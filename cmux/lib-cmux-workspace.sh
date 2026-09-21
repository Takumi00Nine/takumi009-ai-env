# cmux ワークスペース識別子の解決規則（共通部品・cmux-session-todo 設計
# §21・C-11）と宣言記録の読み手（v6・設計 §41.3.2 案 A (b)・A-v6-2）、
# 宣言先解決部品（v7・設計 §42.4・D-v7-6＝focused 解決と記録の破損判定兼引き）。
# cmux-task-model.sh（Task 供給側 `--list`／`--frame`）・cmux-next-model.sh
# （Project 供給側 `--focus`）・cmux-task-declare.sh（宣言 CLI）・
# claude/hooks/bootstrap-vault.sh（SessionStart の ⑥＝宣言状態）から source
# される。単体では実行しない（関数定義と検査式の定数だけ、副作用なし）。
# lib は環境変数を読まない。上書き値・cmux 実体・タイムアウト・記録ファイルの
# パスは呼び出し側が引数で渡す（設計 §1.4）。
#
# `run_with_timeout` に依存するため、呼び出し側は本 lib より先に
# lib-model-view.sh を source すること。
#
# lib の関数はすべて、内部で呼ぶ cmux・jq の stderr を 2>/dev/null で
# 捨てる。理由行を出すのは呼び出し側だけで、子コマンドの出力が
# 「--list の stderr は固定の1行」（FR-54）等の契約を破らないようにする。
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

# --- 宣言記録の読み手（v6・設計 §41.6・A-v6-2）------------------------------
# 記録ファイル（既定 ~/.config/cmux-task-watch/workspaces.json・書き手は宣言
# CLI だけ＝FR-113）の破損判定・slug の妥当性・UUID→slug の引きを 1 か所に置く。
# 旧 cmux-task-declare.sh／cmux-task-model.sh の複製 2 か所をここへ移した
# （検査式・規則は不変）。書き込みの経路は持たない（読むだけ）。

# 記録ファイルの検査式（設計 §3.1）＝`jq -s` で読んだ配列に対して真なら正常。
# ws_state_is_corrupt（2 段の読み手）と ws_declared_slug（宣言先解決部品）が
# 同じ式を使う（正本はここ 1 つ）。
WS_STATE_CHECK='
    length == 1
    and (.[0] | type == "object")
    and (.[0].version == 1)
    and (.[0].workspaces | type == "object")
    and (.[0].workspaces | to_entries | all(.value | type == "string"))
'

# 記録ファイル $1 が「破損」なら真（0）を返す（設計 §3.1 の検査式）。ファイル
# 不在は破損ではない（正常な初期状態＝非0）。jq 1 回。
ws_state_is_corrupt() {
  local file="$1"
  [ -f "$file" ] || return 1
  jq -s -e "$WS_STATE_CHECK" "$file" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] && return 1   # 検査式が真＝正常＝破損ではない
  return 0                      # 検査式が偽（非0終了）＝破損
}

# --- 宣言先解決部品（v7・設計 §42.5.2 段 1・2・D-v7-6・A-v7-1）--------------
# 「フォーカス中のワークスペース（focused）」の宣言先 slug を解決する 1 つの
# 部品。Task 供給側 `--frame` と Project 供給側 `--focus` が同じ部品を呼ぶ
# ＝段の順（cmux → 記録）と理由の順は両側で同一の実体。環境変数は読まない。
#   $1=cmux実体 $2=タイムアウト秒（identify・workspace list の各段に同じ値）
#   $3=宣言記録ファイル
# 段 1＝identify と workspace list の 2 つの JSON から UUID を抽出（jq 1 回・
# 照合規則は ws_uuid_for_ref と同じ＝ref の完全一致・id は非空文字列）。
# 段 2＝記録の破損判定と UUID の対の引き（jq 1 回・ws_state_is_corrupt →
# ws_state_lookup_slug の 2 段と同じ検査式・同じ引き方＝focused の UUID の
# 対だけ・DT-30）。外部プロセス＝cmux 2・jq 2（D-v7-12）。
# rc=0: slug を stdout へ（文法検査はしない＝呼び出し側が ws_slug_valid）。
# rc=1: cmux 呼び出しが非0・打ち切り・JSON 解析失敗・.workspaces が配列でない
#       （順1「cmux 応答なし」）。
# rc=2: focused の ref が空・一覧に無い（順2「対象不明」）。
# rc=3: 記録が破損（順3「宣言記録破損」）。
# rc=4: 対なし＝記録不在・UUID の対が無い・空文字（順4「未宣言」）。
ws_declared_slug() {
  local bin="$1" timeout="$2" file="$3" identify list uuid slug
  identify="$(run_with_timeout "$timeout" "$bin" --json identify 2>/dev/null)" || return 1
  list="$(run_with_timeout "$timeout" "$bin" --json workspace list 2>/dev/null)" || return 1
  uuid="$(printf '%s\n%s' "$identify" "$list" | jq -rs '
    if length == 2 and ((.[1].workspaces // []) | type) == "array" then . else error("cmux") end
    | (.[0].focused.workspace_ref // "") as $r
    | [ .[1].workspaces[]
        | select($r != "" and .ref == $r and (.id | type) == "string" and (.id | length) > 0)
        | .id ]
    | .[0] // ""
  ' 2>/dev/null)" || return 1
  [ -n "$uuid" ] || return 2
  [ -f "$file" ] || return 4
  slug="$(jq -rs --arg u "$uuid" '
    if ('"$WS_STATE_CHECK"') then (.[0].workspaces[$u] // "") else error("corrupt") end
  ' "$file" 2>/dev/null)" || return 3
  [ -n "$slug" ] || return 4
  printf '%s' "$slug"
}

# 記録ファイル $1 で UUID $2 に対応する slug を stdout へ出す（無ければ空・
# rc は常に 0）。呼び出し側は ws_state_is_corrupt を先に確認していること。
# 引くのは呼び出し元の UUID の対だけ（同じ slug の対が複数あっても先頭や
# slug 一致では引かない＝DT-30）。jq 1 回。
ws_state_lookup_slug() {
  local file="$1" uuid="$2"
  [ -f "$file" ] || return 0
  jq -r --arg u "$uuid" '(.workspaces // {})[$u] // empty' "$file" 2>/dev/null
  return 0
}

# slug $1 が FR-34 を満たすか判定する（A-Za-z0-9._- のみ・1文字以上・"." ".."
# そのものは不可）。外部プロセスを起こさない。
ws_slug_valid() {
  local s="$1"
  case "$s" in
    '') return 1 ;;
    .|..) return 1 ;;
  esac
  case "$s" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}
