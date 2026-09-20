#!/usr/bin/env bash
# scripts/fragments-reviewed.sh のユニットテスト（昇格の締めCLI・要件・設計＝
# requirements-design-v1.md FR-3〜5・§2.3・§2.4・2026-09-20）。
#
# 実 $HOME・実 last-run.json・実 fragments_log.py（実Vault）には一切触れない:
# HOME を隔離 temp へ差し替え、FRAGMENTS_LOG_PY を FAKE スタブ（Python・環境変数で
# JSON出力と終了コード/sleepを差し替え可能）へ向け、LAST_RUN_FILE も temp へ向ける。
# 「last-run.jsonを1バイトも変えない」検査はsha256で行う。
#
# 実行方法: bash tests/test-fragments-reviewed.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/fragments-reviewed.sh"

HOME="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗" >&2; exit 1; }
[[ -n "$HOME" && "$HOME" != "/" && -d "$HOME" ]] || { echo "FATAL: HOME 隔離に失敗" >&2; exit 1; }
export HOME
WORK_ROOT="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗" >&2; exit 1; }
[[ -n "$WORK_ROOT" && "$WORK_ROOT" != "/" && -d "$WORK_ROOT" ]] || { echo "FATAL: WORK_ROOT 隔離に失敗" >&2; exit 1; }
trap 'rm -rf "$HOME" "$WORK_ROOT"' EXIT

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
assert_unchanged() {
  # last-run.jsonが1バイトも変わっていないことをsha256で検査する（存在しない
  # 場合も「無いまま」であれば不変とみなす＝AC-3b/AC-4の対象は「書かない」こと）。
  local desc="$1" before="$2" after="$3"
  if [[ "$before" == "$after" ]]; then pass "$desc"; else fail_case "$desc (sha256不一致: before=$before after=$after)"; fi
}
sha_of() {
  # ファイルが無ければ固定文字列「absent」を返す（存在しないこと自体もsha比較対象にする）。
  if [[ -f "$1" ]]; then shasum -a256 "$1" | awk '{print $1}'; else echo "absent"; fi
}

# FAKE fragments_log.py（Python・環境変数でJSON出力/終了コード/sleepを制御）。
# test-maintenance.shのFAKE検出器スタブと同じ流儀（契約＝scan_error_count・
# fragments配列・truncatedを含むJSON）。
setup_fake_fragments_log() {
  local path="$1"
  cat > "$path" <<'PYEOF'
#!/usr/bin/env python3
import os, sys
sleep_s = os.environ.get("FAKE_FRAGMENTS_LOG_SLEEP")
if sleep_s:
    import time
    time.sleep(float(sleep_s))
default_json = '{"scan_error_count": 0, "fragments": [], "truncated": []}'
print(os.environ.get("FAKE_FRAGMENTS_LOG_JSON", default_json))
sys.exit(int(os.environ.get("FAKE_FRAGMENTS_LOG_EXIT", "0")))
PYEOF
  chmod +x "$path"
}

# 共通セットアップ。呼び出し後: T / FAKE_LOG_PY / LAST_RUN_FILE / OUT / ERR が使える。
setup_case() {
  local t="$1"
  mkdir -p "$t"
  T="$t"
  FAKE_LOG_PY="$t/fake_fragments_log.py"
  LAST_RUN_FILE="$t/last-run.json"
  OUT="$t/stdout.log"
  ERR="$t/stderr.log"
  setup_fake_fragments_log "$FAKE_LOG_PY"
}

# CLIを実行する（既定timeoutはテスト用に短縮）。追加引数は`run_cli --dry-run`のように渡す。
run_cli() {
  LAST_RUN_FILE="$LAST_RUN_FILE" FRAGMENTS_LOG_PY="$FAKE_LOG_PY" \
    TIMEOUT_FRAGMENTS_LOG="${TIMEOUT_FRAGMENTS_LOG:-5}" \
    bash "$SCRIPT" "$@" > "$OUT" 2> "$ERR"
}

TODAY="$(date -u +%Y-%m-%d)"

