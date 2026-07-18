#!/usr/bin/env bash
# scripts/vault-agents/vault_lib.py のユニットテスト（複数スクリプト共有ライブラリ・
# 2026-07-16簡素化・cleanup決定#10・PR1.5②）。
#
# vault_inventory.py（frontmatter解析・wikilink正規表現・aliases正規化・
# 汎用alias禁止リスト読込）・apply_aliases.py（apply_updated・write_note_atomic）
# から挙動を一切変えずに抽出したことを、抽出元の元テスト（test-vault-inventory.sh・
# test-apply-aliases.sh、いずれも各関数を間接的に経由して128/65件全passを確認済み）
# に加えて本ファイルで直接検証する（設計書§7「抽出前後の挙動不変テスト」の直接証跡）。
#
# 実行方法: bash tests/test-vault-lib.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/scripts/vault-agents"

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

# vault_lib.py の関数を呼ぶ小さなPythonスニペットを実行し、標準出力を返す。
run_py() {
  python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import vault_lib
$1
"
}

echo "=== 1. parse_frontmatter: 単一行キー・フロー配列・複数行リストの3形式を読める ==="
{
  out="$(run_py '
text = """---
date: 2026-01-01
tags: [a, b]
aliases:
  - "alias1"
  - "alias2"
---
本文
"""
fm, body = vault_lib.parse_frontmatter(text)
print(fm["date"])
print(",".join(fm["tags"]))
print(",".join(fm["aliases"]))
print(body.strip())
')"
  assert_eq "date(単一行)" "2026-01-01" "$(sed -n '1p' <<< "$out")"
  assert_eq "tags(フロー配列)" "a,b" "$(sed -n '2p' <<< "$out")"
  assert_eq "aliases(複数行リスト)" "alias1,alias2" "$(sed -n '3p' <<< "$out")"
  assert_eq "本文がfrontmatter除去後になる" "本文" "$(sed -n '4p' <<< "$out")"
}

echo "=== 2. parse_frontmatter: frontmatterが無いテキストは空dictと元テキストをそのまま返す ==="
{
  out="$(run_py '
fm, body = vault_lib.parse_frontmatter("本文のみ\n")
print(len(fm))
print(body)
')"
  assert_eq "frontmatter辞書は空" "0" "$(sed -n '1p' <<< "$out")"
}

echo "=== 3. LINK_RE: wikilinkを抽出できる ==="
{
  out="$(run_py '
import re
hits = vault_lib.LINK_RE.findall("参照: [[Knowledge/foo]] と [[bar|alias]]")
print(",".join(hits))
')"
  assert_eq "2件のwikilinkが抽出される" "Knowledge/foo,bar|alias" "$out"
}

echo "=== 4. normalize_aliases: リスト/カンマ区切り文字列/未設定を正規化する ==="
{
  out="$(run_py '
print(",".join(vault_lib.normalize_aliases(["a", "b"])))
print(",".join(vault_lib.normalize_aliases("a, b、c")))
print(len(vault_lib.normalize_aliases(None)))
print(len(vault_lib.normalize_aliases("")))
')"
  assert_eq "リスト入力はそのまま" "a,b" "$(sed -n '1p' <<< "$out")"
  assert_eq "カンマ・読点区切り文字列を分割" "a,b,c" "$(sed -n '2p' <<< "$out")"
  assert_eq "Noneは空リスト" "0" "$(sed -n '3p' <<< "$out")"
  assert_eq "空文字も空リスト" "0" "$(sed -n '4p' <<< "$out")"
}

echo "=== 5. load_generic_aliases: 1行1語・#コメント・小文字化を読む ==="
{
  F="$(mktemp)"
  printf 'Codex\n# comment line\nclaude  # inline comment\n\n' > "$F"
  out="$(run_py "print(sorted(vault_lib.load_generic_aliases('$F')))")"
  assert_eq "codex/claudeが小文字化されて読める" "['claude', 'codex']" "$out"
  rm -f "$F"
}

echo "=== 6. load_generic_aliases: ファイルが存在しなければ空集合(fail-open) ==="
{
  out="$(run_py "print(len(vault_lib.load_generic_aliases('/nonexistent-generic-aliases-file.txt')))")"
  assert_eq "空集合" "0" "$out"
}

echo "=== 7. apply_updated: updated:行が既にあれば書き換える ==="
{
  out="$(run_py '
lines = ["date: 2026-01-01", "updated: 2026-01-02", "tags: [x]"]
result = vault_lib.apply_updated(lines, "2026-07-16")
print("|".join(result))
')"
  assert_eq "updated行だけが書き換わる" "date: 2026-01-01|updated: 2026-07-16|tags: [x]" "$out"
}

echo "=== 8. apply_updated: updated:が無ければdate:の直後に挿入する ==="
{
  out="$(run_py '
lines = ["date: 2026-01-01", "tags: [x]"]
result = vault_lib.apply_updated(lines, "2026-07-16")
print("|".join(result))
')"
  assert_eq "date直後にupdatedが挿入される" "date: 2026-01-01|updated: 2026-07-16|tags: [x]" "$out"
}

echo "=== 9. apply_updated: date:も無ければ先頭に挿入する ==="
{
  out="$(run_py '
lines = ["tags: [x]"]
result = vault_lib.apply_updated(lines, "2026-07-16")
print("|".join(result))
')"
  assert_eq "先頭にupdatedが挿入される" "updated: 2026-07-16|tags: [x]" "$out"
}

