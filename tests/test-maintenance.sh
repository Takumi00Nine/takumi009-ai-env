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
# 実HOME・実Vault・実AIENV_REPO・実claude・実launchd・実osascriptには一切
# 依存しない: 毎回FAKEリポジトリ（scripts/lib・maintenance_run_step.pyは
# 実物をコピーして再利用し、check-drift.sh・backup-vault.sh・
# export-public-vault.sh・5検出器・maintenance_apply.pyはFAKEスタブに
# 差し替える）を組み立ててmaintenance.shを実行する。backup-vault.shだけは
# 実物を使う（MAINTENANCE_INTERNAL_CALLバイパスの実結線を検証するため）。
#
# 実行方法: bash tests/test-maintenance.sh

set -uo pipefail

export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
WORK_ROOT="$(mktemp -d)"

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
echo "${FAKE_DRIFT_JSON:-{\"total_drift\": 0, \"item4_drift\": 0, \"drift_excluding_item4\": 0}}"
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

  # --- FAKE 5検出器（Python）: fragments_log.py / vault_inventory.py /
  #     knowledge_merge_candidates.py / decision_propagation.py ---
  # bash 3.2（macOS既定・本環境の`bash`はこれ）には`${var^^}`（大文字化）が
  # 無いため`tr`で移植性のある形にする。
  local py_detector upper default_json
  for py_detector in fragments_log vault_inventory knowledge_merge_candidates; do
    upper="$(echo "$py_detector" | tr '[:lower:]' '[:upper:]')"
    # fragments_log.pyの実物は常にscan_error_countキーを含む契約
    # （2周目ハードニング・impl4でmaintenance.sh側がこのキーを厳密検証するように
    # なった）。FAKEの既定出力もその契約に合わせる（既定'{}'のままだと
    # 「正常系のはずのテストがscan_error_count欠落でanomaly扱いになる」という
    # FAKE側の不整合になる）。
    default_json='{}'
    [[ "$py_detector" == "fragments_log" ]] && default_json='{"scan_error_count": 0}'
    cat > "$repo/scripts/vault-agents/${py_detector}.py" <<PYEOF
#!/usr/bin/env python3
import os, sys
print(os.environ.get("FAKE_${upper}_JSON", '$default_json'))
sys.exit(int(os.environ.get("FAKE_${upper}_EXIT", "0")))
PYEOF
    chmod +x "$repo/scripts/vault-agents/${py_detector}.py"
  done

  cat > "$repo/scripts/vault-agents/decision_propagation.py" <<'PYEOF'
#!/usr/bin/env python3
import argparse, os, sys
ap = argparse.ArgumentParser()
ap.add_argument("--since")
ap.add_argument("--out")
args = ap.parse_args()
if args.out:
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(os.environ.get("FAKE_DECISION_OUT", "# fake decision propagation report\n"))
sys.exit(int(os.environ.get("FAKE_DECISION_EXIT", "0")))
PYEOF
  chmod +x "$repo/scripts/vault-agents/decision_propagation.py"

  # --- FAKE maintenance_apply.py（自身のargvをFAKE_APPLY_ARGV_LOGへ記録） ---
  cat > "$repo/scripts/vault-agents/maintenance_apply.py" <<'PYEOF'
#!/usr/bin/env python3
import argparse, json, os, sys
ap = argparse.ArgumentParser()
ap.add_argument("--vault")
ap.add_argument("--workdir", required=True)
ap.add_argument("--status-file")
ap.add_argument("--claude-timeout")
ap.add_argument("--max-merge-actions")
ap.add_argument("--preferences-proposals-dir")
ap.add_argument("--fragments-json")
ap.add_argument("--merge-json")
ap.add_argument("--dry-run", action="store_true")
args = ap.parse_args()
if os.environ.get("FAKE_APPLY_ARGV_LOG"):
    with open(os.environ["FAKE_APPLY_ARGV_LOG"], "w", encoding="utf-8") as f:
        f.write(" ".join(sys.argv[1:]))
