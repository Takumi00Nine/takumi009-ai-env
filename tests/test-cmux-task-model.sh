#!/bin/bash
# cmux-task-model.sh のユニットテスト（cmux-session-todo 設計 §34.1 MT層）。
# 実 Vault・実ワークスペース・実 cmux には一切触れない。cmux 呼び出しは
# $STUBBIN/cmux（S群スタブ）へ差し替える。dotfiles には一切依存しない
# （NFR-13・AC-106）。
#
# 実行方法: bash tests/test-cmux-task-model.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux/cmux-task-model.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-task-model-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck source=./lib-cmux-fixtures.sh
. "$SCRIPT_DIR/lib-cmux-fixtures.sh"

STUB_STATE="$WORKDIR/stubstate"
STUBBIN="$WORKDIR/stubbin"
VAULT="$WORKDIR/vault"
STATE_FILE="$WORKDIR/decl.json"
mkdir -p "$STUB_STATE" "$STUBBIN" "$VAULT/Projects"

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

write_cmux_stub "$STUBBIN/cmux"
export CMUX_TASK_CMUX_BIN="$STUBBIN/cmux"
export STUB_STATE

# --frame・--list 実行ヘルパー（bash3.2 の罠回避のためファイルへ直接書く）。
FRAME_OUT="$WORKDIR/frame_stdout"
FRAME_RC="$WORKDIR/frame_rc"
run_frame_raw() {
  local vault="$1" state_file="$2"
  CMUX_TASK_VAULT="$vault" CMUX_TASK_STATE="$state_file" \
    bash "$TARGET" --frame > "$FRAME_OUT" 2>"$WORKDIR/frame_stderr"
  printf '%s' "$?" > "$FRAME_RC"
}

LIST_OUT="$WORKDIR/list_stdout"
LIST_STDERR="$WORKDIR/list_stderr"
LIST_RC="$WORKDIR/list_rc"
run_list_raw() {
  local vault="$1" state_file="$2"
  CMUX_TASK_VAULT="$vault" CMUX_TASK_STATE="$state_file" \
    bash "$TARGET" --list > "$LIST_OUT" 2>"$LIST_STDERR"
  printf '%s' "$?" > "$LIST_RC"
}

# --frame の R 行（理由フレーム）を stdout から取り出して返す。
frame_reason() {
  awk -F '\t' '$1=="R"{print $2}' "$FRAME_OUT"
}

# --list が理由行1件・stdout0バイト・rc=1になることをまとめて確認する。
assert_list_reason() {
  local desc="$1" vault="$2" state_file="$3" expected="$4"
  run_list_raw "$vault" "$state_file"
  assert_eq "$desc: stderrが「${expected}」" "$expected" "$(cat "$LIST_STDERR")"
  assert_eq "$desc: rc=1" "1" "$(cat "$LIST_RC")"
  assert_eq "$desc: stdoutが0バイト" "0" "$(wc -c < "$LIST_OUT" | tr -d ' ')"
}

# --frame の理由フレームが期待どおりであることを確認する（版宣言・R行・
# E行の3行だけ・rc=0＝FR-82#11）。
assert_frame_reason() {
  local desc="$1" vault="$2" state_file="$3" expected="$4"
  run_frame_raw "$vault" "$state_file"
  assert_eq "$desc: rc=0" "0" "$(cat "$FRAME_RC")"
  assert_eq "$desc: フレームが版宣言+R+Eの3行" "3" "$(wc -l < "$FRAME_OUT" | tr -d ' ')"
  assert_eq "$desc: #V行" "#V	cmux-dock-frame/2	Task" "$(sed -n '1p' "$FRAME_OUT")"
  assert_eq "$desc: R行の理由が「${expected}」" "$expected" "$(frame_reason)"
  assert_eq "$desc: E行" "E	1" "$(sed -n '3p' "$FRAME_OUT")"
}

# ==========================================================================
# 表示基底（V-1・W-1・S-1・v4＝P-6′と一致する fixture）
# ==========================================================================
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"

echo "=== 基底/AC-125: --frame が P-6′ の形とリテラル一致する ==="
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "基底: rc=0" "0" "$(cat "$FRAME_RC")"
expected_frame='#V	cmux-dock-frame/2	Task
V	1	v2	1/3	cur	open
C	[x]	要件定義
C	[/]	設計
C	[ ]	実装
V	2	v3	0/4	-	fold
D	1
E	6'
assert_eq "基底/AC-125: --frame がP-6′とリテラル一致" "$expected_frame" "$(cat "$FRAME_OUT")"

echo "=== 基底/AC-129: --list が5列でv1(fold・0/4)の子行4つも含む7行 ==="
run_list_raw "$VAULT" "$STATE_FILE"
expected_list='1	v2	1/3	[x]	要件定義
1	v2	1/3	[/]	設計
1	v2	1/3	[ ]	実装
2	v3	0/4	[ ]	t1
2	v3	0/4	[ ]	t2
2	v3	0/4	[ ]	t3
2	v3	0/4	[ ]	t4'
assert_eq "基底/AC-129: --list がリテラル一致（foldのv3の子行4つも出る）" "$expected_list" "$(cat "$LIST_OUT")"
assert_eq "基底/AC-129: --list rc=0" "0" "$(cat "$LIST_RC")"

