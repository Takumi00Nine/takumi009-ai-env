#!/usr/bin/env bash
# claude/hooks/bootstrap-vault.sh のユニットテスト（メイン/サブ両方の回帰テスト）。
#
# 実 Vault($HOME/Data/obsidian) には依存しない。BOOTSTRAP_VAULT 環境変数で
# 毎回ダミーのfixtureディレクトリへ差し替えてスクリプトを実行し、
# 「存在するファイルだけが必読リストに載る」ことを検証する
# （2026-07-08 設計判断: install-sub.sh 対応でメイン/サブ両方の回帰を担保）。
#
# 実行方法: bash tests/test-bootstrap-vault.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"

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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

# 全6ファイルをVAULT配下に作る（メイン相当のfixture）。
make_full_vault() {
  local vault="$1"
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Knowledge/mistakes.md" "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Personal/profile-personal.md" "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

# bootstrap-vault.sh を実行し、additionalContext文字列を返す（単独セッション相当＝
# agent_type無し・チーム未所属。session_idは適当な固定値）。
# reads_log/recall_log・fragments-log/vault-inventoryの出力先ディレクトリは
# 既定で存在しないパス＝実機の $HOME/.claude/logs/* に依存しない
# （外部脳ヘルス行の②③死活チェックが実マシンの状態でテスト結果が揺れないように
# する。2026-07-11 決定でfragments-log/vault-inventoryの出力先がVault配下から
# $HOME/.claude/logs/配下へ移設されたため、5番目・6番目の引数として追加した）。
# knowledge-merge-candidates/vault-merge-alertsの出力先も同じ理由で既定は存在しない
# パスとし、6番目・7番目の引数として追加した（2026-07-12追加）。
# ヘルス行そのものをテストする場合は明示的に渡す。
run_bootstrap() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local frag_log_dir="${4:-/nonexistent-dir/fragments-log}"
  local inv_log_dir="${5:-/nonexistent-dir/vault-inventory}"
  local km_log_dir="${6:-/nonexistent-dir/knowledge-merge-candidates}"
  local alerts_dir="${7:-/nonexistent-dir/vault-merge-alerts}"
  # BOOTSTRAP_DISABLE_PREHEAT=1: Ollama予熱（8.1ラウンド追加）を無効化する。実Ollama/
  # 実ネットワークに依存させず、本テストファイルの既存の関心事（必読ファイル一覧・
  # 外部脳ヘルス行）をhermeticに保つため（予熱自体の専用テストは別途用意する）。
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      FRAGMENTS_LOG_DIR="$frag_log_dir" VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR="$km_log_dir" VAULT_MERGE_ALERTS_DIR="$alerts_dir" \
      BOOTSTRAP_DISABLE_PREHEAT="1" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# agent_type付き（ワーカー扱い）でbootstrap-vault.shを実行する。
run_bootstrap_worker() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local frag_log_dir="${4:-/nonexistent-dir/fragments-log}"
  local inv_log_dir="${5:-/nonexistent-dir/vault-inventory}"
  local km_log_dir="${6:-/nonexistent-dir/knowledge-merge-candidates}"
  local alerts_dir="${7:-/nonexistent-dir/vault-merge-alerts}"
  echo '{"session_id":"test-session-worker","agent_type":"worker"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      FRAGMENTS_LOG_DIR="$frag_log_dir" VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR="$km_log_dir" VAULT_MERGE_ALERTS_DIR="$alerts_dir" \
      BOOTSTRAP_DISABLE_PREHEAT="1" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# N日前のISO8601 UTC時刻（実際のフックと同じく `date -u` で書く。
# tests/test-check-drift.sh の d_ts と同じ考え方＝2026-07-10 敵対的レビュー
# 2回目 N-5 対応でローカルTZとの取り違えを防ぐ）。
d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"d +%Y-%m-%dT%H:%M:%SZ; }

echo "=== 1. メイン相当: 6ファイル全部存在 → 6ファイル全部が必読リストに載る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "6ファイルを読む、の文言" "$ctx" "（6ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Knowledge/mistakes.md が列挙される" "$ctx" "Knowledge/mistakes.md"
  assert_contains "Personal/profile-personal.md が列挙される" "$ctx" "Personal/profile-personal.md"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"
  assert_not_contains "private ノート対象外の注記は出ない（メインでは全部揃うため）" "$ctx" "private ノートはこのマシンには無い"

  rm -rf "$VAULT_DIR"
}

