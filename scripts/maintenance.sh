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
#   ①check-drift.sh --json（環境ヘルスの点検。④を除いたdrift>0または実行
#     異常/timeoutでも中断せず警告として記録し完走する＝2026-08-10 fail-fast
#     廃止・[[Decisions/2026-08-10-round6-rulings]]決定1。Vault書込み安全の
#     門番はPhase 0の直前スナップショット（backup-vault.sh成功必須）に一本化
#     済み。旧fail-fastは18日間の週次メンテ停止（[[Decisions/2026-08-05-
#     bootstrap-health-warning-report]]）の主因だった＝止めた実績はいずれも
#     実行安全とは無関係〈config.tomlアプリ自動追記・リーダー作業途中の
#     未コミット〉。警告・失敗の可視化はPhase3末尾のlast_result記録＋
#     claude/hooks/bootstrap-vault.shの起動ヘルス行が担う）
#   ②fragments_log.py --since <前回成功時刻> --json
#   ③vault_inventory.py --json
#   ④knowledge_merge_candidates.py --json
#   ⑤decision_propagation.py --since <前回成功時刻> --out <レポート>
#   ①〜⑤は1本失敗/timeoutしても他は継続する（エラー隔離）。
# Phase 2: maintenance_apply.py が②④の検出結果を集約しヘッドレスClaudeへ
#   1回投げ、検証済みの構造化出力に基づきPROMOTE/MERGEをVaultへ適用する
#   （FIX機能は2026-07-18本人裁定で丸ごと削除済み＝[[Decisions/2026-07-18-
#   external-brain-hardening]]2周目。理由＝Preferences限定でしか動かず
#   「夜間はPreferencesを書かない」境界の唯一の違反経路だった・値も効果限定的。
#   ③vault_inventory.pyのmissing_updated検出は棚卸しレポート表示のみに残り、
#   maintenance_apply.pyへは渡さない）。
#   PROMOTEのtarget_folder=="Preferences"のみVaultへは書かず、下書き全文を
#   Vault外の提案保管先へ保管するだけにとどめる（2026-07-17改定・[[Decisions/
#   2026-07-16-nightly-batch-direct-write]]同日改定＝Preferencesは「無人
#   直書き」ではなく「提案→承認後に作成」）。
# Phase 3: Preferences提案件数（proposals_dir直下*.mdの参考glob件数。通知は
#   claude/hooks/bootstrap-vault.shが起動のたびに直接スキャンする＝
#   2026-07-18ハードニングでpendingマーカー層は撤去済み）を含む実施サマリを
#   Fragments当日ファイルへ1行追記、last-run.jsonのlast_success_at
#   を完全正常終了時のみ更新、last_result（success/warn＋警告要旨の短文。
#   Phase0の直前スナップショット失敗時は"fail"を個別に記録＝2026-08-10
#   [[Decisions/2026-08-10-round6-rulings]]決定1のセット条件）を常に更新、
#   backup-vault.shを再度呼び即commit、Vault書込ロック解放（EXIT trap自動）、
#   異常時のみmacOS通知、30日超過の実行ディレクトリを削除。
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
# Preferences提案の保管先（maintenance_apply.pyのDEFAULT_PREFERENCES_PROPOSALS_DIRと
# 同じ既定値。明示的に環境変数で両者へ結線し、片方だけ変更してもう片方が
# 追従し忘れるドリフトを避ける＝2026-07-18ハードニング）。
: "${PREFERENCES_PROPOSALS_DIR:=$HOME/.claude/logs/maintenance/preferences-proposals}"
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
: "${TIMEOUT_MAINTENANCE_APPLY:=720}"
# maintenance_apply.py自身の内部--claude-timeout（上記TIMEOUT_MAINTENANCE_APPLYより
# 短くする＝外側のmaintenance_run_step.pyタイムアウトが内側より先に発火すると
# 内部の状況が分からないまま強制終了されるため、内側を先に切れさせる）。
: "${MAINTENANCE_APPLY_CLAUDE_TIMEOUT:=600}"
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

