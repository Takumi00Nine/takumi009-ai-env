#!/usr/bin/env bash
# 段階2・3の外部契約。実装本体をimportせずCLIで確認する。
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


def stage3_setup(f, ready=True):
    # 段階1・2だけで担当表を用意し、追加機能の成功をfixtureの前提にしない。
    f.workflow = write_json(f.root / 'workflow.json', dict(version=1, consultation_round_limit=3))
    f.env['AIENV_TEAM_WORKFLOW_CONFIG'] = str(f.workflow)
    f.seed(ready=ready)
    for ident in ('b', 'c'):
        row = f.row(ident)
        row['scope'] = 'separate fixture scope ' + ident
        f.record('assign', row)


def stage3_event(f, name, ident='a', **fields):
    value = f.event(name)
    value.update(assignment=None if ident == 'parent' else ident,
                 worker='parent' if ident == 'parent' else 'fixture-worker-' + ident)
    value.update(fields)
    saved = f.record('event', value)
    assert all(saved[key] == item for key, item in value.items()), saved
    return saved


def stage3_consult(f, **fields):
    value = dict(peer='fixture-worker-b', topic='topic-a', subject='fixture question',
        scope_ref=str(f.request_ref), participants=['a', 'b'], phase='open', exchanges=[],
        receipt=None, dependencies=[], outcome=None, next_action='await substantive reply',
        work='consultation-wait')
    value.update(fields)
    return stage3_event(f, 'consult', **value)


def stage3_request_stop(f, change='change-a', targets=('a', 'c')):
    return stage3_event(f, 'stop-request', 'b', change=change, topic='topic-a', owner='b',
        targets=list(targets), scope_ref=str(f.request_ref), reason='fixture upstream change',
        sent_refs=[dict(assignment=ident, ref=str(f.operation_ref)) for ident in targets],
        next_action='await stop confirmations', work='stop-requested')


def stage3_confirm(f, ident='a', change='change-a', incomplete=False):
    return stage3_event(f, 'stop-confirm', ident, change=change, targets=[ident],
        position='fixture file boundary', touched_refs=[str(f.artifact)], incomplete=incomplete,
        execution_ref=str(f.operation_ref), execution='ended', work='stopped')


def stage3_permit(f, change='change-a', targets=('a', 'c')):
    permission = write_json(f.work / (change + '-permission.json'), {'fixture': 'permission'})
    return stage3_event(f, 'resume-permitted', 'parent', change=change, targets=list(targets),
        ref=str(permission), premises_ref=str(f.handoff), scope_ref=str(f.request_ref),
        decision_ref=str(f.stop_ref), recheck_ref=str(f.report_ref))


def stage3_read(f):
    before = snapshot(f.state)
    views = [f.view(command) for command in ('status', 'collect')]
    assert all(value['version'] == 1 for value in views), views
    assert views[0]['coordination'] == views[1]['coordination'], views
    assert snapshot(f.state) == before, 'coordination read changed state records'
    return views[0]['coordination']


