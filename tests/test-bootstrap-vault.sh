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

# 全7ファイルをVAULT配下に作る（メイン相当のfixture）。2026-08-30 §9.0 A-1-3
# 波及改修（本人承認済み）: `Knowledge/mistakes.md` を除去し
# `Preferences/core-conduct.md`・`Preferences/core-workflow.md` を追加した
# bootstrap-vault.shのFILES配列と同じ構成にする。
make_full_vault() {
  local vault="$1"
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/profile.md" "Personal/profile-personal.md" "Preferences/coding-delegation.md" \
           "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

# bootstrap-vault.sh を実行し、additionalContext文字列を返す（単独セッション相当＝
# agent_type無し・チーム未所属。session_idは適当な固定値）。
# reads_log/recall_log・vault-inventoryの出力先ディレクトリは既定で存在しないパス＝
# 実機の $HOME/.claude/logs/* に依存しない（外部脳ヘルス行の①③死活チェックが
# 実マシンの状態でテスト結果が揺れないようにする）。ヘルス行そのものをテストする
# 場合は明示的に渡す。
# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で
# 未処理レポート検知（fragments-log/knowledge-merge-candidates）・未解決ALERT監視・
# Ollama予熱を撤去したため、対応する引数（frag_log_dir/km_log_dir/alerts_dir・
# BOOTSTRAP_DISABLE_PREHEAT）も削除した。
# 2026-07-18ハードニングでPreferences提案pendingマーカー層を撤去し提案
# ディレクトリの直接スキャン方式へ変更したため、5番目の引数は
# pending_file(単一ファイル)からproposals_dir(ディレクトリ)へ変わった。
# last-run.jsonの死活検知（6番目の引数）も同時に追加した。
# 7番目の引数はmachine-roleマーカーファイルのパス（既定は存在しないパス＝
# マーカー無し。中身が厳密に"sub"のときだけ④死活検知をスキップする挙動の
# テスト用に2026-08-06追加）。
run_bootstrap() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local inv_log_dir="${4:-/nonexistent-dir/vault-inventory}"
  local proposals_dir="${5:-/nonexistent-dir/preferences-proposals}"
  local last_run_file="${6:-/nonexistent-dir/last-run.json}"
  local role_marker="${7:-/nonexistent-dir/machine-role}"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      PREFERENCES_PROPOSALS_DIR="$proposals_dir" \
      MAINTENANCE_LAST_RUN_FILE="$last_run_file" \
      AIENV_MACHINE_ROLE_MARKER="$role_marker" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# P1機構（ローカル実体プロファイル）のテスト専用ヘルパー。
# BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 を明示して有効化した状態で実行する
# （既定は無効のまま＝run_bootstrap()と挙動を変えないための独立ヘルパー）。
run_bootstrap_with_profile() {
  local vault="$1" profile_path="$2"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_MACHINE_ROLE_MARKER="/nonexistent-dir/machine-role" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# 最小能力表7キーすべてに実運用値を入れた「壊れていない」profile.mdを作る。
make_ok_profile() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
---
inventory_source: Vault(Preferences/Knowledge直下)
reviewer: 本人
vault_write: configured(vault-scribe)
vault_scope: Preferences配下のみ
ui.user_call: SendMessage(to: main)
git_role: push可(takumi009-ai-env repo限定)
web_verification: WebSearch/WebFetch
---
EOF
}

# agent_type付き（ワーカー扱い）でbootstrap-vault.shを実行する。
run_bootstrap_worker() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local inv_log_dir="${4:-/nonexistent-dir/vault-inventory}"
  local proposals_dir="${5:-/nonexistent-dir/preferences-proposals}"
  local last_run_file="${6:-/nonexistent-dir/last-run.json}"
  echo '{"session_id":"test-session-worker","agent_type":"worker"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      PREFERENCES_PROPOSALS_DIR="$proposals_dir" \
      MAINTENANCE_LAST_RUN_FILE="$last_run_file" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# N日前のISO8601 UTC時刻（実際のフックと同じく `date -u` で書く。
# tests/test-check-drift.sh の d_ts と同じ考え方＝2026-07-10 敵対的レビュー
# 2回目 N-5 対応でローカルTZとの取り違えを防ぐ）。
d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"d +%Y-%m-%dT%H:%M:%SZ; }

echo "=== 1. メイン相当: 7ファイル全部存在 → 7ファイル全部が必読リストに載る（2026-08-30 §9.0 A-1-3波及改修後の構成） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "7ファイルを読む、の文言" "$ctx" "（7ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Preferences/core-conduct.md が列挙される" "$ctx" "Preferences/core-conduct.md"
  assert_contains "Preferences/core-workflow.md が列挙される" "$ctx" "Preferences/core-workflow.md"
  assert_not_contains "Knowledge/mistakes.md はもう必読に含まれない（P2除去対象）" "$ctx" "Knowledge/mistakes.md"
  assert_contains "Personal/profile-personal.md が列挙される" "$ctx" "Personal/profile-personal.md"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"
  assert_not_contains "private ノート対象外の注記は出ない（メインでは全部揃うため）" "$ctx" "private ノートはこのマシンには無い"

  rm -rf "$VAULT_DIR"
}

