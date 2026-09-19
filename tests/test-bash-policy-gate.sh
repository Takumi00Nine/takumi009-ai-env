#!/usr/bin/env bash
# claude/hooks/bash-policy-gate.sh のユニットテスト（ラフ＝規則ごとに陽性 1・陰性 1
# ＋不正入力 1。値の一致は deny 理由の先頭語だけ）。
#
# 実 ~/.claude・実Vaultには一切依存しない。PreToolUse フックの実際の呼び出し
# 形式＝`{"tool_input":{"command":"..."}}` を jq で組み立てて標準入力から渡し、
# 標準出力の deny JSON の有無・理由文の先頭語で判定する（フックは deny の場合も
# 含め常に `exit 0` を返す契約＝bash-danger-gate と同じ。exit code では判定
# できない）。様式は tests/test-bash-danger-gate.sh に合わせる。
#
# 2026-09-19 段3-5 τ: settings.json の inline 3 本（公開ガード・pip 仮想環境・
# brew ランタイム）を 1 ファイルへ移した際に新設。判定式と deny 文面は inline
# から verbatim＝ここで固定するのは「規則が発火する／しない」の形だけ。
#
# 実行方法: bash tests/test-bash-policy-gate.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/bash-policy-gate.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# フックへ JSON 入力を渡して標準出力を返す。R2 は環境変数 VIRTUAL_ENV／
# CONDA_PREFIX で許可側へ倒れるため、テスト実行元のシェルの値を外して渡す。
run_hook() {
  local cmd="$1"
  jq -n --arg cmd "$cmd" '{tool_input:{command:$cmd}}' \
    | env -u VIRTUAL_ENV -u CONDA_PREFIX bash "$HOOK"
}

assert_allowed() {
  local desc="$1" cmd="$2" out
  out="$(run_hook "$cmd")"
  if [ -z "$out" ]; then
    pass "$desc"
  else
    fail_case "$desc (denyされてしまった。cmd=[$cmd] out=[$out])"
  fi
}

# reason_substr＝deny 理由の先頭語（別規則の誤発火を見分けるためだけ）。
assert_denied() {
  local desc="$1" cmd="$2" reason_substr="${3:-}" out
  out="$(run_hook "$cmd")"
  if ! printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    fail_case "$desc (denyされなかった。cmd=[$cmd] out=[$out])"
    return
  fi
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    fail_case "$desc (deny 出力が JSON として不正。out=[$out])"
    return
  fi
  if [ -n "$reason_substr" ] && ! printf '%s' "$out" | grep -qF "$reason_substr"; then
    fail_case "$desc (denyされたが想定と別ルールが発火した可能性。cmd=[$cmd] out=[$out])"
    return
  fi
  pass "$desc"
}

echo "=== 1. R1 公開ガード: gh repo create --public は deny・--private は allow ==="
assert_denied "gh repo create foo --public は deny" "gh repo create foo --public" "リポジトリの公開"
assert_allowed "gh repo create foo --private は allow" "gh repo create foo --private"

echo "=== 2. R2 pip 仮想環境: 素の pip install は deny・venv 明示パス／uv pip は allow ==="
assert_denied "pip install requests は deny" "pip install requests" "グローバルへの直接pip"
assert_allowed ".venv/bin/pip install requests は allow（明示パス）" ".venv/bin/pip install requests"
assert_allowed "uv pip install x は allow（uv は対象外）" "uv pip install x"

echo "=== 3. R3 brew ランタイム: brew install python@3.12 は deny・brew install jq は allow ==="
assert_denied "brew install python@3.12 は deny" "brew install python@3.12" "言語ランタイム"
assert_allowed "brew install jq は allow" "brew install jq"

echo "=== 4. 不正入力: 空 stdin・tool_input 欠落 → 無出力 exit 0（fail-silent） ==="
out="$(printf '' | env -u VIRTUAL_ENV -u CONDA_PREFIX bash "$HOOK")"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  pass "空 stdin は無出力 exit 0"
else
  fail_case "空 stdin で出力または非 0 (rc=$rc out=[$out])"
fi
out="$(printf '{"tool_name":"Bash"}' | env -u VIRTUAL_ENV -u CONDA_PREFIX bash "$HOOK")"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  pass "tool_input 欠落は無出力 exit 0"
else
  fail_case "tool_input 欠落で出力または非 0 (rc=$rc out=[$out])"
fi

echo "=== 5. bash 3.2 互換の静的検査 ==="
if /bin/bash -n "$HOOK"; then
  pass "/bin/bash -n が通る（macOS bash 3.2 互換）"
else
  fail_case "/bin/bash -n が通る（macOS bash 3.2 互換）"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
