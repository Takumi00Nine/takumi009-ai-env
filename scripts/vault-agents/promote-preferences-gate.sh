#!/usr/bin/env bash
# maintenance_apply.py の PROMOTE(target_folder=Preferences) 書込前ゲート
# （設計書§2.4改訂v2「事前ゲート: Preferences 向け PROMOTE の最終全文（frontmatter込み）に
# 共通 Personal リンク検査モジュール＋ngwords チェックを同期適用。検出したらその action
# のみ skip」）。
#
# scripts/lib/personal-link-check.sh（export-public-vault.sh/audit.sh と共有・
# 2026-07-16簡素化cleanup決定#5）をそのまま再利用する。maintenance_apply.py（Python）
# 側で同じロジックを再実装せず本スクリプトへ委譲することで、Personalリンク検出の
# 実装が2箇所（bash/python）にドリフトする事故を避ける（cleanup決定#10「共有ロジックの
# 分離原則」の趣旨をPython⇄シェルの言語境界を跨いでも適用する）。
#
# export-public-vault.sh の 3-a/3-b（Personal wiki link・fail-fast）・3-c（ngwords）と
# 同じ検査項目・同じrg呼び出し方だが、対象は「ディレクトリを丸ごとrsyncしたステージング」
# ではなく「これから書き込む1件の候補ノート全文」（--text-file）である点が異なる。
# gitleaks（3-d）はexport-public-vault.sh固有のシークレット検出であり、設計書§2.4は
# 本ゲートの対象に含めていないため実装しない。
#
# 使い方: promote-preferences-gate.sh --vault VAULT --text-file FILE [--ngwords-file FILE]
# 終了コード:
#   0 = 検出なし（書込可）
#   1 = 検出あり（Personal link または ngwords。そのactionはskipすること）
#   2 = 実行エラー（rg失敗・denylist生成失敗・ngwords.txt欠落等。安全側でこのactionはskip扱いにすること＝fail-closed）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/personal-link-check.sh
source "$SCRIPT_DIR/../lib/personal-link-check.sh"

VAULT=""
TEXT_FILE=""
NGWORDS_FILE="$SCRIPT_DIR/../ngwords.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault|--text-file|--ngwords-file)
      # 値が無いまま指定された場合（例: 末尾が"--vault"だけで終わる）、
      # set -u下で$2をそのまま参照すると「unbound variable」でbashが
      # 即終了しexit code 1になり、本スクリプトが契約する「実行エラー=2」を
      # 満たせない（2026-07-16 Codex一次レビュー指摘Minor対応）。
      [[ $# -ge 2 ]] || { echo "ERROR: $1 には値が必要です" >&2; exit 2; }
      case "$1" in
        --vault) VAULT="$2" ;;
        --text-file) TEXT_FILE="$2" ;;
        --ngwords-file) NGWORDS_FILE="$2" ;;
      esac
      shift 2
      ;;
    *) echo "ERROR: 不明な引数です: $1" >&2; exit 2 ;;
  esac
done

# 変数直後に全角記号が続くと bash 3.2（macOS既定）+ ja_JP.UTF-8 環境で
# 「unbound variable」誤検知を起こす既知の地雷（[[Knowledge/bash-fullwidth-var-
# boundary-pitfall]]）。${VAR} と明示的に中括弧で囲み変数名境界を曖昧にしない。
[[ -n "$VAULT" && -d "$VAULT" ]] || { echo "ERROR: --vault が不正です（${VAULT}）" >&2; exit 2; }
[[ -n "$TEXT_FILE" && -f "$TEXT_FILE" ]] || { echo "ERROR: --text-file が不正です（${TEXT_FILE}）" >&2; exit 2; }
[[ -f "$NGWORDS_FILE" ]] || { echo "ERROR: ngwords.txt が見つかりません: $NGWORDS_FILE" >&2; exit 2; }
command -v rg >/dev/null 2>&1 || { echo "ERROR: rg が見つかりません" >&2; exit 2; }

TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -eq 0 ]] || rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT
register_tmp() { REGISTER_TMP_RESULT="$(mktemp -t promote-preferences-gate)"; TMP_FILES+=("$REGISTER_TMP_RESULT"); }

# --- 1. Personal フォルダへの wiki link（フォルダ付き形式）: fail-closed ---
pattern="$(personal_link_folder_regex "Personal")"
rc=0
rg -n -i -P "$pattern" "$TEXT_FILE" >/dev/null || rc=$?
if [[ $rc -eq 0 ]]; then
  echo "DETECTED: Personal フォルダへの wiki link（フォルダ付き）を検出しました" >&2
  exit 1
elif [[ $rc -gt 1 ]]; then
  echo "ERROR: rg 実行エラー (folder-qualified check, exit $rc)" >&2
  exit 2
fi

# --- 2. Personal ノートへの wiki link（basename形式・denylistはVaultのPersonal配下から自動生成） ---
register_tmp; BASENAME_DENYLIST="$REGISTER_TMP_RESULT"
register_tmp; BASENAME_PATTERN_FILE="$REGISTER_TMP_RESULT"

if ! personal_link_build_basename_denylist "$VAULT" "Personal" "$BASENAME_DENYLIST"; then
  echo "ERROR: Personal denylist の生成に失敗しました（findエラー）" >&2
  exit 2
fi
personal_link_build_basename_pattern_file "$BASENAME_DENYLIST" "$BASENAME_PATTERN_FILE"

if [[ -s "$BASENAME_PATTERN_FILE" ]]; then
  rc=0
  rg -n -i -P -f "$BASENAME_PATTERN_FILE" "$TEXT_FILE" >/dev/null || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "DETECTED: Personal ノートへの wiki link（basename形式）を検出しました" >&2
    exit 1
  elif [[ $rc -gt 1 ]]; then
    echo "ERROR: rg 実行エラー (basename check, exit $rc)" >&2
    exit 2
  fi
fi

# --- 3. NGワード検出（固定文字列一致） ---
register_tmp; NGWORDS_CLEAN="$REGISTER_TMP_RESULT"
if ! grep -v '^[[:space:]]*$' "$NGWORDS_FILE" > "$NGWORDS_CLEAN"; then
  [[ -r "$NGWORDS_FILE" ]] || { echo "ERROR: ngwords.txt を読み取れません: $NGWORDS_FILE" >&2; exit 2; }
fi
[[ -s "$NGWORDS_CLEAN" ]] || { echo "ERROR: ngwords.txt に有効な行がありません: $NGWORDS_FILE" >&2; exit 2; }

rc=0
rg -n -F -f "$NGWORDS_CLEAN" "$TEXT_FILE" >/dev/null || rc=$?
if [[ $rc -eq 0 ]]; then
  echo "DETECTED: NGワードを検出しました" >&2
  exit 1
elif [[ $rc -gt 1 ]]; then
  echo "ERROR: rg 実行エラー (ngwords check, exit $rc)" >&2
  exit 2
fi

echo "OK: Personal link / ngwords 検出なし"
exit 0
