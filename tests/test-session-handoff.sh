#!/bin/bash
# scripts/session-handoff.sh のユニットテスト。
# 実 cmux・実 Vault・実 ~/.claude には一切触れない。cmux 呼び出しは
# $WORKDIR/stubbin/cmux（スタブ）へ SESSION_HANDOFF_CMUX_BIN 経由で差し替える。
#
# 実行方法: bash tests/test-session-handoff.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/session-handoff.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/session-handoff-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

STUB_STATE="$WORKDIR/stubstate"
STUBBIN="$WORKDIR/stubbin"
NOTES="$WORKDIR/notes"
mkdir -p "$STUB_STATE" "$STUBBIN" "$NOTES"
export STUB_STATE

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

# ==========================================================================
# cmux スタブ
# ==========================================================================
cat > "$STUBBIN/cmux" <<'STUB'
#!/bin/bash
STATE="$STUB_STATE"
{
  printf 'cmux'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
} >> "$STATE/calls.log"

sub="${1:-}"

case "$sub" in
  new-workspace)
    if [ -e "$STATE/fail_new_workspace" ]; then
      echo "new-workspace failed" >&2
      exit 1
    fi
    if [ -e "$STATE/no_ref_new_workspace" ]; then
      echo "OK (no ref here)"
      exit 0
    fi
    if [ -e "$STATE/garbage_new_workspace" ]; then
      echo "garbage workspace:9 extra"
      exit 0
    fi
    if [ -e "$STATE/multi_ref_new_workspace" ]; then
      echo "OK workspace:4"
      echo "OK workspace:5"
      exit 0
    fi
    echo "OK workspace:4"
    exit 0
    ;;
  read-screen)
    count_file="$STATE/read_screen_count"
    count=0
    [ -f "$count_file" ] && count="$(cat "$count_file")"
    count=$(( count + 1 ))
    echo "$count" > "$count_file"
    hang_at=0
    [ -f "$STATE/hang_at_call" ] && hang_at="$(cat "$STATE/hang_at_call")"
    if [ "$hang_at" != "0" ] && [ "$count" -eq "$hang_at" ]; then
      sleep 30
      exit 1
    fi
    if [ -e "$STATE/spawn_term_ignoring_grandchild" ]; then
      # 自分自身（親）はTERMを無視しないが、無視する子孫を先に作ってから
      # ハングする（検証3巡目 #2: 親がTERMで先に終了し、以後のwatcherの
      # KILLが届かないまま子孫だけ生き残る不具合の再現用）。
      ( trap '' TERM; sleep 30 ) &
      echo "$!" > "$STATE/term_ignoring_grandchild_pid"
      sleep 30
      exit 1
    fi
    if [ -f "$STATE/slow_read_screen_secs" ]; then
      sleep "$(cat "$STATE/slow_read_screen_secs")"
    fi
    if [ -e "$STATE/fail_read_screen" ]; then
      echo "read-screen failed" >&2
      exit 1
    fi
    fail_n=0
    [ -f "$STATE/read_screen_fail_count" ] && fail_n="$(cat "$STATE/read_screen_fail_count")"
    if [ "$count" -le "$fail_n" ]; then
      echo "transient read-screen failure" >&2
      exit 7
    fi
    if [ -e "$STATE/never_prompt" ]; then
      echo "still starting..."
      exit 0
    fi
    if [ -e "$STATE/prompt_not_at_line_start" ]; then
      echo "window title contains ❯ but prompt is absent"
      exit 0
    fi
    need=1
    [ -f "$STATE/prompt_at_call" ] && need="$(cat "$STATE/prompt_at_call")"
    if [ "$count" -ge "$need" ]; then
      echo "some banner text"
      echo "❯ "
    else
      echo "still starting..."
    fi
    exit 0
    ;;
  send)
    # 引数の境界をそのまま検査できるよう1引数1行で記録する（$* だと単語
    # 分割で境界が分からなくなるため）。
    : > "$STATE/last_send_argv.txt"
    for a in "$@"; do printf '%s\n' "$a" >> "$STATE/last_send_argv.txt"; done
    last=""
    for a in "$@"; do last="$a"; done
    printf '%s' "$last" > "$STATE/last_send_message"
    echo "$#" > "$STATE/last_send_argc"
    if [ -e "$STATE/noisy_send" ]; then
      echo "noise from send stub"
    fi
    if [ -e "$STATE/fail_send" ]; then
      exit 1
    fi
    exit 0
    ;;
  send-key)
    : > "$STATE/last_sendkey_argv.txt"
    for a in "$@"; do printf '%s\n' "$a" >> "$STATE/last_sendkey_argv.txt"; done
    echo "$#" > "$STATE/last_sendkey_argc"
    if [ -e "$STATE/noisy_send_key" ]; then
      echo "noise from send-key stub"
    fi
    if [ -e "$STATE/fail_send_key" ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "unhandled: $*" >&2
    exit 9
    ;;
esac
STUB
chmod +x "$STUBBIN/cmux"

reset_stub_state() {
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE"
}

resolve_abs() {
  local p="$1" dir base
  dir="$(cd -P "$(dirname "$p")" && pwd)"
  base="$(basename "$p")"
  printf '%s/%s' "$dir" "$base"
}

# デフォルトは全待ち秒数0（高速化）。CALL_TIMEOUTだけ既定5（通常経路は
# 即時応答なので影響しない）。T5/T6/ハング系だけ個別に上書きする。
run_target() {
  local wait="${SH_WAIT:-0}" grace="${SH_GRACE:-0}" gap="${SH_GAP:-0}" call_timeout="${SH_CALL_TIMEOUT:-5}"
  SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" \
  SESSION_HANDOFF_WAIT_SEC="$wait" \
  SESSION_HANDOFF_GRACE_SEC="$grace" \
  SESSION_HANDOFF_SEND_GAP_SEC="$gap" \
  SESSION_HANDOFF_CALL_TIMEOUT_SEC="$call_timeout" \
  bash "$TARGET" "$@"
}

calls_log_is_empty() {
  [ ! -s "$STUB_STATE/calls.log" ]
}

# 呼び出し順序を検査する（new-workspace→read-screen(N回)→send→send-key）。
# $1 = 期待するread-screen回数（"any"なら1回以上ならOK）。
# 成功時0・失敗時1を返す。呼んだread-screen回数はREAD_COUNT_RESULTへ。
READ_COUNT_RESULT=0
check_call_order() {
  local want_reads="$1" subcmds state c read_count ok
  subcmds="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
  state="expect_new"
  read_count=0
  ok=1
  while IFS= read -r c; do
    case "$state" in
      expect_new)
        if [ "$c" = "new-workspace" ]; then
          state="reads"
        else
          ok=0; break
        fi
        ;;
      reads)
        if [ "$c" = "read-screen" ]; then
          read_count=$(( read_count + 1 ))
        elif [ "$c" = "send" ]; then
          state="sent"
        else
          ok=0; break
        fi
        ;;
      sent)
        if [ "$c" = "send-key" ]; then
          state="done"
        else
          ok=0; break
        fi
        ;;
      done)
        ok=0; break
        ;;
    esac
  done <<EOF
