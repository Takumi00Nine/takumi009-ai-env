#!/usr/bin/env bash
# セッション引き継ぎ CLI。
#
# 長くなったセッションを区切るとき、再開メモを書いたあと本スクリプトで
# 新しい cmux ワークスペースを開き、cct（Claude Code）を起動して続きの
# 依頼を1行で投入する。手動手順の原型＝Fragments/2026-09/2026-09-16.md
# 「手動引き継ぎ 実測 成功」。cmux の send/send-key の仕様は
# Knowledge/cmux-cli-reference.md 参照（送信は send と send-key Enter を
# 分ける必要がある＝末尾に \r を付けても送信されない）。
#
#   session-handoff.sh <再開メモのパス> "<続きの依頼>" [--cwd <dir>] [--name <題>]
#   session-handoff.sh -h | --help
#
# 引数は最初の2個を必須位置引数として先に取り、その後だけオプションを
# 解析する（検証1巡目 #1: 依頼文が "-" で始まっても不明オプション扱いに
# しない）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

CMUX_BIN="${SESSION_HANDOFF_CMUX_BIN:-cmux}"
WAIT_SEC="${SESSION_HANDOFF_WAIT_SEC:-60}"
GRACE_SEC="${SESSION_HANDOFF_GRACE_SEC:-5}"
SEND_GAP_SEC="${SESSION_HANDOFF_SEND_GAP_SEC:-1}"
CALL_TIMEOUT_SEC="${SESSION_HANDOFF_CALL_TIMEOUT_SEC:-5}"

print_usage() {
  cat <<'EOF'
使い方:
  session-handoff.sh <再開メモのパス> "<続きの依頼>" [--cwd <dir>] [--name <題>]
  session-handoff.sh -h | --help

引数（最初の2個。この2つはオプションより先に解釈する）:
  <再開メモのパス>  存在し読める通常ファイル（先頭の ~/ は $HOME へ展開して
                    絶対パスへ正規化する。正規化後の絶対パスに改行(LF/CR)を
                    含む場合は拒否する）
  <続きの依頼>      空でない1行（改行(LF/CR)を含められない。"-" で始まって
                    もよい＝オプションとして解釈しない）

オプション:
  --cwd <dir>   新しいワークスペースの作業ディレクトリ（既定: 呼び出し時の $PWD）
  --name <題>   新しいワークスペースの題（既定:「引き継ぎ <再開メモのファイル名
                （拡張子 .md なし）>」）
  -h, --help    この使い方を表示して終了

環境変数（既定値）:
  SESSION_HANDOFF_CMUX_BIN       cmux コマンド（既定: cmux）
  SESSION_HANDOFF_WAIT_SEC       プロンプト（❯）待ちの実時間の上限秒（既定: 60・
                                  非負整数。0は「即時に1回だけポーリングする」
                                  例外として扱う）
  SESSION_HANDOFF_GRACE_SEC      プロンプト検出後の猶予秒（既定: 5・非負整数）
  SESSION_HANDOFF_SEND_GAP_SEC   send と send-key Enter の間隔秒（既定: 1・非負整数）
  SESSION_HANDOFF_CALL_TIMEOUT_SEC  read-screen 1回あたりの呼出しタイムアウト秒
                                     （既定: 5・1以上の整数。応答が無いcmuxで
                                     ハングし続けないための上限。WAIT_SECの
                                     残り時間より長くは待たない＝実際の上限は
                                     min(この値, 残り時間)）
  上記のうちWAIT_SEC・GRACE_SEC・SEND_GAP_SECの3つはテスト高速化のため 0 を
  指定できる（非負整数以外は拒否）。CALL_TIMEOUT_SECは0にすると即時応答の
  cmuxでも打ち切りと競合しうるため1以上の整数だけを受理する（「0指定可」
  には含めない）。
  SESSION_HANDOFF_CMUX_BIN はコマンド名／パスなので 0 を指定しても動作しない。

終了コード:
  0=送信完了 1=引数不正（cmux は一切呼ばない） 2=new-workspace 失敗
  3=プロンプト待ちタイムアウト（ワークスペースは閉じない） 4=送信失敗
EOF
}

