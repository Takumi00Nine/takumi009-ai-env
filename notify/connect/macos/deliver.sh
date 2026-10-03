#!/bin/bash
# 送り手（macOS 通知・osascript）: deliver.sh <種別> <区分|-> <題> <本文> [<音>]
# 旧 notify/connect/macos/macos-notify.sh（notify_macos）と旧 Usage の送信を 1 つにした（v1.2 束 B）。
# 音の項目の有無で 2 つの呼び方を使い分け、osascript の引数は v1.1 の 2 経路と同じにする:
#   音なし（メンテ）＝AppleScript の文字列リテラルへ題・本文を埋め込む 1 引数
#   音つき（Usage）＝on run argv で本文・音を渡す（題は文字列リテラル）
# 題・本文のダブルクォート・バックスラッシュはエスケープしてから埋め込む（インジェクション対策）。
# 終了コード＝0 届けた／2 osascript が無い／1 失敗。

title="${3:-}" message="${4:-}" sound="${5:-}"
command -v osascript >/dev/null 2>&1 || exit 2
safe_title="${title//\\/\\\\}"
safe_title="${safe_title//\"/\\\"}"
safe_message="${message//\\/\\\\}"
safe_message="${safe_message//\"/\\\"}"
if [ -z "$sound" ]; then
  osascript -e "display notification \"${safe_message}\" with title \"${safe_title}\"" && exit 0
else
  osascript \
    -e 'on run argv' \
    -e "display notification (item 1 of argv) with title \"${safe_title}\" sound name (item 2 of argv)" \
    -e 'end run' \
    "$message" "$sound" && exit 0
fi
exit 1
