#!/bin/bash
# cmux Dock「Project」枠の供給側（cmux-session-todo 設計 §28〜§30）。
# Vault の Projects/*.md の frontmatter と Tasks 節、外部脳ログ
# （vault-inventory・週次メンテの last-run.json）を読み、対応表
# （--list・v1/v2 と同一契約）と 1 ティック分のフレーム（--frame・
# 設計 §29。外部脳ヘルスを同居させる＝FR-61 ⑦）を作る。描画（Dock への
# 表示）は一切行わない＝dotfiles 側の cmux-next-watch.sh が受け取って
# 描くだけ（FR-61・FR-62）。
#
# 引数:
#   --list  ＝ 表示と同じ順序で「番号<TAB>正式プロジェクト名<TAB>next値
#             <TAB>区分（稼働中/保留）」を出す（v1/v2 と同一契約）。
#   --frame ＝ 1 ティック分のフレーム（§29 の行指向 TSV）を stdout へ出す
#             （rc は常に 0）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。
# cmux は一度も呼ばない（ワークスペースに依存しない＝設計 §30.2）。

set -u

LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)"
if [ ! -r "$LIB_DIR/lib-model-view.sh" ]; then
  echo "lib-model-view.sh が見つかりません: $LIB_DIR/lib-model-view.sh" >&2
  exit 1
fi
if [ ! -r "$LIB_DIR/lib-vault-tasks.sh" ]; then
  echo "lib-vault-tasks.sh が見つかりません: $LIB_DIR/lib-vault-tasks.sh" >&2
  exit 1
fi
# shellcheck source=./lib-model-view.sh
. "$LIB_DIR/lib-model-view.sh"
# shellcheck source=./lib-vault-tasks.sh
. "$LIB_DIR/lib-vault-tasks.sh"

VAULT="${CMUX_NEXT_VAULT:-$HOME/Data/obsidian}"
# status 語彙は4値統一（active/paused/completed/closed）。稼働=active・
# 保留=paused のみ表示し、completed/closed は対象外。env は語彙移行期・
# 実験用の上書き口として残す（v1/v2 と同一契約）。
STATUS_ALLOW="${CMUX_NEXT_STATUS_ALLOW:-active}"
STATUS_HOLD="${CMUX_NEXT_STATUS_HOLD:-paused}"
INVENTORY_DIR="${CMUX_NEXT_INVENTORY_DIR:-$HOME/.claude/logs/vault-inventory}"
MAINT_STATE_FILE="${CMUX_NEXT_MAINT_STATE:-$HOME/.claude/logs/maintenance/last-run.json}"
MAINT_STALE_DAYS="${CMUX_NEXT_MAINT_STALE_DAYS:-8}"

case "$MAINT_STALE_DAYS" in ''|*[!0-9]*|0) MAINT_STALE_DAYS=8 ;; esac
STATUS_ALLOW="$(printf '%s' "$STATUS_ALLOW" | tr -d '[:space:]')"
[ -z "$STATUS_ALLOW" ] && STATUS_ALLOW="active"
STATUS_HOLD="$(printf '%s' "$STATUS_HOLD" | tr -d '[:space:]')"

# status が許可リスト（カンマ区切り）に含まれるか判定する。
status_allowed() {
  local status="$1" allow="$2"
  [ -z "$status" ] && return 1
  case ",${allow}," in
    *",${status},"*) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 が実在する暦日の "YYYY-MM-DD" かどうかを判定する。BSD date は存在しない
# 日付（例 2026-02-30）を黙って正規化して成功しうるため、正規化結果を入力と
# 完全一致するかまで確認する（v1/v2 と同一契約）。
is_valid_date() {
  local normalized
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  normalized="$(TZ=UTC date -j -f '%Y-%m-%d' "$1" '+%Y-%m-%d' 2>/dev/null)" || return 1
  [ "$normalized" = "$1" ]
}

# frontmatter の next: が無い／空文字列のノートについて、同じノートの
# Tasks 節から先頭未完タスク（状態が x でない最初のタスク。記載順のまま）
# の本文を取り出す（FR-31）。Tasks 節が無い・未完タスクが無い・ノートが
# 破損しているときは何も出さず非0で返る。
derive_next_from_tasks() {
  local f="$1" ts
  ts="$(read_note "$f" 2>/dev/null)" || return 1
  printf '%s\n' "$ts" | awk -F '\t' '
    $1 == "T" && $2 != "x" { print $3; found = 1; exit }
    END { if (!found) exit 1 }
  '
}

