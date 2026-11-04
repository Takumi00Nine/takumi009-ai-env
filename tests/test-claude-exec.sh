#!/usr/bin/env bash
# team/connect/claude-code/claude-exec.sh のユニットテスト（設計 docs/design-v1.1.1.md §9.1・
# 実装A担当ケース）。
#
# 実 claude コマンドには依存しない。tests/fake-claude/claude（偽シム）を
# CLAUDE_CODE_WRAPPER_BIN で差し替えて使う。実 $HOME・実 launchd・実 git は
# 触らない（HOMEを一時ディレクトリへ差し替え、AIENV_*でfixtureを指す）。
#
# 実行方法: bash tests/test-claude-exec.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/team/connect/claude-code/claude-exec.sh"
STUB_SRC="$TESTS_DIR/fake-claude/claude"
DELEGATION_GATE_SH="$REPO_ROOT/team/connect/claude-code/delegation-gate-v2.sh"
REAL_AGENTS_DIR="$REPO_ROOT/team/rules/agents"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }

fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}

# 新しいfixture一式を作る（$WORK配下）。呼ぶたびにグローバル変数を上書きする。
ALL_WORK_DIRS=()
cleanup_all_work_dirs() {
  local d
  for d in ${ALL_WORK_DIRS[@]+"${ALL_WORK_DIRS[@]}"}; do
    chmod -R u+w "$d" 2>/dev/null
    rm -rf "$d" 2>/dev/null
  done
}
trap cleanup_all_work_dirs EXIT

new_fixture() {
  WORK="$(mktemp -d)"
  ALL_WORK_DIRS+=("$WORK")
  BINDIR="$WORK/bin"
  mkdir -p "$BINDIR"
  cp "$STUB_SRC" "$BINDIR/claude"
  chmod +x "$BINDIR/claude"

  PROFILE="$WORK/profile.md"
  cat > "$PROFILE" <<'EOF'
---
schema_version: 8
profile_slug: fixture
team_mode:        configured value=team
no_read_paths:    unavailable
machine_role:     configured value=main
role.implementer: configured model=t-sonnet-high
role.operator: configured model=sonnet-noeffort
role.researcher:  not_adopted
---
EOF

  MODELS_CONF="$WORK/models.conf"
  cat > "$MODELS_CONF" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
effort=high

[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5-5

EOF

  mkdir -p "$WORK/home"
  mkdir -p "$WORK/preferences"
  printf '%s\n' '## 権限' '担当範囲へ書込可' > "$WORK/preferences/worker-role-implementer.md"
  SETTINGS_SRC="$WORK/settings-src.json"
  cat > "$SETTINGS_SRC" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[
        {"type":"command","command":"echo public-guard"},
        {"type":"command","command":"\$HOME/.claude/hooks/bash-danger-gate.sh"}
      ]},
      {"matcher":"Edit|Write|NotebookEdit","hooks":[{"type":"command","command":"\$HOME/.claude/hooks/delegation-gate-v2.sh"}]},
      {"matcher":"^Agent\$","hooks":[{"type":"command","command":"\$HOME/.claude/hooks/inprocess-gate.sh"}]}
    ],
    "SessionStart":[{"hooks":[{"type":"command","command":"echo should-not-appear"}]}],
    "UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo should-not-appear-either"}]}]
  }
}
EOF

  PROMPT="$WORK/prompt.txt"
  echo "absolute-rules を読んでから hello（テスト用依頼文）" > "$PROMPT"

  AGENTS_DIR="$REAL_AGENTS_DIR"
  MARKER_DIR="$WORK/markers"
  mkdir -p "$MARKER_DIR"
  STUBLOG="$WORK/stub.jsonl"
  LOG="$WORK/claude-exec.jsonl"

  export HOME="$WORK/home"
  export AIENV_LOCAL_PROFILE_PATH="$PROFILE"
  export AIENV_MODEL_DEFS_FILE="$MODELS_CONF"
  export AIENV_AGENT_SOURCE_DIR="$AGENTS_DIR"
  export AIENV_PREFERENCES_DIR="$WORK/preferences"
  export AIENV_CHILD_SETTINGS_SRC="$SETTINGS_SRC"
  export AIENV_CLAUDE_EXEC_LOG="$LOG"
  export GATE_MARKER_DIR="$MARKER_DIR"
  export CLAUDE_CODE_WRAPPER_BIN="$BINDIR/claude"
  export AIENV_CLAUDE_STUB_LOG="$STUBLOG"
  unset AIENV_CLAUDE_EXEC_TIMEOUT_SECS AIENV_CLAUDE_STUB_SLEEP_SECS \
        AIENV_CLAUDE_STUB_RESPONSE_FILE AIENV_CLAUDE_STUB_EXIT_CODE \
        AIENV_CLAUDE_STUB_STDERR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}

