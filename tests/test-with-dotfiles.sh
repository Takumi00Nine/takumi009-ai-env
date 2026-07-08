#!/usr/bin/env bash
# scripts/install-main.sh・scripts/install-sub.sh の --with-dotfiles オプションの
# ユニットテスト。
#
# 実GitHub（Takumi00Nine/dotfiles）には一切依存しない。DOTFILES_REPO_URL を
# ローカルの使い捨てbare repoへ差し替えてテストする。
#
# 注意: install-main.sh は末尾で scripts/setup-codex-mcp.sh（実claude/codex CLIを
# 呼びうる）と、週次drift通知LaunchAgent（com.takumi009.drift-check.plist・メイン専用。
# H-2）のlaunchctl bootstrapを行う。install-sub.sh は委譲先のinstall-main.sh経由で
# 前者に加えサブ専用LaunchAgentのlaunchctl bootstrapも行う（drift-check.plistは
# --sub-delegate により自動skipされる）。どちらもHOME差し替えでは隔離できない
# 実システムへの副作用になりうるため、非dry-run呼び出しには必ず SKIP_CODEX_MCP=1 と
# SKIP_LAUNCHCTL=1 の両方を付ける（Codexレビュー指摘・Major。tests/test-install-sub.sh
# と同じ対策）。
#
# 実行方法: bash tests/test-with-dotfiles.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

# 使い捨てのダミーdotfiles repo（clone可能なbare相当・install.shが実行痕跡を残す）を作る。
make_fake_dotfiles_src() {
  local src="$1"
  git init -q "$src"
  cat > "$src/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "[fake-dotfiles-install] ran successfully"
touch "$HOME/.fake-dotfiles-installed-marker"
EOF
  chmod +x "$src/install.sh"
  git -C "$src" add -A
  git -C "$src" -c user.name=t -c user.email=t@example.invalid commit -q -m init
}

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

echo "=== 1. install-main.sh: 既定（--with-dotfiles無し）ではdotfilesに一切触れない ==="
{
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" bash "$REPO_ROOT/scripts/install-main.sh")
  assert_true "出力にdotfilesという語が出ない" \
    "$(echo "$out" | grep -qi dotfiles && echo 0 || echo 1)"
  assert_true "\$HOME/work が作られない" \
    "$([[ ! -e "$HOME_DIR/work" ]] && echo 1 || echo 0)"

  rm -rf "$HOME_DIR"
}

echo "=== 2. install-main.sh --dry-run --with-dotfiles: 何も実行しない ==="
{
  DOTFILES_SRC="$(mktemp -d)"
  make_fake_dotfiles_src "$DOTFILES_SRC"
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  out=$(HOME="$HOME_DIR" DOTFILES_REPO_URL="$DOTFILES_SRC" DOTFILES_DIR="$HOME_DIR/work/dotfiles" \
    bash "$REPO_ROOT/scripts/install-main.sh" --dry-run --with-dotfiles)
  assert_true "would runでcloneが計画される" \
    "$(echo "$out" | grep -q 'would run: git clone' && echo 1 || echo 0)"
  assert_true "実際にはcloneされていない" \
    "$([[ ! -e "$HOME_DIR/work/dotfiles" ]] && echo 1 || echo 0)"

  rm -rf "$DOTFILES_SRC" "$HOME_DIR"
}

echo "=== 3. install-main.sh --with-dotfiles: 未clone状態からclone+install.shが実行される ==="
{
  DOTFILES_SRC="$(mktemp -d)"
  make_fake_dotfiles_src "$DOTFILES_SRC"
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" DOTFILES_REPO_URL="$DOTFILES_SRC" DOTFILES_DIR="$HOME_DIR/work/dotfiles" \
    bash "$REPO_ROOT/scripts/install-main.sh" --with-dotfiles >/dev/null

  assert_true "dotfilesがcloneされている" \
    "$([[ -f "$HOME_DIR/work/dotfiles/install.sh" ]] && echo 1 || echo 0)"
  assert_true "dotfiles/install.shが実際に実行された（マーカー確認）" \
    "$([[ -f "$HOME_DIR/.fake-dotfiles-installed-marker" ]] && echo 1 || echo 0)"

  rm -rf "$DOTFILES_SRC" "$HOME_DIR"
}

