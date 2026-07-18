#!/usr/bin/env bash
# scripts/lib/personal-link-check.sh のユニットテスト（Personal リンク検査
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
LIB="$REPO_ROOT/scripts/lib/personal-link-check.sh"
EXPORT_SCRIPT="$REPO_ROOT/scripts/export-public-vault.sh"
AUDIT_SCRIPT="$REPO_ROOT/scripts/audit.sh"

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

# --- part (a): 共有関数の単体テスト ---

echo "=== 1. personal_link_folder_regex: 基本形 [[Personal/xxx]] にマッチする ==="
{
  source "$LIB"
  DIR="$(mktemp -d)"
  printf '[[Personal/career-private]] への参照\n' > "$DIR/note.md"
  pattern="$(personal_link_folder_regex "Personal")"
  rc=0
  rg -n -i -P "$pattern" "$DIR" >/dev/null || rc=$?
  assert_eq "フォルダ付きlinkにマッチする(rc=0)" "0" "$rc"
  rm -rf "$DIR"
}

echo "=== 2. personal_link_folder_regex: [[ 直後の空白・フォルダ名/スラッシュ間の空白・大文字小文字を許容する ==="
{
  source "$LIB"
  pattern="$(personal_link_folder_regex "Personal")"
  for variant in '[[Personal/x]]' '[[ Personal/x]]' '[[Personal /x]]' '[[personal/x]]' '[[PERSONAL/x]]'; do
    DIR="$(mktemp -d)"
    printf '%s\n' "$variant" > "$DIR/note.md"
    rc=0
    rg -n -i -P "$pattern" "$DIR" >/dev/null || rc=$?
    assert_eq "「${variant}」にマッチする" "0" "$rc"
    rm -rf "$DIR"
  done
}

echo "=== 3. personal_link_folder_regex: 無関係なフォルダへのlinkにはマッチしない ==="
{
  source "$LIB"
  DIR="$(mktemp -d)"
  printf '[[Knowledge/some-note]] への参照\n' > "$DIR/note.md"
  pattern="$(personal_link_folder_regex "Personal")"
  rc=0
  rg -n -i -P "$pattern" "$DIR" >/dev/null || rc=$?
  assert_eq "マッチしない(rc=1)" "1" "$rc"
  rm -rf "$DIR"
}

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
  content="$(cat "$OUT")"
  assert_contains "career-privateが含まれる" "$content" "career-private"
  assert_contains "devicesが含まれる" "$content" "devices"
  n_lines="$(grep -c . "$OUT")"
  assert_eq "Personal配下の2件のみ(Knowledgeは対象外)" "2" "$n_lines"
  rm -rf "$VAULT_DIR" "$OUT"
}

echo "=== 5. personal_link_build_basename_denylist: フォルダが存在しなくてもエラーにならない（空denylist） ==="
{
  source "$LIB"
  VAULT_DIR="$(mktemp -d)"
  OUT="$(mktemp)"
  personal_link_build_basename_denylist "$VAULT_DIR" Personal "$OUT"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "空denylist" "" "$(cat "$OUT")"
  rm -rf "$VAULT_DIR" "$OUT"
}

echo "=== 6. personal_link_build_basename_pattern_file: basename形式(pipe/heading/blockid)の全バリエーションを拾う ==="
{
  source "$LIB"
  DENYLIST="$(mktemp)"
  printf 'career-private\n' > "$DENYLIST"
  PATTERN_FILE="$(mktemp)"
  personal_link_build_basename_pattern_file "$DENYLIST" "$PATTERN_FILE"

  for variant in '[[career-private]]' '[[career-private|alias]]' '[[career-private | alias]]' \
                 '[[career-private#Heading]]' '[[career-private ^blockid]]' '[[ career-private]]'; do
    DIR="$(mktemp -d)"
    printf '%s\n' "$variant" > "$DIR/note.md"
    rc=0
    rg -n -i -P -f "$PATTERN_FILE" "$DIR" >/dev/null || rc=$?
    assert_eq "「${variant}」にマッチする" "0" "$rc"
    rm -rf "$DIR"
  done
  rm -f "$DENYLIST" "$PATTERN_FILE"
}

