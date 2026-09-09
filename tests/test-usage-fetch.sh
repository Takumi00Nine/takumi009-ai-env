#!/usr/bin/env bash
# scripts/usage-fetch.sh・scripts/lib/usage-source.sh・scripts/lib/usage-notify.sh
# のユニットテスト（B1-b・使用率取得器移設。AC-97＝23 fixture のうち B1-b が
# 実行する19件のうち18件＋AC の枠外4件。⑦の1件はB1-a未マージのため未実施）。
#
# 対応表（要件＝ローカルLLM段階経路-要件-2026-09-03.md v20 AC-97）:
#   ①応答からの値の抽出 2 ／②必須欠落・型不正・401・500 8
#   （型不正はD-15の3変異を1fixtureで注入するパラメタ化1件×2サービス）
#   ③成功時のみfetched_atが進む 2 ／⑤429は完全no-op 4 ／⑥原子的書き出し 2
#   ＝計18件実行。④（ゲート統合2件）はB2。⑦（読み手の非通信3件）のうち
#   check-usage-gate・監視の2件はB2、usage-snapshot 1件はB1-a
#   （claude/hooks/lib/usage_snapshot.py・worktree feature/usage-snapshot）が
#   本ブランチに未マージのため「未実施」として明示スキップする
#   （設計書§4「担当Cの前提」・リーダー指示）。
#   AC の枠外4件＝F-9b・F-9c・D-15窓の定義・F-3（設計書§6.1）。
#
# ⚠️ refresh_service() の戻り値契約（scripts/usage-fetch.sh 冒頭コメント参照）＝
# 0＝キャッシュへ結果を記録できた（成功・失敗記録のどちらも含む）／
# 1＝記録そのものが書けなかった（書き込み障害）。AC-97②の受入条件は
# 「fetched_atが不変・last_errorが非null」であって戻り値ではないため、本テストは
# 戻り値ではなくキャッシュの中身で判定する。
#
# 実 launchd・実ネットワーク・実キーチェーンには一切触れない。curl・security・
# codex を PATH スタブへ差し替え、HOME・XDG_CACHE_HOME・XDG_CONFIG_HOME を
# 都度fixtureディレクトリへ差し替える。scripts/usage-fetch.sh を
# AIENV_USAGE_FETCH_TEST_LIB=1 で source し、refresh_service()等を直接呼ぶ。
#
# 実行方法: bash tests/test-usage-fetch.sh

set -uo pipefail
set -a

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
ENTRY="$REPO_ROOT/scripts/usage-fetch.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}

# --- スタブ bin（set -a のため、以後このファイル内で代入する変数は
#     すべて自動exportされ、外部のスタブスクリプト（別プロセス）から見える）---
FAKE_BIN="$(mktemp -d)"
STUB_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN" "$FAKE_BIN_NO_CODEX" "$STUB_STATE_DIR"' EXIT

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_CURL_EXIT:-}" ] && [ "${STUB_CURL_EXIT}" != "0" ]; then
  exit "$STUB_CURL_EXIT"
fi
if [ -n "${STUB_CURL_BODY_FILE:-}" ] && [ -f "$STUB_CURL_BODY_FILE" ]; then
  cat "$STUB_CURL_BODY_FILE"
else
  printf '%s' "${STUB_CURL_BODY:-}"
fi
printf '\n%s' "${STUB_CURL_STATUS:-200}"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_SECURITY_MISSING:-0}" = "1" ]; then
  exit 44
fi
printf '%s' "${STUB_SECURITY_JSON:-}"
exit 0
EOF
chmod +x "$FAKE_BIN/security"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" != "app-server" ]; then
  exit 1
fi
if [ "${STUB_CODEX_TIMEOUT:-0}" = "1" ]; then
  while true; do sleep 1; done
fi
while IFS= read -r line; do
  id="$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)"
  if [ "$id" = "2" ]; then
    printf '%s\n' "${STUB_CODEX_RESULT_LINE:-}"
  fi
done
EOF
chmod +x "$FAKE_BIN/codex"