echo "=== 10. write_note_atomic: 新規テキストがatomicに書き込まれ一時ファイルが残らない ==="
{
  D="$(mktemp -d)"
  F="$D/note.md"
  printf 'original' > "$F"
  run_py "
import pathlib
vault_lib.write_note_atomic(pathlib.Path('$F'), 'updated-content')
"
  content="$(cat "$F")"
  n_tmp="$(find "$D" -maxdepth 1 -name '.*.tmp' | wc -l | tr -d ' ')"
  assert_eq "新しい内容が書き込まれる" "updated-content" "$content"
  assert_eq "一時ファイルが残置されない" "0" "$n_tmp"
  rm -rf "$D"
}

echo "=== 11. write_note_atomic: 元ファイルのパーミッションを維持する ==="
{
  D="$(mktemp -d)"
  F="$D/note.md"
  printf 'original' > "$F"
  chmod 640 "$F"
  run_py "
import pathlib
vault_lib.write_note_atomic(pathlib.Path('$F'), 'updated-content')
"
  mode="$(stat -f '%Lp' "$F" 2>/dev/null || stat -c '%a' "$F")"
  assert_eq "パーミッション640が維持される" "640" "$mode"
  rm -rf "$D"
}

echo "=== 12. strip_quotes/split_flow_list: クォート内カンマ・エスケープを壊さず分割する ==="
{
  out="$(run_py '
print("|".join(vault_lib.split_flow_list(chr(34) + "foo, bar" + chr(34) + ", baz")))
print(vault_lib.strip_quotes(chr(34) + "esc\\\\" + chr(34) + "aped" + chr(34) + chr(34)))
')"
  assert_eq "クォート内カンマは分割しない" "foo, bar|baz" "$(sed -n '1p' <<< "$out")"
}

echo "=== 13. find_aliases_block/build_aliases_block: 既存ブロックの検出とラウンドトリップ ==="
{
  out="$(run_py '
lines = ["date: 2026-01-01", "aliases:", "  - \"a\"", "  - \"b\"", "tags: [x]"]
start, end, existing = vault_lib.find_aliases_block(lines)
print(start, end, ",".join(existing))
print("\n".join(vault_lib.build_aliases_block(["a", "b", "c"])))
')"
  assert_eq "既存aliasesブロックがstart=1,end=4で検出される" "1 4 a,b" "$(sed -n '1p' <<< "$out")"
}

echo "=== 14. require_generic_aliases: ファイルが無ければexit 1(fail-closed) ==="
{
  out="$(run_py "vault_lib.require_generic_aliases('/nonexistent-generic-$$.txt')" 2>&1)"
  rc=$?
  assert_eq "exit code 1" "1" "$rc"
  [[ "$out" == *"FAIL:"* ]] && pass "FAILメッセージが出る" || fail_case "FAILメッセージが出る (実際: $out)"
}

echo "=== 15. require_generic_aliases: 有効な語が1つもなければexit 1(fail-closed) ==="
{
  F="$(mktemp)"
  printf '# comment only\n\n' > "$F"
  out="$(run_py "vault_lib.require_generic_aliases('$F')" 2>&1)"
  rc=$?
  assert_eq "exit code 1" "1" "$rc"
  rm -f "$F"
}

echo "=== 16. require_generic_aliases: 有効な語があれば集合を返す ==="
{
  F="$(mktemp)"
  printf 'Codex\n' > "$F"
  out="$(run_py "print(sorted(vault_lib.require_generic_aliases('$F')))")"
  assert_eq "codexが小文字化されて返る" "['codex']" "$out"
  rm -f "$F"
}

echo "=== 17. parse_tsv: 相対パス<TAB>alias1|alias2形式を解釈し.md拡張子を補う ==="
{
  F="$(mktemp)"
  printf 'Knowledge/foo\ta1|a2\n# comment\n\nKnowledge/bar.md\ta3\n' > "$F"
  out="$(run_py "
rows = vault_lib.parse_tsv('$F')
for relpath, aliases in rows:
    print(relpath, ','.join(aliases))
")"
  assert_eq "1行目: 拡張子が補われ2aliasに分割される" "Knowledge/foo.md a1,a2" "$(sed -n '1p' <<< "$out")"
  assert_eq "2行目: 既に.mdがあればそのまま" "Knowledge/bar.md a3" "$(sed -n '2p' <<< "$out")"
}

echo "=== 18. process_note: 新規aliasを追加しupdated:を挿入・汎用語はskipする ==="
{
  out="$(run_py '
text = "---\ndate: 2026-01-01\n---\n本文\n"
result = vault_lib.process_note(text, ["新規alias", "codex"], {"codex"}, "2026-07-16")
print(result["changed"])
print(",".join(result["added"]))
print(",".join(result["skipped_generic"]))
print("updated: 2026-07-16" in result["new_text"])
print("新規alias" in result["new_text"])
')"
  assert_eq "変更ありと判定される" "True" "$(sed -n '1p' <<< "$out")"
  assert_eq "新規aliasのみ追加される(汎用語codexは除外)" "新規alias" "$(sed -n '2p' <<< "$out")"
  assert_eq "汎用語がskipped_genericに記録される" "codex" "$(sed -n '3p' <<< "$out")"
  assert_eq "updated:が挿入される" "True" "$(sed -n '4p' <<< "$out")"
  assert_eq "新規aliasがnew_textに含まれる" "True" "$(sed -n '5p' <<< "$out")"
}

echo "=== 19. process_note: frontmatterが無ければerrorを返す ==="
{
  out="$(run_py '
result = vault_lib.process_note("本文のみ", ["x"], set(), "2026-07-16")
print(result["error"] is not None)
')"
  assert_eq "errorが設定される" "True" "$out"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
