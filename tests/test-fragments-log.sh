#!/usr/bin/env bash
# scripts/vault-agents/fragments_log.py のユニットテスト（2026-07-16簡素化・
# Fragments週次昇格候補検出への縮小＝設計書§3.1）。
#
# 実Vault($HOME/Data/obsidian)には一切依存しない。VAULT_ROOT環境変数で
# 毎回ダミーのfixtureディレクトリへ差し替えて実行する。
#
# 実行方法: bash tests/test-fragments-log.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/fragments_log.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

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

# fragments_log.py はVAULT/FRAGMENTS定数を直接参照するため、モジュールとして
# importしテスト実行中だけ書き換える小さなPythonラッパーで呼び出す
# （argparseのCLI引数はそのまま素通しする）。
run_fragments_log() {
  local vault="$1"; shift
  python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import pathlib
import fragments_log as fl
fl.VAULT = pathlib.Path('$vault')
fl.FRAGMENTS = fl.VAULT / 'Fragments'
sys.argv = ['fragments_log.py'] + sys.argv[1:]
fl.main()
" "$@"
}

write_fragment_day() {
  # write_fragment_day <path> <content>
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

d_date() {
  # 今日からn日オフセットした日付をYYYY-MM-DD形式で返す（macOS date -v準拠）。
  local n="$1"
  [[ "$n" != -* ]] && n="+$n"
  date -v"${n}d" +%Y-%m-%d 2>/dev/null || date -d "${n} days" +%Y-%m-%d
}

echo "=== 1. --sinceは必須オプション（未指定はexit 2） ==="
{
  rc=0
  out="$(python3 "$SCRIPT" 2>&1)" || rc=$?
  assert_eq "exit code 2（argparse必須引数エラー）" "2" "$rc"
  assert_contains "--sinceが必須である旨のエラーが出る" "$out" "--since"
}

echo "=== 2. --json: 未処理(status生)のエントリのみをfragmentsに含める ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" \
"## 10:00 未処理タイトル
本文A

## 11:00 処理済みタイトル
status: promoted
本文B"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  title0="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fragments"][0]["heading_or_bullet"])')"
  assert_eq "候補は1件のみ(処理済みは除外)" "1" "$n_frag"
  assert_contains "候補は未処理タイトル" "$title0" "未処理タイトル"

  rm -rf "$VAULT_DIR"
}

echo "=== 3. --json: 箇条書き型のエントリも検出する ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" \
'- **箇条書きタイトル**：本文の内容'

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  assert_eq "箇条書き型も1件検出される" "1" "$n_frag"

  rm -rf "$VAULT_DIR"
}

echo "=== 4. --json: 安定ID(frag-<sha256(source_relpath+見出し)[:12]>)が決定的に生成される ==="
{
  VAULT_DIR="$(mktemp -d)"
  DAY="$(d_date 0)"
  write_fragment_day "$VAULT_DIR/Fragments/$DAY.md" "## 10:00 決定的IDテスト
本文"

  out1="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  out2="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  id1="$(printf '%s' "$out1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fragments"][0]["id"])')"
  id2="$(printf '%s' "$out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fragments"][0]["id"])')"
  assert_eq "同一内容なら同一IDが2回とも生成される（決定的）" "$id1" "$id2"
  [[ "$id1" == frag-* ]] && pass "IDはfrag-プレフィックスを持つ" || fail_case "IDはfrag-プレフィックスを持つ (実際: $id1)"

  rm -rf "$VAULT_DIR"
}

echo "=== 5. --json: source_sha256はソースファイル内容のSHA-256と一致する ==="
{
  VAULT_DIR="$(mktemp -d)"
  DAY="$(d_date 0)"
  write_fragment_day "$VAULT_DIR/Fragments/$DAY.md" "## 10:00 SHA検証
本文"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  sha_reported="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fragments"][0]["source_sha256"])')"
  sha_actual="$(shasum -a 256 "$VAULT_DIR/Fragments/$DAY.md" | cut -d' ' -f1)"
  assert_eq "source_sha256がファイル実体のSHA-256と一致する" "$sha_actual" "$sha_reported"

  rm -rf "$VAULT_DIR"
}

echo "=== 6. --json: サイズ上限(2000字)超過のエントリはtruncatedへ回りfragmentsから除外される ==="
{
  VAULT_DIR="$(mktemp -d)"
  BIG_BODY="$(python3 -c 'print("あ" * 2100)')"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" "## 10:00 巨大エントリ
$BIG_BODY"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -10)" --json)"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  n_trunc="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["truncated"]))')"
  trunc_marker="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["truncated"][0]["non_actionable"])')"
  assert_eq "fragmentsには含まれない" "0" "$n_frag"
  assert_eq "truncatedに1件回る" "1" "$n_trunc"
  assert_eq "non_actionable=truncatedが付与される" "truncated" "$trunc_marker"

  rm -rf "$VAULT_DIR"
}

