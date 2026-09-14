#!/usr/bin/env bash
# usage-inject.sh の正常注入・fail-open・登録/配置を狙い撃ちする。
# 実キャッシュや実 ~/.claude には依存しない。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/usage-inject.sh"
SNAPSHOT="$REPO_ROOT/claude/hooks/lib/usage_snapshot.py"
NOW=1788858365
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: [$needle] / 実際: [$haystack])"
  fi
}

WORK="$(mktemp -d)" || exit 1
case "$WORK" in "" | "/") echo "FATAL: mktemp -d の返り値が不正です" >&2; exit 1 ;; esac
[ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT

CACHE="$WORK/cache"
mkdir -p "$CACHE"
python3 -c "import json,sys; json.dump({'schema_version':1,'service':'claude','fetched_at':$NOW-30,'updated_at':$NOW-30,'five_hour':{'used_percent':25,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':40,'resets_at_epoch':$NOW+90000},'last_error':None},open(sys.argv[1],'w'))" "$CACHE/claude-cache.json"
python3 -c "import json,sys; json.dump({'schema_version':1,'service':'codex','fetched_at':$NOW-20,'updated_at':$NOW-20,'five_hour':{'used_percent':10,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':95,'resets_at_epoch':$NOW+90000},'reset_credits':{'available_count':0,'reset_scope':['five_hour','seven_day'],'credits':[]},'last_error':None},open(sys.argv[1],'w'))" "$CACHE/codex-cache.json"

run_hook_capture() { # $1=stdin文字列、残りは env 引数。3出力を別々に保持する
  local input="$1"; shift
  local stdout_file="$WORK/capture.stdout" stderr_file="$WORK/capture.stderr"
  RUN_RC=0
  printf '%s' "$input" \
    | env AIENV_USAGE_CACHE_DIR="$CACHE" AIENV_USAGE_NOW="$NOW" "$@" /bin/bash "$HOOK" \
      >"$stdout_file" 2>"$stderr_file" || RUN_RC=$?
  RUN_STDOUT="$(<"$stdout_file")"
  RUN_STDERR="$(<"$stderr_file")"
  RUN_STDERR_BYTES="$(wc -c < "$stderr_file" | tr -d ' ')"
}

echo "=== 1. 正常時は見出し＋usage_snapshot.pyの3行と完全一致 ==="
expected="$(printf '【使用率・この発言時点】\n'; AIENV_USAGE_CACHE_DIR="$CACHE" python3 "$SNAPSHOT" --now "$NOW")"
run_hook_capture '{"prompt":"test"}'
assert_eq "正常時 exit 0" "0" "$RUN_RC"
assert_eq "正常時 stderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "見出し＋3行がsnapshot出力と一致" "$expected" "$RUN_STDOUT"
assert_eq "正常時は4行" "4" "$(printf '%s\n' "$RUN_STDOUT" | wc -l | tr -d ' ')"

echo "=== 2. fail-open 4分類は1行＋exit 0 ==="
MINPATH="$WORK/minpath"; mkdir -p "$MINPATH"
for cmd in cat dirname readlink; do ln -s "$(command -v "$cmd")" "$MINPATH/$cmd"; done
run_hook_capture '' PATH="$MINPATH"
assert_eq "python3不在でもexit 0" "0" "$RUN_RC"
assert_eq "python3不在でもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "python3不在は1行" "1" "$(printf '%s\n' "$RUN_STDOUT" | wc -l | tr -d ' ')"
assert_contains "python3不在の説明" "$RUN_STDOUT" "python3 なし"

run_hook_capture '' USAGE_BLOCK_LIB="$WORK/not-found-block.sh"
assert_eq "共有shell lib不在でもexit 0" "0" "$RUN_RC"
assert_eq "共有shell lib不在でもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "共有shell lib不在は内部エラー1行" "【使用率・この発言時点】取得口が使えません（内部エラー）" "$RUN_STDOUT"

run_hook_capture '' USAGE_SNAPSHOT_LIB="$WORK/not-found.py"
assert_eq "snapshot lib不在でもexit 0" "0" "$RUN_RC"
assert_eq "snapshot lib不在でもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "snapshot lib不在は1行" "1" "$(printf '%s\n' "$RUN_STDOUT" | wc -l | tr -d ' ')"
assert_contains "snapshot lib不在の説明" "$RUN_STDOUT" "usage_snapshot.py が見つかりません"

printf '# empty\n' > "$WORK/empty.py"
run_hook_capture '' USAGE_SNAPSHOT_LIB="$WORK/empty.py"
assert_eq "空出力でもexit 0" "0" "$RUN_RC"
assert_eq "空出力でもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "空出力は失敗説明1行" "【使用率・この発言時点】取得口が使えません（usage_snapshot.py の実行に失敗しました）" "$RUN_STDOUT"

printf 'print("partial")\nraise SystemExit(3)\n' > "$WORK/nonzero.py"
run_hook_capture '' USAGE_SNAPSHOT_LIB="$WORK/nonzero.py"
assert_eq "snapshot失敗（非0）でもexit 0" "0" "$RUN_RC"
assert_eq "snapshot失敗（非0）でもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "非0は部分出力を捨てた失敗説明1行" "【使用率・この発言時点】取得口が使えません（usage_snapshot.py の実行に失敗しました）" "$RUN_STDOUT"

echo "=== 3. stdinは空・不正JSONでも正常注入する ==="
run_hook_capture ''
assert_eq "空stdinでもexit 0" "0" "$RUN_RC"
assert_eq "空stdinでもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "空stdinでも正常出力" "$expected" "$RUN_STDOUT"
run_hook_capture '{not-json'
assert_eq "不正JSONでもexit 0" "0" "$RUN_RC"
assert_eq "不正JSONでもstderr 0 byte" "0" "$RUN_STDERR_BYTES"
assert_eq "不正JSONでも正常出力" "$expected" "$RUN_STDOUT"

echo "=== 4. symlink先の実体ディレクトリ直下libを解決する ==="
mkdir -p "$WORK/home/.claude/hooks"
ln -s "$HOOK" "$WORK/home/.claude/hooks/usage-inject.sh"
out="$(printf '{}' | AIENV_USAGE_CACHE_DIR="$CACHE" AIENV_USAGE_NOW="$NOW" /bin/bash "$WORK/home/.claude/hooks/usage-inject.sh")"
assert_eq "symlink経由でも同一出力" "$expected" "$out"

echo "=== 5. settings登録とinstaller配置を静的突合する ==="
last_command="$(python3 -c "import json; d=json.load(open('$REPO_ROOT/claude/settings.json')); print([h['command'] for g in d['hooks']['UserPromptSubmit'] for h in g['hooks']][-1])")"
assert_eq "UserPromptSubmit末尾に登録" '$HOME/.claude/hooks/usage-inject.sh' "$last_command"
settings_fields="$(python3 -c "import json; d=json.load(open('$REPO_ROOT/claude/settings.json')); h=d['hooks']['UserPromptSubmit'][0]['hooks'][-1]; print(h['timeout'],h['statusMessage'])")"
assert_eq "timeout/statusMessageが指定値" "5 使用率を注入中" "$settings_fields"
install_line="$(grep '^[[:space:]]*link claude/hooks/usage-inject\.sh[[:space:]]' "$REPO_ROOT/scripts/install-main.sh" || true)"
assert_contains "install-main.shにlink配置あり" "$install_line" 'usage-inject.sh'
if grep -q 'install-main\.sh' "$REPO_ROOT/scripts/install-sub.sh"; then
  pass "install-sub.shはinstall-main.shへ配置を委譲"
else
  fail_case "install-sub.shの配置経路が確認できない"
fi

echo "=== 6. macOS bash 3.2向け構文と禁止timeoutを静的検査する ==="
if /bin/bash -n "$HOOK" "$REPO_ROOT/claude/hooks/lib/usage-block.sh"; then pass "bash -n成功"; else fail_case "bash -n失敗"; fi
if grep -qE '(^|[[:space:]])timeout([[:space:]]|$)' "$HOOK" "$REPO_ROOT/claude/hooks/lib/usage-block.sh"; then
  fail_case "timeoutコマンドを使っている"
else
  pass "timeoutコマンド不使用"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
