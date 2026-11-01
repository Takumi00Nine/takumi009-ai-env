#!/usr/bin/env bash
# 隔離 HOME・Git fixture・偽通知で、完走・中断・失敗の隔離と実行記録を確認する。

set -uo pipefail

validate_temp_dir() {
  local dir="$1" label="$2"
  if [[ -z "$dir" ]]; then
    echo "FATAL: ${label}用のmktemp -dが空のパスを返しました（隔離が保証できません）。" >&2
    exit 1
  fi
  if [[ "$dir" == "/" ]]; then
    echo "FATAL: ${label}用のmktemp -dがルートディレクトリを返しました（隔離が保証できません）。" >&2
    exit 1
  fi
  if [[ ! -d "$dir" ]]; then
    echo "FATAL: ${label}用のmktemp -dがディレクトリを作成できませんでした: '${dir}'" >&2
    exit 1
  fi
  if [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    echo "FATAL: ${label}用の一時ディレクトリが空ではありません（mktempが返すはずの新規ディレクトリではない疑い・既存ディレクトリの誤指定を拒否）: '${dir}'" >&2
    exit 1
  fi
}

HOME="$(mktemp -d)" || {
  echo "FATAL: mktemp -dに失敗しました（HOME隔離用）。書込み可能な一時領域が無い可能性があります。" >&2
  exit 1
}
validate_temp_dir "$HOME" "HOME"
export HOME
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
WORK_ROOT="$(mktemp -d)" || {
  echo "FATAL: mktemp -dに失敗しました（WORK_ROOT隔離用）。書込み可能な一時領域が無い可能性があります。" >&2
  exit 1
}
validate_temp_dir "$WORK_ROOT" "WORK_ROOT"

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
assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$desc"; else fail_case "$desc (ファイルが存在しません: $path)"; fi
}
assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then pass "$desc"; else fail_case "$desc (存在してはいけないのに存在する: $path)"; fi
}

setup_fake_repo() {
  local repo="$1"
  mkdir -p "$repo/ai-brain/executor" "$repo/ai-brain/data" "$repo/core/executor" "$repo/core/assembly" "$repo/core/data" \
    "$repo/notify/executor" "$repo/notify/connect/macos"
  cp "$REPO_ROOT/ai-brain/executor/maintenance.sh" "$repo/ai-brain/executor/maintenance.sh"
  cp "$REPO_ROOT/ai-brain/executor/backup-vault.sh" "$repo/ai-brain/executor/backup-vault.sh"
  cp "$REPO_ROOT/core/executor/pid-lock.sh" "$repo/core/executor/pid-lock.sh"
  cp "$REPO_ROOT/core/executor/status-file.sh" "$repo/core/executor/status-file.sh"
  cp "$REPO_ROOT/ai-brain/executor/maintenance_run_step.py" "$repo/ai-brain/executor/maintenance_run_step.py"
  chmod +x "$repo/ai-brain/executor/maintenance.sh" "$repo/ai-brain/executor/backup-vault.sh"

  if [ -f "$REPO_ROOT/core/executor/notice.sh" ]; then
    cp "$REPO_ROOT/core/executor/notice.sh" "$repo/core/executor/notice.sh"
  fi
  if [ -f "$REPO_ROOT/core/assembly/ledger-tool.sh" ]; then
    cp "$REPO_ROOT/core/assembly/ledger-tool.sh" "$repo/core/assembly/ledger-tool.sh"
    chmod +x "$repo/core/assembly/ledger-tool.sh"
  fi
  cp "$REPO_ROOT/core/executor/vault-paths.sh" "$repo/core/executor/vault-paths.sh"
  cat > "$repo/notify/executor/notify.sh" <<'FAKEEOF'
#!/bin/bash
set -u
kind="${1:-}"
case "$kind" in
  call)
    title="${3:-}"; body="${4:-}"
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' -e 'end run' \
      "$body" "$title" >/dev/null 2>&1
    exit 0
    ;;
  answer) exit 0 ;;
  *) echo "usage: notify.sh call <区分> <題> <本文> [<音>] | notify.sh answer" >&2; exit 64 ;;
esac
FAKEEOF
  chmod +x "$repo/notify/executor/notify.sh"
  printf 'part\tnotify/executor/notify.sh\tnotify\texecutor\t-\tnotify.send\tFAKE 口（test-maintenance 専用）\t-\t-\n' \
    > "$repo/core/data/ledger.tsv"

  cat > "$repo/core/assembly/check-drift.sh" <<'FAKEEOF'