$subcmds
EOF
  [ "$state" = "done" ] || ok=0
  if [ "$want_reads" = "any" ]; then
    [ "$read_count" -ge 1 ] || ok=0
  else
    [ "$read_count" -eq "$want_reads" ] || ok=0
  fi
  READ_COUNT_RESULT="$read_count"
  [ "$ok" -eq 1 ]
}

NOTE="$NOTES/resume.md"
cat > "$NOTE" <<'EOF'
# 再開メモ（テスト用ダミー）
EOF

# ==========================================================================
# T1: 引数不足／再開メモ不在／依頼が空／依頼に改行／不明オプション／
#     --cwd 不在 → 各 exit 1・calls.log が空
# ==========================================================================
echo "=== T1: 不正入力は cmux を一切呼ばず exit 1 ==="

reset_stub_state
run_target >/dev/null 2>&1
assert_eq "T1a: 引数0個でexit1" "1" "$?"
assert_true "T1a: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
run_target "$NOTE" >/dev/null 2>&1
assert_eq "T1b: 引数1個（依頼欠落）でexit1" "1" "$?"
assert_true "T1b: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
run_target "$WORKDIR/no-such-note.md" "続きの依頼" >/dev/null 2>&1
assert_eq "T1c: 再開メモ不在でexit1" "1" "$?"
assert_true "T1c: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
run_target "$NOTE" "" >/dev/null 2>&1
assert_eq "T1d: 依頼が空文字でexit1" "1" "$?"
assert_true "T1d: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
newline_task="$(printf '1行目\n2行目')"
run_target "$NOTE" "$newline_task" >/dev/null 2>&1
assert_eq "T1e: 依頼に改行を含むとexit1" "1" "$?"
assert_true "T1e: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
run_target "$NOTE" "続きの依頼" --bogus-option >/dev/null 2>&1
assert_eq "T1f: 不明オプションでexit1" "1" "$?"
assert_true "T1f: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
run_target "$NOTE" "続きの依頼" --cwd "$WORKDIR/no-such-dir" >/dev/null 2>&1
assert_eq "T1g: --cwd 不在でexit1" "1" "$?"
assert_true "T1g: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

