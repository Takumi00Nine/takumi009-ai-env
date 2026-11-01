#!/bin/bash
# PreToolUse(Edit|Write|NotebookEdit): delegation-gate v2（リーダー直接実装ゲート）
#
# 目的: オーケストレーター（チームリーダー）が「作る工程」（実装・調査・テスト）を
# 自分でやらず、ワーカー/チームメイトへ委任する運用をツール境界で強制する。
# テキスト指示だけでは長いセッションで効きが切れる再発があったため、
# Knowledge/mistakes の一般則「テキストで効かない再発はツール境界でフック化する」を適用。
# 経緯: Decisions/2026-07-05-delegation-gate-v2 / 運用: Preferences/coding-delegation
#
# 判定順序（1→2.5→3→4m→5）:
#   1) サブエージェント/ワーカー内の編集（agent_id/agent_type あり）＝ワーカーの仕事は正当 → 通過
#   2.5) 外部脳（Vault）の AI 向け6フォルダ＝通過（リーダー直筆可・2026-10-04 本人決定）
#   3) 許可パス（~/.claude / tmp / 例外プロジェクト） → 通過
#   4m) このセッションの委任マーカーが存在する（inprocess-gate.shがAgent起動のPASS時にtouch。
#       名前無しsubagentだけで運用するセッションでの委任実績＝設計v1.2 D-2・FR-25〜28） → 通過
#   5) 直接作業宣言マーカー（直接編集の理由をユーザーに明示してから touch） → 通過
#
# ⚠️ 旧rule 4b（$TMUXかつ任意のチームconfigに非リーダーのメンバーがいれば通過）はFR-38で撤去した
# （過去セッションのconfig.jsonが残っていると常時通過してしまう偽陽性=FM-2）。番号「4b」は再利用しない。
#
# 判定不能時は素通し（このゲートの目的は「委任の自問」であり防御ではない）。

# D-2（設計-v1.1.1.md §3・裁定A）: rule 2.5 の「対象がVaultのAI向け6フォルダ
# 配下か」の判定だけを Core の core/executor/vault-paths.sh の guard_is_vault_ai_path へ委ねる
# （6フォルダの literal はそこにしか書かない＝NFR-7・AC-10②）。
#
# 検証1巡目 I1-B1 対応: installer はこの3フックを1本ずつ
# `$HOME/.claude/hooks/<名前>.sh`（repoへのsymlink）として配置する
# （`$HOME/.claude/hooks/lib/`は作らない）ため、`BASH_SOURCE[0]%/*`だけでは
# 実運用経路で共有部品を解決できない。自身のsymlinkを解決した実体ディレクトリ
# から repo 内の相対位置（core/executor/）を見る。source失敗時は fail-close＝
# rule 2.5 の対象かどうかを判定できないまま素通しにはせず、即denyしてexit 0
# （rule 2.5 の対象判定ができないまま 3〜5 へ進む誤判定を防ぐ）。
resolve_delegation_gate_self_dir() {
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
guard_common_load_error() {
  reason="delegation-gate: vault-paths.sh 読込失敗・cause=$1・rule 2.5 判定不能。正本: ~/Data/obsidian/Preferences/coding-delegation.md"
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}
SELF_DIR="$(resolve_delegation_gate_self_dir 2>/dev/null)" || guard_common_load_error SELF_DIR_UNRESOLVABLE
[ -n "$SELF_DIR" ] || guard_common_load_error SELF_DIR_UNRESOLVABLE
# 検証2巡目 I2-M2 対応: env上書き口（GUARD_COMMON_LIB）は置かない（子が
# 持てない逃げ道になる＝裁定A「子に逃げ道を持たせない」に反するため撤去。
# テスト用の差し替えは、実体ディレクトリごとsymlinkする既存の方式で足りる）。
# shellcheck source=../../../core/executor/vault-paths.sh
source "$SELF_DIR/../../../core/executor/vault-paths.sh" 2>/dev/null || guard_common_load_error GUARD_COMMON_UNREADABLE

MARKER_DIR="${GATE_MARKER_DIR:-/tmp}"
ALLOW_PREFIXES=(
  # Vault はここへ足さない（AI 向け6フォルダは 2.5 で通過・それ以外は 3〜5 で判定）。
  "$HOME/.claude"             # 自環境の設定・フック
  "$HOME/.claude.json"        # Claude Code 本体設定（~/.claude/ の外にあるが同じ設定ドメイン。2026-07-05 追加）
  "/tmp"                      # scratchpad・一時ファイル
  "/private/tmp"
)
# takumi009-web の例外は 2026-07-05 夜に本人指示で撤回（通常のワーカー委任体制へ復帰）

INPUT=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
agent_id=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
agent_type=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
fpath=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)

# 1) サブエージェント/ワーカー内の編集
{ [ -n "$agent_id" ] || [ -n "$agent_type" ]; } && exit 0

# 判定材料が無ければ素通し（安全側）
[ -z "$sid" ] && exit 0
[ -z "$fpath" ] && exit 0

# 相対パスは cwd で絶対化
case "$fpath" in
  /*) : ;;
  *) fpath="${cwd%/}/$fpath" ;;
esac

# 2.5) 外部脳（Vault）は軽重に関係なくリーダーが直筆する。ワーカーは記録候補を
# 最終報告で申告する＝役割の規則で守る。AI 向け6フォルダを通す判定は維持する。
# 判定式は vault-paths.sh の
# guard_is_vault_ai_path（6フォルダの literal はそこだけ）。
if guard_is_vault_ai_path "$fpath"; then
  exit 0
fi

# 3) 許可パス
for p in "${ALLOW_PREFIXES[@]}"; do
  case "$fpath" in "$p"/*|"$p") exit 0 ;; esac
done

# 4m) inprocess-gate またはラッパーが付けた、このセッションの委任マーカー。
[ -f "$MARKER_DIR/claude-delegated-ok-$sid" ] && exit 0

# 5) 直接作業宣言マーカー
marker="$MARKER_DIR/claude-direct-edit-ok-$sid"
[ -f "$marker" ] && exit 0

# deny（自問を強制）
reason="delegation-gate: 委任実績なし・marker=$marker・command=touch $marker。正本: ~/Data/obsidian/Preferences/coding-delegation.md"
jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