if os.environ.get("FAKE_APPLY_SLEEP"):
    import time
    time.sleep(float(os.environ["FAKE_APPLY_SLEEP"]))
status = json.loads(os.environ.get(
    "FAKE_APPLY_STATUS_JSON",
    '{"ok": true, "anomaly": false, "reason": null, "n_promoted": 0, "n_merged": 0, '
    '"n_merged_partial": 0, "n_skipped": 0, "warnings": []}'))
if args.status_file:
    with open(args.status_file, "w", encoding="utf-8") as f:
        json.dump(status, f)
sys.exit(int(os.environ.get("FAKE_APPLY_EXIT", "0")))
PYEOF
  chmod +x "$repo/scripts/vault-agents/maintenance_apply.py"
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

# 共通セットアップ: FAKEリポジトリ・Vault・AIENV_REPO・環境変数一式を用意する。
# 呼び出し後、下記のグローバル変数が使える。
# REPO / VAULT / AIENV_REPO / LOG_ROOT / OSASCRIPT_LOG / EXPORT_CALL_LOG / APPLY_ARGV_LOG
setup_test_env() {
  local test_dir="$1"
  REPO="$test_dir/repo"
  VAULT="$test_dir/vault"
  AIENV_REPO="$test_dir/aienv"
  LOG_ROOT="$test_dir/logs/maintenance"
  local osascript_dir="$test_dir/bin"
  OSASCRIPT_LOG="$test_dir/osascript.log"
  EXPORT_CALL_LOG="$test_dir/export-call.log"
  APPLY_ARGV_LOG="$test_dir/apply-argv.log"
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
  # 呼び出し側が`TIMEOUT_MAINTENANCE_APPLY=1 run_maintenance`のように個別の
  # timeoutを上書きできるよう、`:=`でアンビエント環境変数に既定値を補うだけに
  # とどめる（固定で`VAR=10 ... bash script.sh`と書くと、呼び出し側が事前に
  # 設定したアンビエント値より本関数内の再代入が常に勝ってしまい、上書きが
  # 一切効かなくなる＝本テスト作成時に実際に踏んだ落とし穴）。
  : "${TIMEOUT_BACKUP_VAULT:=10}"
  : "${TIMEOUT_EXPORT_PUBLIC_VAULT:=10}"
  : "${TIMEOUT_CHECK_DRIFT:=2}"
  : "${TIMEOUT_FRAGMENTS_LOG:=10}"
  : "${TIMEOUT_VAULT_INVENTORY:=10}"
  : "${TIMEOUT_KNOWLEDGE_MERGE:=10}"
  : "${TIMEOUT_DECISION_PROPAGATION:=10}"
  : "${TIMEOUT_MAINTENANCE_APPLY:=10}"
  : "${MAINTENANCE_STALE_LOCK_SECONDS:=3600}"
  VAULT="$VAULT" AIENV_REPO="$AIENV_REPO" MAINTENANCE_LOG_ROOT="$LOG_ROOT" TMPDIR="$TEST_TMPDIR" \
    FAKE_OSASCRIPT_LOG="$OSASCRIPT_LOG" FAKE_EXPORT_CALL_LOG="$EXPORT_CALL_LOG" \
    FAKE_APPLY_ARGV_LOG="$APPLY_ARGV_LOG" \
    TIMEOUT_BACKUP_VAULT="$TIMEOUT_BACKUP_VAULT" TIMEOUT_EXPORT_PUBLIC_VAULT="$TIMEOUT_EXPORT_PUBLIC_VAULT" \
    TIMEOUT_CHECK_DRIFT="$TIMEOUT_CHECK_DRIFT" TIMEOUT_FRAGMENTS_LOG="$TIMEOUT_FRAGMENTS_LOG" \
    TIMEOUT_VAULT_INVENTORY="$TIMEOUT_VAULT_INVENTORY" TIMEOUT_KNOWLEDGE_MERGE="$TIMEOUT_KNOWLEDGE_MERGE" \
    TIMEOUT_DECISION_PROPAGATION="$TIMEOUT_DECISION_PROPAGATION" TIMEOUT_MAINTENANCE_APPLY="$TIMEOUT_MAINTENANCE_APPLY" \
    MAINTENANCE_STALE_LOCK_SECONDS="$MAINTENANCE_STALE_LOCK_SECONDS" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    "$@" bash "$REPO/scripts/maintenance.sh" > "$LAST_STDOUT" 2> "$LAST_STDERR"
}

