#!/usr/bin/env bash
# scripts/maintenance-kick.sh のユニットテスト（health-self-explain 設計 v1.2 §7.1・
# §10.1・§16.2 実装 A）。
#
# 実 launchd・実 $HOME・実 last-run.json には一切触れない: HOME を隔離 temp へ
# 差し替え、PATH 先頭に偽 launchctl（呼び出しを記録し、print／kickstart の終了
# コードを env で演じ、kickstart 時に「偽 runner」を背景起動して last-run.json を
# 書く）を置く。全パスは env（MAINTENANCE_LOG_ROOT 等）で temp へ向ける。
#
# 実行方法: bash tests/test-maintenance-kick.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/maintenance-kick.sh"

HOME="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗" >&2; exit 1; }
[[ -n "$HOME" && "$HOME" != "/" && -d "$HOME" ]] || { echo "FATAL: HOME 隔離に失敗" >&2; exit 1; }
export HOME
WORK_ROOT="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗" >&2; exit 1; }
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

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
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
}
assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$desc"; else fail_case "$desc (ファイルが存在しません: $path)"; fi
}
assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then pass "$desc"; else fail_case "$desc (存在してはいけないのに存在する: $path)"; fi
}

# 偽 launchctl（$1 に置く）。挙動は env で演じる:
#   FAKE_LAUNCHCTL_LOG          呼び出しの引数を 1 行ずつ記録（kickstart 行には marker=yes/no を付ける）
#   FAKE_LAUNCHCTL_PRINT_RC     print の終了コード（既定 0）
#   FAKE_LAUNCHCTL_KICKSTART_RC kickstart の終了コード（既定 0）
#   FAKE_MARKER_PATH            kickstart 時に印ファイルの有無を記録する対象
#   FAKE_RUNNER_SCRIPT          非空なら kickstart 成功時に背景起動する（偽 runner）
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

# 偽 runner（$1 に置く）。maintenance.sh の書き手契約のうち kick が読む部分だけを演じる:
#   FAKE_RUNNER_STATE_FILE   last-run.json の場所
#   FAKE_RUNNER_RUN_ID       新しい run_id
#   FAKE_RUNNER_DELAY_START  開始記録（status=running）を書くまでの秒
#   FAKE_RUNNER_FINAL        completed|skipped|none（none＝完了記録を書かない）
#   FAKE_RUNNER_DELAY_FINISH 完了記録を書くまでの秒
#   FAKE_RUNNER_SKIP_REASON  skipped のときの skip_reason
#   FAKE_RUNNER_FULLY_OK     completed のときの fully_ok（true|false）
#   FAKE_RUNNER_MARKER       印ファイル（在れば消費して trigger=manual）
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
[[ "${FAKE_RUNNER_FINAL:-completed}" != "none" ]] || exit 0
sleep "${FAKE_RUNNER_DELAY_FINISH:-0.3}"
fin="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "${FAKE_RUNNER_FINAL:-completed}" == "skipped" ]]; then
  jq --arg fin "$fin" --arg sr "${FAKE_RUNNER_SKIP_REASON:-busy:lock}" '.run.status = "skipped" | .run.skip_reason = $sr | .run.finished_at = $fin' \
    "$FAKE_RUNNER_STATE_FILE" > "$FAKE_RUNNER_STATE_FILE.tmp" && mv "$FAKE_RUNNER_STATE_FILE.tmp" "$FAKE_RUNNER_STATE_FILE"
else
  fo="${FAKE_RUNNER_FULLY_OK:-true}"
  jq --arg fin "$fin" --argjson fo "$fo" '.run.status = "completed" | .run.finished_at = $fin | .completed = {run_id: .run.run_id, run_dir: .run.run_dir, trigger: .run.trigger, started_at: .run.started_at, finished_at: $fin, fully_ok: $fo, steps: [], info: []}' \
    "$FAKE_RUNNER_STATE_FILE" > "$FAKE_RUNNER_STATE_FILE.tmp" && mv "$FAKE_RUNNER_STATE_FILE.tmp" "$FAKE_RUNNER_STATE_FILE"
fi
FAKEEOF
  chmod +x "$path"
}

# 共通セットアップ。呼び出し後: LOG_ROOT / STATE_FILE / LOCK_FILE / MARKER / LCTL_LOG / RUNNER
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

