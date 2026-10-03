#!/usr/bin/env bash
# v1.1 締めの実走ハーネス（要件 v1.5 §7・設計 v1.4 のうち、基準 worktree FX-2 や偽 zz-cli の配置が要り常設の一括実行に乗せないもの）。
#   AC-2 ③④・AC-5 ①・AC-7・AC-8・AC-9・AC-10・AC-12（設計 §13・実装計画 §8）。
#
# 使い方: bash tests/closing/run-closing.sh <基準コミット> [<worktree>]
#   <基準コミット>＝FX-2（実装ブランチの分岐元 main）。<worktree>＝FX-1 を取る repo（既定＝このファイルの repo ルート）。
#   FX-1＝<worktree> の HEAD のコミット（未コミットの変更は含まない＝stderr に注意を出す）。
#   設定値＝tests/closing/closing.conf（環境変数で上書き可）。AC を絞るとき＝CLOSING_ONLY="AC-8 AC-12"。
#
# 出力（契約）: 標準出力＝AC ごとに `AC-n <ok|NG> <要点>` を 1 行、最後に `closing: ok=<n> ng=<n>`。
#   詳細（差分・一覧・ログ）は tests/closing/out/<実行時刻>/ に残し、そのパスを 1 行で示す。終了コード＝NG が 1 件でもあれば 1。
#
# 安全: 基準・FX-1・FX-9a〜d・FX-10 は `git worktree add --detach` の使い捨て（終了時に remove）。HOME は一時ディレクトリ
#   （FX-3）・PATH 先頭に偽 launchctl・osascript・cmux（FX-6）・SKIP_LAUNCHCTL=1・LAUNCHCTL_TIMEOUT_SECS=1。
#   実 ~/.claude・~/.codex・実 launchd・実 cmux・実 Vault（Preferences の grep＝読み取りだけ）・実 repo の main には書かない。
#   AC-10 の origin は使い捨ての bare repo（$WORK/origin.git）。

set -uo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '5,8p' "$0" >&2; exit 2; }
CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CL_HERE/lib-closing.sh"
. "$CL_HERE/ac-suites.sh"
. "$CL_HERE/ac-12.sh"
. "$CL_HERE/ac-live.sh"

CL_SRC="$(cd "${2:-$CL_HERE/../..}" && git rev-parse --show-toplevel)" || { echo "repo が見つからない: ${2:-}" >&2; exit 2; }
BASE_COMMIT="$(git -C "$CL_SRC" rev-parse --verify "$1^{commit}" 2>/dev/null)" || { echo "基準コミットが無い: $1" >&2; exit 2; }
FX1_COMMIT="$(git -C "$CL_SRC" rev-parse HEAD)"
[ -z "$(git -C "$CL_SRC" status --porcelain --untracked-files=no)" ] || echo "注意: $CL_SRC に未コミットの変更がある（FX-1 は HEAD のコミット＝含まない）" >&2

OUT="${CLOSING_OUT_ROOT:-$CL_HERE/out}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
WORK="$(cl_realpath "$(mktemp -d "${TMPDIR:-/tmp}/closing.XXXXXX")")"
trap cl_cleanup EXIT
trap 'exit 130' INT TERM

if ! why="$(cl_check_env)"; then echo "環境が FX-6 の前提を満たさない:$why" >&2; exit 2; fi

WT0="$WORK/wt0"; WT1="$WORK/wt1"
cl_new_wt "$WT0" "$BASE_COMMIT" || { echo "基準の worktree を作れない（$OUT/detail.log）" >&2; exit 2; }
cl_new_wt "$WT1" "$FX1_COMMIT" || { echo "FX-1 の worktree を作れない（$OUT/detail.log）" >&2; exit 2; }

# 比較から除く値（一時パス・コミット hash）の実値→記号
CL_SUBS=("$WORK/home=<HOME>" "$WORK=<WORK>")
for c in "$BASE_COMMIT" "$FX1_COMMIT"; do
  CL_SUBS+=("$c=<COMMIT>" "$(git -C "$CL_SRC" rev-parse --short "$c")=<COMMIT>" "${c:0:7}=<COMMIT>")
done
{ echo "base=$BASE_COMMIT fx1=$FX1_COMMIT src=$CL_SRC work=$WORK"; date; } >> "$OUT/detail.log"

cl_want() { [ -z "${CLOSING_ONLY:-}" ] || case " $CLOSING_ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
t0=$(date +%s)
for ac in AC-2 AC-5 AC-7 AC-8 AC-9 AC-10 AC-12; do
  cl_want "$ac" || continue
  s=$(date +%s)
  "ac_${ac#AC-}"
  echo "$ac $(( $(date +%s) - s ))s" >> "$OUT/timing.txt"
done
echo "total $(( $(date +%s) - t0 ))s" >> "$OUT/timing.txt"

echo "詳細: $OUT"
echo "closing: ok=$CL_OK ng=$CL_NG"
[ "$CL_NG" -eq 0 ]
