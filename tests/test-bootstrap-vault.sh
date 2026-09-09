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
# 単調増加であることを検査する（AC-59: ①→②→③→④→⑤→⑥の順序不変。
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
# 異常な値を返した場合の防御をtest-next-pane-resolve.shのWORK_DIRガードと
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
# 2026-09-07 配役表-能力軸整理対応: ④死活検知のサブ機スキップ判定は
# 旧マーカーファイルから配役表の能力軸`machine_role`へ移った
# （配役表-能力軸整理-設計-2026-09-07.md §4.2・§4.3）。本ヘルパーは
# BOOTSTRAP_ENABLE_LOCAL_PROFILE=0固定のため機役割は常にunknown（=サブ機
# ではない）扱いになる。④の機役割別の振る舞いを検証するテストは
# run_bootstrap_health4()を使う。
# 2026-09-02: BOOTSTRAP_ENABLE_LOCAL_PROFILEのコード側既定値が0→1へ変更された
# （案A採用・rollout-runbook.md現行トラック§7）。本ヘルパーはP1機構（ローカル
# 実体プロファイル）を検証しない大多数のテストで使われるため、既定値の変更に
# よって実機の$HOME/.config/takumi009-ai-env/profile.mdを不用意に読みに行き
# 非決定的になる事故を防ぐ目的で、ここでは明示的に0を指定して従来どおり
# 無効固定にする（P1機構自体の回帰は#37「ゲート無効」テスト・新設した
# 「既定値1」テスト・run_bootstrap_with_profile()の専用テストで別途担保する）。
run_bootstrap() {
  local vault="$1"
  local reads_log="${2:-/nonexistent-dir/vault-reads.tsv}"
  local recall_log="${3:-/nonexistent-dir/vault-recall.tsv}"
  local inv_log_dir="${4:-/nonexistent-dir/vault-inventory}"
  local proposals_dir="${5:-/nonexistent-dir/preferences-proposals}"
  local last_run_file="${6:-/nonexistent-dir/last-run.json}"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$reads_log" VAULT_RECALL_LOG="$recall_log" \
      VAULT_INVENTORY_LOG_DIR="$inv_log_dir" \
      PREFERENCES_PROPOSALS_DIR="$proposals_dir" \
      MAINTENANCE_LAST_RUN_FILE="$last_run_file" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# P1機構（ローカル実体プロファイル）のテスト専用ヘルパー。
# BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 を明示して有効化した状態で実行する
# （run_bootstrap()は2026-09-02からBOOTSTRAP_ENABLE_LOCAL_PROFILE=0を明示固定に
# したため、本ヘルパーとは挙動が分かれる独立ヘルパーのまま維持する）。
# 3番目の引数（省略可）はsettings.jsonの比較先パス。省略時は存在しない
# パスを既定にする（S10/S11/S16対応・check_leader_settings_drift追加に
# あわせて2026-09-01追加。既定を実機の$HOME/.claude/settings.jsonのままに
# すると、v2プロファイルがOKで解決するテスト（#36・#37等）がテスト実行機の
# 実settings.jsonに依存してしまい非決定的になる＝他のログ系引数と同じく
# /nonexistent-dir配下を既定にして隔離する）。
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
[opus-main]
provider=anthropic-api
model=claude-opus-5

[opus-high]
provider=anthropic-api
model=claude-opus-5
effort=high

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

[sonnet-main]
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

run_bootstrap_with_profile() {
  local vault="$1" profile_path="$2" settings_json="${3:-/nonexistent-dir/settings.json}"
  local models_conf="${4:-$SHARED_MODELS_CONF}"
  echo '{"session_id":"test-session-0000"}' \
    | BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_SETTINGS_JSON_FILE="$settings_json" \
      AIENV_MODEL_DEFS_FILE="$models_conf" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}

# run_bootstrap_health4 <vault> <machine_role_line> [legacy_marker_content] [inv_dir] [proposals_dir] —
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
  local inv_dir="${4:-/nonexistent-dir/vault-inventory}" proposals_dir="${5:-/nonexistent-dir/preferences-proposals}"
  local fake_home profile_path
  fake_home="$(mktemp -d)"
  profile_path="$fake_home/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$profile_path")"
  {
    echo "---"
    echo "schema_version: 6"
    echo "profile_slug: authoring"
    echo "team_mode:        configured value=full"
    echo "no_read_paths:    unavailable"
    echo "machine_role:     ${machine_role_line}"
    echo "excluded_models: configured value=none"
    echo "role.leader: configured model=opus-main"
    echo "---"
  } > "$profile_path"
  if [ -n "$legacy_marker" ]; then
    printf '%s\n' "$legacy_marker" > "$fake_home/.config/takumi009-ai-env/machine-role"  # AC5-ALLOW:FX-M1
  fi
  echo '{"session_id":"test-session-0000"}' \
    | HOME="$fake_home" BOOTSTRAP_VAULT="$vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="$inv_dir" \
      PREFERENCES_PROPOSALS_DIR="$proposals_dir" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
  rm -rf "$fake_home"
}

# 「壊れていない」schema 6のprofile.mdを作る（2026-09-08 モデル定義ファイルと
# 候補指定対応: role.leaderまで含めて完全にOKへ解決できる最小の実体。旧版は
# 能力軸3キーだけの自由値v1形式だったが、schema 6のコードは6未満（版なし
# 含む）を一律T4-LEGACYで解決失敗にするため、role.leader込みの完全な実体に
# 差し替えた＝§4.1・§4.2。整理前の中間状態の経緯はgit履歴を参照）。
make_ok_profile() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
---
schema_version: 6
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
excluded_models: configured value=none
role.leader:      configured model=opus-main
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

echo "=== 7m. 外部脳ヘルス行④: 配役表のmachine_roleが\"sub\"かつlast-run.json不在でも④の警告は出ない（サブ機はmaintenance.sh非搭載＝2026-08-06対応、本人報告・実害中の解消。2026-09-07で判定元を旧マーカーから配役表へ移行＝FX-M2相当） ==="
{
  # maintenance.sh(週次メンテ)・LaunchAgentはメイン機専用機能でサブ機には
  # 存在しないため、④の警告は毎セッション必ず出続けていた（実害）。machine_role
  # が厳密に"sub"のときだけ④のみをスキップし、①②等の他セクションには影響しない
  # ことも合わせて確認する。
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  INV_DIR="$(mktemp -d)"
  cat > "$INV_DIR/2026-06-01.md" <<'EOF'
自動生成。ノート 42 件を検査し、**要確認 3 件**。
EOF
  PROPOSALS_DIR="$(mktemp -d)"
  echo "下書き本文" > "$PROPOSALS_DIR/x.md"

  ctx="$(run_bootstrap_health4 "$VAULT_DIR" "configured value=sub" "" "$INV_DIR" "$PROPOSALS_DIR")"
  assert_not_contains "machine_role=sub・last-run.json不在では状態記録の警告が出ない" "$ctx" "週次メンテの状態記録が無い/壊れています"
  assert_not_contains "machine_role=sub・last-run.json不在では動いていない系の警告も出ない" "$ctx" "週次メンテが"
  assert_contains "④以外(①棚卸し)は影響を受けず出る" "$ctx" "棚卸し最新"
  assert_contains "④以外(②Preferences提案)は影響を受けず出る" "$ctx" "夜間バッチで運用ルールの昇格提案"
  assert_contains "ヘルス見出し自体は①②があるので出る" "$ctx" "【外部脳ヘルス】"

  rm -rf "$VAULT_DIR" "$INV_DIR" "$PROPOSALS_DIR"
}

echo "=== 7m2. 外部脳ヘルス行④: 配役表のmachine_roleが\"main\"の場合は従来どおり警告が出る。同じ場所に置いた旧マーカー(\"sub\")は読まれない（FX-M1相当・読んでいないことの証明） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap_health4 "$VAULT_DIR" "configured value=main" "sub")"
  assert_contains "machine_role=mainでは従来どおりlast-run.json不在の警告が出る（旧マーカーがsubでも無視される）" "$ctx" "週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR"
}

echo "=== 7m3. 外部脳ヘルス行④: 実体プロファイルが無い（fail-closed）場合は従来どおり警告が出る ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "/nonexistent-dir/profile.md")"
  assert_contains "実体プロファイル不在では従来どおりlast-run.json不在の警告が出る" "$ctx" "週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR"
}

echo "=== 7m4. 外部脳ヘルス行④: machine_roleの値に内部空白を含む「s u b」(属性の形式検査(T6)で解決失敗)の場合は従来どおり警告が出る（fail-closed。前後空白はtrimするが内部の空白まで削っては誤って一致してしまうためtest-check-sub-update.sh 2eと同じ観点を踏襲） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"

  ctx="$(run_bootstrap_health4 "$VAULT_DIR" "configured value=s u b")"
  assert_contains "machine_roleの値に内部空白を含む場合は\"sub\"と誤認されず従来どおり警告が出る" "$ctx" "週次メンテの状態記録が無い/壊れています"

  rm -rf "$VAULT_DIR"
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

echo "=== 9. ワーカー(agent_type付き)には2026-09-03の軽量版撤去により何も注入されない（is_worker判定自体は健在で即exit 0。共通ルールの正本はagents/*.mdの共通ルール節へ移管済み） ==="
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
  assert_eq "ワーカー版のadditionalContextは完全に空（軽量版DIRECTIVEを撤去しexit 0のみ）" "" "$ctx"
  assert_not_contains "ワーカー版にはヘルス見出しが出ない" "$ctx" "【外部脳ヘルス】"
  assert_not_contains "ワーカー版には棚卸し情報も出ない" "$ctx" "棚卸し最新"
  assert_not_contains "ワーカー版にはフック死の疑いも出ない" "$ctx" "フック死の疑い"
  assert_not_contains "ワーカー版にはPreferences提案通知も出ない（提案が実在しても）" "$ctx" "夜間バッチで運用ルールの昇格提案"
  assert_not_contains "ワーカー版には死活警告も出ない（last-run.jsonが古くても）" "$ctx" "週次メンテが"
  assert_not_contains "旧軽量版の見出し文言はもう出ない（撤去の回帰確認）" "$ctx" "【チームメイト用ブートストラップ｜軽量版】"

  rm -rf "$VAULT_DIR" "$LOGDIR" "$INV_DIR" "$PROPOSALS_DIR" "$LAST_RUN_DIR"
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
schema_version: 6
profile_slug: authoring
team_mode: configured value=<fill-in>
no_read_paths: unavailable
machine_role: configured value=main
excluded_models: configured value=none
role.leader: configured model=opus-main
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
schema_version: 6
profile_slug: authoring
team_mode: configured value=full
no_read_paths: unavailable
excluded_models: configured value=none
role.leader: configured model=opus-main
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
schema_version: 6
profile_slug: authoring
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
excluded_models: configured value=none
role.leader: configured model=opus-main
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