echo "=== 2. サブ相当: private系1ファイル欠如 → 6ファイルのみ列挙+対象外の注記（core-conduct/core-workflowはPreferences配下＝サブにも届く前提） ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/profile.md" "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Personal/profile-personal.md だけが無い（サブ想定＝private層の意図的欠落）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "6ファイルを読む、の文言" "$ctx" "（6ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Preferences/absolute-rules.md は列挙される" "$ctx" "Preferences/absolute-rules.md"
  assert_contains "Preferences/core-conduct.md は列挙される（サブにも届く）" "$ctx" "Preferences/core-conduct.md"
  assert_contains "Preferences/core-workflow.md は列挙される（サブにも届く）" "$ctx" "Preferences/core-workflow.md"
  assert_not_contains "Personal/profile-personal.md は列挙されない（存在しないため）" "$ctx" "Personal/profile-personal.md"
  assert_contains "private ノート対象外の注記が出る（1件）" "$ctx" "private ノートはこのマシンには無い（サブ）: 1件は対象外"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"

  rm -rf "$VAULT_DIR"
}

echo "=== 3. Vault丸ごと空（0ファイル） → 0ファイルでも壊れずに動く ==="
{
  VAULT_DIR="$(mktemp -d)"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "0ファイルを読む、の文言" "$ctx" "（0ファイルを1回の並列 Read で同時取得すること）"
  # 2026-08-30 Codex一次レビュー指摘・Major対応: FILES配列のうち
  # 意図的private層はPersonal/profile-personal.mdの1件だけなので、
  # 「private対象外」は1件のみ。残り6件（Preferences配下の必須publicノート）は
  # 「想定外の欠落」として別枠で強めに警告される（下のテスト3bで直接検証）。
  assert_contains "private対象外の注記は1件のみ" "$ctx" "private ノートはこのマシンには無い（サブ）: 1件は対象外"
  assert_contains "想定外欠落の警告が出る" "$ctx" "必読のはずのpublicノートが見つかりません"

  rm -rf "$VAULT_DIR"
}

echo "=== 3b. 必須publicノート(core-conduct.md)だけが欠落 → private対象外にはせず「想定外」として強めに警告する（Codex一次レビュー指摘・Major対応: §7.3③『どちらも読まれない窓』の実検知） ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-workflow.md" \
           "Preferences/profile.md" "Personal/profile-personal.md" \
           "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Preferences/core-conduct.md だけを欠落させる（移送失敗・sync漏れ等を模す）。

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "6ファイルを読む、の文言" "$ctx" "（6ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "想定外欠落の警告にcore-conduct.mdのフルパスが出る" "$ctx" "Preferences/core-conduct.md"
  assert_contains "想定外欠落の警告文言が出る" "$ctx" "必読のはずのpublicノートが見つかりません"
  assert_not_contains "core-conduct.mdの欠落は「privateノート対象外」には数えられない（profile-personal.mdは存在するため当該注記自体が出ない）" "$ctx" "private ノートはこのマシンには無い"

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

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "$INV_DIR")"
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

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "$INV_DIR")"
  assert_contains "フルパスだけの表示にフォールバックする" "$ctx" "棚卸し最新: ${INV_DIR}/2026-06-15.md"
  assert_not_contains "件数の丸括弧は付かない" "$ctx" "2026-06-15.md（"

  rm -rf "$VAULT_DIR" "$INV_DIR"
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

echo "=== 7b. Preferences提案: 提案ディレクトリに*.mdが1件以上あれば確認するまで毎起動で通知が出る（2026-07-18ハードニング・pendingマーカー層撤去） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROPOSALS_DIR="$(mktemp -d)"
  echo "下書き本文" > "$PROPOSALS_DIR/sample-preference-note.md"
  echo "下書き本文" > "$PROPOSALS_DIR/another-note.md"
  # sidecarの.meta.jsonは件数に数えない（*.mdのみが正本）ことも同時に確認する。
  echo '{}' > "$PROPOSALS_DIR/sample-preference-note.meta.json"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$PROPOSALS_DIR")"
  assert_contains "未確認2件の通知が出る" "$ctx" "🆕 夜間バッチで運用ルールの昇格提案があります（未確認2件）"
  assert_contains "1件目のslugが列挙される" "$ctx" "sample-preference-note"
  assert_contains "2件目のslugも列挙される" "$ctx" "another-note"

  rm -rf "$VAULT_DIR" "$PROPOSALS_DIR"
}

echo "=== 7b2. Preferences提案: slug列挙は先頭5件まで・6件目以降は「ほかN件」に畳む（tester2差し戻し対応・任意Minor。方式変更後も踏襲） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROPOSALS_DIR="$(mktemp -d)"
  for i in 0 1 2 3 4 5 6; do
    echo "下書き本文" > "$PROPOSALS_DIR/slug-$i.md"
  done

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$PROPOSALS_DIR")"
  assert_contains "総数7件はそのまま出る" "$ctx" "未確認7件"
  assert_contains "先頭5件目(slug-4)までは列挙される" "$ctx" "slug-4"
  assert_not_contains "6件目(slug-5)は列挙されない" "$ctx" "slug-5"
  assert_not_contains "7件目(slug-6)は列挙されない" "$ctx" "slug-6"
  assert_contains "6件目以降は「ほか2件」に畳まれる" "$ctx" "ほか2件"

  rm -rf "$VAULT_DIR" "$PROPOSALS_DIR"
}

