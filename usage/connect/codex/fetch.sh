#!/usr/bin/env bash
# Usage 接続（Codex）の取得器＝ usage/executor/usage-fetch.sh が台帳の鍵
# usage.fetch で列挙し source する（D-8 方式②）。宣言（同じ階層の
# usage.env）が持つ短名 "codex" を使い、usage/executor/usage-source.sh の
# retry_fetch() が `fetch_${service}_once` として動的に呼ぶ契約（関数名は
# 固定・提供元のリテラルは usage-source.sh 側に書かない）。
#
# 旧 claude-codex-usage/refresh.sh から移設（B1-b・取得と変換は接続側に
# 残す＝v1.1 分割で usage-source.sh から transform_codex_usage() も
# 本ファイルへ移した＝検証 V-03）。usage/executor/usage-source.sh の
# 共通関数（now_epoch・log・write_validated_usage_payload）と、呼び出し元
# （usage-fetch.sh）が load_config() で設定するグローバル（TMP_DIR・
# REQUEST_TIMEOUT）に依存する。
#
# 戻り値 15＝前提コマンド（codex）が無い（F-3。usage-source.sh の
# retry_fetch() はこの値を 42・14 と同じく即打ち切り（再試行しない）に
# 扱う＝提供元に依らない数値の契約）。

# Codex サーバ後始末用（fetch_codex_once が設定し、trap ハンドラ
# （usage-fetch.sh の cleanup_codex_server）が読む）
_codex_server_pid=""
_codex_writer_pid=""
_codex_tmp_dir=""

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
