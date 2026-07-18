#!/bin/bash
# UserPromptSubmit hook: 外部脳(Obsidian)の想起支援。
#
# 目的: プロンプト本文に、Vaultのノート名/aliasesが「そのまま文字列として含まれて
# いる」場合、そのノートを「候補」として短く提示する（本文は注入しない＝
# additionalContextの肥大化・切り詰め事故を防ぐ。bootstrap-vault.shと同じ教訓）。
# 最終判断（実際にReadするか）はAI/リーダーに委ねる。
#
# 2026-07-16 簡素化（[[Decisions/2026-07-16-remove-vector-search-embedding-infra]]）:
# 埋め込み基盤ごと撤去し、想起はキーワード照合1本に戻した（1プロセス化）。
# 8.1/8.2ラウンドで並列起動していたvector_recall_helper.py（柱①・Ollama embed→
# cosine類似）は削除済み。以後は keyword_recall_helper.py を単独でサブプロセス
# 起動するだけの薄い殻になる。並列2プロセスの生死監視・自己打ち切り（段階縮退）・
# VEC_*系の変数はすべて不要になったため削除した（旧実装の設計理由（照合方式・
# tie-break・fail-open方針・段階縮退等）を読みたい場合は
# `git log -- claude/hooks/vault-recall-legacy.sh` `git log -p claude/hooks/vault-recall.sh`
# でロールバック用アーカイブ・旧版を参照。vault-recall-legacy.sh自体は本簡素化で
# 削除した）。
#
# 照合方式そのもの（全体一致＋トークン部分一致・スコア計算・活用形/カタカナ境界の
# フォールバック等）はkeyword_recall_helper.py側のdocstring・各関数コメントに移設した。
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

# 1ノート内で複数ヒットしたキーを連結する際の内部区切り文字（表示直前まで使う）。
# 半角スペースだと alias 自体に空白を含む場合（例: "fail, open"）に表示用の
# スペース→", "置換でキー内部の空白まで壊れるため、通常のalias文字列にまず
# 出現しない制御文字(Unit Separator)にする（Codexレビュー指摘・Major回帰）。
# keyword_recall_helper.pyのJSON出力(keys配列)からこの区切りへ組み直して使う。
KEY_SEP=$'\x1f'

# 起動必読ファイル（bootstrap-vault.shと同じ6件）の除外はkeyword_recall_helper.py
# 側のEXCLUDE_RELPATHSで行う（旧実装ではベクトル候補側の除外チェックにのみ
# bash側でも同じリストを重複定義していたが、ベクトル枠の撤去でその使用箇所ごと
# 不要になったため削除した＝2箇所同期の運用負担を1箇所へ削減）。

# keyword_recall_helper.pyの出力JSONを取り込む前に通すスキーマ検証式（jq -e用）。
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

# ISO8601時刻+TSV1行を$LOG_FILEへ追記する（ディレクトリ自動作成）。
# 失敗しても握りつぶす（ログ書き込み自体がプロンプト処理を止めてはいけない）。
log_row() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s\t%s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# この呼び出し内でlog_error()が1回でも呼ばれたか。ハートビート(log_heartbeat())は
# このフラグが立っていれば書かない＝「ヒット0件」がkeyword helperのfail-open
# （異常終了・timeout・JSON壊れ等）によるものだった場合にまでハートビートを書くと、
# その行がvault_inventory.py/check-drift.shの「有効な記録」として扱われてしまい、
# 本来検知したい「動いているが失敗し続けている(ERRORING/recall_log_broken)」を隠して
# しまう（無言のfail-openを可観測にするという既存方針そのものへの回帰）。
# log_fact()（パイプライン正常完走時の事実記録）はこのフラグを立てない（下記参照）。
PIPELINE_HAD_ERROR=0

