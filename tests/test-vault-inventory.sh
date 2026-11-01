#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ai-brain/executor/vault_inventory.py"

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

d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%Y-%m-%dT12:00:00; }

make_base_vault() {
  local vault="$1"
  # Personal/はvault_inventory.pyのBOOTSTRAP_FILES（§5注入サイズ監視）に元々
  # 含まれていた（bootstrap-vault.shの必読ファイルと同期）が、このfixtureヘルパー
  # には反映されておらず§5がFileNotFoundErrorで落ちる既存の隙間があった。
  # 2026-07-11決定（[[Decisions/2026-07-11-personal-recall-scope]]）でPersonal/が
  # 想起対象フォルダにも加わったタイミングで合わせて解消する（私の担当外の既存問題
  # だが、Personal関連テストを追加するために本ヘルパーの修正が前提となるため対応）。
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Decisions" "$vault/Projects" \
           "$vault/Personal" "$vault/Fragments"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/vault-operation.md" "Personal/profile-personal.md"; do
    printf -- '---\ndate: 2026-01-01\n---\n\ndummy\n' > "$vault/$f"
  done
  for d in Knowledge Preferences Decisions Projects Personal; do
    printf -- '---\ndate: 2026-01-01\ntags: [meta, index]\n---\n\n# %s\n' "$d" > "$vault/$d/README.md"
  done
}

make_clean_vault() {
  local vault="$1"
  make_base_vault "$vault"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Preferences/vault-operation.md" "Personal/profile-personal.md"; do
    printf -- '---\ndate: 2026-01-01\nupdated: 2026-01-01\naliases: [clean-vault-alias-%s]\n---\n\ndummy\n' \
      "$(basename "$f" .md)" > "$vault/$f"
  done
  printf -- '---\ndate: %s\n---\n\n## dummy entry\n' "$(date +%F)" > "$vault/Fragments/$(date +%F).md"
}

extract_actionable() {
  echo "$1" | grep -oE '要確認 [0-9]+ 件' | head -1 | grep -oE '[0-9]+'
}

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

run_inventory() {
  local vault_home="$1"
  HOME="$vault_home" python3 "$SCRIPT" >/dev/null
  cat "$(ls "$vault_home/.claude/logs/vault-inventory"/20*.md | sort | tail -1)"
}

echo "=== aliasesの欠落を検出する ==="
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

echo "=== ログ不在では未読を断定しない ==="
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

echo "=== 蓄積済みログの未読判定と提示無視率 ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_base_vault "$V"
  write_note "$V" "Knowledge/old-unread.md" $'date: 2026-01-01\naliases:\n  - old-unread-alias'
  write_note "$V" "Knowledge/recent-read.md" $'date: 2026-01-01\naliases:\n  - recent-read-alias'
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
  assert_not_contains "5日前に読まれたノートは対象外" "$out" "Knowledge/recent-read.md\`（"
  assert_contains "提示無視率ワーストにrecalled-oftenが読まれた率0%で出る" \
    "$out" "Knowledge/recalled-often.md\` — 提示3回中 読まれた率0%"

  rm -rf "$VAULT_HOME"
}

echo "=== 読めないノートがあっても完走する ==="
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
  n_after="$(extract_actionable "$out")"
  assert_eq "壊れたsymlinkの検出もactionableへ1件加算される" "1" "$n_after"

  rm -rf "$VAULT_HOME"
}

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
