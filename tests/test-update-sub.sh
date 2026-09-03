#!/usr/bin/env bash
# scripts/update-sub.sh のユニットテスト。
#
# 実 ~/.codex・実Vault・実GitHubには一切依存しない。ローカルの使い捨てbare repo
# を「origin」に見立て、cloneしたサブ相当のrepoに対して update-sub.sh を実行する。
#
# 2026-07-24: machine-roleマーカー（AIENV_MACHINE_ROLE_MARKER）の中身が「sub」
# でなければ即fail()で拒否するガードを追加した（リーダー裁定・Codex一次レビュー
# 指摘Major対応）。run_update()ヘルパーは「サブ機として正しく provisioning 済み」
# の正常系を再現するため、呼び出しのたびに$homeへマーカーを自動設置する
# （マーカー無し/中身違いの拒否そのものを検証するテストは後段で個別に直接
# スクリプトを呼ぶ）。
#
# 実行方法: bash tests/test-update-sub.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/update-sub.sh"

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

# 「origin」相当のbare repoと、そこへpushするための作業コピー(SRC)を作る。
# 最低限の codex/config.toml・vault-public/Preferences/ を持たせる。
make_origin() {
  local bare="$1" src="$2"
  git init -q --bare "$bare"
  mkdir -p "$src/codex" "$src/vault-public/Preferences" "$src/scripts/lib"
  cat > "$src/codex/config.toml" <<'EOF'
service_tier = "default"
[mcp_servers.obsidian]
args = ["__AIENV_HOME__/Data/obsidian"]
EOF
  echo "# 初期方針" > "$src/vault-public/Preferences/rule1.md"
  # update-sub.shが多重起動防止ロックに実物のscripts/lib/pid-lock.shを
  # source するため、fixtureにも実物をコピーして持たせる（2026-08-30 Codex
  # 2巡目差し戻し・MAJOR対応: update-sub.sh独自のロック実装をやめ、
  # backup-vault.sh・maintenance.shと共通の scripts/lib/pid-lock.sh へ
  # 一本化したことに伴う対応）。
  cp "$REPO_ROOT/scripts/lib/pid-lock.sh" "$src/scripts/lib/pid-lock.sh"
  git -C "$src" init -q
  git -C "$src" config user.name test
  git -C "$src" config user.email test@example.invalid
  git -C "$src" remote add origin "$bare"
  git -C "$src" add -A
  git -C "$src" commit -q -m init
  git -C "$src" push -q origin HEAD:main
}

# claude/settings.json テンプレ＋実物の scripts/install-main.sh を SRC へ足す
# （settings.json再生成テスト用。§9.0 A-0-1）。実物のinstall-main.shを使う理由は
# tests/test-check-drift.shと同じ＝--print-leader-runtime（2026-09-01 配役表
# 解凍以降の値出力口。旧--print-modelから改名）は他の全処理より先にexitする
# 副作用ゼロの経路のため、fixture内で呼んでも実システムに一切触れない。
add_settings_json_template() {
  local src="$1"
  mkdir -p "$src/scripts" "$src/claude" "$src/claude/hooks/lib" "$src/claude/agents"
  cat > "$src/claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(npm test)"]
  },
  "model": "__AIENV_MODEL__",
  "effortLevel": "__AIENV_EFFORT__"
}
EOF
  cp "$REPO_ROOT/scripts/install-main.sh" "$src/scripts/install-main.sh"
  chmod +x "$src/scripts/install-main.sh"
  # 2026-09-01 配役表解凍: --print-leader-runtime がv2実体を解決する際に
  # 共有lib（claude/hooks/lib/profile_resolve.py）を必要とする（実体が
  # 存在しない/v1のfixtureではこのlibを一切参照しない＝v1委譲経路のため、
  # ここへ実物を置いても既存のv1系テストの挙動は変わらない）。
  cp "$REPO_ROOT/claude/hooks/lib/profile_resolve.py" "$src/claude/hooks/lib/profile_resolve.py"
  git -C "$src" add -A
  git -C "$src" commit -q -m "add settings.json template + install-main.sh"
  git -C "$src" push -q origin HEAD:main
}

# SRCへ claude/agents/<name>.md を追加してcommit+pushする（4d.のagents
# symlinkテスト用。中身は識別できれば何でもよいので最小のfrontmatterのみ）。
add_agent_role() {
  local src="$1" name="$2"
  mkdir -p "$src/claude/agents"
  cat > "$src/claude/agents/${name}.md" <<EOF
---
name: ${name}
description: テスト用ロール定義
tools: Read
model: sonnet
color: green
---
テスト用ロール定義（${name}）。
EOF
  git -C "$src" add -A
  git -C "$src" commit -q -m "add claude/agents/${name}.md"
  git -C "$src" push -q origin HEAD:main
}

# origin から clone した「サブ機相当」のrepoを作る。
make_sub_clone() {
  local bare="$1" sub="$2"
  git clone -q "$bare" "$sub"
  git -C "$sub" config user.name test
  git -C "$sub" config user.email test@example.invalid
}

# $home配下にmachine-roleマーカー（sub）を設置する。
make_sub_marker() {
  local home="$1"
  mkdir -p "$home/.config/takumi009-ai-env"
  printf 'sub\n' > "$home/.config/takumi009-ai-env/machine-role"
}

run_update() {
  local dir="$1" home="$2" vault="$3" lock="$4"
  make_sub_marker "$home"
  DIR="$dir" HOME="$home" VAULT="$vault" LOCK_FILE="$lock" "$SCRIPT"
}

# write_v2_profile <dest> <leader-line> [extra-lines...] — 最小のv2プロファイル
# を書く（schema_version・能力軸7キー・excluded_modelsは固定キー検査
# （V7/V8-b）を通すための最小セット。role.leaderの行は必須引数、それ以外の
# 職種行は可変長の追加引数で渡す。tests/test-check-drift.shの同名関数・
# tests/test-install-main.shのwrite_v2_profile_with_bedrock_role()と
# 同じ最小セット・様式に揃える）。
write_v2_profile() {
  local dest="$1" leader_line="$2"
  shift 2
  mkdir -p "$(dirname "$dest")"
  {
    echo "---"
    echo "schema_version: 2"
    echo "profile_slug: test"
    echo "role.leader: ${leader_line}"
    for extra in "$@"; do
      printf '%s\n' "$extra"
    done
    echo "excluded_models: configured value=none"
    echo "inventory_source: configured value=work-tools-dir"
    echo "reviewer: configured value=codex-mcp"
    echo "vault_write: configured value=via-scribe"
    echo "vault_scope: configured value=full"
    echo "ui.user_call: configured value=send-message"
    echo "git_role: configured value=aienv-repo:commit"
    echo "web_verification: configured value=websearch"
    echo "---"
  } > "$dest"
}

echo "=== 1. 変更なし: 何もしない（静か・冪等） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  assert_true "変更なしメッセージが出る" \
    "$(echo "$out" | grep -q '変更なし' && echo 1 || echo 0)"
  assert_true "config.tomlは生成されていない（変更が無いため）" \
    "$([[ ! -e "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2. 変更あり: pull + config.toml再生成 + Preferences再同期 + 新骨格フォルダ補充 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  # upstreamへ変更をpush（新ルール追加＋新骨格フォルダDecisions追加）
  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  mkdir -p "$SRC/vault-public/Decisions"
  echo "# Decisions骨格" > "$SRC/vault-public/Decisions/README.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2 + Decisions skeleton"
  git -C "$SRC" push -q origin HEAD:main

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  assert_true "更新検知メッセージが出る" \
    "$(echo "$out" | grep -q '更新を検知しました' && echo 1 || echo 0)"
  assert_true "config.tomlが生成される" \
    "$([[ -f "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"
  assert_true "config.toml内のプレースホルダが実HOMEへ置換されている" \
    "$(grep -q "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.codex/config.toml" && echo 1 || echo 0)"
  assert_true "旧ルール(rule1)が残っている" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/rule1.md" ]] && echo 1 || echo 0)"
  assert_true "新ルール(rule2)が同期される" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/rule2.md" ]] && echo 1 || echo 0)"
  assert_true "新しい骨格フォルダ(Decisions)が補充される" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Decisions/README.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2b. HOMEに正規表現メタ文字（.）が含まれても config.toml に余計な \\ が混入しない ==="
{
  # sedの置換値側で使うescaped_homeは & \ # だけエスケープすればよく、正規表現
  # メタ文字（. 等）まで一律エスケープすると生成物に余計な"\"が混じる
  # （Codexレビュー指摘・Minor）。install-main.shと同じ簡易エスケープに揃えたことを
  # 実際に「.」を含むHOMEパスで確認する。
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home.with.dots"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  assert_true "config.tomlのパスに余計なバックスラッシュが混入していない" \
    "$(grep -q "\\\\" "$FAKE_HOME/.codex/config.toml" && echo 0 || echo 1)"
  assert_true "config.tomlに正しいHOMEパス（ドット含む）がそのまま入っている" \
    "$(grep -qF "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.codex/config.toml" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 3. サブローカルのFragments等は絶対に消えない（Preferences以外に触らない） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian/Fragments"
  echo "サブローカルの断片" > "$FAKE_HOME/Data/obsidian/Fragments/local-note.md"
  LOCK="$WORK/lock"

  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  assert_eq "Fragmentsのローカル断片の中身が変わっていない" "サブローカルの断片" \
    "$(cat "$FAKE_HOME/Data/obsidian/Fragments/local-note.md")"

  rm -rf "$WORK"
}