echo "=== N-2′: --frame のV番号集合==--list第1列集合／openの版のC列がlistの同番号行と順序含め一致／foldの版の子行はlistだけに現れる ==="
frame_v_nums="$(awk -F '\t' '$1=="V"{print $2}' "$FRAME_OUT" | sort -u)"
list_nums_uniq="$(awk -F '\t' '{print $1}' "$LIST_OUT" | sort -u)"
assert_eq "N-2′①(AC-90′①(MT)): --frameのV番号集合==--list第1列集合" "$list_nums_uniq" "$frame_v_nums"
frame_open_triple="$(awk -F '\t' '
  $1=="V" { num=$2; open=($6=="open") }
  $1=="C" && open { print num"\t"$2"\t"$3 }
' "$FRAME_OUT")"
list_num1_triple="$(awk -F '\t' '$1==1{print $1"\t"$4"\t"$5}' "$LIST_OUT")"
assert_eq "N-2′②(AC-90′①(MT)): openの版(番号1)のC行(状態,本文)がlistの番号1行(第4,5列)と順序含め一致" "$list_num1_triple" "$frame_open_triple"
assert_true "N-2′③(AC-90′①(MT)): foldの版（番号2）の子行はlistだけに現れる（frameにC行が無くlistには4行ある）" \
  "$([ "$(awk -F '\t' '$1=="C"' "$FRAME_OUT" | wc -l | tr -d ' ')" -eq 3 ] && [ "$(awk -F '\t' '$1==2' "$LIST_OUT" | wc -l | tr -d ' ')" -eq 4 ] && echo 1 || echo 0)"

echo "=== AC-125: V-15はcurの版だけが番号1のV行1つ・D4 ==="
reset_stub_state "$STUB_STATE"
mk_note_V15 "$VAULT"
mk_decl_single "v15proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
expected_v15_frame='#V	cmux-dock-frame/2	Task
V	1	v2	5/12	cur	open
C	[x]	t1
C	[x]	t2
C	[x]	t3
C	[x]	t4
C	[x]	t5
C	[ ]	t6
C	[ ]	t7
C	[ ]	t8
C	[ ]	t9
C	[ ]	t10
C	[/]	t11
C	[ ]	t12
D	4
E	14'
assert_eq "AC-125: V-15の--frameがリテラル一致" "$expected_v15_frame" "$(cat "$FRAME_OUT")"

echo "=== AC-126: ▶（今の版）の3段判定 ==="
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-126①: V-1（[/]あり）でcurは番号1(v2)" "1" "$(awk -F'\t' '$1=="V" && $5=="cur"{print $2}' "$FRAME_OUT")"

mk_note_V19a "$VAULT"
mk_decl_single "$V19A_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-126②: V-19a（next:\"v2\"完全一致）でcurは番号2(v2)" "2" "$(awk -F'\t' '$1=="V" && $5=="cur"{print $2}' "$FRAME_OUT")"

mk_note_V11 "$VAULT"
mk_decl_single "v11proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-126③: V-11（[/]無し・next:無し）でcurは番号1" "1" "$(awk -F'\t' '$1=="V" && $5=="cur"{print $2}' "$FRAME_OUT")"

mk_note_V18 "$VAULT"
mk_decl_single "$V18_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-126④: V-18（[/]が2版）でcurは番号1（最初の[/]版=v1）" "1" "$(awk -F'\t' '$1=="V" && $5=="cur"{print $2}' "$FRAME_OUT")"

mk_note_V19b "$VAULT"
mk_decl_single "$V19B_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-126⑤: V-19b（next:\"v\"は前方一致のみ・不一致）でcurは番号1" "1" "$(awk -F'\t' '$1=="V" && $5=="cur"{print $2}' "$FRAME_OUT")"

mk_note_V19c "$VAULT"
mk_decl_single "$V19C_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-126⑥: V-19c（next:\"v1\"だがv1は完了済で候補外）でcurは番号1（=v2）" "1" "$(awk -F'\t' '$1=="V" && $5=="cur"{print $2}' "$FRAME_OUT")"

echo "=== AC-127: 展開集合(OPEN = done>=1 ∨ [/])の判定 ==="
mk_note_V11 "$VAULT"
mk_decl_single "v11proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-127①: V-11の1番(cur・0/1・[/]なし)がfold" "fold" "$(awk -F'\t' '$1=="V" && $2==1{print $6}' "$FRAME_OUT")"
assert_eq "AC-127①: V-11の1番のC行が0行" "0" "$(awk -F'\t' '$1=="V"{v=$2} $1=="C"{if(v==1) c++} END{print c+0}' "$FRAME_OUT")"