# 想定外のエラー用ログ。vault_inventory.py の read_log() は同じ vault-recall.tsv を
# 「ts\tsession_id\tノート相対パス[\t一致キー]」として読み、3列目をノートパス（未読
# 判定・提示回数カウント）に使う。ERROR行の3列目にエラーメッセージを置くと、
# 存在しないノートパスとして誤集計されてしまうため、3列目は空文字にして無害化する
# （4列目以降はread_log()が読まないため自由に使える。session_id・メッセージはそちらへ）。
# Knowledge/fail-open-and-observable-guards の「無言のfail-openは可観測にする」の実装。
#
# メッセージ・session_id・relpath・一致キーなど、ログ行へ埋め込む可変長フィールド
# にタブ/CR/改行が混入すると、log_row()が組み立てるTSV行の列がずれてしまうため、
# log_row()を呼ぶ全箇所でこの関数を通す方針にした。
sanitize_log_field() {
  local s="$1"
  s="${s//$'\t'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

log_error() {
  PIPELINE_HAD_ERROR=1
  log_row "ERROR		${SAFE_SESSION_ID:-}	$(sanitize_log_field "$1")"
}

# log_error()の呼び出し箇所は「真の失敗(fail-open)」と「パイプラインが正常完走した
# 上での事実記録」（読取不可ノート件数）の2種類を区別する必要がある。2列目の固定
# 文字列"ERROR"は下流(vault_inventory.py read_log()・check-drift.sh)の契約なので
# 変えない。代わりに行末へ機械可読なレベル列を追加する: 真の失敗(log_error())は
# 従来どおりレベル列を省略し、事実記録(log_fact())だけ6列目に固定文字列"INFO"
# (LOG_LEVEL_INFO)を付与する。下流は列数を厳密固定していないため、この6列目の追加では
# 壊れない。
#
# log_error()と違い、PIPELINE_HAD_ERRORは立てない（読取不可ノートが常在する等で
# 毎回log_fact()だけが発生し続ける状況では候補0件時のハートビートが永久に抑止され、
# HEARTBEAT_REFRESH_AFTER_S（下のlog_heartbeat()参照）による7日超セッションでの
# STALE偽検知対策そのものが無効化されてしまう。log_fact()は「パイプラインは正常
# 完走した」ことの記録であり、この呼び出し単独でハートビートを妨げる理由が無い）。
LOG_LEVEL_INFO='INFO'
log_fact() {
  log_row "ERROR		${SAFE_SESSION_ID:-}	$(sanitize_log_field "$1")	${LOG_LEVEL_INFO}"
}

# キーワード想起のfail-open集約ログ。keyword_recall_helper.pyの起動失敗・timeout・
# 異常終了・出力JSON壊れのいずれもここを通す。
log_keyword_fail_open() {
  log_error "キーワード想起をfail-openでskipしました: $1"
}

# ハートビート行。vault-recall.tsvは従来ヒット時のみ記録していたため、「想起
# パイプラインを走らせた上でヒット0件だった健全な日」と「フックそのものが死んで
# いる（一度も実行されていない）」がログ単独で区別できなかった
# （[[Decisions/2026-07-10-vault-recall-and-metrics]] round2既知の限界）。想起
# パイプラインを最後まで走らせた結果ヒット0件だった呼び出しでは、この関数で1行だけ
# 生存記録を残す。
#
# 短すぎるプロンプト(10文字未満)でパイプライン自体を試みずに終わる早期exitでは
# 呼ばない（想定スコープ外＝round2の課題は「マッチングを実際に試みたのに0件」
# の場合の区別であり、短文早期exitは従来どおり無出力のまま＝既存挙動・既存テスト
# （tests/test-vault-recall.sh 6番）を変えない。短文プロンプトの連投で毎回1行
# 書かれ続けるログ肥大も避けられる）。Vault不在・stdin JSON解析失敗などの
# 既存ERROR経路でも呼ばない（そこは既にlog_errorが「動いているが失敗し続けている」
# ことを示す記録を残しており、ハートビートを重ねるとcheck-drift.shのERRORING
# 検知・vault_inventory.pyのrecall_log_broken判定が「実は失敗し続けているのに
# 健全な有効行がある」と誤認する回帰になるため、意図的に対象外にする）。
#
# 同じ理由で、この呼び出し中にkeyword helperのfail-open（log_error()経由）が
# 1回でも発生していた場合も書かない＝PIPELINE_HAD_ERRORで判定する。
#
# フォーマット: 通常のヒット行と同じ3列構成（ts\tsession_id\t固定マーカー）で書く。
# vault_inventory.py の read_log() と check-drift.sh の log_last_valid_line_age_days()
# はいずれも「3列目(本来はノート相対パス)が空でない行」を『有効な記録』として鮮度・
# 死活判定に使う契約（両ファイルの該当コメント参照）。ERROR行の形式(3列目を空にする)
# で書くと、この「有効な記録」扱いを受けられず、ヒット0件が続くと従来どおり
# 「フックは動いているが失敗し続けている」という誤ったERRORING/recall_log_broken
# 判定を招いてしまう＝ハートビートの目的（生存を示す）を果たせない。3列目に実在
# ノートと衝突しない固定マーカー(HEARTBEAT_MARKER・実在パスには現れない括弧付き
# 文字列)を置くことで、既存パーサを「有効な記録」として正しく通す。副作用として
# vault_inventory.py §12 の「提示回数上位」「提示無視率ワースト」の集計に、実ノート
# ではないこのマーカーが1エントリ（人間が見て一目で実ノートではないと分かる表記）
# として混ざる。実害の小さいトレードオフとして許容する。
#
# ログ肥大対策: 直前1行が既に同一session_idのハートビートであれば書き込みを省略
# する（tail -1のみを見る軽量な抑制＝厳密な重複排除ではないが、同一セッション内で
# ヒット0件の呼び出しが連続するケースの大半を低コストで間引ける）。
#
# ただし無条件の抑制だと、1回のセッションがVAULT_AGENT_LOG_STALE_DAYS（check-drift.sh
# 既定7日）を超えて連続稼働し、その間ずっとヒット0件が続いた場合、ログの最終行が
# セッション開始直後の1回で凍結されたまま更新されなくなる。この状態でSTALE閾値を
# 超えると、フックは実際には動き続けているのにcheck-drift.shが「フック停止の疑い
# (STALE)」という偽の警告を出してしまう。HEARTBEAT_REFRESH_AFTER_S（既定1日）ごとに
# 同一セッションでもハートビートを書き直すことで、最終行の経過日数がSTALE閾値を
# 構造的に超え続けないようにする（既定値なら7日のうちに最低6回は更新される計算で、
# 閾値7日に対して十分な安全マージンがある）。
HEARTBEAT_MARKER='(heartbeat)'
HEARTBEAT_REFRESH_AFTER_S="${VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S:-86400}"
# 7桁以上（100万秒=約11.6日以上）も既定値へフォールバックする（HOOK_BUDGET_MS等と
# 同じ桁数上限ガード。想起フックの再書込み間隔として現実的な値は最大でも数十日の
# オーダーであり、6桁≒999999秒(約11.6日)あれば十分な余裕がある。上限が無いと極端な
# 数字列がbashの`[ -lt ]`整数比較でエラーになりうる＝結果的にはfail-open側へ倒れるが、
# 意図しないstderrノイズを避ける）。
case "$HEARTBEAT_REFRESH_AFTER_S" in
  ''|*[!0-9]*|???????*) HEARTBEAT_REFRESH_AFTER_S=86400 ;;