# informationalな注記の蓄積（2026-08-10・工程横断レビュー指摘Major対応）。
# add_anomaly()と違い、RUN_FULLY_OKは倒さない＝last_result/last_success_atの
# 判定には一切影響しない「参考情報」専用チャネル。用途＝②のTOML三分類で
# 検出された未知config.tomlキーのように、「driftでも異常でもないが、
# RUN_DIRログ（30日TTL）に埋もれさせず翌セッションの起動ヘルス行までは
# 見えるようにしたい」情報を通す（本人裁定「warnへ昇格させない」）。
# ログには残すがwarn()（stderr）は使わない＝完全に正常な実行のノイズに
# しないため（stdoutのlog()のみ）。
INFO_NOTES=()
add_info_note() { INFO_NOTES+=("$1"); log "INFO: $1"; }

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

# last_result（旧D4・[[Decisions/2026-08-10-round6-rulings]]決定1のセット
# 条件「警告・失敗の可視化」）: success/warn/failの3値＋警告要旨の短文を
# last-run.jsonへ記録する。claude/hooks/bootstrap-vault.shの起動ヘルス行が
# 翌セッション冒頭でこれを拾い⚠️表示する（正本＝[[Decisions/2026-08-05-
# bootstrap-health-warning-report]]）。last_result/last_result_summaryは
# 常にペアで意味を持つ値（新しいvalueに古いsummaryが対応してしまうと
# 誤解を招く）のため、write_last_run_field()を2回呼ぶ独立更新にはせず
# 1回のPython起動で両方を同時に書く＝Codex一次レビュー指摘Major対応
# （2回に分けると1回目成功・2回目失敗時に新旧値が混在しうる）。
# write_last_run_field()と同じfail-open方針（書込失敗はwarn()するだけで
# 処理は止めない＝last_resultは「次回への申し送り」であり、これ自体の
# 書込失敗で今回の実行結果を左右すべきではないため）。$2（summary）は
# 空文字列でもよい（success時）。
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
# 衝突検知として使う（2026-07-16 Codexレビュー指摘Minor対応）。
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
  # ここだけはfail-fastする（2026-07-16 Codex二次レビュー指摘Minor対応:
  # 従来は戻り値を見ておらず、書込失敗が黙って握り潰されたまま
  # 「started_atは記録済み」という前提で処理が進んでいた）。
  echo "[maintenance] FAIL: last-run.jsonのstarted_at更新に失敗しました: $LAST_RUN_FILE" >&2
  # last_resultも同じファイルへの書込みのため、started_at同様に失敗しうる
  # （write_last_result自体はfail-openでwarn()するだけ＝二重に中断はしない）。
  # それでも書ける環境（started_atの書込みだけがたまたま失敗した等）では
  # 次回起動時のヘルス行に反映させたい。
  write_last_result "fail" "last-run.jsonのstarted_at更新に失敗しました"
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
#
# acquire_pid_lockはbusy(exit 0)だけでなく、回収ミューテックス競合が20回
# 試行しても解消しない場合はfail-closedでexit 1する契約（前回実行の
# クラッシュ痕跡の可能性・scripts/lib/pid-lock.sh参照）。この経路は
# maintenance.sh側のadd_anomaly/write_last_resultを一切経由せず直接
# プロセスごとexitするため、素通しだと前回のlast_result（success/warn）が
# 誤って残ったまま翌セッションのヘルス行に出てしまう（2026-08-10 Codex
# 一次レビュー2周目指摘Major対応）。acquire_pid_lock自体はライブラリ関数
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
# 2026-08-10 fail-fast廃止（[[Decisions/2026-08-10-round6-rulings]]決定1）。
# 旧: ④を除いたdrift>0または実行異常/timeoutでexit 1しPhase1②以降・Phase2を
# 実行せず中断していた（定期成功0/4の主因）。
# 新: 結果に関わらず②以降・Phase2へ進む。Vault書込み安全の門番はPhase 0の
# 直前スナップショット（本ファイル上部のbackup-vault.sh呼び出し・busy/error時は
# 既にこの行より前でexitしている）に一本化済みのため、ここで止める理由が無い。
DRIFT_STATUS_FILE="$RUN_DIR/step-status-drift.json"
run_wrapped_step "$TIMEOUT_CHECK_DRIFT" "$DRIFT_STATUS_FILE" \
  "$RUN_DIR/drift-stdout.log" "$RUN_DIR/drift-stderr.log" \
  env VAULT="$VAULT" \
  bash "$SCRIPT_DIR/check-drift.sh" --json
