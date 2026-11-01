#!/bin/bash
# tests/test-inprocess-gate.sh — ラッパー起動-設計-v1.1.1.md §4（D-3）・
# 要件v1.4.3 §4.3（FR-21・FR-22）・§5（AC-14・AC-18）を検証する。
#
# 対象: team/executor/profile_resolve.py の `check-inprocess` サブコマンド
# （AC-18＝口の契約）と team/connect/claude-code/inprocess-gate.sh（AC-14＝境界フック）。
# 実 $HOME・実 launchd は使わない（fixture 一式は一時ディレクトリに作る）。
#
# 実行方法: bash tests/test-inprocess-gate.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/team/executor/profile_resolve.py"
GATE="$REPO_ROOT/team/connect/claude-code/inprocess-gate.sh"

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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-inprocess-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export GATE_MARKER_DIR="$WORK"

# ============================================================
# fixture: 配役表 + モデル定義（4状態＋在り/無しの両方をカバーする）
# ============================================================
BASE="$WORK/base"
mkdir -p "$BASE"
cat > "$BASE/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: fixture
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.implementer: configured model=sonnet-noeffort,codex-high
---
EOF
cat > "$BASE/models.conf" <<'EOF'
[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5-5

[codex-high]
provider=external
execution=external-cli
model=default
effort=high
EOF
export AIENV_MODEL_DEFS_FILE="$BASE/models.conf"

CI() { # CI <profile> <subagent-type> — check-inprocess
  python3 "$LIB" check-inprocess "$1" --subagent-type "$2"
}

permission_decision_of() { # permission_decision_of <hook-json> — deny()の出力（jq -n。
  # 改行・空白の有無に依存しない取り出し。値が無ければ空文字）
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}

echo "=== AC-18①: port_json_contract（6フィールド・型・exit0） ==="
{
  out="$(CI "$BASE/profile.md" general-purpose)"; rc=$?
  assert_eq "port_json_contract: exit0" "0" "$rc"
  atype="$(printf '%s' "$out" | python3 -c 'import json,sys; print(type(json.load(sys.stdin)["allowed"]).__name__)')"
  assert_eq "port_json_contract: allowedはbool" "bool" "$atype"
}

echo "=== AC-18④: port_unreadable_profile_nulls（symlink・fail-close） ==="
{
  ln -s "$BASE/profile.md" "$WORK/profile-link.md"
  out="$(CI "$WORK/profile-link.md" general-purpose)"; rc=$?
  assert_eq "port_unreadable_profile_nulls: exit0（JSONは出す）" "0" "$rc"
  assert_eq "読めない配役表は拒否" "false" "$(printf '%s' "$out" | jq -r .allowed)"
}

echo "=== AC-14①: allow_not_in_cast_table（陽性・監査1行） ==="
{
  AUDIT="$WORK/audit-allow.jsonl"
  out_file="$WORK/allow.out"
  err_file="$WORK/allow.err"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"},"session_id":"allow-session"}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT" \
        /bin/bash "$GATE" >"$out_file" 2>"$err_file"
  rc=$?
  assert_eq "allow_not_in_cast_table: stdout空（干渉しない）" "" "$(cat "$out_file")"
  assert_eq "通過したAgentに委任マーカーを付与" "yes" "$([ -f "$WORK/claude-delegated-ok-allow-session" ] && echo yes)"
}

echo "=== AC-14②: deny_four_states（陰性4通り・各1行の監査） ==="
{
  for pair in "implementer:configured"; do
    role="${pair%%:*}"
    AUDIT="$WORK/audit-deny-$role.jsonl"
    out_file="$WORK/deny-$role.out"
    printf '%s' "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$role\"},\"session_id\":\"denied-session\"}" \
      | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
          AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT" \
          /bin/bash "$GATE" >"$out_file" 2>/dev/null
    rc=$?
    assert_eq "deny_four_states($role): permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_file")")"
    assert_eq "in-process拒否の正本参照" "true" "$(jq '.hookSpecificOutput.permissionDecisionReason | contains("~/Data/obsidian/Preferences/worker-role-prompts.md")' "$out_file")"
  done
  assert_eq "拒否したAgentには委任マーカーを付けない" "no" "$([ -f "$WORK/claude-delegated-ok-denied-session" ] && echo yes || echo no)"
}
echo "=== AC-14③: fail_close_on_port_failure（口が非0／不正JSON→ともにdenied・fail-close） ==="
{
  cat > "$WORK/stub-python-nonzero.sh" <<'EOF'
#!/bin/bash
exit 7
EOF
  chmod +x "$WORK"/stub-python-*.sh

  AUDIT_A="$WORK/audit-fc-nonzero.jsonl"
  out_a="$WORK/fc-nonzero.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env AIENV_PYTHON_BIN="$WORK/stub-python-nonzero.sh" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_A" \
        AIENV_INPROCESS_PORT_TIMEOUT_SECS=2 /bin/bash "$GATE" >"$out_a" 2>/dev/null
  rc_a=$?
  assert_eq "fail_close_on_port_failure(非0): permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_a")")"
}

echo "=== 終了0でも不正JSONならfail-close ==="
{
  cat > "$WORK/stub-python-badjson.sh" <<'EOF'
#!/bin/bash
echo 'not json at all'
exit 0
EOF
  chmod +x "$WORK/stub-python-badjson.sh"
  out_badjson="$(printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env AIENV_PYTHON_BIN="$WORK/stub-python-badjson.sh" \
        AIENV_INPROCESS_AUDIT_LOG="$WORK/audit-fc-badjson.jsonl" \
        AIENV_INPROCESS_PORT_TIMEOUT_SECS=2 /bin/bash "$GATE" 2>/dev/null)"
  assert_eq "終了0・不正JSONの口でもdeny" "deny" "$(permission_decision_of "$out_badjson")"
}

echo "=== I2-M1: deny_falls_back_to_printf_when_jq_missing（jq不在でもdenyが無言exit0にならない） ==="
{
  NOJQ_BIN="$WORK/no-jq-bin"
  mkdir -p "$NOJQ_BIN"
  for b in dirname readlink mkdir date cat rm python3 mktemp kill sleep basename; do
    src="$(command -v "$b" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$NOJQ_BIN/$b"
  done

  out_nojq="$WORK/nojq.out"
  AUDIT_NOJQ="$WORK/audit-nojq.jsonl"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env -i PATH="$NOJQ_BIN" AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_NOJQ" \
        /bin/bash "$GATE" >"$out_nojq" 2>/dev/null
  rc_nojq=$?
  # jqが無い環境なので判定はpython3のjson（外部の検証用jq）で行う
  pd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["permissionDecision"])' "$out_nojq" 2>/dev/null)"
  assert_eq "deny_falls_back_to_printf_when_jq_missing: permissionDecision=deny" "deny" "$pd"
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
