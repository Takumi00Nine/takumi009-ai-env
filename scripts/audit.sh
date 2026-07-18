#!/usr/bin/env bash
# public 化直前に1コマンドで回す総監査ツール（手動での公開前監査項目を自動化したもの。Phase 2.5）。
#
# チェック項目（1つでも❌があれば最終的にexit 1。ただし1項目失敗しても残りの項目を
# 続行し、最後にまとめてサマリ表示する＝export-public-vault.sh の fail-fast 方針とは
# 役割が違う。全項目の結果を1回の実行で把握したいための判断＝check-drift.sh と同方針）:
#   1. NGワード（git 履歴全体。scripts/ngwords.txt の全語を固定文字列検索）
#   2. 実ユーザー名パス（git 履歴全体。/Users/$(whoami) を動的に検索。ハードコード禁止）
#   3. シークレット（gitleaks detect --source、git 履歴モード）
#   4. 追跡ファイルの逸脱（git ls-files に docs/・ngwords.txt・.DS_Store が
#      含まれていないこと＝ .gitignore の破れ検知）
#   5. Personal リンク（現在の vault-public。export-public-vault.sh の 3-a/3-b と
#      同等の検出。検出ロジックは scripts/lib/personal-link-check.sh へ抽出し
#      export-public-vault.sh と共有している＝2026-07-16簡素化・cleanup決定#5で
#      複製を解消済み。旧実装は2026-07-08〜複製のまま運用されていた
#      〈担当ワーカーのファイル範囲制約による一時的な複製〉）
#   6. 完備性（README.md・LICENSE・.gitignore・scripts/install-main.sh の存在）
#
# --quick オプション: 1〜3の履歴スキャン（重い）を省き、4〜6の現在ツリーのみ実行する
# （日常の軽量チェック用。public化直前の最終監査は必ず --quick 無しで回すこと）。
#
# 読み取り専用（監査対象repoにも実Vaultにも一切書き込まない。commit/pushもしない）。
#
# 使い方:
#   scripts/audit.sh          # フル監査（public化直前用）
#   scripts/audit.sh --quick  # 現在ツリーのみ（日常用）
#
# パスは環境変数で上書き可（ユニットテスト用。本番は既定値のままでよい）:
#   REPO         監査対象repo（既定: このスクリプトの1つ上の階層）
#   NGWORDS_FILE NGワード定義ファイル（既定: $REPO/scripts/ngwords.txt）
#   VAULT        Personalリンクのbasename形式チェック用の実Vault
#                （既定: $HOME/Data/obsidian。$VAULT/Personal が無ければ
#                 basename形式チェックはスキップ＝サブ機等で私的パッチが無い場合の想定内動作）

set -uo pipefail  # -e は使わない（1項目の失敗で残りの検査が止まらないようにする。check-drift.shと同方針）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Personal リンク検出ロジックは scripts/export-public-vault.sh と共有する
# （2026-07-16 簡素化・cleanup決定#5。複製解消の詳細は scripts/lib/personal-link-check.sh
# 参照）。
# shellcheck source=scripts/lib/personal-link-check.sh
source "$SCRIPT_DIR/lib/personal-link-check.sh"

: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${NGWORDS_FILE:=$REPO/scripts/ngwords.txt}"
: "${VAULT:=$HOME/Data/obsidian}"

QUICK=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    *)
      # 変数の直後に全角文字を続けるとbash 3.2(macOS標準)のset -u下で変数名の
      # 境界誤認（マルチバイト文字の先頭バイトを変数名の一部と誤認）が起きるため、
      # ${arg} と明示的に区切る（2026-07-08 実装時に発見・要修正）。
      echo "[audit] 不明なオプション: ${arg}（使い方: scripts/audit.sh [--quick]）" >&2
      exit 2
      ;;
  esac
done

log() { echo "[audit] $*"; }
fail_setup() { echo "[audit] FAIL: $*" >&2; exit 2; }

