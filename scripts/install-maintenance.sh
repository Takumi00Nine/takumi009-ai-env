#!/usr/bin/env bash
# 週次メンテナンスランナー（scripts/maintenance.sh）用 LaunchAgent
# (launchagents/com.takumi009.maintenance.plist) を $HOME/Library/LaunchAgents へ
# 配置しlaunchctlへ(re)loadする（メイン専用機能。install-backup.shと同方式＝
# 実ファイルコピー＋__AIENV_HOME__プレースホルダ置換）。2026-07-16簡素化時に
# 導入した退役4ラベルの一度限りの移行コードは着手順3（2026-09-19）で撤去した。
# bootstrap+enableのみを行い即時kickstartはしない（自動実行しない・ユーザーが
# 内容を確認したうえで実行する）。
# (README "Setup" 2026-09-19) Both `install-backup.sh` and `install-maintenance.sh` only place the LaunchAgents (bootstrap+enable) — they do **not** trigger an immediate run (kickstart) (because initializing the Vault as a Git repository for the first time is meant to be a staged rollout. Either wait for the next scheduled run, or once you're ready, run `launchctl kickstart -k` manually).
#
# 使い方: scripts/install-maintenance.sh [--dry-run]
# テスト専用: SKIP_LAUNCHCTL=1 で launchctl の実操作だけをskip（plist配置は行う）。
set -euo pipefail
: "${SKIP_LAUNCHCTL:=0}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_NAME="com.takumi009.maintenance.plist"
SRC="$DIR/launchagents/$PLIST_NAME"
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
log() { echo "[install-maintenance] $*"; }
warn() { echo "[install-maintenance] WARN: $*" >&2; }
fail() { echo "[install-maintenance] FAIL: $*" >&2; exit 1; }
[ -e "$SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SRC"
[ -f "$DIR/scripts/maintenance.sh" ] || fail "リポジトリに scripts/maintenance.sh が見つかりません（checkout破損の可能性）"

# __AIENV_USER__: plistのEnvironmentVariables.USER用（ヘッドレスClaude CLIのログイン
# 判定に必要・launchdはUSERを継承しないため明示設定・2026-09-10）。
if ! aienv_user="$(id -un)" || [ -z "$aienv_user" ]; then
  fail "id -un に失敗、または空でした（USER環境変数を解決できません）。手動確認: id -un"
fi

# plistの<string>値へ埋め込む前にXML特殊文字をエンティティへ変換し、sedの置換
# 文字列側の特殊文字（&・\・#）もエスケープする。
xml_escape_for_plist() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}
sed_replacement_escape() {
  printf '%s' "$1" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g'
}

# 対象ラベルがlaunchd上にロード済みかを確認する（新ラベルの「内容不変かつロード
# 済みならenableのみ」判定に使う）。unknown=domain照会が失敗＝fail-closedに倒す。
label_status() {
  local label="$1"
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then echo "skip"; return; fi
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then echo "unknown"; return; fi
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then echo "loaded"; else echo "not_loaded"; fi
}

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ、__AIENV_USER__ を ${aienv_user} へ置換）"
  log "[dry-run] would run: launchctl bootout $DOMAIN/$LABEL （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $DOMAIN $DEST"
  log "[dry-run] would run: launchctl enable $DOMAIN/$LABEL"
  log "[dry-run] （kickstartは行わない＝即時実行しない設計。次のStartCalendarIntervalか手動kickstart待ち）"
  log "[dry-run] 完了。実際の変更は一切行っていません。"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
escaped_home=$(sed_replacement_escape "$(xml_escape_for_plist "$HOME")")
escaped_user=$(sed_replacement_escape "$(xml_escape_for_plist "$aienv_user")")
tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").aienv-tmp.XXXXXX")"
trap 'rm -f "$tmp"' RETURN
sed -e "s#__AIENV_HOME__#${escaped_home}#g" -e "s#__AIENV_USER__#${escaped_user}#g" "$SRC" > "$tmp"

# 内容に変更が無く既にロード済みなら bootout→bootstrap をスキップする（再インス
# トール直後の失敗で正常稼働中のジョブを失う窓を避ける・Codexレビュー指摘Major
# 対応・2026-07-16）。domain照会がunknownなら破壊的操作に進まずexit 1する。
SKIP_RELOAD=0
if [ -f "$DEST" ] && cmp -s "$tmp" "$DEST" && [ "$SKIP_LAUNCHCTL" != "1" ]; then
  content_unchanged_status="$(label_status "$LABEL")"
  if [ "$content_unchanged_status" = "loaded" ]; then
    SKIP_RELOAD=1
  elif [ "$content_unchanged_status" = "unknown" ]; then
    rm -f "$tmp"
    fail "launchd: 新ラベル（${LABEL}）のロード状態をlaunchd照会で確認できませんでした。内容は既存のplistと同一のため、既存ジョブへの破壊的なbootout/bootstrapは行わず何もせず終了します。手動確認: launchctl print ${DOMAIN}"
  fi
fi

if [ "$SKIP_RELOAD" = "1" ]; then
  rm -f "$tmp"
  log "内容に変更なし・新ラベル（${LABEL}）は既にロード済みのため bootout/bootstrap をスキップします: $DEST"
  if launchctl enable "$DOMAIN/$LABEL" 2>/dev/null; then
    log "launchd: ${LABEL} は既存ロードのまま enable 状態を確認しました。"
  else
    fail "launchd: enable failed for ${LABEL}（既存ロードのdisabled解除に失敗。手動でenableしてください: launchctl enable $DOMAIN/${LABEL}）"
  fi
  log "done."
  exit 0
fi

mv "$tmp" "$DEST"
log "generated: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ、__AIENV_USER__ を ${aienv_user} へ置換）"
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
  # disabled override に残っているとenableされるまでbootstrapが失敗し続ける
  # （既知の挙動）。enableを試みてから1回だけ再試行する。
  warn "launchd: bootstrap failed for ${LABEL}（disabled状態の可能性があるため、enable後に1回だけ再試行します）"
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
    bootstrap_ok=1
  fi
fi
[ "$bootstrap_ok" = "1" ] || fail "launchd: bootstrap failed for ${LABEL}（disabled状態のenable経由リトライも失敗。手動でロードしてください: launchctl enable $DOMAIN/${LABEL} && launchctl bootstrap $DOMAIN ${DEST}）"

if launchctl enable "$DOMAIN/$LABEL" 2>/dev/null; then
  log "launchd: (re)loaded ${LABEL}（即時実行はしていません。初回は次のStartCalendarInterval、または準備が整い次第 'launchctl kickstart -k ${DOMAIN}/${LABEL}' を手動実行してください）"
else
  fail "launchd: enable failed for ${LABEL}（手動でenableしてください: launchctl enable $DOMAIN/${LABEL}）"
fi
log "done."
