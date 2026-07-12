#!/usr/bin/env bash
# scripts/vault-agents/vault_inventory.py の §9-12 追加検出項目のユニットテスト
# （aliases 欠落・汎用/短すぎる alias・review_by 期限・未読ノート検出）。
#
# 実 Vault($HOME/Data/obsidian)・実ログ($HOME/.claude/logs/vault-{reads,recall}.tsv)
# には一切依存しない。HOME を一時ディレクトリへ差し替えて fixture Vault を作り、
# VAULT_READS_LOG/VAULT_RECALL_LOG 環境変数でログパスも差し替えて実行する。
# 日付はすべて実行時刻からの相対計算（ハードコード日付を使わない）。
# §1-8（既存機能）はレポート生成が例外なく完走することで簡易リグレッション確認する。
#
# 実行方法: bash tests/test-vault-inventory.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/vault_inventory.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

# N日前/後のYYYY-MM-DD（BSD date。0や正数にも+符号を明示しないと date が拒否する）
d_date() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%F; }
# N日前/後のISO8601時刻（BSD date）。時刻はローカル正午に固定し、tz変換や実行時刻の
# 揺れで日付境界をまたいで丸め誤差が出ないようにする。
d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%Y-%m-%dT12:00:00; }

# 必読5ファイル＋4フォルダのREADME.mdを作る（無いとスクリプトがFileNotFoundErrorで落ちる）
make_base_vault() {
  local vault="$1"
  # Personal/はvault_inventory.pyのBOOTSTRAP_FILES（§5注入サイズ監視）に元々
  # 含まれていた（bootstrap-vault.shの必読6ファイルと同期）が、このfixtureヘルパー
  # には反映されておらず§5がFileNotFoundErrorで落ちる既存の隙間があった。
  # 2026-07-11決定（[[Decisions/2026-07-11-personal-recall-scope]]）でPersonal/が
  # 想起対象フォルダにも加わったタイミングで合わせて解消する（私の担当外の既存問題
  # だが、Personal関連テストを追加するために本ヘルパーの修正が前提となるため対応）。
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Decisions" "$vault/Projects" \
           "$vault/Personal" "$vault/Fragments"
  for f in "Knowledge/mistakes.md" "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Preferences/coding-delegation.md" "Preferences/vault-operation.md" \
           "Personal/profile-personal.md"; do
    printf -- '---\ndate: 2026-01-01\n---\n\ndummy\n' > "$vault/$f"
  done
  for d in Knowledge Preferences Decisions Projects Personal; do
    printf -- '---\ndate: 2026-01-01\ntags: [meta, index]\n---\n\n# %s\n' "$d" > "$vault/$d/README.md"
  done
}

# write_note <vault> <相対パス> <frontmatter本文(コロン行、改行区切り)> [本文]
write_note() {
  local vault="$1" rel="$2" fm="$3" body="${4:-本文}"
  mkdir -p "$(dirname "$vault/$rel")"
  {
    echo "---"
    printf '%s\n' "$fm"
    echo "---"
    echo
    printf '%s\n' "$body"
  } > "$vault/$rel"
}

# vault_inventory.py を --force 実行し、当日レポートの中身を返す
run_inventory() {
  local vault_home="$1"
  HOME="$vault_home" python3 "$SCRIPT" --force >/dev/null
  cat "$(ls "$vault_home/.claude/logs/vault-inventory"/20*.md | sort | tail -1)"
}

echo "=== 1. aliases 欠落検出（§9）: README除外・欠落/フロー形式/複数行形式 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  write_note "$V" "Knowledge/no-alias-note.md" "date: 2026-01-01"
  write_note "$V" "Knowledge/good-alias-note.md" \
    $'date: 2026-01-01\naliases:\n  - specific-term-abc\n  - もうひとつの具体的な語'

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "aliasesが無いノートが§9に載る" "$out" "Knowledge/no-alias-note.md"
  assert_not_contains "aliasesがあるノートは§9に載らない" "$out" "Knowledge/good-alias-note.md\`"
  assert_not_contains "README.mdは§9の対象外（フォルダ全体では0件想定だが個別にも見る）" "$out" "Knowledge/README.md"

  rm -rf "$VAULT_HOME"
}

