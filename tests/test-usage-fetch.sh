#!/usr/bin/env bash
# scripts/usage-fetch.sh・scripts/lib/usage-source.sh・scripts/lib/usage-notify.sh
# のユニットテスト（B1-b・使用率取得器移設 + B1-c・Codexチケット追加）。
#
# ⚠️ 検証職2巡目MINOR-2対応（記述訂正）: 以下の「AC-97」対応表はB1-bが
# 単独ブランチで作業していた当時（`claude/hooks/lib/usage_snapshot.py`が
# まだ本ブランチに無かった時点）の記述で、当時は⑦のusage-snapshot 1件を
# 「B1-a未マージのため未実施」としていた。**B1-aは既にmainへ統合済みで、
# 本ファイルの⑦節は実際には実行される**（下記「⑦読み手の非通信」節の
# コードが該当ファイルの存在を検出して実行する分岐を参照）。この節の
# 「23 fixture」「19件」等の数字はB1-bの範囲だけを数えた当時の値であり、
# 後続のB1-c（⑧節・11変異確認込み）はこの数字に含まれない。
#
# 対応表（要件＝ローカルLLM段階経路-要件-2026-09-03.md v20 AC-97・B1-b当時の記述）:
#   ①応答からの値の抽出 2 ／②必須欠落・型不正・401・500 8
#   （型不正はD-15の3変異を1fixtureで注入するパラメタ化1件×2サービス）
#   ③成功時のみfetched_atが進む 2 ／⑤429は完全no-op 4 ／⑥原子的書き出し 2
#   ＝計18件実行。④（ゲート統合2件）はB2。⑦（読み手の非通信3件）のうち
#   check-usage-gate・監視の2件はB2、usage-snapshot 1件は現在は実行される
#   （上記訂正のとおり）。
#   AC の枠外4件＝F-9b・F-9c・D-15窓の定義・F-3（設計書§6.1）。
#   B1-c（2026-09-09）で⑧節（Codexチケットの取得・変換）を追加。
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
# ⚠️ B1-c⑤（表示ツール互換の現物実行）用に、$HOMEを書き換える前の実際の
# HOMEを保存しておく。`load_entry_for()`は`.`（source）の直前の変数代入
# なのでbashの仕様上シェル全体へ`$HOME`の変更が残る（テスト内の他fixtureが
# 都度 `HOME="$E/home" ...` と明示上書きしているのはこのため）。
HOME_REAL="$HOME"

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
  # B1-c（2026-09-09・検証職1巡目MAJOR-3対応）: `rateLimitResetCredits`は
  # あるが`rateLimits`が丸ごと無い応答は、B1-c以前と同じ`codex_timeout`
  # （124）へ分類される（`.result`全体が非空というだけで完了条件にすると
  # `parse_error`（11）へ分類が後退する、という検証職の実測指摘への対応）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  baseline_fetched_at="$(jq -r '.fetched_at' "$CODEX_CACHE")"

  REQUEST_TIMEOUT=1
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"RateLimitResetCredit_x","status":"available","grantedAt":1788539594,"expiresAt":1791131594,"title":"t"}]}}}'
  refresh_service codex >/dev/null
  assert_eq "B1-c③rateLimits欠落: fetched_atが不変" "$baseline_fetched_at" "$(jq -r '.fetched_at' "$CODEX_CACHE")"
  assert_eq "B1-c③rateLimits欠落: last_error.type=timeout（parse_errorへ後退していない）" "timeout" "$(jq -r '.last_error.type' "$CODEX_CACHE")"
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
  base='{"schema_version":1,"service":"codex","fetched_at":1000,"updated_at":1000,"five_hour":{"used_percent":10,"resets_at_epoch":2000},"seven_day":{"used_percent":20,"resets_at_epoch":3000},"reset_credits":{"available_count":1,"reset_scope":["five_hour","seven_day"],"credits":[{"id":"x","status":"available","granted_at_epoch":1788539594,"expires_at_epoch":1791131594,"title":"t"}]},"last_error":null}'
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

  # B1-c（2026-09-09・検証職1巡目MAJOR-1対応）: reset_creditsの型契約。
  # 「欠落応答（旧CLI相当）」の受理と「壊れた応答（上流が型不正な値を
  # 返す・手で壊されたキャッシュ）」の拒否を、この1つのbaselineから分岐
  # させることで、五時間窓／七日間窓の検査が既に落としている偽陽性を除く
  # （each variantはbaseの他のフィールドを一切変えないため、拒否の原因が
  # reset_creditsの検査以外にないことが保証される）。
  missing_shape="$(printf '%s' "$base" | jq -c '.reset_credits = {available_count:null, reset_scope:["five_hour","seven_day"], credits:[]}')"
  assert_true "codex reset_credits: 欠落形(available_count:null・credits:[])は受理される" \
    "$(validate_usage_payload codex "$missing_shape" && echo 1 || echo 0)"
  v4="$(printf '%s' "$base" | jq -c '.reset_credits.available_count = "1"')"
  assert_true "codex reset_credits(iv) available_countが文字列なら拒否" \
    "$(validate_usage_payload codex "$v4" && echo 0 || echo 1)"
  v5="$(printf '%s' "$base" | jq -c '.reset_credits.available_count = -1')"
  assert_true "codex reset_credits(v) available_countが負値なら拒否" \
    "$(validate_usage_payload codex "$v5" && echo 0 || echo 1)"
  v6="$(printf '%s' "$base" | jq -c '.reset_credits.credits[0].id = 7')"
  assert_true "codex reset_credits(vi) credit.idが数値なら拒否" \
    "$(validate_usage_payload codex "$v6" && echo 0 || echo 1)"
  v7="$(printf '%s' "$base" | jq -c '.reset_credits.credits[0].granted_at_epoch = "1788539594"')"
  assert_true "codex reset_credits(vii) credit.granted_at_epochが文字列なら拒否" \
    "$(validate_usage_payload codex "$v7" && echo 0 || echo 1)"
  v8="$(printf '%s' "$base" | jq -c '.reset_credits.credits[0].title = {"a":1}')"
  assert_true "codex reset_credits(viii) credit.titleがオブジェクトなら拒否" \
    "$(validate_usage_payload codex "$v8" && echo 0 || echo 1)"
  v9="$(printf '%s' "$base" | jq -c '.reset_credits.reset_scope = ["secret_scope"]')"
  assert_true "codex reset_credits(ix) reset_scopeが固定値と不一致なら拒否" \
    "$(validate_usage_payload codex "$v9" && echo 0 || echo 1)"
  v10="$(printf '%s' "$base" | jq -c '.reset_credits.credits = "not-an-array"')"
  assert_true "codex reset_credits(x) creditsが配列でないなら拒否" \
    "$(validate_usage_payload codex "$v10" && echo 0 || echo 1)"
  v11="$(printf '%s' "$base" | jq -c '.reset_credits.credits[0] = "not-an-object"')"
  assert_true "codex reset_credits(xi) credits要素がオブジェクトでないなら拒否" \
    "$(validate_usage_payload codex "$v11" && echo 0 || echo 1)"

  # 変異確認（coding-doc-style §4「陽性fixtureが実際に拒否経路を通って
  # いるか」）: reset_credits_okの検査節を取り除いた変異コピーでは、v4
  # （available_countが文字列）が受理されてしまうことを確認する（このv4が
  # 実際にこの検査（他の検査ではなく）で拒否されている証拠）。
  MUT_USAGE_SOURCE="$(mktemp)"
  sed '/and (\.reset_credits | reset_credits_ok)/d' "$REPO_ROOT/scripts/lib/usage-source.sh" > "$MUT_USAGE_SOURCE"
  assert_true "変異コピー生成: 対象行が実際に1行削除されている" \
    "$([ "$(wc -l < "$REPO_ROOT/scripts/lib/usage-source.sh")" -eq "$(( $(wc -l < "$MUT_USAGE_SOURCE") + 1 ))" ] && echo 1 || echo 0)"
  ( . "$MUT_USAGE_SOURCE"; validate_usage_payload codex "$v4" )
  mut_v4_rc=$?
  assert_true "陽性fixture(v4向け): reset_credits_ok検査を外した変異コピーは文字列のavailable_countでも受理してしまう（fixtureが実際にこの検査を通っている証拠）" \
    "$([ "$mut_v4_rc" -eq 0 ] && echo 1 || echo 0)"
  rm -f "$MUT_USAGE_SOURCE"
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