# v2の全6固定キー(メタ2+能力軸3+excluded_models)をすべて満たした最小の
# base雛形。呼び出し側がrole./fallback.行だけを足して各シナリオを作る。
# 2026-09-08 モデル定義ファイルと候補指定対応: EXPECTED_SCHEMA_VERSIONを
# 5→6へ引き上げた（モデル定義ファイルと候補指定-設計-2026-09-08.md・D-8）
# のに合わせてbaseも更新した。役割の行の属性はmodel=<定義名>[,…]だけになり、
# provider/execution/effortはモデル定義ファイル側（make_model_defs()）へ
# 移した。
# ⚠️ team_mode:の行末揃え（8スペース）は下部のsed置換が字面で参照するため
# 崩さないこと。
V2_BASE='---
schema_version: 6
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
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

echo "=== 23. parser 4.1-a/4.1-b: ハイフンキー・コメント行・行末コメントが正しく扱われる ==="
{
  P="$(mktemp -d)/comment.md"
  make_v2_profile "$P" \
    "# これはコメント行（無視される）" \
    "role.leader: configured model=opus-main  # 行末コメントも無視" \
    "role.requirements-analyst: configured model=opus-main"
  out="$(resolve_v2 "$P")"  || true
  assert_contains "4.1-a: ハイフンを含むキー(role.requirements-analyst)がT6にならない" "$out" "OK"
  assert_not_contains "4.1-b: コメント行・行末コメントでT6にならない" "$out" "MINIMAL"
}

echo "=== 24. parser §3.1-7: 重複キー・重複属性・未許可属性はすべてT6（構文エラー） ==="
{
  DUPKEY="$(mktemp -d)/dupkey.md"
  make_v2_profile "$DUPKEY" \
    "role.leader: configured model=opus-main" \
    "role.leader: unknown"
  out="$(resolve_v2 "$DUPKEY")"  || true
  assert_contains "重複キーはMINIMAL/T6になる" "$out" "MINIMAL"
  assert_contains "T6コードが出る" "$out" "T6"

  DUPATTR="$(mktemp -d)/dupattr.md"
  make_v2_profile "$DUPATTR" \
    "role.leader: configured model=opus-main model=sonnet-main"
  out="$(resolve_v2 "$DUPATTR")"  || true
  assert_contains "重複属性はMINIMAL/T6になる" "$out" "MINIMAL	T6"

  UNKATTR="$(mktemp -d)/unkattr.md"
  make_v2_profile "$UNKATTR" \
    "role.leader: configured model=opus-main mystery=1"
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
    "role.leader: configured model=opus-main" \
    "role.researcher: not_adopted model=opus-main"
  out="$(resolve_v2 "$NOTADOPT_ATTR")"  || true
  assert_contains "not_adoptedが属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  MISSING_MODEL="$(mktemp -d)/missingmodel.md"
  make_v2_profile "$MISSING_MODEL" \
    "role.leader: configured"
  out="$(resolve_v2 "$MISSING_MODEL")"  || true
  assert_contains "configuredでmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNAVAIL_OK="$(mktemp -d)/unavailok.md"
  make_v2_profile "$UNAVAIL_OK" \
    "role.leader: configured model=opus-main" \
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
  make_v2_profile "$BADMODEL" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$BADMODEL_CONF" resolve_v2 "$BADMODEL")"  || true
  assert_contains "anthropic-apiでmodelがclaude-接頭辞でないとT12でMINIMAL" "$out" "MINIMAL	T12"

  BEDROCKARN="$(mktemp -d)/bedrockarn.md"
  BEDROCKARN_CONF="$(mktemp -d)/bedrockarn.conf"
  make_model_defs "$BEDROCKARN_CONF" "[bad-arn]" "provider=bedrock" "model=arn:aws:bedrock:foo"
  make_v2_profile "$BEDROCKARN" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$BEDROCKARN_CONF" resolve_v2 "$BEDROCKARN")"  || true
  assert_contains "bedrockでarn:始まりのmodelはT12（別名限定）" "$out" "MINIMAL	T12"

  BEDROCKUS="$(mktemp -d)/bedrockus.md"
  BEDROCKUS_CONF="$(mktemp -d)/bedrockus.conf"
  make_model_defs "$BEDROCKUS_CONF" "[bad-us]" "provider=bedrock" "model=us.opus"
  make_v2_profile "$BEDROCKUS" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$BEDROCKUS_CONF" resolve_v2 "$BEDROCKUS")"  || true
  assert_contains "bedrockでus.始まりのmodelもT12" "$out" "MINIMAL	T12"

  EXTNOEXEC="$(mktemp -d)/extnoexec.md"
  EXTNOEXEC_CONF="$(mktemp -d)/extnoexec.conf"
  make_model_defs "$EXTNOEXEC_CONF" "[bad-noexec]" "provider=external" "model=default"
  make_v2_profile "$EXTNOEXEC" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$EXTNOEXEC_CONF" resolve_v2 "$EXTNOEXEC")"  || true
  assert_contains "provider=externalでexecution未記載はT12" "$out" "MINIMAL	T12"

  NONSUBEXEC="$(mktemp -d)/nonsubexec.md"
  NONSUBEXEC_CONF="$(mktemp -d)/nonsubexec.conf"
  make_model_defs "$NONSUBEXEC_CONF" "[bad-nonsub]" "provider=anthropic-api" "model=claude-opus-5" "execution=external-cli"
  make_v2_profile "$NONSUBEXEC" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$NONSUBEXEC_CONF" resolve_v2 "$NONSUBEXEC")"  || true
  assert_contains "anthropic-apiでexecution!=subagentはT12" "$out" "MINIMAL	T12"

  DEFAULTEXEC="$(mktemp -d)/defaultexec.md"
  make_v2_profile "$DEFAULTEXEC" \
    "role.leader: configured model=opus-main"
  out="$(resolve_v2 "$DEFAULTEXEC")"  || true
  assert_contains "execution未記載はsubagent既定でOKになる" "$out" "OK"
}

echo "=== 27. validator V9-d②: execution=external-apiは常にconfigured不可（2026-09-08 モデル定義ファイルと候補指定対応でハンドラ写像が(provider,execution,model)の三つ組から(provider,execution)の対へ縮まったため、旧『写像に無いmodel名』の陰性ケースは消滅した＝external-cliならどのmodelでも実装済み扱いになる。§2.4） ==="
{
  EXTAPI="$(mktemp -d)/extapi.md"
  make_v2_profile "$EXTAPI" \
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=ext-api-bad"
  out="$(resolve_v2 "$EXTAPI")"  || true
  assert_contains "execution=external-apiはハンドラ未実装でconfigured不可(V9-d)" "$out" "MINIMAL	T8	V9-d"

  EXTAPI_UNAVAIL="$(mktemp -d)/extapiunavail.md"
  make_v2_profile "$EXTAPI_UNAVAIL" \
    "role.leader: configured model=opus-main" \
    "role.verifier: unavailable model=ext-api-bad"
  out="$(resolve_v2 "$EXTAPI_UNAVAIL")"  || true
  assert_contains "unavailableならexternal-apiでも構文上は許される(V9-d②はconfigured限定)" "$out" "OK"
}

echo "=== 28. validator V16: excluded_modelsに一致する配役はMINIMAL ==="
{
  V16="$(mktemp -d)/v16.md"
  make_v2_profile "$V16" \
    "role.leader: configured model=opus-main"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: configured value=anthropic-api\/claude-opus-5/' "$V16"
  out="$(resolve_v2 "$V16")"  || true
  assert_contains "禁止モデル一致はV16でMINIMAL" "$out" "MINIMAL	T8	V16"

  V16_1M="$(mktemp -d)/v16_1m.md"
  make_v2_profile "$V16_1M" \
    "role.leader: configured model=fable-1m"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: configured value=anthropic-api\/claude-fable-5/' "$V16_1M"
  out="$(resolve_v2 "$V16_1M")"  || true
  assert_contains "[1m]は判定で無視されるので同じく一致してMINIMALになる" "$out" "MINIMAL	T8	V16"
}

echo "=== 29. validator V6: fallbackが指す職種がrole.表に無いとMINIMAL ==="
{
  V6="$(mktemp -d)/v6.md"
  make_v2_profile "$V6" \
    "role.leader: configured model=opus-main" \
    "fallback.ghost-role: configured model=opus-main"
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
  make_v2_profile "$NOLEADER" "role.researcher: configured model=sonnet-main"
  out="$(resolve_v2 "$NOLEADER")"  || true
  assert_contains "role.leader行が無ければfail(MINIMAL)になる" "$out" "MINIMAL"

  UNAVAIL_NOFB="$(mktemp -d)/leaderunavail.md"
  make_v2_profile "$UNAVAIL_NOFB" "role.leader: unavailable model=opus-main"
  out="$(resolve_v2 "$UNAVAIL_NOFB")"  || true
  assert_contains "leader=unavailableでfallback無しはfail" "$out" "MINIMAL"

  err="$(resolve_leader_v2 "$UNAVAIL_NOFB" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderは機械可読コードLEADER_UNAVAILABLE_NO_FALLBACKをstderrへ出す" "$err" "LEADER_UNAVAILABLE_NO_FALLBACK"
}

