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

# 現在時刻をミリ秒精度のepochで返す（8.3ラウンド新設・自己打ち切り(段階縮退)の
# 経過時間計測用）。`%N`(ナノ秒)はGNU date由来の拡張だが、実行環境(macOS)のBSD dateも
# 現時点では%Nに対応していることを実機確認済み。ただしOS更新等で将来サポートが
# 落ちる可能性はゼロではない（3年ノーメンテ運用が前提のため）ため、出力が純粋な
# 数字列でない・桁数が想定(19桁=秒10桁+ナノ秒9桁)ちょうどでない場合は空文字を返し、
# 呼び出し側で自己打ち切り判定そのものを無効化する（fail-open。既存のkill-after
# 到達待ちが最終防衛線のため、この計測が使えないこと自体はプロンプト処理を止める
# 理由にしない）。桁数を「ちょうど19桁」に固定する（Codex一次レビュー指摘・Minor:
# 以前は19桁未満のみ拒否しており、20桁以上の想定外な出力（壊れたdate実装等）を
# そのまま算術展開へ渡してしまい、桁数上限チェックを新設した意味が薄れていた。
# epoch秒が11桁化するのは西暦2286年以降のため、3年運用スコープでは19桁固定で
# 実用上問題ない）。
now_ms() {
  local raw
  raw="$(date +%s%N 2>/dev/null)"
  case "$raw" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "${#raw}" -ne 19 ]; then
    return 0
  fi
  echo $((10#$raw / 1000000))
}
# フック起動からの経過時間（自己打ち切り判定の起点）。できるだけ早い時点＝この
# スクリプトの実質的な先頭で採取する。
HOOK_START_MS="$(now_ms)"

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

# この呼び出し内でlog_error()が1回でも呼ばれたか（8.3ラウンド新設・Codex一次
# レビュー指摘・Major対応）。ハートビート(log_heartbeat())はこのフラグが立って
# いれば書かない＝「ヒット0件」の内訳がkeyword/vectorのfail-open（helper異常終了・
# timeout・JSON壊れ等）によるものだった場合にまでハートビートを書くと、その行が
# vault_inventory.py/check-drift.shの「有効な記録」として扱われてしまい、本来
# 検知したい「動いているが失敗し続けている(ERRORING/recall_log_broken)」を隠して
# しまう（無言のfail-openを可観測にするという既存方針そのものへの回帰）。自己打ち切り
# （段階縮退）もlog_vector_fail_open経由でlog_error()を通るため同様に対象外になるが、
# これは意図した簡素化（自己打ち切りが常態化＝環境が慢性的に遅い状態も「動いてはいる
# が正常に完了できていない」という点でERRORING相当の観測価値があるため、あえて
# 区別しない）。log_fact()（パイプライン正常完走時の事実記録・2026-07-14修正）は
# このフラグを立てない＝log_error()とは異なる（Codex一次レビュー指摘・Major対応:
# 詳細はlog_fact()コメント参照。真の失敗ではないため、候補0件時のハートビートを
# 妨げない）。
PIPELINE_HAD_ERROR=0

# 想定外のエラー用ログ。vault_inventory.py の read_log() は同じ vault-recall.tsv を
# 「ts\tsession_id\tノート相対パス[\t一致キー]」として読み、3列目をノートパス（未読
# 判定・提示回数カウント）に使う。ERROR行の3列目にエラーメッセージを置くと、
# 存在しないノートパスとして誤集計されてしまうため、3列目は空文字にして無害化する
# （4列目以降はread_log()が読まないため自由に使える。session_id・メッセージはそちらへ）。
# Knowledge/fail-open-and-observable-guards の「無言のfail-openは可観測にする」の実装。
#
# メッセージ・session_id・relpath・一致キーなど、ログ行へ埋め込む可変長フィールド
# にタブ/CR/改行が混入すると、log_row()が組み立てるTSV行の列がずれてしまう
# （2026-07-14修正・Codex一次レビュー指摘・Major: 特にhelperのstderr先頭200バイトを
# そのまま埋め込んでいる呼び出し元があり、破損/差し替えhelperがたまたまタブや改行を
# 含む出力をした場合、意図しない列が生成されうる。log_fact()の6列目マーカーは
# recall_bench.py側で「真の失敗ではない」の判定にも使うため、最悪の場合真の失敗
# メッセージの末尾がたまたま"\tINFO"のように見えると誤って無害判定されうる＝可観測性
# が本来検知すべき失敗を隠しかねない。relpath・一致キーはVault内のノート内容
# （ユーザーが自由に書けるファイル名・alias文字列）由来で同様の理論的リスクがある
# ため、log_row()を呼ぶ全箇所でこの関数を通す方針にした）。書き込み前にタブ・CR・LFを
# 安全な代替（半角スペース）へ正規化する。
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

# log_error()の呼び出し箇所は従来、「真の失敗(fail-open)」と「パイプラインが正常
# 完走した上での事実記録」（削除済みノートのベクトル残存除外・読取不可ノート件数）の
# 2種類を同一のERROR行形式で混在させていた。recall_bench.py/measure_recall_latency.py
# はこの2種類をメッセージ本文の部分一致だけで判別しており、hook側の文言が変わると
# 無言で判別が壊れる脆い状態だった（2026-07-14修正・外部脳の想起・ベンチ機構の総点検）。
#
# 2列目の固定文字列"ERROR"は下流(vault_inventory.py read_log()・check-drift.sh)の契約
# なので変えない。代わりに行末へ機械可読なレベル列を追加する: 真の失敗(log_error())は
# 従来どおりレベル列を省略し、事実記録(log_fact())だけ6列目に固定文字列"INFO"
# (LOG_LEVEL_INFO)を付与する。下流は列数を厳密固定していないため、この6列目の追加では
# 壊れない（recall_bench.py側は本日の修正でこの列を読むよう追随、measure_recall_
# latency.pyは無改修のまま従来の文言部分一致で動き続ける＝互換性を確認済み）。
#
# log_error()と違い、PIPELINE_HAD_ERRORは立てない（2026-07-14修正・Codex一次レビュー
# 指摘・Major: 立てたままだと、読取不可ノートが常在する等で毎回log_fact()だけが
# 発生し続ける状況では候補0件時のハートビートが永久に抑止され、
# HEARTBEAT_REFRESH_AFTER_S（上のlog_heartbeat()参照）による7日超セッションでの
# STALE偽検知対策そのものが無効化されてしまう。log_fact()は「パイプラインは正常
# 完走した」ことの記録であり、この呼び出し単独でハートビートを妨げる理由が無い）。
LOG_LEVEL_INFO='INFO'
log_fact() {
  log_row "ERROR		${SAFE_SESSION_ID:-}	$(sanitize_log_field "$1")	${LOG_LEVEL_INFO}"
}

# ベクトル想起のfail-openをすべて1箇所へ集約するログ関数（付録A FR3の6ケースのうち
# 「真の失敗」である5ケース＝Ollama不在／応答timeout／インデックス破損・JSON壊れ／
# 埋め込み次元不一致／権限エラー、いずれもここを通る。ケースの区別はメッセージ文言
# のみで行い、bash側の分岐そのものは増やさない＝「1箇所に集約」）。全ケースで想起
# 処理は継続しキーワード結果は維持する（exitしない）。残る1ケース（削除済みノート
# 残存）は真の失敗ではなく正常完走時の事実記録のため、ここではなくlog_fact()を直接
# 使う（下のVEC_JSON取り込み処理内・2026-07-14修正でログ形式(レベル列)を分離した際に
# 改めて明記）。
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

# ハートビート行（8.3ラウンド新設・round2からの宿題）。vault-recall.tsvは従来
# ヒット時のみ記録していたため、「キーワード・ベクトルとも走らせた上でヒット0件
# だった健全な日」と「フックそのものが死んでいる（一度も実行されていない）」が
# ログ単独で区別できなかった（[[Decisions/2026-07-10-vault-recall-and-metrics]]
# round2既知の限界）。想起パイプラインを最後まで走らせた結果ヒット0件だった
# 呼び出しでは、この関数で1行だけ生存記録を残す。
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
# 同じ理由で、この呼び出し中にkeyword/vector helperのfail-open（log_error()経由）が
# 1回でも発生していた場合も書かない＝PIPELINE_HAD_ERRORで判定する（8.3ラウンド・
# Codex一次レビュー指摘・Major対応: 「両helperとも失敗して結果的に0件」「自己打ち切り
# によりベクトルを諦めた結果キーワードも0件」のようなケースでハートビートを書くと、
# 実際には失敗し続けているのに有効な記録が続くERROR経路と誤認しやすい）。
#
# フォーマット: 通常のヒット行と同じ3列構成（ts\tsession_id\t固定マーカー）で書く。
# vault_inventory.py の read_log() と check-drift.sh の log_last_valid_line_age_days()
# はいずれも「3列目(本来はノート相対パス)が空でない行」を『有効な記録』として鮮度・
# 死活判定に使う契約（両ファイルの該当コメント参照・2026-07-13時点で確認済み）。
# ERROR行の形式(3列目を空にする)で書くと、この「有効な記録」扱いを受けられず、
# ヒット0件が続くと従来どおり「フックは動いているが失敗し続けている」という誤った
# ERRORING/recall_log_broken判定を招いてしまう＝ハートビートの目的（生存を示す）を
# 果たせない。3列目に実在ノートと衝突しない固定マーカー(HEARTBEAT_MARKER・実在パス
# には現れない括弧付き文字列)を置くことで、既存パーサを「有効な記録」として正しく
# 通す。副作用として vault_inventory.py §12 の「提示回数上位」「提示無視率ワースト」
# の集計に、実ノートではないこのマーカーが1エントリ（人間が見て一目で実ノートでは
# ないと分かる表記）として混ざる。実害の小さいトレードオフとして許容し、除外
# フィルタが要れば §12 側の追随課題として別途申告する（本ファイルの担当範囲外）。
#
# ログ肥大対策: 直前1行が既に同一session_idのハートビートであれば書き込みを省略
# する（tail -1のみを見る軽量な抑制＝厳密な重複排除ではないが、同一セッション内で
# ヒット0件の呼び出しが連続するケースの大半を低コストで間引ける）。
#
# ただし無条件の抑制だと、1回のセッションがVAULT_AGENT_LOG_STALE_DAYS（check-drift.sh
# 既定7日）を超えて連続稼働し、その間ずっとヒット0件が続いた場合、ログの最終行が
# セッション開始直後の1回で凍結されたまま更新されなくなる（2026-07-14修正・外部脳の
# 想起・ベンチ機構の総点検・理論的成立を裏取り済み・2026-07-14時点で実害の報告は
# 無い）。この状態でSTALE閾値を超えると、フックは実際には動き続けているのに
# check-drift.shが「フック停止の疑い(STALE)」という偽の警告を出してしまう。
# HEARTBEAT_REFRESH_AFTER_S（既定1日）ごとに同一セッションでもハートビートを書き直す
# ことで、最終行の経過日数がSTALE閾値を構造的に超え続けないようにする（既定値なら
# 7日のうちに最低6回は更新される計算で、閾値7日に対して十分な安全マージンがある）。
HEARTBEAT_MARKER='(heartbeat)'
HEARTBEAT_REFRESH_AFTER_S="${VAULT_RECALL_HEARTBEAT_REFRESH_AFTER_S:-86400}"
# 7桁以上（100万秒=約11.6日以上）も既定値へフォールバックする（Codex一次レビュー
# 指摘・Minor対応: HOOK_BUDGET_MS等と同じ桁数上限ガード。誤記訂正: 当初コメントで
# 「1000万秒(8桁の最小値)」と書いていたが、`???????*`(7文字以上)が実際に弾くのは
# 7桁の最小値=100万秒からなので訂正した。想起フックの再書込み間隔として現実的な値は
# 最大でも数十日のオーダーであり、6桁≒999999秒(約11.6日)あれば十分な余裕がある。
# 上限が無いと極端な数字列がbashの`[ -lt ]`整数比較でエラーになりうる＝結果的には
# fail-open側へ倒れるが、意図しないstderrノイズを避ける）。
case "$HEARTBEAT_REFRESH_AFTER_S" in
  ''|*[!0-9]*|???????*) HEARTBEAT_REFRESH_AFTER_S=86400 ;;
