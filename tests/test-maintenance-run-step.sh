#!/usr/bin/env bash
# scripts/vault-agents/maintenance_run_step.py のユニットテスト（maintenance.sh
# Phase1の各検出ステップ起動用・タイムアウト+プロセスグループ単位kill・
# 設計書§1.2）。
#
# 実行方法: bash tests/test-maintenance-run-step.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/maintenance_run_step.py"

# 全テスト共通の一時ディレクトリ（並列実行時の固定/tmpパス衝突を避ける・
# Codexレビュー指摘Minor対応）。
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}

run_step() { python3 "$SCRIPT" "$@"; }

echo "=== 1. 通常終了: 子プロセスの終了コードがそのまま返る ==="
{
  run_step --timeout 5 -- python3 -c "import sys; sys.exit(3)"
  rc=$?
  assert_eq "終了コード3がそのまま伝播する" "3" "$rc"
}

echo "=== 2. 通常終了: 子プロセスの標準出力・標準エラーがそのまま継承される(素通し) ==="
{
  ERRLOG="$TMPROOT/t2-stderr.log"
  out="$(run_step --timeout 5 -- python3 -c "print('stdout-line'); import sys; print('stderr-line', file=sys.stderr)" 2>"$ERRLOG")"
  err="$(cat "$ERRLOG")"
  assert_eq "標準出力が加工されずそのまま出る" "stdout-line" "$out"
  assert_contains "標準エラーもそのまま出る" "$err" "stderr-line"
}

echo "=== 3. タイムアウト: 終了コード124が返る(GNU coreutils timeout(1)の慣習) ==="
{
  start=$(date +%s)
  run_step --timeout 1 -- python3 -c "import time; time.sleep(60)"
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  assert_eq "タイムアウト時は終了コード124" "124" "$rc"
  if (( elapsed <= 10 )); then
    pass "タイムアウト秒数付近で戻る(60秒丸々待たない・elapsed=${elapsed}s)"
  else
    fail_case "タイムアウトが機能せず長時間待ってしまった(elapsed=${elapsed}s)"
  fi
}

echo "=== 4. タイムアウト: 直接の子だけでなくプロセスグループ全体(孫プロセス含む)がSIGKILLされる(設計書§1.2の主眼) ==="
{
  SPAWN_DIR="$TMPROOT/t4"
  mkdir -p "$SPAWN_DIR"
  cat > "$SPAWN_DIR/spawn.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60 &
echo $! > "$PIDFILE"
sleep 60
EOF
  chmod +x "$SPAWN_DIR/spawn.sh"
  PIDFILE="$SPAWN_DIR/child.pid"
  export PIDFILE
  run_step --timeout 1 -- bash "$SPAWN_DIR/spawn.sh"
  rc=$?
  unset PIDFILE
  assert_eq "spawn.sh自体もタイムアウトで終了コード124" "124" "$rc"
  sleep 0.3
  grandchild_pid="$(cat "$SPAWN_DIR/child.pid" 2>/dev/null || true)"
  if [[ -n "$grandchild_pid" ]] && kill -0 "$grandchild_pid" 2>/dev/null; then
    fail_case "孫プロセス(バックグラウンドsleep)が生き残っている(プロセスグループkillが機能していない)"
    kill -9 "$grandchild_pid" 2>/dev/null || true  # テスト環境を汚さないための後始末
  else
    pass "孫プロセス(バックグラウンドsleep)もプロセスグループごと終了している"
  fi
}

echo "=== 5. タイムアウトメッセージが標準エラーへ出る(タイムアウトと通常の異常終了を区別できる) ==="
{
  err="$(run_step --timeout 1 -- python3 -c "import time; time.sleep(60)" 2>&1 1>/dev/null)"
  assert_contains "タイムアウトメッセージが出る" "$err" "タイムアウト"
  assert_contains "コマンド内容もメッセージに含まれる" "$err" "python3"
}

echo "=== 6. 使い方エラー: '--'指定漏れは終了コード2でコマンドを起動しない ==="
{
  MARKER="$TMPROOT/t6-marker"
  run_step --timeout 5 python3 -c "open('$MARKER', 'w').close()" >/dev/null 2>&1
  rc=$?
  assert_eq "'--'指定漏れは終了コード2" "2" "$rc"
  if [[ -f "$MARKER" ]]; then
    fail_case "'--'指定漏れなのにコマンドが実行されてしまった"
  else
    pass "'--'指定漏れの場合コマンドは起動されない"
  fi
}

echo "=== 7. 使い方エラー: '--'の後にコマンドが無い場合も終了コード2 ==="
{
  run_step --timeout 5 -- >/dev/null 2>&1
  rc=$?
  assert_eq "コマンド未指定は終了コード2" "2" "$rc"
}

