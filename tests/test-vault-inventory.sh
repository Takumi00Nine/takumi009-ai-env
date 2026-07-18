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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
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

# make_base_vault に加え、必読6ファイルの updated/aliases 欠落（§1・§9）と
# Fragments capture停止疑い（§8）を解消し、要確認件数(n_issues)が0件になる
# 「クリーンな」Vaultを作る。要確認件数への各警告種別の算入テスト（32番台）で
# 「対象の警告だけを単独で発生させて差分を見る」ための土台として使う
# （2026-07-14 外部脳バックログ・唯一未裏取りだったCodex指摘の確認・修正対応）。
make_clean_vault() {
  local vault="$1"
  make_base_vault "$vault"
  for f in "Knowledge/mistakes.md" "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Preferences/coding-delegation.md" "Preferences/vault-operation.md" \
           "Personal/profile-personal.md"; do
    printf -- '---\ndate: 2026-01-01\nupdated: 2026-01-01\naliases: [clean-vault-alias-%s]\n---\n\ndummy\n' \
      "$(basename "$f" .md)" > "$vault/$f"
  done
  printf -- '---\ndate: %s\n---\n\n## dummy entry\n' "$(date +%F)" > "$vault/Fragments/$(date +%F).md"
}

# レポート本文から「要確認 N 件」のNを取り出す
extract_n_issues() {
  echo "$1" | grep -oE '要確認 [0-9]+ 件' | head -1 | grep -oE '[0-9]+'
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

# vault_inventory.py を実行し、当日レポートの中身を返す（2026-07-16簡素化で
# 隔週間隔ガード・--forceオプションを撤去したため常に実行される）。
run_inventory() {
  local vault_home="$1"
  HOME="$vault_home" python3 "$SCRIPT" >/dev/null
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
  # 3回の提示はそれぞれ別セッション(sess1a/1b/1c)にする（2026-07-13 round3対応で
  # 提示無視率の分母が (session_id, ノート) 単位に正規化されたため、同一セッション
  # 内の複数提示は1回に集約される＝ここで3回として数えたいなら別セッションが必要）。
  {
    printf '%s\tsess1a\tKnowledge/recalled-often.md\tmatched-key\n' "$(d_ts -20)"
    printf '%s\tsess1b\tKnowledge/recalled-often.md\tmatched-key\n' "$(d_ts -15)"
    printf '%s\tsess1c\tKnowledge/recalled-often.md\tmatched-key\n' "$(d_ts -10)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "aware/naive混在でもクラッシュせずレポートが生成される" "$out" "## 12. 未読ノート"
  assert_contains "真に解析不能な行が2件（ERROR行0件）と分離表示される(round3対応)" \
    "$out" "解析対象外の vault-reads.tsv 行 2 件（うち ERROR行 0 件・真に解析不能な行 2 件）"
  assert_contains "真に解析不能な行があるので破損疑いの警告が出る" "$out" "⚠️ 真に解析不能な行が 2 件あります"
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
  # 各ノートへの3回の提示はそれぞれ別セッション(sessA1-3等)にする（2026-07-13
  # round3対応で提示無視率の分母が (session_id, ノート) 単位に正規化されたため、
  # 同一セッション内の複数提示は1回に集約される＝ここで3回として数えたいなら
  # 別セッションが必要。同一セッション内の重複集約そのものは別テスト24で検証）。
  {
    printf '%s\tsessA1\tKnowledge/read-in-session.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessA2\tKnowledge/read-in-session.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessA3\tKnowledge/read-in-session.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessB1\tKnowledge/read-different-session.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessB2\tKnowledge/read-different-session.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessB3\tKnowledge/read-different-session.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessC1\tKnowledge/never-read-note.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessC2\tKnowledge/never-read-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessC3\tKnowledge/never-read-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessD1\tKnowledge/read-before-presented.md\tk\n' "$(d_ts -5)"
    printf '%s\tsessD2\tKnowledge/read-before-presented.md\tk\n' "$(d_ts -4)"
    printf '%s\tsessD3\tKnowledge/read-before-presented.md\tk\n' "$(d_ts -3)"
  } > "$LOGDIR/vault-recall.tsv"
  {
    # sessA1-3: それぞれ自セッション内・自提示時刻と同時刻にRead → 境界(ts以降=以上)を
    # 満たし3セッションとも「読まれた」扱い
    printf '%s\tsessA1\tKnowledge/read-in-session.md\n' "$(d_ts -20)"
    printf '%s\tsessA2\tKnowledge/read-in-session.md\n' "$(d_ts -15)"
    printf '%s\tsessA3\tKnowledge/read-in-session.md\n' "$(d_ts -10)"
    # sessX: 別セッションでのRead → sessB1-3の提示とは突合されない
    printf '%s\tsessX\tKnowledge/read-different-session.md\n' "$(d_ts -10)"
    # sessD1-3: それぞれ自セッション内で提示より前のRead → N-3対応により3セッション
    # 全てが「正当な既読スキップ」として分母から除外される
    # （旧実装は「読まれた率0%」＝無視、と誤って数えていた）
    printf '%s\tsessD1\tKnowledge/read-before-presented.md\n' "$(d_ts -10)"
    printf '%s\tsessD2\tKnowledge/read-before-presented.md\n' "$(d_ts -10)"
    printf '%s\tsessD3\tKnowledge/read-before-presented.md\n' "$(d_ts -10)"
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    "$out" "うち、正規化後の提示のうち提示より前に既読だった3件は"

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
  # 4件をそれぞれ別セッションにする（2026-07-13 round3対応で提示無視率の分母が
  # (session_id, ノート) 単位に正規化されたため、同一セッション内の複数提示だと
  # 窓内3件でも1セッションに集約されてしまい本テストの意図＝時間窓境界の検証が
  # できなくなる）。
  {
    printf '%s\tsessW1\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -5)"
    printf '%s\tsessW2\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessW3\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -30)"   # 境界: 窓内（30日以内）
    printf '%s\tsessW4\tKnowledge/window-boundary-note.md\tk\n' "$(d_ts -31)"  # 境界: 窓外（31日は除外）
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
  # 4セッション(sessP1-4)は各セッション内で提示の後にRead＝正当な「読まれた」。
  # 2セッション(sessQ1-2)は各セッション内で提示より前にRead＝N-3対応で除外される。
  # （2026-07-13 round3対応で提示無視率の分母が (session_id, ノート) 単位に正規化
  # されたため、「1回のReadが同一セッション内の複数提示イベントを部分的に満たす」
  # という旧来の検証はセッション単位に置き換える＝各セッションに自分のReadを持たせる）。
  {
    printf '%s\tsessP1\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -25)"
    printf '%s\tsessP2\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -24)"
    printf '%s\tsessP3\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -23)"
    printf '%s\tsessP4\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -22)"
    printf '%s\tsessQ1\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessQ2\tKnowledge/partial-exclusion-note.md\tk\n' "$(d_ts -14)"
  } > "$LOGDIR/vault-recall.tsv"
  {
    printf '%s\tsessP1\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)"
    printf '%s\tsessP2\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)"
    printf '%s\tsessP3\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)"
    printf '%s\tsessP4\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)"
    printf '%s\tsessQ1\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)"
    printf '%s\tsessQ2\tKnowledge/partial-exclusion-note.md\n' "$(d_ts -20)"
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "既読より前の4セッションだけが分母に残り読まれた率100%（既読より後の2セッションは除外）" \
    "$out" "Knowledge/partial-exclusion-note.md\` — 提示4回中 読まれた率100%"
  assert_contains "部分除外2件が注記される(N-3)" \
    "$out" "うち、正規化後の提示のうち提示より前に既読だった2件は"

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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "提示2回のノートはワーストリストに出ない（分母3回未満は除外）" \
    "$out" "Knowledge/presented-twice.md\` — 提示"
  assert_contains "3回未満しか提示が無い場合は該当なしと出る" "$out" "該当なし（正規化後の提示3回以上のノートがまだありません）"

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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "readsがERROR行だけでも「毎回失敗し続けている疑い」が出る" \
    "$out" "vault-reads.tsv: 最近ログは書かれています"
  assert_contains "recallがERROR行だけでも「毎回失敗し続けている疑い」が出る" \
    "$out" "vault-recall.tsv: 最近ログは書かれています"
  assert_not_contains "ERROR行だけの場合はstale(記録が無い)側のメッセージは出ない（別の警告に分離）" \
    "$out" "vault-reads.tsv: 直近 30 日以内の有効な記録が無い"
  # 2026-07-13 敵対的レビューround3の実バグ級指摘: ERROR行（フックが自ら記録する
  # 正常なエラーログ）を「解析できなかった行＝ログ破損の疑い」に合算していた
  # （78行の実体はERROR行78件）。読込側(reads_error_rows/recall_error_rows)で
  # skippedと分離して初めて検出できる回帰。
  assert_contains "readsのERROR行2件が「ERROR行2件・真に解析不能な行0件」に分離表示される(round3対応)" \
    "$out" "解析対象外の vault-reads.tsv 行 2 件（うち ERROR行 2 件・真に解析不能な行 0 件）"
  assert_contains "recallのERROR行2件も同様に分離表示される" \
    "$out" "解析対象外の vault-recall.tsv 行 2 件（うち ERROR行 2 件・真に解析不能な行 0 件）"
  assert_not_contains "ERROR行のみ(真に解析不能な行0件)の場合は破損疑いの警告を出さない(round3対応)" \
    "$out" "⚠️ 真に解析不能な行が"

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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
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
      HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null 2>&1 || rc=$?
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
  # 4件をそれぞれ別セッションにする（2026-07-13 round3対応で提示無視率の分母が
  # (session_id, ノート) 単位に正規化されたため、同一セッション内の複数提示だと
  # 窓内3件でも1セッションに集約されてしまい本テストの意図＝未来日時の除外検証が
  # できなくなる）。
  {
    printf '%s\tsessF1\tKnowledge/future-presented-note.md\tk\n' "$(d_ts -5)"
    printf '%s\tsessF2\tKnowledge/future-presented-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessF3\tKnowledge/future-presented-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessF4\tKnowledge/future-presented-note.md\tk\n' "$(d_ts 5)"   # 未来日時（システム時計のズレ・破損想定）
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "未来日時1件を除いた3件だけが集計される" \
    "$out" "Knowledge/future-presented-note.md\` — 提示3回中 読まれた率0%"
  assert_contains "観測注記: 全期間4件のうち窓内3件が対象（未来日時は除外）" \
    "$out" "観測: 直近30日・全期間の提示は4件（うち窓内3件を対象）"

  rm -rf "$VAULT_HOME"
}

echo "=== 24. 提示無視率: 同一セッション内の同一ノート重複提示は(session_id,ノート)単位に1回へ正規化される（2026-07-13 round3対応） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/session-artifact-note.md" $'date: 2026-01-01\naliases:\n  - session-artifact-note-alias'

  LOGDIR="$V/../.claude-logs-dedup"
  mkdir -p "$LOGDIR"
  # 同一セッション(sessDup)内で同一ノートが10回「提示」される想定
  # （長時間セッションで過去の棚卸しレポート引用やフック自身の過去提示文が
  # プロンプト本文に再登場して再ヒットするアーティファクトを模す）。
  # 正規化前(raw)は10件だが、正規化後は1セッション分＝DISMISS_MIN_PRESENTED(3)未満
  # のためワーストには出ないはず（旧実装ではraw件数がそのまま分母になり
  # 「提示10回中 読まれた率0%」としてワースト最上位に誤って出ていた）。
  {
    for n in 20 19 18 17 16 15 14 13 12 11; do
      printf '%s\tsessDup\tKnowledge/session-artifact-note.md\tk\n' "$(d_ts -"$n")"
    done
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "同一セッション内の重複提示は正規化後1セッションに集約され、閾値(3)未満のためワーストに出ない" \
    "$out" "session-artifact-note.md\` — 提示"
  assert_not_contains "生の提示回数10件のままでは集計されない（正規化前カウントでの誤検出防止）" \
    "$out" "session-artifact-note.md\` — 提示10回中"

  rm -rf "$VAULT_HOME"
}

echo "=== 25. 提示無視率: 複数セッションそれぞれの重複提示は正規化後のセッション数で集計され、生の提示回数も参考値として出る ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/multi-session-dup-note.md" $'date: 2026-01-01\naliases:\n  - multi-session-dup-note-alias'

  LOGDIR="$V/../.claude-logs-dedup-multi"
  mkdir -p "$LOGDIR"
  # sessM1=2回・sessM2=3回・sessM3=4回、同一ノートを重複提示（生の合計は9件）。
  # 一度もReadされない。正規化後は3セッション分＝閾値(3)を満たしワーストに出る。
  {
    printf '%s\tsessM1\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -25)"
    printf '%s\tsessM1\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -24)"
    printf '%s\tsessM2\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessM2\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -19)"
    printf '%s\tsessM2\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -18)"
    printf '%s\tsessM3\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -15)"
    printf '%s\tsessM3\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -14)"
    printf '%s\tsessM3\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -13)"
    printf '%s\tsessM3\tKnowledge/multi-session-dup-note.md\tk\n' "$(d_ts -12)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "正規化後3セッション・生提示回数9件が併記される" \
    "$out" "Knowledge/multi-session-dup-note.md\` — 提示3回中 読まれた率0%（生提示回数9）"

  rm -rf "$VAULT_HOME"
}

echo "=== 26. 提示無視率: 同一セッション内の重複提示の代表時刻は入力順序に依存せず最小tsになる（Codex一次レビュー指摘・回帰防止） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/order-independent-note.md" $'date: 2026-01-01\naliases:\n  - order-independent-note-alias'

  LOGDIR="$V/../.claude-logs-order"
  mkdir -p "$LOGDIR"
  # 3セッション(sessOrder1-3)。各セッション内で同一ノートへの提示を「新しい方
  # (-10日)を先に・古い方(-20日)を後に」という非時系列順でログに書く（過去の
  # レポート引用等の再ヒットで実質的な提示順が乱れるケースを模す）。代表提示時刻は
  # 「グループ内の最小ts」であるべき（-20日）。もし実装が誤って「ファイルで最初に
  # 出現した行」を代表にしていると（-10日を代表にしてしまう）、-20日と-10日の間の
  # -15日にあるReadは「代表より前」と誤判定され、正当な読了が「既読前提示」として
  # 分母ごと除外されてしまう（回帰時にのみ落ちるテスト）。
  {
    printf '%s\tsessOrder1\tKnowledge/order-independent-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessOrder1\tKnowledge/order-independent-note.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessOrder2\tKnowledge/order-independent-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessOrder2\tKnowledge/order-independent-note.md\tk\n' "$(d_ts -20)"
    printf '%s\tsessOrder3\tKnowledge/order-independent-note.md\tk\n' "$(d_ts -10)"
    printf '%s\tsessOrder3\tKnowledge/order-independent-note.md\tk\n' "$(d_ts -20)"
  } > "$LOGDIR/vault-recall.tsv"
  {
    printf '%s\tsessOrder1\tKnowledge/order-independent-note.md\n' "$(d_ts -15)"
    printf '%s\tsessOrder2\tKnowledge/order-independent-note.md\n' "$(d_ts -15)"
    printf '%s\tsessOrder3\tKnowledge/order-independent-note.md\n' "$(d_ts -15)"
  } > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "代表時刻は入力順序でなく最小ts(-20日)。-15日のReadは代表より後なので3セッションとも読まれた率100%" \
    "$out" "Knowledge/order-independent-note.md\` — 提示3回中 読まれた率100%"

  rm -rf "$VAULT_HOME"
}

echo "=== 27. 提示無視率: session_idが空の重複提示行は(session_id,ノート)へグルーピングされず1行=1提示のまま扱われる ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/no-session-dup-note.md" $'date: 2026-01-01\naliases:\n  - no-session-dup-note-alias'

  LOGDIR="$V/../.claude-logs-no-session-dup"
  mkdir -p "$LOGDIR"
  # session_idが空の行は他行と突合できずグルーピングもできないため、正規化の対象外
  # として従来どおり1行=1提示のまま扱う（fail-closed設計を維持）。同一ノートへの
  # 3行がすべて別提示として数えられ、かつReadとは突合できないため読まれた率0%になる。
  {
    printf '%s\t\tKnowledge/no-session-dup-note.md\tk\n' "$(d_ts -20)"
    printf '%s\t\tKnowledge/no-session-dup-note.md\tk\n' "$(d_ts -15)"
    printf '%s\t\tKnowledge/no-session-dup-note.md\tk\n' "$(d_ts -10)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "session_idが空の3行はグルーピングされず1行=1提示のまま3件として数えられる" \
    "$out" "Knowledge/no-session-dup-note.md\` — 提示3回中 読まれた率0%"
  assert_contains "session_idが空の提示行3件が注記される" "$out" "session_id が空の提示行 3 件"

  rm -rf "$VAULT_HOME"
}

echo "=== 28. §12: heartbeat行（claude/hooks/vault-recall.shの3列目'(heartbeat)')は提示回数上位・提示無視率ワーストから除外されるが、死活判定では有効な活動として扱われる（2026-07-13外部脳round4対応・小修正4） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/heartbeat-real-note.md" $'date: 2026-01-01\naliases:\n  - heartbeat-real-note-alias'

  LOGDIR="$V/../.claude-logs-heartbeat"
  mkdir -p "$LOGDIR"
  # heartbeat行を3セッション分（提示無視率のDISMISS_MIN_PRESENTED=3を満たす件数）＋
  # 実ノートへの提示3セッション分を同居させる。フィルタが効いていなければ
  # heartbeatも「よく提示されるノート」として上位・ワーストに混ざってしまうはず。
  {
    printf '%s\thbsess1\t(heartbeat)\n' "$(d_ts -20)"
    printf '%s\thbsess2\t(heartbeat)\n' "$(d_ts -15)"
    printf '%s\thbsess3\t(heartbeat)\n' "$(d_ts -10)"
    printf '%s\trealsess1\tKnowledge/heartbeat-real-note.md\tmatched-key\n' "$(d_ts -20)"
    printf '%s\trealsess2\tKnowledge/heartbeat-real-note.md\tmatched-key\n' "$(d_ts -15)"
    printf '%s\trealsess3\tKnowledge/heartbeat-real-note.md\tmatched-key\n' "$(d_ts -10)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "heartbeat行は提示回数上位おまけに出ない" "$out" "(heartbeat)\` —"
  assert_not_contains "heartbeat行は提示無視率ワーストに出ない" "$out" "(heartbeat)\` — 提示"
  assert_contains "実ノートへの提示3回は従来どおり提示無視率ワーストに出る" \
    "$out" "Knowledge/heartbeat-real-note.md\` — 提示3回中 読まれた率0%"
  assert_contains "実ノートへの提示3回は従来どおり提示回数上位おまけに出る" \
    "$out" "Knowledge/heartbeat-real-note.md\` — 3回"

  rm -rf "$VAULT_HOME"
}

echo "=== 29. §12: heartbeat行しかvault-recall.tsvに無くても死活判定では「動いている」扱いになる（提示回数上位/無視率は0件） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  LOGDIR="$V/../.claude-logs-heartbeat-only"
  mkdir -p "$LOGDIR"
  printf '%s\thbonly1\t(heartbeat)\n' "$(d_ts -5)" > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "heartbeatのみでも直近記録ありとみなされフック停止疑いは注記されない" \
    "$out" "vault-recall.tsv: 直近 30 日以内の有効な記録が無い"
  assert_not_contains "heartbeatしか無いので提示回数上位おまけの見出し自体が出ない" \
    "$out" "おまけ: vault-recall.tsv 提示回数"
  assert_contains "提示無視率ワーストはheartbeatしかないので該当なし表記になる" \
    "$out" "該当なし（正規化後の提示3回以上のノートがまだありません）"
  # heartbeatはread_log()上は「3列目が空でない有効行」としてrowsに入る
  # （HEARTBEAT_MARKER自体がノートパスの位置を占めるダミー文字列のため）。
  # フィルタで集計対象から除外しても rows 自体からは除かないため、
  # 死活判定の「有効な記録が無く失敗し続けている」誤警告（ERRORING/BROKEN）は
  # 出ないはず（Codex一次レビュー指摘・Minor: 従来はSTALE非表示のみの確認で、
  # BROKEN側を明示的に確認していなかった）。
  assert_not_contains "heartbeatのみでもフックが失敗し続けている疑いの警告は出ない" \
    "$out" "が、有効なノート記録（ERROR行以外）が1件もありません"

  rm -rf "$VAULT_HOME"
}

echo "=== 29b. §12: session_idが空のheartbeat行は『session_idが空の提示行』件数に混ざらない（Codex一次レビュー指摘・Minor対応） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/no-session-heartbeat-note.md" $'date: 2026-01-01\naliases:\n  - no-session-heartbeat-note-alias'

  LOGDIR="$V/../.claude-logs-heartbeat-no-session"
  mkdir -p "$LOGDIR"
  # session_idが空のheartbeat行2件（フィルタ漏れがあれば「session_idが空の
  # 提示行」に混入する）＋session_idが空の実ノート提示1件（従来どおり数えられる
  # べき正常系）。
  {
    printf '%s\t\t(heartbeat)\n' "$(d_ts -10)"
    printf '%s\t\t(heartbeat)\n' "$(d_ts -5)"
    printf '%s\t\tKnowledge/no-session-heartbeat-note.md\tk\n' "$(d_ts -3)"
  } > "$LOGDIR/vault-recall.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_contains "session_idが空の提示行は実ノート1件のみ数えられる（heartbeat2件は混ざらない）" \
    "$out" "session_id が空の提示行 1 件"

  rm -rf "$VAULT_HOME"
}

echo "=== 30. 停滞プロジェクト検出（§6）: statusは完全一致ではなく単語境界で判定する（\"inactive\"に\"active\"が誤ヒットしない・Codexレビュー指摘の実装ミス修正） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  write_note "$V" "Projects/really-active-project.md" \
    "$(printf 'date: 2026-01-01\nupdated: %s\nstatus: active' "$(d_date -40)")"
  write_note "$V" "Projects/inactive-project.md" \
    "$(printf 'date: 2026-01-01\nupdated: %s\nstatus: inactive' "$(d_date -40)")"
  write_note "$V" "Projects/annotated-in-progress-project.md" \
    "$(printf 'date: 2026-01-01\nupdated: %s\nstatus: in_progress（備考あり）' "$(d_date -40)")"
  write_note "$V" "Projects/not-active-project.md" \
    "$(printf 'date: 2026-01-01\nupdated: %s\nstatus: not-active' "$(d_date -40)")"

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "status:activeで30日以上前は従来どおり停滞として検出される" "$out" "Projects/really-active-project.md\` — active（"
  assert_not_contains "status:inactiveは'active'を部分文字列に含むが誤って停滞検出されない" "$out" "Projects/inactive-project.md\` — inactive（"
  assert_contains "注記付きstatus値でも単語境界一致で正しく検出される（完全一致にはしない）" "$out" "Projects/annotated-in-progress-project.md\` — in_progress（備考あり）（"
  assert_not_contains "'not-active'は先頭が'active'ではないため誤って停滞検出されない（Codexレビュー指摘・search()からmatch()への是正確認）" \
    "$out" "Projects/not-active-project.md\` — not-active（"

  rm -rf "$VAULT_HOME"
}

echo "=== 31. §6b: statusノートのupdated/dateが未来日だと要確認として計上される（未来日検証の欠落修正・Codexレビュー指摘） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  write_note "$V" "Projects/future-dated-project.md" \
    "$(printf 'date: 2026-01-01\nupdated: %s\nstatus: active' "$(d_date 5)")"

  out="$(run_inventory "$VAULT_HOME")"
  assert_contains "未来日updatedのstatusノートが§6bの要確認に載る" "$out" "Projects/future-dated-project.md\` — active（"
  assert_contains "§6bの文言に「未来日」が明記される" "$out" "は今日から見て未来日）"
  assert_not_contains "未来日は経過日数が負になるため§6の停滞（〜日前）表記では出ない" "$out" "Projects/future-dated-project.md\` — active（最終"

  rm -rf "$VAULT_HOME"
}

echo "=== 32. 要確認件数(n_issues): §5個別ファイルのサイズ超過(40行超)が算入される（2026-07-14・Codex指摘の未裏取り分を確認し確定した実バグの修正） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  before_n="$(extract_n_issues "$(run_inventory "$VAULT_HOME")")"

  # Preferences/profile.md をSIZE_LIMIT_LINES(40行)超にする（合計は150行未満のまま＝
  # 個別ファイル警告だけを単独発生させ、§5合計超過(要確認33)とは分離する）
  {
    echo "---"; echo "date: 2026-01-01"; echo "updated: 2026-01-01"
    echo "aliases: [clean-vault-alias-profile]"; echo "---"; echo
    for i in $(seq 1 45); do echo "line $i"; done
  } > "$V/Preferences/profile.md"

  out_after="$(run_inventory "$VAULT_HOME")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "§5に40行超の⚠️が表示される" "$out_after" "\`Preferences/profile.md\` — 51 行"
  assert_contains "§5に40行超の⚠️マークが付く" "$out_after" "⚠️ 40行超"
  if [[ "$before_n" -eq 0 && "$after_n" -eq 1 ]]; then
    pass "profile.mdの40行超で要確認件数が0→1に増える（修正前は§5がn_issuesから漏れていた）"
  else
    fail_case "要確認件数が想定通り増えない(before=$before_n after=$after_n・期待 0→1)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 33. 要確認件数(n_issues): §5合計サイズ超過（各ファイルは40行以下でも合計150行超）が算入される ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  before_n="$(extract_n_issues "$(run_inventory "$VAULT_HOME")")"

  # 必読6ファイルそれぞれを本文25行（frontmatter5行+空行1行=計31行・個別上限40行未満）
  # にし、合計186行（合計上限150行超）にする（Codex一次レビュー指摘・Info:
  # 当初コメントが「各30行・合計180行」と書かれていたが実際の生成物は31行/186行
  # だったため実測値に合わせて訂正）
  for f in "Knowledge/mistakes.md" "Preferences/absolute-rules.md" "Preferences/profile.md" \
           "Preferences/coding-delegation.md" "Preferences/vault-operation.md" \
           "Personal/profile-personal.md"; do
    {
      echo "---"; echo "date: 2026-01-01"; echo "updated: 2026-01-01"
      echo "aliases: [clean-vault-alias-$(basename "$f" .md)]"; echo "---"; echo
      for i in $(seq 1 25); do echo "line $i"; done
    } > "$V/$f"
  done

  out_after="$(run_inventory "$VAULT_HOME")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "§5に要圧縮の⚠️が表示される" "$out_after" "⚠️ **要圧縮**"
  assert_not_contains "個別ファイルはいずれも40行以下なので個別警告(40行超)は出ない" "$out_after" "⚠️ 40行超"
  if [[ "$before_n" -eq 0 && "$after_n" -eq 1 ]]; then
    pass "合計サイズ超過のみ(個別超過なし)で要確認件数が0→1に増える"
  else
    fail_case "要確認件数が想定通り増えない(before=$before_n after=$after_n・期待 0→1)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 33b. 要確認件数(n_issues): §5合計サイズ超過はbytes側(20KB超)単独でも算入される（Codex一次レビュー指摘・Minor対応） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  before_n="$(extract_n_issues "$(run_inventory "$VAULT_HOME")")"

  # 行数は増やさず(個別40行以下・合計150行以下のまま)、1行を21000文字にして
  # bytes側(20,480 bytes)だけを合計超過させる（size_over_totalがtotal_linesと
  # total_bytesの両方をorで見ている式のうち、bytes側だけが脱落する回帰を検出する）
  {
    echo "---"; echo "date: 2026-01-01"; echo "updated: 2026-01-01"
    echo "aliases: [clean-vault-alias-mistakes]"; echo "---"; echo
    printf 'a%.0s' $(seq 1 21000); echo
  } > "$V/Knowledge/mistakes.md"

  out_after="$(run_inventory "$VAULT_HOME")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "§5に要圧縮の⚠️が表示される（bytes超過）" "$out_after" "⚠️ **要圧縮**"
  assert_not_contains "行数は上限内なので個別警告(40行超)は出ない" "$out_after" "⚠️ 40行超"
  if [[ "$before_n" -eq 0 && "$after_n" -eq 1 ]]; then
    pass "bytes側のみの合計超過で要確認件数が0→1に増える"
  else
    fail_case "要確認件数が想定通り増えない(before=$before_n after=$after_n・期待 0→1)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 33c. 要確認件数(n_issues): §5個別超過と合計超過が同時発生すると両方が別々に加算される（Codex一次レビュー指摘・Minor対応: or統合の誤修正を回帰検出） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  before_n="$(extract_n_issues "$(run_inventory "$VAULT_HOME")")"

  # 3ファイルを本文55行(=ファイル計61行・個別上限40行超×3件)にし、残り3ファイルは
  # make_clean_vaultのデフォルト(ファイル計7行)のまま。合計は3*61+3*7=204行で
  # 合計上限150行も超える＝個別3件＋合計1件＝計4件が同時に加算されるはず（もし
  # 実装が size_over_total と size_over_files を`or`でまとめる形に誤って統合
  # されていたら1件にしかならずこの期待値4で検出できる。Codex一次レビュー
  # 指摘・Info: 当初コメントの行数計算が実測値とずれていたため訂正）
  for f in "Knowledge/mistakes.md" "Preferences/profile.md" "Preferences/coding-delegation.md"; do
    {
      echo "---"; echo "date: 2026-01-01"; echo "updated: 2026-01-01"
      echo "aliases: [clean-vault-alias-$(basename "$f" .md)]"; echo "---"; echo
      for i in $(seq 1 55); do echo "line $i"; done
    } > "$V/$f"
  done

  out_after="$(run_inventory "$VAULT_HOME")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "§5に要圧縮の⚠️が表示される" "$out_after" "⚠️ **要圧縮**"
  assert_contains "個別超過(40行超)が3件分表示される" "$out_after" "⚠️ 40行超"
  if [[ "$before_n" -eq 0 && "$after_n" -eq 4 ]]; then
    pass "個別超過3件＋合計超過1件が同時に加算され要確認件数が0→4になる（or統合されていないことを確認）"
  else
    fail_case "要確認件数が想定通り増えない(before=$before_n after=$after_n・期待 0→4)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 34. 要確認件数(n_issues): §8 Fragments capture停止疑いが算入される ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  rm "$V/Fragments/$(date +%F).md"   # capture停止状態にする（frag_files=0）

  out_after="$(run_inventory "$VAULT_HOME")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "§8にcapture停止疑いの⚠️が表示される" "$out_after" "⚠️ capture が止まっている可能性"
  if [[ "$after_n" -eq 1 ]]; then
    pass "Fragments capture停止のみで要確認件数が1件になる（修正前は§8がn_issuesから漏れていた）"
  else
    fail_case "要確認件数が想定通りにならない(after=$after_n・期待 1)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 35. 要確認件数(n_issues): §11 review_by の14日以内到来(review_soon)が算入される ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  before_n="$(extract_n_issues "$(run_inventory "$VAULT_HOME")")"

  write_note "$V" "Decisions/2026-01-01-n-issues-review-soon.md" \
    "date: 2026-01-01
aliases: [n-issues-review-soon-alias]
review_by: $(d_date 7)"

  out_after="$(run_inventory "$VAULT_HOME")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "§11に14日以内到来のノートが表示される" "$out_after" "n-issues-review-soon.md\` — review_by $(d_date 7)"
  if [[ "$before_n" -eq 0 && "$after_n" -eq 1 ]]; then
    pass "review_soon 1件で要確認件数が0→1に増える（修正前はreview_overdueのみ算入・review_soonが漏れていた）"
  else
    fail_case "要確認件数が想定通り増えない(before=$before_n after=$after_n・期待 0→1)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 36. 要確認件数(n_issues): §12 session_idが空のRead/提示行が算入される ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  LOGDIR="$V/../.claude-logs-n-issues-no-session"
  mkdir -p "$LOGDIR"
  printf '%s\t\tKnowledge/n-issues-no-session-dummy.md\n' "$(d_ts -5)" > "$LOGDIR/vault-reads.tsv"
  printf '%s\t\tKnowledge/n-issues-no-session-dummy.md\tk\n' "$(d_ts -5)" > "$LOGDIR/vault-recall.tsv"

  before_n="$(extract_n_issues "$(VAULT_READS_LOG="$LOGDIR/vault-reads-none.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall-none.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")")"

  out_after="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"
  after_n="$(extract_n_issues "$out_after")"

  assert_contains "session_idが空のRead行の注記が出る" "$out_after" "session_id が空のRead行 1 件"
  assert_contains "session_idが空の提示行の注記が出る" "$out_after" "session_id が空の提示行 1 件"
  if [[ "$before_n" -eq 0 && "$after_n" -eq 2 ]]; then
    pass "session_idが空のRead行・提示行それぞれ1件で要確認件数が0→2に増える（修正前はいずれもn_issuesから漏れていた）"
  else
    fail_case "要確認件数が想定通り増えない(before=$before_n after=$after_n・期待 0→2)"
  fi

  rm -rf "$VAULT_HOME"
}

echo "=== 37. read_log()のerror_rows: claude/hooks/vault-recall.sh log_fact()由来の6列目'INFO'行はERROR件数に算入しない（旧形式のレベル列なし行は従来どおり算入・後方互換） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  LOGDIR="$V/../.claude-logs-info-level"
  mkdir -p "$LOGDIR"
  # 3列目=空・2列目="ERROR"固定文字列は共通。旧形式(レベル列なし・5列)のERROR行2件と、
  # log_fact()由来（6列目に固定文字列"INFO"を付与）の事実記録行2件を混在させる。
  {
    printf '%s\tERROR\t\tsessA\t旧形式のfail-open失敗\n' "$(d_ts -4)"
    printf '%s\tERROR\t\tsessA\t削除済みノートのベクトル残存を1件除外しました\tINFO\n' "$(d_ts -3)"
    printf '%s\tERROR\t\tsessA\t2件のノートを読み取れませんでした\tINFO\n' "$(d_ts -2)"
    printf '%s\tERROR\t\tsessA\t旧形式のfail-open失敗その2\n' "$(d_ts -1)"
  } > "$LOGDIR/vault-recall.tsv"
  printf '%s\tsessA\tKnowledge/dummy.md\n' "$(d_ts -1)" > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  # 4行中、6列目"INFO"の事実記録2件はERROR件数からもskipped件数からも除外され、
  # 旧形式(レベル列なし)のERROR行2件だけがERROR行としてカウントされる。
  assert_contains "旧形式ERROR行2件のみがERROR行として計上され、log_fact()由来のINFO行2件は算入されない" \
    "$out" "解析対象外の vault-recall.tsv 行 2 件（うち ERROR行 2 件・真に解析不能な行 0 件）"
  assert_not_contains "真に解析不能な行の警告(ログ破損の疑い)はINFO行を理由に出ない" \
    "$out" "⚠️ 真に解析不能な行が"

  rm -rf "$VAULT_HOME"
}

echo "=== 37b. read_log()のerror_rows: vault-recall.tsvが全てlog_fact()由来のINFO行のみだとERROR行0件・真に解析不能な行0件になる（フックの正常な事実記録のみで壊れていない） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  LOGDIR="$V/../.claude-logs-info-only"
  mkdir -p "$LOGDIR"
  {
    printf '%s\tERROR\t\tsessA\t削除済みノートのベクトル残存を1件除外しました\tINFO\n' "$(d_ts -2)"
    printf '%s\tERROR\t\tsessA\t3件のノートを読み取れませんでした\tINFO\n' "$(d_ts -1)"
  } > "$LOGDIR/vault-recall.tsv"
  printf '%s\tsessA\tKnowledge/dummy.md\n' "$(d_ts -1)" > "$LOGDIR/vault-reads.tsv"

  out="$(VAULT_READS_LOG="$LOGDIR/vault-reads.tsv" VAULT_RECALL_LOG="$LOGDIR/vault-recall.tsv" \
    HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null && \
    cat "$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md | sort | tail -1)")"

  assert_not_contains "INFO行しか無い場合は「解析対象外の vault-recall.tsv 行」の注記自体が出ない（ERROR行0件・真に解析不能な行0件のため）" \
    "$out" "解析対象外の vault-recall.tsv 行"

  rm -rf "$VAULT_HOME"
}

echo "=== 38. 2026-07-16簡素化: 隔週間隔ガードを撤去し常に実行される（--force不要・連続2回実行しても両方成功） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  rc1=0; rc2=0
  HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null 2>&1 || rc1=$?
  HOME="$VAULT_HOME" python3 "$SCRIPT" >/dev/null 2>&1 || rc2=$?
  assert_eq "1回目もexit 0" "0" "$rc1"
  assert_eq "2回目(同日再実行)もskipせずexit 0" "0" "$rc2"
  n_reports="$(ls "$VAULT_HOME/.claude/logs/vault-inventory"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "同日再実行でもレポートは作られる(1件・同日は上書き)" "1" "$n_reports"

  rm -rf "$VAULT_HOME"
}

echo "=== 39. --json: missing_updated（Preferences限定）のFIX候補が計算される(fixable=true・fix_date=date値) ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Preferences/fixable-note.md" $'date: 2026-01-01'

  out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  fixable="$(printf '%s' "$out" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/fixable-note.md'][0]
print(c['fixable'], c['fix_date'], c['skip_reason'])
")"
  assert_eq "fixable=Trueでfix_date=2026-01-01・skip_reasonはNone" "True 2026-01-01 None" "$fixable"

  rm -rf "$VAULT_HOME"
}

echo "=== 40. --json: date:フィールドが無いnoteはno_date_fieldでfix不可 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Preferences/no-date-note.md" $'tags: [x]'

  out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  reason="$(printf '%s' "$out" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/no-date-note.md'][0]
print(c['fixable'], c['skip_reason'])
")"
  assert_eq "fixable=False・skip_reason=no_date_field" "False no_date_field" "$reason"

  rm -rf "$VAULT_HOME"
}

echo "=== 41. --json: 不正な日付形式(fromisoformat失敗)はinvalid_date_formatでfix不可 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Preferences/bad-date-note.md" $'date: not-a-date'

  out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  reason="$(printf '%s' "$out" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/bad-date-note.md'][0]
print(c['fixable'], c['skip_reason'])
")"
  assert_eq "fixable=False・skip_reason=invalid_date_format" "False invalid_date_format" "$reason"

  rm -rf "$VAULT_HOME"
}

echo "=== 42. --json: 未来日時のdate:はfuture_dateでfix不可（誤って未来日付をupdatedへ転記しない） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  future="$(d_date 30)"
  write_note "$V" "Preferences/future-date-note.md" "date: $future"

  out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  reason="$(printf '%s' "$out" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/future-date-note.md'][0]
print(c['fixable'], c['skip_reason'])
")"
  assert_eq "fixable=False・skip_reason=future_date" "False future_date" "$reason"

  rm -rf "$VAULT_HOME"
}

echo "=== 43. --json: date:キーが重複しているnoteはduplicate_date_keyでfix不可（frontmatter異常・どちらが正か機械的に決められない） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  mkdir -p "$V/Preferences"
  printf -- '---\ndate: 2026-01-01\ndate: 2026-02-02\n---\n\n本文\n' > "$V/Preferences/dup-date-note.md"

  out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  reason="$(printf '%s' "$out" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/dup-date-note.md'][0]
print(c['fixable'], c['skip_reason'])
")"
  assert_eq "fixable=False・skip_reason=duplicate_date_key" "False duplicate_date_key" "$reason"

  rm -rf "$VAULT_HOME"
}

echo "=== 43b. --json: FIX候補にはinv-<sha256[:12]>形式の安定IDとsource_sha256（TOCTOU対策用）が含まれる（設計書§2.2/§2.4・maintenance_apply.py未実装向け） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Preferences/fixable-note.md" $'date: 2026-01-01'

  out1="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  info1="$(printf '%s' "$out1" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/fixable-note.md'][0]
print(c['id'])
print(c['source_sha256'])
")"
  id1="$(echo "$info1" | sed -n '1p')"
  sha1="$(echo "$info1" | sed -n '2p')"

  assert_eq "idはinv-プレフィックス+12文字16進" "1" \
    "$(echo "$id1" | grep -qE '^inv-[0-9a-f]{12}$' && echo 1 || echo 0)"
  assert_eq "source_sha256は64文字16進(sha256)" "1" \
    "$(echo "$sha1" | grep -qE '^[0-9a-f]{64}$' && echo 1 || echo 0)"

  # ノートの実際のsha256と一致することを直接検証する（内容ベースIDの根拠）。
  expected_sha="$(python3 -c "import hashlib; print(hashlib.sha256(open('$V/Preferences/fixable-note.md', 'rb').read()).hexdigest())")"
  assert_eq "source_sha256はノート全文の実際のsha256と一致する" "$expected_sha" "$sha1"

  # 同じrelpathなら2回実行しても同じidになる（決定的・連番ではない）。
  out2="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  id2="$(printf '%s' "$out2" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/fixable-note.md'][0]
print(c['id'])
")"
  assert_eq "同一relpathなら再実行しても同じidになる(決定的)" "$id1" "$id2"

  rm -rf "$VAULT_HOME"
}

echo "=== 43c. --json: FIX候補のsource_sha256はノート内容が変わればTOCTOU検知できるよう別の値になる ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Preferences/toctou-note.md" $'date: 2026-01-01'

  out1="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  sha_before="$(printf '%s' "$out1" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/toctou-note.md'][0]
print(c['source_sha256'])
")"

  # ノート本文を書き換える（TOCTOU: Phase1検出後にVaultが変化したケースを模擬）。
  printf -- '---\ndate: 2026-01-01\n---\n\n本文が変わった\n' > "$V/Preferences/toctou-note.md"

  out2="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)"
  sha_after="$(printf '%s' "$out2" | python3 -c "
import json,sys
data = json.load(sys.stdin)
c = [x for x in data['missing_updated_fix_candidates'] if x['relpath'] == 'Preferences/toctou-note.md'][0]
print(c['source_sha256'])
")"

  assert_eq "内容が変わればsource_sha256も変わる(TOCTOU再照合で不一致検知できる)" "1" \
    "$([[ "$sha_before" != "$sha_after" ]] && echo 1 || echo 0)"

  rm -rf "$VAULT_HOME"
}

echo "=== 44. --json: 標準出力はJSON1行のみ（人間向けメッセージは標準エラーへ回る・maintenance_run_step.pyがjson.loads()できる契約） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"

  stdout_out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/tmp/vi-test-stderr.log)"
  stderr_out="$(cat /tmp/vi-test-stderr.log)"
  rc=0
  echo "$stdout_out" | python3 -c "import json,sys; json.load(sys.stdin)" || rc=$?
  assert_eq "標準出力全体が有効なJSONとしてパースできる" "0" "$rc"
  assert_contains "人間向けメッセージは標準エラーに出る" "$stderr_out" "レポート生成:"

  rm -f /tmp/vi-test-stderr.log
  rm -rf "$VAULT_HOME"
}

echo "=== 45. 必読6ファイルのうち1つが欠けてもクラッシュせずwarningとしてレポート§5に載る（tester独立検証で発見・リーダー裁定2026-07-16対応） ==="
{
  # 以前はBOOTSTRAP_FILES内の必読ファイルを無条件でread_text()しており、
  # いずれか1つでも欠けると未処理のFileNotFoundErrorでCLI全体がクラッシュ
  # していた（サブ機・骨格未整備のVault・ファイル名変更直後等で実際に
  # 起こりうる）。claude/hooks/bootstrap-vault.sh側の「存在するファイルだけ
  # 必読リストに載せる」という既存の扱いに揃え、クラッシュさせず「検出のみ」
  # としてレポートへwarning表示する。
  # make_clean_vault はn_issues=0のクリーンな状態を作る（要確認件数への
  # 個別種別の算入テストと同じ土台）。欠落前後でn_issuesが0→1へ増分する
  # ことまで直接確認する（Codexレビュー指摘Minor対応: 「要確認」という
  # 文字列自体は件数に関わらず常にレポート冒頭へ出るため、文字列containsだけ
  # ではn_issuesへの加算漏れを検出できなかった）。
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"

  out_before="$(run_inventory "$VAULT_HOME")"
  n_before="$(extract_n_issues "$out_before")"
  assert_eq "欠落前はn_issues=0(クリーンなVault)" "0" "$n_before"

  rm -f "$V/Preferences/coding-delegation.md"

  rc=0
  out="$(run_inventory "$VAULT_HOME")" || rc=$?
  assert_eq "1ファイル欠落でもクラッシュせずexit 0のまま完走する" "0" "$rc"
  assert_contains "欠落ファイルがwarningとして§5に載る" "$out" "Preferences/coding-delegation.md\` — ⚠️ ファイルが見つかりません"
  assert_contains "残り5ファイルの注入サイズ監視は健在（§5見出し自体は変わらない）" "$out" "## 5. 必読6ファイルの注入サイズ"
  n_after="$(extract_n_issues "$out")"
  assert_eq "欠落後はn_issuesが0→1へ増分する(要確認件数へ正しく加算される)" "1" "$n_after"

  rm -rf "$VAULT_HOME"
}

echo "=== 45b. --json実行でも必読ファイル欠落でクラッシュせずexit 0で有効なJSONを返しn_issuesへ加算される（同上・Codexレビュー指摘Minor対応） ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  rm -f "$V/Knowledge/mistakes.md"

  rc=0
  stdout_out="$(HOME="$VAULT_HOME" python3 "$SCRIPT" --json 2>/dev/null)" || rc=$?
  assert_eq "必読ファイル欠落＋--jsonでもexit 0のまま完走する" "0" "$rc"
  parse_rc=0
  echo "$stdout_out" | python3 -c "import json,sys; json.load(sys.stdin)" || parse_rc=$?
  assert_eq "標準出力は引き続き有効なJSONとしてパースできる" "0" "$parse_rc"
  json_n_issues="$(echo "$stdout_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['n_issues'])")"
  assert_eq "JSON payloadのn_issuesにも欠落1件が加算される(クリーンなVault起点なので1になる)" "1" "$json_n_issues"

  rm -rf "$VAULT_HOME"
}

echo "=== 46. Vault内に壊れたsymlink(.md)があってもクラッシュせず「読込に失敗したノート」として警告表示する（リーダー裁定2026-07-16: 出荷パイプラインのクラッシュ級は今直す・読込失敗は警告表示を採用） ==="
{
  # 全Vault走査（.mdファイル全般の読込ループ）にも、BOOTSTRAP_FILESと同型の
  # クラッシュ余地がCodexレビューで指摘され、リーダー裁定により水平展開で
  # 修正した。壊れたsymlink（リンク先が存在しない）は`p.is_file()`がFalseを
  # 返すため検知できる。
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  ln -s "$V/Knowledge/does-not-exist.md" "$V/Knowledge/broken-link.md"

  rc=0
  out="$(run_inventory "$VAULT_HOME")" || rc=$?
  assert_eq "壊れたsymlinkがあってもクラッシュせずexit 0のまま完走する" "0" "$rc"
  assert_contains "壊れたsymlinkが「読込に失敗したノート」として§0に載る" "$out" "Knowledge/broken-link.md\` —"
  n_after="$(extract_n_issues "$out")"
  assert_eq "壊れたsymlinkの検出もn_issuesへ1件加算される" "1" "$n_after"

  rm -rf "$VAULT_HOME"
}

echo "=== 46b. 壊れたsymlinkへのwikilinkは§3リンク切れとしても検出される（stemsへ登録しない設計・Codexレビュー指摘Minor対応） ==="
{
  # 修正前は存在チェックより先に無条件でstemsへ登録していたため、壊れた
  # symlinkや`.md`名ディレクトリを指すwikilinkが「リンク先は存在する」と
  # 誤判定され、§3リンク切れ検出から漏れる（過少検出）欠陥があった。
  # is_file()==Trueの場合のみstemsへ登録するよう修正したことで、§0（読込
  # 失敗）と§3（リンク切れ）の両方で正しく検出されることを確認する。
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  ln -s "$V/Knowledge/does-not-exist.md" "$V/Knowledge/broken-link.md"
  write_note "$V" "Knowledge/linker.md" "date: 2026-01-01" "本文 [[broken-link]] への言及。"

  rc=0
  out="$(run_inventory "$VAULT_HOME")" || rc=$?
  assert_eq "壊れたsymlinkへのwikilinkがあってもクラッシュせずexit 0のまま完走する" "0" "$rc"
  assert_contains "壊れたsymlink自体は§0(読込に失敗したノート)に載る" "$out" "Knowledge/broken-link.md\` —"
  assert_contains "壊れたsymlinkを指すwikilinkは§3リンク切れとしても検出される(stemsに残っていない)" \
    "$out" "Knowledge/linker.md\` → \`[[broken-link]]\`"

  rm -rf "$VAULT_HOME"
}

echo "=== 47. Vault内に\`.md\`という名前のディレクトリがあってもクラッシュせず「読込に失敗したノート」として警告表示する（同上のリーダー裁定対応） ==="
{
  # `.md`拡張子だが実体がディレクトリの場合、read_text()はIsADirectoryError
  # を送出する。is_file()がFalseを返すため、こちらもBOOTSTRAP_FILESと同じ
  # 存在チェックだけで検知でき、try/exceptまで到達しない。
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  mkdir -p "$V/Knowledge/weird-dir.md"
  echo "not a note" > "$V/Knowledge/weird-dir.md/inner.txt"

  rc=0
  out="$(run_inventory "$VAULT_HOME")" || rc=$?
  assert_eq "\`.md\`名ディレクトリがあってもクラッシュせずexit 0のまま完走する" "0" "$rc"
  assert_contains "\`.md\`名ディレクトリが「読込に失敗したノート」として§0に載る" "$out" "Knowledge/weird-dir.md\` —"
  n_after="$(extract_n_issues "$out")"
  assert_eq "\`.md\`名ディレクトリの検出もn_issuesへ1件加算される" "1" "$n_after"

  rm -rf "$VAULT_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