echo "=== 1b. aliases 欠落検出（§9）: Personal/フォルダも対象になる（2026-07-11決定・4→5フォルダ） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  write_note "$V" "Personal/devices.md" "date: 2026-01-01"
  write_note "$V" "Personal/good-alias-note.md" \
    $'date: 2026-01-01\naliases:\n  - specific-personal-term-abc'

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "Personal/内のaliases欠落ノートが§9に載る" "$out" "Personal/devices.md"
  assert_not_contains "Personal/内のaliasesありノートは§9に載らない" "$out" "Personal/good-alias-note.md\`"
  assert_not_contains "Personal/README.mdは§9の対象外" "$out" "Personal/README.md"

  rm -rf "$VAULT_HOME"
}

echo "=== 2. 汎用/短すぎる alias 検出（§10） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  # 禁止リスト該当（Claude・6文字なので短さは引っかからない）+ 十分に具体的な語
  write_note "$V" "Preferences/generic-alias-note.md" \
    "date: 2026-01-01
aliases: [Claude, 独自の長い単語]"
  # ASCII 3文字未満（短すぎ・禁止リスト非該当）
  write_note "$V" "Decisions/2026-01-01-short-ascii-alias.md" \
    $'date: 2026-01-01\naliases:\n  - x1'
  # 非ASCII 2文字未満（短すぎ・禁止リスト非該当）
  write_note "$V" "Projects/short-nonascii-alias.md" \
    $'date: 2026-01-01\naliases:\n  - 話'

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "Claude(禁止リスト)がalias `Claude`として検出される" "$out" "alias \`Claude\`（汎用語(禁止リスト)）"
  assert_not_contains "Claudeは短さでは引っかからない（誤って短すぎ扱いしない）" "$out" "alias \`Claude\`（汎用語(禁止リスト)・短すぎ）"
  assert_contains "ASCII短すぎ(x1)が検出される" "$out" "alias \`x1\`（短すぎ）"
  assert_contains "非ASCII短すぎ(話)が検出される" "$out" "alias \`話\`（短すぎ）"
  assert_not_contains "十分に具体的な語(独自の長い単語)は検出されない" "$out" "独自の長い単語\`（"

  rm -rf "$VAULT_HOME"
}

echo "=== 3. review_by 期限検出（§11）: 超過/当日境界/14日以内/範囲外 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  # aliasesも付けて§9(欠落検出)とのクロスヒットを避け、§11の判定だけを見る
  write_note "$V" "Decisions/2026-01-01-review-overdue.md" \
    "date: 2026-01-01
aliases: [review-overdue-alias]
review_by: $(d_date -10)"
  write_note "$V" "Decisions/2026-01-01-review-today.md" \
    "date: 2026-01-01
aliases: [review-today-alias]
review_by: $(d_date 0)"
  write_note "$V" "Decisions/2026-01-01-review-soon.md" \
    "date: 2026-01-01
aliases: [review-soon-alias]
review_by: $(d_date 7)"
  write_note "$V" "Decisions/2026-01-01-review-far.md" \
    "date: 2026-01-01
aliases: [review-far-alias]
review_by: $(d_date 30)"

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "10日超過のノートが超過リストに載る" "$out" "Decisions/2026-01-01-review-overdue.md\` — review_by $(d_date -10)（10日超過）"
  assert_contains "当日(delta=0)は境界としてまもなくリストに載る" "$out" "Decisions/2026-01-01-review-today.md\` — review_by $(d_date 0)（あと0日）"
  assert_contains "7日後はまもなくリストに載る" "$out" "Decisions/2026-01-01-review-soon.md\` — review_by $(d_date 7)（あと7日）"
  assert_not_contains "30日後(範囲外)はどちらのリストにも載らない" "$out" "review-far.md\`"

  rm -rf "$VAULT_HOME"
}

echo "=== 4. 未読ノート検出（§12）: ログ無し → 断定しない ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/untracked-note.md" $'date: 2026-01-01\naliases:\n  - untracked-note-alias'

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "ログ蓄積中メッセージが出る（断定しない）" "$out" "ログ蓄積中（まだ記録がありません）"
  assert_not_contains "ログが無いのに個別ノートを未読断定しない" "$out" "untracked-note.md\`（"

  rm -rf "$VAULT_HOME"
}

