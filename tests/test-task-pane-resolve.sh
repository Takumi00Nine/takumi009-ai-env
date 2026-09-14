#!/usr/bin/env bash
# claude/hooks/task-pane-resolve.sh のユニットテスト（cmux-session-todo v2
# 「Task の番号対応」・担当I・docs/design.md §25.2）。
#
# 実 ~/.claude・実Vault・実cmuxには一切依存しない。フックへ渡すJSON入力
# （UserPromptSubmitフックの実際の呼び出し形式）をjqで組み立てて標準入力から
# 渡し、標準出力・標準エラー・終了コードの3点で判定する。`--list` を叩く先は
# TASK_RESOLVE_LIST_CMD で自前のスタブへ差し替える（実 cmux-task-watch.sh は
# 呼ばない）。型は tests/test-next-pane-resolve.sh（並行案件①）と同じにする
# （mktemp -d ガード・run_hook/run_hook_raw・assert_injected/assert_no_injection）。
#
# 収容するAC＝AC-70〜AC-73（H2・フック単体の発火/非発火/fail-silent）・
# AC-74a/AC-74b（H2・両フックの同時発火。next-pane-resolve.shは実行・参照のみで
# 編集しない）・AC-75（S2・登録と配置の突合＋名称変更の伝播。静的検査を
# このファイルの末尾ブロックに置く）・AC-76（bash -n）。
#
# 実行方法: bash tests/test-task-pane-resolve.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/task-pane-resolve.sh"
OTHER_HOOK="$REPO_ROOT/claude/hooks/next-pane-resolve.sh"

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

# --list スタブ（cmux-task-watch.sh --list 相当。4列TSV）。
STUB_LIST_CMD="$WORK_DIR/cmux-task-watch-stub.sh"
cat >"$STUB_LIST_CMD" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tv2\t[x]\t要件定義\n'
  printf '2\tv2\t[/]\t設計\n'
  printf '3\tv2\t[ ]\t実装\n'
fi
EOF
chmod +x "$STUB_LIST_CMD"

# --list スタブ（①のProject側・AC-74a/AC-74bで使う）。
STUB_PROJECT_LIST_CMD="$WORK_DIR/cmux-next-watch-stub.sh"
cat >"$STUB_PROJECT_LIST_CMD" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
  printf '2\tother-project\t(next未設定)\t保留\n'
fi
EOF
chmod +x "$STUB_PROJECT_LIST_CMD"

# 存在するが実行権限の無いスタブ（[ -x ] チェックの回帰確認用）。
NONEXEC_LIST_CMD="$WORK_DIR/cmux-task-watch-noexec.sh"
cat >"$NONEXEC_LIST_CMD" <<'EOF'
#!/bin/bash
printf '1\tv2\t[x]\t要件定義\n'
EOF
chmod -x "$NONEXEC_LIST_CMD"

# ハングして返ってこないスタブ（AC-72）。自分のPIDをファイルへ書いてから
# 待つ＝孤児検査のため（①の型と同じ）。
HANG_LIST_CMD="$WORK_DIR/cmux-task-watch-hang.sh"
HANG_PIDFILE="$WORK_DIR/hang-list-cmd.pid"
cat >"$HANG_LIST_CMD" <<EOF
#!/bin/bash
if [ "\$1" = "--list" ]; then
  echo \$\$ >"$HANG_PIDFILE"
  sleep 30
  printf '1\tv2\t[x]\t要件定義\n'
