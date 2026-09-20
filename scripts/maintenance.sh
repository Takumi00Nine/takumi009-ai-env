#!/usr/bin/env bash
# 週次メンテナンスランナー（LaunchAgent com.takumi009.maintenance・月曜 06:00・無人。手動起動＝scripts/maintenance-kick.sh）。
# Phase0: backup-vault.sh（直前スナップショット）→ Vault 書込ロック → export-public-vault.sh 再試行
# Phase1: ① check-drift.sh --json（drift は警告・止めない）② fragments_log.py --since <last_success_at> --json
#         ③ vault_inventory.py --json（各ステップは maintenance_run_step.py で timeout 隔離・1 本の失敗で止めない）
# Phase3: cmux-task-declare.sh prune → Fragments 当日ファイルへサマリ 1 行 → backup-vault.sh → last-run.json → 異常時のみ macOS 通知 → 30 日整理
# 出力: ~/.claude/logs/maintenance/<日付>/<時刻-pid>/（latest symlink）と last-run.json（契約＝README「状態記録の契約（schema 2）」・
#       health-self-explain 設計 v1.2 §3。読み手＝claude/hooks/lib/health_judge.py（bootstrap-vault.sh・cmux-next-model.sh 経由）。
#       旧 6 キー（started_at・last_success_at・last_result・last_result_summary・fragments_*）は旧読み手（check-drift.sh ⑥・
#       fragments_log.py）互換のため従来どおり書き、run／completed／success_streak／ack を足す＝終わり方 6 経路すべてで run を書く）
# 環境変数で全パス・timeout を上書き可（テスト用）。経緯＝Decisions/2026-08-10-round6-rulings・2026-09-19-ai-env-optimization-rulings
#
# 補足（README「Weekly Maintenance Runner」から 2026-09-19 に移設・原文）:
# Phase 0 — takes a pre-run snapshot via `backup-vault.sh`, acquires a Vault write-lock (PID file, held through Phase 3), and retries `export-public-vault.sh` if the `vault-public/Preferences` snapshot is behind.
# Phase 1 (detection only, read-only) — runs, in order, `check-drift.sh` (environment health check; since 2026-08-10, a drift finding, execution error, or timeout no longer aborts the run — it's recorded as a warning and the run continues. The sole gate for Vault write safety is Phase 0's pre-run snapshot), `fragments_log.py`, and `vault_inventory.py`. The 3 steps are isolated from each other's failures. `vault_inventory.py` writes `~/.claude/logs/vault-inventory/latest.json` (`actionable` = number of fixable findings), which the SessionStart health line and the Dock read.
# Phase 3 — appends a one-line summary to today's Fragments file, updates `last-run.json` (`last_success_at` only on a fully clean run; `last_result` — success/warn/fail — is always recorded, and a warning or failure shows up as a ⚠️ line in the next session's startup health check; `fragments_candidates` = number of unprocessed Fragments since the last successful run, shown by the Dock's Project pane weekly line as "候補N件" — it is never injected into the AI, and nothing moves until the user says "昇格して"), takes a final `backup-vault.sh` snapshot, releases the Vault write-lock, sends a macOS notification only if something went wrong, and prunes maintenance logs older than 30 days.
# `scripts/maintenance.sh` is the single weekly runner (Monday 06:00 since 2026-09-20 (03:00 before), installed by `scripts/install-maintenance.sh`) that replaced the older separate Vault-cultivation LaunchAgents on 2026-07-16. The unattended headless-Claude apply step (Fragments promotion / Knowledge merge / Decision propagation) was retired on 2026-09-19 — the runner now only detects and counts; promotion happens while the user is present, via `vault-scribe`.
# All intermediate files and machine-readable status files for a given run live under `~/.claude/logs/maintenance/<YYYY-MM-DD>/<HHMMSS>-<pid>/`, with `~/.claude/logs/maintenance/latest` always pointing at the most recent run.
#
# 実行方法: scripts/maintenance.sh

set -uo pipefail  # -e は使わない（Phase1の1項目失敗で残りが止まらないようにする）

# 中間ファイルはディレクトリ0700・ファイル0600（ファイル側はumaskで絞る）。
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pid-lock.sh
source "$SCRIPT_DIR/lib/pid-lock.sh"
# shellcheck source=scripts/lib/status-file.sh
source "$SCRIPT_DIR/lib/status-file.sh"
# shellcheck source=scripts/lib/macos-notify.sh
source "$SCRIPT_DIR/lib/macos-notify.sh"

: "${VAULT:=$HOME/Data/obsidian}"
: "${AIENV_REPO:=$HOME/work/takumi009-ai-env}"
: "${MAINTENANCE_LOG_ROOT:=$HOME/.claude/logs/maintenance}"
: "${VAULT_WRITER_LOCK_FILE:=$MAINTENANCE_LOG_ROOT/vault-writer.lock}"
: "${LAST_RUN_FILE:=$MAINTENANCE_LOG_ROOT/last-run.json}"
# Vault書込ロックのstale判定秒数（週次実行1回分が収まる余裕＝既定2時間。
# 前回実行がクラッシュしてロックを片付けられなかった場合の自動解除しきい値）。
: "${MAINTENANCE_STALE_LOCK_SECONDS:=7200}"
: "${MAINTENANCE_RETENTION_DAYS:=30}"

# 各ステップの個別timeout（秒）。
: "${TIMEOUT_BACKUP_VAULT:=180}"
: "${TIMEOUT_EXPORT_PUBLIC_VAULT:=180}"
: "${TIMEOUT_CHECK_DRIFT:=120}"
: "${TIMEOUT_FRAGMENTS_LOG:=90}"
: "${TIMEOUT_VAULT_INVENTORY:=180}"
# 宣言記録の掃除（cmux-task-declare.sh prune）はcmuxを叩くためソケット半死で
# ハングしうる。既存ステップと同じ形で打ち切る（既定30秒）。
: "${TIMEOUT_TASK_PRUNE:=30}"

log() { echo "[maintenance] $*"; }
warn() { echo "[maintenance] WARN: $*" >&2; }

# 完全正常終了かどうか（last-run.jsonのlast_success_at更新判定に使う）。
# add_anomaly()を1回でも呼べば自動的に0になる。
RUN_FULLY_OK=1

# 異常理由の蓄積（Phase3「異常時のみmacOS通知」用）。呼ぶたびにRUN_FULLY_OKも
# 0へ倒す＝「隔離して継続する異常」でも1件あればlast_success_atは進めない
# （fragments_log.pyの--sinceが次回も同じ窓を再走査できるようにする）。
#
# 2026-09-20 health-self-explain（設計 v1.2 §3.3）: 引数を
#   add_anomaly <step_id> <result> <message> [<log_ref>]
# へ拡張した。通知用の ANOMALIES と並行して、完了記録 last-run.json の
# completed.steps[] の材料 STEP_RECORDS（TSV 1 行／件＝id・name・result・actor・
# reason・log_ref）へ積む。result は fail／warn の 2 値（interrupted は書き手が
# 書けない＝読み手が導く）。理由は切り詰めず（200 文字の last_result_summary は
# 旧読み手専用）、TAB・CR・LF だけここで空白へ正規化する（TSV の列ずれ防止。
# ESC 等の残りの制御文字は write_completed_record の Python 側で正規化する）。
# 理由文の材料は「工程の固定文＋子の stdout の要約行」に限る（NFR-4。env・引数・
# URL・ロックファイルの中身は載せない＝各呼び出し箇所の一覧は変更記録
# impl-A-v1.md）。主体は下の固定表 step_actor（表に無い step_id は本人＝§3.4）。
ANOMALIES=()
STEP_RECORDS=()
add_anomaly() {
  local step_id="$1" result="$2" message="$3" log_ref="${4:-}"
  local reason="$message"
  [[ "$result" == "warn" ]] || result="fail"
  reason="${reason//$'\t'/ }"; reason="${reason//$'\r'/ }"; reason="${reason//$'\n'/ }"
  ANOMALIES+=("$message"); warn "$message"; RUN_FULLY_OK=0
  STEP_RECORDS+=("${step_id}"$'\t'"$(step_name "$step_id")"$'\t'"${result}"$'\t'"$(step_actor "$step_id" "$result")"$'\t'"${reason}"$'\t'"${log_ref}")
}

# 工程の固定表（設計 v1.2 §3.3 の表・主体の付与元＝書き手の固定表 §3.4）。
# 読み手（health_judge.py）は理由文から主体を推定しない＝ここで付与済みの値だけ
# を使う。表に無い step_id は「判定できない項目は本人に倒す」（要件 §1）。
step_name() {
  case "$1" in
    phase0-dir)       echo "Phase0 実行ディレクトリ作成" ;;
    phase0-lock)      echo "Phase0 Vault書込ロック取得" ;;
    phase0-backup)    echo "Phase0 直前スナップショット" ;;
    phase0-export)    echo "Phase0 公開スナップショット再試行" ;;
    phase1-drift)     echo "Phase1① check-drift" ;;
    phase1-fragments) echo "Phase1② fragments_log" ;;
    phase1-inventory) echo "Phase1③ vault_inventory" ;;
    phase3-summary)   echo "Phase3 Fragmentsサマリ追記" ;;
    phase3-backup)    echo "Phase3 最終commit" ;;
    phase3-record)    echo "Phase3 last_success_at更新" ;;
    *)                echo "$1" ;;
  esac
}
step_actor() {
  case "$1" in
    # drift 検知（rc=1・warn）は人に見せて判断させる＝本人（Decision 08-05）。
    # 実行異常・timeout（fail）は drift の判断ではなく実行の失敗＝AI（V-15）。
    phase1-drift) if [[ "$2" == "warn" ]]; then echo "本人"; else echo "AI"; fi ;;
    # phase0-export＝公開スナップショット再試行は承認済み export の再実行＝AI
    # （本人裁定 OQ-2・2026-09-20。本人ゲートは公開の可否＝push に掛かる）。
    phase0-dir|phase0-lock|phase0-backup|phase0-export|phase1-fragments|phase1-inventory|phase3-summary|phase3-backup|phase3-record)
      echo "AI" ;;
    *) echo "本人" ;;
  esac
}