echo "=== 2. サブ相当: private系2ファイル欠如 → 4ファイルのみ列挙+対象外の注記 ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences"
  for f in "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Knowledge/mistakes.md と Personal/profile-personal.md は無い（サブ想定）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "4ファイルを読む、の文言" "$ctx" "（4ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Preferences/absolute-rules.md は列挙される" "$ctx" "Preferences/absolute-rules.md"
  assert_not_contains "Knowledge/mistakes.md は列挙されない（存在しないため）" "$ctx" "Knowledge/mistakes.md"
  assert_not_contains "Personal/profile-personal.md は列挙されない（存在しないため）" "$ctx" "Personal/profile-personal.md"
  assert_contains "private ノート対象外の注記が出る（2件）" "$ctx" "private ノートはこのマシンには無い（サブ）: 2件は対象外"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"

  rm -rf "$VAULT_DIR"
}

echo "=== 3. Vault丸ごと空（0ファイル） → 0ファイルでも壊れずに動く ==="
{
  VAULT_DIR="$(mktemp -d)"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "0ファイルを読む、の文言" "$ctx" "（0ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "6件対象外の注記が出る" "$ctx" "private ノートはこのマシンには無い（サブ）: 6件は対象外"

  rm -rf "$VAULT_DIR"
}

echo "=== 4. 外部脳ヘルス行①: 最新棚卸しレポートの日付+件数が表示される ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
---
date: 2026-06-01
---

# 外部脳 棚卸しレポート 2026-06-01

自動生成。ノート 42 件を検査し、**要確認 3 件**。
EOF
  # 古い方のレポート（日付昇順でglobされるため最新判定に混ざらないことも確認）
  cat > "$INV_DIR/2026-01-01.md" <<'EOF'
自動生成。ノート 10 件を検査し、**要確認 99 件**。
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$INV_DIR")"
  assert_contains "ヘルス見出しが出る" "$ctx" "【外部脳ヘルス】"
  assert_contains "最新(2026-06-01)のフルパスと件数(3件)が出る" "$ctx" "棚卸し最新: ${INV_DIR}/2026-06-01.md（要確認 3 件）"
  assert_not_contains "古い方(2026-01-01/99件)は最新として出ない" "$ctx" "2026-01-01（要確認 99 件）"

  rm -rf "$VAULT_DIR" "$INV_DIR"
}

echo "=== 5. 外部脳ヘルス行①: 件数が拾えない本文でも日付だけにフォールバックする ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  printf '# 外部脳 棚卸しレポート 2026-06-15\n\n本文に「要確認」の文言が無いフォーマット\n' \
    > "$INV_DIR/2026-06-15.md"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$INV_DIR")"
  assert_contains "フルパスだけの表示にフォールバックする" "$ctx" "棚卸し最新: ${INV_DIR}/2026-06-15.md"
  assert_not_contains "件数の丸括弧は付かない" "$ctx" "2026-06-15.md（"

  rm -rf "$VAULT_DIR" "$INV_DIR"
}

echo "=== 5b. 外部脳ヘルス行②(未処理レポート): 両方処理済みなら「未処理レポートなし」==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  FRAG_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
---
date: 2026-06-01
processed: 2026-06-02
---

# 外部脳 棚卸しレポート 2026-06-01
EOF
  cat > "$FRAG_DIR/2026-06-01.md" <<'EOF'
---
date: 2026-06-01
processed: 2026-06-02
---

# Fragments 週次ログ 2026-06-01
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "$FRAG_DIR" "$INV_DIR")"
  assert_contains "未処理レポートなしと出る" "$ctx" "未処理レポートなし"
  assert_not_contains "未処理レポート:（コロン付き一覧）は出ない" "$ctx" "未処理レポート:"

  rm -rf "$VAULT_DIR" "$INV_DIR" "$FRAG_DIR"
}