fi
EOF
chmod +x "$HANG_LIST_CMD"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# フックへ生JSON入力を渡し、標準出力/標準エラー/終了コードをグローバル
# 変数（HOOK_STDOUT/HOOK_STDERR/HOOK_EXIT）へ格納する。
run_hook_raw() {
  local json_input="$1" list_cmd="${2:-$STUB_LIST_CMD}"
  HOOK_STDOUT="$(printf '%s' "$json_input" | TASK_RESOLVE_LIST_CMD="$list_cmd" bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

# フックへプレーンテキストのpromptを渡す（内部で本番のUserPromptSubmit
# envelopeへ組み立てる。①のtest-next-pane-resolve.shと同じ理由で、
# prompt-only fixtureではなく本番envelopeを渡す）。
run_hook() {
  local prompt="$1" list_cmd="${2:-$STUB_LIST_CMD}"
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
  run_hook_raw "$json_input" "$list_cmd"
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

assert_no_injection() {
  local desc="$1" prompt="$2"
  run_hook "$prompt"
  assert_fail_silent "$desc"
}

EXPECTED_HEADING='Task番号対応表（この瞬間の表示順。ユーザーの「Task の N 番」はこの表で解決する）:'

assert_injected() {
  local desc="$1" prompt="$2"
  run_hook "$prompt"
  if [ -n "$HOOK_STDERR" ]; then
    fail_case "$desc (stderrに出力があった。err=[$HOOK_STDERR])"
    return
  fi
  if [ "$HOOK_EXIT" -ne 0 ]; then
    fail_case "$desc (終了コードが0でない。exit=$HOOK_EXIT)"
    return
  fi
  if [ -z "$HOOK_STDOUT" ]; then
    fail_case "$desc (注入されなかった。prompt=[$prompt])"
    return
  fi
  if ! printf '%s' "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; then
    fail_case "$desc (JSON形式が想定と違う。out=[$HOOK_STDOUT])"
    return
  fi
  local ctx firstline
  ctx="$(printf '%s' "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')"
  firstline="$(printf '%s' "$ctx" | head -1)"
  if [ "$firstline" != "$EXPECTED_HEADING" ]; then
    fail_case "$desc (見出し文が完全一致しない。firstline=[$firstline])"
    return
  fi
  if ! printf '%s' "$ctx" | grep -qF "要件定義"; then
    fail_case "$desc (--listの出力が含まれていない。ctx=[$ctx])"
    return
  fi
  pass "$desc"
}

echo "=== AC-70: 6通りすべてで発火し、見出し固定文で始まり --list の出力を含む ==="
assert_injected "「Task の3番」は発火" "Task の3番"
assert_injected "「taskの3番」は発火" "taskの3番"
assert_injected "「TASK 3番」は発火" "TASK 3番"
assert_injected "「タスクの3番」は発火" "タスクの3番"
assert_injected "「Next Task の3番」は発火（Taskを含むので発火）" "Next Task の3番"
assert_injected "全角空白「Next　Task の3番」は発火（正規化しなくてもTaskが連続しているので当たる）" "Next　Task の3番"

echo "=== AC-71: 陰性ケース（番なし・Task/タスク無し・素のNext・複数形・語境界・型検査） ==="
assert_no_injection "「Task の状況を教えて」は発火しない（番が無い）" "Task の状況を教えて"
assert_no_injection "「3番目の作業をお願い」は発火しない（Task/タスク無し）" "3番目の作業をお願い"
assert_no_injection "「Next の 3 番」は発火しない（素のNextは発火語でない）" "Next の 3 番"
assert_no_injection "空プロンプトは発火しない" ""
assert_no_injection "「Tasks 3番」は発火しない（複数形）" "Tasks 3番"
assert_no_injection "「task_id 3番」は発火しない（アンダースコア接続）" "task_id 3番"
assert_no_injection "「subtask 3番」は発火しない（先頭の後読み）" "subtask 3番"
assert_no_injection "「タスク化 3番」は発火しない（直後の漢字）" "タスク化 3番"

run_hook_raw '{"prompt":{"text":"Task 3番"}}'
assert_fail_silent "prompt がobject型のときは発火しない"
run_hook_raw '{"prompt":["Task 3番"]}'
assert_fail_silent "prompt がarray型のときは発火しない"

echo "=== AC-71続き: 不正バイトが置換文字化して新たな語境界を作っても発火しない（①側の検証5巡目 MINOR #3と同型） ==="
# jqは不正バイトをU+FFFDへ変換して読み進めるため、"ATask"のように本来は
# 語境界が無い箇所（直前がASCII英字）でも、不正バイトが割り込むと
# "A"+FFFD+"Task"に分断されTaskの前に境界が生まれて過剰発火しうる。
# .promptにU+FFFDが含まれる場合は判定に使わず非発火にするガードで対処した。
BADUTF_JSON_TASK="$WORK_DIR/bad-utf8-task.json"
printf '{"prompt":"A\x80Task 3\xe7\x95\xaa"}' >"$BADUTF_JSON_TASK"
HOOK_STDOUT="$(TASK_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" <"$BADUTF_JSON_TASK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "「A\\x80Task 3番」は不正バイトが境界を作っても発火しない"

# start_ts/end_tsが空（python3不在等）で計測できなかった場合や、awkの
# 出力が数値でない場合を「0秒=合格」に化けさせないためのガード（検証2巡目
# MINOR N-2）。$elapsed と $elapsed_ok を大域変数として設定する。呼び出し元は
# elapsed_ok=0 のときだけ elapsed の3.6秒未満判定を有効な結果として扱う。
compute_elapsed() {
  local ts_start="$1" ts_end="$2"
  elapsed=""
  elapsed_ok=1
  if [ -z "$ts_start" ] || [ -z "$ts_end" ]; then
    return
  fi
  elapsed="$(awk -v a="$ts_start" -v b="$ts_end" 'BEGIN{printf "%.2f", (b-a)}' 2>/dev/null)"
  case "$elapsed" in
    ''|*[!0-9.]*) elapsed="" ; return ;;
  esac
  elapsed_ok=0
}

echo "=== AC-72: LIST_CMD不在・非実行・非0終了・空出力・ハング2通り。孤児ゼロ・TMPDIRの一致も確認 ==="
run_hook "Task の3番" "$WORK_DIR/does-not-exist.sh"
assert_fail_silent "LIST_CMDが存在しないときは発火しない"

run_hook "Task の3番" "$NONEXEC_LIST_CMD"
assert_fail_silent "LIST_CMDに実行権限が無いときは発火しない"

FAIL_LIST_CMD="$WORK_DIR/cmux-task-watch-fail.sh"
cat >"$FAIL_LIST_CMD" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAIL_LIST_CMD"
run_hook "Task の3番" "$FAIL_LIST_CMD"
assert_fail_silent "LIST_CMDが非0で終わるときは発火しない"

EMPTY_LIST_CMD="$WORK_DIR/cmux-task-watch-empty.sh"
cat >"$EMPTY_LIST_CMD" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$EMPTY_LIST_CMD"
run_hook "Task の3番" "$EMPTY_LIST_CMD"
assert_fail_silent "LIST_CMDの出力が空のときは発火しない"

# ハングするLIST_CMD（判定用jqは正常）。TMPDIRをテスト専用にして実行前後の
# ファイル集合が一致することも見る（AC-72の一時ファイル集合の一致）。
HOOK_TMPDIR="$WORK_DIR/hook-tmpdir-hang-list"
mkdir -p "$HOOK_TMPDIR"
before_listing="$(ls -A "$HOOK_TMPDIR" 2>/dev/null | sort)"
rm -f "$HANG_PIDFILE"
start_ts=$(python3 -c 'import time;print(time.monotonic())')
json_input="$(jq -n --arg p "Task の3番" '{prompt:$p}')"
HOOK_STDOUT="$(printf '%s' "$json_input" | TMPDIR="$HOOK_TMPDIR" TASK_RESOLVE_LIST_CMD="$HANG_LIST_CMD" bash "$HOOK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
end_ts=$(python3 -c 'import time;print(time.monotonic())')
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
compute_elapsed "$start_ts" "$end_ts"
after_listing="$(ls -A "$HOOK_TMPDIR" 2>/dev/null | sort)"
orphan_alive=0
if [ -f "$HANG_PIDFILE" ]; then
  hang_pid="$(cat "$HANG_PIDFILE")"
  sleep 0.3
  if kill -0 "$hang_pid" 2>/dev/null; then
    orphan_alive=1
    kill -KILL "$hang_pid" 2>/dev/null
  fi
fi
if [ "$elapsed_ok" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ] \
   && awk -v e="$elapsed" 'BEGIN{exit !(e<3.6)}' && [ "$orphan_alive" -eq 0 ] \
   && [ "$before_listing" = "$after_listing" ]; then
  pass "ハングするLIST_CMDは3.6秒以内に打ち切られ孤児ゼロ・TMPDIR一致（実測 ${elapsed}s）"
else
  fail_case "ハングするLIST_CMDの打ち切り (実測 ${elapsed}s, elapsed_ok=$elapsed_ok, start_ts=[$start_ts] end_ts=[$end_ts], out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT orphan=$orphan_alive tmpdir_match=$([ "$before_listing" = "$after_listing" ] && echo yes || echo no))"
fi

# 最終のjq -nだけをハングさせるスタブ（引数で分岐。判定用jqは正常応答のまま
# にする必要がある＝全jqを止めると判定段で止まり最終段の締切を検査できない）。
HANGJQN_BIN="$WORK_DIR/hangjqn-bin"
mkdir -p "$HANGJQN_BIN"
REAL_JQ="$(command -v jq)"
cat >"$HANGJQN_BIN/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "-n" ]; then
    trap '' TERM
    sleep 30
    exit 0
  fi
done
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$HANGJQN_BIN/jq"
HOOK_TMPDIR2="$WORK_DIR/hook-tmpdir-hang-jqn"
mkdir -p "$HOOK_TMPDIR2"
before_listing2="$(ls -A "$HOOK_TMPDIR2" 2>/dev/null | sort)"
start_ts=$(python3 -c 'import time;print(time.monotonic())')
HOOK_STDOUT="$(printf '%s' "$json_input" | TMPDIR="$HOOK_TMPDIR2" PATH="$HANGJQN_BIN:$PATH" TASK_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
end_ts=$(python3 -c 'import time;print(time.monotonic())')
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
compute_elapsed "$start_ts" "$end_ts"
after_listing2="$(ls -A "$HOOK_TMPDIR2" 2>/dev/null | sort)"
if [ "$elapsed_ok" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ] \
   && awk -v e="$elapsed" 'BEGIN{exit !(e<3.6)}' && [ "$before_listing2" = "$after_listing2" ]; then
  pass "最終のjq -nだけがハングしても3.6秒以内に打ち切られTMPDIR一致（実測 ${elapsed}s）"
else
  fail_case "最終のjq -nだけがハングする場合の打ち切り (実測 ${elapsed}s, elapsed_ok=$elapsed_ok, start_ts=[$start_ts] end_ts=[$end_ts], out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT tmpdir_match=$([ "$before_listing2" = "$after_listing2" ] && echo yes || echo no))"
fi

echo "=== 正常系: 実行前後でTMPDIRのファイル集合が一致する（AC-72） ==="
HOOK_TMPDIR3="$WORK_DIR/hook-tmpdir-normal"
mkdir -p "$HOOK_TMPDIR3"
before_listing3="$(ls -A "$HOOK_TMPDIR3" 2>/dev/null | sort)"
HOOK_STDOUT="$(printf '%s' "$json_input" | TMPDIR="$HOOK_TMPDIR3" TASK_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
after_listing3="$(ls -A "$HOOK_TMPDIR3" 2>/dev/null | sort)"
if [ -n "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ] && [ "$before_listing3" = "$after_listing3" ]; then
  pass "正常系でも実行前後でTMPDIRのファイル集合が一致する"
else
  fail_case "正常系のTMPDIR一致 (out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT tmpdir_match=$([ "$before_listing3" = "$after_listing3" ] && echo yes || echo no))"
fi

echo "=== AC-73: 見出し文の完全一致（assert_injectedの中で検査済みだが単独でも確認） ==="
run_hook "Task の5番"
if [ -n "$HOOK_STDOUT" ]; then
  ctx="$(printf '%s' "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')"
  firstline="$(printf '%s' "$ctx" | head -1)"
  if [ "$firstline" = "$EXPECTED_HEADING" ]; then
    pass "見出し文が「${EXPECTED_HEADING}」と完全一致する"
  else
    fail_case "見出し文の完全一致 (firstline=[$firstline])"
  fi
else
  fail_case "見出し文の完全一致 (注入されなかった)"
fi

echo "=== AC-74a: 両フックの同時発火（見出しで区別。次にNext付きの後方互換版も） ==="
run_two_hooks() {
  local prompt="$1"
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
  PROJECT_STDOUT="$(printf '%s' "$json_input" | NEXT_RESOLVE_LIST_CMD="$STUB_PROJECT_LIST_CMD" bash "$OTHER_HOOK" 2>/dev/null)"
  PROJECT_EXIT=$?
  TASK_STDOUT="$(printf '%s' "$json_input" | TASK_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" 2>/dev/null)"
  TASK_EXIT=$?
}

assert_both_fire() {
  local desc="$1" prompt="$2"
  run_two_hooks "$prompt"
  if [ "$PROJECT_EXIT" -ne 0 ] || [ "$TASK_EXIT" -ne 0 ]; then
    fail_case "$desc (終了コードが0でない。project_exit=$PROJECT_EXIT task_exit=$TASK_EXIT)"
    return
  fi
  if [ -z "$PROJECT_STDOUT" ] || [ -z "$TASK_STDOUT" ]; then
    fail_case "$desc (片方または両方が注入されなかった。project=[$PROJECT_STDOUT] task=[$TASK_STDOUT])"
    return
  fi
  local project_ctx task_ctx project_head task_head
  project_ctx="$(printf '%s' "$PROJECT_STDOUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
  task_ctx="$(printf '%s' "$TASK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
  project_head="$(printf '%s' "$project_ctx" | head -1)"
  task_head="$(printf '%s' "$task_ctx" | head -1)"
  case "$project_head" in
    Project番号対応表*) : ;;
    *) fail_case "$desc (Project側の見出しがProject番号対応表で始まらない。head=[$project_head])"; return ;;
  esac
  case "$task_head" in
    Task番号対応表*) : ;;
    *) fail_case "$desc (Task側の見出しがTask番号対応表で始まらない。head=[$task_head])"; return ;;
  esac
  pass "$desc"
}

