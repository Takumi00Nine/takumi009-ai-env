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

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