echo "=== 5. 未読ノート検出（§12）: ログが浅い（90日未満）→ 暫定「要観察」 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/never-seen.md" $'date: 2026-01-01\naliases:\n  - never-seen-alias'
  write_note "$V" "Knowledge/seen-recently.md" $'date: 2026-01-01\naliases:\n  - seen-recently-alias'

  LOGDIR="$V/../.claude-logs-shallow"
  mkdir -p "$LOGDIR"
  printf '%s\tsess1\tKnowledge/seen-recently.md\n' "$(d_ts -10)" > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "ログ蓄積中の注記（開始日つき・断定しない）が出る" "$out" "ログ蓄積中（開始日: $(d_date -10)"
  assert_contains "一度もログに無いノートは「要観察」として一覧に出る" "$out" "Knowledge/never-seen.md\`（ログ開始以来記録なし）"
  assert_not_contains "直近ログがあるノートは対象外（age<90）" "$out" "Knowledge/seen-recently.md\`（"

  rm -rf "$VAULT_HOME"
}

echo "=== 6. 未読ノート検出（§12）: ログが90日以上 → 確定判定・上位ノートおまけ ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/old-unread.md" $'date: 2026-01-01\naliases:\n  - old-unread-alias'
  write_note "$V" "Knowledge/recent-read.md" $'date: 2026-01-01\naliases:\n  - recent-read-alias'
  write_note "$V" "Knowledge/never-logged.md" $'date: 2026-01-01\naliases:\n  - never-logged-alias'
  write_note "$V" "Knowledge/recalled-often.md" $'date: 2026-01-01\naliases:\n  - recalled-often-alias'

  LOGDIR="$V/../.claude-logs-mature"
  mkdir -p "$LOGDIR"
  # 最古エントリ=100日前（これがlog_startとなり、90日以上のログ蓄積=確定判定に切り替わる）
  printf '%s\tsess1\tKnowledge/old-unread.md\n' "$(d_ts -100)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/recent-read.md\n' "$(d_ts -5)" >> "$LOGDIR/vault-reads.tsv"
  # recalled-often は「提示されるだけで一度もReadされない」ノート（C-2修正の主眼）。
  # 3回提示されるが reads.tsv には一度も現れないため、未読確定リストにも出て
  # 提示無視率ワーストにも「読まれた率0%」で出るはず（旧実装はrecallも
  # last_seenへ混ぜていたため未読リストから隠れてしまっていた＝バグだった）。
  # 提示無視率ワースト側は既定30日の時間窓で集計するため、窓内(-30日以内)の
  # 日付にする（2026-07-10 敵対的レビュー2回目 N-2 対応の窓導入に追従。
  # 未読確定判定は reads.tsv 側の90日成熟＝old-unread の記録だけで見るため無関係）。
  {
    printf '%s\tsess1\tKnowledge/recalled-often.md\tmatched-key\n' "$(d_ts -20)"
    printf '%s\tsess1\tKnowledge/recalled-often.md\tmatched-key\n' "$(d_ts -15)"
    printf '%s\tsess1\tKnowledge/recalled-often.md\tmatched-key\n' "$(d_ts -10)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "ログが十分溜まっていれば「ログ蓄積中」の注記は出ない" "$out" "ログ蓄積中"
  assert_contains "100日未読のノートが確定リストに出る" "$out" "Knowledge/old-unread.md\`（100日未読）"
  assert_contains "一度もログに無いノートも確定リストに出る" "$out" "Knowledge/never-logged.md\`（ログ開始以来記録なし）"
  assert_not_contains "5日前に読まれたノートは対象外" "$out" "Knowledge/recent-read.md\`（"
  assert_contains "提示されるだけで一度もReadされないrecalled-oftenが未読確定リストに出る(C-2修正)" \
    "$out" "Knowledge/recalled-often.md\`（ログ開始以来記録なし）"
  assert_contains "提示回数上位おまけにrecalled-oftenが3回で出る" "$out" "Knowledge/recalled-often.md\` — 3回"
  assert_contains "提示無視率ワーストにrecalled-oftenが読まれた率0%で出る" \
    "$out" "Knowledge/recalled-often.md\` — 提示3回中 読まれた率0%"

  rm -rf "$VAULT_HOME"
}