# -h/--help も cmux を呼ばずexit0（確定仕様①の基本挙動）
reset_stub_state
"$TARGET" -h >/dev/null 2>&1
assert_eq "T1h: -h でexit0" "0" "$?"
assert_true "T1h: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

# 検証2巡目 #1: 不正な環境変数の下でも --help は先に判定されexit0になる。
reset_stub_state
SESSION_HANDOFF_WAIT_SEC="bad" "$TARGET" --help >/dev/null 2>&1
assert_eq "T1i: 不正なWAIT_SECの下でも--helpでexit0" "0" "$?"
assert_true "T1i: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

# 改行入りメモパス→exit1（検証2巡目 #5: Unixでは通常ファイル名にLF/CRを
# 含められるため、絶対パスへ正規化した後の改行検査を直に確かめる）。
reset_stub_state
newline_note="$NOTES/resume"$'\n'"newline.md"
: > "$newline_note" 2>/dev/null
if [ -f "$newline_note" ]; then
  run_target "$newline_note" "続きの依頼T1j" >/dev/null 2>&1
  assert_eq "T1j: 改行入りメモパスでexit1" "1" "$?"
  assert_true "T1j: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"
else
  echo "SKIP: T1j（本ファイルシステムは改行入りファイル名を作成できない）"
fi

# ==========================================================================
# T2: 正常系（順序・--workspace付与・stdout）
# ==========================================================================
echo "=== T2: 正常系 ==="
reset_stub_state
cwd_dir="$WORKDIR/t2-cwd"
mkdir -p "$cwd_dir"
out="$(run_target "$NOTE" "続きの依頼T2" --cwd "$cwd_dir" --name "T2題")"
rc=$?
assert_eq "T2: exit0" "0" "$rc"

first_line="$(sed -n '1p' "$STUB_STATE/calls.log")"
assert_contains "T2: 最初の呼び出しがnew-workspace" "$first_line" "[new-workspace]"
assert_contains "T2: --nameが渡る" "$first_line" "[T2題]"
assert_contains "T2: --commandにcctが渡る" "$first_line" "[cct]"
assert_contains "T2: --focus trueが渡る" "$first_line" "[--focus] [true]"

assert_true "T2: 呼び出し順序がnew-workspace→read-screen(>=1)→send→send-key" \
  "$(check_call_order any && echo 1 || echo 0)"

total_lines="$(wc -l < "$STUB_STATE/calls.log" | tr -d ' ')"
tail_n=$(( total_lines - 1 ))
non_first="$(tail -n "$tail_n" "$STUB_STATE/calls.log")"
missing_ws="$(printf '%s\n' "$non_first" | grep -vF '[--workspace] [workspace:4]' | grep -c . || true)"
assert_eq "T2: read-screen以降の全呼び出しがworkspace:4を持つ" "0" "$missing_ws"

ref_line="$(printf '%s\n' "$out" | sed -n '1p')"
sent_line="$(printf '%s\n' "$out" | sed -n '2p')"
assert_eq "T2: stdout1行目がREF=workspace:4" "REF=workspace:4" "$ref_line"
assert_contains "T2: stdout2行目がSENT=再開メモ..." "$sent_line" "SENT=再開メモ"
out_line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "T2: stdoutがちょうど2行（send/send-keyの出力が漏れていない）" "2" "$out_line_count"

# ==========================================================================
# T3: send本文の一致・末尾に\r/改行なし・sendの後にread-screenが無い
# ==========================================================================
echo "=== T3: send本文の一致 ==="
reset_stub_state
note_abs="$(resolve_abs "$NOTE")"
expected_msg="再開メモ ${note_abs} を全文読んでから続きをお願いします。続きの依頼T3"
run_target "$NOTE" "続きの依頼T3" >/dev/null

