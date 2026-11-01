#!/bin/bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
GUARD="$REPO_ROOT/team/connect/claude-code/agent-model-guard.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-model-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
RUN_RC=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

MARKER_DIR="$WORK/markers"
mkdir -p "$MARKER_DIR"

run_guard() {
  # 締めレビュー1巡目 #1対応: ホスト環境に偶然 CLAUDE_CODE_SUBAGENT_MODEL_FORCE /
  # CLAUDE_CODE_SUBAGENT_MODEL が残っていると、新設したEF検査以外の既存ケース
  # まで巻き込まれて不安定化するため、ベースライン実行では両方を明示的に外す。
  input=$1
  out_file=$2
  err_file=$3
  RUN_RC=0
  printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" /bin/bash "$GUARD" >"$out_file" 2>"$err_file" || RUN_RC=$?
}

run_guard_env() {
  # EF-01/02専用: 対象の環境変数だけを1件指定してguardを実行する（他方は
  # ホスト環境からの漏れを防ぐため明示的に外す）。
  input=$1
  out_file=$2
  err_file=$3
  var_assign=$4
  RUN_RC=0
  printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" "$var_assign" /bin/bash "$GUARD" >"$out_file" 2>"$err_file" || RUN_RC=$?
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

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data['hookSpecificOutput']['hookEventName'] == 'PreToolUse'
assert data['hookSpecificOutput']['permissionDecision'] == 'deny'
assert data['hookSpecificOutput']['permissionDecisionReason'].split(':')[0] == sys.argv[2].split(':')[0]
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

run_guard "$base,"'"model":"claude-opus-5-5"}}' "$WORK/gd04.out" "$WORK/gd04.err"
assert_deny_case "GD-04 具体IDをexit 0の完全なdeny JSONで拒否" "$WORK/gd04.out" "$WORK/gd04.err" 'MODEL_ARGUMENT_INVALID: Agent.model は resolve-candidate が返した4別名のいずれかを明示してください。'

run_guard '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}' "$WORK/gd05.out" "$WORK/gd05.err"
assert_pass_case "GD-05 対象外職種はexit 0・stdout/stderr空" "$WORK/gd05.out" "$WORK/gd05.err"

echo "=== EF-01〜02: CLAUDE_CODE_SUBAGENT_MODEL_FORCE 環境変数の検査（締めレビュー1巡目 #1対応） ==="
run_guard_env "$base,"'"model":"opus"}}' "$WORK/ef01.out" "$WORK/ef01.err" "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1"
assert_deny_case "EF-01 FORCE=1設定時はmodel指定済みでもexit 0の完全なdeny JSONで拒否" "$WORK/ef01.out" "$WORK/ef01.err" 'MODEL_ENV_OVERRIDE_FORBIDDEN: 環境変数 CLAUDE_CODE_SUBAGENT_MODEL_FORCE が設定されています。Agent.model の指定を上書きする可能性があるため、解除してから再実行してください。'

echo "=== HF-01〜04: 入力契約・依存障害は固定ERROR deny ==="
check_error() {
  label=$1 input=$2 cause=$3
  run_guard "$input" "$WORK/hf.out" "$WORK/hf.err"
  expected="MODEL_GUARD_ERROR: cause=$cause; model 指定を検査できません。フックの入力と配置を確認してください。"
  assert_deny_case "$label はexit 0の完全なdeny JSON" "$WORK/hf.out" "$WORK/hf.err" "$expected"
}
check_error HF-01a '{' JQ_FAILED
echo "=== D2-G1〜G3: 委任実績マーカー（設計v1.2 §3.1〜§3.2・OQ-4案B・（ガード側）テスト戦略） ==="
marker_base='{"session_id":"sess-marker-test","tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","description":"model guard marker smoke","prompt":"Reply GD-ID only; do not use tools.","name":"opus-requirements-analyst"'
MARKER_FILE="$MARKER_DIR/claude-delegated-ok-sess-marker-test"

rm -f "$MARKER_FILE"
run_guard "$marker_base,"'"model":"opus"}}' "$WORK/d2g1.out" "$WORK/d2g1.err"
if [ "$RUN_RC" -eq 0 ] && [ -f "$MARKER_FILE" ]; then
  pass "D2-G1 PASS分岐でセッション固有マーカーが作られる"
else
  fail_case "D2-G1 PASS分岐でセッション固有マーカーが作られる"
fi

rm -f "$MARKER_FILE"
run_guard "$marker_base}}" "$WORK/d2g2.out" "$WORK/d2g2.err"
if [ ! -f "$MARKER_FILE" ]; then
  pass "D2-G2 deny(REQUIRED)分岐ではマーカーが作られない"
else
  fail_case "D2-G2 deny(REQUIRED)分岐ではマーカーが作られない"
fi

echo "=== I2-m5(検証2巡目): source失敗時のfail-close分岐そのものに恒久テストを足す（lib/を持たない実体ディレクトリへフックをコピーして起動） ==="
{
  # I2-M2でenv上書き口（GUARD_COMMON_LIB）を撤去したため、source失敗を
  # 再現する手段は「lib/を持たない場所へフック本体だけをコピーして実行する」
  # 方式に一本化する（symlinkだと自身の実体を辿ってlib/を見つけてしまい
  # source失敗を再現できない＝コピーでなければならない）。

  # agent-model-guard.sh: lib/無しでコピー起動するとdeny(GUARD_COMMON_UNREADABLE)・exit 0（素通しにならない）
  NOLIB_DIR="$WORK/nolib-agent-model-guard"
  mkdir -p "$NOLIB_DIR"
  cp "$GUARD" "$NOLIB_DIR/agent-model-guard.sh"
  RUN_RC=0
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","model":"opus"}}' \
    | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" /bin/bash "$NOLIB_DIR/agent-model-guard.sh" \
    >"$WORK/nolib-guard.out" 2>"$WORK/nolib-guard.err" || RUN_RC=$?
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/nolib-guard.err" ] \
     && grep -q '"permissionDecision":"deny"' "$WORK/nolib-guard.out" \
     && grep -q 'GUARD_COMMON_UNREADABLE' "$WORK/nolib-guard.out"; then
    pass "I2-m5: agent-model-guard.shはlib/が無いとfail-close（deny・GUARD_COMMON_UNREADABLE・exit 0）で素通ししない"
  else
    fail_case "I2-m5: agent-model-guard.shのfail-closeが働かない (rc=$RUN_RC out=[$(cat "$WORK/nolib-guard.out" 2>/dev/null)] err=[$(cat "$WORK/nolib-guard.err" 2>/dev/null)])"
  fi

}

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
