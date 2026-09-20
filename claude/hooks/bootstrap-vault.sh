#!/bin/bash
# SessionStart hook: 必読の Read 指示・開幕1行・外部脳ヘルス・実体プロファイル警告を注入する。
# 全文は注入しない（大きいとハーネスがファイルへ退避し先頭しか見えない）＝「各ファイルを Read で全文読め」の短い指示だけを出す。
# ワーカー（stdin JSON に agent_type が付く／他セッションがリーダーのチーム config.json に自分の session_id が載る）には何も注入しない。
# 経緯＝[[Decisions/2026-09-19-ai-env-optimization-rulings]]
# サブ機での挙動（README「Sub machine」から 2026-09-19 に移設・原文）: On sub machines, private notes such as `Personal/profile-personal.md` and `Knowledge/mistakes.md` don't exist, but since `bootstrap-vault.sh` (the SessionStart hook) is designed to only list **files that actually exist** as required reading, no "not found" warnings appear.
VAULT="${BOOTSTRAP_VAULT:-$HOME/Data/obsidian}"
TEAMS_DIR="${BOOTSTRAP_TEAMS_DIR:-$HOME/.claude/teams}"

# 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §5）: ①観測記録を書く → ②判定機（lib/health_judge.py＝唯一の
# 判定ロジック）を呼ぶ → ③注入ブロックのヘルス節を描く。fail-open＝ここで何が起きてもブートストラップ本文は必ず出す。
# 旧判定（8 日線・「N 日成功していません」・「前回の週次メンテ結果」・「フック死の疑い」）は退役。
# ⚠️ 既定が実ファイルの env 6 本（VAULT_READS_LOG・VAULT_RECALL_LOG・VAULT_INVENTORY_LOG_DIR・
# MAINTENANCE_LAST_RUN_FILE・MAINTENANCE_PLIST_FILE・HEALTH_OBSERVATION_FILE）はテストで必ず fixture へ向ける。
: "${VAULT_READS_LOG:=$HOME/.claude/logs/vault-reads.tsv}"
: "${VAULT_RECALL_LOG:=$HOME/.claude/logs/vault-recall.tsv}"
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"  # scripts/check-drift.sh ⑥ と同じ既定値＝想起の疑い判定の現行の線（据え置き）
# vault_inventory.py の OUT_DIR と同じ既定値（直下の latest.json を読む）。
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"
# maintenance.sh（週次）の状態記録（schema 2＝run／completed／ack。旧 6 キーは互換のため残る）。
: "${MAINTENANCE_LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
# 配置済み LaunchAgent＝直近の予定時刻の正本（判定機が plistlib で直接読む。派生コピーは持たない）。
: "${MAINTENANCE_PLIST_FILE:=$HOME/Library/LaunchAgents/com.takumi009.maintenance.plist}"
# SessionStart の観測記録（読込・前セッションの想起）。書き手＝本フック（想起の実行体以外の観測者）。
: "${HEALTH_OBSERVATION_FILE:=$HOME/.claude/logs/health/session-observation.json}"

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
# 外部脳ヘルスの判定機（repo パス運用＝profile_resolve.py と同じ。$HOME へ symlink しない）。
: "${HEALTH_JUDGE_LIB:=$BOOTSTRAP_SELF_DIR/lib/health_judge.py}"
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

# ---------------------------------------------------------------------------
# 外部脳ヘルス（設計 v1.2 §5）＝①観測記録 → ②判定機 → ③描画。
# ---------------------------------------------------------------------------

