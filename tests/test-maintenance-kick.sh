#!/usr/bin/env bash
# 隔離 HOME と偽 launchctl/runner で、起動拒否と手動起動を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/maintenance-kick.sh"

HOME="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗" >&2; exit 1; }
[[ -n "$HOME" && "$HOME" != "/" && -d "$HOME" ]] || { echo "FATAL: HOME 隔離に失敗" >&2; exit 1; }
export HOME
WORK_ROOT="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗" >&2; exit 1; }
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

setup_fake_launchctl() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/launchctl" <<'FAKEEOF'
#!/usr/bin/env bash
sub="${1:-}"
if [[ "$sub" == "kickstart" ]]; then
  marker=no
  [[ -n "${FAKE_MARKER_PATH:-}" && -f "$FAKE_MARKER_PATH" ]] && marker=yes
  echo "$* marker=$marker" >> "${FAKE_LAUNCHCTL_LOG:-/dev/null}"
  rc="${FAKE_LAUNCHCTL_KICKSTART_RC:-0}"
  if [[ "$rc" == "0" && -n "${FAKE_RUNNER_SCRIPT:-}" ]]; then
    bash "$FAKE_RUNNER_SCRIPT" >/dev/null 2>&1 &
  fi
  exit "$rc"
fi
echo "$*" >> "${FAKE_LAUNCHCTL_LOG:-/dev/null}"
if [[ "$sub" == "print" ]]; then exit "${FAKE_LAUNCHCTL_PRINT_RC:-0}"; fi
exit 0
FAKEEOF
  chmod +x "$bindir/launchctl"
}

setup_fake_runner() {
  local path="$1"
  cat > "$path" <<'FAKEEOF'
#!/usr/bin/env bash
sleep "${FAKE_RUNNER_DELAY_START:-0.2}"
trigger=scheduled
if [[ -n "${FAKE_RUNNER_MARKER:-}" && -f "$FAKE_RUNNER_MARKER" ]]; then trigger=manual; rm -f "$FAKE_RUNNER_MARKER"; fi
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$FAKE_RUNNER_STATE_FILE")"
jq -n --arg rid "$FAKE_RUNNER_RUN_ID" --arg now "$now" --arg trig "$trigger" \
  '{schema: 2, started_at: $now, run: {run_id: $rid, run_dir: ("/x/" + $rid), started_at: $now, trigger: $trig, status: "running", stale_after_seconds: 1, skip_reason: null, finished_at: null}}' \
  > "$FAKE_RUNNER_STATE_FILE.tmp" && mv "$FAKE_RUNNER_STATE_FILE.tmp" "$FAKE_RUNNER_STATE_FILE"
FAKEEOF
  chmod +x "$path"
}

setup_env() {
  local t="$1"
  mkdir -p "$t"
  LOG_ROOT="$t/logs/maintenance"
  STATE_FILE="$LOG_ROOT/last-run.json"
  LOCK_FILE="$LOG_ROOT/vault-writer.lock"
  MARKER="$LOG_ROOT/.manual-trigger"
  LCTL_LOG="$t/launchctl.log"
  RUNNER="$t/fake-runner.sh"
  setup_fake_launchctl "$t/bin"
  setup_fake_runner "$RUNNER"
  KICK_OUT="$t/kick.out"; KICK_ERR="$t/kick.err"
}

run_kick() {
  PATH="$(dirname "$LCTL_LOG")/bin:$PATH" \
    MAINTENANCE_LOG_ROOT="$LOG_ROOT" LAST_RUN_FILE="$STATE_FILE" VAULT_WRITER_LOCK_FILE="$LOCK_FILE" \
    FAKE_LAUNCHCTL_LOG="$LCTL_LOG" FAKE_MARKER_PATH="$MARKER" \
    FAKE_RUNNER_STATE_FILE="$STATE_FILE" FAKE_RUNNER_MARKER="$MARKER" \
    KICK_START_TIMEOUT_SECS="${KICK_START_TIMEOUT_SECS:-3}" KICK_POLL_SECS="${KICK_POLL_SECS:-0.1}" \
    bash "$SCRIPT" "$@" > "$KICK_OUT" 2> "$KICK_ERR"
}

echo "=== 未ロードは起動しない ==="
setup_env "$WORK_ROOT/not-loaded"
rc=0
FAKE_LAUNCHCTL_PRINT_RC=113 run_kick || rc=$?
if [ "$rc" -eq 2 ] && ! grep -q kickstart "$LCTL_LOG" && [ ! -e "$MARKER" ]; then
  pass "未ロードは拒否し印を残さない"
else fail_case "未ロードは拒否し印を残さない"; fi

echo "=== 生存ロックを保持したまま起動を拒否する ==="
setup_env "$WORK_ROOT/busy"
mkdir -p "$LOG_ROOT"
echo "$$" > "$LOCK_FILE"
rc=0
run_kick || rc=$?
if [ "$rc" -eq 3 ] && ! grep -q kickstart "$LCTL_LOG" && [ ! -e "$MARKER" ] && [ "$(cat "$LOCK_FILE")" = "$$" ]; then
  pass "busy は非破壊で拒否"
else fail_case "busy は非破壊で拒否"; fi

echo "=== 手動起動は印を先に作り、新しい実行を返す ==="
setup_env "$WORK_ROOT/start"
rc=0
FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="test-run" run_kick || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'kickstart gui/.* marker=yes' "$LCTL_LOG" && ! grep -q 'kickstart -k' "$LCTL_LOG"; then
  pass "起動前に印を作り実行中の処理を殺さない"
else fail_case "起動前に印を作り実行中の処理を殺さない"; fi
if grep -q '^RUN_ID:test-run$' "$KICK_OUT" && grep -q '^STATE_FILE:' "$KICK_OUT" && [ "$(jq -r '.run.trigger' "$STATE_FILE")" = manual ] && [ ! -e "$MARKER" ]; then
  pass "実行 ID と記録先を返し手動起動の印を消費"
else fail_case "実行 ID と記録先を返し手動起動の印を消費"; fi

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
