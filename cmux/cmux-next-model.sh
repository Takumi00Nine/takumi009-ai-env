#!/bin/bash
# cmux Dock「Project」枠の供給側（cmux-session-todo 設計 §28〜§30）。
# Vault の Projects/*.md の frontmatter と Tasks 節を読み、対応表
# （--list・v1/v2 と同一契約）と 1 ティック分のフレーム（--frame・
# 設計 §29。外部脳ヘルスを同居させる＝FR-61 ⑦）を作る。描画（Dock への
# 表示）は一切行わない＝dotfiles 側の cmux-next-watch.sh が受け取って
# 描くだけ（FR-61・FR-62）。
#
# 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §6）: 契約 cmux-dock-frame/3。
# B 行は判定機（claude/hooks/lib/health_judge.py＝唯一の判定ロジック）の写し＝
#   B<TAB>外部脳<TAB><ok|warn|error><TAB><OK|WARNING|ERROR>[ 候補N件]
# を 0〜1 行。判定機が動かないときは 0 行（3 値の外の機構障害＝FR-15 の例外）。
# 旧判定（8 日線・棚卸し n/a・週次 ✅/⚠）は退役。
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
# 判定機の入力 4 本＋配置済み plist（既定は各実ファイル＝テストは必ず fixture へ向ける・設計 §10.1）。
# 棚卸しの正本（design-step2 §3.1/§6.1）。書き手は vault_inventory.py だけ。
INVENTORY_LATEST="${CMUX_NEXT_INVENTORY_LATEST:-$INVENTORY_DIR/latest.json}"
MAINT_STATE_FILE="${CMUX_NEXT_MAINT_STATE:-$HOME/.claude/logs/maintenance/last-run.json}"
HEALTH_OBSERVATION="${CMUX_NEXT_HEALTH_OBSERVATION:-$HOME/.claude/logs/health/session-observation.json}"
RECALL_LOG="${CMUX_NEXT_RECALL_LOG:-$HOME/.claude/logs/vault-recall.tsv}"
MAINT_PLIST="${CMUX_NEXT_MAINT_PLIST:-$HOME/Library/LaunchAgents/com.takumi009.maintenance.plist}"
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"  # 判定機の既定と同値（bootstrap-vault.sh と同じ渡し方＝設計 §4.1・想起の疑い判定の線）
# 判定機の所在（repo パス運用＝$LIB_DIR/../claude/hooks/lib/）。無ければ B 行 0 行・stderr に 1 行。
HEALTH_JUDGE="$LIB_DIR/../claude/hooks/lib/health_judge.py"
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
  printf '#V\tcmux-dock-frame/3\tProject\n'
  printf 'R\t%s\n' "$reason"
  printf 'E\t1\n'
}

# ヘルス（外部脳）の B 行を stdout へ出す（0〜1 行・設計 §6）。判定機
# health_judge.py を呼び、stage（OK／WARNING／ERROR）を warn 欄（ok／warn／
# error）と表示テキスト（3 値）に写す。判定機が無い・python3 が無い・非 0・
# JSON でない・stage が 3 値でない、のいずれでも 0 行（stderr に 1 行）＝
# 誤った段階を見せない（FR-15 の例外・NFR-2 fail-open）。
# 末尾付記＝extras.fragments_candidates が非負整数のときだけ「 候補N件」
# （0 件も表示＝本人裁定 R-2。段階に影響しない）。
# テスト専用 env HEALTH_JUDGE_NOW が非空なら --now に写す（bootstrap と同名・設計 §4.1）。
emit_health_rows() {
  local py verdict rc fields stage cand warn
  if [ ! -f "$HEALTH_JUDGE" ]; then
    echo "health_judge.py が見つかりません（B 行を省略）: $HEALTH_JUDGE" >&2
    return 0
  fi
  py="$(command -v python3 2>/dev/null)"
  [ -n "$py" ] || py="/usr/bin/python3"
  verdict="$("$py" "$HEALTH_JUDGE" judge \
    --last-run "$MAINT_STATE_FILE" \
    --inventory-latest "$INVENTORY_LATEST" \
    --observation "$HEALTH_OBSERVATION" \
    --recall-log "$RECALL_LOG" \
    --plist "$MAINT_PLIST" \
    --recall-stale-days "$VAULT_AGENT_LOG_STALE_DAYS" \
    ${HEALTH_JUDGE_NOW:+--now "$HEALTH_JUDGE_NOW"} 2>/dev/null)"
  rc=$?
  if [ "$rc" != "0" ] || [ -z "$verdict" ]; then
    echo "health_judge.py が失敗しました（rc=${rc}・B 行を省略）" >&2
    return 0
  fi
  fields="$(printf '%s' "$verdict" | jq -r 'select(type == "object" and .schema == "health-verdict/1")
    | [(.stage // ""), (if (.extras.fragments_candidates | type) == "number" and .extras.fragments_candidates >= 0
                         then (.extras.fragments_candidates | floor | tostring) else "" end)] | @tsv' 2>/dev/null)"
  stage="${fields%%$(printf '\t')*}"
  cand="${fields#*$(printf '\t')}"
  [ "$fields" = "$stage" ] && cand=""
  case "$stage" in
    OK) warn="ok" ;;
    WARNING) warn="warn" ;;
    ERROR) warn="error" ;;
    *)
      echo "health_judge.py の stage が 3 値でありません（B 行を省略）" >&2
      return 0 ;;
  esac
  if [ -n "$cand" ]; then
    printf 'B\t外部脳\t%s\t%s 候補%s件\n' "$warn" "$stage" "$cand"
  else
    printf 'B\t外部脳\t%s\t%s\n' "$warn" "$stage"
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

  printf '#V\tcmux-dock-frame/3\tProject\n'
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
