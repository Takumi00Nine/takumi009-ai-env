#!/usr/bin/env bash
# 使用率取得器の通知部分（B1-b・使用率取得器移設）。
#
# ⚠️ **B2（FR-110〜FR-112・事象駆動の監視）で置き換える予定の部品である。**
# 現行の通知（リセット・高使用率警告・トークン失効）を挙動そのまま
# `claude-codex-usage/refresh.sh` から移設しただけであり、恒久設計ではない
# （設計書 D-11・§11 B2-2）。`notify-state.json` を引き継ぐか捨てるかは
# B2 が決める。
#
# `claude-codex-usage/refresh.sh` から移設。scripts/usage-fetch.sh からのみ
# source される（`scripts/lib/usage-source.sh` の atomic_write・now_epoch・
# json_string・run_with_timeout・log に依存＝先に source されている前提）。
# ⚠️ `scripts/lib/macos-notify.sh` は使わない（sound name を持たず、テスト用の
# 通知ログ差し替え口も無いので、現行の通知が静かに変わるため＝設計書 D-11）。

ensure_notify_state_json() {
  jq -cn '{
    schema_version:1,
    updated_at:0,
    services:{
      claude:{
        five_hour:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null},
        seven_day:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null},
        auth_expired_notified:false
      },
      codex:{
        five_hour:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null},
        seven_day:{previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null},
        auth_expired_notified:false
      }
    }
  }'
}

read_notify_state() {
  if [ -f "$NOTIFY_STATE" ] && jq -e '.schema_version == 1 and .services.claude and .services.codex' "$NOTIFY_STATE" >/dev/null 2>&1; then
    jq -c . "$NOTIFY_STATE"
  else
    ensure_notify_state_json
  fi
}

# テスト用の差し替え口＝AIENV_USAGE_TEST_NOTIFY_LOG（設定されていれば
# osascript を呼ばずログへ追記。現物の CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG の
# 後継）。
# ⚠️ 検証職1巡目MINOR-7対応: 通知タイトルは移設元（claude-codex-usage）から
# 変えていない（設計書§8 Q-3「通知は現行挙動のまま」・本人裁定）。
# ⚠️ 検証職1巡目MINOR-8対応: osascriptの失敗を観測可能にする（取得成功
# 自体は損なわない＝戻り値は常に0のまま。失敗はログへ1行残すだけ）。
send_notification() {
  local message rc
  message="$1"
  if [ -n "${AIENV_USAGE_TEST_NOTIFY_LOG:-}" ]; then
    printf '%s\n' "$message" >>"$AIENV_USAGE_TEST_NOTIFY_LOG"
    return 0
  fi
  run_with_timeout "$REQUEST_TIMEOUT" osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "claude-codex-usage" sound name (item 2 of argv)' \
    -e 'end run' \
    "$message" "$NOTIFY_SOUND"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "notification: osascriptが失敗しました（exit=${rc}）。取得結果自体は正常に記録済みです。"
  fi
  return 0
}

run_reset_hook() {
  local service window prev current
  service="$1"
  window="$2"
  prev="$3"
  current="$4"
  [ -n "$RESET_HOOK" ] || return 0
  [ -x "$RESET_HOOK" ] || return 0
  run_with_timeout "$HOOK_TIMEOUT" "$RESET_HOOK" "$service" "$window" "$prev" "$current"
  return 0
}

# Claude トークン失効の通知は1アウテージにつき最大1回。with_lock notify の
# 下で呼ぶこと（process_notifications だけがフラグを解除する＝次回成功時）。
claude_auth_expired_notify_once() {
  local state already updated now
  state="$(read_notify_state)" || return 1
  already="$(printf '%s' "$state" | jq -r '.services.claude.auth_expired_notified // false' 2>/dev/null)"
  [ "$already" = "true" ] && return 0
  send_notification "Claude のアクセストークンが期限切れです。Claude Code を起動すると自動更新されます。"
  now="$(now_epoch)"
  updated="$(printf '%s' "$state" | jq -c --argjson now "$now" '
    .schema_version=1
    | .updated_at=$now
    | .services.claude.auth_expired_notified=true
  ' 2>/dev/null)" || return 1
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  atomic_write "$NOTIFY_STATE" "$updated"
}