echo "=== 7. §12: 混在タイムゾーン（naive/aware）・破損ログ行でもクラッシュせず検出する ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/tz-aware-note.md" $'date: 2026-01-01\naliases:\n  - tz-aware-alias'
  write_note "$V" "Knowledge/tz-naive-note.md" $'date: 2026-01-01\naliases:\n  - tz-naive-alias'

  LOGDIR="$V/../.claude-logs-tzmix"
  mkdir -p "$LOGDIR"
  {
    # aware（+09:00オフセット付き）と naive（オフセット無し）が混在
    printf '%s+09:00\tsess1\tKnowledge/tz-aware-note.md\n' "$(d_ts -100)"
    printf '%s\tsess1\tKnowledge/tz-naive-note.md\n' "$(d_ts -100)"
    printf 'not-a-timestamp\tsess1\tKnowledge/tz-naive-note.md\n'   # 時刻が壊れている
    printf '2026-01-01T00:00:00\tsess1\n'                           # タブ不足（パス無し）
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall-none.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "aware/naive混在でもクラッシュせずレポートが生成される" "$out" "## 12. 未読ノート"
  assert_contains "解析できなかったログ行が2件と報告される" "$out" "解析できなかった vault-reads.tsv 行 2 件"
  assert_contains "100日前のaware時刻も正しく未読判定される" "$out" "Knowledge/tz-aware-note.md\`（100日未読）"
  assert_contains "100日前のnaive時刻も正しく未読判定される" "$out" "Knowledge/tz-naive-note.md\`（100日未読）"

  rm -rf "$VAULT_HOME"
}

echo "=== 8. review_by 形式不正の検出（§11） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/review-invalid-date.md" \
    "date: 2026-01-01
aliases: [review-invalid-date-alias]
review_by: 2026-02-30"
  write_note "$V" "Knowledge/review-not-a-date.md" \
    "date: 2026-01-01
aliases: [review-not-a-date-alias]
review_by: 来月"

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "暦上存在しない日付(2026-02-30)が形式不正として検出される" "$out" "Knowledge/review-invalid-date.md\` — review_by: \`2026-02-30\`"
  assert_contains "日付形式でない値(来月)が形式不正として検出される" "$out" "Knowledge/review-not-a-date.md\` — review_by: \`来月\`"

  rm -rf "$VAULT_HOME"
}

echo "=== 9. README.md は§12(未読ノート)の対象外 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  # README.mdはmake_base_vaultで作成済み・ログには一度も出てこない（=未読の条件を満たすはず）

  LOGDIR="$V/../.claude-logs-readme"
  mkdir -p "$LOGDIR"
  printf '%s\tsess1\tKnowledge/dummy-to-make-log-mature.md\n' "$(d_ts -100)" > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall-none.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "Knowledge/README.mdは未読リストに出ない" "$out" "Knowledge/README.md\`（"
  assert_not_contains "Preferences/README.mdは未読リストに出ない" "$out" "Preferences/README.md\`（"

  rm -rf "$VAULT_HOME"
}

echo "=== 10. alias値の行末コメントを正しく除去する（§9/§10） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/aliases-empty-with-comment.md" \
    "date: 2026-01-01
aliases: [] # 未使用"
  write_note "$V" "Knowledge/aliases-generic-with-comment.md" \
    "date: 2026-01-01
aliases: [Claude] # 汎用の例"

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "コメント付き空リストはaliases欠落として検出される（コメント込みで文字列扱いされない）" \
    "$out" "Knowledge/aliases-empty-with-comment.md\`"
  assert_contains "コメント付きでもalias値(Claude)自体は正しく汎用語判定される" \
    "$out" "alias \`Claude\`（汎用語(禁止リスト)）"

  rm -rf "$VAULT_HOME"
}

