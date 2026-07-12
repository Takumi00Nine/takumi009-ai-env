#!/bin/bash
# UserPromptSubmit hook: 外部脳(Obsidian)の想起支援。
#
# 目的: プロンプト本文に、Vaultのノート名/aliasesが「そのまま文字列として含まれて
# いる」場合、そのノートを「候補」として短く提示する（本文は注入しない＝
# additionalContextの肥大化・切り詰め事故を防ぐ。bootstrap-vault.shと同じ教訓）。
# 最終判断（実際にReadするか）はAI/リーダーに委ねる。
#
# 8.2ラウンド「統一リファクタリング」（リーダー承認済み設計）: 従来このファイルに
# bashでインライン実装されていたキーワード照合ロジック（全体一致＋トークン部分一致の
# 二段構え・8.0ラウンド改修）を scripts/vault-agents/keyword_recall_helper.py へ挙動
# 完全維持のまま移植した。本スクリプトは以後、keyword_recall_helper.pyと
# vector_recall_helper.py（柱①・8.1ラウンド追加・無改変）を並列にサブプロセス起動し、
# 両方の結果をマージして従来と同一形式で表示するだけの薄い殻になる。移植元の全文は
# claude/hooks/vault-recall-legacy.sh にロールバック用として保全してある（インストール
# 対象外・各判断のコメントも含め無変更。詳細な設計理由（照合方式・tie-break・
# fail-open方針等）を読みたい場合はそちらを参照）。
#
# 照合方式そのもの（全体一致＋トークン部分一致・スコア計算・活用形/カタカナ境界の
# フォールバック等）はkeyword_recall_helper.py側のdocstring・各関数コメントに移設した。
#
# fail-open + 可観測（Knowledge/fail-open-and-observable-guards）:
# いかなるエラーでもプロンプト処理は妨げない（必ず exit 0）。ただし「無言の
# fail-open」は禁止のため、エラー時は $VAULT_RECALL_LOG に ERROR 行を残す。
# キーワード・ベクトルは互いに独立してfail-openする（片方が失敗してももう片方の
# 結果は保持する）。
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

# 1ノート内で複数ヒットしたキーを連結する際の内部区切り文字（表示直前まで使う）。
# 半角スペースだと alias 自体に空白を含む場合（例: "fail, open"）に表示用の
# スペース→", "置換でキー内部の空白まで壊れるため、通常のalias文字列にまず
# 出現しない制御文字(Unit Separator)にする（Codexレビュー指摘・Major回帰）。
# keyword_recall_helper.pyのJSON出力(keys配列)からこの区切りへ組み直して使う。
KEY_SEP=$'\x1f'

# 起動必読ファイル（bootstrap-vault.shと同じ6件）は毎セッション必ず全文Readされる
# ため、想起候補として重複提示する意味が無い。Personal/profile-personal.mdは
# 2026-07-11のPersonal想起対象化（[[Decisions/2026-07-11-personal-recall-scope]]）
# でSCAN_DIRSに含まれるようになったため、他5件と同様に除外対象へ追加した
# （リーダー指示: 「必読profile-personalの候補除外ルールは既存の必読除外と同様の
# 扱いでよい」）。keyword_recall_helper.py側にも同じ6件を独立に定義している
# （ここではベクトル候補側の除外チェックにのみ使う。2箇所の完全同期は機械的には
# 強制しない＝GENERIC_TOKENS等と同じ運用方針。更新時は両方見直すこと）。
EXCLUDE_RELPATHS=(
  "Knowledge/mistakes.md"
  "Preferences/absolute-rules.md"
  "Preferences/profile.md"
  "Preferences/coding-delegation.md"
  "Preferences/vault-operation.md"
  "Personal/profile-personal.md"
)

