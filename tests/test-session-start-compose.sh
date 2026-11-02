#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib-ledger-fixtures.sh"
COMPOSER="$REPO_ROOT/core/connect/claude-code/session-start-compose.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれてはいけないのに含まれる: \"$3\")"; fi; }
WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cmux-stub" "$WORK/home"
printf '#!/bin/bash\nexit 9\n' > "$WORK/cmux-stub/cmux"; chmod +x "$WORK/cmux-stub/cmux"
export PATH="$WORK/cmux-stub:$PATH" HOME="$WORK/home"
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT BOOTSTRAP_CMUX_LIB_DIR AIENV_LEDGER

make_full_vault() {
  local vault="$1" f
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}
VAULT_DIR="$WORK/vault"; make_full_vault "$VAULT_DIR"
SESSION_JSON='{"session_id":"test-session-0000"}'
PROFILE_ENABLE=0
PROFILE_PATH="/nonexistent-dir/profile.md"
hook_env() {
  local obs; obs="$(mktemp -d "$WORK/obs.XXXXXX")/session-observation.json"
  BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="${TEAMS_DIR:-/nonexistent-teams-dir}" \
    VAULT_RECALL_LOG="$HOME/.claude/logs/vault-recall.jsonl" \
    VAULT_INVENTORY_LOG_DIR="${INV_DIR_OVR:-/nonexistent-dir/vault-inventory}" \
    MAINTENANCE_LAST_RUN_FILE="${LAST_RUN_OVR:-/nonexistent-dir/last-run.json}" \
    MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
    HEALTH_OBSERVATION_FILE="${OBS_FILE:-$obs}" HEALTH_JUDGE_NOW="2026-09-15T06:01:01Z" \
    AIENV_MODEL_DEFS_FILE="$WORK/no-models.conf" \
    BOOTSTRAP_ENABLE_LOCAL_PROFILE="$PROFILE_ENABLE" AIENV_LOCAL_PROFILE_PATH="$PROFILE_PATH" "$@"
}
compose() {
  RC=0
  printf '%s\n' "${1:-$SESSION_JSON}" | hook_env bash "$COMPOSER" > "$WORK/c.out" 2>"$WORK/c.err" || RC=$?
  CTX="$(jq -r '.hookSpecificOutput.additionalContext' "$WORK/c.out" 2>/dev/null)"
}
slot() {
  local e; e="$(bash "$REPO_ROOT/$LF_LEDGER_TOOL_REL" lookup "$1" 2>/dev/null | head -1)"
  [ -n "$e" ] || return 0
  printf '%s\n' "$SESSION_JSON" | hook_env bash "$e" --slots 2>/dev/null | jq -r --arg k "$2" '.slots[$k]'
}
render_expected() {
  local o m d5 d6 hold hs pw
  o="$(slot team.session-status opening)"; m="$(slot ai-brain.bootstrap must-read)"
  d5="$(slot team.session-status directive5)"; d6="$(slot dock.declare-state declare6)"
  hold="$(slot team.session-status role-hold)"; hs="$(slot ai-brain.bootstrap health)"
  pw="$(slot team.session-status profile-warning)"
  printf '%s' "【セッション開始ブートストラップ｜ハーネス強制注入】

${o}

${m}
${d5}
${d6}
${hold:+
${hold}}

${hs}${pw:+

${pw}}"
}

echo "=== 充足時の合成文字列とJSON契約 ==="
compose
assert_eq "exit 0" "0" "$RC"
assert_eq "hookEventName＝SessionStart" "SessionStart" "$(jq -r '.hookSpecificOutput.hookEventName' "$WORK/c.out" 2>/dev/null)"
assert_eq "基準の骨格と文字列等値" "$(render_expected)" "$CTX"
echo "=== 台帳異常でも見出しを出し、寄与枠を省く ==="
AIENV_LEDGER="$WORK/no-such-dir/ledger.tsv" compose
assert_eq "台帳異常: exit 0" "0" "$RC"
assert_eq "台帳異常: 見出しは出る" "【セッション開始ブートストラップ｜ハーネス強制注入】" "$(printf '%s\n' "$CTX" | head -1)"
assert_not_contains "台帳異常: AI Brain の枠は無い" "$CTX" "① タスクに着手する前に"
echo "=== ワーカーは無出力で寄与を起動しない ==="
OBS_FILE="$WORK/worker-obs/session-observation.json" compose '{"session_id":"test-session-worker","agent_type":"worker"}'
assert_eq "agent_type 付き: exit 0・stdout 空" "0 " "$RC $(cat "$WORK/c.out")"
assert_true "agent_type 付き: 寄与を起動しない（観測記録が書かれない）" "$([ ! -e "$WORK/worker-obs/session-observation.json" ] && echo 1 || echo 0)"
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
