#!/usr/bin/env bash
# Vault(private, $HOME/Data/obsidian) の public 指定フォルダを
# takumi009-ai-env リポジトリの vault-public/ へスナップショット・コピーする。
#
# 詳細は README.md「vault-public/ について」節を参照。
# 方針: Git 履歴を Vault 側と共有しない「スナップショット・コピー」。
#
# 実行順序（**チェック通過前は本番の vault-public/ を一切変更しない**。
# 「最後の砦」である機械チェックに、汚染済み出力が漏れ残る穴を作らないため）:
#   0. ステージング領域（AIENV_REPO 直下の一時ディレクトリ）を用意する
#   1. public フォルダを rsync -a --delete でステージングへ丸ごとコピー
#   2. private 指定フォルダを「空フォルダ + README.md」の骨格としてステージングへ再現
#      （.obsidian/ は骨格再現も含め完全に対象外）
#   3. 機械チェック（ステージングに対して実行。fail-fast・1件でも検知したら exit 1・
#      本番 vault-public/ は無変更のまま・push もしない）
#      a. Personal フォルダへの wiki link（フォルダ付き形式）
#      b. Personal ノートへの wiki link（basename 形式・denylist は Personal 配下から自動生成）
#      c. NGワード（呼称の表記ゆれ等。ngwords.txt）
#      d. シークレット（gitleaks）
#      注記（2026-07-08 本人決定「案A」）: Preferences 28ファイル中25が
#      Knowledge/Decisions 等へのリンクを持つ（延べ90本超＝外部脳のSSOT構造そのもの）ため、
#      fail-fast対象は個人情報寄りの Personal のみに縮小する。Knowledge/Decisions/Projects/
#      Fragments/Explorations への wiki link は許容し、失敗させない代わりに
#      「public側でリンク切れになるリンク一覧」を3-eでレポート表示する（exit 0のまま）。
#   e. Personal 以外の private フォルダ（Knowledge/Decisions/Projects/Fragments/
#      Explorations）への wiki link をレポートのみ表示（fail-fastしない）
#   4. 全チェック通過後にのみ、ステージングを本番 vault-public/ へ rsync -a --delete で
#      昇格する（このステップより前に失敗すれば本番は一切触られない）
#   5. 昇格後にのみ git add/commit（AIENV_REPO 側の新規コミット。push はしない＝別の明示コマンド）
#
# ステージング領域はスクリプト終了時（成功・失敗いずれも）に必ず削除する（EXIT trap）。
# git の追跡対象にならないよう .gitignore に `.export-tmp.*` を追加済み。
#
# パスはすべて $HOME 相対（VAULT・AIENV_REPO・NGWORDS_FILE は環境変数で上書き可＝
# ユニットテスト用。本番実行時は既定値のまま呼べば良い。実 Vault へは書き込まない
# ＝読み取り専用で参照する）。
# 補足: ngwords.txt はNG語の実データを含むため .gitignore で public 履歴から除外
# している（私的パッチ側の資産）。テストが実データに依存しないよう、NGWORDS_FILE
# はダミー語ファイルへ差し替え可能にしている（2026-07-08 設計判断）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${VAULT:=$HOME/Data/obsidian}"
: "${AIENV_REPO:=$HOME/work/takumi009-ai-env}"
: "${NGWORDS_FILE:=$SCRIPT_DIR/ngwords.txt}"

VAULT_PUBLIC="$AIENV_REPO/vault-public"

# public 指定フォルダ（中身を丸ごとコピーする対象。運用変更はこの配列を直すだけ）
PUBLIC_FOLDERS=(Preferences)

# private 骨格フォルダ（空フォルダ + README.md のみ再現。中身はコピーしない）
# Blogs は既に note.com 等で別公開済みの独立資産のため wiki link 検出の対象外
# （下記 FAIL_LINK_FOLDERS / REPORT_LINK_FOLDERS 参照。骨格は他の private フォルダと同様に再現する＝設計§2-1）
SKELETON_FOLDERS=(Personal Knowledge Decisions Projects Fragments Explorations Blogs)

