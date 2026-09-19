#!/usr/bin/env bash
# scripts/install-usage-fetch.sh のユニットテスト（bootstrap+enable だけの
# 直線 installer。設計＝ai-env 全体最適化 着手順1 設計 §6.4 U-1〜U-7）。
#
# ⚠️ 実 launchd には一切触れない。PATH 先頭の偽 launchctl が状態
# （$LCTL_STATE/loaded/<label>）をファイルで持ち、print/bootout/bootstrap/
# enable に応答する。呼び出し履歴は $LCTL_STATE/calls.log に残す。
#
# 実行方法: bash tests/test-install-usage-fetch.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-usage-fetch.sh"
PLIST_SRC="$REPO_ROOT/launchagents/com.takumi009.usage-fetch.plist"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}

FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT

# --- 偽 launchctl（print/bootout/bootstrap/enable。状態は $LCTL_STATE） ---
cat > "$FAKE_BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
: "${LCTL_STATE:?LCTL_STATE not set}"
mkdir -p "$LCTL_STATE/loaded" 2>/dev/null
echo "$1" >> "$LCTL_STATE/calls.log"
case "$1" in
  print)
    case "$2" in
      gui/*/*) label="${2#gui/*/}"; [ -f "$LCTL_STATE/loaded/$label" ] && exit 0 || exit 1 ;;
      gui/*) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  bootout)
    rm -f "$LCTL_STATE/loaded/${2##*/}"
    exit 0
    ;;
  bootstrap)
    [ -f "$LCTL_STATE/fail_bootstrap" ] && exit 1
    label="$(plutil -extract Label raw -o - "$3" 2>/dev/null)"
    [ -n "$label" ] || exit 1
    : > "$LCTL_STATE/loaded/$label"
    exit 0
    ;;
  enable)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$FAKE_BIN/launchctl"
PATH="$FAKE_BIN:$PATH"
hash -r

NEW_LABEL="$(plutil -extract Label raw -o - "$PLIST_SRC")"
OLD_LABEL="com.claude-codex-usage.refresh"

# --- fixture ---
new_env() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home" "$d/lctl"
  echo "$d"
}
run_install() {
  local d="$1"; shift
  HOME="$d/home" LCTL_STATE="$d/lctl" bash "$SCRIPT" "$@"
}
new_plist_path() { echo "$1/home/Library/LaunchAgents/${NEW_LABEL}.plist"; }
calls() { [ -f "$1/lctl/calls.log" ] && cat "$1/lctl/calls.log" || true; }
# bootout/bootstrap/enable の呼び出し回数（print は数えない）
mutating_calls() { calls "$1" | grep -c -E '^(bootout|bootstrap|enable)$'; }
loaded() { [ -f "$1/lctl/loaded/$2" ] && echo 1 || echo 0; }

