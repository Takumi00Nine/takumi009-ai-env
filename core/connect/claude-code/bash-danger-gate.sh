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
  deny 'REMOTE_PIPE_DENIED: curl/wget | shell。正本: ~/Data/obsidian/Preferences/absolute-rules.md・~/Data/obsidian/Preferences/core-worker.md §5'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(bash|sh|zsh)[[:space:]]+<\([[:space:]]*(curl|wget)'; then
  deny 'REMOTE_SUBSTITUTION_DENIED: shell process substitution curl/wget。正本: ~/Data/obsidian/Preferences/absolute-rules.md・~/Data/obsidian/Preferences/core-worker.md §5'
fi

# cat だけの heredoc は、終端が見つかった場合だけ本文を②の照合から除く。
rm_cmd=$(printf '%s' "$cmd" | python3 -c '
import re, sys
original = sys.stdin.read()
lines = original.splitlines(keepends=True)
output = []
redirect = r"(?:>>?\s*[A-Za-z0-9_./-]+\s*)?"
opening = re.compile(r"^\s*cat\s+" + redirect + r"<<(-?)\s*(?:\"(\w+)\"|\x27(\w+)\x27|(\w+))\s*" + redirect + r"$")
i = 0
while i < len(lines):
    # 他コマンド・展開・行継続などを含む形は除外しない。
    match = opening.fullmatch(lines[i].rstrip("\n"))
    if not match and "<<" in lines[i]:
        sys.stdout.write(original)
        sys.exit(0)
    if match:
        delimiter = next(word for word in match.groups()[1:] if word is not None)
        end = i + 1
        while end < len(lines):
            line = lines[end].rstrip("\n")
            if match[1]:
                line = line.lstrip("\t")
            if line == delimiter:
                break
            end += 1
        if end == len(lines):
            sys.stdout.write(original)
            sys.exit(0)
        output.append(lines[i])
        i = end + 1
        continue
    output.append(lines[i])
    i += 1
sys.stdout.write("".join(output))
') || rm_cmd=$cmd

# ② 再帰 rm（rm -r/-R/--recursive）× 保護パス（HOME 直下の実パス基準＋相対形は cwd/cd 判定）
if printf '%s' "$rm_cmd" | grep -Eq '(^|[;&|[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'; then
  prot='(Data/obsidian|\.claude|\.codex|\.cmuxterm)'
  home_pfx='(~|"?\$\{?HOME\}?"?|/Users/[^/[:space:]]+)'
  tail='([^[:alnum:]_.-]|$)'
  # 照合前の正規化: `/./`・`//` を `/` に潰す（`~/./.claude`・`~//.claude` の迂回を塞ぐ）。
  # 照合は大小無区別（APFS は大小無区別＝`/users/<u>/.claude` でも実削除される）。
  # brace（`~/{.claude,.codex}`）は `home_pfx/` 直後の `{...` を許して拾う。glob（`~/.cl*`）は既知の残存限界。
  ncmd=$(printf '%s' "$rm_cmd" | sed -E 's#/(\./)+#/#g; s#/{2,}#/#g')
  # ②-a 絶対形: HOME 直下の保護ディレクトリそのもの・またはその配下（末尾が英数・_・.・- 以外）
  if printf '%s' "$ncmd" | grep -Eqi "${home_pfx}/(\{[^}]*)?${prot}${tail}"; then
    deny 'PROTECTED_RM_DENIED: ~/Data/obsidian・~/.claude・~/.codex・~/.cmuxterm への再帰 rm。正本: ~/Data/obsidian/Preferences/absolute-rules.md・~/Data/obsidian/Preferences/core-worker.md §5'
  fi
  # ②-b 相対形: cwd が HOME、または同じコマンド内で HOME へ cd している時だけ、裸の保護名を見る
  in_home=0
  [ -n "$cwd" ] && [ "${cwd%/}" = "${HOME%/}" ] && in_home=1
  printf '%s' "$ncmd" | grep -Eqi "(^|[;&|[:space:]])cd([[:space:]]+${home_pfx}/?)?[[:space:]]*(;|&|\||$)" && in_home=1
  if [ "$in_home" = 1 ] && printf '%s' "$ncmd" | grep -Eqi "(^|[[:space:]\"'=])(\./)?${prot}${tail}"; then
    deny 'PROTECTED_RM_DENIED: ~/Data/obsidian・~/.claude・~/.codex・~/.cmuxterm への再帰 rm。正本: ~/Data/obsidian/Preferences/absolute-rules.md・~/Data/obsidian/Preferences/core-worker.md §5'
  fi
  # HOME 直下・ルートへの再帰 rm（rm -rf ~ / rm -rf /）
  if printf '%s' "$rm_cmd" | grep -Eq 'rm[[:space:]]+-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]]+("?\$HOME"?|~)?/?([[:space:]]|$)'; then
    deny 'HOME_ROOT_RM_DENIED: HOME または / への再帰 rm。正本: ~/Data/obsidian/Preferences/absolute-rules.md・~/Data/obsidian/Preferences/core-worker.md §5'
  fi
fi

exit 0
