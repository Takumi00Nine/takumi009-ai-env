#!/usr/bin/env bash
# vault-public/Preferences/core-conduct.md・core-workflow.md 内の {{…}} プレース
# ホルダ集合が、最小能力表の能力軸3キー（§3.3.0。2026-09-07能力軸整理で
# 7→3キーへ縮小）、または設計上認められた文書参照名
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

# 最小能力表の能力軸3キー（§3.3.0）。2026-09-08 モデル定義ファイルと候補
# 指定対応（同設計§3.8・D-13）: 旧v1側の正本（bootstrap-vault.shが持って
# いた既知キー配列本体と、それを単独出力する専用フック）を撤去した
# ため、能力軸キー集合はprofile_resolve.pyのCAPABILITY_KEYS（known-keysの
# FIXEDからschema_version/profile_slug/excluded_modelsを除いたもの）だけを
# 唯一の正本として実行時ソースで取得する（ハードコード再列挙しない）。
# ⚠️ 旧v1/v2の突合テスト（旧section 8）は突合相手が消えたため削除した。
BOOTSTRAP_VAULT_SH="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"
PROFILE_RESOLVE_PY_FOR_KEYS="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
KNOWN_KEYS=()
if [ -f "$PROFILE_RESOLVE_PY_FOR_KEYS" ]; then
  _fixed_line="$(python3 "$PROFILE_RESOLVE_PY_FOR_KEYS" known-keys 2>/dev/null | grep '^FIXED:' || true)"
  _fixed_line="${_fixed_line#FIXED:}"
  if [ -n "$_fixed_line" ]; then
    IFS=',' read -r -a _fixed_keys <<< "$_fixed_line"
    for _k in "${_fixed_keys[@]}"; do
      case "$_k" in
        schema_version|profile_slug|excluded_models) continue ;;
      esac
      KNOWN_KEYS+=("$_k")
    done
  fi
fi
if [ "${#KNOWN_KEYS[@]}" -eq 0 ]; then
  echo "FATAL: profile_resolve.py known-keys から能力軸キー集合を取得できませんでした" >&2
  exit 1
fi

# v2配役表解凍で新規に正当化された参照名（2026-09-02追加）。プロファイル
# YAMLのキー名ではなく、コア本文が配役表という概念そのものを指す散文上の
# 参照であるため、能力軸キー集合へは混ぜず、別カテゴリの許可リストとして
# ここに明示する（設計書配役表解凍-設計-2026-09-01.md §7 冒頭注記差分
# 「採用の有無も配役も {{配役表}} を見る」で規定済み。同じ行が「表を統合
# したので {{採用表}} という参照名は作らない」とも明記しているため、
# {{採用表}} はこのリストに加えない＝Vault文言側の懸念は別途リーダーへ報告）。
DOC_REFERENCE_KNOWN_KEYS=(
  "配役表"
)

is_known_key() {
  local target="$1" k
  for k in "${KNOWN_KEYS[@]:-}" "${DOC_REFERENCE_KNOWN_KEYS[@]:-}"; do
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
      pass "$relpath: {{${ph}}} は最小能力表キー・v2追加の能力軸キー、または配役表解凍で正当化された参照名に含まれる"
    else
      # ⚠️ is_known_key()と同じ理由（120行目コメント）で`:-`ガードを付ける。
      # 3モード体制対応で{{reviewer}}が未解決参照になった実例（公開スナップ
      # ショット未再生成の間）で、ここが無guardのままset -u下でunbound
      # variableエラーとなりスイート全体を落としていたのを機に追加した。
      fail_case "$relpath: {{${ph}}} は既知の参照名に含まれない（未解決参照。最小能力表キー＝${KNOWN_KEYS[*]:-}／配役表解凍で正当化された参照名＝${DOC_REFERENCE_KNOWN_KEYS[*]:-}）"
      unknown=$((unknown + 1))
    fi
  done <<EOF
$placeholders
EOF
}

echo "=== 1. Preferences/core-conduct.md の {{…}} プレースホルダが最小能力表キー、または設計上認められた文書参照名に含まれる ==="
check_file "Preferences/core-conduct.md"

