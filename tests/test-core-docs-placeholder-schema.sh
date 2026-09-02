#!/usr/bin/env bash
# vault-public/Preferences/core-conduct.md・core-workflow.md 内の {{…}} プレース
# ホルダ集合が、最小能力表7キー（§3.3.0）、または設計上認められた文書参照名
# （DOC_REFERENCE_KNOWN_KEYS。2026-09-02追加・配役表解凍-設計-2026-09-01.md
# §7）の集合に含まれることを機械判定する静的テスト（2026-08-30 工程横断
# レビュー指摘・MAJOR-3支援）。
#
# ⚠️ コア本文側の修正はcore-docs担当。このテストは「本文中の参照が既知の
# 参照集合と一致していること」を検証するだけで、本文自体は直さない。本文と
# 参照集合が食い違っている間はこのテストが失敗し続けるのが正しい挙動
# （未解決参照を機械的に検知するのがこのテストの目的そのもの）。
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

# セクション6・7（配役表解凍・担当D追加分）で共有するヘルパー。
# install-main.shのextract_profile_schema_block()関数だけをsedで静的抽出して
# evalする（全体sourceによる実インストール処理の副作用を避けるため）。
# 一度evalに成功すれば以後は再抽出せず既存の関数定義を再利用する（declare -Fで
# 判定。セクション7から呼んでもセクション6の定義がそのまま使える）。
# 戻り値0=関数が使える状態／非0=抽出失敗（呼び出し側でfail_caseすること）。
ensure_extract_profile_schema_block_fn() {
  if declare -F extract_profile_schema_block >/dev/null 2>&1; then
    return 0
  fi
  local fn_src
  fn_src="$(sed -n '/^extract_profile_schema_block() {/,/^}/p' "$REPO_ROOT/scripts/install-main.sh")" || return 1
  [ -n "$fn_src" ] || return 1
  eval "$fn_src"
  declare -F extract_profile_schema_block >/dev/null 2>&1
}

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

# v2配役表解凍で新規に正当化された参照名（2026-09-02追加）。プロファイル
# YAMLのキー名ではなく、コア本文が配役表という概念そのものを指す散文上の
# 参照であるため、LOCAL_PROFILE_KNOWN_KEYS（実プロファイルのfrontmatterキー
# 集合・resolve_local_profile_v1()のT4/T5判定でも使われる正本）へは混ぜず、
# 別カテゴリの許可リストとしてここに明示する（設計書
# 配役表解凍-設計-2026-09-01.md §7 冒頭注記差分「採用の有無も配役も
# {{配役表}} を見る」で規定済み。同じ行が「表を統合したので {{採用表}} と
# いう参照名は作らない」とも明記しているため、{{採用表}} はこのリストに
# 加えない＝Vault文言側の懸念は別途リーダーへ報告）。
DOC_REFERENCE_KNOWN_KEYS=(
  "配役表"
)

is_known_key() {
  local target="$1" k
  for k in "${KNOWN_KEYS[@]}" "${DOC_REFERENCE_KNOWN_KEYS[@]}"; do
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
      pass "$relpath: {{${ph}}} は最小能力表7キー、または配役表解凍で正当化された参照名に含まれる"
    else
      fail_case "$relpath: {{${ph}}} は既知の参照名に含まれない（未解決参照。最小能力表7キー＝${KNOWN_KEYS[*]}／配役表解凍で正当化された参照名＝${DOC_REFERENCE_KNOWN_KEYS[*]}）"
      unknown=$((unknown + 1))
    fi
  done <<EOF
$placeholders
EOF
}

echo "=== 1. Preferences/core-conduct.md の {{…}} プレースホルダが最小能力表7キー、または設計上認められた文書参照名に含まれる ==="
check_file "Preferences/core-conduct.md"

echo "=== 2. Preferences/core-workflow.md の {{…}} プレースホルダが最小能力表7キー、または設計上認められた文書参照名に含まれる ==="
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

