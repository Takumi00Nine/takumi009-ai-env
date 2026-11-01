#!/usr/bin/env bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/fragments-reviewed.sh"

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

setup_fake_fragments_log() {
  local path="$1"
  cat > "$path" <<'PYEOF'
#!/usr/bin/env python3
import os, sys
default_json = '{"scan_error_count": 0, "fragments": [], "truncated": []}'
print(os.environ.get("FAKE_FRAGMENTS_LOG_JSON", default_json))
sys.exit(int(os.environ.get("FAKE_FRAGMENTS_LOG_EXIT", "0")))
PYEOF
  chmod +x "$path"
}

setup_case() {
  local t="$1"
  mkdir -p "$t"
  FAKE_LOG_PY="$t/fake_fragments_log.py"
  LAST_RUN_FILE="$t/last-run.json"
  OUT="$t/stdout.log"
  ERR="$t/stderr.log"
  setup_fake_fragments_log "$FAKE_LOG_PY"
}

run_cli() {
  LAST_RUN_FILE="$LAST_RUN_FILE" FRAGMENTS_LOG_PY="$FAKE_LOG_PY" \
    TIMEOUT_FRAGMENTS_LOG="${TIMEOUT_FRAGMENTS_LOG:-5}" \
    bash "$SCRIPT" "$@" > "$OUT" 2> "$ERR"
}

TODAY="$(date -u +%Y-%m-%d)"

echo "=== 3キーを書き、既存情報を保持する ==="
{
  setup_case "$WORK_ROOT/t1"
  echo '{"last_success_at": "2026-09-01T00:00:00Z", "last_result": "success"}' > "$LAST_RUN_FILE"
  FAKE_FRAGMENTS_LOG_JSON='{"scan_error_count": 0, "fragments": [{"title": "a"}, {"title": "b"}], "truncated": [{"title": "c"}]}' \
    run_cli
  rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "3キーを記録し既存キーを保持する" "true" "$(jq -r --arg today "$TODAY" '
    .fragments_candidates == 2 and .fragments_since == $today
    and (.fragments_reviewed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .last_success_at == "2026-09-01T00:00:00Z" and .last_result == "success"
  ' "$LAST_RUN_FILE")"

}

echo "=== 検出器失敗時は記録を1バイトも変えない ==="
{
  setup_case "$WORK_ROOT/t2"
  echo '{"last_success_at": "2026-09-01T00:00:00Z"}' > "$LAST_RUN_FILE"
  BEFORE="$(sha_of "$LAST_RUN_FILE")"
  FAKE_FRAGMENTS_LOG_EXIT=1 run_cli
  rc=$?
  AFTER="$(sha_of "$LAST_RUN_FILE")"
  assert_eq "exit 1" "1" "$rc"
  assert_unchanged "last-run.jsonは不変" "$BEFORE" "$AFTER"
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