esac

# 直前のハートビート行のタイムスタンプ($1・ISO8601 "YYYY-MM-DDTHH:MM:SSZ"）を解析し、
# 現在時刻からの経過秒数が0以上HEARTBEAT_REFRESH_AFTER_S未満なら「まだ新しい」
# (戻り値0=true)を返す。macOSのBSD `date -j`でパースする（check-drift.shの
# log_last_valid_line_age_days()と同じ実装方針・本リポジトリはmacOS専用の3年
# ノーメンテ運用が前提）。解析に失敗した場合はfail-open寄りに「新しくない」(戻り値1)
# を返し、抑制せずハートビートを書く方向へ倒す（無条件抑制に戻って最終行が凍結され
# 続ける事故より、多少ログが増える方が安全）。経過秒数が負（直前行のタイムスタンプが
# 未来＝システム時計のズレ・ログ破損等）の場合も同様に「新しくない」扱いにする
# （素朴に`-lt`だけで判定すると負の経過秒数は常に閾値未満＝「新しい」と誤判定され、
# 壊れた未来日時のハートビートが永久に抑制され続けてしまう）。
#
# date -jへ渡す前に、固定桁のcaseパターンで厳密に"YYYY-MM-DDTHH:MM:SSZ"形式のみを
# 受理する（BSD `date -j -f`はパース成功可否だけでは検証にならないほど寛容で、桁不足・
# 末尾の余剰文字・末尾"Z"欠落もエラーにせず解釈してしまう）。
heartbeat_last_is_fresh() {
  local ts="$1" ts_clean epoch now_epoch elapsed
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) return 1 ;;
  esac
  ts_clean="${ts%Z}"
  epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null)" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  now_epoch="$(date -u +%s 2>/dev/null)" || return 1
  case "$now_epoch" in ''|*[!0-9]*) return 1 ;; esac
  elapsed=$((10#$now_epoch - 10#$epoch))
  [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$HEARTBEAT_REFRESH_AFTER_S" ]
}

log_heartbeat() {
  local last last_ts
  # この呼び出し中に1回でもlog_error()が呼ばれていれば書かない（PIPELINE_HAD_ERROR・
  # 上のコメント参照）。
  [ "$PIPELINE_HAD_ERROR" -ne 0 ] && return 0
  last="$(tail -1 "$LOG_FILE" 2>/dev/null)"
  case "$last" in
    *$'\t'"${SAFE_SESSION_ID:-}"$'\t'"${HEARTBEAT_MARKER}")
      # 直前行が同一セッションのハートビートでも、それがHEARTBEAT_REFRESH_AFTER_S以上
      # 前であれば抑制せず書き直す（上のコメント参照）。
      last_ts="${last%%$'\t'*}"
      heartbeat_last_is_fresh "$last_ts" && return 0
      ;;
  esac
  log_row "${SAFE_SESSION_ID:-}	${HEARTBEAT_MARKER}"
}

# --- 予算・タイムアウト関連の設定 ---
# 内部timeout（要件v2決定h・当初500ms暫定→2026-07-12に1000msへ変更・本人指示）。
# 埋め込み基盤撤去に伴いコールド再ロード等のシビアな事情は無くなったが、値そのものは
# 変えない（キーワード照合はローカルI/Oのみで通常は数十ms程度に収まり、この予算は
# Vault肥大化等の保険として機能する）。
KEYWORD_BUDGET_MS="${VAULT_RECALL_KEYWORD_BUDGET_MS:-1000}"
KEYWORD_KILL_GRACE_MS="${VAULT_RECALL_KEYWORD_KILL_GRACE_MS:-150}"

# 非負整数であることを検証し、不正値（空文字/小数/負数/数字以外）は既定値へフォール
# バックする（後段でこれらの値をbashの算術展開$(( ))へ直接渡すポーリングループに
# 変更したため、環境変数が不正だと算術構文エラーでフック自体が「いかなるエラーでも
# exit 0」というhook契約に反して異常終了しかねない）。
case "$KEYWORD_BUDGET_MS" in
  ''|*[!0-9]*) KEYWORD_BUDGET_MS=1000 ;;
