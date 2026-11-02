#!/usr/bin/env bash
# Codex SessionStart 必読5ファイル注入の受入テスト（req-common.md の裁定）。
# 前提: HOME を差し替えると、フックは $HOME/Data/obsidian を読む。
# ワーカー識別は AIENV_CODEX_WORKER=1。実物の5ファイルは使用しない。
# 対象は team/connect/codex/session-start-read.sh を仮定する。
# 別名/Python 実装の場合は AIENV_CODEX_BOOT_READ_HOOK に絶対パスを指定する。
# .py は python3、それ以外は bash で起動する。実装本体はこのテストに含めない。
# codex-exec.sh は PATH 前置の偽 codex で子の環境を観測する。
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
        require(any(note in line for line in warnings),
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
        if mode == 'missing':
            missing = [notes[1]]
            target = vault / notes[1]
            target.unlink()
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

        if mode == 'complete':
            action = lambda: full_content(result, bodies)
        elif mode == 'worker':
            action = lambda: require(context(result) == '', 'ワーカーのadditionalContextが空文字でない')
        else:
            action = lambda: shortage(result, missing, bodies)
        check(f'{label}: JSONと追加コンテキスト', action)

    def broken_health_keeps_required_notes():
        bindir = work / 'broken-health-bin'
        bindir.mkdir()
        probe = bindir / 'python3'
        # 必読注入の Python は動かし、子の判定機だけ items の無い JSON を返す。
        probe.write_text('#!/bin/sh\nif [ "$1" = "-" ]; then exec "' + sys.executable
                         + '" "$@"; fi\nprintf \'%s\\n\' \'{"stage":"OK","sources":{"recall":{}}}\'\n')
        probe.chmod(0o755)
        case_env = dict(env, HOME=str(work / 'complete'), PATH=str(bindir) + os.pathsep + env['PATH'])
        result = subprocess.run(['bash', str(hook)], env=case_env, text=True,
                                capture_output=True, timeout=10)
        expected = {note: (work / 'complete/Data/obsidian' / note).read_text() for note in notes}
        full_content(result, expected)
        require(context(result).splitlines()[-1] == '【外部脳ヘルス】判定不能（共通観測・保存に失敗）',
                '判定不能の1行がない')
        require(context(result).count('【外部脳ヘルス】') == 1, '途中のヘルス表示が残っている')

    check('ヘルスJSON必須キー欠落でも必読全文を保持', broken_health_keeps_required_notes)

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
        prefs = work / 'preferences'
        prefs.mkdir()
        (prefs / 'worker-role-implementer.md').write_text('試験用職種ノート')
        log = work / 'worker-env.txt'
        child_env = dict(env, HOME=str(work / 'worker'), PATH=str(bindir) + os.pathsep + env['PATH'],
                         BOOT_READ_ENV_LOG=str(log), AIENV_PREFERENCES_DIR=str(prefs))
        require('AIENV_CODEX_WORKER' not in child_env, '親のworker変数が混入')
        result = subprocess.run([
            'bash', str(repo / 'team/connect/codex/codex-exec.sh'),
            '--role', 'implementer', '--cwd', str(work), '--sandbox', 'read-only', '--out', str(work / 'worker-out.md'),
            '--prompt-file', '-',
        ], input='必読: ~/Data/obsidian/Preferences/absolute-rules.md（テスト用依頼）',
            env=child_env, cwd=work, text=True, capture_output=True, timeout=10)
        require(result.returncode == 0, f'codex-exec.sh exit={result.returncode}')
        require(log.is_file(), '偽codexが呼ばれていない')
        require(log.read_text() == '1', '子プロセスにAIENV_CODEX_WORKER=1が渡っていない')

    check('BR-15 codex-exec.sh: 子へworker環境変数を渡す', worker_environment)

PY
python3 "$WORK/check.py" "$REPO_ROOT" "$HOOK" > "$WORK/results" || fail_case "検査プログラムが異常終了"
while IFS= read -r result; do
  case "$result" in
    'ok - '*) pass "${result#ok - }" ;;
    *) fail_case "${result#NG - }" ;;
  esac
done < "$WORK/results"
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
