#!/usr/bin/env bash
# Vault バックアップ用 LaunchAgent (launchagents/com.takumi009.backup-vault.plist) を
# $HOME/Library/LaunchAgents へ配置し、launchctl へ (re)load する
# （dotfiles/install.sh の install_launchagent() と同方式＝実ファイルコピー。
# launchdのログイン時自動読込がsymlinked plistでは不安定なため実ファイルを配る）。
#
# plist は __AIENV_HOME__ プレースホルダを実ホームパスへ置換してから配置する
# （codex/config.toml と同じ理由＝plistはシェル変数展開されないプレーンなXML）。
# 2026-07-16簡素化（com.takumi009.vault-backup→backup-vault改名）時に導入した
# 退役ラベルの一度限りの移行コードは着手順3（2026-09-19）で撤去した。
#
# dotfiles/install.sh の install_launchagent() との違い（意図的）: あちらは
# bootstrap直後に `launchctl kickstart -k` で即時1回実行するが、本スクリプトは
# **bootstrap+enableのみ**で即時実行はしない（plist側もRunAtLoad=false）。
# 初回実行は次のStartInterval（最大6時間後）を待つか、準備が整ってから
# `launchctl kickstart -k gui/$(id -u)/com.takumi009.backup-vault` を手動実行する。
# (README "Setup" 2026-09-19) Both `install-backup.sh` and `install-maintenance.sh` only place the LaunchAgents (bootstrap+enable) — they do **not** trigger an immediate run (kickstart) (because initializing the Vault as a Git repository for the first time is meant to be a staged rollout. Either wait for the next scheduled run, or once you're ready, run `launchctl kickstart -k` manually).
#
# 使い方:
#   scripts/install-backup.sh            # 実行（配置 + launchctl (re)load。即時実行はしない）
#   scripts/install-backup.sh --dry-run  # 計画だけ表示（何もしない）
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#
# テスト専用: SKIP_LAUNCHCTL=1 にすると launchctl への実操作（bootout/bootstrap/
# enable）だけをskipする（plist配置は行う。scripts/install-sub.sh の
# SKIP_LAUNCHCTL と同じ考え方・同じ変数名）。

set -euo pipefail

: "${SKIP_LAUNCHCTL:=0}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_NAME="com.takumi009.backup-vault.plist"
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
warn() { echo "[install-backup] WARN: $*" >&2; }
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
  # ラベルがlaunchdのdisabled override（過去の手動`launchctl disable`等）に
  # 残っている場合、bootstrapはenableされるまで失敗し続けることがある
  # （macOS launchdの既知の挙動）。enableを試みてから1回だけ再試行する。
  warn "launchd: bootstrap failed for ${LABEL}（disabled状態の可能性があるため、enable後に1回だけ再試行します）"
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
    bootstrap_ok=1
  fi
fi

if [ "$bootstrap_ok" = "1" ]; then
  if launchctl enable "$DOMAIN/$LABEL" 2>/dev/null; then
    log "launchd: (re)loaded ${LABEL}（即時実行はしていません。初回は次のStartInterval、または準備が整い次第 'launchctl kickstart -k ${DOMAIN}/${LABEL}' を手動実行してください）"
  else
    # enableの失敗を無視するとラベルがdisabledのまま静かに残り、launchdは
    # 次回起動後も再enableされるまでロードしない（以前は`|| true`で握り潰していた）。
    fail "launchd: enable failed for ${LABEL}（手動でenableしてください: launchctl enable $DOMAIN/${LABEL}）"
  fi
else
  # $DESTを${DEST}と明示的に波括弧で囲む（bash 3.2+ja_JP.UTF-8で裸の$VAR直後に
  # 全角記号が続くと変数名境界を誤認識する実バグの回避・2026-07-16）。
  fail "launchd: bootstrap failed for ${LABEL}（disabled状態のenable経由リトライも失敗。手動でロードしてください: launchctl enable $DOMAIN/${LABEL} && launchctl bootstrap $DOMAIN ${DEST}）"
fi

log "done."
