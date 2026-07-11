#!/usr/bin/env bash
# scripts/vault-agents/apply_aliases.py のユニットテスト。
#
# 実 Vault($HOME/Data/obsidian)には一切依存しない。--vault で毎回ダミーの
# fixtureディレクトリを指定して実行する。generic-aliases.txt はリポジトリ本体の
# ものをそのまま使う（別ワーカー担当・"Claude"などの語を含む前提でテストする）。
#
# 実行方法: bash tests/test-apply-aliases.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/apply_aliases.py"

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
  # write_note <path> <frontmatter本文> [本文]
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

echo "=== 1. dry-run既定: 差分表示のみでファイルは変更されない ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/no-alias.md" "date: 2026-07-01
tags: [knowledge]"
  TSV="$(mktemp)"
  printf 'Knowledge/no-alias.md\tnewterm1|newterm2\n' > "$TSV"
  before="$(cat "$V/Knowledge/no-alias.md")"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V")"
  rc=$?
  after="$(cat "$V/Knowledge/no-alias.md")"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "dry-runではファイルが変更されない" "$before" "$after"
  assert_contains "DRY-RUNの表示が出る" "$out" "DRY-RUN Knowledge/no-alias.md"
  assert_contains "差分(diff)が表示される" "$out" "+  - \"newterm1\""
  assert_contains "反映するには--applyの案内" "$out" "--apply"

  rm -rf "$V" "$TSV"
}

echo "=== 2. --apply: aliases:が無いノートに新規追加される（他フィールド・本文は不変） ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/no-alias.md" "date: 2026-07-01
tags: [knowledge, sample]" "本文はそのまま"
  TSV="$(mktemp)"
  printf 'Knowledge/no-alias.md\tnewterm1|newterm2\n' > "$TSV"

  python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
  content="$(cat "$V/Knowledge/no-alias.md")"
  assert_contains "aliases:ブロックが追加される" "$content" 'aliases:'
  assert_contains "alias1が追加される" "$content" '"newterm1"'
  assert_contains "alias2が追加される" "$content" '"newterm2"'
  assert_contains "updated:が当日に設定される" "$content" "updated: $(date -u +%Y-%m-%d)"
  assert_contains "既存のtags:は変更されない" "$content" "tags: [knowledge, sample]"
  assert_contains "本文は変更されない" "$content" "本文はそのまま"

  rm -rf "$V" "$TSV"
}

echo "=== 3. --apply: 既存aliases(ブロックリスト)と和集合になる・重複は追加しない ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/has-alias.md" 'date: 2026-07-01
updated: 2026-07-02
aliases:
  - "existing-term"'
  TSV="$(mktemp)"
  printf 'Knowledge/has-alias.md\texisting-term|added-term\n' > "$TSV"

  python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
  content="$(cat "$V/Knowledge/has-alias.md")"
  n_existing="$(printf '%s' "$content" | grep -c '"existing-term"')"
  assert_eq "既存aliasは重複追加されない(1回のみ)" "1" "$n_existing"
  assert_contains "新規aliasは追加される" "$content" '"added-term"'

  rm -rf "$V" "$TSV"
}

echo "=== 4. --apply: 既存aliases(インライン配列形式)もブロックリストへ正規化しつつ和集合になる ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/has-flow-alias.md" 'date: 2026-07-01
aliases: [flow-term, "flow term 2"]'
  TSV="$(mktemp)"
  printf 'Knowledge/has-flow-alias.md\tflow-term|flow-term-3\n' > "$TSV"

  python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
  content="$(cat "$V/Knowledge/has-flow-alias.md")"
  assert_contains "既存alias(flow-term)は保持される" "$content" '"flow-term"'
  assert_contains "既存alias(flow term 2)は保持される" "$content" '"flow term 2"'
  assert_contains "新規alias(flow-term-3)が追加される" "$content" '"flow-term-3"'
  assert_not_contains "インライン形式は残らない(ブロックリストに正規化される)" "$content" "aliases: [flow-term"

  rm -rf "$V" "$TSV"
}

echo "=== 5. generic-aliases.txt該当語は警告してskipする（該当以外は適用される） ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/generic-test.md" "date: 2026-07-01"
  TSV="$(mktemp)"
  # generic-aliases.txt収録語(Claude)+具体的な語
  printf 'Knowledge/generic-test.md\tClaude|specific-unique-term\n' > "$TSV"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply)"
  content="$(cat "$V/Knowledge/generic-test.md")"
  assert_contains "WARNメッセージが出る" "$out" 'WARN Knowledge/generic-test.md: alias "Claude"'
  assert_not_contains "汎用語(Claude)は追加されない" "$content" '"Claude"'
  assert_contains "具体的な語は追加される" "$content" '"specific-unique-term"'

  rm -rf "$V" "$TSV"
}

echo "=== 6. 追加すべき新規aliasが無い場合はskip・ファイル不変（updated:も更新しない） ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/already-has.md" 'date: 2026-07-01
updated: 2026-01-01
aliases:
  - "term-a"'
  TSV="$(mktemp)"
  printf 'Knowledge/already-has.md\tterm-a\n' > "$TSV"
  before="$(cat "$V/Knowledge/already-has.md")"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply)"
  after="$(cat "$V/Knowledge/already-has.md")"
  assert_eq "ファイルは一切変更されない(updated:も不変)" "$before" "$after"
  assert_contains "SKIPメッセージが出る" "$out" "SKIP Knowledge/already-has.md"

  rm -rf "$V" "$TSV"
}