# F-3用の別スタブディレクトリ（curl・securityだけを持ち、codexは意図的に
# 置かない）。$FAKE_BIN自体はcodexスタブを持つため、「PATHからcodexを含む
# ディレクトリを除く」フィルタにかけると$FAKE_BINごと除外されてcurl・security
# スタブまで失ってしまう（実測で判明したバグ）。F-3のNO_CODEX_PATH構築は
# このディレクトリを明示的に含める。
FAKE_BIN_NO_CODEX="$(mktemp -d)"
cp "$FAKE_BIN/curl" "$FAKE_BIN_NO_CODEX/curl"
cp "$FAKE_BIN/security" "$FAKE_BIN_NO_CODEX/security"

PATH="$FAKE_BIN:$PATH"
hash -r

# --- fixture 環境の生成・破棄 ---
new_env() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home" "$d/cache" "$d/config"
  echo "$d"
}

# usage-fetch.sh を AIENV_USAGE_FETCH_TEST_LIB=1 でsourceして load_config() 済み
# の関数群を使えるようにする。$1=env dir
load_entry_for() {
  local envdir="$1"
  HOME="$envdir/home" XDG_CACHE_HOME="$envdir/cache" XDG_CONFIG_HOME="$envdir/config" \
    AIENV_USAGE_FETCH_TEST_LIB=1 . "$ENTRY"
  CACHE_DIR="$envdir/cache/claude-codex-usage"
  CONFIG_DIR="$envdir/config/claude-codex-usage"
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  CODEX_CACHE="$CACHE_DIR/codex-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
}

reset_stubs() {
  unset STUB_CURL_EXIT STUB_CURL_STATUS STUB_CURL_BODY STUB_CURL_BODY_FILE
  unset STUB_SECURITY_MISSING STUB_SECURITY_JSON
  unset STUB_CODEX_TIMEOUT STUB_CODEX_RESULT_LINE
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

# codexを含まないPATHを組み立てる（$FAKE_BIN_NO_CODEXを先頭に、既存PATHから
# codexという実行可能ファイルを含むディレクトリ（$FAKE_BIN自身を含む）だけを
# 除いて連結する）。
no_codex_path() {
  local out="$FAKE_BIN_NO_CODEX" d
  local IFS_saved="$IFS"
  IFS=':' read -ra _path_dirs <<< "$PATH"
  IFS="$IFS_saved"
  for d in "${_path_dirs[@]}"; do
    [ -n "$d" ] || continue
    [ -x "$d/codex" ] && continue
    out="${out}:${d}"
  done
  printf '%s' "$out"
}

echo "=== ①応答からの値の抽出（claude・codex 各1） ==="
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CURL_STATUS=200
  STUB_CURL_BODY="$(claude_success_body)"
  refresh_service claude
  rc=$?
  assert_eq "claude: 成功でrefresh_serviceは0" "0" "$rc"
  assert_eq "claude: five_hour.used_percent" "42" "$(jq -r '.five_hour.used_percent' "$CLAUDE_CACHE")"
  assert_eq "claude: seven_day.used_percent" "13" "$(jq -r '.seven_day.used_percent' "$CLAUDE_CACHE")"
  assert_eq "claude: model_weekly.used_percent" "7" "$(jq -r '.model_weekly.used_percent' "$CLAUDE_CACHE")"
  assert_eq "claude: model_weekly.label" "Fable" "$(jq -r '.model_weekly.label' "$CLAUDE_CACHE")"
  assert_eq "claude: last_error はnull" "null" "$(jq -r '.last_error' "$CLAUDE_CACHE")"
  rm -rf "$E"
}
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex
  rc=$?
  assert_eq "codex: 成功でrefresh_serviceは0" "0" "$rc"
  assert_eq "codex: five_hour.used_percent" "55" "$(jq -r '.five_hour.used_percent' "$CODEX_CACHE")"
  assert_eq "codex: seven_day.used_percent" "22" "$(jq -r '.seven_day.used_percent' "$CODEX_CACHE")"
  assert_eq "codex: last_error はnull" "null" "$(jq -r '.last_error' "$CODEX_CACHE")"
  rm -rf "$E"
}

