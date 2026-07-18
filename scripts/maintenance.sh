#!/usr/bin/env bash
# 週次メンテナンスランナー（設計書§1「maintenance.sh本体設計」・PR2）。
#
# LaunchAgent com.takumi009.maintenance（毎週月曜03:00・RunAtLoad=false）から
# 無人実行される前提。Phase 0（バックアップ＋ロック）→ Phase 1（検出・読取専用）
# → Phase 2（ヘッドレスClaude判断＋Vault適用・maintenance_apply.py）→
# Phase 3（サマリ・通知・保持整理）の順に進む。
#
# Phase 0: 直前スナップショット（backup-vault.sh）＋Vault書込ロック取得
#   （Phase0開始時〜Phase3終了までPID方式で保持。~/.claude/logs/maintenance/
#   vault-writer.lock）＋last-run.jsonのstarted_at無条件更新（自己ロック
#   アウト対策）＋vault-public/Preferences差分（check-drift④相当）が残って
#   いればexport-public-vault.shを即再試行。
# Phase 1: 検出専用（読み取り専用・実行順固定・各ステップは
#   maintenance_run_step.py経由でtimeout付き起動）:
#   ①check-drift.sh --json（環境ヘルスの門番＝④を除いたdrift>0または実行
#     異常/timeoutならfail-fast・Vaultには書かずここで終了）
#   ②fragments_log.py --since <前回成功時刻> --json
#   ③vault_inventory.py --json
#   ④knowledge_merge_candidates.py --json
#   ⑤decision_propagation.py --since <前回成功時刻> --out <レポート>
#   ②〜⑤は1本失敗/timeoutしても他は継続する（エラー隔離）。
# Phase 2: maintenance_apply.py が②③④の検出結果を集約しヘッドレスClaudeへ
#   1回投げ、検証済みの構造化出力に基づきPROMOTE/MERGE/FIXをVaultへ適用する。
# Phase 3: 実施サマリをFragments当日ファイルへ1行追記、last-run.jsonの
#   last_success_atを完全正常終了時のみ更新、backup-vault.shを再度呼び
#   即commit、Vault書込ロック解放（EXIT trap自動）、異常時のみmacOS通知、
#   30日超過の実行ディレクトリを削除。
#
# 中間ファイル・status-fileの置き場（設計書§1.3・リーダー裁定2026-07-16）:
#   ~/.claude/logs/maintenance/<YYYY-MM-DD>/<HHMMSS>-<pid>/ という実行ごと
#   一意のディレクトリを本スクリプトが開始時に作成し、そこへ全部まとめる。
#   加えて ~/.claude/logs/maintenance/latest symlink を開始時に原子的に
#   張り替える（一時名で作ってからrename）。30日保持は日付ディレクトリの
#   mtime判定で自動削除する。
#
# パスはすべて環境変数で上書き可（ユニットテスト用。本番実行時は既定値の
# ままでよい）。
#
# 実行方法: scripts/maintenance.sh

set -uo pipefail  # -e は使わない（Phase1の1項目失敗で残りが止まらないようにする）

# 中間ファイル（ディレクトリ0700・ファイル0600＝設計書§1.3）。ディレクトリ側は
# mkdir後にchmodで個別に強制するが、ファイル側はプロセスのumaskに委ねられて
# いたため、スクリプト冒頭でumaskそのものを絞る（2026-07-16 Codexレビュー
# 指摘Minor対応）。
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
# Vault書込ロックのstale判定秒数。週次実行1回分（検出＋ヘッドレスClaude1回＋
# 適用）が十分収まる余裕を見て既定2時間。前回実行がクラッシュしてロックを
# 片付けられなかった場合の自動解除しきい値（backup-vault.shのSTALE_LOCK_SECONDS
# と同じ考え方）。
: "${MAINTENANCE_STALE_LOCK_SECONDS:=7200}"
: "${MAINTENANCE_RETENTION_DAYS:=30}"

