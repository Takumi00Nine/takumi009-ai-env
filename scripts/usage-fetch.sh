#!/usr/bin/env bash
# Claude/Codex の使用率を取得し、キャッシュファイルを原子的に更新し、通知を
# 送るエントリポイント（B1-b・使用率取得器移設。旧 `claude-codex-usage/refresh.sh`
# の後継。要件＝ローカルLLM段階経路-要件-2026-09-03.md v20 FR-77・FR-77b・
# AC-97・AC-98。設計＝docs/core-split/使用率取得器移設B1b-設計-2026-09-08.md）。
#
# ⚠️ キャッシュのパス・形式は現物から1バイトも変えない（FR-77b①）＝
# `${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage/{claude,codex}-cache.json`・
# `schema_version:1`。表示側（tmux-usage.sh・cmux-usage-watch.sh）を無改修で
# 動かし続けるため。設定ファイルも現物と同じ
# `${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage/config.sh` を読む
# （D-12。表示側も同じファイルを読んでいるため）。
#
# ⚠️ 現物（claude-codex-usage/refresh.sh）から意図的に変えた5点（担当A・
# 設計書§4）:
#   ① D-3: 一過性として no-op にするのは 429（curl_exit=42）だけに狭める。
#      タイムアウト・curlの通信系エラー（124・5・6・7・28・52・55・56）は
#      「失敗」として last_error を書く（fetched_at は不変）。
#   ② D-15: 受け入れる応答の検証を used_percent だけでなく resets_at_epoch・
#      fetched_at の型まで広げる（scripts/lib/usage-source.sh 側）。
#   ③ F-9b: 失敗の記録（write_failure_cache）の戻り値を捨てない。書き出しに
#      失敗したらログに1行残し refresh_service を非0で返す。
#   ④ F-9c: `all` モードの短絡をやめる。Claude 側が失敗しても Codex の取得は
#      必ず行い、終了コードは最後に集約する（片方の書き出し障害でもう片方の
#      使用率まで古くならないように）。
#   ⑤ F-3: 前提コマンドの検査をサービスごとに分ける。jq・curl が無ければ
#      全体を止めるが、codex コマンドが無い場合は Codex だけを失敗として
#      last_error に記録し、Claude の取得は行う（現物は `all` で codex が
#      無いだけでどのサービスも取得せず exit 3 していた＝実測）。
# それ以外は現物のロジックを動かさない（D-1＝取得の移設と並行制御の作り
# 替えを同時にやらない）。
#
# テスト用の差し替え口＝AIENV_USAGE_FETCH_TEST_LIB=1（source されたときは
# main を呼ばない）・AIENV_USAGE_CONFIG_FILE（config.sh の読み元を差し替え）・
# XDG_CACHE_HOME/XDG_CONFIG_HOME/HOME（キャッシュ・キーチェーンの読み元を
# 差し替え）・AIENV_USAGE_TEST_NOTIFY_LOG（scripts/lib/usage-notify.sh 側）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck source=scripts/lib/usage-source.sh
. "$SCRIPT_DIR/lib/usage-source.sh"
# shellcheck source=scripts/lib/usage-notify.sh
. "$SCRIPT_DIR/lib/usage-notify.sh"

load_config() {
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-codex-usage"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
  CONFIG_FILE="${AIENV_USAGE_CONFIG_FILE:-$CONFIG_DIR/config.sh}"
  if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
  fi
  REFRESH_INTERVAL="${REFRESH_INTERVAL:-300}"
  REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-15}"
  RETRY_COUNT="${RETRY_COUNT:-2}"
  WARN_THRESHOLD="${WARN_THRESHOLD:-80}"
  NOTIFY_THRESHOLD="${NOTIFY_THRESHOLD:-20}"
  NOTIFY_FLOOR="${NOTIFY_FLOOR:-5}"
  NOTIFY_SOUND="${NOTIFY_SOUND:-Ping}"
  RESET_HOOK="${RESET_HOOK:-}"
  HOOK_TIMEOUT="${HOOK_TIMEOUT:-60}"
  CLAUDE_TOKEN_EXPIRY_SKEW_SECONDS="${CLAUDE_TOKEN_EXPIRY_SKEW_SECONDS:-120}"
  validate_config_numbers
  LOCK_DIR="$CACHE_DIR/locks"
  TMP_DIR="$CACHE_DIR/tmp"
  CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
  CODEX_CACHE="$CACHE_DIR/codex-cache.json"
  NOTIFY_STATE="$CACHE_DIR/notify-state.json"
}

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$$" "$*"
}

is_unsigned_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

