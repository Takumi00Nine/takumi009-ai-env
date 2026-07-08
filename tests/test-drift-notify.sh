#!/usr/bin/env bash
# scripts/drift-notify.sh のユニットテスト。
#
# 実 scripts/check-drift.sh・実 osascript には依存しない。fixture repo内に
# ダミーの check-drift.sh を配置して出力を差し替え、drift-notify.sh の
# パース・通知呼び出し判定ロジックだけを検証する。
#
# 注意: macOSには標準で /usr/bin/osascript が存在するため、単に PATH から
# 実binディレクトリを外すだけでは「osascriptが無い」状態を作れない。osascriptを
# 呼ぶケースでは必ずモックosascriptをPATHの先頭に置き、実system通知が
# 発火しないようにする（実装時の手動確認で、モック無しのテストだと実際に
# macOS通知が飛ぶことを確認済み＝要注意ポイント）。
#
# 実行方法: bash tests/test-drift-notify.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# ダミーの check-drift.sh を持つfixtureリポジトリを作る。
# $2 = check-drift.sh が標準出力する「総drift件数: N」の行（無しなら空文字）。
make_fake_repo() {
  local repo="$1" drift_line="$2"
  mkdir -p "$repo/scripts"
  cat > "$repo/scripts/check-drift.sh" <<EOF
#!/usr/bin/env bash
echo "dummy check-drift.sh output"
${drift_line:+echo "$drift_line"}
EOF
  chmod +x "$repo/scripts/check-drift.sh"
  cp "$REPO_ROOT/scripts/drift-notify.sh" "$repo/scripts/drift-notify.sh"
  chmod +x "$repo/scripts/drift-notify.sh"
}

# モックのosascriptを作る（実system通知を発火させないため必須）。
make_mock_osascript() {
  local bindir="$1" log="$2"
  mkdir -p "$bindir"
  cat > "$bindir/osascript" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
exit 0
EOF
  chmod +x "$bindir/osascript"
}

echo "=== 1. drift>0 なら osascript が正しいメッセージで呼ばれる ==="
{
  REPO="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  LOG="$BINDIR/osascript-calls.log"
  : > "$LOG"
  make_fake_repo "$REPO" "[check-drift] 総drift件数: 3"
  make_mock_osascript "$BINDIR" "$LOG"

  out=$(PATH="$BINDIR:$PATH" bash "$REPO/scripts/drift-notify.sh")
  assert_true "check-drift.shの出力がそのまま含まれる" \
    "$(echo "$out" | grep -q 'dummy check-drift.sh output' && echo 1 || echo 0)"
  assert_true "drift 3件を検知した旨のログが出る" \
    "$(echo "$out" | grep -q 'drift 3件を検知しました' && echo 1 || echo 0)"
  assert_true "osascriptが1回呼ばれた" \
    "$([[ "$(wc -l < "$LOG" | tr -d ' ')" == "1" ]] && echo 1 || echo 0)"
  assert_true "通知メッセージに件数が含まれる" \
    "$(grep -q 'drift 3件を検知しました' "$LOG" && echo 1 || echo 0)"
  assert_true "display notificationコマンドが使われている" \
    "$(grep -q 'display notification' "$LOG" && echo 1 || echo 0)"

  rm -rf "$REPO" "$BINDIR"
}

echo "=== 2. drift=0 なら osascript は呼ばれない ==="
{
  REPO="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  LOG="$BINDIR/osascript-calls.log"
  : > "$LOG"
  make_fake_repo "$REPO" "[check-drift] 総drift件数: 0"
  make_mock_osascript "$BINDIR" "$LOG"

  out=$(PATH="$BINDIR:$PATH" bash "$REPO/scripts/drift-notify.sh")
  assert_true "drift 0件（正常）ログが出る" \
    "$(echo "$out" | grep -q 'drift 0件（正常）' && echo 1 || echo 0)"
  assert_true "osascriptは呼ばれていない" \
    "$([[ ! -s "$LOG" ]] && echo 1 || echo 0)"

  rm -rf "$REPO" "$BINDIR"
}

echo "=== 3. check-drift.shの出力から件数を読み取れない場合はexit 0でWARNのみ（通知しない） ==="
{
  REPO="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  LOG="$BINDIR/osascript-calls.log"
  : > "$LOG"
  make_fake_repo "$REPO" ""
  make_mock_osascript "$BINDIR" "$LOG"

  rc=0
  out=$(PATH="$BINDIR:$PATH" bash "$REPO/scripts/drift-notify.sh" 2>&1) || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "読み取れない旨のWARNが出る" \
    "$(echo "$out" | grep -q 'WARN: check-drift.sh の出力から総drift件数を読み取れませんでした' && echo 1 || echo 0)"
  assert_true "osascriptは呼ばれていない" \
    "$([[ ! -s "$LOG" ]] && echo 1 || echo 0)"

  rm -rf "$REPO" "$BINDIR"
}

echo "=== 4. scripts/check-drift.sh 自体が見つからない場合はexit 0でWARNのみ ==="
{
  REPO="$(mktemp -d)"
  mkdir -p "$REPO/scripts"
  cp "$REPO_ROOT/scripts/drift-notify.sh" "$REPO/scripts/drift-notify.sh"
  chmod +x "$REPO/scripts/drift-notify.sh"
  # check-drift.sh は配置しない（checkout破損を模擬）

  rc=0
  out=$(bash "$REPO/scripts/drift-notify.sh" 2>&1) || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "見つからない旨のWARNが出る" \
    "$(echo "$out" | grep -q 'WARN: scripts/check-drift.sh が見つかりません' && echo 1 || echo 0)"

  rm -rf "$REPO"
}

echo "=== 5. osascriptが無い環境ではWARNのみで通知せずexit 0（実system通知を発火させない） ==="
{
  REPO="$(mktemp -d)"
  make_fake_repo "$REPO" "[check-drift] 総drift件数: 2"

  # osascriptを解決できない最小限のPATHを作る（実system の /usr/bin/osascript を
  # 意図的に除外する。drift-notify.sh自身が必要とする外部コマンド（dirname/sed/
  # tail/cat等）だけを実体からシンボリックリンクして用意する）。
  MINBIN="$(mktemp -d)"
  for tool in bash sh dirname sed tail cat basename mkdir; do
    p="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$p" ]; then
      ln -sf "$p" "$MINBIN/$tool"
    fi
  done

  rc=0
  out=$(PATH="$MINBIN" bash "$REPO/scripts/drift-notify.sh" 2>&1) || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "osascriptが見つからない旨のWARNが出る" \
    "$(echo "$out" | grep -q 'WARN: osascript が見つかりません' && echo 1 || echo 0)"

  rm -rf "$REPO" "$MINBIN"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