echo "=== 31. §3.5-L: leaderのfallback救済（本命unavailable→fallbackがconfigured→採用） ==="
{
  RESCUE="$(mktemp -d)/leaderrescue.md"
  make_v2_profile "$RESCUE" \
    "role.leader: unavailable model=bedrock-opus" \
    "fallback.leader: configured model=opus-main"
  out="$(resolve_v2 "$RESCUE")"  || true
  assert_contains "leaderがfallback救済されればOKになる" "$out" "OK"
  json="$(resolve_leader_v2 "$RESCUE")"  || true
  assert_contains "resolve-leaderはfallbackのmodelを返す" "$json" "claude-opus-5"

  echo "--- leader専用規則: 実効候補のproviderがexternalならfail ---"
  EXT_LEADER="$(mktemp -d)/extleader.md"
  make_v2_profile "$EXT_LEADER" \
    "role.leader: configured model=codex-review"
  out="$(resolve_v2 "$EXT_LEADER")"  || true
  assert_contains "leaderのprovider=externalはfailになる" "$out" "MINIMAL"
}

echo "=== 32. 候補評価§3.6: ワーカー職はV1-b/V9-d/V12単独では空席にならず、使えるfallbackがあれば採用される ==="
{
  FB_RESCUE="$(mktemp -d)/workerfallback.md"
  make_v2_profile "$FB_RESCUE" \
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=bedrock-haiku" \
    "fallback.verifier: configured model=sonnet-main"
  # bedrock.envを与えない(ABSENT=disabled)のでverifierの本命(bedrock)はV9-dで使用不可
  out="$(resolve_v2 "$FB_RESCUE")"  || true
  assert_contains "本命が使用不可でもfallbackが使えればFALLBACK:verifierとして採用される" "$out" "FALLBACK:verifier"
  assert_not_contains "fallbackが採用された職種はVACANTに出ない" "$out" "VACANT:verifier"

  echo "--- 双方使用不可のときだけVACANT+VACANT_REASON、優先順はV1-b→V9-d→V12 ---"
  BOTH_BAD="$(mktemp -d)/bothbad.md"
  make_v2_profile "$BOTH_BAD" \
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=bedrock-haiku" \
    "fallback.verifier: configured model=bedrock-opus"
  out="$(resolve_v2 "$BOTH_BAD")"  || true
  assert_contains "双方bedrockで経路無効なら空席になる" "$out" "VACANT:verifier"
  assert_contains "空席理由の条件番号が出る(V9-d)" "$out" "VACANT_REASON:verifier=V9-d"

  echo "--- unavailableの本命は評価されず、fallbackだけが評価される ---"
  UNAVAIL_SKIP="$(mktemp -d)/unavailskip.md"
  make_v2_profile "$UNAVAIL_SKIP" \
    "role.leader: configured model=opus-main" \
    "role.verifier: unavailable model=bedrock-opus" \
    "fallback.verifier: configured model=sonnet-main"
  out="$(resolve_v2 "$UNAVAIL_SKIP")"  || true
  assert_contains "unavailableな本命はスキップされfallbackが採用される" "$out" "FALLBACK:verifier"
}

echo "=== 33. §3.7 判定不能: Bedrock経路の判定不能はワーカーなら通す・leaderならfail ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir
  UNREADABLE_ENV="/tmp/aienv-test-unreadable-env-dir/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV"
  chmod 0000 "$UNREADABLE_ENV"

  WORKER_UNKNOWN="$(mktemp -d)/workerunknown.md"
  make_v2_profile "$WORKER_UNKNOWN" \
    "role.leader: configured model=opus-main" \
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
    "role.leader: configured model=opus-main"
  echo "api_key: configured value=xyz" >> "$V15_V2"
  # frontmatter終端---の後ろに付けると構文が壊れるので、専用のfixtureを作り直す。
  cat > "$V15_V2" <<'EOF'
---
schema_version: 6
profile_slug: authoring
role.leader: configured model=opus-main
api_key: configured value=xyz
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
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

echo "=== 36. 結合（DIRECTIVE）: VACANT_UNKNOWN・FALLBACK・VACANT_REASONが職種名と条件番号でDIRECTIVEへ注入される（4.1-f） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=bedrock-haiku" \
    "fallback.verifier: configured model=bedrock-opus"
  # 静的検証: このprofile単体でVACANT_REASON:verifier=V9-dが出ることを確認済み(#32)。
  # ここではDIRECTIVEへの伝播だけを確認する。

  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$PROFILE_PATH")"
  assert_contains "DIRECTIVEに配役表の状態行が出る" "$ctx" "配役表の状態"
  assert_contains "VACANT:teseterの職種名が出る" "$ctx" "VACANT:verifier"
  assert_contains "VACANT_REASONの条件番号が出る" "$ctx" "VACANT_REASON:verifier=V9-d"
  # 2026-09-08 モデル定義ファイルと候補指定対応: 定義名（例=bedrock-haiku）は
  # D-10によりこの原則の対象外（配役表解凍-設計-2026-09-08.md §4.1-f）——候補
  # 行に定義名だけが出ることは別のテスト（AC-7相当）で検証済み。ここで見るのは
  # 生の属性構文（`model=`・`provider=`のkey=value形式）がDIRECTIVEへそのまま
  # 再掲されないこと（機構が値を再包装せず生のprofile行を横流しした場合の
  # 回帰を検知する）。
  assert_not_contains "配役の属性構文(model=)がそのまま再掲されない（4.1-f）" "$ctx" "model="
  assert_not_contains "配役の属性構文(provider=)がそのまま再掲されない（4.1-f）" "$ctx" "provider="

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 37. stdout契約: v2 OKでは全文Readが必読リストに載り、フィールドは固定順（OK→FALLBACK→VACANT→VACANT_REASON→VACANT_UNKNOWN→ADVISORY→UNKNOWN_EXTRA） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured model=opus-main" \
    "role.requirements-analyst: configured model=opus-main"

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
    "role.leader: unavailable model=bedrock-opus" \
    "fallback.leader: configured model=opus-main" \
    "role.verifier: configured model=bedrock-haiku" \
    "fallback.verifier: configured model=sonnet-main" \
    "role.researcher: configured model=sonnet-main"
  multi_out="$(resolve_v2 "$MULTI")"  || true
  # 期待: OK -> FALLBACK:leader,verifier(順不同はソート済み) -> VACANT_UNKNOWN(コア
  # マニフェストの他職種) -> ADVISORY:V1-a の順で、この並びどおりに現れること。
  idx_ok=$(printf '%s' "$multi_out" | grep -bo '^OK' | head -1 | cut -d: -f1)
  idx_fallback=$(printf '%s' "$multi_out" | grep -bo 'FALLBACK:' | head -1 | cut -d: -f1)
  idx_vacant_unknown=$(printf '%s' "$multi_out" | grep -bo 'VACANT_UNKNOWN:' | head -1 | cut -d: -f1)
  idx_advisory=$(printf '%s' "$multi_out" | grep -bo 'ADVISORY:' | head -1 | cut -d: -f1)
  assert_contains "複合ケースでFALLBACKにleaderとverifierの両方が出る" "$multi_out" "FALLBACK:leader,verifier"
  order_multi_ok=1
  [ -n "$idx_ok" ] && [ -n "$idx_fallback" ] && [ "$idx_ok" -lt "$idx_fallback" ] || order_multi_ok=0
  [ -n "$idx_fallback" ] && [ -n "$idx_vacant_unknown" ] && [ "$idx_fallback" -lt "$idx_vacant_unknown" ] || order_multi_ok=0
  [ -n "$idx_vacant_unknown" ] && [ -n "$idx_advisory" ] && [ "$idx_vacant_unknown" -lt "$idx_advisory" ] || order_multi_ok=0
  assert_eq "OK→FALLBACK→VACANT_UNKNOWN→ADVISORYの出現順が固定順どおり" "1" "$order_multi_ok"
}

echo "=== 38. 候補評価§3.6: 本命と代替の失敗理由が異なるとき、優先順(V1-b→V9-d→V12)で高い方が採用される（ホワイトボックス・Codex二次レビュー指摘・Major対応: CLI経由のfixtureでは本命/fallbackが同一職種名を共有するためV1-bは両者で必ず同じ結果になり、異なる理由の組み合わせを黒箱では再現できない。_evaluate_single_candidate()を差し替えて優先順ロジック自体を直接検証する） ==="
{
  # 2026-09-08 モデル定義ファイルと候補指定対応: evaluate_worker_candidate()の
  # シグネチャがresolved辞書（{(kind,name): [ModelDef,...]}）を取るように
  # 変わり、内部で候補ごとにCandidate(name, ModelDef)を組み立ててから
  # _evaluate_single_candidate()へ渡すようになった（1行1候補→1行n候補）。
  # そのためline識別はオブジェクトの同一性ではなくdef_nameで行う。
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
    if cand.def_name == "primary-def":
        return False, "V9-d", None
    return False, "V1-b", None


primary = Fake("verifier")
fallback = Fake("verifier")
resolved = {
    ("role", "verifier"): [make_def("primary-def")],
    ("fallback", "verifier"): [make_def("fallback-def")],
}
orig = pr._evaluate_single_candidate
pr._evaluate_single_candidate = fake_eval
try:
    cand = pr.evaluate_worker_candidate("verifier", {"verifier": primary}, {"verifier": fallback}, resolved, None, None)
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
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$ADV_UNKNOWN" "$UNREADABLE_ENV2")"  || true
  assert_contains "判定不能で通した職種があることがADVISORY:JUDGEMENT_UNKNOWNとして出る" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"

  chmod 0700 "$UNREADABLE_ENV2"
  rm -rf /tmp/aienv-test-unreadable-env-dir2
}

echo "=== 40. §4.1-f: leaderがfallback救済されたときも職種名'leader'がFALLBACK:へ出る（Codex一次レビュー指摘・Major対応: 従来はワーカーだけが対象だった） ==="
{
  LEADER_FB="$(mktemp -d)/leaderfb.md"
  make_v2_profile "$LEADER_FB" \
    "role.leader: unavailable model=bedrock-opus" \
    "fallback.leader: configured model=opus-main"
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
  make_v2_profile "$LEADER_FAIL_ENV" "role.leader: configured model=bedrock-sonnet"
  leader_err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_FAIL_ENV" --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_not_contains "resolve-leaderのstderrにもピン実値が現れない" "$leader_err" "supersecret-arn-2"
  assert_not_contains "resolve-leaderのstderrにもAWSキーが現れない" "$leader_err" "SHOULD_NEVER_LEAK_2"
}

