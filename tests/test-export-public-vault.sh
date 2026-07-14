#!/usr/bin/env bash
# scripts/export-public-vault.sh のユニットテスト（設計§8「ユニット層」）。
#
# 実 Vault($HOME/Data/obsidian)・実 GitHub には一切依存しない。
# VAULT/AIENV_REPO を環境変数で毎回ダミーのfixtureディレクトリへ差し替えて
# export-public-vault.sh をそのまま実行し、正常系/異常系の exit code と
# 生成物を検証する。
#
# 実行方法: bash tests/test-export-public-vault.sh
#
# 注意: セットアップ（mktemp/git init 等）自体が失敗した場合は、目的と無関係な
# 失敗を「異常系を正しく検知できた」と誤ってpass扱いしないよう、スクリプト全体を
# errexit で即中断させる（Codexレビュー指摘・Major）。
#
# public浄化について（2026-07-08 設計判断）: このテストファイル自体が将来
# public repo の履歴に入る想定のため、①NGワードの実データ（ngwords.txtに定義される
# 呼称の表記ゆれ等）はここに書かず、NGWORDS_FILE環境変数でダミー語
# （NGWORD_ALPHA/NGWORD_BETA）に差し替えてテストする ②gitleaks検知用のダミー
# GitHub PATは静的ファイルに完全な形で残さず、実行時に文字列連結で組み立てる
# （regexベースの静的スキャナが単純な文字列一致で誤検知しないようにするため）。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/export-public-vault.sh"

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

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# exit code だけでなく、意図した理由で失敗したかを stderr メッセージで確認する
# （exit 1 が別の理由＝セットアップ不備等で出ていないことを保証するため。Codexレビュー指摘）
assert_stderr_has() {
  local desc="$1" work="$2" needle="$3"
  if grep -q -- "$needle" "$work/stderr.log" 2>/dev/null; then
    pass "$desc"
  else
    fail_case "$desc (stderr に \"$needle\" が含まれない。実際のstderr: $(cat "$work/stderr.log" 2>/dev/null))"
  fi
}

# report-only チェック（3-e）は exit 0 のまま stdout にレポート行を出す仕様
# （2026-07-08 本人決定「案A」）なので、stdout の内容を確認する。
assert_stdout_has() {
  local desc="$1" work="$2" needle="$3"
  if grep -q -- "$needle" "$work/stdout.log" 2>/dev/null; then
    pass "$desc"
  else
    fail_case "$desc (stdout に \"$needle\" が含まれない。実際のstdout: $(cat "$work/stdout.log" 2>/dev/null))"
  fi
}

# ダミー Vault fixture を1つ作る（各テストケースで使い回す最小構成）。
# 呼び出し元が VAULT_DIR を用意してから呼ぶ。
make_base_vault() {
  local vault="$1"
  mkdir -p "$vault/Preferences"
  mkdir -p "$vault/Personal" "$vault/Knowledge" "$vault/Decisions" \
           "$vault/Projects" "$vault/Fragments" "$vault/Explorations" "$vault/Blogs"

  cat > "$vault/Preferences/sample-pref.md" <<'EOF'
---
date: 2026-01-01
tags: [test]
project: test
---

# サンプル

無害な運用ルールのサンプル本文。
EOF

  # private フォルダにも中身を置く（rsync 対象外/骨格化されることを確認するため）
  cat > "$vault/Personal/career-private.md" <<'EOF'
---
date: 2026-01-01
tags: [test]
---

# 経歴（テスト用private）
EOF
  cat > "$vault/Knowledge/some-knowledge.md" <<'EOF'
---
date: 2026-01-01
tags: [test]
---

# 技術知見サンプル
EOF
  cat > "$vault/Blogs/published-sample.md" <<'EOF'
# 公開済み記事サンプル
EOF
}

