#!/bin/bash
# cmux Dock「Task」枠の供給側（cmux-session-todo 設計 §28〜§30・v4差分＝
# design.md §39）。フォーカス中のワークスペースの宣言先プロジェクト
# （cmux-task-declare.sh set で宣言）の Tasks 節を読み、対応表
# （--list・v4＝5列TSV）と1ティック分のフレーム（--frame・§39.3・
# 契約版 cmux-dock-frame/2）を作る。描画（Dockへの表示）は一切行わない＝
# dotfiles側のcmux-task-watch.shが受け取って描くだけ（FR-61・FR-62）。
# 「Task の N 番」の N は版（未完の版に記載順で1から）を指す＝供給側だけが
# 番号を振る（N-1）。
#
# 引数:
#   --list  ＝ 未完の版の全子行を5列TSV（版番号・版名・分数・状態・本文）で
#             出す（§39.4.6・R-v4-1。対象は caller で、caller と focused が
#             一致するときだけ出す＝FR-53b）。子行を持たない版（0/0）は
#             状態・本文を「-」にした1行だけ出す。
#   --frame ＝ focused ワークスペースについて 1 ティック分のフレーム
#             （§39.3 の行指向 TSV・#V→(V→C*)*→D→E）を stdout へ出す
#             （rc は常に 0。理由フレームも版宣言つきの正当な出力として
#             rc=0 で返す＝FR-82 #11）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。
#
# 署名（cksum）・CMUX_TASK_INTERVAL による間引きは持たない（R-v3-1・§31.3）。
# 呼ばれるたびに毎回フルに評価する純粋な単発コマンドである。

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
if [ ! -r "$LIB_DIR/lib-cmux-workspace.sh" ]; then
  echo "lib-cmux-workspace.sh が見つかりません: $LIB_DIR/lib-cmux-workspace.sh" >&2
  exit 1
fi
# shellcheck source=./lib-model-view.sh
. "$LIB_DIR/lib-model-view.sh"
# shellcheck source=./lib-vault-tasks.sh
. "$LIB_DIR/lib-vault-tasks.sh"
# shellcheck source=./lib-cmux-workspace.sh
. "$LIB_DIR/lib-cmux-workspace.sh"

# --- 設定（利用者向け＋テスト・実験用の上書き口） -------------------------
VAULT="${CMUX_TASK_VAULT:-$HOME/Data/obsidian}"
STATE_FILE="${CMUX_TASK_STATE:-$HOME/.config/cmux-task-watch/workspaces.json}"
CALL_TIMEOUT="$(sanitize_interval "${CMUX_TASK_CALL_TIMEOUT:-}" 5)"
CMUX_BIN="${CMUX_TASK_CMUX_BIN:-cmux}"

# set -u 下で未評価のまま参照される経路でも unbound variable にならないよう、
# モデル系グローバルは起動時に空へ初期化しておく（v1/v2 と同じ流儀）。
CMUX_REASON=""
CMUX_UUID=""
LIST_REASON=""
LIST_UUID=""
MODEL_REASON=""
V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
NR_BLIDX=(); NR_NUM=()
DONE_N=0
CUR_I=-1

# --- 記録ファイル（読むだけ・書かない） ---------------------------------
# 読み手の本体は共有 lib（lib-cmux-workspace.sh の ws_state_*・ws_slug_valid＝
# v6 A-v6-2）。ここは薄いラッパ（検査式・規則は不変）。

# 記録ファイルの破損判定（v1/v2 と同一式）。ファイル不在は破損ではない。
state_is_corrupt() { ws_state_is_corrupt "$STATE_FILE"; }

# UUID に対応する slug を stdout へ出す（無ければ空）。呼び出し側は
# state_is_corrupt を先に確認していること。
lookup_slug() { ws_state_lookup_slug "$STATE_FILE" "$1"; }

# slug が FR-34 を満たすか判定する。
slug_valid() { ws_slug_valid "$1"; }