#!/usr/bin/env bash
echo "[fake-check-drift] human readable line"
FAKE_DRIFT_DEFAULT_JSON='{"total_drift": 0, "item4_drift": 0, "drift_excluding_item4": 0, "unknown_config_keys": 0}'
echo "${FAKE_DRIFT_JSON:-$FAKE_DRIFT_DEFAULT_JSON}"
exit "${FAKE_DRIFT_EXIT:-0}"
FAKEEOF
  chmod +x "$repo/core/assembly/check-drift.sh"

  cat > "$repo/ai-brain/executor/export-public-vault.sh" <<'FAKEEOF'
#!/usr/bin/env bash
echo "[fake-export] called" >> "${FAKE_EXPORT_CALL_LOG:-/dev/null}"
exit "${FAKE_EXPORT_EXIT:-0}"
FAKEEOF
  chmod +x "$repo/ai-brain/executor/export-public-vault.sh"

  local py_detector upper default_json
  for py_detector in fragments_log vault_inventory; do
    upper="$(echo "$py_detector" | tr '[:lower:]' '[:upper:]')"
    default_json='{}'
    [[ "$py_detector" == "fragments_log" ]] && default_json='{"scan_error_count": 0, "fragments": [], "truncated": []}'
    cat > "$repo/ai-brain/executor/${py_detector}.py" <<PYEOF
#!/usr/bin/env python3
import os, sys
print(os.environ.get("FAKE_${upper}_JSON", '$default_json'))
sys.exit(int(os.environ.get("FAKE_${upper}_EXIT", "0")))
PYEOF
    chmod +x "$repo/ai-brain/executor/${py_detector}.py"
  done
}

setup_fake_osascript() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/osascript" <<'FAKEEOF'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_OSASCRIPT_LOG:-/dev/null}"
exit 0
FAKEEOF
  chmod +x "$bindir/osascript"
}

setup_fake_prune_cmd() {
  local path="$1"
  cat > "$path" <<'FAKEEOF'
#!/usr/bin/env bash
echo "called $*" >> "${FAKE_PRUNE_CALL_LOG:-/dev/null}"
if [[ "${1:-}" != "prune" ]]; then
  echo "usage: cmux-task-declare.sh prune" >&2
  exit 64
fi
exit 0
FAKEEOF
  chmod +x "$path"
}
setup_test_env() {
  local test_dir="$1"
  REPO="$test_dir/repo"
  VAULT="$test_dir/vault"
  AIENV_REPO="$test_dir/aienv"
  LOG_ROOT="$test_dir/logs/maintenance"
  local osascript_dir="$test_dir/bin"
  OSASCRIPT_LOG="$test_dir/osascript.log"
  EXPORT_CALL_LOG="$test_dir/export-call.log"
  PRUNE_STUB="$test_dir/fake-cmux-task-declare.sh"
  PRUNE_CALL_LOG="$test_dir/prune-call.log"
  setup_fake_prune_cmd "$PRUNE_STUB"
  TEST_TMPDIR="$test_dir/tmp"
  mkdir -p "$TEST_TMPDIR"

  mkdir -p "$VAULT/Knowledge" "$VAULT/Fragments" "$AIENV_REPO/ai-brain/data/vault-public"
  setup_fake_repo "$REPO"
  setup_fake_osascript "$osascript_dir"
  export PATH="$osascript_dir:$PATH"

  git -C "$VAULT" init -q -b main
  git -C "$VAULT" config user.email test@example.invalid
  git -C "$VAULT" config user.name test
  echo dummy > "$VAULT/Knowledge/dummy.md"
  git -C "$VAULT" add -A && git -C "$VAULT" commit -q -m init >/dev/null

  git -C "$AIENV_REPO" init -q -b main
  git -C "$AIENV_REPO" config user.email test@example.invalid
  git -C "$AIENV_REPO" config user.name test
  echo readme > "$AIENV_REPO/ai-brain/data/vault-public/README.md"
  git -C "$AIENV_REPO" add -A && git -C "$AIENV_REPO" commit -q -m init >/dev/null
}