# export-public-vault.sh を実行して exit code を返す（VAULT/AIENV_REPO 上書き。
# 第3引数（省略可）は NGWORDS_FILE の差し替え＝NGワード系テストがダミー語
# ファイルを使うため）。
run_export() {
  local vault="$1" repo="$2" ngwords="${3:-}"
  if [[ -n "$ngwords" ]]; then
    VAULT="$vault" AIENV_REPO="$repo" NGWORDS_FILE="$ngwords" \
      "$SCRIPT" >"$repo/../stdout.log" 2>"$repo/../stderr.log"
  else
    VAULT="$vault" AIENV_REPO="$repo" "$SCRIPT" >"$repo/../stdout.log" 2>"$repo/../stderr.log"
  fi
}

# ダミーのNGワードファイルを作る（NGWORD_ALPHA/NGWORD_BETA の2語。ngwords.txtの
# 実データはテストファイルに書かない＝public履歴に入れないため）。
make_dummy_ngwords() {
  local f
  f="$(mktemp)"
  printf 'NGWORD_ALPHA\nNGWORD_BETA' > "$f"
  printf '%s' "$f"
}

# git log --oneline はコミットが1つも無いrepoでは非ゼロ終了する（fatal）ため、
# pipefail/errexit下でも安全にコミット数を数えられるようにする。
count_commits() {
  local repo="$1"
  git -C "$repo" log --oneline 2>/dev/null | wc -l | tr -d ' ' || true
}

new_repo() {
  # AIENV_REPO fixture: git init + commit 用の identity をローカルに設定しておく
  # （sandbox/CI の global git config に依存しないため。実運用では既存の global 設定を使う）。
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "export-public-vault-test"
  git -C "$repo" config user.email "test@example.invalid"
}

echo "=== 1. 正常系: public のみコピー・private は空+README ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "exit code 0" "0" "$rc"

  assert_true "Preferences/sample-pref.md がコピーされている" \
    "$([[ -f "$REPO_DIR/vault-public/Preferences/sample-pref.md" ]] && echo 1 || echo 0)"

  for dir in Personal Knowledge Decisions Projects Fragments Explorations Blogs; do
    n=$(find "$REPO_DIR/vault-public/$dir" -mindepth 1 | wc -l | tr -d ' ')
    assert_eq "$dir はREADME.mdのみ（ファイル数1）" "1" "$n"
    assert_true "$dir/README.md が存在する" \
      "$([[ -f "$REPO_DIR/vault-public/$dir/README.md" ]] && echo 1 || echo 0)"
  done

  assert_true "Personal/career-private.md はコピーされていない（骨格のみ）" \
    "$([[ ! -f "$REPO_DIR/vault-public/Personal/career-private.md" ]] && echo 1 || echo 0)"

  commits=$(count_commits "$REPO_DIR")
  assert_eq "commit が1つ作られている" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 2a. private link（フォルダ付き形式）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

