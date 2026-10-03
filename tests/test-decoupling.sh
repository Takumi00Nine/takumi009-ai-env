#!/usr/bin/env bash
# 疎結合の受入（Core）＝受入① AI Brain は Claude Code 抜きで shell から使える・受入② 提供元の追加は
# 接続フォルダ 1 つと台帳の行で済む・受入③ AI Brain＋Core だけでも 4 入口が働く。
# 正本＝docs/v1.1-components の要件 v1.5 §7（AC-1 ①〜④・AC-2 ①②⑤・AC-5 ②・FX-3〜8・FX-10・FX-11）・
# 設計 v1.4 §10.3・§13。AC-2 ③④・AC-5 ① は締めの実走（tests/closing/）が見る。
#
# 実行方法: bash tests/test-decoupling.sh
#
# 契約（テストが決めた口。台帳と台帳ツールの口は tests/test-ledger.sh 冒頭の契約と同じ）:
#   AI Brain の 4 入口＝台帳の鍵 ai-brain.recall・ai-brain.bootstrap・ai-brain.backup・ai-brain.maintenance を
#   その複製の台帳ツール `lookup` で引いて起動する（実装計画 §3）。
#   入口の上書き口（現行名のまま）＝想起 VAULT_RECALL_VAULT・VAULT_RECALL_LOG／読込 BOOTSTRAP_VAULT／
#   バックアップ VAULT・LOCK_FILE・VAULT_WRITER_LOCK_FILE／メンテ VAULT・AIENV_REPO（状態記録は
#   $HOME/.claude/logs/maintenance/last-run.json＝README「状態記録の契約」）。
#   FX-10 の zz-cli 接続＝共有の雛形 tests/fixtures/zz-cli/connect/（登録・変換シム・配置手順の 3 点。書式は
#   同フォルダの README.md＝所有は締めの実走の担当）を ai-brain/connect/zz-cli/ へ丸ごと写し、変換シムの
#   __RECALL_REL__ を想起の実行器への相対パス（../../executor/vault-recall.sh）に置き換える。
#   台帳の行＝フォルダ単位 1 行（part ai-brain/connect/zz-cli/ ai-brain connect zz-cli - …）。
# 隔離: HOME＝空の一時ディレクトリ（FX-3）・PATH 先頭に FX-6 の偽物・PATH に claude／codex 無し・
#   Vault＝一時の複製（FX-4／FX-5）・repo＝一時の複製（FX-7／FX-8）。実 HOME・実 Vault・実 repo に書かない。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれない: \"$3\")"; fi; }

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
lf_mk_fx6 "$WORK/stub"
NOCLI_PATH="$WORK/stub:$(lf_path_without claude codex)"
BASE="$WORK/base"
lf_copy_repo "$REPO_ROOT" "$BASE"
VAULT_PUBLIC_REL="$(lf_ledger_paths "$BASE/$LF_LEDGER_REL" '$1=="part" && $2 ~ /ai-brain\/data\/vault-public\/$/' 2>/dev/null | head -1)"

echo "=== 0. 前提: FX-6 の PATH に claude・codex が無い ==="
assert_true "command -v claude が非 0" "$(PATH="$NOCLI_PATH" command -v claude >/dev/null 2>&1 && echo 0 || echo 1)"
assert_true "command -v codex が非 0" "$(PATH="$NOCLI_PATH" command -v codex >/dev/null 2>&1 && echo 0 || echo 1)"
assert_true "台帳に公開スナップショット（ai-brain/data/vault-public/）の行がある（FX-4 の元）" "$([ -n "$VAULT_PUBLIC_REL" ] && echo 1 || echo 0)"

# entry <repo> <鍵> — その複製の台帳ツールで入口のパスを引く（1 行目）。
entry() { bash "$1/$LF_LEDGER_TOOL_REL" lookup "$2" 2>/dev/null | head -1; }