esac

# 直前のハートビート行のタイムスタンプ($1・ISO8601 "YYYY-MM-DDTHH:MM:SSZ"）を解析し、
# 現在時刻からの経過秒数が0以上HEARTBEAT_REFRESH_AFTER_S未満なら「まだ新しい」
# (戻り値0=true)を返す。macOSのBSD `date -j`でパースする（check-drift.shの
# log_last_valid_line_age_days()と同じ実装方針・本リポジトリはmacOS専用の3年
# ノーメンテ運用が前提）。解析に失敗した場合はfail-open寄りに「新しくない」(戻り値1)
# を返し、抑制せずハートビートを書く方向へ倒す（無条件抑制に戻って最終行が凍結され
# 続ける事故より、多少ログが増える方が安全＝他の`now_ms()`等と同じfail-open方針）。
# 経過秒数が負（直前行のタイムスタンプが未来＝システム時計のズレ・ログ破損等）の
# 場合も同様に「新しくない」扱いにする（Codex一次レビュー指摘・Major対応: 素朴に
# `-lt`だけで判定すると負の経過秒数は常に閾値未満＝「新しい」と誤判定され、壊れた
# 未来日時のハートビートが永久に抑制され続けてしまい、本機能の目的そのものが
# 無効化される）。
#
# date -jへ渡す前に、固定桁のcaseパターンで厳密に"YYYY-MM-DDTHH:MM:SSZ"形式のみを
# 受理する（Codex一次レビュー指摘・Major対応・2巡目: BSD `date -j -f`はパース成功
# 可否だけでは検証にならないほど寛容で、桁不足("2026-7-5T1:2:3"）・末尾の余剰文字
# ("...56junk"）・末尾"Z"欠落もエラーにせず解釈してしまう（実機確認済み）。本来この
# 関数が読むのはlog_row()が`date -u +%Y-%m-%dT%H:%M:%SZ`で書いた行のタイムスタンプ
# のみのはずなので、その形式ちょうどでなければ「解析できなかった」として扱う。
# なお2月30日のような暦として存在しない日付はBSD dateが自動正規化(3月へ繰り上げ)
# してしまいこの桁チェックだけでは弾けないが、この関数の入力は常にこのフック自身が
# 書いた行に限られ（外部からの改ざんは脅威モデル外）、万一混入しても最悪ハートビート
# 書き込みタイミングの精度が多少ずれるだけでexit 0契約やクラッシュには影響しない
# ため、round-trip再検証までは行わない（既知の限界として明記）。
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

