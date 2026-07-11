#!/bin/bash
# UserPromptSubmit hook: 外部脳(Obsidian)の想起支援。
#
# 目的: プロンプト本文に、Vaultのノート名/aliasesが「そのまま文字列として含まれて
# いる」場合、そのノートを「候補」として短く提示する（本文は注入しない＝
# additionalContextの肥大化・切り詰め事故を防ぐ。bootstrap-vault.shと同じ教訓）。
# 最終判断（実際にReadするか）はAI/リーダーに委ねる。
#
# 照合方式（全体一致＋トークン部分一致の二段構え・2026-07-11 8.0ラウンド改修）:
# 各ノートの「照合キー」（frontmatterのaliases: リスト + ファイル名由来のキー）
# について、まず従来どおり「キー全体がプロンプト文字列の中に部分文字列として
# 含まれるか」を判定する（全体一致・スコア2＝最優先）。ここで不一致でも即座に
# 見送らず、キーを空白/記号/ASCII-非ASCII境界でトークン分割し、各トークンが
# 個別にプロンプトへ出現するかを追加で調べる（部分一致・スコア1）。キーの全
# トークン中おおむね1/3以上が出現すれば部分一致とみなす（tokenize_key/
# token_matches・整数演算 matched*3 >= total）。これにより「iPhoneのSafari」
# （助詞が挟まって連続一致しない）・「pip installしちゃだめ？」（複数語キーの
# 一部の語しかプロンプトに現れない）のような、連続部分文字列では拾えない
# 言い換えに耐性を持たせる（敵対的レビュー2回目§3-5・第三者ホールドアウト
# 0/10の主因＝照合方式が連続部分文字列一致のみだったこと）。
# 日本語はスペース区切りが無いため、プロンプト側を分かち書きすることはしない
# （キー側だけを分割し、プロンプトの中を素朴に探す・従来からの方針を維持）。
# ASCIIキー/トークンは大小文字無視・3文字未満は対象外（"go" 等の一般語の誤爆を
# 減らす）。非ASCIIキー/トークンは大小文字の区別が無いため素の一致・2文字未満
# は対象外。加えて非ASCIIトークン(3文字以上)は「裏取り→裏を取る」「壊れる→
# 壊れた」のような活用形ゆれを一部吸収するため、末尾1文字を落とした形（活用語尾
# の変化を許容）でも一致を許容する（tokenize_key/token_matches実装を参照）。
#
# やらないこと（判断根拠・過剰適合防止）: 1つの複合語トークン（例:「裏取り
# 担当分担」のような助詞を含まない1続きの非ASCII文字列）をさらに細かく2分割し、
# プロンプト中に離れて出現する場合まで一致とみなす gap-tolerant 一致は実装しない。
# 「Webで裏を取る」vs alias「裏取り」型の言い換えの一部はこの方式では拾えない
# ままだが、複合語の内部境界推定は日本語形態素解析なしでは精度が出ず、対象
# ノートと無関係な誤ヒットを増やす副作用の方が大きいと判断した（8.0ラウンド
# 設計時のトレードオフとして記録・リーダー報告）。
#
# fail-open + 可観測（Knowledge/fail-open-and-observable-guards）:
# いかなるエラーでもプロンプト処理は妨げない（必ず exit 0）。ただし「無言の
# fail-open」は禁止のため、エラー時は $VAULT_RECALL_LOG に ERROR 行を残す。
#
# 環境変数（すべて省略可・テスト用）:
#   VAULT_RECALL_VAULT … Vaultのルート（既定 $HOME/Data/obsidian）
#   VAULT_RECALL_LOG    … 提示ログのTSVパス（既定 $HOME/.claude/logs/vault-recall.tsv）
#
# bash 3.2（macOSシステムbash）前提: 連想配列(declare -A)・mapfileは使わない。
# 空配列を "${arr[@]}" 展開すると set -u 下で unbound variable になる既知の癖が
# あるため、本スクリプトは set -u を使わない（bootstrap-vault.sh・
# delegation-gate-v2.sh と同方針）。

