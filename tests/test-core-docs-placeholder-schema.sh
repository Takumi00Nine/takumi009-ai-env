#!/usr/bin/env bash
# vault-public/Preferences/core-conduct.md・core-workflow.md 内の {{…}} プレース
# ホルダ集合が、最小能力表7キー（§3.3.0）の集合に含まれることを機械判定する
# 静的テスト（2026-08-30 工程横断レビュー指摘・MAJOR-3支援）。
#
# ⚠️ コア本文側の修正はcore-docs担当。このテストは「本文がキー集合と一致して
# いること」を検証するだけで、本文自体は直さない。本文とスキーマが食い違って
# いる間はこのテストが失敗し続けるのが正しい挙動（未解決参照を機械的に検知する
# のがこのテストの目的そのもの）。
#
# 追加（2026-08-30 Codex 2巡目差し戻し・MINOR-D対応）: 「必読ファイル集合」の
# 3重管理（claude/hooks/bootstrap-vault.shのFILES配列／scripts/vault-agents/
# keyword_recall_helper.pyのEXCLUDE_RELPATHS／scripts/vault-agents/
# vault_inventory.pyのBOOTSTRAP_FILES）が一致しているかを検証する静的テストも
# 本ファイルに同居させる（registry・版管理は作らない・3ファイルの現物を都度
# 静的抽出して突合するだけ）。
#
# 実行方法: bash tests/test-core-docs-placeholder-schema.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# 最小能力表7キー（§3.3.0）。ハードコードで再列挙せず、claude/hooks/
# bootstrap-vault.sh の LOCAL_PROFILE_KNOWN_KEYS（正本）を実行時ソースとして
# 参照する（2026-08-30 Codex 2巡目差し戻し・MINOR-D対応: 従来はここに独自の
# 配列を再列挙しており、正本が増減してもこのテストが追随せず気づけない
# 3重管理の一角になっていた）。BOOTSTRAP_PRINT_KNOWN_KEYS_ONLY=1は
# bootstrap-vault.sh側のテスト専用早期exitフック（stdin読込・ヘルス行計算
# 等の本処理には進まない）。
BOOTSTRAP_VAULT_SH="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"
KNOWN_KEYS=()
while IFS= read -r k; do
  [ -n "$k" ] && KNOWN_KEYS+=("$k")
done < <(BOOTSTRAP_PRINT_KNOWN_KEYS_ONLY=1 bash "$BOOTSTRAP_VAULT_SH" </dev/null)
if [ "${#KNOWN_KEYS[@]}" -eq 0 ]; then
  echo "FATAL: bootstrap-vault.sh から最小能力表キー集合を取得できませんでした（BOOTSTRAP_PRINT_KNOWN_KEYS_ONLY フックの破損の可能性）" >&2
  exit 1
fi

is_known_key() {
  local target="$1" k
  for k in "${KNOWN_KEYS[@]}"; do
    [ "$k" = "$target" ] && return 0
  done
  return 1
}

# extract_placeholders <file> — {{...}} の中身（1行1件）を重複除去して出す。
# ⚠️ 文字クラスを英数字・アンダースコア・ドットに限定せず「}を含まない
# 任意の文字列」にする（Codex二次レビュー指摘・Minor対応: 限定した文字クラスだと
# 例えば{{user-call-channel}}のようなハイフン入りの未知形式プレースホルダが
# 抽出対象から漏れ、is_known_key()の判定にすら回らず静かに見逃されていた。
# 「}を含まない」まで広げれば、どんな綴りの未知プレースホルダも必ず拾って
# is_known_key()の判定にかけられる＝未知形式ほど検知したいという本テストの
# 目的に合う）。
extract_placeholders() {
  grep -oE '\{\{[^}]+\}\}' "$1" 2>/dev/null \
    | sed -E 's/^\{\{//; s/\}\}$//' \
    | sort -u
}

