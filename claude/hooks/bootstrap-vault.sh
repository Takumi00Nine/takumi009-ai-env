#!/bin/bash
# SessionStart hook: 外部脳(Obsidian)の必読ノートを「Readで全文読め」と強制する。
#
# 旧方式は全文をadditionalContextへダンプしていたが、合計が大きいとハーネスが
# ファイルに退避し、AIには先頭プレビュー(約2KB)しか見えず「読んだ」と錯覚する事故が起きた。
# そこで本スクリプトは「全文は注入しない。各ファイルを Read ツールで開け」という
# 短い必須指示だけを出す。短い指示はサイズ上限に絶対かからない=切り詰められない。
#
# 2026-07-05: Agent Teams 対応。チームメイト/ワーカーのセッションには軽量版
# （absolute-rules のみ必読＋Vault書込禁止）を出す。判定は
#   a) stdin JSON の agent_type が付いている（--agent 起動 or サブエージェント）
#   b) 自分の session_id が「他セッションがリーダーのチーム」config.json に載っている
#      （チーム設定は ~/.claude/teams/session-{リーダーID先頭8桁}/config.json）
# 判定に失敗したらフル版へフォールバック（安全側＝遅いだけ）。
# VAULT は環境変数で上書き可（ユニットテスト用。本番は既定値のまま）。
VAULT="${BOOTSTRAP_VAULT:-$HOME/Data/obsidian}"
TEAMS_DIR="${BOOTSTRAP_TEAMS_DIR:-$HOME/.claude/teams}"

# 外部脳ヘルス行（2026-07-10 敵対的レビュー2回目 §5-2・8.0の柱②対応）。
# 「本人が定期的にレポート/ログを見に行かないと死活が分からない」問題への
# 最後の砦として、SessionStart（毎回必ず走る唯一のフック）に軽い死活サマリを
# 1〜4行だけ注入する。リーダー向けフル版のみに注入する（ワーカー向け軽量版には
# 注入しない）。SessionStartは毎回走るため軽量必須：
#   - scripts/check-drift.sh の再実行はしない（フルスキャンで数百msかかりうる）
#   - ディレクトリの glob（forkなし）・ファイル1件へのgrep・ログのtail程度に留める
#   - fail-open: ここで何が起きてもブートストラップ本文は必ず出す
#     （この関数のエラーはグローバルに伝播させない。呼び出し側で出力を捨てるだけ）
: "${VAULT_READS_LOG:=$HOME/.claude/logs/vault-reads.tsv}"
: "${VAULT_RECALL_LOG:=$HOME/.claude/logs/vault-recall.tsv}"
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"  # scripts/check-drift.sh ⑥ と同じ既定値
# fragments-log（旧fragments-review・2026-07-11リネーム）・vault-inventory の
# レポート出力先（2026-07-11 決定「読まれない人間向け資料をVaultに置かない」で
# Vault配下(Explorations/...)から $HOME/.claude/logs/ 配下へ移設。
# scripts/vault-agents/fragments_log.py・vault_inventory.py のOUT_DIRと同じ既定値）。
: "${FRAGMENTS_LOG_DIR:=$HOME/.claude/logs/fragments-log}"
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"
# knowledge-merge-candidates（外部脳Knowledge自律整理・柱②・2026-07-12追加）の
# レポート出力先。scripts/vault-agents/knowledge_merge_candidates.py のDEFAULT_OUT_DIRと
# 同じ既定値（未処理レポート検知の3つ目・FR9a）。
: "${KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR:=$HOME/.claude/logs/knowledge-merge-candidates}"
# 未解決ALERTレポート出力先（FR12b・要件v2未決事項j「resolved確認までの全マージ
# 停止ラッチ」）。frontmatterに`resolved: YYYY-MM-DD`が無いファイルが1件でもあれば、
# 下のcompute_health_lines()内で専用のヘルス行を出す（マージ役=リーダー自身の書込
# スクリプト(knowledge_merge.py等)が生成する想定・本フックはここでは何も書き込まない
# ＝読み取りのみ）。
: "${VAULT_MERGE_ALERTS_DIR:=$HOME/.claude/logs/vault-merge-alerts}"