# vector_recall_helper.pyへ渡す埋め込みモデル名（2026-07-14修正・外部脳の想起・ベンチ
# 機構の総点検）。vector_recall_helper.pyは同日追加された--model引数（既定
# ei.DEFAULT_MODEL＝環境変数VAULT_EMBED_MODEL、未設定時"qwen3-embedding:0.6b"・
# scripts/vault-agents/embedding_index.py:60のSSOT）でインデックスのmodel_digestを
# 検証する。従来はhook側から--modelを渡さず、helperプロセス自身が自分の環境変数から
# 既定値を解決する暗黙の一致に依存していた。ここでhook側でも同じフォールバック順で
# 明示的に解決し、`--model`として引数で渡すことで、その暗黙依存を解消する
# （VAULT_EMBED_MODEL未設定時の既定値文字列はei.DEFAULT_MODELのフォールバック値の
# 直接複製＝tests/test-vault-recall-vector.shのSSOT検証テストで一致を担保。値そのものは
# 変えないため、VAULT_EMBED_MODEL未設定＝現行運用での挙動は変わらないはず）。
VECTOR_MODEL="${VAULT_EMBED_MODEL:-qwen3-embedding:0.6b}"

# キーワード想起にも同じ二重予算パターンを適用する（8.2ラウンド新設）。キーワード
# 照合はローカルI/Oのみで通常は数十ms程度に収まるが、Vaultが極端に肥大化した場合等の
# 保険として、ベクトル側と全く同じ検証・kill方式を用意する（既定値もVECTOR側と
# 揃えて1000ms/150msにした＝「新しい閾値ノブは作らない」方針の範囲内で、既存パターンの
# 素直な複製として扱う）。
KEYWORD_BUDGET_MS="${VAULT_RECALL_KEYWORD_BUDGET_MS:-1000}"
KEYWORD_KILL_GRACE_MS="${VAULT_RECALL_KEYWORD_KILL_GRACE_MS:-150}"

