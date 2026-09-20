#!/bin/bash
# cmux-next-model.sh のユニットテスト（cmux-session-todo 設計 §34.1 MP層）。
# 実 Vault・実ログには一切触れない。cmux は一度も呼ばない設計なので
# ワークスペースの解決は不要（設計 §30.2）。dotfiles には一切依存しない
# （NFR-13・AC-106）。
#
# 実行方法: bash tests/test-cmux-next-model.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux/cmux-next-model.sh"

# 外側シェルの env から独立させる（R2-1）。--recall-stale-days の期待値 7 は固定。
unset VAULT_AGENT_LOG_STALE_DAYS

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-model-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

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
run_list_raw() {
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" CMUX_NEXT_MAINT_STATE="$MAINT_FILE" \
    CMUX_NEXT_INVENTORY_LATEST="$INV_DIR/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" \
    CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    bash "$TARGET" --list > "$WORKDIR/list_stdout" 2>"$WORKDIR/list_stderr"
  printf '%s' "$?" > "$WORKDIR/list_rc"
}

run_frame_raw() {
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
assert_eq "基底: #V行（契約 /3）" "#V	cmux-dock-frame/3	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
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
assert_eq "AC-48: TAB混入行が4列のまま" "4" "$NCOLS_N6"
python3 -c "
import sys
data = open('$WORKDIR/list_stdout', 'rb').read()
sys.exit(1 if chr(27).encode() in data else 0)
"
assert_true "AC-48: --list出力に生のESCバイトが残っていない" "$([ $? -eq 0 ] && echo 1 || echo 0)"

assert_not_contains "AC-49: completedノートは--listに現れない" "$(cat "$WORKDIR/list_stdout")" "proj-n7-completed"
assert_not_contains "AC-49: completedノートのタスク本文も--listに現れない" "$(cat "$WORKDIR/list_stdout")" "completedなので出ないはず"

assert_order "AC-50: N-0がN-8よりupdated降順で前に並ぶ" "$(cat "$WORKDIR/list_stdout")" "proj-n0-base" "proj-n8-older"
BAD_NCOLS_ROWS="$(awk -F '\t' 'NF && NF!=4' "$WORKDIR/list_stdout" | wc -l | tr -d ' ')"
assert_eq "AC-50/FR-44④: --list に4列でない行が0件" "0" "$BAD_NCOLS_ROWS"

echo "=== next: 無し・Tasks節も無し → next欄が空（(next未設定)は描画側の責務） ==="
FIELD3_N4="$(awk -F '\t' '$2=="proj-n4-none" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "next:もTasks節も無ければnext欄が空文字" "" "$FIELD3_N4"

# ==========================================================================
# 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §6）＝契約 cmux-dock-frame/3。
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

echo "=== frame_v3_header: #V 行の契約版が cmux-dock-frame/3（理由フレームも同じ版） ==="
reset_vault
mk_note_N0 "$VAULT"
run_frame_fixture S-1
assert_eq "frame_v3_header: #V 行" "#V	cmux-dock-frame/3	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
assert_eq "frame_v3_header: 旧版 /1 は出ない" "0" "$(grep -c 'cmux-dock-frame/1' "$WORKDIR/frame_stdout")"
STUBBIN_SORT_V3="$WORKDIR/stubbin-sort-v3"
mkdir -p "$STUBBIN_SORT_V3"
printf '#!/bin/bash\nexit 1\n' > "$STUBBIN_SORT_V3/sort"; chmod +x "$STUBBIN_SORT_V3/sort"
PATH="$STUBBIN_SORT_V3:$PATH" run_frame_raw
assert_eq "frame_v3_header: 理由フレームも /3" "#V	cmux-dock-frame/3	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"

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
cp "$SCRIPT_DIR/../cmux/cmux-next-model.sh" "$SCRIPT_DIR/../cmux/lib-model-view.sh" "$SCRIPT_DIR/../cmux/lib-vault-tasks.sh" "$NOJUDGE/"
d="$FX_ROOT/S-2"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" HEALTH_JUDGE_NOW="$(cat "$d/now")" \
  bash "$NOJUDGE/cmux-next-model.sh" --frame > "$WORKDIR/frame_stdout" 2>"$WORKDIR/frame_stderr"
assert_eq "判定機不在: rc=0（フレームは正当）" "0" "$?"
assert_eq "判定機不在: B 行 0 行" "0" "$(b_rows | wc -l | tr -d ' ')"
assert_eq "判定機不在: #V は /3 のまま" "#V	cmux-dock-frame/3	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
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

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
