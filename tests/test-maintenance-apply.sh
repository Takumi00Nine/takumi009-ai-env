#!/usr/bin/env bash
# scripts/vault-agents/maintenance_apply.py のユニットテスト（maintenance.sh Phase 2
# 「判断＋適用」＝PR2の安全設計中核・設計書§2・§2.4・§6）。
#
# 品質方針（2026-07-16リーダー指示「安全設計（apply層のスキーマ検証・ID方式・
# O_EXCL・TOCTOU・機械ゲート・全件不採用ルール）と、その失敗系テストは一切
# 簡略化不可」）: 本ファイルは設計書§6が要求する全パターン
# （Schema違反→全体不採用／未知id→全体不採用／TOCTOU／冪等リトライ／
# merge_checks.py全項目の失敗パターン／FIX承認・skip／PROMOTEのO_EXCL排他衝突／
# Preferences向けPersonalリンク検出時の単体skip）を狙い撃ちで検証する。
#
# 実HOME・実Vault・実claudeコマンドには一切依存しない（毎回tempディレクトリを
# 使い、claudeは`--claude-bin`でfakeスクリプトへ差し替える＝実環境操作なし）。
#
# 構成: (a) Python関数の単体テスト（run_py経由・高速）
#       (b) CLI end-to-end テスト（fake claudeバイナリ経由・main()のオーケストレーション検証）
#
# 実行方法: bash tests/test-maintenance-apply.sh

set -uo pipefail

# 実HOME配下への書込を構造的に不可能にする（2026-07-12実インシデント対応の教訓）。
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/scripts/vault-agents"
SCRIPT="$LIB_DIR/maintenance_apply.py"
WORK_ROOT="$(mktemp -d)"

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
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
}
assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$desc"; else fail_case "$desc (ファイルが存在しません: $path)"; fi
}
assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then pass "$desc"; else fail_case "$desc (存在してはいけないのに存在する: $path)"; fi
}

# maintenance_apply.pyの関数を呼ぶPythonスニペットを実行し、標準出力を返す。
run_py() {
  python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import maintenance_apply as ma
import knowledge_merge_candidates as kmc
import fragments_log
$1
"
}

# =============================================================================
# (a) Python関数の単体テスト
# =============================================================================

echo "=== 1. slugify_id: NFC正規化・ASCII fold・小文字化・非[a-z0-9-]は-・重複-圧縮 ==="
{
  out="$(run_py "print(ma.slugify_id('frag-3a9f2e1b4c7d'))")"
  assert_eq "hex idはほぼ恒等変換" "frag-3a9f2e1b4c7d" "$out"

  out="$(run_py "print(ma.slugify_id('Cand--ABC__def!!'))")"
  assert_eq "大文字/記号/重複区切りの正規化" "cand-abc-def" "$out"

  out="$(run_py "print(ma.slugify_id('café-tëst'))")"
  assert_eq "非ASCII文字はASCII foldで除去される（NFC正規化のため脱accent化ではなく単純除去）" "caf-tst" "$out"

  out="$(run_py "print(repr(ma.slugify_id('!!!')))")"
  assert_eq "全部無効文字なら空文字列" "''" "$out"

  out="$(run_py "print(len(ma.slugify_id('a'*200)))")"
  assert_eq "長さ上限(SLUG_MAX_LEN=80)で切り詰められる" "80" "$out"
}

echo "=== 2. build_output_schema: id enum・action enum・maxItemsが候補件数と一致 ==="
{
  out="$(run_py "
import json
s = ma.build_output_schema({'frag-1'}, {'inv-1'}, {'cand-1'})
print(s['properties']['actions']['maxItems'])
print(sorted(s['properties']['actions']['items']['properties']['id']['enum']))
print(s['properties']['actions']['items']['additionalProperties'])
")"
  assert_contains "maxItemsが3件" "$out" "3"
  assert_contains "id enumに3件とも含まれる" "$out" "['cand-1', 'frag-1', 'inv-1']"
  assert_contains "additionalPropertiesがFalse" "$out" "False"
}

echo "=== 3. validate_structured_output: 正常な応答はそのまま通る ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'promote', 'target_folder': 'Knowledge', 'body': '---\nx\n---\n'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(err)
print(len(actions))
")"
  assert_contains "エラーなし" "$out" "None"
  assert_contains "1件通る" "$out" "1"
}

echo "=== 4. validate_structured_output: 未知idは応答全体を不採用（部分適用しない） ==="
{
  out="$(run_py "
data = {'actions': [
  {'id': 'frag-1', 'action': 'promote', 'target_folder': 'Knowledge', 'body': '---\nx\n---\n'},
  {'id': 'frag-UNKNOWN', 'action': 'skip'},
]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(actions)
print('ERR' if err else 'NOERR')
")"
  assert_contains "actionsはNone（全件不採用）" "$out" "None"
  assert_contains "エラー理由あり" "$out" "ERR"
}

echo "=== 5. validate_structured_output: 重複idは応答全体を不採用 ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'skip'}, {'id': 'frag-1', 'action': 'skip'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(actions, 'ERR' if err else 'NOERR')
")"
  assert_contains "重複idで不採用" "$out" "None ERR"
}

echo "=== 6. validate_structured_output: 件数が候補数を超えたら不採用 ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'skip'}, {'id': 'frag-1', 'action': 'skip'}, {'id':'x','action':'skip'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(actions, 'ERR' if err else 'NOERR')
")"
  assert_contains "上限超過で不採用" "$out" "None ERR"
}

echo "=== 7. validate_structured_output: id種別とactionの不一致は不採用（frag-idにmerge指定） ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'merge', 'body': '---\nx\n---\n'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), {'cand-1'})
print(actions, 'ERR' if err else 'NOERR')
")"
  assert_contains "id種別不一致で不採用" "$out" "None ERR"
}

echo "=== 8. validate_structured_output: promoteでtarget_folder不正/body欠落は不採用 ==="
{
  out1="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'promote', 'target_folder': 'Personal', 'body': '---\nx\n---\n'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print('ERR' if err else 'NOERR')
")"
  assert_eq "target_folder=Personalは許可外なので不採用" "ERR" "$out1"

  out2="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'promote', 'target_folder': 'Knowledge'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print('ERR' if err else 'NOERR')
")"
  assert_eq "body欠落は不採用" "ERR" "$out2"
}

echo "=== 9. validate_structured_output: skipはbody/target_folder不要で通る ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'skip', 'reason': 'まだ確信が持てない'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(err, len(actions) if actions else 0)
")"
  assert_eq "skipは通る" "None 1" "$out"
}

echo "=== 10. PROMOTE: 正常系（Knowledge新規作成＋Fragments側にstatus:promoted追記） ==="
{
  V="$WORK_ROOT/t10/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片A**：これはPROMOTEの正常系テスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
       'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
       'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
act = {'id': fid, 'action': 'promote', 'target_folder': 'Knowledge',
       'body': '---\ndate: 2026-07-16\ntags: [t]\nproject: x\n---\n\n本文\n'}
r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, ma.DEFAULT_NGWORDS_FILE, dry_run=False, source_cache={})
print(r['applied'], r['note_path'], r['step1'], r['step2'])
slug = ma.slugify_id(fid)
print('SLUG', slug)
")"
  assert_contains "適用成功・Knowledge配下に作成・両stepとも実行" "$out" "True Knowledge/"
  assert_contains "step1=created" "$out" "created"
  assert_contains "step2=marked" "$out" "marked"
  SLUG_10="$(echo "$out" | grep '^SLUG' | awk '{print $2}')"
  assert_file_exists "新規ノートが実在する" "$V/Knowledge/$SLUG_10.md"
  SRC_AFTER="$(cat "$V/Fragments/2026-07/2026-07-15.md")"
  assert_contains "Fragments側にstatus:promotedが追記される" "$SRC_AFTER" "status: promoted"
  assert_contains "リンク先がslugを指す" "$SRC_AFTER" "Knowledge/$SLUG_10"
}