esac
case "$KEYWORD_KILL_GRACE_MS" in
  ''|*[!0-9]*) KEYWORD_KILL_GRACE_MS=150 ;;
esac

# 想起候補の表示上限（FR2）。従来はキーワード枠側がループ内のリテラル`5`のまま
# ハードコードされており、recall_bench.pyのMAX_KEYWORD_CANDIDATES（SSOT検証テスト・
# tests/test-recall-bench.sh）はこのリテラルをgrepで抽出する脆いSSOTだった。
# 名前付き定数へ切り出し、値そのものは変えない（5のまま）。
MAX_KEYWORD_CANDIDATES=5   # キーワード枠（先頭スコア順）の表示上限（FR2）

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
# 以降のログ書き込みは全てこのサニタイズ済み値を使う（log_error()/log_fact()だけで
# なく、ハートビート・提示ログの全ての書き込み経路で同じ値を使う。session_idは
# 実運用では常にUUID相当だが、理論上JSON経由でタブ・改行を含む値が来ても、書き込み時
# だけサニタイズして直前行との比較(tail -1一致判定)には生の値を使う…という実装だと、
# 両者がズレて意図しない二重書き込み等の不整合を招く。1箇所で確定させ全経路で使い
# 回すことでそのズレを避ける）。
SAFE_SESSION_ID="$(sanitize_log_field "${SESSION_ID:-}")"
if [ "$JQ_RC" -ne 0 ]; then
  log_error "stdin JSONの解析に失敗しました（jq exit ${JQ_RC}）。想起支援をskipします。"
  exit 0
fi

