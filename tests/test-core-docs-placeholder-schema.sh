#!/usr/bin/env bash
# 公開コア文書のプレースホルダ整合と必読集合の一致。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# ⚠️ 2026-09-08 本人裁定A案（設定ファイルsample配布）で
# scripts/install-main.shのextract_profile_schema_block()（```yamlフェンス
# 抽出）が撤去された（雛形配置の読み元がconfig/profile.md.sampleという
# 生ファイルへ付け替わり、フェンス抽出が不要になったため）。これをsedで
# 静的抽出してevalしていた共有ヘルパーensure_extract_profile_schema_block_fn()
# も、それを使っていたセクション6・7のテストごと撤去した（詳細＝
# セクション6・7の現行実装を参照）。

# 最小能力表の能力軸3キー（§3.3.0）。2026-09-08 モデル定義ファイルと候補
# 指定対応（同設計§3.8・D-13）: 旧v1側の正本（bootstrap-vault.shが持って
# いた既知キー配列本体と、それを単独出力する専用フック）を撤去した
# ため、能力軸キー集合はprofile_resolve.pyのCAPABILITY_KEYS（known-keysの
# FIXEDからschema_version/profile_slugを除いたもの）だけを
# 唯一の正本として実行時ソースで取得する（ハードコード再列挙しない）。
# ⚠️ 旧v1/v2の突合テスト（旧section 8）は突合相手が消えたため削除した。
BOOTSTRAP_VAULT_SH="$REPO_ROOT/ai-brain/executor/bootstrap-vault.sh"
PROFILE_RESOLVE_PY_FOR_KEYS="$REPO_ROOT/team/executor/profile_resolve.py"
KNOWN_KEYS=()
if [ -f "$PROFILE_RESOLVE_PY_FOR_KEYS" ]; then
  _fixed_line="$(python3 "$PROFILE_RESOLVE_PY_FOR_KEYS" known-keys 2>/dev/null | grep '^FIXED:' || true)"
  _fixed_line="${_fixed_line#FIXED:}"
  if [ -n "$_fixed_line" ]; then
    IFS=',' read -r -a _fixed_keys <<< "$_fixed_line"
    for _k in "${_fixed_keys[@]}"; do
      case "$_k" in
        schema_version|profile_slug) continue ;;
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
  local abspath="$TESTS_DIR/../ai-brain/data/vault-public/$relpath"
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
      :
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
  [ "$unknown" -ne 0 ] || pass "$relpath: プレースホルダが既知の参照名に収まる"
}

echo "=== 1. Preferences/core-conduct.md の {{…}} プレースホルダが最小能力表キー、または設計上認められた文書参照名に含まれる ==="
check_file "Preferences/core-conduct.md"

echo "=== 2. Preferences/core-workflow.md の {{…}} プレースホルダが最小能力表キー、または設計上認められた文書参照名に含まれる ==="
check_file "Preferences/core-workflow.md"

echo "=== 5. 起動と棚卸しの必読ファイル集合が一致する ==="
{
  VAULT_INVENTORY_PY="$REPO_ROOT/ai-brain/executor/vault_inventory.py"

  RESULT="$(python3 - "$BOOTSTRAP_VAULT_SH" "$VAULT_INVENTORY_PY" <<'PYEOF'
import re
import sys

bootstrap_path, inventory_path = sys.argv[1:3]


def extract(text, pattern):
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return None
    return set(re.findall(r'"([^"]+)"', m.group(1)))


bootstrap_text = open(bootstrap_path, encoding='utf-8').read()
inventory_text = open(inventory_path, encoding='utf-8').read()

files_set = extract(bootstrap_text, r'\n\s*FILES=\((.*?)\n\s*\)')
bootstrap_files_set = extract(inventory_text, r'\nBOOTSTRAP_FILES\s*=\s*\[(.*?)\n\]')

results = []

if files_set is None:
    results.append(('FAIL', 'bootstrap-vault.shからFILES配列を抽出できない（正規表現の劣化・変数名変更の可能性）'))
if bootstrap_files_set is None:
    results.append(('FAIL', 'vault_inventory.pyからBOOTSTRAP_FILESを抽出できない（正規表現の劣化・変数名変更の可能性）'))
if files_set is not None and bootstrap_files_set is not None:
    if files_set == bootstrap_files_set:
        results.append(('PASS', 'bootstrap-vault.shのFILESとvault_inventory.pyのBOOTSTRAP_FILESが集合として完全一致する'))
    else:
        only_files = files_set - bootstrap_files_set
        only_inv = bootstrap_files_set - files_set
        results.append(('FAIL', f'FILESとBOOTSTRAP_FILESが不一致（FILESのみ: {sorted(only_files)} / BOOTSTRAP_FILESのみ: {sorted(only_inv)}）'))

for status, desc in results:
    print(f'{status}\t{desc}')
PYEOF
)"

  if [ -z "$RESULT" ]; then
    fail_case "2集合突合の静的テスト自体が何も出力しなかった（想定外）"
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