echo "=== 2. Preferences/core-workflow.md の {{…}} プレースホルダが最小能力表キー、または設計上認められた文書参照名に含まれる ==="
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

    # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 下のサンプルとの
    # 突合は「両者が互いに一致するか」しか見ておらず、両方が同じ誤った
    # 6キー集合へ同時に変わっても通ってしまう（要件AC-1が求める「期待6キー」
    # ではなく「現物同士の一致」しか検査していなかった）。known-keysのFIXED
    # 集合を、配役表-能力軸整理-要件-2026-09-07.md §7.2 AC-1が定めるリテラル
    # 6キーと直接比較する検査を独立して追加する。
    expected_fixed_literal = {
        'schema_version', 'profile_slug', 'team_mode',
        'no_read_paths', 'machine_role', 'excluded_models',
    }
    if fixed_keys == expected_fixed_literal:
        results.append(('PASS', 'AC-1: known-keysのFIXED集合が要件の期待6キー(リテラル集合)と完全一致する'))
    else:
        only_expected = sorted(expected_fixed_literal - fixed_keys)
        only_actual = sorted(fixed_keys - expected_fixed_literal)
        results.append(('FAIL', f'AC-1: known-keysのFIXED集合が期待6キーと不一致（期待のみ: {only_expected} / 実際のみ: {only_actual}）'))

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

# 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.8・D-13）: 旧
# section 8（v1能力軸キー集合とv2能力軸キー集合の突合）を削除した。突合相手
# だったbootstrap-vault.shの既知キー配列本体（v1側の第2正本）が撤去され、
# 能力軸の正本はprofile_resolve.pyのCAPABILITY_KEYS側だけになったため。

echo "=== 9. AC-14: core-workflow.md §7の統合行がVault正本・公開スナップショットの両方にあり、旧2行と{{reviewer}}が現れない ==="
{
  NEW_LINE='**検証職が空席** → リーダー職が受入条件と1対1の最小検証を行い「独立検証なし・リーダー検証のみ」を成果物と報告に明記する'
  for label_path in "Vault正本:$HOME/Data/obsidian/Preferences/core-workflow.md" \
                     "公開スナップショット:$REPO_ROOT/vault-public/Preferences/core-workflow.md"; do
    label="${label_path%%:*}"; f="${label_path#*:}"
    if [ ! -f "$f" ]; then
      fail_case "AC-14(${label}): core-workflow.mdが見つからない"
      continue
    fi
    if grep -qF "$NEW_LINE" "$f"; then
      pass "AC-14(${label}): 統合行（検証職が空席…）がある"
    else
      fail_case "AC-14(${label}): 統合行（検証職が空席…）が無い（Vault反映後／export-public-vault.sh再生成後に緑化想定）"
    fi
    if grep -qF '一次レビュアー職が空席' "$f" || grep -qF 'tester が空席' "$f"; then
      fail_case "AC-14(${label}): 旧2行（一次レビュアー職が空席／tester が空席）が残っている"
    else
      pass "AC-14(${label}): 旧2行が0行"
    fi
    if grep -qF '{{reviewer}}' "$f"; then
      fail_case "AC-14(${label}): {{reviewer}}が残っている"
    else
      pass "AC-14(${label}): {{reviewer}}が現れない"
    fi
  done
}