echo "=== 42. §3.4 T4'(実体の版>コードの版): 未知キーを無視しADVISORY:T4-PRIME+UNKNOWN_EXTRAで通す(最小能力へは倒さない) ==="
{
  T4PRIME="$(mktemp -d)/t4prime.md"
  make_v2_profile "$T4PRIME" \
    "role.leader: configured model=opus-main"
  sed -i '' 's/schema_version: 6/schema_version: 7/' "$T4PRIME"
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

echo "=== 44. V8-b共通規則・excluded_modelsの扱い統一（Codex一次レビュー指摘・Major対応） ==="
{
  EM_SENTINEL="$(mktemp -d)/emsentinel.md"
  make_v2_profile "$EM_SENTINEL" \
    "role.leader: configured model=opus-main"
  sed -i '' 's/excluded_models: configured value=none/excluded_models: configured value=<fill-in>/' "$EM_SENTINEL"
  out="$(resolve_v2 "$EM_SENTINEL")"  || true
  assert_contains "excluded_modelsのsentinelもT2-MINIMALで検出される" "$out" "MINIMAL	T2-MINIMAL"
  assert_contains "T2-MINIMALの理由にexcluded_modelsが出る" "$out" "excluded_models"

  DUP_VALUE="$(mktemp -d)/dupvalue.md"
  make_v2_profile "$DUP_VALUE" \
    "role.leader: configured model=opus-main"
  sed -i '' 's/team_mode:        configured value=full/team_mode:        configured value=full,full/' "$DUP_VALUE"
  out="$(resolve_v2 "$DUP_VALUE")"  || true
  assert_contains "value内の重複要素はV8-bでMINIMALになる（共通規則）" "$out" "MINIMAL	T8	V8-b"

  EM_UNAVAIL="$(mktemp -d)/emunavail.md"
  make_v2_profile "$EM_UNAVAIL" \
    "role.leader: configured model=opus-main"
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

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "正常なOK単体は受理される" || fail_case "正常なOK単体は受理される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tGARBAGE:xyz')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "未知フィールド(GARBAGE)混入は拒否される" || fail_case "未知フィールド(GARBAGE)混入は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tFALLBACK:verifier\tFALLBACK:verifier')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "同一フィールドの重複は拒否される" || fail_case "同一フィールドの重複は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT:verifier\tFALLBACK:verifier')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "フィールドの順序違反(VACANTがFALLBACKより先)は拒否される" || fail_case "フィールドの順序違反(VACANTがFALLBACKより先)は拒否される"

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

  T="$(printf 'OK\tschema_version=2\tFALLBACK:verifier\tTEAM_MODE:full\tMACHINE_ROLE:main')"
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
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tFALLBACK:verifier\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:がTEAM_MODE:の直後以外の位置にあると拒否される" \
    || fail_case "MACHINE_ROLE:がTEAM_MODE:の直後以外の位置にあると拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:unknown')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:unknownは受理される" \
    || fail_case "MACHINE_ROLE:unknownは受理される"
}

echo "=== 46. list-roles: kind/state/定義名/execution既定値/not_adopted・unknownの空欄化・fallbackの並び（2026-09-08 モデル定義ファイルと候補指定対応で8列・1候補1行へ改訂＝設計§3.4） ==="
{
  LR="$(mktemp -d)/listroles.md"
  make_v2_profile "$LR" \
    "role.leader: configured model=opus-main" \
    "role.navi: unknown" \
    "role.researcher: not_adopted" \
    "role.system-designer: configured model=opus-high" \
    "role.verifier: unavailable model=bedrock-opus" \
    "fallback.verifier: configured model=sonnet-main"
  out="$(python3 "$PROFILE_LIB" list-roles "$LR")"  || true

  assert_contains "role.leaderの行がkind=role・state=configured・定義名=opus-mainで出る" "$out" "role	leader	configured	opus-main	anthropic-api	claude-opus-5	subagent	"
  assert_contains "executionが省略されていてもsubagentが補われて出る" "$out" "	subagent	"
  assert_contains "effortが指定されていればそのまま出る(system-designer=high)" "$out" "role	system-designer	configured	opus-high	anthropic-api	claude-opus-5	subagent	high"
  assert_contains "unknown状態は定義名以降が全て空文字になる（5フィールド）" "$out" "role	navi	unknown					"
  assert_contains "not_adopted状態も定義名以降が全て空文字になる（5フィールド）" "$out" "role	researcher	not_adopted					"
  assert_contains "unavailable状態は定義名・provider/modelを保持したまま出る（意図の記録）" "$out" "role	verifier	unavailable	bedrock-opus	bedrock	opus	subagent	"
  assert_contains "fallback行もkind=fallbackとして出る" "$out" "fallback	verifier	configured	sonnet-main	anthropic-api	claude-sonnet-5	subagent	"

  # role.表→fallback.表の順であることの確認（roleの最後の行より後にfallbackが来る）。
  role_idx=$(printf '%s' "$out" | grep -n '^role	verifier' | head -1 | cut -d: -f1)
  fallback_idx=$(printf '%s' "$out" | grep -n '^fallback	verifier' | head -1 | cut -d: -f1)
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
    "role.leader: configured model=opus-main" \
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
  assert_contains "list-roles出力にはBedrockの別名(opus)だけが出る" "$out" "role	leader	configured	bedrock-opus	bedrock	opus	subagent	"
}

echo "=== 49. tester独立検証差し戻し(Major): bedrock.envに不正UTF-8があってもクラッシュせず、判定不能として扱われる（_read_bedrock_env_wanted()がUnicodeDecodeErrorを未捕捉だった実バグの回帰テスト） ==="
{
  BAD_UTF8_ENV="$(mktemp -d)/bedrock.env"
  printf 'CLAUDE_CODE_USE_BEDROCK=1\nANTHROPIC_DEFAULT_HAIKU_MODEL=\xff\xfebroken\n' > "$BAD_UTF8_ENV"

  WORKER_BAD_UTF8="$(mktemp -d)/workerbadutf8.md"
  make_v2_profile "$WORKER_BAD_UTF8" \
    "role.leader: configured model=opus-main" \
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
  make_v2_profile "$BADVER" "role.leader: configured model=opus-main"
  sed -i '' 's/schema_version: 6/schema_version: abc/' "$BADVER"
  out="$(resolve_v2 "$BADVER")"  || true
  assert_contains "schema_versionが数値でなければT3になる" "$out" "MINIMAL	T3"

  BADVER0="$(mktemp -d)/badver0.md"
  make_v2_profile "$BADVER0" "role.leader: configured model=opus-main"
  sed -i '' 's/schema_version: 6/schema_version: 0/' "$BADVER0"
  out="$(resolve_v2 "$BADVER0")"  || true
  assert_contains "schema_version=0(正整数でない)もT3になる" "$out" "MINIMAL	T3"

  BADSLUG="$(mktemp -d)/badslug.md"
  make_v2_profile "$BADSLUG" "role.leader: configured model=opus-main"
  sed -i '' 's/profile_slug: authoring/profile_slug: Bad_Slug!/' "$BADSLUG"
  out="$(resolve_v2 "$BADSLUG")"  || true
  assert_contains "profile_slugが規約(^[a-z0-9][a-z0-9-]*\$)に反するとT14になる" "$out" "MINIMAL	T14"
}

echo "=== 52. V8-a 状態4値×属性有無の網羅補充: unavailableでmodel欠落・unknownが属性を持つ ==="
{
  UNAVAIL_MISSING="$(mktemp -d)/unavailmissing.md"
  make_v2_profile "$UNAVAIL_MISSING" \
    "role.leader: configured model=opus-main" \
    "role.verifier: unavailable"
  out="$(resolve_v2 "$UNAVAIL_MISSING")"  || true
  assert_contains "unavailableでもmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNKNOWN_ATTR="$(mktemp -d)/unknownattr.md"
  make_v2_profile "$UNKNOWN_ATTR" \
    "role.leader: configured model=opus-main" \
    "role.verifier: unknown model=sonnet-main"
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
    "role.leader: configured model=opus-main" \
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
  make_v2_profile "$MANTLE_BAD" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$MANTLE_BAD_CONF" resolve_v2 "$MANTLE_BAD")"  || true
  assert_contains "bedrock-mantleでanthropic.始まりでないmodelはT12でMINIMALになる" "$out" "MINIMAL	T12"
}

echo "=== 54. effort enum境界の直接検証(V9-b/V9-e): Claude系max・Codex方言minimal・設定効果先の非対称 ==="
{
  WORKER_MAX="$(mktemp -d)/workermax.md"
  make_v2_profile "$WORKER_MAX" \
    "role.leader: configured model=opus-main" \
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
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=codex-review-minimal"
  out="$(resolve_v2 "$CODEX_MINIMAL")"  || true
  assert_contains "Codexハンドラ(external-cli/codex-review-default)はminimalを書ける" "$out" "OK"

  # 2026-09-08 モデル定義ファイルと候補指定対応: effortの許可集合検査は
  # モデル定義ファイル側（validate_model_def・T12）へ移った。
  CODEX_MINIMAL_ELSEWHERE_CONF="$(mktemp -d)/codexminimalelsewhere.conf"
  make_model_defs "$CODEX_MINIMAL_ELSEWHERE_CONF" "[bad-sonnet-minimal]" "provider=anthropic-api" "model=claude-sonnet-5" "effort=minimal"
  CODEX_MINIMAL_ELSEWHERE="$(mktemp -d)/codexminimalelsewhere.md"
  make_v2_profile "$CODEX_MINIMAL_ELSEWHERE" "role.leader: configured model=opus-main"
  out="$(AIENV_MODEL_DEFS_FILE="$CODEX_MINIMAL_ELSEWHERE_CONF" resolve_v2 "$CODEX_MINIMAL_ELSEWHERE")"  || true
  assert_contains "Claude系(anthropic-api)でminimalはT12でMINIMALになる(Codex方言はexternalハンドラ限定)" "$out" "MINIMAL	T12"
}

