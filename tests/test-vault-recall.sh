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
# VAULT_RECALL_DISABLE_VECTOR=1（8.1ラウンド追加のキルスイッチ）を常に付ける:
# 本ファイルはキーワード照合ロジック専用のテストであり、ベクトル想起の挙動は
# tests/test-vault-recall-vector.sh 側で個別に検証する。無効化しないと、リポジトリ内
# 既定の埋め込みインデックス置き場(.cache/vault-embeddings/)にたまたま実Vaultの
# インデックスが存在する状態でテストを走らせた場合に、キーワード除外対象のはずの
# ノート（absolute-rules.md等）がベクトル候補として紛れ込み、テストが環境依存で
# 不安定になる（実際に発生した回帰の再発防止＝Codexレビュー相当の自己発見）。
run_recall() {
  local vault="$1" log="$2" prompt="$3" session="${4:-sess-1}"
  local input
  input="$(jq -n --arg p "$prompt" --arg s "$session" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$vault" VAULT_RECALL_LOG="$log" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT"
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

echo "=== 5b. Personal/フォルダも想起対象になる（2026-07-11決定・4→5フォルダ）・profile-personal.mdは除外される ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Personal/devices.md" \
    $'date: 2026-07-11\naliases:\n  - "モニターの型番台帳"'
  write_note "$VAULT_DIR/Personal/profile-personal.md" \
    $'date: 2026-07-11\naliases:\n  - "個人プロファイル除外対象"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "モニターの型番台帳を教えてください")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  assert_contains "Personal/devices.mdが想起対象として提示される" "$ctx" "Personal/devices.md"

  out2="$(run_recall "$VAULT_DIR" "$LOG" "個人プロファイル除外対象について聞きたいです")"
  ctx2="$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  assert_not_contains "Personal/profile-personal.mdは起動必読のため除外される" "$ctx2" "profile-personal.md"

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

  out="$(printf 'not valid json at all' | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT")"
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

