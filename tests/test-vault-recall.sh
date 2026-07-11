#!/usr/bin/env bash
# claude/hooks/vault-recall.sh のユニットテスト（UserPromptSubmit・想起支援）。
#
# 実 Vault($HOME/Data/obsidian)・実ログには一切依存しない。VAULT_RECALL_VAULT・
# VAULT_RECALL_LOG 環境変数で毎回ダミーのfixtureへ差し替えて実行する。
#
# 実行方法: bash tests/test-vault-recall.sh

set -uo pipefail   # -e は使わない（jqの非0終了を明示的に見たいケースがあるため）

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/claude/hooks/vault-recall.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

write_note() {
  # write_note <path> <frontmatter本文(改行区切り)> [本文]
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  {
    echo "---"
    printf '%s\n' "$fm"
    echo "---"
    echo
    printf '%s\n' "$body"
  } > "$path"
}

# vault-recall.sh を実行し、標準出力(JSON文字列)を返す。
run_recall() {
  local vault="$1" log="$2" prompt="$3" session="${4:-sess-1}"
  local input
  input="$(jq -n --arg p "$prompt" --arg s "$session" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$vault" VAULT_RECALL_LOG="$log" "$SCRIPT"
}

echo "=== 1. 正常ヒット: aliases(ブロックリスト)とファイル名由来キーの両方が拾われる ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/fail-open-and-observable-guards.md" \
    $'date: 2026-07-10\naliases:\n  - "fail-open"\n  - "無言のfail-open"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "fail-openの設計原則についてざっくり教えて")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "ヒットしたノートが列挙される" "$ctx" "Knowledge/fail-open-and-observable-guards.md"
  assert_contains "一致キーが表示される" "$ctx" "一致: fail-open"
  assert_contains "hookEventNameがUserPromptSubmit" "$out" "UserPromptSubmit"
  assert_contains "ログにヒット行が残る" "$(cat "$LOG")" "sess-1	Knowledge/fail-open-and-observable-guards.md	fail-open"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 2. 正常ヒット: aliases(インライン配列)・ファイル名のハイフン除去キー ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Preferences/web-verify-before-acting.md" \
    $'date: 2026-07-10\naliases: [裏取り, "web verify"]'

  out="$(run_recall "$VAULT_DIR" "$LOG" "実装前に必ずwebverifybeforeactingを確認してください")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "ハイフン除去したファイル名キーで一致する" "$ctx" "Preferences/web-verify-before-acting.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 3. ASCIIキーは大文字小文字を無視して一致する ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/oss-prior-art-search.md" \
    $'date: 2026-07-10\naliases:\n  - "OSSsearch"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "先にosssearchしてから実装したほうがいいと思う")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "大文字小文字を無視して一致する" "$ctx" "Knowledge/oss-prior-art-search.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 4. 最低文字数: ASCII3文字未満・非ASCII2文字未満は対象外 ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/short-ascii-alias.md" \
    $'date: 2026-07-10\naliases:\n  - "go"'
  write_note "$VAULT_DIR/Knowledge/short-nonascii-alias.md" \
    $'date: 2026-07-10\naliases:\n  - "話"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "go言語の話をしましょうという長めのプロンプト")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  assert_not_contains "ASCII2文字(go)は短すぎて一致しない" "$ctx" "short-ascii-alias.md"
  assert_not_contains "非ASCII1文字(話)は短すぎて一致しない" "$ctx" "short-nonascii-alias.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 5. 除外ファイル: 起動必読5件・README.mdはヒットしても提示されない ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/mistakes.md" \
    $'date: 2026-07-10\naliases:\n  - "excludedkeyword"'
  write_note "$VAULT_DIR/Preferences/absolute-rules.md" \
    $'date: 2026-07-10\naliases:\n  - "excludedkeyword2"'
  mkdir -p "$VAULT_DIR/Knowledge"
  write_note "$VAULT_DIR/Knowledge/README.md" $'date: 2026-07-10' "readme"

  out="$(run_recall "$VAULT_DIR" "$LOG" "excludedkeywordとexcludedkeyword2とREADMEについて聞きたい")"
  rc=$?
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  assert_not_contains "mistakes.mdは提示されない" "$ctx" "mistakes.md"
  assert_not_contains "absolute-rules.mdは提示されない" "$ctx" "absolute-rules.md"
  assert_not_contains "README.mdは提示されない" "$ctx" "README.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 6. プロンプトが10文字未満なら何も出力せずexit 0（ログも残さない） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/mistakes-note.md" $'date: 2026-07-10\naliases:\n  - "短い"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "短い")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_eq "ログファイルは作られない" "0" "$([ -e "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 7. ヒット無しならexit 0・出力なし ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 8. fail-open: 壊れたJSON入力でもexit 0・ログにERROR行（3列目は空で無害化） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"

  out="$(printf 'not valid json at all' | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" "$SCRIPT")"
  rc=$?
  assert_eq "exit code 0（プロンプト処理を妨げない）" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_contains "ERROR行が残る（無言のfail-open防止）" "$logtext" "	ERROR	"
  col3="$(printf '%s' "$logtext" | cut -f3)"
  assert_eq "3列目(ノートパス位置)は空文字＝vault_inventory.pyの誤集計を防ぐ" "" "$col3"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 9. fail-open: Vaultディレクトリが存在しなくてもexit 0・ERROR行を残す ==="
{
  LOG="$(mktemp -d)/vault-recall.tsv"

  out="$(run_recall "/nonexistent-vault-dir-xyz" "$LOG" "これは十分に長いプロンプトです、探して")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_contains "ERROR行にVault不在が記録される" "$(cat "$LOG")" "Vaultディレクトリが見つかりません"

  rm -rf "$(dirname "$LOG")"
}

