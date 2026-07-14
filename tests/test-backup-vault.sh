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
  # UPDATE_EMBEDDING_INDEX_SCRIPT=/dev/null にして埋め込みインデックス更新の
  # best-effort呼び出し（8.1ラウンド追加）を確実にno-op化する。backup-vault.shの
  # テストはgit commit/pushロジックの検証が目的であり、実Ollama/実ネットワークへの
  # 依存や実リポジトリの.cache/vault-embeddings/への副作用を持ち込まないため
  # （/dev/nullは `[[ -f ]]` が偽になるのでWARN1行を出してskipされる＝別テストで
  # 明示的に検証する）。
  STALE_LOCK_SECONDS="$stale" VAULT="$vault" LOCK_FILE="$lock" \
    UPDATE_EMBEDDING_INDEX_SCRIPT="/dev/null" \
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
  # -b main を明示（環境のgit init.defaultBranch設定に依存させない。2026-07-14
  # 追加のブランチSSOTチェック〈VAULT_BACKUP_BRANCH既定main〉と噛み合わせるため）。
  git -C "$VAULT_DIR" init -q -b main
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
  git -C "$VAULT_DIR" init -q -b main
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
  git -C "$VAULT_DIR" init -q -b main
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

echo "=== 8b. ブランチSSOT: VAULTが対象ブランチ(main)上ならそのままcommit・pushされる ==="
{
  WORK="$(mktemp -d)"
  BARE_ORIGIN="$WORK/origin.git"
  git init -q --bare "$BARE_ORIGIN"

  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  git -C "$VAULT_DIR" init -q -b main
  git -C "$VAULT_DIR" config user.name test
  git -C "$VAULT_DIR" config user.email test@example.invalid
  git -C "$VAULT_DIR" remote add origin "$BARE_ORIGIN"
  LOCK="$WORK/lock"

  rc=0
  VAULT_BACKUP_BRANCH=main run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "既定ブランチと一致していればexit 0" "0" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitされる" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 8c. ブランチSSOT: 現在のブランチがVAULT_BACKUP_BRANCHと不一致ならFAILし、自動checkoutしない（2026-07-14 リーダー指摘対応） ==="
{
  # scripts/check-drift.sh ⑦は VAULT_BACKUP_BRANCH（既定main）だけを固定監視して
  # いるため、backup-vault.shが「今checkoutされているブランチ」へ無条件にcommit
  # していると、main以外がcheckoutされたままの場合にSSOT不一致（backupは別
  # ブランチへ蓄積・check-drift.shは健全と誤判定）が起き得た。不一致時は
  # FAILし、自動checkoutしないことを検証する。
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  git -C "$VAULT_DIR" init -q -b feature-branch
  git -C "$VAULT_DIR" config user.name test
  git -C "$VAULT_DIR" config user.email test@example.invalid
  git -C "$VAULT_DIR" add -A
  git -C "$VAULT_DIR" commit -q -m "initial on feature-branch"
  echo "note 2" > "$VAULT_DIR/note2.md"
  LOCK="$WORK/lock"

  rc=0
  VAULT_BACKUP_BRANCH=main run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "ブランチ不一致でexit 1（FAIL）" "1" "$rc"
  assert_stderr_has "ブランチ不一致のFAILメッセージが出る" "$WORK" "バックアップ対象ブランチ"
  assert_eq "自動checkoutされない（feature-branchのまま）" "feature-branch" \
    "$(git -C "$VAULT_DIR" symbolic-ref --short HEAD)"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitは増えない（不一致検知後は中断）" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 8d. ブランチSSOT: 新規git initされたVAULTは常にVAULT_BACKUP_BRANCHで作成される（初回セットアップ直後のミスマッチ防止） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  # VAULT_BACKUP_BRANCHを既定(main)以外に指定し、新規initがそれに追従することを確認。
  rc=0
  VAULT_BACKUP_BRANCH=custom-main run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "初回セットアップはexit 0" "0" "$rc"
  assert_eq "指定したVAULT_BACKUP_BRANCHでinitされる" "custom-main" \
    "$(git -C "$VAULT_DIR" symbolic-ref --short HEAD)"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitされる" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 8f. ブランチSSOT: カスタムVAULT_BACKUP_BRANCHでもremoteへ同名ブランチとしてpushされる（Codexレビュー指摘・Minor対応） ==="
{
  # 8dの「新規initで正しいブランチが作られる」に続けて、そのVAULTへ後からremoteを
  # 追加し2回目の実行でpushされることを確認する（=commit先だけでなくpush先の
  # ブランチ名もVAULT_BACKUP_BRANCHと一致することを直接検証。8dだけではlocalの
  # ブランチ名しか見ておらず、push先のブランチ名までは検証していなかった）。
  WORK="$(mktemp -d)"
  BARE_ORIGIN="$WORK/origin.git"
  git init -q --bare "$BARE_ORIGIN"

  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  # 1回目: リモート未設定のまま初回セットアップ（custom-mainでinit・commit）。
  VAULT_BACKUP_BRANCH=custom-main run_backup "$VAULT_DIR" "$LOCK"
  git -C "$VAULT_DIR" remote add origin "$BARE_ORIGIN"
  echo "note 2" > "$VAULT_DIR/note2.md"

  # 2回目: remote設定後の実行でpushされる。
  rc=0
  VAULT_BACKUP_BRANCH=custom-main run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"
  assert_eq "remote側に同名ブランチ(refs/heads/custom-main)でpushされる" "1" \
    "$(git -C "$BARE_ORIGIN" show-ref --verify --quiet refs/heads/custom-main && echo 1 || echo 0)"
  assert_eq "意図しない既定ブランチ(main)は作られない" "0" \
    "$(git -C "$BARE_ORIGIN" show-ref --verify --quiet refs/heads/main && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 8e. ブランチSSOT: detached HEAD状態ならFAILし、自動checkoutしない ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  git -C "$VAULT_DIR" init -q -b main
  git -C "$VAULT_DIR" config user.name test
  git -C "$VAULT_DIR" config user.email test@example.invalid
  git -C "$VAULT_DIR" add -A
  git -C "$VAULT_DIR" commit -q -m "initial"
  git -C "$VAULT_DIR" checkout -q --detach HEAD
  echo "note 2" > "$VAULT_DIR/note2.md"
  LOCK="$WORK/lock"

  rc=0
  VAULT_BACKUP_BRANCH=main run_backup "$VAULT_DIR" "$LOCK" || rc=$?
  assert_eq "detached HEADでexit 1（FAIL）" "1" "$rc"
  assert_stderr_has "detached HEADのFAILメッセージが出る" "$WORK" "detached HEAD"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitは増えない" "1" "$commits"

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
    UPDATE_EMBEDDING_INDEX_SCRIPT="/dev/null" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout1.log" 2>"$WORK/stderr1.log" &
  pid1=$!
  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    UPDATE_EMBEDDING_INDEX_SCRIPT="/dev/null" \
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

echo "=== 10. 埋め込みインデックス更新（8.1ラウンド追加）: best-effort呼び出し・成功時はログに残る ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  STUB="$WORK/stub-update.py"
  cat > "$STUB" <<'PYEOF'
import sys
print("stub: ok")
sys.exit(0)
PYEOF

  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    UPDATE_EMBEDDING_INDEX_SCRIPT="$STUB" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout.log" 2>"$WORK/stderr.log"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_stdout_has "成功ログが出る" "$WORK" "埋め込みインデックス更新を実行しました"

  rm -rf "$WORK"
}

echo "=== 11. 埋め込みインデックス更新が非0終了してもbackup-vault.sh自体はFAILにしない（best-effort） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  STUB="$WORK/stub-update-fail.py"
  cat > "$STUB" <<'PYEOF'
import sys
sys.exit(1)
PYEOF

  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    UPDATE_EMBEDDING_INDEX_SCRIPT="$STUB" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout.log" 2>"$WORK/stderr.log"
  rc=$?
  assert_eq "非0終了でもbackup-vault.sh自体はexit 0" "0" "$rc"
  assert_stderr_has "best-effort失敗のWARNが出る" "$WORK" "埋め込みインデックス更新が非0終了しました"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commit自体は正常に完了している" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 12. update_embedding_index.pyが見つからない場合もWARNのみでexit 0 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    UPDATE_EMBEDDING_INDEX_SCRIPT="$WORK/does-not-exist.py" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout.log" 2>"$WORK/stderr.log"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_stderr_has "見つからない旨のWARNが出る" "$WORK" "見つからないためインデックス更新をskipしました"

  rm -rf "$WORK"
}

echo "=== 13. 排他制御: staleロックをほぼ同時に複数プロセスが検出しても二重実行しない（回収ミューテックスの回帰テスト） ==="
{
  # 旧実装は stale 判定後に無条件 `rm -f` していたため、複数プロセスがほぼ同時に
  # 同じ stale ロックを検出すると、先にロックを取り直したプロセスの「有効な
  # 新規ロック」を後発プロセスの無条件rmが消してしまい、二重実行が起き得た
  # （2026-07-14 外部脳監視・バックアップ機構総点検で確定・Codexレビュー指摘）。
  # 修正版は mkdir による回収専用ミューテックスで「stale判定の読み直し→片付け→
  # 再作成」を1プロセスに直列化する。
  #
  # commit数だけでは「本処理（クリティカルセクション）に複数プロセスが同時に
  # 入り込んでいないか」を厳密には検証できない（後発が先発のcommit後に到達すれば
  # 差分無しで正常終了し、commit数は結果的に1のままになり得るため。Codex一次
  # レビュー指摘・Major）。そこで UPDATE_EMBEDDING_INDEX_SCRIPT
  # （backup-vault.shが本処理の最後に必ず呼ぶbest-effortフック）に、
  # O_CREAT|O_EXCL による原子的なマーカーファイル作成で「他のプロセスが
  # まだクリティカルセクション内にいないか」を検知するスタブを差し込み、
  # 重複進入があれば violations ファイルに記録させる。
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  echo "999999" > "$LOCK"   # 存在しないであろうPID（stale確定）

  OVERLAP_STUB="$WORK/overlap-detect-stub.py"
  cat > "$OVERLAP_STUB" <<'PYEOF'
import sys, os, time

vault = sys.argv[sys.argv.index("--vault") + 1]
base = os.path.dirname(os.path.abspath(vault))
marker = os.path.join(base, "critical-section-marker")
violations = os.path.join(base, "overlap-violations.log")

got_marker = True
try:
    fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.close(fd)
except FileExistsError:
    got_marker = False

if not got_marker:
    with open(violations, "a") as f:
        f.write("overlap pid=%d\n" % os.getpid())
else:
    # マーカー保持中に十分な時間待つことで、排他が壊れていれば他プロセスの
    # 同時到達を高確率で捉える（排他が健全なら誰も同時にここへ来ない）。
    time.sleep(0.3)
    os.remove(marker)
sys.exit(0)
PYEOF

  # 上のembedding-indexスタブは「本処理の末尾」しか監視できず、途中で
  # git index.lock 判定によりexit 0する経路等は通過しない（Codex二次レビュー
  # 指摘・Major）。acquire_lock() 直後から実行される git コマンド全呼び出しを
  # 同じO_EXCLマーカー方式で監視する `git` ラッパーをPATHの先頭に差し込み、
  # 「ロック取得後の本処理区間そのもの」への重複進入をより直接的に検証する。
  REAL_GIT_BIN="$(command -v git)"
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/git" <<EOF
#!/usr/bin/env bash
marker="$WORK/git-critical-section-marker"
violations="$WORK/git-overlap-violations.log"
got=1
( set -C; echo \$\$ > "\$marker" ) 2>/dev/null || got=0
if [ "\$got" -eq 0 ]; then
  echo "overlap pid=\$\$ args=\$*" >> "\$violations"
else
  sleep 0.05
fi
"$REAL_GIT_BIN" "\$@"
rc=\$?
[ "\$got" -eq 1 ] && rm -f "\$marker"
exit \$rc
EOF
  chmod +x "$WORK/bin/git"

  N=8
  pids=()
  for i in $(seq 1 "$N"); do
    PATH="$WORK/bin:$PATH" \
      STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
      UPDATE_EMBEDDING_INDEX_SCRIPT="$OVERLAP_STUB" \
      GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
      GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
      "$SCRIPT" >"$WORK/stdout-$i.log" 2>"$WORK/stderr-$i.log" &
    pids+=($!)
  done

  all_zero=1
  for pid in "${pids[@]}"; do
    wait "$pid" || all_zero=0
  done
  assert_eq "全プロセスがexit 0" "1" "$all_zero"

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "stale解除の競合があってもcommitは1つだけ" "1" "$commits"
  assert_eq "クリティカルセクション末尾(埋め込み更新)への重複進入が検出されない" "0" \
    "$([[ -f "$WORK/overlap-violations.log" ]] && wc -l < "$WORK/overlap-violations.log" | tr -d ' ' || echo 0)"
  assert_eq "ロック取得後のgit呼び出し区間への重複進入が検出されない" "0" \
    "$([[ -f "$WORK/git-overlap-violations.log" ]] && wc -l < "$WORK/git-overlap-violations.log" | tr -d ' ' || echo 0)"

  rm -rf "$WORK"
}

echo "=== 13b. 排他制御: 回収ミューテックスが（前回実行のクラッシュ等で）解消しない場合は二重実行せずfail-closedで終了する ==="
{
  # Codex二次レビュー指摘・Critical対応: 回収ミューテックス自体のstale判定に
  # stat→rmdirの自己修復を実装すると、その判定と削除の間に別のABAレースが
  # 再発し得るため、あえて自動解除しない設計にした（scripts/backup-vault.sh側の
  # コメント参照）。「自動回復しない」ことで二重実行を避けられている（=詰まった
  # ままでも1プロセスしか処理を進めない）ことを確認する。
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  echo "999999" > "$LOCK"   # stale確定
  mkdir -p "${LOCK}.reclaim"   # 回収ミューテックスを他プロセスが握ったまま固着している状態を模擬

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" 3600 || rc=$?
  assert_eq "回収ミューテックスが解消しない場合はexit 1（fail-closed）" "1" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitはされない（二重実行にはならない）" "0" "$commits"
  assert_stderr_has "手動削除を促すFAILメッセージが出る" "$WORK" "手動で削除してください"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
