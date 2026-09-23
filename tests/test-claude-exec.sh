#!/usr/bin/env bash
# scripts/claude-exec.sh のユニットテスト（設計 docs/design-v1.1.1.md §9.1・
# 実装A担当ケース）。
#
# 実 claude コマンドには依存しない。tests/fake-claude/claude（偽シム）を
# CLAUDE_CODE_WRAPPER_BIN で差し替えて使う。実 $HOME・実 launchd・実 git は
# 触らない（HOMEを一時ディレクトリへ差し替え、AIENV_*でfixtureを指す）。
#
# 実行方法: bash tests/test-claude-exec.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/claude-exec.sh"
STUB_SRC="$TESTS_DIR/fake-claude/claude"
CLAUDE_EXEC_PY="$REPO_ROOT/claude/hooks/lib/claude_exec.py"
GUARD_COMMON_SH="$REPO_ROOT/claude/hooks/lib/guard_common.sh"
DELEGATION_GATE_SH="$REPO_ROOT/claude/hooks/delegation-gate-v2.sh"
REAL_AGENTS_DIR="$REPO_ROOT/claude/agents"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

# ============================================================
# 共通ヘルパ
# ============================================================

# 新しいfixture一式を作る（$WORK配下）。呼ぶたびにグローバル変数を上書きする。
ALL_WORK_DIRS=()
cleanup_all_work_dirs() {
  local d
  for d in ${ALL_WORK_DIRS[@]+"${ALL_WORK_DIRS[@]}"}; do
    chmod -R u+w "$d" 2>/dev/null
    rm -rf "$d" 2>/dev/null
  done
}
trap cleanup_all_work_dirs EXIT

new_fixture() {
  WORK="$(mktemp -d)"
  ALL_WORK_DIRS+=("$WORK")
  BINDIR="$WORK/bin"
  mkdir -p "$BINDIR"
  cp "$STUB_SRC" "$BINDIR/claude"
  chmod +x "$BINDIR/claude"

  PROFILE="$WORK/profile.md"
  cat > "$PROFILE" <<'EOF'
---
schema_version: 7
profile_slug: fixture
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.implementer: configured model=t-sonnet-high,t-sonnet-low,t-opus-high
role.vault-scribe: configured model=sonnet-noeffort
role.verifier:    configured model=t-sonnet-medium
role.system-designer: configured model=sonnet-legacy
role.researcher:  not_adopted
---
EOF

  MODELS_CONF="$WORK/models.conf"
  cat > "$MODELS_CONF" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5
effort=high

[t-sonnet-low]
provider=anthropic-api
model=claude-sonnet-5
effort=low

[t-sonnet-medium]
provider=anthropic-api
model=claude-sonnet-5
effort=medium

[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5

[t-opus-high]
provider=anthropic-api
model=claude-opus-5-5
effort=high

[sonnet-legacy]
provider=anthropic-api
model=claude-sonnet-4-6
effort=high
EOF

  mkdir -p "$WORK/home"
  SETTINGS_SRC="$WORK/settings-src.json"
  cat > "$SETTINGS_SRC" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[
        {"type":"command","command":"echo public-guard"},
        {"type":"command","command":"echo pip-guard"},
        {"type":"command","command":"echo brew-guard"},
        {"type":"command","command":"\$HOME/.claude/hooks/bash-danger-gate.sh"}
      ]},
      {"matcher":"Edit|Write|NotebookEdit","hooks":[{"type":"command","command":"\$HOME/.claude/hooks/delegation-gate-v2.sh"}]},
      {"matcher":"^Agent\$","hooks":[{"type":"command","command":"\$HOME/.claude/hooks/agent-model-guard.sh"}]}
    ],
    "SessionStart":[{"hooks":[{"type":"command","command":"echo should-not-appear"}]}],
    "UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo should-not-appear-either"}]}]
  }
}
EOF

  PROMPT="$WORK/prompt.txt"
  echo "absolute-rules を読んでから hello（テスト用依頼文）" > "$PROMPT"

  AGENTS_DIR="$REAL_AGENTS_DIR"
  MARKER_DIR="$WORK/markers"
  mkdir -p "$MARKER_DIR"
  STUBLOG="$WORK/stub.jsonl"
  LOG="$WORK/claude-exec.jsonl"

  export HOME="$WORK/home"
  export AIENV_LOCAL_PROFILE_PATH="$PROFILE"
  export AIENV_MODEL_DEFS_FILE="$MODELS_CONF"
  export AIENV_AGENT_SOURCE_DIR="$AGENTS_DIR"
  export AIENV_CHILD_SETTINGS_SRC="$SETTINGS_SRC"
  export AIENV_CLAUDE_EXEC_LOG="$LOG"
  export GATE_MARKER_DIR="$MARKER_DIR"
  export CLAUDE_CODE_WRAPPER_BIN="$BINDIR/claude"
  export AIENV_CLAUDE_STUB_LOG="$STUBLOG"
  unset AIENV_CLAUDE_EXEC_TIMEOUT_SECS AIENV_CLAUDE_STUB_SLEEP_SECS \
        AIENV_CLAUDE_STUB_RESPONSE_FILE AIENV_CLAUDE_STUB_EXIT_CODE \
        AIENV_CLAUDE_STUB_STDERR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}

# ラッパーを起動する（実HOMEを読まないようPATHは触らない・stdinは/dev/null）。
# 結果はグローバル RUN_STDOUT / RUN_STDERR / RC。
run_wrapper() {
  RUN_STDOUT="$(bash "$SCRIPT" "$@" < /dev/null 2>"$WORK/last-stderr.log")"
  RC=$?
  RUN_STDERR="$(cat "$WORK/last-stderr.log" 2>/dev/null || true)"
}

stub_lines() { wc -l < "$STUBLOG" 2>/dev/null | tr -d ' ' || echo 0; }
log_lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

# 最後に記録されたスタブ呼び出しの argv から、指定フラグの直後の値を返す。
stub_arg_after() {
  python3 -c '
import json, sys
path, flag = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
argv = lines[-1]["argv"]
try:
    print(argv[argv.index(flag) + 1])
except (ValueError, IndexError):
    print("")
' "$STUBLOG" "$1"
}

stub_argv_has() {
  python3 -c '
import json, sys
path, needle = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
print("1" if needle in lines[-1]["argv"] else "0")
' "$STUBLOG" "$1"
}

stub_env_keys_has() {
  python3 -c '
import json, sys
path, needle = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
print("1" if needle in lines[-1]["env_keys"] else "0")
' "$STUBLOG" "$1"
}

stub_settings_json() {
  python3 -c '
import json, sys
path = sys.argv[1]
lines = [json.loads(l) for l in open(path) if l.strip()]
argv = lines[-1]["argv"]
print(argv[argv.index("--settings") + 1])
' "$STUBLOG"
}

stub_cwd() {
  python3 -c '
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(lines[-1]["cwd"])
' "$STUBLOG"
}

# PreToolUseフックの出力（jq -n の整形JSON。空文字列=pass）がdenyかどうかを
# 判定する（`permissionDecision":"deny"`のような素朴な部分一致はjqの整形
# 出力〈コロン後にスペースが入る〉と食い違うため使わない）。
is_gate_denied() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("0"); sys.exit()
try:
    d = json.loads(raw)
    print("1" if d.get("hookSpecificOutput", {}).get("permissionDecision") == "deny" else "0")
except Exception:
    print("0")
'
}

log_field() {
  # $1=フィールド名。最後のログ行の値を返す（null は文字列"null"）。
  python3 -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(path) if l.strip()]
v = lines[-1].get(key, "__MISSING__")
print("null" if v is None else v)
' "$LOG" "$1"
}

