#!/bin/bash
# Task の宣言 CLI（cmux-session-todo 設計 §3.3）。
# ワークスペース（安定識別子＝UUID）とプロジェクト slug の対を
# ~/.config/cmux-task-watch/workspaces.json（既定）へ記録する。
#
#   cmux-task-declare.sh set   <slug> [--workspace <uuid|ref|index>]
#   cmux-task-declare.sh unset          [--workspace <uuid|ref|index>]
#   cmux-task-declare.sh list
#   cmux-task-declare.sh prune
#
# 書き手はこのスクリプトだけ（原子的置換＝設計 §3.2）。読み手（cmux-task-watch.sh）
# は cat するだけで書き換えない。Vault にも cmux にも set/unset/list/prune の
# いずれも書込しない（prune が触るのは cmux の読み取り系だけ＝FR-23 の例外は
# 「常駐」に対する制約で、本 CLI は §3.3 の D-8 により list-windows も使う）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)"
if [ ! -r "$LIB_DIR/lib-model-view.sh" ]; then
  echo "lib-model-view.sh が見つかりません: $LIB_DIR/lib-model-view.sh" >&2
  exit 1
fi
if [ ! -r "$LIB_DIR/lib-cmux-workspace.sh" ]; then
  echo "lib-cmux-workspace.sh が見つかりません: $LIB_DIR/lib-cmux-workspace.sh" >&2
  exit 1
fi
# shellcheck source=./lib-model-view.sh
. "$LIB_DIR/lib-model-view.sh"
# shellcheck source=./lib-cmux-workspace.sh
. "$LIB_DIR/lib-cmux-workspace.sh"

VAULT="${CMUX_TASK_VAULT:-$HOME/Data/obsidian}"
STATE_FILE="${CMUX_TASK_STATE:-$HOME/.config/cmux-task-watch/workspaces.json}"
CMUX_BIN="${CMUX_TASK_CMUX_BIN:-cmux}"
CALL_TIMEOUT="$(sanitize_interval "${CMUX_TASK_CALL_TIMEOUT:-}" 5)"

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-task-declare.sh set   <slug> [--workspace <uuid|ref|index>]
  cmux-task-declare.sh unset          [--workspace <uuid|ref|index>]
  cmux-task-declare.sh list
  cmux-task-declare.sh prune
EOF
}

# 記録の読み手（slug の妥当性・破損判定）は共有 lib（lib-cmux-workspace.sh の
# ws_slug_valid・ws_state_is_corrupt＝v6 A-v6-2）。ここは薄いラッパ（規則・
# 検査式・終了コードは不変）。書き手は本 CLI だけのまま（FR-113）。

# slug が FR-34 を満たすか判定する（A-Za-z0-9._- のみ・1文字以上・"." "..".
# そのものは不可）。
slug_valid() { ws_slug_valid "$1"; }

# 記録ファイルが「破損」かどうかを判定する（設計 §3.1）。ファイル不在は
# 破損ではない（正常な初期状態）。破損なら真（0）を返す。
state_is_corrupt() { ws_state_is_corrupt "$STATE_FILE"; }

# 記録ファイルを stdout へ出す（無ければ空の骨格）。呼び出し側は
# state_is_corrupt を先に確認していること。
read_state_json() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    printf '{"version":1,"workspaces":{}}'
  fi
}

# $1（uuid|ref|index）を workspace list から UUID へ解決する（薄いラッパ。
# 本体は共有 lib の ws_resolve_uuid＝設計 §21）。解決できなければ非0
# （出力なし）。rc=1（取得失敗）／rc=2（見つからない）のどちらでも、
# 呼び出し側（resolve_target）は0／非0しか見ないので挙動は変わらない。
resolve_workspace_uuid() {
  local val="$1" uuid
  uuid="$(ws_resolve_uuid "$CMUX_BIN" "$CALL_TIMEOUT" "$val")" || return 1
  printf '%s' "$uuid"
}

# 既定対象＝自分がいるワークスペース（caller）の UUID（薄いラッパ。本体は
# 共有 lib の ws_caller_uuid＝設計 §21）。caller が取れない／workspace list
# に無ければ非0。
default_target_uuid() {
  local uuid
  uuid="$(ws_caller_uuid "$CMUX_BIN" "$CALL_TIMEOUT")" || return 1
  printf '%s' "$uuid"
}

