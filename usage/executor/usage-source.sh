#!/usr/bin/env bash
# 使用率取得器の「提供元に依らない変換・検証・原子的書込・時刻」部分
# （B1-b・使用率取得器移設。v1.1 分割＝提供元ごとの取得・変換は
# usage/connect/<提供元>/fetch.sh へ移した。D-15 の窓検査・B1-c の
# reset_credits を持つ払い出しの形の検査は本ファイルに残る＝書き手側の契約）。
#
# `claude-codex-usage/refresh.sh` から移設した純粋寄りの部品を集めた共有
# ライブラリ（実行エントリポイントとは同居させない＝coding-doc-style §1）。
# `usage/executor/usage-fetch.sh` からのみ source される。単体テストからも直接
# source してよい（AIENV_USAGE_TEST_LIB=1 の判定・`main` の呼び出しは持たない
# エントリ側＝usage/executor/usage-fetch.sh の役割。本ファイルは常に安全に source
# できる純粋関数の集合である）。取得器（fetch_<短名>_once）は接続側が持ち、
# 本ファイルの retry_fetch() は短名から関数名を組み立てて呼ぶ（提供元の
# リテラルをここに書かない）。
#
# 呼び出し元（usage/executor/usage-fetch.sh）が load_config() で設定するグローバル
# （CACHE_DIR・TMP_DIR・REQUEST_TIMEOUT・RETRY_COUNT 等）に依存する。
#
# ⚠️ 秘密の扱いは現物から1行も緩めない（absolute-rules ③）＝トークンは
# 接続側（usage/connect/<提供元>/fetch.sh）が `curl --config <600の一時
# ファイル>` 経由でのみ渡し、コマンドライン・環境変数・ログに出さない。
# エラーの詳細は safe_error_token() の許可リストに一致した語だけをログへ出す。

iso_to_epoch() {
  local value normalized
  value="$1"
  [ -n "$value" ] && [ "$value" != "null" ] || return 1
  normalized="$(printf '%s' "$value" | sed -E 's/\.[0-9]+([+-][0-9]{2}:[0-9]{2}|Z)$/\1/; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/' 2>/dev/null)"
  date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null
}