# python3 を PATH から除いた最小PATHディレクトリ（reject_when_prereq_missing用）。
build_path_without_python3() {
  local dir="$1"
  mkdir -p "$dir"
  local sys_tool
  for sys_tool in /bin/bash /bin/sh /usr/bin/grep /usr/bin/sed /bin/cat /bin/mkdir \
                  /usr/bin/dirname /usr/bin/basename /usr/bin/mktemp /bin/chmod \
                  /usr/bin/wc /usr/bin/cut /bin/rm /usr/bin/tr /usr/bin/head \
                  /usr/bin/awk /usr/bin/od /bin/date /bin/kill /bin/ln; do
    [ -x "$sys_tool" ] && ln -sf "$sys_tool" "$dir/$(basename "$sys_tool")" 2>/dev/null
  done
}

write_json() {
  # $1=出力先 $2...=heredoc本文はcaller側で用意。ここでは単純に受け取る。
  cat > "$1"
}

# ============================================================
echo "=== AC-2b: resume_passes_model_and_effort_again ==="
{
  new_fixture
  OUT2B_1="$WORK/o2b-1.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT2B_1" --task-id t-ac2b-1 --model-def t-sonnet-high
  assert_eq "1通目 exit0" "0" "$RC"
  MODEL_1="$(stub_arg_after --model)"
  EFFORT_1="$(stub_arg_after --effort)"

  OUT2B_2="$WORK/o2b-2.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT2B_2" --task-id t-ac2b-2 --model-def t-sonnet-high --resume resume-sid-test
  assert_eq "2通目 exit0" "0" "$RC"
  assert_true "resume_passes_model_and_effort_again: --resumeが引数に現れる" "$([ "$(stub_argv_has --resume)" = "1" ] && echo 1 || echo 0)"
  assert_eq "resume_passes_model_and_effort_again: --resumeの値" "resume-sid-test" "$(stub_arg_after --resume)"
  assert_eq "resume_passes_model_and_effort_again: --modelが1通目と同値で再出現" "$MODEL_1" "$(stub_arg_after --model)"
  assert_eq "resume_passes_model_and_effort_again: --effortが1通目と同値で再出現" "$EFFORT_1" "$(stub_arg_after --effort)"
}

echo "=== AC-4: argv_has_p_agent_json_and_no_bare ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac4 --model-def t-sonnet-high
  assert_eq "exit 0" "0" "$RC"
  assert_true "argvに -p" "$(stub_argv_has "-p")"
  assert_true "argvに --agent implementer" "$([ "$(stub_arg_after --agent)" = "implementer" ] && echo 1 || echo 0)"
  assert_true "argvに --output-format json" "$([ "$(stub_arg_after --output-format)" = "json" ] && echo 1 || echo 0)"
  assert_true "argvに --bare が含まれない" "$([ "$(stub_argv_has --bare)" = "0" ] && echo 1 || echo 0)"
}

echo "=== AC-5: model_passed_verbatim / model_switches_with_candidate ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o1.json" --task-id t-ac5a --model-def t-sonnet-high
  assert_eq "t-sonnet-high: --model sonnet" "sonnet" "$(stub_arg_after --model)"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o2.json" --task-id t-ac5b --model-def t-opus-high
  # OPUS55-AC-2: model=claude-opus-5-5（t-opus-high）が --model opus へ解決される。
  assert_eq "t-opus-high: --model opus" "opus" "$(stub_arg_after --model)"
}

echo "=== AC-6: effort_present / effort_absent_no_flag / effort_differs_between_two_candidates ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o1.json" --task-id t-ac6a --model-def t-sonnet-high
  assert_eq "effort_present: --effort high" "high" "$(stub_arg_after --effort)"

  new_fixture
  run_wrapper --role vault-scribe --prompt-file "$PROMPT" --out "$WORK/o2.json" --task-id t-ac6b --model-def sonnet-noeffort
  assert_true "effort_absent_no_flag: --effortが引数に現れない" "$([ "$(stub_argv_has --effort)" = "0" ] && echo 1 || echo 0)"
  argv_json="$(python3 -c 'import json,sys; print(json.dumps([json.loads(l)["argv"] for l in open(sys.argv[1]) if l.strip()][-1]))' "$STUBLOG")"
  assert_not_contains "effort_absent_no_flag: effortLevelも現れない" "$argv_json" "effortLevel"

  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o3.json" --task-id t-ac6c1 --model-def t-sonnet-high
  e1="$(stub_arg_after --effort)"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o4.json" --task-id t-ac6c2 --model-def t-sonnet-low
  e2="$(stub_arg_after --effort)"
  assert_true "effort_differs_between_two_candidates: high != low" "$([ "$e1" = "high" ] && [ "$e2" = "low" ] && [ "$e1" != "$e2" ] && echo 1 || echo 0)"
}

echo "=== AC-7: reject_no_def(2) / reject_unknown_def(3) / reject_profile_4ways(4) / reject_missing_args_and_unknown_option(2) / reject_bad_task_id(2) ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-nodef
  assert_eq "reject_no_def: exit2" "2" "$RC"
  assert_eq "reject_no_def: stub 0行" "0" "$(stub_lines)"

  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-unknown --model-def t-sonnet-medium
  assert_eq "reject_unknown_def: exit3" "3" "$RC"
  assert_eq "reject_unknown_def: stub 0行" "0" "$(stub_lines)"

  # 4通り: 不在／不正／候補0件／未定義の定義名
  new_fixture
  export AIENV_LOCAL_PROFILE_PATH="$WORK/does-not-exist.md"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-p1 --model-def t-sonnet-high
  assert_eq "profile不在: exit4" "4" "$RC"
  export AIENV_LOCAL_PROFILE_PATH="$PROFILE"

  new_fixture
  BADPROFILE="$WORK/bad.md"
  sed '/^schema_version:/d' "$PROFILE" > "$BADPROFILE"
  export AIENV_LOCAL_PROFILE_PATH="$BADPROFILE"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-p2 --model-def t-sonnet-high
  assert_eq "profile不正: exit4" "4" "$RC"
  export AIENV_LOCAL_PROFILE_PATH="$PROFILE"

  new_fixture
  run_wrapper --role researcher --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-p3 --model-def t-sonnet-high
  assert_eq "候補0件(not_adopted): exit4" "4" "$RC"

  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-p4 --model-def totally-undefined-def
  assert_eq "未定義の定義名: exit4" "4" "$RC"

  # 必須5引数を1つずつ落とす＋未知オプション
  new_fixture
  run_wrapper --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-m1 --model-def t-sonnet-high
  assert_eq "role欠落: exit2" "2" "$RC"
  run_wrapper --role implementer --out "$WORK/o.json" --task-id t-m2 --model-def t-sonnet-high
  assert_eq "prompt-file欠落: exit2" "2" "$RC"
  run_wrapper --role implementer --prompt-file "$PROMPT" --task-id t-m3 --model-def t-sonnet-high
  assert_eq "out欠落: exit2" "2" "$RC"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --model-def t-sonnet-high
  assert_eq "task-id欠落: exit2" "2" "$RC"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-m5
  assert_eq "model-def欠落: exit2" "2" "$RC"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-m6 --model-def t-sonnet-high --no-such-option
  assert_eq "未知オプション: exit2" "2" "$RC"
  assert_eq "④6件: stub 0行のまま" "0" "$(stub_lines)"

  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id "Bad_ID!" --model-def t-sonnet-high
  assert_eq "reject_bad_task_id: exit2" "2" "$RC"
  assert_eq "reject_bad_task_id: stub 0行" "0" "$(stub_lines)"
}

