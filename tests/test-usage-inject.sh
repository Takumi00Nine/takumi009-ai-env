#!/usr/bin/env bash
# 隔離キャッシュで使用率の注入と取得器の失敗時の fail-open を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/usage/executor/usage-inject.sh"
NOW=1788858365
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

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

echo "=== 正常な使用率を注入する ==="
run_hook_capture '{"prompt":"test"}'
if [ "$RUN_RC" -eq 0 ] && [ -z "$RUN_STDERR" ] && [[ "$RUN_STDOUT" == *'【使用率・この発言時点】'* && "$RUN_STDOUT" == *'Claude枠:'* && "$RUN_STDOUT" == *'Codex枠:'* ]]; then
  pass "使用率の見出しとサービス枠を注入"
else fail_case "使用率の見出しとサービス枠を注入"; fi

echo "=== 取得器の失敗は発言を止めない ==="
printf 'print("partial")\nraise SystemExit(3)\n' > "$WORK/nonzero.py"
run_hook_capture '' USAGE_SNAPSHOT_LIB="$WORK/nonzero.py"
if [ "$RUN_RC" -eq 0 ] && [ -z "$RUN_STDERR" ] && [[ "$RUN_STDOUT" == *'取得口が使えません'* && "$RUN_STDOUT" != *partial* ]]; then
  pass "失敗時も終了 0 で部分出力を捨てる"
else fail_case "失敗時も終了 0 で部分出力を捨てる"; fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