echo "=== ⑧Codexチケット（rate-limit reset credit）の取得・変換（B1-c・2026-09-09） ==="
# scripts/lib/usage-source.sh: transform_codex_usage() が .result.rateLimits
# だけでなく兄弟キー .result.rateLimitResetCredits も codex-cache.json の
# reset_credits へ書き出すことを検査する（指示書§2.3＝あり／なし／credits
# 空／statusがavailable以外の4fixture＋秘密値なし＋既存キー不変）。
{
  # (1) あり：availableな1枚＋秘密値混入(accountId・description)が
  # 一切キャッシュへ写らないことも同時に検査する（絶対厳守③）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"accountId":"acct_SECRET1234567890","rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"RateLimitResetCredit_abc123","resetType":"codexRateLimits","status":"available","grantedAt":1788539594,"expiresAt":1791131594,"title":"Full reset (Weekly + 5 hr)","description":"secret-ish free text that must not be recorded"}]}}}'
  refresh_service codex
  rc=$?
  assert_eq "B1-c①あり: refresh_serviceは0" "0" "$rc"
  # 検証職1巡目MAJOR-4対応: 「既存キーは不変」を五時間窓・七日間窓の
  # used_percentという2値だけでなく、reset_credits以外の全キー・全値の
  # 完全一致（schema_version・service・updated_at・両窓のresets_at_epoch・
  # last_error含む）で固定する。fetched_at/updated_atは実行時刻に依存する
  # ため、実際に書かれた値をそのまま期待値へ埋め込んで比較する
  # （B1-b以前の出力形をこのfixtureの入力から手計算した固定値）。
  captured_fetched_at1="$(jq -r '.fetched_at' "$CODEX_CACHE")"
  actual_shape1="$(jq -c -S 'del(.reset_credits)' "$CODEX_CACHE")"
  expected_shape1="$(jq -nc --argjson fa "$captured_fetched_at1" '{
    schema_version: 1, service: "codex", fetched_at: $fa, updated_at: $fa,
    five_hour: {used_percent: 55, resets_at_epoch: 1234567890},
    seven_day: {used_percent: 22, resets_at_epoch: 1234599999},
    last_error: null
  }' | jq -c -S .)"
  assert_eq "B1-c①あり: reset_credits以外の全キー・全値がB1-b以前の出力と1バイトも違わない" "$expected_shape1" "$actual_shape1"
  assert_eq "B1-c①あり: reset_credits.available_count" "1" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"
  assert_eq "B1-c①あり: reset_credits.reset_scope" '["five_hour","seven_day"]' "$(jq -c '.reset_credits.reset_scope' "$CODEX_CACHE")"
  assert_eq "B1-c①あり: credits[0].id" "RateLimitResetCredit_abc123" "$(jq -r '.reset_credits.credits[0].id' "$CODEX_CACHE")"
  assert_eq "B1-c①あり: credits[0].status" "available" "$(jq -r '.reset_credits.credits[0].status' "$CODEX_CACHE")"
  assert_eq "B1-c①あり: credits[0].granted_at_epoch" "1788539594" "$(jq -r '.reset_credits.credits[0].granted_at_epoch' "$CODEX_CACHE")"
  assert_eq "B1-c①あり: credits[0].expires_at_epoch" "1791131594" "$(jq -r '.reset_credits.credits[0].expires_at_epoch' "$CODEX_CACHE")"
  assert_eq "B1-c①あり: credits[0].title" "Full reset (Weekly + 5 hr)" "$(jq -r '.reset_credits.credits[0].title' "$CODEX_CACHE")"
  cache_raw="$(cat "$CODEX_CACHE")"
  assert_true "B1-c①あり(絶対厳守③): accountIdの秘密値がキャッシュに写っていない" \
    "$(printf '%s' "$cache_raw" | grep -q "acct_SECRET" && echo 0 || echo 1)"
  assert_true "B1-c①あり(絶対厳守③): descriptionの自由文がキャッシュに写っていない" \
    "$(printf '%s' "$cache_raw" | grep -q "secret-ish free text" && echo 0 || echo 1)"
  rm -rf "$E"
}
{
  # (2) なし：応答に rateLimitResetCredits キー自体が無い（旧codex-cli）
  # →「取れなかった」ことが分かる形（credits[]・available_countはnull）で
  # 書く（キー自体を省略しない）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  assert_eq "B1-c②なし: reset_credits.available_countはnull" "null" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"
  assert_eq "B1-c②なし: reset_credits.creditsは空配列" "[]" "$(jq -c '.reset_credits.credits' "$CODEX_CACHE")"
  assert_eq "B1-c②なし: reset_credits.reset_scopeは固定値" '["five_hour","seven_day"]' "$(jq -c '.reset_credits.reset_scope' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  # (3) credits空：rateLimitResetCredits はあるが availableCount=0・
  # credits=[]（本人の手持ちチケットが0枚の実在パターン）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}'
  refresh_service codex >/dev/null
  assert_eq "B1-c③credits空: reset_credits.available_count=0" "0" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"
  assert_eq "B1-c③credits空: reset_credits.creditsは空配列" "[]" "$(jq -c '.reset_credits.credits' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  # (4) statusがavailable以外：失効済み(expired)のチケットが1枚だけ返る場合。
  # 取得器はstatusの値をそのまま転記する（フィルタしない。提示側
  # usage_snapshot.pyが「available」だけを表示に使う判断を持つ＝関心の分離）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}},"rateLimitResetCredits":{"availableCount":0,"credits":[{"id":"RateLimitResetCredit_zzz","status":"expired","grantedAt":1788539594,"expiresAt":1791131594,"title":"Full reset (Weekly + 5 hr)"}]}}}'
  refresh_service codex >/dev/null
  assert_eq "B1-c④status非available: available_countは応答どおり0" "0" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"
  assert_eq "B1-c④status非available: statusはそのまま転記される" "expired" "$(jq -r '.reset_credits.credits[0].status' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  # (4b) 【検証職2巡目MAJOR-2の正常形】count-only応答（`credits:null`。
  # 公式app-server応答の正常形＝詳細行を返さずavailableCountだけ返す）を
  # transform_codex_usageへ直接通し、reset_credits.available_countが権威値
  # としてそのまま書かれることを確認する（1巡目対応で追加した「裏付け
  # 必須」というfail-closed化は提示層(usage_snapshot.py)側の問題であり、
  # 取得器(usage-source.sh)は元々この正常形を素通しできていたことの回帰
  # 確認も兼ねる）。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}},"rateLimitResetCredits":{"availableCount":3,"credits":null}}}'
  refresh_service codex
  rc=$?
  assert_eq "B1-c④b count-only: refresh_serviceは0" "0" "$rc"
  assert_eq "B1-c④b count-only: reset_credits.available_count=3（権威値をそのまま信頼する）" "3" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"
  assert_eq "B1-c④b count-only: reset_credits.creditsは空配列" "[]" "$(jq -c '.reset_credits.credits' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  # (4c) 【検証職2巡目MAJOR-3】reset_credits単独の型不正（availableCountが
  # 文字列）があっても、five_hour/seven_dayの更新は止まらない（局所的
  # 縮退＝チケット部分だけが「取れなかった」形へ正規化される）。検証職の
  # 再現repro（77%/88%・availableCount:"bad"）をそのまま使う。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  baseline_fetched_at_4c="$(jq -r '.fetched_at' "$CODEX_CACHE")"

  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":77,"resetsAt":3000},"secondary":{"windowDurationMins":10080,"usedPercent":88,"resetsAt":4000}},"rateLimitResetCredits":{"availableCount":"bad","credits":[]}}}'
  refresh_service codex
  rc=$?
  assert_eq "B1-c④c reset_credits単独異常: refresh_serviceは0（書き込み自体は成功）" "0" "$rc"
  assert_true "B1-c④c reset_credits単独異常: fetched_atが前進する（使用率本体の更新は止まらない）" \
    "$([ "$(jq -r '.fetched_at' "$CODEX_CACHE")" != "$baseline_fetched_at_4c" ] && echo 1 || echo 0)"
  assert_eq "B1-c④c reset_credits単独異常: five_hourは新しい値(77%)に更新される" "77" "$(jq -r '.five_hour.used_percent' "$CODEX_CACHE")"
  assert_eq "B1-c④c reset_credits単独異常: seven_dayは新しい値(88%)に更新される" "88" "$(jq -r '.seven_day.used_percent' "$CODEX_CACHE")"
  assert_eq "B1-c④c reset_credits単独異常: last_errorはnull（局所的縮退であり取得失敗ではない）" "null" "$(jq -r '.last_error' "$CODEX_CACHE")"
  assert_eq "B1-c④c reset_credits単独異常: reset_creditsは欠落sentinelへ正規化される" "null" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"
  rm -rf "$E"
}
{
  # (4c-2) 【検証職3巡目MAJOR-1】`rateLimitResetCredits`自体、または
  # `credits`コンテナがscalar型（文字列・真偽値等）でも、five_hour/seven_day
  # の更新は止まらない（(4c)は`availableCount`という「値」の型不正だったが、
  # 今回は`rateLimitResetCredits`・`credits`という「コンテナ」自体の型不正。
  # objectでない`$rc`への`.availableCount`アクセスや、配列でない
  # `$rc.credits`への`[]`展開はjqの実行時エラーとなり、要素単位のtry/catchへ
  # 到達する前にtransform_codex_usage全体が失敗していた不具合の再発防止）。
  for bad_container_case in \
    'rateLimitResetCredits_is_string:{"rateLimitResetCredits":"bad"}' \
    'rateLimitResetCredits_is_bool:{"rateLimitResetCredits":true}' \
    'credits_is_string:{"rateLimitResetCredits":{"availableCount":1,"credits":"bad"}}' \
    'credits_is_bool:{"rateLimitResetCredits":{"availableCount":1,"credits":true}}'
  do
    case_name="${bad_container_case%%:*}"
    rc_literal="${bad_container_case#*:}"
    E="$(new_env)"; load_entry_for "$E"; reset_stubs
    STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
    refresh_service codex >/dev/null
    baseline_fetched_at_4c2="$(jq -r '.fetched_at' "$CODEX_CACHE")"

    STUB_CODEX_RESULT_LINE="$(printf '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":77,"resetsAt":3000},"secondary":{"windowDurationMins":10080,"usedPercent":88,"resetsAt":4000}},%s}}' "$(printf '%s' "$rc_literal" | sed 's/^{//; s/}$//')")"
    refresh_service codex
    rc=$?
    assert_eq "B1-c④c2[$case_name] refresh_serviceは0（コンテナ型不正でも書き込みは成功）" "0" "$rc"
    assert_true "B1-c④c2[$case_name] fetched_atが前進する（使用率本体の更新は止まらない）" \
      "$([ "$(jq -r '.fetched_at' "$CODEX_CACHE")" != "$baseline_fetched_at_4c2" ] && echo 1 || echo 0)"
    assert_eq "B1-c④c2[$case_name] five_hourは新しい値(77%)に更新される" "77" "$(jq -r '.five_hour.used_percent' "$CODEX_CACHE")"
    assert_eq "B1-c④c2[$case_name] seven_dayは新しい値(88%)に更新される" "88" "$(jq -r '.seven_day.used_percent' "$CODEX_CACHE")"
    assert_eq "B1-c④c2[$case_name] reset_credits.creditsは空配列へ正規化される" "[]" "$(jq -c '.reset_credits.credits' "$CODEX_CACHE")"
    rm -rf "$E"
  done

  # 変異確認: サニタイザからコンテナ型検査（$rc_rawがobjectかどうか）を
  # 取り除いた壊れコピーへ差し戻すと、同じ応答でtransform_codex_usageが
  # 実行時エラーで失敗する（five_hour/seven_dayも巻き込む）ことを確認する
  # （このfixtureが実際にコンテナ型検査を通っている証拠）。
  MUT_USAGE_SOURCE_NOCONTAINERGUARD="$(mktemp)"
  sed 's/(if (\$rc_raw|type) == "object" then \$rc_raw else null end) as \$rc/$rc_raw as $rc/' \
    "$REPO_ROOT/scripts/lib/usage-source.sh" > "$MUT_USAGE_SOURCE_NOCONTAINERGUARD"
  assert_true "変異コピー生成: コンテナ型検査の行が実際に書き換わっている" \
    "$(diff -q "$REPO_ROOT/scripts/lib/usage-source.sh" "$MUT_USAGE_SOURCE_NOCONTAINERGUARD" >/dev/null 2>&1 && echo 0 || echo 1)"
  raw_4c2_mut='{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":77,"resetsAt":3000},"secondary":{"windowDurationMins":10080,"usedPercent":88,"resetsAt":4000}},"rateLimitResetCredits":"bad"}'
  out_4c2_mut="$( ( . "$MUT_USAGE_SOURCE_NOCONTAINERGUARD"; transform_codex_usage "$raw_4c2_mut" 5000 ) 2>/dev/null )"
  assert_true "陽性fixture(B1-c④c2向け): コンテナ型検査を外した変異コピーはscalarなrateLimitResetCreditsで丸ごと失敗する（fixtureが実際にこの検査を通っている証拠）" \
    "$([ -z "$out_4c2_mut" ] && echo 1 || echo 0)"
  rm -f "$MUT_USAGE_SOURCE_NOCONTAINERGUARD"
}
{
  # (4d) 【検証職2巡目MAJOR-1】idが欠落したcreditは丸ごと除外されるが、
  # 使用率本体・available_countは影響を受けない。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs
  STUB_CODEX_RESULT_LINE='{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","grantedAt":1788539594,"expiresAt":1791131594,"title":"t"}]}}}'
  refresh_service codex >/dev/null
  assert_eq "B1-c④d id欠落credit: 丸ごと除外されcreditsは空配列" "[]" "$(jq -c '.reset_credits.credits' "$CODEX_CACHE")"
  assert_eq "B1-c④d id欠落credit: available_countは影響を受けない" "1" "$(jq -r '.reset_credits.available_count' "$CODEX_CACHE")"

  # 変異確認: 取得器のjqサニタイザからid型検査の項を取り除いた壊れコピーで
  # 同じ応答をtransform_codex_usageへ通すと、id欠落creditがそのまま残って
  # しまうことを確認する（このfixtureが実際にid型検査を通っている証拠）。
  MUT_USAGE_SOURCE_NOID="$(mktemp)"
  sed 's/and ((\.id|type) == "string") and (\.id != "")//' "$REPO_ROOT/scripts/lib/usage-source.sh" > "$MUT_USAGE_SOURCE_NOID"
  assert_true "変異コピー生成: id型検査の行が実際に書き換わっている" \
    "$(diff -q "$REPO_ROOT/scripts/lib/usage-source.sh" "$MUT_USAGE_SOURCE_NOID" >/dev/null 2>&1 && echo 0 || echo 1)"
  raw_4d='{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":55,"resetsAt":1234567890},"secondary":{"windowDurationMins":10080,"usedPercent":22,"resetsAt":1234599999}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","grantedAt":1788539594,"expiresAt":1791131594,"title":"t"}]}}'
  out_4d_mut="$( ( . "$MUT_USAGE_SOURCE_NOID"; transform_codex_usage "$raw_4d" 5000 ) )"
  assert_true "陽性fixture(B1-c④d向け): id型検査を外した変異コピーはid欠落creditを残してしまう（fixtureが実際にこの検査を通っている証拠）" \
    "$(printf '%s' "$out_4d_mut" | jq -e '.reset_credits.credits | length == 1' >/dev/null 2>&1 && echo 1 || echo 0)"
  rm -f "$MUT_USAGE_SOURCE_NOID"
  rm -rf "$E"
}
{
  # (5) 表示ツール互換（AC-98①相当・検証職1巡目MAJOR-4対応で現物実行へ
  # 変更）: テスト側でjqの読み方を再実装するのではなく、現物
  # `~/work/claude-codex-usage/tmux-usage.sh`（読み取り専用・無改修）を
  # 拡張後のキャッシュに対して実際に実行し、exit 0・ERR非表示・実値の
  # 反映を確認する。
  E="$(new_env)"; load_entry_for "$E"; reset_stubs; valid_claude_token
  STUB_CODEX_RESULT_LINE="$(codex_success_result_line)"
  refresh_service codex >/dev/null
  STUB_CURL_STATUS=200
  STUB_CURL_BODY="$(claude_success_body)"
  refresh_service claude >/dev/null
  TMUX_USAGE_SH="$HOME_REAL/work/claude-codex-usage/tmux-usage.sh"
  if [ ! -f "$TMUX_USAGE_SH" ]; then
    echo "  未実施 - B1-c⑤表示ツール互換: $TMUX_USAGE_SH が無い（別repo未クローン環境のためスキップ）"
  else
    TMUX_XDG_CACHE="$(mktemp -d)"
    TMUX_XDG_CONFIG="$(mktemp -d)"
    mkdir -p "$TMUX_XDG_CACHE/claude-codex-usage"
    cp "$CODEX_CACHE" "$TMUX_XDG_CACHE/claude-codex-usage/codex-cache.json"
    cp "$CLAUDE_CACHE" "$TMUX_XDG_CACHE/claude-codex-usage/claude-cache.json"
    tmux_out="$(XDG_CACHE_HOME="$TMUX_XDG_CACHE" XDG_CONFIG_HOME="$TMUX_XDG_CONFIG" HOME="$HOME_REAL" bash "$TMUX_USAGE_SH" 2>&1)"
    tmux_rc=$?
    assert_eq "B1-c⑤表示ツール互換: 現物tmux-usage.shの実行はexit 0" "0" "$tmux_rc"
    assert_true "B1-c⑤表示ツール互換: ERR表示になっていない" \
      "$(printf '%s' "$tmux_out" | grep -q "ERR" && echo 0 || echo 1)"
    assert_true "B1-c⑤表示ツール互換: Codex側(CX)の実値が反映される" \
      "$(printf '%s' "$tmux_out" | grep -q "CX" && echo 1 || echo 0)"
    rm -rf "$TMUX_XDG_CACHE" "$TMUX_XDG_CONFIG"
  fi
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
