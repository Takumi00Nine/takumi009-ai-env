#!/bin/bash
# tests/test-inprocess-gate.sh — ラッパー起動-設計-v1.1.1.md §4（D-3）・
# 要件v1.4.3 §4.3（FR-21・FR-22）・§5（AC-14・AC-18）を検証する。
#
# 対象: claude/hooks/lib/profile_resolve.py の `check-inprocess` サブコマンド
# （AC-18＝口の契約）と claude/hooks/inprocess-gate.sh（AC-14＝境界フック）。
# 実 $HOME・実 launchd は使わない（fixture 一式は一時ディレクトリに作る）。
#
# 実行方法: bash tests/test-inprocess-gate.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
GATE="$REPO_ROOT/claude/hooks/inprocess-gate.sh"

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
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\" / 実際: $haystack)"
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-inprocess-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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
role.verifier:    unavailable model=sonnet-noeffort,codex-high
role.navi:        not_adopted
role.ja-doc:      unknown
---
EOF
cat > "$BASE/models.conf" <<'EOF'
[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5

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

json_get() { # json_get <json> <key>
  printf '%s' "$1" | python3 -c "import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print('null' if v is None else v)" "$2"
}

permission_decision_of() { # permission_decision_of <hook-json> — deny()の出力（jq -n。
  # 改行・空白の有無に依存しない取り出し。値が無ければ空文字）
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}

echo "=== AC-18①: port_json_contract（6フィールド・型・exit0） ==="
{
  out="$(CI "$BASE/profile.md" general-purpose)"; rc=$?
  assert_eq "port_json_contract: exit0" "0" "$rc"
  lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert_eq "port_json_contract: JSON1行" "1" "$lines"
  keys="$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin).keys())))')"
  assert_eq "port_json_contract: 6キー完全一致" "allowed,candidate_count,profile_revision,reason_code,role_present,role_state" "$keys"
  atype="$(printf '%s' "$out" | python3 -c 'import json,sys; print(type(json.load(sys.stdin)["allowed"]).__name__)')"
  assert_eq "port_json_contract: allowedはbool" "bool" "$atype"
}

echo "=== AC-18②: port_state_and_count_are_evidence_only（4状態・状態と件数は判定に影響しない） ==="
{
  for pair in "implementer:configured:2" "verifier:unavailable:2" "navi:not_adopted:0" "ja-doc:unknown:0"; do
    role="${pair%%:*}"
    rest="${pair#*:}"
    state="${rest%%:*}"
    count="${rest#*:}"
    out="$(CI "$BASE/profile.md" "$role")"
    allowed="$(json_get "$out" allowed)"
    reason="$(json_get "$out" reason_code)"
    rstate="$(json_get "$out" role_state)"
    rcount="$(json_get "$out" candidate_count)"
    assert_eq "port_4states($role): allowed=False" "False" "$allowed"
    assert_eq "port_4states($role): reason_code=ROLE_IN_CAST_TABLE" "ROLE_IN_CAST_TABLE" "$reason"
    assert_eq "port_4states($role): role_state=$state" "$state" "$rstate"
    assert_eq "port_4states($role): candidate_count=$count" "$count" "$rcount"
  done
}

echo "=== AC-18③: port_positive_nulls（陽性＝role_state=null・candidate_count=0） ==="
{
  out="$(CI "$BASE/profile.md" general-purpose)"
  allowed="$(json_get "$out" allowed)"
  present="$(json_get "$out" role_present)"
  state="$(json_get "$out" role_state)"
  count="$(json_get "$out" candidate_count)"
  reason="$(json_get "$out" reason_code)"
  assert_eq "port_positive_nulls: allowed=True" "True" "$allowed"
  assert_eq "port_positive_nulls: role_present=False" "False" "$present"
  assert_eq "port_positive_nulls: role_state=null" "null" "$state"
  assert_eq "port_positive_nulls: candidate_count=0" "0" "$count"
  assert_eq "port_positive_nulls: reason_code=NOT_IN_CAST_TABLE" "NOT_IN_CAST_TABLE" "$reason"
}

echo "=== AC-18④: port_unreadable_profile_nulls（symlink・fail-close） ==="
{
  ln -s "$BASE/profile.md" "$WORK/profile-link.md"
  out="$(CI "$WORK/profile-link.md" general-purpose)"; rc=$?
  assert_eq "port_unreadable_profile_nulls: exit0（JSONは出す）" "0" "$rc"
  allowed="$(json_get "$out" allowed)"
  present="$(json_get "$out" role_present)"
  state="$(json_get "$out" role_state)"
  count="$(json_get "$out" candidate_count)"
  rev="$(json_get "$out" profile_revision)"
  reason="$(json_get "$out" reason_code)"
  assert_eq "port_unreadable_profile_nulls: allowed=False" "False" "$allowed"
  assert_eq "port_unreadable_profile_nulls: role_present=null" "null" "$present"
  assert_eq "port_unreadable_profile_nulls: role_state=null" "null" "$state"
  assert_eq "port_unreadable_profile_nulls: candidate_count=null" "null" "$count"
  assert_eq "port_unreadable_profile_nulls: profile_revision=null" "null" "$rev"
  assert_eq "port_unreadable_profile_nulls: reason_code=PROFILE_UNRESOLVED" "PROFILE_UNRESOLVED" "$reason"
}

echo "=== AC-18④: port_empty_roles_is_unresolved（役職行が0本・fail-close） ==="
{
  cat > "$WORK/empty-roles.md" <<'EOF'
---
schema_version: 7
profile_slug: fixture
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
---
EOF
  out="$(CI "$WORK/empty-roles.md" general-purpose)"
  allowed="$(json_get "$out" allowed)"
  present="$(json_get "$out" role_present)"
  reason="$(json_get "$out" reason_code)"
  assert_eq "port_empty_roles_is_unresolved: allowed=False" "False" "$allowed"
  assert_eq "port_empty_roles_is_unresolved: role_present=null" "null" "$present"
  assert_eq "port_empty_roles_is_unresolved: reason_code=PROFILE_UNRESOLVED" "PROFILE_UNRESOLVED" "$reason"

  out2="$(CI "$WORK/empty-roles.md" implementer)"
  reason2="$(json_get "$out2" reason_code)"
  assert_eq "port_empty_roles_is_unresolved: 実在しそうな職種名でも同じくPROFILE_UNRESOLVED" "PROFILE_UNRESOLVED" "$reason2"
}

echo "=== AC-18⑤: hook_does_not_parse_profile（フックの実装に配役表を直接読む処理が0件） ==="
{
  # $AIENV_LOCAL_PROFILE_PATH の使用箇所は「既定値の代入」と「口への引数
  # 渡し」の2箇所だけであること（cat/</awk/sed/grep等で内容を読まない）。
  hits="$(grep -n 'AIENV_LOCAL_PROFILE_PATH' "$GATE" | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -Ev ': "\$\{AIENV_LOCAL_PROFILE_PATH:=|check-inprocess "\$AIENV_LOCAL_PROFILE_PATH"')"
  assert_eq "hook_does_not_parse_profile: 想定外の参照が無い" "" "$hits"
  # role.<職種>やschema_versionの文字列を直接扱っていないこと（配役表の
  # 文法・語彙をハードコードしていない静的検査）。
  literal_hits="$(grep -nE 'role\.[a-z]|schema_version:' "$GATE" || true)"
  assert_eq "hook_does_not_parse_profile: role./schema_versionのliteralが無い" "" "$literal_hits"
}

echo "=== AC-14①: allow_not_in_cast_table（陽性・監査1行） ==="
{
  AUDIT="$WORK/audit-allow.jsonl"
  out_file="$WORK/allow.out"
  err_file="$WORK/allow.err"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT" \
        /bin/bash "$GATE" >"$out_file" 2>"$err_file"
  rc=$?
  assert_eq "allow_not_in_cast_table: exit0" "0" "$rc"
  assert_eq "allow_not_in_cast_table: stdout空（干渉しない）" "" "$(cat "$out_file")"
  assert_eq "allow_not_in_cast_table: 監査ログ1行" "1" "$(wc -l < "$AUDIT" | tr -d ' ')"
  line="$(cat "$AUDIT")"
  assert_contains "allow_not_in_cast_table: decision=allowed" "$line" '"decision":"allowed"'
  assert_contains "allow_not_in_cast_table: reason_code=NOT_IN_CAST_TABLE" "$line" '"reason_code":"NOT_IN_CAST_TABLE"'
  assert_contains "allow_not_in_cast_table: role=general-purpose" "$line" '"role":"general-purpose"'
}

echo "=== AC-14②: deny_four_states（陰性4通り・各1行の監査） ==="
{
  for pair in "implementer:configured" "verifier:unavailable" "navi:not_adopted" "ja-doc:unknown"; do
    role="${pair%%:*}"
    state="${pair#*:}"
    AUDIT="$WORK/audit-deny-$role.jsonl"
    out_file="$WORK/deny-$role.out"
    printf '%s' "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$role\"}}" \
      | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
          AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT" \
          /bin/bash "$GATE" >"$out_file" 2>/dev/null
    rc=$?
    assert_eq "deny_four_states($role): exit0" "0" "$rc"
    assert_eq "deny_four_states($role): permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_file")")"
    assert_contains "deny_four_states($role): 理由文にclaude-exec.sh" "$(cat "$out_file")" "claude-exec.sh"
    assert_eq "deny_four_states($role): 監査ログ1行" "1" "$(wc -l < "$AUDIT" | tr -d ' ')"
    line="$(cat "$AUDIT")"
    assert_contains "deny_four_states($role): decision=denied" "$line" '"decision":"denied"'
    assert_contains "deny_four_states($role): reason_code=ROLE_IN_CAST_TABLE" "$line" '"reason_code":"ROLE_IN_CAST_TABLE"'
    assert_contains "deny_four_states($role): role_state=$state" "$line" "\"role_state\":\"$state\""
  done
}

echo "=== AC-14③: fail_close_on_port_failure（口が非0／不正JSON→ともにdenied・fail-close） ==="
{
  cat > "$WORK/stub-python-nonzero.sh" <<'EOF'
#!/bin/bash
exit 7
EOF
  cat > "$WORK/stub-python-badjson.sh" <<'EOF'
#!/bin/bash
echo 'not json at all'
exit 0
EOF
  chmod +x "$WORK"/stub-python-*.sh

  AUDIT_A="$WORK/audit-fc-nonzero.jsonl"
  out_a="$WORK/fc-nonzero.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env AIENV_PYTHON_BIN="$WORK/stub-python-nonzero.sh" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_A" \
        AIENV_INPROCESS_PORT_TIMEOUT_SECS=2 /bin/bash "$GATE" >"$out_a" 2>/dev/null
  rc_a=$?
  assert_eq "fail_close_on_port_failure(非0): exit0" "0" "$rc_a"
  assert_eq "fail_close_on_port_failure(非0): permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_a")")"
  line_a="$(cat "$AUDIT_A")"
  assert_contains "fail_close_on_port_failure(非0): reason_code=PROFILE_UNRESOLVED" "$line_a" '"reason_code":"PROFILE_UNRESOLVED"'
  assert_contains "fail_close_on_port_failure(非0): decision=denied" "$line_a" '"decision":"denied"'

  AUDIT_B="$WORK/audit-fc-badjson.jsonl"
  out_b="$WORK/fc-badjson.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env AIENV_PYTHON_BIN="$WORK/stub-python-badjson.sh" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_B" \
        AIENV_INPROCESS_PORT_TIMEOUT_SECS=2 /bin/bash "$GATE" >"$out_b" 2>/dev/null
  rc_b=$?
  assert_eq "fail_close_on_port_failure(不正JSON): exit0" "0" "$rc_b"
  assert_eq "fail_close_on_port_failure(不正JSON): permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_b")")"
  line_b="$(cat "$AUDIT_B")"
  assert_contains "fail_close_on_port_failure(不正JSON): reason_code=PROFILE_UNRESOLVED" "$line_b" '"reason_code":"PROFILE_UNRESOLVED"'
  assert_contains "fail_close_on_port_failure(不正JSON): decision=denied" "$line_b" '"decision":"denied"'
}