# --- cmux 側（毎回評価） ---------------------------------------------------

# フォーカス中ワークスペースの UUID を解決する（薄いラッパ。段階評価の
# 本体は共有 lib）。成功時は CMUX_UUID に UUID を、失敗時は CMUX_REASON に
# §7 順1・順2 の理由行を入れる（両方成功かつ解決できたときは
# CMUX_REASON=""）。--frame の対象は focused だけで、caller との一致検査は
# 行わない（E-9・設計 §30.2）。
probe_focus_uuid() {
  local refs focus_ref json
  CMUX_REASON=""
  CMUX_UUID=""

  refs="$(ws_identify_refs "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    CMUX_REASON="cmux 応答なし"
    return
  fi
  focus_ref="${refs#*$'\t'}"

  json="$(ws_list_json "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    CMUX_REASON="cmux 応答なし"
    return
  fi

  CMUX_UUID="$(ws_uuid_for_ref "$json" "$focus_ref")"
  if [ $? -ne 0 ]; then
    CMUX_UUID=""
    CMUX_REASON="対象不明"
  fi
}

# --list の対象解決（設計 §20.2・§21・v1/v2 と同一契約）。caller と focused
# の両方を ws_uuid_for_ref で解決し、両者が一致するときだけ caller の UUID
# を返す（FR-53b）。成功時は LIST_UUID に UUID を、失敗時は LIST_REASON に
# 理由をセットする（LIST_UUID は空のまま）。
#
# ⚠️ 呼び出し側はこの関数を裸の文として呼ぶこと（コマンド置換で包まない。
# 包むと関数全体がサブシェルで走り、LIST_REASON/LIST_UUID への代入が
# 呼び出し元へ伝わらない）。
probe_list_target() {
  local refs caller_ref focus_ref json cu fu
  LIST_REASON=""
  LIST_UUID=""

  refs="$(ws_identify_refs "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    LIST_REASON="cmux 応答なし"
    return
  fi
  caller_ref="${refs%%$'\t'*}"
  focus_ref="${refs#*$'\t'}"

  json="$(ws_list_json "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    LIST_REASON="cmux 応答なし"
    return
  fi

  cu="$(ws_uuid_for_ref "$json" "$caller_ref")"
  if [ $? -ne 0 ]; then
    LIST_REASON="対象不明"
    return
  fi

  fu="$(ws_uuid_for_ref "$json" "$focus_ref")"
  if [ $? -ne 0 ] || [ "$cu" != "$fu" ]; then
    LIST_REASON="対象不一致"
    return
  fi

  LIST_UUID="$cu"
}

# --- Vault 側（順3〜順10） -------------------------------------------------