echo "=== 55. V9-f直接検証: 既知の非対応モデル×xhigh はADVISORY、別名は判別不能としてEFFORT_COMPATIBILITY_UNVERIFIED ==="
{
  V9F_KNOWN="$(mktemp -d)/v9fknown.md"
  make_v2_profile "$V9F_KNOWN" \
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=opus46-xhigh"
  out="$(resolve_v2 "$V9F_KNOWN")"  || true
  # ADVISORYフィールドはコードをソートして併記する(§5)ため"V1-a,V9-f"に
  # なる。"ADVISORY:V9-f"という直結文字列を探すのは誤り(実測で判明)。
  assert_contains "既知の非対応モデル(claude-opus-4.6)×xhighはV9-fがADVISORYに含まれる(failにしない)" "$out" "V9-f"
  assert_contains "failにしない(OKのまま)" "$out" "OK"

  V9F_BEDROCK="$(mktemp -d)/v9fbedrock.md"
  make_v2_profile "$V9F_BEDROCK" \
    "role.leader: configured model=opus-main" \
    "role.verifier: configured model=bedrock-opus-xhigh"
  out="$(resolve_v2 "$V9F_BEDROCK")"  || true
  assert_contains "bedrock別名は実モデル版を判別できないためEFFORT_COMPATIBILITY_UNVERIFIEDになる" "$out" "ADVISORY:EFFORT_COMPATIBILITY_UNVERIFIED"
}

echo "=== 56. check_leader_settings_drift(): S10/S11/S16対応（配役表解凍-設計-2026-09-01.md §6.2-B）。v2のリーダー行が解決できたセッションでsettings.jsonとの整合をSessionStartのたびに軽量比較する ==="
{
  LEADER_PROFILE="$(mktemp -d)/leaderdrift.md"
  make_v2_profile "$LEADER_PROFILE" \
    "role.leader: configured model=opus-high"

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
    "role.leader: configured model=opus-main"
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

  echo "--- ゲート無効(BOOTSTRAP_ENABLE_LOCAL_PROFILE=0を明示。run_bootstrap()の固定値)では、settings.jsonが不一致でもDIRECTIVEに一切現れない(P1導入前の挙動) ---"
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  ctx="$(run_bootstrap "$VAULT_DIR")"
  assert_not_contains "ゲート無効時はsettings.json関連の文言が一切出ない" "$ctx" "settings.json"

  echo "--- 2026-09-02 案A採用の回帰: BOOTSTRAP_ENABLE_LOCAL_PROFILEを一切指定しないと、コードの既定値(0→1へ変更済み)によりP1機構が有効になる ---"
  ctx="$(echo '{"session_id":"test-session-0000"}' \
    | env -u BOOTSTRAP_ENABLE_LOCAL_PROFILE \
        BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
        VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
        VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
        PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
        MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
        AIENV_LOCAL_PROFILE_PATH="/nonexistent-dir/profile-for-default-gate-test.md" \
        "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext')"
  assert_contains "フラグ未指定でも既定値1でP1機構が動く(未作成プロファイルのT1案内が出る)" "$ctx" "未作成。installerでサンプルから雛形を作成してください"

  echo "--- 結合(SessionStart全体): ゲート有効・不一致プロファイルでDIRECTIVEの【ローカル実体プロファイル】ブロックに警告が注入される ---"
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$LEADER_PROFILE" "$SETTINGS_MODEL_MISMATCH")"
  assert_contains "DIRECTIVEにsettings.json不一致の警告が出る" "$ctx" "settings.json(${SETTINGS_MODEL_MISMATCH})が配役表のリーダー行"
  assert_not_contains "settings.jsonの実際のmodel値(claude-sonnet-5)そのものは再掲しない（不一致メッセージはフィールド名のみ）" "$ctx" "claude-sonnet-5"

  echo "--- 結合(SessionStart全体): 一致していればDIRECTIVEにsettings.json関連の警告は出ない ---"
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$LEADER_PROFILE" "$SETTINGS_MATCH")"
  assert_not_contains "一致していれば警告が出ない" "$ctx" "settings.json"

  echo "--- 旧版(T4-LEGACY)はスコープ外: profile_kind=OK以外ではsettings.json比較を試みない（2026-09-08 モデル定義ファイルと候補指定対応でv1委譲は撤去したが、旧版が比較対象外という契約自体は同じ。週次drift=check-drift.shのV13が既に旧版をカバーする） ---"
  LEGACY_PROFILE="$(mktemp -d)/legacyprofile.md"
  cat > "$LEGACY_PROFILE" <<'EOF'
---
team_mode: 本人
no_read_paths: ~/work/old
machine_role: 本人
---
EOF
  ctx="$(run_bootstrap_with_profile "$VAULT_DIR" "$LEGACY_PROFILE" "$SETTINGS_BROKEN")"
  assert_contains "旧版の警告文言は出る" "$ctx" "旧版"
  assert_not_contains "旧版ではsettings.json比較の監視不能メッセージは出ない(スコープ外)" "$ctx" "監視不能"

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
  # 実AGENTS_DIR（claude/agents/、vault-scribe.md収録後）を使い、現行の
  # コア職種マニフェスト全件（CORE_ROLES_WITHOUT_REPO_AGENT_FILE 3件（3モード
  # 体制対応でprimary-reviewerがverifierへ統合されたため4件→3件） +
  # claude/agents/*.md 8件＝ファイル名そのまま、計11件）ちょうどをrole.表へ
  # 宣言する。leader以外は状態を"unknown"にして属性検証（V9-b等）を回避し、
  # V1-aの対称差判定だけに焦点を絞る（他ロールのstateはV1-aの結果に影響
  # しない＝role_and_core_manifest_diff()はparsed.rolesのキーのみを見る）。
  COMPLETE_ROSTER="$(mktemp -d)/complete-roster.md"
  make_v2_profile "$COMPLETE_ROSTER" \
    "role.leader: configured model=opus-main" \
    "role.navi: unknown" \
    "role.ja-doc: unknown" \
    "role.adoption-critic: unknown" \
    "role.implementer: unknown" \
    "role.operator: unknown" \
    "role.requirements-analyst: unknown" \
    "role.researcher: unknown" \
    "role.system-designer: unknown" \
    "role.verifier: unknown" \
    "role.vault-scribe: unknown"

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
  # 58.と全く同じ完全ロースターから、'role.vault-scribe'の行だけを
  # 'role.scribe'（旧キー）へ差し替える。他の10行（leader含む）は58.と
  # 完全に同一。
  OLD_KEY_ROSTER="$(mktemp -d)/old-key-roster.md"
  make_v2_profile "$OLD_KEY_ROSTER" \
    "role.leader: configured model=opus-main" \
    "role.navi: unknown" \
    "role.ja-doc: unknown" \
    "role.adoption-critic: unknown" \
    "role.implementer: unknown" \
    "role.operator: unknown" \
    "role.requirements-analyst: unknown" \
    "role.researcher: unknown" \
    "role.system-designer: unknown" \
    "role.verifier: unknown" \
    "role.scribe: unknown"

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
      "role.leader: configured model=opus-main"
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
    "role.leader: configured model=opus-main"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unknown/" "$FXP4"
  if out="$(resolve_v2 "$FXP4")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P4(team_mode:unknown): TEAM_MODE:unknownが出る" "$out" "TEAM_MODE:unknown"
  assert_eq "FX-P4: exit0（AC-2）" "0" "$rc"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-P4: 先頭フィールドはOK" "1" "$head_ok"

  FXP5="$(mktemp -d)/fxp5.md"
  make_v2_profile "$FXP5" \
    "role.leader: configured model=opus-main"
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
    "role.leader: configured model=opus-main"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=solo,lean/" "$FXP6"
  if out="$(resolve_v2 "$FXP6")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P6(カンマ列挙): MINIMALになる" "$out" "MINIMAL"
  assert_eq "FX-P6: exit1（AC-3）" "1" "$rc"
  assert_not_contains "FX-P6: TEAM_MODE:は出ない" "$out" "TEAM_MODE:"

  FXP7="$(mktemp -d)/fxp7.md"
  make_v2_profile "$FXP7" \
    "role.leader: configured model=opus-main"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=quick/" "$FXP7"
  if out="$(resolve_v2 "$FXP7")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P7(未知の語): MINIMALになる" "$out" "MINIMAL"
  assert_eq "FX-P7: exit1（AC-3）" "1" "$rc"
  assert_not_contains "FX-P7: TEAM_MODE:は出ない" "$out" "TEAM_MODE:"
}

