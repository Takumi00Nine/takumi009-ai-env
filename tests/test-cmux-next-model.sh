#!/bin/bash
# cmux-next-model.sh のユニットテスト（cmux-session-todo 設計 §34.1 MP層）。
# 実 Vault・実ログには一切触れない。--list／--frame は cmux を呼ばず（設計 §30.2）、
# --focus だけが PATH 先頭の cmux スタブを 2 回呼ぶ（設計 §42.5）。dotfiles には
# 一切依存しない（NFR-13・AC-106）。
#
# 実行方法: bash tests/test-cmux-next-model.sh
#
# v6（requirements-v6.md・design.md §41）＝実装への契約（テストが決めた口・A-v6-7）:
#   CMUX_VAULT_TASKS_SANITIZE_FAIL=1 ＝ Tasks 節の共有解析（cmux/lib-vault-tasks.sh）の
#   サニタイズ段だけを失敗させるテスト専用の差し替え口（D-v6-14・DT-33＝解析不能の作り方）。
#   未設定／空＝通常。slug の無害化・next の切り詰め・frontmatter の読み取りには効かせない
#   （M-v6-15）。本番設定（config/・launchd/・scripts/install*・dock.json）に名前を書かない。
#   （フック側の口 BOOTSTRAP_CMUX_LIB_DIR は tests/test-bootstrap-vault.sh 参照）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux/cmux-next-model.sh"

# 外側シェルの env から独立させる（R2-1）。--recall-stale-days の期待値 7 は固定。
unset VAULT_AGENT_LOG_STALE_DAYS

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-model-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'chmod -R u+rwx "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT   # chmod 000 の fixture が残っても片付く

# shellcheck source=./lib-cmux-fixtures.sh
. "$SCRIPT_DIR/lib-cmux-fixtures.sh"

VAULT="$WORKDIR/vault"
INV_DIR="$WORKDIR/inventory"
MAINT_FILE="$WORKDIR/maintenance/last-run.json"
mkdir -p "$VAULT/Projects"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  期待した文字列が見つかりません: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  含まれてはいけない文字列が見つかりました: $needle"
  else
    PASS=$(( PASS + 1 ))
  fi
}