# informationalな注記の蓄積。add_anomaly()と違いRUN_FULLY_OKは倒さない＝
# last_result/last_success_atの判定には影響しない「参考情報」専用チャネル
# （未知config.tomlキー・宣言掃除の未実施など「warnへ昇格させない」情報）。
# stderrのwarn()は使わずlog()のみ。
INFO_NOTES=()
add_info_note() { INFO_NOTES+=("$1"); log "INFO: $1"; }

# --- last-run.json 読み書きヘルパ（原子更新・破損時はfail-openで{}扱い） ---
# ファイルパス・フィールド名・値はPythonコード文字列へ埋め込まずsys.argv経由で
# 渡す（値に ' が含まれると構文が壊れ、細工された値では任意コード実行になりうる）。
read_last_run_field() {
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        d = json.load(f)
    v = d.get(sys.argv[2])
    print(v if isinstance(v, str) else '')
except Exception:
    print('')
" "$LAST_RUN_FILE" "$1"
}

write_last_run_field() {
  python3 -c "
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
data[sys.argv[2]] = sys.argv[3]
tmp = path.parent / ('.' + path.name + '.tmp-' + str(os.getpid()))
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding='utf-8')
os.replace(str(tmp), str(path))
" "$LAST_RUN_FILE" "$1" "$2"
}

# write_last_run_json <key> <json-literal>: 値をJSONリテラル（数値・"文字列"等）
# として入れる。`null` ならキーを削除する（前回値を残さないため）。原子更新・
# 破損時{}扱いはwrite_last_run_field()と同じ。文字列専用の同関数は残す。
write_last_run_json() {
  python3 -c "
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
value = json.loads(sys.argv[3])
if value is None:
    data.pop(sys.argv[2], None)
else:
    data[sys.argv[2]] = value
tmp = path.parent / ('.' + path.name + '.tmp-' + str(os.getpid()))
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding='utf-8')
os.replace(str(tmp), str(path))
" "$LAST_RUN_FILE" "$1" "$2"
}

# last_result: success/warn/failの3値＋警告要旨の短文をlast-run.jsonへ記録する
# （bootstrap-vault.shの起動ヘルス行が翌セッション冒頭で拾う）。
# last_result/last_result_summaryは常にペアで意味を持つため1回のPython起動で
# 両方を同時に書く（2回に分けると1回目成功・2回目失敗時に新旧値が混在しうる）。
# fail-open（書込失敗はwarn()するだけで処理は止めない）。$2は空文字列でもよい。
write_last_result() {
  local value="$1" summary="$2"
  python3 -c "
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
data['last_result'] = sys.argv[2]
data['last_result_summary'] = sys.argv[3]
tmp = path.parent / ('.' + path.name + '.tmp-' + str(os.getpid()))
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding='utf-8')
os.replace(str(tmp), str(path))
" "$LAST_RUN_FILE" "$value" "$summary" \
    || warn "last-run.jsonのlast_result/last_result_summary更新に失敗しました（value=${value}）"
}

# --- 状態記録 schema 2（health-self-explain 設計 v1.2 §3.1〜§3.3・2026-09-20） ---
# run＝直近の開始とその終わり方（status: running→completed／skipped）・
# completed＝直近の完了記録（工程ごとの結果種別・理由・主体・ログ所在）・
# success_streak（FR-24）・ack（リーダー AI の対処済み申告＝health_judge.py ack が
# 書き、完全正常終了で失効＝FR-9）。旧 6 キーは旧読み手の互換のため従来どおり書く。
#
# write_run_record <status> [<skip_reason>] [<finished_at>]
#   run を「自分の run_id の内容」で丸ごと書き直す（status だけを patch しない＝
#   定期と手動が重なって後発の busy-skip が run を上書きしていても、先発の完了で
#   先発の run に戻る＝§3.2・F-4）。開始時（status=running）は旧キー started_at と
#   schema=2 も同じ 1 回の Python 起動で書く（2 回に分けると片方だけ成功しうる）。
#   stale_after_seconds＝MAINTENANCE_STALE_LOCK_SECONDS をそのまま写す（読み手は
#   この値で「実行中」と「中断」を分ける。線を読み手側に複製しない＝C-6）。
write_run_record() {
  local status="$1" skip_reason="${2:-}" finished_at="${3:-}"
  python3 -c "
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
run_id, run_dir, started_at, trigger, stale, status, skip_reason, finished_at = sys.argv[2:10]
data['schema'] = 2
if status == 'running':
    data['started_at'] = started_at
data['run'] = {
    'run_id': run_id, 'run_dir': run_dir, 'started_at': started_at, 'trigger': trigger,
    'status': status, 'stale_after_seconds': int(stale) if stale.isdigit() else None,
    'skip_reason': skip_reason or None, 'finished_at': finished_at or None,
}
tmp = path.parent / ('.' + path.name + '.tmp-' + str(os.getpid()))
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding='utf-8')
os.replace(str(tmp), str(path))
" "$LAST_RUN_FILE" "$RUN_ID" "$RUN_DIR" "$STARTED_AT" "$MAINTENANCE_TRIGGER" \
    "$MAINTENANCE_STALE_LOCK_SECONDS" "$status" "$skip_reason" "$finished_at"
}

# write_run_status skipped <busy:backup0|busy:lock>
#   busy-skip の終わり方 (e)(f)＝「開始したが当該予定の仕事をしていない」を中断
#   （status=running のまま）と区別して書く。completed は書かない（前回のまま）。
#   fail-open（書けなくても warn だけ＝読み手には中断として現れる＝正直な失敗）。
write_run_status() {
  write_run_record "$1" "${2:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    || warn "last-run.jsonのrun.status更新に失敗しました（status=${1}${2:+ ・$2}）"
}

# write_completed_record
#   完了記録に到達する 4 経路（(a) 完走・(b) Phase0 直前スナップショット失敗・
#   (c) Vault 書込ロック取得失敗・(d) 実行ディレクトリ作成失敗）で同じ形の
#   completed を書く（書き手契約 FR-10・NFR-6＝経路で形を変えない）。同じ 1 回の
#   Python 起動で run を自分の内容（status=completed・finished_at）に書き戻し
#   （completed.run_id == run.run_id を書き手が保証）、success_streak（fully_ok
#   なら +1・でなければ 0）と ack の失効（fully_ok なら削除・再失敗なら残す→
#   読み手が run_id の不一致で「申告後に再失敗」と読む）も処理する。
#   completed.steps[] の 1 要素＝異常工程 1 つ（正常な工程は書かない＝fully_ok の
#   とき steps は空）。理由は切り詰めず、制御文字（C0・DEL）を空白へ正規化する。
#   同じ step_id が複数回積まれた場合（例: Phase1② の件数書込失敗と
#   scan_error_count>0 が同じ実行で起きる）は 1 工程 1 件に畳む（理由は「／」で
#   連結・fail が warn に勝つ）。fail-open（書けなければ warn＝run.status は
#   running のまま残り、次回判定で中断として現れる＝F-2）。
write_completed_record() {
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 -c "
import json, os, pathlib, re, sys
CTRL = re.compile(r'[\x00-\x1f\x7f]')
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
run_id, run_dir, started_at, trigger, stale, finished_at, fully_ok_raw, n_steps_raw = sys.argv[2:10]
n_steps = int(n_steps_raw)
rest = sys.argv[10:]
step_rows, info_rows = rest[:n_steps], rest[n_steps:]
fully_ok = fully_ok_raw == '1'
steps, index = [], {}
for row in step_rows:
    parts = row.split('\t')
    while len(parts) < 6:
        parts.append('')
    sid, name, result, actor, reason, log_ref = parts[:6]
    rec = {'id': sid, 'name': name, 'result': 'warn' if result == 'warn' else 'fail',
           'reason': CTRL.sub(' ', reason), 'actor': actor if actor in ('AI', '本人') else '本人',
           'log_ref': log_ref or run_dir}
    if sid in index:
        prev = steps[index[sid]]
        prev['reason'] = prev['reason'] + '／' + rec['reason']
        if prev['result'] == 'warn' and rec['result'] == 'fail':
            prev['result'] = 'fail'
            prev['actor'] = rec['actor']
            # health-self-explain 検証 A-2: fail が warn を上書きするとき、
            # 読み手が参照するログ所在（log_ref）も fail 側（今の異常の材料）へ
            # 差し替える。actor だけ差し替えて log_ref を先の warn のままにすると、
            # 読み手が fail の詳細を warn 側のログから探すことになる。
            prev['log_ref'] = rec['log_ref']
    else:
        index[sid] = len(steps)
        steps.append(rec)
if not fully_ok and not steps:
    # 書き手契約（FR-10）: 成功時刻が進まなかった実行の要対処項目が空になることはない。
    steps.append({'id': 'unknown', 'name': 'unknown', 'result': 'fail',
                  'reason': '異常工程の記録が無いまま完全正常終了しませんでした（runner のバグの疑い）',
                  'actor': '本人', 'log_ref': run_dir})
data['schema'] = 2
data['completed'] = {'run_id': run_id, 'run_dir': run_dir, 'trigger': trigger,
                     'started_at': started_at, 'finished_at': finished_at,
                     'fully_ok': fully_ok, 'steps': steps,
                     'info': [CTRL.sub(' ', x) for x in info_rows]}
data['run'] = {'run_id': run_id, 'run_dir': run_dir, 'started_at': started_at, 'trigger': trigger,
               'status': 'completed', 'stale_after_seconds': int(stale) if stale.isdigit() else None,
               'skip_reason': None, 'finished_at': finished_at}
streak = data.get('success_streak')
if not (isinstance(streak, int) and not isinstance(streak, bool) and streak >= 0):
    streak = 0
data['success_streak'] = streak + 1 if fully_ok else 0
if fully_ok:
    data.pop('ack', None)
tmp = path.parent / ('.' + path.name + '.tmp-' + str(os.getpid()))
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding='utf-8')
os.replace(str(tmp), str(path))
" "$LAST_RUN_FILE" "$RUN_ID" "$RUN_DIR" "$STARTED_AT" "$MAINTENANCE_TRIGGER" \
    "$MAINTENANCE_STALE_LOCK_SECONDS" "$finished_at" "$RUN_FULLY_OK" "${#STEP_RECORDS[@]}" \
    ${STEP_RECORDS[@]+"${STEP_RECORDS[@]}"} ${INFO_NOTES[@]+"${INFO_NOTES[@]}"} \
    || warn "last-run.jsonのcompleted更新に失敗しました（run.statusはrunningのまま＝次回の判定で中断として現れます）"
}

