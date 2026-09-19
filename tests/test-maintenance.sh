#!/usr/bin/env bash
# scripts/maintenance.sh のユニットテスト（週次メンテナンスランナー本体・設計書§1・PR2）。
#
# 品質方針（2026-07-16リーダー指示「安全設計...と、その失敗系テストは一切
# 簡略化不可」）: Phase0〜Phase3のオーケストレーション自体（fail-fast判定・
# エラー隔離・anomaly集計・last-run.json更新条件・実行ごと一意ディレクトリ・
# latest symlinkの原子性・30日保持削除）を検証対象とする。check-drift.sh・
# fragments_log.py等の個々の検出ロジック自体は各自の専用テストスイート
# （tests/test-check-drift.sh等）で既に検証済みのため、本ファイルでは
# FAKEスタブに置き換えて「maintenance.shがそれらの結果に正しく反応するか」
# だけを狙い撃ちで検証する（重複テストの回避）。
#
# 実HOME・実Vault・実AIENV_REPO・実launchd・実osascriptには一切
# 依存しない: 毎回FAKEリポジトリ（scripts/lib・maintenance_run_step.pyは
# 実物をコピーして再利用し、check-drift.sh・export-public-vault.sh・
# fragments_log.py・vault_inventory.pyはFAKEスタブに差し替える）を組み立てて
# maintenance.shを実行する。backup-vault.shだけは実物を使う
# （MAINTENANCE_INTERNAL_CALLバイパスの実結線を検証するため）。
# 例外が1つだけある: §16.6.2系統①（実cmux-task-declare.shとの結合試験・
# DT-7とは独立）は、REPO_ROOT（このテストが実際に走っている本リポジトリ・
# 移設先のワークツリー）配下の cmux/cmux-task-declare.sh の実物スクリプトを
# 読みに行く（cmux-session-todo v3で宣言CLIの実体がdotfilesからai-envへ
# 移設されたため。実machineの ~/work/takumi009-ai-env が未マージでも
# ここは常に「今テストしている木」を見るので影響されない＝検証1巡目
# MAJOR #12対応。cmux自体は隔離スタブに差し替え、宣言記録も隔離パスへ
# 書く＝実cmuxにも実記録にも触れない）。
#
# 実行方法: bash tests/test-maintenance.sh

set -uo pipefail

# mktemp -dの失敗を検査せず使うと、書込み不能なsandbox環境で
# HOME/WORK_ROOTが空文字列になり、以後の全パスがルート直下（例:
# "$HOME/work/..." → "/work/..."）へ解決されてしまう事故が起こる
# （2026-09-09 verifier実装レビュー1巡目 #6実測: read-only環境で見かけ上の
# PASS/FAILが大量発生した）。全mktemp呼び出しを終了コードで検査し、返った
# パスが空・"/"・非ディレクトリ・非空（mktempが返すはずのない既存ディレクトリの
# 疑い）のいずれでもないことまで確かめてから使う。
validate_temp_dir() {
  local dir="$1" label="$2"
  if [[ -z "$dir" ]]; then
    echo "FATAL: ${label}用のmktemp -dが空のパスを返しました（隔離が保証できません）。" >&2
    exit 1
  fi
  if [[ "$dir" == "/" ]]; then
    echo "FATAL: ${label}用のmktemp -dがルートディレクトリを返しました（隔離が保証できません）。" >&2
    exit 1
  fi
  if [[ ! -d "$dir" ]]; then
    echo "FATAL: ${label}用のmktemp -dがディレクトリを作成できませんでした: '${dir}'" >&2
    exit 1
  fi
  if [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    echo "FATAL: ${label}用の一時ディレクトリが空ではありません（mktempが返すはずの新規ディレクトリではない疑い・既存ディレクトリの誤指定を拒否）: '${dir}'" >&2
    exit 1
  fi
}

HOME="$(mktemp -d)" || {
  echo "FATAL: mktemp -dに失敗しました（HOME隔離用）。書込み可能な一時領域が無い可能性があります。" >&2
  exit 1
}
validate_temp_dir "$HOME" "HOME"
export HOME
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# §16.6.2系統①（実物cmux-task-declare.shとの結合テスト）は、REPO_ROOT
# （$TESTS_DIR/..＝本ファイルが属するリポジトリ／ワークツリー自身）配下の
# 実物を参照する。検証1巡目 MAJOR #12: 以前は実machineの
# ~/work/takumi009-ai-env を参照していたため、その場所が未マージ／未配置の
# 環境（このワークツリーとは無関係な実行環境）では系統①がSKIPし続け、
# 本来なら実行できるはずの検査を10件分黙って落としていた。REPO_ROOT基準
# なら「今テストしている木」に常に実体があるので、実machineの状態に
# 依存しない。
REAL_CMUX_TASK_DECLARE="$REPO_ROOT/cmux/cmux-task-declare.sh"
WORK_ROOT="$(mktemp -d)" || {
  echo "FATAL: mktemp -dに失敗しました（WORK_ROOT隔離用）。書込み可能な一時領域が無い可能性があります。" >&2
  exit 1
}
validate_temp_dir "$WORK_ROOT" "WORK_ROOT"

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
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
}
assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$desc"; else fail_case "$desc (ファイルが存在しません: $path)"; fi
}
assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then pass "$desc"; else fail_case "$desc (存在してはいけないのに存在する: $path)"; fi
}
assert_files_identical() {
  local desc="$1" file_a="$2" file_b="$3"
  if cmp -s "$file_a" "$file_b"; then pass "$desc"; else fail_case "$desc (バイト単位で不一致: $file_a / $file_b)"; fi
}

# =============================================================================
# FAKEリポジトリの組み立て
# =============================================================================

# $1 = FAKEリポジトリのルート
setup_fake_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts/lib" "$repo/scripts/vault-agents"
  cp "$REPO_ROOT/scripts/maintenance.sh" "$repo/scripts/maintenance.sh"
  cp "$REPO_ROOT/scripts/backup-vault.sh" "$repo/scripts/backup-vault.sh"
  cp "$REPO_ROOT/scripts/lib/pid-lock.sh" "$repo/scripts/lib/pid-lock.sh"
  cp "$REPO_ROOT/scripts/lib/status-file.sh" "$repo/scripts/lib/status-file.sh"
  cp "$REPO_ROOT/scripts/lib/macos-notify.sh" "$repo/scripts/lib/macos-notify.sh"
  cp "$REPO_ROOT/scripts/vault-agents/maintenance_run_step.py" "$repo/scripts/vault-agents/maintenance_run_step.py"
  chmod +x "$repo/scripts/maintenance.sh" "$repo/scripts/backup-vault.sh"

  # --- FAKE check-drift.sh（環境変数で終了コード・JSON出力を制御） ---
  cat > "$repo/scripts/check-drift.sh" <<'FAKEEOF'
#!/usr/bin/env bash
echo "[fake-check-drift] human readable line"
if [[ -n "${FAKE_DRIFT_SLEEP:-}" ]]; then sleep "$FAKE_DRIFT_SLEEP"; fi
# デフォルトJSONは変数に切り出してから${FAKE_DRIFT_JSON:-...}へ渡す（2026-08-10
# 工程横断レビュー対応中に発見・修正: `${VAR:-{"a": 0}}`のようにデフォルト値
# 本体へ直接リテラルの{}を書くと、bashのパラメータ展開パーサは`:-`後で最初に
# 現れる非エスケープの`}`を展開の終端とみなす＝デフォルトJSON内の最初の`}`で
# 展開が終わってしまい、直後の`}`が展開の外側の生のリテラル文字として残る。
# FAKE_DRIFT_JSONを明示的に指定した呼び出し（本ファイル多数のテストが使用）
# では、そのJSON文字列の直後に常に余分な`}`が1つ付与されてしまい、json.loads()
# で構文エラーになる（実測発見。それまでのテストはこの出力をjson.loads()せず
# 部分文字列一致でしか見ていなかったため症状が顕在化していなかった）。
FAKE_DRIFT_DEFAULT_JSON='{"total_drift": 0, "item4_drift": 0, "drift_excluding_item4": 0, "unknown_config_keys": 0}'
echo "${FAKE_DRIFT_JSON:-$FAKE_DRIFT_DEFAULT_JSON}"
exit "${FAKE_DRIFT_EXIT:-0}"
FAKEEOF
  chmod +x "$repo/scripts/check-drift.sh"

  # --- FAKE export-public-vault.sh ---
  cat > "$repo/scripts/export-public-vault.sh" <<'FAKEEOF'
#!/usr/bin/env bash
echo "[fake-export] called" >> "${FAKE_EXPORT_CALL_LOG:-/dev/null}"
exit "${FAKE_EXPORT_EXIT:-0}"
FAKEEOF
  chmod +x "$repo/scripts/export-public-vault.sh"

  # --- FAKE 検出器（Python）: fragments_log.py / vault_inventory.py ---
  # bash 3.2（macOS既定・本環境の`bash`はこれ）には`${var^^}`（大文字化）が
  # 無いため`tr`で移植性のある形にする。
  local py_detector upper default_json
  for py_detector in fragments_log vault_inventory; do
    upper="$(echo "$py_detector" | tr '[:lower:]' '[:upper:]')"
    # fragments_log.pyの実物は常にscan_error_count・fragments（配列）・truncatedを
    # 含む契約。FAKEの既定出力もその契約に合わせる（既定'{}'のままだと
    # 「正常系のはずのテストがキー欠落でanomaly扱いになる」FAKE側の不整合になる）。
    default_json='{}'
    [[ "$py_detector" == "fragments_log" ]] && default_json='{"scan_error_count": 0, "fragments": [], "truncated": []}'
    cat > "$repo/scripts/vault-agents/${py_detector}.py" <<PYEOF
#!/usr/bin/env python3
import os, sys
print(os.environ.get("FAKE_${upper}_JSON", '$default_json'))
sys.exit(int(os.environ.get("FAKE_${upper}_EXIT", "0")))
PYEOF
    chmod +x "$repo/scripts/vault-agents/${py_detector}.py"
  done
}

# fake osascript（実通知を飛ばさず、呼び出し内容だけ記録する）。
# $1 = 記録先ディレクトリ（PATHの先頭へ追加する）。
setup_fake_osascript() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/osascript" <<'FAKEEOF'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_OSASCRIPT_LOG:-/dev/null}"
exit 0
FAKEEOF
  chmod +x "$bindir/osascript"
}

