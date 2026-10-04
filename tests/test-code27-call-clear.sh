#!/usr/bin/env bash
# core/connect/claude-code/prompt-answer.sh（ライブ名 code27-call-clear.sh）のユニットテスト。
# v1.2 束 B（design-v1.md v1.3 §2.2 D-2）＝本人の入力の検知は Core の Claude Code 接続へ移り、
# 「応答」を知らせの共通部品（core/executor/notice.sh）へ渡すだけになる。共通部品は応答を
# 口（notify/executor/notify.sh）へ切り離して起動する（フックは待たず終了 0・標準出力は空）。
# 入力検知フック自身はもう CODE27_CALL_BIN を直接呼ばない＝取次を呼ぶのは CODE27 の送り手
# （notify/connect/code27/deliver.sh）で、CODE27_CALL_BIN はそちらが引き継ぐ（実装計画 §1）。
#
# 正本＝docs/v1.2-notify-install の要件 v1.3 §7 AC-4 ④・FX-25a〜c、設計 v1.3 §2.1〜§2.3。
#
# 実 ~/work/navi-orchestrator/code27-call・実 $HOME には一切依存しない。HOME は一時ディレクトリに
# 固定し、CODE27_CALL_BIN を偽の取次（呼ばれたら印を残すだけ）へ差し替えて、本物の台帳
# （$REPO_ROOT/core/data/ledger.tsv）＋本物の共通部品／口／CODE27 送り手を素通りさせる
# （知らせの中身の受け渡しは tests/test-notify.sh が別途見る＝ここでは入力検知の判定条件
# ＝応答するか・しないか・終了コード・標準出力だけを見る）。台帳異常の 3 ケース（FX-25a〜c）
# だけは AIENV_LEDGER を壊れた複製へ差し替えて見る。
#
# 実行方法: bash tests/test-code27-call-clear.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"
HOOK="$REPO_ROOT/core/connect/claude-code/prompt-answer.sh"
LEDGER_REAL="$REPO_ROOT/core/data/ledger.tsv"
BASH_BIN="$(command -v bash)"

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

# 隔離: 実 $HOME・実 code27-call には触れない（core-worker §5）。
export HOME="$WORK_DIR/home"
mkdir -p "$HOME"
NOTIFY_LOG_DEFAULT="$HOME/.claude/logs/notify.tsv"

STDERR_TMP="$WORK_DIR/stderr.tmp"
MARKER="$WORK_DIR/clear-called.log"