# --workspace <val> があればそれを解決し、無ければ既定（caller）を解決する。
# 成功時は UUID を stdout へ、失敗時は理由を stderr へ出して非0。
resolve_target() {
  local override="$1" uuid
  if [ -n "$override" ]; then
    uuid="$(resolve_workspace_uuid "$override")" || {
      echo "対象ワークスペースを特定できません（--workspace の値が workspace list に見つかりません）。" >&2
      return 1
    }
  else
    uuid="$(default_target_uuid)" || {
      echo "対象ワークスペースを特定できません。--workspace <uuid|ref|index> で指定してください。" >&2
      return 1
    }
  fi
  printf '%s' "$uuid"
}

# §3.2 の原子的置換。$1 = 新しい JSON 全体（文字列）。成功したら 0。
atomic_replace() {
  local new_json="$1" dir tmp
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir" 2>/dev/null || {
    echo "記録ディレクトリを作成できません: $dir" >&2
    return 1
  }
  tmp="$(mktemp "$dir/.workspaces.json.XXXXXX" 2>/dev/null)" || {
    echo "一時ファイルを作成できません（記録は変更していません）。" >&2
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  if ! printf '%s' "$new_json" >"$tmp"; then
    echo "記録の書き込みに失敗しました（記録は変更していません）。" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$STATE_FILE"; then
    echo "記録の置換に失敗しました（記録は変更していません）。" >&2
    return 1
  fi
  trap - EXIT
  return 0
}

