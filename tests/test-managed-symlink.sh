#!/usr/bin/env bash
# tests/test-managed-symlink.sh
#
# scripts/lib/managed-symlink.sh の sync_managed_symlink() を直接 source して
# 検査する（2026-09-19 着手順3・設計 §4.4）。install-main.sh・update-sub.sh・
# check-drift.sh の各テストに散っていた「symlink 同期」の重複ケースをここ 1 本に
# 統合し、代表 1 件ずつ 5 ケースだけ置く（テストはラフに＝Decision 2026-09-17）。
#   1. 正常 link（dest 不在）
#   2. 実ファイル退避（.pre-aienv.bak → 内容が違えば .pre-aienv.bak.<ts>）
#   3. dangling symlink の付け替え（退避しない）
#   4. 他所を向く symlink の付け替え（退避しない・向き先の実体は無傷）
#   5. 再実行の冪等（既に正しい symlink なら backup を増やさない）
# 一時ディレクトリだけを触る（実 $HOME・launchd には一切触れない）。
#
# 実行方法: bash tests/test-managed-symlink.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/managed-symlink.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

# 共有 lib を直接 source する（呼び出し元スクリプトの log() 等に依存しない設計）。
# shellcheck source=../scripts/lib/managed-symlink.sh
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

# extra_backups <dest> — .pre-aienv.bak.<ts>（追加 backup）の個数。
extra_backups() {
  local n=0 f
  for f in "$1".pre-aienv.bak.*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

echo "=== 1. 正常 link: dest が無ければ src を指す symlink を作り linked を出す ==="
{
  make_fixture
  out="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  assert_eq "dest は symlink" "1" "$([[ -L "$DEST" ]] && echo 1 || echo 0)"
  assert_eq "向き先が src" "$SRC" "$(readlink "$DEST")"
  assert_contains "linked 行が log_prefix 付きで出る" "$out" "[t-lib] linked: $DEST -> $SRC"
  assert_not_contains "退避は起きない" "$out" "backed up"
  rm -rf "$WORK"
}

echo "=== 2. 実ファイル退避: 通常ファイルは .pre-aienv.bak へ退避してから symlink 化し、既存 bak と内容が違えば .pre-aienv.bak.<ts> を足す ==="
{
  make_fixture
  echo 'original user file' > "$DEST"
  out="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  assert_contains "backed up 行が出る" "$out" "backed up: $DEST -> $DEST.pre-aienv.bak"
  assert_eq ".pre-aienv.bak に元の内容が残る" "original user file" "$(cat "$DEST.pre-aienv.bak")"
  assert_eq "dest は symlink になる" "1" "$([[ -L "$DEST" ]] && echo 1 || echo 0)"
  # 2 回目: dest が再び通常ファイル（内容は bak と異なる）→ 追加 backup
  rm -f "$DEST"
  echo 'second user file' > "$DEST"
  out2="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  assert_contains "内容が異なるので追加保存の行が出る" "$out2" "既存の.pre-aienv.bakと内容が異なる通常ファイルのため追加保存"
  assert_eq "最初の .pre-aienv.bak は上書きされない" "original user file" "$(cat "$DEST.pre-aienv.bak")"
  assert_eq "追加 backup が 1 件できる" "1" "$(extra_backups "$DEST")"
  rm -rf "$WORK"
}

echo "=== 3. dangling symlink: 壊れた symlink は退避せず src へ付け替える ==="
{
  make_fixture
  ln -s "$WORK/nowhere/gone.sh" "$DEST"
  out="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  assert_eq "向き先が src に付け替わる" "$SRC" "$(readlink "$DEST")"
  assert_not_contains "退避は起きない" "$out" "backed up"
  assert_eq ".pre-aienv.bak は作られない" "0" "$([[ -e "$DEST.pre-aienv.bak" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 4. 他所を向く symlink: 別の実体を指す symlink は退避せず付け替え、向き先の実体は無傷 ==="
{
  make_fixture
  echo 'elsewhere content' > "$WORK/elsewhere.sh"
  ln -s "$WORK/elsewhere.sh" "$DEST"
  out="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  assert_eq "向き先が src に付け替わる" "$SRC" "$(readlink "$DEST")"
  assert_not_contains "退避は起きない" "$out" "backed up"
  assert_eq "旧向き先の実体は無傷" "elsewhere content" "$(cat "$WORK/elsewhere.sh")"
  rm -rf "$WORK"
}

echo "=== 5. 冪等: 既に正しい symlink なら再実行しても backup を増やさず linked だけ出す ==="
{
  make_fixture
  echo 'original user file' > "$DEST"
  sync_managed_symlink "$SRC" "$DEST" "t-lib" >/dev/null
  out="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  out2="$(sync_managed_symlink "$SRC" "$DEST" "t-lib")"
  assert_contains "再実行でも linked 行は出る" "$out2" "[t-lib] linked:"
  assert_not_contains "再実行で退避は起きない" "$out$out2" "backed up"
  assert_eq "追加 backup は 0 件のまま" "0" "$(extra_backups "$DEST")"
  assert_eq "向き先は src のまま" "$SRC" "$(readlink "$DEST")"
  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
