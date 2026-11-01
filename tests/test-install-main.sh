#!/usr/bin/env bash
# フック配置・非破壊雛形・Bedrock 秘匿・生成失敗時の既存保持。

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

[t-bedrock-opus]
provider=bedrock
model=opus
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

# write_v2_profile_with_bedrock_role <dest> <alias> — role.researcherを
# provider=bedrock model=<alias>（定義名t-bedrock-<alias>経由）で配役した
# プロファイルを書く（動的Bedrock許可キーのテスト用）。併せて<dest>と同じ
# ディレクトリへmodels.confを書く。
write_v2_profile_with_bedrock_role() {
  local dest="$1" alias="$2"
  mkdir -p "$(dirname "$dest")"
  write_models_conf_at "$(dirname "$dest")"
  cat > "$dest" <<EOF
---
schema_version: 7
profile_slug: test
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-sonnet-high
role.researcher: configured model=t-bedrock-${alias}
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

echo "=== dry-run は配置しない ==="
DRY_HOME="$WORK/dry-home"; mkdir -p "$DRY_HOME"
rc=0; HOME="$DRY_HOME" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || rc=$?
assert_true "dry-run は正常終了し HOME を変更しない" "$([[ "$rc" -eq 0 && -z "$(ls -A "$DRY_HOME")" ]] && echo 1 || echo 0)"

echo "=== Bedrock の許可と秘匿 ==="
write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" opus
ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
printf 'CLAUDE_CODE_USE_BEDROCK=1\nANTHROPIC_DEFAULT_OPUS_MODEL=test-bedrock-pin\nAWS_ACCESS_KEY_ID=fixture-secret\n' > "$ENV_FILE"
out="$(HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"
assert_true "許可された Bedrock 設定を取り込む" "$(python3 - "$FAKE_HOME/.claude/settings.json" <<'PY'
import json,sys
e=json.load(open(sys.argv[1]))['env']
assert e['CLAUDE_CODE_USE_BEDROCK']=='1' and e['ANTHROPIC_DEFAULT_OPUS_MODEL']=='test-bedrock-pin'
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_eq "Bedrock env は本人だけが読める" 600 "$(stat -f '%Lp' "$ENV_FILE")"
assert_true "認証キーを生成物へ出さない" "$(python3 - "$FAKE_HOME/.claude/settings.json" <<'PY'
import json,sys
assert 'AWS_ACCESS_KEY_ID' not in json.load(open(sys.argv[1])).get('env',{})
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_true "認証値と pin をログへ出さない" "$([[ "$out" != *fixture-secret* && "$out" != *test-bedrock-pin* ]] && echo 1 || echo 0)"
out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --check-profile 2>&1)"
assert_true "検査口も pin を出さない" "$([[ "$out" == OK* && "$out" != *test-bedrock-pin* ]] && echo 1 || echo 0)"

echo "=== 生成失敗では既存設定を保つ ==="
before="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json")"
rm "$ENV_FILE"; mkdir "$ENV_FILE"
rc=0; HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_true "失敗を非0で返す" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "失敗時に既存 settings.json を変えない" "$before" "$(shasum -a 256 "$FAKE_HOME/.claude/settings.json")"

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
