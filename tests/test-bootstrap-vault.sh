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
# PATHをspyディレクトリだけに絞る外部プロセス計数テスト（§10.5）で使う。
# 絞ったPATHでも`bash`自身が見つかるよう、絶対パスを先に確定しておく。
REAL_BASH="$(command -v bash)"
# spyラッパーが`exec`する実バイナリを解決する。⚠️ `python3`はpyenv等の
# バージョンマネージャのshim（内部でPATHに依存した探索を行うbashスクリプト）
# であることがあり、そのままexecするとPATHをspyだけに絞った環境では実体を
# 見失って失敗・停止する。`pyenv which`が使えるときはそちらでshimの先の
# 実バイナリを解決し、無ければ`command -v`にフォールバックする。
resolve_real_cmd_for_spy() {
  local cmd="$1"
  if [ "$cmd" = "python3" ] && command -v pyenv >/dev/null 2>&1; then
    pyenv which python3 2>/dev/null && return 0
  fi
  command -v "$cmd" 2>/dev/null || true
}

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

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    pass "$desc"
  else
    fail_case "$desc"
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

# assert_ascending_line_positions <desc> <haystack> <marker1> <marker2> ... —
# 各markerが行頭(^marker + 半角空白)に現れる最初の行番号を取り、渡した順に
# 単調増加であることを検査する（①→②→④→⑤→⑥の順序不変。③は欠番。
# 差分レビュー指摘#5対応。並べ替えるとここで落ちる）。
assert_ascending_line_positions() {
  local desc="$1"; shift
  local haystack="$1"; shift
  local prev=0 m line
  for m in "$@"; do
    line="$(printf '%s\n' "$haystack" | grep -n "^${m} " | head -1 | cut -d: -f1)"
    if [ -z "$line" ]; then
      fail_case "$desc (${m} の行が見つからない)"
      return
    fi
    if [ "$line" -le "$prev" ]; then
      fail_case "$desc (${m} の位置が順序どおりでない: line=$line prev=$prev)"
      return
    fi
    prev="$line"
  done
  pass "$desc"
}

# safe_mktemp_d — mktemp -d のラッパー。差分レビュー指摘#6（MAJOR）対応。
# 本ファイルは `set -euo pipefail` のため `VAR="$(mktemp -d)"` の失敗自体は
# 既に即終了する契約だが、失敗せずに空・`/`・既存の非空ディレクトリという
# 異常な値を返した場合の防御をtest-dock-pane-resolve.shのWORK_DIRガードと
# 揃える（同種の`rm -rf`巻き込み事故を防ぐ二重の安全網）。
# 標準出力へ検証済みのパスを1行返す。失敗時はFATALをstderrへ出しreturn 1
# （呼び出し側は `VAR="$(safe_mktemp_d)" || exit 1` の形で使うこと）。
safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; return 1; }
  case "$d" in
    "" | "/")
      echo "FATAL: mktemp -d の返り値が不正です: [$d]" >&2
      return 1
      ;;
  esac
  if [ ! -d "$d" ]; then
    echo "FATAL: mktemp -d がディレクトリを作成しませんでした: [$d]" >&2
    return 1
  fi
  if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "FATAL: mktemp -d が空でない既存ディレクトリを返しました: [$d]" >&2
    return 1
  fi
  printf '%s' "$d"
}

# 全5ファイルをVAULT配下に作る（メイン相当のfixture）。2026-09-05 §9.3 P3
# 段階4対応: `Preferences/profile.md`・`Preferences/coding-delegation.md` を
# 必読から外した（コアへの移送完了・配布済み）bootstrap-vault.shのFILES配列と
# 同じ構成にする。
make_full_vault() {
  local vault="$1"
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

# run_bootstrap <vault> [reads_log] [recall_log] [inv_log_dir] [last_run_file] [plist] [observation_file] [session_json] —
# bootstrap-vault.sh を実行し additionalContext を返す（単独セッション相当＝agent_type 無し・チーム未所属）。
# ログ・棚卸し・last-run.json・plist は既定で存在しないパス＝実機の $HOME/.claude/logs/*・$HOME/Library に依存しない。
# 観測記録（HEALTH_OBSERVATION_FILE）は既定で呼び出しごとの一時ディレクトリ（実機の $HOME/.claude/logs/health に書かない）。
# BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 固定（実機の profile.md を読まない。P1 機構は run_bootstrap_with_profile() で検証）。
# ⚠️ 既定が実ファイルの env 6 本（設計 v1.2 §10.1）をすべて渡す。新規ケースはこのヘルパを経由する（直接起動を書かない）。
RUN_BOOTSTRAP_DEFAULT_SESSION_JSON='{"session_id":"test-session-0000"}'
run_bootstrap() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local inv_log_dir="${4:-/nonexistent-dir/vault-inventory}"
  local last_run_file="${5:-/nonexistent-dir/last-run.json}"
  local plist="${6:-/nonexistent-dir/com.takumi009.maintenance.plist}"
  local obs_file="${7:-}"
  local session_json="${8:-$RUN_BOOTSTRAP_DEFAULT_SESSION_JSON}"
  local obs_tmp=""
  if [ -z "$obs_file" ]; then
    obs_tmp="$(mktemp -d)"
    obs_file="$obs_tmp/session-observation.json"
  fi
  printf '%s\n' "$session_json" \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      MAINTENANCE_LAST_RUN_FILE="$last_run_file" \
      MAINTENANCE_PLIST_FILE="$plist" HEALTH_OBSERVATION_FILE="$obs_file" \
      HEALTH_JUDGE_NOW="${HEALTH_JUDGE_NOW:-}" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
  [ -n "$obs_tmp" ] && rm -rf "$obs_tmp"
  return 0
}

# 2026-09-08 モデル定義ファイルと候補指定対応: 役割の行がmodel=<定義名>だけに
# なったため、resolve()を通すfixtureは全てモデル定義ファイルを要る。1つの
# 共有ファイル（読取専用・書き換えない）を全テスト共通で使う。個別に別の
# 定義ファイルが要るケース（不在・壊れている等）だけローカルに上書きする。
SHARED_MODELS_CONF="$(mktemp -d)/models.conf"
make_model_defs() {
  # $1=出力先。$2以降を渡すとそれをそのまま書く（不正な定義ファイルを作る
  # 用途）。無指定なら本ファイル全体で使う既定の豊富な定義集合を書く。
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  if [ "$#" -eq 0 ]; then
    cat > "$path" <<'EOF'
[t-opus-high]
provider=anthropic-api
model=claude-opus-5
effort=high

[opus-noeffort]
provider=anthropic-api
model=claude-opus-5

[opus-max]
provider=anthropic-api
model=claude-opus-5
effort=max

[opus46-xhigh]
provider=anthropic-api
model=claude-opus-4.6
effort=xhigh

[fable-1m]
provider=anthropic-api
model=claude-fable-5[1m]

[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5

[sonnet-max]
provider=anthropic-api
model=claude-sonnet-5
effort=max

[bedrock-opus]
provider=bedrock
model=opus

[bedrock-opus-xhigh]
provider=bedrock
model=opus
effort=xhigh

[bedrock-haiku]
provider=bedrock
model=haiku

[bedrock-sonnet]
provider=bedrock
model=sonnet

[mantle-haiku]
provider=bedrock-mantle
model=anthropic.claude-3-haiku

[codex-review]
provider=external
execution=external-cli
model=codex-review-default
effort=high

[codex-other-tool]
provider=external
execution=external-cli
model=other-tool

[ext-api-bad]
provider=external
execution=external-api
model=codex-review-default

[codex-review-minimal]
provider=external
execution=external-cli
model=codex-review-default
effort=minimal
EOF
  else
    : > "$path"
    for block in "$@"; do printf '%s\n' "$block" >> "$path"; done
  fi
}
make_model_defs "$SHARED_MODELS_CONF"
# ⚠️ 個別のケースがAIENV_MODEL_DEFS_FILEを上書きしない限り、この既定値
# （読取専用・全ケース共通の豊富な定義集合）を使う。値を書き換えるケースは
# 無いので、ファイル冒頭の1回exportが他ケースへ誤って漏れる心配は無い
# （モデル定義ファイルと候補指定-設計-2026-09-08.md §11.1の注記は「ケースごとに
# 異なる値が要る」場合の注意であり、本ファイルでは1つの正しい値を全ケースが
# 共有できるためこの形にした）。
export AIENV_MODEL_DEFS_FILE="$SHARED_MODELS_CONF"

# run_bootstrap_with_profile <vault> <profile_path> [models_conf] — P1 機構（ローカル実体プロファイル）
# のテスト専用ヘルパー。BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 を明示して実行する。
# 判定時刻はテスト専用 env HEALTH_JUDGE_NOW で固定する（2 回の本文を diff するケース＝76・78 が judged_at の
# 秒差で汚れないため。F-19＝この env を export するのは test ヘルパだけ）。
run_bootstrap_with_profile() {
  local vault="$1" profile_path="$2"
  local models_conf="${3:-$SHARED_MODELS_CONF}"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
      HEALTH_OBSERVATION_FILE="/nonexistent-dir/health/session-observation.json" \
      HEALTH_JUDGE_NOW="${HEALTH_JUDGE_NOW:-2026-09-15T06:01:01Z}" \
      AIENV_MODEL_DEFS_FILE="$models_conf" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# run_bootstrap_health4 <vault> <machine_role_line> [legacy_marker_content] [inv_dir] —
# 外部脳ヘルス行④の機役割判定（配役表の能力軸`machine_role`由来）を検証する
# 専用ヘルパー（配役表-能力軸整理-設計-2026-09-07.md §10.1・FX-M1/FX-M2）。
# fake HOME配下に有効なschema 5の実体を置き、HOMEを切り替えてbootstrap-
# vault.shを実行する。legacy_marker_content（省略可）を渡すと同じfake HOME
# 配下の本番と同じ場所（$HOME/.config/takumi009-ai-env/配下・廃止済みの
# 旧マーカーファイル名）へ旧マーカーを併設する（本番と同じ場所に置いても
# 読まれないことの証明＝FX-M1）。MAINTENANCE_LAST_RUN_FILEは既定で不在固定
# （FX-M1/FX-M2はmachine_role以外の環境をすべて揃える＝両方とも不在で
# 統一する）。
run_bootstrap_health4() {
  local vault="$1" machine_role_line="$2" legacy_marker="${3:-}"
  local inv_dir="${4:-/nonexistent-dir/vault-inventory}"
  local fake_home profile_path
  fake_home="$(mktemp -d)"
  profile_path="$fake_home/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$profile_path")"
  {
    echo "---"
    echo "schema_version: 7"
    echo "profile_slug: authoring"
    echo "team_mode:        configured value=full"
    echo "no_read_paths:    unavailable"
    echo "machine_role:     ${machine_role_line}"
    echo "role.leader: configured model=t-opus-high"
    echo "---"
  } > "$profile_path"
  if [ -n "$legacy_marker" ]; then
    printf '%s\n' "$legacy_marker" > "$fake_home/.config/takumi009-ai-env/machine-role"  # AC5-ALLOW:FX-M1
  fi
  echo '{"session_id":"test-session-0000"}' \
    | HOME="$fake_home" BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="$inv_dir" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
      HEALTH_OBSERVATION_FILE="$fake_home/.claude/logs/health/session-observation.json" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
  rm -rf "$fake_home"
}

# 「壊れていない」schema 7のprofile.mdを作る（2026-09-08 モデル定義ファイルと
# 候補指定対応: role.leaderまで含めて完全にOKへ解決できる最小の実体。旧版は
# 能力軸3キーだけの自由値v1形式だったが、schema 7のコードは7未満（版なし
# 含む）を一律T4-LEGACYで解決失敗にするため、role.leader込みの完全な実体に
# 差し替えた＝§4.1・§4.2。整理前の中間状態の経緯はgit履歴を参照）。
make_ok_profile() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader:      configured model=t-opus-high
---
EOF
}

# agent_type付き（ワーカー扱い）でbootstrap-vault.shを実行する。
run_bootstrap_worker() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local inv_log_dir="${4:-/nonexistent-dir/vault-inventory}"
  local last_run_file="${5:-/nonexistent-dir/last-run.json}"
  local obs_file="${6:-/nonexistent-dir/health/session-observation.json}"
  echo '{"session_id":"test-session-worker","agent_type":"worker"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      MAINTENANCE_LAST_RUN_FILE="$last_run_file" \
      MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
      HEALTH_OBSERVATION_FILE="$obs_file" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# N日前のISO8601 UTC時刻（実際のフックと同じく `date -u` で書く。
# tests/test-check-drift.sh の d_ts と同じ考え方＝2026-07-10 敵対的レビュー
# 2回目 N-5 対応でローカルTZとの取り違えを防ぐ）。
d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"d +%Y-%m-%dT%H:%M:%SZ; }

echo "=== 1. メイン相当: 5ファイル全部存在 → 5ファイル全部が必読リストに載る（2026-09-05 §9.3 P3段階4後の構成） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "5ファイルを読む、の文言" "$ctx" "（5ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "Preferences/core-conduct.md が列挙される" "$ctx" "Preferences/core-conduct.md"
  assert_contains "Preferences/core-workflow.md が列挙される" "$ctx" "Preferences/core-workflow.md"
  assert_not_contains "Knowledge/mistakes.md はもう必読に含まれない（P2除去対象）" "$ctx" "Knowledge/mistakes.md"
  assert_not_contains "Preferences/profile.md はもう必読に含まれない（P3除去対象）" "$ctx" "Preferences/profile.md"
  assert_not_contains "Preferences/coding-delegation.md はもう必読に含まれない（P3除去対象）" "$ctx" "Preferences/coding-delegation.md"
  assert_contains "Personal/profile-personal.md が列挙される" "$ctx" "Personal/profile-personal.md"
  assert_not_contains "「見つかりません」という古い文言は出ない" "$ctx" "見つかりません"
  assert_not_contains "private ノート対象外の注記は出ない（メインでは全部揃うため）" "$ctx" "private ノートはこのマシンには無い"

  rm -rf "$VAULT_DIR"
}

echo "=== 2. サブ相当: private系1ファイル欠如 → 4ファイルのみ列挙+対象外の注記（core-conduct/core-workflowはPreferences配下＝サブにも届く前提） ==="
{
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Preferences"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Personal/profile-personal.md だけが無い（サブ想定＝private層の意図的欠落）

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "4ファイルを読む、の文言" "$ctx" "（4ファイルを1回の並列 Read で同時取得すること）"
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
  # 「private対象外」は1件のみ。残り4件（Preferences配下の必須publicノート）は
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
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$VAULT_DIR/$f"
  done
  # Preferences/core-conduct.md だけを欠落させる（移送失敗・sync漏れ等を模す）。

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_contains "4ファイルを読む、の文言" "$ctx" "（4ファイルを1回の並列 Read で同時取得すること）"
  assert_contains "想定外欠落の警告にcore-conduct.mdのフルパスが出る" "$ctx" "Preferences/core-conduct.md"
  assert_contains "想定外欠落の警告文言が出る" "$ctx" "必読のはずのpublicノートが見つかりません"
  assert_not_contains "core-conduct.mdの欠落は「privateノート対象外」には数えられない（profile-personal.mdは存在するため当該注記自体が出ない）" "$ctx" "private ノートはこのマシンには無い"

  rm -rf "$VAULT_DIR"
}

# ============================================================================
# 4〜8: 外部脳ヘルス（案件 health-self-explain・設計 v1.2 §5・§10.2）。
# bootstrap は ①観測記録 → ②判定機（lib/health_judge.py）→ ③描画 の 3 段。段階の判定は判定機 1 か所
# （tests/test-health-judge.sh が 23 本を閉じる）。ここでは「判定機の写し」であること（描画・観測・fail-open）を検査する。
# 旧判定（8 日線・「N 日成功していません」・「前回の週次メンテ結果」・「フック死の疑い」）の検査は退役。
# ============================================================================
HEALTH_FX_ROOT="$TESTS_DIR/fixtures/health"
CMUX_NEXT_MODEL="$REPO_ROOT/cmux/cmux-next-model.sh"
HEALTH_SHARED_VAULT="$(mktemp -d)"
make_full_vault "$HEALTH_SHARED_VAULT"
HEALTH_EMPTY_PROJECTS="$(mktemp -d)"
mkdir -p "$HEALTH_EMPTY_PROJECTS/Projects"

# fixture_vault_dir <fixture dir> — fixture の vault/ があればそれ、observation.json が「ルート不在」なら存在しないパス、
# それ以外は共有の完全な Vault（fixtures/health/README.md の規則）。
fixture_vault_dir() {
  local d="$1"
  if [ -d "$d/vault" ]; then
    printf '%s' "$d/vault"
  elif [ "$(jq -r '.load.vault_root_readable' "$d/observation.json" 2>/dev/null)" = "false" ]; then
    printf '%s' "/nonexistent-dir/vault"
  else
    printf '%s' "$HEALTH_SHARED_VAULT"
  fi
}

# run_bootstrap_fixture <fixture名> [session_json] — fixture の入力を全部向けて bootstrap を回し additionalContext を返す。
# 観測記録＝fixture の observation-prev.json を一時ファイルへ写して HEALTH_OBSERVATION_FILE に渡す（bootstrap が上書きする）。
# 書かれた観測記録は $BOOT_OBS_FILE に残す（呼び出し側が検査してから消す）。HEALTH_JUDGE_NOW＝fixture の now。
HEALTH_FIXTURE_SESSION_JSON='{"session_id":"sess-cur-0002","source":"startup"}'
HEALTH_OBS_WORK="$(mktemp -d)"
BOOT_OBS_FILE="$HEALTH_OBS_WORK/session-observation.json"
run_bootstrap_fixture() {
  local fx="$1" session_json="${2:-$HEALTH_FIXTURE_SESSION_JSON}"
  local d="$HEALTH_FX_ROOT/$fx" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  rm -f "$BOOT_OBS_FILE"
  [ -f "$d/observation-prev.json" ] && cp "$d/observation-prev.json" "$BOOT_OBS_FILE"
  HEALTH_JUDGE_NOW="$(cat "$d/now")" \
    run_bootstrap "$(fixture_vault_dir "$d")" "$d/vault-reads.tsv" "$d/vault-recall.tsv" "$d" "$d/last-run.json" \
      "$plist" "$BOOT_OBS_FILE" "$session_json"
}

# run_dock_fixture <fixture名> — cmux-next-model.sh --frame を fixture の入力（判定機の入力 4 本＋plist）で回す。
# 既定が実ファイルの env 5 本をすべて fixture／存在しないパスへ向ける（設計 §10.1）。
run_dock_fixture() {
  local fx="$1" d="$HEALTH_FX_ROOT/$fx" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  CMUX_NEXT_VAULT="$HEALTH_EMPTY_PROJECTS" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
    CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="$plist" \
    HEALTH_JUDGE_NOW="$(cat "$d/now")" bash "$CMUX_NEXT_MODEL" --frame 2>/dev/null
}

# health_section <ctx> — ヘルス節（【外部脳ヘルス】の行から、続く「- [」項目行・⚠️ 行まで）だけを取り出す。
health_section() {
  printf '%s\n' "$1" | awk '/^【外部脳ヘルス】/{flag=1; print; next} flag && (/^- \[/ || /^⚠️ 観測記録/){print; next} flag{exit}'
}
health_header() { printf '%s\n' "$1" | grep '^【外部脳ヘルス】' | head -1; }

echo "=== 4. ok_health_section_is_one_line（NFR-3・AC-4）: S-1＝ヘルス節は全体で 1 行・stage=OK items=0・⚠️ を含まない ==="
{
  ctx="$(run_bootstrap_fixture S-1)"
  sec="$(health_section "$ctx")"
  assert_eq "S-1: ヘルス節が 1 行" "1" "$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
  assert_contains "S-1: stage=OK items=0" "$sec" "stage=OK items=0"
  assert_not_contains "S-1: ⚠️ を含まない（FR-5）" "$sec" "⚠️"
  s1_run_id="$(jq -r '.completed.run_id' "$HEALTH_FX_ROOT/S-1/last-run.json")"; s1_streak="$(jq -r '.success_streak' "$HEALTH_FX_ROOT/S-1/last-run.json")"
  assert_contains "S-1: 週次の状態（completed・run_id・trigger・streak）" "$sec" "maintenance=completed(${s1_run_id}, trigger=scheduled, streak=${s1_streak}, info=0)"
  s1_report_path="$(jq -r '.report_path' "$HEALTH_FX_ROOT/S-1/latest.json")"
  assert_contains "S-1: 棚卸し 0 件と report_path" "$sec" "inventory=0(2026-09-15, ${s1_report_path})"
  assert_contains "S-1: load=ok recall=observed(injected=true)" "$sec" "load=ok recall=observed(injected=true)"
  assert_not_contains "S-1: 旧見出し（check-drift ⑥ の簡易版）は退役" "$ctx" "簡易版"
  assert_not_contains "S-1: 旧文言「動いていません」は退役" "$ctx" "動いていません"
  assert_contains "S-1: 本文は健在" "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"
}

