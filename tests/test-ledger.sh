#!/usr/bin/env bash
# 台帳・移動表・台帳ツール（FR-14 の常設検査）のテスト（Core）。
# 正本＝docs/v1.1-components の要件 v1.5 §7（AC-3・AC-4・AC-6・AC-11）・設計 v1.4 §3・§5.6・§10.1・§10.2・§11・
# 実装計画 §2・§3・§5。
#
# 実行方法: bash tests/test-ledger.sh
#
# 契約（テストが決めた口。実装計画 §3 の名前・固定文・終了コードをそのまま使い、足りない分だけ決めた）:
#   台帳        core/data/ledger.tsv＝TSV・`#` 始まりはコメント。列＝種類 パス 機能 層 提供元 鍵 備考。
#               種類＝part／suite／notify。層＝data／rules／executor／connect／assembly。値なし＝`-`。
#               パス＝repo 相対（フォルダ単位は末尾 `/`）。notify のパスは repo 外なら `Vault:<ノート>`・`~/…`。
#   移動表      core/data/moves.tsv＝TSV・`#` 始まりはコメント。1 列目＝旧パス・2 列目＝新パス・3 列目＝種別。
#   台帳ツール  core/assembly/ledger-tool.sh。repo ルート＝自分の 2 つ上。走査は repo ルートの git が見る追跡ファイル。
#     check     設計 §10.1 ①〜⑧ を全部行う。合格＝exit 0・不合格行 0。不合格＝exit 非 0・1 件 1 行で stdout へ。
#               行頭の語＝検査名（①part ②suite ③coupling ④provider-leak ⑤moves ⑥forward ⑦live ⑧readme）、
#               続けて対象（部品・スイート・移動表の新パス・転送の旧パス・README に無いフォルダ名）を書く。
#               ③ は 1 組 1 行で `coupling <参照する側> -> <参照される部品>`（どちらも repo 相対）。
#               ⑦ で組立が途中で失敗したときも live 行を出す。
#     lookup <鍵>  鍵→`<repo ルート>/<パス>` を台帳の行順に 1 行ずつ。終了 0 あり／1 鍵なし／2 台帳異常／3 実体異常。
#               2・3 は stderr に固定文 1 行＝`LEDGER: ledger <原因>`／`LEDGER: part <鍵> <パス> <原因>`。1 は stderr なし。
#               上書き口 AIENV_LEDGER＝読む台帳のパス（既定＝repo ルートの core/data/ledger.tsv）。
#     live-set  ⑦ が突合する対象の一覧＝全部入りの組立が生成した settings.json の全フックの command と、
#               配置された LaunchAgent 3 本の ProgramArguments 先頭を 1 行ずつ。組立に使った一時 HOME は `$HOME`、
#               plist の雛形の `__AIENV_HOME__` も `$HOME` と書く（雛形の表記に揃える）。
# 隔離: 台帳ツールは全部入りの組立を走らせるので、本ファイルは HOME＝一時ディレクトリ・SKIP_LAUNCHCTL=1・
#   LAUNCHCTL_TIMEOUT_SECS=1・PATH 先頭に偽 launchctl／osascript／cmux（FX-6）で呼ぶ（core-worker §5）。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"
LEDGER="$REPO_ROOT/$LF_LEDGER_REL"
TOOL="$REPO_ROOT/$LF_LEDGER_TOOL_REL"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
lf_mk_fx6 "$WORK/stub"
export HOME="$WORK/home" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 PATH="$WORK/stub:$PATH"
mkdir -p "$HOME"

CHECK_LINES='^(part|suite|coupling|provider-leak|moves|forward|live|readme) '

# run_check <repo ルート> — その repo の台帳ツールで check。出力を $WORK/check.out、終了コードを CHECK_RC に。
run_check() {
  CHECK_RC=0
  bash "$1/$LF_LEDGER_TOOL_REL" check > "$WORK/check.out" 2>"$WORK/check.err" || CHECK_RC=$?
}
lines_of() { grep -E "^$1 " "$WORK/check.out" || true; }

