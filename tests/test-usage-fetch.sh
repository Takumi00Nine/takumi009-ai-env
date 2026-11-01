#!/usr/bin/env bash
# curl/security/codex を偽物にし、取得結果・失敗日時の保持・429 no-op を確認する。

set -uo pipefail
set -a

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
ENTRY="$REPO_ROOT/usage/executor/usage-fetch.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}

FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${STUB_CURL_BODY:-}"
printf '\n%s' "${STUB_CURL_STATUS:-200}"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${STUB_SECURITY_JSON:-}"
exit 0
EOF
chmod +x "$FAKE_BIN/security"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" != "app-server" ]; then
  exit 1
fi
while IFS= read -r line; do
  id="$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)"
  if [ "$id" = "2" ]; then
    printf '%s\n' "${STUB_CODEX_RESULT_LINE:-}"
  fi
done
EOF
chmod +x "$FAKE_BIN/codex"

PATH="$FAKE_BIN:$PATH"
hash -r

new_env() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home" "$d/cache" "$d/config"
  echo "$d"
}

load_entry_for() {
  local envdir="$1"
  export HOME="$envdir/home" XDG_CACHE_HOME="$envdir/cache" XDG_CONFIG_HOME="$envdir/config"
  AIENV_USAGE_FETCH_TEST_LIB=1 . "$ENTRY"
  REQUEST_TIMEOUT=5
  RETRY_COUNT=0
  CACHE_DIR="$envdir/cache/claude-codex-usage"
  CONFIG_DIR="$envdir/config/claude-codex-usage"
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  CODEX_CACHE="$CACHE_DIR/codex-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
}

reset_stubs() {
  unset STUB_CURL_STATUS STUB_CURL_BODY
  unset STUB_SECURITY_JSON
  unset STUB_CODEX_RESULT_LINE
}

valid_claude_token() {
  STUB_SECURITY_JSON='{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":99999999999999}}'
}

claude_success_body() {
  cat <<'JSON'
{
  "five_hour": {"used_percent": 42, "resets_at": "2026-09-09T00:00:00Z"},
  "seven_day": {"used_percent": 13, "resets_at": "2026-09-14T00:00:00Z"},
  "limits": [
    {"kind": "weekly_scoped", "is_active": true, "percent": 7, "resets_at": "2026-09-15T00:00:00Z",
     "scope": {"model": {"display_name": "Fable"}}}
  ]
}
JSON
}

codex_success_result_line() {
  cat <<'JSON'
{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}}}}
JSON
}

sha256_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

echo "=== サービスごとに応答をキャッシュへ変換する ==="
for svc in claude codex; do
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  if [ "$svc" = claude ]; then
    valid_claude_token; STUB_CURL_BODY="$(claude_success_body)"
    cache="$CLAUDE_CACHE"
    expected_five=42; expected_seven=13
  else
    STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
    cache="$CODEX_CACHE"
    expected_five=55; expected_seven=22
  fi
  refresh_service "$svc"
  rc=$?
  if [ "$rc" -eq 0 ] && jq -e --argjson five "$expected_five" --argjson seven "$expected_seven" '.last_error == null and (.fetched_at | type == "number") and .five_hour.used_percent == $five and .seven_day.used_percent == $seven' "$cache" >/dev/null; then
    pass "$svc の応答を共通キャッシュ形へ変換"
  else fail_case "$svc の応答を共通キャッシュ形へ変換"; fi
  before="$(jq -r '.fetched_at' "$cache")"
  sleep 1.1
  if [ "$svc" = claude ]; then
    STUB_CURL_STATUS=500; STUB_CURL_BODY='{}'
  else
    STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":"invalid"}}}}'
  fi
  refresh_service "$svc" >/dev/null
  if [ "$(jq -r '.fetched_at' "$cache")" = "$before" ] && jq -e '.last_error != null' "$cache" >/dev/null; then
    pass "$svc の失敗では取得日時を進めずエラーを記録"
  else fail_case "$svc の失敗では取得日時を進めずエラーを記録"; fi
  rm -rf "$E"
done

echo "=== HTTP 429 はキャッシュを変更しない ==="
E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
STUB_CURL_BODY="$(claude_success_body)"
refresh_service claude >/dev/null
before="$(sha256_of "$CLAUDE_CACHE")"
STUB_CURL_STATUS=429; STUB_CURL_BODY='{}'
refresh_service claude >/dev/null
assert_eq "429 は完全な no-op" "$before" "$(sha256_of "$CLAUDE_CACHE")"
rm -rf "$E"

echo "結果: PASS=$PASS FAIL=$FAIL"
echo "======================================================================"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