# write_health_observation — ①観測記録（health-observation/1）を書く（D-6）。
# 引数: $1=required（改行区切り・LOCAL_ONLY を除く必読集合） $2=missing（改行区切り・想定外の欠落）。
# 前セッション＝最後に観測記録を書いたセッション（既存ファイルの session_id。無ければ null）。
# `injected`＝recall_valid_rows ≥ 1 → true／reads_rows ≥ 1 ∧ recall_valid_rows == 0 → false／それ以外 → null。
# 書けたら HEALTH_OBS_PATH=$HEALTH_OBSERVATION_FILE・HEALTH_OBS_WRITE_FAILED=0。
# 書けなければ（F-9）一時ファイルへ書いて判定は続け、HEALTH_OBS_WRITE_FAILED=1。
HEALTH_OBS_PATH=""
HEALTH_OBS_WRITE_FAILED=0
HEALTH_OBS_TMP=""
write_health_observation() {
  local required_nl="$1" missing_nl="$2"
  local prev_sid="" counts reads_rows=0 recall_valid=0 recall_err=0 injected="null" root_readable="false"
  local observed_at json tmp
  [ -d "$VAULT" ] && [ -r "$VAULT" ] && root_readable="true"
  if [ -f "$HEALTH_OBSERVATION_FILE" ]; then
    prev_sid="$(jq -r 'if type == "object" then (.session_id // empty) else empty end' "$HEALTH_OBSERVATION_FILE" 2>/dev/null)"
  fi
  if [ -n "$prev_sid" ]; then
    # reads: 2 列目が前 sid の行数／recall: 2 列目が前 sid かつ 3 列目非空（候補提示＋heartbeat）／ERROR 行: 2 列目 ERROR かつ 4 列目が前 sid。
    # awk 1 回（存在するログだけを渡す＝外部プロセスを増やさない）。
    local awk_prog='
        FILENAME == reads { if ($2 == sid) r++; next }
        { if ($2 == sid && $3 != "") v++; else if ($2 == "ERROR" && $4 == sid) e++ }
        END { printf "%d\t%d\t%d\n", r, v, e }'
    counts=""
    if [ -f "$VAULT_READS_LOG" ] && [ -f "$VAULT_RECALL_LOG" ]; then
      counts="$(awk -F '\t' -v sid="$prev_sid" -v reads="$VAULT_READS_LOG" "$awk_prog" "$VAULT_READS_LOG" "$VAULT_RECALL_LOG" 2>/dev/null)"
    elif [ -f "$VAULT_READS_LOG" ]; then
      counts="$(awk -F '\t' -v sid="$prev_sid" -v reads="$VAULT_READS_LOG" "$awk_prog" "$VAULT_READS_LOG" 2>/dev/null)"
    elif [ -f "$VAULT_RECALL_LOG" ]; then
      counts="$(awk -F '\t' -v sid="$prev_sid" -v reads="$VAULT_READS_LOG" "$awk_prog" "$VAULT_RECALL_LOG" 2>/dev/null)"
    fi
    if [ -n "$counts" ]; then
      reads_rows="${counts%%	*}"; counts="${counts#*	}"
      recall_valid="${counts%%	*}"; recall_err="${counts#*	}"
      case "$reads_rows" in ''|*[!0-9]*) reads_rows=0 ;; esac
      case "$recall_valid" in ''|*[!0-9]*) recall_valid=0 ;; esac
      case "$recall_err" in ''|*[!0-9]*) recall_err=0 ;; esac
    fi
    if [ "$recall_valid" -ge 1 ]; then
      injected="true"
    elif [ "$reads_rows" -ge 1 ]; then
      injected="false"
    fi
  fi
  observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  json="$(jq -n --arg at "$observed_at" --arg sid "$SESSION_ID" --arg src "$HOOK_SOURCE" \
    --argjson root "$root_readable" --arg required "$required_nl" --arg missing "$missing_nl" \
    --arg prev "$prev_sid" --argjson reads "$reads_rows" --argjson valid "$recall_valid" \
    --argjson err "$recall_err" --argjson injected "$injected" \
    '{schema: "health-observation/1", observed_at: $at, session_id: $sid, source: $src,
      load: {vault_root_readable: $root,
             required: ($required | split("\n") | map(select(length > 0))),
             missing: ($missing | split("\n") | map(select(length > 0)))},
      recall_prev: {session_id: (if $prev == "" then null else $prev end), reads_rows: $reads,
                    recall_valid_rows: $valid, recall_error_rows: $err, injected: $injected}}' 2>/dev/null)"
  [ -n "$json" ] || json='{"schema":"health-observation/1","load":null,"recall_prev":null}'
  tmp="$HEALTH_OBSERVATION_FILE.tmp.$$"
  if mkdir -p "$(dirname "$HEALTH_OBSERVATION_FILE")" 2>/dev/null \
     && printf '%s\n' "$json" > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$HEALTH_OBSERVATION_FILE" 2>/dev/null; then
    HEALTH_OBS_PATH="$HEALTH_OBSERVATION_FILE"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  HEALTH_OBS_WRITE_FAILED=1
  HEALTH_OBS_TMP="${TMPDIR:-/tmp}/health-observation.$$.json"
  if printf '%s\n' "$json" > "$HEALTH_OBS_TMP" 2>/dev/null; then
    HEALTH_OBS_PATH="$HEALTH_OBS_TMP"
  else
    HEALTH_OBS_PATH="/nonexistent-dir/health-observation.json"
  fi
  return 1
}

