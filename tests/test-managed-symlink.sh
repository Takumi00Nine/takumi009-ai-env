#!/usr/bin/env bash
# 管理リンクの新規作成と既存ファイルの退避。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/core/assembly/managed-symlink.sh"

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

# 共有 lib を直接 source する（呼び出し元スクリプトの log() 等に依存しない設計）。
# shellcheck source=../core/assembly/managed-symlink.sh
source "$LIB"

# make_fixture — src（repo 側の実体）と dest の親ディレクトリを一時領域に作る。
# 呼び出し後 SRC / DEST / WORK が使える。
make_fixture() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/repo" "$WORK/home/.claude/hooks"
  SRC="$WORK/repo/hook.sh"
  DEST="$WORK/home/.claude/hooks/hook.sh"
  echo '#!/bin/bash' > "$SRC"
}
echo "=== link 作成 ==="
make_fixture
sync_managed_symlink "$SRC" "$DEST" t-lib >/dev/null
assert_eq "dest は src への symlink" "$SRC" "$(readlink "$DEST")"
assert_eq "新規作成では退避しない" "0" "$([ -e "$DEST.pre-aienv.bak" ] && echo 1 || echo 0)"
rm -rf "$WORK"

echo "=== 既存ファイルを退避する ==="
make_fixture
echo 'original user file' > "$DEST"
sync_managed_symlink "$SRC" "$DEST" t-lib >/dev/null
assert_eq "dest は src への symlink" "$SRC" "$(readlink "$DEST")"
assert_eq "退避に元の内容が残る" "original user file" "$(cat "$DEST.pre-aienv.bak")"
rm -rf "$WORK"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
