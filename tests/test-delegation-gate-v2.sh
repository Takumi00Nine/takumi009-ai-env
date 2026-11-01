#!/usr/bin/env bash
# team/connect/claude-code/delegation-gate-v2.sh のユニットテスト（前提修正 P-4・設計§4）。
#
# ⚠️ team/connect/claude-code/delegation-gate-v2.sh の判定ロジックは、
# 2026-10-04 決定（リーダーのVault軽書込は直筆可）で rule 2.5 が「Vault の
# AI向け6フォルダ＝通過」に変わる以外は変えない（deny 文面は 2026-09-19 に短縮）。
# 本ファイルは、rule 2.5 以外の判定が「変えていないこと」を守る回帰ガードである
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
# 判定順序（現物）＝1→2→2.5→3→4→4m→5（設計v1.2 §3.3・FR-38で旧4bは撤去）。
# 2.5＝Vault の AI 向け6フォルダ（guard_is_vault_ai_path）なら通過
# （2026-10-04決定・リーダー直筆可。Vault専用マーカーの分岐は撤去済み）。
# 各 fixture は「狙った判定より前の条件がすべて偽」であることを保証する
# （設計§4）。PA-19〜PA-22 に共通の前提 a〜g（PA-18 は対象外＝a〜e＋「対象が
# 許可パスの中」＋g）を、フィクスチャ自身の構成から実際に確認するヘルパーを
# 用意する。
#
# 実行方法: bash tests/test-delegation-gate-v2.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/team/connect/claude-code/delegation-gate-v2.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

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

echo "=== 4. PA-16: 判定2.5（Vault AI向け6フォルダ）→ 通過（2026-10-04決定・リーダー直筆可） ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-pa16-00000000"
  fpath="$HOME_D/Data/obsidian/Knowledge/note.md"
  json="$(make_input "$SID" "" "" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-16: Vault AI向けフォルダ（マーカー無し）で通過"
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

  # 前提g: 不要なマーカーを置かない（本ケースは判定3自体を見るので何も置かない）

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-18: 許可パス（\$HOME/.claude）で通過"
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

  # 前提g: マーカーは一切置かない

  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "PA-19: 自チームに委任実績があれば通過"
  rm -rf "$WORK"
}

echo "=== 8b. D2-M1(AC-9前半・FR-25): 判定4m（自チームconfigに非リーダー0件・このセッションの委任マーカーあり＝agent-model-guard.shのPASSを模す）→ 通過 ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  SID="sess-d2m1-0000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  # 自チームconfigは作らない（非リーダーのメンバー0件＝判定4が偽）。
  touch "$MARK_D/claude-delegated-ok-$SID"


  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_pass "D2-M1: 名前無しsubagentだけの委任実績（4mマーカー）で通過"
  rm -rf "$WORK"
}

echo "=== 8c. D2-M2(AC-9後半・FR-38・FM-7): 他セッションのconfigにだけ非リーダーのメンバーがいる（自セッションのAgent起動なし）→ deny ==="
{
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$MARK_D"
  SID="sess-d2m2-0000000"
  AID=""; ATYPE=""
  fpath="$WORK/project/file.md"
  write_team_config_with_worker "$TEAMS_D/session-OTHERTEAM2/config.json"
  # 自チームconfigは作らない・自セッションの委任マーカー（claude-delegated-
  # ok-<sid>）も置かない＝「自セッションのAgent起動なし」を保証する。


  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json" "fixture-tmux"
  assert_deny "D2-M2: TMUXがあっても他セッションのconfigだけでは通過しない"
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

  # 前提g: 今回の判定（5）に必要な汎用マーカーだけを置く

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


  json="$(make_input "$SID" "$AID" "$ATYPE" "$fpath" "$WORK")"
  run_gate "$HOME_D" "$TEAMS_D" "$MARK_D" "$json"
  assert_deny "PA-22: マーカー・委任実績いずれも無ければdeny・正本参照" "~/Data/obsidian/Preferences/coding-delegation.md"
  rm -rf "$WORK"
}

echo "=== 15. I2-m5(検証2巡目): source失敗時のfail-close分岐そのものに恒久テストを足す（lib/を持たない実体ディレクトリへフックをコピーして起動・既存ケースは1行も変えず追加のみ） ==="
{
  # I2-M2でenv上書き口（GUARD_COMMON_LIB）を撤去したため、source失敗を
  # 再現する手段は「lib/を持たない場所へフック本体だけをコピーして実行する」
  # 方式に一本化する（symlinkだと自身の実体を辿ってlib/を見つけてしまい
  # source失敗を再現できない＝コピーでなければならない）。
  WORK="$(mktemp -d)"
  HOME_D="$WORK/home"; TEAMS_D="$WORK/teams"; MARK_D="$WORK/markers"
  mkdir -p "$HOME_D" "$TEAMS_D" "$MARK_D"
  NOLIB_DIR="$WORK/nolib-delegation-gate"
  mkdir -p "$NOLIB_DIR"
  cp "$HOOK" "$NOLIB_DIR/delegation-gate-v2.sh"

  SID="sess-i2m5-0000000"
  fpath="$WORK/project/file.md"
  json="$(make_input "$SID" "" "" "$fpath" "$WORK")"
  NOLIB_OUT="$(printf '%s' "$json" | HOME="$HOME_D" GATE_TEAMS_DIR="$TEAMS_D" GATE_MARKER_DIR="$MARK_D" env -u TMUX bash "$NOLIB_DIR/delegation-gate-v2.sh" 2>&1)"
  NOLIB_RC=$?

  if [[ "$NOLIB_RC" -eq 0 ]] \
     && printf '%s' "$NOLIB_OUT" | grep -q '"permissionDecision": "deny"' \
     && printf '%s' "$NOLIB_OUT" | grep -qF "GUARD_COMMON_UNREADABLE"; then
    pass "I2-m5: delegation-gate-v2.shはlib/が無いとfail-close（deny・GUARD_COMMON_UNREADABLE・exit 0）で素通ししない"
  else
    fail_case "I2-m5: delegation-gate-v2.shのfail-closeが働かない (rc=$NOLIB_RC out=[$NOLIB_OUT])"
  fi
  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
