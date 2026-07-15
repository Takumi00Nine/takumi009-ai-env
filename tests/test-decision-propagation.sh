#!/usr/bin/env bash
# scripts/vault-agents/decision_propagation.py（Decision波及チェックツール）の
# ユニットテスト。
#
# 実 Vault($HOME/Data/obsidian)には一切依存しない。環境変数 VAULT を一時
# ディレクトリの fixture Vault へ差し替えて実行する（スクリプトは VAULT 環境変数
# を最優先で読む設計）。受入条件 A2〜A5・A7 と機能要件 F1〜F6 をカバーする
# （A1/A6 は実 Vault 相当のため docs/trial-sample-output.md 側で確認）。
#
# 実行方法: bash tests/test-decision-propagation.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/decision_propagation.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

# N日前/後のYYYY-MM-DD（BSD date。0や正数にも+符号を明示しないと date が拒否する）
d_date() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%F; }

# fixture Vault の骨格を作る（照合対象3フォルダ＋Decisions）
make_vault() {
  local vault="$1"
  mkdir -p "$vault/Preferences" "$vault/Projects" "$vault/Knowledge" "$vault/Decisions"
}

# write_note <vault> <相対パス> <frontmatter本文(改行区切り)> [本文]
write_note() {
  local vault="$1" rel="$2" fm="$3" body="${4:-本文}"
  mkdir -p "$(dirname "$vault/$rel")"
  {
    echo "---"
    printf '%s\n' "$fm"
    echo "---"
    echo
    printf '%s\n' "$body"
  } > "$vault/$rel"
}

# decision_propagation.py を fixture Vault で実行し、標準出力を OUT・終了コードを
# RC に入れる（stderr は捨てない＝エラー系テストで検証するため STDERR に入れる）
OUT=""
RC=0
STDERR=""
run_check() {
  local vault="$1"; shift
  local errfile
  errfile="$(mktemp)"
  RC=0
  OUT="$(VAULT="$vault" python3 "$SCRIPT" "$@" 2>"$errfile")" || RC=$?
  STDERR="$(cat "$errfile")"
  rm -f "$errfile"
}

echo "=== 1. A2: 影響語がヒットするのに適用欄に無いノートは漏れ疑い・exit 1 ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-taisei-change.md" \
    "date: 2026-07-01
aliases: [特殊波及ワードX]" \
    "# 特殊体制変更の決定

**特殊波及ワードXの運用を全面変更する**

## 適用
- [[Preferences/recorded-note]] を修正済み"
  write_note "$V" "Preferences/recorded-note.md" "date: 2026-07-01" \
    "特殊波及ワードXは新方式で運用する"
  write_note "$V" "Knowledge/missed-note.md" "date: 2026-06-01" \
    "特殊波及ワードXは従来方式で運用する"
  write_note "$V" "Knowledge/unrelated-note.md" "date: 2026-06-01" \
    "無関係な内容だけのノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-taisei-change.md"
  assert_eq "漏れ疑いありなので exit 1" "1" "$RC"
  assert_contains "漏れ疑いノートが列挙される" "$OUT" "\`Knowledge/missed-note.md\`（ヒット 1 行）"
  assert_contains "該当行の抜粋と影響語が出る" "$OUT" "従来方式で運用する（影響語: \`特殊波及ワードX\`）"
  assert_contains "適用欄記載ノートは記録済み区分に完全パスで出る" "$OUT" "- \`Preferences/recorded-note.md\` — 影響語ヒット 1 行"
  assert_not_contains "記録済みノートは漏れ疑いに出ない" "$OUT" "- \`Preferences/recorded-note.md\`（ヒット"
  assert_not_contains "影響語がヒットしないノートはどこにも出ない" "$OUT" "unrelated-note"
  assert_contains "サマリに漏れ疑い件数が出る" "$OUT" "波及漏れの疑い: 1 ノート"

  rm -rf "$V"
}