def test_stage3_legacy_and_settings(f):
    # A6補足/A10/A12・§3/4: 旧記録・既存列を保ち、共通設定を参照する。
    stage3_setup(f)
    value = stage3_read(f)
    assert value['status'] == 'recorded', value
    assert value['settings'] == dict(ref=str(f.workflow), consultation_round_limit=3), value
    assert value['topics'] == value['changes'] == value['reviews'] == [], value
    assert list(csv.DictReader((f.state / 'assignments.tsv').open(), delimiter='\t').fieldnames) == columns
    # 差し替えを外した場合も、既定値は台帳が指す1か所から来る。
    del f.env['AIENV_TEAM_WORKFLOW_CONFIG']
    result = subprocess.run(['bash', str(repo / 'core/assembly/ledger-tool.sh'),
        'lookup', 'team.workflow-settings'], env=f.env, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    settings_path = Path(result.stdout.strip())
    assert json.loads(settings_path.read_text()) == dict(version=1, consultation_round_limit=3)
    assert stage3_read(f)['settings'] == dict(ref=str(settings_path), consultation_round_limit=3)


def test_stage3_consultation(f):
    # A1/A3/A5・§4: 実在する別範囲の相手を除外せず、受領・訂正・待ちを往復にしない。
    stage3_setup(f)
    consult = stage3_consult(f)
    topic = stage3_read(f)['topics'][0]
    assert topic['receipt'] is None and topic['rounds'] == 0, topic
    for kind in ('answering', 'redirect', 'dependency-wait'):
        if kind == 'dependency-wait':
            stage3_consult(f, topic='topic-b', phase='waiting', dependencies=['topic-a'])
        consult.update(receipt=dict(assignment='b', kind=kind, ref=str(f.operation_ref)),
                       phase='waiting', dependencies=['topic-b'] if kind == 'dependency-wait' else [],
                       next_action='resend same topic to assignment c' if kind == 'redirect' else 'await reply')
        f.record('event', consult)
        topic = next(t for t in stage3_read(f)['topics'] if t['topic'] == 'topic-a')
        assert topic['receipt']['kind'] == kind and topic['rounds'] == 0, topic
        assert topic['dependencies'] == consult['dependencies'] and topic['outcome'] is None, topic
    pairs = [dict(proposal_id='m' + str(i), reply_id='m' + str(i+1),
                  proposal_summary='fixture proposal', reply_summary='fixture counterproposal')
             for i in range(1, 4)]
    consult.update(subject='renamed fixture question', peer='fixture-worker-c', participants=['a', 'c'],
                   receipt=None, exchanges=pairs, phase='parent-wait', dependencies=[],
                   next_action='parent decides disagreement and stopped scope')
    f.record('event', consult)
    stage3_consult(f, topic='topic-b', phase='waiting', dependencies=['topic-a'])
    topics = {t['topic']: t for t in stage3_read(f)['topics']}
    assert topics['topic-a']['rounds'] == 3 and topics['topic-b']['rounds'] == 0, topics
    assert topics['topic-a']['phase'] == 'parent-wait' and not topics['topic-a']['over_limit'], topics
    assert topics['topic-a']['exchanges'] == pairs and topics['topic-a']['limit'] == 3, topics
    # 設定変更でも既存の組を消さない。違反が起きた事実も隠さない。
    write_json(f.workflow, dict(version=1, consultation_round_limit=2))
    topic = next(t for t in stage3_read(f)['topics'] if t['topic'] == 'topic-a')
    assert (topic['rounds'], topic['limit'], topic['over_limit']) == (3, 2, True), topic
    consult['exchanges'] = pairs + [dict(proposal_id='m4', reply_id='m5',
        proposal_summary='fixture excess proposal', reply_summary='fixture excess reply')]
    f.record('event', consult)
    assert next(t for t in stage3_read(f)['topics'] if t['topic'] == 'topic-a')['rounds'] == 4


def test_stage3_peer_binding(f, kind):
    # A5・§4/8: 範囲の意味は判定しないが、宛先の実在・同じ親の所属は確かめる。
    stage3_setup(f)
    if kind == 'foreign-parent':
        path = f.state / 'assignments.tsv'
        with path.open() as stream:
            rows = list(csv.DictReader(stream, delimiter='\t'))
        next(row for row in rows if row['id'] == 'b')['parent_thread'] = 'fixture-other-parent'
        with path.open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=columns, delimiter='\t')
            writer.writeheader()
            writer.writerows(rows)
    value = dict(f.event('consult'),
        peer='fixture-worker-b' if kind == 'foreign-parent' else 'fixture-absent-worker',
        topic='topic-a', subject='fixture',
        scope_ref=str(f.request_ref), participants=['a', 'b'], phase='open', exchanges=[],
        receipt=None, dependencies=[], outcome=None, next_action='parent checks destination')
    before = snapshot(f.state)
    result = f.record('event', value, code=1)
    assert not result.stdout.strip() and 'project-leader: invalid-coordination:' in result.stderr, result
    assert snapshot(f.state) == before