echo "=== 10. AC-5: 廃止した能力軸・マーカー・別名トークンがrepoに残っていない（配役表-能力軸整理-設計-2026-09-07.md §6。本人決定＝Decisions/2026-09-07-profile-axes-consolidation） ==="
{
  # ⚠️ 語をそのまま書かない（この検査自身が0件検査へ一致してしまうため）。
  # 実行時に連結して組み立てる（設計書§6.2）。
  _u='_'; _h='-'
  RETIRED_PAT="git${_u}role|web${_u}verification|inventory${_u}source|ui\\.user${_u}call|vault${_u}write|machine${_h}role|work${_h}old"

  # ① 除外つき検索が0行（exit 1）＝廃止済みの生語がAC5-ALLOWタグ・決定ノート
  # リンク行を除いてrepoのどこにも残っていない。
  rc1=0
  out1="$(git -C "$REPO_ROOT" grep -nE -e "$RETIRED_PAT" \
    --and --not -e 'AC5-ALLOW' \
    --and --not -e 'Decisions/[0-9]{4}-[0-9]{2}-[0-9]{2}-' -- . 2>&1)" || rc1=$?
  if [ "$rc1" -eq 1 ] && [ -z "$out1" ]; then
    pass "①除外つき検索が0行（廃止語の残存なし）"
  else
    fail_case "①除外つき検索が0行ではない（rc=${rc1}）: ${out1}"
  fi

  # ② 許可タグ（AC5-ALLOW）を含むファイルがtests/配下だけにある。
  rc2=0
  tagged_files="$(git -C "$REPO_ROOT" grep -l 'AC5-ALLOW' -- . 2>&1)" || rc2=$?
  if [ "$rc2" -ne 0 ]; then
    fail_case "②AC5-ALLOWタグの検索自体が失敗した（rc=${rc2}）: ${tagged_files}"
  else
    outside_tests=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$f" in
        tests/*) : ;;
        *) outside_tests=$((outside_tests + 1)); fail_case "②AC5-ALLOWタグがtests/の外にある: $f" ;;
      esac
    done <<< "$tagged_files"
    [ "$outside_tests" -eq 0 ] && pass "②AC5-ALLOWタグはtests/配下だけにある"
  fi

  # ③ 各タグの<名前>が明示リスト（要件§6のfixture ID＝FX-P7・FX-M1、および
  # 旧版コード再現fixtureの汎用タグ＝FXP0）に一致する。
  # ⚠️ Codex一次レビュー指摘（MAJOR-3・2026-09-07）対応: 従来は
  # `FX-P[0-9]{1,2}`／`FX-M[0-9]{1,2}`という開いた数字レンジを許可しており、
  # 要件§6に無い任意の番号（例=FX-P12）でも構文だけ一致すれば通ってしまい、
  # 現行resolverに旧入力を渡すだけの通常回帰テストが「旧版コード再現」を
  # 僭称できてしまっていた。名前ごとの明示リストへ絞り、新しい許可名を
  # 増やしたい場合は本リストとAC-5③の記述を同じ巡で変更する規約にする。
  rc3=0
  all_tags="$(git -C "$REPO_ROOT" grep -ohE 'AC5-ALLOW:[A-Za-z0-9-]+' -- tests/ 2>&1)" || rc3=$?
  if [ "$rc3" -ne 0 ] || [ -z "$all_tags" ]; then
    fail_case "③AC5-ALLOWタグが1件も見つからない（想定外・rc=${rc3}）"
  else
    bad_names=0
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      name="${tag#AC5-ALLOW:}"
      if [[ "$name" == "FX-P7" || "$name" == "FX-M1" || "$name" == "FXP0" ]]; then
        :
      else
        bad_names=$((bad_names + 1))
        fail_case "③タグ名が明示リスト（FX-P7／FX-M1／FXP0）に一致しない: ${tag}"
      fi
    done <<< "$(printf '%s\n' "$all_tags" | sort -u)"
    [ "$bad_names" -eq 0 ] && pass "③全タグの名前が明示リスト（FX-P7／FX-M1／FXP0）に一致する（$(printf '%s\n' "$all_tags" | sort -u | wc -l | tr -d ' ')種）"
  fi
}

echo "=== 11. AC-2/AC-8: known-keysの3行目がSCHEMA_VERSION:6に完全一致する（モデル定義ファイルと候補指定-要件-2026-09-08.md §7.2 AC-8。旧・配役表-能力軸整理-要件-2026-09-07.md §7.2 AC-2のSCHEMA_VERSION:5から2026-09-08に6へ引き上げ） ==="
{
  PROFILE_RESOLVE_PY_AC2="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
  if [ ! -f "$PROFILE_RESOLVE_PY_AC2" ]; then
    fail_case "claude/hooks/lib/profile_resolve.py が見つからない"
  else
    kk_ac2="$(python3 "$PROFILE_RESOLVE_PY_AC2" known-keys)"
    line3="$(printf '%s\n' "$kk_ac2" | sed -n '3p')"
    if [ "$line3" = "SCHEMA_VERSION:6" ]; then
      pass "known-keysの3行目がSCHEMA_VERSION:6に完全一致する"
    else
      fail_case "known-keysの3行目がSCHEMA_VERSION:6に完全一致しない（実際: ${line3}）"
    fi
  fi
}

echo "=== 12. AC-7: プレースホルダ{{廃止5キー}}がVault正本・公開スナップショットの両方に0件（core-conduct.md・core-workflow.md。⚠️ 段階2〈vault-scribeによるVault正本改訂＋公開スナップショット再生成〉が終わるまでは公開スナップショット側が赤で正常＝設計書§9.1） ==="
{
  # ⚠️ 廃止キー名をソースへ直接書かない（本ファイル自身がAC-5の0件検査
  # 対象＝tests/配下のため、自分自身が引っかからないよう実行時に組み立てる）。
  _u12='_'
  RETIRED_PLACEHOLDER_PAT="\\{\\{(inventory${_u12}source|vault${_u12}write|ui\\.user${_u12}call|git${_u12}role|web${_u12}verification)\\}\\}"
  for label_path in "Vault正本:$HOME/Data/obsidian/Preferences/core-conduct.md" \
                     "Vault正本:$HOME/Data/obsidian/Preferences/core-workflow.md" \
                     "公開スナップショット:$REPO_ROOT/vault-public/Preferences/core-conduct.md" \
                     "公開スナップショット:$REPO_ROOT/vault-public/Preferences/core-workflow.md"; do
    label="${label_path%%:*}"; f="${label_path#*:}"
    fname="$(basename "$f")"
    if [ ! -f "$f" ]; then
      fail_case "AC-7(${label}:${fname}): ファイルが見つからない"
      continue
    fi
    rc=0
    hit="$(grep -nE "$RETIRED_PLACEHOLDER_PAT" "$f" 2>&1)" || rc=$?
    if [ "$rc" -eq 1 ] && [ -z "$hit" ]; then
      pass "AC-7(${label}:${fname}): 廃止5キーのプレースホルダが0件"
    else
      fail_case "AC-7(${label}:${fname}): 廃止5キーのプレースホルダが残っている: ${hit}"
    fi
  done
}

echo "=== 13. AC-10: core-workflow.md §5について、廃止済みgit上の立場プレースホルダが0件・machine_roleが1件以上（Vault正本・公開スナップショットの両方。⚠️ 段階2が終わるまでは公開スナップショット側が赤で正常） ==="
{
  # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 従来はファイル全体を
  # 検索しており、machine_roleが§5以外の別節に残っているだけでも通ってしまう
  # （要件AC-10は「§5について」と節を明示している）。§5見出し（`## 5. `）から
  # 次の`## `見出しの直前までを抽出してから検査する。
  _u13='_'
  legacy_placeholder_13="{{git${_u13}role}}"
  for label_path in "Vault正本:$HOME/Data/obsidian/Preferences/core-workflow.md" \
                     "公開スナップショット:$REPO_ROOT/vault-public/Preferences/core-workflow.md"; do
    label="${label_path%%:*}"; f="${label_path#*:}"
    if [ ! -f "$f" ]; then
      fail_case "AC-10(${label}): core-workflow.mdが見つからない"
      continue
    fi
    section5="$(awk '/^## 5\. /{flag=1; print; next} /^## [0-9]+\. /{flag=0} flag' "$f")"
    if [ -z "$section5" ]; then
      fail_case "AC-10(${label}): §5見出し（## 5. ）が見つからず抽出できない"
      continue
    fi
    rc=0
    hit="$(printf '%s\n' "$section5" | grep -nF "$legacy_placeholder_13" 2>&1)" || rc=$?
    if [ "$rc" -eq 1 ] && [ -z "$hit" ]; then
      pass "AC-10(${label}): §5内で廃止済みプレースホルダが0件"
    else
      fail_case "AC-10(${label}): §5内に廃止済みプレースホルダが残っている: ${hit}"
    fi
    rc2=0
    hit2="$(printf '%s\n' "$section5" | grep -nF 'machine_role' 2>&1)" || rc2=$?
    if [ "$rc2" -eq 0 ] && [ -n "$hit2" ]; then
      pass "AC-10(${label}): §5内にmachine_roleが1件以上"
    else
      fail_case "AC-10(${label}): §5内にmachine_roleが1件も無い"
    fi
  done
}

echo "=== 14. AC-12①: vault-operation.md・core-workflow.mdについて、廃止済みの旧マーカー語が0件・machine_roleが1件以上（Vault正本・公開スナップショットの両方。⚠️ 段階2が終わるまでは公開スナップショット側が赤で正常） ==="
{
  for name in "vault-operation.md" "core-workflow.md"; do
    for label_path in "Vault正本:$HOME/Data/obsidian/Preferences/${name}" \
                       "公開スナップショット:$REPO_ROOT/vault-public/Preferences/${name}"; do
      label="${label_path%%:*}"; f="${label_path#*:}"
      if [ ! -f "$f" ]; then
        fail_case "AC-12①(${label}:${name}): ファイルが見つからない"
        continue
      fi
      _h2='-'
      legacy_word="machine${_h2}role"
      rc=0
      hit="$(grep -nF "$legacy_word" "$f" 2>&1)" || rc=$?
      if [ "$rc" -eq 1 ] && [ -z "$hit" ]; then
        pass "AC-12①(${label}:${name}): 廃止済みの旧マーカー語が0件"
      else
        fail_case "AC-12①(${label}:${name}): 廃止済みの旧マーカー語が残っている: ${hit}"
      fi
      rc2=0
      hit2="$(grep -nF 'machine_role' "$f" 2>&1)" || rc2=$?
      if [ "$rc2" -eq 0 ] && [ -n "$hit2" ]; then
        pass "AC-12①(${label}:${name}): machine_roleが1件以上"
      else
        fail_case "AC-12①(${label}:${name}): machine_roleが1件も無い"
      fi
    done
  done
}

echo "=== 15. モデル定義ファイルと候補指定-要件-2026-09-08.md AC-14: repoに旧記法(role|fallback)\.[a-z-]+:.*provider=が0件（Codexレビュー指摘・BLOCKING-1対応・1巡目） ==="
{
  # ⚠️ 探索語は要件§7.1のとおり縦棒をエスケープせずに書く（実測で一致を
  # 確認済み）。repo 0件を判定する前に、この式が「わざと書いた1行」に
  # 一致すること（1件以上）を先に確認する（要件AC-14の注記）。
  # 2026-09-08 Codexレビュー指摘・MAJOR対応（2巡目）: 陽性対照は要件§8-3の
  # 実測どおり「引用符つき・インデントつき」の現行fixture行形に一致させる
  # （旧記法の役割行fixtureがrepoに実在していたときの実際の書かれ方＝sed
  # パターン・heredoc内の字下げされた引用符付き文字列を再現する。⚠️
  # 具体的な完成文字列を本コメント自身にも書かない——下の printf の断片
  # 組み立てが実際に生成する1行がその文字列そのものであり、コメントへ
  # 重ねて書くと本ファイル自身がAC-14のrepo検索に一致してしまうため）。
  AC14_PATTERN='(role|fallback)\.[a-z-]+:.*provider='
  POS_FIXTURE="$(mktemp)"
  # ⚠️ 完成文字列をソースへ直書きすると、本ファイル自身がAC-14のrepo検索に
  # 一致してしまう（自己言及の罠）。断片を変数へ分けてから展開する。
  legacy_attr_frag="provider="
  printf '    "role.verifier: configured %sexternal model=codex-review-default"\n' "$legacy_attr_frag" > "$POS_FIXTURE"
  rc_pos=0
  pos_hit="$(grep -nE "$AC14_PATTERN" "$POS_FIXTURE" 2>&1)" || rc_pos=$?
  if [ "$rc_pos" -eq 0 ] && [ -n "$pos_hit" ]; then
    pass "AC-14: 探索語の陽性対照（わざと書いた1行に一致する）"
  else
    fail_case "AC-14: 探索語が陽性対照の1行にすら一致しない（式が壊れている）"
  fi

  rc_repo=0
  repo_hits="$(git -C "$REPO_ROOT" grep -nE "$AC14_PATTERN" -- . 2>&1)" || rc_repo=$?
  if [ "$rc_repo" -eq 1 ] && [ -z "$repo_hits" ]; then
    pass "AC-14: repoに旧記法の役割行が0件"
  else
    fail_case "AC-14: repoに旧記法の役割行が残っている(rc=${rc_repo}): ${repo_hits}"
  fi
}

echo "=== 16. モデル定義ファイルと候補指定-要件-2026-09-08.md AC-15: 公開サンプル（Vault正本・公開スナップショット）の静的検査＝FX-B14a〜c（Codexレビュー指摘・MAJOR-3対応・1巡目） ==="
{
  for label_path in "Vault正本:$HOME/Data/obsidian/Preferences/model-definitions-sample.md" \
                     "公開スナップショット:$REPO_ROOT/vault-public/Preferences/model-definitions-sample.md"; do
    label="${label_path%%:*}"; f="${label_path#*:}"
    if [ ! -f "$f" ]; then
      fail_case "AC-15(${label}): ファイルが見つからない"
      continue
    fi

    rc1=0; hit1="$(grep -nF '/Users/' "$f" 2>&1)" || rc1=$?
    if [ "$rc1" -eq 1 ] && [ -z "$hit1" ]; then
      pass "AC-15①(${label}): 絶対パス(/Users/)が0件"
    else
      fail_case "AC-15①(${label}): 絶対パスが残っている: ${hit1}"
    fi

    rc2=0; hit2="$(grep -nE '(API_KEY|SECRET|TOKEN|PASSWORD)' "$f" 2>&1)" || rc2=$?
    if [ "$rc2" -eq 1 ] && [ -z "$hit2" ]; then
      pass "AC-15②(${label}): 認証情報キー語が0件"
    else
      fail_case "AC-15②(${label}): 認証情報キー語が残っている: ${hit2}"
    fi

    # AC-15③（要件§8-4）: modelの値は雛形トークンXXXXだけ（機体依存の実値は書かない）。
    bad_model="$(grep -nE '^model=' "$f" | grep -vF 'model=XXXX' || true)"
    if [ -z "$bad_model" ]; then
      pass "AC-15③(${label}): model=の値が雛形トークンXXXXだけ"
    else
      fail_case "AC-15③(${label}): 機体依存の値がXXXX以外で書かれている: ${bad_model}"
    fi

    excli_count="$(grep -c '^execution=external-cli$' "$f" 2>/dev/null || true)"
    if [ -n "${excli_count:-}" ] && [ "${excli_count:-0}" -ge 1 ] 2>/dev/null; then
      pass "AC-15(${label}): execution=external-cliの例が1回以上ある"
    else
      fail_case "AC-15(${label}): execution=external-cliの例が無い"
    fi
  done

  # FX-B14a〜c: 陰性fixture（悪い例）を一時ファイルへ書き、上と同じ検査器
  # （探索語）が実際に検出できることを確認する（設計§11.1「悪い例を検査器
  # へ食わせる」）。公開スナップショットのサンプルを土台にする。
  BASE14="$REPO_ROOT/vault-public/Preferences/model-definitions-sample.md"
  if [ -f "$BASE14" ]; then
    B14A="$(mktemp)"; cp "$BASE14" "$B14A"; printf '# /Users/takumi009/leak\n' >> "$B14A"
    hit_a="$(grep -nF '/Users/' "$B14A" || true)"
    if [ -n "$hit_a" ]; then pass "FX-B14a: 絶対パスの混入を検出できる"; else fail_case "FX-B14a: 絶対パスの混入を検出できない"; fi

    B14B="$(mktemp)"; cp "$BASE14" "$B14B"; printf 'ANTHROPIC_API_KEY=sk-fake\n' >> "$B14B"
    hit_b="$(grep -nE '(API_KEY|SECRET|TOKEN|PASSWORD)' "$B14B" || true)"
    if [ -n "$hit_b" ]; then pass "FX-B14b: 認証情報キーの混入を検出できる"; else fail_case "FX-B14b: 認証情報キーの混入を検出できない"; fi

    B14C="$(mktemp)"; cp "$BASE14" "$B14C"; printf 'model=claude-opus-5\n' >> "$B14C"
    hit_c="$(grep -nE '^model=' "$B14C" | grep -vF 'model=XXXX' || true)"
    if [ -n "$hit_c" ]; then pass "FX-B14c: 実モデルIDの混入を検出できる"; else fail_case "FX-B14c: 実モデルIDの混入を検出できない"; fi
  else
    fail_case "FX-B14a〜c: 公開スナップショットのサンプルが見つからないため陰性fixtureを構成できない"
  fi
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
