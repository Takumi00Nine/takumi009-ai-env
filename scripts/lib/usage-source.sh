#!/usr/bin/env bash
# 使用率取得器の「取得・変換・検証」部分（B1-b・使用率取得器移設）。
#
# `claude-codex-usage/refresh.sh` から移設した純粋寄りの部品を集めた共有
# ライブラリ（実行エントリポイントとは同居させない＝coding-doc-style §1）。
# `scripts/usage-fetch.sh` からのみ source される。単体テストからも直接
# source してよい（AIENV_USAGE_TEST_LIB=1 の判定・`main` の呼び出しは持たない
# エントリ側＝scripts/usage-fetch.sh の役割。本ファイルは常に安全に source
# できる純粋関数の集合である）。
#
# 呼び出し元（scripts/usage-fetch.sh）が load_config() で設定するグローバル
# （CACHE_DIR・TMP_DIR・REQUEST_TIMEOUT・RETRY_COUNT・
# CLAUDE_TOKEN_EXPIRY_SKEW_SECONDS 等）と、trap ハンドラが読む後始末用
# グローバル（_codex_server_pid 等）に依存する。
#
# ⚠️ 秘密の扱いは現物から1行も緩めない（absolute-rules ③）＝トークンは
# `curl --config <600の一時ファイル>` 経由でのみ渡し、コマンドライン・環境
# 変数・ログに出さない。エラーの詳細は safe_error_token() の許可リストに
# 一致した語だけをログへ出す。

# Codex サーバ後始末用（fetch_codex_once が設定し、trap ハンドラが読む）
_codex_server_pid=""
_codex_writer_pid=""
_codex_tmp_dir=""

# Claude curl 認証設定ファイル後始末用（fetch_claude_once が設定し、
# trap ハンドラが読む）
_claude_curl_config_files=""
_claude_curl_config_file_result=""

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
    codex_timeout) printf '%s' "$value"; return 0 ;;
    codex_unavailable) printf '%s' "$value"; return 0 ;;
    *) return 1 ;;
  esac
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

curl_config_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

