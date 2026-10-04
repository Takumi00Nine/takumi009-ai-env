#!/bin/bash
# 知らせの共通部品（共有 lib・実行入口を持たない＝発する側と口が source する）。
# v1.2 束 B＝docs/v1.2-notify-install の設計 §2.1〜§2.3・§4。
#
# 発する側は届け先の名前・呼出構文を書かず、ここの関数だけを呼ぶ:
#   notice_call <自分のログ関数|-> <区分> <題> <本文> [<音>]
#       呼出（同期）。口の鍵を照会し、あれば口を起動してその終了コードを返す。
#       鍵なし＝自分のログ関数へ「口が無いため知らせを送りません: <題> — <本文>」1 行（- なら何もしない）。
#       台帳異常・実体異常＝照会の固定文を知らせの記録へ 1 行・自分のログ関数へも同じ 1 行。
#   notice_answer
#       応答。口の鍵を照会し、あれば記録先を同期で確保してから（失敗は stderr へ 1 行）
#       口を切り離して起動し、待たずに 0 で戻る。標準出力には何も出さない。
# 口も使う:
#   notice_record_append <ファイル> <語> <届け先> <題> <詳細>
#       親フォルダを作ってから、各欄を \→\\・改行→\n・TAB→\t の順に符号化し TAB 区切り 1 行で追記。
#       書けなければ stderr に 1 行出して 1 を返す（呼んだ側の働きは変えない）。
#   notice_log_path   … 知らせの記録のパス（AIENV_NOTIFY_LOG で上書き）
#   notice_run_with_timeout <秒> <コマンド...>
#       上限を超えたらコマンドのプロセスグループへ TERM→1 秒後 KILL。打ち切ったら 124、それ以外はコマンドの終了コード。

# ---- 設計定数（§4）＝変えるときはここだけ ----
NOTICE_LOG_DEFAULT_REL=".claude/logs/notify.tsv"   # 知らせの記録（$HOME 相対・AIENV_NOTIFY_LOG で上書き）
NOTICE_MOUTH_KEY="notify.send"                     # 口の鍵（台帳）
NOTICE_TIMEOUT_RC=124                              # notice_run_with_timeout が打ち切ったときの終了コード

NOTICE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOTICE_LEDGER_TOOL="$NOTICE_ROOT/core/assembly/ledger-tool.sh"

notice_log_path() { printf '%s' "${AIENV_NOTIFY_LOG:-$HOME/$NOTICE_LOG_DEFAULT_REL}"; }

_notice_encode() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

notice_record_append() {
  local file="$1" line f
  line="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  shift
  for f in "$@"; do line="$line	$(_notice_encode "$f")"; done
  if mkdir -p "$(dirname "$file")" 2>/dev/null && printf '%s\n' "$line" >>"$file" 2>/dev/null; then
    return 0
  fi
  echo "notice: 知らせの記録に書けません: $file" >&2
  return 1
}

notice_run_with_timeout() {
  local secs="$1" flag had_monitor=0 cmd_pid watcher_pid rc=0
  shift
  flag="$(mktemp "${TMPDIR:-/tmp}/notice-timeout.XXXXXX")" || return 1
  rm -f "$flag"
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  cmd_pid=$!
  ( sleep "$secs"; : >"$flag"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  watcher_pid=$!
  [ "$had_monitor" = "1" ] || set +m
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -KILL "-$cmd_pid" 2>/dev/null
  kill -TERM "-$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  if [ -e "$flag" ]; then rm -f "$flag"; return "$NOTICE_TIMEOUT_RC"; fi
  return "$rc"
}

# _notice_lookup — 口の鍵を照会し、NOTICE_MOUTH（パス）と NOTICE_LEDGER_MSG（固定文）を置く。終了コードは照会のまま。
_notice_lookup() {
  local err rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/notice-lookup.XXXXXX")" || return 2
  NOTICE_MOUTH="$("$NOTICE_LEDGER_TOOL" lookup "$NOTICE_MOUTH_KEY" 2>"$err")" || rc=$?
  NOTICE_LEDGER_MSG="$(head -1 "$err")"
  rm -f "$err"
  return "$rc"
}

# _notice_ledger_bad <自分のログ関数|-> <題> — 照会の固定文を記録へ 1 行（語＝固定文の種別語）・自分のログへも 1 行。
_notice_ledger_bad() {
  local word
  [ -n "$NOTICE_LEDGER_MSG" ] || NOTICE_LEDGER_MSG="LEDGER: ledger 台帳ツールの照会に失敗"
  word="${NOTICE_LEDGER_MSG#LEDGER: }"
  word="${word%% *}"
  notice_record_append "$(notice_log_path)" "$word" "-" "$2" "$NOTICE_LEDGER_MSG"
  [ "$1" = "-" ] || "$1" "$NOTICE_LEDGER_MSG"
}

notice_call() {
  local self_log="$1" cat="$2" title="$3" body="$4" rc=0
  shift 4
  _notice_lookup || rc=$?
  case "$rc" in
    0) "$NOTICE_MOUTH" call "$cat" "$title" "$body" "$@"; return $? ;;
    1) [ "$self_log" = "-" ] || "$self_log" "口が無いため知らせを送りません: $title — $body"; return 1 ;;
    *) _notice_ledger_bad "$self_log" "$title"; return 1 ;;
  esac
}

notice_answer() {
  local rc=0 log
  _notice_lookup || rc=$?
  case "$rc" in
    0)
      log="$(notice_log_path)"
      { mkdir -p "$(dirname "$log")" && : >>"$log"; } 2>/dev/null \
        || echo "notice: 知らせの記録を確保できません: $log" >&2
      ( "$NOTICE_MOUTH" answer </dev/null >/dev/null 2>&1 & )
      ;;
    1) ;;
    *) _notice_ledger_bad - "-" ;;
  esac
  return 0
}
