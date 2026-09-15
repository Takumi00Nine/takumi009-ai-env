#!/bin/bash
# Projectペイン番号参照の自動解決フック（UserPromptSubmit）
# ファイル名は旧仕様（Next Project限定）の名残でnext-pane-resolve.shの
# まま据え置く（本人指示 2026-09-14 19:45）。
# プロンプトに「Project／プロジェクト」（表記ゆれ）＋「番」の両方が
# 含まれるとき、cmux-next-watch.sh --list（番号<TAB>正式プロジェクト名
# <TAB>next値<TAB>区分）の出力を additionalContext として注入する。AI は
# ツールを叩かずに番号→プロジェクトを解決できる
# （正本: Decisions/2026-08-05-next-pane-replaces-feed）。
# 発火条件は「Project」（大小文字非依存）または「プロジェクト」を含み、
# かつ「番」を含むことのみ。旧仕様にあった「Next」の要求は本人の要件
# 変更（Dock枠名からNextを外しProject/Taskにした）で撤廃した。
# 「Next Project の 3 番」はProject＋番を含むので変更後も自然に発火する
# （後方互換）。「ペイン」だけでは発火しない（例: 「Project ペインの
# 3 番」は「番」を含むので発火するが、単なる「Task の 3 番」は
# Project／プロジェクトを含まないため発火しない）。前後をASCII英数字・
# アンダースコアで挟まれた語の一部（例: Projects/Projector/
# abcnext-projectxyz）は対象外にする。この前後境界は英語側だけでなく
# 日本語側（プロジェクト）にも同じASCII英数字・アンダースコアの境界を
# 課す＝「Aプロジェクト」「プロジェクトA」「_プロジェクト」
# 「プロジェクト_」はいずれも対象外（検証5巡目 MAJOR #1。ASCII文字が
# 隣接しなければ境界は自動的に満たされるので、平仮名・カタカナ・漢字が
# 隣接する通常の日本語文には影響しない）。プロジェクトの直後に漢字が
# 続く場合（複合語の一部。例: 「プロジェクト化」）も対象外にする。「の」
# 等の平仮名の助詞は漢字ではないため直後に続いても対象内のまま
# （検証1巡目 MAJOR #2・検証2巡目 MAJOR #2）。「プロジェクター」は
# 「プロジェクト」を部分文字列として含まない別語なのでそもそも一致
# しない。「番」は数字が隣接しなくても文字そのものの有無だけを見る
# （「何番」「Project は何番？」も対象内。検証5巡目 MINOR #4で明文化・
# 全角数字「３番」も番という文字自体は変わらないので対象内）。
# .promptに不正なUTF-8バイト由来の置換文字（U+FFFD）が含まれる場合は
# 判定に使わず非発火にする＝jqは不正バイトをJSON解析エラーにはせず
# U+FFFDへ変換して読み進めるため、そのままだと本来の語とは無関係な
# 境界が生まれて過剰発火する（検証5巡目 MINOR #3で実測確認）。
# 判定は prompt の生テキストをbash変数へ取り出さず jq 単体（Oniguruma正規表現・
# Unicode対応）で完結させる。理由: bashのコマンド置換はNULバイトを黙って
# 落とすため（bash 3.2 で実測）、bash変数を経由すると「Pro\0ject」等が
# 区切り無しの「Project」に化けて誤発火する（検証1巡目 MINOR #8）。
# .prompt が文字列でない場合（object/array等）は
# JSON文字列化されて誤発火しないよう型を検査する（検証1巡目 MAJOR #4）。
#
# 時間予算（②設計 docs/design.md §22.4・リーダー裁定Q3-2で①もこの型へ
# 揃えることになった）: フック枠は5秒（settings.jsonのtimeout）。外部
# プロセスを起こすのは判定用jq（run_with_deadline 1）とemit_context
# （run_with_deadline 2。LIST_CMD呼び出しと最終jq -nの両方を含む）の2箇所
# だけ。run_with_deadline <N> の意味は「正常な処理にN秒まるごと許し、
# TERMをN秒地点で送り、応答しなければ短い猶予（0.3秒）でKILLする」
# （検証4巡目 MAJOR #1＝旧実装はTERMをN-1秒（1秒枠なら0.5秒）で送っており、
# 0.6秒で正常終了するjqや1.2秒で正常終了するLIST_CMDまで打ち切ってしまう
# 過剰な短縮だった。②設計 §22.4の予算表の意図＝「判定用jqに1秒・
# emit_contextに2秒を使わせる」に合わせ、TERMの時刻を「正常処理に許す
# 時間」の意味に統一した）。実質上限は判定用jq=1.3秒・emit_context=2.3秒・
# 合計最大3.6秒（枠5秒に対して1.4秒の余裕。②設計の「2秒の余裕」からは
# 縮むが、正常な遅い処理を打ち切らないことを優先する本人裁定＝要報告）。
# cmd・watchdog双方をプロセスグループ単位（bash 3.2の`set -m`でジョブ
# ごとに専用pgidを得る）でTERM→KILLする。プロセスグループ単位にする
# 理由は2つ＝(a) LIST_CMDが自分の中でさらに子プロセスを起こしても一括で
# 止められる、(b) watchdog自身の子（TERM待ちのsleep）を単独killすると
# 孤児化し、hook終了後もsleepだけ残り続ける不具合が実測で確認された
# （検証3巡目 MAJOR #2）。cmd_pidがシグナルで終了した場合（deadlineの
# TERMが届いた場合）はwatchdog自身の0.3秒後KILLをそのまま待ち、TERM
# ハンドラで後始末する子孫にも猶予0.3秒を与える。deadline前に自然終了
# した場合（成功・失敗問わず、シグナルでない終了）だけ残存子孫へ即座に
# KILLを送る（検証5巡目 MAJOR #2＝cmd_pidの生死に関わらず無条件で即座に
# KILLしていたため、TERMハンドラで後始末する子孫に猶予が実質0秒になって
# いた）。孤児対策自体（SIGKILLは無視できない）は変わらずwatchdogの
# 後続KILLが担う＝TERMをtrapで無視する設定はfork/exec越しに孫プロセスへ
# 継承されるため、group TERMだけでは孫が生き残ることが実測で確認された
# （検証3巡目 MAJOR #2の追加検証）。
# `run_with_deadline` は結果をコマンド置換で受け取らず、いったん一時ファイル
# （呼び出し後に大域変数 RWD_OUT_FILE で示す）へ書かせてから別文で `cat` する
# 2段構成にしている。理由: bash 3.2では、`set -m`で作ったバックグラウンド
# ジョブは、それがコマンド置換（`$(...)`。明示的な`( )`のみならず暗黙の
# サブシェルも含む）の中で作られた場合に限り、標準入力が黙って/dev/nullへ
# 差し替わる（実測で確認）。判定用jqはprompt JSONを標準入力から読む必要が
# あるため、`run_with_deadline`の呼び出し自体をコマンド置換で包めない。
# hook自身が外部（フック枠のtimeout等）からSIGTERM等で終了させられた場合
# でも、生成済みの一時ファイルと起動中の子プロセス群を清掃する
# （EXIT/HUP/INT/TERM trap。検証4巡目 MINOR #3）。trapのcleanup内で
# `exec 2>/dev/null` してから子をkillするのは、`set -m`下でシグナル
# 終了した子をwaitで回収する際にbashが出す「Killed: 9」通知（monitor
# モード特有。job control notificationとは別経路）がstderrへ漏れるのを
# 実測で確認したため（fail-silent要件を満たすための追加対策）。
# どの経路で失敗しても何も出力せず正常終了する（fail-silent・会話を妨げない）。