# 陰性 fixture の土台＝FX-1 の複製（1 回だけ作り、ケースごとに cp -a で写す）。
BASE="$WORK/base"
lf_copy_repo "$REPO_ROOT" "$BASE"
fresh_copy() { rm -rf "$WORK/fx"; cp -a "$BASE" "$WORK/fx"; FX="$WORK/fx"; }
# AI Brain の想起の実行器（陰性の 1 行を足す先）＝台帳の鍵 ai-brain.recall の行。
RECALL_REL="$(lf_ledger_paths "$LEDGER" '$1=="part" && $6=="ai-brain.recall"' 2>/dev/null | head -1)"

echo "=== 0. 置き場: 台帳・移動表・台帳ツールが実在（実装計画 §2） ==="
assert_true "台帳 $LF_LEDGER_REL が実在" "$([ -f "$LEDGER" ] && echo 1 || echo 0)"
assert_true "移動表 $LF_MOVES_REL が実在" "$([ -f "$REPO_ROOT/$LF_MOVES_REL" ] && echo 1 || echo 0)"
assert_true "台帳ツール $LF_LEDGER_TOOL_REL が実行可能" "$([ -x "$TOOL" ] && echo 1 || echo 0)"
assert_true "鍵 ai-brain.recall の行がある（陰性 fixture の足し先）" "$([ -n "$RECALL_REL" ] && echo 1 || echo 0)"

echo "=== 1. AC-3 ①⑤・AC-4 ①・AC-11・FR-14＝FX-1 で検査 ①〜⑧ が全部合格 ==="
run_check "$REPO_ROOT"
assert_eq "FX-1: check の終了コード 0" "0" "$CHECK_RC"
assert_eq "FX-1: 不合格行 0（①〜⑧）" "" "$(grep -E "$CHECK_LINES" "$WORK/check.out" || true)"
assert_eq "AC-4 ① FX-1: 結合参照 0 組" "0" "$(lines_of coupling | grep -c . || true)"

echo "=== 2. AC-3 ② FX-12（台帳に無い部品 1 本）＝① が不合格・そのパスを報告 ==="
fresh_copy
printf '#!/bin/bash\n:\n' > "$FX/ai-brain/executor/zz-unlisted.sh"; chmod +x "$FX/ai-brain/executor/zz-unlisted.sh"
lf_commit_all "$FX"
run_check "$FX"
assert_true "FX-12: 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_eq "FX-12: part 行がそのパスを 1 件報告" "1" "$(lines_of part | grep -c 'ai-brain/executor/zz-unlisted.sh' || true)"

echo "=== 3. AC-3 ② FX-13（実在しないパスの行 1 行）＝① が不合格・そのパスを報告 ==="
fresh_copy
printf 'part\tai-brain/executor/zz-missing.sh\tai-brain\texecutor\t-\t-\t\n' >> "$FX/$LF_LEDGER_REL"
lf_commit_all "$FX"
run_check "$FX"
assert_true "FX-13: 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_eq "FX-13: part 行がそのパスを 1 件報告" "1" "$(lines_of part | grep -c 'ai-brain/executor/zz-missing.sh' || true)"

echo "=== 4. 検査 ②（設計 §10.1）: 機能の記されていないスイート 1 本＝suite 行で報告 ==="
fresh_copy
printf '#!/usr/bin/env bash\n:\n' > "$FX/tests/test-zz-unlisted.sh"
lf_commit_all "$FX"
run_check "$FX"
assert_true "② 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_eq "② suite 行がそのスイートを報告" "1" "$(lines_of suite | grep -c 'tests/test-zz-unlisted.sh' || true)"

echo "=== 5. AC-4 ② FX-14（AI Brain の実行器に Team の部品名を名指す非コメント行）＝ちょうど 1 組 ==="
fresh_copy
TEAM_Q="$(lf_ledger_paths "$LEDGER" '$1=="part" && $3=="team" && $4=="executor" && $2 !~ /\/$/' 2>/dev/null | head -1)"
assert_true "FX-14: Team の実行器の部品が台帳にある（名指す先）" "$([ -n "$TEAM_Q" ] && echo 1 || echo 0)"
printf ': %s\n' "${TEAM_Q##*/}" >> "$FX/$RECALL_REL"
lf_commit_all "$FX"
run_check "$FX"
assert_eq "FX-14: coupling 行ちょうど 1 行" "1" "$(lines_of coupling | grep -c . || true)"
assert_eq "FX-14: その組＝足した行の組" "coupling $RECALL_REL -> $TEAM_Q" "$(lines_of coupling)"