# 両helper(keyword/vector)の出力JSONを取り込む前に通すスキーマ検証式（jq -e用）。
# トップレベルの型だけでなく候補配列の各要素までチェックする（Codexレビュー指摘・Major
# 2巡目: トップレベルの型だけを見る検証だと `{"candidates":[{}]}` のような壊れた要素が
# 素通りし、relpath/scoreが文字列"null"として候補表示・ログへ混入してしまう）。
# helper自身が正常に動作している限り常に真になる契約であり、破損/差し替えhelperに
# 対する防御的検証としてのみ働く（fail-open集約ログへ回すための判定・下記の使用箇所参照）。
KW_SCHEMA_CHECK='type == "object" and (.candidates | type == "array") and
  all(.candidates[]; type == "object"
    and (.relpath | type == "string" and length > 0)
    and (.score | type == "number")
    and (.keys | type == "array")
    and all(.keys[]; type == "object" and (.key | type == "string") and (.partial | type == "boolean")))'
VEC_SCHEMA_CHECK='type == "object" and (.candidates | type == "array") and
  all(.candidates[]; type == "object"
    and (.relpath | type == "string" and length > 0)
    and (.score | type == "number"))'

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

# ベクトル想起のfail-openをすべて1箇所へ集約するログ関数（付録A FR3の6ケース＝
# Ollama不在／応答timeout／インデックス破損・JSON壊れ／埋め込み次元不一致／権限
# エラー／削除済みノート残存、いずれもここを通る。ケースの区別はメッセージ文言のみで
# 行い、bash側の分岐そのものは増やさない＝「1箇所に集約」）。全ケースで想起処理は
# 継続しキーワード結果は維持する（exitしない）。
log_vector_fail_open() {
  log_error "ベクトル想起をfail-openでskipしました: $1"
}

# キーワード想起のfail-open集約ログ（8.2ラウンド新設・log_vector_fail_openと対の
# 関数）。keyword_recall_helper.pyの起動失敗・timeout・異常終了・出力JSON壊れの
# いずれもここを通す。全ケースで想起処理は継続しベクトル結果は維持する（exitしない・
# 「片方が失敗してももう片方の枠は生かす」という設計判断のbash側実装）。
log_keyword_fail_open() {
  log_error "キーワード想起をfail-openでskipしました: $1"
}

# --- 予算・タイムアウト関連の設定 ---
# キーワード想起(柱②・8.2ラウンド)・ベクトル想起(柱①・8.1ラウンド追加)は共通の
# パターン（bash側でenv値を検証→サブプロセス起動→25msポーリングでの生死監視→
# 予算超過時のみ強制kill）に従う。VAULT_RECALL_DISABLE_VECTOR=1でベクトル想起のみを
# 無効化できる（AC1回帰確認用のキルスイッチ。既存4ベンチセットをキーワードのみ
# モードで走らせ「無劣化」を確認するために使う＝設計書§4 AC1。recall_bench.py側から
# この環境変数で切り替える想定）。キーワード想起には対応するキルスイッチは無い
# （常に試みる＝FR2の「候補0件のプロンプトでもキーワード照合自体は毎回行う」を
# 維持するため。無効化が必要になったことは無い）。
VECTOR_DISABLED="${VAULT_RECALL_DISABLE_VECTOR:-0}"

# 内部timeout（要件v2決定h・当初500ms暫定→2026-07-12に1000msへ変更・本人指示）。
# 変更理由（本人立ち会い実測）: コールド時（Ollama既定keep_alive 5分切れ後）はモデル
# 再ロード込みのembedが647〜648msで安定し、旧500ms予算では確実にtimeout→fail-open
# していた（ウォームは65〜70ms）。1000msならコールドでも約35%のマージンで収まり、
# 最悪ケースの待ち（1000+猶予150ms）もAC4の許容枠（プロンプト+2秒p95）内。
# vector_recall_helper.py自身のmonotonic()予算としてそのまま渡す。bash側のハードkill
# レースはこれに小さな猶予(GRACE_MS)を足した秒数で発火させる（helperが自らの予算超過を
# 検知して自主終了する猶予を優先し、bashによる強制killは「それでも終わらない」場合の
# 最終防衛線にする＝二重の予算超過対策）。
VECTOR_BUDGET_MS="${VAULT_RECALL_VECTOR_BUDGET_MS:-1000}"
VECTOR_KILL_GRACE_MS="${VAULT_RECALL_VECTOR_KILL_GRACE_MS:-150}"