# kick を実行する（PATH 先頭に偽 launchctl・全パスを temp へ）。追加の env は
# `FAKE_...=... run_kick --wait` のように呼び出し側のプレフィクスで渡す。
run_kick() {
  PATH="$(dirname "$LCTL_LOG")/bin:$PATH" \
    MAINTENANCE_LOG_ROOT="$LOG_ROOT" LAST_RUN_FILE="$STATE_FILE" VAULT_WRITER_LOCK_FILE="$LOCK_FILE" \
    FAKE_LAUNCHCTL_LOG="$LCTL_LOG" FAKE_MARKER_PATH="$MARKER" \
    FAKE_RUNNER_STATE_FILE="$STATE_FILE" FAKE_RUNNER_MARKER="$MARKER" \
    KICK_START_TIMEOUT_SECS="${KICK_START_TIMEOUT_SECS:-3}" KICK_POLL_SECS="${KICK_POLL_SECS:-0.1}" \
    bash "$SCRIPT" "$@" > "$KICK_OUT" 2> "$KICK_ERR"
}

UID_NUM="$(id -u)"
LABEL="com.takumi009.maintenance"

echo "=== K-1. kick_refused_not_loaded_rc2: launchctl print が非 0 → KICK_REFUSED:not_loaded・終了 2・kickstart は呼ばれず印ファイルも作らない ==="
{
  setup_env "$WORK_ROOT/k1"
  rc=0
  FAKE_LAUNCHCTL_PRINT_RC=113 run_kick || rc=$?
  assert_eq "kick_refused_not_loaded_rc2: 終了コード 2" "2" "$rc"
  assert_eq "固定文 KICK_REFUSED:not_loaded" "KICK_REFUSED:not_loaded" "$(cat "$KICK_OUT")"
  assert_contains "print の呼び方＝gui/<uid>/<label>" "$(cat "$LCTL_LOG")" "print gui/${UID_NUM}/${LABEL}"
  assert_not_contains "kickstart は呼ばれない" "$(cat "$LCTL_LOG")" "kickstart"
  assert_file_not_exists "印ファイルは作られない" "$MARKER"
  assert_contains "stderr に install-maintenance.sh の案内" "$(cat "$KICK_ERR")" "install-maintenance.sh"
}

echo "=== K-2. kick_refused_busy_lock_rc3: Vault 書込ロックを生存プロセスが保持中 → KICK_REFUSED:busy・終了 3 ==="
{
  setup_env "$WORK_ROOT/k2"
  mkdir -p "$LOG_ROOT"
  echo "$$" > "$LOCK_FILE"
  rc=0
  run_kick || rc=$?
  assert_eq "kick_refused_busy_lock_rc3: 終了コード 3" "3" "$rc"
  assert_eq "固定文 KICK_REFUSED:busy" "KICK_REFUSED:busy" "$(cat "$KICK_OUT")"
  assert_not_contains "kickstart は呼ばれない" "$(cat "$LCTL_LOG")" "kickstart"
  assert_file_not_exists "印ファイルは作られない" "$MARKER"
  assert_eq "ロックファイルは触らない（読み取り専用）" "$$" "$(cat "$LOCK_FILE")"
}

echo "=== K-3. kick_refused_busy_running_rc3: run.status=running かつ経過 < stale_after_seconds → busy・終了 3。経過 ≥ stale（中断相当）なら起動する ==="
{
  setup_env "$WORK_ROOT/k3"
  mkdir -p "$LOG_ROOT"
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg now "$NOW_ISO" '{schema: 2, run: {run_id: "2026-09-21/060000-1", status: "running", started_at: $now, stale_after_seconds: 3600, trigger: "scheduled", run_dir: "/x", skip_reason: null, finished_at: null}}' > "$STATE_FILE"
  rc=0
  run_kick || rc=$?
  assert_eq "kick_refused_busy_running_rc3: 終了コード 3" "3" "$rc"
  assert_eq "固定文 KICK_REFUSED:busy" "KICK_REFUSED:busy" "$(cat "$KICK_OUT")"
  assert_not_contains "kickstart は呼ばれない" "$(cat "$LCTL_LOG")" "kickstart"
  # 経過 ≥ stale（開始が 2 時間以上前）＝中断相当なら busy ではない。
  jq '.run.started_at = "2026-01-01T00:00:00Z"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  : > "$LCTL_LOG"
  rc=0
  FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="2026-09-21/070000-2" FAKE_RUNNER_FINAL=none run_kick || rc=$?
  assert_eq "中断相当（経過 ≥ stale）なら起動する（終了 0）" "0" "$rc"
  assert_contains "kickstart が呼ばれる" "$(cat "$LCTL_LOG")" "kickstart gui/${UID_NUM}/${LABEL}"
}

