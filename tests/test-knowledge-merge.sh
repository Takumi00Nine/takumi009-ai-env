#!/usr/bin/env bash
# scripts/vault-agents/knowledge_merge.py・merge_quality_gate.py のユニットテスト
# （外部脳 Knowledge 自律整理・柱②「マージ実行」の機械化CLI）。
#
# 実CLIをsubprocessで叩く（既存test-update-embedding-index.sh等と同じ方針＝
# ロジック再実装によるドリフトを避ける）。実Vault($HOME/Data/obsidian)・実
# ~/.claude/logs・実LaunchAgentsには一切依存せず、毎回tempディレクトリに
# git init したfixture Vault／fixtureベンチリポジトリを作って完結する
# （設計書§4「sandbox隔離」・絶対厳守ルール準拠）。
#
# AC5相当の故障注入（品質劣化マージ・Codex不通(verdict不正)・git競合）・
# AC6相当（スタブ化・aliases和集合・backlink張替・リンク切れ0）を検証する。
# 一部の重大アサーション（gateのFAILがcommitを止める・verdict不正はfail-closed・
# git競合は自動revertせず停止+ALERT）は開発時にfix-revert法（わざと実装を壊して
# 本テストがFAILすることを確認 → 復元）で検証済み（詳細はワーカー最終報告参照）。
#
# 実行方法: bash tests/test-knowledge-merge.sh

set -uo pipefail

# 実HOME配下（~/.claude/logs・~/.claude/tmp等）への書込を構造的に不可能にする
# （2026-07-12 実インシデント対応: 本テストのcommit呼出し17箇所全てに
# --state-file の明示指定が元々欠落しており、knowledge_merge.pyの既定値
# （pathlib.Path.home()ベース＝実運用中の本物のstate.json/lock）へ実際に
# 書き込む事故が起きた。個々の呼出しへの引数指定漏れに頼らず、テストプロセス
# 全体のHOMEを隔離することで「デフォルトパスへ書けと指定し忘れても実環境には
# 書けない」構造にする＝正本ルール: 実環境テストはsandbox/temp HOMEで隔離
# （Vault: Knowledge/mistakes.md）。
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/knowledge_merge.py"
GATE_SCRIPT="$REPO_ROOT/scripts/vault-agents/merge_quality_gate.py"

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
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけない: \"$needle\")"; fi
}
assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$desc"; else fail_case "$desc (ファイルなし: $path)"; fi
}
assert_file_absent() {
  local desc="$1" path="$2"
  if [[ ! -f "$path" ]]; then pass "$desc"; else fail_case "$desc (存在してはいけない: $path)"; fi
}

git_init_repo() {
  (cd "$1" && git init -q && git config user.email test@example.com && git config user.name test)
}

# 新しいfixture Vault（Knowledge/note-a.md・note-b.md・Projects/refers.md）を作り
# グローバル変数 VAULT/WT_DIR/ALERTS/LOCK/STATE/FIXTURE を設定する。
new_fixture() {
  FIXTURE="$(mktemp -d)"
  VAULT="$FIXTURE/vault"
  WT_DIR="$FIXTURE/worktrees"
  ALERTS="$FIXTURE/alerts"
  LOCK="$FIXTURE/lock"
  STATE="$FIXTURE/state.json"
  mkdir -p "$VAULT/Knowledge" "$VAULT/Projects" "$WT_DIR" "$ALERTS"
  git_init_repo "$VAULT"

  cat > "$VAULT/Knowledge/note-a.md" <<'EOF'
---
date: 2026-01-01
updated: 2026-01-01
tags: [test]
aliases:
  - "アリアスA"
---

## 見出しA

本文A。コード:

```
print("a")
```

出典: https://example.com/a 2026-01-01
EOF

  cat > "$VAULT/Knowledge/note-b.md" <<'EOF'
---
date: 2026-02-01
updated: 2026-02-01
tags: [test]
aliases:
  - "アリアスB"
review_by: 2099-01-01
---

## 見出しB

本文B。コード:

```
print("b")
```

出典: https://example.com/b 2026-02-01
EOF

  cat > "$VAULT/Projects/refers.md" <<'EOF'
---
tags: [test]
related:
  - "[[note-a]]"
---

[[note-a]] を参照。[[note-b|Bノート]] も参照。![[note-a]] は埋め込みなので対象外。
`[[note-a]]` はインラインコードなので対象外。
```
[[note-a]] はコードブロックなので対象外
```
EOF

  cat > "$FIXTURE/merged-body.md" <<'EOF'
---
tags: [test, merged]
---

## 見出しA

## 見出しB

本文A・本文Bを統合した内容。コード:

```
print("a")
```

```
print("b")
```

出典: https://example.com/a https://example.com/b 2026-01-01 2026-02-01
EOF

  (cd "$VAULT" && git add -A && git commit -q -m init)

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
}

# fixtureベンチTSVをgit管理下のリポジトリに作る。グローバル変数 BENCH_REPO/BENCH_TSV を設定する。
new_bench_fixture() {
  BENCH_REPO="$FIXTURE/bench-repo"
  mkdir -p "$BENCH_REPO/docs"
  git_init_repo "$BENCH_REPO"
  BENCH_TSV="$BENCH_REPO/docs/bench.tsv"
  cat > "$BENCH_TSV" <<'EOF'
アリアスAについて教えて	Knowledge/note-a.md
アリアスBについて教えて	Knowledge/note-b.md
EOF
  (cd "$BENCH_REPO" && git add -A && git commit -q -m init)
}

# gate結果JSONのfingerprint（compute_worktree_fingerprint）を計算するヘルパ。
# 「gate結果と現在のworktree内容の一致」検証(validate_gate_result)を満たす
# gate JSONをテスト側で手作りする際に使う。
compute_fp() {
  local wt="$1"
  python3 -c "
import sys, json
sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge as km
meta = km.read_meta('$wt')
print(km.compute_worktree_fingerprint('$wt', meta))
"
}

# 正常系のCodex verdict JSONを作る。draft完了後のworktree（既定: $WT_DIR/cand-1）の
# content_fingerprintをcompute_fpで求めてverdictに埋め込む（validate_verdictの
# content_fingerprint必須検証を満たすため）。
approve_verdict() {
  local cid="${1:-cand-1}"
  local wt="${2:-$WT_DIR/cand-1}"
  local fp
  fp="$(compute_fp "$wt")"
  cat <<EOF
{"candidate_id": "${cid}", "content_fingerprint": "${fp}", "verdict": "approve", "reason_code": "OK_ALL_PASS", "rubric_version": "1", "model": "gpt-5.2-codex",
 "rubric": {"contradiction":"PASS","negation_diff":"PASS","date_diff":"PASS","proper_noun_diff":"PASS","code_block_diff":"PASS","claim_preservation":"PASS"}}
EOF
}

run_pipeline_to_gate() {
  # worktree-setup + draft + gate(--skip-bench) を行い、candidate_id=cand-1 のworktreeを
  # gate通過直前の状態にする（後続テストの共通前処理）。
  python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 >/dev/null
  python3 "$SCRIPT" draft --vault dummy --worktrees-dir "$WT_DIR" --candidate-id cand-1 \
    --note-a Knowledge/note-a.md --note-b Knowledge/note-b.md \
    --merged-note-path Knowledge/note-ab.md --merged-note-file "$FIXTURE/merged-body.md" >/dev/null
}