LIST_CMD="${NEXT_RESOLVE_LIST_CMD:-$HOME/work/takumi009-ai-env/cmux/cmux-next-model.sh}"

RWD_OUT_FILE=""
RWD_CMD_PID=""
RWD_WATCHDOG_PID=""
rwd_cleanup_on_signal() {
  exec 2>/dev/null
  [ -n "$RWD_CMD_PID" ] && kill -KILL -- "-$RWD_CMD_PID" 2>/dev/null
  [ -n "$RWD_WATCHDOG_PID" ] && kill -KILL -- "-$RWD_WATCHDOG_PID" 2>/dev/null
  wait 2>/dev/null
  [ -n "$RWD_OUT_FILE" ] && rm -f "$RWD_OUT_FILE" 2>/dev/null
  exit 0
}
trap rwd_cleanup_on_signal EXIT HUP INT TERM

# run_with_deadline N cmd... : cmdをプロセスグループで起動し、正常な
# 処理にはN秒まるごと使わせる。N秒でTERM、応答しなければ0.3秒後にKILL
# する（詳細はヘッダー参照）。標準出力はRWD_OUT_FILEに書く（呼び出し元が
# 読んでrmする）。コマンド置換で包まず、単独の文として呼ぶこと
# （ヘッダーのstdin継承の説明を参照）。
run_with_deadline() {
  local budget="$1"; shift
  local term_at="$budget"
  local grace="0.3"
  RWD_OUT_FILE=$(mktemp 2>/dev/null) || return 1
  set -m
  "$@" >"$RWD_OUT_FILE" 2>/dev/null &
  RWD_CMD_PID=$!
  (
    sleep "$term_at"
    kill -TERM -- "-$RWD_CMD_PID" 2>/dev/null
    sleep "$grace"
    kill -KILL -- "-$RWD_CMD_PID" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  RWD_WATCHDOG_PID=$!
  wait "$RWD_CMD_PID" 2>/dev/null
  local wait_rc=$?
  local rc
  if [ "$wait_rc" -ge 128 ]; then
    # シグナルで終了した（=deadlineのTERMが届いた）。watchdog自身の
    # 0.3秒後のKILLをそのまま待ち、TERMハンドラで後始末する子孫にも
    # 猶予0.3秒を与える（ここで追い打ちのKILLを送ると猶予が0秒になる。
    # 検証5巡目 MAJOR #2）。孤児対策（SIGKILLは無視できない）はwatchdog
    # 自身の後続KILLが担う。
    rc=1
    wait "$RWD_WATCHDOG_PID" 2>/dev/null
  else
    # deadline前に自然終了した（成功・失敗いずれも、シグナルではない）。
    # 残った子孫があれば即座に一掃してよい（もう誰も後始末していない）。
    if [ "$wait_rc" -eq 0 ]; then rc=0; else rc=1; fi
    kill -KILL -- "-$RWD_CMD_PID" 2>/dev/null
    kill -TERM -- "-$RWD_WATCHDOG_PID" 2>/dev/null
    wait "$RWD_WATCHDOG_PID" 2>/dev/null
  fi
  return $rc
}

MATCH_FILTER='
if (.prompt // null) == null or ((.prompt|type) != "string") then
  "no"
elif (.prompt | test("�")) then
  "no"
else
  .prompt as $p
  | if ($p | test("番"))
       and (
         ($p | test("(?<![A-Za-z0-9_])project(?![A-Za-z0-9_])"; "i"))
         or ($p | test("(?<![A-Za-z0-9_])プロジェクト(?![A-Za-z0-9_])(?!\\p{Han})"))
       )
    then "yes"
    else "no"
    end
end
'

# jqはstdinを直接読む（bash変数を経由させない＝NULが落ちない。ヘッダー
# 参照）。run_with_deadlineをコマンド置換で包まないことで、"$@"のstdin
# 継承を壊さない。
run_with_deadline 1 jq -r "$MATCH_FILTER"
match_rc=$?
match=$(cat "$RWD_OUT_FILE" 2>/dev/null)
rm -f "$RWD_OUT_FILE" 2>/dev/null
[ "$match_rc" -eq 0 ] || exit 0
[ "$match" = "yes" ] || exit 0

[ -x "$LIST_CMD" ] || exit 0

# LIST_CMD呼び出しと最終jq -nの両方をrun_with_deadlineの締切内に置く
# （どちらかがハングしても打ち切られるようにする。検証2巡目でjq -nを
# 締切の外に置いていた反省を反映）。
emit_context() {
  local list
  list=$("$LIST_CMD" --list 2>/dev/null) || return 1
  [ -n "$list" ] || return 1
  jq -n --arg ctx "Project番号対応表（この瞬間の表示順。ユーザーの「Project の N 番」はこの表で解決する）:
$list" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
}

run_with_deadline 2 emit_context
emit_rc=$?
out=$(cat "$RWD_OUT_FILE" 2>/dev/null)
rm -f "$RWD_OUT_FILE" 2>/dev/null
[ "$emit_rc" -eq 0 ] || exit 0
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