echo "=== 64. known-keysがSCHEMA_VERSION:6・FIXED:にteam_mode/machine_roleを含み廃止5キーを含まない・要素数は6（配役表-能力軸整理-設計-2026-09-07.md §3・2026-09-08モデル定義ファイルと候補指定対応でschema 5→6。要件AC-1・AC-2の基本口Kの実測はtest-core-docs-placeholder-schema.shが担う） ==="
{
  kk="$(python3 "$PROFILE_LIB" known-keys)"
  assert_contains "known-keys: SCHEMA_VERSION:6" "$kk" "SCHEMA_VERSION:6"
  fixed_line="$(printf '%s' "$kk" | grep '^FIXED:')"
  assert_contains "known-keys: FIXED:にteam_modeを含む" "$fixed_line" "team_mode"
  assert_contains "known-keys: FIXED:にmachine_roleを含む" "$fixed_line" "machine_role"
  # ⚠️ 廃止済み能力軸キー名をソースへ直接書かない（AC-5の0件検査に自分自身が
  # 引っかかるため）。実行時に文字列を組み立てる。
  _underscore='_'
  _retired_key="git${_underscore}role"
  assert_not_contains "known-keys: FIXED:に廃止済み能力軸キーを含まない（本人決定Decisions/2026-09-07-profile-axes-consolidation対象の1つ）" "$fixed_line" "$_retired_key"
  n="$(printf '%s' "${fixed_line#FIXED:}" | tr ',' '\n' | grep -c .)"
  assert_eq "known-keys: FIXED:の要素数は6（メタ2＋能力軸3＋excluded_models）" "6" "$n"

  # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 上のcontains/件数
  # チェックだけでは、誤った6キーへ全体が同時に変わっても通ってしまう
  # （例: team_mode/machine_roleが偶然両方含まれる別の6キー集合）。
  # 要件AC-1が定めるリテラル6キー集合と、ソート済み文字列として直接比較する。
  actual_sorted="$(printf '%s' "${fixed_line#FIXED:}" | tr ',' '\n' | sort | tr '\n' ',')"
  expected_sorted="$(printf 'schema_version\nprofile_slug\nteam_mode\nno_read_paths\nmachine_role\nexcluded_models\n' | sort | tr '\n' ',')"
  assert_eq "AC-1: known-keysのFIXED集合が期待6キー(リテラル集合)と完全一致する" "$expected_sorted" "$actual_sorted"
}

echo "=== 65. FX-I1〜I3: bootstrap結合・3モードの開幕1行がそれぞれちょうど1行現れ、他2モードは0行（AC-6①） ==="
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
      "role.leader: configured model=opus-main"
    sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=$v/" "$FXI"
    ctx="$(run_bootstrap_with_profile "$VD" "$FXI")"

    case "$v" in
      solo) expect='🧭 現在＝単独モード（リーダーが全工程を自分で行います。第三者検証はありません）。他のモード＝軽量／フル。切り替えたいときは言ってください' ;;
      lean) expect='🧭 現在＝軽量モード（実装者と検証職を置き、適用工程ごとに1巡で回します）。他のモード＝単独／フル。切り替えたいときは言ってください' ;;
      full) expect='🧭 現在＝フルモード（職種ごとに担当を立て、指摘が収まるまで検証を回します）。他のモード＝単独／軽量。切り替えたいときは言ってください' ;;
    esac
    assert_contains "FX-I(${v}): 期待文字列と完全一致する行が含まれる" "$ctx" "$expect"
    n="$(printf '%s' "$ctx" | grep -Fx -c "$expect")"
    assert_eq "FX-I(${v}): 期待文字列の行がちょうど1行" "1" "$n"
    total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
    assert_eq "FX-I(${v}): 🧭で始まる行が合計ちょうど1行（他モードは0行）" "1" "$total_mode_lines"
    rm -rf "$VD"
  done
}

echo "=== 66. FX-I4・FX-I6: bootstrap結合・team_modeがunknown、またはresolveがMINIMALのときは未確定行がちょうど1行（AC-7） ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'

  VD="$(mktemp -d)"; make_full_vault "$VD"
  FXI4="$(mktemp -d)/fxi4.md"
  make_v2_profile "$FXI4" \
    "role.leader: configured model=opus-main"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unknown/" "$FXI4"
  ctx="$(run_bootstrap_with_profile "$VD" "$FXI4")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED")"
  assert_eq "FX-I4(team_mode:unknown): 未確定行がちょうど1行" "1" "$n"
  total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "FX-I4: 🧭行の合計もちょうど1行（3モードの行は0行）" "1" "$total_mode_lines"
  rm -rf "$VD"

  # FX-I6: resolveがMINIMALを返す実体（既存のT5＝既知キー欠落を流用する）。
  VD2="$(mktemp -d)"; make_full_vault "$VD2"
  FXI6="$(mktemp -d)/fxi6.md"
  make_v2_profile "$FXI6" \
    "role.leader: configured model=opus-main"
  python3 - "$FXI6" <<'PYEOF'
import sys
path = sys.argv[1]
lines = [l for l in open(path).read().splitlines() if not l.startswith("machine_role:")]
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  ctx="$(run_bootstrap_with_profile "$VD2" "$FXI6")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED")"
  assert_eq "FX-I6(MINIMAL/T5): 未確定行がちょうど1行" "1" "$n"
  total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "FX-I6: 🧭行の合計もちょうど1行（3モードの行は0行）" "1" "$total_mode_lines"
  rm -rf "$VD2"
}

echo "=== 67. FX-R1・FX-R2（AC-10）: 退役キー'primary-reviewer'はV1-bで空席、改名後'verifier'はagents/verifier.mdが実在するのでFALLBACK採用 ==="
{
  FXR1="$(mktemp -d)/fxr1.md"
  make_v2_profile "$FXR1" \
    "role.leader: configured model=opus-main" \
    "role.primary-reviewer: unavailable model=bedrock-opus" \
    "fallback.primary-reviewer: configured model=opus-main"
  out="$(resolve_v2 "$FXR1")"  || true
  assert_contains "FX-R1(陰性): VACANT:にprimary-reviewerが出る" "$out" "VACANT:primary-reviewer"
  assert_contains "FX-R1: VACANT_REASONがprimary-reviewer=V1-b" "$out" "VACANT_REASON:primary-reviewer=V1-b"

  FXR2="$(mktemp -d)/fxr2.md"
  make_v2_profile "$FXR2" \
    "role.leader: configured model=opus-main" \
    "role.verifier: unavailable model=bedrock-opus" \
    "fallback.verifier: configured model=opus-main"
  out="$(resolve_v2 "$FXR2")"  || true
  assert_contains "FX-R2(陽性): FALLBACK:にverifierが出る" "$out" "FALLBACK:verifier"
  assert_not_contains "FX-R2: VACANT:に現れない" "$out" "VACANT:verifier"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-R2: 先頭フィールドはOK（exit0）" "1" "$head_ok"
}

echo "=== 68. §6.3縮退経路の回帰(ID無し・要件のfixture表とは別枠): BOOTSTRAP_ENABLE_LOCAL_PROFILE=0／LEGACY_V1(v1実体)／UNKNOWN_EXTRAを伴うOK行のいずれも、未確定行がちょうど1行・3モードの行は0行 ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'

  # ①BOOTSTRAP_ENABLE_LOCAL_PROFILE=0（解決そのものを行わない）。
  VD="$(mktemp -d)"; make_full_vault "$VD"
  ctx="$(run_bootstrap "$VD")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED")"
  assert_eq "①ゲート無効: 未確定行がちょうど1行" "1" "$n"
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
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED")"
  assert_eq "②旧版(T4-LEGACY): 未確定行がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "②旧版(T4-LEGACY): 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD2"

  # ③UNKNOWN_EXTRAを伴うOK行（team_mode自体は正しく読めていても、未知キーが
  # あれば必読除外・最小能力へ倒すので未確定行になる）。
  VD3="$(mktemp -d)"; make_full_vault "$VD3"
  FXUE="$(mktemp -d)/fxue.md"
  make_v2_profile "$FXUE" \
    "role.leader: configured model=opus-main"
  python3 - "$FXUE" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "future_key_v5: configured value=something")
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  ctx="$(run_bootstrap_with_profile "$VD3" "$FXUE")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED")"
  assert_eq "③UNKNOWN_EXTRA: 未確定行がちょうど1行" "1" "$n"
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
  cleanup_71() {
    [ -n "$BASE_WT" ] && [ -d "$BASE_WT" ] && git -C "$REPO_ROOT" worktree remove --force "$BASE_WT" >/dev/null 2>&1
    rm -rf "$SPY" "${BASE_WT:-}" 2>/dev/null
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

  # role.leader: model=opus-main（effort未指定）と
  # 一致するsettings.json（Codex一次レビュー指摘・MAJOR対応: 従来は
  # /nonexistent-dir/settings.jsonを指定しており、check_leader_settings_drift()
  # が「監視不能」警告を出す状態のまま「警告なし」と称していた。§10.5-5〜6の
  # 「正常分岐（警告が出ていない）」を字義通り満たすため、実際に一致する
  # settings.jsonを用意する＝テスト18番の「正常系」fixtureと同型）。
  SETTINGS_MATCH_71="$(mktemp -d)/settings-match-71.json"
  cat > "$SETTINGS_MATCH_71" <<'EOF'
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
    "role.leader: configured model=opus-main"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=solo/" "$FXP1"
  AFTER_LOG="$(mktemp -d)/calls-after.log"; : > "$AFTER_LOG"
  AFTER_JSON="$(mktemp -d)/after.json"
  PATH="$SPY" SPY_CALLS_LOG="$AFTER_LOG" \
    BOOTSTRAP_VAULT="$VD" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
    VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
    PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
    MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_MATCH_71" \
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
excluded_models: configured value=none
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
  PATH="$SPY" SPY_CALLS_LOG="$BEFORE_LOG" \
    BOOTSTRAP_VAULT="$VD2" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
    VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
    PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
    MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
    AIENV_MACHINE_ROLE_MARKER="$LEGACY_MARKER_71" \
    AIENV_SETTINGS_JSON_FILE="$SETTINGS_MATCH_71" \
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
  AC1_2_REFERENCE_COUNT_BEFORE_2026_09_07=29
  AC1_2_REFERENCE_COUNT_AFTER_2026_09_07=30
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
  make_v2_profile "$FXP1_72" "role.leader: configured model=opus-main"
  rc=0; out="$(resolve_v2 "$FXP1_72")" || rc=$?
  assert_eq "FX-P1: OK<TAB>schema_version=6で始まる" "1" \
    "$([[ "$out" == $'OK\tschema_version=6'* ]] && echo 1 || echo 0)"
  assert_eq "FX-P1: exit 0" "0" "$rc"
  assert_contains "FX-P1: TEAM_MODE:fullを含む" "$out" "TEAM_MODE:full"
  assert_not_contains "FX-P1: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"

  FXP2_72="$(mktemp -d)/fxp2.md"
  make_v2_profile "$FXP2_72" "role.leader: configured model=opus-main"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     configured value=sub/" "$FXP2_72"
  rc=0; out="$(resolve_v2 "$FXP2_72")" || rc=$?
  assert_eq "FX-P2: OK<TAB>schema_version=6で始まる" "1" \
    "$([[ "$out" == $'OK\tschema_version=6'* ]] && echo 1 || echo 0)"
  assert_eq "FX-P2: exit 0" "0" "$rc"
  assert_contains "FX-P2: TEAM_MODE:fullを含む" "$out" "TEAM_MODE:full"
  assert_not_contains "FX-P2: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"

  FXP3_72="$(mktemp -d)/fxp3.md"
  make_v2_profile "$FXP3_72" "role.leader: configured model=opus-main"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     not_adopted/" "$FXP3_72"
  rc=0; out="$(resolve_v2 "$FXP3_72")" || rc=$?
  assert_contains "FX-P3: V7(machine_roleの状態が不正)を含む" "$out" "V7: machine_roleの状態が不正です"
  assert_eq "FX-P3: exit 1" "1" "$rc"

  FXP4_72="$(mktemp -d)/fxp4.md"
  make_v2_profile "$FXP4_72" "role.leader: configured model=opus-main"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     configured value=primary/" "$FXP4_72"
  rc=0; out="$(resolve_v2 "$FXP4_72")" || rc=$?
  assert_contains "FX-P4: V8-b(machine_roleのvalue形式が不正)を含む" "$out" "V8-b: machine_roleのvalue形式が不正です"
  assert_eq "FX-P4: exit 1" "1" "$rc"
}