echo "=== 5c. 外部脳ヘルス行②(未処理レポート): 両方未処理なら両方の日付が出る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  FRAG_DIR="$(mktemp -d)"
  printf '# 外部脳 棚卸しレポート 2026-06-01\n' > "$INV_DIR/2026-06-01.md"
  printf '# Fragments 週次ログ 2026-06-03\n' > "$FRAG_DIR/2026-06-03.md"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "$FRAG_DIR" "$INV_DIR")"
  assert_contains "未処理レポート行が出る（フルパス）" "$ctx" \
    "未処理レポート: fragments-log ${FRAG_DIR}/2026-06-03.md / vault-inventory ${INV_DIR}/2026-06-01.md"

  rm -rf "$VAULT_DIR" "$INV_DIR" "$FRAG_DIR"
}

echo "=== 5d. 外部脳ヘルス行②(未処理レポート): 片方だけ処理済みなら未処理側だけ出る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  FRAG_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
---
date: 2026-06-01
processed: 2026-06-02
---

# 外部脳 棚卸しレポート 2026-06-01
EOF
  printf '# Fragments 週次ログ 2026-06-03\n' > "$FRAG_DIR/2026-06-03.md"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "$FRAG_DIR" "$INV_DIR")"
  assert_contains "未処理レポート: fragments-logのみ出る（フルパス）" "$ctx" "未処理レポート: fragments-log ${FRAG_DIR}/2026-06-03.md"
  assert_not_contains "処理済みのvault-inventoryは未処理一覧に出ない" "$ctx" "vault-inventory ${INV_DIR}/2026-06-01.md"

  rm -rf "$VAULT_DIR" "$INV_DIR" "$FRAG_DIR"
}

echo "=== 5e. 外部脳ヘルス行②(未処理レポート): マーカー形式不正（日付欠如・別キー）は未処理扱い ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
---
date: 2026-06-01
processed: yes
processed_by: leader
---

# 外部脳 棚卸しレポート 2026-06-01
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$INV_DIR")"
  assert_contains "形式不正なマーカーは未処理扱いになる（フルパス）" "$ctx" "未処理レポート: vault-inventory ${INV_DIR}/2026-06-01.md"

  rm -rf "$VAULT_DIR" "$INV_DIR"
}

echo "=== 5f. 外部脳ヘルス行②(未処理レポート): レポートフォルダが両方とも無ければ行自体を出さない(fail-open) ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  # fragments-log/vault-inventoryの出力先ディレクトリを渡さない（既定の
  # 存在しないパス＝vault-agents未導入・サブ機想定）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "未処理レポート関連の行は出ない" "$ctx" "未処理レポート"

  rm -rf "$VAULT_DIR"
}

echo "=== 5g. 外部脳ヘルス行②(未処理レポート): knowledge-merge-candidatesが3つ目として検知される(FR9a) ==="
{
  VAULT_DIR="$(mktemp -d)"
  KM_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  cat > "$KM_DIR/2026-07-06.md" <<'EOF'
---
date: 2026-07-06
tags: [knowledge-merge-candidates, report]
---
# 候補レポート
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$KM_DIR")"
  assert_contains "knowledge-merge-candidatesの未処理フルパスが出る" "$ctx" "未処理レポート: knowledge-merge-candidates ${KM_DIR}/2026-07-06.md"

  rm -rf "$VAULT_DIR" "$KM_DIR"
}

echo "=== 5h. 外部脳ヘルス行②: knowledge-merge-candidatesもprocessedマーカーがあれば未処理扱いにならない ==="
{
  VAULT_DIR="$(mktemp -d)"
  KM_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  cat > "$KM_DIR/2026-07-06.md" <<'EOF'
---
date: 2026-07-06
tags: [knowledge-merge-candidates, report]
processed: 2026-07-07
---
# 候補レポート
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$KM_DIR")"
  assert_contains "未処理レポートなしと出る" "$ctx" "未処理レポートなし"

  rm -rf "$VAULT_DIR" "$KM_DIR"
}

