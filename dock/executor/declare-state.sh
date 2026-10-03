#!/bin/bash
# 宣言状態（Dock の SessionStart 寄与）: 案件宣言の宣言状態を ⑥ の 1 行で出す
# （cmux-session-todo v6・FR-112・NFR-19・設計 §41.6）。
# 使い方: stdin＝hook JSON（読み捨てる）。
#   --slots   {"slots":{"declare6":"<⑥ の 1 行>"}}（末尾に改行を付けない。SessionStart の合成器が起動する形）
#   引数なし  hook 形＝additionalContext に ⑥ の 1 行
# 共有部品（同じフォルダの lib＝呼び出し元ワークスペースの解決・宣言記録の読み手）を **source** して判定する。
# 宣言 CLI はどのサブコマンドも実行しない（AC-153 ③・D-v6-5）・`set` を呼ばない・記録も Vault も書かない。
# 失敗はすべて「宣言状態 不明」に倒し、終了コードと本文は取得結果に依存しない（fail-silent）。
# 共有部品の所在＝上書き口 BOOTSTRAP_CMUX_LIB_DIR（テスト用・DT-29）があればそれ、無ければ本寄与の実体位置
# （固定パス $HOME/work/… にしない＝F-108・D-v6-13）。cmux 実体・記録の置き場・呼び出し上限の既定と上書き口は
# 宣言 CLI と同一（CMUX_TASK_CMUX_BIN／CMUX_TASK_STATE／CMUX_TASK_CALL_TIMEOUT＝既定 5 秒）。
: "${BOOTSTRAP_CMUX_LIB_DIR:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DECLARE_STATE_FILE="${CMUX_TASK_STATE:-$HOME/.config/cmux-task-watch/workspaces.json}"
DECLARE_CMUX_BIN="${CMUX_TASK_CMUX_BIN:-cmux}"
# 宣言コマンドの絶対パス（4 状態すべての行に含める＝D-v6-7・AC-59 の「促す行が 1 行」不変）。
DECLARE_CMD='~/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh set <slug>'

# resolve_declare_state — 段 0〜3 を順に評価し最初の失敗で止まる（§41.6.2）。
# 結果＝DECLARE_STATE（declared／undeclared／unknown／corrupt）・DECLARE_SLUG。
# 段 0: 共有部品を source できる → 段 1: 記録を読む（破損 → corrupt・cmux を呼ばない）
# → 段 2: 呼び出し元の解決（identify → 一覧 → UUID。取得全体を 1 つの上限で包む＝
# D-v6-6・F-107。cmux 不在／非 0／caller 欠落／未知 ref／ハング → unknown）
# → 段 3: UUID を対で引く（対あり → declared／対なし → undeclared）。
# どの段の失敗も undeclared には倒さない。
DECLARE_STATE="unknown"
DECLARE_SLUG=""
resolve_declare_state() {
  local lib="$BOOTSTRAP_CMUX_LIB_DIR" timeout uuid slug
  DECLARE_STATE="unknown"
  DECLARE_SLUG=""
  [ -r "$lib/lib-model-view.sh" ] && [ -r "$lib/lib-cmux-workspace.sh" ] || return 0
  # shellcheck source=./lib-model-view.sh
  . "$lib/lib-model-view.sh" 2>/dev/null || return 0
  # shellcheck source=./lib-cmux-workspace.sh
  . "$lib/lib-cmux-workspace.sh" 2>/dev/null || return 0
  timeout="$(sanitize_interval "${CMUX_TASK_CALL_TIMEOUT:-}" 5)"
  if ws_state_is_corrupt "$DECLARE_STATE_FILE"; then
    DECLARE_STATE="corrupt"
    return 0
  fi
  # 取得全体（identify＋一覧）を 1 つの上限で包む。内側（段ごと）の既存保護はそのまま
  # ＝外側で打ち切った後の子孫は内側が 6 秒以内に消し、寄与はそれを待たない。
  uuid="$(run_with_timeout "$timeout" ws_caller_uuid "$DECLARE_CMUX_BIN" "$timeout" 2>/dev/null)" || return 0
  [ -n "$uuid" ] || return 0
  slug="$(ws_state_lookup_slug "$DECLARE_STATE_FILE" "$uuid" 2>/dev/null)"
  if [ -n "$slug" ]; then
    # 記録は書き手（宣言 CLI）が FR-34 で検証済み。手で壊された値は注入文に写さない。
    ws_slug_valid "$slug" || slug="（slug が不正＝記録を確認）"
    DECLARE_STATE="declared"
    DECLARE_SLUG="$slug"
  else
    DECLARE_STATE="undeclared"
  fi
  return 0
}

# compose_declare_line6 — ⑥ の 1 行を DECLARE_LINE6 へ。固定語は「その状態の行にだけ
# 現れる語」（D-v6-15）＝`宣言済み`／`未宣言`／`宣言状態 不明`／`宣言記録破損`。
compose_declare_line6() {
  case "$DECLARE_STATE" in
    declared)
      DECLARE_LINE6="⑥ 案件宣言＝宣言済み: ${DECLARE_SLUG}（このワークスペースの宣言は cmux 再起動後も同じワークスペースで生きる。別の案件へ切り替えるときだけ ${DECLARE_CMD} を呼び直す・実行はリーダーであってフックではない）" ;;
    undeclared)
      DECLARE_LINE6="⑥ 案件宣言＝未宣言。プロジェクトが確定したら1回だけ宣言する: ${DECLARE_CMD}（実行はリーダーであってフックではない）" ;;
    corrupt)
      DECLARE_LINE6="⑥ 案件宣言＝宣言状態 不明（宣言記録破損: ${DECLARE_STATE_FILE}＝set は記録破損時に拒否される。記録の確認を先に）。直してからプロジェクトが確定したら1回だけ宣言する: ${DECLARE_CMD}（実行はリーダーであってフックではない）" ;;
    *)
      DECLARE_LINE6="⑥ 案件宣言＝宣言状態 不明（cmux の応答なし・呼び出し元ワークスペース未確定など）。プロジェクトが確定したら1回だけ宣言する: ${DECLARE_CMD}（実行はリーダーであってフックではない）" ;;
  esac
}

# stdin（hook JSON）は使わないが読み切る（書き手のパイプを先に閉じない）。
cat >/dev/null 2>&1 || true

resolve_declare_state 2>/dev/null
compose_declare_line6

if [ "${1:-}" = "--slots" ]; then
  jq -n --arg l "$DECLARE_LINE6" '{slots: {declare6: $l}}'
else
  jq -n --arg l "$DECLARE_LINE6" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $l}}'
fi
