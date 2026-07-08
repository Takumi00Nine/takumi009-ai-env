#!/usr/bin/env bash
# scripts/check-drift.sh のユニットテスト。
#
# 実 ~/.claude・~/.codex・実Vault・実リポジトリには一切依存しない。DIR/HOME/VAULT を
# 環境変数で毎回ダミーのfixtureへ差し替えてスクリプトを実行し、①〜④それぞれの
# drift検知（陽性・陰性の両方）を検証する。check-drift.sh は fail-fast しない
# 設計（exit codeは常に0）のため、判定は標準出力の内容で行う。
#
# 実行方法: bash tests/test-check-drift.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_REL="scripts/check-drift.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

# 最小構成の「repo」フィクスチャを作る（check-drift.shが参照する
# claude/・codex/・vault-public/・scripts/check-drift.sh本体だけをコピーする）。
make_fake_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/claude/hooks" "$repo/claude/agents" "$repo/codex" "$repo/vault-public/Preferences"
  cp "$REPO_ROOT/$SCRIPT_REL" "$repo/scripts/check-drift.sh"
  chmod +x "$repo/scripts/check-drift.sh"
  echo '{}' > "$repo/claude/settings.json"
  echo '#!/bin/bash' > "$repo/claude/hooks/bootstrap-vault.sh"
  echo '#!/bin/bash' > "$repo/claude/hooks/delegation-gate-v2.sh"
  echo '# agent' > "$repo/claude/agents/sample-agent.md"
  echo '# AGENTS' > "$repo/codex/AGENTS.md"
  echo '{}' > "$repo/codex/hooks.json"
  cat > "$repo/codex/config.toml" <<'EOF'
service_tier = "default"
[mcp_servers.obsidian]
args = ["__AIENV_HOME__/Data/obsidian"]
EOF
  echo "# サンプル方針" > "$repo/vault-public/Preferences/sample.md"
}

