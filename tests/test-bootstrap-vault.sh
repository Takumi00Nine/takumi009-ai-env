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
# 3番目の引数（省略可）はsettings.jsonの比較先パス。省略時は存在しない
# パスを既定にする（S10/S11/S16対応・check_leader_settings_drift追加に
# あわせて2026-09-01追加。既定を実機の$HOME/.claude/settings.jsonのままに
# すると、v2プロファイルがOKで解決するテスト（#36・#37等）がテスト実行機の
# 実settings.jsonに依存してしまい非決定的になる＝他のログ系引数と同じく
# /nonexistent-dir配下を既定にして隔離する）。
run_bootstrap_with_profile() {
  local vault="$1" profile_path="$2" settings_json="${3:-/nonexistent-dir/settings.json}"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_MACHINE_ROLE_MARKER="/nonexistent-dir/machine-role" \
      AIENV_SETTINGS_JSON_FILE="$settings_json" \
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

echo "=== 16. P1機構 T9'(UNKNOWN_EXTRA): 機械側は既知キー部分が有効(MINIMALへは倒さない)だが、AI向けには必読除外・最小能力(⚠️)になる（配役表解凍-設計-2026-09-01.md §4a・U-8裁定で2026-09-01に advisory→除外へ変更。旧仕様=ℹ️のまま読ませ続ける、はこの裁定で終了） ==="
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
  # 機械側は解決失敗(MINIMAL)ではない＝「を解決できません」という汎用MINIMAL
  # 文言は出ない（既知キー部分は有効という§4a表の区別を保つ）。
  assert_not_contains "T9': 機械側の解決失敗(MINIMAL)ではない" "$ctx" "を解決できません"
  assert_contains "T9': 未知キー名が警告に出る" "$ctx" "future_new_key"
  assert_contains "T9': AI向けには必読除外・最小能力の⚠️警告になる（U-8裁定）" "$ctx" "⚠️ ローカル実体プロファイルに未知のキーがあります"
  assert_contains "T9': 秘匿優先の理由が明記される" "$ctx" "U-8裁定・秘匿優先"
  assert_contains "T9': 「プロファイル利用不可＝最小能力」の文言が明示される（リーダー裁定・2026-09-01）" "$ctx" "プロファイル利用不可＝最小能力"
  assert_contains "T9': 「ワーカー起動は本人確認へ倒す」の文言が明示される（リーダー裁定・2026-09-01）" "$ctx" "ワーカー起動は本人確認へ倒してください"
  assert_not_contains "T9': 旧仕様のℹ️文言はもう出ない" "$ctx" "ℹ️ ローカル実体プロファイルに未知のキーがあります"
  assert_not_contains "T9': 全文Readの指示は付かない（必読除外）" "$ctx" "$PROFILE_PATH  （全"

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

# resolve_local_profile()（v1/v2/混在の分類ディスパッチャそのもの）の生出力
# だけを取得するテスト専用ヘルパー。BOOTSTRAP_RESOLVE_PROFILE_DISPATCH_ONLY=1
# を使う（2026-09-01追加・tester独立検証差し戻し対応。T12=LEGACY_V1トップ
# レベル差し替え・T3-PRIME=混在・T10=lib欠落を直接検証する）。
# 第2引数（省略可）でPROFILE_RESOLVE_LIBを差し替えられる＝T10（lib欠落）テスト用。
run_resolve_local_profile_dispatch() {
  local profile_path="$1" lib_override="${2:-}"
  # ⚠️ `${var:+NAME="$val"}`は「展開結果がNAME=valの形をしていても」bash
  # パーサはparse時点で代入語と認識しない（代入語認識はソース上の字面が
  # NAME=valの形をしている場合だけに働く既知の制約）ため、if/elseで
  # 完全な代入トークンを直接書く形に分ける。
  if [ -n "$lib_override" ]; then
    echo '{}' | BOOTSTRAP_RESOLVE_PROFILE_DISPATCH_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" \
      PROFILE_RESOLVE_LIB="$lib_override" \
      BOOTSTRAP_VAULT="/nonexistent-dir" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" "$SCRIPT"
  else
    echo '{}' | BOOTSTRAP_RESOLVE_PROFILE_DISPATCH_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" \
      BOOTSTRAP_VAULT="/nonexistent-dir" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" "$SCRIPT"
  fi
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

# ============================================================================
# 22番以降: v2配役表解凍（配役表解凍-設計-2026-09-01.md 担当A）のユニット・結合
# テスト。claude/hooks/lib/profile_resolve.py を直接CLI呼び出しする（分類・
# parser・validator・候補評価は本libが唯一の正本＝§3.4）。DIRECTIVE統合部分
# だけrun_bootstrap_with_profile()を使う。
# ============================================================================

PROFILE_LIB="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
AGENTS_DIR="$REPO_ROOT/claude/agents"

classify_v2() { python3 "$PROFILE_LIB" classify "$1"; }
resolve_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}
resolve_leader_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve-leader "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}

# v2の全10固定キー(メタ2+能力軸7+excluded_models)をすべて満たした最小の
# base雛形。呼び出し側がrole./fallback.行だけを足して各シナリオを作る。
V2_BASE='---
schema_version: 2
profile_slug: authoring
inventory_source: configured value=work-tools-dir
reviewer:         configured value=codex-mcp
vault_write:      configured value=via-scribe
vault_scope:      configured value=full
ui.user_call:     configured value=send-message
git_role:         configured value=aienv-repo:commit
web_verification: configured value=websearch
excluded_models: configured value=none'

make_v2_profile() {
  # $1=path、以降の引数は role./fallback. 行（そのまま追記）。
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "$V2_BASE"
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '---\n'
  } > "$path"
}

echo "=== 22. classify(): v1/v2/混在の3分岐 ==="
{
  V1_PATH="$(mktemp -d)/v1.md"
  make_ok_profile "$V1_PATH"
  assert_eq "v1: schema_versionが無く動的行も無い" "v1" "$(classify_v2 "$V1_PATH")"

  V2_PATH="$(mktemp -d)/v2.md"
  make_v2_profile "$V2_PATH" "role.leader: configured provider=anthropic-api model=claude-opus-5"
  assert_eq "v2: schema_version:2かつ動的行あり" "v2" "$(classify_v2 "$V2_PATH")"

  MIXED_PATH="$(mktemp -d)/mixed.md"
  cat > "$MIXED_PATH" <<'EOF'
---
inventory_source: Vault
role.leader: configured provider=anthropic-api model=claude-opus-5
---
EOF
  assert_eq "mixed: schema_version無しなのに動的行がある" "mixed" "$(classify_v2 "$MIXED_PATH")"

  MIXED2_PATH="$(mktemp -d)/mixed2.md"
  cat > "$MIXED2_PATH" <<'EOF'
---
schema_version: 1
role.leader: configured provider=anthropic-api model=claude-opus-5
---
EOF
  assert_eq "mixed: schema_version:1でも動的行があれば混在" "mixed" "$(classify_v2 "$MIXED2_PATH")"
}

echo "=== 23. parser 4.1-a/4.1-b: ハイフンキー・コメント行・行末コメントが正しく扱われる ==="
{
  P="$(mktemp -d)/comment.md"
  make_v2_profile "$P" \
    "# これはコメント行（無視される）" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5  # 行末コメントも無視" \
    "role.requirements-analyst: configured provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$P")"  || true
  assert_contains "4.1-a: ハイフンを含むキー(role.requirements-analyst)がT6にならない" "$out" "OK"
  assert_not_contains "4.1-b: コメント行・行末コメントでT6にならない" "$out" "MINIMAL"
}

