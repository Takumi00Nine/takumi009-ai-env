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
{"candidates": {"cand-1": {"candidate_id": "cand-1", "note_a": "Knowledge/note-a.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
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
{"candidates": {"trav": {"candidate_id": "trav", "note_a": "Knowledge/../Preferences/x.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "パストラバーサルはcleared=false" "$out" '"cleared": false'

  cat > "$STATE" <<EOF
{"candidates": {"outside": {"candidate_id": "outside", "note_a": "Preferences/absolute-rules.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "Knowledge/直下以外はcleared=false" "$out" '"cleared": false'

  ln -s /tmp "$VAULT/Knowledge/evil.md" 2>/dev/null
  cat > "$STATE" <<EOF
{"candidates": {"sym": {"candidate_id": "sym", "note_a": "Knowledge/evil.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
EOF
  out="$(python3 "$SCRIPT" preflight --vault "$VAULT" --state-file "$STATE" --alerts-dir "$ALERTS" \
    --worktrees-dir "$WT_DIR" --lock-file "$LOCK" --json)"
  assert_contains "symlinkはcleared=false" "$out" '"cleared": false'
  rm -f "$VAULT/Knowledge/evil.md"

  cat > "$STATE" <<EOF
{"candidates": {"nx": {"candidate_id": "nx", "note_a": "Knowledge/does-not-exist.md", "note_b": "Knowledge/note-b.md", "status": "pending"}}}
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

echo ""
echo "=== 結果: PASS=${PASS} FAIL=${FAIL} ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
