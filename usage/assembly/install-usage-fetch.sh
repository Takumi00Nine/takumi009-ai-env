#!/usr/bin/env bash
# 使用率取得器 LaunchAgent (usage/assembly/com.takumi009.usage-fetch.plist) を
# $HOME/Library/LaunchAgents へ配置し、launchctl へ bootstrap+enable する
# （ai-brain/assembly/install-backup.sh と同型の直線 installer。旧ジョブからの移行機構は
# 2026-09-19 に役目を終えて撤去した）。
#
# plist は __AIENV_HOME__ プレースホルダを実ホームパスへ置換してから配置する
# （正本は repo 側の plist。~/Library/LaunchAgents の実ファイルは毎回上書きする）。
# plist は RunAtLoad=true なので bootstrap 直後に 1 回取得が走る。
#
# 順序＝plist 配置 → bootout（無ければ無視）→ bootstrap
#      （失敗時 enable→再試行 1 回）→ enable
#
# 使い方:
#   usage/assembly/install-usage-fetch.sh            # 実行（配置 + launchctl (re)load）
#   usage/assembly/install-usage-fetch.sh --dry-run  # 状態表示のみ（何もしない）
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#
# テスト専用: SKIP_LAUNCHCTL=1 にすると plist 配置だけ行い launchctl を一切
# 呼ばない（ai-brain/assembly/install-backup.sh と同名・同意味）。
#
# (README "Usage fetcher" 2026-09-19) `check-drift.sh` reports `[USAGE-FETCH-*]` / `[USAGE-LOCK-STUCK]` if the job is not loaded, disabled, or stops updating.
# Sub machines are not given this LaunchAgent automatically (`install-sub.sh` never installs LaunchAgents, and `update-sub.sh` does not re-run this installer) — run `usage/assembly/install-usage-fetch.sh` there yourself if you want usage tracking on that machine too.

set -euo pipefail

: "${SKIP_LAUNCHCTL:=0}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLIST_NAME="com.takumi009.usage-fetch.plist"
SRC="$DIR/usage/assembly/$PLIST_NAME"
FETCHER="$DIR/usage/executor/usage-fetch.sh"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="${PLIST_NAME%.plist}"
DOMAIN="gui/$(id -u)"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-usage-fetch] $*"; }
warn() { echo "[install-usage-fetch] WARN: $*" >&2; }
fail() { echo "[install-usage-fetch] FAIL: $*" >&2; exit 1; }

render_plist() {
  local escaped_home
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$SRC"
}

[ -e "$SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: ${SRC}"
[ -e "$FETCHER" ] || fail "取得スクリプトが見つかりません（checkout破損の可能性）: ${FETCHER}"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"
  log "[dry-run] would run: launchctl bootout $DOMAIN/$LABEL （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $DOMAIN $DEST"
  log "[dry-run] would run: launchctl enable $DOMAIN/$LABEL"
  log "[dry-run] 完了。実際の変更は一切行っていません。"
  exit 0
fi

# mktemp→mv で原子的に生成する（ai-brain/assembly/install-backup.sh と同方式）
mkdir -p "$(dirname "$DEST")" || fail "LaunchAgentsディレクトリを作成できませんでした: $(dirname "$DEST")"
tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").aienv-tmp.XXXXXX")" || fail "一時ファイルを作成できませんでした。"
render_plist > "$tmp" || { rm -f "$tmp"; fail "plistの生成に失敗しました。"; }
mv -f "$tmp" "$DEST" || { rm -f "$tmp"; fail "plistの配置（mv）に失敗しました。"; }
log "generated: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"

if [ "$SKIP_LAUNCHCTL" = "1" ]; then
  log "SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします（テスト用）"
  log "done."
  exit 0
fi

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
bootstrap_ok=0
if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
  bootstrap_ok=1
else
  # disabled override が残っていると enable するまで bootstrap が失敗し続ける
  # （install-backup.sh と同じ対処＝enable してから 1 回だけ再試行）。
  warn "launchd: bootstrap failed for ${LABEL}（disabled状態の可能性があるため、enable後に1回だけ再試行します）"
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null && bootstrap_ok=1
fi
[ "$bootstrap_ok" = "1" ] \
  || fail "launchctl bootstrap に失敗しました（enable経由の再試行も失敗）。手動でロードしてください: launchctl enable ${DOMAIN}/${LABEL} && launchctl bootstrap ${DOMAIN} ${DEST}"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null \
  || fail "launchctl enable に失敗しました。手動でenableしてください: launchctl enable ${DOMAIN}/${LABEL}"
log "launchd: (re)loaded ${LABEL}（RunAtLoad=true のため直後に1回取得が走ります）"
log "done."
