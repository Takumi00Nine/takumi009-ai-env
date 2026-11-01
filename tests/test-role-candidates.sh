#!/usr/bin/env bash
# 候補一覧の形・経路の代表・unavailable・UNRESOLVED。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
RC="$REPO_ROOT/team/connect/claude-code/role_candidates.py"

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
# BASE fixture
# ============================================================
BASE="$WORK/base"
mkdir -p "$BASE/agents"

cat > "$BASE/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: fixture
team_mode:            configured value=full
no_read_paths:        unavailable
machine_role:         configured value=main
role.leader:          configured model=t-opus-high
role.implementer:     configured model=sonnet-noeffort,codex-high
role.verifier:        configured model=codex-high
role.researcher:      unavailable model=sonnet-noeffort
role.navi:            unknown
role.ja-doc:          not_adopted
---
EOF

cat > "$BASE/models.conf" <<'EOF'
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
---
EOF

export AIENV_MODEL_DEFS_FILE="$BASE/models.conf"

export AIENV_USAGE_CACHE_DIR="$WORK/cache-missing"
echo "=== 候補一覧の形 ==="
rc=0
out="$(python3 "$RC" --profile "$BASE/profile.md" --agents-dir "$BASE/agents")" || rc=$?
assert_eq "候補一覧は正常終了する" 0 "$rc"
assert_eq "ヘッダは提示用の列を持つ" "$(printf 'role\tdef\troute\tpass\tok\th5\td7')" "$(printf '%s\n' "$out" | head -1)"
if printf '%s\n' "$out" | tail -n +2 | awk -F'\t' 'NF!=7 && NF!=2 {bad=1} END{exit bad || NR==0}'; then pass "候補と候補なしの行の形"; else fail_case "候補と候補なしの行の形"; fi
for route in subagent external-cli; do
  if printf '%s\n' "$out" | awk -F'\t' -v r="$route" '$3==r && $5=="ok"{found=1} END{exit !found}'; then pass "経路の代表: $route"; else fail_case "経路の代表: $route"; fi
done
if printf '%s\n' "$out" | awk -F'\t' '$1=="researcher" && NF==7 && $5=="no"{found=1} END{exit !found}'; then pass "unavailable 候補は ok=no"; else fail_case "unavailable 候補は ok=no"; fi
rc=0
out="$(python3 "$RC" --profile "$WORK/missing.md" --agents-dir "$BASE/agents" 2>"$WORK/err")" || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$(printf 'role\tdef\troute\tpass\tok\th5\td7')" ] && grep -q '^UNRESOLVED' "$WORK/err"; then pass "解決不能でもヘッダを返し理由を示す"; else fail_case "解決不能でもヘッダを返し理由を示す"; fi

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