echo "=== 4. install-main.sh --with-dotfiles: 既存なら再clone せず install.sh だけ呼ぶ ==="
{
  DOTFILES_SRC="$(mktemp -d)"
  make_fake_dotfiles_src "$DOTFILES_SRC"
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" DOTFILES_REPO_URL="$DOTFILES_SRC" DOTFILES_DIR="$HOME_DIR/work/dotfiles" \
    bash "$REPO_ROOT/scripts/install-main.sh" --with-dotfiles >/dev/null
  rm -f "$HOME_DIR/.fake-dotfiles-installed-marker"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" DOTFILES_REPO_URL="$DOTFILES_SRC" DOTFILES_DIR="$HOME_DIR/work/dotfiles" \
    bash "$REPO_ROOT/scripts/install-main.sh" --with-dotfiles)
  assert_true "2回目はcloneをskipするメッセージが出る" \
    "$(echo "$out" | grep -q 'clone はskipします' && echo 1 || echo 0)"
  assert_true "install.shは2回目も実行される（マーカー再生成）" \
    "$([[ -f "$HOME_DIR/.fake-dotfiles-installed-marker" ]] && echo 1 || echo 0)"

  rm -rf "$DOTFILES_SRC" "$HOME_DIR"
}

echo "=== 5. install-sub.sh --with-dotfiles: install-main.shへ正しく委譲される ==="
{
  DOTFILES_SRC="$(mktemp -d)"
  make_fake_dotfiles_src "$DOTFILES_SRC"
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  # SKIP_LAUNCHCTL=1: install-sub.shは末尾でサブ専用LaunchAgentをlaunchctl bootstrap
  # するが、gui/$(id -u)はHOME差し替えで隔離できない実launchdセッションのため、
  # テストでは実システムのlaunchdに触れないようにする（tests/test-install-sub.sh
  # と同じ対策）。
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" DOTFILES_REPO_URL="$DOTFILES_SRC" DOTFILES_DIR="$HOME_DIR/work/dotfiles" \
    bash "$REPO_ROOT/scripts/install-sub.sh" --with-dotfiles >/dev/null

  assert_true "install-sub.sh経由でもdotfilesがcloneされる" \
    "$([[ -f "$HOME_DIR/work/dotfiles/install.sh" ]] && echo 1 || echo 0)"
  assert_true "install-sub.sh経由でもinstall.shが実行される" \
    "$([[ -f "$HOME_DIR/.fake-dotfiles-installed-marker" ]] && echo 1 || echo 0)"
  assert_true "Vault骨格も配置される（--with-dotfilesが他の処理を妨げない）" \
    "$([[ -f "$HOME_DIR/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"

  rm -rf "$DOTFILES_SRC" "$HOME_DIR"
}

echo "=== 6. install-sub.sh: --with-dotfiles無しならdotfilesに一切触れない（回帰） ==="
{
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" bash "$REPO_ROOT/scripts/install-sub.sh")
  assert_true "出力にdotfilesという語が出ない" \
    "$(echo "$out" | grep -qi dotfiles && echo 0 || echo 1)"
  assert_true "\$HOME/work/dotfiles が作られない" \
    "$([[ ! -e "$HOME_DIR/work/dotfiles" ]] && echo 1 || echo 0)"

  rm -rf "$HOME_DIR"
}

echo "=== 7. clone失敗（不正なURL）でもinstall-main.sh自体は失敗しない（soft-fail） ==="
{
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  rc=0
  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" DOTFILES_REPO_URL="/nonexistent/path/to/repo" DOTFILES_DIR="$HOME_DIR/work/dotfiles" \
    bash "$REPO_ROOT/scripts/install-main.sh" --with-dotfiles 2>&1) || rc=$?
  assert_eq "clone失敗してもexit 0（soft-fail）" "0" "$rc"
  assert_true "WARNメッセージが出る" \
    "$(echo "$out" | grep -q 'WARN.*clone.*失敗' && echo 1 || echo 0)"
  assert_true "claude/codexのsymlink化自体は完了している" \
    "$([[ -L "$HOME_DIR/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$HOME_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