# ③描画（jq 1 回）: 機械可読＝固定 ASCII キー・値は日本語・値が無ければ「該当なし」（設計 §5）。
# ヘッダに stage= を 1 回だけ。項目行は全項目に severity=。行末の now=injected はテスト専用 env の残留を可視化（F-19）。
HEALTH_RENDER_JQ='
def na: if . == null or . == "" then "該当なし" else (. | tostring) end;
def q: "「" + ((. | na) | gsub("[\t\r\n]"; " ")) + "」";
def src_label: {maintenance: "週次メンテ", inventory: "棚卸し", load: "読込", recall: "想起"}[.] // .;
def ack_text: if . == null then "該当なし"
  elif .state == "pending" then "対処済み・次回判定待ち（\(.at | na): \(.note | na)）"
  else "申告後に再失敗（\(.at | na): \(.note | na)）" end;
def maint_text: .sources.maintenance as $m
  | if $m.state == "completed" then "completed(\($m.run_id | na), trigger=\($m.trigger | na), streak=\($m.success_streak // 0), info=\($m.info_count // 0))"
    elif $m.state == "running" then "running(開始 \($m.started_at | na)・以下の週次メンテ項目は前回 \($m.prev_completed_run_id // "なし") の完了記録)"
    elif $m.state == "skipped" then "skipped(\($m.skipped | na)・前回 \($m.prev_completed_run_id // "なし") の完了記録)"
    elif $m.state == "interrupted" then "interrupted(開始 \($m.started_at | na))"
    elif $m.state == "broken" then "broken(\($m.broken_reason | na))"
    elif $m.state == "legacy" then "legacy(旧形式の記録・run/completed なし)"
    else "absent" end;
def inv_text: .sources.inventory as $i
  | if $i.readable then "\($i.actionable | na)(\($i.date | na), \($i.report_path | na))\(if $i.legacy then " legacy" else "" end)" else "none" end;
def load_text: .sources.load as $l
  | if ($l.observed | not) then "none" elif $l.vault_root_readable == false then "root_unreadable"
    elif ($l.missing_count // 0) > 0 then "missing(\($l.missing_count))" else "ok" end;
def recall_text: .sources.recall as $r
  | if ($r.observed | not) then "none" else "observed(injected=\(if $r.injected == null then "null" else ($r.injected | tostring) end))" end;
("【外部脳ヘルス】stage=\(.stage) items=\(.n_items) judged_at=\(.judged_at) maintenance=\(maint_text) inventory=\(inv_text) load=\(load_text) recall=\(recall_text)"
  + (if .extras.now_injected then " now=injected" else "" end)),
(.items[] | "- [\(.n)] source=\(.source | src_label) severity=\(.severity) "
  + (if .source == "maintenance" then "step=\(.name | na) result=\(.result | na) actor=\(.actor | na) reason=\(.reason | q) "
     elif .source == "inventory" then "kind=\(.kind | na) target=\(.target | na) detail=\(.detail | q) actor=\(.actor | na) "
     elif .source == "load" then "target=\(.target | na) result=\(.result | na) actor=\(.actor | na) "
     else "result=\(.result | na) actor=\(.actor | na) " end)
  + "ok_when=\(.ok_when | q) ack=\(.ack | ack_text) log=\(.log_ref | na)"),
(if .extras.reads_log_stale == true then "INFO:reads_log_stale" else empty end)
'

# compute_health_section — ②判定機 → ③描画。グローバルへ置く:
#   HEALTH_SECTION＝ヘルス節（ヘッダ 1 行＋項目行 0〜N 行＋F-9 の ⚠️ 行）。
#   HEALTH_INFO_LINE＝ヘルス源外の ℹ️ 行（節の外に置く・段階に影響しない＝F-17・SO-8）。
# 判定機が動かない（不在・python3 不在・例外・非 0・JSON でない）ときは固定 1 行「判定不能」（段階を出さない＝F-10・NFR-2）。
HEALTH_SECTION=""
HEALTH_INFO_LINE=""
compute_health_section() {
  local py verdict rendered rc
  HEALTH_SECTION=""
  HEALTH_INFO_LINE=""
  if [ ! -f "$HEALTH_JUDGE_LIB" ]; then
    HEALTH_SECTION="【外部脳ヘルス】判定不能（health_judge.py: 判定機が見つかりません ${HEALTH_JUDGE_LIB}）"
    return 0
  fi
  py="$(command -v python3 2>/dev/null)"
  [ -n "$py" ] || py="/usr/bin/python3"
  verdict="$("$py" "$HEALTH_JUDGE_LIB" judge \
    --last-run "$MAINTENANCE_LAST_RUN_FILE" \
    --inventory-latest "$VAULT_INVENTORY_LOG_DIR/latest.json" \
    --observation "$HEALTH_OBS_PATH" \
    --recall-log "$VAULT_RECALL_LOG" \
    --reads-log "$VAULT_READS_LOG" \
    --plist "$MAINTENANCE_PLIST_FILE" \
    --recall-stale-days "$VAULT_AGENT_LOG_STALE_DAYS" \
    ${HEALTH_JUDGE_NOW:+--now "$HEALTH_JUDGE_NOW"} 2>/dev/null)"
  rc=$?
  if [ "$rc" != "0" ] || [ -z "$verdict" ]; then
    HEALTH_SECTION="【外部脳ヘルス】判定不能（health_judge.py: 判定機が終了コード ${rc} で失敗）"
    return 0
  fi
  rendered="$(printf '%s' "$verdict" | jq -r "$HEALTH_RENDER_JQ" 2>/dev/null)"
  if [ -z "$rendered" ]; then
    HEALTH_SECTION="【外部脳ヘルス】判定不能（health_judge.py: 出力が health-verdict/1 として読めません）"
    return 0
  fi
  # ヘルス源外（SO-8・L-3）: HEALTH_RENDER_JQ が末尾に出す印 1 行（extras.reads_log_stale が
  # true のときだけ）を剥がしてヘルス節の外の ℹ️ 行へ写す（段階に影響しない）。json.dump の区切り
  # 文字列一致に頼らない＝判定機の出力形式の変更に対して脆くしない（外部プロセス +0）。
  case "$rendered" in
    *$'\n'INFO:reads_log_stale)
      HEALTH_INFO_LINE="ℹ️ vault-reads.tsv に直近 ${VAULT_AGENT_LOG_STALE_DAYS} 日の有効な記録なし（ヘルス源外・段階に影響しない）"
      rendered="${rendered%$'\n'INFO:reads_log_stale}"
      ;;
  esac
  HEALTH_SECTION="$rendered"
  if [ "$HEALTH_OBS_WRITE_FAILED" = "1" ]; then
    HEALTH_SECTION="${HEALTH_SECTION}
⚠️ 観測記録の保存に失敗（Dock と食い違う可能性: ${HEALTH_OBSERVATION_FILE}）"
  fi
  return 0
}

