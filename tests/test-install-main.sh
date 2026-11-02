#!/usr/bin/env bash
# フック配置・非破壊雛形・生成専用口。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/core/assembly/install-main.sh"
LIB="$REPO_ROOT/team/executor/profile_resolve.py"
FIXTURES="$TESTS_DIR/fixtures"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# write_models_conf_at <dir> — モデル定義ファイル（models.conf）を <dir>/models.conf
# へ書く。role行は`model=<定義名>[,...]`で定義名を参照するだけなので、role.leader
# の解決を伴うテストは全てこの定義ファイルを必要とする。
write_models_conf_at() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
EOF
}

# make_fake_home_no_profile <home> — 実体プロファイルを置かない版（雛形配置＝
# profile.mdの生成・非破壊性そのものを検証するテスト専用）。
make_fake_home_no_profile() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

# make_fake_home <home> — 妥当な実体プロファイル＋models.confを置いた偽HOME。
# 本ファイルの多くのテストの主眼＝symlink化・settings.json生成の検証であり、
# 雛形配置に依存させない（テストの独立性）。
make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  mkdir -p "$home/.config/takumi009-ai-env"
  write_models_conf_at "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: test-install-main-machine
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-sonnet-high
---
EOF
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
make_fake_home "$FAKE_HOME"
export SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1

echo "=== 全フックと雛形を配置する ==="
rc=0
HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_eq "導入が正常終了する" 0 "$rc"
assert_true "初回はプレースホルダ展開済みテンプレそのもの" "$(python3 - "$FAKE_HOME" "$REPO_ROOT" <<'PY'
import json, pathlib, sys
home, repo = map(pathlib.Path, sys.argv[1:])
window = json.loads((repo/'core/assembly/settings.json').read_text())['env']['CLAUDE_CODE_AUTO_COMPACT_WINDOW']
expected = (repo/'team/connect/codex/config.toml').read_text().replace('__AIENV_HOME__', str(home)).replace('__AIENV_AUTO_COMPACT_WINDOW__', str(int(window)))
assert (home/'.codex/config.toml').read_text() == expected
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_true "登録した全フックの実体が実行可能" "$(python3 - "$FAKE_HOME" <<'PY'
import json,os,shlex,sys
from pathlib import Path
h=Path(sys.argv[1]); d=json.loads((h/'.claude/settings.json').read_text())
commands=[e['command'] for group in d['hooks'].values() for item in group for e in item['hooks'] if e.get('type')=='command']
assert commands
for c in commands:
    p=shlex.split(c.replace('${HOME}',str(h)).replace('$HOME',str(h)))[0]
    assert os.path.isfile(p) and os.access(p,os.X_OK), p
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_true "職種定義の配置が配布元を指す" "$(python3 - "$FAKE_HOME" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys
h,r=map(Path,sys.argv[1:]); defs=list((r/'team/rules/agents').glob('*.md'))
assert defs
for p in defs:
    dest=h/'.claude/agents'/p.name
    assert dest.is_symlink() and dest.resolve()==p.resolve()
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
HOME2="$WORK/no-profile"; make_fake_home_no_profile "$HOME2"
HOME="$HOME2" bash "$SCRIPT" >/dev/null 2>&1 || true
assert_true "雛形は独立した実ファイルとして作る" "$([[ -f "$HOME2/.config/takumi009-ai-env/profile.md" && ! -L "$HOME2/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"
before="$(shasum -a 256 "$FAKE_HOME/.config/takumi009-ai-env/profile.md")"
HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1
assert_eq "既存プロファイルは上書きしない" "$before" "$(shasum -a 256 "$FAKE_HOME/.config/takumi009-ai-env/profile.md")"

echo "=== Codex 設定の初回生成・再生成 ==="
cat > "$FAKE_HOME/.codex/config.toml" <<'EOF'
model = "old-model"
model_reasoning_effort = "low"
notify = ["app-notify", "turn-ended"]
unknown_setting = { text = "引用\"と改行\n", count = 3, ratio = 1.5, enabled = true, day = 2026-11-01, items = [{ name = "one" }] }
[plugins."unified-computer-use@openai-bundled"]
enabled = true
[plugins."computer-use@openai-bundled"]
enabled = true
[projects."/test/project"]
trust_level = "trusted"
[tui]
counter = 7
[marketplaces.local]
last_updated = 2026-11-01T01:02:03Z
[hooks.state."test-hook"]
enabled = false
[mcp_servers.node_repl]
command = "/app/node_repl"
env_vars = ["BROWSER_USE_TEST"]
[mcp_servers.node_repl.env]
BROWSER_USE_AVAILABLE_BACKENDS = "iab"
BROWSER_USE_CODEX_APP_VERSION = "test-version"
[features]
hooks = false
js_repl = true
unknown_feature = "keep"
[sandbox_workspace_write]
network_access = false
EOF
cp "$FAKE_HOME/.codex/config.toml" "$WORK/config-before.toml"
HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1
assert_true "アプリ値・未知キーを保持し、本人キーをテンプレ値に戻す" "$(python3 - "$FAKE_HOME" "$WORK/config-before.toml" "$REPO_ROOT" <<'PY'
import json, pathlib, sys, tomllib
home, before, repo = map(pathlib.Path, sys.argv[1:])
live = tomllib.loads((home/'.codex/config.toml').read_text())
old = tomllib.loads(before.read_text())
for key in ('notify', 'unknown_setting', 'projects', 'tui', 'marketplaces', 'hooks'):
    assert live[key] == old[key], key