DRIFT_RESULT="$(parse_step_status "$DRIFT_STATUS_FILE")"
log "①check-drift.sh: $DRIFT_RESULT"

if [[ "$DRIFT_RESULT" != "OK 0" ]]; then
  # rc=1(④を除いたdrift>0)・rc>=2(実行エラー)・WRAPPER_FAIL(timeout等)の
  # いずれも警告として記録するだけで、②以降・Phase2はそのまま継続する
  # （add_anomaly()がwarn()出力・ANOMALIES追記・RUN_FULLY_OK=0への降格を
  # まとめて行う＝本ファイル冒頭のadd_anomaly()定義参照）。
  DRIFT_JSON_LINE="$(tail -n 1 "$RUN_DIR/drift-stdout.log" 2>/dev/null || true)"
  add_anomaly "Phase1①: check-drift.shがdrift/実行異常を検知しました（${DRIFT_RESULT}・警告として記録し継続します）。JSON: $DRIFT_JSON_LINE"
fi

# --- ①相当: check-drift.sh②(config.toml三分類)の未知キー件数をinformational
#     として拾う（2026-08-10・工程横断レビュー指摘Major対応） ---
# 未知キー（テンプレにも既知アプリ管理キー一覧にも無いキー）はcheck-drift.sh
# 側の設計どおりdriftには数えない＝上のDRIFT_RESULTが"OK 0"（異常なし）でも
# 起こりうる。driftでないぶんadd_anomaly()の対象にはせず（last_result=warnへ
# 昇格させない・本人裁定）、add_info_note()でsuccess時のlast_result_summary
# だけに拾う。これが無いと「WARN表示のみ→drift非計上→last_result=success→
# 起動ヘルス行に出ない」経路になり、RUN_DIRログ（30日TTL）の奥に埋もれて
# 誰にも読まれないまま消えていた（工程横断レビューで指摘された可視化導線の
# 欠落）。DRIFT_RESULTがWRAPPER_FAIL(timeout等)でJSON自体が出力されていない
# 場合はpython3のjson.loads()が例外を投げ、fail-openで何もしない（既に
# add_anomaly側でその異常は捕捉済みのため二重に警告する必要が無い）。
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
  # fragments_log.pyは個々のFragmentsファイルの読取失敗をscan_error_countとして
  # JSONへ返すが、それ自体はexit 0の契約（設計書の「読取専用・fail-open」）の
  # ため、上のrc判定（$FRAGMENTS_RESULT）だけでは検知できない「静かな取りこぼし」
  # だった（2周目・全体構成再レビューCodex+Fable5収束後の小修正＝impl4）。
  # scan_error_count>0ならanomaly化し、last_success_atを進めない（apply側の
  # state_update_warning等と同クラスの最小の足し＝失敗した窓を翌週再走査させる）。
  # JSON自体が破損/契約違反（scan_error_countが無い・非負整数でない等）で
  # 件数を確定できない場合も「0件（正常）」へfail-openで丸めてはいけない
  # （2026-07-18 2周目Codexレビュー指摘Major対応: 従来は例外時に0を印字して
  # おり、fragments_log.py側の契約違反や出力破損を静かな正常扱いにしてしまい、
  # 今回追加した「取りこぼしを翌週再走査させる」目的そのものが成立しなくなる
  # 経路が残っていた）。件数を確定できない場合もanomaly化してPhase2へは渡さない。
  if FRAGMENTS_SCAN_ERROR_COUNT="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
v = d['scan_error_count']
if not (isinstance(v, int) and not isinstance(v, bool) and v >= 0):
    raise SystemExit(1)