echo "=== 11a. rename/delete済みノートへの古いログが成熟判定を誤らせない（§12） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/current-note.md" $'date: 2026-01-01\naliases:\n  - current-note-alias'
  # deleted-note.md はVault上に実体が無い（rename/delete済み想定）

  LOGDIR="$V/../.claude-logs-renamed"
  mkdir -p "$LOGDIR"
  {
    printf '%s\tsess1\tKnowledge/deleted-note.md\n' "$(d_ts -200)"   # 現存しないノートへの大昔の記録
    printf '%s\tsess1\tKnowledge/current-note.md\n' "$(d_ts -10)"    # 現存ノートへの直近記録
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall-none.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "現存ノートの記録(10日分)だけで成熟度を判定する＝ログ蓄積中の注記が出る" \
    "$out" "ログ蓄積中（開始日: $(d_date -10)"
  assert_not_contains "削除済みノートのパスは検査対象ではないのでレポートに出ない" "$out" "deleted-note.md"
  assert_not_contains "現存ノートは直近10日読了済みなので未読リストに出ない" "$out" "current-note.md\`（"

  rm -rf "$VAULT_HOME"
}

echo "=== 11. ログが直近LOG_STALE_DAYS以内に無い → フック停止疑いを注記する ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/stale-log-note.md" $'date: 2026-01-01\naliases:\n  - stale-log-alias'

  LOGDIR="$V/../.claude-logs-stale"
  mkdir -p "$LOGDIR"
  # 最古100日前・最新でも40日前 → 90日分は蓄積済み(mature)だが直近40日は無記録(stale)
  {
    printf '%s\tsess1\tKnowledge/stale-log-note.md\n' "$(d_ts -100)"
    printf '%s\tsess1\tKnowledge/stale-log-note.md\n' "$(d_ts -40)"
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall-none.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "フック停止の疑い（直近記録なし）が注記される" "$out" "直近 30 日以内の有効な記録が無い"
  assert_contains "最終記録日が明示される" "$out" "最終記録: $(d_date -40)"

  rm -rf "$VAULT_HOME"
}

echo "=== 12. 既存§1-8のリグレッション: 空Vaultでも例外なく完走する ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  out="$(run_inventory "$VAULT_HOME")"
  # 見出しはBOOTSTRAP_FILES件数から動的生成される（vault_inventory.py:575）。
  # BOOTSTRAP_FILESは既にPersonal/profile-personal.mdを含む6件（bootstrap-vault.shの
  # 必読6ファイルと同期・私の担当外の既存事実）だったため、本来「必読6ファイル」が
  # 正しい期待値だった（従来のfixtureがPersonal/profile-personal.mdを用意しておらず
  # このテスト自体がFileNotFoundErrorで未達成だったため、この食い違いが露見していな
  # かった＝make_base_vault修正の副次効果として発覚・修正）。
  assert_contains "既存の必読6ファイルサイズ監視セクションは健在" "$out" "## 5. 必読6ファイルの注入サイズ"
  assert_contains "既存のFragmentsセクションは健在" "$out" "## 8. Fragments（直近14日）"
  assert_contains "新設セクション9〜12がすべて出る" "$out" "## 9. aliases が無いノート"
  assert_contains "新設セクション10が出る" "$out" "## 10. 汎用すぎる／短すぎる alias"
  assert_contains "新設セクション11が出る" "$out" "## 11. review_by の期限"
  assert_contains "新設セクション12が出る" "$out" "## 12. 未読ノート"

  rm -rf "$VAULT_HOME"
}