echo "=== 回帰: symlink_resolution_matches_repo_path（\$HOME/.claude/hooks/inprocess-gate.sh相当のsymlink経路でもrepoパス直叩きと同じdeny/allow/監査行になる。resolve_inprocess_gate_self_dir()の恒久検査） ==="
{
  LINKED_HOOKS="$WORK/linked-hooks"
  mkdir -p "$LINKED_HOOKS"
  ln -s "$GATE" "$LINKED_HOOKS/inprocess-gate.sh"

  # allow側（NOT_IN_CAST_TABLE）: symlink経由とrepoパス直叩きで比較
  AUDIT_LINK_ALLOW="$WORK/audit-link-allow.jsonl"
  AUDIT_REPO_ALLOW="$WORK/audit-repo-allow.jsonl"
  out_link_allow="$WORK/link-allow.out"
  out_repo_allow="$WORK/repo-allow.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_LINK_ALLOW" \
        /bin/bash "$LINKED_HOOKS/inprocess-gate.sh" >"$out_link_allow" 2>/dev/null
  rc_link_allow=$?
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_REPO_ALLOW" \
        /bin/bash "$GATE" >"$out_repo_allow" 2>/dev/null
  rc_repo_allow=$?
  assert_eq "symlink_resolution: allow exit0が一致" "$rc_repo_allow" "$rc_link_allow"
  assert_eq "symlink_resolution: allow stdout（空）が一致" "$(cat "$out_repo_allow")" "$(cat "$out_link_allow")"
  line_link_allow="$(cat "$AUDIT_LINK_ALLOW")"
  line_repo_allow="$(cat "$AUDIT_REPO_ALLOW")"
  assert_contains "symlink_resolution: allow監査decision=allowed" "$line_link_allow" '"decision":"allowed"'
  assert_contains "symlink_resolution: allow監査reason_code=NOT_IN_CAST_TABLE" "$line_link_allow" '"reason_code":"NOT_IN_CAST_TABLE"'
  # ts以外（decision/reason_code/role等の各フィールド）はrepoパス直叩きと一致すること
  strip_ts_allow_link="$(printf '%s' "$line_link_allow" | jq -S 'del(.ts)')"
  strip_ts_allow_repo="$(printf '%s' "$line_repo_allow" | jq -S 'del(.ts)')"
  assert_eq "symlink_resolution: allow監査行（ts除く）が一致" "$strip_ts_allow_repo" "$strip_ts_allow_link"

  # deny側（ROLE_IN_CAST_TABLE）: symlink経由とrepoパス直叩きで比較
  AUDIT_LINK_DENY="$WORK/audit-link-deny.jsonl"
  AUDIT_REPO_DENY="$WORK/audit-repo-deny.jsonl"
  out_link_deny="$WORK/link-deny.out"
  out_repo_deny="$WORK/repo-deny.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_LINK_DENY" \
        /bin/bash "$LINKED_HOOKS/inprocess-gate.sh" >"$out_link_deny" 2>/dev/null
  rc_link_deny=$?
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_REPO_DENY" \
        /bin/bash "$GATE" >"$out_repo_deny" 2>/dev/null
  rc_repo_deny=$?
  assert_eq "symlink_resolution: deny exit0が一致" "$rc_repo_deny" "$rc_link_deny"
  assert_eq "symlink_resolution: deny JSON出力が一致" "$(cat "$out_repo_deny")" "$(cat "$out_link_deny")"
  assert_eq "symlink_resolution: deny permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_link_deny")")"
  line_link_deny="$(cat "$AUDIT_LINK_DENY")"
  line_repo_deny="$(cat "$AUDIT_REPO_DENY")"
  strip_ts_deny_link="$(printf '%s' "$line_link_deny" | jq -S 'del(.ts)')"
  strip_ts_deny_repo="$(printf '%s' "$line_repo_deny" | jq -S 'del(.ts)')"
  assert_eq "symlink_resolution: deny監査行（ts除く）が一致" "$strip_ts_deny_repo" "$strip_ts_deny_link"
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
  assert_eq "deny_falls_back_to_printf_when_jq_missing: exit0" "0" "$rc_nojq"
  out_nojq_content="$(cat "$out_nojq")"
  assert_eq "deny_falls_back_to_printf_when_jq_missing: 出力が空でない" "no" "$([ -z "$out_nojq_content" ] && echo yes || echo no)"
  # jqが無い環境なので判定はpython3のjson（外部の検証用jq）で行う
  pd="$(printf '%s' "$out_nojq_content" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null)"
  assert_eq "deny_falls_back_to_printf_when_jq_missing: permissionDecision=deny" "deny" "$pd"
}