# maintenance_run_step.pyの--status-file出力を読み、"OK <returncode>" または
# "WRAPPER_FAIL <reason>" を返す（設計書§1.2「Python subprocess.run(cmd,
# timeout=N, start_new_session=True)」の起動元。呼び出し側は終了コードだけでは
# 「ラッパー自身がタイムアウトしたか」「子プロセス自身がたまたま同じ値を
# 返したか」を区別できないため、必ずstatus-fileを見る＝
# maintenance_run_step.py自身の推奨する使い方）。status-fileが無い/壊れて
# いる場合はラッパーが最後まで到達できなかったとみなしfail扱いにする
# （maintenance_run_step.py自身の契約どおり）。
parse_step_status() {
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        d = json.load(f)
except Exception:
    print('WRAPPER_FAIL status_file_unreadable')
    sys.exit(0)
if d.get('timed_out'):
    print('WRAPPER_FAIL timeout')
elif d.get('spawn_error'):
    print('WRAPPER_FAIL spawn_error')
elif d.get('usage_error'):
    print('WRAPPER_FAIL usage_error')
else:
    print('OK ' + str(d.get('returncode')))
" "$1"
}

# $1=timeout $2=status_file $3=stdout_file $4=stderr_file -- $5..=cmd
# maintenance_run_step.py経由でtimeout付き起動する共通ラッパ（設計書§1.2
# 「各ステップはscripts/vault-agents/maintenance_run_step.py経由で起動」）。
run_wrapped_step() {
  local timeout="$1" status_file="$2" stdout_file="$3" stderr_file="$4"
  shift 4
  python3 "$SCRIPT_DIR/vault-agents/maintenance_run_step.py" \
    --timeout "$timeout" --status-file "$status_file" -- "$@" \
    > "$stdout_file" 2> "$stderr_file"
}

# =============================================================================
# 実行ごと一意ディレクトリの作成＋latest symlinkの原子的張替え
# =============================================================================

DATE_COMPONENT="$(date +%Y-%m-%d)"
TIME_COMPONENT="$(date +%H%M%S)"
DATE_DIR="$MAINTENANCE_LOG_ROOT/$DATE_COMPONENT"
RUN_DIR="$DATE_DIR/${TIME_COMPONENT}-$$"
# run_id＝RUN_DIR の MAINTENANCE_LOG_ROOT からの相対（<日付>/<時刻-pid>・設計 §3.2）。
RUN_ID="$DATE_COMPONENT/${TIME_COMPONENT}-$$"
# Vault 書込ロック取得の結果語（busy／error）を acquire_pid_lock が書く一時の印
# （guard が読む＝設計 §3.3 (f)）。テストで書込不能な場所へ向けて「状態不明」経路を再現できる。
: "${MAINTENANCE_LOCK_STATUS_FILE:=$RUN_DIR/lock-status.txt}"

# --- 起動元の印（FR-22・設計 §3.2・§7.1） ---
# MAINTENANCE_TRIGGER が scheduled／manual ならその値。無ければ手動起動の口
# （scripts/maintenance-kick.sh）が置く印ファイル .manual-trigger が在れば manual
# （読んだら削除＝次の定期起動へ持ち越さない）・無ければ scheduled。
# `launchctl kickstart` を直接叩いた起動は scheduled と記録される（監査用の既知の限界）。
#
# health-self-explain 検証 A-4: 印ファイルは MAINTENANCE_TRIGGER が env で
# 与えられているときも読んだら削除する（「読んだら削除」を env の有無に依らず
# 一貫して適用する）。env=scheduled で印だけが残ると、次の env 無し起動が
# 誤って manual と記録される（テスト経路のみで起きる＝本番 plist は
# MAINTENANCE_TRIGGER を設定しない）。
MANUAL_TRIGGER_MARKER="$MAINTENANCE_LOG_ROOT/.manual-trigger"
MANUAL_TRIGGER_MARKER_PRESENT=0
[[ -f "$MANUAL_TRIGGER_MARKER" ]] && MANUAL_TRIGGER_MARKER_PRESENT=1
if [[ "$MANUAL_TRIGGER_MARKER_PRESENT" == "1" ]]; then
  rm -f "$MANUAL_TRIGGER_MARKER" || warn "手動起動の印ファイルを削除できませんでした（次回も manual と記録されうる可能性があります）: $MANUAL_TRIGGER_MARKER"
fi
if [[ "${MAINTENANCE_TRIGGER:-}" != "scheduled" && "${MAINTENANCE_TRIGGER:-}" != "manual" ]]; then
  if [[ "$MANUAL_TRIGGER_MARKER_PRESENT" == "1" ]]; then
    MAINTENANCE_TRIGGER="manual"
  else
    MAINTENANCE_TRIGGER="scheduled"
  fi
fi