# $1 の中で needle1 が needle2 より前の行に現れることを確認する。
assert_order() {
  local desc="$1" haystack="$2" needle1="$3" needle2="$4"
  local pos1 pos2
  pos1="$(printf '%s\n' "$haystack" | grep -nF -- "$needle1" | head -n1 | cut -d: -f1)"
  pos2="$(printf '%s\n' "$haystack" | grep -nF -- "$needle2" | head -n1 | cut -d: -f1)"
  if [ -n "$pos1" ] && [ -n "$pos2" ] && [ "$pos1" -lt "$pos2" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: ${desc}（$needle1 の行=$pos1 / $needle2 の行=${pos2}）"
  fi
}

# 既定が実ファイルの env 5 本（設計 v1.2 §10.1）を必ず fixture／存在しないパスへ向ける。
# 観測記録・想起ログ・plist は本ファイルの基底ケースでは使わない＝存在しないパス固定。
# v5: 判定時刻の固定口 CMUX_NEXT_JUDGE_NOW は $JUDGE_NOW（空＝未設定＝実時刻）で渡す。
JUDGE_NOW=""
run_list_raw() {
  CMUX_NEXT_JUDGE_NOW="$JUDGE_NOW" \
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" CMUX_NEXT_MAINT_STATE="$MAINT_FILE" \
    CMUX_NEXT_INVENTORY_LATEST="$INV_DIR/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
    CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    bash "$TARGET" --list > "$WORKDIR/list_stdout" 2>"$WORKDIR/list_stderr"
  printf '%s' "$?" > "$WORKDIR/list_rc"
}

run_frame_raw() {
  CMUX_NEXT_JUDGE_NOW="$JUDGE_NOW" \
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" CMUX_NEXT_MAINT_STATE="$MAINT_FILE" \
    CMUX_NEXT_INVENTORY_LATEST="$INV_DIR/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
    CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>"$WORKDIR/frame_stderr"
  printf '%s' "$?" > "$WORKDIR/frame_rc"
}

reset_vault() {
  rm -rf "$VAULT" "$INV_DIR" "$WORKDIR/maintenance"
  mkdir -p "$VAULT/Projects"
}

# ==========================================================================
# 表示基底（P-6 相当・N-0〜N-8 全件 + 棚卸し・週次あり）
# ==========================================================================
reset_vault
mk_notes_N_all "$VAULT"
mk_inventory_report "$INV_DIR" "2026-09-08" 3
mk_maintenance_state "$MAINT_FILE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "=== 基底: --list が8件（N-7はcompletedで対象外）・番号1始まり・updated降順 ==="
run_list_raw
assert_eq "基底: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "基底: --listの行数が8" "8" "$(wc -l < "$WORKDIR/list_stdout" | tr -d ' ')"
assert_eq "基底: 番号は1から連番" "$(seq 1 8)" "$(awk -F '\t' '{print $1}' "$WORKDIR/list_stdout")"

echo "=== DT-10: --frame の P 行番号欄が --list 第1列と順序含め完全一致 ==="
run_frame_raw
assert_eq "DT-10: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
list_nums="$(awk -F '\t' '{print $1}' "$WORKDIR/list_stdout")"
frame_nums="$(awk -F '\t' '$1=="P"{print $2}' "$WORKDIR/frame_stdout")"
assert_eq "DT-10: 番号欄が完全一致" "$list_nums" "$frame_nums"
list_names="$(awk -F '\t' '{print $2}' "$WORKDIR/list_stdout")"
frame_names="$(awk -F '\t' '$1=="P"{print $3}' "$WORKDIR/frame_stdout")"
assert_eq "DT-10: 正式プロジェクト名も完全一致" "$list_names" "$frame_names"

echo "=== FR-72#5相当: 切り詰め前の一致（next値がframeと--listで完全一致） ==="
list_next="$(awk -F '\t' '{print $3}' "$WORKDIR/list_stdout")"
frame_next="$(awk -F '\t' '$1=="P"{print $4}' "$WORKDIR/frame_stdout")"
assert_eq "next値がframeと--listで完全一致" "$list_next" "$frame_next"

echo "=== 基底: --frame の #V/E 行 ==="
assert_eq "基底: #V行（契約 /4）" "#V	cmux-dock-frame/4	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
p_n="$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
b_n="$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "基底: E行が P行数+B行数と一致" "$(( p_n + b_n ))" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== FR-31導出（AC-36・AC-37・AC-38・AC-39・AC-47・AC-48・AC-49・AC-50） ==="
FIELD3_N1="$(awk -F '\t' '$2=="proj-n1-handwritten" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "AC-36: 手書きのnext:がTasks節より優先される" "手書きのnext値" "$FIELD3_N1"

FIELD3_N2="$(awk -F '\t' '$2=="proj-n2-short" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "AC-37: 先頭未完タスク（[x]を除く）が導出される" "短いタスク" "$FIELD3_N2"

FIELD3_N3="$(awk -F '\t' '$2=="proj-n3-long" {print $3}' "$WORKDIR/list_stdout")"
assert_not_contains "AC-38: 15コードポイント切り詰めに省略記号は付かない" "$FIELD3_N3" "…"

FIELD3_N5="$(awk -F '\t' '$2=="proj-n5-emptynext" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "AC-47: next:が空文字列のノートでTasks節からの導出が効く" "進行中のタスク" "$FIELD3_N5"

LINE_N6="$(awk -F '\t' '$2=="proj-n6-control"' "$WORKDIR/list_stdout")"
FIELD3_N6="$(printf '%s\n' "$LINE_N6" | awk -F '\t' '{print $3}')"
NCOLS_N6="$(printf '%s\n' "$LINE_N6" | awk -F '\t' '{print NF}')"
EXPECT_N6="タスク 本文 続き [31m"
assert_eq "AC-48: TAB/CR/ESC無害化後の値が期待と一致" "$EXPECT_N6" "$FIELD3_N6"
assert_eq "AC-48: TAB混入行が5列のまま（v5 読み替え R-v5-3）" "5" "$NCOLS_N6"
python3 -c "
import sys
data = open('$WORKDIR/list_stdout', 'rb').read()
sys.exit(1 if chr(27).encode() in data else 0)
"
assert_true "AC-48: --list出力に生のESCバイトが残っていない" "$([ $? -eq 0 ] && echo 1 || echo 0)"

assert_not_contains "AC-49: completedノートは--listに現れない" "$(cat "$WORKDIR/list_stdout")" "proj-n7-completed"
assert_not_contains "AC-49: completedノートのタスク本文も--listに現れない" "$(cat "$WORKDIR/list_stdout")" "completedなので出ないはず"

assert_order "AC-50: N-0がN-8よりupdated降順で前に並ぶ" "$(cat "$WORKDIR/list_stdout")" "proj-n0-base" "proj-n8-older"
BAD_NCOLS_ROWS="$(awk -F '\t' 'NF && NF!=5' "$WORKDIR/list_stdout" | wc -l | tr -d ' ')"
assert_eq "AC-50/FR-44④: --list に5列でない行が0件（v5 読み替え R-v5-3）" "0" "$BAD_NCOLS_ROWS"

echo "=== next: 無し・Tasks節も無し → next欄が空（(next未設定)は描画側の責務） ==="
FIELD3_N4="$(awk -F '\t' '$2=="proj-n4-none" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "next:もTasks節も無ければnext欄が空文字" "" "$FIELD3_N4"

# ==========================================================================
# 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §6）＝契約 cmux-dock-frame/4（v5）。
# B 行は判定機（claude/hooks/lib/health_judge.py）の写し＝1 行 3 値＋末尾付記。
# 判定は tests/test-health-judge.sh が 23 本を閉じる。ここでは供給側＝B 行の文法・
# 付記・判定機不在の 0 行・E の整合・HEALTH_JUDGE_NOW を検査する。
# 既定が実ファイルの env 5 本（CMUX_NEXT_MAINT_STATE・CMUX_NEXT_INVENTORY_LATEST・
# CMUX_NEXT_HEALTH_OBSERVATION・CMUX_NEXT_RECALL_LOG・CMUX_NEXT_MAINT_PLIST）は
# 必ず fixture／存在しないパスへ向ける（設計 §10.1）。
# ==========================================================================
FX_ROOT="$SCRIPT_DIR/fixtures/health"

# run_frame_fixture <fixture名> — fixture の判定機入力 4 本＋plist＋now で --frame を回す。
run_frame_fixture() {
  local d="$FX_ROOT/$1" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
    CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="$plist" \
    HEALTH_JUDGE_NOW="$(cat "$d/now")" \
    bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>"$WORKDIR/frame_stderr"
  printf '%s' "$?" > "$WORKDIR/frame_rc"
}
b_rows() { awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout"; }

echo "=== frame_v3_header: #V 行の契約版が cmux-dock-frame/4（理由フレームも同じ版・v5 で /3→/4） ==="
reset_vault
mk_note_N0 "$VAULT"
run_frame_fixture S-1
assert_eq "frame_v3_header: #V 行" "#V	cmux-dock-frame/4	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "frame_v3_header: 旧版 /1 は出ない" "0" "$(grep -c 'cmux-dock-frame/1' "$WORKDIR/frame_stdout")"
STUBBIN_SORT_V3="$WORKDIR/stubbin-sort-v3"
mkdir -p "$STUBBIN_SORT_V3"
printf '#!/bin/bash\nexit 1\n' > "$STUBBIN_SORT_V3/sort"; chmod +x "$STUBBIN_SORT_V3/sort"
PATH="$STUBBIN_SORT_V3:$PATH" run_frame_raw
assert_eq "frame_v3_header: 理由フレームも /4" "#V	cmux-dock-frame/4	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"

echo "=== frame_b_row_ok（AC-4 供給側）: S-1 → B 行 1 行＝外部脳／ok／OK＋候補12件 ==="
reset_vault
mk_note_N0 "$VAULT"
run_frame_fixture S-1
assert_eq "frame_b_row_ok: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "frame_b_row_ok: B 行はちょうど 1 行" "1" "$(b_rows | wc -l | tr -d ' ')"
s1_cand="$(jq -r '.fragments_candidates' "$FX_ROOT/S-1/last-run.json")"
assert_eq "frame_b_row_ok: B 行の文法（種別 外部脳・warn 欄 ok・3 値 OK・付記）" "B	外部脳	ok	OK 候補${s1_cand}件" "$(b_rows)"
assert_eq "frame_b_row_ok: 旧種別（棚卸し／週次）の行は出ない" "0" "$(awk -F '\t' '$1=="B" && ($2=="棚卸し" || $2=="週次")' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
p_n="$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "frame_b_row_ok: E＝P 行数＋B 行数" "$(( p_n + 1 ))" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== B 行の 3 値: S-2 → warn／WARNING・S-15 → error／ERROR ==="
run_frame_fixture S-2
s2_cand="$(jq -r '.fragments_candidates' "$FX_ROOT/S-2/last-run.json")"
assert_eq "S-2: B 行 warn／WARNING" "B	外部脳	warn	WARNING 候補${s2_cand}件" "$(b_rows)"
run_frame_fixture S-15
assert_eq "S-15: B 行 error／ERROR" "B	外部脳	error	ERROR 候補12件" "$(b_rows)"

echo "=== all_fixtures_one_b_row_three_values（AC-10）: S-1〜S-23 全件で B 行ちょうど 1 行・付記を除いた文言が 3 値・数字/日付/パス/工程名なし ==="
n_fx=0
for d in "$FX_ROOT"/S-*; do
  fx="$(basename "$d")"
  n_fx=$(( n_fx + 1 ))
  run_frame_fixture "$fx"
  assert_eq "AC-10 $fx: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
  assert_eq "AC-10 $fx: B 行ちょうど 1 行" "1" "$(b_rows | wc -l | tr -d ' ')"
  text="$(b_rows | awk -F '\t' '{print $4}' | sed 's/ 候補[0-9]*件$//')"
  kind="$(b_rows | awk -F '\t' '{print $2}')"
  warn="$(b_rows | awk -F '\t' '{print $3}')"
  assert_eq "AC-10 $fx: 種別＝外部脳" "外部脳" "$kind"
  assert_true "AC-10 $fx: 付記を除いた文言が 3 値のいずれか（実測 ${text}）" \
    "$([ "$text" = "OK" ] || [ "$text" = "WARNING" ] || [ "$text" = "ERROR" ] && echo 1 || echo 0)"
  assert_true "AC-10 $fx: warn 欄と文言の対応（ok/OK・warn/WARNING・error/ERROR）" \
    "$({ [ "$warn/$text" = "ok/OK" ] || [ "$warn/$text" = "warn/WARNING" ] || [ "$warn/$text" = "error/ERROR" ]; } && echo 1 || echo 0)"
  assert_eq "AC-10 $fx: 付記を除いた文言に数字・日付・パス・工程名が無い" "0" "$(printf '%s' "$text" | grep -c '[0-9/.]\|Phase\|要確認\|日前')"
  assert_eq "AC-10 $fx: 4 列ちょうど" "4" "$(b_rows | awk -F '\t' '{print NF}')"
done
assert_eq "AC-10: S-* は 23 本" "23" "$n_fx"

echo "=== b_row_suffix_candidates_when_nonneg（R-2）: fragments_candidates が非負整数のときだけ末尾に「 候補N件」（0 件も表示）。キー無し・型違反は付けない ==="
CAND_DIR="$WORKDIR/cand"; mkdir -p "$CAND_DIR"
cp "$FX_ROOT/S-1/latest.json" "$FX_ROOT/S-1/observation.json" "$FX_ROOT/S-1/vault-recall.tsv" "$FX_ROOT/S-1/now" "$CAND_DIR/"
run_cand() {   # $1=fragments_candidates の JSON 値（"del" でキー削除）
  if [ "$1" = "del" ]; then
    jq 'del(.fragments_candidates)' "$FX_ROOT/S-1/last-run.json" > "$CAND_DIR/last-run.json"
  else
    jq --argjson v "$1" '.fragments_candidates = $v' "$FX_ROOT/S-1/last-run.json" > "$CAND_DIR/last-run.json"
  fi
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$CAND_DIR/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$CAND_DIR/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$CAND_DIR/observation.json" \
    CMUX_NEXT_RECALL_LOG="$CAND_DIR/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    HEALTH_JUDGE_NOW="$(cat "$CAND_DIR/now")" bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
}
run_cand 0
assert_eq "候補 0 件も表示" "B	外部脳	ok	OK 候補0件" "$(b_rows)"
run_cand 37
assert_eq "候補 37 件" "B	外部脳	ok	OK 候補37件" "$(b_rows)"
run_cand del
assert_eq "キー無し: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"
run_cand '"12"'
assert_eq "型違反（文字列）: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"
run_cand -1
assert_eq "負数: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"
run_cand 'null'
assert_eq "null: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"

echo "=== judge_missing_no_b_row_e_count_consistent（F-10・§14-7）: 判定機不在／python3 失敗＝B 行 0 行・E は P 行数・rc=0 ==="
reset_vault
mk_notes_N_all "$VAULT"
# 判定機不在＝供給側スクリプトを lib だけ複製した一時ディレクトリから起動する（$LIB_DIR/../claude/hooks/lib/ が無い）。
NOJUDGE="$WORKDIR/nojudge/cmux"; mkdir -p "$NOJUDGE"
cp "$SCRIPT_DIR/../cmux/cmux-next-model.sh" "$SCRIPT_DIR/../cmux/lib-model-view.sh" "$SCRIPT_DIR/../cmux/lib-vault-tasks.sh" "$SCRIPT_DIR/../cmux/lib-cmux-workspace.sh" "$NOJUDGE/"
d="$FX_ROOT/S-2"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" HEALTH_JUDGE_NOW="$(cat "$d/now")" \
  bash "$NOJUDGE/cmux-next-model.sh" --frame > "$WORKDIR/frame_stdout" 2>"$WORKDIR/frame_stderr"
assert_eq "判定機不在: rc=0（フレームは正当）" "0" "$?"
assert_eq "判定機不在: B 行 0 行" "0" "$(b_rows | wc -l | tr -d ' ')"
assert_eq "判定機不在: #V は /4 のまま" "#V	cmux-dock-frame/4	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
p_n="$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "判定機不在: E＝P 行数（8）" "$p_n" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"
assert_eq "判定機不在: P 行は 8 行そろう" "8" "$p_n"
assert_eq "判定機不在: stderr に 1 行" "1" "$(grep -c 'health_judge.py' "$WORKDIR/frame_stderr")"
STUBBIN_PY="$WORKDIR/stubbin-py"; mkdir -p "$STUBBIN_PY"
printf '#!/bin/bash\nexit 3\n' > "$STUBBIN_PY/python3"; chmod +x "$STUBBIN_PY/python3"
PATH="$STUBBIN_PY:$PATH" run_frame_fixture S-2
assert_eq "python3 が非 0: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "python3 が非 0: B 行 0 行（誤った段階を見せない）" "0" "$(b_rows | wc -l | tr -d ' ')"
assert_eq "python3 が非 0: E＝P 行数" "$p_n" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== health_judge_now_passed_as_now（V-8(a)）: HEALTH_JUDGE_NOW が --now に写る（S-13＝予定超過は now で決まる） ==="
# S-13 は S-2 と同じ記録・plist つき。now を fixture の値（翌週）にすると未起動が加わり WARNING、
# now を S-2 の値（予定を跨がない）にしても WARNING（失敗 1 件）＝段階では見分けられないので、
# 判定機を spy して --now の値そのものを検査する。
SPY_PY="$WORKDIR/spy-py"; mkdir -p "$SPY_PY"
REAL_PY="$(command -v python3)"
cat > "$SPY_PY/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORKDIR/py-args.log"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$SPY_PY/python3"
: > "$WORKDIR/py-args.log"
PATH="$SPY_PY:$PATH" run_frame_fixture S-13
assert_eq "HEALTH_JUDGE_NOW あり: --now <fixture の now> が渡る" "1" "$(grep -c -- "--now $(cat "$FX_ROOT/S-13/now")" "$WORKDIR/py-args.log")"
assert_eq "HEALTH_JUDGE_NOW あり: S-13 は WARNING" "warn" "$(b_rows | awk -F '\t' '{print $3}')"
assert_eq "判定機呼び出し: --recall-stale-days 7 が渡る（I-2・bootstrap と同じ既定の渡し方＝設計 §4.1）" "1" "$(grep -c -- '--recall-stale-days 7' "$WORKDIR/py-args.log")"
: > "$WORKDIR/py-args.log"
d="$FX_ROOT/S-1"
PATH="$SPY_PY:$PATH" CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
  CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
  CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
  HEALTH_JUDGE_NOW="" bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "HEALTH_JUDGE_NOW 無し: --now を渡さない" "0" "$(grep -c -- '--now' "$WORKDIR/py-args.log")"
assert_eq "HEALTH_JUDGE_NOW 無し: 判定機は呼ばれている" "1" "$(grep -c 'health_judge.py judge' "$WORKDIR/py-args.log")"

echo "=== 判定機の入力が壊れていても B 行は出る（NFR-2）: last-run.json 解析不能＝WARNING（破損）・観測記録なし＝OK ==="
d="$FX_ROOT/X-3"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" HEALTH_JUDGE_NOW="$(cat "$d/now")" \
  bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "X-3（解析不能）: B 行 warn／WARNING" "B	外部脳	warn	WARNING" "$(b_rows)"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="/nonexistent-dir/last-run.json" CMUX_NEXT_INVENTORY_LATEST="/nonexistent-dir/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
  bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "データ源が全部無い（サブ機初回・F-7）: 不在＝OK の B 行 1 行" "B	外部脳	ok	OK" "$(b_rows)"

echo "=== no_real_home_default_in_tests（設計 §10.1・静的）: 本ファイル内の \$TARGET 直接起動に既定が実ファイルの env 5 本がすべて付いている ==="
missing_env_lines="$(python3 - "$SCRIPT_DIR/test-cmux-next-model.sh" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
need = ["CMUX_NEXT_MAINT_STATE", "CMUX_NEXT_INVENTORY_LATEST", "CMUX_NEXT_HEALTH_OBSERVATION",
        "CMUX_NEXT_RECALL_LOG", "CMUX_NEXT_MAINT_PLIST"]
bad = []
for i, line in enumerate(lines):
    s = line.strip()
    if '"$TARGET"' not in s or s.startswith("#") or "not in s" in s or "TARGET=" in s:
        continue
    if "--list" in s and "--frame" not in s:
        continue  # --list は判定機を呼ばない（ヘルスの入力を読まない）
    if "bash \"$TARGET\" $combo" in s:
        continue  # 未知引数は使い方 1 行で即終了（入力を読まない）
    window = "\n".join(lines[max(0, i - 8): i + 1])
    lacking = [n for n in need if n + "=" not in window]
    if lacking:
        bad.append(f"L{i + 1}: {' '.join(lacking)}")
print("\n".join(bad))
PY
)"
assert_eq "\$TARGET の --frame 直接起動で env 5 本を欠く箇所が 0" "" "$missing_env_lines"
assert_true "run_frame_raw も env 5 本を渡す（ヘルパの静的検査）" "$(sed -n '/^run_frame_raw() {/,/^}/p' "$SCRIPT_DIR/test-cmux-next-model.sh" | grep -c 'CMUX_NEXT_MAINT_PLIST=' | awk '{print ($1>=1)?1:0}')"

echo "=== items_do_not_use_last_result_summary（設計 §13・静的）: cmux-next-model.sh の項目生成経路に last_result_summary の参照が無い（検証 B-6） ==="
# ⚠️ no_real_home_default_in_tests の静的検査は "$TARGET"（bash 起動）の行だけを見る想定なので、
# ここは "${TARGET}" と書いて誤検出（env 5 本欠落の偽陽性）を避ける（起動ではなく grep の対象パス）。
assert_eq "cmux-next-model.sh: last_result_summary の参照 0" "0" "$(grep -c 'last_result_summary' "${TARGET}")"

echo "=== Projectsディレクトリが空でも --list は0行・rc=0 ==="
reset_vault
run_list_raw
assert_eq "空Vault: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "空Vault: 0行" "0" "$(wc -c < "$WORKDIR/list_stdout" | tr -d ' ')"
run_frame_raw
assert_eq "空Vault(--frame): P行0行" "0" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
# 2026-09-20 health-self-explain: データ源が無くても判定機は「不在＝OK」を返すので B 行は常に 1 行（FR-15）＝E は 1。
assert_eq "空Vault(--frame): B行は不在＝OKの1行" "B	外部脳	ok	OK" "$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout")"
assert_eq "空Vault(--frame): E行1（P 0＋B 1）" "1" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== 検証2巡目#26回帰: collect_entries内のsort失敗で--list rc≠0・0バイト、--frameが理由行（1巡目#7の固定） ==="
reset_vault
mk_note_N0 "$VAULT"
STUBBIN_SORT="$WORKDIR/stubbin-sort"
mkdir -p "$STUBBIN_SORT"
cat > "$STUBBIN_SORT/sort" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$STUBBIN_SORT/sort"
PATH="$STUBBIN_SORT:$PATH" run_list_raw
assert_eq "sort失敗: --list rc=1" "1" "$(cat "$WORKDIR/list_rc")"
assert_eq "sort失敗: --list stdoutは0バイト" "0" "$(wc -c < "$WORKDIR/list_stdout" | tr -d ' ')"
PATH="$STUBBIN_SORT:$PATH" run_frame_raw
assert_eq "sort失敗: --frameが理由行(外部脳応答なし)" "R	外部脳応答なし" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout")"
assert_eq "sort失敗: --frame終端E1" "1" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== 検証2巡目#29回帰: run_list末尾のrm -fがパイプのrcを上書きしない（1巡目#7と同型の取りこぼし） ==="
reset_vault
mk_note_N0 "$VAULT"
STUBBIN_AWK="$WORKDIR/stubbin-awk"
mkdir -p "$STUBBIN_AWK"
cat > "$STUBBIN_AWK/awk" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$STUBBIN_AWK/awk"
PATH="$STUBBIN_AWK:$PATH" run_list_raw
assert_true "run_list: 末尾整形パイプの失敗がrm -fに上書きされずrc≠0で伝播する" "$([ "$(cat "$WORKDIR/list_rc")" != "0" ] && echo 1 || echo 0)"