def test_stage3_decision(f, classification, disposition):
    # A2/A4/A8/A10・§4: 結論・差分・判断者と有効／撤回／保留を保存する。
    stage3_setup(f)
    outcome = dict(classification=classification, conclusion='fixture conclusion', reason='fixture reason',
        disposition=disposition, decision_ref=str(f.stop_ref), diff_refs=[str(f.artifact)],
        next_action='fixture approved action or condition for resumption')
    stage3_consult(f, phase='concluded', outcome=outcome)
    decision = stage3_event(f, 'decision', 'parent', topic='topic-a', classification=classification,
        disposition=disposition, reason=outcome['reason'], decider='user' if classification == 'purpose-policy' else 'parent',
        decision_ref=str(f.stop_ref), diff_refs=outcome['diff_refs'], next_action=outcome['next_action'])
    value = stage3_read(f)
    assert value['topics'][0]['outcome'] == outcome, value
    assert json.loads((f.state / 'events.jsonl').read_text().splitlines()[-1]) == decision


def test_stage3_stop_states(f):
    # A2/A11・§4/5: 送信・受領・実行終了・書きかけ・全停止を混ぜない。
    stage3_setup(f)
    stage3_consult(f)
    stage3_request_stop(f)
    change = stage3_read(f)['changes'][0]
    assert set(change['sent']) == {'a', 'c'} and change['received'] == change['confirmed'] == [], change
    assert set(change['pending_targets']) == {'a', 'c'} and not change['all_stopped'], change
    stage3_event(f, 'stop-received', change='change-a', targets=['a'],
                 received_ref=str(f.operation_ref), work='stop-requested')
    stage3_confirm(f)
    stage3_confirm(f, 'c', incomplete=True)
    change = stage3_read(f)['changes'][0]
    assert change['received'] == change['confirmed'] == ['a'], change
    assert change['pending_targets'] == ['c'] and not change['all_stopped'], change
    # 一旦終了した対象cは受領を偽らず、停止位置と終了の確認だけで停止を確定する。
    stage3_confirm(f, 'c')
    change = stage3_read(f)['changes'][0]
    assert change['all_stopped'] and change['phase'] == 'stopped' and not change['pending_targets'], change
    assert change['received'] == ['a'] and set(change['confirmed']) == {'a', 'c'}, change


def test_stage3_stopped_prepare(f, ready):
    # A11・§5: 全停止や相談終了は再開許可ではない。相談だけの呼び戻しは同じ宛先。
    stage3_setup(f, ready=ready)
    stage3_consult(f)
    stage3_request_stop(f, targets=('a',))
    stage3_confirm(f)
    blocked = f.prepare(f.request('resume'), code=3, reason='resume-not-permitted')
    assert blocked['coordination']['waiting_for_permission'] is True, blocked
    value = f.prepare(f.request('resume', purpose='consultation'))
    assert value['phase'] == ('consultation' if ready else 'read-confirmation'), value
    assert (value['operation'], value['target'], value['model'], value['reasoning_effort']) == (
        'followup', 'fixture-address-a', 'fixture-model', 'high'), value
    assert value['coordination']['topics'] == ['topic-a'] and value['coordination']['changes'] == ['change-a'], value
    assert '停止中・親の再開許可待ち。確認・議論・停止位置の報告だけ。制作・修正を始めない' in value['message']
    assert 'topic-a' in value['message'] and 'change-a' in value['message'], value
    if ready:
        prepared_ref = write_json(f.work / 'consultation-prepared.json', value)
        selection = {key: value[key] for key in ('usage', 'selection_sources')}
        selection.update(candidate='fixture-code', model='fixture-model', effort='high')
        stage3_event(f, 'worker-started', prepare_ref=str(prepared_ref), selection=selection,
                     execution='running', work='consulting')
        stage3_event(f, 'worker-finished', report_ref=str(f.report_ref), artifact_refs=[str(f.artifact)],
                     prepare_ref=str(prepared_ref))
        stage3_confirm(f)
        f.prepare(f.request('resume'), code=3, reason='resume-not-permitted')