echo "=== AC-8: 子環境の組み立て ==="
{
  # ① child_env_only_fixed_key / setting_sources_excludes_user_and_project /
  #    child_cwd_has_no_local_settings
  new_fixture
  export ANTHROPIC_API_KEY="dummy-secret-1"
  export AWS_ACCESS_KEY_ID="dummy-secret-2"
  export CLAUDE_CODE_SOME_DUMMY="dummy-secret-3"
  RAND_SUFFIX="$$_$RANDOM"
  export "ANTHROPIC_FAKE_$RAND_SUFFIX=fake1"
  export "AWS_FAKE_$RAND_SUFFIX=fake2"
  export "CLAUDE_CODE_FAKE_$RAND_SUFFIX=fake3"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8a --model-def t-sonnet-high
  assert_eq "exit0" "0" "$RC"
  n_prefixed="$(python3 -c '
import json
lines=[json.loads(l) for l in open("'"$STUBLOG"'") if l.strip()]
keys=lines[-1]["env_keys"]
n=sum(1 for k in keys if k.startswith("ANTHROPIC_") or k.startswith("AWS_") or k.startswith("CLAUDE_CODE_"))
print(n)
')"
  assert_eq "child_env_only_fixed_key: 3プレフィックス該当キーは固定1つだけ" "1" "$n_prefixed"
  assert_true "CLAUDE_CODE_WRAPPER_BINは残る" "$(stub_env_keys_has CLAUDE_CODE_WRAPPER_BIN)"
  ss_val="$(stub_arg_after --setting-sources)"
  assert_eq "setting_sources_excludes_user_and_project: local のみ" "local" "$ss_val"
  assert_true "child_cwd_has_no_local_settings: 子cwdにsettings.local.jsonが無い" \
    "$([ ! -e "$WORK/.claude/settings.local.json" ] && echo 1 || echo 0)"
  # fake_keys_absent_and_not_in_sources
  assert_true "fake_keys_absent_and_not_in_sources: ANTHROPIC_FAKEが子環境に無い" "$([ "$(stub_env_keys_has "ANTHROPIC_FAKE_$RAND_SUFFIX")" = "0" ] && echo 1 || echo 0)"
  assert_true "fake_keys_absent_and_not_in_sources: AWS_FAKEが子環境に無い" "$([ "$(stub_env_keys_has "AWS_FAKE_$RAND_SUFFIX")" = "0" ] && echo 1 || echo 0)"
  assert_true "fake_keys_absent_and_not_in_sources: CLAUDE_CODE_FAKEが子環境に無い" "$([ "$(stub_env_keys_has "CLAUDE_CODE_FAKE_$RAND_SUFFIX")" = "0" ] && echo 1 || echo 0)"
  hits="$(grep -RF "$RAND_SUFFIX" "$REPO_ROOT/scripts/claude-exec.sh" "$CLAUDE_EXEC_PY" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "fake_keys_absent_and_not_in_sources: 架空キー名はソース中に0件" "0" "$hits"
  unset ANTHROPIC_API_KEY AWS_ACCESS_KEY_ID CLAUDE_CODE_SOME_DUMMY
  unset "ANTHROPIC_FAKE_$RAND_SUFFIX" "AWS_FAKE_$RAND_SUFFIX" "CLAUDE_CODE_FAKE_$RAND_SUFFIX"

  # ③ parent_env_and_settings_unchanged
  new_fixture
  export ANTHROPIC_API_KEY="dummy-secret-parent"
  before_env="$(env | grep -E '^(ANTHROPIC_|AWS_|CLAUDE_CODE_)' | sort)"
  before_hash="$(shasum -a 256 "$SETTINGS_SRC" | awk '{print $1}')"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8c --model-def t-sonnet-high
  after_env="$(env | grep -E '^(ANTHROPIC_|AWS_|CLAUDE_CODE_)' | sort)"
  after_hash="$(shasum -a 256 "$SETTINGS_SRC" | awk '{print $1}')"
  assert_eq "parent_env_and_settings_unchanged: 親環境の3プレフィックス集合が不変" "$before_env" "$after_env"
  assert_eq "parent_env_and_settings_unchanged: settings-srcのハッシュが不変" "$before_hash" "$after_hash"
  unset ANTHROPIC_API_KEY

  # ④ path_home_survive
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8d --model-def t-sonnet-high
  assert_true "path_home_survive: PATHが子環境に残る" "$(stub_env_keys_has PATH)"
  assert_true "path_home_survive: HOMEが子環境に残る" "$(stub_env_keys_has HOME)"

  # ⑤(i)(ii)(iii) settings_has_hooks_without_sessionstart /
  # child_settings_pretooluse_nonempty_and_excludes_leader_hooks
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8e1 --model-def t-sonnet-high
  settings1="$(stub_settings_json)"
  assert_not_contains "settings_has_hooks_without_sessionstart: SessionStartが無い" "$settings1" '"SessionStart"'
  py_check="$(python3 -c '
import json, sys
s = json.loads(sys.argv[1])
pre = s.get("hooks", {}).get("PreToolUse", [])
nonempty = len(pre) > 0
excludes_leader = not any(
    "delegation-gate-v2.sh" in h.get("command","") or "agent-model-guard.sh" in h.get("command","")
    for e in pre for h in e.get("hooks", [])
)
print("1" if (nonempty and excludes_leader) else "0")
' "$settings1")"
  assert_true "child_settings_pretooluse_nonempty_and_excludes_leader_hooks" "$py_check"

  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o2.json" --task-id t-ac8e2 --model-def t-sonnet-high
  settings2="$(stub_settings_json)"
  assert_eq "同じ職種なら毎回同じ--settings集合になる" "$settings1" "$settings2"

  # reject_when_source_settings_unreadable_or_empty(8)
  new_fixture
  export AIENV_CHILD_SETTINGS_SRC="$WORK/does-not-exist.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8f1 --model-def t-sonnet-high
  assert_eq "抽出元が読めない: exit8" "8" "$RC"
  assert_eq "抽出元が読めない: stub 0行" "0" "$(stub_lines)"

  new_fixture
  EMPTYSRC="$WORK/empty-settings.json"
  cat > "$EMPTYSRC" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Edit|Write|NotebookEdit","hooks":[{"type":"command","command":"\$HOME/.claude/hooks/delegation-gate-v2.sh"}]}]}}
EOF
  export AIENV_CHILD_SETTINGS_SRC="$EMPTYSRC"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8f2 --model-def t-sonnet-high
  assert_eq "柵が0本(全部リーダー専用): exit8" "8" "$RC"
  assert_eq "柵が0本: stub 0行" "0" "$(stub_lines)"

  # 裁定A: child_settings_has_vault_gate_for_non_scribe /
  # child_settings_omits_vault_gate_for_vault_scribe
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8g1 --model-def t-sonnet-high
  s_impl="$(stub_settings_json)"
  assert_contains "child_settings_has_vault_gate_for_non_scribe" "$s_impl" "vault-write-gate.sh"

  new_fixture
  run_wrapper --role vault-scribe --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac8g2 --model-def sonnet-noeffort
  s_scribe="$(stub_settings_json)"
  assert_not_contains "child_settings_omits_vault_gate_for_vault_scribe" "$s_scribe" "vault-write-gate.sh"

  # child_settings_drops_empty_entry (DR1-m5): ^Agent$エントリ(command1本=
  # agent-model-guard.shのみ)が丸ごと落ちること（=matcher "^Agent$" が
  # 残った--settingsに現れない）
  assert_not_contains "child_settings_drops_empty_entry: ^Agent\$エントリが残らない" "$s_impl" '"^Agent$"'

  # reject_when_local_settings_present(9)
  new_fixture
  OUT9="$WORK/artifacts9/o.json"
  mkdir -p "$(dirname "$OUT9")/.claude"
  echo '{"env":{"ANTHROPIC_LEAK":"x"}}' > "$(dirname "$OUT9")/.claude/settings.local.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT9" --task-id t-ac8h --model-def t-sonnet-high
  assert_eq "reject_when_local_settings_present: exit9" "9" "$RC"
  assert_eq "reject_when_local_settings_present: stub 0行" "0" "$(stub_lines)"
}

