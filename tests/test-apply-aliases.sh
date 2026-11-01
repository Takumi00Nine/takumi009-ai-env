#!/usr/bin/env bash
# alias 適用の dry-run・非破壊・禁止語と fail-closed を確認する。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/apply_aliases.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

write_note() {
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  {
    echo "---"
    printf '%s\n' "$fm"
    echo "---"
    echo
    printf '%s\n' "$body"
  } > "$path"
}

echo "=== dry-run は元ノートを変更しない ==="
V="$(mktemp -d)" || exit 1
TSV="$V/input.tsv"
trap 'rm -rf "$V"' EXIT
write_note "$V/Knowledge/sample.md" 'tags: [sample]' '本文はそのまま'
printf 'Knowledge/sample.md\tadded-term\n' > "$TSV"
cp "$V/Knowledge/sample.md" "$V/before.md"
python3 "$SCRIPT" "$TSV" --vault "$V" >/dev/null
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$V/before.md" "$V/Knowledge/sample.md"; then
  pass "dry-run は非破壊"
else fail_case "dry-run は非破壊"; fi

echo "=== apply は alias を追加し本文を保つ ==="
python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
rc=$?
content="$(cat "$V/Knowledge/sample.md")"
if [ "$rc" -eq 0 ] && [[ "$content" == *'"added-term"'* && "$content" == *'tags: [sample]'* && "$content" == *'本文はそのまま'* ]]; then
  pass "alias 追加と既存内容の保持"
else fail_case "alias 追加と既存内容の保持"; fi

echo "=== 禁止語は拒否し、具体的な語は通す ==="
printf 'blocked-term\n' > "$V/generic.txt"
printf 'Knowledge/sample.md\tblocked-term|specific-term\n' > "$TSV"
APPLY_ALIASES_GENERIC_FILE="$V/generic.txt" python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null
content="$(cat "$V/Knowledge/sample.md")"
if [[ "$content" != *'"blocked-term"'* && "$content" == *'"specific-term"'* ]]; then
  pass "禁止語の deny と具体語の allow"
else fail_case "禁止語の deny と具体語の allow"; fi

echo "=== 禁止リストが読めなければ書かない ==="
cp "$V/Knowledge/sample.md" "$V/before.md"
APPLY_ALIASES_GENERIC_FILE="$V/missing.txt" python3 "$SCRIPT" "$TSV" --vault "$V" --apply >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$V/before.md" "$V/Knowledge/sample.md"; then
  pass "禁止リスト欠落は fail-closed"
else fail_case "禁止リスト欠落は fail-closed"; fi
echo "=== 16. atomic書込み: write_note_atomic()は書込み失敗時に元ファイルを無変更のまま保ち一時ファイルも残さない（2026-07-14修正・リーダー指示） ==="
{
  ATOMIC_V="$(mktemp -d)" || exit 1
  V_SAVED="$V"; V="$ATOMIC_V"
  write_note "$V/Knowledge/target.md" "date: 2026-07-01" "original body"
  before_sum="$(md5 -q "$V/Knowledge/target.md" 2>/dev/null || md5sum "$V/Knowledge/target.md" | cut -d' ' -f1)"

  PYSCRIPT="$(mktemp)"
  cat > "$PYSCRIPT" <<PYEOF
import sys, pathlib, os
sys.path.insert(0, "$REPO_ROOT/ai-brain/executor")
import vault_lib

p = pathlib.Path("$V/Knowledge/target.md")
orig_replace = os.replace

def boom(*a, **kw):
    raise OSError("simulated os.replace failure")

os.replace = boom
try:
    vault_lib.write_note_atomic(p, "CORRUPTED-SHOULD-NOT-APPEAR")
except OSError as e:
    print("CAUGHT:", e)
finally:
    os.replace = orig_replace

tmp_files = list(p.parent.glob("." + p.name + ".*.tmp"))
print("TMP_LEFTOVER:", len(tmp_files))
PYEOF

  out="$(python3 "$PYSCRIPT" 2>&1)"
  after_sum="$(md5 -q "$V/Knowledge/target.md" 2>/dev/null || md5sum "$V/Knowledge/target.md" | cut -d' ' -f1)"
  if [[ "$out" == *"CAUGHT: simulated os.replace failure"* && "$out" == *"TMP_LEFTOVER: 0"* && "$before_sum" == "$after_sum" ]]; then
    pass "atomic 書込失敗でも元ノートを保持し一時ファイルを消す"
  else fail_case "atomic 書込失敗は非破壊"; fi

  rm -rf "$V" "$PYSCRIPT"
  V="$V_SAVED"

}

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