echo "=== 2. A3: deprecated/廃止 行のみにヒットするノートは漏れ扱いしない・exit 0 ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-stale-line.md" \
    "date: 2026-07-01
aliases: [特殊波及ワードY]" \
    "# 特殊波及ワードYを廃止する決定

## 適用
- [[Preferences/already-fixed]]"
  write_note "$V" "Preferences/already-fixed.md" "date: 2026-07-01" "修正済みノート"
  write_note "$V" "Knowledge/stale-only-note.md" "date: 2026-06-01" \
    "特殊波及ワードYは廃止済み（新体制側の記述）
deprecated: 特殊波及ワードYの旧手順"
  write_note "$V" "Knowledge/live-hit-note.md" "date: 2026-06-01" \
    "特殊波及ワードYを現役ルールとして使う"

  run_check "$V" --decision "$V/Decisions/2026-07-01-stale-line.md"
  assert_eq "生きた記述のヒットがあるので exit 1（stale行除外の対照群）" "1" "$RC"
  assert_not_contains "廃止/deprecated行のみのノートは漏れに出ない" "$OUT" "stale-only-note"
  assert_contains "廃止語を含まない行のヒットは漏れに出る" "$OUT" "\`Knowledge/live-hit-note.md\`"

  rm -rf "$V"
}

echo "=== 3. A3補: 全ヒットがstale行なら漏れ0件で exit 0 ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-stale-only.md" \
    "date: 2026-07-01
aliases: [特殊波及ワードZ]" \
    "# 特殊波及ワードZの決定

## 適用
- [[Preferences/already-fixed]]"
  write_note "$V" "Preferences/already-fixed.md" "date: 2026-07-01" "修正済みノート"
  write_note "$V" "Knowledge/stale-only-note.md" "date: 2026-06-01" \
    "特殊波及ワードZは撤去済み（旧方式）"
  # 「旧手順」「旧ルール」等、列挙されていない任意の「旧＋名詞」も除外される
  # （Codexレビュー指摘・Major: 旧方式|旧「|旧C の列挙だけでは拾えなかった）
  write_note "$V" "Knowledge/stale-old-rule-note.md" "date: 2026-06-01" \
    "特殊波及ワードZの旧ルールを参照しない
特殊波及ワードZの旧手順も参照しない"
  # 「旧 API」（空白挟み）・「DEPRECATED」（大文字）の表記ゆれも除外される
  # （Codexレビュー3巡目・Major/Minor）
  write_note "$V" "Knowledge/stale-variant-note.md" "date: 2026-06-01" \
    "旧 API の特殊波及ワードZは使わない
DEPRECATED: 特殊波及ワードZ"

  run_check "$V" --decision "$V/Decisions/2026-07-01-stale-only.md"
  assert_eq "漏れ疑いなしなので exit 0" "0" "$RC"
  assert_contains "漏れ疑いなしの表示" "$OUT" "✅ なし"
  assert_not_contains "旧ルール/旧手順の行のみのノートも漏れに出ない" "$OUT" "stale-old-rule-note"
  assert_not_contains "旧 API（空白挟み）/DEPRECATED（大文字）の行のみのノートも漏れに出ない" \
    "$OUT" "stale-variant-note"

  rm -rf "$V"
}

echo "=== 4. A4: 適用欄の無い Decision は「適用欄なし」区分・漏れに混ぜない・exit 0 ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-no-apply.md" \
    "date: 2026-07-01