assert_both_fire "「Project の2番と Task の3番」は両方が注入する（AC-74a）" "Project の2番と Task の3番"
assert_both_fire "後方互換「Next Project の2番と Next Task の3番」も両方が注入する（AC-74a）" "Next Project の2番と Next Task の3番"

echo "=== AC-74b: 全角空白版でも同じ結果になる ==="
assert_both_fire "全角空白版「Next　Project の2番と Next　Task の3番」も両方が注入する（AC-74b）" "Next　Project の2番と Next　Task の3番"

echo "=== AC-76: bash 3.2互換の静的検査 ==="
if /bin/bash -n "$HOOK"; then
  pass "/bin/bash -n が通る（macOS bash 3.2互換）"
else
  fail_case "/bin/bash -n が通る（macOS bash 3.2互換）"
fi

echo "=== AC-75: 登録と配置の突合＋名称変更の伝播（静的検査） ==="

# ①settings.jsonのUserPromptSubmit配列で、task-pane-resolve.shがnext-pane-resolve.shの
# 直後にありtimeoutが5であること。
SETTINGS_JSON="$REPO_ROOT/claude/settings.json"
if jq -e '
  .hooks.UserPromptSubmit[0].hooks as $h
  | ($h | map(.command) | index("$HOME/.claude/hooks/next-pane-resolve.sh")) as $i
  | $i != null and ($h[$i+1].command == "$HOME/.claude/hooks/task-pane-resolve.sh") and ($h[$i+1].timeout == 5)
