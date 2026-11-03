#!/usr/bin/env bash
# 段階2の外部契約（stage2-contract §2〜7）。実装本体をimportせずCLIで確認する。
# A7a/A7b/A13/A6と結果回収。内蔵操作・実読了・枠解放は親の実環境確認へ。
# fixtureはこのファイル内で生成し、実Vault・個人設定・外部サービスを使わない。
# 実行: bash tests/test-project-workers-acceptance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import csv
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tomllib

repo = Path(sys.argv[1])
cli = repo / 'team/connect/codex/project-leader.py'
candidates_cli = repo / 'team/connect/claude-code/role_candidates.py'
columns = ('version id stage scope artifact role worker address parent_thread candidate '
           'model effort selection_ref replaces handoff_ref state_ref').split()
role = 'test-writer'
required_notes = ['absolute-rules', 'core-worker', 'worker-role-' + role]
passed = failed = 0


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False) + '\n', encoding='utf-8')
    return path


def snapshot(root):
    return {str(p.relative_to(root)): ('link', os.readlink(p)) if p.is_symlink()
            else ('file', p.read_bytes()) if p.is_file() else ('dir',)
            for p in root.rglob('*')}


class Fixture:
    def __init__(self, root):
        self.root = root
        self.home = root / 'home'
        self.project = root / 'project'
        self.work = self.project / 'work'
        self.state = self.project / 'output/team'
        self.prefs = self.home / 'Data/obsidian/Preferences'
        self.agents = self.home / '.claude/agents'
        self.codex_agents = self.home / '.codex/agents'
        self.cache = root / 'cache'
        self.profile = self.home / '.config/takumi009-ai-env/profile.md'
        self.models = self.profile.with_name('models.conf')
        self.binary = root / 'bin'
        for path in (self.work, self.state, self.project / 'docs', self.prefs, self.agents,
                     self.codex_agents, self.cache, self.profile.parent, self.binary):
            path.mkdir(parents=True, exist_ok=True)
        # 白紙の環境から必要な参照先だけを指定し、呼出元の個人設定を継承しない。
        self.env = dict(HOME=str(self.home), PATH=str(self.binary) + os.pathsep + os.environ['PATH'],
                        PYTHONDONTWRITEBYTECODE='1', SKIP_LAUNCHCTL='1', LAUNCHCTL_TIMEOUT_SECS='1',
                        AIENV_LOCAL_PROFILE_PATH=str(self.profile), AIENV_MODEL_DEFS_FILE=str(self.models),
                        AIENV_USAGE_CACHE_DIR=str(self.cache), AIENV_PREFERENCES_DIR=str(self.prefs),
                        AIENV_COMPONENTS_FILE=str(root / 'components.env'),
                        CMUX_TASK_CMUX_BIN=str(self.binary / 'cmux'),
                        FIXTURE_EXTERNAL_CALLS=str(root / 'external-calls'))
        for command in ('codex', 'claude', 'cmux', 'launchctl', 'osascript', 'git', 'gh', 'curl'):
            path = self.binary / command
            path.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$FIXTURE_EXTERNAL_CALLS"\nexit 97\n')
            path.chmod(0o755)
        self.profile.write_text('---\nschema_version: 7\nprofile_slug: fixture\n'
            'team_mode: configured value=full\nno_read_paths: unavailable\n'
            'machine_role: configured value=main\nrole.leader: configured model=fixture-claude\n'
            'role.test-writer: configured model=fixture-code,fixture-other,fixture-claude\n'
            'role.verifier: not_adopted\n---\n')
        self.models.write_text('[fixture-code]\nprovider=external\nexecution=external-cli\n'
            'model=fixture-model\neffort=high\n\n'
            '[fixture-other]\nprovider=external\nexecution=external-cli\n'
            'model=fixture-other-model\neffort=low\n\n'
            '[fixture-claude]\nprovider=anthropic-api\nmodel=claude-sonnet-5-5\neffort=high\n')
        for name in required_notes:
            (self.prefs / (name + '.md')).write_text('fixture reference: ' + name + '\n')
        (self.agents / (role + '.md')).write_text('---\nname: test-writer\n---\n')
        (self.codex_agents / (role + '.toml')).write_text('name = "test-writer"\n'
            'description = "テスト作成の担当"\ndeveloper_instructions = """\n'
            '着手前に ~/Data/obsidian/Preferences/absolute-rules.md → core-worker.md → '
            'worker-role-test-writer.md を全文読み、従う。\n"""\n')
        self.usage()
        self.request_ref = self.work / 'request.md'
        self.request_ref.write_text('背景・目的: fixture。担当: 試験。受入: 契約に従う。\n'
            '成果: output/tests.txt。報告: work/report.md。禁止: 実装本体の編集。\n'
            f'参照: {self.project / "docs/design.md"}。担当表: {self.state / "assignments.tsv"}\n')
        self.stop_ref = self.project / 'docs/tasks.md'
        self.stop_ref.write_text('fixture approved stop point: 5h remaining 25%。\n')
        self.artifact = self.project / 'output/tests.txt'
        self.artifact.write_text('fixture artifact\n')
        self.report_ref = self.work / 'worker-report.md'
        self.report_ref.write_text('fixture final response\nsecond line: pending parent review\n')
        self.handoff = self.project / 'docs/handoff.md'
        self.handoff.write_text('成果・担当表・有効な判断と理由・議論の結論・未決・停止位置・次の一手: fixture\n')
        self.operation_ref = write_json(self.work / 'operation.json', {'address': 'fixture-address-a'})
        self.prepare_ref = write_json(self.work / 'prepared.json', self.prepared())
        # 公開版1記録を入力にする。起動・init・実際の内蔵一覧には依存しない。
        note = self.home / 'Data/obsidian/Projects/example.md'
        note.parent.mkdir(parents=True)
        note.write_text('fixture project note\n')
        write_json(self.state / 'project.json', dict(version=1, project='example',
            project_dir=str(self.project), cwd=str(self.project), workspace='fixture-workspace',
            surface='fixture-surface', thread_id='fixture-parent', recovery_attempted=False,
            recovery_complete=False, run='1', sequence=1, note=str(note), goal='fixture goal',
            source='fixture source', candidate='fixture-parent-candidate', model='fixture-parent-model',
            effort='high', selection_ref=str(self.stop_ref), sandbox='danger-full-access',
            created_at=datetime.now(timezone.utc).isoformat()))
        with (self.state / 'assignments.tsv').open('w', newline='') as stream:
            csv.writer(stream, delimiter='\t').writerow(columns)
        (self.state / 'events.jsonl').touch()
        write_json(self.state / 'latest.json', {'version': 1, 'workers': {}})
        run = self.state / 'runs/1'
        write_json(run / 'run.json', dict(version=1, mode='start', thread_id='fixture-parent',
                                         out=str(run / 'final.md')))
        (run / 'final.md').write_text('fixture parent final\n')
        (run / 'wrapper.log').write_text('EXIT:0\n')
        write_json(run / 'report.json', dict(version=1, summary='fixture parent summary',
            pending=[], reason='fixture boundary', read_notes=[], written_notes=[],
            notification_attempted=True, notification='unknown'))

    def usage(self, h5=80, d7=70):
        now = int(time.time())
        for service in ('codex', 'claude'):
            write_json(self.cache / (service + '-cache.json'), dict(schema_version=1,
                service=service, fetched_at=now, updated_at=now, last_error=None,
                five_hour=dict(used_percent=100-h5, resets_at_epoch=now+3600),
                seven_day=dict(used_percent=100-d7, resets_at_epoch=now+90000)))

    def prepared(self):
        return dict(version=1, status='ready', mode='new', operation='spawn', target=None,
            agent_type=role, model='fixture-model', reasoning_effort='high', fork_turns='none',
            phase='read-confirmation', message='fixture read confirmation',
            assignment=dict(id='a', stage='tests', scope='fixture scope', artifact=str(self.artifact),
                            role=role, candidate='fixture-code', model='fixture-model', effort='high'),
            usage=dict(checked_at=datetime.now(timezone.utc).isoformat(), h5=80, d7=70,
                       stop_remaining_percent=25, stop_ref=str(self.stop_ref), candidate='fixture-code'),
            selection_sources=[str(self.profile), str(self.models)])

    def run(self, *args, script=cli, code=0, json_output=True):
        result = subprocess.run([sys.executable, str(script), *map(str, args)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == code, f'exit={result.returncode}, expected={code}: {result.stderr.strip()}'
        return json.loads(result.stdout) if json_output else result

    def record(self, command, value, code=0):
        source = write_json(self.work / (command + '.json'), value)
        return self.run(command, '--state-dir', self.state, '--file', source, code=code,
                        json_output=(code == 0))

    def row(self, ident='a', **extra):
        return dict(id=ident, stage='tests', scope='fixture scope', artifact=str(self.artifact),
            role=role, worker='fixture-worker-' + ident, address='fixture-address-' + ident,
            parent_thread='fixture-parent', candidate='fixture-code', model='fixture-model',
            effort='high', selection_ref=str(self.state / 'events.jsonl'), **extra)

    def assign(self, ident='a', **extra):
        return self.record('assign', self.row(ident, **extra))

    def event(self, event, **extra):
        return dict(actor='parent', assignment='a', worker='fixture-worker-a', event=event,
                    execution='ended', work='parent-wait', ref=str(self.operation_ref), **extra)

    def seed(self, ready=True, execution='ended'):
        self.assign()
        # 読了済み→一旦終了、という過去の明示履歴。最新だけを読了の正本にしない。
        events = []
        if ready:
            events.append(self.event('worker-ready', role=role, read_notes=required_notes,
                                     prohibitions=['実装本体を編集しない']))
        events.append(self.event('worker-done', handoff_ref=str(self.handoff)))
        events[-1].update(execution=execution, work='done' if execution == 'ended' else 'unconfirmed')
        for value in events:
            value.update(version=1, recorded_at=datetime.now(timezone.utc).isoformat(), run='1')
        (self.state / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
        write_json(self.state / 'latest.json', {'version': 1, 'workers': {'fixture-worker-a': events[-1]}})

    def request(self, mode='new', **extra):
        value = dict(mode=mode, request_ref=str(self.request_ref),
                     stop_remaining_percent=25, stop_ref=str(self.stop_ref))
        if mode == 'new':
            value.update(id='a', role=role, candidate='fixture-code', stage='tests',
                         scope='fixture scope', artifact=str(self.artifact))
        else:
            value['assignment'] = 'a'
            if mode == 'replace':
                value.update(id='b', candidate='fixture-other', reason='resume-unavailable',
                             old_execution_ref=str(self.operation_ref), handoff_ref=str(self.handoff))
        return dict(value, **extra)

    def prepare(self, value, code=0, reason=None):
        source = write_json(self.work / 'prepare-request.json', value)
        before = snapshot(self.state)
        result = self.run('worker-prepare', '--state-dir', self.state, '--file', source,
                          code=code, json_output=(code != 1))
        assert snapshot(self.state) == before, 'worker-prepare changed state records'
        if code == 1:
            assert not result.stdout.strip(), result.stdout
            assert f'project-leader: {reason}:' in result.stderr, result.stderr
        elif code == 3:
            assert result['version'] == 1 and result['status'] == 'deferred', result
            assert result['reason'] == reason and 'usage' in result, result
        else:
            assert result['version'] == 1 and result['status'] == 'ready', result
        return result

    def view(self, command='status'):
        return self.run(command, '--state-dir', self.state)

    def install(self, *args, code=0):
        result = subprocess.run(['bash', str(repo / 'core/assembly/install-main.sh'), *args],
            env=self.env, capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) if code == 0 else (result.returncode != 0), result.stderr
        return result.stdout + result.stderr


def test_candidates(f):
    # §2: resolved values, no automatic choice, and legacy TSV agree.
    data = f.run('--profile', f.profile, '--agents-dir', f.agents,
                 '--role', role, '--format', 'json', script=candidates_cli)
    assert data['version'] == 1 and data['unresolved'] == [], data
    values = data['candidates']
    assert {v['candidate'] for v in values} == {'fixture-code', 'fixture-other', 'fixture-claude'}
    code = next(v for v in values if v['candidate'] == 'fixture-code')
    assert code == dict(role=role, candidate='fixture-code', route='external-cli',
                       model='fixture-model', effort='high', ok='ok', h5=80, d7=70)
    legacy = f.run('--role', role, script=candidates_cli, json_output=False)
    rows = list(csv.DictReader(legacy.stdout.splitlines(), delimiter='\t'))
    assert legacy.stdout.splitlines()[0] == 'role\tdef\troute\tpass\tok\th5\td7'
    assert {(r['def'], r['route'], r['ok'], int(r['h5']), int(r['d7'])) for r in rows} == {
        (v['candidate'], v['route'], v['ok'], v['h5'], v['d7']) for v in values}


def test_fixture(f):
    # 入力自体の不備による赤ではないことを既存の口で確かめる。
    legacy = f.run('--role', role, script=candidates_cli, json_output=False)
    rows = list(csv.DictReader(legacy.stdout.splitlines(), delimiter='\t'))
    selected = next(row for row in rows if row['def'] == 'fixture-code')
    assert (selected['route'], selected['ok'], selected['h5'], selected['d7']) == ('external-cli', 'ok', '80', '70')
    assert '--model fixture-model' in selected['pass'] and '--effort high' in selected['pass']
    assert tomllib.loads((f.codex_agents / (role + '.toml')).read_text())['name'] == role
    assert f.view('collect')['status'] == 'finished'


def test_unresolved(f):
    absent = f.run('--role', 'verifier', '--format', 'json', script=candidates_cli)
    assert absent == dict(version=1, candidates=[], unresolved=['not_adopted']), absent
    f.profile.unlink()
    result = f.run('--role', role, '--format', 'json', script=candidates_cli, json_output=False)
    assert json.loads(result.stdout) == dict(version=1, candidates=[], unresolved=['PROFILE_NOT_FOUND'])
    assert 'PROFILE_NOT_FOUND' in result.stderr


def test_new(f):
    value = f.prepare(f.request())
    assert value['assignment'] == f.prepared()['assignment']
    assert (value['mode'], value['operation'], value['target'], value['agent_type'], value['model'],
            value['reasoning_effort'], value['fork_turns'], value['phase']) == (
            'new', 'spawn', None, role, 'fixture-model', 'high', 'none', 'read-confirmation')
    for reference in (*[name + '.md' for name in required_notes],
                      str(f.request_ref), str(f.state / 'assignments.tsv')):
        assert reference in value['message'], reference
    assert set(value['selection_sources']) == {str(f.profile), str(f.models)}
    assert {k: value['usage'][k] for k in ('h5', 'd7', 'stop_remaining_percent', 'stop_ref', 'candidate')} == {
        k: f.prepared()['usage'][k] for k in ('h5', 'd7', 'stop_remaining_percent', 'stop_ref', 'candidate')}
    assert datetime.fromisoformat(value['usage']['checked_at'].replace('Z', '+00:00')).utcoffset().total_seconds() == 0


def test_resume(f):
    f.seed()
    f.usage(h5=63, d7=52)  # 初回の80/70を再利用しない。
    value = f.prepare(f.request('resume'))
    assert (value['mode'], value['operation'], value['target'], value['agent_type'],
            value['model'], value['reasoning_effort'], value['phase']) == (
            'resume', 'followup', 'fixture-address-a', role, 'fixture-model', 'high', 'task')
    assert value['assignment']['id'] == 'a' and value['assignment']['candidate'] == 'fixture-code'
    assert (value['usage']['h5'], value['usage']['d7']) == (63, 52)
    assert f.view()['current_assignment_ids'] == ['a']
    assert f.prepare(f.request('resume', confirm_reading=True))['phase'] == 'read-confirmation'


def test_role_definition_source(f, source):
    # ROLE-SOURCE: project.json の cwd を使い、探索用の追加引数は渡さない。
    project = json.loads((f.state / 'project.json').read_text())
    cwd = f.work / 'checkout'
    cwd.mkdir()
    project['cwd'] = str(cwd)
    write_json(f.state / 'project.json', project)
    home_definition = f.codex_agents / (role + '.toml')
    project_definition = cwd / '.codex/agents' / home_definition.name
    if source in ('project', 'invalid-project'):
        # C2: 両方を残し、ホーム優先への退行を採用元の記録で検出する。
        project_definition.parent.mkdir(parents=True)
        project_definition.write_text(home_definition.read_text())
        if source == 'invalid-project':
            # C5: 案件側のnameが不正なら、正常なホーム側へ逃げずに拒否する。
            project_definition.write_text(project_definition.read_text().replace(
                'name = "test-writer"', 'name = "wrong-role"'))
            f.prepare(f.request(), code=1, reason='invalid-role-definition')
            return
    elif source == 'missing':
        home_definition.unlink()
        f.prepare(f.request(), code=1, reason='invalid-role-definition')
        return
    value = f.prepare(f.request())
    expected = project_definition if source == 'project' else home_definition
    # 記録のフィールド名は縛らず、採用した定義ファイルを結果から識別できること。
    assert json.dumps(str(expected)) in json.dumps(value), f'definition source not recorded: {expected}'


def test_missing_reading(f):
    f.seed(ready=False)
    value = f.prepare(f.request('resume'))
    assert value['target'] == 'fixture-address-a' and value['phase'] == 'read-confirmation'


def test_definition_change(f):
    f.seed()
    f.models.write_text(f.models.read_text().replace('model=fixture-model\n', 'model=fixture-changed\n'))
    f.prepare(f.request('resume'), code=3, reason='resume-unavailable')


def test_deferred(f, mode, h5, d7, reason):
    if mode != 'new':
        f.seed()
    if h5 is None:
        (f.cache / 'codex-cache.json').unlink()
    else:
        f.usage(h5=h5, d7=d7)
    f.prepare(f.request(mode), code=3, reason=reason)


def test_execution(f, execution, reason):
    f.seed(execution=execution)
    f.prepare(f.request('resume'), code=3, reason=reason)
    f.prepare(f.request('replace'), code=3, reason=reason)


def test_replace(f):
    f.seed()
    value = f.prepare(f.request('replace'))
    assert (value['mode'], value['operation'], value['target'], value['phase']) == (
        'replace', 'spawn', None, 'read-confirmation')
    replacement = value['assignment']
    assert {k: replacement[k] for k in ('id', 'replaces', 'handoff_ref', 'role', 'candidate', 'model', 'effort')} == dict(
        id='b', replaces='a', handoff_ref=str(f.handoff), role=role,
        candidate='fixture-other', model='fixture-other-model', effort='low')
    for key in ('stage', 'scope', 'artifact'):
        assert replacement[key] == f.row()[key]
    f.record('assign', dict(replacement, worker='fixture-worker-b', address='fixture-address-b',
                           parent_thread='fixture-parent', selection_ref=str(f.state / 'events.jsonl')))
    result = f.view()
    assert [r['id'] for r in result['assignments']] == ['a', 'b']
    assert result['current_assignment_ids'] == ['b']
    assert result['assignments'][0]['address'] == 'fixture-address-a'
    assert result['assignments'][1]['replaces'] == 'a'


def test_invalid_prepare(f, kind):
    request = f.request()
    reason = 'invalid-request'
    if kind == 'reference':
        f.request_ref.unlink()
        reason = 'invalid-reference'
    elif kind == 'route':
        request['candidate'] = 'fixture-claude'
        reason = 'wrong-route'
    elif kind == 'unresolved':
        request['candidate'] = 'not-configured'
        reason = 'candidate-unresolved'
    elif kind == 'resume-selection':
        f.seed()
        request = f.request('resume', candidate='fixture-other')
    elif kind == 'replace-reason':
        f.seed()
        request = f.request('replace', reason='stop-point')
    f.prepare(request, code=1, reason=reason)


def test_reading_rejected(f, kind):
    f.seed(ready=False)
    value = f.event('worker-ready', role=role, read_notes=required_notes[:],
                    prohibitions=['実装本体を編集しない'])
    if kind == 'notes':
        value['read_notes'] = ['worker-role-' + role]
    elif kind == 'role':
        value['role'] = 'verifier'
    else:
        value['prohibitions'] = []
    before = snapshot(f.state)
    f.record('event', value, code=1)
    assert snapshot(f.state) == before
    assert f.prepare(f.request('resume'))['phase'] == 'read-confirmation'


def test_event_binding(f):
    f.assign()
    value = f.event('worker-unavailable', reason='operation-failed')
    value.update(worker='unregistered-worker', execution='unknown', work='unconfirmed')
    before = snapshot(f.state)
    f.record('event', value, code=1)
    assert snapshot(f.state) == before


def test_queue(f):
    f.seed()
    production = f.event('worker-slot-wait', queue_class='production', queue_order=2, blocked_by=[])
    production.update(work='slot-wait')
    f.record('event', production)
    consultation = dict(actor='parent', event='worker-slot-wait', worker='parent', assignment=None,
        execution='running', work='slot-wait', ref=str(f.operation_ref), planned_id='b',
        request_ref=str(f.request_ref), queue_class='consultation', queue_order=1, blocked_by=['a'])
    f.record('event', consultation)
    result = f.view()
    assert result['current_assignment_ids'] == ['a'] and len(result['assignments']) == 1
    queued = sorted(result['last_recorded'].values(), key=lambda e: e['queue_order'])
    assert [(e['queue_class'], e['queue_order'], e['assignment']) for e in queued] == [
        ('consultation', 1, None), ('production', 2, 'a')]
    assert queued[0]['blocked_by'] == ['a'] and queued[0]['planned_id'] == 'b'
    assert f.prepare(f.request('resume'))['target'] == 'fixture-address-a'


def test_collect(f):
    f.assign()
    prepared = json.loads(f.prepare_ref.read_text())
    selection = {k: prepared[k] for k in ('usage', 'selection_sources')}
    selection.update(candidate='fixture-code', model='fixture-model', effort='high')
    started = f.event('worker-started', prepare_ref=str(f.prepare_ref), selection=selection)
    started.update(execution='running')
    f.record('event', started)
    f.record('event', f.event('worker-ready', role=role, read_notes=required_notes,
                            prohibitions=['実装本体を編集しない']))
    finished = f.event('worker-finished', report_ref=str(f.report_ref),
                       artifact_refs=[str(f.artifact)], prepare_ref=str(f.prepare_ref))
    saved = f.record('event', finished)
    f.record('report', dict(summary='fixture: result received, approval pending', pending=['parent review'],
        reason='fixture boundary', read_notes=[], written_notes=[], worker_refs=['a']))
    report_bytes = f.report_ref.read_bytes()
    for result in (f.view(), f.view('collect')):
        assert result['version'] == 1 and result['thread_id'] == 'fixture-parent'
        assert {k: result['assignments'][0][k] for k in f.row()} == f.row()
        assert result['report']['worker_refs'] == ['a'] and result['report']['pending'] == ['parent review']
        assert result['last_recorded']['fixture-worker-a'] == saved
        assert saved['execution'] == 'ended' and saved['work'] == 'parent-wait'
        assert Path(saved['report_ref']).read_bytes() == report_bytes
        assert saved['artifact_refs'] == [result['assignments'][0]['artifact']]
        assert Path(saved['artifact_refs'][0]).read_text() == 'fixture artifact\n'
    f.record('event', f.event('worker-done', handoff_ref=str(f.handoff)) | {'work': 'done'})
    history = [json.loads(line) for line in (f.state / 'events.jsonl').read_text().splitlines()]
    assert [e['event'] for e in history] == ['worker-started', 'worker-ready', 'worker-finished', 'worker-done']
    assert history[0]['selection'] == selection
    assert history[0]['version'] == 1 and history[0]['run'] == '1' and history[0]['recorded_at']
    assert f.view()['assignments'][0]['selection_ref'] == str(f.state / 'events.jsonl')


def test_started_selection(f):
    f.seed()
    stale_usage = json.loads(f.prepare_ref.read_text())['usage']
    f.usage(h5=63, d7=52)
    prepared = f.prepare(f.request('resume'))
    write_json(f.prepare_ref, prepared)
    selection = {key: prepared['assignment'][key] for key in ('candidate', 'model', 'effort')}
    selection.update({key: prepared[key] for key in ('usage', 'selection_sources')})
    # 再開時の転記違いを各項目で拒否し、履歴・最終形を更新しない。
    for key, stale in (('usage', stale_usage), ('selection_sources', [str(f.work / 'old-models.conf')])):
        before = snapshot(f.state)
        started = f.event('worker-started', prepare_ref=str(f.prepare_ref),
                          selection=dict(selection, **{key: stale}))
        started.update(execution='running')
        f.record('event', started, code=1)
        assert snapshot(f.state) == before, key
    started['selection'] = selection
    assert f.record('event', started)['selection'] == selection


def test_missing_result(f, kind):
    f.assign()
    (f.report_ref if kind == 'report' else f.artifact).unlink()
    before = snapshot(f.state)
    f.record('event', f.event('worker-finished', report_ref=str(f.report_ref),
        artifact_refs=[str(f.artifact)], prepare_ref=str(f.prepare_ref)), code=1)
    assert snapshot(f.state) == before


def test_legacy(f):
    f.assign()
    # 追加項目なしの段階1 event/report もそのまま回収できる。
    event = f.event('finished')
    del event['assignment']
    f.record('event', event)
    f.record('report', dict(summary='legacy summary', pending=[], reason='boundary',
                            read_notes=[], written_notes=[]))
    result = f.view('collect')
    assert result['report']['summary'] == 'legacy summary'
    assert result['report'].get('worker_refs', []) == []
    assert result['last_recorded']['fixture-worker-a']['event'] == 'finished'


def test_definitions(f):
    source = repo / 'team/rules/codex-agents'
    definitions = list(source.glob('*.toml'))
    assert {p.stem for p in definitions} == {p.stem for p in (repo / 'team/rules/agents').glob('*.md')}
    assert definitions, 'Codex role definitions are missing'
    for path in definitions:
        value = tomllib.loads(path.read_text())
        assert set(value) == {'name', 'description', 'developer_instructions'}, path.name
        assert value['name'] == path.stem and value['description'].strip(), path.name
        body = value['developer_instructions']
        for name in ('absolute-rules.md', 'core-worker.md', 'worker-role-' + path.stem + '.md'):
            assert name in body, (path.name, name)
        assert '~/Data/obsidian/Preferences/' in body and '全文' in body, path.name
        assert '##' not in body and not re.search(r'(?m)^\s*(model|effort|reasoning_effort)\s*=', body)


def test_install(f):
    # team/coreだけを選び、run配置・dotfiles・外部通知へ進まない。
    destination = f.codex_agents / (role + '.toml')
    destination.write_text('fixture existing personal file\n')
    log = f.install('--select', 'team,core')
    source = repo / 'team/rules/codex-agents' / destination.name
    assert destination.is_symlink() and destination.resolve() == source.resolve()
    assert destination.with_name(destination.name + '.pre-aienv.bak').read_text() == 'fixture existing personal file\n'
    assert 'codex' in log.lower() and role in log
    for path in (repo / 'team/rules/agents').glob('*.md'):
        assert (f.agents / path.name).resolve() == path.resolve(), path.name
    dangling = f.codex_agents / 'fixture-retired.toml'
    dangling.symlink_to(repo / 'team/rules/codex-agents/fixture-retired.toml')
    log = f.install('--select', 'team,core', code=1)
    assert dangling.is_symlink() and not dangling.exists()
    assert 'codex' in log.lower() and 'fixture-retired' in log


def test_install_dry(f):
    before = snapshot(f.home)
    log = f.install('--select', 'team,core', '--dry-run')
    assert snapshot(f.home) == before
    assert str(f.codex_agents / (role + '.toml')) in log


def test_install_without_team(f):
    for path in f.codex_agents.iterdir():
        path.unlink()
    f.install('--select', 'core')
    assert not list(f.codex_agents.glob('*.toml'))


def test_sub_placement(f):
    for path in f.codex_agents.iterdir():
        path.unlink()
    f.profile.write_text(f.profile.read_text().replace('value=main', 'value=sub'))
    f.install('--select', 'team,core', '--sub-delegate')
    assert not list(f.codex_agents.glob('*.toml')), 'sub installation deployed Codex agents'
    for extra in ([], ['--all']):
        result = subprocess.run(['bash', str(repo / 'core/assembly/ledger-tool.sh'), 'placement', *extra],
                                env=f.env, capture_output=True, text=True, check=True, timeout=20)
        rows = [line.split('\t') for line in result.stdout.splitlines()]
        assert not any('/codex-agents/' in row[2] for row in rows), extra
        assert any('/.claude/agents/' in row[1] for row in rows), extra
    drift = subprocess.run(['bash', str(repo / 'core/assembly/check-drift.sh'), '--managed-symlinks-only'],
                           env=f.env, capture_output=True, text=True, timeout=20)
    assert drift.returncode == 0, drift.stdout + drift.stderr
    assert 'drift: 0件' in drift.stdout


cases = [
    ('fixture: 模擬候補・枠・版1記録は既存CLIで利用できる', test_fixture),
    ('A13/§2: 候補JSONの解決値・枠と従来TSVの互換', test_candidates),
    ('§2: 候補なし・解決異常もJSONと理由を返して終了0', test_unresolved),
    ('A13: 初回は職種・指定値・必読参照を供給し読了確認だけを準備', test_new),
    ('A7a: 同じ宛先・選択値を保持し枠を再照会、必要時は読了再確認', test_resume),
    ('A13: 過去の読了記録がなければ再開も確認だけ', test_missing_reading),
    ('A7a: 定義変更で保存値を上書きせず再開保留', test_definition_change),
    ('A7b/A6: 同職種への交代、引継ぎ・旧担当・現担当を保持', test_replace),
    ('A6/A7a: 相談優先の待ち順と未起動行なし、同じ宛先への復帰', test_queue),
    ('A6/結果回収: 選択履歴・全文報告・成果・親の未承認をstatus/collectへ', test_collect),
    ('§4: 再開時の枠・設定参照の転記不一致を拒否し、準備結果の一致だけを記録', test_started_selection),
    ('互換: 段階1の追加項目なし入力を回収', test_legacy),
    ('A13: 既存職種と同じ参照TOML・3キー、モデル固定なし', test_definitions),
    ('A13: main/team配置・既存ファイル退避・Claude配置維持・Codexリンク切れ報告', test_install),
    ('A13: dry-runはCodex配置計画だけを示しHOMEを変えない', test_install_dry),
    ('A13: team未選択ではCodex職種を配置しない', test_install_without_team),
    ('A13: subの配置・全機能導出・drift検査はCodex職種を同じ条件で除外', test_sub_placement),
    ('§4: 未登録workerと担当表の不一致は記録しない', test_event_binding),
]
# 行数・空入力の網羅はせず、契約で保留が必要な振る舞いを各1件。
for mode, h5, d7, reason in (
    ('new', 25, 70, 'stop-point'), ('resume', None, None, 'usage-unavailable'),
    ('replace', 0, 0, 'quota-exhausted')):
    cases.append((f'A7a/A7b: {mode}/{reason}は保留・操作なし',
                  lambda f, m=mode, h=h5, d=d7, r=reason: test_deferred(f, m, h, d, r)))
for execution, reason in (('running', 'already-running'), ('unknown', 'execution-unconfirmed')):
    cases.append((f'A7a/A7b: 旧実行{execution}なら再開も交代も保留',
                  lambda f, e=execution, r=reason: test_execution(f, e, r)))
for source in ('project', 'home', 'missing', 'invalid-project'):
    cases.append((f'ROLE-SOURCE: {source} の職種定義で準備・採用元記録、両方なければ拒否',
                  lambda f, s=source: test_role_definition_source(f, s)))
for kind in ('reference', 'route', 'unresolved', 'resume-selection', 'replace-reason'):
    cases.append((f'§3/§7: 不正な準備 {kind} は指定エラー・記録不変',
                  lambda f, k=kind: test_invalid_prepare(f, k)))
for kind in ('notes', 'role', 'prohibitions'):
    cases.append((f'A13: 読了確認の不足 {kind} を拒否しtaskへ進めない',
                  lambda f, k=kind: test_reading_rejected(f, k)))
for kind in ('report', 'artifact'):
    cases.append((f'結果回収: 保存先の{kind}欠落は終了結果に記録しない',
                  lambda f, k=kind: test_missing_result(f, k)))

with tempfile.TemporaryDirectory(prefix='project-workers-acceptance-') as temporary:
    for index, (label, test) in enumerate(cases):
        try:
            fixture = Fixture(Path(temporary) / str(index))
            try:
                test(fixture)
            finally:
                assert not (fixture.root / 'external-calls').exists(), 'external service/tool was invoked'
        except (AssertionError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
            failed += 1
            print(f'  NG - {label}: {error}')
        else:
            passed += 1
            print(f'  ok - {label}')
print(f'=== summary: {passed} passed, {failed} failed ===')
sys.exit(1 if failed else 0)
PY