echo "=== 24. parser §3.1-7: 重複キー・重複属性・未許可属性はすべてT6（構文エラー） ==="
{
  DUPKEY="$(mktemp -d)/dupkey.md"
  make_v2_profile "$DUPKEY" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.leader: unknown"
  out="$(resolve_v2 "$DUPKEY")"  || true
  assert_contains "重複キーはMINIMAL/T6になる" "$out" "MINIMAL"
  assert_contains "T6コードが出る" "$out" "T6"

  DUPATTR="$(mktemp -d)/dupattr.md"
  make_v2_profile "$DUPATTR" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5 provider=bedrock"
  out="$(resolve_v2 "$DUPATTR")"  || true
  assert_contains "重複属性はMINIMAL/T6になる" "$out" "MINIMAL	T6"

  UNKATTR="$(mktemp -d)/unkattr.md"
  make_v2_profile "$UNKATTR" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5 mystery=1"
  out="$(resolve_v2 "$UNKATTR")"  || true
  assert_contains "許可されない属性はMINIMAL/T6になる" "$out" "MINIMAL	T6"

  # エラー理由に行番号とキー名だけが含まれ、属性値そのもの(mystery=1の"1"等)は
  # 含まれないこと（§3.1-8）。
  assert_not_contains "エラー理由に属性の生値が含まれない（§3.1-8）" "$out" "mystery=1"
}

echo "=== 25. validator V8-a: 状態4値と属性有無の組み合わせ ==="
{
  NOTADOPT_ATTR="$(mktemp -d)/notadopt.md"
  make_v2_profile "$NOTADOPT_ATTR" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.researcher: not_adopted provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$NOTADOPT_ATTR")"  || true
  assert_contains "not_adoptedが属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  MISSING_MODEL="$(mktemp -d)/missingmodel.md"
  make_v2_profile "$MISSING_MODEL" \
    "role.leader: configured provider=anthropic-api"
  out="$(resolve_v2 "$MISSING_MODEL")"  || true
  assert_contains "configuredでmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNAVAIL_OK="$(mktemp -d)/unavailok.md"
  make_v2_profile "$UNAVAIL_OK" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.researcher: unavailable provider=bedrock model=haiku"
  out="$(resolve_v2 "$UNAVAIL_OK")"  || true
  assert_contains "unavailableはprovider/modelを持ってよい（意図の記録）" "$out" "OK"
}

echo "=== 26. validator V9-b: provider毎のmodel形式・execution既定・external必須execution ==="
{
  BADMODEL="$(mktemp -d)/badmodel.md"
  make_v2_profile "$BADMODEL" \
    "role.leader: configured provider=anthropic-api model=gpt-5"
  out="$(resolve_v2 "$BADMODEL")"  || true
  assert_contains "anthropic-apiでmodelがclaude-接頭辞でないとV9-bでMINIMAL" "$out" "MINIMAL	T8	V9-b"

  BEDROCKARN="$(mktemp -d)/bedrockarn.md"
  make_v2_profile "$BEDROCKARN" \
    "role.leader: configured provider=bedrock model=arn:aws:bedrock:foo"
  out="$(resolve_v2 "$BEDROCKARN")"  || true
  assert_contains "bedrockでarn:始まりのmodelはV9-bでMINIMAL（別名限定）" "$out" "MINIMAL	T8	V9-b"

  BEDROCKUS="$(mktemp -d)/bedrockus.md"
  make_v2_profile "$BEDROCKUS" \
    "role.leader: configured provider=bedrock model=us.opus"
  out="$(resolve_v2 "$BEDROCKUS")"  || true
  assert_contains "bedrockでus.始まりのmodelもV9-bでMINIMAL" "$out" "MINIMAL	T8	V9-b"

  EXTNOEXEC="$(mktemp -d)/extnoexec.md"
  make_v2_profile "$EXTNOEXEC" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.primary-reviewer: configured provider=external model=codex-review-default"
  out="$(resolve_v2 "$EXTNOEXEC")"  || true
  assert_contains "provider=externalでexecution未記載はV9-bでMINIMAL" "$out" "MINIMAL	T8	V9-b"

  NONSUBEXEC="$(mktemp -d)/nonsubexec.md"
  make_v2_profile "$NONSUBEXEC" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5 execution=external-mcp"
  out="$(resolve_v2 "$NONSUBEXEC")"  || true
  assert_contains "anthropic-apiでexecution!=subagentはV9-bでMINIMAL" "$out" "MINIMAL	T8	V9-b"

  DEFAULTEXEC="$(mktemp -d)/defaultexec.md"
  make_v2_profile "$DEFAULTEXEC" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$DEFAULTEXEC")"  || true
  assert_contains "execution未記載はsubagent既定でOKになる" "$out" "OK"
}

echo "=== 27. validator V9-d①②: ハンドラ写像に無い組・execution=external-apiは常にconfigured不可 ==="
{
  UNIMPL_HANDLER="$(mktemp -d)/unimplhandler.md"
  make_v2_profile "$UNIMPL_HANDLER" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.primary-reviewer: configured provider=external execution=external-mcp model=other-tool"
  out="$(resolve_v2 "$UNIMPL_HANDLER")"  || true
  assert_contains "写像に無い(provider,execution,model)組はV9-dでMINIMAL" "$out" "MINIMAL	T8	V9-d"

  EXTAPI="$(mktemp -d)/extapi.md"
  make_v2_profile "$EXTAPI" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.primary-reviewer: configured provider=external execution=external-api model=codex-review-default"
  out="$(resolve_v2 "$EXTAPI")"  || true
  assert_contains "execution=external-apiはハンドラ未実装でconfigured不可(V9-d)" "$out" "MINIMAL	T8	V9-d"

  EXTAPI_UNAVAIL="$(mktemp -d)/extapiunavail.md"
  make_v2_profile "$EXTAPI_UNAVAIL" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.primary-reviewer: unavailable provider=external execution=external-api model=codex-review-default"
  out="$(resolve_v2 "$EXTAPI_UNAVAIL")"  || true
  assert_contains "unavailableならexternal-apiでも構文上は許される(V9-d②はconfigured限定)" "$out" "OK"
}

echo "=== 28. validator V16: excluded_modelsに一致する配役はMINIMAL ==="
{
  V16="$(mktemp -d)/v16.md"
  make_v2_profile "$V16" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: configured value=anthropic-api\/claude-opus-5/' "$V16"
  out="$(resolve_v2 "$V16")"  || true
  assert_contains "禁止モデル一致はV16でMINIMAL" "$out" "MINIMAL	T8	V16"

  V16_1M="$(mktemp -d)/v16_1m.md"
  make_v2_profile "$V16_1M" \
    "role.leader: configured provider=anthropic-api model=claude-fable-5[1m]"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: configured value=anthropic-api\/claude-fable-5/' "$V16_1M"
  out="$(resolve_v2 "$V16_1M")"  || true
  assert_contains "[1m]は判定で無視されるので同じく一致してMINIMALになる" "$out" "MINIMAL	T8	V16"
}

echo "=== 29. validator V6: fallbackが指す職種がrole.表に無いとMINIMAL ==="
{
  V6="$(mktemp -d)/v6.md"
  make_v2_profile "$V6" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "fallback.ghost-role: configured provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$V6")"  || true
  assert_contains "対応するrole.表が無いfallbackはV6でMINIMAL" "$out" "MINIMAL	T8	V6"
}

echo "=== 30. §3.5-L リーダー状態遷移: unknown/not_adopted/行が無い/unavailableでfallback無し は全てfail（resolveも非0・resolve-leaderも非0） ==="
{
  for state in "role.leader: unknown" "role.leader: not_adopted"; do
    P="$(mktemp -d)/leaderfail.md"
    make_v2_profile "$P" "$state"
    rc=0; out="$(resolve_v2 "$P")" || rc=$?
    assert_contains "leader=${state}はMINIMALになる" "$out" "MINIMAL"
    assert_eq "leader=${state}はresolveが非0終了する" "1" "$rc"
  done

  NOLEADER="$(mktemp -d)/noleader.md"
  make_v2_profile "$NOLEADER" "role.researcher: configured provider=anthropic-api model=claude-sonnet-5"
  out="$(resolve_v2 "$NOLEADER")"  || true
  assert_contains "role.leader行が無ければfail(MINIMAL)になる" "$out" "MINIMAL"

  UNAVAIL_NOFB="$(mktemp -d)/leaderunavail.md"
  make_v2_profile "$UNAVAIL_NOFB" "role.leader: unavailable provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$UNAVAIL_NOFB")"  || true
  assert_contains "leader=unavailableでfallback無しはfail" "$out" "MINIMAL"

  err="$(resolve_leader_v2 "$UNAVAIL_NOFB" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderは機械可読コードLEADER_UNAVAILABLE_NO_FALLBACKをstderrへ出す" "$err" "LEADER_UNAVAILABLE_NO_FALLBACK"
}