# UUID から表示モデルを組み立てる（v4・design.md §39.4.1〜§39.4.3・v6 §41.3.1）。
# ▶ の版（cur）と「▶ を決めない条件」（理由行 Tasks 節なし／タスクなし／空タスク）
# の判定は共有部品 decide_current_version（lib-vault-tasks.sh）の呼び出し＝規則・
# 理由行・表示は v4 と不変（D-v6-1・A-v6-1）。版の待ち行（種別 W）は読まない
# （版行・分数に出ない＝AC-150）。
# 以下のグローバルを設定する。
#   MODEL_REASON : 非空なら理由行（順3〜10）。空なら通常表示（順11）
#   DONE_N       : 完了した版の件数（`D` 行）
#   CUR_I        : 今の版の版インデックス（vcount空間・無ければ-1）
#   BL_KIND/BL_A/BL_B/BL_C : 未完の版（U・記載順）の版行＋その全子行
#     VE（展開＝open）/VC（畳み＝fold）: A="cur"/"-" B=版名 C=分数"done/total"
#     CX/CS/CB: A=状態1文字 B=タスク本文 C=（未使用）
#   NR_BLIDX/NR_NUM : number_rows() が版行（VE/VC）だけに振った番号
load_model() {
  local uuid="$1"
  MODEL_REASON=""
  V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
  BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
  NR_BLIDX=(); NR_NUM=()
  DONE_N=0
  CUR_I=-1

  if state_is_corrupt; then
    MODEL_REASON="宣言記録破損"
    return
  fi

  local slug
  slug="$(lookup_slug "$uuid")"
  if [ -z "$slug" ]; then
    MODEL_REASON="未宣言"
    return
  fi

  if [ ! -d "$VAULT" ]; then
    MODEL_REASON="Vault 不在"
    return
  fi

  if ! slug_valid "$slug"; then
    MODEL_REASON="ノート不在"
    return
  fi
  local note="$VAULT/Projects/$slug.md"
  if [ ! -f "$note" ]; then
    MODEL_REASON="ノート不在"
    return
  fi

  local tsv rc
  tsv="$(read_note "$note")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    MODEL_REASON="ノート破損"
    return
  fi

  local vcount=0 cur_vi=-1
  local task_vidx=() task_state=() task_body=()
  local kind a b
  # N（next:）・W（版の待ち行）は表示の組み立てでは読まない（N は決定部品が
  # 読む・W は Task 枠に描かず数えない＝AC-150）。
  while IFS="$(printf '\t')" read -r kind a b; do
    [ -n "$kind" ] || continue
    case "$kind" in
      V)
        V_NAME+=("$a")
        V_TOTAL+=(0)
        V_DONE+=(0)
        V_HASSLASH+=(0)
        cur_vi=$vcount
        vcount=$(( vcount + 1 ))
        ;;
      T)
        [ "$cur_vi" -ge 0 ] || continue
        V_TOTAL[$cur_vi]=$(( V_TOTAL[$cur_vi] + 1 ))
        case "$a" in
          x) V_DONE[$cur_vi]=$(( V_DONE[$cur_vi] + 1 )) ;;
          /) V_HASSLASH[$cur_vi]=1 ;;
        esac
        task_vidx+=("$cur_vi")
        task_state+=("$a")
        task_body+=("$b")
        ;;
    esac
  done <<TSV_EOF
$tsv
TSV_EOF

  # ▶ の版の決定（順 10〜11・§39.4.2・v6 §41.5.3）＝共有部品 1 か所。出力＝
  # "<序数>\tcur\t<待ち行>" か "-1\t<区分>\t"。区分 noversion／notask／blanktask は
  # 既存の理由行（同じ条件・同じ順）に写す。alldone は理由行ではない（U が空＝
  # cur なし・--frame は通常フレーム・--list は「全版完了」を別に検出＝§39.4.4）。
  local decision kind
  decision="$(printf '%s\n' "$tsv" | decide_current_version)"
  kind="${decision#*$'\t'}"; kind="${kind%%$'\t'*}"
  case "$kind" in
    noversion) MODEL_REASON="Tasks 節なし"; return ;;
    notask)    MODEL_REASON="タスクなし"; return ;;
    blanktask) MODEL_REASON="空タスク"; return ;;
    cur)       CUR_I="${decision%%$'\t'*}" ;;
    *)         CUR_I=-1 ;;
  esac
  local n_tasks=${#task_body[@]}

  # 完了判定（順11・§39.4.1手順3）: done_i = (total>=1 && done==total)。
  # U = 未完の版の列（記載順）・DONE_N = 完了版の件数（表示用の統計。U の定義は
  # 決定部品と同じ式）。
  local i ui u_list=()
  for ((i = 0; i < vcount; i++)); do
    if [ "${V_TOTAL[$i]}" -ge 1 ] && [ "${V_DONE[$i]}" -eq "${V_TOTAL[$i]}" ]; then
      DONE_N=$(( DONE_N + 1 ))
    else
      u_list+=("$i")
    fi
  done

  # BL_* の組み立て（U の全版＋その全子行・OPENに依らない＝§39.4.1手順6）。
  local j is_open
  for ui in "${u_list[@]+"${u_list[@]}"}"; do
    is_open=0
    if [ "${V_DONE[$ui]}" -ge 1 ] || [ "${V_HASSLASH[$ui]}" -eq 1 ]; then
      is_open=1
    fi
    if [ "$is_open" -eq 1 ]; then
      BL_KIND+=("VE")
    else
      BL_KIND+=("VC")
    fi
    if [ "$ui" -eq "$CUR_I" ]; then
      BL_A+=("cur")
    else
      BL_A+=("-")
    fi
    BL_B+=("${V_NAME[$ui]}")
    BL_C+=("${V_DONE[$ui]}/${V_TOTAL[$ui]}")

    if [ "$n_tasks" -gt 0 ]; then
      for ((j = 0; j < n_tasks; j++)); do
        if [ "${task_vidx[$j]}" -eq "$ui" ]; then
          case "${task_state[$j]}" in
            x) BL_KIND+=("CX") ;;
            /) BL_KIND+=("CS") ;;
            *) BL_KIND+=("CB") ;;
          esac
          BL_A+=("${task_state[$j]}")
          BL_B+=("${task_body[$j]}")
          BL_C+=("")
        fi
      done
    fi
  done

  number_rows
}

