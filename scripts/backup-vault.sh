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
#   3. VAULT が git repo でなければ git init（ローカルのみ・リモートは作らない）
#   4. git add -A → 差分があれば commit（"backup: YYYY-MM-DD HH:MM"）
#   5. remote 'origin' が設定済みの場合のみ push。未設定なら commit までで
#      WARN表示して終了する（絶対厳守ルール②＝publicリポジトリ化・remote作成は
#      本人が行う、の精神に準拠。このスクリプトはremoteを勝手に作らない）
#
# パスは $HOME 相対（VAULT・LOCK_FILE は環境変数で上書き可＝ユニットテスト用。
# 本番実行時は既定値のまま呼べば良い）。

set -euo pipefail

: "${VAULT:=$HOME/Data/obsidian}"
: "${LOCK_FILE:=${TMPDIR:-/tmp}/aienv-backup-vault.lock}"
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
  warn "stale なロックファイルを検出しました（pid=${old_pid:-unknown} は生存していません）。解除して続行します: $LOCK_FILE"
  rm -f "$LOCK_FILE"
  if try_create_lock; then
    trap 'rm -f "$LOCK_FILE"' EXIT
    return
  fi
  # 再取得にも失敗した＝ちょうど同じタイミングで別プロセスも同じstaleロックを
  # 検出し、先に解除→再取得を済ませていた可能性が高い（この経路自体が稀な
  # 競合ケースへの対処であり、極めて低頻度の二重レース）。相手が実際に生きて
  # いれば「実行中なのでskip」で静かに譲り、無人バッチでの一時的な失敗ログを
  # 避ける（Codexレビュー指摘・Minor）。原因不明の失敗のみFAILにする。
  old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "ロック再取得中に別プロセスが先に取得しました（pid=${old_pid}）。今回はskipします。"
    exit 0
  fi
  fail "ロック取得に失敗しました（原因不明。再試行してください）: $LOCK_FILE"
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
  git -C "$VAULT" init -q
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