echo "=== 10. 最大5件・一致キー数の多い順 ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  for i in 1 2 3 4 5 6; do
    write_note "$VAULT_DIR/Projects/project-$i.md" \
      "$(printf 'date: 2026-07-10\naliases:\n  - "projectkeyword%d"' "$i")"
  done
  # project-1 だけ一致キーを2つにして最上位に来ることを確認する
  write_note "$VAULT_DIR/Projects/project-1.md" \
    $'date: 2026-07-10\naliases:\n  - "projectkeyword1"\n  - "extratopkeyword"'

  prompt="projectkeyword1 projectkeyword2 projectkeyword3 projectkeyword4 projectkeyword5 projectkeyword6 extratopkeyword について全部確認したい"
  out="$(run_recall "$VAULT_DIR" "$LOG" "$prompt")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  n_hits="$(printf '%s' "$ctx" | grep -c '^- ')"
  assert_eq "候補は最大5件に絞られる" "5" "$n_hits"
  first_line="$(printf '%s' "$ctx" | grep '^- ' | head -1)"
  assert_contains "一致キー数が最も多いnote(project-1)が先頭に来る" "$first_line" "project-1.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 11. 同一ノート内の重複キーは1回だけ数える（filenameキー=alias が被る場合） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Decisions/2026-07-10-sampledecision.md" \
    $'date: 2026-07-10\naliases:\n  - "2026-07-10-sampledecision"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "2026-07-10-sampledecisionについて詳しく教えてください")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  n_hits="$(printf '%s' "$ctx" | grep -c '^- ')"
  assert_eq "1ノートのみ提示される（重複カウントで複数扱いにならない）" "1" "$n_hits"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 12. 存在しないフォルダ(Decisions等)があってもエラーにならない（サブ機想定） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  mkdir -p "$VAULT_DIR/Knowledge"
  write_note "$VAULT_DIR/Knowledge/only-note.md" $'date: 2026-07-10\naliases:\n  - "onlynotekeyword"'
  # Preferences/Decisions/Projects フォルダを作らない

  out="$(run_recall "$VAULT_DIR" "$LOG" "onlynotekeywordについて確認したいことがあります")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "存在するフォルダのノートは正常にヒットする" "$ctx" "Knowledge/only-note.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 13. jqが無い環境でもexit 0・ERROR行を残す（Codexレビュー指摘・Minor: 旧テストはPATHを空にし過ぎてmkdir/dateも道連れに消え、ログ書き込み自体を検証できていなかった） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/dummy.md" $'date: 2026-07-10'

  # jq以外の必須コマンド(mkdir/dirname/date/cat)だけを含む隔離PATHを作る。
  # システムのjqが/usr/binにあり、mkdir等と分離できない環境があるため、
  # 個別にsymlinkを張ってjqだけを不在にする。
  BINDIR="$(mktemp -d)"
  for t in mkdir dirname date cat; do
    p="$(command -v "$t")"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$t"
  done

  out=$(printf '{"session_id":"s1","prompt":"これは十分に長いプロンプトです確認"}' \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" PATH="$BINDIR" "$SCRIPT" 2>&1)
  rc=$?
  assert_eq "exit code 0（jq不在でも落ちない）" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_contains "jq不在でもERROR行が残る（mkdir/date等は隔離PATHでも使えるため書ける）" "$logtext" $'\tERROR\t'

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")" "$BINDIR"
}

