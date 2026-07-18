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
# scripts/vault-agents/vault_inventory.py のOUT_DIRと同じ既定値）。
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"

# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で
# 「レポート生成→リーダーがセッション内で処理」という間接ループを廃止し、
# 定常メンテは夜間バッチ(maintenance.sh)がVaultへ直接書き込む方式へ移行した。
# 旧・未処理レポート検知（fragments-log/vault-inventory/knowledge-merge-candidates
# のprocessedマーカー監視）・未解決ALERT監視（knowledge_merge.py由来。同スクリプトは
# 撤去済み）はこの間接ループの一部だったため、対応するreport_frontmatter()・
# latest_unprocessed_report_date()・count_unresolved_alerts()ごと削除した。
# 代替の新鮮度チェック（maintenance.shのlast-run.json・started_atの経過日数のみで
# 判定）はmaintenance.sh新設（PR2）と同時に導入する。旧実装を読みたい場合は
# `git log -p claude/hooks/bootstrap-vault.sh` を参照。

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

  # ② 未処理レポート検知・④ 未解決ALERT監視は撤去（2026-07-16簡素化・
  # [[Decisions/2026-07-16-nightly-batch-direct-write]]）。ファイル冒頭コメント参照。

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