# --- 設定不正の検査（health-self-explain 検証 A-9） ---
# MAINTENANCE_STALE_LOCK_SECONDS は run.stale_after_seconds へそのまま写す値
# （§3.2・線を読み手側に複製しない＝C-6）。不正なら write_run_record／
# write_completed_record は stale.isdigit() が偽になって stale_after_seconds に
# null を書いてしまい、読み手には型違反（④ 破損）に見えうる。acquire_pid_lock
# 側（scripts/lib/pid-lock.sh の同じ ^[1-9][0-9]*$ 検査）も非数値を exit 1 で
# 拒むが、それより前に null が書かれてしまう経路を断つため、開始時に
# fail-fast する（started_at／run が書けないときと同じ型＝L431 相当）。
if [[ ! "$MAINTENANCE_STALE_LOCK_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[maintenance] FAIL: MAINTENANCE_STALE_LOCK_SECONDSが正の整数ではありません: '${MAINTENANCE_STALE_LOCK_SECONDS}'" >&2
  write_last_result "fail" "MAINTENANCE_STALE_LOCK_SECONDSの設定が不正です（${MAINTENANCE_STALE_LOCK_SECONDS}）"
  notify_macos "maintenance.sh 異常終了" "MAINTENANCE_STALE_LOCK_SECONDSの設定が不正なため中断しました: ${MAINTENANCE_STALE_LOCK_SECONDS}"
  exit 1
fi

# --- last-run.json の started_at と run を無条件で最初に書く（自己ロックアウト対策） ---
# check-drift.sh⑥相当の「定常メンテ自体が動いているか」の死活監視が、
# started_atの経過日数だけで判定できるようにする（設計書§4「レポート未処理
# 検知・ALERT監視を削除、maintenance新鮮度チェック（started_atの経過日数のみで
# 判定）に置換」）。busy/errorで即座に終了する経路でもここまでは必ず到達する。
# 2026-09-20: 実行ディレクトリ作成より前へ前倒しした（設計 v1.2 §3.3 (d)＝ディレクトリ
# 作成失敗の経路でも run を書き、「run は前回・completed は今回」の記録を作らない）。
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! write_run_record running; then
  # started_at／run はcheck-drift.sh⑥相当の死活監視と health_judge.py が依拠する
  # 自己ロックアウト対策の要であり、これが書けない環境（ディスク枯渇・権限異常等）
  # では以降の処理を続けても同種の書込みが軒並み失敗する可能性が高いため、
  # ここだけはfail-fastする（戻り値を見ないと書込失敗が黙って握り潰されたまま
  # 「started_atは記録済み」という前提で処理が進んでしまうため）。記録は前回の
  # まま→予定を過ぎれば未起動として現れる（設計 §4.5 F-1）。
  echo "[maintenance] FAIL: last-run.jsonのstarted_at/run更新に失敗しました: $LAST_RUN_FILE" >&2
  # last_resultも同じファイルへの書込みのため、started_at同様に失敗しうる
  # （write_last_result自体はfail-openでwarn()するだけ＝二重に中断はしない）。
  # それでも書ける環境（started_atの書込みだけがたまたま失敗した等）では
  # 次回起動時のヘルス行に反映させたい。
  write_last_result "fail" "last-run.jsonのstarted_at更新に失敗しました"
  notify_macos "maintenance.sh 異常終了" "last-run.jsonへの書込みに失敗したため中断しました。詳細: $RUN_DIR"
  exit 1
fi

# 終わり方 (d)＝日付／実行ディレクトリ作成失敗。run は上で書けているので、
# completed（phase0-dir fail 1 件）を同じ run_id で書いて中断する。
mkdir -p "$DATE_DIR" || {
  echo "[maintenance] FAIL: 日付ディレクトリを作成できません: $DATE_DIR" >&2
  add_anomaly phase0-dir fail "Phase0: 日付ディレクトリを作成できませんでした（${DATE_DIR}）"
  write_last_result "fail" "日付ディレクトリを作成できませんでした（${DATE_DIR}）"
  write_completed_record
  exit 1
}
# RUN_DIRは`$$`(PID)を含むため通常は衝突しないが、`mkdir -p`は既存ディレクトリを
# 静かに再利用してしまう（PID再利用等の極めて稀な衝突時にログが混在しうる）。
# 単純な`mkdir`（`-p`無し）はディレクトリが既に存在すると失敗するため、これを
# 衝突検知として使う。
if ! mkdir "$RUN_DIR"; then
  echo "[maintenance] FAIL: 実行ディレクトリの作成に失敗しました（既に存在する可能性があります）: $RUN_DIR" >&2
  add_anomaly phase0-dir fail "Phase0: 実行ディレクトリの作成に失敗しました（既に存在する可能性があります・${RUN_DIR}）"
  write_last_result "fail" "実行ディレクトリの作成に失敗しました（${RUN_DIR}）"
  write_completed_record
  exit 1
fi
chmod 0700 "$MAINTENANCE_LOG_ROOT" "$DATE_DIR" "$RUN_DIR" 2>/dev/null || true
log "実行ディレクトリ: $RUN_DIR"

# latest symlinkを原子的に張り替える（一時名で作ってからrename）。
# 通常のシェル`mv`はBSD/GNU問わず「宛先が既存のディレクトリを指すsymlinkの
# 場合、宛先の中へsourceを移動する」という挙動を取るため（`mv -T`はGNU限定で
# macOS標準mvには無い）、単純に`mv tmp latest`とすると symlink自体の置換に
# ならず、tmp（symlink）がlatestが指すディレクトリの中へ移動されてしまう
# 実害のある落とし穴がある（本実装時に実機で再現確認済み）。POSIXの
# rename(2)はシンボリックリンクそのものを対象にし、この落とし穴が無いため、
# 既にこのリポジトリ全体が依存しているpython3経由でos.rename()を呼ぶ
# （bashのみでこのファイルシステム操作を安全に行う標準的な手段が無いため）。
# latest symlink自体は「今回のRUN_DIRを指し示す利便性のための機能」であり
# RUN_DIR自体の正当性には影響しないため、失敗してもスクリプト全体は
# 中断しない（ログにWARNを残すのみ＝fail-open）。
LATEST_LINK="$MAINTENANCE_LOG_ROOT/latest"
TMP_LATEST_LINK="$MAINTENANCE_LOG_ROOT/.latest.tmp-$$"
if ! ln -s "$RUN_DIR" "$TMP_LATEST_LINK"; then
  warn "latest symlinkの一時リンク作成に失敗しました（続行します）: $TMP_LATEST_LINK"
elif ! python3 -c "import os, sys; os.rename(sys.argv[1], sys.argv[2])" "$TMP_LATEST_LINK" "$LATEST_LINK"; then
  warn "latest symlinkの張替えに失敗しました（続行します）: $LATEST_LINK"
  rm -f "$TMP_LATEST_LINK" 2>/dev/null || true
fi

# --sinceに渡す日付の算出（fragments_log.py --sinceは日付部分のみ解釈する契約）。
# 候補は [fragments_reviewed_at, last_success_at] の順（昇格の締めCLI＝
# scripts/fragments-reviewed.sh が書くfragments_reviewed_atを優先する＝
# 「対応したら消える」を実現するため。設計書§2.2）。どちらも無い/形式不正/
# 未来日時/30日超過はいずれも7日前へfail-openでフォールバックする
# （fragments_log.py自身のresolve_since()と同じ閾値）。候補値の検証ロジックは
# 1か所にまとめ、候補ごとに複製しない。
REVIEWED_AT="$(read_last_run_field fragments_reviewed_at)"
PREV_SUCCESS_AT="$(read_last_run_field last_success_at)"
SINCE_RESULT="$(python3 -c "
import datetime, re, sys

def validate(raw, today):
    # last_success_at/fragments_reviewed_atはUTC（date -u）で保存されるため、
    # 今日の日付判定もUTC基準に揃える（ローカル日付（datetime.date.today()）
    # のままだと、UTCとローカルTZの日付が食い違う時間帯（例: 週次実行予定の
    # JST 06:00はUTCでは前日）で未来日判定・30日境界が1日ずれうるため）。
    raw = (raw or '').strip()
    if not raw:
        return None
    # write_last_run_field()が書く形式（date -u +%Y-%m-%dT%H:%M:%SZ）に加え、
    # 日付のみの形式も許容するが、末尾に無関係な文字列が付いた壊れた値
    # （例: '2026-07-16broken'）は正規表現で構造ごと弾く（先頭10文字を
    # 切り出すだけだとraw[:10]がたまたま有効な日付形式に見えれば通過して
    # しまうため）。
    m = re.match(r'^(\d{4}-\d{2}-\d{2})(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2}))?\$', raw)
    if not m:
        return None
    try:
        if m.group(2):
            # 時刻部分を含む場合は文字列全体を厳密に解析する（日付部分
            # （m.group(1)）だけをfromisoformat()に渡すと、
            # '2026-07-16T99:99:99Z'のような不正な時刻値でも正規表現の
            # 桁数チェックさえ満たせば日付部分は正常に解析され、時刻の
            # 妥当性が一切検証されないまま通過してしまうため）。
            parsed = datetime.datetime.fromisoformat(raw.replace('Z', '+00:00')).date()
        else:
            parsed = datetime.date.fromisoformat(m.group(1))
    except ValueError:
        return None
    if parsed > today or (today - parsed).days > 30:
        return None
    return parsed

today = datetime.datetime.now(datetime.timezone.utc).date()
fallback = (today - datetime.timedelta(days=7)).isoformat()
chosen_raw, chosen_date = '', None
for raw in sys.argv[1:]:
    parsed = validate(raw, today)
    if parsed is not None:
        chosen_raw, chosen_date = raw, parsed.isoformat()
        break
if chosen_date is None:
    chosen_date = fallback
print(chosen_date + '\t' + chosen_raw)
" "$REVIEWED_AT" "$PREV_SUCCESS_AT")"
IFS=$'\t' read -r SINCE_DATE SINCE_SOURCE <<< "$SINCE_RESULT"
log "起点: ${SINCE_SOURCE:-なし（初回相当）} / --since に使う日付: $SINCE_DATE"

# =============================================================================
# Phase 0: Vault書込ロック取得＋直前スナップショット＋export-public-vault再試行
# =============================================================================

log "=== Phase 0: ロック＋バックアップ ==="

# --- Vault書込ロック取得（Phase0開始時〜Phase3終了まで保持・PID方式） ---
# 設計書「Phase0開始時に取得しPhase3終了まで保持」を文字どおり最初に行う
# （Phase0の直前スナップショット＝backup-vault.sh呼び出しの後にロック取得
# すると、2つのmaintenance.shが重複起動した場合、どちらも「自分自身の
# 呼び出し」としてMAINTENANCE_INTERNAL_CALLバイパスでbackup-vault.shの
# busyチェックを素通りしてしまい、ロックによる相互排他が機能しない窓が
# できるため）。acquire_pid_lockはbusy/error
# 時にプロセスごとexitする契約（scripts/lib/pid-lock.sh参照）。取得できれば
# EXIT trapで自動解放されるため、以降のどのexit経路でも明示的な解放処理は
# 不要。
#
# acquire_pid_lockはbusy(exit 0)だけでなく、回収ミューテックス競合が20回
# 試行しても解消しない場合はfail-closedでexit 1する契約（前回実行の
# クラッシュ痕跡の可能性・scripts/lib/pid-lock.sh参照）。この経路は
# maintenance.sh側のadd_anomaly/write_last_resultを一切経由せず直接
# プロセスごとexitするため、素通しだと前回のlast_result（success/warn）が
# 誤って残ったまま翌セッションのヘルス行に出てしまう。acquire_pid_lock自体はライブラリ関数
# として busy/error を呼び出し元へ判別可能な形で返さない（バックアップ
# 対象がbackup-vault.shとも共用する汎用ロックのため、maintenance.sh固有の
# last_result概念をpid-lock.sh側へ持ち込みたくない＝関心の分離）ため、
# ここだけ限定的なEXIT trapで「acquire_pid_lock呼び出し中に非ゼロ終了した
# か」を$?で判定して拾う。acquire_pid_lockが成功するとロック解放用の
# 自分自身のtrapを合成登録する（_pid_lock_register_cleanup参照）ため、
# ここで`trap - EXIT`のように無条件でtrapを消すとロック解放処理ごと
# 消してしまう。そのためtrap文字列自体は残したまま、フラグ
# （MAINTENANCE_LOCK_ACQUIRE_GUARD_ACTIVE）で「今チェックすべき区間か」だけ
# を切り替える（成功/busyで区間を抜けた後はフラグ0でこの関数は何もしない
# no-opになるだけで、合成後のtrap文字列自体はそのまま有効であり続ける）。
#
# 2026-09-20 health-self-explain（設計 v1.2 §3.3 (c)(f)・V-1）: 区間内で EXIT したら
# rc に関わらず、acquire_pid_lock が第 4 引数 status_file へ書いた結果語を読んで
# 終わり方を分ける（busy の exit 0 は maintenance.sh 側に戻らないため、ここが
# 「開始したが仕事をしていない」を記録できる唯一の場所）:
#   status_file == busy            → run.status=skipped(busy:lock)（通知なし・completed は書かない）
#   status_file == error ∨ rc ≠ 0  → completed に phase0-lock fail 1 件（現行の通知も維持）
#   それ以外（status 無し ∧ rc == 0）→ 起こらないはず（成功時は区間を抜けてからしか exit
#                                     しない）。起きたら phase0-lock fail「ロック状態が不明」
#                                     として記録する（静かに通さない）。
_maintenance_lock_acquire_guard() {
  local rc=$?
  [[ "${MAINTENANCE_LOCK_ACQUIRE_GUARD_ACTIVE:-0}" = "1" ]] || return 0
  local lock_word
  lock_word="$(read_status_file "$MAINTENANCE_LOCK_STATUS_FILE" 2>/dev/null)" || lock_word="missing"
  if [[ "$lock_word" == "busy" ]]; then
    log "Vault書込ロックがbusyのため、今回の週次実行を穏当にskipします（run.status=skipped・busy:lock）"
    write_run_status skipped busy:lock
  elif [[ "$lock_word" == "error" || "$rc" -ne 0 ]]; then
    add_anomaly phase0-lock fail "Phase0: Vault書込ロックの取得に失敗しました（回収ミューテックス競合が解消しませんでした・status=${lock_word}・rc=${rc}。詳細: ${VAULT_WRITER_LOCK_FILE}.reclaim）"
    write_last_result "fail" "Vault書込ロックの取得に失敗しました（回収ミューテックス競合が解消しませんでした。詳細: ${VAULT_WRITER_LOCK_FILE}.reclaim）"
    write_completed_record
    notify_macos "maintenance.sh 異常終了" "Vault書込ロックの取得に失敗したため中断しました。手動確認: rmdir ${VAULT_WRITER_LOCK_FILE}.reclaim"
  else
    add_anomaly phase0-lock fail "Phase0: Vault書込ロックの取得区間で終了しましたがロック状態が不明です（status_file=${MAINTENANCE_LOCK_STATUS_FILE} が読めない・rc=${rc}）"
    write_last_result "fail" "Vault書込ロックの取得区間で終了しましたがロック状態が不明です（${MAINTENANCE_LOCK_STATUS_FILE}）"
    write_completed_record
    notify_macos "maintenance.sh 異常終了" "Vault書込ロックの取得区間で終了しましたがロック状態が不明です。詳細: $RUN_DIR"
  fi
}
MAINTENANCE_LOCK_ACQUIRE_GUARD_ACTIVE=1
trap _maintenance_lock_acquire_guard EXIT
acquire_pid_lock "$VAULT_WRITER_LOCK_FILE" "$MAINTENANCE_STALE_LOCK_SECONDS" "maintenance" "$MAINTENANCE_LOCK_STATUS_FILE"
# ここへ到達するのはロック取得成功時のみ（busy/errorはacquire_pid_lock内で
# 既にプロセスごとexit済み＝guardが run／completed を書いている）。以後の通常の
# exit経路でこのguardが誤発火しないよう区間を抜ける。
MAINTENANCE_LOCK_ACQUIRE_GUARD_ACTIVE=0

# backup-vault.shへ渡す「このロックを保持しているのは自分自身だ」という
# 証明。単なる真偽値フラグ(旧MAINTENANCE_INTERNAL_CALL=1)だと、
# launchctl setenv等でこの環境変数がアンビエントに漏れ残っていた場合に
# 毎時LaunchAgent側のbackup-vault.shまで誤ってbypassしてしまうため。
# ロックファイルに実際に書かれた
# PIDと一致する場合のみbypassする設計にすることで、「本当にこのロックを
# 取得したプロセス自身からの呼び出しか」をbackup-vault.js側で検証できる
# ようにする。
MAINTENANCE_LOCK_OWNER_PID="$$"

# --- 直前スナップショット（backup-vault.sh） ---
BACKUP0_STATUS_FILE="$RUN_DIR/step-status-backup0.json"
run_wrapped_step "$TIMEOUT_BACKUP_VAULT" "$BACKUP0_STATUS_FILE" \
  "$RUN_DIR/backup0-stdout.log" "$RUN_DIR/backup0-stderr.log" \
  env MAINTENANCE_LOCK_OWNER_PID="$MAINTENANCE_LOCK_OWNER_PID" VAULT="$VAULT" VAULT_WRITER_LOCK_FILE="$VAULT_WRITER_LOCK_FILE" \
  bash "$SCRIPT_DIR/backup-vault.sh" --status-file "$RUN_DIR/backup0-status.txt"
BACKUP0_RESULT="$(parse_step_status "$BACKUP0_STATUS_FILE")"
BACKUP0_STATUS_WORD="$(read_status_file "$RUN_DIR/backup0-status.txt" 2>/dev/null || echo missing)"
log "Phase0直前スナップショット: $BACKUP0_RESULT (status-file=$BACKUP0_STATUS_WORD)"

# busy/completed/no-change/error/missingを個別に判定する（"error"/"missing"
# だけを弾くと"busy"が素通りしてPhase1以降へ進んでしまうため。設計書は
# 「busyなら今回の週次実行を穏当にskip」と明記している）。
# 終わり方 (b)＝Phase0 直前スナップショットの失敗・異常終了（completed に phase0-backup fail 1 件）。
if [[ "$BACKUP0_RESULT" != "OK 0" ]]; then
  add_anomaly phase0-backup fail "Phase0: 直前スナップショット(backup-vault.sh)の起動自体に失敗しました（${BACKUP0_RESULT}）" "$RUN_DIR/backup0-stderr.log"
  write_last_result "fail" "Phase0: 直前スナップショット(backup-vault.sh)の起動自体に失敗しました（${BACKUP0_RESULT}）"
  write_completed_record
  notify_macos "maintenance.sh 異常終了" "Phase0のバックアップ起動に失敗したため中断しました。詳細: $RUN_DIR"
  exit 1
fi
case "$BACKUP0_STATUS_WORD" in
  completed|no-change)
    : # 正常系。続行する。
    ;;
  busy)
    # 他プロセス（毎時LaunchAgentのbackup-vault.sh等）と競合した場合の
    # 穏当なskip。異常ではないため通知しない（設計書「busyなら今回の週次
    # 実行を穏当にskip」）。終わり方 (e)＝run.status=skipped(busy:backup0) を書く
    # （「開始したが当該予定の仕事をしていない」を中断と区別する。定期起動なら
    # 読み手が未起動 1 件として数える＝要件 T-14）。completed は前回のまま。
    log "Phase0直前スナップショットがbusyのため、今回の週次実行を穏当にskipします"
    write_run_status skipped busy:backup0
    exit 0
    ;;
  *)
    add_anomaly phase0-backup fail "Phase0: 直前スナップショット(backup-vault.sh)が異常終了しました（status=${BACKUP0_STATUS_WORD}）" "$RUN_DIR/backup0-stderr.log"
    write_last_result "fail" "Phase0: 直前スナップショット(backup-vault.sh)が異常終了しました（status=${BACKUP0_STATUS_WORD}）"
    write_completed_record
    notify_macos "maintenance.sh 異常終了" "Phase0のバックアップに失敗したため中断しました。詳細: $RUN_DIR"
    exit 1
    ;;
