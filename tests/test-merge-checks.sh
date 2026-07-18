#!/usr/bin/env bash
# scripts/vault-agents/merge_checks.py のユニットテスト（Knowledgeマージ品質ゲートの
# 構造チェック関数群・設計書§2.5「merge_checks.py（新設・merge_quality_gate.pyから
# 抽出温存）」）。
#
# 2026-07-16簡素化で削除されたscripts/vault-agents/merge_quality_gate.pyから
# check_structural/check_aliases_union/check_frontmatter_required_keys/
# check_broken_links（~150行）のみを抽出温存したことに伴い新設したテスト
# （旧CLI・worktree改ざん検知・ALERT機構・ベンチTSV付け替えの機能は削除済みのため
# 対象外＝旧テストのtests/test-knowledge-merge.shはこれらも含んでいたが本ファイルは
# 抽出温存した範囲のみを検証する）。
#
# 実HOME・実Vaultには依存しない（毎回tempディレクトリを使う）。
#
# 実行方法: bash tests/test-merge-checks.sh

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
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}

# merge_checks.py の関数を呼ぶ小さなPythonスニペットを実行し、標準出力を返す。
run_py() {
  python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import merge_checks as mc
$1
"
}

echo "=== 1. check_structural: 見出し・コードブロック・URL・日付が全て統合ノートに残っていればpass ==="
{
  out="$(run_py '
a = "# 見出しA\n\nhttps://example.com/a 2026-01-01\n"
b = "# 見出しB\n\n```\ncode-b\n```\n"
merged = "# 見出しA\n# 見出しB\n```\ncode-b\n```\nhttps://example.com/a 2026-01-01\n"
r = mc.check_structural(a, b, merged)
print(r["pass"])
')"
  assert_eq "全項目残存でpass=True" "True" "$out"
}

echo "=== 2. check_structural: 見出しが1つでも欠けるとfail(missing_headingsに載る) ==="
{
  out="$(run_py '
a = "# keep-a\n"
b = "# drop-b\n"
merged = "# keep-a\n"
r = mc.check_structural(a, b, merged)
print(r["pass"])
print(r["missing_headings"])
')"
  assert_contains "見出し欠落でpass=False" "$out" "False"
  assert_contains "欠落見出しがmissing_headingsに載る" "$out" "drop-b"
}

echo "=== 3. check_structural: コードブロック欠落を検出する ==="
{
  out="$(run_py '
a = "```\nkeep-code\n```\n"
b = "```\ndrop-code\n```\n"
merged = "```\nkeep-code\n```\n"
r = mc.check_structural(a, b, merged)
print(r["pass"], len(r["missing_code_blocks"]))
')"
  assert_eq "コードブロック欠落でpass=False・1件検出" "False 1" "$out"
}

echo "=== 4. check_structural: URL欠落を検出する ==="
{
  out="$(run_py '
a = "参照: https://keep.example.com/x\n"
b = "参照: https://drop.example.com/y\n"
merged = "参照: https://keep.example.com/x\n"
r = mc.check_structural(a, b, merged)
print(r["pass"])
print(r["missing_urls"])
')"
  assert_contains "URL欠落でpass=False" "$out" "False"
  assert_contains "欠落URLがmissing_urlsに載る" "$out" "drop.example.com"
}

echo "=== 5. check_structural: 日付欠落を検出する ==="
{
  out="$(run_py '
a = "作成: 2026-01-01\n"
b = "作成: 2099-12-31\n"
merged = "作成: 2026-01-01\n"
r = mc.check_structural(a, b, merged)
print(r["pass"])
print(r["missing_dates"])
')"
  assert_contains "日付欠落でpass=False" "$out" "False"
  assert_contains "欠落日付がmissing_datesに載る" "$out" "2099-12-31"
}

