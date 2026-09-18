#!/bin/bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
GUARD="$REPO_ROOT/claude/hooks/agent-model-guard.sh"
SETTINGS="$REPO_ROOT/claude/settings.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-model-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
RUN_RC=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# D-2（設計v1.2 §3.2・（ガード側）テスト戦略）: マーカー置き場をWORK配下へ
# 隔離する（実`/tmp`へ書かせない）。delegation-gate-v2.shと同名の環境変数
# GATE_MARKER_DIRで1変数だけ差し替える。
MARKER_DIR="$WORK/markers"
mkdir -p "$MARKER_DIR"

run_guard() {
  # 締めレビュー1巡目 #1対応: ホスト環境に偶然 CLAUDE_CODE_SUBAGENT_MODEL_FORCE /
  # CLAUDE_CODE_SUBAGENT_MODEL が残っていると、新設したEF検査以外の既存ケース
  # まで巻き込まれて不安定化するため、ベースライン実行では両方を明示的に外す。
  input=$1
  out_file=$2
  err_file=$3
  RUN_RC=0
  printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" /bin/bash "$GUARD" >"$out_file" 2>"$err_file" || RUN_RC=$?
}

run_guard_env() {
  # EF-01/02専用: 対象の環境変数だけを1件指定してguardを実行する（他方は
  # ホスト環境からの漏れを防ぐため明示的に外す）。
  input=$1
  out_file=$2
  err_file=$3
  var_assign=$4
  RUN_RC=0
  printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" "$var_assign" /bin/bash "$GUARD" >"$out_file" 2>"$err_file" || RUN_RC=$?
}

assert_pass_case() {
  label=$1
  out_file=$2
  err_file=$3
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$out_file" ] && [ ! -s "$err_file" ]; then
    pass "$label"
  else
    fail_case "$label"
  fi
}

assert_deny_case() {
  label=$1
  out_file=$2
  err_file=$3
  expected_reason=$4
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$err_file" ] && python3 - "$out_file" "$expected_reason" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
assert raw.endswith(b"\n") and raw.count(b"\n") == 1
assert json.loads(raw) == {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": sys.argv[2],
    }
}
PY
  then
    pass "$label"
  else
    fail_case "$label"
  fi
}

base='{"tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","description":"model guard smoke","prompt":"Reply GD-ID only; do not use tools.","name":"opus-requirements-analyst"'

echo "=== GD-01〜05: Agent入力の通過・拒否 ==="
run_guard "$base,"'"model":"opus"}}' "$WORK/gd01.out" "$WORK/gd01.err"
assert_pass_case "GD-01 model=opusはexit 0・stdout/stderr空" "$WORK/gd01.out" "$WORK/gd01.err"

run_guard "$base}}" "$WORK/gd02.out" "$WORK/gd02.err"
assert_deny_case "GD-02 欠落をexit 0の完全なdeny JSONで拒否" "$WORK/gd02.out" "$WORK/gd02.err" 'MODEL_ARGUMENT_REQUIRED: resolve-candidate の AGENT_MODEL を Agent.model に明示してください。'

run_guard "$base,"'"model":""}}' "$WORK/gd03.out" "$WORK/gd03.err"
assert_deny_case "GD-03 空文字をexit 0の完全なdeny JSONで拒否" "$WORK/gd03.out" "$WORK/gd03.err" 'MODEL_ARGUMENT_INVALID: Agent.model は resolve-candidate が返した4別名のいずれかを明示してください。'

run_guard "$base,"'"model":"claude-opus-5"}}' "$WORK/gd04.out" "$WORK/gd04.err"
assert_deny_case "GD-04 具体IDをexit 0の完全なdeny JSONで拒否" "$WORK/gd04.out" "$WORK/gd04.err" 'MODEL_ARGUMENT_INVALID: Agent.model は resolve-candidate が返した4別名のいずれかを明示してください。'

run_guard '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}' "$WORK/gd05.out" "$WORK/gd05.err"
assert_pass_case "GD-05 対象外職種はexit 0・stdout/stderr空" "$WORK/gd05.out" "$WORK/gd05.err"