echo "=== 4. 既存の骨格フォルダは上書きしない（README.md等をそのまま保持） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  mkdir -p "$SRC/vault-public/Personal"
  echo "# Personal骨格（初期）" > "$SRC/vault-public/Personal/README.md"
  make_origin "$BARE" "$SRC"
  # make_originの後にPersonalを追加したので改めてpush
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add Personal skeleton" --allow-empty
  git -C "$SRC" push -q origin HEAD:main

  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian/Personal"
  echo "サブでローカルに書いたPersonalノート" > "$FAKE_HOME/Data/obsidian/Personal/my-local-note.md"
  LOCK="$WORK/lock"

  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  assert_true "既存Personalフォルダのローカルノートが消えていない" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Personal/my-local-note.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 5. ff-only不可（サブ側にローカルcommitがある）ならWARNで終了しexit 0 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  # サブ側でローカルcommitを作る（本来は起きないはずだが、ff不可を人工的に再現）
  echo "local edit" >> "$SUB/codex/config.toml"
  git -C "$SUB" add -A
  git -C "$SUB" commit -q -m "unexpected local commit"

  # upstreamにも別の変更をpush（分岐させる）
  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  rc=0
  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1) || rc=$?
  assert_eq "exit code 0（致命的エラーにしない）" "0" "$rc"
  assert_true "ff-only失敗のWARNが出る" \
    "$(echo "$out" | grep -q 'git pull --ff-only に失敗しました' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 6. remote origin未設定ならWARNで終了しexit 0 ==="
{
  WORK="$(mktemp -d)"
  SUB="$WORK/sub-no-remote"
  mkdir -p "$SUB" "$SUB/scripts/lib"
  git -C "$SUB" init -q
  git -C "$SUB" config user.name test
  git -C "$SUB" config user.email test@example.invalid
  echo "x" > "$SUB/x.md"
  cp "$REPO_ROOT/scripts/lib/pid-lock.sh" "$SUB/scripts/lib/pid-lock.sh"
  git -C "$SUB" add -A
  git -C "$SUB" commit -q -m init

  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  rc=0
  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1) || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "remote未設定のWARNが出る" \
    "$(echo "$out" | grep -q "remote 'origin' が設定されていません" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 7. ロック: 生存しているPIDのロックがあれば今回はskipする ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  echo "$$" > "$LOCK"

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  assert_true "既に実行中ですメッセージが出る" \
    "$(echo "$out" | grep -q '既に実行中です' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 8. ロック: staleなPIDは自動解除して続行する ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  echo "999999" > "$LOCK"

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)
  assert_true "staleロック検出のWARNが出る" \
    "$(echo "$out" | grep -q 'stale なロックファイルを検出しました' && echo 1 || echo 0)"
  assert_true "続行して変更なしメッセージまで到達する" \
    "$(echo "$out" | grep -q '変更なし' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 9. machine-roleマーカー: マーカーが無ければ即FAILで拒否する（メインでの誤実行防止・2026-07-24追加） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  # make_sub_marker() を意図的に呼ばず、マーカー未設置(=メイン相当)を再現する。

  rc=0
  out=$(DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" "$SCRIPT" 2>&1) || rc=$?
  assert_eq "マーカー無しはexit 1(FAIL)" "1" "$rc"
  assert_true "サブ機として登録されていない旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q "サブ機として登録されていません" && echo 1 || echo 0)"
  assert_true "install-sub.shを先に実行するよう案内する" \
    "$(echo "$out" | grep -q "install-sub.sh を実行" && echo 1 || echo 0)"
  assert_true "マーカー無しの時点でgit pull等には一切進まない(rule1.mdが同期されていない)" \
    "$([[ ! -f "$FAKE_HOME/Data/obsidian/Preferences/rule1.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 9b. machine-roleマーカー: 中身が「sub」以外(例: main)でも即FAILで拒否する ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  printf 'main\n' > "$FAKE_HOME/.config/takumi009-ai-env/machine-role"
  LOCK="$WORK/lock"

  rc=0
  out=$(DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" "$SCRIPT" 2>&1) || rc=$?
  assert_eq "中身がmainならexit 1(FAIL)" "1" "$rc"
  assert_true "サブ機として登録されていない旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q "サブ機として登録されていません" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 9c. machine-roleマーカー: 中身が「sub」(前後空白付き)なら正常に動作する ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  printf '  sub  \n' > "$FAKE_HOME/.config/takumi009-ai-env/machine-role"
  LOCK="$WORK/lock"

  rc=0
  out=$(DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" "$SCRIPT" 2>&1) || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_true "変更なしメッセージまで正常に到達する" \
    "$(echo "$out" | grep -q '変更なし' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 9d. machine-roleマーカー: 中身が「s u b」(内部に空白を含む)なら「sub」と誤認せずFAILで拒否する(Codex再レビュー指摘Minor対応) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  printf 's u b\n' > "$FAKE_HOME/.config/takumi009-ai-env/machine-role"
  LOCK="$WORK/lock"

  rc=0
  out=$(DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" "$SCRIPT" 2>&1) || rc=$?
  assert_eq "内部に空白を含む中身はexit 1(FAIL)" "1" "$rc"
  assert_true "サブ機として登録されていない旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q "サブ機として登録されていません" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 9f. machine-roleマーカー: ja_JP.UTF-8ロケール環境でも本来のFAILメッセージが握り潰されない（2026-07-16 scripts/install-backup.shで発見済みの実バグ回帰テスト・2026-07-24 update-sub.shへの横展開で同型バグが再発しないことの固定化） ==="
{
  # bash 3.2(macOS既定)+ja_JP.UTF-8ロケール環境で、fail()メッセージ内の裸の
  # $AIENV_MACHINE_ROLE_MARKER直後に全角の閉じ括弧（）が続くと、変数名の境界を
  # 誤認識し「unbound variable」でクラッシュし本来のFAILメッセージが一切
  # 表示されない欠陥が実装中に一度発生した（${AIENV_MACHINE_ROLE_MARKER}と
  # 波括弧で囲んで修正済み）。元バグはこのロケール下でのみ再現するため、CI等の
  # 別ロケール環境でも確実にこの回帰を検出できるようLC_ALL/LANGを明示指定する。
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  # マーカーは意図的に未設置のまま(=拒否パスを踏ませる)。

  rc=0
  out=$(LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8 DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" "$SCRIPT" 2>&1) || rc=$?
  assert_eq "マーカー拒否はexit 1(FAIL)のまま" "1" "$rc"
  assert_true "'unbound variable'クラッシュでは落ちず本来のFAILメッセージが出る" \
    "$(echo "$out" | grep -q "サブ機として登録されていません" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 10. settings.json再生成: HEADが変わっていなくてもサブ既定値(claude-opus-5)で再生成される（§9.0 A-0-1・§11.2 項目3の受入条件） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  # HEADは変わらない（pull時点で既に最新）ケースでも再生成されることを見る。
  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  assert_true "変更なしメッセージが出る（HEAD不変）" \
    "$(echo "$out" | grep -q '変更なし' && echo 1 || echo 0)"
  assert_true "settings.jsonが生成される" \
    "$([[ -f "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "modelはサブ既定値(claude-opus-5)へ解決される（値出力口＝install-main.sh --print-leader-runtime --sub-delegate）" \
    "$(grep -q 'claude-opus-5' "$FAKE_HOME/.claude/settings.json" && echo 1 || echo 0)"
  assert_true "再生成メッセージが出る" \
    "$(echo "$out" | grep -q 'settings.json を再生成しました' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 11. settings.json再生成: ローカルのmodel値上書き(AIENV_MODEL_SUB)にも従う（値出力口の一本化の裏付け） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"

  make_sub_marker "$FAKE_HOME"
  AIENV_MODEL_SUB='custom-sub-model' DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" "$SCRIPT" >/dev/null

  assert_true "AIENV_MODEL_SUB上書きがsettings.jsonへ反映される" \
    "$(grep -q 'custom-sub-model' "$FAKE_HOME/.claude/settings.json" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 12. settings.json再生成: テンプレのmodelが__AIENV_MODEL__の目印から変わっていれば生成失敗し、旧ファイルを保持する ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  # テンプレを壊す（誰かがmodelへ特定値を直書きした回帰を模す）。
  cat > "$SRC/claude/settings.json" <<'EOF'
{
  "model": "claude-hardcoded-oops"
}
EOF
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "break settings.json template"
  git -C "$SRC" push -q origin HEAD:main

  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude"
  echo '{"model": "旧settings.json"}' > "$FAKE_HOME/.claude/settings.json"
  LOCK="$WORK/lock"

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)
  assert_true "生成失敗のWARNが出る" \
    "$(echo "$out" | grep -q 'settings.json の生成に失敗しました' && echo 1 || echo 0)"
  assert_true "旧settings.jsonが変わらず残る（原子的書込・失敗時に壊さない）" \
    "$(grep -q '旧settings.json' "$FAKE_HOME/.claude/settings.json" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 13. settings.json再生成: Bedrock envファイルの値がenvブロックへ取り込まれる（§9.0 A-1-4） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8
EOF
  chmod 644 "$ENV_FILE"
  # 2026-09-01 §4.2-d改訂（担当Bコミット36745b2/fe06258）: ANTHROPIC_DEFAULT_
  # OPUS_MODELは固定許可から動的許可へ変わった（プロファイルのrole.*/
  # fallback.*が実際にprovider=bedrock model=opusを使っているときだけ許可）。
  # v2プロファイルでresearcherをそう配役し、動的に許可されることを確認する
  # （リーダー実査指摘・結合確認対応: tests/test-install-main.shの
  # write_v2_profile_with_bedrock_role()と同じ様式）。
  write_v2_profile "$FAKE_HOME/.config/takumi009-ai-env/profile.md" \
    "configured provider=anthropic-api model=claude-sonnet-5" \
    "role.researcher: configured provider=bedrock model=opus"
  LOCK="$WORK/lock"

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  assert_true "CLAUDE_CODE_USE_BEDROCKがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "ANTHROPIC_DEFAULT_OPUS_MODELがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('ANTHROPIC_DEFAULT_OPUS_MODEL')=='us.anthropic.claude-opus-4-8' else 1)" && echo 1 || echo 0)"
  perm="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  assert_eq "envファイルのパーミッションが0600へ揃えられる" "600" "$perm"

  rm -rf "$WORK"
}

echo "=== 14. settings.json再生成: 許可リスト外のキー（AWS認証情報等を想定）は取り込まずWARNする（Codex一次レビュー指摘・Major対応の横展開） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
AWS_SECRET_ACCESS_KEY=super-secret-value
EOF
  LOCK="$WORK/lock"

  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)"

  assert_true "許可リスト外キーのWARNが出る" \
    "$(echo "$out" | grep -q '許可リスト外のキーがあったため取り込みませんでした' && echo 1 || echo 0)"
  assert_true "AWS_SECRET_ACCESS_KEYはsettings.jsonへ一切取り込まれない" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if 'AWS_SECRET_ACCESS_KEY' not in d.get('env',{}) else 1)" && echo 1 || echo 0)"
  assert_true "値そのものはログにも出ない" \
    "$(echo "$out" | grep -q 'super-secret-value' && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo "=== 15. settings.json再生成: パーミッションを0600へ矯正できない場合はsettings.json本体の再生成ごと中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR対応: 従来は取り込みだけskipしsettings.json本体は再生成・上書きしていたため、既存設定にあったCLAUDE_CODE_USE_BEDROCK等が消え得た。設計書§11.2「生成失敗時は旧ファイルを触らない」契約どおりに修正。2026-08-30 リーダー追補: tester独立検証がbedrock.envを644＋chflags uchgで矯正恒久失敗させ、install-main.sh/update-sub.sh双方でCLAUDE_CODE_USE_BEDROCK・AWS_REGIONが黙って消えることを別経路で実再現済み＝本テストはその再現シナリオそのもの） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  # 「既存のsettings.json」を模した番兵コンテンツを事前に置く（再生成が中止され
  # 既存ファイルが一切触られないことを、単なる不在ではなく内容不変で検証する）。
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
EOF
  # tester再現シナリオ通り644を明示する（2026-08-30 Codex五次レビュー指摘・
  # Minor対応: umaskによっては`cat >`だけで既に600相当になり、パーミッション
  # 矯正の「失敗」自体が発生しないシナリオになりうるため、umaskに依存させない）。
  chmod 0644 "$ENV_FILE"
  LOCK="$WORK/lock"

  if command -v chflags >/dev/null 2>&1 && chflags uchg "$ENV_FILE" 2>/dev/null; then
    rc=0
    out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?
    chflags nouchg "$ENV_FILE" 2>/dev/null || true

    assert_eq "settings.json再生成が中止されると4a〜4cは続行されるがupdate-sub.sh全体は最終的に非0終了する（状態機械B S4・2026-09-01工程横断レビュー差し戻しMAJOR対応）" "1" "$rc"
    assert_true "パーミッション矯正失敗のWARNが出る" \
      "$(echo "$out" | grep -q 'パーミッションを0600へ揃えられませんでした' && echo 1 || echo 0)"
    assert_true "再生成中止・既存ファイル保持のWARNが出る" \
      "$(echo "$out" | grep -q '既存ファイルを保持します' && echo 1 || echo 0)"
    POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
    assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
    # SHA-256不変は全内容の不変を含意するが、tester独立検証と同じ観点
    # （CLAUDE_CODE_USE_BEDROCK・AWS_REGIONが個別に消えていないか）も
    # 明示的に直接確認する。
    assert_true "CLAUDE_CODE_USE_BEDROCKが消えていない(tester独立検証と同一観点)" \
      "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
    assert_true "AWS_REGIONが消えていない(tester独立検証と同一観点)" \
      "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('AWS_REGION')=='us-east-1' else 1)" && echo 1 || echo 0)"
  else
    pass "chflagsが使えない環境のためskip（このマシンでは未検証）"
  fi

  rm -rf "$WORK"
}