echo "=== 4b. fragments_candidates_not_injected: S-1 は候補 12 件だが AI へは注入しない（現行契約・SO-8） ==="
{
  ctx="$(run_bootstrap_fixture S-1)"
  assert_not_contains "S-1: 「候補」を注入しない" "$ctx" "候補"
  assert_not_contains "S-1: fragments_candidates を注入しない" "$ctx" "fragments_candidates"
}

echo "=== 5. render_item_keys_fixed（AC-1）: S-2＝項目行ちょうど 1 行・固定キーの並び・result=失敗・actor=AI・ack=該当なし ==="
{
  ctx="$(run_bootstrap_fixture S-2)"
  sec="$(health_section "$ctx")"
  items="$(printf '%s\n' "$sec" | grep '^- \[')"
  assert_eq "S-2: 項目行が 1 行" "1" "$(printf '%s\n' "$items" | grep -c '^- \[')"
  assert_contains "S-2: ヘッダ stage=WARNING items=1" "$(health_header "$ctx")" "stage=WARNING items=1"
  # V-17 差し替え後、S-2 の実際の工程・log_ref は実生成物（phase1-inventory・temp パス）に変わる
  # （設計 §10.1「run_dir／log_ref は temp の絶対パス（fixture では任意に置換してよい）」）。
  # 固定キーの並び自体（順序）はワイルドカードで検査し、step 名・log の逐語一致は別に検査する。
  expected_re='^- \[1\] source=週次メンテ severity=WARNING step=.+ result=失敗 actor=AI reason=「[^」]+」 ok_when=「[^」]+」 ack=該当なし log=.+$'
  assert_eq "S-2: 固定キーの並び（source severity step result actor reason ok_when ack log）" "1" \
    "$(printf '%s\n' "$items" | grep -Ec "$expected_re")"
  assert_contains "S-2: step 名が逐語（V-17 差し替え後の実物）" "$items" "step=$(jq -r '.completed.steps[0].name' "$HEALTH_FX_ROOT/S-2/last-run.json")"
  assert_contains "S-2: log が逐語（V-17 差し替え後の実物）" "$items" "log=$(jq -r '.completed.steps[0].log_ref' "$HEALTH_FX_ROOT/S-2/last-run.json")"
  assert_contains "S-2: 理由 X が逐語" "$items" "$(jq -r '.completed.steps[0].reason' "$HEALTH_FX_ROOT/S-2/last-run.json")"
  assert_contains "S-2: ③ OK に戻る条件" "$items" "ok_when=「次回の本番経路の実行（定期起動または scripts/maintenance-kick.sh）が完全正常終了する」"
  assert_not_contains "S-2: 項目行に stage= は無い（V-5）" "$items" "stage="
}

echo "=== 5b. S-3（AC-2）: 2 行・理由の合計 >200 文字が両方とも逐語（切り詰め 0）・警告/失敗・本人/AI ==="
{
  ctx="$(run_bootstrap_fixture S-3)"
  items="$(health_section "$ctx" | grep '^- \[')"
  assert_eq "S-3: 項目行が 2 行" "2" "$(printf '%s\n' "$items" | grep -c '^- \[')"
  assert_contains "S-3: [1] drift の理由が逐語" "$items" "reason=「$(jq -r '.completed.steps[0].reason' "$HEALTH_FX_ROOT/S-3/last-run.json")」"
  assert_contains "S-3: [2] 理由 X が逐語" "$items" "reason=「$(jq -r '.completed.steps[1].reason' "$HEALTH_FX_ROOT/S-3/last-run.json")」"
  assert_contains "S-3: [1] result=警告 actor=本人" "$items" "result=警告 actor=本人"
  assert_contains "S-3: [2] result=失敗 actor=AI" "$items" "result=失敗 actor=AI"
}

echo "=== 5c. 4 状態の明示（AC-3）: S-4＝interrupted・S-5＝broken・S-21＝未起動（前回の完了結果として出ない） ==="
{
  ctx="$(run_bootstrap_fixture S-4)"
  assert_contains "S-4: ヘッダ maintenance=interrupted(開始 …)" "$(health_header "$ctx")" "maintenance=interrupted(開始 2026-09-15T06:00:01Z)"
  assert_contains "S-4: 項目 result=中断・開始したが完了記録が無い" "$ctx" "result=中断 actor=AI reason=「開始したが完了記録が無い"
  assert_not_contains "S-4: 前回の理由 X は出ない" "$ctx" "理由X"
  ctx="$(run_bootstrap_fixture S-5)"
  assert_contains "S-5: ヘッダ maintenance=broken(" "$(health_header "$ctx")" "maintenance=broken("
  assert_contains "S-5: 項目 result=破損" "$ctx" "result=破損 actor=AI"
  ctx="$(run_bootstrap_fixture S-21)"
  assert_contains "S-21: 項目 result=未起動・予定時刻を過ぎて開始していない" "$ctx" "result=未起動 actor=AI reason=「予定時刻を過ぎて開始していない"
  assert_eq "S-21: 項目行 1 行" "1" "$(health_section "$ctx" | grep -c '^- \[')"
}

echo "=== 5d. 棚卸し・読込・想起の項目行の固定キー（S-8・S-15・S-19）と ack の描画（S-11・S-7） ==="
{
  ctx="$(run_bootstrap_fixture S-8)"
  items="$(health_section "$ctx" | grep '^- \[')"
  assert_eq "S-8: 棚卸し 2 行（kind target detail actor ok_when ack log）" "2" \
    "$(printf '%s\n' "$items" | grep -Ec '^- \[[12]\] source=棚卸し severity=WARNING kind=[a-z_]+ target=[^ ]+ detail=「[^」]+」 actor=(AI|本人) ok_when=「[^」]+」 ack=該当なし log=[^ ]+$')"
  s8_report_path="$(jq -r '.report_path' "$HEALTH_FX_ROOT/S-8/latest.json")"
  assert_eq "S-8: log が report_path と逐語一致（2 行とも）" "2" \
    "$(printf '%s\n' "$items" | grep -Fc "log=${s8_report_path}")"
  assert_contains "S-8: date_drift は AI" "$items" "kind=date_drift target=Knowledge/x.md detail=「frontmatter updated: 2026-08-01 ＜ 本文最新: 2026-09-10」 actor=AI"
  assert_contains "S-8: 表に無い kind は本人" "$items" "kind=owner_decision target=Projects/y.md"
  assert_not_contains "S-8: 要観察は現れない" "$items" "unread_pending"
  assert_contains "S-8: ヘッダ inventory=2(" "$(health_header "$ctx")" "inventory=2(2026-09-15, "
  ctx="$(run_bootstrap_fixture S-15)"
  assert_eq "S-15: 読込 1 行（target result actor ok_when ack log=該当なし）" "1" \
    "$(health_section "$ctx" | grep -Ec '^- \[1\] source=読込 severity=ERROR target=Preferences/core-conduct\.md result=[^ ]+ actor=AI ok_when=「[^」]+」 ack=該当なし log=該当なし$')"
  assert_contains "S-15: ヘッダ stage=ERROR … load=missing(1)" "$(health_header "$ctx")" "load=missing(1)"
  assert_contains "S-15: 必読リスト側の想定外欠落の警告も従来どおり" "$ctx" "必読のはずのpublicノートが見つかりません"
  ctx="$(run_bootstrap_fixture S-19)"
  assert_eq "S-19: 想起 1 行（result actor ok_when ack log）" "1" \
    "$(health_section "$ctx" | grep -Ec '^- \[1\] source=想起 severity=ERROR result=前セッション（sess-prev-0001）で注入なし（直接観測） actor=AI ok_when=「[^」]+」 ack=該当なし log=該当なし$')"
  assert_contains "S-19: ヘッダ recall=observed(injected=false)" "$(health_header "$ctx")" "recall=observed(injected=false)"
  ctx="$(run_bootstrap_fixture S-11)"
  ack_at="$(jq -r '.ack.at' "$HEALTH_FX_ROOT/S-11/last-run.json")"; ack_note="$(jq -r '.ack.note' "$HEALTH_FX_ROOT/S-11/last-run.json")"
  assert_contains "S-11: ack=対処済み・次回判定待ち（at: note）" "$ctx" "ack=対処済み・次回判定待ち（${ack_at}: ${ack_note}）"
  assert_contains "S-11: stage=WARNING のまま" "$(health_header "$ctx")" "stage=WARNING"
  ctx="$(run_bootstrap_fixture S-7)"
  ack_at="$(jq -r '.ack.at' "$HEALTH_FX_ROOT/S-7/last-run.json")"; ack_note="$(jq -r '.ack.note' "$HEALTH_FX_ROOT/S-7/last-run.json")"
  assert_contains "S-7: ack=申告後に再失敗（at: note）" "$ctx" "ack=申告後に再失敗（${ack_at}: ${ack_note}）"
  ctx="$(run_bootstrap_fixture S-16)"
  assert_eq "S-16（AC-20）: severity=ERROR の項目行がちょうど 1 行" "1" "$(health_section "$ctx" | grep -c 'severity=ERROR')"
  assert_eq "S-16: 項目行 2 行（週次 1・読込 1）" "2" "$(health_section "$ctx" | grep -c '^- \[')"
}

echo "=== 6. stage_unique_and_equal_to_dock（AC-12）: S-1〜S-23 全件で stage= がヘッダに 1 回・Dock の B 行と一致 ==="
{
  n_fx=0
  for d in "$HEALTH_FX_ROOT"/S-*; do
    fx="$(basename "$d")"
    n_fx=$((n_fx + 1))
    ctx="$(run_bootstrap_fixture "$fx")"
    frame="$(run_dock_fixture "$fx")"
    assert_eq "AC-12 $fx: stage= がちょうど 1 回" "1" "$(grep -c 'stage=' <<<"$ctx")"
    assert_eq "AC-12 $fx: 注入の stage と B 行の段階が一致" \
      "$(grep -o 'stage=[A-Z]*' <<<"$ctx" | cut -d= -f2)" \
      "$(awk -F'\t' '$1=="B"{print $4}' <<<"$frame" | sed 's/ 候補[0-9]*件$//')"
    assert_eq "AC-12 $fx: ヘッダの items= と項目行数が一致" \
      "$(grep -o 'items=[0-9]*' <<<"$ctx" | head -1 | cut -d= -f2)" \
      "$(health_section "$ctx" | grep -c '^- \[')"
    # bootstrap が書いた観測記録の load・recall_prev が fixture の observation.json（期待値）と一致（設計 §10.1）
    assert_eq "AC-12 $fx: 観測記録の load が期待値と一致" \
      "$(jq -c '.load' "$d/observation.json")" "$(jq -c '.load' "$BOOT_OBS_FILE" 2>/dev/null)"
    assert_eq "AC-12 $fx: 観測記録の recall_prev が期待値と一致" \
      "$(jq -c '.recall_prev' "$d/observation.json")" "$(jq -c '.recall_prev' "$BOOT_OBS_FILE" 2>/dev/null)"
  done
  assert_eq "AC-12: S-* は 23 本" "23" "$n_fx"
}

echo "=== 7. observer_writes_injected_false_when_reads_but_no_recall（AC-22 恒・D-6）: 前セッションは reads あり・recall 0 行 → injected=false・ERROR ==="
{
  ctx="$(run_bootstrap_fixture S-19)"
  assert_eq "観測記録: schema" "health-observation/1" "$(jq -r '.schema' "$BOOT_OBS_FILE")"
  assert_eq "観測記録: session_id=今回・source=startup" "sess-cur-0002 startup" "$(jq -r '"\(.session_id) \(.source)"' "$BOOT_OBS_FILE")"
  assert_eq "観測記録: recall_prev.session_id=前セッション" "sess-prev-0001" "$(jq -r '.recall_prev.session_id' "$BOOT_OBS_FILE")"
  assert_eq "観測記録: reads_rows=3 recall_valid_rows=0 recall_error_rows=0 injected=false" "3 0 0 false" \
    "$(jq -r '.recall_prev | "\(.reads_rows) \(.recall_valid_rows) \(.recall_error_rows) \(.injected)"' "$BOOT_OBS_FILE")"
  assert_contains "注入: stage=ERROR" "$(health_header "$ctx")" "stage=ERROR"
  assert_contains "注入: 想起の項目" "$ctx" "source=想起 severity=ERROR"
}

echo "=== 7b. observer_prev_session_is_last_writer（F-18・V-11）: 前セッション＝最後に観測記録を書いたセッション（自分自身・並行も定義どおり） ==="
{
  LOGDIR="$(mktemp -d)"
  OBS="$(mktemp -d)/session-observation.json"
  printf '%s\tsess-A\tPreferences/absolute-rules.md\n%s\tsess-B\tPreferences/absolute-rules.md\n' "$(d_ts -1)" "$(d_ts -1)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsess-A\tKnowledge/x.md\tk\n%s\tERROR\t\tsess-B\tboom\n' "$(d_ts -1)" "$(d_ts -1)" > "$LOGDIR/vault-recall.tsv"
  # (1) 観測記録なし → 前セッション null・injected null
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "" "" "" "$OBS" '{"session_id":"sess-A","source":"startup"}')"
  assert_eq "(1) 前回なし: recall_prev.session_id=null・injected=null" "null null" "$(jq -r '"\(.recall_prev.session_id) \(.recall_prev.injected)"' "$OBS")"
  assert_contains "(1) ヘッダ recall=observed(injected=null)" "$(health_header "$ctx")" "recall=observed(injected=null)"
  # (2) sess-B が起動 → 前セッション＝sess-A（reads 1・recall 有効 1 → injected=true）
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "" "" "" "$OBS" '{"session_id":"sess-B","source":"startup"}')"
  assert_eq "(2) 前セッション=sess-A・injected=true" "sess-A true" "$(jq -r '"\(.recall_prev.session_id) \(.recall_prev.injected)"' "$OBS")"
  # (3) sess-B が compact で再び起動 → 前セッション＝自分自身 sess-B（reads 1・有効 0・ERROR 行 1 → injected=false）
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "" "" "" "$OBS" '{"session_id":"sess-B","source":"compact"}')"
  assert_eq "(3) 前セッション=自分自身 sess-B・source=compact" "sess-B compact" "$(jq -r '"\(.recall_prev.session_id) \(.source)"' "$OBS")"
  assert_eq "(3) reads 1・有効 0・ERROR 1 → injected=false" "1 0 1 false" \
    "$(jq -r '.recall_prev | "\(.reads_rows) \(.recall_valid_rows) \(.recall_error_rows) \(.injected)"' "$OBS")"
  assert_contains "(3) 注入は ERROR（想起）" "$(health_header "$ctx")" "stage=ERROR"
  # (4) 前セッションに reads が無い → injected=null（F-17 の縮退）
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "/nonexistent-dir/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "" "" "" "$OBS" '{"session_id":"sess-C","source":"startup"}')"
  assert_eq "(4) reads ログ不在 → injected=null" "null" "$(jq -r '.recall_prev.injected' "$OBS")"
  assert_eq "(4) 観測記録の required は LOCAL_ONLY を除く 4 件・missing 0" "4 0" "$(jq -r '"\(.load.required | length) \(.load.missing | length)"' "$OBS")"
  rm -rf "$LOGDIR" "$(dirname "$OBS")"
}

echo "=== 7c. 観測記録は毎回上書き（今回の観測で判定）・Vault ルート不在＝vault_root_readable=false・missing に必読 4 件 ==="
{
  ctx="$(run_bootstrap_fixture S-18)"
  assert_eq "S-18: vault_root_readable=false・missing 4 件" "false 4" "$(jq -r '"\(.load.vault_root_readable) \(.load.missing | length)"' "$BOOT_OBS_FILE")"
  assert_contains "S-18: ヘッダ load=root_unreadable" "$(health_header "$ctx")" "load=root_unreadable"
  assert_eq "S-18: 項目は 1 行（ノートごとに数えない）" "1" "$(health_section "$ctx" | grep -c '^- \[')"
}

echo "=== 7d. X1b_skipped_header_marks_prev_completed／X5_running_header_marks_prev_completed（W-3・§14-6）: 「前回」明示 ==="
{
  ctx="$(run_bootstrap_fixture X-1b)"
  assert_contains "X-1b: ヘッダが skipped(busy:lock・前回 <completed.run_id> の完了記録)" "$(health_header "$ctx")" \
    "maintenance=skipped(busy:lock・前回 2026-09-08/150001-1111 の完了記録)"
  assert_contains "X-1b: stage=OK items=0（手動の busy-skip は加算しない）" "$(health_header "$ctx")" "stage=OK items=0"
  ctx="$(run_bootstrap_fixture X-5)"
  assert_contains "X-5: ヘッダが running(開始 …・以下の週次メンテ項目は前回 <completed.run_id> の完了記録)" "$(health_header "$ctx")" \
    "maintenance=running(開始 2026-09-15T06:00:01Z・以下の週次メンテ項目は前回 2026-09-08/150001-1111 の完了記録)"
  assert_eq "X-5: 項目は前回の fail 1 行" "1" "$(health_section "$ctx" | grep -c '^- \[1\] source=週次メンテ severity=WARNING step=Phase1② fragments_log result=失敗')"
  assert_contains "X-5: stage=WARNING items=1" "$(health_header "$ctx")" "stage=WARNING items=1"
  ctx="$(run_bootstrap_fixture X-1)"
  assert_contains "X-1: 定期の busy-skip は未起動 1 件" "$ctx" "result=未起動 actor=AI reason=「当該予定の起動が実行なしに終わった（busy-skip: busy:lock"
}

echo "=== 7e. health_judge_now_passed_as_now（V-8(a)・F-19）: HEALTH_JUDGE_NOW が --now に写る＝judged_at と now=injected。未設定なら now=injected 無し ==="
{
  ctx="$(run_bootstrap_fixture S-1)"
  assert_contains "HEALTH_JUDGE_NOW あり: judged_at が fixture の now" "$(health_header "$ctx")" "judged_at=$(cat "$HEALTH_FX_ROOT/S-1/now")"
  assert_contains "HEALTH_JUDGE_NOW あり: ヘッダ末尾に now=injected" "$(health_header "$ctx")" " now=injected"
  ctx="$(HEALTH_JUDGE_NOW="" run_bootstrap "$HEALTH_SHARED_VAULT")"
  assert_not_contains "HEALTH_JUDGE_NOW 無し: now=injected が出ない" "$ctx" "now=injected"
  assert_contains "HEALTH_JUDGE_NOW 無し: 不在＝OK（サブ機初回・F-7）" "$(health_header "$ctx")" "stage=OK items=0"
  assert_contains "HEALTH_JUDGE_NOW 無し: maintenance=absent" "$(health_header "$ctx")" "maintenance=absent"
}

echo "=== 8. judge_missing_prints_unavailable_line（F-10・NFR-2）: 判定機不在／python3 失敗＝固定 1 行「判定不能」・段階を出さない・本文は止めない ==="
{
  ctx="$(HEALTH_JUDGE_LIB=/nonexistent-dir/health_judge.py run_bootstrap "$HEALTH_SHARED_VAULT")"
  assert_eq "判定機不在: 固定 1 行" "1" "$(printf '%s\n' "$ctx" | grep -c '^【外部脳ヘルス】判定不能（health_judge.py: ')"
  assert_not_contains "判定機不在: stage= を出さない" "$ctx" "stage="
  assert_contains "判定機不在: 本文は健在" "$ctx" "① タスクに着手する前に"
  STUB_PY="$(mktemp -d)"
  printf '#!/bin/bash\nexit 3\n' > "$STUB_PY/python3"; chmod +x "$STUB_PY/python3"
  ctx="$(PATH="$STUB_PY:$PATH" run_bootstrap "$HEALTH_SHARED_VAULT")"
  assert_contains "python3 が非 0: 判定不能（終了コード 3）" "$ctx" "【外部脳ヘルス】判定不能（health_judge.py: 判定機が終了コード 3 で失敗）"
  assert_not_contains "python3 が非 0: stage= を出さない" "$ctx" "stage="
  rm -rf "$STUB_PY"
}