# エラーの詳細をログへ出してよい語の許可リスト。一致しなければ何も返さず
# 非0で終わる（未知の内容をそのままログへ出さない＝秘密の混入防止）。
safe_error_token() {
  local value
  value="$(cat "$1" 2>/dev/null | tail -n 1)"
  case "$value" in
    http_status=[0-9][0-9][0-9]) printf '%s' "$value"; return 0 ;;
    curl_exit=[0-9]|curl_exit=[0-9][0-9]|curl_exit=[0-9][0-9][0-9]) printf '%s' "$value"; return 0 ;;
    rate_limited) printf '%s' "$value"; return 0 ;;
    missing_token) printf '%s' "$value"; return 0 ;;
    invalid_token) printf '%s' "$value"; return 0 ;;
    token_expired) printf '%s' "$value"; return 0 ;;
    parse_error) printf '%s' "$value"; return 0 ;;
    missing_command) printf '%s' "$value"; return 0 ;;
  esac
  # 接続（usage/connect/<短名>/fetch.sh）が書く <短名>_timeout／
  # <短名>_unavailable を1本の正規表現で受ける（短名の構文＝設計定数§11と
  # 同じ英小文字・数字・ハイフン・先頭英字）。値そのものは変えない（NFR-1）。
  if [[ "$value" =~ ^[a-z][a-z0-9-]*_(timeout|unavailable)$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

run_with_timeout() {
  local seconds timeout_base timeout_dir flag child watcher status i
  seconds="$1"
  shift
  timeout_base="${TMP_DIR:-${TMPDIR:-/tmp}}"
  mkdir -p "$timeout_base" 2>/dev/null || timeout_base="${TMPDIR:-/tmp}"
  timeout_dir=""
  i=0
  while [ "$i" -lt 10 ]; do
    timeout_dir="$timeout_base/.usage-fetch-timeout.$$.$RANDOM.d"
    mkdir "$timeout_dir" 2>/dev/null && break
    timeout_dir=""
    i=$(( i + 1 ))
  done
  if [ -z "$timeout_dir" ]; then
    timeout_dir="${TMPDIR:-/tmp}/.usage-fetch-timeout.$$.$RANDOM.d"
    mkdir "$timeout_dir" 2>/dev/null || return 1
  fi
  flag="$timeout_dir/flag"
  "$@" &
  child=$!
  (
    sleep "$seconds"
    if kill -0 "$child" 2>/dev/null; then
      : >"$flag"
      kill "$child" 2>/dev/null
      sleep 1
      kill -0 "$child" 2>/dev/null && kill -9 "$child" 2>/dev/null
    fi
  ) &
  watcher=$!
  wait "$child"
  status=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then
    rm -rf "$timeout_dir" 2>/dev/null
    return 124
  fi
  rm -rf "$timeout_dir" 2>/dev/null
  return "$status"
}

# ⚠️ D-15（B1-b で現物から広げた検査。設計書§2.2・§8 Q-8＝訂正採用）＝
# `used_percent` だけでなく、存在する窓（used_percent が非null の窓）の
# `resets_at_epoch` と、応答全体の `fetched_at` の型も検査する。
# 「窓が存在する」＝used_percent が非null（transform_*_usage は欠落した
# 窓の used_percent と resets_at_epoch をどちらも null にするため、この
# 定義なら「欠落した窓」と「壊れた窓」を取り違えない＝設計書§2.2）。
# 存在する窓なのに resets_at_epoch が null／非整数なら失敗（リセット時刻の
# 抽出に失敗した壊れた応答を「正常」として書かないための契約＝
# coding-doc-style §4「壊れたデータを見分ける条件は書き手側の契約で書く」）。
# ⚠️ Codex の片窓欠落は現物のまま受け入れる（§8 Q-6＝読み手側の改訂は
# B2 の担当。取得器の振る舞いはここでは変えない）。

# ⚠️ B1-c（2026-09-09・検証職1巡目MAJOR-1対応）＝ `reset_credits` の型契約
# （FR-104由来の窓検査と同じ「書き手側の契約」原則）。取得器がここで拒否
# しないと、上流APIが返した型不正な値（枚数が文字列・idが数値・epochが
# 文字列等）がそのままキャッシュへ書かれてしまう。`reset_scope` は取得器が
# 常に固定値で書く定数（上流データではない）なので、固定値との完全一致を
# 検査する（`["secret_scope"]`のような値が紛れ込んでいたら壊れた応答として
# 拒否する）。
validate_usage_payload() {
  local service payload
  service="$1"
  payload="$2"
  printf '%s' "$payload" | jq -e --arg service "$service" '
    def valid_number: type == "number" and . >= 0 and . <= 100;
    def valid_epoch: type == "number" and (. == floor);
    def valid_count: . == null or (type == "number" and (. == floor) and . >= 0);
    def valid_str_or_null: . == null or type == "string";
    def window_ok:
      (.used_percent == null) or ((.used_percent | valid_number) and (.resets_at_epoch | valid_epoch));
    # ⚠️ 検証職2巡目MAJOR-1対応: id・status・granted_at_epochは必須
    # （非null・非空文字列／有効epoch）。expires_at_epoch・titleは公式
    # protocol（v2/account.rs）がnullableのため任意（null許容）。
    # 接続側の取得器が既にこの契約を満たす形へ正規化するため、ここは
    # 主に「hand-craftedな不正payloadを直接この関数へ渡すテスト」のための
    # 多重防御。
    def credit_ok:
      type == "object"
      and (.id | type == "string") and (.id != "")
      and (.status | type == "string") and (.status != "")
      and (.granted_at_epoch | valid_epoch)
      and (.title | valid_str_or_null)
      and (.expires_at_epoch == null or (.expires_at_epoch | valid_epoch));
    def reset_credits_ok:
      type == "object"
      and (.available_count | valid_count)
      and (.reset_scope == ["five_hour", "seven_day"])
      and (.credits | type == "array")
      and all(.credits[]; credit_ok);
    .schema_version == 1
    and .service == $service
    and (.fetched_at | valid_epoch)
    and (
      if has("reset_credits") then
        (.five_hour | window_ok)
        and (.seven_day | window_ok)
        and ((.five_hour.used_percent != null) or (.seven_day.used_percent != null))
        and (.reset_credits | reset_credits_ok)
      else
        (.five_hour.used_percent != null) and (.five_hour | window_ok)
        and (.seven_day.used_percent != null) and (.seven_day | window_ok)
        and (.model_weekly | window_ok)
      end
    )
  ' >/dev/null 2>&1
}

write_validated_usage_payload() {
  local service payload out_file err_file
  service="$1"
  payload="$2"
  out_file="$3"
  err_file="$4"
  validate_usage_payload "$service" "$payload" || {
    printf '%s\n' 'parse_error' >"$err_file"
    return 11
  }
  printf '%s\n' "$payload" >"$out_file"
}

retry_fetch() {
  local service out_file err_file attempt max_attempts last_status err_detail sleep_seconds shift_amount
  service="$1"
  out_file="$2"
  err_file="$3"
  attempt=0
  max_attempts=$(( RETRY_COUNT + 1 ))
  last_status=1
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$(( attempt + 1 ))
    # 取得器（usage/connect/<短名>/fetch.sh）は短名から関数名を組み立てて
    # 呼ぶ＝提供元のリテラルをここに書かない（接続側が fetch_<短名>_once を
    # 定義する契約。D-8 方式②）。
    "fetch_${service}_once" "$out_file" "$err_file"
    last_status=$?
    if [ "$last_status" -eq 0 ]; then
      log "$service: fetch OK (attempt $attempt/$max_attempts)"
      return 0
    fi
    err_detail="$(safe_error_token "$err_file")"
    log "$service: fetch FAILED status=$last_status attempt=$attempt/$max_attempts${err_detail:+ token=$err_detail}"
    if [ "$last_status" -eq 42 ]; then
      log "$service: rate limited; retry suppressed until next refresh cycle"
      break
    fi
    if [ "$last_status" -eq 14 ]; then
      log "$service: token expired; retry suppressed until the token is refreshed"
      break
    fi
    if [ "$last_status" -eq 15 ]; then
      log "$service: required command missing; retry suppressed until it is installed"
      break
    fi
    [ "$attempt" -lt "$max_attempts" ] || break
    # 指数バックオフ（1,2,4,...最大32秒）。既に失敗しているエンドポイントを
    # 一定間隔で叩き続けて自ら429を誘発しないため。
    shift_amount=$(( attempt - 1 ))
    [ "$shift_amount" -gt 5 ] && shift_amount=5
    sleep_seconds=$(( 1 << shift_amount ))
    log "$service: retry in ${sleep_seconds}s (exponential backoff)"
    sleep "$sleep_seconds"
  done
  return "$last_status"
}

# ⚠️ 本ファイルは常に安全に source できる（main を呼ばない・load_config も
# 呼ばない）。AIENV_USAGE_TEST_LIB=1 の判定と main の呼び出しはエントリ側
# （usage/executor/usage-fetch.sh）だけが持つ。
