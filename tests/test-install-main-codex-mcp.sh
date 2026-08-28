#!/usr/bin/env bash
# scripts/install-main.sh から scripts/setup-codex-mcp.sh が正しく呼ばれる（成功時は
# 静かに完了・失敗時はWARNでinstaller全体を落とさない）ことのユニットテスト。
# setup-codex-mcp.sh 自体の詳細な挙動は tests/test-setup-codex-mcp.sh が担当する。
#
# 注意: install-main.sh は末尾で週次drift通知LaunchAgent（com.takumi009.drift-check.plist）
# もlaunchctl bootstrapする（メイン専用機能。H-2）。gui/$(id -u) はHOME差し替えでは
# 隔離できない実launchdセッションのため、非dry-run呼び出しには必ず SKIP_LAUNCHCTL=1 を
# 付ける（tests/test-install-sub.sh と同じ対策）。
#
# 実行方法: bash tests/test-install-main-codex-mcp.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-main.sh"

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

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

echo "=== 1. claudeコマンドが無くてもinstall-main.sh全体はexit 0（WARNのみ・soft-fail） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  rc=0
  out=$(SKIP_LAUNCHCTL=1 PATH="/usr/bin:/bin" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "codex MCP登録失敗のWARNが出る" \
    "$(echo "$out" | grep -q 'WARN: codex MCP の登録に失敗しました' && echo 1 || echo 0)"
  assert_true "symlink化（hooks等）は完了している" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
  assert_true "settings.jsonも生成されている（symlinkではなく実ファイル）" \
    "$([[ -f "$FAKE_HOME/.claude/settings.json" && ! -L "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "settings.jsonのmodelはメイン既定値(claude-fable-5[1m])に置換されている" \
    "$(grep -q 'claude-fable-5\[1m\]' "$FAKE_HOME/.claude/settings.json" && echo 1 || echo 0)"
  assert_true "config.tomlも生成されている" \
    "$([[ -f "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. モックclaude+codexがあれば登録が実行される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  BINDIR="$(mktemp -d)"
  LOG="$BINDIR/claude-calls.log"
  : > "$LOG"
  cat > "$BINDIR/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
if [ "\$1 \$2" = "mcp get" ]; then exit 1; fi
if [ "\$1 \$2" = "mcp add" ]; then exit 0; fi
exit 0
EOF
  chmod +x "$BINDIR/claude"
  cat > "$BINDIR/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BINDIR/codex"

  rc=0
  SKIP_LAUNCHCTL=1 PATH="$BINDIR:/usr/bin:/bin" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "mcp add codex が呼ばれた" \
    "$(grep -qE '^mcp add codex -s user -- .*/codex mcp-server$' "$LOG" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo "=== 3. --dry-run では setup-codex-mcp.sh を実際には呼ばない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  BINDIR="$(mktemp -d)"
  LOG="$BINDIR/claude-calls.log"
  : > "$LOG"
  cat > "$BINDIR/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
exit 1
EOF
  chmod +x "$BINDIR/claude"

  out=$(PATH="$BINDIR:/usr/bin:/bin" HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run 2>&1)
  assert_true "would runの計画表示が出る" \
    "$(echo "$out" | grep -q 'would run:.*setup-codex-mcp.sh' && echo 1 || echo 0)"
  assert_true "モックclaudeは一度も呼ばれていない（dry-runなので）" \
    "$([[ ! -s "$LOG" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
