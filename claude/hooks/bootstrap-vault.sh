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
# machine-roleマーカー（サブ機判定用。既定値・環境変数名は
# check-sub-update.sh・install-main.sh・install-sub.sh・update-sub.shと共通）。
# 用途は外部脳ヘルス行④（週次メンテ死活検知）のサブ機スキップのみ
# （2026-08-06対応。下部compute_health_lines参照）。
: "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"

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
# Preferences提案ディレクトリ（2026-07-18ハードニング・[[Decisions/
# 2026-07-18-external-brain-hardening]]で pending マーカー層を撤去）。
# scripts/vault-agents/maintenance_apply.pyのDEFAULT_PREFERENCES_PROPOSALS_DIRと
# 同じ既定値。正本＝このディレクトリ自体（マーカーJSON等の派生物は持たない）。
: "${PREFERENCES_PROPOSALS_DIR:=$HOME/.claude/logs/maintenance/preferences-proposals}"
# 死活検知: maintenance.sh(週次)のlast-run.json（Critical対処・2026-07-18
# ハードニング）。started_atは実行のたびに（busy/error早期終了でも）
# 無条件更新される契約のため、これが古いままなら「週次メンテ自体が
# 全く起動していない」ことを受動的に検知できる（maintenance.shのコメント
# 「自己ロックアウト対策」参照）。
: "${MAINTENANCE_LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
: "${MAINTENANCE_STALE_DAYS:=8}"

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

  now_epoch="$(date -u +%s 2>/dev/null)"

  # ② Preferences提案（2026-07-18ハードニング・[[Decisions/2026-07-18-
  # external-brain-hardening]]で pending マーカー層を撤去）: 提案ディレクトリ
  # 自体（`<slug>.md`＝maintenance_apply.pyのapply_promote_preferences_
  # proposal()が排他書込する下書き本文そのもの）を**正本として直接スキャン**し、
  # `*.md`ファイルの件数を「未確認N件」として毎起動で通知し続ける。承認/却下は
  # リーダーが`.md`（＋sidecarの`.meta.json`）を削除するだけでよく、通知件数が
  # 自然に追従する（派生物のマーカーJSON・破損時自己修復ロジックは持たない＝
  # 部品削減。旧実装はgit log -p参照）。
  # fail-open: ディレクトリが無い/読めない等はここで例外的に落ちずヘルス行を
  # 諦めるだけにする（呼び出し側の`compute_health_lines 2>/dev/null`と二重に
  # fail-openを守る）。
  if [ -d "$PREFERENCES_PROPOSALS_DIR" ]; then
    shopt -s nullglob
    local proposal_files=("$PREFERENCES_PROPOSALS_DIR"/*.md)
    shopt -u nullglob
    local n_proposals="${#proposal_files[@]}"
    if [ "$n_proposals" -gt 0 ]; then
      # ファイル名（拡張子除く＝slug）を決定的な表示順にするため一旦ソートする
      # （globの列挙順はファイルシステム依存で保証されないため）。
      # slug列挙は先頭5件までに抑え、6件目以降は「ほかN件」に畳む
      # （2026-07-17 tester2差し戻し対応・任意Minor: ヘルス行が際限なく
      # 長くなるのを防ぐ。方式変更後も同じ制限を踏襲する）。
      local sorted_slugs=() f base shown_slugs="" remaining=0 i=0
      while IFS= read -r base; do
        sorted_slugs+=("${base%.md}")
      done < <(printf '%s\n' "${proposal_files[@]##*/}" | sort)
      for i in "${!sorted_slugs[@]}"; do
        [ "$i" -ge 5 ] && break
        shown_slugs="${shown_slugs}${shown_slugs:+・}${sorted_slugs[$i]}"
      done
      if [ "$n_proposals" -gt 5 ]; then
        remaining=$((n_proposals - 5))
        shown_slugs="${shown_slugs}・ほか${remaining}件"
      fi
      lines="${lines}- 🆕 夜間バッチで運用ルールの昇格提案があります（未確認${n_proposals}件）: ${shown_slugs}
