#!/usr/bin/env bash
# scripts/install-sub.sh のユニットテスト。
#
# 実 ~/.claude・~/.codex・実Vaultには一切依存しない。HOME環境変数を
# 毎回ダミーのfixtureディレクトリへ差し替えてスクリプトを実行し、
# Vault骨格配置・claude/codex symlink化の委譲が正しく行われることを検証する。
#
# 注意: install-sub.sh は末尾でサブ専用LaunchAgent（update-sub.plist）の
# launchctl bootstrap を行うが、gui/$(id -u) は実launchdセッションでありHOME差し替え
# では隔離できないため、非dry-run呼び出しには必ず SKIP_LAUNCHCTL=1 を付けて
# 実システムのlaunchdに触れないようにする（発見の経緯: 実装中に一度SKIP無しで
# テストを回し、実launchdに一時ディレクトリを指すゴミ登録をしてしまい
# `launchctl bootout` で手動クリーンアップした。以後この対策を導入）。
# install-sub.sh は install-main.sh へ `--sub-delegate` を付けて委譲する。
# 週次drift通知LaunchAgent（com.takumi009.drift-check.plist）は2026-07-16簡素化で
# install-main.sh自体から撤去済み（メイン/サブ問わず誰も設置しない。旧・メイン専用
# skip実装＝H-2は撤去に伴い不要化した）。SKIP_LAUNCHCTL=1 は install-main.sh側の
# 環境にも引き継がれる（同名の環境変数を採用しているため）。
# 同様に install-sub.sh は install-main.sh 経由で scripts/setup-codex-mcp.sh も
# 呼ぶため、実 claude/codex CLI がPATH上にある開発機でテストを走らせた場合の
# 実MCP登録への副作用を避けるため SKIP_CODEX_MCP=1 も併せて付ける
# （Codexレビュー指摘・Major）。
#
# 実行方法: bash tests/test-install-sub.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-sub.sh"

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

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

echo "=== 1. dry-run: 実際の変更を一切しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "dry-run出力にwould copyが含まれる" \
    "$(echo "$out" | grep -q 'would copy' && echo 1 || echo 0)"
  assert_true "Vaultが実際には作られていない" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian" ]] && echo 1 || echo 0)"
  assert_true "settings.jsonが実際にはsymlink化されていない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. Vault未存在: vault-public/の中身が骨格として配置される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_true "Preferencesの中身がコピーされている（absolute-rules.md存在）" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"
  for dir in Personal Knowledge Decisions Projects Fragments Explorations Blogs; do
    n=$(find "$FAKE_HOME/Data/obsidian/$dir" -mindepth 1 -not -name '.DS_Store' | wc -l | tr -d ' ')
    assert_eq "$dir はREADME.mdのみ（ファイル数1）" "1" "$n"
  done

  rm -rf "$FAKE_HOME"
}