# ラッパーを起動する（実HOMEを読まないようPATHは触らない・stdinは/dev/null）。
# 結果はグローバル RUN_STDOUT / RUN_STDERR / RC。
run_wrapper() {
  RUN_STDOUT="$(bash "$SCRIPT" "$@" < /dev/null 2>"$WORK/last-stderr.log")"
  RC=$?
  RUN_STDERR="$(cat "$WORK/last-stderr.log" 2>/dev/null || true)"
}
stub_lines() { [ -f "$STUBLOG" ] && wc -l < "$STUBLOG" | tr -d ' ' || echo 0; }

stub_arg_after() {
  python3 -c '
import json, sys
path, flag = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
argv = lines[-1]["argv"]
try:
    print(argv[argv.index(flag) + 1])
except (ValueError, IndexError):
    print("")
' "$STUBLOG" "$1"
}

stub_argv_has() {
  python3 -c '
import json, sys
path, needle = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
print("1" if needle in lines[-1]["argv"] else "0")
' "$STUBLOG" "$1"
}

stub_settings_json() {
  python3 -c '
import json, sys
path = sys.argv[1]
lines = [json.loads(l) for l in open(path) if l.strip()]
argv = lines[-1]["argv"]
print(argv[argv.index("--settings") + 1])
' "$STUBLOG"
}

is_gate_denied() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("0"); sys.exit()
try:
    d = json.loads(raw)
    print("1" if d.get("hookSpecificOutput", {}).get("permissionDecision") == "deny" else "0")
except Exception:
    print("0")
'
}

log_field() {
  # $1=フィールド名。最後のログ行の値を返す（null は文字列"null"）。
  python3 -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
v = lines[-1].get(key, "__MISSING__")
print("null" if v is None else v)
' "$LOG" "$1"
}

echo "=== AC-2b: resume_passes_model_and_effort_again ==="
{
  new_fixture
  OUT2B_1="$WORK/o2b-1.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT2B_1" --task-id t-ac2b-1 --model-def t-sonnet-high
  MODEL_1="$(stub_arg_after --model)"
  EFFORT_1="$(stub_arg_after --effort)"

  OUT2B_2="$WORK/o2b-2.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT2B_2" --task-id t-ac2b-2 --model-def t-sonnet-high --resume resume-sid-test
  assert_true "resumeのmodel/effortを再送する" \
    "$([ "$RC" -eq 0 ] && [ "$(stub_arg_after --resume)" = resume-sid-test ] \
       && [ "$(stub_arg_after --model)" = "$MODEL_1" ] \
       && [ "$(stub_arg_after --effort)" = "$EFFORT_1" ] && echo 1 || echo 0)"
}

echo "=== AC-4: argv_has_p_agent_json_and_no_bare ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac4 --model-def t-sonnet-high
  assert_true "職種・JSON出力・モデルとeffortを渡す" \
    "$([ "$RC" -eq 0 ] && [ "$(stub_arg_after --agent)" = implementer ] \
       && [ "$(stub_arg_after --output-format)" = json ] \
       && [ -n "$(stub_arg_after --model)" ] && [ -n "$(stub_arg_after --effort)" ] \
       && [ "$(stub_argv_has -p)" = 1 ] && echo 1 || echo 0)"
  agents_json="$(stub_arg_after --agents)"
  assert_true "職種の参照本文とtoolsが起動JSONへ渡る" \
    "$(python3 -c '
import json,sys
from pathlib import Path
agent=json.loads(sys.argv[1])["implementer"]
body=Path(sys.argv[2]).read_text().split("---",2)[-1].strip()
assert agent["prompt"].strip() == body
assert "worker-role-implementer.md" in agent["prompt"]
assert "Read" in agent["tools"]
' "$agents_json" "$REAL_AGENTS_DIR/implementer.md" && echo 1 || echo 0)"

}