' "$SETTINGS_JSON" >/dev/null 2>&1; then
  pass "settings.jsonでtask-pane-resolve.shがnext-pane-resolve.shの直後にありtimeout=5である"
else
  fail_case "settings.jsonでtask-pane-resolve.shがnext-pane-resolve.shの直後にありtimeout=5である"
fi

if grep -qF '"statusMessage": "Task番号対応表を注入中"' "$SETTINGS_JSON"; then
  pass "settings.jsonにTask番号対応表を注入中のstatusMessageがある"
else
  fail_case "settings.jsonにTask番号対応表を注入中のstatusMessageがある"
fi

if grep -qF '"statusMessage": "Project番号対応表を注入中"' "$SETTINGS_JSON"; then
  pass "settings.jsonの①がProject番号対応表を注入中へ変わっている"
else
  fail_case "settings.jsonの①がProject番号対応表を注入中へ変わっている"
fi
if grep -qF 'Nextペイン番号対応表' "$SETTINGS_JSON"; then
  fail_case "settings.jsonに旧statusMessage（Nextペイン番号対応表を注入中）が残っていない"
else
  pass "settings.jsonに旧statusMessage（Nextペイン番号対応表を注入中）が残っていない"
fi

# ②install-main.shのlink行とchmod一覧。
INSTALL_MAIN="$REPO_ROOT/scripts/install-main.sh"
if grep -qF 'link claude/hooks/task-pane-resolve.sh "$HOME/.claude/hooks/task-pane-resolve.sh"' "$INSTALL_MAIN"; then
  pass "install-main.shにtask-pane-resolve.shのlink行がある"