# FAKE cmux-task-declare.sh（週次メンテ側テスト専用の契約スタブ・設計書
# §16.6.2「テスト内で定義する10行程度のスクリプトが§3.3の終了コード契約を
# そのまま演じる」）。担当Bが別リポジトリで実装中の実物には一切依存せず、
# prune()のrc=0/1/2/3（v1.6でrc=3=内部エラーを追加）とstdout契約
# （<UUID><TAB><slug>を0行以上／rc=1・2・3は空）だけを演じる。呼ばれるたび
# FAKE_PRUNE_CALL_LOGへ1行追記する（AC-57①「掃除の入口が1回だけ呼ばれる」の
# 検査対象）。
# 挙動はFAKE_PRUNE_MODE（既定ok0）で切り替える。
#   ok0 = rc=0でFAKE_PRUNE_STDOUTをそのまま出す（既定は空＝0件消した扱い）
#   rc1 = rc=1・何も出さない（接続不可＝workspace list取得失敗＝F-22相当）
#   rc2 = rc=2・何も出さない（宣言記録が破損＝§3.1相当）
#   rc3 = rc=3・何も出さない（内部エラー＝取得後の書込等に失敗＝§3.3相当）
# FAKE_PRUNE_SLEEPを指定するとその秒数だけ応答を遅らせる（F-24のtimeout検査用。
# 呼び出しログへの記録はsleepより前に行うため、timeoutで打ち切られても
# 「呼ばれた」こと自体は正しく1回だけ記録される）。
setup_fake_prune_cmd() {
  local path="$1"
  cat > "$path" <<'FAKEEOF'
#!/usr/bin/env bash
echo "called $*" >> "${FAKE_PRUNE_CALL_LOG:-/dev/null}"
if [[ "${1:-}" != "prune" ]]; then
  echo "usage: cmux-task-declare.sh prune" >&2
  exit 64
fi
if [[ -n "${FAKE_PRUNE_SLEEP:-}" ]]; then sleep "${FAKE_PRUNE_SLEEP}"; fi
case "${FAKE_PRUNE_MODE:-ok0}" in
  ok0)
    printf '%s' "${FAKE_PRUNE_STDOUT:-}"
    exit 0
    ;;
  rc1)
    echo "ワークスペース一覧を取得できませんでした。1件も削除していません。" >&2
    exit 1
    ;;
  rc2)
    echo "宣言記録が破損しています。" >&2
    exit 2
    ;;
  rc3)
    echo "内部エラー: 記録の書込に失敗しました。" >&2
    exit 3
    ;;
esac
FAKEEOF
  chmod +x "$path"
}

# 実cmux-task-declare.shとの結合試験専用の最小cmuxスタブ（設計書§16.6.2
# 系統①）。list-windows と workspace list --window <id> の2コマンドだけに
# 応答する（cmd_prune()のcollect_alive_uuidsが呼ぶのはこの2つだけ・
# cmux-task-declare.sh:242-264参照）。制御は$state_dir配下のファイルで行う。
#   fail_list_windows        存在すればlist-windowsを非0にする(接続不可を模擬)
#   windows.json              list-windowsの応答本体（呼び出し前に用意する）
#   workspaces.<win>.json     workspace list --window <win>の応答本体
#   all-calls.log             受けた全呼出しを1行1回で集約記録(応答の成否に
#                              関わらず記録する・AC-34の書込系ゼロ検査に使う。
#                              verifier実装レビュー2巡目#10対応)
# $1 = スタブ本体を置くパス（実行可能ファイル） $2 = 制御ディレクトリ
setup_real_cmux_stub() {
  local bin_path="$1" state_dir="$2"
  mkdir -p "$state_dir"
  # 非quotedヒアドキュメント終端（<<EOF）で$state_dirだけを生成時に埋め込み、
  # スタブ自身の実行時ロジック（\$1等）はバックスラッシュでエスケープして
  # そのまま出力する（bash32-strict-mode-pitfallsの「デフォルト値へJSONを
  # 直接埋め込むと`}`でパーサが誤解する」落とし穴を避けるため、JSON本体は
  # 呼び出し側が別ファイルへ書き、スタブはcatするだけにする）。
  cat > "$bin_path" <<EOF
#!/usr/bin/env bash
STATE_DIR="$state_dir"
echo "\$*" >> "\$STATE_DIR/all-calls.log"
if [[ "\$1" == "--json" && "\$2" == "list-windows" ]]; then
  if [[ -e "\$STATE_DIR/fail_list_windows" ]]; then
    echo "stub cmux: list-windows failed" >&2
    exit 1
  fi
  cat "\$STATE_DIR/windows.json"
  exit 0
fi
if [[ "\$1" == "--json" && "\$2" == "workspace" && "\$3" == "list" && "\$4" == "--window" ]]; then
  win="\$5"
  if [[ ! -f "\$STATE_DIR/workspaces.\${win}.json" ]]; then
    echo "stub cmux: no such window: \$win" >&2
    exit 1
  fi
  cat "\$STATE_DIR/workspaces.\${win}.json"
  exit 0
fi
echo "stub cmux: unsupported invocation: \$*" >&2
exit 1
EOF
  chmod +x "$bin_path"
}

# 共通セットアップ: FAKEリポジトリ・Vault・AIENV_REPO・環境変数一式を用意する。
# 呼び出し後、下記のグローバル変数が使える。
# REPO / VAULT / AIENV_REPO / LOG_ROOT / OSASCRIPT_LOG / EXPORT_CALL_LOG
# / PRUNE_STUB / PRUNE_CALL_LOG
setup_test_env() {
  local test_dir="$1"
  REPO="$test_dir/repo"
  VAULT="$test_dir/vault"
  AIENV_REPO="$test_dir/aienv"
  LOG_ROOT="$test_dir/logs/maintenance"
  local osascript_dir="$test_dir/bin"
  OSASCRIPT_LOG="$test_dir/osascript.log"
  EXPORT_CALL_LOG="$test_dir/export-call.log"
  # 既定は「掃除の入口はあるが対象0件」の契約スタブ（FR-47・設計書§16）。
  # 既存テスト（本ファイルのFR-47追加より前からある全テスト）はこの新工程を
  # 意識していないため、既定を「実施したが対象なし」にしておくことで
  # last_result_summary・last_success_atへの副作用を出さない（add_info_note
  # はrc=0のOK系では呼ばれないため）。掃除そのものを狙い撃ちで検査する
  # テストだけがMAINTENANCE_TASK_PRUNE_CMD/FAKE_PRUNE_MODE等を個別に上書きする。
  PRUNE_STUB="$test_dir/fake-cmux-task-declare.sh"
  PRUNE_CALL_LOG="$test_dir/prune-call.log"
  setup_fake_prune_cmd "$PRUNE_STUB"
  # backup-vault.sh自身のCLI多重起動防止ロック（既定は$TMPDIR/aienv-backup-
  # vault.lock）を実TMPDIR/実/tmpから隔離する。テストごとに専用のTMPDIRを
  # 割り当てることで、backup-vault.sh自身の"busy"（＝別のbackup-vault.sh
  # インスタンスが実行中）を安全に再現できるようにする。
  TEST_TMPDIR="$test_dir/tmp"
  mkdir -p "$TEST_TMPDIR"

  mkdir -p "$VAULT/Knowledge" "$VAULT/Fragments" "$AIENV_REPO/vault-public"
  setup_fake_repo "$REPO"
  setup_fake_osascript "$osascript_dir"
  export PATH="$osascript_dir:$PATH"

  git -C "$VAULT" init -q -b main
  git -C "$VAULT" config user.email test@example.invalid
  git -C "$VAULT" config user.name test
  echo dummy > "$VAULT/Knowledge/dummy.md"
  git -C "$VAULT" add -A && git -C "$VAULT" commit -q -m init >/dev/null

  git -C "$AIENV_REPO" init -q -b main
  git -C "$AIENV_REPO" config user.email test@example.invalid
  git -C "$AIENV_REPO" config user.name test
  echo readme > "$AIENV_REPO/vault-public/README.md"
  git -C "$AIENV_REPO" add -A && git -C "$AIENV_REPO" commit -q -m init >/dev/null
}

# maintenance.shを実行する（既定タイムアウトはテスト用に短縮）。
run_maintenance() {
  # 呼び出し側が`TIMEOUT_TASK_PRUNE=1 run_maintenance`のように個別の
  # timeoutを上書きできるよう、`:=`でアンビエント環境変数に既定値を補うだけに
  # とどめる（固定で`VAR=10 ... bash script.sh`と書くと、呼び出し側が事前に
  # 設定したアンビエント値より本関数内の再代入が常に勝ってしまい、上書きが
  # 一切効かなくなる＝本テスト作成時に実際に踏んだ落とし穴）。
  : "${TIMEOUT_BACKUP_VAULT:=10}"
  : "${TIMEOUT_EXPORT_PUBLIC_VAULT:=10}"
  : "${TIMEOUT_CHECK_DRIFT:=2}"
  : "${TIMEOUT_FRAGMENTS_LOG:=10}"
  : "${TIMEOUT_VAULT_INVENTORY:=10}"
  : "${MAINTENANCE_STALE_LOCK_SECONDS:=3600}"
  # 宣言記録の掃除（FR-47・設計書§16）。既定は上のsetup_test_env()が用意した
  # 「対象0件」の契約スタブを指す。掃除そのものを狙い撃ちで検査するテストは
  # `MAINTENANCE_TASK_PRUNE_CMD=... FAKE_PRUNE_MODE=... run_maintenance`の
  # ように個別に上書きする（他のTIMEOUT_*と同じ`:=`の流儀）。
  : "${TIMEOUT_TASK_PRUNE:=5}"
  : "${MAINTENANCE_TASK_PRUNE_CMD:=$PRUNE_STUB}"
  VAULT="$VAULT" AIENV_REPO="$AIENV_REPO" MAINTENANCE_LOG_ROOT="$LOG_ROOT" TMPDIR="$TEST_TMPDIR" \
    FAKE_OSASCRIPT_LOG="$OSASCRIPT_LOG" FAKE_EXPORT_CALL_LOG="$EXPORT_CALL_LOG" \
    FAKE_PRUNE_CALL_LOG="$PRUNE_CALL_LOG" \
    TIMEOUT_BACKUP_VAULT="$TIMEOUT_BACKUP_VAULT" TIMEOUT_EXPORT_PUBLIC_VAULT="$TIMEOUT_EXPORT_PUBLIC_VAULT" \
    TIMEOUT_CHECK_DRIFT="$TIMEOUT_CHECK_DRIFT" TIMEOUT_FRAGMENTS_LOG="$TIMEOUT_FRAGMENTS_LOG" \
    TIMEOUT_VAULT_INVENTORY="$TIMEOUT_VAULT_INVENTORY" \
    TIMEOUT_TASK_PRUNE="$TIMEOUT_TASK_PRUNE" MAINTENANCE_TASK_PRUNE_CMD="$MAINTENANCE_TASK_PRUNE_CMD" \
    MAINTENANCE_STALE_LOCK_SECONDS="$MAINTENANCE_STALE_LOCK_SECONDS" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    "$@" bash "$REPO/scripts/maintenance.sh" > "$LAST_STDOUT" 2> "$LAST_STDERR"
}

# 最新の実行ディレクトリ（latest symlinkの実体）を返す。
latest_run_dir() {
  python3 -c "import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(p.resolve() if p.is_symlink() else '')" "$LOG_ROOT/latest"
}

