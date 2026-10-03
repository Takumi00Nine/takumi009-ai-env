#!/bin/bash
# codex-direct-call-gate.sh — PreToolUse(Bash) の Codex 直叩き柵（Team 接続／Claude Code）。
# 目的: codex exec / codex resume（execの別名eを含む）の直接実行を deny し、Codex の口（ラッパー）
#   経由だけを通す（v1.1 で危険コマンド柵のルール③から分けた。deny 文は分割前と同じ）。
# 導入経緯: 2026-09-06 codex exec 一本化（Claude CodeからのMCPサーバー経由呼び出しを廃止しラッパーに
#   一本化）。absolute-rules参照の機械強制はラッパー内部に移した（execはPreToolUseフックの対象外のため）
#   ため、ラッパーを経由しない直叩きが機械強制のバイパス経路にならないようここで塞ぐ。
#   ⚠️ 目的は「ラッパーを経由し忘れる事故の防止」であり、シェル構文を完全に解析してあらゆる回避策を
#   防ぎ切ることではない（残存限界は判定 py の docstring 参照）。
# 判定: 同じフォルダの codex_direct_call_check.py（shlex ベース）に委ねる。python3 が無い・
#   トークナイズに失敗した場合は、語境界の簡易正規表現へ fail-closed でフォールバックする
#   （`codex` と `exec`/`e`/`resume` が両方出現すれば deny する粗い判定＝過剰検知を許容）。
# 許可するラッパー: 台帳の鍵 team.codex-exec を Core の台帳ツールで照会する（上書き口 AIENV_LEDGER）。
#   鍵なし＝ラッパー無し＝直叩きは deny（fail-close）。台帳異常・実体異常＝deny し、照会の固定文を
#   deny 文に添えて stderr にも出す。
# 常に exit 0（deny は stdout の JSON・allow は無出力）。

CODEX_WRAPPER_KEY="team.codex-exec"

input=$(cat 2>/dev/null || true)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  exit 0
}

# installer はフックを個別 symlink するので、自身の symlink を解決した実体の位置から repo を引く。
_cdg_resolve_self_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
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
SELF_DIR="$(_cdg_resolve_self_dir)"
ROOT_DIR="$(cd -P "$SELF_DIR/../../.." && pwd)"

# 許可するラッパーの照会（stdout＝絶対パス・stderr＝固定文。行頭で読み分けられるので 1 本にまとめて受ける）。
wrapper="" ledger_msg=""
lookup_out="$(bash "$ROOT_DIR/core/assembly/ledger-tool.sh" lookup "$CODEX_WRAPPER_KEY" 2>&1)"
case $? in
  0) wrapper="$(printf '%s\n' "$lookup_out" | head -1)" ;;
  1) ;;
  *) ledger_msg="$(printf '%s\n' "$lookup_out" | head -1)" ;;
esac

_cdg_lib="$SELF_DIR/codex_direct_call_check.py"
codex_direct_call=0
_cdg_fallback_check() {
  printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])codex([^[:alnum:]_]|$)' || return 1
  printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(exec|e|resume)([^[:alnum:]_]|$)'
}
if command -v python3 >/dev/null 2>&1 && [ -f "$_cdg_lib" ]; then
  _cdg_result="$(printf '%s' "$cmd" | python3 "$_cdg_lib" ${wrapper:+"$wrapper"} 2>/dev/null)"
  case "$_cdg_result" in
    DENY) codex_direct_call=1 ;;
    ALLOW) codex_direct_call=0 ;;
    *) _cdg_fallback_check && codex_direct_call=1 ;;
  esac
else
  _cdg_fallback_check && codex_direct_call=1
fi
[ "$codex_direct_call" = "1" ] || exit 0

if [ -n "$wrapper" ]; then
  deny "Codex の起動は ${wrapper#"$ROOT_DIR"/} 経由のみです（absolute-rules の機械強制はラッパー内部にあります）。直接の codex exec / codex resume 呼び出しはブロックされています（bash-danger-gate）。"
fi
no_wrapper='Codex の起動ラッパーが台帳に無いため、直接の codex exec / codex resume 呼び出しはブロックされています（bash-danger-gate）。'
if [ -n "$ledger_msg" ]; then
  printf '%s\n' "$ledger_msg" >&2
  deny "$no_wrapper $ledger_msg"
fi
deny "$no_wrapper"