echo "=== GD-06: settings matcherはBashをdispatchしない ==="
python3 - "$SETTINGS" <<'PY' && pass "GD-06 ^Agent$ matcherはBashに不一致" || fail_case "GD-06 ^Agent$ matcherはBashに不一致"
import json,re,sys
d=json.load(open(sys.argv[1]))
entries=[e for e in d['hooks']['PreToolUse'] if any(h.get('command','').endswith('/agent-model-guard.sh') for h in e['hooks'])]
assert len(entries)==1 and entries[0]['matcher']=='^Agent$'
assert re.search(entries[0]['matcher'],'Bash') is None
PY

echo "=== 対象8職種・許容4別名の設定一致 ==="
for role in adoption-critic implementer operator requirements-analyst researcher system-designer vault-scribe verifier; do
  run_guard "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$role\",\"model\":\"opus\"}}" "$WORK/role.out" "$WORK/role.err"
  assert_pass_case "$role がexit 0・無出力で正常値を通過" "$WORK/role.out" "$WORK/role.err"
done
for alias in fable opus sonnet haiku; do
  run_guard "$base,\"model\":\"$alias\"}}" "$WORK/alias.out" "$WORK/alias.err"
  assert_pass_case "$alias がexit 0・無出力で通過" "$WORK/alias.out" "$WORK/alias.err"
done

echo "=== EF-01〜02: CLAUDE_CODE_SUBAGENT_MODEL_FORCE 環境変数の検査（締めレビュー1巡目 #1対応） ==="
run_guard_env "$base,"'"model":"opus"}}' "$WORK/ef01.out" "$WORK/ef01.err" "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1"
assert_deny_case "EF-01 FORCE=1設定時はmodel指定済みでもexit 0の完全なdeny JSONで拒否" "$WORK/ef01.out" "$WORK/ef01.err" 'MODEL_ENV_OVERRIDE_FORBIDDEN: 環境変数 CLAUDE_CODE_SUBAGENT_MODEL_FORCE が設定されています。Agent.model の指定を上書きする可能性があるため、解除してから再実行してください。'

run_guard_env "$base,"'"model":"opus"}}' "$WORK/ef02.out" "$WORK/ef02.err" "CLAUDE_CODE_SUBAGENT_MODEL=haiku"
assert_pass_case "EF-02 CLAUDE_CODE_SUBAGENT_MODEL（非FORCE）のみ設定時はexit 0・無出力で従来どおり通過" "$WORK/ef02.out" "$WORK/ef02.err"

