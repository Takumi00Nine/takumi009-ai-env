#!/bin/bash
# fixture Vault と偽 cmux で、表示の形・非破壊・宣言先の照会を確認する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../dock/executor/cmux-next-model.sh"

unset VAULT_AGENT_LOG_STALE_DAYS

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-model-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'chmod -R u+rwx "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT   # chmod 000 の fixture が残っても片付く

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

echo "=== list/frame は形を保ち、読み取りだけを行う ==="
mk_notes_N_all "$VAULT"
STUBBIN="$WORKDIR/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/bash\necho called >> "%s"\nexit 9\n' "$WORKDIR/cmux-calls" > "$STUBBIN/cmux"
chmod +x "$STUBBIN/cmux"
export PATH="$STUBBIN:$PATH"
before="$(find "$VAULT" -type f -exec shasum -a 256 {} \; | sort)"
run_list_raw
assert_true "list は非空の5列 TSV" "$([ "$(cat "$WORKDIR/list_rc")" = 0 ] && awk -F '\t' 'NF!=5 {exit 1} END {if(NR==0) exit 1}' "$WORKDIR/list_stdout" && echo 1 || echo 0)"
run_frame_raw
assert_true "frame は版宣言と終端を持つ" "$([ "$(cat "$WORKDIR/frame_rc")" = 0 ] && awk -F '\t' 'NR==1 {if($1!="#V" || $3!="Project") exit 1} END {if($1!="E") exit 1}' "$WORKDIR/frame_stdout" && echo 1 || echo 0)"
assert_true "frame の Project 行は6列" "$(awk -F '\t' '$1=="P" {n++; if(NF!=6) exit 1} END {if(!n) exit 1}' "$WORKDIR/frame_stdout" && echo 1 || echo 0)"
assert_true "list/frame は cmux を呼ばない" "$([ ! -e "$WORKDIR/cmux-calls" ] && echo 1 || echo 0)"
assert_eq "Vault は変更されない" "$before" "$(find "$VAULT" -type f -exec shasum -a 256 {} \; | sort)"

echo "=== focus は宣言先を返す ==="
FD_HOME="$WORKDIR/fd-home"; FD_STATE="$WORKDIR/fd-state"; FD_BIN="$WORKDIR/fd-bin"
FD_RECORD="$FD_HOME/.config/cmux-task-watch/workspaces.json"
mkdir -p "$FD_BIN"
write_fd_cmux_stub "$FD_BIN/cmux"
export FD_STATE
mk_fd_record "$FD_RECORD" base
reset_fd_state "$FD_STATE" workspace:1
out="$(HOME="$FD_HOME" PATH="$FD_BIN:$PATH" CMUX_TASK_CMUX_BIN="$FD_BIN/cmux" CMUX_TASK_STATE="$FD_RECORD" bash "$TARGET" --focus 2>"$WORKDIR/focus.err")"; rc=$?
assert_true "focus が宣言先 slug を返す" "$([ "$rc" -eq 0 ] && [ "$out" = "p-act2" ] && [ ! -s "$WORKDIR/focus.err" ] && echo 1 || echo 0)"
touch "$FD_STATE/fail_identify"
out="$(HOME="$FD_HOME" PATH="$FD_BIN:$PATH" CMUX_TASK_CMUX_BIN="$FD_BIN/cmux" CMUX_TASK_STATE="$FD_RECORD" bash "$TARGET" --focus 2>"$WORKDIR/focus.err")"; rc=$?
assert_true "cmux が使えなくても focus は終了 0" "$([ "$rc" -eq 0 ] && [ -z "$out" ] && [ -s "$WORKDIR/focus.err" ] && echo 1 || echo 0)"

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