echo "=== 1. 正常系: 全Phase成功・anomalyなし・last_success_at更新・候補件数記録・通知なし ==="
{
  T="$WORK_ROOT/t1"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  # fragments が 2 件（truncated 1 件は数えない）の週を模擬する。
  FAKE_FRAGMENTS_LOG_JSON='{"scan_error_count": 0, "fragments": [{"title": "a"}, {"title": "b"}], "truncated": [{"title": "c"}]}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  RUN_DIR="$(latest_run_dir)"
  assert_file_exists "latest symlinkの実体が存在する" "$RUN_DIR/fragments.json"
  assert_file_not_exists "Phase2（apply-status.json）はもう作られない" "$RUN_DIR/apply-status.json"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "started_atが記録される" "$LAST_RUN" "started_at"
  assert_contains "last_success_atが記録される（完全正常終了）" "$LAST_RUN" "last_success_at\":"
  assert_contains "last_result=successが記録される" "$LAST_RUN" "\"last_result\": \"success\""
  assert_contains "last_result_summaryは空文字列" "$LAST_RUN" "\"last_result_summary\": \"\""
  assert_eq "fragments_candidatesがFAKEのfragments配列長(2)で記録される（truncatedは数えない）" \
    "2" "$(jq -r '.fragments_candidates' "$LOG_ROOT/last-run.json")"
  EXPECTED_SINCE="$(date -u -v-7d +%Y-%m-%d)"
  assert_eq "fragments_sinceが--sinceの日付で記録される" \
    "$EXPECTED_SINCE" "$(jq -r '.fragments_since' "$LOG_ROOT/last-run.json")"
  assert_file_not_exists "異常時のみ通知＝正常時は通知されない" "$OSASCRIPT_LOG"
  FRAG_FILE="$(find "$VAULT/Fragments" -name '20*.md' | head -1)"
  assert_file_exists "Fragments当日ファイルが作成される" "$FRAG_FILE"
  assert_contains "サマリ行が追記される" "$(cat "$FRAG_FILE")" "定常メンテ(週次)"
  commits="$(git -C "$VAULT" log --oneline | wc -l | tr -d ' ')"
  # 初期commit(1) + Phase3最終commit(Fragmentsサマリ追記分・1) = 2。
  # Phase0のスナップショットはVaultが初期commitから未変更のため
  # no-changeでcommitされない（差分が無ければ何もしないという設計どおり）。
  assert_eq "初期commit＋Phase3最終commitの2回のみ（Phase0時点では無変更のためno-change）" "2" "$commits"
}

echo "=== 2. Phase0: backup-vault.shがerrorならPhase1以降へ進まず異常終了する ==="
{
  T="$WORK_ROOT/t2"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 現在のブランチをVAULT_BACKUP_BRANCH(既定main)と不一致にしてbackup-vault.shをFAILさせる。
  git -C "$VAULT" checkout -q -b other-branch
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 1" "1" "$rc"
  RUN_DIR="$(latest_run_dir)"
  assert_file_not_exists "check-drift.shは呼び出されない（Phase0で中断）" "$RUN_DIR/drift-stdout.log"
  assert_file_exists "異常通知される" "$OSASCRIPT_LOG"
  assert_file_not_exists "last-run.jsonにlast_success_atは記録されない（started_atのみ）" "$LOG_ROOT/last-run.json.nonexistent-marker"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json" 2>/dev/null || echo '{}')"
  assert_contains "started_atは記録される（自己ロックアウト対策）" "$LAST_RUN" "started_at"
  assert_not_contains "last_success_atは記録されない" "$LAST_RUN" "last_success_at\":"
  assert_contains "last_result=failが記録される（Phase0の直前スナップショット失敗・旧D4・2026-08-10）" "$LAST_RUN" "\"last_result\": \"fail\""
  assert_contains "last_result_summaryに直前スナップショット異常の要旨が入る" "$LAST_RUN" "直前スナップショット"
}

echo "=== 3. Phase0: export再試行 - ai-env repoがdirtyならbusyスキップしPhase1へ進む ==="
{
  T="$WORK_ROOT/t3"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  echo "dirty" > "$AIENV_REPO/dirty-file.txt"
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0（dirtyでもPhase1以降は続行）" "0" "$rc"
  assert_file_not_exists "export-public-vault.shは呼ばれない" "$EXPORT_CALL_LOG"
  assert_contains "export再試行スキップのログが出る" "$(cat "$LAST_STDOUT")" "dirtyのためスキップ"
}

echo "=== 4. Phase0: export再試行が失敗してもPhase1以降は続行し異常だけ記録する ==="
{
  T="$WORK_ROOT/t4"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_EXPORT_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0（export失敗はPhase1以降を止めない）" "0" "$rc"
  assert_file_exists "export-public-vault.shは実際に呼ばれる" "$EXPORT_CALL_LOG"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "通知内容にexport失敗が含まれる" "$(cat "$OSASCRIPT_LOG")" "export"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  # 隔離して継続する異常（export再試行失敗を含む）が1件でもあればlast_success_atは
  # 進めない（fragments_log.pyの--sinceが次回も正しく巻き戻れるようにする
  # 保守的な方針＝「完全正常終了時のみ」を文字どおり満たす）。
  assert_not_contains "last_success_atは更新されない（export失敗もRUN_FULLY_OKを崩す）" "$LAST_RUN" "last_success_at\":"
}

echo "=== 5. Phase1①: check-drift.shが実drift検出(rc=1)でも警告として記録し完走する（fail-fast廃止・2026-08-10・[[Decisions/2026-08-10-round6-rulings]]決定1） ==="
{
  T="$WORK_ROOT/t5"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_EXIT=1 FAKE_DRIFT_JSON='{"total_drift": 3, "item4_drift": 0, "drift_excluding_item4": 3}' \
    run_maintenance || rc=$?
  assert_eq "exit 0（fail-fastしない）" "0" "$rc"
  assert_file_exists "②③は起動される（Phase1の残りまで完走）" "$(latest_run_dir)/step-status-inventory.json"
  assert_file_exists "異常通知される（警告として記録）" "$OSASCRIPT_LOG"
  assert_contains "通知内容にcheck-driftが含まれる" "$(cat "$OSASCRIPT_LOG")" "check-drift"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "last_success_atは更新されない（警告も1件の異常として計上）" "$LAST_RUN" "last_success_at\":"
  assert_contains "last_result=warnが記録される（完走はしたが異常あり・旧D4・2026-08-10）" "$LAST_RUN" "\"last_result\": \"warn\""
  assert_contains "last_result_summaryにcheck-driftの警告要旨が入る" "$LAST_RUN" "check-drift"
}

echo "=== 6. Phase1①: check-drift.shの実行異常(rc>=2)も警告として記録し完走する（fail-fast廃止） ==="
{
  T="$WORK_ROOT/t6"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_EXIT=2 run_maintenance || rc=$?
  assert_eq "exit 0（fail-fastしない）" "0" "$rc"
  assert_file_exists "②③は起動される" "$(latest_run_dir)/step-status-inventory.json"
  assert_file_exists "異常通知される" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_result=warnが記録される（実行異常時も同様・旧D4）" "$LAST_RUN" "\"last_result\": \"warn\""
}

echo "=== 7. Phase1①: check-drift.shのtimeoutも警告として記録し完走する（fail-fast廃止） ==="
{
  T="$WORK_ROOT/t7"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_SLEEP=5 run_maintenance || rc=$?
  assert_eq "exit 0（fail-fastしない）" "0" "$rc"
  assert_file_exists "②③は起動される" "$(latest_run_dir)/step-status-inventory.json"
  assert_contains "timeoutとして記録される" "$(cat "$LAST_STDOUT" "$LAST_STDERR" 2>/dev/null)" "timeout"
  assert_file_exists "異常通知される" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_result=warnが記録される（timeout時も同様・旧D4）" "$LAST_RUN" "\"last_result\": \"warn\""
}

echo "=== 7c. Phase1①: check-drift.sh②が未知config.tomlキーを検出（unknown_config_keys>0・drift自体は0件）してもlast_result=successのまま維持し、summaryにinformationalとして記録する（工程横断レビュー指摘Major対応・2026-08-10） ==="
{
  T="$WORK_ROOT/t7c"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  # drift_excluding_item4=0（fail-fast/警告化のトリガーにはならない）だが
  # unknown_config_keysが3件ある状態を模擬する。
  FAKE_DRIFT_JSON='{"total_drift": 0, "item4_drift": 0, "drift_excluding_item4": 0, "unknown_config_keys": 3}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_not_exists "異常通知はされない（未知キーはwarnへ昇格させない・本人裁定）" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_result=successのまま（昇格しない）" "$LAST_RUN" "\"last_result\": \"success\""
  assert_contains "last_success_atは更新される（完全正常終了のまま）" "$LAST_RUN" "last_success_at\":"
  assert_contains "last_result_summaryに未知キー3件のinformationalが記録される" "$LAST_RUN" "未知キーを3件検出"
}

echo "=== 7d. Phase1①: check-drift.sh②に未知config.tomlキーが無い(unknown_config_keys=0)場合はsummaryに何も追記されない ==="
{
  T="$WORK_ROOT/t7d"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_JSON='{"total_drift": 0, "item4_drift": 0, "drift_excluding_item4": 0, "unknown_config_keys": 0}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_result=success" "$LAST_RUN" "\"last_result\": \"success\""
  assert_contains "last_result_summaryは空文字列のまま" "$LAST_RUN" "\"last_result_summary\": \"\""
  assert_not_contains "未知キーのinformationalは出ない" "$LAST_RUN" "未知キー"
}

echo "=== 7e. Phase1①: check-drift.sh②のJSONにunknown_config_keysキー自体が無い（旧バージョン混在等）場合もクラッシュせずfail-openで無視する ==="
{
  T="$WORK_ROOT/t7e"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_JSON='{"total_drift": 0, "item4_drift": 0, "drift_excluding_item4": 0}' \
    run_maintenance || rc=$?
  assert_eq "exit 0（キー欠落でもクラッシュしない）" "0" "$rc"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_result=success" "$LAST_RUN" "\"last_result\": \"success\""
  assert_contains "last_result_summaryは空文字列のまま" "$LAST_RUN" "\"last_result_summary\": \"\""
}

echo "=== 7f. Phase1①: 別種のanomaly(Phase0 export再試行失敗)と未知config.tomlキー(informational)が同じ週次実行で同時に起きても、last_result=warnとなりsummaryに両方が残る（Codex一次レビュー2周目指摘Major対応: if/elifで分岐していたためINFO_NOTES側が丸ごと捨てられ、可視化導線がこのケースだけ再発していた。異常源はcheck-drift自身以外＝export再試行失敗を使う: check-drift由来のanomalyメッセージは生JSON全文を含み単体で200文字summaryをほぼ使い切るため、combineの構造自体を検証する狙い撃ちには不向き） ==="
{
  T="$WORK_ROOT/t7f"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  # drift自体はOK 0（check-drift由来のanomalyは起きない）だが、Phase0の
  # export再試行失敗で別のanomalyが1件立つ。同時にunknown_config_keys>0で
  # informationalも1件立つ＝異なる発生源のanomalyとinfo note共存パターン。
  FAKE_EXPORT_EXIT=1 \
    FAKE_DRIFT_JSON='{"total_drift": 0, "item4_drift": 0, "drift_excluding_item4": 0, "unknown_config_keys": 2}' \
    run_maintenance || rc=$?
  assert_eq "exit 0（fail-fastしない）" "0" "$rc"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_result=warn（anomalyがある以上success/infoへは降格しない）" "$LAST_RUN" "\"last_result\": \"warn\""
  assert_contains "summaryにexport再試行失敗の異常要旨が残る" "$LAST_RUN" "export"
  assert_contains "summaryに未知キー2件のinformationalも残る（従来はここが欠落していた）" "$LAST_RUN" "未知キーを2件検出"
}

echo "=== 8. Phase1②: fragments_log.py失敗時はlast-run.jsonのfragments_candidates/fragments_sinceを残さず（前週の値を削除）継続する ==="
{
  T="$WORK_ROOT/t8"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 前週の値が残っている状態から始める（失敗時に消えることを見る）。
  mkdir -p "$LOG_ROOT"
  echo '{"fragments_candidates": 5, "fragments_since": "2026-01-01"}' > "$LOG_ROOT/last-run.json"
  rc=0
  FAKE_FRAGMENTS_LOG_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離・③以降は実行される）" "0" "$rc"
  assert_file_exists "③は起動される" "$(latest_run_dir)/step-status-inventory.json"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "fragments_candidatesは残らない" "$LAST_RUN" "fragments_candidates"
  assert_not_contains "fragments_sinceは残らない" "$LAST_RUN" "fragments_since"
  assert_contains "サマリ行は『昇格候補 不明』" "$(find "$VAULT/Fragments" -name '20*.md' -exec cat {} \;)" "昇格候補 不明"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_not_contains "last_success_atは更新されない（隔離継続した異常もRUN_FULLY_OKを崩す）" \
    "$LAST_RUN" "last_success_at\":"
}