# 各ステップの個別timeout（秒）。設計書§1.2「各ステップ個別timeout」。
: "${TIMEOUT_BACKUP_VAULT:=180}"
: "${TIMEOUT_EXPORT_PUBLIC_VAULT:=180}"
: "${TIMEOUT_CHECK_DRIFT:=120}"
: "${TIMEOUT_FRAGMENTS_LOG:=90}"
: "${TIMEOUT_VAULT_INVENTORY:=180}"
: "${TIMEOUT_KNOWLEDGE_MERGE:=300}"
: "${TIMEOUT_DECISION_PROPAGATION:=120}"
: "${TIMEOUT_MAINTENANCE_APPLY:=420}"
# maintenance_apply.py自身の内部--claude-timeout（上記TIMEOUT_MAINTENANCE_APPLYより
# 短くする＝外側のmaintenance_run_step.pyタイムアウトが内側より先に発火すると
# 内部の状況が分からないまま強制終了されるため、内側を先に切れさせる）。
: "${MAINTENANCE_APPLY_CLAUDE_TIMEOUT:=300}"
: "${MAINTENANCE_APPLY_MAX_MERGE_ACTIONS:=2}"
# ヘッドレスClaudeのモデル・バイナリ（maintenance_apply.py側の既定＝
# MAINTENANCE_APPLY_MODEL/MAINTENANCE_APPLY_CLAUDE_BIN環境変数）をそのまま
# 継承させる。本スクリプト独自のCLI引数は設けない（運用者は環境変数で統一
# して上書きする＝二重の設定経路を作らない）。

log() { echo "[maintenance] $*"; }
warn() { echo "[maintenance] WARN: $*" >&2; }

# 完全正常終了かどうか（last-run.jsonのlast_success_at更新判定に使う）。
# add_anomaly()を1回でも呼べば自動的に0になる（下記参照）。
RUN_FULLY_OK=1

# 異常理由の蓄積（Phase3「異常時のみmacOS通知」用）。呼ぶたびに
# RUN_FULLY_OK も自動的に0へ倒す（2026-07-16 Codexレビュー指摘Major対応:
# 従来は個別の異常系分岐ごとに`RUN_FULLY_OK=0`を書き忘れると
# last_success_atが誤って進んでしまう構造だった。「隔離して継続する異常」
# であっても、fragments_log.py/decision_propagation.pyの--sinceが次回も
# 正しく巻き戻れるよう、1件でも異常があればlast_success_atは進めない
# という保守的な方針に統一する＝設計書「完全正常終了時のみ」を文字どおり
# 満たす）。
ANOMALIES=()
add_anomaly() { ANOMALIES+=("$1"); warn "$1"; RUN_FULLY_OK=0; }

# --- last-run.json 読み書きヘルパ（原子更新・破損時はfail-openで{}扱い） ---
# ファイルパス・フィールド名・値はいずれもPythonコード文字列へ直接埋め込まず
# sys.argv 経由で渡す（2026-07-16 リーダー裁定・scripts/check-drift.shの
# check_maintenance_freshness()で検出された同型欠陥＝Codexレビュー指摘Major
# 「シェル変数のコード直接埋め込みは、値に ' が含まれるだけで構文が壊れ、
# 細工された値では任意コード実行の経路になりうる」の横展開修正。
# $LAST_RUN_FILE は環境変数で上書き可能なため単一ユーザーローカル運用でも
# 防御的に塞ぐ）。
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
mkdir -p "$DATE_DIR" || { echo "[maintenance] FAIL: 日付ディレクトリを作成できません: $DATE_DIR" >&2; exit 1; }
# RUN_DIRは`$$`(PID)を含むため通常は衝突しないが、`mkdir -p`は既存ディレクトリを
# 静かに再利用してしまう（PID再利用等の極めて稀な衝突時にログが混在しうる）。
# 単純な`mkdir`（`-p`無し）はディレクトリが既に存在すると失敗するため、これを
# 衝突検知として使う（2026-07-16 Codexレビュー指摘Minor対応）。
if ! mkdir "$RUN_DIR"; then
  echo "[maintenance] FAIL: 実行ディレクトリの作成に失敗しました（既に存在する可能性があります）: $RUN_DIR" >&2
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
  # ここだけはfail-fastする（2026-07-16 Codex二次レビュー指摘Minor対応:
  # 従来は戻り値を見ておらず、書込失敗が黙って握り潰されたまま
  # 「started_atは記録済み」という前提で処理が進んでいた）。
  echo "[maintenance] FAIL: last-run.jsonのstarted_at更新に失敗しました: $LAST_RUN_FILE" >&2
  notify_macos "maintenance.sh 異常終了" "last-run.jsonへの書込みに失敗したため中断しました。詳細: $RUN_DIR"
  exit 1
