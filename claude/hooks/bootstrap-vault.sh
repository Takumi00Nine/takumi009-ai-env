#!/bin/bash
# SessionStart hook: 必読の Read 指示・開幕1行・外部脳ヘルス・実体プロファイル警告を注入する。
# 全文は注入しない（大きいとハーネスがファイルへ退避し先頭しか見えない）＝「各ファイルを Read で全文読め」の短い指示だけを出す。
# ワーカー（stdin JSON に agent_type が付く／他セッションがリーダーのチーム config.json に自分の session_id が載る）には何も注入しない。
# 経緯＝[[Decisions/2026-09-19-ai-env-optimization-rulings]]
VAULT="${BOOTSTRAP_VAULT:-$HOME/Data/obsidian}"
TEAMS_DIR="${BOOTSTRAP_TEAMS_DIR:-$HOME/.claude/teams}"

# 外部脳ヘルス行（fail-open・軽量: check-drift.sh は再実行しない。ファイル1件への jq／ログの tail 程度に留める）。
: "${VAULT_READS_LOG:=$HOME/.claude/logs/vault-reads.tsv}"
: "${VAULT_RECALL_LOG:=$HOME/.claude/logs/vault-recall.tsv}"
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"  # scripts/check-drift.sh ⑥ と同じ既定値
# vault_inventory.py の OUT_DIR と同じ既定値（直下の latest.json を読む）。
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"
# maintenance.sh（週次）の状態ファイル。started_at は毎回無条件更新の契約＝古いままなら週次メンテ自体が起動していない。
: "${MAINTENANCE_LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
: "${MAINTENANCE_STALE_DAYS:=8}"

# ローカル実体プロファイル（正本＝各マシンの $HOME/.config/takumi009-ai-env/profile.md・repo 管理外）。
: "${BOOTSTRAP_ENABLE_LOCAL_PROFILE:=1}"
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
# 判定式の正本は lib/profile_resolve.py の1箇所。installer は hook を個別 symlink するので、
# 自身の symlink を解決した実体ディレクトリ直下の lib/ を見る。
resolve_bootstrap_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
BOOTSTRAP_SELF_DIR="$(resolve_bootstrap_self_dir)"
: "${PROFILE_RESOLVE_LIB:=$BOOTSTRAP_SELF_DIR/lib/profile_resolve.py}"
# Bedrock のピン留め実値ファイル（install-main.sh と同じ既定値。特定キーの有無だけ見る＝値は読まない）。
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
# コア職種マニフェストの実体側入力。claude/hooks/../agents。
: "${AIENV_AGENTS_DIR:=$BOOTSTRAP_SELF_DIR/../agents}"

# 開幕1行（team_mode＝solo|lean|full|unknown）。builtin だけで書く（外部プロセスを起こさない）。
# 文面の正本＝Preferences/core-conduct.md §1（両者の一致は静的テストが検証する）。
compose_team_mode_line() {   # $1 = solo|lean|full|unknown
  case "$1" in
    solo) TEAM_MODE_LINE='🧭 現在＝単独モード（リーダーが全工程を自分で行います。第三者検証はありません）。他のモード＝軽量／フル。切り替えたいときは言ってください' ;;
    lean) TEAM_MODE_LINE='🧭 現在＝軽量モード（実装者と検証職を置き、適用工程ごとに1巡で回します）。他のモード＝単独／フル。切り替えたいときは言ってください' ;;
    full) TEAM_MODE_LINE='🧭 現在＝フルモード（職種ごとに担当を立て、指摘が収まるまで検証を回します）。他のモード＝単独／軽量。切り替えたいときは言ってください' ;;
    *)    TEAM_MODE_LINE='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。' ;;
  esac
}