# keyword_recall_helper.pyへ渡す生プロンプト（@tsvエスケープを経由しない別ルート）。
# 上のPROMPT変数は10文字未満チェック専用として無変更のまま維持し、helperへの入力には
# こちらを使う（@tsvはプロンプト中の実改行を"\n"という2文字リテラルへエスケープし、
# その後の`read -r`はそれを実改行へ戻さないため、PROMPTをそのままhelperへ渡すと改行を
# 含む質問で入力が変質する。同じ$INPUTに対して.promptだけを単独で取り出す追加のjq
# 呼び出し1回で、実改行を保持した生のプロンプトを別変数として得る）。
RAW_PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"
if [ $? -ne 0 ]; then
  RAW_PROMPT=""  # 取得失敗時は空文字（helper側の「クエリが空です」経由でfail-open）
fi

# 文字数カウント(${#PROMPT})を多バイト正しく行うため、UTF-8ロケールを明示する
# （実測: LC_ALLを明示しない環境ではbashが日本語をバイト単位で数えてしまう）。
# このLC_ALLは以降起動するPythonサブプロセス(keyword_recall_helper.py)にも継承される。
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

# --- キーワード想起を起動する ---
# GNU timeout非依存のbashネイティブなタイムアウト実装。helperをバックグラウンド
# 起動し、追加のバックグラウンドプロセス（sleep watcher等）は一切使わず、親shell自身が
# 25ms間隔で生死をポーリングする（旧実装（2プロセス並列監視）を1プロセス分に単純化
# しただけ・詳細な設計理由（孤児プロセス問題等）は
# `git log -- claude/hooks/vault-recall-legacy.sh` の該当コメントを参照）。

KW_RELPATHS=(); KW_SCORES=(); KW_KEYLISTS=()
UNREADABLE_NOTE_COUNT=0
KW_OUT_FILE=""; KW_ERR_FILE=""; KW_PID=""; KW_KILL_AFTER_MS=0; KW_RC=""

