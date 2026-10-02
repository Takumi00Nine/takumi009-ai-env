# Vault Projects ノートの frontmatter 抽出と Tasks 節パーサ（Vault 読み取りの
# 共通部品）。cmux-task-watch.sh（新規・Tasks 節から表示モデルを作る）と
# cmux-next-watch.sh（既存・next: 導出の拡張で fm_extract を直接使う）の
# 両方から source される。単体では実行しない（関数定義のみ、副作用なし）。
# lib は環境変数を読まない（唯一の例外＝テスト専用の差し替え口
# CMUX_VAULT_TASKS_SANITIZE_FAIL・read_note の注記＝設計 §41 D-v6-14）。
#
# 公開入口は read_note <path>（Tasks 節の解析）と decide_current_version
# （▶ の版の決定＝v6・設計 §41.3.1 案 A・D-v6-1）の 2 つ（frontmatter の値を
# 取るための fm_extract 直接呼び出しは、既存 cmux-next-watch.sh の互換経路
# として別に残る＝cmux-session-todo 設計 §1.4・§5.3・§15 I-5）。
# parse_tasks は read_note 経由でのみ呼ぶ（サニタイズ済みストリームだけを
# 受け取れる型の関数のため。設計 §5.1）。
#
# v6（設計 §41.5）: 版の範囲内の行頭 `- wait_until:` 行を「版の待ち行」種別
# `W` で流し（値は前後 trim・引用符はまだ剥がさない）、▶ の版の決定規則
# （▶ を決めない条件＝版なし／タスクなし／空タスク／全版完了 → `[/]` →
# `next:` 完全一致 → 未完の 1 番）を decide_current_version の 1 か所に置く。
# Task 供給側（cmux-task-model.sh）と Project 供給側（cmux-next-model.sh）の
# 両方がこれを呼ぶ（FR-106 は構造で成立）。
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
# キーの2件目以降は無視＝最初の1件）。前後空白（[[:space:]]）・前後が揃った
# 引用符（"…" / '…'）を剥がす（既存 cmux-next-watch.sh の fm_field と同一の
# 結果）。v6 で builtin（read＋case＋パラメータ展開）だけの実装に置き換えた
# ＝旧 `printf | grep -m1 | sed` の 3 fork をノート 1 件あたり 4〜5 回起こして
# いた分を削り、v6 で増える Tasks 節解析の費用を相殺する（NFR-18・AC-117）。
fm_field() {
  local block="$1" key="$2" line raw=""
  while IFS= read -r line; do
    case "$line" in
      "${key}:"*) raw="${line#"${key}:"}"; break ;;
    esac
  done <<FM_EOF
$block
FM_EOF
  while :; do case "$raw" in [[:space:]]*) raw="${raw#?}" ;; *) break ;; esac; done
  while :; do case "$raw" in *[[:space:]]) raw="${raw%?}" ;; *) break ;; esac; done
  fm_unquote "$raw"
}

# 値 $1 の前後が揃った引用符（"…" / '…'）を剥がして stdout へ出す（fm_field の
# 剥がし規則の正本。v6 では版の待ち行の値にも同じ規則を通す＝要件 §11 FR-104〜106・
# WV-16・17・23）。外部プロセスを起こさない。
fm_unquote() {
  local val="$1"
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
#   W<TAB><版の待ち行の値>   （v6・設計 §41.5.2。前後 trim 済み・引用符はそのまま）
#
# 判定規則（§5.2・v6 §41.5.2）:
#   Tasks 節の開始: ^##[ \t]+Tasks[ \t]*$
#   Tasks 節の終了: 次の ^#[ \t] または ^##[ \t]（別の節）／EOF
#   版          : 節の中の ^###[ \t]+(.*)$。版名は前後空白を trim
#   タスク       : 版の中の ^- \[[ /x]\]。本文は7バイト目以降を trim
#   版の待ち行   : 版の中の ^- wait_until:。値は14バイト目以降を trim。同じ版に
#                 複数あれば全部流す（先頭だけを使うのは decide_current_version）
# 版の見出しより前に並ぶチェックリスト・待ち行はタスク／待ち行として数えない
# （FR-1・V-3・FR-104＝WV-22・26）。インデントされた行・[X] のような大文字は
# 数えない（^ 始まりの厳密一致・文字クラスに大文字 X を含めないことで自然に
# 除外される＝FR-2・WV-12）。同じ版名が複数あっても記載順に別の版として出す
# （FR-36 ②・V-13）。
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
      if (state == 2 && $0 ~ /^- wait_until:/) {
        print "W\t" trim(substr($0, 14))
        next
      }
      # state==1（版なし）の行・上記に当たらない行はタスク／待ち行として数えない
    }
  '
  return 0
}

