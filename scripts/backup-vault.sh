#!/usr/bin/env bash
# Vault($HOME/Data/obsidian) を git commit（＋remote設定済みならpush）でバックアップする。
#
# 詳細は README.md「Vault バックアップの運用」節を参照。
#
# launchagents/com.takumi009.backup-vault.plist から1時間おきに無人実行される
# 前提のスクリプト（scripts/install-backup.sh が配置する。旧ラベル名
# com.takumi009.vault-backupは2026-07-16簡素化で改名済み＝設計書§5）。
#
# 処理順序:
#   1. スクリプト自身の多重起動防止ロック（PIDファイル方式。stale なら自動解除）
#   2. git index.lock が残っていれば、staleなものだけ自動解除（新しければ今回はskip）
#   3. VAULT が git repo でなければ git init（ローカルのみ・リモートは作らない。
#      対象ブランチ名は $VAULT_BACKUP_BRANCH で明示的に作成する）
#   3b. 現在checkoutされているブランチが $VAULT_BACKUP_BRANCH と一致するか確認する
#      （2026-07-14 リーダー指摘対応。scripts/check-drift.sh ⑦のpush死活監視も
#      同じ $VAULT_BACKUP_BRANCH（既定"main"）をSSOTとして固定監視しているが、
#      本スクリプトは従来「今checkoutされているブランチ」へ無条件にcommit・
#      `push origin HEAD` していたため、main以外のブランチが誤ってcheckoutされた
#      ままだとbackupはそちらへ蓄積し続け、check-drift.shは main を見ているだけ
#      なので健全と誤判定するSSOT不一致があった。不一致を検知したら**自動
#      checkoutはせず**FAILで中断する（意図しないブランチ切替・作業ツリー書き換え
#      という破壊的操作を避けるため。本人が確認のうえ手動でcheckoutする運用）
#   4. git add -A → 差分があれば commit（"backup: YYYY-MM-DD HH:MM"）
#   5. remote 'origin' が設定済みの場合のみ push。未設定なら commit までで
#      WARN表示して終了する（絶対厳守ルール②＝publicリポジトリ化・remote作成は
#      本人が行う、の精神に準拠。このスクリプトはremoteを勝手に作らない）
#
# パスは $HOME 相対（VAULT・LOCK_FILE は環境変数で上書き可＝ユニットテスト用。
# 本番実行時は既定値のまま呼べば良い）。VAULT_BACKUP_BRANCH は
# scripts/check-drift.sh と同一名の環境変数（既定 "main"）＝SSOT。
#
# --status-file <path>: 省略可。機械可読な実行結果（completed/no-change/busy/
# error のいずれか1語）をscripts/lib/status-file.sh経由で書く（設計書§1.2
# 「maintenance.sh Phase0がbackup-vault.shを--status-file付きで呼ぶ」向け。
# 2026-07-16簡素化・PR1.5からの持ち越し）。省略時は従来どおり何も書かない
# （既存のLaunchAgent無引数呼び出しと完全互換）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 多重起動防止ロック（PIDファイル方式・stale自動解除）は scripts/maintenance.sh
# （週次ランナー・PR2）とも共有する（2026-07-16簡素化・cleanup決定#10・PR1.5③）。
# status-file.shは--status-fileの読み書き（同じくPR2のmaintenance.shと共用）。
# shellcheck source=scripts/lib/pid-lock.sh
source "$SCRIPT_DIR/lib/pid-lock.sh"
# shellcheck source=scripts/lib/status-file.sh
source "$SCRIPT_DIR/lib/status-file.sh"

STATUS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status-file)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[backup-vault] FAIL: --status-file には値が必要です" >&2
        exit 1
      fi
      STATUS_FILE="$2"
      shift 2
      ;;
    *)
      echo "[backup-vault] FAIL: 不明な引数です: $1" >&2
      exit 1
      ;;
  esac
done

: "${VAULT:=$HOME/Data/obsidian}"
: "${LOCK_FILE:=${TMPDIR:-/tmp}/aienv-backup-vault.lock}"
# scripts/check-drift.sh ⑦の VAULT_BACKUP_BRANCH と同一名・同一既定値のSSOT
# （2026-07-14 リーダー指摘対応）。
: "${VAULT_BACKUP_BRANCH:=main}"
# stale判定の閾値。LaunchAgentの実行間隔（1時間=3600秒）と同じにしておけば、
# 「前回実行がクラッシュして片付けられなかったロック」と「今まさに実行中」を
# 十分な余裕を持って区別できる。
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-3600}"
# maintenance.sh（週次ランナー・PR2・未実装）がPhase0〜Phase3の間保持するVault
# 書込ロック。本スクリプトは自分では取得・作成しない（is_pid_lock_heldによる
# 読み取り専用チェックのみ＝設計書§1.2「backup-vault.sh側にも軽量チェックを
# 追加（毎時backupとの競合対策）」）。
: "${VAULT_WRITER_LOCK_FILE:=$HOME/.claude/logs/maintenance/vault-writer.lock}"