# コマンド置換$(cat ...)は末尾改行を除去してしまい、送信文への余分な
# \r/改行の混入を見逃す（検証1巡目 #8）。バイト列そのものをcmpで比較する。
printf '%s' "$expected_msg" > "$WORKDIR/t3-expected.bin"
cmp -s "$WORKDIR/t3-expected.bin" "$STUB_STATE/last_send_message"
assert_eq "T3: sendの本文がバイト単位で一致する（末尾\\r/改行の混入なし）" "0" "$?"

argc_t3="$(cat "$STUB_STATE/last_send_argc")"
assert_eq "T3: sendの引数がちょうど5個" "5" "$argc_t3"
assert_eq "T3: 第1引数がsend" "send" "$(sed -n '1p' "$STUB_STATE/last_send_argv.txt")"
assert_eq "T3: 第2引数が--workspace" "--workspace" "$(sed -n '2p' "$STUB_STATE/last_send_argv.txt")"
assert_eq "T3: 第3引数がworkspace:4" "workspace:4" "$(sed -n '3p' "$STUB_STATE/last_send_argv.txt")"
assert_eq "T3: 第4引数が--（-- が存在する）" "--" "$(sed -n '4p' "$STUB_STATE/last_send_argv.txt")"

send_line_no="$(grep -n '^cmux \[send\]' "$STUB_STATE/calls.log" | head -n1 | cut -d: -f1)"
after_send="$(tail -n "+$(( send_line_no + 1 ))" "$STUB_STATE/calls.log")"
read_after_send="$(printf '%s\n' "$after_send" | grep -c '\[read-screen\]' || true)"
assert_eq "T3: sendの後にread-screenが無い" "0" "$read_after_send"

echo "--- T3補強: 依頼文が「-」で始まっても不明オプション扱いにしない ---"
reset_stub_state
run_target "$NOTE" "-continue the work" >/dev/null
rc_dash="$?"
assert_eq "T3補強: 先頭が-の依頼でもexit0" "0" "$rc_dash"
expected_dash_msg="再開メモ ${note_abs} を全文読んでから続きをお願いします。-continue the work"
printf '%s' "$expected_dash_msg" > "$WORKDIR/t3-dash-expected.bin"
cmp -s "$WORKDIR/t3-dash-expected.bin" "$STUB_STATE/last_send_message"
assert_eq "T3補強: 先頭が-の依頼が本文にそのまま入る" "0" "$?"

echo "--- T3補強: send-keyの全argvがちょうど「send-key --workspace <REF> Enter」 ---"
reset_stub_state
run_target "$NOTE" "続きの依頼T3sk" >/dev/null
argc_sk="$(cat "$STUB_STATE/last_sendkey_argc")"
assert_eq "T3補強: send-keyの引数がちょうど4個" "4" "$argc_sk"
assert_eq "T3補強: 第1引数がsend-key" "send-key" "$(sed -n '1p' "$STUB_STATE/last_sendkey_argv.txt")"
assert_eq "T3補強: 第2引数が--workspace" "--workspace" "$(sed -n '2p' "$STUB_STATE/last_sendkey_argv.txt")"
assert_eq "T3補強: 第3引数がworkspace:4" "workspace:4" "$(sed -n '3p' "$STUB_STATE/last_sendkey_argv.txt")"
assert_eq "T3補強: 第4引数がEnter" "Enter" "$(sed -n '4p' "$STUB_STATE/last_sendkey_argv.txt")"

echo "--- T3補強: send/send-keyがstdoutへノイズを出しても成功時stdoutは2行のまま ---"
reset_stub_state
touch "$STUB_STATE/noisy_send" "$STUB_STATE/noisy_send_key"
out_noisy="$(run_target "$NOTE" "続きの依頼T3noisy")"
rc_noisy=$?
assert_eq "T3補強: exit0（ノイズがあっても成功）" "0" "$rc_noisy"
out_noisy_line_count="$(printf '%s\n' "$out_noisy" | wc -l | tr -d ' ')"
assert_eq "T3補強: send/send-keyがノイズを出しても最終stdoutはちょうど2行" "2" "$out_noisy_line_count"