# claude/・codex/ の symlink化（install-main.sh相当を簡易に再現）＋config.toml生成を行う。
install_fake_home() {
  local repo="$1" home="$2"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  ln -s "$repo/claude/settings.json" "$home/.claude/settings.json"
  ln -s "$repo/claude/hooks/bootstrap-vault.sh" "$home/.claude/hooks/bootstrap-vault.sh"
  ln -s "$repo/claude/hooks/delegation-gate-v2.sh" "$home/.claude/hooks/delegation-gate-v2.sh"
  ln -s "$repo/claude/agents/sample-agent.md" "$home/.claude/agents/sample-agent.md"
  ln -s "$repo/codex/AGENTS.md" "$home/.codex/AGENTS.md"
  ln -s "$repo/codex/hooks.json" "$home/.codex/hooks.json"
  # install-main.sh の generate_config_toml() と同じくエスケープしてから置換する
  # （$home に # を含むテスト（1b）で、エスケープ無しだと置換自体が壊れて
  # 「正しく生成されたはずのconfig.tomlがテンプレと不一致」という偽陽性になるため）。
  local escaped_home
  escaped_home=$(printf '%s' "$home" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$repo/codex/config.toml" > "$home/.codex/config.toml"
}

run_check() {
  # bash 3.2（macOSシステムbash）では、同一 `local` 文中で直前に代入した変数を
  # 続く代入の右辺で参照すると、set -u下で「unbound variable」になる既知の癖がある
  # （実測: `local a=1 b=$a` は b=$a の評価時点で a が未束縛扱いになるケースがある）。
  # 各代入を別行に分けて回避する。
  local repo="$1"
  local home="$2"
  local vault="${3:-$home/Data/obsidian}"
  DIR="$repo" HOME="$home" VAULT="$vault" bash "$repo/scripts/check-drift.sh"
}

echo "=== 1. 全項目ズレ無し（陰性コントロール） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "symlink drift 0件" "$out" "symlink総数: 6件 / drift: 0件"
  assert_contains "config.toml一致" "$out" "プレースホルダ展開を考慮すれば一致しています"
  assert_contains "Preferences差分なし" "$out" "差分なし（vault-public/Preferences は実Vaultの最新を反映しています）"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 1b. HOMEに # が含まれる環境でも②config.tomlチェックが壊れない（Codexレビュー指摘・Minor回帰） ==="
{
  REPO="$(mktemp -d)"
  HOME_PARENT="$(mktemp -d)"
  HOME_DIR="$HOME_PARENT/home#with-hash"
  mkdir -p "$HOME_DIR"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "HOMEに#が含まれてもconfig.toml一致と判定される" "$out" "プレースホルダ展開を考慮すれば一致しています"
  assert_not_contains "sedの構文エラーが出ない" "$out" "sed:"

  rm -rf "$REPO" "$HOME_PARENT"
}

echo "=== 2. ①symlinkが無い（未インストール）を検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  mkdir -p "$HOME_DIR/.claude/hooks" "$HOME_DIR/.claude/agents" "$HOME_DIR/.codex"
  # symlink化しない（未インストール状態を模擬）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "MISSING検知" "$out" "[MISSING]"
  assert_contains "6件全部drift" "$out" "symlink総数: 6件 / drift: 6件"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 3. ①symlinkが実ファイルに置き換わっている（NOT-SYMLINK）を検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  rm "$HOME_DIR/.claude/settings.json"
  echo '{"hand-edited": true}' > "$HOME_DIR/.claude/settings.json"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "NOT-SYMLINK検知" "$out" "[NOT-SYMLINK]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 4. ①symlinkが別の場所を指している（WRONG-TARGET）を検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  rm "$HOME_DIR/.claude/settings.json"
  echo '{}' > "$HOME_DIR/somewhere-else.json"
  ln -s "$HOME_DIR/somewhere-else.json" "$HOME_DIR/.claude/settings.json"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "WRONG-TARGET検知" "$out" "[WRONG-TARGET]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 5. ②config.tomlがテンプレと異なる（手動編集）を検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  echo "extra_manual_line = true" >> "$HOME_DIR/.codex/config.toml"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "config.toml DIFF検知" "$out" "[DIFF]"
  assert_not_contains "config.toml一致メッセージは出ない" "$out" "プレースホルダ展開を考慮すれば一致しています"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 5b. ②Codexアプリが自動書き換えする機械管理キーのみ異なる場合はdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # Codexアプリが実運用で自動追加/書き換えする類のキー・セクションを模擬して
  # live側だけに付加する（テンプレには意図的に存在しない）。セクションが
  # 中間・末尾どちらにあっても連続空行が畳まれてテンプレと一致することも
  # あわせて確認するため、既存セクションの間にも挿入する。
  # 実ホームパスを含む行（args・source等）は $HOME_DIR で埋める（クォート無し
  # heredocで変数展開する）。そうしないと逆置換 __AIENV_HOME__ 化が効かず、
  # このテスト自体が意図しない[DIFF]（パス不一致）を起こしてしまう。
  cat > "$HOME_DIR/.codex/config.toml" <<EOF
service_tier = "default"

notify = ["${HOME_DIR}/.codex/computer-use/Codex Computer Use.app", "turn-ended"]

[marketplaces.openai-bundled]
last_updated = "2026-07-08T11:17:59Z"
source_type = "local"
source = "${HOME_DIR}/.codex/.tmp/bundled-marketplaces/openai-bundled"

[mcp_servers.obsidian]
args = ["${HOME_DIR}/Data/obsidian"]
NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = "deadbeefdeadbeefdeadbeefdeadbeef"
BROWSER_USE_CODEX_APP_VERSION = "26.999.999999"

[hooks.state."${HOME_DIR}/work/repo"]
trust_hash = "abc123"

[projects."${HOME_DIR}/work/repo"]
trust_level = "trusted"

[tui.model_availability_nux]
read = true
EOF

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "機械管理キー除外後は一致と判定される" "$out" "プレースホルダ展開を考慮すれば一致しています（機械管理キー除外後）"
  assert_not_contains "config.toml DIFFにはならない" "$out" "[DIFF] ${HOME_DIR}/.codex/config.toml"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 5c. ②機械管理キー一覧に含まれないキュレート対象キーが異なる場合はdriftとして検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # 機械管理キーの除外フィルタが、無関係な人為的設定変更まで握りつぶさないことを確認する
  # （service_tier はテンプレでキュレートされている設定値であり、除外リストには無い）。
  sed 's/service_tier = "default"/service_tier = "high"/' "$HOME_DIR/.codex/config.toml" > "$HOME_DIR/.codex/config.toml.tmp"
  mv "$HOME_DIR/.codex/config.toml.tmp" "$HOME_DIR/.codex/config.toml"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "config.toml DIFF検知（機械管理キーではないので握りつぶされない）" "$out" "[DIFF]"
  assert_not_contains "一致メッセージは出ない" "$out" "プレースホルダ展開を考慮すれば一致しています"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 5d. ②セクション名の前方一致誤爆・キー行の空白違いの境界条件（Codexレビュー指摘・Major回帰） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # (a) "[projects_backup]" のように除外対象セクション名を前方一致するが別物の
  #     セクションは、境界（"."区切り or "]"終端）を見ていれば誤って除去されない
  #     ＝テンプレに無いので[DIFF]として残るはず。
  # (b) "notify=[...]"（"="の前後にスペース無し）のような書き方違いも、
  #     空白許容つきアンカーであれば正しく除去対象と判定されるはず。
  cat >> "$HOME_DIR/.codex/config.toml" <<'EOF'

notify=["turn-ended"]

[projects_backup]
comment = "本来のprojectsセクションとは無関係の別テーブル"
EOF

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "notifyの書き方違いは機械管理キーとして除去され[DIFF]の直接原因にはならない（別要因の[projects_backup]でDIFF自体は出る）" "$out" "[DIFF]"
  assert_not_contains "notify=[...]の行自体はdiff出力に残らない（除去できている証跡）" "$out" "notify=[\"turn-ended\"]"
  assert_contains "[projects_backup]は前方一致誤爆で握りつぶされずdiff出力に残る" "$out" "projects_backup"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 6. ③repoに未commitの変更があるとUNCOMMITTEDを検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name test
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"
  echo "dirty change" >> "$REPO/vault-public/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "UNCOMMITTED検知" "$out" "[UNCOMMITTED]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 7. ③repoがcommit済みでクリーンならUNCOMMITTEDは出ない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name test
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "UNCOMMITTEDは出ない" "$out" "[UNCOMMITTED]"
  assert_contains "未commitの変更はありませんメッセージ" "$out" "未commitの変更はありません"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 8. ④実Vaultとvault-publicのPreferencesに差分があるとDIFFを検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  # わざと内容を変えてエクスポート漏れを模擬する
  echo "# 実Vault側だけの更新（未エクスポート）" > "$HOME_DIR/Data/obsidian/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "Preferences DIFF検知" "$out" "[DIFF]"
  assert_contains "エクスポート漏れの可能性メッセージ" "$out" "export-public-vault.sh の再実行が必要な可能性"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 9. ④実Vaultが無い（サブ機想定）ならDIFFではなく対象外メッセージ ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  # $HOME_DIR/Data/obsidian を作らない（サブ機で私的パッチが無い状態を模擬）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "対象外メッセージが出る" "$out" "このマシンに私的パッチが無い（サブ機）想定ならチェック対象外"
  assert_not_contains "DIFFにはならない" "$out" "[DIFF]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 10. exit codeは常に0（fail-fastしない設計） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  # 何もインストールしない＝全項目drift状態でもexit 0であることを確認

  rc=0
  run_check "$REPO" "$HOME_DIR" >/dev/null || rc=$?
  if [[ "$rc" == "0" ]]; then
    pass "drift大量でもexit 0"
  else
    fail_case "drift大量でもexit 0 (実際は$rc)"
  fi

  rm -rf "$REPO" "$HOME_DIR"
}