# --- 前提コマンドの確認（履歴スキャンで使うものはquick時は不要だが、まとめて確認する） ---
for cmd in git rg; do
  command -v "$cmd" >/dev/null 2>&1 || fail_setup "コマンドが見つかりません: $cmd"
done
if [[ "$QUICK" -eq 0 ]]; then
  command -v gitleaks >/dev/null 2>&1 || fail_setup "コマンドが見つかりません: gitleaks"
fi

[[ -d "$REPO" ]] || fail_setup "REPO が見つかりません: $REPO"
[[ -d "$REPO/.git" ]] || fail_setup "REPO が git リポジトリではありません: $REPO"

FAIL_COUNT=0
RESULT_LINES=()

ok_item() { RESULT_LINES+=("✅ $1"); log "✅ $1"; }
ng_item() { RESULT_LINES+=("❌ $1"); log "❌ $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# 作業用一時ファイルはここに集約して登録し、EXIT時にまとめて掃除する
TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -eq 0 ]] || rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT
register_tmp() { local f; f="$(mktemp)"; TMP_FILES+=("$f"); printf '%s' "$f"; }

# 履歴ダンプは1・2で共用する（`git log -p --all` は大きいrepoほど重いため二重に
# 走らせない。また `git log | rg` のパイプだと、pipefail下でも「git自体の失敗」と
# 「rgのマッチ無し(rc=1)」の終了コードが区別しにくいため、いったんファイルへ書き出して
# gitのrcを確定させてからrgをファイルに対して走らせる＝Codexレビュー指摘・Major）。
if [[ "$QUICK" -eq 0 ]]; then
  HIST_DUMP="$(register_tmp)"
  hist_rc=0
  git -C "$REPO" log -p --all > "$HIST_DUMP" 2>/dev/null || hist_rc=$?
fi

echo "======================================================================"
echo "1. NGワード（git 履歴全体）"
echo "======================================================================"
if [[ "$QUICK" -eq 1 ]]; then
  log "skip（--quick指定のため履歴スキャンなし）"
elif [[ "$hist_rc" -ne 0 ]]; then
  ng_item "NGワード（履歴）: git log -p --all の取得に失敗しました (exit $hist_rc)"
elif [[ ! -f "$NGWORDS_FILE" ]]; then
  ng_item "NGワード（履歴）: NGWORDS_FILE が見つかりません: $NGWORDS_FILE"
else
  # 空行が1行でも混じると「全行マッチ」の事故になるため、空行を除いた一時ファイルを使う
  # （export-public-vault.sh 3-c と同方針）。「読み取れない」と「有効な行が無い」を
  # 区別する（読み取り不能を握りつぶして誤って0件扱いにしないため＝Codexレビュー指摘・Minor）。
  NGWORDS_CLEAN="$(register_tmp)"
  if ! grep -v '^[[:space:]]*$' "$NGWORDS_FILE" > "$NGWORDS_CLEAN" 2>/dev/null; then
    [[ -r "$NGWORDS_FILE" ]] || ng_item "NGワード（履歴）: NGWORDS_FILE を読み取れません: $NGWORDS_FILE"
  fi
  if [[ ! -r "$NGWORDS_FILE" ]]; then
    : # 上で既にng_item済み。二重報告しない
  elif [[ ! -s "$NGWORDS_CLEAN" ]]; then
    ng_item "NGワード（履歴）: ngwords.txt に有効な行がありません"
  else
    NGWORDS_HITS="$(register_tmp)"
    rc=0
    rg -n -F -f "$NGWORDS_CLEAN" "$HIST_DUMP" > "$NGWORDS_HITS" 2>/dev/null || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      count=$(wc -l < "$NGWORDS_HITS" | tr -d ' ')
      ng_item "NGワード（履歴）: ${count}行検出（$NGWORDS_FILE 参照）"
    elif [[ "$rc" -eq 1 ]]; then
      ok_item "NGワード（履歴）: 0件"
    else
      ng_item "NGワード（履歴）: rg 実行エラー (exit $rc)"
    fi
  fi
