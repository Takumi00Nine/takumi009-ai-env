#!/usr/bin/env bash
# scripts/vault-agents/keyword_recall_helper.py のユニットテスト（想起フック補助・
# キーワード全体一致＋トークン部分一致の二段構え。8.2ラウンド「統一リファクタリング」で
# claude/hooks/vault-recall.shからPythonへ移植した際に新設）。
#
# helperを直接subprocessで叩く（vector_recall_helper.pyのテストと同じ流儀）。挙動の
# 詳細な期待値は claude/hooks/vault-recall-legacy.sh のコメント・旧tests/test-vault-recall.sh
# と揃えてある（移植元と挙動を完全一致させる検収条件のため）。
#
# 実行方法: bash tests/test-keyword-recall-helper.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/keyword_recall_helper.py"

# bashのファイル名グロブ展開順（strcoll）を再現するhelper側のロケール依存ソートを
# 決定的にするため、production同様UTF-8ロケールを明示する
# （claude/hooks/vault-recall.shのLC_ALL補正ブロックと同じ意図）。
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

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
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
}

write_note() {
  # write_note <path> <frontmatter本文(改行区切り)> [本文]
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  { echo "---"; printf '%s\n' "$fm"; echo "---"; echo; printf '%s\n' "$body"; } > "$path"
}

# helperを実行し、標準出力(JSON文字列)を返す。
run_helper() {
  local vault="$1" query="$2"
  shift 2
  python3 "$SCRIPT" --query "$query" --vault "$vault" "$@"
}

# JSONから .candidates[].relpath のPythonリスト表現を取り出す。
relpaths_of() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print([c['relpath'] for c in d['candidates']])"
}

echo "=== 1. 正常ヒット: aliases(ブロックリスト)とファイル名由来キーの両方が拾われる ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/fail-open-and-observable-guards.md" \
    $'date: 2026-07-10\naliases:\n  - "fail-open"\n  - "無言のfail-open"'

  out="$(run_helper "$VAULT_DIR" "fail-openの設計原則についてざっくり教えて")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "ヒットしたノートが列挙される" "$relpaths" "fail-open-and-observable-guards.md"
  keys="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print([k['key'] for k in d['candidates'][0]['keys']])")"
  assert_contains "全体一致キー'fail-open'が含まれる" "$keys" "fail-open"
  partial_full="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); ks={k['key']: k['partial'] for k in d['candidates'][0]['keys']}; print(ks.get('fail-open'))")"
  assert_eq "'fail-open'は全体一致(partial=False)" "False" "$partial_full"

  rm -rf "$VAULT_DIR"
}