# 偽 CODE27 取次（FX-4・共有 fixture tests/fixtures/code27-call/・test-writer B 作成）＝
# 呼ばれたら印(1行)を残すだけ。実 code27-call には一切触れない。重複を避けるため
# tests/fixtures/ 配下の共有物を使う（README 参照）。
FAKE_CLEAR="$REPO_ROOT/tests/fixtures/code27-call/bin/code27-call-clear"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# 口（notice.sh の応答経路）は切り離して起動する＝フックの終了後に書く。即時には
# 観測できないため、短い間隔でポーリングする（上限 <timeout 秒>・実測は数十 ms 想定）。
wait_for() {  # wait_for <ファイル> <timeout秒>
  local f="$1" t="$2" i=0
  while [ "$i" -lt $((t * 10)) ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$f" ]
}

# フックへ生 stdin を渡して実行し、標準出力/標準エラー/終了コードをグローバル変数へ格納する。
# $1=stdin文字列 $2=CODE27_CALL_BIN（省略時は偽取次） $3=AIENV_LEDGER（省略時は本物の台帳）
run_hook_raw() {
  local stdin_text="$1" bin_path="${2:-$FAKE_CLEAR}" ledger="${3:-$LEDGER_REAL}" extra_path="${4:-}"
  rm -f "$MARKER"
  HOOK_STDOUT="$(printf '%s' "$stdin_text" \
    | CODE27_CALL_BIN="$bin_path" CODE27_CALL_LOG="$MARKER" AIENV_LEDGER="$ledger" PATH="${extra_path:+$extra_path:}$PATH" \
      bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

# UserPromptSubmit の実イベント形（本番 envelope）を jq で組み立てて渡す。
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

echo "=== a. 人の入力＝応答が 1 件届く（従来どおり・切り離し起動のため少し待つ） ==="
run_hook_prompt "聞こえた"
assert_hook_quick() {
  [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]
}
if assert_hook_quick; then pass "入口は終了0・標準出力は空（切り離して即終了＝design v1.3 §2.1）"
else fail_case "入口は終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
if wait_for "$MARKER" 3 && [ "$(grep -c . "$MARKER" 2>/dev/null || true)" = "1" ]; then
  pass "人の入力プロンプトで偽 CODE27 取次が1回呼ばれる（応答が届く）"
else
  fail_case "人の入力プロンプトで偽 CODE27 取次が1回呼ばれる (marker=$(cat "$MARKER" 2>/dev/null))"
fi

echo "=== b. 背景タスクの完了通知＝応答しない（全消去しない） ==="
run_hook_prompt "$(printf '<task-notification>\n<task-id>x</task-id>\n完了しました')"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then pass "終了0・標準出力は空"
else fail_case "終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
sleep 0.5
if [ ! -s "$MARKER" ]; then pass "<task-notification>で始まる入力では応答が届かない"
else fail_case "<task-notification>入力で応答が届いてはいけない (marker=$(cat "$MARKER"))"; fi

echo "=== c. stdin が空／JSON でない／jq が無い＝安全側（従来どおり応答する） ==="
run_hook_raw ""
if [ "$HOOK_EXIT" -eq 0 ] && wait_for "$MARKER" 3; then pass "stdinが空でも応答が届く（安全側）・終了0"
else fail_case "stdinが空 (exit=$HOOK_EXIT marker=$(cat "$MARKER" 2>/dev/null))"; fi

run_hook_raw "not-json"
if [ "$HOOK_EXIT" -eq 0 ] && wait_for "$MARKER" 3; then pass "stdinがJSONでなくても応答が届く（安全側）・終了0"
else fail_case "stdinが非JSON (exit=$HOOK_EXIT marker=$(cat "$MARKER" 2>/dev/null))"; fi

# jq を PATH から完全に除く（lib-ledger-fixtures.sh の共有ヘルパー＝含むディレクトリを
# 影のディレクトリへ置き換える。元の PATH を素通りで残すと jq が別の場所から見つかって
# しまい「jq 無し」を試験できないため）。
NO_JQ_PATH="$(lf_path_without jq)"
run_hook_raw_no_fallback() {
  local stdin_text="$1" bin_path="$2" ledger="$3" path="$4"
  rm -f "$MARKER"
  HOOK_STDOUT="$(printf '%s' "$stdin_text" \
    | CODE27_CALL_BIN="$bin_path" CODE27_CALL_LOG="$MARKER" AIENV_LEDGER="$ledger" PATH="$path" \
      "$BASH_BIN" "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}
run_hook_raw_no_fallback '{"prompt":"聞こえた"}' "$FAKE_CLEAR" "$LEDGER_REAL" "$NO_JQ_PATH"
if [ "$HOOK_EXIT" -eq 0 ] && wait_for "$MARKER" 3; then pass "jqが無くても応答が届く（安全側）・終了0"
else fail_case "jqが無い (exit=$HOOK_EXIT marker=$(cat "$MARKER" 2>/dev/null))"; fi

echo "=== FX-25a〜c（AC-4 ④）: 台帳の異常は入口を終了0・標準出力空のまま保ち、知らせの記録へ固定文1行だけ残す ==="
notify_log_tail_has() {  # notify_log_tail_has <grep対象>
  [ -f "$NOTIFY_LOG_DEFAULT" ] && tail -1 "$NOTIFY_LOG_DEFAULT" 2>/dev/null | grep -qF "$1"
}

echo "--- FX-25a: 台帳ファイルが無い ---"
rm -f "$NOTIFY_LOG_DEFAULT"
run_hook_prompt "聞こえた" "$FAKE_CLEAR" "$WORK_DIR/no-such-ledger.tsv"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then pass "FX-25a: 終了0・標準出力は空"
else fail_case "FX-25a: 終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
sleep 0.5
if notify_log_tail_has "LEDGER: ledger"; then pass "FX-25a: 知らせの記録に種別語 ledger の固定文が1行"
else fail_case "FX-25a: 知らせの記録に種別語 ledger の固定文が1行 (log=$(cat "$NOTIFY_LOG_DEFAULT" 2>/dev/null))"; fi

echo "--- FX-25b: 台帳の形式不正（列数不足の行1） ---"
BAD_LEDGER="$WORK_DIR/bad-format-ledger.tsv"
printf 'part\tnotify/executor/notify.sh\tnotify\n' > "$BAD_LEDGER"
rm -f "$NOTIFY_LOG_DEFAULT"
run_hook_prompt "聞こえた" "$FAKE_CLEAR" "$BAD_LEDGER"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then pass "FX-25b: 終了0・標準出力は空"
else fail_case "FX-25b: 終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
sleep 0.5
if notify_log_tail_has "LEDGER: ledger"; then pass "FX-25b: 知らせの記録に種別語 ledger の固定文が1行"
else fail_case "FX-25b: 知らせの記録に種別語 ledger の固定文が1行 (log=$(cat "$NOTIFY_LOG_DEFAULT" 2>/dev/null))"; fi

echo "--- VB-01 回帰: 台帳の形式不正（7列＝8列目「知らせ」が無い行）→ no-dest 等に化けず ledger の固定文のまま ---"
SHORT7_LEDGER="$WORK_DIR/short7-ledger.tsv"
printf 'part\tnotify/executor/notify.sh\tnotify\texecutor\t-\tnotify.send\t口\n' > "$SHORT7_LEDGER"
rm -f "$NOTIFY_LOG_DEFAULT"
run_hook_prompt "聞こえた" "$FAKE_CLEAR" "$SHORT7_LEDGER"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then pass "VB-01: 7列行＝終了0・標準出力は空"
else fail_case "VB-01: 7列行＝終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
sleep 0.5
if notify_log_tail_has "LEDGER: ledger"; then pass "VB-01: 7列行＝知らせの記録に種別語 ledger の固定文が1行（no-dest 等に化けない）"
else fail_case "VB-01: 7列行＝知らせの記録に種別語 ledger の固定文が1行 (log=$(cat "$NOTIFY_LOG_DEFAULT" 2>/dev/null))"; fi

echo "--- FX-25c: 口の行はあるがその実体が無い ---"
MISSING_LEDGER="$WORK_DIR/missing-part-ledger.tsv"
printf 'part\tnotify/executor/zz-missing-mouth.sh\tnotify\texecutor\t-\tnotify.send\t\t-\n' > "$MISSING_LEDGER"
rm -f "$NOTIFY_LOG_DEFAULT"
run_hook_prompt "聞こえた" "$FAKE_CLEAR" "$MISSING_LEDGER"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then pass "FX-25c: 終了0・標準出力は空"
else fail_case "FX-25c: 終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
sleep 0.5
if notify_log_tail_has "LEDGER: part"; then pass "FX-25c: 知らせの記録に種別語 part の固定文が1行"
else fail_case "FX-25c: 知らせの記録に種別語 part の固定文が1行 (log=$(cat "$NOTIFY_LOG_DEFAULT" 2>/dev/null))"; fi

echo "--- 追加ケース（AC-4 ④ test-writer 割当）: 台帳が実在するが読めない（権限） ---"
UNREADABLE_LEDGER="$WORK_DIR/unreadable-ledger.tsv"
cp "$LEDGER_REAL" "$UNREADABLE_LEDGER"
chmod 000 "$UNREADABLE_LEDGER"
rm -f "$NOTIFY_LOG_DEFAULT"
run_hook_prompt "聞こえた" "$FAKE_CLEAR" "$UNREADABLE_LEDGER"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then pass "読めない台帳: 終了0・標準出力は空"
else fail_case "読めない台帳: 終了0・標準出力は空 (exit=$HOOK_EXIT out=[$HOOK_STDOUT])"; fi
sleep 0.5
if notify_log_tail_has "LEDGER: ledger"; then pass "読めない台帳: 知らせの記録に種別語 ledger の固定文が1行"
else fail_case "読めない台帳: 知らせの記録に種別語 ledger の固定文が1行 (log=$(cat "$NOTIFY_LOG_DEFAULT" 2>/dev/null))"; fi
chmod 644 "$UNREADABLE_LEDGER"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
