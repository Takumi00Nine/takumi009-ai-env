#!/usr/bin/env bash
# scripts/audit.sh のユニットテスト。
#
# 実 Vault($HOME/Data/obsidian)・実リポジトリ・実GitHubには一切依存しない。
# REPO/NGWORDS_FILE/VAULT を環境変数で毎回ダミーのfixtureへ差し替えて audit.sh を
# そのまま実行し、クリーン版（陰性コントロール）と汚染版（NG語入り履歴・
# 実ユーザー名パス入り履歴・シークレット入り履歴・docs混入・Personalリンク混入・
# 完備性欠如）それぞれで pass/fail の判定を検証する。
#
# public浄化について（test-export-public-vault.sh と同方針）: このテストファイル
# 自体が将来 public repo の履歴に入る想定のため、①NGワードの実データはここに書かず
# ダミー語（NGWORD_ALPHA/NGWORD_BETA）を使う ②gitleaks検知用のダミーGitHub PATは
# 静的ファイルに完全な形で残さず、実行時に文字列連結で組み立てる。
#
# 実行方法: bash tests/test-audit.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_REL="scripts/audit.sh"

# bash実行ファイルの絶対パスを先に確定しておく（テスト17でPATHを最小構成に
# 差し替えた際、「PATH=... bash ...」の "bash" 自体の解決にもその一時PATHが
# 使われてしまい "command not found: bash" になるため。以後は常にこの絶対パスで
# インタプリタを起動する＝Codexレビュー指摘の追加テストで発見）。
BASH_BIN="$(command -v bash)"

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

# 最小構成のfixture repoを作る（audit.shが必要とするファイルだけ揃える）。
# .gitignore は実リポジトリと同方針（docs/・scripts/ngwords.txt・.DS_Store を除外）
# にする。ngwords.txt はNGワード検索対象として実ファイルを置くが、通常はgitignore
# されて追跡されない（実リポジトリでの運用＝symlinkと同じ扱い）ため、
# 「クリーン版」で誤って項目4（追跡ファイルの逸脱）を発火させない。
# git init はするがcommitはしない。commitのタイミングは各テストケースに委ねる。
make_fake_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/vault-public/Personal"
  cp "$REPO_ROOT/$SCRIPT_REL" "$repo/scripts/audit.sh"
  chmod +x "$repo/scripts/audit.sh"
  # audit.sh は2026-07-16簡素化でscripts/lib/personal-link-check.shをsourceするように
  # なったため、fixture repoにも同ファイルを複製する（cleanup決定#5）。
  mkdir -p "$repo/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/personal-link-check.sh" "$repo/scripts/lib/personal-link-check.sh"
  echo "# README（テスト用ダミー）" > "$repo/README.md"
  echo "MIT（テスト用ダミー）" > "$repo/LICENSE"
  cat > "$repo/.gitignore" <<'EOF'
.DS_Store
docs/
scripts/ngwords.txt
EOF
  cat > "$repo/scripts/install-main.sh" <<'EOF'
#!/usr/bin/env bash
echo "dummy installer"
EOF
  chmod +x "$repo/scripts/install-main.sh"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$repo/scripts/ngwords.txt"
  echo "# Personal（骨格・テスト用ダミー）" > "$repo/vault-public/Personal/README.md"

  git -C "$repo" init -q
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
}

commit_all() {
  local repo="$1" msg="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
}

# .gitignore で除外されたパスをテスト用にわざと追跡させる（「逸脱」を模擬する）。
force_track() {
  local repo="$1"; shift
  git -C "$repo" add -f "$@"
}

# audit.sh を実行する。REPOはfixture repo・VAULTはfixtureのVault代替
# （$VAULT/Personal が無ければbasename形式チェックはスキップされる仕様）。
# 標準出力/エラーはそれぞれ outdir/stdout.log, outdir/stderr.log に落とす。
run_audit() {
  local repo="$1" vault="$2" outdir="$3"; shift 3
  REPO="$repo" NGWORDS_FILE="$repo/scripts/ngwords.txt" VAULT="$vault" \
    "$BASH_BIN" "$repo/scripts/audit.sh" "$@" >"$outdir/stdout.log" 2>"$outdir/stderr.log"
}