echo "=== ②必須欠落・型不正・401・500（claude・codex 各4＝計8） ==="
# claude: baseline成功 -> 各失敗を注入し、fetched_atが不変・last_errorが非nullであることを確かめる
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CURL_STATUS=200
  STUB_CURL_BODY="$(claude_success_body)"
  refresh_service claude >/dev/null
  baseline_fetched_at="$(jq -r '.fetched_at' "$CLAUDE_CACHE")"

  # 必須欠落（seven_dayが丸ごと無い）
  STUB_CURL_STATUS=200
  STUB_CURL_BODY='{"five_hour":{"used_percent":10,"resets_at":"2026-09-09T00:00:00Z"}}'
  refresh_service claude >/dev/null
  assert_eq "claude 必須欠落: fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
  assert_true "claude 必須欠落: last_errorが非null" "$([ "$(jq -r '.last_error' "$CLAUDE_CACHE")" != "null" ] && echo 1 || echo 0)"

  # HTTP 401
  STUB_CURL_STATUS=401
  STUB_CURL_BODY='{}'
  refresh_service claude >/dev/null
  assert_eq "claude 401: fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
  assert_eq "claude 401: last_error.status=401" "401" "$(jq -r '.last_error.status' "$CLAUDE_CACHE")"

  # HTTP 500
  STUB_CURL_STATUS=500
  STUB_CURL_BODY='{}'
  refresh_service claude >/dev/null
  assert_eq "claude 500: fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
  assert_eq "claude 500: last_error.status=500" "500" "$(jq -r '.last_error.status' "$CLAUDE_CACHE")"
  rm -rf "$E"
}
# claude: 型不正（D-15の3変異をパラメタ化・validate_usage_payloadを直接検査）
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  base='{"schema_version":1,"service":"claude","fetched_at":1000,"updated_at":1000,"five_hour":{"used_percent":10,"resets_at":null,"resets_at_epoch":2000},"seven_day":{"used_percent":20,"resets_at":null,"resets_at_epoch":3000},"model_weekly":{"used_percent":null,"resets_at":null,"resets_at_epoch":null,"label":null},"last_error":null}'
  assert_true "claude 型不正 baseline: 有効な応答は受理される" \
    "$(validate_usage_payload claude "$base" && echo 1 || echo 0)"
  v1="$(printf '%s' "$base" | jq -c '.five_hour.used_percent = true')"
  assert_true "claude 型不正(i) used_percentが真偽値なら拒否" \
    "$(validate_usage_payload claude "$v1" && echo 0 || echo 1)"
  v2="$(printf '%s' "$base" | jq -c '.five_hour.resets_at_epoch = null')"
  assert_true "claude 型不正(ii) 存在する窓のresets_at_epochがnullなら拒否（D-15の検出力の本体）" \
    "$(validate_usage_payload claude "$v2" && echo 0 || echo 1)"
  v3="$(printf '%s' "$base" | jq -c '.fetched_at = 1.5')"
  assert_true "claude 型不正(iii) fetched_atが非整数なら拒否" \
    "$(validate_usage_payload claude "$v3" && echo 0 || echo 1)"
  rm -rf "$E"
}
# codex: baseline成功 -> 必須欠落（両窓とも無し）・timeout（旧無言no-op対象・D-3で失敗化）・
#        parse_error（壊れた応答）の3通り＋型不正（直接検査）で4通り
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  baseline_fetched_at="$(jq -r '.fetched_at' "$CODEX_CACHE")"

  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{}}}'
  refresh_service codex >/dev/null
  assert_eq "codex 必須欠落(両窓無し): fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CODEX_CACHE")"
  assert_true "codex 必須欠落: last_errorが非null" "$([ "$(jq -r '.last_error' "$CODEX_CACHE")" != "null" ] && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  baseline_fetched_at="$(jq -r '.fetched_at' "$CODEX_CACHE")"

  STUB_CODEX_TIMEOUT=1
  REQUEST_TIMEOUT=1
  refresh_service codex >/dev/null
  assert_eq "codex timeout(旧無言no-opの対象・D-3で失敗化): fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CODEX_CACHE")"
  assert_eq "codex timeout: last_error.type=timeout" "timeout" "$(jq -r '.last_error.type' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  # 4通り目＝codexコマンド不在（F-3）。⚠️ codexの取得層（app-server経由の
  # JSON-RPC）には「構文的に壊れた応答」に対応する固有のfetch_status（HTTP層
  # で言う401/500相当）が実在しない（実測＝抽出用jqが失敗すると単に
  # timeout(124)へ収束する）ため、この4件目には「必須欠落・型不正・timeout」
  # とは異なる、codex固有の実在する失敗モードを充てる。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  baseline_fetched_at="$(jq -r '.fetched_at' "$CODEX_CACHE")"

  ( PATH="$(no_codex_path)"; refresh_service codex >/dev/null )
  assert_eq "codex コマンド不在(F-3): fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CODEX_CACHE")"
  assert_true "codex コマンド不在(F-3): last_errorにcodexへの言及がある" \
    "$(jq -r '.last_error.message' "$CODEX_CACHE" | grep -q "codex" && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  base='{"schema_version":1,"service":"codex","fetched_at":1000,"updated_at":1000,"five_hour":{"used_percent":10,"resets_at_epoch":2000},"seven_day":{"used_percent":20,"resets_at_epoch":3000},"last_error":null}'
  assert_true "codex 型不正 baseline: 有効な応答は受理される" \
    "$(validate_usage_payload codex "$base" && echo 1 || echo 0)"
  v1="$(printf '%s' "$base" | jq -c '.five_hour.used_percent = true')"
  assert_true "codex 型不正(i) used_percentが真偽値なら拒否" \
    "$(validate_usage_payload codex "$v1" && echo 0 || echo 1)"
  v2="$(printf '%s' "$base" | jq -c '.five_hour.resets_at_epoch = null')"
  assert_true "codex 型不正(ii) 存在する窓のresets_at_epochがnullなら拒否" \
    "$(validate_usage_payload codex "$v2" && echo 0 || echo 1)"
  v3="$(printf '%s' "$base" | jq -c '.fetched_at = 1.5')"
  assert_true "codex 型不正(iii) fetched_atが非整数なら拒否" \
    "$(validate_usage_payload codex "$v3" && echo 0 || echo 1)"
  rm -rf "$E"
}

