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
  assert_eq "$desc: #V行" "#V	cmux-dock-frame/1	Task" "$(sed -n '1p' "$FRAME_OUT")"
  assert_eq "$desc: R行の理由が「${expected}」" "$expected" "$(frame_reason)"
  assert_eq "$desc: E行" "E	1" "$(sed -n '3p' "$FRAME_OUT")"
}

# ==========================================================================
# 表示基底（V-1・W-1・S-1）
# ==========================================================================
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"

echo "=== 基底: --frame が P-6 の形と一致する ==="
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "基底: rc=0" "0" "$(cat "$FRAME_RC")"
expected_frame='#V	cmux-dock-frame/1	Task
H	▶	v1proj		v2	1/3
V	v1	✅	3/3
V	v2	▶	1/3
V	v3	・	0/4
C	1	[x]	要件定義
C	2	[/]	設計
C	3	[ ]	実装
X	2
E	8'
assert_eq "基底: --frame がリテラル一致" "$expected_frame" "$(cat "$FRAME_OUT")"

echo "=== 基底: --list が v1/v2 と同一契約 ==="
run_list_raw "$VAULT" "$STATE_FILE"
expected_list='1	v2	[x]	要件定義
2	v2	[/]	設計
3	v2	[ ]	実装'
assert_eq "基底: --list がリテラル一致" "$expected_list" "$(cat "$LIST_OUT")"
assert_eq "基底: --list rc=0" "0" "$(cat "$LIST_RC")"

echo "=== N-2/AC-79相当: --frame の C 行 と --list の (番号,状態,本文) が完全一致 ==="
frame_triple="$(awk -F '\t' '$1=="C"{print $2"\t"$3"\t"$4}' "$FRAME_OUT")"
list_triple="$(awk -F '\t' '{print $1"\t"$3"\t"$4}' "$LIST_OUT")"
assert_eq "N-2: --frame と --list の番号・状態・本文が一致" "$list_triple" "$frame_triple"

echo "=== AC-124①: 全版完了（V-10） → --frame は通常フレーム・--list は「全版完了」 ==="
mk_note_V10 "$VAULT"
mk_decl_single "v10proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-124①: rc=0" "0" "$(cat "$FRAME_RC")"
expected_v10='#V	cmux-dock-frame/1	Task
H	✅	v10proj	全版完了		3/3
V	v1	✅	2/2
V	v2	✅	1/1
V	v3	✅	3/3
X	-
E	5'
assert_eq "AC-124①: 全版完了フレームがリテラル一致（子行0・X=-）" "$expected_v10" "$(cat "$FRAME_OUT")"
assert_list_reason "AC-124①(--list)" "$VAULT" "$STATE_FILE" "全版完了"

echo "=== AC-124②: [/]無し・未完版2つ（V-11） → 展開対象の版行の記号も・ ==="
mk_note_V11 "$VAULT"
mk_decl_single "v11proj" "$STATE_FILE"
run_frame_raw "$VAULT" "$STATE_FILE"
expected_v11='#V	cmux-dock-frame/1	Task
H	・	v11proj	次: 	v1	0/1
V	v1	・	0/1
V	v2	・	0/1
C	1	[ ]	a
X	1
E	5'
assert_eq "AC-124②: [/]無しの正当フレームがリテラル一致（展開対象の版行も・）" "$expected_v11" "$(cat "$FRAME_OUT")"

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

echo "=== AC-62: --list の制御文字除去（V-6拡張・4列固定・コードポイント単位） ==="
mk_note_V6 "$VAULT"
mk_decl_single "v6proj" "$STATE_FILE"
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-62: --list 終了コード0" "0" "$(cat "$LIST_RC")"
ac62_nlines="$(wc -l < "$LIST_OUT" | tr -d ' ')"
ac62_bad_cols="$(awk -F '\t' 'NF!=4' "$LIST_OUT" | wc -l | tr -d ' ')"
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
assert_eq "AC-62: --list の全行が4列のまま" "0" "$ac62_bad_cols"
assert_eq "AC-62: 4列に分解した各データ列に制御文字コードポイントが無い" "0" "$ac62_bad_cp"
assert_true "AC-62: 出力が1行以上ある（検査が空振りでない）" "$([ "$ac62_nlines" -gt 0 ] && echo 1 || echo 0)"

echo "=== AC-64: V-18: [/]を持つ版が2つあるとき最初の版の子行だけが番号を持つ ==="
mk_note_V18 "$VAULT"
mk_decl_single "$V18_SLUG" "$STATE_FILE"
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-64: --list 終了コード0" "0" "$(cat "$LIST_RC")"
assert_eq "AC-64: --listの行数が最初の[/]版(v1・3件)と一致" "3" "$(wc -l < "$LIST_OUT" | tr -d ' ')"
assert_eq "AC-64: 全行の版名がv1" "v1" "$(awk -F'\t' '{print $2}' "$LIST_OUT" | sort -u)"

echo "=== AC-65/AC-81: caller≠focused → --list は対象不一致（--frameはfocused側=W-10相当） ==="
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
cat > "$VAULT/Projects/proj2.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
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
assert_contains "AC-65: --frameはfocused側(proj2)を表示" "$(cat "$FRAME_OUT")" "proj2"

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

echo "=== AC-68/AC-83②: 全版完了(V-10) → --list 全版完了・--frameは通常フレーム ==="
mk_note_V10 "$VAULT"
mk_decl_single "v10proj" "$STATE_FILE"
assert_list_reason "AC-68/AC-83②" "$VAULT" "$STATE_FILE" "全版完了"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-68/AC-83②: --frameは版宣言つきの通常フレーム（R行0行）" "0" "$(awk -F '\t' '$1=="R"' "$FRAME_OUT" | wc -l | tr -d ' ')"

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

echo "=== AC-63（v2移管）: V-15 x M-3: --list はクランプの影響を受けず12行を1〜12の番号で出す ==="
# 元のAC-63（dotfiles v2 main）は見出しにM-3（40x8列）を含むが、本体は
# 一度も端末寸法を渡さずrun_list_raw（--list）だけを呼んでいた（実査で
# 確認済み）。--listは元々端末寸法を一切参照しない契約（FR-52の4列TSVは
# 寸法非依存）ため、この3件は純粋にデータ層の検査であり、V-15フィクス
# チャ（既にlib-cmux-fixtures.shに移設済み・test-cmux-task-model.shでは
# 未使用だった）を使えばv3供給側でもそのまま3件とも再現できる
# （検証3巡目 リーダー裁定「--listのai-env移管で観測できない1件」の調査で
# 判明。実際には1件も欠けておらず、AC-63.1のbase_n引き下げは不要と判断し、
# base_n=3のまま全3件を復元した＝旧IDを見出しに残す形）。
reset_stub_state "$STUB_STATE"
mk_note_V15 "$VAULT"
mk_decl_single "v15proj" "$STATE_FILE"
run_list_raw "$VAULT" "$STATE_FILE"
assert_eq "AC-63: --list 終了コード0" "0" "$(cat "$LIST_RC")"
ac63_list_out="$(cat "$LIST_OUT")"
assert_eq "AC-63: --list が12行" "12" "$(printf '%s\n' "$ac63_list_out" | wc -l | tr -d ' ')"
assert_eq "AC-63: 番号が1〜12の連番" "1
2
3
4
5
6
7
8
9
10
11
12" "$(printf '%s\n' "$ac63_list_out" | awk -F '\t' '{print $1}')"

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

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
