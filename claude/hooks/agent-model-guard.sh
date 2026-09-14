#!/bin/bash

# PreToolUse: managed Agent roles must receive an explicit supported model alias.
# Bash 3.2 compatible; denial is returned as hook JSON with exit 0.

deny() {
  reason=$1
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

guard_error() {
  deny "MODEL_GUARD_ERROR: cause=$1; model 指定を検査できません。フックの入力と配置を確認してください。"
}

command -v jq >/dev/null 2>&1 || guard_error JQ_UNAVAILABLE

input=$(cat)
[ -n "$input" ] || guard_error INPUT_INVALID

# 締めレビュー1巡目 #1対応（2026-09-14）: CLAUDE_CODE_SUBAGENT_MODEL_FORCE は
# 公式ドキュメント（https://code.claude.com/docs/en/model-config,
# https://code.claude.com/docs/en/sub-agents#run-every-subagent-on-one-model）
# により、per-invocation model（Agent.model引数）や定義側のmodel（inherit含む）
# より優先し上書きする。settings.jsonのenvブロックで設定された値もこのフック
# の実行環境にそのまま継承されるため、このシェル変数で観測できる。非FORCE版
# のCLAUDE_CODE_SUBAGENT_MODELはper-invocation/定義側を上書きしない（公式に
# 明記）ため検査しない。値の意味（"1"/"true"などの真偽表現）は同ドキュメント
# 群を確認しても本フック用の解釈規約が明文化されておらず、fail-closedの既存
# 流儀に合わせ「非空なら常にoverrideの可能性あり」としてdenyする（誤ってオフ
# 値〈例: "0"〉を設定した場合も安全側でdenyする）。
force_override_env="${CLAUDE_CODE_SUBAGENT_MODEL_FORCE-}"

result=$(printf '%s' "$input" | jq -rs --arg force "$force_override_env" '
  if length != 1 or (.[0] | type) != "object" then "ERROR:INPUT_INVALID"
  else .[0] as $event |
    if ($event | has("tool_name") | not) then "ERROR:TOOL_NAME_MISSING"
    elif $event.tool_name == null then "ERROR:TOOL_NAME_NULL"
    elif ($event.tool_name | type) != "string" then "ERROR:TOOL_NAME_TYPE"
    elif $event.tool_name == "" then "ERROR:TOOL_NAME_EMPTY"
    elif $event.tool_name != "Agent" then "ERROR:TOOL_NAME_UNEXPECTED"
    elif ($event.tool_input | type) != "object" then "ERROR:TOOL_INPUT_INVALID"
    elif ($event.tool_input.subagent_type | type) != "string" or $event.tool_input.subagent_type == "" then "ERROR:TOOL_INPUT_INVALID"
    elif (["adoption-critic","implementer","operator","requirements-analyst","researcher","system-designer","vault-scribe","verifier"] | index($event.tool_input.subagent_type)) == null then "PASS"
    elif $force != "" then "FORCE_OVERRIDE"
    elif ($event.tool_input | has("model") | not) then "REQUIRED"
    elif ($event.tool_input.model | type) == "string" and (["fable","opus","sonnet","haiku"] | index($event.tool_input.model)) != null then "PASS"
    else "INVALID"
    end
  end
' 2>/dev/null) || guard_error JQ_FAILED

case "$result" in
  PASS) exit 0 ;;
  REQUIRED)
    deny 'MODEL_ARGUMENT_REQUIRED: resolve-candidate の AGENT_MODEL を Agent.model に明示してください。'
    ;;
  INVALID)
    deny 'MODEL_ARGUMENT_INVALID: Agent.model は resolve-candidate が返した4別名のいずれかを明示してください。'
    ;;
  FORCE_OVERRIDE)
    deny 'MODEL_ENV_OVERRIDE_FORBIDDEN: 環境変数 CLAUDE_CODE_SUBAGENT_MODEL_FORCE が設定されています。Agent.model の指定を上書きする可能性があるため、解除してから再実行してください。'
    ;;
  ERROR:*) guard_error "${result#ERROR:}" ;;
  *) guard_error JQ_FAILED ;;
esac
