#!/bin/bash
# 口（Notify の実行器・台帳の鍵 notify.send）。v1.2 束 B＝docs/v1.2-notify-install の設計 §2.1・§2.3。
#
# 呼び方:
#   notify.sh call <区分> <題> <本文> [<音>]   区分＝alert（異常）・usage（使用率）・ask（判断依頼）
#   notify.sh answer
# 台帳ツールの照会（route）で知らせ→送り手の一覧を引き、送り手を並行に起動して各々を
# 上限 AIENV_NOTIFY_WAIT_SECS 秒（既定 5）で打ち切る。送り手の標準出力・標準エラーは捨てる。
# 届かなかった届け先・届け先なし・台帳の異常だけを知らせの記録へ 1 行ずつ（成功は書かない）。
# 終了コード＝0 1 件以上届いた／1 1 件も届かない／64 使い方の誤り。
# 届け先の名前・呼出構文は持たない（照会の結果だけを使う）。

set -u

# ---- 設計定数（§4）＝変えるときはここだけ ----
NOTIFY_WAIT_SECS_DEFAULT=5
NOTIFY_CATEGORIES="alert usage ask"   # 呼出の区分の語彙
NOTIFY_RC_USAGE=64

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=core/executor/notice.sh
. "$ROOT/core/executor/notice.sh"
WAIT_SECS="${AIENV_NOTIFY_WAIT_SECS:-$NOTIFY_WAIT_SECS_DEFAULT}"

usage() {
  echo "usage: notify.sh call <区分(${NOTIFY_CATEGORIES// /|})> <題> <本文> [<音>] | notify.sh answer" >&2
  exit "$NOTIFY_RC_USAGE"
}

case "${1:-}" in
  call)
    { [ $# -eq 4 ] || [ $# -eq 5 ]; } || usage
    case " $NOTIFY_CATEGORIES " in *" $2 "*) ;; *) usage ;; esac
    kind=call; cat="$2"; title="$3"; body="$4"; sound="${5:-}"; topic="call.$2" ;;
  answer)
    [ $# -eq 1 ] || usage
    kind=answer; cat=-; title=-; body=-; sound=; topic=answer ;;
  *) usage ;;
esac

LOG="$(notice_log_path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notify.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

# 照会: 実体の無い送り手の行は stderr の固定文（LEDGER: part …）で除かれる。固定文は 1 行ずつ記録へ。
rc=0
routes="$("$ROOT/core/assembly/ledger-tool.sh" route "$topic" 2>"$WORK/route.err")" || rc=$?
while IFS= read -r msg; do
  case "$msg" in
    "LEDGER: "*) word="${msg#LEDGER: }"; notice_record_append "$LOG" "${word%% *}" "-" "$title" "$msg" ;;
  esac
done <"$WORK/route.err"
case "$rc" in
  0) ;;
  1) notice_record_append "$LOG" "no-dest" "-" "$title" "$topic"; exit 1 ;;
  *) [ -s "$WORK/route.err" ] || notice_record_append "$LOG" "ledger" "-" "$title" "LEDGER: ledger 照会に失敗 (exit=$rc)"
     exit 1 ;;
esac

# 並行に渡す（各々 WAIT_SECS で打ち切り）。
n=0
while IFS=$'\t' read -r dest path; do
  [ -n "$dest" ] || continue
  n=$((n + 1))
  printf '%s' "$dest" >"$WORK/$n.dest"
  ( notice_run_with_timeout "$WAIT_SECS" "$path" "$kind" "$cat" "$title" "$body" ${sound:+"$sound"} >/dev/null 2>&1
    echo $? >"$WORK/$n.rc" ) &
done <<EOF
$routes
EOF
wait

delivered=0
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  dest="$(cat "$WORK/$i.dest")"
  r="$(cat "$WORK/$i.rc" 2>/dev/null)"
  case "$r" in
    0) delivered=1 ;;
    2) notice_record_append "$LOG" "no-exe" "$dest" "$title" "-" ;;
    "$NOTICE_TIMEOUT_RC") notice_record_append "$LOG" "timeout" "$dest" "$title" "${WAIT_SECS}s" ;;
    *) notice_record_append "$LOG" "failed" "$dest" "$title" "exit=${r:-?}" ;;
  esac
done
[ "$delivered" -eq 1 ] && exit 0
exit 1