# 単独の -h/--help は環境変数の妥当性に関係なくusageを表示して終了する
# （検証2巡目 #1: 不正な環境変数の下でも --help は使える必要がある）。
if [ $# -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  print_usage
  exit 0
fi

is_nonneg_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

if ! is_nonneg_int "$WAIT_SEC"; then
  echo "SESSION_HANDOFF_WAIT_SEC は非負整数で指定してください: $WAIT_SEC" >&2
  print_usage >&2
  exit 1
fi
if ! is_nonneg_int "$GRACE_SEC"; then
  echo "SESSION_HANDOFF_GRACE_SEC は非負整数で指定してください: $GRACE_SEC" >&2
  print_usage >&2
  exit 1
fi
if ! is_nonneg_int "$SEND_GAP_SEC"; then
  echo "SESSION_HANDOFF_SEND_GAP_SEC は非負整数で指定してください: $SEND_GAP_SEC" >&2
  print_usage >&2
  exit 1
fi
# CALL_TIMEOUT_SECは0を許すと即時応答のcmuxでも sleep 0 のwatcherと競合し
# うる（検証3巡目 #3）ため、他の3つと違い1以上の整数だけを受理する。
if ! is_nonneg_int "$CALL_TIMEOUT_SEC" || [ "$CALL_TIMEOUT_SEC" -lt 1 ]; then
  echo "SESSION_HANDOFF_CALL_TIMEOUT_SEC は1以上の整数で指定してください: $CALL_TIMEOUT_SEC" >&2
  print_usage >&2
  exit 1
fi

# ==========================================================================
# 引数解析（最初の2個＝必須位置引数。依頼文が "-" で始まってもよい＝
# 検証1巡目 #1）
# ==========================================================================
if [ $# -lt 2 ]; then
  print_usage >&2
  exit 1
fi

note_arg="$1"
task_arg="$2"
shift 2

cwd_opt=""
name_opt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        print_usage >&2
        exit 1
      fi
      cwd_opt="$2"
      shift 2
      ;;
    --name)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        print_usage >&2
        exit 1
      fi
      name_opt="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      print_usage >&2
      exit 1
      ;;
  esac
done

# 先頭の ~/ を $HOME へ展開する。
case "$note_arg" in
  "~/"*)
    note_arg="$HOME/${note_arg#\~/}"
    ;;
  "~")
    note_arg="$HOME"
    ;;
esac

if [ -z "$note_arg" ] || [ ! -f "$note_arg" ] || [ ! -r "$note_arg" ]; then
  echo "再開メモが読めません（存在し読める通常ファイルであること）: $note_arg" >&2
  print_usage >&2
  exit 1
fi

note_dir="$(cd -P "$(dirname "$note_arg")" 2>/dev/null && pwd)"
if [ -z "$note_dir" ]; then
  echo "再開メモのディレクトリを解決できません: $note_arg" >&2
  print_usage >&2
  exit 1
fi
note_abs="$note_dir/$(basename "$note_arg")"

# 正規化後の絶対パスにも改行検査を行う（検証1巡目 #7: Unixでは通常
# ファイル名にLF/CRを含められるため、依頼文だけの検査では送信文が
# 複数行化しうる）。
case "$note_abs" in
  *$'\n'*|*$'\r'*)
    echo "再開メモの絶対パスに改行を含められません: $note_abs" >&2
    print_usage >&2
    exit 1
    ;;
esac

if [ -z "$task_arg" ]; then
  echo "続きの依頼が空です。" >&2
  print_usage >&2
  exit 1
fi
case "$task_arg" in
  *$'\n'*|*$'\r'*)
    echo "続きの依頼に改行を含められません（1行で指定してください）。" >&2
    print_usage >&2
    exit 1
    ;;
esac

cwd_dir="${cwd_opt:-$PWD}"
if [ ! -d "$cwd_dir" ]; then
  echo "作業ディレクトリが存在しません: $cwd_dir" >&2
  print_usage >&2
  exit 1
fi
cwd_dir="$(cd -P "$cwd_dir" 2>/dev/null && pwd)"
if [ -z "$cwd_dir" ]; then
  echo "作業ディレクトリを解決できません: ${cwd_opt:-$PWD}" >&2
  print_usage >&2
  exit 1
fi

if [ -z "$name_opt" ]; then
  base="$(basename "$note_abs")"
  base="${base%.md}"
  name_opt="引き継ぎ $base"
fi

message="再開メモ ${note_abs} を全文読んでから続きをお願いします。${task_arg}"

# ==========================================================================
# a. 新規ワークスペースを開いて cct を起動する
# ==========================================================================
out="$(CMUX_QUIET=1 "$CMUX_BIN" new-workspace --name "$name_opt" --cwd "$cwd_dir" --command "cct" --focus true)"
rc=$?
ref=""
if [ "$rc" -eq 0 ]; then
  # 「OK workspace:N」の完全一致行がちょうど1行あるときだけREFを採用する
  # （検証1巡目 #2: 余分・複数・形式違反な出力からの誤REF採用を防ぐ）。
  match_lines="$(printf '%s\n' "$out" | grep -xE 'OK workspace:[0-9]+')"
  match_count="$(printf '%s\n' "$match_lines" | grep -c . || true)"
  if [ "$match_count" -eq 1 ]; then
    ref="${match_lines#OK }"
  fi
