#!/bin/bash
# 読込（AI Brain の SessionStart 寄与）: 必読ノートの Read 指示と外部脳ヘルス節を出す。
# 全文は注入しない（大きいとハーネスがファイルへ退避し先頭しか見えない）＝「各ファイルを Read で全文読め」の短い指示だけを出す。
# 使い方: stdin＝hook JSON（session_id・source を観測記録に使う）。
#   --slots   自分の全枠を 1 回で返す＝{"slots":{"must-read":"<文>","health":"<文>"}}（SessionStart の合成器が起動する形）
#   引数なし  空でない枠を枠順（must-read・health）に空行 1 つで連結し hook 形（additionalContext）で返す（shell からの読込の入口）
# 観測記録はどちらのモードでも起動 1 回につき 1 回書く。ワーカー判定は持たない（合成器が行う）。
# 経緯＝[[Decisions/2026-09-19-ai-env-optimization-rulings]]
# サブ機での挙動（README「Sub machine」から 2026-09-19 に移設・原文）: On sub machines, private notes such as `Personal/profile-personal.md` and `Knowledge/mistakes.md` don't exist, but since `bootstrap-vault.sh` (the SessionStart hook) is designed to only list **files that actually exist** as required reading, no "not found" warnings appear.
VAULT="${BOOTSTRAP_VAULT:-$HOME/Data/obsidian}"

# 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §5）: ①観測記録を書く → ②判定機（health_judge.py＝唯一の
# 判定ロジック）を呼ぶ → ③ヘルス節を描く。fail-open＝ここで何が起きても必読の枠は必ず出す。
# 旧判定（8 日線・「N 日成功していません」・「前回の週次メンテ結果」・「フック死の疑い」）は退役。
# vault_inventory.py の OUT_DIR と同じ既定値（直下の latest.json を読む）。
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"
# maintenance.sh（週次）の状態記録（schema 2＝run／completed／ack。旧 6 キーは互換のため残る）。
: "${MAINTENANCE_LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
# 配置済み LaunchAgent＝直近の予定時刻の正本（判定機が plistlib で直接読む。派生コピーは持たない）。
: "${MAINTENANCE_PLIST_FILE:=$HOME/Library/LaunchAgents/com.takumi009.maintenance.plist}"
# SessionStart の観測記録（必読の読込のみ）。書き手＝本寄与（想起の実行体以外の観測者）。
: "${HEALTH_OBSERVATION_FILE:=$HOME/.claude/logs/health/session-observation.json}"
# 外部脳ヘルスの判定機（同じフォルダ＝repo パス運用。$HOME へ symlink しない）。
: "${HEALTH_JUDGE_LIB:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/health_judge.py}"

# ---------------------------------------------------------------------------
# 外部脳ヘルス（設計 v1.2 §5）＝①観測記録 → ②判定機 → ③描画。
# ---------------------------------------------------------------------------

# 必読の読込検査だけを保存する。想起は共通 observe が扱う。
# 書けなければ（F-9）一時ファイルへ書いて判定は続け、HEALTH_OBS_WRITE_FAILED=1。
HEALTH_OBS_PATH=""
HEALTH_OBS_WRITE_FAILED=0
HEALTH_OBS_TMP=""
write_health_observation() {
  local required_nl="$1" missing_nl="$2"
  local root_readable="false" observed_at json tmp
  [ -d "$VAULT" ] && [ -r "$VAULT" ] && root_readable="true"
  observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  json="$(jq -n --arg at "$observed_at" --arg sid "$SESSION_ID" --arg src "$HOOK_SOURCE" \
    --argjson root "$root_readable" --arg required "$required_nl" --arg missing "$missing_nl" \
    '{schema: "health-observation/1", observed_at: $at, session_id: $sid, source: $src,
      load: {vault_root_readable: $root,
             required: ($required | split("\n") | map(select(length > 0))),
             missing: ($missing | split("\n") | map(select(length > 0)))}}' 2>/dev/null)"
  [ -n "$json" ] || json='{"schema":"health-observation/1","load":null}'
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
def recall_text: .sources.recall | to_entries | map("\(.key)=\(.value)") | join(",");
("【外部脳ヘルス】stage=\(.stage) items=\(.n_items) judged_at=\(.judged_at) maintenance=\(maint_text) inventory=\(inv_text) load=\(load_text) recall=\(recall_text)"
  + (if .extras.now_injected then " now=injected" else "" end)),
