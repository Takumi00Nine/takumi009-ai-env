#!/usr/bin/env bash
# 週次メンテの手動起動の口（health-self-explain 設計 v1.2 §7.1・D-4・2026-09-20）。
# launchd 経由で scripts/maintenance.sh を起動する＝定期実行と同じ実行体・同じ環境
# （plist の HOME・PATH・USER）・同じ記録先（last-run.json）を通る（FR-7）。起動前に
# 印ファイル $MAINTENANCE_LOG_ROOT/.manual-trigger を置き、runner が run.trigger=manual
# と記録する（FR-22。`launchctl kickstart` を直接叩いた起動は scheduled と記録される
# ＝監査用の既知の限界）。`-k` は付けない（実行中のインスタンスを殺さない・man launchctl）。
#
# 使い方:
#   scripts/maintenance-kick.sh          # 起動して RUN_ID:<id> / STATE_FILE:<path> を印字
#   scripts/maintenance-kick.sh --wait   # さらに完了記録（run.status != running）まで待ち
#                                        # STATUS:<completed|skipped> / FULLY_OK:<true|false>
#                                        # （skipped なら SKIP_REASON:<busy:…>）を印字
#
# 出力は固定文の行だけ（ワーカーの --out 契約と同じ流儀）。終了コード表（§7.1）:
#   0  起動した（--wait なら完了記録まで待った）
#   1  使い方の誤り
#   2  KICK_REFUSED:not_loaded  LaunchAgent が未ロード（scripts/install-maintenance.sh を実行する）
#   3  KICK_REFUSED:busy        Vault 書込ロック保持中、または run.status=running かつ経過 < stale_after_seconds
#   4  KICK_REFUSED:marker      印ファイルを作れない
#   5  KICK_FAILED              launchctl kickstart が失敗（印ファイルは消す）
#   6  KICK_TIMEOUT             起動が KICK_START_TIMEOUT_SECS（既定 30 秒）以内に記録へ現れない
#                               （launchd の stdout＝~/Library/Logs/maintenance.log を見る）。
#                               印ファイルは消す＝遅れて開始した run は scheduled と記録されうる
#   7  KICK_WAIT_TIMEOUT        --wait で stale_after_seconds 以内に完了記録が書かれない（設計 §7.1 の表外＝追加）
# 環境変数（テスト用・既定は実ファイル）: MAINTENANCE_LOG_ROOT・LAST_RUN_FILE・
#   VAULT_WRITER_LOCK_FILE・MAINTENANCE_LABEL・MAINTENANCE_STALE_LOCK_SECONDS・
#   KICK_START_TIMEOUT_SECS・KICK_POLL_SECS（テストでは偽 launchctl を PATH 先頭に置く）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pid-lock.sh
source "$SCRIPT_DIR/lib/pid-lock.sh"

: "${MAINTENANCE_LOG_ROOT:=$HOME/.claude/logs/maintenance}"
: "${VAULT_WRITER_LOCK_FILE:=$MAINTENANCE_LOG_ROOT/vault-writer.lock}"
: "${LAST_RUN_FILE:=$MAINTENANCE_LOG_ROOT/last-run.json}"
: "${MAINTENANCE_LABEL:=com.takumi009.maintenance}"
: "${MAINTENANCE_STALE_LOCK_SECONDS:=7200}"
: "${KICK_START_TIMEOUT_SECS:=30}"
: "${KICK_POLL_SECS:=1}"
MANUAL_TRIGGER_MARKER="$MAINTENANCE_LOG_ROOT/.manual-trigger"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

WAIT=0
case "${1:-}" in
  "") ;;
  --wait) WAIT=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "usage: scripts/maintenance-kick.sh [--wait]" >&2; exit 1 ;;
esac

# last-run.json の run／completed の要点を `|` 区切り 1 行で返す（フィールドは
# run_id|status|started_epoch|stale_after_seconds|skip_reason|fully_ok|completed.run_id。
# ファイル不在・解析不能・型違反は空欄＝fail-open）。値は sys.argv で渡す（maintenance.sh と同じ流儀）。
read_run_fields() {
  python3 -c "
import datetime, json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        d = json.load(f)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
run = d.get('run') if isinstance(d.get('run'), dict) else {}
comp = d.get('completed') if isinstance(d.get('completed'), dict) else {}
def s(v):
    return v.replace('|', ' ') if isinstance(v, str) else ''
epoch = ''
try:
    epoch = str(int(datetime.datetime.fromisoformat(s(run.get('started_at')).replace('Z', '+00:00')).timestamp()))
except Exception:
    pass
stale = run.get('stale_after_seconds')
stale = str(stale) if isinstance(stale, int) and not isinstance(stale, bool) and stale > 0 else ''
fo = comp.get('fully_ok')
fo = 'true' if fo is True else ('false' if fo is False else '')
print('|'.join([s(run.get('run_id')), s(run.get('status')), epoch, stale, s(run.get('skip_reason')), fo, s(comp.get('run_id'))]))
" "$LAST_RUN_FILE" 2>/dev/null || echo "||||||"
}

load_run_fields() {
  local line
  line="$(read_run_fields)"
  IFS='|' read -r RUN_ID RUN_STATUS RUN_EPOCH RUN_STALE RUN_SKIP_REASON COMPLETED_FULLY_OK COMPLETED_RUN_ID <<<"$line"
}

# --- 1. LaunchAgent がロード済みか ---
UID_NUM="$(id -u 2>/dev/null)" || UID_NUM=""
if [[ -z "$UID_NUM" ]]; then
  echo "KICK_REFUSED:not_loaded"
  echo "HINT: id -u でユーザー ID を取得できません（launchd ドメインを決められません）" >&2
  exit 2
