#!/usr/bin/env bash
# claude/hooks/vault-write-gate.sh のユニットテスト（設計 design-step1.md §3.3）。
#
# 子（claude-exec 経由のワーカー）向けの Vault 保護柵。実 ~/.claude・実 Vault
# には一切依存せず、偽 HOME（一時ディレクトリ）へ HOME を差し替えてフックを
# 直接実行する（symlink なし＝SELF_DIR/lib/guard_common.sh は repo 内で解決
# できるため、フック配置の隔離は不要）。
#
# 入力: stdin の JSON（tool_input.file_path または notebook_path・cwd）。
# 判定: フックは deny の場合も含め常に exit 0 を返す契約（permissionDecision
# は標準出力のJSONで表現）。標準出力に "permissionDecision": "deny" を含めば
# deny、空なら通過。
#
# 実行方法: bash tests/test-vault-write-gate.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/vault-write-gate.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/Data/obsidian/Knowledge" "$FAKE_HOME/Data/obsidian/Preferences" \
  "$FAKE_HOME/Data/obsidian/Archive" "$FAKE_HOME/Data/obsidian/Decisions"

# run_hook <file_path> <cwd> — フックへJSON入力を渡して標準出力を返す。
run_hook() {
  local fpath="$1" cwd="$2"
  jq -n --arg fpath "$fpath" --arg cwd "$cwd" \
    '{tool_input:{file_path:$fpath}, cwd:$cwd}' | HOME="$FAKE_HOME" bash "$HOOK"
}

assert_denied() {
  local desc="$1" fpath="$2" cwd="$3" out
  out="$(run_hook "$fpath" "$cwd")"
  if printf '%s' "$out" | grep -qE '"permissionDecision":[[:space:]]*"deny"'; then
    pass "$desc"
  else
    fail_case "$desc (denyされなかった。fpath=[$fpath] cwd=[$cwd] out=[$out])"
  fi
}

assert_allowed() {
  local desc="$1" fpath="$2" cwd="$3" out
  out="$(run_hook "$fpath" "$cwd")"
  if [ -z "$out" ]; then
    pass "$desc"
  else
    fail_case "$desc (denyされてしまった。fpath=[$fpath] cwd=[$cwd] out=[$out])"
  fi
}

echo "=== 1. VW-P1/P2: AI向け6フォルダ配下の絶対パスはdeny ==="
assert_denied "VW-P1: Knowledge配下のWriteはdeny" "$FAKE_HOME/Data/obsidian/Knowledge/x.md" "/tmp"
assert_denied "VW-P2: Preferences配下のEditはdeny" "$FAKE_HOME/Data/obsidian/Preferences/y.md" "/tmp"

echo "=== 2. VW-N1/N2: 6フォルダの外・Vault外は通過 ==="
assert_allowed "VW-N1: Vault配下でも6フォルダの外（Archive）は通過" "$FAKE_HOME/Data/obsidian/Archive/z.md" "/tmp"
assert_allowed "VW-N2: Vault外（/tmp配下）は通過" "/tmp/out/w.md" "/tmp"

echo "=== 3. VW-R1: 相対パスはcwdで絶対化してから判定（6フォルダ配下ならdeny） ==="
assert_denied "VW-R1: cwd=Decisions配下・file_path=相対のdeny" "d.md" "$FAKE_HOME/Data/obsidian/Decisions"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