config_fallback() {
  local name default reason
  name="$1"
  default="$2"
  reason="$3"
  log "config: $name invalid ($reason); using default $default"
  eval "$name=\$default"
}

normalize_int_config() {
  local name default min max value
  name="$1"
  default="$2"
  min="$3"
  max="$4"
  eval "value=\"\${$name}\""
  is_unsigned_int "$value" || { config_fallback "$name" "$default" "not an integer"; return; }
  [ "$value" -ge "$min" ] || { config_fallback "$name" "$default" "below $min"; return; }
  if [ -n "$max" ] && [ "$value" -gt "$max" ]; then
    config_fallback "$name" "$default" "above $max"
  fi
}

validate_config_numbers() {
  normalize_int_config REFRESH_INTERVAL 300 1 ""
  normalize_int_config REQUEST_TIMEOUT 15 1 ""
  normalize_int_config RETRY_COUNT 2 0 ""
  normalize_int_config WARN_THRESHOLD 80 0 100
  normalize_int_config NOTIFY_THRESHOLD 20 0 100
  normalize_int_config NOTIFY_FLOOR 5 0 100
  normalize_int_config HOOK_TIMEOUT 60 1 ""
  normalize_int_config CLAUDE_TOKEN_EXPIRY_SKEW_SECONDS 120 0 ""
}

now_epoch() {
  date -u '+%s'
}

json_string() {
  printf '%s' "$1" | jq -Rs .
}

atomic_write() {
  local path content dir tmp
  path="$1"
  content="$2"
  dir="$(dirname "$path")"
  tmp="$dir/.tmp.$(basename "$path").$$"
  printf '%s\n' "$content" >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$path" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# ロック保持中の名前一覧（trap ハンドラが読む）
_held_locks=""

cleanup_codex_server() {
  [ -n "$_codex_writer_pid" ] && kill "$_codex_writer_pid" 2>/dev/null
  [ -n "$_codex_server_pid" ] && kill "$_codex_server_pid" 2>/dev/null
  [ -n "$_codex_server_pid" ] && wait "$_codex_server_pid" 2>/dev/null
  [ -n "$_codex_tmp_dir" ]    && rm -rf "$_codex_tmp_dir" 2>/dev/null
}

cleanup_claude_curl_configs() {
  local file
  printf '%s\n' "$_claude_curl_config_files" | while IFS= read file; do
    [ -n "$file" ] && rm -f "$file" 2>/dev/null
  done
  _claude_curl_config_files=""
}

cleanup_locks() {
  local lock
  printf '%s\n' "$_held_locks" | while IFS= read lock; do
    [ -n "$lock" ] && rm -rf "$lock" 2>/dev/null
  done
  _held_locks=""
}

lock_max_age() {
  # retry_fetch の最悪実行時間（(RETRY_COUNT+1)回の試行 + 最大RETRY_COUNT回の
  # 指数バックオフ・各32秒上限）を必ず上回らせる。実行中の保持者のロックを
  # stale と誤判定しないため。
  printf '%s\n' $(( REQUEST_TIMEOUT * (RETRY_COUNT + 1) + 32 * RETRY_COUNT + HOOK_TIMEOUT + 30 ))
}

with_lock() {
  local name lock created now max_age status previous_held_locks
  name="$1"
  shift
  mkdir -p "$LOCK_DIR" "$TMP_DIR" 2>/dev/null || return 1
  lock="$LOCK_DIR/$name.lock.d"
  if ! mkdir "$lock" 2>/dev/null; then
    created="$(cat "$lock/created_at" 2>/dev/null)"
    now="$(now_epoch)"
    max_age="$(lock_max_age)"
    case "$created" in
      ''|*[!0-9]*) rm -rf "$lock" 2>/dev/null ;;
      *) [ $(( now - created )) -gt "$max_age" ] && rm -rf "$lock" 2>/dev/null ;;
    esac
    mkdir "$lock" 2>/dev/null || { log "$name: lock held, skipping"; return 0; }
  fi
  previous_held_locks="$_held_locks"
  if [ -n "$_held_locks" ]; then
    _held_locks="$_held_locks
$lock"
  else
    _held_locks="$lock"
  fi
  printf '%s\n' "$$" >"$lock/pid" 2>/dev/null
  now_epoch >"$lock/created_at" 2>/dev/null
  "$@"
  status=$?
  rm -rf "$lock" 2>/dev/null
  _held_locks="$previous_held_locks"
  return "$status"
}

