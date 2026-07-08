#!/usr/bin/env bash
# scripts/install-main.sh・launchagents/com.takumi009.drift-check.plist の
# ユニットテスト（週次drift通知LaunchAgentの設置ロジック。メイン専用。H-2）。
#
# 実 ~/Library/LaunchAgents・実 launchctl には一切依存しない。非dry-run呼び出しでも
# SKIP_LAUNCHCTL=1（launchctl操作だけskip・plist生成はそのまま行う）を必ず付ける
# （gui/$(id -u) はHOME差し替えでは隔離できない実launchdセッションのため。
# tests/test-install-sub.shと同じ対策）。SKIP_CODEX_MCP=1 も併せて付ける
# （実 claude/codex CLI がPATH上にある開発機での実MCP登録副作用を避けるため）。
#
# 実行方法: bash tests/test-install-main-drift-check.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-main.sh"
PLIST="$REPO_ROOT/launchagents/com.takumi009.drift-check.plist"

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

echo "=== 1. plist単体: RunAtLoad=false（静的チェック） ==="
{
  val=$(awk '/<key>RunAtLoad<\/key>/{getline; print; exit}' "$PLIST" | tr -d '[:space:]')
  assert_eq "RunAtLoad=false" "<false/>" "$val"
}

echo "=== 2. plist単体: plutil -lint OK ==="
{
  if command -v plutil >/dev/null 2>&1; then
    assert_true "plutil -lint OK" \
      "$(plutil -lint "$PLIST" >/dev/null 2>&1 && echo 1 || echo 0)"
  else
    pass "plutilが無い環境のためskip"
  fi
}

echo "=== 3. --dry-run: 実際の変更を一切しない・launchctlに触れない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "would generate: drift-check.plist が計画される" \
    "$(echo "$out" | grep -q 'would generate:.*com.takumi009.drift-check.plist' && echo 1 || echo 0)"
  assert_true "実際にはLaunchAgentsディレクトリが作られていない" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. 非dry-run（SKIP_LAUNCHCTL=1）: plistが生成されプレースホルダが正しく置換される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")
  DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.drift-check.plist"

  assert_true "plistファイルが生成されている" "$([[ -f "$DEST" ]] && echo 1 || echo 0)"
  assert_true "SKIP_LAUNCHCTL=1のためskipするログが出る" \
    "$(echo "$out" | grep -q 'SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします' && echo 1 || echo 0)"
  assert_true "__AIENV_HOME__が実HOMEへ置換されている" \
    "$(grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/drift-notify.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "プレースホルダが残っていない" \
    "$(grep -q '__AIENV_HOME__' "$DEST" && echo 0 || echo 1)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "生成後もplutil -lint OK" \
      "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 5. 冪等性: 2回実行してもエラーにならない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null
  rc=0
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"
  assert_true "2回目もplistは健在" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/com.takumi009.drift-check.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 6. --sub-delegate: drift-check.plistは設置されない（メイン専用機能。install-sub.sh用の内部フラグ） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --sub-delegate)
  assert_true "skipメッセージが出る" \
    "$(echo "$out" | grep -q 'sub-delegate.*週次drift通知LaunchAgentの設置はskipします' && echo 1 || echo 0)"
  assert_true "drift-check.plistは生成されていない" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.drift-check.plist" ]] && echo 1 || echo 0)"
  assert_true "symlink化自体は完了している（他処理を妨げない）" \
    "$([[ -L "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
