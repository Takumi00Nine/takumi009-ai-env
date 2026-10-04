#!/usr/bin/env bash
# v1.2 束 B の締めの実走ハーネス（要件 v1.2 §7・設計 v1.3 §6 のうち、観測の層「締め」の行＝
#   AC-2・AC-3④・AC-4①・AC-5①・AC-7①②④・AC-12①②）。既存の v1.1 締めハーネス（run-closing.sh・
#   lib-closing.sh・ac-suites.sh・ac-12.sh・ac-live.sh）の共通部品をそのまま source し、
#   束 B の AC だけを ac-b.sh の定義（同名で上書き）に差し替える。
#
# 使い方: bash tests/closing/run-closing-b.sh <基準コミット> [<worktree>]
#   <基準コミット>＝FX-2（main 0a86db1 相当）。<worktree>＝FX-1 を取る repo（既定＝このファイルの repo ルート）。
#   設定値＝tests/closing/closing.conf（環境変数で上書き可）。AC を絞るとき＝CLOSING_ONLY="AC-2 AC-5"。
#
# 出力・安全＝run-closing.sh と同じ契約（AC ごとに `AC-n <ok|NG> <要点>`・最後に `closing: ok=<n> ng=<n>`・
#   詳細は tests/closing/out/<実行時刻>/・使い捨て worktree・一時 HOME・PATH 先頭の偽コマンド・
#   SKIP_LAUNCHCTL=1・LAUNCHCTL_TIMEOUT_SECS=1）。

set -uo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '7,9p' "$0" >&2; exit 2; }
CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CL_HERE/lib-closing.sh"
. "$CL_HERE/ac-suites.sh"
. "$CL_HERE/ac-12.sh"
. "$CL_HERE/ac-live.sh"
. "$CL_HERE/ac-b.sh"   # 束 B の AC-2・AC-5・AC-7・AC-12 を上書き・AC-3・AC-4 を追加

CL_SRC="$(cd "${2:-$CL_HERE/../..}" && git rev-parse --show-toplevel)" || { echo "repo が見つからない: ${2:-}" >&2; exit 2; }
BASE_COMMIT="$(git -C "$CL_SRC" rev-parse --verify "$1^{commit}" 2>/dev/null)" || { echo "基準コミットが無い: $1" >&2; exit 2; }
FX1_COMMIT="$(git -C "$CL_SRC" rev-parse HEAD)"
[ -z "$(git -C "$CL_SRC" status --porcelain --untracked-files=no)" ] || echo "注意: $CL_SRC に未コミットの変更がある（FX-1 は HEAD のコミット＝含まない）" >&2

OUT="${CLOSING_OUT_ROOT:-$CL_HERE/out}/$(date +%Y%m%d-%H%M%S)-b"
mkdir -p "$OUT"
WORK="$(cl_realpath "$(mktemp -d "${TMPDIR:-/tmp}/closing-b.XXXXXX")")"
trap cl_cleanup EXIT
trap 'exit 130' INT TERM

if ! why="$(cl_check_env)"; then echo "環境が FX-6 の前提を満たさない:$why" >&2; exit 2; fi

WT0="$WORK/wt0"; WT1="$WORK/wt1"
cl_new_wt "$WT0" "$BASE_COMMIT" || { echo "基準の worktree を作れない（$OUT/detail.log）" >&2; exit 2; }
cl_new_wt "$WT1" "$FX1_COMMIT" || { echo "FX-1 の worktree を作れない（$OUT/detail.log）" >&2; exit 2; }

CL_SUBS=("$WORK/home=<HOME>" "$WORK=<WORK>")
for c in "$BASE_COMMIT" "$FX1_COMMIT"; do
  CL_SUBS+=("$c=<COMMIT>" "$(git -C "$CL_SRC" rev-parse --short "$c")=<COMMIT>" "${c:0:7}=<COMMIT>")
done
{ echo "base=$BASE_COMMIT fx1=$FX1_COMMIT src=$CL_SRC work=$WORK"; date; } >> "$OUT/detail.log"

cl_want() { [ -z "${CLOSING_ONLY:-}" ] || case " $CLOSING_ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
t0=$(date +%s)
for ac in AC-2 AC-3 AC-4 AC-5 AC-7 AC-12; do
  cl_want "$ac" || continue
  s=$(date +%s)
  "ac_${ac#AC-}"
  echo "$ac $(( $(date +%s) - s ))s" >> "$OUT/timing.txt"
done
echo "total $(( $(date +%s) - t0 ))s" >> "$OUT/timing.txt"

echo "詳細: $OUT"
echo "closing: ok=$CL_OK ng=$CL_NG"
[ "$CL_NG" -eq 0 ]