echo "=== AC-34相当: cmuxを一度も呼ばない ==="
reset_vault
mk_notes_N_all "$VAULT"
STUBBIN_N="$WORKDIR/stubbin-n"
mkdir -p "$STUBBIN_N"
CMUX_CALL_LOG_N="$WORKDIR/cmux_calls_n.log"
: > "$CMUX_CALL_LOG_N"
cat > "$STUBBIN_N/cmux" <<STUB
#!/bin/bash
echo "cmux \$*" >> "$CMUX_CALL_LOG_N"
exit 0
STUB
chmod +x "$STUBBIN_N/cmux"
PATH="$STUBBIN_N:$PATH" run_list_raw
PATH="$STUBBIN_N:$PATH" run_frame_raw
CMUX_CALLS_N="$(wc -l < "$CMUX_CALL_LOG_N" | tr -d ' ')"
assert_true "AC-34: --list/--frame実行でcmuxが1度も呼ばれない" "$([ "$CMUX_CALLS_N" -eq 0 ] && echo 1 || echo 0)"

echo "=== AC-33相当: Vault実行前後で不変（読み取りだけ） ==="
reset_vault
mk_notes_N_all "$VAULT"
vault_snapshot() {
  find "$1" -type f -print 2>/dev/null | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(stat -f '%N %m %z' "$f" 2>/dev/null)" "$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
  done
}
before="$(vault_snapshot "$VAULT")"
run_list_raw
run_frame_raw
after="$(vault_snapshot "$VAULT")"
assert_true "AC-33: 実行前後でVaultが不変" "$([ "$before" = "$after" ] && echo 1 || echo 0)"

echo "=== AC-117: 実際の供給側（スタブでない）をNext Project基底（N-0〜N-8全件）で20回連続実行し、中央値・最大値ともに0.4秒以下（単調時計） ==="
if command -v python3 >/dev/null 2>&1; then
  reset_vault
  mk_notes_N_all "$VAULT"
  mk_inventory_report "$INV_DIR" "2026-09-08" 3
  mk_maintenance_state "$MAINT_FILE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  AC117_TIMES="$WORKDIR/ac117_times.txt"
  : > "$AC117_TIMES"
  ac117_ok=1
  i=1
  while [ "$i" -le 20 ]; do
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" CMUX_NEXT_MAINT_STATE="$MAINT_FILE" \
      CMUX_NEXT_INVENTORY_LATEST="$INV_DIR/latest.json" \
      CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
      CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
      bash "$TARGET" --list >/dev/null 2>"$WORKDIR/ac117_err" || ac117_ok=0
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    python3 -c "print($t1 - $t0)" >> "$AC117_TIMES"
    i=$((i + 1))
  done
  assert_true "AC-117(Project): 20回とも正常終了" "$ac117_ok"
  AC117_STATS="$(python3 -c "
import statistics
vals = [float(x) for x in open('$AC117_TIMES')]
print(statistics.median(vals), max(vals))
")"
  AC117_MEDIAN="${AC117_STATS% *}"
  AC117_MAX="${AC117_STATS#* }"
  assert_true "AC-117(Project): 中央値が0.4秒以下（実測 ${AC117_MEDIAN}秒）" \
    "$(python3 -c "print(1 if $AC117_MEDIAN <= 0.4 else 0)")"
  assert_true "AC-117(Project): 最大値が0.4秒以下（実測 ${AC117_MAX}秒）" \
    "$(python3 -c "print(1 if $AC117_MAX <= 0.4 else 0)")"
else
  echo "SKIP: python3が無いためAC-117(Project)の単調時計計測を省略します"
fi

echo "=== 未知引数・併用・過剰引数は使い方1件・非0 ==="
for combo in "" "--once" "--plain" "--list --frame" "--frame extra"; do
  out="$(bash "$TARGET" $combo 2>"$WORKDIR/unk_err")"
  rc=$?
  assert_true "未知引数[$combo]: 非0で終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "未知引数[$combo]: stdout0バイト" "$([ -z "$out" ] && echo 1 || echo 0)"
  assert_true "未知引数[$combo]: 使い方がstderrに出る" "$(grep -q '使い方' "$WORKDIR/unk_err" && echo 1 || echo 0)"
done

# ==========================================================================
# v5: Project 枠「待ち」区分（requirements-v5.md §7 fixture WU-*・§8.1 AC-135〜138・
# §8.3 AC-146 ①②③・設計 §40.9 DT-17 ①②）。判定時刻は T0／T0s／T1 を
# CMUX_NEXT_JUDGE_NOW（テスト専用の固定口）で渡す。WU-N だけは固定口なし（NFR-16）。
# ==========================================================================
T0="2026-09-20T12:00"; T0S="2026-09-20T12:00:30"; T1="2026-09-25T10:00"
tab="$(printf '\t')"
AC135_EXPECTED="1${tab}p-active${tab}次を進める${tab}稼働中${tab}
2${tab}p-past${tab}返答を反映${tab}稼働中${tab}
3${tab}p-wait${tab}返事待ち${tab}待ち${tab}2026-09-25T10:00
4${tab}p-waitday${tab}再開${tab}待ち${tab}2026-09-25T00:00
5${tab}p-paused${tab}${tab}保留${tab}"
AC136_EXPECTED="1${tab}p-active${tab}次を進める${tab}稼働中${tab}
2${tab}p-past${tab}返答を反映${tab}稼働中${tab}
3${tab}p-edge${tab}境界${tab}稼働中${tab}
4${tab}p-badday${tab}暦外${tab}稼働中${tab}
5${tab}p-badtxt${tab}文字${tab}稼働中${tab}
6${tab}p-tz${tab}時差${tab}稼働中${tab}
7${tab}p-empty${tab}空値${tab}稼働中${tab}
8${tab}p-sameday${tab}当日${tab}稼働中${tab}
9${tab}p-wait${tab}返事待ち${tab}待ち${tab}2026-09-25T10:00
10${tab}p-waitday${tab}再開${tab}待ち${tab}2026-09-25T00:00
11${tab}p-quoted${tab}引用${tab}待ち${tab}2026-09-25T10:00
12${tab}p-nextyear${tab}年跨ぎ${tab}待ち${tab}2027-01-05T09:00
13${tab}p-squote${tab}単引${tab}待ち${tab}2026-09-25T10:00
14${tab}p-spaces${tab}空白${tab}待ち${tab}2026-09-25T10:00
15${tab}p-paused${tab}${tab}保留${tab}
16${tab}p-pausedbad${tab}保留無効${tab}保留${tab}"

echo "=== v5_ac135_list_5cols_T0: WU-A × T0 で --list が 5 行リテラル一致・rc=0 ==="
reset_vault
mk_notes_WU_A "$VAULT"
JUDGE_NOW="$T0" run_list_raw
assert_eq "v5_ac135: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_ac135: 5 行リテラル一致" "$AC135_EXPECTED" "$(cat "$WORKDIR/list_stdout")"
assert_eq "v5_ac135: stderr 0 行（WU-A に無効値は無い）" "0" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"

echo "=== v5_ac136_classes_T0: WU-B × T0 で 16 行リテラル一致・非表示 4 件・--frame は理由フレームにならない・無効値の診断（A-v5-3） ==="
reset_vault
mk_notes_WU_B "$VAULT"
JUDGE_NOW="$T0" run_list_raw
assert_eq "v5_ac136: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_ac136: 16 行リテラル一致" "$AC136_EXPECTED" "$(cat "$WORKDIR/list_stdout")"
for hidden in p-done p-nostatus p-closed p-unknown; do
  assert_not_contains "v5_ac136: 非表示 $hidden が出ない" "$(cat "$WORKDIR/list_stdout")" "$hidden"
done
# A-v5-3: 診断はキーあり＋非空＋正規化失敗の 3 件（WU-5・WU-6・WU-11）だけ。欠落（WU-10）・空値（WU-15）・保留（WU-16）は無し。
assert_eq "v5_ac136: 無効 wait_until の stderr が 3 行" "3" "$(grep -c 'wait_until が無効です' "$WORKDIR/list_stderr")"
assert_eq "v5_ac136: stderr は診断 3 行だけ" "3" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
for slug in p-badday p-badtxt p-tz; do
  assert_contains "v5_ac136: 診断に $slug" "$(cat "$WORKDIR/list_stderr")" ": $slug: "
done
for slug in p-empty p-active p-pausedbad; do
  assert_not_contains "v5_ac136: 診断なし $slug" "$(cat "$WORKDIR/list_stderr")" "$slug"
done
JUDGE_NOW="$T0" run_frame_raw
assert_eq "v5_ac136: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v5_ac136: --frame に R 行が無い（無効値で理由フレームにしない）" "0" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v5_ac136: --frame の P 行 16" "16" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"

echo "=== v5_ac136_minute_precision_T0s: T0s（12:00:30）でも同じ 16 行（p-edge は同時刻＝稼働中） ==="
JUDGE_NOW="$T0S" run_list_raw
assert_eq "v5_ac136_T0s: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_ac136_T0s: 16 行リテラル一致" "$AC136_EXPECTED" "$(cat "$WORKDIR/list_stdout")"

echo "=== v5_ac137_time_only_T1: WU-A × T1 で待ちが稼働中へ戻る（並び p-active・p-past・p-wait・p-waitday・保留 5） ==="
reset_vault
mk_notes_WU_A "$VAULT"
before_v5="$(vault_snapshot "$VAULT")"
JUDGE_NOW="$T0" run_list_raw
t0_out="$(cat "$WORKDIR/list_stdout")"
JUDGE_NOW="$T1" run_list_raw
assert_eq "v5_ac137: T1 rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_ac137: T1 の 5 行" "1${tab}p-active${tab}次を進める${tab}稼働中${tab}
2${tab}p-past${tab}返答を反映${tab}稼働中${tab}
3${tab}p-wait${tab}返事待ち${tab}稼働中${tab}
4${tab}p-waitday${tab}再開${tab}稼働中${tab}
5${tab}p-paused${tab}${tab}保留${tab}" "$(cat "$WORKDIR/list_stdout")"
assert_eq "v5_ac137: T0 は AC-135 の 5 行（同じ Vault・判定時刻だけの差）" "$AC135_EXPECTED" "$t0_out"
after_v5="$(vault_snapshot "$VAULT")"
assert_true "v5_ac137_vault_immutable: T0／T1 の実行前後で Vault がバイト不変" "$([ "$before_v5" = "$after_v5" ] && echo 1 || echo 0)"

