#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/vault-read-log.sh"

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

run_read_log() {
  # run_read_log <vault> <log> <file_path> [session_id]
  local vault="$1" log="$2" fpath="$3" session="${4:-sess-1}"
  local input
  input="$(jq -n --arg f "$fpath" --arg s "$session" \
    '{session_id: $s, tool_name: "Read", tool_input: {file_path: $f}}')"
  printf '%s' "$input" | VAULT_READS_VAULT="$vault" VAULT_READS_LOG="$log" "$SCRIPT"
}

echo "=== Vault内のReadをTSVへ追記する ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"
  mkdir -p "$VAULT_DIR/Knowledge"
  : > "$VAULT_DIR/Knowledge/mistakes.md"

  run_read_log "$VAULT_DIR" "$LOG" "$VAULT_DIR/Knowledge/mistakes.md" "sess-abc"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  logtext="$(cat "$LOG")"
  assert_eq "Readがセッションと相対パスを持つTSVとして追記される" "1" \
    "$(printf '%s\n' "$logtext" | awk -F'\t' 'NF==3 && $2=="sess-abc" && $3=="Knowledge/mistakes.md" {n++} END {print n+0}')"
  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== Vault外のReadは対象外で正常終了する ==="
{
  VAULT_DIR="$(mktemp -d)"
  OTHER_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"

  run_read_log "$VAULT_DIR" "$LOG" "$OTHER_DIR/somefile.md"
  rc=$?
  assert_eq "対象外はexit 0・ログ未作成" "0 absent" \
    "$rc $([ -e "$LOG" ] && echo present || echo absent)"

  rm -rf "$VAULT_DIR" "$OTHER_DIR" "$(dirname "$LOG")"
}

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