# DIRECTIVE ⑤（オーケストレーター行動則）をモード別に組み立てる（先頭に「⑤ 」を含む）。
compose_team_mode_directive5() {   # $1 = solo|lean|full|unknown
  local base5='⑤ オーケストレーター行動則（詳細＝Preferences/core-workflow.md §1・§2）: 「作る工程」は自分でやらず委任し、成果物の修正はリーダーが直接行わず作成元ロールへ差し戻す。⚠️ リーダー自身の Edit/Write が正当なのは、~/.claude・scratchpad・リーダー自身の成果物への軽微な修正・ユーザーの直接作業指示のみ（Vault は含まない）。許可パス外への直接編集は delegation-gate-v2 フックが deny する（委任するか、理由をユーザーに明示してマーカー touch）。'
  case "$1" in
    solo)
      TEAM_MODE_DIRECTIVE5='⑤ ⚠️ 単独モードでは全工程をリーダー自身が行い、他の職種を1つも立てない（検証職も立てない）。工程は飛ばさず『専任なし』を明記する。許可パス外の直接編集は、単独モードであることを理由として本人への応答で明示してから touch $MARKER_DIR/claude-direct-edit-ok-<session_id> して再試行する。⚠️ Vault の AI 向け6フォルダも同じ扱い——solo ではリーダーが案件の締めにまとめて直筆する（理由を応答で明示してから touch $MARKER_DIR/claude-vault-direct-ok-<session_id>）。'
      ;;
    lean)
      TEAM_MODE_DIRECTIVE5="${base5} ⚠️ 軽量モードでは要件定義と設計はリーダー自身が行う。実装は implementer へ委任し、適用工程ごとに検証職を1巡だけ回す。requirements-analyst・system-designer・researcher・adoption-critic・operator は立てず『専任なし』を明記する。"
      ;;
    full)
      TEAM_MODE_DIRECTIVE5="$base5"
      ;;
    *)
      TEAM_MODE_DIRECTIVE5="${base5} ⚠️ モードが未確定なので、委任の前に本人へ確認する。"
      ;;
  esac
}

# テスト専用: BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1 なら開幕1行4本を1行1本で出して即終了する（本処理には進まない）。
if [ "${BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY:-0}" = "1" ]; then
  for _tm_mode in solo lean full unknown; do
    compose_team_mode_line "$_tm_mode"
    printf '%s\n' "$TEAM_MODE_LINE"
  done
  exit 0
fi
# 未記入のまま残っていると壊れているのと同じ扱いにする印（T2-MINIMAL）。
# sample（config/profile.md.sample）は実値入りで配布するのでどのキーにも使わないが、安全弁として検出機構は維持する。
LOCAL_PROFILE_SENTINEL='<fill-in>'