"
    fi
  fi

  # ④ 死活検知（Critical対処・2026-07-18ハードニング／2周目・全体構成再レビュー
  #
  # サブ機スキップ（2026-08-06追加。本人報告・実害対応）: maintenance.sh（週次
  # メンテ）とそれを起動するLaunchAgentはメイン機専用機能であり、サブ機には
  # 設計上存在しない（install-sub.shはmaintenance.sh関連のインストールを一切
  # 行わない）。そのためサブ機ではlast-run.jsonが常に不在のままとなり、
  # 以下の判定が「毎セッション必ず」④の警告を出し続けてしまっていた
  # （本来は正常な状態にもかかわらず）。判定はcheck-sub-update.shの
  # machine-roleマーカー読取・trimパターンをそのまま流用し一貫させる
  # （fail-closed＝マーカーが無い/読めない/中身が"sub"以外はすべて
  # 「メイン機」とみなし従来どおり④を実行する。積極的な証明＝厳密に
  # "sub"の場合のみスキップする）。①②等の他セクションは元々ディレクトリ
  # 不在時に静かにスキップするfail-open設計のため対象外（変更しない）。
  local machine_role_raw machine_role
  machine_role_raw="$(cat "$AIENV_MACHINE_ROLE_MARKER" 2>/dev/null)"
  machine_role="${machine_role_raw#"${machine_role_raw%%[![:space:]]*}"}"
  machine_role="${machine_role%"${machine_role##*[![:space:]]}"}"

  if [ "$machine_role" != "sub" ]; then
  # Codex+Fable5収束後の小修正＝impl4）: maintenance.sh(週次)のlast-run.json
  # started_atが${MAINTENANCE_STALE_DAYS}日以上前のままなら「週次メンテ自体が
  # 動いていない」疑いとして警告する（started_atはbusy/error早期終了でも
  # 無条件更新される契約＝maintenance.sh参照。メンテ全停止を受動的に検知する
  # 最後の砦）。2周目で以下2点を追加（「複雑化させない」原則で既存判定への
  # 足しに留める）:
  #   (a) last_success_atのN日停滞検知＝started_atは新しくてもlast_success_at
  #       が${MAINTENANCE_STALE_DAYS}日以上古ければ「起動はするが成功していない」
  #       ＝「毎週起動して毎週失敗」の不可視を塞ぐ（Phase1①のfail-fastや
  #       Phase2の失敗が続いていても、started_atだけ見ていると気付けない）。
  #   (b) last-run.json不在・JSON破損・両フィールドとも未記録、または
  #       実在するいずれかのフィールドの値が解析不能／未来日時（空文字列・
  #       null・不正な文字列を含む＝2周目再レビューでhas()による区別へ
  #       修正済み）のときは `[ -f ]`等で静かにスキップせず「状態記録が
  #       無い/壊れています」と警告する＝初回未稼働・状態ファイル消失/破損・
  #       片方だけの破損の不可視を塞ぐ。
  # fail-open: jqが無い/JSON破損/フィールド欠落/時刻パース不能のいずれでも
  # クラッシュはしない（このcompute_health_lines関数自体が呼び出し側で
  # 2>/dev/nullされる二重の安全網もそのまま維持）。
  #
  # tester4差し戻し・Major対応（2周目・全体構成再レビュー独立検証で発見された
  # A②の穴）: 従来は(b)の判定が「started_epoch・success_epochの両方が空の
  # ときだけ」発火しており、片方だけ値が壊れている（不正な文字列・未来日時）
  # ケースを静かに見逃していた。最も痛いのは「last_success_atだけ破損・
  # started_atは正常」＝(a)が狙う「起動するが成功しない」検知そのものが
  # 破損データによって無効化される。修正: 各フィールドについて「値は有るのに
  # 信用できない（解析不能または未来日時）」状態を`*_broken`として個別に
  # 判定し、いずれか一方でもbrokenなら(b)の警告を出す（「値が無い」＝キー
  # 自体が未設定という正常な過渡状態＝初回未成功等とは区別する。7l系テストが
  # 保証する「last_success_at未設定でも警告なし」は壊さない）。
  #
  # 再レビュー指摘Major対応: 「キーが無い(has()==false)」と「キーはあるが
  # 値が偽値（空文字列/null）」を`.field // empty`だけでは区別できない
  # （どちらも`jq -r`の出力としては空文字列になる。`jq -r '"" // empty'`も
  # 出力上は空文字列と見分けが付かない）。maintenance.sh自身は常に有効な
  # ISO8601文字列しか書かない契約のため、後者（キーは実在するが値が空/null）
  # は書込側の異常（破損）を示す信号であり、「まだ一度も成功していない」という
  # 正常な過渡状態（＝キー自体が無い）と混同してはいけない。`has()`で
  # キーの実在を独立に確認し、実在するのに解析できない/未来日時の場合のみ
  # brokenとする（キーが存在しないなら`*_broken`は立てない＝7l系テストの
  # 正常無警告契約を保つ）。
  if [ -n "$now_epoch" ]; then
    local started_at last_success_at started_epoch success_epoch started_age success_age
    local started_broken=0 success_broken=0 has_started="" has_success=""
    started_at=""
    last_success_at=""
    if [ -f "$MAINTENANCE_LAST_RUN_FILE" ]; then
      started_at="$(jq -r '.started_at // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      last_success_at="$(jq -r '.last_success_at // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      has_started="$(jq -r 'has("started_at")' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      has_success="$(jq -r 'has("last_success_at")' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    fi

    started_epoch=""
    if [ "$has_started" = "true" ]; then
      [ -n "$started_at" ] && started_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%Z}" +%s 2>/dev/null)"
      # キーは実在するのに解析できない（空文字列/null/不正な文字列）、
      # または未来日時（時計ズレ/破損の疑い）なら壊れているとみなす。
      # 以降のstale判定には使わせない。
      if [ -z "$started_epoch" ] || [ "$started_epoch" -gt "$now_epoch" ]; then
        started_broken=1
        started_epoch=""
      fi
    fi
    success_epoch=""
    if [ "$has_success" = "true" ]; then
      [ -n "$last_success_at" ] && success_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${last_success_at%Z}" +%s 2>/dev/null)"
      if [ -z "$success_epoch" ] || [ "$success_epoch" -gt "$now_epoch" ]; then
        success_broken=1
        success_epoch=""
      fi
    fi

    if { [ -z "$started_at" ] && [ -z "$last_success_at" ]; } \
       || [ "$started_broken" -eq 1 ] || [ "$success_broken" -eq 1 ]; then
      # (b) ファイル不在／JSON破損／両フィールドとも記録が無い、または
      # いずれかのフィールドに値は有るが解析不能/未来日時＝状態記録が
      # 部分的にでも信用できない。
      lines="${lines}- ⚠️ 週次メンテの状態記録が無い/壊れています（要確認。last-run.json: $MAINTENANCE_LAST_RUN_FILE）
"
    else
      [ -n "$started_epoch" ] && started_age=$(( (now_epoch - started_epoch) / 86400 ))
      [ -n "$success_epoch" ] && success_age=$(( (now_epoch - success_epoch) / 86400 ))
      if [ -n "$started_epoch" ] && [ "$started_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        lines="${lines}- ⚠️ 週次メンテが${started_age}日動いていません（要確認。last-run.json: $MAINTENANCE_LAST_RUN_FILE）
"
      elif [ -z "$started_epoch" ] && [ -n "$success_epoch" ] && [ "$success_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        # started_atが未設定（キー自体が無い）の場合のみ、従来どおり
        # last_success_atへフォールバックする（started_atの値が壊れている
        # ケースは上のstarted_broken判定で既に(b)枝へ拾われている）。
        lines="${lines}- ⚠️ 週次メンテが${success_age}日動いていません（要確認。last-run.json: $MAINTENANCE_LAST_RUN_FILE）
"
      elif [ -n "$started_epoch" ] && [ -n "$success_epoch" ] && [ "$success_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        # (a) started_atは新しい(=起動はしている)がlast_success_atだけが
        # 古い＝起動するが成功し続けていない疑い。
        lines="${lines}- ⚠️ 週次メンテが起動はするが${success_age}日成功していません（要確認。last-run.json: $MAINTENANCE_LAST_RUN_FILE）
"
      fi
    fi
  fi
  fi  # machine_role != sub（サブ機では④の全判定を無警告でスキップ）

  # ③ check-drift.sh ⑥相当の簡易死活。reads/recallログそれぞれの「最終有効行」
  # （3列目=ノート相対パスが空でない行）の経過日数が閾値超なら死の疑いを出す。
  # 全行走査はしない（tail の範囲内に有効行が無ければ判定を諦めてfail-openする＝
  # 詳細判定はcheck-drift.sh（週次drift通知）の役目で、ここは毎回軽く見るだけ）。
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
