#!/usr/bin/env bash
# claude/hooks/delegation-gate-v2.sh のユニットテスト（前提修正 P-4・設計§4）。
#
# ⚠️ claude/hooks/delegation-gate-v2.sh 本体は1行も変えない（設計の絶対条件）。
# 本ファイルは「変えていないこと」を守るための回帰ガードとして新設する
# （フックにテストが1本も無かった＝要件§15-2）。
#
# 隔離: HOME（許可パスと Vault 接頭辞の両方が追随する）・GATE_TEAMS_DIR・
# GATE_MARKER_DIR の3つを一時ディレクトリへ差し替えるだけでよい（破壊的操作を
# 含まない）。実 ~/.claude・実Vault・実チーム構成には一切依存しない。
#
# 入力: stdin の JSON（session_id・agent_id・agent_type・tool_input.file_path・
# cwd）。判定: exit 0 かつ標準出力が空なら通過／permissionDecision: "deny"
# を含めば deny（フックは deny の場合も含め常に exit 0 を返す契約）。
#
# 判定順序（現物）＝1→2→2.5→3→4→4b→5。各 fixture は「狙った判定より前の
# 条件がすべて偽」であることを保証する（設計§4）。PA-19〜PA-22 に共通の
# 前提 a〜g（PA-18 は対象外＝a〜e＋「対象が許可パスの中」＋g）を、フィクス
# チャ自身の構成から実際に確認するヘルパーを用意する。
#
# 実行方法: bash tests/test-delegation-gate-v2.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/delegation-gate-v2.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# make_input <session_id> <agent_id> <agent_type> <file_path> <cwd> — フック
# への標準入力JSONを組み立てる（PreToolUseフックの実際の呼び出し形式）。
make_input() {
  local sid="$1" aid="$2" atype="$3" fpath="$4" cwd="$5"
  jq -n --arg sid "$sid" --arg aid "$aid" --arg atype "$atype" \
        --arg fpath "$fpath" --arg cwd "$cwd" \
    '{session_id:$sid, agent_id:$aid, agent_type:$atype, tool_input:{file_path:$fpath}, cwd:$cwd}'
}

# run_gate <home> <teams_dir> <marker_dir> <json> [tmux_value] — フックを
# 実行し、標準出力とexit codeをグローバル変数(GATE_OUT/GATE_RC)へ格納する。
run_gate() {
  local home="$1" teams="$2" markers="$3" json="$4" tmux_value="${5:-}"
  GATE_RC=0
  if [ -n "$tmux_value" ]; then
    GATE_OUT="$(printf '%s' "$json" | HOME="$home" GATE_TEAMS_DIR="$teams" GATE_MARKER_DIR="$markers" TMUX="$tmux_value" bash "$HOOK" 2>&1)"
  else
    GATE_OUT="$(printf '%s' "$json" | HOME="$home" GATE_TEAMS_DIR="$teams" GATE_MARKER_DIR="$markers" env -u TMUX bash "$HOOK" 2>&1)"
  fi
  GATE_RC=$?
}

assert_pass() {
  local desc="$1"
  if [[ "$GATE_RC" -eq 0 ]] && [[ -z "$GATE_OUT" ]]; then
    pass "$desc"
  else
    fail_case "$desc (通過しなかった。rc=$GATE_RC out=[$GATE_OUT])"
  fi
}

assert_deny() {
  local desc="$1" reason_substr="${2:-}"
  # フックは deny の場合も含め常に exit 0 を返す契約（判定は標準出力のJSONで
  # 表現する。exit codeでは判定しない＝現物にexit非0の分岐は無い）。deny
  # JSONを出しつつ非0終了する回帰を見逃さないよう exit code も検査する
  # （2026-09-07 Codex一次レビュー指摘・MINOR対応）。
  if [[ "$GATE_RC" -ne 0 ]]; then
    fail_case "$desc (exit codeが非0＝フック自体の異常終了の可能性。rc=$GATE_RC out=[$GATE_OUT])"
    return
  fi
  if ! printf '%s' "$GATE_OUT" | grep -q '"permissionDecision": "deny"'; then
    fail_case "$desc (denyされなかった。rc=$GATE_RC out=[$GATE_OUT])"
    return
  fi
  if [[ -n "$reason_substr" ]] && ! printf '%s' "$GATE_OUT" | grep -qF "$reason_substr"; then
    fail_case "$desc (denyされたが想定と別理由の可能性。out=[$GATE_OUT])"
    return
  fi
  pass "$desc"
}

