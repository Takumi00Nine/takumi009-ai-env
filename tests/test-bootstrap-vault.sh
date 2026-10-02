#!/usr/bin/env bash
# claude/hooks/bootstrap-vault.sh のユニットテスト（メイン/サブ両方の回帰テスト）。
#
# 実 Vault($HOME/Data/obsidian) には依存しない。BOOTSTRAP_VAULT 環境変数で
# 毎回ダミーのfixtureディレクトリへ差し替えてスクリプトを実行し、
# 「存在するファイルだけが必読リストに載る」ことを検証する
# （2026-07-08 設計判断: install-sub.sh 対応でメイン/サブ両方の回帰を担保）。
#
# 実行方法: bash tests/test-bootstrap-vault.sh
#
# v1.1（機能の部品化）で分けた働きの節は移し替えた（由来＝本ファイル）: 開幕行・⑤・machine_role 保留・
# 実体プロファイル警告・配役表の解決器 → tests/test-session-status.sh（Team）／⑥ 宣言状態 →
# tests/test-declare-state.sh（Dock）／ブロック全体の形・ワーカー判定・外部プロセス数 →
# tests/test-session-start-compose.sh（Core）／注入の段階＝Dock の B 行 → tests/test-integration.sh（Core）。
# 本ファイルに残るのは必読一覧・ヘルス節（AI Brain の寄与）。
# A-v6-4: フックが cmux を呼ぶようになるため、本ファイルの全ケースで PATH 先頭に「応答
# しない cmux スタブ」を置き、実 cmux（実ソケット）に触れないよう固定する（safe_mktemp_d の直後）。

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

# v6 A-v6-4: 全ケースで cmux の実体を「非 0 で即終了するスタブ」に固定する（実ソケットに触れない）。
# 宣言 CLI と共有の上書き口は外側シェルの値に依存させない（既定＝隔離 HOME の既定パス・PATH の cmux・5 秒）。
CMUX_FIXED_STUB_DIR="$(safe_mktemp_d)" || exit 1
printf '#!/bin/bash\nexit 9\n' > "$CMUX_FIXED_STUB_DIR/cmux"
chmod +x "$CMUX_FIXED_STUB_DIR/cmux"
export PATH="$CMUX_FIXED_STUB_DIR:$PATH"
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT BOOTSTRAP_CMUX_LIB_DIR

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
# BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 固定（実機の profile.md を読まない。P1 機構は tests/test-session-status.sh で検証）。
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
HEALTH_SHARED_VAULT="$(mktemp -d)"
make_full_vault "$HEALTH_SHARED_VAULT"

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
  # 見出し「【セッション開始ブートストラップ｜ハーネス強制注入】」は合成器の配置表の固定文（v1.1 設計 §5.5）＝
  # tests/test-session-start-compose.sh が見る。ここは AI Brain の寄与の本文（必読一覧）が健在であることを見る。
  assert_contains "S-1: 本文は健在（必読一覧）" "$ctx" "Preferences/absolute-rules.md"
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
  assert_true "\$SCRIPT の直接起動が検査対象に含まれている（陽性の実測 ${n_direct} 箇所）" "$([ "$n_direct" -ge 1 ] && echo 1 || echo 0)"
}

echo "=== 8f. 判定機の入力が壊れていても本文は止めない（NFR-2 fail-open）: latest.json 破損＝週次の整合 1 件・last-run 解析不能＝破損 ==="
{
  INV_DIR="$(mktemp -d)"
  printf 'not json' > "$INV_DIR/latest.json"
  ctx="$(run_bootstrap "$HEALTH_SHARED_VAULT" "" "" "$INV_DIR" "$HEALTH_FX_ROOT/S-1/last-run.json")"
  assert_contains "latest.json 破損: phase1-inventory の失敗 1 件（⑥）" "$ctx" "step=Phase1③ vault_inventory（記録の整合） result=失敗 actor=AI"
  assert_contains "latest.json 破損: ヘッダ inventory=none" "$(health_header "$ctx")" "inventory=none"
  # 見出しの検査は合成器スイートへ移した（v1.1 設計 §5.5＝見出しは合成器の配置表の固定文）。
  assert_contains "本文は健在（必読一覧）" "$ctx" "Preferences/absolute-rules.md"
  rm -rf "$INV_DIR"
}

echo "=== 8g. AC-1 ②（読込の入口＝引数なしの hook 形）: stdin {} で exit 0・additionalContext に Preferences/absolute-rules.md ==="
{
  OBS8G="$(mktemp -d)"
  rc8g=0
  out8g="$(printf '{}' \
    | BOOTSTRAP_VAULT="$HEALTH_SHARED_VAULT" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
      HEALTH_OBSERVATION_FILE="$OBS8G/session-observation.json" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT")" || rc8g=$?
  assert_eq "AC-1 ②: exit 0" "0" "$rc8g"
  assert_contains "AC-1 ②: additionalContext に Preferences/absolute-rules.md" \
    "$(printf '%s' "$out8g" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" "Preferences/absolute-rules.md"
  rm -rf "$OBS8G"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