echo "=== 14. インライン配列: クォート内カンマは分割しない（Codexレビュー指摘・Major回帰） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/tricky.md" $'date: 2026-07-10\naliases: ["fail, open", simplekeyword]'

  # クォート内カンマを含むalias自体（"fail, open"）が1つのキーとして生き残って
  # いることを、それ単体で一致させて直接確認する（Codexレビュー指摘・Minor:
  # 従来は後続のsimplekeywordが拾えることしか見ておらず、分割されていないことの
  # 直接証拠になっていなかった）。
  out="$(run_recall "$VAULT_DIR" "$LOG" "fail, openの設計について詳しく教えてください")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "\"fail, open\"が分割されず1キーとして一致する" "$ctx" "一致: fail, open"

  out2="$(run_recall "$VAULT_DIR" "$LOG" "simplekeywordについて確認したい、十分な長さのプロンプトです")"
  ctx2="$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "後続のalias(simplekeyword)も壊れず拾える" "$ctx2" "Knowledge/tricky.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 14b. 一方のaliasが他方のprefixでも、両方が別々の一致として数えられる（Codexレビュー指摘・Minor回帰） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/prefix-test.md" \
    $'date: 2026-07-10\naliases:\n  - "foobar"\n  - "foo"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "fooとfoobarについて両方確認したいので教えてください")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "prefix関係にある短いほうのalias(foo)も一致として表示される" "$ctx" "一致: foobar, foo"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 15. 読み取れないノートはファイル名キーのみでフォールバックし、ERROR要約行を残す ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/locked-note.md" $'date: 2026-07-10\naliases:\n  - "lockedbodyalias"'
  chmod 000 "$VAULT_DIR/Knowledge/locked-note.md"

  out="$(run_recall "$VAULT_DIR" "$LOG" "lockednoteについて確認したい、十分な長さのプロンプトです")"
  chmod 644 "$VAULT_DIR/Knowledge/locked-note.md"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "本文が読めなくてもファイル名キーで一致する" "$ctx" "Knowledge/locked-note.md"
  assert_contains "読み取り不可の要約ERROR行が残る（無言のfail-open防止）" "$(cat "$LOG")" "件のノートを読み取れませんでした"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 16. トークン部分一致: 2語キーの片方だけがプロンプトに現れても一致する（8.0ラウンド） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/orange-banana-note.md" \
    $'date: 2026-07-10\naliases:\n  - "orange banana"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "orangeについて詳しく教えてもらえますか")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  assert_contains "bananaが無くてもorangeだけで部分一致する" "$ctx" "Knowledge/orange-banana-note.md"
  assert_contains "部分一致であることが表示に出る" "$ctx" "(部分一致)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 17. 単一トークンキーでも活用形フォールバックが届く（Codexレビュー指摘・Major対応） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/single-token-inflection.md" \
    $'date: 2026-07-10\naliases:\n  - "こわれる"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "システムがこわれた気がするので確認したい")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  assert_contains "単一alias「こわれる」が活用形「こわれた」に一致する" "$ctx" "Knowledge/single-token-inflection.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 17b. 漢字+ひらがな混在の単一トークン（ヘッダコメントの実例「壊れる」）でも活用形フォールバックが届く ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/kanji-inflection.md" \
    $'date: 2026-07-10\naliases:\n  - "崩れる"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "設定が崩れた場合の対処を知りたいので教えてください")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  assert_contains "漢字始まりの単一alias「崩れる」が「崩れた」に一致する" "$ctx" "Knowledge/kanji-inflection.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 18. 汎用トークン単独では部分一致しない（誤ヒット面拡大の防止） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Preferences/codex-howto-note.md" \
    $'date: 2026-07-10\naliases:\n  - "Codex手順書"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "Codexについて雑談したいだけなんだけど")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  assert_not_contains "Codexという汎用トークン単独では一致しない" "$ctx" "codex-howto-note.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 19. カタカナ境界分割: 複合語の中のカタカナ語だけが独立して一致する（8.0ラウンド） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Decisions/2026-07-05-impact-check-routine.md" \
    $'date: 2026-07-10\naliases:\n  - "波及影響チェック手順"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "変更したときのチェックってどうやるんだっけ")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  assert_contains "複合語内の「チェック」だけでカタカナ境界分割により一致する" "$ctx" "impact-check-routine.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 20. fail-open: カタカナ境界分割用のgrepが無くてもexit 0でクラッシュしない ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Decisions/2026-07-05-impact-check-routine.md" \
    $'date: 2026-07-10\naliases:\n  - "波及影響チェック手順"'

  BINDIR="$(mktemp -d)"
  for t in jq mkdir dirname date cat sed grep; do
    [ "$t" = "grep" ] && continue
    p="$(command -v "$t")"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$t"
  done

  out=$(printf '{"session_id":"s1","prompt":"変更したときのチェックってどうやるんだっけ"}' \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" PATH="$BINDIR" "$SCRIPT" 2>&1)
  rc=$?
  assert_eq "grep不在でもexit code 0" "0" "$rc"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")" "$BINDIR"
}