run_maintenance() {
  : "${TIMEOUT_BACKUP_VAULT:=10}"
  : "${TIMEOUT_EXPORT_PUBLIC_VAULT:=10}"
  : "${TIMEOUT_CHECK_DRIFT:=2}"
  : "${TIMEOUT_FRAGMENTS_LOG:=10}"
  : "${TIMEOUT_VAULT_INVENTORY:=10}"
  : "${MAINTENANCE_STALE_LOCK_SECONDS:=3600}"
  : "${TIMEOUT_TASK_PRUNE:=5}"
  : "${MAINTENANCE_TASK_PRUNE_CMD:=$PRUNE_STUB}"
  VAULT="$VAULT" AIENV_REPO="$AIENV_REPO" MAINTENANCE_LOG_ROOT="$LOG_ROOT" TMPDIR="$TEST_TMPDIR" \
    FAKE_OSASCRIPT_LOG="$OSASCRIPT_LOG" FAKE_EXPORT_CALL_LOG="$EXPORT_CALL_LOG" \
    FAKE_PRUNE_CALL_LOG="$PRUNE_CALL_LOG" \
    TIMEOUT_BACKUP_VAULT="$TIMEOUT_BACKUP_VAULT" TIMEOUT_EXPORT_PUBLIC_VAULT="$TIMEOUT_EXPORT_PUBLIC_VAULT" \
    TIMEOUT_CHECK_DRIFT="$TIMEOUT_CHECK_DRIFT" TIMEOUT_FRAGMENTS_LOG="$TIMEOUT_FRAGMENTS_LOG" \
    TIMEOUT_VAULT_INVENTORY="$TIMEOUT_VAULT_INVENTORY" \
    TIMEOUT_TASK_PRUNE="$TIMEOUT_TASK_PRUNE" MAINTENANCE_TASK_PRUNE_CMD="$MAINTENANCE_TASK_PRUNE_CMD" \
    MAINTENANCE_STALE_LOCK_SECONDS="$MAINTENANCE_STALE_LOCK_SECONDS" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    "$@" bash "$REPO/ai-brain/executor/maintenance.sh" > "$LAST_STDOUT" 2> "$LAST_STDERR"
}

latest_run_dir() {
  python3 -c "import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(p.resolve() if p.is_symlink() else '')" "$LOG_ROOT/latest"
}

echo "=== 正常な週次メンテは全 Phase を完走する ==="
T="$WORK_ROOT/success"; mkdir -p "$T"; setup_test_env "$T"
LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
rc=0
run_maintenance || rc=$?
assert_eq "全 Phase が終了 0" 0 "$rc"
RUN_DIR="$(latest_run_dir)"
assert_file_exists "検出器まで到達" "$RUN_DIR/fragments.json"
assert_eq "実行と完了の記録が同じ ID で正常終了" true "$(jq '.run.status == "completed" and .completed.run_id == .run.run_id and .completed.fully_ok and (.last_success_at != null)' "$LOG_ROOT/last-run.json")"
assert_file_not_exists "正常時に異常通知しない" "$OSASCRIPT_LOG"
assert_contains "Fragments に週次サマリ" "$(find "$VAULT/Fragments" -name '20*.md' -exec cat {} \;)" '定常メンテ(週次)'

echo "=== backup 失敗は後続を止める ==="
T="$WORK_ROOT/backup-fail"; mkdir -p "$T"; setup_test_env "$T"
LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
git -C "$VAULT" checkout -q -b other-branch
rc=0; run_maintenance || rc=$?
assert_eq "backup 失敗は非 0" 1 "$rc"
assert_file_not_exists "Phase1 へ進まない" "$(latest_run_dir)/drift-stdout.log"
assert_eq "失敗を記録し成功日時を進めない" true "$(jq '.last_result == "fail" and .last_success_at == null and (.completed.fully_ok == false)' "$LOG_ROOT/last-run.json")"

echo "=== drift は警告を記録して続行する ==="
T="$WORK_ROOT/drift"; mkdir -p "$T"; setup_test_env "$T"
LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
rc=0; FAKE_DRIFT_EXIT=1 FAKE_DRIFT_JSON='{"total_drift":3,"drift_excluding_item4":3}' run_maintenance || rc=$?
assert_eq "drift があっても完走" 0 "$rc"
assert_file_exists "後続の inventory を実行" "$(latest_run_dir)/step-status-inventory.json"
assert_eq "警告を記録し成功日時を進めない" true "$(jq '.last_result == "warn" and .last_success_at == null and (.completed.steps | length > 0)' "$LOG_ROOT/last-run.json")"

echo "=== 検出器の失敗を隔離して続行する ==="
T="$WORK_ROOT/detector-fail"; mkdir -p "$T"; setup_test_env "$T"
LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
rc=0; FAKE_FRAGMENTS_LOG_EXIT=1 run_maintenance || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$(latest_run_dir)/step-status-inventory.json" ]; then pass "検出器の失敗後も続行"; else fail_case "検出器の失敗後も続行"; fi
assert_eq "誤った候補数や成功日時を記録しない" true "$(jq '.fragments_candidates == null and .last_success_at == null and (.completed.fully_ok == false)' "$LOG_ROOT/last-run.json")"

echo "=== 生存ロックがあればメンテしない ==="
T="$WORK_ROOT/busy"; mkdir -p "$T"; setup_test_env "$T"
LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
mkdir -p "$LOG_ROOT"; echo "$$" > "$LOG_ROOT/vault-writer.lock"
rc=0; run_maintenance || rc=$?
assert_eq "busy は穏当に skip" 0 "$rc"
assert_eq "ロックを保持し skip を記録" true "$(jq '.run.status == "skipped" and .run.skip_reason == "busy:lock"' "$LOG_ROOT/last-run.json")"

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