echo "=== 5i. 外部脳ヘルス行④(未解決ALERT・新設): resolvedの無いALERTファイルがあると専用行が出る(FR12b) ==="
{
  VAULT_DIR="$(mktemp -d)"
  ALERTS_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  cat > "$ALERTS_DIR/cand-abc123.md" <<'EOF'
---
date: 2026-07-06
processed: 2026-07-06
attempt_count: 1
---
# ALERT: git競合
EOF
  cat > "$ALERTS_DIR/cand-def456.md" <<'EOF'
---
date: 2026-07-05
processed: 2026-07-05
resolved: 2026-07-06
---
# ALERT: 解消済み
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "" "$ALERTS_DIR")"
  assert_contains "未解決ALERT1件の警告が出る" "$ctx" "⚠️ マージALERT未解決 1件＝マージ停止中"

  rm -rf "$VAULT_DIR" "$ALERTS_DIR"
}

echo "=== 5j. 外部脳ヘルス行④: 全ALERTがresolved済みなら警告行は出ない ==="
{
  VAULT_DIR="$(mktemp -d)"
  ALERTS_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  cat > "$ALERTS_DIR/cand-def456.md" <<'EOF'
---
date: 2026-07-05
processed: 2026-07-05
resolved: 2026-07-06
---
# ALERT: 解消済み
EOF

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "" "$ALERTS_DIR")"
  assert_not_contains "未解決ALERTの警告は出ない" "$ctx" "マージALERT未解決"

  rm -rf "$VAULT_DIR" "$ALERTS_DIR"
}

echo "=== 5k. 外部脳ヘルス行④: ALERTディレクトリが無ければ行自体を出さない(fail-open・ALERT未発生想定) ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "ALERT関連の行は出ない" "$ctx" "マージALERT"

  rm -rf "$VAULT_DIR"
}

echo "=== 6. 外部脳ヘルス行②: reads/recallログが直近${VAULT_AGENT_LOG_STALE_DAYS:-7}日以内なら警告なし ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LOGDIR="$(mktemp -d)"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts -1)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts -1)" > "$LOGDIR/vault-recall.tsv"

  ctx="$(run_bootstrap "$VAULT_DIR" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv")"
  assert_not_contains "フック死の疑いは出ない（直近1日前）" "$ctx" "フック死の疑い"

  rm -rf "$VAULT_DIR" "$LOGDIR"
}

echo "=== 7. 外部脳ヘルス行②: reads/recallログが8日以上前で止まっていると両方とも警告に出る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LOGDIR="$(mktemp -d)"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts -8)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts -8)" > "$LOGDIR/vault-recall.tsv"

  ctx="$(run_bootstrap "$VAULT_DIR" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv")"
  assert_contains "フック死の疑いが出る" "$ctx" "⚠️ フック死の疑い:"
  assert_contains "vault-reads.tsvが名指しされる" "$ctx" "vault-reads.tsv"
  assert_contains "vault-recall.tsvも名指しされる" "$ctx" "vault-recall.tsv"

  rm -rf "$VAULT_DIR" "$LOGDIR"
}

echo "=== 8. 外部脳ヘルス行: 棚卸し・ログとも無い（fail-open）→ ヘルス見出し自体が出ない・本文は健在 ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  # 棚卸しレポート出力先を作らない・ログも渡さない（既定の存在しないパス）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "ヘルス見出しが出ない（無い情報を無理に出さない）" "$ctx" "【外部脳ヘルス】"
  assert_not_contains "本文自体は壊れず末尾まで出る" "$ctx" "見つかりません"
  # ctxが空文字のまま素通りする偽陽性を防ぐため、本文の固有見出しを積極的に
  # 確認する（Codexレビュー指摘・Minor: 否定アサーションのみだとctx自体が
  # 空でも成功してしまう）。
  assert_contains "ブートストラップ本文の見出しは健在（ctxが空で素通りしていないことの確認）" \
    "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"
  assert_contains "本文の必読ファイル指示も健在" "$ctx" "① タスクに着手する前に"

  rm -rf "$VAULT_DIR"
}