echo "=== 31. §3.5-L: leaderのfallback救済（本命unavailable→fallbackがconfigured→採用） ==="
{
  RESCUE="$(mktemp -d)/leaderrescue.md"
  make_v2_profile "$RESCUE" \
    "role.leader: unavailable provider=bedrock model=opus" \
    "fallback.leader: configured provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$RESCUE")"  || true
  assert_contains "leaderがfallback救済されればOKになる" "$out" "OK"
  json="$(resolve_leader_v2 "$RESCUE")"  || true
  assert_contains "resolve-leaderはfallbackのmodelを返す" "$json" "claude-opus-5"

  echo "--- leader専用規則: 実効候補のproviderがexternalならfail ---"
  EXT_LEADER="$(mktemp -d)/extleader.md"
  make_v2_profile "$EXT_LEADER" \
    "role.leader: configured provider=external execution=external-mcp model=codex-review-default"
  out="$(resolve_v2 "$EXT_LEADER")"  || true
  assert_contains "leaderのprovider=externalはfailになる" "$out" "MINIMAL"
}

echo "=== 32. 候補評価§3.6: ワーカー職はV1-b/V9-d/V12単独では空席にならず、使えるfallbackがあれば採用される ==="
{
  FB_RESCUE="$(mktemp -d)/workerfallback.md"
  make_v2_profile "$FB_RESCUE" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku" \
    "fallback.tester: configured provider=anthropic-api model=claude-sonnet-5"
  # bedrock.envを与えない(ABSENT=disabled)のでtesterの本命(bedrock)はV9-dで使用不可
  out="$(resolve_v2 "$FB_RESCUE")"  || true
  assert_contains "本命が使用不可でもfallbackが使えればFALLBACK:testerとして採用される" "$out" "FALLBACK:tester"
  assert_not_contains "fallbackが採用された職種はVACANTに出ない" "$out" "VACANT:tester"

  echo "--- 双方使用不可のときだけVACANT+VACANT_REASON、優先順はV1-b→V9-d→V12 ---"
  BOTH_BAD="$(mktemp -d)/bothbad.md"
  make_v2_profile "$BOTH_BAD" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku" \
    "fallback.tester: configured provider=bedrock model=opus"
  out="$(resolve_v2 "$BOTH_BAD")"  || true
  assert_contains "双方bedrockで経路無効なら空席になる" "$out" "VACANT:tester"
  assert_contains "空席理由の条件番号が出る(V9-d)" "$out" "VACANT_REASON:tester=V9-d"

  echo "--- unavailableの本命は評価されず、fallbackだけが評価される ---"
  UNAVAIL_SKIP="$(mktemp -d)/unavailskip.md"
  make_v2_profile "$UNAVAIL_SKIP" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: unavailable provider=bedrock model=opus" \
    "fallback.tester: configured provider=anthropic-api model=claude-sonnet-5"
  out="$(resolve_v2 "$UNAVAIL_SKIP")"  || true
  assert_contains "unavailableな本命はスキップされfallbackが採用される" "$out" "FALLBACK:tester"
}

echo "=== 33. §3.7 判定不能: Bedrock経路の判定不能はワーカーなら通す・leaderならfail ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir
  UNREADABLE_ENV="/tmp/aienv-test-unreadable-env-dir/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV"
  chmod 0000 "$UNREADABLE_ENV"

  WORKER_UNKNOWN="$(mktemp -d)/workerunknown.md"
  make_v2_profile "$WORKER_UNKNOWN" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku"
  out="$(resolve_v2 "$WORKER_UNKNOWN" "$UNREADABLE_ENV")"  || true
  assert_not_contains "判定不能でもワーカーは空席にならない" "$out" "VACANT:tester"
  assert_contains "resolve自体はOKのまま" "$out" "OK"

  LEADER_UNKNOWN="$(mktemp -d)/leaderunknownenv.md"
  make_v2_profile "$LEADER_UNKNOWN" \
    "role.leader: configured provider=bedrock model=opus"
  out="$(resolve_v2 "$LEADER_UNKNOWN" "$UNREADABLE_ENV")"  || true
  assert_contains "判定不能でもleaderはfailになる" "$out" "MINIMAL"

  chmod 0700 "$UNREADABLE_ENV"
  rm -rf /tmp/aienv-test-unreadable-env-dir
}

echo "=== 34. 秘匿: bedrock.envのピン留め実値がresolve/resolve-leaderのいずれの出力にも現れない ==="
{
  PIN_ENV="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn
AWS_ACCESS_KEY_ID=AKIA_SHOULD_NEVER_LEAK
EOF
  SECRET_PROFILE="$(mktemp -d)/secretprofile.md"
  make_v2_profile "$SECRET_PROFILE" \
    "role.leader: configured provider=bedrock model=opus"
  out="$(resolve_v2 "$SECRET_PROFILE" "$PIN_ENV")"  || true
  assert_not_contains "resolve出力にピン実値(ARN)が現れない" "$out" "supersecret-arn"
  assert_not_contains "resolve出力にAWSキーが現れない" "$out" "AKIA_SHOULD_NEVER_LEAK"

  json="$(resolve_leader_v2 "$SECRET_PROFILE" "$PIN_ENV")"  || true
  assert_not_contains "resolve-leader出力にもピン実値(ARN)が現れない" "$json" "supersecret-arn"
  assert_not_contains "resolve-leader出力にもAWSキーが現れない" "$json" "AKIA_SHOULD_NEVER_LEAK"
  assert_contains "resolve-leaderはmodelとして別名(opus)だけを返す" "$json" '"model": "opus"'
}