echo "=== HF-01〜04: 入力契約・依存障害は固定ERROR deny ==="
check_error() {
  label=$1 input=$2 cause=$3
  run_guard "$input" "$WORK/hf.out" "$WORK/hf.err"
  expected="MODEL_GUARD_ERROR: cause=$cause; model 指定を検査できません。フックの入力と配置を確認してください。"
  assert_deny_case "$label はexit 0の完全なdeny JSON" "$WORK/hf.out" "$WORK/hf.err" "$expected"
}
check_error HF-01a '{' JQ_FAILED
check_error HF-01b '{"tool_input":{}}' TOOL_NAME_MISSING
check_error HF-01c '{"tool_name":null,"tool_input":{}}' TOOL_NAME_NULL
check_error HF-01d '{"tool_name":"","tool_input":{}}' TOOL_NAME_EMPTY
check_error HF-01e '{"tool_name":1,"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01f '{"tool_name":true,"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01g '{"tool_name":[],"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01h '{"tool_name":{},"tool_input":{}}' TOOL_NAME_TYPE
check_error HF-01i '{"tool_name":"Task","tool_input":{}}' TOOL_NAME_UNEXPECTED
check_error HF-01j '{"tool_name":"Bash","tool_input":{"command":"true"}}' TOOL_NAME_UNEXPECTED
check_error HF-02 '' INPUT_INVALID

# 検証1巡目 I1-B1 対応: guard自身のsymlink解決（resolve_agent_model_guard_
# self_dir）がdirname/readlinkをPATH経由で呼ぶようになったため、「jqだけが
# 無い」を再現するにはPATHを空にせずdirname/readlink/catは残す必要がある
# （空PATHのままだとSELF_DIR_UNRESOLVABLEに倒れてしまいHF-03の意図＝
# JQ_UNAVAILABLEを検証できない）。
mkdir -p "$WORK/no-jq"
for _hf03_tool in cat dirname readlink; do
  _hf03_bin="$(command -v "$_hf03_tool" 2>/dev/null || true)"
  [ -n "$_hf03_bin" ] && ln -sf "$_hf03_bin" "$WORK/no-jq/$_hf03_tool"
done
RUN_RC=0
PATH="$WORK/no-jq" /bin/bash "$GUARD" <<<'{}' >"$WORK/hf03.out" 2>"$WORK/hf03.err" || RUN_RC=$?
assert_deny_case "HF-03 jq不在はexit 0の完全なdeny JSON" "$WORK/hf03.out" "$WORK/hf03.err" 'MODEL_GUARD_ERROR: cause=JQ_UNAVAILABLE; model 指定を検査できません。フックの入力と配置を確認してください。'

mkdir "$WORK/stub"
printf '#!/bin/bash\nexit 1\n' > "$WORK/stub/jq"
chmod +x "$WORK/stub/jq"
RUN_RC=0
printf '{}' | PATH="$WORK/stub:/bin:/usr/bin" /bin/bash "$GUARD" >"$WORK/hf04.out" 2>"$WORK/hf04.err" || RUN_RC=$?
assert_deny_case "HF-04 jq非0はexit 0の完全なdeny JSON" "$WORK/hf04.out" "$WORK/hf04.err" 'MODEL_GUARD_ERROR: cause=JQ_FAILED; model 指定を検査できません。フックの入力と配置を確認してください。'

echo "=== D2-G1〜G3: 委任実績マーカー（設計v1.2 §3.1〜§3.2・OQ-4案B・（ガード側）テスト戦略） ==="
marker_base='{"session_id":"sess-marker-test","tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","description":"model guard marker smoke","prompt":"Reply GD-ID only; do not use tools.","name":"opus-requirements-analyst"'
MARKER_FILE="$MARKER_DIR/claude-delegated-ok-sess-marker-test"

rm -f "$MARKER_FILE"
run_guard "$marker_base,"'"model":"opus"}}' "$WORK/d2g1.out" "$WORK/d2g1.err"
if [ "$RUN_RC" -eq 0 ] && [ -f "$MARKER_FILE" ]; then
  pass "D2-G1 PASS分岐でセッション固有マーカーが作られる"
else
  fail_case "D2-G1 PASS分岐でセッション固有マーカーが作られる"
fi

rm -f "$MARKER_FILE"
run_guard "$marker_base}}" "$WORK/d2g2.out" "$WORK/d2g2.err"
if [ ! -f "$MARKER_FILE" ]; then
  pass "D2-G2 deny(REQUIRED)分岐ではマーカーが作られない"
else
  fail_case "D2-G2 deny(REQUIRED)分岐ではマーカーが作られない"
fi

rm -f "$MARKER_FILE"
run_guard '{"session_id":"sess-marker-test","tool_name":"Bad"}' "$WORK/d2g3.out" "$WORK/d2g3.err"
if [ ! -f "$MARKER_FILE" ]; then
  pass "D2-G3 guard_error(TOOL_NAME_UNEXPECTED)分岐ではマーカーが作られない"
else
  fail_case "D2-G3 guard_error(TOOL_NAME_UNEXPECTED)分岐ではマーカーが作られない"
fi

echo "=== AC-10②: alias_literal_only_in_guard_common（許容別名の集合はguard_common.shにしか無い・NFR-7） ==="
{
  GUARD_COMMON="$REPO_ROOT/claude/hooks/lib/guard_common.sh"
  DELEGATION_GATE="$REPO_ROOT/claude/hooks/delegation-gate-v2.sh"
  VAULT_GATE="$REPO_ROOT/claude/hooks/vault-write-gate.sh"
  CLAUDE_EXEC="$REPO_ROOT/scripts/claude-exec.sh"

  # guard_common.sh が正本を持つ（4別名すべてが1関数内に揃っている）
  if grep -qE 'fable[^\n]*opus[^\n]*sonnet[^\n]*haiku' "$GUARD_COMMON"; then
    pass "guard_common.sh が4別名（fable/opus/sonnet/haiku）の正本を持つ"
  else
    fail_case "guard_common.sh が4別名（fable/opus/sonnet/haiku）の正本を持つ"
  fi

  # agent-model-guard.sh・delegation-gate-v2.sh・vault-write-gate.sh には
  # 別名の複製（4語すべてが同一ファイルに揃う形）が無い。scripts/claude-exec.sh
  # は担当A が並行実装中で本テスト実行時点に存在しないことがあるため、
  # 存在するときだけ同じ検査を掛ける。
  dup=0
  for f in "$GUARD" "$DELEGATION_GATE" "$VAULT_GATE"; do
    grep -qE 'fable[^\n]*opus[^\n]*sonnet[^\n]*haiku' "$f" && dup=1
  done
  if [ -f "$CLAUDE_EXEC" ]; then
    grep -qE 'fable[^\n]*opus[^\n]*sonnet[^\n]*haiku' "$CLAUDE_EXEC" && dup=1
  fi
  if [ "$dup" -eq 0 ]; then
    pass "agent-model-guard.sh・delegation-gate-v2.sh・vault-write-gate.sh（・存在すればラッパー）に4別名の複製が無い"
  else
    fail_case "agent-model-guard.sh・delegation-gate-v2.sh・vault-write-gate.sh（・存在すればラッパー）に4別名の複製が無い"
  fi

  # マーカー名の規則（claude-delegated-ok-）を組み立てる関数はguard_common.sh
  # にしか定義が無い（agent-model-guard.shはguard_mark_delegationを呼ぶだけ）
  marker_fn_defs="$(grep -l 'guard_marker_path()' "$GUARD_COMMON" "$GUARD" "$VAULT_GATE" 2>/dev/null | wc -l | tr -d ' ')"
  guard_calls_shared="$(grep -c 'guard_mark_delegation\|guard_allowed_model_aliases\|guard_is_allowed_model_alias' "$GUARD" 2>/dev/null || true)"
  if [ "${marker_fn_defs:-9}" -eq 1 ] && [ "${guard_calls_shared:-0}" -ge 1 ]; then
    pass "マーカー名の組み立て関数はguard_common.shにしか定義されず・agent-model-guard.shは共有関数を呼ぶだけ"
  else
    fail_case "マーカー名の組み立て関数はguard_common.shにしか定義されず・agent-model-guard.shは共有関数を呼ぶだけ (defs=$marker_fn_defs calls=$guard_calls_shared)"
  fi

  # guard_allowed_model_aliases の集合 ＝ profile_resolve.py の
  # AGENT_MODEL_ALIASES の値集合（設計-v1.1.1.md §3 末尾）
  guard_set="$(bash -c 'source "$0"; guard_allowed_model_aliases' "$GUARD_COMMON" | tr ' ' '\n' | sort | paste -sd ',' -)"
  py_set="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 -c 'import profile_resolve as pr; print(",".join(sorted(set(pr.AGENT_MODEL_ALIASES.values()))))')"
  assert_eq_local() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail_case "$3 (guard=[$1] profile_resolve=[$2])"; fi
  }
  assert_eq_local "$guard_set" "$py_set" "guard_allowed_model_aliasesの値集合＝profile_resolve.pyのAGENT_MODEL_ALIASESの値集合"
}

