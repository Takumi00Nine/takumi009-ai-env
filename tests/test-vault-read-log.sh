#!/usr/bin/env bash
# claude/hooks/vault-read-log.sh のユニットテスト（PostToolUse Read・利用ログ）。
#
# 実 Vault($HOME/Data/obsidian)・実ログには一切依存しない。VAULT_READS_VAULT・
# VAULT_READS_LOG 環境変数で毎回ダミーのfixtureへ差し替えて実行する
# （環境変数名は scripts/vault-agents/vault_inventory.py と揃えている＝
# 同じ vault-reads.tsv を読む側の実装に合わせる）。
#
# 実行方法: bash tests/test-vault-read-log.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/claude/hooks/vault-read-log.sh"

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

run_read_log() {
  # run_read_log <vault> <log> <file_path> [session_id]
  local vault="$1" log="$2" fpath="$3" session="${4:-sess-1}"
  local input
  input="$(jq -n --arg f "$fpath" --arg s "$session" \
    '{session_id: $s, tool_name: "Read", tool_input: {file_path: $f}}')"
  printf '%s' "$input" | VAULT_READS_VAULT="$vault" VAULT_READS_LOG="$log" "$SCRIPT"
}

echo "=== 1. Vault配下のReadはTSVに1行追記される ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"
  mkdir -p "$VAULT_DIR/Knowledge"
  : > "$VAULT_DIR/Knowledge/mistakes.md"

  run_read_log "$VAULT_DIR" "$LOG" "$VAULT_DIR/Knowledge/mistakes.md" "sess-abc"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  logtext="$(cat "$LOG")"
  assert_contains "session_idが記録される" "$logtext" $'\tsess-abc\t'
  assert_contains "相対パスが記録される" "$logtext" $'\tKnowledge/mistakes.md'
  n_cols="$(printf '%s' "$logtext" | awk -F'\t' '{print NF}')"
  assert_eq "3列（ts, session_id, relpath）" "3" "$n_cols"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 2. Vault配下でないReadは対象外（exit 0・ログ未作成） ==="
{
  VAULT_DIR="$(mktemp -d)"
  OTHER_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"

  run_read_log "$VAULT_DIR" "$LOG" "$OTHER_DIR/somefile.md"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "ログファイルは作られない" "0" "$([ -e "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$OTHER_DIR" "$(dirname "$LOG")"
}

echo "=== 3. file_pathが無い/空のReadは対象外（exit 0） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"

  out="$(printf '{"session_id":"s1","tool_name":"Read","tool_input":{}}' \
    | VAULT_READS_VAULT="$VAULT_DIR" VAULT_READS_LOG="$LOG" "$SCRIPT")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_eq "ログファイルは作られない" "0" "$([ -e "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 4. fail-open: 壊れたJSON入力でもexit 0・ERROR行（3列目は空で無害化） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"

  out="$(printf 'not json at all' | VAULT_READS_VAULT="$VAULT_DIR" VAULT_READS_LOG="$LOG" "$SCRIPT")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_contains "ERROR行が残る" "$logtext" $'\tERROR\t'
  col3="$(printf '%s' "$logtext" | cut -f3)"
  assert_eq "3列目(ノートパス位置)は空文字" "" "$col3"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 4b. Vault配下を装った \"..\" traversalは対象外にする（Codexレビュー指摘・Major回帰） ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"
  OUTSIDE="$(mktemp -d)/outside.md"
  : > "$OUTSIDE"

  # 文字列prefixとしては "$VAULT_DIR/" で始まるが、実体はVault外を指すパス。
  run_read_log "$VAULT_DIR" "$LOG" "$VAULT_DIR/../$(basename "$(dirname "$OUTSIDE")")/outside.md"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "traversalパスはログに残さない" "0" "$([ -e "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")" "$(dirname "$OUTSIDE")"
}

echo "=== 5. 複数回Readすると追記され続ける ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-reads.tsv"
  mkdir -p "$VAULT_DIR/Knowledge" "$VAULT_DIR/Preferences"
  : > "$VAULT_DIR/Knowledge/a.md"
  : > "$VAULT_DIR/Preferences/b.md"

  run_read_log "$VAULT_DIR" "$LOG" "$VAULT_DIR/Knowledge/a.md"
  run_read_log "$VAULT_DIR" "$LOG" "$VAULT_DIR/Preferences/b.md"

  n_lines="$(wc -l < "$LOG" | tr -d ' ')"
  assert_eq "2行追記される" "2" "$n_lines"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 6. ログディレクトリが存在しなくても自動作成される ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Knowledge"
  : > "$VAULT_DIR/Knowledge/a.md"
  LOG_PARENT="$(mktemp -d)/nested/dir"
  LOG="$LOG_PARENT/vault-reads.tsv"

  run_read_log "$VAULT_DIR" "$LOG" "$VAULT_DIR/Knowledge/a.md"
  assert_eq "ログファイルが作成される" "1" "$([ -f "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$(dirname "$(dirname "$LOG_PARENT")")"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
