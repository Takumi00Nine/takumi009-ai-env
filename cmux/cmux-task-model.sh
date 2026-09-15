#!/bin/bash
# cmux Dock「Task」枠の供給側（cmux-session-todo 設計 §28〜§30）。
# フォーカス中のワークスペースの宣言先プロジェクト（cmux-task-declare.sh
# set で宣言）の Tasks 節を読み、対応表（--list・v1/v2 と同一契約）と
# 1 ティック分のフレーム（--frame・設計 §29）を作る。描画（Dock への表示）
# は一切行わない＝dotfiles 側の cmux-task-watch.sh が受け取って描くだけ
# （FR-61・FR-62）。
#
# 引数:
#   --list  ＝ 展開対象の版の子行を4列TSV（番号・版名・状態・本文）で出す
#             （FR-52・v1/v2 と同一契約。対象は caller で、caller と focused
#             が一致するときだけ出す＝FR-53b）。
#   --frame ＝ focused ワークスペースについて 1 ティック分のフレーム
#             （§29 の行指向 TSV）を stdout へ出す（rc は常に 0。理由フレーム
#             も版宣言つきの正当な出力として rc=0 で返す＝FR-82 #11）。
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
MODEL_SLUG=""
MODEL_SYM=""
MODEL_LEADWORD=""
MODEL_VERNAME=""
MODEL_FRAC=""
V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()

# --- 記録ファイル（読むだけ・書かない） ---------------------------------

# 記録ファイルの破損判定（v1/v2 と同一式）。ファイル不在は破損ではない。
state_is_corrupt() {
  [ -f "$STATE_FILE" ] || return 1
  jq -s -e '
    length == 1
    and (.[0] | type == "object")
    and (.[0].version == 1)
    and (.[0].workspaces | type == "object")
    and (.[0].workspaces | to_entries | all(.value | type == "string"))
  ' "$STATE_FILE" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] && return 1
  return 0
}

# UUID に対応する slug を stdout へ出す（無ければ空）。呼び出し側は
# state_is_corrupt を先に確認していること。
lookup_slug() {
  local uuid="$1"
  [ -f "$STATE_FILE" ] || return 0
  jq -r --arg u "$uuid" '(.workspaces // {})[$u] // empty' "$STATE_FILE" 2>/dev/null
}

# slug が FR-34 を満たすか判定する。
slug_valid() {
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

# UUID から表示モデルを組み立てる。以下のグローバルを設定する。
#   MODEL_REASON      : 非空なら理由行（順3〜10）。空なら通常表示（順11）
#   MODEL_SLUG        : プロジェクト名（宣言された slug）
#   MODEL_SYM/MODEL_LEADWORD/MODEL_VERNAME/MODEL_FRAC : ヘッダーの版欄（FR-35）
#   BL_KIND/BL_A/BL_B/BL_C : 版行＋展開対象の子行（クランプ前・記載順）
#     VE/VC: A=記号 B=版名 C=分数"done/total"
#     CX/CS/CB: A=状態1文字 B=タスク本文 C=（未使用）
load_model() {
  local uuid="$1"
  MODEL_REASON=""
  MODEL_SLUG=""
  MODEL_SYM=""
  MODEL_LEADWORD=""
  MODEL_VERNAME=""
  MODEL_FRAC=""
  V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
  BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
  NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()

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
  MODEL_SLUG="$slug"

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
  while IFS="$(printf '\t')" read -r kind a b; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "V" ]; then
      V_NAME+=("$a")
      V_TOTAL+=(0)
      V_DONE+=(0)
      V_HASSLASH+=(0)
      cur_vi=$vcount
      vcount=$(( vcount + 1 ))
    elif [ "$kind" = "T" ]; then
      [ "$cur_vi" -ge 0 ] || continue
      V_TOTAL[$cur_vi]=$(( V_TOTAL[$cur_vi] + 1 ))
      case "$a" in
        x) V_DONE[$cur_vi]=$(( V_DONE[$cur_vi] + 1 )) ;;
        /) V_HASSLASH[$cur_vi]=1 ;;
      esac
      task_vidx+=("$cur_vi")
      task_state+=("$a")
      task_body+=("$b")
    fi
  done <<TSV_EOF
