#!/usr/bin/env bash
# Codex 直叩き柵（Team 接続／Claude Code・PreToolUse Bash）のテスト（Team）。
# tests/test-bash-danger-gate.sh から ③ の節（旧 3〜9。番号は旧のまま）を移し替えた（由来＝分割元。
# v1.1 設計 v1.2 §4.3・§5.2・§5.6、実装計画 §8）。③ の判定の経緯（レビュー 1〜9 巡目）は
# team/connect/claude-code/codex_direct_call_check.py の docstring と分割前の test-bash-danger-gate.sh の履歴を参照。
#
# 実行方法: bash tests/test-codex-direct-call-gate.sh
#
# 契約（テストが決めた口。台帳・台帳ツールの口は tests/test-ledger.sh 冒頭の契約と同じ）:
#   柵   team/connect/claude-code/codex-direct-call-gate.sh。stdin＝{"tool_input":{"command":…}[,"cwd":…]}。
#        常に exit 0。deny は stdout の JSON（permissionDecision＝deny）、allow は無出力（分割前と同じ）。
#   許可するラッパー＝台帳の鍵 team.codex-exec を lookup で引いたもの（上書き口 AIENV_LEDGER）。
#     全部入りの deny 文＝分割前の文の team/connect/codex/codex-exec.sh を新パス team/connect/codex/codex-exec.sh に置き換えたもの。
#     鍵なし＝ラッパー無し＝直叩きは deny（fail-close）。
#     台帳異常・実体異常＝deny（fail-close）し、deny 文に照会の固定文（LEDGER: ledger …／LEDGER: part team.codex-exec …）を
#     添え、同じ固定文を stderr へも出す。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/team/connect/claude-code/codex-direct-call-gate.sh"
LEDGER="$REPO_ROOT/core/data/ledger.tsv"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# フックへJSON入力を渡して標準出力を返す（stderr は $WORK/hook.err）。第2引数 cwd を渡すと PreToolUse
# の共通入力フィールド cwd を模して渡す。
run_hook() {
  local cmd="$1" cwd="${2:-}"
  jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd}} + (if $cwd=="" then {} else {cwd:$cwd} end)' | bash "$HOOK" 2>"$WORK/hook.err"
}

assert_allowed() {
  local desc="$1" cmd="$2" cwd="${3:-}" out
  out="$(run_hook "$cmd" "$cwd")"
  if [ -z "$out" ] && [ -f "$HOOK" ]; then
    pass "$desc"
  else
    fail_case "$desc (denyされてしまった／柵が無い。cmd=[$cmd] out=[$out])"
  fi
}

# reason_substr を指定すると、denyの理由文にその部分文字列が含まれることまで確認する。
assert_denied() {
  local desc="$1" cmd="$2" reason_substr="${3:-}" cwd="${4:-}" out
  out="$(run_hook "$cmd" "$cwd")"
  if ! printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    fail_case "$desc (denyされなかった。cmd=[$cmd] out=[$out])"
    return
  fi
  if [ -n "$reason_substr" ] && ! printf '%s' "$out" | grep -qF "$reason_substr"; then
    fail_case "$desc (denyされたが想定と別ルールが発火した可能性。cmd=[$cmd] out=[$out])"
    return
  fi
  pass "$desc"
}

RULE3_REASON='team/connect/codex/codex-exec.sh 経由のみ'

assert_denied "codex exec 直叩きはdeny" \
  "codex exec --skip-git-repo-check -s read-only -C /tmp --json -o /tmp/out.md 'hello'" "$RULE3_REASON"
assert_denied "execの別名 e もdeny" \
  "codex e --sandbox read-only 'hi'" "$RULE3_REASON"
assert_denied "トップレベル codex resume の直叩きもdeny" \
  "codex resume --last" "$RULE3_REASON"
assert_denied "直後に無関係な echo codex-exec.sh を混ぜてもdeny（複合コマンドの別断片）" \
  "codex exec --sandbox read-only 'hi'; echo codex-exec.sh" "$RULE3_REASON"
assert_denied "codex-exec.shを同一断片内の無関係な引数（--out）に混ぜてもdeny" \
  "codex exec task --out /tmp/codex-exec.sh" "$RULE3_REASON"
assert_denied "サブコマンドが引用符の後に来る正当なCLI構文（codex -c '...' exec）もdeny" \
  "codex -c 'model_reasoning_effort=high' exec task" "$RULE3_REASON"
assert_denied "-- 終端記法の後の --help は実際にはプロンプト文字列なのでdeny" \
  "codex exec -- --help" "$RULE3_REASON"
assert_denied "エスケープされた二重引用符（\\\"）で引用区間の対応がずれてもdeny" \
  'codex -c "developer_instructions=a\"b" exec "run task"' "$RULE3_REASON"
assert_denied "行継続のバックスラッシュ+改行を挟んでもdeny（挿入した区切り文字がエスケープされないこと）" \
  "$(printf 'echo safe; \\\ncodex exec task')" "$RULE3_REASON"
assert_denied "1行目の行末コメントが2行目のcodex execまで飲み込んでしまわないこと" \
  "$(printf 'echo safe # comment\ncodex exec task')" "$RULE3_REASON"
assert_denied "単語の途中にある#（foo#bar）以降を誤ってコメント扱いして消さないこと" \
  "echo foo#bar; codex exec task" "$RULE3_REASON"
assert_denied "サブシェルで囲んだ直接実行（( codex exec 'hi' )）もdeny" \
  "( codex exec 'hi' )" "$RULE3_REASON"
assert_allowed "ラッパー経由の基本呼び出しはallow" \
  "bash ~/Workspace/Tools/takumi009-ai-env/team/connect/codex/codex-exec.sh --cwd /tmp --sandbox read-only --out /tmp/out.md --prompt-file -"
assert_allowed "codex exec --help はallow" "codex exec --help"
export AIENV_LEDGER="$WORK/no-such-dir/ledger.tsv"
assert_denied "台帳異常: codex exec 直叩きはdeny・deny 文に LEDGER: ledger" "codex exec --sandbox read-only 'hi'" "LEDGER: ledger "
unset AIENV_LEDGER

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
