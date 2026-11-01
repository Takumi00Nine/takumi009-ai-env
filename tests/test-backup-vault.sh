#!/usr/bin/env bash
# ai-brain/executor/backup-vault.sh のユニットテスト。
#
# 実 Vault($HOME/Data/obsidian)・実 GitHub には一切依存しない。VAULT/LOCK_FILE を
# 環境変数で毎回ダミーのfixtureディレクトリへ差し替えて backup-vault.sh を
# そのまま実行し、正常系/異常系の挙動を検証する。
#
# 実行方法: bash tests/test-backup-vault.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/backup-vault.sh"
# shellcheck source=core/executor/pid-lock.sh
# テスト14・14b・14c・14d・19で、Vault書込ロックのfixtureを手書きの1行
# (PIDのみ)形式ではなく acquire_pid_lock() が実際に生成する形式
# （2026-08-30 PID再利用対策改修で1行目=PID・2行目=指紋の2行形式へ変更済み）
# で作るためにsourceする（2026-08-30 リーダー追補・tester独立検証指摘:
# 手書き1行fixtureのままだと実フォーマットに対する回帰を検出できない）。
source "$REPO_ROOT/core/executor/pid-lock.sh"

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

count_commits() {
  local repo="$1"
  git -C "$repo" log --oneline 2>/dev/null | wc -l | tr -d ' ' || true
}

run_backup() {
  local vault="$1" lock="$2" stale="${3:-3600}" writer_lock="${4:-$WORK/unused-writer.lock}"
  STALE_LOCK_SECONDS="$stale" VAULT="$vault" LOCK_FILE="$lock" \
    VAULT_WRITER_LOCK_FILE="$writer_lock" \
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

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "初回commitが1つ作られている" "1" "$commits"
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

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "変更が無ければcommit数は1のまま" "1" "$commits"
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

  commits=$(count_commits "$VAULT_DIR")
  assert_eq "skipされたのでcommitは作られない" "0" "$commits"
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

  origin_commits=$(count_commits "$BARE_ORIGIN")
  assert_eq "origin側にpushされている" "1" "$origin_commits"
  rm -rf "$WORK"
}

echo "=== 8c. ブランチSSOT: 現在のブランチがVAULT_BACKUP_BRANCHと不一致ならFAILし、自動checkoutしない（2026-07-14 リーダー指摘対応） ==="
{
  # core/assembly/check-drift.sh ⑦は VAULT_BACKUP_BRANCH（既定main）だけを固定監視して
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
  assert_eq "自動checkoutされない（feature-branchのまま）" "feature-branch" \
    "$(git -C "$VAULT_DIR" symbolic-ref --short HEAD)"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitは増えない（不一致検知後は中断）" "1" "$commits"
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
  rm -rf "$WORK"
}

echo "=== 14. Vault書込ロック: maintenance.sh(想定)が保持中(生存PID)なら今回のcommitを見送る(busy・exit 0)(設計書§1.2) ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  WRITER_LOCK="$WORK/vault-writer.lock"
  acquire_pid_lock "$WRITER_LOCK" 3600 "test-writer-lock"   # 実フォーマット(1行目=PID・2行目=指紋)で生成する（このテストプロセス自身のPID・確実に生存）

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" 3600 "$WRITER_LOCK" || rc=$?
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitはされない" "0" "$commits"
  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