echo "=== v1.2 AC-1 ①② FX-18 CPLN（AI Brain の実行器に Notify の接続の部品名を名指す非コメント行）＝ちょうど 1 組（Notify 所在の例外を外す＝FR-2） ==="
fresh_copy
NOTIFY_CONN_Q="$(lf_ledger_paths "$LEDGER" '$1=="part" && $3=="notify" && $4=="connect" && $2 !~ /\/$/' 2>/dev/null | head -1)"
assert_true "FX-18: Notify の接続の部品が台帳にある（名指す先）" "$([ -n "$NOTIFY_CONN_Q" ] && echo 1 || echo 0)"
printf ': %s\n' "${NOTIFY_CONN_Q##*/}" >> "$FX/$RECALL_REL"
lf_commit_all "$FX"
run_check "$FX"
assert_eq "FX-18: coupling 行ちょうど 1 行（v1.1 では Notify 所在の例外で 0 行だった組が、v1.2 では検出される）" \
  "1" "$(lines_of coupling | grep -c . || true)"
assert_eq "FX-18: その組＝足した行の組" "coupling $RECALL_REL -> $NOTIFY_CONN_Q" "$(lines_of coupling)"

echo "=== v1.2 AC-1 ③④: 式 B・式 C に当たる部品の置き場（Notify 所在の例外なし・設計 §2.4） ==="
{
  # 式B（要件 v1.1 §7＝本人を呼ぶ呼出構文の目印）。届け先の部品を登録・配置する行は当たらない。
  scan_targets() {
    git -C "$REPO_ROOT" ls-files | grep -vE '^(tests/|README\.md$|LICENSE$|\.gitignore$|Brewfile$)' \
      | while IFS= read -r f; do
          [ -L "$REPO_ROOT/$f" ] && continue; [ -f "$REPO_ROOT/$f" ] || continue
          case "$f" in *.sh|*.py) echo "$f"; continue ;; esac
          head -1 "$REPO_ROOT/$f" | grep -qE '^#!.*(/|env )(sh|bash|python[0-9.]*)([[:space:]]|$)' && echo "$f"
        done
  }
  FORMULA_B='cmux[[:space:]]+notify|display notification|code27-call/bin/'
  hit_b="$(scan_targets | while IFS= read -r f; do
    grep -vE '^[[:space:]]*(#|//)' "$REPO_ROOT/$f" | grep -qE "$FORMULA_B" && echo "$f"; done | sort -u)"
  assert_true "AC-1 ③: 式 B に当たる部品が 1 件以上（観測が空でない・未実装のうちは 0 で赤）" "$([ -n "$hit_b" ] && echo 1 || echo 0)"
  notify_connect_rows="$(awk -F'\t' '!/^#/ && $1=="part" && $3=="notify" && $4=="connect" {print $2}' "$LEDGER" 2>/dev/null | sort -u)"
  not_in_connect="$(comm -23 <(printf '%s\n' "$hit_b") <(printf '%s\n' "$notify_connect_rows") 2>/dev/null)"
  assert_eq "AC-1 ③: 式 B に当たる部品が全て Notify の接続にある（Notify 所在の例外なし）" "" "$not_in_connect"

  # 式C（要件 v1.1 §7＝提供元の識別子。既定の除外＝.claude/logs）。
  FORMULA_C='\.(claude|codex)([^[:alnum:]_-]|$)|(^|[[:space:];|&(=])(claude|codex)([[:space:];|&)]|$)|[=\[(][[:space:]]*["'"'"'](claude|codex)["'"'"']'
  hit_c="$(scan_targets | while IFS= read -r f; do
    grep -vE '^[[:space:]]*(#|//)' "$REPO_ROOT/$f" | grep -vE '\.claude.{1,5}logs' | grep -qE "$FORMULA_C" && echo "$f"; done | sort -u)"
  leak_ok_rows="$(awk -F'\t' '!/^#/ && $1=="part" && (($4=="connect")||($4=="assembly")) {print $2}' "$LEDGER" 2>/dev/null | sort -u)"
  not_in_ok="$(comm -23 <(printf '%s\n' "$hit_c") <(printf '%s\n' "$leak_ok_rows") 2>/dev/null)"
  assert_eq "AC-1 ④: 式 C に当たる部品が全て接続・組立にある（Notify 所在の例外なし）" "" "$not_in_ok"
}

