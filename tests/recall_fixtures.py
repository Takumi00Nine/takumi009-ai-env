"""隔離 HOME 用の想起接続 fixture。製品コードは承認値を書かない。"""
import hashlib
import json
from pathlib import Path
import sys


def trust_codex_recall(home):
    """installer または最小 fixture が置いた想起ハンドラを信頼済みにする。"""
    source = home / '.codex/hooks.json'
    groups = json.loads(source.read_text())['hooks']['UserPromptSubmit']
    with (home / '.codex/config.toml').open('a') as out:
        for gi, group in enumerate(groups):
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


def configure_recall_connections(repo, home):
    """登録・実体・信頼だけを置く。想起の発火・成功は記録しない。"""
    for leader in ('claude', 'codex'):
        hook_rel = f'.{leader}/hooks/vault-recall.sh'
        hook = home / hook_rel
        hook.parent.mkdir(parents=True)
        hook.symlink_to(repo / 'ai-brain/executor/vault-recall.sh')
        groups = [{'hooks': [{'type': 'command', 'timeout': 5,
                             'command': f'$HOME/{hook_rel} --leader {leader}' + suffix}]}
                  for suffix in ('', ' --observe')]
        root = home / f'.{leader}'
        (root / ('settings.json' if leader == 'claude' else 'hooks.json')).write_text(
            json.dumps({'hooks': {'UserPromptSubmit': groups}}))
        if leader == 'codex':
            (root / 'config.toml').write_text('[features]\nhooks = true\n')
    trust_codex_recall(home)


if __name__ == '__main__':
    configure_recall_connections(*map(Path, sys.argv[1:3]))