empty_error_cache() {
  local service now type message status attempts
  service="$1"
  now="$2"
  type="$3"
  message="$4"
  status="${5:-null}"
  attempts="$6"
  jq -cn \
    --arg service "$service" \
    --arg type "$type" \
    --arg message "$message" \
    --argjson now "$now" \
    --argjson status "$status" \
    --argjson attempts "$attempts" \
    '{schema_version:1, service:$service, updated_at:$now, last_error:{at:$now,type:$type,message:$message,status:$status,attempts:$attempts}}'
}

write_failure_cache() {
  local service cache type message status attempts now msg_json out
  service="$1"
  cache="$2"
  type="$3"
  message="$4"
  status="${5:-null}"
  attempts="$6"
  now="$(now_epoch)"
  msg_json="$(json_string "$message")"
  if [ -f "$cache" ] && jq -e . "$cache" >/dev/null 2>&1; then
    out="$(jq -c \
      --arg service "$service" \
      --arg type "$type" \
      --argjson message "$msg_json" \
      --argjson now "$now" \
      --argjson status "$status" \
      --argjson attempts "$attempts" \
      '.schema_version=1
       | .service=$service
       | .updated_at=$now
       | .last_error={at:$now,type:$type,message:$message,status:$status,attempts:$attempts}' \
      "$cache" 2>/dev/null)" || return 1
  else
    out="$(empty_error_cache "$service" "$now" "$type" "$message" "$status" "$attempts")" || return 1
  fi
  atomic_write "$cache" "$out"
}

# ⚠️ 429/失敗/成功の評価順は設計書§2.2 の表のとおりに固定する（先勝ち）。
#   1. fetch_status==0（成功）           -> キャッシュ更新・last_error=null
#   2. fetch_status==42（429・D-3/D-4）  -> 完全な no-op（1バイトも書かない）
#   3. fetch_status==14（トークン失効）  -> last_error.type=auth_expired・通知1回
#   4. それ以外すべて                    -> last_error 非null・fetched_at 不変
# ⚠️ D-4: 現物にあった「42) ... status_json="429"」という到達不能の死に分岐は
# 復活させない（評価順を1本のcaseへ寄せる将来のリファクタで甦る罠だった）。
#
# ⚠️ 戻り値の契約（現物を踏襲・F-9b/F-9c はこの契約の上に乗る）＝
# **0＝キャッシュへ「結果」を記録できた（成功として記録・失敗として記録の
# どちらも含む）／1＝記録そのものが書けなかった（F-9a＝成功したのに
# atomic_writeが失敗／F-9b＝失敗の記録＝write_failure_cacheが失敗／
# F-3＝前提コマンド欠如でも同じ扱い）。** 401・500・parse_error・timeout
# 等の「取得に失敗したが last_error として正しく記録できた」場合は0を返す
# （AC-97②の受入条件は「fetched_atが不変・last_errorが非null」であって
# refresh_serviceの戻り値ではない）。main()のF-9c集約が拾うのは「書き込み
# そのものの障害」だけである。
refresh_service() {
  local service cache out err fetch_status attempts payload error_type message status_json
  service="$1"
  if [ "$service" = "claude" ]; then
    cache="$CLAUDE_CACHE"
  else
    cache="$CODEX_CACHE"
  fi
  out="$TMP_DIR/$service.out.$$"
  err="$TMP_DIR/$service.err.$$"
  mkdir -p "$CACHE_DIR" "$TMP_DIR" 2>/dev/null || return 1

  # F-3: codex コマンド不在は Codex サービスだけの失敗として扱う（Claude の
  # 取得を止めない。前提コマンドの検査をサービスごとに分ける＝D-18）。
  # ⚠️ 他の「取得に失敗したが正しく記録できた」経路と同じく、記録が書けた
  # 場合は0を返す（非0を返すのはwrite_failure_cache自体が失敗した場合だけ＝
  # 上の戻り値契約の注記を参照）。
  if [ "$service" = "codex" ] && ! command -v codex >/dev/null 2>&1; then
    log "codex: command not found; skipping fetch and recording failure"
    attempts=0
    if ! write_failure_cache "$service" "$cache" "command" "missing required command: codex" "null" "$attempts"; then
      log "$service: failed to write failure cache (missing_command)"
      return 1
    fi
    return 0
  fi

  retry_fetch "$service" "$out" "$err"
  fetch_status=$?
  attempts=$(( RETRY_COUNT + 1 ))

  if [ "$fetch_status" -eq 0 ]; then
    payload="$(cat "$out" 2>/dev/null)"
    atomic_write "$cache" "$payload" || {
      rm -f "$out" "$err" 2>/dev/null
      return 1
    }
    rm -f "$out" "$err" 2>/dev/null
    # ⚠️ 検証職1巡目MINOR-8対応: 通知処理の失敗（osascript失敗・
    # notify-state書き込み失敗）を観測可能にする。取得自体は成功している
    # ため戻り値は0のまま（通知は付随機能・取得の成否とは別軸）。
    if ! with_lock notify process_notifications "$service" "$cache"; then
      log "$service: notification processing failed (osascript failure or notify-state write failure); usage data was still recorded successfully"
    fi
    return 0
  fi

  if [ "$fetch_status" -eq 42 ]; then
    log "$service: rate limited (429); leaving cache untouched (D-3)"
    rm -f "$out" "$err" 2>/dev/null
    return 0
  fi

  if [ "$fetch_status" -eq 14 ]; then
    log "$service: access token expired; skipped fetch, keeping existing usage"
    rm -f "$out" "$err" 2>/dev/null
    if ! write_failure_cache "$service" "$cache" "auth_expired" "access token expired; open Claude Code to refresh it" "null" 0; then
      log "$service: failed to write failure cache (auth_expired)"
      return 1
    fi
    if ! with_lock notify claude_auth_expired_notify_once; then
      log "$service: auth-expired notification failed (osascript failure or notify-state write failure)"
    fi
    return 0
  fi

  # ⚠️ D-3: 一過性の no-op は 429 だけ。タイムアウト・curl の通信系エラー
  # （124・5・6・7・28・52・55・56）を含め、それ以外はすべて「失敗」として
  # last_error を書く（現物は 42・124・5・6・7・28・52・55・56 を無言 no-op に
  # しており、全面的なネットワーク断が最大10分間まったく見えなかった）。
  case "$fetch_status" in
    10) error_type="auth"; message="authentication failed"; status_json="null" ;;
    11) error_type="parse"; message="failed to parse usage response"; status_json="null" ;;
    12) error_type="http"; message="HTTP request failed"; status_json="$(safe_error_token "$err" | sed 's/^http_status=//')" ;;
    124) error_type="timeout"; message="request timed out"; status_json="null" ;;
    5|6|7|28|52|55|56) error_type="curl"; message="network error (curl_exit=$fetch_status)"; status_json="null" ;;
    *) error_type="command"; message="usage command failed"; status_json="null" ;;
  esac
  case "$status_json" in [1-9][0-9][0-9]) ;; *) status_json="null" ;; esac

  # F-9b: 失敗の記録の戻り値を捨てない。書き出しに失敗したらログへ1行残し、
  # refresh_service を非0で返す（現物は戻り値を無視して常に return 0 して
  # おり、「last_error すら書けない」二重の静かな失敗になっていた）。
  if ! write_failure_cache "$service" "$cache" "$error_type" "$message" "$status_json" "$attempts"; then
    log "$service: failed to write failure cache (status=$fetch_status)"
    rm -f "$out" "$err" 2>/dev/null
    return 1
  fi
  rm -f "$out" "$err" 2>/dev/null
  return 0
}

