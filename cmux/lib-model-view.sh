# 供給側（ai-env）が使う締切・サニタイズ・切り詰めの共通部品
# （cmux-session-todo 設計 §28.1 C-16・§30.6）。cmux-task-model.sh・
# cmux-next-model.sh・cmux-task-declare.sh・lib-cmux-workspace.sh・
# lib-vault-tasks.sh から source される。単体では実行しない（関数定義のみ、
# 副作用なし）。lib は環境変数を読まない。
#
# FR-87（相手リポジトリからの source を禁止）に従い、dotfiles
# cmux/lib-dock-view.sh の該当関数をこちらへ複製したもの（source ではない）。
# 各関数の直前に複製元・理由・追随の注記を置く（設計 §30.6 の固定形）。
#
# 使い方:
#   LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)"
#   . "$LIB_DIR/lib-model-view.sh"

# 複製元: Takumi00Nine/dotfiles cmux/lib-dock-view.sh の is_number
# 複製の理由: FR-87（相手リポジトリからの source を禁止）。守る対象が違う
#             （こちら＝供給側の数値検証／向こう＝描画側の数値検証）。
# 追随: 片方を直したらもう片方も同じ巡で直す。自動同期は無い（NFR-13）。
# $1 が非負整数（'' も含めて弾く）かどうかを判定する。
is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 複製元: Takumi00Nine/dotfiles cmux/lib-dock-view.sh の sanitize_interval
# 複製の理由: FR-87（相手リポジトリからの source を禁止）。守る対象が違う
#             （こちら＝供給側の呼び出し締切／向こう＝描画側の呼び出し締切）。
# 追随: 片方を直したらもう片方も同じ巡で直す。自動同期は無い（NFR-13）。
# $1 を数値とみなし、空・非数字・0 なら $2（既定値）を返す。
sanitize_interval() {
  local v="$1" default="$2"
  case "$v" in
    ''|*[!0-9]*|0) printf '%s' "$default" ;;
    *) printf '%s' "$v" ;;
  esac
}

# 複製元: Takumi00Nine/dotfiles cmux/lib-dock-view.sh の sanitize_str
# 複製の理由: FR-87（相手リポジトリからの source を禁止）。守る対象が違う
#             （こちら＝供給側の入力サニタイズ／向こう＝描画側の契約検証）。
# 追随: 片方を直したらもう片方も同じ巡で直す。自動同期は無い（NFR-13）。
# $1 を無害化する（既存 cmux-next-watch.sh の sanitize_str と同一挙動）。
sanitize_str() {
  printf '%s' "$1" | jq -Rsr 'gsub("[\u0001-\u001f\u007f-\u009f]"; " ")' 2>/dev/null
}

# 複製元: Takumi00Nine/dotfiles cmux/lib-dock-view.sh の sanitize_lines
# 複製の理由: FR-87（相手リポジトリからの source を禁止）。守る対象が違う
#             （こちら＝供給側の入力サニタイズ／向こう＝描画側の契約検証）。
# 追随: 片方を直したらもう片方も同じ巡で直す。自動同期は無い（NFR-13）。
# stdin の各行を無害化して stdout へ出す。U+0000〜U+001F と U+007F〜U+009F
# を U+0020 へ置換する（U+0000 を含む）。
sanitize_lines() {
  jq -Rr '
    [explode[] | if (. <= 31) or (. >= 127 and . <= 159) then 32 else . end] | implode
  ' 2>/dev/null
}

# 複製元: Takumi00Nine/dotfiles cmux/lib-dock-view.sh の truncate_plain
# 複製の理由: FR-87（相手リポジトリからの source を禁止）。守る対象が違う
#             （こちら＝next 導出値の15コードポイント切り詰め／向こう＝
#             描画側の表示切り詰め）。
# 追随: 片方を直したらもう片方も同じ巡で直す。自動同期は無い（NFR-13）。
# コードポイント数ベースで $2 に切り詰める（省略記号は付けない）。
# $2 <= 0 は空文字を返す。
truncate_plain() {
  local s="$1" n="$2"
  case "$n" in
    -*) case "${n#-}" in ''|*[!0-9]*) n=0 ;; esac ;;
    ''|*[!0-9]*) n=0 ;;
  esac
  if [ "$n" -le 0 ]; then
    printf ''
    return 0
  fi
  jq -Rr --argjson w "$n" '.[0:$w]' <<<"$s" 2>/dev/null
}

# 複製元: Takumi00Nine/dotfiles cmux/lib-dock-view.sh の run_with_timeout
# 複製の理由: FR-87（相手リポジトリからの source を禁止）。守る対象が違う
#             （こちら＝cmux 呼び出し用・CMUX_TASK_CALL_TIMEOUT／向こう＝
#             供給側呼び出し用・lib-supply-frame.sh の run_supply）。
# 追随: 片方を直したらもう片方も同じ巡で直す。自動同期は無い（NFR-13）。
#
# "$@" をプロセスグループごと起動し、$1 秒でタイムアウトさせる
# （TERM→1秒猶予→KILL 方式）。返り値は cmd の終了コード。打ち切られたときは
# 非0。満たす3性質（DT-9 で検査）:
#   ① 打ち切りが効く: ウォッチャー自身も set -m でプロセスグループ化する。
#   ② 常駐が死なない: kill は cmd・watcher 個別のプロセスグループにだけ
#      効かせ、呼び出し元（このシェル）を巻き込まない。
#   ③ 子孫が残らない: ウォッチャーとコマンドの両方をグループごと落とし、
#      ウォッチャーの sleep が孤児として残らないよう最後に wait する。
#      TERMを無視する子孫がいても、watcherを止める前にコマンド側
#      プロセスグループへ改めてKILLを送って掃除する（コマンド自身が
#      TERMで先に終了すると、以後のwatcherのKILLが届かないまま停止させ
#      られ、TERMを無視した子孫だけが生き残ることがあるため）。
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