fi

echo
echo "======================================================================"
echo "2. 実ユーザー名パス（git 履歴全体）"
echo "======================================================================"
if [[ "$QUICK" -eq 1 ]]; then
  log "skip（--quick指定のため履歴スキャンなし）"
elif [[ "$hist_rc" -ne 0 ]]; then
  ng_item "実ユーザー名パス（履歴）: git log -p --all の取得に失敗しました (exit $hist_rc)"
else
  # $(whoami) で実行マシンのユーザー名を動的に取得する（どのマシンでも動くように
  # ハードコード禁止＝設計方針）。固定文字列検索（-F）で正規表現特殊文字を気にしない。
  # ログには実ユーザー名そのものを出さない（監査ログを貼付・共有する運用を想定した
  # プライバシー配慮＝Codexレビュー指摘・Minor）。
  real_user="$(whoami)"
  user_pattern="/Users/${real_user}"
  USER_HITS="$(register_tmp)"
  rc=0
  rg -n -F -- "$user_pattern" "$HIST_DUMP" > "$USER_HITS" 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    count=$(wc -l < "$USER_HITS" | tr -d ' ')
    ng_item "実ユーザー名パス（履歴）: ${count}行検出（/Users/<実行ユーザー> 形式）"
  elif [[ "$rc" -eq 1 ]]; then
    ok_item "実ユーザー名パス（履歴）: 0件"
  else
    ng_item "実ユーザー名パス（履歴）: rg 実行エラー (exit $rc)"
  fi
fi

echo
echo "======================================================================"
echo "3. シークレット（gitleaks・履歴全体）"
echo "======================================================================"
if [[ "$QUICK" -eq 1 ]]; then
  log "skip（--quick指定のため履歴スキャンなし）"
else
  rc=0
  gitleaks detect --source "$REPO" --no-banner --redact >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok_item "シークレット（履歴）: gitleaks検出なし"
  elif [[ "$rc" -eq 1 ]]; then
    ng_item "シークレット（履歴）: gitleaks がシークレットの疑いを検出しました"
  else
    ng_item "シークレット（履歴）: gitleaks 実行エラー (exit $rc)"
  fi
fi

echo
echo "======================================================================"
echo "4. 追跡ファイルの逸脱（git ls-files）"
echo "======================================================================"
TRACKED="$(register_tmp)"
if ! git -C "$REPO" ls-files > "$TRACKED" 2>/dev/null; then
  # git ls-files自体が失敗した場合、追跡ファイルが空扱いになって誤って「0件」と
  # 判定されてしまうのを防ぐ（fail-openにしない＝Codexレビュー指摘・Major方針を踏襲）。
  ng_item "追跡ファイルの逸脱: git ls-files の実行に失敗しました"
else
  DEVIANT_HITS="$(register_tmp)"
  : > "$DEVIANT_HITS"
  while IFS= read -r f; do
    case "$f" in
      docs|docs/*) echo "$f" >> "$DEVIANT_HITS" ;;
      scripts/ngwords.txt) echo "$f" >> "$DEVIANT_HITS" ;;
      .DS_Store|*/.DS_Store) echo "$f" >> "$DEVIANT_HITS" ;;
    esac
  done < "$TRACKED"
  count=$(wc -l < "$DEVIANT_HITS" | tr -d ' ')
  if [[ "$count" -eq 0 ]]; then
    ok_item "追跡ファイルの逸脱: 0件"
  else
    ng_item "追跡ファイルの逸脱: ${count}件（$(paste -sd, "$DEVIANT_HITS")）"
  fi
fi

echo
echo "======================================================================"
echo "5. Personal リンク（vault-public、export-public-vault.sh 3-a/3-b 相当）"
echo "======================================================================"
VAULT_PUBLIC="$REPO/vault-public"
if [[ ! -d "$VAULT_PUBLIC" ]]; then
  ng_item "Personal リンク: vault-public が見つかりません: $VAULT_PUBLIC"
