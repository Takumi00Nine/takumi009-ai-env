#!/bin/bash
# 迂回の検出（設計-v1.1.1.md §6・D-5・FR-23）: `scripts/claude-exec.sh` を経由
# しない `claude -p` / `claude --print` 起動が repo 内に無いかを静的検査する。
#
# 使い方:
#   scripts/check-claude-bypass.sh [検査対象パス]   # 既定＝repo ルート
#
# ⚠️ AC-13① の陽性 fixture は、本スクリプトが読む repo 本体とは別に、一時
# ディレクトリを検査対象に指定した**別の実行**で行う（本体の「0件」判定と
# 混ぜない＝4巡目 V4-m2）。検査対象を引数で受けるのはこのため。
#
# 検査語（3本のOR。P1が主・P2/P3は迂回の別形）:
#   P1: claude／claude.exe の引数として -p／--print が来る形
#       （間にフラグと値が入ってよいが、値トークンに '/' を含む語は置けない
#       ＝ `git log -p claude/x.sh` の類を落とす）
#   P2: claude.exe の実体パス直指定
#   P3: CLAUDE_CODE_EXECPATH（全 Bash ツール環境に export 済みの実体パス経由）
#
# 走査から外すディレクトリ＝.git/・node_modules/。バイナリは -I で飛ばす。
#
# 固定の除外リスト（裁定C・設計 v1.1.1 §6）＝3件ちょうど。除外の追加・削除は
# 設計書の改訂を要する（恒久テスト exclusion_list_is_exactly_three が3件
# ちょうどであることと、理由つきで表示されることを見る）。
#   1. scripts/claude-exec.sh                        … ラッパー自身
#   2. scripts/check-claude-bypass.sh                 … 検出器自身（検査語を literal で持つ）
#   3. scripts/experiments/worker-provider-probe.sh    … 手動実行のみの実験資産（B-2完了時に退役と同時に除外を外す）
#
# 出力: 除外を適用した後に残った一致行を `path:line:内容` で並べ、1件以上
# なら exit 1。除外の表示行は件数に数えない。除外は常に3行、末尾に表示する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="${1:-$REPO_ROOT}"
if [ ! -e "$TARGET" ]; then
  echo "check-claude-bypass: 検査対象パスが存在しません: $TARGET" >&2
  exit 2
fi
TARGET_ABS="$(cd "$TARGET" 2>/dev/null && pwd || true)"
if [ -z "$TARGET_ABS" ]; then
  # ファイル単体指定にも対応（ディレクトリでなければ cd できない）
  case "$TARGET" in
    /*) TARGET_ABS="$TARGET" ;;
    *) TARGET_ABS="$(pwd)/$TARGET" ;;
  esac
fi

P1='(^|[^A-Za-z0-9_./-])claude(\.exe)?([[:space:]]+(-{1,2}[A-Za-z][A-Za-z0-9_-]*(=[^[:space:]]+)?|[^[:space:]/]+))*[[:space:]]+(-p|--print)([[:space:]]|$)'
P2='claude\.exe'
P3='CLAUDE_CODE_EXECPATH'

# 固定の除外リスト（裁定C）＝repo ルートからの絶対パスで持つ。検査対象が
# repo の外（一時ディレクトリ）のときは、これらのパスは存在しないので
# 単純に一致しない（除外の表示自体は常に行う）。
EXCLUDE_PATHS=(
  "$REPO_ROOT/scripts/claude-exec.sh"
  "$REPO_ROOT/scripts/check-claude-bypass.sh"
  "$REPO_ROOT/scripts/experiments/worker-provider-probe.sh"
)
EXCLUDE_REASONS=(
  "ラッパー自身＝唯一の正規の呼び出し口"
  "検出器自身＝検査語を literal で持つ"
  "手動実行のみの実験資産（B-2＝サブ機Bedrock経路の実測に使う。B-2完了時に退役と同時に除外を外す）"
)

is_excluded() {
  local f="$1" i
  for i in "${!EXCLUDE_PATHS[@]}"; do
    [ "$f" = "${EXCLUDE_PATHS[$i]}" ] && return 0
  done
  return 1
}

RAW="$(grep -rInE --exclude-dir=.git --exclude-dir=node_modules -I \
  -e "$P1" -e "$P2" -e "$P3" \
  "$TARGET_ABS" 2>/dev/null || true)"

HITS=0
if [ -n "$RAW" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%%:*}"
    case "$f" in
      /*) f_abs="$f" ;;
      *) f_abs="$TARGET_ABS/$f" ;;
    esac
    # grep -r の相対パス表示をrepoルート基準の絶対パスへ正規化
    f_abs="$(cd "$(dirname "$f_abs")" 2>/dev/null && pwd)/$(basename "$f_abs")"
    if is_excluded "$f_abs"; then
      continue
    fi
    echo "$line"
    HITS=$((HITS + 1))
  done <<EOF
$RAW
EOF
fi

echo "---"
for i in "${!EXCLUDE_PATHS[@]}"; do
  echo "除外 ${#EXCLUDE_PATHS[@]} 件＝${EXCLUDE_PATHS[$i]}（${EXCLUDE_REASONS[$i]}）"
done

if [ "$HITS" -gt 0 ]; then
  echo "check-claude-bypass: ${HITS}件の迂回候補を検出しました" >&2
  exit 1
fi
exit 0