echo "=== AC-10②(裁定A): vault_folders_literal_only_in_guard_common（Vault6フォルダの判定literalはguard_common.shにしか無い） ==="
{
  GUARD_COMMON="$REPO_ROOT/claude/hooks/lib/guard_common.sh"
  DELEGATION_GATE="$REPO_ROOT/claude/hooks/delegation-gate-v2.sh"
  VAULT_GATE="$REPO_ROOT/claude/hooks/vault-write-gate.sh"

  # guard_common.sh のguard_vault_ai_prefixesが6フォルダすべての正本を持つ
  # （printfの複数引数に分かれているため複数行にまたがる＝1関数の本文
  # 全体をawkで抜き出してから6語すべての出現を見る）
  fn_body="$(awk '/^guard_vault_ai_prefixes\(\)/{f=1} f{print} f&&/^}/{exit}' "$GUARD_COMMON")"
  folders_ok=1
  for name in Fragments Knowledge Decisions Projects Preferences Personal; do
    printf '%s' "$fn_body" | grep -qF "$name" || folders_ok=0
  done
  if [ "$folders_ok" -eq 1 ]; then
    pass "guard_common.sh がVault6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）の正本を持つ"
  else
    fail_case "guard_common.sh がVault6フォルダの正本を持つ"
  fi

  # delegation-gate-v2.sh・vault-write-gate.shは、6フォルダを判定する
  # 独自のcase/esacブロック（判定listの複製）を持たない。判定は
  # guard_is_vault_ai_pathの呼び出しに委ねている（デリー文面のプレーン
  # テキストに6フォルダ名が現れること自体は変えない契約＝振る舞い不変。
  # ここで見るのは「パターンマッチのための複製」の有無）。
  dup_check="$(python3 - "$DELEGATION_GATE" "$VAULT_GATE" <<'PY'
import re, sys
FOLDERS = ["Fragments", "Knowledge", "Decisions", "Projects", "Preferences", "Personal"]
bad = 0
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r"case\b.*?\besac\b", text, re.S):
        block = m.group(0)
        n = sum(1 for f in FOLDERS if f in block)
        if n >= 2:
            bad += 1