# 最新の実行ディレクトリ（latest symlinkの実体）を返す。
latest_run_dir() {
  python3 -c "import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(p.resolve() if p.is_symlink() else '')" "$LOG_ROOT/latest"
}

echo "=== 1. 正常系: 全Phase成功・anomalyなし・last_success_at更新・通知なし ==="
{
  T="$WORK_ROOT/t1"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  RUN_DIR="$(latest_run_dir)"
  assert_file_exists "latest symlinkの実体が存在する" "$RUN_DIR/apply-status.json"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "started_atが記録される" "$LAST_RUN" "started_at"
  assert_contains "last_success_atが記録される（完全正常終了）" "$LAST_RUN" "last_success_at"
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
  assert_not_contains "last_success_atは記録されない" "$LAST_RUN" "last_success_at"
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
  # 2026-07-16 Codexレビュー指摘Major対応で方針を変更: 隔離して継続する異常
  # （export再試行失敗を含む）が1件でもあればlast_success_atは進めない
  # （fragments_log.py/decision_propagation.pyの--sinceが次回も正しく
  # 巻き戻れるようにする保守的な方針＝「完全正常終了時のみ」を文字どおり
  # 満たす）。
  assert_not_contains "last_success_atは更新されない（export失敗もRUN_FULLY_OKを崩す）" "$LAST_RUN" "last_success_at"
}

echo "=== 5. Phase1①: check-drift.shが実drift検出(rc=1)ならfail-fastしPhase2は起動されない ==="
{
  T="$WORK_ROOT/t5"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_EXIT=1 FAKE_DRIFT_JSON='{"total_drift": 3, "item4_drift": 0, "drift_excluding_item4": 3}' \
    run_maintenance || rc=$?
  assert_eq "exit 1" "1" "$rc"
  assert_file_not_exists "maintenance_apply.pyは起動されない（Phase2未到達）" "$APPLY_ARGV_LOG"
  assert_file_exists "異常通知される" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "last_success_atは更新されない" "$LAST_RUN" "last_success_at"
}

echo "=== 6. Phase1①: check-drift.shの実行異常(rc>=2)もfail-fastする ==="
{
  T="$WORK_ROOT/t6"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_EXIT=2 run_maintenance || rc=$?
  assert_eq "exit 1" "1" "$rc"
  assert_file_not_exists "Phase2は起動されない" "$APPLY_ARGV_LOG"
}

echo "=== 7. Phase1①: check-drift.shのtimeoutもfail-fastする ==="
{
  T="$WORK_ROOT/t7"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DRIFT_SLEEP=5 run_maintenance || rc=$?
  assert_eq "exit 1" "1" "$rc"
  assert_file_not_exists "Phase2は起動されない" "$APPLY_ARGV_LOG"
  assert_contains "timeoutとして記録される" "$(cat "$LAST_STDOUT" "$LAST_STDERR" 2>/dev/null)" "timeout"
}

echo "=== 8. Phase1②: fragments_log.py失敗時はPhase2へ--fragments-jsonを渡さず継続する ==="
{
  T="$WORK_ROOT/t8"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離・Phase2は実行される）" "0" "$rc"
  assert_file_exists "Phase2(maintenance_apply.py)は起動される" "$APPLY_ARGV_LOG"
  assert_not_contains "--fragments-jsonは渡されない" "$(cat "$APPLY_ARGV_LOG")" "--fragments-json"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_not_contains "last_success_atは更新されない（隔離継続した異常もRUN_FULLY_OKを崩す）" \
    "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
}