# brain_judge <repo> <ラベル> — AI Brain 判定（AC-1 ①〜④）。毎回 新しい HOME（FX-3）と Vault の複製を使う。
brain_judge() {
  local repo="$1" label="$2" e out rc fx4 fx5 n0 n1 th
  # 引数の先頭の VAR=値（入口ごとの上書き口）も環境変数として渡すため env を通す。
  run_env() { HOME="$th" PATH="$NOCLI_PATH" LOCK_FILE="$th/backup.lock" \
      VAULT_WRITER_LOCK_FILE="$th/vault-writer.lock" env "$@"; }
  [ -n "$VAULT_PUBLIC_REL" ] || { fail_case "$label: FX-4 の元（ai-brain/data/vault-public/）が台帳で引けない"; return; }

  th="$WORK/$label-home1"; mkdir -p "$th"; fx4="$WORK/$label-fx4"
  lf_mk_fx4 "$repo/$VAULT_PUBLIC_REL" "$fx4"
  e="$(entry "$repo" ai-brain.recall)"
  assert_true "$label ①: 想起の入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  rc=0; out="$(printf '%s' '{"session_id":"s1","prompt":"想起プローブ甲 について"}' \
    | run_env VAULT_RECALL_VAULT="$fx4" VAULT_RECALL_LOG="$th/vault-recall.tsv" bash "${e:-/nonexistent}")" || rc=$?
  assert_eq "$label ① FX-17: exit 0" "0" "$rc"
  assert_contains "$label ① FX-17: additionalContext に Knowledge/zz-probe.md" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" "Knowledge/zz-probe.md"
  rc=0; out="$(printf '%s' '{"session_id":"s1","prompt":"今日の天気"}' \
    | run_env VAULT_RECALL_VAULT="$fx4" VAULT_RECALL_LOG="$th/vault-recall.tsv" bash "${e:-/nonexistent}")" || rc=$?
  assert_eq "$label ① FX-18: exit 0" "0" "$rc"
  assert_eq "$label ① FX-18: stdout 空" "" "$out"

  th="$WORK/$label-home2"; mkdir -p "$th"
  e="$(entry "$repo" ai-brain.bootstrap)"
  assert_true "$label ②: 読込の入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  rc=0; out="$(printf '{}' | run_env BOOTSTRAP_VAULT="$fx4" bash "${e:-/nonexistent}")" || rc=$?
  assert_eq "$label ②: exit 0" "0" "$rc"
  assert_contains "$label ②: additionalContext に Preferences/absolute-rules.md" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" "Preferences/absolute-rules.md"

  th="$WORK/$label-home3"; mkdir -p "$th"; fx5="$WORK/$label-fx5"
  lf_mk_fx5 "$repo/$VAULT_PUBLIC_REL" "$fx5"
  e="$(entry "$repo" ai-brain.backup)"
  assert_true "$label ③: バックアップの入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  n0="$(git -C "$fx5" rev-list --count HEAD 2>/dev/null)"
  rc=0; run_env VAULT="$fx5" bash "${e:-/nonexistent}" >/dev/null 2>&1 || rc=$?
  n1="$(git -C "$fx5" rev-list --count HEAD 2>/dev/null)"
  assert_eq "$label ③: exit 0" "0" "$rc"
  assert_eq "$label ③: FX-5 のコミット数が 1 増える" "$((n0 + 1))" "$n1"

  th="$WORK/$label-home4"; mkdir -p "$th"; fx5="$WORK/$label-fx5m"
  lf_mk_fx5 "$repo/$VAULT_PUBLIC_REL" "$fx5"
  e="$(entry "$repo" ai-brain.maintenance)"
  assert_true "$label ④: メンテの入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  run_env VAULT="$fx5" AIENV_REPO="$repo" bash "${e:-/nonexistent}" >/dev/null 2>&1
  local lr="$th/.claude/logs/maintenance/last-run.json"
  assert_eq "$label ④: run.status＝completed" "completed" "$(jq -r '.run.status' "$lr" 2>/dev/null)"
  # HOME は空から始めた＝記録は今回の実行だけが書いた。completed が今回の run のもの。
  assert_true "$label ④: completed が今回の run（completed.run_id＝run.run_id）" \
    "$(jq -e '.completed.run_id != null and .completed.run_id == .run.run_id' "$lr" >/dev/null 2>&1 && echo 1 || echo 0)"
}

echo "=== 1. AC-1 受入①: FX-7（Claude Code の接続フォルダを全機能分除いた複製）で AI Brain 判定 ==="
FX7="$WORK/fx7"; cp -a "$BASE" "$FX7"
for func in $(lf_ledger_paths "$BASE/$LF_LEDGER_REL" '$4=="connect" && $5=="claude-code"' 2>/dev/null | cut -d/ -f1 | sort -u); do
  rm -rf "$FX7/$func/connect/claude-code"
done
assert_eq "FX-7: Claude Code の接続フォルダが残っていない" "" "$(cd "$FX7" && ls -d */connect/claude-code 2>/dev/null)"
brain_judge "$FX7" "FX-7"

