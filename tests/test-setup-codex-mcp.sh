#!/usr/bin/env bash
# scripts/setup-codex-mcp.sh のユニットテスト。
#
# 実 claude・実 codex コマンドには依存しない。モックの `claude`（PATH前置）を
# 使って「未登録→addが呼ばれる」「登録済み→skip」等を検証する
# （2026-07-08 設計判断のテスト方式）。
#
# 実行方法: bash tests/test-setup-codex-mcp.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/setup-codex-mcp.sh"

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

# モックの claude コマンドを作る。$1 = 配置先binディレクトリ、$2 = ログファイル、
# $3 = "registered" なら `mcp get codex` を成功(0)扱い、それ以外は失敗(1)扱いにする。
make_mock_claude() {
  local bindir="$1" log="$2" registered="$3"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
if [ "\$1 \$2" = "mcp get" ]; then
  if [ "$registered" = "registered" ]; then exit 0; else exit 1; fi
fi
if [ "\$1 \$2" = "mcp add" ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$bindir/claude"
}

make_mock_codex() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bindir/codex"
}

echo "=== 1. 未登録・codexがPATHにある → mcp add が正しい引数で呼ばれる ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/claude-calls.log"
  : > "$LOG"
  make_mock_claude "$BINDIR" "$LOG" "unregistered"
  make_mock_codex "$BINDIR"

  rc=0
  PATH="$BINDIR:$PATH" HOME="$WORK/fake-home-no-shims" bash "$SCRIPT" >"$WORK/stdout.log" 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "mcp get codex が呼ばれた" \
    "$(grep -q '^mcp get codex$' "$LOG" && echo 1 || echo 0)"
  assert_true "mcp add codex -s user -- <path> mcp-server が呼ばれた" \
    "$(grep -qE '^mcp add codex -s user -- .*/codex mcp-server$' "$LOG" && echo 1 || echo 0)"
  assert_true "絶対パスで登録されている（bare codexではない）" \
    "$(grep -E '^mcp add' "$LOG" | grep -q -- "-- $BINDIR/codex mcp-server" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2. 登録済み → skipし、addは呼ばれない ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/claude-calls.log"
  : > "$LOG"
  make_mock_claude "$BINDIR" "$LOG" "registered"
  make_mock_codex "$BINDIR"

  rc=0
  out=$(PATH="$BINDIR:$PATH" HOME="$WORK/fake-home-no-shims" bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "既に登録済みメッセージが出る" \
    "$(echo "$out" | grep -q '既に登録済み' && echo 1 || echo 0)"
  assert_true "mcp add は呼ばれていない" \
    "$(grep -q '^mcp add' "$LOG" && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo "=== 3. 未登録・codexがどこにも見つからない → exit 1、手順を表示 ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/claude-calls.log"
  : > "$LOG"
  make_mock_claude "$BINDIR" "$LOG" "unregistered"
  # codexは配置しない（見つからない状態を模擬）。PATHは "$BINDIR:$PATH" のように
  # 外側のPATHを継承せず /usr/bin:/bin に固定する（Codexレビュー指摘・Minor：
  # 外側PATHを継承すると、開発機に実codexが入っている場合にテストが
  # 環境依存で失敗する＝「どこにも見つからない」の再現性が崩れる）。
  rc=0
  out=$(PATH="$BINDIR:/usr/bin:/bin" HOME="$WORK/fake-home-no-shims" bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "codexが見つからない旨のメッセージが出る" \
    "$(echo "$out" | grep -q 'codex コマンドが見つかりません' && echo 1 || echo 0)"
  assert_true "手動登録コマンドの案内が出る" \
    "$(echo "$out" | grep -q 'claude mcp add codex' && echo 1 || echo 0)"
  assert_true "mcp add は呼ばれていない" \
    "$(grep -q '^mcp add' "$LOG" && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo "=== 3b. codexがシェル関数（絶対パスでない）の場合は無視してnot foundにする ==="
{
  # `command -v codex` はシェル関数があると絶対パスではなくbare名を返すことがある
  # （実測確認済み）。bare command禁止の原則に従い、これを「見つからなかった」扱いに
  # フォールバックできることを確認する（Codexレビュー指摘・Major）。
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/claude-calls.log"
  : > "$LOG"
  make_mock_claude "$BINDIR" "$LOG" "unregistered"
  # codexは実行ファイルとしては配置せず、シェル関数として export する。

  rc=0
  out=$(
    codex() { echo "fake function output"; }
    export -f codex
    PATH="$BINDIR:/usr/bin:/bin" HOME="$WORK/fake-home-no-shims" bash "$SCRIPT" 2>&1
  ) || rc=$?
  assert_eq "exit code 1（関数はbareなので不採用・not found扱い）" "1" "$rc"
  assert_true "codexが見つからない旨のメッセージが出る（関数を誤採用していない）" \
    "$(echo "$out" | grep -q 'codex コマンドが見つかりません' && echo 1 || echo 0)"
  assert_true "mcp add は呼ばれていない" \
    "$(grep -q '^mcp add' "$LOG" && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo "=== 4. claude コマンド自体が見つからない → exit 1 ==="
{
  WORK="$(mktemp -d)"
  rc=0
  out=$(PATH="/usr/bin:/bin" HOME="$WORK/fake-home-no-shims" bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "claudeが見つからない旨のメッセージが出る" \
    "$(echo "$out" | grep -q 'claude コマンドが見つかりません' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 5. nodenv shim経由でcodexが見つかる場合も登録できる ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/claude-calls.log"
  : > "$LOG"
  make_mock_claude "$BINDIR" "$LOG" "unregistered"
  FAKE_HOME="$WORK/fake-home-with-shim"
  mkdir -p "$FAKE_HOME/.anyenv/envs/nodenv/shims"
  cat > "$FAKE_HOME/.anyenv/envs/nodenv/shims/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_HOME/.anyenv/envs/nodenv/shims/codex"

  rc=0
  PATH="$BINDIR:/usr/bin:/bin" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "nodenv shimの絶対パスで登録された" \
    "$(grep -q -- "-- $FAKE_HOME/.anyenv/envs/nodenv/shims/codex mcp-server" "$LOG" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
