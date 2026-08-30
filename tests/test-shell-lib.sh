#!/usr/bin/env bash
# scripts/lib/ 配下の共有シェルライブラリのユニットテスト（2026-07-16簡素化・
# cleanup決定#10・PR1.5③）。
#
# pid-lock.sh（多重起動防止ロック）の挙動不変（ロックファイルの原子的な初期化＝
# 2026-08-30 PID再利用対策改修でnoclobberから同ディレクトリの一時ファイル＋
# `ln`公開方式へ変更・ABA対策の回収ミューテックス・並行プロセスでの排他制御）は、
# 抽出元の tests/test-backup-vault.sh（45件・並行プロセスによる排他制御の実地
# 回帰テストを含む）で確認済み。本ファイルではさらに、関数化に伴い新設したtrap
# 構築方式（グローバル変数＋名前付きクリーンアップ関数によるtrap合成）・
# 2026-08-30のPID再利用対策（指紋照合・原子的公開）固有の観点を追加で検証する。
# status-file.sh・macos-notify.shは全面的に本ファイルが対象。
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

echo "=== 12e. pid-lock.sh: EXIT trapのcleanupは所有権(PID+指紋)を再確認してからrmする（他プロセスに回収された後のロックを誤って削除しない・TOCTOU対応。2026-08-30 リーダー追補・tester独立検証指摘） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test"
    # 取得直後、自プロセスが終了する前に、このロックが既に別プロセスへ
    # 回収されていた状況をシミュレートする（内容を全く別のPID+指紋で
    # 上書きする）。無条件rmだと、この後のEXIT trapがこの他所有者のロック
    # を誤って削除してしまう。
    printf "999999\nFAKE-OTHER-OWNER-FINGERPRINT\n" > "$2"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  assert_eq "ロックファイルは削除されず残る（他所有者のロックを誤って削除していない）" "1" \
    "$([[ -f "$LOCK" ]] && echo 1 || echo 0)"
  assert_eq "ロックの中身(1行目PID)は他所有者のものがそのまま残っている" \
    "999999" "$(sed -n '1p' "$LOCK" 2>/dev/null)"
  assert_eq "ロックの中身(2行目指紋)も他所有者のものがそのまま残っている" \
    "FAKE-OTHER-OWNER-FINGERPRINT" "$(sed -n '2p' "$LOCK" 2>/dev/null)"
  rm -f "$LOCK"
  rm -rf "$D"
}

echo "=== 12f. pid-lock.sh: EXIT trapのcleanupは、PIDが一致していても指紋だけが不一致なら削除しない（12eはPID+指紋の両方を書き換えており指紋のみ不一致の分岐を通っていなかった・2026-08-30 Codex五次レビュー指摘・MAJOR対応） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test"
    # PID(1行目)は自分自身のままにし、指紋(2行目)だけを別の値へ書き換える
    # （PID一致・指紋不一致という単独の分岐を狙い撃ちする）。
    printf "%s\nFAKE-MISMATCHED-FINGERPRINT-ONLY\n" "$$" > "$2"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  assert_eq "ロックファイルは削除されず残る（PID一致でも指紋不一致なら誤って削除しない）" "1" \
    "$([[ -f "$LOCK" ]] && echo 1 || echo 0)"
  assert_eq "ロックの中身(2行目指紋)は書き換え後の値のまま残っている" \
    "FAKE-MISMATCHED-FINGERPRINT-ONLY" "$(sed -n '2p' "$LOCK" 2>/dev/null)"
  rm -f "$LOCK"
  rm -rf "$D"
}

echo "=== 12g. pid-lock.sh: EXIT trapのcleanupは、指紋が予約値(FINGERPRINT-UNAVAILABLE)の自己所有ロックならPID一致だけで正しく削除する（フォールバック経路自体が壊れていないことの直接確認・2026-08-30 Codex五次レビュー指摘・MAJOR対応の横展開） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/ps" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUBDIR/ps"
  # psが使えない状態でacquire_pid_lockし、指紋が予約値のまま自然に
  # プロセスが終了する（何も改ざんしない・正当な自己所有のまま解放される
  # ことを確認する）。
  PATH="$STUBDIR:$PATH" bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  assert_eq "指紋が予約値の自己所有ロックは正しく解放される(残らない)" "1" \
    "$([[ -f "$LOCK" ]] && echo 0 || echo 1)"
  rm -rf "$D" "$STUBDIR"
}

