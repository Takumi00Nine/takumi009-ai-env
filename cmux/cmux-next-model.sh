#!/bin/bash
# cmux Dock「Project」枠の供給側（cmux-session-todo 設計 §28〜§30）。
# Vault の Projects/*.md の frontmatter と Tasks 節を読み、対応表
# （--list・v1/v2 と同一契約）と 1 ティック分のフレーム（--frame・
# 設計 §29。外部脳ヘルスを同居させる＝FR-61 ⑦）を作る。描画（Dock への
# 表示）は一切行わない＝dotfiles 側の cmux-next-watch.sh が受け取って
# 描くだけ（FR-61・FR-62）。
#
# 契約 cmux-dock-frame/4（v5・設計 §40.4・v6 でも不変＝FR-108）。区分は 3 値＝
# 稼働中／待ち／保留。
#
# 待ち（v6・要件 FR-104〜107・設計 §41.5）＝待ちは「▶ の版（今の版＝Task 枠が ▶
# を付ける版）が日時を待っている」こと。`wait_until` の置き場は 2 つで、使い分けは
#   (1) Tasks 節の版の直下に行頭から `- wait_until: <値>` を 1 行（版の待ち日時）
#       ＝▶ の版にある行だけが効く（前の版の行は効かない・先頭の 1 行だけ・
#       字下げ／版の範囲外／Tasks 節の外は読まない）。
#   (2) frontmatter の `wait_until:`（案件の待ち日時・v5 FR-88）＝▶ の版が無い
#       案件（Tasks 節なし・版見出しなし・全版完了・全版タスク 0 件・空タスク）
#       だけに効く。▶ の版がある案件に残っている値は使わず stderr に 1 行。
# 値の文法はどちらも同じ（`YYYY-MM-DDTHH:MM` か `YYYY-MM-DD`＝その日の 00:00・
# ローカル時刻・分精度・前後空白と揃った引用符は剥がす）。有効で判定時刻 <
# 待ち日時のとき「待ち」（status: active のまま・FR-91）。無効な値（秒・
# オフセット付き・文字列・暦外日）は稼働中として扱い（隠さない側）、非空の
# ときだけ stderr に 1 行。判定順＝保留 → 解析不能（稼働中＋診断）→ ▶ の版
# あり（版の待ち行だけで待ち／稼働中）→ ▶ の版なし（frontmatter で待ち／稼働中）
# ＝FR-105。▶ の版の決定は Task 供給側と同じ共有部品（lib-vault-tasks.sh の
# decide_current_version）＝両側で同じ版（FR-106）。
# 判定時刻はテスト専用 env CMUX_NEXT_JUDGE_NOW（`YYYY-MM-DDTHH:MM[:SS]`・
# ローカル・秒は切り捨て）で固定でき、未設定なら実時刻（設計 §40.5.1）。
#
# 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §6）:
# B 行は判定機（claude/hooks/lib/health_judge.py＝唯一の判定ロジック）の写し＝
#   B<TAB>外部脳<TAB><ok|warn|error><TAB><OK|WARNING|ERROR>[ 候補N件]
# を 0〜1 行。判定機が動かないときは 0 行（3 値の外の機構障害＝FR-15 の例外）。
# 旧判定（8 日線・棚卸し n/a・週次 ✅/⚠）は退役。
#
# 引数:
#   --list  ＝ 表示と同じ順序で「番号<TAB>正式プロジェクト名<TAB>next値
#             <TAB>区分（稼働中/待ち/保留）<TAB>待ち日時（待ちの行だけ
#             YYYY-MM-DDTHH:MM・他は空）」の 5 列を出す（v1/v2 の 4 列の
#             位置と意味は不変＝FR-95）。
#   --frame ＝ 1 ティック分のフレーム（§29 の行指向 TSV・P 行は 6 欄）を
#             stdout へ出す（rc は常に 0。例外＝判定時刻の固定口が不正な
#             ときだけ rc=1・stdout 0 バイト＝§40.5.1）。
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

# --- v5: 待ち日時（設計 §40.5） ------------------------------------------------

# `wait_until:` の値 $1（fm_field 済み）を `YYYY-MM-DDTHH:MM` へ正規化して stdout
# へ出す（無効なら空）。rc は常に 0。日付形は T00:00 を補う（FR-89）。形の照合
# （case）→ TZ=UTC の date -j -f で往復させ入力と一致するかで暦の妥当性を見る
# （is_valid_date と同型＝暦外日 02-30→03-02・24:00・10:60 を弾く）。秒・
# オフセット付き・文字列は case で落ちる。
normalize_wait() {
  local v="$1" n
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) v="${v}T00:00" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]) : ;;
    *) printf ''; return 0 ;;
  esac
  n="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M' "$v" '+%Y-%m-%dT%H:%M' 2>/dev/null)" || { printf ''; return 0; }
  if [ "$n" = "$v" ]; then printf '%s' "$v"; else printf ''; fi
}