esac

# --- vault-public/Preferences差分（check-drift④相当）が残っていれば
#     export-public-vault.shを即再試行する ---
# ai-env repoがdirty（無関係な未commit変更がある）ならbusyスキップし、
# 無関係な変更を巻き込まない（設計書§1.2改訂v2）。Phase0からのみ呼ぶ
# （リーダーの通常編集由来のvault-public/Preferences差分対策）。旧・Phase3
# 呼び出し（Preferences昇格があった夜の再実行）は2026-07-17改定でPreferences
# が夜間にVaultへ直接書かれなくなったため撤去された（関数自体はlabel引数を
# 取る汎用実装のまま残す＝将来また複数箇所から呼ぶ可能性を排除しないため）。
run_export_retry() {
  local label="$1"
  if [[ ! -d "$AIENV_REPO/.git" ]]; then
    log "$label export再試行: AIENV_REPOがgit repoではないためスキップします: $AIENV_REPO"
    return 0
  fi
  if [[ -n "$(git -C "$AIENV_REPO" status --porcelain 2>/dev/null)" ]]; then
    log "$label export再試行: ai-env repoがdirtyのためスキップします（無関係な変更を巻き込まないため）"
    return 0
  fi
  local status_file="$RUN_DIR/step-status-export-$(echo "$label" | tr -c 'A-Za-z0-9' '-').json"
  run_wrapped_step "$TIMEOUT_EXPORT_PUBLIC_VAULT" "$status_file" \
    "$RUN_DIR/export-${label}-stdout.log" "$RUN_DIR/export-${label}-stderr.log" \
    env VAULT="$VAULT" AIENV_REPO="$AIENV_REPO" \
    bash "$SCRIPT_DIR/export-public-vault.sh"
  local export_result remaining_diff
  export_result="$(parse_step_status "$status_file")"
  remaining_diff="$(git -C "$AIENV_REPO" status --porcelain -- vault-public 2>/dev/null || true)"
  if [[ "$export_result" == "OK 0" && -z "$remaining_diff" ]]; then
    log "$label export再試行: 成功（${export_result}・vault-public差分解消）"
  else
    # 失敗しても異常通知に含めるのみでPhase1以降は止めない（旧設計書§1.2
    # 改訂v2は「Phase 1 の fail-fast 判定から④を除外」と表現していたが、
    # 2026-08-10にPhase1①自体のfail-fastを廃止した現在は「④はエラー隔離の
    # 対象＝失敗を検知しても中断せず警告として記録し先へ進む」という、より
    # 単純な一般則の一部として扱われている。ここでもその趣旨を徹底する）。
    add_anomaly phase0-export fail "$label: export-public-vault.sh再試行に失敗しました（${export_result}・残差分=$([[ -n "$remaining_diff" ]] && echo あり || echo なし)）" "$RUN_DIR/export-${label}-stderr.log"
  fi
}