echo "=== 12h. pid-lock.sh: cleanup中にrmが失敗しても回収ミューテックス(.reclaim)は残置されず、プロセス全体はexit 0を維持する（2026-08-30 Codex六次レビュー指摘・MAJOR対応の回帰テスト: rm未ガードのままだとset -e下でrmdirへ到達せず.reclaimが残置され、以後このロックの取得がfail-closedで失敗し続ける事故になっていた） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/rm" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUBDIR/rm"
  rc=0
  PATH="$STUBDIR:$PATH" bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" || rc=$?
  assert_eq "rmが常に失敗する環境でもプロセス全体はexit 0で完走する" "0" "$rc"
  assert_eq "回収ミューテックス(.reclaim)は残置されない" "1" \
    "$([[ ! -d "${LOCK}.reclaim" ]] && echo 1 || echo 0)"
  # rmスタブの副作用でロックファイル自体は削除されずに残る想定どおり。
  # 実際のrm（PATHのstub外）で後始末する。
  rm -f "$LOCK"
  rm -rf "$D" "$STUBDIR"
}

echo "=== 12i. pid-lock.sh: _pid_lock_try_create()をif条件の外でbareに直接呼んだ場合でも、rm失敗時のガードにより処理が中断されない（2026-08-30 Codex六次レビュー指摘・Minor対応の回帰テスト: 現行の唯一の呼び出し経路〈if条件・AND-ORリスト〉ではerrexit免除が効くため実害はないが、将来の直接呼び出しや単体テストでの直接呼び出しに備えたガード自体を検証する） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/rm" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUBDIR/rm"
  out="$(PATH="$STUBDIR:$PATH" bash -c '
    set -e
    source "$1"
    _pid_lock_try_create "$2"
    echo REACHED_AFTER_DIRECT_CALL
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
  }
  assert_contains_local "if条件の外でbare呼び出ししてもrm失敗で中断されず後続処理まで到達する" "$out" "REACHED_AFTER_DIRECT_CALL"
  assert_eq "ln自体は成功しロックファイルが実際に作られている" "1" \
    "$([[ -f "$LOCK" ]] && echo 1 || echo 0)"
  rm -f "$LOCK"
  rm -rf "$D" "$STUBDIR"
}

echo "=== 12j. pid-lock.sh: stale解除中にrmが失敗し続けても回収ミューテックス(.reclaim)は残置されない（最終的にはfail-closedでexit 1になるが、後始末自体は正しく行われることを確認する・2026-08-30 Codex六次レビュー指摘・Minor対応の回帰テスト） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  echo "999999" > "$LOCK"   # 存在しないPID(旧形式・指紋なし)＝stale確定
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/rm" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUBDIR/rm"
  rc=0
  PATH="$STUBDIR:$PATH" bash -c '
    source "$1"
    acquire_pid_lock "$2" 3600 "test"
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" || rc=$?
  assert_eq "rmが壊れているとstale解除自体ができず最終的にexit 1(fail-closed)になる" "1" "$rc"
  assert_eq "それでも回収ミューテックス(.reclaim)は残置されない" "1" \
    "$([[ ! -d "${LOCK}.reclaim" ]] && echo 1 || echo 0)"
  rm -f "$LOCK"
  rm -rf "$D" "$STUBDIR"
}

echo "=== 12b. pid-lock.sh: _pid_lock_try_create()は公開後に一時ファイルを残さず、ロックファイルは常に2行とも揃った状態で存在する（2026-08-30 Codex三次レビュー指摘・BLOCKING対応: ln方式への変更確認。中身が空/片方の行だけのロックファイルが外から観測される窓が無いことの構造的な確認） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  rc=0
  bash -c 'source "$1"; _pid_lock_try_create "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "作成は成功する(rc=0)" "0" "$rc"
  n_hidden="$(find "$D" -maxdepth 1 -name '.pid-lock.*' | wc -l | tr -d ' ')"
  assert_eq "一時ファイル(.pid-lock.*)が残っていない" "0" "$n_hidden"
  n_lines="$(wc -l < "$LOCK" | tr -d ' ')"
  assert_eq "ロックファイルは常に2行揃った状態で存在する" "2" "$n_lines"
  assert_eq "1行目は空でない(PID)" "1" "$([[ -n "$(sed -n '1p' "$LOCK")" ]] && echo 1 || echo 0)"
  assert_eq "2行目は空でない(指紋または予約値)" "1" "$([[ -n "$(sed -n '2p' "$LOCK")" ]] && echo 1 || echo 0)"
  rm -rf "$D"
}