echo "=== 7c. Preferences提案: 提案ディレクトリが無ければ通知は出ない ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "/nonexistent-dir/preferences-proposals")"
  assert_not_contains "ディレクトリが無ければ通知は出ない" "$ctx" "夜間バッチで運用ルールの昇格提案"

  rm -rf "$VAULT_DIR"
}

echo "=== 7d. Preferences提案: ディレクトリが存在しても*.mdが0件なら通知は出ない ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROPOSALS_DIR="$(mktemp -d)"
  echo '{}' > "$PROPOSALS_DIR/orphan-sidecar.meta.json"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$PROPOSALS_DIR")"
  assert_not_contains "*.mdが0件（sidecarのみ）なら通知は出ない" "$ctx" "夜間バッチで運用ルールの昇格提案"

  rm -rf "$VAULT_DIR" "$PROPOSALS_DIR"
}

echo "=== 7e. Preferences提案: 承認/却下でリーダーが.mdを削除すると通知件数が自然に追従する ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROPOSALS_DIR="$(mktemp -d)"
  echo "下書き本文" > "$PROPOSALS_DIR/sample-preference-note.md"

  ctx_before="$(run_bootstrap "$VAULT_DIR" "" "" "" "$PROPOSALS_DIR")"
  assert_contains "削除前は未確認1件の通知が出る" "$ctx_before" "未確認1件"

  rm -f "$PROPOSALS_DIR/sample-preference-note.md"
  ctx_after="$(run_bootstrap "$VAULT_DIR" "" "" "" "$PROPOSALS_DIR")"
  assert_not_contains ".md削除後は通知が出ない（マーカー同期処理が不要になった）" "$ctx_after" "夜間バッチで運用ルールの昇格提案"

  rm -rf "$VAULT_DIR" "$PROPOSALS_DIR"
}

echo "=== 7f. Preferences提案: 提案ディレクトリの場所がファイル（ディレクトリでない）でもクラッシュせず通知は出ない(fail-open) ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  TMPBASE="$(mktemp -d)"
  NOT_A_DIR="$TMPBASE/preferences-proposals"
  echo "not a directory" > "$NOT_A_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$NOT_A_DIR")"
  assert_not_contains "ディレクトリでない場合は通知を誤って出さない(fail-open)" "$ctx" "夜間バッチで運用ルールの昇格提案"
  assert_contains "本文自体は壊れず出力される" "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"

  rm -rf "$VAULT_DIR" "$TMPBASE"
}

echo "=== 7f2. Preferences提案: 提案ディレクトリが存在するが読取権限が無い(scandir失敗)場合もクラッシュせず通知は出ない(fail-open。2026-07-18ハードニングCodexレビュー指摘Minor対応) ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  TMPBASE="$(mktemp -d)"
  UNREADABLE_DIR="$TMPBASE/preferences-proposals"
  mkdir -p "$UNREADABLE_DIR"
  echo "下書き本文" > "$UNREADABLE_DIR/x.md"
  chmod 0000 "$UNREADABLE_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "$UNREADABLE_DIR")"
  chmod 0700 "$UNREADABLE_DIR"
  assert_not_contains "読取権限が無いディレクトリでも通知を誤って出さない(fail-open)" "$ctx" "夜間バッチで運用ルールの昇格提案"
  assert_contains "本文自体は壊れず出力される" "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"

  rm -rf "$VAULT_DIR" "$TMPBASE"
}

echo "=== 7g. 外部脳ヘルス行④: last-run.jsonのstarted_atが直近(1日前)なら死活警告は出ない ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s"}' "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_not_contains "直近実行なら死活警告は出ない" "$ctx" "週次メンテが"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7h. 外部脳ヘルス行④: last-run.jsonのstarted_atが8日以上前なら死活警告が出る（Critical対処・2026-07-18ハードニング） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s"}' "$(d_ts -10)" "$(d_ts -10)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "10日動いていない旨の死活警告が出る" "$ctx" "⚠️ 週次メンテが10日動いていません"
  # last-run.jsonのフルパスが末尾に文字化けせず出る（2026-08-10実測発見:
  # macOS標準bash 3.2は`$VAR）`（波括弧無し・直後に全角文字）で変数展開が
  # 化ける実害があり、本行はその回帰確認。詳細はclaude/hooks/bootstrap-
  # vault.sh側の同トピックのコメント参照）。
  assert_contains "last-run.jsonのフルパスが文字化けせず出る（bash 3.2の\$VAR）文字化けバグの回帰確認）" \
    "$ctx" "last-run.json: ${LAST_RUN_FILE}）"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7h2. 外部脳ヘルス行④: 境界値（7日前は警告なし・ちょうど8日前は警告あり）（2026-07-18ハードニングCodexレビュー指摘Minor対応） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  LAST_RUN_DIR7="$(mktemp -d)"
  LAST_RUN_FILE7="$LAST_RUN_DIR7/last-run.json"
  printf '{"started_at": "%s"}' "$(d_ts -7)" > "$LAST_RUN_FILE7"
  ctx7="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE7")"
  assert_not_contains "7日前(境界未満)では警告は出ない" "$ctx7" "週次メンテが"

  LAST_RUN_DIR8="$(mktemp -d)"
  LAST_RUN_FILE8="$LAST_RUN_DIR8/last-run.json"
  printf '{"started_at": "%s"}' "$(d_ts -8)" > "$LAST_RUN_FILE8"
  ctx8="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE8")"
  assert_contains "ちょうど8日前(境界)では警告が出る" "$ctx8" "⚠️ 週次メンテが8日動いていません"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR7" "$LAST_RUN_DIR8"
}

