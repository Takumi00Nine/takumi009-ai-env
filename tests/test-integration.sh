#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_DIR="$TESTS_DIR"
TARGET="$REPO_ROOT/dock/executor/cmux-next-model.sh"
unset VAULT_AGENT_LOG_STALE_DAYS

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/aienv-integration-test.XXXXXX")" || { echo "FATAL: mktemp -d に失敗しました" >&2; exit 1; }
trap 'chmod -R u+rwx "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/cmux-stub"
printf '#!/bin/bash\nexit 9\n' > "$WORKDIR/cmux-stub/cmux"; chmod +x "$WORKDIR/cmux-stub/cmux"
export PATH="$WORKDIR/cmux-stub:$PATH" HOME="$WORKDIR/home"
mkdir -p "$HOME"
python3 "$TESTS_DIR/recall_fixtures.py" "$REPO_ROOT" "$HOME" || exit 1

VAULT="$WORKDIR/vault"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }

FX_ROOT="$SCRIPT_DIR/fixtures/health"
run_frame_fixture() {
  local d="$FX_ROOT/$1" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
    CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="$plist" \
    HEALTH_JUDGE_NOW="$(cat "$d/now")" \
    bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>"$WORKDIR/frame_stderr"
}
b_rows() { awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout"; }
echo "=== 正常時のB行 ==="
mkdir -p "$VAULT/Projects"
run_frame_fixture S-1
assert_eq "frame_b_row_ok: 旧キーがあっても候補を出さない" "B	外部脳	ok	OK" "$(b_rows)"
echo "=== WARNINGとERRORのB行 ==="
run_frame_fixture S-2
assert_eq "S-2: B 行 warn／WARNING" "B	外部脳	warn	WARNING" "$(b_rows)"
run_frame_fixture S-15
assert_eq "S-15: B 行 error／ERROR" "B	外部脳	error	ERROR" "$(b_rows)"
echo "=== 入力破損でもB行を出す ==="
d="$FX_ROOT/X-3"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" HEALTH_JUDGE_NOW="$(cat "$d/now")" \
  bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "X-3（解析不能）: B 行 warn／WARNING" "B	外部脳	warn	WARNING" "$(b_rows)"
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
