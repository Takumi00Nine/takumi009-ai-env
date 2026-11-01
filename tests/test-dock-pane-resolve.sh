#!/usr/bin/env bash
# 偽 list コマンドで、Project/Task の注入と取得失敗時の縮退を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/dock/executor/dock-pane-resolve.sh"

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
if [ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]; then
  echo "FATAL: mktemp -d が空でない既存ディレクトリを返しました: [$WORK_DIR]" >&2
  exit 1
fi
trap 'rm -rf "$WORK_DIR"' EXIT

STDERR_TMP="$WORK_DIR/stderr.tmp"

PROJECT_STUB="$WORK_DIR/cmux-next-model-stub.sh"
cat >"$PROJECT_STUB" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tp-active\t次を進める\t稼働中\t\n'
fi
EOF
chmod +x "$PROJECT_STUB"

TASK_STUB="$WORK_DIR/cmux-task-model-stub.sh"
cat >"$TASK_STUB" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tv2\t1/3\t[x]\t要件定義\n'
  printf '1\tv2\t1/3\t[ ]\t実装\n'
fi
EOF
chmod +x "$TASK_STUB"

FAIL_STUB="$WORK_DIR/fail.sh"
printf '#!/bin/bash\nexit 1\n' >"$FAIL_STUB"
chmod +x "$FAIL_STUB"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

run_hook_raw() {
  local json_input="$1" project_cmd="${2:-$PROJECT_STUB}" task_cmd="${3:-$TASK_STUB}"
  HOOK_STDOUT="$(printf '%s' "$json_input" | NEXT_RESOLVE_LIST_CMD="$project_cmd" TASK_RESOLVE_LIST_CMD="$task_cmd" bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

run_hook() {
  local prompt="$1" project_cmd="${2:-$PROJECT_STUB}" task_cmd="${3:-$TASK_STUB}"
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
  run_hook_raw "$json_input" "$project_cmd" "$task_cmd"
}

assert_fail_silent() {
  local desc="$1"
  if [ -n "$HOOK_STDOUT" ]; then
    fail_case "$desc (stdoutに出力があった。out=[$HOOK_STDOUT])"
    return
  fi
  if [ -n "$HOOK_STDERR" ]; then
    fail_case "$desc (stderrに出力があった。err=[$HOOK_STDERR])"
    return
  fi
  if [ "$HOOK_EXIT" -ne 0 ]; then
    fail_case "$desc (終了コードが0でない。exit=$HOOK_EXIT)"
    return
  fi
  pass "$desc"
}

PROJECT_HEADING='Project番号対応表（この瞬間の表示順。ユーザーの「Project の N 番」はこの表で解決する。列＝番号・正式プロジェクト名・next 値・区分（稼働中／待ち／保留）・待ち日時（待ちの行だけ YYYY-MM-DDTHH:MM・他は空））:'
TASK_HEADING='Task番号対応表（番号は版を指す・この瞬間の表示順。ユーザーの「Task の N 番」は同じ番号の行の版で解決する。列＝番号・版名・分数・状態・本文）:'

extract_ctx() {
  local desc="$1"
  CTX=""
  if [ -n "$HOOK_STDERR" ]; then
    fail_case "$desc (stderrに出力があった。err=[$HOOK_STDERR])"; return 1
  fi
  if [ "$HOOK_EXIT" -ne 0 ]; then
    fail_case "$desc (終了コードが0でない。exit=$HOOK_EXIT)"; return 1
  fi
  if [ -z "$HOOK_STDOUT" ]; then
    fail_case "$desc (注入されなかった)"; return 1
  fi
  if ! printf '%s' "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; then
    fail_case "$desc (JSON形式が想定と違う。out=[$HOOK_STDOUT])"; return 1
  fi
  CTX="$(printf '%s' "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')"
  return 0
}

assert_injected_side() {
  local desc="$1" prompt="$2" side="$3" heading other_heading list_mark
  if [ "$side" = "project" ]; then
    heading="$PROJECT_HEADING"; other_heading="$TASK_HEADING"; list_mark="p-active"
  else
    heading="$TASK_HEADING"; other_heading="$PROJECT_HEADING"; list_mark="要件定義"
  fi
  run_hook "$prompt"
  extract_ctx "$desc" || return
  local firstline
  firstline="$(printf '%s' "$CTX" | head -1)"
  if [ "$firstline" != "$heading" ]; then
    fail_case "$desc (見出し文が完全一致しない。firstline=[$firstline])"; return
  fi
  if ! printf '%s' "$CTX" | grep -qF "$list_mark"; then
    fail_case "$desc (--listの出力が含まれていない。ctx=[$CTX])"; return
  fi
  if printf '%s' "$CTX" | grep -qF "$other_heading"; then
    fail_case "$desc (もう片方の表が混入している。ctx=[$CTX])"; return
  fi
  pass "$desc"
}

echo "=== 1. 発火（Project側）＝見出し固定文で始まり --list の出力を含む ==="
assert_injected_side "「Project の 3 番」はProject表だけ注入" "Project の 3 番" project

echo "=== 2. 発火（Task側） ==="
assert_injected_side "「Task の3番」はTask表だけ注入" "Task の3番" task

echo "=== 3. 両方発火＝1つのadditionalContextにProject表→空行→Task表 ==="
start_ts=$(date +%s)
run_hook "Project の2番と Task の3番"
end_ts=$(date +%s)
both_elapsed=$((end_ts - start_ts))
if extract_ctx "両語同時発火"; then
  firstline="$(printf '%s' "$CTX" | head -1)"
  project_ln="$(printf '%s\n' "$CTX" | grep -nF "$PROJECT_HEADING" | head -1 | cut -d: -f1)"
  task_ln="$(printf '%s\n' "$CTX" | grep -nF "$TASK_HEADING" | head -1 | cut -d: -f1)"
  blank_before_task="$(printf '%s\n' "$CTX" | sed -n "$((${task_ln:-1} - 1))p")"
  if [ "$firstline" = "$PROJECT_HEADING" ] && [ -n "$task_ln" ] && [ "${project_ln:-0}" -lt "$task_ln" ] \
     && [ -z "$blank_before_task" ] \
     && printf '%s' "$CTX" | grep -qF "p-active" && printf '%s' "$CTX" | grep -qF "要件定義"; then
    pass "「Project の2番と Task の3番」は1 JSONにProject表→空行→Task表の順で両表が入る（実測 ${both_elapsed}s）"
  else
    fail_case "両語同時発火の合成 (project_ln=$project_ln task_ln=$task_ln blank=[$blank_before_task] ctx=[$CTX])"
  fi
fi

echo "=== 5. fail-silent（LIST_CMD不在・非実行・空出力・非0）＝Project側・Task側の代表 ==="
run_hook "Project の2番" "$WORK_DIR/does-not-exist.sh" "$TASK_STUB"
assert_fail_silent "Project側LIST_CMDが存在しないときは発火しない"
echo "=== 5b. 両方発火で片方が失敗＝その表だけ落とし、もう片方だけ出す ==="
run_hook "Project の2番と Task の3番" "$PROJECT_STUB" "$FAIL_STUB"
if extract_ctx "Task側だけ失敗"; then
  if [ "$(printf '%s' "$CTX" | head -1)" = "$PROJECT_HEADING" ] && ! printf '%s' "$CTX" | grep -qF "$TASK_HEADING"; then
    pass "Task側の--listが失敗してもProject表だけは注入される"
  else
    fail_case "Task側だけ失敗のときProject表だけ (ctx=[$CTX])"
  fi
fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
