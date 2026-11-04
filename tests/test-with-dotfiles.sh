#!/usr/bin/env bash
# dotfiles を既定で触らないことと、指定時の clone・導入。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# リーダー配役は make_fake_home() が置く実体プロファイル（role.leader:
# configured model=t-sonnet-high）から resolver が解決する（対話式リーダー設定
# と AIENV_LEADER_ROLE は 2026-09-19 に退役＝install-main.sh は profile.md を
# 読むだけ）。本ファイルの主眼＝--with-dotfilesの呼び分け。

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

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

# write_models_conf_at <dir> — モデル定義ファイル（models.conf）を<dir>/
# models.conf へ書く（モデル定義ファイルと候補指定-設計-2026-09-08.md
# §2.3・§2.4）。schema 8のrole行は`model=<定義名>[,...]`で定義名を
# 参照するだけになったため、role.leaderの解決を伴うテストは全てこの定義
# ファイルを必要とする（無いとT7で解決不能になる）。
write_models_conf_at() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
EOF
}

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  # 配役表-能力軸整理-設計-2026-09-07.md §3: schema 5・新3キーの実体を
  # あらかじめ置く。本ファイルの主眼＝--with-dotfilesの呼び分けとは無関係
  # なので、install-main.sh の雛形配置（team/data/profile.md.sample からの
  # コピー。2026-09-08 本人裁定A案で読み元をvault-public/Preferences/
  # profile-sample.mdから付け替え）に依存させない（テストの独立性・
  # §10「機能差分なし」を字面どおり保つため）。
  mkdir -p "$home/.config/takumi009-ai-env"
  write_models_conf_at "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 8
profile_slug: test-with-dotfiles-machine
team_mode: configured value=team
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-sonnet-high
---
EOF
}

echo "=== 1. install-main.sh: 既定（--with-dotfiles無し）ではdotfilesに一切触れない ==="
{
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" bash "$REPO_ROOT/core/assembly/install-main.sh")
  assert_true "出力にdotfilesという語が出ない" \
    "$(echo "$out" | grep -qi dotfiles && echo 0 || echo 1)"
  assert_true "\$HOME/Workspace が作られない" \
    "$([[ ! -e "$HOME_DIR/Workspace/Tools/dotfiles" && ! -e "$HOME_DIR/.fake-dotfiles-installed-marker" ]] && echo 1 || echo 0)"

  rm -rf "$HOME_DIR"
}

echo "=== 3. install-main.sh --with-dotfiles: 未clone状態からclone+install.shが実行される ==="
{
  DOTFILES_SRC="$(mktemp -d)"
  make_fake_dotfiles_src "$DOTFILES_SRC"
  HOME_DIR="$(mktemp -d)"
  make_fake_home "$HOME_DIR"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$HOME_DIR" DOTFILES_REPO_URL="$DOTFILES_SRC" DOTFILES_DIR="$HOME_DIR/Workspace/Tools/dotfiles" \
    bash "$REPO_ROOT/core/assembly/install-main.sh" --with-dotfiles >/dev/null

  assert_true "dotfilesがcloneされている" \
    "$([[ -f "$HOME_DIR/Workspace/Tools/dotfiles/install.sh" ]] && echo 1 || echo 0)"
  assert_true "dotfiles/install.shが実際に実行された（マーカー確認）" \
    "$([[ -f "$HOME_DIR/.fake-dotfiles-installed-marker" ]] && echo 1 || echo 0)"

  rm -rf "$DOTFILES_SRC" "$HOME_DIR"
}


echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