INPUT=$(cat 2>/dev/null || true)
# session_id・agent_type・source（startup／resume／…＝観測記録の監査用）を jq 1 回で取る（外部プロセスを増やさない）。
INPUT_FIELDS=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.agent_type // ""), (.source // "")] | @tsv' 2>/dev/null)
SESSION_ID="${INPUT_FIELDS%%	*}"
INPUT_FIELDS_REST="${INPUT_FIELDS#*	}"
AGENT_TYPE="${INPUT_FIELDS_REST%%	*}"
HOOK_SOURCE="${INPUT_FIELDS_REST#*	}"
[ "$INPUT_FIELDS" = "$INPUT_FIELDS_REST" ] && { AGENT_TYPE=""; HOOK_SOURCE=""; }
[ "$INPUT_FIELDS_REST" = "$AGENT_TYPE" ] && HOOK_SOURCE=""

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
  obs_required_nl=""
  obs_missing_nl=""
  for f in "${FILES[@]}"; do
    abs="$VAULT/$f"
    is_local_only_file "$f" || obs_required_nl="${obs_required_nl}${f}
"
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
      obs_missing_nl="${obs_missing_nl}${f}
"
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

  # 外部脳ヘルス（fail-open: 失敗してもブートストラップ本文は必ず出す）＝①観測記録 → ②判定機 → ③描画。
  write_health_observation "$obs_required_nl" "$obs_missing_nl" 2>/dev/null
  compute_health_section 2>/dev/null
  [ -n "$HEALTH_SECTION" ] || HEALTH_SECTION='【外部脳ヘルス】判定不能（health_judge.py: 描画に失敗）'
  [ -n "$HEALTH_OBS_TMP" ] && rm -f "$HEALTH_OBS_TMP" 2>/dev/null

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

${HEALTH_SECTION}${HEALTH_INFO_LINE:+

${HEALTH_INFO_LINE}}
${LOCAL_PROFILE_WARNING:+
【ローカル実体プロファイル】
$LOCAL_PROFILE_WARNING}
EOF
fi

jq -n --arg ctx "$DIRECTIVE" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
