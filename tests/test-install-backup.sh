#!/usr/bin/env bash
# scripts/install-backup.sh のユニットテスト（新ラベル設置・冪等・失敗時の
# exit 1 の検証。旧ラベル移行の検査は 2026-09-19 着手順 1 で退役＝ラベルは
# repo の plist から動的に取る）。
#
# 実 ~/Library/LaunchAgents・実launchdセッションには一切依存しない。
# HOME環境変数を毎回ダミーのfixtureディレクトリへ差し替え、かつ非dry-run呼び出し
# には必ず SKIP_LAUNCHCTL=1 を付けて実システムのlaunchdに触れないようにする
# （gui/$(id -u) は実launchdセッションでありHOME差し替えだけでは隔離できない
# ＝tests/test-install-sub.shで実際に起きた事故の教訓を踏襲。scripts/
# install-backup.shのSKIP_LAUNCHCTLはplist配置・旧plist削除は行ったまま
# launchctlコマンドの実行だけをskipする）。
#
# 加えて、SKIP_LAUNCHCTL分岐そのものが将来壊れて実launchctlを呼んでしまう回帰に
# 備え、PATH先頭へ偽launchctl（呼び出しを記録するだけの何もしないスクリプト）を
# 差し込み、各テスト後に「一度も呼ばれていないこと」を独立に検証する
# （2026-07-16 Codexレビュー指摘Major対応: SKIP_LAUNCHCTLの解釈自体がテスト対象の
# 実装コードなので、それを信用するだけでは不十分＝二重の安全網にする）。
#
# 実行方法: bash tests/test-install-backup.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-backup.sh"

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

NEW_LABEL="$(plutil -extract Label raw -o - "$REPO_ROOT"/launchagents/com.takumi009.backup-vault.plist)"

# 偽launchctl（呼ばれたら引数をログへ記録するだけ・本物のlaunchdには一切触れない）
# を$FAKE_BIN/launchctlとして用意し、PATHの先頭へ差し込む。
FAKE_BIN="$(mktemp -d)"
FAKE_LAUNCHCTL_LOG="$FAKE_BIN/launchctl-calls.log"
cat > "$FAKE_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$FAKE_LAUNCHCTL_LOG"
exit 1
EOF
chmod +x "$FAKE_BIN/launchctl"
trap 'rm -rf "$FAKE_BIN"' EXIT

# SKIP_LAUNCHCTL=1付きでinstall-backup.shを実行する。PATHの先頭に偽launchctlを
# 差し込む（本物のlaunchctlより先に見つかるようにする）。
run_install_skip() {
  : > "$FAKE_LAUNCHCTL_LOG"
  PATH="$FAKE_BIN:$PATH" SKIP_LAUNCHCTL=1 HOME="$1" bash "$SCRIPT" "${@:2}"
}

# 偽launchctlが一度も呼ばれていないことをassertする（直前のrun_install_skip呼び出しに対して）。
assert_launchctl_never_called() {
  local desc="$1"
  assert_true "$desc" "$([[ ! -s "$FAKE_LAUNCHCTL_LOG" ]] && echo 1 || echo 0)"
}