echo "=== 6. AC-3 ③ 式 C（FX-19・FX-20・FX-21）＝④ が不合格・足した行の部品を報告 ==="
leak_case() {  # $1=fixture ID $2=足す 1 行（要件 §7 の字面そのまま）
  fresh_copy
  printf '%s\n' "$2" >> "$FX/$RECALL_REL"
  lf_commit_all "$FX"
  run_check "$FX"
  assert_true "$1: 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
  assert_eq "$1: provider-leak 行がその部品を報告" "1" "$(lines_of provider-leak | grep -c "$RECALL_REL" || true)"
}
leak_case FX-19 '[ "$p" = "codex" ] && :'
leak_case FX-20 'c=claude; "$c" --version >/dev/null 2>&1 || :'
leak_case FX-21 '[ -d "$HOME/.codex/sessions" ] || :'

echo "=== 7. AC-3 ④ 移動表（FX-24・FX-25）＝⑤ が不合格・該当の行を報告 ==="
# ⚠️ ここで言う「FX-24」「FX-25」は本ファイルが元々使っていた v1.1 §7 の識別子（この
# echo 直下のローカルな仮の名）で、要件 v1.2 requirements-v1.md §7 の FX-24 PART・
# FX-25a〜c LBAD（tests/test-notify.sh・test-code27-call-clear.sh が見る）とは別物。
# 旧も新も 1 行にしか現れない行（＝移動）を 2 つ選ぶ。
pick_moves() {
  awk -F'\t' '!/^#/ && NF>=2 && $1!="" && $2!="" {o[$1]++; n[$2]++; row[NR]=$1"\t"$2}
    END {for (i in row) {split(row[i], a, "\t"); if (o[a[1]]==1 && n[a[2]]==1) print i"\t"row[i]}}' "$1" | sort -n | head -2
}
MOVES_PICK="$(pick_moves "$REPO_ROOT/$LF_MOVES_REL" 2>/dev/null)"
ROW_A="$(printf '%s\n' "$MOVES_PICK" | sed -n 1p)"; ROW_B="$(printf '%s\n' "$MOVES_PICK" | sed -n 2p)"
NEW_A="$(printf '%s' "$ROW_A" | cut -f3)"; LNO_B="$(printf '%s' "$ROW_B" | cut -f1)"
LNO_A="$(printf '%s' "$ROW_A" | cut -f1)"
assert_true "移動表に移動の行が 2 つ以上ある" "$([ -n "$ROW_B" ] && echo 1 || echo 0)"
fresh_copy
awk -F'\t' -v OFS='\t' -v l="$LNO_B" -v n="$NEW_A" 'NR==l{$2=n} {print}' "$BASE/$LF_MOVES_REL" > "$FX/$LF_MOVES_REL"
lf_commit_all "$FX"
run_check "$FX"
assert_true "FX-24: 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_true "FX-24: moves 行が主後継の重なった新パスを報告" "$(lines_of moves | grep -qF "$NEW_A" && echo 1 || echo 0)"
fresh_copy
awk -F'\t' -v OFS='\t' -v l="$LNO_A" 'NR==l{$1=""} {print}' "$BASE/$LF_MOVES_REL" > "$FX/$LF_MOVES_REL"
lf_commit_all "$FX"
run_check "$FX"
assert_true "FX-25: 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_true "FX-25: moves 行が由来の空いた新パスを報告" "$(lines_of moves | grep -qF "$NEW_A" && echo 1 || echo 0)"
# v1.2 T5（リーダー裁定）＝旧 FX-25b「変更の無いスイートの移動表の行を消すと非 0・由来の
# 無いスイートを報告」は v1.2 FR-20（台帳の検査は移動表に行の無い部品・スイートを
# 不合格にしない）と矛盾するため撤去した。FR-20 の正の側（移動表に行の無い新規部品・
# スイートを不合格にしないこと）は tests/test-ledger.sh の
# 「v1.2 FR-20: 移動表に行の無い新規部品・スイートを不合格にしない（FX-11 ZZD）」節で見る。
# 移動表に行の「ある」部品・スイートに v1.1 FR-13 の 3 条件を保つことは、直前の FX-24・
# FX-25（行はあるが新パスが重なる／空いている＝不合格）がそのまま見ている。

