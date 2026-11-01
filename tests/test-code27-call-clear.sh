#!/usr/bin/env bash
# 隔離 HOME と偽 CODE27 で、人の入力への応答と背景通知の無視を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/core/connect/claude-code/prompt-answer.sh"
LEDGER_REAL="$REPO_ROOT/core/data/ledger.tsv"

WORK_DIR="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; exit 1; }
case "$WORK_DIR" in
  "" | "/")
    echo "FATAL: mktemp -d の返り値が不正です: [$WORK_DIR]" >&2
    exit 1
    ;;
esac
if [ ! -d "$WORK_DIR" ]; then
  echo "FATAL: mktemp -d がディレクトリを作成できませんでした: [$WORK_DIR]" >&2
  exit 1
fi
trap 'chmod -R u+rwx "$WORK_DIR" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

export HOME="$WORK_DIR/home"
mkdir -p "$HOME"

STDERR_TMP="$WORK_DIR/stderr.tmp"
MARKER="$WORK_DIR/clear-called.log"

FAKE_CLEAR="$REPO_ROOT/tests/fixtures/code27-call/bin/code27-call-clear"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

wait_for() {  # wait_for <ファイル> <timeout秒>
  local f="$1" t="$2" i=0
  while [ "$i" -lt $((t * 10)) ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$f" ]
}

run_hook_raw() {
  local stdin_text="$1" bin_path="${2:-$FAKE_CLEAR}" ledger="${3:-$LEDGER_REAL}" extra_path="${4:-}"
  rm -f "$MARKER"
  HOOK_STDOUT="$(printf '%s' "$stdin_text" \
    | CODE27_CALL_BIN="$bin_path" CODE27_CALL_LOG="$MARKER" AIENV_LEDGER="$ledger" PATH="${extra_path:+$extra_path:}$PATH" \
      bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

run_hook_prompt() {
  local prompt="$1" bin_path="${2:-$FAKE_CLEAR}" ledger="${3:-$LEDGER_REAL}"
  local json_input
  json_input="$(jq -n --arg p "$prompt" '{
    session_id: "test-session-id",
    transcript_path: "/tmp/test-transcript.jsonl",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "UserPromptSubmit",
    prompt_id: "test-prompt-id",
    scratchpad_dir: "/tmp/test-scratchpad",
    prompt: $p
  }')"
  run_hook_raw "$json_input" "$bin_path" "$ledger"
}

echo "=== 人の入力は応答する ==="
run_hook_prompt "聞こえた"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && wait_for "$MARKER" 3; then
  pass "人の入力で応答しフックは終了 0"
else fail_case "人の入力で応答しフックは終了 0"; fi

echo "=== 背景通知では応答しない ==="
run_hook_prompt '<task-notification>完了しました'
sleep 0.5
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ ! -s "$MARKER" ]; then
  pass "背景通知を無視する"
else fail_case "背景通知を無視する"; fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