# is_v2_resolve_output_well_formed <line> <exit_code> — resolve の出力が stdout 契約
# （固定順・既知フィールドのみ・単一行）どおりかを検査する。
# ⚠️ この regex は lib/profile_resolve.py の do_resolve() が生成するフィールド集合と1対1。
# resolve() の出力へフィールドを足すときは同じコミットでここも更新すること。
is_v2_resolve_output_well_formed() {
  local s="$1" rc="$2"
  # 複数行（改行混入）は契約違反。
  [ "$(printf '%s' "$s" | wc -l | tr -d ' ')" = "0" ] || return 1
  # name は職種名（role.<name> の <name>）＝parser の KEY_RE と同じ文字集合。
  local name='[A-Za-z0-9_.-]+' code='[A-Za-z0-9_-]+' key='[A-Za-z0-9_.-]+' tab notab
  tab="$(printf '\t')"
  # ⚠️ POSIX ERE はブラケット式内で \t をタブへ解釈しない。実際のタブ文字を埋め込む。
  notab="[^${tab}]+"
  # ADVISORY はコロン区切りの補助情報を持つコードも読めるよう、1要素だけ code より広い。
  local adv_code="${code}(:${name}(:${name})?)?"
  case "$s" in
    OK"$tab"*)
      [ "$rc" = "0" ] || return 1
      # TEAM_MODE: は schema_version の直後・MACHINE_ROLE: はその直後で、どちらも必須（位置を一意にする）。
      local re="^OK${tab}schema_version=[0-9]+${tab}TEAM_MODE:(solo|lean|full|unknown)${tab}MACHINE_ROLE:(main|sub|unknown|unavailable)(${tab}VACANT:${name}(,${name})*)?(${tab}VACANT_REASON:${name}=${code}(,${name}=${code})*)?(${tab}VACANT_UNKNOWN:${name}(,${name})*)?(${tab}ADVISORY:${adv_code}(,${adv_code})*)?(${tab}UNKNOWN_EXTRA:${key}(,${key})*)?\$"
      [[ "$s" =~ $re ]]
      ;;
    MINIMAL"$tab"*)
      [ "$rc" = "1" ] || return 1
      # 理由部分にタブを含めない＝コード・理由の2フィールドだけに限定する。
      local re="^MINIMAL${tab}[A-Za-z0-9_-]+${tab}${notab}\$"
      [[ "$s" =~ $re ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# resolve_local_profile <path> — 実体を解決する（symlink拒否／存在確認→preflight→resolve）。
# 標準出力へタブ区切り1行:
#   MINIMAL\t<コード>\t<理由>          … 最小能力+⚠️（schema_version 無し・旧版は T4-LEGACY としてここに含まれる）
#   OK\t<解決値>[\tVACANT:...][\tVACANT_REASON:...][\tVACANT_UNKNOWN:...][\tADVISORY:...][\tUNKNOWN_EXTRA:...]
resolve_local_profile() {
  local path="$1"
  [ -L "$path" ] && { printf 'MINIMAL\tSYMLINK\t実体はsymlinkであってはいけません（マシンローカルの通常ファイルとして直接作成してください）: %s\n' "$path"; return; }
  [ -f "$path" ] || { printf 'MINIMAL\tT1\t実体ファイルが存在しません: %s\n' "$path"; return; }

  if [ ! -f "$PROFILE_RESOLVE_LIB" ]; then
    printf 'MINIMAL\tT10\tresolver本体が見つかりません: %s\n' "$PROFILE_RESOLVE_LIB"
    return
  fi

  local preflight_out preflight_rc=0
  preflight_out="$(python3 "$PROFILE_RESOLVE_LIB" preflight "$path" 2>/dev/null)"
  preflight_rc=$?
  if [ "$preflight_rc" != "0" ]; then
    if [ -n "$preflight_out" ]; then
      printf 'MINIMAL\t%s\n' "$preflight_out"
    else
      printf 'MINIMAL\tT10\tresolver本体の実行に失敗しました（preflight）\n'
    fi
    return
  fi

  local v2_out v2_rc=0
  v2_out="$(python3 "$PROFILE_RESOLVE_LIB" resolve "$path" \
    --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" 2>/dev/null)"
  v2_rc=$?
  if is_v2_resolve_output_well_formed "$v2_out" "$v2_rc"; then
    printf '%s\n' "$v2_out"
  else
    printf 'MINIMAL\tT10\tresolver本体の出力が契約違反です（resolve）\n'
  fi
}

# 外部脳ヘルス行。fail-open＝ここで何が起きてもブートストラップ本文は必ず出す（呼び出し側は 2>/dev/null で出力を捨てるだけ）。
# $machine_role は呼び出し前に代入済み（下部の resolve 出力からの取り出し）。
compute_health_lines() {
  local lines="" now_epoch stale_names=""

  # ① 最新棚卸し＝latest.json（書き手＝vault_inventory.py）。不在→行なし／JSON 破損・date/actionable 欠落・型違反→⚠️1行。
  # jq が無ければ行なし（④と同じ fail-open）。last-run.json の fragments_candidates は読まない（AI へ注入しない）。
  local inv_json="$VAULT_INVENTORY_LOG_DIR/latest.json"
  if [ -f "$inv_json" ] && command -v jq >/dev/null 2>&1; then
    local inv_fields inv_path inv_n inv_date inv_rest
    inv_fields="$(jq -r 'select(type == "object" and (.date | type) == "string" and (.actionable | type) == "number" and .actionable >= 0 and (.actionable | floor) == .actionable) | [(.report_path // "" | tostring), (.actionable | tostring), .date] | join("\t")' "$inv_json" 2>/dev/null)"
    if [ -n "$inv_fields" ]; then
      inv_path="${inv_fields%%$'\t'*}"
      inv_rest="${inv_fields#*$'\t'}"
      inv_n="${inv_rest%%$'\t'*}"
      inv_date="${inv_rest#*$'\t'}"
      [ -n "$inv_path" ] || inv_path="$inv_json"
      lines="${lines}- 棚卸し最新: ${inv_path}（要確認 ${inv_n} 件・${inv_date}）
"
    else
      lines="${lines}- ⚠️ 棚卸しの状態記録が壊れています（latest.json: ${inv_json}）
"
    fi
  fi

  now_epoch="$(date -u +%s 2>/dev/null)"

  # ④ 死活検知（last-run.json）。サブ機（machine_role が厳密に "sub"）には maintenance.sh が無いのでスキップ。
  # それ以外（解決失敗・欠落・main）はメイン機とみなして判定する（fail-closed）。
  if [ "$machine_role" != "sub" ]; then
  # started_at が ${MAINTENANCE_STALE_DAYS} 日以上前＝週次メンテが動いていない。
  #   (a) started_at は新しいが last_success_at が古い＝起動はするが成功していない。
  #   (b) 不在・JSON 破損・両フィールド未記録・実在する値が解析不能/未来日時＝状態記録が無い/壊れている。
  # has() でキーの実在を確認し、実在するのに解析できない値だけを broken にする
  # （キーが無い＝初回未成功の正常な過渡状態とは区別する。`.field // empty` だけでは空文字列/null と区別できない）。
  if [ -n "$now_epoch" ]; then
    local started_at last_success_at started_epoch success_epoch started_age success_age
    local started_broken=0 success_broken=0 has_started="" has_success=""
    started_at=""
    last_success_at=""
    if [ -f "$MAINTENANCE_LAST_RUN_FILE" ]; then
      started_at="$(jq -r '.started_at // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      last_success_at="$(jq -r '.last_success_at // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      has_started="$(jq -r 'has("started_at")' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      has_success="$(jq -r 'has("last_success_at")' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    fi

    started_epoch=""
    if [ "$has_started" = "true" ]; then
      [ -n "$started_at" ] && started_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%Z}" +%s 2>/dev/null)"
      if [ -z "$started_epoch" ] || [ "$started_epoch" -gt "$now_epoch" ]; then
        started_broken=1
        started_epoch=""
      fi
    fi
    success_epoch=""
    if [ "$has_success" = "true" ]; then
      [ -n "$last_success_at" ] && success_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${last_success_at%Z}" +%s 2>/dev/null)"
      if [ -z "$success_epoch" ] || [ "$success_epoch" -gt "$now_epoch" ]; then
        success_broken=1
        success_epoch=""
      fi
    fi

    # ⚠️ macOS の bash 3.2 は二重引用符内で `$VAR）`（波括弧無し＋全角）が化ける。必ず `${VAR}）` の形で書く。
    if { [ -z "$started_at" ] && [ -z "$last_success_at" ]; } \
       || [ "$started_broken" -eq 1 ] || [ "$success_broken" -eq 1 ]; then
      lines="${lines}- ⚠️ 週次メンテの状態記録が無い/壊れています（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
    else
      [ -n "$started_epoch" ] && started_age=$(( (now_epoch - started_epoch) / 86400 ))
      [ -n "$success_epoch" ] && success_age=$(( (now_epoch - success_epoch) / 86400 ))
      if [ -n "$started_epoch" ] && [ "$started_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        lines="${lines}- ⚠️ 週次メンテが${started_age}日動いていません（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
      elif [ -z "$started_epoch" ] && [ -n "$success_epoch" ] && [ "$success_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        # started_at キー自体が無いときだけ last_success_at へフォールバックする。
        lines="${lines}- ⚠️ 週次メンテが${success_age}日動いていません（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
      elif [ -n "$started_epoch" ] && [ -n "$success_epoch" ] && [ "$success_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        lines="${lines}- ⚠️ 週次メンテが起動はするが${success_age}日成功していません（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
      fi
    fi
  fi

  # last_result（success|warn|fail＝maintenance.sh が書く3値）: warn/fail は ⚠️、success＋summary 非空は ℹ️。
  # それ以外の値・キー欠落・ファイル不在・jq 不在は fail-open で無視する。
  if [ -f "$MAINTENANCE_LAST_RUN_FILE" ]; then
    local last_result last_result_summary
    last_result="$(jq -r '.last_result // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    last_result_summary="$(jq -r '.last_result_summary // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    if [ "$last_result" = "warn" ] || [ "$last_result" = "fail" ]; then
      lines="${lines}- ⚠️ 前回の週次メンテ結果: ${last_result}${last_result_summary:+（${last_result_summary}）}（last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
    elif [ "$last_result" = "success" ] && [ -n "$last_result_summary" ]; then
      lines="${lines}- ℹ️ 前回の週次メンテ結果: success（${last_result_summary}）（last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
    fi
  fi
  fi  # machine_role != sub

  # ③ check-drift.sh ⑥相当の簡易死活。reads/recall ログの「最終有効行」（3列目非空）の経過日数が閾値超なら死の疑い。
  # tail の範囲内に有効行が無ければ判定を諦める（fail-open。詳細判定は check-drift.sh の役目）。
  if [ -n "$now_epoch" ]; then
    local pair name f ts epoch age
    for pair in "vault-reads.tsv|$VAULT_READS_LOG" "vault-recall.tsv|$VAULT_RECALL_LOG"; do
      name="${pair%%|*}"
      f="${pair#*|}"
      [ -f "$f" ] || continue
      ts="$(tail -n 50 "$f" 2>/dev/null | awk -F'\t' 'NF>=3 && $3!="" {t=$1} END{if (t!="") print t}')"
      [ -n "$ts" ] || continue
      ts="${ts%Z}"
      epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null)" || continue
      age=$(( (now_epoch - epoch) / 86400 ))
      if [ "$age" -gt "$VAULT_AGENT_LOG_STALE_DAYS" ]; then
        stale_names="${stale_names}${stale_names:+・}${name}"
      fi
    done
  fi
  if [ -n "$stale_names" ]; then
    lines="${lines}- ⚠️ フック死の疑い: ${stale_names}（直近${VAULT_AGENT_LOG_STALE_DAYS}日以内の有効な記録なし。詳細は scripts/check-drift.sh を実行して確認）
"
  fi

  printf '%s' "$lines"
}

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)

is_worker=0
[ -n "$AGENT_TYPE" ] && is_worker=1
if [ "$is_worker" = "0" ] && [ -n "$SESSION_ID" ] && [ -d "$TEAMS_DIR" ]; then
  own_team="session-${SESSION_ID:0:8}"
  for cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$cfg" ] || continue
    team_dir=$(basename "$(dirname "$cfg")")
    [ "$team_dir" = "$own_team" ] && continue  # 自分がリーダーのチーム設定は除外
    if grep -q "$SESSION_ID" "$cfg" 2>/dev/null; then
      is_worker=1
      break
    fi
  done
fi

if [ "$is_worker" = "1" ]; then
  # ワーカーには何も注入しない（共通ルールの正本＝agents/*.md の共通ルール節。in-process ワーカーには本フックの注入が届かない）。
  exit 0
else
  # 必読リスト。サブ機（private 層を持たない）との違いは Personal/ の有無だけ＝単一配列でメイン/サブ両方に効く。
  FILES=(
    "Preferences/absolute-rules.md"
    "Preferences/core-conduct.md"
    "Preferences/core-workflow.md"
    "Personal/profile-personal.md"
    "Preferences/vault-operation.md"
  )
  # private 層＝サブ機に「無くて正常」なファイル。それ以外の欠落は同期失敗・checkout 破損等の異常として別枠で警告する。
  LOCAL_ONLY_FILES=(
    "Personal/profile-personal.md"
  )
  is_local_only_file() {
    local target="$1" candidate
    for candidate in "${LOCAL_ONLY_FILES[@]}"; do
      [ "$candidate" = "$target" ] && return 0
    done
    return 1
  }

  # 必読ファイル一覧を絶対パス+行数付きで生成（行数があれば Read の結果が全文か AI 自身が照合できる）。
  # 存在するファイルだけを載せる＝サブ機で毎回「見つかりません」と警告しない。
  list=""
  present_count=0
  missing_count=0
  unexpected_missing=""
  unexpected_missing_count=0
  for f in "${FILES[@]}"; do
    abs="$VAULT/$f"
    if [ -f "$abs" ]; then
      lines=$(wc -l < "$abs" | tr -d ' ')
      list="$list
  - $abs  （全${lines}行：Readで全文を読むこと）"
      present_count=$((present_count + 1))
    elif is_local_only_file "$f"; then
      missing_count=$((missing_count + 1))
    else
      unexpected_missing="$unexpected_missing
  - $abs"
      unexpected_missing_count=$((unexpected_missing_count + 1))
    fi
  done
  if [ "$missing_count" -gt 0 ]; then
    list="$list
  （private ノートはこのマシンには無い（サブ）: ${missing_count}件は対象外）"
  fi
  if [ "$unexpected_missing_count" -gt 0 ]; then
    list="$list
  ⚠️ 必読のはずのpublicノートが見つかりません（想定外・同期失敗やcheckout破損の可能性。scripts/update-sub.shの再実行・scripts/check-drift.shでの確認を推奨）:$unexpected_missing"
  fi

  # ローカル実体プロファイル: 必読リストには載せない。解決の成否・schema_version・machine_role・照会コマンドは
  # 🧭モード行の末尾セグメントへ織り込む。失敗時は「利用不可（区分）」を同じセグメントに出す（AI は最小能力として振る舞う）。
  LOCAL_PROFILE_WARNING=""
  # profile_kind／machine_role はこのブロックの外でも参照するので先に初期化する。
  profile_kind=""
  machine_role=""
  if [ "$BOOTSTRAP_ENABLE_LOCAL_PROFILE" = "1" ]; then
    profile_status="$(resolve_local_profile "$AIENV_LOCAL_PROFILE_PATH")"
    profile_kind="${profile_status%%$'\t'*}"
    profile_rest="${profile_status#*$'\t'}"
    profile_has_unknown_extra=0
    printf '%s' "$profile_status" | grep -q 'UNKNOWN_EXTRA:' && profile_has_unknown_extra=1

    # 警告＝コード＋取るべき行動1つ。
    if [ "$profile_kind" = "MINIMAL" ]; then
      profile_reason_code="${profile_rest%%$'\t'*}"
      profile_reason_msg="${profile_rest#*$'\t'}"
      if [ "$profile_reason_code" = "T11" ]; then
        LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイル(${AIENV_LOCAL_PROFILE_PATH})に認証情報らしいキー名があります（T11: ${profile_reason_msg}）→ 該当行を削除して再開。最小能力として扱う。"
      else
        LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイル(${AIENV_LOCAL_PROFILE_PATH})を解決できません（${profile_reason_code}: ${profile_reason_msg}）→ 最小能力として扱い、空席の申告（Preferences/core-workflow.md §7）を行う。既定値を発明しない。"
      fi
    elif [ "$profile_has_unknown_extra" = "1" ]; then
      # 未知キーの「値」に秘密が書かれている可能性があるため、機械側の解決は有効でも AI 向けには最小能力として扱う。
      unknown_extra="${profile_status#*UNKNOWN_EXTRA:}"
      LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイルに未知のキーがあります（${unknown_extra}）→ プロファイル利用不可＝最小能力として扱い、ワーカー起動は本人確認へ倒してください（Preferences/core-workflow.md §7）。"
    elif printf '%s' "$profile_status" | grep -q -E '(VACANT|VACANT_REASON|VACANT_UNKNOWN|ADVISORY):'; then
      # 配役の値そのものは再掲しないが、縮退・未確定の職種名と条件番号は必ず注入する（静かな失敗を防ぐ）。
      casting_note="$(printf '%s' "$profile_status" | sed -E 's/^OK\t//')"
      LOCAL_PROFILE_WARNING="ℹ️ 配役表の状態（職種名と条件番号のみ・値は含みません）: ${casting_note}。詳細はPreferences/core-workflow.md §7（職種が空席のとき）を参照してください。"
    fi
  fi

  # TEAM_MODE: の取り出し（パラメータ展開だけ＝外部プロセスなし。$'\t' は command substitution を避けるため）。
  tm_tab=$'\t'
  tm_pat="${tm_tab}TEAM_MODE:"
  team_mode=""
  if [ "$profile_kind" = "OK" ] && [ "$profile_has_unknown_extra" = "0" ]; then
    tm_rest="${profile_status#*"$tm_pat"}"
    [ "$tm_rest" != "$profile_status" ] && team_mode="${tm_rest%%"$tm_tab"*}"
  fi
  case "$team_mode" in solo|lean|full) : ;; *) team_mode="unknown" ;; esac
  compose_team_mode_line "$team_mode"
  compose_team_mode_directive5 "$team_mode"

  # MACHINE_ROLE: も同じ形で取り出す。⚠️ unknown_extra は見ない（機構の分岐は既知キー部分だけを使う。
  # 降格させると廃止キーが残る過渡状態のサブ機で④の誤警告が毎セッション出る）。
  mr_tab=$'\t'
  mr_pat="${mr_tab}MACHINE_ROLE:"
  if [ "$profile_kind" = "OK" ]; then
    mr_rest="${profile_status#*"$mr_pat"}"
    [ "$mr_rest" != "$profile_status" ] && machine_role="${mr_rest%%"$mr_tab"*}"
  fi
  # main|sub|unavailable はそのまま通し、それ以外だけ unknown へ倒す（unavailable では保留行を出さない）。
  case "$machine_role" in main|sub|unavailable) : ;; *) machine_role="unknown" ;; esac
  MACHINE_ROLE_HOLD_LINE=""
  [ "$machine_role" = "unknown" ] && MACHINE_ROLE_HOLD_LINE='⚠️ 配役表の machine_role が未確定です（この機がメイン機かサブ機かを本人が宣言していません）。機役割に依存する判断（Preferences の編集・公開スナップショットの生成・git の立場）は本人へ確認してから行う。既定値を発明しない。'

  # 🧭モード行の末尾セグメント（解決の成否・schema_version・machine_role・照会コマンド）。
  # BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 では解決を試みていないので付けない。
  if [ "$BOOTSTRAP_ENABLE_LOCAL_PROFILE" = "1" ]; then
    if [ "$profile_kind" = "OK" ] && [ "$profile_has_unknown_extra" = "0" ]; then
      sv_tab=$'\t'
      sv_rest="${profile_status#*schema_version=}"
      schema_version_value="${sv_rest%%"$sv_tab"*}"
      TEAM_MODE_LINE="${TEAM_MODE_LINE}｜配役表＝OK schema_version=${schema_version_value} machine_role=${machine_role} 照会＝python3 ~/work/takumi009-ai-env/claude/hooks/lib/role_candidates.py [--role <職種>]"
    else
      # 不在・symlink・validator 違反は区分コード（T1/SYMLINK/T5/…）、UNKNOWN_EXTRA は専用コード名（値は再掲しない）。
      profile_unresolved_code=""
      if [ "$profile_kind" = "MINIMAL" ]; then
        profile_unresolved_code="$profile_reason_code"
      elif [ "$profile_has_unknown_extra" = "1" ]; then
        profile_unresolved_code="UNKNOWN_EXTRA"
      fi
      TEAM_MODE_LINE="${TEAM_MODE_LINE}｜配役表＝利用不可（${profile_unresolved_code}）＝最小能力として振る舞う・ワーカー起動は本人確認へ倒す"
    fi
  fi

  # 外部脳ヘルス行（fail-open: 失敗してもブートストラップ本文は必ず出す）。
  HEALTH_LINES="$(compute_health_lines 2>/dev/null)" || HEALTH_LINES=""

  read -r -d '' DIRECTIVE <<EOF