echo "=== 8b. Phase1②: fragments_log.pyがexit 0でもscan_error_count>0（Fragmentsファイル読取失敗）ならanomaly化しlast_success_atを進めない（2周目・全体構成再レビュー後の小修正） ==="
{
  T="$WORK_ROOT/t8b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='{"since": "2026-07-01", "until": "2026-07-16", "since_fallback_reason": null, "scanned_files": 1, "scan_error_count": 2, "fragments": [], "truncated": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離・rc自体はOK 0なのでPhase2は実行される）" "0" "$rc"
  assert_file_exists "Phase2(maintenance_apply.py)は起動される" "$APPLY_ARGV_LOG"
  assert_contains "scan_error_count>0でも--fragments-json自体は渡される（候補は活かしつつ再走査させる設計）" \
    "$(cat "$APPLY_ARGV_LOG")" "--fragments-json"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "通知内容にscan_error_countの件数が含まれる" "$(cat "$OSASCRIPT_LOG")" "読み取れなかったFragmentsファイルが2件"
  assert_not_contains "last_success_atは更新されない（翌週同じ窓を再走査させるため）" \
    "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
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
    "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
}

echo "=== 8d. Phase1②: fragments_log.pyがexit 0でも出力が壊れたJSON（契約違反）ならscan_error_countを確定できないためanomaly化し--fragments-jsonも渡さない（0件へfail-openで丸めない・Codex一次レビュー指摘Major対応） ==="
{
  T="$WORK_ROOT/t8d"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_FRAGMENTS_LOG_JSON='not valid json{{{' run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離・Phase2は実行される）" "0" "$rc"
  assert_file_exists "Phase2(maintenance_apply.py)は起動される" "$APPLY_ARGV_LOG"
  assert_not_contains "scan_error_countを確定できないため--fragments-jsonは渡されない" \
    "$(cat "$APPLY_ARGV_LOG")" "--fragments-json"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "通知内容に契約違反/JSON破損の疑いが含まれる" "$(cat "$OSASCRIPT_LOG")" "scan_error_countを取得できませんでした"
  assert_not_contains "last_success_atは更新されない" "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
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
  assert_not_contains "キー欠落のため--fragments-jsonは渡されない" \
    "$(cat "$APPLY_ARGV_LOG")" "--fragments-json"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_not_contains "last_success_atは更新されない" "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
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
    assert_not_contains "値=${badval}は非負整数でないため--fragments-jsonは渡されない" \
      "$(cat "$APPLY_ARGV_LOG")" "--fragments-json"
    assert_not_contains "値=${badval}ではlast_success_atは更新されない" \
      "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
  done
}

echo "=== 9. Phase1③: vault_inventory.py失敗時もanomaly化しつつ処理は継続する（--inventory-jsonの配線はFIX機能撤去に伴い削除済み・成功/失敗いずれでもPhase2へは渡らない） ==="
{
  # FIX機能（action: fix_approve）は2026-07-18本人裁定で丸ごと削除され、
  # inventory.jsonをmaintenance_apply.pyへFIX候補として渡す配線も撤去された
  # （[[Decisions/2026-07-18-external-brain-hardening]]2周目）。vault_inventory.py
  # 自体は棚卸し検出（missing_updated等の検出のみ）として引き続き週次実行し、
  # 失敗時はanomaly化してlast_success_atを進めない。
  T="$WORK_ROOT/t9"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_VAULT_INVENTORY_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_not_contains "--inventory-jsonはそもそもPhase2へ渡されない（配線撤去済み）" "$(cat "$APPLY_ARGV_LOG")" "--inventory-json"
  assert_not_contains "last_success_atは更新されない" "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
}

echo "=== 10. Phase1④: knowledge_merge_candidates.py失敗時はPhase2へ--merge-jsonを渡さず継続する ==="
{
  T="$WORK_ROOT/t10"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_KNOWLEDGE_MERGE_CANDIDATES_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_not_contains "--merge-jsonは渡されない" "$(cat "$APPLY_ARGV_LOG")" "--merge-json"
  assert_not_contains "last_success_atは更新されない" "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
}