VAULT="${VAULT_RECALL_VAULT:-$HOME/Data/obsidian}"
LOG_FILE="${VAULT_RECALL_LOG:-$HOME/.claude/logs/vault-recall.tsv}"

# 想起支援の対象フォルダ（README.mdは各フォルダの説明用で照合対象外）。
SCAN_DIRS=(Knowledge Preferences Decisions Projects)

# 1ノート内で複数ヒットしたキーを連結する際の内部区切り文字（表示直前まで使う）。
# 半角スペースだと alias 自体に空白を含む場合（例: "fail, open"）に表示用の
# スペース→", "置換でキー内部の空白まで壊れるため、通常のalias文字列にまず
# 出現しない制御文字(Unit Separator)にする（Codexレビュー指摘・Major回帰）。
KEY_SEP=$'\x1f'

# 一致キー1件あたりのスコア。全体一致(キー全体が連続部分文字列として一致)を
# 最優先し、トークン部分一致はそれより弱い信号として扱う（同点ならより多くの
# 全体一致キーを持つノートが上位に来る・従来の「一致キー数の多い順」を維持）。
KEY_SCORE_FULL=2
KEY_SCORE_PARTIAL=1

# 起動必読ファイル（bootstrap-vault.shと同じ6件）は毎セッション必ず全文Readされる
# ため、想起候補として重複提示する意味が無い。Personal/profile-personal.md は
# 上記4フォルダの対象外なので実質的な除外対象は5件。
EXCLUDE_RELPATHS=(
  "Knowledge/mistakes.md"
  "Preferences/absolute-rules.md"
  "Preferences/profile.md"
  "Preferences/coding-delegation.md"
  "Preferences/vault-operation.md"
)

# ISO8601時刻+TSV1行を$LOG_FILEへ追記する（ディレクトリ自動作成）。
# 失敗しても握りつぶす（ログ書き込み自体がプロンプト処理を止めてはいけない）。
log_row() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s\t%s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# 想定外のエラー用ログ。vault_inventory.py の read_log() は同じ vault-recall.tsv を
# 「ts\tsession_id\tノート相対パス[\t一致キー]」として読み、3列目をノートパス（未読
# 判定・提示回数カウント）に使う。ERROR行の3列目にエラーメッセージを置くと、
# 存在しないノートパスとして誤集計されてしまうため、3列目は空文字にして無害化する
# （4列目以降はread_log()が読まないため自由に使える。session_id・メッセージはそちらへ）。
# Knowledge/fail-open-and-observable-guards の「無言のfail-openは可観測にする」の実装。
log_error() {
  log_row "ERROR		${SESSION_ID:-}	$1"
}

INPUT="$(cat 2>/dev/null || true)"

# session_id/promptを1回のjq呼び出しで取り出す（@tsvはフィールド内のタブ/改行を
# エスケープするため、プロンプトに実改行があっても行が壊れない）。
JQ_OUT="$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.prompt // "")] | @tsv' 2>/dev/null)"
JQ_RC=$?
IFS=$'\t' read -r SESSION_ID PROMPT <<< "$JQ_OUT"
if [ "$JQ_RC" -ne 0 ]; then
  log_error "stdin JSONの解析に失敗しました（jq exit ${JQ_RC}）。想起支援をskipします。"
  exit 0
fi

# 文字数カウント(${#PROMPT})を多バイト正しく行うため、UTF-8ロケールを明示する
# （実測: LC_ALLを明示しない環境ではbashが日本語をバイト単位で数えてしまう）。
case "${LC_ALL:-}" in
  *UTF-8*) : ;;
  *)
    case "${LANG:-}" in
      *UTF-8*) export LC_ALL="$LANG" ;;
      *) export LC_ALL="en_US.UTF-8" ;;
    esac
    ;;
esac

# プロンプトが短すぎる場合は何もしない（想起の価値が薄く、雑音になりやすいため）。
if [ "${#PROMPT}" -lt 10 ]; then
  exit 0
fi