# --- ⑤ private可視性チェック用のヘルパー ---

# 指定パスに git リポジトリを作り、origin remote を設定する。
make_git_repo_with_remote() {
  local path="$1" remote="$2"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" remote add origin "$remote"
}

# モックの gh コマンドを作る。mode: PRIVATE / PUBLIC / fail（未認証等でrepo viewが失敗する想定）。
make_mock_gh() {
  local bindir="$1" mode="$2"
  mkdir -p "$bindir"
  if [ "$mode" = "fail" ]; then
    cat > "$bindir/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  else
    cat > "$bindir/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "repo view" ]; then
  echo "$mode"
  exit 0
fi
exit 1
EOF
  fi
  chmod +x "$bindir/gh"
}

echo "=== 11. ⑤Vault・私的パッチrepoとも PRIVATE ならdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin git@github.com:someone/myvault.git
  make_git_repo_with_remote "$PRIVATE_REPO" "https://github.com/someone/aienv-private.git"
  make_mock_gh "$BINDIR" "PRIVATE"

  out="$(PATH="$BINDIR:$PATH" AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_contains "Vaultバックアップ: PRIVATE確認メッセージ" "$out" "Vaultバックアップ (someone/myvault): ✅ PRIVATE"
  assert_contains "私的パッチrepo: PRIVATE確認メッセージ" "$out" "私的パッチrepo (someone/aienv-private): ✅ PRIVATE"
  assert_not_contains "[VISIBILITY]は出ない" "$out" "[VISIBILITY]"
  assert_contains "総drift件数0（他項目もクリーンなfixtureのため）" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$BINDIR" "$PRIVATE_REPO"
}