run_export_retry "Phase0"

# =============================================================================
# Phase 1: 検出（読み取り専用・実行順固定・エラー隔離）
# =============================================================================

log "=== Phase 1: 検出 ==="

# --- ①check-drift.sh --json（環境ヘルスの点検・警告化） ---
# drift>0・実行異常・timeoutのいずれも警告として記録し②以降へ進む（fail-fastしない
# ＝Decisions/2026-08-10-round6-rulings 決定1。Vault書込み安全の門番はPhase0の
# 直前スナップショットに一本化済み）。
DRIFT_STATUS_FILE="$RUN_DIR/step-status-drift.json"
run_wrapped_step "$TIMEOUT_CHECK_DRIFT" "$DRIFT_STATUS_FILE" \
  "$RUN_DIR/drift-stdout.log" "$RUN_DIR/drift-stderr.log" \
  env VAULT="$VAULT" \
  bash "$SCRIPT_DIR/check-drift.sh" --json
DRIFT_RESULT="$(parse_step_status "$DRIFT_STATUS_FILE")"
log "①check-drift.sh: $DRIFT_RESULT"

if [[ "$DRIFT_RESULT" != "OK 0" ]]; then
  # rc=1(drift>0)・rc>=2(実行エラー)・WRAPPER_FAIL(timeout等)のいずれも警告として
  # 記録するだけで②以降は継続する。
  DRIFT_JSON_LINE="$(tail -n 1 "$RUN_DIR/drift-stdout.log" 2>/dev/null || true)"
  # 結果種別（設計 §3.3 表）: rc=1＝drift 検知＝仕事は完了＝warn（主体は本人）／
  # rc≥2・WRAPPER_FAIL（実行異常・timeout）＝fail（主体は AI）。
  DRIFT_STEP_RESULT="fail"
  [[ "$DRIFT_RESULT" == "OK 1" ]] && DRIFT_STEP_RESULT="warn"
  # health-self-explain 検証 A-6: check-drift.sh --json の契約は最終行が件数
  # JSON（§1.2・L140〜146 相当）だが、rc≥2・WRAPPER_FAIL（実行異常・timeout）の
  # ときは JSON を出す前に終わっていることがあり、その最終行は人間向けの見出し
  # 行（NFR-4＝材料は件数 JSON か見出し行に限る・中身は変えない）。ラベルは
  # 中身（`{` で始まるか）で書き分け、JSON でないものを「JSON:」と名乗らない。
  DRIFT_LINE_LABEL="stdout 最終行"
  [[ "$DRIFT_JSON_LINE" == \{* ]] && DRIFT_LINE_LABEL="JSON"
  add_anomaly phase1-drift "$DRIFT_STEP_RESULT" "Phase1①: check-drift.shがdrift/実行異常を検知しました（${DRIFT_RESULT}・警告として記録し継続します）。${DRIFT_LINE_LABEL}: $DRIFT_JSON_LINE" "$RUN_DIR/drift-stdout.log"
fi

# --- ①相当: check-drift.sh②(config.toml三分類)の未知キー件数をinformationalとして拾う ---
# 未知キーはdriftには数えない（DRIFT_RESULTが"OK 0"でも起こりうる）ため
# add_anomaly()ではなくadd_info_note()でlast_result_summaryにだけ載せる
# （warnへ昇格させない・本人裁定）。JSONが無い/壊れている場合はfail-openで何もしない
# （その異常はadd_anomaly側で捕捉済み）。
DRIFT_JSON_LAST_LINE="$(tail -n 1 "$RUN_DIR/drift-stdout.log" 2>/dev/null || true)"
if UNKNOWN_CONFIG_KEYS_COUNT="$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
v = d['unknown_config_keys']
if not (isinstance(v, int) and not isinstance(v, bool) and v >= 0):
    raise SystemExit(1)
print(v)
" "$DRIFT_JSON_LAST_LINE" 2>/dev/null)" \
    && [[ "$UNKNOWN_CONFIG_KEYS_COUNT" =~ ^[0-9]+$ ]] \
    && [[ "$UNKNOWN_CONFIG_KEYS_COUNT" -gt 0 ]]; then
  add_info_note "Phase1①: check-drift.sh②がconfig.tomlの未知キーを${UNKNOWN_CONFIG_KEYS_COUNT}件検出しました（テンプレにも既知アプリ管理キー一覧にも無い・driftには数えません。詳細: ${RUN_DIR}）"
fi

# --- ②fragments_log.py --since <起点> --json ---
# fragments_log.py/vault_inventory.pyはVaultパスを$HOME/Data/obsidianに固定
# しており--vault相当のオプションを持たない（本スクリプトは現状追随）。
# 成功時は候補件数（len(fragments)・truncatedは含めない）をlast-run.jsonの
# fragments_candidates／fragments_since（--sinceの日付）へ書く。読み手＝
# cmux-next-model.sh の週次行「候補N件」（AIへは注入しない）。
# 失敗時（rc≠0・timeout・JSON破損・契約違反）は前週の値を残さないよう両キーを削除する。
FRAGMENTS_STATUS_FILE="$RUN_DIR/step-status-fragments.json"
FRAGMENTS_JSON="$RUN_DIR/fragments.json"
run_wrapped_step "$TIMEOUT_FRAGMENTS_LOG" "$FRAGMENTS_STATUS_FILE" \
  "$FRAGMENTS_JSON" "$RUN_DIR/fragments-stderr.log" \
  python3 "$SCRIPT_DIR/vault-agents/fragments_log.py" --since "$SINCE_DATE" --json
FRAGMENTS_RESULT="$(parse_step_status "$FRAGMENTS_STATUS_FILE")"
log "②fragments_log.py: $FRAGMENTS_RESULT"
FRAGMENTS_CANDIDATES=""   # 空＝件数を確定できなかった（サマリ行は「不明」）
if [[ "$FRAGMENTS_RESULT" == "OK 0" ]]; then
  # fragments_log.pyは個々のFragmentsファイルの読取失敗をscan_error_countとして
  # JSONへ返しつつexit 0で終わる契約のため、rcだけでは検知できない。
  # scan_error_count>0はanomaly化してlast_success_atを進めない（翌週再走査）が、
  # 件数自体は書く。JSON破損/契約違反（キー欠落・非負整数でない）は「0件（正常）」へ
  # 丸めずanomaly化し、件数も書かない。
  if FRAGMENTS_SCAN_ERROR_COUNT="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
v = d['scan_error_count']
if not (isinstance(v, int) and not isinstance(v, bool) and v >= 0):
    raise SystemExit(1)
print(v)
" "$FRAGMENTS_JSON" 2>/dev/null)" && [[ "$FRAGMENTS_SCAN_ERROR_COUNT" =~ ^[0-9]+$ ]]; then
    if FRAGMENTS_CANDIDATES="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
v = d['fragments']
assert isinstance(v, list)
print(len(v))
" "$FRAGMENTS_JSON" 2>/dev/null)" && [[ "$FRAGMENTS_CANDIDATES" =~ ^[0-9]+$ ]] \
        && write_last_run_json fragments_candidates "$FRAGMENTS_CANDIDATES" \
        && write_last_run_json fragments_since "\"$SINCE_DATE\""; then
      log "②昇格候補${FRAGMENTS_CANDIDATES}件（${SINCE_DATE}以降）を last-run.json に記録しました"
    else
      FRAGMENTS_CANDIDATES=""
      write_last_run_json fragments_candidates null || warn "Phase1②: last-run.json の候補キー削除に失敗"
      write_last_run_json fragments_since null || warn "Phase1②: last-run.json の候補キー削除に失敗"
      add_anomaly phase1-fragments fail "Phase1②: 候補件数を last-run.json に書けませんでした" "$FRAGMENTS_JSON"
    fi
    if [[ "$FRAGMENTS_SCAN_ERROR_COUNT" -gt 0 ]]; then
      # 子の失敗を実行体が警告として継続し完走する 09-14 型（要件 S-17）。実行体が
      # 継続することは結果種別を変えない＝子の処理の結果が失敗を含む＝fail（V-4・W-1）。
      add_anomaly phase1-fragments fail "Phase1②: fragments_log.pyが読み取れなかったFragmentsファイルが${FRAGMENTS_SCAN_ERROR_COUNT}件あります（scan_error_count>0・候補件数は記録しつつ継続しますが、翌週再走査させるためlast_success_atは進めません）" "$FRAGMENTS_JSON"
    fi
  else
    write_last_run_json fragments_candidates null || warn "Phase1②: last-run.json の候補キー削除に失敗"
    write_last_run_json fragments_since null || warn "Phase1②: last-run.json の候補キー削除に失敗"
    add_anomaly phase1-fragments fail "Phase1②: fragments_log.pyのJSON出力からscan_error_countを取得できませんでした（契約違反/JSON破損の疑い・候補件数は記録せず継続します）" "$FRAGMENTS_JSON"
  fi
else
  write_last_run_json fragments_candidates null || warn "Phase1②: last-run.json の候補キー削除に失敗"
  write_last_run_json fragments_since null || warn "Phase1②: last-run.json の候補キー削除に失敗"
  add_anomaly phase1-fragments fail "Phase1②: fragments_log.pyが失敗/timeoutしました（${FRAGMENTS_RESULT}・継続します）" "$RUN_DIR/fragments-stderr.log"
fi

# --- ③vault_inventory.py --json ---
# 棚卸し検出（latest.jsonとmdレポートを書く）。失敗/timeoutはanomaly化する。
INVENTORY_STATUS_FILE="$RUN_DIR/step-status-inventory.json"
INVENTORY_JSON="$RUN_DIR/inventory.json"
run_wrapped_step "$TIMEOUT_VAULT_INVENTORY" "$INVENTORY_STATUS_FILE" \
  "$INVENTORY_JSON" "$RUN_DIR/inventory-stderr.log" \
  python3 "$SCRIPT_DIR/vault-agents/vault_inventory.py" --json
INVENTORY_RESULT="$(parse_step_status "$INVENTORY_STATUS_FILE")"
log "③vault_inventory.py: $INVENTORY_RESULT"
if [[ "$INVENTORY_RESULT" != "OK 0" ]]; then
  add_anomaly phase1-inventory fail "Phase1③: vault_inventory.pyが失敗/timeoutしました（${INVENTORY_RESULT}・継続します）" "$RUN_DIR/inventory-stderr.log"
fi

# =============================================================================
# Phase 3: サマリ・last-run.json更新・最終commit・通知・保持整理
# =============================================================================

log "=== Phase 3: サマリ・通知 ==="

# --- 宣言記録の掃除（cmux-session-todo・FR-47・設計書§16・v1.6でprune rc
#     3値→4値に追随）---
# 呼ぶ位置はPhase3冒頭・実施サマリ1行の組み立てより前（設計書§16.1）。
# ①Phase3は既に「保持整理」（30日超過の実行ディレクトリ削除）を担っており
# 宣言記録の掃除は同じ性質 ②結果をサマリ行に載せられる ③掃除はVaultへ
# 1バイトも書かないため、Phase0のVault書込ロックともPhase3後半の
# backup-vault.shとも干渉しない。
# 新しいエラー隔離の仕組みは作らず、既存のrun_wrapped_step（timeout付き
# 起動＋status-file）にそのまま載せる（設計書§16.2）。
TASK_PRUNE_CMD="${MAINTENANCE_TASK_PRUNE_CMD:-$HOME/work/takumi009-ai-env/cmux/cmux-task-declare.sh}"
TASK_PRUNE_SEGMENT=""            # 実施サマリへ足す1セグメント
if [[ ! -x "$TASK_PRUNE_CMD" ]]; then
  # 掃除の入口そのものが存在しない（段②でai-env側だけ先に入った期間・
  # dotfiles未導入の別マシン＝F-23）。記録も他工程も無傷のまま
  # 「未導入」とだけ記録して次へ進む（FR-47④）。
  TASK_PRUNE_SEGMENT="・宣言掃除 未導入"
  add_info_note "Phase3: 宣言記録の掃除は未実施です（掃除の入口が見つかりません: ${TASK_PRUNE_CMD}）"
else
  TASK_PRUNE_STATUS_FILE="$RUN_DIR/step-status-task-prune.json"
  TASK_PRUNE_OUT="$RUN_DIR/task-prune.out"
  run_wrapped_step "$TIMEOUT_TASK_PRUNE" "$TASK_PRUNE_STATUS_FILE" \
    "$TASK_PRUNE_OUT" "$RUN_DIR/task-prune-stderr.log" \
    bash "$TASK_PRUNE_CMD" prune
  TASK_PRUNE_RESULT="$(parse_step_status "$TASK_PRUNE_STATUS_FILE")"
  log "Phase3 宣言掃除: $TASK_PRUNE_RESULT"
  # ステップ結果の生文字列（"OK 1"等）はサマリに出さない。"OK"は人には成功に
  # 見えるので失敗を成功に見せてしまう（設計書§16.3）。人が読む語へ写像する。
  case "$TASK_PRUNE_RESULT" in
    "OK 0")
      # 消した対はcmux-task-declare.sh側の契約どおり<UUID><TAB><slug>の行
      # のみをstdoutへ出す（設計書§3.3）。空行は数えない（grep -c .）。
      # サマリ行には件数のみを載せる（UUID一覧は${TASK_PRUNE_OUT}に残る＝
      # サマリ末尾の「（詳細: ${RUN_DIR}）」が場所を示す・D-1）。
      N_PRUNED="$(grep -c . "$TASK_PRUNE_OUT" 2>/dev/null || echo 0)"
      [[ "$N_PRUNED" =~ ^[0-9]+$ ]] || N_PRUNED=0
      TASK_PRUNE_SEGMENT="・宣言掃除 実施・${N_PRUNED}件"
      ;;
    "OK 1") TASK_PRUNE_REASON="接続不可" ;;      # cmuxに繋がらない＝F-22
    "OK 2") TASK_PRUNE_REASON="宣言記録破損" ;;  # §3.1の破損判定に当たる
    *)      TASK_PRUNE_REASON="内部エラー" ;;    # OK 3（取得後の書込等に失敗）・
                                                  # その他のrc・WRAPPER_FAIL
                                                  # （timeout＝F-24を含む）
  esac
  if [[ "$TASK_PRUNE_RESULT" != "OK 0" ]]; then
    # rc=1/2/3・WRAPPER_FAILのいずれも、掃除の失敗はadd_info_noteに積む。
    # add_anomalyは使わない＝last_success_atはPhase1②の--since算出の起点なので、
    # 毎週の掃除失敗が毎週の再走査を引き起こす二次被害が出る。月曜06:00にcmuxが
    # 起動していないのは普通に起こる状態で、異常扱いにすると警告が常態化する。
    # 掃除が失敗しても記録は元のまま（run_wrapped_stepの隔離＋prune側の
    # 「取得に失敗したら1件も消さない」契約）。
    TASK_PRUNE_SEGMENT="・宣言掃除 未実施（${TASK_PRUNE_REASON}）"
    add_info_note "Phase3: 宣言記録の掃除は未実施です（${TASK_PRUNE_REASON}・記録は変更していません。ステップ結果=${TASK_PRUNE_RESULT}・詳細: ${RUN_DIR}）"
  fi
