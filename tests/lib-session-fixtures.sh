# 要望8: 既存の設定生成・差分検査を実物のコピーと偽HOMEで通す。
# 呼び出し側の REPO_ROOT / PASS / FAIL / pass / fail_case を使う。
sf_init() {
  SF_WORK="$(mktemp -d)"
  SF_REPO="$SF_WORK/repo"
  SF_HOME="$SF_WORK/home"
  mkdir -p "$SF_REPO" "$SF_HOME/.config/takumi009-ai-env" "$SF_WORK/bin"
  # git は追跡対象の列挙のみ。コピー先に .git を作らず実gitを変更しない。
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
    { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"
  done | tar -cf - --null -T -) | (cd "$SF_REPO" && tar -xf -)
  printf '[t-session]\nprovider=anthropic-api\nmodel=claude-sonnet-5-5\n' > "$SF_HOME/.config/takumi009-ai-env/models.conf"
  printf '%s\n' '---' 'schema_version: 7' 'profile_slug: session-test' \
    'team_mode: configured value=full' 'no_read_paths: unavailable' \
    'machine_role: configured value=main' 'role.leader: configured model=t-session' '---' \
    > "$SF_HOME/.config/takumi009-ai-env/profile.md"
  for cmd in launchctl cmux osascript git; do
    printf '#!/bin/bash\nexit 1\n' > "$SF_WORK/bin/$cmd"
    chmod +x "$SF_WORK/bin/$cmd"
  done
}
sf_env() {
  env -i HOME="$SF_HOME" PATH="$SF_WORK/bin:$PATH" TMPDIR="$SF_WORK" \
    XDG_CACHE_HOME="$SF_HOME/.cache" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 "$@"
}
sf_install() {
  sf_env bash "$SF_REPO/core/assembly/install-main.sh" --select core,team > "$SF_WORK/install.log" 2>&1
}
sf_set_env() {
  python3 - "$SF_REPO/core/assembly/settings.json" "$1" "$2" <<'PY'
import json, sys
p, key, value = sys.argv[1:]
d = json.load(open(p))
env = d.setdefault('env', {})
if value == '__missing__':
    env.pop(key, None)
else:
    env[key] = value
with open(p, 'w') as f:
    json.dump(d, f)
PY
}
sf_check() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail_case "$desc"; fi
}
sf_generated_values() {
  python3 - "$SF_HOME" "$1" <<'PY'
import json, pathlib, sys, tomllib
h, value = pathlib.Path(sys.argv[1]), int(sys.argv[2])
c = json.loads((h/'.claude/settings.json').read_text())
x = tomllib.loads((h/'.codex/config.toml').read_text())
assert str(c['env']['CLAUDE_CODE_AUTO_COMPACT_WINDOW']) == str(value)
assert x['model_auto_compact_token_limit'] == value
PY
}