echo "=== 8. 検査 ⑥（AC-3 ④ 後段）: 転送のリンク先が主後継と違う＝forward 行で報告 ==="
fresh_copy
ln -sfn ../dock/executor/cmux-task-model.sh "$FX/dock/executor/cmux-next-model.sh"
lf_commit_all "$FX"
run_check "$FX"
assert_true "⑥ 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_eq "⑥ forward 行がその転送を報告" "1" "$(lines_of forward | grep -c 'dock/executor/cmux-next-model.sh' || true)"

echo "=== 9. 検査 ⑦（AC-3 ⑤・FR-14 ②）: 登録フックの実体が実行可能でない＝live 行で報告 ==="
fresh_copy
chmod -x "$FX/core/connect/claude-code/bash-policy-gate.sh" 2>/dev/null
run_check "$FX"
assert_true "⑦ 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_true "⑦ live 行がそのフックを報告" "$(lines_of live | grep -q 'bash-policy-gate.sh' && echo 1 || echo 0)"

echo "=== 10. 検査 ⑧（AC-11）: README の構成節に無い実フォルダ＝readme 行で報告 ==="
fresh_copy
mkdir -p "$FX/zz-extra"; printf 'x\n' > "$FX/zz-extra/zz.txt"
lf_commit_all "$FX"
run_check "$FX"
assert_true "⑧ 非 0" "$([ "$CHECK_RC" != "0" ] && echo 1 || echo 0)"
assert_true "⑧ readme 行がそのフォルダを報告" "$(lines_of readme | grep -q 'zz-extra' && echo 1 || echo 0)"

echo "=== 11. AC-3 ⑤: ⑦ が突合した集合＝雛形の全フック command＋LaunchAgent 3 本の起動対象 ==="
SETTINGS_TPL="$REPO_ROOT/core/assembly/settings.json"
expected_live="$( { jq -r '.hooks[][].hooks[].command' "$SETTINGS_TPL" 2>/dev/null
  git -C "$REPO_ROOT" ls-files '*.plist' | while IFS= read -r p; do
    plutil -extract ProgramArguments.0 raw -o - "$REPO_ROOT/$p" 2>/dev/null; echo; done \
    | sed 's/__AIENV_HOME__/$HOME/' | grep . ; } | sort -u)"
actual_live="$(bash "$TOOL" live-set 2>/dev/null | sort -u)"
assert_eq "LaunchAgent の雛形は 3 本" "3" "$(git -C "$REPO_ROOT" ls-files '*.plist' | grep -c . || true)"
assert_true "期待集合が空でない" "$([ -n "$expected_live" ] && echo 1 || echo 0)"
assert_eq "live-set＝雛形の全フック＋plist 3 本の起動対象" "$expected_live" "$actual_live"

echo "=== v1.2 FR-7/§2.4: notify 行（repo 外の所在）の役割の検査＝発する側は提供元 '-'・下流の取次は届け先名 ==="
{
  # v1.1 の「Notify 所在（repo 内の3行）」は v1.2 で部品行へ置き換わる（FR-7）＝
  # notify 種類の行は repo 外（Vault の規則ノート・別 repo の取次）の 4 行だけになる。
  notify_rows_count="$(awk -F'\t' '!/^#/ && $1=="notify" {c++} END{print c+0}' "$LEDGER" 2>/dev/null)"
  assert_eq "v1.2: notify 種類の行はちょうど 4 行（repo 外の所在だけ）" "4" "$notify_rows_count"
  vault_rows="$(awk -F'\t' '!/^#/ && $1=="notify" && $2 ~ /^Vault:/ {print}' "$LEDGER" 2>/dev/null)"
  assert_eq "v1.2: Vault の規則ノートの行はちょうど 3（cmux-notifications・core-conduct・coding-delegation・確定直前の grep 一覧）" \
    "3" "$(printf '%s\n' "$vault_rows" | grep -c . || true)"
  bad_src_provider="$(printf '%s\n' "$vault_rows" | awk -F'\t' '$5!="-" {print}')"
  assert_eq "v1.2: 発する側（Vault の規則ノート）の提供元は '-'（口を呼ぶ側・届け先を持たない）" "" "$bad_src_provider"
  downstream_rows="$(awk -F'\t' '!/^#/ && $1=="notify" && $2 !~ /^Vault:/ {print}' "$LEDGER" 2>/dev/null)"
  assert_eq "v1.2: 下流の取次（別 repo）の行はちょうど 1" "1" "$(printf '%s\n' "$downstream_rows" | grep -c . || true)"
  bad_dst_provider="$(printf '%s\n' "$downstream_rows" | awk -F'\t' '$5!="code27" {print}')"
  assert_eq "v1.2: 下流の取次の提供元は届け先名 code27" "" "$bad_dst_provider"
}