echo "=== AC-8: 子環境の組み立て ==="
{
  # ① child_env_only_fixed_key / setting_sources_excludes_user_and_project /
  #    child_cwd_has_no_local_settings
  new_fixture
  export ANTHROPIC_API_KEY="dummy-secret-1"
  export AWS_ACCESS_KEY_ID="dummy-secret-2"
  export CLAUDE_CODE_SOME_DUMMY="dummy-secret-3"
  RAND_SUFFIX="$$_$RANDOM"
  export "ANTHROPIC_FAKE_$RAND_SUFFIX=fake1"
  export "AWS_FAKE_$RAND_SUFFIX=fake2"
  export "CLAUDE_CODE_FAKE_$RAND_SUFFIX=fake3"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8a --model-def t-sonnet-high
  n_prefixed="$(python3 -c '
import json
lines=[json.loads(l) for l in open("'"$STUBLOG"'") if l.strip()]
keys=lines[-1]["env_keys"]
n=sum(1 for k in keys if k.startswith("ANTHROPIC_") or k.startswith("AWS_") or k.startswith("CLAUDE_CODE_"))
print(n)
')"
  assert_eq "child_env_only_fixed_key: 3プレフィックス該当キーは固定1つだけ" "1" "$n_prefixed"
  ss_val="$(stub_arg_after --setting-sources)"
  assert_eq "setting_sources_excludes_user_and_project: local のみ" "local" "$ss_val"
  assert_true "child_cwd_has_no_local_settings: 子cwdにsettings.local.jsonが無い" \
    "$([ ! -e "$WORK/.claude/settings.local.json" ] && echo 1 || echo 0)"
  unset ANTHROPIC_API_KEY AWS_ACCESS_KEY_ID CLAUDE_CODE_SOME_DUMMY
  unset "ANTHROPIC_FAKE_$RAND_SUFFIX" "AWS_FAKE_$RAND_SUFFIX" "CLAUDE_CODE_FAKE_$RAND_SUFFIX"
  # ⑤(i)(ii)(iii) settings_has_hooks_without_sessionstart /
  # child_settings_pretooluse_nonempty_and_excludes_leader_hooks
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8e1 --model-def t-sonnet-high
  settings1="$(stub_settings_json)"
  py_check="$(python3 -c '
import json, sys
s = json.loads(sys.argv[1])
pre = s.get("hooks", {}).get("PreToolUse", [])
nonempty = len(pre) > 0
excludes_leader = not any(
    "delegation-gate-v2.sh" in h.get("command","")
    for e in pre for h in e.get("hooks", [])
)
print("1" if (nonempty and excludes_leader) else "0")
' "$settings1")"
  assert_true "child_settings_pretooluse_nonempty_and_excludes_leader_hooks" "$py_check"

  # reject_when_source_settings_unreadable_or_empty(8)
  new_fixture
  export AIENV_CHILD_SETTINGS_SRC="$WORK/does-not-exist.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8f1 --model-def t-sonnet-high
  assert_true "子設定を読めなければ起動を止める" \
    "$([ "$RC" -eq 8 ] && [ "$(stub_lines)" = 0 ] && echo 1 || echo 0)"

  assert_contains "子設定のlayer1に危険コマンド柵が残る" "$settings1" "bash-danger-gate.sh"
  assert_true "子設定にVault書込柵を付与しない" "$([[ "$settings1" != *vault-write-gate.sh* ]] && echo 1 || echo 0)"

}

echo "=== AC-9: marker_uses_parent_sid / child_sid_marker_does_not_pass / vault_passes ==="
{
  new_fixture
  export CLAUDE_CODE_SESSION_ID="parent-sid-ac9"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac9 --model-def t-sonnet-high
  NONALLOW_PATH="$WORK/some-project/file.txt"
  mkdir -p "$(dirname "$NONALLOW_PATH")"

  gate_input_pass="$(python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "parent-sid-ac9" "$NONALLOW_PATH")"
  gate_out="$(printf '%s' "$gate_input_pass" | GATE_MARKER_DIR="$MARKER_DIR" bash "$DELEGATION_GATE_SH")"
  assert_true "marker_uses_parent_sid: rule 4mで通過（deny無し）" "$([ -z "$gate_out" ] && echo 1 || echo 0)"

  gate_input_childsid="$(python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "some-other-sid" "$NONALLOW_PATH")"
  gate_out2="$(printf '%s' "$gate_input_childsid" | GATE_MARKER_DIR="$MARKER_DIR" bash "$DELEGATION_GATE_SH")"
  assert_true "child_sid_marker_does_not_pass: 別sidではdeny" "$(is_gate_denied "$gate_out2")"
}

echo "=== AC-12: timeout_classifies_and_logs(12) ==="
{
  new_fixture
  export AIENV_CLAUDE_EXEC_TIMEOUT_SECS=1
  export AIENV_CLAUDE_STUB_SLEEP_SECS=6
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac12 --model-def t-sonnet-high
  assert_true "timeoutを失敗として記録" \
    "$([ "$RC" -eq 12 ] && [ "$(log_field reason_code)" = timeout ] && echo 1 || echo 0)"
  unset AIENV_CLAUDE_EXEC_TIMEOUT_SECS AIENV_CLAUDE_STUB_SLEEP_SECS
}

