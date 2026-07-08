#!/usr/bin/env bash
# scripts/backup-vault.sh のユニットテスト。
#
# 実 Vault($HOME/Data/obsidian)・実 GitHub には一切依存しない。VAULT/LOCK_FILE を
# 環境変数で毎回ダミーのfixtureディレクトリへ差し替えて backup-vault.sh を
# そのまま実行し、正常系/異常系の挙動を検証する。
#
# 実行方法: bash tests/test-backup-vault.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/backup-vault.sh"

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

assert_stdout_has() {
  local desc="$1" work="$2" needle="$3"
  if grep -q -- "$needle" "$work/stdout.log" 2>/dev/null; then
    pass "$desc"
  else
    fail_case "$desc (stdout に \"$needle\" が含まれない。実際: $(cat "$work/stdout.log" 2>/dev/null))"
  fi
}

# backup-vault.sh の warn() は stderr へ出す（log() は stdout）ため専用の確認関数を分ける。
assert_stderr_has() {
  local desc="$1" work="$2" needle="$3"
  if grep -q -- "$needle" "$work/stderr.log" 2>/dev/null; then
    pass "$desc"
  else
    fail_case "$desc (stderr に \"$needle\" が含まれない。実際: $(cat "$work/stderr.log" 2>/dev/null))"
  fi
}

# git log --oneline はコミットが1つも無いrepoでは非ゼロ終了するため安全に数える
count_commits() {
  local repo="$1"
  git -C "$repo" log --oneline 2>/dev/null | wc -l | tr -d ' ' || true
}

# backup-vault.sh を実行して exit code を返す（VAULT/LOCK_FILE/STALE_LOCK_SECONDS 上書き）。
# GIT_AUTHOR_*/GIT_COMMITTER_* を環境変数で渡すことで、backup-vault.sh 自身が
# 初回 git init するケース（事前に `git config` できない）でも、sandbox/CI に
# global git identity が無い環境で失敗しないようにする（Codexレビュー指摘・Major）。
run_backup() {
  local vault="$1" lock="$2" stale="${3:-3600}"
  STALE_LOCK_SECONDS="$stale" VAULT="$vault" LOCK_FILE="$lock" \
    GIT_AUTHOR_NAME="backup-vault-test" GIT_AUTHOR_EMAIL="test@example.invalid" \
    GIT_COMMITTER_NAME="backup-vault-test" GIT_COMMITTER_EMAIL="test@example.invalid" \
    "$SCRIPT" >"$WORK/stdout.log" 2>"$WORK/stderr.log"
}

echo "=== 1. 正常系: 未git化のVaultを init + 初回commit（remote未設定はWARN） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "exit code 0" "0" "$rc"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "初回commitが1つ作られている" "1" "$commits"
  assert_stderr_has "remote未設定のWARNが出る" "$WORK" "remote 'origin' が未設定のため push をスキップ"

  rm -rf "$WORK"
}

echo "=== 2. 冪等性: 変更が無ければcommitしない ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  run_backup "$VAULT_DIR" "$LOCK"
  rc=0
  run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "変更が無ければcommit数は1のまま" "1" "$commits"
  assert_stdout_has "変更なしメッセージが出る" "$WORK" "変更なし。commit をスキップします"

  rm -rf "$WORK"
}

echo "=== 3. 差分があれば新規commitされる ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  run_backup "$VAULT_DIR" "$LOCK"
  echo "note 2" > "$VAULT_DIR/note2.md"
  run_backup "$VAULT_DIR" "$LOCK"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "差分があればcommit数が増える" "2" "$commits"

  rm -rf "$WORK"
}

echo "=== 4. ロック: 生存しているPIDのロックがあれば今回はskipする ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  echo "$$" > "$LOCK"   # このテストプロセス自身のPID（確実に生存している）

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "実行中ロックがあればexit 0（skip）" "0" "$rc"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "skipされたのでcommitは作られない" "0" "$commits"
  assert_stdout_has "既に実行中ですメッセージが出る" "$WORK" "既に実行中です"

  rm -rf "$WORK"
}