check_file() {
  # bash 3.2（macOS既定）は同一local文中で直前に代入した変数を続く代入の
  # 右辺で参照するとset -u下でunbound variableになる既知の癖があるため、
  # 各代入を別行に分ける（本リポジトリの既存作法）。
  local relpath="$1"
  local abspath="$TESTS_DIR/../vault-public/$relpath"
  if [ ! -f "$abspath" ]; then
    fail_case "$relpath が見つからない（vault-public未export・checkout破損等の可能性）"
    return
  fi
  local placeholders
  # `|| true`はset -e対策（Codex二次レビュー指摘・Minor対応）: grepの
  # マッチ0件はexit 1を返し、pipefail下ではパイプライン全体がその終了
  # コードを引き継ぐ。単純な代入文でのコマンド置換失敗はset -e下では
  # スクリプト全体を即終了させてしまうため、直後のif分岐（0件時のfail_case）
  # へ到達する前に落ちてしまっていた。
  placeholders="$(extract_placeholders "$abspath")" || true
  if [ -z "$placeholders" ]; then
    fail_case "$relpath に {{…}} プレースホルダが1件も見つからない（想定外・抽出正規表現の劣化の可能性）"
    return
  fi
  local unknown=0
  while IFS= read -r ph; do
    [ -z "$ph" ] && continue
    if is_known_key "$ph"; then
      pass "$relpath: {{${ph}}} は最小能力表7キーに含まれる"
    else
      fail_case "$relpath: {{${ph}}} は最小能力表7キーに含まれない（未解決参照。§3.3.0のキー集合＝${KNOWN_KEYS[*]}）"
      unknown=$((unknown + 1))
    fi
  done <<EOF
$placeholders
EOF
}

echo "=== 1. Preferences/core-conduct.md の {{…}} プレースホルダが最小能力表7キーに含まれる ==="
check_file "Preferences/core-conduct.md"

echo "=== 2. Preferences/core-workflow.md の {{…}} プレースホルダが最小能力表7キーに含まれる ==="
check_file "Preferences/core-workflow.md"

echo "=== 3. 回帰: プレースホルダが0件のファイルでもset -e下でスクリプト全体が落ちずfail_caseまで到達する（Codex二次レビュー指摘・Minor対応） ==="
{
  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE_FILE="$FIXTURE_DIR/no-placeholder.md"
  echo "プレースホルダを1件も含まない本文" > "$FIXTURE_FILE"

  # check_file()相当のロジックを直接再現する（`|| true`が無いとextract_
  # placeholders()自体がgrepの0件時exit 1を返し、set -e下でスクリプト全体が
  # ここで即終了してしまう＝このテスト自身も同じ落とし穴を踏まないよう
  # `|| true`を付ける）。
  placeholders_direct="$(extract_placeholders "$FIXTURE_FILE")" || true
  if [ -z "$placeholders_direct" ]; then
    pass "0件のプレースホルダでもスクリプトが落ちずに空判定へ到達する"
  else
    fail_case "0件のはずなのに何か抽出された（想定外）"
  fi

  rm -rf "$FIXTURE_DIR"
}

echo "=== 4. 回帰: ハイフン等を含む未知形式のプレースホルダも抽出対象になる（Codex二次レビュー指摘・Minor対応: 従来の文字クラス限定だと静かに見逃されていた） ==="
{
  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE_FILE="$FIXTURE_DIR/hyphenated.md"
  echo '本文中に {{user-call-channel}} という未知形式のプレースホルダがある。' > "$FIXTURE_FILE"

  extracted="$(extract_placeholders "$FIXTURE_FILE")"
  assert_contains_local() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
      pass "$desc"
    else
      fail_case "$desc (含まれない: \"$needle\")"
    fi
  }
  assert_contains_local "ハイフン入りプレースホルダが抽出される" "$extracted" "user-call-channel"

  rm -rf "$FIXTURE_DIR"
}