# 自己打ち切り（段階縮退・8.3ラウンド新設）。UserPromptSubmitフックのtimeoutは
# settings.json側で2秒（$HOME/.claude/settings.jsonの該当hookエントリ・timeout: 2）。
# ハイブリッド化（8.1/8.2ラウンド）でこの予算を消費するようになり、実測では
# warm≈780ms/cold≈1365ms（[[Decisions/2026-07-10-vault-recall-and-metrics]] round3
# 所見）とまだ余裕はあるが、Vault肥大化・システム負荷・Ollamaのモデル再ロード遅延が
# 重なると2秒を超え、フック全体がClaude Code側から強制timeoutされる「サイレント
# タイムアウト」（キーワード枠も含め全滅＝KW_OUT_FILEに既に書き出し済みの結果すら
# 提示できない）に陥りかねない（2026-07-13敵対的レビューround3「スケール耐性」
# 「3年ノーメンテ自走性」軸の指摘）。ベクトル想起は柱①（無くても柱②単独で想起は
# 機能する・既存fail-open方針）である一方、キーワード想起は柱②かつ唯一の必須機能
# なので、フック予算の残りが乏しくなったらベクトル枠だけを自ら打ち切り、キーワード
# 枠のみで返す。キーワード枠は打ち切り対象にしない。
#
# HOOK_BUDGET_MSは実運用のsettings.json値と一致させる既定値2000msだが、settings.json
# 側を変更した場合にここも追随する必要がある点は運用上の既知の制約（settings.jsonから
# 動的に読み取る手段が無いため。値がズレても安全側＝打ち切りが早まる/遅れるだけで
# fail-openの外側には出ない）。
HOOK_BUDGET_MS="${VAULT_RECALL_HOOK_BUDGET_MS:-2000}"
# ポーリングループ終了後の後処理（JSON組み立て・ログ書き込み等）に確保する余裕。
# VECTOR_KILL_GRACE_MS等、既存の猶予値と同オーダーの値を採用しつつ、後処理は
# jq呼び出し複数回＋ファイルI/Oを伴うため既存猶予(150ms)よりやや多めに確保した。
DEGRADE_TAIL_RESERVE_MS="${VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS:-400}"

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
# HOOK_BUDGET_MS/DEGRADE_TAIL_RESERVE_MSは非数値・空文字に加え、7桁以上（100万ms=
# 約16.7分以上）も既定値へフォールバックする（8.3ラウンド・Codex一次レビュー指摘・
# Major対応: 上の非負整数チェックだけでは桁数に上限が無く、極端に長い数字列を
# 算術展開$(( ))に渡すとbash 3.2の符号付き整数演算が静かにオーバーフロー/折り返し
# して負数化し、DEGRADE_AFTER_MSの下限ガードを意図せずすり抜けうる。想起フックの
# 予算として現実的な値は最大でも数秒〜数十秒のオーダーであり、6桁≒999999ms あれば
# 十分な余裕がある）。
case "$HOOK_BUDGET_MS" in
  ''|*[!0-9]*|???????*) HOOK_BUDGET_MS=2000 ;;