fi

# --sinceに渡す日付の算出（fragments_log.py --since / decision_propagation.py
# --sinceはいずれも日付部分のみ解釈する契約＝時刻精度は不要）。前回成功実行が
# 無い/形式不正/未来日時/30日超過はいずれも7日前へfail-openでフォールバック
# する（設計書「初回/破損/未来日時/30日超過は7日にフォールバックしfactログ・
# 中断しない」・fragments_log.py自身のresolve_since()と同じ閾値・同じ考え方
# ＝2026-07-16 Codexレビュー指摘Major対応。従来は先頭10文字を無条件に切り出す
# だけで、未来日時・30日超過の検証が抜けていた）。
PREV_SUCCESS_AT="$(read_last_run_field last_success_at)"
SINCE_DATE="$(python3 -c "
import datetime, re, sys
raw = sys.argv[1].strip()
# last_success_atはUTC（date -u）で保存されるため、今日の日付判定もUTC基準に
# 揃える（2026-07-16 Codex四次レビュー指摘Minor対応: ローカル日付
# （datetime.date.today()）のままだと、UTCとローカルTZの日付が食い違う
# 時間帯（例: 週次実行予定のJST 03:00はUTCでは前日）で未来日判定・30日
# 境界が1日ずれうる）。
today = datetime.datetime.now(datetime.timezone.utc).date()
fallback = (today - datetime.timedelta(days=7)).isoformat()
parsed = None
if raw:
    # write_last_run_field()が書く形式（date -u +%Y-%m-%dT%H:%M:%SZ）に加え、
    # 日付のみの形式も許容するが、末尾に無関係な文字列が付いた壊れた値
    # （例: '2026-07-16broken'）は正規表現で構造ごと弾く（2026-07-16 Codex
    # 二次レビュー指摘Minor対応: 従来は先頭10文字を切り出すだけでraw[:10]が
    # たまたま有効な日付形式に見えれば通過していた）。
    m = re.match(r'^(\d{4}-\d{2}-\d{2})(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2}))?\$', raw)
    if m:
        try:
            if m.group(2):
                # 時刻部分を含む場合は文字列全体を厳密に解析する
                # （2026-07-16 Codex三次レビュー指摘Minor対応: 日付部分
                # （m.group(1)）だけをfromisoformat()に渡していたため、
                # '2026-07-16T99:99:99Z'のような不正な時刻値でも正規表現の
                # 桁数チェックさえ満たせば日付部分は正常に解析され、時刻の
                # 妥当性が一切検証されないまま通過していた）。
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
# （2026-07-16 Codexレビュー指摘Major対応: 従来はPhase0の直前スナップショット
# ＝backup-vault.sh呼び出しの後にロック取得していたため、2つのmaintenance.sh
# が重複起動した場合、どちらも「自分自身の呼び出し」としてMAINTENANCE_
# INTERNAL_CALLバイパスでbackup-vault.shのbusyチェックを素通りしてしまい、
# ロックによる相互排他が機能しない窓があった）。acquire_pid_lockはbusy/error
# 時にプロセスごとexitする契約（scripts/lib/pid-lock.sh参照）。取得できれば
# EXIT trapで自動解放されるため、以降のどのexit経路でも明示的な解放処理は
# 不要。
acquire_pid_lock "$VAULT_WRITER_LOCK_FILE" "$MAINTENANCE_STALE_LOCK_SECONDS" "maintenance" ""