echo "=== 2. インライン配列: クォート内カンマは分割しない ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/tricky.md" $'date: 2026-07-10\naliases: ["fail, open", simplekeyword]'

  out="$(run_helper "$VAULT_DIR" "fail, openの設計について詳しく教えてください")"
  keys="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print([k['key'] for k in d['candidates'][0]['keys']])")"
  assert_contains "\"fail, open\"が分割されず1キーとして一致する" "$keys" "fail, open"

  out2="$(run_helper "$VAULT_DIR" "simplekeywordについて確認したい、十分な長さのプロンプトです")"
  relpaths2="$(printf '%s' "$out2" | relpaths_of)"
  assert_contains "後続のalias(simplekeyword)も壊れず拾える" "$relpaths2" "tricky.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 3. ASCII大文字小文字無視・最低文字数(ASCII3/非ASCII2)未満は対象外 ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/oss-prior-art-search.md" $'date: 2026-07-10\naliases:\n  - "OSSsearch"'
  write_note "$VAULT_DIR/Knowledge/short-ascii-alias.md" $'date: 2026-07-10\naliases:\n  - "go"'
  write_note "$VAULT_DIR/Knowledge/short-nonascii-alias.md" $'date: 2026-07-10\naliases:\n  - "話"'

  out="$(run_helper "$VAULT_DIR" "先にosssearchしてから実装したほうがいいと思う")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "大文字小文字を無視して一致する" "$relpaths" "oss-prior-art-search.md"

  out2="$(run_helper "$VAULT_DIR" "go言語の話をしましょうという長めのプロンプト")"
  relpaths2="$(printf '%s' "$out2" | relpaths_of)"
  assert_not_contains "ASCII2文字(go)は短すぎて一致しない" "$relpaths2" "short-ascii-alias.md"
  assert_not_contains "非ASCII1文字(話)は短すぎて一致しない" "$relpaths2" "short-nonascii-alias.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 4. 除外: README.md・EXCLUDE_RELPATHS(起動必読6件)はヒットしても候補に出ない ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/mistakes.md" $'date: 2026-07-10\naliases:\n  - "excludedkeyword"'
  write_note "$VAULT_DIR/Preferences/absolute-rules.md" $'date: 2026-07-10\naliases:\n  - "excludedkeyword2"'
  write_note "$VAULT_DIR/Personal/profile-personal.md" $'date: 2026-07-11\naliases:\n  - "excludedkeyword3"'
  write_note "$VAULT_DIR/Knowledge/README.md" $'date: 2026-07-10' "readme"

  out="$(run_helper "$VAULT_DIR" "excludedkeywordとexcludedkeyword2とexcludedkeyword3とREADMEについて聞きたい")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_not_contains "mistakes.mdは候補に出ない" "$relpaths" "mistakes.md"
  assert_not_contains "absolute-rules.mdは候補に出ない" "$relpaths" "absolute-rules.md"
  assert_not_contains "profile-personal.mdは候補に出ない" "$relpaths" "profile-personal.md"
  assert_not_contains "README.mdは候補に出ない" "$relpaths" "README.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 5. トークン部分一致: 2語キーの片方だけプロンプトに現れても一致する ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/orange-banana-note.md" $'date: 2026-07-10\naliases:\n  - "orange banana"'

  out="$(run_helper "$VAULT_DIR" "orangeについて詳しく教えてもらえますか")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "bananaが無くてもorangeだけで部分一致する" "$relpaths" "orange-banana-note.md"
  is_partial="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); ks={k['key']: k['partial'] for k in d['candidates'][0]['keys']}; print(ks.get('orange banana'))")"
  assert_eq "部分一致フラグがTrue" "True" "$is_partial"

  rm -rf "$VAULT_DIR"
}

echo "=== 6. 汎用トークン単独では部分一致しない ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/codex-howto-note.md" $'date: 2026-07-10\naliases:\n  - "Codex手順書"'

  out="$(run_helper "$VAULT_DIR" "Codexについて雑談したいだけなんだけど")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_not_contains "Codexという汎用トークン単独では一致しない" "$relpaths" "codex-howto-note.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 7. 活用形フォールバック: 単一トークンキー(漢字始まり)でも末尾ひらがな1文字ドロップで一致する ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/kanji-inflection.md" $'date: 2026-07-10\naliases:\n  - "崩れる"'

  out="$(run_helper "$VAULT_DIR" "設定が崩れた場合の対処を知りたいので教えてください")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "漢字始まりの単一alias「崩れる」が「崩れた」に一致する" "$relpaths" "kanji-inflection.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 8. カタカナ境界分割: 複合語の中のカタカナ語だけが独立して一致する ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Decisions/2026-07-05-impact-check-routine.md" \
    $'date: 2026-07-10\naliases:\n  - "波及影響チェック手順"'

  out="$(run_helper "$VAULT_DIR" "変更したときのチェックってどうやるんだっけ")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "複合語内の「チェック」だけでカタカナ境界分割により一致する" "$relpaths" "impact-check-routine.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 9. 部分一致の加点は1ノートにつき最大1回 ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Projects/inflated-note.md" \
    $'date: 2026-07-10\naliases:\n  - "banana keyA"\n  - "banana keyB"\n  - "banana keyC"'
  # ファイル名自体のトークン(zzz/unrelated/topic)がプロンプト・aliasのどの語とも
  # 重ならないよう選ぶ（ファイル名由来キーの部分一致が偶然混入してスコアを狂わせない
  # ため。"full-match-note"のような名前だと"full"/"match"トークンがalias
  # "distinctfullmatch"の部分文字列と一致してしまい比較対象として使えなくなる）。
  write_note "$VAULT_DIR/Projects/zzz-unrelated-topic.md" $'date: 2026-07-10\naliases:\n  - "distinctfullmatch"'

  out="$(run_helper "$VAULT_DIR" "distinctfullmatchとbananaについて確認したい、十分な長さです")"
  inflated_score="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print([c['score'] for c in d['candidates'] if c['relpath']=='Projects/inflated-note.md'][0])")"
  full_score="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print([c['score'] for c in d['candidates'] if c['relpath']=='Projects/zzz-unrelated-topic.md'][0])")"
  assert_eq "3つのalias全てがbananaを共有していても部分一致スコアは1のまま" "1" "$inflated_score"
  assert_eq "全体一致は2のまま（比較対象）" "2" "$full_score"

  rm -rf "$VAULT_DIR"
}