echo "=== 6. 静的（配役表解凍・担当D）: vault-public/Preferences/profile-sample.md の \`\`\`yaml ブロックが scripts/install-main.sh の extract_profile_schema_block() で抽出できる（設計書§10「静的」①・4.5） ==="
{
  PROFILE_SAMPLE="$REPO_ROOT/vault-public/Preferences/profile-sample.md"

  # install-main.sh全体をsourceすると実インストール処理が走ってしまうため、
  # extract_profile_schema_block()関数の定義部分だけを静的抽出して使う
  # （関数は`^extract_profile_schema_block() {`で始まり`^}`で終わる単純な形。
  # 対象関数内に行頭"}"の入れ子は無い＝この抽出方法で安全に切り出せる。
  # 抽出・eval自体の失敗は共有ヘルパーensure_extract_profile_schema_block_fn()
  # 内で吸収し、戻り値でfail_caseへ倒せるようにする＝Codex一次レビュー指摘・
  # Minor対応）。
  if ! ensure_extract_profile_schema_block_fn; then
    fail_case "install-main.shからextract_profile_schema_block()関数を抽出できない（関数名変更・削除の可能性）"
  else
    EXTRACT_OUT=""
    extract_rc=0
    if EXTRACT_OUT="$(extract_profile_schema_block "$PROFILE_SAMPLE" 2>&1)"; then
      extract_rc=0
    else
      extract_rc=$?
    fi
    if [ "$extract_rc" -ne 0 ]; then
      fail_case "profile-sample.mdから\`\`\`yamlブロックを抽出できない（詳細: ${EXTRACT_OUT}）"
    else
      pass "extract_profile_schema_block()がprofile-sample.mdからブロックを抽出できる"
      if [[ "$(printf '%s\n' "$EXTRACT_OUT" | head -1)" == "---" ]]; then
        pass "抽出したブロックの先頭行が---（installerが読む雛形フォーマット）"
      else
        fail_case "抽出したブロックの先頭行が---でない（installerの雛形フォーマットと不一致）"
      fi
      if printf '%s\n' "$EXTRACT_OUT" | grep -q '^role\.leader:'; then
        pass "抽出したブロックにrole.leader行が含まれる（配役表v2の必須配役行）"
      else
        fail_case "抽出したブロックにrole.leader行が含まれない"
      fi
      if printf '%s\n' "$EXTRACT_OUT" | grep -q '^schema_version:'; then
        pass "抽出したブロックにschema_version行が含まれる"
      else
        fail_case "抽出したブロックにschema_version行が含まれない"
      fi
    fi
  fi
}