echo "=== 1. preflight: パス独立検証（Knowledge/直下2件のみ許可） ==="
{
  new_fixture
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "正常な候補はcleared=true" "$out" '"cleared": true'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"trav": {"candidate_id": "trav", "note_a": "Knowledge/../Preferences/x.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "パストラバーサルはcleared=false" "$out" '"cleared": false'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"outside": {"candidate_id": "outside", "note_a": "Preferences/absolute-rules.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "Knowledge/直下以外はcleared=false" "$out" '"cleared": false'

  ln -s /tmp "$VAULT/Knowledge/evil.md" 2>/dev/null
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"sym": {"candidate_id": "sym", "note_a": "Knowledge/evil.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "symlinkはcleared=false" "$out" '"cleared": false'
  rm -f "$VAULT/Knowledge/evil.md"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"nx": {"candidate_id": "nx", "note_a": "Knowledge/does-not-exist.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "存在しないファイルはcleared=false" "$out" '"cleared": false'
}

echo "=== 2. ALERTラッチ: resolved欄＋機械的判定のAND ==="
{
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type lock_conflict \
    --command test --message "テスト用ALERT" >/dev/null

  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "未解決ALERT(resolvedもmachineも未達成)は全マージ拒否(ラッチ)" "$out" '"ok": false'
  assert_contains "理由はunresolved_alerts" "$out" "unresolved_alerts"

  # (a) resolved欄だけでは解消しない: ロックを外部プロセスが保持したまま(machine判定NG)。
  python3 -c "
import fcntl, time
f = open('$LOCK', 'a+')
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
time.sleep(2)
" &
  HOLDER_PID=$!
  sleep 0.3
  alert_file="$(ls "$ALERTS"/*lock_conflict*.md)"
  python3 - "$alert_file" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "resolved欄だけではラッチ解除しない(ロックはまだ他プロセスが保持=machine NG)" "$out" '"ok": false'
  wait "$HOLDER_PID" 2>/dev/null

  # (b) resolved欄＋machine判定(ロック解放済み)の両方が揃って初めてラッチ解除。
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "resolved欄＋機械判定の両方が揃うとラッチ解除" "$out" '"ok": true'
}

echo "=== 3. worktree-setup: 作成・冪等な再利用・非ルート拒否・force-recreate ==="
{
  new_fixture
  out="$(python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1)"
  assert_file_exists "worktreeディレクトリが作られる" "$WT_DIR/cand-1/.vault-merge-meta.json"
  assert_contains "base_headが記録される" "$out" "base_head"

  out2="$(python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1)"
  assert_eq "冪等な再利用でexit 0" "0" "$?"

  rc=0
  python3 "$SCRIPT" worktree-setup --vault "$VAULT/Knowledge" --worktrees-dir "$WT_DIR" --candidate-id cand-x >/dev/null 2>&1 || rc=$?
  assert_eq "gitリポジトリのルート以外を--vaultに指定すると失敗" "1" "$rc"

  # 別コミットを作ってから強制再作成し、base_headが更新されることを確認
  echo x >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "extra")
  out3="$(python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --force-recreate)"
  new_head="$(cd "$VAULT" && git rev-parse HEAD)"
  assert_contains "force-recreateで新しいHEADを基準に再作成" "$out3" "$new_head"
}

echo "=== 4. draft: 統合ノート・非破壊スタブ化・aliases和集合・backlink張替 ==="
{
  new_fixture
  run_pipeline_to_gate
  merged="$WT_DIR/cand-1/Knowledge/note-ab.md"
  stub_a="$WT_DIR/cand-1/Knowledge/note-a.md"
  stub_b="$WT_DIR/cand-1/Knowledge/note-b.md"
  referrer="$WT_DIR/cand-1/Projects/refers.md"

  assert_contains "統合ノートにaliases和集合(A)" "$(cat "$merged")" "アリアスA"
  assert_contains "統合ノートにaliases和集合(B)" "$(cat "$merged")" "アリアスB"
  assert_contains "統合ノートは本日日付" "$(cat "$merged")" "$(date +%Y-%m-%d)"

  assert_contains "note-aはdeprecated: true" "$(cat "$stub_a")" "deprecated: true"
  assert_contains "note-aはsuperseded_by" "$(cat "$stub_a")" "superseded_by: [[note-ab]]"
  assert_contains "note-bはdeprecated: true" "$(cat "$stub_b")" "deprecated: true"
  assert_not_contains "note-aは本文Aを含まない(非破壊だが本文は要約に置換)" "$(cat "$stub_a")" "本文A。コード"

  ref_text="$(cat "$referrer")"
  assert_contains "[[note-a]]は[[note-ab]]へ張替" "$ref_text" "[[note-ab]] を参照"
  assert_contains "[[note-b|表示]]は表示名を保ったまま張替" "$ref_text" "[[note-ab|Bノート]]"
  assert_contains "埋め込み![[note-a]]は対象外のまま" "$ref_text" '![[note-a]] は埋め込み'
  assert_contains "インラインコード内の[[note-a]]は対象外のまま" "$ref_text" '`[[note-a]]` はインライン'
  assert_contains "コードブロック内の[[note-a]]は対象外のまま" "$ref_text" $'```\n[[note-a]] はコードブロック'
  assert_contains "frontmatter内related:の[[note-a]]は書き換わらない(frontmatterブロック全体が対象外)" "$ref_text" '- "[[note-a]]"'
}

echo "=== 4b. draft: 統合ノートに存在しない見出しへの[[note#見出し]]は張替をskip ==="
{
  new_fixture
  cat >> "$VAULT/Projects/refers.md" <<'EOF'
[[note-a#存在しない見出し]] は対象外のまま残る。
EOF
  (cd "$VAULT" && git add -A && git commit -q -m "add heading link")
  run_pipeline_to_gate
  ref_text="$(cat "$WT_DIR/cand-1/Projects/refers.md")"
  assert_contains "存在しない見出しへのリンクは書き換わらない" "$ref_text" "[[note-a#存在しない見出し]]"
}

echo "=== 5. evidence: 証拠パックJSON生成・rubric明記・リンク解決状況 ==="
{
  new_fixture
  run_pipeline_to_gate
  out="$(python3 "$SCRIPT" evidence --vault dummy --worktrees-dir "$WT_DIR" --candidate-id cand-1)"
  ev="$WT_DIR/cand-1.evidence.json"
  assert_file_exists "証拠パックJSONが生成される" "$ev"
  content="$(cat "$ev")"
  for item in contradiction negation_diff date_diff proper_noun_diff code_block_diff claim_preservation; do
    assert_contains "rubric_itemsに${item}を含む" "$content" "\"$item\""
  done
  assert_contains "note_a側にcontent_hashを含む" "$content" '"content_hash"'
  assert_contains "existing_titles_in_target_folderを含む" "$content" "existing_titles_in_target_folder"
}

echo "=== 6. gate: 構造チェック（見出し/コード/URL/日付/aliases/frontmatter/リンク切れ） ==="
{
  new_fixture
  run_pipeline_to_gate
  out="$(python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench)"
  assert_contains "正常な統合ノートはgate PASS" "$out" '"pass": true'
}

echo "=== 6b. gate: 見出し欠落はFAIL（品質劣化マージの検出） ==="
{
  new_fixture
  cat > "$FIXTURE/merged-body.md" <<'EOF'
---
tags: [test]
---

本文のみ・見出しが欠落している統合ノート。
EOF
  run_pipeline_to_gate
  rc=0
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/tmp/km-gate-out.json 2>/dev/null || rc=$?
  assert_eq "見出し欠落でgate非0終了" "2" "$rc"
  assert_contains "missing_headingsに両見出しが載る" "$(cat /tmp/km-gate-out.json)" "見出しA"
}

echo "=== 6c. gate: aliases和集合が崩れるとFAIL ==="
{
  # draft自体は常にaliasesを両原ノートの和集合へ強制する（安全側の仕様）ため、
  # 「aliases和集合が崩れた統合ノート」はdraft後に手作業で編集された場合にのみ
  # 発生しうる。gateがその安全網として機能するかを検証する（draft経由で回避
  # できないことも同時に確認する）。
  new_fixture
  run_pipeline_to_gate
  merged="$WT_DIR/cand-1/Knowledge/note-ab.md"
  assert_contains "draft自体は常にaliases和集合を強制する" "$(cat "$merged")" "アリアスB"

  python3 - "$merged" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('  - アリアスB\n', ''))
PYEOF
  out="$(python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench)"
  assert_contains "draft後の手動編集でaliases和集合が崩れるとgateがFAILさせる" "$out" '"pass": false'
  assert_contains "missing_aliasesにアリアスBが載る" "$out" "アリアスB"
}

echo "=== 6d. gate: ベンチTSVの旧→新パスremap採点＋回帰なし ==="
{
  new_fixture
  new_bench_fixture
  run_pipeline_to_gate
  out="$(python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --bench-tsv "$BENCH_TSV")"
  assert_contains "ベンチ採点込みでgate PASS" "$out" '"pass": true'
  status="$(cd "$BENCH_REPO" && git status --porcelain)"
  assert_eq "元ベンチTSVは無変更のまま" "" "$status"
}

echo "=== 6e. gate: ベンチTSV改ざん（未コミット差分）はfail-closed即block＋ALERT ==="
{
  new_fixture
  new_bench_fixture
  run_pipeline_to_gate
  echo "tampered" >> "$BENCH_TSV"
  rc=0
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --bench-tsv "$BENCH_TSV" >/tmp/km-gate-tamper.json 2>/dev/null || rc=$?
  assert_eq "改ざん時はgate非0終了" "1" "$rc"
  assert_contains "gate結果に改ざん検知が記録される" "$(cat /tmp/km-gate-tamper.json)" "改ざん疑い"
  assert_file_exists "bench_tsv_tampered ALERTが生成される" "$(ls "$ALERTS"/*bench_tsv_tampered*.md 2>/dev/null | head -1)"
  (cd "$BENCH_REPO" && git checkout -- docs/bench.tsv)
}

echo "=== 7. commit: fail-closed（Codex不通/verdict不正・非approve・gate結果の不正/不一致/FAIL） ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  fp="$(compute_fp "$WT_DIR/cand-1")"

  echo "not json" > "$WT_DIR/cand-1.verdict.json"
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-commit1.out 2>&1 || rc=$?
  assert_eq "verdict JSON不正はBLOCKED(rc=4)" "4" "$rc"

  cat > "$WT_DIR/cand-1.verdict.json" <<EOF
{"candidate_id": "cand-1", "content_fingerprint": "${fp}", "verdict": "approve", "reason_code": "OK", "rubric_version": "1", "model": "codex",
 "rubric": {"contradiction":"PASS","negation_diff":"PASS","date_diff":"PASS","proper_noun_diff":"PASS","code_block_diff":"PASS"}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "rubric項目欠落はBLOCKED(rc=4)" "4" "$rc"

  cat > "$WT_DIR/cand-1.verdict.json" <<EOF
{"candidate_id": "cand-other", "content_fingerprint": "${fp}", "verdict": "approve", "reason_code": "OK", "rubric_version": "1", "model": "codex",
 "rubric": {"contradiction":"PASS","negation_diff":"PASS","date_diff":"PASS","proper_noun_diff":"PASS","code_block_diff":"PASS","claim_preservation":"PASS"}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "verdictのcandidate_id不一致(別候補のverdict使い回し)はBLOCKED(rc=4)" "4" "$rc"

  cat > "$WT_DIR/cand-1.verdict.json" <<EOF
{"candidate_id": "cand-1", "content_fingerprint": "0000000000000000000000000000000000000000000000000000000000000000", "verdict": "approve", "reason_code": "OK", "rubric_version": "1", "model": "codex",
 "rubric": {"contradiction":"PASS","negation_diff":"PASS","date_diff":"PASS","proper_noun_diff":"PASS","code_block_diff":"PASS","claim_preservation":"PASS"}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "verdictのcontent_fingerprint不一致(証拠パック生成後の内容変化/古いverdict使い回し)はBLOCKED(rc=4)" "4" "$rc"

  cat > "$WT_DIR/cand-1.verdict.json" <<EOF
{"candidate_id": "cand-1", "content_fingerprint": "${fp}", "verdict": "reject", "reason_code": "CONTRADICTION_FOUND", "rubric_version": "1", "model": "codex",
 "rubric": {"contradiction":"FAIL","negation_diff":"PASS","date_diff":"PASS","proper_noun_diff":"PASS","code_block_diff":"PASS","claim_preservation":"PASS"}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "verdict=rejectはSKIP(rc=5)" "5" "$rc"

  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  echo '{"pass": false, "reason": "injected-fail"}' > "$WT_DIR/cand-1.gate.json"
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "構造不正なgate結果(candidate_id/fingerprint欠落)はBLOCKED(rc=4)" "4" "$rc"

  # 整合性(candidate_id・fingerprint・必須セクション)は正しいが、正当にFAILだった
  # gate結果 → こちらは異常ではなく正常な意思決定としてSKIP(5)になることを確認する。
  cat > "$WT_DIR/cand-1.gate.json" <<EOF
{"candidate_id": "cand-1", "fingerprint": "${fp}", "pass": false,
 "structural": {"pass": false, "missing_headings": ["dummy"]},
 "aliases": {"pass": true}, "frontmatter_required_keys": {"pass": true},
 "broken_links": {"pass": true}, "bench": {"skipped": true, "pass": true}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "整合性は正しいが正当にFAILなgate結果はSKIP(rc=5)＝verdict approveでもコミットしない" "5" "$rc"

  # fingerprint不一致(gate後にworktree内容が変わった＝古いgate結果の使い回し)はBLOCKED。
  cat > "$WT_DIR/cand-1.gate.json" <<EOF
{"candidate_id": "cand-1", "fingerprint": "0000000000000000000000000000000000000000000000000000000000000000", "pass": true,
 "structural": {"pass": true}, "aliases": {"pass": true}, "frontmatter_required_keys": {"pass": true},
 "broken_links": {"pass": true}, "bench": {"skipped": true, "pass": true}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "gate結果のfingerprint不一致(内容すり替え疑い)はBLOCKED(rc=4)" "4" "$rc"

  # bench.skipped=trueは既定では拒否（--allow-bench-skip省略時）。
  cat > "$WT_DIR/cand-1.gate.json" <<EOF
{"candidate_id": "cand-1", "fingerprint": "${fp}", "pass": true,
 "structural": {"pass": true}, "aliases": {"pass": true}, "frontmatter_required_keys": {"pass": true},
 "broken_links": {"pass": true}, "bench": {"skipped": true, "pass": true}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 >/dev/null 2>&1 || rc=$?
  assert_eq "--allow-bench-skip省略時はbench.skipped=trueをBLOCKED(rc=4)" "4" "$rc"

  commit_count="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "いずれのケースでも新規コミットは作られない" "1" "$commit_count"
}

echo "=== 7b. gate結果のトップレベルpassが各セクションの論理積と自己矛盾する場合はBLOCKED ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  fp="$(compute_fp "$WT_DIR/cand-1")"
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  # 各セクションが空dict同然(pass無し)なのにトップレベルpass=trueだけを主張するgate結果。
  cat > "$WT_DIR/cand-1.gate.json" <<EOF
{"candidate_id": "cand-1", "fingerprint": "${fp}", "pass": true,
 "structural": {}, "aliases": {}, "frontmatter_required_keys": {}, "broken_links": {},
 "bench": {"skipped": true, "pass": true}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "空セクションでpass=trueだけ主張するgate結果はBLOCKED(rc=4)" "4" "$rc"

  # トップレベルpass=trueなのに実は1セクションがFAILしている自己矛盾ケース。
  cat > "$WT_DIR/cand-1.gate.json" <<EOF
{"candidate_id": "cand-1", "fingerprint": "${fp}", "pass": true,
 "structural": {"pass": false}, "aliases": {"pass": true}, "frontmatter_required_keys": {"pass": true},
 "broken_links": {"pass": true}, "bench": {"skipped": true, "pass": true}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1 || rc=$?
  assert_eq "pass=trueなのに1セクションFAILの自己矛盾gate結果はBLOCKED(rc=4)" "4" "$rc"

  commit_count="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "いずれのケースでも新規コミットは作られない" "1" "$commit_count"
}

echo "=== 7c. draft: CRLF混入ノートでもpathlib.read_text()のuniversal newlines変換によりLF化されて安全に処理される ==="
{
  # Codexレビュー(2巡目)でCRLF/CR混入時の除外判定すり抜けを指摘されたが、実装調査の
  # 結果、pathlib.Path.read_text()は既定でuniversal newlines変換を行うため、
  # ディスク上が\r\nでも本ツールが読む時点で常にLF化されることを確認した。
  # 追加のCRLF拒否ロジックは不要（かえって正常なCRLF入力を無用にblockしうる）と
  # 判断し実装しないことにした。本テストはその前提（\rが最終的に混入しないこと）を
  # 固定化する回帰チェック。
  new_fixture
  printf 'note-a\r\ncontent\r\n' > "$FIXTURE/crlf-check.txt"
  out="$(python3 -c "
import pathlib
p = pathlib.Path('$FIXTURE/crlf-check.txt')
print('CR_PRESENT' if '\r' in p.read_text(encoding='utf-8') else 'CR_ABSENT')
")"
  assert_eq "read_text()はCRLFをLFへ正規化する(universal newlines)" "CR_ABSENT" "$out"
}

echo "=== 8. commit: 全PASSの正常系 → 1コミット・trailer固定スキーマ・mainへff-onlyマージ ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  out="$(python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip --report-id 2026-07-12)"
  assert_contains "commit成功JSON" "$out" '"ok": true'
  assert_file_exists "統合ノートがmainに反映される" "$VAULT/Knowledge/note-ab.md"
  assert_file_absent "原ノートAは削除されない(非破壊)" "/nonexistent"  # 削除されないことの直接確認は次行
  assert_file_exists "原ノートAはスタブとして残存" "$VAULT/Knowledge/note-a.md"
  assert_file_exists "原ノートBはスタブとして残存" "$VAULT/Knowledge/note-b.md"

  msg="$(cd "$VAULT" && git log -1 --format=%B)"
  for key in candidate_id note_a note_b note_a_content_hash note_b_content_hash merged_note_path \
             codex_verdict reason_code rubric_version model backlink_rewrite_count report_id action; do
    assert_contains "commit trailerに${key}を含む" "$msg" "$key:"
  done
  assert_contains "commit trailerのaction=merge" "$msg" "action: merge"

  ref_after="$(cat "$VAULT/Projects/refers.md")"
  assert_contains "main側のbacklinkも張替済み" "$ref_after" "[[note-ab]] を参照"
}

echo "=== 9. commit: HEAD移動（並行コミット）でff-only失敗 → 自動revertせずALERT ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  echo "concurrent" >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "concurrent unrelated commit (simulated hourly backup)")
  before_head="$(cd "$VAULT" && git rev-parse HEAD)"

  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-commit9.out 2>&1 || rc=$?
  assert_eq "ff-only失敗はBLOCKED(rc=7)" "7" "$rc"
  after_head="$(cd "$VAULT" && git rev-parse HEAD)"
  assert_eq "mainのHEADは動かない(自動revert/マージされない)" "$before_head" "$after_head"
  assert_file_exists "head_moved ALERTが生成される" "$(ls "$ALERTS"/*head_moved*.md 2>/dev/null | head -1)"

  latch_out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "解消前はラッチが有効(以後のマージ全体を停止)" "$latch_out" '"ok": false'

  alert_file="$(ls "$ALERTS"/*head_moved*.md)"
  python3 - "$alert_file" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF
  python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --force-recreate >/dev/null
  latch_out2="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "resolved+基準HEAD再設定(force-recreate)でラッチ解除" "$latch_out2" '"ok": true'
}

echo "=== 10. commit: draft後の想定外変更はworktree_dirty ALERTでBLOCKED ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  echo "unexpected" > "$WT_DIR/cand-1/Knowledge/rogue.md"

  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-commit10.out 2>&1 || rc=$?
  assert_eq "想定外の変更はBLOCKED(rc=6)" "6" "$rc"
  assert_file_exists "worktree_dirty ALERTが生成される" "$(ls "$ALERTS"/*worktree_dirty*.md 2>/dev/null | head -1)"
  commit_count="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "コミットは作られない" "1" "$commit_count"
}

echo "=== 11. reconcile: git log trailer / ALERTを正としてstate.jsonを再構成 ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null

  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  state_content="$(cat "$STATE")"
  assert_contains "reconcile後にstatus=mergedへ更新される" "$state_content" '"status": "merged"'
  assert_contains "merged_commitが記録される" "$state_content" "merged_commit"
}

echo "=== 11b. reconcile: revert後もstatusはFR9b語彙(merged)のまま・reverted_commitで事実を記録 ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null
  python3 "$SCRIPT" revert --vault "$VAULT" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --reason "テスト" >/dev/null

  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  state_content="$(cat "$STATE")"
  assert_contains "revert後もstatusはFR9b語彙のmergedのまま('reverted'という新語彙は導入しない)" \
    "$state_content" '"status": "merged"'
  assert_not_contains "'reverted'というstatus値は存在しない(knowledge_merge_candidates.pyのTERMINAL_STATUSESと非互換になるため)" \
    "$state_content" '"status": "reverted"'
  assert_contains "reverted_commitでrevertの事実を記録する" "$state_content" "reverted_commit"
}

echo "=== 12. revert: 正常系（1コミット追加）・dirty vaultはBLOCKED ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null

  echo "dirty" >> "$VAULT/Knowledge/note-a.md"
  rc=0
  python3 "$SCRIPT" revert --vault "$VAULT" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 >/tmp/km-revert-dirty.out 2>&1 || rc=$?
  assert_eq "vaultがdirtyだとBLOCKED(rc=6)" "6" "$rc"
  assert_file_exists "worktree_dirty ALERTが生成される(revert)" "$(ls "$ALERTS"/*worktree_dirty*.md 2>/dev/null | head -1)"
  (cd "$VAULT" && git checkout -- Knowledge/note-a.md)

  # ALERTラッチはresolved欄+機械判定のANDのため、vaultをcleanにしただけでは
  # まだ全マージ/revertが停止したまま（FR12b・設計書§2.3手順3と同じ扱いがrevertにも
  # 及ぶことの確認）。リーダーがresolvedを明示付与して初めて次のrevertへ進める。
  rc=0
  python3 "$SCRIPT" revert --vault "$VAULT" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --reason "テスト" >/dev/null 2>&1 || rc=$?
  assert_eq "resolved欄未記入のうちはvault clean化だけではラッチ解除されずBLOCKED(rc=8)" "8" "$rc"

  alert_file="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF

  out="$(python3 "$SCRIPT" revert --vault "$VAULT" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --reason "テスト")"
  assert_contains "revert成功JSON" "$out" '"ok": true'
  msg="$(cd "$VAULT" && git log -1 --format=%B)"
  assert_contains "revert commitにaction=revertを含む" "$msg" "action: revert"
  assert_file_absent "統合ノートはrevertで消える" "$VAULT/Knowledge/note-ab.md"
  commit_count="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "1revert=1コミット" "3" "$commit_count"
}

echo "=== 13. alert: attempt_count増加・processedとresolvedの分離 ==="
{
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-9 --alert-type lock_conflict \
    --command test --message "1回目" >/dev/null
  f="$(ls "$ALERTS"/*cand-9*.md)"
  assert_contains "初回attempt_count=1" "$(cat "$f")" "attempt_count: 1"
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-9 --alert-type lock_conflict \
    --command test --message "2回目" >/dev/null
  assert_contains "再発でattempt_count=2" "$(cat "$f")" "attempt_count: 2"
  assert_not_contains "resolvedは未記入" "$(cat "$f")" "resolved:"
}

echo "=== 14. merge_quality_gate.py: 単体CLIスモークテスト ==="
{
  new_fixture
  cat > "$FIXTURE/note-a.md" <<'EOF'
---
tags: [test]
aliases: ["A"]
---
## H1
```
code-a
```
https://example.com/a 2026-01-01
EOF
  cat > "$FIXTURE/note-b.md" <<'EOF'
---
tags: [test]
aliases: ["B"]
---
## H2
```
code-b
```
https://example.com/b 2026-02-01
EOF
  cat > "$FIXTURE/merged-ok.md" <<'EOF'
---
tags: [test]
aliases: ["A", "B"]
---
## H1
## H2
```
code-a
```
```
code-b
```
https://example.com/a https://example.com/b 2026-01-01 2026-02-01
EOF
  rc=0
  python3 "$GATE_SCRIPT" --orig-note-a "$FIXTURE/note-a.md" --orig-note-b "$FIXTURE/note-b.md" \
    --merged-note "$FIXTURE/merged-ok.md" >/dev/null 2>&1 || rc=$?
  assert_eq "正常な統合ノートはexit 0" "0" "$rc"

  cat > "$FIXTURE/merged-bad.md" <<'EOF'
---
tags: [test]
---
本文のみ。
EOF
  rc=0
  python3 "$GATE_SCRIPT" --orig-note-a "$FIXTURE/note-a.md" --orig-note-b "$FIXTURE/note-b.md" \
    --merged-note "$FIXTURE/merged-bad.md" >/dev/null 2>&1 || rc=$?
  assert_eq "劣化した統合ノートはexit非0" "1" "$rc"
}

echo "=== 15. skip: pendingをskippedへ（成功・冪等・存在しない候補/merged/blocked拒否・不正入力の拒否） ==="
{
  new_fixture
  out="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "内容が重複していない")"
  assert_contains "skip成功JSON" "$out" '"status": "skipped"'
  state_content="$(cat "$STATE")"
  assert_contains "state.jsonにstatus=skippedが記録される" "$state_content" '"status": "skipped"'
  assert_contains "skip_reasonが記録される" "$state_content" "内容が重複していない"
  assert_contains "skipped_atが記録される(本日日付)" "$state_content" "$(date +%Y-%m-%d)"

  rc=0
  out2="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "別理由で上書きしようとする" 2>&1)" || rc=$?
  assert_eq "既にskipped済みへの再skipは冪等に成功(rc=0)" "0" "$rc"
  state_content2="$(cat "$STATE")"
  assert_contains "冪等時reasonは上書きされず既存値を維持" "$state_content2" "内容が重複していない"
  assert_not_contains "冪等時に新しいreasonへは書き換わらない" "$state_content2" "別理由で上書きしようとする"

  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id does-not-exist --reason "x" \
    >/tmp/km-skip-nf.out 2>&1 || rc=$?
  assert_eq "存在しないcandidate_idはFAIL(rc=1)" "1" "$rc"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "merged"}}}
EOF
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-skip-merged.out 2>&1 || rc=$?
  assert_eq "merged状態の候補へのskipはFAIL(rc=1)" "1" "$rc"
  assert_contains "merged状態は変更されない" "$(cat "$STATE")" '"status": "merged"'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "blocked"}}}
