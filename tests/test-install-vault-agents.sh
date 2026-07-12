#!/usr/bin/env bash
# scripts/install-vault-agents.sh・launchagents/com.takumi009.{vault-inventory,
# fragments-log}.plist のユニットテスト。
#
# 実 ~/Library/LaunchAgents・実 launchctl には一切依存しない（--dry-runのみ実行）。
# 「配置のみ・即時kickstartはしない」設計（Codexレビュー指摘・Major）を固定する
# 回帰テストが主目的。
#
# 実行方法: bash tests/test-install-vault-agents.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-vault-agents.sh"

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

echo "=== 1. 収録した3plistは全てRunAtLoad=falseである（静的チェック） ==="
{
  for name in vault-inventory fragments-log knowledge-merge-detect; do
    plist="$REPO_ROOT/launchagents/com.takumi009.$name.plist"
    # RunAtLoadキーの直後の値が<false/>であることを確認する
    val=$(awk '/<key>RunAtLoad<\/key>/{getline; print; exit}' "$plist" | tr -d '[:space:]')
    assert_eq "$name: RunAtLoad=false" "<false/>" "$val"
  done
}

echo "=== 2. plutil -lint が全plistでOKになる（構文チェック） ==="
{
  for name in vault-inventory fragments-log knowledge-merge-detect; do
    plist="$REPO_ROOT/launchagents/com.takumi009.$name.plist"
    if plutil -lint "$plist" >/dev/null 2>&1; then
      pass "$name: plutil -lint OK"
    else
      fail_case "$name: plutil -lint NG"
    fi
  done
}

echo "=== 3. --dry-run: 実際の変更を一切しない・kickstartに触れない ==="
{
  FAKE_HOME="$(mktemp -d)"
  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)

  assert_true "would generateが3件出る" \
    "$([[ "$(echo "$out" | grep -c 'would generate')" == "3" ]] && echo 1 || echo 0)"
  # ログ文中に「kickstartは行わない」旨の説明があるのは正しい（そのものは弾かない）。
  # 実際に kickstart を"実行する計画"（would run: launchctl kickstart）が無いことを確認する。
  assert_true "「would run: launchctl kickstart」という実行計画は出ない（即時実行しない設計）" \
    "$(echo "$out" | grep -q 'would run: launchctl kickstart' && echo 0 || echo 1)"
  assert_true "実際にはLaunchAgentsディレクトリが作られていない" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. __AIENV_HOME__ プレースホルダが実ホームパスへ正しく置換される（生成シミュレーション） ==="
{
  FAKE_HOME="/tmp/fake-home-for-vault-agents-test"
  for name in vault-inventory fragments-log knowledge-merge-detect; do
    src="$REPO_ROOT/launchagents/com.takumi009.$name.plist"
    sim=$(sed "s#__AIENV_HOME__#$FAKE_HOME#g" "$src")
    assert_true "$name: 置換後に__AIENV_HOME__が残っていない" \
      "$(echo "$sim" | grep -q '__AIENV_HOME__' && echo 0 || echo 1)"
    assert_true "$name: 置換後にscripts/vault-agents/への参照が正しい" \
      "$(echo "$sim" | grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/vault-agents/" && echo 1 || echo 0)"
  done
}

echo "=== 5. 撤去済みラベル(旧fragments-review)のplistが実在すると--dry-runで移行計画が出る（Codexレビュー指摘・Major） ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  touch "$FAKE_HOME/Library/LaunchAgents/com.takumi009.fragments-review.plist"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "旧ラベルの移行計画（bootout+削除）が出る" \
    "$(echo "$out" | grep -q 'would migrate away retired LaunchAgent.*com.takumi009.fragments-review.plist' && echo 1 || echo 0)"
  assert_true "--dry-runなので旧plistファイル自体は実際には削除されない" \
    "$([[ -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.fragments-review.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 6. 撤去済みラベルのplistが無ければ移行メッセージは出ない（新規導入・移行済み環境） ==="
{
  FAKE_HOME="$(mktemp -d)"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "移行計画メッセージは出ない（fail-open・無用なノイズを出さない）" \
    "$(echo "$out" | grep -q 'would migrate away retired LaunchAgent' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

# モックの launchctl を作る（実 launchctl・実LaunchAgentsには一切依存しない）。
#   bootout: 引数が com.takumi009.fragments-review を含むラベルなら $retired_bootout_rc
#            を返す。それ以外（vault-inventory・fragments-log の通常install_one分）は
#            常に成功させる（そうしないと install_one 側が fail() で異常終了する）。
#   print:   com.takumi009.fragments-review を含むラベルなら $retired_print_rc を返す
#            （0=まだロードされている、1=見つからない＝未ロード）。
#   bootstrap/enable: 常に成功させる。
make_mock_launchctl_for_migration() {
  local bindir="$1" retired_bootout_rc="$2" retired_print_rc="$3"
  mkdir -p "$bindir"
  cat > "$bindir/launchctl" <<EOF
#!/usr/bin/env bash
sub="\$1"
case "\$sub" in
  bootout)
    case "\$2" in
      *com.takumi009.fragments-review*) exit ${retired_bootout_rc} ;;
      *) exit 0 ;;
    esac
    ;;
  print)
    case "\$2" in
      *com.takumi009.fragments-review*) exit ${retired_print_rc} ;;
      *) exit 0 ;;
    esac
    ;;
  bootstrap|enable) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bindir/launchctl"
}

echo "=== 7. 旧ラベルのbootoutに失敗し、かつまだロードされている場合はplistを削除せず警告する（Codexレビュー指摘・Major） ==="
{
  FAKE_HOME="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  touch "$FAKE_HOME/Library/LaunchAgents/com.takumi009.fragments-review.plist"
  # bootout失敗(rc=1)・print成功(rc=0=まだロードされている)を模擬
  make_mock_launchctl_for_migration "$BINDIR" 1 0

  rc=0
  out=$(PATH="$BINDIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "スクリプト自体は異常終了しない(exit 0)" "0" "$rc"
  assert_true "ロードされたままの旨の警告が出る" \
    "$(echo "$out" | grep -q '\[WARN\].*まだロードされたままです' && echo 1 || echo 0)"
  assert_true "旧plistは削除されず残る（次回再試行できるようにするため）" \
    "$([[ -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.fragments-review.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo "=== 8. 旧ラベルのbootoutに失敗したが未ロードだった（printも失敗）場合はplistを安全に削除する ==="
{
  FAKE_HOME="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  touch "$FAKE_HOME/Library/LaunchAgents/com.takumi009.fragments-review.plist"
  # bootout失敗(rc=1)・print失敗(rc=1=未ロード)を模擬
  make_mock_launchctl_for_migration "$BINDIR" 1 1

  rc=0
  out=$(PATH="$BINDIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "スクリプト自体は異常終了しない(exit 0)" "0" "$rc"
  assert_true "未ロードだった旨のメッセージが出る" \
    "$(echo "$out" | grep -q '未ロードのためbootoutは対象なしでした' && echo 1 || echo 0)"
  assert_true "旧plistは削除される" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.fragments-review.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