echo "=== 8b. Phase1②: fragments_log.pyがexit 0でもscan_error_count>0（Fragmentsファイル読取失敗）ならanomaly化しlast_success_atを進めない。件数自体は記録する ==="
{
  T="$WORK_ROOT/t8b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='{"since": "2026-07-01", "until": "2026-07-16", "since_fallback_reason": null, "scanned_files": 1, "scan_error_count": 2, "fragments": [{"title": "a"}], "truncated": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離）" "0" "$rc"
  assert_eq "scan_error_count>0でもfragments_candidatesは書かれる（候補は渡しつつ再走査させる設計）" \
    "1" "$(jq -r '.fragments_candidates' "$LOG_ROOT/last-run.json")"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "通知内容にscan_error_countの件数が含まれる" "$(cat "$OSASCRIPT_LOG")" "読み取れなかったFragmentsファイルが2件"
  assert_not_contains "last_success_atは更新されない（翌週同じ窓を再走査させるため）" \
    "$(cat "$LOG_ROOT/last-run.json")" "last_success_at\":"
}

echo "=== 8c. Phase1②: fragments_log.pyがscan_error_count=0（正常）なら従来どおりanomaly化しない ==="
{
  T="$WORK_ROOT/t8c"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='{"since": "2026-07-01", "until": "2026-07-16", "since_fallback_reason": null, "scanned_files": 1, "scan_error_count": 0, "fragments": [], "truncated": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_not_exists "異常が無いため通知は送られない" "$OSASCRIPT_LOG"
  assert_contains "last_success_atは更新される（完全正常終了）" \
    "$(cat "$LOG_ROOT/last-run.json")" "last_success_at\":"
}

echo "=== 8d. Phase1②: fragments_log.pyがexit 0でも出力が壊れたJSON（契約違反）ならscan_error_countを確定できないためanomaly化し、fragments_candidates/fragments_sinceも書かない（0件へfail-openで丸めない） ==="
{
  T="$WORK_ROOT/t8d"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='not valid json{{{' run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離・③以降は実行される）" "0" "$rc"
  assert_file_exists "③は起動される" "$(latest_run_dir)/step-status-inventory.json"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "scan_error_countを確定できないためfragments_candidatesは書かれない" "$LAST_RUN" "fragments_candidates"
  assert_not_contains "fragments_sinceも書かれない" "$LAST_RUN" "fragments_since"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "通知内容に契約違反/JSON破損の疑いが含まれる" "$(cat "$OSASCRIPT_LOG")" "scan_error_countを取得できませんでした"
  assert_not_contains "last_success_atは更新されない" "$LAST_RUN" "last_success_at\":"
}

echo "=== 8e. Phase1②: fragments_log.pyのJSONにscan_error_countキー自体が無い（契約違反）場合も0件と誤認せずanomaly化する ==="
{
  T="$WORK_ROOT/t8e"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='{"since": "2026-07-01", "until": "2026-07-16", "scanned_files": 1, "fragments": [], "truncated": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "キー欠落のためfragments_candidatesは書かれない" "$LAST_RUN" "fragments_candidates"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_not_contains "last_success_atは更新されない" "$LAST_RUN" "last_success_at\":"
}

echo "=== 8f. Phase1②: scan_error_countが非負整数でない（bool/文字列/負数）契約違反も0件と誤認せずanomaly化する ==="
{
  for badval in 'true' '"2"' '-1'; do
    T="$WORK_ROOT/t8f-$(echo "$badval" | tr -c 'a-zA-Z0-9' '-')"; mkdir -p "$T"
    setup_test_env "$T"
    LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
    rc=0
    FAKE_FRAGMENTS_LOG_JSON="{\"scan_error_count\": $badval, \"fragments\": [], \"truncated\": []}" \
      run_maintenance || rc=$?
    assert_eq "exit 0（値=${badval}）" "0" "$rc"
    LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
    assert_not_contains "値=${badval}は非負整数でないためfragments_candidatesは書かれない" \
      "$LAST_RUN" "fragments_candidates"
    assert_not_contains "値=${badval}ではlast_success_atは更新されない" \
      "$LAST_RUN" "last_success_at\":"
  done
}

echo "=== 9. Phase1③: vault_inventory.py失敗時もanomaly化しつつ処理は継続する ==="
{
  T="$WORK_ROOT/t9"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_VAULT_INVENTORY_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "Phase3のサマリ行まで到達する（③失敗でも継続）" "$(cat "$LAST_STDOUT")" "Fragmentsサマリ追記"
  assert_not_contains "last_success_atは更新されない" "$(cat "$LOG_ROOT/last-run.json")" "last_success_at\":"
}

echo "=== 15. Phase3: サマリ行に昇格候補の件数と窓（--sinceの日付）が反映される ==="
{
  T="$WORK_ROOT/t15"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='{"scan_error_count": 0, "fragments": [{"title": "a"}, {"title": "b"}, {"title": "c"}], "truncated": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  FRAG_TEXT="$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")"
  assert_contains "昇格候補3件" "$FRAG_TEXT" "昇格候補3件"
  assert_contains "前回成功以降の窓が出る" "$FRAG_TEXT" "前回成功 $(date -u -v-7d +%Y-%m-%d) 以降"
  assert_not_contains "マージ・見送り・提案の表記はもう出ない(Phase2退役)" "$FRAG_TEXT" "マージ"
  assert_not_contains "Preferences未確認提案の表記はもう出ない(Phase2退役)" "$FRAG_TEXT" "Preferences未確認提案"
}

echo "=== 16. latest symlinkが原子的に張り替わり、実行ごとに異なるRUN_DIRを指す ==="
{
  T="$WORK_ROOT/t16"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  run_maintenance
  FIRST_RUN_DIR="$(latest_run_dir)"
  sleep 1.1
  run_maintenance
  SECOND_RUN_DIR="$(latest_run_dir)"
  if [[ "$FIRST_RUN_DIR" != "$SECOND_RUN_DIR" ]]; then
    pass "2回の実行で異なるRUN_DIRが作られる"
  else
    fail_case "2回の実行で同じRUN_DIRになってしまった（一意性の欠陥）: $FIRST_RUN_DIR"
  fi
  assert_file_exists "1回目のRUN_DIRも削除されず残っている（保持期間内）" "$FIRST_RUN_DIR/fragments.json"
  [[ -L "$LOG_ROOT/latest" ]] && pass "latestはsymlinkのまま" || fail_case "latestがsymlinkではなくなっている"
}

echo "=== 17. 30日超過の実行日付ディレクトリは次回実行時に自動削除される ==="
{
  T="$WORK_ROOT/t17"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT/2020-01-01/000000-1"
  echo x > "$LOG_ROOT/2020-01-01/000000-1/dummy.txt"
  touch -t 202001010000 "$LOG_ROOT/2020-01-01"
  run_maintenance
  assert_file_not_exists "30日超過ディレクトリは削除される" "$LOG_ROOT/2020-01-01"
}

echo "=== 18. --sinceの算出: 初回実行(last-run.json無し)は7日前を使う ==="
{
  T="$WORK_ROOT/t18"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  run_maintenance
  EXPECTED_SINCE="$(date -u -v-7d +%Y-%m-%d)"
  assert_contains "stdout内の--sinceに7日前の日付が使われる" "$(cat "$LAST_STDOUT")" "$EXPECTED_SINCE"
}

echo "=== 19. --sinceの算出: 2回目実行は前回のlast_success_atの日付を使う ==="
{
  T="$WORK_ROOT/t19"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  # 2026-07-16 Codex三次レビュー指摘Minor対応: 固定値の日付はテスト実行日
  # から30日超過して意図せず7日前フォールバックへ丸め込まれる偽陽性リスクが
  # あった（アサーションがstdout全体の部分一致のみで、実際にフォールバック
  # していても「前回成功時刻」欄の生値表示に一致して見逃していた）。
  # 常に「1日前」を動的生成し、test28と同じ「--sinceに使う日付: <値>」欄の
  # 厳密一致で確認する。
  YESTERDAY="$(date -u -v-1d +%Y-%m-%d)"
  echo "{\"started_at\": \"2026-06-01T00:00:00Z\", \"last_success_at\": \"${YESTERDAY}T03:00:00Z\"}" > "$LOG_ROOT/last-run.json"
  run_maintenance
  assert_contains "stdout内の--sinceに前回last_success_atの日付が使われる" \
    "$(cat "$LAST_STDOUT")" "--since に使う日付: $YESTERDAY"
}

echo "=== 19b. --sinceの算出: 前回last_success_atが未来日時なら7日前へフォールバックする ==="
{
  T="$WORK_ROOT/t19b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  TOMORROW="$(date -u -v+1d +%Y-%m-%d)"
  echo "{\"last_success_at\": \"${TOMORROW}T00:00:00Z\"}" > "$LOG_ROOT/last-run.json"
  run_maintenance
  EXPECTED_SINCE="$(date -u -v-7d +%Y-%m-%d)"
  assert_contains "未来日時は7日前へフォールバックする" \
    "$(cat "$LAST_STDOUT")" "--since に使う日付: $EXPECTED_SINCE"
}

echo "=== 19c. --sinceの算出: 前回last_success_atが31日前(30日超過)なら7日前へフォールバックする ==="
{
  T="$WORK_ROOT/t19c"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  OLD31="$(date -u -v-31d +%Y-%m-%d)"
  echo "{\"last_success_at\": \"${OLD31}T00:00:00Z\"}" > "$LOG_ROOT/last-run.json"
  run_maintenance
  EXPECTED_SINCE="$(date -u -v-7d +%Y-%m-%d)"
  assert_contains "31日前(30日超過)は7日前へフォールバックする" \
    "$(cat "$LAST_STDOUT")" "--since に使う日付: $EXPECTED_SINCE"
}

echo "=== 19d. --sinceの算出: 前回last_success_atがちょうど30日前は境界内としてそのまま使う ==="
{
  T="$WORK_ROOT/t19d"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  OLD30="$(date -u -v-30d +%Y-%m-%d)"
  echo "{\"last_success_at\": \"${OLD30}T00:00:00Z\"}" > "$LOG_ROOT/last-run.json"
  run_maintenance
  assert_contains "ちょうど30日前は境界内としてそのまま使われる" \
    "$(cat "$LAST_STDOUT")" "--since に使う日付: $OLD30"
}

echo "=== 20. Vault書込ロック: 生存中のロックが既にあれば今回はbusyで穏当にskipする ==="
{
  T="$WORK_ROOT/t20"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  echo "$$" > "$LOG_ROOT/vault-writer.lock"
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0（busyで穏当にskip・エラー扱いではない）" "0" "$rc"
  assert_file_not_exists "Phase1は実行されない（①未起動で確認）" "$(latest_run_dir)/step-status-drift.json"
}