echo "=== 8b. 外部脳ヘルス行②: ログ時刻が壊れている/未来日時でもクラッシュせず警告は出さない(fail-open) ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LOGDIR="$(mktemp -d)"
  # 3列目はあるが時刻が壊れている行のみ → 経過日数を計算できずfail-openで無警告
  printf 'not-a-timestamp\tsess1\tKnowledge/x.md\n' > "$LOGDIR/vault-reads.tsv"
  # 未来日時（システム時計のズレ・破損想定）→ age が負になり「7日超過」条件を
  # 満たさないため、こちらもfail-open側（誤ってstale扱いにはしない）。
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 3650)" > "$LOGDIR/vault-recall.tsv"

  ctx="$(run_bootstrap "$VAULT_DIR" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv")"
  assert_contains "本文は壊れず出力される" "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"
  assert_not_contains "壊れた時刻・未来日時ではフック死の疑いを誤って出さない(fail-open)" \
    "$ctx" "フック死の疑い"

  rm -rf "$VAULT_DIR" "$LOGDIR"
}

echo "=== 9. 外部脳ヘルス行: ワーカー向け軽量版には注入されない ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
自動生成。ノート 42 件を検査し、**要確認 3 件**。
EOF
  LOGDIR="$(mktemp -d)"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts -8)" > "$LOGDIR/vault-reads.tsv"
  ALERTS_DIR="$(mktemp -d)"
  cat > "$ALERTS_DIR/cand-abc123.md" <<'EOF'
---
date: 2026-07-06
---
# ALERT
EOF

  ctx="$(run_bootstrap_worker "$VAULT_DIR" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "" "$INV_DIR" "" "$ALERTS_DIR")"
  assert_not_contains "ワーカー版にはヘルス見出しが出ない" "$ctx" "【外部脳ヘルス】"
  assert_not_contains "ワーカー版には棚卸し情報も出ない" "$ctx" "棚卸し最新"
  assert_not_contains "ワーカー版にはフック死の疑いも出ない" "$ctx" "フック死の疑い"
  assert_not_contains "ワーカー版には未処理レポート情報も出ない" "$ctx" "未処理レポート"
  assert_not_contains "ワーカー版には未解決ALERT情報も出ない" "$ctx" "マージALERT"
  assert_contains "ワーカー版本文は健在" "$ctx" "【チームメイト用ブートストラップ｜軽量版】"

  rm -rf "$VAULT_DIR" "$LOGDIR" "$INV_DIR" "$ALERTS_DIR"
}

echo "=== 10. Ollama予熱(8.1ラウンド追加): 既に起動済みならollama serveを呼ばずwarm embedのみ ==="
{
  VAULT_DIR="$(mktemp -d)"; make_full_vault "$VAULT_DIR"
  BIN_DIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  PAYLOAD_FILE="$(mktemp)"
  # -dの直後の引数（JSON payload）だけを別ファイルへ書き出す（Codexレビュー指摘・
  # Minor: 文字列としての部分一致だけでなく、値レベル(options.num_ctx==8192等)を
  # jq/pythonで厳密検証できるようにするため）。
  cat > "$BIN_DIR/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-d" ]; then
    printf '%s' "\$a" > "$PAYLOAD_FILE"
  fi
  prev="\$a"
done
exit 0
CURLEOF
  chmod +x "$BIN_DIR/curl"
  cat > "$BIN_DIR/ollama" <<OLLAMAEOF