aliases: [特殊波及ワードW]" \
    "# 特殊波及ワードWの決定（適用欄を書き忘れた）"
  write_note "$V" "Knowledge/hit-note.md" "date: 2026-06-01" \
    "特殊波及ワードWを使う現在形ノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-no-apply.md"
  assert_eq "適用欄なしは漏れ疑いに数えないので exit 0" "0" "$RC"
  assert_contains "適用欄なしの区分表示が出る" "$OUT" "**適用欄なし**"
  assert_contains "サマリに適用欄なし 1件が出る" "$OUT" "適用欄なし Decision: 1 件"
  assert_contains "サマリの漏れ疑いは 0 ノート" "$OUT" "波及漏れの疑い: 0 ノート"
  assert_contains "影響語ヒットは参考として列挙される" "$OUT" "- \`Knowledge/hit-note.md\`（ヒット 1 行）"
  assert_not_contains "漏れ疑いセクション自体が出ない" "$OUT" "### 波及漏れの疑い"

  rm -rf "$V"
}

echo "=== 5. F4: 適用欄見出しの表記ゆれ（### 適用／## 適用（日付）／適用範囲は誤認しない） ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-h3-apply.md" \
    "date: 2026-07-01
aliases: [表記ゆれワードA]" \
    "# 表記ゆれワードAの決定

### 適用
- [[Preferences/h3-recorded]]"
  write_note "$V" "Decisions/2026-07-02-dated-apply.md" \
    "date: 2026-07-02
aliases: [表記ゆれワードB]" \
    "# 表記ゆれワードBの決定

## 適用（2026-07-02）
- [[Preferences/dated-recorded]]"
  write_note "$V" "Decisions/2026-07-03-scope-heading.md" \
    "date: 2026-07-03
aliases: [表記ゆれワードC]" \
    "# 表記ゆれワードCの決定

## 適用範囲の調整
- これは適用欄ではない（別語の見出し）"
  write_note "$V" "Preferences/h3-recorded.md" "date: 2026-07-01" "表記ゆれワードAを使う"
  write_note "$V" "Preferences/dated-recorded.md" "date: 2026-07-01" "表記ゆれワードBを使う"

  run_check "$V" --decision "$V/Decisions/2026-07-01-h3-apply.md"
  assert_contains "### 適用 が適用欄として認識される" "$OUT" "- \`Preferences/h3-recorded.md\` — 影響語ヒット 1 行"
  assert_eq "### 適用 の Decision は漏れなし exit 0" "0" "$RC"

  run_check "$V" --decision "$V/Decisions/2026-07-02-dated-apply.md"
  assert_contains "## 適用（YYYY-MM-DD） が適用欄として認識される" "$OUT" "- \`Preferences/dated-recorded.md\` — 影響語ヒット 1 行"

  run_check "$V" --decision "$V/Decisions/2026-07-03-scope-heading.md"
  assert_contains "「適用範囲」見出しは適用欄と誤認せず適用欄なし扱い" "$OUT" "**適用欄なし**"

  rm -rf "$V"
}

echo "=== 5b. F4/F2: コードフェンス内の「## 適用」見出し・太字は実体と誤認しない ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  # フェンス内にだけ「## 適用」と太字がある Decision（例示コードを引用した想定）。
  # 旧実装はフェンス内見出しで「適用欄あり」と誤判定し（A4区分破壊）、
  # フェンス内太字から偽影響語を抽出していた（Codexレビュー指摘・Major×2）
  write_note "$V" "Decisions/2026-07-01-fenced-heading.md" \
    "date: 2026-07-01
aliases: [フェンス見出し検証語句]" \
    '# フェンス見出し検証語句の決定

例示コード:

```
## 適用
- [[Preferences/fake-recorded]]
**フェンス内偽影響語句**
```'
  write_note "$V" "Knowledge/fake-term-note.md" "date: 2026-06-01" \
    "フェンス内偽影響語句を含むだけのノート"
  write_note "$V" "Knowledge/real-term-note.md" "date: 2026-06-01" \
    "フェンス見出し検証語句を含むノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-fenced-heading.md"
  assert_contains "フェンス内の ## 適用 は適用欄と誤認せず適用欄なし扱い（A4）" "$OUT" "**適用欄なし**"
  assert_not_contains "フェンス内太字から偽影響語を抽出しない" "$OUT" "フェンス内偽影響語句を含むだけ"
  assert_contains "本物の影響語（aliases由来）のヒットは参考として出る" "$OUT" "\`Knowledge/real-term-note.md\`"

  rm -rf "$V"
}

