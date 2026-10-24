#!/usr/bin/env bash
# Usage 接続（Claude Code）の取得器＝ usage/executor/usage-fetch.sh が台帳の
# 鍵 usage.fetch で列挙し source する（D-8 方式②）。宣言（同じ階層の
# usage.env）が持つ短名 "claude" を使い、usage/executor/usage-source.sh の
# retry_fetch() が `fetch_${service}_once` として動的に呼ぶ契約（関数名は
# 固定・提供元のリテラルは usage-source.sh 側に書かない）。
#
# 旧 claude-codex-usage/refresh.sh から移設（B1-b）。usage/executor/
# usage-source.sh の共通関数（iso_to_epoch・safe_error_token・now_epoch・
# is_unsigned_int・log・write_validated_usage_payload）と、呼び出し元
# （usage-fetch.sh）が load_config() で設定するグローバル（TMP_DIR・
# REQUEST_TIMEOUT・CLAUDE_TOKEN_EXPIRY_SKEW_SECONDS）に依存する。
#
# ⚠️ 秘密の扱いは現物から1行も緩めない（absolute-rules ③）＝トークンは
# `curl --config <600の一時ファイル>` 経由でのみ渡し、コマンドライン・環境
# 変数・ログに出さない。

# curl 認証設定ファイル後始末用（fetch_claude_once が設定し、trap ハンドラ
# （usage-fetch.sh の cleanup_claude_curl_configs）が読む）
_claude_curl_config_files=""
_claude_curl_config_file_result=""

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

# jq ヘルパ（per-model weekly 窓を「配列位置」ではなく「意味」
# （kind=="weekly_scoped" かつ scope.model が非null）で選ぶ。上流が並びを
# 入れ替えた実績がある＝2026-07-13）。
_MODEL_WEEKLY_ENTRY_JQ='
  def model_weekly_entry:
    ([.limits[]? | select(.kind == "weekly_scoped" and .scope.model != null)]) as $candidates
    | (($candidates | map(select(.is_active == true)) | .[0]) // $candidates[0]);
'

# ── 設計定数（設計 v3 §4・§5.3。変える見込みの無い定義なので設定項目にしない）──
# 診断の記録で名前を出してよいキー（取得器が読むキーだけ）。これ以外のキー名は
# 一切出さず、伏せ字と型ごとの件数だけにする（秘密の混入防止）。
_CLAUDE_DIAG_TOP_KEYS='["five_hour","seven_day","limits"]'
_CLAUDE_DIAG_WINDOW_KEYS='["used_percent","utilization","resets_at","resetsAt"]'
_CLAUDE_DIAG_MASK='?'
_CLAUDE_DIAG_UNREADABLE='JSON として読めない'
_CLAUDE_DIAG_FAILED='形を記録できなかった'

# 窓の分類（設計 v3 §5.1。先勝ち）。使用率の対（used_percent／utilization）・
# リセット時刻の対（resets_at／resetsAt）から値を 1 つ選ぶ規則は 1 か所
# （pick_pair）。分類とキャッシュへの変換は、この関数が返す値だけを使う。
# 出力＝{"class":"idle"|"active"|"broken","used":<値>,"reset":<値>}
# 引数＝raw（応答本文）・key（five_hour／seven_day）。raw が JSON でなければ非 0。
_CLAUDE_CLASSIFY_JQ='
  def pick_pair($a; $b):
    [.[$a], .[$b]] | map(select(. != null))
    | if length == 0 then {none: true}
      elif length == 1 then {value: .[0]}
      else {broken: true} end;
  def broken: {class: "broken"};
  if type != "object" then broken
  elif has($key) | not then broken
  else
    .[$key] as $w
    | if $w == null then {class: "idle"}
      elif ($w | type) != "object" then broken
      elif ($w | has("used_percent") or has("utilization") or has("resets_at") or has("resetsAt")) | not then broken
      else
        ($w | pick_pair("used_percent"; "utilization")) as $u
        | ($w | pick_pair("resets_at"; "resetsAt")) as $r
        | if $u.broken or $r.broken then broken
          elif $r | has("value") then
            if ($r.value | type) == "string" then {class: "active", used: (if $u | has("value") then $u.value else null end), reset: $r.value}
            else broken end
          elif ($u | has("value") | not) or ($u.value | type) == "number" and $u.value == 0 then {class: "idle"}
          else broken end
      end
  end'

classify_claude_window() {
  printf '%s' "$1" | jq -c --arg key "$2" "$_CLAUDE_CLASSIFY_JQ" 2>/dev/null
}

# 窓 1 つをキャッシュの形へ変換する。未開始は「未開始の形」（設計 v3 §5.2）、
# 進行中は選んだ使用率・リセット時刻と求めた resets_at_epoch。壊れなら非 0。
claude_window_json() {
  local classified class reset epoch
  classified="$(classify_claude_window "$1" "$2")" || return 1
  class="$(printf '%s' "$classified" | jq -r '.class')" || return 1
  case "$class" in
    idle)
      printf '%s' '{"used_percent":0,"resets_at":null,"resets_at_epoch":null}'
      ;;
    active)
      reset="$(printf '%s' "$classified" | jq -r '.reset')" || return 1
      epoch="$(iso_to_epoch "$reset")" || return 1
      printf '%s' "$classified" | jq -c --argjson epoch "$epoch" \
        '{used_percent: .used, resets_at: .reset, resets_at_epoch: $epoch}'
      ;;
    *) return 1 ;;
  esac
}

