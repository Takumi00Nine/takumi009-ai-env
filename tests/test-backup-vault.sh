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
# shellcheck source=scripts/lib/pid-lock.sh
# テスト14・14b・14c・14d・19で、Vault書込ロックのfixtureを手書きの1行
# (PIDのみ)形式ではなく acquire_pid_lock() が実際に生成する形式
# （2026-08-30 PID再利用対策改修で1行目=PID・2行目=指紋の2行形式へ変更済み）
# で作るためにsourceする（2026-08-30 リーダー追補・tester独立検証指摘:
# 手書き1行fixtureのままだと実フォーマットに対する回帰を検出できない）。
source "$REPO_ROOT/scripts/lib/pid-lock.sh"

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
#
# VAULT_WRITER_LOCK_FILE は既定で「テストごとの未使用パス」に強制する
# （2026-07-16簡素化・PR2: 明示的に上書きしない限り、実HOME配下の
# ~/.claude/logs/maintenance/vault-writer.lock を読みに行ってしまい、将来
# maintenance.sh が実際にこのロックを保持している環境でテストを実行すると
# 意図せずbusy扱いになり得るため。$4で個別に上書きできるようにする）。
run_backup() {
  local vault="$1" lock="$2" stale="${3:-3600}" writer_lock="${4:-$WORK/unused-writer.lock}" status_file="${5:-}"
  local extra_args=()
  [[ -n "$status_file" ]] && extra_args=(--status-file "$status_file")
  # 空配列を`set -u`下で`${extra_args[@]}`展開するとbash 3.2（macOS既定）では
  # "unbound variable"エラーになるため、`${extra_args[@]+...}`のnounset安全な
  # 展開イディオムを使う。
  STALE_LOCK_SECONDS="$stale" VAULT="$vault" LOCK_FILE="$lock" \
    VAULT_WRITER_LOCK_FILE="$writer_lock" \
    GIT_AUTHOR_NAME="backup-vault-test" GIT_AUTHOR_EMAIL="test@example.invalid" \
    GIT_COMMITTER_NAME="backup-vault-test" GIT_COMMITTER_EMAIL="test@example.invalid" \
    "$SCRIPT" ${extra_args[@]+"${extra_args[@]}"} >"$WORK/stdout.log" 2>"$WORK/stderr.log"
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

  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" VAULT_WRITER_LOCK_FILE="$WORK/unused-writer.lock" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" >"$WORK/stdout1.log" 2>"$WORK/stderr1.log" &
  pid1=$!
  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" VAULT_WRITER_LOCK_FILE="$WORK/unused-writer.lock" \
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
  # レビュー指摘・Major）。acquire_lock() 直後から実行される git コマンド全呼び出しを
  # O_EXCLマーカー方式で監視する `git` ラッパーをPATHの先頭に差し込み、「ロック
  # 取得後の本処理区間そのもの」への重複進入を検証する（旧実装は本処理の最後に
  # 必ず呼ばれる埋め込みインデックス更新best-effortフックにも同種のマーカーを
  # 仕込んでいたが、2026-07-16簡素化でそのフック自体を撤去したため、gitラッパー
  # 側の検証だけで足りる＝gitラッパーはacquire_lock()直後からtrap EXITでの
  # ロック解放直前までの全git呼び出しを覆っており、埋め込みindex呼び出しが
  # あった旧末尾区間より広い範囲をカバーする）。
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  echo "999999" > "$LOCK"   # 存在しないであろうPID（stale確定）

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
      STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" VAULT_WRITER_LOCK_FILE="$WORK/unused-writer.lock" \
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
  assert_eq "Vault書込ロック保持中はexit 0（skip）" "0" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitはされない" "0" "$commits"
  assert_stdout_has "Vault書込ロック保持中のメッセージが出る" "$WORK" "Vault書込ロックを別プロセス"
  # 自スクリプトの多重起動防止ロック($LOCK)自体は取得・解放されている
  # （見送ったのはgit操作だけ）ことも確認する。
  assert_eq "自スクリプトのロックファイルは残らない(解放済み)" "0" \
    "$([[ -e "$LOCK" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 14b. Vault書込ロック: MAINTENANCE_LOCK_OWNER_PIDがロックファイルの実PIDと一致すればbypassして通常どおりcommitする(設計書§1.2) ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  WRITER_LOCK="$WORK/vault-writer.lock"
  acquire_pid_lock "$WRITER_LOCK" 3600 "test-writer-lock"   # 実フォーマット(1行目=PID・2行目=指紋)で生成する（このテストプロセス自身のPID・確実に生存）

  rc=0
  MAINTENANCE_LOCK_OWNER_PID="$$" \
    STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" VAULT_WRITER_LOCK_FILE="$WRITER_LOCK" \
    GIT_AUTHOR_NAME="backup-vault-test" GIT_AUTHOR_EMAIL="test@example.invalid" \
    GIT_COMMITTER_NAME="backup-vault-test" GIT_COMMITTER_EMAIL="test@example.invalid" \
    "$SCRIPT" >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  assert_eq "PID一致時はexit 0（通常どおり実行）" "0" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "PID一致時はcommitされる（busyでskipされない）" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 14c. Vault書込ロック: MAINTENANCE_LOCK_OWNER_PIDが未設定なら従来どおりbusyでskipする（bypassが誤って常時有効化されていないことの確認） ==="
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
  assert_eq "未設定なら従来どおりbusy(exit 0・skip)" "0" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "commitはされない" "0" "$commits"

  rm -rf "$WORK"
}

