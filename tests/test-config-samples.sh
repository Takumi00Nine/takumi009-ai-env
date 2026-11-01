#!/usr/bin/env bash
# sample の解決・経路の代表・秘匿。repo 内だけで完結する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/team/executor/profile_resolve.py"
INSTALL_MAIN="$REPO_ROOT/core/assembly/install-main.sh"
CONFIG_DIR="$REPO_ROOT/team/data"
PROFILE_SAMPLE="$CONFIG_DIR/profile.md.sample"
MODELS_SAMPLE="$CONFIG_DIR/models.conf.sample"
BEDROCK_SAMPLE="$REPO_ROOT/team/connect/claude-code/bedrock.env.sample"
AGENTS_DIR="$REPO_ROOT/team/rules/agents"


PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in "$PROFILE_SAMPLE" "$MODELS_SAMPLE" "$BEDROCK_SAMPLE"; do
  [ -f "$f" ] || { fail_case "前提: $f が存在する"; }
done

echo "=== sample の解決 ==="
out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$PROFILE_SAMPLE" --agents-dir "$AGENTS_DIR")"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == OK* && "$out" == *TEAM_MODE:* && "$out" == *MACHINE_ROLE:* ]]; then
  pass "sample を resolver で解決できる"
else
  fail_case "sample を resolver で解決できる"
fi
echo "=== AC-2: 経路（provider×execution）ごとの代表1件が起動でき、未対応の経路は保留になる（要件書 FR-7・AC-2） ==="
{
  check_candidate() {
    local role="$1" def="$2" route="$3"
    local out rc=0
    out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve-candidate "$PROFILE_SAMPLE" --role "$role" --model-def "$def" --agents-dir "$AGENTS_DIR" 2>&1)" || rc=$?
    case "$out" in
      OK*)
        if [ "$rc" -eq 0 ] && [[ "$out" == *"$def"* ]]; then
          pass "経路の代表: $route"
        else
          fail_case "経路の代表: $route"
        fi
        ;;
      *SUBAGENT_PROVIDER_UNSUPPORTED*)
        # 要件書 FR-7: この機体で未対応の経路は赤にせず保留にする。
        echo "  hold - この機体で未対応の経路（${route}）"
        pass "AC-2: route=$route role=$role def=$def この機体で未対応のため保留"
        ;;
      *)
        fail_case "AC-2: route=$route role=$role def=$def exit0 (expected=[0] actual=[$rc] out=[$out])"
        ;;
    esac
  }
  # 要件書 AC-2・FR-7: 起動可能性は provider×execution の経路ごとに代表1件だけ
  # 見る。list-roles の configured 行を経路（provider/execution）でまとめ、
  # 経路ごと最初の1組だけを resolve-candidate に通す（テストに literal で
  # 列挙しない）。同じ経路の残りの候補・どこからも参照されていない定義は
  # 個別に検査しない。組が0件のときは検査が空回りしたものとして失敗させる
  # （空虚な真の禁止）。
  routes_reps="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" list-roles "$PROFILE_SAMPLE" \
    | awk -F'\t' '$2=="configured" && !seen[$4"/"$6]++ {print $1"\t"$3"\t"$4"/"$6}')"
  routes_count=0
  while IFS=$'\t' read -r role def route; do
    [ -n "$role" ] || continue
    check_candidate "$role" "$def" "$route"
    routes_count=$((routes_count + 1))
  done <<< "$routes_reps"
  if [ "$routes_count" -lt 1 ]; then
    fail_case "AC-2: サンプルから経路が1件も生成されなかった（空虚な真の禁止）"
  fi
}

echo "=== sample と生成物に秘密・実パスを含めない ==="
if python3 - "$REPO_ROOT" <<'PY'
import re,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'team/executor'))
import profile_resolve as pr
root=Path(sys.argv[1])
for rel in ('team/data/profile.md.sample','team/data/models.conf.sample','team/connect/claude-code/bedrock.env.sample'):
    text=(root/rel).read_text()
    assert not re.search(r'/Users/|/home/[^/\s]+/',text), rel
    for key in re.findall(r'^\s*#?\s*\[?([A-Za-z0-9_.-]+)\]?\s*[:=]',text,re.M):
        assert not any(s in key.lower() for s in pr.FORBIDDEN_KEY_SUBSTRINGS), rel
PY
then pass "sample に認証キー・個人の実パスが無い"; else fail_case "sample に認証キー・個人の実パスが無い"; fi
ac3_home="$WORK/home"; mkdir -p "$ac3_home"
cp "$BEDROCK_SAMPLE" "$WORK/bedrock.env"
rc=0
AIENV_LOCAL_PROFILE_PATH="$PROFILE_SAMPLE" AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" AIENV_BEDROCK_ENV_FILE="$WORK/bedrock.env" \
  HOME="$ac3_home" "$INSTALL_MAIN" --render-settings-json "$WORK/settings.json" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && python3 - "$WORK/settings.json" "$LIB" <<'PY'
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[2]).parent))
import profile_resolve as pr
d=json.load(open(sys.argv[1]))
assert d['model'] and d['model'] != '__AIENV_MODEL__'
assert all(not any(s in k.lower() for s in pr.FORBIDDEN_KEY_SUBSTRINGS) for k in d.get('env',{}))
PY
then pass "sample から秘密を含まない設定を生成できる"; else fail_case "sample から秘密を含まない設定を生成できる"; fi

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