echo "=== 5c. F5: 影響語を抽出できない Decision は「検証不能」として明示される ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  # aliases なし・太字なし・H1 が最低語長未満（2字）→ 影響語0件
  write_note "$V" "Decisions/2026-07-01-no-terms.md" \
    "date: 2026-07-01" \
    "# メモ

## 適用
- なし"
  write_note "$V" "Knowledge/some-note.md" "date: 2026-06-01" "無関係な内容"

  run_check "$V" --decision "$V/Decisions/2026-07-01-no-terms.md"
  assert_eq "検証不能でも実行エラーではないので exit 0" "0" "$RC"
  assert_contains "サマリに検証不能 Decision の件数が出る" "$OUT" "影響語を抽出できなかった Decision: 1 件"
  assert_contains "Decision 個別にも検証不能の警告が出る" "$OUT" "⚠️ **影響語抽出不能**"

  rm -rf "$V"
}

echo "=== 6. F3: 除外対象（Decision自身・Decisions/配下・mistakes-archive）はヒットしない ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-exclusion.md" \
    "date: 2026-07-01
aliases: [除外検証ワード]" \
    "# 除外検証ワードの決定

本文にも除外検証ワードが登場する（自分自身は照合対象外）

## 適用
- なし"
  write_note "$V" "Decisions/2026-06-01-old-decision.md" "date: 2026-06-01" \
    "除外検証ワードを含む別のDecision（履歴＝対象外）"
  write_note "$V" "Knowledge/mistakes-archive.md" "date: 2026-06-01" \
    "除外検証ワードを含む失敗アーカイブ（履歴＝対象外）"
  write_note "$V" "Knowledge/current-note.md" "date: 2026-06-01" \
    "除外検証ワードを含む現在形ノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-exclusion.md"
  assert_not_contains "Decision自身はヒットに出ない" "$OUT" "2026-07-01-exclusion.md\`（ヒット"
  assert_not_contains "Decisions/配下の他ノートは走査されない" "$OUT" "old-decision"
  assert_not_contains "mistakes-archiveは走査されない" "$OUT" "mistakes-archive"
  assert_contains "現在形ノートのヒットは漏れ疑いに出る" "$OUT" "\`Knowledge/current-note.md\`"

  rm -rf "$V"
}

echo "=== 7. F6: 汎用語（多数ノートに出現）の単独ヒットでは漏れ扱いしない ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  # 「よくある汎用語句」を6ノート（GENERIC_DF_MIN=5以上）に撒く → DFフィルタで除外
  for i in 1 2 3 4 5 6; do
    write_note "$V" "Knowledge/common-$i.md" "date: 2026-06-01" \
      "よくある汎用語句を含むノート $i"
  done
  write_note "$V" "Decisions/2026-07-01-generic.md" \
    "date: 2026-07-01
aliases: [よくある汎用語句]" \
    "# 汎用語しか持たない決定

## 適用
- なし"

  run_check "$V" --decision "$V/Decisions/2026-07-01-generic.md"
  assert_eq "汎用語の単独ヒットでは漏れ扱いせず exit 0" "0" "$RC"
  assert_contains "汎用のため除外した影響語がレポートに明示される" "$OUT" "汎用のため照合から除外した影響語"
  assert_contains "除外語とDFが出る" "$OUT" "\`よくある汎用語句\`(DF=6)"
  assert_not_contains "汎用語ヒットのノートは漏れ疑いに出ない" "$OUT" "common-1.md\`（ヒット"

  rm -rf "$V"
}