fi
DOMAIN="gui/${UID_NUM}"
if ! launchctl print "$DOMAIN/$MAINTENANCE_LABEL" >/dev/null 2>&1; then
  echo "KICK_REFUSED:not_loaded"
  echo "HINT: LaunchAgent ${MAINTENANCE_LABEL} が ${DOMAIN} にロードされていません。scripts/install-maintenance.sh を実行してください" >&2
  exit 2
fi

# --- 2. 実行中・ロック中なら起動しない（F-5＝重なりを事前に防ぐ） ---
load_run_fields
if is_pid_lock_held "$VAULT_WRITER_LOCK_FILE"; then
  echo "KICK_REFUSED:busy"
  echo "HINT: Vault 書込ロック ${VAULT_WRITER_LOCK_FILE} を別プロセスが保持中です（週次メンテまたはバックアップの実行中）。数分後に再実行してください" >&2
  exit 3
fi
if [[ "$RUN_STATUS" == "running" && -n "$RUN_EPOCH" ]]; then
  NOW_EPOCH="$(date +%s)"
  LIMIT="${RUN_STALE:-$MAINTENANCE_STALE_LOCK_SECONDS}"
  if [[ $(( NOW_EPOCH - RUN_EPOCH )) -lt "$LIMIT" ]]; then
    echo "KICK_REFUSED:busy"
    echo "HINT: 直近の実行 ${RUN_ID} が実行中です（run.status=running・開始から $(( NOW_EPOCH - RUN_EPOCH )) 秒 < ${LIMIT} 秒）。完了を待って再実行してください" >&2
    exit 3
  fi
fi
PREV_RUN_ID="$RUN_ID"

# --- 3. 手動起動の印（FR-22） ---
if ! mkdir -p "$MAINTENANCE_LOG_ROOT" 2>/dev/null || ! : > "$MANUAL_TRIGGER_MARKER" 2>/dev/null; then
  echo "KICK_REFUSED:marker"
  echo "HINT: 印ファイルを作れません: ${MANUAL_TRIGGER_MARKER}" >&2
  exit 4
fi

# --- 4. launchd 経由で起動（-k は付けない＝実行中を殺さない） ---
if ! launchctl kickstart "$DOMAIN/$MAINTENANCE_LABEL" >/dev/null 2>&1; then
  rm -f "$MANUAL_TRIGGER_MARKER" 2>/dev/null || true
  echo "KICK_FAILED"
  echo "HINT: launchctl kickstart ${DOMAIN}/${MAINTENANCE_LABEL} が失敗しました（launchctl error <code> で復号できます）" >&2
  exit 5
fi

# --- 5. 開始記録（run.run_id の変化）を待つ ---
wait_until() {   # $1=最大秒数 $2..=条件（関数名）。条件が真になれば 0・超過で 1。
  local max="$1"; shift
  local polls remaining
  # 最大秒数 ÷ ポーリング間隔（小数可）を切り上げた回数だけ試す（bash 3.2 は小数演算を持たない）。
  polls="$(python3 -c "import math, sys; print(max(1, math.ceil(float(sys.argv[1]) / float(sys.argv[2]))))" "$max" "$KICK_POLL_SECS" 2>/dev/null)" || polls=30
  remaining="$polls"
  while true; do
    if "$@"; then return 0; fi
    [[ "$remaining" -gt 0 ]] || return 1
    remaining=$(( remaining - 1 ))
    sleep "$KICK_POLL_SECS"
  done
}
run_id_changed() {
  load_run_fields
  [[ -n "$RUN_ID" && "$RUN_ID" != "$PREV_RUN_ID" ]]
}
run_not_running() {
  load_run_fields
  [[ -n "$RUN_STATUS" && "$RUN_STATUS" != "running" ]]
}

if ! wait_until "$KICK_START_TIMEOUT_SECS" run_id_changed; then
  # health-self-explain 検証 A-3（リーダー裁定）＝印は「起動要求の記録」ではなく
  # 「起動した runner に trigger を伝える媒体」。30 秒以内に開始を観測できない
  # 要求は失敗として閉じ、印を消す。runner が実際には遅れて起動していた場合、
  # その run は口を経ない起動と区別できず scheduled と記録されうる（FR-22 と
  # 同型の既知の限界として受容＝README 参照）。
  rm -f "$MANUAL_TRIGGER_MARKER" 2>/dev/null || true
  echo "KICK_TIMEOUT"
  echo "HINT: ${KICK_START_TIMEOUT_SECS} 秒以内に開始記録が現れませんでした（印ファイルは消しました＝遅れて開始した run は scheduled と記録されうる）。launchd の stdout（$HOME/Library/Logs/maintenance.log）を確認してください" >&2
  exit 6
fi
echo "RUN_ID:${RUN_ID}"
echo "STATE_FILE:${LAST_RUN_FILE}"
[[ "$WAIT" -eq 1 ]] || exit 0

WAIT_MAX="${RUN_STALE:-$MAINTENANCE_STALE_LOCK_SECONDS}"
if ! wait_until "$WAIT_MAX" run_not_running; then
  echo "KICK_WAIT_TIMEOUT"
  echo "HINT: ${WAIT_MAX} 秒以内に完了記録が書かれませんでした（run.status=running のまま＝次回判定で中断として現れます）" >&2
  exit 7
fi
echo "STATUS:${RUN_STATUS}"
if [[ "$RUN_STATUS" == "skipped" ]]; then
  echo "SKIP_REASON:${RUN_SKIP_REASON}"
else
  echo "FULLY_OK:${COMPLETED_FULLY_OK}"
fi
exit 0