echo "=== 21. 部分一致の加点は1ノートにつき最大1回（同じトークンを共有する複数aliasでもスコアが積み上がらない） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  for i in 1 2 3 4 5; do
    write_note "$VAULT_DIR/Projects/filler-$i.md" \
      "$(printf 'date: 2026-07-10\naliases:\n  - "fillerkeyword%d"' "$i")"
  done
  # 3つのaliasが全て"banana"を共有する（もし加点が積み上がるならスコア3になり、
  # fillerkeyword(いずれもスコア2の全体一致)5件より上位に来てしまう）。
  write_note "$VAULT_DIR/Projects/inflated-note.md" \
    $'date: 2026-07-10\naliases:\n  - "banana keyA"\n  - "banana keyB"\n  - "banana keyC"'

  prompt="fillerkeyword1 fillerkeyword2 fillerkeyword3 fillerkeyword4 fillerkeyword5 bananaについて全部確認したい"
  out="$(run_recall "$VAULT_DIR" "$LOG" "$prompt")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  n_hits="$(printf '%s' "$ctx" | grep -c '^- ')"
  assert_eq "候補は最大5件のまま" "5" "$n_hits"
  assert_not_contains "部分一致が積み上がらないため加点1点のinflated-noteは上位5件から漏れる" "$ctx" "inflated-note.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