echo "=== 12c. pid-lock.sh: _pid_lock_try_create()はロックファイルが既に存在すれば失敗し、既存の内容を上書きしない(ln方式の排他性確認) ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  printf 'sentinel-content-line1\nsentinel-content-line2\n' > "$LOCK"
  rc=0
  bash -c 'source "$1"; _pid_lock_try_create "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "既存ファイルがあれば失敗する(rc=1)" "1" "$rc"
  assert_eq "既存の内容が上書きされていない" "sentinel-content-line1" "$(sed -n '1p' "$LOCK")"
  rm -rf "$D"
}

echo "=== 12d. pid-lock.sh: 一時ファイルへの書込み自体が失敗すればlnせず失敗を返し、一時ファイルも残さない（2026-08-30 Codex四次レビュー指摘・BLOCKING対応: 書込み結果を確認せずlnしていると空/部分的な一時ファイルを公開してしまう回帰テスト） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STUBDIR="$(mktemp -d)"
  # 実際のmktempで一時ファイルを作った直後にchmod 000（書込み不可）にする
  # スタブ。後続のprintf > $tmpfileが必ず失敗する状況を再現する。
  cat > "$STUBDIR/mktemp" <<'EOF'
#!/bin/sh
f="$(/usr/bin/mktemp "$@")" || exit 1
chmod 000 "$f"
echo "$f"
EOF
  chmod +x "$STUBDIR/mktemp"
  rc=0
  PATH="$STUBDIR:$PATH" bash -c 'source "$1"; _pid_lock_try_create "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "一時ファイルへの書込み失敗はexit 1になる(lnしない)" "1" "$rc"
  assert_eq "書込み失敗時はロックファイル自体が作られない" "0" \
    "$([[ -e "$LOCK" ]] && echo 1 || echo 0)"
  n_hidden="$(find "$D" -mindepth 1 -maxdepth 1 -name '.pid-lock.*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "書込み不可の一時ファイルも残さず削除される" "0" "$n_hidden"
  rm -rf "$D" "$STUBDIR"
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

echo "=== 14b. pid-lock.sh: is_pid_lock_held は指紋が一致していれば0(held)を返す（2026-08-30 Codex二次レビュー指摘・MAJOR対応） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/writer.lock"
  real_fp="$(bash -c 'source "$1"; _pid_lock_fingerprint "$2"' _ "$LIB_DIR/pid-lock.sh" "$$")"
  printf '%s\n%s\n' "$$" "$real_fp" > "$LOCK"
  bash -c 'source "$1"; is_pid_lock_held "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "PID生存かつ指紋一致ならexit 0(held)" "0" "$rc"
  rm -rf "$D"
}

echo "=== 14c. pid-lock.sh: is_pid_lock_held はPIDが生存していても指紋が不一致なら1(not held)を返す（PID再利用のシミュレーション。maintenance.sh異常終了後にPID番号が別プロセスへ再利用された場合、backup-vault.shが永久にheld誤判定してbackupを止め続ける実害の回帰テスト） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/writer.lock"
  printf '%s\n%s\n' "$$" "FAKE-MISMATCHED-FINGERPRINT" > "$LOCK"
  bash -c 'source "$1"; is_pid_lock_held "$2"' _ "$LIB_DIR/pid-lock.sh" "$LOCK"
  rc=$?
  assert_eq "PID生存でも指紋不一致ならexit 1(not held)" "1" "$rc"
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