if [ ! -d "$VAULT" ]; then
  log_error "Vaultディレクトリが見つかりません: ${VAULT}"
  exit 0
fi

# --- 候補ファイル一覧（フォークなしのbashグロブ。存在しないフォルダはnullglobで
#     単に0件になる＝サブ機でDecisions等が無くてもエラーにならない） ---
shopt -s nullglob
FILES=()
for d in "${SCAN_DIRS[@]}"; do
  for f in "$VAULT/$d"/*.md; do
    FILES+=("$f")
  done
done
shopt -u nullglob

# インライン配列の中身（例: a, "b, c", d）を、クォート内のカンマでは分割しない
# ように1文字ずつ走査してCUR_KEYSへ追加する（Codexレビュー指摘・Major: 単純な
# IFS=,展開だと `aliases: ["foo, bar"]` のようなクォート内カンマを含むaliasが
# 誤って2つに割れてしまう。scripts/vault-agents/apply_aliases.py の
# split_flow_list() と同じ考え方をbashで実装）。
emit_inline_alias_part() {
  local part="$1"
  part="${part#"${part%%[![:space:]]*}"}"   # 先頭空白除去
  part="${part%"${part##*[![:space:]]}"}"   # 末尾空白除去
  part="${part%\"}"; part="${part#\"}"
  part="${part%\'}"; part="${part#\'}"
  [ -n "$part" ] && CUR_KEYS+=("$part")
}
split_inline_aliases() {
  local inner="$1" cur="" quote="" ch len i=0
  len=${#inner}
  while [ "$i" -lt "$len" ]; do
    ch="${inner:$i:1}"
    if [ -n "$quote" ]; then
      if [ "$ch" = '\' ] && [ $((i + 1)) -lt "$len" ]; then
        cur="${cur}${ch}${inner:$((i + 1)):1}"
        i=$((i + 2))
        continue
      fi
      cur="${cur}${ch}"
      [ "$ch" = "$quote" ] && quote=""
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      '"' | "'") quote="$ch"; cur="${cur}${ch}" ;;
      ,) emit_inline_alias_part "$cur"; cur="" ;;
      *) cur="${cur}${ch}" ;;
    esac
    i=$((i + 1))
  done
  emit_inline_alias_part "$cur"
}

# --- 1ファイル分の照合キー(aliases + ファイル名由来)を CUR_KEYS へ詰める ---
# フォーク・サブシェルを使わない（130ノート規模で実行時間目標300msを守るため）。
# 読み取れなかったノート件数はUNREADABLE_NOTE_COUNTに積算し、末尾でまとめて
# 1行だけログする（Codexレビュー指摘・Minor: 権限エラー等で本文が読めない場合
# 無言でファイル名キーだけにフォールバックしていた＝無言のfail-open）。
CUR_KEYS=()
UNREADABLE_NOTE_COUNT=0
collect_keys_for_file() {
  local relpath="$1" f="$VAULT/$1"
  CUR_KEYS=()
  local stem="${relpath##*/}"
  stem="${stem%.md}"
  CUR_KEYS+=("$stem")
  local nohy="${stem//-/}"
  [ "$nohy" != "$stem" ] && CUR_KEYS+=("$nohy")

  [ -f "$f" ] || return 0
  if [ ! -r "$f" ]; then
    UNREADABLE_NOTE_COUNT=$((UNREADABLE_NOTE_COUNT + 1))
    return 0
  fi

  local in_fm=0 fm_line=0 mode=0 line val
  while IFS= read -r line || [ -n "$line" ]; do
    fm_line=$((fm_line + 1))
    if [ "$fm_line" -eq 1 ]; then
      [ "$line" = "---" ] && in_fm=1
      continue
    fi
    [ "$in_fm" -eq 0 ] && break        # frontmatterが無いノート
    [ "$line" = "---" ] && break       # frontmatter終端

    # ブロックリスト形式（aliases:\n  - foo\n  - bar）の項目行
    if [ "$mode" -eq 1 ]; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
        val="${BASH_REMATCH[1]}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        [ -n "$val" ] && CUR_KEYS+=("$val")
        continue
      else
        mode=0   # ブロックリスト終了。このlineは以下のチェックへフォールスルーする
      fi
    fi

    # インライン配列形式（aliases: [foo, "bar baz"]）
    if [[ "$line" =~ ^aliases:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
      split_inline_aliases "${BASH_REMATCH[1]}"
      continue
    fi

    # ブロックリスト形式の開始行（aliases: の後に値が無い）
    if [[ "$line" =~ ^aliases:[[:space:]]*$ ]]; then
      mode=1
      continue
    fi
  done < "$f"
}

# キー全体としては一致しない場合の部分一致判定に使う、区切り文字の集合。
# ここに含まれる文字はトークンの一部にはせず、単なる区切りとして捨てる
# （ASCII/非ASCIIの切り替わり自体も、区切り文字を介さず暗黙の境界として扱う＝
# tokenize_key本体のクラス変化検出で処理する）。
TOKEN_SEP_CHARS=$' \t\r\n-_/.,:;()[]{}"'"'"'!?~=+*&%#@|<>「」『』【】、。・〜～'

# キーが「ASCII/非ASCII境界では一切分割できない、1続きの非ASCII文字列」の
# 場合に限り、追加でカタカナ連続の境界でも分割を試みる（外部grepを1回だけ
# fork・全キーに対して行うと130ノート規模の実行時間予算を超えるため、境界
# 候補が他に無い場合の最後の手段としてのみ使う）。カタカナの連続（借用語・
# 固有名詞由来が多い）は複合語の中でも独立した意味単位になりやすいという
# 性質を利用する（例:「波及チェック定型化」→「波及」「チェック」「定型化」）。
# 漢字とひらがなの間では分割しない＝活用形の語幹+送り仮名（例:「壊れる」
# 「裏取り」）を壊さないため（末尾1文字ドロップの活用形吸収と両立させる）。
# bash 3.2の文字クラス([[ ... ]]・case )はマルチバイト文字のUnicode範囲判定が
# 壊れている（実機確認済み）ため、この用途だけは外部grep(BSD grep)に頼る。
KATAKANA_CHARS="ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヲンヴーヵヶ"

# キーに片仮名とそれ以外の両方が混ざっている場合だけtrueを返す（純粋な漢字・
# ひらがなのみのキー、または片仮名のみのキーではgrepをforkしても分割点が
# 得られない＝無駄なforkを避ける事前チェック。Codexレビュー指摘・Minor:
# 全体一致に失敗した非ASCII単一トークンすべてでforkしていたため、130ノート
# 規模でも数百回forkし得た）。
has_mixed_katakana() {
  local s="$1" i=0 len ch has_kata=0 has_other=0
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    case "$KATAKANA_CHARS" in
      *"$ch"*) has_kata=1 ;;
      *) has_other=1 ;;
    esac
    [ "$has_kata" -eq 1 ] && [ "$has_other" -eq 1 ] && return 0
    i=$((i + 1))
  done
  return 1
}

