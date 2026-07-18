#!/usr/bin/env bash
# scripts/lib/ 配下の共有シェルライブラリのユニットテスト（2026-07-16簡素化・
# cleanup決定#10・PR1.5③）。
#
# pid-lock.sh（多重起動防止ロック）の挙動不変（noclobber原子取得・ABA対策の
# 回収ミューテックス・並行プロセスでの排他制御）は、抽出元の
# tests/test-backup-vault.sh（45件・並行プロセスによる排他制御の実地回帰テストを
# 含む）で確認済み。本ファイルではさらに、関数化に伴い新設したtrap構築方式
# （グローバル変数＋名前付きクリーンアップ関数によるtrap合成）固有の観点を追加で
# 検証する。status-file.sh・macos-notify.shは全面的に本ファイルが対象。
#
# 実行方法: bash tests/test-shell-lib.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/scripts/lib"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

echo "=== 1. status-file.sh: write_status_file → read_status_file で書いた値をそのまま読める ==="
{
  source "$LIB_DIR/status-file.sh"
  F="$(mktemp -u)"
  write_status_file "$F" "completed"
  out="$(read_status_file "$F")"
  assert_eq "completedが読める" "completed" "$out"
  rm -f "$F"
}

echo "=== 2. status-file.sh: write_status_fileはディレクトリが無ければ作成する ==="
{
  source "$LIB_DIR/status-file.sh"
  D="$(mktemp -d)"
  F="$D/nested/status.txt"
  write_status_file "$F" "busy"
  out="$(read_status_file "$F")"
  assert_eq "ネストしたディレクトリも自動作成されて読み書きできる" "busy" "$out"
  rm -rf "$D"
}

echo "=== 3. status-file.sh: read_status_fileはファイルが無ければ missing を返しexit code 1 ==="
{
  source "$LIB_DIR/status-file.sh"
  rc=0
  out="$(read_status_file "/nonexistent-status-file-$$.txt")" || rc=$?
  assert_eq "missing が返る" "missing" "$out"
  assert_eq "exit code 1" "1" "$rc"
}

echo "=== 4. status-file.sh: read_status_fileはファイルが空でも missing を返す ==="
{
  source "$LIB_DIR/status-file.sh"
  F="$(mktemp)"
  : > "$F"
  rc=0
  out="$(read_status_file "$F")" || rc=$?
  assert_eq "空ファイルは missing 扱い" "missing" "$out"
  assert_eq "exit code 1" "1" "$rc"
  rm -f "$F"
}

echo "=== 5. status-file.sh: 4種の状態語(completed/no-change/busy/error)を正しく往復できる ==="
{
  source "$LIB_DIR/status-file.sh"
  for status in completed no-change busy error; do
    F="$(mktemp -u)"
    write_status_file "$F" "$status"
    out="$(read_status_file "$F")"
    assert_eq "状態語「${status}」が往復する" "$status" "$out"
    rm -f "$F"
  done
}

echo "=== 5b. status-file.sh: write_status_fileは不正な状態語を拒否しWARNを出すが常にexit 0(真のfail-open・Codex一次レビュー指摘・Minor対応) ==="
{
  source "$LIB_DIR/status-file.sh"
  F="$(mktemp -u)"
  rc=0
  err="$(write_status_file "$F" "not-a-valid-status" 2>&1)" || rc=$?
  assert_eq "exit code 0（set -e下でも呼び出し元を止めない）" "0" "$rc"
  [[ "$err" == *"不正な状態語"* ]] && pass "不正な状態語のWARNが出る" || fail_case "不正な状態語のWARNが出る (実際: $err)"
  assert_eq "不正な値ではファイルが書かれない" "0" "$([ -e "$F" ] && echo 1 || echo 0)"
}

echo "=== 5c. status-file.sh: read_status_fileはファイル内容が4状態語以外なら missing 扱い(不正値の透過を防ぐ) ==="
{
  source "$LIB_DIR/status-file.sh"
  F="$(mktemp)"
  printf 'garbage-value\n' > "$F"
  rc=0
  out="$(read_status_file "$F")" || rc=$?
  assert_eq "missing が返る" "missing" "$out"
  assert_eq "exit code 1" "1" "$rc"
  rm -f "$F"
}