# ファイル先頭のfrontmatter（先頭行が `---` の場合のみ、次の `---` 行の直前まで）を
# 標準出力へ書く。先頭行が `---` でない・読み取れない等はfrontmatmter無し扱いで
# 空を返す（Codexレビュー指摘・Major: frontmatter外の本文・引用・コード例に
# 偶然 `processed: YYYY-MM-DD` という行があっても、frontmatterの外側なら
# マーカーとして誤認しないようにする＝判定をfrontmatterブロック内に限定する）。
report_frontmatter() {
  awk 'NR==1 { if ($0 != "---") exit; next } /^---[[:space:]]*$/ { exit } { print }' "$1" 2>/dev/null
}

# ディレクトリ内の最新 YYYY-MM-DD.md が「未処理」（frontmatterに
# `processed: YYYY-MM-DD` 行が無い）なら、そのファイルの日付(YYYY-MM-DD)を
# 標準出力へ書いてexit 0。処理済みならexit 1で何も出さない。レポート0件・
# frontmatter読み取り不可（権限不備等）もexit 1で何も出さない…と言いたい
# ところだが、「読み取れず処理済みかどうか判断できない」場合は"処理済み"と
# 誤認して通知を消してしまう方が危険なため、あえて「未処理」側に倒す
# （scripts/check-drift.sh ⑥と同じ設計方針＝「誤報を恐れて沈黙するより
# 軽い誤報を許容する側に倒す」）。呼び出し側は
# `if d="$(latest_unprocessed_report_date ...)"` のように使う。
# マーカー行の形式は行頭アンカー＋末尾に他の文字が続かないことを要求する
# （例えば `processed_by:` のような別キーへの誤ヒットを避けるため）。
latest_unprocessed_report_date() {
  local dir="$1" latest
  shopt -s nullglob
  local files=("$dir"/20*.md)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || return 1
  latest="${files[$((${#files[@]} - 1))]}"  # ファイル名がYYYY-MM-DDなのでglob順=時系列順
  if report_frontmatter "$latest" | grep -qE '^processed:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'; then
    return 1
  fi
  basename "$latest" .md
}

