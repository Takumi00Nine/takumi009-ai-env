#!/usr/bin/env bash
# claude/hooks/code27-call-clear.sh のユニットテスト（📣 通知取次 v1・実機スモーク指摘b＝
# 入力時フックは「人の入力」だけで全消去し、背景タスクの完了通知（<task-notification>
# で始まる入力）では消さない。design notify-v1-design.md v1.3 §2 入力時フック行）。
#
# 実 ~/work/navi-orchestrator/code27-call には一切依存しない。フックへUserPromptSubmit
# の実イベント形をstdinで渡し、CODE27_CALL_BINで偽のclear実行ファイル（呼ばれたら
# 印を残すだけ）へ差し替える。標準出力/標準エラー/終了コード/偽clearの呼ばれた回数
# の4点で判定する。
#
# 実行方法: bash tests/test-code27-call-clear.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/code27-call-clear.sh"

WORK_DIR="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; exit 1; }
case "$WORK_DIR" in
  "" | "/")
    echo "FATAL: mktemp -d の返り値が不正です: [$WORK_DIR]" >&2
    exit 1
    ;;
esac
if [ ! -d "$WORK_DIR" ]; then
  echo "FATAL: mktemp -d がディレクトリを作成しませんでした: [$WORK_DIR]" >&2
  exit 1
fi
trap 'rm -rf "$WORK_DIR"' EXIT

STDERR_TMP="$WORK_DIR/stderr.tmp"
MARKER="$WORK_DIR/clear-called.log"

# 偽clear＝呼ばれたら印(1行)を残すだけ。実 code27-call-clear には触れない。
FAKE_CLEAR="$WORK_DIR/fake-clear.sh"
cat >"$FAKE_CLEAR" <<EOF
#!/bin/bash
echo "called" >> "$MARKER"
exit 0
EOF
chmod +x "$FAKE_CLEAR"

MISSING_BIN="$WORK_DIR/does-not-exist.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# フックへ生stdinを渡して実行し、標準出力/標準エラー/終了コードをグローバル
# 変数へ格納する。$1=stdin文字列・$2=CODE27_CALL_BIN（省略時は偽clear）。
run_hook_raw() {
  local stdin_text="$1" bin_path="${2:-$FAKE_CLEAR}"
  rm -f "$MARKER"
  HOOK_STDOUT="$(printf '%s' "$stdin_text" | CODE27_CALL_BIN="$bin_path" bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

# UserPromptSubmitの実イベント形（本番envelope＝session_id等を含む）をjqで組み
# 立てて渡す。promptだけのfixtureだと他キーの有無で分岐する変異を検出できない
# ため（test-dock-pane-resolve.sh と同じ流儀）。
run_hook_prompt() {
  local prompt="$1" bin_path="${2:-$FAKE_CLEAR}"
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
  run_hook_raw "$json_input" "$bin_path"
}

clear_call_count() {
  if [ -f "$MARKER" ]; then
    wc -l <"$MARKER" | tr -d ' '
  else
    echo 0
  fi
}

echo "=== a. 人の入力＝全消去する（従来どおり） ==="
run_hook_prompt "聞こえた"
count="$(clear_call_count)"
if [ "$count" = "1" ] && [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ]; then
  pass "人の入力プロンプトで偽clearが1回呼ばれ・終了0・stdout/stderr空"
else
  fail_case "人の入力プロンプト (count=$count exit=$HOOK_EXIT out=[$HOOK_STDOUT] err=[$HOOK_STDERR])"
fi

echo "=== b. 背景タスクの完了通知＝全消去しない（実機スモーク指摘・design v1.3 §2） ==="
run_hook_prompt "$(printf '<task-notification>\n<task-id>x</task-id>\n完了しました')"
count="$(clear_call_count)"
if [ "$count" = "0" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "<task-notification>で始まる入力では偽clearが呼ばれない・終了0"
else
  fail_case "<task-notification>入力 (count=$count exit=$HOOK_EXIT out=[$HOOK_STDOUT] err=[$HOOK_STDERR])"
fi

echo "=== c. stdinが空／JSONでない＝安全側（従来どおり消す） ==="
run_hook_raw ""
count="$(clear_call_count)"
if [ "$count" = "1" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "stdinが空でも偽clearが呼ばれる・終了0（安全側）"
else
  fail_case "stdinが空 (count=$count exit=$HOOK_EXIT out=[$HOOK_STDOUT] err=[$HOOK_STDERR])"
fi

run_hook_raw "not-json"
count="$(clear_call_count)"
if [ "$count" = "1" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "stdinがJSONでなくても偽clearが呼ばれる・終了0（安全側）"
else
  fail_case "stdinが非JSON (count=$count exit=$HOOK_EXIT out=[$HOOK_STDOUT] err=[$HOOK_STDERR])"
fi

echo "=== d. CODE27_CALL_BINが存在しない＝何もせず終了0 ==="
run_hook_prompt "聞こえた" "$MISSING_BIN"
count="$(clear_call_count)"
if [ "$count" = "0" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "CODE27_CALL_BINが存在しないときは何もせず終了0"
else
  fail_case "CODE27_CALL_BINが存在しない (count=$count exit=$HOOK_EXIT out=[$HOOK_STDOUT] err=[$HOOK_STDERR])"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
