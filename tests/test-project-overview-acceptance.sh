#!/usr/bin/env bash
# 段階4契約§2〜7。模擬Projects・宣言・版1記録だけからoverviewを確認する。
# CLIの実装をimportせず実行。ps・時刻・sleepだけを模擬化し、実待機しない。
# 実行: bash tests/test-project-overview-acceptance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import csv
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
cli = repo / 'team/connect/codex/project-leader.py'
columns = ('version id stage scope artifact role worker address parent_thread candidate '
           'model effort selection_ref replaces handoff_ref state_ref').split()
recorded = '2026-01-01T00:00:00Z'
observed = '2026-01-02T00:00:00Z'
passed = failed = 0


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False) + '\n')
    return path


# CLIの引数・出力の契約で確認し、実装の関数名や内部構成に依存しない。
# sleepを表示後の観測点にし、各フレーム間の書き込み0を確かめてから素材を更新する。
runner = r'''
import datetime
import json
import os
from pathlib import Path
import runpy
import sys
import time
from unittest.mock import patch

control = Path(os.environ['OVERVIEW_TEST_CONTROL'])
plan = json.loads((control / 'plan.json').read_text())
inputs = Path(plan['inputs'])
clock = datetime.datetime.fromisoformat(plan['now'].replace('Z', '+00:00'))
original_datetime = datetime.datetime
sleeps = []

def snapshot():
    return {str(p.relative_to(inputs)): ('link', os.readlink(p)) if p.is_symlink() else
            ('file', p.read_bytes(), p.stat().st_mtime_ns) if p.is_file() else ('dir',)
            for p in inputs.rglob('*')}

expected = snapshot()

class Clock(original_datetime):
    @classmethod
    def now(cls, tz=None):
        return clock.astimezone(tz) if tz is not None else clock.replace(tzinfo=None)

def sleep(seconds):
    global clock, expected
    assert snapshot() == expected, 'overview changed inputs before next frame'
    assert plan['frames'], 'single display unexpectedly slept'
    sleeps.append(seconds)
    if len(sleeps) >= plan['frames']:
        raise KeyboardInterrupt
    for action in plan['mutations'].get(str(len(sleeps)), []):
        path = Path(action['path'])
        if action['op'] == 'json':
            path.write_text(json.dumps(action['value']) + '\n')
        elif action['op'] == 'text':
            path.write_text(action['value'])
        elif action['op'] == 'rename':
            path.rename(action['destination'])
    expected = snapshot()
    clock += datetime.timedelta(seconds=seconds)

sys.argv = [plan['cli'], *plan['args']]
try:
    with patch('datetime.datetime', Clock), patch('time.time', lambda: clock.timestamp()), patch('time.sleep', sleep), \
         patch('os.kill', side_effect=AssertionError('overview sent a process signal')), \
         patch('os.killpg', side_effect=AssertionError('overview sent a process-group signal')):
        runpy.run_path(plan['cli'], run_name='__main__')
finally:
    assert snapshot() == expected, 'overview changed input contents, mtimes or file list'
    (control / 'probe.json').write_text(json.dumps({'sleeps': sleeps}))
'''