print(v)
" "$FRAGMENTS_JSON" 2>/dev/null)" && [[ "$FRAGMENTS_SCAN_ERROR_COUNT" =~ ^[0-9]+$ ]]; then
    FRAGMENTS_JSON_ARG=(--fragments-json "$FRAGMENTS_JSON")
    if [[ "$FRAGMENTS_SCAN_ERROR_COUNT" -gt 0 ]]; then
      add_anomaly "Phase1②: fragments_log.pyが読み取れなかったFragmentsファイルが${FRAGMENTS_SCAN_ERROR_COUNT}件あります（scan_error_count>0・候補は渡しつつ継続しますが、翌週再走査させるためlast_success_atは進めません）"
    fi
  else
    add_anomaly "Phase1②: fragments_log.pyのJSON出力からscan_error_countを取得できませんでした（契約違反/JSON破損の疑い・候補は渡さず継続します）"
  fi
else
  add_anomaly "Phase1②: fragments_log.pyが失敗/timeoutしました（${FRAGMENTS_RESULT}・継続します）"
fi

# --- ③vault_inventory.py --json ---
# missing_updated（Preferences限定）はもはやmaintenance_apply.pyへ渡さない
# （FIX機能を2026-07-18本人裁定で丸ごと削除済み＝[[Decisions/2026-07-18-
# external-brain-hardening]]2周目。以後は`.md`棚卸しレポート§1への表示・
# n_issues計上のみ＝人間が読み時/棚卸し相談で直す）。それでも棚卸し検出
# 自体（他の項目＝date_drift・リンク切れ・alias欠落等を含む）は週次で
# 実行し続け、失敗/timeoutはanomaly化する。
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
  "OK 1")
    # rc=1は「何らかの波及漏れ疑いがある」ことしか保証しないブール値だが、
    # decision_propagation.pyのレポート本文には実件数
    # 「波及漏れの疑い: N ノート」が必ず1行含まれる契約（build_report()参照）
    # のため、可能ならそこから実件数を拾う（2026-07-18ハードニング対処方針4
    # 「decision_propagationサマリは可能なら実件数へ」）。best-effort:
    # レポート書式変更・DECISION_OUT読取不可等でパースできない場合は、
    # 従来どおり「1件以上ある」ことだけを表す1へフォールバックする（0件と
    # 誤表示しない安全側デフォルト）。
    DECISION_MISSING_PARSED="$(grep -m1 -oE '波及漏れの疑い: [0-9]+' "$DECISION_OUT" 2>/dev/null | grep -oE '[0-9]+$')"
    if [[ "$DECISION_MISSING_PARSED" =~ ^[0-9]+$ && "$DECISION_MISSING_PARSED" -gt 0 ]]; then
      DECISION_MISSING_COUNT="$DECISION_MISSING_PARSED"
    else
      DECISION_MISSING_COUNT=1
    fi
    ;;
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
  --preferences-proposals-dir "$PREFERENCES_PROPOSALS_DIR" \
  ${FRAGMENTS_JSON_ARG[@]+"${FRAGMENTS_JSON_ARG[@]}"} \
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
N_PROMOTED=0; N_MERGED=0; N_MERGED_PARTIAL=0; N_SKIPPED=0; APPLY_ANOMALY=1; APPLY_REASON="wrapper_failed"
if [[ "$APPLY_WRAPPER_RESULT" == "OK 0" && -f "$APPLY_STATUS_FILE" ]]; then
  read -r N_PROMOTED N_MERGED N_MERGED_PARTIAL N_SKIPPED APPLY_ANOMALY APPLY_REASON <<EOF
