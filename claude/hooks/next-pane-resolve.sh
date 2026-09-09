#!/bin/bash
# Next Projectペイン番号参照の自動解決フック（UserPromptSubmit）
# プロンプトに「Next/ネクスト」＋「番/ペイン」が含まれるとき、
# cmux-next-watch.sh --list（番号<TAB>正式プロジェクト名<TAB>next値<TAB>区分）の
# 出力を additionalContext として注入する。AI はツールを叩かずに番号→
# プロジェクトを解決できる（正本: Decisions/2026-08-05-next-pane-replaces-feed）。
# 「Next Task」への言及（Next Task 常駐枠。cmux-session-todo 設計参照）は
# Next Project とは別物なので、Next Task の言及を消してから従来条件を評価する
# ことで誤注入を防ぐ（FR-45・cmux-session-todo/docs/design.md §8）。
# どの経路で失敗しても何も出力せず正常終了する（fail-silent・会話を妨げない）。

LIST_CMD="${NEXT_RESOLVE_LIST_CMD:-$HOME/work/tools/cmux-next-watch/cmux-next-watch.sh}"

prompt=$(jq -r '.prompt // ""' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0

# Next Task への言及（表記ゆれ＝Next Task/Next-Task/Next_Task/NextTask/
# ネクストタスク、大小文字非依存）を残りの判定から取り除く。BSD sed には
# 大小文字非依存の `I` 修飾子が無いので文字クラスで書く。
residue="$(printf '%s' "$prompt" | sed -E '
  s/[Nn][Ee][Xx][Tt][[:space:]_-]*[Tt][Aa][Ss][Kk]//g
  s/[Nn][Ee][Xx][Tt][[:space:]_-]*タスク//g
  s/ネクスト[[:space:]]*タスク//g')"

printf '%s' "$residue" | grep -qiE 'next|ネクスト' || exit 0
printf '%s' "$residue" | grep -qE '番|ペイン' || exit 0
[ -x "$LIST_CMD" ] || exit 0

list=$("$LIST_CMD" --list 2>/dev/null) || exit 0
[ -n "$list" ] || exit 0

jq -n --arg ctx "NextProjectペイン番号対応表（この瞬間の表示順。ユーザーの「Nextの N 番」はこの表で解決する）:
$list" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