log() { echo "[backup-vault] $*"; }
warn() { echo "[backup-vault] WARN: $*" >&2; }
fail() {
  echo "[backup-vault] FAIL: $*" >&2
  write_status_file "$STATUS_FILE" error
  exit 1
}

[[ -d "$VAULT" ]] || fail "VAULT が見つかりません: $VAULT"
command -v git >/dev/null 2>&1 || fail "git が見つかりません"

# --- 1. 多重起動防止ロック（PIDファイル方式・原子的に取得） ---
# 実装は scripts/lib/pid-lock.sh（acquire_pid_lock）に抽出済み（2026-07-16簡素化・
# PR1.5③。ロジック自体は敵対的レビュー3巡を経た挙動を一切変えていない＝
# noclobberによる原子取得・ABA対策のmkdir回収ミューテックス・回収ミューテックス
# 自体はfail-closedで自動解除しない設計。詳細は同ファイルのコメント参照）。
# 既存のロック形式（$LOCK_FILE にPIDを書いた1個のファイル）自体は変更していない
# （tests/test-backup-vault.sh の `echo "$$" > "$LOCK"` 等の既存前提と完全互換）。
# STATUS_FILEを渡すことで、busy/error確定時に自動でwrite_status_fileされる。
acquire_pid_lock "$LOCK_FILE" "$STALE_LOCK_SECONDS" "backup-vault" "$STATUS_FILE"

# --- 1b. Vault書込ロック（maintenance.sh保持）の軽量チェック（読み取り専用） ---
# maintenance.sh自身がPhase0/Phase3で本スクリプトを（Vault書込ロックを保持した
# ままの状態で）意図的に呼び出す場合は、このチェックをbypassする
# （2026-07-16 maintenance.sh実装時に発見・追加: このチェックの本来の目的は
# 「毎時LaunchAgent発火のbackup-vault.shが、maintenance.sh実行中の複数ステップ
# 書込みと競合しないよう横から割り込ませない」ことであり、maintenance.sh自身が
# 呼ぶ分（設計書§1.2 Phase0の直前スナップショット・Phase3の最終commit）まで
# 阻止してしまうと、ロックを取得した本人が自分の意図した呼び出しで永遠に
# blockされる自己矛盾になる）。
#
# bypassの判定は単なる真偽値フラグではなく、`MAINTENANCE_LOCK_OWNER_PID`に
# 渡された値がロックファイルへ実際に書かれているPIDと一致するかで行う
# （2026-07-16 Codexレビュー指摘Major対応: 当初は`MAINTENANCE_INTERNAL_CALL=1`
# という単純な真偽値フラグだった。`launchctl setenv`・plist設定ミス・手動
# 実行等でこの環境変数がアンビエントに`=1`のまま毎時LaunchAgent側の
# backup-vault.sh実行に漏れ残っていた場合、無関係な実行までVault書込
# ロックの排他をbypassしてしまいうる。ロックファイルの実際のPIDと照合する
# ことで、「本当にこのロックを取得したプロセス自身からの呼び出しか」を
# 検証できるようにする＝真に自分自身が保持しているロックでなければ
# bypassしない）。
_bypass_writer_lock_check=0
if [[ -n "${MAINTENANCE_LOCK_OWNER_PID:-}" && -f "$VAULT_WRITER_LOCK_FILE" ]]; then
  _lock_file_pid="$(cat "$VAULT_WRITER_LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$_lock_file_pid" && "$_lock_file_pid" == "$MAINTENANCE_LOCK_OWNER_PID" ]]; then
    _bypass_writer_lock_check=1
  fi
fi
if [[ "$_bypass_writer_lock_check" -ne 1 ]] && is_pid_lock_held "$VAULT_WRITER_LOCK_FILE"; then
  log "Vault書込ロックを別プロセス（maintenance.sh）が保持中のため、今回のcommitは見送ります: $VAULT_WRITER_LOCK_FILE"
  write_status_file "$STATUS_FILE" busy
  exit 0
fi

# --- 2. git index.lock 対策（stale なら自動解除、新しければ今回はskip） ---
INDEX_LOCK="$VAULT/.git/index.lock"
if [[ -e "$INDEX_LOCK" ]]; then
  lock_mtime=$(stat -f %m "$INDEX_LOCK" 2>/dev/null || stat -c %Y "$INDEX_LOCK" 2>/dev/null || echo 0)
  lock_age=$(( $(date +%s) - lock_mtime ))
  if [[ "$lock_age" -ge "$STALE_LOCK_SECONDS" ]]; then
    warn "stale な git index.lock を検出しました（${lock_age}秒経過）。解除して続行します: $INDEX_LOCK"
    rm -f "$INDEX_LOCK"
  else
    log "git index.lock が新しく（${lock_age}秒前）、別のgit操作が進行中の可能性があるため今回はskipします。"
    write_status_file "$STATUS_FILE" busy
    exit 0
  fi
fi

