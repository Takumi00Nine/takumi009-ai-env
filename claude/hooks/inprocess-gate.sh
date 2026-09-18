#!/bin/bash

# PreToolUse: in-process Agent 起動の境界（ラッパー起動-設計-v1.1.1.md
# §4.2・要件FR-21・FR-22・D-3）。配役表に職種行がある職種のin-process
# 起動（Agentツール）を拒否し、scripts/claude-exec.sh 経由へ誘導する。
# agent-model-guard.sh と同じ event（PreToolUse・matcher "^Agent$"）に
# 2本並ぶ（どちらかがdenyすればdeny＝claude/settings.json）。
#
# ⚠️ 配役表を自前で解析しない（AC-18⑤）。判定・監査の根拠は
# `profile_resolve.py check-inprocess` の口が返す6フィールドのJSONだけを
# 使う（本ファイルが読むのはこのJSONの各フィールドだけ。$AIENV_LOCAL_
# PROFILE_PATH は口へ渡す引数としてしか使わない）。
# fail-close（設計§4.1・4.3・DR1-M5）＝口が非0で終わる・不正JSONを返す・
# 必須フィールドが欠ける・30秒で返らない場合はすべてdenied
#（PROFILE_UNRESOLVED相当）。
#
# Bash 3.2 compatible（macOSシステムbash・連想配列不使用）。
#
# 環境変数（すべてテスト用に上書き可。本番は既定値のまま呼べばよい）:
#   PROFILE_RESOLVE_LIB            … 口の実体（既定 $SELF_DIR/lib/profile_resolve.py）
#   AIENV_LOCAL_PROFILE_PATH       … 配役表（既定 $HOME/.config/takumi009-ai-env/profile.md）
#   AIENV_INPROCESS_AUDIT_LOG      … 監査ログ（既定 $HOME/.claude/logs/inprocess-audit.jsonl）
#   AIENV_INPROCESS_PORT_TIMEOUT_SECS … 口の呼び出し期限秒数（既定 30）
#   AIENV_PYTHON_BIN               … python3 実行体（既定 python3）

# claude/hooks/check-sub-update.sh の resolve_check_sub_update_self_dir() と
# 同じ方式（installerはhookを1本ずつsymlinkしており~/.claude/hooks/lib/は
# 存在しないため、本フック自身のsymlinkを解決した実体ディレクトリ直下の
# lib/を見る＝判定式を2箇所に増やさない）。
resolve_inprocess_gate_self_dir() {
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
SELF_DIR="$(resolve_inprocess_gate_self_dir)"
: "${PROFILE_RESOLVE_LIB:=$SELF_DIR/lib/profile_resolve.py}"
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
: "${AIENV_INPROCESS_AUDIT_LOG:=$HOME/.claude/logs/inprocess-audit.jsonl}"
: "${AIENV_INPROCESS_PORT_TIMEOUT_SECS:=30}"
: "${AIENV_PYTHON_BIN:=python3}"

deny() {
  # jqが無い/失敗した場合のフォールバックは$1（roleを含みうる）を補間しない
  # 固定文にする（printfの%sへ生埋め込みするとJSONが壊れうるため。I2-M1）。
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null \
    || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"IN_PROCESS_BLOCKED: jqが利用できないため判定できません（判定不能・fail-close）。scripts/claude-exec.sh 経由で起動してください。"}}'
  exit 0
}

# 口が失敗したとき・fail-closeで使う既定の6フィールド（reason_code以外
# すべてnull＝FR-22の口自身の契約と同じ形）。
UNRESOLVED_PORT_JSON='{"allowed":false,"role_present":null,"role_state":null,"candidate_count":null,"profile_revision":null,"reason_code":"PROFILE_UNRESOLVED"}'

# write_audit_line <role> <decision> <port_json> — 監査1行を追記する
# （FR-21）。キー＝ts・type(inprocess_attempt)・role・decision＋口の6
# フィールドを平たく載せる。書けなければ非0（呼び出し側がfail-closeへ倒す）。
write_audit_line() {
  local role="$1" decision="$2" port_json="$3"
  local dir
  dir="$(dirname "$AIENV_INPROCESS_AUDIT_LOG")"
  mkdir -p "$dir" 2>/dev/null || return 1
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)"
  local line
  line="$(printf '%s' "$port_json" | jq -c --arg ts "$ts" --arg role "$role" --arg decision "$decision" \
    '. + {ts:$ts, type:"inprocess_attempt", role:$role, decision:$decision}' 2>/dev/null)"
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" >> "$AIENV_INPROCESS_AUDIT_LOG" 2>/dev/null
}