echo "=== 6. macos-notify.sh: osascriptが無い環境ではexit code 2でWARNを出す(fail-open) ==="
{
  source "$LIB_DIR/macos-notify.sh"
  BINDIR="$(mktemp -d)"
  for t in echo; do
    p="$(command -v "$t")"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$t"
  done
  rc=0
  err="$(PATH="$BINDIR" notify_macos "タイトル" "本文" 2>&1)" || rc=$?
  assert_eq "exit code 2" "2" "$rc"
  [[ "$err" == *"osascript が見つかりません"* ]] && pass "見つからない旨のWARNが出る" || fail_case "見つからない旨のWARNが出る (実際: $err)"
  rm -rf "$BINDIR"
}

echo "=== 7. macos-notify.sh: osascriptがあれば実際に呼び出しtitle/messageが渡る ==="
{
  source "$LIB_DIR/macos-notify.sh"
  BINDIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  cat > "$BINDIR/osascript" <<CALLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
exit 0
CALLEOF
  chmod +x "$BINDIR/osascript"
  rc=0
  PATH="$BINDIR:$PATH" notify_macos "テスト通知" "本文だよ" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  call_text="$(cat "$CALLS")"
  [[ "$call_text" == *"テスト通知"* ]] && pass "titleが渡る" || fail_case "titleが渡る (実際: $call_text)"
  [[ "$call_text" == *"本文だよ"* ]] && pass "messageが渡る" || fail_case "messageが渡る"
  rm -rf "$BINDIR" "$CALLS"
}

echo "=== 8. macos-notify.sh: title/message中のダブルクォート・バックスラッシュがエスケープされAppleScript文字列を壊さない ==="
{
  source "$LIB_DIR/macos-notify.sh"
  BINDIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  cat > "$BINDIR/osascript" <<CALLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
exit 0
CALLEOF
  chmod +x "$BINDIR/osascript"
  rc=0
  PATH="$BINDIR:$PATH" notify_macos '危険な"タイトル"' '本文\に"引用符"を含む' || rc=$?
  assert_eq "exit code 0（クォート混入でもクラッシュしない）" "0" "$rc"
  call_text="$(cat "$CALLS")"
  [[ "$call_text" == *'\"タイトル\"'* ]] && pass "ダブルクォートがエスケープされて渡る" || fail_case "ダブルクォートがエスケープされて渡る (実際: $call_text)"
  rm -rf "$BINDIR" "$CALLS"
}

echo "=== 9. macos-notify.sh: osascript自体が失敗(非0終了)したらexit code 1でWARNを出す ==="
{
  source "$LIB_DIR/macos-notify.sh"
  BINDIR="$(mktemp -d)"
  cat > "$BINDIR/osascript" <<'CALLEOF'
#!/bin/bash
exit 1
CALLEOF
  chmod +x "$BINDIR/osascript"
  rc=0
  err="$(PATH="$BINDIR:$PATH" notify_macos "タイトル" "本文" 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  [[ "$err" == *"通知に失敗しました"* ]] && pass "失敗の旨のWARNが出る" || fail_case "失敗の旨のWARNが出る (実際: $err)"
  rm -rf "$BINDIR"
}

echo "=== 10. pid-lock.sh: ロックファイルのパスにシングルクォートを含んでいても取得・解放できる（Codex一次レビュー指摘・Major対応: trap文字列への直接埋め込みからグローバル変数+名前付き関数方式への変更） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/lock'with-quote.lock"
  bash -c 'source "$1"; acquire_pid_lock "$2" 3600 "test"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "exit code 0（取得成功）" "0" "$rc"
  assert_eq "プロセス終了後にロックファイルが解放される" "0" "$([ -f "$LOCK" ] && echo 1 || echo 0)"
  rm -rf "$D"
}

echo "=== 11. pid-lock.sh: 呼び出し元が事前に設定していたEXIT trapを上書きせず合成する（Codex一次レビュー指摘・Major対応） ==="
{
  D="$(mktemp -d)"
  MARKER="$D/other-cleanup-ran"
  LOCK="$D/test.lock"
  bash -c '
    source "$1"
    trap "touch \"$2\"" EXIT
    acquire_pid_lock "$3" 3600 "test"
  ' _ "$LIB_DIR/pid-lock.sh" "$MARKER" "$LOCK"
  assert_eq "呼び出し元の既存trapも実行される" "1" "$([ -f "$MARKER" ] && echo 1 || echo 0)"
  assert_eq "ロックも解放される" "1" "$([ -f "$LOCK" ] && echo 0 || echo 1)"
  rm -rf "$D"
}