print(bad)
PY
)"
  if [ "${dup_check:-1}" -eq 0 ]; then
    pass "delegation-gate-v2.sh・vault-write-gate.shに6フォルダ判定のcase/esac複製が無い"
  else
    fail_case "delegation-gate-v2.sh・vault-write-gate.shに6フォルダ判定のcase/esac複製が無い (bad=$dup_check)"
  fi

  # 両ファイルが共有関数 guard_is_vault_ai_path を呼んでいる
  calls_ok=1
  grep -q 'guard_is_vault_ai_path' "$DELEGATION_GATE" || calls_ok=0
  grep -q 'guard_is_vault_ai_path' "$VAULT_GATE" || calls_ok=0
  if [ "$calls_ok" -eq 1 ]; then
    pass "delegation-gate-v2.sh・vault-write-gate.shがguard_is_vault_ai_pathを呼ぶ"
  else
    fail_case "delegation-gate-v2.sh・vault-write-gate.shがguard_is_vault_ai_pathを呼ぶ"
  fi
}

echo "=== I1-M3(検証1巡目・I1-B1回帰防止): symlink経由の起動でもagent-model-guard.shの結果がrepoパス直叩きと一致する ==="
{
  # installerはこの3フックを1本ずつ $HOME/.claude/hooks/<名前>.sh
  # （repoへのsymlink）として配置し、$HOME/.claude/hooks/lib/ は作らない。
  # その実経路を一時ディレクトリで再現する（symlinkのみを置き、隣にlib/を
  # 作らない）。guard_common.shが実経路で解決できないと、PASS期待の入力が
  # INVALID/REQUIREDへ倒れ、マーカーも作られない（I1-B1の実害そのもの）。
  LINK_DIR="$WORK/linked-hooks"
  mkdir -p "$LINK_DIR"
  ln -s "$GUARD" "$LINK_DIR/agent-model-guard.sh"

  run_via_link() {
    input=$1; out_file=$2; err_file=$3
    RUN_RC=0
    printf '%s' "$input" | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" /bin/bash "$LINK_DIR/agent-model-guard.sh" >"$out_file" 2>"$err_file" || RUN_RC=$?
  }

  # PASS系（有効な別名）: symlink経由でもexit 0・無出力・委任実績マーカーが作られる
  SYMLINK_MARKER="$MARKER_DIR/claude-delegated-ok-sess-symlink-b1"
  rm -f "$SYMLINK_MARKER"
  pass_input='{"session_id":"sess-symlink-b1","tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","description":"symlink smoke","prompt":"Reply GD-ID only; do not use tools.","name":"opus-requirements-analyst","model":"opus"}}'
  run_via_link "$pass_input" "$WORK/symlink-pass.out" "$WORK/symlink-pass.err"
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/symlink-pass.out" ] && [ ! -s "$WORK/symlink-pass.err" ] && [ -f "$SYMLINK_MARKER" ]; then
    pass "I1-M3: symlink経由のPASS(有効別名)がrepoパス直叩きと同じくexit 0・無出力・マーカー作成"
  else
    fail_case "I1-M3: symlink経由のPASS(有効別名)がrepoパス直叩きと不一致 (rc=$RUN_RC out=[$(cat "$WORK/symlink-pass.out" 2>/dev/null)] err=[$(cat "$WORK/symlink-pass.err" 2>/dev/null)] marker=$([ -f "$SYMLINK_MARKER" ] && echo あり || echo なし)"
  fi

  # deny系（model欠落）: symlink経由でもrepoパス直叩きと同じ理由文で拒否される
  # （guard_common.sh未解決によるMODEL_GUARD_ERRORへの後退が無いことを見る）
  deny_input='{"session_id":"sess-symlink-b1-deny","tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","description":"symlink smoke","prompt":"Reply GD-ID only; do not use tools.","name":"opus-requirements-analyst"}}'
  run_via_link "$deny_input" "$WORK/symlink-deny.out" "$WORK/symlink-deny.err"
  assert_deny_case "I1-M3: symlink経由のdeny(model欠落)がrepoパス直叩きと同じ理由(MODEL_ARGUMENT_REQUIRED)" "$WORK/symlink-deny.out" "$WORK/symlink-deny.err" 'MODEL_ARGUMENT_REQUIRED: resolve-candidate の AGENT_MODEL を Agent.model に明示してください。'
}