echo "=== 12. ⑤GitHub上でPUBLICになっているとdriftとして検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin git@github.com:someone/myvault.git
  make_git_repo_with_remote "$PRIVATE_REPO" "https://github.com/someone/aienv-private.git"
  make_mock_gh "$BINDIR" "PUBLIC"

  out="$(PATH="$BINDIR:$PATH" AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_contains "Vaultバックアップの[VISIBILITY]検知" "$out" "[VISIBILITY] Vaultバックアップ (someone/myvault)"
  assert_contains "私的パッチrepoの[VISIBILITY]検知" "$out" "[VISIBILITY] 私的パッチrepo (someone/aienv-private)"
  assert_contains "総drift件数2（PUBLIC2件分）" "$out" "総drift件数: 2"

  rm -rf "$REPO" "$HOME_DIR" "$BINDIR" "$PRIVATE_REPO"
}

echo "=== 13. ⑤gh コマンドが無い場合はWARN表示のみでdriftにしない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin git@github.com:someone/myvault.git
  make_git_repo_with_remote "$PRIVATE_REPO" "https://github.com/someone/aienv-private.git"
  # gh は配置しない（見つからない状態を模擬）。外側PATHを継承すると開発機に実ghが
  # 入っている場合に環境依存で結果が変わるため、PATHを固定する
  # （tests/test-setup-codex-mcp.shのCodexレビュー指摘・Minorと同じ対策）。

  out="$(PATH="/usr/bin:/bin" AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_contains "GH-UNAVAILABLE表示（Vault）" "$out" "[GH-UNAVAILABLE] Vaultバックアップ"
  assert_contains "GH-UNAVAILABLE表示（私的パッチrepo）" "$out" "[GH-UNAVAILABLE] 私的パッチrepo"
  assert_not_contains "[VISIBILITY]は出ない（driftにしない）" "$out" "[VISIBILITY]"
  assert_contains "総drift件数0（gh不在はdriftにしない）" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$PRIVATE_REPO"
}

echo "=== 14. ⑤gh はあるが repo view が失敗（未認証等）ならWARN表示のみでdriftにしない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin git@github.com:someone/myvault.git
  make_mock_gh "$BINDIR" "fail"

  out="$(PATH="$BINDIR:$PATH" run_check "$REPO" "$HOME_DIR")"
  assert_contains "GH-CHECK-FAILED表示" "$out" "[GH-CHECK-FAILED] Vaultバックアップ"
  assert_not_contains "[VISIBILITY]は出ない（driftにしない）" "$out" "[VISIBILITY]"

  rm -rf "$REPO" "$HOME_DIR" "$BINDIR"
}

