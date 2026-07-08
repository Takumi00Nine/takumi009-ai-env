#!/usr/bin/env bash
# scripts/update-sub.sh のユニットテスト。
#
# 実 ~/.codex・実Vault・実GitHubには一切依存しない。ローカルの使い捨てbare repo
# を「origin」に見立て、cloneしたサブ相当のrepoに対して update-sub.sh を実行する。
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
  mkdir -p "$src/codex" "$src/vault-public/Preferences"
  cat > "$src/codex/config.toml" <<'EOF'
service_tier = "default"
[mcp_servers.obsidian]
args = ["__AIENV_HOME__/Data/obsidian"]
EOF
  echo "# 初期方針" > "$src/vault-public/Preferences/rule1.md"
  git -C "$src" init -q
  git -C "$src" config user.name test
  git -C "$src" config user.email test@example.invalid
  git -C "$src" remote add origin "$bare"
  git -C "$src" add -A
  git -C "$src" commit -q -m init
  git -C "$src" push -q origin HEAD:main
}

# origin から clone した「サブ機相当」のrepoを作る。
make_sub_clone() {
  local bare="$1" sub="$2"
  git clone -q "$bare" "$sub"
  git -C "$sub" config user.name test
  git -C "$sub" config user.email test@example.invalid
}

run_update() {
  local dir="$1" home="$2" vault="$3" lock="$4"
  DIR="$dir" HOME="$home" VAULT="$vault" LOCK_FILE="$lock" "$SCRIPT"
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
  mkdir -p "$SUB"
  git -C "$SUB" init -q
  git -C "$SUB" config user.name test
  git -C "$SUB" config user.email test@example.invalid
  echo "x" > "$SUB/x.md"
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

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
