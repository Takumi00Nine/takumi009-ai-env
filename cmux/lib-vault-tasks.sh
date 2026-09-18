# Vault Projects ノートの frontmatter 抽出と Tasks 節パーサ（Vault 読み取りの
# 共通部品）。cmux-task-watch.sh（新規・Tasks 節から表示モデルを作る）と
# cmux-next-watch.sh（既存・next: 導出の拡張で fm_extract を直接使う）の
# 両方から source される。単体では実行しない（関数定義のみ、副作用なし）。
# lib は環境変数を読まない。
#
# 公開入口は read_note <path> の1つだけ（Tasks 節の解析について。frontmatter
# の値を取るための fm_extract 直接呼び出しは、既存 cmux-next-watch.sh の
# 互換経路として別に残る＝cmux-session-todo 設計 §1.4・§5.3・§15 I-5）。
# parse_tasks は read_note 経由でのみ呼ぶ（サニタイズ済みストリームだけを
# 受け取れる型の関数のため。設計 §5.1）。
#
# 使い方:
#   LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)"
#   . "$LIB_DIR/lib-vault-tasks.sh"
#   . "$LIB_DIR/lib-model-view.sh"   # read_note が sanitize_lines に依存する

# frontmatter ブロックを stdin から読み、抽出して stdout へ出す。入力は
# 生でもサニタイズ済みでもよい（判定は "---" と行数だけ）。1行目が "---"
# でない、または60行以内に閉じないなら終了コード1（既存
# cmux-next-watch.sh の fm_extract と同じ判定基準・stdin 版）。
fm_extract() {
  awk '
    NR==1 { if ($0 != "---") { exit 1 } ; next }
    /^---$/ { found=1; exit 0 }
    NR>60 { exit 1 }
    { print }
    END { if (!found) exit 1 }
  ' 2>/dev/null
}

# frontmatter ブロック文字列 $1 から key "$2" の値を1つ取り出す（複数行
# キーの2件目以降は無視・grep -m1）。前後空白・前後が揃った引用符（"…" /
# '…'）を剥がす（既存 cmux-next-watch.sh の fm_field と同一）。
fm_field() {
  local block="$1" key="$2" raw val
  raw="$(printf '%s\n' "$block" | grep -m1 "^${key}:" | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]+\$//")"
  val="$raw"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

# Tasks 節を stdin から読み、TSV ストリームを stdout へ出す（設計 §5.2）。
# 入力はサニタイズ済みストリームでなければならない（生を渡してはいけない
# ＝型の前提。単独では呼ばず read_note 経由で使う）。常に終了コード0。
#
# 出力の行:
#   V<TAB><版名>
#   T<TAB><状態1文字><TAB><タスク本文>
#
# 判定規則（§5.2）:
#   Tasks 節の開始: ^##[ \t]+Tasks[ \t]*$
#   Tasks 節の終了: 次の ^#[ \t] または ^##[ \t]（別の節）／EOF
#   版          : 節の中の ^###[ \t]+(.*)$。版名は前後空白を trim
#   タスク       : 版の中の ^- \[[ /x]\]。本文は7バイト目以降を trim
# 版の見出しより前に並ぶチェックリストはタスクとして数えない（FR-1・V-3）。
# インデントされた行・[X] のような大文字は数えない（^ 始まりの厳密一致・
# 文字クラスに大文字 X を含めないことで自然に除外される＝FR-2）。
# 同じ版名が複数あっても記載順に別の版として出す（FR-36 ②・V-13）。
parse_tasks() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { state = 0 }   # 0=Tasks節の前 1=Tasks節・版なし 2=Tasks節・版あり 3=Tasks節終了後
    {
      if (state == 0) {
        if ($0 ~ /^##[ \t]+Tasks[ \t]*$/) { state = 1 }
        next
      }
      if (state == 3) { next }
      if ($0 ~ /^#[ \t]/ || $0 ~ /^##[ \t]/) { state = 3; next }
      if (match($0, /^###[ \t]+/)) {
        name = trim(substr($0, RLENGTH + 1))
        print "V\t" name
        state = 2
        next
      }
      if (state == 2 && $0 ~ /^- \[[ \/x]\]/) {
        st = substr($0, 4, 1)
        body = trim(substr($0, 7))
        print "T\t" st "\t" body
        next
      }
      # state==1（版なし）の行・上記に当たらない行はタスクとして数えない
    }
  '
  return 0
}

# C-4 の公開入口。ファイルパス $1 を読み、sanitize_lines → fm_extract →
# parse_tasks の順に通して TSV ストリームを stdout へ出す（設計 §1.4・
# v4差分＝design.md §39.4.2・D-v4-12）。先頭に frontmatter の next: 値を
# 「N<TAB><値>」の1行として出す（next: が無い／空でも常に1行出す。値は空
# でもよい）。既存の消費者（cmux-next-model.sh の derive_next_from_tasks）は
# `$1 == "T"` だけを読むので N 行は自然に無視される（grep実測で消費者は
# cmux-task-model.sh と cmux-next-model.sh の2件だけ）。
# 終了コード: 0=成功／2=サニタイズ失敗またはframontmatter不正（呼び出し側は
# 「ノート破損」として扱う）。ファイルの存在確認は呼び出し側が先に行う。
# サニタイズ結果を一度シェル変数へ受けてから複数回使う（一時ファイルを
# 作らない。U+0000 はこの時点で空白に置換済みなので、変数へ入れても
# 切り詰められない）。
read_note() {
  local clean fm rc nextval
  clean="$(sanitize_lines <"$1")" || return 2          # jq 失敗＝ノート破損
  fm="$(printf '%s\n' "$clean" | fm_extract)"
  rc=$?
  [ "$rc" -eq 0 ] || return 2                          # frontmatter 不正＝ノート破損
  nextval="$(fm_field "$fm" next)"
  printf 'N\t%s\n' "$nextval"
  printf '%s\n' "$clean" | parse_tasks                 # TSV を stdout へ
}
