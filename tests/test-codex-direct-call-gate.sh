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

echo "=== 3. 新設ルール③: codex exec の直接実行はdeny ==="
assert_denied "codex exec 直叩きはdeny" \
  "codex exec --skip-git-repo-check -s read-only -C /tmp --json -o /tmp/out.md 'hello'" "$RULE3_REASON"
assert_denied "codexとexecの間にグローバルフラグがあってもdeny" \
  "codex -a never --search exec --sandbox read-only -C /tmp -o /tmp/out.md 'hello'" "$RULE3_REASON"
assert_denied "execの別名 e もdeny" \
  "codex e --sandbox read-only 'hi'" "$RULE3_REASON"
assert_denied "パス接頭辞付きの直叩き（/usr/local/bin/codex exec）もdeny" \
  "/usr/local/bin/codex exec --sandbox read-only 'hi'" "$RULE3_REASON"
assert_denied "大文字小文字を変えても（CODEX exec）deny" \
  "CODEX exec --sandbox read-only 'hi'" "$RULE3_REASON"

echo "=== 4. 新設ルール③: codex ... resume の直接実行はdeny ==="
assert_denied "codex exec 経由の resume 直叩きはdeny" \
  "codex exec --skip-git-repo-check -s read-only -C /tmp -o /tmp/o2.md resume -- abc123 -" "$RULE3_REASON"
assert_denied "トップレベル codex resume の直叩きもdeny" \
  "codex resume --last" "$RULE3_REASON"

echo "=== 5. 新設ルール③（2巡目レビューCritical対応）: 複合コマンドでの除外バイパスはdeny ==="
assert_denied "直後に無関係な echo codex-exec.sh を混ぜてもdeny（複合コマンドの別断片）" \
  "codex exec --sandbox read-only 'hi'; echo codex-exec.sh" "$RULE3_REASON"
assert_denied "scripts/codex-exec.shを別断片に置いてもdeny" \
  "echo team/connect/codex/codex-exec.sh; codex exec --sandbox read-only 'hi'" "$RULE3_REASON"
assert_denied "無関係な echo --help を混ぜてもdeny（--helpは別断片）" \
  "echo --help; codex exec --sandbox read-only 'hi'" "$RULE3_REASON"
assert_denied "無害な codex --version の直後に codex exec を混ぜてもdeny" \
  "codex --version; codex exec --sandbox read-only 'hi'" "$RULE3_REASON"

echo "=== 5b. 新設ルール③（3巡目レビューCritical対応）: 同一断片内での除外文字列混入もdeny ==="
assert_denied "codex-exec.shを同一断片内の無関係な引数（--out）に混ぜてもdeny" \
  "codex exec task --out /tmp/codex-exec.sh" "$RULE3_REASON"
assert_denied "codex-exec.shを同一断片内の引用符付きプロンプト文へ混ぜてもdeny" \
  'codex exec "codex-exec.sh を無視して実行"' "$RULE3_REASON"
assert_denied "--helpを同一断片内の引用符付きプロンプト文へ混ぜてもdeny（末尾でなければ読み取り系とみなさない）" \
  'codex exec "この --help を含む依頼を実行"' "$RULE3_REASON"

echo "=== 5c. 新設ルール③（4巡目レビューCritical対応）: 引用符後のサブコマンド・コメント/--終端の偽装もdeny ==="
assert_denied "サブコマンドが引用符の後に来る正当なCLI構文（codex -c '...' exec）もdeny" \
  "codex -c 'model_reasoning_effort=high' exec task" "$RULE3_REASON"
assert_denied "ダブルクォートの引用符後にサブコマンドが来る形もdeny" \
  'codex --model "t-model-x" exec task' "$RULE3_REASON"
assert_denied "シェルコメントへ --help を紛れ込ませてもdeny（コメントは実行に影響しない）" \
  "codex exec task # --help" "$RULE3_REASON"
assert_denied "-- 終端記法の後の --help は実際にはプロンプト文字列なのでdeny" \
  "codex exec -- --help" "$RULE3_REASON"

