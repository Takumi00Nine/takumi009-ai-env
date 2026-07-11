#!/bin/bash
# PostToolUse(Read) hook: Vault内ファイルのRead実態を記録する（利用ログ）。
#
# 目的: vault-recall.sh（UserPromptSubmit）が提示した候補ノートが、実際に
# Readされたかどうかを後から突き合わせるための実測データを残す
# （session_id + 相対パスで vault-recall.tsv と vault-reads.tsv を突き合わせれば、
# 「提示されたのに読まれなかった率」を計測できる。突き合わせは
# scripts/vault-agents/vault_inventory.py §12 が実施）。
#
# Vault配下以外のReadは対象外（即exit 0・ログも残さない）。fail-open・軽量最優先＝
# PostToolUseなのでこのフックの失敗がRead自体の結果に影響することは無いが、
# 「あらゆるReadで毎回呼ばれる」高頻度フックのため、Vault外という多数派ケースでは
# 一切フォークもログ書き込みもしない（stdin解析の異常時のみ後述のERROR行を残す＝
# ノイズゼロを優先しつつ、無言のfail-openにはしない）。
#
# vault-recall.tsv と同じ理由で、vault-reads.tsv も
# scripts/vault-agents/vault_inventory.py の read_log()（ts\tsession_id\tノート相対パス
# の3列を読む共通パーサ）が消費する。ERROR行の3列目（ノートパスの位置）に
# メッセージを置くと存在しないノートとして誤集計されるため、3列目は空にして
# 無害化し、メッセージは read_log() が読まない4列目に置く（vault-recall.shと同方式）。
#
# 環境変数（すべて省略可・テスト用）:
#   VAULT_READS_VAULT … Vaultのルート（既定 $HOME/Data/obsidian）
#   VAULT_READS_LOG    … 利用ログのTSVパス（既定 $HOME/.claude/logs/vault-reads.tsv・
#                         vault_inventory.py と同名の環境変数）

VAULT="${VAULT_READS_VAULT:-$HOME/Data/obsidian}"
LOG_FILE="${VAULT_READS_LOG:-$HOME/.claude/logs/vault-reads.tsv}"

log_error() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")"
  printf '%s\tERROR\t\t%s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

INPUT="$(cat 2>/dev/null || true)"

# file_path・session_idを1回のjq呼び出しで取り出す。
JQ_OUT="$(printf '%s' "$INPUT" | jq -r '[(.tool_input.file_path // ""), (.session_id // "")] | @tsv' 2>/dev/null)"
JQ_RC=$?
if [ "$JQ_RC" -ne 0 ]; then
  log_error "stdin JSONの解析に失敗しました（jq exit ${JQ_RC}）"
  exit 0
fi
IFS=$'\t' read -r FPATH SESSION_ID <<< "$JQ_OUT"

[ -z "$FPATH" ] && exit 0

case "$FPATH" in
  "$VAULT"/*) : ;;
  *) exit 0 ;;   # Vault配下でなければ即終了（多数派ケース・ログも残さない）
esac

RELPATH="${FPATH#"$VAULT"/}"

# 文字列prefix一致だけでは "$VAULT/../outside.md" のような ".." を含むパスも
# "$VAULT/"始まりとして通ってしまう（Codexレビュー指摘・Major）。相対パス化した
# 後に ".." 構成要素が残っていれば、実体はVault外の可能性が高いためログに残さず
# 終了する（realpath等でのシンボリックリンク解決までは行わない軽量な防御）。
case "$RELPATH" in
  ..|../*|*/../*|*/..) exit 0 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || exit 0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")"
printf '%s\t%s\t%s\n' "$TS" "$SESSION_ID" "$RELPATH" >> "$LOG_FILE" 2>/dev/null || true

exit 0
