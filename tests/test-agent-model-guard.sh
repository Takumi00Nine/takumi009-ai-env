#!/bin/bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
GUARD="$REPO_ROOT/claude/hooks/agent-model-guard.sh"
SETTINGS="$REPO_ROOT/claude/settings.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-model-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
RUN_RC=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

run_guard() {
  # 締めレビュー1巡目 #1対応: ホスト環境に偶然 CLAUDE_CODE_SUBAGENT_MODEL_FORCE /
  # CLAUDE_CODE_SUBAGENT_MODEL が残っていると、新設したEF検査以外の既存ケース
  # まで巻き込まれて不安定化するため、ベースライン実行では両方を明示的に外す。
  input=$1
  out_file=$2
  err_file=$3
  RUN_RC=0
  printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL /bin/bash "$GUARD" >"$out_file" 2>"$err_file" || RUN_RC=$?
}

run_guard_env() {
  # EF-01/02専用: 対象の環境変数だけを1件指定してguardを実行する（他方は
  # ホスト環境からの漏れを防ぐため明示的に外す）。
  input=$1
  out_file=$2
  err_file=$3
  var_assign=$4
  RUN_RC=0
  printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL "$var_assign" /bin/bash "$GUARD" >"$out_file" 2>"$err_file" || RUN_RC=$?
}

assert_pass_case() {
  label=$1
  out_file=$2
  err_file=$3
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$out_file" ] && [ ! -s "$err_file" ]; then
    pass "$label"
  else
    fail_case "$label"
  fi
}

assert_deny_case() {
  label=$1
  out_file=$2
  err_file=$3
  expected_reason=$4
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$err_file" ] && python3 - "$out_file" "$expected_reason" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
assert raw.endswith(b"\n") and raw.count(b"\n") == 1
assert json.loads(raw) == {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": sys.argv[2],
    }
}
PY
  then
    pass "$label"
  else
    fail_case "$label"
  fi
}

base='{"tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","description":"model guard smoke","prompt":"Reply GD-ID only; do not use tools.","name":"opus-requirements-analyst"'

echo "=== GD-01〜05: Agent入力の通過・拒否 ==="
run_guard "$base,"'"model":"opus"}}' "$WORK/gd01.out" "$WORK/gd01.err"
assert_pass_case "GD-01 model=opusはexit 0・stdout/stderr空" "$WORK/gd01.out" "$WORK/gd01.err"

run_guard "$base}}" "$WORK/gd02.out" "$WORK/gd02.err"
assert_deny_case "GD-02 欠落をexit 0の完全なdeny JSONで拒否" "$WORK/gd02.out" "$WORK/gd02.err" 'MODEL_ARGUMENT_REQUIRED: resolve-candidate の AGENT_MODEL を Agent.model に明示してください。'

run_guard "$base,"'"model":""}}' "$WORK/gd03.out" "$WORK/gd03.err"
assert_deny_case "GD-03 空文字をexit 0の完全なdeny JSONで拒否" "$WORK/gd03.out" "$WORK/gd03.err" 'MODEL_ARGUMENT_INVALID: Agent.model は resolve-candidate が返した4別名のいずれかを明示してください。'

run_guard "$base,"'"model":"claude-opus-5"}}' "$WORK/gd04.out" "$WORK/gd04.err"
assert_deny_case "GD-04 具体IDをexit 0の完全なdeny JSONで拒否" "$WORK/gd04.out" "$WORK/gd04.err" 'MODEL_ARGUMENT_INVALID: Agent.model は resolve-candidate が返した4別名のいずれかを明示してください。'

run_guard '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}' "$WORK/gd05.out" "$WORK/gd05.err"
assert_pass_case "GD-05 対象外職種はexit 0・stdout/stderr空" "$WORK/gd05.out" "$WORK/gd05.err"

echo "=== GD-06: settings matcherはBashをdispatchしない ==="
python3 - "$SETTINGS" <<'PY' && pass "GD-06 ^Agent$ matcherはBashに不一致" || fail_case "GD-06 ^Agent$ matcherはBashに不一致"
import json,re,sys
d=json.load(open(sys.argv[1]))
entries=[e for e in d['hooks']['PreToolUse'] if any(h.get('command','').endswith('/agent-model-guard.sh') for h in e['hooks'])]
assert len(entries)==1 and entries[0]['matcher']=='^Agent$'
assert re.search(entries[0]['matcher'],'Bash') is None
PY