echo "=== 15b. settings.json再生成: Bedrock envパスがディレクトリの場合もsettings.json本体の再生成を中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR対応） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # Bedrock envのパスをディレクトリにする。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "settings.json再生成が中止されると4a〜4cは続行されるがupdate-sub.sh全体は最終的に非0終了する（状態機械B S4・2026-09-01工程横断レビュー差し戻しMAJOR対応）" "1" "$rc"
  assert_true "ディレクトリである旨のWARNが出る（無警告のまま素通りしない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 15b2. settings.json再生成: Bedrock envパスがdangling symlink(実体が既に無いsymlink)の場合もsettings.json本体の再生成を中止し既存ファイルを保持する（2026-08-30 Codex四次レビュー指摘・MAJOR対応: 従来は'[ -e ]'だけの判定だとdangling symlinkが「存在しない＝ABSENT」に丸められ、無警告のまま空設定で生成・上書きしていた） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # 実体を作ってからsymlinkを張り、実体だけ削除してdangling symlinkにする。
  DANGLING_TARGET="$FAKE_HOME/.config/takumi009-ai-env/bedrock-target.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$DANGLING_TARGET"
  ln -s "$DANGLING_TARGET" "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  rm -f "$DANGLING_TARGET"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "settings.json再生成が中止されると4a〜4cは続行されるがupdate-sub.sh全体は最終的に非0終了する（状態機械B S4・2026-09-01工程横断レビュー差し戻しMAJOR対応）" "1" "$rc"
  assert_true "dangling symlinkである旨のWARNが出る（ABSENT扱いで無警告のまま素通りしない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 15c. settings.json再生成: 値出力口(install-main.sh --print-bedrock-env-json)が非0終了する場合もsettings.json本体の再生成を中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR対応: 従来はBEDROCK_PAYLOADを空へ丸めてそのまま再生成・上書きしていた） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  # 不正なUTF-8バイト列にする（install-main.sh --print-bedrock-env-jsonが
  # compute_bedrock_env_json()内のpython3 open()でUnicodeDecodeErrorとなり
  # 非0終了することを実測で確認済み。パーミッション自体は正しく0600へ
  # 矯正できる＝15とは異なる失敗経路を狙い撃ちする）。
  printf '\xff\xfe\x00\x01invalid-utf8-\xfe' > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "settings.json再生成が中止されると4a〜4cは続行されるがupdate-sub.sh全体は最終的に非0終了する（状態機械B S4・2026-09-01工程横断レビュー差し戻しMAJOR対応）" "1" "$rc"
  assert_true "解析失敗のWARNが出る" \
    "$(echo "$out" | grep -q 'Bedrock envファイルの解析に失敗しました' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 15d. settings.json再生成: 親ディレクトリの探索権限不足(EACCES)で存在確認自体ができない場合もsettings.json本体の再生成を中止し既存ファイルを保持する（2026-08-30 Codex五次レビュー指摘・Minor対応: bedrock_env_file_kind()のFileNotFoundError以外のOSError→UNAVAILABLE経路をchmod 000で直接踏む） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  LOCKED_DIR="$FAKE_HOME/.config/bedrock-locked"
  mkdir -p "$LOCKED_DIR"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$LOCKED_DIR/bedrock.env"
  chmod 000 "$LOCKED_DIR"
  LOCK="$WORK/lock"

  rc=0
  out="$(AIENV_BEDROCK_ENV_FILE="$LOCKED_DIR/bedrock.env" run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?
  chmod 700 "$LOCKED_DIR"

  assert_eq "settings.json再生成が中止されると4a〜4cは続行されるがupdate-sub.sh全体は最終的に非0終了する（状態機械B S4・2026-09-01工程横断レビュー差し戻しMAJOR対応）" "1" "$rc"
  assert_true "通常ファイルではない旨のWARNが出る（探索権限不足もABSENT扱いにされない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 15e. settings.json再生成が中止され最終的に非0終了する場合でも、4a〜4c（config.toml再生成・Preferences再同期）は実際に続行されている（S4のdeferred方式の振る舞いカバレッジ・Codexレビュー指摘Major対応: HEAD変化を伴わない15/15b〜15dだけでは4a〜4cの続行そのものは検証できていなかった） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value"
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # HEADを進める変更をorigin側へpushしておく（4a〜4cが実際に走ったことを、
  # 変更前には存在しなかった内容で確認するため）。
  MARKER="MARKER-15e-$(date +%s)-$$"
  cat > "$SRC/codex/config.toml" <<EOF