# 表示番号の正本（設計 §39.4.1手順7・N-1）。BL_KIND（load_model が組み立てた
# 未完の版・記載順の版行＋子行）を読み、版行（VE/VC）だけに記載順で1から
# 番号を振る（v4では番号は版を指す＝子行はもう番号を持たない）。並列配列
# NR_BLIDX（BL_KIND上の位置）/NR_NUM を設定する。--list も --frame もこの
# 関数が返した配列を読むだけで、自分では数えない。純関数（副作用は上記
# グローバルの設定のみ・BL_* は変更しない）。
number_rows() {
  NR_BLIDX=(); NR_NUM=()
  local n=${#BL_KIND[@]} i num=0
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      VE|VC)
        num=$(( num + 1 ))
        NR_BLIDX+=("$i")
        NR_NUM+=("$num")
        ;;
    esac
  done
}

# --- `--list`（v4・5列・設計 §39.4.6・R-v4-1） -----------------------------
# 対象は caller。caller と focused が一致するときだけ5列TSVを出す
# （FR-53b）。1行＝未完の版の子行1つ（版番号・版名・分数を各行に繰り返す）。
# 子行を持たない版（0/0）は1行だけ出し、状態・本文を「-」にする（§39.4.6）。
# 展開欄fold（畳み）の版の子行も出す＝BL_*はUの全版の全子行を持つ
# （load_modelの手順6・OPENに依らない）。
# stdout: 成功時のみ5列TSVを1行以上。失敗時は0バイト。
# stderr: 失敗時のみ理由1行。rc: 成功0／失敗1。
run_list() {
  probe_list_target
  if [ -z "$LIST_UUID" ]; then
    echo "${LIST_REASON:-対象不明}" >&2
    return 1
  fi

  load_model "$LIST_UUID"
  if [ -n "$MODEL_REASON" ]; then
    echo "$MODEL_REASON" >&2
    return 1
  fi

  local n=${#NR_NUM[@]}
  if [ "$n" -eq 0 ]; then
    # U が空＝全版完了。MODEL_REASON は立たない（--frame は通常フレーム
    # として扱う）ので、--list はここで別に検出する（§39.4.4）。
    echo "全版完了" >&2
    return 1
  fi

  local bn=${#BL_KIND[@]} i ni=0 cur_num="" cur_name="" cur_frac="" has_child=0
  for ((i = 0; i < bn; i++)); do
    case "${BL_KIND[$i]}" in
      VE|VC)
        if [ "$ni" -gt 0 ] && [ "$has_child" -eq 0 ]; then
          printf '%s\t%s\t%s\t-\t-\n' "$cur_num" "$cur_name" "$cur_frac"
        fi
        cur_num="${NR_NUM[$ni]}"
        cur_name="${BL_B[$i]}"
        cur_frac="${BL_C[$i]}"
        has_child=0
        ni=$(( ni + 1 ))
        ;;
      CX|CS|CB)
        printf '%s\t%s\t%s\t[%s]\t%s\n' "$cur_num" "$cur_name" "$cur_frac" "${BL_A[$i]}" "${BL_B[$i]}"
        has_child=1
        ;;
    esac
  done
  if [ "$ni" -gt 0 ] && [ "$has_child" -eq 0 ]; then
    printf '%s\t%s\t%s\t-\t-\n' "$cur_num" "$cur_name" "$cur_frac"
  fi
  return 0
}