echo "=== v1.2 FR-20: 移動表に行の無い新規部品・スイートを不合格にしない（FX-11 ZZD） ==="
{
  WT11="$WORK/wt-fx11"
  lf_copy_repo "$REPO_ROOT" "$WT11"
  mkdir -p "$WT11/notify/connect/zz-dest"
  cp "$TESTS_DIR/fixtures/zz-dest/connect/deliver.sh" "$WT11/notify/connect/zz-dest/deliver.sh" 2>/dev/null
  chmod +x "$WT11/notify/connect/zz-dest/deliver.sh" 2>/dev/null
  printf 'part\tnotify/connect/zz-dest/deliver.sh\tnotify\tconnect\tzz-dest\t-\t第4の届け先（試験）\tcall\n' >> "$WT11/$LF_LEDGER_REL"
  lf_commit_all "$WT11"
  run_check "$WT11"
  assert_eq "FX-11: 台帳の検査 exit 0（移動表に行の無い zz-dest の部品を不合格にしない）" "0" "$CHECK_RC"
  assert_eq "FX-11: moves 行の不合格が無い" "0" "$(lines_of moves | grep -c . || true)"
}

echo "=== v1.2 §2.4 ⑧README: 提供元のフォルダは README に載っていなくてよい（載っているものは実在すること） ==="
{
  fresh_copy
  mkdir -p "$FX/notify/connect/zz-readme-optional"
  printf '#!/bin/bash\n:\n' > "$FX/notify/connect/zz-readme-optional/deliver.sh"
  chmod +x "$FX/notify/connect/zz-readme-optional/deliver.sh"
  printf 'part\tnotify/connect/zz-readme-optional/deliver.sh\tnotify\tconnect\tzz-readme-optional\t-\t試験（README 未記載でも合格）\t-\n' >> "$FX/$LF_LEDGER_REL"
  lf_commit_all "$FX"
  run_check "$FX"
  assert_eq "README に載らない提供元フォルダがあっても ⑧ readme は不合格にしない" "0" "$(lines_of readme | grep -c 'zz-readme-optional' || true)"
}

echo "=== v1.2 §2.4 ①: 台帳の「知らせ」列の形式（値を持つのは Notify の接続の実行可能な部品だけ） ==="
{
  bad_knows="$(awk -F'\t' '!/^#/ && $1=="part" && NF>=8 && $8!="-" && $8!="" && !($3=="notify" && $4=="connect") {print $2}' "$LEDGER" 2>/dev/null)"
  assert_eq "Notify の接続以外に「知らせ」列の値を持つ部品が無い" "" "$bad_knows"
}

echo "=== v1.2 実装計画: 旧 test-code27-call-clear.sh のスイート行は機能列が core（入力検知の試験として Core へ） ==="
{
  row="$(awk -F'\t' '!/^#/ && $1=="suite" && $2=="tests/test-code27-call-clear.sh" {print}' "$LEDGER" 2>/dev/null)"
  assert_true "台帳にそのスイート行がある" "$([ -n "$row" ] && echo 1 || echo 0)"
  func="$(printf '%s' "$row" | cut -f3)"
  assert_eq "その機能列は core" "core" "$func"
}