# backup-vault.shへ渡す「このロックを保持しているのは自分自身だ」という
# 証明。単なる真偽値フラグ(旧MAINTENANCE_INTERNAL_CALL=1)だと、
# launchctl setenv等でこの環境変数がアンビエントに漏れ残っていた場合に
# 毎時LaunchAgent側のbackup-vault.shまで誤ってbypassしてしまう
# （2026-07-16 Codexレビュー指摘Major対応）。ロックファイルに実際に書かれた
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

# busy/completed/no-change/error/missingを個別に判定する（2026-07-16 Codex
# レビュー指摘Major対応: 従来は"error"/"missing"だけを弾いており、"busy"が
# 素通りしてPhase1以降へ進んでしまっていた。設計書は「busyなら今回の週次
# 実行を穏当にskip」と明記している）。
if [[ "$BACKUP0_RESULT" != "OK 0" ]]; then
  add_anomaly "Phase0: 直前スナップショット(backup-vault.sh)の起動自体に失敗しました（${BACKUP0_RESULT}）"
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
    notify_macos "maintenance.sh 異常終了" "Phase0のバックアップに失敗したため中断しました。詳細: $RUN_DIR"
    exit 1
    ;;
esac

# --- vault-public/Preferences差分（check-drift④相当）が残っていれば
#     export-public-vault.shを即再試行する ---
# ai-env repoがdirty（無関係な未commit変更がある）ならbusyスキップし、
# 無関係な変更を巻き込まない（設計書§1.2改訂v2）。Phase0・Phase3（Preferences
# 昇格があった夜）の両方から呼べるよう関数化する。
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
    # 失敗しても異常通知に含めるのみでPhase1以降は止めない（設計書§1.2改訂v2
    # 「Phase 1 の fail-fast 判定から④を除外」の趣旨をここでも徹底する）。
    add_anomaly "$label: export-public-vault.sh再試行に失敗しました（${export_result}・残差分=$([[ -n "$remaining_diff" ]] && echo あり || echo なし)）"
  fi
}

run_export_retry "Phase0"

# =============================================================================
# Phase 1: 検出（読み取り専用・実行順固定・エラー隔離）
# =============================================================================

log "=== Phase 1: 検出 ==="

# --- ①check-drift.sh --json（環境ヘルスの門番・fail-fast） ---
DRIFT_STATUS_FILE="$RUN_DIR/step-status-drift.json"
run_wrapped_step "$TIMEOUT_CHECK_DRIFT" "$DRIFT_STATUS_FILE" \
  "$RUN_DIR/drift-stdout.log" "$RUN_DIR/drift-stderr.log" \
  env VAULT="$VAULT" \
  bash "$SCRIPT_DIR/check-drift.sh" --json
DRIFT_RESULT="$(parse_step_status "$DRIFT_STATUS_FILE")"
log "①check-drift.sh: $DRIFT_RESULT"

if [[ "$DRIFT_RESULT" != "OK 0" ]]; then
  # rc=1(④を除いたdrift>0)・rc>=2(実行エラー)・WRAPPER_FAIL(timeout等)の
  # いずれもfail-fast対象（設計書§1.2「④を除いたdrift件数>0または実行異常/
  # timeoutならfail-fast。②以降・Phase2を実行せず異常通知して終了。Vaultには
  # 書かない」）。
  DRIFT_JSON_LINE="$(tail -n 1 "$RUN_DIR/drift-stdout.log" 2>/dev/null || true)"
  add_anomaly "Phase1①: check-drift.shがfail-fastしました（${DRIFT_RESULT}）。JSON: $DRIFT_JSON_LINE"
  RUN_FULLY_OK=0
  notify_macos "maintenance.sh 異常終了" "環境ヘルスチェック(check-drift)でdrift/実行異常を検知したため中断しました。詳細: $RUN_DIR"
  exit 1
fi