echo "=== 8. 使い方エラー: --timeoutが0以下/NaN/inf/-infなら終了コード2でコマンドを起動しない ==="
{
  all_clear=1
  for case in "0:$TMPROOT/t8-zero" "-5:$TMPROOT/t8-neg" "nan:$TMPROOT/t8-nan" "inf:$TMPROOT/t8-inf" "-inf:$TMPROOT/t8-ninf"; do
    val="${case%%:*}"
    marker="${case#*:}"
    run_step --timeout "$val" -- python3 -c "open('$marker', 'w').close()" >/dev/null 2>&1
    rc=$?
    assert_eq "--timeout $val は終了コード2" "2" "$rc"
    if [[ -f "$marker" ]]; then
      all_clear=0
      fail_case "--timeout $val なのにコマンドが実行されてしまった"
    fi
  done
  if [[ "$all_clear" -eq 1 ]]; then
    pass "不正な--timeout(0/負値/nan/inf/-inf)はいずれもコマンドを起動しない"
  fi
}

echo "=== 9. --timeoutは'--'より前・コマンド自身の引数と混同しない ==="
{
  out="$(run_step --timeout 5 -- python3 -c "import sys; print(len(sys.argv)); print(sys.argv[1:])" --timeout fake-arg-for-child)"
  assert_contains "子プロセス自身の--timeout風の引数はそのままargvへ渡る(自スクリプトのargparseに奪われない)" "$out" "['--timeout', 'fake-arg-for-child']"
}

echo "=== 10. 存在しないコマンド: 終了コード127でエラーメッセージが出る ==="
{
  ERRLOG="$TMPROOT/t10-stderr.log"
  run_step --timeout 5 -- /nonexistent/command/that/should/not/exist-xyz >/dev/null 2>"$ERRLOG"
  rc=$?
  err="$(cat "$ERRLOG")"
  assert_eq "存在しないコマンドは終了コード127" "127" "$rc"
  assert_contains "エラーメッセージが出る" "$err" "エラー"
}

echo "=== 11. 実行権限が無いファイル: OSError全般を捕捉して終了コード127になる(FileNotFoundError限定ではない・Codexレビュー指摘Minor対応) ==="
{
  NOEXEC="$TMPROOT/t11-noexec.sh"
  printf '#!/usr/bin/env bash\necho should-not-run\n' > "$NOEXEC"
  chmod 000 "$NOEXEC"
  if [[ "$(id -u)" == "0" ]]; then
    pass "root実行のためpermission検証はskip"
  else
    run_step --timeout 5 -- "$NOEXEC" >/dev/null 2>/dev/null
    rc=$?
    assert_eq "実行権限が無いファイルも終了コード127" "127" "$rc"
  fi
  chmod 700 "$NOEXEC"
}

echo "=== 12. シグナル終了した子プロセスの終了コードはbashの慣習(128+シグナル番号)へ正規化される(Codexレビュー指摘Minor対応) ==="
{
  # このテストは、親側のpthread_sigmask一時ブロック(SIGTERM/SIGHUP/SIGINT)を
  # 子プロセスがfork/exec経由でそのまま継承してしまい、子が自分自身へ送った
  # SIGTERMが子自身にも配送されなくなる回帰を実際に検出した（Codex 4巡目
  # レビュー対応でpreexec_fnによるマスク解除を追加して修正済み）。
  run_step --timeout 5 -- python3 -c "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"
  rc=$?
  assert_eq "SIGTERM(15)で自殺した子は終了コード143(=128+15)になる" "143" "$rc"
}

echo "=== 13. --status-file: 通常終了時の内容が正しい ==="
{
  STATUS="$TMPROOT/t13-status.json"
  run_step --timeout 5 --status-file "$STATUS" -- python3 -c "import sys; sys.exit(0)"
  rc=$?
  ok="$(python3 -c "import json; print(json.load(open('$STATUS'))['ok'])")"
  timed_out="$(python3 -c "import json; print(json.load(open('$STATUS'))['timed_out'])")"
  assert_eq "終了コード0" "0" "$rc"
  assert_eq "status-fileのok=True" "True" "$ok"
  assert_eq "status-fileのtimed_out=False" "False" "$timed_out"
}

echo "=== 14. --status-file: タイムアウト時にtimed_out=Trueが記録される ==="
{
  STATUS="$TMPROOT/t14-status.json"
  run_step --timeout 1 --status-file "$STATUS" -- python3 -c "import time; time.sleep(60)" 2>/dev/null
  timed_out="$(python3 -c "import json; print(json.load(open('$STATUS'))['timed_out'])")"
  ok="$(python3 -c "import json; print(json.load(open('$STATUS'))['ok'])")"
  assert_eq "status-fileのtimed_out=True" "True" "$timed_out"
  assert_eq "status-fileのok=False" "False" "$ok"
}