echo "=== AC-9: marker_uses_parent_sid / child_sid_marker_does_not_pass / vault_still_denied ==="
{
  new_fixture
  export CLAUDE_CODE_SESSION_ID="parent-sid-ac9"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac9 --model-def t-sonnet-high
  assert_eq "起動成功" "0" "$RC"
  assert_true "marker_uses_parent_sid: マーカーファイルが親sidで存在する" \
    "$([ -e "$MARKER_DIR/claude-delegated-ok-parent-sid-ac9" ] && echo 1 || echo 0)"

  NONALLOW_PATH="$WORK/some-project/file.txt"
  mkdir -p "$(dirname "$NONALLOW_PATH")"

  gate_input_pass="$(python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "parent-sid-ac9" "$NONALLOW_PATH")"
  gate_out="$(printf '%s' "$gate_input_pass" | GATE_MARKER_DIR="$MARKER_DIR" bash "$DELEGATION_GATE_SH")"
  assert_true "marker_uses_parent_sid: rule 4mで通過（deny無し）" "$([ -z "$gate_out" ] && echo 1 || echo 0)"

  gate_input_childsid="$(python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "some-other-sid" "$NONALLOW_PATH")"
  gate_out2="$(printf '%s' "$gate_input_childsid" | GATE_MARKER_DIR="$MARKER_DIR" bash "$DELEGATION_GATE_SH")"
  assert_true "child_sid_marker_does_not_pass: 別sidではdeny" "$(is_gate_denied "$gate_out2")"

  VAULT_PATH="$HOME/Data/obsidian/Knowledge/test-ac9.md"
  gate_input_vault="$(python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "parent-sid-ac9" "$VAULT_PATH")"
  gate_out3="$(printf '%s' "$gate_input_vault" | GATE_MARKER_DIR="$MARKER_DIR" bash "$DELEGATION_GATE_SH")"
  assert_true "vault_still_denied: 委任マーカーがあってもVaultはdeny" "$(is_gate_denied "$gate_out3")"
}

echo "=== AC-10(1): reject_unsupported_alias_no_stub_record(5) ==="
{
  new_fixture
  run_wrapper --role system-designer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac10 --model-def sonnet-legacy
  assert_eq "未対応の別名: exit5" "5" "$RC"
  assert_eq "未対応の別名: stub 0行" "0" "$(stub_lines)"
}

echo "=== AC-11: parallel_n_lines_and_intact_artifacts / overwrite_denied_without_force(7) / overwrite_allowed_with_force ==="
{
  new_fixture
  N=5
  PIDS=()
  for i in $(seq 1 "$N"); do
    (
      bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" \
        --out "$WORK/par-$i.json" --task-id "t-par-$i" --model-def t-sonnet-high \
        < /dev/null > "$WORK/par-$i.stdout" 2>"$WORK/par-$i.stderr"
    ) &
    PIDS+=($!)
  done
  ALL_OK=1
  for p in "${PIDS[@]}"; do
    wait "$p" || ALL_OK=0
  done
  ok_artifacts=1
  for i in $(seq 1 "$N"); do
    python3 -c "import json; json.load(open('$WORK/par-$i.json'))" 2>/dev/null || ok_artifacts=0
  done
  assert_true "parallel: N個の成果物すべてが解析可能なJSON" "$ok_artifacts"
  n_log="$(log_lines)"
  assert_eq "parallel: ログ行数がN(=$N)と一致" "$N" "$n_log"
  ok_log_json=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    python3 -c "import json,sys; json.loads(sys.argv[1])" "$line" 2>/dev/null || ok_log_json=0
  done < "$LOG"
  assert_true "parallel: ログの各行がJSONとして解析できる" "$ok_log_json"

  # overwrite_denied_without_force / overwrite_allowed_with_force
  new_fixture
  OUTW="$WORK/w.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTW" --task-id t-ow1 --model-def t-sonnet-high
  assert_eq "1回目成功" "0" "$RC"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTW" --task-id t-ow2 --model-def t-sonnet-high
  assert_eq "overwrite_denied_without_force: exit7" "7" "$RC"
  assert_eq "overwrite_denied_without_force: stub行数は1のまま" "1" "$(stub_lines)"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTW" --task-id t-ow3 --model-def t-sonnet-high --force
  assert_eq "overwrite_allowed_with_force: exit0" "0" "$RC"
  assert_eq "overwrite_allowed_with_force: stub行数は2に増える" "2" "$(stub_lines)"
}

echo "=== AC-12: timeout_classifies_and_logs(12) ==="
{
  new_fixture
  export AIENV_CLAUDE_EXEC_TIMEOUT_SECS=1
  export AIENV_CLAUDE_STUB_SLEEP_SECS=6
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac12 --model-def t-sonnet-high
  assert_eq "timeout: exit12" "12" "$RC"
  assert_eq "timeout: REASON:timeout" "timeout" "$(printf '%s\n' "$RUN_STDOUT" | awk -F: '/^REASON:/{print $2}')"
  assert_eq "timeout: ログのreason_code=timeout" "timeout" "$(log_field reason_code)"
  unset AIENV_CLAUDE_EXEC_TIMEOUT_SECS AIENV_CLAUDE_STUB_SLEEP_SECS
}

echo "=== AC-15: no_secret_in_five_outputs / no_prompt_body_in_log_or_dryrun ==="
{
  new_fixture
  SECRET="sk-dummy-secret-XYZ789"
  export ANTHROPIC_API_KEY="$SECRET"
  UNIQUE_PROMPT_MARKER="PROMPT_BODY_UNIQUE_MARKER_QAZXSW"
  echo "absolute-rules を読んでから hello ${UNIQUE_PROMPT_MARKER}" > "$PROMPT"

  OUT15="$WORK/o15.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT15" --task-id t-ac15 --model-def t-sonnet-high
  n1="$(grep -c "$SECRET" "$LOG" 2>/dev/null || true)"; n1="${n1:-0}"
  n2="$(printf '%s' "$RUN_STDOUT" | grep -c "$SECRET" || true)"; n2="${n2:-0}"
  n3="$(printf '%s' "$RUN_STDERR" | grep -c "$SECRET" || true)"; n3="${n3:-0}"
  n4="$(grep -c "$SECRET" "$OUT15" 2>/dev/null || true)"; n4="${n4:-0}"

  DRYOUT="$WORK/dry.json"
  DRYSTDOUT="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$DRYOUT" --task-id t-ac15-dry --model-def t-sonnet-high --dry-run < /dev/null 2>"$WORK/dry-stderr.log")"
  n5="$(printf '%s' "$DRYSTDOUT" | grep -c "$SECRET" || true)"; n5="${n5:-0}"

  assert_eq "no_secret_in_five_outputs: ログに0件" "0" "$n1"
  assert_eq "no_secret_in_five_outputs: 標準出力に0件" "0" "$n2"
  assert_eq "no_secret_in_five_outputs: 標準エラーに0件" "0" "$n3"
  assert_eq "no_secret_in_five_outputs: 成果物に0件" "0" "$n4"
  assert_eq "no_secret_in_five_outputs: dry-run表示に0件" "0" "$n5"

  m1="$(grep -c "$UNIQUE_PROMPT_MARKER" "$LOG" 2>/dev/null || true)"; m1="${m1:-0}"
  m2="$(printf '%s' "$DRYSTDOUT" | grep -c "$UNIQUE_PROMPT_MARKER" || true)"; m2="${m2:-0}"
  assert_eq "no_prompt_body_in_log_or_dryrun: ログに依頼文本文が0件" "0" "$m1"
  assert_eq "no_prompt_body_in_log_or_dryrun: dry-run表示に依頼文本文が0件" "0" "$m2"
  unset ANTHROPIC_API_KEY
}