echo "=== v5_ac137_realtime_WU_N: 固定口なし（実時刻）で t＋2 分が待ち・t−1 分が稼働中（NFR-16） ==="
reset_vault
wu_n_t="$(mk_notes_WU_N "$VAULT")"
JUDGE_NOW="" run_list_raw
assert_eq "v5_ac137_WU_N: rc=0（t=${wu_n_t}）" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_ac137_WU_N: p-plus2 が待ち" "待ち" "$(awk -F '\t' '$2=="p-plus2"{print $4}' "$WORKDIR/list_stdout")"
assert_eq "v5_ac137_WU_N: p-minus1 が稼働中・第 5 列空" "稼働中${tab}" "$(awk -F '\t' '$2=="p-minus1"{print $4 "\t" $5}' "$WORKDIR/list_stdout")"
assert_eq "v5_ac137_WU_N: p-plus2 の待ち日時は正規化形" "1" "$(awk -F '\t' '$2=="p-plus2"{print $5}' "$WORKDIR/list_stdout" | grep -c '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]$')"

echo "=== v5_ac138_frame_v4: WU-A × T0 の --frame＝#V /4・P 6 欄が --list と一致・B 1 行・E＝P＋B・理由フレームも /4 ==="
reset_vault
mk_notes_WU_A "$VAULT"
JUDGE_NOW="$T0" run_list_raw
JUDGE_NOW="$T0" run_frame_raw
assert_eq "v5_ac138: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v5_ac138: 1 行目が #V /4" "#V${tab}cmux-dock-frame/4${tab}Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "v5_ac138: P 行 5 行" "5" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v5_ac138: P 行は全行 6 欄" "0" "$(awk -F '\t' '$1=="P" && NF!=6' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v5_ac138: P 行の第 2〜6 欄が --list の 5 行と順序含め完全一致" "$(cat "$WORKDIR/list_stdout")" \
  "$(awk -F '\t' '$1=="P"{printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6}' "$WORKDIR/frame_stdout")"
assert_eq "v5_ac138: 待ち行だけ待ち日時が非空" "3 4" "$(awk -F '\t' '$1=="P" && $6!=""{printf "%s%s", (n++?" ":""), $2}' "$WORKDIR/frame_stdout")"
p_n="$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
b_n="$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v5_ac138: B 行 1 行" "1" "$b_n"
assert_eq "v5_ac138: E＝P＋B" "$(( p_n + b_n ))" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"
# 理由フレーム＝Projects ディレクトリを読めない状態そのもの（AC-138）＝①chmod 000 ②ディレクトリ不在。
chmod 000 "$VAULT/Projects"
JUDGE_NOW="$T0" run_frame_raw
JUDGE_NOW="$T0" run_list_raw
chmod 755 "$VAULT/Projects"
assert_eq "v5_ac138: Projects 読取不可（chmod 000）: 理由フレームの #V も /4" "#V${tab}cmux-dock-frame/4${tab}Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "v5_ac138: Projects 読取不可: R 行 1 行（既存の理由文）" "R${tab}外部脳応答なし" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout")"
assert_eq "v5_ac138: Projects 読取不可: P 行 0 行（空の正常フレームにしない）" "0" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v5_ac138: Projects 読取不可: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v5_ac138: Projects 読取不可: --list は非0" "1" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_ac138: Projects 読取不可: --list stdout 0 バイト" "0" "$(wc -c < "$WORKDIR/list_stdout" | tr -d ' ')"
assert_eq "v5_ac138: Projects 読取不可: --list stderr 1 行" "1" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
rm -rf "$VAULT/Projects"
JUDGE_NOW="$T0" run_frame_raw
assert_eq "v5_ac138: Projects 不在: 理由フレームの #V も /4" "#V${tab}cmux-dock-frame/4${tab}Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "v5_ac138: Projects 不在: R 行 1 行" "R${tab}外部脳応答なし" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout")"
assert_eq "v5_ac138: Projects 不在: E 1" "1" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== v5_ac138_no_v3_literal_aienv: ai-env の追跡ファイルで旧版リテラルが行単位 0 件（マーカー行を除く・マーカー行は ai-env では 0 行） ==="
# リテラルは分割して書く（本テスト自身が検査に引っかからないように）。
V3_LIT='cmux-dock-frame/'"3"
V3_MARK='# legacy-frame-version'" fixture"
REPO_ROOT_V5="$(cd "$SCRIPT_DIR/.." && pwd)"
v3_hits="$(git -C "$REPO_ROOT_V5" ls-files -z | xargs -0 grep -n -F -- "$V3_LIT" 2>/dev/null \
  | grep -v -E '^docs/[^:]*archive|^[^:]*requirements-v5(-notes)?\.md:' || true)"
v3_marked="$(printf '%s\n' "$v3_hits" | grep -F -- "$V3_MARK" | grep -c . || true)"
v3_unmarked="$(printf '%s\n' "$v3_hits" | grep -v -F -- "$V3_MARK" | grep -c . || true)"
assert_eq "v5_ac138: マーカー無しの旧版リテラル行が 0 件${v3_hits:+（実測: $v3_hits）}" "0" "$v3_unmarked"
assert_eq "v5_ac138: ai-env 側のマーカー行は 0 行（WU-Z (g) は dotfiles 側）" "0" "$v3_marked"

echo "=== v5_ac146（＝v6 AC-151 ③・NFR-18 の計測もこの 29 ノート入力で兼ねる）: 不変（WU-B を Next Project 基底に加えた入力）＝①cmux 0 回 ②Vault バイト不変 ③20 回の中央値 0.8 秒・最大値 1.2 秒以下（NFR-15 v5.8） ==="
reset_vault
mk_notes_N_all "$VAULT"
mk_notes_WU_B "$VAULT"
mk_inventory_report "$INV_DIR" "2026-09-08" 3
mk_maintenance_state "$MAINT_FILE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STUBBIN_V5="$WORKDIR/stubbin-v5"; mkdir -p "$STUBBIN_V5"
CMUX_CALL_LOG_V5="$WORKDIR/cmux_calls_v5.log"; : > "$CMUX_CALL_LOG_V5"
cat > "$STUBBIN_V5/cmux" <<STUB
#!/bin/bash
echo "cmux \$*" >> "$CMUX_CALL_LOG_V5"
exit 0
STUB
chmod +x "$STUBBIN_V5/cmux"
before_v5="$(vault_snapshot "$VAULT")"
PATH="$STUBBIN_V5:$PATH" JUDGE_NOW="$T0" run_list_raw
PATH="$STUBBIN_V5:$PATH" JUDGE_NOW="$T0" run_frame_raw
after_v5="$(vault_snapshot "$VAULT")"
assert_eq "v5_ac146_no_cmux_call: cmux の呼び出し 0 件" "0" "$(wc -l < "$CMUX_CALL_LOG_V5" | tr -d ' ')"
assert_true "v5_ac146_vault_bytes: 実行前後で Vault がバイト不変" "$([ "$before_v5" = "$after_v5" ] && echo 1 || echo 0)"
assert_eq "v5_ac146: --list の行数＝基底 8＋WU-B 16" "24" "$(wc -l < "$WORKDIR/list_stdout" | tr -d ' ')"
if command -v python3 >/dev/null 2>&1; then
  # NFR-15 v5.8＝29 ノート入力で中央値 0.8 秒以下・最大値 1.2 秒以下（20 回・単調時計）。計時は python 1 プロセスの
  # 中で供給側を 20 回起動して行う＝python 自身の起動時間（1 回 30〜40 ms）を供給側の
  # 所要に混ぜない（AC-117 の「python3 -c を前後で起こす」形はそれを含んでいた）。
  V5_STATS="$(CMUX_NEXT_JUDGE_NOW="$T0" CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" \
    CMUX_NEXT_MAINT_STATE="$MAINT_FILE" CMUX_NEXT_INVENTORY_LATEST="$INV_DIR/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
    CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    python3 - "$TARGET" <<'PY'
