#!/bin/bash
# Nextペイン番号参照の自動解決フック（UserPromptSubmit）
# プロンプトに「Next/ネクスト」＋「番/ペイン」が含まれるとき、
# cmux-next-watch.sh --list（番号<TAB>正式プロジェクト名<TAB>next値）の出力を
# additionalContext として注入する。AI はツールを叩かずに番号→プロジェクトを
# 解決できる（正本: Decisions/2026-08-05-next-pane-replaces-feed）。
# どの経路で失敗しても何も出力せず正常終了する（fail-silent・会話を妨げない）。

LIST_CMD="${NEXT_RESOLVE_LIST_CMD:-$HOME/work/tools/cmux-next-watch/cmux-next-watch.sh}"

prompt=$(jq -r '.prompt // ""' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0
printf '%s' "$prompt" | grep -qiE 'next|ネクスト' || exit 0
printf '%s' "$prompt" | grep -qE '番|ペイン' || exit 0
[ -x "$LIST_CMD" ] || exit 0

list=$("$LIST_CMD" --list 2>/dev/null) || exit 0
[ -n "$list" ] || exit 0

jq -n --arg ctx "Nextペイン番号対応表（この瞬間の表示順。ユーザーの「Nextの N 番」はこの表で解決する）:
$list" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