echo "=== 6. check_structural: コードフェンス内の'#'はATX見出しとして要求しない(strip_code_blocks) ==="
{
  out="$(run_py '
code_fence = "```\n# これはコード内コメントで見出しではない\n```\n"
a = code_fence
b = "本文のみ\n"
# コードブロック自体は不変性チェック対象（別テスト3で検証済み）のため、ここでは
# そのまま維持した上で、コード内の"#"が見出し要求(missing_headings)には
# 現れないことだけを見る。
merged = code_fence + "本文のみ（コード内コメントは見出しとして要求されない）\n"
r = mc.check_structural(a, b, merged)
print(r["pass"], r["missing_headings"])
')"
  assert_eq "コード内'#'は見出し要求に含まれずpass=True" "True []" "$out"
}

echo "=== 7. check_aliases_union: 統合ノートが両原ノートaliasesの和集合を含めばpass ==="
{
  out="$(run_py '
fm_a = {"aliases": ["a1", "shared"]}
fm_b = {"aliases": ["b1", "shared"]}
fm_merged = {"aliases": ["a1", "b1", "shared"]}
r = mc.check_aliases_union(fm_a, fm_b, fm_merged)
print(r["pass"])
')"
  assert_eq "和集合を包含していればpass=True" "True" "$out"
}

echo "=== 8. check_aliases_union: 統合ノートに1件でも欠けていればfail ==="
{
  out="$(run_py '
fm_a = {"aliases": ["a1"]}
fm_b = {"aliases": ["b1"]}
fm_merged = {"aliases": ["a1"]}
r = mc.check_aliases_union(fm_a, fm_b, fm_merged)
print(r["pass"], r["missing_aliases"])
')"
  assert_eq "b1欠落でpass=False" "False ['b1']" "$out"
}

echo "=== 9. check_frontmatter_required_keys: 免除キー(aliases/updated/date等)は必須扱いにしない ==="
{
  out="$(run_py '
fm_a = {"title": "a", "date": "2026-01-01", "aliases": ["x"]}
fm_b = {"title": "b", "updated": "2026-01-02", "deprecated": "false"}
fm_merged = {"title": "merged"}
r = mc.check_frontmatter_required_keys(fm_a, fm_b, fm_merged)
print(r["pass"], sorted(r["missing_keys"]))
')"
  assert_eq "免除キー以外にmissingが無ければpass=True" "True []" "$out"
}

echo "=== 10. check_frontmatter_required_keys: 免除対象外キーが欠ければfail ==="
{
  out="$(run_py '
fm_a = {"title": "a", "project": "external-brain"}
fm_b = {"title": "b"}
fm_merged = {"title": "merged"}
r = mc.check_frontmatter_required_keys(fm_a, fm_b, fm_merged)
print(r["pass"], r["missing_keys"])
')"
  assert_eq "project欠落でpass=False" "False ['project']" "$out"
}

echo "=== 11. check_broken_links: 短縮リンク・フルパスリンクどちらも解決できればpass ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/target.md" <<'EOF'
---
date: 2026-01-01
---
本文
EOF
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
短縮: [[target]]
フルパス: [[Knowledge/target]]
EOF
  out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], r['broken_links'])
")"
  assert_eq "両表記とも解決できpass=True・broken_linksは空" "True []" "$out"
  rm -rf "$VAULT"
}

echo "=== 12. check_broken_links: 存在しないノートへのリンクはbroken扱いでfail ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
[[does-not-exist]]
EOF
  out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'])
print(r['broken_links'])
")"
  assert_contains "存在しないリンク先でpass=False" "$out" "False"
  assert_contains "broken_linksに該当リンクが載る" "$out" "does-not-exist"
  rm -rf "$VAULT"
}

echo "=== 13. check_broken_links: コードフェンス/インラインコード内の'[[...]]'書式例は誤検知しない ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
リンクの書き方: `[[note-name]]` のように書く。

```
例: [[another-fake-link]]
```
EOF
  out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], r['broken_links'])
")"
  assert_eq "コード例内の擬似リンクは検査対象外でpass=True" "True []" "$out"
  rm -rf "$VAULT"
}