cmd_set() {
  local slug="$1" override="$2" uuid cur new_json

  # 終了コードは §3.3 v1.6 の4値（+setの拒否専用rc=4）:
  #   0=成功 1=接続不可（ワークスペース解決に失敗） 2=記録破損
  #   3=内部エラー（jq組立・原子的置換の失敗） 4=setの拒否（FR-6）
  if state_is_corrupt; then
    echo "記録が壊れている。中身を確認して削除するか直してから再実行してください: $STATE_FILE" >&2
    return 2
  fi
  if ! slug_valid "$slug"; then
    echo "無効な slug です: ${slug}（英数字・.・_・- のみ、1文字以上、\".\"/\"..\" は不可）" >&2
    return 4
  fi
  if [ ! -f "$VAULT/Projects/$slug.md" ]; then
    echo "ノートが存在しません: $VAULT/Projects/$slug.md" >&2
    return 4
  fi

  uuid="$(resolve_target "$override")" || return 1

  cur="$(read_state_json)"
  new_json="$(printf '%s' "$cur" | jq -c --arg u "$uuid" --arg s "$slug" '
    .version = 1
    | .workspaces = ((.workspaces // {}) + {($u): $s})
  ')" || {
    echo "記録の組み立てに失敗しました（jq エラー）。" >&2
    return 3
  }
  atomic_replace "$new_json" || return 3
}

cmd_unset() {
  local override="$1" uuid cur new_json

  # 終了コードは cmd_set と同じ4値（unsetにrc=4は無い＝拒否条件が無い）。
  if state_is_corrupt; then
    echo "記録が壊れている。中身を確認して削除するか直してから再実行してください: $STATE_FILE" >&2
    return 2
  fi

  uuid="$(resolve_target "$override")" || return 1

  # 未宣言（キー無し・ファイル不在含む）なら何もせず成功（冪等・FR-7）。
  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi
  # UUID→対の引きは共有部品（A-v6-2）。対が無ければ何もせず成功。
  [ -n "$(ws_state_lookup_slug "$STATE_FILE" "$uuid")" ] || return 0
  cur="$(read_state_json)"
  new_json="$(printf '%s' "$cur" | jq -c --arg u "$uuid" '
    .version = 1
    | .workspaces = ((.workspaces // {}) | del(.[$u]))
  ')" || {
    echo "記録の組み立てに失敗しました（jq エラー）。" >&2
    return 3
  }
  atomic_replace "$new_json" || return 3
}

cmd_list() {
  if state_is_corrupt; then
    echo "記録が壊れている。中身を確認して削除するか直してから再実行してください: $STATE_FILE" >&2
    return 2
  fi
  [ -f "$STATE_FILE" ] || return 0
  jq -r '
    (.workspaces // {}) | to_entries | sort_by(.key) | .[] | "\(.key)\t\(.value)"
  ' "$STATE_FILE" 2>/dev/null
}

# 生存 UUID の集合を stdout へ出す。1か所でも取得に失敗したら「何も出さずに
# 非0」で返る（設計 §3.3・申し送り I-1: list-windows の失敗／workspace list
# の失敗／どちらかの jq 解析の失敗／空集合の4つすべてで非0）。
# 申し送り I-2 ＋ verifier実装レビュー1巡目 #1（BLOCKING）: 配列であること・
# ID が非空文字列であることを、不正要素を select で黙って除外するのでは
# なく all(...) で「全要素」検証する。1件でも型不正・id 欠落があれば
# 「不完全な alive 集合」として非0・無出力にする（select 除外方式だと
# 一部不正な応答でも有効 ID だけを集めて成功扱いになり、prune が不完全な
# 生存集合をもとに有効な宣言を消しうる）。
collect_alive_uuids() {
  local raw win_ids w ids out=""
  raw="$(run_with_timeout "$CALL_TIMEOUT" "$CMUX_BIN" --json list-windows)" || return 1
  printf '%s' "$raw" | jq -e '
    type == "array"
    and all(.[]; type == "object" and (.id | type == "string") and (.id | length) > 0)
  ' >/dev/null 2>&1 || return 1
  win_ids="$(printf '%s' "$raw" | jq -r '.[].id' 2>/dev/null)" || return 1
  [ -n "$win_ids" ] || return 1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    raw="$(run_with_timeout "$CALL_TIMEOUT" "$CMUX_BIN" --json workspace list --window "$w")" || return 1
    printf '%s' "$raw" | jq -e '
      (.workspaces // []) as $ws
      | ($ws | type == "array")
      and ($ws | all(.[]; type == "object" and (.id | type == "string") and (.id | length) > 0))
    ' >/dev/null 2>&1 || return 1
    ids="$(printf '%s' "$raw" | jq -r '(.workspaces // [])[].id' 2>/dev/null)" || return 1
    [ -n "$ids" ] || return 1
    out="$out$ids
"
  done <<EOF
$win_ids
EOF
  printf '%s' "$out"
}

cmd_prune() {
  local alive cur removed_pairs new_json

  # 終了コード（設計 §3.3 v1.6・D-17）: 0=実施 1=接続不可（一覧取得失敗）
  # 2=記録破損 3=内部エラー（jq組立・原子的置換の失敗）。pruneはrc=4を
  # 返さない（拒否条件を持たないため）。
  if state_is_corrupt; then
    echo "記録が壊れている。中身を確認して削除するか直してから再実行してください: $STATE_FILE" >&2
    return 2
  fi
  [ -f "$STATE_FILE" ] || return 0

  alive="$(collect_alive_uuids)"
  if [ $? -ne 0 ]; then
    echo "ワークスペース一覧を取得できませんでした。1件も削除していません。" >&2
    return 1
  fi

  cur="$(read_state_json)"
  # jq の index() 等に渡す filter 引数は「その式に流れ込む値」を . に束縛する
  # ため、$keep へパイプしてから .key を参照すると .key は $keep（配列）に
  # 対して評価されてしまう（jqの既知の落とし穴）。.key as $k で先に外側の値を
  # 捕まえてから index($k) を呼ぶ。
  removed_pairs="$(printf '%s' "$cur" | jq -r --arg alive "$alive" '
    ($alive | split("\n") | map(select(length > 0))) as $keep
    | (.workspaces // {}) | to_entries
    | map(select(.key as $k | ($keep | index($k)) == null))
    | sort_by(.key) | .[] | "\(.key)\t\(.value)"
  ' 2>/dev/null)"
  new_json="$(printf '%s' "$cur" | jq -c --arg alive "$alive" '
    ($alive | split("\n") | map(select(length > 0))) as $keep
    | .version = 1
    | .workspaces = ((.workspaces // {}) | with_entries(select(.key as $k | ($keep | index($k)) != null)))
  ' 2>/dev/null)"
  if [ -z "$new_json" ]; then
    echo "記録の組み立てに失敗しました（jq エラー）。" >&2
    return 3
  fi
  atomic_replace "$new_json" || return 3
  [ -n "$removed_pairs" ] && printf '%s\n' "$removed_pairs"
  return 0
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "jq が見つかりません。" >&2; exit 1; }

  local sub="${1:-}"
  shift || true

  local slug="" override=""
  case "$sub" in
    set)
      slug="${1:-}"
      [ -n "$slug" ] || { usage; exit 1; }
      shift || true
      ;;
    unset|list|prune) : ;;
    *) usage; exit 1 ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace)
        override="${2:-}"
        [ -n "$override" ] || { usage; exit 1; }
        shift 2
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  done

  case "$sub" in
    set) cmd_set "$slug" "$override"; exit $? ;;
    unset) cmd_unset "$override"; exit $? ;;
    list) cmd_list; exit $? ;;
    prune) cmd_prune; exit $? ;;
  esac
}

main "$@"