import statistics, subprocess, sys, time
vals, ok = [], 1
for _ in range(20):
    t0 = time.monotonic()
    r = subprocess.run(["bash", sys.argv[1], "--list"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    vals.append(time.monotonic() - t0)
    if r.returncode != 0:
        ok = 0
print(ok, statistics.median(vals), max(vals))
PY
)"
  set -- $V5_STATS
  echo "v5_ac146_perf_20runs: 実測 中央値=${2}秒 最大値=${3}秒"
  assert_true "v5_ac146_perf_20runs: 20 回とも rc=0" "$1"
  assert_true "v5_ac146_perf_20runs: 中央値 0.8 秒以下（実測 ${2}秒）" "$(python3 -c "print(1 if $2 <= 0.8 else 0)")"
  assert_true "v5_ac146_perf_20runs: 最大値 1.2 秒以下（実測 ${3}秒）" "$(python3 -c "print(1 if $3 <= 1.2 else 0)")"
else
  echo "SKIP: python3 が無いため v5_ac146_perf_20runs を省略します"
fi

echo "=== v5_dt17_judge_now_invalid: 固定口の不正 5 値は --list/--frame とも rc=1・stdout 0 バイト・stderr 1 行（理由フレームにしない）。境界 :59 は可 ==="
reset_vault
mk_notes_WU_B "$VAULT"
for bad in "来週" "2026-02-30T12:00" "2026-09-20T99:99" "2026-09-20T12:00:60" "2026-09-20T12:00:99"; do
  JUDGE_NOW="$bad" run_list_raw
  assert_eq "v5_dt17[$bad]: --list rc=1" "1" "$(cat "$WORKDIR/list_rc")"
  assert_eq "v5_dt17[$bad]: --list stdout 0 バイト" "0" "$(wc -c < "$WORKDIR/list_stdout" | tr -d ' ')"
  assert_eq "v5_dt17[$bad]: --list stderr 1 行" "1" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
  JUDGE_NOW="$bad" run_frame_raw
  assert_eq "v5_dt17[$bad]: --frame rc=1" "1" "$(cat "$WORKDIR/frame_rc")"
  assert_eq "v5_dt17[$bad]: --frame stdout 0 バイト（#V も R も出ない）" "0" "$(wc -c < "$WORKDIR/frame_stdout" | tr -d ' ')"
  assert_eq "v5_dt17[$bad]: --frame stderr 1 行" "1" "$(wc -l < "$WORKDIR/frame_stderr" | tr -d ' ')"
done
JUDGE_NOW="2026-09-20T12:00:59" run_list_raw
assert_eq "v5_dt17[:59]: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_dt17[:59]: T0 と同じ 16 行" "$AC136_EXPECTED" "$(cat "$WORKDIR/list_stdout")"

echo "=== v5_dt17_date_failure: 固定口なしで実時刻の date が失敗（PATH 先頭の偽 date）でも rc=1・stdout 0・stderr 1 行 ==="
STUBBIN_DATE="$WORKDIR/stubbin-date"; mkdir -p "$STUBBIN_DATE"
printf '#!/bin/bash\nexit 1\n' > "$STUBBIN_DATE/date"; chmod +x "$STUBBIN_DATE/date"
PATH="$STUBBIN_DATE:$PATH" JUDGE_NOW="" run_list_raw
assert_eq "v5_dt17_date: --list rc=1" "1" "$(cat "$WORKDIR/list_rc")"
assert_eq "v5_dt17_date: --list stdout 0 バイト" "0" "$(wc -c < "$WORKDIR/list_stdout" | tr -d ' ')"
assert_eq "v5_dt17_date: --list stderr 1 行" "1" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
PATH="$STUBBIN_DATE:$PATH" JUDGE_NOW="" run_frame_raw
assert_eq "v5_dt17_date: --frame rc=1" "1" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v5_dt17_date: --frame stdout 0 バイト" "0" "$(wc -c < "$WORKDIR/frame_stdout" | tr -d ' ')"
assert_eq "v5_dt17_date: --frame stderr 1 行" "1" "$(wc -l < "$WORKDIR/frame_stderr" | tr -d ' ')"

# ==========================================================================
# v6: 待ち日時の版付け（requirements-v6.md §7 WV-1〜27・WV-A／WV-B・§8.1 AC-148〜151・
# §8.5 AC-154 (a)・design.md §41.9.4 DT-23・25・26・27・28・33）。判定時刻は v5 と同じ
# T0／T1 を CMUX_NEXT_JUDGE_NOW で渡す。診断の固定語（§41.5.4）＝「無効」／「使わない」／
# `解析できない`。slug の照合は前後が slug 文字（[a-z0-9-]）でない位置だけ数える
# （v-bad が v-badday・v-badfirst に当たらないように）。
# ==========================================================================
slug_hits() {   # $1=slug $2=file → slug を含む行数
  grep -cE -- "(^|[^a-z0-9-])$1([^a-z0-9-]|\$)" "$2"
}
diag_line() {   # $1=slug → stderr のその slug の行
  grep -E -- "(^|[^a-z0-9-])$1([^a-z0-9-]|\$)" "$WORKDIR/list_stderr"
}
AC148_EXPECTED="1${tab}v-prev${tab}次版${tab}稼働中${tab}
2${tab}v-fm${tab}fm${tab}稼働中${tab}
3${tab}v-cur${tab}返事待ち${tab}待ち${tab}2026-09-25T10:00
4${tab}v-nofm${tab}待つ${tab}待ち${tab}2026-09-25T10:00
5${tab}v-paused${tab}止${tab}保留${tab}"
AC149_EXPECTED="1${tab}v-prev${tab}次版${tab}稼働中${tab}
2${tab}v-fm${tab}fm${tab}稼働中${tab}
3${tab}v-past${tab}過去${tab}稼働中${tab}
4${tab}v-bad${tab}無効${tab}稼働中${tab}
5${tab}v-indent${tab}字下げ${tab}稼働中${tab}
6${tab}v-sec${tab}秒${tab}稼働中${tab}
7${tab}v-tz${tab}時差${tab}稼働中${tab}
8${tab}v-badday${tab}暦外${tab}稼働中${tab}
9${tab}v-badfirst${tab}先頭無効${tab}稼働中${tab}
10${tab}v-outside${tab}範囲外${tab}稼働中${tab}
11${tab}v-other${tab}別節${tab}稼働中${tab}
12${tab}v-after${tab}節後${tab}稼働中${tab}
13${tab}v-cur${tab}返事待ち${tab}待ち${tab}2026-09-25T10:00
14${tab}v-nofm${tab}待つ${tab}待ち${tab}2026-09-25T10:00
15${tab}v-next${tab}v3${tab}待ち${tab}2026-09-26T10:00
16${tab}v-done${tab}完了${tab}待ち${tab}2026-09-25T10:00
17${tab}v-two${tab}二行${tab}待ち${tab}2026-09-25T10:00
18${tab}v-day${tab}日付${tab}待ち${tab}2026-09-25T00:00
19${tab}v-first${tab}zzz${tab}待ち${tab}2026-09-25T10:00
20${tab}v-bothfm${tab}両方${tab}待ち${tab}2026-09-25T10:00
21${tab}v-empty${tab}空版${tab}待ち${tab}2026-09-28T10:00
22${tab}v-quoted${tab}引用${tab}待ち${tab}2026-09-25T10:00
23${tab}v-spaces${tab}空白${tab}待ち${tab}2026-09-25T10:00
24${tab}v-squote${tab}単引${tab}待ち${tab}2026-09-25T10:00
25${tab}v-noheads${tab}見出無${tab}待ち${tab}2026-09-28T10:00
26${tab}v-blank${tab}空本文${tab}待ち${tab}2026-09-28T10:00
27${tab}v-paused${tab}止${tab}保留${tab}"
AC149_T1_EXPECTED="1${tab}v-cur${tab}返事待ち${tab}稼働中${tab}
2${tab}v-prev${tab}次版${tab}稼働中${tab}
3${tab}v-fm${tab}fm${tab}稼働中${tab}
4${tab}v-nofm${tab}待つ${tab}稼働中${tab}
5${tab}v-paused${tab}止${tab}保留${tab}"

echo "=== v6_ac148_version_wait_5cols_T0: WV-A × T0 で --list が 5 行リテラル一致・rc=0・--frame の #V /4 と P 行 6 欄が一致（FR-108） ==="
reset_vault
mk_notes_WV_A "$VAULT"
JUDGE_NOW="$T0" run_list_raw
assert_eq "v6_ac148: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v6_ac148: 5 行リテラル一致（v-prev＝前の版の待ちは効かない・v-fm＝▶ の版があるので frontmatter を見ない・v-cur＝▶ の版 v2 の待ち・v-nofm＝Tasks 節なしは frontmatter・v-paused＝保留）" "$AC148_EXPECTED" "$(cat "$WORKDIR/list_stdout")"
JUDGE_NOW="$T0" run_frame_raw
assert_eq "v6_ac148: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v6_ac148: --frame 1 行目が #V /4（契約不変）" "#V${tab}cmux-dock-frame/4${tab}Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "v6_ac148: P 行 5 行" "5" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v6_ac148: P 行は全行 6 欄" "0" "$(awk -F '\t' '$1=="P" && NF!=6' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v6_ac148: P 行の第 2〜6 欄が --list の 5 行と順序含め完全一致" "$AC148_EXPECTED" \
  "$(awk -F '\t' '$1=="P"{printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6}' "$WORKDIR/frame_stdout")"
assert_eq "v6_ac148: --frame に R 行なし" "0" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"

echo "=== v6_ac149_classes_T0: WV-B × T0 で --list が 27 行リテラル一致・rc=0・stderr の診断ちょうど 7 行（slug＋固定語＋値）・除外 9 slug は 0 行 ==="
reset_vault
mk_notes_WV_B "$VAULT"
JUDGE_NOW="$T0" run_list_raw
assert_eq "v6_ac149: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v6_ac149: 27 行リテラル一致（▶ の版が無い 5 分類＝v-nofm・v-done・v-empty・v-noheads・v-blank は frontmatter が効く）" "$AC149_EXPECTED" "$(cat "$WORKDIR/list_stdout")"
assert_eq "v6_ac149: stderr の診断はちょうど 7 行" "7" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
for slug in v-fm v-bad v-bothfm v-sec v-tz v-badday v-badfirst; do
  assert_eq "v6_ac149: 診断に $slug を含む行がちょうど 1 行" "1" "$(slug_hits "$slug" "$WORKDIR/list_stderr")"
done
for slug in v-indent v-outside v-other v-after v-paused v-empty v-noheads v-blank v-two; do
  assert_eq "v6_ac149: 診断に $slug を含む行が 0（読まない・順 2・順 5 は診断なし）" "0" "$(slug_hits "$slug" "$WORKDIR/list_stderr")"
done
# §41.5.4: 種別の固定語と値。「使わない」（frontmatter 残存）＝v-fm・v-bothfm、「無効」（版の待ち行）＝5 件。
assert_eq "v6_ac149: 「使わない」 の行は 2 行" "2" "$(grep -c '使わない' "$WORKDIR/list_stderr")"
assert_eq "v6_ac149: 「無効」 の行は 5 行" "5" "$(grep -c '無効' "$WORKDIR/list_stderr")"
assert_contains "v6_ac149: v-fm の行＝使わない＋frontmatter の値" "$(diag_line v-fm)" "使わない"
assert_contains "v6_ac149: v-fm の行に frontmatter の値 2026-09-25T10:00" "$(diag_line v-fm)" "2026-09-25T10:00"
assert_not_contains "v6_ac149: v-fm の行に 「無効」 は無い" "$(diag_line v-fm)" "無効"
assert_contains "v6_ac149: v-bothfm の行＝使わない" "$(diag_line v-bothfm)" "使わない"
assert_contains "v6_ac149: v-bothfm の行に frontmatter の値 2026-09-30T10:00" "$(diag_line v-bothfm)" "2026-09-30T10:00"
assert_not_contains "v6_ac149: v-bothfm の行に 「無効」 は無い" "$(diag_line v-bothfm)" "無効"
for pair in "v-bad|来週" "v-sec|2026-09-25T10:00:00" "v-tz|2026-09-25T10:00+09:00" "v-badday|2026-02-30T10:00" "v-badfirst|来週"; do
  slug="${pair%%|*}"; val="${pair#*|}"
  assert_contains "v6_ac149: $slug の行＝無効" "$(diag_line "$slug")" "無効"
  assert_contains "v6_ac149: $slug の行に書かれた値 $val" "$(diag_line "$slug")" "$val"
  assert_not_contains "v6_ac149: $slug の行に 「使わない」 は無い" "$(diag_line "$slug")" "使わない"
done
JUDGE_NOW="$T0" run_frame_raw
assert_eq "v6_ac149: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v6_ac149: --frame に R 行が無い（診断で理由フレームにしない）" "0" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v6_ac149: --frame の P 行 27" "27" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
echo "=== v6_dt28_frame_same_classes: --frame の P 行第 2〜6 欄が WV-B 27 件の --list と順序含め完全一致（分類経路が 1 本） ==="
assert_eq "v6_dt28: P 行の第 2〜6 欄＝--list 27 行" "$AC149_EXPECTED" \
  "$(awk -F '\t' '$1=="P"{printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6}' "$WORKDIR/frame_stdout")"
assert_eq "v6_dt28: P 行は全行 6 欄" "0" "$(awk -F '\t' '$1=="P" && NF!=6' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"

echo "=== v6_ac149_time_only_T1: WV-A × T1 で v-cur・v-nofm が稼働中・第 5 列空。T0／T1 の前後で Vault のファイル集合と内容がバイト不変 ==="
reset_vault
mk_notes_WV_A "$VAULT"
before_v6="$(vault_snapshot "$VAULT")"
JUDGE_NOW="$T0" run_list_raw
t0_out_v6="$(cat "$WORKDIR/list_stdout")"
JUDGE_NOW="$T1" run_list_raw
assert_eq "v6_ac149_T1: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v6_ac149_T1: 5 行（v-cur・v-nofm が稼働中・第 5 列空）" "$AC149_T1_EXPECTED" "$(cat "$WORKDIR/list_stdout")"
assert_eq "v6_ac149_T1: T0 は AC-148 の 5 行（同じ Vault・判定時刻だけの差）" "$AC148_EXPECTED" "$t0_out_v6"
after_v6="$(vault_snapshot "$VAULT")"
assert_true "v6_ac149_vault_immutable: T0／T1 の実行前後で Vault がバイト不変" "$([ "$before_v6" = "$after_v6" ] && echo 1 || echo 0)"

echo "=== v6_ac151_invariants: WV-B 入力で ①cmux を一度も呼ばない ②Vault がバイト不変（③所要＝v5_ac146 の 29 ノート計測・④回帰 11 本＝test-runner） ==="
reset_vault
mk_notes_WV_B "$VAULT"
STUBBIN_V6="$WORKDIR/stubbin-v6"; mkdir -p "$STUBBIN_V6"
CMUX_CALL_LOG_V6="$WORKDIR/cmux_calls_v6.log"; : > "$CMUX_CALL_LOG_V6"
cat > "$STUBBIN_V6/cmux" <<STUB
#!/bin/bash
echo "cmux \$*" >> "$CMUX_CALL_LOG_V6"
exit 0
STUB
chmod +x "$STUBBIN_V6/cmux"
before_v6="$(vault_snapshot "$VAULT")"
PATH="$STUBBIN_V6:$PATH" JUDGE_NOW="$T0" run_list_raw
PATH="$STUBBIN_V6:$PATH" JUDGE_NOW="$T0" run_frame_raw
after_v6="$(vault_snapshot "$VAULT")"
assert_eq "v6_ac151①: cmux の呼び出し 0 件" "0" "$(wc -l < "$CMUX_CALL_LOG_V6" | tr -d ' ')"
assert_true "v6_ac151②: 実行前後で Vault がバイト不変" "$([ "$before_v6" = "$after_v6" ] && echo 1 || echo 0)"
assert_eq "v6_ac151: --list は 27 行・rc=0" "27 0" "$(wc -l < "$WORKDIR/list_stdout" | tr -d ' ') $(cat "$WORKDIR/list_rc")"

echo "=== v6_dt23_25_26_27: ▶ でない版の無効行（DT-23）・空値（DT-25 (i)）・保留の next 導出（DT-26）・版見出し前の行（DT-27）＝診断 0 行 ==="
reset_vault
# DT-23: ▶ の版 v2 は待ち行なし。▶ でない v1 にだけ無効な待ち行 → 稼働中・診断 0。
_mk_note_WV "$VAULT" v-dt23 'status: active' 2026-09-19 'next: dt23' '' $'## Tasks\n### v1\n- [x] a\n- wait_until: 来週\n### v2\n- [/] b\n'
# DT-25 (i): 空値（`- wait_until:` だけ）・frontmatter なし → 稼働中・第 5 列空・診断 0。
_mk_note_WV "$VAULT" v-dt25i 'status: active' 2026-09-18 'next: dt25i' '' $'## Tasks\n### v1\n- [/] a\n- wait_until:\n'
# DT-26: paused・next: 空・未完タスクあり・版の待ち行が無効 → 保留・next 欄は先頭未完タスクから導出・第 5 列空・診断 0。
_mk_note_WV "$VAULT" v-dt26 'status: paused' 2026-09-17 'next:' '' $'## Tasks\n### v1\n- [ ] 先頭未完\n- wait_until: 来週\n'
# DT-27 (a): 版見出しの前にチェックリストと待ち行・後に版 v1（待ち行なし） → 稼働中（前の行を v1 に帰属させない）。
_mk_note_WV "$VAULT" v-dt27a 'status: active' 2026-09-16 'next: dt27a' '' $'## Tasks\n- [ ] stray\n- wait_until: 2026-09-25T10:00\n### v1\n- [/] a\n'
# DT-27 (b): 同じ形で v1 に別の待ち行 → v1 の行だけが効く（09-26。09-25 ではない）。
_mk_note_WV "$VAULT" v-dt27b 'status: active' 2026-09-15 'next: dt27b' '' $'## Tasks\n- [ ] stray\n- wait_until: 2026-09-25T10:00\n### v1\n- [/] a\n- wait_until: 2026-09-26T10:00\n'
JUDGE_NOW="$T0" run_list_raw
assert_eq "v6_dt23-27: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v6_dt23-27: stderr 0 行（どれも診断なし）" "0" "$(wc -c < "$WORKDIR/list_stderr" | tr -d ' ')"
assert_eq "v6_dt23: v-dt23 は稼働中・第 5 列空" "稼働中${tab}" "$(awk -F '\t' '$2=="v-dt23"{print $4 "\t" $5}' "$WORKDIR/list_stdout")"
assert_eq "v6_dt25(i): v-dt25i は稼働中・第 5 列空" "稼働中${tab}" "$(awk -F '\t' '$2=="v-dt25i"{print $4 "\t" $5}' "$WORKDIR/list_stdout")"
assert_eq "v6_dt26: v-dt26 は保留・next 欄は導出値・第 5 列空" "先頭未完${tab}保留${tab}" "$(awk -F '\t' '$2=="v-dt26"{print $3 "\t" $4 "\t" $5}' "$WORKDIR/list_stdout")"
assert_eq "v6_dt27(a): v-dt27a は稼働中・第 5 列空" "稼働中${tab}" "$(awk -F '\t' '$2=="v-dt27a"{print $4 "\t" $5}' "$WORKDIR/list_stdout")"
assert_eq "v6_dt27(b): v-dt27b は v1 の待ち行だけで待ち（2026-09-26T10:00）" "待ち${tab}2026-09-26T10:00" "$(awk -F '\t' '$2=="v-dt27b"{print $4 "\t" $5}' "$WORKDIR/list_stdout")"

echo "=== v6_dt25_ii_empty_value_with_fm: 空値の待ち行＋frontmatter に将来の値 → 稼働中・第 5 列空・診断ちょうど 1 行（使わない・無効を含まない） ==="
reset_vault
_mk_note_WV "$VAULT" v-dt25ii 'status: active' 2026-09-18 'next: dt25ii' 'wait_until: 2026-09-28T10:00' $'## Tasks\n### v1\n- [/] a\n- wait_until:\n'
JUDGE_NOW="$T0" run_list_raw
assert_eq "v6_dt25(ii): rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v6_dt25(ii): 稼働中・第 5 列空（空値で frontmatter に倒さない）" "1${tab}v-dt25ii${tab}dt25ii${tab}稼働中${tab}" "$(cat "$WORKDIR/list_stdout")"
assert_eq "v6_dt25(ii): stderr ちょうど 1 行" "1" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
assert_contains "v6_dt25(ii): 診断は使わない（frontmatter 残存）" "$(cat "$WORKDIR/list_stderr")" "使わない"
assert_contains "v6_dt25(ii): 診断に slug" "$(cat "$WORKDIR/list_stderr")" "v-dt25ii"
assert_not_contains "v6_dt25(ii): 診断に無効は無い（空値は無効ではない）" "$(cat "$WORKDIR/list_stderr")" "無効"

echo "=== v6_dt33_unparseable: 差し替え口 CMUX_VAULT_TASKS_SANITIZE_FAIL=1 で解析不能＝稼働中・第 5 列空・診断 1 行（解析できない＋slug）・frontmatter 不採用・理由フレームにしない・口の名前が本番設定に 0 件 ==="
reset_vault
_mk_note_WV "$VAULT" v-dt33 'status: active' 2026-09-19 'next: dt33' 'wait_until: 2026-09-28T10:00' $'## Tasks\n### v1\n- [/] a\n'
mk_note_WV4 "$VAULT"   # Tasks 見出しなし＝解析を起こさない対照（口の影響を受けず frontmatter で待ち）
CMUX_VAULT_TASKS_SANITIZE_FAIL=1 JUDGE_NOW="$T0" run_list_raw
assert_eq "v6_dt33: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "v6_dt33: 2 行＝v-dt33 稼働中・空（frontmatter の 09-28 を採用しない）・v-nofm は待ち" "1${tab}v-dt33${tab}dt33${tab}稼働中${tab}
2${tab}v-nofm${tab}待つ${tab}待ち${tab}2026-09-25T10:00" "$(cat "$WORKDIR/list_stdout")"
assert_eq "v6_dt33: stderr ちょうど 1 行" "1" "$(wc -l < "$WORKDIR/list_stderr" | tr -d ' ')"
assert_contains "v6_dt33: 診断の固定語 解析できない" "$(cat "$WORKDIR/list_stderr")" "解析できない"
assert_eq "v6_dt33: 診断に slug v-dt33" "1" "$(slug_hits v-dt33 "$WORKDIR/list_stderr")"
assert_not_contains "v6_dt33: 診断に 使わない は無い" "$(cat "$WORKDIR/list_stderr")" "使わない"
assert_not_contains "v6_dt33: 診断に 無効 は無い" "$(cat "$WORKDIR/list_stderr")" "無効"
CMUX_VAULT_TASKS_SANITIZE_FAIL=1 JUDGE_NOW="$T0" run_frame_raw
assert_eq "v6_dt33: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v6_dt33: --frame に R 行なし" "0" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v6_dt33: --frame の v-dt33 は稼働中・待ち日時空" "稼働中${tab}" "$(awk -F '\t' '$1=="P" && $3=="v-dt33"{print $5 "\t" $6}' "$WORKDIR/frame_stdout")"
# 対照＝口なしなら同じ Vault で v-dt33 は「▶ の版あり・待ち行なし・frontmatter 残存」＝稼働中＋使わない 1 行。
JUDGE_NOW="$T0" run_list_raw
assert_eq "v6_dt33(対照): 口なしでは診断 1 行＝使わない（解析できない は出ない）" "1 0" "$(grep -c '使わない' "$WORKDIR/list_stderr") $(grep -c '解析できない' "$WORKDIR/list_stderr")"
# 静的: 差し替え口の名前が本番設定に 0 件（F-81 と同型。dock.json は dotfiles があるときだけ・launchd/ は存在するときだけ）。
REPO_ROOT_V6="$(cd "$SCRIPT_DIR/.." && pwd)"
# 対象＝config/・launchagents/（本 repo の launchd plist 置き場＝実在必須・空振り防止）・scripts/install*・dock.json（dotfiles があるときだけ）。
# 2 つの口（CMUX_VAULT_TASKS_SANITIZE_FAIL・BOOTSTRAP_CMUX_LIB_DIR＝A-v6-7）とも 0 件。
dt33_targets="$REPO_ROOT_V6/config $REPO_ROOT_V6/launchagents"
assert_true "v6_dt33(静的): config/ と launchagents/ が実在する（検査の空振り防止）" "$([ -d "$REPO_ROOT_V6/config" ] && [ -d "$REPO_ROOT_V6/launchagents" ] && echo 1 || echo 0)"
for f in "$REPO_ROOT_V6"/scripts/install*; do [ -f "$f" ] && dt33_targets="$dt33_targets $f"; done
[ -f "$HOME/work/dotfiles/cmux/dock.json" ] && dt33_targets="$dt33_targets $HOME/work/dotfiles/cmux/dock.json"
# shellcheck disable=SC2086
dt33_leak="$(grep -rlE -- 'CMUX_VAULT_TASKS_SANITIZE_'"FAIL"'|BOOTSTRAP_CMUX_LIB_'"DIR" $dt33_targets 2>/dev/null | grep -c . || true)"
assert_eq "v6_dt33(静的): テスト用の口 2 つの名前が本番設定（config/・launchagents/・scripts/install*・dock.json）に 0 件" "0" "$dt33_leak"

echo "=== v6_ac154a_doc: cmux-next-model.sh の冒頭コメントと usage に「▶ の版」「frontmatter」「wait_until」の説明がある（AC-154 (a)） ==="
head_comment="$(sed -n '1,80p' "${TARGET}" | grep '^#' || true)"
assert_contains "v6_ac154a: 冒頭コメントに ▶ の版" "$head_comment" "▶ の版"
assert_contains "v6_ac154a: 冒頭コメントに frontmatter" "$head_comment" "frontmatter"
assert_contains "v6_ac154a: 冒頭コメントに wait_until" "$head_comment" "wait_until"
bash "${TARGET}" >/dev/null 2>"$WORKDIR/usage_err" || true
assert_contains "v6_ac154a: usage に ▶ の版" "$(cat "$WORKDIR/usage_err")" "▶ の版"
assert_contains "v6_ac154a: usage に frontmatter" "$(cat "$WORKDIR/usage_err")" "frontmatter"

# ==========================================================================
# v7: Project 枠の宣言先照会の口 `--focus`（requirements-v7.md v7.3 §7 FV-1〜11・FV-A／B・
# FD-1〜10 と派生・T0／§8 AC-158・AC-160・AC-162・AC-163 ①⑤／design.md §42.5（状態遷移・
# 出力契約）・§42.9 MP 層・DT-35・36・39・42）。
# 照会口＝隔離 HOME の宣言記録（Task 供給側と同名の既定の置き場 ~/.config/cmux-task-watch/
# workspaces.json）＋PATH 先頭の cmux スタブ（既定の実体名 cmux）。上限の既定値は固定しない
# （所要は ≤4 秒＝上限 3＋1 で判定）。設計 §42.5 の契約＝stdout ちょうど 1 行（slug／空行・LF 終端）・
# stderr は空行のときだけ理由 1 行（cmux 応答なし／対象不明／宣言記録破損／未宣言）・rc 0。
# ==========================================================================
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT CMUX_NEXT_FOCUS_TIMEOUT
FD_HOME="$WORKDIR/fd-home"; FD_STATE="$WORKDIR/fd-state"; FD_BIN="$WORKDIR/fd-bin"
FD_RECORD="$FD_HOME/.config/cmux-task-watch/workspaces.json"
mkdir -p "$FD_BIN"
write_fd_cmux_stub "$FD_BIN/cmux"
export FD_STATE

# fd_apply <FD id> — 宣言記録とスタブ状態を FD-n に合わせる（id の p＝′。例: 3p＝FD-3′）。
fd_apply() {
  mk_fd_record "$FD_RECORD" base
  reset_fd_state "$FD_STATE" workspace:1
  case "$1" in
    1)  ;;
    2)  echo workspace:2 > "$FD_STATE/focused_ref" ;;
    3)  echo workspace:3 > "$FD_STATE/focused_ref" ;;
    3p) mk_fd_record "$FD_RECORD" hold7; echo workspace:3 > "$FD_STATE/focused_ref" ;;
    4)  echo workspace:9 > "$FD_STATE/focused_ref" ;;
    5)  touch "$FD_STATE/fail_identify" ;;
    5p) touch "$FD_STATE/fail_workspace_list" ;;
    6)  mk_fd_record "$FD_RECORD" corrupt ;;
    6p) mk_fd_record "$FD_RECORD" badslug ;;
    7)  echo workspace:77 > "$FD_STATE/focused_ref" ;;
    8)  echo workspace:4 > "$FD_STATE/focused_ref" ;;
    8p) mk_fd_record "$FD_RECORD" none6; echo workspace:6 > "$FD_STATE/focused_ref" ;;
    9)  touch "$FD_STATE/hang_identify" ;;
    9p) touch "$FD_STATE/hang_workspace_list" ;;
    10) echo workspace:5 > "$FD_STATE/focused_ref" ;;
    *) echo "fd_apply: unknown FD $1" >&2; return 1 ;;
  esac
}