# --- 前提 a〜g の確認ヘルパー（設計§4）。フィクスチャ自身の構成から、
#     狙った判定より前の条件が実際に偽であることを確認する。 ---
assert_precond_a() {
  assert_true "前提a: session_idが非空" "$([[ -n "$1" ]] && echo 1 || echo 0)"
}
assert_precond_b() {
  assert_true "前提b: file_pathが非空・絶対パス" "$([[ "$1" == /* && -n "$1" ]] && echo 1 || echo 0)"
}
assert_precond_c() {
  assert_true "前提c: agent_id・agent_typeがどちらも空" "$([[ -z "$1" && -z "$2" ]] && echo 1 || echo 0)"
}
# 前提d: 他チームのconfigに自session_idが載っていない（現物と同じ走査ロジックで確認）
assert_precond_d() {
  local sid="$1" teams="$2" own_team="session-${sid:0:8}" found=0
  if [ -d "$teams" ]; then
    for cfg in "$teams"/*/config.json; do
      [ -f "$cfg" ] || continue
      [ "$(basename "$(dirname "$cfg")")" = "$own_team" ] && continue
      grep -q "$sid" "$cfg" 2>/dev/null && found=1
    done
  fi
  assert_true "前提d: 他チームのconfigに自session_idが載っていない" "$([[ "$found" -eq 0 ]] && echo 1 || echo 0)"
}
# 前提e: 対象がVaultのAI向け6フォルダの外
assert_precond_e() {
  local fpath="$1" vault_prefix="$2" hit=0
  case "$fpath" in
    "$vault_prefix"/Fragments/*|"$vault_prefix"/Knowledge/*|"$vault_prefix"/Decisions/*|"$vault_prefix"/Projects/*|"$vault_prefix"/Preferences/*|"$vault_prefix"/Personal/*)
      hit=1 ;;
  esac
  assert_true "前提e: 対象がVaultのAI向け6フォルダの外" "$([[ "$hit" -eq 0 ]] && echo 1 || echo 0)"
}
# 前提f: 対象が許可パス（$HOME/.claude・$HOME/.claude.json・/tmp・/private/tmp）の外
assert_precond_f() {
  local fpath="$1" home="$2" hit=0
  for p in "$home/.claude" "$home/.claude.json" "/tmp" "/private/tmp"; do
    case "$fpath" in "$p"/*|"$p") hit=1 ;; esac
  done
  assert_true "前提f: 対象が許可パスの外" "$([[ "$hit" -eq 0 ]] && echo 1 || echo 0)"
}
# 前提f逆（PA-18専用）: 対象が許可パスの中
assert_precond_f_inside() {
  local fpath="$1" home="$2" hit=0
  for p in "$home/.claude" "$home/.claude.json" "/tmp" "/private/tmp"; do
    case "$fpath" in "$p"/*|"$p") hit=1 ;; esac
  done
  assert_true "前提(PA-18): 対象が許可パスの中" "$([[ "$hit" -eq 1 ]] && echo 1 || echo 0)"
}

# 自チームの config.json に、team-lead 以外のメンバーを1名持たせる（判定4用）。
write_team_config_with_worker() {
  local cfg="$1"
  mkdir -p "$(dirname "$cfg")"
  jq -n '{members:[{agentType:"team-lead"},{agentType:"researcher"}]}' > "$cfg"
}
# team-lead のみ（委任実績なし）の config.json。
write_team_config_leader_only() {
  local cfg="$1"
  mkdir -p "$(dirname "$cfg")"
  jq -n '{members:[{agentType:"team-lead"}]}' > "$cfg"
}
# 他チームのconfigに自session_idを載せる（判定2用）。
write_team_config_with_sid() {
  local cfg="$1" sid="$2"
  mkdir -p "$(dirname "$cfg")"
  jq -n --arg sid "$sid" '{members:[{session_id:$sid}]}' > "$cfg"
}

echo "=== 1. PA-13: 判定1（agent_type あり）→ 通過 ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  json="$(make_input "sess-pa13-00000000" "" "researcher" "$WORK/project/file.md" "$WORK/project")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-13: agent_typeありで通過"
  rm -rf "$WORK"
}

echo "=== 2. PA-14: 判定1（agent_id 単独あり・agent_type空）→ 通過（現物は agent_id 単独でも通す） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  json="$(make_input "sess-pa14-00000000" "worker-123" "" "$WORK/project/file.md" "$WORK/project")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-14: agent_id単独で通過"
  rm -rf "$WORK"
}

echo "=== 3. PA-15: 判定2（他チームのconfigに自session_id）→ 通過 ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$MARK_D"
  SID="sess-pa15-00000000"
  write_team_config_with_sid "$TEAMS_D/session-OTHERTEAM/config.json" "$SID"
  json="$(make_input "$SID" "" "" "$WORK/project/file.md" "$WORK/project")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-15: 他チームconfigに自session_idがあれば通過"
  rm -rf "$WORK"
}

echo "=== 4. PA-16: 判定2.5（Vault AI向け6フォルダ・専用マーカーなし）→ deny（理由文にvault-scribe） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa16-00000000"
  fpath="$HOME_D/Data/obsidian/Knowledge/note.md"
  json="$(make_input "$SID" "" "" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_deny "PA-16: Vault AI向けフォルダ・マーカー無しでdeny" "vault-scribe"
  rm -rf "$WORK"
}

echo "=== 5. PA-17: 判定2.5（同・Vault専用マーカーあり）→ 通過 ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa17-00000000"
  fpath="$HOME_D/Data/obsidian/Knowledge/note.md"
  touch "$MARK_D/claude-vault-direct-ok-$SID"
  json="$(make_input "$SID" "" "" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-17: Vault専用マーカーありで通過"
  rm -rf "$WORK"
}

echo "=== 6. PA-18: 判定3（許可パス）→ 通過（前提=a〜e＋許可パスの中＋g） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa18-00000000"
  AID=""; ATYPE=""
  fpath="$HOME_D/.claude/settings.local.json"

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f_inside "$fpath" "$HOME_D"
  # 前提g: 不要なマーカーを置かない（本ケースは判定3自体を見るので何も置かない）

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-18: 許可パス（\$HOME/.claude）で通過"
  rm -rf "$WORK"
}

echo "=== 6b. PA-18相当: 許可パス（/tmp）でも通過 ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa18b-0000000"
  fpath="/tmp/aienv-test-delegation-gate-pa18b/file.md"
  json="$(make_input "$SID" "" "" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-18相当: /tmp配下で通過"
  rm -rf "$WORK"
}

echo "=== 7. PA-19: 判定4（自チームにリーダー以外のメンバーあり）→ 通過（共通前提a〜g） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$MARK_D"
  SID="sess-pa19-00000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  write_team_config_with_worker "$TEAMS_D/session-${SID:0:8}/config.json"

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f "$fpath" "$HOME_D"
  # 前提g: マーカーは一切置かない

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-19: 自チームに委任実績があれば通過"
  rm -rf "$WORK"
}

echo "=== 8. PA-20: 判定4b（TMUXあり＋他チームにリーダー以外の稼働メンバー＋自チームconfigは無い）→ 通過（共通前提a〜g・判定4が偽であることまで満たす） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$MARK_D"
  SID="sess-pa20-00000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  write_team_config_with_worker "$TEAMS_D/session-OTHERTEAM/config.json"
  # 自チームのconfig（$TEAMS_D/session-${SID:0:8}/config.json）は意図的に作らない
  # ＝判定4「自チームにリーダー以外のメンバーが存在」が偽であることを保証する。

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f "$fpath" "$HOME_D"
  assert_true "前提(PA-20固有): 自チームのconfigが存在しない（判定4が偽）" \
    "$([[ ! -f "$TEAMS_D/session-${SID:0:8}/config.json" ]] && echo 1 || echo 0)"
  # 前提g: マーカーは一切置かない

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json" "1"
  assert_pass "PA-20: TMUX下で他チームに委任実績があれば通過（再開セッション対策）"
  rm -rf "$WORK"
}

echo "=== 9. PA-21: 判定5（汎用マーカーあり）→ 通過（共通前提a〜g） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa21-00000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  # 自チームconfigは置かない or leaderのみ（判定4を偽にする）。
  write_team_config_leader_only "$TEAMS_D/session-${SID:0:8}/config.json"
  touch "$MARK_D/claude-direct-edit-ok-$SID"

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f "$fpath" "$HOME_D"
  # 前提g: 今回の判定（5）に必要な汎用マーカーだけを置く（Vault専用マーカーは置かない）
  assert_true "前提g: Vault専用マーカーは置かない" \
    "$([[ ! -f "$MARK_D/claude-vault-direct-ok-$SID" ]] && echo 1 || echo 0)"

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-21: 汎用マーカーありで通過"
  rm -rf "$WORK"
}

echo "=== 10. PA-22: マーカーも委任実績も無い → deny（共通前提a〜g） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa22-00000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  write_team_config_leader_only "$TEAMS_D/session-${SID:0:8}/config.json"

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f "$fpath" "$HOME_D"
  assert_true "前提g: マーカーは一切置かない" \
    "$([[ ! -f "$MARK_D/claude-direct-edit-ok-$SID" && ! -f "$MARK_D/claude-vault-direct-ok-$SID" ]] && echo 1 || echo 0)"

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_deny "PA-22: マーカー・委任実績いずれも無ければdeny" "delegation-gate"
  rm -rf "$WORK"
}

echo "=== 11. FX-G1（3モード体制-要件-2026-09-05.md §6.0）: 実効モードsolo相当・汎用マーカーあり・許可パス外のWrite → 通過（既存の判定5。新しい判定を1つも足していないこと＝AC-15） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-fxg1-0000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  # solo相当＝チーム構成そのものが無い（自チームconfigも他チームconfigも
  # 作らない）。リーダーが理由を本人へ明示してから汎用マーカーをtouch済み、
  # という単独モードの手順（core-conduct.md §4③）をfixture化したもの。
  touch "$MARK_D/claude-direct-edit-ok-$SID"

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f "$fpath" "$HOME_D"

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "FX-G1: solo相当・汎用マーカーあり・許可パス外のWriteは通過"
  rm -rf "$WORK"
}

echo "=== 12. FX-G2（既存の挙動が変わっていないこと＝回帰ガード）: マーカーも委任実績も無ければdeny ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-fxg2-0000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  # マーカーもチーム構成(委任実績)も一切無い状態。

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "$AID" "$ATYPE"
  assert_precond_d "$SID" "$TEAMS_D"
  assert_precond_e "$fpath" "$HOME_D/Data/obsidian"
  assert_precond_f "$fpath" "$HOME_D"
  assert_true "前提g: マーカーは一切置かない" \
    "$([[ ! -f "$MARK_D/claude-direct-edit-ok-$SID" && ! -f "$MARK_D/claude-vault-direct-ok-$SID" ]] && echo 1 || echo 0)"

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_deny "FX-G2: マーカー・委任実績いずれも無ければdeny"
  rm -rf "$WORK"
}

echo "=== 13. FX-G9（FR-31）: 実効モードsolo相当・汎用マーカーあり・対象がVaultのPreferences/配下 → deny・理由文にvault-scribe（判定2.5は汎用マーカーでは開かない） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-fxg9-0000000"
  fpath="$HOME_D/Data/obsidian/Preferences/core-worker.md"
  # ⚠️ FX-G1と同じ「汎用」マーカー（claude-direct-edit-ok-）だけを置く。
  # Vault専用マーカー（claude-vault-direct-ok-）は意図的に置かない＝
  # 判定2.5が汎用マーカーでは通らないことを見る（FR-31）。
  touch "$MARK_D/claude-direct-edit-ok-$SID"

  assert_precond_a "$SID"
  assert_precond_b "$fpath"
  assert_precond_c "" ""
  assert_precond_d "$SID" "$TEAMS_D"
  # ⚠️ macOS既定のbash 3.2は`$(case ... esac)`のようなcommand substitution
  # 内caseの構文解析に既知の不具合があるため、caseを独立文にしてから変数へ
  # 代入する（他のテスト・profile_resolve.py側と同じ回避策）。
  fxg9_precond=0
  case "$fpath" in "$HOME_D/Data/obsidian"/Preferences/*) fxg9_precond=1 ;; esac
  assert_true "前提(FX-G9固有): 対象はVaultのAI向け6フォルダの中（Preferences/）" "$fxg9_precond"
  assert_true "前提g: Vault専用マーカーは置かない" \
    "$([[ ! -f "$MARK_D/claude-vault-direct-ok-$SID" ]] && echo 1 || echo 0)"

  json="$(make_input "$SID" "" "" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_deny "FX-G9: solo相当・汎用マーカーのみではVault対象はdenyのまま" "vault-scribe"
  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