echo "=== 7i. 外部脳ヘルス行④(b): last-run.json自体が無い/壊れている/時刻が両方とも壊れているのいずれでもクラッシュせず「状態記録が無い/壊れています」を警告する（2周目ハードニング・従来の完全silentから変更） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx1="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "/nonexistent-dir/last-run.json")"
  assert_not_contains "ファイルが無ければ「動いていません」ではなく" "$ctx1" "週次メンテが動いていません"
  assert_not_contains "「起動はするが」でもない" "$ctx1" "起動はするが"
  assert_contains "ファイルが無ければ状態記録なしの警告が出る" "$ctx1" "⚠️ 週次メンテの状態記録が無い/壊れています"

  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf 'not valid json{{{' > "$LAST_RUN_FILE"
  ctx2="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "壊れたJSONでも状態記録なしの警告が出る(fail-openだが沈黙しない)" "$ctx2" "⚠️ 週次メンテの状態記録が無い/壊れています"

  printf '{"started_at": "not-a-timestamp"}' > "$LAST_RUN_FILE"
  ctx3="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "started_atの時刻が壊れており他に手がかりが無ければ状態記録なしの警告が出る" "$ctx3" "⚠️ 週次メンテの状態記録が無い/壊れています"
  assert_contains "本文自体は壊れず出力される" "$ctx3" "【セッション開始ブートストラップ｜ハーネス強制注入】"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7j. 外部脳ヘルス行④(a): started_atは直近(1日前)でもlast_success_atが8日以上前なら「起動はするが成功していない」を警告する（2周目ハードニング・毎週起動して毎週失敗の不可視対応） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s"}' "$(d_ts -1)" "$(d_ts -10)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "起動はするが10日成功していない旨の警告が出る" "$ctx" "⚠️ 週次メンテが起動はするが10日成功していません"
  assert_not_contains "「動いていません」（全停止）とは混同しない" "$ctx" "週次メンテが10日動いていません"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7k. 外部脳ヘルス行④(a): 境界値（last_success_atが7日前は警告なし・ちょうど8日前は警告あり。started_atは直近固定） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  LAST_RUN_DIR7="$(mktemp -d)"
  LAST_RUN_FILE7="$LAST_RUN_DIR7/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s"}' "$(d_ts -1)" "$(d_ts -7)" > "$LAST_RUN_FILE7"
  ctx7="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE7")"
  assert_not_contains "last_success_atが7日前(境界未満)では警告なし" "$ctx7" "成功していません"

  LAST_RUN_DIR8="$(mktemp -d)"
  LAST_RUN_FILE8="$LAST_RUN_DIR8/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s"}' "$(d_ts -1)" "$(d_ts -8)" > "$LAST_RUN_FILE8"
  ctx8="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE8")"
  assert_contains "last_success_atがちょうど8日前(境界)では警告が出る" "$ctx8" "⚠️ 週次メンテが起動はするが8日成功していません"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR7" "$LAST_RUN_DIR8"
}