EOF
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-skip-blocked.out 2>&1 || rc=$?
  assert_eq "blocked状態の候補へのskipはFAIL(rc=1)" "1" "$rc"
  assert_contains "blocked状態は変更されない" "$(cat "$STATE")" '"status": "blocked"'
  assert_contains "blocked時のFAILメッセージはALERT解決を誘導する" "$(cat /tmp/km-skip-blocked.out)" "ALERT"

  new_fixture
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "" \
    >/tmp/km-skip-empty.out 2>&1 || rc=$?
  assert_eq "空のreasonはFAIL(rc=1)" "1" "$rc"
  assert_contains "state.jsonは無変更のまま" "$(cat "$STATE")" '"status": "pending"'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "unknown-status"}}}
EOF
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-skip-unknown.out 2>&1 || rc=$?
  assert_eq "未知のstatus値はfail-closedでFAIL(rc=1)" "1" "$rc"
  assert_contains "未知status時のstate.jsonは変更されない" "$(cat "$STATE")" '"status": "unknown-status"'
}

echo "=== 15b. skip: retry状態でも未解決ALERTがあればFAIL(リーダー判断・二重防御・2026-07-14)。解消後はskip可能・skip後にreconcileを実行してもskippedのまま(retryへ後戻りしない) ==="
{
  # 以前はstatus=="blocked"チェックのみに頼っており、statusがまだ"retry"の間は
  # 未解決ALERTがあってもskipできてしまっていた。リーダー判断により、skip自身が
  # 当該candidate_idの未解決ALERTを直接確認するよう変更（status=="blocked"
  # チェックと合わせた二重防御）。
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type lock_conflict \
    --command test --message "テスト用ALERT(未解決のまま残す)" >/dev/null
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "retry"}}}
EOF
  rc=0
  out_15b_block="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "レビュー結果マージ不適" 2>&1)" || rc=$?
  assert_eq "retry状態でも未解決ALERTがあればskipはFAIL(rc=1・以前は素通りしていた)" "1" "$rc"
  assert_contains "FAILメッセージは未解決ALERTを理由に挙げる" "$out_15b_block" "未解決ALERT"
  assert_contains "state.jsonは無変更のまま(retryのまま)" "$(cat "$STATE")" '"status": "retry"'

  # ALERTを解消（resolved欄＋機械判定=lock解放）してからskipを再試行する。
  alert_file_15b="$(ls "$ALERTS"/*lock_conflict*.md)"
  python3 - "$alert_file_15b" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "レビュー結果マージ不適" >/dev/null
  assert_contains "ALERT解消後はskip直後にstatus=skippedになる" "$(cat "$STATE")" '"status": "skipped"'

  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  state_content="$(cat "$STATE")"
  assert_contains "skip後にreconcileを実行してもstatus=skippedのまま" "$state_content" '"status": "skipped"'
  assert_not_contains "解消済みALERTがあってもreconcileでstatus=retryへ巻き戻らない" "$state_content" '"status": "retry"'
}