def test_stage3_permissions(f):
    # A2/A11・§5: 許可はchange・対象・前提・範囲に限り有効。別の停止を解除しない。
    stage3_setup(f)
    stage3_consult(f)
    for change in ('change-a', 'change-b'):
        stage3_request_stop(f, change, targets=('a',))
        stage3_confirm(f, change=change)
    stage3_permit(f, targets=('a',))
    f.prepare(f.request('resume'), code=3, reason='resume-not-permitted')
    permission = stage3_permit(f, 'change-b', targets=('a',))
    value = f.prepare(f.request('resume'))
    assert not value['coordination']['waiting_for_permission'], value
    stage3_event(f, 'work-resumed', change='change-b', targets=['a'],
                 permission_ref=permission['ref'], position='fixture resumed boundary',
                 execution='running', work='working')
    changes = {c['change']: c for c in stage3_read(f)['changes']}
    assert changes['change-b']['phase'] == 'resumed' and changes['change-b']['resumed'] == ['a'], changes
    assert not changes['change-b']['all_stopped'], changes
    assert changes['change-b']['permissions'] == [dict(targets=['a'], ref=permission['ref'],
        premises_ref=str(f.handoff), scope_ref=str(f.request_ref))], changes


def test_stage3_unconfirmed(f, cause):
    # A3/A11・§8: 共通設定不明や親の異常終了を停止完了・作業許可にしない。
    stage3_setup(f)
    stage3_consult(f)
    if cause == 'settings':
        f.workflow.write_text('{invalid fixture json')
        # 設定不正でも緊急の停止要求・結果の保存は妨げない。
        stage3_request_stop(f, targets=('a',))
    else:
        (f.state / 'runs/1/wrapper.log').write_text('EXIT:1\n')
    value = f.view()['coordination']
    assert value['status'] == 'unconfirmed', value
    if cause == 'settings':
        assert value['reason'] == 'settings-unreadable', value
        assert value['settings']['consultation_round_limit'] is None, value
        assert value['topics'][0]['limit'] is None and value['topics'][0]['over_limit'] is None, value
    f.prepare(f.request('resume', purpose='consultation'), code=3, reason='coordination-unconfirmed')


def test_stage3_review(f, trigger):
    # A9/A12・§6: 要否は親の明示入力。2条件・迷う場合を記録し、回収と採否を分ける。
    stage3_setup(f)
    review = dict(review='review-a', required=True, triggers=[trigger], scope_ref=str(f.request_ref),
        basis_ref=str(f.handoff), request_ref=str(f.request_ref), reason='fixture review needed')
    report = dict(summary='fixture same-family review; additional review pending', pending=['review-a'],
        reason='fixture review boundary', read_notes=[], written_notes=[], claude_review=review)
    f.record('report', report)
    stage3_event(f, 'quality-review', 'parent', **review, state='requested')
    value = stage3_read(f)['reviews'][0]
    assert all(value[key] == item for key, item in review.items()) and value['state'] == 'requested', value
    assert f.view('collect')['report']['claude_review'] == review
    assert 'review-a' in f.view('collect')['report']['pending']
    if trigger == 'release':
        wrapper = write_json(f.work / 'wrapper-result.json', {'result': 'fixture final response'})
        returned = dict(version=1, review='review-a', parent_thread='fixture-parent',
            scope_ref=review['scope_ref'], basis_ref=review['basis_ref'], wrapper_exit=0,
            wrapper_reason='completed', wrapper_out_ref=str(wrapper), verifier_report_ref=str(f.report_ref))
        return_ref = write_json(f.work / 'review-return.json', returned)
        fields = {key: returned[key] for key in ('wrapper_exit', 'wrapper_reason',
                                               'wrapper_out_ref', 'verifier_report_ref')}
        stage3_event(f, 'quality-review', 'parent', **review, **fields, ref=str(return_ref), state='received')
        value = stage3_read(f)['reviews'][0]
        assert value['state'] == 'received' and value['basis_ref'] == returned['basis_ref'], value
        assert all(value[key] == item for key, item in fields.items()), value
        stage3_event(f, 'quality-review', 'parent', **review, **fields, state='adopted',
                     decision_ref=str(f.stop_ref))
        assert stage3_read(f)['reviews'][0]['decision_ref'] == str(f.stop_ref)


