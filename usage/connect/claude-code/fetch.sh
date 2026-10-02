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