# --- ②fragments_log.py --since <前回成功時刻> --json ---
# fragments_log.py/vault_inventory.pyはVaultパスを$HOME/Data/obsidianに固定
# しており--vault相当のオプション/環境変数を持たない（2026-07-16実装時に
# 判明した既存の仕様＝knowledge_merge_candidates.py・maintenance_apply.pyは
# --vaultを持つのに対し非対称。本スクリプトはVAULTを渡せる範囲では渡すに
# 留め、この2本の改修はPR2のスコープ外として現状追随する）。
FRAGMENTS_STATUS_FILE="$RUN_DIR/step-status-fragments.json"
FRAGMENTS_JSON="$RUN_DIR/fragments.json"
run_wrapped_step "$TIMEOUT_FRAGMENTS_LOG" "$FRAGMENTS_STATUS_FILE" \
  "$FRAGMENTS_JSON" "$RUN_DIR/fragments-stderr.log" \
  python3 "$SCRIPT_DIR/vault-agents/fragments_log.py" --since "$SINCE_DATE" --json
FRAGMENTS_RESULT="$(parse_step_status "$FRAGMENTS_STATUS_FILE")"
log "②fragments_log.py: $FRAGMENTS_RESULT"
FRAGMENTS_JSON_ARG=()
if [[ "$FRAGMENTS_RESULT" == "OK 0" ]]; then
  FRAGMENTS_JSON_ARG=(--fragments-json "$FRAGMENTS_JSON")
else
  add_anomaly "Phase1②: fragments_log.pyが失敗/timeoutしました（${FRAGMENTS_RESULT}・継続します）"
fi

# --- ③vault_inventory.py --json ---
INVENTORY_STATUS_FILE="$RUN_DIR/step-status-inventory.json"
INVENTORY_JSON="$RUN_DIR/inventory.json"
run_wrapped_step "$TIMEOUT_VAULT_INVENTORY" "$INVENTORY_STATUS_FILE" \
  "$INVENTORY_JSON" "$RUN_DIR/inventory-stderr.log" \
  python3 "$SCRIPT_DIR/vault-agents/vault_inventory.py" --json
INVENTORY_RESULT="$(parse_step_status "$INVENTORY_STATUS_FILE")"
log "③vault_inventory.py: $INVENTORY_RESULT"
INVENTORY_JSON_ARG=()
if [[ "$INVENTORY_RESULT" == "OK 0" ]]; then
  INVENTORY_JSON_ARG=(--inventory-json "$INVENTORY_JSON")
else
  add_anomaly "Phase1③: vault_inventory.pyが失敗/timeoutしました（${INVENTORY_RESULT}・継続します）"
fi

# --- ④knowledge_merge_candidates.py --json ---
MERGE_STATUS_FILE="$RUN_DIR/step-status-merge.json"
MERGE_JSON="$RUN_DIR/merge.json"
run_wrapped_step "$TIMEOUT_KNOWLEDGE_MERGE" "$MERGE_STATUS_FILE" \
  "$MERGE_JSON" "$RUN_DIR/merge-stderr.log" \
  python3 "$SCRIPT_DIR/vault-agents/knowledge_merge_candidates.py" --vault "$VAULT" --json
MERGE_RESULT="$(parse_step_status "$MERGE_STATUS_FILE")"
log "④knowledge_merge_candidates.py: $MERGE_RESULT"
MERGE_JSON_ARG=()
if [[ "$MERGE_RESULT" == "OK 0" ]]; then
  MERGE_JSON_ARG=(--merge-json "$MERGE_JSON")
else
  add_anomaly "Phase1④: knowledge_merge_candidates.pyが失敗/timeoutしました（${MERGE_RESULT}・継続します）"
fi

# --- ⑤decision_propagation.py --since <前回成功時刻> --out <レポート> ---
# rc=0/1は成功（0=波及漏れ無し・1=波及漏れ検出＝いずれも正常な検出結果）、
# rc>=2のみ失敗としてラップする（設計書§3.4）。検出結果はmaintenance_apply.py
# には渡さない（波及修正はSSOT書換＝夜間ジョブ禁止スコープのため、サマリの
# みFragments日次へ・棚卸し相談で人間が処理する対象＝cleanup決定#6）。
DECISION_STATUS_FILE="$RUN_DIR/step-status-decision.json"
DECISION_OUT="$RUN_DIR/decision-propagation.md"
run_wrapped_step "$TIMEOUT_DECISION_PROPAGATION" "$DECISION_STATUS_FILE" \
  "$RUN_DIR/decision-stdout.log" "$RUN_DIR/decision-stderr.log" \
  env VAULT="$VAULT" \
  python3 "$SCRIPT_DIR/vault-agents/decision_propagation.py" --since "$SINCE_DATE" --out "$DECISION_OUT"
