#!/usr/bin/env bash
# scripts/install-maintenance.sh のユニットテスト（2026-07-16簡素化・設計書§4
# 「install-maintenance.sh（新設）がvault-inventory/fragments-log/
# knowledge-merge-detect/drift-checkの4ラベルをmigrate_retired_label()で移行し
# maintenance.plistを設置」）。
#
# scripts/install-backup.shの1旧→1新ラベル移行テスト（tests/test-install-backup.sh）
# と同じ設計・同じCodexレビュー対応パターンを、4旧→1新ラベルに拡張して踏襲する。
#
# 実 ~/Library/LaunchAgents・実launchdセッションには一切依存しない。
# HOME環境変数を毎回ダミーのfixtureディレクトリへ差し替え、かつ非dry-run呼び出し
# には必ず SKIP_LAUNCHCTL=1 を付けて実システムのlaunchdに触れないようにする。
# 加えて、SKIP_LAUNCHCTL分岐そのものが将来壊れて実launchctlを呼んでしまう回帰に
# 備え、PATH先頭へ偽launchctl（呼び出しを記録するだけの何もしないスクリプト）を
# 差し込み、各テスト後に「一度も呼ばれていないこと」を独立に検証する。
#
# 実行方法: bash tests/test-install-maintenance.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-maintenance.sh"

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

NEW_LABEL="com.takumi009.maintenance"
RETIRED_LABELS=(
  com.takumi009.vault-inventory
  com.takumi009.fragments-log
  com.takumi009.knowledge-merge-detect
  com.takumi009.drift-check
)

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

# SKIP_LAUNCHCTL=1付きでinstall-maintenance.shを実行する。PATHの先頭に偽launchctlを
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

echo "=== 2. 通常実行: 新ラベル(com.takumi009.maintenance)のplistが生成される・実launchctlは一切呼ばれない ==="
{
  FAKE_HOME="$(mktemp -d)"

  run_install_skip "$FAKE_HOME" >/dev/null
  assert_launchctl_never_called "SKIP_LAUNCHCTL=1下では偽launchctlすら一度も呼ばれない"

  DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
  assert_true "新ラベルのplistが生成される" "$([[ -f "$DEST" ]] && echo 1 || echo 0)"
  assert_true "__AIENV_HOME__が実HOME(FAKE_HOME)へ置換されている" \
    "$(grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/maintenance.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "プレースホルダが残っていない" \
    "$(grep -q '__AIENV_HOME__' "$DEST" && echo 0 || echo 1)"
  assert_true "Labelキーが新ラベルになっている" \
    "$(grep -A1 '<key>Label</key>' "$DEST" | grep -q "<string>${NEW_LABEL}</string>" && echo 1 || echo 0)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "plutil -lint OK" "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 3. 移行: 旧ラベル4本のplistが残っていれば全て削除される ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  for label in "${RETIRED_LABELS[@]}"; do
    echo "<!-- old plist stub: $label -->" > "$FAKE_HOME/Library/LaunchAgents/${label}.plist"
  done

  out="$(run_install_skip "$FAKE_HOME")"
  assert_launchctl_never_called "移行経路でもSKIP_LAUNCHCTL=1下では偽launchctlは呼ばれない"

  NEW_DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
  assert_true "新ラベルのplistが生成される" "$([[ -f "$NEW_DEST" ]] && echo 1 || echo 0)"
  for label in "${RETIRED_LABELS[@]}"; do
    assert_true "旧ラベル(${label})のplistは削除される" \
      "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/${label}.plist" ]] && echo 1 || echo 0)"
    assert_true "旧ラベル(${label})の移行検出ログが出る" \
      "$(echo "$out" | grep -q "旧ラベル（${label}）を検出" && echo 1 || echo 0)"
  done

  rm -rf "$FAKE_HOME"
}