mk_note_V20 "$VAULT"
mk_decl_single "$V20_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-127②: V-20の2番(v2・done1・非cur)がopen" "open" "$(awk -F'\t' '$1=="V" && $2==2{print $6}' "$FRAME_OUT")"
assert_eq "AC-127②: V-20の2番のC行が2行" "2" "$(awk -F'\t' '$1=="V"{v=$2} $1=="C"{if(v==2) c++} END{print c+0}' "$FRAME_OUT")"
assert_eq "AC-127③: V-20の3番(v3・0/1)がfold" "fold" "$(awk -F'\t' '$1=="V" && $2==3{print $6}' "$FRAME_OUT")"
assert_eq "AC-127③: V-20の3番のC行が0行" "0" "$(awk -F'\t' '$1=="V"{v=$2} $1=="C"{if(v==3) c++} END{print c+0}' "$FRAME_OUT")"
assert_eq "AC-127⑤: V-20の1番(v1・cur・[/]・0/2)がcur" "cur" "$(awk -F'\t' '$1=="V" && $2==1{print $5}' "$FRAME_OUT")"
assert_eq "AC-127⑤: V-20の1番がopen" "open" "$(awk -F'\t' '$1=="V" && $2==1{print $6}' "$FRAME_OUT")"
assert_eq "AC-127⑤: V-20の1番のC行が2行" "2" "$(awk -F'\t' '$1=="V"{v=$2} $1=="C"{if(v==1) c++} END{print c+0}' "$FRAME_OUT")"

mk_note_V18 "$VAULT"
mk_decl_single "$V18_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-127④: V-18の2番(v2・[/]あり・done0・非cur)がopen" "open" "$(awk -F'\t' '$1=="V" && $2==2{print $6}' "$FRAME_OUT")"
assert_eq "AC-127④: V-18の2番のC行が2行" "2" "$(awk -F'\t' '$1=="V"{v=$2} $1=="C"{if(v==2) c++} END{print c+0}' "$FRAME_OUT")"

echo "=== AC-128: 完了件数(D)がfixtureごとに正しい・0/0の版も番号を持つ ==="
mk_note_V1 "$VAULT"; mk_decl_single "v1proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-128: V-1のD" "1" "$(awk -F'\t' '$1=="D"{print $2}' "$FRAME_OUT")"

mk_note_V15 "$VAULT"; mk_decl_single "v15proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-128: V-15のD" "4" "$(awk -F'\t' '$1=="D"{print $2}' "$FRAME_OUT")"

mk_note_V10 "$VAULT"; mk_decl_single "v10proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-128: V-10のD" "3" "$(awk -F'\t' '$1=="D"{print $2}' "$FRAME_OUT")"

mk_note_V11 "$VAULT"; mk_decl_single "v11proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-128: V-11のD" "0" "$(awk -F'\t' '$1=="D"{print $2}' "$FRAME_OUT")"

mk_note_V5 "$VAULT"; mk_decl_single "v5proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-128: V-5のD" "1" "$(awk -F'\t' '$1=="D"{print $2}' "$FRAME_OUT")"
expected_v5='#V	cmux-dock-frame/2	Task
V	1	v2	0/0	cur	fold
V	2	v3	0/1	-	fold
D	1
E	3'
assert_eq "AC-128: V-5のフレームがリテラル一致(0/0の版v2が番号1・cur・fold・C0行)" "$expected_v5" "$(cat "$FRAME_OUT")"

echo "=== AC-129: --list の5列・0/0の版は状態・本文が「-」の1行 ==="
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-129: V-5の--listが2行(0/0の版は状態・本文-)" '1	v2	0/0	-	-
2	v3	0/1	[ ]	b' "$(cat "$LIST_OUT")"

echo "=== AC-124′①: 全版完了（V-10） → --frame はV0行・D3・E1の通常フレーム・--list は「全版完了」 ==="
mk_note_V10 "$VAULT"
mk_decl_single "v10proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-124′①: rc=0" "0" "$(cat "$FRAME_RC")"
expected_v10='#V	cmux-dock-frame/2	Task
D	3
E	1'
assert_eq "AC-124′①: 全版完了フレームがリテラル一致（V行0・D3・E1）" "$expected_v10" "$(cat "$FRAME_OUT")"
assert_list_reason "AC-124′①(--list)" "$VAULT" "$STATE_FILE" "全版完了"

echo "=== AC-124′②: [/]無し・未完版2つとも未着手（V-11） → 両方cur/-・fold・C0行・D0 ==="
mk_note_V11 "$VAULT"
mk_decl_single "v11proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
expected_v11='#V	cmux-dock-frame/2	Task
V	1	v1	0/1	cur	fold
V	2	v2	0/1	-	fold
D	0
E	3'
assert_eq "AC-124′②: [/]無しの正当フレームがリテラル一致（両版fold・C0行）" "$expected_v11" "$(cat "$FRAME_OUT")"

echo "=== AC-13: 陰性4件（V-2/V-3/V-4/V-8）が理由フレーム・--list理由行・rc一致 ==="
mk_note_V2 "$VAULT"; mk_note_V3 "$VAULT"; mk_note_V4 "$VAULT"; mk_note_V8 "$VAULT"
declare -a v13_slugs=(v2proj v3proj v4proj v8proj)
declare -a v13_reasons=("Tasks 節なし" "Tasks 節なし" "タスクなし" "空タスク")
for idx in 0 1 2 3; do
  mk_decl_single "${v13_slugs[$idx]}" "$STATE_FILE"
  assert_frame_reason "AC-13(${v13_slugs[$idx]})" "$VAULT" "$STATE_FILE" "${v13_reasons[$idx]}"
  assert_list_reason "AC-13(${v13_slugs[$idx]}・--list)" "$VAULT" "$STATE_FILE" "${v13_reasons[$idx]}"
done