echo "=== 10. 読み取れないノート: ファイル名キーのみでフォールバックしunreadable_countに計上される ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/locked-note.md" $'date: 2026-07-10\naliases:\n  - "lockedbodyalias"'
  chmod 000 "$VAULT_DIR/Knowledge/locked-note.md"

  out="$(run_helper "$VAULT_DIR" "lockednoteについて確認したい、十分な長さのプロンプトです")"
  chmod 644 "$VAULT_DIR/Knowledge/locked-note.md"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "本文が読めなくてもファイル名キー(ハイフン除去)で一致する" "$relpaths" "locked-note.md"
  unreadable="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['unreadable_count'])")"
  assert_eq "unreadable_countが1になる" "1" "$unreadable"

  rm -rf "$VAULT_DIR"
}

echo "=== 11. スコア降順・同点は走査順(ファイル名のグロブ展開順)でtie-breakされる ==="
{
  VAULT_DIR="$(mktemp -d)"
  # 3つとも同じ全体一致1件だけ＝同スコア(2)。ファイル名は昇順に並ぶよう命名。
  for n in aa1 bb2 cc3; do
    write_note "$VAULT_DIR/Knowledge/tie-$n.md" \
      "$(printf 'date: 2026-07-10\naliases:\n  - "tiemarkerkeyword"')"
  done
  # 別ディレクトリの高スコア候補（全体一致2件）も混ぜ、スコア降順が優先されることを確認する。
  write_note "$VAULT_DIR/Preferences/top-note.md" \
    $'date: 2026-07-10\naliases:\n  - "tiemarkerkeyword"\n  - "extratopkeyword"'

  out="$(run_helper "$VAULT_DIR" "tiemarkerkeywordとextratopkeywordについて全部確認したい")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_eq "最高スコアのtop-note.mdが先頭に来る" "['Preferences/top-note.md', 'Knowledge/tie-aa1.md', 'Knowledge/tie-bb2.md', 'Knowledge/tie-cc3.md']" "$relpaths"

  rm -rf "$VAULT_DIR"
}

echo "=== 12. クエリ空: exit非0（bad query） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/dummy.md" $'date: 2026-07-10'
  out="$(python3 "$SCRIPT" --query "" --vault "$VAULT_DIR" 2>&1)"
  rc=$?
  assert_eq "exit非0" "1" "$rc"
  rm -rf "$VAULT_DIR"
}

echo "=== 13. Vaultディレクトリが存在しない: exit非0（fail-open素材） ==="
{
  out="$(run_helper "/nonexistent-vault-dir-xyz" "何か質問です十分な長さです" 2>&1)"
  rc=$?
  assert_eq "exit非0" "2" "$rc"
  assert_contains "Vault不在のメッセージ" "$out" "Vaultディレクトリが見つかりません"
}