echo "=== 73. AC-4(FR-5): no_read_pathsの実パス書式の陽性1件(FX-P9)・陰性2件(FX-P10・FX-P11) ==="
{
  FXP9_73="$(mktemp -d)/fxp9.md"
  make_v2_profile "$FXP9_73" "role.leader: configured model=opus-main"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=~/work/old,~/Data/private#" "$FXP9_73"
  rc=0; out="$(resolve_v2 "$FXP9_73")" || rc=$?
  assert_eq "FX-P9: OKで始まる（大文字を含む実パスも受理）" "1" \
    "$([[ "$out" == OK* ]] && echo 1 || echo 0)"
  assert_eq "FX-P9: exit 0" "0" "$rc"

  FXP10_73="$(mktemp -d)/fxp10.md"
  make_v2_profile "$FXP10_73" "role.leader: configured model=opus-main"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=~/work/old, ~/tmp/x#" "$FXP10_73"
  rc=0; out="$(resolve_v2 "$FXP10_73")" || rc=$?
  assert_contains "FX-P10: T6を含む" "$out" "T6"
  assert_contains "FX-P10: 属性の形式が不正ですを含む" "$out" "属性の形式が不正です"
  assert_eq "FX-P10: exit 1" "1" "$rc"

  FXP11_73="$(mktemp -d)/fxp11.md"
  make_v2_profile "$FXP11_73" "role.leader: configured model=opus-main"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=/work/old#" "$FXP11_73"
  rc=0; out="$(resolve_v2 "$FXP11_73")" || rc=$?
  assert_contains "FX-P11: V8-b(no_read_pathsのvalue形式が不正)を含む" "$out" "V8-b: no_read_pathsのvalue形式が不正です"
  assert_eq "FX-P11: exit 1" "1" "$rc"
}

echo "=== 75. AC-9(FR-13): 廃止キー残存時のUNKNOWN_EXTRA契約の陽性1件(FX-P7)・陰性1件(FX-P1) ==="
{
  FXP7_75="$(mktemp -d)/fxp7-ac9.md"
  make_v2_profile "$FXP7_75" "role.leader: configured model=opus-main"
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
  assert_contains "FX-P7: I=必読から除外の文言を含む（AI側は降格）" "$ctx" "必読から除外"
  assert_contains "FX-P7: I=最小能力の文言を含む" "$ctx" "最小能力"

  FXP1_75="$(mktemp -d)/fxp1-ac9.md"
  make_v2_profile "$FXP1_75" "role.leader: configured model=opus-main"
  out="$(resolve_v2 "$FXP1_75")"
  assert_not_contains "FX-P1: R=UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"
  ctx="$(run_bootstrap_with_profile "$(mktemp -d)" "$FXP1_75")"
  assert_contains "FX-P1: I=全文Readを指示する" "$ctx" "Readで全文を読むこと"
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
  FXP_76="$(mktemp -d)/fxp-ac11.md"
  make_v2_profile "$FXP_76" "role.leader: configured model=opus-main"
  ctx_p1="$(run_bootstrap_with_profile "$VD_76" "$FXP_76")"

  sed -i '' "s/machine_role:     configured value=main/machine_role:     unknown/" "$FXP_76"
  ctx_p8="$(run_bootstrap_with_profile "$VD_76" "$FXP_76")"

  norm_p1="$(printf '%s\n' "$ctx_p1" | sed -E 's/MACHINE_ROLE:[a-z]+/MACHINE_ROLE:X/')"
  norm_p8="$(printf '%s\n' "$ctx_p8" | sed -E 's/MACHINE_ROLE:[a-z]+/MACHINE_ROLE:X/')"

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
  make_v2_profile "$FXP_76B" "role.leader: configured model=opus-main"
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
  make_v2_profile "$FXP77" "role.leader: configured model=opus-main"
  ctx77="$(run_bootstrap_with_profile "$VD77" "$FXP77" "/nonexistent-dir/settings.json" "relative/models.conf")"
  n77="$(printf '%s' "$ctx77" | grep -Fx -c "$UNCONFIRMED")"
  assert_eq "I(T13): AIENV_MODEL_DEFS_FILEが相対パスだと未確定行がちょうど1行（resolve自体がT13でloud失敗する）" "1" "$n77"
  total77="$(printf '%s' "$ctx77" | grep -c '^🧭 現在＝')"
  assert_eq "I(T13): 🧭行の合計もちょうど1行" "1" "$total77"
  rm -rf "$VD77"
}

echo "=== 78. 設計§11.3新設2件の②: 同じ絶対パスのAIENV_MODEL_DEFS_FILEなら、Iを呼び出すcwdを変えても同じ結果になる（Codexレビュー指摘・MAJOR-3対応・1巡目。R/L/LD/Cの4口はtest-model-definitions.shで既に検証済み） ==="
{
  VD78="$(mktemp -d)"; make_full_vault "$VD78"
  FXP78="$(mktemp -d)/fxp78.md"
  make_v2_profile "$FXP78" "role.leader: configured model=opus-main"
  ctx78_tmp="$(cd /tmp && run_bootstrap_with_profile "$VD78" "$FXP78" "/nonexistent-dir/settings.json" "$SHARED_MODELS_CONF")"
  ctx78_repo="$(cd "$REPO_ROOT" && run_bootstrap_with_profile "$VD78" "$FXP78" "/nonexistent-dir/settings.json" "$SHARED_MODELS_CONF")"
  ctx78_vd="$(cd "$VD78" && run_bootstrap_with_profile "$VD78" "$FXP78" "/nonexistent-dir/settings.json" "$SHARED_MODELS_CONF")"
  assert_eq "I(cwd不変性): /tmp とREPO_ROOTで同じ結果" "$ctx78_tmp" "$ctx78_repo"
  assert_eq "I(cwd不変性): /tmp とVault作業ディレクトリで同じ結果" "$ctx78_tmp" "$ctx78_vd"
  rm -rf "$VD78"
}

echo "=== 79. B1a「使用率の見える化」AC-91④⑤: 【使用率】ブロックが枠あたり1行で出る（正常キャッシュ） ==="
{
  VD79="$(mktemp -d)"; make_full_vault "$VD79"
  UC79="$(mktemp -d)"
  NOW79=1788858365
  python3 -c "import json; open('$UC79/claude-cache.json','w').write(json.dumps({'fetched_at':$NOW79-60,'five_hour':{'used_percent':25.0,'resets_at_epoch':$NOW79+1000},'seven_day':{'used_percent':46.0,'resets_at_epoch':$NOW79+90000},'model_weekly':{'used_percent':34,'resets_at_epoch':$NOW79+90000,'label':'Fable'},'last_error':None}))"
  python3 -c "import json; open('$UC79/codex-cache.json','w').write(json.dumps({'fetched_at':$NOW79-30,'five_hour':{'used_percent':66,'resets_at_epoch':$NOW79+2000},'seven_day':{'used_percent':10,'resets_at_epoch':$NOW79+90000},'last_error':None}))"

  ctx79="$(AIENV_USAGE_CACHE_DIR="$UC79" AIENV_USAGE_NOW="$NOW79" run_bootstrap "$VD79")"
  assert_contains "79: 【使用率】見出しが出る" "$ctx79" "【使用率】"
  n_claude79="$(printf '%s\n' "$ctx79" | grep -c '^Claude枠:' || true)"
  n_codex79="$(printf '%s\n' "$ctx79" | grep -c '^Codex枠:' || true)"
  n_unlimited79="$(printf '%s\n' "$ctx79" | grep -Fxc 'unlimited（Bedrock・ローカル）: 使用率なし' || true)"
  assert_eq "79: Claude枠は枠あたり1行" "1" "$n_claude79"
  assert_eq "79: Codex枠は枠あたり1行" "1" "$n_codex79"
  assert_eq "79: unlimited行はちょうど1行" "1" "$n_unlimited79"
  assert_contains "79: 委任前の同一口の案内が末尾に出る" "$ctx79" "委任の前に見直すときは同じ口＝usage_snapshot.py"

  # 2026-09-08 worker-driven一次レビューMAJOR-4対応: 見出し・接頭辞だけで
  # なく、5h/7d残量・リセット時刻・鮮度の実内容を厳密一致で検査する
  # （python3 claude/hooks/lib/usage_snapshot.pyを同じfixture・同じNOW79で
  # 直接実行し裏取り済みの期待値。tests/test-usage-snapshot.shのFX-1と
  # 同一NOW値・同種fixtureで独立に検証済みの値と一致する）。
  assert_contains "79: Claude枠の実内容（5h/7d/Fable週の残量・リセット・鮮度）が厳密一致" "$ctx79" \
    "Claude枠: 5h 残75%（リセット 18:22）／7d 残54%（09-09 19:06）／Fable週 残66%・取得 1分前"
  assert_contains "79: Codex枠の実内容（5h/7dの残量・リセット・鮮度）が厳密一致" "$ctx79" \
    "Codex枠: 5h 残34%（リセット 18:39）／7d 残90%（09-09 19:06）・取得 0分前"

  rm -rf "$VD79" "$UC79"
}