echo "=== 8b. observation_write_failure_warns（F-9）: 観測記録が書けなくても判定は続き、ヘルス節末尾に ⚠️ 1 行 ==="
{
  RO="$(mktemp -d)"
  : > "$RO/not-a-dir"
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "" "" "$HEALTH_FX_ROOT/S-2" "$HEALTH_FX_ROOT/S-2/last-run.json" "" "$RO/not-a-dir/session-observation.json")"
  assert_contains "F-9: ⚠️ 観測記録の保存に失敗" "$(health_section "$ctx")" "⚠️ 観測記録の保存に失敗（Dock と食い違う可能性"
  assert_contains "F-9: 判定は続く（stage=WARNING・S-2 の 1 件）" "$(health_header "$ctx")" "stage=WARNING items=1"
  assert_contains "F-9: 今回の観測で判定（load=ok）" "$(health_header "$ctx")" "load=ok"
  rm -rf "$RO"
}

echo "=== 8c. extras_reads_log_stale_outside_health_section（F-17・SO-8）: vault-reads.tsv の 7 日超は節の外の ℹ️ 行・段階に影響しない ==="
{
  LOGDIR="$(mktemp -d)"
  printf '%s\tsess-old\tKnowledge/x.md\n' "$(d_ts -8)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsess-old\tKnowledge/x.md\tk\n' "$(d_ts -1)" > "$LOGDIR/vault-recall.tsv"
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv")"
  assert_eq "ℹ️ 行が 1 行" "1" "$(printf '%s\n' "$ctx" | grep -c '^ℹ️ vault-reads.tsv に直近 7 日の有効な記録なし（ヘルス源外・段階に影響しない）')"
  assert_not_contains "ℹ️ 行はヘルス節の中に無い" "$(health_section "$ctx")" "ℹ️"
  assert_contains "段階は OK のまま" "$(health_header "$ctx")" "stage=OK items=0"
  assert_not_contains "旧文言「フック死の疑い」は退役" "$ctx" "フック死の疑い"
  printf '%s\tsess-new\tKnowledge/x.md\n' "$(d_ts -1)" > "$LOGDIR/vault-reads.tsv"
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv")"
  assert_not_contains "直近なら ℹ️ 行なし" "$ctx" "ℹ️ vault-reads.tsv"
  rm -rf "$LOGDIR"
}

echo "=== 8d. items_do_not_use_last_result_summary（設計 §13・静的）: 項目生成経路に last_result_summary の参照が無い ==="
{
  assert_eq "bootstrap-vault.sh: last_result_summary の参照 0" "0" "$(grep -c 'last_result_summary' "$SCRIPT")"
  JUDGE_LIB="$REPO_ROOT/claude/hooks/lib/health_judge.py"
  assert_eq "health_judge.py: last_result_summary の参照はちょうど 1 か所" "1" "$(grep -c 'last_result_summary' "$JUDGE_LIB")"
  assert_eq "health_judge.py: その 1 か所は旧形式（legacy）フォールバックの中" "1" \
    "$(awk '/# 旧形式（移行期）/{f=1} /# 以降は新契約/{f=0} f && /last_result_summary/{n++} END{print n+0}' "$JUDGE_LIB")"
  assert_eq "bootstrap-vault.sh: 旧判定の線 MAINTENANCE_STALE_DAYS は退役" "0" "$(grep -c 'MAINTENANCE_STALE_DAYS' "$SCRIPT")"
  assert_eq "bootstrap-vault.sh: machine_role による④スキップは撤去" "0" "$(grep -c 'machine_role" != "sub"' "$SCRIPT")"
}

echo "=== 8e. no_real_home_default_in_tests（設計 §10.1・静的）: 本ファイル内の \$SCRIPT 直接起動に既定が実ファイルの env 6 本がすべて付いている ==="
{
  missing_env_lines="$(python3 - "$TESTS_DIR/test-bootstrap-vault.sh" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
need = ["VAULT_READS_LOG", "VAULT_RECALL_LOG", "VAULT_INVENTORY_LOG_DIR",
        "MAINTENANCE_LAST_RUN_FILE", "MAINTENANCE_PLIST_FILE", "HEALTH_OBSERVATION_FILE"]
bad = []
for i, line in enumerate(lines):
    if '"$SCRIPT"' not in line:
        continue
    s = line.strip()
    # 早期終了モード（BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY）はヘルス節に到達しない＝対象外。
    if s.startswith("#") or "sed -n" in s or "grep" in s or "bash -n" in s or s.startswith("SCRIPT=") \
            or "not in line" in s or "BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY" in s:
        continue
    window = "\n".join(lines[max(0, i - 14): i + 1])
    lacking = [n for n in need if n + "=" not in window]
    if lacking:
        bad.append(f"L{i + 1}: {' '.join(lacking)}")
print("\n".join(bad))
PY
)"
  assert_eq "\$SCRIPT 直接起動で env 6 本を欠く箇所が 0" "" "$missing_env_lines"
  n_direct="$(grep -c '"\$SCRIPT"' "$TESTS_DIR/test-bootstrap-vault.sh")"
  assert_true "\$SCRIPT の直接起動が検査対象に含まれている（陽性の実測 ${n_direct} 箇所）" "$([ "$n_direct" -ge 5 ] && echo 1 || echo 0)"
}

echo "=== 8f. 判定機の入力が壊れていても本文は止めない（NFR-2 fail-open）: latest.json 破損＝週次の整合 1 件・last-run 解析不能＝破損 ==="
{
  INV_DIR="$(mktemp -d)"
  printf 'not json' > "$INV_DIR/latest.json"
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "" "" "$INV_DIR" "$HEALTH_FX_ROOT/S-1/last-run.json")"
  assert_contains "latest.json 破損: phase1-inventory の失敗 1 件（⑥）" "$ctx" "step=Phase1③ vault_inventory（記録の整合） result=失敗 actor=AI"
  assert_contains "latest.json 破損: ヘッダ inventory=none" "$(health_header "$ctx")" "inventory=none"
  assert_contains "本文は健在" "$ctx" "【セッション開始ブートストラップ｜ハーネス強制注入】"
  rm -rf "$INV_DIR"
}

echo "=== 9. ワーカー(agent_type付き)には2026-09-03の軽量版撤去により何も注入されない（is_worker判定自体は健在で即exit 0。共通ルールの正本はagents/*.mdの共通ルール節へ移管済み） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  printf '{"date":"2026-06-01","report_path":"%s/2026-06-01.md","actionable":3}\n' "$INV_DIR" > "$INV_DIR/latest.json"
  LOGDIR="$(mktemp -d)"
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts -8)" > "$LOGDIR/vault-reads.tsv"
  LAST_RUN_DIR="$(mktemp -d)"
  LAST_RUN_FILE="$LAST_RUN_DIR/last-run.json"
  printf '{"started_at": "%s"}' "$(d_ts -10)" > "$LAST_RUN_FILE"

  WORKER_OBS_DIR="$(mktemp -d)"
  ctx="$(run_bootstrap_worker "$VAULT_DIR" "$LOGDIR/vault-reads.tsv" "$LOGDIR/vault-recall.tsv" "$INV_DIR" "$LAST_RUN_FILE" "$WORKER_OBS_DIR/session-observation.json")"
  assert_eq "ワーカー版のadditionalContextは完全に空（軽量版DIRECTIVEを撤去しexit 0のみ）" "" "$ctx"
  assert_not_contains "ワーカー版にはヘルス見出しが出ない" "$ctx" "【外部脳ヘルス】"
  assert_not_contains "ワーカー版には段階も出ない" "$ctx" "stage="
  assert_not_contains "旧軽量版の見出し文言はもう出ない（撤去の回帰確認）" "$ctx" "【チームメイト用ブートストラップ｜軽量版】"
  # 観測記録はワーカーでは書かない（設計 §5 手順 4＝現行の early exit のまま）。
  assert_true "ワーカー版は観測記録を書かない" "$([ ! -e "$WORKER_OBS_DIR/session-observation.json" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$LOGDIR" "$INV_DIR" "$LAST_RUN_DIR" "$WORKER_OBS_DIR"
}

echo "=== 10. P1機構(ローカル実体プロファイル): ゲート無効(BOOTSTRAP_ENABLE_LOCAL_PROFILE=0明示。run_bootstrap()の固定値)では固定パスが必読リストに一切現れない（2026-09-02からコードの既定値は1・§9.0 A-1／rollout-runbook.md現行トラック§7） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_PATH="$(mktemp -d)/profile.md"
  make_ok_profile "$PROFILE_PATH"

  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "ゲート無効では固定パスが必読リストに出ない" "$ctx" "$PROFILE_PATH"
  assert_not_contains "ゲート無効ではローカル実体プロファイル見出しも出ない" "$ctx" "【ローカル実体プロファイル】"

  rm -rf "$VAULT_DIR" "$(dirname "$PROFILE_PATH")"
}

echo "=== 11. FR-10(要件v1.2.1): 有効化しても実体プロファイルの固定パスは必読リストに一切現れない（旧P1受入条件①は撤回。FR-11のモード行セグメントで代替） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_ok_profile "$PROFILE_PATH"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  occurrences="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "固定パスは必読リストに0件（FR-10）" "0" "$occurrences"
  assert_contains "Vault側の必読ファイル(absolute-rules.md)も引き続き現れる" "$ctx" "$VAULT_DIR/Preferences/absolute-rules.md"
  assert_not_contains "壊れていないprofileでは最小能力警告は出ない" "$ctx" "最小能力"
  assert_contains "FR-11: モード行セグメントにschema_version=が含まれる" "$ctx" "schema_version=7"
  assert_contains "FR-11: モード行セグメントにmachine_role=が含まれる" "$ctx" "machine_role=main"
  assert_contains "FR-11: モード行セグメントに照会コマンド(role_candidates.py)が含まれる" "$ctx" "role_candidates.py"

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
  # FR-10差し戻し（検証1巡目MINOR-4・2026-09-17）: 失敗経路（T1）でも必読
  # リストへは一切追加しない（旧仕様は「未作成」の案内1行を必読リストへ
  # 出していた。案内は🧭モード行の「利用不可（T1）」セグメントへ一本化）。
  occurrences_t1="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "T1: 必読リストに実体プロファイルの行が0件" "0" "$occurrences_t1"

  # FR-12（要件v1.2.1）: 不在(T1)は🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（値の再掲は無く区分コードのみ）。
  mode_line_t1="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "T1: モード行に「利用不可」を含む" "$mode_line_t1" "利用不可"
  assert_contains "T1: モード行に「本人確認へ倒す」を含む" "$mode_line_t1" "本人確認へ倒す"
  assert_contains "T1: モード行の区分コードに（T1）を含む" "$mode_line_t1" "（T1）"

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
schema_version: 7
profile_slug: authoring
team_mode: configured value=<fill-in>
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-opus-high
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
  # machine_role キーだけを欠落させる（2026-09-05 P3段階4差し戻し対応でno_read_paths
  # を追加したため、この行にも書いて「欠落は machine_role の1件だけ」という
  # 回帰テストの意図を保つ＝Codex一次レビュー指摘・Minor対応の型を継承）。
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode: configured value=full
no_read_paths: unavailable
role.leader: configured model=t-opus-high
---
EOF

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "T5: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T5: 既存キー欠落の理由が出る" "$ctx" "T5"
  assert_contains "T5: 欠落キー名が出る" "$ctx" "machine_role"

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
team_mode: 本人
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
  # 既知の3キーはすべて揃えたうえで、将来のスキーマ拡張を想定した未知キーを追加する。
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-opus-high
future_new_key: 未来のスキーマが追加した値
---
EOF

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  # 機械側は解決失敗(MINIMAL)ではない＝「を解決できません」という汎用MINIMAL
  # 文言は出ない（既知キー部分は有効という§4a表の区別を保つ）。
  assert_not_contains "T9': 機械側の解決失敗(MINIMAL)ではない" "$ctx" "を解決できません"
  assert_contains "T9': 未知キー名が警告に出る" "$ctx" "future_new_key"
  assert_contains "T9': AI向けには必読除外・最小能力の⚠️警告になる（U-8裁定）" "$ctx" "⚠️ ローカル実体プロファイルに未知のキーがあります"
  assert_contains "T9': 取るべき行動（本人確認へ倒す）が明記される" "$ctx" "本人確認へ倒してください"
  assert_contains "T9': 「プロファイル利用不可＝最小能力」の文言が明示される（リーダー裁定・2026-09-01）" "$ctx" "プロファイル利用不可＝最小能力"
  assert_contains "T9': 「ワーカー起動は本人確認へ倒す」の文言が明示される（リーダー裁定・2026-09-01）" "$ctx" "ワーカー起動は本人確認へ倒してください"
  assert_not_contains "T9': 旧仕様のℹ️文言はもう出ない" "$ctx" "ℹ️ ローカル実体プロファイルに未知のキーがあります"
  assert_not_contains "T9': 全文Readの指示は付かない（必読除外）" "$ctx" "$PROFILE_PATH  （全"
  # FR-10差し戻し（検証1巡目MINOR-4・2026-09-17）: UNKNOWN_EXTRAでも必読
  # リストへは一切追加しない（旧仕様は⚠️の警告文とは別に必読リストへも
  # 「プロファイル利用不可のため全文はReadさせません」の案内1行を出していた）。
  occurrences_ue="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "T9': 必読リストに実体プロファイルの行が0件" "0" "$occurrences_ue"

  # FR-12（要件v1.2.1）: UNKNOWN_EXTRAも🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（区分コードはUNKNOWN_EXTRA）。
  mode_line_ue="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "T9': モード行に「利用不可」を含む" "$mode_line_ue" "利用不可"
  assert_contains "T9': モード行に「本人確認へ倒す」を含む" "$mode_line_ue" "本人確認へ倒す"
  assert_contains "T9': モード行の区分コードに（UNKNOWN_EXTRA）を含む" "$mode_line_ue" "（UNKNOWN_EXTRA）"

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
  # FR-10差し戻し（検証1巡目MINOR-4・2026-09-17）: symlinkでも必読リストへは
  # 一切追加しない（旧仕様は「symlinkのため実体として受理しません」の案内
  # 1行を必読リストへ出していた。案内は🧭モード行の「利用不可（SYMLINK）」
  # セグメントへ一本化する）。
  occurrences_symlink="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "symlink: 必読リストに実体プロファイルの行が0件" "0" "$occurrences_symlink"

  # FR-12（要件v1.2.1）: symlinkも🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（区分コードはSYMLINK）。
  mode_line_symlink="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "symlink: モード行に「利用不可」を含む" "$mode_line_symlink" "利用不可"
  assert_contains "symlink: モード行の区分コードに（SYMLINK）を含む" "$mode_line_symlink" "（SYMLINK）"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

# ============================================================================
# 23番以降: v2配役表解凍（配役表解凍-設計-2026-09-01.md 担当A）のユニット・結合
# テスト。claude/hooks/lib/profile_resolve.py を直接CLI呼び出しする（parser・
# validator・候補評価は本libが唯一の正本＝§3.4）。DIRECTIVE統合部分だけ
# run_bootstrap_with_profile()を使う。2026-09-08 モデル定義ファイルと候補
# 指定対応（同設計§3.8・D-13）: 旧・分類ラッパー関数（旧・版分類サブコマンドの
# ラッパー）は撤去した——schema 6のコードは分類そのものを行わない。
# ============================================================================

PROFILE_LIB="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
AGENTS_DIR="$REPO_ROOT/claude/agents"

resolve_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}
resolve_leader_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve-leader "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}

# v2の全5固定キー(メタ2+能力軸3)をすべて満たした最小の
# base雛形。呼び出し側がrole.行だけを足して各シナリオを作る。
# 2026-09-08 モデル定義ファイルと候補指定対応: EXPECTED_SCHEMA_VERSIONを
# 5→6へ引き上げた（モデル定義ファイルと候補指定-設計-2026-09-08.md・D-8）
# のに合わせてbaseも更新した。役割の行の属性はmodel=<定義名>[,…]だけになり、
# provider/execution/effortはモデル定義ファイル側（make_model_defs()）へ
# 移した。2026-09-16 代替配役の層と禁止モデル列挙の層の撤去-設計-
# 2026-09-16.mdでEXPECTED_SCHEMA_VERSIONを6→7へ引き上げたのに合わせて
# baseを再更新した。
# ⚠️ team_mode:の行末揃え（8スペース）は下部のsed置換が字面で参照するため
# 崩さないこと。
V2_BASE='---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main'

make_v2_profile() {
  # $1=path、以降の引数は role.行（そのまま追記）。
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "$V2_BASE"
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '---\n'
  } > "$path"
}

echo "=== 23. parser 4.1-a/4.1-b: ハイフンキー・コメント行・行末コメントが正しく扱われる ==="
{
  P="$(mktemp -d)/comment.md"
  make_v2_profile "$P" \
    "# これはコメント行（無視される）" \
    "role.leader: configured model=t-opus-high  # 行末コメントも無視" \
    "role.requirements-analyst: configured model=t-opus-high"
  out="$(resolve_v2 "$P")"  || true
  assert_contains "4.1-a: ハイフンを含むキー(role.requirements-analyst)がT6にならない" "$out" "OK"
  assert_not_contains "4.1-b: コメント行・行末コメントでT6にならない" "$out" "MINIMAL"
}

echo "=== 24. parser §3.1-7: 重複キー・重複属性・未許可属性はすべてT6（構文エラー） ==="
{
  DUPKEY="$(mktemp -d)/dupkey.md"
  make_v2_profile "$DUPKEY" \
    "role.leader: configured model=t-opus-high" \
    "role.leader: unknown"
  out="$(resolve_v2 "$DUPKEY")"  || true
  assert_contains "重複キーはMINIMAL/T6になる" "$out" "MINIMAL"
  assert_contains "T6コードが出る" "$out" "T6"

  DUPATTR="$(mktemp -d)/dupattr.md"
  make_v2_profile "$DUPATTR" \
    "role.leader: configured model=t-opus-high model=t-sonnet-high"
  out="$(resolve_v2 "$DUPATTR")"  || true
  assert_contains "重複属性はMINIMAL/T6になる" "$out" "MINIMAL	T6"

  UNKATTR="$(mktemp -d)/unkattr.md"
  make_v2_profile "$UNKATTR" \
    "role.leader: configured model=t-opus-high mystery=1"
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
    "role.leader: configured model=t-opus-high" \
    "role.researcher: not_adopted model=t-opus-high"
  out="$(resolve_v2 "$NOTADOPT_ATTR")"  || true
  assert_contains "not_adoptedが属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  MISSING_MODEL="$(mktemp -d)/missingmodel.md"
  make_v2_profile "$MISSING_MODEL" \
    "role.leader: configured"
  out="$(resolve_v2 "$MISSING_MODEL")"  || true
  assert_contains "configuredでmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNAVAIL_OK="$(mktemp -d)/unavailok.md"
  make_v2_profile "$UNAVAIL_OK" \
    "role.leader: configured model=t-opus-high" \
    "role.researcher: unavailable model=bedrock-haiku"
  out="$(resolve_v2 "$UNAVAIL_OK")"  || true
  assert_contains "unavailableはprovider/modelを持ってよい（意図の記録）" "$out" "OK"
}

