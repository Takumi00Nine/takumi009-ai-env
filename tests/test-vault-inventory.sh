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

echo "=== 旧ログと aliases を検査材料にしない ==="
{
  VAULT_HOME="$(mktemp -d)"
  V="$VAULT_HOME/Data/obsidian"
  make_clean_vault "$V"
  write_note "$V" "Knowledge/no-alias.md" "date: 2026-01-01"
  mkdir -p "$VAULT_HOME/.claude/logs"
  printf '2000-01-01T00:00:00Z\tsess\tKnowledge/no-alias.md\n' > "$VAULT_HOME/.claude/logs/vault-reads.tsv"
  cp "$VAULT_HOME/.claude/logs/vault-reads.tsv" "$VAULT_HOME/.claude/logs/vault-recall.tsv"
  out="$(run_inventory "$VAULT_HOME")"
  assert_not_contains "aliases 欠落を表示しない" "$out" "aliases が無いノート"
  assert_not_contains "旧ログが残っても未読を表示しない" "$out" "未読ノート"
  assert_not_contains "旧ログが残っても提示無視率を表示しない" "$out" "提示無視率"
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
