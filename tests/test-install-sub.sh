#!/usr/bin/env bash
# サブ機の骨格配置・既存 Vault 保持・install-main への委譲。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/core/assembly/install-sub.sh"

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

# write_models_conf_at <dir> — モデル定義ファイル（models.conf）を<dir>/
# models.conf へ書く（モデル定義ファイルと候補指定-設計-2026-09-08.md
# §2.3・§2.4）。schema 8のrole行は`model=<定義名>[,...]`で定義名を
# 参照するだけになったため、role.leaderの解決を伴うテストは全てこの定義
# ファイルを必要とする（無いとT7で解決不能になる）。tests/test-install-main.sh
# と同じ最小の定義セットを使う。
write_models_conf_at() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
EOF
}

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  # 配役表-能力軸整理-設計-2026-09-07.md §3: schema 5・新3キーの実体を
  # あらかじめ置く。本ファイルの主眼＝Vault骨格配置・symlink化・機役割の
  # 案内ログの検証とは無関係なテストは、install-main.shの雛形配置
  # （team/data/profile.md.sample からのコピー。2026-09-08 本人裁定A案で
  # 読み元をvault-public/Preferences/profile-sample.mdから付け替え）に
  # 依存させない（テストの独立性）。seed_v2_profile()・
  # 個別のcat上書きで置き換えるテストはこの既定値を上書きする（後勝ち）。
  mkdir -p "$home/.config/takumi009-ai-env"
  write_models_conf_at "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 8
profile_slug: test-install-sub-machine
team_mode: configured value=team
no_read_paths: unavailable
machine_role: configured value=sub
role.leader: configured model=t-sonnet-high
---
EOF
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1
FAKE_HOME="$WORK/new"; make_fake_home "$FAKE_HOME"
rc=0; HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
assert_eq "サブ機の導入が正常終了する" 0 "$rc"
assert_true "公開 Preferences の骨格を置く" "$([ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ] && echo 1 || echo 0)"
assert_true "個人ノートの置き場を用意する" "$([[ -d "$FAKE_HOME/Data/obsidian/Fragments" && -d "$FAKE_HOME/Data/obsidian/Knowledge" ]] && echo 1 || echo 0)"
assert_eq "委譲先が標準フックを配置する" "$REPO_ROOT/core/connect/claude-code/session-start-compose.sh" "$(readlink "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh")"
assert_true "委譲先が settings.json を生成する" "$(python3 - "$FAKE_HOME/.claude/settings.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['model'] and d['hooks']
PY
[ "$?" -eq 0 ] && echo 1 || echo 0)"
assert_true "サブ機では LaunchAgent を設置しない" "$([ ! -d "$FAKE_HOME/Library/LaunchAgents" ] && echo 1 || echo 0)"

FAKE_HOME="$WORK/existing"; make_fake_home "$FAKE_HOME"
mkdir -p "$FAKE_HOME/Data/obsidian"
printf 'existing private note\n' > "$FAKE_HOME/Data/obsidian/my-note.md"
HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1
assert_eq "既存の個人ノートを上書きしない" "existing private note" "$(cat "$FAKE_HOME/Data/obsidian/my-note.md")"
assert_true "既存 Vault に公開骨格を混ぜない" "$([ ! -e "$FAKE_HOME/Data/obsidian/Preferences" ] && echo 1 || echo 0)"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