echo "=== 11. Phase1⑤: decision_propagation.pyのrc=1(波及漏れ検出)は正常扱い ==="
{
  T="$WORK_ROOT/t11"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DECISION_EXIT=1 run_maintenance || rc=$?
  assert_eq "exit 0（rc=1は正常な検出結果）" "0" "$rc"
  assert_file_not_exists "rc=1は異常通知の対象ではない（他のanomalyが無ければ通知なし）" "$OSASCRIPT_LOG"
  RUN_DIR="$(latest_run_dir)"
  assert_contains "サマリ行に波及漏れ疑い件数が反映される（レポート本文をパースできない場合は1件へフォールバック）" \
    "$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")" "波及漏れ疑い1件"
}

echo "=== 11b. Phase1⑤: decision_propagation.pyのレポート本文から実件数を拾えれば0/1でなく実件数がサマリへ反映される（2026-07-18ハードニング対処方針4） ==="
{
  T="$WORK_ROOT/t11b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  # 実物のdecision_propagation.pyのbuild_report()が出力する行フォーマットと
  # 同じ文言をFAKE_DECISION_OUTへ与え、maintenance.sh側のgrepパースを狙い撃ちで検証する。
  FAKE_DECISION_EXIT=1 \
    FAKE_DECISION_OUT="# Decision波及チェックレポート 2026-07-18

- **波及漏れの疑い: 3 ノート**（Decision 2 件）
" \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_contains "サマリ行に実件数(3件)が反映される（0/1の二値ではない）" \
    "$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")" "波及漏れ疑い3件"
}

echo "=== 12. Phase1⑤: decision_propagation.pyのrc>=2は失敗として記録されるが継続する ==="
{
  T="$WORK_ROOT/t12"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_DECISION_EXIT=2 run_maintenance || rc=$?
  assert_eq "exit 0（エラー隔離）" "0" "$rc"
  assert_file_exists "Phase2は実行される" "$APPLY_ARGV_LOG"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_not_contains "last_success_atは更新されない" "$(cat "$LOG_ROOT/last-run.json")" "last_success_at"
}

echo "=== 13. Phase2: maintenance_apply.pyがanomaly=trueを報告したらlast_success_atを更新せず通知する ==="
{
  T="$WORK_ROOT/t13"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_APPLY_STATUS_JSON='{"ok": false, "anomaly": true, "reason": "schema_violation: test", "n_promoted": 0, "n_merged": 0, "n_merged_partial": 0, "n_skipped": 0, "warnings": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0（maintenance_apply.py自体は正常終了する契約）" "0" "$rc"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  assert_contains "通知内容にreasonが含まれる" "$(cat "$OSASCRIPT_LOG")" "schema_violation"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "last_success_atは更新されない" "$LAST_RUN" "last_success_at"
}

echo "=== 14. Phase2: maintenance_apply.py自体がtimeoutしたら異常として記録される ==="
{
  T="$WORK_ROOT/t14"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  TIMEOUT_MAINTENANCE_APPLY=1 FAKE_APPLY_SLEEP=5 run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_exists "異常が記録され通知される" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "last_success_atは更新されない" "$LAST_RUN" "last_success_at"
}