echo "=== AC-16: artifact_and_session_id_recorded ==="
{
  new_fixture
  OUT16="$WORK/o16.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT16" --task-id t-ac16 --model-def t-sonnet-high
  assert_eq "exit0" "0" "$RC"
  assert_true "成果物ファイルが実在" "$([ -f "$OUT16" ] && echo 1 || echo 0)"
  sid_field="$(log_field child_session_id)"
  assert_true "ログのchild_session_idが非空" "$([ -n "$sid_field" ] && [ "$sid_field" != "null" ] && echo 1 || echo 0)"
}

echo "=== AC-17: dry_run_prints_names_only ==="
{
  new_fixture
  # env-keysは「現在プロセスの環境に実在するキー」だけを列挙するので、
  # CLAUDE_CODE_SESSION_ID の名前がdry-run表示に出ることを見るには
  # 実際に立てておく必要がある（new_fixtureは既定でunsetしている）。
  export CLAUDE_CODE_SESSION_ID="dry-run-parent-sid"
  DRYOUT="$WORK/dry2.json"
  DRYSTDOUT="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$DRYOUT" --task-id t-ac17 --model-def t-sonnet-high --dry-run < /dev/null 2>"$WORK/dry2-stderr.log")"
  DRYRC=$?
  assert_eq "exit0" "0" "$DRYRC"
  assert_eq "スタブ記録0行" "0" "$(stub_lines)"
  assert_contains "候補の定義名が出る" "$DRYSTDOUT" "t-sonnet-high"
  assert_contains "--modelの値が出る" "$DRYSTDOUT" "model=sonnet"
  assert_contains "effortの値が出る" "$DRYSTDOUT" "effort=high"
  assert_contains "環境変数名が出る(CLAUDE_CODE_SESSION_ID)" "$DRYSTDOUT" "CLAUDE_CODE_SESSION_ID"
  assert_true "--outファイルは作られない" "$([ ! -e "$DRYOUT" ] && echo 1 || echo 0)"
  assert_true "<out>.lockは作られない（DR1-m7）" "$([ ! -e "${DRYOUT}.lock" ] && echo 1 || echo 0)"
  assert_eq "invocationログは残らない" "0" "$(log_lines)"

  # dry-runは--outの親ディレクトリが無くても新設しない（DR1-m7）。
  DRYOUT_NESTED="$WORK/dry-run-nested-dir/dry3.json"
  DRYSTDOUT2="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$DRYOUT_NESTED" --task-id t-ac17-nested --model-def t-sonnet-high --dry-run < /dev/null 2>"$WORK/dry3-stderr.log")"
  DRYRC2=$?
  assert_eq "dry_run_prints_names_only(nested): exit0" "0" "$DRYRC2"
  assert_true "dry_run_prints_names_only(nested): 親ディレクトリは作られない" "$([ ! -e "$WORK/dry-run-nested-dir" ] && echo 1 || echo 0)"
}

echo "=== I2-m2: dry_run_matches_production_accept_reject ==="
{
  # ①親ディレクトリが作成不能（祖先がファイルで塞がれている）＝本番はexit8。
  new_fixture
  BLOCKER_FILE="$WORK/i2m2-blocker"
  : > "$BLOCKER_FILE"
  OUT_BLOCKED="$BLOCKER_FILE/sub/out.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT_BLOCKED" --task-id t-i2m2-a1 --model-def t-sonnet-high
  RC_PROD_A="$RC"
  DRY_A_STDOUT="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$OUT_BLOCKED" --task-id t-i2m2-a2 --model-def t-sonnet-high --dry-run < /dev/null 2>/dev/null)"
  RC_DRY_A=$?
  assert_eq "dry_run_matches_production_accept_reject(親不在・作成不能): 本番exit8" "8" "$RC_PROD_A"
  assert_eq "dry_run_matches_production_accept_reject(親不在・作成不能): dry-runも同じexit" "$RC_PROD_A" "$RC_DRY_A"

  # ②settings.local.jsonがcwdにある＝本番はexit9。
  new_fixture
  OUTCFG="$WORK/i2m2-cfg/out.json"
  mkdir -p "$(dirname "$OUTCFG")/.claude"
  echo '{"env":{"ANTHROPIC_LEAK":"x"}}' > "$(dirname "$OUTCFG")/.claude/settings.local.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTCFG" --task-id t-i2m2-b1 --model-def t-sonnet-high
  RC_PROD_B="$RC"
  DRY_B_STDOUT="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$OUTCFG" --task-id t-i2m2-b2 --model-def t-sonnet-high --dry-run < /dev/null 2>/dev/null)"
  RC_DRY_B=$?
  assert_eq "dry_run_matches_production_accept_reject(settings.local.jsonあり): 本番exit9" "9" "$RC_PROD_B"
  assert_eq "dry_run_matches_production_accept_reject(settings.local.jsonあり): dry-runも同じexit" "$RC_PROD_B" "$RC_DRY_B"

  # ③相対パス＝手順1（引数の形）で本番・dry-run共通にexit2。
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "relative/out.json" --task-id t-i2m2-c1 --model-def t-sonnet-high
  RC_PROD_C="$RC"
  DRY_C_STDOUT="$(bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "relative/out.json" --task-id t-i2m2-c2 --model-def t-sonnet-high --dry-run < /dev/null 2>/dev/null)"
  RC_DRY_C=$?
  assert_eq "dry_run_matches_production_accept_reject(相対パス): 本番exit2" "2" "$RC_PROD_C"
  assert_eq "dry_run_matches_production_accept_reject(相対パス): dry-runも同じexit" "$RC_PROD_C" "$RC_DRY_C"
}

echo "=== AC-19: permission_denials_not_success(13) ==="
{
  new_fixture
  RESP="$WORK/resp-denial.json"
  cat > "$RESP" <<'EOF'
{"is_error":false,"subtype":"success","session_id":"sid-denial","result":"Write was denied by policy","permission_denials":[{"tool_name":"Write","tool_use_id":"x","tool_input":{}}]}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$RESP"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac19 --model-def t-sonnet-high
  assert_eq "permission_denials非空でも成功扱いしない: exit13" "13" "$RC"
  assert_eq "ログのreason_code=permission_denied" "permission_denied" "$(log_field reason_code)"
  unset AIENV_CLAUDE_STUB_RESPONSE_FILE
}

