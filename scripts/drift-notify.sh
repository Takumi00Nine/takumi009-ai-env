#!/usr/bin/env bash
# scripts/check-drift.sh を実行し、drift件数が1件以上あれば macOS 通知を出す薄いラッパ
# （2026-07-08 adoption-critic指摘「陳腐化防止の宿題」対応）。
#
# check-drift.sh は fail-fast しない設計（常にexit 0）のため、drift の有無は
# exit code ではなく標準出力の「総drift件数: N」行をパースして判定する。
#
# launchagents/com.takumi009.drift-check.plist から週1（月曜09:30）で無人実行される
# 前提のスクリプト（install-main.sh が設置する。**メイン専用**）。
#
# 使い方: scripts/drift-notify.sh
#
# 注意: 本スクリプトは launchagents/com.takumi009.drift-check.plist 経由で定期実行される
# 想定（手動実行も可能）。

set -uo pipefail  # check-drift.sh 自体は失敗させない設計のため -e は使わない

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[drift-notify] $*"; }
warn() { echo "[drift-notify] WARN: $*" >&2; }

[ -x "$DIR/scripts/check-drift.sh" ] || { warn "scripts/check-drift.sh が見つかりません（checkout破損の可能性）"; exit 0; }

OUTPUT="$("$DIR/scripts/check-drift.sh" 2>&1)"
printf '%s\n' "$OUTPUT"

# 「総drift件数: N」行から件数を取り出す（BSD sed互換のためGNU拡張の \+ は使わない）。
DRIFT_COUNT="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*総drift件数: \([0-9][0-9]*\).*/\1/p' | tail -1)"

if [ -z "$DRIFT_COUNT" ]; then
  warn "check-drift.sh の出力から総drift件数を読み取れませんでした（出力形式が変わった可能性）"
  exit 0
fi

if [ "$DRIFT_COUNT" -eq 0 ] 2>/dev/null; then
  log "drift 0件（正常）。通知しません。"
  exit 0
fi

log "drift ${DRIFT_COUNT}件を検知しました。通知します。"
if command -v osascript >/dev/null 2>&1; then
  MSG="drift ${DRIFT_COUNT}件を検知しました（scripts/check-drift.sh で詳細確認してください）"
  TITLE="takumi009-ai-env: drift検知"
  osascript -e "display notification \"${MSG}\" with title \"${TITLE}\"" || warn "osascript による通知に失敗しました"
else
  warn "osascript が見つかりません（通知をスキップ。ログのみ）"
fi