service_tier = "default"
[mcp_servers.obsidian]
args = ["__AIENV_HOME__/Data/obsidian", "${MARKER}"]
EOF
  echo "# ${MARKER}" > "$SRC/vault-public/Preferences/rule-15e.md"
  # 4c（新しい骨格フォルダの補充）も同じテストで検証する（Codex二次レビュー
  # 指摘・Minor対応: 4a/4bだけでは「4a〜4cが続行」の受入条件を完全には
  # 証明できていなかった）。
  mkdir -p "$SRC/vault-public/NewFolder15e"
  echo "# ${MARKER}" > "$SRC/vault-public/NewFolder15e/README.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "15e: config.toml更新+新規Preferences"
  git -C "$SRC" push -q origin HEAD:main
  # Bedrock envパスをディレクトリにしてEXISTS_BUT_UNAVAILABLE(S4)を発生させる
  # （15bと同じ発生源。ここではHEAD変化との組み合わせを狙い撃ちする）。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "settings.json再生成が中止されてもupdate-sub.sh全体は最終的に非0終了する（S4）" "1" "$rc"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "settings.jsonは再生成されず旧ファイルが保持される(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
  assert_true "4a. config.tomlは実際に再生成されている（新content=マーカー入りのHOME置換済み）" \
    "$(grep -q "$FAKE_HOME/Data/obsidian.*$MARKER" "$FAKE_HOME/.codex/config.toml" 2>/dev/null && echo 1 || echo 0)"
  assert_true "4b. Preferencesは実際に再同期されている（新規ファイルのマーカーが宛先へ実転写）" \
    "$(grep -q "$MARKER" "$FAKE_HOME/Data/obsidian/Preferences/rule-15e.md" 2>/dev/null && echo 1 || echo 0)"
  assert_true "4c. 新しい骨格フォルダが実際に補充されている（新規READMEのマーカーが宛先へ実転写）" \
    "$(grep -q "$MARKER" "$FAKE_HOME/Data/obsidian/NewFolder15e/README.md" 2>/dev/null && echo 1 || echo 0)"
  assert_true "更新を検知したログが出る（HEADが実際に進んだことの確認）" \
    "$(echo "$out" | grep -q '更新を検知しました' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 16. settings.json再生成: Bedrock envファイルの解析できない行は行番号付きでWARNし、値は出さない（Codex一次レビュー指摘・Minor対応の横展開） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
THIS_LINE_HAS_NO_EQUALS_SIGN_AND_MIGHT_LEAK_A_TOKEN_abcdef123456
=empty-key-value
EOF
  LOCK="$WORK/lock"

  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)"

  assert_true "解析できない行のWARNが行番号付きで出る" \
    "$(echo "$out" | grep -q '解析できない行がありました（行番号: 2,3）' && echo 1 || echo 0)"
  assert_true "不正行の値そのものはログに出ない" \
    "$(echo "$out" | grep -q 'MIGHT_LEAK_A_TOKEN' && echo 0 || echo 1)"
  assert_true "正常行(CLAUDE_CODE_USE_BEDROCK)は取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 16b. settings.json再生成: model値の出力口が部分出力を残しつつ非0終了しても、取得失敗として扱い既存settings.jsonを保持しWARN＋非0終了する（2026-08-30 Codex四次レビュー指摘・MAJOR対応: 従来は\$MODEL_VALUEが非空かどうかだけで成功/失敗を判定しており、部分出力を残す非0終了を誤って成功扱いし、BEDROCK_STATUS/BEDROCK_PAYLOAD未初期化のままset -u下で異常終了しうる欠陥があった。2026-09-01 Codex一次レビュー指摘・Blocking対応: 取得失敗時はスクリプト全体もexit 0ではなく非0で終わる＝設計書§3.9「WARN＋非0終了」） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env" "$FAKE_HOME/.claude"
  # 「既存のsettings.json」を模した番兵コンテンツを事前に置く。
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {}
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # install-main.shを「--print-leader-runtimeへ部分出力を残しつつ非0終了する」
  # スタブへ差し替える（2026-09-01 配役表解凍以降、値出力口は--print-model
  # から--print-leader-runtimeへ一本化＝§4.2-a）。
  cat > "$SUB/scripts/install-main.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --print-leader-runtime)
    echo "partial-output-before-crash"
    exit 1
    ;;
esac
exit 1
EOF
  chmod +x "$SUB/scripts/install-main.sh"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "set -uでの異常終了が再発しない代わりにexit 1（設計書§3.9・WARN＋非0終了）で終わる" "1" "$rc"
  assert_true "リーダー実行値の取得に失敗した旨のWARNが出る" \
    "$(echo "$out" | grep -q 'リーダー実行値の取得に失敗しました' && echo 1 || echo 0)"
  assert_not_contains_helper() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
  }
  assert_not_contains_helper "set -uのunbound variableエラーは出ない" "$out" "unbound variable"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 17. P1受入④(HEAD不変): update-sub.sh実行後もPreferencesがrepoとrsync差分ゼロ、かつローカル実体プロファイルのSHA-256が不変（差し戻し対応・設計書§9.3 P1受入条件④の判定式どおり） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian/Preferences" "$FAKE_HOME/.config/takumi009-ai-env"
  # 「既にup-to-dateなサブ機」を再現するため、Preferencesを事前にrepoの
  # vault-public/Preferencesと同一内容にしておく（HEAD不変ケースでは
  # update-sub.sh自身はPreferences同期処理〈4b〉まで到達しないため）。
  cp -R "$SUB/vault-public/Preferences/." "$FAKE_HOME/Data/obsidian/Preferences/"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  echo "ローカル実体プロファイルの中身（update-sub.shで変わってはいけない）" > "$PROFILE_PATH"
  profile_sha_before="$(shasum -a 256 "$PROFILE_PATH" | cut -d' ' -f1)"
  LOCK="$WORK/lock"

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  profile_sha_after="$(shasum -a 256 "$PROFILE_PATH" | cut -d' ' -f1)"
  assert_eq "[HEAD不変] ローカル実体プロファイルのSHA-256が不変" "$profile_sha_before" "$profile_sha_after"
  rsync_diff="$(diff -rq "$SUB/vault-public/Preferences" "$FAKE_HOME/Data/obsidian/Preferences" 2>&1)"
  assert_eq "[HEAD不変] Preferencesがrepoのvault-public/Preferencesと差分ゼロ" "" "$rsync_diff"

  rm -rf "$WORK"
}

