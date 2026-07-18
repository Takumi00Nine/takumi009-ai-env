#!/usr/bin/env bash
# scripts/install-backup.sh のユニットテスト（2026-07-16簡素化・設計書§5
# 「改名実施は com.takumi009.vault-backup → com.takumi009.backup-vault の1件のみ」
# ＝新ラベル設置＋旧ラベルのbootout+plist削除ロジックの検証）。
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

NEW_LABEL="com.takumi009.backup-vault"
OLD_LABEL="com.takumi009.vault-backup"

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

echo "=== 2. 通常実行: 新ラベル(com.takumi009.backup-vault)のplistが生成される・実launchctlは一切呼ばれない ==="
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

echo "=== 3. 移行: 旧ラベル(com.takumi009.vault-backup)のplistが残っていれば新ラベル設置後に削除される ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  out="$(run_install_skip "$FAKE_HOME")"
  assert_launchctl_never_called "移行経路でもSKIP_LAUNCHCTL=1下では偽launchctlは呼ばれない"

  NEW_DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
  assert_true "新ラベルのplistが生成される" "$([[ -f "$NEW_DEST" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルのplistは削除される" "$([[ ! -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "移行検出のログメッセージが出る" \
    "$(echo "$out" | grep -q "旧ラベル（${OLD_LABEL}）を検出" && echo 1 || echo 0)"
  assert_true "移行完了のログメッセージが出る" \
    "$(echo "$out" | grep -q "旧ラベル（${OLD_LABEL}）を削除しました" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. 移行: 旧ラベルのplistが元々無ければ移行処理は何もしない(繰り返し実行しても安全) ==="
{
  FAKE_HOME="$(mktemp -d)"

  out="$(run_install_skip "$FAKE_HOME")"
  assert_launchctl_never_called "旧plist無し実行でも偽launchctlは呼ばれない"

  assert_true "移行検出のログは出ない(旧plistが無いため)" \
    "$(echo "$out" | grep -q "旧ラベル（${OLD_LABEL}）を検出" && echo 0 || echo 1)"
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

echo "=== 6. dry-run: 旧ラベルのplistが残っている場合、移行予定のメッセージも表示するが実際には削除しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "dry-run出力に旧ラベルのbootout予定が含まれる" \
    "$(echo "$out" | grep -q "would run: launchctl bootout .*${OLD_LABEL}" && echo 1 || echo 0)"
  assert_true "旧ラベルのplistは実際には削除されない(dry-runのため)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

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

echo "=== 8. 移行: 旧plistファイルは既に無いが旧ラベルがlaunchd上にロード済みの場合も検出しbootoutを試みる(Codexレビュー指摘Major対応) ==="
{
  # SKIP_LAUNCHCTL=1下ではold_label_loaded()は常にfalse固定（実launchdへ問い合わせ
  # ない安全側フォールバック）のため、この経路自体はSKIP_LAUNCHCTL=0でしか
  # 再現できない。実launchdには一切触れず、PATH先頭の偽launchctlだけで
  # 「print実行時は成功(=ロード済みという返答)・bootout実行時は成功」を返す
  # スタブに差し替えて検証する（実launchctlへは到達しない＝安全）。
  FAKE_HOME="$(mktemp -d)"
  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  print) exit 0 ;;   # 「ロード済み」を意味する成功終了
  bootstrap) exit 0 ;;
  bootout) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  # 旧plistファイル自体は存在しない状態を作る（ここがこのテストの主眼）。
  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "旧plistファイルが無くてもlaunchd上ロード済みなら移行検出のログが出る" \
    "$(echo "$out" | grep -q "旧ラベル（${OLD_LABEL}）を検出" && echo 1 || echo 0)"
  assert_true "旧ラベルへprintで生死を問い合わせている" \
    "$(grep -qE "^print .*${OLD_LABEL}" "$CALL_LOG" && echo 1 || echo 0)"
  assert_true "旧ラベルへbootoutも実行される" \
    "$(grep -qE "^bootout .*${OLD_LABEL}" "$CALL_LOG" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 9. 移行: 旧ラベルのbootoutに失敗した場合はplistを削除せず次回実行時に再試行できる状態を保つ(Codexレビュー指摘Major対応) ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  bootout)
    # 旧ラベルへのbootoutだけ常に失敗させる（新ラベルへのbootoutは無視して成功）。
    case "\$*" in
      *${OLD_LABEL}*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  print)
    # domain自体への照会(old_label_status()内の前段チェック)・旧ラベルへの
    # 照会のどちらも「正常にロードされている」と一貫して答える（bootout失敗が
    # 一時的なものではなく実際に解除できていない状態を模擬。domain照会まで
    # 失敗させるとold_label_status()が"unknown"を返しWARN文言が変わってしまう
    # ため、domain照会は常に成功させる＝2026-07-16 Codexレビュー3巡目対応で
    # old_label_status()が3値判定になったことに追随したスタブ更新）。
    exit 0
    ;;
  bootstrap) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  # 旧ラベルのbootout失敗は「新ラベルは動くが後片付けが未完了」という状態であり、
  # サイレントにexit 0で完了扱いにはしない（2026-07-16 Codexレビュー2巡目指摘
  # Major対応: 当初はexit 0のままで「完了はしていないが検知できない」状態
  # だった）。
  assert_eq "旧ラベルのbootout失敗はスクリプト全体の終了コードを非0にする" "1" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "新ラベルのplistは(旧ラベルの後片付け失敗とは無関係に)生成されている" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"
  assert_true "'done.'ログは出る(新ラベル設置自体は成功しているため)" \
    "$(echo "$out" | grep -q '\[install-backup\] done\.' && echo 1 || echo 0)"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "bootout失敗のWARNメッセージが出る" \
    "$(echo "$err" | grep -q "旧ラベル（${OLD_LABEL}）のbootoutに失敗しました" && echo 1 || echo 0)"
  assert_true "bootoutに失敗した旧plistは削除されず残る(次回再試行のため)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 10. 移行: 新ラベルのbootstrapが失敗した場合、旧ラベルの移行処理には一切進まず旧plist・旧ジョブは触れない(Codexレビュー指摘Minor対応) ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  bootstrap) exit 1 ;;   # 新ラベルのbootstrapを常に失敗させる
  bootout) exit 0 ;;
  print) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "新ラベルのbootstrap失敗はexit 1(FAIL)になる" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "bootstrap失敗のFAILメッセージが出る" \
    "$(echo "$err" | grep -q "bootstrap failed" && echo 1 || echo 0)"
  assert_true "旧ラベルへのbootout呼び出しは記録されていない(移行処理まで到達していない)" \
    "$(grep -qE "^bootout .*${OLD_LABEL}" "$CALL_LOG" 2>/dev/null && echo 0 || echo 1)"
  assert_true "旧plistは削除されず残る" "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 11. 移行: 呼び出し順序は新ラベルのbootstrap成功→旧ラベルのbootoutの順になる(設計書§4「新ラベル設置後に旧ラベルをbootout」・Codexレビュー指摘Minor対応) ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$STUB_BIN/launchctl"

  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  bootstrap_line="$(grep -nE "^bootstrap " "$CALL_LOG" | head -1 | cut -d: -f1)"
  old_bootout_line="$(grep -nE "^bootout .*${OLD_LABEL}" "$CALL_LOG" | head -1 | cut -d: -f1)"
  assert_true "bootstrap呼び出しが記録されている" "$([[ -n "$bootstrap_line" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルへのbootout呼び出しが記録されている" "$([[ -n "$old_bootout_line" ]] && echo 1 || echo 0)"
  assert_true "新ラベルのbootstrapが旧ラベルのbootoutより先に呼ばれる" \
    "$([[ -n "$bootstrap_line" && -n "$old_bootout_line" && "$bootstrap_line" -lt "$old_bootout_line" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 12. 移行: 旧plistファイルは残っているが旧ラベルが一度もロードされていない場合、bootoutを試みずに安全にplistだけ削除する(Codexレビュー指摘Major対応) ==="
{
  # old_label_status()が3値判定になる前は、この「未ロードのplist」ケースで
  # bootoutが（未ロードサービスへのbootoutは通常非0で終わるため）常に
  # 『失敗』と誤判定され、削除して問題ない孤立plistを永久に温存し続けて
  # しまっていた。domain自体への照会は成功・旧ラベルへの照会は失敗（＝
  # 確実に未ロード）という組み合わせを模擬し、bootoutを一切呼ばずに
  # 安全にplistだけ削除できることを検証する。
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub (never loaded) -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  print)
    case "\$*" in
      *${OLD_LABEL}*) exit 1 ;;   # 旧ラベルへの照会は失敗＝確実に未ロード
      *) exit 0 ;;                # domain自体への照会は成功（launchd自体は健全）
    esac
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "未ロードのplist削除は成功しexit 0のまま" "0" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "「元々ロードされていませんでした」のログが出る" \
    "$(echo "$out" | grep -q "元々ロードされていませんでした" && echo 1 || echo 0)"
  assert_true "旧plistは削除される" "$([[ ! -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルへのbootoutは一切呼ばれない(未ロードと分かっているので不要)" \
    "$(grep -qE "^bootout .*${OLD_LABEL}" "$STUB_BIN/calls.log" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 13. 移行: launchdへの照会自体が機能していない(domain照会失敗)場合はfail-closedでplistを温存する(Codexレビュー指摘Major対応) ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  print) exit 1 ;;   # domain自体への照会も含めて常に失敗＝launchdへの問い合わせが機能していない
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "照会不能はexit 1(fail-closed)" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "確認できなかった旨のWARNが出る" \
    "$(echo "$err" | grep -q "ロード状態をlaunchd照会で確認できませんでした" && echo 1 || echo 0)"
  assert_true "照会不能な場合はplistを削除せず温存する(誤って安全なplistを消さない)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 14. 移行: 旧plistファイルが元々無い状態でもdomain照会が失敗すればfail-closedでexit 1になる(Codexレビュー4巡目指摘Major対応) ==="
{
  # 旧plistファイルの有無で外側を先にゲートしていた旧実装では、この
  # 「plistは既に無い・でもlaunchd照会も機能していない」という組み合わせで
  # unknown分岐へ一切入らずサイレントにexit 0（完了扱い）になってしまって
  # いた。旧ジョブがlaunchd上に残っている可能性を否定できないまま完了扱いに
  # ならないことを検証する。
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
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${OLD_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

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
  assert_true "旧ラベルはenable失敗より後の移行へ進まないため削除されず残る" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

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