fi

# --- Fragments当日ファイルへ実施サマリを1行追記 ---
# 週次メンテの監査はこのサマリ行＋git履歴で担保する。失敗時はanomaly化する。
append_fragments_summary() {
  local line="$1"
  local month_dir="$VAULT/Fragments/$(date +%Y-%m)"
  local day_file="$month_dir/$(date +%Y-%m-%d).md"
  mkdir -p "$month_dir" || return 1
  local tmp
  tmp="$(mktemp "${month_dir}/.$(basename "$day_file").aienv-tmp.XXXXXX")" || return 1
  if [[ -f "$day_file" ]]; then
    cp "$day_file" "$tmp" || { rm -f "$tmp"; return 1; }
  else
    {
      echo "---"
      echo "date: $(date +%Y-%m-%d)"
      echo "tags: [fragments, daily]"
      echo "project: external-brain"
      echo "---"
      echo
      echo "# Fragments $(date +%Y-%m-%d)"
      echo
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf -- '- %s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$day_file"
}

# 昇格候補の件数（Phase1②）。昇格そのものは在席時にvault-scribeが行う（無人では
# 動かない）ため、サマリ行は件数と窓（起点以降）だけを残す。
if [[ -n "$FRAGMENTS_CANDIDATES" ]]; then
  CANDIDATES_SEGMENT="昇格候補${FRAGMENTS_CANDIDATES}件（起点 ${SINCE_DATE} 以降・Dock の Project 枠参照）"
else
  CANDIDATES_SEGMENT="昇格候補 不明（fragments_log 失敗）"
fi
SUMMARY_LINE="定常メンテ(週次): ${CANDIDATES_SEGMENT}${TASK_PRUNE_SEGMENT}（詳細: ${RUN_DIR}）"
if append_fragments_summary "$SUMMARY_LINE"; then
  log "Fragmentsサマリ追記: $SUMMARY_LINE"
else
  add_anomaly phase3-summary fail "Phase3: Fragmentsサマリの追記に失敗しました"
fi

# --- backup-vault.shを再度呼び即commit（Fragmentsサマリを捕捉） ---
BACKUP3_STATUS_FILE="$RUN_DIR/step-status-backup3.json"
run_wrapped_step "$TIMEOUT_BACKUP_VAULT" "$BACKUP3_STATUS_FILE" \
  "$RUN_DIR/backup3-stdout.log" "$RUN_DIR/backup3-stderr.log" \
  env MAINTENANCE_LOCK_OWNER_PID="$MAINTENANCE_LOCK_OWNER_PID" VAULT="$VAULT" VAULT_WRITER_LOCK_FILE="$VAULT_WRITER_LOCK_FILE" \
  bash "$SCRIPT_DIR/backup-vault.sh" --status-file "$RUN_DIR/backup3-status.txt"
BACKUP3_RESULT="$(parse_step_status "$BACKUP3_STATUS_FILE")"
BACKUP3_STATUS_WORD="$(read_status_file "$RUN_DIR/backup3-status.txt" 2>/dev/null || echo missing)"
log "Phase3最終commit: $BACKUP3_RESULT (status-file=$BACKUP3_STATUS_WORD)"
case "$BACKUP3_STATUS_WORD" in
  completed|no-change)
    if [[ "$BACKUP3_RESULT" != "OK 0" ]]; then
      add_anomaly phase3-backup fail "Phase3: 最終commit(backup-vault.sh)の起動自体に失敗しました（${BACKUP3_RESULT}）" "$RUN_DIR/backup3-stderr.log"
    fi
    ;;
  *)
    # busyもここではanomaly扱いにする（Phase3はVault書込ロックを自分自身が保持した
    # まま呼ぶため、bypassが正しく機能していればbusyにはならない＝busyはバイパスの
    # 不整合を示す異常）。Fragmentsサマリが未commitのまま残りうるので
    # last_success_atは更新しない。
    add_anomaly phase3-backup fail "Phase3: 最終commit(backup-vault.sh)が異常終了しました（${BACKUP3_RESULT}・status=${BACKUP3_STATUS_WORD}）" "$RUN_DIR/backup3-stderr.log"
    ;;
