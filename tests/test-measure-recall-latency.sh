#!/usr/bin/env bash
# scripts/vault-agents/measure_recall_latency.py のユニットテスト（AC4性能計測ツール）。
#
# 実物のclaude/hooks/vault-recall.shをsubprocessで実際に叩く方針（recall_bench.pyと
# 同じ）。--disable-vectorでベクトル想起(Ollama依存)を無効化し、実Ollama・実インデックス
# に一切依存せず完結させる。fail-open検出のテストのみ、fixtureの偽hook（bashスクリプト）
# でVAULT_RECALL_LOGへERROR行/ハートビート行を直接書かせて模す。
#
# 実行方法: bash tests/test-measure-recall-latency.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/measure_recall_latency.py"
HOOK="$REPO_ROOT/claude/hooks/vault-recall.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\")"; fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
}

write_note() {
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  { echo "---"; printf '%s\n' "$fm"; echo "---"; echo; printf '%s\n' "$body"; } > "$path"
}

echo "=== 1. 基本動作: 実フック(キーワードのみモード)で正常計測できる・fail-open除外0件 ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/hit-note.md" $'date: 2026-07-10\naliases:\n  - "hitkeyword12345"'

  BENCH="$(mktemp)"
  {
    printf 'hitkeyword12345について確認したい、十分な長さのプロンプトです\tKnowledge/hit-note.md\n'
    printf '全く関係ない話題について質問したいです\tKnowledge/nonexistent-note.md\n'
  } > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" --disable-vector --cold-runs 0 --json 2>/dev/null)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  warm_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['warm']['count'])")"
  fail_open_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['fail_open_excluded']))")"
  assert_eq "2件ともwarmバケットへ計測される" "2" "$warm_count"
  assert_eq "fail-open除外は0件" "0" "$fail_open_count"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo "=== 2. fail-open検出: フックがERROR行を残した計測はcold/warmから除外され別枠で報告される（Codexレビュー指摘・Major対応: 性能計測の偽装通過防止） ==="
{
  FAKE_HOOK="$(mktemp)"
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
cat >/dev/null
mkdir -p "$(dirname "$VAULT_RECALL_LOG")" 2>/dev/null
printf '%s\tERROR\t\ts1\t模擬的なfail-open(Ollama不通)です\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT_RECALL_LOG"
exit 0
HOOKEOF
  chmod +x "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 --json 2>/dev/null)"
  rc=$?
  assert_eq "fail-open検出時はexit 2（測定失敗の可視化）" "2" "$rc"
  warm_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['warm']['count'])")"
  fail_open_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['fail_open_excluded']))")"
  fail_open_msg="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['fail_open_excluded'][0]['messages'][0])")"
  assert_eq "fail-open計測はwarmバケットに計上されない（rc=0でも速いだけの縮退応答を混入させない）" "0" "$warm_count"
  assert_eq "fail_open_excludedへ1件計上される" "1" "$fail_open_count"
  assert_contains "ERROR行のメッセージがそのまま転記される" "$fail_open_msg" "模擬的なfail-open"

  out_text="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 2>/dev/null)"
  assert_contains "非json出力でもfail-open除外が明示される" "$out_text" "フックがfail-open経路"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 3. ハートビート行はfail-openと誤認されない（ヒット0件でも想起パイプラインを最後まで走らせた健全な呼び出し） ==="
{
  FAKE_HOOK="$(mktemp)"
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
cat >/dev/null
mkdir -p "$(dirname "$VAULT_RECALL_LOG")" 2>/dev/null
printf '%s\ts1\t(heartbeat)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT_RECALL_LOG"
exit 0
HOOKEOF
  chmod +x "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 --json 2>/dev/null)"
  rc=$?
  assert_eq "ハートビートのみはexit 0（fail-openではない）" "0" "$rc"
  warm_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['warm']['count'])")"
  fail_open_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['fail_open_excluded']))")"
  assert_eq "ハートビートも通常どおりwarmバケットへ計測される" "1" "$warm_count"
  assert_eq "fail-open除外は0件" "0" "$fail_open_count"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 4. 複数回の呼び出しでログが取り違わない（呼び出しごとに独立した使い捨てログを使う・Codexレビュー指摘対応） ==="
{
  FAKE_HOOK="$(mktemp)"
  # 1回目の呼び出しでだけERROR行を書き、2回目は何も書かない偽hook。
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
INPUT="$(cat)"
mkdir -p "$(dirname "$VAULT_RECALL_LOG")" 2>/dev/null
case "$INPUT" in
  *first-call*)
    printf '%s\tERROR\t\ts1\t1回目だけのfail-open\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT_RECALL_LOG"
    ;;