echo "=== 18. pid-lock.sh: PID番号が生存していても指紋(開始時刻)がロックファイル記載分と一致しなければ、経過時間に関わらず即stale解除される（PID再利用のシミュレーション。2026-08-30 Codex 2巡目差し戻し・BLOCKING対応の回帰テスト） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  printf '%s\n%s\n' "$$" "FAKE-MISMATCHED-FINGERPRINT" > "$LOCK"   # 自分自身のPID（確実に生存）＋わざと不一致な指紋
  # mtimeは「今」のまま（時間側フォールバックが効かない状況でも指紋不一致だけで
  # stale判定されることを確認するため、経過時間はほぼ0にしておく）。
  out="$(bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 3600 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\")"; fi
  }
  assert_contains_local "PID生存でも指紋不一致(mtimeは新しいまま)でstale解除のWARNが出る" "$out" "stale なロックファイルを検出しました"
  assert_contains_local "stale解除後にロック取得が成功し後続処理まで到達する" "$out" "REACHED_AFTER_LOCK"
  rm -rf "$D"
}

echo "=== 19. pid-lock.sh: PID番号が生存し指紋も一致すれば、経過時間がstale_secondsを大幅に超えていても生存扱いのままbusy skipする（18の対比・二重実行防止の核心＝正当な所有者を時間だけで強制期限切れにしない。2026-08-30 Codex 2巡目差し戻し・BLOCKING対応の回帰テスト） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  # 自分自身(このテストスクリプトプロセス=$$)の実際の指紋を取得して書き込む
  # （_pid_lock_fingerprintを直接呼ぶ。サブシェル自身の$$ではなく、外側の
  # このプロセスのPIDを明示的に渡す＝bash -cの子プロセスPIDを取り違えない）。
  real_fp="$(bash -c 'source "$1"; _pid_lock_fingerprint "$2"' _ "$LIB_DIR/pid-lock.sh" "$$")"
  printf '%s\n%s\n' "$$" "$real_fp" > "$LOCK"
  # mtimeをstale_secondsより遥かに古い過去へ巻き戻す（bash 3.2互換のため
  # touch -tではなくos.utime()で秒単位精度を明示指定する）。
  python3 -c "
import os, time
t = time.time() - 999999
os.utime('$LOCK', (t, t))
"
  out="$(bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 5 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\")"; fi
  }
  assert_contains_local "指紋一致なら経過999999秒≫stale_seconds5秒でも既に実行中扱いのまま" "$out" "既に実行中です"
  if [[ "$out" != *"REACHED_AFTER_LOCK"* ]]; then
    pass "busy skipなので後続処理まで到達しない(exit 0で早期終了)"
  else
    fail_case "busy skipのはずが後続処理まで到達した(想定外＝正当な所有者を誤って期限切れにした)"
  fi
  rm -rf "$D"
}

echo "=== 20. pid-lock.sh: 指紋なし旧形式ロック(PIDのみ1行)は、経過時間がstale_seconds未満ならフォールバックで生存扱いのまま（本改修前に書かれたロックファイルとの後方互換） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  echo "$$" > "$LOCK"   # 旧形式＝PIDのみ(指紋行なし)
  python3 -c "
import os, time
t = time.time() - 2
os.utime('$LOCK', (t, t))
"
  out="$(bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 3600 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\")"; fi
  }
  assert_contains_local "指紋なし旧形式・経過2秒<stale_seconds3600秒では既に実行中扱いのまま" "$out" "既に実行中です"
  if [[ "$out" != *"REACHED_AFTER_LOCK"* ]]; then
    pass "busy skipなので後続処理まで到達しない(exit 0で早期終了)"
  else
    fail_case "busy skipのはずが後続処理まで到達した(想定外)"
  fi
  rm -rf "$D"
}

echo "=== 21. pid-lock.sh: 指紋なし旧形式ロックは、経過時間がstale_seconds以上ならフォールバックでstale解除される（20の対比） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  echo "$$" > "$LOCK"
  python3 -c "
import os, time
t = time.time() - 10
os.utime('$LOCK', (t, t))
"
  out="$(bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 5 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\")"; fi
  }
  assert_contains_local "指紋なし旧形式・経過10秒≥stale_seconds5秒でstale解除のWARNが出る" "$out" "stale なロックファイルを検出しました"
  assert_contains_local "stale解除後にロック取得が成功し後続処理まで到達する" "$out" "REACHED_AFTER_LOCK"
  rm -rf "$D"
}

