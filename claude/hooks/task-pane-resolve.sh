#!/bin/bash
# Taskペイン番号参照の自動解決フック（UserPromptSubmit）
# 新設（cmux-session-todo v2「Task の番号対応」・本人指示 2026-09-14 19:45で
# Dock枠名からNextを外しProject/Taskにした。設計中の旧称はnext-task-resolve.sh
# だったが、Dock枠名の改称に合わせtask-pane-resolve.shへ改称した）。
# プロンプトに「Task／タスク」（表記ゆれ）＋「番」の両方が含まれるとき、
# cmux-task-model.sh --list（v4・5列＝版番号<TAB>版名<TAB>分数<TAB>状態<TAB>
# タスク本文。番号は版を指す）の出力を additionalContext として注入する。
# AI はツールを叩かずに番号→タスクを解決できる（正本: docs/design.md
# §22・§39.4.7・cmux-session-todo）。
# 発火条件は「Task」（大小文字非依存）または「タスク」を含み、かつ「番」を
# 含むことのみ。「Next」は発火語に要らない＝「Next Task の 3 番」はTask＋番を
# 含むので自然に発火する（後方互換）。「Tasks」（複数形）・「task_id」・
# 「subtask」・「タスク化」は語境界（後述）により発火しない。
# ②の機能は並行案件①（next-pane-resolve.sh・Project側）の適用状態に依存
# しない。両フックは互いを知らず独立に判定するので、1つのプロンプトが
# 両方の発火条件を満たせば両方が注入する（例:「Project の2番と Task の3番」）。
#
# 判定は prompt の生テキストをbash変数へ取り出さず jq 単体（Oniguruma正規表現・
# Unicode対応）で完結させる。理由: bashのコマンド置換はNULバイトを黙って
# 落とすため（bash 3.2 で実測）、bash変数を経由すると「タス\0ク」等が
# 区切り無しの「タスク」に化けて誤発火する。
# .prompt が文字列でない場合（object/array等）はJSON文字列化されて
# 誤発火しないよう型を検査する。
# .promptに不正なUTF-8バイト由来の置換文字（U+FFFD）が含まれる場合は
# 判定に使わず非発火にする（①の現物と同型のガード）＝jqは不正バイトを
# JSON解析エラーにはせずU+FFFDへ変換して読み進めるため、そのままだと
# 本来の語とは無関係な境界が生まれて過剰発火しうる（①側の検証5巡目
# MINOR #3で実測確認）。
# 語境界は①の現物と同型（後読み(?<![A-Za-z0-9_])・先読み(?![A-Za-z0-9_])と
# (?!\p{Han})）だが、発火語がTask／タスクの1語になったぶん、英語側・日本語側
# 双方に同じ1本の正規表現で境界を課す（①はProject／プロジェクトの表記が
# 語構成上非対称なため英日で正規表現を分けている。②は対称なので1本で足りる）。
# 空白の正規化（gsub）は入れない＝発火語が1語になった時点で区切り文字を
# 跨ぐ照合が無くなり、間の空白（全角空白含む）がどんな種類でも結果が
# 変わらないため（リーダー裁定Q5-2・2026-09-14で「外す」に確定。効果の無い
# 処理を置かない）。
#
# 時間予算（docs/design.md §22.4）: フック枠は5秒（settings.jsonのtimeout）。
# 外部プロセスを起こすのは判定用jq（run_with_deadline 1）とemit_context
# （run_with_deadline 2。LIST_CMD呼び出しと最終jq -nの両方を含む）の2箇所
# だけ。run_with_deadline <N> の意味は「正常な処理にN秒まるごと許し、
# TERMをN秒地点で送り、応答しなければ短い猶予（0.3秒）でKILLする」。
# 実質上限は判定用jq=1.3秒・emit_context=2.3秒・合計最大3.6秒（枠5秒に
# 対して1.4秒の余裕）。
# cmd・watchdog双方をプロセスグループ単位（bash 3.2の`set -m`でジョブ
# ごとに専用pgidを得る）でTERM→KILLする。プロセスグループ単位にする
# 理由は2つ＝(a) LIST_CMDが自分の中でさらに子プロセスを起こしても一括で
# 止められる、(b) watchdog自身の子（TERM待ちのsleep）を単独killすると
# 孤児化し、hook終了後もsleepだけ残り続ける不具合が①側の実測で確認された。
# cmd_pidがシグナルで終了した場合（deadlineのTERMが届いた場合）は
# watchdog自身の0.3秒後KILLをそのまま待ち、TERMハンドラで後始末する
# 子孫にも猶予0.3秒を与える。deadline前に自然終了した場合（成功・失敗
# 問わず、シグナルでない終了）だけ残存子孫へ即座にKILLを送る（①の現物と
# 同型＝①側の検証5巡目 MAJOR #2）。孤児対策自体（SIGKILLは無視できない）
# は変わらずwatchdogの後続KILLが担う＝TERMをtrapで無視する設定はfork/exec
# 越しに孫プロセスへ継承されるため、group TERMだけでは孫が生き残ることが
# ①側の実測で確認された。
# `run_with_deadline` は結果をコマンド置換で受け取らず、いったん一時ファイル
# （呼び出し後に大域変数 RWD_OUT_FILE で示す）へ書かせてから別文で `cat` する
# 2段構成にしている。理由: bash 3.2では、`set -m`で作ったバックグラウンド
# ジョブは、それがコマンド置換（`$(...)`。明示的な`( )`のみならず暗黙の
# サブシェルも含む）の中で作られた場合に限り、標準入力が黙って/dev/nullへ
# 差し替わる（①側の実測で確認・
# Knowledge/macos-bash32-hook-constraints.md）。判定用jqはprompt JSONを
# 標準入力から読む必要があるため、`run_with_deadline`の呼び出し自体を
# コマンド置換で包めない。
# hook自身が外部（フック枠のtimeout等）からSIGTERM等で終了させられた場合
# でも、生成済みの一時ファイルと起動中の子プロセス群を清掃する
# （EXIT/HUP/INT/TERM trap）。trapのcleanup内で`exec 2>/dev/null`してから
# 子をkillするのは、`set -m`下でシグナル終了した子をwaitで回収する際に
# bashが出す「Killed: 9」通知（monitorモード特有）がstderrへ漏れるのを
# ①側の実測で確認したため（fail-silent要件を満たすための追加対策）。
# どの経路で失敗しても何も出力せず正常終了する（fail-silent・会話を妨げない）。

