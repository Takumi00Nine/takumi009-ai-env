#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/team/connect/claude-code/profile-status.sh"
STATUS_HOME="$(mktemp -d)"
export HOME="$STATUS_HOME"
trap 'rm -rf "$STATUS_HOME"' EXIT
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

SHARED_MODELS_CONF="$STATUS_HOME/models.conf"
cat > "$SHARED_MODELS_CONF" <<'EOF'
[t-opus-high]
provider=anthropic-api
model=claude-opus-5-5
effort=high

[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5

[codex-review]
provider=external
execution=external-cli
model=codex-review-default
effort=high
EOF
export AIENV_MODEL_DEFS_FILE="$SHARED_MODELS_CONF"
STATUS_SESSION_JSON='{"session_id":"test-session-0000"}'
run_status_with_profile() {
  local profile_path="$1" models_conf="${2:-$SHARED_MODELS_CONF}"
  echo "$STATUS_SESSION_JSON" \
    | AIENV_MODEL_DEFS_FILE="$models_conf" BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 \
      AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
run_status() {
  echo "$STATUS_SESSION_JSON" | BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
make_ok_profile() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
---
schema_version: 8
profile_slug: authoring
team_mode:        configured value=team
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader:      configured model=t-opus-high
---
EOF
}

echo "=== slotsの形とhookの合成 ==="
{
  set +e
  slots_json="$(echo "$STATUS_SESSION_JSON" | BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" --slots 2>/dev/null)"
  slots_rc=$?
  set -e
  assert_eq "S1: --slots の終了コード 0" "0" "$slots_rc"
  assert_eq "S1: 枠名＝directive5・opening・profile-warning・role-hold（jq keys は辞書順）" \
    "directive5,opening,profile-warning,role-hold" \
    "$(printf '%s' "$slots_json" | jq -r '.slots | keys | join(",")' 2>/dev/null)"
  hook_ctx="$(run_status 2>/dev/null || true)"
  assert_eq "S1: 引数なし＝空でない枠（opening・directive5・role-hold）を空行で連結" \
    "$(printf '%s' "$slots_json" | jq -r '[.slots.opening, .slots.directive5, .slots["role-hold"]] | join("\n\n")' 2>/dev/null)" "$hook_ctx"
}
echo "=== プロファイル不在では最小能力へ倒す ==="
{
  PROFILE_PATH="$(mktemp -d)/nonexistent/profile.md"

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "T1: 解決不能時の正本参照" "$ctx" "~/Data/obsidian/Preferences/role-vacancy.md"
  # 不在(T1)はモード行に利用不可の状態を出す。
  mode_line_t1="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "T1: モード行に利用不可の理由コード" "$mode_line_t1" "利用不可（T1）"
}
echo "=== プロファイル破損では最小能力へ倒す ==="
{
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # frontmatterの終端区切りが無い壊れたファイル。
  cat > "$PROFILE_PATH" <<'EOF'
---
team_mode: 本人
EOF

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "T6: 破損時の正本参照" "$ctx" "~/Data/obsidian/Preferences/core-workflow.md §7"
  assert_contains "T6: YAML破損の理由が出る" "$ctx" "T6"

  rm -rf "$PROFILE_DIR"
}
echo "=== symlinkは実体として受理しない ==="
{
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  REAL_TARGET="$PROFILE_DIR/real-target.md"
  make_ok_profile "$REAL_TARGET"
  ln -s "$REAL_TARGET" "$PROFILE_PATH"

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "symlink時の正本参照" "$ctx" "~/Data/obsidian/Preferences/role-vacancy.md"
  assert_contains "SYMLINK理由コードが出る" "$ctx" "SYMLINK"
  rm -rf "$PROFILE_DIR"
}
PROFILE_LIB="$REPO_ROOT/team/executor/profile_resolve.py"
AGENTS_DIR="$REPO_ROOT/team/rules/agents"

resolve_v2() {
  local path="$1" agents_dir="${2:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve "$path" --agents-dir "$agents_dir"
}

echo "=== MODE-TEAM: 配役表から開幕1行まで ==="
{
  MODE_PROFILE="$STATUS_HOME/mode-profile.md"
  make_ok_profile "$MODE_PROFILE"
  resolved="$(resolve_v2 "$MODE_PROFILE" 2>/dev/null || true)"
  assert_contains "MODE-TEAM: resolverはteamを返す" "$resolved" "TEAM_MODE:team"
  ctx="$(run_status_with_profile "$MODE_PROFILE")"
  mode_line="$(printf '%s\n' "$ctx" | sed -n '/^🧭 現在＝/p')"
  # 正本core-conduct §1のteam行。実Vaultは試験から読まない。
  expected='🧭 現在＝チームモード（私はマックリーダーとして、案件ごとにプロジェクトリーダーを立ててワーカーのチームに任せ、全体の把握とあなたとの取り次ぎをします）。他のモード＝単独／軽量。切り替えたいときは言ってください'
  assert_eq "MODE-TEAM: teamの開幕文は正本と一致する" "$expected" "${mode_line%%｜*}"
  sed 's/value=team/value=full/' "$MODE_PROFILE" > "$STATUS_HOME/old-full.md"
  ctx="$(run_status_with_profile "$STATUS_HOME/old-full.md")"
  mode_line="$(printf '%s\n' "$ctx" | sed -n '/^🧭 現在＝/p')"
  assert_contains "MODE-TEAM: fullを読み替えずモード未確定にする" "$mode_line" "現在＝モード未確定"
}

V2_BASE='---
schema_version: 8
profile_slug: authoring
team_mode:        configured value=team
no_read_paths:    unavailable
machine_role:     configured value=main'

make_v2_profile() {
  # $1=path、以降の引数は role.行（そのまま追記）。
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "$V2_BASE"
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '---\n'
  } > "$path"
}
echo "=== 外部providerのリーダーは拒否する ==="
{
  EXT_LEADER="$(mktemp -d)/extleader.md"
  make_v2_profile "$EXT_LEADER" \
    "role.leader: configured model=codex-review"
  out="$(resolve_v2 "$EXT_LEADER")"  || true
  assert_contains "leaderのprovider=externalはfailになる" "$out" "MINIMAL"
}
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
