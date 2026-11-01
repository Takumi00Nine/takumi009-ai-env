#!/usr/bin/env bash
# 一時ファイルで status-file・pid-lock と Vault 保護パスの判定を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/core/executor"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

echo "=== 1. status-file.sh: write_status_file → read_status_file で書いた値をそのまま読める ==="
{
  source "$LIB_DIR/status-file.sh"
  F="$(mktemp -u)"
  write_status_file "$F" "completed"
  out="$(read_status_file "$F")"
  assert_eq "completedが読める" "completed" "$out"
  rm -f "$F"
}
echo "=== 3. status-file.sh: read_status_fileはファイルが無ければ missing を返しexit code 1 ==="
{
  source "$LIB_DIR/status-file.sh"
  rc=0
  out="$(read_status_file "/nonexistent-status-file-$$.txt")" || rc=$?
  assert_eq "missing が返る" "missing" "$out"
  assert_eq "exit code 1" "1" "$rc"
}

echo "=== pid-lock の取得・解放 ==="
D="$(mktemp -d)" || exit 1
trap 'rm -rf "$D"' EXIT
LOCK="$D/writer.lock"
bash -c 'source "$1"; acquire_pid_lock "$2" 3600 test; test -s "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$LOCK" ]; then pass "取得したロックを終了時に解放"; else fail_case "取得したロックを終了時に解放"; fi

echo "=== busy は処理を実行せず status-file に残す ==="
echo "$$" > "$LOCK"
bash -c 'source "$1"; source "$2"; acquire_pid_lock "$3" 3600 test "$4"; touch "$5"' _ "$LIB_DIR/pid-lock.sh" "$LIB_DIR/status-file.sh" "$LOCK" "$D/status" "$D/ran"
if [ "$(cat "$D/status")" = busy ] && [ ! -e "$D/ran" ] && [ "$(cat "$LOCK")" = "$$" ]; then pass "生存ロックは非破壊で busy"; else fail_case "生存ロックは非破壊で busy"; fi

echo "=== stale は回収して処理を実行する ==="
echo "999999" > "$LOCK"
bash -c 'source "$1"; acquire_pid_lock "$2" 3600 test; touch "$3"' _ "$LIB_DIR/pid-lock.sh" "$LOCK" "$D/ran"
if [ -e "$D/ran" ] && [ ! -e "$LOCK" ]; then pass "stale ロックの回収と解放"; else fail_case "stale ロックの回収と解放"; fi

echo "=== ロックの原子的な公開は既存の所有者を上書きしない ==="
printf 'sentinel\n' > "$LOCK"
bash -c 'source "$1"; _pid_lock_try_create "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$LOCK")" = sentinel ]; then pass "既存ロックを上書きしない"; else fail_case "既存ロックを上書きしない"; fi

echo "=== Vault 保護パスの allow/deny ==="
VP_HOME="$D/home"
HOME="$VP_HOME" source "$LIB_DIR/vault-paths.sh"
rc=0; HOME="$VP_HOME" guard_is_vault_ai_path "$VP_HOME/Data/obsidian/Knowledge/x.md" || rc=$?
assert_eq "保護対象の配下は allow" 0 "$rc"
rc=0; HOME="$VP_HOME" guard_is_vault_ai_path "$VP_HOME/Data/obsidian/Templates/x.md" || rc=$?
assert_eq "保護対象外は deny" 1 "$rc"

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
