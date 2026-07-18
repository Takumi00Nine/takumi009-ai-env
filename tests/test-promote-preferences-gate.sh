#!/usr/bin/env bash
# scripts/vault-agents/promote-preferences-gate.sh のユニットテスト（maintenance_apply.py
# のPROMOTE(target_folder=Preferences)書込前ゲート＝設計書§2.4改訂v2）。
#
# scripts/lib/personal-link-check.sh（export-public-vault.sh/audit.shと共有）を
# そのまま再利用しているため、ここでは「候補ノート1件のテキストファイル」という
# 本スクリプト固有の入出力契約（--text-file・終了コード0/1/2）のみを検証する
# （個々の正規表現の詳細な単体テストはtests/test-personal-link-check.shの役目）。
#
# 実HOMEには依存しない。
#
# 実行方法: bash tests/test-promote-preferences-gate.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/promote-preferences-gate.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}

setup() {
  VAULT="$(mktemp -d)"; mkdir -p "$VAULT/Personal"
  echo "dummy" > "$VAULT/Personal/career-private.md"
  NGWORDS="$(mktemp)"; echo "himitsuword" > "$NGWORDS"
  TXT="$(mktemp)"
}

echo "=== 1. Personalフォルダ付きwiki linkを検出したらexit 1 ==="
{
  setup
  printf '本文\n[[Personal/career-private]] への参照\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "$TXT" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 1" "1" "$rc"
  assert_contains "DETECTEDメッセージ" "$out" "DETECTED"
}

echo "=== 2. Personalノートへのbasename形式wiki linkを検出したらexit 1 ==="
{
  setup
  printf '本文\n[[career-private]] への参照（フォルダ省略）\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "$TXT" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 1" "1" "$rc"
}

echo "=== 3. NGワードを検出したらexit 1 ==="
{
  setup
  printf '本文にhimitsuwordが混入\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "$TXT" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 1" "1" "$rc"
}

echo "=== 4. 検出なしのクリーンな本文はexit 0 ==="
{
  setup
  printf 'クリーンな本文（Personalリンクもngwordsも含まない）\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "$TXT" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_contains "OKメッセージ" "$out" "OK"
}

echo "=== 5. Knowledge/Decisions等の非Personalフォルダへのリンクは検出対象外（誤検知しない） ==="
{
  setup
  printf '本文\n[[Knowledge/some-note]] への参照\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "$TXT" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 0（Knowledgeリンクは対象外）" "0" "$rc"
}

echo "=== 6. --vaultが不正（存在しない）ならexit 2（fail-closed） ==="
{
  setup
  printf 'クリーンな本文\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "/no/such/dir" --text-file "$TXT" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_contains "ERRORメッセージ" "$out" "ERROR"
}

echo "=== 7. ngwords.txtが見つからないならexit 2（fail-closed） ==="
{
  setup
  printf 'クリーンな本文\n' > "$TXT"
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "$TXT" --ngwords-file "/no/such/ngwords.txt" 2>&1)"; rc=$?
  assert_eq "exit 2" "2" "$rc"
}

echo "=== 8. --text-fileが存在しないならexit 2（fail-closed） ==="
{
  setup
  out="$(bash "$SCRIPT" --vault "$VAULT" --text-file "/no/such/file.md" --ngwords-file "$NGWORDS" 2>&1)"; rc=$?
  assert_eq "exit 2" "2" "$rc"
}

echo "=== 9. Personalフォルダが空でも他チェックは正常に動く（denylistが空になるだけ） ==="
{
  VAULT2="$(mktemp -d)"; mkdir -p "$VAULT2/Personal"
  NG2="$(mktemp)"; echo "himitsuword" > "$NG2"
  TXT2="$(mktemp)"; printf 'クリーンな本文\n' > "$TXT2"
  out="$(bash "$SCRIPT" --vault "$VAULT2" --text-file "$TXT2" --ngwords-file "$NG2" 2>&1)"; rc=$?
  assert_eq "exit 0" "0" "$rc"
}

echo "=== 10. --vaultに値が無いまま終わる呼び出しはexit 1(unbound variable crash)ではなくexit 2で契約どおり失敗する ==="
{
  setup
  out="$(bash "$SCRIPT" --text-file "$TXT" --ngwords-file "$NGWORDS" --vault 2>&1)"; rc=$?
  assert_eq "exit 2（bashのunbound variableクラッシュ=1にならない）" "2" "$rc"
  assert_contains "値が必要という趣旨のERRORメッセージ" "$out" "ERROR"
}

echo "=== 11. --text-fileに値が無いまま終わる呼び出しも同様にexit 2 ==="
{
  setup
  out="$(bash "$SCRIPT" --vault "$VAULT" --ngwords-file "$NGWORDS" --text-file 2>&1)"; rc=$?
  assert_eq "exit 2" "2" "$rc"
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
