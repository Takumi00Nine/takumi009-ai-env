#!/usr/bin/env bash
# Vault バックアップ用 LaunchAgent (launchagents/com.takumi009.vault-backup.plist) を
# $HOME/Library/LaunchAgents へ配置し、launchctl へ (re)load する
# （dotfiles/install.sh の install_launchagent() と同方式＝実ファイルコピー。
# launchdのログイン時自動読込がsymlinked plistでは不安定なため実ファイルを配る）。
#
# plist は __AIENV_HOME__ プレースホルダを実ホームパスへ置換してから配置する
# （codex/config.toml と同じ理由＝plistはシェル変数展開されないプレーンなXML）。
#
# dotfiles/install.sh の install_launchagent() との違い（意図的）: あちらは
# bootstrap直後に `launchctl kickstart -k` で即時1回実行するが、本スクリプトは
# **bootstrap+enableのみ**で即時実行はしない（plist側もRunAtLoad=false）。
# Vaultの初回git化は「Vault分割・呼称の中立化等が完了してから」という
# 段階的ロールアウトが前提（設計§4-3）のため、インストール＝即バックアップ実行
# にしてしまうと、その前提確認より先にVaultがgit管理下に入ってしまう恐れがある。
# 初回実行は次のStartInterval（最大1時間後）を待つか、準備が整ってから
# `launchctl kickstart -k gui/$(id -u)/com.takumi009.vault-backup` を手動実行する。
#
# 使い方:
#   scripts/install-backup.sh            # 実行（配置 + launchctl (re)load。即時実行はしない）
#   scripts/install-backup.sh --dry-run  # 計画だけ表示（何もしない）
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_NAME="com.takumi009.vault-backup.plist"
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

log() { echo "[install-backup] $*"; }
fail() { echo "[install-backup] FAIL: $*" >&2; exit 1; }

[ -e "$SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SRC"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"
  log "[dry-run] would run: launchctl bootout $DOMAIN/$LABEL （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $DOMAIN $DEST"
  log "[dry-run] would run: launchctl enable $DOMAIN/$LABEL"
  log "[dry-run] （kickstartは行わない＝即時実行しない設計。次のStartIntervalか手動kickstart待ち）"
  log "[dry-run] 完了。実際の変更は一切行っていません。"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"

# plistは symlink ではなく実ファイルとして配置する（dotfiles/install.shの
# install_launchagent()と同じ理由＝launchdのログイン時自動読込がsymlinked plist
# では不安定なため）。__AIENV_HOME__ を実ホームパスへ置換しつつ、mktemp書き込み
# →mvで原子的に生成する（scripts/install-main.shのgenerate_config_toml()と同方式）。
escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").aienv-tmp.XXXXXX")"
trap 'rm -f "$tmp"' RETURN
sed "s#__AIENV_HOME__#${escaped_home}#g" "$SRC" > "$tmp"
mv "$tmp" "$DEST"
log "generated: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  log "launchd: (re)loaded ${LABEL}（即時実行はしていません。初回は次のStartInterval、または準備が整い次第 'launchctl kickstart -k ${DOMAIN}/${LABEL}' を手動実行してください）"
else
  fail "launchd: bootstrap failed for ${LABEL}（手動でロードしてください: launchctl bootstrap $DOMAIN $DEST）"
fi

log "done."