echo "=== ③成功したときだけfetched_atが進む（claude・codex 各1） ==="
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CURL_STATUS=200
  STUB_CURL_BODY="$(claude_success_body)"
  refresh_service claude >/dev/null
  first_fetched_at="$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
  sleep 1.1
  refresh_service claude >/dev/null
  second_fetched_at="$(jq -r '.fetched_at' "$CLAUDE_CACHE")"
  assert_true "claude: 2回連続成功でfetched_atが進む" "$([ "$second_fetched_at" -gt "$first_fetched_at" ] && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  first_fetched_at="$(jq -r '.fetched_at' "$CODEX_CACHE")"
  sleep 1.1
  refresh_service codex >/dev/null
  second_fetched_at="$(jq -r '.fetched_at' "$CODEX_CACHE")"
  assert_true "codex: 2回連続成功でfetched_atが進む" "$([ "$second_fetched_at" -gt "$first_fetched_at" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== ⑤429は完全なno-op（claude・codex×直前正常/直前失敗＝計4） ==="
# claude は実際のHTTP 429応答で検証する。codex の取得層（app-server経由の
# JSON-RPC）にはHTTPステータスに相当する信号が無い（fetch_codex_onceは
# 429を返さない＝現物からの構造的事実）ため、429/失敗/成功の評価順を担う
# refresh_service側の共通分岐（サービス名に依存しない）を、retry_fetchを
# サブシェル内で一時的に上書きして fetch_status=42 を強制注入する形で検証する
# （どちらのサービスでも同じ共通コードパスが429を1バイトも書かないことを
# 確かめるのが目的であり、codex固有のwireプロトコルを捏造しない）。
for svc in claude codex; do
  cache_var="CLAUDE_CACHE"; [ "$svc" = "codex" ] && cache_var="CODEX_CACHE"

  # (a) 直前が正常
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  cache_path="${!cache_var}"
  if [ "$svc" = "claude" ]; then
    valid_claude_token
    STUB_CURL_STATUS=200
    STUB_CURL_BODY="$(claude_success_body)"
    refresh_service claude >/dev/null
  else
    STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
    refresh_service codex >/dev/null
  fi
  before_hash="$(sha256_of "$cache_path")"
  if [ "$svc" = "claude" ]; then
    reset_stubs; valid_claude_token
    STUB_CURL_STATUS=429
    STUB_CURL_BODY='{}'
    refresh_service claude >/dev/null
  else
    ( retry_fetch() { return 42; }; refresh_service codex >/dev/null )
  fi
  after_hash="$(sha256_of "$cache_path")"
  assert_eq "$svc 429(直前正常): SHA-256不変" "$before_hash" "$after_hash"
  rm -rf "$E"

  # (b) 直前が失敗
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  cache_path="${!cache_var}"
  if [ "$svc" = "claude" ]; then
    valid_claude_token
    STUB_CURL_STATUS=500
    STUB_CURL_BODY='{}'
    refresh_service claude >/dev/null
  else
    STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{}}}'
    refresh_service codex >/dev/null
  fi
  before_hash="$(sha256_of "$cache_path")"
  before_last_error="$(jq -c '.last_error' "$cache_path")"
  if [ "$svc" = "claude" ]; then
    reset_stubs; valid_claude_token
    STUB_CURL_STATUS=429
    STUB_CURL_BODY='{}'
    refresh_service claude >/dev/null
  else
    ( retry_fetch() { return 42; }; refresh_service codex >/dev/null )
  fi
  after_hash="$(sha256_of "$cache_path")"
  after_last_error="$(jq -c '.last_error' "$cache_path")"
  assert_eq "$svc 429(直前失敗): SHA-256不変" "$before_hash" "$after_hash"
  assert_eq "$svc 429(直前失敗): last_errorは429で上書きされない" "$before_last_error" "$after_last_error"
  rm -rf "$E"