echo "=== 7. personal_link_build_basename_pattern_file: 正規表現特殊文字を含むbasenameでも壊れない ==="
{
  source "$LIB"
  DENYLIST="$(mktemp)"
  printf 'note.with(special)chars\n' > "$DENYLIST"
  PATTERN_FILE="$(mktemp)"
  personal_link_build_basename_pattern_file "$DENYLIST" "$PATTERN_FILE"
  DIR="$(mktemp -d)"
  printf '[[note.with(special)chars]]\n' > "$DIR/note.md"
  rc=0
  rg -n -i -P -f "$PATTERN_FILE" "$DIR" >/dev/null || rc=$?
  assert_eq "特殊文字を含むbasenameでもマッチする(rc=0)" "0" "$rc"
  rm -rf "$DENYLIST" "$PATTERN_FILE" "$DIR"
}

# --- part (b): export-public-vault.sh / audit.sh の検出結果一致テスト
#     （悪性fixture＝Personal link混入のnegative test を兼ねる） ---

# export-public-vault.sh を実行して exit code を返す。
run_export() {
  local vault="$1" repo="$2"
  VAULT="$vault" AIENV_REPO="$repo" "$EXPORT_SCRIPT" >"$WORK_TMP/export-stdout.log" 2>"$WORK_TMP/export-stderr.log"
}

# audit.sh を --quick で実行する（Personal リンクチェック自体は5番・quickでもスキップ
# されない項目のため --quick で十分。フルスキャンの履歴チェックは対象外にして
# gitleaks/履歴走査コストを避ける）。
run_audit_quick() {
  local repo="$1" vault="$2"
  REPO="$repo" VAULT="$vault" "$AUDIT_SCRIPT" --quick >"$WORK_TMP/audit-stdout.log" 2>"$WORK_TMP/audit-stderr.log"
}