echo "=== 18. P1受入④(HEAD変化あり): update-sub.sh実行後にPreferencesがrepoとrsync差分ゼロ、かつローカル実体プロファイルのSHA-256が不変 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.config/takumi009-ai-env"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  echo "ローカル実体プロファイルの中身（update-sub.shで変わってはいけない）" > "$PROFILE_PATH"
  profile_sha_before="$(shasum -a 256 "$PROFILE_PATH" | cut -d' ' -f1)"
  LOCK="$WORK/lock"

  # マーカー文字列（内容が実転写されたことを直接確認する。差分ゼロ判定
  # だけだと偽陰性の余地がある＝tester独立検証の指摘に合わせて移植）。
  MARKER_TOP="MARKER-TOP-$(date +%s)-$$"
  MARKER_NESTED="MARKER-NESTED-$(date +%s)-$$-nested"
  echo "# 追加方針 ${MARKER_TOP}" > "$SRC/vault-public/Preferences/rule2.md"
  mkdir -p "$SRC/vault-public/Preferences/subdir"
  echo "# ネストしたルール ${MARKER_NESTED}" > "$SRC/vault-public/Preferences/subdir/rule3.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2 + nested rule3"
  git -C "$SRC" push -q origin HEAD:main

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  profile_sha_after="$(shasum -a 256 "$PROFILE_PATH" | cut -d' ' -f1)"
  assert_eq "[HEAD変化あり] ローカル実体プロファイルのSHA-256が不変" "$profile_sha_before" "$profile_sha_after"
  # $SUBはpull済みのため、$SUB/vault-public/Preferencesが再同期後の期待値そのもの。
  rsync_diff="$(diff -rq "$SUB/vault-public/Preferences" "$FAKE_HOME/Data/obsidian/Preferences" 2>&1)"
  assert_eq "[HEAD変化あり] Preferencesがrepoのvault-public/Preferencesと差分ゼロ（ネスト含む）" "" "$rsync_diff"
  assert_true "[HEAD変化あり] トップ階層ファイルのマーカー文字列が宛先へ実転写されている" \
    "$(grep -q "$MARKER_TOP" "$FAKE_HOME/Data/obsidian/Preferences/rule2.md" 2>/dev/null && echo 1 || echo 0)"
  assert_true "[HEAD変化あり] ネストしたファイルのマーカー文字列が宛先へ実転写されている" \
    "$(grep -q "$MARKER_NESTED" "$FAKE_HOME/Data/obsidian/Preferences/subdir/rule3.md" 2>/dev/null && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 19. MAJOR-A結合: 同一Bedrock envファイルに対しinstall-main.sh(--sub-delegate)とupdate-sub.shが生成するsettings.jsonのenvブロックが完全一致する（installer/updaterの生成結果同一性・2026-08-30 工程横断レビュー指摘・MAJOR-A対応: 両者が独自に値表・解析ロジックを複製していたため食い違いうる構造だった） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"

  # 許可されたBedrock envキー5件すべてを含める（Codex一次レビュー指摘・
  # Minor対応: 従来は3件だけだとSONNET/HAIKUの取り扱いに installer/updater 間の
  # 差異があっても検出できなかった）。
  ENV_CONTENT='CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8
ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-sonnet-4-8
ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-8'

  # --- install-main.sh を --sub-delegate で直接実行（実repoの完全なファイル
  #     ツリーが必要なため、実運用と同じ$REPO_ROOTを使う。update-sub.sh側の
  #     $SRC/$SUBはprint系モードだけ使うfixtureのため完全なツリーを持たない）。
  FAKE_HOME_INSTALLER="$WORK/home_installer"
  mkdir -p "$FAKE_HOME_INSTALLER/.claude/hooks" "$FAKE_HOME_INSTALLER/.claude/agents" \
           "$FAKE_HOME_INSTALLER/.codex" "$FAKE_HOME_INSTALLER/.config/takumi009-ai-env"
  printf '%s\n' "$ENV_CONTENT" > "$FAKE_HOME_INSTALLER/.config/takumi009-ai-env/bedrock.env"
  # 2026-09-01 §4.2-d改訂（担当Bコミット36745b2/fe06258）: Bedrockモデルpin
  # キー（ANTHROPIC_DEFAULT_OPUS/SONNET/HAIKU_MODEL）は固定許可から動的許可へ
  # 変わった（プロファイルのrole.*/fallback.*が実際にprovider=bedrockで
  # その別名を使っているときだけ許可）。installer/updater双方に、
  # opus/sonnet/haikuの3別名すべてを配役したv2プロファイルを事前に置く
  # （リーダー実査指摘・結合確認対応）。role.leaderはAIENV_LEADER_ROLEと
  # 一致させ対話を発生させない（既存の値と一致→そのまま通す・冪等＝§3.9）。
  write_v2_profile "$FAKE_HOME_INSTALLER/.config/takumi009-ai-env/profile.md" \
    "configured provider=anthropic-api model=claude-sonnet-5" \
    "role.researcher: configured provider=bedrock model=opus" \
    "role.tester: configured provider=bedrock model=sonnet" \
    "role.operator: configured provider=bedrock model=haiku"
  # 2026-09-01 配役表解凍（設計書§3.9）: v2雛形はrole.leaderがunknownのまま
  # 配布されるが、上記で事前にconfigured済みのプロファイルを置いたため
  # 雛形配置（非破壊・初回のみ）はskipされ、対話にも入らない
  # （tests/test-install-main.shが採用している既定パターンと同じ＝担当B
  # からの引き継ぎ）。
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-sonnet-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME_INSTALLER" bash "$REPO_ROOT/scripts/install-main.sh" --sub-delegate >/dev/null 2>&1

  # --- update-sub.sh（pull経路。SUBクローン＝add_settings_json_templateが
  #     $SRCへ実物のinstall-main.shをコピー済みなので--print-*系は動く）---
  FAKE_HOME_UPDATER="$WORK/home_updater"
  mkdir -p "$FAKE_HOME_UPDATER/.codex" "$FAKE_HOME_UPDATER/Data/obsidian" "$FAKE_HOME_UPDATER/.config/takumi009-ai-env"
  printf '%s\n' "$ENV_CONTENT" > "$FAKE_HOME_UPDATER/.config/takumi009-ai-env/bedrock.env"
  # updater側にも同じ配役のv2プロファイルを置く（installer側と同一集合の
  # Bedrock由来envキーが動的に許可されることの前提を揃える）。
  write_v2_profile "$FAKE_HOME_UPDATER/.config/takumi009-ai-env/profile.md" \
    "configured provider=anthropic-api model=claude-sonnet-5" \
    "role.researcher: configured provider=bedrock model=opus" \
    "role.tester: configured provider=bedrock model=sonnet" \
    "role.operator: configured provider=bedrock model=haiku"
  LOCK="$WORK/lock"
  run_update "$SUB" "$FAKE_HOME_UPDATER" "$FAKE_HOME_UPDATER/Data/obsidian" "$LOCK" >/dev/null

  # ⚠️ update-sub.sh側のfixtureテンプレ（add_settings_json_template）は
  # 実repoのテンプレとは別物（"env"にDISABLE_AUTOUPDATER等のテンプレ由来
  # キーを持たない最小fixture）なので、envブロック全体ではなく
  # **Bedrock由来のキーだけ**を抽出して比較する（テンプレ差に起因する
  # 差分を「installer/updaterの不一致」と誤検出しないため）。「Bedrock由来の
  # キー」の集合はテスト側でハードコードせず、単一解析経路
  # （install-main.sh --print-bedrock-env-json）が実際に返した env キー集合を
  # 正本として使う（Codex一次レビュー指摘・Minor対応: 従来はテスト内で3キーを
  # 再列挙しており、許可リストが増減してもこの比較範囲が追随せず、installer/
  # updater間の将来的な処理差を見逃しうる穴があった）。
  bedrock_keys_json="$(HOME="$FAKE_HOME_INSTALLER" bash "$REPO_ROOT/scripts/install-main.sh" --print-bedrock-env-json)"
  bedrock_env_installer="$(python3 -c "
import json, sys
keys = sorted(json.loads(sys.argv[2])['env'].keys())
env = json.load(open(sys.argv[1]))['env']
print(json.dumps({k: env[k] for k in keys if k in env}, sort_keys=True))
" "$FAKE_HOME_INSTALLER/.claude/settings.json" "$bedrock_keys_json")"
  bedrock_env_updater="$(python3 -c "
import json, sys
keys = sorted(json.loads(sys.argv[2])['env'].keys())
env = json.load(open(sys.argv[1]))['env']
print(json.dumps({k: env[k] for k in keys if k in env}, sort_keys=True))
" "$FAKE_HOME_UPDATER/.claude/settings.json" "$bedrock_keys_json")"
  assert_eq "install-main.sh(--sub-delegate)とupdate-sub.shが生成するBedrock由来のenvキーが完全一致する" "$bedrock_env_installer" "$bedrock_env_updater"
  env_installer="$bedrock_env_installer"
  assert_true "envブロックに実際にBedrock由来のキーが5件とも含まれている（比較が空同士の偶然一致でないことの確認）" \
    "$(echo "$env_installer" | grep -q 'CLAUDE_CODE_USE_BEDROCK' && echo "$env_installer" | grep -q 'AWS_REGION' && echo "$env_installer" | grep -q 'ANTHROPIC_DEFAULT_OPUS_MODEL' && echo "$env_installer" | grep -q 'ANTHROPIC_DEFAULT_SONNET_MODEL' && echo "$env_installer" | grep -q 'ANTHROPIC_DEFAULT_HAIKU_MODEL' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 20. §4.3: リーダー配役未確定(role.leader: unknown)なら機械可読コードを人向け文言へ変換してWARNし、settings.jsonを再生成しない（旧ファイル保持・fail-open）（2026-09-01 配役表解凍） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude"
  write_v2_profile "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "unknown"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value"
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  # 2026-09-01 Codex一次レビュー指摘・Blocking対応: 設計書§3.9
  # 「update-sub.shはリーダー行が未確定ならWARN＋非0終了」どおり、対話を
  # せず旧ファイルを保持する代わりに終了コードは非0になる（「対話はしない」
  # ≠「exit 0で完走する」＝旧テストの誤った期待を修正）。
  assert_eq "update-sub.sh全体は非0終了する（対話はしないが成功扱いにもしない・§3.9）" "1" "$rc"
  assert_true "機械可読コードLEADER_UNCONFIGUREDが人向け文言に変換される" \
    "$(echo "$out" | grep -q 'リーダー配役が未確定です' && echo 1 || echo 0)"
  assert_true "WARN文面に「プロファイルのリーダー行を確認してください」を含む" \
    "$(echo "$out" | grep -q 'プロファイルのリーダー行（role.leader）を確認してください' && echo 1 || echo 0)"
  assert_true "生の機械可読コード(LEADER_UNCONFIGURED)自体は理由として画面に残っていてもよいが、素の2>/dev/nullの汎用WARNへ丸められていない" \
    "$(echo "$out" | grep -q '値の取得に失敗しました（scripts/install-main.sh --print-model' && echo 0 || echo 1)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "settings.jsonは再生成されず旧ファイルが保持される（バイト単位で不変）" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 21. §4.3: リーダー行のeffortが3者一致で追随する（modelとeffortの両方＝設計書§4.3「updateはmodelとeffortの両方へ追随」） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  write_v2_profile "$FAKE_HOME/.config/takumi009-ai-env/profile.md" \
    "configured provider=anthropic-api model=claude-sonnet-5 effort=high"
  LOCK="$WORK/lock"

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  assert_true "modelがプロファイルのリーダー行どおりに解決される" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('model')=='claude-sonnet-5' else 1)" && echo 1 || echo 0)"
  assert_true "effortLevelがプロファイルのリーダー行のeffortどおりに解決される" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('effortLevel')=='high' else 1)" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 21b. §4.3: リーダー行にeffort未指定ならeffortLevelキー自体が出力されない（正常な省略と解決失敗を混同しない・4.2-a） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  write_v2_profile "$FAKE_HOME/.config/takumi009-ai-env/profile.md" \
    "configured provider=anthropic-api model=claude-sonnet-5"
  LOCK="$WORK/lock"

  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  assert_true "effortLevelキー自体が存在しない" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if 'effortLevel' not in d else 1)" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 22. §11.2 項目3の受入条件（設計書§4.3・リーダー確認）: repoのHEADが不変でも、プロファイルのリーダー行だけを書き換えればsettings.jsonが追随する ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile "$PROFILE_PATH" "configured provider=anthropic-api model=claude-sonnet-5"
  LOCK="$WORK/lock"
  HEAD_BEFORE="$(git -C "$SUB" rev-parse HEAD)"

  out1="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)"
  assert_true "1回目: 変更なしメッセージが出る（HEAD不変）" \
    "$(echo "$out1" | grep -q '変更なし' && echo 1 || echo 0)"
  assert_true "1回目: modelはリーダー行どおり(claude-sonnet-5)" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('model')=='claude-sonnet-5' else 1)" && echo 1 || echo 0)"

  # ⚠️ repo($SUB)には一切触れず、ローカル実体プロファイルのリーダー行だけを
  # 書き換える（本人がエディタで1行編集する運用を模す）。
  write_v2_profile "$PROFILE_PATH" "configured provider=anthropic-api model=claude-opus-5 effort=low"
  HEAD_MID="$(git -C "$SUB" rev-parse HEAD)"
  assert_eq "リーダー行の書き換え自体はrepoのHEADを一切動かさない" "$HEAD_BEFORE" "$HEAD_MID"

  out2="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)"
  HEAD_AFTER="$(git -C "$SUB" rev-parse HEAD)"
  assert_eq "2回目もrepoのHEADは不変のまま（pull由来の変化ゼロ）" "$HEAD_BEFORE" "$HEAD_AFTER"
  assert_true "2回目: 変更なしメッセージが出る（HEAD不変のまま）" \
    "$(echo "$out2" | grep -q '変更なし' && echo 1 || echo 0)"
  assert_true "2回目: modelが書き換え後のリーダー行(claude-opus-5)へ追随する" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('model')=='claude-opus-5' else 1)" && echo 1 || echo 0)"
  assert_true "2回目: effortLevelも書き換え後のリーダー行(low)へ追随する" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('effortLevel')=='low' else 1)" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 23. §4.2-a契約検証: --print-leader-runtimeがeffortキーを空文字列で返す契約違反はJSON解析失敗として拒否しWARN＋非0終了する（未指定＝キー省略との混同を防ぐ・2026-09-01 Codex二次レビュー指摘・Major対応） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value"
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  cat > "$SUB/scripts/install-main.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --print-leader-runtime)
    echo '{"model": "claude-fable-5[1m]", "effort": ""}'
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$SUB/scripts/install-main.sh"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "空文字列effortは契約違反として非0終了する（§3.9）" "1" "$rc"
  assert_true "JSON解析失敗（契約違反）である旨のWARNが出る" \
    "$(echo "$out" | grep -q 'リーダー実行値のJSON解析に失敗しました' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "旧settings.jsonが変わらず残る" "$PRE_SHA" "$POST_SHA"

  rm -rf "$WORK"
}

