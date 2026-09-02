#!/usr/bin/env bash
# scripts/install-main.sh・scripts/install-sub.sh の --with-dotfiles オプションの
# ユニットテスト。
#
# 実GitHub（Takumi00Nine/dotfiles）には一切依存しない。DOTFILES_REPO_URL を
# ローカルの使い捨てbare repoへ差し替えてテストする。
#
# 注意: install-main.sh は末尾で scripts/setup-codex-mcp.sh（実claude/codex CLIを
# 呼びうる）のlaunchctl相当処理を行う（週次drift通知LaunchAgent・
# com.takumi009.drift-check.plistの設置は2026-07-16簡素化で撤去済み）。install-sub.sh
# は委譲先のinstall-main.sh経由でこれを間接的に呼ぶ（サブ専用の定期更新
# LaunchAgent自体は2026-07-23廃止済みで、install-sub.shはLaunchAgentを一切
# 設置・撤去しない＝claude/hooks/check-sub-update.shのSessionStartフックに
# 置き換え済み）。HOME差し替えでは隔離できない実システムへの副作用になりうる
# ため、非dry-run呼び出しには必ず SKIP_CODEX_MCP=1 を付ける（Codexレビュー
# 指摘・Major。tests/test-install-sub.sh と同じ対策。SKIP_LAUNCHCTL=1 は
# install-main.sh側が同名の環境変数を別目的で宣言しているための互換目的で
# 一部呼び出しに残しているが、install-sub.sh自体はこれを参照しない）。
#
# 実行方法: bash tests/test-with-dotfiles.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# 2026-09-01 配役表解凍（設計書§3.9）: v2雛形はrole.leaderがunknownのまま
# 配布されるため、リーダー配役が未確定のままinstall-main.shを対話・
# --non-interactiveいずれも指定せず実行すると対話可否の判定で止まる。
# 本ファイルの主眼＝--with-dotfilesの呼び分けとは無関係なので、既定値を
# exportして「未確定→envの値を検査して採用（質問しない）」経路を通す。
export AIENV_LEADER_ROLE='provider=anthropic-api model=claude-sonnet-5'

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

  # install-sub.sh自体はLaunchAgentを一切設置・撤去しない（2026-07-23廃止）ため
  # SKIP_LAUNCHCTL は本来不要だが、委譲先の install-main.sh が同名の環境変数を
  # 別目的（週次drift通知LaunchAgent向け・現在は未使用）で宣言しているための
  # 互換目的として付けておく（tests/test-install-sub.sh と同じ方針）。
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
    "$([[ -L "$HOME_DIR/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
  assert_true "settings.jsonも生成されている（2026-08-21 machine-role対応でsymlinkから変更）" \
    "$([[ -f "$HOME_DIR/.claude/settings.json" && ! -L "$HOME_DIR/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$HOME_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