# frontmatter ブロック $1 に key "$2" の行があるか（値の有無は見ない）。
# fm_field はキー欠落も空値も空文字を返すので、診断（A-v5-3）の切り分け用。
fm_has_key() {
  printf '%s\n' "$1" | grep -q "^${2}:"
}

# 判定時刻を大域変数 JUDGE_NOW（`YYYY-MM-DDTHH:MM`・ローカル・分精度）へ固定する
# （1 回の呼び出しで 1 回だけ・全ノートが同じ判定時刻で分類される）。
# テスト専用 env CMUX_NEXT_JUDGE_NOW が非空ならそれ（16 文字形か、秒欄が
# [0-5][0-9] の 19 文字形＝先頭 16 文字に切り捨て）。未設定・空なら実時刻。
# どちらも normalize_wait と同じ突合で形と暦を検証し、不正・date 失敗は
# rc=1（呼び出し側が stderr 1 行・stdout 0 バイトで止める＝F-82）。
JUDGE_NOW=""
resolve_judge_now() {
  local v="${CMUX_NEXT_JUDGE_NOW:-}" n
  if [ -n "$v" ]; then
    case "$v" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]) : ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-5][0-9]) v="${v:0:16}" ;;
      *) return 1 ;;
    esac
  else
    v="$(date '+%Y-%m-%dT%H:%M' 2>/dev/null)" || return 1
  fi
  n="$(normalize_wait "$v")"
  [ -n "$n" ] && [ "$n" = "$v" ] || return 1
  JUDGE_NOW="$n"
  return 0
}

# frontmatter の next: が無い／空文字列のノートについて、同じノートの
# Tasks 節から先頭未完タスク（状態が x でない最初のタスク。記載順のまま）
# の本文を取り出す（FR-31）。$1＝read_note の TSV ストリーム（v6＝同じノートを
# v6 の判定と next 導出で 2 回解析しない＝NFR-18・§41.5.5。解析は呼び出し側）。
# 未完タスクが無いときは何も出さず非0で返る。
derive_next_from_tasks() {
  printf '%s\n' "$1" | awk -F '\t' '
    $1 == "T" && $2 != "x" { print $3; found = 1; exit }
    END { if (!found) exit 1 }
  '
}

# Tasks 見出しの安価な有無判定（v6・NFR-18・設計 §41.5.5・D-v6-4）。解析部品の
# 見出し判定（サニタイズ後の ^##[ \t]+Tasks[ \t]*$）の上位集合＝サニタイズは
# 制御文字を空白へ置くだけなので、生ファイルの「`##` で始まり Tasks を含む行」
# を見れば、解析して版が出る入力を取りこぼさない（偽なら解析しても版は出ない）。
# 偽陽性（`##Tasks` など）は無駄な解析 1 回で無害。外部プロセスを起こさない
# （builtin の read＋case。AC-117・NFR-18 の時間予算）。
note_has_tasks_heading() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "##"*Tasks*) return 0 ;; esac
  done < "$1" 2>/dev/null
  return 1
}

# v5 の frontmatter 判定（▶ の版が無いと確定したノート専用＝順 5・FR-107）。
# 大域 RANK／WAIT を設定する（呼び出し側は裸の文で呼ぶ＝サブシェルにしない）。
# 無効値は稼働中へ倒す（隠さない側）。診断はキーあり＋非空＋正規化失敗だけ（A-v5-3）。
RANK=1
WAIT=""
classify_by_frontmatter() {
  local fm="$1" base="$2" wait_raw
  wait_raw="$(fm_field "$fm" wait_until)"
  WAIT="$(normalize_wait "$wait_raw")"
  if [ -n "$WAIT" ] && [ "$JUDGE_NOW" \< "$WAIT" ]; then
    RANK=2                                   # 待ち＝判定時刻 < 待ち日時（同じ分は稼働中）
  else
    if [ -z "$WAIT" ] && [ -n "$wait_raw" ] && fm_has_key "$fm" wait_until; then
      echo "wait_until が無効です（稼働中として扱う）: ${base}: ${wait_raw}" >&2
    fi
    RANK=1
    WAIT=""
  fi
}