# audit.sh 用のfixture repo骨格を作る（scripts/audit.sh + scripts/lib/personal-link-check.sh
# を実体コピーし、REPO/vault-public/Personal を用意する。export-public-vault.sh側の
# 出力(vault-public/)をそのままこのrepoへコピーして比較する）。
make_audit_repo_skeleton() {
  local repo="$1"
  mkdir -p "$repo/scripts/lib"
  cp "$AUDIT_SCRIPT" "$repo/scripts/audit.sh"
  cp "$LIB" "$repo/scripts/lib/personal-link-check.sh"
  chmod +x "$repo/scripts/audit.sh"
  echo "# README" > "$repo/README.md"
  echo "MIT" > "$repo/LICENSE"
  echo ".DS_Store" > "$repo/.gitignore"
  mkdir -p "$repo/scripts"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$repo/scripts/ngwords.txt"
  cat > "$repo/scripts/install-main.sh" <<'EOF'
#!/usr/bin/env bash
echo dummy
EOF
  chmod +x "$repo/scripts/install-main.sh"
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
  mkdir -p "$EXPORT_REPO/scripts"
  cp -r "$REPO_ROOT/scripts/templates" "$EXPORT_REPO/scripts/templates"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$EXPORT_REPO/scripts/ngwords.txt"
  git -C "$EXPORT_REPO" init -q
  git -C "$EXPORT_REPO" config user.name test
  git -C "$EXPORT_REPO" config user.email test@example.invalid
  touch "$EXPORT_REPO/.gitignore"
  git -C "$EXPORT_REPO" add -A && git -C "$EXPORT_REPO" commit -q -m init

  export_rc=0
  run_export "$VAULT_DIR" "$EXPORT_REPO" || export_rc=$?
  assert_eq "export-public-vault.shはfail-fastでexit 1" "1" "$export_rc"
  assert_contains "検出理由がフォルダ付きlink" "$(cat "$WORK_TMP/export-stderr.log")" \
    "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  # export-public-vault.shはfail-fastのためvault-public/自体が生成されない
  # （設計どおり）。audit.sh側の検出を同条件で確認するため、悪性リンクを含む
  # ステージング相当のvault-publicを別途組み立てて監査する。
  AUDIT_REPO="$WORK_TMP/audit-repo"
  make_audit_repo_skeleton "$AUDIT_REPO"
  mkdir -p "$AUDIT_REPO/vault-public/Preferences"
  cp "$VAULT_DIR/Preferences/leak.md" "$AUDIT_REPO/vault-public/Preferences/leak.md"
  git -C "$AUDIT_REPO" add -A && git -C "$AUDIT_REPO" commit -q -m init

  audit_rc=0
  run_audit_quick "$AUDIT_REPO" "$VAULT_DIR" || audit_rc=$?
  audit_out="$(cat "$WORK_TMP/audit-stdout.log")"
  assert_contains "audit.shもPersonalリンクを検出する(❌)" "$audit_out" "❌ Personal リンク（vault-public）"
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
  mkdir -p "$EXPORT_REPO/scripts"
  cp -r "$REPO_ROOT/scripts/templates" "$EXPORT_REPO/scripts/templates"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$EXPORT_REPO/scripts/ngwords.txt"
  git -C "$EXPORT_REPO" init -q
  git -C "$EXPORT_REPO" config user.name test
  git -C "$EXPORT_REPO" config user.email test@example.invalid
  touch "$EXPORT_REPO/.gitignore"
  git -C "$EXPORT_REPO" add -A && git -C "$EXPORT_REPO" commit -q -m init

  export_rc=0
  run_export "$VAULT_DIR" "$EXPORT_REPO" || export_rc=$?
  assert_eq "export-public-vault.shはexit 0（Personal linkなし）" "0" "$export_rc"

  AUDIT_REPO="$WORK_TMP/audit-repo"
  make_audit_repo_skeleton "$AUDIT_REPO"
  cp -r "$EXPORT_REPO/vault-public" "$AUDIT_REPO/vault-public"
  git -C "$AUDIT_REPO" add -A && git -C "$AUDIT_REPO" commit -q -m init

  audit_rc=0
  run_audit_quick "$AUDIT_REPO" "$VAULT_DIR" || audit_rc=$?
  audit_out="$(cat "$WORK_TMP/audit-stdout.log")"
  assert_contains "audit.shも0件判定で一致する" "$audit_out" "✅ Personal リンク（vault-public）: 0件"

  rm -rf "$WORK_TMP"
}