echo "=== 14. --budget-ms 0: 走査開始前に予算超過で打ち切りexit非0 ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/dummy.md" $'date: 2026-07-10\naliases:\n  - "dummykeyword"'
  out="$(run_helper "$VAULT_DIR" "dummykeywordについて確認したい、十分な長さです" --budget-ms 0 2>&1)"
  rc=$?
  assert_eq "exit非0" "3" "$rc"
  assert_contains "打ち切りメッセージ" "$out" "打ち切りました"
  rm -rf "$VAULT_DIR"
}

echo "=== 15. stdin経由でもクエリを受け取れる（--query省略時） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/stdin-note.md" $'date: 2026-07-10\naliases:\n  - "stdinkeyword"'
  out="$(printf 'stdinkeywordについて確認したい、十分な長さです' | python3 "$SCRIPT" --vault "$VAULT_DIR")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "stdin経由のクエリでもヒットする" "$relpaths" "stdin-note.md"
  rm -rf "$VAULT_DIR"
}

echo "=== 16. 隠しファイル(ドット始まり)は走査対象外（Codexレビュー指摘・Major回帰: pathlib.Path.globはbashのglob(dotglob無効)と異なりドットファイルにも一致してしまう） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/.hidden-note.md" $'date: 2026-07-10\naliases:\n  - "hiddenmarkerkeyword"'
  write_note "$VAULT_DIR/Knowledge/visible-note.md" $'date: 2026-07-10\naliases:\n  - "hiddenmarkerkeyword"'

  out="$(run_helper "$VAULT_DIR" "hiddenmarkerkeywordについて確認したい、十分な長さです")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_not_contains "ドット始まりのノートは候補に出ない" "$relpaths" ".hidden-note.md"
  assert_contains "通常のノートは候補に出る" "$relpaths" "visible-note.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 17. CRLF改行のfrontmatterは1行目が\"---\"と一致せず解析skipされる（legacyのbash read -rが行末に\\rを残す挙動をPython側でも再現。Codexレビュー指摘・Major対応） ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Knowledge"
  # write_noteヘルパーはLF固定なので、ここではprintfで直接CRLFファイルを作る。ファイル名の
  # トークンがalias/プロンプトのどの語とも重ならないよう選ぶ（テスト9と同じ注意点）。
  printf -- '---\r\naliases:\r\n  - "distinctcrlfonlyalias"\r\n---\r\n\r\n本文\r\n' \
    > "$VAULT_DIR/Knowledge/zzz-quux-sample.md"

  out="$(run_helper "$VAULT_DIR" "distinctcrlfonlyaliasについて確認したい、十分な長さです")"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_not_contains "CRLFノートのaliasは解析されない（legacyと同じ挙動）" "$relpaths" "zzz-quux-sample.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 18. バックスラッシュ・タブを含むaliasも壊れずJSONへ復元される（@tsv非使用の確認） ==="
{
  VAULT_DIR="$(mktemp -d)"
  # インライン配列でバックスラッシュを含むaliasを1つだけ定義する（split_inline_aliases/
  # legacyのbash実装ともYAMLの`\\`→`\`展開はしない＝ソース中の1個の"\"はそのまま1個の
  # "\"として値に残る仕様なので、ここでは$''の1重"\\"＝1文字の"\"を書けばよい）。
  write_note "$VAULT_DIR/Knowledge/backslash-note.md" $'date: 2026-07-10\naliases: ["C:\\path\\to\\file"]'

  out="$(run_helper "$VAULT_DIR" "C:\\path\\to\\fileについて確認したい、十分な長さです")"
  key="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['candidates'][0]['keys'][0]['key'])")"
  assert_eq "バックスラッシュが変質せず1文字ずつ復元される" 'C:\path\to\file' "$key"

  rm -rf "$VAULT_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