echo "=== 20b. Vault書込ロック: acquire_pid_lockの回収ミューテックス競合が解消しない(fail-closed exit 1)場合もlast_result=failが記録され通知される（Codex一次レビュー2周目指摘Major対応: acquire_pid_lockはmaintenance.shのadd_anomaly/write_last_resultを経由せず直接exitするため、素通しだと前回のlast_resultが誤って残ったままヘルス行に出ていた） ==="
{
  T="$WORK_ROOT/t20b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  # tests/test-backup-vault.sh 13b と同じ再現方法: stale確定のPID(生存し得ない
  # 巨大PID)を書いたロックファイル＋回収ミューテックスディレクトリを事前に
  # 握ったままにしておくと、acquire_pid_lockは20回試行しても回収ミューテックス
  # を取得できずfail-closedでexit 1する（scripts/lib/pid-lock.sh参照）。
  echo "999999" > "$LOG_ROOT/vault-writer.lock"
  mkdir -p "$LOG_ROOT/vault-writer.lock.reclaim"
  rc=0
  run_maintenance || rc=$?
  assert_eq "回収ミューテックス競合が解消しない場合はexit 1（fail-closed）" "1" "$rc"
  assert_file_not_exists "Phase1は実行されない（①未起動で確認）" "$(latest_run_dir)/step-status-drift.json"
  assert_file_exists "異常通知される" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json" 2>/dev/null || echo '{}')"
  assert_contains "last_result=failが記録される" "$LAST_RUN" "\"last_result\": \"fail\""
}

echo "=== 21. backup-vault.shはmaintenance.sh自身の呼び出し(Phase0/Phase3)ではVault書込ロックにbypassされ通常どおりcommitする ==="
{
  T="$WORK_ROOT/t21"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  # 正常終了できている時点でPhase0のbackup-vault.sh呼び出しが自己ロックで
  # busyスキップされていないことは既にtest1のcommit数アサーションで
  # 間接検証済みだが、ここでは明示的にstatus-fileの中身も確認する。
  RUN_DIR="$(latest_run_dir)"
  # grep -cは「マッチ0件」でもexit 1で"0"を出力するため、`|| echo 0`は不要
  # （二重出力になるバグを生む。本テスト作成時に実際に踏んだ）。
  assert_eq "Phase0のbackup-vault.sh status-fileがcompleted/no-change（busyではない）" "0" \
    "$(grep -c '^busy$' "$RUN_DIR/backup0-status.txt" 2>/dev/null)"
}

echo "=== 23. Phase0: backup-vault.sh自身のCLI多重起動防止ロックがbusyなら、通知なしで穏当にskipする（設計書§1.2） ==="
{
  T="$WORK_ROOT/t23"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # backup-vault.sh自身のCLIロック（既定 $TMPDIR/aienv-backup-vault.lock）を
  # 生存中の別プロセス（このテストプロセス自身）が保持している状態を模擬する。
  echo "$$" > "$TEST_TMPDIR/aienv-backup-vault.lock"
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0（busyで穏当にskip）" "0" "$rc"
  assert_file_not_exists "busyは異常通知の対象ではない" "$OSASCRIPT_LOG"
  assert_file_not_exists "Phase1以降は実行されない" "$(latest_run_dir)/step-status-drift.json"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "started_atは記録される（自己ロックアウト対策）" "$LAST_RUN" "started_at"
  assert_not_contains "last_success_atは記録されない" "$LAST_RUN" "last_success_at\":"
}

echo "=== 26. 実行ディレクトリの衝突検知: DATE_DIR配下にRUN_DIRを作成できない場合はfail-closedで中断する ==="
{
  T="$WORK_ROOT/t26"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 当日のDATE_DIRを先に作成し、DATE_DIR自体を読み取り専用化する（RUN_DIRの
  # 衝突そのものはPIDが予測できず再現困難なため、「RUN_DIR作成に失敗した
  # ときfail-closedで中断する」という同じコードパスを、より確実に再現できる
  # 代替シナリオ＝親ディレクトリへの書込み不可で検証する）。
  DATE_COMPONENT="$(date +%Y-%m-%d)"
  mkdir -p "$LOG_ROOT/$DATE_COMPONENT"
  chmod 0500 "$LOG_ROOT/$DATE_COMPONENT"
  rc=0
  run_maintenance || rc=$?
  chmod 0700 "$LOG_ROOT/$DATE_COMPONENT" 2>/dev/null || true
  assert_eq "RUN_DIR作成に失敗したらexit 1（fail-closed・クラッシュしない）" "1" "$rc"
  # LAST_RUN_FILE(last-run.json)自体はDATE_DIR配下ではなくLOG_ROOT直下のため
  # 書込み可能なまま＝last_result="fail"がこの早期exitでも記録される
  # （Codex一次レビュー指摘Major対応: 従来は直前スナップショット失敗の2箇所
  # にしかlast_result書込みが無かった）。
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json" 2>/dev/null || echo '{}')"
  assert_contains "RUN_DIR作成失敗でもlast_result=failが記録される" "$LAST_RUN" "\"last_result\": \"fail\""
}

echo "=== 26b. DATE_DIR自体の作成に失敗した場合もfail-closedで中断しlast_result=failが記録される（test26はRUN_DIR作成失敗、本テストはその1段階前のDATE_DIR作成失敗を狙い撃ちで再現・Codex一次レビュー2周目指摘Minor対応） ==="
{
  T="$WORK_ROOT/t26b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # DATE_DIR（$LOG_ROOT/<当日日付>）のパスへ、ディレクトリではなく通常
  # ファイルを事前に置くことで、`mkdir -p "$DATE_DIR"`自体を
  # 「既にファイルが存在する」で確実に失敗させる（test26のchmod 0500方式は
  # RUN_DIR作成側=1段階後の失敗を再現するのに対し、本テストはDATE_DIR
  # 作成自体の失敗という異なるコードパスを狙う）。
  DATE_COMPONENT="$(date +%Y-%m-%d)"
  mkdir -p "$LOG_ROOT"
  : > "$LOG_ROOT/$DATE_COMPONENT"
  rc=0
  run_maintenance || rc=$?
  assert_eq "DATE_DIR作成に失敗したらexit 1（fail-closed・クラッシュしない）" "1" "$rc"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json" 2>/dev/null || echo '{}')"
  assert_contains "DATE_DIR作成失敗でもlast_result=failが記録される" "$LAST_RUN" "\"last_result\": \"fail\""
}

echo "=== 28. --sinceの算出: 末尾に無関係な文字列が付いた壊れた値は7日前へフォールバックする ==="
{
  T="$WORK_ROOT/t28"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  mkdir -p "$LOG_ROOT"
  echo '{"started_at": "2026-06-01T00:00:00Z", "last_success_at": "2026-06-15broken"}' > "$LOG_ROOT/last-run.json"
  run_maintenance
  EXPECTED_SINCE="$(date -u -v-7d +%Y-%m-%d)"
  assert_contains "壊れた値は7日前へフォールバックする" "$(cat "$LAST_STDOUT")" "$EXPECTED_SINCE"
  # ログ行自体には診断用に生の前回値（壊れた文字列）がそのまま出るのは正しい
  # 挙動なので、「--sinceに使う日付」欄だけが壊れた値になっていないことを
  # 確認する（生ログ全体からの単純な文字列不在チェックは診断ログと
  # 衝突するため使わない）。
  assert_not_contains "--sinceに使う日付欄には壊れた値が使われない" "$(cat "$LAST_STDOUT")" "--since に使う日付: 2026-06-15"
}

echo "=== 29. last-run.jsonのstarted_at書込みに失敗したらfail-fastで中断する ==="
{
  T="$WORK_ROOT/t29"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # LAST_RUN_FILEだけをRUN_DIR/DATE_DIR作成とは独立した書込み不可能な場所へ
  # 向けることで、「実行ディレクトリ作成は成功するがstarted_at書込みだけが
  # 失敗する」状況を狙い撃ちで再現する（LOG_ROOT自体を読み取り専用化すると
  # RUN_DIR作成自体も道連れで失敗し、test26と区別できなくなるため）。
  UNWRITABLE_DIR="$T/unwritable"
  mkdir -p "$UNWRITABLE_DIR"
  chmod 0500 "$UNWRITABLE_DIR"
  rc=0
  LAST_RUN_FILE="$UNWRITABLE_DIR/last-run.json" run_maintenance || rc=$?
  chmod 0700 "$UNWRITABLE_DIR" 2>/dev/null || true
  assert_eq "started_at書込み失敗はexit 1（fail-fast）" "1" "$rc"
  assert_file_not_exists "Phase0以降は実行されない" "$(latest_run_dir)/backup0-stdout.log"
  # last_resultも同じ書込み不可能なLAST_RUN_FILEへの書込みのため失敗するが、
  # write_last_result()自体はfail-openでwarn()するだけ＝二重にexit 1したり
  # クラッシュしたりしない（Codex一次レビュー指摘Major対応の追加テスト）。
  assert_contains "last_result書込み失敗はwarn()で記録されクラッシュしない" \
    "$(cat "$LAST_STDERR")" "last_result"
}

echo "=== 30. LAST_RUN_FILEのパスにシングルクォートが含まれても壊れず正常終了する（2026-07-16 リーダー裁定・check-drift.shで検出された同型injection経路のmaintenance.sh側横展開修正の回帰テスト） ==="
{
  T="$WORK_ROOT/t30"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # read_last_run_field/write_last_run_field が、python3コード文字列へ
  # ファイルパスを直接埋め込んでいた旧実装では、パスに ' が含まれるだけで
  # 構文が壊れていた（Codexレビュー指摘Major。scripts/check-drift.shの
  # check_maintenance_freshness()で先に検出・修正した同型欠陥をmaintenance.sh
  # 側へ横展開）。LAST_RUN_FILEをシングルクォートを含むパスへ向けて、
  # read/write_last_run_field()の修正を狙い撃ちで検証する
  # （parse_step_status/fragments.json側はテスト30bで
  # 別途検証する＝Codexレビュー指摘Minor対応。1テストで全経路を混在させると
  # どの関数の回帰かテスト失敗時に切り分けにくくなるため意図的に分離した）。
  QUOTE_DIR="$T/it's-a-quote-dir"
  mkdir -p "$QUOTE_DIR"
  QUOTE_LAST_RUN_FILE="$QUOTE_DIR/last-run.json"
  rc=0
  LAST_RUN_FILE="$QUOTE_LAST_RUN_FILE" run_maintenance || rc=$?
  assert_eq "シングルクォートを含むLAST_RUN_FILEでも正常終了する(exit 0)" "0" "$rc"
  assert_file_exists "last-run.jsonがシングルクォートを含むパスに生成される" "$QUOTE_LAST_RUN_FILE"
  LAST_RUN="$(cat "$QUOTE_LAST_RUN_FILE" 2>/dev/null || echo "")"
  assert_contains "started_atが正しく記録される(python3構文破壊なし)" "$LAST_RUN" "started_at"
  assert_contains "last_success_atが正しく記録される(完全正常終了)" "$LAST_RUN" "last_success_at\":"
}