echo "=== 7l. 外部脳ヘルス行④: last_success_atが未設定（初回相当）でもstarted_atが直近なら警告は出ない（起動していない/日時解析不能とは異なる正常な過渡状態） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s"}' "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_not_contains "last_success_at未設定・started_at直近では何も警告しない" "$ctx" "週次メンテ"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7l2. 外部脳ヘルス行④(b): last_success_atだけ値が壊れている(started_atは正常・直近)場合も状態記録の警告が出る（tester4差し戻し・Major対応: A②の穴＝非対称破損パターン① last_success_atのみ破損） ==="
{
  # 従来はstarted_epoch/success_epochの両方が空のときしか(b)が発火せず、
  # started_atが正常なままlast_success_atだけ壊れていると完全に沈黙していた
  # （(a)が狙う「起動するが成功しない」検知そのものが破損データで無効化される
  # 最も痛いケース）。
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "not-a-timestamp"}' "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "last_success_atのみ破損でも状態記録の警告が出る(沈黙しない)" "$ctx" "⚠️ 週次メンテの状態記録が無い/壊れています"
  assert_not_contains "「起動はするが」の誤判定にはならない(値を信用できないため)" "$ctx" "起動はするが"
  assert_not_contains "「動いていません」の誤判定にもならない" "$ctx" "週次メンテが1日動いていません"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7l3. 外部脳ヘルス行④(b): started_atだけ値が壊れている(last_success_atは正常・直近)場合も状態記録の警告が出る（tester4差し戻し・Major対応: 非対称破損パターン② started_atのみ破損） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "not-a-timestamp", "last_success_at": "%s"}' "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "started_atのみ破損でも状態記録の警告が出る(沈黙しない)" "$ctx" "⚠️ 週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7l4. 外部脳ヘルス行④(b): started_at・last_success_atが両方とも未来日時(時計ズレ/破損の疑い)の場合も状態記録の警告が出る（tester4差し戻し・Major対応: 非対称破損パターン③ 両方未来日） ==="
{
  # 未来日時はdate解析自体は成功する（形式は正しい）ため、解析失敗のみを
  # 見る従来の判定では素通りしてしまう（age計算が負になりstale判定も
  # 永久にすり抜ける）。解析成功でも未来日時なら「壊れている」扱いにする。
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s"}' "$(d_ts 30)" "$(d_ts 30)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "両方未来日時でも状態記録の警告が出る(沈黙しない)" "$ctx" "⚠️ 週次メンテの状態記録が無い/壊れています"
  assert_not_contains "「動いていません」（負のage）の誤判定にはならない" "$ctx" "週次メンテが"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7l5. 外部脳ヘルス行④(b): last_success_atキーは実在するが値が空文字列/nullの場合も『キー自体が無い(初回未成功)』と誤認せず状態記録の警告が出る（2周目再レビュー指摘Major対応: \`.field // empty\`だけではキー欠落と空文字列/nullを区別できない穴） ==="
{
  # maintenance.sh自身は有効なISO8601文字列しか書かない契約のため、
  # 「キーは実在するのに値が空/null」は書込側の異常（破損）を示す信号で
  # あり、「まだ一度も成功していない」という正常な過渡状態（＝キー自体が
  # 無い・7l系テスト）と混同してはいけない。`jq -r '.field // empty'`だけ
  # では、値が空文字列/null/falseのいずれもキー欠落と同じ出力（空文字列）
  # になり区別できない（Codex再レビュー指摘・Major）ため、`has()`で
  # キーの実在を独立に確認する実装へ修正した。
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  LAST_RUN_DIR_EMPTY="$(mktemp -d)"
  LAST_RUN_FILE_EMPTY="$LAST_RUN_DIR_EMPTY/last-run.json"
  printf '{"started_at": "%s", "last_success_at": ""}' "$(d_ts -1)" > "$LAST_RUN_FILE_EMPTY"
  ctx_empty="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE_EMPTY")"
  assert_contains "last_success_atが空文字列(キーは実在)でも状態記録の警告が出る" \
    "$ctx_empty" "⚠️ 週次メンテの状態記録が無い/壊れています"

  LAST_RUN_DIR_NULL="$(mktemp -d)"
  LAST_RUN_FILE_NULL="$LAST_RUN_DIR_NULL/last-run.json"
  printf '{"started_at": "%s", "last_success_at": null}' "$(d_ts -1)" > "$LAST_RUN_FILE_NULL"
  ctx_null="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE_NULL")"
  assert_contains "last_success_atがnull(キーは実在)でも状態記録の警告が出る" \
    "$ctx_null" "⚠️ 週次メンテの状態記録が無い/壊れています"

  LAST_RUN_DIR_STARTED_EMPTY="$(mktemp -d)"
  LAST_RUN_FILE_STARTED_EMPTY="$LAST_RUN_DIR_STARTED_EMPTY/last-run.json"
  printf '{"started_at": "", "last_success_at": "%s"}' "$(d_ts -1)" > "$LAST_RUN_FILE_STARTED_EMPTY"
  ctx_started_empty="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE_STARTED_EMPTY")"
  assert_contains "started_atが空文字列(last_success_atは正常)でも状態記録の警告が出る" \
    "$ctx_started_empty" "⚠️ 週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR_EMPTY" "$LAST_RUN_DIR_NULL" "$LAST_RUN_DIR_STARTED_EMPTY"
}

echo "=== 7m. 外部脳ヘルス行④: machine-roleマーカーが\"sub\"かつlast-run.json不在でも④の警告は出ない（サブ機はmaintenance.sh非搭載＝2026-08-06対応、本人報告・実害中の解消） ==="
{
  # maintenance.sh(週次メンテ)・LaunchAgentはメイン機専用機能でサブ機には
  # 存在しないため、④の警告は毎セッション必ず出続けていた（実害）。マーカーが
  # 厳密に"sub"のときだけ④のみをスキップし、①②等の他セクションには影響しない
  # ことも合わせて確認する。
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
自動生成。ノート 42 件を検査し、**要確認 3 件**。
EOF
  PROPOSALS_DIR="$(mktemp -d)"
  echo "下書き本文" > "$PROPOSALS_DIR/x.md"
  ROLE_DIR="$(mktemp -d)"
  ROLE_FILE="$ROLE_DIR/machine-role"
  printf 'sub\n' > "$ROLE_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "$INV_DIR" "$PROPOSALS_DIR" "/nonexistent-dir/last-run.json" "$ROLE_FILE")"
  assert_not_contains "marker=sub・last-run.json不在では状態記録の警告が出ない" "$ctx" "週次メンテの状態記録が無い/壊れています"
  assert_not_contains "marker=sub・last-run.json不在では動いていない系の警告も出ない" "$ctx" "週次メンテが"
  assert_contains "④以外(①棚卸し)は影響を受けず出る" "$ctx" "棚卸し最新"
  assert_contains "④以外(②Preferences提案)は影響を受けず出る" "$ctx" "夜間バッチで運用ルールの昇格提案"
  assert_contains "ヘルス見出し自体は①②があるので出る" "$ctx" "【外部脳ヘルス】"

  rm -rf "$VAULT_DIR" "$INV_DIR" "$PROPOSALS_DIR" "$ROLE_DIR"
}

echo "=== 7m2. 外部脳ヘルス行④: machine-roleマーカーが\"main\"の場合は従来どおり警告が出る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  ROLE_DIR="$(mktemp -d)"
  ROLE_FILE="$ROLE_DIR/machine-role"
  printf 'main\n' > "$ROLE_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "/nonexistent-dir/last-run.json" "$ROLE_FILE")"
  assert_contains "marker=mainでは従来どおりlast-run.json不在の警告が出る" "$ctx" "週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR" "$ROLE_DIR"
}

echo "=== 7m3. 外部脳ヘルス行④: machine-roleマーカーが無い（ファイル不在）場合は従来どおり警告が出る（fail-closed） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "/nonexistent-dir/last-run.json" "/nonexistent-dir/machine-role")"
  assert_contains "marker不在では従来どおりlast-run.json不在の警告が出る" "$ctx" "週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR"
}

echo "=== 7m4. 外部脳ヘルス行④: machine-roleマーカーの中身が「s u b」(内部に空白を含む非厳密一致)の場合は従来どおり警告が出る（fail-closed。前後空白はtrimするが内部の空白まで削っては誤って一致してしまうためtest-check-sub-update.sh 2eと同じ観点を踏襲） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  ROLE_DIR="$(mktemp -d)"
  ROLE_FILE="$ROLE_DIR/machine-role"
  printf 's u b\n' > "$ROLE_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "/nonexistent-dir/last-run.json" "$ROLE_FILE")"
  assert_contains "marker中身が\"s u b\"(内部空白)では\"sub\"と誤認されず従来どおり警告が出る" "$ctx" "週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR" "$ROLE_DIR"
}

echo "=== 7n. 外部脳ヘルス行: last_result=warnなら警告要旨つきで⚠️1行が出る（旧D4・2026-08-10・[[Decisions/2026-08-10-round6-rulings]]決定1のセット条件） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  # started_atは直近(死活警告が別途出て本テストの主眼と混同しないように)。
  printf '{"started_at": "%s", "last_success_at": "%s", "last_result": "warn", "last_result_summary": "Phase1check-drift.shがdriftを検知しました"}' \
    "$(d_ts -1)" "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "前回結果warnの⚠️行が出る" "$ctx" "⚠️ 前回の週次メンテ結果: warn"
  assert_contains "警告要旨(last_result_summary)が併記される" "$ctx" "check-drift.shがdriftを検知しました"
  assert_not_contains "死活経過日数の警告(④の他分岐)は誤って出ない" "$ctx" "週次メンテが"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7n2. 外部脳ヘルス行: last_result=failなら⚠️1行が出る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_result": "fail", "last_result_summary": "backup-vault.sh failed"}' "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "前回結果failの⚠️行が出る" "$ctx" "⚠️ 前回の週次メンテ結果: fail"
  assert_contains "警告要旨が併記される" "$ctx" "backup-vault.sh failed"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7n3. 外部脳ヘルス行: last_result=successなら⚠️行は出ない ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s", "last_result": "success", "last_result_summary": ""}' \
    "$(d_ts -1)" "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_not_contains "successでは前回結果の⚠️行は出ない" "$ctx" "前回の週次メンテ結果"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7n4. 外部脳ヘルス行: last_resultキー自体が無い（旧last-run.json・移行前）でもクラッシュせず⚠️行は出ない(fail-open) ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s"}' "$(d_ts -1)" "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_not_contains "last_resultキー欠落では前回結果の⚠️行は出ない(fail-open)" "$ctx" "前回の週次メンテ結果"
  assert_contains "本文自体は壊れず末尾まで出る" "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 7n5. 外部脳ヘルス行: last_result=successかつlast_result_summaryが非空ならℹ️1行が出る（⚠️ではない・工程横断レビュー指摘Major対応・2026-08-10。用途例＝check-drift②の未知config.tomlキー検出） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s", "last_success_at": "%s", "last_result": "success", "last_result_summary": "Phase1check-drift.sh2が未知キーを3件検出しました"}' \
    "$(d_ts -1)" "$(d_ts -1)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap "$VAULT_DIR" "" "" "" "" "$LAST_RUN_FILE")"
  assert_contains "ℹ️1行が出る" "$ctx" "ℹ️ 前回の週次メンテ結果: success"
  assert_contains "summaryの中身が併記される" "$ctx" "未知キーを3件検出しました"
  assert_not_contains "⚠️（warn/fail用の記号）は使われない" "$ctx" "⚠️ 前回の週次メンテ結果"
  assert_contains "last-run.jsonのフルパスが文字化けせず出る（bash 3.2の\$VAR）文字化けバグの回帰確認）" \
    "$ctx" "last-run.json: ${LAST_RUN_FILE}）"

  rm -rf "$VAULT_DIR" "$LAST_RUN_DIR"
}

echo "=== 8. 外部脳ヘルス行: 棚卸し・ログとも無いが、last-run.json不在の死活警告(b)は出る（2周目ハードニングで完全沈黙は撤回） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  # 棚卸しレポート出力先を作らない・ログも渡さない（既定の存在しないパス）。
  # last-run.jsonも既定の存在しないパスのまま＝7iで検証した(b)の警告が
  # 単独で出るようになった（2026-07-18 2周目ハードニング以前は完全沈黙で
  # ヘルス見出し自体が出なかったが、初回未稼働の不可視を塞ぐ変更に伴い
  # 意図的に変更した）。

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "ヘルス見出し自体はlast-run.json不在の警告(b)で出る" "$ctx" "【外部脳ヘルス】"
  assert_contains "last-run.json不在の状態記録警告が単独で出る" "$ctx" "⚠️ 週次メンテの状態記録が無い/壊れています"
  assert_not_contains "棚卸し・フック死・提案通知など他の項目は出ない（無い情報を無理に出さない）" "$ctx" "棚卸し最新"
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
  PROPOSALS_DIR="$(mktemp -d)"
  echo "下書き本文" > "$PROPOSALS_DIR/x.md"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s"}' "$(d_ts -10)" > "$LAST_RUN_FILE"

  ctx="$(run_bootstrap_worker "$VAULT_DIR" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "$INV_DIR" "$PROPOSALS_DIR" "$LAST_RUN_FILE")"
  assert_not_contains "ワーカー版にはヘルス見出しが出ない" "$ctx" "【外部脳ヘルス】"
  assert_not_contains "ワーカー版には棚卸し情報も出ない" "$ctx" "棚卸し最新"
  assert_not_contains "ワーカー版にはフック死の疑いも出ない" "$ctx" "フック死の疑い"
  assert_not_contains "ワーカー版にはPreferences提案通知も出ない（提案が実在しても）" "$ctx" "夜間バッチで運用ルールの昇格提案"
  assert_not_contains "ワーカー版には死活警告も出ない（last-run.jsonが古くても）" "$ctx" "週次メンテが"
  assert_contains "ワーカー版本文は健在" "$ctx" "【チームメイト用ブートストラップ｜軽量版】"

  rm -rf "$VAULT_DIR" "$LOGDIR" "$INV_DIR" "$PROPOSALS_DIR" "$LAST_RUN_DIR"
}

echo "=== 10. P1機構(ローカル実体プロファイル): 既定(無効)では固定パスが必読リストに一切現れない（有効化はリーダー側工程に残す・§9.0 A-1） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_PATH="$(mktemp -d)/profile.md"
  make_ok_profile "$PROFILE_PATH"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "既定では固定パスが必読リストに出ない" "$ctx" "$PROFILE_PATH"
  assert_not_contains "既定ではローカル実体プロファイル見出しも出ない" "$ctx" "【ローカル実体プロファイル】"

  rm -rf "$VAULT_DIR" "$(dirname "$PROFILE_PATH")"
}

echo "=== 11. P1機構: 有効化すると、Vault側の必読ファイルに加えて固定パスが1件だけ現れる（P1受入条件①） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_ok_profile "$PROFILE_PATH"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  occurrences="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "固定パスがちょうど1件だけ現れる" "1" "$occurrences"
  assert_contains "Vault側の必読ファイル(absolute-rules.md)も引き続き現れる" "$ctx" "$VAULT_DIR/Preferences/absolute-rules.md"
  assert_not_contains "壊れていないprofileでは最小能力警告は出ない" "$ctx" "最小能力"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 12. P1機構 T1(実体なし): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_PATH="$(mktemp -d)/nonexistent/profile.md"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "T1: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T1: 実体なしの理由が出る" "$ctx" "T1"
  assert_contains "未作成の案内が必読リストに出る" "$ctx" "未作成"

  rm -rf "$VAULT_DIR"
}

echo "=== 13. P1機構 T2-MINIMAL(未記入sentinel): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer: <fill-in>
vault_write: configured
vault_scope: 全範囲
ui.user_call: SendMessage
git_role: pull専用
web_verification: WebSearch
---
EOF

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "T2-MINIMAL: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T2-MINIMAL: 未記入sentinelの理由が出る" "$ctx" "T2-MINIMAL"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 14. P1機構 T5(既存キー欠落): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # git_role キーを欠落させる。
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer: 本人
vault_write: configured
vault_scope: 全範囲
ui.user_call: SendMessage
web_verification: WebSearch
---
EOF

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "T5: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T5: 既存キー欠落の理由が出る" "$ctx" "T5"
  assert_contains "T5: 欠落キー名が出る" "$ctx" "git_role"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 15. P1機構 T6(YAML破損): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # frontmatterの終端区切りが無い壊れたファイル。
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer: 本人
EOF

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "T6: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T6: YAML破損の理由が出る" "$ctx" "T6"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 16. P1機構 T4(新キー未追随): unknown補完+ℹ️で、最小能力へは倒さない ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # 既知の7キーはすべて揃えたうえで、将来のスキーマ拡張を想定した未知キーを追加する。
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer: 本人
vault_write: configured
vault_scope: 全範囲
ui.user_call: SendMessage
git_role: pull専用
web_verification: WebSearch
future_new_key: 未来のスキーマが追加した値
---
EOF

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_not_contains "T4: 最小能力へは倒さない（degrade警告は出ない）" "$ctx" "を解決できません"
  assert_contains "T4: 未知キーの情報行が出る" "$ctx" "future_new_key"
  assert_contains "T4: ℹ️の情報行として出る（⚠️ではない）" "$ctx" "ℹ️ ローカル実体プロファイルに未知のキーがあります"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 17. P1機構: 実体がsymlinkの場合は受理せず最小能力+⚠️になる（Codex一次レビュー指摘・Major対応: repo/Vault管理下ファイルへのsymlinkでリモート更新が能力表へ暗黙反映される経路を防ぐ） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  REAL_TARGET="$PROFILE_DIR/real-target.md"
  make_ok_profile "$REAL_TARGET"
  ln -s "$REAL_TARGET" "$PROFILE_PATH"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "symlinkでは最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "SYMLINK理由コードが出る" "$ctx" "SYMLINK"
  # Codex二次レビュー指摘・Major対応: 必読リスト側の判定も揃っていることを
  # 検証する（resolve_local_profile()だけでなく、リスト表示のfor文自体が
  # `-f`のみで判定していると、信頼しないはずのsymlink内容を「全文をRead
  # すること」として読ませる指示が残ってしまう）。
  assert_not_contains "symlinkは「全文をReadすること」の必読指示に載らない" "$ctx" "$PROFILE_PATH  （全"
  assert_contains "symlinkのため受理しない旨が必読リスト側にも表示される" "$ctx" "symlinkのため実体として受理しません"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

# resolve_local_profile()の生出力（MINIMAL/OK行）だけを取得するテスト専用
# ヘルパー。BOOTSTRAP_RESOLVE_PROFILE_ONLY=1を使う（2026-08-30 MAJOR-8b対応）。
run_resolve_local_profile() {
  local profile_path="$1"
  echo '{}' | BOOTSTRAP_RESOLVE_PROFILE_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" \
    BOOTSTRAP_VAULT="/nonexistent-dir" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" "$SCRIPT"
}

echo "=== 18. resolve_local_profile(): 値が空(\`key:\`のみ)のキーはOKのまま\"unknown\"へ正規化される（2026-08-30 工程横断レビュー指摘・MAJOR-8b対応: 最低契約④どおり空値をOK扱いのまま通さない） ==="
{
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer:
vault_write: configured
vault_scope: 全範囲
ui.user_call: SendMessage
git_role: pull専用
web_verification: WebSearch
---
EOF

  out="$(run_resolve_local_profile "$PROFILE_PATH")"
  assert_contains "OK扱いのまま（最小能力へは倒さない）" "$out" "OK"
  assert_not_contains "MINIMALへは倒さない" "$out" "MINIMAL"
  assert_contains "reviewerの値がunknownへ正規化される" "$out" "reviewer=unknown"

  rm -rf "$PROFILE_DIR"
}

echo "=== 19. resolve_local_profile(): 空白のみの値も\"unknown\"へ正規化される ==="
{
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  {
    echo "---"
    echo "inventory_source: Vault"
    printf 'reviewer:   \n'
    echo "vault_write: configured"
    echo "vault_scope: 全範囲"
    echo "ui.user_call: SendMessage"
    echo "git_role: pull専用"
    echo "web_verification: WebSearch"
    echo "---"
  } > "$PROFILE_PATH"

  out="$(run_resolve_local_profile "$PROFILE_PATH")"
  assert_contains "OK扱いのまま" "$out" "OK"
  assert_contains "空白のみのreviewerもunknownへ正規化される" "$out" "reviewer=unknown"

  rm -rf "$PROFILE_DIR"
}

echo "=== 20. resolve_local_profile(): 値が空でも他のキーの値は変わらない（正規化が該当キーだけに閉じている回帰確認） ==="
{
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer:
vault_write: configured(vault-scribe)
vault_scope: 全範囲
ui.user_call: SendMessage
git_role: pull専用
web_verification: WebSearch
---
EOF

  out="$(run_resolve_local_profile "$PROFILE_PATH")"
  assert_contains "reviewer以外(vault_write)の値は空値正規化の影響を受けない" "$out" "vault_write=configured(vault-scribe)"

  rm -rf "$PROFILE_DIR"
}

echo "=== 21. resolve_local_profile(): 全キー正常記入ならOK・unknown正規化は起きない（回帰確認） ==="
{
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_ok_profile "$PROFILE_PATH"

  out="$(run_resolve_local_profile "$PROFILE_PATH")"
  assert_contains "OKが返る" "$out" "OK"
  assert_not_contains "unknownへの正規化は起きない（元々空値のキーが無いため）" "$out" "=unknown"

  rm -rf "$PROFILE_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