echo "=== I2-m6: invalid_timeout_normalizes_to_default（非整数期限でも判定が変わらない） ==="
{
  AUDIT_BADTO_DENY="$WORK/audit-badto-deny.jsonl"
  out_badto_deny="$WORK/badto-deny.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"implementer"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_BADTO_DENY" \
        AIENV_INPROCESS_PORT_TIMEOUT_SECS="30.5" /bin/bash "$GATE" >"$out_badto_deny" 2>/dev/null
  rc_badto_deny=$?
  assert_eq "invalid_timeout_normalizes_to_default: deny側exit0" "0" "$rc_badto_deny"
  assert_eq "invalid_timeout_normalizes_to_default: deny側permissionDecision=deny" "deny" "$(permission_decision_of "$(cat "$out_badto_deny")")"
  line_badto_deny="$(cat "$AUDIT_BADTO_DENY")"
  assert_contains "invalid_timeout_normalizes_to_default: deny側reason_code=ROLE_IN_CAST_TABLE" "$line_badto_deny" '"reason_code":"ROLE_IN_CAST_TABLE"'

  AUDIT_BADTO_ALLOW="$WORK/audit-badto-allow.jsonl"
  out_badto_allow="$WORK/badto-allow.out"
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}' \
    | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
        AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT_BADTO_ALLOW" \
        AIENV_INPROCESS_PORT_TIMEOUT_SECS="abc" /bin/bash "$GATE" >"$out_badto_allow" 2>/dev/null
  rc_badto_allow=$?
  assert_eq "invalid_timeout_normalizes_to_default: allow側exit0" "0" "$rc_badto_allow"
  assert_eq "invalid_timeout_normalizes_to_default: allow側stdout空（干渉しない）" "" "$(cat "$out_badto_allow")"
  line_badto_allow="$(cat "$AUDIT_BADTO_ALLOW")"
  assert_contains "invalid_timeout_normalizes_to_default: allow側decision=allowed" "$line_badto_allow" '"decision":"allowed"'
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
