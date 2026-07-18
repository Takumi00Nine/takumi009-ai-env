#!/usr/bin/env bash
# 共有シェルライブラリ: 機械可読status-fileの読み書き
# （2026-07-16簡素化・cleanup決定#10・PR1.5③）。
#
# scripts/backup-vault.sh の `--status-file`（PR2でmaintenance.sh Phase0向けに
# 追加予定・設計書§1.2）と scripts/maintenance.sh 自身の状態ファイル読み取りが
# この関数を共用する。状態値は `completed` / `no-change` / `busy` / `error` の
# いずれか1語（設計書§1.2）。既存の人間向けログ文言パースはしない＝
# ステータスは常にこの専用ファイルへ機械可読な1語で書く契約。
#
# 呼び出し規約:
#   write_status_file <status_file_path> <status_word>
#     status_wordは completed/no-change/busy/error のいずれかのみ許可する
#     （Codex一次レビュー指摘・Minor対応: 契約外の値を書けてしまうと読み取り側の
#     機械判定が「知らない値」を静かに誤分類しうる）。不正な値・ディレクトリ作成
#     失敗・書込み失敗は標準エラーへWARNを出すのみで**常にexit code 0を返す**
#     （真のfail-open。呼び出し元が`set -e`下でも本関数の呼び出しでスクリプトが
#     止まらない契約＝status-fileはあくまで補助的な通知経路であり、本処理の成否は
#     別途スクリプト自身のexit codeで判定できる設計のため）。
#   read_status_file <status_file_path>
#     標準出力へ status_word を1行で返す。ファイルが無い/読み取れない/空/
#     4状態語のいずれでもない場合は固定文字列 "missing" を返す（呼び出し元が
#     「未実行/不正値」を一律に「未実行」として扱えるように）。

_STATUS_FILE_VALID_WORDS=(completed no-change busy error)

_status_file_is_valid_word() {
  local word="$1" w
  for w in "${_STATUS_FILE_VALID_WORDS[@]}"; do
    [[ "$word" == "$w" ]] && return 0
  done
  return 1
}

write_status_file() {
  local status_file="$1" status="$2"
  [[ -n "$status_file" ]] || return 0
  if ! _status_file_is_valid_word "$status"; then
    echo "WARN: write_status_file: 不正な状態語です（completed/no-change/busy/errorのいずれかのみ許可）: $status" >&2
    return 0
  fi
  if ! mkdir -p "$(dirname "$status_file")" 2>/dev/null; then
    echo "WARN: write_status_file: ディレクトリを作成できません: $status_file" >&2
    return 0
  fi
  if ! printf '%s\n' "$status" > "$status_file" 2>/dev/null; then
    echo "WARN: write_status_file: 書込みに失敗しました: $status_file" >&2
    return 0
  fi
  return 0
}

read_status_file() {
  local status_file="$1" content
  if [[ ! -f "$status_file" ]]; then
    echo "missing"
    return 1
  fi
  content="$(head -n 1 "$status_file" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$content" ]] || ! _status_file_is_valid_word "$content"; then
    echo "missing"
    return 1
  fi
  printf '%s\n' "$content"
}