echo "=== 14. check_broken_links: 読込失敗ノートがあればfail-closed(pass=False・unreadableに記録) ==="
{
  out="$(run_py '
from unittest import mock
import pathlib
real_read_text = pathlib.Path.read_text
def broken_read_text(self, *a, **kw):
    if self.name == "unreadable.md":
        raise OSError("permission denied (simulated)")
    return real_read_text(self, *a, **kw)
import tempfile, os
vault = tempfile.mkdtemp()
os.makedirs(os.path.join(vault, "Knowledge"))
with open(os.path.join(vault, "Knowledge", "unreadable.md"), "w") as f:
    f.write("---\ndate: 2026-01-01\n---\n本文\n")
with mock.patch.object(pathlib.Path, "read_text", broken_read_text):
    r = mc.check_broken_links(vault)
print(r["pass"], len(r["unreadable"]))
import shutil; shutil.rmtree(vault)
')"
  assert_eq "読込失敗を検査対象から静かに除外せずfail-closedする" "False 1" "$out"
}

echo "=== 15. run_all_checks: vault_root・overlaysともに必須引数(省略不可・全PASS必須の抜け道を作らない・Codex/リーダー裁定対応) ==="
{
  out="$(run_py '
import inspect
sig = inspect.signature(mc.run_all_checks)
# vault_root・overlaysともにデフォルト値が無い(=省略できない)ことを確認する。
vault_root_param = sig.parameters["vault_root"]
overlays_param = sig.parameters["overlays"]
print(vault_root_param.default is inspect.Parameter.empty)
print(overlays_param.default is inspect.Parameter.empty)
')"
  assert_contains "vault_rootにデフォルト値が無い" "$out" "True"
  n_true="$(echo "$out" | grep -c '^True$')"
  assert_eq "vault_root・overlaysの両方にデフォルト値が無い(True×2行)" "2" "$n_true"
}

echo "=== 15b. run_all_checks: overlaysにNone/空dictを渡すと呼び出し自体をfail-closedで拒否する(リーダー裁定: 省略可は不採用) ==="
{
  VAULT="$(mktemp -d)"; mkdir -p "$VAULT/Knowledge"
  out_none="$(run_py "
r = mc.run_all_checks('a', 'b', 'merged', '$VAULT', None)
print(r['pass'], 'error' in r)
")"
  assert_eq "overlays=Noneはpass=Falseでerrorフィールドが立つ" "False True" "$out_none"

  out_empty="$(run_py "
r = mc.run_all_checks('a', 'b', 'merged', '$VAULT', {})
print(r['pass'], 'error' in r)
")"
  assert_eq "overlays={}(空dict)も同様にfail-closed" "False True" "$out_empty"
  rm -rf "$VAULT"
}

echo "=== 16. run_all_checks: 全項目passかつVault内リンクも解決できれば全体pass=True ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
本文
EOF
  out="$(run_py "
a = '---\ndate: 2026-01-01\naliases: [\"x\"]\n---\n# h\nhttps://x.example.com 2026-01-01\n'
b = '---\ndate: 2026-01-01\n---\n# h\n'
merged = '---\ndate: 2026-01-01\naliases: [\"x\"]\n---\n# h\nhttps://x.example.com 2026-01-01\n'
r = mc.run_all_checks(a, b, merged, '$VAULT', {'Knowledge/merged.md': merged})
print(r['pass'], sorted(r.keys()))
")"
  assert_contains "全項目pass時は全体もpass=True" "$out" "True"
  assert_contains "broken_linksを含む全項目が結果に含まれる" "$out" "'broken_links'"
  rm -rf "$VAULT"
}

echo "=== 17. run_all_checks: broken_linksがfailなら他が全passでも全体はfail=False ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
[[missing-target]]
EOF
  out="$(run_py "
r = mc.run_all_checks('a', 'b', 'merged', '$VAULT', {'Knowledge/merged.md': 'merged'})
print(r['pass'], r['broken_links']['pass'])
")"
  assert_eq "broken_links失敗が全体passへ波及する" "False False" "$out"
  rm -rf "$VAULT"
}