echo "=== K-4. kick_marker_written_before_kickstart / kick_kickstart_without_k / kick_prints_run_id_and_state_file ==="
{
  setup_env "$WORK_ROOT/k4"
  mkdir -p "$LOG_ROOT"
  jq -n '{schema: 2, run: {run_id: "2026-09-14/060000-1", status: "completed", started_at: "2026-09-14T06:00:00Z", stale_after_seconds: 7200, trigger: "scheduled", run_dir: "/x", skip_reason: null, finished_at: "2026-09-14T06:07:00Z"}}' > "$STATE_FILE"
  rc=0
  FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="2026-09-21/101500-777" FAKE_RUNNER_FINAL=none run_kick || rc=$?
  assert_eq "終了コード 0" "0" "$rc"
  assert_contains "kick_marker_written_before_kickstart: kickstart 時に印ファイルが存在する" "$(cat "$LCTL_LOG")" "marker=yes"
  assert_eq "kick_kickstart_without_k: kickstart の引数に -k が無い（実行中を殺さない）" "kickstart gui/${UID_NUM}/${LABEL} marker=yes" "$(grep '^kickstart' "$LCTL_LOG")"
  assert_eq "kick_prints_run_id_and_state_file: 1 行目 RUN_ID:<新しい run_id>" "RUN_ID:2026-09-21/101500-777" "$(sed -n '1p' "$KICK_OUT")"
  assert_eq "kick_prints_run_id_and_state_file: 2 行目 STATE_FILE:<path>" "STATE_FILE:${STATE_FILE}" "$(sed -n '2p' "$KICK_OUT")"
  assert_eq "--wait 無しは 2 行だけ" "2" "$(wc -l < "$KICK_OUT" | tr -d ' ')"
  assert_eq "runner が印ファイルを消費し trigger=manual と記録している（結合）" "manual" "$(jq -r '.run.trigger' "$STATE_FILE")"
  assert_file_not_exists "印ファイルは runner が消費済み" "$MARKER"
}

echo "=== K-5. kick_failed_rc5_removes_marker: kickstart が非 0 → KICK_FAILED・終了 5・印ファイルを消す ==="
{
  setup_env "$WORK_ROOT/k5"
  rc=0
  FAKE_LAUNCHCTL_KICKSTART_RC=5 run_kick || rc=$?
  assert_eq "kick_failed_rc5_removes_marker: 終了コード 5" "5" "$rc"
  assert_eq "固定文 KICK_FAILED" "KICK_FAILED" "$(cat "$KICK_OUT")"
  assert_contains "kickstart は印ファイルつきで呼ばれていた" "$(cat "$LCTL_LOG")" "marker=yes"
  assert_file_not_exists "kick_failed_rc5_removes_marker: 印ファイルが消えている" "$MARKER"
}

echo "=== K-6. kick_timeout_rc6: 起動が KICK_START_TIMEOUT_SECS 以内に記録へ現れない → KICK_TIMEOUT・終了 6 ==="
{
  setup_env "$WORK_ROOT/k6"
  rc=0
  KICK_START_TIMEOUT_SECS=1 KICK_POLL_SECS=0.2 run_kick || rc=$?
  assert_eq "kick_timeout_rc6: 終了コード 6" "6" "$rc"
  assert_eq "固定文 KICK_TIMEOUT" "KICK_TIMEOUT" "$(cat "$KICK_OUT")"
  assert_contains "stderr に maintenance.log の案内" "$(cat "$KICK_ERR")" "maintenance.log"
  # 記録が無い状態（初回）でも run_id の変化待ちが空→非空で成立することは K-4 で担保。
  # health-self-explain 検証 A-3（リーダー裁定）: 終了 6 では印ファイルを消す
  # （遅れて起動した run は口を経ない起動と区別できず scheduled と記録されうる）。
  assert_file_not_exists "kick_timeout_rc6: 終了 6 のあと印ファイルが無い（A-3）" "$MARKER"
}

