#!/usr/bin/env bash
# v1.2 束 C の締めの実走ハーネス（要件 v1.4・設計 v1.4 §6 のうち、観測の層「締め」の行＝
#   AC-7①②④・AC-8②④・AC-10・AC-11③④・AC-12①②③④）。既存の束 B の締めハーネス（ac-b.sh・lib-closing.sh・
#   ac-suites.sh・ac-12.sh・ac-live.sh）の共通部品をそのまま source し、AC-7 は ac-b.sh の定義を流用（再定義しない）、
#   AC-8・AC-10・AC-11・AC-12 は ac-c.sh の定義（同名で上書き）に差し替える。
#
# 使い方: bash tests/closing/run-closing-c.sh <基準コミット> [<worktree>]
#   <基準コミット>＝束 C 着手ゲート C1（束 B 取込み後の main＝束 C の基準）。<worktree>＝FX-1 を取る repo（既定＝このファイルの repo ルート）。
#   設定値＝tests/closing/closing.conf（環境変数で上書き可）。AC を絞るとき＝CLOSING_ONLY="AC-8 AC-10"。
#   AC-11④（FX-16・dotfiles）＝CLOSING_DOTFILES_REPO・CLOSING_DOTFILES_COMMIT が未指定なら skip（NG に数えない）。
#
# 出力・安全＝run-closing-b.sh と同じ契約（AC ごとに `AC-n <ok|NG> <要点>`・最後に `closing: ok=<n> ng=<n>`・
#   詳細は tests/closing/out/<実行時刻>-c/・使い捨て worktree・一時 HOME・PATH 先頭の偽コマンド・
#   SKIP_LAUNCHCTL=1・LAUNCHCTL_TIMEOUT_SECS=1）。実 HOME・実 launchd・実 cmux・実 Vault（読むだけ）・
#   実 ~/work/dotfiles・実 repo の main には書かない。

set -uo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '8,11p' "$0" >&2; exit 2; }
CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CL_HERE/lib-closing.sh"
. "$CL_HERE/ac-suites.sh"
. "$CL_HERE/ac-12.sh"
. "$CL_HERE/ac-live.sh"
. "$CL_HERE/ac-b.sh"   # AC-7 はここの定義をそのまま使う（束 C で再定義しない）
. "$CL_HERE/ac-c.sh"   # AC-8・AC-10・AC-11・AC-12 を束 C の定義で上書き

CL_SRC="$(cd "${2:-$CL_HERE/../..}" && git rev-parse --show-toplevel)" || { echo "repo が見つからない: ${2:-}" >&2; exit 2; }
BASE_COMMIT="$(git -C "$CL_SRC" rev-parse --verify "$1^{commit}" 2>/dev/null)" || { echo "基準コミットが無い: $1" >&2; exit 2; }
FX1_COMMIT="$(git -C "$CL_SRC" rev-parse HEAD)"
[ -z "$(git -C "$CL_SRC" status --porcelain --untracked-files=no)" ] || echo "注意: $CL_SRC に未コミットの変更がある（FX-1 は HEAD のコミット＝含まない）" >&2

OUT="${CLOSING_OUT_ROOT:-$CL_HERE/out}/$(date +%Y%m%d-%H%M%S)-c"
mkdir -p "$OUT"
WORK="$(cl_realpath "$(mktemp -d "${TMPDIR:-/tmp}/closing-c.XXXXXX")")"
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
for ac in AC-7 AC-8 AC-10 AC-11 AC-12; do
  cl_want "$ac" || continue
  s=$(date +%s)
  "ac_${ac#AC-}"
  echo "$ac $(( $(date +%s) - s ))s" >> "$OUT/timing.txt"
done
echo "total $(( $(date +%s) - t0 ))s" >> "$OUT/timing.txt"

echo "詳細: $OUT"
echo "closing: ok=$CL_OK ng=$CL_NG"
[ "$CL_NG" -eq 0 ]