def test_stage3_review_missing(f):
    # A9・§6: stdoutや正常終了だけで一覧の全文を回収済みにしない。
    stage3_setup(f)
    wrapper = write_json(f.work / 'wrapper-result.json', {'result': 'fixture report location only'})
    stage3_event(f, 'quality-review', 'parent', review='review-a', required=True, triggers=['release'],
        scope_ref=str(f.request_ref), basis_ref=str(f.handoff), request_ref=str(f.request_ref),
        state='held', wrapper_exit=0, wrapper_reason='report-missing', wrapper_out_ref=str(wrapper),
        verifier_report_ref=None, reason='fixture full findings missing', next_action='retrieve findings before decision')
    value = stage3_read(f)['reviews'][0]
    assert value['state'] == 'held' and value['required'] and value['verifier_report_ref'] is None, value
    assert value['reason'] and value['next_action'], value


def test_candidates(f):
    # §2: resolved values, no automatic choice, and legacy TSV agree.
    data = f.run('--profile', f.profile, '--agents-dir', f.agents,
                 '--role', role, '--format', 'json', script=candidates_cli)
    assert data['version'] == 1 and data['unresolved'] == [], data
    values = data['candidates']
    assert {v['candidate'] for v in values} == {'fixture-code', 'fixture-other', 'fixture-claude'}
    code = next(v for v in values if v['candidate'] == 'fixture-code')
    assert code == dict(role=role, candidate='fixture-code', route='external-cli',
                       model='fixture-model', effort='high', ok='ok', h5=80, d7=70,
                       not_applicable_windows=[])
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


def test_usage_windows(f, scenario):
    # USAGE-WINDOW: 正規の取得口を模擬キャッシュから通し、適用外と取得不能を区別する。
    path = f.cache / 'codex-cache.json'
    cache = json.loads(path.read_text())
    cache['five_hour'] = dict(used_percent=None, resets_at_epoch=None)
    cache['reset_credits'] = dict(available_count=0, reset_scope=['five_hour', 'seven_day'], credits=[])
    cache['seven_day']['used_percent'] = 100 if scenario == 'exhausted' else 29
    if scenario == 'error':
        del cache['fetched_at']
    elif scenario == 'stale':
        cache['fetched_at'] = 1
    write_json(path, cache)
    before = path.read_bytes()
    snapshot_cli = repo / 'usage/executor/usage_snapshot.py'
    snapshot_value = f.run('--json', script=snapshot_cli)
    pool = next(p for p in snapshot_value['pools'] if p['pool_ref'] == 'codex-subscription')
    assert pool['usage_state'] == (scenario if scenario in ('error', 'stale') else 'ok'), pool
    if scenario not in ('error', 'stale'):
        assert [w['window'] for w in pool['windows']] == ['seven_day'], pool
    if scenario in ('error', 'stale'):
        f.prepare(f.request(), code=3, reason='usage-unavailable')
    else:
        value = f.prepare(f.request(), code=3 if scenario == 'exhausted' else 0,
                          reason='quota-exhausted' if scenario == 'exhausted' else None)
        assert value['usage']['h5'] is None, value
        assert value['usage']['d7'] == (0 if scenario == 'exhausted' else 71), value
        assert value['usage']['not_applicable_windows'] == ['five_hour'], value
    assert path.read_bytes() == before, 'worker-prepare rewrote usage cache'


def test_execution(f, execution, reason):
    f.seed(execution=execution)
    f.prepare(f.request('resume'), code=3, reason=reason)
    f.prepare(f.request('replace'), code=3, reason=reason)


def test_replace(f, reason):
    f.seed()
    value = f.prepare(f.request('replace', reason=reason))
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


def test_context_limit_rejected(f, command):
    # R8/A7b: 文脈上限は新しい交代準備・利用不能記録の理由にしない。
    f.seed()
    if command == 'worker-prepare':
        f.prepare(f.request('replace', reason='context-limit'), code=1, reason='invalid-request')
    else:
        before = snapshot(f.state)
        f.record('event', f.event('worker-unavailable', reason='context-limit'), code=1)
        assert snapshot(f.state) == before, 'rejected context-limit event changed state records'