# ディレクトリ内の*.mdファイルのうち、frontmatterに`resolved: YYYY-MM-DD`行が
# 無いもの（＝未解決ALERT）の件数を返す（FR12b・未決事項j「resolved確認までの
# 全マージ停止ラッチ」の可視化用）。ALERTファイル名は棚卸し/fragments-log/
# knowledge-merge-candidatesのような日付先頭固定ではない想定（候補IDベース等）
# のため、20*.md ではなく *.md 全件を対象にする。ディレクトリが無い/空なら0を返す。
count_unresolved_alerts() {
  local dir="$1" count=0 f
  shopt -s nullglob
  local files=("$dir"/*.md)
  shopt -u nullglob
  for f in "${files[@]}"; do
    if ! report_frontmatter "$f" | grep -qE '^resolved:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

compute_health_lines() {
  local inv_dir lines="" latest count now_epoch stale_names=""

  # ① 最新棚卸しレポートの日付・検出件数（frontmatter/タイトルには件数が無いため、
  # 本文冒頭の「要確認 N 件」を1回のgrepで拾う。取れなければ日付のみ表示する）。
  # 2026-07-11 決定でVault配下(Explorations/vault-inventory)から
  # $HOME/.claude/logs/vault-inventory へ出力先が移設された（vault_inventory.py
  # のOUT_DIRと同じ既定値）。
  inv_dir="$VAULT_INVENTORY_LOG_DIR"
  if [ -d "$inv_dir" ]; then
    shopt -s nullglob
    local files=("$inv_dir"/20*.md)
    shopt -u nullglob
    if [ "${#files[@]}" -gt 0 ]; then
      latest="${files[$((${#files[@]} - 1))]}"  # ファイル名がYYYY-MM-DDなのでglob順=時系列順（bash 3.2互換のため負インデックス不使用）
      count="$(grep -m1 -oE '要確認[^0-9]*[0-9]+' "$latest" 2>/dev/null | grep -oE '[0-9]+$')"
      # 表示は日付のみではなくフルパス（本人がそのままファイルを開けるように・
      # Codexレビュー指摘の運用改善。2026-07-12追加）。
      if [ -n "$count" ]; then
        lines="${lines}- 棚卸し最新: ${latest}（要確認 ${count} 件）
"
      else
        lines="${lines}- 棚卸し最新: ${latest}
"
      fi
    fi
  fi

  # ② 未処理レポート検知（fragments-log / vault-inventory / knowledge-merge-candidates）。
  # 2026-07-11 決定（Decisions/2026-07-11-vault-maintenance-hands-off.md）で、
  # 両レポートの対処（昇格・棚卸し要確認項目の解消）は「本人が見て指示」から
  # 「リーダーがレポート生成後の最初のセッションで自律処理」に変わった。
  # テキスト規律にせず機械検知するため、各レポートフォルダの最新ファイルに
  # 処理完了マーカー（frontmatter行 `processed: YYYY-MM-DD`。リーダーが処理完了時に
  # 追記する。fragments_log.py/vault_inventory.py/knowledge_merge_candidates.py は
  # このキーを出力しないため生成物とは衝突しない）が無ければ「未処理」として日付を出す。
  # フォルダが1つも無ければ（vault-agents未導入・サブ機）行自体を出さない。
  # 出力先は同じく$HOME/.claude/logs/配下（Vault配下からの移設）。knowledge-merge-
  # candidatesは3つ目として2026-07-12追加（FR9a。候補ごとに安定ID・状態を持つため
  # 「全候補終端」までprocessedが付かない＝他の2本より未処理期間が長くなり得る
  # 想定は既知＝FR9b仕様どおり）。
  local frag_dir="$FRAGMENTS_LOG_DIR"
  local inv_dir_up="$VAULT_INVENTORY_LOG_DIR"
  local km_dir="$KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR"
  local any_report_dir=0 unprocessed="" d
  # 表示は日付のみではなくフルパス（本人がそのままファイルを開けるように・
  # Codexレビュー指摘の運用改善。2026-07-12追加）。latest_unprocessed_report_dateは
  # 引き続き日付(basename)のみを返す＝呼び出し側でdir/dateからフルパスを組み立てる。
  if [ -d "$frag_dir" ]; then
    any_report_dir=1
    if d="$(latest_unprocessed_report_date "$frag_dir" 2>/dev/null)"; then
      unprocessed="${unprocessed}fragments-log ${frag_dir}/${d}.md"
    fi
  fi
  if [ -d "$inv_dir_up" ]; then
    any_report_dir=1
    if d="$(latest_unprocessed_report_date "$inv_dir_up" 2>/dev/null)"; then
      unprocessed="${unprocessed}${unprocessed:+ / }vault-inventory ${inv_dir_up}/${d}.md"
    fi
  fi
  if [ -d "$km_dir" ]; then
    any_report_dir=1
    if d="$(latest_unprocessed_report_date "$km_dir" 2>/dev/null)"; then
      unprocessed="${unprocessed}${unprocessed:+ / }knowledge-merge-candidates ${km_dir}/${d}.md"
    fi
  fi
  if [ "$any_report_dir" = "1" ]; then
    if [ -n "$unprocessed" ]; then
      lines="${lines}- 未処理レポート: ${unprocessed}
"
    else
      lines="${lines}- 未処理レポートなし
"
    fi
  fi

  # ④ 未解決ALERT（2026-07-12追加・FR12b／要件v2未決事項j対応）。
  # ~/.claude/logs/vault-merge-alerts/ 配下にfrontmatter `resolved: YYYY-MM-DD`
  # の無いファイルが1件でもあれば、「resolved確認までの全マージ停止ラッチ」が
  # かかっていることを本人が能動的に見に行かなくても気づけるよう、専用の
  # ヘルス行を出す。fail-open: ディレクトリが無い（ALERT未発生=健全）なら
  # 行自体を出さない。
  if [ -d "$VAULT_MERGE_ALERTS_DIR" ]; then
    local unresolved_count
    unresolved_count="$(count_unresolved_alerts "$VAULT_MERGE_ALERTS_DIR" 2>/dev/null)"
    if [ -n "$unresolved_count" ] && [ "$unresolved_count" -gt 0 ] 2>/dev/null; then
      lines="${lines}- ⚠️ マージALERT未解決 ${unresolved_count}件＝マージ停止中（詳細: ${VAULT_MERGE_ALERTS_DIR}）
"
    fi
  fi

  # ③ check-drift.sh ⑥相当の簡易死活。reads/recallログそれぞれの「最終有効行」
  # （3列目=ノート相対パスが空でない行）の経過日数が閾値超なら死の疑いを出す。
  # 全行走査はしない（tail の範囲内に有効行が無ければ判定を諦めてfail-openする＝
  # 詳細判定はcheck-drift.sh（週次drift通知）の役目で、ここは毎回軽く見るだけ）。
  now_epoch="$(date -u +%s 2>/dev/null)"
  if [ -n "$now_epoch" ]; then
    local pair name f ts epoch age
    for pair in "vault-reads.tsv|$VAULT_READS_LOG" "vault-recall.tsv|$VAULT_RECALL_LOG"; do
      name="${pair%%|*}"
      f="${pair#*|}"
      [ -f "$f" ] || continue
      ts="$(tail -n 50 "$f" 2>/dev/null | awk -F'\t' 'NF>=3 && $3!="" {t=$1} END{if (t!="") print t}')"
      [ -n "$ts" ] || continue
      ts="${ts%Z}"
      epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null)" || continue
      age=$(( (now_epoch - epoch) / 86400 ))
      if [ "$age" -gt "$VAULT_AGENT_LOG_STALE_DAYS" ]; then
        stale_names="${stale_names}${stale_names:+・}${name}"
      fi
    done
  fi
  if [ -n "$stale_names" ]; then
    lines="${lines}- ⚠️ フック死の疑い: ${stale_names}（直近${VAULT_AGENT_LOG_STALE_DAYS}日以内の有効な記録なし。詳細は scripts/check-drift.sh を実行して確認）
"
  fi

  printf '%s' "$lines"
}

# --- Ollama予熱（外部脳ハイブリッド検索・柱①・FR1・8.1ラウンド追加） ---
# セッション開始に連動してOllamaを起動＋対象モデルを予熱する。フル版分岐（本人の
# メインセッション）のみで呼ぶ。ワーカー/サブエージェントの軽量版分岐には追加しない
# （設計書§1「ワーカー軽量版には追加しない＝多重予熱防止」＝サブエージェントを何個も
# 起動するたびに予熱が走るのを防ぐ）。
#
# 起動方式（実機確認・2026-07-11リーダー実施＋本ワーカー確認）: brew services /
# LaunchAgent化はしない（本人方針＝ログイン項目に入れない）。`ollama serve` を
# 直接バックグラウンド起動する。多重起動対策は「起動前に疎通確認」＋「ollama serve
# 自体、既に誰かがポートを掴んでいれば即エラー終了する」の二重（実機確認済み：
# 2重起動してもクラッシュしたり既存プロセスを壊したりはしない＝安全側）。
#
# fire-and-forget: 呼び出し全体をバックグラウンド化(&)＋disownし、本フックの応答
# （SessionStart timeout=15秒）を一切ブロックしない。失敗しても本フック本体には
# 何も影響しない・ログも増やさない（Ollama起動状況の可観測性は柱①検索側の
# fail-openログ(vault-recall.tsv)に委ねる＝「意味のあるエラーだけ拾う」既存方針）。
preheat_ollama() {
  local base_url="${VAULT_EMBED_BASE_URL:-http://127.0.0.1:11434}"
  local model="${VAULT_EMBED_MODEL:-qwen3-embedding:0.6b}"
  # scripts/vault-agents/embedding_index.py の EMBED_NUM_CTX/EMBED_NUM_BATCH と
  # 同じ既定値・同じ環境変数名（VAULT_EMBED_NUM_CTX/VAULT_EMBED_NUM_BATCH）を使う
  # ことで、bash側とpython側で値がずれないようにする（値そのものはbash/python間で
  # 共有できないため、環境変数を単一の設定点にする運用でsyncを保つ）。
  local num_ctx="${VAULT_EMBED_NUM_CTX:-4096}"
  local num_batch="${VAULT_EMBED_NUM_BATCH:-4096}"
  command -v curl >/dev/null 2>&1 || return 0

  if ! curl -s -m 1 "${base_url}/api/tags" >/dev/null 2>&1; then
    local ollama_bin
    ollama_bin="$(command -v ollama 2>/dev/null || true)"
    [ -z "$ollama_bin" ] && [ -x /opt/homebrew/bin/ollama ] && ollama_bin="/opt/homebrew/bin/ollama"
    [ -z "$ollama_bin" ] && [ -x /usr/local/bin/ollama ] && ollama_bin="/usr/local/bin/ollama"
    [ -z "$ollama_bin" ] && return 0

    # OLLAMA_NUM_PARALLEL=1: 埋め込み用途は逐次処理（想起フックは1クエリずつ・
    # インデクサも1ノートずつ）で並列スロットが不要なため、既定の並列数のまま
    # 起動しない（実機測定・2026-07-11リーダー実測: options.num_ctx=8192指定時、
    # 既定の並列スロット数(4)分のコンテキストが確保されモデルロードが6.7GBまで
    # 膨張することを確認。24GB機では圧迫が大きい。1並列に絞ることでコンテキスト
    # メモリを概ね1/4に削減できる見込み。※その後の追加実測でnum_ctx既定自体を
    # 8192→4096へ引き下げ済み(6.7GB→3.6GB)・OLLAMA_NUM_PARALLEL=1は引き続き有効）。
    # このOllamaサーバはbootstrap-vault.sh自身が起動を担う構成（brew services等の
    # 外部管理下ではない）なので、ここで環境変数を付与してもリポジトリ外の設定に
    # 影響しない。
    OLLAMA_NUM_PARALLEL=1 nohup "$ollama_bin" serve >/dev/null 2>&1 &
    disown 2>/dev/null || true

    local i=0
    while [ "$i" -lt 10 ]; do
      curl -s -m 1 "${base_url}/api/tags" >/dev/null 2>&1 && break
      sleep 0.5
      i=$((i + 1))
    done
  fi

  # 空文字の埋め込みリクエストでモデルをメモリへロードさせる（予熱）。応答は捨てる。
  # 本番の検索/インデクサ呼び出しと同じoptions(num_ctx/num_batch)で叩く（Codex
  # レビュー後リーダー実機指摘: optionsが違うとOllama側でモデル再ロードが走り、
  # 予熱の意味が無くなって最初の本番クエリが再ロード分の遅延を被り500ms予算を
  # 圧迫する）。keep_aliveは既定のまま（対話中の再ロード防止を優先）。
  curl -s -m 30 "${base_url}/api/embed" \
    -d "{\"model\":\"${model}\",\"input\":\"\",\"options\":{\"num_ctx\":${num_ctx},\"num_batch\":${num_batch}}}" \
    >/dev/null 2>&1
}

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)

is_worker=0
[ -n "$AGENT_TYPE" ] && is_worker=1
if [ "$is_worker" = "0" ] && [ -n "$SESSION_ID" ] && [ -d "$TEAMS_DIR" ]; then
  own_team="session-${SESSION_ID:0:8}"
  for cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$cfg" ] || continue
    team_dir=$(basename "$(dirname "$cfg")")
    [ "$team_dir" = "$own_team" ] && continue  # 自分がリーダーのチーム設定は除外
    if grep -q "$SESSION_ID" "$cfg" 2>/dev/null; then
      is_worker=1
      break
    fi
  done
fi

if [ "$is_worker" = "1" ]; then
  read -r -d '' DIRECTIVE <<EOF
【チームメイト用ブートストラップ｜軽量版】

あなたはエージェントチームのチームメイト（ワーカー）です。以下を守ること。

① タスクに着手する前に、まず Read ツールで $VAULT/Preferences/absolute-rules.md を全文読む（絶対厳守ルール。全員に適用）。
② Vault($VAULT) の読み取りは自由（タスクに関連するノートは Read/Grep で参照してよい）。ただし**Vault への書込は禁止**（編集者はリーダーの Claude のみ）。残すべき知見・判断・発見・失敗は、リーダーへの最終報告に「Vault記録候補:」として明記して申告する。
③ obsidian-mcp は使わない（ファイル直接 Read/Grep のみ）。
EOF
else
  FILES=(
    "Knowledge/mistakes.md"
    "Preferences/absolute-rules.md"
    "Preferences/profile.md"
    "Personal/profile-personal.md"
    "Preferences/coding-delegation.md"
    "Preferences/vault-operation.md"
  )

  # 必読ファイル一覧を絶対パス+存在確認+行数付きで生成（行数を載せておくと、
  # 後でReadした結果が全文かどうかAI自身が照合できる）。
  # サブ機（private層を持たない環境）では Personal/profile-personal.md・
  # Knowledge/mistakes.md 等が存在しないため、「見つかりません」と毎回警告するのではなく
  # **存在するファイルだけを必読リストに載せる**（2026-07-08 リーダー指示・install-sub.sh対応）。
  # メイン機（全6ファイルが揃う環境）の挙動は変わらない＝6ファイル全部が列挙される。
  list=""
  present_count=0
  missing_count=0
  for f in "${FILES[@]}"; do
    abs="$VAULT/$f"
    if [ -f "$abs" ]; then
      lines=$(wc -l < "$abs" | tr -d ' ')
      list="$list
  - $abs  （全${lines}行：Readで全文を読むこと）"
      present_count=$((present_count + 1))
    else
      missing_count=$((missing_count + 1))
    fi
  done
  if [ "$missing_count" -gt 0 ]; then
    list="$list
  （private ノートはこのマシンには無い（サブ）: ${missing_count}件は対象外）"
  fi

  # 外部脳ヘルス行（fail-open: 失敗してもブートストラップ本文は必ず出す）。
  HEALTH_LINES="$(compute_health_lines 2>/dev/null)" || HEALTH_LINES=""

  # Ollama予熱をfire-and-forgetで起動（フル版のみ）。BOOTSTRAP_DISABLE_PREHEAT=1で
  # 無効化できる（ユニットテスト用・実Ollama/実ネットワークへ依存させないため）。
  if [ "${BOOTSTRAP_DISABLE_PREHEAT:-0}" != "1" ]; then
    ( preheat_ollama ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi

  read -r -d '' DIRECTIVE <<EOF
【セッション開始ブートストラップ｜ハーネス強制注入】

重要: 必読ノートの全文はこのメッセージには注入されていない。
あなたは下記ファイルをまだ読んでいない。プレビューや要約で読んだ気にならないこと。

① タスクに着手する前に、まず Read ツールで以下を「全文」読む（${present_count}ファイルを1回の並列 Read で同時取得すること）:
$list

② 上記を読み終えるまで、ユーザー依頼の実作業（調査・検索・コード変更・委任を含む）に着手しない。
③ ユーザーの質問に関連するキーワードで Vault($VAULT) を Read/Grep/Glob で検索し、ヒットしたノートを読んでから回答する(obsidian-mcp は使わない)。
④ 新たな知見・判断・好み・プロジェクト変化が出たら、その場で Vault に書き込む（メインセッション＝リーダーの Claude のみ。チームメイト/ワーカー/Codex は申告→リーダーが代筆）。フロントマター必須。
⑤ オーケストレーター行動則: 実装・調査・テスト等の「作る工程」は自分でやらず、着手前にチームメイト/Agentワーカーへ委任する（Preferences/coding-delegation）。リーダー自身の Edit/Write が正当なのは、Vault・~/.claude・scratchpad・レビュー指摘の反映・軽微な修正・ユーザーの直接作業指示のみ。許可パス外への直接編集は delegation-gate-v2 フックが deny する（委任するか、理由をユーザーに明示してマーカー touch）。
${HEALTH_LINES:+
【外部脳ヘルス】（scripts/check-drift.sh ⑥の簡易版。詳細確認は本体を実行）
$HEALTH_LINES}
EOF
fi

jq -n --arg ctx "$DIRECTIVE" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
