#!/usr/bin/env bash
# claude/hooks/dock-pane-resolve.sh のユニットテスト（旧 test-next-pane-resolve.sh
# ＋ test-task-pane-resolve.sh を統合・2026-09-19 着手順5 σ・設計 §3.4）。
#
# 実 ~/.claude・実Vault・実cmuxには一切依存しない。フックへ渡すJSON入力
# （UserPromptSubmitフックの実際の呼び出し形式）をjqで組み立てて標準入力から
# 渡し、標準出力・標準エラー・終了コードの3点で判定する。`--list` を叩く先は
# NEXT_RESOLVE_LIST_CMD（Project側）／TASK_RESOLVE_LIST_CMD（Task側）で自前の
# スタブへ差し替える。
#
# テストはラフに（Decisions/2026-09-17-tests-rough-not-strict）＝経路ごとに
# 代表1〜2件。発火＝Project 2・Task 2・両方 1／非発火＝番なし・語境界3・
# 型検査・U+FFFD・NUL／fail-silent＝LIST_CMD不在・非実行・空出力・非0（Project側
# とTask側を代表1ずつ）＋両方発火で片方失敗はその表だけ落とす／deadline＝
# 遅いが打ち切らない・TERM無視ハングで孤児0＋TMPDIR集合一致・hook自身が
# SIGTERMで一時ファイルが残らない／bash 3.2静的。旧AC-75（他ファイルの文字列
# を見る静的結合）・AC-74b（全角空白版）・重複バリエーションは退役。
#
# 実行方法: bash tests/test-dock-pane-resolve.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/dock-pane-resolve.sh"

# mktemp -d の失敗・異常な返り値を即検査する（空・`/`・既存の非空ディレクトリ
# を拒否してからtrapの `rm -rf "$WORK_DIR"` へ進む）。
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

# --list スタブ（Project側・cmux-next-model.sh --list 相当・v5・5列TSV＝番号・
# 正式プロジェクト名・next値・区分（稼働中／待ち／保留）・待ち日時）。行は
# 要件 v5 AC-135 の 5 行そのまま（AC-145・AC-147 の注記＝5列）。
PROJECT_STUB="$WORK_DIR/cmux-next-model-stub.sh"
cat >"$PROJECT_STUB" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tp-active\t次を進める\t稼働中\t\n'
  printf '2\tp-past\t返答を反映\t稼働中\t\n'
  printf '3\tp-wait\t返事待ち\t待ち\t2026-09-25T10:00\n'
  printf '4\tp-waitday\t再開\t待ち\t2026-09-25T00:00\n'
  printf '5\tp-paused\t\t保留\t\n'
fi
EOF
chmod +x "$PROJECT_STUB"

# --list スタブ（Task側・cmux-task-model.sh --list 相当・v4・5列TSV）。
TASK_STUB="$WORK_DIR/cmux-task-model-stub.sh"
cat >"$TASK_STUB" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tv2\t1/3\t[x]\t要件定義\n'
  printf '1\tv2\t1/3\t[ ]\t実装\n'
fi
EOF
chmod +x "$TASK_STUB"

# 存在するが実行権限の無いスタブ（[ -x ] チェックの回帰確認用）。
NONEXEC_STUB="$WORK_DIR/noexec.sh"
printf '#!/bin/bash\nprintf "1\\tx\\ty\\tz\\n"\n' >"$NONEXEC_STUB"
chmod -x "$NONEXEC_STUB"

EMPTY_STUB="$WORK_DIR/empty.sh"
printf '#!/bin/bash\nexit 0\n' >"$EMPTY_STUB"
chmod +x "$EMPTY_STUB"

FAIL_STUB="$WORK_DIR/fail.sh"
printf '#!/bin/bash\nexit 1\n' >"$FAIL_STUB"
chmod +x "$FAIL_STUB"

# 正常だが遅い（0.6秒）スタブ＝budget=2の内側なので打ち切られないはず。
SLOW_OK_STUB="$WORK_DIR/slow-ok.sh"
cat >"$SLOW_OK_STUB" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  sleep 0.6
  printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
fi
EOF
chmod +x "$SLOW_OK_STUB"

# TERMを無視してハングするスタブ。子（sleep）のPIDをファイルへ書かせ、
# hook終了後に `kill -0` で直接生死を確認する（孤児検査）。
IGNORE_TERM_STUB="$WORK_DIR/ignore-term.sh"
IGNORE_TERM_PIDFILE="$WORK_DIR/ignore-term-child.pid"
cat >"$IGNORE_TERM_STUB" <<EOF
#!/bin/bash
trap '' TERM
if [ "\$1" = "--list" ]; then
  sleep 8 &
  echo \$! >"$IGNORE_TERM_PIDFILE"
  wait
  printf '1\tv2\t1/3\t[x]\t要件定義\n'
