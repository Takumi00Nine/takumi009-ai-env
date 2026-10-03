#!/bin/bash
# zz-cli 接続の配置手順（設計 §10.3 (c)）: 登録に変換シムの絶対パスを埋めて $HOME/.zz-cli/ へ置く。
# 全部入りの組立は呼ばない・触らない（この接続フォルダの中で完結＝FR-9）。
set -eu
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.zz-cli"
sed "s#__SHIM__#$SELF_DIR/recall-shim.sh#" "$SELF_DIR/register.tmpl" > "$HOME/.zz-cli/hooks"