echo "=== 15. ⑤remote未設定・GitHub以外のremoteは対象外メッセージのみでdriftにしない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # Vault: git init はするがremoteは追加しない（未設定を模擬）
  git -C "$HOME_DIR/Data/obsidian" init -q
  # 私的パッチrepo: GitHub以外のremote（gitlab）を設定
  make_git_repo_with_remote "$PRIVATE_REPO" "https://gitlab.com/someone/aienv-private.git"

  out="$(AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_contains "Vault: remote未設定で対象外" "$out" "Vaultバックアップ: remote 'origin' が未設定のためチェック対象外"
  assert_contains "私的パッチrepo: GitHub以外で対象外" "$out" "私的パッチrepo: GitHub以外のremoteのため可視性チェック対象外"
  assert_not_contains "[VISIBILITY]は出ない" "$out" "[VISIBILITY]"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$PRIVATE_REPO"
}

echo "=== 16. ⑤GitHub remote URLの表記ゆれ（認証情報付きHTTPS・ssh.github.com:443・末尾スラッシュ）も解析できる（Codexレビュー指摘・Major回帰） ==="
{
  BINDIR="$(mktemp -d)"
  make_mock_gh "$BINDIR" "PRIVATE"

  urls=(
    "https://user:token@github.com/someone/repo-a.git"
    "ssh://git@ssh.github.com:443/someone/repo-b.git"
    "https://github.com/someone/repo-c/"
  )
  expects=(
    "someone/repo-a"
    "someone/repo-b"
    "someone/repo-c"
  )
  i=0
  for url in "${urls[@]}"; do
    REPO="$(mktemp -d)"
    HOME_DIR="$(mktemp -d)"
    make_fake_repo "$REPO"
    install_fake_home "$REPO" "$HOME_DIR"
    mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
    cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
    git -C "$HOME_DIR/Data/obsidian" init -q
    git -C "$HOME_DIR/Data/obsidian" remote add origin "$url"

    out="$(PATH="$BINDIR:$PATH" AIENV_PRIVATE_REPO="$HOME_DIR/nonexistent" run_check "$REPO" "$HOME_DIR")"
    assert_contains "URL『${url}』が ${expects[$i]} として解析される" "$out" "Vaultバックアップ (${expects[$i]}): ✅ PRIVATE"
    assert_not_contains "URL『${url}』はGH-URL-UNPARSEABLEにならない" "$out" "[GH-URL-UNPARSEABLE]"

    rm -rf "$REPO" "$HOME_DIR"
    i=$((i + 1))
  done

  rm -rf "$BINDIR"
}

echo "=== 17. ⑤解析できないGitHubらしきURLは対象外ではなく[GH-URL-UNPARSEABLE]として目立たせる（driftにはしない） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  # ownerもrepoも取れない異常系URL（github.comは含むがパス部が無い）
  git -C "$HOME_DIR/Data/obsidian" remote add origin "https://github.com"

  out="$(AIENV_PRIVATE_REPO="$HOME_DIR/nonexistent" run_check "$REPO" "$HOME_DIR")"
  assert_contains "GH-URL-UNPARSEABLEが出る" "$out" "[GH-URL-UNPARSEABLE] Vaultバックアップ"
  assert_not_contains "[VISIBILITY]にはならない" "$out" "[VISIBILITY]"
  assert_contains "総drift件数0（解析不能はdriftにしない）" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 18. ⑤解析できない/GitHub以外のURLに認証情報が含まれていてもログに露出しない（Codexレビュー指摘・Major回帰） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # Vault: github.comらしきURLだがパス部が無く解析不能（[GH-URL-UNPARSEABLE]経路）
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin "https://user:sup3rSecretToken@github.com"
  # 私的パッチrepo: GitHub以外（対象外経路）
  make_git_repo_with_remote "$PRIVATE_REPO" "https://user:sup3rSecretToken@gitlab.com/someone/aienv-private.git"

  out="$(AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "認証トークンがログに出ない" "$out" "sup3rSecretToken"
  assert_contains "代わりにredactedと表示される（Vault側）" "$out" "<redacted>@github.com"
  assert_contains "代わりにredactedと表示される（私的パッチrepo側）" "$out" "<redacted>@gitlab.com"

  rm -rf "$REPO" "$HOME_DIR" "$PRIVATE_REPO"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
