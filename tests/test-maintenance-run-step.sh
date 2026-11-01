#!/usr/bin/env bash
# 子の終了コード・出力・status-file と、タイムアウト時の孫の終了を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/maintenance_run_step.py"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}

run_step() { python3 "$SCRIPT" "$@"; }

echo "=== 1. 通常終了: 子プロセスの終了コードがそのまま返る ==="
{
  run_step --timeout 5 -- python3 -c "import sys; sys.exit(3)"
  rc=$?
  assert_eq "終了コード3がそのまま伝播する" "3" "$rc"
}

echo "=== 2. 通常終了: 子プロセスの標準出力・標準エラーがそのまま継承される(素通し) ==="
{
  ERRLOG="$TMPROOT/t2-stderr.log"
  out="$(run_step --timeout 5 -- python3 -c "print('stdout-line'); import sys; print('stderr-line', file=sys.stderr)" 2>"$ERRLOG")"
  err="$(cat "$ERRLOG")"
  assert_eq "標準出力が加工されずそのまま出る" "stdout-line" "$out"
  assert_contains "標準エラーもそのまま出る" "$err" "stderr-line"
}

echo "=== 4. タイムアウト: 直接の子だけでなくプロセスグループ全体(孫プロセス含む)がSIGKILLされる(設計書§1.2の主眼) ==="
{
  SPAWN_DIR="$TMPROOT/t4"
  mkdir -p "$SPAWN_DIR"
  cat > "$SPAWN_DIR/spawn.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60 &
echo $! > "$PIDFILE"
sleep 60
EOF
  chmod +x "$SPAWN_DIR/spawn.sh"
  PIDFILE="$SPAWN_DIR/child.pid"
  export PIDFILE
  run_step --timeout 1 -- bash "$SPAWN_DIR/spawn.sh"
  rc=$?
  unset PIDFILE
  assert_eq "spawn.sh自体もタイムアウトで終了コード124" "124" "$rc"
  sleep 0.3
  grandchild_pid="$(cat "$SPAWN_DIR/child.pid" 2>/dev/null || true)"
  if [[ -z "$grandchild_pid" ]]; then
    fail_case "孫プロセスの PID を取得できなかった"
  elif kill -0 "$grandchild_pid" 2>/dev/null; then
    fail_case "孫プロセス(バックグラウンドsleep)が生き残っている(プロセスグループkillが機能していない)"
    kill -9 "$grandchild_pid" 2>/dev/null || true  # テスト環境を汚さないための後始末
  else
    pass "孫プロセス(バックグラウンドsleep)もプロセスグループごと終了している"
  fi
}

echo "=== 13. --status-file: 通常終了時の内容が正しい ==="
{
  STATUS="$TMPROOT/t13-status.json"
  run_step --timeout 5 --status-file "$STATUS" -- python3 -c "import sys; sys.exit(0)"
  rc=$?
  ok="$(python3 -c "import json; print(json.load(open('$STATUS'))['ok'])")"
  timed_out="$(python3 -c "import json; print(json.load(open('$STATUS'))['timed_out'])")"
  if [ "$rc" -eq 0 ] && [ "$ok" = True ] && [ "$timed_out" = False ]; then
    pass "通常終了を status-file に記録"
  else fail_case "通常終了を status-file に記録"; fi
}

echo "=== 14. --status-file: タイムアウト時にtimed_out=Trueが記録される ==="
{
  STATUS="$TMPROOT/t14-status.json"
  run_step --timeout 1 --status-file "$STATUS" -- python3 -c "import time; time.sleep(60)" 2>/dev/null
  timed_out="$(python3 -c "import json; print(json.load(open('$STATUS'))['timed_out'])")"
  ok="$(python3 -c "import json; print(json.load(open('$STATUS'))['ok'])")"
  if [ "$timed_out" = True ] && [ "$ok" = False ]; then
    pass "timeout を status-file に記録"
  else fail_case "timeout を status-file に記録"; fi
}

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
