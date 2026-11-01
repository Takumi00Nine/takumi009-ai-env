#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

run_fragments_log() {
  local vault="$1"; shift
  python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/ai-brain/executor')
import pathlib
import fragments_log as fl
fl.VAULT = pathlib.Path('$vault')
fl.FRAGMENTS = fl.VAULT / 'Fragments'
sys.argv = ['fragments_log.py'] + sys.argv[1:]
fl.main()
" "$@"
}

write_fragment_day() {
  # write_fragment_day <path> <content>
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

d_date() {
  # 今日からn日オフセットした日付をYYYY-MM-DD形式で返す（macOS date -v準拠）。
  local n="$1"
  [[ "$n" != -* ]] && n="+$n"
  date -v"${n}d" +%Y-%m-%d 2>/dev/null || date -d "${n} days" +%Y-%m-%d
}

echo "=== 未処理の候補をJSONで返す ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" \
"## 10:00 未処理タイトル
本文A

## 11:00 処理済みタイトル
status: promoted
本文B"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  title0="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fragments"][0]["heading_or_bullet"])')"
  assert_eq "候補は1件のみ(処理済みは除外)" "1" "$n_frag"
  assert_contains "候補は未処理タイトル" "$title0" "未処理タイトル"

  rm -rf "$VAULT_DIR"
}

echo "=== サイズ上限超過は候補から除外する ==="
{
  VAULT_DIR="$(mktemp -d)"
  BIG_BODY="$(python3 -c 'print("あ" * 2100)')"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" "## 10:00 巨大エントリ
$BIG_BODY"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  n_trunc="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["truncated"]))')"
  trunc_marker="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["truncated"][0]["non_actionable"])')"
  assert_eq "fragmentsには含まれない" "0" "$n_frag"
  assert_eq "truncatedに1件回る" "1" "$n_trunc"
  assert_eq "non_actionable=truncatedが付与される" "truncated" "$trunc_marker"

  rm -rf "$VAULT_DIR"
}

echo "=== Fragments不在でも候補0件で継続する ==="
{
  VAULT_DIR="$(mktemp -d)"
  rc=0
  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -5)" --json)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  assert_eq "候補0件" "0" "$n_frag"

  rm -rf "$VAULT_DIR"
}

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