echo "=== 26. validate_model_def(): provider毎のmodel形式・execution既定・external必須execution（2026-09-08 モデル定義ファイルと候補指定対応でV9-bの検査対象が役割の行からモデル定義ファイル側へ移った。§2.4） ==="
{
  # ⚠️ load_model_defs()は定義ファイル内の全定義を検証するため、role.leaderが
  # 実際にその定義を参照していなくても、ファイル内に1つでも不正な定義が
  # あればT12でMINIMALになる（役割の行の候補解決より前の段）。
  BADMODEL="$(mktemp -d)/badmodel.md"
  BADMODEL_CONF="$(mktemp -d)/badmodel.conf"
  make_model_defs "$BADMODEL_CONF" "[bad-model]" "provider=anthropic-api" "model=gpt-5"
  make_v2_profile "$BADMODEL" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$BADMODEL_CONF" resolve_v2 "$BADMODEL")"  || true
  assert_contains "anthropic-apiでmodelがclaude-接頭辞でないとT12でMINIMAL" "$out" "MINIMAL	T12"

  BEDROCKARN="$(mktemp -d)/bedrockarn.md"
  BEDROCKARN_CONF="$(mktemp -d)/bedrockarn.conf"
  make_model_defs "$BEDROCKARN_CONF" "[bad-arn]" "provider=bedrock" "model=arn:aws:bedrock:foo"
  make_v2_profile "$BEDROCKARN" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$BEDROCKARN_CONF" resolve_v2 "$BEDROCKARN")"  || true
  assert_contains "bedrockでarn:始まりのmodelはT12（別名限定）" "$out" "MINIMAL	T12"

  BEDROCKUS="$(mktemp -d)/bedrockus.md"
  BEDROCKUS_CONF="$(mktemp -d)/bedrockus.conf"
  make_model_defs "$BEDROCKUS_CONF" "[bad-us]" "provider=bedrock" "model=us.opus"
  make_v2_profile "$BEDROCKUS" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$BEDROCKUS_CONF" resolve_v2 "$BEDROCKUS")"  || true
  assert_contains "bedrockでus.始まりのmodelもT12" "$out" "MINIMAL	T12"

  EXTNOEXEC="$(mktemp -d)/extnoexec.md"
  EXTNOEXEC_CONF="$(mktemp -d)/extnoexec.conf"
  make_model_defs "$EXTNOEXEC_CONF" "[bad-noexec]" "provider=external" "model=default"
  make_v2_profile "$EXTNOEXEC" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$EXTNOEXEC_CONF" resolve_v2 "$EXTNOEXEC")"  || true
  assert_contains "provider=externalでexecution未記載はT12" "$out" "MINIMAL	T12"

  NONSUBEXEC="$(mktemp -d)/nonsubexec.md"
  NONSUBEXEC_CONF="$(mktemp -d)/nonsubexec.conf"
  make_model_defs "$NONSUBEXEC_CONF" "[bad-nonsub]" "provider=anthropic-api" "model=claude-opus-5" "execution=external-cli"
  make_v2_profile "$NONSUBEXEC" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$NONSUBEXEC_CONF" resolve_v2 "$NONSUBEXEC")"  || true
  assert_contains "anthropic-apiでexecution!=subagentはT12" "$out" "MINIMAL	T12"

  DEFAULTEXEC="$(mktemp -d)/defaultexec.md"
  make_v2_profile "$DEFAULTEXEC" \
    "role.leader: configured model=t-opus-high"
  out="$(resolve_v2 "$DEFAULTEXEC")"  || true
  assert_contains "execution未記載はsubagent既定でOKになる" "$out" "OK"
}

echo "=== 27. validator V9-d②: execution=external-apiは常にconfigured不可（2026-09-08 モデル定義ファイルと候補指定対応でハンドラ写像が(provider,execution,model)の三つ組から(provider,execution)の対へ縮まったため、旧『写像に無いmodel名』の陰性ケースは消滅した＝external-cliならどのmodelでも実装済み扱いになる。§2.4） ==="
{
  EXTAPI="$(mktemp -d)/extapi.md"
  make_v2_profile "$EXTAPI" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=ext-api-bad"
  out="$(resolve_v2 "$EXTAPI")"  || true
  assert_contains "execution=external-apiはハンドラ未実装でconfigured不可(V9-d)" "$out" "MINIMAL	T8	V9-d"

  EXTAPI_UNAVAIL="$(mktemp -d)/extapiunavail.md"
  make_v2_profile "$EXTAPI_UNAVAIL" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unavailable model=ext-api-bad"
  out="$(resolve_v2 "$EXTAPI_UNAVAIL")"  || true
  assert_contains "unavailableならexternal-apiでも構文上は許される(V9-d②はconfigured限定)" "$out" "OK"
}

echo "=== 29b. AC-5: 撤去済みキーが残存した実体はUNKNOWN_EXTRAとして扱われる（FR-3。エラーにも無視にもしない） ==="
{
  # ⚠️ 撤去済みキー名を検索語としてソースへ直書きしない（AC-1・AC-2の
  # repo検索に一致しないよう分割代入する。上のlegacy_excluded_keyと同じ手口）。
  retired_key_1="fall""back"".""verifier"
  retired_key_2="excluded""_models"

  RESIDUAL_1="$(mktemp -d)/residual1.md"
  cat > "$RESIDUAL_1" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader: configured model=t-opus-high
fallback.verifier: configured model=t-opus-high # RETIRED-FIXTURE
---
EOF
  out="$(resolve_v2 "$RESIDUAL_1")"  || true
  assert_contains "残存する旧キーの行はUNKNOWN_EXTRAに出る(1)" "$out" "UNKNOWN_EXTRA:${retired_key_1}"
  assert_not_contains "残存キーがあってもMINIMALへは倒さない(1)" "$out" "MINIMAL"

  RESIDUAL_2="$(mktemp -d)/residual2.md"
  cat > "$RESIDUAL_2" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader: configured model=t-opus-high
excluded_models: configured value=none # RETIRED-FIXTURE
---
EOF
  out="$(resolve_v2 "$RESIDUAL_2")"  || true
  assert_contains "残存する旧キーの行はUNKNOWN_EXTRAに出る(2)" "$out" "UNKNOWN_EXTRA:${retired_key_2}"
  assert_not_contains "残存キーがあってもMINIMALへは倒さない(2)" "$out" "MINIMAL"

  echo "--- 廃止済みの複数候補あいまいコードは復活しない（AC-4の回帰） ---"
  AMBIG="$(mktemp -d)/ambig.md"
  make_v2_profile "$AMBIG" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=t-opus-high,t-sonnet-high"
  err="$(python3 "$PROFILE_LIB" resolve-candidate "$AMBIG" --role verifier --model-def t-opus-high 2>&1 1>/dev/null)"  || true
  assert_not_contains "候補が複数あってもFALLBACK_AMBIGUOUSは出ない" "$err" "FALLBACK_AMBIGUOUS"  # RETIRED-FIXTURE
}

echo "=== 30. §3.5-L リーダー状態遷移: unknown/not_adopted/行が無い/unavailableは全てfail（resolveも非0・resolve-leaderも非0） ==="
{
  for state in "role.leader: unknown" "role.leader: not_adopted"; do
    P="$(mktemp -d)/leaderfail.md"
    make_v2_profile "$P" "$state"
    rc=0; out="$(resolve_v2 "$P")" || rc=$?
    assert_contains "leader=${state}はMINIMALになる" "$out" "MINIMAL"
    assert_eq "leader=${state}はresolveが非0終了する" "1" "$rc"
  done

  NOLEADER="$(mktemp -d)/noleader.md"
  make_v2_profile "$NOLEADER" "role.researcher: configured model=t-sonnet-high"
  out="$(resolve_v2 "$NOLEADER")"  || true
  assert_contains "role.leader行が無ければfail(MINIMAL)になる" "$out" "MINIMAL"

  UNAVAIL="$(mktemp -d)/leaderunavail.md"
  make_v2_profile "$UNAVAIL" "role.leader: unavailable model=t-opus-high"
  out="$(resolve_v2 "$UNAVAIL")"  || true
  assert_contains "leader=unavailableはfail" "$out" "MINIMAL"

  err="$(resolve_leader_v2 "$UNAVAIL" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderは機械可読コードLEADER_UNAVAILABLEをstderrへ出す" "$err" "LEADER_UNAVAILABLE"
  # 廃止済みコードは復活しない（AC-4の回帰。マーカー2/4本目）。
  assert_not_contains "旧コードLEADER_UNAVAILABLE_NO_FALLBACKは出ない" "$err" "LEADER_UNAVAILABLE_NO_FALLBACK"  # RETIRED-FIXTURE
}

echo "=== 31. §3.5-L: leader専用規則: 実効候補のproviderがexternalならfail ==="
{
  EXT_LEADER="$(mktemp -d)/extleader.md"
  make_v2_profile "$EXT_LEADER" \
    "role.leader: configured model=codex-review"
  out="$(resolve_v2 "$EXT_LEADER")"  || true
  assert_contains "leaderのprovider=externalはfailになる" "$out" "MINIMAL"
}

echo "=== 32. 候補評価§3.6: ワーカー職はV1-b/V9-d/V12単独では空席にならず、同じ行の2件目以降の候補が使えれば採用される ==="
{
  MULTI_CAND="$(mktemp -d)/workermulticand.md"
  make_v2_profile "$MULTI_CAND" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,t-sonnet-high"
  # bedrock.envを与えない(ABSENT=disabled)のでverifierの1件目(bedrock)はV9-dで使用不可・
  # 2件目(t-sonnet-high)は使用可。
  out="$(resolve_v2 "$MULTI_CAND")"  || true
  assert_not_contains "1件目が使用不可でも2件目が使えれば空席にならない" "$out" "VACANT:verifier"
  assert_contains "resolve自体はOKのまま" "$out" "OK"

  echo "--- 全候補が使用不可のときだけVACANT+VACANT_REASON、優先順はV1-b→V9-d→V12 ---"
  BOTH_BAD="$(mktemp -d)/bothbad.md"
  make_v2_profile "$BOTH_BAD" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus"
  out="$(resolve_v2 "$BOTH_BAD")"  || true
  assert_contains "全候補がbedrockで経路無効なら空席になる" "$out" "VACANT:verifier"
  assert_contains "空席理由の条件番号が出る(V9-d)" "$out" "VACANT_REASON:verifier=V9-d"

  echo "--- unavailableな行は候補を1件も評価せず、良い候補を持っていてもVACANTになる（§3.6：状態は行単位） ---"
  UNAVAIL_LINE="$(mktemp -d)/unavailline.md"
  make_v2_profile "$UNAVAIL_LINE" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unavailable model=t-sonnet-high"
  out="$(resolve_v2 "$UNAVAIL_LINE")"  || true
  assert_contains "unavailableな行は候補が良くてもVACANTになる（意図的な不使用）" "$out" "VACANT:verifier"
  assert_not_contains "評価しないので理由(VACANT_REASON)も付かない" "$out" "VACANT_REASON:verifier"
}

echo "=== 33. §3.7 判定不能: Bedrock経路の判定不能はワーカーなら通す・leaderならfail ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir
  UNREADABLE_ENV="/tmp/aienv-test-unreadable-env-dir/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV"
  chmod 0000 "$UNREADABLE_ENV"

  WORKER_UNKNOWN="$(mktemp -d)/workerunknown.md"
  make_v2_profile "$WORKER_UNKNOWN" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$WORKER_UNKNOWN" "$UNREADABLE_ENV")"  || true
  assert_not_contains "判定不能でもワーカーは空席にならない" "$out" "VACANT:verifier"
  assert_contains "resolve自体はOKのまま" "$out" "OK"

  LEADER_UNKNOWN="$(mktemp -d)/leaderunknownenv.md"
  make_v2_profile "$LEADER_UNKNOWN" \
    "role.leader: configured model=bedrock-opus"
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
    "role.leader: configured model=bedrock-opus"
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
    "role.leader: configured model=t-opus-high"
  echo "api_key: configured value=xyz" >> "$V15_V2"
  # frontmatter終端---の後ろに付けると構文が壊れるので、専用のfixtureを作り直す。
  cat > "$V15_V2" <<'EOF'
---
schema_version: 7
profile_slug: authoring
role.leader: configured model=t-opus-high
api_key: configured value=xyz
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
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
team_mode: 本人
no_read_paths: ~/work/old
auth_token: should-not-be-here
---
EOF
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "v1でも禁止キー名検出で最小能力の警告が出る" "$ctx" "認証情報らしいキー名があります"
  assert_not_contains "全文Readの指示は付かない（必読除外）" "$ctx" "$PROFILE_PATH  （全"
  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 36. 結合（DIRECTIVE）: VACANT_UNKNOWN・VACANT_REASONが職種名と条件番号でDIRECTIVEへ注入される ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus"
  # 静的検証: このprofile単体でVACANT_REASON:verifier=V9-dが出ることを確認済み(#32)。
  # ここではDIRECTIVEへの伝播だけを確認する。

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "DIRECTIVEに配役表の状態行が出る" "$ctx" "配役表の状態"
  assert_contains "VACANT:teseterの職種名が出る" "$ctx" "VACANT:verifier"
  assert_contains "VACANT_REASONの条件番号が出る" "$ctx" "VACANT_REASON:verifier=V9-d"
  # ここで見るのは生の属性構文（`model=`・`provider=`のkey=value形式）が
  # DIRECTIVEへそのまま再掲されないこと（機構が値を再包装せず生のprofile行を
  # 横流しした場合の回帰を検知する）。
  assert_not_contains "配役の属性構文(model=)がそのまま再掲されない" "$ctx" "model="
  assert_not_contains "配役の属性構文(provider=)がそのまま再掲されない" "$ctx" "provider="
  # FR-11（要件v1.2.1）: 職種ごとの候補一覧（定義名のみ）の注入行は撤去した
  # （旧仕様=advisory直後にℹ️行を足す形。候補一覧コマンド新設に伴い
  # SessionStart注入からは0件になる＝NFR-5）。
  assert_eq "候補一覧のℹ️行は0件（FR-11で撤去）" "0" \
    "$(printf '%s\n' "$ctx" | grep -c '^ℹ️ 職種ごとのモデル候補' || true)"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 37. FR-10対応: v2 OKでも全文Read指示は必読リストに載らない（旧仕様は撤回）。フィールドは固定順（OK→VACANT→VACANT_REASON→VACANT_UNKNOWN→ADVISORY→UNKNOWN_EXTRA） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured model=t-opus-high" \
    "role.requirements-analyst: configured model=t-opus-high"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  occurrences="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH  （全" || true)"
  assert_eq "壊れていないv2プロファイルでも全文Read指示は0件（FR-10）" "0" "$occurrences"

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
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus" \
    "role.researcher: configured model=t-sonnet-high"
  multi_out="$(resolve_v2 "$MULTI")"  || true
  # 期待: OK -> VACANT:verifier -> VACANT_REASON:verifier=V9-d -> VACANT_UNKNOWN
  # (コアマニフェストの他職種) -> ADVISORY:V1-a の順で、この並びどおりに現れること。
  idx_ok=$(printf '%s' "$multi_out" | grep -bo '^OK' | head -1 | cut -d: -f1)
  idx_vacant=$(printf '%s' "$multi_out" | grep -bo 'VACANT:' | head -1 | cut -d: -f1)
  idx_vacant_reason=$(printf '%s' "$multi_out" | grep -bo 'VACANT_REASON:' | head -1 | cut -d: -f1)
  idx_vacant_unknown=$(printf '%s' "$multi_out" | grep -bo 'VACANT_UNKNOWN:' | head -1 | cut -d: -f1)
  idx_advisory=$(printf '%s' "$multi_out" | grep -bo 'ADVISORY:' | head -1 | cut -d: -f1)
  assert_contains "複合ケースでVACANTにverifierが出る" "$multi_out" "VACANT:verifier"
  order_multi_ok=1
  [ -n "$idx_ok" ] && [ -n "$idx_vacant" ] && [ "$idx_ok" -lt "$idx_vacant" ] || order_multi_ok=0
  [ -n "$idx_vacant" ] && [ -n "$idx_vacant_reason" ] && [ "$idx_vacant" -lt "$idx_vacant_reason" ] || order_multi_ok=0
  [ -n "$idx_vacant_reason" ] && [ -n "$idx_vacant_unknown" ] && [ "$idx_vacant_reason" -lt "$idx_vacant_unknown" ] || order_multi_ok=0
  [ -n "$idx_vacant_unknown" ] && [ -n "$idx_advisory" ] && [ "$idx_vacant_unknown" -lt "$idx_advisory" ] || order_multi_ok=0
  assert_eq "OK→VACANT→VACANT_REASON→VACANT_UNKNOWN→ADVISORYの出現順が固定順どおり" "1" "$order_multi_ok"
}

echo "=== 38. 候補評価§3.6: 1件目と2件目の失敗理由が異なるとき、優先順(V1-b→V9-d→V12)で高い方が採用される（ホワイトボックス・Codex二次レビュー指摘・Major対応: CLI経由のfixtureでは1件目/2件目が同一職種名を共有するためV1-bは両者で必ず同じ結果になり、異なる理由の組み合わせを黒箱では再現できない。_evaluate_single_candidate()を差し替えて優先順ロジック自体を直接検証する） ==="
{
  # 2026-09-08 モデル定義ファイルと候補指定対応: evaluate_worker_candidate()の
  # シグネチャがresolved辞書（{name: [ModelDef,...]}）を取るように変わり、
  # 内部で候補ごとにCandidate(name, ModelDef)を組み立ててから
  # _evaluate_single_candidate()へ渡すようになった（1行1候補→1行n候補）。
  # そのためline識別はオブジェクトの同一性ではなくdef_nameで行う。
  # 2026-09-16 代替配役の層の撤去に合わせ、resolved辞書のキーを
  # (kind,name)からnameへ、evaluate_worker_candidate()の引数を5個へ縮める。
  result="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 - <<'PYEOF'
import profile_resolve as pr


class Fake:
    def __init__(self, name):
        self.name = name
        self.state = "configured"


def make_def(name):
    d = pr.ModelDef(name, 0)
    d.provider = "anthropic-api"
    d.model = "claude-opus-5"
    d.execution = "subagent"
    return d


def fake_eval(cand, agents_dir, bedrock_env, is_leader):
    if cand.def_name == "first-def":
        return False, "V9-d", None
    return False, "V1-b", None


primary = Fake("verifier")
resolved = {
    "verifier": [make_def("first-def"), make_def("second-def")],
}
orig = pr._evaluate_single_candidate
pr._evaluate_single_candidate = fake_eval
try:
    cand = pr.evaluate_worker_candidate("verifier", {"verifier": primary}, resolved, None, None)
finally:
    pr._evaluate_single_candidate = orig
print(cand.vacant_reason)
PYEOF
)"
  assert_eq "1件目=V9-d・2件目=V1-bでもV1-bの方が優先順が高いのでV1-bが選ばれる" "V1-b" "$result"
}

echo "=== 39. §3.7 判定不能: ワーカーが判定不能で通ったこと自体がADVISORY(JUDGEMENT_UNKNOWN)として出る（Codex一次レビュー指摘・Major対応: 従来はunknown_noteを保持するだけで出力していなかった） ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir2
  UNREADABLE_ENV2="/tmp/aienv-test-unreadable-env-dir2/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV2"
  chmod 0000 "$UNREADABLE_ENV2"

  ADV_UNKNOWN="$(mktemp -d)/advunknown.md"
  make_v2_profile "$ADV_UNKNOWN" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$ADV_UNKNOWN" "$UNREADABLE_ENV2")"  || true
  assert_contains "判定不能で通した職種があることがADVISORY:JUDGEMENT_UNKNOWNとして出る" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"

  chmod 0700 "$UNREADABLE_ENV2"
  rm -rf /tmp/aienv-test-unreadable-env-dir2
}

echo "=== 40. 代替配役の層の撤去の回帰: 職種の2件目の候補が採用されても撤去済みフィールドは一切出ない ==="
{
  # ⚠️ 撤去済みフィールド名を検索語としてソースへ直書きしない（AC-1の
  # repo検索に一致しないよう分割代入する。上のlegacy_excluded_keyと同じ手口）。
  retired_field_name="FALL""BACK:"
  MULTI_OK="$(mktemp -d)/multiok.md"
  make_v2_profile "$MULTI_OK" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,t-sonnet-high"
  out="$(resolve_v2 "$MULTI_OK")"  || true
  assert_not_contains "1件目が使用不可で2件目が採用されても撤去済みフィールドは出ない" "$out" "$retired_field_name"
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
  make_v2_profile "$LEADER_FAIL_ENV" "role.leader: configured model=bedrock-sonnet"
  leader_err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_FAIL_ENV" --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_not_contains "resolve-leaderのstderrにもピン実値が現れない" "$leader_err" "supersecret-arn-2"
  assert_not_contains "resolve-leaderのstderrにもAWSキーが現れない" "$leader_err" "SHOULD_NEVER_LEAK_2"
}