$tsv
TSV_EOF

  if [ "$vcount" -eq 0 ]; then
    MODEL_REASON="Tasks 節なし"
    return
  fi

  local i total_all=0
  for ((i = 0; i < vcount; i++)); do
    total_all=$(( total_all + V_TOTAL[i] ))
  done
  if [ "$total_all" -eq 0 ]; then
    MODEL_REASON="タスクなし"
    return
  fi

  local n_tasks=${#task_body[@]}
  if [ "$n_tasks" -gt 0 ]; then
    for ((i = 0; i < n_tasks; i++)); do
      if [ -z "${task_body[$i]}" ]; then
        MODEL_REASON="空タスク"
        return
      fi
    done
  fi

  # 展開対象の決定（FR-27）
  local expand=-1
  for ((i = 0; i < vcount; i++)); do
    if [ "${V_HASSLASH[$i]}" -eq 1 ]; then
      expand=$i
      break
    fi
  done
  if [ "$expand" -lt 0 ]; then
    for ((i = 0; i < vcount; i++)); do
      if [ "${V_DONE[$i]}" -lt "${V_TOTAL[$i]}" ]; then
        expand=$i
        break
      fi
    done
  fi

  # ヘッダーの状態（FR-35）
  if [ "$expand" -ge 0 ] && [ "${V_HASSLASH[$expand]}" -eq 1 ]; then
    MODEL_SYM="▶"; MODEL_LEADWORD=""; MODEL_VERNAME="${V_NAME[$expand]}"
    MODEL_FRAC="${V_DONE[$expand]}/${V_TOTAL[$expand]}"
  elif [ "$expand" -ge 0 ]; then
    MODEL_SYM="・"; MODEL_LEADWORD="次: "; MODEL_VERNAME="${V_NAME[$expand]}"
    MODEL_FRAC="${V_DONE[$expand]}/${V_TOTAL[$expand]}"
  else
    MODEL_SYM="✅"; MODEL_LEADWORD="全版完了"; MODEL_VERNAME=""
    local done_v=0
    for ((i = 0; i < vcount; i++)); do
      if [ "${V_TOTAL[$i]}" -ge 1 ] && [ "${V_DONE[$i]}" -eq "${V_TOTAL[$i]}" ]; then
        done_v=$(( done_v + 1 ))
      fi
    done
    MODEL_FRAC="${done_v}/${vcount}"
  fi

  # BL_* の組み立て（版行＋展開対象版の子行・記載順）
  local j sym_i
  for ((i = 0; i < vcount; i++)); do
    if [ "${V_TOTAL[$i]}" -ge 1 ] && [ "${V_DONE[$i]}" -eq "${V_TOTAL[$i]}" ]; then
      sym_i="✅"
    elif [ "${V_HASSLASH[$i]}" -eq 1 ]; then
      sym_i="▶"
    else
      sym_i="・"
    fi
    if [ "$i" -eq "$expand" ]; then
      BL_KIND+=("VE")
    else
      BL_KIND+=("VC")
    fi
    BL_A+=("$sym_i")
    BL_B+=("${V_NAME[$i]}")
    BL_C+=("${V_DONE[$i]}/${V_TOTAL[$i]}")

    if [ "$i" -eq "$expand" ] && [ "$n_tasks" -gt 0 ]; then
      for ((j = 0; j < n_tasks; j++)); do
        if [ "${task_vidx[$j]}" -eq "$i" ]; then
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

# 表示番号の正本（設計 §19.1・N-1）。BL_KIND/BL_A/BL_B（load_model が
# 組み立てた版行＋展開対象版の子行・記載順）を読み、展開対象版の子行
# （CX/CS/CB）だけに記載順で1から番号を振る。並列配列
# NR_BLIDX（BL_KIND上の位置）/NR_NUM/NR_STATE/NR_BODY を設定する。
# --list も --frame もこの関数が返した配列を読むだけで、自分では数えない。
# 純関数（副作用は上記グローバルの設定のみ・BL_* は変更しない）。
number_rows() {
  NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()
  local n=${#BL_KIND[@]} i num=0
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      CX|CS|CB)
        num=$(( num + 1 ))
        NR_BLIDX+=("$i")
        NR_NUM+=("$num")
        NR_STATE+=("${BL_A[$i]}")
        NR_BODY+=("${BL_B[$i]}")
        ;;
    esac
  done
}

# --- `--list`（v1/v2 と同一契約・FR-52・設計 §20） -------------------------
# 対象は caller。caller と focused が一致するときだけ4列TSVを出す
# （FR-53b）。stdout: 成功時のみ4列TSVを1行以上。失敗時は0バイト。
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
    # 展開対象の版が無い＝全版完了。MODEL_REASON は立たない（--frame は
    # 通常フレームとして扱う）ので、--list はここで別に検出する。
    echo "全版完了" >&2
    return 1
  fi

  local i
  for ((i = 0; i < n; i++)); do
    printf '%s\t%s\t[%s]\t%s\n' "${NR_NUM[$i]}" "$MODEL_VERNAME" "${NR_STATE[$i]}" "${NR_BODY[$i]}"
  done
  return 0
}

# --- `--frame`（新規・設計 §29） -------------------------------------------

# 版宣言＋理由行＋終端行の理由フレームを stdout へ出す。
print_reason_frame() {
  local reason="$1"
  printf '#V\tcmux-dock-frame/1\tTask\n'
  printf 'R\t%s\n' "$reason"
  printf 'E\t1\n'
}

# 通常フレーム（版宣言＋ヘッダー＋版行＋子行＋展開位置＋終端行）を
# stdout へ出す。load_model 済みであること（呼び出し側の前提）。
print_task_frame() {
  printf '#V\tcmux-dock-frame/1\tTask\n'
  printf 'H\t%s\t%s\t%s\t%s\t%s\n' "$MODEL_SYM" "$MODEL_SLUG" "$MODEL_LEADWORD" "$MODEL_VERNAME" "$MODEL_FRAC"

  local n=${#BL_KIND[@]} i vpos=0 xpos="-" body_n=1
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      VE|VC)
        vpos=$(( vpos + 1 ))
        printf 'V\t%s\t%s\t%s\n' "${BL_B[$i]}" "${BL_A[$i]}" "${BL_C[$i]}"
        body_n=$(( body_n + 1 ))
        [ "${BL_KIND[$i]}" = "VE" ] && xpos="$vpos"
        ;;
    esac
  done

  local cn=${#NR_NUM[@]}
  for ((i = 0; i < cn; i++)); do
    printf 'C\t%s\t[%s]\t%s\n' "${NR_NUM[$i]}" "${NR_STATE[$i]}" "${NR_BODY[$i]}"
    body_n=$(( body_n + 1 ))
  done

  printf 'X\t%s\n' "$xpos"
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