echo "=== 5. 必読ファイル集合の3重管理（bootstrap FILES／keyword_recall_helper EXCLUDE_RELPATHS／vault_inventory BOOTSTRAP_FILES）が集合として一致する（2026-08-30 Codex 2巡目差し戻し・MINOR-D対応。registry・版管理は作らず3ファイルの現物を静的抽出して突合するだけ） ==="
{
  KEYWORD_RECALL_PY="$REPO_ROOT/scripts/vault-agents/keyword_recall_helper.py"
  VAULT_INVENTORY_PY="$REPO_ROOT/scripts/vault-agents/vault_inventory.py"

  # bootstrap-vault.sh・keyword_recall_helper.py・vault_inventory.pyの現物
  # テキストを静的抽出するだけ（実行はしない＝python3コード自体はこのテストの
  # 一部として動くが、対象3ファイルはimport/sourceせずreadでテキストとして
  # 読むだけ）。keyword_recall_helper.pyのEXCLUDE_RELPATHSは仕様上
  # "Knowledge/mistakes.md"を1件多く含む（H19未決の除外維持・MAJOR-4で
  # 既知の差分として明文化済み）ため、その1件を除いた残りがFILES／
  # BOOTSTRAP_FILESと完全一致することを検証する。
  RESULT="$(python3 - "$BOOTSTRAP_VAULT_SH" "$KEYWORD_RECALL_PY" "$VAULT_INVENTORY_PY" <<'PYEOF'
import re
import sys

bootstrap_path, recall_path, inventory_path = sys.argv[1:4]


def extract(text, pattern):
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return None
    return set(re.findall(r'"([^"]+)"', m.group(1)))


bootstrap_text = open(bootstrap_path, encoding='utf-8').read()
recall_text = open(recall_path, encoding='utf-8').read()
inventory_text = open(inventory_path, encoding='utf-8').read()

files_set = extract(bootstrap_text, r'\n\s*FILES=\((.*?)\n\s*\)')
exclude_set = extract(recall_text, r'\nEXCLUDE_RELPATHS\s*=\s*\((.*?)\n\)')
bootstrap_files_set = extract(inventory_text, r'\nBOOTSTRAP_FILES\s*=\s*\[(.*?)\n\]')

results = []

if files_set is None:
    results.append(('FAIL', 'bootstrap-vault.shからFILES配列を抽出できない（正規表現の劣化・変数名変更の可能性）'))
if bootstrap_files_set is None:
    results.append(('FAIL', 'vault_inventory.pyからBOOTSTRAP_FILESを抽出できない（正規表現の劣化・変数名変更の可能性）'))
if exclude_set is None:
    results.append(('FAIL', 'keyword_recall_helper.pyからEXCLUDE_RELPATHSを抽出できない（正規表現の劣化・変数名変更の可能性）'))

if files_set is not None and bootstrap_files_set is not None:
    if files_set == bootstrap_files_set:
        results.append(('PASS', 'bootstrap-vault.shのFILESとvault_inventory.pyのBOOTSTRAP_FILESが集合として完全一致する'))
    else:
        only_files = files_set - bootstrap_files_set
        only_inv = bootstrap_files_set - files_set
        results.append(('FAIL', f'FILESとBOOTSTRAP_FILESが不一致（FILESのみ: {sorted(only_files)} / BOOTSTRAP_FILESのみ: {sorted(only_inv)}）'))

if files_set is not None and exclude_set is not None:
    known_extra = {'Knowledge/mistakes.md'}
    exclude_minus_known = exclude_set - known_extra
    if exclude_minus_known == files_set:
        results.append(('PASS', 'EXCLUDE_RELPATHSから既知の追加分(Knowledge/mistakes.md)を除いた残りがFILESと集合として完全一致する'))
    else:
        only_exclude = exclude_minus_known - files_set
        only_files2 = files_set - exclude_minus_known
        results.append(('FAIL', f'EXCLUDE_RELPATHS(既知分除く)とFILESが不一致（EXCLUDE_RELPATHSのみ: {sorted(only_exclude)} / FILESのみ: {sorted(only_files2)}）'))
    if 'Knowledge/mistakes.md' not in exclude_set:
        results.append(('FAIL', 'EXCLUDE_RELPATHSにKnowledge/mistakes.mdが含まれない（H19未決の除外維持方針からの逸脱の可能性）'))

for status, desc in results:
    print(f'{status}\t{desc}')
PYEOF
)"

  if [ -z "$RESULT" ]; then
    fail_case "3集合突合の静的テスト自体が何も出力しなかった（想定外）"
  else
    while IFS=$'\t' read -r status desc; do
      [ -z "$status" ] && continue
      if [ "$status" = "PASS" ]; then
        pass "$desc"
      else
        fail_case "$desc"
      fi
    done <<< "$RESULT"
  fi
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