echo "=== 42. §3.4 T4'(実体の版>コードの版): 未知キーを無視しADVISORY:T4-PRIME+UNKNOWN_EXTRAで通す(最小能力へは倒さない) ==="
{
  T4PRIME="$(mktemp -d)/t4prime.md"
  make_v2_profile "$T4PRIME" \
    "role.leader: configured model=t-opus-high"
  sed -i '' 's/schema_version: 7/schema_version: 8/' "$T4PRIME"
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

echo "=== 44. V8-b共通規則（Codex一次レビュー指摘・Major対応） ==="
{
  DUP_VALUE="$(mktemp -d)/dupvalue.md"
  make_v2_profile "$DUP_VALUE" \
    "role.leader: configured model=t-opus-high"
  sed -i '' 's/team_mode:        configured value=full/team_mode:        configured value=full,full/' "$DUP_VALUE"
  out="$(resolve_v2 "$DUP_VALUE")"  || true
  assert_contains "value内の重複要素はV8-bでMINIMALになる（共通規則）" "$out" "MINIMAL	T8	V8-b"
}

echo "=== 45. is_v2_resolve_output_well_formed(): ゴミ混入・重複・順序違反はいずれも拒否される（Codex三次レビュー指摘・Major対応） ==="
{
  source_well_formed() {
    # bootstrap-vault.sh から is_v2_resolve_output_well_formed だけを取り込む
    # （本体を実行させないよう、関数定義を含む範囲だけをsedで切り出す）。
    eval "$(sed -n '/^is_v2_resolve_output_well_formed()/,/^}/p' "$SCRIPT")"
  }
  source_well_formed

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "正常なOK単体は受理される" || fail_case "正常なOK単体は受理される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tGARBAGE:xyz')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "未知フィールド(GARBAGE)混入は拒否される" || fail_case "未知フィールド(GARBAGE)混入は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT:verifier\tVACANT:verifier')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "同一フィールドの重複は拒否される" || fail_case "同一フィールドの重複は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT_REASON:verifier=V9-d\tVACANT:verifier')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "フィールドの順序違反(VACANT_REASONがVACANTより先)は拒否される" || fail_case "フィールドの順序違反(VACANT_REASONがVACANTより先)は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 1 && pass "OKなのにexit1は拒否される" || fail_case "OKなのにexit1は拒否される"

  T="$(printf 'MINIMAL\tT6\t3行目: 解析できない行です')"
  is_v2_resolve_output_well_formed "$T" 1 && pass "正常なMINIMAL(exit1)は受理される" || fail_case "正常なMINIMAL(exit1)は受理される"

  T="$(printf 'MINIMAL\tT6\t理由')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MINIMALなのにexit0は拒否される" || fail_case "MINIMALなのにexit0は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\nEXTRA_LINE')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "複数行出力は拒否される" || fail_case "複数行出力は拒否される"

  T="$(printf 'MINIMAL\tT6\t3行目: 解析できない行です\tGARBAGE')"
  ! is_v2_resolve_output_well_formed "$T" 1 && pass "MINIMALの理由部分にタブで4つ目のフィールドが紛れ込むと拒否される（Codex三次レビュー指摘・Major対応）" \
    || fail_case "MINIMALの理由部分にタブで4つ目のフィールドが紛れ込むと拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT_UNKNOWN:My_Role.v2')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "大文字・アンダースコア・ドットを含む職種名も受理される（Codex三次レビュー指摘・Major対応: parserのKEY_RE[A-Za-z0-9_.-]+と同じ文字集合に統一）" \
    || fail_case "大文字・アンダースコア・ドットを含む職種名も受理される"

  T="$(printf 'OK\tschema_version=2')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "TEAM_MODE:欠落は拒否される（3モード体制-設計-2026-09-06.md §4.2＝必須フィールド）" \
    || fail_case "TEAM_MODE:欠落は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:quick\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "TEAM_MODE:の値が4語のいずれでもないと拒否される" \
    || fail_case "TEAM_MODE:の値が4語のいずれでもないと拒否される"

  T="$(printf 'OK\tschema_version=2\tVACANT:verifier\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "TEAM_MODE:がschema_versionの直後以外の位置にあると拒否される" \
    || fail_case "TEAM_MODE:がschema_versionの直後以外の位置にあると拒否される"

  # 配役表-能力軸整理-設計-2026-09-07.md §4.2・D-2: MACHINE_ROLE:はTEAM_MODE:の
  # 直後・必須フィールド。
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:欠落は拒否される（D-2＝必須フィールド）" \
    || fail_case "MACHINE_ROLE:欠落は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:primary')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:の値がmain/sub/unknown/unavailableのいずれでもないと拒否される" \
    || fail_case "MACHINE_ROLE:の値が不正だと拒否される"

  # TEAM_MODEは正しい位置のまま、MACHINE_ROLEだけをTEAM_MODEの直後以外へ
  # 動かす（TEAM_MODEの位置違反とは独立にMACHINE_ROLEの位置だけを検証する）。
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tVACANT:verifier\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:がTEAM_MODE:の直後以外の位置にあると拒否される" \
    || fail_case "MACHINE_ROLE:がTEAM_MODE:の直後以外の位置にあると拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:unknown')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:unknownは受理される" \
    || fail_case "MACHINE_ROLE:unknownは受理される"

  # 検証1巡目MINOR-4対応（設計§6.3⑩）: 撤去済みフィールドを含む行は
  # 不正として拒否される（AC-1・AC-2に引っかからないよう分割代入する）。
  retired_field_name="FALL""BACK:verifier"
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\t%s' "$retired_field_name")"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "撤去済みフィールドを含む行は拒否される" \
    || fail_case "撤去済みフィールドを含む行は拒否される"
}

echo "=== 46. list-roles: state/定義名/execution既定値/not_adopted・unknownの空欄化（2026-09-16 代替配役の層の撤去で7列・単一role.表へ改訂＝設計§3.4） ==="
{
  LR="$(mktemp -d)/listroles.md"
  make_v2_profile "$LR" \
    "role.leader: configured model=t-opus-high" \
    "role.navi: unknown" \
    "role.researcher: not_adopted" \
    "role.system-designer: configured model=t-opus-high" \
    "role.verifier: unavailable model=bedrock-opus"
  out="$(python3 "$PROFILE_LIB" list-roles "$LR")"  || true

  assert_contains "role.leaderの行がstate=configured・定義名=t-opus-highで出る" "$out" "leader	configured	t-opus-high	anthropic-api	claude-opus-5	subagent	"
  assert_contains "executionが省略されていてもsubagentが補われて出る" "$out" "	subagent	"
  assert_contains "effortが指定されていればそのまま出る(system-designer=high)" "$out" "system-designer	configured	t-opus-high	anthropic-api	claude-opus-5	subagent	high"
  assert_contains "unknown状態は定義名以降が全て空文字になる（5フィールド）" "$out" "navi	unknown					"
  assert_contains "not_adopted状態も定義名以降が全て空文字になる（5フィールド）" "$out" "researcher	not_adopted					"
  assert_contains "unavailable状態は定義名・provider/modelを保持したまま出る（意図の記録）" "$out" "verifier	unavailable	bedrock-opus	bedrock	opus	subagent	"
  assert_not_contains "kind列は撤去済みなので先頭に'role'は出ない" "$out" "role	leader"

  count="$(printf '%s' "$out" | awk -F'\t' '{print NF}' | sort -u | wc -l | tr -d ' ')"
  assert_eq "全行が7列で揃っている（列数のばらつきが無い）" "1" "$count"
}

echo "=== 47. list-roles: 失敗時（自己完結・resolve-leaderと同じコード体系）はstdoutが空でstderrへ機械可読コードが出る ==="
{
  err="$(python3 "$PROFILE_LIB" list-roles /nonexistent-dir/nope.md 2>&1 1>/dev/null)"  || true
  assert_contains "存在しないファイルはPROFILE_NOT_FOUNDになる" "$err" "PROFILE_NOT_FOUND"

  DUP="$(mktemp -d)/lrdup.md"
  make_v2_profile "$DUP" \
    "role.leader: configured model=t-opus-high" \
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
    "role.leader: configured model=bedrock-opus"
  # list-rolesはbedrock-envを引数に取らない（profile本体の値=別名しか扱わない
  # 設計）ため、そもそもbedrock.envを読まない。念のため実際に出力へ実値が
  # 混入していないことを確認する。
  out="$(python3 "$PROFILE_LIB" list-roles "$LR_SECRET")"  || true
  assert_not_contains "list-roles出力にピン実値(ARN)が現れない" "$out" "supersecret-arn-3"
  assert_not_contains "list-roles出力にAWSキーが現れない" "$out" "SHOULD_NEVER_LEAK_3"
  assert_contains "list-roles出力にはBedrockの別名(opus)だけが出る" "$out" "leader	configured	bedrock-opus	bedrock	opus	subagent	"
}

echo "=== 49. tester独立検証差し戻し(Major): bedrock.envに不正UTF-8があってもクラッシュせず、判定不能として扱われる（_read_bedrock_env_wanted()がUnicodeDecodeErrorを未捕捉だった実バグの回帰テスト） ==="
{
  BAD_UTF8_ENV="$(mktemp -d)/bedrock.env"
  printf 'CLAUDE_CODE_USE_BEDROCK=1\nANTHROPIC_DEFAULT_HAIKU_MODEL=\xff\xfebroken\n' > "$BAD_UTF8_ENV"

  WORKER_BAD_UTF8="$(mktemp -d)/workerbadutf8.md"
  make_v2_profile "$WORKER_BAD_UTF8" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$WORKER_BAD_UTF8" "$BAD_UTF8_ENV")"  || true
  err="$(python3 "$PROFILE_LIB" resolve "$WORKER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "workerは判定不能で通り(JUDGEMENT_UNKNOWN)クラッシュしない" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"
  assert_not_contains "workerはVACANTにならない" "$out" "VACANT:verifier"
  assert_not_contains "stderrにPythonのtracebackが出ない" "$err" "Traceback"

  LEADER_BAD_UTF8="$(mktemp -d)/leaderbadutf8.md"
  make_v2_profile "$LEADER_BAD_UTF8" "role.leader: configured model=bedrock-haiku"
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

echo "=== 51. V14メタ構文の直接検証: schema_versionが正整数でない・profile_slugが規約に反する ==="
{
  BADVER="$(mktemp -d)/badver.md"
  make_v2_profile "$BADVER" "role.leader: configured model=t-opus-high"
  sed -i '' 's/schema_version: 7/schema_version: abc/' "$BADVER"
  out="$(resolve_v2 "$BADVER")"  || true
  assert_contains "schema_versionが数値でなければT3になる" "$out" "MINIMAL	T3"

  BADVER0="$(mktemp -d)/badver0.md"
  make_v2_profile "$BADVER0" "role.leader: configured model=t-opus-high"
  sed -i '' 's/schema_version: 7/schema_version: 0/' "$BADVER0"
  out="$(resolve_v2 "$BADVER0")"  || true
  assert_contains "schema_version=0(正整数でない)もT3になる" "$out" "MINIMAL	T3"

  BADSLUG="$(mktemp -d)/badslug.md"
  make_v2_profile "$BADSLUG" "role.leader: configured model=t-opus-high"
  sed -i '' 's/profile_slug: authoring/profile_slug: Bad_Slug!/' "$BADSLUG"
  out="$(resolve_v2 "$BADSLUG")"  || true
  assert_contains "profile_slugが規約(^[a-z0-9][a-z0-9-]*\$)に反するとT14になる" "$out" "MINIMAL	T14"
}

echo "=== 52. V8-a 状態4値×属性有無の網羅補充: unavailableでmodel欠落・unknownが属性を持つ ==="
{
  UNAVAIL_MISSING="$(mktemp -d)/unavailmissing.md"
  make_v2_profile "$UNAVAIL_MISSING" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unavailable"
  out="$(resolve_v2 "$UNAVAIL_MISSING")"  || true
  assert_contains "unavailableでもmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNKNOWN_ATTR="$(mktemp -d)/unknownattr.md"
  make_v2_profile "$UNKNOWN_ATTR" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unknown model=t-sonnet-high"
  out="$(resolve_v2 "$UNKNOWN_ATTR")"  || true
  assert_contains "unknown状態で属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  # 2026-09-08 モデル定義ファイルと候補指定対応: 旧「providerが無いこともV8-a
  # でMINIMALになる」ケースは撤去した——role行はもうprovider属性を持たない
  # ため、そのケース自体が成立しない（`model=claude-opus-5`は定義名として
  # 文法上妥当に読め、未定義参照ならV17で落ちる。V8-aの対象外）。
}

echo "=== 53. bedrock-mantle provider: 適合表(§3.3)の形式検査(モデル定義ファイル側=T12)とV12対象外(ピンチェックを課さない) ==="
{
  MANTLE_OK="$(mktemp -d)/mantleok.md"
  make_v2_profile "$MANTLE_OK" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=mantle-haiku"
  # bedrock.envは渡すがCLAUDE_CODE_USE_BEDROCKだけ有効にする(ピンは無し)。
  MANTLE_ENV="$(mktemp -d)/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$MANTLE_ENV"
  out="$(resolve_v2 "$MANTLE_OK" "$MANTLE_ENV")"  || true
  assert_contains "bedrock-mantleは正しい形式(anthropic.で始まる)ならOKになる(V12の対象外)" "$out" "OK"
  assert_not_contains "bedrock-mantleはVACANTにならない(ピンチェック不要)" "$out" "VACANT:verifier"

  MANTLE_BAD="$(mktemp -d)/mantlebad.md"
  MANTLE_BAD_CONF="$(mktemp -d)/mantlebad.conf"
  make_model_defs "$MANTLE_BAD_CONF" "[bad-mantle]" "provider=bedrock-mantle" "model=not-anthropic-prefixed"
  make_v2_profile "$MANTLE_BAD" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$MANTLE_BAD_CONF" resolve_v2 "$MANTLE_BAD")"  || true
  assert_contains "bedrock-mantleでanthropic.始まりでないmodelはT12でMINIMALになる" "$out" "MINIMAL	T12"
}

echo "=== 54. effort enum境界の直接検証(V9-b/V9-e): Claude系max・Codex方言minimal・設定効果先の非対称 ==="
{
  WORKER_MAX="$(mktemp -d)/workermax.md"
  make_v2_profile "$WORKER_MAX" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=sonnet-max"
  out="$(resolve_v2 "$WORKER_MAX")"  || true
  assert_contains "ワーカー行はmaxを書ける(V9-bのenumはEFFORT_CLAUDEでmaxを含む)" "$out" "OK"

  LEADER_MAX="$(mktemp -d)/leadermax.md"
  make_v2_profile "$LEADER_MAX" "role.leader: configured model=opus-max"
  out="$(resolve_v2 "$LEADER_MAX")"  || true
  assert_contains "leader行はmaxだとV9-eで弾かれfailになる(settings.jsonのeffortLevelがmaxを受理しないため)" "$out" "MINIMAL"
  err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_MAX" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderのエラーコードにV9-eが出る" "$err" "V9-e"

  CODEX_MINIMAL="$(mktemp -d)/codexminimal.md"
  make_v2_profile "$CODEX_MINIMAL" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=codex-review-minimal"
  out="$(resolve_v2 "$CODEX_MINIMAL")"  || true
  assert_contains "Codexハンドラ(external-cli/codex-review-default)はminimalを書ける" "$out" "OK"

  # 2026-09-08 モデル定義ファイルと候補指定対応: effortの許可集合検査は
  # モデル定義ファイル側（validate_model_def・T12）へ移った。
  CODEX_MINIMAL_ELSEWHERE_CONF="$(mktemp -d)/codexminimalelsewhere.conf"
  make_model_defs "$CODEX_MINIMAL_ELSEWHERE_CONF" "[bad-sonnet-minimal]" "provider=anthropic-api" "model=claude-sonnet-5" "effort=minimal"
  CODEX_MINIMAL_ELSEWHERE="$(mktemp -d)/codexminimalelsewhere.md"
  make_v2_profile "$CODEX_MINIMAL_ELSEWHERE" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$CODEX_MINIMAL_ELSEWHERE_CONF" resolve_v2 "$CODEX_MINIMAL_ELSEWHERE")"  || true
  assert_contains "Claude系(anthropic-api)でminimalはT12でMINIMALになる(Codex方言はexternalハンドラ限定)" "$out" "MINIMAL	T12"
}

echo "=== 55. V9-f直接検証: 既知の非対応モデル×xhigh はADVISORY、別名は判別不能としてEFFORT_COMPATIBILITY_UNVERIFIED ==="
{
  V9F_KNOWN="$(mktemp -d)/v9fknown.md"
  make_v2_profile "$V9F_KNOWN" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=opus46-xhigh"
  out="$(resolve_v2 "$V9F_KNOWN")"  || true
  # ADVISORYフィールドはコードをソートして併記する(§5)ため"V1-a,V9-f"に
  # なる。"ADVISORY:V9-f"という直結文字列を探すのは誤り(実測で判明)。
  assert_contains "既知の非対応モデル(claude-opus-4.6)×xhighはV9-fがADVISORYに含まれる(failにしない)" "$out" "V9-f"
  assert_contains "failにしない(OKのまま)" "$out" "OK"

  V9F_BEDROCK="$(mktemp -d)/v9fbedrock.md"
  make_v2_profile "$V9F_BEDROCK" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-opus-xhigh"
  out="$(resolve_v2 "$V9F_BEDROCK")"  || true
  assert_contains "bedrock別名は実モデル版を判別できないためEFFORT_COMPATIBILITY_UNVERIFIEDになる" "$out" "ADVISORY:EFFORT_COMPATIBILITY_UNVERIFIED"
}

echo "=== 56. BOOTSTRAP_ENABLE_LOCAL_PROFILE を指定しなければコードの既定値1でP1機構が有効になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  ctx="$(echo '{"session_id":"test-session-0000"}' \
    | env -u BOOTSTRAP_ENABLE_LOCAL_PROFILE \
        BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
        VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
        VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
        MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
        MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
        HEALTH_OBSERVATION_FILE="/nonexistent-dir/health/session-observation.json" \
        AIENV_LOCAL_PROFILE_PATH="/nonexistent-dir/profile-for-default-gate-test.md" \
        "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext')"
  mode_line_default_gate="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "フラグ未指定でも既定値1でP1機構が動く(T1のモード行区分コードが出る)" "$mode_line_default_gate" "（T1）"
  rm -rf "$VAULT_DIR"
}

echo "=== 57. V1-aマニフェスト: claude/agents/vault-scribe.mdは職種名'vault-scribe'としてファイル名そのままマニフェストへ数えられ、旧職種名'scribe'は入らない（2026-09-03本人裁定・方針変更: 対応表〈旧AGENT_FILE_TO_ROLE〉でファイル名と職種名の不一致を吸収する方式は、サブ機で『role.scribeを見てsubagent_type=scribeでspawn→定義ファイルが無く失敗』という実害が起きたため撤回し、配役表側のキーをrole.vault-scribeへ改名して職種名＝ファイル名の不変条件に揃える方式へ変更した） ==="
{
  # role_and_core_manifest_diff()本体を直接呼ぶ（マニフェスト計算ロジックの
  # 再実装ではなく、実装コードそのものを検証する）。role表は空にし、
  # only_in_manifest（＝マニフェスト全件）をそのまま確認する。
  result="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 - "$AGENTS_DIR" <<'PYEOF'
import sys
import profile_resolve as pr


class FakeParsed:
    roles: dict = {}


agents_dir = sys.argv[1]
_, only_in_manifest = pr.role_and_core_manifest_diff(FakeParsed(), agents_dir)
print("vault_scribe_count=" + str(only_in_manifest.count("vault-scribe")))
print("scribe_present=" + str("scribe" in only_in_manifest))
PYEOF
)"
  assert_contains "マニフェストに'vault-scribe'が1回だけ入る（ファイル名そのまま）" "$result" "vault_scribe_count=1"
  assert_contains "旧職種名'scribe'はマニフェストに入らない" "$result" "scribe_present=False"
}

