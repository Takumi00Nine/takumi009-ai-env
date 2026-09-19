#!/usr/bin/env bash
# 週次メンテナンスランナー（LaunchAgent com.takumi009.maintenance・月曜 03:00・無人）。
# Phase0: backup-vault.sh（直前スナップショット）→ Vault 書込ロック → export-public-vault.sh 再試行
# Phase1: ① check-drift.sh --json（drift は警告・止めない）② fragments_log.py --since <last_success_at> --json
#         ③ vault_inventory.py --json（各ステップは maintenance_run_step.py で timeout 隔離・1 本の失敗で止めない）
# Phase3: cmux-task-declare.sh prune → Fragments 当日ファイルへサマリ 1 行 → backup-vault.sh → last-run.json → 異常時のみ macOS 通知 → 30 日整理
# 出力: ~/.claude/logs/maintenance/<日付>/<時刻-pid>/（latest symlink）と last-run.json（契約＝design-step2 §6・読み手＝bootstrap-vault.sh ④・cmux-next-model.sh）
# 環境変数で全パス・timeout を上書き可（テスト用）。経緯＝Decisions/2026-08-10-round6-rulings・2026-09-19-ai-env-optimization-rulings
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
ANOMALIES=()
add_anomaly() { ANOMALIES+=("$1"); warn "$1"; RUN_FULLY_OK=0; }

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
mkdir -p "$DATE_DIR" || {
  echo "[maintenance] FAIL: 日付ディレクトリを作成できません: $DATE_DIR" >&2
  write_last_result "fail" "日付ディレクトリを作成できませんでした（${DATE_DIR}）"
  exit 1
}
# RUN_DIRは`$$`(PID)を含むため通常は衝突しないが、`mkdir -p`は既存ディレクトリを
# 静かに再利用してしまう（PID再利用等の極めて稀な衝突時にログが混在しうる）。
# 単純な`mkdir`（`-p`無し）はディレクトリが既に存在すると失敗するため、これを
# 衝突検知として使う。
if ! mkdir "$RUN_DIR"; then
  echo "[maintenance] FAIL: 実行ディレクトリの作成に失敗しました（既に存在する可能性があります）: $RUN_DIR" >&2
  write_last_result "fail" "実行ディレクトリの作成に失敗しました（${RUN_DIR}）"
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

# --- last-run.json の started_at を無条件で最初に更新（自己ロックアウト対策） ---
# check-drift.sh⑥相当の「定常メンテ自体が動いているか」の死活監視が、
# started_atの経過日数だけで判定できるようにする（設計書§4「レポート未処理
# 検知・ALERT監視を削除、maintenance新鮮度チェック（started_atの経過日数のみで
# 判定）に置換」）。busy/errorで即座に終了する経路でもここまでは必ず到達する。
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! write_last_run_field started_at "$STARTED_AT"; then
  # started_atはcheck-drift.sh⑥相当の死活監視が依拠する自己ロックアウト
  # 対策の要であり、これが書けない環境（ディスク枯渇・権限異常等）では
  # 以降の処理を続けても同種の書込みが軒並み失敗する可能性が高いため、
  # ここだけはfail-fastする（戻り値を見ないと書込失敗が黙って握り潰されたまま
  # 「started_atは記録済み」という前提で処理が進んでしまうため）。
  echo "[maintenance] FAIL: last-run.jsonのstarted_at更新に失敗しました: $LAST_RUN_FILE" >&2
  # last_resultも同じファイルへの書込みのため、started_at同様に失敗しうる
  # （write_last_result自体はfail-openでwarn()するだけ＝二重に中断はしない）。
  # それでも書ける環境（started_atの書込みだけがたまたま失敗した等）では
  # 次回起動時のヘルス行に反映させたい。
  write_last_result "fail" "last-run.jsonのstarted_at更新に失敗しました"
  notify_macos "maintenance.sh 異常終了" "last-run.jsonへの書込みに失敗したため中断しました。詳細: $RUN_DIR"
  exit 1
fi

