#!/usr/bin/env bash
# tests/test-claude-bypass.sh — scripts/check-claude-bypass.sh のユニットテスト
# （設計-v1.1.1.md §6・§9.1・D-5・要件v1.4.3 FR-23・AC-13）。
#
# ⚠️ P1〜P3 の検査語（"claude" に隣接する "-p"／"--print"・実体パス直指定の
# 語・実体パスexport変数の語）は、ソース上に完成形の文字列として**コメント
# 中も含めて**書くと repo_scan_is_clean（repo本体の0件判定）を本ファイル
# 自身への自己ヒットで壊してしまう（本ファイルは除外リスト3件に含まれない
# ＝設計 notes §6 却下案「除外にtests/を足す」を踏まえ、陽性 fixture・
# メッセージ文字列とも実行時に分割・結合で組み立てる。
# tests/test-agent-definitions.sh の MCP_EXEC_PAT と同じ作法）。
#
# 実行方法: bash tests/test-claude-bypass.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/check-claude-bypass.sh"
GATE="$REPO_ROOT/claude/hooks/inprocess-gate.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# 検査語を分割・結合で組み立てる（自己ヒット防止。以後この変数だけを使う）
CLAUDE_WORD="cla"; CLAUDE_WORD="${CLAUDE_WORD}ude"
P_FLAG="-"; P_FLAG="${P_FLAG}p"
PRINT_FLAG="--"; PRINT_FLAG="${PRINT_FLAG}print"
EXE_WORD="${CLAUDE_WORD}"; EXE_WORD="${EXE_WORD}.exe"
EXECPATH_WORD="CLAUDE_CODE"; EXECPATH_WORD="${EXECPATH_WORD}_EXECPATH"

# 出力から「一致行」だけの件数を数える（除外表示の "除外 " 行・区切りの
# "---" 行を除く）。
count_nonexclusion_lines() {
  printf '%s\n' "$1" | grep -v '^除外 ' | grep -vc '^---$' || true
}

echo "=== repo_scan_is_clean: repo本体（既定=repoルート）は除外3件を適用したうえで0件 ==="
{
  out="$(cd "$REPO_ROOT" && bash "$DETECTOR" 2>&1)"; rc=$?
  n="$(count_nonexclusion_lines "$out")"
  if [ "$rc" -eq 0 ] && [ "${n:-1}" -eq 0 ]; then
    pass "repo_scan_is_clean: exit0・除外3件適用後は一致行0件"
  else
    fail_case "repo_scan_is_clean (rc=$rc n=$n out=[$out])"
  fi
}

echo "=== detector_has_execpath_and_exe_words: 検出コマンドの検査語がP2/P3の2語を含む（FR-23） ==="
{
  msg="check-claude-bypass.sh は ${EXE_WORD} と ${EXECPATH_WORD} を検査語に含む"
  if grep -qF "$EXE_WORD" "$DETECTOR" && grep -qF "$EXECPATH_WORD" "$DETECTOR"; then
    pass "$msg"
  else
    fail_case "$msg"
  fi
}

echo "=== positive_fixture_in_tmpdir_detected: 一時ディレクトリ指定の別実行でP1/P2/P3それぞれ検出される（AC-13①陽性はrepo本体と別実行＝V4-m2） ==="
{
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-bypass.XXXXXX")"
  printf '%s %s "hello"\n' "$CLAUDE_WORD" "$P_FLAG" > "$WORK/p1.sh"
  printf 'exec %s %s\n' "$EXE_WORD" "$PRINT_FLAG" > "$WORK/p2.sh"
  printf 'export %s=/opt/x/%s\n' "$EXECPATH_WORD" "$CLAUDE_WORD" > "$WORK/p3.sh"

  out="$(bash "$DETECTOR" "$WORK" 2>&1)"; rc=$?
  ok=1
  [ "$rc" -eq 1 ] || ok=0
  printf '%s\n' "$out" | grep -q "p1.sh:1:" || ok=0
  printf '%s\n' "$out" | grep -q "p2.sh:1:" || ok=0
  printf '%s\n' "$out" | grep -q "p3.sh:1:" || ok=0
  if [ "$ok" -eq 1 ]; then
    pass "positive_fixture_in_tmpdir_detected: P1/P2/P3すべて検出・exit1"
  else
    fail_case "positive_fixture_in_tmpdir_detected (rc=$rc out=[$out])"
  fi
  rm -rf "$WORK"
}