echo "=== 30b. MAINTENANCE_LOG_ROOTのパスにシングルクォートが含まれても壊れず正常終了する（parse_step_status/fragments.json解析の回帰テスト） ==="
{
  T="$WORK_ROOT/t30b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # LOG_ROOT自体をシングルクォートを含むパスへ差し替える。RUN_DIR（status-file
  # 群・fragments.jsonの置き場所）はLOG_ROOT配下のため、parse_step_status()・
  # Phase1②の候補件数解析を狙い撃ちで検証できる。run_maintenance()
  # 自身が内部で`MAINTENANCE_LOG_ROOT="$LOG_ROOT"`という固定代入を行うため、
  # 外側から`MAINTENANCE_LOG_ROOT=...`を環境変数prefixで渡しても関数内側の
  # 代入に上書きされてしまう（このテストファイル冒頭の教訓と同型）。グローバル
  # 変数LOG_ROOT自体を書き換えるのが正しい。
  QUOTE_LOG_ROOT="$T/it's-a-quote-dir/logs/maintenance"
  mkdir -p "$(dirname "$QUOTE_LOG_ROOT")"
  LOG_ROOT="$QUOTE_LOG_ROOT"
  rc=0
  run_maintenance || rc=$?
  assert_eq "シングルクォートを含むMAINTENANCE_LOG_ROOTでも正常終了する(exit 0)" "0" "$rc"
  QUOTE_LAST_RUN="$(cat "$QUOTE_LOG_ROOT/last-run.json" 2>/dev/null || echo "")"
  assert_contains "last_success_atが正しく記録される(fragments.json解析が構文破壊せず完走)" \
    "$QUOTE_LAST_RUN" "last_success_at\":"
  assert_contains "fragments_candidatesが記録される" "$QUOTE_LAST_RUN" "fragments_candidates"
}

echo "=== 31. 統合テスト: 実物のfragments_log.py/vault_inventory.py/vault_lib.pyを使った「候補0件の静かな週」でanomaly=false・通知なし・last_success_atが前進し・fragments_candidates=0 ==="
{
  # 本ファイルの他の全テストはsetup_fake_repo()が検出器をFAKEスタブへ差し替える
  # ため、ここだけ実物のPython実装（fragments_log.py・vault_inventory.py・
  # 依存モジュールvault_lib.py）へ差し替え、空の（何も検出しない）Vaultに対して
  # 実行することで、Phase1②の実際のJSON契約（fragments配列）と③の実行器の
  # 結合（偽HOMEのlatest.json）が壊れていないことを直接検証する。
  T="$WORK_ROOT/t31"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"

  for real_py in fragments_log vault_inventory vault_lib; do
    cp "$REPO_ROOT/scripts/vault-agents/${real_py}.py" "$REPO/scripts/vault-agents/${real_py}.py"
    chmod +x "$REPO/scripts/vault-agents/${real_py}.py"
  done
  [ -f "$REPO_ROOT/scripts/vault-agents/generic-aliases.txt" ] \
    && cp "$REPO_ROOT/scripts/vault-agents/generic-aliases.txt" "$REPO/scripts/vault-agents/generic-aliases.txt"

  # 実物のfragments_log.py/vault_inventory.pyはVaultパスを$HOME/Data/obsidian
  # に固定しており（--vaultフラグを受け付けない）、$VAULT（本テストファイルの
  # 慣例＝$T/vault）を素直には見てくれない。$HOME/Data/obsidianを$VAULTへの
  # symlinkにすることで、両者を同じ実体へ一致させる（本テストは全テスト中で
  # 最後に配置しているため、本テストの$HOME/Data作成が他テストへ波及する心配は
  # 無い＝$HOMEはファイル冒頭でファイル全体で1つだけexportされ使い回される）。
  mkdir -p "$HOME/Data"
  ln -s "$VAULT" "$HOME/Data/obsidian"

  # 実物のvault_inventory.pyはBOOTSTRAP_FILES（必読ファイル）を無条件で
  # read_text()するため、欠けるとFileNotFoundErrorになる。実行前提を満たす。
  mkdir -p "$VAULT/Preferences" "$VAULT/Personal"
  for bf in "Knowledge/mistakes.md" "Preferences/absolute-rules.md" "Preferences/profile.md" \
            "Personal/profile-personal.md" "Preferences/coding-delegation.md" "Preferences/vault-operation.md"; do
    echo "# ${bf}" > "$VAULT/${bf}"
  done
  git -C "$VAULT" add -A && git -C "$VAULT" commit -q -m "add bootstrap files" >/dev/null

  rc=0
  run_maintenance || rc=$?
  assert_eq "候補0件でもexit 0" "0" "$rc"

  RUN_DIR="$(latest_run_dir)"
  assert_file_exists "実物のfragments_log.pyがfragments.jsonを生成する" "$RUN_DIR/fragments.json"
  assert_file_not_exists "Phase2の中間ファイルは作られない" "$RUN_DIR/apply-status.json"
  assert_file_not_exists "anomaly無しのため通知は送られない" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_success_atが前進する(完全正常終了)" "$LAST_RUN" "last_success_at\":"
  assert_eq "fragments_candidates=0が記録される" "0" "$(jq -r '.fragments_candidates' "$LOG_ROOT/last-run.json")"
}

# =============================================================================
# Phase3宣言記録の掃除（cmux-session-todo・FR-47・設計書§16・v1.6でprune rc
# 3値→4値・サマリ写像固定・DT-7に追随。AC-57／AC-58）
# =============================================================================
# 前半（本節〜39. Phase3宣言掃除の入口パス上書き）は実物のcmux-task-declare.sh
# には依存しない契約スタブ試験。§16.6.2の「契約スタブ」（setup_fake_prune_cmd()。
# 本ファイル冒頭）で§3.3の終了コード契約（rc=0で<UUID><TAB><slug>を0行以上・
# rc=1/2/3は空）を演じ、maintenance.sh側の統合＝1回だけ呼ぶ・エラーを隔離する・
# サマリのセグメントを§16.3の固定文字列へ正しく写像する・last_success_atを
# 進める、を検査する。
# 続くcase 40・41（§16.6.2系統①）は実物のcmux-task-declare.sh（REPO_ROOT配下の
# cmux/）との実物結合試験で、記録が本当に
# 2件→1件へ減る／1バイトも変わらないところまで見る（実物が無い環境では
# SKIP。実cmux・実記録には触れない・verifier実装レビュー2巡目#12対応）。

# DT-7共通ボディ（§16.6.3）。呼び出し側が事前にsetup_test_env()と、必要な
# FAKE_PRUNE_*/MAINTENANCE_TASK_PRUNE_CMD/TIMEOUT_TASK_PRUNEの上書きを済ませた
# 状態で呼ぶ。6状態すべてで共通に確かめる5項目（設計書§16.6.3）を検査する。
# $1=T（テスト用一時ディレクトリ） $2=期待するサマリのセグメント文字列
#   （§16.3の写像表そのもの。部分一致だが区切り記号（・（）を含む完全な
#   セグメント単位で照合するため実質的に完全一致相当）
# $3=掃除の入口が呼ばれた回数の期待値（未導入=0・それ以外=1）
# $4=last_result_summaryにadd_info_noteの本文が残ることを期待するか(1/0)
#   （c＝実施のみ0。add_info_noteはrc=0のOK系では呼ばれないため）
run_dt7_case() {
  local T="$1" expect_segment="$2" expect_calls="$3" expect_info_note="$4"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 「宣言記録」に相当するfixture。契約スタブ自身はこのファイルを一切
  # 参照・変更しない（maintenance.sh側の実装がこのパスへ直接触れていない
  # ことを回帰的に確かめるための独立した観測点）。W-8相当＝2件のうち1件は
  # workspace listに無いUUID、という体裁だけ真似ておく。
  local record_fixture="$T/fake-declare-record.json"
  printf '{"version":1,"workspaces":{"FB3B2F30-00D7-4093-91CE-0DE32B43165C":"slug-a","11111111-1111-1111-1111-111111111111":"slug-b"}}' \
    > "$record_fixture"
  cp "$record_fixture" "$record_fixture.before"
  local rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0（週次メンテは中断せず最後の工程まで到達する）" "0" "$rc"
  assert_contains "Phase3の保持整理ログまで到達する(最終工程到達の証跡)" "$(cat "$LAST_STDOUT")" "done."
  assert_files_identical "宣言記録は実行の前後でバイト単位で一致する(maintenance.sh自身は記録に一切触れない)" \
    "$record_fixture" "$record_fixture.before"
  local frag_text
  frag_text="$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")"
  assert_contains "実施サマリのセグメントが§16.3の写像表の固定文字列と一致する" "$frag_text" "$expect_segment"
  local last_run
  last_run="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_success_atが進む(掃除の失敗をadd_anomalyにしていない証拠・設計書§16.4)" \
    "$last_run" "last_success_at\":"
  if [[ "$expect_info_note" == "1" ]]; then
    assert_contains "last_result_summaryにadd_info_noteの本文が残る(起動ヘルス行への可視化)" \
      "$last_run" "宣言記録の掃除は未実施です"
  else
    assert_not_contains "add_info_noteは呼ばれないためlast_result_summaryに未実施の注記は残らない" \
      "$last_run" "宣言記録の掃除は未実施です"
  fi
  local call_count
  call_count="$(grep -c . "$PRUNE_CALL_LOG" 2>/dev/null || echo 0)"
  assert_eq "掃除の入口の呼び出し回数(AC-57①)" "$expect_calls" "$call_count"
}

echo "=== 32. DT-7状態a: 掃除の入口が存在しない（未導入・F-23） ==="
{
  T="$WORK_ROOT/t32a"; mkdir -p "$T"
  setup_test_env "$T"
  MAINTENANCE_TASK_PRUNE_CMD="$T/no-such-cmux-task-declare.sh" \
    run_dt7_case "$T" "・宣言掃除 未導入" "0" "1"
}

echo "=== 33. DT-7状態b: workspace list取得に失敗する(rc=1・接続不可・F-22・AC-58) ==="
{
  T="$WORK_ROOT/t33b"; mkdir -p "$T"
  setup_test_env "$T"
  FAKE_PRUNE_MODE=rc1 run_dt7_case "$T" "・宣言掃除 未実施（接続不可）" "1" "1"
}

echo "=== 34. DT-7状態c: rc=0で消した対が1件（実施・AC-57①②③） ==="
{
  T="$WORK_ROOT/t34c"; mkdir -p "$T"
  setup_test_env "$T"
  FAKE_PRUNE_MODE=ok0 FAKE_PRUNE_STDOUT=$'FB3B2F30-00D7-4093-91CE-0DE32B43165C\tslug-a\n' \
    run_dt7_case "$T" "・宣言掃除 実施・1件（FB3B2F30-00D7-4093-91CE-0DE32B43165C=slug-a）" "1" "0"
}

echo "=== 35. DT-7状態d: 宣言記録が破損している(rc=2) ==="
{
  T="$WORK_ROOT/t35d"; mkdir -p "$T"
  setup_test_env "$T"
  FAKE_PRUNE_MODE=rc2 run_dt7_case "$T" "・宣言掃除 未実施（宣言記録破損）" "1" "1"
}

echo "=== 36. DT-7状態e: 内部エラー(rc=3・取得後の書込等に失敗) ==="
{
  T="$WORK_ROOT/t36e"; mkdir -p "$T"
  setup_test_env "$T"
  FAKE_PRUNE_MODE=rc3 run_dt7_case "$T" "・宣言掃除 未実施（内部エラー）" "1" "1"
}

echo "=== 37. DT-7状態f: cmuxのハング等でtimeoutし打ち切られる(F-24。rc=3と同じ『内部エラー』へ写像) ==="
{
  T="$WORK_ROOT/t37f"; mkdir -p "$T"
  setup_test_env "$T"
  TIMEOUT_TASK_PRUNE=1 FAKE_PRUNE_SLEEP=5 run_dt7_case "$T" "・宣言掃除 未実施（内部エラー）" "1" "1"
}