else
  # フォルダ付き wiki link（[[Personal/xxx]] 等）検出用の正規表現。
  # scripts/lib/personal-link-check.sh を export-public-vault.sh と共有する
  # （2026-07-16簡素化・cleanup決定#5。複製解消）。
  folder_pattern="$(personal_link_folder_regex "Personal")"
  FOLDER_HITS="$(register_tmp)"
  link_scan_error=0
  rc=0
  rg -n -i -P "$folder_pattern" "$VAULT_PUBLIC" > "$FOLDER_HITS" 2>/dev/null || rc=$?
  [[ "$rc" -gt 1 ]] && link_scan_error=1

  # basename 形式（[[career-private]] 等、フォルダ省略）の denylist は実Vaultの
  # Personal 配下から自動生成する。実Vaultへアクセスできない環境（サブ機等）では
  # このチェックだけスキップする（fail扱いにはしない＝想定内の実行環境差）。
  BASENAME_HITS="$(register_tmp)"
  : > "$BASENAME_HITS"
  if [[ -d "$VAULT/Personal" ]]; then
    BASENAME_DENYLIST="$(register_tmp)"
    # findが1件でも失敗した場合はdenylistが不完全な可能性があり、そのまま検査を
    # 続けると本来検出すべきPersonalリンクを見逃しうる（fail-open化を防ぐ・
    # Codexレビュー指摘・Major対応）。「検査不能」として扱う。
    if ! personal_link_build_basename_denylist "$VAULT" Personal "$BASENAME_DENYLIST"; then
      link_scan_error=1
    else
      BASENAME_PATTERN_FILE="$(register_tmp)"
      personal_link_build_basename_pattern_file "$BASENAME_DENYLIST" "$BASENAME_PATTERN_FILE"
      if [[ -s "$BASENAME_PATTERN_FILE" ]]; then
        rc=0
        rg -n -i -P -f "$BASENAME_PATTERN_FILE" "$VAULT_PUBLIC" > "$BASENAME_HITS" 2>/dev/null || rc=$?
        [[ "$rc" -gt 1 ]] && link_scan_error=1
      fi
    fi
  else
    log "  basename形式チェック: $VAULT/Personal が見つからないためスキップ（実Vault非依存の環境では想定内）"
  fi

  if [[ "$link_scan_error" -eq 1 ]]; then
    # rg自体のエラー(exit>1)を「マッチ無し」と誤認してfail-openしない
    # （Codexレビュー指摘・Major方針を5にも適用）
    ng_item "Personal リンク（vault-public）: rg 実行エラーのため検査できません"
  else
    count=$(cat "$FOLDER_HITS" "$BASENAME_HITS" 2>/dev/null | sort -u | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
      ok_item "Personal リンク（vault-public）: 0件"
    else
      ng_item "Personal リンク（vault-public）: ${count}行検出"
    fi
  fi
fi

echo
echo "======================================================================"
echo "6. 完備性（README.md・LICENSE・.gitignore・scripts/install-main.sh）"
echo "======================================================================"
REQUIRED_FILES=(README.md LICENSE .gitignore scripts/install-main.sh)
missing=()
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "$REPO/$f" ]]; then
    log "  ✅ $f"
  else
    log "  ❌ $f"
    missing+=("$f")
  fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
  ok_item "完備性: 必須ファイル全て存在"
else
  ng_item "完備性: 不足${#missing[@]}件（${missing[*]}）"
fi

echo
echo "======================================================================"
echo "サマリ"
echo "======================================================================"
for line in "${RESULT_LINES[@]}"; do
  echo "  $line"
done

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  log "public化可（全項目クリア）"
  exit 0
else
  log "public化不可（❌ ${FAIL_COUNT}件。上記を修正してから再実行してください）"
  exit 1
fi