echo "=== 1. 全項目クリーン（陰性コントロール・フルスキャン） ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"
  mkdir -p "$VAULT_DIR/Personal"
  echo "# dummy" > "$VAULT_DIR/Personal/dummy-note.md"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"

  assert_eq "exit code 0" "0" "$rc"
  assert_contains "1.NGワード0件" "$out" "✅ NGワード（履歴）: 0件"
  assert_contains "2.実ユーザー名パス0件" "$out" "✅ 実ユーザー名パス（履歴）: 0件"
  assert_contains "3.gitleaks検出なし" "$out" "✅ シークレット（履歴）: gitleaks検出なし"
  assert_contains "4.追跡ファイル逸脱0件" "$out" "✅ 追跡ファイルの逸脱: 0件"
  assert_contains "5.Personalリンク0件" "$out" "✅ Personal リンク（vault-public）: 0件"
  assert_contains "6.完備性OK" "$out" "✅ 完備性: 必須ファイル全て存在"
  assert_contains "public化可の判定" "$out" "public化可（全項目クリア）"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 2. NG語が履歴にのみ残っている場合、フルスキャンで検知し--quickでは検知しない ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  echo "NGWORD_ALPHA が混入したメモ" > "$REPO_DIR/tmp-leak.md"
  commit_all "$REPO_DIR" "oops: leaked ngword"
  rm "$REPO_DIR/tmp-leak.md"
  commit_all "$REPO_DIR" "fix: remove leaked ngword"
  [[ ! -e "$REPO_DIR/tmp-leak.md" ]]  # 前提確認: 現在ツリーはクリーン

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "フルスキャンでexit 1" "1" "$rc"
  assert_contains "NGワード検知" "$out" "❌ NGワード（履歴）"
  assert_contains "public化不可の判定" "$out" "public化不可"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "--quickではexit 0（履歴スキャンしないため）" "0" "$rc"
  assert_contains "--quickはskipログを出す" "$out" "skip（--quick指定のため履歴スキャンなし）"
  assert_not_contains "--quickではNGワード違反が出ない" "$out" "❌ NGワード"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 3. 実ユーザー名パスが履歴にのみ残っている場合、フルスキャンで検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  real_user="$(whoami)"
  echo "設定ファイルは /Users/${real_user}/work に置く" > "$REPO_DIR/tmp-path.md"
  commit_all "$REPO_DIR" "oops: leaked real username path"
  rm "$REPO_DIR/tmp-path.md"
  commit_all "$REPO_DIR" "fix: remove leaked path"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "フルスキャンでexit 1" "1" "$rc"
  assert_contains "実ユーザー名パス検知" "$out" "❌ 実ユーザー名パス（履歴）"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 4. シークレットが履歴にのみ残っている場合、gitleaksで検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  # ダミーGitHub PATは静的ファイルに完全な形で残さず、実行時に文字列連結で組み立てる
  # （test-export-public-vault.sh と同方針。regexベースの静的スキャナへの誤検知回避）
  dummy_token=$(printf '%s%s' 'ghp_' 'NbrnTP3fAbnFbmOHnKYaXRvj7uff0LYTH8xI')
  printf 'github_token = "%s"\n' "$dummy_token" > "$REPO_DIR/tmp-secret.env"
  commit_all "$REPO_DIR" "oops: leaked dummy token"
  rm "$REPO_DIR/tmp-secret.env"
  commit_all "$REPO_DIR" "fix: remove leaked token"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "フルスキャンでexit 1" "1" "$rc"
  assert_contains "gitleaks検知" "$out" "❌ シークレット（履歴）: gitleaks がシークレットの疑いを検出しました"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 5. docs/・ngwords.txt・.DS_Store が追跡されていると検知する（.gitignore破れ） ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  mkdir -p "$REPO_DIR/docs"
  echo "# 内部メモ" > "$REPO_DIR/docs/internal.md"
  touch "$REPO_DIR/.DS_Store"
  git -C "$REPO_DIR" add -A
  force_track "$REPO_DIR" docs/internal.md .DS_Store scripts/ngwords.txt
  git -C "$REPO_DIR" commit -q -m "initial (with deviant tracked files)"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "quickでもexit 1（現在ツリーの追跡状態は判定できるため）" "1" "$rc"
  assert_contains "docs/検知" "$out" "docs/internal.md"
  assert_contains "ngwords.txt検知" "$out" "scripts/ngwords.txt"
  assert_contains "DS_Store検知" "$out" ".DS_Store"
  assert_contains "3件検知" "$out" "追跡ファイルの逸脱: 3件"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 6. vault-public に Personal フォルダ付きリンクがあると検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  mkdir -p "$REPO_DIR/vault-public/Preferences"
  echo "関連: [[Personal/career-private]]" > "$REPO_DIR/vault-public/Preferences/leak.md"
  commit_all "$REPO_DIR" "initial (with personal folder-qualified link leak)"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "Personalリンク（フォルダ付き）検知" "$out" "❌ Personal リンク（vault-public）"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 7. 実Vaultがある場合、basename形式（フォルダ省略）のPersonalリンクも検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  mkdir -p "$REPO_DIR/vault-public/Preferences"
  echo "関連: [[career-private]]" > "$REPO_DIR/vault-public/Preferences/leak.md"
  commit_all "$REPO_DIR" "initial (with basename link leak)"
  mkdir -p "$VAULT_DIR/Personal"
  echo "# 経歴（テスト用ダミー）" > "$VAULT_DIR/Personal/career-private.md"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "basename形式Personalリンク検知" "$out" "❌ Personal リンク（vault-public）"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 8. 実VaultのPersonalが無い環境ではbasename形式チェックをスキップする（既知の限界） ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  mkdir -p "$REPO_DIR/vault-public/Preferences"
  echo "関連: [[career-private]]" > "$REPO_DIR/vault-public/Preferences/leak.md"
  commit_all "$REPO_DIR" "initial (basename link, no vault access)"
  # $VAULT_DIR/Personal を作らない（実Vaultにアクセスできない環境を模擬）

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_contains "スキップログが出る" "$out" "basename形式チェック"
  assert_eq "folder形式の混入が無ければexit 0（basename検出はVault依存のため）" "0" "$rc"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 9. README.md が無いと完備性チェックで検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  rm "$REPO_DIR/README.md"
  commit_all "$REPO_DIR" "initial (no README)"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "README.md欠如検知" "$out" "❌ 完備性: 不足1件（README.md）"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 10. --quick は1〜3すべてスキップし、4〜6のみ実行する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 0" "0" "$rc"
  skip_count=$(grep -c 'skip（--quick指定のため履歴スキャンなし）' <<<"$out" || true)
  assert_eq "skipログが3回出る（1〜3の各項目）" "3" "$skip_count"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 11. 未知のオプションは exit 2 で拒否する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --bogus || rc=$?
  err="$(cat "$WORK/stderr.log")"
  assert_eq "exit code 2" "2" "$rc"
  assert_contains "不明なオプションメッセージ" "$err" "不明なオプション"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 12. REPO が git リポジトリでない場合は exit 2（監査失敗ではなくセットアップエラー） ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  mkdir -p "$REPO_DIR/scripts/lib"
  cp "$REPO_ROOT/$SCRIPT_REL" "$REPO_DIR/scripts/audit.sh"
  cp "$REPO_ROOT/scripts/lib/personal-link-check.sh" "$REPO_DIR/scripts/lib/personal-link-check.sh"
  chmod +x "$REPO_DIR/scripts/audit.sh"
  # git init しない

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" --quick || rc=$?
  err="$(cat "$WORK/stderr.log")"
  assert_eq "exit code 2" "2" "$rc"
  assert_contains "gitリポジトリではないメッセージ" "$err" "git リポジトリではありません"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 13. git履歴が1コミットも無い場合、履歴チェックは全て0件でクリアする ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  # commit_all を呼ばない（0コミットのまま）

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 0（0コミットはエラーではない）" "0" "$rc"
  assert_contains "NGワード0件" "$out" "✅ NGワード（履歴）: 0件"
  assert_contains "実ユーザー名パス0件" "$out" "✅ 実ユーザー名パス（履歴）: 0件"
  assert_contains "gitleaks検出なし" "$out" "✅ シークレット（履歴）: gitleaks検出なし"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 14. NGWORDS_FILE が存在しない場合、NGワードチェックで検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"
  rm "$REPO_DIR/scripts/ngwords.txt"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "NGWORDS_FILE不在メッセージ" "$out" "NGWORDS_FILE が見つかりません"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 15. NGWORDS_FILE が空（有効な行が無い）場合、NGワードチェックで検知する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  printf '\n   \n' > "$REPO_DIR/scripts/ngwords.txt"
  commit_all "$REPO_DIR" "initial clean commit"

  rc=0
  run_audit "$REPO_DIR" "$VAULT_DIR" "$WORK" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "有効な行が無いメッセージ" "$out" "ngwords.txt に有効な行がありません"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 16. REPO を相対パスで渡しても動作する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  parent_dir="$(dirname "$REPO_DIR")"
  base_name="$(basename "$REPO_DIR")"
  rc=0
  (
    cd "$parent_dir" &&
      REPO="./${base_name}" NGWORDS_FILE="./${base_name}/scripts/ngwords.txt" VAULT="$VAULT_DIR" \
        "$BASH_BIN" "./${base_name}/scripts/audit.sh" --quick
  ) >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  out="$(cat "$WORK/stdout.log")"
  assert_eq "相対パスのREPOでもexit 0" "0" "$rc"
  assert_contains "相対パスでも完備性チェックが通る" "$out" "✅ 完備性: 必須ファイル全て存在"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK"
}