fi
if [ "$rc" -ne 0 ] || [ -z "$ref" ]; then
  echo "新規ワークスペースの作成に失敗しました（cmux new-workspace の応答が不正です）。" >&2
  exit 2
fi

# ==========================================================================
# b. プロンプト（❯）を待つ。行頭のプロンプトだけを認め（検証1巡目 #3）、
#    read-screenが非0終了した回の出力は判定に使わず、失敗しても上限時間
#    までは再試行する（検証1巡目 #4）。上限はイテレーション回数ではなく
#    実時間（date +%s）で判定し、read-screen 1回ごとに呼出しタイムアウト
#    を設けてハングしても止まらないようにする（検証2巡目 #4）。呼出し
#    タイムアウトはCALL_TIMEOUT_SECそのものではなく「残り時間」でも
#    上限を掛け（最小1秒）、WAIT_SECを実時間の上限として厳密に守る
#    （検証3巡目 #1）。
# ==========================================================================
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'
}

is_prompt_present() {
  printf '%s\n' "$1" | strip_ansi | grep -qE '^[[:space:]]*❯'
}

# 複製元: cmux/lib-model-view.sh の run_with_timeout（検証2巡目 #4）。
# 相手lib一式をsourceすると他関数の依存（jq等）を持ち込むため、本関数だけ
# 最小限で複製する（複製の理由・追随の要否は同libのコメントに準じる。
# ⚠️複製元 lib-model-view.sh は本スクリプトの担当外のため直さない＝
# 検証3巡目 #2 の指摘は本関数側にだけ反映する）。
# "$@" をプロセスグループごと起動し、$1 秒でタイムアウトさせる
# （TERM→1秒猶予→KILL方式）。返り値はコマンドの終了コード。打ち切られた
# ときは非0。TERMを無視する子孫がいても、watcherを止める前にコマンド側
# プロセスグループへ改めてKILLを送って掃除する（検証3巡目 #2: コマンド
# 自身がTERMで先に終了すると、以後のwatcherのKILLが届かないまま停止させ
# られ、TERMを無視した子孫だけが生き残ることがある）。
run_with_timeout() {
  local secs="$1"
  shift
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  [ "$had_monitor" = "1" ] || set +m
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -KILL "-$cmd_pid" 2>/dev/null
  kill -TERM "-$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return "$rc"
}

deadline=$(( $(date +%s) + WAIT_SEC ))
prompt_found=0
last_read_screen_rc=0
first_attempt=1
while :; do
  if [ "$first_attempt" -ne 1 ]; then
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      break
    fi
    sleep 1
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      break
    fi
  fi
  first_attempt=0
  now="$(date +%s)"
  remaining=$(( deadline - now ))
  call_timeout="$CALL_TIMEOUT_SEC"
  if [ "$remaining" -lt "$call_timeout" ]; then
    call_timeout="$remaining"
  fi
  if [ "$call_timeout" -lt 1 ]; then
    call_timeout=1
  fi
  screen="$(run_with_timeout "$call_timeout" "$CMUX_BIN" read-screen --workspace "$ref" 2>/dev/null)"
  read_rc=$?
  if [ "$read_rc" -eq 0 ]; then
    if is_prompt_present "$screen"; then
      prompt_found=1
      break
    fi
  else
    last_read_screen_rc="$read_rc"
  fi
done

if [ "$prompt_found" -ne 1 ]; then
  if [ "$last_read_screen_rc" -ne 0 ]; then
    echo "プロンプトが出ません: ${ref}（最後の失敗理由: read-screen が終了コード ${last_read_screen_rc} で失敗）" >&2
  else
    echo "プロンプトが出ません: $ref" >&2
  fi
  exit 3
fi

# ==========================================================================
# c. 起動注入（SessionStart フック等）の完了を待つ猶予
# ==========================================================================
sleep "$GRACE_SEC"

# ==========================================================================
# d. 依頼文を送る（末尾に \r・改行を付けない。送信は send-key Enter で行う。
#    stdoutは捨てる＝検証1巡目 #6）
# ==========================================================================
"$CMUX_BIN" send --workspace "$ref" -- "$message" >/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "依頼文の送信に失敗しました（cmux send）: $ref" >&2
  exit 4
fi

# ==========================================================================
# e. Enter を送って送信を確定する（stdoutは捨てる）
# ==========================================================================
sleep "$SEND_GAP_SEC"
"$CMUX_BIN" send-key --workspace "$ref" Enter >/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "Enter 送出に失敗しました（cmux send-key）: $ref" >&2
  exit 4
fi

# ==========================================================================
# f. 完了報告（stdoutはこの2行だけ＝検証1巡目 #6）
# ==========================================================================
printf 'REF=%s\n' "$ref"
printf 'SENT=%s\n' "$message"
exit 0
