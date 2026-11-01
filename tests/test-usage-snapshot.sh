#!/usr/bin/env bash
# 隔離キャッシュで生成物の形・鮮度・欠落・秘密の無害化を確認する。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/usage/executor/usage_snapshot.py"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\" / 実際: $haystack)"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NOW=1788858365  # 固定epoch（JST表示・年齢計算を決定的にするための固定値）

write_json() { # write_json <path> <python式(dictリテラル)>
  python3 -c "import json,sys; open(sys.argv[1],'w').write(json.dumps(eval(sys.argv[2])))" "$1" "$2"
}
run_json() { # run_json <cache_dir> [追加引数...]
  local dir="$1"; shift
  AIENV_USAGE_CACHE_DIR="$dir" python3 "$LIB" --json --now "$NOW" "$@"
}
run_human() { # run_human <cache_dir> [追加引数...]
  local dir="$1"; shift
  AIENV_USAGE_CACHE_DIR="$dir" python3 "$LIB" --now "$NOW" "$@"
}
pool_field() { # pool_field <json> <pool_ref> <key>
  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
p = [p for p in d['pools'] if p['pool_ref'] == sys.argv[2]][0]
v = p[sys.argv[3]]
print('null' if v is None else v)
" "$1" "$2" "$3"
}
FX1="$WORK/fx1"; mkdir -p "$FX1"
write_json "$FX1/claude-cache.json" "{'schema_version':1,'service':'claude','fetched_at':$NOW-180,'updated_at':$NOW-180,'five_hour':{'used_percent':25.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':46.0,'resets_at_epoch':$NOW+90000},'model_weekly':{'used_percent':34,'resets_at_epoch':$NOW+90000,'label':'Fable'},'last_error':None}"
write_json "$FX1/codex-cache.json" "{'schema_version':1,'service':'codex','fetched_at':$NOW-60,'updated_at':$NOW-60,'five_hour':{'used_percent':66,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':10,'resets_at_epoch':$NOW+90000},'reset_credits':{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'RateLimitResetCredit_abc123','status':'available','granted_at_epoch':1788539594,'expires_at_epoch':1791131594,'title':'Full reset (Weekly + 5 hr)'}]},'last_error':None}"

echo "=== 正常なキャッシュを JSON と人向け表示にする ==="
json="$(run_json "$FX1")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d["generated_at"],(int,float)); assert d["pools"]; assert all({"pool_ref","usage_state","windows"} <= p.keys() for p in d["pools"])'; then
  pass "JSON は生成日時とサービス枠を持つ"
else fail_case "JSON は生成日時とサービス枠を持つ"; fi
for svc in claude codex; do
  assert_eq "$svc は正常" ok "$(pool_field "$json" "$svc-subscription" usage_state)"
done
human="$(run_human "$FX1")"
if [[ "$human" == *'Claude枠:'* && "$human" == *'Codex枠:'* ]]; then pass "人向け表示にサービス枠"; else fail_case "人向け表示にサービス枠"; fi
FX2="$WORK/fx2"; mkdir -p "$FX2"
write_json "$FX2/claude-cache.json" "{'fetched_at':$NOW-700,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':None}"
write_json "$FX2/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':40,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':50,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== 古いキャッシュは stale と表示する ==="
json="$(run_json "$FX2")"
assert_eq "古いサービスは stale" stale "$(pool_field "$json" claude-subscription usage_state)"
assert_contains "人向け表示でも古いと分かる" "$(run_human "$FX2")" '⚠️古い'

echo "=== キャッシュ欠落でも他サービスは表示する ==="
rm "$FX1/claude-cache.json"
json="$(run_json "$FX1")"
if [ "$(pool_field "$json" claude-subscription usage_state)" = missing ] && [ "$(pool_field "$json" codex-subscription usage_state)" = ok ]; then
  pass "欠落した枠だけ missing"
else fail_case "欠落した枠だけ missing"; fi
FX9="$WORK/fx9"; mkdir -p "$FX9"
write_json "$FX9/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':{'type':'Bearer sk-abc123XYZsecret leaked!!','message':'whatever secret token=xyz AKIAABCDEFGHIJKLMNOP'}}"
write_json "$FX9/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== キャッシュ内の自由文に混ざった秘密を再掲しない ==="
json="$(run_json "$FX9")"; human="$(run_human "$FX9")"
if [[ "$json$human" != *sk-abc123XYZsecret* && "$json$human" != *AKIAABCDEFGHIJKLMNOP* && "$json$human" != *token=xyz* ]] && [ -n "$(pool_field "$json" claude-subscription error)" ]; then
  pass "JSON と人向け表示の秘密を無害化"
else fail_case "JSON と人向け表示の秘密を無害化"; fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