echo "=== 35. V15/T11: 禁止キー名はv1/v2どちらの分類でもpreflightでMINIMAL/T11・必読除外になる（v1経路への新規適用） ==="
{
  V15_V2="$(mktemp -d)/v15v2.md"
  make_v2_profile "$V15_V2" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  echo "api_key: configured value=xyz" >> "$V15_V2"
  # frontmatter終端---の後ろに付けると構文が壊れるので、専用のfixtureを作り直す。
  cat > "$V15_V2" <<'EOF'
---
schema_version: 2
profile_slug: authoring
role.leader: configured provider=anthropic-api model=claude-opus-5
api_key: configured value=xyz
inventory_source: configured value=work-tools-dir
reviewer:         configured value=codex-mcp
vault_write:      configured value=via-scribe
vault_scope:      configured value=full
ui.user_call:     configured value=send-message
git_role:         configured value=aienv-repo:commit
web_verification: configured value=websearch
excluded_models: configured value=none
---
EOF
  out="$(resolve_v2 "$V15_V2")"  || true
  assert_contains "v2でapi_keyというキー名があるとpreflightでMINIMAL/T11になる" "$out" "MINIMAL	T11"

  echo "--- 統合(DIRECTIVE)側: v1形式にforbidden keyを混ぜてもMINIMAL/T11で必読除外される ---"
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  cat > "$PROFILE_PATH" <<'EOF'
---
inventory_source: Vault
reviewer: 本人
vault_write: configured
vault_scope: 全範囲
ui.user_call: SendMessage
git_role: pull専用
web_verification: WebSearch
auth_token: should-not-be-here
---
EOF
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "v1でも禁止キー名検出で最小能力の警告が出る" "$ctx" "認証情報らしいキー名があります"
  assert_not_contains "全文Readの指示は付かない（必読除外）" "$ctx" "$PROFILE_PATH  （全"
  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 36. 結合（DIRECTIVE）: VACANT_UNKNOWN・FALLBACK・VACANT_REASONが職種名と条件番号でDIRECTIVEへ注入される（4.1-f） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku" \
    "fallback.tester: configured provider=bedrock model=opus"
  # 静的検証: このprofile単体でVACANT_REASON:tester=V9-dが出ることを確認済み(#32)。
  # ここではDIRECTIVEへの伝播だけを確認する。

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "DIRECTIVEに配役表の状態行が出る" "$ctx" "配役表の状態"
  assert_contains "VACANT:teseterの職種名が出る" "$ctx" "VACANT:tester"
  assert_contains "VACANT_REASONの条件番号が出る" "$ctx" "VACANT_REASON:tester=V9-d"
  # Codex一次レビュー指摘・Major対応: 元のfixtureに存在しない文字列
  # ("model=bedrock")を検査しても常に偽陰性で通ってしまう無意味な検査だった。
  # 実際にfixtureへ書いたmodel値(haiku/opus)とprovider値(bedrock)そのものが
  # 再掲されないことを検査する。
  assert_not_contains "配役の値(model=haiku)そのものは再掲されない（4.1-f）" "$ctx" "model=haiku"
  assert_not_contains "配役の値(model=opus)そのものは再掲されない（4.1-f）" "$ctx" "model=opus"
  assert_not_contains "provider=の値も再掲されない" "$ctx" "provider=bedrock"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 37. stdout契約: v2 OKでは全文Readが必読リストに載り、フィールドは固定順（OK→FALLBACK→VACANT→VACANT_REASON→VACANT_UNKNOWN→ADVISORY→UNKNOWN_EXTRA） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.requirements-analyst: configured provider=anthropic-api model=claude-opus-5"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  occurrences="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH  （全" || true)"
  assert_eq "壊れていないv2プロファイルは全文Read指示がちょうど1件" "1" "$occurrences"

  out="$(resolve_v2 "$PROFILE_PATH")"  || true
  order_ok=1
  case "$out" in
    OK*) ;;
    *) order_ok=0 ;;
  esac
  assert_eq "先頭フィールドは必ずOK" "1" "$order_ok"

  echo "--- フィールドが複数同時に出るケースで固定順を検証する（Codex一次レビュー指摘・Major対応: 従来は先頭がOKかしか見ていなかった） ---"
  MULTI="$(mktemp -d)/multi.md"
  make_v2_profile "$MULTI" \
    "role.leader: unavailable provider=bedrock model=opus" \
    "fallback.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku" \
    "fallback.tester: configured provider=anthropic-api model=claude-sonnet-5" \
    "role.researcher: configured provider=anthropic-api model=claude-sonnet-5"
  multi_out="$(resolve_v2 "$MULTI")"  || true
  # 期待: OK -> FALLBACK:leader,tester(順不同はソート済み) -> VACANT_UNKNOWN(コア
  # マニフェストの他職種) -> ADVISORY:V1-a の順で、この並びどおりに現れること。
  idx_ok=$(printf '%s' "$multi_out" | grep -bo '^OK' | head -1 | cut -d: -f1)
  idx_fallback=$(printf '%s' "$multi_out" | grep -bo 'FALLBACK:' | head -1 | cut -d: -f1)
  idx_vacant_unknown=$(printf '%s' "$multi_out" | grep -bo 'VACANT_UNKNOWN:' | head -1 | cut -d: -f1)
  idx_advisory=$(printf '%s' "$multi_out" | grep -bo 'ADVISORY:' | head -1 | cut -d: -f1)
  assert_contains "複合ケースでFALLBACKにleaderとtesterの両方が出る" "$multi_out" "FALLBACK:leader,tester"
  order_multi_ok=1
  [ -n "$idx_ok" ] && [ -n "$idx_fallback" ] && [ "$idx_ok" -lt "$idx_fallback" ] || order_multi_ok=0
  [ -n "$idx_fallback" ] && [ -n "$idx_vacant_unknown" ] && [ "$idx_fallback" -lt "$idx_vacant_unknown" ] || order_multi_ok=0
  [ -n "$idx_vacant_unknown" ] && [ -n "$idx_advisory" ] && [ "$idx_vacant_unknown" -lt "$idx_advisory" ] || order_multi_ok=0
  assert_eq "OK→FALLBACK→VACANT_UNKNOWN→ADVISORYの出現順が固定順どおり" "1" "$order_multi_ok"
}

echo "=== 38. 候補評価§3.6: 本命と代替の失敗理由が異なるとき、優先順(V1-b→V9-d→V12)で高い方が採用される（ホワイトボックス・Codex二次レビュー指摘・Major対応: CLI経由のfixtureでは本命/fallbackが同一職種名を共有するためV1-bは両者で必ず同じ結果になり、異なる理由の組み合わせを黒箱では再現できない。_evaluate_single_candidate()を差し替えて優先順ロジック自体を直接検証する） ==="
{
  result="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 - <<'PYEOF'
import profile_resolve as pr


class Fake:
    def __init__(self, name):
        self.name = name
        self.state = "configured"
        self.attrs = {"provider": "anthropic-api", "model": "claude-opus-5", "execution": "subagent"}


def fake_eval(line, agents_dir, bedrock_env, is_leader):
    if line is primary:
        return False, "V9-d", None
    return False, "V1-b", None


primary = Fake("tester")
fallback = Fake("tester")
orig = pr._evaluate_single_candidate
pr._evaluate_single_candidate = fake_eval
try:
    cand = pr.evaluate_worker_candidate("tester", {"tester": primary}, {"tester": fallback}, None, None)
finally:
    pr._evaluate_single_candidate = orig
print(cand.vacant_reason)
PYEOF
)"
  assert_eq "本命=V9-d・fallback=V1-bでもV1-bの方が優先順が高いのでV1-bが選ばれる" "V1-b" "$result"
}

echo "=== 39. §3.7 判定不能: ワーカーが判定不能で通ったこと自体がADVISORY(JUDGEMENT_UNKNOWN)として出る（Codex一次レビュー指摘・Major対応: 従来はunknown_noteを保持するだけで出力していなかった） ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir2
  UNREADABLE_ENV2="/tmp/aienv-test-unreadable-env-dir2/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV2"
  chmod 0000 "$UNREADABLE_ENV2"

  ADV_UNKNOWN="$(mktemp -d)/advunknown.md"
  make_v2_profile "$ADV_UNKNOWN" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku"
  out="$(resolve_v2 "$ADV_UNKNOWN" "$UNREADABLE_ENV2")"  || true
  assert_contains "判定不能で通した職種があることがADVISORY:JUDGEMENT_UNKNOWNとして出る" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"

  chmod 0700 "$UNREADABLE_ENV2"
  rm -rf /tmp/aienv-test-unreadable-env-dir2
}

echo "=== 40. §4.1-f: leaderがfallback救済されたときも職種名'leader'がFALLBACK:へ出る（Codex一次レビュー指摘・Major対応: 従来はワーカーだけが対象だった） ==="
{
  LEADER_FB="$(mktemp -d)/leaderfb.md"
  make_v2_profile "$LEADER_FB" \
    "role.leader: unavailable provider=bedrock model=opus" \
    "fallback.leader: configured provider=anthropic-api model=claude-opus-5"
  out="$(resolve_v2 "$LEADER_FB")"  || true
  assert_contains "leaderのfallback採用がFALLBACK:leaderとして出る" "$out" "FALLBACK:leader"
}

echo "=== 41. 秘匿: check-candidateとresolve-leaderのstderr（失敗時）にもピン実値・AWS認証情報が一切現れない（Codex一次レビュー指摘・Major対応: 従来のテストはresolveの標準出力だけを見ていた） ==="
{
  PIN_ENV2="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV2" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn-2
AWS_SECRET_ACCESS_KEY=SHOULD_NEVER_LEAK_2
EOF
  # Codex二次レビュー指摘・Major対応: --model opusはピン(ANTHROPIC_DEFAULT_
  # OPUS_MODEL)が満たされているためcheck-candidateはOK(成功)を返し、失敗経路の
  # 秘匿を検査したことにならなかった。ピンが無いhaikuを使いFAIL経路を通す。
  cc_out="$(python3 "$PROFILE_LIB" check-candidate --provider bedrock --model haiku \
    --role-name leader --for-leader --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1)"  || true
  assert_contains "check-candidateが実際にFAILを返している（テストの前提確認）" "$cc_out" "FAIL"
  assert_not_contains "check-candidate出力にピン実値が現れない" "$cc_out" "supersecret-arn-2"
  assert_not_contains "check-candidate出力にAWSキーが現れない" "$cc_out" "SHOULD_NEVER_LEAK_2"

  LEADER_FAIL_ENV="$(mktemp -d)/leaderfailenv.md"
  make_v2_profile "$LEADER_FAIL_ENV" "role.leader: configured provider=bedrock model=sonnet"
  leader_err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_FAIL_ENV" --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_not_contains "resolve-leaderのstderrにもピン実値が現れない" "$leader_err" "supersecret-arn-2"
  assert_not_contains "resolve-leaderのstderrにもAWSキーが現れない" "$leader_err" "SHOULD_NEVER_LEAK_2"
}

