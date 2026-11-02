#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/vault_inventory.py"

PASS=0
FAIL=0
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/inventory-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

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

d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%Y-%m-%dT12:00:00; }

make_base_vault() {
  local vault="$1"
  # Personal/はvault_inventory.pyのBOOTSTRAP_FILES（§5注入サイズ監視）に元々
  # 含まれていた（bootstrap-vault.shの必読ファイルと同期）が、このfixtureヘルパー
  # には反映されておらず§5がFileNotFoundErrorで落ちる既存の隙間があった。
  # 2026-07-11決定（[[Decisions/2026-07-11-personal-recall-scope]]）でPersonal/が
  # 想起対象フォルダにも加わったタイミングで合わせて解消する（私の担当外の既存問題
  # だが、Personal関連テストを追加するために本ヘルパーの修正が前提となるため対応）。
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Decisions" "$vault/Projects" \
           "$vault/Personal" "$vault/Fragments"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/vault-operation.md" "Personal/profile-personal.md"; do
    printf -- '---\ndate: 2026-01-01\n---\n\ndummy\n' > "$vault/$f"
  done
  for d in Knowledge Preferences Decisions Projects Personal; do
    printf -- '---\ndate: 2026-01-01\ntags: [meta, index]\n---\n\n# %s\n' "$d" > "$vault/$d/README.md"
  done
}

make_clean_vault() {
  local vault="$1"
  make_base_vault "$vault"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/vault-operation.md" "Personal/profile-personal.md"; do
    printf -- '---\ndate: 2026-01-01\nupdated: 2026-01-01\naliases: [clean-vault-alias-%s]\n---\n\ndummy\n' \
      "$(basename "$f" .md)" > "$vault/$f"
  done
  printf -- '---\ndate: %s\n---\n\n## dummy entry\n' "$(date +%F)" > "$vault/Fragments/$(date +%F).md"
}

extract_actionable() {
  echo "$1" | grep -oE '要確認 [0-9]+ 件' | head -1 | grep -oE '[0-9]+'
}

write_note() {
  local vault="$1" rel="$2" fm="$3" body="${4:-本文}"
  mkdir -p "$(dirname "$vault/$rel")"
  {
    echo "---"
    printf '%s\n' "$fm"
    echo "---"
    echo
    printf '%s\n' "$body"
  } > "$vault/$rel"
}

run_inventory() {
  local vault_home="$1"
  HOME="$vault_home" VAULT="$vault_home/Data/obsidian" python3 "$SCRIPT" >/dev/null
  cat "$(ls "$vault_home/.claude/logs/vault-inventory"/20*.md | sort | tail -1)"
}

echo "=== 旧ログと aliases を検査材料にしない ==="
{
  VAULT_HOME="$(mktemp -d "$TEST_ROOT/home.XXXXXX")"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  write_note "$V" "Knowledge/no-alias.md" "date: 2026-01-01"
  mkdir -p "$VAULT_HOME/.claude/logs"
  printf '2000-01-01T00:00:00Z\tsess\tKnowledge/no-alias.md\n' > "$VAULT_HOME/.claude/logs/vault-reads.tsv"
  cp "$VAULT_HOME/.claude/logs/vault-reads.tsv" "$VAULT_HOME/.claude/logs/vault-recall.tsv"
  out="$(run_inventory "$VAULT_HOME")"
  assert_not_contains "aliases 欠落を表示しない" "$out" "aliases が無いノート"
  assert_not_contains "旧ログが残っても未読を表示しない" "$out" "未読ノート"
  assert_not_contains "旧ログが残っても提示無視率を表示しない" "$out" "提示無視率"
  rm -rf "$VAULT_HOME"
}

echo "=== 読めないノートがあっても完走する ==="
{
  # 全Vault走査（.mdファイル全般の読込ループ）にも、BOOTSTRAP_FILESと同型の
  # クラッシュ余地がCodexレビューで指摘され、リーダー裁定により水平展開で
  # 修正した。壊れたsymlink（リンク先が存在しない）は`p.is_file()`がFalseを
  # 返すため検知できる。
  VAULT_HOME="$(mktemp -d "$TEST_ROOT/home.XXXXXX")"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  ln -s "$V/Knowledge/does-not-exist.md" "$V/Knowledge/broken-link.md"

  rc=0
  out="$(run_inventory "$VAULT_HOME")" || rc=$?
  assert_eq "壊れたsymlinkがあってもクラッシュせずexit 0のまま完走する" "0" "$rc"
  assert_contains "壊れたsymlinkが「読込に失敗したノート」として§0に載る" "$out" "Knowledge/broken-link.md\` —"
  n_after="$(extract_actionable "$out")"
  assert_eq "壊れたsymlinkの検出もactionableへ1件加算される" "1" "$n_after"

  rm -rf "$VAULT_HOME"
}