KW_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-kw-out.XXXXXX" 2>/dev/null)"
KW_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-kw-err.XXXXXX" 2>/dev/null)"
if [ -n "$KW_OUT_FILE" ] && [ -n "$KW_ERR_FILE" ]; then
  # `10#`接頭辞で明示的に10進数として評価する（先頭ゼロ付きの数値がbashの算術展開で
  # 8進数と誤解釈されるのを防ぐ）。
  KW_KILL_AFTER_MS=$((10#$KEYWORD_BUDGET_MS + 10#$KEYWORD_KILL_GRACE_MS))
  # クエリはCLI引数ではなくstdin経由で渡す（`ps`等からの覗き見防止・引数長上限回避）。
  "$PYTHON_BIN" "$KEYWORD_HELPER" --vault "$VAULT" \
    --budget-ms "$KEYWORD_BUDGET_MS" > "$KW_OUT_FILE" 2>"$KW_ERR_FILE" <<< "$RAW_PROMPT" &
  KW_PID=$!
else
  log_keyword_fail_open "一時ファイルの作成に失敗しました"
fi

POLL_INTERVAL_MS=25
ELAPSED_MS=0
KW_DONE=1; [ -n "$KW_PID" ] && KW_DONE=0
while [ "$KW_DONE" -eq 0 ]; do
  if ! kill -0 "$KW_PID" 2>/dev/null; then KW_DONE=1; break; fi
  if [ "$ELAPSED_MS" -ge "$KW_KILL_AFTER_MS" ]; then
    kill -9 "$KW_PID" 2>/dev/null
    KW_DONE=1
    break
  fi
  sleep 0.025
  ELAPSED_MS=$((ELAPSED_MS + POLL_INTERVAL_MS))
done
if [ -n "$KW_PID" ]; then
  wait "$KW_PID" 2>/dev/null
  KW_RC=$?
fi

# --- キーワード想起の結果を取り込む ---
# keyword_recall_helper.pyは既にスコア降順・同点は走査順にソート済みのJSONを返すため、
# bash側は先頭MAX_KEYWORD_CANDIDATES件を切り出すだけでよい。
if [ -n "$KW_PID" ]; then
  if [ "$KW_RC" -eq 0 ]; then
    KW_JSON="$(cat "$KW_OUT_FILE" 2>/dev/null)"
    # 出力が空、またはJSONスキーマが想定外（本来helperの成功パスでは起こらないが、
    # 破損/差し替えhelperへの防御として検証する）の場合は「候補0件の正常応答」と
    # 誤認せずfail-openとしてログに残す（jqは空stdinに対してexit 0・出力なしを返す
    # ため、この検証が無いと無言のfail-openになる）。
    if [ -z "$KW_JSON" ] || ! printf '%s' "$KW_JSON" \
        | jq -e "$KW_SCHEMA_CHECK" >/dev/null 2>&1; then
      log_keyword_fail_open "helper出力が空または想定外の形式です: $(printf '%s' "$KW_JSON" | head -c 200)"
    else
      # 各候補をJSON1行(JSON Lines)として取り出し、relpath/score/keysをそれぞれ
      # jq -rで個別に復号する。@tsvは値中のバックスラッシュ・タブ・改行をエスケープ
      # するが、後段の`read -r`はそれを実文字へ戻さないため、alias中にこれらの文字が
      # 含まれると表示・ログが壊れる。JSON文字列としてやり取りし`jq -r`でデコード
      # すれば、どんな文字が混ざっていても正しく復元できる。
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
          # 区切りにはbash側のKEY_SEP(Unit Separator制御文字)を使う。旧実装はjq
          # フィルタのリテラル内に生の制御バイトを埋め込んでいたが、テキスト
          # 編集時に不可視文字が消失するリスクがあるため、`--arg`経由の明示的な
          # 変数渡しに直す（挙動は不変。この事故は本改修の自己レビューで発見・修正）。
          kkeys="$(jq -r --arg sep "$KEY_SEP" '.k | join($sep)' <<< "$kline" 2>/dev/null)"
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
  # これも失敗ではなく正常系（ファイル名キーのみへフォールバックしただけでパイプ
  # ラインは完走している）なのでlog_fact()で事実だけ記録する。
  log_fact "${UNREADABLE_NOTE_COUNT}件のノートを読み取れませんでした（権限不足の可能性・ファイル名キーのみで照合しました）"
fi

N=${#KW_RELPATHS[@]}

SELECTED_IDX=()
for ((i = 0; i < N && i < MAX_KEYWORD_CANDIDATES; i++)); do
  SELECTED_IDX+=("$i")
done

# キーワード枠のCTXは候補が1件以上ある場合のみ組み立てる（見出し・順序・件数は
# 従来どおり不変＝FR2）。
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

# ヒット無しなら、ここで無出力exitする。想起パイプラインを最後まで走らせた結果と
# しての「健全なヒット0件」なので、ここでハートビートを1行残す（log_heartbeat()の
# コメント参照・round2からの宿題）。
if [ -z "$KEYWORD_CTX" ]; then
  log_heartbeat
  exit 0
fi

CTX="$KEYWORD_CTX"

# 出力生成の失敗も「無言のfail-open」にしない（スクリプト最後のコマンドがそのまま
# exit codeになるため、jq自体がここで失敗すると「必ずexit 0」の契約が破れる。
# 一度変数へ受けてから明示的にexit 0する）。
OUT_JSON="$(jq -n --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null)"
JQ_OUT_RC=$?
if [ "$JQ_OUT_RC" -ne 0 ] || [ -z "$OUT_JSON" ]; then
  log_error "出力JSONの生成に失敗しました（jq exit ${JQ_OUT_RC}）。想起支援をskipします。"
  exit 0
fi

# 提示ログへの追記は、出力生成が成功した後（＝実際にadditionalContextとして
# 提示することが確定した後）に行う（従来はCTX組み立てと同時にlog_rowしていたため、
# 最終jqが失敗した場合に「提示していないのに提示済みとしてログされる」誤集計が
# 起き得た）。
#
# relpath・一致キーもsanitize_log_field()を通す（これらはVault内のファイル名・
# alias文字列（ユーザーが自由に記述できるMarkdownノートの内容）由来のため、理論上
# タブ・改行を含み得る）。
for idx in "${SELECTED_IDX[@]}"; do
  keys_log="${KW_KEYLISTS[$idx]//$KEY_SEP/,}"
  keys_log="${keys_log#,}"
  log_row "${SAFE_SESSION_ID:-}	$(sanitize_log_field "${KW_RELPATHS[$idx]}")	$(sanitize_log_field "$keys_log")"
done

printf '%s\n' "$OUT_JSON"
exit 0
