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

# N日前/後のYYYY-MM-DD・ISO8601時刻（BSD date。⑥のfixture用。
# tests/test-vault-inventory.sh と同じ考え方＝ハードコード日付を使わない）。
d_date() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%F; }
# 実際のフック（vault-recall.sh/vault-read-log.sh）は `date -u +...Z` でUTC時刻を
# 書く。テストのfixtureも同じくUTCで生成する（`-u`無しのローカル時刻に'Z'を付けた
# だけの値だと、check-drift.sh側の解析バグ〈N-5・ローカルTZとして誤解釈〉と
# 対称に間違えてしまい、テストがバグを覆い隠してしまうため＝2026-07-10
# 敵対的レビュー2回目 N-5 対応）。
d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"d +%Y-%m-%dT%H:%M:%SZ; }
# `touch -t` 用のN日前/後のタイムスタンプ（BSD touch形式 [[CC]YY]MMDDhhmm[.SS]）。
# weekly-reviewのcanvasはファイル名(対象週の月曜日)ではなくmtime基準で新鮮度判定する
# ため、fixtureのmtimeを意図的に古くしたい場合に使う。
d_mtime_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%Y%m%d0000; }

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
  echo '#!/bin/bash' > "$repo/claude/hooks/vault-recall.sh"
  echo '#!/bin/bash' > "$repo/claude/hooks/vault-read-log.sh"
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
  ln -s "$repo/claude/hooks/vault-recall.sh" "$home/.claude/hooks/vault-recall.sh"
  ln -s "$repo/claude/hooks/vault-read-log.sh" "$home/.claude/hooks/vault-read-log.sh"
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
  assert_contains "symlink drift 0件" "$out" "symlink総数: 8件 / drift: 0件"
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
  assert_contains "8件全部drift" "$out" "symlink総数: 8件 / drift: 8件"

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

echo "=== 7b. ③git status --porcelain の実行自体が失敗した場合は『差分なし』に混同せずGIT-STATUS-CHECK-FAILEDを検知する（2026-07-14 リーダー指摘対応） ==="
{
  # 旧実装は `|| true` でコマンド失敗を握りつぶしており、gitリポジトリ破損等で
  # status自体が実行できない場合も出力ゼロ件＝「未commitの変更はありません」と
  # 偽の健全表示になっていた（「監視不能も異常」の原則に反する）。
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
  # .git/HEAD を消してリポジトリを破損させる（.gitディレクトリ自体は残る＝
  # 本ツールの `[ -d "$DIR/.git" ]` ガードは通過するが、git statusは失敗する）。
  rm -f "$REPO/.git/HEAD"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "GIT-STATUS-CHECK-FAILEDが検知される" "$out" "[GIT-STATUS-CHECK-FAILED]"
  assert_not_contains "偽の健全表示にはならない" "$out" "✅ 未commitの変更はありません"
  assert_not_contains "UNCOMMITTEDと誤分類はしない（別種別）" "$out" "[UNCOMMITTED]"

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

echo "=== 8b. ④diff -rq の実行自体が失敗した場合は『差分なし』に混同せずDIFF-CHECK-FAILEDを検知する（2026-07-14 リーダー指摘対応） ==="
{
  # diff -rq のexit code: 0=差分なし／1=差分あり／2=読み取り不能等のエラー。
  # 旧実装は `|| true` で握りつぶしており、2（エラー）も出力ゼロ件なら
  # 「差分なし＝健全」に混同し得た。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # vault-public側のファイルを読み取り不能にして diff -rq をエラー終了させる
  # （ディレクトリ自体の権限は残す＝一覧はできるが個別ファイルが読めない状態）。
  chmod 000 "$REPO/vault-public/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "DIFF-CHECK-FAILEDが検知される" "$out" "[DIFF-CHECK-FAILED]"
  assert_not_contains "偽の健全表示にはならない" "$out" "✅ 差分なし"
  assert_not_contains "DIFFと誤分類はしない（別種別）" "$out" "[DIFF]"

  chmod 644 "$REPO/vault-public/Preferences/sample.md"
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

# N時間前/後のepoch秒（BSD date。⑦のfixture用。origin/mainのコミット日時を
# 過去/未来に固定するために使う＝ハードコード日付を使わない）。
d_epoch_hours() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"H +%s; }

# ⑦のfixture用: 指定パスをVault風のgitリポジトリにし、ローカルのbare originを
# 設定する（tests/test-backup-vault.shの「8. remote origin設定済みならpush
# される」と同じ方式＝実ネットワーク不要）。ブランチ名は本番のVaultと同じ main に
# 固定する（環境のinit.defaultBranch設定に依存しないよう -b で明示）。
make_vault_with_bare_origin() {
  local vault="$1" bare="$2"
  git init -q --bare "$bare"
  mkdir -p "$vault"
  git -C "$vault" init -q -b main
  git -C "$vault" config user.name test
  git -C "$vault" config user.email test@example.invalid
  git -C "$vault" remote add origin "$bare"
}

# ⑦のfixture用: 指定epoch秒でVaultへ1コミット追加する。
vault_commit_at() {
  local vault="$1" epoch="$2" msg="$3"
  echo "$msg" >> "$vault/note.md"
  git -C "$vault" add -A
  GIT_AUTHOR_DATE="@${epoch} +0000" GIT_COMMITTER_DATE="@${epoch} +0000" \
    git -C "$vault" commit -q -m "$msg"
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

echo "=== 14. ⑤gh はあるが repo view が失敗（未認証等）ならGH-CHECK-FAILEDとしてdriftに計上する（2026-07-13外部脳round4対応） ==="
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
  assert_not_contains "[VISIBILITY]は出ない（GH-CHECK-FAILEDとは別種の異常）" "$out" "[VISIBILITY]"
  assert_contains "総drift件数1（可視性チェック実行不能もdrift計上・監視不能も異常）" "$out" "総drift件数: 1"

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

echo "=== 19. ⑥vault-agentsが健全（レポート・ログとも新しい）ならdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 0).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "棚卸しレポート健全メッセージ" "$out" "✅ 棚卸しレポート:"
  assert_contains "fragments-logレポート健全メッセージ" "$out" "✅ fragments-logレポート:"
  assert_contains "vault-reads.tsv健全メッセージ" "$out" "✅ vault-reads.tsv:"
  assert_contains "vault-recall.tsv健全メッセージ" "$out" "✅ vault-recall.tsv:"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 20. ⑥棚卸しレポートが期限超過(STALE)だと検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 目安20日を超える25日前が最新レポート
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date -25).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-INVENTORY-STALEが検知される" "$out" "[VAULT-INVENTORY-STALE]"
  assert_contains "確認コマンドが含まれる" "$out" "launchctl list | grep vault-inventory"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 21. ⑥棚卸しレポートが一度も生成されていない(DEAD)と検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # vault-inventory/ ディレクトリはあるが中身が空（一度もレポート生成されていない）
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-INVENTORY-DEADが検知される" "$out" "[VAULT-INVENTORY-DEAD]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22. ⑥fragments-logレポートが期限超過(STALE)だと検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 0).md"
  # 目安10日を超える15日前が最新レビュー
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date -15).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "FRAGMENTS-LOG-STALEが検知される" "$out" "[FRAGMENTS-LOG-STALE]"
  assert_contains "確認コマンドが含まれる" "$out" "launchctl list | grep fragments-log"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22b. ⑥未処理レポート: 生成直後（猶予日数以内）はdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 生成から1日（既定の猶予3日以内）・processedマーカーなし
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date -1).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date -1).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "VAULT-INVENTORY-UNPROCESSEDは出ない（猶予内）" "$out" "[VAULT-INVENTORY-UNPROCESSED]"
  assert_not_contains "FRAGMENTS-LOG-UNPROCESSEDは出ない（猶予内）" "$out" "[FRAGMENTS-LOG-UNPROCESSED]"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22c. ⑥未処理レポート: 猶予日数を超えて未処理だとUNPROCESSEDを検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 生成から5日（既定の猶予3日超）・STALE閾値(棚卸し20日/週次10日)は超えていない
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date -5).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date -5).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-INVENTORY-UNPROCESSEDが検知される" "$out" "[VAULT-INVENTORY-UNPROCESSED]"
  assert_contains "FRAGMENTS-LOG-UNPROCESSEDが検知される" "$out" "[FRAGMENTS-LOG-UNPROCESSED]"
  assert_contains "総drift件数2" "$out" "総drift件数: 2"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22d. ⑥未処理レポート: frontmatterに processed マーカーがあればdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  D="$(d_date -5)"
  cat > "$HOME_DIR/.claude/logs/vault-inventory/${D}.md" <<EOF
