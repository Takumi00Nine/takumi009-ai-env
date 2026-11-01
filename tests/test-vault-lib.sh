#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/ai-brain/executor"

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

run_py() {
  python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import vault_lib
$1
"
}

echo "=== frontmatterを解析し本文を保持する ==="
{
  out="$(run_py '
text = """---
date: 2026-01-01
tags: [a, b]
aliases:
  - "alias1"
  - "alias2"
---
本文
"""
fm, body = vault_lib.parse_frontmatter(text)
print(fm["date"])
print(",".join(fm["tags"]))
print(",".join(fm["aliases"]))
print(body.strip())
')"
  assert_eq "date(単一行)" "2026-01-01" "$(sed -n '1p' <<< "$out")"
  assert_eq "tags(フロー配列)" "a,b" "$(sed -n '2p' <<< "$out")"
  assert_eq "aliases(複数行リスト)" "alias1,alias2" "$(sed -n '3p' <<< "$out")"
  assert_eq "本文がfrontmatter除去後になる" "本文" "$(sed -n '4p' <<< "$out")"
}

echo "=== atomic書込後に一時ファイルを残さない ==="
{
  D="$(mktemp -d)"
  F="$D/note.md"
  printf 'original' > "$F"
  run_py "
import pathlib
vault_lib.write_note_atomic(pathlib.Path('$F'), 'updated-content')
"
  content="$(cat "$F")"
  n_tmp="$(find "$D" -maxdepth 1 -name '.*.tmp' | wc -l | tr -d ' ')"
  assert_eq "新しい内容が書き込まれる" "updated-content" "$content"
  assert_eq "一時ファイルが残置されない" "0" "$n_tmp"
  rm -rf "$D"
}

echo "=== 汎用語定義がなければfail-closed ==="
{
  out="$(run_py "vault_lib.require_generic_aliases('/nonexistent-generic-$$.txt')" 2>&1)"
  rc=$?
  assert_eq "exit code 1" "1" "$rc"
}

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