process_notifications() {
  local service cache state now cache_json events kind window a b display_service display_window updated
  service="$1"
  cache="$2"
  [ -f "$cache" ] || return 0
  # どちらかの窓に実値があれば通知対象にする（窓が欠落しうる＝codexの5h上限
  # 一時撤廃の実績あり）。窓ごとに独立して扱うので、欠落窓が他方をブロック
  # したり「0へリセットされた」と誤読したりしない。
  jq -e '.last_error == null and ((.five_hour.used_percent != null) or (.seven_day.used_percent != null))' "$cache" >/dev/null 2>&1 || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  state="$(read_notify_state)" || return 1
  now="$(now_epoch)"
  cache_json="$(jq -c . "$cache" 2>/dev/null)" || return 0
  events="$(jq -rn \
    --argjson state "$state" \
    --argjson cache "$cache_json" \
    --arg service "$service" \
    --argjson warn "$WARN_THRESHOLD" \
    --argjson threshold "$NOTIFY_THRESHOLD" \
    --argjson floor "$NOTIFY_FLOOR" '
      ["five_hour","seven_day"][] as $w
      | ($cache[$w].used_percent) as $current
      | select($current != null)
      | ($state.services[$service][$w].previous_used_percent) as $prev
      | ($state.services[$service][$w].reset_notified // false) as $rn
      | ($state.services[$service][$w].warn_notified // false) as $wn
      | if ($prev != null and ($rn|not) and $prev >= $threshold and $current <= $floor) then
          "reset|\($w)|\($prev)|\($current)"
        else empty end,
        if (($wn|not) and $current >= $warn) then
          "warn|\($w)|\($current)"
        else empty end
    ' 2>/dev/null)"
  printf '%s\n' "$events" | while IFS='|' read kind window a b; do
    [ -n "$kind" ] || continue
    display_service="$(printf '%s' "$service" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    display_window="$window"
    [ "$window" = "five_hour" ] && display_window="5h"
    [ "$window" = "seven_day" ] && display_window="7d"
    if [ "$kind" = "reset" ]; then
      send_notification "$display_service $display_window リセット: ${a}% -> ${b}%"
      run_reset_hook "$service" "$window" "$a" "$b"
    elif [ "$kind" = "warn" ]; then
      send_notification "$display_service ${display_window}枠 警告: ${a}%"
    fi
  done
  updated="$(jq -cn \
    --argjson state "$state" \
    --argjson cache "$cache_json" \
    --arg service "$service" \
    --argjson now "$now" \
    --argjson warn "$WARN_THRESHOLD" \
    --argjson threshold "$NOTIFY_THRESHOLD" \
    --argjson floor "$NOTIFY_FLOOR" '
      def empty_window: {previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null};
      reduce ["five_hour","seven_day"][] as $w ($state;
        .schema_version=1
        | .updated_at=$now
        | .services.claude.five_hour=(.services.claude.five_hour // empty_window)
        | .services.claude.seven_day=(.services.claude.seven_day // empty_window)
        | .services.codex.five_hour=(.services.codex.five_hour // empty_window)
        | .services.codex.seven_day=(.services.codex.seven_day // empty_window)
        | .services[$service].auth_expired_notified=false
        | ($cache[$w].used_percent) as $current
        | if $current == null then .
          else
            (.services[$service][$w].previous_used_percent) as $prev
            | (.services[$service][$w].reset_notified // false) as $rn
            | (.services[$service][$w].warn_notified // false) as $wn
            | (.services[$service][$w].reset_notified) =
                (if ($rn and $current >= $threshold) then false
                 elif ($prev != null and ($rn|not) and $prev >= $threshold and $current <= $floor) then true
                 else $rn end)
            | (.services[$service][$w].reset_notified_at) =
                (if ($rn and $current >= $threshold) then null
                 elif ($prev != null and ($rn|not) and $prev >= $threshold and $current <= $floor) then $now
                 else .services[$service][$w].reset_notified_at end)
            | (.services[$service][$w].warn_notified) =
                (if $current >= $warn then true else false end)
            | (.services[$service][$w].warn_notified_at) =
                (if (($wn|not) and $current >= $warn) then $now
                 elif $current < $warn then null
                 else .services[$service][$w].warn_notified_at end)
            | (.services[$service][$w].previous_used_percent) = $current
            | (.services[$service][$w].last_seen_used_percent) = $current
          end
      )' 2>/dev/null)" || return 1
  atomic_write "$NOTIFY_STATE" "$updated"
}
