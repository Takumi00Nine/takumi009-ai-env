#!/usr/bin/env bash
# ai-brain/executor/export-public-vault.sh のユニットテスト（設計§8「ユニット層」）。
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
SCRIPT="$REPO_ROOT/ai-brain/executor/export-public-vault.sh"

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
assert_rejected() {
  local desc="$1" work="$2" needle="$3"
  if [ "$rc" -eq 1 ] && grep -q -- "$needle" "$work/stderr.log" 2>/dev/null; then
    pass "$desc"
  else
    fail_case "$desc (stderr に \"$needle\" が含まれない。実際のstderr: $(cat "$work/stderr.log" 2>/dev/null))"
  fi
}

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

make_dummy_ngwords() {
  local f
  f="$(mktemp)"
  printf 'NGWORD_ALPHA\nNGWORD_BETA' > "$f"
  printf '%s' "$f"
}

# 既定のNGWORDS_FILE（本テストの全ケースが個別指定しない限りこれを使う）。
# ⚠️ 2026-08-30 環境依存欠陥の修正（追加1対応）: 従来はrun_export()の第3引数を
# 省略するとNGWORDS_FILEを一切渡さず、export-public-vault.sh側の既定値
# （$SCRIPT_DIR/ngwords.txt）へフォールバックしていた。この既定パスは
# .gitignore対象（scripts/ngwords.txt）の私的資産（実運用ではprivateリポジトリ
# へのsymlinkとして手動設置される）であり、リポジトリを新規clone/checkout・
# git worktreeした環境には存在しない。開発者の主作業ディレクトリ
# （~/Workspace/Tools/takumi009-ai-env）にたまたま手動設置済みだったため、そこで実行する
# 限りは気づかず全緑に見えていたが、tester環境（隔離worktree）やCI相当の
# クリーンチェックアウトでは「ngwords.txt が見つかりません」でexport-public-
# vault.sh自体がFAILし、ほぼ全テストが道連れで失敗していた（本体側の
# fail-closed挙動＝ngwords.txt無しなら止める、は本番の安全設計として正しい
# ため変更しない。直すのはテスト側＝「実 Vault・実 GitHubには一切依存しない」
# という本ファイル冒頭の設計方針どおり、テスト自身が使うNGワードファイルは
# テスト自身が用意する）。
DEFAULT_NGWORDS_FILE="$(make_dummy_ngwords)"
trap 'rm -f "$DEFAULT_NGWORDS_FILE"' EXIT

# export-public-vault.sh を実行して exit code を返す（VAULT/AIENV_REPO 上書き。
# 第3引数（省略可）は NGWORDS_FILE の差し替え＝NGワード系テストがダミー語
# ファイルを使うため。省略時もDEFAULT_NGWORDS_FILEを渡し、実行環境に存在する
# かもしれない私的ngwords.txtには依存しない）。
run_export() {
  local vault="$1" repo="$2" ngwords="${3:-$DEFAULT_NGWORDS_FILE}"
  VAULT="$vault" AIENV_REPO="$repo" NGWORDS_FILE="$ngwords" \
    "$SCRIPT" >"$repo/../stdout.log" 2>"$repo/../stderr.log"
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
  assert_true "Preferences/sample-pref.md がコピーされている" \
    "$([ "$rc" -eq 0 ] && [ -f "$REPO_DIR/ai-brain/data/vault-public/Preferences/sample-pref.md" ] && echo 1 || echo 0)"

  private_files="$(find "$REPO_DIR/ai-brain/data/vault-public" -type f ! -name README.md ! -path '*/Preferences/*')"
  assert_true "privateはREADMEの骨格だけ" \
    "$([ -z "$private_files" ] && [ -f "$REPO_DIR/ai-brain/data/vault-public/Personal/README.md" ] && echo 1 || echo 0)"

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

うっかり private へのリンク: [[　personal /career-private]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_rejected "フォルダ付きリンク（空白・大小文字の抜け道）を拒否" "$WORK" "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  rm -rf "$WORK"
}

echo "=== 2b. private link（basename形式・フォルダ省略）で exit 1 ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

フォルダを省略したうっかりリンク: [[ career-private | alias]]
EOF
  new_repo "$REPO_DIR"

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_rejected "basenameリンク（空白・別名）を拒否" "$WORK" "Personal ノートへの wiki link（basename形式）を検出しました"

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
  assert_true "Knowledgeへのlinkがレポートに出る" \
    "$([ "$rc" -eq 0 ] && grep -q linkreport "$WORK/stdout.log" && echo 1 || echo 0)"
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
  assert_rejected "NGワードを拒否" "$WORK" "NGワードを検出しました"

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
  assert_rejected "シークレットを拒否" "$WORK" "gitleaks がシークレットの疑いを検出しました"

  rm -rf "$WORK"
}

