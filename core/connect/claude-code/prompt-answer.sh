#!/bin/bash
# UserPromptSubmit hook（ライブ名 ~/.claude/hooks/code27-call-clear.sh）: 本人の入力を検知し「応答」を知らせる。
#
# 本人が Claude Code に入力した＝応答した、とみなし、知らせの共通部品へ応答を渡す（共通部品が口を
# 切り離して起動し、ここは待たない＝届け先は台帳の「知らせ」列が決める）。同じイベントは背景タスクの
# 完了通知（prompt が <task-notification> で始まる）でも発火するので、それだけは無視する。
# 判定できないとき（stdin 空・JSON でない・jq 不在）は安全側＝応答する。
# 常に終了 0（入力を止めない）・標準出力は空（Claude の文脈に入るため）。秘密は扱わない。

# 共通部品は実体の位置から引く＝ライブ名の symlink から起動されてもリンクを辿る。
self="${BASH_SOURCE[0]:-$0}"
while [ -L "$self" ]; do
  dir="$(cd "$(dirname "$self")" && pwd)"
  self="$(readlink "$self")"
  case "$self" in /*) ;; *) self="$dir/$self" ;; esac
done
ROOT="$(cd "$(dirname "$self")/../../.." && pwd)"

if command -v jq >/dev/null 2>&1 \
  && jq -e '.prompt | type == "string" and test("^\\s*<task-notification>")' >/dev/null 2>&1; then
  exit 0
fi
# shellcheck source=core/executor/notice.sh
. "$ROOT/core/executor/notice.sh" 2>/dev/null || exit 0
notice_answer </dev/null >/dev/null
exit 0