echo "=== 9b. session_idがJSONに無くても候補は無言で消えず通常どおり提示される（8.1ラウンド・リーダー実機発見の回帰修正） ==="
{
  # バグの機序: @tsvの1列目(session_id)が空文字だと出力が先頭タブ始まりになり、
  # bashのreadがIFSに含まれる空白類文字(タブ)の連続を「先頭の空白」として読み飛ばす
  # 仕様により、本来2列目に入るはずのプロンプト全体が誤って1列目へ詰まってしまい
  # PROMPTが空文字になっていた（＝候補があっても無言で無出力になる「無言のfail-open」
  # 違反）。実機のClaude Codeは常にsession_idを送るため実害は無かったが、手動テストを
  # 混乱させるため修正した。session_id側に固定プレフィックスを付けてから読み、直後に
  # 取り除く方式で、1列目が常に非空になり先頭空白読み飛ばしを回避する。
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/sessionless-note.md" \
    $'date: 2026-07-10\naliases:\n  - "excludedsessiontestkeyword"'

  out="$(printf '{"prompt":"excludedsessiontestkeywordについて教えて"}' \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  assert_contains "session_id欠落でも候補が無言で消えず提示される" "$ctx" "sessionless-note.md"

  logtext="$(cat "$LOG" 2>/dev/null || true)"
  # ログ行は "timestamp\tsession_id\trelpath\t..." の形式（log_row()参照）。
  # session_idはtimestampに続く2列目で、欠落時は空文字のまま記録される
  # （Codexレビュー指摘・コメント表現の訂正: 1列目ではなく2列目）。
  assert_contains "提示ログの2列目(session_id)は空文字のまま記録される" "$logtext" $'\t\tKnowledge/sessionless-note.md'

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
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
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" PATH="$BINDIR" "$SCRIPT" 2>&1)
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

echo "=== 15. 読み取れないノートはファイル名キーのみでフォールバックし、log_fact()の事実記録要約行を残す ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/locked-note.md" $'date: 2026-07-10\naliases:\n  - "lockedbodyalias"'
  chmod 000 "$VAULT_DIR/Knowledge/locked-note.md"

  out="$(run_recall "$VAULT_DIR" "$LOG" "lockednoteについて確認したい、十分な長さのプロンプトです")"
  chmod 644 "$VAULT_DIR/Knowledge/locked-note.md"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "本文が読めなくてもファイル名キーで一致する" "$ctx" "Knowledge/locked-note.md"
  assert_contains "読み取り不可の要約行(log_fact())が残る（無言のfail-open防止）" "$(cat "$LOG")" "件のノートを読み取れませんでした"

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
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" PATH="$BINDIR" "$SCRIPT" 2>&1)
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

echo "=== 22. ハートビート: 想起パイプラインを走らせてヒット0件ならログに1行残る（round2からの宿題・8.3ラウンド） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います" "hb-sess-1")"
  rc=$?
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_contains "ハートビート行が1行残る" "$logtext" $'\thb-sess-1\t(heartbeat)'
  col3="$(tail -1 "$LOG" | cut -f3)"
  assert_eq "3列目は固定マーカー(heartbeat)＝vault_inventory.py/check-drift.shの「有効な記録」判定に乗る" \
    "(heartbeat)" "$col3"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 23. ハートビート: 短すぎるプロンプト(10文字未満)の早期exitでは書かれない（既存テスト6の無ログ挙動を変えないスコープ限定） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"

  out="$(run_recall "$VAULT_DIR" "$LOG" "短い" "hb-sess-short")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_eq "ログファイルは作られない（従来どおり）" "0" "$([ -e "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 24. ハートビート: 同一session_idの連続呼び出しは1行に抑制される（ログ肥大対策） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います その1" "hb-throttle" >/dev/null
  run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います その2" "hb-throttle" >/dev/null
  run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います その3" "hb-throttle" >/dev/null
  n_heartbeats="$(grep -c $'\thb-throttle\t(heartbeat)' "$LOG" 2>/dev/null || true)"
  assert_eq "同一session_idの連投は直前行が既にハートビートなら書き込みを省略し1行のまま" "1" "$n_heartbeats"

  run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います その4" "hb-throttle-2" >/dev/null
  n_sessions="$(cut -f2 "$LOG" | sort -u | grep -c 'hb-throttle')"
  assert_eq "session_idが変われば別行として記録される" "2" "$n_sessions"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 25. ハートビート: ヒットがある呼び出しでは余分なハートビート行は書かれない ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/fail-open-and-observable-guards.md" \
    $'date: 2026-07-10\naliases:\n  - "fail-open"'

  run_recall "$VAULT_DIR" "$LOG" "fail-openの設計原則についてざっくり教えて" "hb-hit-sess" >/dev/null
  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  n_heartbeats="$(grep -c '(heartbeat)' "$LOG" 2>/dev/null || true)"
  assert_eq "ログは候補ヒット行1行のみ" "1" "$n_lines"
  assert_eq "ハートビート行は無い" "0" "$n_heartbeats"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 26. ハートビート: keyword helperがfail-openした呼び出しでは書かれない（結果的に0件でもERROR経路優先・Codex一次レビュー指摘・Major対応） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'
  BROKEN_HELPER="$(mktemp -d)/broken-keyword-helper.py"
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$BROKEN_HELPER"

  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います" --arg s "hb-error-sess" '{session_id: $s, prompt: $p}')"
  out="$(printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" \
    VAULT_RECALL_DISABLE_VECTOR="1" VAULT_RECALL_KEYWORD_HELPER="$BROKEN_HELPER" "$SCRIPT")"
  rc=$?
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_contains "keyword helperの異常終了がERROR行として残る" "$logtext" "helperが異常終了しました"
  assert_not_contains "ERROR経路が発生した呼び出しではハートビートを書かない" "$logtext" "(heartbeat)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")" "$(dirname "$BROKEN_HELPER")"
}