# ▶ の版の決定部品（v6・設計 §41.3.1 案 A (b)・§41.5.3・D-v6-1）。read_note の
# TSV ストリームを stdin から読み、1 行を stdout へ出す（常に終了コード 0・
# 外部プロセスは awk 1 つ）:
#   <版の序数（0 始まり・V の記載順）><TAB>cur<TAB><その版の先頭の待ち行の値（無ければ空）>
#   -1<TAB><区分><TAB>          … ▶ の版が無い。区分＝noversion（Tasks 節なし・
#                                版見出しなし）／notask（全版タスク 0）／blanktask
#                                （trim 後に本文が空のタスク行が 1 つでもある）／
#                                alldone（全版完了）＝要件 v6.4 §2 の 5 分類
# 規則（既存 cmux-task-model.sh の 3 段判定と理由行の条件をそのまま移した正本）:
#   ① ▶ を決めない条件（Task 側の理由行と同じ順）＝版なし → タスクなし → 空タスク
#   ② 未完の版 U＝(total>=1 && done==total) でない版・記載順。U が空＝全版完了
#   ③ U の中で `[/]` を含む最初の版 → 無ければ `next:`（N 行）と版名が trim
#      （ASCII 空白と TAB だけ・全角空白は一致に含む）後に完全一致する最初の版
#      → 無ければ U の 1 番
# 待ち行は ▶ の版の**先頭の 1 行**だけ（空値でも先頭が勝つ＝2 行目で補わない・
# FR-104）。値の有効・無効・正規化・時刻比較は呼び出し側（Project 供給側）。
decide_current_version() {
  awk -F '\t' '
    function trim(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { vc = 0; total = 0; blank = 0; next_raw = "" }
    $1 == "N" { next_raw = $2; next }
    $1 == "V" { vc++; name[vc] = $2; tot[vc] = 0; done[vc] = 0; slash[vc] = 0; hasw[vc] = 0; wait[vc] = ""; next }
    $1 == "T" {
      if (vc == 0) next
      tot[vc]++; total++
      if ($2 == "x") done[vc]++
      if ($2 == "/") slash[vc] = 1
      if ($3 == "") blank = 1
      next
    }
    $1 == "W" {
      if (vc == 0) next
      if (!hasw[vc]) { hasw[vc] = 1; wait[vc] = $2 }
      next
    }
    END {
      if (vc == 0) { print "-1\tnoversion\t"; exit }
      if (total == 0) { print "-1\tnotask\t"; exit }
      if (blank) { print "-1\tblanktask\t"; exit }
      nu = 0
      for (i = 1; i <= vc; i++) {
        if (!(tot[i] >= 1 && done[i] == tot[i])) u[++nu] = i
      }
      if (nu == 0) { print "-1\talldone\t"; exit }
      cur = 0
      for (k = 1; k <= nu; k++) { if (slash[u[k]]) { cur = u[k]; break } }
      tn = trim(next_raw)
      if (!cur && tn != "") {
        for (k = 1; k <= nu; k++) { if (trim(name[u[k]]) == tn) { cur = u[k]; break } }
      }
      if (!cur) cur = u[1]
      print (cur - 1) "\tcur\t" wait[cur]
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
# テスト専用の差し替え口（v6・設計 §41.9.3・D-v6-14・A-v6-7＝lib が環境変数を
# 読む唯一の例外）: CMUX_VAULT_TASKS_SANITIZE_FAIL が非空なら read_note 全体を
# サニタイズ段の失敗として返す（rc=2＝解析不能の作り方＝DT-33。read_note 内の
# frontmatter 読取も含めて返らない）。read_note の外＝Project 供給側の frontmatter
# 読取（collect_entries の fm_extract／fm_field）・slug の無害化（sanitize_str）・
# next の切り詰め（truncate_plain）には効かない。本番設定にこの名前を書かない。
read_note() {
  local clean fm rc nextval
  [ -z "${CMUX_VAULT_TASKS_SANITIZE_FAIL:-}" ] || return 2
  clean="$(sanitize_lines <"$1")" || return 2          # jq 失敗＝ノート破損
  fm="$(printf '%s\n' "$clean" | fm_extract)"
  rc=$?
  [ "$rc" -eq 0 ] || return 2                          # frontmatter 不正＝ノート破損
  nextval="$(fm_field "$fm" next)"
  printf 'N\t%s\n' "$nextval"
  printf '%s\n' "$clean" | parse_tasks                 # TSV を stdout へ
}