---
date: ${D}
processed: $(d_date -4)
---

# 外部脳 棚卸しレポート ${D}
EOF
  cat > "$HOME_DIR/.claude/logs/fragments-log/${D}.md" <<EOF
---
date: ${D}
processed: $(d_date -4)
---

# Fragments 昇格レビュー ${D}
EOF
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "棚卸しレポート処理済みメッセージ" "$out" "✅ 棚卸しレポート: 処理済みマーカーあり"
  assert_contains "fragments-logレポート処理済みメッセージ" "$out" "✅ fragments-logレポート: 処理済みマーカーあり"
  assert_not_contains "UNPROCESSEDは出ない" "$out" "UNPROCESSED"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22e. ⑥未処理レポート: 既にSTALE扱いのレポートは二重にUNPROCESSED報告しない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 目安20日を超える25日前が最新レポート＝STALE（かつprocessedマーカーも無い）
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date -25).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-INVENTORY-STALEが検知される" "$out" "[VAULT-INVENTORY-STALE]"
  assert_not_contains "同じレポートにVAULT-INVENTORY-UNPROCESSEDは重複して出ない" "$out" "[VAULT-INVENTORY-UNPROCESSED]"
  assert_contains "総drift件数1（STALEのみ・重複無し）" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22f. ⑥未処理レポート: 最新は処理済みでも、古い（既に置き換わった）未処理レポートは検知する（2026-07-14修正の回帰テスト。旧実装は最新1件しか見ておらず、drift-checkがレポート生成と同日実行される運用ではlatestが常にage=0でグレースを超えられず、この穴が永久検知不能だった） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 古いレポート（8日前・猶予3日超だがSTALE閾値10日は超えていない）は未処理のまま。
  OLD="$(d_date -8)"
  echo "# review old" > "$HOME_DIR/.claude/logs/fragments-log/${OLD}.md"
  # 最新レポート（当日生成）は既に処理済み＝旧実装ではここだけを見て「健全」と誤判定していた。
  NEW="$(d_date 0)"
  cat > "$HOME_DIR/.claude/logs/fragments-log/${NEW}.md" <<EOF
---
date: ${NEW}
processed: ${NEW}
---