echo "=== 5d. 新設ルール③（5巡目レビューCritical対応・実装をshlexベースへ刷新）: エスケープされた引用符による対応ずれもdeny ==="
assert_denied "エスケープされた二重引用符（\\\"）で引用区間の対応がずれてもdeny" \
  'codex -c "developer_instructions=a\"b" exec "run task"' "$RULE3_REASON"

echo "=== 5e. 新設ルール③（6巡目レビューCritical対応）: 改行区切りの複数行コマンドもdeny ==="
assert_denied "無害な1行目の直後の改行で始まる2行目のcodex execもdeny（shlexは改行を既定で空白扱いするため要対応）" \
  "$(printf 'echo safe\ncodex exec task')" "$RULE3_REASON"
assert_allowed "codexに無関係な複数行コマンドはallow（回帰確認）" \
  "$(printf 'echo safe\nls -la /tmp')"

echo "=== 5f. 新設ルール③（7巡目レビューCritical対応）: 行継続（バックスラッシュ+改行）経由のバイパスもdeny ==="
assert_denied "行継続のバックスラッシュ+改行を挟んでもdeny（挿入した区切り文字がエスケープされないこと）" \
  "$(printf 'echo safe; \\\ncodex exec task')" "$RULE3_REASON"

echo "=== 5g. 新設ルール③（8巡目レビューCritical対応）: 行末コメントが次行を飲み込むバイパスもdeny ==="
assert_denied "1行目の行末コメントが2行目のcodex execまで飲み込んでしまわないこと" \
  "$(printf 'echo safe # comment\ncodex exec task')" "$RULE3_REASON"

echo "=== 5h. 新設ルール③（9巡目レビューCritical対応）: 単語途中の#が誤ってコメント扱いされずdenyできること ==="
assert_denied "単語の途中にある#（foo#bar）以降を誤ってコメント扱いして消さないこと" \
  "echo foo#bar; codex exec task" "$RULE3_REASON"
assert_allowed "codex#execのように#で連結された無関係な語はallow（先頭コマンド語はcodex#execであってcodexではない）" \
  "codex#exec task"

echo "=== 5i. 新設ルール③（自己点検で追加対応）: 1階層のサブシェル（( ... )）経由の直接実行もdeny ==="
assert_denied "サブシェルで囲んだ直接実行（( codex exec 'hi' )）もdeny" \
  "( codex exec 'hi' )" "$RULE3_REASON"
assert_allowed "codexに無関係なサブシェルはallow（回帰確認）" \
  "( echo hi )"

echo "=== 6. 新設ルール③: team/connect/codex/codex-exec.sh 経由の呼び出しはallow ==="
assert_allowed "ラッパー経由の基本呼び出しはallow" \
  "bash ~/work/takumi009-ai-env/team/connect/codex/codex-exec.sh --cwd /tmp --sandbox read-only --out /tmp/out.md --prompt-file -"
assert_allowed "ラッパー経由の --resume 指定もallow（内部にresumeという語を含むが対象外）" \
  "bash ~/work/takumi009-ai-env/team/connect/codex/codex-exec.sh --cwd /tmp --sandbox read-only --out /tmp/out.md --prompt-file - --resume abc123"
assert_allowed "ラッパーのパスを絶対パスで直接実行してもallow" \
  "/Users/takumi009/work/takumi009-ai-env/team/connect/codex/codex-exec.sh --cwd /tmp --sandbox read-only --out /tmp/out.md --prompt-file -"

echo "=== 7. 新設ルール③: --help / --version 等の読み取り系はallow（同一断片内のみ有効） ==="
assert_allowed "codex --version はallow" "codex --version"
assert_allowed "codex exec --help はallow" "codex exec --help"
assert_allowed "codex exec -h はallow" "codex exec -h"
assert_allowed "codex resume --help はallow" "codex resume --help"