echo "=== 1. dry-run: 実際の変更を一切しない ==="
{
  FAKE_HOME="$(mktemp -d)"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "dry-run出力にwould generateが含まれる" \
    "$(echo "$out" | grep -q 'would generate' && echo 1 || echo 0)"
  assert_true "新ラベルのplistは実際には作られていない" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. 通常実行: 新ラベルのplistが生成される・実launchctlは一切呼ばれない ==="
{
  FAKE_HOME="$(mktemp -d)"

  run_install_skip "$FAKE_HOME" >/dev/null
  assert_launchctl_never_called "SKIP_LAUNCHCTL=1下では偽launchctlすら一度も呼ばれない"

  DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
  assert_true "新ラベルのplistが生成される" "$([[ -f "$DEST" ]] && echo 1 || echo 0)"
  assert_true "__AIENV_HOME__が実HOME(FAKE_HOME)へ置換されている" \
    "$(grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/backup-vault.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "プレースホルダが残っていない" \
    "$(grep -q '__AIENV_HOME__' "$DEST" && echo 0 || echo 1)"
  assert_true "Labelキーが新ラベルになっている" \
    "$(grep -A1 '<key>Label</key>' "$DEST" | grep -q "<string>${NEW_LABEL}</string>" && echo 1 || echo 0)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "plutil -lint OK" "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 4. 新設置: 素の環境でも新ラベルのplistが生成される(繰り返し実行しても安全) ==="
{
  FAKE_HOME="$(mktemp -d)"

  out="$(run_install_skip "$FAKE_HOME")"
  assert_launchctl_never_called "素の環境の実行でも偽launchctlは呼ばれない"

  NEW_DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
  assert_true "新ラベルのplistは通常どおり生成される" "$([[ -f "$NEW_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 5. 冪等性: 2回実行しても新ラベルのplistは1つだけ・エラーにならない ==="
{
  FAKE_HOME="$(mktemp -d)"

  run_install_skip "$FAKE_HOME" >/dev/null
  rc=0
  run_install_skip "$FAKE_HOME" >/dev/null || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"
  assert_launchctl_never_called "2回目実行でも偽launchctlは呼ばれない"

  NEW_DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
  assert_true "新ラベルのplistは存在する" "$([[ -f "$NEW_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 7. 不明な引数はexit 1(FAIL) ==="
{
  FAKE_HOME="$(mktemp -d)"
  ERRLOG="$FAKE_HOME/stderr.log"
  rc=0
  HOME="$FAKE_HOME" bash "$SCRIPT" --bogus-flag >/dev/null 2>"$ERRLOG" || rc=$?
  assert_eq "不明な引数はexit 1" "1" "$rc"
  rm -rf "$FAKE_HOME"
}

echo "=== 14. 旧plistファイルが元々無い状態でもdomain照会が失敗すればfail-closedでexit 1になる(Codexレビュー4巡目指摘Major対応) ==="
{
  # 旧plistファイルの有無で外側を先にゲートしていた旧実装では、この
  # 「plistは既に無い・でもlaunchd照会も機能していない」という組み合わせで
  # unknown分岐へ一切入らずサイレントにexit 0（完了扱い）になってしまって
  # いた。domain照会自体が機能していない場合にfail-closedでexit 1になる
  # ことを検証する。
  FAKE_HOME="$(mktemp -d)"
  # 旧plistファイルは意図的に作らない（このテストの主眼）。

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  print) exit 1 ;;   # domain自体への照会も含めて常に失敗
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "旧plist無しでもdomain照会不能ならexit 1(fail-closed)" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "確認できなかった旨のWARNが出る" \
    "$(echo "$err" | grep -q "ロード状態をlaunchd照会で確認できませんでした" && echo 1 || echo 0)"
  assert_true "新ラベルのplistは正常に生成されている" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 15. 新ラベルのenableが失敗した場合はexit 1になる(以前は\`|| true\`で握り潰していた・scripts/install-maintenance.shで確立した方式の横展開・2026-07-16リーダー裁定対応) ==="
{
  FAKE_HOME="$(mktemp -d)"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  enable) exit 1 ;;   # 新ラベルのenableを常に失敗させる
  bootstrap) exit 0 ;;
  bootout) exit 0 ;;
  print) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "新ラベルのenable失敗はexit 1(FAIL)になる" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "enable失敗のFAILメッセージが出る" \
    "$(echo "$err" | grep -q "enable failed" && echo 1 || echo 0)"
  assert_true "新ラベルのplist自体は生成されている(bootstrapは成功しているため)" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 16. bootstrapが最初は失敗してもenable後の再試行で成功すれば正常完了する(disabled状態からの復旧・scripts/install-maintenance.shで確立した方式の横展開・2026-07-16リーダー裁定対応) ==="
{
  # macOS launchdは対象ラベルがdisabled overrideに残っている場合、enableされる
  # までbootstrapが失敗し続けることがある既知の挙動があるため、1回だけの
  # enable→bootstrap再試行で復旧できることを検証する。「呼び出し回数」ではなく
  # 「enableが実際に実行されたこと」に依存させるため、bootstrapはマーカー
  # ファイルが存在する場合にのみ成功するスタブにする（tests/test-install-
  # maintenance.shのCodexレビュー指摘Minor対応を踏襲）。
  FAKE_HOME="$(mktemp -d)"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  ENABLED_MARKER="$STUB_BIN/enabled.marker"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  bootstrap)
    if [ -e "$ENABLED_MARKER" ]; then exit 0; else exit 1; fi
    ;;
  bootout) exit 0 ;;
  enable) touch "$ENABLED_MARKER"; exit 0 ;;
  print) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  out="$(PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_eq "disabled復旧の再試行が成功すればexit 0" "0" "$rc"
  assert_true "1回目bootstrap失敗のWARNログが出る" \
    "$(echo "$out" | grep -q "disabled状態の可能性があるため" && echo 1 || echo 0)"
  assert_true "enableが実際に実行されたことを介してbootstrapが成功している(回数だけの偶然ではない)" \
    "$([[ -e "$ENABLED_MARKER" ]] && echo 1 || echo 0)"
  assert_true "bootstrapが2回呼ばれている(初回失敗+再試行成功)" \
    "$([[ "$(grep -cE '^bootstrap ' "$CALL_LOG")" -eq 2 ]] && echo 1 || echo 0)"
  assert_true "新ラベルのplistが生成されている" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
