#!/usr/bin/env bash
# 使用率取得器の通知部分（閾値の判定・通知状態の記録・送る段）。
#
# `claude-codex-usage/refresh.sh` から移設（B1-b）。v1.2 束 B で notify/connect/macos/ から
# Usage の実行器へ移し、送る段の先を知らせの共通部品（呼出・区分 usage）にした（設計 D-2）。
# usage/executor/usage-fetch.sh からのみ source される（`usage/executor/usage-source.sh` の
# atomic_write・now_epoch・json_string・run_with_timeout・log と `core/executor/notice.sh` の
# notice_call に依存＝先に source されている前提）。

USAGE_NOTIFY_TITLE="claude-codex-usage"   # 知らせの題（移設元のまま＝設計書§8 Q-3）

# 通知状態の services は宣言された短名（USAGE_FETCH_SERVICES・台帳の行順）ごとに 1 つ
# （提供元の名前をここに書かない＝FR-6。全部入りでは従来と同じ JSON になる）。
ensure_notify_state_json() {
  jq -cn --arg svcs "$USAGE_FETCH_SERVICES" '
    def empty_window: {previous_used_percent:null,last_seen_used_percent:null,reset_notified:false,reset_notified_at:null,warn_notified:false,warn_notified_at:null};
    {
      schema_version:1,
      updated_at:0,
      services:(reduce ($svcs | split(" ") | map(select(. != "")))[] as $s ({};
        .[$s] = {five_hour:empty_window, seven_day:empty_window, auth_expired_notified:false}))
    }'
}

read_notify_state() {
  if [ -f "$NOTIFY_STATE" ] && jq -e --arg svcs "$USAGE_FETCH_SERVICES" '
      . as $st | .schema_version == 1 and ($svcs | split(" ") | map(select(. != "")) | all($st.services[.] != null))
    ' "$NOTIFY_STATE" >/dev/null 2>&1; then
    jq -c . "$NOTIFY_STATE"
  else
    ensure_notify_state_json
  fi
}

# テスト用の差し替え口＝AIENV_USAGE_TEST_NOTIFY_LOG（設定されていれば
# 共通部品を呼ばずログへ追記。現物の CLAUDE_CODEX_USAGE_TEST_NOTIFY_LOG の後継）。
# 送る段は常に 0 を返す＝通知状態の更新は送信の成否に依らない（届かなかったことは
# 口が知らせの記録へ・口が無いことは共通部品が自分のログへ 1 行残す）。
send_notification() {
  local message
  message="$1"
  if [ -n "${AIENV_USAGE_TEST_NOTIFY_LOG:-}" ]; then
    printf '%s\n' "$message" >>"$AIENV_USAGE_TEST_NOTIFY_LOG"
    return 0
  fi
  notice_call log usage "$USAGE_NOTIFY_TITLE" "$message" "$NOTIFY_SOUND"
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

# トークン失効の通知は1アウテージにつき最大1回。with_lock notify の
# 下で呼ぶこと（process_notifications だけがフラグを解除する＝次回成功時）。
# $1＝短名（トークン失効を返すのは現状 Claude の取得器だけ＝文言もそれに合わせる）。
auth_expired_notify_once() {
  local service state already updated now
  service="$1"
  state="$(read_notify_state)" || return 1
  already="$(printf '%s' "$state" | jq -r --arg s "$service" '.services[$s].auth_expired_notified // false' 2>/dev/null)"
  [ "$already" = "true" ] && return 0
  send_notification "Claude のアクセストークンが期限切れです。Claude Code を起動すると自動更新されます。"
  now="$(now_epoch)"
  updated="$(printf '%s' "$state" | jq -c --argjson now "$now" --arg s "$service" '
    .schema_version=1
    | .updated_at=$now
    | .services[$s].auth_expired_notified=true
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
    --arg svcs "$USAGE_FETCH_SERVICES" \
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
        | reduce ($svcs | split(" ") | map(select(. != "")))[] as $s (.;
            .services[$s].five_hour=(.services[$s].five_hour // empty_window)
            | .services[$s].seven_day=(.services[$s].seven_day // empty_window))
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