# ==========================================================================
# T4: ~/ 先頭の再開メモが $HOME 展開・絶対パスで埋め込まれる
# ==========================================================================
echo "=== T4: ~/ 展開 ==="
reset_stub_state
FAKE_HOME="$WORKDIR/fakehome"
mkdir -p "$FAKE_HOME/notes"
echo "dummy" > "$FAKE_HOME/notes/resume-home.md"
expected_home_abs="$(cd -P "$FAKE_HOME/notes" && pwd)/resume-home.md"
expected_home_msg="再開メモ ${expected_home_abs} を全文読んでから続きをお願いします。続きの依頼T4"
out="$(HOME="$FAKE_HOME" \
  SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" \
  SESSION_HANDOFF_WAIT_SEC=0 SESSION_HANDOFF_GRACE_SEC=0 SESSION_HANDOFF_SEND_GAP_SEC=0 \
  bash "$TARGET" "~/notes/resume-home.md" "続きの依頼T4")"
rc=$?
assert_eq "T4: exit0" "0" "$rc"
home_sent_msg="$(cat "$STUB_STATE/last_send_message")"
assert_eq "T4: ~/がHOME展開され絶対パスで埋め込まれる" "$expected_home_msg" "$home_sent_msg"

# ==========================================================================
# T5: ❯ が3回目のread-screenで出る場合、3回呼ばれてからsend
# ==========================================================================
echo "=== T5: プロンプトが3回目で出る ==="
reset_stub_state
echo 3 > "$STUB_STATE/prompt_at_call"
SH_WAIT=5 SH_GRACE=0 SH_GAP=0 run_target "$NOTE" "続きの依頼T5" >/dev/null
rc=$?
assert_eq "T5: exit0" "0" "$rc"
# check_call_orderをコマンド置換$(...)内で呼ぶとサブシェル境界を跨いで
# READ_COUNT_RESULTへの書込みが失われる（bash32の罠）ため直接呼ぶ。
check_call_order 3
order_rc=$?
assert_true "T5: 呼び出し順序が正しくread-screenが3回" "$([ "$order_rc" -eq 0 ] && echo 1 || echo 0)"
assert_eq "T5: read-screenの呼び出し回数が3" "3" "$READ_COUNT_RESULT"

# ==========================================================================
# T6: ❯ が出ない（WAIT_SEC=2）→ exit3・send/send-keyが呼ばれない・
#     stderrにREFを含む
# ==========================================================================
echo "=== T6: プロンプトが出ないタイムアウト ==="
reset_stub_state
touch "$STUB_STATE/never_prompt"
err_file="$WORKDIR/t6.stderr"
SH_WAIT=2 SH_GRACE=0 SH_GAP=0 run_target "$NOTE" "続きの依頼T6" >/dev/null 2>"$err_file"
rc=$?
assert_eq "T6: exit3" "3" "$rc"
subcmds_t6="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
send_calls_t6="$(printf '%s\n' "$subcmds_t6" | grep -cx 'send\|send-key' || true)"
assert_eq "T6: send/send-keyが呼ばれない" "0" "$send_calls_t6"
assert_contains "T6: stderrにREFを含む" "$(cat "$err_file")" "workspace:4"

# ==========================================================================
# T6補強: WAIT_SEC は実時間の上限（検証2巡目 #4）。read-screenが遅くても
# 少なくとも1回はポーリングし、ハングしても呼出しタイムアウトで打ち切る。
# ==========================================================================
echo "--- T6補強: WAIT_SEC=0でもread-screenが2秒かかるスタブなら1回だけ実行してexit3 ---"
reset_stub_state
echo 2 > "$STUB_STATE/slow_read_screen_secs"
touch "$STUB_STATE/never_prompt"
start_ts="$(date +%s)"
SH_WAIT=0 SH_GRACE=0 SH_GAP=0 SH_CALL_TIMEOUT=5 run_target "$NOTE" "続きの依頼T6a" >/dev/null 2>/dev/null
rc_t6a=$?
end_ts="$(date +%s)"
elapsed_t6a=$(( end_ts - start_ts ))
assert_eq "T6a: exit3" "3" "$rc_t6a"
subcmds_t6a="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
read_count_t6a="$(printf '%s\n' "$subcmds_t6a" | grep -cx 'read-screen' || true)"
assert_eq "T6a: WAIT_SEC=0ではread-screenが1回だけ" "1" "$read_count_t6a"
assert_true "T6a: 所要時間が10秒未満（無期限に待たない）" "$([ "$elapsed_t6a" -lt 10 ] && echo 1 || echo 0)"