#!/bin/bash
echo "ollama \$@" >> "$CALLS"
OLLAMAEOF
  chmod +x "$BIN_DIR/ollama"

  echo '{"session_id":"test-session-preheat-1"}' \
    | PATH="$BIN_DIR:$PATH" BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/x" VAULT_RECALL_LOG="/nonexistent-dir/y" \
      FRAGMENTS_LOG_DIR="/nonexistent-dir/f" VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/i" \
      "$SCRIPT" > /dev/null

  # fire-and-forgetでバックグラウンド実行されるため、完了を短いポーリングで待つ
  # （固定sleepの積み上げではなく「条件が満たされるまで」の待ち方＝Monitor代替）。
  waited=0
  while ! grep -q "api/embed" "$CALLS" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done

  assert_contains "api/tagsで疎通確認する" "$(cat "$CALLS")" "api/tags"
  assert_contains "api/embedで予熱する" "$(cat "$CALLS")" "api/embed"
  assert_not_contains "既に起動済みならollama serveは呼ばない" "$(cat "$CALLS")" "ollama serve"

  # 値レベルでJSONとして検証する（Codexレビュー指摘・Minor: 文字列部分一致だけだと
  # 値が違っていたりJSONが壊れていても素通りしてしまう）。
  payload_num_ctx="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['options']['num_ctx'])" 2>/dev/null)"
  payload_num_batch="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['options']['num_batch'])" 2>/dev/null)"
  payload_input="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['input'])" 2>/dev/null)"
  assert_eq "予熱リクエストのoptions.num_ctxは4096（値レベル検証・2026-07-11実測でnum_ctx既定を8192から引き下げ）" "4096" "$payload_num_ctx"
  assert_eq "予熱リクエストのoptions.num_batchは4096（値レベル検証・2026-07-11実測でnum_ctx既定を8192から引き下げ）" "4096" "$payload_num_batch"
  assert_eq "予熱リクエストのinputは空文字（値レベル検証）" "" "$payload_input"

  rm -rf "$VAULT_DIR" "$BIN_DIR" "$CALLS"
  rm -f "$PAYLOAD_FILE"
}

echo "=== 11. Ollama予熱: 未起動ならollama serveを起動してから疎通を待ってwarm embedする ==="
{
  VAULT_DIR="$(mktemp -d)"; make_full_vault "$VAULT_DIR"
  BIN_DIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  MARKER="$(mktemp -u)"
  PAYLOAD_FILE="$(mktemp)"
  cat > "$BIN_DIR/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-d" ]; then
    printf '%s' "\$a" > "$PAYLOAD_FILE"
  fi
  prev="\$a"
done
case "\$*" in
  *api/tags*) [ -f "$MARKER" ] && exit 0 || exit 7 ;;
  *) exit 0 ;;
esac
CURLEOF
  chmod +x "$BIN_DIR/curl"
  # OLLAMA_NUM_PARALLEL環境変数がollama serve起動時に付与されているかも記録する
  # （リーダー実機実測対応・メモリ削減のため1並列に絞る指示）。
  cat > "$BIN_DIR/ollama" <<OLLAMAEOF
#!/bin/bash
echo "ollama \$@ OLLAMA_NUM_PARALLEL=\${OLLAMA_NUM_PARALLEL:-unset}" >> "$CALLS"
touch "$MARKER"
OLLAMAEOF
  chmod +x "$BIN_DIR/ollama"

  echo '{"session_id":"test-session-preheat-2"}' \
    | PATH="$BIN_DIR:$PATH" BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/x" VAULT_RECALL_LOG="/nonexistent-dir/y" \
      FRAGMENTS_LOG_DIR="/nonexistent-dir/f" VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/i" \
      "$SCRIPT" > /dev/null

  waited=0
  while ! grep -q "api/embed" "$CALLS" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done

  assert_contains "ollama serveを起動する" "$(cat "$CALLS")" "ollama serve"
  assert_contains "起動後にwarm embedする" "$(cat "$CALLS")" "api/embed"
  assert_contains "ollama serve起動時にOLLAMA_NUM_PARALLEL=1が付与される（メモリ削減・リーダー実機実測対応）" \
    "$(cat "$CALLS")" "OLLAMA_NUM_PARALLEL=1"

  payload_num_ctx="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['options']['num_ctx'])" 2>/dev/null)"
  payload_num_batch="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['options']['num_batch'])" 2>/dev/null)"
  assert_eq "予熱リクエストのoptions.num_ctxは4096（値レベル検証・2026-07-11実測でnum_ctx既定を8192から引き下げ）" "4096" "$payload_num_ctx"
  assert_eq "予熱リクエストのoptions.num_batchは4096（値レベル検証・2026-07-11実測でnum_ctx既定を8192から引き下げ）" "4096" "$payload_num_batch"

  rm -rf "$VAULT_DIR" "$BIN_DIR" "$CALLS"
  rm -f "$MARKER" "$PAYLOAD_FILE"
}