# run_focus_raw — 隔離 HOME・PATH 先頭の FD スタブで --focus を 1 回。FOCUS_VAULT（空＝$VAULT）・
# FOCUS_TIMEOUT（空＝既定）・FOCUS_PATH_PREFIX（スパイ用）・JUDGE_NOW で条件を変える。
# 既定が実ファイルの env 5 本は存在しないパス固定（照会口は読まない＝DT-36）。所要を focus_elapsed に残す。
FOCUS_VAULT=""; FOCUS_TIMEOUT=""; FOCUS_PATH_PREFIX=""
run_focus_raw() {
  local t0 t1
  t0="$(python3 -c 'import time; print(time.monotonic())')"
  HOME="$FD_HOME" PATH="${FOCUS_PATH_PREFIX:+$FOCUS_PATH_PREFIX:}$FD_BIN:$PATH" \
  CMUX_NEXT_FOCUS_TIMEOUT="$FOCUS_TIMEOUT" CMUX_NEXT_JUDGE_NOW="$JUDGE_NOW" \
  CMUX_NEXT_VAULT="${FOCUS_VAULT:-$VAULT}" CMUX_NEXT_INVENTORY_DIR="/nonexistent-dir" \
    CMUX_NEXT_MAINT_STATE="/nonexistent-dir/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="/nonexistent-dir/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
    CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    bash "$TARGET" --focus > "$WORKDIR/focus_stdout" 2>"$WORKDIR/focus_stderr"
  printf '%s' "$?" > "$WORKDIR/focus_rc"
  t1="$(python3 -c 'import time; print(time.monotonic())')"
  focus_elapsed="$(python3 -c "print($t1 - $t0)")"
}

