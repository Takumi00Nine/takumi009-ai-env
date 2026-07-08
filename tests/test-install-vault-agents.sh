#!/usr/bin/env bash
# scripts/install-vault-agents.sh・launchagents/com.takumi009.{vault-inventory,
# fragments-review}.plist のユニットテスト。
#
# 実 ~/Library/LaunchAgents・実 launchctl には一切依存しない（--dry-runのみ実行）。
# 「配置のみ・即時kickstartはしない」設計（Codexレビュー指摘・Major）を固定する
# 回帰テストが主目的。
#
# 実行方法: bash tests/test-install-vault-agents.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-vault-agents.sh"

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

echo "=== 1. 収録した2plistは全てRunAtLoad=falseである（静的チェック） ==="
{
  for name in vault-inventory fragments-review; do
    plist="$REPO_ROOT/launchagents/com.takumi009.$name.plist"
    # RunAtLoadキーの直後の値が<false/>であることを確認する
    val=$(awk '/<key>RunAtLoad<\/key>/{getline; print; exit}' "$plist" | tr -d '[:space:]')
    assert_eq "$name: RunAtLoad=false" "<false/>" "$val"
  done
}

echo "=== 2. plutil -lint が全plistでOKになる（構文チェック） ==="
{
  for name in vault-inventory fragments-review; do
    plist="$REPO_ROOT/launchagents/com.takumi009.$name.plist"
    if plutil -lint "$plist" >/dev/null 2>&1; then
      pass "$name: plutil -lint OK"
    else
      fail_case "$name: plutil -lint NG"
    fi
  done
}

echo "=== 3. --dry-run: 実際の変更を一切しない・kickstartに触れない ==="
{
  FAKE_HOME="$(mktemp -d)"
  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)

  assert_true "would generateが2件出る" \
    "$([[ "$(echo "$out" | grep -c 'would generate')" == "2" ]] && echo 1 || echo 0)"
  # ログ文中に「kickstartは行わない」旨の説明があるのは正しい（そのものは弾かない）。
  # 実際に kickstart を"実行する計画"（would run: launchctl kickstart）が無いことを確認する。
  assert_true "「would run: launchctl kickstart」という実行計画は出ない（即時実行しない設計）" \
    "$(echo "$out" | grep -q 'would run: launchctl kickstart' && echo 0 || echo 1)"
  assert_true "実際にはLaunchAgentsディレクトリが作られていない" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. __AIENV_HOME__ プレースホルダが実ホームパスへ正しく置換される（生成シミュレーション） ==="
{
  FAKE_HOME="/tmp/fake-home-for-vault-agents-test"
  for name in vault-inventory fragments-review; do
    src="$REPO_ROOT/launchagents/com.takumi009.$name.plist"
    sim=$(sed "s#__AIENV_HOME__#$FAKE_HOME#g" "$src")
    assert_true "$name: 置換後に__AIENV_HOME__が残っていない" \
      "$(echo "$sim" | grep -q '__AIENV_HOME__' && echo 0 || echo 1)"
    assert_true "$name: 置換後にscripts/vault-agents/への参照が正しい" \
      "$(echo "$sim" | grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/vault-agents/" && echo 1 || echo 0)"
  done
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