# Fragments 昇格レビュー ${NEW}
EOF
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  # 最新自体は処理済みだが、古い方が未処理のまま残っているためdrift扱いを優先する
  # （処理済みマーカーありメッセージより「未処理が残っている」警告を優先表示）。
  assert_contains "古い未処理レポートがFRAGMENTS-LOG-UNPROCESSEDとして検知される" "$out" "[FRAGMENTS-LOG-UNPROCESSED]"
  assert_contains "件数1件と表示される" "$out" "未処理（frontmatterの processed: 行が無い）レポートが1件あります"
  assert_contains "古いレポートのフルパスが表示される" "$out" "${HOME_DIR}/.claude/logs/fragments-log/${OLD}.md"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 22g. ⑥未処理レポート: 未処理が複数件あれば件数と最古/最新パスをまとめて報告する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 未処理のまま放置された3件（いずれもSTALE閾値10日は超えていない）
  D1="$(d_date -9)"; D2="$(d_date -7)"; D3="$(d_date -4)"
  echo "# review 1" > "$HOME_DIR/.claude/logs/fragments-log/${D1}.md"
  echo "# review 2" > "$HOME_DIR/.claude/logs/fragments-log/${D2}.md"
  echo "# review 3" > "$HOME_DIR/.claude/logs/fragments-log/${D3}.md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "3件まとめて1つのdrift項目として報告される" "$out" "未処理（frontmatterの processed: 行が無い）レポートが3件あります"
  assert_contains "最古のパスが表示される" "$out" "最古: ${HOME_DIR}/.claude/logs/fragments-log/${D1}.md"
  assert_contains "最新のパスが表示される" "$out" "最新: ${HOME_DIR}/.claude/logs/fragments-log/${D3}.md"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 23. ⑥reads/recallログの死活は個別に検知される（片方だけ停止・両方無し） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 0).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  # reads: 目安7日を超える10日前が最終記録（STALE）／recall: 一度も記録が無い（DEAD）
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts -10)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-READS-LOG-STALEが検知される" "$out" "[VAULT-READS-LOG-STALE]"
  assert_contains "VAULT-RECALL-LOG-DEADが検知される（ヒット0件と区別できない旨も明記）" \
    "$out" "[VAULT-RECALL-LOG-DEAD]"
  assert_contains "ヒット0件の日々と区別できない既知の限界が明記される" "$out" "ヒット0件"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 25. ⑥ログがERROR行だけ積み上がっている（鮮度は健全だが失敗し続けている）を検知する（Codexレビュー指摘） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 0).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  # 直近のログ行は全てERROR行（3列目=空）。最終行の鮮度だけ見ると健全に見える。
  {
    printf '%s\tERROR\t\tsess1\tjq解析失敗\n' "$(d_ts -3)"
    printf '%s\tERROR\t\tsess1\tjq解析失敗\n' "$(d_ts -1)"
  } > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  {
    printf '%s\tERROR\t\tsess1\tjq解析失敗\n' "$(d_ts -3)"
    printf '%s\tERROR\t\tsess1\tjq解析失敗\n' "$(d_ts -1)"
  } > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "readsのERRORING(失敗し続けている疑い)が検知される" "$out" "[VAULT-READS-LOG-ERRORING]"
  assert_contains "recallのERRORING(失敗し続けている疑い)が検知される" "$out" "[VAULT-RECALL-LOG-ERRORING]"
  assert_not_contains "ERROR行だけの場合はDEAD/STALEにはならない（別種別に分離）" "$out" "[VAULT-READS-LOG-STALE]"
  assert_not_contains "ERROR行だけの場合はDEAD/STALEにはならない（別種別に分離）" "$out" "[VAULT-READS-LOG-DEAD]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 26. ⑥未来日時のレポート/ログは「健全」に誤判定せずFUTURE-DATEとして検知する（Codexレビュー指摘） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  # 10年後の日付（システム時計のズレ・ファイル破損を模擬）
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 3650).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 3650)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "棚卸しレポートの未来日付が検知される" "$out" "[VAULT-INVENTORY-FUTURE-DATE]"
  assert_contains "vault-reads.tsvの未来日時が検知される" "$out" "[VAULT-READS-LOG-FUTURE-DATE]"
  assert_not_contains "未来日付はSTALE扱いにはしない（別種別に分離）" "$out" "[VAULT-INVENTORY-STALE]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 27. ⑥有効行だけが未来日時で最終行(ERROR)は現在時刻の境界ケース（Codexレビュー指摘・再レビュー分） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 0).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  # 1行目=未来日時の有効行／2行目(最終行)=現在時刻のERROR行。最終行だけを見る
  # チェックだと"新しすぎるので健全"に誤判定しうる境界ケース。
  {
    printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 3650)"
    printf '%s\tERROR\t\tsess1\tjq解析失敗\n' "$(d_ts 0)"
  } > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "有効行の未来日時がFUTURE-DATEとして検知される" "$out" "[VAULT-READS-LOG-FUTURE-DATE]"
  assert_not_contains "健全(✅)扱いにはならない" "$out" "✅ vault-reads.tsv:"
  assert_not_contains "ERRORING扱いにもならない（FUTURE-DATEを優先）" "$out" "[VAULT-READS-LOG-ERRORING]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 28. ⑥ログ時刻はUTCとして解析される（N-5・ローカルTZとして誤解釈するとJST環境で偽STALEになる境界ケース） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/vault-inventory" \
           "$HOME_DIR/.claude/logs/fragments-log" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  # 棚卸し・fragments-logは任意機能（scripts/check-drift.sh ⑥の新ゲート＝
  # LaunchAgent plist存在で判定。Codexレビュー指摘・Major対応）。このfixtureは
  # 「導入済み」を模擬するためマーカーplistを置く。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"
  echo "# report" > "$HOME_DIR/.claude/logs/vault-inventory/$(d_date 0).md"
  echo "# review" > "$HOME_DIR/.claude/logs/fragments-log/$(d_date 0).md"
  # 目安7日(VAULT_AGENT_LOG_STALE_DAYS既定値)ぎりぎり内側＝UTCで7日15時間前。
  # 正しくUTCとして解析すれば経過日数は7日(floor)＝閾値超過ではなく健全。
  # ローカルTZ(JST=UTC+9)として誤解釈すると実際より9時間早い時刻に解釈され、
  # 経過日数が8日(floor)に繰り上がり閾値超のSTALEに誤判定される
  # （N-5：以前はこの誤判定が起き得た。9時間という差が日境界をまたぐよう
  # あえて7日15時間に設定している）。
  TS="$(date -u -v-7d -v-15H +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\tsess1\tKnowledge/x.md\n' "$TS" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  # ホストの実TZに関わらず再現できるよう、JST(UTC+9)を明示して実行する
  # （ホストが既にUTC等でも本テストが同じ結果になることを保証するため）。
  out="$(TZ="Asia/Tokyo" run_check "$REPO" "$HOME_DIR")"
  assert_contains "UTCとして正しく解析されれば7日前(閾値以内)で健全と判定される" \
    "$out" "✅ vault-reads.tsv: 最終記録 7日前"
  assert_not_contains "ローカルTZ(JST)として誤解釈した場合に起きるSTALE誤判定は発生しない" \
    "$out" "[VAULT-READS-LOG-STALE]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 24. ⑥vault-agentsの出力(fragments-log/vault-inventory/reads/recallログ)が1件も無ければ対象外（サブ機・未導入想定） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # $HOME_DIR/.claude/logs/{fragments-log,vault-inventory,vault-reads.tsv,vault-recall.tsv}
  # は一切作らない（vault-agents未導入 or 純粋なサブ機想定。2026-07-11の出力先移設で
  # 判定基準がExplorations有無から$HOME/.claude/logs配下の4種の有無へ変わった）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "対象外メッセージが出る" "$out" "vault-agentsが一度も導入されていない想定ならチェック対象外"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 29. ⑥標準フック(reads/recall)は動いているが棚卸し・fragments-logの任意LaunchAgentは未導入 → レポート系はDEAD誤報しない（Codexレビュー指摘・Major） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # vault-recall.sh/vault-read-log.sh は install-main.sh で標準導入されるため、
  # このfixtureのようにreads/recallログだけが存在するのはごく普通のmain機構成
  # （棚卸し・fragments-logは任意機能＝scripts/install-vault-agents.sh を
  # 実行していなければ$HOME/Library/LaunchAgents/com.takumi009.{vault-inventory,
  # fragments-log}.plist は存在しない）。
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"
  # $HOME_DIR/Library/LaunchAgents/com.takumi009.{vault-inventory,fragments-log}.plist
  # は作らない（任意機能未導入を模擬）。$HOME_DIR/.claude/logs/{vault-inventory,
  # fragments-log}ディレクトリも作らない（レポートが一度も生成されていない状態）。

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "任意機能未導入なのに棚卸しレポートがDEAD誤報されない" "$out" "[VAULT-INVENTORY-DEAD]"
  assert_not_contains "任意機能未導入なのにfragments-logがDEAD誤報されない" "$out" "[FRAGMENTS-LOG-DEAD]"
  assert_contains "棚卸しレポートは任意機能未導入の対象外メッセージが出る" "$out" "棚卸しレポート: 任意機能未導入"
  assert_contains "fragments-logレポートも任意機能未導入の対象外メッセージが出る" "$out" "fragments-logレポート: 任意機能未導入"
  assert_contains "reads/recallログの健全チェックは通常どおり実行される" "$out" "✅ vault-reads.tsv:"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 30. ⑥LaunchAgent plistは導入済みだが出力(レポート/ログ)がまだ1件も無い → DEADとして検知する（Codexレビュー指摘・Major再指摘） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # 棚卸し・fragments-logのLaunchAgent plistは導入済み（scripts/install-vault-agents.sh
  # 実行済み想定）だが、初回実行前 or ジョブが一度も成功していないため
  # $HOME/.claude/logs/{vault-inventory,fragments-log}・reads/recallログは
  # 1件も存在しない。出力4種の不在だけで「一度も導入されていない」と誤判定し
  # セクション全体を対象外にすると、本来出るべきDEADが出せなくなる
  # （Codexレビュー指摘・Major再指摘）。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.vault-inventory.plist" \
        "$HOME_DIR/Library/LaunchAgents/com.takumi009.fragments-log.plist"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "plist導入済みなのに出力が無い棚卸しレポートはDEADとして検知される" "$out" "[VAULT-INVENTORY-DEAD]"
  assert_contains "同様にfragments-logもDEADとして検知される" "$out" "[FRAGMENTS-LOG-DEAD]"
  assert_not_contains "「一度も導入されていない」という対象外メッセージにはならない（plistがあるため）" \
    "$out" "vault-agentsが一度も導入されていない想定ならチェック対象外"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 31. ⑥knowledge-merge-candidatesが健全（レポートが新しい・processed済み）ならdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/knowledge-merge-candidates" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.knowledge-merge-detect.plist"
  cat > "$HOME_DIR/.claude/logs/knowledge-merge-candidates/$(d_date 0).md" <<'EOF'