done

echo "=== ⑥原子的な書き出し（決定的＋確率的＝計2） ==="
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  mkdir -p "$CACHE_DIR"
  echo '{"schema_version":1,"service":"claude","prior":true}' > "$CLAUDE_CACHE"
  before="$(cat "$CLAUDE_CACHE")"
  cat > "$FAKE_BIN/mv" <<EOF
#!/usr/bin/env bash
if [ -n "\${STUB_MV_FAIL_ONCE:-}" ] && [ -f "\${STUB_MV_FAIL_ONCE}" ]; then
  rm -f "\${STUB_MV_FAIL_ONCE}"
  exit 1
fi
exec /bin/mv "\$@"
EOF
  chmod +x "$FAKE_BIN/mv"
  hash -r
  STUB_MV_FAIL_ONCE="$STUB_STATE_DIR/mv-fail-flag-1"
  : > "$STUB_MV_FAIL_ONCE"
  atomic_write "$CLAUDE_CACHE" '{"schema_version":1,"service":"claude","new":true}'
  rc=$?
  after="$(cat "$CLAUDE_CACHE")"
  assert_true "⑥決定的: mv失敗でatomic_writeは非0" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "⑥決定的: mv失敗時は正規パスが1バイトも変わらない" "$before" "$after"
  rm -f "$FAKE_BIN/mv"; hash -r
  rm -rf "$E"
}
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  mkdir -p "$CACHE_DIR"
  echo '{"schema_version":1,"service":"claude","prior":true}' > "$CLAUDE_CACHE"
  ok=1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash -c "
      HOME='$E/home' XDG_CACHE_HOME='$E/cache' XDG_CONFIG_HOME='$E/config' AIENV_USAGE_FETCH_TEST_LIB=1 . '$ENTRY'
      atomic_write '$CLAUDE_CACHE' '{\"schema_version\":1,\"service\":\"claude\",\"iter\":$i}'
    " &
    child=$!
    sleep 0.0$((RANDOM % 5 + 1))
    kill -9 "$child" 2>/dev/null
    wait "$child" 2>/dev/null
    if ! jq -e '.schema_version == 1 and .service == "claude"' "$CLAUDE_CACHE" >/dev/null 2>&1; then
      ok=0
    fi
  done
  assert_true "⑥確率的: 10回のSIGKILL試行後も正規パスは常にschema_version/service揃いで読める" "$ok"
  rm -rf "$E"
}