echo "=== 24. §4.2-b契約検証: 標準エラーが複数行・タブ無し等の契約違反のときは生テキストを再掲せず汎用文言へ倒す（2026-09-01 Codex二次レビュー指摘・Major対応） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude"
  echo '{"model": "sentinel-pre-existing-value"}' > "$FAKE_HOME/.claude/settings.json"
  cat > "$SUB/scripts/install-main.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --print-leader-runtime)
    printf 'MULTI_LINE_STDERR_LINE_1\nMULTI_LINE_STDERR_LINE_2_MIGHT_LEAK\n' >&2
    exit 1
    ;;
esac
exit 1
EOF
  chmod +x "$SUB/scripts/install-main.sh"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "契約違反時も非0終了する" "1" "$rc"
  assert_true "契約違反である旨の汎用文言が出る" \
    "$(echo "$out" | grep -q '標準エラーの出力が契約' && echo 1 || echo 0)"
  assert_not_contains_helper2() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
  }
  assert_not_contains_helper2 "契約外の2行目の生テキストはログに出ない" "$out" "MIGHT_LEAK"

  rm -rf "$WORK"
}

echo "=== 25. §4.2-b契約検証: 構文上はcleanだが契約に無い未知の機械可読コードは拒否し、コード自体をログへ再掲しない（2026-09-01 Codex三次レビュー指摘・Major対応） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_settings_json_template "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude"
  echo '{"model": "sentinel-pre-existing-value"}' > "$FAKE_HOME/.claude/settings.json"
  cat > "$SUB/scripts/install-main.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --print-leader-runtime)
    printf 'UNKNOWN_SENSITIVE_CODE\tsome-reason\n' >&2
    exit 1
    ;;
esac
exit 1
EOF
  chmod +x "$SUB/scripts/install-main.sh"
  LOCK="$WORK/lock"

  rc=0
  out="$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)" || rc=$?

  assert_eq "契約外コードでも非0終了する" "1" "$rc"
  assert_true "契約違反である旨の汎用文言が出る" \
    "$(echo "$out" | grep -q '標準エラーの出力が契約' && echo 1 || echo 0)"
  assert_not_contains_helper2 "契約に無い未知コード自体はログに出ない" "$out" "UNKNOWN_SENSITIVE_CODE"

  rm -rf "$WORK"
}

echo "=== 26. 4d. claude/agents/*.md のsymlink化: 新規追加されたロール定義（例: vault-scribe.md）で、サブ機に既に実ファイルが置かれている場合は退避してからsymlink化する（本人指示・2026-09-03最優先・受入条件6） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  # サブ機に既に存在する「機体ローカルの実ファイル」を模す
  # （メイン機で~/.claude/agents/vault-scribe.mdが実ファイルだった状況と同型）。
  echo "サブ機ローカルの旧vault-scribe定義" > "$FAKE_HOME/.claude/agents/vault-scribe.md"

  # repoへvault-scribe.mdを新規追加（HEADを進める＝4.の実行条件）。
  add_agent_role "$SRC" "vault-scribe"

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  assert_true "更新検知メッセージが出る" \
    "$(echo "$out" | grep -q '更新を検知しました' && echo 1 || echo 0)"
  assert_true "既存の実ファイルが .pre-aienv.bak へ退避された旨が出る" \
    "$(echo "$out" | grep -q "backed up: $FAKE_HOME/.claude/agents/vault-scribe.md ->" && echo 1 || echo 0)"
  assert_true "退避先ファイルに旧内容が残っている" \
    "$([[ -f "$FAKE_HOME/.claude/agents/vault-scribe.md.pre-aienv.bak" ]] && grep -q 'サブ機ローカルの旧vault-scribe定義' "$FAKE_HOME/.claude/agents/vault-scribe.md.pre-aienv.bak" && echo 1 || echo 0)"
  assert_true "vault-scribe.mdがrepoを指すsymlinkになる" \
    "$([[ -L "$FAKE_HOME/.claude/agents/vault-scribe.md" ]] && echo 1 || echo 0)"
  assert_eq "symlink先がrepoのclaude/agents/vault-scribe.mdと一致する" \
    "$SUB/claude/agents/vault-scribe.md" "$(readlink "$FAKE_HOME/.claude/agents/vault-scribe.md")"
  assert_true "linkedログが出る" \
    "$(echo "$out" | grep -q "linked: $FAKE_HOME/.claude/agents/vault-scribe.md -> $SUB/claude/agents/vault-scribe.md" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 26b. 4d.: 既に正しいsymlinkが張られているロールは何もしない（no-op・退避ファイルを作らない） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_agent_role "$SRC" "vault-scribe"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  # 初回install-sub.sh相当で既に正しくsymlink済みの状態を模す。
  ln -s "$SUB/claude/agents/vault-scribe.md" "$FAKE_HOME/.claude/agents/vault-scribe.md"

  # HEADを進めるための無関係な変更（4.の実行条件を満たすため）。
  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  assert_true "既に正しいsymlinkのままである" \
    "$([[ -L "$FAKE_HOME/.claude/agents/vault-scribe.md" ]] && echo 1 || echo 0)"
  assert_eq "symlink先が変わっていない" \
    "$SUB/claude/agents/vault-scribe.md" "$(readlink "$FAKE_HOME/.claude/agents/vault-scribe.md")"
  assert_true ".pre-aienv.bakは作られない（symlinkは退避対象ではない）" \
    "$([[ ! -e "$FAKE_HOME/.claude/agents/vault-scribe.md.pre-aienv.bak" ]] && echo 1 || echo 0)"
  assert_true "linked/backed upのログは出ない（no-op）" \
    "$(echo "$out" | grep -Eq '(linked|backed up): .*vault-scribe\.md' && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo "=== 26c. 4d.: repoから削除されたロールへのdangling symlinkは削除せずWARNのみに留める（本人指示: 削除は本人判断） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  # claude/agents/ ディレクトリ自体は存在するが、retired-role.mdだけが
  # repoから既に削除されている状況を再現する（26g. のディレクトリ自体が
  # 丸ごと無いケースとは区別する＝Codexレビュー指摘対応でディレクトリ欠落と
  # 個別ロール削除を混同しないよう修正したため、fixture側もそれに合わせる）。
  add_agent_role "$SRC" "vault-scribe"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  # repoには存在しない旧ロールへのsymlink（dangling）を模す
  # （かつてrepoにあったが削除された想定。retiredされた職種を指すsymlinkを
  # 事前に作っておく）。
  ln -s "$SUB/claude/agents/retired-role.md" "$FAKE_HOME/.claude/agents/retired-role.md"

  # HEADを進めるための変更（4.の実行条件を満たすため）。
  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)
  assert_true "削除されたロールへのdangling symlink警告が出る" \
    "$(echo "$out" | grep -q "repoから削除されたロール定義へのsymlinkが残っています" && echo 1 || echo 0)"
  assert_true "symlink自体は削除されずに残る" \
    "$([[ -L "$FAKE_HOME/.claude/agents/retired-role.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 26d. 4d.: aienv管理下でないdangling symlink（\$AGENTS_SRC_DIR配下以外を指す）はWARN対象にしない（誤検知防止・Codexレビュー指摘対応） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  # dangling走査自体が実際に有効化される（agents_md_count>0）状態を作るため、
  # 少なくとも1件の管理対象ロールをrepoへ用意する（Codexフォローアップ
  # レビュー指摘・Minor対応: claude/agents/が空のままだと走査自体がskipされ、
  # このテストは`case`のフィルタを削除しても合格してしまっていた）。
  add_agent_role "$SRC" "vault-scribe"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  # repo外（本スクリプトが関与しないアプリ由来を模す）の実体無きsymlinkを置く。
  ln -s "$FAKE_HOME/somewhere-else/foreign-agent.md" "$FAKE_HOME/.claude/agents/foreign-agent.md"

  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)
  assert_true "dangling走査自体は実際に有効（vault-scribe.mdがsymlink化される）" \
    "$([[ -L "$FAKE_HOME/.claude/agents/vault-scribe.md" ]] && echo 1 || echo 0)"
  assert_true "aienv管理下でないdanglingは削除されたロールの警告対象にならない" \
    "$(echo "$out" | grep -q "foreign-agent" && echo 0 || echo 1)"
  assert_true "aienv管理下でないsymlinkのリンク先は変わらない（触らない）" \
    "$([[ "$(readlink "$FAKE_HOME/.claude/agents/foreign-agent.md")" = "$FAKE_HOME/somewhere-else/foreign-agent.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 26e. 4d.: 古いrepoパス・別ファイルを指す誤ったsymlinkは現在のrepoパスへ張り直す（no-opではなく修復する） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_agent_role "$SRC" "vault-scribe"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  # 別ファイルを指す誤ったsymlinkを模す（過去のパス変更・手動編集事故等）。
  ln -s "$SUB/claude/agents/nonexistent-old-name.md" "$FAKE_HOME/.claude/agents/vault-scribe.md"

  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1)
  assert_true "linkedログが出る（張り直しが実行された）" \
    "$(echo "$out" | grep -q "linked: $FAKE_HOME/.claude/agents/vault-scribe.md -> $SUB/claude/agents/vault-scribe.md" && echo 1 || echo 0)"
  assert_eq "symlink先が現在のrepoパスへ修復される" \
    "$SUB/claude/agents/vault-scribe.md" "$(readlink "$FAKE_HOME/.claude/agents/vault-scribe.md")"

  rm -rf "$WORK"
}