echo "=== 18. run_all_checks: frontmatterは本文から内部解析される(呼び出し元が別辞書を渡す事故を構造的に防ぐ・Codexレビュー指摘Minor対応) ==="
{
  VAULT="$(mktemp -d)"; mkdir -p "$VAULT/Knowledge"
  out="$(run_py "
a = '---\ndate: 2026-01-01\naliases: [\"only-in-a\"]\n---\n本文a\n'
b = '---\ndate: 2026-01-01\n---\n本文b\n'
merged = '---\ndate: 2026-01-01\n---\n本文merged\n'  # aのaliasesを引き継いでいない
r = mc.run_all_checks(a, b, merged, '$VAULT', {'Knowledge/merged.md': merged})
print(r['aliases']['pass'], r['aliases']['missing_aliases'])
")"
  assert_eq "本文中のfrontmatterから実際にaliases和集合が判定される" "False ['only-in-a']" "$out"
  rm -rf "$VAULT"
}

echo "=== 19. DEFAULT_FRONTMATTER_EXEMPT_KEYS: 想定した6キーがちょうど免除対象になっている ==="
{
  out="$(run_py '
print(sorted(mc.DEFAULT_FRONTMATTER_EXEMPT_KEYS))
')"
  assert_eq "免除キー集合が設計どおり" "['aliases', 'date', 'deprecated', 'review_by', 'superseded_by', 'updated']" "$out"
}

echo "=== 20. check_broken_links: vault_rootが存在しない/ディレクトリでない場合はfail-closed(空Vault扱いでpass=Trueにしない・Codexレビュー指摘Major対応) ==="
{
  out="$(run_py '
r1 = mc.check_broken_links("/nonexistent/path/that/should/not/exist-xyz")
print("nonexistent:", r1["pass"])
tmp = __import__("tempfile").NamedTemporaryFile(delete=False)
tmp.close()
r2 = mc.check_broken_links(tmp.name)
print("regular-file:", r2["pass"])
import os; os.unlink(tmp.name)
')"
  assert_contains "存在しないパスはfail-closed(pass=False)" "$out" "nonexistent: False"
  assert_contains "通常ファイルをvault_rootに渡してもfail-closed(pass=False)" "$out" "regular-file: False"
}

echo "=== 21. check_broken_links: '../'によるVault外への脱出リンクは壊れているとみなす(誤ってpass扱いしない・Codexレビュー指摘Major対応) ==="
{
  OUTER="$(mktemp -d)"
  VAULT="$OUTER/vault"
  mkdir -p "$VAULT/Knowledge"
  # Vault外(OUTER直下)に実在ファイルを置く。target側がVault外へ脱出して
  # 「たまたま実在するファイル」に解決されても、Vault内としては壊れている扱いにする。
  echo "outside content" > "$OUTER/escaped.md"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
[[../escaped]]
EOF
  out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], r['broken_links'])
")"
  assert_contains "Vault外への脱出リンクはpass=False" "$out" "False"
  assert_contains "脱出リンクがbroken_linksに載る" "$out" "escaped"
  rm -rf "$OUTER"
}

echo "=== 22. check_broken_links: 絶対パス表記のリンクはVault相対記法として扱わずbroken扱いにする ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
[[/etc/passwd]]
EOF
  out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], r['broken_links'])
")"
  assert_eq "絶対パス表記はbroken扱いでpass=False" "False [('Knowledge/source.md', '/etc/passwd')]" "$out"
  rm -rf "$VAULT"
}

echo "=== 23. check_broken_links: 非UTF-8(UnicodeDecodeError)もOSErrorと同様にfail-closedする(Codexレビュー指摘Minor対応) ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/ok.md" <<'EOF'
---
date: 2026-01-01
---
本文
EOF
  printf '\xff\xfe invalid utf-8' > "$VAULT/Knowledge/broken-binary.md"
  out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], len(r['unreadable']))