echo "=== 7. 静的（配役表解凍・担当D）: 固定キー集合＋動的プレフィックス2種＋期待版がprofile-sample.mdとprofile_resolve.py（known-keys／print-schema-version）で一致する（設計書§10「静的」②・§3.4・profile-resolve-contract-2026-09-01.md§7） ==="
{
  PROFILE_RESOLVE_PY="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
  PROFILE_SAMPLE="$REPO_ROOT/vault-public/Preferences/profile-sample.md"

  if [ ! -f "$PROFILE_RESOLVE_PY" ]; then
    # 担当Aの成果物（claude/hooks/lib/profile_resolve.py）が本ブランチへ未着地の
    # 間は、契約（profile-resolve-contract-2026-09-01.md）どおりにテストだけを
    # 先に書いておき、lib着地後にこのテストを再実行して結合確認する運用
    # （リーダー指示・2026-09-01）。したがってこの分岐に入っている間のNGは
    # このテスト自体の不具合ではなく「担当A成果物の未着地」を示す。
    fail_case "claude/hooks/lib/profile_resolve.py が未配置のため known-keys/print-schema-version との一致を検証できない（担当A成果物の未着地待ち・契約＝profile-resolve-contract-2026-09-01.md §7。着地後に本テストを再実行して結合確認すること）"
  elif ! ensure_extract_profile_schema_block_fn; then
    fail_case "install-main.shからextract_profile_schema_block()関数を抽出できない（セクション6と同一失敗のはず＝想定外）"
  else
    # `VAR="$(cmd)"`単独（`||`無し）はset -e下でcmdが非0を返すと即座にスクリプト
    # 全体を終了させてしまう（Codex一次レビュー指摘・Major対応）。以下すべての
    # コマンド置換をif/elseで包み、rcを明示的に取り出す形に統一する。
    known_keys_rc=0
    if KNOWN_KEYS_OUT="$(python3 "$PROFILE_RESOLVE_PY" known-keys 2>&1)"; then
      known_keys_rc=0
    else
      known_keys_rc=$?
    fi
    if [ "$known_keys_rc" -ne 0 ]; then
      fail_case "profile_resolve.py known-keys が非0終了した（詳細: ${KNOWN_KEYS_OUT}）"
    elif ! SAMPLE_BLOCK="$(extract_profile_schema_block "$PROFILE_SAMPLE" 2>&1)"; then
      fail_case "profile-sample.mdから\`\`\`yamlブロックを抽出できない（詳細: ${SAMPLE_BLOCK}）"
    else
      pass "profile_resolve.py known-keys が成功する"

      # 抽出したサンプルブロックを一時ファイルへ書き、print-schema-versionの
      # 入力に使う（このサブコマンドはパス引数を取る値なし・副作用ゼロの契約）。
      TMP_SAMPLE_BLOCK="$(mktemp)"
      printf '%s\n' "$SAMPLE_BLOCK" > "$TMP_SAMPLE_BLOCK"

      print_version_rc=0
      if PRINT_VERSION_OUT="$(python3 "$PROFILE_RESOLVE_PY" print-schema-version "$TMP_SAMPLE_BLOCK" 2>&1)"; then
        print_version_rc=0
      else
        print_version_rc=$?
      fi
      rm -f "$TMP_SAMPLE_BLOCK"

      # known-keys／print-schema-versionの出力とサンプル本文を、この場だけの
      # 突合ロジックとして直接文字列処理せずpython3へ渡す（既存のsection5と
      # 同じ「現物を静的抽出して突合するだけ・registryは作らない」方針）。
      RESULT="$(python3 - "$KNOWN_KEYS_OUT" "$SAMPLE_BLOCK" "$PRINT_VERSION_OUT" "$print_version_rc" <<'PYEOF'
import re
import sys

known_keys_out, sample_block, print_version_out, print_version_rc = sys.argv[1:5]

fixed_line = next((l for l in known_keys_out.splitlines() if l.startswith('FIXED:')), None)
prefixes_line = next((l for l in known_keys_out.splitlines() if l.startswith('PREFIXES:')), None)
schema_version_line = next((l for l in known_keys_out.splitlines() if l.startswith('SCHEMA_VERSION:')), None)

results = []

if fixed_line is None or prefixes_line is None or schema_version_line is None:
    results.append(('FAIL', f'known-keysの出力にFIXED/PREFIXES/SCHEMA_VERSIONのいずれかが無い（出力: {known_keys_out!r}）'))
else:
    fixed_keys = set(fixed_line[len('FIXED:'):].split(','))
    prefixes = set(prefixes_line[len('PREFIXES:'):].split(','))
    expected_version = schema_version_line[len('SCHEMA_VERSION:'):].strip()

    # サンプルブロックの先頭階層キー（コメント行・空行・"---"区切り行を除く）を抽出。
    sample_keys = set()
    sample_schema_version = None
    for line in sample_block.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or stripped == '---':
            continue
        m = re.match(r'^([A-Za-z0-9_.-]+):', line)
        if not m:
            continue
        key = m.group(1)
        sample_keys.add(key)
        if key == 'schema_version':
            sample_schema_version = line.split(':', 1)[1].split('#', 1)[0].strip()

    dynamic_keys = {k for k in sample_keys if any(k.startswith(p) for p in prefixes)}
    sample_fixed_keys = sample_keys - dynamic_keys

    if sample_fixed_keys == fixed_keys:
        results.append(('PASS', 'profile-sample.mdの固定キー集合がprofile_resolve.py known-keysのFIXEDと完全一致する'))
    else:
        only_sample = sample_fixed_keys - fixed_keys
        only_code = fixed_keys - sample_fixed_keys
        results.append(('FAIL', f'固定キー集合が不一致（サンプルのみ: {sorted(only_sample)} / コードのみ: {sorted(only_code)}）'))

    used_prefixes = {p for p in prefixes if any(k.startswith(p) for k in sample_keys)}
    if prefixes == {'role.', 'fallback.'}:
        results.append(('PASS', 'known-keysの動的プレフィックスがrole./fallback.の2種で固定されている'))
    else:
        results.append(('FAIL', f'known-keysの動的プレフィックスがrole./fallback.の2種ではない（実際: {sorted(prefixes)}）'))
    if used_prefixes == prefixes:
        results.append(('PASS', 'サンプルが動的プレフィックス2種の両方を実際に使用している'))
    else:
        results.append(('FAIL', f'サンプルで使われていない動的プレフィックスがある（未使用: {sorted(prefixes - used_prefixes)}）'))

    if sample_schema_version is None:
        results.append(('FAIL', 'サンプルにschema_version行が無い'))
    elif sample_schema_version == expected_version:
        results.append(('PASS', f'サンプルのschema_version({sample_schema_version})がknown-keysの期待版({expected_version})と一致する'))
    else:
        results.append(('FAIL', f'サンプルのschema_version({sample_schema_version})がknown-keysの期待版({expected_version})と不一致'))

    if print_version_rc != '0':
        results.append(('FAIL', f'print-schema-versionが非0終了した（詳細: {print_version_out!r}）'))
    elif print_version_out.strip() == expected_version:
        results.append(('PASS', f'print-schema-versionの出力({print_version_out.strip()})がknown-keysの期待版と一致する'))
    else:
        results.append(('FAIL', f'print-schema-versionの出力({print_version_out.strip()})がknown-keysの期待版({expected_version})と不一致'))

for status, desc in results:
    print(f'{status}\t{desc}')
PYEOF
)"

      if [ -z "$RESULT" ]; then
        fail_case "known-keys/print-schema-versionとの突合が何も出力しなかった（想定外）"
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
    fi
  fi
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