echo "=== 7. --since: 未来日時は7日前へフォールバックしfactログを出すが中断しない ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" "## 10:00 タイトル
本文"

  future="$(d_date 30)"
  rc=0
  out="$(run_fragments_log "$VAULT_DIR" --since "$future" --json 2>&1)" || rc=$?
  assert_eq "exit code 0（中断しない）" "0" "$rc"
  assert_contains "フォールバックのFACTログが出る" "$out" "未来日時"
  since_val="$(printf '%s' "$out" | grep -o '"since": "[^"]*"' | head -1 | cut -d'"' -f4)"
  assert_eq "sinceは7日前にフォールバックされる" "$(d_date -7)" "$since_val"

  rm -rf "$VAULT_DIR"
}

echo "=== 8. --since: 30日超過も7日前へフォールバックする ==="
{
  VAULT_DIR="$(mktemp -d)"
  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -60)" --json 2>&1)"
  assert_contains "30日超過のFACTログが出る" "$out" "30日超過"

  rm -rf "$VAULT_DIR"
}

echo "=== 9. --since: 破損値(パース不能)も7日前へフォールバックする ==="
{
  VAULT_DIR="$(mktemp -d)"
  out="$(run_fragments_log "$VAULT_DIR" --since "not-a-date" --json 2>&1)"
  rc=$?
  assert_eq "exit code 0（中断しない）" "0" "$rc"
  assert_contains "パース失敗のFACTログが出る" "$out" "パース失敗"

  rm -rf "$VAULT_DIR"
}

echo "=== 10. --since: 有効な範囲内の値はそのまま使われる(フォールバックしない) ==="
{
  VAULT_DIR="$(mktemp -d)"
  valid_since="$(d_date -5)"
  out="$(run_fragments_log "$VAULT_DIR" --since "$valid_since" --json 2>&1)"
  assert_not_contains "フォールバックのFACTログは出ない" "$out" "FACT: --sinceを7日前へ"
  since_val="$(printf '%s' "$out" | grep -o '"since": "[^"]*"' | head -1 | cut -d'"' -f4)"
  assert_eq "sinceは指定値がそのまま使われる" "$valid_since" "$since_val"

  rm -rf "$VAULT_DIR"
}

echo "=== 11. Fragmentsフォルダが存在しなくてもクラッシュしない(exit 0・候補0件) ==="
{
  VAULT_DIR="$(mktemp -d)"
  rc=0
  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -5)" --json)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  assert_eq "候補0件" "0" "$n_frag"

  rm -rf "$VAULT_DIR"
}

echo "=== 12. --sinceより前・untilより後(未来)の日次ファイルは対象外 ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date -20).md" "## 10:00 範囲外(古い)
本文"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" "## 10:00 範囲内
本文"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -5)" --json)"
  n_frag="$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["fragments"]))')"
  title="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fragments"][0]["heading_or_bullet"])')"
  assert_eq "範囲内の1件のみ検出される" "1" "$n_frag"
  assert_contains "検出されるのは範囲内のエントリ" "$title" "範囲内"

  rm -rf "$VAULT_DIR"
}

echo "=== 13. --json無し: 人間向けサマリを標準出力へ返す（後方互換の簡易確認） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" "## 10:00 タイトル
本文"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -5)")"
  assert_contains "対象期間のサマリ行が出る" "$out" "対象期間:"
  assert_contains "候補IDが表示される" "$out" "frag-"
}

echo "=== 14. 読み取れないFragmentsファイルがあってもfail-openでスキップしfactログを残す ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_fragment_day "$VAULT_DIR/Fragments/$(d_date 0).md" "## 10:00 読めるタイトル
本文"
  LOCKED="$VAULT_DIR/Fragments/$(d_date -1).md"
  write_fragment_day "$LOCKED" "## 10:00 読めないタイトル
本文"
  chmod 000 "$LOCKED"

  out="$(run_fragments_log "$VAULT_DIR" --since "$(d_date -5)" --json 2>&1)"
  rc=$?
  chmod 644 "$LOCKED"
  n_frag="$(printf '%s' "$out" | grep -o '"fragments"' | wc -l | tr -d ' ')"
  assert_eq "exit code 0（読み取り不可でも中断しない）" "0" "$rc"
  assert_contains "読み取れなかった旨のFACTログが出る" "$out" "読み取れなかった"

  rm -rf "$VAULT_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
