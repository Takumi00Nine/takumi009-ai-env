#!/usr/bin/env bash
# S3: 隔離 HOME で両接続・期限・観測基準の保存と回復を確認する。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/recall-s3.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
python3 - "$REPO_ROOT" "$WORK" "$@" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tomllib
import unittest
from unittest.mock import patch

repo, work = map(Path, sys.argv[1:3])
test_names = sys.argv[3:]
sys.path.insert(0, str(repo / 'ai-brain/executor'))
import health_judge as health
import recall_runtime as runtime


class RecallFlow(unittest.TestCase):
    def setUp(self):
        self.home = work / self._testMethodName
        self.home.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ('AIENV_', 'VAULT_', 'HEALTH_', 'BOOTSTRAP_', 'CMUX_', 'MAINTENANCE_', 'GATE_'))}
        self.env.update(HOME=str(self.home), SKIP_LAUNCHCTL='1', LAUNCHCTL_TIMEOUT_SECS='1',
                        TMPDIR=str(self.home), CMUX_CODEX_HOOKS_DISABLED='1')
        profile = self.home / '.config/takumi009-ai-env'
        profile.mkdir(parents=True)
        (profile / 'models.conf').write_text('[test]\nprovider=anthropic-api\nmodel=claude-sonnet-5-5\n')
        (profile / 'profile.md').write_text('''---
schema_version: 7
profile_slug: recall-test
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=test
---
''')
        installed = self.run_cmd(['bash', str(repo / 'core/assembly/install-main.sh')])
        self.assertEqual(installed.returncode, 0, installed.stderr[-300:])
        self.hook = self.home / '.claude/hooks/vault-recall.sh'
        self.log = self.home / '.claude/logs/vault-recall.jsonl'
        self.state = self.home / '.claude/logs/health/recall-observation.json'
        self.vault = self.home / 'Data/obsidian'
        (self.vault / 'Projects').mkdir(parents=True)
        for note in ('Preferences/absolute-rules.md', 'Preferences/core-conduct.md',
                     'Preferences/core-workflow.md', 'Personal/profile-personal.md',
                     'Preferences/vault-operation.md'):
            path = self.vault / note
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# 必読\nfixture の全文\n')
        path = self.vault / 'Knowledge/safety.md'
        path.parent.mkdir()
        path.write_text('''# 安全柵
## 教訓: tests
- 教訓1行: 安全柵が守る振る舞いを確認する。
- 効く場面:
  - 安全柵のテストを減らす
- 起きたこと: 安全柵まで削る案になった。
- 発生記録:
  - 2026-11-01 [[Fragments/初回]]
''')
        path = self.vault / 'Decisions/fix.md'
        path.parent.mkdir()
        path.write_text('''# 判断
- 判断1行: 応急処置で終わらせない
- 効く場面:
  - 直すのは別のタスクに回す
- 判断の日付: 2026-11-01
''')
        self.trust()
        # 外部コマンドの経路を隔離。check-drift は実 launchd/git/cmux/gh に触れない。
        bin_dir = self.home / 'bin'
        bin_dir.mkdir()
        for name in ('launchctl', 'cmux', 'gh', 'git'):
            stub = bin_dir / name
            stub.write_text('#!/bin/sh\nexit 1\n')
            stub.chmod(0o755)
        self.env['PATH'] = str(bin_dir) + ':' + self.env['PATH']

    def run_cmd(self, cmd, text='', extra=None):
        return subprocess.run(cmd, input=text, text=True, capture_output=True,
                              env={**self.env, **(extra or {})}, cwd=self.home, timeout=40)

    def trust(self):
        # fixture のみ。製品コードは承認値を書かない。
        source = self.home / '.codex/hooks.json'
        hooks = json.loads(source.read_text())['hooks']['UserPromptSubmit']
        config = self.home / '.codex/config.toml'
        with config.open('a') as out:
            for gi, group in enumerate(hooks):
                for hi, handler in enumerate(group['hooks']):
                    if 'vault-recall.sh' in handler['command']:
                        key = f'{source}:user_prompt_submit:{gi}:{hi}'
                        identity = {'event_name': 'user_prompt_submit', 'hooks': [{
                            'type': 'command', 'command': handler['command'],
                            'timeout': 5, 'async': False}]}
                        raw = json.dumps(identity, sort_keys=True, separators=(',', ':'))
                        fingerprint = 'sha256:' + hashlib.sha256(raw.encode()).hexdigest()
                        out.write(f'\n[hooks.state.{json.dumps(key)}]\ntrusted_hash = '
                                  + json.dumps(fingerprint) + '\n')

    def test_cmux_group_zero_keeps_fixed_trust(self):
        # HEAD の実定義と実環境で照合済みのハッシュを固定の正解にする。
        fixture = json.loads((repo / 'tests/fixtures/recall/codex-cmux-head.json').read_text())
        source = self.home / '.codex/hooks.json'
        group = json.loads(source.read_text())['hooks']['UserPromptSubmit'][0]
        self.assertEqual(group, fixture['group'])
        self.assertEqual(health.codex_hook_hash(group, group['hooks'][0]), fixture['trusted_hash'])
        key = f'{source}:user_prompt_submit:0:0'
        config = self.home / '.codex/config.toml'
        with config.open('a') as out:
            out.write(f'\n[hooks.state.{json.dumps(key)}]\nenabled = false\ntrusted_hash = '
                      + json.dumps(fixture['trusted_hash']) + '\n')
        installed = self.run_cmd(['bash', str(repo / 'core/assembly/install-main.sh')])
        self.assertEqual(installed.returncode, 0, installed.stderr[-300:])
        self.assertEqual(json.loads(source.read_text())['hooks']['UserPromptSubmit'][0], fixture['group'])
        self.assertEqual(tomllib.loads(config.read_text())['hooks']['state'][key],
                         {'enabled': False, 'trusted_hash': fixture['trusted_hash']})
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.recall_connections()['codex'], None)

    def prompt(self, leader, prompt='', observe=False, session='same', extra=None):
        result = self.run_cmd([str(self.hook), '--leader', leader] + (['--observe'] if observe else []),
                              json.dumps({'prompt': prompt, 'session_id': session}), extra)
        self.assertEqual(result.returncode, 0)
        return json.loads(result.stdout)['hookSpecificOutput']['additionalContext'] if result.stdout else ''

    def rows(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def seed(self, leader, event, at, run=None):
        self.log.parent.mkdir(parents=True, exist_ok=True)
        row = dict(schema='vault-recall/1', at=at.isoformat(), leader=leader,
                   session_id='same', mode='hook', event=event, items=[], error=None)
        if run:
            row['run_id'] = run
        with self.log.open('a') as out:
            out.write(json.dumps(row) + '\n')

    def invoke_reader(self, reader):
        now = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=10)).isoformat()
        extra = dict(HEALTH_JUDGE_NOW=now)
        if reader == 'dock':
            cmd = ['bash', str(repo / 'dock/executor/cmux-next-model.sh'), '--frame']
        elif reader == 'claude':
            cmd = ['bash', str(repo / 'ai-brain/executor/bootstrap-vault.sh'), '--slots']
        elif reader == 'codex':
            cmd = ['bash', str(repo / 'team/connect/codex/session-start-read.sh')]
        else:
            cmd = ['bash', str(repo / 'core/assembly/check-drift.sh')]
        result = self.run_cmd(cmd, '{"session_id":"startup"}', extra)
        self.assertEqual(result.returncode, 0, result.stderr[-300:])
        self.assertTrue(self.state.exists(), reader + ': 共通観測を呼んでいない')
        return result.stdout

    def test_connections_and_same_text(self):
        # 実際に配置された登録コマンドを通す。cmux ハンドラは対象にしない。
        prompt = '安全柵のテストを減らしたい。直すのは別のタスクに回そう'
        texts = []
        for leader in ('claude', 'codex'):
            source = self.home / ('.claude/settings.json' if leader == 'claude' else '.codex/hooks.json')
            groups = json.loads(source.read_text())['hooks']['UserPromptSubmit']
            commands = [h['command'] for g in groups for h in g['hooks'] if 'vault-recall.sh' in h['command']]
            self.assertEqual(len(commands), 2)
            for command in commands:
                result = self.run_cmd(['bash', '-c', command], json.dumps({'prompt': prompt, 'session_id': 'same'}))
                self.assertEqual(result.returncode, 0)
                if result.stdout:
                    texts.append(json.loads(result.stdout)['hookSpecificOutput']['additionalContext'])
        manual = self.run_cmd([str(self.hook), '--leader', 'codex', '--manual'], prompt)
        self.assertEqual(texts, [manual.stdout.rstrip(), manual.stdout.rstrip()])
        self.assertIn('教訓：', texts[0])
        self.assertIn('本人の判断：', texts[0])
        rows = self.rows()
        self.assertNotIn(prompt, self.log.read_text())
        for start in (r for r in rows if r['event'] == 'started'):
            terminal = [r for r in rows if r.get('run_id') == start['run_id'] and r['event'] in ('completed', 'failed')]
            self.assertEqual(len(terminal), 1)
        self.assertTrue(all('run_id' not in r for r in rows if r['event'] == 'expected'))
        path = self.vault / 'Knowledge/safety.md'
        path.write_text(path.read_text().replace('安全柵が守る振る舞いを確認する。', 'まず安全柵の目的を確認する。'))
        self.assertIn('まず安全柵の目的', self.prompt('claude', prompt))
        self.assertEqual(len(self.prompt('codex', prompt, extra={'VAULT_RECALL_MAX_ITEMS': '1'}).splitlines()), 1)
        self.assertEqual(self.prompt('codex', prompt, extra={'AIENV_CODEX_WORKER': '1'}), '')
        before = self.log.read_text()
        self.run_cmd([str(self.hook), '--leader', 'claude'], '{"agent_id":"worker","prompt":"安全柵のテストを減らす"}')
        self.assertEqual(self.log.read_text(), before)

    def test_timeout_records_and_returns_zero(self):
        # 照合そのものを遅らせ、OSタイマーによる全体期限を通す。
        with patch.dict(os.environ, self.env, clear=True), patch.object(sys, 'argv', [
                'recall', '--leader', 'codex', '--manual', '--budget-ms', '80']), \
                patch.object(sys, 'stdin', __import__('io').StringIO('安全柵のテストを減らす')), \
                patch.object(sys, 'stdout', __import__('io').StringIO()) as out, \
                patch.object(runtime, 'recall_situations', side_effect=lambda *a, **kw: time.sleep(2)):
            runtime.PROCESS_STARTED = time.monotonic()
            runtime.main()
            self.assertEqual(out.getvalue(), '')
        self.assertEqual(self.rows()[-1]['event'], 'failed')
        self.assertEqual(self.rows()[-1]['error']['kind'], 'timeout')
        self.assertEqual(self.prompt('codex', '安全柵のテストを減らす', extra={'VAULT_RECALL_KEYWORD_BUDGET_MS': '0'}), '')
        self.assertEqual(self.rows()[-1]['error']['kind'], 'timeout')

    def test_all_readers_persist_recovery_with_legacy_files(self):
        old = self.home / '.claude/logs'
        old.mkdir(parents=True, exist_ok=True)
        (old / 'vault-reads.tsv').write_text('2000-01-01T00:00:00Z\told\tKnowledge/safety.md\n')
        (old / 'vault-recall.tsv').write_text('2000-01-01T00:00:00Z\told\tKnowledge/safety.md\n')
        (old / 'health').mkdir(exist_ok=True)
        (old / 'health/session-observation.json').write_text(json.dumps({
            'schema': 'health-observation/1', 'recall_prev': {'injected': False, 'reads_rows': 3}}))
        (old / 'maintenance').mkdir(exist_ok=True)
        (old / 'maintenance/last-run.json').write_text('{"fragments_candidates":999}')
        (old / 'vault-inventory').mkdir(exist_ok=True)
        (old / 'vault-inventory/latest.json').write_text(json.dumps({'actionable': 1, 'items': [
            {'kind': 'missing_aliases', 'target': 'old', 'detail': 'obsolete'}]}))
        past = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=9)
        for reader in ('dock', 'claude', 'codex', 'drift'):
            output = self.invoke_reader(reader)
            if reader == 'codex':
                self.assertIn('claude=未観測', output)
                self.assertIn('codex=未観測', output)
                self.assertIn('stage=OK', output)
            self.assertNotIn('候補999件', output)
            self.assertNotIn('recall_not_injected', output)
            self.assertNotIn('[VAULT-RECALL-LOG-STALE]', output)
        self.assertEqual(json.loads(self.state.read_text())['sessions'], {})
        # 0件成功が7日を超えても日数を異常にしない。
        for day in range(9):
            for event in ('expected', 'started', 'completed'):
                self.seed('claude', event, past + dt.timedelta(days=day),
                          f'healthy-{day}' if event != 'expected' else None)
        for reader in ('dock', 'claude', 'codex', 'drift'):
            self.seed('codex', 'expected', dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=5))
            if reader == 'dock':
                self.run_cmd([str(self.hook), '--leader', 'codex', '--manual'], '手動だけ成功')
            self.invoke_reader(reader)
            states = json.loads(self.state.read_text())['sessions']
            self.assertEqual(states['claude']['same']['state'], '正常')
            self.assertEqual(states['codex']['same']['state'], '未起動', reader)
            self.prompt('codex', observe=True)
            self.prompt('codex', '一致しない文')
            self.invoke_reader(reader)
            saved = self.state.read_text()
            self.assertEqual(json.loads(saved)['sessions']['codex']['same']['state'], '正常', reader)
            self.invoke_reader(reader)
            self.assertEqual(self.state.read_text(), saved, reader + ': 再表示で基準が変わった')

    def test_failure_recovery_running_and_connection_state(self):
        now = dt.datetime.now(dt.timezone.utc)
        events = [dict(event=e, at=(now - dt.timedelta(seconds=2)).isoformat(), run_id='one')
                  for e in ('expected', 'started', 'failed')]
        state, basis = health.judge_recall(events, {}, now, 1000)
        self.assertEqual(state, '失敗中')
        events = [dict(event=e, at=now.isoformat(), run_id='two') for e in ('expected', 'started', 'completed')]
        state, basis = health.judge_recall(events, basis, now, 1000)
        self.assertEqual(state, '実行中')
        state, basis = health.judge_recall([], basis, now + dt.timedelta(seconds=2), 1000)
        self.assertEqual(state, '正常')
        self.assertEqual(health.judge_recall([], basis, now + dt.timedelta(days=8), 1000)[0], '正常')
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.recall_connections(), {'claude': None, 'codex': None})
        blocked = self.home / 'blocked-parent'
        blocked.write_text('観測記録の親を作れない')
        result = self.run_cmd(['python3', str(repo / 'ai-brain/executor/health_judge.py'), 'observe'],
                              extra={'HEALTH_RECALL_OBSERVATION_FILE': str(blocked / 'basis.json')})
        verdict = json.loads(result.stdout)
        self.assertEqual(verdict['sources']['recall'], dict.fromkeys(('claude', 'codex'), '観測記録障害'))
        config = self.home / '.codex/config.toml'
        config.write_text(config.read_text().split('\n[hooks.state.')[0])
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.recall_connections()['codex'], '本人の承認待ち')
        config.write_text(config.read_text().replace('hooks = true', 'hooks = false'))
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.recall_connections()['codex'], '構成異常')

    def test_observation_reads_only_appended_rows_and_skips_broken_line(self):
        now = dt.datetime.now(dt.timezone.utc)
        self.seed('claude', 'expected', now)
        self.seed('claude', 'started', now, 'across-reads')
        args = __import__('argparse').Namespace(recall_log=str(self.log), now=now.isoformat())
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.observe_recall(args)[0]['claude'], '実行中')
        position = json.loads(self.state.read_text())['position']
        with self.log.open('ab') as out:
            out.write(b'broken JSON\n')
        self.seed('claude', 'completed', now, 'across-reads')
        args.now = (now + dt.timedelta(seconds=2)).isoformat()
        loads = json.loads
        with patch.dict(os.environ, self.env, clear=True), patch.object(health.json, 'loads', wraps=loads) as read:
            self.assertEqual(health.observe_recall(args)[0]['claude'], '正常')
            # 古い expected/started 行は JSON デコードへも渡さない。
            decoded_rows = [call.args[0] for call in read.call_args_list if isinstance(call.args[0], bytes)]
        self.assertEqual(len(decoded_rows), 2)
        saved = json.loads(self.state.read_text())
        self.assertEqual(saved['position'], self.log.stat().st_size)
        self.assertGreater(saved['position'], position)
        self.assertEqual(saved['sessions']['claude']['same']['totals'],
                         {'expected': 1, 'started': 1, 'completed': 1, 'failed': 0})
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.observe_recall(args)[0]['claude'], '正常')
        self.assertEqual(json.loads(self.state.read_text()), saved)

    def test_observation_restarts_after_shrink_and_waits_for_newline(self):
        now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=5)
        for event in ('expected', 'started', 'completed'):
            self.seed('claude', event, now, 'before-shrink')
        args = __import__('argparse').Namespace(recall_log=str(self.log),
                                               now=(now + dt.timedelta(seconds=10)).isoformat())
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(health.observe_recall(args)[0]['claude'], '正常')
            row = dict(leader='codex', session_id='replacement', mode='hook',
                       event='expected', at=now.isoformat())
            partial = json.dumps(row).encode()
            self.assertLess(len(partial), json.loads(self.state.read_text())['position'])
            self.log.write_bytes(partial)
            self.assertEqual(health.observe_recall(args)[0],
                             {'claude': '未観測', 'codex': '未観測'})
            self.assertEqual(json.loads(self.state.read_text())['sessions'], {})
            self.assertEqual(json.loads(self.state.read_text())['position'], 0)
            with self.log.open('ab') as out:
                out.write(b'\n')
            self.assertEqual(health.observe_recall(args)[0]['codex'], '未起動')
        saved = json.loads(self.state.read_text())
        self.assertEqual(saved['position'], len(partial) + 1)
        self.assertEqual(set(saved['sessions']), {'codex'})
        self.assertEqual(saved['sessions']['codex']['replacement']['totals']['expected'], 1)

    def test_inventory_no_longer_reads_legacy_metrics(self):
        result = self.run_cmd(['python3', str(repo / 'ai-brain/executor/vault_inventory.py'), '--json'])
        self.assertEqual(result.returncode, 0, result.stderr[-300:])
        latest = json.loads((self.home / '.claude/logs/vault-inventory/latest.json').read_text())
        self.assertNotIn('missing_aliases', latest['sections'])
        report = Path(json.loads(result.stdout)['report_path']).read_text()
        self.assertNotIn('未読ノート', report)
        self.assertNotIn('提示無視率', report)


unittest.main(argv=['recall-flow'] + test_names, verbosity=2)
PY