tokenize_katakana_boundary() {
  local key="$1" out part
  TOK_ARR=()
  out="$(LC_ALL=en_US.UTF-8 grep -oE '[ァ-ヶー]+|[^ァ-ヶー]+' <<< "$key" 2>/dev/null)"
  if [ -z "$out" ]; then
    TOK_ARR=("$key")
    return 0
  fi
  while IFS= read -r part; do
    [ -n "$part" ] && TOK_ARR+=("$part")
  done <<< "$out"
}

# キー文字列を「トークン」の配列 TOK_ARR に分解する（bash 3.2純正・1文字ずつ
# 走査。split_inline_aliasesと同じフォーク無し方針）。区切り文字で区切るほか、
# ASCII文字と非ASCII文字が区切り文字を挟まず隣接している場合（例: "MCPサーバー"）
# も、そこを暗黙の境界とみなして分割する。
# 分割後、以下を除いたものだけをTOK_ARRに残す（誤ヒット源になりやすいため）:
#   - 純数字のみのトークン（ファイル名の日付断片"2026""07""05"等）
#   - ASCII 3文字未満・非ASCII 2文字未満のトークン（既存の最小長ルールと同じ）
tokenize_key() {
  local key="$1" i=0 len ch cur="" cur_class="" new_class
  local raw=()
  TOK_ARR=()
  len=${#key}
  while [ "$i" -lt "$len" ]; do
    ch="${key:$i:1}"
    case "$ch" in
      *[![:ascii:]]*) new_class="N" ;;                # 非ASCII文字
      *)
        case "$TOKEN_SEP_CHARS" in
          *"$ch"*) new_class="S" ;;                    # 区切り文字
          *) new_class="A" ;;                          # ASCII英数字
        esac
        ;;
    esac
    if [ "$new_class" = "S" ]; then
      [ -n "$cur" ] && raw+=("$cur")
      cur=""; cur_class=""
    elif [ "$new_class" != "$cur_class" ]; then
      [ -n "$cur" ] && raw+=("$cur")
      cur="$ch"; cur_class="$new_class"
    else
      cur="${cur}${ch}"
    fi
    i=$((i + 1))
  done
  [ -n "$cur" ] && raw+=("$cur")

  # ASCII/非ASCII境界では1個も分割できなかった場合（キー全体が1続きの非ASCII
  # 文字列）のみ、最後の手段としてカタカナ境界分割を試みる（fork予算対策の
  # ため、既に複数トークンに分かれているキーには適用しない）。
  if [ "${#raw[@]}" -eq 1 ]; then
    local only="${raw[0]}"
    case "$only" in
      *[![:ascii:]]*)
        if [ "${#only}" -ge 4 ] && has_mixed_katakana "$only"; then
          tokenize_katakana_boundary "$only"
          [ "${#TOK_ARR[@]}" -ge 2 ] && raw=("${TOK_ARR[@]}")
        fi
        ;;
    esac
  fi

  local t tlen is_digit_only
  TOK_ARR=()
  for t in "${raw[@]}"; do
    case "$t" in
      *[![:digit:]]*) is_digit_only=0 ;;
      *) is_digit_only=1 ;;
    esac
    [ "$is_digit_only" -eq 1 ] && continue

    tlen=${#t}
    case "$t" in
      *[![:ascii:]]*) [ "$tlen" -ge 2 ] && TOK_ARR+=("$t") ;;
      *) [ "$tlen" -ge 3 ] && TOK_ARR+=("$t") ;;
    esac
  done
}