echo "=== AC-19b: classify_auth_http(11) / classify_auth_not_logged_in(11) / classify_limit(10) / classify_other_529(14) / classify_retried_429_is_other(14) / subtype_success_does_not_fool / stderr_does_not_change_class ==="
{
  new_fixture
  R1="$WORK/r1.json"; cat > "$R1" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":401,"terminal_reason":"api_error","result":"Failed to authenticate. API Error: 401 API key is invalid.","num_turns":1,"total_cost_usd":0}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R1"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o1.json" --task-id t-b1 --model-def t-sonnet-high
  assert_eq "classify_auth_http: exit11" "11" "$RC"
  assert_eq "classify_auth_http: reason_code=auth_failed" "auth_failed" "$(log_field reason_code)"

  R2="$WORK/r2.json"; cat > "$R2" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":null,"terminal_reason":"api_error","result":"Not logged in · Please run /login"}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R2"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o2.json" --task-id t-b2 --model-def t-sonnet-high
  assert_eq "classify_auth_not_logged_in: exit11" "11" "$RC"
  assert_eq "classify_auth_not_logged_in: reason_code=auth_failed" "auth_failed" "$(log_field reason_code)"

  R3="$WORK/r3.json"; cat > "$R3" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":429,"terminal_reason":"api_error","result":"API Error: Request rejected (429) · upstream limit"}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R3"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o3.json" --task-id t-b3 --model-def t-sonnet-high
  assert_eq "classify_limit: exit10" "10" "$RC"
  assert_eq "classify_limit: reason_code=limit_reached" "limit_reached" "$(log_field reason_code)"

  R4="$WORK/r4.json"; cat > "$R4" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":529,"terminal_reason":"api_error","result":"API Error: Repeated 529 Overloaded errors"}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R4"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o4.json" --task-id t-b4 --model-def t-sonnet-high
  assert_eq "classify_other_529: exit14" "14" "$RC"
  assert_eq "classify_other_529: reason_code=other" "other" "$(log_field reason_code)"
  assert_contains "classify_other_529: resultの全文がラッパーの標準エラーに出る" "$RUN_STDERR" "API Error: Repeated 529 Overloaded errors"

  R5="$WORK/r5.json"; cat > "$R5" <<'EOF'
{"is_error":true,"subtype":"success","api_error_status":429,"terminal_reason":"api_error","result":"API Error: too many requests after retries"}
EOF
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R5"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o5.json" --task-id t-b5 --model-def t-sonnet-high
  assert_eq "classify_retried_429_is_other: exit14" "14" "$RC"
  assert_eq "classify_retried_429_is_other: reason_code=other(枠の上限に丸めない)" "other" "$(log_field reason_code)"

  # subtype_success_does_not_fool: 上の5件すべて subtype=success なのに
  # 分類が①②⑤のいずれかになっている＝subtypeで判定していないことの押さえ。
  pass "subtype_success_does_not_fool: 上5件はすべて subtype=success だが正しく分類された（既に確認済み）"

  # stderr_does_not_change_class: 子の標準エラーに別分類を示す文言を出しても
  # 分類が変わらないこと。
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$R3"
  export AIENV_CLAUDE_STUB_STDERR="Not logged in · Please run /login (dummy stderr noise)"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o6.json" --task-id t-b6 --model-def t-sonnet-high
  assert_eq "stderr_does_not_change_class: exit10のまま" "10" "$RC"
  assert_eq "stderr_does_not_change_class: reason_code=limit_reachedのまま" "limit_reached" "$(log_field reason_code)"
  unset AIENV_CLAUDE_STUB_RESPONSE_FILE AIENV_CLAUDE_STUB_STDERR
}

echo "=== DR1-M2: child_stderr_kept_next_to_out ==="
{
  new_fixture
  STDERR_MARKER="CHILD_STDERR_MARKER_$$"
  export AIENV_CLAUDE_STUB_STDERR="$STDERR_MARKER"
  OUTSTDERR="$WORK/ostderr.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTSTDERR" --task-id t-stderr --model-def t-sonnet-high
  assert_eq "child_stderr_kept_next_to_out: exit0（stderrがあっても分類は変わらない）" "0" "$RC"
  assert_true "child_stderr_kept_next_to_out: <out>.stderrが作られる" "$([ -f "${OUTSTDERR}.stderr" ] && echo 1 || echo 0)"
  n_marker="$(grep -c "$STDERR_MARKER" "${OUTSTDERR}.stderr" 2>/dev/null || true)"; n_marker="${n_marker:-0}"
  assert_true "child_stderr_kept_next_to_out: <out>.stderrに子のstderrが残る" "$([ "$n_marker" -ge 1 ] && echo 1 || echo 0)"
  unset AIENV_CLAUDE_STUB_STDERR
}

echo "=== AC-21: invocation_keys_exact_11 / ts_rfc3339_ms_utc / ids_unique_and_format / child_fields_non_empty_on_success / child_sid_null_when_not_launched ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac21 --model-def t-sonnet-high
  keys_ok="$(python3 -c '
import json
rec = json.loads(open("'"$LOG"'").read().splitlines()[-1])
expected = {"ts","type","invocation_id","task_id","role","candidate_def","exit_code","reason_code","artifact_path","child_session_id","child_cwd"}
print("1" if set(rec.keys()) == expected else "0")
')"
  assert_true "invocation_keys_exact_11: キー11個ちょうど" "$keys_ok"

  ts_ok="$(python3 -c '
import json, re
rec = json.loads(open("'"$LOG"'").read().splitlines()[-1])
print("1" if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", rec["ts"]) else "0")
')"
  assert_true "ts_rfc3339_ms_utc: UTC RFC3339ミリ秒形式" "$ts_ok"

  assert_true "child_fields_non_empty_on_success: child_session_id非空" "$([ -n "$(log_field child_session_id)" ] && [ "$(log_field child_session_id)" != "null" ] && echo 1 || echo 0)"
  assert_true "child_fields_non_empty_on_success: child_cwd非空" "$([ -n "$(log_field child_cwd)" ] && [ "$(log_field child_cwd)" != "null" ] && echo 1 || echo 0)"

  # ids_unique_and_format: N並行呼び出しで invocation_id が相異なりUUID/16進形式
  new_fixture
  for i in 1 2 3; do
    bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$WORK/id-$i.json" --task-id "t-id-$i" --model-def t-sonnet-high < /dev/null > /dev/null 2>&1
  done
  ids_ok="$(python3 -c '
import json, re
recs = [json.loads(l) for l in open("'"$LOG"'") if l.strip()]
ids = [r["invocation_id"] for r in recs]
fmt_ok = all(re.match(r"^[0-9a-f]{16,}$", i) for i in ids)
print("1" if (len(ids) == len(set(ids)) and fmt_ok) else "0")
')"
  assert_true "ids_unique_and_format: 3個のinvocation_idが相異なり16進形式" "$ids_ok"

  # child_sid_null_when_not_launched
  new_fixture
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-ac21-null --model-def totally-undefined-def
  assert_eq "child_sid_null_when_not_launched: exit4" "4" "$RC"
  assert_eq "child_sid_null_when_not_launched: child_session_id=null" "null" "$(log_field child_session_id)"
}

echo "=== 新設①: allowed_tools_matches_role_tools ==="
{
  new_fixture
  run_wrapper --role vault-scribe --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-newac1 --model-def sonnet-noeffort
  expect_tools="$(python3 "$REPO_ROOT/claude/hooks/lib/agent_def.py" allowed-tools --dir "$AGENTS_DIR" --role vault-scribe)"
  actual_tools="$(stub_arg_after --allowedTools)"
  assert_eq "allowed_tools_matches_role_tools: agent_def.pyの出力と一致" "$expect_tools" "$actual_tools"
}

echo "=== 設計固有の失敗経路: reject_prompt_without_absolute_rules(6) ==="
{
  new_fixture
  BADPROMPT="$WORK/no-ref.txt"
  echo "こんにちは、何かして" > "$BADPROMPT"
  run_wrapper --role implementer --prompt-file "$BADPROMPT" --out "$WORK/o.json" --task-id t-noref --model-def t-sonnet-high
  assert_eq "exit6" "6" "$RC"
  assert_eq "stub 0行" "0" "$(stub_lines)"
  assert_eq "ログ1行" "1" "$(log_lines)"
}

echo "=== 設計固有の失敗経路: reject_unreadable_prompt_file(6) ==="
{
  new_fixture
  run_wrapper --role implementer --prompt-file "$WORK/does-not-exist-prompt.txt" --out "$WORK/o.json" --task-id t-unread --model-def t-sonnet-high
  assert_eq "exit6(2ではない＝DR1-M6)" "6" "$RC"
  assert_eq "ログ1行" "1" "$(log_lines)"
}

echo "=== 設計固有の失敗経路: reject_when_prereq_missing(8) ==="
{
  new_fixture
  NOPYDIR="$WORK/no-python3-path"
  build_path_without_python3 "$NOPYDIR"
  RUN_STDOUT="$(PATH="$NOPYDIR" bash "$SCRIPT" --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-nopy --model-def t-sonnet-high < /dev/null 2>"$WORK/nopy-stderr.log")"
  RC=$?
  assert_eq "python3が無い: exit8" "8" "$RC"

  new_fixture
  export CLAUDE_CODE_WRAPPER_BIN="$WORK/does-not-exist-claude"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o2.json" --task-id t-nobin --model-def t-sonnet-high
  assert_eq "claude実行体が無い: exit8" "8" "$RC"
}