else
  fail_case "install-main.shにtask-pane-resolve.shのlink行がある"
fi
if grep -qF '"$DIR/claude/hooks/task-pane-resolve.sh"' "$INSTALL_MAIN"; then
  pass "install-main.shのchmod一覧にtask-pane-resolve.shがある"
else
  fail_case "install-main.shのchmod一覧にtask-pane-resolve.shがある"
fi

# ③check-drift.shのSYMLINKS配列。
CHECK_DRIFT="$REPO_ROOT/scripts/check-drift.sh"
if grep -qF '"$HOME/.claude/hooks/task-pane-resolve.sh|$DIR/claude/hooks/task-pane-resolve.sh"' "$CHECK_DRIFT"; then
  pass "check-drift.shのSYMLINKS配列にtask-pane-resolve.shがある"
else
  fail_case "check-drift.shのSYMLINKS配列にtask-pane-resolve.shがある"
fi

# ④README.mdのhooks一覧2か所。
README="$REPO_ROOT/README.md"
readme_hits="$(grep -cF 'task-pane-resolve.sh' "$README" 2>/dev/null || true)"
if [ "${readme_hits:-0}" -ge 2 ]; then
  pass "README.mdのhooks一覧（英日）にtask-pane-resolve.shが2か所以上ある"
else
  fail_case "README.mdのhooks一覧にtask-pane-resolve.shが足りない (hits=$readme_hits)"