# assert_focus <desc> <期待 slug（空＝空行）> <期待 stderr（空＝0 バイト）> — 設計 §42.5.3 の契約を 1 回分検査。
assert_focus() {
  local desc="$1" slug="$2" reason="$3"
  assert_eq "$desc: rc=0" "0" "$(cat "$WORKDIR/focus_rc")"
  assert_eq "$desc: stdout はちょうど 1 行（LF 終端）" "1" "$(wc -l < "$WORKDIR/focus_stdout" | tr -d ' ')"
  assert_eq "$desc: stdout の行＝[$slug]" "$slug" "$(cat "$WORKDIR/focus_stdout")"
  if [ -n "$slug" ]; then
    assert_eq "$desc: stderr 0 バイト（slug が出るとき理由は無い）" "0" "$(wc -c < "$WORKDIR/focus_stderr" | tr -d ' ')"
  else
    assert_eq "$desc: stdout は空行 1 バイト" "1" "$(wc -c < "$WORKDIR/focus_stdout" | tr -d ' ')"
    assert_eq "$desc: stderr は理由 1 行＝[$reason]" "$reason" "$(cat "$WORKDIR/focus_stderr")"
    assert_eq "$desc: stderr は 1 行だけ" "1" "$(wc -l < "$WORKDIR/focus_stderr" | tr -d ' ')"
  fi
}

FV_A_LIST="1${tab}p-act1${tab}設計${tab}稼働中${tab}
2${tab}p-act2${tab}実装${tab}稼働中${tab}
3${tab}roles-conf${tab}職種を設定だけで縛る${tab}待ち${tab}2026-12-31T23:59
4${tab}p-hold${tab}止${tab}保留${tab}"
FV_B_LIST="${FV_A_LIST}
5${tab}p-hold2${tab}h2${tab}保留${tab}
6${tab}p-hold3${tab}h3${tab}保留${tab}
7${tab}p-hold4${tab}h4${tab}保留${tab}
8${tab}p-hold5${tab}h5${tab}保留${tab}
9${tab}p-hold6${tab}h6${tab}保留${tab}
10${tab}p-hold7${tab}h7${tab}保留${tab}"

echo "=== v7_ac158_focus_three_classes（AC-158 MP）: FD-1・2・3 で --focus が p-act2／roles-conf／p-hold の 1 行・stderr 0・rc 0。FV-A×T0 の --frame は P 行 4 行（6 欄・--list と一致）・#V /4 ==="
reset_vault
mk_notes_FV_A "$VAULT"
JUDGE_NOW="$T0"
fd_apply 1; run_focus_raw; assert_focus "v7_ac158[FD-1 稼働中]" "p-act2" ""
fd_apply 2; run_focus_raw; assert_focus "v7_ac158[FD-2 待ち]" "roles-conf" ""
fd_apply 3; run_focus_raw; assert_focus "v7_ac158[FD-3 保留]" "p-hold" ""
# 設定口（Task 供給側・宣言 CLI と同名）＝CMUX_TASK_STATE で記録の置き場を差し替えられる（既定は隔離 HOME の置き場）。
fd_apply 3
mk_fd_record "$WORKDIR/fd-alt-record.json" hold7
CMUX_TASK_STATE="$WORKDIR/fd-alt-record.json" run_focus_raw
assert_focus "v7_ac158[CMUX_TASK_STATE で別の記録（U3→p-hold7）へ]" "p-hold7" ""
fd_apply 1
PATH="$FD_BIN:$PATH" JUDGE_NOW="$T0" run_frame_raw
assert_eq "v7_ac158: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v7_ac158: --frame 1 行目が #V /4（契約不変）" "#V${tab}cmux-dock-frame/4${tab}Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "v7_ac158: P 行 4 行" "4" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v7_ac158: P 行は全行 6 欄" "0" "$(awk -F '\t' '$1=="P" && NF!=6' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v7_ac158: P 行の第 2〜6 欄＝FV-A の 4 行（v6 と同じ欄）" "$FV_A_LIST" \
  "$(awk -F '\t' '$1=="P"{printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6}' "$WORKDIR/frame_stdout")"
assert_eq "v7_ac158: --frame に R 行なし" "0" "$(awk -F '\t' '$1=="R"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"

echo "=== v7_focus_usage（設計 §42.5.3）: --focus と他の引数の併用・過剰引数は使い方 1 件・非 0・stdout 0 バイト ==="
for combo in "--focus --list" "--list --focus" "--focus --frame" "--focus extra"; do
  out="$(HOME="$FD_HOME" PATH="$FD_BIN:$PATH" bash "$TARGET" $combo 2>"$WORKDIR/unk_err")"
  rc=$?
  assert_true "v7_focus_usage[$combo]: 非 0 で終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "v7_focus_usage[$combo]: stdout 0 バイト" "$([ -z "$out" ] && echo 1 || echo 0)"
  assert_true "v7_focus_usage[$combo]: 使い方が stderr に出る" "$(grep -q '使い方' "$WORKDIR/unk_err" && echo 1 || echo 0)"
done

echo "=== v7_ac160_focus_13_states（AC-160 MP）: 空行 7 状態の理由語（順 1〜4）・FD-8／8′／10 の 1 行・FD-9／9′ の所要 ≤4 秒（上限 3＋1）・13 状態で Vault と宣言記録がバイト不変（cksum） ==="
reset_vault
mk_notes_FV_A "$VAULT"
JUDGE_NOW="$T0"
fd10_out=""; fd1_out=""
for spec in "1|p-act2|" "2|roles-conf|" "3|p-hold|" "4||未宣言" "5||cmux 応答なし" "5p||cmux 応答なし" \
            "6||宣言記録破損" "7||対象不明" "8|p-done|" "8p|p-none|" "9||cmux 応答なし" "9p||cmux 応答なし" "10|p-act2|"; do
  id="${spec%%|*}"; rest="${spec#*|}"; slug="${rest%%|*}"; reason="${rest#*|}"
  label="FD-${id%p}"; [ "${id%p}" != "$id" ] && label="${label}′"
  fd_apply "$id"
  before_vault="$(vault_snapshot "$VAULT")"; before_rec="$(cksum "$FD_RECORD")"
  run_focus_raw
  after_vault="$(vault_snapshot "$VAULT")"; after_rec="$(cksum "$FD_RECORD")"
  assert_focus "v7_ac160[$label]" "$slug" "$reason"
  assert_true "v7_ac160[$label]: 実行前後で Vault がバイト不変" "$([ "$before_vault" = "$after_vault" ] && echo 1 || echo 0)"
  assert_eq "v7_ac160[$label]: 実行前後で宣言記録がバイト不変（cksum）" "$before_rec" "$after_rec"
  case "$id" in
    9|9p) assert_true "v7_ac160[$label]: ハングでも所要 ≤4 秒（実測 ${focus_elapsed}秒）" "$(python3 -c "print(1 if $focus_elapsed <= 4.0 else 0)")" ;;
  esac
  [ "$id" = "1" ] && fd1_out="$(cat "$WORKDIR/focus_stdout")"
  [ "$id" = "10" ] && fd10_out="$(cat "$WORKDIR/focus_stdout")"
done
assert_eq "v7_ac160[FD-10]: 同じ slug を 2 ワークスペースが宣言しても出力は FD-1 と完全一致" "$fd1_out" "$fd10_out"

echo "=== v7_ac162_focus_clamp_input（AC-162 MP）: FV-B×T0 の --frame は P 行 10 行（稼働中 2・待ち 1・保留 7・番号順）・FD-3′ で --focus＝p-hold7 ==="
reset_vault
mk_notes_FV_B "$VAULT"
JUDGE_NOW="$T0"
fd_apply 3p
PATH="$FD_BIN:$PATH" JUDGE_NOW="$T0" run_frame_raw
assert_eq "v7_ac162: --frame rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "v7_ac162: P 行 10 行" "10" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "v7_ac162: 区分の件数＝稼働中 2・待ち 1・保留 7" "2 1 7" \
  "$(awk -F '\t' '$1=="P"{n[$5]++} END{printf "%d %d %d", n["稼働中"], n["待ち"], n["保留"]}' "$WORKDIR/frame_stdout")"
assert_eq "v7_ac162: P 行の第 2〜6 欄＝FV-B の 10 行" "$FV_B_LIST" \
  "$(awk -F '\t' '$1=="P"{printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6}' "$WORKDIR/frame_stdout")"
run_focus_raw
assert_focus "v7_ac162[FD-3′ 記録 U3→p-hold7]" "p-hold7" ""

echo "=== v7_ac163_1_5_list_invariant（AC-163 ①⑤）: FV-A・T0 の --list は FD-1／4／6 のどれでも同じ 4 行・rc 0・cmux スパイ 0 件・所要 NFR-18 の線。--frame 1 行目 /4・旧版リテラル 0 件 ==="
reset_vault
mk_notes_FV_A "$VAULT"
for id in 1 4 6; do
  fd_apply "$id"
  : > "$FD_STATE/calls.log"
  HOME="$FD_HOME" PATH="$FD_BIN:$PATH" JUDGE_NOW="$T0" run_list_raw
  assert_eq "v7_ac163①[FD-$id]: --list rc=0" "0" "$(cat "$WORKDIR/list_rc")"
  assert_eq "v7_ac163①[FD-$id]: --list 4 行リテラル一致（宣言状態に依存しない）" "$FV_A_LIST" "$(cat "$WORKDIR/list_stdout")"
  assert_eq "v7_ac163①[FD-$id]: --list 中の cmux スパイ 0 件" "0" "$(wc -l < "$FD_STATE/calls.log" | tr -d ' ')"
