#!/usr/bin/env bash
# モデル解決の経路・一覧の形・未定義と旧版の拒否。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/team/executor/profile_resolve.py"

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
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ============================================================
# §6.1 共通ベース FX-B1（要件v1.7・literal）
# ============================================================
BASE="$WORK/base"
mkdir -p "$BASE/agents"

cat > "$BASE/profile.md" <<'EOF'
---
schema_version: 8
profile_slug: fixture
team_mode:        configured value=team
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader:      configured model=t-opus-high
role.implementer: configured model=sonnet-noeffort,codex-high
role.verifier:    configured model=codex-high
---
EOF

cat > "$BASE/models.conf" <<'EOF'
# モデル定義（実体＝機ごとのローカル。config/models.conf.sampleのコピー）
[t-opus-high]
provider=anthropic-api
model=claude-opus-5-5
effort=high

[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5-5

[codex-high]
provider=external
execution=external-cli
model=default
effort=high

EOF

cat > "$BASE/agents/implementer.md" <<'EOF'
---
name: implementer
model: claude-sonnet-5-5
---
EOF
cat > "$BASE/agents/verifier.md" <<'EOF'
---
name: verifier
model: claude-opus-5-5
---
EOF
export AIENV_MODEL_DEFS_FILE="$BASE/models.conf"
echo "=== resolver の正常系 ==="
rc=0; out="$(python3 "$LIB" resolve "$BASE/profile.md" --agents-dir "$BASE/agents")" || rc=$?
assert_eq "正常な定義は解決できる" 0 "$rc"
case "$out" in OK*) pass "正常解決の形" ;; *) fail_case "正常解決の形" ;; esac
out="$(python3 "$LIB" resolve-leader "$BASE/profile.md" --agents-dir "$BASE/agents")"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d["model"],str) and d["model"]'; then
  pass "リーダー解決はモデルを持つ JSON"
else fail_case "リーダー解決はモデルを持つ JSON"; fi
out="$(python3 "$LIB" list-roles "$BASE/profile.md")"
if printf '%s\n' "$out" | awk -F'\t' 'NF!=7 {bad=1} END{exit bad || NR==0}'; then pass "配役一覧は7列"; else fail_case "配役一覧は7列"; fi
out="$(python3 "$LIB" list-candidates "$BASE/profile.md" --agents-dir "$BASE/agents")"
if printf '%s\n' "$out" | awk -F'\t' 'NF!=6 {bad=1} END{exit bad || NR==0}'; then pass "候補一覧は6列"; else fail_case "候補一覧は6列"; fi
for spec in 'sonnet-noeffort subagent' 'codex-high external-cli'; do
  set -- $spec
  rc=0; out="$(python3 "$LIB" resolve-candidate "$BASE/profile.md" --role implementer --model-def "$1" --agents-dir "$BASE/agents")" || rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == OK* && "$out" == *"$2"* ]]; then pass "候補解決: $2"; else fail_case "候補解決: $2"; fi
done
echo "=== resolver の拒否 ==="
assert_eq "MODE-TEAM/I7: resolverの期待schemaは8" "SCHEMA_VERSION:8" \
  "$(python3 "$LIB" known-keys | sed -n '/^SCHEMA_VERSION:/p')"
# enum追加で6以上の受入範囲を狭めない。旧版のfullに互換は与えない。
sed -e 's/^schema_version:.*/schema_version: 6/' -e 's/value=team/value=lean/' "$BASE/profile.md" > "$WORK/schema6.md"
rc=0; out="$(python3 "$LIB" resolve "$WORK/schema6.md" --agents-dir "$BASE/agents")" || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == OK* && "$out" == *TEAM_MODE:lean* ]]; then
  pass "MODE-TEAM/I7: schema 6の有効なleanを受理する"
else
  fail_case "MODE-TEAM/I7: schema 6の有効なleanを受理する"
fi
sed 's/model=sonnet-noeffort,codex-high/model=undefined-def/' "$BASE/profile.md" > "$WORK/undefined.md"
rc=0; out="$(python3 "$LIB" resolve "$WORK/undefined.md" --agents-dir "$BASE/agents")" || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" != OK* && "$out" == *undefined-def* ]]; then pass "未定義モデルを拒否する"; else fail_case "未定義モデルを拒否する"; fi
sed 's/^schema_version:.*/schema_version: 1/' "$BASE/profile.md" > "$WORK/legacy.md"
rc=0; out="$(python3 "$LIB" resolve "$WORK/legacy.md" --agents-dir "$BASE/agents")" || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" != OK* && "$out" == *T4-LEGACY* ]]; then pass "旧版プロファイルを拒否する"; else fail_case "旧版プロファイルを拒否する"; fi

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