echo "=== 38. Phase3宣言掃除: rc=0で消した対が0件なら『実施・0件』と現れる(§16.3写像表・DT-7外の追加網羅) ==="
{
  T="$WORK_ROOT/t38"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_PRUNE_MODE=ok0 FAKE_PRUNE_STDOUT="" run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  FRAG_TEXT="$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")"
  assert_contains "サマリ行に『宣言掃除 実施・0件』が現れる" "$FRAG_TEXT" "・宣言掃除 実施・0件"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_success_atは進む" "$LAST_RUN" "last_success_at\":"
}

echo "=== 39. Phase3宣言掃除: 入口のパスはMAINTENANCE_TASK_PRUNE_CMDで上書きできる（既存のパス上書きの流儀・設計書§16.2） ==="
{
  T="$WORK_ROOT/t39"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # setup_test_env()の既定PRUNE_STUBとは別のパスへ契約スタブを新規に用意し、
  # 既定パスではなくこちらが呼ばれることを確認する。
  ALT_STUB="$T/alt-declare.sh"
  setup_fake_prune_cmd "$ALT_STUB"
  rc=0
  MAINTENANCE_TASK_PRUNE_CMD="$ALT_STUB" FAKE_PRUNE_MODE=ok0 \
    FAKE_PRUNE_STDOUT=$'UUID-ALT\tslug-alt\n' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  FRAG_TEXT="$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")"
  assert_contains "上書きしたパスの応答が反映される" "$FRAG_TEXT" "・宣言掃除 実施・1件（UUID-ALT=slug-alt）"
}

echo "=== 39b. FR-78/AC-104: MAINTENANCE_TASK_PRUNE_CMDを上書きしないとき、既定は ai-env の cmux/cmux-task-declare.sh を指す（cmux-session-todo v3・供給側の移設） ==="
{
  T="$WORK_ROOT/t39b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 既定パスの解決先（新）は $HOME/work/takumi009-ai-env/cmux/cmux-task-declare.sh。
  # 本ファイルの $HOME は隔離済み（冒頭 mktemp -d）なので、そこへ直接スタブを
  # 置き、MAINTENANCE_TASK_PRUNE_CMD を一切渡さずに maintenance.sh を実行する
  # （run_maintenance() は `:=$PRUNE_STUB` で常に上書きしてしまうため、ここだけ
  # 直接 bash 呼び出しにする）。
  DEFAULT_PRUNE_DIR="$HOME/work/takumi009-ai-env/cmux"
  mkdir -p "$DEFAULT_PRUNE_DIR"
  DEFAULT_PRUNE_STUB="$DEFAULT_PRUNE_DIR/cmux-task-declare.sh"
  PRUNE_CALL_LOG="$T/prune-call-39b.log"
  setup_fake_prune_cmd "$DEFAULT_PRUNE_STUB"
  rc=0
  VAULT="$VAULT" AIENV_REPO="$AIENV_REPO" MAINTENANCE_LOG_ROOT="$LOG_ROOT" TMPDIR="$TEST_TMPDIR" \
    FAKE_OSASCRIPT_LOG="$OSASCRIPT_LOG" FAKE_EXPORT_CALL_LOG="$EXPORT_CALL_LOG" \
    FAKE_PRUNE_CALL_LOG="$PRUNE_CALL_LOG" \
    TIMEOUT_BACKUP_VAULT=10 TIMEOUT_EXPORT_PUBLIC_VAULT=10 TIMEOUT_CHECK_DRIFT=2 \
    TIMEOUT_FRAGMENTS_LOG=10 TIMEOUT_VAULT_INVENTORY=10 TIMEOUT_TASK_PRUNE=5 \
    MAINTENANCE_STALE_LOCK_SECONDS=3600 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    bash "$REPO/scripts/maintenance.sh" > "$LAST_STDOUT" 2> "$LAST_STDERR" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "既定パスのスタブ（ai-env/cmux/cmux-task-declare.sh）が呼ばれた" \
    "1" "$([ -s "$PRUNE_CALL_LOG" ] && echo 1 || echo 0)"
  rm -rf "$DEFAULT_PRUNE_DIR"
}

echo "=== 39c. AC-104: MAINTENANCE_TASK_PRUNE_CMDを上書きしない既定経路で、実物cmux-task-declare.shを通した実削除（workspace listに無いUUIDだけが消えて残り1件は残る）と実施サマリへの反映まで検査する（検証1巡目 MAJOR #14対応: 39bは既定パスへのルーティングだけ、40/41は実物だが明示上書き経路だけを見ており、『既定パス×実物×実削除』の組合せが未検査だった） ==="
{
  T="$WORK_ROOT/t39c"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 検証2巡目 MINOR #33: REAL_CMUX_TASK_DECLAREはREPO_ROOT基準（このワーク
  # ツリー自身）なので、SKIPだと将来のリネーム等で本ケースが無言で落ちる
  # （#12と同型の事故）。無ければfail_caseで異常として可視化する。
  if [[ ! -x "$REAL_CMUX_TASK_DECLARE" ]]; then
    fail_case "AC-104(39c・既定経路): 実物cmux-task-declare.shが見つかりません（${REAL_CMUX_TASK_DECLARE}）"
  else
    # 既定パス（$HOME/work/takumi009-ai-env/cmux/cmux-task-declare.sh）へ
    # 実物をコピーして置く。cp なのでLIB_DIR解決（dirname "$0"）はコピー先
    # 基準になるが、cmux-task-declare.shはcmux/lib-vault-tasks.sh・
    # lib-cmux-workspace.shと同じ相対位置にある前提のため、依存libも
    # 一緑にコピーする。
    DEFAULT_PRUNE_DIR="$HOME/work/takumi009-ai-env/cmux"
    mkdir -p "$DEFAULT_PRUNE_DIR"
    cp "$REAL_CMUX_TASK_DECLARE" "$DEFAULT_PRUNE_DIR/cmux-task-declare.sh"
    REAL_CMUX_TASK_DECLARE_DIR="$(cd "$(dirname "$REAL_CMUX_TASK_DECLARE")" && pwd)"
    for lib in lib-model-view.sh lib-cmux-workspace.sh lib-vault-tasks.sh; do
      [ -f "$REAL_CMUX_TASK_DECLARE_DIR/$lib" ] && cp "$REAL_CMUX_TASK_DECLARE_DIR/$lib" "$DEFAULT_PRUNE_DIR/$lib"
    done
    chmod +x "$DEFAULT_PRUNE_DIR/cmux-task-declare.sh"

    # --- 隔離cmuxスタブ: window "1" に生存UUIDが1件だけ含まれる（case 40と同型） ---
    CMUX_STUB_DIR="$T/real-cmux-stub"
    CMUX_STUB_BIN="$CMUX_STUB_DIR/cmux"
    CMUX_STUB_STATE="$CMUX_STUB_DIR/state"
    setup_real_cmux_stub "$CMUX_STUB_BIN" "$CMUX_STUB_STATE"
    printf '[{"id":"1","index":0}]' > "$CMUX_STUB_STATE/windows.json"
    printf '{"workspaces":[{"id":"FB3B2F30-00D7-4093-91CE-0DE32B43165C"}]}' \
      > "$CMUX_STUB_STATE/workspaces.1.json"

    # --- 隔離宣言記録: 2件（うち1件はworkspace listに無いUUID＝W-8相当） ---
    DECLARE_STATE_DIR="$T/real-declare-state"
    mkdir -p "$DECLARE_STATE_DIR"
    DECLARE_STATE_FILE="$DECLARE_STATE_DIR/workspaces.json"
    printf '{"version":1,"workspaces":{"FB3B2F30-00D7-4093-91CE-0DE32B43165C":"slug-a","22222222-2222-2222-2222-222222222222":"slug-c"}}' \
      > "$DECLARE_STATE_FILE"

    rc=0
    VAULT="$VAULT" AIENV_REPO="$AIENV_REPO" MAINTENANCE_LOG_ROOT="$LOG_ROOT" TMPDIR="$TEST_TMPDIR" \
      FAKE_OSASCRIPT_LOG="$OSASCRIPT_LOG" FAKE_EXPORT_CALL_LOG="$EXPORT_CALL_LOG" \
      CMUX_TASK_STATE="$DECLARE_STATE_FILE" \
      CMUX_TASK_CMUX_BIN="$CMUX_STUB_BIN" \
      CMUX_TASK_VAULT="$T/unused-vault" \
      TIMEOUT_BACKUP_VAULT=10 TIMEOUT_EXPORT_PUBLIC_VAULT=10 TIMEOUT_CHECK_DRIFT=2 \
      TIMEOUT_FRAGMENTS_LOG=10 TIMEOUT_VAULT_INVENTORY=10 TIMEOUT_TASK_PRUNE=5 \
      MAINTENANCE_STALE_LOCK_SECONDS=3600 \
      GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
      bash "$REPO/scripts/maintenance.sh" > "$LAST_STDOUT" 2> "$LAST_STDERR" || rc=$?
    assert_eq "AC-104: exit 0（既定経路・実物）" "0" "$rc"

    REMAINING_KEYS="$(jq -r '.workspaces | keys | length' "$DECLARE_STATE_FILE" 2>/dev/null)"
    assert_eq "AC-104: 記録が2件→1件になる(既定経路でも実物の削除が実際に起きる)" "1" "$REMAINING_KEYS"
    assert_contains "AC-104: 残る1件はworkspace listにあるUUIDである" \
      "$(cat "$DECLARE_STATE_FILE")" "FB3B2F30-00D7-4093-91CE-0DE32B43165C"
    assert_not_contains "AC-104: workspace listに無いUUIDは消えている" \
      "$(cat "$DECLARE_STATE_FILE")" "22222222-2222-2222-2222-222222222222"

    RUN_DIR="$(readlink "$LOG_ROOT/latest")"
    FRAG_FILE="$(find "$VAULT/Fragments" -name '20*.md' | head -1)"
    FRAG_LINE="$(grep '^- 定常メンテ(週次): ' "$FRAG_FILE" 2>/dev/null)"
    assert_contains "AC-104: サマリ行が既定経路でも削除対象のUUID=slugを含む" "$FRAG_LINE" "・宣言掃除 実施・1件（22222222-2222-2222-2222-222222222222=slug-c）（詳細: ${RUN_DIR}）"
    assert_contains "AC-104: サマリ行に昇格候補の件数が出る" "$FRAG_LINE" "昇格候補0件"

    rm -rf "$DEFAULT_PRUNE_DIR"
  fi
}

# =============================================================================
# §16.6.2 系統①: 実cmux-task-declare.shとの結合試験（担当Bの成果物）
# =============================================================================
# ここまでの契約スタブ系（②）はmaintenance.sh側の統合ロジックだけを検査して
# きた。ここからは実物のcmux-task-declare.sh（REPO_ROOT配下のcmux/。
# cmux-session-todo v3で宣言CLIの実体がdotfilesからai-envへ移設された）を
# 実際に呼び、記録が本当に2件→1件へ減る／
# 1バイトも変わらないところまで見る（verifier実装レビュー1巡目#2対応）。
# cmux自体は隔離cmuxスタブ（setup_real_cmux_stub）に差し替え、宣言記録も
# 隔離パス（CMUX_TASK_STATE）へ書く＝実cmux・実記録には一切触れない。
# 実物が無い環境ではSKIP（既存テストのjq不在時と同じ流儀）。