echo "=== 3. Vault既存: 骨格配置をskipし、既存の中身を上書きしない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Data/obsidian"
  echo "existing private note" > "$FAKE_HOME/Data/obsidian/my-note.md"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")
  assert_true "skipしますのメッセージが出る" \
    "$(echo "$out" | grep -q 'skipします' && echo 1 || echo 0)"
  assert_eq "既存ファイルの中身が変わっていない" "existing private note" \
    "$(cat "$FAKE_HOME/Data/obsidian/my-note.md")"
  assert_true "vault-publicのPreferencesが誤って混ざっていない" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian/Preferences" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. claude/・codex/ の symlink化が install-main.sh 経由で行われる ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_eq "settings.jsonがrepoへのsymlinkになっている" "$REPO_ROOT/claude/settings.json" \
    "$(readlink "$FAKE_HOME/.claude/settings.json")"
  assert_true "config.tomlが生成されている（symlinkではなく実ファイル）" \
    "$([[ -f "$FAKE_HOME/.codex/config.toml" && ! -L "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 5. メイン専用LaunchAgent類はインストールされない（サブ専用のupdate-subだけ入る） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  for name in backup-vault vault-inventory fragments-log drift-check; do
    assert_true "メイン専用の $name.plist は入らない" \
      "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.$name.plist" ]] && echo 1 || echo 0)"
  done
  assert_true "サブ専用のupdate-sub.plistは入る" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/com.takumi009.update-sub.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 5b. update-sub.plist: RunAtLoad=false・プレースホルダ置換・構文が正しい ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.update-sub.plist"
  assert_true "RunAtLoadがfalse" \
    "$(awk '/<key>RunAtLoad<\/key>/{getline; print; exit}' "$DEST" | tr -d '[:space:]' | grep -q '<false/>' && echo 1 || echo 0)"
  assert_true "__AIENV_HOME__が実HOMEへ置換されている" \
    "$(grep -q "$FAKE_HOME/work/takumi009-ai-env/scripts/update-sub.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "プレースホルダが残っていない" \
    "$(grep -q '__AIENV_HOME__' "$DEST" && echo 0 || echo 1)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "plutil -lint OK" \
      "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 6. 冪等性: 2回実行してもエラーにならず状態が壊れない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null
  rc=0
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"
  assert_true "2回目もVaultのPreferencesは健在" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 7. update-sub.plistのbootstrap失敗時、FAILメッセージが本来の内容で出る(unbound variableで握り潰されない・2026-07-16発見の実バグ回帰テスト) ==="
{
  # scripts/install-backup.shのテスト実装中に発見した実バグの回帰テスト:
  # bash 3.2(macOS既定)+ja_JP.UTF-8ロケール環境で、fail()メッセージ内の裸の
  # $SUB_UPDATE_DEST直後に全角の閉じ括弧（）が続いていたため、変数名の境界を
  # 誤認識し「unbound variable」でクラッシュし本来のFAILメッセージが一切
  # 表示されない欠陥があった（${SUB_UPDATE_DEST}と波括弧で囲んで修正済み）。
  # 実launchdには一切触れず、PATH先頭に「bootstrapだけ失敗する」偽launchctlを
  # 差し込んで再現する。
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  bootstrap) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  # LANG/LC_ALLを明示的にja_JP.UTF-8にする（元バグはこのロケール下でのみ再現する
  # ため、CI等の別ロケール環境でも確実にこの回帰を検出できるようにする）。
  rc=0
  PATH="$STUB_BIN:$PATH" LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" \
    >/dev/null 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "bootstrap失敗はexit 1(FAIL)になる" "1" "$rc"

  # 「本来のFAILメッセージが出るか」だけをassertする（バグが再発した場合は
  # このメッセージ自体が出力されないため、これだけで両状態を確実に判別できる）。
  # 「'unbound variable'という文字列が出ていないこと」は当初あわせてassertしよう
  # としたが撤回した: 実測の結果、この壊れた出力（不正なUTF-8継続バイトを含む
  # 行）に対してgrepは`-a`（テキスト強制）付きでも安定して非マッチを返す
  # （BSD grep 2.6.0で確認・macOS既定）ため、その方向のassertionは「バグが
  # 再発しても常にpassしてしまう」誤った安心を生む。文字列一致に頼らない
  # 唯一信頼できる判定は上記のexit code・メッセージ有無のみ。
  assert_true "'unbound variable'クラッシュでは落ちず本来のFAILメッセージが出る" \
    "$(grep -a -q "bootstrap failed for" "$FAKE_HOME/stderr.log" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 8. 移行: 旧ラベル(com.takumi009.sub-update)のplistが残っていれば新ラベル設置後に削除される（2026-07-16簡素化・設計書§5命名規則統一・PR3残確認で発見した見落としのリーダー裁定対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")
  NEW_DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.update-sub.plist"
  assert_true "新ラベルのplistが生成される" "$([[ -f "$NEW_DEST" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルのplistは削除される" "$([[ ! -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "移行検出のログメッセージが出る" \
    "$(echo "$out" | grep -q "旧ラベル（com.takumi009.sub-update）を検出" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 9. 移行: 旧plistファイルは既に無いが旧ラベルがlaunchd上にロード済みの場合も検出しbootoutを試みる ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALL_LOG"
case "\$1" in
  print) exit 0 ;;
  bootstrap) exit 0 ;;
  bootout) exit 0 ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >"$FAKE_HOME/stdout.log" 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "旧plistファイルが無くてもlaunchd上ロード済みなら移行検出のログが出る" \
    "$(echo "$out" | grep -q "旧ラベル（com.takumi009.sub-update）を検出" && echo 1 || echo 0)"
  assert_true "旧ラベルへbootoutも実行される" \
    "$(grep -qE "^bootout .*sub-update" "$CALL_LOG" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 10. 移行: 旧ラベルのbootoutに失敗した場合はplistを削除せず、スクリプト全体の終了コードも非0にする ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  bootout)
    case "$*" in
      *sub-update*) exit 1 ;;
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
  PATH="$STUB_BIN:$PATH" SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" \
    >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "旧ラベルのbootout失敗はスクリプト全体の終了コードを非0にする" "1" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "新ラベルのplistは(旧ラベルの後片付け失敗とは無関係に)生成されている" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/com.takumi009.update-sub.plist" ]] && echo 1 || echo 0)"
  assert_true "'done.'ログは出る(新ラベル設置自体は成功しているため)" \
    "$(echo "$out" | grep -q '\[install-sub\] done\.' && echo 1 || echo 0)"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "bootout失敗のWARNメッセージが出る" \
    "$(echo "$err" | grep -q "旧ラベル（com.takumi009.sub-update）のbootoutに失敗しました" && echo 1 || echo 0)"
  assert_true "bootoutに失敗した旧plistは削除されず残る(次回再試行のため)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 10b. 移行: 旧plistファイルは残っているが旧ラベルが一度もロードされていない場合、bootoutを試みずに安全にplistだけ削除する（Codexレビュー指摘Minor対応: not_loaded分岐の単体検証が無かった） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist"
  echo "<!-- old plist stub (never loaded) -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  CALL_LOG="$STUB_BIN/calls.log"
  cat > "$STUB_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "STUB_CALL_LOG_PLACEHOLDER"