echo "=== 42. §3.4 T4'(実体の版>コードの版): 未知キーを無視しADVISORY:T4-PRIME+UNKNOWN_EXTRAで通す(最小能力へは倒さない) ==="
{
  T4PRIME="$(mktemp -d)/t4prime.md"
  make_v2_profile "$T4PRIME" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/schema_version: 2/schema_version: 3/' "$T4PRIME"
  # ---の直前に未知キーを挿入する。

  python3 - "$T4PRIME" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "future_key_v3: configured value=something")
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  out="$(resolve_v2 "$T4PRIME")"  || true
  assert_contains "T4-PRIME: MINIMALへは倒さない" "$out" "OK"
  assert_contains "T4-PRIME: ADVISORYコードが出る" "$out" "ADVISORY:T4-PRIME"
  assert_contains "T4-PRIME: 未知キーはUNKNOWN_EXTRAにも出る" "$out" "UNKNOWN_EXTRA:future_key_v3"
}

echo "=== 43. §3.4 T4(実体の版<コードの版): 欠落した固定キーをunknownで仮想補完しADVISORY:T4で通す（ホワイトボックス・Codex二次レビュー指摘・Major対応: 環境変数で本番の期待版を差し替えられる穴を撤去したため、テストはサブプロセス内でモジュール属性を直接上書きする。本番の起動経路（bootstrap-vault.sh・install-main.sh）には一切影響しない） ==="
{
  T4="$(mktemp -d)/t4.md"
  make_v2_profile "$T4" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  # web_verificationキーを欠落させる（EXPECTED=3のときだけT5にせずT4で仮想補完される）。
  python3 - "$T4" <<'PYEOF'
import sys
path = sys.argv[1]
lines = [l for l in open(path).read().splitlines() if not l.startswith("web_verification:")]
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  out_normal="$(resolve_v2 "$T4")"  || true
  assert_contains "EXPECTED=2(現行)のままなら欠落はT5でMINIMALになる（回帰確認）" "$out_normal" "MINIMAL	T5"

  out_override="$(python3 - "$T4" "$AGENTS_DIR" <<PYEOF
import sys
sys.path.insert(0, "$REPO_ROOT/claude/hooks/lib")
import profile_resolve as pr
pr.EXPECTED_SCHEMA_VERSION = 3
line, code = pr.do_resolve(sys.argv[1], None, sys.argv[2])
print(line)
PYEOF
)"
  assert_contains "EXPECTED=3に差し替えるとT4で仮想補完されOKになる" "$out_override" "OK"
  assert_contains "T4のADVISORYコードが出る" "$out_override" "ADVISORY:T4"
}

echo "=== 44. V8-b共通規則・excluded_modelsの扱い統一（Codex一次レビュー指摘・Major対応） ==="
{
  EM_SENTINEL="$(mktemp -d)/emsentinel.md"
  make_v2_profile "$EM_SENTINEL" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: configured value=<fill-in>/' "$EM_SENTINEL"
  out="$(resolve_v2 "$EM_SENTINEL")"  || true
  assert_contains "excluded_modelsのsentinelもT2-MINIMALで検出される" "$out" "MINIMAL	T2-MINIMAL"
  assert_contains "T2-MINIMALの理由にexcluded_modelsが出る" "$out" "excluded_models"

  DUP_VALUE="$(mktemp -d)/dupvalue.md"
  make_v2_profile "$DUP_VALUE" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/web_verification: configured value=websearch/web_verification: configured value=websearch,websearch/' "$DUP_VALUE"
  out="$(resolve_v2 "$DUP_VALUE")"  || true
  assert_contains "value内の重複要素はV8-bでMINIMALになる（共通規則）" "$out" "MINIMAL	T8	V8-b"

  EM_UNAVAIL="$(mktemp -d)/emunavail.md"
  make_v2_profile "$EM_UNAVAIL" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: unavailable/' "$EM_UNAVAIL"
  out="$(resolve_v2 "$EM_UNAVAIL")"  || true
  assert_contains "excluded_models: unavailable（属性無し）はOKになる（他の能力軸キーと同じ3状態）" "$out" "OK"
}

echo "=== 45. is_v2_resolve_output_well_formed(): ゴミ混入・重複・順序違反はいずれも拒否される（Codex三次レビュー指摘・Major対応） ==="
{
  source_well_formed() {
    # bootstrap-vault.sh から is_v2_resolve_output_well_formed だけを取り込む
    # （本体を実行させないよう、関数定義を含む範囲だけをsedで切り出す）。
    eval "$(sed -n '/^is_v2_resolve_output_well_formed()/,/^}/p' "$SCRIPT")"
  }
  source_well_formed

  T="$(printf 'OK\tschema_version=2')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "正常なOK単体は受理される" || fail_case "正常なOK単体は受理される"

  T="$(printf 'OK\tschema_version=2\tGARBAGE:xyz')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "未知フィールド(GARBAGE)混入は拒否される" || fail_case "未知フィールド(GARBAGE)混入は拒否される"

  T="$(printf 'OK\tschema_version=2\tFALLBACK:tester\tFALLBACK:tester')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "同一フィールドの重複は拒否される" || fail_case "同一フィールドの重複は拒否される"

  T="$(printf 'OK\tschema_version=2\tVACANT:tester\tFALLBACK:tester')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "フィールドの順序違反(VACANTがFALLBACKより先)は拒否される" || fail_case "フィールドの順序違反(VACANTがFALLBACKより先)は拒否される"

  T="$(printf 'OK\tschema_version=2')"
  ! is_v2_resolve_output_well_formed "$T" 1 && pass "OKなのにexit1は拒否される" || fail_case "OKなのにexit1は拒否される"

  T="$(printf 'MINIMAL\tT6\t3行目: 解析できない行です')"
  is_v2_resolve_output_well_formed "$T" 1 && pass "正常なMINIMAL(exit1)は受理される" || fail_case "正常なMINIMAL(exit1)は受理される"

  T="$(printf 'MINIMAL\tT6\t理由')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MINIMALなのにexit0は拒否される" || fail_case "MINIMALなのにexit0は拒否される"

  T="$(printf 'OK\tschema_version=2\nEXTRA_LINE')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "複数行出力は拒否される" || fail_case "複数行出力は拒否される"

  T="$(printf 'MINIMAL\tT6\t3行目: 解析できない行です\tGARBAGE')"
  ! is_v2_resolve_output_well_formed "$T" 1 && pass "MINIMALの理由部分にタブで4つ目のフィールドが紛れ込むと拒否される（Codex三次レビュー指摘・Major対応）" \
    || fail_case "MINIMALの理由部分にタブで4つ目のフィールドが紛れ込むと拒否される"

  T="$(printf 'OK\tschema_version=2\tVACANT_UNKNOWN:My_Role.v2')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "大文字・アンダースコア・ドットを含む職種名も受理される（Codex三次レビュー指摘・Major対応: parserのKEY_RE[A-Za-z0-9_.-]+と同じ文字集合に統一）" \
    || fail_case "大文字・アンダースコア・ドットを含む職種名も受理される"
}