echo "--- T6補強: read-screenがハングしても呼出しタイムアウトで打ち切り再試行する ---"
reset_stub_state
echo 1 > "$STUB_STATE/hang_at_call"
echo 2 > "$STUB_STATE/prompt_at_call"
start_ts="$(date +%s)"
SH_WAIT=10 SH_GRACE=0 SH_GAP=0 SH_CALL_TIMEOUT=1 run_target "$NOTE" "続きの依頼T6b" >/dev/null
rc_t6b=$?
end_ts="$(date +%s)"
elapsed_t6b=$(( end_ts - start_ts ))
assert_eq "T6b: exit0（ハング1回のあと2回目の❯で送信）" "0" "$rc_t6b"
subcmds_t6b="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
read_count_t6b="$(printf '%s\n' "$subcmds_t6b" | grep -cx 'read-screen' || true)"
assert_eq "T6b: read-screenが2回（ハング1回＋成功1回）" "2" "$read_count_t6b"
assert_true "T6b: 所要時間が10秒未満（呼出しタイムアウトで打ち切られている）" "$([ "$elapsed_t6b" -lt 10 ] && echo 1 || echo 0)"

echo "--- T6補強: WAIT=2・CALL_TIMEOUT=5・read-screenが8秒かかっても5秒未満にexit3（検証3巡目 #1・検証4巡目 #1） ---"
# slowとWAITの差を広げて秒境界の丸めでフレーキーにならないようにする
# （検証4巡目 #1: 4秒/3秒未満は実測約2.1秒でも秒境界次第で3秒判定になり
# 不安定だった）。8秒/5秒未満なら実測約2秒との差が3秒あり安定する。
reset_stub_state
echo 8 > "$STUB_STATE/slow_read_screen_secs"
touch "$STUB_STATE/never_prompt"
start_ts="$(date +%s)"
SH_WAIT=2 SH_GRACE=0 SH_GAP=0 SH_CALL_TIMEOUT=5 run_target "$NOTE" "続きの依頼T6c" >/dev/null 2>/dev/null
rc_t6c=$?
end_ts="$(date +%s)"
elapsed_t6c=$(( end_ts - start_ts ))
assert_eq "T6c: exit3" "3" "$rc_t6c"
assert_true "T6c: 所要時間が5秒未満（WAIT_SECの残り時間で呼出しタイムアウトを絞る。8秒スタブが最後まで走れば8秒超になるはず）" \
  "$([ "$elapsed_t6c" -lt 5 ] && echo 1 || echo 0)"

echo "--- T6補強: TERMを無視する子孫がいてもタイムアウト後に生存しない（検証3巡目 #2） ---"
reset_stub_state
touch "$STUB_STATE/spawn_term_ignoring_grandchild"
SH_WAIT=1 SH_GRACE=0 SH_GAP=0 SH_CALL_TIMEOUT=1 run_target "$NOTE" "続きの依頼T6d" >/dev/null 2>/dev/null
rc_t6d=$?
assert_eq "T6d: exit3" "3" "$rc_t6d"
sleep 0.5
grandchild_pid="$(cat "$STUB_STATE/term_ignoring_grandchild_pid" 2>/dev/null)"
assert_true "T6d: 子孫PIDが記録されている（検査自体が空振りでない）" "$([ -n "$grandchild_pid" ] && echo 1 || echo 0)"
if [ -n "$grandchild_pid" ] && kill -0 "$grandchild_pid" 2>/dev/null; then
  kill -9 "$grandchild_pid" 2>/dev/null
  assert_eq "T6d: exit3後にTERM無視の子孫PIDが生存しない" "生存しない" "生存した"
else
  assert_eq "T6d: exit3後にTERM無視の子孫PIDが生存しない" "生存しない" "生存しない"
fi

# ==========================================================================
# T7: new-workspace が失敗／出力にworkspace:Nが無い → exit2・
#     read-screen以降なし
# ==========================================================================
echo "=== T7: new-workspace の失敗 ==="

reset_stub_state
touch "$STUB_STATE/fail_new_workspace"
run_target "$NOTE" "続きの依頼T7a" >/dev/null 2>/dev/null
assert_eq "T7a: new-workspace非0終了でexit2" "2" "$?"
subcmds_t7a="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
assert_eq "T7a: 呼び出しはnew-workspaceのみ" "new-workspace" "$subcmds_t7a"