echo "=== I1-M3(検証1巡目・vault-write-gate.sh・test-claude-exec.shには入れずここに置く): symlink経由の起動でもrepoパス直叩きと結果が一致する ==="
{
  # vault-write-gate.shは設計§9.1の vault_gate_denies_ai_folders が
  # tests/test-claude-exec.sh の担当だが、同ファイルは担当Cの担当範囲外
  # （tests/test-claude-exec.shは触らない）のため、symlink回帰ケースは
  # ここへ置く（リーダー裁定）。
  VAULT_GATE="$REPO_ROOT/claude/hooks/vault-write-gate.sh"
  VG_LINK_DIR="$WORK/linked-vault-hooks"
  mkdir -p "$VG_LINK_DIR"
  ln -s "$VAULT_GATE" "$VG_LINK_DIR/vault-write-gate.sh"
  VG_HOME="$WORK/vg-home"
  mkdir -p "$VG_HOME"

  run_vault_gate() {
    hook_path=$1; input=$2; out_file=$3
    rc=0
    printf '%s' "$input" | HOME="$VG_HOME" /bin/bash "$hook_path" >"$out_file" 2>"$WORK/vg.err" || rc=$?
    echo "$rc"
  }

  ai_fpath="$VG_HOME/Data/obsidian/Knowledge/note.md"
  ai_input="{\"tool_input\":{\"file_path\":\"$ai_fpath\"},\"cwd\":\"$WORK\"}"
  direct_rc="$(run_vault_gate "$VAULT_GATE" "$ai_input" "$WORK/vg-direct.out")"
  link_rc="$(run_vault_gate "$VG_LINK_DIR/vault-write-gate.sh" "$ai_input" "$WORK/vg-link.out")"
  if [ "$direct_rc" = "0" ] && [ "$link_rc" = "0" ] \
     && grep -q '"permissionDecision": "deny"' "$WORK/vg-direct.out" \
     && diff -q "$WORK/vg-direct.out" "$WORK/vg-link.out" >/dev/null 2>&1; then
    pass "I1-M3: vault-write-gate.shはsymlink経由でもAI向け6フォルダ配下のEditをrepoパス直叩きと同じdeny JSONで拒否"
  else
    fail_case "I1-M3: vault-write-gate.sh symlink経由のdenyがrepoパス直叩きと不一致 (direct_rc=$direct_rc link_rc=$link_rc)"
  fi

  outside_fpath="$WORK/project/file.md"
  outside_input="{\"tool_input\":{\"file_path\":\"$outside_fpath\"},\"cwd\":\"$WORK\"}"
  direct_rc2="$(run_vault_gate "$VAULT_GATE" "$outside_input" "$WORK/vg-direct2.out")"
  link_rc2="$(run_vault_gate "$VG_LINK_DIR/vault-write-gate.sh" "$outside_input" "$WORK/vg-link2.out")"
  if [ "$direct_rc2" = "0" ] && [ "$link_rc2" = "0" ] \
     && [ ! -s "$WORK/vg-direct2.out" ] && [ ! -s "$WORK/vg-link2.out" ]; then
    pass "I1-M3: vault-write-gate.shはsymlink経由でも6フォルダ配下外は無出力で素通し（repoパス直叩きと一致）"
  else
    fail_case "I1-M3: vault-write-gate.sh symlink経由の素通しがrepoパス直叩きと不一致 (direct_rc=$direct_rc2 link_rc=$link_rc2)"
  fi
}