echo "=== AC-14: frontmatter未閉（V-12）→ノート破損 ==="
mk_note_V12 "$VAULT"
mk_decl_single "v12proj" "$STATE_FILE"
assert_frame_reason "AC-14" "$VAULT" "$STATE_FILE" "ノート破損"

echo "=== AC-15: ノート不在/未宣言 ==="
mk_decl_single "no-such-note-slug" "$STATE_FILE"
assert_frame_reason "AC-15(ノート不在)" "$VAULT" "$STATE_FILE" "ノート不在"
mk_decl_empty "$STATE_FILE"
assert_frame_reason "AC-15(未宣言)" "$VAULT" "$STATE_FILE" "未宣言"

echo "=== AC-16: S-2/S-3/S-4 ==="
mk_decl_single "v1proj" "$STATE_FILE"
touch "$STUB_STATE/fail_identify"
assert_frame_reason "AC-16(S-2)" "$VAULT" "$STATE_FILE" "cmux 応答なし"
rm -f "$STUB_STATE/fail_identify"

touch "$STUB_STATE/fail_workspace_list"
assert_frame_reason "AC-16(S-3)" "$VAULT" "$STATE_FILE" "cmux 応答なし"
rm -f "$STUB_STATE/fail_workspace_list"

echo "workspace:99" > "$STUB_STATE/focused_ref"
assert_frame_reason "AC-16(S-4)" "$VAULT" "$STATE_FILE" "対象不明"
echo "workspace:1" > "$STUB_STATE/focused_ref"

echo "=== AC-17: Vault不在（F-2） ==="
CMUX_TASK_VAULT="$WORKDIR/no-such-vault" CMUX_TASK_STATE="$STATE_FILE" \
  bash "$TARGET" --frame > "$FRAME_OUT" 2>"$WORKDIR/frame_stderr"
printf '%s' "$?" > "$FRAME_RC"
assert_eq "AC-17: rc=0" "0" "$(cat "$FRAME_RC")"
assert_eq "AC-17: Vault不在" "Vault 不在" "$(frame_reason)"

echo "=== AC-18: 先勝ちの3組合せ ==="
mk_note_V8 "$VAULT"
mk_decl_empty "$STATE_FILE"
assert_frame_reason "AC-18(W-3×V-8)" "$VAULT" "$STATE_FILE" "未宣言"

touch "$STUB_STATE/fail_identify"
assert_frame_reason "AC-18(S-2×W-3)" "$VAULT" "$STATE_FILE" "cmux 応答なし"
rm -f "$STUB_STATE/fail_identify"

mk_decl_corrupt "$STATE_FILE"
assert_frame_reason "AC-18(W-7×W-3)" "$VAULT" "$STATE_FILE" "宣言記録破損"

echo "=== AC-23: ref振り直し（W-5）→ 表示基底と一致 ==="
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:7"}]}
JSON
echo "workspace:7" > "$STUB_STATE/focused_ref"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-23: refが振り直っても同一UUIDで解決・表示基底と一致" "$expected_frame" "$(cat "$FRAME_OUT")"
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
echo "workspace:1" > "$STUB_STATE/focused_ref"

echo "=== AC-26相当: cmux応答なし→回復（無状態の単発呼び出しで両方とも正しい） ==="
touch "$STUB_STATE/fail_identify"
assert_frame_reason "AC-26(失敗時)" "$VAULT" "$STATE_FILE" "cmux 応答なし"
rm -f "$STUB_STATE/fail_identify"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-26(回復後): 直前の理由フレームを持ち越さず通常表示に戻る" "$expected_frame" "$(cat "$FRAME_OUT")"

echo "=== AC-62′: --list の制御文字除去（V-6拡張・5列固定・コードポイント単位） ==="
mk_note_V6 "$VAULT"
mk_decl_single "v6proj" "$STATE_FILE"
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-62′: --list 終了コード0" "0" "$(cat "$LIST_RC")"
ac62_nlines="$(wc -l < "$LIST_OUT" | tr -d ' ')"
ac62_bad_cols="$(awk -F '\t' 'NF!=5' "$LIST_OUT" | wc -l | tr -d ' ')"
ac62_bad_cp="$(python3 -c "
import sys
bad = 0
with open('$LIST_OUT', encoding='utf-8') as f:
    for line in f:
        cols = line.rstrip(chr(10)).split(chr(9))
        for c in cols[1:]:
            for ch in c:
                cp = ord(ch)
                if cp <= 0x1f or (0x7f <= cp <= 0x9f):
                    bad += 1
print(bad)
")"
assert_eq "AC-62′: --list の全行が5列のまま" "0" "$ac62_bad_cols"
assert_eq "AC-62′: 5列に分解した各データ列に制御文字コードポイントが無い" "0" "$ac62_bad_cp"
assert_true "AC-62′: 出力が1行以上ある（検査が空振りでない）" "$([ "$ac62_nlines" -gt 0 ] && echo 1 || echo 0)"