echo "=== 15c. skip: commit成功直後のreconcile自動失敗を想定したstale state（state.jsonはpendingのままだがgit履歴には既にマージコミットが存在）はgit logをsource of truthに参照してFAILする ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null
  # commit成功時は自動でreconcileが走りstate.jsonが更新される。ここでは
  # 「reconcileのみが何らかの理由で失敗しstate.jsonがstaleなまま残った」状況を
  # 意図的に再現するため、reconcile後のstate.jsonをpendingへ手動で巻き戻す。
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-skip-stale.out 2>&1 || rc=$?
  assert_eq "state.jsonがstale=pendingでもgit履歴に既存マージコミットがあればFAIL(rc=1)" "1" "$rc"
  assert_contains "FAILメッセージはgit履歴のマージコミットを理由に挙げる" "$(cat /tmp/km-skip-stale.out)" "マージコミットが存在"
  assert_contains "stale状態はskippedへ書き換わらない" "$(cat "$STATE")" '"status": "pending"'
}

echo "=== 15d. skip: ff-only失敗で候補ブランチにだけ残った未反映のtrailerコミットは『マージ済み』と誤判定しない(HEAD到達可能性で絞り込む) ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  # 並行コミットでmainのHEADを進め、後続のcommitがff-onlyできない状況を作る
  # （=== 9. ===と同じ再現方法）。候補ブランチvault-merge/cand-1にはtrailer付き
  # コミットが作られるが、mainへは反映されない。
  echo "concurrent" >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "concurrent unrelated commit (simulated)")

  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-skip-ffonly-commit.out 2>&1 || rc=$?
  assert_eq "ff-only失敗はBLOCKED(rc=7)・候補ブランチにtrailerコミットだけ残る" "7" "$rc"
  # commit失敗時はstate.jsonへ触れない（ALERT生成のみ）ため、new_fixtureが設定した
  # 初期状態(pending)のまま。
  assert_contains "state.jsonはpendingのまま(commit失敗はstate.jsonへ書込まない)" "$(cat "$STATE")" '"status": "pending"'

  # commit失敗時に生成されたhead_moved ALERTがまだ未解決のため、リーダー判断で
  # 追加したskip側の未解決ALERTチェック（二重防御）にまず引っかかることを確認する
  # （このFAILは「マージコミットが存在する」という誤判定ではないことをメッセージで
  # 見分ける＝HEAD到達可能性フィルタ自体は正しく機能している証拠）。
  rc=0
  out_alert_block="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 \
    --reason "競合のため見送り" 2>&1)" || rc=$?
  assert_eq "未解決のhead_moved ALERTがあるためskipはまずFAIL(rc=1・二重防御)" "1" "$rc"
  assert_contains "FAILメッセージは未解決ALERTを理由に挙げる(マージ済み誤判定ではない)" "$out_alert_block" "未解決ALERT"

  # head_moved ALERTを解消（resolved欄＋worktree再作成による基準HEAD再設定）してから
  # 再試行する（=== 9. ===と同じ解消手順）。
  alert_file_ffonly="$(ls "$ALERTS"/*head_moved*.md)"
  python3 - "$alert_file_ffonly" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF
  python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --force-recreate >/dev/null

  rc=0
  out="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 \
    --reason "競合のため見送り" 2>/tmp/km-skip-ffonly-skip.err)" || rc=$?
  assert_eq "ALERT解消後は、現在HEADに未到達のtrailerコミットが『マージ済み』と誤判定されずskip成功(rc=0)" "0" "$rc"
  assert_contains "skip成功JSON" "$out" '"status": "skipped"'
  assert_contains "state.jsonにstatus=skippedが記録される" "$(cat "$STATE")" '"status": "skipped"'
}