# セクション1: Projects/*.md の frontmatter を走査し、status をグループ判定
# （A=稼働中／H=保留）。"グループ<TAB>sortkey<TAB>名前<TAB>next値" を
# A→H・各グループ内は更新日降順で標準出力へ並べる（表示と --list の共通
# データ源。number_entries() が読む唯一の入口）。mktemp 失敗時は非0。
collect_entries() {
  local projects_dir="$VAULT/Projects" f base fm status nextval
  local tmpfile sortkey grp derived

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/cmux-next-model.XXXXXX" 2>/dev/null)"
  [ -n "$tmpfile" ] || return 1
  for f in "$projects_dir"/*.md; do
    [ -e "$f" ] || continue
    fm="$(fm_extract <"$f")" || continue
    [ -z "$fm" ] && continue
    status="$(fm_field "$fm" status)"
    if status_allowed "$status" "$STATUS_ALLOW"; then
      grp="A"
    elif status_allowed "$status" "$STATUS_HOLD"; then
      grp="H"
    else
      continue
    fi
    base="$(sanitize_str "$(basename "$f" .md)")"
    nextval="$(sanitize_str "$(fm_field "$fm" next)")"
    if [ -z "$nextval" ]; then
      derived="$(derive_next_from_tasks "$f")"
      if [ -n "$derived" ]; then
        nextval="$(sanitize_str "$(truncate_plain "$derived" 15)")"
      fi
    fi
    sortkey="$(fm_field "$fm" updated)"
    is_valid_date "$sortkey" || sortkey="$(fm_field "$fm" date)"
    is_valid_date "$sortkey" || sortkey="0000-00-00"
    printf '%s\t%s\t%s\t%s\n' "$grp" "$sortkey" "$base" "$nextval" >>"$tmpfile"
  done
  # 検証1巡目 MAJOR #7: 以前は `rm -f` の成功がこの関数自体の戻り値に
  # なっており、sort が失敗しても（PATH汚染等）rc=0のまま伝播していた
  # （--list が0バイト・rc=0で返り、--frame も空だが正常な"E 0"フレームを
  # 誤って出していた）。sort自身の終了値を保持してから削除し、それを返す。
  local sort_rc
  sort -t "$(printf '\t')" -k1,1 -k2,2r "$tmpfile"
  sort_rc=$?
  rm -f "$tmpfile"
  return "$sort_rc"
}

# 表示番号の正本（設計 §19.1・N-1・§30.3の「唯一の実装変更」）。
# collect_entries の出力（grp<TAB>sortkey<TAB>name<TAB>next）を記載順に
# 1 から番号付けし、"番号<TAB>grp<TAB>name<TAB>next" を stdout へ出す。
# --list も --frame もこの関数の出力だけを読み、自分では数えない
# （DT-10。render_next() の idx を移さない）。純関数（stdin/stdout のみ）。
number_entries() {
  awk -F '\t' 'NF { n++; printf "%d\t%s\t%s\t%s\n", n, $1, $3, $4 }'
}

# 棚卸しレポート（vault-inventory）の最新ファイル（名前順＝日付ファイル名
# なので辞書順＝時系列順）から「要確認 N 件」を抽出する。見つかれば
# "count<TAB>M/D" を標準出力へ、抽出失敗時は何も出さず非0を返す。
inventory_status() {
  local f base latest="" latest_base="" count mmdd mm dd
  for f in "$INVENTORY_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"
    is_valid_date "$base" || continue
    if [ -z "$latest" ] || [ "$base" \> "$latest_base" ]; then
      latest="$f"
      latest_base="$base"
    fi
  done
  [ -n "$latest" ] || return 1
  count="$(grep -oE '要確認 [0-9]+ 件' "$latest" 2>/dev/null | head -n1 | grep -oE '[0-9]+')"
  is_number "$count" || return 1
  base="$(basename "$latest" .md)"
  mmdd="${base#*-}"
  mm="${mmdd%-*}"; dd="${mmdd#*-}"
  mm=$(( 10#$mm )); dd=$(( 10#$dd ))
  printf '%s\t%d/%d\n' "$count" "$mm" "$dd"
}

# 棚卸しの「データ源」の有無だけを判定する（実在する暦日ファイル名の最新
# レポートが1件でも見つかるか）。件数抽出（inventory_status）の成否とは
# 独立させる（v1/v2 と同一契約）。
inventory_has_source() {
  local f base
  for f in "$INVENTORY_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"
    is_valid_date "$base" && return 0
  done
  return 1
}

# 週次メンテ（maintenance.sh）の死活状態を last-run.json の last_success_at
# （無ければ started_at）から判定する。見つかれば
# "ok_or_warn<TAB>表示テキスト" を標準出力へ、状態ファイルが無い／壊れて
# いる場合は何も出さず非0を返す。
maintenance_status() {
  local raw ts epoch now age_days disp
  [ -f "$MAINT_STATE_FILE" ] || return 1
  raw="$(jq -r '.last_success_at // empty' "$MAINT_STATE_FILE" 2>/dev/null)"
  [ -n "$raw" ] || raw="$(jq -r '.started_at // empty' "$MAINT_STATE_FILE" 2>/dev/null)"
  [ -n "$raw" ] || return 1
  ts="$raw"
  case "$ts" in *.*Z) ts="${ts%%.*}Z" ;; esac
  epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null)"
  is_number "$epoch" || return 1
  now="$(date '+%s')"
  age_days=$(( (now - epoch) / 86400 ))
  [ "$age_days" -lt 0 ] && age_days=0
  if [ "$age_days" -ge "$MAINT_STALE_DAYS" ]; then
    printf 'warn\t⚠%d日前\n' "$age_days"
  else
    disp="$(date -r "$epoch" '+%-m/%-d' 2>/dev/null)"
    [ -n "$disp" ] || disp="?"
    printf 'ok\t✅%s\n' "$disp"
  fi
}

# --- `--list`（v1/v2 と同一契約） ------------------------------------------
# 検証1巡目 MAJOR #7: `collect_entries | number_entries | awk ...` という
# 素通しのパイプでは、pipefail無しの既定シェルでは最後尾の awk の rc しか
# 見えず、collect_entries（sort失敗等）の失敗が0バイト・rc=0の「空だが
# 正常なリスト」として黙って伝わっていた。collect_entries の出力を一旦
# 生ファイルへ落として自身のrcを直接検査してから後段へ渡す。
# 検証2巡目 MINOR #29: #7 と同型の取りこぼしが本関数の末尾にも残っていた。
# `number_entries < "$raw" | awk …` のrcを検査せず素通しし、直後の
# `rm -f "$raw"`（ほぼ必ず成功する）が関数の戻り値になっていたため、
# 整形段（`awk`）が失敗しても呼び出し側からはrc=0にしか見えなかった。
# パイプのrcを一旦変数へ保存してから`rm`し、保存した値を返す。
run_list() {
  local raw
  raw="$(mktemp "${TMPDIR:-/tmp}/cmux-next-model-list.XXXXXX" 2>/dev/null)"
  [ -n "$raw" ] || return 1
  if ! collect_entries > "$raw"; then
    rm -f "$raw"
    return 1
  fi
  local list_rc
  number_entries < "$raw" | awk -F '\t' 'NF {
    label = ($2 == "H") ? "保留" : "稼働中"
    printf "%s\t%s\t%s\t%s\n", $1, $3, $4, label
  }'
  list_rc=$?
  rm -f "$raw"
  return "$list_rc"
}

# --- `--frame`（新規・設計 §29） -------------------------------------------

print_reason_frame() {
  local reason="$1"
  printf '#V\tcmux-dock-frame/1\tProject\n'
  printf 'R\t%s\n' "$reason"
  printf 'E\t1\n'
}

# ヘルス（外部脳）の B 行を stdout へ出す（0〜2 行）。棚卸し→週次の順
# （v1/v2 の表示順と同じ）。データ源が無い側は行そのものを省略する。
# 棚卸しの件数抽出に失敗した（データ源はあるが「要確認 N件」パターンが
# 無い）場合は "棚卸し n/a" を warn 欄 ok で出す（n/a 自体は警告ではない。
# 描画側は表示テキストが n/a のときだけ配色を DIM にする＝§31.4）。
emit_health_rows() {
  local inv_src=0 maint_src=0
  inventory_has_source && inv_src=1
  [ -f "$MAINT_STATE_FILE" ] && maint_src=1
  [ "$inv_src" -eq 0 ] && [ "$maint_src" -eq 0 ] && return 0

  if [ "$inv_src" -eq 1 ]; then
    local inv_out inv_count inv_date
    inv_out="$(inventory_status)"
    if [ -n "$inv_out" ]; then
      inv_count="${inv_out%%$(printf '\t')*}"
      inv_date="${inv_out#*$(printf '\t')}"
      if [ "$inv_count" -ge 1 ] 2>/dev/null; then
        printf 'B\t棚卸し\twarn\t要確認%s件 (%s)\n' "$inv_count" "$inv_date"
      else
        printf 'B\t棚卸し\tok\t要確認%s件 (%s)\n' "$inv_count" "$inv_date"
      fi
    else
      printf 'B\t棚卸し\tok\tn/a\n'
    fi
  fi

  if [ "$maint_src" -eq 1 ]; then
    local maint_out maint_kind maint_disp
    maint_out="$(maintenance_status)"
    if [ -n "$maint_out" ]; then
      maint_kind="${maint_out%%$(printf '\t')*}"
      maint_disp="${maint_out#*$(printf '\t')}"
      printf 'B\t週次\t%s\t%s\n' "$maint_kind" "$maint_disp"
    fi
  fi
}

run_frame() {
  local entries_tmp raw_tmp rc
  entries_tmp="$(mktemp "${TMPDIR:-/tmp}/cmux-next-model-frame.XXXXXX" 2>/dev/null)"
  if [ -z "$entries_tmp" ]; then
    print_reason_frame "外部脳応答なし"
    return 0
  fi
  # 検証1巡目 MAJOR #7: `collect_entries | number_entries > file` は
  # pipefail無しでは number_entries（常に成功する awk）の rc しか見ないため
  # collect_entries（sort失敗等）の失敗を検知できず、空だが「正常」な
  # E 0 フレームを誤って出していた。collect_entries を一旦生ファイルへ
  # 落として自身のrcを直接検査する。
  raw_tmp="$(mktemp "${TMPDIR:-/tmp}/cmux-next-model-frame-raw.XXXXXX" 2>/dev/null)"
  if [ -z "$raw_tmp" ]; then
    rm -f "$entries_tmp"
    print_reason_frame "外部脳応答なし"
    return 0
  fi
  if ! collect_entries > "$raw_tmp"; then
    rm -f "$raw_tmp" "$entries_tmp"
    print_reason_frame "外部脳応答なし"
    return 0
  fi
  number_entries < "$raw_tmp" > "$entries_tmp"
  rm -f "$raw_tmp"

  local health_tmp
  health_tmp="$(mktemp "${TMPDIR:-/tmp}/cmux-next-model-health.XXXXXX" 2>/dev/null)"
  if [ -z "$health_tmp" ]; then
    rm -f "$entries_tmp"
    print_reason_frame "外部脳応答なし"
    return 0
  fi
  emit_health_rows > "$health_tmp"

  local p_n b_n body_n
  p_n="$(wc -l < "$entries_tmp" | tr -d ' ')"
  b_n="$(wc -l < "$health_tmp" | tr -d ' ')"
  body_n=$(( p_n + b_n ))

  printf '#V\tcmux-dock-frame/1\tProject\n'
  awk -F '\t' '{ printf "P\t%s\t%s\t%s\t%s\n", $1, $3, $4, ($2=="H")?"保留":"稼働中" }' "$entries_tmp"
  cat "$health_tmp"
  printf 'E\t%s\n' "$body_n"

  rm -f "$entries_tmp" "$health_tmp"
  return 0
}

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-next-model.sh --list
  cmux-next-model.sh --frame
EOF
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "jq が見つかりません。" >&2; exit 1; }

  local mode=""
  case "${1:-}" in
    --list) mode="list" ;;
    --frame) mode="frame" ;;
    *) usage; exit 1 ;;
  esac
  shift || true
  [ $# -eq 0 ] || { usage; exit 1; }

  if [ "$mode" = "list" ]; then
    # 検証1巡目 MAJOR #7: 以前は `exit 0` を無条件に固定しており、
    # run_list（collect_entriesの失敗）の失敗が呼び出し元へ伝わらなかった。
    run_list
    exit $?
  fi
  run_frame
  exit $?
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
