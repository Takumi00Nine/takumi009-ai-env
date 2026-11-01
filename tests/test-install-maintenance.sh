#!/usr/bin/env bash
# 一時 HOME と偽 launchctl で dry-run・plist 生成を確認する。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/assembly/install-maintenance.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

NEW_LABEL="$(plutil -extract Label raw -o - "$REPO_ROOT"/ai-brain/assembly/com.takumi009.maintenance.plist)"

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
  PATH="$FAKE_BIN:$PATH" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 HOME="$1" bash "$SCRIPT" "${@:2}"
}

echo "=== dry-run は変更しない ==="
FAKE_HOME="$(mktemp -d)"
out="$(run_install_skip "$FAKE_HOME" --dry-run)"
assert_true "dry-run で配置せず launchctl も呼ばない" \
  "$([[ "$out" == *'would generate'* && ! -e "$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist" && ! -s "$FAKE_LAUNCHCTL_LOG" ]] && echo 1 || echo 0)"
rm -rf "$FAKE_HOME"

echo "=== plist を生成する ==="
FAKE_HOME="$(mktemp -d)"
rc=0
run_install_skip "$FAKE_HOME" >/dev/null || rc=$?
DEST="$FAKE_HOME/Library/LaunchAgents/${NEW_LABEL}.plist"
assert_true "正常終了し plist を配置、launchctl は呼ばない" \
  "$([[ "$rc" -eq 0 && -f "$DEST" && ! -s "$FAKE_LAUNCHCTL_LOG" ]] && echo 1 || echo 0)"
assert_true "HOME を現行配置へ置換し、有効な plist を生成する" \
  "$(python3 - "$DEST" "$FAKE_HOME" "$NEW_LABEL" <<'PY'
import plistlib,sys
p,home,label=sys.argv[1:]
with open(p,'rb') as f: d=plistlib.load(f)
assert d['Label']==label
assert home+'/Workspace/Tools/takumi009-ai-env/ai-brain/executor/maintenance.sh' in d['ProgramArguments']
assert '__AIENV_' not in open(p).read()
PY
  [ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_true "実行環境の HOME・USER を設定する" \
  "$(python3 - "$DEST" "$FAKE_HOME" "$(id -un)" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: env=plistlib.load(f)['EnvironmentVariables']
assert env['HOME']==sys.argv[2] and env['USER']==sys.argv[3]
PY
  [ "$?" -eq 0 ] && echo 1 || echo 0)"
before="$(shasum -a 256 "$DEST")"
rc=0; run_install_skip "$FAKE_HOME" >/dev/null || rc=$?
assert_true "再実行しても配置を壊さない" \
  "$([[ "$rc" -eq 0 && "$before" == "$(shasum -a 256 "$DEST")" && ! -s "$FAKE_LAUNCHCTL_LOG" ]] && echo 1 || echo 0)"
rm -rf "$FAKE_HOME"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