echo "=== 17. gitleaksコマンドが無い環境では、フルスキャンは分かりやすいエラーでexit 2する ==="
{
  REPO_DIR="$(mktemp -d)"
  VAULT_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  FAKE_BIN="$(mktemp -d)"
  make_fake_repo "$REPO_DIR"
  commit_all "$REPO_DIR" "initial clean commit"

  # gitleaks以外の必要コマンドだけをFAKE_BINにリンクし、gitleaksが無い環境を模擬する
  # （rg/gitleaksは同じ/opt/homebrew/bin配下にあることが多く、PATHを丸ごと差し替えないと
  # gitleaksだけを「無い」状態に絞り込めないため）。
  for tool in git rg grep sed sort find wc cat printf basename dirname cut tr paste \
              whoami mktemp chmod cp rm mkdir head; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "$FAKE_BIN/$tool"
  done

  rc=0
  PATH="$FAKE_BIN" REPO="$REPO_DIR" NGWORDS_FILE="$REPO_DIR/scripts/ngwords.txt" VAULT="$VAULT_DIR" \
    "$BASH_BIN" "$REPO_DIR/scripts/audit.sh" >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  err="$(cat "$WORK/stderr.log")"
  assert_eq "フルスキャンはexit 2" "2" "$rc"
  assert_contains "gitleaks不在メッセージ" "$err" "gitleaks"

  rc=0
  PATH="$FAKE_BIN" REPO="$REPO_DIR" NGWORDS_FILE="$REPO_DIR/scripts/ngwords.txt" VAULT="$VAULT_DIR" \
    "$BASH_BIN" "$REPO_DIR/scripts/audit.sh" --quick >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  assert_eq "--quickならgitleaks不要でexit 0" "0" "$rc"

  rm -rf "$REPO_DIR" "$VAULT_DIR" "$WORK" "$FAKE_BIN"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