# fail_close [role] — denyの唯一の出口（判定不能はすべてここへ集約）。
# roleが取れていなくても監査を試みる（「書けるなら1行」＝設計§4.3）。
fail_close() {
  write_audit_line "${1:-}" "denied" "$UNRESOLVED_PORT_JSON"
  deny 'IN_PROCESS_BLOCKED: 配役表を解決できません（判定不能・fail-close）。scripts/claude-exec.sh 経由で起動してください。'
}

command -v jq >/dev/null 2>&1 || fail_close ""

input="$(cat)"
[ -n "$input" ] || fail_close ""

# tool_name/subagent_typeの取り出しだけを行う（配役表には一切触れない）。
parsed="$(printf '%s' "$input" | jq -rs '
  if length != 1 or (.[0] | type) != "object" then "ERROR"
  else .[0] as $e |
    if ($e.tool_name // "") != "Agent" then "SKIP"
    elif ($e.tool_input | type) != "object" then "ERROR"
    elif ($e.tool_input.subagent_type | type) != "string" or ($e.tool_input.subagent_type // "") == "" then "ERROR"
    else "ROLE:" + $e.tool_input.subagent_type
    end
  end
' 2>/dev/null)"
[ -n "$parsed" ] || fail_close ""

case "$parsed" in
  SKIP)
    exit 0
    ;;
  ROLE:*)
    role="${parsed#ROLE:}"
    ;;
  *)
    fail_close ""
    ;;
esac

# 口を30秒の期限つきで呼ぶ。macOSシステムbashにtimeout(1)が無いため、
# 背景起動＋0.1秒ポーリングで自前実装する（scripts/claude-exec.sh §2.7と
# 同じ考え方＝timeoutコマンドに依存しない）。刻みは0.1秒単位（elapsed_ds
# はdeciseconds）＝口は通常0.1秒台で返るため、1秒刻みだとAgentツールを
# 使うたび最大約1秒の固定費が乗ってしまうのを避ける。期限の30秒は不変。
PORT_OUT="$(mktemp 2>/dev/null)" || fail_close "$role"
"$AIENV_PYTHON_BIN" "$PROFILE_RESOLVE_LIB" check-inprocess "$AIENV_LOCAL_PROFILE_PATH" --subagent-type "$role" >"$PORT_OUT" 2>/dev/null &
port_pid=$!
elapsed_ds=0
# 非整数（例 30.5）が来ると次の掛け算がその場で算術エラー終了し無言の
# 素通しになるため、整数でなければ既定30秒へ正規化する（I2-m6）。
case "$AIENV_INPROCESS_PORT_TIMEOUT_SECS" in
  ''|*[!0-9]*) AIENV_INPROCESS_PORT_TIMEOUT_SECS=30 ;;
esac
timeout_ds=$((AIENV_INPROCESS_PORT_TIMEOUT_SECS * 10))
port_rc=""
while kill -0 "$port_pid" 2>/dev/null; do
  if [ "$elapsed_ds" -ge "$timeout_ds" ]; then
    kill -TERM "$port_pid" 2>/dev/null
    sleep 1
    kill -KILL "$port_pid" 2>/dev/null
    port_rc=124
    break
  fi
  sleep 0.1
  elapsed_ds=$((elapsed_ds + 1))
done
if [ -z "$port_rc" ]; then
  wait "$port_pid" 2>/dev/null
  port_rc=$?
fi
port_json="$(cat "$PORT_OUT" 2>/dev/null)"
rm -f "$PORT_OUT" 2>/dev/null

if [ "$port_rc" -ne 0 ]; then
  fail_close "$role"
fi

valid="$(printf '%s' "$port_json" | jq -e '
  (type=="object") and
  (has("allowed") and has("role_present") and has("role_state") and has("candidate_count") and has("profile_revision") and has("reason_code"))
' >/dev/null 2>&1 && echo yes)"
[ "$valid" = "yes" ] || fail_close "$role"

allowed="$(printf '%s' "$port_json" | jq -r '.allowed' 2>/dev/null)"

if [ "$allowed" = "true" ]; then
  if write_audit_line "$role" "allowed" "$port_json"; then
    exit 0
  fi
  # 記録できない許可は出さない（FR-23②が恒真になるのを防ぐ＝設計§4.3）。
  deny 'IN_PROCESS_BLOCKED: 監査ログを書き込めません。scripts/claude-exec.sh 経由で起動してください。'
fi

write_audit_line "$role" "denied" "$port_json"
deny "IN_PROCESS_BLOCKED: role=${role} は配役表の職種として登録されています。Agentツールでのin-process起動は使えません。scripts/claude-exec.sh --role ${role} … で起動してください。"