# 汎用すぎるトークン（このVault内のほぼ全ノートに顔を出す道具名・役割名）は、
# プロンプトに出現していても部分一致の根拠としては数えない（scripts/vault-agents/
# generic-aliases.txt と目的が近いリストをここに複製・実測で判明した回帰への対処:
# 例えば「claude-codex-usage」を尋ねただけで、"Claude"という1語だけを共有する
# 無関係な別ノート群のaliasが軒並み部分一致してしまい、複数aliasにまたがる分
# スコアが積み上がって正解ノートを押しのけていた。シンボリックリンク経由でも
# 確実に動く必要がある＝相対パスで外部ファイルを読みに行かず定数として埋め込む。
# 完全な同期は要求しない・alias品質チェックとは目的が別のため多少ズレても実害は
# 小さい。更新する場合はgenerative-aliases.txtも合わせて見直すことが望ましい）。
GENERIC_TOKENS_ASCII=(ai claude codex obsidian vault mcp)
GENERIC_TOKENS_NONASCII=("ツール" "ルール" "設定" "配信" "メモ" "作業" "運用" "テスト" \
  "レビュー" "ワークフロー" "エージェント" "ワーカー" "委任" "フック" "スクリプト" "外部脳")

is_generic_token() {
  local tok="$1" g
  case "$tok" in
    *[![:ascii:]]*)
      for g in "${GENERIC_TOKENS_NONASCII[@]}"; do
        [ "$tok" = "$g" ] && return 0
      done
      ;;
    *)
      shopt -s nocasematch
      for g in "${GENERIC_TOKENS_ASCII[@]}"; do
        if [[ "$tok" == "$g" ]]; then
          shopt -u nocasematch
          return 0
        fi
      done
      shopt -u nocasematch
      ;;
  esac
  return 1
}