echo "=== 11b. Ollama予熱: VAULT_EMBED_NUM_CTX/VAULT_EMBED_NUM_BATCHで上書きした値が予熱リクエストに反映される ==="
{
  VAULT_DIR="$(mktemp -d)"; make_full_vault "$VAULT_DIR"
  BIN_DIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  PAYLOAD_FILE="$(mktemp)"
  cat > "$BIN_DIR/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-d" ]; then
    printf '%s' "\$a" > "$PAYLOAD_FILE"
  fi
  prev="\$a"
done
exit 0
CURLEOF
  chmod +x "$BIN_DIR/curl"

  echo '{"session_id":"test-session-preheat-ctx-override"}' \
    | PATH="$BIN_DIR:$PATH" BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/x" VAULT_RECALL_LOG="/nonexistent-dir/y" \
      FRAGMENTS_LOG_DIR="/nonexistent-dir/f" VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/i" \
      VAULT_EMBED_NUM_CTX="4096" VAULT_EMBED_NUM_BATCH="2048" \
      "$SCRIPT" > /dev/null

  waited=0
  while ! grep -q "api/embed" "$CALLS" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done

  payload_num_ctx="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['options']['num_ctx'])" 2>/dev/null)"
  payload_num_batch="$(python3 -c "import json; print(json.load(open('$PAYLOAD_FILE'))['options']['num_batch'])" 2>/dev/null)"
  assert_eq "VAULT_EMBED_NUM_CTX上書きが予熱リクエストへ反映される" "4096" "$payload_num_ctx"
  assert_eq "VAULT_EMBED_NUM_BATCH上書きが予熱リクエストへ反映される" "2048" "$payload_num_batch"

  rm -rf "$VAULT_DIR" "$BIN_DIR" "$CALLS"
  rm -f "$PAYLOAD_FILE"
}

echo "=== 12. Ollama予熱: BOOTSTRAP_DISABLE_PREHEAT=1で完全に呼ばれない ==="
{
  VAULT_DIR="$(mktemp -d)"; make_full_vault "$VAULT_DIR"
  BIN_DIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  cat > "$BIN_DIR/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
exit 0
CURLEOF
  chmod +x "$BIN_DIR/curl"

  echo '{"session_id":"test-session-preheat-3"}' \
    | PATH="$BIN_DIR:$PATH" BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/x" VAULT_RECALL_LOG="/nonexistent-dir/y" \
      FRAGMENTS_LOG_DIR="/nonexistent-dir/f" VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/i" \
      BOOTSTRAP_DISABLE_PREHEAT="1" "$SCRIPT" > /dev/null

  sleep 0.5   # 万一バックグラウンドで何か起きてもここまでに現れるはずの猶予
  assert_eq "curlは一切呼ばれない（CALLSファイルは空のまま）" "" "$(cat "$CALLS" 2>/dev/null)"

  rm -rf "$VAULT_DIR" "$BIN_DIR" "$CALLS"
}

echo "=== 13. Ollama予熱: ワーカー軽量版分岐では呼ばれない（多重予熱防止） ==="
{
  VAULT_DIR="$(mktemp -d)"; make_full_vault "$VAULT_DIR"
  BIN_DIR="$(mktemp -d)"
  CALLS="$(mktemp)"
  cat > "$BIN_DIR/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> "$CALLS"
exit 0
CURLEOF
  chmod +x "$BIN_DIR/curl"

  echo '{"session_id":"test-session-preheat-4","agent_type":"worker"}' \
    | PATH="$BIN_DIR:$PATH" BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/x" VAULT_RECALL_LOG="/nonexistent-dir/y" \
      FRAGMENTS_LOG_DIR="/nonexistent-dir/f" VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/i" \
      "$SCRIPT" > /dev/null

  sleep 0.5
  assert_eq "ワーカー版ではcurlが一切呼ばれない" "" "$(cat "$CALLS" 2>/dev/null)"

  rm -rf "$VAULT_DIR" "$BIN_DIR" "$CALLS"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
