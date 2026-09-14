#!/bin/bash
# UserPromptSubmit hook: 本人の発言時点の使用率を毎回コンテキストへ追加する。
# stdin の内容には依存しない。どの失敗経路でも1行へ縮退し exit 0 を返す。
set -u

resolve_usage_inject_self_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}

# Claude Code は JSON を stdin に渡すが、本フックは発言内容で分岐しない。
cat >/dev/null 2>&1 || true

USAGE_INJECT_SELF_DIR="$(resolve_usage_inject_self_dir 2>/dev/null)" || USAGE_INJECT_SELF_DIR=""
USAGE_BLOCK_LIB="${USAGE_BLOCK_LIB:-$USAGE_INJECT_SELF_DIR/lib/usage-block.sh}"
USAGE_SNAPSHOT_LIB="${USAGE_SNAPSHOT_LIB:-$USAGE_INJECT_SELF_DIR/lib/usage_snapshot.py}"

if [ -z "$USAGE_INJECT_SELF_DIR" ] || [ ! -f "$USAGE_BLOCK_LIB" ]; then
  printf '【使用率・この発言時点】取得口が使えません（内部エラー）\n'
  exit 0
fi

# shellcheck source=lib/usage-block.sh
. "$USAGE_BLOCK_LIB" 2>/dev/null || {
  printf '【使用率・この発言時点】取得口が使えません（内部エラー）\n'
  exit 0
}

USAGE_BLOCK="$(compute_usage_block '【使用率・この発言時点】' '' 2>/dev/null)" || USAGE_BLOCK=""
[ -n "$USAGE_BLOCK" ] || USAGE_BLOCK='【使用率・この発言時点】取得口が使えません（内部エラー）'
printf '%s\n' "$USAGE_BLOCK"
exit 0
