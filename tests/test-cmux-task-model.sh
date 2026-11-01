#!/bin/bash
# fixture Vault と偽 cmux で、表示の形・今の版・無応答からの回復を確認する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../dock/executor/cmux-task-model.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-task-model-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

. "$SCRIPT_DIR/lib-cmux-fixtures.sh"

STUB_STATE="$WORKDIR/stubstate"
STUBBIN="$WORKDIR/stubbin"
VAULT="$WORKDIR/vault"
STATE_FILE="$WORKDIR/decl.json"
mkdir -p "$STUB_STATE" "$STUBBIN" "$VAULT/Projects"

PASS=0
FAIL=0

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

write_cmux_stub "$STUBBIN/cmux"
export CMUX_TASK_CMUX_BIN="$STUBBIN/cmux"
export STUB_STATE

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
reset_stub_state "$STUB_STATE"
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"

echo "=== frame/list の生成物の形 ==="
run_frame_raw "$VAULT" "$STATE_FILE"
assert_true "frame は版宣言と終端を持つ" "$([ "$(cat "$FRAME_RC")" = 0 ] && awk -F '\t' 'NR==1 {if($1!="#V" || $3!="Task") exit 1} END {if($1!="E") exit 1}' "$FRAME_OUT" && echo 1 || echo 0)"
assert_true "進行中の版に cur が付く" "$(awk -F '\t' '$1=="V" && $5=="cur" && $3=="v2" {found=1} END {exit !found}' "$FRAME_OUT" && echo 1 || echo 0)"
run_list_raw "$VAULT" "$STATE_FILE"
assert_true "list は非空の5列 TSV" "$([ "$(cat "$LIST_RC")" = 0 ] && awk -F '\t' 'NF!=5 {exit 1} END {if(!NR) exit 1}' "$LIST_OUT" && echo 1 || echo 0)"

echo "=== cmux 無応答は理由を示して縮退する ==="
touch "$STUB_STATE/fail_identify"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_true "frame は終了 0 で理由を表示" "$([ "$(cat "$FRAME_RC")" = 0 ] && grep -q 'cmux 応答なし' "$FRAME_OUT" && echo 1 || echo 0)"
run_list_raw "$VAULT" "$STATE_FILE"
assert_true "list は終了 1 で無出力と理由" "$([ "$(cat "$LIST_RC")" = 1 ] && [ ! -s "$LIST_OUT" ] && grep -q 'cmux 応答なし' "$LIST_STDERR" && echo 1 || echo 0)"
rm "$STUB_STATE/fail_identify"
run_frame_raw "$VAULT" "$STATE_FILE"
assert_true "回復時は通常フレームに戻る" "$([ "$(cat "$FRAME_RC")" = 0 ] && grep -q '^V' "$FRAME_OUT" && ! grep -q '^R' "$FRAME_OUT" && echo 1 || echo 0)"

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