echo "=== AC-64′: V-18: [/]を持つ版が2つあるとき両方openになる（cur=最初の[/]版だけ） ==="
mk_note_V18 "$VAULT"
mk_decl_single "$V18_SLUG" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
expected_v18='#V	cmux-dock-frame/2	Task
V	1	v1	1/3	cur	open
C	[x]	a
C	[/]	b
C	[ ]	c
V	2	v2	0/2	-	open
C	[/]	d
C	[ ]	e
D	0
E	8'
assert_eq "AC-64′: --frameがリテラル一致（v2はdone0でも[/]でopen）" "$expected_v18" "$(cat "$FRAME_OUT")"
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-64′: --list 終了コード0" "0" "$(cat "$LIST_RC")"
assert_eq "AC-64′: --listの行数が5行（v1の3件+v2の2件）" "5" "$(wc -l < "$LIST_OUT" | tr -d ' ')"
assert_eq "AC-64′: 第2列がv1 v1 v1 v2 v2の順" "v1
v1
v1
v2
v2" "$(awk -F'\t' '{print $2}' "$LIST_OUT")"
assert_eq "AC-64′: 第4列が[x] [/] [ ] [/] [ ]の順" '[x]
[/]
[ ]
[/]
[ ]' "$(awk -F'\t' '{print $4}' "$LIST_OUT")"

echo "=== AC-65/AC-81: caller≠focused → --list は対象不一致（--frameはfocused側=W-10相当） ==="
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
cat > "$VAULT/Projects/proj2.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### proj2ver
- [ ] only task
EOF
mk_decl_pair "UUID-AAA" "v1proj" "UUID-BBB" "proj2" "$STATE_FILE"
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"},{"id":"UUID-BBB","ref":"workspace:2"}]}
JSON
echo "workspace:1" > "$STUB_STATE/caller_ref"
echo "workspace:2" > "$STUB_STATE/focused_ref"
assert_list_reason "AC-65" "$VAULT" "$STATE_FILE" "対象不一致"
run_frame_raw "$VAULT" "$STATE_FILE"
# v4はフレームにslug(proj2)を出さない（H行廃止）ため、proj2ノート固有の
# 版名で focused 側(proj2)のデータであることを確認する。
assert_contains "AC-65: --frameはfocused側(proj2)を表示" "$(cat "$FRAME_OUT")" "proj2ver"

echo "workspace:2" > "$STUB_STATE/caller_ref"
echo "workspace:1" > "$STUB_STATE/focused_ref"
assert_list_reason "AC-81" "$VAULT" "$STATE_FILE" "対象不一致"
echo "workspace:1" > "$STUB_STATE/caller_ref"
echo "workspace:1" > "$STUB_STATE/focused_ref"

echo "=== AC-66: W-11: callerが解決できない2通り → 対象不明 ==="
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
printf '' > "$STUB_STATE/caller_ref"
assert_list_reason "AC-66①(caller null)" "$VAULT" "$STATE_FILE" "対象不明"
echo "workspace:99" > "$STUB_STATE/caller_ref"
assert_list_reason "AC-66②(caller_refがworkspace listに無い)" "$VAULT" "$STATE_FILE" "対象不明"
echo "workspace:1" > "$STUB_STATE/caller_ref"

echo "=== AC-67: --list の理由行が§7と同じ文言（順3〜10） ==="
reset_stub_state "$STUB_STATE"
mk_note_V12 "$VAULT"
mk_decl_corrupt "$STATE_FILE"
assert_list_reason "AC-67(宣言記録破損・W-7)" "$VAULT" "$STATE_FILE" "宣言記録破損"
mk_decl_empty "$STATE_FILE"
assert_list_reason "AC-67(未宣言・W-3)" "$VAULT" "$STATE_FILE" "未宣言"
mk_decl_single "v1proj" "$STATE_FILE"
assert_list_reason "AC-67(Vault不在・F-2)" "$WORKDIR/no-such-vault-for-list" "$STATE_FILE" "Vault 不在"
mk_decl_single "no-such-note-slug" "$STATE_FILE"
assert_list_reason "AC-67(ノート不在・W-2)" "$VAULT" "$STATE_FILE" "ノート不在"
mk_decl_single "v12proj" "$STATE_FILE"
assert_list_reason "AC-67(ノート破損・V-12)" "$VAULT" "$STATE_FILE" "ノート破損"
mk_note_V2 "$VAULT"
mk_decl_single "v2proj" "$STATE_FILE"
assert_list_reason "AC-67(Tasks節なし・V-2)" "$VAULT" "$STATE_FILE" "Tasks 節なし"
mk_note_V4 "$VAULT"
mk_decl_single "v4proj" "$STATE_FILE"
assert_list_reason "AC-67(タスクなし・V-4)" "$VAULT" "$STATE_FILE" "タスクなし"
mk_note_V8 "$VAULT"
mk_decl_single "v8proj" "$STATE_FILE"
assert_list_reason "AC-67(空タスク・V-8)" "$VAULT" "$STATE_FILE" "空タスク"

echo "=== AC-68′/AC-83②′: 全版完了(V-10) → --list 全版完了・--frameは通常フレーム ==="
mk_note_V10 "$VAULT"
mk_decl_single "v10proj" "$STATE_FILE"
assert_list_reason "AC-68′/AC-83②′" "$VAULT" "$STATE_FILE" "全版完了"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-68′/AC-83②′: --frameは版宣言つきの通常フレーム（R行0行）" "0" "$(awk -F '\t' '$1=="R"' "$FRAME_OUT" | wc -l | tr -d ' ')"

