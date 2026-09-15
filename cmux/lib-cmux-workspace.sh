# cmux ワークスペース識別子の解決規則（共通部品・cmux-session-todo 設計
# §21・C-11）。cmux-task-watch.sh（常駐描画・`--list`）と
# cmux-task-declare.sh（宣言 CLI）の両方から source される。単体では実行
# しない（関数定義のみ、副作用なし）。lib は環境変数を読まない。上書き値・
# cmux 実体・タイムアウトは呼び出し側が引数で渡す（設計 §1.4）。
#
# `run_with_timeout` に依存するため、呼び出し側は本 lib より先に
# lib-model-view.sh を source すること。
#
# lib の関数はすべて、内部で呼ぶ cmux・jq の stderr を 2>/dev/null で
# 捨てる。理由行を出すのは公開側（cmux-task-watch.sh / cmux-task-declare.sh）
# だけで、子コマンドの出力が「--list の stderr は固定の1行」（FR-54）等の
# 契約を破らないようにする。
#
# 使い方:
#   LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)"
#   . "$LIB_DIR/lib-model-view.sh"
#   . "$LIB_DIR/lib-cmux-workspace.sh"

# cmux --json identify を1回呼ぶ。
#   $1=cmux実体 $2=タイムアウト秒
# stdout: "<caller_ref><TAB><focused_ref>"（値が無ければ空文字）。
# rc=0: 呼び出しが成功し JSON を解析できた。
# rc=1: 呼び出しが非0・打ち切り・JSON 解析失敗（終了コード0のまま壊れた
#       応答を返す場合を含む＝fixture S-5）。
ws_identify_refs() {
  local bin="$1" timeout="$2" raw
  raw="$(run_with_timeout "$timeout" "$bin" --json identify 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -r '
    "\(.caller.workspace_ref // "")\t\(.focused.workspace_ref // "")"
  ' 2>/dev/null
}

# cmux --json workspace list を1回呼ぶ。
#   $1=cmux実体 $2=タイムアウト秒
# stdout: 生のJSON。
# rc=0: 取得でき、かつ .workspaces が配列である。
# rc=1: それ以外（呼び出し失敗・打ち切り・JSONとして解析できない・
#       .workspaces が配列でない＝終了コード0のまま壊れた応答を返す場合を
#       含む＝fixture S-5）。
ws_list_json() {
  local bin="$1" timeout="$2" raw
  raw="$(run_with_timeout "$timeout" "$bin" --json workspace list 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -e '(.workspaces // []) | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$raw"
}

# JSON文字列 $1 中の workspace 一覧から、ref($2) に一致する id を返す。
# cmux を呼ばない純関数。ref が空、見つからない、id が非空文字列でない
# 場合は rc=1・出力なし。
ws_uuid_for_ref() {
  local json="$1" ref="$2" uuid
  [ -n "$ref" ] || return 1
  uuid="$(printf '%s' "$json" | jq -r --arg r "$ref" '
    (.workspaces // [])[]
    | select(.ref == $r and (.id | type) == "string" and (.id | length) > 0)
    | .id
  ' 2>/dev/null | head -n1)"
  [ -n "$uuid" ] || return 1
  printf '%s' "$uuid"
}

# $3（uuid|ref|index）を workspace list から UUID へ解決する。
#   $1=cmux実体 $2=タイムアウト秒 $3=uuid|ref|index
# 現行 cmux-task-declare.sh:resolve_workspace_uuid の照合規則（uuid → ref →
# .index を一意キーとして照合。既存の修正込み）をそのまま移す。畳まれて
# いた非0を2値へ分ける。
# rc=1: workspace list の取得に失敗。
# rc=2: 取得はできたが値が見つからない。
ws_resolve_uuid() {
  local bin="$1" timeout="$2" val="$3" json uuid
  json="$(ws_list_json "$bin" "$timeout")" || return 1
  uuid="$(printf '%s' "$json" | jq -r --arg v "$val" '
    (.workspaces // []) as $ws
    | (($ws[] | select(.id == $v) | .id) // ($ws[] | select(.ref == $v) | .id) // empty)
  ' 2>/dev/null | head -n1)"
  if [ -z "$uuid" ]; then
    case "$val" in
      ''|*[!0-9]*) : ;;
      *)
        # 実 cmux の workspace list の .index は 0 始まりであり配列位置とは
        # 限らない（実査: `cmux --json workspace list` の .index=0）。配列位置
        # ではなく .index フィールドを一意キーとして照合する（verifier実装
        # レビュー2巡目 #9・MAJOR）。
        uuid="$(printf '%s' "$json" | jq -r --argjson i "$val" '
          (.workspaces // []) | map(select(.index == $i)) | .[0].id // empty
        ' 2>/dev/null)"
        ;;
    esac
  fi
  [ -n "$uuid" ] || return 2
  printf '%s' "$uuid"
}

# 「自分がいるワークスペース（caller）」を解決する（cmux-task-declare.sh の
# 既定対象・常駐描画の focused 解決の材料）。
#   $1=cmux実体 $2=タイムアウト秒
# ws_resolve_uuid は呼ばない（「取得失敗」と「見つからない」を1本の非0に
# 畳んでいた元実装の性質を引き継ぐため、rc=1/rc=2 の書き分けが実現できない
# ＝設計 §21）。自分で段階評価する。
# rc=1: cmux 呼び出しか JSON 解析が失敗（呼び出し側は「cmux 応答なし」）。
# rc=2: caller が取れない・workspace list に無い（呼び出し側は「対象不明」）。
ws_caller_uuid() {
  local bin="$1" timeout="$2" refs caller_ref json
  refs="$(ws_identify_refs "$bin" "$timeout")" || return 1
  # タブ区切りの分解は "IFS=タブ read" ではなくパラメータ展開で行う。
  # bash は IFS に設定した文字がタブ等の「IFS空白類」に該当すると、先頭の
  # 空フィールドを黙って読み飛ばす（caller が空文字＝null のとき、後続の
  # focused の値を caller 側へ誤って詰めてしまう＝実測で確認済みの罠）。
  caller_ref="${refs%%$'\t'*}"
  [ -n "$caller_ref" ] || return 2
  json="$(ws_list_json "$bin" "$timeout")" || return 1
  ws_uuid_for_ref "$json" "$caller_ref" || return 2
}
