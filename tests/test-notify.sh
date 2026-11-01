#!/usr/bin/env bash
# 隔離 HOME と偽の届け先で、通知経路と無応答時の配送継続を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib-ledger-fixtures.sh"

NOTIFY="$REPO_ROOT/notify/executor/notify.sh"
LEDGER_REAL="$REPO_ROOT/core/data/ledger.tsv"
CODE27_FAKE_BIN="$TESTS_DIR/fixtures/code27-call/bin/code27-call-clear"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
STUB="$WORK/stub"
lf_mk_fx6 "$STUB"                      # 偽 launchctl・osascript・cmux（calls.log へ記録）
export HOME="$WORK/home" PATH="$STUB:$PATH"
mkdir -p "$HOME"
NOTIFY_LOG="$HOME/.claude/logs/notify.tsv"

echo "=== 口から呼出が各届け先へ届く ==="
rc=0
ZZ_DEST_LOG="$WORK/unused.log" "$NOTIFY" call ask "テスト題" "テスト本文" >/dev/null 2>&1 || rc=$?
assert_eq "口の呼出が成功" 0 "$rc"
"$NOTIFY" call alert "テスト題" "テスト本文" >/dev/null 2>&1
if grep -q 'cmux notify' "$STUB/calls.log" && grep -q 'osascript' "$STUB/calls.log"; then
  pass "cmux と macOS の両方へ届く"
else fail_case "cmux と macOS の両方へ届く"; fi

echo "=== 応答は CODE27 へ届く ==="
rc=0
CODE27_CALL_BIN="$CODE27_FAKE_BIN" CODE27_CALL_LOG="$WORK/code27.log" "$NOTIFY" answer >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$WORK/code27.log" ]; then pass "応答が CODE27 へ届く"; else fail_case "応答が CODE27 へ届く"; fi

echo "=== 届け先なしは失敗を記録する ==="
awk -F '\t' '!/^#/ && $1=="part" && $3=="notify" && $4=="connect" {next} {print}' "$LEDGER_REAL" > "$WORK/no-dest.tsv"
rc=0
AIENV_LEDGER="$WORK/no-dest.tsv" "$NOTIFY" call ask 題 本文 >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'no-dest' "$NOTIFY_LOG"; then pass "届け先なしは失敗と記録"; else fail_case "届け先なしは失敗と記録"; fi

echo "=== 一方が無応答でも他へ届く ==="
HANG_STUB="$WORK/hang-stub"; mkdir -p "$HANG_STUB"
printf '#!/bin/bash\nsleep 30\n' > "$HANG_STUB/cmux"
chmod +x "$HANG_STUB/cmux"
rm -f "$STUB/calls.log" "$NOTIFY_LOG"
awk -F '\t' -v OFS='\t' '$1=="part" && $5=="macos" {$8="call.ask"} {print}' "$LEDGER_REAL" > "$WORK/two-dest.tsv"
PATH="$HANG_STUB:$PATH" AIENV_LEDGER="$WORK/two-dest.tsv" AIENV_NOTIFY_WAIT_SECS=1 ZZ_DEST_LOG="$WORK/unused.log" "$NOTIFY" call ask 題 本文 >/dev/null 2>&1
if grep -q osascript "$STUB/calls.log"; then pass "cmux 無応答でも macOS へ届く"; else fail_case "cmux 無応答でも macOS へ届く"; fi
if grep -q cmux "$NOTIFY_LOG" && grep -q timeout "$NOTIFY_LOG"; then pass "無応答を記録して戻る"; else fail_case "無応答を記録して戻る"; fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