LIST_CMD="${TASK_RESOLVE_LIST_CMD:-$HOME/work/takumi009-ai-env/cmux/cmux-task-model.sh}"

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
    # ①側の検証5巡目 MAJOR #2）。孤児対策（SIGKILLは無視できない）は
    # watchdog自身の後続KILLが担う。
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
       and ($p | test("(?<![A-Za-z0-9_])(?:task|タスク)(?![A-Za-z0-9_])(?!\\p{Han})"; "i"))
    then "yes" else "no" end
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
# （どちらかがハングしても打ち切られるようにする）。CMUX_TASK_CALL_TIMEOUT=1は
# このLIST_CMD呼び出し1回だけに効かせる（exportしない。手で--listを叩く
# ときの既定5秒を変えない）。
emit_context() {
  local list
  list="$(CMUX_TASK_CALL_TIMEOUT=1 "$LIST_CMD" --list 2>/dev/null)" || return 1
  [ -n "$list" ] || return 1
  jq -n --arg ctx "Task番号対応表（番号は版を指す・この瞬間の表示順。ユーザーの「Task の N 番」は同じ番号の行の版で解決する。列＝番号・版名・分数・状態・本文）:
$list" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
}

run_with_deadline 2 emit_context
emit_rc=$?
out=$(cat "$RWD_OUT_FILE" 2>/dev/null)
rm -f "$RWD_OUT_FILE" 2>/dev/null
[ "$emit_rc" -eq 0 ] || exit 0
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
exit 0