echo "=== 2. AC-5 ② 受入③: FX-8（AI Brain と Core だけ）で AI Brain 判定 ==="
FX8="$WORK/fx8"; cp -a "$BASE" "$FX8"
rm -rf "$FX8/team" "$FX8/usage" "$FX8/notify" "$FX8/dock" "$FX8"/*/connect/claude-code
assert_true "FX-8: 機能フォルダは ai-brain と core だけ" \
  "$([ -d "$FX8/ai-brain" ] && [ -d "$FX8/core" ] && [ ! -e "$FX8/team" ] && [ ! -e "$FX8/dock" ] && echo 1 || echo 0)"
brain_judge "$FX8" "FX-8"

echo "=== 3. AC-2 受入② ①②: FX-10（AI Brain の zz-cli 接続フォルダ＋台帳 1 行）＝式 A 0 行・台帳の突合が合格 ==="
# mk_zz_connect <repo> — 共有の雛形を接続フォルダへ写し、台帳の行を足す（コミットはしない＝式 A が見る差分）。
ZZ_TEMPLATE="$TESTS_DIR/fixtures/zz-cli/connect"
ZZ_LEDGER_LINE=$'part\tai-brain/connect/zz-cli/\tai-brain\tconnect\tzz-cli\t-\t偽 zz-cli 接続（試験）'
ZZ_MOVES_LINE=$'-\tai-brain/connect/zz-cli/\t新規\t-'
# mk_zz_connect <repo> — 共有の雛形を接続フォルダへ写し、台帳と移動表（FR-13＝新規の部品にも由来が要る）に
# 無ければ 1 行足す（既にある tree の上で重ねて呼んでも行が増えない）。
mk_zz_connect() {
  local d="$1/ai-brain/connect/zz-cli"
  mkdir -p "$d"
  cp -p "$ZZ_TEMPLATE"/* "$d"/
  sed -i '' 's#__RECALL_REL__#../../executor/vault-recall.sh#' "$d/recall-shim.sh"
  grep -qF -- "$ZZ_LEDGER_LINE" "$1/$LF_LEDGER_REL" || printf '%s\n' "$ZZ_LEDGER_LINE" >> "$1/$LF_LEDGER_REL"
  grep -qF -- "$ZZ_MOVES_LINE" "$1/$LF_MOVES_REL" || printf '%s\n' "$ZZ_MOVES_LINE" >> "$1/$LF_MOVES_REL"
}
# 式 A（要件 §7 の形のまま。<…> を設計で決まったパスに置き換えたもの。台帳と同じ理由で移動表も除く＝
# 接続フォルダの追加に必ず伴う由来の追記 (FR-13) は接続フォルダ外の変更として数えない）。
formula_a() {
  git -C "$1" status --porcelain --untracked-files=all \
    | cut -c4- \
    | grep -vE '^ai-brain/connect/zz-cli/' \
    | grep -vxF "$LF_LEDGER_REL" \
    | grep -vxF "$LF_MOVES_REL"
}
FX10="$WORK/fx10"; cp -a "$BASE" "$FX10"
mk_zz_connect "$FX10"
assert_eq "AC-2 ① FX-10: 式 A の出力 0 行" "" "$(formula_a "$FX10")"
TH="$WORK/home-check"; mkdir -p "$TH"
check_out="$(HOME="$TH" PATH="$WORK/stub:$PATH" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 \
  bash "$FX10/$LF_LEDGER_TOOL_REL" check 2>/dev/null)"; check_rc=$?
assert_true "AC-2 ② FX-10: 台帳ツールが動いた（終了 127 でない）" "$([ "$check_rc" != "127" ] && [ -f "$FX10/$LF_LEDGER_TOOL_REL" ] && echo 1 || echo 0)"
assert_eq "AC-2 ② FX-10: AC-3 ① の突合（part・suite）に不合格行なし" "" "$(printf '%s\n' "$check_out" | grep -E '^(part|suite) ' || true)"

echo "=== 4. AC-2 ⑤: FX-11（FX-10＋接続外の追跡ファイル 1 本に 1 行）＝式 A がそのパス 1 行 ==="
FX11="$WORK/fx11"; cp -a "$BASE" "$FX11"
mk_zz_connect "$FX11"
printf '\n' >> "$FX11/README.md"
assert_eq "AC-2 ⑤ FX-11: 式 A の出力＝README.md の 1 行" "README.md" "$(formula_a "$FX11")"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
