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
EOF
fi

jq -n --arg ctx "$DIRECTIVE" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
