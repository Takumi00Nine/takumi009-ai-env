#!/usr/bin/env bash
# scripts/install-sub.sh のユニットテスト。
#
# 実 ~/.claude・~/.codex・実Vaultには一切依存しない。HOME環境変数を
# 毎回ダミーのfixtureディレクトリへ差し替えてスクリプトを実行し、
# Vault骨格配置・claude/codex symlink化の委譲が正しく行われることを検証する。
#
# 注意: install-sub.sh は末尾でサブ専用LaunchAgent（sub-update.plist）の
# launchctl bootstrap を行うが、gui/$(id -u) は実launchdセッションでありHOME差し替え
# では隔離できないため、非dry-run呼び出しには必ず SKIP_LAUNCHCTL=1 を付けて
# 実システムのlaunchdに触れないようにする（発見の経緯: 実装中に一度SKIP無しで
# テストを回し、実launchdに一時ディレクトリを指すゴミ登録をしてしまい
# `launchctl bootout` で手動クリーンアップした。以後この対策を導入）。
# install-sub.sh は install-main.sh へ `--sub-delegate` を付けて委譲するため、
# 週次drift通知LaunchAgent（com.takumi009.drift-check.plist・メイン専用。H-2）は
# install-main.sh側で自動skipされる（installされない）。SKIP_LAUNCHCTL=1 は
# install-main.sh側の環境にも引き継がれる（同名の環境変数を採用しているため）。
# 同様に install-sub.sh は install-main.sh 経由で scripts/setup-codex-mcp.sh も
# 呼ぶため、実 claude/codex CLI がPATH上にある開発機でテストを走らせた場合の
# 実MCP登録への副作用を避けるため SKIP_CODEX_MCP=1 も併せて付ける
# （Codexレビュー指摘・Major）。
#
# 実行方法: bash tests/test-install-sub.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-sub.sh"

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

echo "=== 1. dry-run: 実際の変更を一切しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "dry-run出力にwould copyが含まれる" \
    "$(echo "$out" | grep -q 'would copy' && echo 1 || echo 0)"
  assert_true "Vaultが実際には作られていない" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian" ]] && echo 1 || echo 0)"
  assert_true "settings.jsonが実際にはsymlink化されていない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. Vault未存在: vault-public/の中身が骨格として配置される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_true "Preferencesの中身がコピーされている（absolute-rules.md存在）" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"
  for dir in Personal Knowledge Decisions Projects Fragments Explorations Blogs; do
    n=$(find "$FAKE_HOME/Data/obsidian/$dir" -mindepth 1 -not -name '.DS_Store' | wc -l | tr -d ' ')
    assert_eq "$dir はREADME.mdのみ（ファイル数1）" "1" "$n"
  done

  rm -rf "$FAKE_HOME"
}

echo "=== 3. Vault既存: 骨格配置をskipし、既存の中身を上書きしない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Data/obsidian"
  echo "existing private note" > "$FAKE_HOME/Data/obsidian/my-note.md"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")
  assert_true "skipしますのメッセージが出る" \
    "$(echo "$out" | grep -q 'skipします' && echo 1 || echo 0)"
  assert_eq "既存ファイルの中身が変わっていない" "existing private note" \
    "$(cat "$FAKE_HOME/Data/obsidian/my-note.md")"
  assert_true "vault-publicのPreferencesが誤って混ざっていない" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian/Preferences" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. claude/・codex/ の symlink化が install-main.sh 経由で行われる ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_eq "settings.jsonがrepoへのsymlinkになっている" "$REPO_ROOT/claude/settings.json" \
    "$(readlink "$FAKE_HOME/.claude/settings.json")"
  assert_true "config.tomlが生成されている（symlinkではなく実ファイル）" \
    "$([[ -f "$FAKE_HOME/.codex/config.toml" && ! -L "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 5. メイン専用LaunchAgent類はインストールされない（サブ専用のsub-updateだけ入る） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  for name in vault-backup vault-inventory fragments-review drift-check; do
    assert_true "メイン専用の $name.plist は入らない" \
      "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.$name.plist" ]] && echo 1 || echo 0)"
  done
  assert_true "サブ専用のsub-update.plistは入る" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 5b. sub-update.plist: RunAtLoad=false・プレースホルダ置換・構文が正しい ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist"
  assert_true "RunAtLoadがfalse" \
    "$(awk '/<key>RunAtLoad<\/key>/{getline; print; exit}' "$DEST" | tr -d '[:space:]' | grep -q '<false/>' && echo 1 || echo 0)"
  assert_true "__AIENV_HOME__が実HOMEへ置換されている" \
    "$(grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/update-sub.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "プレースホルダが残っていない" \
    "$(grep -q '__AIENV_HOME__' "$DEST" && echo 0 || echo 1)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "plutil -lint OK" \
      "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 6. 冪等性: 2回実行してもエラーにならず状態が壊れない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null
  rc=0
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"
  assert_true "2回目もVaultのPreferencesは健在" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