# 活用語尾は必ずひらがな（送り仮名）で書かれるという日本語表記の性質を利用し、
# 末尾1文字ドロップの活用形フォールバックは「トークンの最後の1文字がひらがな」
# の場合だけに限定する（ノイズ検査の実測で判明: 例えば「配信前」の末尾「前」
# （漢字）を落として「配信」にしてしまうと、活用形とは無関係な一般語が生まれて
# 無関係プロンプトに誤ヒットする。「キャラ」の末尾「ラ」（カタカナ）を落として
# 「キャ」にしてしまい、たまたま「ポッドキャスト」に含まれる「キャ」と誤って
# 一致したケースも同様。末尾がひらがなのときだけに絞ることで、"壊れる"→
# "壊れた"のような正規の活用ゆれ吸収はそのまま残しつつ、この2件の誤ヒットを
# 塞げることを確認済み）。長音符「ー」は含めない（Codexレビュー指摘・Minor:
# 含めると片仮名語の長音省略（"サーバー"→"サーバ"等）まで許容してしまい、
# 「活用形のゆれ」という趣旨から外れて誤ヒット面を広げるだけになる）。
HIRAGANA_CHARS="あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんがぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽゃゅょっ"

is_hiragana_char() {
  case "$HIRAGANA_CHARS" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 1トークンがプロンプト中に見つかるかを判定する。ASCIIトークンは大小文字無視の
# 通常の部分文字列一致。非ASCIIトークン(3文字以上)は、通常一致に加えて「末尾
# 1文字を落とした形」でも一致を許容する（"壊れる"→"壊れた"のような活用形の
# ゆれを、複合語の内部分割はせず語尾のみの変化として吸収する・ヘッダコメント
# の「やらないこと」参照）。末尾がひらがなの場合のみ許容する（上のコメント）。
token_matches() {
  local tok="$1" tlen=${#tok}
  case "$tok" in
    *[![:ascii:]]*)
      [[ "$PROMPT" == *"$tok"* ]] && return 0
      if [ "$tlen" -ge 3 ] && is_hiragana_char "${tok:$((tlen - 1)):1}"; then
        local trimmed="${tok%?}"
        [[ "$PROMPT" == *"$trimmed"* ]] && return 0
      fi
      return 1
      ;;
    *)
      local rc=1
      shopt -s nocasematch
      [[ "$PROMPT" == *"$tok"* ]] && rc=0
      shopt -u nocasematch
      return "$rc"
      ;;
  esac
}

# --- 各ファイルについてプロンプトとの照合を行う ---
RESULT_RELPATHS=()
RESULT_SCORES=()
RESULT_KEYLISTS=()

