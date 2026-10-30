#!/usr/bin/env bash
# Codex SessionStart 必読5ファイル注入の受入テスト（req-common.md の裁定）。
# 前提: HOME を差し替えると、フックは $HOME/Data/obsidian を読む。
# ワーカー識別は AIENV_CODEX_WORKER=1。実物の5ファイルは使用しない。
# 対象は team/connect/codex/session-start-read.sh を仮定する。
# 別名/Python 実装の場合は AIENV_CODEX_BOOT_READ_HOOK に絶対パスを指定する。
# .py は python3、それ以外は bash で起動する。実装本体はこのテストに含めない。
# codex-exec.sh は PATH 前置の偽 codex で子の環境を観測する。
# BR-01〜12: 6条件それぞれのJSON/内容、BR-13〜15: 登録/既存維持/環境伝播。
# BR-16〜29: コンテキスト上限/登録コマンド実行/本体・Python異常/配置上書き。
# 仕様根拠: https://developers.openai.com/codex/hooks （2026-10-31 確認）
# 実行: bash tests/test-codex-boot-read.sh

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="${AIENV_CODEX_BOOT_READ_HOOK:-$REPO_ROOT/team/connect/codex/session-start-read.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# 一時ファイルは Python の TemporaryDirectory 内だけに作る。
# HOME/worker/cmux の継承で、実環境への依存や通知が発生しないようにする。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# macOS の bash 3.2 では process substitution 内の長い heredoc を避ける。
cat > "$WORK/check.py" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

repo, hook = map(Path, sys.argv[1:])
notes = (
    'Preferences/absolute-rules.md',
    'Preferences/core-conduct.md',
    'Preferences/core-workflow.md',
    'Personal/profile-personal.md',
    'Preferences/vault-operation.md',
)
complete = '必読5ファイル＝全文注入済み（5/5）'


def check(name, action):
    try:
        action()
        print('ok - ' + name)
    except Exception as exc:
        # stdout/stderr の全文は表示しない（テストに必要な診断だけ）。
        print('NG - ' + name + ': ' + str(exc).replace('\n', ' ')[:240])


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def context(result):
    require(result.returncode == 0, f'hook exit={result.returncode}（起動を止めない）')
    output = json.loads(result.stdout)
    require(output.get('continue') is not False, 'continue=false は起動を止める')
    specific = output['hookSpecificOutput']
    require(specific['hookEventName'] == 'SessionStart', 'hookEventName が不一致')
    require(isinstance(specific['additionalContext'], str), 'additionalContext が文字列でない')
    return specific['additionalContext']


def full_content(result, bodies):
    text = context(result)
    require(text.startswith(complete), '冒頭に全文注入済み（5/5）がない')
    require('⚠️ 不足' not in text, '全件存在するのに不足扱い')
    for note, body in bodies.items():
        require(body in text, f'{note}: 全文（先頭・中間・末尾）が一致しない')
        headers = [line for line in text.splitlines() if note in line]
        require(any(re.search(r'(?<!\d)4\s*(?:行|lines?\b)', line) for line in headers),
                f'{note}: パスと行数4の見出しがない')


def shortage(result, missing, bodies):
    text = context(result)
    opening = text.splitlines()[0]
    require(f'必読5ファイルのうち {len(missing)} 件が不足' in opening,
            '冒頭の不足件数が不一致')
    require('読了として扱わず' in opening and '最初の応答で本人に伝える' in opening,
            '冒頭に未読扱い・本人への報告指示がない')
    require(complete not in text, '不足を全文読了として扱っている')
    warnings = [line for line in text.splitlines() if '⚠️ 不足：' in line]
    require(len(warnings) == len(missing), '不足行の件数が不一致')
    for note in missing:
        require(any(note in line and re.search(r'[（(].+?[）)]', line) for line in warnings),
                f'{note}: 不足行にパス・理由がない')
    for note, body in bodies.items():
        if note not in missing:
            require(body in text, f'{note}: 読めるファイルの全文が欠落')