echo "=== negative_fixture_git_log_p_not_detected: git log -p claude/x.sh は検出しない（DR1-M4） ==="
{
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-bypass.XXXXXX")"
  printf 'git log %s %s/hooks/x.sh\n' "$P_FLAG" "$CLAUDE_WORD" > "$WORK/neg.sh"
  out="$(bash "$DETECTOR" "$WORK" 2>&1)"; rc=$?
  n="$(count_nonexclusion_lines "$out")"
  if [ "$rc" -eq 0 ] && [ "${n:-1}" -eq 0 ]; then
    pass "negative_fixture_git_log_p_not_detected: exit0・検出なし"
  else
    fail_case "negative_fixture_git_log_p_not_detected (rc=$rc n=$n out=[$out])"
  fi
  rm -rf "$WORK"
}

echo "=== exclusion_list_is_exactly_three: 除外はちょうど3件・各件がパスと理由つきで表示される（裁定C） ==="
{
  out="$(cd "$REPO_ROOT" && bash "$DETECTOR" 2>&1)"
  n="$(printf '%s\n' "$out" | grep -c '^除外 3 件＝' || true)"
  has_reason="$(printf '%s\n' "$out" | grep -Ec '^除外 3 件＝.+（.+）$' || true)"
  has_wrapper="$(printf '%s\n' "$out" | grep -Fc "scripts/claude-exec.sh" || true)"
  has_detector="$(printf '%s\n' "$out" | grep -Fc "scripts/check-claude-bypass.sh" || true)"
  has_probe="$(printf '%s\n' "$out" | grep -Fc "scripts/experiments/worker-provider-probe.sh" || true)"
  if [ "${n:-0}" -eq 3 ] && [ "${has_reason:-0}" -eq 3 ] \
     && [ "${has_wrapper:-0}" -ge 1 ] && [ "${has_detector:-0}" -ge 1 ] && [ "${has_probe:-0}" -ge 1 ]; then
    pass "exclusion_list_is_exactly_three: 3件・各件にパスと理由・固定3対象を含む"
  else
    fail_case "exclusion_list_is_exactly_three (n=$n has_reason=$has_reason wrapper=$has_wrapper detector=$has_detector probe=$has_probe)"
  fi
}

echo "=== audit_has_no_allowed_for_role_present: 監査イベントに role_present=true かつ decision=allowed の行が無い（FR-23②） ==="
{
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-bypass.XXXXXX")"
  BASE="$WORK/base"; mkdir -p "$BASE"
  cat > "$BASE/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: fixture-bypass
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.implementer: configured model=sonnet-noeffort
---
EOF
  cat > "$BASE/models.conf" <<'EOF'
[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5
EOF
  AUDIT="$WORK/audit.jsonl"

  # role_present=true になる職種（implementer）と role_present=false になる
  # 職種（配役表に行が無い general-purpose）の両方を通す。
  for role in implementer general-purpose; do
    printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s"}}' "$role" \
      | env -u AIENV_PYTHON_BIN AIENV_MODEL_DEFS_FILE="$BASE/models.conf" \
          AIENV_LOCAL_PROFILE_PATH="$BASE/profile.md" AIENV_INPROCESS_AUDIT_LOG="$AUDIT" \
          /bin/bash "$GATE" >/dev/null 2>/dev/null
  done

  if [ -f "$AUDIT" ]; then
    bad="$(python3 - "$AUDIT" <<'PY'
import json, sys
bad = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("role_present") is True and obj.get("decision") == "allowed":
            bad += 1
print(bad)
PY
)"
    lines_n="$(wc -l < "$AUDIT" | tr -d ' ')"
  else
    bad="MISSING"
    lines_n="0"
  fi

  if [ "${bad:-1}" = "0" ] && [ "${lines_n:-0}" = "2" ]; then
    pass "audit_has_no_allowed_for_role_present: 監査2行とも role_present=true∧decision=allowed の組は0件"
  else
    fail_case "audit_has_no_allowed_for_role_present (bad=$bad lines=$lines_n)"
  fi
  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