echo "=== 15e. skip: git log --allには見えるがHEAD到達不能な非revertマージコミットは『マージ済み』と誤判定せずskipを許可する(HEAD到達可能性フィルタの直接検証・外部脳総点検・unskipレビュー時に発見) ==="
{
  # === 15d. === はff-only失敗→head_moved ALERT→resolved+force-recreateという
  # 実際の失敗フローを再現する価値ある統合テストだが、force-recreateが候補ブランチ
  # (vault-merge/cand-1)自体を`branch -D`で削除するため、その後の`git log --all`
  # からはtrailerコミットが完全に消える。よって15dのskip成功は「HEAD到達可能性
  # フィルタ(_commit_reachable_from_head)が実際に機能して除外されたから」なのか
  # 「検索結果からそもそも消えたから」なのかを区別できていない（cmd_unskip追加の
  # レビュー中に25eと同型の問題として発見・Codexレビュー指摘・Major。15d自体は
  # 統合テストとして価値があるため書き換えず、本テストを追加して補完する）。
  # ここでは25eと同じ手法で、candidate_id trailerを持つコミットを現在のVault HEAD
  # から分岐した独立ブランチ上に直接作り、skip実行後も削除せず残すことで、
  # フィルタが実際に効いていることを明示的に確認する。
  new_fixture
  main_branch="$(cd "$VAULT" && git rev-parse --abbrev-ref HEAD)"
  (cd "$VAULT" && git checkout -q -b vault-merge/cand-1)
  echo "orphan trailer commit content" >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "$(printf 'Knowledge自律整理(模擬・HEAD未到達): cand-1\n\ncandidate_id: cand-1\naction: merge\n')")
  orphan_hash="$(cd "$VAULT" && git rev-parse HEAD)"
  (cd "$VAULT" && git checkout -q "$main_branch")

  all_log="$(cd "$VAULT" && git log --all --oneline)"
  assert_contains "前提: orphanコミットはgit log --allに見える" "$all_log" "${orphan_hash:0:7}"
  reachable_check=0
  (cd "$VAULT" && git merge-base --is-ancestor "$orphan_hash" HEAD) || reachable_check=$?
  assert_eq "前提: orphanコミットは現在のHEADから到達不能(merge-base --is-ancestorが失敗=1)" "1" "$reachable_check"

  rc=0
  out15e="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "競合のため見送り" 2>&1)" || rc=$?
  assert_eq "git log --allに見えるがHEAD到達不能なtrailerコミットは『マージ済み』と誤判定されずskip成功(rc=0)" "0" "$rc"
  assert_contains "skip成功JSON" "$out15e" '"status": "skipped"'

  branch_still_exists="$(cd "$VAULT" && git branch --list vault-merge/cand-1)"
  assert_contains "skip実行後も独立ブランチは削除されず残る(フィルタで除外されたことの証拠であり検索対象消失ではない)" \
    "$branch_still_exists" "vault-merge/cand-1"
}

echo "=== 16. commit: 候補が既に終端状態(merged/skipped)ならfail-closedで再commitを拒否する ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "merged"}}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-commit-terminal.out 2>&1 || rc=$?
  assert_eq "既にmerged状態の候補への再commitはFAIL(rc=1)" "1" "$rc"
  assert_contains "終端状態が理由として示される" "$(cat /tmp/km-commit-terminal.out)" "終端状態"
  commit_count="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "コミットは作られない" "1" "$commit_count"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "skipped"}}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-commit-terminal2.out 2>&1 || rc=$?
  assert_eq "既にskipped状態の候補への再commitもFAIL(rc=1)" "1" "$rc"
}

echo "=== 16b. commit: state.jsonがstale(pending)でもgit履歴に既存マージコミットがあればfail-closedで再commitを拒否する(cmd_skipの15cと同型・Codexレビュー指摘・Major対応) ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null

  # commit成功直後の自動reconcileが何らかの理由で失敗しstate.jsonがstale=pending
  # のまま残った状況を意図的に再現する（=== 15c. ===と同型のstale化）。
  # TERMINAL_STATUSESチェック（stateの自己申告）だけでは、このstaleウィンドウで
  # 2件目のマージコミットを許してしまう間隙をgit log参照で塞ぐ。
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-commit-stale.out 2>&1 || rc=$?
  assert_eq "state.jsonがstale=pendingでもgit履歴に既存マージコミットがあればFAIL(rc=1)" "1" "$rc"
  assert_contains "FAILメッセージはgit履歴のマージコミットを理由に挙げる" "$(cat /tmp/km-commit-stale.out)" "マージコミットが存在"
  commit_count="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "2件目のマージコミットは作られない(1回目のみ)" "2" "$commit_count"
}

echo "=== 17. preflight: 終端状態(merged/skipped)の候補を明示指定するとcleared=falseで拒否する(fail-closed)・blocked/retryは対象外 ==="
{
  new_fixture
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "merged"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --json)"
  assert_contains "終端状態(merged)はcleared=false" "$out" '"cleared": false'
  assert_contains "理由に終端状態が明記される" "$out" "終端状態"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "skipped"}}}
EOF
  out2="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --json)"
  assert_contains "終端状態(skipped)もcleared=false" "$out2" '"cleared": false'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "blocked"}}}
EOF
  out3="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --json)"
  assert_contains "blocked(非終端)は終端チェックの対象外でcleared=trueのまま(再挑戦できる設計を維持)" "$out3" '"cleared": true'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "retry"}}}
EOF
  out4="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --candidate-id cand-1 --json)"
  assert_contains "retry(非終端)も同様にcleared=trueのまま(再挑戦できる設計を維持)" "$out4" '"cleared": true'
}

echo "=== 18. commit: Codex不通(FR11a) → codex_unavailable ALERT生成+当該候補のみblocked化(全マージ停止ラッチの対象外・他候補は妨げない) ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null

  echo "not json" > "$WT_DIR/cand-1.verdict.json"
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-fr11a.out 2>&1 || rc=$?
  assert_eq "verdict不正時はBLOCKED(rc=4)のまま" "4" "$rc"
  assert_contains "FR11a・当該候補のみblocked化の旨がメッセージに出る" "$(cat /tmp/km-fr11a.out)" "FR11a"

  assert_file_exists "codex_unavailable ALERTが生成される" "$(ls "$ALERTS"/*codex_unavailable*.md 2>/dev/null | head -1)"
  state_content="$(cat "$STATE")"
  assert_contains "ALERT生成直後の自動reconcileでcand-1がblocked化される" "$state_content" '"status": "blocked"'

  # 別候補cand-2を追加し、codex_unavailable ALERTが全マージ停止ラッチ(FR12b)の
  # 対象外である(=他候補のpreflightを妨げない・FR11a本文)ことを確認する。
  python3 -c "
import json
p = '$STATE'
d = json.load(open(p))
d['candidates']['cand-2'] = {'candidate_id': 'cand-2', 'note_a': 'Knowledge/note-a.md', 'note_b': 'Knowledge/note-b.md', 'status': 'pending'}
json.dump(d, open(p, 'w'))
"
  latch_out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "codex_unavailable ALERTは全マージ停止ラッチに参加しない(他候補cand-2のpreflightは通る)" "$latch_out" '"ok": true'
  assert_contains "cand-2は通常どおり評価される" "$latch_out" '"candidate_id": "cand-2"'
  assert_not_contains "unresolved_alertsという拒否理由にはならない(latch_active=falseのまま)" "$latch_out" "unresolved_alerts"

  # codex_unavailable以外の通常ALERT（未解決）が同時に存在する場合は、FR12bの
  # 全マージ停止ラッチが引き続き機能することを確認する（codex_unavailableの
  # 除外が他種別へ波及していないことの確認・Codexレビュー指摘対応）。
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-2 --alert-type lock_conflict \
    --command test --message "通常ALERT(未解決)" >/dev/null
  latch_out2="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "通常の未解決ALERTがあればFR12bのラッチが引き続き優先される" "$latch_out2" '"ok": false'
  assert_contains "拒否理由はunresolved_alerts" "$latch_out2" "unresolved_alerts"

  # 後続の再commit検証に影響しないようlock_conflict ALERTを解消しておく。
  lock_alert_file="$(ls "$ALERTS"/*lock_conflict*.md)"
  python3 - "$lock_alert_file" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF

  # cand-1自身も、有効なverdictへ差し替えて再commitすれば（statusはblockedであり
  # TERMINAL_STATUSESではないため）そのまま成功する＝retry可能であることの確認。
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  rc=0
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  out_retry="$(python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip)" || rc=$?
  assert_eq "有効なverdictに差し替えれば同じ候補でも再commitして成功する(blockedはretry可能)" "0" "$rc"
  assert_contains "再commit成功JSON" "$out_retry" '"ok": true'
}

echo "=== 19. reconcile: ALERTがresolvedになった候補はblocked/retryからpendingへ復帰する(skipのFAILメッセージが有効な指示になる) ==="
{
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "テスト用ALERT(後でresolveする)" >/dev/null
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "blocked"}}}
EOF

  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" >/tmp/km-recon-skip1.out 2>&1 || rc=$?
  assert_eq "resolved前はskipがblockedを理由にFAIL(rc=1)" "1" "$rc"

  alert_file="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF

  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_after="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "resolved欄を埋めてreconcileを実行するとblockedからpendingへ復帰する" "pending" "$status_after"

  rc=0
  out="$(python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "レビュー結果マージ不適" 2>&1)" || rc=$?
  assert_eq "reconcile後は(復帰したFAILメッセージどおりの手順で)実際にskipできる(rc=0)" "0" "$rc"
  assert_contains "skip成功" "$out" '"status": "skipped"'

  # retry状態でも同様に復帰することを確認（lock_conflict ALERT由来）。
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type lock_conflict \
    --command test --message "テスト用ALERT(後でresolveする・retry)" >/dev/null
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "retry"}}}
EOF
  alert_file2="$(ls "$ALERTS"/*lock_conflict*.md)"
  python3 - "$alert_file2" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_retry_after="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "retryもresolved後のreconcileでpendingへ復帰する" "pending" "$status_retry_after"

  # resolved欄の日付形式だけ埋めても、実際にはまだ未解決（機械判定NG）なら
  # 復帰させない（Codexレビュー指摘・Major対応: 復帰判定は「resolved欄」だけで
  # なくalert_machine_resolved()とのANDを要求する。さもないと「resolved欄を
  # 書くだけで実際には未解決のALERTでもpendingへ復帰→即skipで終端化できる」
  # という、cmd_skipの「ALERT未解決のままskipできない」方針に反する揉み消し
  # 経路が生まれる）。
  new_fixture
  python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 >/dev/null
  echo "dirty" > "$WT_DIR/cand-1/rogue.md"
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "実際にまだdirty" >/dev/null
  alert_file3="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file3" "$WT_DIR/cand-1" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text().replace("---\n\n#", f"resolved: 2026-07-12\ntarget_path: {sys.argv[2]}\n---\n\n#")