echo "=== 27. ハートビート: 直前ハートビートが再書込み間隔(既定1日・VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S)を超えて古ければ同一セッションでも書き直す（7日超連続セッションでのcheck-drift.sh STALE偽検知防止・外部脳総点検2026-07-14） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  # check-drift.shのVAULT_AGENT_LOG_STALE_DAYS(既定7日)を超えるシナリオを模して、
  # 8日前のタイムスタンプで同一session_idのハートビート行を直前1行として仕込む。
  old_ts="$(date -u -v-8d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\thb-old-sess\t(heartbeat)\n' "$old_ts" > "$LOG"

  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その5" --arg s "hb-old-sess" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT" >/dev/null
  rc=$?

  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  new_ts_date="$(tail -1 "$LOG" | cut -f1 | cut -c1-10)"
  old_ts_date="$(printf '%s' "$old_ts" | cut -c1-10)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "8日前のハートビートは抑制されず新しい行が追記される（旧実装なら1のまま凍結）" "2" "$n_lines"
  assert_not_contains "追記された最終行は8日前の日付のまま固定されない" "$new_ts_date" "$old_ts_date"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 28. ハートビート: 再書込み間隔内(既定1日)なら従来どおり同一セッションで抑制される（回帰確認・item27との対比） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  recent_ts="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\thb-recent-sess\t(heartbeat)\n' "$recent_ts" > "$LOG"

  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その6" --arg s "hb-recent-sess" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT" >/dev/null

  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  assert_eq "1時間前(既定閾値1日未満)のハートビートは引き続き抑制される" "1" "$n_lines"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 29. ハートビート: 直前行のタイムスタンプが解析できなくてもfail-open（抑制せず新規に書く） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  printf 'not-a-valid-timestamp\thb-broken-ts-sess\t(heartbeat)\n' > "$LOG"

  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その7" --arg s "hb-broken-ts-sess" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT" >/dev/null
  rc=$?

  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "壊れたタイムスタンプは解析失敗としてfail-open（抑制せず新規ハートビートを書く）" "2" "$n_lines"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 29b. ハートビート: BSD date -jが寛容にパース成功してしまう「一見それらしいが厳密形式ではない」タイムスタンプも、固定桁caseパターンにより解析失敗として扱われる（Codex一次レビュー指摘・Minor対応: 29番はnot-a-valid-timestampのみで、date -j自体が受理してしまう桁不足・末尾余剰文字・Z欠落のガード自体は未検証だった） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  # いずれもBSD `date -j -f "%Y-%m-%dT%H:%M:%S"` は成功してしまう（実機確認済み）が、
  # log_row()が実際に書く厳密形式"YYYY-MM-DDTHH:MM:SSZ"ではないため、固定桁case
  # パターンにより弾かれ、抑制せず新規ハートビートが書かれるはず。
  for bad_ts in '2026-7-5T1:2:3Z' '2026-07-15T12:34:56junk' '2026-07-15T12:34:56'; do
    LOG="$(mktemp -d)/vault-recall.tsv"
    printf '%s\thb-lenient-ts-sess\t(heartbeat)\n' "$bad_ts" > "$LOG"
    input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その7b" --arg s "hb-lenient-ts-sess" '{session_id: $s, prompt: $p}')"
    printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT" >/dev/null
    rc=$?
    n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
    assert_eq "「${bad_ts}」でもexit code 0" "0" "$rc"
    assert_eq "「${bad_ts}」は厳密形式ではないため解析失敗扱いとなり新規ハートビートが書かれる" "2" "$n_lines"
    rm -rf "$(dirname "$LOG")"
  done

  rm -rf "$VAULT_DIR"
}