echo "=== 13. 提示無視率（session_id突合・C-2）: 同一セッション後読/別セッション/未読/既読前提示の除外(N-3) ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/read-in-session.md" $'date: 2026-01-01\naliases:\n  - read-in-session-alias'
  write_note "$V" "Knowledge/read-different-session.md" $'date: 2026-01-01\naliases:\n  - read-different-session-alias'
  write_note "$V" "Knowledge/never-read-note.md" $'date: 2026-01-01\naliases:\n  - never-read-note-alias'
  write_note "$V" "Knowledge/read-before-presented.md" $'date: 2026-01-01\naliases:\n  - read-before-presented-alias'

  LOGDIR="$V/../.claude-logs-dismissal"
  mkdir -p "$LOGDIR"
  # 提示イベントは既定の時間窓(30日)内に収める（-50/-40/-30日は窓外になるため
  # -20/-15/-10日に変更＝2026-07-10 敵対的レビュー2回目 N-2 対応の窓導入に追従）。
  {
    printf '%s\tsessA\tKnowledge/read-in-session.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessA\tKnowledge/read-in-session.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessA\tKnowledge/read-in-session.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessB\tKnowledge/read-different-session.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessB\tKnowledge/read-different-session.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessB\tKnowledge/read-different-session.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessC\tKnowledge/never-read-note.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessC\tKnowledge/never-read-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessC\tKnowledge/never-read-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessD\tKnowledge/read-before-presented.md\tk\n' "$(d_ts -5)"
    printf '%s\tsessD\tKnowledge/read-before-presented.md\tk\n' "$(d_ts -4)"
    printf '%s\tsessD\tKnowledge/read-before-presented.md\tk\n' "$(d_ts -3)"
  } > "$LOGDIR/vault-recall.tsv"
  {
    # sessA: 最後の提示(-10日)と同時刻にRead → 境界(ts以降=以上)を満たし3件とも「読まれた」扱い
    printf '%s\tsessA\tKnowledge/read-in-session.md\n' "$(d_ts -10)"
    # sessX: 別セッションでのRead → sessBの提示とは突合されない
    printf '%s\tsessX\tKnowledge/read-different-session.md\n' "$(d_ts -10)"
    # sessD: 全ての提示より前のRead → N-3対応により3件全てが「正当な既読スキップ」として
    # 分母から除外される（旧実装は「読まれた率0%」＝無視、と誤って数えていた）
    printf '%s\tsessD\tKnowledge/read-before-presented.md\n' "$(d_ts -10)"
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "同一セッション内で後からReadされたノートは読まれた率100%" \
    "$out" "Knowledge/read-in-session.md\` — 提示3回中 読まれた率100%"
  assert_contains "別セッションでのReadは突合されず読まれた率0%" \
    "$out" "Knowledge/read-different-session.md\` — 提示3回中 読まれた率0%"
  assert_contains "一度もReadされないノートは読まれた率0%" \
    "$out" "Knowledge/never-read-note.md\` — 提示3回中 読まれた率0%"
  assert_not_contains "全提示より前にReadされていたノートはN-3対応により除外されワーストに出ない" \
    "$out" "Knowledge/read-before-presented.md\` — 提示"
  assert_contains "既読前提示として除外された3件が注記される(N-3)" \
    "$out" "うち、同一セッションで提示より前に既読だった提示3件は"

  rm -rf "$VAULT_HOME"
}

echo "=== 20. 提示無視率: 時間窓の境界（N-2・窓内=30日以内・窓外=31日以上は除外） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/window-boundary-note.md" $'date: 2026-01-01\naliases:\n  - window-boundary-note-alias'

  LOGDIR="$V/../.claude-logs-window"
  mkdir -p "$LOGDIR"
  {
    printf '%s\tsessA\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -5)"
    printf '%s\tsessA\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessA\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -30)"   # 境界: 窓内（30日以内）
    printf '%s\tsessA\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -31)"  # 境界: 窓外（31日は除外）
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "30日以内の3件だけが集計され、31日前は含まれない" \
    "$out" "Knowledge/window-boundary-note.md\` — 提示3回中 読まれた率0%"
  assert_contains "観測注記: 全期間4件のうち窓内3件が対象" \
    "$out" "観測: 直近30日・全期間の提示は4件（うち窓内3件を対象）"

  rm -rf "$VAULT_HOME"
}

echo "=== 21. 提示無視率: 既読前提示の部分除外（N-3・一部の提示イベントだけが既読前）==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/partial-exclusion-note.md" $'date: 2026-01-01\naliases:\n  - partial-exclusion-note-alias'

  LOGDIR="$V/../.claude-logs-partial-exclusion"
  mkdir -p "$LOGDIR"
  # 提示4回(-25,-24,-23,-22)の後にRead(-20)。さらに提示2回(-15,-14)はRead(-20)より後
  # ＝この2回は「提示より前に既読」としてN-3対応で除外される。残る4回は読まれた率100%。
  {
    printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -25)"
    printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -24)"
    printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -23)"
    printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -22)"
    printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -14)"
  } > "$LOGDIR/vault-recall.tsv"
  printf '%s\tsessA\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)" > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "既読より前の4件だけが分母に残り読まれた率100%（既読より後の2件は除外）" \
    "$out" "Knowledge/partial-exclusion-note.md\` — 提示4回中 読まれた率100%"
  assert_contains "部分除外2件が注記される(N-3)" \
    "$out" "うち、同一セッションで提示より前に既読だった提示2件は"

  rm -rf "$VAULT_HOME"
}

