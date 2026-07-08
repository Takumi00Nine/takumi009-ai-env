#!/usr/bin/env bash
# claude/hooks/bootstrap-vault.sh のユニットテスト（メイン/サブ両方の回帰テスト）。
#
# 実 Vault($HOME/Data/obsidian) には依存しない。BOOTSTRAP_VAULT 環境変数で
# 毎回ダミーのfixtureディレクトリへ差し替えてスクリプトを実行し、
# 「存在するファイルだけが必読リストに載る」ことを検証する
# （2026-07-08 設計判断: install-sub.sh 対応でメイン/サブ両方の回帰を担保）。
#
# 実行方法: bash tests/test-bootstrap-vault.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
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

# 全6ファイルをVAULT配下に作る（メイン相当のfixture）。
make_full_vault() {
  local vault="$1"
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Knowledge/mistakes.md" "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Personal/profile-personal.md" "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

# bootstrap-vault.sh を実行し、additionalContext文字列を返す（単独セッション相当＝
# agent_type無し・チーム未所属。session_idは適当な固定値）。
run_bootstrap() {
  local vault="$1"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

echo "=== 1. メイン相当: 6ファイル全部存在 → 6ファイル全部が必読リストに載る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "6ファイルを読む、の文言" "$ctx" "（6ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Knowledge/mistakes.md が列挙される" "$ctx" "Knowledge/mistakes.md"
  assert_contains "Personal/profile-personal.md が列挙される" "$ctx" "Personal/profile-personal.md"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"
  assert_not_contains "private ノート対象外の注記は出ない（メインでは全部揃うため）" "$ctx" "private ノートはこのマシンには無い"

  rm -rf "$VAULT_DIR"
}

echo "=== 2. サブ相当: private系2ファイル欠如 → 4ファイルのみ列挙+対象外の注記 ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences"
  for f in "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Knowledge/mistakes.md と Personal/profile-personal.md は無い（サブ想定）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "4ファイルを読む、の文言" "$ctx" "（4ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Preferences/absolute-rules.md は列挙される" "$ctx" "Preferences/absolute-rules.md"
  assert_not_contains "Knowledge/mistakes.md は列挙されない（存在しないため）" "$ctx" "Knowledge/mistakes.md"
  assert_not_contains "Personal/profile-personal.md は列挙されない（存在しないため）" "$ctx" "Personal/profile-personal.md"
  assert_contains "private ノート対象外の注記が出る（2件）" "$ctx" "private ノートはこのマシンには無い（サブ）: 2件は対象外"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"

  rm -rf "$VAULT_DIR"
}

echo "=== 3. Vault丸ごと空（0ファイル） → 0ファイルでも壊れずに動く ==="
{
  VAULT_DIR="$(mktemp -d)"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "0ファイルを読む、の文言" "$ctx" "（0ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "6件対象外の注記が出る" "$ctx" "private ノートはこのマシンには無い（サブ）: 6件は対象外"

  rm -rf "$VAULT_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