echo "=== 14d. Vault書込ロック: MAINTENANCE_LOCK_OWNER_PIDがロックファイルの実PIDと一致しなければbypassしない（launchctl setenv等でアンビエントに漏れ残った場合の多層防御） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  WRITER_LOCK="$WORK/vault-writer.lock"
  acquire_pid_lock "$WRITER_LOCK" 3600 "test-writer-lock"   # 実フォーマット(1行目=PID・2行目=指紋)で生成する（このテストプロセス自身のPID・確実に生存）

  rc=0
  # MAINTENANCE_LOCK_OWNER_PIDに実際のロック保持者とは異なる値（例:
  # 過去のmaintenance.sh実行のPIDが環境変数として漏れ残っていた想定）を渡す。
  MAINTENANCE_LOCK_OWNER_PID="999999" \
    STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" VAULT_WRITER_LOCK_FILE="$WRITER_LOCK" \
    GIT_AUTHOR_NAME="backup-vault-test" GIT_AUTHOR_EMAIL="test@example.invalid" \
    GIT_COMMITTER_NAME="backup-vault-test" GIT_COMMITTER_EMAIL="test@example.invalid" \
    "$SCRIPT" >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  assert_eq "PID不一致ならbypassされずbusy(exit 0)" "0" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "PID不一致ならcommitされない" "0" "$commits"

  rm -rf "$WORK"
}

echo "=== 15. Vault書込ロック: PIDがstale(死んでいる)なら無視して通常どおりcommitする ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  WRITER_LOCK="$WORK/vault-writer.lock"
  echo "999999" > "$WRITER_LOCK"   # 存在しないであろうPID

  rc=0
  run_backup "$VAULT_DIR" "$LOCK" 3600 "$WRITER_LOCK" || rc=$?
  assert_eq "staleなVault書込ロックは無視されexit 0" "0" "$rc"
  commits=$(count_commits "$VAULT_DIR")
  assert_eq "通常どおりcommitされる" "1" "$commits"
  # is_pid_lock_heldは読み取り専用（stale判定してもファイル自体は消さない）。
  assert_eq "staleなVault書込ロックファイル自体は(読み取り専用チェックのため)残る" "1" \
    "$([[ -e "$WRITER_LOCK" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 16. --status-file: 差分がありcommit成功したらcompletedが書かれる ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  STATUS="$WORK/status.txt"

  run_backup "$VAULT_DIR" "$LOCK" 3600 "" "$STATUS"
  assert_eq "status-fileにcompletedが書かれる" "completed" "$(cat "$STATUS")"

  rm -rf "$WORK"
}

