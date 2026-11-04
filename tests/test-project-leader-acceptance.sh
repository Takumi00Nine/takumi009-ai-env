#!/usr/bin/env bash
# 段階1の独立した受入確認。README の版1 CLI/記録契約を使う。
# 体制節と締め済みノートは資料突合用の入力。転記をCLIへ要求しない。
# 実モデルの承認遵守・Vault分担・cmux送達は実環境確認へ。
# 実行: bash tests/test-project-leader-acceptance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
cli = repo / 'team/connect/codex/project-leader.py'
notes = ('absolute-rules core-conduct core-workflow coding-delegation worker-role-prompts '
         'vault-operation codex-exec-worker session-handoff project-tasks-format cmux-notifications').split()
passed = failed = 0


class Fixture:
    def __init__(self, root, slug='example'):
        self.root = root
        self.slug = slug
        self.project = root / 'project'
        self.state = self.project / 'output/team'
        self.vault = root / 'vault'
        self.note = self.vault / 'Projects' / (slug + '.md')
        self.bin = root / 'bin'
        self.prefs = root / 'prefs'
        for path in (self.project / 'docs', self.project / 'work', self.project / 'output',
                     root / 'home', self.bin, self.prefs, self.note.parent):
            path.mkdir(parents=True, exist_ok=True)
        self.note.write_text('## 目的\nfixture goal\n## Tasks\n', encoding='utf-8')
        for name in notes:
            (self.prefs / (name + '.md')).write_text('fixture reference', encoding='utf-8')
        # read-screen is the only cmux operation needed to register a display.
        # The real notify mouth uses this fake cmux; all other destinations are omitted.
        self.executable('cmux', '''#!/bin/sh
if [ "$1" = read-screen ]; then [ ! -e "$ACCEPT_ROOT/no-screen" ]; exit $?; fi
if [ "$1" = notify ]; then printf '%s\\n' "$*" >> "$ACCEPT_ROOT/notices"; exit 0; fi
exit 9
''')
        self.executable('codex', '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['ACCEPT_ROOT'])
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps({'argv':sys.argv[1:], 'prompt':sys.stdin.read()}) + '\\n')
print(json.dumps({'type':'thread.started','thread_id':'fixture-thread'}), flush=True)
subprocess.run([sys.executable, os.environ['ACCEPT_CLI'], 'report', '--state-dir',
    os.environ['ACCEPT_STATE'], '--file', str(root / 'checkpoint.json')],
    check=True, stdout=subprocess.DEVNULL)
pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_text('fixture final response')
''')
        self.declaration = root / 'declarations.json'
        self.declaration.write_text(json.dumps({'version':1, 'workspaces':{'fixture-workspace':slug}}))
        # Use the existing mouth and declaration components, with only a fake destination.
        ledger = root / 'ledger.tsv'
        ledger.write_text('\n'.join(
            line for line in (repo / 'core/data/ledger.tsv').read_text().splitlines()
            if not (line.startswith('part\t') and '\tnotify\tconnect\t' in line
                    and '\tcmux\t' not in line)) + '\n')
        self.env = dict(os.environ, HOME=str(root / 'home'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        AIENV_LEDGER=str(ledger), AIENV_COMPONENTS_FILE=str(root / 'components.env'),
                        AIENV_NOTIFY_LOG=str(root / 'notify.tsv'), AIENV_NOTIFY_WAIT_SECS='1',
                        AIENV_PREFERENCES_DIR=str(self.prefs), CMUX_TASK_STATE=str(self.declaration),
                        CMUX_TASK_CMUX_BIN=str(self.bin / 'cmux'),
                        ACCEPT_ROOT=str(root), ACCEPT_CLI=str(cli), ACCEPT_STATE=str(self.state),
                        PYTHONDONTWRITEBYTECODE='1')
        for key in ('CMUX_SOCKET_PATH', 'CMUX_BUNDLED_CLI_PATH', 'CMUX_WORKSPACE_ID', 'CMUX_SURFACE_ID'):
            self.env.pop(key, None)
        self.usage = root / 'usage.md'
        self.usage.write_text('fixture usage checked above the stop point')
        self.request = root / 'request.md'
        self.request.write_text('fixture request')
        self.checkpoint = dict(summary='fixture summary', pending=[], reason='fixture boundary',
                               read_notes=notes, written_notes=[str(self.note)])

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding='utf-8')
        path.chmod(0o755)

    def run(self, command, *args, ok=True, json_output=True):
        result = subprocess.run([sys.executable, str(cli), command, '--state-dir', str(self.state),
                                 *map(str, args)], env=self.env, capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == ok, f'{command}: exit={result.returncode}: {result.stderr}'
        return json.loads(result.stdout) if ok and json_output else result

    def init(self, ok=True):
        return self.run('init', '--project', self.slug, '--project-dir', self.project,
                        '--cwd', self.project, '--note', self.note, '--goal', 'fixture goal',
                        '--source', 'fixture goal reference', '--workspace', 'fixture-workspace',
                        '--surface', 'fixture-surface', '--candidate', 'fixture-candidate',
                        '--model', 'fixture-model', '--effort', 'high', '--selection-ref', self.usage,
                        '--sandbox', 'danger-full-access', ok=ok)

    def record(self, command, value):
        path = self.root / (command + '.json')
        path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        return self.run(command, '--file', path)

    def assign(self, ident, role, scope, artifact):
        return self.record('assign', dict(id=ident, stage=role, scope=scope, artifact=str(artifact),
            role=role, worker='fixture-' + ident, address='fixture-address-' + ident,
            parent_thread='fixture-thread', candidate='fixture-candidate', model='fixture-model',
            effort='high', selection_ref=str(self.usage)))

    def event(self, ident, ref, event='finished', **extra):
        return self.record('event', dict(actor='parent', worker='fixture-' + ident, event=event,
                           execution='ended', work='done', ref=str(ref), **extra))

    def execute(self, command='start'):
        (self.root / 'checkpoint.json').write_text(json.dumps(self.checkpoint), encoding='utf-8')
        self.run(command, '--prompt-file', self.request, '--usage-ref', self.usage)
        # Only short-lived fake processes are polled, with a bounded wait.
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            status = self.run('status')
            if status['status'] != 'running':
                assert status['status'] == 'finished', status
                return self.run('collect')
            time.sleep(.1)
        raise AssertionError('fixture parent did not finish')

    def retire_raw_files(self):
        shutil.rmtree(self.project / 'work')
        for run in (self.state / 'runs').iterdir():
            # EXIT, run.json, final.md and report.json are retained result records.
            for name in ('prompt.md', 'final.md.events.jsonl', 'final.md.stderr.log', 'runner.log'):
                (run / name).unlink(missing_ok=True)

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]


def test_a6(f):
    # 資料突合の入力: 見込みは甲2人/乙1人。実担当はまだ各1人だけ。
    design = f.project / 'docs/design.md'
    design.write_text('設計本文\n\n## 次の工程の体制\n'
                      '| 対象範囲 | 次の工程 | 必要人数 |\n|---|---|---|\n'
                      '| 甲 | 実装 | 2 |\n| 乙 | 実装 | 1 |\n')
    consultation = f.project / 'docs/design-notes.md'
    consultation.write_text('設計担当と親の相談結論: 甲2人・乙1人を見込む。')
    # 締め済みノートは親の転記結果を表すfixture。CLIに転記はさせない。
    closing = '体制の要点: 甲 / 実装 / 2人、乙 / 実装 / 1人。相談結論: 範囲別に必要人数を採用。\n'
    f.note.write_text(closing + f'担当表: {f.state / "assignments.tsv"}\n状態履歴: {f.state / "events.jsonl"}\n')
    f.init()
    for ident, scope in (('a', '甲'), ('b', '乙')):
        f.assign(ident, 'implementer', scope, design)
        f.event(ident, consultation, event='consult', peer='parent')
    f.checkpoint['summary'] = closing
    f.execute()
    f.retire_raw_files()
    result = f.run('collect')
    assert [(row['scope'], row['worker']) for row in result['assignments']] == [('甲','fixture-a'), ('乙','fixture-b')]
    assert result['current_assignment_ids'] == ['a', 'b']  # 見込み3人を実在人数にしない。
    assert result['report']['summary'] == closing
    assert result['report']['written_notes'] == [str(f.note)]
    assert all(Path(row['artifact']).read_text() == design.read_text() for row in result['assignments'])
    assert all(Path(event['ref']).read_text() == consultation.read_text() for event in result['last_recorded'].values())
    assert closing in Path(result['report']['written_notes'][0]).read_text()
    assert not (f.project / 'work').exists()


def test_a6_supplement(f):
    # テスト作成人数は要件成果、実行人数はoutputの引継ぎ説明末尾にある。
    requirements = f.project / 'docs/requirements.md'
    requirements.write_text('要件本文\n## 次の工程の体制\n'
                            '| 対象範囲 | 次の工程 | 必要人数 |\n|---|---|---|\n| 甲 | テスト作成 | 2 |\n')
    handoff = f.project / 'output/test-handoff.md'
    handoff.write_text('テスト成果の引き継ぎ\n## 次の工程の体制\n'
                       '| 対象範囲 | 次の工程 | 必要人数 |\n|---|---|---|\n| 甲 | テスト実行 | 1 |\n')
    conclusion = f.project / 'docs/requirements-notes.md'
    conclusion.write_text('要件担当と親: 作成2人。テスト作成担当と親: 実行1人。')
    f.init()
    f.assign('tests', 'test-writer', '甲', handoff)
    first = f.event('tests', conclusion)
    f.assign('implementation', 'implementer', '甲', requirements)
    second = f.event('implementation', requirements)
    closing = '甲 / テスト作成 / 2人、甲 / テスト実行 / 1人。相談結論: 作成と実行の見込みを別に採用。'
    f.note.write_text(closing + f'\n担当表: {f.state / "assignments.tsv"}\n状態記録: {f.state / "latest.json"}\n')
    f.checkpoint['summary'] = closing
    f.execute()
    # 受入テストの退役後にも体制の要点を回収できる入力例。
    handoff.unlink()
    f.retire_raw_files()
    result = f.run('collect')
    assert [(row['role'], row['artifact']) for row in result['assignments']] == [
        ('test-writer', str(handoff)), ('implementer', str(requirements))]
    history = [json.loads(line) for line in (f.state / 'events.jsonl').read_text().splitlines()]
    assert history == [first, second]
    assert first['recorded_at'] <= second['recorded_at']
    assert result['report']['summary'] == closing
    assert closing in Path(result['report']['written_notes'][0]).read_text()
    assert result['last_recorded']['fixture-tests']['ref'] == str(conclusion)
    assert not handoff.exists() and not (f.project / 'work').exists()


def test_a10(f):
    f.init()
    decisions = f.project / 'docs/design-notes.md'
    decisions.write_text('有効: 案甲、理由: 要件に適合。撤回: 案乙。成果: 試験用成果。未決: 受入。次: 確認を取り次ぐ。')
    f.assign('a', 'implementer', '甲', decisions)
    f.event('a', decisions)
    f.checkpoint.update(summary=decisions.read_text(), pending=['受入判断'])
    f.note.write_text(f'正本: {decisions}\n担当表: {f.state / "assignments.tsv"}\n状態: {f.state / "latest.json"}\n')
    before = f.execute()
    records = {name:(f.state / name).read_bytes() for name in ('assignments.tsv', 'events.jsonl', 'latest.json')}
    f.retire_raw_files()
    after = f.run('collect')
    assert after['thread_id'] == before['thread_id'] == 'fixture-thread'
    assert after['assignments'] == before['assignments'] and after['last_recorded'] == before['last_recorded']
    assert after['report'] == before['report'] and after['exit'] == 0
    view = f.run('view', json_output=False)
    assert 'fixture-thread' in view.stdout and decisions.read_text() in view.stdout
    # 原依頼・Codexイベントを失っても保存会話で同じ親を再開できる。
    f.request.write_text('保存資料を読み、撤回した案乙を採用せず受入判断を取り次ぐ。')
    resumed = f.execute('resume')
    assert resumed['thread_id'] == 'fixture-thread'
    assert f.calls()[-1]['argv'][-4:] == ['resume', '--', 'fixture-thread', '-']
    assert all((f.state / name).read_bytes() == data for name, data in records.items())
    assert str(f.project / 'work') not in f.note.read_text()


def test_a12(f):
    other = Fixture(f.root / 'other', 'example-b')
    projects = (f, other)
    snapshots = []
    for index, project in enumerate(projects):
        fragments = project.vault / 'Fragments/day.md'
        fragments.parent.mkdir()
        # 既存部分を残して親が追記した後の資料を、報告の照合入力にする。
        fragments.write_text('既存のメモ\n\n案件の追記fixture\n')
        project.checkpoint.update(summary=f'案件{index}の結論', pending=[f'判断{index}'],
                                  written_notes=[str(project.note), str(fragments)])
        snapshots.append({path:path.read_bytes() for path in project.vault.rglob('*.md')})
        project.init()
        project.execute()
    for index, project in enumerate(projects):
        status = project.run('status')  # 次のターンで案件ごとに回収する。
        collected = project.run('collect')
        assert status['report']['summary'] == f'案件{index}の結論'
        assert collected['report']['pending'] == [f'判断{index}']
        assert collected['report']['written_notes'] == project.checkpoint['written_notes']
        assert all(path.read_bytes() == data for path, data in snapshots[index].items())
        assert '📣 ' + project.slug in (project.root / 'notices').read_text()


def test_a15_prerequisites(f):
    # ノート拒否は既存スイート。ここでは未宣言と消えた画面の経路を確認。
    f.declaration.write_text('{"version":1,"workspaces":{}}')
    f.init(ok=False)
    assert not f.state.exists() and not (f.root / 'calls.jsonl').exists()
    f.declaration.write_text(json.dumps({'version':1, 'workspaces':{'fixture-workspace':f.slug}}))
    (f.root / 'no-screen').touch()
    f.init(ok=False)
    assert not f.state.exists() and not (f.root / 'calls.jsonl').exists()


def test_a15_reply(f):
    f.init()
    f.checkpoint.update(summary='作業一覧・見積り・停止点・体制の提案fixture', pending=['本人承認'])
    proposal = f.execute()
    assert proposal['report']['pending'] == ['本人承認']
    assert '本人承認前' in f.calls()[0]['prompt']
    reply = 'fixture承認回答: 提案された一覧を承認。理由: 目的と範囲が一致。参照: fixture-approval。'
    f.request.write_text(reply)
    f.checkpoint.update(summary='承認回答を受領したfixture', pending=[])
    result = f.execute('resume')
    call = f.calls()[-1]
    assert call['prompt'].endswith(reply)
    assert call['argv'][-4:] == ['resume', '--', proposal['thread_id'], '-']
    assert result['thread_id'] == proposal['thread_id']
    assert str(f.note) in call['prompt'] and 'fixture goal reference' in call['prompt']


def test_team_mode_prompt(f):
    # MODE-TEAM/受入: マシンの既定がlean・初回ノートが準備中でも依頼文で体制を伝える。
    profile = f.root / 'profile.md'
    profile.write_text('---\nschema_version: 8\nprofile_slug: fixture\n'
        'team_mode: configured value=lean\nno_read_paths: unavailable\n'
        'machine_role: configured value=main\nrole.leader: configured model=fixture-leader\n---\n')
    models = f.root / 'models.conf'
    models.write_text('[fixture-leader]\nprovider=anthropic-api\nmodel=claude-sonnet-5-5\neffort=high\n')
    f.env.update(AIENV_LOCAL_PROFILE_PATH=str(profile), AIENV_MODEL_DEFS_FILE=str(models))
    resolved = subprocess.run([sys.executable, str(repo / 'team/executor/profile_resolve.py'),
        'resolve', str(profile)], env=f.env, capture_output=True, text=True, timeout=15)
    assert resolved.returncode == 0 and 'TEAM_MODE:lean' in resolved.stdout, resolved.stderr
    f.note.write_text('## 目的\nfixture goal\n## 正本の所在\n- 状態記録: 準備中 [state](<'
        + os.path.relpath(f.state, f.note.parent) + '/>)\n## Tasks\n')
    before_profile, before_note = profile.read_bytes(), f.note.read_bytes()
    f.init()
    f.execute()  # 既存fixtureのCodexだけが起動し、受け取った依頼文を保存する。
    assert 'チームモード' in f.calls()[0]['prompt'], f.calls()[0]['prompt']
    assert profile.read_bytes() == before_profile and f.note.read_bytes() == before_note
    assert 'team_mode' not in json.loads((f.state / 'project.json').read_text())


cases = [
    ('MODE-TEAM: lean配役表と準備中ノートでも起動依頼文にチームモード', test_team_mode_prompt),
    ('A6: 体制見込みと実担当を分け、締め後も資料と記録を突合できる', test_a6),
    ('A6補足: 作成/実行の体制と担当・順序を残し、退役後はノートの要点を参照できる', test_a6_supplement),
    ('A10: 締め・生ログ整理後も記録を回収し、保存会話で継続できる', test_a10),
    ('A12: 複数案件の判断待ちと書いたノート一覧を回収し、CLIはVaultを変更しない', test_a12),
    ('A15: 宣言・画面が欠けた案件は親を起動しない', test_a15_prerequisites),
    ('A15: 承認回答と理由を同じ親へ渡す', test_a15_reply),
]
with tempfile.TemporaryDirectory(prefix='project-leader-acceptance-') as temporary:
    for index, (label, test) in enumerate(cases):
        try:
            test(Fixture(Path(temporary) / str(index)))
        except (AssertionError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
            failed += 1
            print(f'  NG - {label}: {error}')
        else:
            passed += 1
            print(f'  ok - {label}')
print(f'=== summary: {passed} passed, {failed} failed ===')
sys.exit(1 if failed else 0)
PY