case "$1" in
  print)
    case "$*" in
      *sub-update*) exit 1 ;;   # 旧ラベルへの照会は失敗＝確実に未ロード
      *) exit 0 ;;              # domain自体への照会は成功（launchd自体は健全）
    esac
    ;;
  *) exit 0 ;;
esac
EOF
  sed -i '' "s#STUB_CALL_LOG_PLACEHOLDER#$CALL_LOG#" "$STUB_BIN/launchctl"
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" \
    >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "未ロードのplist削除は成功しexit 0のまま" "0" "$rc"

  out="$(cat "$FAKE_HOME/stdout.log")"
  assert_true "「元々ロードされていませんでした」のログが出る" \
    "$(echo "$out" | grep -q "元々ロードされていませんでした" && echo 1 || echo 0)"
  assert_true "旧plistは削除される" "$([[ ! -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "旧ラベルへのbootoutは一切呼ばれない(未ロードと分かっているので不要)" \
    "$(grep -qE "^bootout .*sub-update" "$CALL_LOG" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 11. 移行: launchdへの照会自体が機能していない(domain照会失敗)場合はfail-closedでplistを温存しexit 1になる ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  print) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" \
    >"$FAKE_HOME/stdout.log" 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "照会不能はexit 1(fail-closed)" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "確認できなかった旨のWARNが出る" \
    "$(echo "$err" | grep -q "ロード状態をlaunchd照会で確認できませんでした" && echo 1 || echo 0)"
  assert_true "照会不能な場合はplistを削除せず温存する(誤って安全なplistを消さない)" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"
  assert_true "新ラベルのplistは正常に生成されている(旧ラベルの照会不能とは独立)" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/com.takumi009.update-sub.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 12. 新ラベルのenableが失敗した場合はexit 1になる(以前は\`|| true\`で握り潰していた・install-backup.shで確立した方式の横展開) ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  OLD_DEST="$FAKE_HOME/Library/LaunchAgents/com.takumi009.sub-update.plist"
  echo "<!-- old plist stub -->" > "$OLD_DEST"

  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  enable) exit 1 ;;
  bootstrap) exit 0 ;;
  bootout) exit 0 ;;
  print) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"

  rc=0
  PATH="$STUB_BIN:$PATH" SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" \
    >/dev/null 2>"$FAKE_HOME/stderr.log" || rc=$?
  assert_eq "新ラベルのenable失敗はexit 1(FAIL)になる" "1" "$rc"

  err="$(cat "$FAKE_HOME/stderr.log")"
  assert_true "enable失敗のFAILメッセージが出る" \
    "$(echo "$err" | grep -q "enable failed" && echo 1 || echo 0)"
  assert_true "旧ラベルはenable失敗より後の移行へ進まないため削除されず残る" \
    "$([[ -e "$OLD_DEST" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo "=== 13. bootstrapが最初は失敗してもenable後の再試行で成功すれば正常完了する(disabled状態からの復旧・install-backup.shで確立した方式の横展開) ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  STUB_BIN="$(mktemp -d)"
  ENABLED_MARKER="$STUB_BIN/enabled.marker"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
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
  out="$(PATH="$STUB_BIN:$PATH" SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_eq "disabled復旧の再試行が成功すればexit 0" "0" "$rc"
  assert_true "1回目bootstrap失敗のWARNログが出る" \
    "$(echo "$out" | grep -q "disabled状態の可能性があるため" && echo 1 || echo 0)"
  assert_true "enableが実際に実行されたことを介してbootstrapが成功している(回数だけの偶然ではない)" \
    "$([[ -e "$ENABLED_MARKER" ]] && echo 1 || echo 0)"
  assert_true "新ラベルのplistが生成されている" \
    "$([[ -f "$FAKE_HOME/Library/LaunchAgents/com.takumi009.update-sub.plist" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