echo "=== S4: 再発集計と形の欠け（AC-FL-12・14） ==="
S4_ROOT="$TEST_ROOT/s4"
mkdir -p "$S4_ROOT"
if HOME="$S4_ROOT" VAULT="$S4_ROOT/Data/obsidian" PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

repo = Path(sys.argv[1])
home = Path.home()
vault = home / 'Data/obsidian'
script = repo / 'ai-brain/executor/vault_inventory.py'
for folder in ('Knowledge', 'Decisions', 'Fragments'):
    (vault / folder).mkdir(parents=True)


def lesson(name, occurrences, scene=True, text=True):
    return f'''## 教訓: {name}
{('- 教訓1行: 先に目的を確認する。' if text else '')}
{('- 効く場面:' + chr(10) + '  - 安全柵のテストを減らす' if scene else '')}
- 起きたこと: 安全柵を削りかけた。
- 発生記録:
''' + ''.join(f'  - {day} [[Fragments/{day}#{name}]] [[Fragments/{day}#検証]]\n' for day in occurrences)


class InventoryS4(unittest.TestCase):
    def run_inventory(self, *args, **env):
        result = subprocess.run(['python3', str(script), *args], env={**os.environ, **env},
                                text=True, capture_output=True, check=True)
        return result.stdout

    def test_dates_and_malformed_headings(self):
        import tempfile
        sys.path.insert(0, str(repo / 'ai-brain/executor'))
        import vault_lib
        with tempfile.TemporaryDirectory(dir=home) as folder:
            root = Path(folder)
            (root / 'Knowledge').mkdir()
            (root / 'Decisions').mkdir()
            (root / 'Knowledge/dates.md').write_text(
                lesson('dates', ['20261102', '2026-10-31', '2026-11-01'])
                + '## 教訓：全角\n本文\n## 教訓: ID with spaces\n本文\n')
            (root / 'Decisions/date.md').write_text(
                '# 判断\n- 判断1行: 日付を揃える\n- 効く場面:\n  - 集計する\n- 判断の日付: 20261102\n')
            records, issues = vault_lib.read_recall_records(root)
            self.assertEqual([r['date'] for r in records[0]['occurrences']],
                             ['2026-10-31', '2026-11-01', '2026-11-02'])
            self.assertEqual(records[1]['date'], '2026-11-02')
            self.assertEqual([r['id'] for r in issues],
                             ['Knowledge/dates.md#教訓：全角', 'Knowledge/dates.md#教訓: ID with spaces'])

    def test_recurrence_and_same_day(self):
        note = vault / 'Knowledge/lessons.md'
        note.write_text(lesson('X', ['2026-10-31', '2026-11-02'])
                        + lesson('Y', ['2026-11-01', '2026-11-03'])
                        + lesson('first-only', ['2026-11-02']))
        decision = vault / 'Decisions/choice.md'
        decision.write_text('# 判断\n- 判断1行: 応急処置で終わらせない\n- 効く場面:\n  - 直すのは別のタスクに回す\n- 判断の日付: 2026-11-02\n')
        log = home / 'configured-recall.jsonl'
        rows = [dict(schema='vault-recall/1', at=at, event=event, items=items,
                     leader=leader, mode=mode, session_id='s', run_id=str(i), error=None)
                for i, (at, event, items, leader, mode) in enumerate([
                    ('2026-11-01T15:00:00Z', 'completed', ['Knowledge/lessons.md#X'], 'codex', 'manual'),
                    ('2026-11-03T01:00:00Z', 'failed', ['Knowledge/lessons.md#Y'], 'claude', 'hook'),
                    ('2026-11-03T15:00:00Z', 'completed', ['Knowledge/lessons.md#Y', 'Decisions/choice.md'], 'claude', 'hook'),
                ])]
        log.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        args = ('--recurrence', '--start', '2026-11-02', '--end', '2026-11-03')
        before = {str(p): p.read_bytes() for p in home.rglob('*') if p.is_file()}
        result = json.loads(self.run_inventory(*args, '--timezone', 'Asia/Tokyo', '--json', VAULT_RECALL_LOG=str(log)))
        self.assertEqual(result['total'], 2)
        self.assertEqual([(r['id'], r['count']) for r in result['lessons']],
                         [('Knowledge/lessons.md#X', 1), ('Knowledge/lessons.md#Y', 1)])
        self.assertEqual([r['occurrences'][0]['presented'] for r in result['lessons']], [True, False])
        self.assertEqual(result['lessons'][0]['occurrences'][0]['source'],
                         '[[Fragments/2026-11-02#X]] [[Fragments/2026-11-02#検証]]')
        self.assertEqual(result['recorded_period'], {'start': '2026-11-02', 'end': '2026-11-04'})
        self.assertEqual({str(p): p.read_bytes() for p in home.rglob('*') if p.is_file()}, before)
        # ローカル日付の既定も各日時の TZ に従う（UTC では X は前日）。
        utc = json.loads(self.run_inventory(*args, '--recall-log', str(log), '--json', TZ='UTC'))
        self.assertEqual([r['occurrences'][0]['presented'] for r in utc['lessons']], [False, True])
        output = self.run_inventory(*args, '--timezone', 'Asia/Tokyo', '--recall-log', str(log))
        for expected in ('再発合計: 2件', '出した', '出していない', '提示記録の対象期間:', '正常稼働の証拠にはなりません'):
            self.assertIn(expected, output)
        missing = json.loads(self.run_inventory(*args, '--recall-log', str(home / 'no-log'), '--json'))
        self.assertIsNone(missing['recorded_period'])
        self.assertTrue(all(not r['occurrences'][0]['presented'] for r in missing['lessons']))
        # 記録の壊れた行は、集計対象から外したことを明示する。
        with log.open('a') as out:
            out.write('broken JSON\n')
        broken = json.loads(self.run_inventory(*args, '--recall-log', str(log), '--json'))
        self.assertEqual(len(broken['log_issues']), 1)
        note.unlink()
        decision.unlink()

    def test_format_issues_and_no_legacy_metrics(self):
        (vault / 'Knowledge/missing.md').write_text(
            lesson('no-scene', ['2026-11-01'], scene=False)
            + lesson('no-text', ['2026-11-01'], text=False))
        (vault / 'Knowledge/example.md').write_text('```markdown\n## 教訓: example\n```\n')
        (vault / 'Decisions/missing.md').write_text('# 判断\n- 効く場面:\n  - 先に直す\n- 判断の日付: 2026-11-01\n')
        (vault / 'Decisions/no-date.md').write_text('# 判断\n- 判断1行: 先に直す\n- 効く場面:\n  - 先に直す\n')
        for path in ('Knowledge/README.md', 'Decisions/README.md', 'Decisions/retired.md'):
            (vault / path).write_text('# 退役\n> ⚠️ 退役（本文は履歴）\n')
        logs = home / '.claude/logs'
        logs.mkdir(parents=True)
        old = logs / 'vault-reads.tsv'
        old.write_text('2000-01-01T00:00:00Z\ts\tKnowledge/missing.md\n')
        output = json.loads(self.run_inventory('--json'))
        state = json.loads((logs / 'vault-inventory/latest.json').read_text())
        self.assertEqual(output['recall_format'], state['recall_format'])
        found = {r['id']: r['fields'] for r in state['recall_format']}
        self.assertEqual(len(found), 4)
        self.assertNotIn('recall_format', state['sections'])
        self.assertFalse(any(r['kind'] == 'recall_format' for r in state['items']))
        self.assertIn('効く場面', found['Knowledge/missing.md#no-scene'])
        self.assertIn('教訓1行', found['Knowledge/missing.md#no-text'])
        self.assertIn('判断1行', found['Decisions/missing.md'])
        self.assertIn('判断の日付', found['Decisions/no-date.md'])
        self.assertEqual(state['actionable'], len(state['items']))
        report = Path(state['report_path']).read_text()
        self.assertIn('Knowledge/missing.md#no-scene', report)
        for obsolete in ('読んだ率', '未読', '提示無視率', 'missing_aliases', 'generic_aliases', '候補件数', '再発合計'):
            self.assertNotIn(obsolete, report + json.dumps(state))
        self.assertEqual(old.read_text(), '2000-01-01T00:00:00Z\ts\tKnowledge/missing.md\n')


unittest.main(argv=['inventory-s4'], verbosity=2)
PY
then
  pass "S4: 再発集計と形の欠け"
else
  fail_case "S4: 再発集計と形の欠け"
fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