echo "=== 5. ロック: staleなPID（存在しない）は自動解除して続行する ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  echo "999999" > "$LOCK"   # 存在しないであろうPID

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "staleロックは解除されexit 0" "0" "$rc"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "staleロック解除後にcommitされる" "1" "$commits"
  assert_stderr_has "staleロック検出のWARNが出る" "$WORK" "stale なロックファイルを検出しました"

  rm -rf "$WORK"
}

echo "=== 6. git index.lock: 新しければ今回はskipする ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  git -C "$VAULT_DIR" init -q
  git -C "$VAULT_DIR" config user.name test
  git -C "$VAULT_DIR" config user.email test@example.invalid
  echo "note 1" > "$VAULT_DIR/note1.md"
  touch "$VAULT_DIR/.git/index.lock"
  LOCK="$WORK/lock"

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" 3600 || rc=$?
  assert_eq "新しいindex.lockがあればexit 0（skip）" "0" "$rc"
  assert_eq "index.lockはまだ残っている" "1" \
    "$([[ -e "$VAULT_DIR/.git/index.lock" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 7. git index.lock: staleなら自動解除して続行する ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  git -C "$VAULT_DIR" init -q
  git -C "$VAULT_DIR" config user.name test
  git -C "$VAULT_DIR" config user.email test@example.invalid
  echo "note 1" > "$VAULT_DIR/note1.md"
  touch -t 202001010000 "$VAULT_DIR/.git/index.lock"
  LOCK="$WORK/lock"

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" 3600 || rc=$?
  assert_eq "staleなindex.lockは解除されexit 0" "0" "$rc"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "index.lock解除後にcommitされる" "1" "$commits"
  assert_stderr_has "staleなindex.lock検出のWARNが出る" "$WORK" "stale な git index.lock を検出しました"

  rm -rf "$WORK"
}

echo "=== 8. remote origin設定済みならpushされる ==="
{
  WORK="$(mktemp -d)"
  BARE_ORIGIN="$WORK/origin.git"
  git init -q --bare "$BARE_ORIGIN"

  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  git -C "$VAULT_DIR" init -q
  git -C "$VAULT_DIR" config user.name test
  git -C "$VAULT_DIR" config user.email test@example.invalid
  git -C "$VAULT_DIR" remote add origin "$BARE_ORIGIN"
  LOCK="$WORK/lock"

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "push成功でexit 0" "0" "$rc"

  origin_commits=$(count_commits "$BARE_ORIGIN")
  assert_eq "origin側にpushされている" "1" "$origin_commits"
  assert_stdout_has "pushしましたメッセージが出る" "$WORK" "push しました"

  rm -rf "$WORK"
}

echo "=== 9. 排他制御: ほぼ同時に2プロセス起動しても片方だけが処理を進める（原子的ロックの回帰テスト） ==="
{
  # 旧実装は [[ -f ]] チェック→echo > の2段階でTOCTOUレースがあった
  # （Codexレビュー指摘・Major）。set -C(noclobber)による原子的なロック取得に
  # 修正したことを、実際にほぼ同時に2プロセスを起動して確認する。
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout1.log" 2>"$WORK/stderr1.log" &
  pid1=$!
  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout2.log" 2>"$WORK/stderr2.log" &
  pid2=$!

  rc1=0; rc2=0
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?
  assert_eq "両プロセスともexit 0" "0" "$([[ $rc1 -eq 0 && $rc2 -eq 0 ]] && echo 0 || echo 1)"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitは1つだけ（両方が処理を進めていない証拠）" "1" "$commits"

  skip_count=0
  grep -q "既に実行中です" "$WORK/stdout1.log" 2>/dev/null && skip_count=$((skip_count + 1))
  grep -q "既に実行中です" "$WORK/stdout2.log" 2>/dev/null && skip_count=$((skip_count + 1))
  assert_eq "どちらか一方だけがskipメッセージを出す" "1" "$skip_count"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