fi

# ②Q2-4の伝播＝READMEとcheck-drift.shのどちらにも「symlink [0-9]+ ?ファイル」の
# 形が1つも残っていないこと。
if grep -qE 'symlink[[:space:]]*[0-9]+ ?ファイル' "$README"; then
  fail_case "README.mdに「symlink N ?ファイル」の形が残っていない"
else
  pass "README.mdに「symlink N ?ファイル」の形が残っていない"
fi
if grep -qE 'symlink[[:space:]]*[0-9]+ ?ファイル' "$CHECK_DRIFT"; then
  fail_case "check-drift.shに「symlink N ?ファイル」の形が残っていない"
else
  pass "check-drift.shに「symlink N ?ファイル」の形が残っていない"
fi

# ⑤名称変更の伝播（肯定側と否定側を対で見る）。
if grep -qF 'Next Task' "$README" || grep -qF 'Next Project' "$README"; then
  fail_case "README.mdにNext Task／Next Projectが1つも残っていない"
else
  pass "README.mdにNext Task／Next Projectが1つも残っていない"
fi

BOOTSTRAP="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"
TEST_BOOTSTRAP="$REPO_ROOT/tests/test-bootstrap-vault.sh"
if grep -qF 'Dock の Task 枠' "$BOOTSTRAP" && ! grep -qF 'Dock の Next Task 枠' "$BOOTSTRAP"; then
  pass "bootstrap-vault.shに「Dock の Task 枠」があり「Dock の Next Task 枠」が無い"
else
  fail_case "bootstrap-vault.shの名称変更の伝播"
fi
if grep -qF 'Dock の Task 枠' "$TEST_BOOTSTRAP" && ! grep -qF 'Dock の Next Task 枠' "$TEST_BOOTSTRAP"; then
  pass "test-bootstrap-vault.shに「Dock の Task 枠」があり「Dock の Next Task 枠」が無い"
else
  fail_case "test-bootstrap-vault.shの名称変更の伝播"
fi

# ⑥tests/test-check-drift.shのフック列挙2か所＋固定件数3か所が14であること。
TEST_CHECK_DRIFT="$REPO_ROOT/tests/test-check-drift.sh"
hits="$(grep -cF 'task-pane-resolve.sh' "$TEST_CHECK_DRIFT" 2>/dev/null || true)"
if [ "${hits:-0}" -ge 2 ]; then
  pass "test-check-drift.shのフック列挙2か所以上にtask-pane-resolve.shがある"
else
  fail_case "test-check-drift.shのフック列挙にtask-pane-resolve.shが足りない (hits=$hits)"
fi
if grep -qF 'symlink総数: 14件 / drift: 0件' "$TEST_CHECK_DRIFT" \
   && grep -qF 'symlink総数: 14件 / drift: 14件' "$TEST_CHECK_DRIFT" \
   && grep -qF 'symlink総数: 14件 / drift: 1件' "$TEST_CHECK_DRIFT"; then
  pass "test-check-drift.shの固定件数3か所が14件に更新されている（期待文字列の一致）"
else
  fail_case "test-check-drift.shの固定件数3か所のいずれかが期待文字列と一致しない"
fi
if grep -qF 'symlink総数: 13件' "$TEST_CHECK_DRIFT"; then
  fail_case "test-check-drift.shに旧件数（13件）が残っていない"
else
  pass "test-check-drift.shに旧件数（13件）が残っていない"
fi

# ⑦tests/test-install-main.shのアサーション。
TEST_INSTALL_MAIN="$REPO_ROOT/tests/test-install-main.sh"
if grep -qF 'task-pane-resolve.sh' "$TEST_INSTALL_MAIN"; then
  pass "test-install-main.shにtask-pane-resolve.shのアサーションがある"
else
  fail_case "test-install-main.shにtask-pane-resolve.shのアサーションがある"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