token_has_crlf() {
  case "$1" in
    *$'\r'*|*$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

register_claude_curl_config() {
  local file
  file="$1"
  if [ -n "$_claude_curl_config_files" ]; then
    _claude_curl_config_files="$_claude_curl_config_files
$file"
  else
    _claude_curl_config_files="$file"
  fi
}

# トークンをコマンドラインにも環境変数にも載せず、0600の一時ファイル
# （curl --config 経由）だけで渡す。ファイルはシンボリックリンク攻撃を
# 避けるため `set -C`（noclobber）で新規作成し、権限を作成直後に締める。
create_claude_curl_config() {
  local token file quoted i
  token="$1"
  _claude_curl_config_file_result=""
  mkdir -p "$TMP_DIR" 2>/dev/null || return 1
  i=0
  while [ "$i" -lt 10 ]; do
    file="$TMP_DIR/.claude-curl-auth.$$.$RANDOM.conf"
    if ( set -C; umask 077; : >"$file" ) 2>/dev/null; then
      chmod 600 "$file" 2>/dev/null || { rm -f "$file" 2>/dev/null; return 1; }
      register_claude_curl_config "$file"
      quoted="$(curl_config_quote "$token")"
      printf 'header = "Authorization: Bearer %s"\n' "$quoted" >"$file" 2>/dev/null || {
        rm -f "$file" 2>/dev/null
        return 1
      }
      _claude_curl_config_file_result="$file"
      return 0
    fi
    i=$(( i + 1 ))
  done
  return 1
}

remove_claude_curl_config() {
  local file kept entry
  file="$1"
  rm -f "$file" 2>/dev/null
  kept=""
  while IFS= read entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$file" ] && continue
    if [ -n "$kept" ]; then
      kept="$kept
$entry"
    else
      kept="$entry"
    fi
  done <<EOF
$_claude_curl_config_files
EOF
  _claude_curl_config_files="$kept"
}

# jq ヘルパ（Claude の per-model weekly 窓を「配列位置」ではなく「意味」
# （kind=="weekly_scoped" かつ scope.model が非null）で選ぶ。上流が並びを
# 入れ替えた実績がある＝2026-07-13。transform_codex_usage の
# windowDurationMins 帯判定と同じ考え方）。
_MODEL_WEEKLY_ENTRY_JQ='
  def model_weekly_entry:
    ([.limits[]? | select(.kind == "weekly_scoped" and .scope.model != null)]) as $candidates
    | (($candidates | map(select(.is_active == true)) | .[0]) // $candidates[0]);
'

transform_claude_usage() {
  local raw now fh_reset sd_reset mw_reset fh_epoch sd_epoch mw_epoch value
  raw="$1"
  now="$2"
  fh_reset="$(printf '%s' "$raw" | jq -r '.five_hour.resets_at // .five_hour.resetsAt // empty' 2>/dev/null)"
  sd_reset="$(printf '%s' "$raw" | jq -r '.seven_day.resets_at // .seven_day.resetsAt // empty' 2>/dev/null)"
  mw_reset="$(printf '%s' "$raw" | jq -r "${_MODEL_WEEKLY_ENTRY_JQ} model_weekly_entry | .resets_at // empty" 2>/dev/null)"
  fh_epoch="null"
  sd_epoch="null"
  mw_epoch="null"
  if [ -n "$fh_reset" ]; then
    value="$(iso_to_epoch "$fh_reset")" && fh_epoch="$value"
  fi
  if [ -n "$sd_reset" ]; then
    value="$(iso_to_epoch "$sd_reset")" && sd_epoch="$value"
  fi
  if [ -n "$mw_reset" ]; then
    value="$(iso_to_epoch "$mw_reset")" && mw_epoch="$value"
  fi
  printf '%s' "$raw" | jq -c \
    --argjson now "$now" \
    --argjson fh_epoch "$fh_epoch" \
    --argjson sd_epoch "$sd_epoch" \
    --argjson mw_epoch "$mw_epoch" \
    "${_MODEL_WEEKLY_ENTRY_JQ}"'
    (model_weekly_entry) as $mw
    | {
      schema_version: 1,
      service: "claude",
      fetched_at: $now,
      updated_at: $now,
      five_hour: {
        used_percent: (.five_hour.used_percent // .five_hour.utilization),
        resets_at: (.five_hour.resets_at // .five_hour.resetsAt // null),
        resets_at_epoch: $fh_epoch
      },
      seven_day: {
        used_percent: (.seven_day.used_percent // .seven_day.utilization),
        resets_at: (.seven_day.resets_at // .seven_day.resetsAt // null),
        resets_at_epoch: $sd_epoch
      },
      model_weekly: {
        used_percent: ($mw.percent // null),
        resets_at: ($mw.resets_at // null),
        resets_at_epoch: $mw_epoch,
        label: ($mw.scope.model.display_name // null)
      },
      last_error: null
    }' 2>/dev/null
}

transform_codex_usage() {
  # primary/secondary は配列位置ではなく windowDurationMins の帯で分類する
  # （上流が5h/7dの枠を入れ替えた実績あり＝2026-07-13）。既知の帯に属さない、
  # または不在の窓は null のまま（validate_usage_payload の「片方は許容」規則
  # の対象）。
  #
  # ⚠️ B1-c（2026-09-09）: raw は fetch_codex_once が渡す `.result`
  # （`{rateLimits, rateLimitResetCredits}`）または（旧仕様・テスト双方の
  # 互換のため）rateLimits 単体のどちらでも受理する（`.rateLimits? // .`）。
  # rateLimitResetCredits（本人の言う「チケット」＝banked reset credit）は
  # `.rateLimits` の兄弟キーとして raw 直下から読む（$r ではなく raw の
  # トップレベル）。欠落（旧 codex-cli 応答）は「取れなかった」ことが分かる
  # 形（available_count:null・credits:[]）で書き、キー自体を省略しない。
  # description は転記しない（長文・変動＝指示書§2.1）。id はプレフィクス
  # 付きの不透明な資源ID形式（`RateLimitResetCredit_<opaque>`。複数の独立
  # ソースで確認＝Knowledge/claude-codex-usage.md 2026-09-09節）で accountId
  # を埋め込まないため、加工せずそのまま転記する。
  local raw now
  raw="$1"
  now="$2"
  printf '%s' "$raw" | jq -c --argjson now "$now" '
    def window_kind:
      if . == null then null
      elif (.windowDurationMins >= 295 and .windowDurationMins <= 305) then "five_hour"
      elif (.windowDurationMins >= 10075 and .windowDurationMins <= 10085) then "seven_day"
      else null
      end;
    (.rateLimits? // .) as $r
    | (.rateLimitResetCredits) as $rc
    | (reduce ([$r.primary, $r.secondary] | .[]) as $w
        ({five_hour: null, seven_day: null};
          ($w | window_kind) as $kind
          | if $kind == null then . else .[$kind] = $w end
        )) as $byKind
    | {
      schema_version: 1,
      service: "codex",
      fetched_at: $now,
      updated_at: $now,
      five_hour: {
        used_percent: ($byKind.five_hour.usedPercent // $byKind.five_hour.used_percent // null),
        resets_at_epoch: ($byKind.five_hour.resetsAt // $byKind.five_hour.resets_at_epoch // null)
      },
      seven_day: {
        used_percent: ($byKind.seven_day.usedPercent // $byKind.seven_day.used_percent // null),
        resets_at_epoch: ($byKind.seven_day.resetsAt // $byKind.seven_day.resets_at_epoch // null)
      },
      # ⚠️ 検証職2巡目MAJOR-3対応: reset_credits単独の型不正が使用率本体
      # （five_hour/seven_day）の更新まで止めてはいけない（局所的縮退の
      # 仕様に反する）。ここで上流の型不正をその場で「取れなかった」形
      # （available_count:null・該当creditを除外）へ正規化し、
      # validate_usage_payload() に渡す時点で reset_credits は常に
      # 型契約を満たす（five_hour/seven_dayが正常な限り、reset_credits側の
      # 汚染で書き込み全体が拒否されることは無い）。
      # ⚠️ 検証職3巡目MAJOR-1対応: 上記の正規化は「$rcがobject」「$rc.credits
      # が配列」という前提のアクセス（`$rc.availableCount`・`$rc.credits[]`）
      # に依存していたため、`rateLimitResetCredits`自体や`credits`コンテナが
      # scalar型（文字列・真偽値・配列等）だと、そのアクセス自体がjqの
      # 実行時エラーとなり、try/catchへ到達する前にtransform_codex_usage()
      # 全体が失敗していた（five_hour/seven_dayも巻き込んで書き込み全体が
      # parse_errorへ倒れる＝MAJOR-3で直したはずの契約が破れていた）。
      # コンテナ自体の型検査を最初に行い、objectでない`$rc`はnullへ、
      # 配列でない`$rc.credits`は空配列へ倒してから中身へアクセスする。
      # ⚠️ 検証職2巡目MAJOR-1対応: id・status・granted_at_epoch は必須
      # （非null・正しい型）とし、いずれか欠落/型不正のcreditは丸ごと
      # 除外する（「有効な別creditがあればnullだらけのcreditも残る」を
      # 防ぐ）。expires_at_epoch・title は公式protocol（v2/account.rs）が
      # nullable のため任意＝型不正なら当該フィールドだけをnullへ倒し、
      # エントリ自体は残す（id/status/granted_at_epochが正しい限り「詳細の
      # 一部が無い」だけの正常な縮退として扱う）。
      reset_credits: (
        (.rateLimitResetCredits) as $rc_raw
        | (if ($rc_raw|type) == "object" then $rc_raw else null end) as $rc
        | (if $rc == null then null else $rc.availableCount end) as $ac_raw
        | (
            if ($ac_raw|type) == "number" and ($ac_raw == ($ac_raw|floor)) and ($ac_raw >= 0)
            then $ac_raw
            else null
            end
          ) as $safe_ac
        | (
            if $rc == null then []
            elif ($rc.credits|type) == "array" then $rc.credits
            else []
            end
          ) as $credits_raw
        | {
            available_count: $safe_ac,
            reset_scope: ["five_hour", "seven_day"],
            credits: [
              $credits_raw[]
              | try (
                  if (type == "object")
                     and ((.id|type) == "string") and (.id != "")
                     and ((.status|type) == "string") and (.status != "")
                     and ((.grantedAt|type) == "number") and (.grantedAt == (.grantedAt|floor))
                  then {
                    id: .id,
                    status: .status,
                    granted_at_epoch: .grantedAt,
                    expires_at_epoch: (
                      if ((.expiresAt|type) == "number") and (.expiresAt == (.expiresAt|floor))
                      then .expiresAt
                      else null
                      end
                    ),
                    title: (if (.title|type) == "string" then .title else null end)
                  }
                  else empty
                  end
                ) catch empty
            ]
          }
      ),
      last_error: null
    }' 2>/dev/null
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
    # transform_codex_usage()が既にこの契約を満たす形へ正規化するため、
    # ここは主に「hand-craftedな不正payloadを直接この関数へ渡すテスト」
    # のための多重防御。
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
      if $service == "codex" then
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

fetch_claude_once() {
  local out_file err_file creds_source token expires_at now_ms skew_ms response curl_status status body now transformed curl_config
  out_file="$1"
  err_file="$2"
  creds_source="keychain"
  token="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  if [ -z "$token" ]; then
    creds_source="file"
    token="$(jq -r '.claudeAiOauth.accessToken // empty' \
      "$HOME/.claude/.credentials.json" 2>/dev/null)"
  fi
  if [ -z "$token" ]; then
    printf '%s\n' 'missing_token' >"$err_file"
    return 10
  fi
  if token_has_crlf "$token"; then
    printf '%s\n' 'invalid_token' >"$err_file"
    return 10
  fi
  # claudeAiOauth.expiresAt はミリ秒epoch。事前に見て、既に期限切れ（or
  # 期限間際）なら通信せず auth_expired を返す（確実に401になる通信を
  # 省く）。読む先はトークンと同じ資格情報源（keychain/file）に揃える
  # （別ソースの古い expiresAt で誤って skip しないため）。
  if [ "$creds_source" = "keychain" ]; then
    expires_at="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
      | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)"
  else
    expires_at="$(jq -r '.claudeAiOauth.expiresAt // empty' \
      "$HOME/.claude/.credentials.json" 2>/dev/null)"
  fi
  if [ -n "$expires_at" ] && is_unsigned_int "$expires_at"; then
    if [ "${#expires_at}" -ge 13 ] && [ "${#expires_at}" -le 15 ]; then
      now_ms=$(( $(now_epoch) * 1000 ))
      skew_ms=$(( CLAUDE_TOKEN_EXPIRY_SKEW_SECONDS * 1000 ))
      if [ "$expires_at" -le $(( now_ms + skew_ms )) ]; then
        printf '%s\n' 'token_expired' >"$err_file"
        return 14
      fi
    else
      log "claude: expiresAt has unexpected digit count (${#expires_at}); ignoring it and fetching normally"
    fi
  else
    log "claude: expiresAt missing or non-numeric; expiry pre-check skipped"
  fi
  create_claude_curl_config "$token" || {
    printf '%s\n' 'curl_config_error' >"$err_file"
    return 13
  }
  curl_config="$_claude_curl_config_file_result"
  response="$(curl -sS --max-time "$REQUEST_TIMEOUT" \
    -w '\n%{http_code}' \
    --config "$curl_config" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)"
  curl_status=$?
  remove_claude_curl_config "$curl_config"
  if [ "$curl_status" -ne 0 ]; then
    printf 'curl_exit=%s\n' "$curl_status" >"$err_file"
    return "$curl_status"
  fi
  status="$(printf '%s\n' "$response" | tail -n 1)"
  body="$(printf '%s\n' "$response" | sed '$d')"
  case "$status" in
    2??)
      now="$(now_epoch)"
      transformed="$(transform_claude_usage "$body" "$now")" || {
        printf '%s\n' 'parse_error' >"$err_file"
        return 11
      }
      write_validated_usage_payload claude "$transformed" "$out_file" "$err_file" || return 11
      return 0
      ;;
    429) printf '%s\n' 'rate_limited' >"$err_file"; return 42 ;;
    *) printf 'http_status=%s\n' "$status" >"$err_file"; return 12 ;;
  esac
}

fetch_codex_once() {
  local out_file err_file in_fifo server_out server_err codex_deadline start_seconds result now transformed
  out_file="$1"
  err_file="$2"
  _codex_tmp_dir="$TMP_DIR/codex.$$.$RANDOM"
  mkdir -p "$_codex_tmp_dir" 2>/dev/null || return 1
  in_fifo="$_codex_tmp_dir/in"
  server_out="$_codex_tmp_dir/out"
  server_err="$_codex_tmp_dir/err"
  mkfifo "$in_fifo" 2>/dev/null || {
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir=""
    return 1
  }
  : >"$server_out"
  codex app-server <"$in_fifo" >"$server_out" 2>"$server_err" &
  _codex_server_pid=$!

  # codex app-server は initialize が終わるまで account/* を捌かない。FIFO を
  # writer サブシェルで開き続けて全体の間中つなぐ。
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"takumi009-ai-env-usage-fetch","version":"1.0"}}}'
    sleep 3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
    sleep "$REQUEST_TIMEOUT"
  } >"$in_fifo" &
  _codex_writer_pid=$!

  codex_deadline=$(( REQUEST_TIMEOUT + 5 ))
  start_seconds=$SECONDS
  result=""
  while [ $(( SECONDS - start_seconds )) -le "$codex_deadline" ]; do
    # B1-c（2026-09-09・検証職1巡目MAJOR-3対応）: チケット
    # （`.result.rateLimitResetCredits`）は rateLimits の兄弟キーなので
    # 変換器へは `.result` 全体を渡すが、**完了条件（このループを抜ける
    # 条件）は従来どおり `.result.rateLimits` の存在**に保つ（`.result` の
    # 有無だけを条件にすると、rateLimits を欠いた応答＝壊れた/不完全な
    # 応答を「結果が来た」と誤認して待機を打ち切ってしまい、本来
    # `codex_timeout`（124）になるべき状況が `parse_error`（11）に化ける
    # という分類の後退を検証職が実測で発見した）。
    result="$(jq -c 'select(.id == 2 and (.result.rateLimits != null)) | .result // empty' "$server_out" 2>/dev/null | tail -n 1)"
    [ -n "$result" ] && break
    kill -0 "$_codex_server_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$_codex_writer_pid" 2>/dev/null
  kill "$_codex_server_pid" 2>/dev/null
  sleep 1
  kill -0 "$_codex_server_pid" 2>/dev/null && kill -9 "$_codex_server_pid" 2>/dev/null
  wait "$_codex_writer_pid" 2>/dev/null
  wait "$_codex_server_pid" 2>/dev/null
  if [ -z "$result" ]; then
    printf '%s\n' 'codex_timeout' >"$err_file"
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
    return 124
  fi
  now="$(now_epoch)"
  transformed="$(transform_codex_usage "$result" "$now")" || {
    printf '%s\n' 'parse_error' >"$err_file"
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
    return 11
  }
  write_validated_usage_payload codex "$transformed" "$out_file" "$err_file" || {
    rm -rf "$_codex_tmp_dir" 2>/dev/null
    _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
    return 11
  }
  rm -rf "$_codex_tmp_dir" 2>/dev/null
  _codex_tmp_dir="" _codex_server_pid="" _codex_writer_pid=""
  return 0
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
    if [ "$service" = "claude" ]; then
      fetch_claude_once "$out_file" "$err_file"
    else
      fetch_codex_once "$out_file" "$err_file"
    fi
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
# （scripts/usage-fetch.sh）だけが持つ。