echo "=== 14. 提示無視率: 提示3回未満のノートはワーストに出ない ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/presented-twice.md" $'date: 2026-01-01\naliases:\n  - presented-twice-alias'

  LOGDIR="$V/../.claude-logs-dismissal-min"
  mkdir -p "$LOGDIR"
  {
    printf '%s\tsessA\tKnowledge/presented-twice.md\tk\n' "$(d_ts -50)"
    printf '%s\tsessA\tKnowledge/presented-twice.md\tk\n' "$(d_ts -40)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "提示2回のノートはワーストリストに出ない（分母3回未満は除外）" \
    "$out" "Knowledge/presented-twice.md\` — 提示"
  assert_contains "3回未満しか提示が無い場合は該当なしと出る" "$out" "該当なし（提示3回以上のノートがまだありません）"

  rm -rf "$VAULT_HOME"
}

echo "=== 15. ログ別死活判定（M-1）: recallだけ停止していてもreadsは正常表示・逆も同様 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/split-stale-note.md" $'date: 2026-01-01\naliases:\n  - split-stale-note-alias'

  LOGDIR="$V/../.claude-logs-split-stale"
  mkdir -p "$LOGDIR"
  # reads は直近5日以内に記録あり（生存）／recallは60日前が最後（停止疑い）
  printf '%s\tsessA\tKnowledge/split-stale-note.md\n' "$(d_ts -5)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsessA\tKnowledge/split-stale-note.md\tk\n' "$(d_ts -60)" > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "recallログの停止疑いが個別に注記される" "$out" "vault-recall.tsv: 直近 30 日以内の有効な記録が無い"
  assert_contains "recallの最終記録日が明示される" "$out" "最終記録: $(d_date -60)"
  assert_not_contains "readsは直近に記録があるので停止疑いは出ない" "$out" "vault-reads.tsv: 直近 30 日以内の有効な記録が無い"

  rm -rf "$VAULT_HOME"
}

echo "=== 16. ログ別死活判定（M-1）: 逆パターン（readsだけ停止・recallは正常） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/split-stale-note2.md" $'date: 2026-01-01\naliases:\n  - split-stale-note2-alias'

  LOGDIR="$V/../.claude-logs-split-stale2"
  mkdir -p "$LOGDIR"
  printf '%s\tsessA\tKnowledge/split-stale-note2.md\n' "$(d_ts -60)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsessA\tKnowledge/split-stale-note2.md\tk\n' "$(d_ts -5)" > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "readsログの停止疑いが個別に注記される" "$out" "vault-reads.tsv: 直近 30 日以内の有効な記録が無い"
  assert_not_contains "recallは直近に記録があるので停止疑いは出ない" "$out" "vault-recall.tsv: 直近 30 日以内の有効な記録が無い"

  rm -rf "$VAULT_HOME"
}

echo "=== 17. ログ死活（Codexレビュー指摘・Major）: ERROR行だけが積み上がる「壊れているが直近は動いている」を検知 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  LOGDIR="$V/../.claude-logs-broken"
  mkdir -p "$LOGDIR"
  # 直近のログ行は全てERROR行（3列目=空）。staleにはならない鮮度だが、有効な
  # ノート記録は1件も無い＝フックは動いているが失敗し続けている疑い。
  {
    printf '%s\tERROR\t\tsessA\tjq解析失敗\n' "$(d_ts -3)"
    printf '%s\tERROR\t\tsessA\tjq解析失敗\n' "$(d_ts -1)"
  } > "$LOGDIR/vault-reads.tsv"
  {
    printf '%s\tERROR\t\tsessA\tjq解析失敗\n' "$(d_ts -3)"
    printf '%s\tERROR\t\tsessA\tjq解析失敗\n' "$(d_ts -1)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "readsがERROR行だけでも「毎回失敗し続けている疑い」が出る" \
    "$out" "vault-reads.tsv: 最近ログは書かれています"
  assert_contains "recallがERROR行だけでも「毎回失敗し続けている疑い」が出る" \
    "$out" "vault-recall.tsv: 最近ログは書かれています"
  assert_not_contains "ERROR行だけの場合はstale(記録が無い)側のメッセージは出ない（別の警告に分離）" \
    "$out" "vault-reads.tsv: 直近 30 日以内の有効な記録が無い"

  rm -rf "$VAULT_HOME"
}

echo "=== 18. ログ死活（Codexレビュー指摘・Major）: 未来日時のログ行は「健全」に誤判定しない ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/future-log-note.md" $'date: 2026-01-01\naliases:\n  - future-log-note-alias'

  LOGDIR="$V/../.claude-logs-future"
  mkdir -p "$LOGDIR"
  # 最終行が10年後（システム時計のズレ・ファイル破損を模擬）。経過日数が負になり、
  # 素朴な `> LOG_STALE_DAYS` 判定だけだと「新しすぎるので健全」と誤判定してしまう。
  printf '%s\tsessA\tKnowledge/future-log-note.md\n' "$(d_ts 3650)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\tsessA\tKnowledge/future-log-note.md\tk\n' "$(d_ts 3650)" > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "readsの未来日時が注記される" "$out" "vault-reads.tsv: 最終記録が未来日時"
  assert_contains "recallの未来日時が注記される" "$out" "vault-recall.tsv: 最終記録が未来日時"

  rm -rf "$VAULT_HOME"
}

echo "=== 19. session_idが空のRead行（Codexレビュー指摘・再レビュー分Minor）: 突合不能を注記する ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  LOGDIR="$V/../.claude-logs-no-session"
  mkdir -p "$LOGDIR"
  printf '%s\t\tKnowledge/x.md\n' "$(d_ts -5)" > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall-none.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "session_idが空のRead行が注記される" "$out" "session_id が空のRead行 1 件"

  rm -rf "$VAULT_HOME"
}

echo "=== 22. 提示無視率: VAULT_DISMISS_WINDOW_DAYS が不正値でもクラッシュせず既定30日にフォールバックする（Codexレビュー指摘・Major） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/dummy-note.md" $'date: 2026-01-01\naliases:\n  - dummy-note-alias'

  # 4値それぞれについて exit 0・当日レポートへの30日フォールバックの両方を検証する
  # （ループ最後のケースだけを見ると他の値での退行を見逃しうる＝Codexレビュー
  # 指摘・Info。同じ当日ファイルに毎回上書きされるため、各回ごとにレポートを
  # 読み直して確認する）。
  for bad in "not-a-number" "-5" "0" ""; do
    rc=0
    VAULT_DISMISS_WINDOW_DAYS="$bad" VAULT_READS_LOG="/nonexistent-dir/r.tsv" VAULT_RECALL_LOG="/nonexistent-dir/c.tsv" \
      HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null 2>&1 || rc=$?
    if [[ "$rc" == "0" ]]; then
      pass "VAULT_DISMISS_WINDOW_DAYS=\"$bad\" でもクラッシュしない(exit 0)"
    else
      fail_case "VAULT_DISMISS_WINDOW_DAYS=\"$bad\" でクラッシュした(exit $rc)"
    fi
    out="$(cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"
    assert_contains "VAULT_DISMISS_WINDOW_DAYS=\"$bad\" は既定30日にフォールバックする（注記に30日と出る）" \
      "$out" "観測: 直近30日"
  done

  rm -rf "$VAULT_HOME"
}

echo "=== 23. 提示無視率: 未来日時の提示イベントは窓内に含めない（Codexレビュー指摘・Minor） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/future-presented-note.md" $'date: 2026-01-01\naliases:\n  - future-presented-note-alias'

  LOGDIR="$V/../.claude-logs-future-presented"
  mkdir -p "$LOGDIR"
  {
    printf '%s\tsessA\tKnowledge/future-presented-note.md\tk\n' "$(d_ts -5)"
    printf '%s\tsessA\tKnowledge/future-presented-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessA\tKnowledge/future-presented-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessA\tKnowledge/future-presented-note.md\tk\n' "$(d_ts 5)"   # 未来日時（システム時計のズレ・破損想定）
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" --force >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "未来日時1件を除いた3件だけが集計される" \
    "$out" "Knowledge/future-presented-note.md\` — 提示3回中 読まれた率0%"
  assert_contains "観測注記: 全期間4件のうち窓内3件が対象（未来日時は除外）" \
    "$out" "観測: 直近30日・全期間の提示は4件（うち窓内3件を対象）"

  rm -rf "$VAULT_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