with tempfile.TemporaryDirectory(prefix='codex-boot-read-') as directory:
    work = Path(directory)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('AIENV_', 'CMUX_'))}
    cases = (
        ('5ファイルそろい', 'complete'),
        ('1件欠け', 'missing'),
        ('空ファイル', 'empty'),
        ('読めない対象（ディレクトリ）', 'unreadable'),
        ('全件欠け', 'absent'),
        ('ワーカー', 'worker'),
    )
    for index, (label, mode) in enumerate(cases):
        home = work / mode
        vault = home / 'Data/obsidian'
        home.mkdir()
        bodies = {}
        for number, note in enumerate(notes):
            path = vault / note
            path.parent.mkdir(parents=True, exist_ok=True)
            # 引用符・バックスラッシュ・Unicode・空行でJSONエスケープも検査。
            body = f'FIRST-{number}\n中間 "引用" \\ 🧪\n\nLAST-{number}\n'
            bodies[note] = body
            path.write_text(body, encoding='utf-8')
        missing = []
        if mode in ('missing', 'empty', 'unreadable'):
            missing = [notes[1]]
            target = vault / notes[1]
            target.unlink()
            if mode == 'empty':
                target.touch()
            elif mode == 'unreadable':
                # chmod 000 は root で読めるため、確実に読めない型を使う。
                target.mkdir()
        elif mode == 'absent':
            missing = list(notes)
            for note in notes:
                (vault / note).unlink()
        case_env = dict(env, HOME=str(home))
        if mode == 'worker':
            case_env['AIENV_CODEX_WORKER'] = '1'
        command = [sys.executable if hook.suffix == '.py' else 'bash', str(hook)]
        try:
            result = subprocess.run(command, input=json.dumps({
                'hook_event_name': 'SessionStart', 'source': 'startup',
                'session_id': 'boot-read-test', 'cwd': str(home),
            }), env=case_env, cwd=home, text=True, capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            result = None

        def valid_json():
            require(result is not None, 'hook起動失敗またはタイムアウト')
            context(result)

        check(f'BR-{index * 2 + 1:02d} {label}: exit 0・有効なJSON・SessionStart', valid_json)
        if mode == 'complete':
            action = lambda: full_content(result, bodies)
        elif mode == 'worker':
            action = lambda: require(context(result) == '', 'ワーカーのadditionalContextが空文字でない')
        else:
            action = lambda: shortage(result, missing, bodies)
        check(f'BR-{index * 2 + 2:02d} {label}: 追加コンテキスト', action)

    def handlers():
        config = json.loads((repo / 'team/connect/codex/hooks.json').read_text())
        return [handler for group in config['hooks']['SessionStart'] for handler in group['hooks']]

    def registered():
        require(any(handler.get('type') == 'command' and hook.name in handler.get('command', '')
                    for handler in handlers()), '新しいSessionStartコマンドフックがない')

    def cmux_retained():
        require(any(handler.get('type') == 'command'
                    and re.search(r'hooks\s+codex\s+session-start', handler.get('command', ''))
                    and 'cmux' in handler['command'] for handler in handlers()),
                '既存のcmux SessionStartフックがない')

    check('BR-13 hooks.json: 新しいSessionStartフックを登録', registered)
    check('BR-14 hooks.json: 既存cmuxフックを維持', cmux_retained)

    def worker_environment():
        bindir = work / 'bin'
        bindir.mkdir()
        probe = bindir / 'codex'
        probe.write_text('''#!/usr/bin/env bash
cat >/dev/null
printf '%s' "${AIENV_CODEX_WORKER:-}" > "$BOOT_READ_ENV_LOG"
printf '%s\\n' '{"type":"thread.started","thread_id":"boot-read-test"}'
printf '%s\\n' '{"type":"turn.completed"}'
''')
        probe.chmod(0o755)
        log = work / 'worker-env.txt'
        child_env = dict(env, HOME=str(work / 'worker'), PATH=str(bindir) + os.pathsep + env['PATH'],
                         BOOT_READ_ENV_LOG=str(log))
        require('AIENV_CODEX_WORKER' not in child_env, '親のworker変数が混入')
        result = subprocess.run([
            'bash', str(repo / 'team/connect/codex/codex-exec.sh'),
            '--cwd', str(work), '--sandbox', 'read-only', '--out', str(work / 'worker-out.md'),
            '--prompt-file', '-',
        ], input='必読: ~/Data/obsidian/Preferences/absolute-rules.md（テスト用依頼）',
            env=child_env, cwd=work, text=True, capture_output=True, timeout=10)
        require(result.returncode == 0, f'codex-exec.sh exit={result.returncode}')
        require(log.is_file(), '偽codexが呼ばれていない')
        require(log.read_text() == '1', '子プロセスにAIENV_CODEX_WORKER=1が渡っていない')

    check('BR-15 codex-exec.sh: 子へworker環境変数を渡す', worker_environment)

    def boot_handler():
        matches = [handler for handler in handlers()
                   if handler.get('type') == 'command' and hook.name in handler.get('command', '')]
        require(len(matches) == 1, '必読SessionStartコマンドを一意に特定できない')
        return matches[0]

    def unlimited_context():
        limit = boot_handler().get('additionalContextLimit')
        require(type(limit) is int and limit == 0, 'additionalContextLimit が整数0でない')

    check('BR-16 hooks.json: additionalContextLimit=0', unlimited_context)

    # 配置の既定値を複製せず、正本から解決する。実HOME/repoは変更しない。
    paths_file = repo / 'core/executor/vault-paths.sh'
    resolved = subprocess.run(
        ['/bin/bash', '-c', 'source "$1"; printf "%s" "$AIENV_REPO_HOME_REL"',
         'boot-read-paths', str(paths_file)],
        env=env, text=True, capture_output=True, check=True)
    default_rel = Path(resolved.stdout)
    require(not default_rel.is_absolute() and '..' not in default_rel.parts,
            'テストHOME外を参照するrepo相対パス')

    def fixture(label):
        home = work / label
        home.mkdir()
        bodies = {}
        for number, note in enumerate(notes):
            path = home / 'Data/obsidian' / note
            path.parent.mkdir(parents=True, exist_ok=True)
            bodies[note] = f'FIRST-{number}\n登録コマンド検査 "引用" \\ 🧪\n\nLAST-{number}\n'
            path.write_text(bodies[note], encoding='utf-8')
        install_hook(home / default_rel)
        return home, bodies

    def install_hook(destination):
        target = destination / hook.relative_to(repo)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(hook, target)
        config = destination / paths_file.relative_to(repo)
        config.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(paths_file, config)
        return target

    def run_registered(home, worker=False, **overrides):
        child_env = dict(env, HOME=str(home), **overrides)
        if worker:
            child_env['AIENV_CODEX_WORKER'] = '1'
        # hooks.json の文字列をそのままシェルへ渡す。本体の直接起動は禁止。
        return subprocess.run(
            ['/bin/bash', '-c', boot_handler()['command']],
            input=json.dumps({'hook_event_name': 'SessionStart', 'source': 'startup',
                              'session_id': 'registered-command-test', 'cwd': str(home)}),
            env=child_env, cwd=home, text=True, capture_output=True, timeout=10)

    def registered_complete(worker):
        home, bodies = fixture('registered-' + str(worker))
        result = run_registered(home, worker)
        if worker:
            require(context(result) == '', 'ワーカーのadditionalContextが空文字でない')
        else:
            full_content(result, bodies)

    check('BR-17 登録コマンド: リーダーへ5ファイル全文', lambda: registered_complete(False))
    check('BR-18 登録コマンド: ワーカーは空コンテキスト', lambda: registered_complete(True))

    def broken_hook(mode, worker):
        home, bodies = fixture('broken-' + mode + '-' + str(worker))
        target = home / default_rel / hook.relative_to(repo)
        target.unlink()
        if mode == 'unreadable':
            # rootでも読めない型にする（既存BR-07と同じ再現方法）。
            target.mkdir()
        elif mode == 'failed':
            target.write_text('#!/bin/bash\nexit 126\n')
            target.chmod(0o755)
        result = run_registered(home, worker)
        if worker:
            require(context(result) == '', '本体異常時にワーカーへ追加コンテキストがある')
        else:
            shortage(result, list(notes), bodies)

    for index, (label, mode) in enumerate((('本体なし', 'absent'),
                                          ('本体が読めない', 'unreadable'),
                                          ('本体が実行失敗', 'failed'))):
        for offset, worker in enumerate((False, True)):
            role = 'ワーカーは空コンテキスト' if worker else 'リーダーは5件の不足明示'
            check(f'BR-{19 + index * 2 + offset:02d} 登録コマンド・{label}: {role}',
                  lambda mode=mode, worker=worker: broken_hook(mode, worker))

    def python_failure(mode, worker):
        home, bodies = fixture('python-' + mode + '-' + str(worker))
        bindir = home / 'bin'
        bindir.mkdir()
        # Pythonだけを外す。フォールバックに必要なシェル/標準コマンドは残す。
        for name in ('bash', 'sh', 'cat', 'dirname', 'basename', 'pwd', 'wc', 'sed',
                     'awk', 'grep', 'tr', 'head', 'tail', 'readlink', 'realpath', 'env'):
            executable = shutil.which(name, path=env.get('PATH'))
            if executable:
                (bindir / name).symlink_to(executable)
        marker = home / 'python-attempted'
        if mode == 'failed':
            python = bindir / 'python3'
            python.write_text('#!/bin/bash\nprintf attempted > "$HOME/python-attempted"\nexit 126\n')
            python.chmod(0o755)
        else:
            require(shutil.which('python3', path=str(bindir)) is None, 'PythonがPATHに混入')
        result = run_registered(home, worker, PATH=str(bindir))
        # ワーカーはPython起動前に終了してもよい。
        if mode == 'failed' and not worker:
            require(marker.is_file(), 'Python起動失敗の経路を通っていない')
        if worker:
            require(context(result) == '', 'Python異常時にワーカーへ追加コンテキストがある')
        else:
            shortage(result, list(notes), bodies)

    for index, (label, mode) in enumerate((('Pythonなし', 'absent'), ('Python起動失敗', 'failed'))):
        for offset, worker in enumerate((False, True)):
            role = 'ワーカーは空コンテキスト' if worker else 'リーダーは5件の不足明示'
            check(f'BR-{25 + index * 2 + offset:02d} 登録コマンド・{label}: {role}',
                  lambda mode=mode, worker=worker: python_failure(mode, worker))

    def overridden_repo():
        home, _ = fixture('overridden-repo')
        override_rel = Path('custom repo/別の配置')
        selected = install_hook(home / override_rel)
        # 既定と上書き先を区別できる出力にする。空白/Unicodeを含む配置も検査。
        for target, marker in ((home / default_rel / hook.relative_to(repo), 'DEFAULT-REPO'),
                               (selected, 'OVERRIDDEN-REPO')):
            output = json.dumps({'hookSpecificOutput': {
                'hookEventName': 'SessionStart', 'additionalContext': marker}})
            target.write_text("#!/bin/bash\ncat <<'RESULT'\n" + output + '\nRESULT\n')
            target.chmod(0o755)
        result = run_registered(home, AIENV_REPO_HOME_REL=str(override_rel))
        require(context(result) == 'OVERRIDDEN-REPO', 'AIENV_REPO_HOME_RELの配置の本体が使われない')

    check('BR-29 登録コマンド: AIENV_REPO_HOME_RELで本体の配置を上書き', overridden_repo)
PY
COUNT=0
while IFS= read -r result; do
  COUNT=$((COUNT + 1))
  case "$result" in
    'ok - '*) pass "${result#ok - }" ;;
    *) fail_case "${result#NG - }" ;;
  esac
done < <(python3 "$WORK/check.py" "$REPO_ROOT" "$HOOK")
[[ "$COUNT" -eq 29 ]] || fail_case "受入条件29件を実行できていない（実際: $COUNT）"
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