うっかり private へのリンク: [[Personal/career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "フォルダ付きprivate linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=フォルダ付きlink検出" "$WORK" "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  commits=$(count_commits "$REPO_DIR")
  assert_eq "commit されていない" "0" "$commits"

  rm -rf "$WORK"
}

# --- tester独立検証で発見された2件目のMajor欠陥の回帰テスト（2026-07-08）:
#     `[[` 直後・フォルダ名とスラッシュの間に空白があると検出をすり抜けていた ---

echo "=== 2a2. private link（フォルダ付き形式・[[直後に空白）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

[[直後に空白のうっかりリンク: [[ Personal/career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "[[直後空白のフォルダ付きprivate linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=[[直後空白フォルダ付きlink検出" "$WORK" "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2a3. private link（フォルダ付き形式・フォルダ名とスラッシュの間に空白）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

フォルダ名とスラッシュの間に空白のうっかりリンク: [[Personal /career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "スラッシュ前空白のフォルダ付きprivate linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=スラッシュ前空白フォルダ付きlink検出" "$WORK" "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  rm -rf "$WORK"
}

# --- 大文字小文字非依存化の回帰テスト（2026-07-08）:
#     macOSはcase-insensitiveなファイルシステムのため、フォルダ名/basenameを
#     小文字・大文字化してもObsidianはほぼ確実に実リンクとして解決してしまう ---

echo "=== 2a4. private link（フォルダ付き形式・小文字 personal/）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

小文字フォルダ名のうっかりリンク: [[personal/career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "小文字personal/フォルダ付きprivate linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=小文字フォルダ付きlink検出" "$WORK" "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2a5. private link（フォルダ付き形式・全大文字 PERSONAL/）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

全大文字フォルダ名のうっかりリンク: [[PERSONAL/career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "全大文字PERSONAL/フォルダ付きprivate linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=全大文字フォルダ付きlink検出" "$WORK" "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2b. private link（basename形式・フォルダ省略）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

フォルダを省略したうっかりリンク: [[career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "basename形式private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2c. private link（frontmatter内・basename形式）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat > "$VAULT_DIR/Preferences/related-pref.md" <<'EOF'
---
date: 2026-01-01
tags: [test]
related:
  - "[[career-private]]"
---

# frontmatter経由のうっかりリンク
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "frontmatter内private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=frontmatter経由basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2d. private link（basename + 見出し参照 #Heading）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

見出し参照のうっかりリンク: [[career-private#経歴]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "見出し参照private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=見出し参照basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2e. private link（basename + ブロック参照 ^blockid）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

ブロック参照のうっかりリンク: [[career-private^abcd12]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "ブロック参照private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=ブロック参照basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

# --- tester独立検証で発見されたMajor欠陥の回帰テスト（2026-07-08）:
#     区切り文字（| # ^）の直前に空白があると検出をすり抜けていた ---

echo "=== 2e2. private link（basename + 空白入りpipe記法 ' | alias'）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

空白入りpipe記法のうっかりリンク: [[career-private | 経歴エイリアス]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "空白入りpipe記法private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=空白入りpipe basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2e3. private link（basename + 空白入り見出し参照 ' # 見出し'）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

空白入り見出し参照のうっかりリンク: [[career-private # 経歴]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "空白入り見出し参照private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=空白入り見出し basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2e4. private link（basename + 空白入りブロック参照 ' ^blockid'）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

空白入りブロック参照のうっかりリンク: [[career-private ^abcd12]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "空白入りブロック参照private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=空白入りブロック basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2e5. private link（basename形式・[[直後に空白）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

[[直後に空白のうっかりリンク（basename）: [[ career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "[[直後空白のbasename private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=[[直後空白basename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2e6. private link（basename形式・大文字小文字違い Career-Private）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

大文字小文字違いのうっかりリンク: [[Career-Private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "大文字小文字違いbasename private linkで exit 1" "1" "$rc"
  assert_stderr_has "理由=大文字小文字違いbasename link検出" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2f. denylistに無い無害なwiki linkは誤検知しない（exit 0） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  # "career-private" の前方一致だが別ノート名。basenameの完全一致のみ検出することを確認する
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

無害なリンク（前方一致だが別名）: [[career-private-archive]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "denylist前方一致の別名は誤検知せずexit 0" "0" "$rc"

  rm -rf "$WORK"
}

echo "=== 2g. Knowledge へのlink（フォルダ付き）は許容＝exit 0だがレポートに出る（2026-07-08案A） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

外部脳のSSOT参照: [[Knowledge/some-knowledge]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "Knowledgeへのフォルダ付きlinkはexit 0（fail-fast対象外）" "0" "$rc"
  assert_stdout_has "Knowledgeへのlinkがレポートに出る" "$WORK" "linkreport"
  assert_stdout_has "レポート内容にKnowledge/some-knowledgeが含まれる" "$WORK" "Knowledge/some-knowledge"

  commits=$(count_commits "$REPO_DIR")
  assert_eq "レポートのみでもcommitはされる" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 2h. Decisions へのlink（basename形式・フォルダ省略）は許容＝exit 0だがレポートに出る ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  mkdir -p "$VAULT_DIR/Decisions"
  cat > "$VAULT_DIR/Decisions/2026-01-01-example-decision.md" <<'EOF'
---
date: 2026-01-01
tags: [test]
---

# サンプル決定
EOF
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

フォルダ省略の意思決定参照: [[2026-01-01-example-decision]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "Decisionsへのbasename linkはexit 0（fail-fast対象外）" "0" "$rc"
  assert_stdout_has "Decisionsへのlinkがレポートに出る" "$WORK" "linkreport"
  assert_stdout_has "レポート内容に2026-01-01-example-decisionが含まれる" "$WORK" "2026-01-01-example-decision"

  rm -rf "$WORK"
}

echo "=== 2h2. Knowledge への空白入りpipe記法basename linkも許容＝exit 0だがレポートに出る（回帰） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

空白入りpipe記法での参照: [[some-knowledge | 表記]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "Knowledgeへの空白入りbasename linkもexit 0" "0" "$rc"
  assert_stdout_has "空白入りbasename linkもレポートに出る" "$WORK" "linkreport"
  assert_stdout_has "レポート内容にsome-knowledgeが含まれる" "$WORK" "some-knowledge"

  rm -rf "$WORK"
}

echo "=== 2h3. Knowledge への[[直後空白のフォルダ付きlinkも許容＝exit 0だがレポートに出る（回帰） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

[[直後に空白の参照: [[ Knowledge/some-knowledge]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "Knowledgeへの[[直後空白フォルダ付きlinkもexit 0" "0" "$rc"
  assert_stdout_has "[[直後空白フォルダ付きlinkもレポートに出る" "$WORK" "linkreport"
  assert_stdout_has "レポート内容にKnowledge/some-knowledgeが含まれる(2)" "$WORK" "Knowledge/some-knowledge"

  rm -rf "$WORK"
}

echo "=== 2h4. 小文字 knowledge/ へのlinkも許容＝exit 0だがレポートに出る（回帰） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

小文字フォルダ名での参照: [[knowledge/some-knowledge]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "小文字knowledge/へのlinkもexit 0" "0" "$rc"
  assert_stdout_has "小文字knowledge/linkもレポートに出る" "$WORK" "linkreport"
  assert_stdout_has "レポート内容にknowledge/some-knowledgeが含まれる" "$WORK" "knowledge/some-knowledge"

  rm -rf "$WORK"
}

echo "=== 2i. private link皆無の場合はレポートが0件と明示される ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "リンク無しならexit 0" "0" "$rc"
  assert_stdout_has "レポート0件が明示される" "$WORK" "private link は0件"

  rm -rf "$WORK"
}

echo "=== 3a. NGワード（ダミー語 NGWORD_ALPHA）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  NGWORDS_DUMMY="$(make_dummy_ngwords)"
  printf '\nNGWORD_ALPHA はこう考える。\n' >> "$VAULT_DIR/Preferences/sample-pref.md"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" "$NGWORDS_DUMMY" || rc=$?
  assert_eq "ダミーNGワード(ALPHA)で exit 1" "1" "$rc"
  assert_stderr_has "理由=NGワード検出" "$WORK" "NGワードを検出しました"

  rm -f "$NGWORDS_DUMMY"
  rm -rf "$WORK"
}

echo "=== 3b. NGワード（ダミー語 NGWORD_BETA・表記ゆれ相当）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  NGWORDS_DUMMY="$(make_dummy_ngwords)"
  printf '\nNGWORD_BETA と呼ばれることもある。\n' >> "$VAULT_DIR/Preferences/sample-pref.md"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" "$NGWORDS_DUMMY" || rc=$?
  assert_eq "ダミーNGワード(BETA・表記ゆれ相当)で exit 1" "1" "$rc"
  assert_stderr_has "理由=NGワード検出（表記ゆれ相当）" "$WORK" "NGワードを検出しました"

  rm -f "$NGWORDS_DUMMY"
  rm -rf "$WORK"
}

echo "=== 3c. 「takumi009」は対象外（ダミー語リストにも無いので素通りしてexit 0） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  NGWORDS_DUMMY="$(make_dummy_ngwords)"
  printf '\nGitHubアカウントは takumi009 です。\n' >> "$VAULT_DIR/Preferences/sample-pref.md"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" "$NGWORDS_DUMMY" || rc=$?
  assert_eq "「takumi009」はNG対象外でexit 0" "0" "$rc"

  rm -f "$NGWORDS_DUMMY"
  rm -rf "$WORK"
}

echo "=== 4. シークレット混入で gitleaks が検知し exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  # ダミーのGitHub PAT形式トークンを実行時に組み立てる（このテストファイルが
  # 将来public repoに入る想定のため、完全な形の文字列を静的に残さない）。
  dummy_token=$(printf '%s%s' 'ghp_' 'NbrnTP3fAbnFbmOHnKYaXRvj7uff0LYTH8xI')
  printf '\ngithub_token = "%s"\n' "$dummy_token" >> "$VAULT_DIR/Preferences/sample-pref.md"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "ダミーGitHubトークンでgitleaks検知しexit 1" "1" "$rc"
  assert_stderr_has "理由=gitleaks検出" "$WORK" "gitleaks がシークレットの疑いを検出しました"

  rm -rf "$WORK"
}

echo "=== 5. 冪等性: 2回連続実行しても2回目は無変更commitなしでexit 0 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  rc2=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc2=$?
  assert_eq "1回目 exit 0" "0" "$rc"
  assert_eq "2回目 exit 0" "0" "$rc2"

  commits=$(count_commits "$REPO_DIR")
  assert_eq "変更が無ければcommitは1つのまま" "1" "$commits"

  rm -rf "$WORK"
}

echo "=== 6. チェック失敗時に vault-public/ は本番から一切変更されない（ステージング昇格順序） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"

  # まず正常系を1回走らせ、「既に成功済みexportがある」本番状態（ベースライン）を作る。
  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "ベースラインexportはexit 0" "0" "$rc"

  BASELINE_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
  SNAPSHOT_DIR="$WORK/vault-public-snapshot"
  cp -R "$REPO_DIR/vault-public" "$SNAPSHOT_DIR"

  # ここから private link を混入させ、機械チェックを意図的に失敗させる（2aと同種の欠陥）。
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

うっかり private へのリンク（ステージング安全性テスト用）: [[Personal/career-private]]
EOF

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "チェック失敗でexit 1" "1" "$rc"
  # 意図した理由（Personal link検出）で失敗したことも確認する（Codexレビュー指摘・Minor:
  # 別の理由で早期失敗しても vault-public が無変更なら誤ってpassしてしまう抜け穴を塞ぐ）。
  assert_stderr_has "理由=フォルダ付きprivate link検出（ステージング安全性テスト）" "$WORK" \
    "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  # 「チェック失敗時に vault-public/ が変更されていない」を直接アサートする（設計①の受入条件）。
  diff_out="$(diff -r "$SNAPSHOT_DIR" "$REPO_DIR/vault-public" 2>&1 || true)"
  assert_eq "vault-public はベースラインと完全一致（無変更）" "" "$diff_out"

  git_status="$(git -C "$REPO_DIR" status --porcelain -- vault-public)"
  assert_eq "git status(vault-public)も無変更" "" "$git_status"

  new_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  assert_eq "HEADのcommitも変わっていない" "$BASELINE_HEAD" "$new_head"

  # ステージング領域（.export-tmp.*）がEXIT trapで掃除され、残骸が残っていないことも確認する。
  leftover=$(find "$REPO_DIR" -maxdepth 1 -name '.export-tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "ステージング領域の残骸が無い" "0" "$leftover"

  rm -rf "$WORK"
}

echo "=== 6b. vault-public/ が未作成（初回実行前）の状態でチェック失敗しても作成されない ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

うっかり private へのリンク（初回チェック失敗テスト用）: [[Personal/career-private]]
EOF
  new_repo "$REPO_DIR"
  # vault-public/ はまだ一度も生成していない（本テストの主眼: mkdir すら本番側に残さないこと）。

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_eq "初回でチェック失敗はexit 1" "1" "$rc"
  # 意図した理由（Personal link検出）で失敗したことも確認する（Codexレビュー指摘・Minor:
  # 別の理由で早期失敗しても vault-public/ が未作成なら誤ってpassしてしまう抜け穴を塞ぐ）。
  assert_stderr_has "理由=フォルダ付きprivate link検出（初回チェック失敗テスト）" "$WORK" \
    "Personal フォルダへの wiki link（フォルダ付き）を検出しました"
  assert_true "vault-public/ 自体が作られていない（空ディレクトリも残らない）" \
    "$([[ ! -e "$REPO_DIR/vault-public" ]] && echo 1 || echo 0)"

  # ステージング領域（.export-tmp.*）も残らないことを確認する（trap の初回失敗ケース検証）。
  leftover=$(find "$REPO_DIR" -maxdepth 1 -name '.export-tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "初回失敗時もステージング領域の残骸が無い" "0" "$leftover"

  rm -rf "$WORK"
}

# register_tmp のサブシェル伝播バグ回帰テスト（2026-07-14）:
# `VAR="$(register_tmp)"` はコマンド置換＝サブシェル実行のため、関数内での
# TMP_FILES+=() が親シェルへ伝播せず cleanup() が常に空配列を見ていた
# （mktemp の一時ファイルが仕様に反して毎回残留するバグ）。
# register_tmp の mktemp には識別用プレフィックス（-t export-public-vault）を
# 付けているので、既定のシステム一時領域を実行前後でスキャンして残留の有無を確認する。
#
# 注意（Codexレビュー指摘・Minor）: macOS(BSD)の mktemp は `-t` 使用時も TMPDIR
# 環境変数を無視し、常に確定的なユーザー毎の既定一時領域を使う（テスト側で専用
# TMPDIR に隔離できない）。そのため「件数」ではなく「ファイル名の集合」を
# 実行前後でdiffし、このテスト実行中に増えて消えなかったファイルだけを検出する
# （他プロセスが同時に無関係なファイルを作成・削除しても誤検知しにくい）。
discover_mktemp_dir() {
  local probe dir
  probe="$(mktemp -t export-public-vault-probe)"
  dir="$(dirname "$probe")"
  rm -f "$probe"
  printf '%s' "$dir"
}

snapshot_tmp() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name 'export-public-vault.*' 2>/dev/null | sort
}

echo "=== 7. register_tmp: 正常系実行後にmktempの一時ファイルが残らない（TMP_FILES伝播バグ回帰） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"
  MKTMP_DIR="$(discover_mktemp_dir)"

  before=$(snapshot_tmp "$MKTMP_DIR")
  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  after=$(snapshot_tmp "$MKTMP_DIR")
  new_leftover=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))

  assert_eq "正常系 exit 0" "0" "$rc"
  assert_eq "register_tmpのmktemp一時ファイルが今回の実行で増えたまま残っていない（正常系）" "" "$new_leftover"

  rm -rf "$WORK"
}

echo "=== 7b. register_tmp: fail-fast経路（異常終了）でも一時ファイルが残らない ==="
{
  # basename形式のprivate link（3-b・register_tmp呼び出し後にfailする経路）を使う。
  # フォルダ付き形式（3-a）は register_tmp を1つも呼ばずにfailするため、
  # 「register_tmp呼び出し済みの一時ファイルがcleanup()で確実に消える」ことの
  # 検証にならない（Codexレビュー指摘で発覚・basename形式に修正）。
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

うっかり private へのリンク（basename形式・一時ファイル残留テスト用）: [[career-private]]
EOF
  new_repo "$REPO_DIR"
  MKTMP_DIR="$(discover_mktemp_dir)"

  before=$(snapshot_tmp "$MKTMP_DIR")
  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  after=$(snapshot_tmp "$MKTMP_DIR")
  new_leftover=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))

  assert_eq "fail-fastでexit 1" "1" "$rc"
  assert_stderr_has "理由=basename link検出（register_tmp呼び出し後にfail）" "$WORK" \
    "Personal ノートへの wiki link（basename形式）を検出しました"
  assert_eq "register_tmpのmktemp一時ファイルが今回の実行で増えたまま残っていない（異常系）" "" "$new_leftover"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
