#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/keyword_recall_helper.py"

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

write_note() {
  # write_note <path> <frontmatter本文(改行区切り)> [本文]
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  { echo "---"; printf '%s\n' "$fm"; echo "---"; echo; printf '%s\n' "$body"; } > "$path"
}

run_helper() {
  local vault="$1" query="$2"
  shift 2
  python3 "$SCRIPT" --query "$query" --vault "$vault" "$@"
}

relpaths_of() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print([c['relpath'] for c in d['candidates']])"
}

echo "=== キーワードのヒットを返す ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/fail-open-and-observable-guards.md" \
    $'date: 2026-07-10\naliases:\n  - "fail-open"\n  - "無言のfail-open"'

  out="$(run_helper "$VAULT_DIR" "fail-openの設計原則についてざっくり教えて")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  relpaths="$(printf '%s' "$out" | relpaths_of)"
  assert_contains "ヒットしたノートが列挙される" "$relpaths" "fail-open-and-observable-guards.md"

  rm -rf "$VAULT_DIR"
}

echo "=== 必読ノートを候補から除外する ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/absolute-rules.md" $'date: 2026-07-10\naliases: [excludedkeyword]'
  out="$(run_helper "$VAULT_DIR" "excludedkeywordについて詳しく教えてください")"
  assert_eq "必読ノートは想起候補から除外される" "[]" "$(printf '%s' "$out" | relpaths_of)"

  rm -rf "$VAULT_DIR"
}

echo "=== トークンの部分一致を返す ==="
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

echo "=== 読めないノートはファイル名で照合する ==="
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

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