echo "=== 58. V1-aマニフェスト(結合): role.vault-scribeを含む現行の全ロール構成でresolve()を通してもADVISORY:V1-aが出ない（57.の単体確認をCLI経由でも裏付け。2026-09-03本人裁定・方針変更対応） ==="
{
  # 実AGENTS_DIR（claude/agents/）を使い、現行のコア職種マニフェスト全件
  # （CORE_ROLES_WITHOUT_REPO_AGENT_FILE + claude/agents/*.md＝ファイル名
  # そのまま）ちょうどをrole.表へ宣言する。leader以外は状態を"unknown"に
  # して属性検証（V9-b等）を回避し、V1-aの対称差判定だけに焦点を絞る
  # （他ロールのstateはV1-aの結果に影響しない＝role_and_core_manifest_diff()
  # はparsed.rolesのキーのみを見る）。
  #
  # ロースター行は職種名をハードコードせず、CORE_ROLES_WITHOUT_REPO_AGENT_FILE
  # と AGENTS_DIR の *.md の stem から生成する（2026-09-20 設計 §4.4: 職種の
  # 追加・削除でこのテストの改修が要らないようにする）。bash 3.2 のため
  # 連想配列は使わず通常配列で組む。
  CORE_ROLE_NAMES="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 -c \
    'import profile_resolve as pr; print("\n".join(sorted(pr.CORE_ROLES_WITHOUT_REPO_AGENT_FILE)))')"
  AGENT_FILE_STEMS=""
  for f in "$AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    stem="${f##*/}"; stem="${stem%.md}"
    AGENT_FILE_STEMS="${AGENT_FILE_STEMS}${stem}"$'\n'
  done
  # 生成の前提（空虚な真の禁止）: claude/agents/*.md が0件ならロースターが
  # 成立しないので、後続の判定に進む前にここで fail にする。
  stems_present=0
  [ -n "$AGENT_FILE_STEMS" ] && stems_present=1
  assert_true "生成の前提: claude/agents/*.md が1件以上ある（0件ならロースター生成不能）" "$stems_present"

  ROSTER_LINES=()
  while IFS= read -r role_name; do
    [ -n "$role_name" ] || continue
    if [ "$role_name" = "leader" ]; then
      ROSTER_LINES+=("role.leader: configured model=t-opus-high")
    else
      ROSTER_LINES+=("role.${role_name}: unknown")
    fi
  done <<ROSTER_EOF
$CORE_ROLE_NAMES
$AGENT_FILE_STEMS
ROSTER_EOF

  COMPLETE_ROSTER="$(mktemp -d)/complete-roster.md"
  make_v2_profile "$COMPLETE_ROSTER" "${ROSTER_LINES[@]}"

  out="$(resolve_v2 "$COMPLETE_ROSTER")"  || true
  # bash 3.2(macOS既定)では`$(case ... esac)`のような command substitution
  # 内caseの構文解析に既知の不具合があるため、他のテスト（22番等）と同じく
  # caseを独立文として使い、結果を変数へ代入する方式に揃える。
  head_ok=0
  case "$out" in
    OK*) head_ok=1 ;;
  esac
  assert_eq "先頭フィールドはOK（プロファイル自体は妥当）" "1" "$head_ok"
  assert_not_contains "role.vault-scribeで揃えればADVISORY:V1-aが出ない" "$out" "ADVISORY:V1-a"
}

echo "=== 58b. V1-aマニフェスト(結合・回帰防止・対照実験): 完全ロースターのうち'role.vault-scribe'の1行だけを旧キー'role.scribe'へ差し替えると、他は一切変えていないのにADVISORY:V1-aが出るようになる（受入条件どおり・2026-09-03本人裁定: 特別な互換処理は入れない＝'行を書かなかった職種はunknown'の既存規則に従い、vault-scribeはVACANT_UNKNOWN・scribeはマニフェストに無いキーとしてV1-a advisoryに出る。Codexレビュー指摘・Minor対応: 当初はleaderとscribeの2行だけの疎なプロファイルで検証しており、他の10職種が欠けていること自体でもV1-aが出てしまうため『role.scribeへの置換だけが原因』というこの受入条件を厳密に隔離できていなかった。58.の完全ロースターから1行だけ差し替える対照実験にすることで、原因を旧キーの使用だけに絞り込む） ==="
{
  # 58.で生成した完全ロースター（ROSTER_LINES）から、'role.vault-scribe'の
  # 行だけを'role.scribe'（旧キー）へ差し替える。他の行（leader含む）は58.と
  # 完全に同一。vault-scribeは固定職種なのでここでの名指しは可。
  OLD_KEY_LINES=()
  replaced=0
  for line in "${ROSTER_LINES[@]}"; do
    if [ "$line" = "role.vault-scribe: unknown" ]; then
      OLD_KEY_LINES+=("role.scribe: unknown"); replaced=1
    else
      OLD_KEY_LINES+=("$line")
    fi
  done
  assert_true "対照実験の前提: 58.のロースターに role.vault-scribe の行がある（差し替え対象が存在する）" "$replaced"

  OLD_KEY_ROSTER="$(mktemp -d)/old-key-roster.md"
  make_v2_profile "$OLD_KEY_ROSTER" "${OLD_KEY_LINES[@]}"

  out="$(resolve_v2 "$OLD_KEY_ROSTER")"  || true
  assert_contains "58.の完全ロースターと1行しか違わないのに、旧キー'role.scribe'のままではADVISORY:V1-aが出る（改名を促す）" "$out" "ADVISORY:V1-a"
  assert_contains "vault-scribeはマニフェストにあるがrole表に無いためVACANT_UNKNOWNに出る" "$out" "vault-scribe"
}

echo "=== 59. 方針変更の反映確認: 旧方式の対応表（AGENT_FILE_TO_ROLE・ROLE_LOCAL_AGENT_FILE）がコードから完全に撤去されている（2026-09-03本人裁定・方針変更。将来誰かが対応表方式を再導入する回帰を検知する） ==="
{
  result="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 - <<'PYEOF'
import profile_resolve as pr

print("has_agent_file_to_role=" + str(hasattr(pr, "AGENT_FILE_TO_ROLE")))
print("has_role_local_agent_file=" + str(hasattr(pr, "ROLE_LOCAL_AGENT_FILE")))
PYEOF
)"
  assert_contains "AGENT_FILE_TO_ROLE対応表は存在しない" "$result" "has_agent_file_to_role=False"
  assert_contains "ROLE_LOCAL_AGENT_FILE対応表は存在しない" "$result" "has_role_local_agent_file=False"
}

echo "=== 60. V1-b直接検証: role_definition_exists('vault-scribe', 'subagent', agents_dir)が対応表を介さずagents_dir配下を職種名そのままで引いて実在有無を正しく判定する（'scribe'という旧職種名では定義ファイルが無いと判定される＝職種名＝ファイル名の不変条件の直接確認） ==="
{
  result="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 - "$AGENTS_DIR" <<'PYEOF'
import sys
import profile_resolve as pr

agents_dir = sys.argv[1]
print("vault_scribe=" + str(pr.role_definition_exists("vault-scribe", "subagent", agents_dir)))
print("scribe=" + str(pr.role_definition_exists("scribe", "subagent", agents_dir)))
PYEOF
)"
  assert_contains "'vault-scribe'はagents_dir配下にvault-scribe.mdがあるためTrue" "$result" "vault_scribe=True"
  assert_contains "旧職種名'scribe'はscribe.mdが無いためFalse（対応表による救済はしない）" "$result" "scribe=False"
}

# ============================================================================
# 61番以降: 3モード体制（3モード体制-設計-2026-09-06.md／同要件-2026-09-05.md）
# の team_mode スロット・開幕1行・改名対応のユニット・結合テスト。
# ============================================================================

echo "=== 61. FX-P1〜P3: resolver単体・team_modeがsolo/lean/fullのときTEAM_MODE:がそれぞれ1つだけ現れexit0（AC-1①） ==="
{
  for v in solo lean full; do
    FXP="$(mktemp -d)/fxp-$v.md"
    make_v2_profile "$FXP" \
      "role.leader: configured model=t-opus-high"
    sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=$v/" "$FXP"
    # ⚠️ `out="$(cmd)" || true`は`||`の右辺が常に成功するため直後の`$?`は
    # 常に0になり、resolve_v2自身の終了コードを検証できない（Codex一次
    # レビュー指摘・MAJOR対応）。if/elseで実際の終了コードを取る。
    if out="$(resolve_v2 "$FXP")"; then rc=0; else rc=$?; fi
    assert_contains "FX-P$([ "$v" = solo ] && echo 1 || { [ "$v" = lean ] && echo 2 || echo 3; }): TEAM_MODE:${v}が現れる" "$out" "TEAM_MODE:${v}"
    assert_eq "FX-P(${v}): exit0（AC-1①）" "0" "$rc"
    head_ok=0
    case "$out" in OK*) head_ok=1 ;; esac
    assert_eq "FX-P(${v}): 先頭フィールドはOK" "1" "$head_ok"
    # TEAM_MODE:はちょうど1回だけ現れる（重複が無いこと）。
    count="$(printf '%s' "$out" | grep -o 'TEAM_MODE:' | wc -l | tr -d ' ')"
    assert_eq "FX-P(${v}): TEAM_MODE:はちょうど1回だけ現れる" "1" "$count"
  done
}

echo "=== 62. FX-P4〜P5: resolver単体・team_modeがunknown/unavailableならTEAM_MODE:unknown・exit0（AC-2） ==="
{
  FXP4="$(mktemp -d)/fxp4.md"
  make_v2_profile "$FXP4" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unknown/" "$FXP4"
  if out="$(resolve_v2 "$FXP4")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P4(team_mode:unknown): TEAM_MODE:unknownが出る" "$out" "TEAM_MODE:unknown"
  assert_eq "FX-P4: exit0（AC-2）" "0" "$rc"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-P4: 先頭フィールドはOK" "1" "$head_ok"

  FXP5="$(mktemp -d)/fxp5.md"
  make_v2_profile "$FXP5" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unavailable/" "$FXP5"
  if out="$(resolve_v2 "$FXP5")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P5(team_mode:unavailable): TEAM_MODE:unknownが出る" "$out" "TEAM_MODE:unknown"
  assert_eq "FX-P5: exit0（AC-2）" "0" "$rc"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-P5: 先頭フィールドはOK" "1" "$head_ok"
}

echo "=== 63. FX-P6〜P7: resolver単体・team_modeの値形式違反はMINIMAL・exit1・TEAM_MODE:が出ない（AC-3） ==="
{
  FXP6="$(mktemp -d)/fxp6.md"
  make_v2_profile "$FXP6" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=solo,lean/" "$FXP6"
  if out="$(resolve_v2 "$FXP6")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P6(カンマ列挙): MINIMALになる" "$out" "MINIMAL"
  assert_eq "FX-P6: exit1（AC-3）" "1" "$rc"
  assert_not_contains "FX-P6: TEAM_MODE:は出ない" "$out" "TEAM_MODE:"

  FXP7="$(mktemp -d)/fxp7.md"
  make_v2_profile "$FXP7" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=quick/" "$FXP7"
  if out="$(resolve_v2 "$FXP7")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P7(未知の語): MINIMALになる" "$out" "MINIMAL"
  assert_eq "FX-P7: exit1（AC-3）" "1" "$rc"
  assert_not_contains "FX-P7: TEAM_MODE:は出ない" "$out" "TEAM_MODE:"
}

echo "=== 64. known-keysがSCHEMA_VERSION:7・FIXED:にteam_mode/machine_roleを含み廃止5キーを含まない・要素数は5（配役表-能力軸整理-設計-2026-09-07.md §3・代替配役の層と禁止モデル列挙の層の撤去-設計-2026-09-16.mdでschema 6→7。要件AC-1・AC-2の基本口Kの実測はtest-core-docs-placeholder-schema.shが担う） ==="
{
  kk="$(python3 "$PROFILE_LIB" known-keys)"
  assert_contains "known-keys: SCHEMA_VERSION:7" "$kk" "SCHEMA_VERSION:7"
  fixed_line="$(printf '%s' "$kk" | grep '^FIXED:')"
  assert_contains "known-keys: FIXED:にteam_modeを含む" "$fixed_line" "team_mode"
  assert_contains "known-keys: FIXED:にmachine_roleを含む" "$fixed_line" "machine_role"
  # ⚠️ 廃止済み能力軸キー名をソースへ直接書かない（AC-5の0件検査に自分自身が
  # 引っかかるため）。実行時に文字列を組み立てる。
  _underscore='_'
  _retired_key="git${_underscore}role"
  assert_not_contains "known-keys: FIXED:に廃止済み能力軸キーを含まない（本人決定Decisions/2026-09-07-profile-axes-consolidation対象の1つ）" "$fixed_line" "$_retired_key"
  n="$(printf '%s' "${fixed_line#FIXED:}" | tr ',' '\n' | grep -c .)"
  assert_eq "known-keys: FIXED:の要素数は5（メタ2＋能力軸3）" "5" "$n"

  # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 上のcontains/件数
  # チェックだけでは、誤った5キーへ全体が同時に変わっても通ってしまう
  # （例: team_mode/machine_roleが偶然両方含まれる別の5キー集合）。
  # 要件AC-1が定めるリテラル5キー集合と、ソート済み文字列として直接比較する。
  actual_sorted="$(printf '%s' "${fixed_line#FIXED:}" | tr ',' '\n' | sort | tr '\n' ',')"
  expected_sorted="$(printf 'schema_version\nprofile_slug\nteam_mode\nno_read_paths\nmachine_role\n' | sort | tr '\n' ',')"
  assert_eq "AC-1: known-keysのFIXED集合が期待5キー(リテラル集合)と完全一致する" "$expected_sorted" "$actual_sorted"
}

# FR-11・FR-12（要件v1.2.1・タスク2）: 🧭モード行の末尾セグメント（bootstrap-
# vault.sh側の実装と同じ固定書式）を組み立てるヘルパー。BOOTSTRAP_ENABLE_
# LOCAL_PROFILE=1で実体プロファイルを解決したとき、4本の固定文面（solo/
# lean/full/未確定）の末尾にこの1セグメントが付く（行数は増やさない＝
# ちょうど1行のまま）。
mode_success_segment() {  # $1=schema_version $2=machine_role
  printf '｜配役表＝OK schema_version=%s machine_role=%s 照会＝python3 ~/work/takumi009-ai-env/claude/hooks/lib/role_candidates.py [--role <職種>]' "$1" "$2"
}
mode_failure_segment() {  # $1=区分コード（T1/SYMLINK/T5/T4-LEGACY/UNKNOWN_EXTRA等）
  printf '｜配役表＝利用不可（%s）＝最小能力として振る舞う・ワーカー起動は本人確認へ倒す' "$1"
}

echo "=== 65. FX-I1〜I3: bootstrap結合・3モードの開幕1行がそれぞれちょうど1行現れ、他2モードは0行（AC-6①）。2026-09-17 FR-11対応でモード行末尾に配役表セグメントが付く形へexpect=を更新 ==="
{
  # ⚠️ 「ちょうど1行」の計数は`grep -Fx -c`で行全体の完全一致を見る。
  # `-F`のみ（部分一致）だと、開幕行の末尾に余計な文言が付いても
  # 「含む」判定で1件とカウントしてしまい、末尾改変を見逃す偽陽性経路になる
  # （検証職・第3巡MAJOR指摘4の反映。本セクション以降の全`$UNCONFIRMED`
  # 計数も同様に`-Fx`へ揃える）。
  for v in solo lean full; do
    VD="$(mktemp -d)"; make_full_vault "$VD"
    FXI="$(mktemp -d)/fxi-$v.md"
    make_v2_profile "$FXI" \
      "role.leader: configured model=t-opus-high"
    sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=$v/" "$FXI"
    ctx="$(run_bootstrap_with_profile "$VD" "$FXI")"

    case "$v" in
      solo) expect='🧭 現在＝単独モード（リーダーが全工程を自分で行います。第三者検証はありません）。他のモード＝軽量／フル。切り替えたいときは言ってください' ;;
      lean) expect='🧭 現在＝軽量モード（実装者と検証職を置き、適用工程ごとに1巡で回します）。他のモード＝単独／フル。切り替えたいときは言ってください' ;;
      full) expect='🧭 現在＝フルモード（職種ごとに担当を立て、指摘が収まるまで検証を回します）。他のモード＝単独／軽量。切り替えたいときは言ってください' ;;
    esac
    # FX-Iのfixture（V2_BASE）はschema_version=7・machine_role=mainで解決OK。
    expect="${expect}$(mode_success_segment 7 main)"
    assert_contains "FX-I(${v}): 期待文字列と完全一致する行が含まれる" "$ctx" "$expect"
    n="$(printf '%s' "$ctx" | grep -Fx -c "$expect" || true)"
    assert_eq "FX-I(${v}): 期待文字列の行がちょうど1行" "1" "$n"
    total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
    assert_eq "FX-I(${v}): 🧭で始まる行が合計ちょうど1行（他モードは0行）" "1" "$total_mode_lines"
    rm -rf "$VD"
  done
}

echo "=== 66. FX-I4・FX-I6: bootstrap結合・team_modeがunknown、またはresolveがMINIMALのときは未確定行がちょうど1行（AC-7）。2026-09-17 FR-11/FR-12対応でセグメント込みのexpect=へ更新 ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'

  VD="$(mktemp -d)"; make_full_vault "$VD"
  FXI4="$(mktemp -d)/fxi4.md"
  make_v2_profile "$FXI4" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unknown/" "$FXI4"
  ctx="$(run_bootstrap_with_profile "$VD" "$FXI4")"
  # ⚠️ FX-I4はteam_mode自体が"unknown"状態なだけで、配役表全体の解決
  # （schema_version/machine_role）は成功する（FXI4はrole.leader・
  # machine_role等は正常なまま）＝モード行は「未確定」固定文面＋成功セグメント。
  fxi4_expect="${UNCONFIRMED}$(mode_success_segment 7 main)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$fxi4_expect" || true)"
  assert_eq "FX-I4(team_mode:unknown): 未確定行(成功セグメント込み)がちょうど1行" "1" "$n"
  total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "FX-I4: 🧭行の合計もちょうど1行（3モードの行は0行）" "1" "$total_mode_lines"
  rm -rf "$VD"

  # FX-I6: resolveがMINIMALを返す実体（既存のT5＝既知キー欠落を流用する）。
  VD2="$(mktemp -d)"; make_full_vault "$VD2"
  FXI6="$(mktemp -d)/fxi6.md"
  make_v2_profile "$FXI6" \
    "role.leader: configured model=t-opus-high"
  python3 - "$FXI6" <<'PYEOF'
import sys
path = sys.argv[1]
lines = [l for l in open(path).read().splitlines() if not l.startswith("machine_role:")]
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  # FX-I6は解決そのものが失敗する（T5＝既知キーmachine_role欠落）ので
  # モード行は「未確定」固定文面＋失敗セグメント（区分=T5）になる。
  UNCONFIRMED="${UNCONFIRMED}$(mode_failure_segment T5)"
  ctx="$(run_bootstrap_with_profile "$VD2" "$FXI6")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED" || true)"
  assert_eq "FX-I6(MINIMAL/T5): 未確定行(失敗セグメント込み)がちょうど1行" "1" "$n"
  total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "FX-I6: 🧭行の合計もちょうど1行（3モードの行は0行）" "1" "$total_mode_lines"
  rm -rf "$VD2"
}

