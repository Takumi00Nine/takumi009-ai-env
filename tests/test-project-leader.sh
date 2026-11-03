#!/usr/bin/env bash
# 管理CLIの内部不変条件。HOME・必読・宣言・通知・Codexをすべてfixtureへ隔離する。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
cli = repo / 'team/connect/codex/project-leader.py'
passed = 0

with tempfile.TemporaryDirectory(prefix='project-leader-test-') as temporary:
    root = Path(temporary)
    home, binary, prefs = root / 'home', root / 'bin', root / 'prefs'
    project, state = root / 'project', root / 'project/output/team'
    for directory in (home, binary, prefs, project / 'docs', project / 'work', project / 'output'):
        directory.mkdir(parents=True, exist_ok=True)
    note = root / 'vault/Projects/example.md'
    note.parent.mkdir(parents=True)
    note.write_text('## 目的\nfixture\n## Tasks\n')
    notes = 'absolute-rules core-conduct core-workflow coding-delegation worker-role-prompts vault-operation codex-exec-worker session-handoff project-tasks-format cmux-notifications'.split()
    for name in notes:
        (prefs / (name + '.md')).write_text('fixture ' + name)
    (binary / 'cmux').write_text('''#!/bin/sh
if [ "$1" = read-screen ]; then exit 0; fi
if [ "$1" = notify ]; then printf '%s\\n' "$*" >> "$HOME/notices"; exit 0; fi
exit 9
''')
    (binary / 'osascript').write_text('#!/bin/sh\nexit 0\n')
    (binary / 'launchctl').write_text('#!/bin/sh\nexit 0\n')
    (binary / 'codex').write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['LEADER_TEST_ROOT'])
prompt = sys.stdin.read()
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps({'argv':sys.argv[1:], 'prompt':prompt,
        'worker':os.environ.get('AIENV_CODEX_WORKER'),
        'leader':os.environ.get('AIENV_CODEX_PROJECT_LEADER')}) + '\\n')
print(json.dumps({'type':'thread.started', 'thread_id':'fixture-thread'}), flush=True)
while (root / 'wait').exists():
    time.sleep(.05)
state = pathlib.Path(os.environ['LEADER_TEST_STATE'])
command = [sys.executable, os.environ['LEADER_TEST_CLI']]
report = root / 'report.json'
report.write_text(json.dumps({'summary':'fixture summary','pending':['approval'],
    'reason':'fixture boundary','read_notes':['fixture'],'written_notes':[]}))
subprocess.run(command + ['report','--state-dir',str(state),'--file',str(report)], check=True, stdout=subprocess.DEVNULL)
if (root / 'recover-ok').exists():
    event = root / 'recovered.json'
    event.write_text(json.dumps({'actor':'parent','worker':'parent','event':'recovery-complete',
        'execution':'ended','work':'stopped','ref':'fixture-stop-and-diff-check'}))
    subprocess.run(command + ['event','--state-dir',str(state),'--file',str(event)], check=True, stdout=subprocess.DEVNULL)
pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_text('fixture final report')
sys.exit(3 if (root / 'error').exists() else 0)
''')
    for path in binary.iterdir():
        path.chmod(0o755)
    declaration = root / 'declarations.json'
    declaration.write_text(json.dumps({'version':1,'workspaces':{'fixture-workspace':'example'}}))
    env = dict(os.environ, HOME=str(home), PATH=str(binary) + os.pathsep + os.environ['PATH'],
               AIENV_PREFERENCES_DIR=str(prefs), CMUX_TASK_STATE=str(declaration),
               CMUX_TASK_CMUX_BIN=str(binary / 'cmux'), AIENV_NOTIFY_WAIT_SECS='1',
               LEADER_TEST_ROOT=str(root), LEADER_TEST_STATE=str(state), LEADER_TEST_CLI=str(cli))
    # Never inherit selected components, a real ledger, or a real notification log.
    for key in ('AIENV_LEDGER','AIENV_COMPONENTS_FILE','AIENV_NOTIFY_LOG','CMUX_SOCKET_PATH',
                'CMUX_BUNDLED_CLI_PATH','CMUX_WORKSPACE_ID','CMUX_SURFACE_ID'):
        env.pop(key, None)

    def invoke(command, *args, ok=True):
        result = subprocess.run([sys.executable,str(cli),command,'--state-dir',str(state),*map(str,args)],
                                env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == ok, result.stderr
        return json.loads(result.stdout) if ok else result

    def check(label):
        global passed
        passed += 1
        print('ok - ' + label)

    def settle():
        # Bounded waits on fixture processes only; the production manager never polls workers.
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            result = invoke('status')
            if result['status'] != 'running':
                return result
            time.sleep(.1)
        raise AssertionError('fixture execution did not finish')

    def data(command, value):
        path = root / (command + '.json')
        path.write_text(json.dumps(value))
        return invoke(command, '--file', path)

    parent_env = dict(env, AIENV_CODEX_WORKER='0', AIENV_CODEX_PROJECT_LEADER='1')
    hook = subprocess.run(['bash', str(repo / 'team/connect/codex/session-start-read.sh')],
                          env=parent_env, capture_output=True, text=True, check=True)
    context = json.loads(hook.stdout)['hookSpecificOutput']['additionalContext']
    assert '親の必読' in context and '外部脳ヘルス' not in context and '不足' not in context
    worker_hook = subprocess.run(['bash', str(repo / 'team/connect/codex/session-start-read.sh')],
                                 env=dict(parent_env, AIENV_CODEX_WORKER='1'),
                                 capture_output=True, text=True, check=True)
    assert json.loads(worker_hook.stdout)['hookSpecificOutput']['additionalContext'] == ''
    check('parent SessionStart does not run the Mac leader bootstrap')

    usage, prompt = root / 'usage.md', root / 'request.md'
    usage.write_text('fixture usage checked; above stop point')
    prompt.write_text('fixture request')
    init_args = ['--project','example','--project-dir',project,'--cwd',project,'--note',note,
                 '--goal','fixture goal','--source','fixture input reference','--workspace','fixture-workspace',
                 '--surface','fixture-surface','--candidate','fixture-candidate','--model','fixture-model',
                 '--effort','high','--selection-ref',usage,'--sandbox','read-only']
    # Registration cannot bypass the existing note/declaration prerequisites.
    note.unlink()
    invoke('init', *init_args, ok=False)
    assert not state.exists()
    note.write_text('## Tasks\n')
    invoke('init', *init_args)
    assert invoke('status')['status'] == 'not-started'
    check('registration preserves the note-before-parent boundary')

    assignment = dict(id='a1',stage='implementation',scope='fixture scope',artifact='fixture artifact',
                      role='implementer',worker='fixture-worker',address='fixture-address',parent_thread='fixture-thread',
                      candidate='fixture-candidate',model='fixture-model',effort='high',selection_ref='fixture usage')
    data('assign', assignment)
    data('assign', dict(assignment,id='a2',worker='replacement-worker',replaces='a1',handoff_ref='fixture-handoff'))
    event = dict(actor='parent',worker='fixture-worker',event='consult',execution='ended',
                 work='consultation-wait',peer='replacement-worker',ref='fixture consultation')
    data('event', event)
    rows = list(csv.DictReader((state / 'assignments.tsv').open(),delimiter='\t'))
    assert len(rows) == 2 and rows[1]['replaces'] == 'a1'
    assert invoke('status')['current_assignment_ids'] == ['a2']
    assert json.loads((state / 'latest.json').read_text())['workers']['fixture-worker']['work'] == 'consultation-wait'
    assert json.loads((state / 'events.jsonl').read_text())['execution'] == 'ended'
    check('assignment history and explicit execution/work states stay distinct')

    try:
        (root / 'wait').touch()
        invoke('start','--prompt-file',prompt,'--usage-ref',usage)
        assert invoke('status')['status'] == 'running'
        invoke('resume','--prompt-file',prompt,'--usage-ref',usage,ok=False)
        invoke('collect',ok=False)
    finally:
        (root / 'wait').unlink(missing_ok=True)
    result = settle()
    assert result['status'] == 'finished' and result['exit'] == 0
    assert invoke('collect')['final_report'] == 'fixture final report'
    call = json.loads((root / 'calls.jsonl').read_text().splitlines()[0])
    assert call['worker'] == '0' and call['leader'] == '1'
    assert all(str(prefs / (name + '.md')) in call['prompt'] for name in notes)
    assert 'core-worker.md' not in call['prompt'] and 'worker-role-implementer.md' not in call['prompt']
    assert '本人承認前' in call['prompt']
    assert '📣 example' in (home / 'notices').read_text()
    check('detached run refuses a duplicate and collects EXIT plus report after notification')

    # A changed display only changes the mapping, never starts another Codex process.
    before = (root / 'calls.jsonl').read_text()
    invoke('display','--workspace','fixture-workspace','--surface','replacement-surface')
    output = subprocess.run([sys.executable,str(cli),'view','--state-dir',str(state)],env=env,capture_output=True,text=True)
    assert 'fixture final report' in output.stdout and output.returncode == 0
    assert (root / 'calls.jsonl').read_text() == before
    invoke('resume','--prompt-file',prompt,'--usage-ref',usage)
    assert settle()['status'] == 'finished'
    call = json.loads((root / 'calls.jsonl').read_text().splitlines()[-1])
    assert call['argv'][-4:] == ['resume','--','fixture-thread','-']
    assert call['argv'][call['argv'].index('-m')+1] == 'fixture-model'
    assert 'model_reasoning_effort=high' in call['argv']
    check('display restoration is read-only; resume keeps the saved thread and model')

    # Nonzero exit, then one failed recovery: no normal resume or second recovery.
    (root / 'error').touch()
    invoke('resume','--prompt-file',prompt,'--usage-ref',usage)
    result = settle()
    assert result['status'] == 'unconfirmed' and result['worker_records_status'] == 'unconfirmed'
    assert result['last_recorded']['fixture-worker']['work'] == 'consultation-wait'
    invoke('resume','--prompt-file',prompt,'--usage-ref',usage,ok=False)
    invoke('recover','--prompt-file',prompt,'--usage-ref',usage)
    assert settle()['status'] == 'unconfirmed'
    invoke('recover','--prompt-file',prompt,'--usage-ref',usage,ok=False)
    check('failed recovery stays unconfirmed and cannot be retried')

    # Reconstruct an abandoned run without EXIT; no process or child state is invented.
    metadata = json.loads((state / 'project.json').read_text())
    directory = state / 'runs' / metadata['run']
    (directory / 'wrapper.log').write_text('THREAD_ID:fixture-thread\n')
    metadata.update(recovery_attempted=False,recovery_complete=False)
    (state / 'project.json').write_text(json.dumps(metadata))
    (root / 'error').unlink()
    assert invoke('status')['status'] == 'unconfirmed'
    (root / 'recover-ok').touch()
    invoke('recover','--prompt-file',prompt,'--usage-ref',usage)
    assert settle()['status'] == 'finished'
    assert '新しい制作は始めない' in json.loads((root / 'calls.jsonl').read_text().splitlines()[-1])['prompt']
    check('missing EXIT needs explicit recovery completion before collection')

    # Notification failure leaves the saved report collectable on the next turn.
    (root / 'recover-ok').unlink()
    (binary / 'cmux').write_text('#!/bin/sh\n[ "$1" = read-screen ] && exit 0\nexit 1\n')
    no_dest = root / 'no-dest.tsv'
    no_dest.write_text('\n'.join(line for line in (repo / 'core/data/ledger.tsv').read_text().splitlines()
                                 if not (line.startswith('part\t') and '\tnotify\tconnect\t' in line)) + '\n')
    env['AIENV_LEDGER'] = str(no_dest)
    invoke('resume','--prompt-file',prompt,'--usage-ref',usage)
    assert settle()['notification'] == 'unknown'
    assert invoke('collect')['report']['pending'] == ['approval']
    check('notification failure cannot lose the saved decision wait')

    # A PID reused by another process must not make an old execution appear live.
    metadata = json.loads((state / 'project.json').read_text())
    (state / 'runs' / metadata['run'] / 'runner.pid').write_text(f'{os.getpid()}\nobsolete process start\n')
    assert invoke('status')['status'] == 'finished'
    check('retained execution records distinguish a reused PID by its start time')

print(f'PASS={passed} FAIL=0')
PY