# キーワード想起にも同じ二重予算パターンを適用する（8.2ラウンド新設）。キーワード
# 照合はローカルI/Oのみで通常は数十ms程度に収まるが、Vaultが極端に肥大化した場合等の
# 保険として、ベクトル側と全く同じ検証・kill方式を用意する（既定値もVECTOR側と
# 揃えて1000ms/150msにした＝「新しい閾値ノブは作らない」方針の範囲内で、既存パターンの
# 素直な複製として扱う）。
KEYWORD_BUDGET_MS="${VAULT_RECALL_KEYWORD_BUDGET_MS:-1000}"
KEYWORD_KILL_GRACE_MS="${VAULT_RECALL_KEYWORD_KILL_GRACE_MS:-150}"

# 非負整数であることを検証し、不正値（空文字/小数/負数/数字以外）は既定値へフォール
# バックする（Codexレビュー指摘・Major: 後段でこれらの値をbashの算術展開$(( ))へ直接
# 渡すポーリングループに変更したため、環境変数が不正だと算術構文エラーでフック自体が
# 「いかなるエラーでもexit 0」というhook契約に反して異常終了しかねない。旧awkベースの
# 実装は非数値でも構文エラーにならず`[ -z ... ] && KILL_AFTER_S="0.65"`で拾えていたが、
# 整数演算化に伴い明示的な検証が必要になった）。
case "$VECTOR_BUDGET_MS" in
  ''|*[!0-9]*) VECTOR_BUDGET_MS=1000 ;;
esac
case "$VECTOR_KILL_GRACE_MS" in
  ''|*[!0-9]*) VECTOR_KILL_GRACE_MS=150 ;;
esac
case "$KEYWORD_BUDGET_MS" in
  ''|*[!0-9]*) KEYWORD_BUDGET_MS=1000 ;;
esac
case "$KEYWORD_KILL_GRACE_MS" in
  ''|*[!0-9]*) KEYWORD_KILL_GRACE_MS=150 ;;
esac
MAX_VECTOR_EXTRA=3   # ベクトル候補のうちキーワード候補に無いものの表示上限（FR2）