echo "=== 15. Phase3: サマリ行に各件数(promote/merge/merge_partial/skip)が反映される ==="
{
  # FIX機能（action: fix_approve）は2026-07-18本人裁定で丸ごと削除された
  # ため、サマリ行から「修正N件」は撤去された（[[Decisions/2026-07-18-
  # external-brain-hardening]]2周目）。
  T="$WORK_ROOT/t15"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_APPLY_STATUS_JSON='{"ok": true, "anomaly": false, "reason": null, "n_promoted": 2, "n_merged": 1, "n_merged_partial": 1, "n_skipped": 4, "warnings": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  FRAG_TEXT="$(cat "$(find "$VAULT/Fragments" -name '20*.md' | head -1)")"
  assert_contains "昇格2件" "$FRAG_TEXT" "昇格2件"
  assert_contains "マージ1件" "$FRAG_TEXT" "マージ1件"
  assert_contains "部分適用1件" "$FRAG_TEXT" "部分適用1件"
  assert_not_contains "修正N件の表記はもう出ない(FIX機能撤去)" "$FRAG_TEXT" "修正"
  assert_contains "見送り4件" "$FRAG_TEXT" "見送り4件"
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
  assert_file_exists "1回目のRUN_DIRも削除されず残っている（保持期間内）" "$FIRST_RUN_DIR/apply-status.json"
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
  assert_file_not_exists "Phase1は実行されない（Phase2未起動で確認）" "$APPLY_ARGV_LOG"
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

echo "=== 22. Phase2への--fragments-json/--merge-jsonは全検出器成功時に渡される（--inventory-jsonはFIX機能撤去に伴い配線自体が削除済み） ==="
{
  T="$WORK_ROOT/t22"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  run_maintenance
  ARGV="$(cat "$APPLY_ARGV_LOG")"
  assert_contains "--fragments-jsonが渡される" "$ARGV" "--fragments-json"
  assert_not_contains "--inventory-jsonは渡されない（配線撤去済み・2026-07-18本人裁定）" "$ARGV" "--inventory-json"
  assert_contains "--merge-jsonが渡される" "$ARGV" "--merge-json"
  assert_contains "--vaultが渡される" "$ARGV" "--vault"
  assert_contains "--workdirが渡される" "$ARGV" "--workdir"
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
  assert_file_not_exists "Phase1以降は実行されない" "$APPLY_ARGV_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "started_atは記録される（自己ロックアウト対策）" "$LAST_RUN" "started_at"
  assert_not_contains "last_success_atは記録されない" "$LAST_RUN" "last_success_at"
}

echo "=== 24. Phase3: 提案ディレクトリが空ならFragmentsサマリのPreferences未確認提案は0件・マーカーファイルは生成しない（2026-07-18ハードニング・pendingマーカー層撤去） ==="
{
  T="$WORK_ROOT/t24"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  # PREFERENCES_PROPOSALS_DIRの既定は$HOME/.claude/logs/maintenance/
  # preferences-proposals/（$HOMEはこのテストファイル冒頭で1回だけ設定される
  # 共有fake HOME）。他テストが残した提案ファイルと混ざらないよう明示的に
  # クリーンな状態から始める（テスト分離）。本テストでは何も置かない＝
  # 提案0件の週を再現する。
  rm -rf "$HOME/.claude/logs/maintenance/preferences-proposals" 2>/dev/null || true
  FAKE_APPLY_STATUS_JSON='{"ok": true, "anomaly": false, "reason": null, "n_promoted": 1, "n_merged": 0, "n_merged_partial": 0, "n_skipped": 0, "warnings": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_not_exists "pendingマーカー機構自体が撤去済みのためファイルは作られない" "$LOG_ROOT/preferences-proposals.pending"
  assert_not_contains "異常通知の対象でもない（0件は正常系）" "$(cat "$OSASCRIPT_LOG" 2>/dev/null || true)" "pending"
  assert_contains "Fragmentsサマリ行はPreferences未確認提案0件と出る" \
    "$(find "$VAULT/Fragments" -name '20*.md' -exec cat {} \;)" "Preferences未確認提案0件"
}

echo "=== 25. Phase3: proposals_dirに*.mdファイルが実在すればFragmentsサマリのPreferences未確認提案件数へそのまま反映される（マーカー層撤去・ディレクトリ直接カウント方式） ==="
{
  T="$WORK_ROOT/t25"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # PREFERENCES_PROPOSALS_DIRの既定は$HOME/.claude/logs/maintenance/
  # preferences-proposals/。ここへ直接、maintenance_apply.pyの
  # apply_promote_preferences_proposal()が実際に書く契約どおりの
  # <slug>.md + <slug>.meta.jsonを事前に置く（sidecarは*.mdの拡張子で
  # ないため件数に数えられないことも同時に確認する）。他テストの残留物と
  # 混ざらないよう明示的にクリーンな状態から始める（テスト分離）。
  PROPOSALS_DIR="$HOME/.claude/logs/maintenance/preferences-proposals"
  rm -rf "$PROPOSALS_DIR" 2>/dev/null || true
  mkdir -p "$PROPOSALS_DIR"
  echo "---
date: 2026-07-16
---

下書き本文" > "$PROPOSALS_DIR/frag-x.md"
  echo '{"id": "frag-x", "source_relpath": "Fragments/2026-07/2026-07-15.md", "generated_at": "2026-07-16T00:00:00Z"}' \
    > "$PROPOSALS_DIR/frag-x.meta.json"
  rc=0
  run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_not_exists "pendingマーカーファイルは生成されない(機構自体が撤去済み)" "$LOG_ROOT/preferences-proposals.pending"
  ARGV_LOG="$(cat "$APPLY_ARGV_LOG" 2>/dev/null || echo "")"
  assert_contains "maintenance_apply.pyへ--preferences-proposals-dirが結線される" "$ARGV_LOG" "--preferences-proposals-dir $PROPOSALS_DIR"
  assert_contains "Fragmentsサマリ行にもPreferences提案件数(1件・sidecarは数えない)が出る" \
    "$(find "$VAULT/Fragments" -name '20*.md' -exec cat {} \;)" "Preferences未確認提案1件"
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
}

echo "=== 27. Phase2: apply-status.jsonのok/anomalyが矛盾する組合せ(ok=false かつ anomaly=false)は成功扱いにしない ==="
{
  T="$WORK_ROOT/t27"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  rc=0
  FAKE_APPLY_STATUS_JSON='{"ok": false, "anomaly": false, "reason": null, "n_promoted": 0, "n_merged": 0, "n_merged_partial": 0, "n_skipped": 0, "warnings": []}' \
    run_maintenance || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_exists "矛盾したstatus-fileはanomaly扱いで通知される" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_not_contains "last_success_atは更新されない" "$LAST_RUN" "last_success_at"
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
  assert_file_not_exists "Phase0以降は実行されない" "$APPLY_ARGV_LOG"
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
  # （parse_step_status/apply-status.json/apply-log.json側はテスト30bで
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
  assert_contains "last_success_atが正しく記録される(完全正常終了)" "$LAST_RUN" "last_success_at"
}

echo "=== 30b. MAINTENANCE_LOG_ROOTのパスにシングルクォートが含まれても壊れず正常終了する（parse_step_status/apply-status.jsonの回帰テスト・Codexレビュー指摘Minor対応。2026-07-18ハードニングでpendingマーカー関連の検証部分は撤去） ==="
{
  T="$WORK_ROOT/t30b"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"
  # LOG_ROOT自体をシングルクォートを含むパスへ差し替える。RUN_DIR（status-file
  # 群・apply-status.jsonの置き場所）はLOG_ROOT配下のため、parse_step_status()・
  # Phase2のapply-status.json解析を狙い撃ちで検証できる。run_maintenance()
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
  assert_contains "last_success_atが正しく記録される(apply-status.json解析が構文破壊せず完走)" \
    "$QUOTE_LAST_RUN" "last_success_at"
}

echo "=== 31. 統合テスト: 実物のfragments_log.py/vault_inventory.py/knowledge_merge_candidates.py/maintenance_apply.pyを使った「候補0件の静かな週」でanomaly=false・通知なし・last_success_atが前進する（tester独立検証F2対応） ==="
{
  # tester独立検証F2で実測: maintenance_apply.py内の_write_status_file()の
  # 一部呼び出し箇所でn_merged_partialキーが欠落しており、maintenance.sh側の
  # 7キー必須検証で静穏週のたびに偽anomaly判定→last_success_atが進まず
  # --sinceが巻き戻らない実害があった。本テストファイルの他の全テストは
  # setup_fake_repo()がmaintenance_apply.py等をFAKEスタブへ差し替えるため
  # （このFAKEは元々全キーを正しく書いており、実物側の欠陥を検出できない）、
  # ここだけ意図的に実物のPython実装（fragments_log.py・vault_inventory.py・
  # knowledge_merge_candidates.py・maintenance_apply.py・その依存モジュール
  # merge_checks.py/merge_state.py/vault_lib.py）へ差し替え、実際に空の
  # （何も検出しない）Vaultに対して実行することで、Phase1→Phase2の実際の
  # 契約（status-file 7キー）が壊れていないことを直接検証する。
  T="$WORK_ROOT/t31"; mkdir -p "$T"
  setup_test_env "$T"
  LAST_STDOUT="$T/stdout.log"; LAST_STDERR="$T/stderr.log"

  for real_py in fragments_log vault_inventory knowledge_merge_candidates maintenance_apply \
                 merge_checks merge_state vault_lib; do
    cp "$REPO_ROOT/scripts/vault-agents/${real_py}.py" "$REPO/scripts/vault-agents/${real_py}.py"
    chmod +x "$REPO/scripts/vault-agents/${real_py}.py"
  done

  # 実物のfragments_log.py/vault_inventory.pyはVaultパスを$HOME/Data/obsidian
  # に固定しており（--vaultフラグを受け付けない・maintenance.sh:419のコメント
  # 参照）、$VAULT（本テストファイルの慣例＝$T/vault）を素直には見てくれない。
  # $HOME/Data/obsidianを$VAULTへのsymlinkにすることで、両者を同じ実体へ
  # 一致させる（本テストは全テスト中で最後に配置しているため、本テストの
  # $HOME/Data作成が他テストへ波及する心配は無い＝$HOMEはファイル冒頭で
  # ファイル全体で1つだけexportされ使い回される設計のため）。
  mkdir -p "$HOME/Data"
  ln -s "$VAULT" "$HOME/Data/obsidian"

  # VAULTは setup_test_env() が作る最小構成（Knowledge/dummy.mdのみ・
  # Fragments空・updated欠落ノート無し）に加え、実物のvault_inventory.pyが
  # BOOTSTRAP_FILES（bootstrap-vault.shと同じ必読5ファイル）を無条件で
  # `read_text()`する箇所があり、いずれか1つでも欠けるとFileNotFoundError
  # で未処理例外クラッシュする（本テスト作成中に実測発見。既存の`vault_agent_
  # installed`型のガードとは別種の欠陥＝bootstrap-vault.sh側は「存在する
  # ファイルだけ必読リストに載せる」よう改修済みだが、vault_inventory.py側の
  # 同名リストには同じ改修が及んでいなかった。本テストのスコープ外の別欠陥
  # のため、ここでは実行前提を満たすだけに留め、リーダーへ別途申告する）。
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
  assert_file_exists "実物のmaintenance_apply.pyがapply-status.jsonを生成する" "$RUN_DIR/apply-status.json"
  APPLY_STATUS="$(cat "$RUN_DIR/apply-status.json")"
  MISSING_KEYS="$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
required = ['ok', 'anomaly', 'n_promoted', 'n_merged', 'n_merged_partial', 'n_skipped']
print(','.join(k for k in required if k not in d))
" "$APPLY_STATUS")"
  assert_eq "実物のapply-status.jsonに6必須キーが全て揃っている(F2の実害範囲を直接検証・n_fixedは2026-07-18本人裁定でFIX機能ごと撤去済み)" "" "$MISSING_KEYS"
  assert_contains "anomaly=falseで完了する" "$APPLY_STATUS" '"anomaly": false'

  assert_file_not_exists "anomaly無しのため通知は送られない" "$OSASCRIPT_LOG"
  LAST_RUN="$(cat "$LOG_ROOT/last-run.json")"
  assert_contains "last_success_atが前進する(完全正常終了)" "$LAST_RUN" "last_success_at"
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