echo "=== AC-15: no_secret_in_five_outputs / no_prompt_body_in_log_or_dryrun ==="
{
  new_fixture
  SECRET="sk-dummy-secret-XYZ789"
  export ANTHROPIC_API_KEY="$SECRET"
  UNIQUE_PROMPT_MARKER="PROMPT_BODY_UNIQUE_MARKER_QAZXSW"
  echo "absolute-rules を読んでから hello ${UNIQUE_PROMPT_MARKER}" > "$PROMPT"

  OUT15="$WORK/o15.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT15" --task-id t-ac15 --model-def t-sonnet-high
  n1="$(grep -c "$SECRET" "$LOG" 2>/dev/null || true)"; n1="${n1:-0}"
  n2="$(printf '%s' "$RUN_STDOUT" | grep -c "$SECRET" || true)"; n2="${n2:-0}"
  n3="$(printf '%s' "$RUN_STDERR" | grep -c "$SECRET" || true)"; n3="${n3:-0}"
  n4="$(grep -c "$SECRET" "$OUT15" 2>/dev/null || true)"; n4="${n4:-0}"

  DRYOUT="$WORK/dry.json"
  stub_count_before_dry="$(stub_lines)"
  DRYSTDOUT="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$DRYOUT" --task-id t-ac15-dry --model-def t-sonnet-high --dry-run < /dev/null 2>"$WORK/dry-stderr.log")"
  assert_true "dry-runは子を起動せず成果物を作らない" \
    "$([ "$(stub_lines)" = "$stub_count_before_dry" ] && [ ! -e "$DRYOUT" ] && echo 1 || echo 0)"
  n5="$(printf '%s' "$DRYSTDOUT" | grep -c "$SECRET" || true)"; n5="${n5:-0}"

  m1="$(grep -c "$UNIQUE_PROMPT_MARKER" "$LOG" 2>/dev/null || true)"; m1="${m1:-0}"
  m2="$(printf '%s' "$DRYSTDOUT" | grep -c "$UNIQUE_PROMPT_MARKER" || true)"; m2="${m2:-0}"
  assert_true "秘密を全出力へ漏らさず、依頼本文をログへ残さない" \
    "$([ "$RC" -eq 0 ] && [ -f "$OUT15" ] && [ "$n1$n2$n3$n4$n5$m1$m2" = 0000000 ] && echo 1 || echo 0)"
  unset ANTHROPIC_API_KEY
}

echo "=== AC-19: permission_denials_not_success(13) ==="
{
  new_fixture
  RESP="$WORK/resp-denial.json"
  cat > "$RESP" <<'EOF'
{"is_error":false,"subtype":"success","session_id":"sid-denial","result":"Write was denied by policy","permission_denials":[{"tool_name":"Write","tool_use_id":"x","tool_input":{}}]}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$RESP"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac19 --model-def t-sonnet-high
  assert_eq "permission_denials非空でも成功扱いしない: exit13" "13" "$RC"
  unset AIENV_CLAUDE_STUB_RESPONSE_FILE
}

echo "=== 失敗分類: 認証・上限・その他 ==="
{
  new_fixture
  R1="$WORK/r1.json"; cat > "$R1" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":401,"terminal_reason":"api_error","result":"Failed to authenticate. API Error: 401 API key is invalid.","num_turns":1,"total_cost_usd":0}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R1"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o1.json" --task-id t-b1 --model-def t-sonnet-high
  assert_eq "classify_auth_http: exit11" "11" "$RC"

  R3="$WORK/r3.json"; cat > "$R3" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":429,"terminal_reason":"api_error","result":"API Error: Request rejected (429) · upstream limit"}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R3"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o3.json" --task-id t-b3 --model-def t-sonnet-high
  assert_eq "classify_limit: exit10" "10" "$RC"

  R4="$WORK/r4.json"; cat > "$R4" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":529,"terminal_reason":"api_error","result":"API Error: Repeated 529 Overloaded errors"}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R4"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o4.json" --task-id t-b4 --model-def t-sonnet-high
  assert_eq "classify_other_529: exit14" "14" "$RC"
  unset AIENV_CLAUDE_STUB_RESPONSE_FILE AIENV_CLAUDE_STUB_STDERR
}
echo "=== 職種ノートが無ければ起動しない ==="
{
  new_fixture
  export AIENV_PREFERENCES_DIR="$WORK/missing-preferences"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-nonote --model-def t-sonnet-high
  assert_true "職種ノート欠落で子を起動せず前提不備を記録する" \
    "$([ "$RC" -eq 8 ] && [ "$(stub_lines)" = 0 ] && [ "$(log_field reason_code)" = role_note_unavailable ] && echo 1 || echo 0)"
}
echo "=== absolute-rules 参照なしでも起動する ==="
{
  new_fixture
  BADPROMPT="$WORK/no-ref.txt"
  echo "こんにちは、何かして" > "$BADPROMPT"
  run_wrapper --role implementer --prompt-file "$BADPROMPT" --out "$WORK/o.json" --task-id t-noref --model-def t-sonnet-high
  assert_true "absolute-rulesの参照なしでも起動する" \
    "$([ "$RC" -eq 0 ] && [ "$(stub_lines)" = 1 ] && echo 1 || echo 0)"
}
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