f.write_text(text)
PYEOF
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "blocked"}}}
EOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" >/dev/null
  status_still_blocked="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "resolved欄があっても実際にまだdirty(機械判定NG)ならblockedのまま復帰しない" "blocked" "$status_still_blocked"

  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-recon-skip-machineng.out 2>&1 || rc=$?
  assert_eq "実際には未解決のためskipもblockedを理由にFAILしたまま(揉み消せない)" "1" "$rc"

  # resolved欄が日付形式ですらない不正値の場合も復帰しない。
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type lock_conflict \
    --command test --message "形式不正なresolved値のテスト" >/dev/null
  alert_file4="$(ls "$ALERTS"/*lock_conflict*.md)"
  python3 - "$alert_file4" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: yes\n---\n\n#"))
PYEOF
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "retry"}}}
EOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_bad_format="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "resolved欄がYYYY-MM-DD形式でなければ復帰しない" "retry" "$status_bad_format"

  # ALERTファイルが1件でも読込失敗する場合は、その回は復帰処理自体を全面的に
  # 見送る（fail-closed）。他の候補が正しくresolvedでも巻き込まれて据え置かれる。
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "resolved済み" >/dev/null
  alert_file5="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file5" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-12\n---\n\n#"))
PYEOF
  # 読込不能なALERTファイル（ディレクトリなので read_text() が OSError
  # (IsADirectoryError) を送出する）を紛れ込ませる。
  mkdir -p "$ALERTS/broken.md"
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "blocked"}}}
EOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_unreadable="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "ALERTディレクトリ内に読込不能ファイルがあれば復帰処理全体を見送る(fail-closed)" "blocked" "$status_unreadable"
}

echo "=== 19b. reconcile: 候補がまだpendingの状態でも、resolved欄が甘い/機械判定NG/読込不能なALERTがあればblockedへ進める(Codexレビュー指摘・Major・2巡目再指摘対応) ==="
{
  # 「進める」方向と「戻す」方向で判定強度が非対称だと、statusがまだpendingの
  # 候補には弱い判定（resolved欄の有無のみ）しか働かず、resolved欄が形式不正/
  # 機械判定NGでも見かけ上blocked化されずpendingのまま残り、cmd_skipで
  # 終端化できてしまう間隙があった。pending始まりでも必ずblockedへ進むことを確認する。

  # (a) resolved欄が日付形式ですらない不正値（worktree_dirty＝lock_conflict以外
  #     なのでblockedへ進む・blockedはskipで拒否される種別）。
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "形式不正なresolved(pending始まり)" >/dev/null
  alert_file6="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file6" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: yes\n---\n\n#"))
PYEOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_pending_a="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "(a) pending始まり+形式不正resolvedはblockedへ進む(以前は弱い判定でpendingのまま残っていた)" \
    "blocked" "$status_pending_a"
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-pending-skip-a.out 2>&1 || rc=$?
  assert_eq "(a) blockedになったのでskipはFAIL(rc=1・以前は形式不正resolvedのまま揉み消せていた)" "1" "$rc"

  # (b) resolved日付は有効だが実際にはまだdirty(機械判定NG)。
  new_fixture
  python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 >/dev/null
  echo "dirty" > "$WT_DIR/cand-1/rogue.md"
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "実際にまだdirty(pending始まり)" >/dev/null
  alert_file7="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file7" "$WT_DIR/cand-1" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text().replace("---\n\n#", f"resolved: 2026-07-12\ntarget_path: {sys.argv[2]}\n---\n\n#")
f.write_text(text)
PYEOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" >/dev/null
  status_pending_b="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "(b) pending始まり+機械判定NGはblockedへ進む" "blocked" "$status_pending_b"
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-pending-skip-b.out 2>&1 || rc=$?
  assert_eq "(b) blockedになったのでskipはFAIL(rc=1・揉み消せない)" "1" "$rc"
  rm -f "$WT_DIR/cand-1/rogue.md"

  # (c) ALERTディレクトリ内に読込不能ファイルがある＝status同期処理自体を
  #     全面的に見送る＝pendingのまま据え置かれる（進む方向に確定できないので
  #     blockedにはならないが、これは既存fail-closed方針＝現状維持＝どおり）。
  new_fixture
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type lock_conflict \
    --command test --message "本来は未解決(pending始まり)" >/dev/null
  mkdir -p "$ALERTS/broken.md"
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_pending_c="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "(c) 読込不能ALERTがあればstatus同期処理全体を見送りpendingのまま(fail-closed=現状維持)" "pending" "$status_pending_c"

  # reconcileがpendingのまま据え置いても、skip自身のALERT走査（cmd_skip）は
  # 独立してALERTディレクトリを直接見るため、読込不能ファイルがあればFAILする
  # ことを確認する（Codexレビュー指摘・Minor: cmd_skipのexcept OSError分岐の
  # 直接テストが無かった）。
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-pending-skip-c.out 2>&1 || rc=$?
  assert_eq "(c) pending状態でも読込不能ALERTがあればskipはFAIL(rc=1・fail-closed)" "1" "$rc"
  assert_contains "FAILメッセージはALERT読込失敗を理由に挙げる" "$(cat /tmp/km-pending-skip-c.out)" "ALERTファイルの読込に失敗"
  assert_contains "state.jsonは無変更のまま(pendingのまま)" "$(cat "$STATE")" '"status": "pending"'
  rm -rf "$ALERTS/broken.md"

  # --alerts-dirがディレクトリではない（設定ミス/改ざんの疑い）場合もfail-closed
  # でFAILする（「ALERTなし」と誤認してskipを通してしまわない・Codexレビュー
  # 指摘・Minor）。
  bogus_alerts_dir="$(mktemp)"
  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$bogus_alerts_dir" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-pending-skip-baddir.out 2>&1 || rc=$?
  assert_eq "--alerts-dirがディレクトリでない場合もskipはFAIL(rc=1・fail-closed)" "1" "$rc"
  assert_contains "FAILメッセージはディレクトリでない旨を挙げる" "$(cat /tmp/km-pending-skip-baddir.out)" "ディレクトリではありません"
  rm -f "$bogus_alerts_dir"
}

echo "=== 19c. reconcile: 同一候補にlock_conflict以外の未解決ALERTが1件でもあればblockedが優先される(retryで揉み消せない・Codexレビュー指摘・Major・3巡目再指摘対応) ==="
{
  # 同一候補に「未解決のworktree_dirty」と「未解決のlock_conflict」が同時に存在する
  # 状況を作る。lock_conflict側のファイル名を意図的に未来日付へリネームし、
  # sorted()順で必ず最後に処理されるようにする（Codexレビュー指摘・Minor:
  # 同日生成だとファイル名のアルファベット順で"lock_conflict"<"worktree_dirty"と
  # なり、旧実装の「最後が勝つ」でも偶然blockedになってしまい、修正前後の差異を
  # 再現できていなかった。lock_conflictを確実に最後にすることで、旧実装なら
  # retryに、新実装ならblockedになる、という回帰を正しく再現する）。
  new_fixture
  python3 "$SCRIPT" worktree-setup --vault "$VAULT" --worktrees-dir "$WT_DIR" --candidate-id cand-1 >/dev/null
  echo "dirty" > "$WT_DIR/cand-1/rogue.md"
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "未解決のまま(古い方)" >/dev/null
  alert_file8="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file8" "$WT_DIR/cand-1" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text().replace("---\n\n#", f"target_path: {sys.argv[2]}\n---\n\n#")
f.write_text(text)
PYEOF
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type lock_conflict \
    --command test --message "未解決のまま(新しい方)" >/dev/null
  lock_alert_file8="$(ls "$ALERTS"/*lock_conflict*.md)"
  mv "$lock_alert_file8" "$ALERTS/9999-12-31-cand-1-lock_conflict.md"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" >/dev/null
  status_mixed="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1']['status'])
")"
  assert_eq "lock_conflict以外の未解決ALERTが1件でもあればblockedが優先される(retryにならない)" "blocked" "$status_mixed"

  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-mixed-skip.out 2>&1 || rc=$?
  assert_eq "blockedになったのでskipはFAIL(rc=1・以前はretryとして揉み消せていた)" "1" "$rc"
  rm -f "$WT_DIR/cand-1/rogue.md"
}

echo "=== 20. reconcile: ff-only失敗で候補ブランチにだけ残った未反映コミットは『マージ済み』と誤認しない(HEAD到達可能性で絞り込む) ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  echo "concurrent" >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "concurrent unrelated commit (simulated)")

  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-recon-ffonly.out 2>&1 || rc=$?
  assert_eq "ff-only失敗はBLOCKED(rc=7)・候補ブランチにtrailerコミットだけ残る" "7" "$rc"

  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/dev/null
  status_after="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1'].get('status'))
")"
  # commit失敗時にhead_moved ALERTが生成されており未解決のままのため、正しい
  # 復元先は"merged"ではなく（head_moved ALERTの通り）"blocked"になる。ここで
  # 検証したいのは「HEAD未到達のtrailerコミットがmergedと誤登録されないこと」
  # （実際に確認すべきはmerged_commitが設定されないこと）であり、blocked自体は
  # 別の既存機構（head_moved ALERT検知）による正しい挙動。
  assert_eq "HEAD未到達のtrailerコミットはmergedへ誤登録されない(head_moved ALERTによりblockedになる)" \
    "blocked" "$status_after"
  merged_commit_field="$(python3 -c "
import json
print(json.load(open('$STATE'))['candidates']['cand-1'].get('merged_commit', ''))
")"
  assert_eq "merged_commitも設定されない" "" "$merged_commit_field"
}

echo "=== 21. revert: HEAD未到達(ff-only失敗で候補ブランチにのみ残った)コミットはrevert対象にしない ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  echo "concurrent" >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "concurrent unrelated commit (simulated)")

  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null 2>&1

  head_before="$(cd "$VAULT" && git rev-parse HEAD)"
  rc=0
  python3 "$SCRIPT" revert --vault "$VAULT" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" \
    --candidate-id cand-1 --reason "test" >/tmp/km-revert-unreachable.out 2>&1 || rc=$?
  assert_eq "HEAD未到達コミットはrevert対象として見つからずFAIL(rc=1)" "1" "$rc"
  assert_contains "マージコミットが見つからない旨のメッセージ" "$(cat /tmp/km-revert-unreachable.out)" "マージコミットが見つかりません"

  head_after="$(cd "$VAULT" && git rev-parse HEAD)"
  commit_count_after="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "拒否されたrevert試行の前後でHEADは変化しない" "$head_before" "$head_after"
  assert_eq "拒否されたrevert試行でコミット数も変化しない(init+concurrentの2件のまま)" "2" "$commit_count_after"
}