echo "=== 40. 系統①(設計書§16.6.2): 実cmux-task-declare.shをmaintenance.shから呼ぶと、workspace listに無いUUIDだけが記録から消えて残り1件は残る(実結合・AC-57) ==="
{
  T="$WORK_ROOT/t40"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 検証2巡目 MINOR #33: SKIPだと将来ファイルをリネーム・削除しても本ケースが
  # 無言で落ちる（#12で起きた事故と同じ形）。REAL_CMUX_TASK_DECLAREは本ファイル
  # 冒頭で必ず解決される前提のパスなので、無ければ検査すべきものが検査でき
  # ていない異常としてfail_caseにする。
  if [[ ! -x "$REAL_CMUX_TASK_DECLARE" ]]; then
    fail_case "系統①(40): 実物cmux-task-declare.shが見つかりません（${REAL_CMUX_TASK_DECLARE}）"
  else
    # --- 隔離cmuxスタブ: window "1" に生存UUIDが1件だけ含まれる ---
    CMUX_STUB_DIR="$T/real-cmux-stub"
    CMUX_STUB_BIN="$CMUX_STUB_DIR/cmux"
    CMUX_STUB_STATE="$CMUX_STUB_DIR/state"
    setup_real_cmux_stub "$CMUX_STUB_BIN" "$CMUX_STUB_STATE"
    printf '[{"id":"1","index":0}]' > "$CMUX_STUB_STATE/windows.json"
    printf '{"workspaces":[{"id":"FB3B2F30-00D7-4093-91CE-0DE32B43165C"}]}' \
      > "$CMUX_STUB_STATE/workspaces.1.json"

    # --- 隔離宣言記録: 2件（うち1件はworkspace listに無いUUID＝W-8相当） ---
    DECLARE_STATE_DIR="$T/real-declare-state"
    mkdir -p "$DECLARE_STATE_DIR"
    DECLARE_STATE_FILE="$DECLARE_STATE_DIR/workspaces.json"
    printf '{"version":1,"workspaces":{"FB3B2F30-00D7-4093-91CE-0DE32B43165C":"slug-a","11111111-1111-1111-1111-111111111111":"slug-b"}}' \
      > "$DECLARE_STATE_FILE"

    # --- 呼び出し回数を数えるラッパ(設計書§16.6.2)。$0を実物へそのまま渡す
    #     ことで、実物側のLIB_DIR解決（dirname "$0"/..）を壊さない。
    PRUNE_CALL_LOG_REAL="$T/real-prune-call.log"
    REAL_WRAPPER="$T/real-declare-wrapper.sh"
    cat > "$REAL_WRAPPER" <<WRAPEOF
#!/bin/bash
echo "called" >> "$PRUNE_CALL_LOG_REAL"
exec bash "$REAL_CMUX_TASK_DECLARE" "\$@"
WRAPEOF
    chmod +x "$REAL_WRAPPER"

    rc=0
    MAINTENANCE_TASK_PRUNE_CMD="$REAL_WRAPPER" \
      CMUX_TASK_STATE="$DECLARE_STATE_FILE" \
      CMUX_TASK_CMUX_BIN="$CMUX_STUB_BIN" \
      CMUX_TASK_VAULT="$T/unused-vault" \
      run_maintenance || rc=$?
    assert_eq "exit 0" "0" "$rc"
    # symlinkを解決するlatest_run_dir()を使うと、macOSの/var->/private/var
    # のようなシンボリックリンク正規化でmaintenance.sh自身が埋め込む生の
    # $RUN_DIR文字列（ln -s "$RUN_DIR" ...で生成・非解決）とズレ、完全一致
    # 比較が常にFAILする（本テスト作成中に実測）。latestシンボリックリンクの
    # ターゲットをreadlinkでそのまま読み、生の文字列を使う。
    RUN_DIR="$(readlink "$LOG_ROOT/latest")"

    CALL_COUNT="$(grep -c . "$PRUNE_CALL_LOG_REAL" 2>/dev/null || echo 0)"
    assert_eq "掃除の入口(実物)は1回だけ呼ばれる" "1" "$CALL_COUNT"

    REMAINING_KEYS="$(jq -r '.workspaces | keys | length' "$DECLARE_STATE_FILE" 2>/dev/null)"
    assert_eq "記録が2件→1件になる(実物の削除が実際に起きる)" "1" "$REMAINING_KEYS"
    assert_contains "残る1件はworkspace listにあるUUIDである" \
      "$(cat "$DECLARE_STATE_FILE")" "FB3B2F30-00D7-4093-91CE-0DE32B43165C"
    assert_not_contains "workspace listに無いUUIDは消えている" \
      "$(cat "$DECLARE_STATE_FILE")" "11111111-1111-1111-1111-111111111111"

    # 実施サマリ行を1行だけ抽出し、掃除セグメント（区切り記号を含む完全な
    # セグメント単位）とRUN_DIRが含まれることを見る。
    FRAG_FILE="$(find "$VAULT/Fragments" -name '20*.md' | head -1)"
    FRAG_LINE="$(grep '^- 定常メンテ(週次): ' "$FRAG_FILE")"
    assert_contains "サマリ行が削除対象のUUID=slugとRUN_DIRを含む(AC-57)" "$FRAG_LINE" "・宣言掃除 実施・1件（11111111-1111-1111-1111-111111111111=slug-b）（詳細: ${RUN_DIR}）"

    # cmuxの書込系コマンド(AC-34)が1度も呼ばれていないことを、隔離cmux
    # スタブの集約呼出しログで検査する(verifier実装レビュー2巡目#10対応)。
    # grep -c は不一致のとき"0"を出力しつつ非0終了する。`|| echo 0`を
    # 続けると出力後の非0終了でechoも走り"0\n0"の二重出力になる落とし穴
    # （bash32-strict-mode-pitfalls）があるため、出力を先に受けてから
    # 数値かどうかで判定する。
    WRITE_CALL_COUNT="$(grep -cE '(^| )(todo|set-status|clear-status|set-progress|new-pane|new-surface)( |$)|workspace status set' \
      "$CMUX_STUB_STATE/all-calls.log" 2>/dev/null)"
    [[ "$WRITE_CALL_COUNT" =~ ^[0-9]+$ ]] || WRITE_CALL_COUNT=0
    assert_eq "cmuxの書込系コマンドは1度も呼ばれない(AC-34・X-1)" "0" "$WRITE_CALL_COUNT"
  fi
}

echo "=== 41. 系統①(設計書§16.6.2): 実cmux-task-declare.shの接続に失敗すると、記録は実行の前後でバイト単位で一致し、呼出回数1・サマリに固定の未実施文言が現れる(実結合・AC-58) ==="
{
  T="$WORK_ROOT/t41"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # 検証2巡目 MINOR #33（case 40と同じ理由）: SKIPをやめてfail_caseにする。
  if [[ ! -x "$REAL_CMUX_TASK_DECLARE" ]]; then
    fail_case "系統①(41): 実物cmux-task-declare.shが見つかりません（${REAL_CMUX_TASK_DECLARE}）"
  else
    CMUX_STUB_DIR="$T/real-cmux-stub"
    CMUX_STUB_BIN="$CMUX_STUB_DIR/cmux"
    CMUX_STUB_STATE="$CMUX_STUB_DIR/state"
    setup_real_cmux_stub "$CMUX_STUB_BIN" "$CMUX_STUB_STATE"
    # list-windows自体を失敗させる(接続不可・collect_alive_uuidsはこの1点で
    # 非0になり、以降の削除処理へは進まない契約＝cmux-task-declare.sh:244)。
    touch "$CMUX_STUB_STATE/fail_list_windows"

    DECLARE_STATE_DIR="$T/real-declare-state"
    mkdir -p "$DECLARE_STATE_DIR"
    DECLARE_STATE_FILE="$DECLARE_STATE_DIR/workspaces.json"
    printf '{"version":1,"workspaces":{"FB3B2F30-00D7-4093-91CE-0DE32B43165C":"slug-a","11111111-1111-1111-1111-111111111111":"slug-b"}}' \
      > "$DECLARE_STATE_FILE"
    cp "$DECLARE_STATE_FILE" "$DECLARE_STATE_FILE.before"

    PRUNE_CALL_LOG_REAL="$T/real-prune-call.log"
    REAL_WRAPPER="$T/real-declare-wrapper.sh"
    cat > "$REAL_WRAPPER" <<WRAPEOF
#!/bin/bash
echo "called" >> "$PRUNE_CALL_LOG_REAL"
exec bash "$REAL_CMUX_TASK_DECLARE" "\$@"
WRAPEOF
    chmod +x "$REAL_WRAPPER"

    rc=0
    MAINTENANCE_TASK_PRUNE_CMD="$REAL_WRAPPER" \
      CMUX_TASK_STATE="$DECLARE_STATE_FILE" \
      CMUX_TASK_CMUX_BIN="$CMUX_STUB_BIN" \
      CMUX_TASK_VAULT="$T/unused-vault" \
      run_maintenance || rc=$?
    assert_eq "exit 0" "0" "$rc"
    # symlinkを解決するlatest_run_dir()を使うと、macOSの/var->/private/var
    # のようなシンボリックリンク正規化でmaintenance.sh自身が埋め込む生の
    # $RUN_DIR文字列（ln -s "$RUN_DIR" ...で生成・非解決）とズレ、完全一致
    # 比較が常にFAILする（本テスト作成中に実測）。latestシンボリックリンクの
    # ターゲットをreadlinkでそのまま読み、生の文字列を使う。
    RUN_DIR="$(readlink "$LOG_ROOT/latest")"

    CALL_COUNT="$(grep -c . "$PRUNE_CALL_LOG_REAL" 2>/dev/null || echo 0)"
    assert_eq "掃除の入口(実物)は1回だけ呼ばれる" "1" "$CALL_COUNT"

    assert_files_identical "記録は実行の前後でバイト単位で一致する(実物が1件も削除しない契約どおり・AC-58)" \
      "$DECLARE_STATE_FILE" "$DECLARE_STATE_FILE.before"

    # 実施サマリ行を1行だけ抽出し、掃除セグメントとRUN_DIRが含まれることを見る
    # （case 40と同じ）。
    FRAG_FILE="$(find "$VAULT/Fragments" -name '20*.md' | head -1)"
    FRAG_LINE="$(grep '^- 定常メンテ(週次): ' "$FRAG_FILE")"
    assert_contains "サマリ行が未実施(接続不可)とRUN_DIRを含む(AC-58)" "$FRAG_LINE" "・宣言掃除 未実施（接続不可）（詳細: ${RUN_DIR}）"

    # cmuxの書込系コマンド(AC-34)が1度も呼ばれていないことを、隔離cmux
    # スタブの集約呼出しログで検査する(verifier実装レビュー2巡目#10対応)。
    # grep -c は不一致のとき"0"を出力しつつ非0終了する。`|| echo 0`を
    # 続けると出力後の非0終了でechoも走り"0\n0"の二重出力になる落とし穴
    # （bash32-strict-mode-pitfalls）があるため、出力を先に受けてから
    # 数値かどうかで判定する。
    WRITE_CALL_COUNT="$(grep -cE '(^| )(todo|set-status|clear-status|set-progress|new-pane|new-surface)( |$)|workspace status set' \
      "$CMUX_STUB_STATE/all-calls.log" 2>/dev/null)"
    [[ "$WRITE_CALL_COUNT" =~ ^[0-9]+$ ]] || WRITE_CALL_COUNT=0
    assert_eq "cmuxの書込系コマンドは1度も呼ばれない(AC-34・X-1)" "0" "$WRITE_CALL_COUNT"
  fi
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
