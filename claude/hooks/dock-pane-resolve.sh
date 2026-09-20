#!/bin/bash
# Dock（Project／Task）ペイン番号参照の自動解決フック（UserPromptSubmit）。
# 旧 next-pane-resolve.sh（Project側）と task-pane-resolve.sh（Task側）を
# 1本に統合した（2026-09-19 着手順5 σ・設計 docs/design-step5.md §3）。
# プロンプトに「番」と、「Project／プロジェクト」または「Task／タスク」
# （表記ゆれ・大小文字非依存）が含まれるとき、cmux-next-model.sh --list
# （v5・5列＝番号<TAB>正式プロジェクト名<TAB>next値<TAB>区分（稼働中／待ち／
# 保留）<TAB>待ち日時）／cmux-task-model.sh
# --list（v4・5列＝版番号<TAB>版名<TAB>分数<TAB>状態<TAB>タスク本文）の出力を
# 1つの additionalContext として注入する（Project表→空行→Task表の順・
# 発火した側だけ。片方の --list が失敗・空ならその表だけ落とし、もう片方
# だけ出す。両方失敗＝無出力 exit 0）。AI はツールを叩かずに番号→
# プロジェクト／タスクを解決できる。
# 発火語の判定は旧2フックから不変＝Project側は英日2本（英: 前後がASCII
# 英数字・アンダースコアで挟まれた語の一部〈Projects/Projector〉は対象外。
# 日: 同じASCII境界＋直後に漢字が続く複合語〈プロジェクト化〉は対象外。
# 「の」等の平仮名の助詞は対象内のまま）、Task側は英日対称なので1本
# （Tasks・task_id・subtask・タスク化は語境界で非発火）。「番」は数字が
# 隣接しなくても文字そのものの有無だけを見る（「何番」「３番」も対象内）。
# .promptに不正なUTF-8バイト由来の置換文字（U+FFFD）が含まれる場合は
# 判定に使わず非発火にする＝jqは不正バイトをJSON解析エラーにはせず
# U+FFFDへ変換して読み進めるため、そのままだと本来の語とは無関係な
# 境界が生まれて過剰発火する（旧①検証5巡目 MINOR #3で実測確認）。
# 判定は prompt の生テキストをbash変数へ取り出さず jq 単体（Oniguruma正規表現・
# Unicode対応）で完結させる。理由: bashのコマンド置換はNULバイトを黙って
# 落とすため（bash 3.2 で実測）、bash変数を経由すると「Pro\0ject」等が
# 区切り無しの「Project」に化けて誤発火する（旧①検証1巡目 MINOR #8）。
# .prompt が文字列でない場合（object/array等）は
# JSON文字列化されて誤発火しないよう型を検査する（旧①検証1巡目 MAJOR #4）。
#
# 時間予算（設計 §3.2）: フック枠は8秒（settings.jsonのtimeout・旧2本は各5秒）。
# 外部プロセスを起こすのは判定用jq（run_with_deadline 1）→Project表
# （run_with_deadline 2）→Task表（run_with_deadline 2）の直列3箇所だけで、
# 発火した側だけ走る。run_with_deadline <N> の意味は「正常な処理にN秒
# まるごと許し、TERMをN秒地点で送り、応答しなければ短い猶予（0.3秒）で
# KILLする」（旧①検証4巡目 MAJOR #1＝旧実装はTERMをN-1秒で送っており、
# 正常な遅い処理まで打ち切っていた。TERMの時刻を「正常処理に許す時間」の
# 意味に統一した）。実質上限は判定用jq=1.3秒・各表=2.3秒・両語同時発火の
# 合計最大5.9秒（枠8秒に対して2.1秒の余裕）。片方だけの発火は旧と同じ
# 最大3.6秒。CMUX_TASK_CALL_TIMEOUT=1 はTask側の --list 呼び出し1回だけに
# 効かせる（exportしない。手で--listを叩くときの既定5秒を変えない）。
# cmd・watchdog双方をプロセスグループ単位（bash 3.2の`set -m`でジョブ
# ごとに専用pgidを得る）でTERM→KILLする。プロセスグループ単位にする
# 理由は2つ＝(a) LIST_CMDが自分の中でさらに子プロセスを起こしても一括で
# 止められる、(b) watchdog自身の子（TERM待ちのsleep）を単独killすると
# 孤児化し、hook終了後もsleepだけ残り続ける不具合が実測で確認された
# （旧①検証3巡目 MAJOR #2）。cmd_pidがシグナルで終了した場合（deadlineの
# TERMが届いた場合）はwatchdog自身の0.3秒後KILLをそのまま待ち、TERM
# ハンドラで後始末する子孫にも猶予0.3秒を与える。deadline前に自然終了
# した場合（成功・失敗問わず、シグナルでない終了）だけ残存子孫へ即座に
# KILLを送る（旧①検証5巡目 MAJOR #2）。孤児対策自体（SIGKILLは無視
# できない）は変わらずwatchdogの後続KILLが担う＝TERMをtrapで無視する設定は
# fork/exec越しに孫プロセスへ継承されるため、group TERMだけでは孫が生き残る
# ことが実測で確認された（旧①検証3巡目 MAJOR #2の追加検証）。
# `run_with_deadline` は結果をコマンド置換で受け取らず、いったん一時ファイル
# （呼び出し後に大域変数 RWD_OUT_FILE で示す）へ書かせてから別文で `cat` する
# 2段構成にしている。理由: bash 3.2では、`set -m`で作ったバックグラウンド
# ジョブは、それがコマンド置換（`$(...)`。明示的な`( )`のみならず暗黙の
# サブシェルも含む）の中で作られた場合に限り、標準入力が黙って/dev/nullへ
# 差し替わる（実測で確認・Knowledge/macos-bash32-hook-constraints.md）。
# 判定用jqはprompt JSONを標準入力から読む必要があるため、
# `run_with_deadline`の呼び出し自体をコマンド置換で包めない。
# 各表はLIST_CMD呼び出しとJSON文字列化（jq -Rs .）の両方を締切内に置き
# （どちらかがハングしても打ち切られる）、最終のJSON組み立ては外部
# プロセスを起こさない文字列連結だけにする＝締切の外にjqを置かない。
# hook自身が外部（フック枠のtimeout等）からSIGTERM等で終了させられた場合
# でも、生成済みの一時ファイルと起動中の子プロセス群を清掃する
# （EXIT/HUP/INT/TERM trap。旧①検証4巡目 MINOR #3）。trapのcleanup内で
# `exec 2>/dev/null` してから子をkillするのは、`set -m`下でシグナル
# 終了した子をwaitで回収する際にbashが出す「Killed: 9」通知（monitor
# モード特有。job control notificationとは別経路）がstderrへ漏れるのを
# 実測で確認したため（fail-silent要件を満たすための追加対策）。
# どの経路で失敗しても何も出力せず正常終了する（fail-silent・会話を妨げない）。