fi
EOF
chmod +x "$IGNORE_TERM_STUB"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# フックへ生JSON入力を渡し、標準出力/標準エラー/終了コードをグローバル
# 変数（HOOK_STDOUT/HOOK_STDERR/HOOK_EXIT）へ格納する。
# $2=Project側LIST_CMD・$3=Task側LIST_CMD（省略時は正常スタブ）。
run_hook_raw() {
  local json_input="$1" project_cmd="${2:-$PROJECT_STUB}" task_cmd="${3:-$TASK_STUB}"
  HOOK_STDOUT="$(printf '%s' "$json_input" | NEXT_RESOLVE_LIST_CMD="$project_cmd" TASK_RESOLVE_LIST_CMD="$task_cmd" bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

# フックへプレーンテキストのpromptを渡す（本番のUserPromptSubmit envelope＝
# session_id等を含む形に組み立てる。promptだけのfixtureだと`.prompt`以外の
# キーの有無で分岐する変異を検出できないため）。
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

assert_no_injection() {
  local desc="$1" prompt="$2"
  run_hook "$prompt"
  assert_fail_silent "$desc"
}

PROJECT_HEADING='Project番号対応表（この瞬間の表示順。ユーザーの「Project の N 番」はこの表で解決する。列＝番号・正式プロジェクト名・next 値・区分（稼働中／待ち／保留）・待ち日時（待ちの行だけ YYYY-MM-DDTHH:MM・他は空））:'
TASK_HEADING='Task番号対応表（番号は版を指す・この瞬間の表示順。ユーザーの「Task の N 番」は同じ番号の行の版で解決する。列＝番号・版名・分数・状態・本文）:'

# 直前の run_hook の結果を検査し、additionalContext を大域変数 CTX に置く。
# 戻り値 0＝正常JSON。失敗時は fail_case 済み。
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

# 片側だけの注入＝見出し固定文で始まり（完全一致）、--list出力を含み、
# もう片方の見出しを含まない。$3=project|task。
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
assert_injected_side "「プロジェクトの3番」はProject表だけ注入（直後の平仮名助詞は複合語扱いしない）" "プロジェクトの3番" project

echo "=== 2. 発火（Task側） ==="
assert_injected_side "「Task の3番」はTask表だけ注入" "Task の3番" task
assert_injected_side "「タスクの3番」はTask表だけ注入" "タスクの3番" task

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

echo "=== 4. 非発火（番なし・語境界・型検査・U+FFFD・NUL・不正JSON） ==="
assert_no_injection "「プロジェクトを確認して」は発火しない（番が無い）" "プロジェクトを確認して"
assert_no_injection "「Projects の 3 番」は発火しない（英語側の語境界＝複数形の一部）" "Projects の 3 番"
assert_no_injection "「Aプロジェクト 3番」は発火しない（日本語側にもASCII英数字の境界）" "Aプロジェクト 3番"
assert_no_injection "「タスク化 3番」は発火しない（直後の漢字＝複合語の一部）" "タスク化 3番"
run_hook_raw '{"prompt":{"text":"Project 3番と Task 3番"}}'
assert_fail_silent "prompt がobject型のときは発火しない"
# jqは不正バイトをU+FFFDへ変換して読み進めるため、不正バイトが本来無関係な
# 位置に語境界を作り過剰発火しうる。U+FFFDを含むpromptは判定に使わない。
BADUTF_JSON="$WORK_DIR/bad-utf8.json"
printf '{"prompt":"A\x80Project 3\xe7\x95\xaa"}' >"$BADUTF_JSON"
HOOK_STDOUT="$(NEXT_RESOLVE_LIST_CMD="$PROJECT_STUB" TASK_RESOLVE_LIST_CMD="$TASK_STUB" bash "$HOOK" <"$BADUTF_JSON" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "「A\\x80Project 3番」は不正バイトが境界を作っても発火しない（U+FFFD検査）"
run_hook_raw '{"prompt":"Pro\\u0000ject 3番"}'
assert_fail_silent "「Pro\\u0000ject 3番」はNULで語が分断され発火しない（bash変数を経由しない）"
run_hook_raw 'not-json'
assert_fail_silent "不正JSON入力のときは発火しない"

echo "=== 5. fail-silent（LIST_CMD不在・非実行・空出力・非0）＝Project側・Task側の代表 ==="
run_hook "Project の2番" "$WORK_DIR/does-not-exist.sh" "$TASK_STUB"
assert_fail_silent "Project側LIST_CMDが存在しないときは発火しない"
run_hook "Task の3番" "$PROJECT_STUB" "$NONEXEC_STUB"
assert_fail_silent "Task側LIST_CMDに実行権限が無いときは発火しない"
run_hook "Project の2番" "$EMPTY_STUB" "$TASK_STUB"
assert_fail_silent "Project側LIST_CMDの出力が空のときは発火しない"
run_hook "Task の3番" "$PROJECT_STUB" "$FAIL_STUB"
assert_fail_silent "Task側LIST_CMDが非0で終わるときは発火しない"

echo "=== 5b. 両方発火で片方が失敗＝その表だけ落とし、もう片方だけ出す ==="
run_hook "Project の2番と Task の3番" "$PROJECT_STUB" "$FAIL_STUB"
if extract_ctx "Task側だけ失敗"; then
  if [ "$(printf '%s' "$CTX" | head -1)" = "$PROJECT_HEADING" ] && ! printf '%s' "$CTX" | grep -qF "$TASK_HEADING"; then
    pass "Task側の--listが失敗してもProject表だけは注入される"
  else
    fail_case "Task側だけ失敗のときProject表だけ (ctx=[$CTX])"
  fi
fi
run_hook "Project の2番と Task の3番" "$WORK_DIR/does-not-exist.sh" "$TASK_STUB"
if extract_ctx "Project側だけ失敗"; then
  if [ "$(printf '%s' "$CTX" | head -1)" = "$TASK_HEADING" ] && ! printf '%s' "$CTX" | grep -qF "$PROJECT_HEADING"; then
    pass "Project側のLIST_CMDが不在でもTask表だけは注入される"
  else
    fail_case "Project側だけ失敗のときTask表だけ (ctx=[$CTX])"
  fi
fi
run_hook "Project の2番と Task の3番" "$EMPTY_STUB" "$FAIL_STUB"
assert_fail_silent "両方失敗のときは無出力・exit 0"

echo "=== 6. deadline（正常だが遅い処理は打ち切らない・ハングは打ち切り孤児0・TMPDIR集合一致） ==="
start_ts=$(date +%s)
run_hook "Project 3番" "$SLOW_OK_STUB" "$TASK_STUB"
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
if [ "$elapsed" -le 3 ] && [ -n "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "0.6秒で正常終了するLIST_CMD（budget=2）は打ち切られず発火する（実測 ${elapsed}s）"
else
  fail_case "0.6秒で正常終了するLIST_CMDは打ち切られず発火する (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
fi

# TERMを無視するハング（Task側）。TMPDIRをテスト専用にして実行前後の集合が
# 一致することも見る。片側発火なので上限は判定1.3＋表2.3＝3.6秒程度。
HOOK_TMPDIR="$WORK_DIR/hook-tmpdir-hang"
mkdir -p "$HOOK_TMPDIR"
before_listing="$(ls -A "$HOOK_TMPDIR" 2>/dev/null | sort)"
rm -f "$IGNORE_TERM_PIDFILE"
json_input="$(jq -n --arg p "Task の3番" '{prompt:$p}')"
start_ts=$(date +%s)
HOOK_STDOUT="$(printf '%s' "$json_input" | TMPDIR="$HOOK_TMPDIR" NEXT_RESOLVE_LIST_CMD="$PROJECT_STUB" TASK_RESOLVE_LIST_CMD="$IGNORE_TERM_STUB" bash "$HOOK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
end_ts=$(date +%s)
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
elapsed=$((end_ts - start_ts))
after_listing="$(ls -A "$HOOK_TMPDIR" 2>/dev/null | sort)"
sleep 0.3
if [ ! -f "$IGNORE_TERM_PIDFILE" ]; then
  fail_case "SIGTERMを無視するLIST_CMDの子孫検査 (PIDファイルが作られなかった＝スタブが起動できていない可能性)"
else
  child_pid="$(cat "$IGNORE_TERM_PIDFILE")"
  if kill -0 "$child_pid" 2>/dev/null; then
    fail_case "SIGTERMを無視するLIST_CMDも打ち切られ子孫も残らない (子プロセス pid=$child_pid がまだ生きている＝孤児化)"
    kill -KILL "$child_pid" 2>/dev/null
  elif [ "$elapsed" -le 4 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ] \
       && [ "$before_listing" = "$after_listing" ]; then
    pass "SIGTERMを無視するLIST_CMDも打ち切られ、子孫(pid=$child_pid)も残らず、TMPDIRの集合が一致する（実測 ${elapsed}s）"
  else
    fail_case "SIGTERMを無視するLIST_CMDの打ち切り (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT tmpdir_match=$([ "$before_listing" = "$after_listing" ] && echo yes || echo no))"
  fi
fi

# 判定用jqをハングさせ、hook起動直後にhookプロセス自身へSIGTERMを送る。
# mktempが作る一時ファイルがhook終了後に残っていないかを直接検査する。
HOOK_TMPDIR2="$WORK_DIR/hook-tmpdir-sigterm"
mkdir -p "$HOOK_TMPDIR2"
HANGJQ_BIN="$WORK_DIR/hangjq-bin"
mkdir -p "$HANGJQ_BIN"
printf '#!/bin/bash\ntrap "" TERM\nsleep 30\n' >"$HANGJQ_BIN/jq"
chmod +x "$HANGJQ_BIN/jq"
json_input="$(jq -n --arg p "Project 3番" '{prompt:$p}')"
printf '%s' "$json_input" | TMPDIR="$HOOK_TMPDIR2" PATH="$HANGJQ_BIN:$PATH" NEXT_RESOLVE_LIST_CMD="$PROJECT_STUB" TASK_RESOLVE_LIST_CMD="$TASK_STUB" bash "$HOOK" >"$WORK_DIR/sigterm-hook.out" 2>"$WORK_DIR/sigterm-hook.err" &
sigterm_hook_pid=$!
sleep 0.2
kill -TERM "$sigterm_hook_pid" 2>/dev/null
wait "$sigterm_hook_pid" 2>/dev/null
sleep 0.3
sigterm_out="$(cat "$WORK_DIR/sigterm-hook.out" 2>/dev/null)"
sigterm_err="$(cat "$WORK_DIR/sigterm-hook.err" 2>/dev/null)"
leftover_count="$(ls -A "$HOOK_TMPDIR2" 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$sigterm_out" ] && [ -z "$sigterm_err" ] && [ "$leftover_count" -eq 0 ]; then
  pass "hook自身がSIGTERMで終了しても一時ファイルが残らない（無出力・stderrなし）"
else
  fail_case "hook自身がSIGTERMで終了しても一時ファイルが残らない (out=[$sigterm_out] err=[$sigterm_err] leftover=$leftover_count)"
fi

echo "=== v5. AC-145: 5列スタブの逐語注入（待ち行と第5列が落ちない）・Project見出し固定文 ==="
run_hook "Project の 3 番"
if extract_ctx "v5_ac145_verbatim_5cols"; then
  v5_expected="$(printf '1\tp-active\t次を進める\t稼働中\t\n2\tp-past\t返答を反映\t稼働中\t\n3\tp-wait\t返事待ち\t待ち\t2026-09-25T10:00\n4\tp-waitday\t再開\t待ち\t2026-09-25T00:00\n5\tp-paused\t\t保留\t')"
  v5_body="$(printf '%s\n' "$CTX" | sed -n '2,6p')"
  if [ "$v5_body" = "$v5_expected" ]; then
    pass "v5_ac145_verbatim_5cols: 注入文の 2〜6 行目が AC-135 の 5 行と逐語一致（TAB・空の第5列を含む）"
  else
    fail_case "v5_ac145_verbatim_5cols (body=[$v5_body])"
  fi
  if [ "$(printf '%s' "$CTX" | head -1)" = "$PROJECT_HEADING" ] \
     && printf '%s' "$PROJECT_HEADING" | grep -q '番号' && printf '%s' "$PROJECT_HEADING" | grep -q 'next' \
     && printf '%s' "$PROJECT_HEADING" | grep -q '区分（稼働中／待ち／保留）' && printf '%s' "$PROJECT_HEADING" | grep -q '待ち日時'; then
    pass "v5_ac145_project_heading: Project 見出し固定文に列の説明（番号・名前・next・区分 3 値・待ち日時）が入る"
  else
    fail_case "v5_ac145_project_heading (firstline=[$(printf '%s' "$CTX" | head -1)])"
  fi
fi

echo "=== v5_ac147_stub_note_5cols: Project側スタブの注記が 5 列（AC-147・静的） ==="
# スタブ定義の直前の注記（`# --list スタブ（Project側`〜`PROJECT_STUB=` の前）に 5 列の説明が残ること。
stub_note="$(sed -n '/^# --list スタブ（Project側/,/^PROJECT_STUB=/p' "$TESTS_DIR/test-dock-pane-resolve.sh" | grep '^#')"
ac147_ok=1
for word in "5列" "番号" "正式プロジェクト名" "next値" "区分（稼働中／待ち／保留）" "待ち日時"; do
  printf '%s\n' "$stub_note" | grep -qF -- "$word" || { ac147_ok=0; echo "  missing: $word"; }
done
if [ "$ac147_ok" -eq 1 ] && [ -n "$stub_note" ]; then
  pass "v5_ac147_stub_note_5cols: スタブ注記に 5列・番号・正式プロジェクト名・next値・区分（稼働中／待ち／保留）・待ち日時 がある"
else
  fail_case "v5_ac147_stub_note_5cols (note=[$stub_note])"
fi

echo "=== 7. bash 3.2 互換の静的検査 ==="
if /bin/bash -n "$HOOK"; then
  pass "/bin/bash -n が通る（macOS bash 3.2 互換）"
else
  fail_case "/bin/bash -n が通る（macOS bash 3.2 互換）"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
