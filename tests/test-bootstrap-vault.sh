#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/bootstrap-vault.sh"  # AI Brain の寄与（引数なし＝hook 形）。AI Brain のスイートは AI Brain の部品だけを起動する（設計 §4.4）
PASS=0
FAIL=0
# 新しい共通観測も実 HOME に書かない。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-vault.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
TEST_HOME="$WORK/home"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME" PYTHONDONTWRITEBYTECODE=1
export VAULT_RECALL_LOG="$TEST_HOME/recall.jsonl"
export HEALTH_RECALL_OBSERVATION_FILE="$TEST_HOME/recall-observation.json"

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

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    pass "$desc"
  else
    fail_case "$desc"
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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; return 1; }
  case "$d" in
    "" | "/")
      echo "FATAL: mktemp -d の返り値が不正です: [$d]" >&2
      return 1
      ;;
  esac
  if [ ! -d "$d" ]; then
    echo "FATAL: mktemp -d がディレクトリを作成しませんでした: [$d]" >&2
    return 1
  fi
  if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "FATAL: mktemp -d が空でない既存ディレクトリを返しました: [$d]" >&2
    return 1
  fi
  printf '%s' "$d"
}

CMUX_FIXED_STUB_DIR="$(safe_mktemp_d)" || exit 1
printf '#!/bin/bash\nexit 9\n' > "$CMUX_FIXED_STUB_DIR/cmux"
chmod +x "$CMUX_FIXED_STUB_DIR/cmux"
export PATH="$CMUX_FIXED_STUB_DIR:$PATH"
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT BOOTSTRAP_CMUX_LIB_DIR

make_full_vault() {
  local vault="$1"
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

RUN_BOOTSTRAP_DEFAULT_SESSION_JSON='{"session_id":"test-session-0000"}'
run_bootstrap() {
  local vault="$1"
  local inv_log_dir="${2:-/nonexistent-dir/vault-inventory}"
  local last_run_file="${3:-/nonexistent-dir/last-run.json}"
  local plist="${4:-/nonexistent-dir/com.takumi009.maintenance.plist}"
  local obs_file="${5:-}"
  local session_json="${6:-$RUN_BOOTSTRAP_DEFAULT_SESSION_JSON}"
  local obs_tmp=""
  if [ -z "$obs_file" ]; then
    obs_tmp="$(mktemp -d)"
    obs_file="$obs_tmp/session-observation.json"
  fi
  printf '%s\n' "$session_json" \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      MAINTENANCE_LAST_RUN_FILE="$last_run_file" \
      MAINTENANCE_PLIST_FILE="$plist" HEALTH_OBSERVATION_FILE="$obs_file" \
      HEALTH_JUDGE_NOW="${HEALTH_JUDGE_NOW:-}" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
  [ -n "$obs_tmp" ] && rm -rf "$obs_tmp"
  return 0
}
echo "=== 必読ノートを注入し、読了まで着手を止める ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  all_present=1
  for f in Preferences/absolute-rules.md Preferences/core-conduct.md Preferences/core-workflow.md Personal/profile-personal.md Preferences/vault-operation.md; do
    [[ "$ctx" == *"$VAULT_DIR/$f"* ]] || all_present=0
  done
  assert_true "必読ノートがすべて注入される" "$all_present"
  assert_contains "読了まで着手しない指示がある" "$ctx" "② 上記を読み終えるまで"
  assert_contains "Vault記録分担の正本参照" "$ctx" "$VAULT_DIR/Preferences/core-worker.md §4"

  rm -rf "$VAULT_DIR"
}

echo "=== サブ機のprivateノート不在は対象外として案内する ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Personal/profile-personal.md だけが無い（サブ想定＝private層の意図的欠落）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "Personal/profile-personal.md は列挙されない（存在しないため）" "$ctx" "Personal/profile-personal.md"
  assert_contains "private ノート対象外の注記が出る（1件）" "$ctx" "private ノートはこのマシンには無い（サブ）: 1件は対象外"

  rm -rf "$VAULT_DIR"
}
echo "=== 必読publicノートの欠落は強く警告する ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Preferences/core-conduct.md だけを欠落させる（移送失敗・sync漏れ等を模す）。

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "想定外欠落の警告文言が出る" "$ctx" "必読のはずのpublicノートが見つかりません"
  assert_not_contains "core-conduct.mdの欠落は「privateノート対象外」には数えられない（profile-personal.mdは存在するため当該注記自体が出ない）" "$ctx" "private ノートはこのマシンには無い"

  rm -rf "$VAULT_DIR"
}
HEALTH_FX_ROOT="$TESTS_DIR/fixtures/health"
HEALTH_SHARED_VAULT="$(mktemp -d)"
make_full_vault "$HEALTH_SHARED_VAULT"