transform_claude_usage() {
  local raw now fh_json sd_json mw_reset mw_epoch value
  raw="$1"
  now="$2"
  fh_json="$(claude_window_json "$raw" five_hour)" || return 1
  sd_json="$(claude_window_json "$raw" seven_day)" || return 1
  mw_reset="$(printf '%s' "$raw" | jq -r "${_MODEL_WEEKLY_ENTRY_JQ} model_weekly_entry | .resets_at // empty" 2>/dev/null)"
  mw_epoch="null"
  if [ -n "$mw_reset" ]; then
    value="$(iso_to_epoch "$mw_reset")" && mw_epoch="$value"
  fi
  printf '%s' "$raw" | jq -c \
    --argjson now "$now" \
    --argjson five_hour "$fh_json" \
    --argjson seven_day "$sd_json" \
    --argjson mw_epoch "$mw_epoch" \
    "${_MODEL_WEEKLY_ENTRY_JQ}"'
    (model_weekly_entry) as $mw
    | {
      schema_version: 1,
      service: "claude",
      fetched_at: $now,
      updated_at: $now,
      five_hour: $five_hour,
      seven_day: $seven_day,
      model_weekly: {
        used_percent: ($mw.percent // null),
        resets_at: ($mw.resets_at // null),
        resets_at_epoch: $mw_epoch,
        label: ($mw.scope.model.display_name // null)
      },
      last_error: null
    }' 2>/dev/null
}

# 2xx の応答を弾いたときの診断の 1 行の組立（設計 v3 §5.3）。出すのは許可リスト
# のキー名＋型、許可リスト外は伏せ字＋型ごとの件数だけ。値・本文は出さない。
# JSON として読めなければ固定文。組み立てに失敗したら非 0（呼び出し側が固定文を出す）。
claude_rejected_shape() {
  local body
  body="$1"
  printf '%s' "$body" | jq -e . >/dev/null 2>&1 || { printf '%s' "$_CLAUDE_DIAG_UNREADABLE"; return 0; }
  printf '%s' "$body" | jq -r \
    --argjson top_keys "$_CLAUDE_DIAG_TOP_KEYS" \
    --argjson window_keys "$_CLAUDE_DIAG_WINDOW_KEYS" \
    --arg mask "$_CLAUDE_DIAG_MASK" '
    def known($k; $allowed): [$allowed[] | select(. == $k)] | length > 0;
    def outline($allowed):
      if type == "object" then
        ([to_entries[] | select(known(.key; $allowed)) | "\(.key):\(.value | type)"]) as $named
        | ([to_entries[] | select(known(.key; $allowed) | not)] | group_by(.value | type)
           | map("\($mask):\(.[0].value | type)×\(length)")) as $masked
        | "{" + (($named + $masked) | join(",")) + "}"
      else type end;
    "top=\(type) " + outline($top_keys)
    + (if type == "object" then
        (" five_hour=" + (.five_hour | outline($window_keys)) + " seven_day=" + (.seven_day | outline($window_keys)))
       else "" end)' 2>/dev/null
}

log_claude_rejection() {
  local shape
  if shape="$(claude_rejected_shape "$1")" && [ -n "$shape" ]; then
    log "claude: rejected 2xx shape: $shape"
  else
    log "claude: rejected 2xx shape: $_CLAUDE_DIAG_FAILED"
  fi
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
        log_claude_rejection "$body"
        return 11
      }
      write_validated_usage_payload claude "$transformed" "$out_file" "$err_file" || {
        log_claude_rejection "$body"
        return 11
      }
      return 0
      ;;
    429) printf '%s\n' 'rate_limited' >"$err_file"; return 42 ;;
    *) printf 'http_status=%s\n' "$status" >"$err_file"; return 12 ;;
  esac
}