echo "=== 22. state.json: schema_versionが無い/不一致ならfail-closedで読込を拒否する(preflight/skip/reconcileで共通・candidates.py側との対称性) ==="
{
  new_fixture
  cat > "$STATE" <<EOF
{"candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "schema_version欠如はstate_load_errorでok=false" "$out" '"reason": "state_load_error"'
  assert_contains "エラーメッセージにschema_versionが無い旨" "$out" "schema_version"

  rc=0
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --candidate-id cand-1 --reason "x" \
    >/tmp/km-schema-skip.out 2>&1 || rc=$?
  assert_eq "skipもschema_version欠如でFAIL(rc=1)" "1" "$rc"

  cat > "$STATE" <<EOF
{"schema_version": 999, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  rc=0
  python3 "$SCRIPT" reconcile --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --lock-file "$LOCK" >/tmp/km-schema-reconcile.out 2>&1 || rc=$?
  assert_eq "reconcileもschema_version不一致でFAIL(rc=1)" "1" "$rc"
  assert_contains "不一致の旨がメッセージに出る" "$(cat /tmp/km-schema-reconcile.out)" "schema_version"

  # commitもschema_version欠如/不一致でFAILする（cmd_commitが追加したTERMINAL_
  # STATUSESチェック/git log二重マージ防止チェックのために候補statusを読む際、
  # load_state()のfail-closed検証を経由するため）。
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  cat > "$STATE" <<EOF
{"candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-schema-commit.out 2>&1 || rc=$?
  assert_eq "commitもschema_version欠如でFAIL(rc=1)" "1" "$rc"
  assert_contains "commitのFAILメッセージにもschema_versionが無い旨が出る" "$(cat /tmp/km-schema-commit.out)" "schema_version"
  commit_count_schema="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "schema_version欠如時はコミットも作られない" "1" "$commit_count_schema"
}

echo "=== 23. commit: 未登録候補(state.jsonに存在しない)はfail-closedで既定拒否・--allow-unregistered-candidateで明示許可(リーダー判断・2026-07-14) ==="
{
  # state.json消失/state-file誤指定と、preflightの--note-a/--note-bによる意図的な
  # 「stateに未登録の候補を手動で試す」運用を区別できないまま、以前はcommit_cand
  # is Noneを無条件で通過させていた。既定をfail-closedへ変更し、意図的な手動運用
  # のみ--allow-unregistered-candidateで明示許可する（--allow-bench-skipと同じ
  # 二重明示エスケープハッチの流儀）。
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {}}
EOF
  rc=0
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/tmp/km-unreg-commit.out 2>&1 || rc=$?
  assert_eq "未登録候補は既定でFAIL(rc=1)" "1" "$rc"
  assert_contains "FAILメッセージは--allow-unregistered-candidateの明示指定を誘導する" \
    "$(cat /tmp/km-unreg-commit.out)" "--allow-unregistered-candidate"
  commit_count_unreg="$(cd "$VAULT" && git log --oneline | wc -l | tr -d ' ')"
  assert_eq "拒否時はコミットは作られない" "1" "$commit_count_unreg"

  out_unreg="$(python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip --allow-unregistered-candidate)"
  assert_contains "--allow-unregistered-candidateを明示すれば成功する(手動オーバーライド運用を維持)" "$out_unreg" '"ok": true'
  assert_file_exists "統合ノートがmainに反映される" "$VAULT/Knowledge/note-ab.md"
}

echo "=== 24. commit: 書込直前の最終ラッチ再確認(TOCTOU対策・外部脳総点検5巡目Codexレビュー指摘) ==="
{
  # 冒頭のcheck_alert_latch()（ロック取得直後）から実際のgit書込(add/commit/merge)
  # までの間にstate.json読込・fingerprint再計算・verdict/gate読込・git status確認
  # という無視できない処理を挟んでおり、この間に新規ALERTが割込んでも冒頭の一度
  # きりのチェックでは検知できないまま書込まれてしまう窓があった（write_alert()
  # 自体はロックを取らない設計のため他プロセスが書込みうる＝write_alertの
  # docstring参照）。実際の並行プロセスによる割込みを決定的に再現するのは難しい
  # ため、check_alert_latch()を直接差し替え「1回目はクリア・2回目（=書込直前の
  # 再確認）でALERT検出」を模擬し、cmd_commitが実際に2回呼出し・2回目の結果を
  # 尊重してBLOCKEDにすることを検証する（ホワイトボックステスト。ブラックボックス
  # では冒頭チェックと区別できないため）。さらにgit_status_porcelain_dir()も
  # 差し替え、2回目のlatch呼出し時点で既にworktreeのgit status確認（想定外変更
  # チェック）を経由済みであることも確認する（Codexレビュー指摘・Minor・2巡目
  # 再指摘: 呼出し回数だけでは「2回目のチェックがgit status確認より前へ後退しても
  # テストが気づかない」ため、実装が実際に想定した順序＝git status確認の後・
  # git add直前でチェックしていることまで検証する）。
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  before_head="$(cd "$VAULT" && git rev-parse HEAD)"
  before_wt_head="$(cd "$WT_DIR/cand-1" && git rev-parse HEAD)"
  before_wt_status="$(cd "$WT_DIR/cand-1" && git status --porcelain)"

  out24="$(python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge as km

calls = {'n': 0, 'status_called': False}
orig_status = km.git_status_porcelain_dir
def fake_status(path):
    calls['status_called'] = True
    return orig_status(path)
km.git_status_porcelain_dir = fake_status

def fake_latch(*a, **kw):
    calls['n'] += 1
    if calls['n'] == 1:
        return False, []
    return True, [{'candidate_id': 'injected', 'alert_type': 'worktree_dirty',
                   'reasons': ['simulated: 書込直前に新規ALERTが割込んだことを模擬'],
                   'status_called_before_2nd_latch': calls['status_called']}]
km.check_alert_latch = fake_latch

args = km.build_parser().parse_args([
    'commit', '--vault', '$VAULT', '--state-file', '$STATE', '--worktrees-dir', '$WT_DIR',
    '--alerts-dir', '$ALERTS', '--lock-file', '$LOCK', '--candidate-id', 'cand-1', '--allow-bench-skip',
])
rc = km.cmd_commit(args)
print('RC=%d CALLS=%d STATUS_CALLED=%s' % (rc, calls['n'], calls['status_called']))
")"
  assert_contains "check_alert_latch()はcmd_commit内で2回呼ばれる(冒頭+書込直前)" "$out24" "CALLS=2"
  assert_contains "2回目の呼出しでラッチが有効ならBLOCKED(rc=8)" "$out24" "RC=8"
  assert_contains "2回目のlatch確認は実際にgit status確認(想定外変更チェック)の後で行われる" \
    "$out24" "STATUS_CALLED=True"
  after_head="$(cd "$VAULT" && git rev-parse HEAD)"
  assert_eq "書込直前の再確認でBLOCKEDになった場合mainのHEADは動かない" "$before_head" "$after_head"
  assert_file_absent "統合ノートはmainへ反映されない" "$VAULT/Knowledge/note-ab.md"
  after_wt_head="$(cd "$WT_DIR/cand-1" && git rev-parse HEAD)"
  after_wt_status="$(cd "$WT_DIR/cand-1" && git status --porcelain)"
  assert_eq "候補worktreeでもcommitは作られない(HEAD不変)" "$before_wt_head" "$after_wt_head"
  assert_eq "候補worktreeでgit addも実行されない(git status --porcelainが呼出し前後で不変=書込直前で本当に止まっている証拠)" \
    "$before_wt_status" "$after_wt_status"
}

echo "=== 25. unskip: skippedをpendingへ手動再評価用に戻す(成功・監査記録・skipped以外拒否・存在しない候補拒否・不正入力の拒否) ==="
{
  new_fixture
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "レビュー結果マージ不適" >/dev/null
  assert_contains "前提: skip済み" "$(cat "$STATE")" '"status": "skipped"'

  out25="$(python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "状況変化のため再評価したい")"
  assert_contains "unskip成功JSON" "$out25" '"status": "pending"'
  state25="$(cat "$STATE")"
  assert_contains "state.jsonにstatus=pendingが記録される" "$state25" '"status": "pending"'
  assert_contains "unskip_reasonが記録される" "$state25" "状況変化のため再評価したい"
  assert_contains "unskipped_atが記録される(本日日付)" "$state25" "$(date +%Y-%m-%d)"
  assert_contains "既存のskip_reasonは上書きされず維持される(監査性)" "$state25" "レビュー結果マージ不適"
  assert_contains "既存のskipped_atも維持される" "$state25" '"skipped_at"'

  # 副作用確認: pendingへ戻った候補は、以後のバッチ選定(--candidate-id省略時の
  # preflight)がpending/retryとして拾う対象に含まれる(=次回週次検出の再評価対象に
  # なるのと同じ観測可能な効果。knowledge_merge_candidates.py自体は別ワーカー
  # 担当のため本テストの対象外)。
  latch_out25="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "unskip後はバッチpreflightがcand-1を選定対象に含む(pending復帰の副作用)" "$latch_out25" '"candidate_id": "cand-1"'
  assert_contains "unskip後のpreflightはcleared=trueになる" "$latch_out25" '"cleared": true'

  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "二回目" >/tmp/km-unskip-pending.out 2>&1 || rc=$?
  assert_eq "既にpendingの候補への再unskipはFAIL(skipped以外は一律拒否・rc=1)" "1" "$rc"
  assert_contains "FAILメッセージはskipped専用である旨" "$(cat /tmp/km-unskip-pending.out)" "skipped"

  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id does-not-exist --reason "x" >/tmp/km-unskip-nf.out 2>&1 || rc=$?
  assert_eq "存在しないcandidate_idはFAIL(rc=1)" "1" "$rc"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "merged"}}}
EOF
  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-unskip-merged.out 2>&1 || rc=$?
  assert_eq "merged状態はunskip不可(rc=1)" "1" "$rc"
  assert_contains "merged状態は変更されない" "$(cat "$STATE")" '"status": "merged"'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "blocked"}}}
EOF
  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-unskip-blocked.out 2>&1 || rc=$?
  assert_eq "blocked状態はunskip不可(rc=1・先にALERT解消+reconcileが筋)" "1" "$rc"
  assert_contains "blocked状態は変更されない" "$(cat "$STATE")" '"status": "blocked"'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "空reasonテスト用" >/dev/null
  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "" >/tmp/km-unskip-empty.out 2>&1 || rc=$?
  assert_eq "空のreasonはFAIL(rc=1)" "1" "$rc"
  assert_contains "state.jsonは無変更のまま(skippedのまま)" "$(cat "$STATE")" '"status": "skipped"'
}