esac
case "$DEGRADE_TAIL_RESERVE_MS" in
  ''|*[!0-9]*|???????*) DEGRADE_TAIL_RESERVE_MS=400 ;;
esac
# フック起動からの経過時間がこの値(ms)以上になったら、ベクトルのkill-after
# (VEC_KILL_AFTER_MS)到達を待たずに自己打ち切りする（段階縮退の閾値）。上の桁数
# 上限チェックにより両オペランドとも最大6桁(≦999999)なので、この減算がbashの
# 64bit符号付き整数演算でオーバーフローすることはない。
DEGRADE_AFTER_MS=$((10#$HOOK_BUDGET_MS - 10#$DEGRADE_TAIL_RESERVE_MS))
[ "$DEGRADE_AFTER_MS" -lt 0 ] && DEGRADE_AFTER_MS=0
# 想起候補の表示上限（FR2）。従来はキーワード枠側がループ内のリテラル`5`のまま
# ハードコードされており、recall_bench.pyのMAX_KEYWORD_CANDIDATES（SSOT検証テスト・
# tests/test-recall-bench.sh）はこのリテラルをgrepで抽出する脆いSSOTだった
# （2026-07-14修正・外部脳の想起・ベンチ機構の総点検）。名前付き定数へ切り出し、
# 値そのものは変えない（5/3のまま）。
MAX_KEYWORD_CANDIDATES=5   # キーワード枠（先頭スコア順）の表示上限（FR2）
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
# 以降のログ書き込みは全てこのサニタイズ済み値を使う（Codex一次レビュー指摘・Minor
# 対応: log_error()/log_fact()だけでなく、ハートビート・提示ログの全ての書き込み
# 経路で同じ値を使う。session_idは実運用では常にUUID相当だが、理論上JSON経由で
# タブ・改行を含む値が来ても、書き込み時だけサニタイズして直前行との比較(tail -1一致
# 判定)には生の値を使う…という実装だと、両者がズレて意図しない二重書き込み等の
# 不整合を招く。1箇所で確定させ全経路で使い回すことでそのズレを避ける）。
SAFE_SESSION_ID="$(sanitize_log_field "${SESSION_ID:-}")"
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
VEC_SELF_TRUNCATED=0

# 自己打ち切り（段階縮退）その1: ベクトルを起動する前の時点で、既にフック起動から
# DEGRADE_AFTER_MS ms以上経過している（通常は数十msのはずが、ディスクI/O遅延等の
# 悪条件でここまでに時間を使い切っている）場合は、起動コストすら惜しんでベクトルの
# 起動自体を見送る。HOOK_START_MSが採取できていない環境（now_ms()参照）ではこの
# 判定自体を無効化し（fail-open）、従来どおり起動を試みる。
VEC_SHOULD_DEGRADE=0
PRE_VEC_ELAPSED_MS=""
if [ -n "$HOOK_START_MS" ]; then
  PRE_VEC_NOW_MS="$(now_ms)"
  if [ -n "$PRE_VEC_NOW_MS" ]; then
    PRE_VEC_ELAPSED_MS=$((PRE_VEC_NOW_MS - HOOK_START_MS))
    [ "$PRE_VEC_ELAPSED_MS" -ge "$DEGRADE_AFTER_MS" ] && VEC_SHOULD_DEGRADE=1
  fi
fi

if [ "$VECTOR_DISABLED" != "1" ] && [ -n "$REPO_ROOT" ] && [ "$VEC_SHOULD_DEGRADE" -ne 1 ]; then
  VEC_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-vec-out.XXXXXX" 2>/dev/null)"
  VEC_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/vault-recall-vec-err.XXXXXX" 2>/dev/null)"
  if [ -n "$VEC_OUT_FILE" ] && [ -n "$VEC_ERR_FILE" ]; then
    VEC_KILL_AFTER_MS=$((10#$VECTOR_BUDGET_MS + 10#$VECTOR_KILL_GRACE_MS))
    "$PYTHON_BIN" "$VECTOR_HELPER" --vault "$VAULT" \
      --budget-ms "$VECTOR_BUDGET_MS" --model "$VECTOR_MODEL" \
      > "$VEC_OUT_FILE" 2>"$VEC_ERR_FILE" <<< "$RAW_PROMPT" &
    VEC_PID=$!
  else
    log_vector_fail_open "一時ファイルの作成に失敗しました"
  fi
elif [ "$VECTOR_DISABLED" != "1" ] && [ -n "$REPO_ROOT" ] && [ "$VEC_SHOULD_DEGRADE" -eq 1 ]; then
  log_vector_fail_open "自己打ち切り（段階縮退）: フック予算(${HOOK_BUDGET_MS}ms)の残りが乏しいため（起動前の経過約${PRE_VEC_ELAPSED_MS}ms・打ち切り閾値${DEGRADE_AFTER_MS}ms）、ベクトル想起の起動自体をスキップしキーワード枠のみで返します"
fi

# 両プロセスの生死を1つのループで同期ポーリングする（監視用の別プロセスを増やさない
# という設計を2プロセス分でも維持するため、KW/VECそれぞれの完了フラグを見ながら
# 1本のループで両方を扱う。片方が先に終わっていればkill -0が即座に失敗しdoneになる
# ため、早期終了のレイテンシは単体時と同じく最大25ms）。
POLL_INTERVAL_MS=25
ELAPSED_MS=0
KW_DONE=1; [ -n "$KW_PID" ] && KW_DONE=0
VEC_DONE=1; [ -n "$VEC_PID" ] && VEC_DONE=0
# 自己打ち切り（段階縮退）その2: ベクトルは起動できたが応答が長引くケース（Ollamaの
# コールド再ロード等）向け。ベクトル自身のkill-after（VEC_KILL_AFTER_MS、既定
# 1150ms）到達を待たず、フック起動(HOOK_START_MS)からの実経過時間がフック全体の
# 予算(DEGRADE_AFTER_MS)を超えた時点でここで先に打ち切る（フック全体のサイレント
# タイムアウトを防ぐ）。キーワード枠は対象外（唯一の必須機能なので自身のkill-after
# までは待つ＝リーダー承認済み設計）。
#
# 経過時間はELAPSED_MS（ループの周回数×25msの名目値）ではなく、毎周now_ms()を
# 呼び直してHOOK_START_MSとの実差分で測る（8.3ラウンド・Codex一次レビュー指摘・
# Major対応: ELAPSED_MSは`sleep 0.025`が実際にどれだけかかったかを反映しない名目値
# のため、まさに自己打ち切りが必要なシステム高負荷時ほど「経過25ms」が実際には
# 数百ms〜になり得て、フック全体2秒timeoutを防げない）。now_ms()がその周だけ失敗
# しても（一時的なdateコマンド起動失敗等）次の周で再試行するだけで、この判定機能
# 全体を永続的に無効化はしない＝fail-open。
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
  if [ "$VEC_DONE" -eq 0 ] && [ -n "$HOOK_START_MS" ]; then
    LOOP_NOW_MS="$(now_ms)"
    if [ -n "$LOOP_NOW_MS" ] && [ $((LOOP_NOW_MS - HOOK_START_MS)) -ge "$DEGRADE_AFTER_MS" ]; then
      kill -9 "$VEC_PID" 2>/dev/null
      VEC_DONE=1
      VEC_SELF_TRUNCATED=1
    fi
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
# bash側は先頭MAX_KEYWORD_CANDIDATES件を切り出すだけでよい（旧実装のO(n²)選択ロジックは
# 不要になった）。
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
  # これも失敗ではなく正常系（ファイル名キーのみへフォールバックしただけでパイプ
  # ラインは完走している）なのでlog_fact()で事実だけ記録する（2026-07-14修正・
  # 上のlog_fact()コメント参照）。
  log_fact "${UNREADABLE_NOTE_COUNT}件のノートを読み取れませんでした（権限不足の可能性・ファイル名キーのみで照合しました）"
fi

N=${#KW_RELPATHS[@]}
# 「候補0件なら即exit」はここではしない（設計書§2.1手順2-3・FR2）。ベクトル候補との
# マージ後（下のFINAL_EMPTYチェック）にまとめて判定する＝キーワード0件のプロンプトでも
# ベクトル想起は常に試みる。

SELECTED_IDX=()
for ((i = 0; i < N && i < MAX_KEYWORD_CANDIDATES; i++)); do
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
        # 削除済みノートの除外件数（付録A FR3ケース6）も1箇所のログへ集約する
        # （Codexレビュー指摘・Major: この事象だけが唯一無言で正常終了扱いになって
        # いたため、要件の「全ケースでexit0・ログに残す」の6ケース目もログに残る
        # ようにする。ただしこのケースは他5ケースと違い真の失敗(fail-open)ではなく
        # 正常完走時の事実記録なので、2026-07-14修正でlog_fact()経由（6列目に
        # LOG_LEVEL_INFO）へ切り出した＝下のcase文参照）。
        EXCLUDED_MISSING="$(printf '%s' "$VEC_JSON" | jq -r '.excluded_missing // 0' 2>/dev/null)"
        case "$EXCLUDED_MISSING" in
          ''|*[!0-9]*) : ;;  # 数値以外(壊れた応答等)はログしない・素通り
          0) : ;;
          # これは失敗ではなく正常系（インデックスの最大1時間ラグを検索側が吸収した
          # だけ）なので log_vector_fail_open は使わず、log_fact()で事実だけ記録する
          # （"fail-openでskipしました"という誤解を招く文言を避け、6列目のレベル列
          # (LOG_LEVEL_INFO)でも機械的に「真の失敗ではない」と判別できるようにする・
          # 2026-07-14修正・上のlog_fact()コメント参照）。
          *) log_fact "削除済みノートのベクトル残存を${EXCLUDED_MISSING}件除外しました（インデックスの最大1時間ラグ・付録A FR3ケース6・候補提示自体は正常）" ;;
        esac
      else
        log_vector_fail_open "helper出力のJSON解析に失敗しました: $(printf '%s' "$VEC_JSON" | head -c 200)"
      fi
    fi
  elif [ "$VEC_RC" -eq 137 ]; then
    # kill -9 が発火した理由が「ベクトル自身の予算超過」（従来からの二重予算kill）か
    # 「自己打ち切り（段階縮退・フック全体の予算が乏しいため待たずに打ち切った）」かで
    # メッセージを分ける（VEC_SELF_TRUNCATEDはポーリングループ側で設定）。どちらも
    # log_vector_fail_open経由＝既存のERROR行フォーマットをそのまま使う。
    if [ "$VEC_SELF_TRUNCATED" -eq 1 ]; then
      log_vector_fail_open "自己打ち切り（段階縮退）: フック予算(${HOOK_BUDGET_MS}ms)の残りが乏しくなったため（打ち切り閾値${DEGRADE_AFTER_MS}ms到達）、応答を待たずに打ち切りキーワード枠のみで返します"
    else
      log_vector_fail_open "helperの応答が予算(${VECTOR_BUDGET_MS}ms+猶予${VECTOR_KILL_GRACE_MS}ms)を超えたため強制終了しました"
    fi
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
# 想起パイプラインを最後まで走らせた結果としての「健全なヒット0件」なので、
# ここでハートビートを1行残す（log_heartbeat()のコメント参照・round2からの宿題）。
if [ -z "$KEYWORD_CTX" ] && [ -z "$VECTOR_CTX" ]; then
  log_heartbeat
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
#
# relpath・一致キーもsanitize_log_field()を通す（2026-07-14修正・Codex一次レビュー
# 指摘・Minor対応: これらはVault内のファイル名・alias文字列（ユーザーが自由に
# 記述できるMarkdownノートの内容）由来のため、理論上タブ・改行を含み得る。ここを
# サニタイズしないまま残すと、log_error()/log_fact()側だけタブ注入を防いでも、
# この提示ログ経路から同種のTSV列ズレが起こり得るままになってしまう）。
for idx in "${SELECTED_IDX[@]}"; do
  keys_log="${KW_KEYLISTS[$idx]//$KEY_SEP/,}"
  keys_log="${keys_log#,}"
  log_row "${SAFE_SESSION_ID:-}	$(sanitize_log_field "${KW_RELPATHS[$idx]}")	$(sanitize_log_field "$keys_log")"
done
for ((i = 0; i < VEC_EXTRA_COUNT; i++)); do
  log_row "${SAFE_SESSION_ID:-}	$(sanitize_log_field "${VEC_EXTRA_RELPATHS[$i]}")	(ベクトル類似)"
done

printf '%s\n' "$OUT_JSON"
exit 0
