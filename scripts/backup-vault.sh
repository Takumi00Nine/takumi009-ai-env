#!/usr/bin/env bash
# Vault($HOME/Data/obsidian) を git commit（＋remote設定済みならpush）でバックアップする。
#
# 詳細は README.md「Vault バックアップの運用」節を参照。
#
# launchagents/com.takumi009.vault-backup.plist から1時間おきに無人実行される
# 前提のスクリプト（scripts/install-backup.sh が配置する）。
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

set -euo pipefail

: "${VAULT:=$HOME/Data/obsidian}"
: "${LOCK_FILE:=${TMPDIR:-/tmp}/aienv-backup-vault.lock}"
# scripts/check-drift.sh ⑦の VAULT_BACKUP_BRANCH と同一名・同一既定値のSSOT
# （2026-07-14 リーダー指摘対応）。
: "${VAULT_BACKUP_BRANCH:=main}"
# stale判定の閾値。LaunchAgentの実行間隔（1時間=3600秒）と同じにしておけば、
# 「前回実行がクラッシュして片付けられなかったロック」と「今まさに実行中」を
# 十分な余裕を持って区別できる。
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-3600}"

log() { echo "[backup-vault] $*"; }
warn() { echo "[backup-vault] WARN: $*" >&2; }
fail() { echo "[backup-vault] FAIL: $*" >&2; exit 1; }

[[ -d "$VAULT" ]] || fail "VAULT が見つかりません: $VAULT"
command -v git >/dev/null 2>&1 || fail "git が見つかりません"

# --- 1. 多重起動防止ロック（PIDファイル方式・原子的に取得） ---
# PIDを記録し、そのPIDが実際に生きているかを毎回 kill -0 で確認することで、
# プロセスが異常終了(kill -9・電源断等)して片付けられなかった stale なロックを
# 安全に自動解除できるようにする。
# ロック取得自体は bash の noclobber（`set -C`）を使い、「ファイルが無い時だけ
# 作成に成功する」という原子的な操作にする（Codexレビュー指摘・Major：
# 素朴な `[[ -f ]]` チェック→`echo >` の2段階だと、ほぼ同時に2プロセスが
# 起動した場合に両方とも「ロックが無い」と判定して素通りしてしまうTOCTOUレースがあった）。
try_create_lock() {
  ( set -C; echo "$$" > "$LOCK_FILE" ) 2>/dev/null
}

# stale判定〜片付け〜再作成の一連の操作を1プロセスだけが行うよう直列化する
# ための回収専用ミューテックス（$LOCK_FILE とは別物。mkdirはPOSIX上atomicな
# 排他取得手段＝同じディレクトリを複数プロセスが同時にmkdirしても成功できるのは
# 1プロセスだけ）。
#
# 2026-07-14 修正（外部脳監視・バックアップ機構総点検で確定したレース。旧実装は
# stale判定後に無条件 `rm -f` していたため、A・Bがほぼ同時に同じstaleロックを
# 検出すると、Aがrm→再作成した直後にBが古い"stale"判定のまま無条件rmしてしまい、
# Aの*有効な新規ロック*を消して二重実行が起き得た。その後 `mv`（rename）による
# 「片付ける権利の奪取」に変更したが、Codex一次レビューで指摘の通りそれでも
# ABA問題が残っていた: 「読んだ時点でstaleと判定した内容」と「実際にmvする時点の
# 中身」が一致する保証が無く、A再作成後にBが古い判定に基づき`mv`するとAの有効な
# ロックをやはり奪ってしまう。mkdirミューテックスなら、①ミューテックス取得 →
# ②その場でPIDを改めて読み直し生存確認（ここが重要: 古い判定結果を使い回さない）
# → ③本当にstaleな時だけrm→再作成、という順序を1プロセスに直列化でき、
# 「読んだ時点」と「片付ける時点」がズレない）。
#
# このミューテックス自体が stale になった場合（＝前回実行がミューテックス保持中に
# クラッシュ〈kill -9・電源断等〉した極めて稀なケース）は、あえて自動解除しない
# （Codex二次レビュー指摘・Critical対応: 一度は `stat`でmtime判定→`rmdir`する
# 自己修復を実装したが、mtime判定とrmdirの間にも同じABAが再発し得る＝
# rmdirはパス名だけを見て「今そこにあるものが何であれ」削除してしまうため、
# 判定後に別プロセスが正規に再作成した有効なミューテックスを誤って奪える。
# 回収区間は数命令のみで通常は一瞬のため、無理に自動回復を狙うより、競合が
# 解消しなければ明示的にfail()して気付けるようにする方が安全＝二重実行より
# 「稀に手動での後片付けが要る」方を選ぶ設計判断）。この失敗は無人実行時は
# ログ（/tmp/vault-backup.log）にのみ残るが、commit/pushが止まり続ければ
# scripts/check-drift.sh ⑦（Vaultバックアップのpush死活監視）が24時間以内に
# 検知して通知するため、無限に無言で死ぬことはない。
#
# 既存のロック形式（$LOCK_FILE にPIDを書いた1個のファイル）自体は変更していない
# （tests/test-backup-vault.sh の `echo "$$" > "$LOCK"` 等の既存前提と完全互換）。
RECLAIM_MUTEX_DIR="${LOCK_FILE}.reclaim"