echo "=== 設計固有の失敗経路: classify_non_json_output(14) ==="
{
  new_fixture
  RESP="$WORK/resp-nonjson.txt"
  echo "not a json line" > "$RESP"
  export AIENV_CLAUDE_STUB_RESPONSE_FILE="$RESP"
  OUTNJ="$WORK/o-nj.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTNJ" --task-id t-nonjson --model-def t-sonnet-high
  assert_eq "非JSON出力: exit14" "14" "$RC"
  assert_eq "非JSON出力: reason_code=other" "other" "$(log_field reason_code)"
  assert_true "非JSON出力: --outに生出力が残る" "$(grep -q "not a json line" "$OUTNJ" && echo 1 || echo 0)"
  unset AIENV_CLAUDE_STUB_RESPONSE_FILE
}

echo "=== 設計固有の失敗経路: rename_failure_keeps_tmp(15) ==="
{
  new_fixture
  OUT15R="$WORK/artifacts15/rename-target.json"
  mkdir -p "$OUT15R"
  chmod 555 "$OUT15R"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUT15R" --task-id t-rename --model-def t-sonnet-high --force
  assert_eq "rename失敗: exit15" "15" "$RC"
  assert_eq "rename失敗: ログのreason_code=rename_failed" "rename_failed" "$(log_field reason_code)"
  tmp_left="$(find "$(dirname "$OUT15R")" -maxdepth 1 -name 'rename-target.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_true "rename失敗: 一時ファイルが残る" "$([ "$tmp_left" -ge 1 ] && echo 1 || echo 0)"
  chmod 755 "$OUT15R"
}

echo "=== 設計固有の失敗経路: resolver_hang_times_out(4) ==="
{
  new_fixture
  FAKELIB="$WORK/fake-lib"
  mkdir -p "$FAKELIB"
  cp "$REPO_ROOT/claude/hooks/lib/agent_def.py" "$FAKELIB/agent_def.py"
  cp "$REPO_ROOT/claude/hooks/lib/claude_exec.py" "$FAKELIB/claude_exec.py"
  cat > "$FAKELIB/profile_resolve.py" <<'EOF'
import sys, time
time.sleep(60)
EOF
  FAKESCRIPT="$WORK/fake-claude-exec.sh"
  sed "s#LIB_DIR=\"\$REPO_ROOT/claude/hooks/lib\"#LIB_DIR=\"$FAKELIB\"#" "$SCRIPT" > "$FAKESCRIPT"
  chmod +x "$FAKESCRIPT"
  START=$(date +%s)
  RUN_STDOUT="$(bash "$FAKESCRIPT" --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-hang --model-def t-sonnet-high < /dev/null 2>"$WORK/hang-stderr.log")"
  RC=$?
  END=$(date +%s)
  assert_eq "resolverハング: exit4" "4" "$RC"
  assert_true "resolverハング: 30秒程度で打ち切られる(60秒未満)" "$([ $((END-START)) -lt 55 ] && echo 1 || echo 0)"
}

echo "=== 設計固有の失敗経路: warnings_go_to_stderr_only ==="
{
  # F1: 親sidが空
  new_fixture
  unset CLAUDE_CODE_SESSION_ID
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-f1 --model-def t-sonnet-high
  assert_eq "F1: 終了コードは変わらず0" "0" "$RC"
  assert_contains "F1: 標準エラーに警告" "$RUN_STDERR" "親セッションID"

  # F2: マーカーが書けない（GATE_MARKER_DIRを書けない場所にする）
  new_fixture
  export CLAUDE_CODE_SESSION_ID="sid-f2"
  export GATE_MARKER_DIR="$WORK/no-such-marker-dir/nested"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$WORK/o2.json" --task-id t-f2 --model-def t-sonnet-high
  assert_eq "F2: 終了コードは変わらず0" "0" "$RC"
  assert_contains "F2: 標準エラーに警告" "$RUN_STDERR" "委任実績マーカー"

  # F4: カナリア不在（偽claudeはSessionEndフックを実行しないため常に不在）
  new_fixture
  OUTF4="$WORK/artf4/o.json"
  run_wrapper --role implementer --prompt-file "$PROMPT" --out "$OUTF4" --task-id t-f4 --model-def t-sonnet-high
  assert_eq "F4: 終了コードは変わらず0" "0" "$RC"
  assert_contains "F4: 標準エラーに警告" "$RUN_STDERR" "カナリア"
  assert_true "F4: .claude-exec-hooks-missing が残る" "$([ -e "$WORK/artf4/.claude-exec-hooks-missing" ] && echo 1 || echo 0)"
}

echo "=== 設計固有の失敗経路: vault_gate_denies_ai_folders ==="
{
  new_fixture
  VAULT_TARGET="$HOME/Data/obsidian/Knowledge/vg-test.md"
  mkdir -p "$(dirname "$VAULT_TARGET")"
  in1="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$VAULT_TARGET" "$WORK")"
  out1="$(printf '%s' "$in1" | bash "$REPO_ROOT/claude/hooks/vault-write-gate.sh")"
  assert_true "vault_gate_denies_ai_folders: 6フォルダ配下はdeny" "$(is_gate_denied "$out1")"

  NONVAULT_TARGET="$HOME/Data/obsidian/Blogs/vg-test2.md"
  mkdir -p "$(dirname "$NONVAULT_TARGET")"
  in2="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$NONVAULT_TARGET" "$WORK")"
  out2="$(printf '%s' "$in2" | bash "$REPO_ROOT/claude/hooks/vault-write-gate.sh")"
  assert_true "vault_gate_denies_ai_folders: 配下でないパスは素通り" "$([ -z "$out2" ] && echo 1 || echo 0)"
}

# ============================================================
# RC-X（職種の追加・削除を設定だけで完結させる設計 2026-09-20 §3・§4.5）:
# Vault 書込宣言（frontmatter `aienv-vault-write: allowed`）で柵の有無を決める。
# 職種名の名指し・件数の固定はしない（定義集合はディレクトリの中身そのもの）。
# ============================================================

# --settings JSON の PreToolUse のうち vault-write-gate.sh を含むエントリ数。
count_vault_gate_entries() {
  printf '%s' "$1" | python3 -c '
import json, sys
s = json.load(sys.stdin)
n = 0
for e in s.get("hooks", {}).get("PreToolUse", []):
    if any("vault-write-gate.sh" in (h.get("command") or "") for h in e.get("hooks", [])):
        n += 1
print(n)
'
}

# 要件 §7 の probe 形の定義（契約だけを満たす最小形）を書く。
# 引数: <出力パス> <name> [<frontmatter に足す行>...]
write_probe_def() {
  local out="$1" name="$2" extra
  shift 2
  {
    echo "---"
    echo "name: $name"
    echo "description: probe definition for the wrapper-path test"
    echo "tools: Read"
    for extra in "$@"; do echo "$extra"; done
    echo "---"
    echo "probe body"
    echo
    echo "## 権限"
    echo "成果物への書込＝なし／テスト＝なし／実行＝なし"
  } > "$out"
}

# 一時配役表（new_fixture の $PROFILE）の閉じ `---` の直前に 1 行足す。
profile_add_role_line() {
  python3 - "$PROFILE" "$1" <<'PYPROF'
import sys
path, line = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
head, sep, tail = text.rpartition("\n---\n")
open(path, "w", encoding="utf-8").write(head + "\n" + line + sep + tail)
PYPROF
}