reset_stub_state
touch "$STUB_STATE/no_ref_new_workspace"
run_target "$NOTE" "続きの依頼T7b" >/dev/null 2>/dev/null
assert_eq "T7b: workspace:N不在でexit2" "2" "$?"
subcmds_t7b="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
assert_eq "T7b: 呼び出しはnew-workspaceのみ" "new-workspace" "$subcmds_t7b"

echo "--- T7補強: REF形式違反（garbage行・複数REF行）でexit2 ---"
reset_stub_state
touch "$STUB_STATE/garbage_new_workspace"
run_target "$NOTE" "続きの依頼T7c" >/dev/null 2>/dev/null
assert_eq "T7c: garbage行（完全一致しない）でexit2" "2" "$?"
subcmds_t7c="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
assert_eq "T7c: 呼び出しはnew-workspaceのみ" "new-workspace" "$subcmds_t7c"

reset_stub_state
touch "$STUB_STATE/multi_ref_new_workspace"
run_target "$NOTE" "続きの依頼T7d" >/dev/null 2>/dev/null
assert_eq "T7d: 複数REF行でexit2" "2" "$?"
subcmds_t7d="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
assert_eq "T7d: 呼び出しはnew-workspaceのみ" "new-workspace" "$subcmds_t7d"

# ==========================================================================
# T7補強: read-screenの一時失敗（非0終了）は無視して次回のプロンプト検出
# を続ける（検証1巡目 #4）。❯が行頭でない画面は送らない（検証1巡目 #3）。
# ==========================================================================
echo "--- T7補強: read-screenの一時失敗を無視して次回の❯で送る ---"
reset_stub_state
echo 2 > "$STUB_STATE/read_screen_fail_count"
echo 1 > "$STUB_STATE/prompt_at_call"
SH_WAIT=5 SH_GRACE=0 SH_GAP=0 run_target "$NOTE" "続きの依頼T7e" >/dev/null
assert_eq "T7e: exit0（一時失敗2回のあと3回目で送信）" "0" "$?"
subcmds_t7e="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
read_count_t7e="$(printf '%s\n' "$subcmds_t7e" | grep -cx 'read-screen' || true)"
assert_eq "T7e: read-screenが3回呼ばれる（失敗2回＋成功1回）" "3" "$read_count_t7e"
send_count_t7e="$(printf '%s\n' "$subcmds_t7e" | grep -cx 'send' || true)"
assert_eq "T7e: sendが呼ばれる（一時失敗だけでは諦めない）" "1" "$send_count_t7e"

echo "--- T7補強: read-screenが常に失敗→タイムアウトでexit3・send/send-key呼ばれない ---"
reset_stub_state
touch "$STUB_STATE/fail_read_screen"
err_t7f="$WORKDIR/t7f.stderr"
SH_WAIT=2 SH_GRACE=0 SH_GAP=0 run_target "$NOTE" "続きの依頼T7f" >/dev/null 2>"$err_t7f"
assert_eq "T7f: exit3" "3" "$?"
subcmds_t7f="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
sendish_t7f="$(printf '%s\n' "$subcmds_t7f" | grep -cx 'send\|send-key' || true)"
assert_eq "T7f: send/send-keyが呼ばれない" "0" "$sendish_t7f"
assert_contains "T7f: stderrにREFを含む" "$(cat "$err_t7f")" "workspace:4"

echo "--- T7補強: ❯が行頭でない画面では送らない（タイムアウトでexit3） ---"
reset_stub_state
touch "$STUB_STATE/prompt_not_at_line_start"
SH_WAIT=1 SH_GRACE=0 SH_GAP=0 run_target "$NOTE" "続きの依頼T7g" >/dev/null 2>/dev/null
assert_eq "T7g: 行頭でない❯では送信されずexit3" "3" "$?"
subcmds_t7g="$(awk '{print $2}' "$STUB_STATE/calls.log" | sed 's/^\[//;s/\]$//')"
sendish_t7g="$(printf '%s\n' "$subcmds_t7g" | grep -cx 'send\|send-key' || true)"
assert_eq "T7g: send/send-keyが呼ばれない" "0" "$sendish_t7g"