(.items[] | "- [\(.n)] source=\(.source | src_label) severity=\(.severity) "
  + (if .source == "maintenance" then "step=\(.name | na) result=\(.result | na) actor=\(.actor | na) reason=\(.reason | q) "
     elif .source == "inventory" then "kind=\(.kind | na) target=\(.target | na) detail=\(.detail | q) actor=\(.actor | na) "
     elif .source == "load" then "target=\(.target | na) result=\(.result | na) actor=\(.actor | na) "
     else "result=\(.result | na) actor=\(.actor | na) " end)
  + "ok_when=\(.ok_when | q) ack=\(.ack | ack_text) log=\(.log_ref | na)")
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
  verdict="$("$py" "$HEALTH_JUDGE_LIB" observe \
    --last-run "$MAINTENANCE_LAST_RUN_FILE" \
    --inventory-latest "$VAULT_INVENTORY_LOG_DIR/latest.json" \
    --observation "$HEALTH_OBS_PATH" \
    --plist "$MAINTENANCE_PLIST_FILE" \
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
  HEALTH_SECTION="$rendered"
  if [ "$HEALTH_OBS_WRITE_FAILED" = "1" ]; then
    HEALTH_SECTION="${HEALTH_SECTION}
⚠️ 観測記録の保存に失敗（Dock と食い違う可能性: ${HEALTH_OBSERVATION_FILE}）"
  fi
  return 0
}

INPUT=$(cat 2>/dev/null || true)
# session_id・source（startup／resume／…＝観測記録の監査用）を jq 1 回で取る（外部プロセスを増やさない）。
INPUT_FIELDS=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.source // "")] | @tsv' 2>/dev/null)
SESSION_ID="${INPUT_FIELDS%%$'\t'*}"
HOOK_SOURCE="${INPUT_FIELDS#*$'\t'}"
[ "$INPUT_FIELDS" = "$SESSION_ID" ] && HOOK_SOURCE=""

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
  ⚠️ 必読のはずのpublicノートが見つかりません（不足 ${unexpected_missing_count} 件）。正本: $VAULT/Preferences/core-workflow.md・$VAULT/Preferences/git-workflow.md:$unexpected_missing"
fi

# 外部脳ヘルス（fail-open: 失敗しても必読の枠は必ず出す）＝①観測記録 → ②判定機 → ③描画。
write_health_observation "$obs_required_nl" "$obs_missing_nl" 2>/dev/null
compute_health_section 2>/dev/null
[ -n "$HEALTH_SECTION" ] || HEALTH_SECTION='【外部脳ヘルス】判定不能（health_judge.py: 描画に失敗）'
[ -n "$HEALTH_OBS_TMP" ] && rm -f "$HEALTH_OBS_TMP" 2>/dev/null

# 枠 must-read（「重要: …」から「④ …」まで）と枠 health（ヘルス節＋節の外の ℹ️ 行）。末尾に改行を付けない。
SLOT_MUST_READ="重要: 必読ノートの全文はこのメッセージには注入されていない。
① タスクに着手する前に、以下の${present_count}ファイルを全文読む:
$list

② 上記を読み終えるまで作業しない。不足があれば読了扱いにせず、最初の応答で本人に伝える。
④ 正本: $VAULT/Preferences/core-workflow.md §5・$VAULT/Preferences/core-worker.md §4・$VAULT/Preferences/vault-operation.md"
SLOT_HEALTH="${HEALTH_SECTION}${HEALTH_INFO_LINE:+

${HEALTH_INFO_LINE}}"

if [ "${1:-}" = "--slots" ]; then
  jq -n --arg m "$SLOT_MUST_READ" --arg h "$SLOT_HEALTH" '{slots: {"must-read": $m, health: $h}}'
else
  jq -n --arg m "$SLOT_MUST_READ" --arg h "$SLOT_HEALTH" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ([$m, $h] | map(select(. != "")) | join("\n\n"))}}'
fi
