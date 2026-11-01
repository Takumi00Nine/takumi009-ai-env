#!/usr/bin/env bash
# 隔離 HOME と偽 cmux で、宣言状態の読み取りと注入の継続を確認する。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DECL="$REPO_ROOT/dock/executor/declare-state.sh"
DECL_SESSION_JSON='{"session_id":"test-session-0000"}'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=$2 actual=$3)"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれない: \"$3\")"; fi; }

safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; return 1; }
  case "$d" in "" | "/") echo "FATAL: mktemp -d の返り値が不正です: [$d]" >&2; return 1 ;; esac
  [ -d "$d" ] || { echo "FATAL: mktemp -d がディレクトリを作成しませんでした: [$d]" >&2; return 1; }
  [ -z "$(ls -A "$d" 2>/dev/null)" ] || { echo "FATAL: mktemp -d が空でない既存ディレクトリを返しました: [$d]" >&2; return 1; }
  printf '%s' "$d"
}

CMUX_FIXED_STUB_DIR="$(safe_mktemp_d)" || exit 1
printf '#!/bin/bash\nexit 9\n' > "$CMUX_FIXED_STUB_DIR/cmux"
chmod +x "$CMUX_FIXED_STUB_DIR/cmux"
export PATH="$CMUX_FIXED_STUB_DIR:$PATH"
DECL_HOME="$(safe_mktemp_d)" || exit 1
export HOME="$DECL_HOME"
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT BOOTSTRAP_CMUX_LIB_DIR

run_decl() {
  printf '%s\n' "$DECL_SESSION_JSON" | "$DECL" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || true
}

echo "=== cmux が使えなくても宣言状態を注入する ==="
trap 'rm -rf "$CMUX_FIXED_STUB_DIR" "$DECL_HOME"' EXIT
CMUX_TASK_STATE="$DECL_HOME/workspaces.json"
export CMUX_TASK_STATE
ctx="$(run_decl)"
assert_contains "cmux 不在でも状態不明の案内" "$ctx" '宣言状態 不明'
assert_contains "案件宣言の正本参照" "$ctx" '~/Data/obsidian/Preferences/core-workflow.md'
assert_eq "状態を調べても記録は作らない" 0 "$([ -e "$CMUX_TASK_STATE" ] && echo 1 || echo 0)"

echo "=== 宣言済と未宣言を読み取りだけで判断する ==="
cat > "$CMUX_FIXED_STUB_DIR/cmux" <<'EOF'
#!/bin/bash
case "$2" in
  identify) printf '{"focused":{"workspace_ref":"workspace:1"},"caller":{"workspace_ref":"workspace:1"}}\n' ;;
  workspace) printf '{"workspaces":[{"id":"U1","ref":"workspace:1","index":0}]}\n' ;;
  list-windows) printf '[{"id":"win:1","index":0}]\n' ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$CMUX_FIXED_STUB_DIR/cmux"
printf '{"version":1,"workspaces":{"U1":"slug-a"}}\n' > "$CMUX_TASK_STATE"
cp "$CMUX_TASK_STATE" "$DECL_HOME/before.json"
ctx="$(run_decl)"
if [[ "$ctx" == *'宣言済み'* && "$ctx" == *slug-a* ]] && cmp -s "$CMUX_TASK_STATE" "$DECL_HOME/before.json"; then
  pass "宣言済み slug を読み記録を保持"
else fail_case "宣言済み slug を読み記録を保持"; fi
rm "$CMUX_TASK_STATE"
ctx="$(run_decl)"
if [[ "$ctx" == *'未宣言'* && "$ctx" == *'cmux-task-declare.sh set <slug>'* ]] && [ ! -e "$CMUX_TASK_STATE" ]; then
  pass "未宣言なら案内だけ出し記録を作らない"
else fail_case "未宣言なら案内だけ出し記録を作らない"; fi

echo "=== slots も同じ注入を返す ==="
slots="$(printf '%s\n' "$DECL_SESSION_JSON" | "$DECL" --slots)"
assert_eq "slots と通常の注入内容が一致" "$ctx" "$(printf '%s' "$slots" | jq -r '.slots.declare6')"

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