【セッション開始ブートストラップ｜ハーネス強制注入】

【開幕1行】最初の応答の冒頭に、次の1行をそのまま転記する（1行だけ・要約しない）:
${TEAM_MODE_LINE}
⚠️ この依頼に本人のモード指定が含まれていたら、上の行ではなく指定後のモードの行を1行だけ出す（2行出さない）。モードを変えられるのは本人だけ。

重要: 必読ノートの全文はこのメッセージには注入されていない。
あなたは下記ファイルをまだ読んでいない。プレビューや要約で読んだ気にならないこと。

① タスクに着手する前に、まず Read ツールで以下を「全文」読む（${present_count}ファイルを1回の並列 Read で同時取得すること）:
$list

② 上記を読み終えるまで、ユーザー依頼の実作業（調査・検索・コード変更・委任を含む）に着手しない。
④ 記録職＝subagent_type: vault-scribe（略称不可）。
${TEAM_MODE_DIRECTIVE5}
⑥ プロジェクトが確定したら1回だけ宣言する: ~/work/takumi009-ai-env/cmux/cmux-task-declare.sh set <slug>（宣言済みなら呼び直さない・実行はリーダーであってフックではない）
${MACHINE_ROLE_HOLD_LINE:+
${MACHINE_ROLE_HOLD_LINE}}
${HEALTH_LINES:+
【外部脳ヘルス】（scripts/check-drift.sh ⑥の簡易版。詳細確認は本体を実行）
$HEALTH_LINES}
${LOCAL_PROFILE_WARNING:+
【ローカル実体プロファイル】
$LOCAL_PROFILE_WARNING}
EOF
fi

jq -n --arg ctx "$DIRECTIVE" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