echo "=== 15. --status-file: 子プロセス自身が終了コード124/127/2を返しても、status-fileでラッパー状態と区別できる(Codexレビュー指摘Major対応の核心) ==="
{
  STATUS="$TMPROOT/t15-status.json"
  run_step --timeout 5 --status-file "$STATUS" -- python3 -c "import sys; sys.exit(124)"
  rc=$?
  timed_out="$(python3 -c "import json; print(json.load(open('$STATUS'))['timed_out'])")"
  returncode="$(python3 -c "import json; print(json.load(open('$STATUS'))['returncode'])")"
  assert_eq "終了コード自体は子の124がそのまま伝播する" "124" "$rc"
  assert_eq "status-fileのreturncodeも124" "124" "$returncode"
  assert_eq "しかしtimed_out=Falseで『本物のタイムアウトではない』と判別できる" "False" "$timed_out"
}

echo "=== 15b. --status-file: spawn_error/usage_errorも子の終了コードと独立して正しく記録される ==="
{
  STATUS_SPAWN="$TMPROOT/t15b-spawn.json"
  run_step --timeout 5 --status-file "$STATUS_SPAWN" -- /nonexistent/command-xyz >/dev/null 2>/dev/null
  rc_spawn=$?
  spawn_error="$(python3 -c "import json; print(json.load(open('$STATUS_SPAWN'))['spawn_error'])")"
  assert_eq "起動失敗の終了コードは127" "127" "$rc_spawn"
  assert_eq "status-fileのspawn_error=True" "True" "$spawn_error"

  STATUS_USAGE="$TMPROOT/t15b-usage.json"
  run_step --timeout 5 --status-file "$STATUS_USAGE" -- >/dev/null 2>/dev/null
  rc_usage=$?
  usage_error="$(python3 -c "import json; print(json.load(open('$STATUS_USAGE'))['usage_error'])")"
  assert_eq "コマンド未指定の終了コードは2" "2" "$rc_usage"
  assert_eq "status-fileのusage_error=True" "True" "$usage_error"
}

echo "=== 15c. --status-file: 前回実行分の残骸(stale content)は今回の実行開始時に消され、古い内容を誤読しない(Codex 4巡目レビュー指摘Major対応) ==="
{
  STATUS_STALE="$TMPROOT/t15c-stale.json"
  echo '{"returncode": 0, "timed_out": false, "spawn_error": false, "usage_error": false, "ok": true, "note": "stale-from-previous-run"}' > "$STATUS_STALE"
  # 今回は--timeoutが不正な使い方エラー。status-fileの値自体は既に確定して
  # いる(own_argsの解析には成功している)ため、旧内容を消してusage_error記録に
  # 差し替えられるはず。
  run_step --timeout -1 --status-file "$STATUS_STALE" -- true >/dev/null 2>/dev/null
  rc=$?
  content="$(cat "$STATUS_STALE")"
  assert_eq "使い方エラーの終了コードは2" "2" "$rc"
  assert_contains "旧内容(stale-from-previous-run)は残っていない" "$content" "\"usage_error\": true"
  if [[ "$content" == *"stale-from-previous-run"* ]]; then
    fail_case "前回実行分の残骸が消えずに残ってしまった"
  else
    pass "前回実行分の残骸は消えて今回の内容に差し替わっている"
  fi
}

echo "=== 16. SIGTERM: ラッパー自身がSIGTERMを受けても子プロセスグループ(孫プロセス含む)を道連れにする(Codexレビュー指摘Major対応) ==="
{
  SPAWN_DIR="$TMPROOT/t16"
  mkdir -p "$SPAWN_DIR"
  cat > "$SPAWN_DIR/spawn.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60 &
echo $! > "$PIDFILE"
sleep 60
EOF
  chmod +x "$SPAWN_DIR/spawn.sh"
  PIDFILE="$SPAWN_DIR/child.pid"
  export PIDFILE
  # run_step()関数越しに`&`でバックグラウンド起動すると、bashが関数呼び出し用に
  # 挟む中間bashプロセスの方が$!になり、そちらがSIGTERMを（トラップ無しの既定
  # 動作で）即座に受けて死んでしまい、python3本体には信号が届かない
  # （実運用のmaintenance.shは`python3 maintenance_run_step.py ...`を関数越し
  # なく直接呼ぶため問題にならない）。本テストではpython3を直接バックグラウンド
  # 起動し、確実にラッパー本体がSIGTERMを受け取るようにする。
  python3 "$SCRIPT" --timeout 30 -- bash "$SPAWN_DIR/spawn.sh" &
  wrapper_pid=$!
  sleep 0.5
  kill -TERM "$wrapper_pid"
  wait "$wrapper_pid"
  wrapper_rc=$?
  unset PIDFILE
  assert_eq "ラッパー自身もSIGTERMで終了コード143になる" "143" "$wrapper_rc"
  sleep 0.3
  grandchild_pid="$(cat "$SPAWN_DIR/child.pid" 2>/dev/null || true)"
  if [[ -n "$grandchild_pid" ]] && kill -0 "$grandchild_pid" 2>/dev/null; then
    fail_case "ラッパーへのSIGTERM後も孫プロセスが生き残っている"
    kill -9 "$grandchild_pid" 2>/dev/null || true
  else
    pass "ラッパーへのSIGTERM転送で孫プロセスも道連れに終了する"
  fi
}