echo "=== 1. AC-1/AC-3a: 正常時にlast-run.jsonへ3キー（fragments_reviewed_at/fragments_candidates/fragments_since）が期待値で書かれ、他のキーは不変・exit 0 ==="
{
  setup_case "$WORK_ROOT/t1"
  echo '{"last_success_at": "2026-09-01T00:00:00Z", "last_result": "success"}' > "$LAST_RUN_FILE"
  FAKE_FRAGMENTS_LOG_JSON='{"scan_error_count": 0, "fragments": [{"title": "a"}, {"title": "b"}], "truncated": [{"title": "c"}]}' \
    run_cli
  rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "fragments_candidatesはfragments配列長(2)・truncatedは数えない" \
    "2" "$(jq -r '.fragments_candidates' "$LAST_RUN_FILE")"
  assert_eq "fragments_sinceは今日の日付" "$TODAY" "$(jq -r '.fragments_since' "$LAST_RUN_FILE")"
  REVIEWED_AT="$(jq -r '.fragments_reviewed_at' "$LAST_RUN_FILE")"
  assert_contains "fragments_reviewed_atはlast_success_atと同形式(UTC ISO8601 Z)" "$REVIEWED_AT" "T"
  if [[ "$REVIEWED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "fragments_reviewed_atがYYYY-MM-DDTHH:MM:SSZ形式に一致する"
  else
    fail_case "fragments_reviewed_atが期待形式でない: $REVIEWED_AT"
  fi
  assert_eq "既存キーlast_success_atは不変" "2026-09-01T00:00:00Z" "$(jq -r '.last_success_at' "$LAST_RUN_FILE")"
  assert_eq "既存キーlast_resultは不変" "success" "$(jq -r '.last_result' "$LAST_RUN_FILE")"
  assert_contains "stdoutに1行サマリが出る" "$(cat "$OUT")" "昇格対応済み: "
  assert_contains "stdoutサマリに候補件数が出る" "$(cat "$OUT")" "候補2件"
}

echo "=== 2. AC-3b①: fragments_log.pyが非0で終了 → last-run.jsonは1バイトも変わらずexit 1・stderrに理由1行 ==="
{
  setup_case "$WORK_ROOT/t2"
  echo '{"last_success_at": "2026-09-01T00:00:00Z"}' > "$LAST_RUN_FILE"
  BEFORE="$(sha_of "$LAST_RUN_FILE")"
  FAKE_FRAGMENTS_LOG_EXIT=1 run_cli
  rc=$?
  AFTER="$(sha_of "$LAST_RUN_FILE")"
  assert_eq "exit 1" "1" "$rc"
  assert_unchanged "last-run.jsonは不変" "$BEFORE" "$AFTER"
  assert_contains "stderrに理由が1行出る" "$(cat "$ERR")" "fragments_log.py"
}

echo "=== 3. AC-3b②: fragments_log.pyがtimeout → last-run.jsonは1バイトも変わらずexit 1・stderrに理由1行 ==="
{
  setup_case "$WORK_ROOT/t3"
  echo '{"last_success_at": "2026-09-01T00:00:00Z"}' > "$LAST_RUN_FILE"
  BEFORE="$(sha_of "$LAST_RUN_FILE")"
  TIMEOUT_FRAGMENTS_LOG=1 FAKE_FRAGMENTS_LOG_SLEEP=5 run_cli
  rc=$?
  AFTER="$(sha_of "$LAST_RUN_FILE")"
  assert_eq "exit 1" "1" "$rc"
  assert_unchanged "last-run.jsonは不変" "$BEFORE" "$AFTER"
  assert_contains "stderrにtimeoutの理由が出る" "$(cat "$ERR")" "timeout"
}

echo "=== 4. AC-3b③: fragments_log.pyの出力が壊れたJSON(exit 0) → last-run.jsonは1バイトも変わらずexit 2・stderrに理由1行 ==="
{
  setup_case "$WORK_ROOT/t4"
  echo '{"last_success_at": "2026-09-01T00:00:00Z"}' > "$LAST_RUN_FILE"
  BEFORE="$(sha_of "$LAST_RUN_FILE")"
  FAKE_FRAGMENTS_LOG_JSON='not valid json{{{' run_cli
  rc=$?
  AFTER="$(sha_of "$LAST_RUN_FILE")"
  assert_eq "exit 2" "2" "$rc"
  assert_unchanged "last-run.jsonは不変" "$BEFORE" "$AFTER"
  assert_contains "stderrに契約違反の理由が出る" "$(cat "$ERR")" "契約に違反"
}

echo "=== 5. AC-3b④: fragments_log.pyの出力にキー欠落(scan_error_count無し・契約違反) → last-run.jsonは1バイトも変わらずexit 2 ==="
{
  setup_case "$WORK_ROOT/t5"
  echo '{"last_success_at": "2026-09-01T00:00:00Z"}' > "$LAST_RUN_FILE"
  BEFORE="$(sha_of "$LAST_RUN_FILE")"
  FAKE_FRAGMENTS_LOG_JSON='{"fragments": [], "truncated": []}' run_cli
  rc=$?
  AFTER="$(sha_of "$LAST_RUN_FILE")"
  assert_eq "exit 2" "2" "$rc"
  assert_unchanged "last-run.jsonは不変" "$BEFORE" "$AFTER"
}

echo "=== 6. AC-3c①: last-run.jsonが無い → {}から作る(fail-open)・3キーが書かれる ==="
{
  setup_case "$WORK_ROOT/t6"
  rm -f "$LAST_RUN_FILE"
  FAKE_FRAGMENTS_LOG_JSON='{"scan_error_count": 0, "fragments": [{"title": "a"}], "truncated": []}' run_cli
  rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_file_exists "last-run.jsonが新規に作られる" "$LAST_RUN_FILE"
  assert_eq "fragments_candidates=1が記録される" "1" "$(jq -r '.fragments_candidates' "$LAST_RUN_FILE")"
}

echo "=== 7. AC-3c②: last-run.jsonが壊れている(不正JSON) → {}から作り直す(fail-open) ==="
{
  setup_case "$WORK_ROOT/t7"
  echo 'not json{{{' > "$LAST_RUN_FILE"
  run_cli
  rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "壊れた内容は捨てられfragments_sinceだけが残る" "$TODAY" "$(jq -r '.fragments_since' "$LAST_RUN_FILE")"
}

echo "=== 8. AC-4: --dry-runは何も書かず、書く予定の3値を表示してexit 0 ==="
{
  setup_case "$WORK_ROOT/t8"
  echo '{"last_success_at": "2026-09-01T00:00:00Z"}' > "$LAST_RUN_FILE"
  BEFORE="$(sha_of "$LAST_RUN_FILE")"
  FAKE_FRAGMENTS_LOG_JSON='{"scan_error_count": 0, "fragments": [{"title": "a"}, {"title": "b"}], "truncated": []}' \
    run_cli --dry-run
  rc=$?
  AFTER="$(sha_of "$LAST_RUN_FILE")"
  assert_eq "exit 0" "0" "$rc"
  assert_unchanged "dry-run前後でlast-run.jsonのsha256が一致する" "$BEFORE" "$AFTER"
  assert_contains "dry-run出力にfragments_reviewed_atが出る" "$(cat "$OUT")" "fragments_reviewed_at="
  assert_contains "dry-run出力にfragments_candidates=2が出る" "$(cat "$OUT")" "fragments_candidates=2"
  assert_contains "dry-run出力にfragments_since=今日が出る" "$(cat "$OUT")" "fragments_since=${TODAY}"
}

echo "=== 9. -h/--help: usageを表示してexit 0・何も書かない ==="
{
  setup_case "$WORK_ROOT/t9"
  rm -f "$LAST_RUN_FILE"
  bash "$SCRIPT" -h > "$OUT" 2> "$ERR"
  rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_contains "usageに使い方が出る" "$(cat "$OUT")" "fragments-reviewed.sh"
  assert_file_not_exists "last-run.jsonは作られない" "$LAST_RUN_FILE"
}

echo "=== 10. 不明な引数はusageをstderrへ出しexit 2で終わる ==="
{
  setup_case "$WORK_ROOT/t10"
  bash "$SCRIPT" --bogus > "$OUT" 2> "$ERR"
  rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_contains "stderrにusageが出る" "$(cat "$ERR")" "usage"
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