for key, value in old['plugins'].items():
    assert live['plugins'][key] == value, key
node = live['mcp_servers']['node_repl']
for key in ('command', 'env_vars'):
    assert node[key] == old['mcp_servers']['node_repl'][key], key
for key, value in old['mcp_servers']['node_repl']['env'].items():
    assert node['env'][key] == value, key
# 既存に無いアプリ管理キーはテンプレから補う。
assert node['startup_timeout_sec'] == 120
assert node['env']['CODEX_HOME'] == str(home/'.codex')
window = json.loads((repo/'core/assembly/settings.json').read_text())['env']['CLAUDE_CODE_AUTO_COMPACT_WINDOW']
template = tomllib.loads((repo/'team/connect/codex/config.toml').read_text().replace('__AIENV_HOME__', str(home)).replace('__AIENV_AUTO_COMPACT_WINDOW__', window))
for key in ('model', 'model_reasoning_effort', 'sandbox_workspace_write'):
    assert live[key] == template[key], key
assert live['features'] == dict(template['features'], unknown_feature='keep')
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"

# check-drift は観測基準も保存するため HOME を隔離する。外部照会・実 launchd はスタブへ向ける。
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/launchctl"
printf '#!/bin/sh\necho PRIVATE\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/launchctl" "$WORK/bin/gh"
HOME="$FAKE_HOME" PATH="$WORK/bin:$PATH" bash "$REPO_ROOT/core/assembly/check-drift.sh" > "$WORK/drift.log" 2>&1
assert_true "生成直後の check-drift ② は drift 0（未知キーは WARN）" "$(python3 - "$WORK/drift.log" <<'PY'
import pathlib, sys
section = pathlib.Path(sys.argv[1]).read_text().split('② ~/.codex/config.toml', 1)[1].split('③ repo', 1)[0]
assert 'TOML三分類で一致しています' in section
assert 'WARN: 未知キー' in section
assert '[DIFF]' not in section and '[MISSING-KEY]' not in section and '[TOML-PARSE-FAILED]' not in section
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"

echo "=== 1部品の複数配置を導出・配置・検査する ==="
HOME="$FAKE_HOME" bash "$REPO_ROOT/core/assembly/ledger-tool.sh" placement --all > "$WORK/placement.tsv"
mv "$FAKE_HOME/.codex/hooks/vault-recall.sh" "$WORK/codex-recall-link"
rc=0
HOME="$FAKE_HOME" PATH="$WORK/bin:$PATH" bash "$REPO_ROOT/core/assembly/check-drift.sh" --managed-symlinks-only > "$WORK/missing-link.log" 2>&1 || rc=$?
mv "$WORK/codex-recall-link" "$FAKE_HOME/.codex/hooks/vault-recall.sh"
assert_true "両配置が同じ実体を指し、Codex 側の欠落も検出する" "$(python3 - "$FAKE_HOME" "$REPO_ROOT" "$WORK" "$rc" <<'PY'
from pathlib import Path
import re, sys
home, repo, work = map(Path, sys.argv[1:4])
src = repo / 'ai-brain/executor/vault-recall.sh'
rows = [row.split('\t') for row in (work / 'placement.tsv').read_text().splitlines()]
actual = [row for row in rows if row[2] == str(src)]
expected = [['link', str(home / leader / 'hooks/vault-recall.sh'), str(src), 'ai-brain']
            for leader in ('.claude', '.codex')]
assert actual == expected
assert all(Path(row[1]).is_symlink() and Path(row[1]).resolve() == src.resolve() for row in actual)
assert re.search(r'symlink総数: \d+件 / drift: 0件', (work / 'drift.log').read_text())
assert sys.argv[4] == '1'
assert f'[MISSING] {home}/.codex/hooks/vault-recall.sh ' in (work / 'missing-link.log').read_text()
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"

printf 'model = [broken\n' > "$FAKE_HOME/.codex/config.toml"
before="$(shasum -a 256 "$FAKE_HOME/.codex/config.toml")"
rc=0
HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_true "壊れた既存 TOML は導入失敗となり内容を保持する" "$([[ "$rc" -ne 0 && "$before" == "$(shasum -a 256 "$FAKE_HOME/.codex/config.toml")" ]] && echo 1 || echo 0)"

echo "=== dry-run は配置しない ==="
DRY_HOME="$WORK/dry-home"; mkdir -p "$DRY_HOME"
rc=0; HOME="$DRY_HOME" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || rc=$?
assert_true "dry-run は正常終了し HOME を変更しない" "$([[ "$rc" -eq 0 && -z "$(ls -A "$DRY_HOME")" ]] && echo 1 || echo 0)"

echo "=== 生成専用口は指定先だけに出力する ==="
RENDER_HOME="$WORK/render-home"; mkdir -p "$RENDER_HOME"
rc=0
AIENV_LOCAL_PROFILE_PATH="$FIXTURES/profile.md" AIENV_MODEL_DEFS_FILE="$FIXTURES/models.conf" \
  HOME="$RENDER_HOME" bash "$SCRIPT" --render-settings-json "$WORK/rendered.json" >/dev/null 2>&1 || rc=$?
assert_true "生成した JSON にモデル・フックがある" "$(python3 - "$WORK/rendered.json" "$rc" <<'PY'
import json,sys
assert sys.argv[2]=='0'
d=json.load(open(sys.argv[1])); assert d['model'] and d['hooks']
assert d['model'] != '__AIENV_MODEL__'
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_eq "生成専用口は HOME を変更しない" "" "$(ls -A "$RENDER_HOME")"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
