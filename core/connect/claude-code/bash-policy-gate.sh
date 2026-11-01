#!/bin/bash
# PreToolUse(Bash): 公開ガード。deny JSON を返し、終了コードは常に0。

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

# R1 公開ガード（5 分岐）
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+repo[[:space:]]+create' && printf '%s' "$cmd" | grep -Eq -- '--public([[:space:]]|=|$)'; then
  deny 'PUBLIC_CREATE_DENIED: gh repo create --public。正本: ~/Data/obsidian/Preferences/absolute-rules.md ②・~/Data/obsidian/Preferences/git-workflow.md'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+repo[[:space:]]+edit' && printf '%s' "$cmd" | grep -Eqi -- '--visibility[[:space:]=]+public'; then
  deny 'PUBLIC_VISIBILITY_DENIED: gh repo edit --visibility public。正本: ~/Data/obsidian/Preferences/absolute-rules.md ②・~/Data/obsidian/Preferences/git-workflow.md'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+repo[[:space:]]+create' && ! printf '%s' "$cmd" | grep -Eq -- '--private([[:space:]]|=|$)'; then
  deny 'PRIVATE_ARGUMENT_MISSING: gh repo create の --private なし。正本: ~/Data/obsidian/Preferences/absolute-rules.md ②・~/Data/obsidian/Preferences/git-workflow.md'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+api' && printf '%s' "$cmd" | grep -Eqi 'visibility' && printf '%s' "$cmd" | grep -Eqi 'public'; then
  deny 'PUBLIC_API_DENIED: gh api visibility public。正本: ~/Data/obsidian/Preferences/absolute-rules.md ②・~/Data/obsidian/Preferences/git-workflow.md'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])(curl|wget)' && printf '%s' "$cmd" | grep -Eqi 'api.github.com' && printf '%s' "$cmd" | grep -Eqi 'visibility' && printf '%s' "$cmd" | grep -Eqi 'public'; then
  deny 'PUBLIC_HTTP_DENIED: curl/wget api.github.com visibility public。正本: ~/Data/obsidian/Preferences/absolute-rules.md ②・~/Data/obsidian/Preferences/git-workflow.md'
fi

exit 0
