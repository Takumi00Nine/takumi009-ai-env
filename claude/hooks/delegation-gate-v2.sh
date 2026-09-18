#!/bin/bash
# PreToolUse(Edit|Write|NotebookEdit): delegation-gate v2（リーダー直接実装ゲート）
#
# 目的: オーケストレーター（チームリーダー）が「作る工程」（実装・調査・テスト）を
# 自分でやらず、ワーカー/チームメイトへ委任する運用をツール境界で強制する。
# テキスト指示だけでは長いセッションで効きが切れる再発があったため、
# Knowledge/mistakes の一般則「テキストで効かない再発はツール境界でフック化する」を適用。
# 経緯: Decisions/2026-07-05-delegation-gate-v2 / 運用: Preferences/coding-delegation
#
# 判定順序（1→2→2.5→3→4→4m→5。2.5 のみ通過条件ではなく専用の deny 分岐）:
#   1) サブエージェント/ワーカー内の編集（agent_id/agent_type あり）＝ワーカーの仕事は正当 → 通過
#   2) チームメイトセッション（他チームの config.json に自 session_id が載る） → 通過
#   2.5) 外部脳（Vault）は 1)/2) を通過しなかった場合（＝リーダー）、専用マーカーが無い限り常に deny
#        （2026-08-12〜。汎用マーカー 5)・委任実績 4)/4m) では開かない）
#   3) 許可パス（~/.claude / tmp / 例外プロジェクト） → 通過
#   4) 自チームにリーダー以外のメンバーが存在（＝委任実績あり。名前付きチームメイトの例外運用のため残す） → 通過
#   4m) このセッションの委任マーカーが存在する（agent-model-guard.shがAgent起動のPASS時にtouch。
#       名前無しsubagentだけで運用するセッションでの委任実績＝設計v1.2 D-2・FR-25〜28） → 通過
#   5) 直接作業宣言マーカー（直接編集の理由をユーザーに明示してから touch） → 通過
#
# ⚠️ 旧rule 4b（$TMUXかつ任意のチームconfigに非リーダーのメンバーがいれば通過）はFR-38で撤去した
# （過去セッションのconfig.jsonが残っていると常時通過してしまう偽陽性=FM-2）。番号「4b」は再利用しない。
#
# 判定不能時は素通し（このゲートの目的は「委任の自問」であり防御ではない）。

# D-2（設計-v1.1.1.md §3・裁定A）: rule 2.5 の「対象がVaultのAI向け6フォルダ
# 配下か」の判定だけを guard_common.sh の guard_is_vault_ai_path へ委ねる
# （6フォルダの literal はそこにしか書かない＝NFR-7・AC-10②）。⚠️
# 振る舞い（マーカーの逃げ道・deny文面・rule 4mを含む他の判定順序）は
# 一切変えない（設計の絶対条件＝本ファイルは判定式の移設のみ）。
#
# 検証1巡目 I1-B1 対応: installer はこの3フックを1本ずつ
# `$HOME/.claude/hooks/<名前>.sh`（repoへのsymlink）として配置する
# （`$HOME/.claude/hooks/lib/`は作らない）ため、`BASH_SOURCE[0]%/*`だけでは
# 実運用経路でguard_common.shを解決できない。claude/hooks/inprocess-gate.sh
# の resolve_inprocess_gate_self_dir() と同じ方式（自身のsymlinkを解決した
# 実体ディレクトリ直下のlib/を見る）に揃える。source失敗時は fail-close＝
# rule 2.5 の対象かどうかを判定できないまま素通しにはせず、即denyしてexit 0
# （このゲート唯一のVault保護柵が無言で無効化される再発を防ぐ）。
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
  reason="delegation-gate: 共有部品（guard_common.sh・cause=$1）を読み込めず、Vault保護（rule 2.5）を判定できません。フックの配置を確認してください。"
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}
SELF_DIR="$(resolve_delegation_gate_self_dir 2>/dev/null)" || guard_common_load_error SELF_DIR_UNRESOLVABLE
[ -n "$SELF_DIR" ] || guard_common_load_error SELF_DIR_UNRESOLVABLE
# 検証2巡目 I2-M2 対応: env上書き口（GUARD_COMMON_LIB）は置かない（子が
# 持てない逃げ道になる＝裁定A「子に逃げ道を持たせない」に反するため撤去。
# テスト用の差し替えは、実体ディレクトリごとsymlinkする既存の方式で足りる）。
# shellcheck source=lib/guard_common.sh
source "$SELF_DIR/lib/guard_common.sh" 2>/dev/null || guard_common_load_error GUARD_COMMON_UNREADABLE