---
date: 2026-07-12
processed: 2026-07-12
---
# 候補レポート
EOF
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "Knowledge統合候補レポート健全メッセージ" "$out" "✅ Knowledge統合候補レポート:"
  assert_contains "処理済みメッセージ" "$out" "✅ Knowledge統合候補レポート: 処理済みマーカーあり"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 32. ⑥knowledge-merge-candidatesレポートが期限超過(STALE)だと検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/knowledge-merge-candidates" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.knowledge-merge-detect.plist"
  # 目安10日を超える15日前が最新レポート
  echo "# report" > "$HOME_DIR/.claude/logs/knowledge-merge-candidates/$(d_date -15).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "KNOWLEDGE-MERGE-CANDIDATES-STALEが検知される" "$out" "[KNOWLEDGE-MERGE-CANDIDATES-STALE]"
  assert_contains "確認コマンドが含まれる" "$out" "launchctl list | grep knowledge-merge-detect"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 33. ⑥knowledge-merge-candidatesレポートが一度も生成されていない(DEAD)と検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/knowledge-merge-candidates" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.knowledge-merge-detect.plist"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "KNOWLEDGE-MERGE-CANDIDATES-DEADが検知される" "$out" "[KNOWLEDGE-MERGE-CANDIDATES-DEAD]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 34. ⑥knowledge-merge-candidates未処理レポート: 猶予日数超過でUNPROCESSEDを検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  mkdir -p "$HOME_DIR/.claude/logs/knowledge-merge-candidates" \
           "$HOME_DIR/.claude/logs" \
           "$HOME_DIR/Library/LaunchAgents"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.knowledge-merge-detect.plist"
  # 猶予(既定3日)を超える5日前・processedマーカー無し
  echo "# report" > "$HOME_DIR/.claude/logs/knowledge-merge-candidates/$(d_date -5).md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "KNOWLEDGE-MERGE-CANDIDATES-UNPROCESSEDが検知される" "$out" "[KNOWLEDGE-MERGE-CANDIDATES-UNPROCESSED]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 35. ⑥knowledge-merge-detectの任意LaunchAgentが未導入ならDEAD誤報しない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"
  # $HOME_DIR/Library/LaunchAgents/com.takumi009.knowledge-merge-detect.plist は作らない
  # （任意機能未導入を模擬）。$HOME_DIR/.claude/logs/knowledge-merge-candidates も作らない。

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "任意機能未導入なのにDEAD誤報されない" "$out" "[KNOWLEDGE-MERGE-CANDIDATES-DEAD]"
  assert_contains "任意機能未導入の対象外メッセージが出る" "$out" "Knowledge統合候補レポート: 任意機能未導入"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 36. ⑥未解決ALERT（FR12b）: resolvedの無いALERTファイルがあると検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs/vault-merge-alerts"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"
  cat > "$HOME_DIR/.claude/logs/vault-merge-alerts/cand-abc.md" <<'EOF'
---
date: 2026-07-06
processed: 2026-07-06
---
# ALERT
EOF

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-MERGE-ALERT-UNRESOLVEDが検知される" "$out" "[VAULT-MERGE-ALERT-UNRESOLVED]"
  assert_contains "件数1件が明記される" "$out" "未解決ALERT"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 37. ⑥未解決ALERT: 全件resolved済みならdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs/vault-merge-alerts"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"
  cat > "$HOME_DIR/.claude/logs/vault-merge-alerts/cand-abc.md" <<'EOF'