# --sinceに渡す日付の算出（fragments_log.py --sinceは日付部分のみ解釈する契約）。
# 前回成功実行が無い/形式不正/未来日時/30日超過はいずれも7日前へfail-openで
# フォールバックする（fragments_log.py自身のresolve_since()と同じ閾値）。
PREV_SUCCESS_AT="$(read_last_run_field last_success_at)"
SINCE_DATE="$(python3 -c "
import datetime, re, sys
raw = sys.argv[1].strip()
# last_success_atはUTC（date -u）で保存されるため、今日の日付判定もUTC基準に
# 揃える（ローカル日付（datetime.date.today()）のままだと、UTCとローカルTZの
# 日付が食い違う時間帯（例: 週次実行予定のJST 03:00はUTCでは前日）で未来日
# 判定・30日境界が1日ずれうるため）。
today = datetime.datetime.now(datetime.timezone.utc).date()
fallback = (today - datetime.timedelta(days=7)).isoformat()
parsed = None
if raw:
    # write_last_run_field()が書く形式（date -u +%Y-%m-%dT%H:%M:%SZ）に加え、
    # 日付のみの形式も許容するが、末尾に無関係な文字列が付いた壊れた値
    # （例: '2026-07-16broken'）は正規表現で構造ごと弾く（先頭10文字を
    # 切り出すだけだとraw[:10]がたまたま有効な日付形式に見えれば通過して
    # しまうため）。
    m = re.match(r'^(\d{4}-\d{2}-\d{2})(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2}))?\$', raw)
    if m:
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
            parsed = None
if parsed is None or parsed > today or (today - parsed).days > 30:
    print(fallback)
else:
    print(parsed.isoformat())
" "$PREV_SUCCESS_AT")"
log "前回成功時刻: ${PREV_SUCCESS_AT:-なし（初回相当）} / --since に使う日付: $SINCE_DATE"

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
_maintenance_lock_acquire_guard() {
  local rc=$?
  if [[ "${MAINTENANCE_LOCK_ACQUIRE_GUARD_ACTIVE:-0}" = "1" && "$rc" -ne 0 ]]; then
    write_last_result "fail" "Vault書込ロックの取得に失敗しました（回収ミューテックス競合が解消しませんでした。詳細: ${VAULT_WRITER_LOCK_FILE}.reclaim）"
    notify_macos "maintenance.sh 異常終了" "Vault書込ロックの取得に失敗したため中断しました。手動確認: rmdir ${VAULT_WRITER_LOCK_FILE}.reclaim"
  fi
}
MAINTENANCE_LOCK_ACQUIRE_GUARD_ACTIVE=1
trap _maintenance_lock_acquire_guard EXIT
acquire_pid_lock "$VAULT_WRITER_LOCK_FILE" "$MAINTENANCE_STALE_LOCK_SECONDS" "maintenance" ""
# ここへ到達するのはロック取得成功時のみ（busy/errorはacquire_pid_lock内で
# 既にプロセスごとexit済み）。以後の通常のexit経路（busy-skip等は含まれない
# ＝本ファイル冒頭の「busy-skipはlast_result対象外」方針どおり）でこの
# guardが誤発火しないよう区間を抜ける。
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
if [[ "$BACKUP0_RESULT" != "OK 0" ]]; then
  add_anomaly "Phase0: 直前スナップショット(backup-vault.sh)の起動自体に失敗しました（${BACKUP0_RESULT}）"
  write_last_result "fail" "Phase0: 直前スナップショット(backup-vault.sh)の起動自体に失敗しました（${BACKUP0_RESULT}）"
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
    # 実行を穏当にskip」）。last-run.jsonのstarted_atは既に更新済みなので
    # 死活監視は正しく機能し続ける。
    log "Phase0直前スナップショットがbusyのため、今回の週次実行を穏当にskipします"
    exit 0
    ;;
  *)
    add_anomaly "Phase0: 直前スナップショット(backup-vault.sh)が異常終了しました（status=${BACKUP0_STATUS_WORD}）"
    write_last_result "fail" "Phase0: 直前スナップショット(backup-vault.sh)が異常終了しました（status=${BACKUP0_STATUS_WORD}）"
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
    add_anomaly "$label: export-public-vault.sh再試行に失敗しました（${export_result}・残差分=$([[ -n "$remaining_diff" ]] && echo あり || echo なし)）"
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
  add_anomaly "Phase1①: check-drift.shがdrift/実行異常を検知しました（${DRIFT_RESULT}・警告として記録し継続します）。JSON: $DRIFT_JSON_LINE"
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