TEAMS_DIR="${GATE_TEAMS_DIR:-$HOME/.claude/teams}"
MARKER_DIR="${GATE_MARKER_DIR:-/tmp}"
ALLOW_PREFIXES=(
  # 外部脳($HOME/Data/obsidian)は 2026-08-12 本人指示で許可パスから除外
  # （執筆は vault-scribe 必須＝下の 2.5 で専用 deny）
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

# 2) チームメイトセッション（他チームの config に自 session_id）
if [ -d "$TEAMS_DIR" ]; then
  own_team="session-${sid:0:8}"
  for cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$cfg" ] || continue
    [ "$(basename "$(dirname "$cfg")")" = "$own_team" ] && continue
    grep -q "$sid" "$cfg" 2>/dev/null && exit 0
  done
fi

# 2.5) 外部脳（Vault）の AI向け6フォルダはリーダー直筆禁止（2026-08-12 本人指示＝「scribe不在時・
# 軽い1件は直筆可」の例外を撤廃／2026-08-13 本人指示＝適用範囲を AI向け6フォルダに限定。
# 人間向け領域＝Blogs/・Explorations/・機械生成物フォルダ等の6フォルダ以外は直接編集可）。
# 執筆は常駐チームメイト vault-scribe へ委任する
# （Decisions/2026-08-10-vault-scribe / Decisions/2026-08-12-vault-scribe-mandatory）。
# ワーカー/チームメイトは上の 1)/2) で既に通過済み＝ここに到達するのはリーダーのみ。
# 逃げ道は Vault 専用マーカーのみ（汎用マーカー 5)・委任実績 4)/4m) では開かない）。
if guard_is_vault_ai_path "$fpath"; then
  vault_marker="$MARKER_DIR/claude-vault-direct-ok-$sid"
  [ -f "$vault_marker" ] && exit 0
  reason="delegation-gate: 外部脳（Vault）の AI向け6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）への執筆は常駐チームメイト vault-scribe へ委任してください（Preferences/vault-operation。2026-08-12 本人指示で「軽い1件はリーダー直筆可」の例外は撤廃・2026-08-13 本人指示で対象は AI向け6フォルダに限定）。リーダーは内容を確定して vault-scribe へ渡す係です。vault-scribe 不在なら起動してから振る（Task toolのsubagent_typeは必ず\"vault-scribe\"を使う＝\"scribe\"という省略形は職種名・エージェント定義ファイル名のいずれとも一致せずspawn失敗する）。vault-scribe が使えない緊急時のみ、理由をユーザーへの応答で明示した上で次を実行してから再試行: touch $vault_marker"
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi

# 3) 許可パス
for p in "${ALLOW_PREFIXES[@]}"; do
  case "$fpath" in "$p"/*|"$p") exit 0 ;; esac
done

# 4) 自チームにリーダー以外のメンバーがいる＝委任実績あり
own_cfg="$TEAMS_DIR/session-${sid:0:8}/config.json"
if [ -f "$own_cfg" ]; then
  n_workers=$(jq '[.members[]? | select((.agentType // .agent_type // "") != "team-lead")] | length' "$own_cfg" 2>/dev/null)
  [ "${n_workers:-0}" -gt 0 ] 2>/dev/null && exit 0
fi

# 4m) このセッションの委任マーカーが存在する（FR-25〜28・FM-1対応）。
# 名前無し subagent だけで運用しているセッションでは 4) の自チーム config
# 照合（team-lead以外のmembers）が常に空振りする（名前無しsubagentは
# ~/.claude/teams/*/config.jsonにメンバーとして載らないため）。
# agent-model-guard.shがPreToolUse(Agent)のPASS時にセッション固有の
# マーカーをtouchする（OQ-4案B）ので、それが存在すれば「このセッションで
# 少なくとも1回委任が起きた」実績として通す。sidは既にL34で取得済み。
# FM-3: /resumeでsession_idが変わるとマーカー名も変わり実績は一旦空振りする
# が、そのセッションで最初にAgentを起動した時点で立ち直る（仕様）。
[ -f "$MARKER_DIR/claude-delegated-ok-$sid" ] && exit 0

# 5) 直接作業宣言マーカー
marker="$MARKER_DIR/claude-direct-edit-ok-$sid"
[ -f "$marker" ] && exit 0

# deny（自問を強制）
reason="delegation-gate: 実装・調査・テスト等の「作る工程」はチームメイト/Agentワーカーへ委任するのが既定です（Preferences/coding-delegation）。このセッションではまだ委任実績がありません。→ (a) チームメイト/ワーカーを起こしてタスクを振るか、(b) 直接編集が妥当な理由（リーダー自身の成果物への軽微な修正・ユーザーの明示指示・例外プロジェクト等。⚠️ワーカー作成の成果物への修正は理由にならない＝作成元ロールへ差し戻し、停止済みなら同ロールを再起動して委任＝Decisions/2026-08-14-deliverable-revision-by-creator）をユーザーへの応答で明示した上で、次を実行してから再試行してください: touch $marker"
jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