esac
exit 0
HOOKEOF
  chmod +x "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  {
    printf 'first-callという質問文です、十分な長さがあります\tKnowledge/a.md\n'
    printf 'second-callという質問文です、十分な長さがあります\tKnowledge/b.md\n'
  } > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 --json 2>/dev/null)"
  warm_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['warm']['count'])")"
  fail_open_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['fail_open_excluded']))")"
  fail_open_index="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['fail_open_excluded'][0]['index'])")"
  assert_eq "1件だけfail-open除外される" "1" "$fail_open_count"
  assert_eq "fail-open除外は1回目(index=1)" "1" "$fail_open_index"
  assert_eq "2回目はwarmバケットへ正常に計測される" "1" "$warm_count"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 5. 無害なERROR行（パイプライン正常完走の事実記録）はfail-open除外の対象にしない（Codex一次レビュー指摘・Major対応） ==="
{
  FAKE_HOOK="$(mktemp)"
  # claude/hooks/vault-recall.shのlog_error()は「柱①/②のskip」だけでなく、
  # 「削除済みノート残存の除外(候補提示自体は正常)」「読取不可ノート件数」のような
  # 正常完走の事実記録にも使い回されている（同ファイル該当コメント参照）。この2つの
  # 既知の無害メッセージを模す。
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
cat >/dev/null
mkdir -p "$(dirname "$VAULT_RECALL_LOG")" 2>/dev/null
printf '%s\tERROR\t\ts1\t削除済みノートのベクトル残存を1件除外しました（インデックスの最大1時間ラグ・付録A FR3ケース6・候補提示自体は正常）\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT_RECALL_LOG"
printf '%s\tERROR\t\ts1\t2件のノートを読み取れませんでした（権限不足の可能性・ファイル名キーのみで照合しました）\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT_RECALL_LOG"
exit 0
HOOKEOF
  chmod +x "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 --json 2>/dev/null)"
  rc=$?
  assert_eq "無害なERROR行のみならexit 0（fail-open扱いされない）" "0" "$rc"
  warm_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['warm']['count'])")"
  fail_open_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['fail_open_excluded']))")"
  assert_eq "無害なERROR行だけならwarmバケットへ通常どおり計測される" "1" "$warm_count"
  assert_eq "fail-open除外は0件（削除済みノート除外・読取不可件数は正常完走の記録）" "0" "$fail_open_count"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 6. 未知のERROR行（無害リストに無いメッセージ）は安全側に倒してfail-open除外する（Codex一次レビュー指摘・Major対応） ==="
{
  FAKE_HOOK="$(mktemp)"
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
cat >/dev/null
mkdir -p "$(dirname "$VAULT_RECALL_LOG")" 2>/dev/null
printf '%s\tERROR\t\ts1\t将来追加されるかもしれない未知の異常です\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT_RECALL_LOG"
exit 0
HOOKEOF
  chmod +x "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 --json 2>/dev/null)"
  rc=$?
  assert_eq "無害リストに無いERROR行はexit 2（安全側でfail-open扱い）" "2" "$rc"
  fail_open_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['fail_open_excluded']))")"
  assert_eq "未知のERROR行はfail-open除外される" "1" "$fail_open_count"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 7. ログが完全に空でも除外はせずcold/warmへ計上し、目視確認用に別枠(empty_log_included)へ記録する（Codex一次レビュー指摘・Major対応） ==="
{
  FAKE_HOOK="$(mktemp)"
  # ログへ一切書き込まない偽hook（10文字未満の短文プロンプトの意図的な無ログ早期exit・
  # または想定外の異常のいずれかを模す。本ツールはこれらを区別できないため除外しない）。
  printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$FAKE_HOOK"
  chmod +x "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 --json 2>/dev/null)"
  rc=$?
  assert_eq "空ログのみではexit 0（fail-open除外の対象にはしない）" "0" "$rc"
  warm_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['warm']['count'])")"
  empty_log_count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['empty_log_included']))")"
  assert_eq "空ログでもwarmバケットへ計上される（除外しない）" "1" "$warm_count"
  assert_eq "empty_log_includedへ1件記録され目視確認できる" "1" "$empty_log_count"

  out_text="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --cold-runs 0 2>/dev/null)"
  assert_contains "非json出力でも空ログの注記が出る" "$out_text" "ログが完全に空でした"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 8. 不正な引数はexit非0でFAILメッセージを出す（既存の頑健性を維持） ==="
{
  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf 'ダミーの質問文です十分な長さがあります\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "/nonexistent-hook-xyz.sh" 2>&1)"
  rc=$?
  assert_eq "存在しないhookパスは非0終了" "1" "$rc"
  assert_contains "hookが見つからない旨のメッセージ" "$out" "hookが見つかりません"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