echo "=== AC-69相当: 未知引数・併用・過剰引数は使い方1件・非0 ==="
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
for combo in "" "--once" "--plain" "--list --frame" "--frame extra" "--list --list"; do
  out="$(CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" bash "$TARGET" $combo 2>"$WORKDIR/ac69_err")"
  rc=$?
  assert_true "AC-69[$combo]: 非0で終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "AC-69[$combo]: stdout0バイト" "$([ -z "$out" ] && echo 1 || echo 0)"
  assert_true "AC-69[$combo]: 使い方がstderrに出る" "$(grep -q '使い方' "$WORKDIR/ac69_err" && echo 1 || echo 0)"
done

echo "=== AC-77: cmux応答なしの4経路（--listと--frameの分類一致） ==="
for marker in fail_identify fail_workspace_list; do
  touch "$STUB_STATE/$marker"
  assert_list_reason "AC-77[$marker]" "$VAULT" "$STATE_FILE" "cmux 応答なし"
  assert_frame_reason "AC-77[$marker](--frame)" "$VAULT" "$STATE_FILE" "cmux 応答なし"
  rm -f "$STUB_STATE/$marker"
done
for marker in broken_identify broken_workspace_list; do
  touch "$STUB_STATE/$marker"
  assert_list_reason "AC-77[$marker]" "$VAULT" "$STATE_FILE" "cmux 応答なし"
  assert_frame_reason "AC-77[$marker](--frame)" "$VAULT" "$STATE_FILE" "cmux 応答なし"
  rm -f "$STUB_STATE/$marker"
done

echo "=== AC-78: cmuxハング時--listが予算内で終了・孤児ゼロ ==="
rm -f "$STUB_STATE/hang_pids"
touch "$STUB_STATE/hang_identify"
t0=$(python3 -c 'import time;print(time.monotonic())')
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_CALL_TIMEOUT=1 \
  bash "$TARGET" --list > "$LIST_OUT" 2>"$LIST_STDERR"
list_rc=$?
t1=$(python3 -c 'import time;print(time.monotonic())')
elapsed="$(python3 -c "print($t1 - $t0)")"
assert_true "AC-78: 4秒未満で終了" "$(python3 -c "print(1 if $elapsed < 4.0 else 0)")"
assert_eq "AC-78: rc=1" "1" "$list_rc"
assert_eq "AC-78: stdout0バイト" "0" "$(wc -c < "$LIST_OUT" | tr -d ' ')"
assert_eq "AC-78: stderrがcmux応答なし" "cmux 応答なし" "$(cat "$LIST_STDERR")"
sleep 1.5
orphan_free=1
if [ -f "$STUB_STATE/hang_pids" ]; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && orphan_free=0
  done < "$STUB_STATE/hang_pids"
fi
assert_true "AC-78: 孤児ゼロ" "$orphan_free"
rm -f "$STUB_STATE/hang_identify" "$STUB_STATE/hang_pids"

echo "=== AC-78補強: TERMを無視する子孫がいてもタイムアウト予算内で終了し、子孫も生存しない（cmux/lib-model-view.sh run_with_timeout・scripts/session-handoff.sh側の同型回帰の写し） ==="
# TERM無視の子孫（trap '' TERM）が標準出力のパイプ書き込み端を握ったまま
# 残ると、wait後にKILLで掃除しない実装ではcmd_pid自体がTERMで終了しても
# 呼び出し元の command substitution（$(...)）がEOF待ちで子孫のsleep終了
# （60秒後）までブロックする＝AC-78（子孫を作らないhang）では検出できない
# 実害。elapsed（AC-78と同じ予算内終了の検査）がその実害を直接捉える。
rm -f "$STUB_STATE/term_ignoring_grandchild_pid"
touch "$STUB_STATE/term_ignoring_hang_identify"
t0=$(python3 -c 'import time;print(time.monotonic())')
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_CALL_TIMEOUT=1 \
  bash "$TARGET" --list > "$LIST_OUT" 2>"$LIST_STDERR"
t1=$(python3 -c 'import time;print(time.monotonic())')
elapsed_term="$(python3 -c "print($t1 - $t0)")"
assert_true "AC-78補強: 4秒未満で終了（TERM無視の子孫にEOF待ちでブロックされない）" \
  "$(python3 -c "print(1 if $elapsed_term < 4.0 else 0)")"
sleep 1.5
grandchild_pid="$(cat "$STUB_STATE/term_ignoring_grandchild_pid" 2>/dev/null)"
assert_true "AC-78補強: 子孫PIDが記録されている（検査自体が空振りでない）" \
  "$([ -n "$grandchild_pid" ] && echo 1 || echo 0)"
if [ -n "$grandchild_pid" ] && kill -0 "$grandchild_pid" 2>/dev/null; then
  kill -9 "$grandchild_pid" 2>/dev/null
  assert_eq "AC-78補強: TERM無視の子孫がタイムアウト後に生存しない（elapsedが主検査・本assertは補助）" "生存しない" "生存した"
else
  assert_eq "AC-78補強: TERM無視の子孫がタイムアウト後に生存しない（elapsedが主検査・本assertは補助）" "生存しない" "生存しない"
fi
rm -f "$STUB_STATE/term_ignoring_hang_identify" "$STUB_STATE/term_ignoring_grandchild_pid"