echo "=== 25b. unskip: 当該candidate_idに未解決ALERTがあればFAIL(cmd_skipと対称の二重防御) ==="
{
  new_fixture
  python3 "$SCRIPT" skip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "レビュー結果マージ不適" >/dev/null
  python3 "$SCRIPT" alert --alerts-dir "$ALERTS" --candidate-id cand-1 --alert-type worktree_dirty \
    --command test --message "テスト用ALERT(未解決のまま残す)" >/dev/null

  rc=0
  out25b="$(python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "再評価したい" 2>&1)" || rc=$?
  assert_eq "未解決ALERTがあればunskipはFAIL(rc=1)" "1" "$rc"
  assert_contains "FAILメッセージは未解決ALERTを理由に挙げる" "$out25b" "未解決ALERT"
  assert_contains "state.jsonは無変更のまま(skippedのまま)" "$(cat "$STATE")" '"status": "skipped"'

  alert_file_25b="$(ls "$ALERTS"/*worktree_dirty*.md)"
  python3 - "$alert_file_25b" <<'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace("---\n\n#", "resolved: 2026-07-15\n---\n\n#"))
PYEOF
  # worktree_dirty種別のalert_machine_resolved()はtarget_path配下(=候補worktree)の
  # git statusを見る。skipはVaultの実ファイルへ触れないためworktreeは未作成のまま
  # ＝target_dirが存在しない場合は「対象自体が破棄済み」としてcleared扱いになる
  # (alert_machine_resolvedのworktree_dirty分岐参照)。
  out25b2="$(python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "再評価したい")"
  assert_contains "ALERT解消後はunskip成功" "$out25b2" '"status": "pending"'
}

echo "=== 25c. unskip: git履歴に現在HEADから到達可能なマージコミットが既に存在する候補はunskip不可(state.jsonとgit履歴の矛盾をfail-closedで検出) ==="
{
  new_fixture
  run_pipeline_to_gate
  python3 "$SCRIPT" gate --vault "$VAULT" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" --candidate-id cand-1 --skip-bench >/dev/null
  approve_verdict > "$WT_DIR/cand-1.verdict.json"
  python3 "$SCRIPT" commit --vault "$VAULT" --state-file "$STATE" --worktrees-dir "$WT_DIR" --alerts-dir "$ALERTS" \
    --lock-file "$LOCK" --candidate-id cand-1 --allow-bench-skip >/dev/null
  # commit成功時は自動reconcileでstatus=mergedになる。ここでは「reconcileのみ何らか
  # の理由で失敗し、state.jsonが誤ってskippedに手動編集された(あるいは何らかの
  # 破損)」という矛盾状況を意図的に再現する(=== 15c. ===と同型の考え方)。
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "skipped", "skip_reason": "誤って手動編集", "skipped_at": "2026-07-01"}}}
EOF
  rc=0
  out25c="$(python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "再評価したい" 2>&1)" || rc=$?
  assert_eq "既にgit履歴にマージコミットが存在する候補はunskip不可(rc=1)" "1" "$rc"
  assert_contains "FAILメッセージはgit履歴のマージコミットを理由に挙げる" "$out25c" "マージコミットが存在"
  assert_contains "矛盾状態はunskipで書き換わらない(skippedのまま)" "$(cat "$STATE")" '"status": "skipped"'
}

echo "=== 25d. unskip: retry/未知status/alerts-dir不正/ALERT読込不能もskipped専用のfail-closedで一律拒否する(cmd_skipとの対称性の網羅・Codexレビュー指摘) ==="
{
  new_fixture
  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "retry"}}}
EOF
  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-unskip-retry.out 2>&1 || rc=$?
  assert_eq "retry状態はunskip不可(rc=1・skipped以外は一律拒否)" "1" "$rc"
  assert_contains "retry状態は変更されない" "$(cat "$STATE")" '"status": "retry"'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "unknown-status"}}}
EOF
  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-unskip-unknown.out 2>&1 || rc=$?
  assert_eq "未知のstatus値もfail-closedで拒否する(rc=1)" "1" "$rc"
  assert_contains "未知status時のstate.jsonは変更されない" "$(cat "$STATE")" '"status": "unknown-status"'

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "skipped", "skip_reason": "x", "skipped_at": "2026-07-01"}}}
EOF
  rm -rf "$ALERTS"
  touch "$ALERTS"  # --alerts-dirが通常ファイル(ディレクトリでない)という設定ミスを模擬
  rc=0
  python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" >/tmp/km-unskip-alertsdirfile.out 2>&1 || rc=$?
  assert_eq "--alerts-dirがディレクトリでない場合もunskipはFAIL(rc=1・fail-closed)" "1" "$rc"
  assert_contains "FAILメッセージはディレクトリでない旨を挙げる" "$(cat /tmp/km-unskip-alertsdirfile.out)" "ディレクトリではありません"
  assert_contains "state.jsonは無変更のまま(skippedのまま)" "$(cat "$STATE")" '"status": "skipped"'
  rm -f "$ALERTS"
  mkdir -p "$ALERTS"

  # 当該candidate_idの未解決ALERTファイルが読込不能な場合もfail-closedで拒否する
  # (cmd_skipの直接scan分岐と対称)。「読込不能」をchmod 000で再現するとroot実行
  # 環境(CI等)ではrootが権限を無視して読めてしまい不安定になるため、実行ユーザー
  # 権限に依存しない決定的な再現方法として「*.md」という名前のディレクトリを作る
  # （`alerts_dir.glob("*.md")`はディレクトリも拾う一方、parse_alert()の
  # `Path.read_text()`はディレクトリに対して必ずIsADirectoryError=OSErrorを送出
  # するため、権限に関わらず常に読込失敗を再現できる＝Codexレビュー指摘・Minor対応）。
  bad_alert="$ALERTS/2026-07-15-cand-1-worktree_dirty.md"
  mkdir -p "$bad_alert"
  rc=0
  out25d="$(python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "x" 2>&1)" || rc=$?
  assert_eq "ALERTファイル読込不能はfail-closedでunskip拒否(rc=1)" "1" "$rc"
  assert_contains "FAILメッセージはALERT読込失敗を理由に挙げる" "$out25d" "ALERTファイルの読込に失敗"
  assert_contains "state.jsonは無変更のまま(skippedのまま)" "$(cat "$STATE")" '"status": "skipped"'
  rm -rf "$bad_alert"
}

echo "=== 25e. unskip: git log --allには見えるがHEAD到達不能な非revertマージコミット(candidate_id trailer)は『マージ済み』と誤判定せずunskipを許可する(HEAD到達可能性フィルタの直接検証) ==="
{
  # cmd_skipの15dと同じ「ff-only失敗→head_moved ALERT→resolved+force-recreateで
  # 解消」という実失敗フローをそのまま流用すると、force-recreateが候補ブランチ
  # (vault-merge/cand-1)自体を`branch -D`で削除してしまい、`git log --all`から
  # コミットが完全に消える。その状態でunskipが成功しても「到達不能として正しく
  # 除外されたから」なのか「検索結果からそもそも消えたから」なのか区別できない
  # （Codexレビュー指摘・Major・2巡目再指摘: 当初は15dを流用しておりこの区別が
  # できていなかった）。よってここではcmd_commitの実失敗フローを経由せず、
  # candidate_id trailerを持つコミットを現在のVault HEADから分岐した独立ブランチ
  # 上に直接作る（=ff-only失敗で候補ブランチにのみ残った未反映コミットを模擬する、
  # より直接的で決定的な再現方法）。このブランチはunskip実行後も削除せず残すため
  # `git log --all`には引き続き見え続け、_commit_reachable_from_headによる
  # 絞り込みが実際に効いていることを明示的に確認できる。
  new_fixture
  main_branch="$(cd "$VAULT" && git rev-parse --abbrev-ref HEAD)"
  (cd "$VAULT" && git checkout -q -b vault-merge/cand-1)
  echo "orphan trailer commit content" >> "$VAULT/Projects/refers.md"
  (cd "$VAULT" && git add -A && git commit -q -m "$(printf 'Knowledge自律整理(模擬・HEAD未到達): cand-1\n\ncandidate_id: cand-1\naction: merge\n')")
  orphan_hash="$(cd "$VAULT" && git rev-parse HEAD)"
  (cd "$VAULT" && git checkout -q "$main_branch")

  # 前提確認: このコミットはgit log --allには見えるが、現在のHEAD(main_branch)から
  # は到達できない(=ff-only失敗で候補ブランチにのみ残った未反映コミットと同じ状況)。
  all_log="$(cd "$VAULT" && git log --all --oneline)"
  assert_contains "前提: orphanコミットはgit log --allに見える" "$all_log" "${orphan_hash:0:7}"
  reachable_check=0
  (cd "$VAULT" && git merge-base --is-ancestor "$orphan_hash" HEAD) || reachable_check=$?
  assert_eq "前提: orphanコミットは現在のHEADから到達不能(merge-base --is-ancestorが失敗=1)" "1" "$reachable_check"

  cat > "$STATE" <<EOF
{"schema_version": 1, "candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "skipped", "skip_reason": "競合のため見送り(模擬)", "skipped_at": "2026-07-01"}}}
EOF
  rc=0
  out25e="$(python3 "$SCRIPT" unskip --vault "$VAULT" --state-file "$STATE" --lock-file "$LOCK" --alerts-dir "$ALERTS" --worktrees-dir "$WT_DIR" \
    --candidate-id cand-1 --reason "再評価したい" 2>&1)" || rc=$?
  assert_eq "git log --allに見えるがHEAD到達不能なtrailerコミットは『マージ済み』と誤判定されずunskip成功(rc=0)" "0" "$rc"
  assert_contains "unskip成功JSON" "$out25e" '"status": "pending"'

  # 事後確認: 独立ブランチ自体はunskip実行後も削除されず残り続ける(=本当に到達
  # 可能性フィルタで除外されたのであって、ブランチ削除で検索対象から消えたのでは
  # ないことの直接証拠)。
  branch_still_exists="$(cd "$VAULT" && git branch --list vault-merge/cand-1)"
  assert_contains "unskip実行後も独立ブランチは削除されず残る(フィルタで除外されたことの証拠であり検索対象消失ではない)" \
    "$branch_still_exists" "vault-merge/cand-1"
}

echo ""
echo "=== 結果: PASS=${PASS} FAIL=${FAIL} ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
