#!/usr/bin/env bash
# 一時 HOME と偽 launchctl で dry-run・導入を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/usage/assembly/install-usage-fetch.sh"
PLIST_SRC="$REPO_ROOT/usage/assembly/com.takumi009.usage-fetch.plist"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}

FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT

# 実 launchd を呼ばない偽コマンド。
printf '#!/bin/bash\necho called >> "%s"\nexit 1\n' "$FAKE_BIN/calls" > "$FAKE_BIN/launchctl"
chmod +x "$FAKE_BIN/launchctl"
export PATH="$FAKE_BIN:$PATH" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1
NEW_LABEL="$(plutil -extract Label raw -o - "$PLIST_SRC")"
E="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN" "$E"' EXIT
mkdir -p "$E/home"
rc=0
HOME="$E/home" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || rc=$?
assert_true "dry-run は HOME を変更しない" "$([[ "$rc" -eq 0 && -z "$(ls -A "$E/home")" && ! -s "$FAKE_BIN/calls" ]] && echo 1 || echo 0)"
rc=0
HOME="$E/home" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
DEST="$E/home/Library/LaunchAgents/${NEW_LABEL}.plist"
assert_true "正常終了し plist を配置する" "$([[ "$rc" -eq 0 && -f "$DEST" ]] && echo 1 || echo 0)"
assert_true "plist のラベル・実行先が有効" "$(python3 - "$DEST" "$E/home" "$NEW_LABEL" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: d=plistlib.load(f)
assert d['Label']==sys.argv[3]
assert any(a.startswith(sys.argv[2]+'/') and a.endswith('/usage-fetch.sh') for a in d['ProgramArguments'])
assert '__AIENV_HOME__' not in open(sys.argv[1]).read()
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_true "launchctl を呼ばない" "$([ ! -s "$FAKE_BIN/calls" ] && echo 1 || echo 0)"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
