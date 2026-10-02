#!/bin/bash
# bash-danger-gate.sh — PreToolUse(Bash) の危険コマンド deny ゲート
# 目的: プロンプトインジェクション等で騙されても、ツール境界で破壊的コマンドを実行不能にする最終防衛線。
#   ①リモートスクリプトのパイプ実行（curl/wget → shell）を無条件 deny
#   ②保護パス（Vault・~/.claude・~/.codex・~/.cmuxterm・HOME直下・/）への再帰 rm を deny
#   （分割前の ③ Codex の直接実行の deny は v1.1 で Team の Codex 直叩き柵へ分けた）
# 導入経緯: 2026-07-19 偽 system_warning 注入インシデント（Fragments/2026-07/2026-07-19）

input=$(cat 2>/dev/null || true)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

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

# ② 再帰 rm（rm -r/-R/--recursive）× 保護パス（HOME 直下の実パス基準＋相対形は cwd/cd 判定）
if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'; then
  prot='(Data/obsidian|\.claude|\.codex|\.cmuxterm)'
  home_pfx='(~|"?\$\{?HOME\}?"?|/Users/[^/[:space:]]+)'
  tail='([^[:alnum:]_.-]|$)'
  # 照合前の正規化: `/./`・`//` を `/` に潰す（`~/./.claude`・`~//.claude` の迂回を塞ぐ）。
  # 照合は大小無区別（APFS は大小無区別＝`/users/<u>/.claude` でも実削除される）。
  # brace（`~/{.claude,.codex}`）は `home_pfx/` 直後の `{...` を許して拾う。glob（`~/.cl*`）は既知の残存限界。
  ncmd=$(printf '%s' "$cmd" | sed -E 's#/(\./)+#/#g; s#/{2,}#/#g')
  # ②-a 絶対形: HOME 直下の保護ディレクトリそのもの・またはその配下（末尾が英数・_・.・- 以外）
  if printf '%s' "$ncmd" | grep -Eqi "${home_pfx}/(\{[^}]*)?${prot}${tail}"; then
    deny '保護パス（~/Data/obsidian・~/.claude・~/.codex・~/.cmuxterm）への再帰 rm は拒否しました。必要なら本人が手で実行してください（bash-danger-gate）。'
  fi
  # ②-b 相対形: cwd が HOME、または同じコマンド内で HOME へ cd している時だけ、裸の保護名を見る
  in_home=0
  [ -n "$cwd" ] && [ "${cwd%/}" = "${HOME%/}" ] && in_home=1
  printf '%s' "$ncmd" | grep -Eqi "(^|[;&|[:space:]])cd([[:space:]]+${home_pfx}/?)?[[:space:]]*(;|&|\||$)" && in_home=1
  if [ "$in_home" = 1 ] && printf '%s' "$ncmd" | grep -Eqi "(^|[[:space:]\"'=])(\./)?${prot}${tail}"; then
    deny '保護パス（~/Data/obsidian・~/.claude・~/.codex・~/.cmuxterm）への再帰 rm は拒否しました。必要なら本人が手で実行してください（bash-danger-gate）。'
  fi
  # HOME 直下・ルートへの再帰 rm（rm -rf ~ / rm -rf /）
  if printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]]+("?\$HOME"?|~)?/?([[:space:]]|$)'; then
    deny 'ホーム直下またはルートへの再帰 rm はブロックされています（bash-danger-gate）。'
  fi
fi

exit 0