echo "=== 80. B1a「使用率の見える化」AC-91④⑤: キャッシュ欠落（未導入）でも起動が止まらない ==="
{
  VD80="$(mktemp -d)"; make_full_vault "$VD80"
  UC80="$(mktemp -d)"  # claude-cache.json/codex-cache.jsonのどちらも置かない

  ctx80="$(AIENV_USAGE_CACHE_DIR="$UC80" run_bootstrap "$VD80")"
  assert_contains "80: キャッシュ欠落でも必読ファイル案内は出る（起動は止まらない）" "$ctx80" "① タスクに着手する前に"
  assert_contains "80: 【使用率】見出しは出る" "$ctx80" "【使用率】"
  assert_contains "80: Claude枠は未導入の固定文言" "$ctx80" "Claude枠: 取得できません（キャッシュ無し＝claude-codex-usage 未導入。導入手順: README §使用率）"
  assert_contains "80: Codex枠は未導入の固定文言" "$ctx80" "Codex枠: 取得できません（キャッシュ無し＝claude-codex-usage 未導入。導入手順: README §使用率）"
  n_unlimited80="$(printf '%s\n' "$ctx80" | grep -Fxc 'unlimited（Bedrock・ローカル）: 使用率なし' || true)"
  assert_eq "80: unlimited行はちょうど1行（欠落でも行数を変えない）" "1" "$n_unlimited80"

  rm -rf "$VD80" "$UC80"
}

echo "=== 81. B1a「使用率の見える化」compute_usage_block()のfail-open3分岐: lib不在（worker-driven一次レビューMAJOR-3対応） ==="
{
  VD81="$(mktemp -d)"; make_full_vault "$VD81"
  ctx81="$(USAGE_SNAPSHOT_LIB="/nonexistent-dir/usage_snapshot.py" run_bootstrap "$VD81")"
  assert_contains "81: lib不在でも必読ファイル案内は出る（起動は止まらない）" "$ctx81" "① タスクに着手する前に"
  n_line81="$(printf '%s\n' "$ctx81" | grep -Fxc '【使用率】取得口が使えません（usage_snapshot.py が見つかりません）' || true)"
  assert_eq "81: 「見つかりません」の1行に縮退する（見出しと本文を分けない）" "1" "$n_line81"

  rm -rf "$VD81"
}

echo "=== 82. B1a「使用率の見える化」compute_usage_block()のfail-open3分岐: 非ゼロ終了（stdout有り/無しの両方・worker-driven一次レビューMAJOR-3対応） ==="
{
  # (a) 非ゼロ終了・stdoutは空（usage_snapshot.py自身の契約どおりのクラッシュ）。
  VD82A="$(mktemp -d)"; make_full_vault "$VD82A"
  FAKE_LIB_82A="$(mktemp -d)/fake-usage-snapshot-empty.py"
  cat > "$FAKE_LIB_82A" <<'EOF'
import sys
sys.exit(1)
EOF
  ctx82a="$(USAGE_SNAPSHOT_LIB="$FAKE_LIB_82A" run_bootstrap "$VD82A")"
  n_line82a="$(printf '%s\n' "$ctx82a" | grep -Fxc '【使用率】取得口が使えません（usage_snapshot.py の実行に失敗しました）' || true)"
  assert_eq "82a: 非ゼロ終了・stdout空なら「実行に失敗しました」の1行に縮退する" "1" "$n_line82a"

  # (b) 非ゼロ終了・stdoutは非空（従来はexit codeを見ておらずstdoutが
  # あれば正常ブロックとして注入してしまっていた＝MAJOR-3の指摘そのもの）。
  VD82B="$(mktemp -d)"; make_full_vault "$VD82B"
  FAKE_LIB_82B="$(mktemp -d)/fake-usage-snapshot-partial.py"
  cat > "$FAKE_LIB_82B" <<'EOF'
import sys
print("Claude枠: 5h 残99%・取得 0分前")
sys.exit(1)
EOF
  ctx82b="$(USAGE_SNAPSHOT_LIB="$FAKE_LIB_82B" run_bootstrap "$VD82B")"
  n_line82b="$(printf '%s\n' "$ctx82b" | grep -Fxc '【使用率】取得口が使えません（usage_snapshot.py の実行に失敗しました）' || true)"
  assert_eq "82b: 非ゼロ終了・stdout有りでも終了コードを見て失敗扱いにする（部分出力を正常ブロックとして注入しない）" "1" "$n_line82b"
  assert_not_contains "82b: 部分出力（stdoutにあった偽のClaude枠行）がそのまま注入されていない" "$ctx82b" "残99%"

  rm -rf "$VD82A" "$VD82B"
}

echo "=== 83. B1a「使用率の見える化」compute_usage_block()のfail-open3分岐: python3が真に不在（worker-driven一次レビューMAJOR-3対応） ==="
{
  # PATH上の全実行ファイルをsymlinkで複製し、python*系だけを除外した
  # 制限PATHを作る（run_bootstrap()はBOOTSTRAP_ENABLE_LOCAL_PROFILE=0固定
  # なのでprofile_resolve.py側のpython3呼び出しは発生しない＝
  # compute_usage_block()だけがpython3を必要とする状態を作れる）。
  NOPY_PATH_DIR="$(mktemp -d)"
  IFS=':' read -ra _path_dirs <<< "$PATH"
  for _pd in "${_path_dirs[@]}"; do
    [ -d "$_pd" ] || continue
    for _f in "$_pd"/*; do
      [ -x "$_f" ] || continue
      _base="$(basename "$_f")"
      case "$_base" in python3|python3.*|python|python2*) continue ;; esac
      [ -e "$NOPY_PATH_DIR/$_base" ] || ln -s "$_f" "$NOPY_PATH_DIR/$_base" 2>/dev/null
    done
  done

  VD83="$(mktemp -d)"; make_full_vault "$VD83"
  ctx83="$(PATH="$NOPY_PATH_DIR" USAGE_SNAPSHOT_LIB="$REPO_ROOT/claude/hooks/lib/usage_snapshot.py" run_bootstrap "$VD83")"
  assert_contains "83: python3不在でも必読ファイル案内は出る（起動は止まらない）" "$ctx83" "① タスクに着手する前に"
  n_line83="$(printf '%s\n' "$ctx83" | grep -Fxc '【使用率】取得口が使えません（python3 なし）' || true)"
  assert_eq "83: 「python3 なし」の1行に縮退する" "1" "$n_line83"

  rm -rf "$VD83" "$NOPY_PATH_DIR"
}

echo "=== 84. FR-48/AC-59: 起動注入文に宣言コマンドの呼び出しを促す⑥が1行追加される（cmux-session-todo設計v1.5 §17） ==="
{
  VD84="$(safe_mktemp_d)" || exit 1
  make_full_vault "$VD84"
  ctx84="$(run_bootstrap "$VD84")"
  assert_contains "84: ⑥の行が含まれる" "$ctx84" \
    "⑥ 最初の依頼からプロジェクトが確定したら、そのセッションのワークスペースを1回だけ宣言する: ~/work/tools/cmux-task-watch/cmux-task-declare.sh set <slug>（Dock の Next Task 枠がこのセッションのタスクに追従する。宣言済みなら呼び直さない。⚠️ 実行するのはリーダーであってフックではない）"
  n_line84="$(printf '%s\n' "$ctx84" | grep -Fxc '⑥ 最初の依頼からプロジェクトが確定したら、そのセッションのワークスペースを1回だけ宣言する: ~/work/tools/cmux-task-watch/cmux-task-declare.sh set <slug>（Dock の Next Task 枠がこのセッションのタスクに追従する。宣言済みなら呼び直さない。⚠️ 実行するのはリーダーであってフックではない）' || true)"
  assert_eq "84: ⑥はちょうど1行（改行を含まない）" "1" "$n_line84"

  # 既存①〜⑤が全部残っていること（文面も並びも変えない＝FR-48）。
  assert_contains "84: ①が残る" "$ctx84" "① タスクに着手する前に"
  assert_contains "84: ②が残る" "$ctx84" "② 上記を読み終えるまで"
  assert_contains "84: ③が残る" "$ctx84" "③ ユーザーの質問に関連するキーワードで"
  assert_contains "84: ④が残る" "$ctx84" "④ 新たな知見・判断・好み・プロジェクト変化が出たら"
  assert_contains "84: ⑤が残る" "$ctx84" "⑤"

  # 差分レビュー指摘#5: 存在だけでなく①→②→③→④→⑤→⑥の順序不変を検査する
  # （行位置の比較。並べ替えるとここで落ちる）。
  assert_ascending_line_positions "84: ①→②→③→④→⑤→⑥の順序が保たれる" "$ctx84" \
    "①" "②" "③" "④" "⑤" "⑥"

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
  # $HOME/work/tools/cmux-task-watch/cmux-task-declare.sh にもスパイを置く
  # （固定パスを直接実行する誤実装がPATHスパイを迂回してもここで捕まる）。
  # 実機の~/work/toolsには一切触れないよう、隔離HOMEを別途用意する。
  FAKE_HOME85="$(safe_mktemp_d)" || exit 1
  mkdir -p "$FAKE_HOME85/work/tools/cmux-task-watch"
  MARKER_DIR85B="$(safe_mktemp_d)" || exit 1
  MARKER85B="$MARKER_DIR85B/declare-was-called-fixedpath.marker"
  cat > "$FAKE_HOME85/work/tools/cmux-task-watch/cmux-task-declare.sh" <<EOF
#!/bin/bash
touch "$MARKER85B"
EOF
  chmod +x "$FAKE_HOME85/work/tools/cmux-task-watch/cmux-task-declare.sh"

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
  assert_eq "85: 偽cmux-task-declare.sh(固定パス \$HOME/work/tools/cmux-task-watch/経由)も呼ばれない" "0" "$marker_exists85b"

  state_exists85=0
  if [ -e "$STATE85" ]; then state_exists85=1; fi
  assert_eq "85: 宣言記録ファイルも作られない" "0" "$state_exists85"

  rm -rf "$VD85" "$SPY_DIR85" "$MARKER_DIR85" "$FAKE_HOME85" "$MARKER_DIR85B" "$STATE_DIR85"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