main() {
  load_config
  local mode overall_status
  trap 'cleanup_locks; cleanup_claude_curl_configs; cleanup_codex_server; exit 130' INT
  trap 'cleanup_locks; cleanup_claude_curl_configs; cleanup_codex_server; exit 143' TERM
  trap 'cleanup_locks; cleanup_claude_curl_configs; cleanup_codex_server'           EXIT
  mode="${1:-all}"
  case "$mode" in
    claude|codex|all) ;;
    *) printf '%s\n' "usage: $0 [claude|codex|all]" >&2; return 2 ;;
  esac
  log "usage-fetch.sh $mode: started"
  command -v jq >/dev/null 2>&1 || { printf '%s\n' 'missing required command: jq' >&2; return 3; }
  command -v curl >/dev/null 2>&1 || { printf '%s\n' 'missing required command: curl' >&2; return 3; }
  mkdir -p "$CACHE_DIR" "$LOCK_DIR" "$TMP_DIR" 2>/dev/null || return 1

  # ⚠️ F-9c: `all` の短絡をやめる。片方が非0でも、もう片方の取得を必ず
  # 行い、終了コードは最後に集約する（現物は claude が非0だと
  # `with_lock claude refresh_service claude || return 1` でそこで打ち切り、
  # codex の取得が丸ごと省略されていた）。
  overall_status=0
  if [ "$mode" = "claude" ] || [ "$mode" = "all" ]; then
    with_lock claude refresh_service claude || overall_status=1
  fi
  if [ "$mode" = "codex" ] || [ "$mode" = "all" ]; then
    with_lock codex refresh_service codex || overall_status=1
  fi
  return "$overall_status"
}

if [ "${AIENV_USAGE_FETCH_TEST_LIB:-}" = "1" ]; then
  load_config
else
  main "$@"
  exit $?
fi