DECISION_RESULT="$(parse_step_status "$DECISION_STATUS_FILE")"
log "⑤decision_propagation.py: $DECISION_RESULT"
DECISION_MISSING_COUNT=0
case "$DECISION_RESULT" in
  "OK 0") : ;;
  "OK 1") DECISION_MISSING_COUNT=1 ;;
  *) add_anomaly "Phase1⑤: decision_propagation.pyが失敗/timeoutしました（${DECISION_RESULT}・継続します）" ;;
esac

# =============================================================================
# Phase 2: 判断＋適用（maintenance_apply.py）
# =============================================================================

log "=== Phase 2: 判断＋適用 ==="

APPLY_STATUS_FILE="$RUN_DIR/apply-status.json"
APPLY_WRAPPER_STATUS_FILE="$RUN_DIR/step-status-apply.json"
run_wrapped_step "$TIMEOUT_MAINTENANCE_APPLY" "$APPLY_WRAPPER_STATUS_FILE" \
  "$RUN_DIR/apply-stdout.log" "$RUN_DIR/apply-stderr.log" \
  python3 "$SCRIPT_DIR/vault-agents/maintenance_apply.py" \
  --vault "$VAULT" --workdir "$RUN_DIR" --status-file "$APPLY_STATUS_FILE" \
  --claude-timeout "$MAINTENANCE_APPLY_CLAUDE_TIMEOUT" \
  --max-merge-actions "$MAINTENANCE_APPLY_MAX_MERGE_ACTIONS" \
  ${FRAGMENTS_JSON_ARG[@]+"${FRAGMENTS_JSON_ARG[@]}"} \
  ${INVENTORY_JSON_ARG[@]+"${INVENTORY_JSON_ARG[@]}"} \
  ${MERGE_JSON_ARG[@]+"${MERGE_JSON_ARG[@]}"}
APPLY_WRAPPER_RESULT="$(parse_step_status "$APPLY_WRAPPER_STATUS_FILE")"
log "Phase2 maintenance_apply.py: $APPLY_WRAPPER_RESULT"

# maintenance_apply.py自身は「一切書き込まず」異常でも常にexit 0で終わる契約
# （設計書§2.6）のため、ラッパー自身がtimeout/spawn_error等で異常終了した
# 場合（=child自体がapply-status.jsonを書けなかった可能性が高い）と、
# 子プロセスが正常終了した場合を区別して読む。status-fileの中身自体も
# fail-closedで厳密に検証する（2026-07-16 Codexレビュー指摘Minor対応:
# 従来は`.get(key, 0)`/`.get("anomaly")`のtruthy判定のみで、`{}`や
# `{"ok": false}`のような不完全なstatus-fileも「正常・件数0」として素通り
# していた。ok/anomalyの型がbool以外、必須キー欠落、件数が非負整数でない
# 場合はすべて読取失敗＝anomaly扱いにする）。
N_PROMOTED=0; N_MERGED=0; N_MERGED_PARTIAL=0; N_FIXED=0; N_SKIPPED=0; APPLY_ANOMALY=1; APPLY_REASON="wrapper_failed"
if [[ "$APPLY_WRAPPER_RESULT" == "OK 0" && -f "$APPLY_STATUS_FILE" ]]; then
  read -r N_PROMOTED N_MERGED N_MERGED_PARTIAL N_FIXED N_SKIPPED APPLY_ANOMALY APPLY_REASON <<EOF