")"
  assert_eq "非UTF-8ファイルもunreadableへ記録されfail-closedする" "False 1" "$out"
  rm -rf "$VAULT"
}

echo "=== 24. check_broken_links: overlaysで書込前の統合ノート案自体もリンク切れ検査できる(Codex 2巡目レビュー指摘Major対応) ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/target.md" <<'EOF'
---
date: 2026-01-01
---
本文
EOF
  # merged-note.mdはディスク上にまだ存在しない(overlayでのみ与える)。
  # 統合ノート案の中に壊れたリンクを1つ・正当なリンクを1つ仕込む。
  out="$(run_py "
overlays = {
    'Knowledge/merged-note.md': '---\ndate: 2026-01-01\n---\n正当: [[target]]\n壊れ: [[missing-in-overlay]]\n',
}
r = mc.check_broken_links('$VAULT', overlays=overlays)
print(r['pass'], r['broken_links'])
")"
  assert_contains "ディスク未書込の統合ノート案自体のリンク切れが検出される" "$out" "False"
  assert_contains "壊れたリンクがbroken_linksに載る" "$out" "missing-in-overlay"
  rm -rf "$VAULT"
}

echo "=== 25. check_broken_links: overlaysで新規作成予定ノートへのリンクは解決できる(実在有無を問わない) ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
[[Knowledge/merged-note]]
EOF
  out="$(run_py "
overlays = {'Knowledge/merged-note.md': '---\ndate: 2026-01-01\n---\n本文\n'}
r = mc.check_broken_links('$VAULT', overlays=overlays)
print(r['pass'], r['broken_links'])
")"
  assert_eq "overlay先の新規ノートへのリンクはbroken扱いにならずpass=True" "True []" "$out"
  rm -rf "$VAULT"
}

echo "=== 26. check_broken_links: overlaysはディスク上の現行内容より優先される(旧内容の壊れたリンクを引きずらない) ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  # ディスク上の現行版は壊れたリンクを含むが、overlayで修正済みの内容に
  # 差し替える想定（MERGE適用でstub化・書換されるノートを模したケース）。
  cat > "$VAULT/Knowledge/orig-a.md" <<'EOF'
---
date: 2026-01-01
---
[[does-not-exist-in-disk-version]]
EOF
  out="$(run_py "
overlays = {'Knowledge/orig-a.md': '---\ndate: 2026-01-01\ndeprecated: true\n---\nstub化済み。[[Knowledge/orig-a]]自身への自己リンクは許容。\n'}
r = mc.check_broken_links('$VAULT', overlays=overlays)
print(r['pass'], r['broken_links'])
")"
  assert_eq "overlayの新内容だけが検査され旧内容の壊れたリンクは無視される" "True []" "$out"
  rm -rf "$VAULT"
}

echo "=== 27. run_all_checks: overlaysを指定すると統合ノート案自体のリンク切れがMERGE全体判定へ波及する ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  out="$(run_py "
a = '---\ndate: 2026-01-01\n---\n# h\n'
b = '---\ndate: 2026-01-01\n---\n# h\n'
merged = '---\ndate: 2026-01-01\n---\n# h\n[[nonexistent-in-merged-note]]\n'
r = mc.run_all_checks(a, b, merged, '$VAULT', overlays={'Knowledge/merged.md': merged})
print(r['pass'], r['broken_links']['pass'])
")"
  assert_eq "統合ノート案のリンク切れがrun_all_checks全体のpassへ波及する" "False False" "$out"
  rm -rf "$VAULT"
}

if command -v ln >/dev/null 2>&1; then
  echo "=== 28. check_broken_links: Vault外symlinkのノートは検査対象から除外する(中身を正常なリンク先として読まない・Codex 2巡目レビュー指摘Minor対応) ==="
  {
    OUTER="$(mktemp -d)"
    VAULT="$OUTER/vault"
    mkdir -p "$VAULT/Knowledge"
    echo "外部ファイルの内容" > "$OUTER/external.md"
    ln -s "$OUTER/external.md" "$VAULT/Knowledge/symlinked.md"
    cat > "$VAULT/Knowledge/source.md" <<'EOF'
---
date: 2026-01-01
---
短縮リンク: [[symlinked]]
EOF
    out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], r['broken_links'])