def test_legacy_context_limit(f):
    # R8/A7a: 過去の記録は新規入力の検証口を通さず用意し、読めることを確かめる。
    f.seed()
    old = f.event('worker-unavailable', reason='context-limit')
    old.update(version=1, recorded_at=datetime.now(timezone.utc).isoformat(), run='1')
    with (f.state / 'events.jsonl').open('a') as stream:
        stream.write(json.dumps(old) + '\n')
    write_json(f.state / 'latest.json', {'version': 1, 'workers': {'fixture-worker-a': old}})
    before = snapshot(f.state)
    for command in ('status', 'collect'):
        value = f.view(command)
        assert value['last_recorded']['fixture-worker-a'] == old, value
        assert value['current_assignment_ids'] == ['a'], value
    value = f.prepare(f.request('resume'))
    assert (value['operation'], value['target'], value['phase']) == (
        'followup', 'fixture-address-a', 'task'), value
    assert snapshot(f.state) == before, 'reading legacy context-limit records changed state'


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
    ('STAGE3/A6補足/A10/A12: 旧記録・既存列と共通設定の参照を維持', test_stage3_legacy_and_settings),
    ('STAGE3/A1/A3/A5: 受領・訂正・依存待ちと往復・論点名・上限を区別', test_stage3_consultation),
    ('STAGE3/A2/A11: 複数対象の送信・受領・書きかけ・全停止を区別', test_stage3_stop_states),
    ('STAGE3/A2/A11: 許可は同じchange・対象・前提・範囲にだけ効く', test_stage3_permissions),
    ('STAGE3/A9: 全文結果欠落は正常終了でもheldを保つ', test_stage3_review_missing),
    ('fixture: 模擬候補・枠・版1記録は既存CLIで利用できる', test_fixture),
    ('A13/§2: 候補JSONの解決値・枠と従来TSVの互換', test_candidates),
    ('§2: 候補なし・解決異常もJSONと理由を返して終了0', test_unresolved),
    ('A13: 初回は職種・指定値・必読参照を供給し読了確認だけを準備', test_new),
    ('A7a: 同じ宛先・選択値を保持し枠を再照会、必要時は読了再確認', test_resume),
    ('A13: 過去の読了記録がなければ再開も確認だけ', test_missing_reading),
    ('A7a: 定義変更で保存値を上書きせず再開保留', test_definition_change),
    ('REPLACEMENT/R8/A7a: 過去のcontext-limit記録を読み同じワーカーを再開', test_legacy_context_limit),
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
for kind in ('absent', 'foreign-parent'):
    cases.append((f'STAGE3/A5: {kind} の相手をinvalid-coordinationで拒否・記録不変',
                  lambda f, k=kind: test_stage3_peer_binding(f, k)))
for classification, disposition in (('requirements-scope', 'effective'),
                                    ('purpose-policy', 'withdrawn'), ('unresolved', 'held')):
    cases.append((f'STAGE3/A2/A4/A8/A10: {classification}/{disposition} の結論・判断・差分を保持',
                  lambda f, c=classification, d=disposition: test_stage3_decision(f, c, d)))
for ready in (True, False):
    cases.append((f'STAGE3/A11: 読了確認{ready}で停止中のworkを保留し相談条件を引き継ぐ',
                  lambda f, r=ready: test_stage3_stopped_prepare(f, r)))
for cause in ('settings', 'parent'):
    cases.append((f'STAGE3/A3/A11: {cause} 不明時は停止や許可を推定しない',
                  lambda f, c=cause: test_stage3_unconfirmed(f, c)))
for trigger in ('irreversible-design', 'release', 'uncertain'):
    cases.append((f'STAGE3/A9/A12: {trigger} の追加確認要否・依頼・回収・裁定を記録',
                  lambda f, t=trigger: test_stage3_review(f, t)))
for reason in ('quota-exhausted', 'resume-unavailable'):
    cases.append((f'REPLACEMENT/R8/A7b: {reason} で同職種への交代と引継ぎを保持',
                  lambda f, r=reason: test_replace(f, r)))
for command in ('worker-prepare', 'event'):
    cases.append((f'REPLACEMENT/R8/A7b: {command} は新しいcontext-limit入力を拒否・記録不変',
                  lambda f, c=command: test_context_limit_rejected(f, c)))
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
for scenario in ('ready', 'error', 'stale', 'exhausted'):
    cases.append((f'USAGE-WINDOW: 5h適用外/{scenario} は適用窓と取得状態で判定',
                  lambda f, s=scenario: test_usage_windows(f, s)))
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