echo "=== 7b. F6: 小規模Vault（DF下限5未満）でも全ノート飽和の汎用語は除外する ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  # 3ノート全部（=8割以上）に同じ語 → 絶対下限5に満たない規模でも汎用扱い
  # （Codexレビュー指摘・Major: 旧実装は5件未満のVaultで汎用語が素通りした）
  for i in 1 2 3; do
    write_note "$V" "Knowledge/small-common-$i.md" "date: 2026-06-01" \
      "小規模でも頻出する語句を含むノート $i"
  done
  write_note "$V" "Decisions/2026-07-01-small-generic.md" \
    "date: 2026-07-01
aliases: [小規模でも頻出する語句]" \
    "# 小規模Vault汎用語の決定

## 適用
- なし"

  run_check "$V" --decision "$V/Decisions/2026-07-01-small-generic.md"
  assert_eq "3ノート全てに出る語は汎用扱い＝漏れなし exit 0" "0" "$RC"
  assert_contains "飽和した語が除外語として明示される" "$OUT" "\`小規模でも頻出する語句\`(DF=3)"
  assert_not_contains "飽和語ヒットのノートは漏れ疑いに出ない" "$OUT" "small-common-1.md\`（ヒット"

  rm -rf "$V"
}

echo "=== 8. F2: 影響語は aliases／H1タイトル／太字 の3系統から導出される ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-sources.md" \
    "date: 2026-07-01
aliases: [エイリアス由来語]" \
    "# タイトル由来語の決定

本文の **太字由来語を採用する** という決定。短い太字 **実装** は語長で捨てられる。

## 適用
- なし"
  write_note "$V" "Knowledge/hit-by-alias.md" "date: 2026-06-01" "エイリアス由来語を含む"
  write_note "$V" "Knowledge/hit-by-title.md" "date: 2026-06-01" "タイトル由来語を含む"
  write_note "$V" "Knowledge/hit-by-bold.md" "date: 2026-06-01" "太字由来語を採用する予定"
  write_note "$V" "Knowledge/hit-by-short.md" "date: 2026-06-01" "実装の話だけを含む"

  run_check "$V" --decision "$V/Decisions/2026-07-01-sources.md"
  assert_contains "aliases由来の語でヒットする" "$OUT" "\`Knowledge/hit-by-alias.md\`"
  assert_contains "H1タイトル由来の語でヒットする" "$OUT" "\`Knowledge/hit-by-title.md\`"
  assert_contains "太字由来の語でヒットする" "$OUT" "\`Knowledge/hit-by-bold.md\`"
  assert_not_contains "最低語長未満の語（実装=2字）は影響語にならない（F6(a)）" "$OUT" "hit-by-short"

  rm -rf "$V"
}

echo "=== 8b. F4: 空白を含むファイル名の適用欄記載も記録済みと判定する ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-space-name.md" \
    "date: 2026-07-01
aliases: [空白名検証ワード]" \
    "# 空白名検証ワードの決定

## 適用
- coding delegation.md を修正済み
- メモ 帳.md も修正済み"
  # 空白を含む裸のファイル名（ASCII）とフォールバック頼みの日本語ファイル名
  # （Codexレビュー指摘・Major: 旧実装は空白で分断され記録済みでも漏れ扱いした）
  write_note "$V" "Preferences/coding delegation.md" "date: 2026-07-01" \
    "空白名検証ワードを使うノート"
  write_note "$V" "Knowledge/メモ 帳.md" "date: 2026-07-01" \
    "空白名検証ワードを使う日本語名ノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-space-name.md"
  assert_eq "空白入りファイル名の記載が記録済みと判定され漏れなし exit 0" "0" "$RC"
  assert_not_contains "空白入りASCII名は漏れ疑いに出ない" "$OUT" "coding delegation.md\`（ヒット"
  assert_not_contains "空白入り日本語名も（フォールバックで）漏れ疑いに出ない" "$OUT" "メモ 帳.md\`（ヒット"
  # 記録済み欄の表示はノートの完全パス（Codexレビュー指摘・Major/Minor:
  # 旧実装は末尾断片「帳」だけを「ヒットなし」と誤報していた）
  assert_contains "ASCII空白名は記録済み欄に完全パスで出る" "$OUT" "- \`Preferences/coding delegation.md\` — 影響語ヒット 1 行"
  assert_contains "日本語空白名も記録済み欄に完全パスで出る" "$OUT" "- \`Knowledge/メモ 帳.md\` — 影響語ヒット 1 行（適用欄本文の記載に一致）"
  assert_not_contains "末尾断片の偽エントリ（帳）は表示されない" "$OUT" "- \`帳\`"

  rm -rf "$V"
}

