#!/bin/bash
# vault-paths.sh — 「Vault の AI 向け 6 フォルダ配下か」の述語（Core の汎用部品）。
#
# 正本はここ 1 か所（6 フォルダの literal はここにしか書かない）。Vault 書込の柵と
# 委任の柵の両方が source して同じ判定を使う。関数名は分割前のまま（呼ぶ側の行を変えない）。
# Bash 3.2 互換。`source` して使う（何度 source しても副作用は関数定義のみ）。

# guard_vault_ai_prefixes: $HOME/Data/obsidian 配下の AI 向け 6 フォルダの
# プレフィックス（末尾に /* を付けない絶対パス）を 1 行ずつ標準出力する。
guard_vault_ai_prefixes() {
  local base="${HOME:-}/Data/obsidian"
  printf '%s\n' \
    "$base/Fragments" \
    "$base/Knowledge" \
    "$base/Decisions" \
    "$base/Projects" \
    "$base/Preferences" \
    "$base/Personal"
}

# guard_is_vault_ai_path <絶対パス>: 6 フォルダ配下（フォルダ自身は含まず、
# 配下のファイル/ディレクトリだけ）なら 0・それ以外は 1。
guard_is_vault_ai_path() {
  local path="$1" prefix
  while IFS= read -r prefix; do
    case "$path" in
      "$prefix"/*) return 0 ;;
    esac
  done <<EOF
$(guard_vault_ai_prefixes)
EOF
  return 1
}