echo "=== U-1: --dry-run は plist を置かず bootout/bootstrap/enable を呼ばない ==="
{
  E="$(new_env)"
  out="$(run_install "$E" --dry-run 2>&1)"
  rc=$?
  assert_eq "dry-run: exit=0" "0" "$rc"
  assert_true "dry-run: plist を置かない" "$([ ! -e "$(new_plist_path "$E")" ] && echo 1 || echo 0)"
  assert_eq "dry-run: 変更系の launchctl 呼び出しが 0" "0" "$(mutating_calls "$E")"
  assert_true "dry-run: 旧ジョブの状態を 1 行表示する" "$([ "$(printf '%s\n' "$out" | grep -c '旧')" = "1" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== U-2: 新規導入。plist の内容が SRC の __AIENV_HOME__ 置換と一致・bootstrap→enable の順・exit 0 ==="
{
  E="$(new_env)"
  out="$(run_install "$E" 2>&1)"
  rc=$?
  assert_eq "新規: exit=0" "0" "$rc"
  assert_true "新規: plist が置かれる" "$([ -f "$(new_plist_path "$E")" ] && echo 1 || echo 0)"
  expected="$(mktemp)"
  sed "s#__AIENV_HOME__#$E/home#g" "$PLIST_SRC" > "$expected"
  assert_true "新規: plist の内容が置換後の SRC と一致" "$(cmp -s "$expected" "$(new_plist_path "$E")" && echo 1 || echo 0)"
  rm -f "$expected"
  assert_true "新規: 呼び出し順が bootstrap→enable" \
    "$(calls "$E" | grep -E '^(bootstrap|enable)$' | tr '\n' ' ' | grep -q '^bootstrap enable ' && echo 1 || echo 0)"
  assert_eq "新規: 新ラベルが loaded" "1" "$(loaded "$E" "$NEW_LABEL")"
  rm -rf "$E"
}

echo "=== U-3: 再実行。exit 0・plist は 1 つ ==="
{
  E="$(new_env)"
  run_install "$E" >/dev/null 2>&1
  out="$(run_install "$E" 2>&1)"
  rc=$?
  assert_eq "再実行: exit=0" "0" "$rc"
  n="$(ls "$E/home/Library/LaunchAgents" | wc -l | tr -d ' ')"
  assert_eq "再実行: LaunchAgents 配下のファイルは 1 つ（一時ファイルを残さない）" "1" "$n"
  assert_eq "再実行: 新ラベルが loaded のまま" "1" "$(loaded "$E" "$NEW_LABEL")"
  rm -rf "$E"
}

echo "=== U-4: 旧ラベルが loaded なら exit 1・FAIL 1 行に旧ラベル名・plist を置かない・bootstrap しない ==="
{
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$OLD_LABEL"
  err="$(run_install "$E" 2>&1 >/dev/null)"
  rc=$?
  assert_eq "旧残存: exit=1" "1" "$rc"
  assert_eq "旧残存: stderr の FAIL 行は 1 行" "1" "$(printf '%s\n' "$err" | grep -c 'FAIL:')"
  assert_true "旧残存: FAIL 行が旧ラベル名を含む" "$(printf '%s\n' "$err" | grep 'FAIL:' | grep -q "$OLD_LABEL" && echo 1 || echo 0)"
  assert_true "旧残存: plist を置かない" "$([ ! -e "$(new_plist_path "$E")" ] && echo 1 || echo 0)"
  assert_eq "旧残存: 変更系の launchctl 呼び出しが 0" "0" "$(mutating_calls "$E")"
  # --dry-run は「本実行は FAIL する」と表示して exit 0
  out="$(run_install "$E" --dry-run 2>&1)"
  rc=$?
  assert_eq "旧残存 dry-run: exit=0" "0" "$rc"
  assert_true "旧残存 dry-run: FAIL 予告を表示" "$(printf '%s\n' "$out" | grep -q 'FAIL' && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== U-5: SKIP_LAUNCHCTL=1 は plist を置き launchctl を 0 回 ==="
{
  E="$(new_env)"
  out="$(SKIP_LAUNCHCTL=1 run_install "$E" 2>&1)"
  rc=$?
  assert_eq "SKIP: exit=0" "0" "$rc"
  assert_true "SKIP: plist が置かれる" "$([ -f "$(new_plist_path "$E")" ] && echo 1 || echo 0)"
  assert_eq "SKIP: launchctl の呼び出しが 0（print 含む）" "0" "$(calls "$E" | grep -c .)"
  rm -rf "$E"
}

echo "=== U-6: 未知の引数は exit 1 ==="
{
  E="$(new_env)"
  run_install "$E" --bogus >/dev/null 2>&1
  rc=$?
  assert_eq "未知引数: exit=1" "1" "$rc"
  assert_true "未知引数: plist を置かない" "$([ ! -e "$(new_plist_path "$E")" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== U-7: bootstrap が失敗し続けると exit 1・FAIL 行に launchctl bootstrap ==="
{
  E="$(new_env)"
  : > "$E/lctl/fail_bootstrap"
  err="$(run_install "$E" 2>&1 >/dev/null)"
  rc=$?
  assert_eq "bootstrap 失敗: exit=1" "1" "$rc"
  assert_true "bootstrap 失敗: FAIL 行に launchctl bootstrap を含む" \
    "$(printf '%s\n' "$err" | grep 'FAIL:' | grep -q 'launchctl bootstrap' && echo 1 || echo 0)"
  assert_true "bootstrap 失敗: enable 経由で再試行している（bootstrap が 2 回）" \
    "$([ "$(calls "$E" | grep -c '^bootstrap$')" = "2" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
