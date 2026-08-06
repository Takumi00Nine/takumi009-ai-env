#!/bin/bash
# bash-danger-gate.sh — PreToolUse(Bash) の危険コマンド deny ゲート
# 目的: プロンプトインジェクション等で騙されても、ツール境界で破壊的コマンドを実行不能にする最終防衛線。
#   ①リモートスクリプトのパイプ実行（curl/wget → shell）を無条件 deny
#   ②保護パス（Vault・~/.claude・~/.codex・~/.cmuxterm・HOME直下・/）への再帰 rm を deny
# 導入経緯: 2026-07-19 偽 system_warning 注入インシデント（Fragments/2026-07/2026-07-19）

cmd=$(jq -r '.tool_input.command // ""')

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  exit 0
}

# ① リモート取得内容をシェルへ流す実行（curl/wget ... | [sudo] bash/sh/zsh、bash <(curl ...)）
if printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|source)([[:space:]]|$)'; then
  deny 'リモートスクリプトのパイプ実行（curl/wget | shell）はブロックされています。スクリプトは一旦ファイルに保存し、内容を確認してから実行してください（bash-danger-gate）。'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(bash|sh|zsh)[[:space:]]+<\([[:space:]]*(curl|wget)'; then
  deny 'リモートスクリプトのプロセス置換実行（bash <(curl ...)）はブロックされています。スクリプトは一旦ファイルに保存し、内容を確認してから実行してください（bash-danger-gate）。'
fi

# ② 再帰 rm（rm -r/-R/--recursive）× 保護パス
if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'; then
  # 保護パス: Vault / ~/.claude / ~/.codex / ~/.cmuxterm
  if printf '%s' "$cmd" | grep -Eq '(Data/obsidian|\.claude|\.codex|\.cmuxterm)'; then
    deny '保護パス（Vault・.claude・.codex・.cmuxterm）への再帰 rm はブロックされています。本当に必要な削除は本人が自分の手で実行してください（bash-danger-gate）。'
  fi
  # HOME 直下・ルートへの再帰 rm（rm -rf ~ / rm -rf /）
  if printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]]+("?\$HOME"?|~)?/?([[:space:]]|$)'; then
    deny 'ホーム直下またはルートへの再帰 rm はブロックされています（bash-danger-gate）。'
  fi
fi

exit 0