# --- `--frame`（v4・設計 §39.3） --------------------------------------------

# 版宣言＋理由行＋終端行の理由フレームを stdout へ出す（契約版はTask種別の
# cmux-dock-frame/2＝D-v4-1。理由フレーム自体の行文法は#V→R→Eのまま）。
print_reason_frame() {
  local reason="$1"
  printf '#V\tcmux-dock-frame/2\tTask\n'
  printf 'R\t%s\n' "$reason"
  printf 'E\t1\n'
}

# 通常フレーム（版宣言＋版行＋子行＋完了件数＋終端行）を stdout へ出す。
# load_model 済みであること（呼び出し側の前提）。`V` 行はUの全版（番号・
# 版名・分数・▶欄・展開欄）、`C` 行は展開欄openの版だけ（fold の子行は
# BL_*上に存在するが出さない＝§39.4.1）。`D` 行はDONE_N。ヘッダー（H）・
# 展開位置（X）はv4で廃止（規則4・Q-v4-3以降不要）。
print_task_frame() {
  printf '#V\tcmux-dock-frame/2\tTask\n'

  local n=${#BL_KIND[@]} i ni=0 in_open=0 cur_flag open_flag body_n=0
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      VE|VC)
        cur_flag="-"
        [ "${BL_A[$i]}" = "cur" ] && cur_flag="cur"
        if [ "${BL_KIND[$i]}" = "VE" ]; then
          open_flag="open"; in_open=1
        else
          open_flag="fold"; in_open=0
        fi
        printf 'V\t%s\t%s\t%s\t%s\t%s\n' "${NR_NUM[$ni]}" "${BL_B[$i]}" "${BL_C[$i]}" "$cur_flag" "$open_flag"
        ni=$(( ni + 1 ))
        body_n=$(( body_n + 1 ))
        ;;
      CX|CS|CB)
        if [ "$in_open" -eq 1 ]; then
          printf 'C\t[%s]\t%s\n' "${BL_A[$i]}" "${BL_B[$i]}"
          body_n=$(( body_n + 1 ))
        fi
        ;;
    esac
  done

  printf 'D\t%s\n' "$DONE_N"
  body_n=$(( body_n + 1 ))
  printf 'E\t%s\n' "$body_n"
}

# focused ワークスペースについて 1 ティック分のフレームを stdout へ出す。
# rc は常に0（呼び出し側＝描画側は stdout の中身だけで判定する。FR-82
# #11＝rc=0のときフレームがちょうど1つある）。
run_frame() {
  probe_focus_uuid
  if [ -n "$CMUX_REASON" ]; then
    print_reason_frame "$CMUX_REASON"
    return 0
  fi

  load_model "$CMUX_UUID"
  if [ -n "$MODEL_REASON" ]; then
    print_reason_frame "$MODEL_REASON"
    return 0
  fi

  print_task_frame
  return 0
}

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-task-model.sh --list
  cmux-task-model.sh --frame
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
    run_list
    exit $?
  fi
  run_frame
  exit $?
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
