#!/usr/bin/env bash
# Usage 接続（Codex）の取得器＝ usage/executor/usage-fetch.sh が台帳の鍵
# usage.fetch で列挙し source する（D-8 方式②）。宣言（同じ階層の
# usage.env）が持つ短名 "codex" を使い、usage/executor/usage-source.sh の
# retry_fetch() が `fetch_${service}_once` として動的に呼ぶ契約（関数名は
# 固定・提供元のリテラルは usage-source.sh 側に書かない）。
#
# 旧 claude-codex-usage/refresh.sh から移設（B1-b）。usage/executor/
# usage-source.sh の共通関数（transform_codex_usage・now_epoch・log・
# write_validated_usage_payload）と、呼び出し元（usage-fetch.sh）が
# load_config() で設定するグローバル（TMP_DIR・REQUEST_TIMEOUT）に依存する。
#
# 戻り値 15＝前提コマンド（codex）が無い（F-3。usage-source.sh の
# retry_fetch() はこの値を 42・14 と同じく即打ち切り（再試行しない）に
# 扱う＝提供元に依らない数値の契約）。

# Codex サーバ後始末用（fetch_codex_once が設定し、trap ハンドラ
# （usage-fetch.sh の cleanup_codex_server）が読む）
_codex_server_pid=""
_codex_writer_pid=""
_codex_tmp_dir=""

fetch_codex_once() {
  local out_file err_file in_fifo server_out server_err codex_deadline start_seconds result now transformed
  out_file="$1"
  err_file="$2"
  # F-3: 前提コマンドの検査をサービスごとに分ける（codex が PATH に無い
  # ときだけこの接続を失敗にする。jq・curl 共通の検査は usage-fetch.sh
  # main() が全体の前提として行う）。再試行しても変わらないので
  # retry_fetch() 側で即打ち切り（戻り値 15）。
  if ! command -v codex >/dev/null 2>&1; then
    printf '%s\n' 'missing_command' >"$err_file"
    return 15
  fi
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
