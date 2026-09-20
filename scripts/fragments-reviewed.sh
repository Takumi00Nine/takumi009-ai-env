#!/usr/bin/env bash
# 昇格の締めCLI（Preferences/fragments-workflow.md §4「昇格の締め3手順」の②。
# 要件・設計＝requirements-design-v1.md FR-3・§2.3・2026-09-20）。
#
# 背景: 週次メンテ(scripts/maintenance.sh)のPhase1②は「候補N件」をlast-run.jsonの
# fragments_candidates/fragments_sinceへ書き、cmux Dockの週次行が読む。従来は
# 数え始め（--since）が「前回の週次成功」固定だったため、本人が昇格対応を終えても
# 次の週次まで候補が0件にならなかった。本CLIはlast-run.jsonへ
# fragments_reviewed_at（今この瞬間）を書き、maintenance.shのsince決定
# （候補=[fragments_reviewed_at, last_success_at]の順で最初に有効なもの）へ割り込む。
# CLI自身は候補件数を数え直して表示するだけで、Dockの0件反映は次回の週次
# （または本CLI実行後60秒以内に読み直すDock側の既存経路＝設計書AC-7）に委ねる。
#
# 使い方:
#   scripts/fragments-reviewed.sh             # last-run.jsonへ記録し1行出力
#   scripts/fragments-reviewed.sh --dry-run   # 何も書かず、書く予定の3値を表示
#   scripts/fragments-reviewed.sh -h          # 使い方
#
# 手順: ①UTCの今をnowとする ②`fragments_log.py --since <nowの日付> --json`を
# maintenance.shのrun_wrapped_step相当（maintenance_run_step.py・timeout付き・
# プロセスグループごと終了）で実行 ③maintenance.sh Phase1②と同じ契約検査
# （exit 0・JSON・scan_error_countが非負整数・fragmentsが配列）を通ったときだけ
# ④last-run.jsonへfragments_reviewed_at=now・fragments_candidates=候補件数・
# fragments_since=<nowの日付>を原子的に書く（tmp→os.replace）。
#
# 失敗時（fragments_log.pyの非0/timeout・JSON破損・契約違反・書込失敗のいずれか）
# はlast-run.jsonを1バイトも変えずexit非0でstderrに理由1行を出す。
#   1 = fragments_log.pyが失敗/timeoutした
#   2 = fragments_log.pyの出力が契約に違反している（JSON破損含む）
#   3 = last-run.jsonへの書込みに失敗した
#
# 環境変数（テスト用・既定はmaintenance.shと同じ値/同じ既定パス）:
#   LAST_RUN_FILE         既定 $HOME/.claude/logs/maintenance/last-run.json
#   FRAGMENTS_LOG_PY      既定 <このスクリプトの場所>/vault-agents/fragments_log.py
#   TIMEOUT_FRAGMENTS_LOG 既定 90（秒）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
: "${FRAGMENTS_LOG_PY:=$SCRIPT_DIR/vault-agents/fragments_log.py}"
: "${TIMEOUT_FRAGMENTS_LOG:=90}"

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "fragments-reviewed.sh: 不明な引数です: ${1}" >&2; echo "usage: scripts/fragments-reviewed.sh [--dry-run]" >&2; exit 2 ;;
esac

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SINCE_DATE="${NOW%%T*}"

TMPDIR_CLI="$(mktemp -d "${TMPDIR:-/tmp}/fragments-reviewed.XXXXXX")" || {
  echo "fragments-reviewed.sh: 一時ディレクトリを作成できません" >&2
  exit 1
}
trap 'rm -rf "$TMPDIR_CLI"' EXIT

STATUS_FILE="$TMPDIR_CLI/status.json"
OUT_FILE="$TMPDIR_CLI/fragments.json"
ERR_FILE="$TMPDIR_CLI/stderr.log"

# maintenance.shのrun_wrapped_step/parse_step_statusと同じ方法（timeout付き・
# プロセスグループごと終了）で起動する。maintenance.sh自身の関数は切り出さず、
# 同じ土台（maintenance_run_step.py）を直接呼ぶ。
python3 "$SCRIPT_DIR/vault-agents/maintenance_run_step.py" \
  --timeout "$TIMEOUT_FRAGMENTS_LOG" --status-file "$STATUS_FILE" -- \
  python3 "$FRAGMENTS_LOG_PY" --since "$SINCE_DATE" --json \
  > "$OUT_FILE" 2> "$ERR_FILE"

STEP_RESULT="$(python3 -c "
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
" "$STATUS_FILE")"

if [[ "$STEP_RESULT" != "OK 0" ]]; then
  echo "fragments-reviewed.sh: fragments_log.pyが失敗/timeoutしました（${STEP_RESULT}）: $(tail -n1 "$ERR_FILE" 2>/dev/null)" >&2
  exit 1
fi

# 契約検査（maintenance.sh Phase1②と同じ＝scan_error_countが非負整数・
# fragmentsが配列）と件数取得を1回のpython起動でまとめて行う。
CANDIDATES="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
sec = d.get('scan_error_count')
if not (isinstance(sec, int) and not isinstance(sec, bool) and sec >= 0):
    sys.exit(1)
frags = d.get('fragments')
if not isinstance(frags, list):
    sys.exit(1)
print(len(frags))
" "$OUT_FILE" 2>/dev/null)"
if [[ $? -ne 0 || ! "$CANDIDATES" =~ ^[0-9]+$ ]]; then
  echo "fragments-reviewed.sh: fragments_log.pyの出力が契約に違反しています（JSON破損またはキー欠落/型違反）: ${OUT_FILE}" >&2
  exit 2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "dry-run: fragments_reviewed_at=${NOW} fragments_candidates=${CANDIDATES} fragments_since=${SINCE_DATE}"
  exit 0
fi

# 原子更新（maintenance.shのwrite_last_run_jsonと同型: 読み→マージ→tmp書き→
# os.replace。破損/不在時は{}から作る＝fail-open）。3キーを1回のpython起動で
# 同時に書く（2回に分けると1回目成功・2回目失敗時に不整合な組合せが残るため）。
if ! python3 -c "
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
data['fragments_reviewed_at'] = sys.argv[2]
data['fragments_candidates'] = int(sys.argv[3])
data['fragments_since'] = sys.argv[4]
tmp = path.parent / ('.' + path.name + '.tmp-' + str(os.getpid()))
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding='utf-8')
os.replace(str(tmp), str(path))
" "$LAST_RUN_FILE" "$NOW" "$CANDIDATES" "$SINCE_DATE"; then
  echo "fragments-reviewed.sh: last-run.jsonへの書込みに失敗しました: ${LAST_RUN_FILE}" >&2
  exit 3
fi

echo "昇格対応済み: ${NOW}・候補${CANDIDATES}件（${SINCE_DATE} 以降）"