fixture_vault_dir() {
  local d="$1"
  if [ -d "$d/vault" ]; then
    printf '%s' "$d/vault"
  elif [ "$(jq -r '.load.vault_root_readable' "$d/observation.json" 2>/dev/null)" = "false" ]; then
    printf '%s' "/nonexistent-dir/vault"
  else
    printf '%s' "$HEALTH_SHARED_VAULT"
  fi
}

HEALTH_FIXTURE_SESSION_JSON='{"session_id":"sess-cur-0002","source":"startup"}'
HEALTH_OBS_WORK="$(mktemp -d)"
BOOT_OBS_FILE="$HEALTH_OBS_WORK/session-observation.json"
run_bootstrap_fixture() {
  local fx="$1" session_json="${2:-$HEALTH_FIXTURE_SESSION_JSON}"
  local d="$HEALTH_FX_ROOT/$fx" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  rm -f "$BOOT_OBS_FILE"
  [ -f "$d/observation-prev.json" ] && cp "$d/observation-prev.json" "$BOOT_OBS_FILE"
  HEALTH_JUDGE_NOW="$(cat "$d/now")" \
    run_bootstrap "$(fixture_vault_dir "$d")" "$d" "$d/last-run.json" \
      "$plist" "$BOOT_OBS_FILE" "$session_json"
}

health_section() {
  printf '%s\n' "$1" | awk '/^【外部脳ヘルス】/{flag=1; print; next} flag && (/^- \[/ || /^⚠️ 観測記録/){print; next} flag{exit}'
}
echo "=== 正常（想起は未観測）のヘルス節は1行 ==="
{
  # 登録・実体・信頼だけの最小 fixture。想起はまだ一度も発火していない。
  python3 - "$REPO_ROOT" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
repo = Path(sys.argv[1])
home = Path.home()
for leader in ('claude', 'codex'):
    hook_rel = f'.{leader}/hooks/vault-recall.sh'
    hook = home / hook_rel
    hook.parent.mkdir(parents=True)
    hook.symlink_to(repo / 'ai-brain/executor/vault-recall.sh')
    groups = [{'hooks': [{'type': 'command', 'timeout': 5,
                         'command': f'$HOME/{hook_rel} --leader {leader}' + suffix}]}
              for suffix in ('', ' --observe')]
    root = home / ('.claude' if leader == 'claude' else '.codex')
    root.mkdir(exist_ok=True)
    (root / ('settings.json' if leader == 'claude' else 'hooks.json')).write_text(
        json.dumps({'hooks': {'UserPromptSubmit': groups}}))
    if leader == 'codex':
        text = '[features]\nhooks = true\n'
        for gi, group in enumerate(groups):
            handler = dict(group['hooks'][0], **{'async': False})
            identity = {'event_name': 'user_prompt_submit', 'hooks': [handler]}
            raw = json.dumps(identity, sort_keys=True, separators=(',', ':'))
            key = f'{root}/hooks.json:user_prompt_submit:{gi}:0'
            text += f'\n[hooks.state.{json.dumps(key)}]\ntrusted_hash = "sha256:{hashlib.sha256(raw.encode()).hexdigest()}"\n'
        (root / 'config.toml').write_text(text)
PY
  ctx="$(run_bootstrap_fixture S-1)"
  sec="$(health_section "$ctx")"
  assert_eq "S-1: ヘルス節は1行" "1" "$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
  assert_contains "S-1: 正常" "$sec" "stage=OK items=0"
  assert_not_contains "S-1: ⚠️ を含まない（FR-5）" "$sec" "⚠️"
}
echo "=== 想起が未配置なら両リーダーの構成異常を表示する ==="
{
  mkdir -p "$WORK/unconfigured"
  ctx="$(HOME="$WORK/unconfigured" run_bootstrap_fixture S-1)"
  sec="$(health_section "$ctx")"
  assert_contains "未配置: 構成異常を隠さない" "$sec" "stage=ERROR items=2"
  assert_eq "未配置: ヘルス節は見出しと両リーダーの異常" "3" "$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
}
echo "=== 判定機不在でも必読本文を注入する ==="
{
  ctx="$(HEALTH_JUDGE_LIB=/nonexistent-dir/health_judge.py run_bootstrap "$HEALTH_SHARED_VAULT")"
  assert_eq "判定機不在: 固定 1 行" "1" "$(printf '%s\n' "$ctx" | grep -c '^【外部脳ヘルス】判定不能（health_judge.py: ')"
  assert_not_contains "判定機不在: stage= を出さない" "$ctx" "stage="
  assert_contains "判定機不在: 本文は健在" "$ctx" "① タスクに着手する前に"
}
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