echo "=== 6. チェック失敗時に ai-brain/data/vault-public/ は本番から一切変更されない（ステージング昇格順序） ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"

  # まず正常系を1回走らせ、「既に成功済みexportがある」本番状態（ベースライン）を作る。
  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  [ "$rc" -eq 0 ] || exit 1

  BASELINE_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
  SNAPSHOT_DIR="$WORK/vault-public-snapshot"
  cp -R "$REPO_DIR/ai-brain/data/vault-public" "$SNAPSHOT_DIR"

  # ここから private link を混入させ、機械チェックを意図的に失敗させる（2aと同種の欠陥）。
  cat >> "$VAULT_DIR/Preferences/sample-pref.md" <<'EOF'

うっかり private へのリンク（ステージング安全性テスト用）: [[Personal/career-private]]
EOF

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  assert_rejected "理由=フォルダ付きprivate link検出（ステージング安全性テスト）" "$WORK" \
    "Personal フォルダへの wiki link（フォルダ付き）を検出しました"

  # 「チェック失敗時に ai-brain/data/vault-public/ が変更されていない」を直接アサートする（設計①の受入条件）。
  diff_out="$(diff -r "$SNAPSHOT_DIR" "$REPO_DIR/ai-brain/data/vault-public" 2>&1 || true)"
  assert_eq "ai-brain/data/vault-public はベースラインと完全一致（無変更）" "" "$diff_out"
  new_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  assert_eq "HEADのcommitも変わっていない" "$BASELINE_HEAD" "$new_head"

  rm -rf "$WORK"
}

echo "=== 9. PA-2: ai-brain/data/vault-public 以外を stage した状態で実行しても commit は ai-brain/data/vault-public/ 配下のみ ==="
{
  WORK="$(mktemp -d)"
  VAULT_DIR="$WORK/vault"
  REPO_DIR="$WORK/repo"
  make_base_vault "$VAULT_DIR"
  new_repo "$REPO_DIR"

  # ai-brain/data/vault-public/ と無関係なファイルを stage したままにしておく。
  echo "unrelated change" > "$REPO_DIR/other-file.txt"
  git -C "$REPO_DIR" add other-file.txt

  rc=0
  run_export "$VAULT_DIR" "$REPO_DIR" || rc=$?
  [ "$rc" -eq 0 ] || exit 1

  # このコミットは repo 最初の commit（親を持たない root commit）なので、
  # diff-tree で親との差分を出すには --root が要る（無いと空になる）。
  changed_paths="$(git -C "$REPO_DIR" diff-tree --no-commit-id --name-only -r --root HEAD)"
  non_vault_public=$(printf '%s\n' "$changed_paths" | grep -v '^ai-brain/data/vault-public/' || true)
  assert_eq "コミットの変更パスは ai-brain/data/vault-public/ 配下のみ" "" "$non_vault_public"
  assert_true "ai-brain/data/vault-public/ 配下の変更が含まれている" \
    "$(printf '%s\n' "$changed_paths" | grep -q '^ai-brain/data/vault-public/' && echo 1 || echo 0)"

  staged_status="$(git -C "$REPO_DIR" status --porcelain -- other-file.txt)"
  assert_eq "stage したままの other-file.txt は index に残っている（A  other-file.txt）" \
    "A  other-file.txt" "$staged_status"

  rm -rf "$WORK"
}
echo "=== 検査設定欠落はfail-close ==="
WORK="$(mktemp -d)"
make_base_vault "$WORK/vault"
new_repo "$WORK/repo"
rc=0
run_export "$WORK/vault" "$WORK/repo" "$WORK/missing-ngwords" || rc=$?
assert_true "NG語設定なしでは公開物を作らない" \
  "$([ "$rc" -ne 0 ] && [ ! -e "$WORK/repo/ai-brain/data/vault-public" ] && echo 1 || echo 0)"
rm -rf "$WORK"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