acquire_lock() {
  if try_create_lock; then
    trap 'rm -f "$LOCK_FILE"' EXIT
    return
  fi
  # 既に存在＝実行中 or stale。中身のPIDを見て判定する。
  local old_pid
  old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "既に実行中です（pid=${old_pid}）。今回はskipします。"
    exit 0
  fi
  # stale の疑い。1つのループに統一し、毎回まず「既に別プロセスが（回収
  # ミューテックスを介した経路・通常の初回取得経路のどちらであれ）有効なロックを
  # 取得済みでないか」を確認してから、取れていなければ回収ミューテックスの取得を
  # 試みる（Codex二次レビュー指摘・Minor対応: 旧実装は「回収ミューテックス取得後の
  # rm→再作成」が別プロセスとのごく短い競合で失敗すると、たとえその別プロセスが
  # 正常に取得して即座に完了しただけであっても即fail()していた。ループ先頭へ戻って
  # 現在の所有者を再確認する形にすることで、正常な競合を異常終了にしない）。
  local attempt
  for attempt in $(seq 1 20); do
    old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "ロック再取得中に別プロセスが先に取得しました（pid=${old_pid}）。今回はskipします。"
      exit 0
    fi
    if mkdir "$RECLAIM_MUTEX_DIR" 2>/dev/null; then
      # ミューテックス取得後に改めてPIDを読み直す（ここまでの間に別プロセスが
      # 有効な新規ロックを再作成していないか、古い判定を使い回さず再確認する）。
      old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
      if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        rmdir "$RECLAIM_MUTEX_DIR" 2>/dev/null || true
        log "既に実行中です（pid=${old_pid}）。今回はskipします。"
        exit 0
      fi
      warn "stale なロックファイルを検出しました（pid=${old_pid:-unknown} は生存していません）。解除して続行します: $LOCK_FILE"
      rm -f "$LOCK_FILE"
      local created=0
      try_create_lock && created=1
      rmdir "$RECLAIM_MUTEX_DIR" 2>/dev/null || true
      if [[ "$created" -eq 1 ]]; then
        trap 'rm -f "$LOCK_FILE"' EXIT
        return
      fi
      # rm直後・再作成までのごく一瞬に、ミューテックスを介さない通常の初回取得
      # （try_create_lock・関数先頭）を行う別プロセスが先にロックを取得できた
      # 場合（正常な競合。二重実行にはならない）。即fail()せずループ先頭へ戻り、
      # 現在の所有者を再確認する。
      continue
    fi
    # 回収ミューテックスは他プロセスが保持中。少し待ってから再試行する。
    sleep 0.05
  done
  fail "ロック取得に失敗しました（他プロセスとの競合が解消しません。回収ミューテックス（${RECLAIM_MUTEX_DIR}）が長時間残っている場合は、前回実行がクラッシュした痕跡の可能性があります。実行中のbackup-vault.shプロセスが無いことを確認してから手動で削除してください: rmdir ${RECLAIM_MUTEX_DIR}）: $LOCK_FILE"
}
acquire_lock

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

if git -C "$VAULT" diff --cached --quiet; then
  log "変更なし。commit をスキップします"
else
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

# --- 6. 埋め込みインデックスのbest-effort更新（外部脳ハイブリッド検索・柱①）---
# 毎時のvault-backup相乗り（設計書§1柱①・§2.2・§3(b)採用案）。Vaultのcommit/pushとは
# 独立した処理のため、失敗してもこのスクリプト自体はFAILにしない（best-effort＝
# インデックス更新はバックアップの必須要件ではない。update_embedding_index.py自身が
# Ollama不通等をfail-openでexit 0にする設計だが、万一非0で終わっても無視する）。
UPDATE_EMBEDDING_INDEX="${UPDATE_EMBEDDING_INDEX_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vault-agents/update_embedding_index.py}"
if [[ -f "$UPDATE_EMBEDDING_INDEX" ]]; then
  PYTHON_BIN_FOR_INDEX="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
  if "$PYTHON_BIN_FOR_INDEX" "$UPDATE_EMBEDDING_INDEX" --vault "$VAULT"; then
    log "埋め込みインデックス更新を実行しました"
  else
    warn "埋め込みインデックス更新が非0終了しました（best-effort・バックアップ自体は正常完了扱い）"
  fi
else
  warn "update_embedding_index.pyが見つからないためインデックス更新をskipしました: $UPDATE_EMBEDDING_INDEX"
fi

log "done."