echo "=== 30. ハートビート: VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_Sが不正値でも既定値(86400)へフォールバックしexit 0を維持する ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  for bad in "abc" "-100" "12.5" ""; do
    input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その8" --arg s "hb-badenv-${bad:-empty}" '{session_id: $s, prompt: $p}')"
    printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" \
      VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S="$bad" "$SCRIPT" >/dev/null
    rc=$?
    assert_eq "VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S=${bad:-<空文字>} でもexit code 0（既定値へフォールバック）" "0" "$rc"
  done

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 31. ログ形式分離: 読取不可ノート件数の事実記録(log_fact())は6列目に固定文字列INFOが付き、真の失敗(log_error())と区別できる（外部脳総点検2026-07-14） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/locked-note.md" $'date: 2026-07-10\naliases:\n  - "lockedbodyalias"'
  chmod 000 "$VAULT_DIR/Knowledge/locked-note.md"

  out="$(run_recall "$VAULT_DIR" "$LOG" "lockednoteについて確認したい、十分な長さのプロンプトです")"
  chmod 644 "$VAULT_DIR/Knowledge/locked-note.md"

  fact_line="$(grep '件のノートを読み取れませんでした' "$LOG")"
  fact_col2="$(printf '%s' "$fact_line" | cut -f2)"
  fact_col6="$(printf '%s' "$fact_line" | cut -f6)"
  assert_eq "2列目は下流互換のため引き続き固定文字列ERROR" "ERROR" "$fact_col2"
  assert_eq "6列目に事実記録を示すINFOが付与される" "INFO" "$fact_col6"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 32. ハートビート: log_fact()由来の事実記録（読取不可ノート件数）だけならPIPELINE_HAD_ERRORを立てず、候補0件でもハートビートが書かれる（Codex一次レビュー指摘・Major対応: 真の失敗ではないためハートビート抑止の対象にしない） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/locked-note2.md" $'date: 2026-07-10\naliases:\n  - "lockedbodyalias2"'
  chmod 000 "$VAULT_DIR/Knowledge/locked-note2.md"

  out="$(run_recall "$VAULT_DIR" "$LOG" "全く関係ない話題について質問したいと思います その9")"
  rc=$?
  chmod 644 "$VAULT_DIR/Knowledge/locked-note2.md"
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_contains "読取不可の事実記録(log_fact())は残る" "$logtext" "件のノートを読み取れませんでした"
  assert_contains "log_fact()だけならハートビートは抑止されず書かれる（旧実装ならPIPELINE_HAD_ERRORで抑止されていた）" \
    "$logtext" "(heartbeat)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 33. ハートビート: 直前行のタイムスタンプが未来（システム時計ズレ等）でも「新しい」と誤判定せず書き直す（Codex一次レビュー指摘・Major対応: 負の経過秒数を無条件で「新しい」扱いすると壊れた未来日時が永久にハートビートを抑止してしまう） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  future_ts="$(date -u -v+1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 day' +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\thb-future-sess\t(heartbeat)\n' "$future_ts" > "$LOG"

  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その10" --arg s "hb-future-sess" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" "$SCRIPT" >/dev/null
  rc=$?

  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "未来日時のハートビートは「新しい」と誤判定されず新規行が追記される（旧実装なら負の経過秒数が閾値未満と誤判定され凍結し続けた）" \
    "2" "$n_lines"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 34. ハートビート: VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_Sで指定したカスタム閾値が実際に尊重される（Codex一次レビュー指摘・Minor対応: 既定値86400へ無視して固定されていないことの境界値確認） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  ts_30s_ago="$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"

  # 30秒前のハートビートに対し閾値=3600秒（1時間）なら、まだ新しいので抑制される。
  printf '%s\thb-custom-sess\t(heartbeat)\n' "$ts_30s_ago" > "$LOG"
  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その11" --arg s "hb-custom-sess" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" \
    VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S=3600 "$SCRIPT" >/dev/null
  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  assert_eq "30秒前は閾値3600秒未満のため抑制される" "1" "$n_lines"

  # 同じ経過時間(30秒前)でも閾値=10秒なら書き直されるはず＝カスタム値が実際に使われて
  # いることの確認（既定値86400のままなら誤ってこのケースも1のまま通ってしまう）。
  printf '%s\thb-custom-sess2\t(heartbeat)\n' "$ts_30s_ago" > "$LOG"
  input2="$(jq -n --arg p "全く関係ない話題について質問したいと思います その12" --arg s "hb-custom-sess2" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input2" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_DISABLE_VECTOR="1" \
    VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S=10 "$SCRIPT" >/dev/null
  n_lines2="$(grep -c . "$LOG" 2>/dev/null || true)"
  assert_eq "同じ30秒経過でも閾値10秒なら書き直される（既定値へ無視して固定されていない確認）" "2" "$n_lines2"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 35. ログ形式のサニタイズ: helperのstderrに混入したタブ・改行はスペースへ正規化され、TSV列を偽装できない（Codex一次レビュー指摘・Major対応: 真の失敗メッセージの末尾がたまたま\"\\tINFO\"に見えると誤って無害判定されうる隙間の是正） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'
  BROKEN_HELPER="$(mktemp -d)/broken-keyword-helper-tab.py"
  # head -c 200(bash側)→コマンド置換は末尾の改行を取り除くため、末尾に改行を置くだけ
  # では改行サニタイズそのものは実質検証できない（Codex一次レビュー指摘・Minor対応:
  # 改行をメッセージの「途中」に置き、末尾の改行除去に巻き込まれない位置で検証する）。
  cat > "$BROKEN_HELPER" <<'PYEOF'
import sys
sys.stderr.write("boom\nsecond-line\tINFO\n")
sys.exit(1)
PYEOF

  input="$(jq -n --arg p "全く関係ない話題について質問したいと思います その13" --arg s "sanitize-sess" '{session_id: $s, prompt: $p}')"
  out="$(printf '%s' "$input" | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" \
    VAULT_RECALL_DISABLE_VECTOR="1" VAULT_RECALL_KEYWORD_HELPER="$BROKEN_HELPER" "$SCRIPT")"
  rc=$?

  n_lines="$(grep -c . "$LOG" 2>/dev/null || true)"
  err_line="$(grep 'helperが異常終了しました' "$LOG")"
  col2="$(printf '%s' "$err_line" | cut -f2)"
  col6="$(printf '%s' "$err_line" | cut -f6)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_eq "stderr中間の改行が混入していてもログ行は1行のまま分裂しない" "1" "$n_lines"
  assert_eq "2列目は真の失敗を示すERRORのまま" "ERROR" "$col2"
  assert_eq "サニタイズにより6列目に偽のINFOマーカーは生成されない（5列のまま＝真の失敗として判別可能）" "" "$col6"
  assert_contains "改行はスペースへ正規化されメッセージ本文として残る（黙って消えない＝可観測性維持）" \
    "$err_line" "boom second-line INFO"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")" "$(dirname "$BROKEN_HELPER")"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