$(python3 -c "
import json, sys

def _nonneg_int(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0

try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    required = ['ok', 'anomaly', 'n_promoted', 'n_merged', 'n_merged_partial', 'n_fixed', 'n_skipped']
    if not isinstance(d, dict) or any(k not in d for k in required):
        raise ValueError('missing_required_key')
    if not isinstance(d['ok'], bool) or not isinstance(d['anomaly'], bool):
        raise ValueError('ok_or_anomaly_not_bool')
    # ok/anomalyは互いに否定の関係でなければならない契約
    # （maintenance_apply.py側の_write_status_file呼び出しは常に
    # ok=not has_anomaly, anomaly=has_anomalyを渡す）。この不変条件が
    # 崩れている（例: ok=false かつ anomaly=false）status-fileは、
    # 中間ファイル破損の兆候として素直に信用せずanomaly扱いにする
    # （2026-07-16 Codex二次レビュー指摘Minor対応: 従来はanomalyフィールド
    # だけを見ており、「ok: false, anomaly: false」のような矛盾した
    # 組合せがok=false側を無視して「成功」として通過していた。バッククォート
    # で囲むと、この行全体がpython3 -cの二重引用符bash文字列の内側にある
    # ためコマンド置換として誤解釈され「line NNN: {ok:: command not found」
    # というシェルエラーになる＝2026-07-16 tester独立検証F1で実測発見。
    # python3 -cのコード文字列内（bashの二重引用符の内側）ではバッククォート
    # も二重引用符自体も使わない＝2026-07-16 Codexレビュー指摘Minor対応
    # （本コメント自身が二重引用符を含んでいたため同種の脆弱な構造になって
    # いた）。
    if d['ok'] == d['anomaly']:
        raise ValueError('ok_and_anomaly_inconsistent')
    counts = [d['n_promoted'], d['n_merged'], d['n_merged_partial'], d['n_fixed'], d['n_skipped']]
    if not all(_nonneg_int(c) for c in counts):
        raise ValueError('counts_not_nonneg_int')
    print(*counts, 1 if d['anomaly'] else 0, (d.get('reason') or 'none').replace(' ', '_'))
except Exception as e:
    print(0, 0, 0, 0, 0, 1, f'apply_status_file_invalid:{type(e).__name__}')
" "$APPLY_STATUS_FILE")
EOF
  if [[ "$APPLY_ANOMALY" == "1" ]]; then
    add_anomaly "Phase2: maintenance_apply.pyがanomalyを報告しました（reason=${APPLY_REASON}）"
  fi
else
  # ラッパー自体の起動失敗（timeout/spawn_error等）は上のstatus-file読取を
  # 行わない＝APPLY_REASON="wrapper_failed"のままなので、二重に
  # add_anomaly()しないようここだけで完結させる（2026-07-16 Codexレビュー
  # 対応の自己点検: 起動失敗時に「起動自体に失敗」と「anomalyを報告」の
  # 2つの異常メッセージが重複しないようにする）。
  add_anomaly "Phase2: maintenance_apply.pyの起動自体に失敗しました（${APPLY_WRAPPER_RESULT}）"
fi
log "Phase2結果: promote=$N_PROMOTED merge=$N_MERGED merge_partial=$N_MERGED_PARTIAL fix=$N_FIXED skip=$N_SKIPPED"

# =============================================================================
# Phase 3: サマリ・last-run.json更新・最終commit・通知・保持整理
# =============================================================================

log "=== Phase 3: サマリ・通知 ==="

# --- Fragments当日ファイルへ実施サマリを1行追記 ---
# 定常メンテ（Fragments週次昇格・棚卸し対処）はAIが自律実行し個別報告も
# 不要という運用（Preferences/vault-operation.md「書き方の鉄則」の例外規定）
# のもと、監査はこのサマリ行＋git履歴で担保する。失敗時はanomaly化する
# （2026-07-16 Codexレビュー指摘Major対応: 従来は戻り値を一切見ておらず、
# 書込失敗が黙って握り潰されたまま処理が続いていた）。
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

SUMMARY_LINE="定常メンテ(週次): 昇格${N_PROMOTED}件・マージ${N_MERGED}件（部分適用${N_MERGED_PARTIAL}件）・修正${N_FIXED}件・見送り${N_SKIPPED}件・波及漏れ疑い${DECISION_MISSING_COUNT}件（詳細: ${RUN_DIR}）"
if append_fragments_summary "$SUMMARY_LINE"; then
  log "Fragmentsサマリ追記: $SUMMARY_LINE"
else
  add_anomaly "Phase3: Fragmentsサマリの追記に失敗しました"
fi

# --- Preferencesへの昇格があった夜はexport-public-vault.shを再実行する ---
# （設計書改訂v2§1.2「Preferencesへの昇格があった夜はPhase 3でexportを実行」）。
# apply-log.json内にaction=promote・applied=true・note_pathが"Preferences/"で
# 始まる結果が1件でもあれば対象（2026-07-16 Codexレビュー指摘Major対応:
# 当初はPhase3にこの再実行が実装されておらず、新規Preferencesノートの
# public同期が最大1週間遅延しうる欠陥があった）。
APPLY_LOG_FILE="$RUN_DIR/apply-log.json"
HAD_PREFERENCES_PROMOTION="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print(0); raise SystemExit
found = any(
    isinstance(r, dict) and r.get('action') == 'promote' and r.get('applied') is True
    and isinstance(r.get('note_path'), str) and r['note_path'].startswith('Preferences/')
    for r in d.get('results', []) if isinstance(d, dict)
)
print(1 if found else 0)
" "$APPLY_LOG_FILE" 2>/dev/null || echo 0)"
if [[ "$HAD_PREFERENCES_PROMOTION" == "1" ]]; then
  log "Phase3: Preferencesへの昇格を検出したためexport-public-vault.shを再実行します"
  run_export_retry "Phase3"
fi

# --- backup-vault.shを再度呼び即commit（Fragmentsサマリ＋Phase2の全変更を捕捉） ---
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
    # busyもここではanomaly扱いにする（2026-07-16 Codexレビュー指摘Major
    # 対応: Phase3はVault書込ロックを自分自身が保持したまま最後に呼ぶため、
    # MAINTENANCE_LOCK_OWNER_PIDのbypassが正しく機能していればbusyには
    # ならないはずで、busyが観測されること自体がバイパスの不整合を示す
    # 異常＝Phase0のような「穏当なskip」とは意味が異なる）。今回の
    # Fragmentsサマリ・Phase2の変更が未commitのまま残る可能性があるため
    # last_success_atは更新しない。
    add_anomaly "Phase3: 最終commit(backup-vault.sh)が異常終了しました（${BACKUP3_RESULT}・status=${BACKUP3_STATUS_WORD}）"
    ;;
esac

# --- last-run.jsonのlast_success_atは完全正常終了時のみ更新 ---
# Phase3の最終commitまで含めた全ステップが終わった後、最後に判定する
# （2026-07-16 Codexレビュー指摘Major対応: 従来はFragmentsサマリ追記の直後
# ＝最終commitより前に判定していたため、最終commit自体が失敗しても
# last_success_atだけが先に進んでしまっていた）。
if [[ "$RUN_FULLY_OK" -eq 1 ]]; then
  if write_last_run_field last_success_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
    log "last_success_at を更新しました"
  else
    # ここまで来て最後の書込みだけが失敗した場合、次回実行時の--since算出が
    # 古いままの値を使うことになり実害は小さい（fail-open）が、書込失敗
    # 自体は運用上気付けるようにanomaly化する（2026-07-16 Codex二次レビュー
    # 指摘Minor対応）。スクリプト自体はここでは中断しない（Phase3の最後の
    # ステップであり、これ以上ロールバックすべき後続処理も無いため）。
    add_anomaly "Phase3: last-run.jsonのlast_success_at更新に失敗しました"
  fi
else
  log "今回は完全正常終了ではないため last_success_at は更新しません（次回も同じ--sinceから再試行）"
fi

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
# Phase1②〜⑤やexport再試行の個別失敗のように「隔離して継続した」異常が
# あってもここでは0のまま。1=Phase0/Phase1①のfail-fastで早期中断した場合の
# みで、それらは各早期return箇所で個別にexit 1している）。「何か異常が
# あったか」はプロセスの終了コードではなく、上記のmacOS通知（異常時のみ）で
# 判断する設計＝cronジョブ的な「ジョブ自体は完走した」と「中身に注意点が
# あった」を別チャネルに分ける一般的な作法に合わせる。
exit 0