esac

# --- last-run.jsonのlast_success_atは完全正常終了時のみ更新 ---
# Phase3の最終commitまで含めた全ステップが終わった後、最後に判定する
# （Fragmentsサマリ追記の直後＝最終commitより前に判定すると、最終commit
# 自体が失敗してもlast_success_atだけが先に進んでしまうため）。
if [[ "$RUN_FULLY_OK" -eq 1 ]]; then
  if write_last_run_field last_success_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
    log "last_success_at を更新しました"
  else
    # ここまで来て最後の書込みだけが失敗した場合、次回実行時の--since算出が
    # 古いままの値を使うことになり実害は小さい（fail-open）が、書込失敗
    # 自体は運用上気付けるようにanomaly化する。スクリプト自体はここでは中断しない（Phase3の最後の
    # ステップであり、これ以上ロールバックすべき後続処理も無いため）。
    add_anomaly phase3-record fail "Phase3: last-run.jsonのlast_success_at更新に失敗しました"
  fi
else
  log "今回は完全正常終了ではないため last_success_at は更新しません（次回も同じ--sinceから再試行）"
fi

# --- last-run.jsonのlast_result（success/warn）を記録（旧D4・[[Decisions/
#     2026-08-10-round6-rulings]]決定1のセット条件） ---
# ここまで到達できた時点でPhase3の最終commitまで含めて完走しているため
# "fail"にはならない（"fail"はPhase0の直前スナップショット失敗時に
# write_last_result経由で個別に書く＝本ファイル上部参照。ここは「完走した
# 週次実行」の中でのsuccess/warnのみを扱う）。RUN_FULLY_OKは上のブロックで
# last_success_at書込み自体が失敗した場合も0へ倒りうるため、判定はこの
# ブロックの後で行う。
LAST_RESULT_VALUE="success"
if [[ "$RUN_FULLY_OK" -ne 1 ]]; then
  LAST_RESULT_VALUE="warn"
fi
# ANOMALIESとINFO_NOTESを両方summaryへ合流させる（2026-08-10 工程横断
# レビュー2周目指摘Major対応: 従来はif/elifで分岐しており、warn（ANOMALIES
# 非空）とinformational（INFO_NOTES非空）が同じ週次実行内で同時に起きると
# INFO_NOTES側が丸ごと捨てられ、未知config.tomlキーの可視化導線がこの
# ケースだけ再び失われていた）。ANOMALIESを先に置く＝last_result=warnを
# 招いた本質的な原因（異常）の方がinformationalな注記より優先度が高く、
# 200文字切り詰めで後半が落ちるとしても先に見えるべきなのはこちら。
# successのみ（ANOMALIES空）ならINFO_NOTESだけがそのまま入る。
# 展開は`${ARRAY[@]+"${ARRAY[@]}"}`のbash 3.2安全イディオムを使う（macOS
# 標準bash 3.2は空配列に対する`"${ARRAY[@]}"`をset -u下でunbound variable
# エラーにする既知の欠陥があり、素朴な`"${ANOMALIES[@]}"`はANOMALIESが
# 空＝success時に本行自体をクラッシュさせる＝実測発見・全テストで検出）。
SUMMARY_PARTS=(${ANOMALIES[@]+"${ANOMALIES[@]}"} ${INFO_NOTES[@]+"${INFO_NOTES[@]}"})
# ANOMALIES/INFO_NOTESを"; "区切りで1行に要約する。起動ヘルス行に載せる短文
# のため200文字で切り詰める（マルチバイト文字境界は気にしない＝個人用
# ツールの表示用途として許容。中身の全量はRUN_DIR配下のログで確認可能。
# macOS通知は「本人は見ていない」前提（Phase3「異常時のみmacOS通知」
# コメント参照）のため全量回収先としては挙げない＝2026-08-10 工程横断
# レビュー指摘Minor対応: 通知本文には未切詰めの全量が乗るが、それを読む
# 前提の説明は本人が通知を見ない運用と矛盾するため訂正）。
#
# SUMMARY_PARTSが空（完全正常終了・informationalな注記も無い）の場合は
# printfを呼ばない（printfは実引数0件でもフォーマット文字列を1回実行する
# POSIX仕様のため、`printf '%s; ' ${SUMMARY_PARTS[@]+"${SUMMARY_PARTS[@]}"}`
# のように実引数を渡さない形で呼んでも"; "だけが出力されてしまい、
# last_result_summaryが真の空文字列にならない＝実測発見）。
LAST_RESULT_SUMMARY=""
if [[ "${#SUMMARY_PARTS[@]}" -gt 0 ]]; then
  LAST_RESULT_SUMMARY="$(printf '%s; ' "${SUMMARY_PARTS[@]}")"
  LAST_RESULT_SUMMARY="${LAST_RESULT_SUMMARY:0:200}"
fi
write_last_result "$LAST_RESULT_VALUE" "$LAST_RESULT_SUMMARY"

# --- 終わり方 (a)＝完走: completed（異常工程ごとの steps・info）・run の書き戻し・
#     success_streak・ack の失効を 1 回の原子更新で書く（設計 v1.2 §3.3） ---
write_completed_record

# --- 異常時のみmacOS通知（正常時は通知しない＝本人「通知は見ていない」指摘） ---
if [[ "${#ANOMALIES[@]}" -gt 0 ]]; then
  SUMMARY_FOR_NOTIFY="$(printf '%s; ' "${ANOMALIES[@]}")"
  notify_macos "maintenance.sh 異常あり" "${SUMMARY_FOR_NOTIFY}詳細: $RUN_DIR"
fi

# --- 30日超過の実行ディレクトリを削除（日付ディレクトリのmtime判定） ---
find "$MAINTENANCE_LOG_ROOT" -maxdepth 1 -type d -name '20*' -mtime "+${MAINTENANCE_RETENTION_DAYS}" -print0 2>/dev/null \
  | while IFS= read -r -d '' old_dir; do
      log "保持期限(${MAINTENANCE_RETENTION_DAYS}日)超過のため削除: $old_dir"
      rm -rf -- "$old_dir"
    done

log "done."
# 終了コードはPhase3まで到達できたかどうかだけを表す（0=最後まで走った・
# Phase1①〜③やexport再試行の「隔離して継続した」異常があっても0のまま。
# 1=Phase0の直前スナップショット(backup-vault.sh)の起動失敗/異常終了のみ）。
# 「何か異常があったか」は終了コードではなくlast_result／macOS通知で判断する。
exit 0