# --- ②fragments_log.py --since <前回成功時刻> --json ---
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
      add_anomaly "Phase1②: 候補件数を last-run.json に書けませんでした"
    fi
    if [[ "$FRAGMENTS_SCAN_ERROR_COUNT" -gt 0 ]]; then
      add_anomaly "Phase1②: fragments_log.pyが読み取れなかったFragmentsファイルが${FRAGMENTS_SCAN_ERROR_COUNT}件あります（scan_error_count>0・候補件数は記録しつつ継続しますが、翌週再走査させるためlast_success_atは進めません）"
    fi
  else
    write_last_run_json fragments_candidates null || warn "Phase1②: last-run.json の候補キー削除に失敗"
    write_last_run_json fragments_since null || warn "Phase1②: last-run.json の候補キー削除に失敗"
    add_anomaly "Phase1②: fragments_log.pyのJSON出力からscan_error_countを取得できませんでした（契約違反/JSON破損の疑い・候補件数は記録せず継続します）"
  fi
else
  write_last_run_json fragments_candidates null || warn "Phase1②: last-run.json の候補キー削除に失敗"
  write_last_run_json fragments_since null || warn "Phase1②: last-run.json の候補キー削除に失敗"
  add_anomaly "Phase1②: fragments_log.pyが失敗/timeoutしました（${FRAGMENTS_RESULT}・継続します）"
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
  add_anomaly "Phase1③: vault_inventory.pyが失敗/timeoutしました（${INVENTORY_RESULT}・継続します）"
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
      N_PRUNED="$(grep -c . "$TASK_PRUNE_OUT" 2>/dev/null || echo 0)"
      [[ "$N_PRUNED" =~ ^[0-9]+$ ]] || N_PRUNED=0
      if [[ "$N_PRUNED" -gt 0 ]]; then
        PRUNED_PAIRS="$(tr '\t' '=' < "$TASK_PRUNE_OUT" | tr '\n' ';' | sed 's/;$//')"
        TASK_PRUNE_SEGMENT="・宣言掃除 実施・${N_PRUNED}件（${PRUNED_PAIRS}）"
      else
        TASK_PRUNE_SEGMENT="・宣言掃除 実施・0件"
      fi
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
    # 毎週の掃除失敗が毎週の再走査を引き起こす二次被害が出る。月曜03:00にcmuxが
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
# 動かない）ため、サマリ行は件数と窓（前回成功以降）だけを残す。
if [[ -n "$FRAGMENTS_CANDIDATES" ]]; then
  CANDIDATES_SEGMENT="昇格候補${FRAGMENTS_CANDIDATES}件（前回成功 ${SINCE_DATE} 以降・Dock の Project 枠参照）"
else
  CANDIDATES_SEGMENT="昇格候補 不明（fragments_log 失敗）"
fi
SUMMARY_LINE="定常メンテ(週次): ${CANDIDATES_SEGMENT}${TASK_PRUNE_SEGMENT}（詳細: ${RUN_DIR}）"
if append_fragments_summary "$SUMMARY_LINE"; then
  log "Fragmentsサマリ追記: $SUMMARY_LINE"
else
  add_anomaly "Phase3: Fragmentsサマリの追記に失敗しました"
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
      add_anomaly "Phase3: 最終commit(backup-vault.sh)の起動自体に失敗しました（${BACKUP3_RESULT}）"
    fi
    ;;
  *)
    # busyもここではanomaly扱いにする（Phase3はVault書込ロックを自分自身が保持した
    # まま呼ぶため、bypassが正しく機能していればbusyにはならない＝busyはバイパスの
    # 不整合を示す異常）。Fragmentsサマリが未commitのまま残りうるので
    # last_success_atは更新しない。
    add_anomaly "Phase3: 最終commit(backup-vault.sh)が異常終了しました（${BACKUP3_RESULT}・status=${BACKUP3_STATUS_WORD}）"
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
    add_anomaly "Phase3: last-run.jsonのlast_success_at更新に失敗しました"
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