echo "=== 67. FX-R1・FX-R2（AC-10）: 退役キー'primary-reviewer'はV1-bで空席、改名後'verifier'はagents/verifier.mdが実在するので同じ行の2件目の候補が採用される ==="
{
  FXR1="$(mktemp -d)/fxr1.md"
  make_v2_profile "$FXR1" \
    "role.leader: configured model=t-opus-high" \
    "role.primary-reviewer: configured model=t-opus-high"
  out="$(resolve_v2 "$FXR1")"  || true
  assert_contains "FX-R1(陰性): VACANT:にprimary-reviewerが出る" "$out" "VACANT:primary-reviewer"
  assert_contains "FX-R1: VACANT_REASONがprimary-reviewer=V1-b" "$out" "VACANT_REASON:primary-reviewer=V1-b"

  FXR2="$(mktemp -d)/fxr2.md"
  make_v2_profile "$FXR2" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-opus,t-opus-high"
  # bedrock.envを与えない(ABSENT=disabled)ので1件目(bedrock-opus)はV9-dで
  # 使用不可・2件目(t-opus-high)はagents/verifier.mdが実在するので使用可。
  out="$(resolve_v2 "$FXR2")"  || true
  assert_not_contains "FX-R2(陽性): 1件目が使用不可でも2件目で採用されVACANT:に現れない" "$out" "VACANT:verifier"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-R2: 先頭フィールドはOK（exit0）" "1" "$head_ok"
}

echo "=== 68. §6.3縮退経路の回帰(ID無し・要件のfixture表とは別枠): BOOTSTRAP_ENABLE_LOCAL_PROFILE=0／LEGACY_V1(v1実体)／UNKNOWN_EXTRAを伴うOK行のいずれも、未確定行がちょうど1行・3モードの行は0行。2026-09-17 FR-11/FR-12対応で②③はセグメント込みのexpect=へ更新（①はBOOTSTRAP_ENABLE_LOCAL_PROFILE=0で解決自体を行わないためセグメント無しのまま） ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'

  # ①BOOTSTRAP_ENABLE_LOCAL_PROFILE=0（解決そのものを行わない）。
  VD="$(mktemp -d)"; make_full_vault "$VD"
  ctx="$(run_bootstrap "$VD")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED" || true)"
  assert_eq "①ゲート無効: 未確定行(セグメント無し。解決自体を行わないため)がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "①ゲート無効: 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD"

  # ②旧版（T4-LEGACY。schema_versionの行が無い実体＝team_modeという概念自体
  # を機械が読めない）。
  VD2="$(mktemp -d)"; make_full_vault "$VD2"
  V1P="$(mktemp -d)/v1legacy.md"
  cat > "$V1P" <<'EOF'
---
team_mode: 本人
no_read_paths: ~/work/old
machine_role: 本人
---
EOF
  ctx="$(run_bootstrap_with_profile "$VD2" "$V1P")"
  unconfirmed_t4legacy="${UNCONFIRMED}$(mode_failure_segment T4-LEGACY)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$unconfirmed_t4legacy" || true)"
  assert_eq "②旧版(T4-LEGACY): 未確定行(失敗セグメント込み)がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "②旧版(T4-LEGACY): 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD2"

  # ③UNKNOWN_EXTRAを伴うOK行（team_mode自体は正しく読めていても、未知キーが
  # あれば必読除外・最小能力へ倒すので未確定行になる）。
  VD3="$(mktemp -d)"; make_full_vault "$VD3"
  FXUE="$(mktemp -d)/fxue.md"
  make_v2_profile "$FXUE" \
    "role.leader: configured model=t-opus-high"
  python3 - "$FXUE" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "future_key_v5: configured value=something")
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  ctx="$(run_bootstrap_with_profile "$VD3" "$FXUE")"
  unconfirmed_unknown_extra="${UNCONFIRMED}$(mode_failure_segment UNKNOWN_EXTRA)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$unconfirmed_unknown_extra" || true)"
  assert_eq "③UNKNOWN_EXTRA: 未確定行(失敗セグメント込み)がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "③UNKNOWN_EXTRA: 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD3"
}

# ⚠️ §10.3-10（開幕1行の文面がcore-conduct.mdと一致する）は
# tests/test-agent-definitions.sh 側の検査項目として実装した（設計§10.3の
# 収容先指定どおり）。本ファイルからは重複させない。

echo "=== 70. §10.5: builtinだけで書けている（BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLYは外部プロセスを1つも起こさない） ==="
{
  SPY0="$(mktemp -d)"
  for cmd in python3 jq wc grep sed awk tail cat tr date sort basename dirname readlink diff; do
    real="$(resolve_real_cmd_for_spy "$cmd")"
    [ -z "$real" ] && continue
    cat > "$SPY0/$cmd" <<EOF
#!/bin/bash
printf '%s\n' "$cmd" >> "$SPY0/calls.log"
exec "$real" "\$@"
EOF
    chmod +x "$SPY0/$cmd"
  done
  : > "$SPY0/calls.log"
  PATH="$SPY0" BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1 "$REAL_BASH" "$SCRIPT" </dev/null >/dev/null
  # ⚠️ resolve_bootstrap_self_dir()（symlink解決・全エントリポイント共通の
  # 既存処理）が1回だけ外部の`dirname`を呼ぶため、これは新設部分より前の
  # 前提処理として許容する（BOOTSTRAP_PRINT_KNOWN_KEYS_ONLYと共有する既存の
  # オーバーヘッドであって、team_mode機能が新たに増やした外部プロセスではない）。
  # ⚠️ ここで見るのは「dirname以外が1つも呼ばれていないこと」＝
  # compose_team_mode_line()（4パターンの文面組み立て）だけがbuiltinだけで
  # 書けている証明（Codex一次レビュー指摘・MAJOR対応で訂正: 本フックは
  # 値の取り出し=OK行からのTEAM_MODE:抽出ロジックには到達しない——その
  # コードはこの早期exitより後段のDIRECTIVE組み立て内にあるため）。値の
  # 取り出し自体がbuiltinだけであることは、後段のテスト71（AC-1②・実際の
  # SessionStart全体を走らせて外部プロセス総数が変更前から増加しないことを
  # 見る。実測は29→28＝設計v1.5反映済み）が間接的に証明する。
  calls="$(cat "$SPY0/calls.log")"
  assert_eq "BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1: dirname以外の外部プロセスは0件" "" "$(printf '%s\n' "$calls" | grep -v '^dirname$' | grep -v '^$' || true)"
  rm -rf "$SPY0"
}

echo "=== 71. AC-1②/NFR-1: SessionStart(schema6・正常分岐)が起こす外部プロセス数が、変更前(段階2直前コミットのschema3)から増加しない（実測29→29。配役表-能力軸整理-設計-2026-09-07.md §10.3・2026-09-08 モデル定義ファイルと候補指定対応で候補名注入のawk1段ぶん再実測） ==="
{
  SPY="$(mktemp -d)"
  BASE_WT=""
  FAKE_HOME_71=""
  cleanup_71() {
    [ -n "$BASE_WT" ] && [ -d "$BASE_WT" ] && git -C "$REPO_ROOT" worktree remove --force "$BASE_WT" >/dev/null 2>&1
    rm -rf "$SPY" "${BASE_WT:-}" "${FAKE_HOME_71:-}" 2>/dev/null
  }
  # ⚠️ ここは関数ではなく単なる{ }ブロックなので`trap ... RETURN`は発火しない。
  # EXIT trapを後始末の保険にしつつ、正常系ではブロック末尾で明示的に呼ぶ。
  trap cleanup_71 EXIT

  for cmd in python3 jq wc grep sed awk tail cat tr date sort basename dirname readlink diff; do
    real="$(resolve_real_cmd_for_spy "$cmd")"
    [ -z "$real" ] && continue
    cat > "$SPY/$cmd" <<EOF
#!/bin/bash
printf '%s\n' "$cmd" >> "\$SPY_CALLS_LOG"
exec "$real" "\$@"
EOF
    chmod +x "$SPY/$cmd"
  done

  # 変更前（旧コミット）の bootstrap は settings.json と配役表の整合を毎回比較していた（現行は撤去済み）。
  # 旧側が「警告なし」の正常分岐を通るよう、role.leader: model=opus-noeffort（effort未指定）と一致する
  # settings.json を偽 HOME の既定パス（$HOME/.claude/settings.json）に置く。
  FAKE_HOME_71="$(mktemp -d)"
  mkdir -p "$FAKE_HOME_71/.claude"
  cat > "$FAKE_HOME_71/.claude/settings.json" <<'EOF'
{"model": "claude-opus-5"}
EOF

  # bootstrapとjqの終了コードを分離検査するためのヘルパー（Codex一次レビュー
  # 指摘・MAJOR対応: パイプ全体を1つのcommand substitutionにしていたため
  # bootstrap自身の終了コードを個別に見られなかった）。
  # 戻り値: 標準出力へJSON全体を返す。$? はbootstrap自身の終了コード。
  run_bootstrap_capture_rc() {
    local out_json="$1"; shift
    echo '{"session_id":"test-session-0000"}' | "$REAL_BASH" "$@" > "$out_json"
  }

  # 変更後（現worktree・schema5）を測る。
  VD="$(mktemp -d)"; make_full_vault "$VD"
  FXP1="$(mktemp -d)/fxp1-spy.md"
  make_v2_profile "$FXP1" \
    "role.leader: configured model=opus-noeffort"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=solo/" "$FXP1"
  AFTER_LOG="$(mktemp -d)/calls-after.log"; : > "$AFTER_LOG"
  AFTER_JSON="$(mktemp -d)/after.json"
  OBS71="$(mktemp -d)"
  PATH="$SPY" SPY_CALLS_LOG="$AFTER_LOG" \
    BOOTSTRAP_VAULT="$VD" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
    VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
    MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
    MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
    HEALTH_OBSERVATION_FILE="$OBS71/session-observation.json" \
    BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$FXP1" \
    run_bootstrap_capture_rc "$AFTER_JSON" "$SCRIPT"
  after_bootstrap_rc=$?
  after_ctx="$(jq -r '.hookSpecificOutput.additionalContext' "$AFTER_JSON")"
  after_count="$(wc -l < "$AFTER_LOG" | tr -d ' ')"
  assert_eq "変更後: bootstrap自身の終了コードが0" "0" "$after_bootstrap_rc"
  assert_contains "変更後: 正常分岐(OK・警告なし)を通っている" "$after_ctx" "🧭 現在＝単独モード"
  after_profile_block="$(printf '%s\n' "$after_ctx" | awk '/^【ローカル実体プロファイル】$/{flag=1; next} flag')"
  # 2026-09-08 モデル定義ファイルと候補指定対応: 候補名の注入行
  # （ℹ️ 職種ごとのモデル候補…）は本文中に固定の案内「⚠️ spawn のたびに候補
  # から定義名を1つ選ぶこと」を含む契約（設計§4(b)）。これは実際の警告では
  # なく毎回出る固定文言なので、その1行を除いてから「真の警告0件」を見る。
  after_profile_block_no_candidates="$(printf '%s\n' "$after_profile_block" | grep -v '^ℹ️ 職種ごとのモデル候補')"
  assert_not_contains "変更後: 【ローカル実体プロファイル】内に⚠️警告が無い（真に警告0件。ℹ️の候補注入行・V1-a advisoryはrole.leaderのみ宣言する最小fixtureゆえの想定内の情報行で許容する）" "$after_profile_block_no_candidates" "⚠️"

  # 変更前（段階2直前コミット・schema3）を隔離worktreeで測る。
  BASE_WT="$(mktemp -d)/aienv-base-wt"
  git -C "$REPO_ROOT" worktree add --detach "$BASE_WT" 3583015b635c209f8ec95fdc187c72903655bccd >/dev/null 2>&1
  BASE_SCRIPT="$BASE_WT/claude/hooks/bootstrap-vault.sh"
  BASE_AGENTS="$BASE_WT/claude/agents"
  VD2="$(mktemp -d)"; make_full_vault "$VD2"
  FXP0="$(mktemp -d)/fxp0-spy.md"
  # 2026-09-08 Codexレビュー指摘・BLOCKING-1対応（1巡目）: 本fixtureは
  # 歴史的コミット（3583015b…）の旧role.leader文法をそのまま再現する
  # 必要があるため属性構文自体は変えられないが、AC-14のrepo検索（完成
  # 文字列の直書き禁止）に一致しないよう断片を変数へ分けてから展開する
  # （意図的な歴史再現fixtureであり、本物の旧記法の取りこぼしではない）。
  legacy_role_attr="provider="
  # ⚠️ 代替配役の層と禁止モデル列挙の層の撤去-設計-2026-09-16.md §6.3
  # （r1-#1対応）: 本fixtureは歴史的コミットの旧・禁止モデル列挙キーを
  # そのまま再現する必要があるため、上のlegacy_role_attrと同じ手口で
  # 完成語をソースへ直書きしない（AC-1のrepo検索に一致しないように分割
  # 代入する）。生成されるfixtureの中身は不変。
  legacy_excluded_key="excluded""_models"
  cat > "$FXP0" <<EOF
---
schema_version: 3
profile_slug: authoring
inventory_source: configured value=work-tools-dir  # AC5-ALLOW:FXP0
reviewer:         configured value=codex-mcp
vault_write:      configured value=via-scribe  # AC5-ALLOW:FXP0
vault_scope:      configured value=full
ui.user_call:     configured value=send-message  # AC5-ALLOW:FXP0
git_role:         configured value=aienv-repo:commit  # AC5-ALLOW:FXP0
web_verification: configured value=websearch  # AC5-ALLOW:FXP0
no_read_paths:    configured value=work-old  # AC5-ALLOW:FXP0
${legacy_excluded_key}: configured value=none
role.leader: configured ${legacy_role_attr}anthropic-api model=claude-opus-5
---
EOF
  # 段階2直前コミット（3583015b…）のbootstrap-vault.shは廃止済みの旧
  # マーカーを読む。本テストは「旧マーカーのパスは行継続の途中にあって
  # コメントを付けられない」ため、先に変数へ入れてその代入行にタグを付ける
  # （配役表-能力軸整理-設計-2026-09-07.md §6.4）。
  LEGACY_MARKER_71="/nonexistent-dir/machine-role"  # AC5-ALLOW:FXP0
  BEFORE_LOG="$(mktemp -d)/calls-before.log"; : > "$BEFORE_LOG"
  BEFORE_JSON="$(mktemp -d)/before.json"
  PATH="$SPY" SPY_CALLS_LOG="$BEFORE_LOG" HOME="$FAKE_HOME_71" \
    BOOTSTRAP_VAULT="$VD2" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
    VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
    MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
    AIENV_MACHINE_ROLE_MARKER="$LEGACY_MARKER_71" \
    AIENV_AGENTS_DIR="$BASE_AGENTS" \
    BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$FXP0" \
    run_bootstrap_capture_rc "$BEFORE_JSON" "$BASE_SCRIPT"
  before_bootstrap_rc=$?
  before_ctx="$(jq -r '.hookSpecificOutput.additionalContext' "$BEFORE_JSON")"
  before_count="$(wc -l < "$BEFORE_LOG" | tr -d ' ')"
  assert_eq "変更前: bootstrap自身の終了コードが0" "0" "$before_bootstrap_rc"
  assert_not_contains "変更前: 未知キー警告が出ていない(正常分岐)" "$before_ctx" "未知のキー"
  assert_not_contains "変更前: 解決できません警告が出ていない(正常分岐)" "$before_ctx" "を解決できません"
  before_profile_block="$(printf '%s\n' "$before_ctx" | awk '/^【ローカル実体プロファイル】$/{flag=1; next} flag')"
  assert_not_contains "変更前: 【ローカル実体プロファイル】内に⚠️警告が無い（真に警告0件。ℹ️のV1-a advisoryはrole.leaderのみ宣言する最小fixtureゆえの想定内の情報行で許容する）" "$before_profile_block" "⚠️"

  # ⚠️ リーダー裁定（MINOR-2再裁定・2026-09-08）: 29→28への減少は、本案件で
  # 削除した④の廃止済み旧マーカー読取ブロック（`cat`による外部プロセス1回。
  # 既に呼んでいるresolveの出力からbashのパラメータ展開だけでmachine_role
  # を取り出す実装にしたため不要になった）による正当な減少であり、縮退では
  # ない。設計§10.3の意図＝NFR-1「外部プロセスを増やさない」を判定式として
  # 固定するため、判定は「増加しない」（`after <= before`）とする（設計側は
  # v1.5でこの字面へ揃える予定）。
  # 2026-09-08 B1a「使用率の見える化」（FR-108①・使用率提示B1a-実装-
  # 2026-09-08.md）追記: 本案件はSessionStart注入へ【使用率】ブロックを
  # 新設し、その構築のためpython3 usage_snapshot.pyを1回呼ぶ（実測29→30）。
  # これはprofile_resolve.py側の既存複数呼び出しと同じ設計パターンの新規
  # 機能追加であり、NFR-4（team_mode行の組み立てをbuiltinのみで行う制約）の
  # 対象範囲（配役表-能力軸整理-要件-2026-09-07.md）には含まれない別要件書
  # （ローカルLLM段階経路-要件-2026-09-03.md v20 FR-108①）が要求する新規の
  # 提示口であり、リーダー裁定「設計相当」の範囲内で許容された増加として
  # 承認済みの予算+1を明示的に計上する（無条件で閾値を緩めない＝これ以上の
  # 増加はこの判定式が引き続き検出する）。
  AC1_2_APPROVED_DELTA_2026_09_08=1  # python3 usage_snapshot.py 呼び出し1回（B1a）
  assert_eq "外部プロセス数(変更後)が変更前から承認済み予算(+1・B1a使用率提示)を超えて増加しない（設計§10.3・NFR-1・AC-1②）" "1" \
    "$([ "$after_count" -le "$((before_count + AC1_2_APPROVED_DELTA_2026_09_08))" ] && echo 1 || echo 0)"
  # 設計§10.5⑥「基準値はテスト内に定数として記録する」への対応。
  # 2026-09-08 モデル定義ファイルと候補指定対応の実測値へ更新（変更前29は
  # 不変。変更後は28→29——旧分類呼び出し1回の削減とlist-roles呼び出し
  # 1回の追加は設計どおり相殺されるが、候補名の注入行がlist-rolesの出力を
  # awkで加工する1段（外部プロセス1回）を追加で使うため、net -1+1+1(awk)=+1
  # となり28→29になる。設計側のnet0見積もりはpython3呼び出し数だけを数えて
  # おりawk等のパイプ段を含めていなかった実装レベルの差分＝実装記録
  # モデル定義ファイルと候補指定-実装-2026-09-08.md参照）。
  # 2026-09-08 B1a「使用率の見える化」対応で29→30へ更新（上記の承認済み
  # +1予算どおり）。増やす変更を入れるときはNFR-4との突合を経てから更新
  # すること。
  # 2026-09-17 FR-10・FR-11（要件v1.2.1）対応で30→26へ更新（実測）。
  # 実体プロファイルの全文Read指示（`wc -l`1回）とFR-11で撤去した候補一覧
  # ℹ️行の生成（`python3 profile_resolve.py list-roles`1回＋`awk`1回）が
  # 減った分の正当な減少（この判定式は「増加しない」だけを見るので、
  # NFR-1の趣旨どおり回帰扱いにしない）。
  # 2026-09-19 着手順2 η（bootstrap 縮小）で26→23へ更新（実測）。settings.json 整合比較
  # （python3 2回）と【使用率】ブロック（python3 1回）の撤去に対し、棚卸し①は
  # latest.json 不在で jq を呼ばない＝net -3 の正当な減少。
  # 2026-09-20 health-self-explain（設計 v1.2 §5）で23→26へ更新（実測 net +3）。増＝観測記録の
  # 書込み（jq・mkdir・mv）＋判定機（python3）＋描画（jq）。減＝旧判定の date/jq 呼び出しの撤去と
  # stdin JSON の jq を 2 回→1 回に統合。判定式「増加しない（承認済み予算 +1 を含めて
  # before+1 以下）」は 26 ≤ 30 で維持（NFR-1＝新しい常駐・フックは増やしていない）。
  AC1_2_REFERENCE_COUNT_BEFORE_2026_09_07=29
  AC1_2_REFERENCE_COUNT_AFTER_2026_09_07=26
  if [ "$before_count" != "$AC1_2_REFERENCE_COUNT_BEFORE_2026_09_07" ] || [ "$after_count" != "$AC1_2_REFERENCE_COUNT_AFTER_2026_09_07" ]; then
    echo "  info - 参考値: 変更前${AC1_2_REFERENCE_COUNT_BEFORE_2026_09_07}・変更後${AC1_2_REFERENCE_COUNT_AFTER_2026_09_07}を記録していたが今回は変更前${before_count}・変更後${after_count}だった"
  fi

  cleanup_71
  trap - EXIT
}