echo "=== AC の枠外（fixture総数23には数えない）4件 ==="
{
  # (1) F-9b: 失敗の記録（write_failure_cache）自体が書けなかったらrefresh_service
  # が非0でログに1行残る（atomic_writeを常に失敗させ、そもそも書き込み障害が
  # あるディスクを模す）
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CURL_STATUS=500
  STUB_CURL_BODY='{}'
  mkdir -p "$(dirname "$CLAUDE_CACHE")"
  cat > "$FAKE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$FAKE_BIN/mv"; hash -r
  out="$(refresh_service claude 2>&1)"
  rc=$?
  assert_true "F-9b: 失敗記録の書き込み自体が失敗したらrefresh_serviceは非0" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "F-9b: ログに1行残る" "$(printf '%s' "$out" | grep -q "failed to write failure cache" && echo 1 || echo 0)"
  rm -f "$FAKE_BIN/mv"; hash -r
  rm -rf "$E"
}
{
  # (2) F-9c: all で claude 側の「成功したのに書き出せない」(F-9a) が起きても、
  # codex の取得は必ず実行され、終了コードは集約される（片方の書き込み障害で
  # もう片方の使用率まで古くならないことの確認）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CURL_STATUS=200
  STUB_CURL_BODY="$(claude_success_body)"
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  cat > "$FAKE_BIN/mv" <<EOF
#!/usr/bin/env bash
if [ -n "\${STUB_MV_FAIL_ONCE:-}" ] && [ -f "\${STUB_MV_FAIL_ONCE}" ]; then
  rm -f "\${STUB_MV_FAIL_ONCE}"
  exit 1
fi
exec /bin/mv "\$@"
EOF
  chmod +x "$FAKE_BIN/mv"; hash -r
  STUB_MV_FAIL_ONCE="$STUB_STATE_DIR/mv-fail-flag-f9c"
  : > "$STUB_MV_FAIL_ONCE"
  HOME="$E/home" XDG_CACHE_HOME="$E/cache" XDG_CONFIG_HOME="$E/config" \
    STUB_SECURITY_JSON="$STUB_SECURITY_JSON" STUB_CURL_STATUS="$STUB_CURL_STATUS" STUB_CURL_BODY="$STUB_CURL_BODY" \
    STUB_CODEX_RESULT_LINE="$STUB_CODEX_RESULT_LINE" STUB_MV_FAIL_ONCE="$STUB_MV_FAIL_ONCE" \
    bash "$ENTRY" all
  rc=$?
  assert_true "F-9c: all実行の終了コードは非0（claude側の書き込み障害を集約）" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "F-9c: claude側が書き込み障害でもcodexの取得は実行される" \
    "$([ -f "$CODEX_CACHE" ] && [ "$(jq -r '.five_hour.used_percent' "$CODEX_CACHE")" = "55" ] && echo 1 || echo 0)"
  rm -f "$FAKE_BIN/mv"; hash -r
  rm -rf "$E"
}
{
  # (3) D-15窓の定義: codexの片窓欠落は受理され、片方だけnull（usedはあるがresetsが無い）は失敗になる
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":33,"resetsAt":111}}}}'
  refresh_service codex
  rc=$?
  assert_eq "D-15(3a): codexの片窓欠落(7dが丸ごと無い)は受理される" "0" "$rc"
  assert_eq "D-15(3a): five_hourは値どおり" "33" "$(jq -r '.five_hour.used_percent' "$CODEX_CACHE")"
  assert_eq "D-15(3a): seven_dayはnull（欠落として受理）" "null" "$(jq -r '.seven_day.used_percent' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  base='{"schema_version":1,"service":"codex","fetched_at":1000,"updated_at":1000,"five_hour":{"used_percent":33,"resets_at_epoch":null},"seven_day":{"used_percent":null,"resets_at_epoch":null},"last_error":null}'
  assert_true "D-15(3b): used_percentはあるがresets_at_epochが無い窓は失敗（欠落と壊れの取り違え防止）" \
    "$(validate_usage_payload codex "$base" && echo 0 || echo 1)"
  rm -rf "$E"
}
{
  # (4) F-3: codexコマンドがPATHに無くてもclaudeの取得は行われ、codex側だけ
  # last_errorに記録される（現物はallでcodexが無いだけでどのサービスも
  # 取得せずexit 3していた＝実測）。現在のPATHから「codexという実行可能
  # ファイルを含むディレクトリ」だけを除いた版を作る（bash・jq・curl等の
  # 他コマンドは温存する）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CURL_STATUS=200
  STUB_CURL_BODY="$(claude_success_body)"
  HOME="$E/home" XDG_CACHE_HOME="$E/cache" XDG_CONFIG_HOME="$E/config" \
    STUB_SECURITY_JSON="$STUB_SECURITY_JSON" STUB_CURL_STATUS="$STUB_CURL_STATUS" STUB_CURL_BODY="$STUB_CURL_BODY" \
    PATH="$(no_codex_path)" bash "$ENTRY" all
  assert_true "F-3: codex不在でもall実行は完走し、claudeは成功する" \
    "$([ "$(jq -r '.five_hour.used_percent' "$CLAUDE_CACHE" 2>/dev/null)" = "42" ] && echo 1 || echo 0)"
  assert_true "F-3: codex側はlast_errorに missing required command: codex を記録" \
    "$(jq -r '.last_error.message' "$CODEX_CACHE" 2>/dev/null | grep -q "codex" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== ⑦読み手の非通信（usage-snapshot・B1-aがmainへ入ったため実施。check-usage-gate・監視の2件はB2） ==="
if [ ! -f "$REPO_ROOT/claude/hooks/lib/usage_snapshot.py" ]; then
  echo "  未実施 - ⑦usage-snapshot: claude/hooks/lib/usage_snapshot.py が本ブランチに無い（B1-a=feature/usage-snapshot 未マージ）。設計書§4の指示どおりスキップ。"
else
  E="$(new_env)"
  mkdir -p "$E/cache"
  now_epoch="$(date -u +%s)"
  cat > "$E/cache/claude-cache.json" <<EOF
{"schema_version":1,"service":"claude","fetched_at":$now_epoch,"updated_at":$now_epoch,"five_hour":{"used_percent":10,"resets_at":"2026-09-09T00:00:00Z","resets_at_epoch":1788912000},"seven_day":{"used_percent":20,"resets_at":"2026-09-14T00:00:00Z","resets_at_epoch":1789344000},"model_weekly":{"used_percent":null,"resets_at":null,"resets_at_epoch":null,"label":null},"last_error":null}
EOF
  cat > "$E/cache/codex-cache.json" <<EOF
{"schema_version":1,"service":"codex","fetched_at":$now_epoch,"updated_at":$now_epoch,"five_hour":{"used_percent":30,"resets_at_epoch":1788912000},"seven_day":{"used_percent":40,"resets_at_epoch":1789344000},"last_error":null}
EOF
  # curl・security・codexが1回でも呼ばれたら痕跡が残るよう、呼び出しを記録
  # したうえで失敗するだけの専用スタブ（$FAKE_BINとは別の隔離ディレクトリ。
  # 既存の$FAKE_BINの中身は変更しない＝他のテストへの影響はゼロ）を用意する。
  # ⚠️ sedでの行挿入はBSD sed（macOS既定）では`Ni text`の1行形式を受け付け
  # ないため使わない（実測で判明。`Ni\`+改行+textの2行形式が必要）。
  CALL_LOG="$E/call.log"
  LOGGING_BIN="$(mktemp -d)"
  for bin in curl security codex; do
    cat > "$LOGGING_BIN/$bin" <<EOF
#!/usr/bin/env bash
echo "$bin \$@" >> "$CALL_LOG"
exit 1
EOF
    chmod +x "$LOGGING_BIN/$bin"
  done

  out="$(PATH="$LOGGING_BIN:$PATH" python3 "$REPO_ROOT/claude/hooks/lib/usage_snapshot.py" --cache-dir "$E/cache" --now "$now_epoch")"
  rc=$?
  assert_eq "usage-snapshot: exit 0" "0" "$rc"
  assert_true "usage-snapshot: 出力が3行ある（枠3件）" "$([ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3" ] && echo 1 || echo 0)"
  assert_true "usage-snapshot: curl/security/codexのいずれも一度も呼ばれていない（外向き通信ゼロ）" \
    "$([ ! -s "$CALL_LOG" ] && echo 1 || echo 0)"

  out_json="$(PATH="$LOGGING_BIN:$PATH" python3 "$REPO_ROOT/claude/hooks/lib/usage_snapshot.py" --json --cache-dir "$E/cache" --now "$now_epoch")"
  assert_true "usage-snapshot --json: curl/security/codexのいずれも一度も呼ばれていない" \
    "$([ ! -s "$CALL_LOG" ] && echo 1 || echo 0)"
  assert_true "usage-snapshot --json: 非秘密JSON1行が出る（poolsを含む）" \
    "$(printf '%s' "$out_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "pools" in d and len(d["pools"])==3 else 1)' 2>/dev/null && echo 1 || echo 0)"

  # 静的検査（AC-97⑦の判定方法の一つ＝rg -n）: subprocess・urllib・socket等の
  # 外向き通信APIの呼び出しが0件であることも合わせて確認する。
  assert_true "usage-snapshot: 静的検査でも通信系APIの呼び出しが0件" \
    "$(grep -qE 'subprocess|urllib|socket\.|requests\.|http\.client' "$REPO_ROOT/claude/hooks/lib/usage_snapshot.py" && echo 0 || echo 1)"

  rm -rf "$E" "$LOGGING_BIN"