echo "=== 17. --status-file: 差分が無ければno-changeが書かれる ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  STATUS="$WORK/status.txt"

  run_backup "$VAULT_DIR" "$LOCK" 3600 "" "$STATUS"   # 1回目でcommit済みにしておく
  run_backup "$VAULT_DIR" "$LOCK" 3600 "" "$STATUS"   # 2回目は差分なし
  assert_eq "2回目のstatus-fileにno-changeが書かれる" "no-change" "$(cat "$STATUS")"

  rm -rf "$WORK"
}

echo "=== 18. --status-file: 自スクリプトの多重起動防止ロックで見送った場合はbusyが書かれる ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  echo "$$" > "$LOCK"
  STATUS="$WORK/status.txt"

  run_backup "$VAULT_DIR" "$LOCK" 3600 "" "$STATUS" || true
  assert_eq "status-fileにbusyが書かれる" "busy" "$(cat "$STATUS")"

  rm -rf "$WORK"
}

echo "=== 19. --status-file: Vault書込ロック保持中で見送った場合もbusyが書かれる ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  WRITER_LOCK="$WORK/vault-writer.lock"
  acquire_pid_lock "$WRITER_LOCK" 3600 "test-writer-lock"   # 実フォーマット(1行目=PID・2行目=指紋)で生成する（このテストプロセス自身のPID・確実に生存）
  STATUS="$WORK/status.txt"

  run_backup "$VAULT_DIR" "$LOCK" 3600 "$WRITER_LOCK" "$STATUS"
  assert_eq "status-fileにbusyが書かれる" "busy" "$(cat "$STATUS")"

  rm -rf "$WORK"
}

echo "=== 20. --status-file: FAIL経路(ブランチ不一致)ではerrorが書かれる ==="
{
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
  STATUS="$WORK/status.txt"

  rc=0
  VAULT_BACKUP_BRANCH=main run_backup "$VAULT_DIR" "$LOCK" 3600 "" "$STATUS" || rc=$?
  assert_eq "ブランチ不一致はexit 1" "1" "$rc"
  assert_eq "status-fileにerrorが書かれる" "error" "$(cat "$STATUS")"

  rm -rf "$WORK"
}

echo "=== 21. --status-file省略時は従来どおり何も書かれない(後方互換) ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"
  STATUS="$WORK/status-should-not-exist.txt"

  run_backup "$VAULT_DIR" "$LOCK"   # --status-file を渡さない
  assert_eq "status-fileは作られない" "0" "$([[ -e "$STATUS" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 22. CLI引数: 不明な引数はexit 1(FAIL) ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  rc=0
  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    VAULT_WRITER_LOCK_FILE="$WORK/unused-writer.lock" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" --bogus-flag >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  assert_eq "不明な引数はexit 1" "1" "$rc"
  assert_stderr_has "不明な引数のFAILメッセージが出る" "$WORK" "不明な引数です"

  rm -rf "$WORK"
}

echo "=== 23. CLI引数: --status-file に値が無ければexit 1(FAIL) ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  mkdir -p "$VAULT_DIR"
  echo "note 1" > "$VAULT_DIR/note1.md"
  LOCK="$WORK/lock"

  rc=0
  STALE_LOCK_SECONDS=3600 VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    VAULT_WRITER_LOCK_FILE="$WORK/unused-writer.lock" \
    GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@example.invalid" \
    GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@example.invalid" \
    "$SCRIPT" --status-file >"$WORK/stdout.log" 2>"$WORK/stderr.log" || rc=$?
  assert_eq "値省略はexit 1" "1" "$rc"
  assert_stderr_has "値必須のFAILメッセージが出る" "$WORK" "--status-file には値が必要"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
