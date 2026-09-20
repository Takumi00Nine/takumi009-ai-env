#!/bin/bash

# PreToolUse: managed Agent roles must receive an explicit supported model alias.
# Bash 3.2 compatible; denial is returned as hook JSON with exit 0.
#
# D-2（設計-v1.1.1.md §3）: 許容別名の集合と委任実績マーカーの置き方は
# claude/hooks/lib/guard_common.sh を正本とし、ここでは複製しない（NFR-7・
# AC-10②）。判定式（^Agent$・管理職種・FORCE_OVERRIDE の扱い）自体は変えない。
#
# D-1（roles-config-only 設計 v1.2 §2）: 管理職種の集合はコード内に列挙せず、
# 自身の実体パスから解決した repo claude/agents/ 直下の *.md（`-f` で見える
# 実体＝symlink は辿る・dangling は数えない）のファイル名そのものとする。
# 内容は読まない。一覧が取れない／空のときは fail-close（AGENTS_DIR_UNREADABLE
# ／AGENTS_DIR_EMPTY で deny）。名前は jq の --args で JSON 配列として渡す。
#
# D-2（設計v1.2 §3.1〜§3.2・OQ-4案B）: 名前無し subagent だけで運用する
# セッションでも delegation-gate-v2.sh が「委任実績あり」と認められるよう、
# PASS分岐でセッション固有マーカーを touch する。マーカーの置き場所
# （GATE_MARKER_DIR で差し替え可）と名前の規則は guard_common.sh の
# guard_marker_path/guard_mark_delegation が正本を持つ（設計-v1.1.1.md §3）。

deny() {
  reason=$1
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

guard_error() {
  deny "MODEL_GUARD_ERROR: cause=$1; model 指定を検査できません。フックの入力と配置を確認してください。"
}

# 検証1巡目 I1-B1 対応: installer はこの3フックを1本ずつ
# `$HOME/.claude/hooks/<名前>.sh`（repoへのsymlink）として配置する
# （`$HOME/.claude/hooks/lib/`は作らない）ため、`BASH_SOURCE[0]%/*`だけでは
# 実運用経路でguard_common.shを解決できない。claude/hooks/inprocess-gate.sh
# の resolve_inprocess_gate_self_dir() / claude/hooks/usage-inject.sh の
# resolve_usage_inject_self_dir() と同じ方式（自身のsymlinkを解決した実体
# ディレクトリ直下のlib/を見る）に揃える。source失敗（自己解決不能・
# guard_common.shが読めない等）は fail-close（guard_errorでdenyしてexit 0＝
# 無言で続行しない）。
resolve_agent_model_guard_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
SELF_DIR="$(resolve_agent_model_guard_self_dir 2>/dev/null)" || guard_error SELF_DIR_UNRESOLVABLE
[ -n "$SELF_DIR" ] || guard_error SELF_DIR_UNRESOLVABLE
# 検証2巡目 I2-M2 対応: env上書き口（GUARD_COMMON_LIB）は置かない（子が
# 持てない逃げ道になる＝裁定A「子に逃げ道を持たせない」に反するため撤去。
# テスト用の差し替えは、実体ディレクトリごとsymlinkする既存の方式で足りる）。
# shellcheck source=lib/guard_common.sh
source "$SELF_DIR/lib/guard_common.sh" 2>/dev/null || guard_error GUARD_COMMON_UNREADABLE

command -v jq >/dev/null 2>&1 || guard_error JQ_UNAVAILABLE

input=$(cat)
[ -n "$input" ] || guard_error INPUT_INVALID

# D-1（設計 v1.2 §2.1）: 管理職種の一覧＝repo claude/agents/ 直下の *.md。
# SELF_DIR は <repo>/claude/hooks の物理パスなので、`..` を使わず文字列で
# 1 段上がる。配布先 ~/.claude/agents/ と $HOME は読まない。env 差替口は
# 置かない（I2-M2 裁定の継続・テストは複製配置で差し替える）。
# 一覧は tool_name に関係なく毎回評価する（破損した配置では Agent 起動を
# 全部止める＝fail-close）。外部コマンド（ls・find）は使わない（HF-03 の
# 「jq だけ無い PATH」でも同じ経路を通る）。
AGENTS_DIR="${SELF_DIR%/*}/agents"
{ [ -d "$AGENTS_DIR" ] && [ -r "$AGENTS_DIR" ] && [ -x "$AGENTS_DIR" ]; } || guard_error AGENTS_DIR_UNREADABLE
managed_roles=()
for _agent_file in "$AGENTS_DIR"/*.md; do
  # [ -f ] は symlink を辿る（profile_resolve.py の os.path.isfile・installer
  # の -e と同じ見え方）。dangling symlink・ディレクトリ・glob 不一致時の
  # リテラル "*.md" はいずれも偽＝数えない。
  [ -f "$_agent_file" ] || continue
  _agent_name="${_agent_file##*/}"
  managed_roles+=("${_agent_name%.md}")
done
[ "${#managed_roles[@]}" -gt 0 ] || guard_error AGENTS_DIR_EMPTY

# セッション固有マーカーの名前に使う session_id を1回だけ取り出す（判定
# ロジックの`jq -rs`とは別口・既存の判定式は一切変えない）。
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)

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

# D-1: 管理職種は $ARGS.positional（--args で渡した JSON 配列。空白入りの名前
# も 1 要素のまま）。--args は以降の引数を全部 positional にするので末尾に置く。
result=$(printf '%s' "$input" | jq -rs --arg force "$force_override_env" --arg aliases "$(guard_allowed_model_aliases)" '
  if length != 1 or (.[0] | type) != "object" then "ERROR:INPUT_INVALID"
  else .[0] as $event |
    if ($event | has("tool_name") | not) then "ERROR:TOOL_NAME_MISSING"
    elif $event.tool_name == null then "ERROR:TOOL_NAME_NULL"
    elif ($event.tool_name | type) != "string" then "ERROR:TOOL_NAME_TYPE"
    elif $event.tool_name == "" then "ERROR:TOOL_NAME_EMPTY"
    elif $event.tool_name != "Agent" then "ERROR:TOOL_NAME_UNEXPECTED"
    elif ($event.tool_input | type) != "object" then "ERROR:TOOL_INPUT_INVALID"
    elif ($event.tool_input.subagent_type | type) != "string" or $event.tool_input.subagent_type == "" then "ERROR:TOOL_INPUT_INVALID"
    elif ($ARGS.positional | index($event.tool_input.subagent_type)) == null then "PASS"
    elif $force != "" then "FORCE_OVERRIDE"
    elif ($event.tool_input | has("model") | not) then "REQUIRED"
    elif ($event.tool_input.model | type) == "string" and (($aliases | split(" ")) | index($event.tool_input.model)) != null then "PASS"
    else "INVALID"
    end
  end
' --args "${managed_roles[@]}" 2>/dev/null) || guard_error JQ_FAILED

case "$result" in
  PASS)
    # FR-25〜FR-28（要件v1.2.1・OQ-4案B）: 委任実績のsource of truth。
    # deny・guard_errorの分岐には置かない（拒否されたspawnではマーカーを
    # 立てない）。書き込み失敗は握り潰してexit 0（FM-D8・ガードはspawnを
    # 止めない・guard_mark_delegationが内部で同じ流儀を守る）。
    guard_mark_delegation "$sid"
    exit 0
    ;;
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
