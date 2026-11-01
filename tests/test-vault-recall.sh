#!/usr/bin/env bash

set -uo pipefail   # -e は使わない（jqの非0終了を明示的に見たいケースがあるため）

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/vault-recall.sh"

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

run_recall() {
  local vault="$1" log="$2" prompt="$3" session="${4:-sess-1}"
  local input
  input="$(jq -n --arg p "$prompt" --arg s "$session" '{session_id: $s, prompt: $p}')"
  printf '%s' "$input" | VAULT_RECALL_VAULT="$vault" VAULT_RECALL_LOG="$log" "$SCRIPT"
}

echo "=== ヒットしたノートを注入しログへ記録する ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Knowledge/fail-open-and-observable-guards.md" \
    $'date: 2026-07-10\naliases:\n  - "fail-open"\n  - "無言のfail-open"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "fail-openの設計原則についてざっくり教えて")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "ヒットしたノートが列挙される" "$ctx" "Knowledge/fail-open-and-observable-guards.md"
  assert_contains "ログにヒット行が残る" "$(cat "$LOG")" "sess-1	Knowledge/fail-open-and-observable-guards.md	fail-open"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 必読ノートを想起から除外する ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"
  write_note "$VAULT_DIR/Preferences/absolute-rules.md" \
    $'date: 2026-07-10\naliases:\n  - "excludedkeyword2"'

  out="$(run_recall "$VAULT_DIR" "$LOG" "excludedkeyword2について詳しく聞きたい")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  assert_not_contains "absolute-rules.mdは提示されない" "$ctx" "absolute-rules.md"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 入力破損でもプロンプト処理を止めない ==="
{
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp -d)/vault-recall.tsv"

  out="$(printf 'not valid json at all' | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" "$SCRIPT")"
  rc=$?
  assert_eq "exit code 0（プロンプト処理を妨げない）" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"

  rm -rf "$VAULT_DIR" "$(dirname "$LOG")"
}

echo "=== 候補は最大5件で優先順に表示する ==="
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

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