# --- 3. git repo が無ければ初期化（ローカルのみ・リモートは作らない） ---
if [[ ! -d "$VAULT/.git" ]]; then
  log "VAULT が git repo ではないため git init します（ローカルのみ・リモートは設定しない）: $VAULT"
  # 対象ブランチ名を明示して作成する（git 2.28+ の `-b`）。既定のまま
  # `git init` すると `init.defaultBranch` 設定次第で main 以外（例: master）に
  # なり得るため、初回セットアップの時点から $VAULT_BACKUP_BRANCH（check-drift.sh
  # と同一SSOT）に合わせておく（下の3bのミスマッチ検知に初回セットアップ直後から
  # 引っかからないようにするため）。
  git -C "$VAULT" init -q -b "$VAULT_BACKUP_BRANCH"
fi

# --- 3b. 現在のブランチが $VAULT_BACKUP_BRANCH と一致するか確認する ---
# scripts/check-drift.sh ⑦は $VAULT_BACKUP_BRANCH（既定"main"）だけを固定監視して
# いるため、ここでそれ以外のブランチへ無条件にcommit・pushしてしまうと、
# check-drift.sh側は気付けないままバックアップが別ブランチへ蓄積し続けるSSOT不一致
# になる（2026-07-14 リーダー指摘対応）。検知しても**自動checkoutはしない**
# （破壊的操作＝作業ツリーの書き換えを避ける。本人が状況を確認したうえで手動対応
# する運用）。
current_branch="$(git -C "$VAULT" symbolic-ref --short HEAD 2>/dev/null || true)"
if [[ -z "$current_branch" ]]; then
  fail "VAULT(${VAULT})のHEADがブランチを指していません（detached HEAD等の可能性）。バックアップ対象ブランチ（${VAULT_BACKUP_BRANCH}）へcommitしてよいか判断できないため中断します。確認: git -C ${VAULT} status ／ 復帰: git -C ${VAULT} checkout ${VAULT_BACKUP_BRANCH}"
fi
if [[ "$current_branch" != "$VAULT_BACKUP_BRANCH" ]]; then
  fail "VAULT(${VAULT})の現在のブランチ（${current_branch}）がバックアップ対象ブランチ（${VAULT_BACKUP_BRANCH}。scripts/check-drift.shのVAULT_BACKUP_BRANCHと同一のSSOT）と一致しません。意図しないブランチへの蓄積を避けるため、自動checkoutはせず中断します。本人が状況を確認したうえで、必要なら手動で 'git -C ${VAULT} checkout ${VAULT_BACKUP_BRANCH}' を実行してください。"
fi

# --- 4. git add -A → 差分があれば commit ---
git -C "$VAULT" add -A

HAD_CHANGES=0
if git -C "$VAULT" diff --cached --quiet; then
  log "変更なし。commit をスキップします"
else
  HAD_CHANGES=1
  # commit用identityが無いと素のGitエラーで落ちて分かりにくいので事前検知する
  # （export-public-vault.shと同方針）。
  if ! git -C "$VAULT" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
    fail "git commit 用の identity が未設定です。'git config user.name' / 'git config user.email' を設定してください（--global または $VAULT 内で --local）"
  fi
  commit_msg="backup: $(date '+%Y-%m-%d %H:%M')"
  git -C "$VAULT" commit -q -m "$commit_msg"
  log "commit しました: $commit_msg"
fi

# --- 5. remote 'origin' が設定済みの場合のみ push ---
if git -C "$VAULT" remote get-url origin >/dev/null 2>&1; then
  rc=0
  git -C "$VAULT" push origin HEAD || rc=$?
  if [[ $rc -eq 0 ]]; then
    log "push しました"
  else
    # ネットワーク不通・認証切れ等は一時的な問題であり得るため、push失敗だけで
    # 致命的なFAIL扱いにはしない（commitはローカルに残っており、次回実行時に
    # 再度pushが試みられる＝データ損失は無い）。
    warn "push に失敗しました (exit $rc)。commit は完了しているため次回実行時に再試行されます。"
  fi
else
  warn "remote 'origin' が未設定のため push をスキップしました（commit までは完了）。remote設定は本人が行う運用です。"
fi

# --- 6. 埋め込みインデックスのbest-effort更新（廃止） ---
# 2026-07-16簡素化（[[Decisions/2026-07-16-remove-vector-search-embedding-infra]]）で
# ベクトル検索基盤を埋め込み基盤ごと撤去したため、毎時のvault-backup相乗り
# （update_embedding_index.py呼び出し）も不要になり削除した。旧実装を読みたい場合は
# `git log -p scripts/backup-vault.sh` を参照。

# push失敗はWARNに留め致命的エラーとしない（上記コメント参照）ため、
# completed/no-changeの判定はpush結果に左右されない＝ローカルcommit（または
# 「変更なし」の確認）まで到達できたことをもって成功とする。
if [[ "$HAD_CHANGES" -eq 1 ]]; then
  write_status_file "$STATUS_FILE" completed
else
  write_status_file "$STATUS_FILE" no-change
fi

log "done."