echo "=== 10. 悪性fixture(negative test・basename形式): フォルダ省略の[[career-private]]形式リンクをexport-public-vault.shとaudit.shが両方とも検出で一致する ==="
{
  WORK_TMP="$(mktemp -d)"
  VAULT_DIR="$WORK_TMP/vault"
  EXPORT_REPO="$WORK_TMP/export-repo"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Personal" "$VAULT_DIR/Knowledge" \
           "$VAULT_DIR/Decisions" "$VAULT_DIR/Projects" "$VAULT_DIR/Fragments" \
           "$VAULT_DIR/Explorations" "$VAULT_DIR/Blogs"
  echo "# dummy" > "$VAULT_DIR/Personal/career-private.md"
  # フォルダ修飾なしのbasename形式（[[career-private]]）を混入させる。
  cat > "$VAULT_DIR/Preferences/leak-basename.md" <<'EOF'
---
date: 2026-01-01
---
参照: [[career-private]]
EOF
  mkdir -p "$EXPORT_REPO/scripts"
  cp -r "$REPO_ROOT/scripts/templates" "$EXPORT_REPO/scripts/templates"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$EXPORT_REPO/scripts/ngwords.txt"
  git -C "$EXPORT_REPO" init -q
  git -C "$EXPORT_REPO" config user.name test
  git -C "$EXPORT_REPO" config user.email test@example.invalid
  touch "$EXPORT_REPO/.gitignore"
  git -C "$EXPORT_REPO" add -A && git -C "$EXPORT_REPO" commit -q -m init

  export_rc=0
  run_export "$VAULT_DIR" "$EXPORT_REPO" || export_rc=$?
  assert_eq "export-public-vault.shはbasename形式でもfail-fastでexit 1" "1" "$export_rc"
  assert_contains "検出理由がbasename形式link" "$(cat "$WORK_TMP/export-stderr.log")" \
    "Personal ノートへの wiki link（basename形式）を検出しました"

  AUDIT_REPO="$WORK_TMP/audit-repo"
  make_audit_repo_skeleton "$AUDIT_REPO"
  mkdir -p "$AUDIT_REPO/vault-public/Preferences"
  cp "$VAULT_DIR/Preferences/leak-basename.md" "$AUDIT_REPO/vault-public/Preferences/leak-basename.md"
  git -C "$AUDIT_REPO" add -A && git -C "$AUDIT_REPO" commit -q -m init

  audit_rc=0
  run_audit_quick "$AUDIT_REPO" "$VAULT_DIR" || audit_rc=$?
  audit_out="$(cat "$WORK_TMP/audit-stdout.log")"
  assert_contains "audit.shもbasename形式linkを検出する(❌)" "$audit_out" "❌ Personal リンク（vault-public）"
  assert_eq "audit.sh --quickは監査失敗でexit 1" "1" "$audit_rc"

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

echo "=== 12. find失敗時: export-public-vault.shはfail-fastし(set -e)、audit.shは「検査不能」としてNGにする(fail-openにしない・Codex一次レビュー指摘・Major対応) ==="
{
  WORK_TMP="$(mktemp -d)"
  VAULT_DIR="$WORK_TMP/vault"
  EXPORT_REPO="$WORK_TMP/export-repo"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Personal" "$VAULT_DIR/Knowledge" \
           "$VAULT_DIR/Decisions" "$VAULT_DIR/Projects" "$VAULT_DIR/Fragments" \
           "$VAULT_DIR/Explorations" "$VAULT_DIR/Blogs"
  echo "# dummy" > "$VAULT_DIR/Personal/career-private.md"
  echo "# clean" > "$VAULT_DIR/Preferences/clean.md"
  mkdir -p "$EXPORT_REPO/scripts"
  cp -r "$REPO_ROOT/scripts/templates" "$EXPORT_REPO/scripts/templates"
  printf 'NGWORD_ALPHA\nNGWORD_BETA\n' > "$EXPORT_REPO/scripts/ngwords.txt"
  git -C "$EXPORT_REPO" init -q
  git -C "$EXPORT_REPO" config user.name test
  git -C "$EXPORT_REPO" config user.email test@example.invalid
  touch "$EXPORT_REPO/.gitignore"
  git -C "$EXPORT_REPO" add -A && git -C "$EXPORT_REPO" commit -q -m init

  BINDIR="$(mktemp -d)"
  for t in rsync rg gitleaks git basename sort mkdir cat dirname mktemp; do
    p="$(command -v "$t" 2>/dev/null)"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$t"
  done
  cat > "$BINDIR/find" <<'FINDEOF'
#!/bin/bash
exit 1
FINDEOF
  chmod +x "$BINDIR/find"

  export_rc=0
  PATH="$BINDIR:$PATH" run_export "$VAULT_DIR" "$EXPORT_REPO" || export_rc=$?
  assert_eq "export-public-vault.shはfind失敗時にfail-fastでexit 1する（fail-openしない）" "1" "$export_rc"

  AUDIT_REPO="$WORK_TMP/audit-repo"
  make_audit_repo_skeleton "$AUDIT_REPO"
  mkdir -p "$AUDIT_REPO/vault-public/Preferences"
  echo "# clean" > "$AUDIT_REPO/vault-public/Preferences/clean.md"
  git -C "$AUDIT_REPO" add -A && git -C "$AUDIT_REPO" commit -q -m init

  audit_rc=0
  PATH="$BINDIR:$PATH" run_audit_quick "$AUDIT_REPO" "$VAULT_DIR" || audit_rc=$?
  audit_out="$(cat "$WORK_TMP/audit-stdout.log")"
  assert_contains "audit.shはfind失敗を「検査不能」としてNGにする（0件と誤判定しない）" "$audit_out" \
    "rg 実行エラーのため検査できません"
  assert_eq "audit.sh --quickは検査不能でexit 1" "1" "$audit_rc"

  rm -rf "$WORK_TMP" "$BINDIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