echo "=== 11. PROMOTE: TOCTOU（Phase1後にFragments原文が変わっていたらskip・書込なし） ==="
{
  V="$WORK_ROOT/t11/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片B**：TOCTOUテスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
stale_sha = hashlib.sha256((text + '差分').encode()).hexdigest()  # Phase1時点のsha256を偽装（変化後の値と食い違わせる）
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
       'source_sha256': stale_sha, 'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
act = {'id': fid, 'action': 'promote', 'target_folder': 'Knowledge', 'body': '---\nx\n---\n'}
r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, ma.DEFAULT_NGWORDS_FILE, dry_run=False, source_cache={})
print(r['applied'], r['reason'])
")"
  assert_eq "TOCTOU不一致でskip" "False source_changed_toctou" "$out"
  assert_file_not_exists "Knowledgeへは何も作成されない" "$V/Knowledge"/*.md
}

echo "=== 12. PROMOTE: 冪等リトライ（既存slugファイルがあればstep1をスキップしstep2のみ再試行） ==="
{
  V="$WORK_ROOT/t12/vault"; mkdir -p "$V/Knowledge" "$V/Decisions" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片C**：冪等リトライテスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
       'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
       'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
slug = ma.slugify_id(fid)
(vault/'Knowledge'/f'{slug}.md').write_text('---\ndate: 2026-07-16\n---\n\n前回実行で作成済み\n')
# 今回はClaudeがDecisionsを選んだとしても、既存Knowledge側を尊重してstep1をスキップする
act = {'id': fid, 'action': 'promote', 'target_folder': 'Decisions', 'body': '---\nx\n---\n\n別の本文\n'}
r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, ma.DEFAULT_NGWORDS_FILE, dry_run=False, source_cache={})
print(r['applied'], r['step1'], r['step2'], r['note_path'])
")"
  assert_contains "step1がalready_exists" "$out" "already_exists"
  assert_contains "step2がmarked" "$out" "marked"
  assert_file_not_exists "Decisionsには新規作成されない（既存Knowledgeを尊重）" "$V/Decisions"/*.md
  KEPT="$(find "$V/Knowledge" -name '*.md' | head -1 | xargs cat)"
  assert_contains "Knowledge側の既存内容は上書きされない" "$KEPT" "前回実行で作成済み"
}

echo "=== 13. exclusive_create: O_EXCL排他衝突（既存ファイルへは書き込めない） ==="
{
  V="$WORK_ROOT/t13/vault"; mkdir -p "$V/Knowledge"
  echo "既存" > "$V/Knowledge/dup.md"
  out="$(run_py "
import pathlib
ok, err = ma.exclusive_create(pathlib.Path('$V/Knowledge/dup.md'), '新規で上書きしようとする本文')
print(ok, err)
")"
  assert_eq "既存ファイルへのO_EXCLは失敗する" "False already_exists" "$out"
  assert_eq "元の内容が保持される" "既存" "$(cat "$V/Knowledge/dup.md")"
}

echo "=== 14. PROMOTE Preferences: Personal wiki linkを検出したらそのactionのみskip ==="
{
  V="$WORK_ROOT/t14/vault"; mkdir -p "$V/Knowledge" "$V/Preferences" "$V/Personal" "$V/Fragments/2026-07"
  echo "dummy" > "$V/Personal/career-private.md"
  NG="$WORK_ROOT/t14/ngwords.txt"; echo "dummyngword" > "$NG"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片D**：Preferencesゲートテスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
       'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
       'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
body = '---\ndate: 2026-07-16\n---\n\n[[Personal/career-private]] への言及\n'
act = {'id': fid, 'action': 'promote', 'target_folder': 'Preferences', 'body': body}
r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, '$NG', dry_run=False, source_cache={})
print(r['applied'], r['reason'])
")"
  assert_contains "Personalリンク検出でapplied=False" "$out" "False"
  assert_contains "理由にpreferences_gate_detected" "$out" "preferences_gate_detected"
  assert_file_not_exists "Preferencesには何も作成されない" "$V/Preferences"/*.md
  SRC="$(cat "$V/Fragments/2026-07/2026-07-15.md")"
  assert_not_contains "Fragments側もマーキングされない（action全体がskip）" "$SRC" "status: promoted"
}

echo "=== 15. PROMOTE Preferences: NGワードを検出したらそのactionのみskip ==="
{
  V="$WORK_ROOT/t15/vault"; mkdir -p "$V/Knowledge" "$V/Preferences" "$V/Personal" "$V/Fragments/2026-07"
  NG="$WORK_ROOT/t15/ngwords.txt"; echo "himitsuword" > "$NG"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片E**：NGワードゲートテスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
       'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
       'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
body = '---\ndate: 2026-07-16\n---\n\nhimitsuword を含む本文\n'
act = {'id': fid, 'action': 'promote', 'target_folder': 'Preferences', 'body': body}
r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, '$NG', dry_run=False, source_cache={})
print(r['applied'], r['reason'])
")"
  assert_contains "NGワード検出でapplied=False" "$out" "False"
  assert_contains "理由にpreferences_gate_detected" "$out" "preferences_gate_detected"
  assert_file_not_exists "Preferencesには何も作成されない" "$V/Preferences"/*.md
}

echo "=== 16. PROMOTE Preferences: 検出なしの場合は正常に適用される（掟4条を満たすクリーンな本文） ==="
{
  V="$WORK_ROOT/t16/vault"; mkdir -p "$V/Knowledge" "$V/Preferences" "$V/Personal" "$V/Fragments/2026-07"
  NG="$WORK_ROOT/t16/ngwords.txt"; echo "somethingelse" > "$NG"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片F**：クリーンなPreferences昇格テスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
       'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
       'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
body = '---\ndate: 2026-07-16\n---\n\n運用ルールの本文（Personalリンクもngwordsも含まない）\n'
act = {'id': fid, 'action': 'promote', 'target_folder': 'Preferences', 'body': body}
r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, '$NG', dry_run=False, source_cache={})
print(r['applied'])
")"
  assert_eq "クリーンな本文はapplied=True" "True" "$out"
  assert_file_exists "Preferencesへ実際に作成される" "$V/Preferences"/*.md
}

echo "=== 17. FIX: 正常系（fix_dateがそのまま適用される・Claude由来の値は無視） ==="
{
  V="$WORK_ROOT/t17/vault"; mkdir -p "$V/Preferences"
  printf -- '---\ndate: 2026-07-01\ntags: [preference]\nproject: x\n---\n\n本文\n' > "$V/Preferences/foo.md"
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Preferences/foo.md').read_text()
rec = {'id': 'inv-abc', 'relpath': 'Preferences/foo.md',
       'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'fix_date': '2026-07-01'}
r = ma.apply_fix(vault, rec, dry_run=False)
print(r['applied'])
")"
  assert_eq "適用成功" "True" "$out"
  assert_contains "updated:がfix_dateで挿入される" "$(cat "$V/Preferences/foo.md")" "updated: 2026-07-01"
}

echo "=== 18. FIX: TOCTOU（Phase1後にノートが変わっていたらskip） ==="
{
  V="$WORK_ROOT/t18/vault"; mkdir -p "$V/Preferences"
  printf -- '---\ndate: 2026-07-01\n---\n\n本文\n' > "$V/Preferences/foo.md"
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Preferences/foo.md').read_text()
stale_sha = hashlib.sha256((text + 'X').encode()).hexdigest()
rec = {'id': 'inv-abc', 'relpath': 'Preferences/foo.md', 'source_sha256': stale_sha, 'fix_date': '2026-07-01'}
r = ma.apply_fix(vault, rec, dry_run=False)
print(r['applied'], r['reason'])
")"
  assert_eq "TOCTOU不一致でskip" "False source_changed_toctou" "$out"
  assert_not_contains "updated:は追加されない" "$(cat "$V/Preferences/foo.md")" "updated:"
}

echo "=== 19. FIX: relpathがVault境界外(..)ならskip ==="
{
  V="$WORK_ROOT/t19/vault"; mkdir -p "$V/Preferences"
  out="$(run_py "
import pathlib
vault = pathlib.Path('$V')
rec = {'id': 'inv-abc', 'relpath': '../../../../etc/passwd', 'source_sha256': 'x', 'fix_date': '2026-07-01'}
r = ma.apply_fix(vault, rec, dry_run=False)
print(r['applied'], r['reason'])
")"
  assert_eq "Vault境界外はvault_boundary_violation" "False vault_boundary_violation" "$out"
}

# --- MERGE用の共通フィクスチャ生成ヘルパ ---
# $1=vault $2=note_aのupdated $3=note_bのupdated
make_merge_pair() {
  local vault="$1" upd_a="$2" upd_b="$3"
  mkdir -p "$vault/Knowledge"
  cat > "$vault/Knowledge/note-a.md" <<EOF
---
date: 2026-07-01
updated: $upd_a
tags: [test]
project: x
aliases:
  - "alias-a"
---

# Note A

## Sec1
content A https://example.com/a 2026-07-01
\`\`\`
code-a
\`\`\`
EOF
  cat > "$vault/Knowledge/note-b.md" <<EOF
---
date: 2026-07-02
updated: $upd_b
tags: [test]
project: x
aliases:
  - "alias-b"
---

# Note B

## Sec2
content B https://example.com/b 2026-07-02
\`\`\`
code-b
\`\`\`
EOF
}

VALID_MERGED_BODY_TEMPLATE='---
date: 2026-07-01
updated: 2026-07-16
tags: [test]
project: x
aliases:
  - "alias-a"
  - "alias-b"
---

# Note A

updated: note-a=%s, note-b=%s

## Sec1
content A https://example.com/a 2026-07-01
```
code-a
```

# Note B

## Sec2
content B https://example.com/b 2026-07-02
```
code-b
```
'

echo "=== 20. MERGE: 正常系＋primary選定（updatedが新しい方が生き残りファイル名の元になる） ==="
{
  V="$WORK_ROOT/t20/vault"
  make_merge_pair "$V" "2026-07-10" "2026-07-12"
  BODY="$(printf -- "$VALID_MERGED_BODY_TEMPLATE" "2026-07-10" "2026-07-12")"
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
ta = (vault/'Knowledge/note-a.md').read_text(); tb = (vault/'Knowledge/note-b.md').read_text()
cid = kmc.stable_pair_id('Knowledge/note-a.md', 'Knowledge/note-b.md')
rec = {'id': cid, 'note_a': 'Knowledge/note-a.md', 'note_b': 'Knowledge/note-b.md', 'folder': 'Knowledge',
       'note_a_sha256': hashlib.sha256(ta.encode()).hexdigest(), 'note_b_sha256': hashlib.sha256(tb.encode()).hexdigest()}
act = {'id': cid, 'action': 'merge', 'body': '''$BODY'''}
r = ma.apply_merge(vault, rec, act, '2026-07-16', dry_run=False,
                    merge_state_dir='$WORK_ROOT/t20/state', merge_lock_file='$WORK_ROOT/t20/lock')
print(r['applied'], r.get('merged_relpath'))
")"
  assert_contains "適用成功" "$out" "True"
  assert_contains "primary=note-b（updatedが新しい）のためファイル名がnote-b--merged-*" "$out" "Knowledge/note-b--merged-20260716.md"
  assert_file_exists "統合ノートが作成される" "$V/Knowledge/note-b--merged-20260716.md"
  A_STUB="$(cat "$V/Knowledge/note-a.md")"
  B_STUB="$(cat "$V/Knowledge/note-b.md")"
  assert_contains "note-aがdeprecated:true化される" "$A_STUB" "deprecated: true"
  assert_contains "note-aにsuperseded_byが付く" "$A_STUB" "superseded_by: [[Knowledge/note-b--merged-20260716]]"
  assert_contains "note-bもdeprecated:true化される" "$B_STUB" "deprecated: true"
}

echo "=== 21. MERGE: primary選定タイ（updated同値/両方欠落）はファイル名昇順で先が生き残る ==="
{
  V="$WORK_ROOT/t21/vault"
  make_merge_pair "$V" "2026-07-10" "2026-07-10"
  BODY="$(printf -- "$VALID_MERGED_BODY_TEMPLATE" "2026-07-10" "2026-07-10")"
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
ta = (vault/'Knowledge/note-a.md').read_text(); tb = (vault/'Knowledge/note-b.md').read_text()
cid = kmc.stable_pair_id('Knowledge/note-a.md', 'Knowledge/note-b.md')
rec = {'id': cid, 'note_a': 'Knowledge/note-a.md', 'note_b': 'Knowledge/note-b.md', 'folder': 'Knowledge',
       'note_a_sha256': hashlib.sha256(ta.encode()).hexdigest(), 'note_b_sha256': hashlib.sha256(tb.encode()).hexdigest()}
act = {'id': cid, 'action': 'merge', 'body': '''$BODY'''}
r = ma.apply_merge(vault, rec, act, '2026-07-16', dry_run=False,
                    merge_state_dir='$WORK_ROOT/t21/state', merge_lock_file='$WORK_ROOT/t21/lock')
print(r.get('merged_relpath'))
")"
  assert_eq "同値タイならnote-a（ファイル名昇順で先）が生き残る" "Knowledge/note-a--merged-20260716.md" "$out"
}

echo "=== 22. MERGE: TOCTOU（Phase1後にnote_bが変わっていたらskip・両ノートとも無変更） ==="
{
  V="$WORK_ROOT/t22/vault"
  make_merge_pair "$V" "2026-07-10" "2026-07-12"
  BODY="$(printf -- "$VALID_MERGED_BODY_TEMPLATE" "2026-07-10" "2026-07-12")"
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
ta = (vault/'Knowledge/note-a.md').read_text(); tb = (vault/'Knowledge/note-b.md').read_text()
cid = kmc.stable_pair_id('Knowledge/note-a.md', 'Knowledge/note-b.md')
stale_sha_b = hashlib.sha256((tb + 'X').encode()).hexdigest()
rec = {'id': cid, 'note_a': 'Knowledge/note-a.md', 'note_b': 'Knowledge/note-b.md', 'folder': 'Knowledge',
       'note_a_sha256': hashlib.sha256(ta.encode()).hexdigest(), 'note_b_sha256': stale_sha_b}
act = {'id': cid, 'action': 'merge', 'body': '''$BODY'''}
r = ma.apply_merge(vault, rec, act, '2026-07-16', dry_run=False,
                    merge_state_dir='$WORK_ROOT/t22/state', merge_lock_file='$WORK_ROOT/t22/lock')
print(r['applied'], r['reason'])
")"
  assert_eq "TOCTOU不一致でskip" "False note_changed_toctou" "$out"
  assert_not_contains "note-aは変更されない" "$(cat "$V/Knowledge/note-a.md")" "deprecated"
  assert_not_contains "note-bも変更されない" "$(cat "$V/Knowledge/note-b.md")" "deprecated"
}

echo "=== 23. MERGE: merge_checks.py不合格（見出し欠落）ならVaultに一切書き込まずskip ==="
{
  V="$WORK_ROOT/t23/vault"
  make_merge_pair "$V" "2026-07-10" "2026-07-12"
  # 意図的に "# Note A" 見出しを欠落させた不正な統合本文
  BAD_BODY='---
date: 2026-07-01
updated: 2026-07-16
tags: [test]
project: x
aliases:
  - "alias-a"
  - "alias-b"
---

# Note B

## Sec1
content A https://example.com/a 2026-07-01
```
code-a
```

## Sec2
content B https://example.com/b 2026-07-02
```
code-b
```
'
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
ta = (vault/'Knowledge/note-a.md').read_text(); tb = (vault/'Knowledge/note-b.md').read_text()
cid = kmc.stable_pair_id('Knowledge/note-a.md', 'Knowledge/note-b.md')
rec = {'id': cid, 'note_a': 'Knowledge/note-a.md', 'note_b': 'Knowledge/note-b.md', 'folder': 'Knowledge',
       'note_a_sha256': hashlib.sha256(ta.encode()).hexdigest(), 'note_b_sha256': hashlib.sha256(tb.encode()).hexdigest()}
act = {'id': cid, 'action': 'merge', 'body': '''$BAD_BODY'''}
r = ma.apply_merge(vault, rec, act, '2026-07-16', dry_run=False,
                    merge_state_dir='$WORK_ROOT/t23/state', merge_lock_file='$WORK_ROOT/t23/lock')
print(r['applied'], r['reason'])
print('Note A' in r['check_detail']['structural']['missing_headings'])
")"
  assert_contains "merge_checks不合格でapplied=False" "$out" "False merge_checks_failed"
  assert_contains "missing_headingsに'Note A'が載る" "$out" "True"
  assert_file_not_exists "統合ノートは作成されない" "$V/Knowledge"/*merged*.md
  assert_not_contains "note-aは変更されない" "$(cat "$V/Knowledge/note-a.md")" "deprecated"
  assert_not_contains "note-bは変更されない" "$(cat "$V/Knowledge/note-b.md")" "deprecated"
}

echo "=== 24. MERGE: note_a/note_bがKnowledge直下1階層でない(サブディレクトリ)候補はnot_merge_eligible ==="
{
  V="$WORK_ROOT/t24/vault"; mkdir -p "$V/Knowledge/sub"
  out="$(run_py "
rec = {'id': 'cand-x', 'note_a': 'Knowledge/sub/a.md', 'note_b': 'Knowledge/b.md', 'folder': 'Knowledge',
       'note_a_sha256': 'x', 'note_b_sha256': 'y'}
act = {'id': 'cand-x', 'action': 'merge', 'body': '---\nx\n---\n'}
r = ma.apply_merge('$V', rec, act, '2026-07-16', dry_run=False,
                    merge_state_dir='$WORK_ROOT/t24/state', merge_lock_file='$WORK_ROOT/t24/lock')
print(r['applied'], r['reason'])
")"
  assert_eq "サブディレクトリ経由はnot_merge_eligible" "False not_merge_eligible" "$out"
}

echo "=== 25. MERGE: 週上限（max_merge_actions）を超えた分はapply_actions()レベルでskipされる ==="
{
  V="$WORK_ROOT/t25/vault"; mkdir -p "$V/Knowledge"
  # 3組の独立したペアを用意し、cap=2で3件目がcapで弾かれることを確認する。
  make_pair() {
    local n="$1"
    cat > "$V/Knowledge/a$n.md" <<EOF
---
date: 2026-07-01
updated: 2026-07-10
tags: [test]
project: x
---
# A$n
本文A$n
EOF
    cat > "$V/Knowledge/b$n.md" <<EOF
---
date: 2026-07-01
updated: 2026-07-10
tags: [test]
project: x
---
# B$n
本文B$n
EOF
  }
  make_pair 1; make_pair 2; make_pair 3
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
fragments_by_id, fix_by_id, merge_by_id = {}, {}, {}
actions = []
for n in (1, 2, 3):
    ta = (vault/f'Knowledge/a{n}.md').read_text(); tb = (vault/f'Knowledge/b{n}.md').read_text()
    cid = kmc.stable_pair_id(f'Knowledge/a{n}.md', f'Knowledge/b{n}.md')
    merge_by_id[cid] = {'id': cid, 'note_a': f'Knowledge/a{n}.md', 'note_b': f'Knowledge/b{n}.md', 'folder': 'Knowledge',
                         'note_a_sha256': hashlib.sha256(ta.encode()).hexdigest(),
                         'note_b_sha256': hashlib.sha256(tb.encode()).hexdigest()}
    body = (f'---\ndate: 2026-07-01\nupdated: 2026-07-16\ntags: [test]\nproject: x\n---\n'
            f'# A{n}\n本文A{n}（原updated: 2026-07-10）\n# B{n}\n本文B{n}（原updated: 2026-07-10）\n')
    actions.append({'id': cid, 'action': 'merge', 'body': body})
results = ma.apply_actions(vault, actions, fragments_by_id, fix_by_id, merge_by_id, today_iso='2026-07-16',
                            max_merge_actions=2, gate_script=ma.DEFAULT_GATE_SCRIPT, ngwords_file=ma.DEFAULT_NGWORDS_FILE,
                            dry_run=False, merge_state_dir='$WORK_ROOT/t25/state', merge_lock_file='$WORK_ROOT/t25/lock')
applied = [r['applied'] for r in results]
reasons = [r.get('reason') for r in results]
print(applied)
print(reasons)
")"
  assert_contains "1・2件目は適用・3件目は上限で不適用" "$out" "[True, True, False]"
  assert_contains "3件目の理由はmerge_weekly_cap_exceeded" "$out" "merge_weekly_cap_exceeded"
}

echo "=== 26. build_merge_stub_text/determine_primary: frontmatterが無い原ノートはNoneを返す ==="
{
  out="$(run_py "
print(ma.build_merge_stub_text('frontmatterの無い本文だけ', 'Knowledge/merged.md', '2026-07-16'))
")"
  assert_eq "frontmatter無しはNone" "None" "$out"
}

echo "=== 27. PROMOTE: 同一Fragments日次ファイルから複数件PROMOTEしても2件目以降が誤ってTOCTOUでskipされない ==="
{
  V="$WORK_ROOT/t27b/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片X**：同一ファイル複数PROMOTEテスト用の断片本文Xです。
- **断片Y**：同一ファイル複数PROMOTEテスト用の断片本文Yです。
EOF
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
assert len(entries) == 2, entries
sha = hashlib.sha256(text.encode()).hexdigest()
source_cache = {}
results = []
for heading, status, body in entries:
    fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', heading)
    rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md', 'source_sha256': sha,
           'date': '2026-07-15', 'heading_or_bullet': heading, 'body': body}
    act = {'id': fid, 'action': 'promote', 'target_folder': 'Knowledge',
           'body': f'---\ndate: 2026-07-16\n---\n\n{heading}の本文\n'}
    r = ma.apply_promote(vault, rec, act, '2026-07-16', ma.DEFAULT_GATE_SCRIPT, ma.DEFAULT_NGWORDS_FILE,
                          dry_run=False, source_cache=source_cache)
    results.append((r['applied'], r.get('reason')))
print(results)
")"
  assert_eq "2件とも適用成功（2件目がTOCTOUで誤skipされない）" "[(True, None), (True, None)]" "$out"
  assert_eq "Knowledgeに新規ノートが2件作成される" "2" "$(find "$V/Knowledge" -name '*.md' | wc -l | tr -d ' ')"
  SRC="$(cat "$V/Fragments/2026-07/2026-07-15.md")"
  N_MARKED="$(grep -c 'status: promoted' <<< "$SRC")"
  assert_eq "Fragments側は2件ともmarkされる" "2" "$N_MARKED"
}

echo "=== 28. validate_structured_output: action要素の未知キーは応答全体を不採用（additionalProperties相当） ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'skip', 'unexpected_field': 'x'}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(actions, 'ERR' if err else 'NOERR')
")"
  assert_contains "未知キーで不採用" "$out" "None ERR"
}

echo "=== 29. validate_structured_output: トップレベルの未知キーは応答全体を不採用 ==="
{
  out="$(run_py "
data = {'actions': [], 'unexpected_top': 1}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(actions, 'ERR' if err else 'NOERR')
")"
  assert_contains "トップレベル未知キーで不採用" "$out" "None ERR"
}

echo "=== 30. validate_structured_output: reasonが文字列でなければ不採用 ==="
{
  out="$(run_py "
data = {'actions': [{'id': 'frag-1', 'action': 'skip', 'reason': 123}]}
actions, err = ma.validate_structured_output(data, {'frag-1'}, set(), set())
print(actions, 'ERR' if err else 'NOERR')
")"
  assert_contains "reason型不正で不採用" "$out" "None ERR"
}

echo "=== 31. Phase1レコード再検証: idがsource_relpath+heading_or_bulletの再計算値と一致しないfragmentは除外される ==="
{
  out="$(run_py "
warnings = []
tampered = {'id': 'frag-000000000000', 'source_relpath': 'Fragments/2026-07/x.md',
            'source_sha256': 'a'*64, 'date': '2026-07-15', 'heading_or_bullet': '断片Z', 'body': '本文'}
by_id = ma._index_by_id_no_collision([tampered], ma._validate_fragment_record, 'fragments_records', warnings)
print(list(by_id.keys()))
print(len(warnings) > 0)
")"
  assert_eq "id再計算不一致のレコードは除外される" "[]
True" "$out"
}

echo "=== 32. Phase1レコード再検証: Preferences以外を指すFIXレコードは除外される（設計書§3.5の範囲外） ==="
{
  out="$(run_py "
import vault_inventory, datetime
warnings = []
rid = vault_inventory.stable_fix_id('Knowledge/not-preferences.md')
tampered = {'id': rid, 'relpath': 'Knowledge/not-preferences.md', 'source_sha256': 'a'*64,
            'fixable': True, 'fix_date': '2026-07-01', 'skip_reason': None}
by_id = ma._index_by_id_no_collision([tampered],
    lambda r, rec: ma._validate_fix_record(r, rec, datetime.date(2026, 7, 16)), 'fix_records', warnings)
print(list(by_id.keys()))
")"
  assert_eq "Preferences以外のFIXレコードは除外される" "[]" "$out"
}

echo "=== 33. Phase1レコード再検証: cidがnote_a/note_bの再計算値と一致しないmergeレコードは除外される ==="
{
  out="$(run_py "
warnings = []
tampered = {'note_a': 'Knowledge/a.md', 'note_b': 'Knowledge/b.md', 'folder': 'Knowledge',
            'note_a_sha256': 'a'*64, 'note_b_sha256': 'b'*64}
by_id = ma._index_by_id_no_collision([dict(tampered, id='cand-not-matching-hash')],
                                      ma._validate_merge_record, 'merge_records', warnings)
print(list(by_id.keys()))
")"
  assert_eq "cid不一致のmergeレコードは除外される" "[]" "$out"
}

echo "=== 34. Phase1レコード再検証: 同一Phase1出力内でidが衝突する場合は両方とも除外される ==="
{
  out="$(run_py "
warnings = []
records = [
  {'id': 'frag-dup000000', 'source_relpath': 'Fragments/x.md', 'source_sha256': 'a'*64,
   'heading_or_bullet': 'タイトルA', 'body': 'A'},
  {'id': 'frag-dup000000', 'source_relpath': 'Fragments/x.md', 'source_sha256': 'a'*64,
   'heading_or_bullet': 'タイトルB', 'body': 'B'},
]
by_id = ma._index_by_id_no_collision(records, ma._validate_fragment_record, 'fragments_records', warnings)
print(list(by_id.keys()))
print(any('衝突' in w for w in warnings))
")"
  assert_eq "衝突id2件とも除外され、警告が記録される" "[]
True" "$out"
}

echo "=== 35. apply_actions(): 1件のactionで予期しない例外が起きても他のactionの処理は継続する ==="
{
  V="$WORK_ROOT/t35/vault"; mkdir -p "$V/Preferences"
  printf -- '---\ndate: 2026-07-01\n---\n\n本文\n' > "$V/Preferences/foo.md"
  out="$(run_py "
import hashlib, pathlib
vault = pathlib.Path('$V')
text = (vault/'Preferences/foo.md').read_text()
fix_by_id = {'inv-abc': {'id': 'inv-abc', 'relpath': 'Preferences/foo.md',
             'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'fix_date': '2026-07-01'}}
actions = [
  {'id': 'inv-missing-from-dict', 'action': 'fix_approve'},  # fix_by_idに無いkeyで例外を誘発
  {'id': 'inv-abc', 'action': 'fix_approve'},
]
results = ma.apply_actions(vault, actions, {}, fix_by_id, {}, today_iso='2026-07-16', max_merge_actions=2,
                            gate_script=ma.DEFAULT_GATE_SCRIPT, ngwords_file=ma.DEFAULT_NGWORDS_FILE,
                            dry_run=False, merge_state_dir='$WORK_ROOT/t35/state', merge_lock_file='$WORK_ROOT/t35/lock')
print([(r['applied'], 'unexpected_exception' in (r.get('reason') or '')) for r in results])
")"
  assert_eq "1件目は例外を捕捉してapplied=False、2件目は正常に適用される" "[(False, True), (True, False)]" "$out"
  assert_contains "2件目（正常なFIX）は実際に反映される" "$(cat "$V/Preferences/foo.md")" "updated: 2026-07-01"
}

echo "=== 36. find_existing_promoted_file: symlinkは既存の昇格済みファイルとみなさない ==="
{
  V="$WORK_ROOT/t36/vault"; mkdir -p "$V/Knowledge" "$V/Decisions"
  echo "リンク先" > "$WORK_ROOT/t36/outside.md"
  ln -s "$WORK_ROOT/t36/outside.md" "$V/Knowledge/dummy-slug.md"
  out="$(run_py "
r = ma.find_existing_promoted_file('$V', 'dummy-slug')
print(r)
")"
  assert_eq "symlinkは無視されNoneが返る" "None" "$out"
}

echo "=== 37. invoke_claude: permission_denialsがlist型でなければ異常扱い（fail-closed） ==="
{
  mkdir -p "$WORK_ROOT/t37"
  RESP="$WORK_ROOT/t37/response.json"
  cat > "$RESP" <<'EOF'
{"is_error": false, "permission_denials": "not-a-list", "structured_output": {"actions": []}}
EOF
  FAKE37="$WORK_ROOT/t37/fake.sh"
  printf '#!/usr/bin/env bash\ncat > /dev/null\ncat "%s"\n' "$RESP" > "$FAKE37"
  chmod +x "$FAKE37"
  out="$(run_py "
structured, kind, detail = ma.invoke_claude('$FAKE37', 'sonnet', '/dev/null', {'type': 'object'}, {}, 10)
print(structured, kind)
")"
  assert_eq "非list型permission_denialsはtool_use_detectedとして異常扱い" "None tool_use_detected" "$out"
}

echo "=== 38. MERGE: merge_checks実行中(=書込前の時間のかかる区間)にnote_bが変わったら統合ノート作成後もstub化しない ==="
{
  V="$WORK_ROOT/t38/vault"
  make_merge_pair "$V" "2026-07-10" "2026-07-12"
  BODY="$(printf -- "$VALID_MERGED_BODY_TEMPLATE" "2026-07-10" "2026-07-12")"
  out="$(run_py "
import hashlib, pathlib
import merge_checks
vault = pathlib.Path('$V')
ta = (vault/'Knowledge/note-a.md').read_text(); tb_orig = (vault/'Knowledge/note-b.md').read_text()
cid = kmc.stable_pair_id('Knowledge/note-a.md', 'Knowledge/note-b.md')
rec = {'id': cid, 'note_a': 'Knowledge/note-a.md', 'note_b': 'Knowledge/note-b.md', 'folder': 'Knowledge',
       'note_a_sha256': hashlib.sha256(ta.encode()).hexdigest(), 'note_b_sha256': hashlib.sha256(tb_orig.encode()).hexdigest()}
act = {'id': cid, 'action': 'merge', 'body': '''$BODY'''}

_orig_run_all_checks = merge_checks.run_all_checks
def _racing_run_all_checks(*a, **kw):
    # merge_checks実行中に別プロセス(想定)がnote_bを書き換える競合を模擬する。
    (vault/'Knowledge/note-b.md').write_text(tb_orig + '\n追記された行\n')
    return _orig_run_all_checks(*a, **kw)
merge_checks.run_all_checks = _racing_run_all_checks
try:
    r = ma.apply_merge(vault, rec, act, '2026-07-16', dry_run=False,
                        merge_state_dir='$WORK_ROOT/t38/state', merge_lock_file='$WORK_ROOT/t38/lock')
finally:
    merge_checks.run_all_checks = _orig_run_all_checks
print(r['applied'], r.get('partial_merge_state'), r.get('reason'))
")"
  assert_contains "applied=True・partial_merge_state=True（統合ノートは既に作成済みのため）" "$out" "True True"
  assert_file_exists "統合ノート自体は作成される" "$V/Knowledge/note-b--merged-20260716.md"
  A_TEXT="$(cat "$V/Knowledge/note-a.md")"
  B_TEXT="$(cat "$V/Knowledge/note-b.md")"
  assert_not_contains "note-aはstub化されない（partial検知で書込み中止）" "$A_TEXT" "deprecated"
  assert_not_contains "note-bもstub化されない" "$B_TEXT" "deprecated"
  assert_contains "note-bには競合で追記された内容が残る（上書きされていない証拠）" "$B_TEXT" "追記された行"
}

echo "=== 39. Phase1レコード再検証: source_relpathの'..'によるVault内フォルダ逸脱は拒否される ==="
{
  out="$(run_py "
warnings = []
tampered_relpath = 'Fragments/../Preferences/2026-07-15.md'
tampered = {'id': fragments_log.stable_fragment_id(tampered_relpath, '見出し'), 'source_relpath': tampered_relpath,
            'source_sha256': 'a'*64, 'heading_or_bullet': '見出し', 'body': '本文'}
by_id = ma._index_by_id_no_collision([tampered], ma._validate_fragment_record, 'fragments_records', warnings)
print(list(by_id.keys()))
")"
  assert_eq "'..'を含むsource_relpathは除外される" "[]" "$out"
}

echo "=== 40. Phase1レコード再検証: 実在しない暦日(2026-99-99等)のsource_relpathは拒否される ==="
{
  out="$(run_py "
warnings = []
bad_relpath = 'Fragments/2026-07/2026-99-99.md'
tampered = {'id': fragments_log.stable_fragment_id(bad_relpath, '見出し'), 'source_relpath': bad_relpath,
            'source_sha256': 'a'*64, 'heading_or_bullet': '見出し', 'body': '本文'}
by_id = ma._index_by_id_no_collision([tampered], ma._validate_fragment_record, 'fragments_records', warnings)
print(list(by_id.keys()))
")"
  assert_eq "実在しない暦日は除外される" "[]" "$out"
}

echo "=== 41. _summarize_results: partial_merge_stateが1件でもあればanomaly=Trueになる（純粋関数の直接テスト） ==="
{
  out="$(run_py "
results = [
  {'id': 'frag-1', 'action': 'promote', 'applied': True},
  {'id': 'cand-1', 'action': 'merge', 'applied': True, 'partial_merge_state': True},
  {'id': 'cand-2', 'action': 'merge', 'applied': True},
  {'id': 'inv-1', 'action': 'fix_approve', 'applied': False, 'reason': 'x'},
]
s = ma._summarize_results(results)
print(s['n_promoted'], s['n_merged'], s['n_merged_partial'], s['n_fixed'], s['n_skipped'], s['has_anomaly'])
")"
  assert_eq "n_merged=1(正常のみ)・n_merged_partial=1・has_anomaly=True" "1 1 1 0 1 True" "$out"
}

echo "=== 42. find_existing_promoted_file: 対象フォルダ自体がsymlinkの場合は既存の昇格済みファイルとみなさない ==="
{
  V="$WORK_ROOT/t42/vault"; mkdir -p "$V"
  OUTSIDE="$WORK_ROOT/t42/outside-dir"; mkdir -p "$OUTSIDE"
  echo "Vault外の無関係な内容" > "$OUTSIDE/dummy-slug.md"
  ln -s "$OUTSIDE" "$V/Knowledge"
  mkdir -p "$V/Decisions" "$V/Projects" "$V/Preferences"
  out="$(run_py "
r = ma.find_existing_promoted_file('$V', 'dummy-slug')
print(r)
")"
  assert_eq "Knowledgeフォルダ自体がsymlinkの場合はNoneが返る（誤って既存とみなさない）" "None" "$out"
}

echo "=== 43. PROMOTE: 最終書込み直前の再照合で外部変更を検知しstep2を書き込まない（自分自身の直前書込みとは区別） ==="
{
  V="$WORK_ROOT/t43/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片P**：PROMOTE最終再照合の競合注入テスト用の断片本文です。
EOF
  out="$(run_py "
import hashlib, pathlib
import maintenance_apply as ma_mod
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
sha = hashlib.sha256(text.encode()).hexdigest()
rec = {'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md', 'source_sha256': sha,
       'date': '2026-07-15', 'heading_or_bullet': entries[0][0], 'body': entries[0][2]}
act = {'id': fid, 'action': 'promote', 'target_folder': 'Knowledge', 'body': '---\ndate: 2026-07-16\n---\n\n本文\n'}

_orig_exclusive_create = ma_mod.exclusive_create
def _racing_exclusive_create(path, body):
    # O_EXCL作成中(=最終再照合より前)に外部プロセスがFragments原文を書き換える競合を模擬する。
    (vault/'Fragments/2026-07/2026-07-15.md').write_text(text + '\n外部から追記された行\n')
    return _orig_exclusive_create(path, body)
ma_mod.exclusive_create = _racing_exclusive_create
try:
    r = ma_mod.apply_promote(vault, rec, act, '2026-07-16', ma_mod.DEFAULT_GATE_SCRIPT,
                              ma_mod.DEFAULT_NGWORDS_FILE, dry_run=False, source_cache={})
finally:
    ma_mod.exclusive_create = _orig_exclusive_create
print(r['applied'], r.get('step1'), r.get('step2'))
")"
  assert_contains "step1は成功済み(created)・step2は最終再照合で見送り" "$out" "created source_changed_at_final_recheck"
  SRC="$(cat "$V/Fragments/2026-07/2026-07-15.md")"
  assert_not_contains "Fragments側にstatus:promotedは追記されない" "$SRC" "status: promoted"
  assert_contains "外部からの追記内容は残る（上書きされていない証拠）" "$SRC" "外部から追記された行"
}
# =============================================================================
# (b) CLI end-to-end テスト（fake claudeバイナリ経由）
# =============================================================================

# fake claude バイナリを生成する。
# 制御用環境変数:
#   FAKE_CLAUDE_MODE      = respond(既定) / sleep / nonzero / garbage
#   FAKE_CLAUDE_RESPONSE_FILE = respond時に標準出力へcatする応答JSONファイル
#   FAKE_CLAUDE_SLEEP_SECONDS = sleepモードの秒数
#   FAKE_CLAUDE_SAVE_ARGV / FAKE_CLAUDE_SAVE_STDIN = 呼び出し引数/標準入力の保存先（検証用）
FAKE_CLAUDE="$WORK_ROOT/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'FAKEEOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_CLAUDE_SAVE_STDIN:-}" ]]; then cat > "$FAKE_CLAUDE_SAVE_STDIN"; else cat >/dev/null; fi
if [[ -n "${FAKE_CLAUDE_SAVE_ARGV:-}" ]]; then printf '%s\n' "$@" > "$FAKE_CLAUDE_SAVE_ARGV"; fi
case "${FAKE_CLAUDE_MODE:-respond}" in
  sleep) sleep "${FAKE_CLAUDE_SLEEP_SECONDS:-5}"; echo '{}' ;;
  nonzero) echo "boom" >&2; exit 1 ;;
  garbage) echo 'not-json{{' ;;
  respond) cat "$FAKE_CLAUDE_RESPONSE_FILE" ;;
esac
FAKEEOF
chmod +x "$FAKE_CLAUDE"

run_apply_cli() {
  # $1=vault $2=workdir。以降は追加引数。
  local vault="$1" workdir="$2"; shift 2
  python3 "$SCRIPT" --vault "$vault" --workdir "$workdir" --claude-bin "$FAKE_CLAUDE" "$@"
}

echo "=== 44. main(): fragments-jsonのトップレベルが配列などdict以外の場合はanomaly（クラッシュしない） ==="
{
  V="$WORK_ROOT/t44/vault"; mkdir -p "$V/Knowledge"
  FJSON="$WORK_ROOT/t44/fragments.json"; echo '[]' > "$FJSON"
  W="$WORK_ROOT/t44/work"
  run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t44/stdout.txt" 2>&1
  RC=$?
  assert_eq "クラッシュせずexit 0" "0" "$RC"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true・reasonにphase1_input_invalid" "$STATUS" "phase1_input_invalid"
}

echo "=== 45. main(): fragmentsキーが配列でない場合もanomaly扱いになる（候補0件が静かなno_candidatesに丸め込まれない） ==="
{
  V="$WORK_ROOT/t45/vault"; mkdir -p "$V/Knowledge"
  FJSON="$WORK_ROOT/t45/fragments.json"; echo '{"fragments": "broken"}' > "$FJSON"
  W="$WORK_ROOT/t45/work"
  run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t45/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true・reasonにphase1_input_invalid" "$STATUS" "phase1_input_invalid"
}

echo "=== 46. main(): fragments配列内に非オブジェクト要素が混ざっていてもクラッシュせず除外される ==="
{
  V="$WORK_ROOT/t46/vault"; mkdir -p "$V/Knowledge"
  FJSON="$WORK_ROOT/t46/fragments.json"; echo '{"fragments": [42, "x", null]}' > "$FJSON"
  W="$WORK_ROOT/t46/work"
  run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t46/stdout.txt" 2>&1
  RC=$?
  assert_eq "クラッシュせずexit 0" "0" "$RC"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "非オブジェクト要素のみ→全滅扱いでanomaly" "$STATUS" "phase1_input_invalid"
}

echo "=== 47. main(): inventoryのmissing_updated_fix_candidatesキーが丸ごと欠落していたらanomaly ==="
{
  V="$WORK_ROOT/t47b/vault"; mkdir -p "$V/Knowledge"
  IJSON="$WORK_ROOT/t47b/inventory.json"; echo '{"date": "2026-07-16", "n_issues": 0}' > "$IJSON"
  W="$WORK_ROOT/t47b/work"
  run_apply_cli "$V" "$W" --inventory-json "$IJSON" > "$WORK_ROOT/t47b/stdout.txt" 2>&1
  RC=$?
  assert_eq "クラッシュせずexit 0" "0" "$RC"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "キー欠落はanomaly=phase1_input_invalid" "$STATUS" "phase1_input_invalid"
}

echo "=== 48. main(): missing_updated_fix_candidatesが明示的にnullの場合もanomaly（配列でない値の一種として扱う） ==="
{
  V="$WORK_ROOT/t48b/vault"; mkdir -p "$V/Knowledge"
  IJSON="$WORK_ROOT/t48b/inventory.json"; echo '{"missing_updated_fix_candidates": null}' > "$IJSON"
  W="$WORK_ROOT/t48b/work"
  run_apply_cli "$V" "$W" --inventory-json "$IJSON" > "$WORK_ROOT/t48b/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "null値もanomaly=phase1_input_invalid" "$STATUS" "phase1_input_invalid"
}

echo "=== 49. main(): missing_updated_fix_candidates内の非オブジェクト要素はクラッシュせず除外される（fixable=Falseの正常な要素と区別） ==="
{
  V="$WORK_ROOT/t49b/vault"; mkdir -p "$V/Preferences"
  IJSON="$WORK_ROOT/t49b/inventory.json"
  cat > "$IJSON" <<'EOF'
{"missing_updated_fix_candidates": [
  42,
  {"id": "inv-x", "relpath": "Preferences/normal-skip.md", "fixable": false, "skip_reason": "no_date_field"}
]}
EOF
  W="$WORK_ROOT/t49b/work"
  run_apply_cli "$V" "$W" --inventory-json "$IJSON" > "$WORK_ROOT/t49b/stdout.txt" 2>&1
  RC=$?
  assert_eq "クラッシュせずexit 0" "0" "$RC"
  STATUS="$(cat "$W/apply-status.json")"
  # fixable=falseの要素だけなら正常な「今回は対象0件」週と区別できない
  # （非オブジェクト要素1件のみが構造異常のシグナル）が、input_load_failuresの
  # 計上により正しくanomalyへ倒れることを確認する。
  assert_contains "非オブジェクト要素混入によりanomaly" "$STATUS" "phase1_input_invalid"
}

echo "=== 50. main(): fixableがbool型でない要素(欠落/文字列/数値/null)はfixable=falseの正常要素と区別してanomaly ==="
{
  for variant in 'missing' 'string' 'number' 'null'; do
    V="$WORK_ROOT/t49c-$variant/vault"; mkdir -p "$V/Preferences"
    IJSON="$WORK_ROOT/t49c-$variant/inventory.json"; mkdir -p "$WORK_ROOT/t49c-$variant"
    case "$variant" in
      missing) echo '{"missing_updated_fix_candidates": [{"id": "inv-x", "relpath": "Preferences/a.md"}]}' > "$IJSON" ;;
      string)  echo '{"missing_updated_fix_candidates": [{"id": "inv-x", "relpath": "Preferences/a.md", "fixable": "true"}]}' > "$IJSON" ;;
      number)  echo '{"missing_updated_fix_candidates": [{"id": "inv-x", "relpath": "Preferences/a.md", "fixable": 1}]}' > "$IJSON" ;;
      null)    echo '{"missing_updated_fix_candidates": [{"id": "inv-x", "relpath": "Preferences/a.md", "fixable": null}]}' > "$IJSON" ;;
    esac
    W="$WORK_ROOT/t49c-$variant/work"
    run_apply_cli "$V" "$W" --inventory-json "$IJSON" > "$WORK_ROOT/t49c-$variant/stdout.txt" 2>&1
    RC=$?
    assert_eq "variant=$variant: クラッシュせずexit 0" "0" "$RC"
    STATUS="$(cat "$W/apply-status.json")"
    assert_contains "variant=$variant: fixable非bool型はanomaly" "$STATUS" "phase1_input_invalid"
  done
}

echo "=== 51. main(): fixable=falseのみ（正常な修正不可検出）の週はanomalyにならない（誤検知しないことの陽性対照） ==="
{
  V="$WORK_ROOT/t49d/vault"; mkdir -p "$V/Preferences"
  IJSON="$WORK_ROOT/t49d/inventory.json"
  echo '{"missing_updated_fix_candidates": [{"id": "inv-x", "relpath": "Preferences/a.md", "fixable": false, "skip_reason": "no_date_field"}]}' > "$IJSON"
  W="$WORK_ROOT/t49d/work"
  run_apply_cli "$V" "$W" --inventory-json "$IJSON" > "$WORK_ROOT/t49d/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "fixable=falseのみは正常なno_candidates（anomalyではない）" "$STATUS" '"anomaly": false'
  assert_contains "reasonはno_candidates" "$STATUS" "no_candidates"
}

echo "=== 52. FIX: 最終書込み直前の再照合で外部変更を検知しupdated:を書き込まない ==="
{
  V="$WORK_ROOT/t50b/vault"; mkdir -p "$V/Preferences"
  printf -- '---\ndate: 2026-07-01\n---\n\n本文\n' > "$V/Preferences/foo.md"
  out="$(run_py "
import hashlib, pathlib
import maintenance_apply as ma_mod
vault = pathlib.Path('$V')
text = (vault/'Preferences/foo.md').read_text()
fix_rec = {'id': 'inv-abc', 'relpath': 'Preferences/foo.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'fix_date': '2026-07-01'}

_orig_apply_fix_updated = ma_mod.apply_fix_updated
def _racing_apply_fix_updated(current_text, fix_date):
    # apply_fix_updated()呼び出し中(=最終再照合より前)に外部プロセスがノートを書き換える競合を模擬する。
    (vault/'Preferences/foo.md').write_text(text + '\n外部から追記された行\n')
    return _orig_apply_fix_updated(current_text, fix_date)
ma_mod.apply_fix_updated = _racing_apply_fix_updated
try:
    r = ma_mod.apply_fix(vault, fix_rec, dry_run=False)
finally:
    ma_mod.apply_fix_updated = _orig_apply_fix_updated
print(r['applied'], r.get('reason'))
")"
  assert_eq "最終再照合で外部変更を検知しapplied=False" "False source_changed_at_final_recheck" "$out"
  NOW="$(cat "$V/Preferences/foo.md")"
  assert_not_contains "updated:は書き込まれない" "$NOW" "updated:"
  assert_contains "外部からの追記内容は残る（上書きされていない証拠）" "$NOW" "外部から追記された行"
}

echo "=== 53. main(): 候補が0件ならclaudeを起動せずok/no_candidatesで終了 ==="
{
  V="$WORK_ROOT/t27/vault"; mkdir -p "$V/Knowledge"
  W="$WORK_ROOT/t27/work"
  ARGV_FILE="$WORK_ROOT/t27/argv.txt"; rm -f "$ARGV_FILE"
  FAKE_CLAUDE_SAVE_ARGV="$ARGV_FILE" run_apply_cli "$V" "$W" >/dev/null 2>&1
  assert_file_not_exists "候補0件ならclaudeは起動されない（argvファイル未生成）" "$ARGV_FILE"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "status.ok=true" "$STATUS" '"ok": true'
  assert_contains "reason=no_candidates" "$STATUS" "no_candidates"
  # tester独立検証F2で実測: _write_status_file()の呼び出し箇所の一部で
  # n_merged_partialキーが欠落しており、maintenance.sh側の7キー必須検証で
  # 静穏週のたびに偽anomaly判定→last_success_atが進まず--sinceが巻き戻らない
  # 実害があった（2026-07-16）。単一ヘルパでの既定値保証（_write_status_file
  # 内のdictマージ）に修正したことを、maintenance.sh側と同じ7キー全てが
  # 存在することを直接assertして固定する（キー名の変更・追加漏れを機械的に
  # 検出できるようにする）。
  MISSING_KEYS="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
required = ['ok', 'anomaly', 'n_promoted', 'n_merged', 'n_merged_partial', 'n_fixed', 'n_skipped']
missing = [k for k in required if k not in d]
print(','.join(missing))
" "$W/apply-status.json")"
  assert_eq "候補0件の正常系status.jsonに7必須キー(F2回帰テスト)が全て揃っている(欠落無し)" "" "$MISSING_KEYS"
}

echo "=== 53b. _write_status_file(): 個数系キーを省略しても常に7必須キー全てが書かれる（tester独立検証F2対応・単一ヘルパでの根治確認） ==="
{
  # 呼び出し箇所ごとの個別補完ではなく_write_status_file()自体が個数系5キー
  # （n_promoted/n_merged/n_merged_partial/n_fixed/n_skipped）の既定値(0)を
  # 保証する設計に修正した（tester独立検証F2＝5呼び出し箇所中複数箇所で
  # n_merged_partialが欠落しmaintenance.sh側の7キー必須検証で静穏週のたびに
  # 偽anomaly判定が起きていた実害への対応）。呼び出し側の個々のcall siteを
  # 網羅するより、ヘルパ自体の契約を直接検証する方が将来の呼び出し追加にも
  # 頑健（新しい呼び出し箇所を追加しても、個数系キーを省略するだけで自動的に
  # 契約を満たせる）。
  OUT="$WORK_ROOT/t27b/status.json"; mkdir -p "$(dirname "$OUT")"
  python3 -c "
import sys, json
sys.path.insert(0, '$LIB_DIR')
import maintenance_apply as ma

# ケース1: 個数系キーを一切渡さない呼び出し（no_candidates相当）。
ma._write_status_file(sys.argv[1], ok=True, anomaly=False, reason='no_candidates', warnings=[])
d = json.load(open(sys.argv[1], encoding='utf-8'))
required = ['ok', 'anomaly', 'n_promoted', 'n_merged', 'n_merged_partial', 'n_fixed', 'n_skipped']
missing = [k for k in required if k not in d]
assert not missing, f'case1 missing keys: {missing}'
assert d['n_merged_partial'] == 0, f'case1 n_merged_partial should default to 0, got {d[\"n_merged_partial\"]!r}'

# ケース2: 一部の個数系キーだけを明示指定（他は既定値のまま・上書きは尊重される）。
ma._write_status_file(sys.argv[1], ok=False, anomaly=True, reason='schema_violation: x', warnings=[], n_promoted=3)
d2 = json.load(open(sys.argv[1], encoding='utf-8'))
missing2 = [k for k in required if k not in d2]
assert not missing2, f'case2 missing keys: {missing2}'
assert d2['n_promoted'] == 3, 'case2: explicit override must be respected'
assert d2['n_merged_partial'] == 0, 'case2: unspecified count key must still default to 0'
print('OK')
" "$OUT"
  RC=$?
  assert_eq "個数系キー省略・部分指定のどちらでも7必須キーが揃い、明示指定は尊重される" "0" "$RC"
}

echo "=== 54. main(): 正常系end-to-end（fragments-json入力→PROMOTE適用→status/log確認） ==="
{
  V="$WORK_ROOT/t28/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---

# Fragments 2026-07-15

- **断片G**：CLI end-to-endテスト用の断片本文です。
EOF
  FJSON="$WORK_ROOT/t28/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
print(fid)
" > "$WORK_ROOT/t28/fid.txt"
  FID="$(cat "$WORK_ROOT/t28/fid.txt")"
  RESP="$WORK_ROOT/t28/response.json"
  python3 -c "
import json
print(json.dumps({'is_error': False, 'permission_denials': [], 'structured_output': {'actions': [
  {'id': '$FID', 'action': 'promote', 'target_folder': 'Knowledge',
   'body': '---\ndate: 2026-07-16\nupdated: 2026-07-16\ntags: [t]\nproject: x\n---\n\n本文\n'}]}}))
" > "$RESP"
  W="$WORK_ROOT/t28/work"
  FAKE_CLAUDE_MODE=respond FAKE_CLAUDE_RESPONSE_FILE="$RESP" \
    run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t28/stdout.txt" 2>&1
  assert_contains "標準出力に完了サマリ" "$(cat "$WORK_ROOT/t28/stdout.txt")" "promote=1"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "status: ok・anomaly false・n_promoted=1" "$STATUS" '"n_promoted": 1'
  assert_eq "Knowledgeに新規ノートが1件だけ作成される" "1" "$(find "$V/Knowledge" -name '*.md' | wc -l | tr -d ' ')"
}

echo "=== 55. main(): claude起動不可（spawn_error）は一切書き込まずanomalyで終了 ==="
{
  V="$WORK_ROOT/t29/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片H**：spawn_errorテスト用。
EOF
  FJSON="$WORK_ROOT/t29/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
"
  W="$WORK_ROOT/t29/work"
  python3 "$SCRIPT" --vault "$V" --workdir "$W" --claude-bin "$WORK_ROOT/t29/does-not-exist" \
    --fragments-json "$FJSON" > "$WORK_ROOT/t29/stdout.txt" 2>&1
  RC=$?
  assert_eq "終了コードは0（異常時もstatus-file経由で通知）" "0" "$RC"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true" "$STATUS" '"anomaly": true'
  assert_contains "reasonにspawn_error" "$STATUS" "spawn_error"
  assert_eq "Knowledgeには何も書き込まれない" "0" "$(find "$V/Knowledge" -name '*.md' | wc -l | tr -d ' ')"
}

echo "=== 56. main(): claudeがタイムアウトしたら一切書き込まずanomaly=timeout ==="
{
  V="$WORK_ROOT/t30/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片I**：timeoutテスト用。
EOF
  FJSON="$WORK_ROOT/t30/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
"
  W="$WORK_ROOT/t30/work"
  FAKE_CLAUDE_MODE=sleep FAKE_CLAUDE_SLEEP_SECONDS=3 \
    run_apply_cli "$V" "$W" --fragments-json "$FJSON" --claude-timeout 1 > "$WORK_ROOT/t30/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true・reasonにtimeout" "$STATUS" "timeout"
  assert_eq "Knowledgeには何も書き込まれない" "0" "$(find "$V/Knowledge" -name '*.md' | wc -l | tr -d ' ')"
}

echo "=== 57. main(): claudeがschema違反（未知id）の構造化出力を返したら一切書き込まずanomaly ==="
{
  V="$WORK_ROOT/t31/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片J**：schema違反テスト用。
EOF
  FJSON="$WORK_ROOT/t31/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
"
  RESP="$WORK_ROOT/t31/response.json"
  cat > "$RESP" <<'EOF'
{"is_error": false, "permission_denials": [], "structured_output": {"actions": [
  {"id": "frag-totally-unknown-id", "action": "promote", "target_folder": "Knowledge", "body": "---\nx\n---\n"}
]}}
EOF
  W="$WORK_ROOT/t31/work"
  FAKE_CLAUDE_MODE=respond FAKE_CLAUDE_RESPONSE_FILE="$RESP" \
    run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t31/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true・reasonにschema_violation" "$STATUS" "schema_violation"
  assert_eq "Knowledgeには何も書き込まれない" "0" "$(find "$V/Knowledge" -name '*.md' | wc -l | tr -d ' ')"
}

echo "=== 58. main(): permission_denialsが空でなければツール使用試行とみなしanomaly ==="
{
  V="$WORK_ROOT/t32/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片K**：permission_denialsテスト用。
EOF
  FJSON="$WORK_ROOT/t32/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
"
  RESP="$WORK_ROOT/t32/response.json"
  cat > "$RESP" <<'EOF'
{"is_error": false, "permission_denials": [{"tool": "Bash"}], "structured_output": {"actions": []}}
EOF
  W="$WORK_ROOT/t32/work"
  FAKE_CLAUDE_MODE=respond FAKE_CLAUDE_RESPONSE_FILE="$RESP" \
    run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t32/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true・reasonにtool_use_detected" "$STATUS" "tool_use_detected"
}

echo "=== 59. main(): claude出力がJSONとして壊れていたら一切書き込まずanomaly=invalid_json ==="
{
  V="$WORK_ROOT/t33/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片L**：invalid_jsonテスト用。
EOF
  FJSON="$WORK_ROOT/t33/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
"
  W="$WORK_ROOT/t33/work"
  FAKE_CLAUDE_MODE=garbage run_apply_cli "$V" "$W" --fragments-json "$FJSON" > "$WORK_ROOT/t33/stdout.txt" 2>&1
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "anomaly=true・reasonにinvalid_json" "$STATUS" "invalid_json"
}

echo "=== 60. main(): --dry-runは検証だけ行いVaultへは一切書き込まない ==="
{
  V="$WORK_ROOT/t34/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片M**：dry-runテスト用。
EOF
  FJSON="$WORK_ROOT/t34/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
print(fid)
" > "$WORK_ROOT/t34/fid.txt"
  FID="$(cat "$WORK_ROOT/t34/fid.txt")"
  RESP="$WORK_ROOT/t34/response.json"
  python3 -c "
import json
print(json.dumps({'is_error': False, 'permission_denials': [], 'structured_output': {'actions': [
  {'id': '$FID', 'action': 'promote', 'target_folder': 'Knowledge', 'body': '---\nx\n---\n\n本文\n'}]}}))
" > "$RESP"
  W="$WORK_ROOT/t34/work"
  FAKE_CLAUDE_MODE=respond FAKE_CLAUDE_RESPONSE_FILE="$RESP" \
    run_apply_cli "$V" "$W" --fragments-json "$FJSON" --dry-run > "$WORK_ROOT/t34/stdout.txt" 2>&1
  assert_eq "Vaultには何も作成されない" "0" "$(find "$V/Knowledge" -name '*.md' | wc -l | tr -d ' ')"
  SRC="$(cat "$V/Fragments/2026-07/2026-07-15.md")"
  assert_not_contains "Fragments側もdry-runでは変更されない" "$SRC" "status: promoted"
  STATUS="$(cat "$W/apply-status.json")"
  assert_contains "それでもn_promoted=1として集計される（判定は実施済み）" "$STATUS" '"n_promoted": 1'
}

echo "=== 61. main(): claude実起動時の引数に安全設計フラグ一式が実際に含まれる ==="
{
  V="$WORK_ROOT/t47/vault"; mkdir -p "$V/Knowledge" "$V/Fragments/2026-07"
  cat > "$V/Fragments/2026-07/2026-07-15.md" <<'EOF'
---
date: 2026-07-15
tags: [fragments, daily]
project: external-brain
---
# Fragments 2026-07-15
- **断片N**：claude起動引数検証用。
EOF
  FJSON="$WORK_ROOT/t47/fragments.json"
  python3 -c "
import sys, hashlib, json, pathlib
sys.path.insert(0, '$LIB_DIR')
import fragments_log
vault = pathlib.Path('$V')
text = (vault/'Fragments/2026-07/2026-07-15.md').read_text()
entries = fragments_log.extract_entries(text)
fid = fragments_log.stable_fragment_id('Fragments/2026-07/2026-07-15.md', entries[0][0])
payload = {'fragments': [{'id': fid, 'source_relpath': 'Fragments/2026-07/2026-07-15.md',
           'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'date': '2026-07-15',
           'heading_or_bullet': entries[0][0], 'body': entries[0][2]}], 'truncated': []}
pathlib.Path('$FJSON').write_text(json.dumps(payload))
"
  RESP="$WORK_ROOT/t47/response.json"
  echo '{"is_error": false, "permission_denials": [], "structured_output": {"actions": []}}' > "$RESP"
  ARGV_FILE="$WORK_ROOT/t47/argv.txt"
  W="$WORK_ROOT/t47/work"
  FAKE_CLAUDE_MODE=respond FAKE_CLAUDE_RESPONSE_FILE="$RESP" FAKE_CLAUDE_SAVE_ARGV="$ARGV_FILE" \
    python3 "$SCRIPT" --vault "$V" --workdir "$W" --claude-bin "$FAKE_CLAUDE" \
    --fragments-json "$FJSON" --model haiku > "$WORK_ROOT/t47/stdout.txt" 2>&1
  ARGV="$(cat "$ARGV_FILE")"
  assert_contains "--toolsが渡される" "$ARGV" $'--tools\n'
  assert_contains "--disable-slash-commandsが渡される" "$ARGV" "--disable-slash-commands"
  assert_contains "--strict-mcp-configが渡される" "$ARGV" "--strict-mcp-config"
  assert_contains "--disallowedTools mcp__* が渡される" "$ARGV" $'--disallowedTools\nmcp__*'
  assert_contains "--max-turns 1 が渡される" "$ARGV" $'--max-turns\n1'
  assert_contains "--model 引数がCLI指定値(haiku)で渡される" "$ARGV" $'--model\nhaiku'
  assert_contains "--output-format json が渡される" "$ARGV" $'--output-format\njson'
  assert_contains "--mcp-configは一切渡されない（--strict-mcp-configとの二重防御の前提）" "$(echo "$ARGV" | grep -c -- '--mcp-config$' || true)" "0"
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