echo "=== 7. 存在しないノートはSKIPして他の行の処理は続行する ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/exists.md" "date: 2026-07-01"
  TSV="$(mktemp)"
  printf 'Knowledge/missing.md\tsome-alias\nKnowledge/exists.md\tvalid-term\n' > "$TSV"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply)"
  content="$(cat "$V/Knowledge/exists.md")"
  assert_contains "存在しないノートはSKIP表示" "$out" "SKIP Knowledge/missing.md: ノートが見つかりません"
  assert_contains "続く行は正常に適用される" "$content" '"valid-term"'

  rm -rf "$V" "$TSV"
}

echo "=== 8. frontmatterが無いノートはERRORとして報告され、書き換えない ==="
{
  V="$(mktemp -d)"
  mkdir -p "$V/Knowledge"
  printf '# no frontmatter here\n' > "$V/Knowledge/no-fm.md"
  TSV="$(mktemp)"
  printf 'Knowledge/no-fm.md\tsome-alias\n' > "$TSV"
  before="$(cat "$V/Knowledge/no-fm.md")"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply)"
  after="$(cat "$V/Knowledge/no-fm.md")"
  assert_eq "ファイルは変更されない" "$before" "$after"
  assert_contains "ERROR表示が出る" "$out" "ERROR Knowledge/no-fm.md: frontmatterが見つかりません"

  rm -rf "$V" "$TSV"
}

echo "=== 9. 拡張子省略・コメント行/空行/不正行のTSVを許容する ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/ext-omitted.md" "date: 2026-07-01"
  TSV="$(mktemp)"
  {
    echo "# これはコメント行"
    echo ""
    echo "Knowledge/ext-omitted	newalias"
    echo "brokenlinewithoutalias"
  } > "$TSV"

  err="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply 2>&1 >/dev/null)"
  content="$(cat "$V/Knowledge/ext-omitted.md")"
  assert_contains "拡張子を省略しても.mdが補われて適用される" "$content" '"newalias"'
  assert_contains "壊れた行はWARN(stderr)してskipされる" "$err" "WARN:"

  rm -rf "$V" "$TSV"
}

echo "=== 9b. TSVの \"..\" traversalはVault外へ書き込まずERRORにする（Codexレビュー指摘・Major回帰） ==="
{
  V="$(mktemp -d)"
  mkdir -p "$V/Knowledge"
  OUTSIDE_PARENT="$(mktemp -d)"
  echo "outside content" > "$OUTSIDE_PARENT/outside.md"
  write_note "$V/Knowledge/legit.md" "date: 2026-07-01"
  TSV="$(mktemp)"
  {
    printf 'Knowledge/../../%s/outside.md\tbadalias\n' "$(basename "$OUTSIDE_PARENT")"
    printf 'Knowledge/legit.md\tgoodalias\n'
  } > "$TSV"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply)"
  assert_contains "traversalパスはERRORとして報告される" "$out" "Vaultの外を指しているためskipします"
  assert_not_contains "Vault外のファイルは書き換えられない" "$(cat "$OUTSIDE_PARENT/outside.md")" "badalias"
  assert_contains "他の正常な行は引き続き適用される" "$(cat "$V/Knowledge/legit.md")" '"goodalias"'

  rm -rf "$V" "$TSV" "$OUTSIDE_PARENT"
}

echo "=== 9c. 既存alias(インライン配列)にクォート内カンマが含まれても壊さず保持する（Codexレビュー指摘・Major回帰） ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/tricky.md" 'date: 2026-07-01
aliases: ["foo, bar", simple]'
  TSV="$(mktemp)"
  printf 'Knowledge/tricky.md\tnewterm\n' > "$TSV"

  python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
  content="$(cat "$V/Knowledge/tricky.md")"
  assert_contains "クォート内カンマを含む既存aliasが分割されずに保持される" "$content" '"foo, bar"'
  assert_contains "他の既存aliasも保持される" "$content" '"simple"'
  assert_contains "新規aliasも追加される" "$content" '"newterm"'

  rm -rf "$V" "$TSV"
}

echo "=== 10. TSVが空/コメントのみなら「対象がありません」で正常終了する ==="
{
  V="$(mktemp -d)"
  TSV="$(mktemp)"
  printf '# コメントのみ\n\n' > "$TSV"

  out="$(python3 "$SCRIPT" "$TSV" --vault "$V")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "対象なしメッセージが出る" "$out" "適用対象がありません"

  rm -rf "$V" "$TSV"
}

echo "=== 11. 冪等性: 同じTSVを2回applyしても2回目は変更なし(SKIP) ==="
{
  V="$(mktemp -d)"
  write_note "$V/Knowledge/idempotent.md" "date: 2026-07-01"
  TSV="$(mktemp)"
  printf 'Knowledge/idempotent.md\ttermA|termB\n' > "$TSV"

  python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
  after_first="$(cat "$V/Knowledge/idempotent.md")"
  out2="$(python3 "$SCRIPT" "$TSV" --vault "$V" --apply)"
  after_second="$(cat "$V/Knowledge/idempotent.md")"

  assert_eq "2回目は内容不変" "$after_first" "$after_second"
  assert_contains "2回目はSKIP表示" "$out2" "SKIP Knowledge/idempotent.md: 追加すべき新規aliasがありません"

  rm -rf "$V" "$TSV"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