")"
    assert_contains "symlink経由のノートは実在扱いにならずbroken扱いになる" "$out" "False"
    assert_contains "symlinkedへのリンクがbroken_linksに載る" "$out" "symlinked"
    rm -rf "$OUTER"
  }
fi

echo "=== 29. check_broken_links: 不正なoverlayキー(絶対パス/'..'/空文字列/非文字列値)はVault境界チェックを迂回できずfail-closed(Codex 3巡目レビュー指摘Major対応) ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/inside.md" <<'EOF'
---
date: 2026-01-01
---
本文
EOF

  abs_out="$(run_py "
r = mc.check_broken_links('$VAULT', overlays={'/etc/evil.md': 'x'})
print(r['pass'])
")"
  assert_eq "絶対パスキーはfail-closed(pass=False)" "False" "$abs_out"

  dotdot_out="$(run_py "
r = mc.check_broken_links('$VAULT', overlays={'../escape.md': 'x'})
print(r['pass'])
")"
  assert_eq "'..'を含むキーはfail-closed(pass=False)" "False" "$dotdot_out"

  empty_out="$(run_py "
r = mc.check_broken_links('$VAULT', overlays={'': 'x'})
print(r['pass'])
")"
  assert_eq "空文字列キーはfail-closed(pass=False)" "False" "$empty_out"

  nonstr_out="$(run_py "
r = mc.check_broken_links('$VAULT', overlays={'Knowledge/ok.md': 12345})
print(r['pass'])
")"
  assert_eq "値が文字列でないoverlayはfail-closed(pass=False)" "False" "$nonstr_out"

  valid_out="$(run_py "
r = mc.check_broken_links('$VAULT', overlays={'Knowledge/new.md': '---\ndate: 2026-01-01\n---\n本文\n'})
print(r['pass'])
")"
  assert_eq "正当な相対パスキーは従来どおり通る" "True" "$valid_out"
  rm -rf "$VAULT"
}

echo "=== 30. check_broken_links: overlay指定の無いVault外symlinkノートはunreadableへ記録されfail-closed(自身のリンクを未検査のまま通さない・Codex 3巡目レビュー指摘Minor対応) ==="
{
  if command -v ln >/dev/null 2>&1; then
    OUTER="$(mktemp -d)"
    VAULT="$OUTER/vault"
    mkdir -p "$VAULT/Knowledge"
    echo "外部ファイルの内容" > "$OUTER/external.md"
    ln -s "$OUTER/external.md" "$VAULT/Knowledge/symlinked.md"
    out="$(run_py "
r = mc.check_broken_links('$VAULT')
print(r['pass'], len(r['unreadable']))
")"
    assert_eq "symlinkノート自体がunreadableへ記録されfail-closedする" "False 1" "$out"
    rm -rf "$OUTER"

    # overlayでsymlinkパスを明示的に上書きする場合は、overlay側の内容だけが
    # 検査対象になり、symlink自体はfail-closed扱いにならない。
    OUTER2="$(mktemp -d)"
    VAULT2="$OUTER2/vault"
    mkdir -p "$VAULT2/Knowledge"
    echo "外部ファイルの内容" > "$OUTER2/external.md"
    ln -s "$OUTER2/external.md" "$VAULT2/Knowledge/symlinked.md"
    overlay_out="$(run_py "
r = mc.check_broken_links('$VAULT2', overlays={'Knowledge/symlinked.md': '---\ndate: 2026-01-01\n---\n本文\n'})
print(r['pass'], len(r['unreadable']))
")"
    assert_eq "overlayで明示上書きされたsymlinkパスはfail-closed対象から外れる" "True 0" "$overlay_out"
    rm -rf "$OUTER2"
  else
    pass "ln コマンドが無い環境のためskip"
  fi
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