echo "=== 46. list-roles: kind/state/execution既定値/not_adopted・unknownの空欄化・fallbackの並び（リーダー裁定2026-09-01でB向けに追加確定・契約書§4.5） ==="
{
  LR="$(mktemp -d)/listroles.md"
  make_v2_profile "$LR" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.navi: unknown" \
    "role.researcher: not_adopted" \
    "role.system-designer: configured provider=anthropic-api model=claude-opus-5 effort=high" \
    "role.tester: unavailable provider=bedrock model=opus" \
    "fallback.tester: configured provider=anthropic-api model=claude-sonnet-5"
  out="$(python3 "$PROFILE_LIB" list-roles "$LR")"  || true

  assert_contains "role.leaderの行がkind=role・state=configuredで出る" "$out" "role	leader	configured	anthropic-api	claude-opus-5	subagent	"
  assert_contains "executionが省略されていてもsubagentが補われて出る" "$out" "	subagent	"
  assert_contains "effortが指定されていればそのまま出る(system-designer=high)" "$out" "role	system-designer	configured	anthropic-api	claude-opus-5	subagent	high"
  assert_contains "unknown状態はprovider以降が全て空文字になる" "$out" "role	navi	unknown				"
  assert_contains "not_adopted状態もprovider以降が全て空文字になる" "$out" "role	researcher	not_adopted				"
  assert_contains "unavailable状態はprovider/modelを保持したまま出る（意図の記録）" "$out" "role	tester	unavailable	bedrock	opus	subagent	"
  assert_contains "fallback行もkind=fallbackとして出る" "$out" "fallback	tester	configured	anthropic-api	claude-sonnet-5	subagent	"

  # role.表→fallback.表の順であることの確認（roleの最後の行より後にfallbackが来る）。
  role_idx=$(printf '%s' "$out" | grep -n '^role	tester' | head -1 | cut -d: -f1)
  fallback_idx=$(printf '%s' "$out" | grep -n '^fallback	tester' | head -1 | cut -d: -f1)
  order_ok=1
  [ -n "$role_idx" ] && [ -n "$fallback_idx" ] && [ "$role_idx" -lt "$fallback_idx" ] || order_ok=0
  assert_eq "role.表の行がfallback.表の行より先に出る" "1" "$order_ok"
}

echo "=== 47. list-roles: 失敗時（自己完結・resolve-leaderと同じコード体系）はstdoutが空でstderrへ機械可読コードが出る ==="
{
  err="$(python3 "$PROFILE_LIB" list-roles /nonexistent-dir/nope.md 2>&1 1>/dev/null)"  || true
  assert_contains "存在しないファイルはPROFILE_NOT_FOUNDになる" "$err" "PROFILE_NOT_FOUND"

  DUP="$(mktemp -d)/lrdup.md"
  make_v2_profile "$DUP" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.leader: unknown"
  out="$(python3 "$PROFILE_LIB" list-roles "$DUP" 2>/dev/null)"  || true
  err="$(python3 "$PROFILE_LIB" list-roles "$DUP" 2>&1 1>/dev/null)"  || true
  assert_eq "パース失敗時はstdoutが空" "" "$out"
  assert_contains "パース失敗時はstderrへPROFILE_INVALID:T6が出る" "$err" "PROFILE_INVALID:T6"
}

echo "=== 48. 秘匿: list-rolesの出力にもbedrock.envのピン実値・AWS認証情報が一切現れない（リーダー裁定2026-09-01の指示どおり§10の秘匿テストを追加） ==="
{
  PIN_ENV3="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV3" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn-3
AWS_SECRET_ACCESS_KEY=SHOULD_NEVER_LEAK_3
EOF
  LR_SECRET="$(mktemp -d)/lrsecret.md"
  make_v2_profile "$LR_SECRET" \
    "role.leader: configured provider=bedrock model=opus"
  # list-rolesはbedrock-envを引数に取らない（profile本体の値=別名しか扱わない
  # 設計）ため、そもそもbedrock.envを読まない。念のため実際に出力へ実値が
  # 混入していないことを確認する。
  out="$(python3 "$PROFILE_LIB" list-roles "$LR_SECRET")"  || true
  assert_not_contains "list-roles出力にピン実値(ARN)が現れない" "$out" "supersecret-arn-3"
  assert_not_contains "list-roles出力にAWSキーが現れない" "$out" "SHOULD_NEVER_LEAK_3"
  assert_contains "list-roles出力にはBedrockの別名(opus)だけが出る" "$out" "role	leader	configured	bedrock	opus	subagent	"
}

echo "=== 49. tester独立検証差し戻し(Major): bedrock.envに不正UTF-8があってもクラッシュせず、判定不能として扱われる（_read_bedrock_env_wanted()がUnicodeDecodeErrorを未捕捉だった実バグの回帰テスト） ==="
{
  BAD_UTF8_ENV="$(mktemp -d)/bedrock.env"
  printf 'CLAUDE_CODE_USE_BEDROCK=1\nANTHROPIC_DEFAULT_HAIKU_MODEL=\xff\xfebroken\n' > "$BAD_UTF8_ENV"

  WORKER_BAD_UTF8="$(mktemp -d)/workerbadutf8.md"
  make_v2_profile "$WORKER_BAD_UTF8" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=haiku"
  out="$(resolve_v2 "$WORKER_BAD_UTF8" "$BAD_UTF8_ENV")"  || true
  err="$(python3 "$PROFILE_LIB" resolve "$WORKER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "workerは判定不能で通り(JUDGEMENT_UNKNOWN)クラッシュしない" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"
  assert_not_contains "workerはVACANTにならない" "$out" "VACANT:tester"
  assert_not_contains "stderrにPythonのtracebackが出ない" "$err" "Traceback"

  LEADER_BAD_UTF8="$(mktemp -d)/leaderbadutf8.md"
  make_v2_profile "$LEADER_BAD_UTF8" "role.leader: configured provider=bedrock model=haiku"
  out2="$(resolve_v2 "$LEADER_BAD_UTF8" "$BAD_UTF8_ENV")"  || true
  err2="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "leaderはクリーンな機械可読コードで非0終了する" "$out2" "MINIMAL"
  assert_not_contains "resolveのstderrにもtracebackが出ない" "$(python3 "$PROFILE_LIB" resolve "$LEADER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)" "Traceback"
  assert_not_contains "resolve-leaderのstderrにtracebackが出ない" "$err2" "Traceback"
  assert_contains "resolve-leaderは機械可読コード(LEADER_CANDIDATE_INVALID)を返す" "$err2" "LEADER_CANDIDATE_INVALID"

  echo "--- --check-profile相当(list-roles)も不正UTF-8のbedrock.envの影響を受けない(list-rolesはbedrock.envを読まない設計のため無関係だが念のため) ---"
  lr_out="$(python3 "$PROFILE_LIB" list-roles "$WORKER_BAD_UTF8" 2>&1)"  || true
  assert_not_contains "list-rolesもtracebackを出さない" "$lr_out" "Traceback"
}

echo "=== 50. §10欠落補充: T12(v1委譲でLEGACY_V1がトップレベルに出る)・T3-PRIME(混在)・T10(lib欠落)を分類ディスパッチャ(resolve_local_profile())で直接検証（tester独立検証・§10欠落指摘対応） ==="
{
  V1_OK="$(mktemp -d)/v1ok.md"
  make_ok_profile "$V1_OK"
  out="$(run_resolve_local_profile_dispatch "$V1_OK")"
  assert_contains "v1でOKなプロファイルはトップレベルがLEGACY_V1になる(T12)" "$out" "LEGACY_V1"
  assert_not_contains "生のOKトークンでは始まらない(トップレベルが差し替わっている)" "$out" "OK	"

  MIXED_DISPATCH="$(mktemp -d)/mixeddispatch.md"
  cat > "$MIXED_DISPATCH" <<'EOF'
---
inventory_source: Vault
role.leader: configured provider=anthropic-api model=claude-opus-5
---
EOF
  out="$(run_resolve_local_profile_dispatch "$MIXED_DISPATCH")"
  assert_contains "混在はMINIMAL/T3-PRIMEになる" "$out" "MINIMAL	T3-PRIME"

  V2_OK_DISPATCH="$(mktemp -d)/v2okdispatch.md"
  make_v2_profile "$V2_OK_DISPATCH" "role.leader: configured provider=anthropic-api model=claude-opus-5"
  out="$(run_resolve_local_profile_dispatch "$V2_OK_DISPATCH" "/nonexistent/lib-for-t10-test.py")"
  assert_contains "libが見つからない場合はT10になる(v2分類のprofileでも)" "$out" "MINIMAL	T10"
}

