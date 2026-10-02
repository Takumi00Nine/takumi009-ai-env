#!/bin/bash
# usage_snapshot.py の人可読3行へ見出しを付ける共有関数。
# 呼び出し元は USAGE_SNAPSHOT_LIB を実体パスへ設定すること。

compute_usage_block() { # $1=見出し、$2=末尾へ付ける案内（空なら省略）
  local heading="$1"
  local footer="$2"
  local body rc

  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s取得口が使えません（python3 なし）' "$heading"
    return 0
  fi
  if [ ! -f "$USAGE_SNAPSHOT_LIB" ]; then
    printf '%s取得口が使えません（usage_snapshot.py が見つかりません）' "$heading"
    return 0
  fi

  if [ -n "${AIENV_USAGE_NOW:-}" ]; then
    body="$(python3 "$USAGE_SNAPSHOT_LIB" --now "$AIENV_USAGE_NOW" 2>/dev/null)"
  else
    body="$(python3 "$USAGE_SNAPSHOT_LIB" 2>/dev/null)"
  fi
  rc=$?
  if [ -z "$body" ] || [ "$rc" != "0" ]; then
    printf '%s取得口が使えません（usage_snapshot.py の実行に失敗しました）' "$heading"
    return 0
  fi

  if [ -n "$footer" ]; then
    printf '%s\n%s\n%s' "$heading" "$body" "$footer"
  else
    printf '%s\n%s' "$heading" "$body"
  fi
  return 0
}
