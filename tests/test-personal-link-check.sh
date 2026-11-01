#!/usr/bin/env bash
# ai-brain/executor/personal-link-check.sh のユニットテスト（Personal リンク検査
# 共通モジュール・2026-07-16簡素化・cleanup決定#5）。
#
# 採用条件（cleanup決定#5・設計書§6）: 共通化前後で
# export-public-vault.sh（3-a/3-b・fail-fast）と audit.sh（5・レポートのみ）の
# 検出結果が一致すること＋悪性fixture（Personal リンク混入）のnegative test。
# 本ファイルは (a) 共有関数の単体テスト (b) 悪性/良性fixtureに対する
# export-public-vault.sh と audit.sh の検出結果一致テスト、の2部構成。
#
# 実行方法: bash tests/test-personal-link-check.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/ai-brain/executor/personal-link-check.sh"
EXPORT_SCRIPT="$REPO_ROOT/ai-brain/executor/export-public-vault.sh"
AUDIT_SCRIPT="$REPO_ROOT/core/executor/audit.sh"

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

# --- part (a): 共有関数の単体テスト ---

echo "=== 4. personal_link_build_basename_denylist: Vault配下の指定フォルダから.mdのbasenameを重複排除して収集する ==="
{
  source "$LIB"
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Personal" "$VAULT_DIR/Knowledge"
  echo x > "$VAULT_DIR/Personal/career-private.md"
  echo x > "$VAULT_DIR/Personal/devices.md"
  echo x > "$VAULT_DIR/Knowledge/unrelated.md"
  OUT="$(mktemp)"
  personal_link_build_basename_denylist "$VAULT_DIR" Personal "$OUT"
  if grep -qx career-private "$OUT" && ! grep -q unrelated "$OUT"; then
    pass "Personalのbasenameだけを収集"
  else
    fail_case "Personalのbasenameだけを収集"
  fi
  rm -rf "$VAULT_DIR" "$OUT"
}

# export-public-vault.sh を実行して exit code を返す。
# ⚠️ 2026-08-30 環境依存欠陥の修正（追加1対応）: 従来はNGWORDS_FILEを渡して
# おらず、export-public-vault.sh側の既定値（$SCRIPT_DIR/ngwords.txt＝実スクリプト
# 自身が置かれた $REPO_ROOT/scripts/ngwords.txt）へフォールバックしていた。
# このパスは.gitignore対象の私的資産（実運用ではprivateリポジトリへの
# symlinkとして手動設置される）であり、新規clone/checkout・git worktreeした
# 環境には存在しない。各fixtureが用意する「$repo/scripts/ngwords.txt」は
# このデフォルト経路では一度も参照されておらず、実際には無関係な
# $REPO_ROOT/scripts/ngwords.txt（開発者の主作業ディレクトリにたまたま手動
# 設置済みだったもの）を読んでいたため、そこで実行する限りは気づかず
# 通っていた（tester環境＝隔離worktreeやCI相当のクリーンチェックアウトでは
# 「ngwords.txt が見つかりません」でexport-public-vault.sh自体がFAILする）。
# 本体側のfail-closed挙動（ngwords.txt無しなら止める）は本番の安全設計として
# 正しいため変更せず、テスト側の意図（fixtureが用意した「$repo/scripts/
# ngwords.txt」を使わせる）どおりNGWORDS_FILEを明示的に渡すよう修正した。
run_export() {
  local vault="$1" repo="$2"
  VAULT="$vault" AIENV_REPO="$repo" NGWORDS_FILE="$repo/scripts/ngwords.txt" \
    "$EXPORT_SCRIPT" >"$WORK_TMP/export-stdout.log" 2>"$WORK_TMP/export-stderr.log"
}

# audit.sh を --quick で実行する（Personal リンクチェック自体は5番・quickでもスキップ
# されない項目のため --quick で十分。フルスキャンの履歴チェックは対象外にして
# gitleaks/履歴走査コストを避ける）。
run_audit_quick() {
  local repo="$1" vault="$2"
  REPO="$repo" VAULT="$vault" NGWORDS_FILE="$repo/scripts/ngwords.txt" "$AUDIT_SCRIPT" --quick >"$WORK_TMP/audit-stdout.log" 2>"$WORK_TMP/audit-stderr.log"
}

# audit.sh 用のfixture repo骨格を作る（core/executor/audit.sh + ai-brain/executor/personal-link-check.sh
# を実体コピーし、REPO/ai-brain/data/vault-public/Personal を用意する。export-public-vault.sh側の
# 出力(ai-brain/data/vault-public/)をそのままこのrepoへコピーして比較する）。
make_audit_repo_skeleton() {
  local repo="$1"
  mkdir -p "$repo/core/executor" "$repo/core/assembly" "$repo/ai-brain/executor" "$repo/ai-brain/data"
  cp "$AUDIT_SCRIPT" "$repo/core/executor/audit.sh"
  cp "$LIB" "$repo/ai-brain/executor/personal-link-check.sh"
  chmod +x "$repo/core/executor/audit.sh"
  echo "# README" > "$repo/README.md"
  echo "MIT" > "$repo/LICENSE"
  printf '.DS_Store\nscripts/ngwords.txt\n' > "$repo/.gitignore"
  mkdir -p "$repo/scripts"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$repo/scripts/ngwords.txt"
  cat > "$repo/core/assembly/install-main.sh" <<'EOF'
#!/usr/bin/env bash
EOF
  chmod +x "$repo/core/assembly/install-main.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
}