# ============================================================================
# 72番以降: 配役表-能力軸整理-要件-2026-09-07.md §7の受入条件のうち、本ファイル
# 担当分（AC-3・AC-4・AC-8・AC-9・AC-11）をfixture単位で直接検証する。
# fixture定義・期待値は同要件書§6.2の表のとおり（FX-P1が共通ベース）。
# ============================================================================

echo "=== 72. AC-3(FR-1): machine_roleの状態enumの陽性2件(FX-P1・FX-P2)・陰性2件(FX-P3・FX-P4) ==="
{
  # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 先頭文字列とexit
  # codeだけでは、fixture表（要件§6.2）が定めるTEAM_MODE:full・UNKNOWN_EXTRA:
  # 不在という残りの期待を固定していなかった。両方を明示的に検査する。
  FXP1_72="$(mktemp -d)/fxp1.md"
  make_v2_profile "$FXP1_72" "role.leader: configured model=t-opus-high"
  rc=0; out="$(resolve_v2 "$FXP1_72")" || rc=$?
  assert_eq "FX-P1: OK<TAB>schema_version=7で始まる" "1" \
    "$([[ "$out" == $'OK\tschema_version=7'* ]] && echo 1 || echo 0)"
  assert_eq "FX-P1: exit 0" "0" "$rc"
  assert_contains "FX-P1: TEAM_MODE:fullを含む" "$out" "TEAM_MODE:full"
  assert_not_contains "FX-P1: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"

  FXP2_72="$(mktemp -d)/fxp2.md"
  make_v2_profile "$FXP2_72" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     configured value=sub/" "$FXP2_72"
  rc=0; out="$(resolve_v2 "$FXP2_72")" || rc=$?
  assert_eq "FX-P2: OK<TAB>schema_version=7で始まる" "1" \
    "$([[ "$out" == $'OK\tschema_version=7'* ]] && echo 1 || echo 0)"
  assert_eq "FX-P2: exit 0" "0" "$rc"
  assert_contains "FX-P2: TEAM_MODE:fullを含む" "$out" "TEAM_MODE:full"
  assert_not_contains "FX-P2: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"

  FXP3_72="$(mktemp -d)/fxp3.md"
  make_v2_profile "$FXP3_72" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     not_adopted/" "$FXP3_72"
  rc=0; out="$(resolve_v2 "$FXP3_72")" || rc=$?
  assert_contains "FX-P3: V7(machine_roleの状態が不正)を含む" "$out" "V7: machine_roleの状態が不正です"
  assert_eq "FX-P3: exit 1" "1" "$rc"

  FXP4_72="$(mktemp -d)/fxp4.md"
  make_v2_profile "$FXP4_72" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     configured value=primary/" "$FXP4_72"
  rc=0; out="$(resolve_v2 "$FXP4_72")" || rc=$?
  assert_contains "FX-P4: V8-b(machine_roleのvalue形式が不正)を含む" "$out" "V8-b: machine_roleのvalue形式が不正です"
  assert_eq "FX-P4: exit 1" "1" "$rc"
}

echo "=== 73. AC-4(FR-5): no_read_pathsの実パス書式の陽性1件(FX-P9)・陰性2件(FX-P10・FX-P11) ==="
{
  FXP9_73="$(mktemp -d)/fxp9.md"
  make_v2_profile "$FXP9_73" "role.leader: configured model=t-opus-high"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=~/work/old,~/Data/private#" "$FXP9_73"
  rc=0; out="$(resolve_v2 "$FXP9_73")" || rc=$?
  assert_eq "FX-P9: OKで始まる（大文字を含む実パスも受理）" "1" \
    "$([[ "$out" == OK* ]] && echo 1 || echo 0)"
  assert_eq "FX-P9: exit 0" "0" "$rc"

  FXP10_73="$(mktemp -d)/fxp10.md"
  make_v2_profile "$FXP10_73" "role.leader: configured model=t-opus-high"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=~/work/old, ~/tmp/x#" "$FXP10_73"
  rc=0; out="$(resolve_v2 "$FXP10_73")" || rc=$?
  assert_contains "FX-P10: T6を含む" "$out" "T6"
  assert_contains "FX-P10: 属性の形式が不正ですを含む" "$out" "属性の形式が不正です"
  assert_eq "FX-P10: exit 1" "1" "$rc"

  FXP11_73="$(mktemp -d)/fxp11.md"
  make_v2_profile "$FXP11_73" "role.leader: configured model=t-opus-high"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=/work/old#" "$FXP11_73"
  rc=0; out="$(resolve_v2 "$FXP11_73")" || rc=$?
  assert_contains "FX-P11: V8-b(no_read_pathsのvalue形式が不正)を含む" "$out" "V8-b: no_read_pathsのvalue形式が不正です"
  assert_eq "FX-P11: exit 1" "1" "$rc"
}

echo "=== 75. AC-9(FR-13): 廃止キー残存時のUNKNOWN_EXTRA契約の陽性1件(FX-P7)・陰性1件(FX-P1) ==="
{
  FXP7_75="$(mktemp -d)/fxp7-ac9.md"
  make_v2_profile "$FXP7_75" "role.leader: configured model=t-opus-high"
  # frontmatter終端(---)の直前に挿入する（末尾に追記すると frontmatter の
  # 外側になってしまうため）。AC5-ALLOW:FX-P7
  python3 - "$FXP7_75" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "git_role: unavailable")  # AC5-ALLOW:FX-P7
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  rc=0; out="$(resolve_v2 "$FXP7_75")" || rc=$?
  assert_contains "FX-P7: R=UNKNOWN_EXTRA:git_roleを含む（機械側は既知キーで解決）" "$out" "UNKNOWN_EXTRA:git_role"  # AC5-ALLOW:FX-P7
  assert_eq "FX-P7: R=exit 0" "0" "$rc"
  ctx="$(run_bootstrap_with_profile "$(mktemp -d)" "$FXP7_75")"
  assert_contains "FX-P7: I=プロファイル利用不可の文言を含む（AI側は降格）" "$ctx" "プロファイル利用不可"
  assert_contains "FX-P7: I=最小能力の文言を含む" "$ctx" "最小能力"

  FXP1_75="$(mktemp -d)/fxp1-ac9.md"
  make_v2_profile "$FXP1_75" "role.leader: configured model=t-opus-high"
  out="$(resolve_v2 "$FXP1_75")"
  assert_not_contains "FX-P1: R=UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"
  ctx="$(run_bootstrap_with_profile "$(mktemp -d)" "$FXP1_75")"
  # FR-10で全文Read指示自体を撤去した。解決成功はFR-11のモード行セグメント
  # （schema_version=・machine_role=・role_candidates.py）で示す。
  assert_not_contains "FX-P1: I=もう全文Readは指示しない（FR-10）" "$ctx" "Readで全文を読むこと"
  assert_contains "FX-P1: I=モード行セグメントにschema_version=が含まれる" "$ctx" "schema_version=7"
  assert_contains "FX-P1: I=モード行セグメントにmachine_role=が含まれる" "$ctx" "machine_role=main"
  assert_contains "FX-P1: I=モード行セグメントに照会コマンド(role_candidates.py)が含まれる" "$ctx" "role_candidates.py"
}

echo "=== 76. AC-11(FR-9): machine_roleがunknownのときだけDIRECTIVEへ保留の1行が増える（FX-P8陽性・FX-P1陰性・同一HOME・同一パスでmachine_roleの値だけを変える） ==="
{
  VD_76="$(mktemp -d)"; make_full_vault "$VD_76"

  # ⚠️ 同一のHOME・同一の実体パスでmachine_roleの値だけを書き換える（AC-11の
  # 判定式どおり）。FX-P1・FX-P8はいずれもrole.leader以外の職種行を書かない
  # ため、VACANT_UNKNOWN/ADVISORY:V1-aが付随する（要件§6.1の注記どおり）。
  # ⚠️ Codex一次レビュー指摘（MAJOR-2・2026-09-07）対応: 従来は「保留の行の
  # 有無」と「保留を除いた行数の一致」を別々に検査しており、要件AC-11が
  # 求める「2本文の差分がちょうど1行」を実際にはdiffしていなかった（AC-11の
  # 意図した検査になっていなかった＝実装側で判定式を緩めていた）。
  # 【ローカル実体プロファイル】ブロックの「配役表の状態」行はresolveの生OK行
  # をそのまま転写する仕様であり、MACHINE_ROLE:の値もその中に含まれるため、
  # machine_roleを変えるとこの1行の内容も変わる（保留の1行の追加とは別の、
  # 既存メカニズムに由来する副作用）。この副作用を打ち消すため、両本文の
  # 診断行中のMACHINE_ROLE:<値>トークンを共通のプレースホルダへ正規化して
  # からdiffする（値そのものの一致は他のテスト＝§75等で別途検査済み）。
  # ⚠️ FR-11対応（2026-09-17）: 🧭モード行の末尾セグメントにも
  # machine_role=<値>が載るため、こちらも同じプレースホルダへ正規化する
  # （さもないとセグメント内の値変化そのものが2本目の差分として現れ、
  # AC-11が見たい「保留行の追加1行だけ」の判定を汚す）。
  FXP_76="$(mktemp -d)/fxp-ac11.md"
  make_v2_profile "$FXP_76" "role.leader: configured model=t-opus-high"
  ctx_p1="$(run_bootstrap_with_profile "$VD_76" "$FXP_76")"

  sed -i '' "s/machine_role:     configured value=main/machine_role:     unknown/" "$FXP_76"
  ctx_p8="$(run_bootstrap_with_profile "$VD_76" "$FXP_76")"

  norm_p1="$(printf '%s\n' "$ctx_p1" | sed -E 's/MACHINE_ROLE:[a-z]+/MACHINE_ROLE:X/; s/machine_role=[a-z]+/machine_role=X/')"
  norm_p8="$(printf '%s\n' "$ctx_p8" | sed -E 's/MACHINE_ROLE:[a-z]+/MACHINE_ROLE:X/; s/machine_role=[a-z]+/machine_role=X/')"

  diff_out="$(diff <(printf '%s\n' "$norm_p1") <(printf '%s\n' "$norm_p8") || true)"
  added_lines="$(printf '%s\n' "$diff_out" | grep -c '^> ' || true)"
  removed_lines="$(printf '%s\n' "$diff_out" | grep -c '^< ' || true)"
  assert_eq "正規化後の差分は追加1行のみ（削除0行）" "1" "$added_lines"
  assert_eq "正規化後の差分に削除は無い" "0" "$removed_lines"
  assert_eq "追加された1行にmachine_roleを含む" "1" \
    "$(printf '%s\n' "$diff_out" | grep '^> ' | grep -q 'machine_role' && echo 1 || echo 0)"

  hold_count_p1="$(printf '%s\n' "$ctx_p1" | grep -c '配役表の machine_role が未確定です' || true)"
  hold_count_p8="$(printf '%s\n' "$ctx_p8" | grep -c '配役表の machine_role が未確定です' || true)"
  assert_eq "FX-P1(main): 保留の行は0回" "0" "$hold_count_p1"
  assert_eq "FX-P8(unknown): 保留の行はちょうど1回" "1" "$hold_count_p8"

  rm -rf "$VD_76"
}

echo "=== 76b. AC-11(FR-9)陰性・MAJOR-1対応: machine_roleがunavailableのときは保留行を出さない（unknownとは区別する） ==="
{
  VD_76B="$(mktemp -d)"; make_full_vault "$VD_76B"

  FXP_76B="$(mktemp -d)/fxp-ac11-unavailable.md"
  make_v2_profile "$FXP_76B" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     unavailable/" "$FXP_76B"
  ctx_unavail="$(run_bootstrap_with_profile "$VD_76B" "$FXP_76B")"

  hold_count_unavail="$(printf '%s\n' "$ctx_unavail" | grep -c '配役表の machine_role が未確定です' || true)"
  assert_eq "machine_role=unavailable: 保留の行は0回（unknownと違い明示的な申告のため）" "0" "$hold_count_unavail"
  assert_contains "machine_role=unavailable: 診断行にはMACHINE_ROLE:unavailableがそのまま出る" "$ctx_unavail" "MACHINE_ROLE:unavailable"

  rm -rf "$VD_76B"
}

echo "=== 77. 設計§11.3新設2件の①: AIENV_MODEL_DEFS_FILEが相対パスならR・L・LD・Cに加えI（bootstrap-vault.sh経由）もT13相当でloudに落ちる（Codexレビュー指摘・MAJOR-3対応・1巡目。R/L/LD/Cの4口はtest-model-definitions.shで既に検証済み） ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'
  VD77="$(mktemp -d)"; make_full_vault "$VD77"
  FXP77="$(mktemp -d)/fxp77.md"
  make_v2_profile "$FXP77" "role.leader: configured model=t-opus-high"
  ctx77="$(run_bootstrap_with_profile "$VD77" "$FXP77" "relative/models.conf")"
  unconfirmed_t13="${UNCONFIRMED}$(mode_failure_segment T13)"
  n77="$(printf '%s' "$ctx77" | grep -Fx -c "$unconfirmed_t13" || true)"
  assert_eq "I(T13): AIENV_MODEL_DEFS_FILEが相対パスだと未確定行(失敗セグメント込み)がちょうど1行（resolve自体がT13でloud失敗する）" "1" "$n77"
  total77="$(printf '%s' "$ctx77" | grep -c '^🧭 現在＝')"
  assert_eq "I(T13): 🧭行の合計もちょうど1行" "1" "$total77"
  rm -rf "$VD77"
}

echo "=== 78. 設計§11.3新設2件の②: 同じ絶対パスのAIENV_MODEL_DEFS_FILEなら、Iを呼び出すcwdを変えても同じ結果になる（Codexレビュー指摘・MAJOR-3対応・1巡目。R/L/LD/Cの4口はtest-model-definitions.shで既に検証済み） ==="
{
  VD78="$(mktemp -d)"; make_full_vault "$VD78"
  FXP78="$(mktemp -d)/fxp78.md"
  make_v2_profile "$FXP78" "role.leader: configured model=t-opus-high"
  ctx78_tmp="$(cd /tmp && run_bootstrap_with_profile "$VD78" "$FXP78" "$SHARED_MODELS_CONF")"
  ctx78_repo="$(cd "$REPO_ROOT" && run_bootstrap_with_profile "$VD78" "$FXP78" "$SHARED_MODELS_CONF")"
  ctx78_vd="$(cd "$VD78" && run_bootstrap_with_profile "$VD78" "$FXP78" "$SHARED_MODELS_CONF")"
  assert_eq "I(cwd不変性): /tmp とREPO_ROOTで同じ結果" "$ctx78_tmp" "$ctx78_repo"
  assert_eq "I(cwd不変性): /tmp とVault作業ディレクトリで同じ結果" "$ctx78_tmp" "$ctx78_vd"
  rm -rf "$VD78"
}

echo "=== 84. 注入本文: ③は欠番・④は vault-scribe の1行・⑥は宣言コマンドを含む1行・【使用率】無し・順序 ①②④⑤⑥ ==="
{
  VD84="$(safe_mktemp_d)" || exit 1
  make_full_vault "$VD84"
  ctx84="$(run_bootstrap "$VD84")"
  n_line84="$(printf '%s\n' "$ctx84" | grep -cE '^⑥ .*cmux-task-declare\.sh set <slug>' || true)"
  assert_eq "84: ⑥は宣言コマンド(set <slug>)を含むちょうど1行" "1" "$n_line84"
  assert_contains "84: ⑥は「宣言済みなら呼び直さない」を残す" "$ctx84" "宣言済みなら呼び直さない"
  assert_contains "84: ⑥は「実行はリーダー」を残す" "$ctx84" "実行はリーダーであってフックではない"
  n_line84_4="$(printf '%s\n' "$ctx84" | grep -cE '^④ .*vault-scribe' || true)"
  assert_eq "84: ④は vault-scribe を含むちょうど1行" "1" "$n_line84_4"
  n_line84_3="$(printf '%s\n' "$ctx84" | grep -c '^③ ' || true)"
  assert_eq "84: ③は欠番（番号は詰めない）" "0" "$n_line84_3"
  assert_contains "84: ①が残る" "$ctx84" "① タスクに着手する前に"
  assert_contains "84: ②が残る" "$ctx84" "② 上記を読み終えるまで"
  assert_contains "84: ⑤が残る" "$ctx84" "⑤"
  assert_not_contains "84: 【使用率】ブロックは出ない（発言ごとの usage-inject.sh が正）" "$ctx84" "【使用率】"

  # 行位置の比較で ①→②→④→⑤→⑥ の順序不変を検査する（並べ替えるとここで落ちる）。
  assert_ascending_line_positions "84: ①→②→④→⑤→⑥の順序が保たれる" "$ctx84" \
    "①" "②" "④" "⑤" "⑥"

  rm -rf "$VD84"
}

echo "=== 85. FR-48/AC-59: フックは宣言コマンド(set)を実行せず、宣言記録も作らない ==="
{
  VD85="$(safe_mktemp_d)" || exit 1
  make_full_vault "$VD85"

  # PATH先頭にマーカーを書くだけの偽cmux-task-declare.shを置く。
  # フックが誤ってこれを呼び出せばMARKER85が作られる（design.md §17.3）。
  SPY_DIR85="$(safe_mktemp_d)" || exit 1
  MARKER_DIR85="$(safe_mktemp_d)" || exit 1
  MARKER85="$MARKER_DIR85/declare-was-called.marker"
  cat > "$SPY_DIR85/cmux-task-declare.sh" <<EOF
#!/bin/bash
touch "$MARKER85"
EOF
  chmod +x "$SPY_DIR85/cmux-task-declare.sh"

  # 差分レビュー指摘#6: PATH上だけでなく、注入文に書かれている固定パス
  # $HOME/work/takumi009-ai-env/cmux/cmux-task-declare.sh にもスパイを置く
  # （固定パスを直接実行する誤実装がPATHスパイを迂回してもここで捕まる。
  # cmux-session-todo v3で宣言CLIの実体がdotfilesからai-envへ移設された
  # ことに合わせ、スパイの置き場も新しい既定パスへ更新した）。
  # 実機の~/work/takumi009-ai-envには一切触れないよう、隔離HOMEを別途用意する。
  FAKE_HOME85="$(safe_mktemp_d)" || exit 1
  mkdir -p "$FAKE_HOME85/work/takumi009-ai-env/cmux"
  MARKER_DIR85B="$(safe_mktemp_d)" || exit 1
  MARKER85B="$MARKER_DIR85B/declare-was-called-fixedpath.marker"
  cat > "$FAKE_HOME85/work/takumi009-ai-env/cmux/cmux-task-declare.sh" <<EOF
#!/bin/bash
touch "$MARKER85B"
EOF
  chmod +x "$FAKE_HOME85/work/takumi009-ai-env/cmux/cmux-task-declare.sh"

  # CMUX_TASK_STATE相当の宣言記録ファイル（フックが誤って書けば存在するようになる）。
  STATE_DIR85="$(safe_mktemp_d)" || exit 1
  STATE85="$STATE_DIR85/workspaces.json"

  ctx85="$(HOME="$FAKE_HOME85" PATH="$SPY_DIR85:$PATH" CMUX_TASK_STATE="$STATE85" run_bootstrap "$VD85")"

  assert_contains "85: 本文自体は壊れず出力される" "$ctx85" "【セッション開始ブートストラップ｜ハーネス強制注入】"

  marker_exists85=0
  if [ -e "$MARKER85" ]; then marker_exists85=1; fi
  assert_eq "85: 偽cmux-task-declare.sh(PATH経由)は呼ばれない（マーカー未生成）" "0" "$marker_exists85"

  marker_exists85b=0
  if [ -e "$MARKER85B" ]; then marker_exists85b=1; fi
  assert_eq "85: 偽cmux-task-declare.sh(固定パス \$HOME/work/takumi009-ai-env/cmux/経由)も呼ばれない" "0" "$marker_exists85b"

  state_exists85=0
  if [ -e "$STATE85" ]; then state_exists85=1; fi
  assert_eq "85: 宣言記録ファイルも作られない" "0" "$state_exists85"

  rm -rf "$VD85" "$SPY_DIR85" "$MARKER_DIR85" "$FAKE_HOME85" "$MARKER_DIR85B" "$STATE_DIR85"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