# fail-fast 対象（個人情報寄り。ここへの wiki link は exit 1）
# 2026-07-08 本人決定「案A」：以前は private 6フォルダ全部が fail-fast 対象だったが、
# Preferences の大半が Knowledge/Decisions 等へリンクする運用実態（外部脳のSSOT構造）と
# 衝突し運用不能だったため、Personal のみに縮小した。
FAIL_LINK_FOLDERS=(Personal)

# レポートのみ対象（fail-fastしない。許容するが、public側でリンク切れになる旨を通知する）
REPORT_LINK_FOLDERS=(Knowledge Decisions Projects Fragments Explorations)

log() { echo "[export-public-vault] $*"; }
fail() { echo "[export-public-vault] FAIL: $*" >&2; exit 1; }

# 作業用一時ファイルはここに集約して登録し、EXIT時にまとめて掃除する。
# STAGING_DIR（ステージング領域。本体は下記0.で作る）も同じEXIT trapで
# 成功・失敗いずれの終了経路でも必ず削除する（汚染物を残さない）。
TMP_FILES=()
STAGING_DIR=""
cleanup() {
  [[ ${#TMP_FILES[@]} -eq 0 ]] || rm -f "${TMP_FILES[@]}"
  [[ -z "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
register_tmp() { local f; f="$(mktemp)"; TMP_FILES+=("$f"); printf '%s' "$f"; }

# --- 前提コマンドの確認 ---
for cmd in rsync rg gitleaks git; do
  command -v "$cmd" >/dev/null 2>&1 || fail "コマンドが見つかりません: $cmd"
done

[[ -d "$VAULT" ]] || fail "VAULT が見つかりません: $VAULT"
[[ -d "$AIENV_REPO" ]] || fail "AIENV_REPO が見つかりません: $AIENV_REPO"
[[ -f "$NGWORDS_FILE" ]] || fail "ngwords.txt が見つかりません: $NGWORDS_FILE"

# 注意: $VAULT_PUBLIC の mkdir はここでは行わない（Codexレビュー指摘・Major:
# チェック失敗時でも本番側に空ディレクトリが作られてしまうと「本番を一切変更しない」
# 設計と矛盾するため）。$VAULT_PUBLIC への書き込みは4.の昇格ステップでのみ行う。

# --- 0. ステージング領域を用意する（本番 vault-public/ とは完全に別の場所。
#      AIENV_REPO 直下に隠しディレクトリとして作る＝ .gitignore の `.export-tmp.*` で
#      追跡対象外。以降のチェック通過までは、ここだけに書き込む） ---
STAGING_DIR="$(mktemp -d "$AIENV_REPO/.export-tmp.XXXXXX")"

# --- 1. public フォルダを rsync でコピー（ステージングへ） ---
for dir in "${PUBLIC_FOLDERS[@]}"; do
  [[ -d "$VAULT/$dir" ]] || fail "public 指定フォルダが Vault に存在しません: $dir"
  log "sync public folder: $dir"
  mkdir -p "$STAGING_DIR/$dir"
  rsync -a --delete "$VAULT/$dir/" "$STAGING_DIR/$dir/"
done

# --- 2. private 骨格フォルダ（空 + README、ステージングへ都度新規作成） ---
for dir in "${SKELETON_FOLDERS[@]}"; do
  template="$SCRIPT_DIR/templates/readme-$dir.md"
  [[ -f "$template" ]] || fail "README テンプレが見つかりません: $template"
  log "skeleton folder: $dir"
  mkdir -p "$STAGING_DIR/$dir"
  cp "$template" "$STAGING_DIR/$dir/README.md"
done

# --- 3. 機械チェック（fail-fast） ---
# rg は「マッチ0件」を exit 1 で返す（正常系）。exit 2 以上は rg 自体のエラーなので
# それも検知対象にする（「マッチなし」と「rg が壊れて何も見ていない」を混同しない）。

# basename 形式の wiki link パターン（[[name]] / [[name|alias]] / [[name#Heading]] /
# [[name^blockid]] の全バリエーションを拾う）を1つの denylist basename から生成する。
# 3-a/3-b（fail-fast）・3-e（report-only）の両方で使い回す共通関数。
#
# 空白許容ポリシー（2026-07-08、tester 独立検証で発見された2件のMajorへの対応）:
#  1件目: name と区切り文字（| # ^ ]）の**間**の空白 → `[[:space:]]*` を区切り文字の前に追加
#         （例: `[[career-private | alias]]` のようにpipeエイリアスの可読性目的で空白を
#          入れる書き方はObsidian実務でよくあるが、空白なし前提の正規表現だとすり抜けていた）
#  2件目: `[[` **直後**の空白 → `[[:space:]]*` を name の前にも追加
#         （例: `[[ career-private]]` のようなタイプミス/IME確定時の余分な空白）
# うっかり検知が本チェックの存在意義のため、いずれも必須修正（Major×2件）。
build_basename_pattern_file() {
  local denylist="$1" out="$2" name escaped
  : > "$out"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    escaped=$(printf '%s' "$name" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g')
    printf '\\[\\[[[:space:]]*%s[[:space:]]*([|#\\^]|\\])\n' "$escaped" >> "$out"
  done < "$denylist"
}

# フォルダ付き wiki link（[[Personal/xxx]] 等）検出用の正規表現を生成する。3-a/3-eで共用。
# `[[` 直後・フォルダ名とスラッシュの間、両方に `[[:space:]]*` で空白を許容する
# （tester 独立検証で発見・Major: `[[ Personal/career-private]]` のように [[ 直後に
# 空白を挟む書き方が検出をすり抜けていた。フォルダ名とスラッシュの間の空白＝
# `[[Personal /career-private]]` も同種のリスクとして併せて許容する＝設計判断）。
folder_link_regex() {
  local alt="$1"
  printf '\\[\\[[[:space:]]*(%s)[[:space:]]*/' "$alt"
}

# 3-a. Personal フォルダへの wiki link（フォルダ付き形式: [[Personal/xxx]] 等）: fail-fast
#      -i（大文字小文字非依存）: macOSはcase-insensitiveなファイルシステムのため、
#      `[[personal/x]]` のような小文字表記でもObsidianはほぼ確実に実リンクとして解決してしまう
#      （2026-07-08 修正決定。ngwordsチェック/gitleaksは対象外＝現状維持）。
#      対象はステージング（$STAGING_DIR）。本番 $VAULT_PUBLIC は全チェック通過後にしか触らない。
log "check: Personal folder wiki link (folder-qualified, fail-fast)"
folder_alt=$(printf '%s|' "${FAIL_LINK_FOLDERS[@]}")
folder_alt="${folder_alt%|}"
rc=0
rg -n -i -P "$(folder_link_regex "$folder_alt")" "$STAGING_DIR" || rc=$?
if [[ $rc -eq 0 ]]; then
  fail "Personal フォルダへの wiki link（フォルダ付き）を検出しました"
elif [[ $rc -gt 1 ]]; then
  fail "rg 実行エラー (folder-qualified check, exit $rc)"
fi

# 3-b. Personal ノートへの wiki link（basename 形式: [[career-private]] 等、フォルダ省略）: fail-fast
#      denylist は「FAIL_LINK_FOLDERS（=Personal）配下の全 .md の basename」を毎回自動生成する
#      （手書き例示だと網羅できないため。設計§1-3 Codexレビュー指摘）
log "check: Personal note basename wiki link (denylist auto-generated, fail-fast)"
BASENAME_DENYLIST="$(register_tmp)"
BASENAME_PATTERN_FILE="$(register_tmp)"

: > "$BASENAME_DENYLIST"
for dir in "${FAIL_LINK_FOLDERS[@]}"; do
  if [[ -d "$VAULT/$dir" ]]; then
    find "$VAULT/$dir" -type f -name '*.md' -exec basename {} .md \; >> "$BASENAME_DENYLIST"
  fi
done
sort -u -o "$BASENAME_DENYLIST" "$BASENAME_DENYLIST"

build_basename_pattern_file "$BASENAME_DENYLIST" "$BASENAME_PATTERN_FILE"

if [[ -s "$BASENAME_PATTERN_FILE" ]]; then
  rc=0
  rg -n -i -P -f "$BASENAME_PATTERN_FILE" "$STAGING_DIR" || rc=$?
  if [[ $rc -eq 0 ]]; then
    fail "Personal ノートへの wiki link（basename形式）を検出しました"
  elif [[ $rc -gt 1 ]]; then
    fail "rg 実行エラー (basename check, exit $rc)"
  fi
else
  log "denylist が空のため basename チェックはスキップ（Personal フォルダに .md が無い）"
fi

# 3-c. NGワード検出（呼称の表記ゆれ等。「takumi009」表記は対象外＝本人明記）
#      -F（固定文字列）で扱う：ngwords.txt に将来 . [ ( 等の正規表現特殊文字を含む語が
#      追加された場合の誤爆・regexミスを避ける（Codexレビュー指摘・Minor）。
#      空行が1行でも混じると「全行マッチ」の事故になるため、空行を除いた一時ファイルを使う。
log "check: NG words ($NGWORDS_FILE)"
NGWORDS_CLEAN="$(register_tmp)"
if ! grep -v '^[[:space:]]*$' "$NGWORDS_FILE" > "$NGWORDS_CLEAN"; then
  # grep -v は「空行以外が1行も無い（=全部空行 or 0バイト）」場合も非ゼロで終了するため、
  # 「読み取れない」と「有効な行が無い」を区別する（Codexレビュー指摘・Nit）
  [[ -r "$NGWORDS_FILE" ]] || fail "ngwords.txt を読み取れません: $NGWORDS_FILE"
fi
[[ -s "$NGWORDS_CLEAN" ]] || fail "ngwords.txt に有効な行がありません: $NGWORDS_FILE"

rc=0
rg -n -F -f "$NGWORDS_CLEAN" "$STAGING_DIR" || rc=$?
if [[ $rc -eq 0 ]]; then
  fail "NGワードを検出しました（$NGWORDS_FILE 参照）"
elif [[ $rc -gt 1 ]]; then
  fail "rg 実行エラー (ngwords check, exit $rc)"
fi

# 3-d. シークレット検出（gitleaks、OSS 再利用。--redact で検出内容自体をログへ露出させない）
log "check: gitleaks"
rc=0
gitleaks detect --source "$STAGING_DIR" --no-git --no-banner --redact || rc=$?
if [[ $rc -eq 1 ]]; then
  fail "gitleaks がシークレットの疑いを検出しました"
elif [[ $rc -gt 1 ]]; then
  fail "gitleaks 実行エラー (exit $rc)"
fi

# 3-e. Personal 以外の private フォルダ（Knowledge/Decisions/Projects/Fragments/
#      Explorations）への wiki link は許容する（2026-07-08 本人決定「案A」）。
#      ただし public 側では参照先が存在しないためリンク切れになるので、
#      一覧をレポート表示するだけに留める（fail-fastしない・exit 0のまま）。
log "check: private folder link report (non-fail; Knowledge/Decisions/Projects/Fragments/Explorations)"
REPORT_LINES_FILE="$(register_tmp)"
: > "$REPORT_LINES_FILE"

# report-only なので rg のマッチ有無（exit 0/1）では絶対に fail させないが、
# rg 自体の実行エラー（exit 2以上）は「レポートが不完全かもしれない」ことを
# 分かるようにWARNだけ出す（黙って0件扱いにしない。Codexレビュー指摘・Minor）。
report_folder_alt=$(printf '%s|' "${REPORT_LINK_FOLDERS[@]}")
report_folder_alt="${report_folder_alt%|}"
rc=0
rg -n -i -P "$(folder_link_regex "$report_folder_alt")" "$STAGING_DIR" >> "$REPORT_LINES_FILE" || rc=$?
[[ $rc -gt 1 ]] && log "WARN: report-only rg 実行エラー (folder-qualified, exit $rc)。レポートが不完全な可能性があります"

REPORT_BASENAME_DENYLIST="$(register_tmp)"
REPORT_BASENAME_PATTERN_FILE="$(register_tmp)"
: > "$REPORT_BASENAME_DENYLIST"
for dir in "${REPORT_LINK_FOLDERS[@]}"; do
  if [[ -d "$VAULT/$dir" ]]; then
    find "$VAULT/$dir" -type f -name '*.md' -exec basename {} .md \; >> "$REPORT_BASENAME_DENYLIST"
  fi
done
sort -u -o "$REPORT_BASENAME_DENYLIST" "$REPORT_BASENAME_DENYLIST"

build_basename_pattern_file "$REPORT_BASENAME_DENYLIST" "$REPORT_BASENAME_PATTERN_FILE"
if [[ -s "$REPORT_BASENAME_PATTERN_FILE" ]]; then
  rc=0
  rg -n -i -P -f "$REPORT_BASENAME_PATTERN_FILE" "$STAGING_DIR" >> "$REPORT_LINES_FILE" || rc=$?
  [[ $rc -gt 1 ]] && log "WARN: report-only rg 実行エラー (basename, exit $rc)。レポートが不完全な可能性があります"
fi

if [[ -s "$REPORT_LINES_FILE" ]]; then
  # rg は行単位で出力するため「件」ではなく「行」で数える（1行に複数linkがあっても1行=1件として
  # カウントする点に注意。Codexレビュー指摘・Nit）
  report_count=$(sort -u "$REPORT_LINES_FILE" | wc -l | tr -d ' ')
  log "REPORT: public側でリンク切れになる private link を含む行を ${report_count} 行検出（fail-fast対象外。許容方針＝2026-07-08本人決定）"
  while IFS= read -r line; do
    log "  linkreport: $line"
  done < <(sort -u "$REPORT_LINES_FILE")
else
  log "REPORT: Knowledge/Decisions/Projects/Fragments/Explorations 宛ての private link は0件"
fi

# --- 4. 全チェック通過後にのみ、ステージングを本番 vault-public/ へ昇格する ---
#      ここより前で fail() すればスクリプトは即 exit するため、本番側は一切書き換わらない
#      （trap によりステージングだけが削除される。$VAULT_PUBLIC 自体もこの行まで
#      一切作成・変更しない＝存在しない場合でもチェック失敗時に空ディレクトリすら残さない）。
#      注記: rsync --delete による同期は完全な原子操作ではない（同期途中でkillされる等の
#      極端なケースでは本番側が部分更新状態になり得る）。この点は本スクリプトの1.（public
#      フォルダのrsync）でも従来から同じ特性であり、今回の変更で新たに生じたリスクではない
#      （Codexレビュー指摘・Minor。完全な原子性が要る場合は rename(2) ベースの
#      ディレクトリ差し替えを別途検討すること）。
mkdir -p "$VAULT_PUBLIC"
log "promote: staging -> $VAULT_PUBLIC"
rsync -a --delete "$STAGING_DIR/" "$VAULT_PUBLIC/"

# --- 5. 全チェック通過・昇格後のみ git add/commit（push はしない） ---
if [[ ! -d "$AIENV_REPO/.git" ]]; then
  log "AIENV_REPO が git repo ではないため git init します（ローカルのみ・リモートは設定しない）: $AIENV_REPO"
  git -C "$AIENV_REPO" init -q
fi

git -C "$AIENV_REPO" add vault-public
if git -C "$AIENV_REPO" diff --cached --quiet -- vault-public; then
  log "vault-public に変更なし。commit をスキップします"
else
  # commit 用の identity（user.name/user.email）が無いと `git commit` が素の Git
  # エラーで落ちて分かりにくいので、実際にcommitする直前だけ検知する
  # （変更が無くno-opでスキップされるケースまで identity 不備で失敗させないため、
  # このelseブロック内に置く＝Codexレビュー指摘・Minor）。
  if ! git -C "$AIENV_REPO" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
    fail "git commit 用の identity が未設定です。'git config user.name' / 'git config user.email' を設定してください（--global または $AIENV_REPO 内で --local）"
  fi
  git -C "$AIENV_REPO" commit -q -m "chore: export public vault snapshot ($(date +%Y-%m-%d))"
  log "commit しました（push は別の明示コマンドで行うこと）"
fi

log "done."