echo "=== 22. pid-lock.sh: acquire_pid_lockはstale_secondsが正の整数でなければFAILでexit 1する(呼び出し元のバグ検知・Codex一次レビュー指摘Minor対応) ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  for bad in 0 -5 abc "" "3.5"; do
    rc=0
    out="$(bash -c 'source "$1"; acquire_pid_lock "$2" "$3" "test" ""' _ "$LIB_DIR/pid-lock.sh" "$LOCK" "$bad" 2>&1)" || rc=$?
    assert_eq "stale_seconds='${bad}'はexit 1になる" "1" "$rc"
  done
  rm -rf "$D"
}

echo "=== 23. pid-lock.sh: 指紋はロケール/タイムゾーンに依存せず一致する（ロック書込みと照合で呼び出し環境のLC_ALL/TZが異なっても同一プロセスなら生存扱いのまま。2026-08-30 Codex二次レビュー指摘・MAJOR対応: ps -o lstart=は曜日・月名を含む表示文字列のため、環境ロケールが異なると同一プロセスでも文字列が変わり誤stale判定になりうる欠陥の回帰テスト） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  # 書込み側は日本語ロケール環境、照合側はC/America-New_York環境で、それぞれ
  # 独立に指紋を取得して直接比較する（Codex三次レビュー指摘・Minor対応:
  # 従来は`|| true`でfp_ja取得失敗を握り潰しており、失敗しても指紋なし旧形式＋
  # 新しいmtimeとしてたまたまbusy判定になり、テストの意図を検証せずに
  # 通ってしまう穴があった。取得成功を先に明示的にassertし、かつ2つの指紋の
  # 生値を直接比較する）。
  fp_ja="$(LC_ALL=ja_JP.UTF-8 bash -c 'source "$1"; _pid_lock_fingerprint "$2"' _ "$LIB_DIR/pid-lock.sh" "$$")"
  assert_eq "ja_JP.UTF-8環境での指紋取得が成功する(fixtureの前提確認)" "1" \
    "$([[ -n "$fp_ja" ]] && echo 1 || echo 0)"
  fp_c="$(LC_ALL=C TZ=America/New_York bash -c 'source "$1"; _pid_lock_fingerprint "$2"' _ "$LIB_DIR/pid-lock.sh" "$$")"
  assert_eq "C/America-New_York環境での指紋取得が成功する(fixtureの前提確認)" "1" \
    "$([[ -n "$fp_c" ]] && echo 1 || echo 0)"
  assert_eq "ロケール/タイムゾーンが異なっても同一プロセスの指紋は一致する" "$fp_ja" "$fp_c"

  # 併せてacquire_pid_lock経由の結合確認も残す。
  printf '%s\n%s\n' "$$" "$fp_ja" > "$LOCK"
  out="$(LC_ALL=C TZ=America/New_York bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 3600 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
  }
  assert_contains_local "書込み側ja_JP・照合側C/America-New_Yorkでも指紋が一致し既に実行中扱いになる" "$out" "既に実行中です"
  rm -rf "$D"
}

echo "=== 24. pid-lock.sh: 指紋照合中にpsが失敗しても(判定不能)生存扱いのまま解除しない(fail-closed。2026-08-30 Codex二次レビュー指摘・BLOCKING対応の回帰テスト) ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  real_fp="$(bash -c 'source "$1"; _pid_lock_fingerprint "$2"' _ "$LIB_DIR/pid-lock.sh" "$$")"
  printf '%s\n%s\n' "$$" "$real_fp" > "$LOCK"
  # psが常に失敗するスタブをPATHの先頭に差し込む（照合時のps呼び出しを
  # 意図的に破壊する）。
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/ps" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUBDIR/ps"
  out="$(PATH="$STUBDIR:$PATH" bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 3600 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
  }
  assert_contains_local "ps失敗で現在指紋が取得できなくても既に実行中扱いのまま(誤ってstale解除しない)" "$out" "既に実行中です"
  if [[ "$out" != *"REACHED_AFTER_LOCK"* ]]; then
    pass "busy skipなので後続処理まで到達しない(exit 0で早期終了)"
  else
    fail_case "busy skipのはずが後続処理まで到達した(想定外＝ps失敗を理由に生存ロックを誤って解除した)"
  fi
  rm -rf "$D" "$STUBDIR"
}