# v6 の版の待ち判定（▶ の版があるノート＝順 4／4′・FR-104・FR-105）。$1＝▶ の版の
# 先頭の待ち行の生値（decide_current_version の第 3 欄）・$2＝frontmatter・$3＝slug。
# 値は frontmatter と同じ剥がし（fm_unquote）→ 同じ正規化（normalize_wait）を通す。
# 大域 RANK／WAIT を設定する。診断（設計 §41.5.4・固定語）＝非空かつ正規化失敗
# なら `無効`（値つき）・frontmatter に `wait_until:` が非空で残っていれば `使わない`
# （frontmatter の値つき・待ちでも稼働中でも出す）。空値・待ち行なし・過去・同時刻
# は診断なし（D-v6-3）。frontmatter の値は区分に使わない（本人確定）。
classify_by_version_wait() {
  local raw fm="$2" base="$3" fm_wait
  raw="$(fm_unquote "$1")"
  WAIT="$(normalize_wait "$raw")"
  if [ -n "$WAIT" ] && [ "$JUDGE_NOW" \< "$WAIT" ]; then
    RANK=2
  else
    if [ -z "$WAIT" ] && [ -n "$raw" ]; then
      echo "版の待ち日時が無効です（稼働中として扱う）: ${base}: ${raw}" >&2
    fi
    RANK=1
    WAIT=""
  fi
  fm_wait="$(fm_field "$fm" wait_until)"   # 非空＝キーあり（fm_has_key は不要）
  if [ -n "$fm_wait" ]; then
    echo "frontmatter の wait_until は使わない（▶ の版があるため・版の待ち行だけを見る）: ${base}: ${fm_wait}" >&2
  fi
}