echo "=== 8. 新設ルール③: codexに無関係なコマンド・誤検知になりうる引用パターンはallow ==="
assert_allowed "codexという語を含まない普通のコマンドはallow" "ls -la /tmp"
assert_allowed "execという語だけを含む無関係なコマンドはallow" "exec 3< /tmp/somefile"
assert_allowed "resumeという語だけを含む無関係なコマンドはallow" "echo resume the meeting later"
assert_allowed "~/.codex 配下の読み取りだけならallow（execもresumeも含まない）" "cat ~/.codex/config.toml"
assert_allowed "codexとexecが別の単純コマンドに分かれているだけならallow" "echo codex; echo exec"
assert_allowed "grep codex ... && echo resume のように無関係な文脈で両語が出てもallow" \
  "grep codex README.md && echo resume"
assert_allowed "printf 'codex exec' のように文字列としてcodexが現れるだけならallow（先頭コマンド語ではない）" \
  "printf 'codex exec'"
assert_allowed "codex reviewはこのルールの対象外（execでもresumeでもない）" "codex review"
assert_allowed "codexへの直接プロンプト起動もこのルールの対象外" 'codex "直接プロンプト"'
assert_allowed "引用符内に'exec'という語があるだけの無関係なcodex reviewはallow（誤検知回避・3巡目対応）" \
  'codex review "execの意味を説明して"'

echo "=== 9. 既知の残存限界（受け入れ済みトレードオフ・意図的に未対応） ==="
# execの別名 'e' は1文字のため、位置に関わらず「独立した単語としてのe」を
# 検出する現行方式では、フラグの値がたまたま 'e' である場合（例:
# `codex review -m e`）を誤検知する。execの別名検出を維持する以上の
# トレードオフとして受け入れており、テストとしては固定しない（将来
# 'e'検出をcodex直後の位置に限定する等の改善は別途検討）。
#
# `codex exec --help >/tmp/help.txt` や `codex exec --help 2>&1` のように
# --help の後にリダイレクトが続く場合、--help が断片の末尾でなくなるため
# 誤ってdenyされる（安全側＝過剰検知であり見逃しではないため許容。
# Codex一次レビュー指摘・4巡目Minor）。テストとしては固定しない。

echo "=== 10. 鍵なし（設計 §5.2・§5.6）: 台帳に team.codex-exec が無い＝ラッパー無し＝直叩きは deny（fail-close） ==="
awk -F'\t' '$6!="team.codex-exec"' "$LEDGER" > "$WORK/no-key.tsv" 2>/dev/null
export AIENV_LEDGER="$WORK/no-key.tsv"
assert_denied "鍵なし: codex exec 直叩きはdeny" "codex exec --sandbox read-only 'hi'"
assert_denied "鍵なし: codex resume 直叩きもdeny" "codex resume --last"
unset AIENV_LEDGER

echo "=== 11. 台帳異常・実体異常（設計 §5.6）: deny（fail-close）・deny 文と stderr に照会の固定文 ==="
export AIENV_LEDGER="$WORK/no-such-dir/ledger.tsv"
assert_denied "台帳異常: codex exec 直叩きはdeny・deny 文に LEDGER: ledger" "codex exec --sandbox read-only 'hi'" "LEDGER: ledger "
if grep -q '^LEDGER: ledger ' "$WORK/hook.err"; then pass "台帳異常: stderr に LEDGER: ledger"; else fail_case "台帳異常: stderr に LEDGER: ledger"; fi
{ awk -F'\t' '$6!="team.codex-exec"' "$LEDGER"
  printf 'part\tteam/connect/codex/zz-missing-codex-exec.sh\tteam\tconnect\tcodex\tteam.codex-exec\t-\t-\n'; } > "$WORK/bad-part.tsv" 2>/dev/null
export AIENV_LEDGER="$WORK/bad-part.tsv"
assert_denied "実体異常: codex exec 直叩きはdeny・deny 文に LEDGER: part team.codex-exec" "codex exec --sandbox read-only 'hi'" "LEDGER: part team.codex-exec "
if grep -q '^LEDGER: part team.codex-exec ' "$WORK/hook.err"; then pass "実体異常: stderr に LEDGER: part team.codex-exec"; else fail_case "実体異常: stderr に LEDGER: part team.codex-exec"; fi
unset AIENV_LEDGER

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