echo "=== 8d. F3: NFC/NFD 正規化差があっても照合・突合できる ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  # Decision 側の alias を NFD（分解形）で書く。ノート本文は NFC（合成形）。
  # 正規化なしでは substring 一致が外れる（Codexレビュー指摘・Major）
  NFD_WORD="$(python3 -c 'import sys,unicodedata;sys.stdout.write(unicodedata.normalize("NFD","ガイド検証語句"))')"
  write_note "$V" "Decisions/2026-07-01-nfd.md" \
    "date: 2026-07-01
aliases: [$NFD_WORD]" \
    "# NFD正規化検証の決定

## 適用
- なし"
  write_note "$V" "Knowledge/nfc-note.md" "date: 2026-06-01" \
    "ガイド検証語句を使う現在形ノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-nfd.md"
  assert_eq "NFD alias でも NFC 本文にヒットして exit 1" "1" "$RC"
  assert_contains "NFC ノートが漏れ疑いに出る" "$OUT" "\`Knowledge/nfc-note.md\`"

  rm -rf "$V"
}

echo "=== 8c. F4: フォルダ付き記載は同名stemの別フォルダノートを記録済みにしない ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-cross-folder.md" \
    "date: 2026-07-01
aliases: [同名判定検証ワード]" \
    "# 同名判定検証ワードの決定

## 適用
- [[Preferences/shared-stem]]"
  # 同じ stem のノートが2フォルダに存在（Codexレビュー指摘・Major: 旧実装は
  # Preferences/shared-stem の記録だけで Knowledge/shared-stem.md まで記録済み扱い）
  write_note "$V" "Preferences/shared-stem.md" "date: 2026-07-01" \
    "同名判定検証ワードを使う（記録済み側）"
  write_note "$V" "Knowledge/shared-stem.md" "date: 2026-07-01" \
    "同名判定検証ワードを使う（未記録側）"

  run_check "$V" --decision "$V/Decisions/2026-07-01-cross-folder.md"
  assert_eq "未記録側があるので exit 1" "1" "$RC"
  assert_contains "記録された側は記録済み区分（完全パス表示）" "$OUT" "- \`Preferences/shared-stem.md\` — 影響語ヒット 1 行"
  assert_contains "同名stemの別フォルダノートは漏れ疑いに出る" "$OUT" "- \`Knowledge/shared-stem.md\`（ヒット 1 行）"

  rm -rf "$V"
}

echo "=== 8e. F3: 照合は casefold（Unicode大小文字対応。lower では外れるß等） ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  # alias は「Straße検証語句」・ノート本文は大文字「STRASSE検証語句」。
  # lower() では straße≠strasse で外れる（Codexレビュー3巡目・Major）
  write_note "$V" "Decisions/2026-07-01-casefold.md" \
    "date: 2026-07-01
aliases: [Straße検証語句]" \
    "# casefold検証の決定

## 適用
- なし"
  write_note "$V" "Knowledge/casefold-note.md" "date: 2026-06-01" \
    "STRASSE検証語句を使う現在形ノート"

  run_check "$V" --decision "$V/Decisions/2026-07-01-casefold.md"
  assert_eq "casefold 照合でヒットし exit 1" "1" "$RC"
  assert_contains "大小文字対応の異なるノートが漏れ疑いに出る" "$OUT" "\`Knowledge/casefold-note.md\`"

  rm -rf "$V"
}