echo "=== 13. 照会 3 種（設計 §5.6・§11）: あり 0／鍵なし 1／台帳異常 2／実体異常 3＋固定文 ==="
run_lookup() {  # $1=鍵 [AIENV_LEDGER]
  LOOKUP_RC=0
  AIENV_LEDGER="${2:-$LEDGER}" bash "$TOOL" lookup "$1" > "$WORK/lk.out" 2>"$WORK/lk.err" || LOOKUP_RC=$?
}
MULTI_KEY="$(awk -F'\t' '!/^#/ && $1=="part" && $6!="-" && $6!="" {n[$6]++} END{for (k in n) if (n[k]>=2) print k}' "$LEDGER" 2>/dev/null | head -1)"
assert_true "台帳に複数行の鍵がある（接続の列挙）" "$([ -n "$MULTI_KEY" ] && echo 1 || echo 0)"
run_lookup "${MULTI_KEY:-zz.none}"
assert_eq "あり: 終了 0" "0" "$LOOKUP_RC"
assert_eq "あり: repo ルート＋パスを台帳の行順に" \
  "$(lf_ledger_paths "$LEDGER" '$1=="part" && $6=="'"$MULTI_KEY"'"' 2>/dev/null | sed "s#^#$REPO_ROOT/#")" "$(cat "$WORK/lk.out")"
assert_eq "あり: stderr なし" "" "$(cat "$WORK/lk.err")"
run_lookup "zz.no-such-key"
assert_eq "鍵なし: 終了 1" "1" "$LOOKUP_RC"
assert_eq "鍵なし: stdout・stderr とも空" "" "$(cat "$WORK/lk.out" "$WORK/lk.err")"
run_lookup "ai-brain.recall" "$WORK/no-such-dir/ledger.tsv"
assert_eq "台帳異常（無い）: 終了 2" "2" "$LOOKUP_RC"
assert_true "台帳異常（無い）: stderr 1 行＝LEDGER: ledger …" \
  "$([ "$(grep -c . "$WORK/lk.err")" = "1" ] && grep -q '^LEDGER: ledger ' "$WORK/lk.err" && echo 1 || echo 0)"
printf 'part\tai-brain/executor/vault-recall.sh\tai-brain\n' > "$WORK/short.tsv"
run_lookup "ai-brain.recall" "$WORK/short.tsv"
assert_eq "台帳異常（列数不足）: 終了 2" "2" "$LOOKUP_RC"
assert_true "台帳異常（列数不足）: LEDGER: ledger …" "$(grep -q '^LEDGER: ledger ' "$WORK/lk.err" && echo 1 || echo 0)"
# V-06: 照会も check と同じ語彙検査をする＝suite 行の機能が語彙外の台帳は台帳異常（設計 §5.6）。
{ cat "$LEDGER"; printf 'suite\ttests/test-ledger.sh\tzz-not-a-function\t-\t-\t-\t\n'; } > "$WORK/bad-vocab.tsv" 2>/dev/null
run_lookup "ai-brain.recall" "$WORK/bad-vocab.tsv"
assert_eq "台帳異常（suite 行の機能が語彙外）: 終了 2" "2" "$LOOKUP_RC"
assert_true "台帳異常（suite 行の機能が語彙外）: LEDGER: ledger …" "$(grep -q '^LEDGER: ledger ' "$WORK/lk.err" && echo 1 || echo 0)"
{ cat "$LEDGER"; printf 'part\tai-brain/executor/zz-missing.sh\tai-brain\texecutor\t-\tzz.missing\t\n'; } > "$WORK/bad-part.tsv" 2>/dev/null
run_lookup "zz.missing" "$WORK/bad-part.tsv"
assert_eq "実体異常（パス不在）: 終了 3" "3" "$LOOKUP_RC"
assert_true "実体異常: stderr 1 行＝LEDGER: part zz.missing <パス> …" \
  "$([ "$(grep -c . "$WORK/lk.err")" = "1" ] && grep -q '^LEDGER: part zz\.missing .*ai-brain/executor/zz-missing\.sh' "$WORK/lk.err" && echo 1 || echo 0)"
{ cat "$LEDGER"; printf 'part\t%s\tcore\tdata\t-\tzz.noexec\t\n' "$LF_LEDGER_REL"; } > "$WORK/noexec.tsv" 2>/dev/null
run_lookup "zz.noexec" "$WORK/noexec.tsv"
assert_eq "実体異常（実行不可）: 終了 3" "3" "$LOOKUP_RC"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