echo "=== 26f. 4d.: 既に .pre-aienv.bak が存在する場合は2回目以降の実行で上書き・二重退避しない ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  echo "サブ機ローカルの旧vault-scribe定義" > "$FAKE_HOME/.claude/agents/vault-scribe.md"
  add_agent_role "$SRC" "vault-scribe"

  # 1回目: 実ファイル退避＋symlink化。
  run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" >/dev/null

  # バックアップ作成後に何者かが.pre-aienv.bakの中身を書き換えたと仮定
  # （本物のオリジナルが既に退避済みであることの目印として、意図的に別内容へ
  # 書き換える＝2回目実行で上書きされたら退避規則違反として検出できる）。
  echo "退避直後の内容（これを上書きしてはいけない）" > "$FAKE_HOME/.claude/agents/vault-scribe.md.pre-aienv.bak"

  # symlinkを削除し、再び実ファイルへ戻す（.pre-aienv.bakが既にある状態で
  # destが実ファイルの分岐を実際に踏ませるため＝Codexフォローアップレビュー
  # 指摘・Minor対応: 2回目時点でdestが既にsymlinkのままだと`elif [ -e "$dest" ]`
  # 側のバックアップ判定コード自体が一切実行されず、`[ ! -e
  # "$dest.pre-aienv.bak" ]`を誤って消しても本テストは合格してしまっていた）。
  rm -f "$FAKE_HOME/.claude/agents/vault-scribe.md"
  echo "2回目実行時点でのローカル実ファイル（symlinkが何らかの理由で失われた想定）" \
    > "$FAKE_HOME/.claude/agents/vault-scribe.md"

  # 2回目: repoへさらに変更をpushしHEADを進め、update-sub.shを再実行する。
  echo "# 追加方針2" > "$SRC/vault-public/Preferences/rule3.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule3"
  git -C "$SRC" push -q origin HEAD:main
  out2=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")

  assert_eq ".pre-aienv.bakは2回目実行で上書きされない（二重退避しない）" \
    "退避直後の内容（これを上書きしてはいけない）" \
    "$(cat "$FAKE_HOME/.claude/agents/vault-scribe.md.pre-aienv.bak")"
  assert_true "backed upログは2回目では出ない（.pre-aienv.bakが既にあるため）" \
    "$(echo "$out2" | grep -q 'backed up:.*vault-scribe' && echo 0 || echo 1)"
  assert_true "symlinkとして復元される（実ファイルのままにはしない）" \
    "$([[ -L "$FAKE_HOME/.claude/agents/vault-scribe.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 26g. 4d.: claude/agents/ ディレクトリ自体が無い（checkout破損）場合はfailせずWARNのみで他の処理は続行する ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"
  # make_origin fixtureはclaude/agents/を持たない（意図的にディレクトリ欠落を再現）。

  # ディレクトリ丸ごと欠落時にdangling走査そのものが（誤発報防止のため）
  # skipされることも合わせて確認する（Codexフォローアップレビュー指摘・Minor
  # 対応: 既存symlinkが1つも無い状態だと「個別削除WARNが出ない」ことを
  # 検証できていなかった）。
  ln -s "$SUB/claude/agents/old-role.md" "$FAKE_HOME/.claude/agents/old-role.md"

  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add rule2"
  git -C "$SRC" push -q origin HEAD:main

  rc=0
  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK" 2>&1) || rc=$?
  assert_eq "exit code 0（agentsディレクトリ欠落だけでは致命的エラーにしない）" "0" "$rc"
  assert_true "claude/agents/欠落のWARNが出る" \
    "$(echo "$out" | grep -q 'claude/agents/ が見つかりません' && echo 1 || echo 0)"
  assert_true "ディレクトリ丸ごと欠落時は個別ロール削除のWARNは出ない（誤発報しない）" \
    "$(echo "$out" | grep -q '削除されたロール定義へのsymlinkが残っています' && echo 0 || echo 1)"
  assert_true "既存symlinkは削除されずそのまま残る" \
    "$([[ -L "$FAKE_HOME/.claude/agents/old-role.md" ]] && echo 1 || echo 0)"
  assert_true "4a. config.tomlは続行している" \
    "$([[ -f "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"
  assert_true "4b. Preferences再同期は続行している" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/rule2.md" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 26h. 2c.（旧4d）はHEADが不変でも実行される（本人実査・2026-09-03緊急対応の回帰テスト: 当初4d.は4.配下〈HEAD変化時のみ〉に置いており、サブ機の2回目以降の実行がHEAD不変で3.の早期終了に入るとagentsのsymlink化に一切到達しない実バグがあった。SUBを最初からrepoの最新HEADでclone〈＝pullで進む差分が無い〉した状態でも、まだsymlink化されていない実ファイルが正しくsymlink化されることを確認する） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_agent_role "$SRC" "vault-scribe"
  # SRCへvault-scribe.mdを追加した"後"にcloneする＝SUBは最初からrepoの最新HEAD
  # を持つ（pullで進む差分が存在しない）。
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"

  before_head_test="$(git -C "$SUB" rev-parse HEAD)"
  out=$(run_update "$SUB" "$FAKE_HOME" "$FAKE_HOME/Data/obsidian" "$LOCK")
  after_head_test="$(git -C "$SUB" rev-parse HEAD)"

  assert_eq "このテストの前提: pullで進むHEADの差分が実際に存在しない" "$before_head_test" "$after_head_test"
  assert_true "『変更なし』メッセージが出る（HEAD不変の経路を通っている証拠）" \
    "$(echo "$out" | grep -q '変更なし' && echo 1 || echo 0)"
  assert_true "HEAD不変でもvault-scribe.mdがsymlink化される（旧実装ならここが失敗していた）" \
    "$([[ -L "$FAKE_HOME/.claude/agents/vault-scribe.md" ]] && echo 1 || echo 0)"
  assert_true "4a.（config.toml再生成、HEAD変化時のみ）はHEAD不変のため実行されない（2c.との違いの確認）" \
    "$([[ ! -e "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 27. 自己更新対策: update-sub.sh自身がpullで更新された場合、新版のスクリプトへexecしなおして最初からやり直す（本人実査・2026-09-03緊急対応: bashはスクリプトを逐次読みするため、実行中の自分自身をpullで書き換えたまま処理を続けると不定動作になる実害があった。テスト③〈無限ループしない〉も兼ねる＝ログの重複有無で検証） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  add_agent_role "$SRC" "vault-scribe"
  # v1 = 実物のupdate-sub.sh（自己更新対応版そのもの）をrepoへ同梱する
  # （自己参照テストのため、テストハーネスの$SCRIPTではなく$SUB/scripts/
  # update-sub.shを直接bashで起動する＝本番のcronから手動実行される経路と
  # 同じ形）。
  cp "$REPO_ROOT/scripts/update-sub.sh" "$SRC/scripts/update-sub.sh"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "add v1 update-sub.sh"
  git -C "$SRC" push -q origin HEAD:main

  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian" "$FAKE_HOME/.claude/agents"
  LOCK="$WORK/lock"
  make_sub_marker "$FAKE_HOME"

  # v2 = v1の1行目（shebang）直後に実際に実行される識別用echoを差し込んだもの
  # （Codexフォローアップレビュー指摘・Nit対応: 単なる末尾コメントの追加だと
  # ファイルのバイト列が変わっただけの証明にしかならず、「re-exec後に実際に
  # v2の中身が実行された」ことまでは直接示せなかった。execで起動される
  # プロセスの最初の一手として必ず標準エラーに出る行を挿入することで、
  # v1が単に生き残って処理を続けたのではなく、v2へ確かに切り替わったことを
  # 直接観測できるようにする）。ロジック自体はv1と同じ自己更新対応版のまま。
  awk 'NR==1{print; print "echo \"V2-EXECUTED-MARKER\" >&2"; next} {print}' \
    "$REPO_ROOT/scripts/update-sub.sh" > "$SRC/scripts/update-sub.sh"
  echo "# 追加方針v2" > "$SRC/vault-public/Preferences/rule2.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "bump update-sub.sh to v2 + rule2"
  git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" bash "$SUB/scripts/update-sub.sh" 2>&1)" || rc=$?

  assert_eq "自己更新のre-exec後もexit 0で正常終了する" "0" "$rc"
  assert_true "自己更新検知のログが出る" \
    "$(echo "$out" | grep -q 'update-sub.sh自身が更新されました' && echo 1 || echo 0)"
  assert_true "新版で最初からやり直す旨のログが出る" \
    "$(echo "$out" | grep -q '新版のスクリプトで最初からやり直しています' && echo 1 || echo 0)"
  assert_true "v2固有の識別マーカーが実際に出る（v1が生き残ったのではなくv2へ確かに切り替わった直接証拠）" \
    "$(echo "$out" | grep -q 'V2-EXECUTED-MARKER' && echo 1 || echo 0)"
  assert_true "識別マーカーはre-exec後に1回だけ出る（v1側が誤って実行を続けていない証拠）" \
    "$([ "$(echo "$out" | grep -c 'V2-EXECUTED-MARKER')" -eq 1 ] && echo 1 || echo 0)"
  assert_true "『既に実行中です』にはならない（execがPIDを保つため自分自身のロックに阻まれない）" \
    "$(echo "$out" | grep -q '既に実行中です' && echo 0 || echo 1)"
  assert_true "再exec後の新版でagents symlink化(2c)が実行される" \
    "$([[ -L "$FAKE_HOME/.claude/agents/vault-scribe.md" ]] && echo 1 || echo 0)"
  assert_true "再exec後の新版で4b(Preferences再同期)も実行される（元のHEAD差分が正しく引き継がれている証拠。引き継ぎが無ければ『pull済みでHEAD不変』に見えて4a〜4cが空振りする）" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/rule2.md" ]] && echo 1 || echo 0)"
  assert_eq "自己更新の検知・再実行ログが1回だけ出る（無限ループしていない証拠）" \
    "1" "$(echo "$out" | grep -c 'update-sub.sh自身が更新されました')"
  assert_true "実行完了後、多重起動防止ロックファイルが残っていない（handoff方式でも最終的なEXIT trapが正しく発火しクリーンアップされる証拠。Codexフォローアップレビュー指摘・Minor対応）" \
    "$([[ ! -e "$LOCK" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 27c. 自己更新対策(handoff): ロックファイルのPIDは自分自身と一致するが指紋（プロセス開始時刻）が食い違う場合はfail-closedで拒否する（PID再利用対策。Codexフォローアップレビュー指摘・Major対応: 当初はPID一致だけで引き継いでおり、環境変数の誤残留＋異常終了した旧ロックの残留＋PID番号の再利用が偶然重なると、他プロセスのロックを誤って『自分のもの』として引き継いでしまう穴があった） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  make_sub_marker "$FAKE_HOME"

  orig_head="$(git -C "$SUB" rev-parse HEAD)"

  # update-sub.shの$$と実際に一致するPIDを、ロックファイル作成時点で
  # 前もって知ることはできない（$(...)で起動すると新しいPIDになるため）。
  # そこで小さな中継スクリプトを使う: 中継スクリプトは自分自身の$$（＝
  # execで置き換えた後もupdate-sub.shの$$と同一になる）で「PIDは一致するが
  # 指紋だけ食い違う」ロックファイルを書いてから、そのままexecでupdate-sub.sh
  # へ引き継ぐ（execはPIDを保つため、中継スクリプトが書いたPIDが
  # そのままupdate-sub.shの$$になる＝「たまたま自分と同じPID番号だが
  # 実際には別プロセスが書いた古いロック」というPID再利用シナリオの
  # 直接再現）。
  RELAY="$WORK/relay.sh"
  cat > "$RELAY" <<'RELAYEOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$$" "FAKE-DIFFERENT-FINGERPRINT-Thu-Jan-1-00:00:00-1970" > "$1"