echo "=== 4. 移行: 旧ラベルのplistが元々無ければ移行処理は何もしない(繰り返し実行しても安全) ==="
{
  FAKE_HOME="$(mktemp -d)"

  out="$(run_install_skip "$FAKE_HOME")"
  assert_launchctl_never_called "旧plist無し実行でも偽launchctlは呼ばれない"

  for label in "${RETIRED_LABELS[@]}"; do
    assert_true "旧ラベル(${label})の移行検出ログは出ない(旧plistが無いため)" \
      "$(echo "$out" | grep -q "旧ラベル（${label}）を検出" && echo 0 || echo 1)"
  done
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
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${RETIRED_LABELS[0]}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "dry-run出力に旧ラベルの移行予定が含まれる" \
    "$(echo "$out" | grep -q "would migrate away retired LaunchAgent.*${RETIRED_LABELS[0]}" && echo 1 || echo 0)"
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

echo "=== 8. 移行: 旧plistファイルは既に無いが旧ラベルがlaunchd上にロード済みの場合も検出しbootoutを試みる ==="
{
  # SKIP_LAUNCHCTL=1下ではretired_label_status()は常に"skip"固定（実launchdへ
  # 問い合わせない安全側フォールバック）のため、この経路自体はSKIP_LAUNCHCTL=0
  # でしか再現できない。実launchdには一切触れず、PATH先頭の偽launchctlだけで
  # 「print実行時は成功(=ロード済みという返答)・bootout実行時は成功」を返す
  # スタブに差し替えて検証する（実launchctlへは到達しない＝安全）。
  FAKE_HOME="$(mktemp -d)"
  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  TARGET_LABEL="${RETIRED_LABELS[0]}"
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
    "$(echo "$out" | grep -q "旧ラベル（${TARGET_LABEL}）を検出" && echo 1 || echo 0)"
  assert_true "旧ラベルへprintで生死を問い合わせている" \
    "$(grep -qE "^print .*${TARGET_LABEL}" "$CALL_LOG" && echo 1 || echo 0)"
  assert_true "旧ラベルへbootoutも実行される" \
    "$(grep -qE "^bootout .*${TARGET_LABEL}" "$CALL_LOG" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 9. 移行: 旧ラベルのbootoutに失敗した場合はplistを削除せず、スクリプト全体の終了コードも非0にする ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  TARGET_LABEL="${RETIRED_LABELS[1]}"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${TARGET_LABEL}.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  bootout)
    # 対象ラベル(旧)へのbootoutだけ常に失敗させる（新ラベルへの先行bootoutは無視して成功）。
    case "\$*" in
      *${TARGET_LABEL}*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  print) exit 0 ;;
  bootstrap) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  # 旧ラベルのbootout失敗は「新ラベルは動くが後片付けが未完了」という状態であり、
  # サイレントにexit 0で完了扱いにはしない。
  assert_eq "旧ラベルのbootout失敗はスクリプト全体の終了コードを非0にする" "1" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "新ラベルのplistは(旧ラベルの後片付け失敗とは無関係に)生成されている" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"
  assert_true "'done.'ログは出る(新ラベル設置自体は成功しているため)" \
    "$(echo "$out" | grep -q '\[install-maintenance\] done\.' && echo 1 || echo 0)"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "bootout失敗のWARNメッセージが出る" \
    "$(echo "$err" | grep -q "旧ラベル（${TARGET_LABEL}）のbootoutに失敗しました" && echo 1 || echo 0)"
  assert_true "bootoutに失敗した旧plistは削除されず残る(次回再試行のため)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 10. 移行: 新ラベルのbootstrapが失敗した場合、旧ラベルの移行は一切行われずexit 1になる ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${RETIRED_LABELS[0]}.plist"
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
  # 本スクリプトは新ラベルの設置・bootstrap・enableが成功したことを確認してから
  # 旧ラベル4本の移行へ進む設計（Codexレビュー指摘Major対応・2026-07-16。新ラベル
  # 設置に失敗した場合に週次経路が完全消失する事態を避けるため）。
  # よってbootstrap失敗時は旧ラベルの移行に一切進んでおらず、旧plistは温存される。
  assert_true "旧ラベルは新ラベルのbootstrap失敗より前に移行されないため削除されず残る" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルへのbootoutは一度も呼ばれていない(新ラベル失敗で早期exitするため)" \
    "$(grep -qE "^bootout .*${RETIRED_LABELS[0]}" "$CALL_LOG" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 11. 順序: 新ラベルのbootstrap/enableは旧ラベル4本の移行より先に行われる(新設置確定を優先する設計) ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  for label in "${RETIRED_LABELS[@]}"; do
    echo "<!-- old plist stub: $label -->" > "$FAKE_HOME/Library/LaunchAgents/${label}.plist"
  done

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$STUB_BIN/launchctl"

  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  enable_line="$(grep -nE "^enable " "$CALL_LOG" | head -1 | cut -d: -f1)"
  first_old_bootout_line="$(grep -nE "^bootout .*${RETIRED_LABELS[0]}" "$CALL_LOG" | head -1 | cut -d: -f1)"
  assert_true "新ラベルのenable呼び出しが記録されている" "$([[ -n "$enable_line" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルへのbootout呼び出しが記録されている" "$([[ -n "$first_old_bootout_line" ]] && echo 1 || echo 0)"
  assert_true "新ラベルのenableが旧ラベル4本の移行より先に行われる" \
    "$([[ -n "$enable_line" && -n "$first_old_bootout_line" && "$enable_line" -lt "$first_old_bootout_line" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 11b. 移行: 新ラベルのenableが失敗した場合はexit 1になり、旧ラベルの移行は行われない ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${RETIRED_LABELS[0]}.plist"
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
  assert_eq "新ラベルのenable失敗はexit 1(FAIL)になる(以前は\`|| true\`で握り潰していた)" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "enable失敗のFAILメッセージが出る" \
    "$(echo "$err" | grep -q "enable failed" && echo 1 || echo 0)"
  assert_true "新ラベルのplist自体は生成されている(bootstrapは成功しているため)" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルはenable失敗より後の移行へ進まないため削除されず残る" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 12. 移行: 旧plistファイルは残っているが旧ラベルが一度もロードされていない場合、bootoutを試みずに安全にplistだけ削除する ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  TARGET_LABEL="${RETIRED_LABELS[2]}"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${TARGET_LABEL}.plist"
  echo "<!-- old plist stub (never loaded) -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$STUB_BIN/calls.log"
case "\$1" in
  print)
    case "\$*" in
      *${TARGET_LABEL}*) exit 1 ;;   # 対象ラベルへの照会は失敗＝確実に未ロード
      *) exit 0 ;;                   # domain自体への照会は成功（launchd自体は健全）
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
    "$(grep -qE "^bootout .*${TARGET_LABEL}" "$STUB_BIN/calls.log" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 13. 移行: launchdへの照会自体が機能していない(domain照会失敗)場合はfail-closedでplistを温存しexit 1になる ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/${RETIRED_LABELS[0]}.plist"
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
  assert_true "確認できなかった旨のWARNが出る(旧ラベル4本分)" \
    "$([[ "$(echo "$err" | grep -c "ロード状態をlaunchd照会で確認できませんでした")" -eq 4 ]] && echo 1 || echo 0)"
  assert_true "照会不能な場合はplistを削除せず温存する(誤って安全なplistを消さない)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "新ラベルのplistは正常に生成されている(旧ラベルの照会不能とは独立)" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 14. 移行: 旧plistファイルが元々無い状態でもdomain照会が失敗すればfail-closedでexit 1になる ==="
{
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

echo "=== 15. checkout破損: scripts/maintenance.shが見つからなければFAILする ==="
{
  FAKE_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/scripts" "$FAKE_REPO/scripts"
  cp -R "$REPO_ROOT/launchagents" "$FAKE_REPO/launchagents"
  rm -f "$FAKE_REPO/scripts/maintenance.sh"

  FAKE_HOME="$(mktemp -d)"
  rc=0
  HOME="$FAKE_HOME" bash "$FAKE_REPO/scripts/install-maintenance.sh" >/dev/null 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "scripts/maintenance.sh欠落はexit 1" "1" "$rc"
  assert_true "FAILメッセージが出る" \
    "$(grep -q "scripts/maintenance.sh が見つかりません" "$FAKE_HOME/stderr.log" && echo 1 || echo 0)"

  rm -rf "$FAKE_REPO" "$FAKE_HOME"
}

echo "=== 16. checkout破損: launchagents/com.takumi009.maintenance.plistが見つからなければFAILする ==="
{
  FAKE_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/scripts" "$FAKE_REPO/scripts"
  cp -R "$REPO_ROOT/launchagents" "$FAKE_REPO/launchagents"
  rm -f "$FAKE_REPO/launchagents/com.takumi009.maintenance.plist"

  FAKE_HOME="$(mktemp -d)"
  rc=0
  HOME="$FAKE_HOME" bash "$FAKE_REPO/scripts/install-maintenance.sh" >/dev/null 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "plistソース欠落はexit 1" "1" "$rc"
  assert_true "FAILメッセージが出る" \
    "$(grep -q "リポジトリのファイルが見つかりません" "$FAKE_HOME/stderr.log" && echo 1 || echo 0)"

  rm -rf "$FAKE_REPO" "$FAKE_HOME"
}

echo "=== 17. 再実行: 内容に変更が無くlaunchd上ロード済みなら bootout→bootstrap をスキップする ==="
{
  # SKIP_LAUNCHCTL=1では実際のロード状態を確認できないため、この経路は
  # SKIP_LAUNCHCTL=0＋偽launchctlで検証する（実launchdには一切触れない）。
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  print) exit 0 ;;   # domain照会・対象ラベル照会ともに成功＝ロード済み
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  # 1回目: 通常インストール（内容を書き込み、ロード済みにする）。
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1
  : > "$CALL_LOG"

  # 2回目: 同じSRCから再実行（内容は変わらない）。1回目のprintスタブが常に
  # 成功を返すため「ロード済み」と判定され、reloadがスキップされるはず。
  out="$(PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

  assert_true "スキップのログが出る" \
    "$(echo "$out" | grep -q "bootout/bootstrap をスキップします" && echo 1 || echo 0)"
  assert_true "2回目実行ではbootoutが呼ばれない" \
    "$(grep -qE "^bootout .*${NEW_LABEL}" "$CALL_LOG" && echo 0 || echo 1)"
  assert_true "2回目実行ではbootstrapが呼ばれない" \
    "$(grep -qE "^bootstrap " "$CALL_LOG" && echo 0 || echo 1)"
  assert_true "2回目実行でもenableは呼ばれる(disabled overrideの見逃し防止のため。Codexレビュー指摘Major対応)" \
    "$(grep -qE "^enable .*${NEW_LABEL}" "$CALL_LOG" && echo 1 || echo 0)"
  assert_true "新ラベルのplistは引き続き存在する" "$([[ -f "$DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 18. 移行: bootstrapが最初は失敗してもenable後の再試行で成功すれば正常完了する(disabled状態からの復旧) ==="
{
  # macOS launchdは対象ラベルがdisabled overrideに残っている場合、enableされる
  # までbootstrapが失敗し続けることがある既知の挙動があるため、1回だけの
  # enable→bootstrap再試行で復旧できることを検証する。
  # 「呼び出し回数」ではなく「enableが実際に実行されたこと」に依存させるため、
  # bootstrapはENABLED_MARKERファイルが存在する場合にのみ成功するスタブにする
  # （Codexレビュー指摘Minor対応・2026-07-16。回数ベースの旧版だと実装から
  # enable呼び出しを削除してもテストが通ってしまっていた）。
  FAKE_HOME="$(mktemp -d)"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  ENABLED_MARKER="$STUB_BIN/enabled.marker"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  bootstrap)
    # enableが実行された後(ENABLED_MARKERが存在する)場合のみ成功させる。
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

echo "=== 19. 再実行: 内容変更無し・ロード済みでもenableに失敗すればexit 1になる(disabled状態の見逃し防止) ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  print) exit 0 ;;
  bootstrap) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  # 1回目: 通常インストール（成功させ、ロード済みの状態を作る）。
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  # 2回目以降はenableだけ失敗させるスタブに差し替える（SKIP_RELOAD経路に
  # 入り、bootout/bootstrapは呼ばれずenableだけが呼ばれるはず）。
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$STUB_BIN/calls.log"
case "\$1" in
  print) exit 0 ;;
  enable) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  out="$(PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_eq "SKIP_RELOAD経路でもenable失敗はexit 1(FAIL)になる" "1" "$rc"
  assert_true "enable failedのFAILメッセージが出る" \
    "$(echo "$out" | grep -q "enable failed" && echo 1 || echo 0)"
  assert_true "SKIP_RELOAD経路のためbootstrapは呼ばれない" \
    "$(grep -qE '^bootstrap ' "$STUB_BIN/calls.log" && echo 0 || echo 1)"
  assert_true "SKIP_RELOAD経路のためbootoutは呼ばれない" \
    "$(grep -qE '^bootout ' "$STUB_BIN/calls.log" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 20. 再実行: 内容変更無しでもdomain照会不能(unknown)なら破壊的reloadに進まずfail-closedでexit 1になる ==="
{
  # 内容が同一でもロード状態が確認できない場合、素朴にbootout→bootstrapへ
  # 進むと健全なジョブを誤って止めてしまう恐れがある（Codexレビュー指摘
  # Major対応・2026-07-16）。
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  print) exit 0 ;;
  bootstrap) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  # 1回目: 通常インストール（成功させ、ロード済みの状態を作る）。
  PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  # 2回目以降はdomain照会そのものが失敗するスタブに差し替える。
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  print) exit 1 ;;   # domain自体への照会も失敗＝unknown
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  out="$(PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_eq "内容同一でもunknownならexit 1(fail-closed)" "1" "$rc"
  assert_true "ロード状態確認不能の旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q "ロード状態をlaunchd照会で確認できませんでした" && echo 1 || echo 0)"
  assert_true "unknown判定時はbootoutが一切呼ばれない(既存ジョブに触れない)" \
    "$(grep -qE '^bootout ' "$CALL_LOG" && echo 0 || echo 1)"
  assert_true "unknown判定時はbootstrapが一切呼ばれない" \
    "$(grep -qE '^bootstrap ' "$CALL_LOG" && echo 0 || echo 1)"
  assert_true "unknown判定時は旧ラベルの移行にも一切進まない" \
    "$(grep -qE '^bootout .*vault-inventory' "$CALL_LOG" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