# ==========================================================================
# T8: --name/--cwd省略時の既定値がnew-workspace引数に出る
# ==========================================================================
echo "=== T8: --name/--cwd の既定値 ==="
reset_stub_state
default_cwd="$WORKDIR/t8-default-cwd"
mkdir -p "$default_cwd"
expected_default_cwd="$(cd -P "$default_cwd" && pwd)"
out="$( (cd "$default_cwd" && \
  SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" \
  SESSION_HANDOFF_WAIT_SEC=0 SESSION_HANDOFF_GRACE_SEC=0 SESSION_HANDOFF_SEND_GAP_SEC=0 \
  bash "$TARGET" "$NOTE" "続きの依頼T8") )"
rc=$?
assert_eq "T8: exit0" "0" "$rc"
first_line_t8="$(sed -n '1p' "$STUB_STATE/calls.log")"
assert_contains "T8: --nameの既定値が「引き継ぎ resume」" "$first_line_t8" "[引き継ぎ resume]"
assert_contains "T8: --cwdの既定値が呼び出し時のPWD" "$first_line_t8" "[$expected_default_cwd]"

# ==========================================================================
# T9: send-keyが失敗 → exit4・stderrにREF
# ==========================================================================
echo "=== T9: send-keyの失敗 ==="
reset_stub_state
touch "$STUB_STATE/fail_send_key"
err_file_t9="$WORKDIR/t9.stderr"
run_target "$NOTE" "続きの依頼T9" >/dev/null 2>"$err_file_t9"
assert_eq "T9: exit4" "4" "$?"
assert_contains "T9: stderrにREFを含む" "$(cat "$err_file_t9")" "workspace:4"

# ==========================================================================
# T9補強: 待ち秒数3つが非負整数以外だとexit1・cmux未呼出（検証1巡目 #5）
# ==========================================================================
echo "=== T9補強: 待ち秒数の検証 ==="
reset_stub_state
SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" SESSION_HANDOFF_WAIT_SEC="not-a-number" \
  SESSION_HANDOFF_GRACE_SEC=0 SESSION_HANDOFF_SEND_GAP_SEC=0 \
  bash "$TARGET" "$NOTE" "続きの依頼T9a" >/dev/null 2>&1
assert_eq "T9a: WAIT_SECが非整数でexit1" "1" "$?"
assert_true "T9a: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" SESSION_HANDOFF_WAIT_SEC=0 \
  SESSION_HANDOFF_GRACE_SEC="not-a-number" SESSION_HANDOFF_SEND_GAP_SEC=0 \
  bash "$TARGET" "$NOTE" "続きの依頼T9b" >/dev/null 2>&1
assert_eq "T9b: GRACE_SECが非整数でexit1" "1" "$?"
assert_true "T9b: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" SESSION_HANDOFF_WAIT_SEC=0 \
  SESSION_HANDOFF_GRACE_SEC=0 SESSION_HANDOFF_SEND_GAP_SEC="-1" \
  bash "$TARGET" "$NOTE" "続きの依頼T9c" >/dev/null 2>&1
assert_eq "T9c: SEND_GAP_SECが負値でexit1" "1" "$?"
assert_true "T9c: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

reset_stub_state
SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" SESSION_HANDOFF_WAIT_SEC=0 \
  SESSION_HANDOFF_GRACE_SEC=0 SESSION_HANDOFF_SEND_GAP_SEC=0 \
  SESSION_HANDOFF_CALL_TIMEOUT_SEC="not-a-number" \
  bash "$TARGET" "$NOTE" "続きの依頼T9d" >/dev/null 2>&1
assert_eq "T9d: CALL_TIMEOUT_SECが非整数でexit1" "1" "$?"
assert_true "T9d: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

# 検証3巡目 #3: CALL_TIMEOUT_SECは他の3つと違い0も拒否する（1以上のみ）。
reset_stub_state
SESSION_HANDOFF_CMUX_BIN="$STUBBIN/cmux" SESSION_HANDOFF_WAIT_SEC=0 \
  SESSION_HANDOFF_GRACE_SEC=0 SESSION_HANDOFF_SEND_GAP_SEC=0 \
  SESSION_HANDOFF_CALL_TIMEOUT_SEC=0 \
  bash "$TARGET" "$NOTE" "続きの依頼T9e" >/dev/null 2>&1
assert_eq "T9e: CALL_TIMEOUT_SEC=0でもexit1（他3変数と違い0は拒否）" "1" "$?"
assert_true "T9e: calls.logが空" "$(calls_log_is_empty && echo 1 || echo 0)"

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
exit $?