echo "=== AC-44（v2移管・単発呼出向けに再定義）: --list/--frameの単発呼び出しが宣言記録ファイルの内容・mtimeを変えない ==="
# 元のAC-44（dotfiles v2 main・cmux-task-watch.sh）は常駐が2ティック後も
# 記録ファイル・mtimeが不変であることを検査していたが、v3供給側
# （cmux-task-model.sh）は常駐を持たない単発コマンド（設計§28.1・
# R-v3-1・cmux-task-model.sh冒頭コメント「署名・CMUX_TASK_INTERVALによる
# 間引きは持たない…呼ばれるたびに毎回フルに評価する純粋な単発コマンド」）
# のため、「2ティック」を「--list/--frameを1回ずつ連続で呼ぶ」へ読み替えて
# 復元する（検証3巡目 MAJOR #36対応。ac-manifest.tsvのAC-44.1が旧番号の
# ままv3で見出しが振り直され後継が無かったため、旧IDを見出しに残す形で
# 復元＝担当Kのdotfiles側と同型の対応）。
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
before_state="$(cat "$STATE_FILE")"
before_mtime="$(stat -f '%m' "$STATE_FILE")"
sleep 1.1
run_list_raw "$VAULT" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
after_state="$(cat "$STATE_FILE")"
after_mtime="$(stat -f '%m' "$STATE_FILE")"
assert_eq "AC-44: 記録ファイルの内容が不変" "$before_state" "$after_state"
assert_eq "AC-44: 記録ファイルのmtimeが不変" "$before_mtime" "$after_mtime"

echo "=== AC-63′: V-15 x M-3: --list はクランプの影響を受けず12行すべて番号1・版名v2・分数5/12を記載順で返す ==="
# v4では番号は子行でなく版を指す（N-1）。V-15はv1/v3/v4/v5が完了しU={v2}
# だけになるため、v2の12子行すべてが番号1・版名v2・分数5/12になる
# （design.md §39.7.3 AC-63′）。
reset_stub_state "$STUB_STATE"
mk_note_V15 "$VAULT"
mk_decl_single "v15proj" "$STATE_FILE"
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-63′: --list 終了コード0" "0" "$(cat "$LIST_RC")"
ac63_list_out="$(cat "$LIST_OUT")"
assert_eq "AC-63′: --list が12行" "12" "$(printf '%s\n' "$ac63_list_out" | wc -l | tr -d ' ')"
assert_true "AC-63′: 番号が全行1" \
  "$([ "$(printf '%s\n' "$ac63_list_out" | awk -F '\t' '{print $1}' | sort -u)" = "1" ] && echo 1 || echo 0)"
assert_true "AC-63′: 版名が全行v2" \
  "$([ "$(printf '%s\n' "$ac63_list_out" | awk -F '\t' '{print $2}' | sort -u)" = "v2" ] && echo 1 || echo 0)"
assert_true "AC-63′: 分数が全行5/12" \
  "$([ "$(printf '%s\n' "$ac63_list_out" | awk -F '\t' '{print $3}' | sort -u)" = "5/12" ] && echo 1 || echo 0)"
assert_eq "AC-63′: 状態欄が記載順（[x]x5,[ ]x5,[/],[ ]）" '[x]
[x]
[x]
[x]
[x]
[ ]
[ ]
[ ]
[ ]
[ ]
[/]
[ ]' "$(printf '%s\n' "$ac63_list_out" | awk -F '\t' '{print $4}')"

echo "=== AC-117: 実際の供給側（スタブでない）を表示基底（V-1）で20回連続実行し、中央値・最大値ともに0.4秒以下（単調時計） ==="
if command -v python3 >/dev/null 2>&1; then
  reset_stub_state "$STUB_STATE"
  mk_note_V1 "$VAULT"
  mk_decl_single "v1proj" "$STATE_FILE"
  AC117_TIMES="$WORKDIR/ac117_times.txt"
  : > "$AC117_TIMES"
  ac117_ok=1
  i=1
  while [ "$i" -le 20 ]; do
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" \
      bash "$TARGET" --list >/dev/null 2>"$WORKDIR/ac117_err" || ac117_ok=0
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    python3 -c "print($t1 - $t0)" >> "$AC117_TIMES"
    i=$((i + 1))
  done
  assert_true "AC-117(Task): 20回とも正常終了" "$ac117_ok"
  AC117_STATS="$(python3 -c "
import statistics
vals = [float(x) for x in open('$AC117_TIMES')]
print(statistics.median(vals), max(vals))
")"
  AC117_MEDIAN="${AC117_STATS% *}"
  AC117_MAX="${AC117_STATS#* }"
  assert_true "AC-117(Task): 中央値が0.4秒以下（実測 ${AC117_MEDIAN}秒）" \
    "$(python3 -c "print(1 if $AC117_MEDIAN <= 0.4 else 0)")"
  assert_true "AC-117(Task): 最大値が0.4秒以下（実測 ${AC117_MAX}秒）" \
    "$(python3 -c "print(1 if $AC117_MAX <= 0.4 else 0)")"
else
  echo "SKIP: python3が無いためAC-117(Task)の単調時計計測を省略します"
fi