echo "=== 12. pid-lock.sh: 同一プロセス内で複数回acquire_pid_lockを呼んでも全ロックが解放される ==="
{
  D="$(mktemp -d)"
  LOCK1="$D/lock1.lock"
  LOCK2="$D/lock2.lock"
  bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test1"
    acquire_pid_lock "$3" 3600 "test2"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK1" "$LOCK2"
  assert_eq "1つ目のロックが解放される" "1" "$([ -f "$LOCK1" ] && echo 0 || echo 1)"
  assert_eq "2つ目のロックが解放される" "1" "$([ -f "$LOCK2" ] && echo 0 || echo 1)"
  rm -rf "$D"
}

echo "=== 13. pid-lock.sh: is_pid_lock_held は生存PIDが書かれていれば0(held)を返す ==="
{
  D="$(mktemp -d)"
  LOCK="$D/writer.lock"
  echo "$$" > "$LOCK"   # 自分自身のPID（確実に生存）
  bash -c 'source "$1"; is_pid_lock_held "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "生存PIDならexit 0(held)" "0" "$rc"
  rm -rf "$D"
}

echo "=== 14. pid-lock.sh: is_pid_lock_held はファイル無し/staleなPID/空なら1(not held)を返し、副作用も無い ==="
{
  D="$(mktemp -d)"
  LOCK="$D/writer.lock"
  # ファイル自体が無いケース。
  bash -c 'source "$1"; is_pid_lock_held "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc_missing=$?
  assert_eq "ファイル無しはexit 1(not held)" "1" "$rc_missing"

  echo "999999" > "$LOCK"   # 存在しないであろうPID
  bash -c 'source "$1"; is_pid_lock_held "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc_stale=$?
  assert_eq "staleなPIDはexit 1(not held)" "1" "$rc_stale"
  assert_eq "staleでもファイル自体は削除されない(読み取り専用)" "1" \
    "$([[ -e "$LOCK" ]] && echo 1 || echo 0)"

  : > "$LOCK"   # 空ファイル
  bash -c 'source "$1"; is_pid_lock_held "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc_empty=$?
  assert_eq "空ファイルはexit 1(not held)" "1" "$rc_empty"

  rm -rf "$D"
}

echo "=== 15. pid-lock.sh: acquire_pid_lockに4引数目でstatus_fileを渡すと、既に実行中(busy)時にbusyが書かれる ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STATUS="$D/status.txt"
  echo "$$" > "$LOCK"   # 自分自身のPID（確実に生存＝busy確定）
  bash -c '
    source "$1"
    source "$2"
    acquire_pid_lock "$3" 3600 "test" "$4"
  ' _ "$LIB_DIR/pid-lock.sh" "$LIB_DIR/status-file.sh" "$LOCK" "$STATUS"
  assert_eq "status-fileにbusyが書かれる" "busy" "$(cat "$STATUS" 2>/dev/null || echo MISSING)"
  rm -rf "$D"
}

echo "=== 16. pid-lock.sh: status-file.sh未sourceでもacquire_pid_lockの4引数目指定はエラーにならない(ダックタイピングの安全側フォールバック) ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STATUS="$D/status.txt"
  echo "$$" > "$LOCK"
  rc=0
  bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test" "$3"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" "$STATUS" || rc=$?
  assert_eq "status-file.sh未sourceでもexit 0のまま(busyのexit自体は変わらない)" "0" "$rc"
  assert_eq "write_status_file未定義のためstatus-fileは作られない" "0" \
    "$([[ -e "$STATUS" ]] && echo 1 || echo 0)"
  rm -rf "$D"
}

echo "=== 17. pid-lock.sh: acquire_pid_lock成功時（ロック取得できた側）はstatus_fileへ何も書かない(busy/errorの時だけ書く契約) ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STATUS="$D/status.txt"
  bash -c '
    source "$1"
    source "$2"
    acquire_pid_lock "$3" 3600 "test" "$4"
  ' _ "$LIB_DIR/pid-lock.sh" "$LIB_DIR/status-file.sh" "$LOCK" "$STATUS"
  assert_eq "取得成功時はstatus-fileが作られない(completedの判定は呼び出し元スクリプトの責務)" "0" \
    "$([[ -e "$STATUS" ]] && echo 1 || echo 0)"
  rm -rf "$D"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