fi

echo "=== 検証職1巡目 MINOR-7: 通知タイトルは移設元のまま（Q-3「現行挙動のまま」） ==="
{
  assert_true "MINOR-7回帰: usage-notify.shの通知タイトルはclaude-codex-usageのまま" \
    "$(grep -q 'with title "claude-codex-usage"' "$REPO_ROOT/scripts/lib/usage-notify.sh" && echo 1 || echo 0)"
  assert_true "MINOR-7回帰: 新しいタイトル文言(takumi009-ai-env usage-fetch)は使わない" \
    "$(grep -q 'takumi009-ai-env usage-fetch' "$REPO_ROOT/scripts/lib/usage-notify.sh" && echo 0 || echo 1)"
}

echo "=== 検証職1巡目 MINOR-8: 通知失敗（osascript失敗）は取得成功を損なわず観測可能になる ==="
{
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  # WARN_THRESHOLD(既定80)を超える値でwarn通知イベントを発生させ、
  # osascriptが失敗する状況（AIENV_USAGE_TEST_NOTIFY_LOGを使わず実経路を
  # 通す）でも取得結果自体は正常に記録され、失敗がログへ1行残ることを
  # 確認する。
  STUB_CURL_STATUS=200
  STUB_CURL_BODY='{"five_hour":{"used_percent":85,"resets_at":"2026-09-09T00:00:00Z"},"seven_day":{"used_percent":85,"resets_at":"2026-09-14T00:00:00Z"}}'
  cat > "$FAKE_BIN/osascript" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$FAKE_BIN/osascript"; hash -r
  unset AIENV_USAGE_TEST_NOTIFY_LOG
  out="$(refresh_service claude 2>&1)"
  rc=$?
  assert_eq "MINOR-8回帰: osascript失敗でも取得結果はrefresh_service=0のまま" "0" "$rc"
  assert_eq "MINOR-8回帰: five_hour.used_percentは正常に記録される" "85" "$(jq -r '.five_hour.used_percent' "$CLAUDE_CACHE")"
  assert_true "MINOR-8回帰: osascript失敗がログへ観測可能な形で残る" \
    "$(printf '%s' "$out" | grep -q "osascript" && echo 1 || echo 0)"
  rm -f "$FAKE_BIN/osascript"; hash -r
  rm -rf "$E"
}

echo
echo "======================================================================"
echo "結果: PASS=$PASS FAIL=$FAIL"
echo "======================================================================"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