echo "=== 対象8職種・許容4別名の設定一致 ==="
for role in adoption-critic implementer operator requirements-analyst researcher system-designer vault-scribe verifier; do
  run_guard "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$role\",\"model\":\"opus\"}}" "$WORK/role.out" "$WORK/role.err"
  assert_pass_case "$role がexit 0・無出力で正常値を通過" "$WORK/role.out" "$WORK/role.err"
done
for alias in fable opus sonnet haiku; do
  run_guard "$base,\"model\":\"$alias\"}}" "$WORK/alias.out" "$WORK/alias.err"
  assert_pass_case "$alias がexit 0・無出力で通過" "$WORK/alias.out" "$WORK/alias.err"
done

echo "=== EF-01〜02: CLAUDE_CODE_SUBAGENT_MODEL_FORCE 環境変数の検査（締めレビュー1巡目 #1対応） ==="
run_guard_env "$base,"'"model":"opus"}}' "$WORK/ef01.out" "$WORK/ef01.err" "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1"
assert_deny_case "EF-01 FORCE=1設定時はmodel指定済みでもexit 0の完全なdeny JSONで拒否" "$WORK/ef01.out" "$WORK/ef01.err" 'MODEL_ENV_OVERRIDE_FORBIDDEN: 環境変数 CLAUDE_CODE_SUBAGENT_MODEL_FORCE が設定されています。Agent.model の指定を上書きする可能性があるため、解除してから再実行してください。'

run_guard_env "$base,"'"model":"opus"}}' "$WORK/ef02.out" "$WORK/ef02.err" "CLAUDE_CODE_SUBAGENT_MODEL=haiku"
assert_pass_case "EF-02 CLAUDE_CODE_SUBAGENT_MODEL（非FORCE）のみ設定時はexit 0・無出力で従来どおり通過" "$WORK/ef02.out" "$WORK/ef02.err"

echo "=== HF-01〜04: 入力契約・依存障害は固定ERROR deny ==="
check_error() {
  label=$1 input=$2 cause=$3
  run_guard "$input" "$WORK/hf.out" "$WORK/hf.err"
  expected="MODEL_GUARD_ERROR: cause=$cause; model 指定を検査できません。フックの入力と配置を確認してください。"
  assert_deny_case "$label はexit 0の完全なdeny JSON" "$WORK/hf.out" "$WORK/hf.err" "$expected"
}
check_error HF-01a '{' JQ_FAILED
check_error HF-01b '{"tool_input":{}}' TOOL_NAME_MISSING
check_error HF-01c '{"tool_name":null,"tool_input":{}}' TOOL_NAME_NULL
check_error HF-01d '{"tool_name":"","tool_input":{}}' TOOL_NAME_EMPTY
check_error HF-01e '{"tool_name":1,"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01f '{"tool_name":true,"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01g '{"tool_name":[],"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01h '{"tool_name":{},"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01i '{"tool_name":"Task","tool_input":{}}' TOOL_NAME_UNEXPECTED
check_error HF-01j '{"tool_name":"Bash","tool_input":{"command":"true"}}' TOOL_NAME_UNEXPECTED
check_error HF-02 '' INPUT_INVALID

RUN_RC=0
PATH="$WORK/no-jq" /bin/bash "$GUARD" <<<'{}' >"$WORK/hf03.out" 2>"$WORK/hf03.err" || RUN_RC=$?
assert_deny_case "HF-03 jq不在はexit 0の完全なdeny JSON" "$WORK/hf03.out" "$WORK/hf03.err" 'MODEL_GUARD_ERROR: cause=JQ_UNAVAILABLE; model 指定を検査できません。フックの入力と配置を確認してください。'

mkdir "$WORK/stub"
printf '#!/bin/bash\nexit 1\n' > "$WORK/stub/jq"
chmod +x "$WORK/stub/jq"
RUN_RC=0
printf '{}' | PATH="$WORK/stub:/bin:/usr/bin" /bin/bash "$GUARD" >"$WORK/hf04.out" 2>"$WORK/hf04.err" || RUN_RC=$?
assert_deny_case "HF-04 jq非0はexit 0の完全なdeny JSON" "$WORK/hf04.out" "$WORK/hf04.err" 'MODEL_GUARD_ERROR: cause=JQ_FAILED; model 指定を検査できません。フックの入力と配置を確認してください。'

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