done
fd_apply 1
: > "$FD_STATE/calls.log"
HOME="$FD_HOME" PATH="$FD_BIN:$PATH" JUDGE_NOW="$T0" run_frame_raw
assert_eq "v7_ac163⑤: --frame 1 行目が cmux-dock-frame/4（版上げなし）" "#V${tab}cmux-dock-frame/4${tab}Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "v7_ac163⑤: --frame 出力に旧版リテラル 0 件" "0" "$(grep -c -F -- "$V3_LIT" "$WORKDIR/frame_stdout")"
assert_eq "v7_ac163⑤: ai-env の追跡ファイルにマーカー無しの旧版リテラル行が 0 件（v5_ac138 の走査と同じ）" "0" "$v3_unmarked"
assert_eq "v7_ac163①: --frame 中も cmux スパイ 0 件（--frame は cmux を呼ばない）" "0" "$(wc -l < "$FD_STATE/calls.log" | tr -d ' ')"
if command -v python3 >/dev/null 2>&1; then
  AC163_STATS="$(HOME="$FD_HOME" PATH="$FD_BIN:$PATH" CMUX_NEXT_JUDGE_NOW="$T0" CMUX_NEXT_VAULT="$VAULT" \
    CMUX_NEXT_INVENTORY_DIR="/nonexistent-dir" CMUX_NEXT_MAINT_STATE="/nonexistent-dir/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="/nonexistent-dir/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
    CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    python3 - "$TARGET" <<'PY'
import statistics, subprocess, sys, time
vals, ok = [], 1
for _ in range(20):
    t0 = time.monotonic()
    r = subprocess.run(["bash", sys.argv[1], "--list"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    vals.append(time.monotonic() - t0)
    if r.returncode != 0:
        ok = 0
print(ok, statistics.median(vals), max(vals))
PY
)"
  set -- $AC163_STATS
  echo "v7_ac163①_perf_20runs: 実測 中央値=${2}秒 最大値=${3}秒"
  assert_true "v7_ac163①_perf: 20 回とも rc=0" "$1"
  assert_true "v7_ac163①_perf: 中央値 0.8 秒以下（NFR-18・実測 ${2}秒）" "$(python3 -c "print(1 if $2 <= 0.8 else 0)")"
  assert_true "v7_ac163①_perf: 最大値 1.2 秒以下（NFR-18・実測 ${3}秒）" "$(python3 -c "print(1 if $3 <= 1.2 else 0)")"
else
  echo "SKIP: python3 が無いため v7_ac163①_perf を省略します"
fi

echo "=== v7_dt35_focused_not_caller（DT-35）: caller=U1・focused=U2 で --focus は focused 側＝roles-conf ==="
reset_vault
mk_notes_FV_A "$VAULT"
JUDGE_NOW="$T0"
fd_apply 1
reset_fd_state "$FD_STATE" workspace:2 workspace:1
run_focus_raw
assert_focus "v7_dt35[caller≠focused]" "roles-conf" ""
reset_fd_state "$FD_STATE" workspace:1 workspace:2
run_focus_raw
assert_focus "v7_dt35[逆＝caller=U2・focused=U1]" "p-act2" ""

echo "=== v7_dt36_no_vault_no_judge_now（DT-36）: (a) Vault 不在パスでも p-act2・所要 ≤1 秒 (b) 判定時刻の不正値でも同じ・rc 0 (c) 外部プロセス＝cmux ちょうど 2（identify・workspace list）・jq ≤2 ==="
fd_apply 1
FOCUS_VAULT="$WORKDIR/no-such-vault" run_focus_raw
assert_focus "v7_dt36(a)[Vault 不在パス]" "p-act2" ""
assert_true "v7_dt36(a): 所要 ≤1 秒（実測 ${focus_elapsed}秒）" "$(python3 -c "print(1 if $focus_elapsed <= 1.0 else 0)")"
FOCUS_VAULT="$WORKDIR/no-such-vault" JUDGE_NOW="来週" run_focus_raw
assert_focus "v7_dt36(b)[判定時刻の不正値 来週]" "p-act2" ""
JUDGE_NOW="2026-02-30T12:00" run_focus_raw
assert_focus "v7_dt36(b)[判定時刻の不正値 暦外]" "p-act2" ""
JUDGE_NOW="$T0"
SPY_JQ="$WORKDIR/spy-jq"; mkdir -p "$SPY_JQ"
REAL_JQ="$(command -v jq)"
cat > "$SPY_JQ/jq" <<EOF
#!/bin/bash
echo jq >> "$WORKDIR/jq-args.log"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$SPY_JQ/jq"
: > "$WORKDIR/jq-args.log"
fd_apply 1
FOCUS_PATH_PREFIX="$SPY_JQ" run_focus_raw
assert_focus "v7_dt36(c)[スパイ下でも p-act2]" "p-act2" ""
assert_eq "v7_dt36(c): cmux の起動ちょうど 2" "2" "$(wc -l < "$FD_STATE/calls.log" | tr -d ' ')"
assert_eq "v7_dt36(c): identify 1 回・workspace list 1 回" "1 1" \
  "$(printf '%s %s' "$(grep -c -- '--json identify' "$FD_STATE/calls.log")" "$(grep -c -- '--json workspace list' "$FD_STATE/calls.log")")"
jq_n="$(wc -l < "$WORKDIR/jq-args.log" | tr -d ' ')"
assert_true "v7_dt36(c): jq の起動 ≤2（実測 ${jq_n}）" "$([ "$jq_n" -le 2 ] && echo 1 || echo 0)"

echo "=== v7_dt39_hang_bounded（DT-39）: FD-9 で所要 ≤4 秒（上限 3＋1）・空行・cmux 応答なし・rc 0・終了 6 秒後にスタブの子孫 0。上限の設定口 CMUX_NEXT_FOCUS_TIMEOUT=1 で ≤2.5 秒 ==="
fd_apply 9
# 探針の取りこぼし防止＝このケースだけハングを 20 秒にする（sleep の自然終了 10 秒が「終了 6 秒後」の観測点に近いため）。
echo 20 > "$FD_STATE/hang_secs"
run_focus_raw
assert_focus "v7_dt39[FD-9 identify ハング]" "" "cmux 応答なし"
assert_true "v7_dt39: 所要 ≤4 秒（実測 ${focus_elapsed}秒）" "$(python3 -c "print(1 if $focus_elapsed <= 4.0 else 0)")"
assert_true "v7_dt39: スタブがハングした（hang_pids に記録あり＝検査の空振り防止）" "$([ -s "$FD_STATE/hang_pids" ] && echo 1 || echo 0)"
sleep 6
dt39_alive=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null && dt39_alive=$(( dt39_alive + 1 ))
done < "$FD_STATE/hang_pids"
assert_eq "v7_dt39: 終了 6 秒後にスタブの子孫プロセスが 0" "0" "$dt39_alive"
fd_apply 9
FOCUS_TIMEOUT=1 run_focus_raw
assert_focus "v7_dt39[設定口 CMUX_NEXT_FOCUS_TIMEOUT=1]" "" "cmux 応答なし"
assert_true "v7_dt39: 設定口 1 秒で所要 ≤2.5 秒（実測 ${focus_elapsed}秒）" "$(python3 -c "print(1 if $focus_elapsed <= 2.5 else 0)")"
sleep 2

echo "=== v7_dt42_badslug_record（DT-42）: FD-6′（focused の slug が文法外＝改行を含む）で stdout 空行ちょうど 1 行・stderr 宣言記録破損・rc 0 ==="
fd_apply 6p
assert_eq "v7_dt42: fixture 自体は JSON として正しい（検査の空振り防止）" "0" "$(jq -e '.workspaces["UUID-U1"] | contains("\n")' "$FD_RECORD" >/dev/null 2>&1; echo $?)"
run_focus_raw
assert_focus "v7_dt42[FD-6′]" "" "宣言記録破損"

# --------------------------------------------------------------------------
# implementer 追記（内部不変条件・設計 §42.5.4・FR-122・D-v7-6。外部プロセス数は DT-36(c) が正本）。
# --------------------------------------------------------------------------
echo "=== v7_impl_timeout_default（§42.5.4・リーダー裁定＝既定 3 秒・整数）: FD-9 の所要が既定で 3〜4.5 秒・小数 3.5 と 0 は既定へ（sanitize_interval の規則） ==="
for tv in "" "3.5" "0"; do
  fd_apply 9
  FOCUS_TIMEOUT="$tv" run_focus_raw
  assert_focus "v7_impl_timeout[CMUX_NEXT_FOCUS_TIMEOUT=${tv:-未設定}]" "" "cmux 応答なし"
  assert_true "v7_impl_timeout[${tv:-未設定}]: 所要 3〜4.5 秒（実測 ${focus_elapsed}秒）" "$(python3 -c "print(1 if 3.0 <= $focus_elapsed <= 4.5 else 0)")"
done
sleep 5

echo "=== v7_impl_same_words_as_task（FR-122・D-v7-6）: 同じ状態（FD-4・5・5′・6・7）で Task 供給側 --frame の理由行と --focus の stderr が同じ語 ==="
TASK_TARGET="$SCRIPT_DIR/../cmux/cmux-task-model.sh"
for spec in "4|未宣言" "5|cmux 応答なし" "5p|cmux 応答なし" "6|宣言記録破損" "7|対象不明"; do
  id="${spec%%|*}"; word="${spec#*|}"
  fd_apply "$id"
  run_focus_raw
  task_word="$(HOME="$FD_HOME" PATH="$FD_BIN:$PATH" CMUX_TASK_VAULT="$VAULT" CMUX_TASK_CALL_TIMEOUT=3 \
    bash "$TASK_TARGET" --frame 2>/dev/null | awk -F '\t' '$1=="R"{print $2}')"
  assert_eq "v7_impl_same_words[FD-$id]: Task 枠の理由行＝[$word]" "$word" "$task_word"
  assert_eq "v7_impl_same_words[FD-$id]: --focus の stderr＝Task 枠と同じ語" "$task_word" "$(cat "$WORKDIR/focus_stderr")"
done

echo "=== v7_ac166b_doc（AC-166 (b)・requirements-v7.md §8.4・§9 文書行・設計 §42.9.1 DOC 層・§42.13）: cmux-next-model.sh の冒頭コメントと usage の両方に照会（--focus）の意味・CMUX_NEXT_FOCUS_TIMEOUT・既定 3 秒がある ==="
head_comment_166="$(sed -n '1,80p' "${TARGET}" | grep '^#' || true)"
assert_contains "v7_ac166b: 冒頭コメントに --focus の意味（宣言先の照会）" "$head_comment_166" "宣言先の照会"
assert_contains "v7_ac166b: 冒頭コメントに CMUX_NEXT_FOCUS_TIMEOUT" "$head_comment_166" "CMUX_NEXT_FOCUS_TIMEOUT"
assert_contains "v7_ac166b: 冒頭コメントに 上限の既定値 3" "$head_comment_166" "既定 3"
assert_contains "v7_ac166b: 冒頭コメントに 単位（秒）" "$head_comment_166" "秒"
bash "${TARGET}" >/dev/null 2>"$WORKDIR/usage_err_166" || true
usage_err_166="$(cat "$WORKDIR/usage_err_166")"
assert_contains "v7_ac166b: usage に --focus の意味（宣言先の照会）" "$usage_err_166" "宣言先の照会"
assert_contains "v7_ac166b: usage に CMUX_NEXT_FOCUS_TIMEOUT" "$usage_err_166" "CMUX_NEXT_FOCUS_TIMEOUT"
assert_contains "v7_ac166b: usage に 上限の既定値 3" "$usage_err_166" "既定 3"
assert_contains "v7_ac166b: usage に 単位（秒）" "$usage_err_166" "秒"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
