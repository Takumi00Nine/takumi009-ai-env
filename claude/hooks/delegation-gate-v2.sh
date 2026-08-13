#!/bin/bash
# PreToolUse(Edit|Write|NotebookEdit): delegation-gate v2（リーダー直接実装ゲート）
#
# 目的: オーケストレーター（チームリーダー）が「作る工程」（実装・調査・テスト）を
# 自分でやらず、ワーカー/チームメイトへ委任する運用をツール境界で強制する。
# テキスト指示だけでは長いセッションで効きが切れる再発があったため、
# Knowledge/mistakes の一般則「テキストで効かない再発はツール境界でフック化する」を適用。
# 経緯: Decisions/2026-07-05-delegation-gate-v2 / 運用: Preferences/coding-delegation
#
# 判定順序（1→2→2.5→3→4→4b→5。2.5 のみ通過条件ではなく専用の deny 分岐）:
#   1) サブエージェント/ワーカー内の編集（agent_id/agent_type あり）＝ワーカーの仕事は正当 → 通過
#   2) チームメイトセッション（他チームの config.json に自 session_id が載る） → 通過
#   2.5) 外部脳（Vault）は 1)/2) を通過しなかった場合（＝リーダー）、専用マーカーが無い限り常に deny
#        （2026-08-12〜。汎用マーカー 5)・委任実績 4)/4b) では開かない）
#   3) 許可パス（~/.claude / tmp / 例外プロジェクト） → 通過
#   4) 自チームにリーダー以外のメンバーが存在（＝委任実績あり。以後のレビュー反映等は素通し） → 通過
#   5) 直接作業宣言マーカー（直接編集の理由をユーザーに明示してから touch） → 通過
#
# 判定不能時は素通し（このゲートの目的は「委任の自問」であり防御ではない）。

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
# 逃げ道は Vault 専用マーカーのみ（汎用マーカー 5)・委任実績 4)/4b) では開かない）。
VAULT_PREFIX="$HOME/Data/obsidian"
case "$fpath" in
  "$VAULT_PREFIX"/Fragments/*|"$VAULT_PREFIX"/Knowledge/*|"$VAULT_PREFIX"/Decisions/*|"$VAULT_PREFIX"/Projects/*|"$VAULT_PREFIX"/Preferences/*|"$VAULT_PREFIX"/Personal/*)
    vault_marker="$MARKER_DIR/claude-vault-direct-ok-$sid"
    [ -f "$vault_marker" ] && exit 0
    reason="delegation-gate: 外部脳（Vault）の AI向け6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）への執筆は常駐チームメイト vault-scribe へ委任してください（Preferences/vault-operation。2026-08-12 本人指示で「軽い1件はリーダー直筆可」の例外は撤廃・2026-08-13 本人指示で対象は AI向け6フォルダに限定）。リーダーは内容を確定して scribe へ渡す係です。scribe 不在なら起動してから振る。scribe が使えない緊急時のみ、理由をユーザーへの応答で明示した上で次を実行してから再試行: touch $vault_marker"
    jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
    ;;
esac

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

# 4b) 再開セッション対策（2026-07-05 実測: /resume でセッションIDが変わるが
# チーム config は旧IDのディレクトリに残るため、4) の自チーム照合が空振りして
# 誤判定していた）。tmux シム環境（claude-teams 配下）で、いずれかのチームに
# リーダー以外の稼働メンバーが存在すれば委任実績とみなして通す。
# 自問ゲートであり防御ではないため、この緩さで許容する。
if [ -n "${TMUX:-}" ] && [ -d "$TEAMS_DIR" ]; then
  for cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$cfg" ] || continue
    n_any=$(jq '[.members[]? | select((.agentType // .agent_type // "") != "team-lead")] | length' "$cfg" 2>/dev/null)
    [ "${n_any:-0}" -gt 0 ] 2>/dev/null && exit 0
  done
fi

# 5) 直接作業宣言マーカー
marker="$MARKER_DIR/claude-direct-edit-ok-$sid"
[ -f "$marker" ] && exit 0

# deny（自問を強制）
reason="delegation-gate: 実装・調査・テスト等の「作る工程」はチームメイト/Agentワーカーへ委任するのが既定です（Preferences/coding-delegation）。このセッションではまだ委任実績がありません。→ (a) チームメイト/ワーカーを起こしてタスクを振るか、(b) 直接編集が妥当な理由（軽微な修正・レビュー指摘の反映・ユーザーの明示指示・例外プロジェクト等）をユーザーへの応答で明示した上で、次を実行してから再試行してください: touch $marker"
jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