echo "=== 9. F3裁量: コードフェンス内のヒットは漏れ扱いしない ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-fence.md" \
    "date: 2026-07-01
aliases: [フェンス検証ワード]" \
    "# フェンス検証ワードの決定

## 適用
- なし"
  write_note "$V" "Knowledge/fence-only-note.md" "date: 2026-06-01" \
    '```
フェンス検証ワードはコマンド例の中だけに登場
```'

  run_check "$V" --decision "$V/Decisions/2026-07-01-fence.md"
  assert_eq "フェンス内のみのヒットは漏れにせず exit 0" "0" "$RC"
  assert_not_contains "フェンス内のみのノートは出ない" "$OUT" "fence-only-note"

  rm -rf "$V"
}

echo "=== 10. F1: --since で日付フィルタ・省略時は直近30日 ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/$(d_date -5)-recent.md" \
    "date: $(d_date -5)
aliases: [直近決定ワード]" \
    "# 直近決定ワードの決定

## 適用
- なし"
  write_note "$V" "Decisions/$(d_date -50)-old.md" \
    "date: $(d_date -50)
aliases: [古い決定ワード]" \
    "# 古い決定ワードの決定

## 適用
- なし"
  write_note "$V" "Decisions/README.md" "date: 2026-01-01" "# Decisions index"
  # サブディレクトリの Decision も走査対象（Codexレビュー指摘・Major:
  # 非再帰 glob は Decisions/archive/ 等を無言で取りこぼしていた）
  write_note "$V" "Decisions/archive/$(d_date -5)-nested.md" \
    "date: $(d_date -5)
aliases: [入れ子決定語句]" \
    "# 入れ子決定語句の決定

## 適用
- なし"
  write_note "$V" "Knowledge/dummy.md" "date: 2026-06-01" "無関係"

  run_check "$V" --since "$(d_date -10)"
  assert_eq "--since はエラーなく完走" "0" "$RC"
  assert_contains "since以降の Decision は対象" "$OUT" "recent.md"
  assert_contains "サブディレクトリの Decision も対象" "$OUT" "archive/$(d_date -5)-nested.md"
  assert_not_contains "since より古い Decision は対象外" "$OUT" "-old.md"
  assert_not_contains "README.md は対象外" "$OUT" "README"

  run_check "$V"
  assert_contains "引数省略時は直近30日対象（-5日は入る）" "$OUT" "recent.md"
  assert_not_contains "引数省略時に50日前は入らない" "$OUT" "-old.md"
  assert_contains "サマリに既定の対象範囲が出る" "$OUT" "直近30日"

  rm -rf "$V"
}

echo "=== 11. F5: --out でファイル出力・stdout と同内容 ==="
{
  V="$(mktemp -d)"
  OUTDIR="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-out.md" \
    "date: 2026-07-01
aliases: [出力検証ワード]" \
    "# 出力検証ワードの決定

## 適用
- なし"

  run_check "$V" --decision "$V/Decisions/2026-07-01-out.md" --out "$OUTDIR/report.md"
  if [[ -f "$OUTDIR/report.md" ]]; then
    pass "--out でレポートファイルが生成される"
  else
    fail_case "--out でレポートファイルが生成されない"
  fi
  if diff -q <(printf '%s\n' "$OUT") "$OUTDIR/report.md" >/dev/null 2>&1 || \
     [[ "$OUT" == "$(cat "$OUTDIR/report.md")" ]]; then
    pass "--out の内容が stdout と一致する"
  else
    fail_case "--out の内容が stdout と一致しない"
  fi

  # 書込失敗も「実行エラー=2」の契約に含める（Codexレビュー指摘・Major/Minor:
  # 旧実装は例外処理外で traceback + exit 1 になり漏れ疑い=1 と区別できなかった）
  run_check "$V" --decision "$V/Decisions/2026-07-01-out.md" --out "$OUTDIR"
  assert_eq "--out が既存ディレクトリなら exit 2" "2" "$RC"
  assert_contains "書込失敗の理由が stderr に出る" "$STDERR" "書き込めません"

  RODIR="$(mktemp -d)"
  chmod 555 "$RODIR"
  run_check "$V" --decision "$V/Decisions/2026-07-01-out.md" --out "$RODIR/sub/report.md"
  assert_eq "--out の親ディレクトリが作成不能（権限なし）なら exit 2" "2" "$RC"
  chmod 755 "$RODIR"

  rm -rf "$V" "$OUTDIR" "$RODIR"
}

echo "=== 12. A7: Vault へ一切書き込まない（--out で Vault 配下を指すと拒否 exit 2） ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-ro.md" \
    "date: 2026-07-01
aliases: [読取専用検証ワード]" \
    "# 読取専用検証ワードの決定

## 適用
- なし"
  write_note "$V" "Knowledge/some-note.md" "date: 2026-06-01" "読取専用検証ワードあり"

  SNAPSHOT="$(mktemp -d)"
  cp -R "$V/" "$SNAPSHOT/vault/"

  run_check "$V" --decision "$V/Decisions/2026-07-01-ro.md"
  if diff -r "$V" "$SNAPSHOT/vault" >/dev/null 2>&1; then
    pass "実行後も Vault の内容が完全に不変（A7）"
  else
    fail_case "実行後に Vault の内容が変化した（A7違反）"
  fi

  run_check "$V" --decision "$V/Decisions/2026-07-01-ro.md" --out "$V/Knowledge/report.md"
  assert_eq "--out が Vault 配下なら exit 2 で拒否" "2" "$RC"
  assert_contains "拒否理由が stderr に出る" "$STDERR" "読み取り専用のため拒否"
  if [[ ! -f "$V/Knowledge/report.md" ]]; then
    pass "拒否時に Vault 配下へファイルが作られていない"
  else
    fail_case "拒否したのに Vault 配下にファイルが作られた"
  fi

  rm -rf "$V" "$SNAPSHOT"
}

echo "=== 13. F5: 実行エラーは exit 2（存在しない --decision・不正な --since） ==="
{
  V="$(mktemp -d)"
  make_vault "$V"

  run_check "$V" --decision "$V/Decisions/no-such-file.md"
  assert_eq "存在しない --decision は exit 2" "2" "$RC"
  assert_contains "エラーメッセージが stderr に出る" "$STDERR" "error:"

  run_check "$V" --since "not-a-date"
  assert_eq "不正な --since は exit 2" "2" "$RC"

  run_check "/nonexistent-vault-dir-xyz" --since "2026-01-01"
  assert_eq "Vault が存在しなければ exit 2" "2" "$RC"

  rm -rf "$V"
}

echo "=== 14. F3/F5: 現在形ノートの読取失敗は走査不完全として exit 2 ==="
{
  V="$(mktemp -d)"
  make_vault "$V"
  write_note "$V" "Decisions/2026-07-01-unreadable.md" \
    "date: 2026-07-01
aliases: [読取失敗検証語句]" \
    "# 読取失敗検証語句の決定

## 適用
- なし"
  write_note "$V" "Knowledge/ok-note.md" "date: 2026-06-01" "読める現在形ノート"
  write_note "$V" "Knowledge/broken-note.md" "date: 2026-06-01" "読めない現在形ノート"
  chmod 000 "$V/Knowledge/broken-note.md"

  run_check "$V" --decision "$V/Decisions/2026-07-01-unreadable.md"
  assert_eq "読取失敗ノートがあると走査不完全＝exit 2" "2" "$RC"
  assert_contains "レポートに走査不完全の警告と対象ノートが出る" "$OUT" "読み取れなかったノート: 1 件"
  assert_contains "stderr に走査不完全の理由が出る" "$STDERR" "走査が不完全"

  chmod 644 "$V/Knowledge/broken-note.md"
  rm -rf "$V"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
