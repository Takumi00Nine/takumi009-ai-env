#!/usr/bin/env bash
# Vault育成系 LaunchAgent 2種（vault-inventory・fragments-review）を
# $HOME/Library/LaunchAgents へ配置し、launchctl へ (re)load する（メイン専用機能）。
# install-backup.sh と同方式＝実ファイルコピー＋__AIENV_HOME__プレースホルダ置換。
#
# 対象スクリプト本体（scripts/vault-agents/*.py）は symlink 化せず、plist の
# ProgramArguments がリポジトリ内のパスを直接参照する（backup-vault.shと同じ扱い。
# python スクリプトはOSが決め打つ配置場所を持たないため、symlinkする理由が無い）。
#
# install-backup.sh と同じ理由で、bootstrap+enableのみを行い**即時kickstartはしない**
# （初回実行はStartCalendarIntervalの次回発火を待つか、準備が整ってから手動で
# `launchctl kickstart -k` する）。同じ理由で、収録した2plistは実際にデプロイ済みの
# ものから RunAtLoad を true→false に変更している（Codexレビュー指摘・Major：
# RunAtLoad=trueのままだと bootstrap 時点で即時実行され、「配置のみ・即時実行しない」
# という本スクリプトの設計と矛盾するため）。
#
# 使い方:
#   scripts/install-vault-agents.sh            # 実行（配置 + launchctl (re)load）
#   scripts/install-vault-agents.sh --dry-run  # 計画だけ表示（何もしない）
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="gui/$(id -u)"
PLISTS=(
  com.takumi009.vault-inventory.plist
  com.takumi009.fragments-review.plist
)

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-vault-agents] $*"; }
fail() { echo "[install-vault-agents] FAIL: $*" >&2; exit 1; }

for name in "${PLISTS[@]}"; do
  src="$DIR/launchagents/$name"
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
done
[ -d "$DIR/scripts/vault-agents" ] || fail "リポジトリに scripts/vault-agents/ が見つかりません（checkout破損の可能性）"

install_one() {
  local name="$1" src="$DIR/launchagents/$1" dest="$HOME/Library/LaunchAgents/$1" label="${1%.plist}"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would generate: $dest <- $src （__AIENV_HOME__ を $HOME へ置換）"
    log "[dry-run] would run: launchctl bootout ${DOMAIN}/${label} （既存があれば一旦アンロード。無ければ無視）"
    log "[dry-run] would run: launchctl bootstrap $DOMAIN $dest"
    log "[dry-run] would run: launchctl enable ${DOMAIN}/${label}"
    log "[dry-run] （kickstartは行わない＝即時実行しない設計。次回発火か手動kickstart待ち）"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  local escaped_home tmp
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").aienv-tmp.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$src" > "$tmp"
  mv "$tmp" "$dest"
  log "generated: $dest <- $src （__AIENV_HOME__ を $HOME へ置換）"

  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  if launchctl bootstrap "$DOMAIN" "$dest" 2>/dev/null; then
    launchctl enable "$DOMAIN/$label" 2>/dev/null || true
    log "launchd: (re)loaded ${label}（即時実行はしていません。準備が整い次第 'launchctl kickstart -k ${DOMAIN}/${label}' を手動実行してください）"
  else
    fail "launchd: bootstrap failed for ${label}（手動でロードしてください: launchctl bootstrap $DOMAIN $dest）"
  fi
}

for name in "${PLISTS[@]}"; do
  install_one "$name"
done

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  log "done."
fi
