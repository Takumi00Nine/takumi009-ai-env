#!/usr/bin/env bash
# 共有シェルライブラリ: macOS通知（osascript経由）
# （2026-07-16簡素化・cleanup決定#10・PR1.5③）。
#
# 抽出元: 旧 scripts/drift-notify.sh（週次drift通知ラッパ・本簡素化で削除済み。
# 全文は `git log -p -- scripts/drift-notify.sh` 参照）。scripts/maintenance.sh
# （週次ランナー・PR2）のPhase 3「異常時のみmacOS通知」がこの関数を使う。
#
# 呼び出し規約:
#   notify_macos <title> <message>
#   戻り値: 0=通知成功／1=osascript実行失敗／2=osascriptが見つからない
#   （いずれも呼び出し元の処理を止めない前提のfail-open設計＝通知失敗そのものを
#   致命的エラーにしない。標準エラー出力にWARNを残すのみ）。

notify_macos() {
  local title="$1" message="$2"
  if ! command -v osascript >/dev/null 2>&1; then
    echo "WARN: osascript が見つかりません（通知をスキップ。ログのみ）" >&2
    return 2
  fi
  # title/message中のダブルクォート・バックスラッシュをエスケープしてから
  # AppleScript文字列リテラルへ埋め込む（インジェクション対策。旧drift-notify.shは
  # 数値のみを埋め込む用途に限定されていたためエスケープが無かったが、本関数は
  # 汎用の呼び出し元を想定するため必須にする）。
  local safe_title safe_message
  safe_title="${title//\\/\\\\}"
  safe_title="${safe_title//\"/\\\"}"
  safe_message="${message//\\/\\\\}"
  safe_message="${safe_message//\"/\\\"}"
  if osascript -e "display notification \"${safe_message}\" with title \"${safe_title}\"" 2>/dev/null; then
    return 0
  fi
  echo "WARN: osascript による通知に失敗しました" >&2
  return 1
}