shift
exec "$@"
RELAYEOF
  chmod +x "$RELAY"

  rc=0
  out="$(AIENV_UPDATE_SUB_REEXEC=1 AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD="$orig_head" \
    DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" \
    bash "$RELAY" "$LOCK" bash "$REPO_ROOT/scripts/update-sub.sh" 2>&1)" || rc=$?

  assert_eq "PID一致でも指紋が食い違えばexit 1(FAIL)で拒否する" "1" "$rc"
  assert_true "所有者が一致しない旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q '多重起動防止ロックの所有者が自分自身と一致しません' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 27d. 自己更新対策(handoff): 記録された指紋が『取得不能』予約値（FINGERPRINT-UNAVAILABLE）の場合はPIDが一致していてもfail-closedで拒否する（Codexフォローアップレビュー指摘・Major対応: 共有ライブラリ本体の_pid_lock_is_alive()は『他者の正当なロックを誤って削除しない』ためにこの予約値をPID生存のみで生存扱いへ倒すが、handoffは向きが逆＝『自分のものと証明できるか』が問われるため、証明できない予約値は受理してはならない） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  make_sub_marker "$FAKE_HOME"

  orig_head="$(git -C "$SUB" rev-parse HEAD)"

  # 27c.と同じ中継スクリプト方式で、PIDは正しく一致させたまま、指紋を
  # 「取得不能」予約値（scripts/lib/pid-lock.shの_PID_LOCK_FP_UNAVAILABLEと
  # 同じ文字列）にする。
  RELAY2="$WORK/relay2.sh"
  cat > "$RELAY2" <<'RELAYEOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$$" "FINGERPRINT-UNAVAILABLE" > "$1"
shift
exec "$@"
RELAYEOF
  chmod +x "$RELAY2"

  rc=0
  out="$(AIENV_UPDATE_SUB_REEXEC=1 AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD="$orig_head" \
    DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" \
    bash "$RELAY2" "$LOCK" bash "$REPO_ROOT/scripts/update-sub.sh" 2>&1)" || rc=$?

  assert_eq "指紋が『取得不能』予約値のままではPID一致だけでは受理せずexit 1(FAIL)で拒否する" "1" "$rc"
  assert_true "所有者が一致しない旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q '多重起動防止ロックの所有者が自分自身と一致しません' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 27b. 自己更新対策: AIENV_UPDATE_SUB_REEXECガードが立っていても、引き継ぐべき多重起動防止ロックが実在しない（execによる正当な引き継ぎではない）場合はfail-closedで拒否する（本人環境・LaunchAgent等へこの内部専用環境変数が誤って残留・伝播した場合の安全策。Codexフォローアップレビュー指摘・Minor対応: ロックを解放してから再取得する旧方式ではこの検証手段自体が無かったが、1.をhandoff方式へ変更したことで『引き継ぐべきロックが無ければ拒否する』という直接的なfail-closed経路が持てるようになった。無限ループしないことの直接証拠でもある＝サイレントにpullをスキップし続けず即fail()する） ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  FAKE_HOME="$WORK/home"
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  make_sub_marker "$FAKE_HOME"

  orig_head="$(git -C "$SUB" rev-parse HEAD)"

  # SUBがまだ取得していない、update-sub.sh自身を書き換える新しいcommitを
  # originへ用意する（ガードが誤って通ってしまった場合にpullで拾われ自己更新
  # チェックが発火するはずの状況を実在させ、そこへ到達しないことも併せて
  # 確認する）。
  mkdir -p "$SRC/scripts"
  printf '#!/usr/bin/env bash\n# pending self-update not yet pulled by SUB\n' > "$SRC/scripts/update-sub.sh"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "update-sub.sh has a pending update SUB hasn't pulled yet"
  git -C "$SRC" push -q origin HEAD:main

  # $LOCKはまだ一切存在しない＝正当なacquire_pid_lock()を経て取得された
  # ロックではない状態を模す（本物のre-execなら直前のプロセスが必ず
  # 取得済みのはず）。update-sub.sh本体は非0終了するため`|| true`で
  # set -e下でもテストスクリプト自体を落とさないようにする。
  rc=0
  out="$(AIENV_UPDATE_SUB_REEXEC=1 AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD="$orig_head" \
    DIR="$SUB" HOME="$FAKE_HOME" VAULT="$FAKE_HOME/Data/obsidian" LOCK_FILE="$LOCK" \
    bash "$REPO_ROOT/scripts/update-sub.sh" 2>&1)" || rc=$?

  after_head="$(git -C "$SUB" rev-parse HEAD)"
  assert_eq "引き継ぐべきロックが無ければexit 1(FAIL)で拒否する（サイレントにpullをスキップし続けない）" "1" "$rc"
  assert_true "ロックが見つからない旨のFAILメッセージが出る" \
    "$(echo "$out" | grep -q '引き継ぐべき多重起動防止ロックが見つかりません' && echo 1 || echo 0)"
  assert_eq "SUBのHEADはpullされず元のままである（fail-closedによりgit pull自体に到達しなかった証拠）" \
    "$orig_head" "$after_head"
  assert_true "自己更新チェックの検知ログ（自身が更新されました）は出ない（ロック確認で拒否されpull自体に到達しないため）" \
    "$(echo "$out" | grep -q 'update-sub.sh自身が更新されました' && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