# child-settings を直叩きする。結果はグローバル CS_STDOUT / CS_STDERR / CS_RC。
run_child_settings() {
  local role="$1" dir="$2"
  CS_STDOUT="$(python3 "$CLAUDE_EXEC_PY" child-settings --src "$REPO_ROOT/claude/settings.json" --role "$role" --child-cwd "$WORK" --agents-dir "$dir" 2>"$WORK/cs-stderr.log")"
  CS_RC=$?
  CS_STDERR="$(cat "$WORK/cs-stderr.log" 2>/dev/null || true)"
}

echo "=== RC-X1. child-settings 直叩き: 宣言の 4 状態（なし／有効／不正／重複）＋未知 aienv- キー（AC-3(a)(b)(c)） ==="
{
  new_fixture
  RCX_DIR="$WORK/decl-agents"
  mkdir -p "$RCX_DIR"
  write_probe_def "$RCX_DIR/decl-ok.md"   decl-ok   "aienv-vault-write: allowed"
  write_probe_def "$RCX_DIR/decl-none.md" decl-none
  write_probe_def "$RCX_DIR/decl-bad.md"  decl-bad  "aienv-vault-write: yes"
  write_probe_def "$RCX_DIR/decl-dup.md"  decl-dup  "aienv-vault-write: yes" "aienv-vault-write: allowed"
  write_probe_def "$RCX_DIR/decl-typo.md" decl-typo "aienv-vault-writ: allowed"

  run_child_settings decl-ok "$RCX_DIR"
  assert_eq "RC-X1 decl-ok: exit 0" "0" "$CS_RC"
  assert_eq "RC-X1 decl-ok: vault-write-gate エントリ 0 件" "0" "$(count_vault_gate_entries "$CS_STDOUT")"

  run_child_settings decl-none "$RCX_DIR"
  assert_eq "RC-X1 decl-none: exit 0" "0" "$CS_RC"
  assert_eq "RC-X1 decl-none: vault-write-gate エントリ 1 件" "1" "$(count_vault_gate_entries "$CS_STDOUT")"

  for pair in "decl-bad:VAULT_WRITE_DECLARATION_INVALID" \
              "decl-dup:VAULT_WRITE_DECLARATION_DUPLICATE" \
              "decl-typo:AIENV_KEY_UNKNOWN"; do
    r="${pair%%:*}"; code="${pair#*:}"
    run_child_settings "$r" "$RCX_DIR"
    assert_eq "RC-X1 $r: exit 1" "1" "$CS_RC"
    assert_eq "RC-X1 $r: stdout 空" "" "$CS_STDOUT"
    assert_eq "RC-X1 $r: stderr がちょうど 1 行（traceback でない）" "1" "$(wc -l < "$WORK/cs-stderr.log" | tr -d ' ')"
    assert_true "RC-X1 $r: stderr が $code で始まる" "$([[ "$CS_STDERR" == "$code"* ]] && echo 1 || echo 0)"
  done
  # 後勝ちで 0 件にならない＝重複は DUPLICATE であって INVALID/成功ではない。
  run_child_settings decl-dup "$RCX_DIR"
  assert_not_contains "RC-X1 decl-dup: INVALID ではなく DUPLICATE" "$CS_STDERR" "VAULT_WRITE_DECLARATION_INVALID"
}

echo "=== RC-X2. ラッパー経由: 宣言が不正な職種は子を起動せず exit 8（AC-3(c)） ==="
{
  new_fixture
  RCX2_DIR="$WORK/decl-agents"
  mkdir -p "$RCX2_DIR"
  write_probe_def "$RCX2_DIR/decl-bad.md" decl-bad "aienv-vault-write: yes"
  profile_add_role_line "role.decl-bad: configured model=t-sonnet-high"
  export AIENV_AGENT_SOURCE_DIR="$RCX2_DIR"
  run_wrapper --role decl-bad --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-rcx2 --model-def t-sonnet-high
  assert_eq "RC-X2: exit 8" "8" "$RC"
  assert_eq "RC-X2: stub 0 行（子は起動しない）" "0" "$(stub_lines)"
  assert_contains "RC-X2: stderr に原因コード" "$RUN_STDERR" "VAULT_WRITE_DECLARATION_INVALID"
}

echo "=== RC-X3. ラッパー経由: 実定義の複製＋probe（宣言なし）で起動・--agents は probe・柵 1 件・--allowedTools=Read（AC-1④⑥） ==="
{
  new_fixture
  RCX3_DIR="$WORK/agents-with-probe"
  mkdir -p "$RCX3_DIR"
  cp "$REAL_AGENTS_DIR"/*.md "$RCX3_DIR"/
  write_probe_def "$RCX3_DIR/zz-probe.md" zz-probe
  profile_add_role_line "role.zz-probe: configured model=t-sonnet-high"
  export AIENV_AGENT_SOURCE_DIR="$RCX3_DIR"
  run_wrapper --role zz-probe --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-rcx3 --model-def t-sonnet-high
  assert_eq "RC-X3: exit 0" "0" "$RC"
  assert_eq "RC-X3: --agents のトップキー={zz-probe}" "zz-probe" "$(stub_arg_after --agents | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin).keys())))')"
  assert_eq "RC-X3: --settings に vault-write-gate ちょうど 1 件" "1" "$(count_vault_gate_entries "$(stub_settings_json)")"
  assert_eq "RC-X3: --allowedTools=Read" "Read" "$(stub_arg_after --allowedTools)"
}

echo "=== RC-X4. ラッパー経由: probe を zz-probe-b へ改名（削除＋追加）しても同じ観測（AC-2b②） ==="
{
  new_fixture
  RCX4_DIR="$WORK/agents-with-probe-b"
  mkdir -p "$RCX4_DIR"
  cp "$REAL_AGENTS_DIR"/*.md "$RCX4_DIR"/
  write_probe_def "$RCX4_DIR/zz-probe-b.md" zz-probe-b
  profile_add_role_line "role.zz-probe-b: configured model=t-sonnet-high"
  export AIENV_AGENT_SOURCE_DIR="$RCX4_DIR"
  run_wrapper --role zz-probe-b --prompt-file "$PROMPT" --out "$WORK/o.json" --task-id t-rcx4 --model-def t-sonnet-high
  assert_eq "RC-X4: exit 0" "0" "$RC"
  assert_eq "RC-X4: --agents のトップキー={zz-probe-b}" "zz-probe-b" "$(stub_arg_after --agents | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin).keys())))')"
  assert_eq "RC-X4: --settings に vault-write-gate ちょうど 1 件" "1" "$(count_vault_gate_entries "$(stub_settings_json)")"
  assert_eq "RC-X4: --allowedTools=Read" "Read" "$(stub_arg_after --allowedTools)"
}

echo "=== RC-X5. 実定義の全件: vault_declared_writable の真偽と child-settings の柵の件数が 1:1（AC-3 回帰） ==="
{
  new_fixture
  rcx5_n=0
  for f in "$REAL_AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    rcx5_n=$((rcx5_n + 1))
    role="${f##*/}"; role="${role%.md}"
    declared="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 -c 'import sys, agent_def; print(agent_def.vault_declared_writable(sys.argv[1], sys.argv[2]))' "$REAL_AGENTS_DIR" "$role" 2>&1)"
    run_child_settings "$role" "$REAL_AGENTS_DIR"
    assert_eq "RC-X5 $role: child-settings exit 0" "0" "$CS_RC"
    case "$declared" in
      True)  want=0 ;;
      False) want=1 ;;
      *)     want="(vault_declared_writable failed: $declared)" ;;
    esac
    assert_eq "RC-X5 $role: 宣言=$declared ↔ vault-write-gate エントリ $want 件" "$want" "$(count_vault_gate_entries "$CS_STDOUT")"
  done
  assert_true "RC-X5: 実定義が 1 件以上ある（空虚な真の禁止）" "$([ "$rcx5_n" -ge 1 ] && echo 1 || echo 0)"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