PROJECT_LIST_CMD="${NEXT_RESOLVE_LIST_CMD:-$HOME/work/takumi009-ai-env/cmux/cmux-next-model.sh}"
TASK_LIST_CMD="${TASK_RESOLVE_LIST_CMD:-$HOME/work/takumi009-ai-env/cmux/cmux-task-model.sh}"

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

# 判定は1回＝"no"／"project"／"task"／"both" の4値。型検査・U+FFFD検査・
# 「番」必須は共通前段。Project側の英日2本・Task側の1本の正規表現は旧2フック
# のまま。
MATCH_FILTER='
if (.prompt // null) == null or ((.prompt|type) != "string") then
  "no"
elif (.prompt | test("�")) then
  "no"
else
  .prompt as $p
  | if ($p | test("番")) | not then "no"
    else
      (
        ($p | test("(?<![A-Za-z0-9_])project(?![A-Za-z0-9_])"; "i"))
        or ($p | test("(?<![A-Za-z0-9_])プロジェクト(?![A-Za-z0-9_])(?!\\p{Han})"))
      ) as $proj
      | ($p | test("(?<![A-Za-z0-9_])(?:task|タスク)(?![A-Za-z0-9_])(?!\\p{Han})"; "i")) as $task
      | if $proj and $task then "both"
        elif $proj then "project"
        elif $task then "task"
        else "no"
        end
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
case "$match" in
  project|task|both) ;;
  *) exit 0 ;;
esac

# emit_table project|task : 該当側のLIST_CMDを呼び、見出し固定文＋表を
# JSON文字列リテラル（jq -Rs .）にして標準出力へ書く。LIST_CMD呼び出しと
# jqの両方をrun_with_deadlineの締切内に置く（旧①検証2巡目でjqを締切の外に
# 置いていた反省を反映）。失敗・空出力はreturn 1（その表だけ落ちる）。
emit_table() {
  local list heading
  if [ "$1" = "project" ]; then
    list=$("$PROJECT_LIST_CMD" --list 2>/dev/null) || return 1
    heading='Project番号対応表（この瞬間の表示順。ユーザーの「Project の N 番」はこの表で解決する。列＝番号・正式プロジェクト名・next 値・区分（稼働中／待ち／保留）・待ち日時（待ちの行だけ YYYY-MM-DDTHH:MM・他は空））:'
  else
    list="$(CMUX_TASK_CALL_TIMEOUT=1 "$TASK_LIST_CMD" --list 2>/dev/null)" || return 1
    heading='Task番号対応表（番号は版を指す・この瞬間の表示順。ユーザーの「Task の N 番」は同じ番号の行の版で解決する。列＝番号・版名・分数・状態・本文）:'
  fi
  [ -n "$list" ] || return 1
  printf '%s\n%s' "$heading" "$list" | jq -Rs .
}

# collect_table project|task : 発火した側の表を締切2秒で集め、JSON文字列
# リテラルを大域変数 TABLE_JSON に置く（失敗・非該当は空）。
collect_table() {
  local side="$1" cmd rc
  TABLE_JSON=""
  case "$match" in "$side"|both) ;; *) return 0 ;; esac
  if [ "$side" = "project" ]; then cmd="$PROJECT_LIST_CMD"; else cmd="$TASK_LIST_CMD"; fi
  [ -x "$cmd" ] || return 0
  run_with_deadline 2 emit_table "$side"
  rc=$?
  TABLE_JSON=$(cat "$RWD_OUT_FILE" 2>/dev/null)
  rm -f "$RWD_OUT_FILE" 2>/dev/null
  [ "$rc" -eq 0 ] || TABLE_JSON=""
  case "$TABLE_JSON" in \"*\") ;; *) TABLE_JSON="" ;; esac
}

collect_table project
project_json="$TABLE_JSON"
collect_table task
task_json="$TABLE_JSON"

# 最終のJSON組み立ては文字列連結だけ（外部プロセス無し）。両表あるときは
# Project表→空行→Task表＝2つのJSON文字列リテラルを「\n\n」で継ぐ
# （前者の末尾の引用符と後者の先頭の引用符を落として1つのリテラルにする）。
if [ -n "$project_json" ] && [ -n "$task_json" ]; then
  ctx="${project_json%\"}\\n\\n${task_json#\"}"
elif [ -n "$project_json" ]; then
  ctx="$project_json"
elif [ -n "$task_json" ]; then
  ctx="$task_json"
else
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ctx"
exit 0