echo "=== K-7. kick_wait_prints_status_and_skip_reason: --wait は run.status != running まで待ち、completed → STATUS/FULLY_OK・skipped → STATUS/SKIP_REASON を印字 ==="
{
  setup_env "$WORK_ROOT/k7"
  rc=0
  FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="2026-09-21/110000-1" FAKE_RUNNER_FINAL=completed FAKE_RUNNER_FULLY_OK=true run_kick --wait || rc=$?
  assert_eq "completed: 終了コード 0" "0" "$rc"
  assert_eq "completed: 4 行＝RUN_ID/STATE_FILE/STATUS/FULLY_OK" "RUN_ID:2026-09-21/110000-1|STATE_FILE:${STATE_FILE}|STATUS:completed|FULLY_OK:true" "$(paste -sd'|' "$KICK_OUT")"

  setup_env "$WORK_ROOT/k7b"
  rc=0
  FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="2026-09-21/110100-2" FAKE_RUNNER_FINAL=completed FAKE_RUNNER_FULLY_OK=false run_kick --wait || rc=$?
  assert_eq "completed(fully_ok=false): FULLY_OK:false" "STATUS:completed|FULLY_OK:false" "$(sed -n '3,4p' "$KICK_OUT" | paste -sd'|' -)"

  setup_env "$WORK_ROOT/k7c"
  rc=0
  FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="2026-09-21/110200-3" FAKE_RUNNER_FINAL=skipped FAKE_RUNNER_SKIP_REASON="busy:backup0" run_kick --wait || rc=$?
  assert_eq "skipped: 終了コード 0（busy-skip は失敗ではなく再実行の対象＝AC-13a の注意）" "0" "$rc"
  assert_eq "kick_wait_prints_status_and_skip_reason: STATUS:skipped と SKIP_REASON:busy:backup0" "STATUS:skipped|SKIP_REASON:busy:backup0" "$(sed -n '3,4p' "$KICK_OUT" | paste -sd'|' -)"
}

echo "=== K-8. --wait の待ち切れ: 完了記録が stale_after_seconds 以内に書かれない → KICK_WAIT_TIMEOUT・終了 7 ==="
{
  setup_env "$WORK_ROOT/k8"
  rc=0
  # 偽 runner の stale_after_seconds=1 が待ちの上限になる。
  FAKE_RUNNER_SCRIPT="$RUNNER" FAKE_RUNNER_RUN_ID="2026-09-21/120000-1" FAKE_RUNNER_FINAL=none KICK_POLL_SECS=0.2 run_kick --wait || rc=$?
  assert_eq "終了コード 7" "7" "$rc"
  assert_eq "3 行目 KICK_WAIT_TIMEOUT" "KICK_WAIT_TIMEOUT" "$(sed -n '3p' "$KICK_OUT")"
}

echo "=== K-9. 使い方の誤り → 終了 1／--help → 終了 0 ==="
{
  setup_env "$WORK_ROOT/k9"
  rc=0
  run_kick --bogus || rc=$?
  assert_eq "不明な引数は終了 1" "1" "$rc"
  assert_not_contains "不明な引数では launchctl を呼ばない" "$(cat "$LCTL_LOG" 2>/dev/null || true)" "print"
  rc=0
  run_kick --help || rc=$?
  assert_eq "--help は終了 0" "0" "$rc"
  assert_contains "--help に終了コード表" "$(cat "$KICK_OUT")" "KICK_REFUSED:not_loaded"
}

echo "=== K-10. no_real_home_default_in_tests（静的）: 本テストの kick 起動行は既定が実ファイルの env（MAINTENANCE_LOG_ROOT・LAST_RUN_FILE・VAULT_WRITER_LOCK_FILE）を必ず temp へ向けている ==="
{
  DIRECT_LINES="$(grep -n 'bash "\$SCRIPT"' "$TESTS_DIR/test-maintenance-kick.sh" | grep -v '^[0-9]*: *#')"
  assert_eq "直接起動行は run_kick の 1 行だけ" "1" "$(printf '%s\n' "$DIRECT_LINES" | grep -c .)"
  RUN_KICK_BODY="$(sed -n '/^run_kick() {/,/^}/p' "$TESTS_DIR/test-maintenance-kick.sh")"
  for v in MAINTENANCE_LOG_ROOT LAST_RUN_FILE VAULT_WRITER_LOCK_FILE; do
    assert_contains "run_kick が $v を temp へ向ける" "$RUN_KICK_BODY" "$v=\""
  done
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