echo "=== 51. V14メタ構文の直接検証: schema_versionが正整数でない・profile_slugが規約に反する ==="
{
  BADVER="$(mktemp -d)/badver.md"
  make_v2_profile "$BADVER" "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/schema_version: 2/schema_version: abc/' "$BADVER"
  out="$(resolve_v2 "$BADVER")"  || true
  assert_contains "schema_versionが数値でなければT3になる" "$out" "MINIMAL	T3"

  BADVER0="$(mktemp -d)/badver0.md"
  make_v2_profile "$BADVER0" "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/schema_version: 2/schema_version: 0/' "$BADVER0"
  out="$(resolve_v2 "$BADVER0")"  || true
  assert_contains "schema_version=0(正整数でない)もT3になる" "$out" "MINIMAL	T3"

  BADSLUG="$(mktemp -d)/badslug.md"
  make_v2_profile "$BADSLUG" "role.leader: configured provider=anthropic-api model=claude-opus-5"
  sed -i '' 's/profile_slug: authoring/profile_slug: Bad_Slug!/' "$BADSLUG"
  out="$(resolve_v2 "$BADSLUG")"  || true
  assert_contains "profile_slugが規約(^[a-z0-9][a-z0-9-]*\$)に反するとT14になる" "$out" "MINIMAL	T14"
}

echo "=== 52. V8-a 状態4値×属性有無の網羅補充: unavailableでmodel欠落・unknownが属性を持つ ==="
{
  UNAVAIL_MISSING="$(mktemp -d)/unavailmissing.md"
  make_v2_profile "$UNAVAIL_MISSING" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: unavailable provider=bedrock"
  out="$(resolve_v2 "$UNAVAIL_MISSING")"  || true
  assert_contains "unavailableでもmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNKNOWN_ATTR="$(mktemp -d)/unknownattr.md"
  make_v2_profile "$UNKNOWN_ATTR" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: unknown provider=anthropic-api model=claude-sonnet-5"
  out="$(resolve_v2 "$UNKNOWN_ATTR")"  || true
  assert_contains "unknown状態で属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  MISSING_PROVIDER="$(mktemp -d)/missingprovider.md"
  make_v2_profile "$MISSING_PROVIDER" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5 execution=subagent"
  sed -i '' 's/role.leader: configured provider=anthropic-api model=claude-opus-5 execution=subagent/role.leader: configured model=claude-opus-5/' "$MISSING_PROVIDER"
  out="$(resolve_v2 "$MISSING_PROVIDER")"  || true
  assert_contains "providerが無いこともV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"
}

echo "=== 53. bedrock-mantle provider: 適合表(§3.3)の形式検査とV12対象外(ピンチェックを課さない) ==="
{
  MANTLE_OK="$(mktemp -d)/mantleok.md"
  make_v2_profile "$MANTLE_OK" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock-mantle model=anthropic.claude-3-haiku"
  # bedrock.envは渡すがCLAUDE_CODE_USE_BEDROCKだけ有効にする(ピンは無し)。
  MANTLE_ENV="$(mktemp -d)/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$MANTLE_ENV"
  out="$(resolve_v2 "$MANTLE_OK" "$MANTLE_ENV")"  || true
  assert_contains "bedrock-mantleは正しい形式(anthropic.で始まる)ならOKになる(V12の対象外)" "$out" "OK"
  assert_not_contains "bedrock-mantleはVACANTにならない(ピンチェック不要)" "$out" "VACANT:tester"

  MANTLE_BAD="$(mktemp -d)/mantlebad.md"
  make_v2_profile "$MANTLE_BAD" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock-mantle model=not-anthropic-prefixed"
  out="$(resolve_v2 "$MANTLE_BAD")"  || true
  assert_contains "bedrock-mantleでanthropic.始まりでないmodelはV9-bでMINIMALになる" "$out" "MINIMAL	T8	V9-b"
}

echo "=== 54. effort enum境界の直接検証(V9-b/V9-e): Claude系max・Codex方言minimal・設定効果先の非対称 ==="
{
  WORKER_MAX="$(mktemp -d)/workermax.md"
  make_v2_profile "$WORKER_MAX" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=anthropic-api model=claude-sonnet-5 effort=max"
  out="$(resolve_v2 "$WORKER_MAX")"  || true
  assert_contains "ワーカー行はmaxを書ける(V9-bのenumはEFFORT_CLAUDEでmaxを含む)" "$out" "OK"

  LEADER_MAX="$(mktemp -d)/leadermax.md"
  make_v2_profile "$LEADER_MAX" "role.leader: configured provider=anthropic-api model=claude-opus-5 effort=max"
  out="$(resolve_v2 "$LEADER_MAX")"  || true
  assert_contains "leader行はmaxだとV9-eで弾かれfailになる(settings.jsonのeffortLevelがmaxを受理しないため)" "$out" "MINIMAL"
  err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_MAX" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderのエラーコードにV9-eが出る" "$err" "V9-e"

  CODEX_MINIMAL="$(mktemp -d)/codexminimal.md"
  make_v2_profile "$CODEX_MINIMAL" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.primary-reviewer: configured provider=external execution=external-mcp model=codex-review-default effort=minimal"
  out="$(resolve_v2 "$CODEX_MINIMAL")"  || true
  assert_contains "Codexハンドラ(external-mcp/codex-review-default)はminimalを書ける" "$out" "OK"

  CODEX_MINIMAL_ELSEWHERE="$(mktemp -d)/codexminimalelsewhere.md"
  make_v2_profile "$CODEX_MINIMAL_ELSEWHERE" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=anthropic-api model=claude-sonnet-5 effort=minimal"
  out="$(resolve_v2 "$CODEX_MINIMAL_ELSEWHERE")"  || true
  assert_contains "Claude系(anthropic-api)でminimalはV9-bでMINIMALになる(Codex方言はexternalハンドラ限定)" "$out" "MINIMAL	T8	V9-b"
}

echo "=== 55. V9-f直接検証: 既知の非対応モデル×xhigh はADVISORY、別名は判別不能としてEFFORT_COMPATIBILITY_UNVERIFIED ==="
{
  V9F_KNOWN="$(mktemp -d)/v9fknown.md"
  make_v2_profile "$V9F_KNOWN" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=anthropic-api model=claude-opus-4.6 effort=xhigh"
  out="$(resolve_v2 "$V9F_KNOWN")"  || true
  # ADVISORYフィールドはコードをソートして併記する(§5)ため"V1-a,V9-f"に
  # なる。"ADVISORY:V9-f"という直結文字列を探すのは誤り(実測で判明)。
  assert_contains "既知の非対応モデル(claude-opus-4.6)×xhighはV9-fがADVISORYに含まれる(failにしない)" "$out" "V9-f"
  assert_contains "failにしない(OKのまま)" "$out" "OK"

  V9F_BEDROCK="$(mktemp -d)/v9fbedrock.md"
  make_v2_profile "$V9F_BEDROCK" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5" \
    "role.tester: configured provider=bedrock model=opus effort=xhigh"
  out="$(resolve_v2 "$V9F_BEDROCK")"  || true
  assert_contains "bedrock別名は実モデル版を判別できないためEFFORT_COMPATIBILITY_UNVERIFIEDになる" "$out" "ADVISORY:EFFORT_COMPATIBILITY_UNVERIFIED"
}