echo "=== 17. SIGINT: マスク解除(pthread_sigmask SIG_SETMASK)直後というピンポイントのタイミングで送っても、except KeyboardInterruptで確実に子プロセスグループがkillされる(Codex 5巡目レビュー指摘Major対応の決定性確認) ==="
{
  # bashレベルでの「起動直後にkill -TERM」はPython起動そのもの(数十ms)に
  # 埋もれてしまい、狙った競合区間（run_step()内のマスク解除処理）を確実には
  # 踏めない（2026-07-16 Codex 6巡目レビュー指摘Minor: 前バージョンのテストは
  # 「孫プロセスが一度も起動できていない」ケースをそのまま成功扱いしており、
  # 競合区間を実際には検証できていなかった）。
  # ここではPython内部でsignal.pthread_sigmaskをフックし、run_step()内で
  # SIG_SETMASK(マスク解除)が実際に呼ばれた直後にだけSIGINTを送る。
  # sigprocmask自体はOSレベルで原子的な操作のため「解除の最中」という状態は
  # 存在せず、「解除完了直後」に送ることが、この競合を再現する上で意味のある
  # 最も厳しいタイミングになる。
  # 別スレッドは使わない（2026-07-16 Codex 7巡目レビュー指摘Minor対応:
  # run_step()はPopen(preexec_fn=...)を使うため、fork時に他スレッドが動いて
  # いるとPython公式ドキュメントが警告するデッドロック条件そのものを
  # テスト側で作ってしまっていた。同一スレッド内でマスク解除呼び出しの
  # 直後に同期的にos.kill()する形へ変更し、この危険条件を作らないようにした）。
  # 注意: preexec_fn(_make_child_sigmask_restorer)もfork後の子プロセス側で
  # signal.pthread_sigmask(SIG_SETMASK, ...)を呼ぶため、モンキーパッチした
  # 関数オブジェクトはfork()でそのまま子へも継承される。os.getpid()で
  # 「この呼び出しは親(このテストプロセス)自身のものか」を判定するガードを
  # 入れないと、子プロセス側（execで置き換わる直前の一瞬）でも誤って自分自身へ
  # SIGINTを送ってしまい、Popen()自体を壊してしまう（実際に一度この不具合を
  # 作り込み、proc_holderが空になる形で症状が出たため、実測して発見・修正した）。
  out="$(python3 -c "
import sys, signal, os
sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import maintenance_run_step as mrs

real_pthread_sigmask = signal.pthread_sigmask
fired = {'done': False}
main_pid = os.getpid()

def patched(how, mask):
    result = real_pthread_sigmask(how, mask)
    if how == signal.SIG_SETMASK and not fired['done'] and os.getpid() == main_pid:
        fired['done'] = True
        os.kill(os.getpid(), signal.SIGINT)
    return result

signal.pthread_sigmask = patched

proc_holder = {}
orig_popen = mrs.subprocess.Popen
def spy_popen(*a, **kw):
    p = orig_popen(*a, **kw)
    proc_holder['proc'] = p
    return p
mrs.subprocess.Popen = spy_popen

try:
    mrs.run_step(['python3', '-c', 'import time; time.sleep(30)'], timeout=30)
    print('NO_INTERRUPT_RAISED')
except KeyboardInterrupt:
    print('INTERRUPT_CAUGHT')
    p = proc_holder.get('proc')
    if p is not None:
        p.wait(timeout=5)
        print('CHILD_REAPED', p.poll())
")"
  assert_contains "マスク解除直後のSIGINTはKeyboardInterruptとして送出され、except節に捕捉される" "$out" "INTERRUPT_CAUGHT"
  assert_contains "捕捉後に子プロセスが確実にkillpg+wait()で回収されている" "$out" "CHILD_REAPED"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
