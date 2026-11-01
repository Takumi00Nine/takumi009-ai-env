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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
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

[bedrock-opus]
provider=bedrock
model=opus

[bedrock-haiku]
provider=bedrock
model=haiku

[bedrock-sonnet]
provider=bedrock
model=sonnet

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
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
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
  assert_contains "T1: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  # FR-12（要件v1.2.1）: 不在(T1)は🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（値の再掲は無く区分コードのみ）。
  mode_line_t1="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "T1: モード行に「本人確認へ倒す」を含む" "$mode_line_t1" "本人確認へ倒す"
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
  assert_contains "T6: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
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
  assert_contains "symlinkでは最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "SYMLINK理由コードが出る" "$ctx" "SYMLINK"
  rm -rf "$PROFILE_DIR"
}
PROFILE_LIB="$REPO_ROOT/team/executor/profile_resolve.py"
AGENTS_DIR="$REPO_ROOT/team/rules/agents"

resolve_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}
resolve_leader_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve-leader "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}

V2_BASE='---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
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
echo "=== ワーカーの利用可能候補と空席の判定 ==="
{
  MULTI_CAND="$(mktemp -d)/workermulticand.md"
  make_v2_profile "$MULTI_CAND" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,t-sonnet-high"
  # bedrock.envを与えない(ABSENT=disabled)のでverifierの1件目(bedrock)はV9-dで使用不可・
  # 2件目(t-sonnet-high)は使用可。
  out="$(resolve_v2 "$MULTI_CAND")"  || true
  assert_not_contains "1件目が使用不可でも2件目が使えれば空席にならない" "$out" "VACANT:verifier"
  assert_contains "resolve自体はOKのまま" "$out" "OK"

  echo "--- 全候補が使用不可のときだけVACANT+VACANT_REASON、優先順はV1-b→V9-d→V12 ---"
  BOTH_BAD="$(mktemp -d)/bothbad.md"
  make_v2_profile "$BOTH_BAD" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus"
  out="$(resolve_v2 "$BOTH_BAD")"  || true
  assert_contains "全候補がbedrockで経路無効なら空席になる" "$out" "VACANT:verifier"
  assert_contains "空席理由の条件番号が出る(V9-d)" "$out" "VACANT_REASON:verifier=V9-d"
}
echo "=== 成功時にピン実値と認証情報を漏らさない ==="
{
  PIN_ENV="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn
AWS_ACCESS_KEY_ID=AKIA_SHOULD_NEVER_LEAK
EOF
  SECRET_PROFILE="$(mktemp -d)/secretprofile.md"
  make_v2_profile "$SECRET_PROFILE" \
    "role.leader: configured model=bedrock-opus"
  out="$(resolve_v2 "$SECRET_PROFILE" "$PIN_ENV")"  || true
  assert_not_contains "resolve出力にピン実値(ARN)が現れない" "$out" "supersecret-arn"
  assert_not_contains "resolve出力にAWSキーが現れない" "$out" "AKIA_SHOULD_NEVER_LEAK"

  json="$(resolve_leader_v2 "$SECRET_PROFILE" "$PIN_ENV")"  || true
  assert_not_contains "resolve-leader出力にもピン実値(ARN)が現れない" "$json" "supersecret-arn"
  assert_not_contains "resolve-leader出力にもAWSキーが現れない" "$json" "AKIA_SHOULD_NEVER_LEAK"
  assert_contains "resolve-leaderはmodelとして別名(opus)だけを返す" "$json" '"model": "opus"'
}
echo "=== 失敗時もピン実値と認証情報を漏らさない ==="
{
  PIN_ENV2="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV2" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn-2
AWS_SECRET_ACCESS_KEY=SHOULD_NEVER_LEAK_2
EOF
  # Codex二次レビュー指摘・Major対応: --model opusはピン(ANTHROPIC_DEFAULT_
  # OPUS_MODEL)が満たされているためcheck-candidateはOK(成功)を返し、失敗経路の
  # 秘匿を検査したことにならなかった。ピンが無いhaikuを使いFAIL経路を通す。
  cc_out="$(python3 "$PROFILE_LIB" check-candidate --provider bedrock --model haiku \
    --role-name leader --for-leader --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1)"  || true
  assert_contains "check-candidateが実際にFAILを返している（テストの前提確認）" "$cc_out" "FAIL"
  assert_not_contains "check-candidate出力にピン実値が現れない" "$cc_out" "supersecret-arn-2"
  assert_not_contains "check-candidate出力にAWSキーが現れない" "$cc_out" "SHOULD_NEVER_LEAK_2"

  LEADER_FAIL_ENV="$(mktemp -d)/leaderfailenv.md"
  make_v2_profile "$LEADER_FAIL_ENV" "role.leader: configured model=bedrock-sonnet"
  leader_err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_FAIL_ENV" --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_not_contains "resolve-leaderのstderrにもピン実値が現れない" "$leader_err" "supersecret-arn-2"
  assert_not_contains "resolve-leaderのstderrにもAWSキーが現れない" "$leader_err" "SHOULD_NEVER_LEAK_2"
}
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
