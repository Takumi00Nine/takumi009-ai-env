#!/usr/bin/env bash
# 共有シェルライブラリ: Personal ノートへの wiki link 検出ロジック
# （2026-07-16 簡素化・cleanup決定#5「Personal リンク検査の共通モジュール化」）。
#
# scripts/export-public-vault.sh（3-a/3-b・fail-fast）と scripts/audit.sh
# （5・レポートのみ）が同じ検出ロジックをそれぞれ複製実装していた（ドリフト源。
# 2026-07-08時点のコメントに「folder_link_regex / build_basename_pattern_file の
# ロジックを変えた場合は export-public-vault.sh 側も同時に見直すこと」という手動同期
# の注意書きがあった）。本ファイルへ1本化し、両スクリプトから source する。
#
# 呼び出し規約: このファイルは関数定義のみ（副作用なし・source専用）。
# 出力先ファイルは呼び出し側が用意する（register_tmp等の一時ファイル管理は
# 呼び出し側の既存の流儀に委ねる＝このライブラリ自体はtrap/cleanupを持たない）。
# 全関数はrgと同じexit code規約（0=マッチあり／1=マッチなし／2以上=実行エラー）を
# そのまま呼び出し側へ伝える。
#
# 挙動不変の検収条件（cleanup決定#5・設計書§6 test-personal-link-check.sh）:
# 共通化前後でexport-public-vault.sh/audit.shの出力が完全一致すること。悪性fixture
# （Personal リンク混入）に対するnegative testも必須。

# フォルダ付き wiki link（[[Personal/xxx]] 等）検出用の正規表現を生成する。
# $1 = 対象フォルダ名の "|" 区切りalternation（例: "Personal" や "Knowledge|Decisions"）。
#
# 空白許容ポリシー（2026-07-08、tester 独立検証で発見された2件のMajorへの対応。
# 複製元=export-public-vault.shのコメントをそのまま踏襲）:
#  1件目: name と区切り文字（| # ^ ]）の**間**の空白 → `[[:space:]]*` を区切り文字の前に追加
#         （例: `[[career-private | alias]]` のようにpipeエイリアスの可読性目的で空白を
#          入れる書き方はObsidian実務でよくあるが、空白なし前提の正規表現だとすり抜けていた）
#  2件目: `[[` **直後**の空白 → `[[:space:]]*` を name の前にも追加
#         （例: `[[ career-private]]` のようなタイプミス/IME確定時の余分な空白）
personal_link_folder_regex() {
  local alt="$1"
  printf '\\[\\[[[:space:]]*(%s)[[:space:]]*/' "$alt"
}

# $1 = Vaultルート、$2以降 = basename denylistを生成する対象フォルダ名（可変長）、
# 最後の引数 = 出力先denylistファイルパス。
# 対象フォルダ配下の全 .md の basename（拡張子抜き）を重複排除して1行1件で書く。
# フォルダが存在しない（サブ機で私的パッチ未clone等）場合はそのフォルダ分は
# 単にスキップする（fail-openではなく「対象が無いだけ」の正常系）。
#
# 戻り値: 0=正常終了／1=findが1件でも失敗した（権限不備・I/Oエラー等）。
# 抽出前のexport-public-vault.shは`find ... >> "$BASENAME_DENYLIST"`を`set -e`下で
# 直接実行しており、findが失敗すればスクリプト全体が即座に停止していた（denylistが
# 不完全なまま後続のPersonalリンク検査へfail-openで進んでしまう事故を防ぐ設計）。
# 関数化に伴いパイプライン末尾が`sort`（常に成功しうる）になったことでこの
# fail-fastが暗黙に失われていたため、findの終了コードを明示的に検査して呼び出し元へ
# 伝える（Codexレビュー指摘・Major対応）。呼び出し側は戻り値1を「denylistが不完全
# かもしれない＝検査不能」として扱うこと（export側はfail、audit側はNG項目にする）。
personal_link_build_basename_denylist() {
  local vault="$1"; shift
  local out="${*: -1}"
  local -a folders=("${@:1:$#-1}")
  local find_failed=0
  : > "$out"
  local dir
  for dir in "${folders[@]}"; do
    if [[ -d "$vault/$dir" ]]; then
      find "$vault/$dir" -type f -name '*.md' -exec basename {} .md \; >> "$out" || find_failed=1
    fi
  done
  sort -u -o "$out" "$out"
  [[ "$find_failed" -eq 0 ]]
}

# basename 形式の wiki link パターン（[[name]] / [[name|alias]] / [[name#Heading]] /
# [[name^blockid]] の全バリエーションを拾う）を、denylist（1行1 basename）から
# rg -f 用のパターンファイルへ変換する。
# $1 = denylistファイルパス、$2 = 出力先パターンファイルパス。
personal_link_build_basename_pattern_file() {
  local denylist="$1" out="$2" name escaped
  : > "$out"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    escaped=$(printf '%s' "$name" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g')
    printf '\\[\\[[[:space:]]*%s[[:space:]]*([|#\\^]|\\])\n' "$escaped" >> "$out"
  done < "$denylist"
}