class Fixture:
    def __init__(self, root):
        self.root = root
        self.inputs = root / 'inputs'
        self.home = self.inputs / 'home'
        self.vault = self.inputs / 'vault'
        self.projects = self.vault / 'Projects'
        self.control = root / 'control'
        self.binary = root / 'bin'
        for path in (self.home, self.projects, self.control, self.binary, self.inputs / 'cache'):
            path.mkdir(parents=True, exist_ok=True)
        self.declarations = write_json(self.inputs / 'declarations.json', dict(version=1,
            workspaces={'fixture-screen-2': 'alpha', 'fixture-screen-1': 'alpha'}))
        self.workflow = write_json(self.inputs / 'workflow.json', dict(version=1,
            consultation_round_limit=3, overview_interval_seconds=2))
        self.processes = write_json(self.control / 'processes.json',
            {'41001': 'fixture alpha start', '41002': 'fixture beta start'})
        self.env = dict(HOME=str(self.home), PATH=str(self.binary) + os.pathsep + os.environ['PATH'],
            PYTHONDONTWRITEBYTECODE='1', CMUX_NEXT_VAULT=str(self.vault), CMUX_TASK_STATE=str(self.declarations),
            AIENV_TEAM_WORKFLOW_CONFIG=str(self.workflow), AIENV_USAGE_CACHE_DIR=str(self.inputs / 'cache'),
            OVERVIEW_TEST_CONTROL=str(self.control))
        # 許される外部観測は模擬psだけ。サービス・通知・表示操作は呼ばれたら失敗する。
        for name in ('codex', 'claude', 'cmux', 'launchctl', 'osascript', 'git', 'gh', 'curl', 'notify-send'):
            self.executable(name, '#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$OVERVIEW_TEST_CONTROL/forbidden"\nexit 97\n')
        self.executable('ps', '''#!/usr/bin/env python3
import json, os
from pathlib import Path
import sys
control = Path(os.environ['OVERVIEW_TEST_CONTROL'])
with (control / 'ps-calls').open('a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
args = sys.argv[1:]
assert '-p' in args and '-o' in args, args
pid = args[args.index('-p') + 1]
start = json.loads((control / 'processes.json').read_text()).get(pid)
if start is None:
    sys.exit(1)
if isinstance(start, dict):
    start = start['C' if os.environ.get('LC_ALL') == 'C' else 'ja']
field = args[args.index('-o') + 1]
assert field in ('lstart=', 'stat=,lstart='), field
print(start if field == 'lstart=' else 'S ' + start)
''')
        self.states = {}
        for slug, ids, pid in (('alpha', ('a', 'b'), 41001), ('beta', ('c', 'd'), 41002)):
            self.make_project(slug, ids, pid)

    def executable(self, name, body):
        path = self.binary / name
        path.write_text(body)
        path.chmod(0o755)

    def note(self, slug, connection='三段', state=None, status='active'):
        reference = '- 状態記録: 従来経路' if connection == '従来経路' else (
            '' if connection is None else f'- 状態記録: {connection} [state](<{os.path.relpath(state, self.projects)}/>)')
        path = self.projects / (slug + '.md')
        path.write_text(f'---\ndate: 2026-01-01\nupdated: 2026-01-01\ntags: [project, fixture]\n'
            f'project: {slug}\nstatus: {status}\nnext: "fixture next"\nrelated: []\naliases: []\n---\n'
            f'# {slug}\n\n## 目的\nfixture goal\n\n## 守ること\nfixture constraint\n\n'
            f'## 今どこ・次に何を\nfixture next\n\n## 正本の所在\n{reference}\n\n'
            '## Tasks\n### fixture stage\n- [ ] fixture task\n')
        return path

    def event(self, slug, ident, execution, work, **extra):
        # 既存版1の旧形式も読める素材。相談・停止は下で構造化記録を追加する。
        name = 'consult' if work in ('consulting', 'consultation-wait') else (
            'stop-confirm' if work == 'stopped' else 'resume-permitted')
        return dict(version=1, actor='parent', assignment=ident, worker='fixture-worker-' + ident,
            event=name, targets=[ident], peer='fixture-worker-' + ('b' if ident == 'a' else 'a'),
            execution=execution, work=work, recorded_at=recorded, run='1',
            ref=str(self.states[slug] / 'evidence.json'), **extra)

    def save_events(self, slug, events):
        state = self.states[slug]
        (state / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
        write_json(state / 'latest.json', dict(version=1, workers={e['worker']: e for e in events}))

    def rows(self, slug):
        with (self.states[slug] / 'assignments.tsv').open() as stream:
            return list(csv.DictReader(stream, delimiter='\t'))

    def save_rows(self, slug, rows):
        with (self.states[slug] / 'assignments.tsv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=columns, delimiter='\t')
            writer.writeheader()
            writer.writerows(rows)

    def make_project(self, slug, ids, pid):
        project = self.inputs / slug
        state = project / 'output/team'
        self.states[slug] = state
        for part in ('docs', 'work', 'output/team/runs/1'):
            (project / part).mkdir(parents=True, exist_ok=True)
        note = self.note(slug, state=state)
        write_json(state / 'project.json', dict(version=1, project=slug, project_dir=str(project),
            cwd=str(project), note=str(note), workspace='fixture-' + slug, surface='fixture-surface',
            thread_id='fixture-parent-' + slug, recovery_attempted=False, recovery_complete=False,
            run='1', sequence=1, goal='fixture goal', source='fixture source', candidate='fixture-candidate',
            model='fixture-model', effort='high', selection_ref=str(state / 'evidence.json'),
            sandbox='danger-full-access', created_at=recorded))
        write_json(state / 'evidence.json', {'fixture': 'operation evidence'})
        rows = [dict.fromkeys(columns, '') for _ in ids]
        for row, ident in zip(rows, ids):
            row.update(version='1', id=ident, stage='fixture-stage', scope='fixture scope ' + ident,
                artifact=str(project / 'output' / (ident + '.txt')), role='test-writer',
                worker='fixture-worker-' + ident, address='fixture-address-' + ident,
                parent_thread='fixture-parent-' + slug, candidate='fixture-candidate', model='fixture-model',
                effort='high', selection_ref=str(state / 'evidence.json'), state_ref=str(state / 'events.jsonl'))
        self.save_rows(slug, rows)
        events = [self.event(slug, ident, 'running' if ident in ('b', 'c') else 'ended',
                            dict(a='consultation-wait', b='consulting', c='working', d='stopped')[ident])
                  for ident in ids]
        if slug == 'alpha':
            consult = dict(events[0], event='consult', peer='fixture-worker-b', topic='topic-a',
                subject='fixture discussion', scope_ref=str(state / 'evidence.json'), participants=['a', 'b'],
                phase='waiting', exchanges=[], receipt=dict(assignment='b', kind='answering',
                ref=str(state / 'evidence.json')), dependencies=[], outcome=None, next_action='fixture answer')
            events += [consult, dict(consult, topic='topic-z', phase='concluded',
                outcome=dict(classification='detail', conclusion='fixture conclusion', reason='fixture reason',
                    disposition='effective', decision_ref=None, diff_refs=[], next_action='fixture next'))]
        else:
            request = dict(events[0], event='stop-request', change='change-a', topic='topic-stop',
                owner='c', targets=['d'], scope_ref=str(state / 'evidence.json'), reason='fixture change',
                sent_refs=[dict(assignment='d', ref=str(state / 'evidence.json'))],
                next_action='fixture await permission', work='stop-requested')
            confirm = dict(events[1], change='change-a', position='fixture boundary',
                touched_refs=[str(state / 'evidence.json')], incomplete=False,
                execution_ref=str(state / 'evidence.json'))
            review = dict(version=1, actor='parent', assignment=None, worker='parent',
                event='quality-review', execution='ended', work='parent-wait', recorded_at=recorded,
                run='1', ref=str(state / 'evidence.json'), review='review-a', required=True,
                triggers=['release'], scope_ref=str(state / 'evidence.json'),
                basis_ref=str(state / 'evidence.json'), request_ref=str(state / 'evidence.json'),
                reason='fixture review needed', state='requested')
            events = [request, confirm, *events, review]
        self.save_events(slug, events)
        directory = state / 'runs/1'
        write_json(directory / 'run.json', dict(version=1, mode='start', thread_id='fixture-parent-' + slug,
            out=str(directory / 'final.md'), wrapper_pid=pid, wrapper_started='fixture ' + slug + ' start'))
        (directory / 'wrapper.log').write_text('fixture running\n')
        (directory / 'final.md').write_text('fixture parent final\n')
        write_json(directory / 'report.json', dict(version=1, summary='fixture ' + slug + ' summary',
            pending=['fixture decision'], reason='fixture boundary', read_notes=[], written_notes=[],
            notification_attempted=True, notification='unknown'))

    def run(self, *args, code=0, frames=0, mutations=None, defaults=False):
        arguments = ['overview']
        if not defaults:
            arguments += ['--projects-dir', str(self.projects), '--declarations', str(self.declarations)]
        arguments += list(map(str, args))
        write_json(self.control / 'plan.json', dict(cli=str(cli), inputs=str(self.inputs), args=arguments,
            now=observed, frames=frames, mutations=mutations or {}))
        result = subprocess.run([sys.executable, '-c', runner], env=self.env,
            capture_output=True, text=True, timeout=15)
        assert result.returncode == code, f'exit={result.returncode}, expected={code}: {result.stderr.strip()}'
        assert 'Traceback' not in result.stderr, result.stderr
        assert not (self.control / 'forbidden').exists(), 'forbidden service/tool was invoked'
        self.probe = json.loads((self.control / 'probe.json').read_text())
        return result

    def json(self, *args, **kwargs):
        result = self.run('--format', 'json', *args, **kwargs)
        lines = result.stdout.splitlines()
        assert len(lines) == 1, result.stdout
        value = json.loads(lines[0])
        assert value['version'] == 1 and value['generated_at'] == observed, value
        assert value['mode'] == 'once' and value['interval_seconds'] is None, value
        assert not self.probe['sleeps'], self.probe
        return value


def projects(value):
    return {p['project']: p for p in value['projects']}


def assert_count(count, known, exact):
    assert (count['known'], count['exact']) == (known, exact), count


def assert_text_information(text, value):
    # §9: 詳細でも生ダンプを使わず、通常表と合わせて各人・相談・時点を辿れる。
    assert not re.search(r'["\'](?:last_recorded|parent_thread|scope_ref)["\']\s*:', text), text
    assert '三段の確認済み人数' in text and '未確定の案件数' in text, text
    states = dict(running='実行中', ended='終了', unknown='未確認', working='作業',
        consulting='相談', **{'consultation-wait': '相談待ち', 'stopped': '停止',
                            'unconfirmed': '未確認', 'last-recorded': '最終記録'})
    for project in value['projects']:
        assert project['project'] in text, text
        for worker in project['workers']:
            line = next((line for line in text.splitlines() if worker['address'] in line), '')
            assert line, (worker, text)
            for key in ('execution', 'work'):
                assert worker[key] in line or states[worker[key]] in line, (worker, line)
            if worker['recorded_at']:
                assert worker['recorded_at'] in line or (
                    worker['recorded_at'][:10] in text and worker['recorded_at'][11:19] in line), line
        for topic in project['consultations']:
            line = next((line for line in text.splitlines() if topic['topic'] in line and topic['subject'] in line), '')
            assert line, (topic, text)
            assert all(re.search(r'(?<![\w-])' + re.escape(i) + r'(?![\w-])', line)
                       for i in topic['participants']), line
            labels = dict(received='受領', concluded='結論', unreceived='未受領',
                          **{'dependency-wait': '依存', 'redirect': '訂正'})
            assert topic['reception'] in line or labels[topic['reception']] in line, line
            assert topic['certainty'] in line or states[topic['certainty']] in line, line
    if any(p['counts']['running']['exact'] is None for p in value['projects']):
        assert '未確認' in text and '全案件の総人数は未確定' in text, text
    assert '\x1b' not in text, text


def test_basic(f):
    # A14/R20/A12: 重複宣言をまとめ、宣言のない案件も含めた4人と根拠・報告。
    value = f.json()
    assert value['discovery_complete'] and [p['project'] for p in value['projects']] == ['alpha', 'beta'], value
    assert value['sources'] == dict(projects_dir=str(f.projects), declarations=str(f.declarations)), value
    assert value['totals']['project_count'] == 2, value
    for name, count in (('current_started', 4), ('running', 2), ('cumulative_started', 4)):
        assert_count(value['totals'][name], count, count)
        assert value['totals'][name]['unknown_projects'] == [], value
    alpha, beta = value['projects']
    assert set(alpha['declared_workspaces']) == {'fixture-screen-1', 'fixture-screen-2'}
    assert beta['declared_workspaces'] == [] and beta['working_workers'] == ['c'] and beta['working_complete'], beta
    for project in (alpha, beta):
        assert project['connection'] == 'connected' and project['project_status'] == 'active', project
        assert project['next'] == 'fixture next' and project['parent']['status'] == 'running', project
        assert project['parent']['observed_at'] == observed and project['parent']['evidence'], project
        assert project['parent']['report']['pending'] == ['fixture decision'], project
        assert_count(project['counts']['current_started'], 2, 2)
        assert_count(project['counts']['running'], 1, 1)
        for worker in project['workers']:
            assert worker['recorded_at'] == recorded and worker['ref'] and worker['certainty'] == 'last-recorded', worker
            assert worker['address'] == 'fixture-address-' + worker['assignment'], worker
    assert [(w['assignment'], w['execution'], w['work']) for w in beta['workers']] == [
        ('c', 'running', 'working'), ('d', 'ended', 'stopped')]
    assert [t['topic'] for t in alpha['consultations']] == ['topic-a', 'topic-z'], alpha
    assert alpha['consultations'][0]['participants'] == ['a', 'b']
    assert alpha['consultations'][0]['reception'] == 'received' and alpha['consultations'][0]['active']
    assert not alpha['consultations'][1]['active']
    assert beta['coordination']['changes'][0]['confirmed'] == ['d'], beta
    assert beta['coordination']['changes'][0]['permissions'] == [], beta
    assert beta['coordination']['reviews'][0]['state'] == 'requested', beta
    text = f.run('--details').stdout
    assert_text_information(text, value)


def test_connections(f):
    # §3/5: 明示の準備中だけが0人。欠落・未接続・従来経路を同じ0にしない。
    f.note('preparing', '準備中', f.inputs / 'preparing/output/team')
    f.note('missing', '三段', f.inputs / 'missing/output/team')
    f.note('legacy', '従来経路', status='paused')
    f.note('unlinked', None, status='completed')
    f.note('beta', state=f.states['beta'], status='closed')
    write_json(f.declarations, dict(version=1, workspaces={'fixture-screen': 'declared-only'}))
    data = projects(f.json())
    assert set(data) == {'alpha', 'beta', 'preparing', 'missing', 'legacy', 'unlinked', 'declared-only'}, data
    assert data['preparing']['connection'] == 'preparing' and data['preparing']['parent']['status'] == 'not-started'
    for count in data['preparing']['counts'].values():
        assert_count(count, 0, 0)
    for slug, connection in (('missing', 'unconfirmed'), ('legacy', 'legacy'), ('unlinked', 'unconnected'),
                              ('declared-only', 'unconnected')):
        assert data[slug]['connection'] == connection and data[slug]['issues'], data[slug]
        assert data[slug]['counts']['current_started']['exact'] is None, data[slug]
    assert data['legacy']['parent']['status'] == 'not-applicable'
    assert data['beta']['connection'] == 'connected' and data['beta']['project_status'] == 'closed'


def test_defaults_and_references(f):
    # §2/3: 既存の環境変数・HOME参照を使い、宣言がなくてもノートから列挙。
    note = f.projects / 'alpha.md'
    note.write_text(note.read_text().replace(os.path.relpath(f.states['alpha'], f.projects), '~/../alpha/output/team'))
    f.declarations.unlink()
    value = f.json(defaults=True)
    assert set(projects(value)) == {'alpha', 'beta'} and value['discovery_complete'], value
    assert projects(value)['alpha']['state_dir'] == str(f.states['alpha']), value
    assert_count(value['totals']['current_started'], 4, 4)


def test_reference_mismatch(f):
    # §3: 別案件が同じSを参照しても二重計上しない。
    f.note('beta', state=f.states['alpha'])
    value = f.json()
    for project in value['projects']:
        assert project['connection'] == 'unconfirmed', project
        assert any(issue['code'] == 'reference-mismatch' for issue in project['issues']), project
    assert value['totals']['current_started']['exact'] is None, value


def test_counts_and_replacement(f):
    # A14・§4: 呼び戻し・予定枠待ちで人数は増えず、実登録した交代だけ累計へ。
    events = [json.loads(line) for line in (f.states['beta'] / 'events.jsonl').read_text().splitlines()]
    events += [f.event('beta', 'c', 'running', 'working'),
        dict(version=1, actor='parent', assignment=None, worker='parent', event='worker-slot-wait',
            execution='running', work='slot-wait', recorded_at=recorded, run='1', planned_id='future',
            ref=str(f.states['beta'] / 'evidence.json'), request_ref=str(f.states['beta'] / 'evidence.json'),
            queue_class='production', queue_order=1, blocked_by=[])]
    f.save_events('beta', events)
    assert_count(f.json()['totals']['cumulative_started'], 4, 4)
    rows = f.rows('beta')
    rows.append(dict(rows[-1], id='e', worker='fixture-worker-e', address='fixture-address-e', replaces='d',
                     handoff_ref=str(f.states['beta'] / 'evidence.json')))
    f.save_rows('beta', rows)
    events += [f.event('beta', 'e', 'running', 'working')]
    f.save_events('beta', events)
    value = f.json()
    assert_count(value['totals']['current_started'], 4, 4)
    assert_count(value['totals']['cumulative_started'], 5, 5)
    beta = projects(value)['beta']
    assert [w['assignment'] for w in beta['workers']] == ['c', 'd', 'e'], beta
    assert [w['assignment'] for w in beta['workers'] if w['current']] == ['c', 'e'], beta
    assert beta['workers'][2]['replaces'] == 'd' and not beta['workers'][1]['current'], beta


def test_consultations(f):
    # A14/A10・§4: 同一topicの最新形で受領・依存・訂正・結論を区別。
    path = f.states['alpha'] / 'events.jsonl'
    events = [json.loads(line) for line in path.read_text().splitlines()]
    base = next(e for e in events if e.get('topic') == 'topic-a')
    for kind, reception, active in ((None, 'unreceived', True), ('answering', 'received', True),
        ('dependency-wait', 'dependency-wait', True), ('redirect', 'redirect', False), ('concluded', 'concluded', False)):
        item = dict(base, receipt=None if kind is None else dict(assignment='b',
            kind='answering' if kind == 'concluded' else kind, ref=base['ref']),
            phase='concluded' if kind == 'concluded' else 'waiting',
            dependencies=['topic-z'] if kind == 'dependency-wait' else [])
        if kind == 'concluded':
            item['outcome'] = next(e['outcome'] for e in events if e.get('topic') == 'topic-z')
        events.append(item)
        f.save_events('alpha', events)
        topics = projects(f.json())['alpha']['consultations']
        assert [t['topic'] for t in topics] == ['topic-a', 'topic-z'], topics
        topic = topics[0]
        assert (topic['reception'], topic['active'], topic['recorded_at']) == (reception, active, recorded), topic
        assert topic['dependencies'] == item['dependencies'] and topic['rounds'] == 0, topic


def test_partial_record(f):
    # §4/5: 一案件の担当表破損でも、他案件の人数と読めた親の報告を残す。
    (f.states['beta'] / 'assignments.tsv').write_text('invalid fixture table\n')
    value = f.json()
    data = projects(value)
    assert set(data) == {'alpha', 'beta'} and data['beta']['issues'], value
    assert_count(data['alpha']['counts']['current_started'], 2, 2)
    assert_count(value['totals']['current_started'], 2, None)
    assert value['totals']['current_started']['unknown_projects'] == ['beta'], value
    assert data['beta']['parent']['report']['summary'] == 'fixture beta summary', value


def test_unknown_worker(f):
    # MAJOR 4・§4: aが不明でも同案件のbはrunning。knownを0に丸めない。
    path = f.states['alpha'] / 'latest.json'
    latest = json.loads(path.read_text())
    del latest['workers']['fixture-worker-a']
    write_json(path, latest)
    value = f.json()
    alpha = projects(value)['alpha']
    worker = next(w for w in alpha['workers'] if w['assignment'] == 'a')
    assert worker['certainty'] == 'unconfirmed' and worker['last_recorded'] is None, worker
    b = next(w for w in alpha['workers'] if w['assignment'] == 'b')
    assert b['execution'] == 'running' and b['certainty'] == 'last-recorded', b
    assert_count(alpha['counts']['running'], 1, None)
    assert_count(value['totals']['running'], 2, None)
    assert value['totals']['running']['unknown_projects'] == ['alpha'], value
    # MAJOR 3: 未確認もtextに残し、「計2人」と確定表示しない。
    assert_text_information(f.run('--details').stdout, value)


def test_missing_project_history(f):
    # MAJOR 1・§5/A10/A12: 登録破損は有効な相談・停止・確認履歴まで消さない。
    state = f.states['beta']
    events = [json.loads(line) for line in (state / 'events.jsonl').read_text().splitlines()]
    topic = dict(f.event('beta', 'c', 'ended', 'consultation-wait'), event='consult',
        topic='topic-history', subject='fixture historical discussion', scope_ref=str(state / 'evidence.json'),
        peer='fixture-worker-d', participants=['c', 'd'], phase='waiting', exchanges=[],
        receipt=dict(assignment='d', kind='answering', ref=str(state / 'evidence.json')),
        dependencies=[], outcome=None, next_action='fixture await answer')
    f.save_events('beta', [*events, topic])
    (state / 'project.json').write_text('{broken fixture')
    value = f.json()
    beta = projects(value)['beta']
    assert beta['connection'] == 'unconfirmed' and beta['parent']['status'] == 'unconfirmed', beta
    assert any(issue['code'] == 'record-error' for issue in beta['issues']), beta
    coordination = beta['coordination']
    assert coordination['status'] == 'unconfirmed', coordination
    assert len(coordination['topics']) == len(coordination['changes']) == len(coordination['reviews']) == 1, coordination
    assert coordination['topics'][0]['topic'] == 'topic-history', coordination
    change = coordination['changes'][0]
    assert change['change'] == 'change-a' and change['sent'] == ['d'] and change['confirmed'] == ['d'], change
    assert change['permissions'] == [], change
    review = coordination['reviews'][0]
    assert review['review'] == 'review-a' and review['state'] == 'requested', review
    assert len(beta['consultations']) == 1, beta
    consultation = beta['consultations'][0]
    assert consultation['participants'] == ['c', 'd'] and consultation['reception'] == 'received', consultation
    assert consultation['certainty'] == 'unconfirmed' and consultation['recorded_at'] == recorded, consultation
    assert consultation['ref'] == topic['ref'] and consultation['next_action'] == topic['next_action'], consultation
    assert all(w['certainty'] == 'unconfirmed' and w['last_recorded'] for w in beta['workers']), beta
    assert_count(projects(value)['alpha']['counts']['running'], 1, 1)


def test_declaration_error(f):
    # §3/5: 宣言破損時もProjects由来の案件・knownを残し、全exactは不明。
    f.declarations.write_text('{broken fixture')
    value = f.json()
    assert set(projects(value)) == {'alpha', 'beta'} and not value['discovery_complete'], value
    assert any(i['code'] == 'declaration-error' for i in value['issues']), value
    for key, count in (('current_started', 4), ('running', 2), ('cumulative_started', 4)):
        assert_count(value['totals'][key], count, None)


def test_retired_logs(f):
    # A10・§5: workと親生ログの退役で恒久記録の結論・未決・根拠を消さない。
    (f.inputs / 'alpha/work').rmdir()
    (f.states['alpha'] / 'runs/1/wrapper.log').unlink()
    (f.states['alpha'] / 'runs/1/final.md').unlink()
    write_json(f.processes, {'41002': 'fixture beta start'})
    alpha = projects(f.json())['alpha']
    assert alpha['parent']['status'] == 'unconfirmed', alpha
    assert alpha['parent']['report']['pending'] == ['fixture decision'], alpha
    assert_count(alpha['counts']['cumulative_started'], 2, 2)
    topics = {topic['topic']: topic for topic in alpha['consultations']}
    assert topics['topic-a']['reception'] == 'received' and topics['topic-a']['ref'], topics
    assert topics['topic-a']['certainty'] == 'unconfirmed', topics
    assert topics['topic-z']['outcome']['conclusion'] == 'fixture conclusion', topics
    assert topics['topic-z']['next_action'] == 'fixture answer', topics
    assert all(w['last_recorded'] and w['recorded_at'] == recorded for w in alpha['workers']), alpha


def test_parent_observation(f, kind):
    # §4/5: PID再利用・非0終了は未確認、正常終了も子の完了へ流用しない。
    processes = json.loads(f.processes.read_text())
    if kind == 'pid-reused':
        processes['41001'] = 'fixture different process start'
    else:
        del processes['41001']
        (f.states['alpha'] / 'runs/1/wrapper.log').write_text('EXIT:' + ('0' if kind == 'finished' else '1') + '\n')
    write_json(f.processes, processes)
    value = f.json()
    alpha = projects(value)['alpha']
    assert alpha['parent']['status'] == ('finished' if kind == 'finished' else 'unconfirmed'), alpha
    b = next(w for w in alpha['workers'] if w['assignment'] == 'b')
    assert b['last_recorded']['execution'] == 'running' and b['recorded_at'] == recorded, b
    if kind == 'finished':
        assert b['execution'] == 'running' and b['work'] == 'consulting', b
    else:
        assert (b['execution'], b['work'], b['certainty']) == ('unknown', 'unconfirmed', 'unconfirmed'), b
        assert_count(alpha['counts']['running'], 0, None)
        assert_count(value['totals']['current_started'], 4, 4)


def test_watch(f, interval):
    # §2/4/6: 即時表示、各回の親観測、次回だけの子更新、書き込み0とCtrl-C。
    if interval == 'settings':
        write_json(f.workflow, dict(version=1, consultation_round_limit=3, overview_interval_seconds=.4))
    elif interval == 'explicit':
        write_json(f.workflow, dict(version=1, consultation_round_limit=3))
    else:
        assert json.loads((repo / 'team/data/workflow.json').read_text())['overview_interval_seconds'] == 2
    effective = .4 if interval == 'settings' else .25 if interval == 'explicit' else 2
    events = [json.loads(line) for line in (f.states['beta'] / 'events.jsonl').read_text().splitlines()]
    event = f.event('beta', 'c', 'ended', 'stopped')
    event['recorded_at'] = '2026-01-01T01:00:00Z'
    events.append(event)
    mutations = {'1': [dict(op='json', path=str(f.processes), value={'41002': 'fixture beta start'})],
                 '2': [dict(op='json', path=str(f.states['beta'] / 'latest.json'), value=dict(version=1,
                           workers={e['worker']: e for e in events})),
                       dict(op='text', path=str(f.states['beta'] / 'events.jsonl'),
                           value=''.join(json.dumps(e) + '\n' for e in events))]}
    args = ('--interval', '.25') if interval == 'explicit' else ()
    result = f.run('--format', 'json', '--watch', *args, code=130, frames=3, mutations=mutations)
    frames = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(frames) == 3 and f.probe['sleeps'] == [effective] * 3, result.stdout
    assert all(v['mode'] == 'watch' and v['interval_seconds'] == effective for v in frames), frames
    assert frames[0]['generated_at'] == observed, frames[0]
    times = [datetime.fromisoformat(v['generated_at'].replace('Z', '+00:00')) for v in frames]
    assert times == sorted(set(times)), frames
    assert projects(frames[0])['alpha']['parent']['status'] == 'running'
    assert projects(frames[1])['alpha']['parent']['status'] == 'unconfirmed'
    assert_count(projects(frames[1])['alpha']['counts']['running'], 0, None)
    assert projects(frames[1])['beta']['working_workers'] == ['c']
    assert projects(frames[2])['beta']['working_workers'] == []
    for frame in frames:
        a = next(w for w in projects(frame)['alpha']['workers'] if w['assignment'] == 'a')
        assert a['recorded_at'] == recorded and a['last_recorded']['work'] == 'consultation-wait', a


def test_interval_errors(f):
    # §2/5: 単発は間隔設定不要、明示0は引数エラー、既定watchは設定欠落を隠さない。
    write_json(f.workflow, dict(version=1, consultation_round_limit=3))
    f.json()
    result = f.run('--format', 'json', '--interval', '0', code=2)
    assert not result.stdout and 'interval' in result.stderr.lower(), result
    result = f.run('--format', 'json', '--watch', code=1)
    assert not result.stdout and 'project-leader: overview-settings-error:' in result.stderr, result


def test_source_failure(f):
    # §5: 列挙入口の失敗は正常JSONに混ぜず、空Projectsは宣言との和集合を返す。
    f.projects.rename(f.vault / 'Projects-retired')
    result = f.run('--format', 'json', code=1)
    assert not result.stdout and 'project-leader: overview-source-error:' in result.stderr, result
    f.projects.mkdir()
    value = f.json()
    assert list(projects(value)) == ['alpha'] and projects(value)['alpha']['connection'] == 'unconnected', value


def test_locale_observation(f, legacy=False):
    # trial-s4 B: 実ロケールの導入有無に依存せず、psだけがロケール差を再現する。
    english, japanese = 'Tue Nov  3 00:00:00 2026', '火 11/ 3 00:00:00 2026'
    write_json(f.processes, {'41001': {'C': english, 'ja': japanese}, '41002': 'fixture beta start'})
    f.env['LC_ALL'] = 'ja_JP.UTF-8'
    # 起動時の保存口を通し、実プロセス起動や実psを使わない。
    code = 'import runpy,sys; m=runpy.run_path(sys.argv[1]); print(m["process_start"](41001))'
    result = subprocess.run([sys.executable, '-c', code, str(cli)], env=f.env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    path = f.states['alpha'] / 'runs/1/run.json'
    run = json.loads(path.read_text())
    run['wrapper_started'] = japanese if legacy else result.stdout.strip()
    write_json(path, run)
    f.env['LC_ALL'] = 'C'
    alpha = projects(f.json())['alpha']
    if not legacy:
        assert alpha['parent']['status'] == 'running', alpha
        assert run['wrapper_started'] == english, run
    else:
        # 旧ja記録は正規化して一致ならrunning、解釈不能なら明示の未確認を許す。
        assert alpha['parent']['status'] in ('running', 'unconfirmed'), alpha
        if alpha['parent']['status'] == 'unconfirmed':
            assert alpha['issues'] and all(w['last_recorded'] for w in alpha['workers']), alpha
    # 旧記録を無条件に生存扱いしない。別の開始時刻なら必ず未確認。
    write_json(f.processes, {'41001': {'C': 'Wed Nov  4 00:00:00 2026',
                                    'ja': '水 11/ 4 00:00:00 2026'}, '41002': 'fixture beta start'})
    assert projects(f.json())['alpha']['parent']['status'] == 'unconfirmed'


def test_compact_text(f):
    # trial-s4 C・§9.2/9.3: 通常表は1案件1行。生ダンプ・名前と数だけでは通らない。
    value = f.json()
    text = f.run().stdout
    assert '三段の確認済み人数' in text and '未確定の案件数' in text, text
    known = next((line for line in text.splitlines() if '三段の確認済み人数' in line), '')
    for label, key in (('現担当', 'current_started'), ('実行中', 'running'), ('累計', 'cumulative_started')):
        assert re.search(label + r'\s*[:：]?\s*' + str(value['totals'][key]['known']) + r'\s*人', known), known
    assert re.search(r'現担当.*実行中.*累計', text), text
    assert all(label in text for label in ('案件', '接続', '親', '相談', '最終記録')), text
    assert observed in text or ('2026-01-02' in text and 'UTC' in text and '00:00:00' in text), text
    rows = {}
    for slug in ('alpha', 'beta'):
        matches = [line for line in text.splitlines() if re.match(r'^\s*\|?\s*' + slug + r'\b', line)]
        assert len(matches) == 1, (slug, text)
        rows[slug] = matches[0]
        assert '実行中' in matches[0] and ('2026-01-01' in matches[0]), matches[0]
        assert re.search(r'2\s*(?:人)?\s*[/／|]\s*1\s*(?:人)?\s*[/／|]\s*2', matches[0]), matches[0]
    for ident, work, execution in (('a', '相談待ち', '終了'), ('b', '相談', '実行中'),
                                  ('c', '作業', '実行中'), ('d', '停止', '終了')):
        row = rows['alpha' if ident in ('a', 'b') else 'beta']
        assert re.search(r'\b' + ident + r'\s*[:：]\s*' + work + r'[^|]*?' + execution, row), row
    assert 'topic-a' in rows['alpha'] and '受領' in rows['alpha'], rows
    assert re.search(r'a\s*[,/／・↔ -]\s*b', rows['alpha']), rows
    assert 'topic-z' not in rows['alpha'], rows
    assert not re.search(r'["\'](?:last_recorded|parent_thread|scope_ref)["\']\s*:', text), text


def test_project_selection_and_all(f):
    # trial-s4 C・§9.1/9.2/9.3: 案内・メモを数えず、宣言だけは残す。同じ素材でallも確認。
    f.note('legacy', '従来経路', status='closed')
    f.note('unlinked', None, status='paused')
    f.note('missing', '三段', f.inputs / 'missing/output/team')
    f.note('ReadMe', state=f.states['alpha'])  # project付きでも案内は対象外。
    for slug in ('memo', 'declared-memo'):
        (f.projects / (slug + '.md')).write_text('---\ntags: [fixture]\n---\nfixture memo\n')
    write_json(f.declarations, dict(version=1, workspaces={
        'fixture-screen': 'alpha', 'fixture-only': 'declared-only', 'fixture-memo': 'declared-memo'}))
    value = f.json()
    expected = {'alpha', 'beta', 'legacy', 'unlinked', 'missing', 'declared-only', 'declared-memo'}
    assert set(projects(value)) == expected and value['totals']['project_count'] == 7, value
    assert projects(value)['declared-memo']['connection'] == 'unconnected', value
    for key, n in (('current_started', 4), ('running', 2), ('cumulative_started', 4)):
        assert_count(value['totals'][key], n, None)
        assert len(value['totals'][key]['unknown_projects']) == 5, value
    # 表示オプションはJSONの内容・集計を変えない。
    assert f.json('--all', '--details') == value
    text = f.run().stdout
    known = next((line for line in text.splitlines() if '三段の確認済み人数' in line), '')
    for label, n in (('現担当', 4), ('実行中', 2), ('累計', 4)):
        assert re.search(label + r'\s*[:：]?\s*' + str(n) + r'\s*人', known), known
    for label, slugs in (('未接続', ['declared-memo', 'declared-only', 'unlinked']), ('従来経路', ['legacy'])):
        lines = [line for line in text.splitlines() if re.match(r'^\s*' + label + r'\s+' + str(len(slugs)) + r'\s*件', line)]
        assert len(lines) == 1 and all(slug in lines[0] for slug in slugs), text
        assert '人数' in lines[0] and re.search('不明|未確認|未確定', lines[0]), lines
        assert not any(re.match(r'^\s*\|?\s*' + slug + r'\b', line) for slug in slugs for line in text.splitlines()), text
    assert any(re.match(r'^\s*\|?\s*missing\b', line) for line in text.splitlines()), text
    unknown = next((line for line in text.splitlines() if '未確定の案件数' in line), '')
    for label in ('現担当', '実行中', '累計'):
        assert re.search(label + r'\s*[:：]?\s*5\s*件', unknown), unknown
    assert '全案件の総人数は未確定' in text and '従来経路' in text, text
    all_text = f.run('--all').stdout
    assert next((line for line in all_text.splitlines() if '三段の確認済み人数' in line), '') == known, all_text
    assert next((line for line in all_text.splitlines() if '未確定の案件数' in line), '') == unknown, all_text
    for slug in expected:
        assert len([line for line in all_text.splitlines() if re.match(r'^\s*\|?\s*' + slug + r'\b', line)]) == 1, all_text
    assert not re.search(r'^\s*(未接続|従来経路)\s+\d+\s*件:', all_text, re.MULTILINE), all_text


def test_watch_source_failure(f):
    # §5: watch途中の致命的失敗は完全な既出フレームだけを残して終了する。
    result = f.run('--format', 'json', '--watch', '--interval', '.25', code=1, frames=2,
        mutations={'1': [dict(op='rename', path=str(f.projects), destination=str(f.vault / 'Projects-retired'))]})
    assert len(result.stdout.splitlines()) == 1 and json.loads(result.stdout)['version'] == 1, result.stdout
    assert 'project-leader: overview-source-error:' in result.stderr, result.stderr


cases = [
    ('TRIAL-S4/B: jaで保存しCで観測しても同じPIDは生存一致', test_locale_observation),
    ('TRIAL-S4/B: 保存済みja文字列を読み、PID再利用を生存扱いしない', lambda f: test_locale_observation(f, True)),
    ('TRIAL-S4/C: 通常表の1案件1行・人数の言葉・各人・相談・時点', test_compact_text),
    ('TRIAL-S4/C: 対象選別・未接続まとめ・allとJSONの不変', test_project_selection_and_all),
    ('A14/R20/A12: 2案件4人・相談組・作業中・報告・時点をJSONとtextへ', test_basic),
    ('§3: 準備中0人・記録欠落・従来経路・未接続と全statusの列挙', test_connections),
    ('§2/3: 既存環境変数とHOME参照、宣言解除後のノートからの列挙', test_defaults_and_references),
    ('§3: 同じ保存先を異なる案件が参照しても二重計上しない', test_reference_mismatch),
    ('A14: 呼び戻し・予定人数・交代済みと現担当・累計を区別', test_counts_and_replacement),
    ('A14/A10: 論点ごとに未受領・受領・依存先待ち・宛先訂正・結論を区別', test_consultations),
    ('§5: 一案件の破損でも他案件と確認済み合計・保存報告を残す', test_partial_record),
    ('§4: 子の記録欠落時も確認済みrunningだけをknownへ', test_unknown_worker),
    ('MAJOR 1: project.json破損でも相談・停止・確認履歴を現在未確認の最終記録として残す', test_missing_project_history),
    ('§3/5: 宣言破損でもノートの案件を残し列挙不完全を表示', test_declaration_error),
    ('A10: 生ログ退役後も担当・結論・未決・次の一手を保存記録から辿る', test_retired_logs),
    ('§2: 単発に既定間隔は不要、明示0とwatch設定欠落は区別', test_interval_errors),
    ('§5: Projects入口失敗と空ディレクトリを区別', test_source_failure),
    ('§5: watch途中の入口失敗は既出フレームを保つ', test_watch_source_failure),
]
for kind in ('pid-reused', 'finished', 'failed'):
    cases.append((f'§4: 親の{kind}を毎回観測し子の最終記録と現在を区別',
                  lambda f, k=kind: test_parent_observation(f, k)))
for interval in ('default', 'settings', 'explicit'):
    cases.append((f'§2/4/6: watch/{interval} の間隔・親観測・子更新・書き込み0',
                  lambda f, i=interval: test_watch(f, i)))

with tempfile.TemporaryDirectory(prefix='project-overview-acceptance-') as temporary:
    for index, (label, test) in enumerate(cases):
        try:
            fixture = Fixture(Path(temporary) / str(index))
            test(fixture)
        except (AssertionError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
            failed += 1
            print(f'  NG - {label}: {error}')
        else:
            passed += 1
            print(f'  ok - {label}')
print(f'=== summary: {passed} passed, {failed} failed ===')
sys.exit(1 if failed else 0)
PY
