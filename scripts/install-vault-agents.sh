#!/usr/bin/env bash
# Vault育成系 LaunchAgent 2種（vault-inventory・fragments-log）を
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
  com.takumi009.fragments-log.plist
)
# 改名済みで撤去されたLaunchAgentラベル（2026-07-11: fragments-review →
# fragments-log。「review」だと人間レビュー待ちに誤解されるため改名）。
# 旧ラベルが読み込まれたまま残ると、削除済みの旧スクリプト
# （scripts/vault-agents/fragments_review.py）を参照し続けて実行のたびに
# 失敗し続ける（Codexレビュー指摘・Major）。旧plistが実在する環境でのみ
# bootout＋削除する一度限りの移行を行う（新規導入・移行済み環境では
# 該当ファイルが無いため何もしない＝fail-open）。
RETIRED_LABELS=(
  com.takumi009.fragments-review
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

# 撤去済みラベルの移行（改名前の旧LaunchAgentが残っていれば bootout + 削除）。
# 新規導入・移行済み環境ではplistが存在しないため何もしない。
migrate_retired_label() {
  local label="$1" dest="$HOME/Library/LaunchAgents/${1}.plist"
  [ -e "$dest" ] || return 0

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would migrate away retired LaunchAgent: $dest （launchctl bootout ${DOMAIN}/${label} の後、ファイル削除）"
    return 0
  fi

  if launchctl bootout "$DOMAIN/$label" 2>/dev/null; then
    rm -f "$dest"
    log "migrated: retired LaunchAgent removed ($dest)"
    return 0
  fi

  # bootout失敗を無条件でrmすると、「ロードされたまま停止に失敗した」場合でも
  # plistを消してしまい、次回実行時は既にplistが無いため冒頭のexistsチェックで
  # 移行処理自体がスキップされ、旧ジョブ（削除済みの fragments_review.py を参照）が
  # 動いたまま永久に取り残される（Codexレビュー指摘・Major）。launchctl print で
  # 実際にまだロードされているか確認し、ロードされているならplistを消さずに
  # 警告だけ出す（次回実行時に再試行できるようにする＝fail-safe）。
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    log "[WARN] $dest の bootout に失敗しましたが、ジョブはまだロードされたままです。削除済みの旧スクリプト（fragments_review.py）を参照して失敗し続ける可能性があります。手動で 'launchctl bootout ${DOMAIN}/${label}' を実行してから本スクリプトを再実行してください（plistは削除していません＝次回再試行可能）。"
    return 0
  fi

  # launchctl print でも見つからない＝そもそも未ロードだった（未ロードの
  # ジョブに対する bootout は失敗しうるが、この場合は安全に削除してよい）。
  rm -f "$dest"
  log "migrated: retired LaunchAgent removed ($dest)（未ロードのためbootoutは対象なしでした）"
}

for label in "${RETIRED_LABELS[@]}"; do
  migrate_retired_label "$label"
done

for name in "${PLISTS[@]}"; do
  install_one "$name"
done

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  log "done."
fi