echo "=== 25. pid-lock.sh: 指紋なし旧形式ロックの境界値。経過時間がちょうどstale_secondsならフォールバックでstale扱いになる('<'であって'<='ではない・2026-08-30 Codex二次レビュー指摘・Minor対応) ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  echo "$$" > "$LOCK"
  python3 -c "
import os, time
t = time.time() - 5
os.utime('$LOCK', (t, t))
"
  out="$(bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 5 2>&1)"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\")"; fi
  }
  # os.utime()実行からacquire_pid_lock内のdate +%s実行までに実時間が経過する
  # ため、実測ageは5以上（境界ちょうど、または境界超）になる。いずれの場合も
  # `age -lt 5`は偽＝stale解除される、という同じ結論になる。
  assert_contains_local "経過時間がstale_seconds以上(境界含む)でstale解除される" "$out" "REACHED_AFTER_LOCK"
  rm -rf "$D"
}

echo "=== 26. pid-lock.sh: ロック新規作成時にpsが使えず指紋を記録できなくても、生存所有者はmtime経過だけで期限切れにならない（2026-08-30 Codex三次レビュー指摘・BLOCKING対応の回帰テスト: 作成時のpsの一瞬の失敗が『指紋なし旧形式』に化けてmtimeフォールバックへ落ちる穴があった） ==="
{
  D="$(mktemp -d)"
  LOCK="$D/self.lock"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/ps" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUBDIR/ps"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
  }

  # 1. psが使えない状態で_pid_lock_try_create()を直接呼び、そのプロセス自体は
  #    sleepでbackground生存させ続ける（acquire_pid_lock()経由だとEXIT trapで
  #    プロセス終了時に自動解放されてしまい、検証したい「生存し続けるロック」
  #    を作れないため、ここだけ意図的に低レベル関数を直接呼ぶ）。
  PATH="$STUBDIR:$PATH" bash -c '
    source "$1"
    _pid_lock_try_create "$2"
    sleep 30
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" &
  HOLDER_PID=$!
  for _i in $(seq 1 50); do
    [[ -s "$LOCK" ]] && break
    sleep 0.1
  done
  assert_eq "1行目にholderプロセスのPIDが書かれている" "$HOLDER_PID" "$(sed -n '1p' "$LOCK" 2>/dev/null)"
  assert_eq "2行目に予約値(FINGERPRINT-UNAVAILABLE)が書かれている(2行目省略ではない)" \
    "FINGERPRINT-UNAVAILABLE" "$(sed -n '2p' "$LOCK" 2>/dev/null)"

  # 2. mtimeをstale_secondsより遥かに古い過去へ巻き戻す。
  python3 -c "
import os, time
t = time.time() - 999999
os.utime('$LOCK', (t, t))
"

  # 3. holderはsleep中でまだ生存したまま、通常PATH(psが正常に使える状態)の
  #    別プロセスから再取得を試みる。予約値が書かれているため、経過時間に
  #    関わらずbusyのままであるべき（旧実装なら2行目省略のまま=旧形式扱いに
  #    なり、mtimeフォールバックで誤ってstale解除されてしまっていた）。
  out2="$(bash -c '
    source "$1"
    acquire_pid_lock "$2" "$3" "test" ""
    echo REACHED_AFTER_LOCK
  ' _ "$LIB_DIR/pid-lock.sh" "$LOCK" 5 2>&1)"
  assert_contains_local "作成時ps失敗でも生存holderのまま経過999999秒≫stale_seconds5秒でbusyのまま" "$out2" "既に実行中です"
  if [[ "$out2" != *"REACHED_AFTER_LOCK"* ]]; then
    pass "busy skipなので後続処理まで到達しない(exit 0で早期終了)"
  else
    fail_case "busy skipのはずが後続処理まで到達した(想定外＝作成時ps失敗を理由に生存ロックを誤って解除した)"
  fi

  kill "$HOLDER_PID" 2>/dev/null
  wait "$HOLDER_PID" 2>/dev/null
  rm -rf "$D" "$STUBDIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