---
date: 2026-07-06
processed: 2026-07-06
resolved: 2026-07-07
---
# ALERT
EOF

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "VAULT-MERGE-ALERT-UNRESOLVEDは出ない" "$out" "[VAULT-MERGE-ALERT-UNRESOLVED]"
  assert_contains "健全メッセージが出る" "$out" "✅ 未解決ALERT: 0件"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 38. ⑥未解決ALERT: ディレクトリ自体が無ければ対象外（ALERT未発生想定・fail-open） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"
  # $HOME_DIR/.claude/logs/vault-merge-alerts は作らない

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "対象外メッセージが出る" "$out" "未解決ALERT: "
  assert_contains "対象外メッセージが出る(続き)" "$out" "が無い（ALERT未発生の想定）ためチェック対象外"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 39. ⑥knowledge-merge-detect: plistは導入済みだが出力がまだ1件も無い → DEADとして検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs" "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.knowledge-merge-detect.plist"
  # $HOME_DIR/.claude/logs/knowledge-merge-candidates ディレクトリ自体を作らない
  # （plist導入済みだが初回実行前 or ジョブが一度も成功していない状態を模擬）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "plist導入済みなのに出力が無いとDEADとして検知される" "$out" "[KNOWLEDGE-MERGE-CANDIDATES-DEAD]"
  assert_not_contains "「一度も導入されていない」という対象外メッセージにはならない（plistがあるため）" \
    "$out" "vault-agentsが一度も導入されていない想定ならチェック対象外"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 40. ⑦Vaultがgit管理下に無ければ対象外（サブ機・私的Vault未clone想定） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # $HOME_DIR/Data/obsidian は git init しない（サブ機想定）。

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "対象外メッセージが出る" "$out" "Vaultがgit管理下にありません"
  assert_not_contains "VAULT-PUSHは出ない" "$out" "[VAULT-PUSH"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 41. ⑦Vaultにremote originが未設定なら対象外 ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q -b main
  git -C "$HOME_DIR/Data/obsidian" config user.name test
  git -C "$HOME_DIR/Data/obsidian" config user.email test@example.invalid
  git -C "$HOME_DIR/Data/obsidian" commit -q --allow-empty -m init

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "対象外メッセージが出る" "$out" "remote 'origin' が未設定のためチェック対象外"
  assert_not_contains "VAULT-PUSHは出ない" "$out" "[VAULT-PUSH"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 42. ⑦mainとorigin/mainが同一コミット（push済み・健全）なら、たとえ古くてもdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -240)" "old commit (10日前)"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "同一コミットの健全メッセージが出る" "$out" "main と origin/main は同一コミット"
  assert_not_contains "VAULT-PUSHは出ない（差分が無いので古くても誤報しない）" "$out" "[VAULT-PUSH"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 42b. ⑦ローカルmainがorigin/mainより単に古い（reset等で巻き戻った）場合は「未反映commitあり」と誤検知しない（Codex一次レビュー指摘・Major対応） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -50)" "first"
  first_sha="$(git -C "$HOME_DIR/Data/obsidian" rev-parse HEAD)"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -40)" "second"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  # ローカルだけ先頭commitへ巻き戻す（origin/mainはsecondのまま＝ローカルが
  # 単純に「古い」状態。SHA比較だけだと「未反映commitあり」と誤検知しうる）。
  git -C "$HOME_DIR/Data/obsidian" reset -q --hard "$first_sha"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "巻き戻り単独ではVAULT-PUSHは出ない（rev-listで空と判定される）" "$out" "[VAULT-PUSH"
  assert_contains "事実に即したメッセージになる（同一コミットとは断定しない・Codex二次レビュー指摘・Minor対応）" \
    "$out" "未反映のcommitはありません（push未反映の差分なし。ローカルがorigin/mainより遅れているだけの可能性があります）"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 43. ⑦分岐しているが24時間以内なら様子見でdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -2)" "pushed 2時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours 0)" "unpushed just now"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "様子見メッセージが出る" "$out" "より進んでいますが、最も古い未反映commitから"
  assert_not_contains "[VAULT-PUSH-STALE]はまだ出ない（24時間未満）" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 44. ⑦未反映commit自体が24時間超過して待たされているとVAULT-PUSH-STALEとしてdrift計上する（2026-07-13 外部脳round4対応・欠陥① / Codex一次レビュー指摘・Major対応で『最も古い未反映commit』基準に変更） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  # origin側のtipは100時間前（十分に古いが、それ自体はもうpush済みなので無関係）。
  # 「未反映のまま30時間待たされているcommit」がある、という状態を再現する
  # （旧実装はorigin tipの古さだけを見ていたため、直近の未反映commitが実際には
  # 新しくてもtipが古いだけでSTALE誤報していた＝Codexレビュー指摘・Major）。
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -100)" "pushed 100時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -30)" "unpushed 30時間前"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-PUSH-STALEが検知される" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "確認コマンドが含まれる" "$out" "tail -50 /tmp/vault-backup.log"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 44b. ⑦origin tipは古いが未反映commit自体は新しい場合はSTALEにしない（Codex一次レビュー指摘・Major『origin tip基準だと誤検知する』の回帰防止） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  # origin tipは100時間前（旧実装ならこれだけでSTALE誤検知した）だが、
  # 未反映commit自体は1時間前にできたばかり＝pushはまだ「詰まっている」とは言えない。
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -100)" "pushed 100時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -1)" "unpushed 1時間前"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "origin tipが古いだけではSTALEにならない" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 45. ⑦一度もpushしていない（origin/main参照が無い）が最古commitが24時間以内なら判定不能のfail-open表示・driftにはしない（初回セットアップ直後の猶予） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -1)" "never pushed yet, but recent"
  # push しない（origin/main 参照がローカルに無い状態を模擬）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "VAULT-PUSH-STALEにはならない（初回セットアップ直後の猶予）" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "様子見メッセージに『一度も成功pushしていない可能性』が注記される" "$out" "一度も成功pushしていない可能性"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 45b. ⑦一度もpushしていない状態が24時間超続くとVAULT-PUSH-STALEとして検知する（Codex一次レビュー指摘・Major対応：従来はここが永久にfail-openで穴だった） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -30)" "never pushed, 30時間前のまま"
  # push しない（初回pushが認証不良等で30時間ずっと失敗し続けている状態を模擬）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-PUSH-STALEが検知される" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "『一度も成功pushしていない可能性』が注記される" "$out" "一度も成功pushしていない可能性"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 45c. ⑦ローカルブランチ自体が無い（commitが1つも無い）場合は判定不能のfail-open・driftにはしない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  # commitを1つも作らない（unborn main。install-backup.sh導入直後・初回backup-vault.sh
  # 実行前を模擬）。

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-PUSH-CHECK-UNAVAILABLEが表示される" "$out" "[VAULT-PUSH-CHECK-UNAVAILABLE]"
  assert_not_contains "VAULT-PUSH-STALEにはならない" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "総drift件数0" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 46. ⑦未反映commit自体の時刻が未来日時ならVAULT-PUSH-FUTURE-DATEとして検知する（origin側ではなく未反映commit自体が未来のケース。Codex一次レビュー指摘反映） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -50)" "pushed 50時間前（正常な日時）"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours 240)" "未反映commitの時刻が未来（システム時計ズレ想定）"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-PUSH-FUTURE-DATEが検知される" "$out" "[VAULT-PUSH-FUTURE-DATE]"
  assert_not_contains "STALEにはならない（FUTURE-DATEを優先）" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 47. ⑦VAULT_BACKUP_PUSH_STALE_HOURSで閾値を上書きできる ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -20)" "pushed 20時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -4)" "unpushed 4時間前"

  out="$(VAULT_BACKUP_PUSH_STALE_HOURS=3 DIR="$REPO" HOME="$HOME_DIR" VAULT="$HOME_DIR/Data/obsidian" \
    bash "$REPO/scripts/check-drift.sh")"
  assert_contains "しきい値3時間に短縮すると4時間前の未反映commitでVAULT-PUSH-STALEが検知される" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 48. ⑦未反映commitの並び(git rev-listの出力順)とコミット時刻が非単調でも、最も古い時刻のcommitを正しく基準にする（Codex二次レビュー指摘・Major対応：tail -1は出力順=最古コミット時刻の保証が無い） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -200)" "pushed 200時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  # 未反映commitを2つ作るが、git rev-list の出力順（履歴の新しい方=後にcommitした方
  # が先頭）とコミット時刻の新旧をわざと逆転させる。1つ目(A)は「履歴的には古い
  # （親）」がコミット時刻は1時間前（新しい）。2つ目(B)は「履歴的には新しい（子）」
  # だがコミット時刻は50時間前（古い）。旧実装(tail -1)は出力順の末尾＝Aを
  # 「最古」と誤認しSTALEを見逃す。正しい実装はBの50時間前を基準にSTALEを検知する。
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -1)" "unpushed A（履歴上は親・時刻は1時間前）"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -50)" "unpushed B（履歴上は子・時刻は50時間前で非単調）"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "非単調な時刻順でも最古(50時間前)のcommitを基準にVAULT-PUSH-STALEが検知される" "$out" "[VAULT-PUSH-STALE]"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 49. ⑦git rev-list自体の実行失敗（gitオブジェクト破損等）はVAULT-PUSH-CHECK-FAILEDとしてdrift計上する（Codex二次レビュー指摘・Major対応：『監視不能も異常』の原則） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -50)" "pushed 50時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -1)" "unpushed"
  # 未反映commit自体のloose objectを消し、git rev-list origin/main..main が
  # "fatal: Invalid revision range" で失敗する状態を再現する（リポジトリ構造自体は
  # 壊さない＝remote get-url/rev-parse --verifyは通常どおり成功する必要がある）。
  unpushed_sha="$(git -C "$HOME_DIR/Data/obsidian" rev-parse HEAD)"
  obj_file="$HOME_DIR/Data/obsidian/.git/objects/${unpushed_sha:0:2}/${unpushed_sha:2}"
  rm -f "$obj_file"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-PUSH-CHECK-FAILEDが検知される" "$out" "[VAULT-PUSH-CHECK-FAILED]"
  assert_contains "総drift件数1（監視不能も異常として計上）" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 50. ⑦未反映commitが複数あり、そのうち最古(=STALE基準)ではないcommitだけが未来日時でも見逃さずFUTURE-DATEにする（Codex三次レビュー指摘・Major対応：最小epochだけでは一部だけ未来のケースを見逃す） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -50)" "pushed 50時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  # 未反映commitを2つ: 1つ目は1時間前（最古=STALE基準になる・24時間以内で健全）、
  # 2つ目は240時間後の未来（旧実装は最小epoch=1時間前だけを見るためこれを
  # 見逃し「様子見」の健全表示になってしまっていた）。
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -1)" "unpushed 1時間前（最古）"
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours 240)" "unpushed 未来240時間（最古ではない）"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "最古ではない未来commitも見逃さずVAULT-PUSH-FUTURE-DATEが検知される" "$out" "[VAULT-PUSH-FUTURE-DATE]"
  assert_not_contains "様子見の健全表示にはならない" "$out" "のため様子見です"
  assert_contains "総drift件数1" "$out" "総drift件数: 1"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 51. ⑥weekly-reviewが健全（最新canvasのmtimeが新しい）ならdriftにならない（2026-07-14追加） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # weekly-reviewは takumi009-ai-env-private 側の任意機能。LaunchAgent plistの
  # 実在で導入判定する（他のvault-agentsと同じゲート方式）。
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  # ファイル名は「対象週の月曜日」（生成日ではない）だが、判定はmtime基準。
  echo '{}' > "$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "週次振り返りcanvasが健全と表示される" "$out" "✅ 週次振り返りcanvas: 更新0日前"
  assert_not_contains "WEEKLY-REVIEWのdriftは出ない" "$out" "[WEEKLY-REVIEW-"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 52. ⑥weekly-reviewが一度も生成されていない(DEAD)と検知する（Fragments記録は存在＝材料はあったのに未生成） ==="
{
  # 2026-07-14 リーダー指摘対応: weekly_review.pyは対象週にFragments記録が
  # 無ければ意図的に未生成のまま終わる仕様のため、Fragments記録が実在する
  # （＝生成すべき材料はあった）場合に限りDEAD/STALEをdrift計上する。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Data/obsidian/Fragments" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  # ディレクトリはあるが中身が空（一度も生成されていない）。Fragments記録は存在する。
  echo "# fragment" > "$HOME_DIR/Data/obsidian/Fragments/$(d_date -3).md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "WEEKLY-REVIEW-DEADが検知される" "$out" "[WEEKLY-REVIEW-DEAD]"
  assert_contains "確認コマンドが含まれる" "$out" "launchctl list | grep weekly-review"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 52b. ⑥weekly-review未生成でもFragments記録が一度も無ければ、weekly_review.py仕様どおりの正常な未生成としてdriftにしない（2026-07-14 リーダー指摘対応） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  # canvasもFragmentsも一度も無い（$HOME_DIR/Data/obsidian/Fragments 自体を作らない）。

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "WEEKLY-REVIEW-DEADは出ない（Fragments記録が無い正常な未生成）" "$out" "[WEEKLY-REVIEW-DEAD]"
  assert_contains "仕様どおりの未生成である旨の情報表示が出る" "$out" "weekly_review.pyの仕様（対象週にFragments記録が無ければ生成しない）による正常な未生成の可能性"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 53. ⑥weekly-reviewが期限超過(STALE)だと検知する（ファイル名ではなくmtime基準・Fragments記録は存在＝材料はあったのに未生成） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Data/obsidian/Fragments" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  CANVAS="$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"
  echo '{}' > "$CANVAS"
  # 目安10日を超える15日前のmtimeに書き換える（生成が止まっている疑いを模擬）。
  touch -t "$(d_mtime_ts -15)" "$CANVAS"
  # canvas生成後（15日前より新しい・3日前）にFragments記録がある＝材料はあった。
  echo "# fragment" > "$HOME_DIR/Data/obsidian/Fragments/$(d_date -3).md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "WEEKLY-REVIEW-STALEが検知される" "$out" "[WEEKLY-REVIEW-STALE]"
  assert_contains "確認コマンドが含まれる" "$out" "launchctl list | grep weekly-review"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 53b. ⑥weekly-reviewが古くても、生成以降Fragments記録が無ければweekly_review.py仕様どおりの正常な未生成としてdriftにしない（2026-07-14 リーダー指摘対応） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  CANVAS="$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"
  echo '{}' > "$CANVAS"
  touch -t "$(d_mtime_ts -15)" "$CANVAS"
  # Fragmentsディレクトリ自体を作らない（生成以降、記録が一度も無い想定）。

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "WEEKLY-REVIEW-STALEは出ない（生成以降Fragments記録が無い正常な未生成）" "$out" "[WEEKLY-REVIEW-STALE]"
  assert_contains "仕様どおりの未生成である旨の情報表示が出る" "$out" "weekly_review.pyの仕様（対象週にFragments記録が無ければ生成しない）による正常な未生成の可能性"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 53c. ⑥weekly-review: canvas生成と同じ暦日に書かれたFragmentも『生成以降の記録』として扱う（Codex三次レビュー指摘・Major対応：日付比較の粒度不一致） ==="
{
  # canvasのmtime（時刻成分あり）とFragmentsのファイル名日付（0時扱い）を
  # 単純比較すると、canvas生成と同じ暦日に書かれたFragmentが誤って「canvasより
  # 古い」扱いになり、以後Fragmentが増えなければSTALEを永久に抑止しうる欠陥が
  # あった。canvasのmtimeをその日の0時へ正規化してから比較する修正を検証する。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Data/obsidian/Fragments" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  CANVAS="$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"
  echo '{}' > "$CANVAS"
  # 15日前の04:00（weekly_review.pyの実運用スケジュールと同じ時刻帯）にmtimeを設定。
  touch -t "$(date -v-15d +%Y%m%d)0400" "$CANVAS"
  # Fragmentは同じ暦日（15日前）の記録。時刻は保持されずファイル名日付のみ
  # （0時扱い）だが、実際にはcanvas生成(04:00)より後に書かれた可能性がある。
  echo "# fragment same day" > "$HOME_DIR/Data/obsidian/Fragments/$(d_date -15).md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "同じ暦日のFragmentでもWEEKLY-REVIEW-STALEが検知される" "$out" "[WEEKLY-REVIEW-STALE]"
  assert_not_contains "正常な未生成の誤判定にはならない" "$out" "正常な未生成の可能性があります"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 53d. ⑥weekly-review: Fragments探索自体が失敗した場合は『記録なし』と混同せずWEEKLY-REVIEW-FRAGMENTS-CHECK-FAILEDを検知する（Codex三次レビュー指摘・Major対応） ==="
{
  # find がディレクトリ権限不備等で探索できない場合、従来は出力ゼロ件＝
  # 「Fragments記録なし＝正常な未生成」と誤って同一視していた
  # （「監視不能も異常」の原則に反する）。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Data/obsidian/Fragments/sub" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  CANVAS="$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"
  echo '{}' > "$CANVAS"
  touch -t "$(d_mtime_ts -15)" "$CANVAS"
  echo "# fragment" > "$HOME_DIR/Data/obsidian/Fragments/sub/$(d_date -3).md"
  chmod 000 "$HOME_DIR/Data/obsidian/Fragments/sub"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "WEEKLY-REVIEW-FRAGMENTS-CHECK-FAILEDが検知される" "$out" "[WEEKLY-REVIEW-FRAGMENTS-CHECK-FAILED]"
  assert_not_contains "正常な未生成として握りつぶされない" "$out" "正常な未生成の可能性があります"
  assert_not_contains "STALEとは別種別（探索できず判定不能なだけ）" "$out" "[WEEKLY-REVIEW-STALE]"

  chmod 755 "$HOME_DIR/Data/obsidian/Fragments/sub"
  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 54. ⑥weekly-review未導入（LaunchAgent plist無し）ならチェック対象外 ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/Library/LaunchAgents" "$HOME_DIR/.claude/logs"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # plistもExplorations/weekly-reviewディレクトリも置かない＝未導入を模擬。
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "任意機能未導入メッセージが出る" "$out" "週次振り返りcanvas: 任意機能未導入"
  assert_not_contains "WEEKLY-REVIEWのdriftは出ない" "$out" "[WEEKLY-REVIEW-"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 55. ⑥weekly-reviewのcanvasはVault同期される出力のため、それだけではvault-agents『導入済み』とみなさない（Codexレビュー指摘・Major対応） ==="
{
  # WEEKLY_REVIEW_DIR は $VAULT 配下＝Vault自体が複数マシン間でgit同期されるため、
  # 他の出力先（$HOME/.claude/logs/... 配下・ローカル専用）とは異なり、
  # reads/recallフックもweekly-review LaunchAgentも一切導入していないサブ機でも
  # 「他マシンが生成したcanvasをVault同期で受け取っているだけ」で存在し得る。
  # この場合にvault-agents『導入済み』と誤認してreads/recallのDEADを誤報しないこと
  # を確認する（2026-07-14 Codex一次レビュー指摘・Major対応）。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # weekly-reviewのLaunchAgent plistは置かない（このマシンには未導入）。
  # reads/recallログも置かない（このマシンでは標準フックすら未セットアップの想定）。
  # canvasだけがVault同期で存在する状態を模擬する。
  echo '{}' > "$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "vault-agents未導入の対象外メッセージが出る（canvasの存在だけでは導入済みとみなさない）" \
    "$out" "vault-agentsが一度も導入されていない想定ならチェック対象外"
  assert_not_contains "VAULT-READS-LOG-DEADは誤報されない" "$out" "[VAULT-READS-LOG-DEAD]"
  assert_not_contains "VAULT-RECALL-LOG-DEADは誤報されない" "$out" "[VAULT-RECALL-LOG-DEAD]"
  assert_not_contains "WEEKLY-REVIEW-DEADも出ない（未導入としてスキップされるため）" "$out" "[WEEKLY-REVIEW-"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 56. ⑥age_days_from_epoch: 24時間未満の未来mtimeも切り捨てず必ずFUTURE-DATEとして検知する（Codex二次レビュー指摘・Minor対応） ==="
{
  # bashの整数除算は0方向へ丸めるため、旧実装は「-3600秒（1時間未来）」のような
  # 24時間未満の未来スキューを `-3600/86400=0` に丸めてしまい、「未来なのに
  # 経過日数0＝健全」と誤判定していた。weekly-reviewのmtime基準FUTURE-DATE判定
  # （新規追加）で顕在化するため、ここで直接検証する。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" \
           "$HOME_DIR/Data/obsidian/Explorations/weekly-review" \
           "$HOME_DIR/Library/LaunchAgents"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  touch "$HOME_DIR/Library/LaunchAgents/com.takumi009.weekly-review.plist"
  CANVAS="$HOME_DIR/Data/obsidian/Explorations/weekly-review/$(d_date -7).canvas"
  echo '{}' > "$CANVAS"
  # 1時間後（24時間未満の未来）のmtimeにする。
  touch -t "$(date -v+1H +%Y%m%d%H%M)" "$CANVAS"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "24時間未満の未来mtimeでもWEEKLY-REVIEW-FUTURE-DATEが検知される" "$out" "[WEEKLY-REVIEW-FUTURE-DATE]"
  assert_not_contains "未来日時が健全（更新0日前）に誤判定されない" "$out" "✅ 週次振り返りcanvas: 更新0日前"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 57. ⑦-2 backup-vault.shのロック回収ミューテックスが長時間残っているとVAULT-BACKUP-LOCK-STUCKとして検知する（2026-07-14追加・Codex二次レビュー指摘・Major対応） ==="
{
  # backup-vault.shの回収ミューテックス自己修復を撤去しfail-closedにした結果、
  # 前回実行がミューテックス保持中にクラッシュすると以後commit前に止まり続け、
  # ⑦（push死活）のrev-list判定には何も現れない別種の穴になる。ミューテックス
  # ディレクトリ自体の新鮮度を直接読む本チェックで検知できることを確認する。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  FAKE_LOCK="$HOME_DIR/fake-backup-vault.lock"
  mkdir -p "${FAKE_LOCK}.reclaim"
  # 20分前のmtimeにして「回収処理中にクラッシュして固着した」状況を模擬する
  # （既定の目安10分を超えさせる）。
  touch -t "$(date -v-20M +%Y%m%d%H%M)" "${FAKE_LOCK}.reclaim"

  out="$(VAULT_BACKUP_LOCK_FILE="$FAKE_LOCK" DIR="$REPO" HOME="$HOME_DIR" VAULT="$HOME_DIR/Data/obsidian" \
    bash "$REPO/scripts/check-drift.sh")"
  assert_contains "VAULT-BACKUP-LOCK-STUCKが検知される" "$out" "[VAULT-BACKUP-LOCK-STUCK]"
  assert_contains "手動解除の案内が含まれる" "$out" "rmdir ${FAKE_LOCK}.reclaim"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 58. ⑦-2 ロック回収ミューテックスが目安時間以内（実行中の可能性）なら様子見でdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  FAKE_LOCK="$HOME_DIR/fake-backup-vault.lock"
  mkdir -p "${FAKE_LOCK}.reclaim"
  # 作成直後（0分前）＝目安10分以内のため様子見。

  out="$(VAULT_BACKUP_LOCK_FILE="$FAKE_LOCK" DIR="$REPO" HOME="$HOME_DIR" VAULT="$HOME_DIR/Data/obsidian" \
    bash "$REPO/scripts/check-drift.sh")"
  assert_not_contains "VAULT-BACKUP-LOCK-STUCKは出ない（目安時間以内）" "$out" "[VAULT-BACKUP-LOCK-STUCK]"
  assert_contains "様子見メッセージが出る" "$out" "様子見です"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 59. ⑦-2 ロック回収ミューテックスが無ければ健全表示でdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  FAKE_LOCK="$HOME_DIR/fake-backup-vault.lock"
  # 回収ミューテックス自体を作らない（通常状態）。

  out="$(VAULT_BACKUP_LOCK_FILE="$FAKE_LOCK" DIR="$REPO" HOME="$HOME_DIR" VAULT="$HOME_DIR/Data/obsidian" \
    bash "$REPO/scripts/check-drift.sh")"
  assert_not_contains "VAULT-BACKUP-LOCK-STUCKは出ない" "$out" "[VAULT-BACKUP-LOCK-STUCK]"
  assert_contains "健全メッセージが出る" "$out" "✅ ロック回収ミューテックスは残っていません"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 60. ⑦-2 ロック回収ミューテックスの更新時刻が未来ならVAULT-BACKUP-LOCK-FUTURE-DATEとして検知する（Codex三次レビュー指摘・Minor対応） ==="
{
  # mtimeが未来だと経過分数が負になり、旧実装は「-N分前・様子見」という
  # 健全表示に誤判定していた（システム時計のズレ・ファイル破損を見逃す）。
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  FAKE_LOCK="$HOME_DIR/fake-backup-vault.lock"
  mkdir -p "${FAKE_LOCK}.reclaim"
  touch -t "$(date -v+2H +%Y%m%d%H%M)" "${FAKE_LOCK}.reclaim"

  out="$(VAULT_BACKUP_LOCK_FILE="$FAKE_LOCK" DIR="$REPO" HOME="$HOME_DIR" VAULT="$HOME_DIR/Data/obsidian" \
    bash "$REPO/scripts/check-drift.sh")"
  assert_contains "VAULT-BACKUP-LOCK-FUTURE-DATEが検知される" "$out" "[VAULT-BACKUP-LOCK-FUTURE-DATE]"
  assert_not_contains "様子見の健全表示にはならない" "$out" "様子見です"
  assert_not_contains "STUCK扱いにもしない（別種別に分離）" "$out" "[VAULT-BACKUP-LOCK-STUCK]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