for f in "${FILES[@]}"; do
  relpath="${f#"$VAULT"/}"
  base="${f##*/}"
  [ "$base" = "README.md" ] && continue

  excluded=0
  for ex in "${EXCLUDE_RELPATHS[@]}"; do
    if [ "$relpath" = "$ex" ]; then excluded=1; break; fi
  done
  [ "$excluded" -eq 1 ] && continue

  collect_keys_for_file "$relpath"

  # matched_keys の内部区切りには半角スペースではなく制御文字(Unit Separator \x1f)を
  # 使う（Codexレビュー指摘・Major回帰で発覚: alias自体に空白を含む場合
  # （例: "fail, open"）、スペース区切り+表示時のスペース→", "置換だと、キー内部の
  # 空白まで誤って ", " に変換され表示が壊れる。\x1fは通常のalias文字列に
  # まず出現しないため、区切り文字としても表示直前の置換対象としても安全）。
  matched_keys=""
  seen_keys=""
  note_full_score=0
  note_has_partial=0
  for key in "${CUR_KEYS[@]}"; do
    [ -z "$key" ] && continue

    # 前後をKEY_SEPで挟んでから完全一致部分文字列として探す（Codexレビュー指摘・
    # Minor回帰: 左境界だけの判定だと、既存キー"foobar"に対して新キー"foo"が
    # prefix一致してしまい、別のaliasなのに重複扱いでskipされてしまっていた）。
    case "${KEY_SEP}${seen_keys}${KEY_SEP}" in
      *"${KEY_SEP}${key}${KEY_SEP}"*) continue ;;   # 同一ノート内の重複キーは1回だけ数える
    esac

    case "$key" in
      *[![:ascii:]]*) is_ascii=0 ;;
      *) is_ascii=1 ;;
    esac
    klen=${#key}

    full_matched=0
    if [ "$is_ascii" -eq 1 ]; then
      if [ "$klen" -ge 3 ]; then
        shopt -s nocasematch
        [[ "$PROMPT" == *"$key"* ]] && full_matched=1
        shopt -u nocasematch
      fi
    else
      if [ "$klen" -ge 2 ]; then
        [[ "$PROMPT" == *"$key"* ]] && full_matched=1
      fi
    fi

    key_score=0
    key_tag=""
    is_partial=0
    if [ "$full_matched" -eq 1 ]; then
      key_score=$KEY_SCORE_FULL
    else
      # 全体一致しなかったキーだけ追加コストをかけてトークン部分一致を試す
      # （大半のキーは全体一致で確定するか、ここでも不一致に終わる＝
      # 130ノート規模での実行時間予算を守るため、全体一致に成功したキーでは
      # トークン化を行わない）。
      tokenize_key "$key"
      tok_total=${#TOK_ARR[@]}
      if [ "$tok_total" -ge 2 ]; then
        tok_matched=0
        for tok in "${TOK_ARR[@]}"; do
          # 汎用トークン(is_generic_token)単独の一致は数えない（誤ヒット面拡大の
          # 主因だったため・上のGENERIC_TOKENS定義のコメント参照）。
          if token_matches "$tok" && ! is_generic_token "$tok"; then
            tok_matched=$((tok_matched + 1))
          fi
        done
        # ratio >= 1/3（整数演算 matched*3 >= total）。2語キーは1語一致で
        # 部分一致とみなす一方、4語以上のキーは半数近くの一致を要求することに
        # なり、単発の断片一致だけで長いキーが誤ヒットするのを防ぐ
        # （ヘッダコメント参照・閾値は第三者ホールドアウト/回帰/ノイズ検査の
        # 実測を見て決定）。
        if [ "$tok_matched" -ge 1 ] && [ $((tok_matched * 3)) -ge "$tok_total" ]; then
          key_score=$KEY_SCORE_PARTIAL
          key_tag=" (部分一致)"
          is_partial=1
        fi
      elif [ "$tok_total" -eq 1 ]; then
        # 単一トークンキー（＝ASCII/非ASCII境界でもカタカナ境界でも分割できず、
        # キー全体で1語のまま）でも、活用形フォールバック（token_matches内の
        # 末尾ひらがな1文字ドロップ）だけは試す（Codexレビュー指摘・Major:
        # これが無いと、複数語からなるキーの構成要素としてしか活用形フォール
        # バックが機能せず、単独alias「壊れる」のようなケースに全く届かない）。
        # トークンが1つしか無いため一致率の閾値判定は不要＝フォールバック自体が
        # 成立した場合だけ部分一致として扱う。
        tok="${TOK_ARR[0]}"
        if ! is_generic_token "$tok" && token_matches "$tok"; then
          key_score=$KEY_SCORE_PARTIAL
          key_tag=" (部分一致)"
          is_partial=1
        fi
      fi
    fi

    [ "$key_score" -eq 0 ] && continue

    seen_keys="${seen_keys}${KEY_SEP}${key}"
    matched_keys="${matched_keys}${KEY_SEP}${key}${key_tag}"
    if [ "$is_partial" -eq 1 ]; then
      # 1ノートにつき部分一致の加点は最大1回分だけ（Codexレビュー前の実測で
      # 判明した回帰への対処: 同じ汎用トークンを共有する複数aliasを持つノートが、
      # alias数だけスコアが積み上がって無関係なのに上位を独占していた。表示・
      # ログには全ての部分一致キーを残す＝どの語で拾われたかは追える）。
      note_has_partial=1
    else
      note_full_score=$((note_full_score + key_score))
    fi
  done
  note_score=$((note_full_score + (note_has_partial * KEY_SCORE_PARTIAL)))

  if [ "$note_score" -gt 0 ]; then
    RESULT_RELPATHS+=("$relpath")
    RESULT_SCORES+=("$note_score")
    RESULT_KEYLISTS+=("$matched_keys")
  fi
done

# 読み取れなかったノートが1件以上あれば、ヒット件数に関わらず1回だけ要約ログを残す
# （無言のfail-open防止。ファイルごとに出すとログが荒れるため件数のみ集約する）。
if [ "$UNREADABLE_NOTE_COUNT" -gt 0 ]; then
  log_error "${UNREADABLE_NOTE_COUNT}件のノートを読み取れませんでした（権限不足の可能性・ファイル名キーのみで照合しました）"
fi

N=${#RESULT_RELPATHS[@]}
[ "$N" -eq 0 ] && exit 0

# --- 一致キー数の多い順に最大5件を選ぶ（外部sortを使わない選択法。件数が
#     小規模なのでO(n^2)で十分＝300ms予算内） ---
USED=()
for ((i = 0; i < N; i++)); do USED[i]=0; done
SELECTED_IDX=()
for ((k = 0; k < 5 && k < N; k++)); do
  best=-1
  best_score=-1
  for ((i = 0; i < N; i++)); do
    if [ "${USED[i]}" -eq 0 ] && [ "${RESULT_SCORES[i]}" -gt "$best_score" ]; then
      best=$i
      best_score=${RESULT_SCORES[i]}
    fi
  done
  [ "$best" -lt 0 ] && break
  USED[$best]=1
  SELECTED_IDX+=("$best")
done

CTX="外部脳の関連ノート候補（必要なら Read）:"
for idx in "${SELECTED_IDX[@]}"; do
  relpath="${RESULT_RELPATHS[$idx]}"
  # matched_keys は先頭にKEY_SEPが付いた "${KEY_SEP}key1${KEY_SEP}key2..." 形式
  # なので、区切りを人間向けの区切りへ置換した後、先頭の余分な区切りを取り除く。
  keys_display="${RESULT_KEYLISTS[$idx]//$KEY_SEP/, }"
  keys_display="${keys_display#, }"
  CTX="${CTX}
- ${relpath}（一致: ${keys_display}）"
done

# 出力生成の失敗も「無言のfail-open」にしない（Codexレビュー指摘・Major:
# スクリプト最後のコマンドがそのままexit codeになるため、jq自体がここで失敗
# すると「必ずexit 0」の契約が破れる。一度変数へ受けてから明示的にexit 0する）。
OUT_JSON="$(jq -n --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null)"
JQ_OUT_RC=$?
if [ "$JQ_OUT_RC" -ne 0 ] || [ -z "$OUT_JSON" ]; then
  log_error "出力JSONの生成に失敗しました（jq exit ${JQ_OUT_RC}）。想起支援をskipします。"
  exit 0
fi

# 提示ログへの追記は、出力生成が成功した後（＝実際にadditionalContextとして
# 提示することが確定した後）に行う（Codexレビュー指摘・Minor回帰: 従来は
# CTX組み立てと同時にlog_rowしていたため、最終jqが失敗した場合に「提示して
# いないのに提示済みとしてログされる」誤集計が起き得た）。
for idx in "${SELECTED_IDX[@]}"; do
  keys_log="${RESULT_KEYLISTS[$idx]//$KEY_SEP/,}"
  keys_log="${keys_log#,}"
  log_row "${SESSION_ID}	${RESULT_RELPATHS[$idx]}	${keys_log}"
done

printf '%s\n' "$OUT_JSON"
exit 0