echo "=== 8. 悪性fixture(negative test): Personal配下へのフォルダ付きlinkをexport-public-vault.shとaudit.shが両方とも検出で一致する ==="
{
  WORK_TMP="$(mktemp -d)"
  VAULT_DIR="$WORK_TMP/vault"
  EXPORT_REPO="$WORK_TMP/export-repo"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Personal" "$VAULT_DIR/Knowledge" \
           "$VAULT_DIR/Decisions" "$VAULT_DIR/Projects" "$VAULT_DIR/Fragments" \
           "$VAULT_DIR/Explorations" "$VAULT_DIR/Blogs"
  echo "# dummy" > "$VAULT_DIR/Personal/career-private.md"
  cat > "$VAULT_DIR/Preferences/leak.md" <<'EOF'
---
date: 2026-01-01
---
参照: [[Personal/career-private]]
EOF
  mkdir -p "$EXPORT_REPO/scripts" "$EXPORT_REPO/ai-brain/data"
  cp -r "$REPO_ROOT/ai-brain/data/templates" "$EXPORT_REPO/ai-brain/data/templates"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$EXPORT_REPO/scripts/ngwords.txt"
  git -C "$EXPORT_REPO" init -q
  git -C "$EXPORT_REPO" config user.name test
  git -C "$EXPORT_REPO" config user.email test@example.invalid
  touch "$EXPORT_REPO/.gitignore"
  git -C "$EXPORT_REPO" add -A && git -C "$EXPORT_REPO" commit -q -m init

  export_rc=0
  run_export "$VAULT_DIR" "$EXPORT_REPO" || export_rc=$?
  assert_eq "export-public-vault.shはfail-fastでexit 1" "1" "$export_rc"
  # export-public-vault.shはfail-fastのためvault-public/自体が生成されない
  # （設計どおり）。audit.sh側の検出を同条件で確認するため、悪性リンクを含む
  # ステージング相当のvault-publicを別途組み立てて監査する。
  AUDIT_REPO="$WORK_TMP/audit-repo"
  make_audit_repo_skeleton "$AUDIT_REPO"
  mkdir -p "$AUDIT_REPO/ai-brain/data/vault-public/Preferences"
  cp "$VAULT_DIR/Preferences/leak.md" "$AUDIT_REPO/ai-brain/data/vault-public/Preferences/leak.md"
  git -C "$AUDIT_REPO" add -A && git -C "$AUDIT_REPO" commit -q -m init

  audit_rc=0
  run_audit_quick "$AUDIT_REPO" "$VAULT_DIR" || audit_rc=$?
  assert_eq "audit.sh --quickは監査失敗でexit 1" "1" "$audit_rc"

  rm -rf "$WORK_TMP"
}

echo "=== 9. 良性fixture: Personal linkが無ければexport-public-vault.shとaudit.shが両方ともクリア判定で一致する ==="
{
  WORK_TMP="$(mktemp -d)"
  VAULT_DIR="$WORK_TMP/vault"
  EXPORT_REPO="$WORK_TMP/export-repo"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Personal" "$VAULT_DIR/Knowledge" \
           "$VAULT_DIR/Decisions" "$VAULT_DIR/Projects" "$VAULT_DIR/Fragments" \
           "$VAULT_DIR/Explorations" "$VAULT_DIR/Blogs"
  echo "# dummy" > "$VAULT_DIR/Personal/career-private.md"
  cat > "$VAULT_DIR/Preferences/clean.md" <<'EOF'
---
date: 2026-01-01
---
無害な本文。Personalへの参照は無い。[[Knowledge/some-note]]は許容対象。
EOF
  mkdir -p "$EXPORT_REPO/scripts" "$EXPORT_REPO/ai-brain/data"
  cp -r "$REPO_ROOT/ai-brain/data/templates" "$EXPORT_REPO/ai-brain/data/templates"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$EXPORT_REPO/scripts/ngwords.txt"
  git -C "$EXPORT_REPO" init -q
  git -C "$EXPORT_REPO" config user.name test
  git -C "$EXPORT_REPO" config user.email test@example.invalid
  touch "$EXPORT_REPO/.gitignore"
  git -C "$EXPORT_REPO" add -A && git -C "$EXPORT_REPO" commit -q -m init

  export_rc=0
  run_export "$VAULT_DIR" "$EXPORT_REPO" || export_rc=$?
  assert_eq "良性のexportは成功" "0" "$export_rc"
  AUDIT_REPO="$WORK_TMP/audit-repo"
  make_audit_repo_skeleton "$AUDIT_REPO"
  cp -r "$EXPORT_REPO/ai-brain/data/vault-public" "$AUDIT_REPO/ai-brain/data/vault-public"
  git -C "$AUDIT_REPO" add -A && git -C "$AUDIT_REPO" commit -q -m init

  audit_rc=0
  run_audit_quick "$AUDIT_REPO" "$VAULT_DIR" || audit_rc=$?
  assert_eq "auditの判定" "$export_rc" "$audit_rc"
  rm -rf "$WORK_TMP"
}

echo "=== 11. personal_link_build_basename_denylist: find失敗時はfail-open化せず戻り値1を返す（Codex一次レビュー指摘・Major対応の直接検証） ==="
{
  source "$LIB"
  BINDIR="$(mktemp -d)"
  cat > "$BINDIR/find" <<'FINDEOF'
#!/bin/bash
exit 1
FINDEOF
  chmod +x "$BINDIR/find"
  VAULT_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Personal"
  echo x > "$VAULT_DIR/Personal/note.md"
  OUT="$(mktemp)"
  rc=0
  PATH="$BINDIR:$PATH" personal_link_build_basename_denylist "$VAULT_DIR" Personal "$OUT" || rc=$?
  assert_eq "find失敗時は戻り値1（denylist不完全の可能性を呼び出し元へ伝える）" "1" "$rc"
  rm -rf "$BINDIR" "$VAULT_DIR" "$OUT"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