$(python3 -c "
import json, sys

def _nonneg_int(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0

try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    # n_fixedキーは2026-07-18本人裁定「FIXごと削除」でmaintenance_apply.py側の
    # status-file契約から撤去された＝[[Decisions/2026-07-18-external-brain-
    # hardening]]2周目。この必須キー契約も6キーへ追従する。
    required = ['ok', 'anomaly', 'n_promoted', 'n_merged', 'n_merged_partial', 'n_skipped']
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
    counts = [d['n_promoted'], d['n_merged'], d['n_merged_partial'], d['n_skipped']]
    if not all(_nonneg_int(c) for c in counts):
        raise ValueError('counts_not_nonneg_int')
    print(*counts, 1 if d['anomaly'] else 0, (d.get('reason') or 'none').replace(' ', '_'))
except Exception as e:
    print(0, 0, 0, 0, 1, f'apply_status_file_invalid:{type(e).__name__}')
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
log "Phase2結果: promote=$N_PROMOTED merge=$N_MERGED merge_partial=$N_MERGED_PARTIAL skip=$N_SKIPPED"

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

# --- Preferences提案件数（Fragmentsサマリ用・2026-07-18ハードニング）---
# 2026-07-17改定＝[[Decisions/2026-07-16-nightly-batch-direct-write]]同日改定・
# 本人再裁定でPreferences昇格は「無人直書き」ではなく「提案→承認後に作成」へ
# 変更された。maintenance_apply.py（Phase2）はtarget_folder=="Preferences"の
# PROMOTEをVaultへ書かず、下書き全文をVault外の提案保管先（PREFERENCES_
# PROPOSALS_DIR）へ保管するだけにとどめる。旧実装（apply-log.json内の
# note_pathが"Preferences/"で始まる結果を検出してexport-public-vault.shを
# Phase3で再実行する処理）はここで撤去された（Preferencesが夜間にVaultへ
# 直接書かれなくなったため、同夜exportの必要性自体が消えた＝Phase0冒頭の
# export再試行＝run_export_retry "Phase0"はリーダーの通常編集由来の差分対策
# として引き続き残る・別目的のため混同しない）。
#
# pendingマーカー層は2026-07-18ハードニング（[[Decisions/2026-07-18-
# external-brain-hardening]]）で撤去した（正本＝proposals_dir自体を
# claude/hooks/bootstrap-vault.shが起動のたびに直接スキャンして通知する
# 方式へ変更・専用マーカーJSON・破損自己修復ロジック・
# preferences_pending_marker.pyは削除済み＝部品削減。旧実装はgit log -p参照）。
# ここでは通知は行わず、Fragmentsサマリ行に載せる参考件数として
# proposals_dir直下の*.mdファイル数を軽く数えるだけにとどめる（列挙自体が
# 失敗しても0件扱いのfail-openでよい＝この数値は監査用の参考情報であり、
# 本人への通知はbootstrap-vault.sh側の独立したスキャンが担保するため）。
N_PENDING_PREFERENCES_PROPOSALS=0
if [[ -d "$PREFERENCES_PROPOSALS_DIR" ]]; then
  N_PENDING_PREFERENCES_PROPOSALS="$(find "$PREFERENCES_PROPOSALS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$N_PENDING_PREFERENCES_PROPOSALS" =~ ^[0-9]+$ ]] || N_PENDING_PREFERENCES_PROPOSALS=0
fi

SUMMARY_LINE="定常メンテ(週次): 昇格${N_PROMOTED}件・マージ${N_MERGED}件（部分適用${N_MERGED_PARTIAL}件）・見送り${N_SKIPPED}件・Preferences未確認提案${N_PENDING_PREFERENCES_PROPOSALS}件（要承認）・波及漏れ疑い${DECISION_MISSING_COUNT}件（詳細: ${RUN_DIR}）"
if append_fragments_summary "$SUMMARY_LINE"; then
  log "Fragmentsサマリ追記: $SUMMARY_LINE"
else
  add_anomaly "Phase3: Fragmentsサマリの追記に失敗しました"
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
# Phase1①〜⑤やexport再試行の個別失敗のように「隔離して継続した」異常が
# あってもここでは0のまま。1=Phase0の直前スナップショット(backup-vault.sh)が
# 起動失敗/異常終了した場合のみで、そこの早期return箇所で個別にexit 1して
# いる。Phase1①のcheck-drift.shは2026-08-10からfail-fastを廃止したため、
# ここでexit 1する経路ではなくなった＝[[Decisions/2026-08-10-round6-
# rulings]]決定1）。「何か異常があったか」はプロセスの終了コードではなく、
# 上記のmacOS通知（異常時のみ）で判断する設計＝cronジョブ的な「ジョブ自体は
# 完走した」と「中身に注意点があった」を別チャネルに分ける一般的な作法に
# 合わせる。
exit 0