# セクション1: Projects/*.md の frontmatter を走査し、区分を順位で判定
# （1=稼働中／2=待ち／3=保留・FR-105 の順で先勝ち・設計 §41.5.3）:
#   順 1 非表示 → 順 2 保留（v6 の判定を省略・next 導出は行う）→ 順 3 Tasks 見出し
#   なし（順 5 へ）→ 順 3′ 解析不能（稼働中＋診断 `解析できない`・frontmatter を
#   採用しない）→ 順 4／4′ ▶ の版あり（版の待ち行だけ）→ 順 5 ▶ の版なし（v5 の
#   frontmatter 判定）。
# "順位<TAB>sortkey<TAB>名前<TAB>next値<TAB>待ち日時" を 1→2→3・各区分内は
# 更新日降順で標準出力へ並べる（表示と --list の共通データ源。
# number_entries() が読む唯一の入口）。判定時刻は main が JUDGE_NOW に固定済み。
# 待ち日時は normalize_wait の ASCII 固定形か空しか入らない（sanitize 不要）。
# Projects ディレクトリが列挙不能（無い・ディレクトリでない・読めない）なら
# stderr 1 行＋非0（--list は非0・--frame は既存経路で理由フレーム＝AC-138）。
# glob 不成立を「0 件の正常な表」と取り違えない。mktemp 失敗時も非0。
collect_entries() {
  local projects_dir="$VAULT/Projects" f base fm status nextval
  local tmpfile sortkey rank derived wait tsv parsed decision

  if [ ! -d "$projects_dir" ] || [ ! -r "$projects_dir" ] || [ ! -x "$projects_dir" ]; then
    echo "Projects ディレクトリを読めません: $projects_dir" >&2
    return 1
  fi
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/cmux-next-model.XXXXXX" 2>/dev/null)"
  [ -n "$tmpfile" ] || return 1
  for f in "$projects_dir"/*.md; do
    [ -e "$f" ] || continue
    fm="$(fm_extract <"$f")" || continue
    [ -z "$fm" ] && continue
    status="$(fm_field "$fm" status)"
    base="$(sanitize_str "$(basename "$f" .md)")"
    wait=""
    # parsed: 0=未解析／1=解析済み（tsv 有効）／2=解析不能（順 3′）
    parsed=0
    tsv=""
    if status_allowed "$status" "$STATUS_ALLOW"; then
      if note_has_tasks_heading "$f"; then
        if tsv="$(read_note "$f" 2>/dev/null)"; then
          parsed=1
        else
          parsed=2
        fi
      fi
      if [ "$parsed" -eq 2 ]; then
        # 順 3′: ▶ の不在が確定していないので frontmatter を採用しない（F-113）。
        echo "Tasks 節を解析できない（稼働中として扱う・frontmatter の wait_until は採用しない）: ${base}" >&2
        RANK=1; WAIT=""
      elif [ "$parsed" -eq 1 ]; then
        decision="$(printf '%s\n' "$tsv" | decide_current_version)"
        case "$decision" in
          -1$'\t'*) classify_by_frontmatter "$fm" "$base" ;;                        # 順 5: ▶ の版なし（5 分類）
          *) classify_by_version_wait "${decision#*$'\t'cur$'\t'}" "$fm" "$base" ;;  # 順 4／4′: 第 3 欄＝先頭の待ち行
        esac
      else
        classify_by_frontmatter "$fm" "$base"                          # 順 3→5: Tasks 見出しなし
      fi
      rank="$RANK"; wait="$WAIT"
    elif status_allowed "$status" "$STATUS_HOLD"; then
      rank=3                                   # 保留＝版の待ち行も frontmatter も読まない
    else
      continue
    fi
    nextval="$(sanitize_str "$(fm_field "$fm" next)")"
    if [ -z "$nextval" ] && [ "$parsed" -ne 2 ]; then
      # next 導出（v1 FR-31・status に依らず）。v6 の判定で解析済みならその結果を
      # 使い、未解析（保留・Tasks 見出しなし）ならここで 1 回だけ解析する。
      if [ "$parsed" -eq 0 ]; then
        tsv="$(read_note "$f" 2>/dev/null)" || tsv=""
      fi
      derived="$(derive_next_from_tasks "$tsv")"
      if [ -n "$derived" ]; then
        nextval="$(sanitize_str "$(truncate_plain "$derived" 15)")"
      fi
    fi
    sortkey="$(fm_field "$fm" updated)"
    is_valid_date "$sortkey" || sortkey="$(fm_field "$fm" date)"
    is_valid_date "$sortkey" || sortkey="0000-00-00"
    printf '%s\t%s\t%s\t%s\t%s\n' "$rank" "$sortkey" "$base" "$nextval" "$wait" >>"$tmpfile"
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
# collect_entries の出力（rank<TAB>sortkey<TAB>name<TAB>next<TAB>wait）を記載順に
# 1 から番号付けし、"番号<TAB>rank<TAB>name<TAB>next<TAB>wait" を stdout へ出す。
# --list も --frame もこの関数の出力だけを読み、自分では数えない
# （DT-10。render_next() の idx を移さない）。純関数（stdin/stdout のみ）。
number_entries() {
  awk -F '\t' 'NF { n++; printf "%d\t%s\t%s\t%s\t%s\n", n, $1, $3, $4, $5 }'
}

# 順位→区分ラベルの awk 関数（--list と --frame の両方の awk に前置する＝
# 正本 1 か所・設計 §40.5.4）。
LABEL_AWK='function label(r) { return (r == 3) ? "保留" : (r == 2) ? "待ち" : "稼働中" }'

# --- `--list`（v1/v2 の 4 列＋待ち日時の第 5 列＝FR-95） ------------------------------------------
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
  number_entries < "$raw" | awk -F '\t' "$LABEL_AWK"' NF {
    printf "%s\t%s\t%s\t%s\t%s\n", $1, $3, $4, label($2), $5
  }'
  list_rc=$?
  rm -f "$raw"
  return "$list_rc"
}

# --- `--frame`（新規・設計 §29） -------------------------------------------

print_reason_frame() {
  local reason="$1"
  printf '#V\tcmux-dock-frame/4\tProject\n'
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

  printf '#V\tcmux-dock-frame/4\tProject\n'
  awk -F '\t' "$LABEL_AWK"' { printf "P\t%s\t%s\t%s\t%s\t%s\n", $1, $3, $4, label($2), $5 }' "$entries_tmp"
  cat "$health_tmp"
  printf 'E\t%s\n' "$body_n"

  rm -f "$entries_tmp" "$health_tmp"
  return 0
}

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-next-model.sh --list    番号・正式プロジェクト名・next値・区分（稼働中/待ち/保留）・待ち日時 の 5 列 TSV
  cmux-next-model.sh --frame   1 ティック分のフレーム（cmux-dock-frame/4）
待ち＝「▶ の版（今の版＝Task 枠が ▶ を付ける版）」が日時を待っていること。wait_until の置き場は 2 つ:
  (1) Tasks 節の版の直下に行頭から `- wait_until: YYYY-MM-DDTHH:MM`（YYYY-MM-DD 可）＝▶ の版の行だけが効く
  (2) frontmatter の `wait_until:`＝▶ の版が無い案件（Tasks 節なし・全版完了・全版タスク 0 件など）だけに効く
環境変数（テスト専用）: CMUX_NEXT_JUDGE_NOW=YYYY-MM-DDTHH:MM[:SS]（待ち判定の判定時刻・ローカル）
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

  # 判定時刻の固定はモード分岐の前（設計 §40.5.1・D-v5-3）。不正な固定値・
  # 実時刻の date 失敗は --list/--frame 共通で rc=1・stdout 0 バイト・stderr 1 行
  # （run_frame の「失敗を理由フレーム rc=0 に変換する」経路に入る前に止める）。
  if ! resolve_judge_now; then
    echo "判定時刻を決められません（CMUX_NEXT_JUDGE_NOW=${CMUX_NEXT_JUDGE_NOW:-}・形は YYYY-MM-DDTHH:MM[:SS]）" >&2
    exit 1
  fi

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
