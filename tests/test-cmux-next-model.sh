#!/bin/bash
# cmux-next-model.sh のユニットテスト（cmux-session-todo 設計 §34.1 MP層）。
# 実 Vault・実ログには一切触れない。cmux は一度も呼ばない設計なので
# ワークスペースの解決は不要（設計 §30.2）。dotfiles には一切依存しない
# （NFR-13・AC-106）。
#
# 実行方法: bash tests/test-cmux-next-model.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux/cmux-next-model.sh"

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

run_list_raw() {
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" CMUX_NEXT_MAINT_STATE="$MAINT_FILE" \
    bash "$TARGET" --list > "$WORKDIR/list_stdout" 2>"$WORKDIR/list_stderr"
  printf '%s' "$?" > "$WORKDIR/list_rc"
}

run_frame_raw() {
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="$INV_DIR" CMUX_NEXT_MAINT_STATE="$MAINT_FILE" \
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
assert_eq "基底: #V行" "#V	cmux-dock-frame/1	Project" "$(sed -n '1p' "$WORKDIR/frame_stdout")"
p_n="$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
b_n="$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "基底: E行が P行数+B行数と一致" "$(( p_n + b_n ))" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== FR-31導出（AC-36・AC-37・AC-38・AC-39・AC-47・AC-48・AC-49・AC-50） ==="
FIELD3_N1="$(awk -F '\t' '$2=="proj-n1-handwritten" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "AC-36: 手書きのnext:がTasks節より優先される" "手書きのnext値" "$FIELD3_N1"

FIELD3_N2="$(awk -F '\t' '$2=="proj-n2-short" {print $3}' "$WORKDIR/list_stdout")"
assert_eq "AC-37: 先頭未完タスク（[x]を除く）が導出される" "短いタスク" "$FIELD3_N2"

FIELD3_N3="$(awk -F '\t' '$2=="proj-n3-long" {print $3}' "$WORKDIR/list_stdout")"
EXPECT_N3="これは十五コードポイントを確実"
assert_eq "AC-38: 導出値が先頭15文字と完全一致" "$EXPECT_N3" "$FIELD3_N3"
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

echo "=== 外部脳ヘルス: 棚卸し・週次の両方が正常 ==="
reset_vault
mk_note_N0 "$VAULT"
mk_inventory_report "$INV_DIR" "2026-08-05" 15
mk_maintenance_state "$MAINT_FILE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_frame_raw
b_rows="$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout")"
assert_eq "ヘルス: 棚卸し行" "B	棚卸し	warn	要確認15件 (8/5)" "$(printf '%s\n' "$b_rows" | sed -n '1p')"
assert_eq "ヘルス: 週次行（当日=ok）" "1" "$(printf '%s\n' "$b_rows" | sed -n '2p' | awk -F '\t' '$3=="ok"{print 1}')"

echo "=== 外部脳ヘルス: 棚卸し抽出失敗はn/a（warn扱いにしない） ==="
reset_vault
mk_note_N0 "$VAULT"
mk_inventory_report_noparse "$INV_DIR" "2026-08-05"
run_frame_raw
assert_eq "ヘルス: 棚卸しn/a行" "B	棚卸し	ok	n/a" "$(awk -F '\t' '$1=="B" && $2=="棚卸し"' "$WORKDIR/frame_stdout")"

echo "=== 外部脳ヘルス: 週次が古い（8日以上）と warn ==="
reset_vault
mk_note_N0 "$VAULT"
mk_maintenance_state "$MAINT_FILE" "2020-01-01T00:00:00Z"
run_frame_raw
assert_eq "ヘルス: 週次warn" "warn" "$(awk -F '\t' '$1=="B" && $2=="週次"{print $3}' "$WORKDIR/frame_stdout")"

echo "=== 外部脳ヘルス: 両方のデータ源が無ければブロック全体（B行）が0行 ==="
reset_vault
mk_note_N0 "$VAULT"
run_frame_raw
assert_eq "ヘルス: データ源が両方無ければB行0行" "0" "$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"

echo "=== 外部脳ヘルス: 棚卸しのみデータあり（週次は状態ファイル無し）→棚卸し行のみ ==="
reset_vault
mk_note_N0 "$VAULT"
mk_inventory_report "$INV_DIR" "2026-08-05" 0
run_frame_raw
assert_eq "ヘルス: 棚卸しのみ1行" "1" "$(awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "ヘルス: 棚卸し0件はwarnでなくok" "ok" "$(awk -F '\t' '$1=="B"{print $3}' "$WORKDIR/frame_stdout")"

echo "=== Projectsディレクトリが空でも --list は0行・rc=0 ==="
reset_vault
run_list_raw
assert_eq "空Vault: rc=0" "0" "$(cat "$WORKDIR/list_rc")"
assert_eq "空Vault: 0行" "0" "$(wc -c < "$WORKDIR/list_stdout" | tr -d ' ')"
run_frame_raw
assert_eq "空Vault(--frame): P行0行" "0" "$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "空Vault(--frame): E行0" "0" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

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