echo "=== 56. check_leader_settings_drift(): S10/S11/S16対応（配役表解凍-設計-2026-09-01.md §6.2-B）。v2のリーダー行が解決できたセッションでsettings.jsonとの整合をSessionStartのたびに軽量比較する ==="
{
  LEADER_PROFILE="$(mktemp -d)/leaderdrift.md"
  make_v2_profile "$LEADER_PROFILE" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5 effort=high"

  echo "--- S10/S11/S16共通の検出信号: settings.jsonのmodelが配役表の解決値と食い違う(手で直した/旧ファイルを放置/生成失敗のいずれでも観測結果は同じ不一致になる) ---"
  SETTINGS_MODEL_MISMATCH="$(mktemp -d)/settings-model-mismatch.json"
  cat > "$SETTINGS_MODEL_MISMATCH" <<'EOF'
{"model": "claude-sonnet-5", "effortLevel": "high"}
EOF
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_MODEL_MISMATCH" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" "$SCRIPT" < /dev/null)"
  assert_contains "modelの不一致で⚠️が出る" "$out" "⚠️"
  assert_contains "不一致フィールドとしてmodelが挙がる" "$out" "model"

  echo "--- effortLevelの不一致(同じ検出信号の別バリエーション) ---"
  SETTINGS_EFFORT_MISMATCH="$(mktemp -d)/settings-effort-mismatch.json"
  cat > "$SETTINGS_EFFORT_MISMATCH" <<'EOF'
{"model": "claude-opus-5", "effortLevel": "low"}
EOF
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_EFFORT_MISMATCH" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" "$SCRIPT" < /dev/null)"
  assert_contains "effortLevelの不一致で⚠️が出る" "$out" "⚠️"
  assert_contains "不一致フィールドとしてeffortLevelが挙がる" "$out" "effortLevel"

  echo "--- 正常系: settings.jsonが配役表の解決値と一致していれば警告なし(S10/S11/S16のいずれの状態でもない) ---"
  SETTINGS_MATCH="$(mktemp -d)/settings-match.json"
  cat > "$SETTINGS_MATCH" <<'EOF'
{"model": "claude-opus-5", "effortLevel": "high"}
EOF
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_MATCH" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" "$SCRIPT" < /dev/null)"
  assert_eq "model/effortLevelとも一致していれば出力は空" "" "$out"

  echo "--- effort未指定のleader行では、settings.jsonにeffortLevelキーが有るだけで不一致になる（§3.8の非対称） ---"
  LEADER_NO_EFFORT="$(mktemp -d)/leadernoeffort.md"
  make_v2_profile "$LEADER_NO_EFFORT" \
    "role.leader: configured provider=anthropic-api model=claude-opus-5"
  SETTINGS_UNEXPECTED_EFFORT="$(mktemp -d)/settings-unexpected-effort.json"
  cat > "$SETTINGS_UNEXPECTED_EFFORT" <<'EOF'
{"model": "claude-opus-5", "effortLevel": "high"}
EOF
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_NO_EFFORT" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_UNEXPECTED_EFFORT" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" "$SCRIPT" < /dev/null)"
  assert_contains "effort未指定なのにeffortLevelキーが存在すると不一致になる" "$out" "⚠️"

  echo "--- 比較不能ケース(リーダー要件③): settings.jsonが存在しないなら「監視不能」として⚠️を出す(静かに素通りさせない) ---"
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="/nonexistent-dir/no-such-settings.json" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" "$SCRIPT" < /dev/null)"
  assert_contains "settings.json不在は監視不能として⚠️になる" "$out" "⚠️"

  echo "--- settings.jsonがJSONとして壊れている場合も監視不能として⚠️を出す ---"
  SETTINGS_BROKEN="$(mktemp -d)/settings-broken.json"
  printf '{not valid json' > "$SETTINGS_BROKEN"
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_BROKEN" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" "$SCRIPT" < /dev/null)"
  assert_contains "settings.json破損は監視不能として⚠️になる" "$out" "⚠️"

  echo "--- Codex一次レビュー指摘・Major対応の回帰: resolve-leaderが契約違反の不正effort(null/空文字列)を返しても『未指定』へ静かに丸めず監視不能になる ---"
  # PROFILE_RESOLVE_LIBを差し替え可能なことを利用し、resolve-leaderが
  # 契約(profile-resolve-contract §4)に反する形（キーはあるが値がnull・
  # 空文字列）のJSONを返すケースを直接シミュレートする（本物のresolverが
  # こう振る舞うことは想定していないが、防御的検証として固定する）。
  STUB_LIB_DIR="$(mktemp -d)"
  STUB_LIB="$STUB_LIB_DIR/profile_resolve.py"
  cat > "$STUB_LIB" <<'EOF'
import sys
if sys.argv[1] == "resolve-leader":
    print('{"model": "claude-opus-5", "effort": null}')
    sys.exit(0)
sys.exit(1)
EOF
  SETTINGS_ANY="$(mktemp -d)/settings-any.json"
  cat > "$SETTINGS_ANY" <<'EOF'
{"model": "claude-opus-5"}
EOF
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_ANY" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" PROFILE_RESOLVE_LIB="$STUB_LIB" "$SCRIPT" < /dev/null)"
  # Codex一次レビュー2巡目指摘・Minor対応: 「⚠️」だけの検査だと、
  # effortLevel欠落を理由にした通常の不一致検出（旧実装でも⚠️が出るパス）
  # と区別できず、修正が効いていなくても偽陽性で通ってしまう。修正で
  # 新設した専用メッセージ文言そのものを検査し、UNAVAILABLE分岐を通った
  # ことを確認する。
  assert_contains "不正な型のeffort(null)は一致と誤判定せず監視不能(effortが不正)の分岐になる" "$out" "配役表のリーダー実行値のeffortが不正です"

  echo "--- 同上の別バリエーション: effortキーはあるが値が空文字列 ---"
  cat > "$STUB_LIB" <<'EOF'
import sys
if sys.argv[1] == "resolve-leader":
    print('{"model": "claude-opus-5", "effort": ""}')
    sys.exit(0)
sys.exit(1)
EOF
  out="$(BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1 AIENV_LOCAL_PROFILE_PATH="$LEADER_PROFILE" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_ANY" AIENV_AGENTS_DIR="$AGENTS_DIR" \
    AIENV_BEDROCK_ENV_FILE="/nonexistent-dir/bedrock.env" PROFILE_RESOLVE_LIB="$STUB_LIB" "$SCRIPT" < /dev/null)"
  assert_contains "空文字列のeffortも監視不能(effortが不正)の分岐になる" "$out" "配役表のリーダー実行値のeffortが不正です"
  rm -rf "$STUB_LIB_DIR"

  echo "--- ゲート無効(BOOTSTRAP_ENABLE_LOCAL_PROFILE未設定=既定0)では、settings.jsonが不一致でもDIRECTIVEに一切現れない(今日までの挙動を変えない) ---"
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "ゲート無効時はsettings.json関連の文言が一切出ない" "$ctx" "settings.json"

  echo "--- 結合(SessionStart全体): ゲート有効・不一致プロファイルでDIRECTIVEの【ローカル実体プロファイル】ブロックに警告が注入される ---"
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$LEADER_PROFILE" "$SETTINGS_MODEL_MISMATCH")"
  assert_contains "DIRECTIVEにsettings.json不一致の警告が出る" "$ctx" "settings.json(${SETTINGS_MODEL_MISMATCH})が配役表のリーダー行"
  assert_not_contains "settings.jsonの実際のmodel値(claude-sonnet-5)そのものは再掲しない（不一致メッセージはフィールド名のみ）" "$ctx" "claude-sonnet-5"

  echo "--- 結合(SessionStart全体): 一致していればDIRECTIVEにsettings.json関連の警告は出ない ---"
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$LEADER_PROFILE" "$SETTINGS_MATCH")"
  assert_not_contains "一致していれば警告が出ない" "$ctx" "settings.json"

  echo "--- LEGACY_V1(v1委譲)はスコープ外: v1プロファイルではsettings.json比較を試みない(週次drift=check-drift.shのV13が既にv1をカバーする) ---"
  V1_PROFILE="$(mktemp -d)/v1profile.md"
  make_ok_profile "$V1_PROFILE"
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$V1_PROFILE" "$SETTINGS_BROKEN")"
  assert_contains "v1委譲の警告文言は出る" "$ctx" "v1形式です"
  assert_not_contains "v1ではsettings.json比較の監視不能メッセージは出ない(スコープ外)" "$ctx" "監視不能"

  rm -rf "$VAULT_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
