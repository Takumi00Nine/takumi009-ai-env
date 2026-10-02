#!/bin/bash
# SessionStart 合成器（Core）: 寄与 3 を台帳の鍵で引いて各 1 回起動し、配置表の順に 1 つの additionalContext で出す。
# 寄与の起動＝`<寄与> --slots`（stdin は受けた hook JSON のまま）→ {"slots":{"<枠名>":"<文>",…}}。
# ワーカー（stdin JSON に agent_type が付く／他セッションがリーダーのチーム config.json に自分の session_id が載る）には何も注入しない。
# 縮退: 鍵なし＝その寄与の枠を省く（予定された省略・記録なし）。台帳異常・寄与の不在・寄与の異常（非 0・契約の形でない・
#   枠欠落）＝その寄与の枠を省き、本文の末尾に空行 1 つを置いて固定文 `LEDGER: …` を 1 件 1 行（同じ行を stderr へも）。
# 寄与に独自の時間上限は足さない（全体は settings の hook timeout）。見出しは寄与が全部欠けても出す。
# 正本＝docs/v1.1-components 設計 §5.5・§5.6。経緯＝[[Decisions/2026-09-19-ai-env-optimization-rulings]]
TEAMS_DIR="${BOOTSTRAP_TEAMS_DIR:-$HOME/.claude/teams}"

# 登録名（~/.claude/hooks/bootstrap-vault.sh）は symlink なので、辿った実体の位置から台帳ツールを引く。
resolve_self_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
SELF_DIR="$(resolve_self_dir)"
REPO_ROOT="${SELF_DIR%/*/*/*}"
LEDGER_TOOL="$REPO_ROOT/core/assembly/ledger-tool.sh"

# 配置表（設計定数）: 寄与の鍵（配置表に最初に現れる順＝起動順）と、その鍵から受け取る枠名。
# 枠の並び・固定文・区切りは末尾の heredoc（基準＝分割前の読込の注入文の骨格）。
CONTRIBUTOR_KEYS="team.session-status ai-brain.bootstrap dock.declare-state"
slots_of() {
  case "$1" in
    team.session-status) echo "opening directive5 role-hold profile-warning" ;;
    ai-brain.bootstrap)  echo "must-read health" ;;
    dock.declare-state)  echo "declare6" ;;
  esac
}

INPUT=$(cat 2>/dev/null || true)
INPUT_FIELDS=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.agent_type // "")] | @tsv' 2>/dev/null)
SESSION_ID="${INPUT_FIELDS%%$'\t'*}"
AGENT_TYPE="${INPUT_FIELDS#*$'\t'}"
[ "$INPUT_FIELDS" = "$SESSION_ID" ] && AGENT_TYPE=""

is_worker=0
[ -n "$AGENT_TYPE" ] && is_worker=1
if [ "$is_worker" = "0" ] && [ -n "$SESSION_ID" ] && [ -d "$TEAMS_DIR" ]; then
  own_team="session-${SESSION_ID:0:8}"
  for cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$cfg" ] || continue
    team_dir=$(basename "$(dirname "$cfg")")
    [ "$team_dir" = "$own_team" ] && continue  # 自分がリーダーのチーム設定は除外
    if grep -q "$SESSION_ID" "$cfg" 2>/dev/null; then
      is_worker=1
      break
    fi
  done
fi
# ワーカーには何も注入しない（共通ルールの正本＝職種定義の共通ルール節。in-process ワーカーには本フックの注入が届かない）。
[ "$is_worker" = "1" ] && exit 0

# warn_line <固定文> — 警告行を 1 件足す（同じ行は 1 回だけ）。同じ行を stderr へも。
WARNINGS=""
warn_line() {
  case $'\n'"$WARNINGS"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
  WARNINGS="${WARNINGS:+$WARNINGS$'\n'}$1"
  printf '%s\n' "$1" >&2
}

# 枠の文＝SLOT_<枠名の - を _ に>。省いた寄与の枠は空のまま。
SLOT_opening=""; SLOT_must_read=""; SLOT_directive5=""; SLOT_declare6=""
SLOT_role_hold=""; SLOT_health=""; SLOT_profile_warning=""
for key in $CONTRIBUTOR_KEYS; do
  found="$(bash "$LEDGER_TOOL" lookup "$key" 2>&1)"; rc=$?
  case "$rc" in
    0) ;;
    1) continue ;;
    *)
      case "$found" in
        "LEDGER: "*) warn_line "${found%%$'\n'*}" ;;
        *) warn_line "LEDGER: ledger 照会に失敗（rc=${rc}）" ;;
      esac
      continue ;;
  esac
  path="${found%%$'\n'*}"
  rel="${path#"$REPO_ROOT"/}"
  out="$("$path" --slots <<<"$INPUT")"; rc=$?
  if [ "$rc" != "0" ]; then
    warn_line "LEDGER: part $key $rel 寄与が非 0（rc=${rc}）"
    continue
  fi
  # 配置表にある枠が全て文字列で揃うときだけ代入文を出す（@sh で引用）。
  assign="$(printf '%s' "$out" | jq -r --arg names "$(slots_of "$key")" '
    .slots as $s | ($names | split(" ")) as $n
    | if ($s | type) == "object" and all($n[]; ($s[.] | type) == "string")
      then $n[] | "SLOT_\(gsub("-"; "_"))=\($s[.] | @sh)"
      else error("枠が欠ける") end' 2>/dev/null)"
  if [ -z "$assign" ]; then
    warn_line "LEDGER: part $key $rel 寄与の出力が契約の形でない"
    continue
  fi
  eval "$assign"
done

read -r -d '' DIRECTIVE <<EOF
【セッション開始ブートストラップ｜ハーネス強制注入】

${SLOT_opening}

${SLOT_must_read}
${SLOT_directive5}
${SLOT_declare6}
${SLOT_role_hold:+
${SLOT_role_hold}}

${SLOT_health}${SLOT_profile_warning:+

${SLOT_profile_warning}}
EOF
[ -n "$WARNINGS" ] && DIRECTIVE="${DIRECTIVE}

${WARNINGS}"

jq -n --arg ctx "$DIRECTIVE" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