# claude/hooks/vault-recall.sh は install-main.sh により $HOME/.claude/hooks/ へ
# シンボリックリンクされる（実体はリポジトリ内）ため、BASH_SOURCEをシンボリックリンク
# 解決してからリポジトリルートを求める必要がある（macOSのBSD readlinkは-fを持たない
# ため、手動でループ解決する定番のbash 3.2互換イディオム）。直接パス実行（テスト等）
# でもシンボリックリンクが無いだけで同じロジックがそのまま正しく動く。
resolve_repo_root() {
  local src="${BASH_SOURCE[0]}" dir link
  while [ -h "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    link="$(readlink "$src")"
    case "$link" in
      /*) src="$link" ;;
      *) src="$dir/$link" ;;
    esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  (cd -P "$dir/../.." && pwd)
}
REPO_ROOT="${VAULT_RECALL_REPO_ROOT:-$(resolve_repo_root 2>/dev/null)}"
VECTOR_HELPER="${VAULT_RECALL_VECTOR_HELPER:-$REPO_ROOT/scripts/vault-agents/vector_recall_helper.py}"
KEYWORD_HELPER="${VAULT_RECALL_KEYWORD_HELPER:-$REPO_ROOT/scripts/vault-agents/keyword_recall_helper.py}"
PYTHON_BIN="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"

INPUT="$(cat 2>/dev/null || true)"

# session_id/promptを1回のjq呼び出しで取り出す（@tsvはフィールド内のタブ/改行を
# エスケープするため、プロンプトに実改行があっても行が壊れない）。
#
# session_id側の値には固定の非空プレフィックス"S"を付けてから@tsvへ渡し、read後に
# 取り除く（8.1ラウンド・リーダー実機発見の回帰修正: session_idがJSONに存在しない
# 場合、@tsvの1列目が空文字列になり出力が先頭タブ始まり（例: "\tプロンプト"）に
# なる。bashの`read`はIFSに空白類文字（タブは該当）を指定した場合、先頭の連続する
# 区切り文字を「先頭の空白」として読み飛ばしてから分割する仕様があるため、この
# 先頭タブが暗黙に無視されてしまい、本来2列目に入るはずのプロンプト全体が誤って
# 1列目(SESSION_ID)へ詰まり、PROMPTが空文字になってしまっていた（＝候補があっても
# 無言で無出力になる「無言のfail-open」バグ・実機Claude Codeは常にsession_idを
# 送るため実害はなかったが、原則違反かつ手動テストを混乱させるため修正）。
# プレフィックスにより1列目が常に非空になるため、この先頭空白読み飛ばしを回避できる。
JQ_OUT="$(printf '%s' "$INPUT" | jq -r '[("S" + (.session_id // "")), (.prompt // "")] | @tsv' 2>/dev/null)"
JQ_RC=$?
IFS=$'\t' read -r SESSION_ID PROMPT <<< "$JQ_OUT"
SESSION_ID="${SESSION_ID#S}"
if [ "$JQ_RC" -ne 0 ]; then
  log_error "stdin JSONの解析に失敗しました（jq exit ${JQ_RC}）。想起支援をskipします。"
  exit 0
fi

# キーワード・ベクトル両helperへ渡す生プロンプト（@tsvエスケープを経由しない別ルート）。
# 上のPROMPT変数は10文字未満チェック専用として無変更のまま維持し、両helperへの入力には
# こちらを使う（8.1ラウンド2巡目Codexレビュー指摘・Major: @tsvはプロンプト中の実改行を
# "\n"という2文字リテラルへエスケープし、その後の`read -r`はそれを実改行へ戻さないため、
# PROMPTをそのままhelperへ渡すと改行を含む質問で入力が変質する。同じ$INPUTに対して
# .promptだけを単独で取り出す追加のjq呼び出し1回で、実改行を保持した生のプロンプトを
# 別変数として得る）。8.2ラウンドでキーワード照合もPythonへ移った際、変数名を
# VECTOR_PROMPT→RAW_PROMPTへ改名した（ベクトル専用ではなく両helper共通の入力になった
# ため。キーワード照合キーには改行が含まれ得ないため、旧実装がPROMPT(@tsvエスケープ済み)
# を使っていたことによる挙動差は生じない＝リーダー承認済み設計の判断根拠）。
RAW_PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"
if [ $? -ne 0 ]; then
  RAW_PROMPT=""  # 取得失敗時は空文字（helper側の「クエリが空です」経由でfail-open）
fi

# 文字数カウント(${#PROMPT})を多バイト正しく行うため、UTF-8ロケールを明示する
# （実測: LC_ALLを明示しない環境ではbashが日本語をバイト単位で数えてしまう）。
# このLC_ALLは以降起動するPythonサブプロセス(両helper)にも継承される。
# keyword_recall_helper.py はこれを使ってファイル名グロブのソート順（bashの旧glob
# 展開順と同じstrcoll順）を再現している（同ファイルのdocstring参照）。
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

# --- キーワード想起(柱②)・ベクトル想起(柱①)を並列に起動する ---
# GNU timeout非依存のbashネイティブなタイムアウト実装。各helperをバックグラウンド
# 起動し、追加のバックグラウンドプロセス（sleep watcher等）は一切使わず、親shell自身が
# 25ms間隔で両方の生死を同期ポーリングする（8.1ラウンドでベクトル単体について確立した
# 設計をそのまま2プロセス分に拡張しただけ・詳細な設計理由（孤児プロセス問題等）は
# claude/hooks/vault-recall-legacy.sh の該当コメントを参照）。

KW_RELPATHS=(); KW_SCORES=(); KW_KEYLISTS=()
UNREADABLE_NOTE_COUNT=0
KW_OUT_FILE=""; KW_ERR_FILE=""; KW_PID=""; KW_KILL_AFTER_MS=0; KW_RC=""

KW_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-kw-out.XXXXXX" 2>/dev/null)"
KW_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-kw-err.XXXXXX" 2>/dev/null)"
if [ -n "$KW_OUT_FILE" ] && [ -n "$KW_ERR_FILE" ]; then
  # `10#`接頭辞で明示的に10進数として評価する（先頭ゼロ付きの数値がbashの算術展開で
  # 8進数と誤解釈されるのを防ぐ・ベクトル側と同じ対策。詳細はlegacyコメント参照）。
  KW_KILL_AFTER_MS=$((10#$KEYWORD_BUDGET_MS + 10#$KEYWORD_KILL_GRACE_MS))
  # クエリはCLI引数ではなくstdin経由で渡す（`ps`等からの覗き見防止・引数長上限回避。
  # ベクトル側と同じ理由）。
  "$PYTHON_BIN" "$KEYWORD_HELPER" --vault "$VAULT" \
    --budget-ms "$KEYWORD_BUDGET_MS" > "$KW_OUT_FILE" 2>"$KW_ERR_FILE" <<< "$RAW_PROMPT" &
  KW_PID=$!
else
  log_keyword_fail_open "一時ファイルの作成に失敗しました"
fi

VEC_RELPATHS=(); VEC_SCORES=(); VEC_EXTRA_RELPATHS=(); VEC_EXTRA_COUNT=0
VEC_OUT_FILE=""; VEC_ERR_FILE=""; VEC_PID=""; VEC_KILL_AFTER_MS=0; VEC_RC=""
if [ "$VECTOR_DISABLED" != "1" ] && [ -n "$REPO_ROOT" ]; then
  VEC_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-vec-out.XXXXXX" 2>/dev/null)"
  VEC_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-vec-err.XXXXXX" 2>/dev/null)"
  if [ -n "$VEC_OUT_FILE" ] && [ -n "$VEC_ERR_FILE" ]; then
    VEC_KILL_AFTER_MS=$((10#$VECTOR_BUDGET_MS + 10#$VECTOR_KILL_GRACE_MS))
    "$PYTHON_BIN" "$VECTOR_HELPER" --vault "$VAULT" \
      --budget-ms "$VECTOR_BUDGET_MS" > "$VEC_OUT_FILE" 2>"$VEC_ERR_FILE" <<< "$RAW_PROMPT" &
    VEC_PID=$!
  else
    log_vector_fail_open "一時ファイルの作成に失敗しました"
  fi
fi

# 両プロセスの生死を1つのループで同期ポーリングする（監視用の別プロセスを増やさない
# という設計を2プロセス分でも維持するため、KW/VECそれぞれの完了フラグを見ながら
# 1本のループで両方を扱う。片方が先に終わっていればkill -0が即座に失敗しdoneになる
# ため、早期終了のレイテンシは単体時と同じく最大25ms）。
POLL_INTERVAL_MS=25
ELAPSED_MS=0
KW_DONE=1; [ -n "$KW_PID" ] && KW_DONE=0
VEC_DONE=1; [ -n "$VEC_PID" ] && VEC_DONE=0
while [ "$KW_DONE" -eq 0 ] || [ "$VEC_DONE" -eq 0 ]; do
  if [ "$KW_DONE" -eq 0 ] && ! kill -0 "$KW_PID" 2>/dev/null; then KW_DONE=1; fi
  if [ "$VEC_DONE" -eq 0 ] && ! kill -0 "$VEC_PID" 2>/dev/null; then VEC_DONE=1; fi
  [ "$KW_DONE" -eq 1 ] && [ "$VEC_DONE" -eq 1 ] && break
  if [ "$KW_DONE" -eq 0 ] && [ "$ELAPSED_MS" -ge "$KW_KILL_AFTER_MS" ]; then
    kill -9 "$KW_PID" 2>/dev/null
    KW_DONE=1
  fi
  if [ "$VEC_DONE" -eq 0 ] && [ "$ELAPSED_MS" -ge "$VEC_KILL_AFTER_MS" ]; then
    kill -9 "$VEC_PID" 2>/dev/null
    VEC_DONE=1
  fi
  [ "$KW_DONE" -eq 1 ] && [ "$VEC_DONE" -eq 1 ] && break
  sleep 0.025
  ELAPSED_MS=$((ELAPSED_MS + POLL_INTERVAL_MS))
done
if [ -n "$KW_PID" ]; then
  wait "$KW_PID" 2>/dev/null
  KW_RC=$?
fi
if [ -n "$VEC_PID" ]; then
  wait "$VEC_PID" 2>/dev/null
  VEC_RC=$?
fi

# --- キーワード想起の結果を取り込む ---
# keyword_recall_helper.pyは既にスコア降順・同点は走査順にソート済みのJSONを返すため、
# bash側は先頭5件を切り出すだけでよい（旧実装のO(n²)選択ロジックは不要になった）。
if [ -n "$KW_PID" ]; then
  if [ "$KW_RC" -eq 0 ]; then
    KW_JSON="$(cat "$KW_OUT_FILE" 2>/dev/null)"
    # 出力が空、またはJSONスキーマが想定外（本来helperの成功パスでは起こらないが、
    # 破損/差し替えhelperへの防御として検証する）の場合は「候補0件の正常応答」と
    # 誤認せずfail-openとしてログに残す（Codexレビュー指摘・Major: jqは空stdinに
    # 対してexit 0・出力なしを返すため、この検証が無いと無言のfail-openになる）。
    if [ -z "$KW_JSON" ] || ! printf '%s' "$KW_JSON" \
        | jq -e "$KW_SCHEMA_CHECK" >/dev/null 2>&1; then
      log_keyword_fail_open "helper出力が空または想定外の形式です: $(printf '%s' "$KW_JSON" | head -c 200)"
    else
      # 各候補をJSON1行(JSON Lines)として取り出し、relpath/score/keysをそれぞれ
      # jq -rで個別に復号する。@tsvは値中のバックスラッシュ・タブ・改行をエスケープ
      # するが、後段の`read -r`はそれを実文字へ戻さないため、alias中にこれらの文字が
      # 含まれると表示・ログが壊れる（Codexレビュー指摘・Major）。JSON文字列として
      # やり取りし`jq -r`でデコードすれば、どんな文字が混ざっていても正しく復元できる。
      KW_LINES="$(printf '%s' "$KW_JSON" | jq -c \
        '.candidates[]? | {r: .relpath, s: (.score|tostring),
          k: ((.keys // []) | map(.key + (if .partial then " (部分一致)" else "" end)))}' \
        2>/dev/null)"
      KW_JQ_RC=$?
      if [ "$KW_JQ_RC" -eq 0 ]; then
        while IFS= read -r kline; do
          [ -z "$kline" ] && continue
          krel="$(jq -r '.r' <<< "$kline" 2>/dev/null)"
          kscore="$(jq -r '.s' <<< "$kline" 2>/dev/null)"
          kkeys="$(jq -r '.k | join("")' <<< "$kline" 2>/dev/null)"
          [ -z "$krel" ] && continue
          KW_RELPATHS+=("$krel")
          KW_SCORES+=("$kscore")
          KW_KEYLISTS+=("${KEY_SEP}${kkeys}")
        done <<< "$KW_LINES"

        KW_UNREADABLE="$(printf '%s' "$KW_JSON" | jq -r '.unreadable_count // 0' 2>/dev/null)"
        case "$KW_UNREADABLE" in
          ''|*[!0-9]*) KW_UNREADABLE=0 ;;
        esac
        UNREADABLE_NOTE_COUNT=$((UNREADABLE_NOTE_COUNT + KW_UNREADABLE))
      else
        log_keyword_fail_open "helper出力のJSON解析に失敗しました: $(printf '%s' "$KW_JSON" | head -c 200)"
      fi
    fi
  elif [ "$KW_RC" -eq 137 ]; then
    log_keyword_fail_open "helperの応答が予算(${KEYWORD_BUDGET_MS}ms+猶予${KEYWORD_KILL_GRACE_MS}ms)を超えたため強制終了しました"
  else
    KW_ERR="$(head -c 200 "$KW_ERR_FILE" 2>/dev/null)"
    log_keyword_fail_open "helperが異常終了しました（rc=${KW_RC}）: ${KW_ERR}"
  fi
fi
rm -f "$KW_OUT_FILE" "$KW_ERR_FILE" 2>/dev/null

# 読み取れなかったノートが1件以上あれば、ヒット件数に関わらず1回だけ要約ログを残す
# （無言のfail-open防止。ファイルごとに出すとログが荒れるため件数のみ集約する）。
if [ "$UNREADABLE_NOTE_COUNT" -gt 0 ]; then
  log_error "${UNREADABLE_NOTE_COUNT}件のノートを読み取れませんでした（権限不足の可能性・ファイル名キーのみで照合しました）"
fi

N=${#KW_RELPATHS[@]}
# 「候補0件なら即exit」はここではしない（設計書§2.1手順2-3・FR2）。ベクトル候補との
# マージ後（下のFINAL_EMPTYチェック）にまとめて判定する＝キーワード0件のプロンプトでも
# ベクトル想起は常に試みる。

SELECTED_IDX=()
for ((i = 0; i < N && i < 5; i++)); do
  SELECTED_IDX+=("$i")
done

# キーワード枠のCTXは候補が1件以上ある場合のみ組み立てる（キーワード枠の見出し・
# 順序・件数は従来どおり不変＝FR2）。
KEYWORD_CTX=""
if [ "${#SELECTED_IDX[@]}" -gt 0 ]; then
  KEYWORD_CTX="外部脳の関連ノート候補（必要なら Read）:"
  for idx in "${SELECTED_IDX[@]}"; do
    relpath="${KW_RELPATHS[$idx]}"
    # KW_KEYLISTS は先頭にKEY_SEPが付いた "${KEY_SEP}key1${KEY_SEP}key2..." 形式
    # なので、区切りを人間向けの区切りへ置換した後、先頭の余分な区切りを取り除く。
    keys_display="${KW_KEYLISTS[$idx]//$KEY_SEP/, }"
    keys_display="${keys_display#, }"
    KEYWORD_CTX="${KEYWORD_CTX}
- ${relpath}（一致: ${keys_display}）"
  done
fi

# --- ベクトル想起の結果を取り込む ---
# 削除済みノートは helper 側でも実在確認しているが、検索側（ここ）でも防御的に
# 二重チェックする（indexerの最大1時間ラグ対策・付録A FR3ケース6）。
if [ -n "$VEC_PID" ]; then
  if [ "$VEC_RC" -eq 0 ]; then
    VEC_JSON="$(cat "$VEC_OUT_FILE" 2>/dev/null)"
    # 出力が空、またはJSONスキーマが想定外の場合は「候補0件の正常応答」と誤認せず
    # fail-openとしてログに残す（キーワード側と同じ理由・Codexレビュー指摘・Major:
    # jqは空stdinに対してexit 0・出力なしを返すため、この検証が無いと無言のfail-open
    # になる。vector_recall_helper.py自体は無改変＝この検証は呼び出し側の防御として
    # 追加するだけで、helperの出力契約は変えない）。
    if [ -z "$VEC_JSON" ] || ! printf '%s' "$VEC_JSON" \
        | jq -e "$VEC_SCHEMA_CHECK" >/dev/null 2>&1; then
      log_vector_fail_open "helper出力が空または想定外の形式です: $(printf '%s' "$VEC_JSON" | head -c 200)"
    else
      VEC_LINES="$(printf '%s' "$VEC_JSON" | jq -r '.candidates[]? | "\(.relpath)\t\(.score)"' 2>/dev/null)"
      VEC_JQ_RC=$?
      if [ "$VEC_JQ_RC" -eq 0 ]; then
        while IFS=$'\t' read -r vrel vscore; do
          [ -z "$vrel" ] && continue
          VEC_RELPATHS+=("$vrel")
          VEC_SCORES+=("$vscore")
        done <<< "$VEC_LINES"
        # 削除済みノートの除外件数もfail-open 6ケース(付録A FR3ケース6)の一部として
        # 1箇所のログへ集約する（Codexレビュー指摘・Major: この事象だけが唯一
        # 無言で正常終了扱いになっていたため、要件の「全ケースでexit0・ERRORログ」
        # 6ケース目もログに残るようにする。ヒット自体は正常に成立するため、これは
        # 候補提示を止めない=fail-openのままログだけ足す）。
        EXCLUDED_MISSING="$(printf '%s' "$VEC_JSON" | jq -r '.excluded_missing // 0' 2>/dev/null)"
        case "$EXCLUDED_MISSING" in
          ''|*[!0-9]*) : ;;  # 数値以外(壊れた応答等)はログしない・素通り
          0) : ;;
          # これは失敗ではなく正常系（インデックスの最大1時間ラグを検索側が吸収した
          # だけ）なので log_vector_fail_open は使わず、直接 log_error で事実だけ記録する
          # （"fail-openでskipしました"という誤解を招く文言を避けるため）。
          *) log_error "削除済みノートのベクトル残存を${EXCLUDED_MISSING}件除外しました（インデックスの最大1時間ラグ・付録A FR3ケース6・候補提示自体は正常）" ;;
        esac
      else
        log_vector_fail_open "helper出力のJSON解析に失敗しました: $(printf '%s' "$VEC_JSON" | head -c 200)"
      fi
    fi
  elif [ "$VEC_RC" -eq 137 ]; then
    log_vector_fail_open "helperの応答が予算(${VECTOR_BUDGET_MS}ms+猶予${VECTOR_KILL_GRACE_MS}ms)を超えたため強制終了しました"
  else
    VEC_ERR="$(head -c 200 "$VEC_ERR_FILE" 2>/dev/null)"
    log_vector_fail_open "helperが異常終了しました（rc=${VEC_RC}）: ${VEC_ERR}"
  fi
fi
rm -f "$VEC_OUT_FILE" "$VEC_ERR_FILE" 2>/dev/null

# --- キーワード候補∪(ベクトル候補のうちキーワード候補に無いもの・最大3件) ---
# （設計書§2.1手順5）。
VECTOR_CTX=""
VN=${#VEC_RELPATHS[@]}
for ((i = 0; i < VN && VEC_EXTRA_COUNT < MAX_VECTOR_EXTRA; i++)); do
  vrel="${VEC_RELPATHS[$i]}"
  already=0
  for idx in "${SELECTED_IDX[@]}"; do
    if [ "${KW_RELPATHS[$idx]}" = "$vrel" ]; then already=1; break; fi
  done
  [ "$already" -eq 1 ] && continue
  # 起動必読ファイル（EXCLUDE_RELPATHS）はキーワード枠と同様にベクトル枠でも除外する
  # （Personal想起対象化に伴うリーダー指示。従来はキーワード照合ループでしか
  # チェックしておらず、ベクトル側は素通りする隙間があったため合わせて塞いだ）。
  vexcluded=0
  for ex in "${EXCLUDE_RELPATHS[@]}"; do
    if [ "$vrel" = "$ex" ]; then vexcluded=1; break; fi
  done
  [ "$vexcluded" -eq 1 ] && continue
  [ -f "$VAULT/$vrel" ] || continue
  if [ "$VEC_EXTRA_COUNT" -eq 0 ]; then
    VECTOR_CTX="意味的に近い候補（キーワード一致なし・必要なら Read）:"
  fi
  VECTOR_CTX="${VECTOR_CTX}
- ${vrel}（類似度: ${VEC_SCORES[$i]}）"
  VEC_EXTRA_RELPATHS[$VEC_EXTRA_COUNT]="$vrel"
  VEC_EXTRA_COUNT=$((VEC_EXTRA_COUNT + 1))
done

# キーワード・ベクトルの両方が空なら、ここで初めて無出力exitする（従来の
# 「候補0件なら即exit」相当の判定をマージ後の位置へ移動＝設計書§2.1手順2-3）。
if [ -z "$KEYWORD_CTX" ] && [ -z "$VECTOR_CTX" ]; then
  exit 0
fi

# キーワード枠とベクトル枠を別セクションとして連結する（見出しで区別できるように
# する・設計書§2.1手順5「別枠表示」）。
CTX="$KEYWORD_CTX"
if [ -n "$VECTOR_CTX" ]; then
  if [ -n "$CTX" ]; then
    CTX="${CTX}

${VECTOR_CTX}"
  else
    CTX="$VECTOR_CTX"
  fi
fi

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
  keys_log="${KW_KEYLISTS[$idx]//$KEY_SEP/,}"
  keys_log="${keys_log#,}"
  log_row "${SESSION_ID}	${KW_RELPATHS[$idx]}	${keys_log}"
done
for ((i = 0; i < VEC_EXTRA_COUNT; i++)); do
  log_row "${SESSION_ID}	${VEC_EXTRA_RELPATHS[$i]}	(ベクトル類似)"
done

printf '%s\n' "$OUT_JSON"
exit 0