echo "=== I2-m5(検証2巡目): source失敗時のfail-close分岐そのものに恒久テストを足す（lib/を持たない実体ディレクトリへフックをコピーして起動） ==="
{
  # I2-M2でenv上書き口（GUARD_COMMON_LIB）を撤去したため、source失敗を
  # 再現する手段は「lib/を持たない場所へフック本体だけをコピーして実行する」
  # 方式に一本化する（symlinkだと自身の実体を辿ってlib/を見つけてしまい
  # source失敗を再現できない＝コピーでなければならない）。

  # agent-model-guard.sh: lib/無しでコピー起動するとdeny(GUARD_COMMON_UNREADABLE)・exit 0（素通しにならない）
  NOLIB_DIR="$WORK/nolib-agent-model-guard"
  mkdir -p "$NOLIB_DIR"
  cp "$GUARD" "$NOLIB_DIR/agent-model-guard.sh"
  RUN_RC=0
  printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"requirements-analyst","model":"opus"}}' \
    | env -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE -u CLAUDE_CODE_SUBAGENT_MODEL GATE_MARKER_DIR="$MARKER_DIR" /bin/bash "$NOLIB_DIR/agent-model-guard.sh" \
    >"$WORK/nolib-guard.out" 2>"$WORK/nolib-guard.err" || RUN_RC=$?
  if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/nolib-guard.err" ] \
     && grep -q '"permissionDecision":"deny"' "$WORK/nolib-guard.out" \
     && grep -q 'GUARD_COMMON_UNREADABLE' "$WORK/nolib-guard.out"; then
    pass "I2-m5: agent-model-guard.shはlib/が無いとfail-close（deny・GUARD_COMMON_UNREADABLE・exit 0）で素通ししない"
  else
    fail_case "I2-m5: agent-model-guard.shのfail-closeが働かない (rc=$RUN_RC out=[$(cat "$WORK/nolib-guard.out" 2>/dev/null)] err=[$(cat "$WORK/nolib-guard.err" 2>/dev/null)])"
  fi

  # vault-write-gate.sh: lib/無しでコピー起動するとdeny(GUARD_COMMON_UNREADABLE)・exit 0（素通しにならない）
  VAULT_GATE="$REPO_ROOT/claude/hooks/vault-write-gate.sh"
  NOLIB_VG_DIR="$WORK/nolib-vault-write-gate"
  mkdir -p "$NOLIB_VG_DIR"
  cp "$VAULT_GATE" "$NOLIB_VG_DIR/vault-write-gate.sh"
  RUN_RC=0
  printf '%s' '{"tool_input":{"file_path":"/tmp/whatever.md"},"cwd":"/tmp"}' \
    | /bin/bash "$NOLIB_VG_DIR/vault-write-gate.sh" \
    >"$WORK/nolib-vg.out" 2>"$WORK/nolib-vg.err" || RUN_RC=$?
  if [ "$RUN_RC" -eq 0 ] \
     && grep -q '"permissionDecision": "deny"' "$WORK/nolib-vg.out" \
     && grep -q 'GUARD_COMMON_UNREADABLE' "$WORK/nolib-vg.out"; then
    pass "I2-m5: vault-write-gate.shはlib/が無いとfail-close（deny・GUARD_COMMON_UNREADABLE・exit 0）で素通ししない"
  else
    fail_case "I2-m5: vault-write-gate.shのfail-closeが働かない (rc=$RUN_RC out=[$(cat "$WORK/nolib-vg.out" 2>/dev/null)] err=[$(cat "$WORK/nolib-vg.err" 2>/dev/null)])"
  fi
}

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