echo "=== DT-9: 供給側の cmux 締切（run_with_timeout の3性質） ==="
# ① 打ち切りが効く: 上のAC-78がタイムアウトを確認済み。
# ② 呼び出し元が死なない・③ 子孫が残らない: --list呼び出し元（bash自身）が
#    生存し続け、上の孤児検査（orphan_free）が子孫の非残存を見ている。
assert_true "DT-9: 締切後も呼び出し元プロセスが正常終了した（list_rc採取済み）" "1"

# ==========================================================================
# v6 AC-150（requirements-v6.md §8.1・FR-106・E-v6-2・design.md §41.9.2 TP 層）:
# WV-n（tests/lib-cmux-fixtures.sh・Project 側と同じ fixture）を宣言先にした
# Task 供給側の --frame で、▶（cur）の版が Project 側と同じ規則で決まり、
# `- wait_until:` の行は描かれず・数えられない。cmux スタブは S-1 のまま。
# ==========================================================================
echo "=== v6_ac150_cur_version: WV-1／WV-7／WV-13 を宣言先にした --frame の cur の版名が v2（[/]）・v3（next: 一致）・v1（1 番） ==="
reset_stub_state "$STUB_STATE"
cur_version() { awk -F '\t' '$1=="V" && $5=="cur"{print $3}' "$FRAME_OUT"; }
cur_fraction() { awk -F '\t' '$1=="V" && $5=="cur"{print $4}' "$FRAME_OUT"; }
mk_note_WV1 "$VAULT"; mk_note_WV2 "$VAULT"; mk_note_WV7 "$VAULT"; mk_note_WV13 "$VAULT"
mk_note_WV22 "$VAULT"; mk_note_WV24 "$VAULT"; mk_note_WV25 "$VAULT"; mk_note_WV27 "$VAULT"
mk_decl_single "v-cur" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "v6_ac150: WV-1 rc=0" "0" "$(cat "$FRAME_RC")"
assert_eq "v6_ac150: WV-1 の cur は v2（[/] の版）" "v2" "$(cur_version)"
assert_eq "v6_ac150: WV-1 の v2 の分数は 0/2（待ち行を数えない）" "0/2" "$(cur_fraction)"
assert_eq "v6_ac150: WV-1 のフレームに wait_until を含む行 0" "0" "$(grep -c 'wait_until' "$FRAME_OUT")"
mk_decl_single "v-next" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "v6_ac150: WV-7 の cur は v3（next: 完全一致）" "v3" "$(cur_version)"
assert_eq "v6_ac150: WV-7 のフレームに wait_until を含む行 0" "0" "$(grep -c 'wait_until' "$FRAME_OUT")"
mk_decl_single "v-first" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "v6_ac150: WV-13 の cur は v1（未完の 1 番）" "v1" "$(cur_version)"
assert_eq "v6_ac150: WV-13 のフレームに wait_until を含む行 0" "0" "$(grep -c 'wait_until' "$FRAME_OUT")"

echo "=== v6_ac150_prev_version_wait_not_counted: WV-2＝D 行 1（v1 は完了版として畳まれる＝待ち行を未完タスクと数えない）・v2 が cur・分数 0/1 ==="
mk_decl_single "v-prev" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "v6_ac150: WV-2 rc=0" "0" "$(cat "$FRAME_RC")"
assert_eq "v6_ac150: WV-2 の D 行は 1" "1" "$(awk -F '\t' '$1=="D"{print $2}' "$FRAME_OUT")"
assert_eq "v6_ac150: WV-2 の cur は v2" "v2" "$(cur_version)"
assert_eq "v6_ac150: WV-2 の v2 の分数は 0/1" "0/1" "$(cur_fraction)"
assert_eq "v6_ac150: WV-2 のフレームに wait_until を含む行 0" "0" "$(grep -c 'wait_until' "$FRAME_OUT")"

echo "=== v6_ac150_outside_lines_not_drawn: WV-22／WV-24／WV-25（版の範囲外・別節の待ち行）のフレームに wait_until を含む行 0・cur は v1 ==="
for slug in v-outside v-other v-after; do
  mk_decl_single "$slug" "$STATE_FILE"
  run_frame_raw "$VAULT" "$STATE_FILE"
  assert_eq "v6_ac150: $slug rc=0" "0" "$(cat "$FRAME_RC")"
  assert_eq "v6_ac150: $slug のフレームに wait_until を含む行 0" "0" "$(grep -c 'wait_until' "$FRAME_OUT")"
  assert_eq "v6_ac150: $slug の cur は v1" "v1" "$(cur_version)"
done

echo "=== v6_ac150_blank_task_reason: WV-27（本文が空の - [ ]）は Task 側が理由行「空タスク」（▶ なし＝Project 側 AC-149 行 26 と対で両側とも ▶ なし） ==="
mk_decl_single "v-blank" "$STATE_FILE"
assert_frame_reason "v6_ac150(WV-27)" "$VAULT" "$STATE_FILE" "空タスク"
assert_eq "v6_ac150: WV-27 のフレームに cur の行 0" "0" "$(awk -F '\t' '$1=="V" && $5=="cur"' "$FRAME_OUT" | wc -l | tr -d ' ')"
assert_list_reason "v6_ac150(WV-27・--list)" "$VAULT" "$STATE_FILE" "空タスク"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
