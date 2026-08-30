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
# tests/test-check-drift.shと同じ＝--print-modelは他の全処理より先にexitする
# 副作用ゼロの経路のため、fixture内で呼んでも実システムに一切触れない。
add_settings_json_template() {
  local src="$1"
  mkdir -p "$src/scripts" "$src/claude"
  cat > "$src/claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(npm test)"]
  },
  "model": "__AIENV_MODEL__"
}
EOF
  cp "$REPO_ROOT/scripts/install-main.sh" "$src/scripts/install-main.sh"
  chmod +x "$src/scripts/install-main.sh"
  git -C "$src" add -A
  git -C "$src" commit -q -m "add settings.json template + install-main.sh"
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
  assert_true "modelはサブ既定値(claude-opus-5)へ解決される（値出力口＝install-main.sh --print-model --sub-delegate）" \
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

    assert_eq "settings.json再生成が中止されてもupdate-sub.sh全体はexit 0で完走する" "0" "$rc"
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

  assert_eq "settings.json再生成が中止されてもupdate-sub.sh全体はexit 0で完走する" "0" "$rc"
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

  assert_eq "settings.json再生成が中止されてもupdate-sub.sh全体はexit 0で完走する" "0" "$rc"
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

  assert_eq "settings.json再生成が中止されてもupdate-sub.sh全体はexit 0で完走する" "0" "$rc"
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

  assert_eq "settings.json再生成が中止されてもupdate-sub.sh全体はexit 0で完走する" "0" "$rc"
  assert_true "通常ファイルではない旨のWARNが出る（探索権限不足もABSENT扱いにされない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

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

echo "=== 16b. settings.json再生成: model値の出力口が部分出力を残しつつ非0終了しても、取得失敗として扱い既存settings.jsonを保持する（2026-08-30 Codex四次レビュー指摘・MAJOR対応: 従来は\$MODEL_VALUEが非空かどうかだけで成功/失敗を判定しており、部分出力を残す非0終了を誤って成功扱いし、BEDROCK_STATUS/BEDROCK_PAYLOAD未初期化のままset -u下で異常終了しうる欠陥があった） ==="
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
  # install-main.shを「--print-model --sub-delegateへ部分出力を残しつつ
  # 非0終了する」スタブへ差し替える。
  cat > "$SUB/scripts/install-main.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --print-model)
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

  assert_eq "update-sub.sh全体はexit 0で完走する(set -uでの異常終了が再発しない)" "0" "$rc"
  assert_true "model値の取得に失敗した旨のWARNが出る" \
    "$(echo "$out" | grep -q 'model値の取得に失敗しました' && echo 1 || echo 0)"
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
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME_INSTALLER" bash "$REPO_ROOT/scripts/install-main.sh" --sub-delegate >/dev/null 2>&1

  # --- update-sub.sh（pull経路。SUBクローン＝add_settings_json_templateが
  #     $SRCへ実物のinstall-main.shをコピー済みなので--print-*系は動く）---
  FAKE_HOME_UPDATER="$WORK/home_updater"
  mkdir -p "$FAKE_HOME_UPDATER/.codex" "$FAKE_HOME_UPDATER/Data/obsidian" "$FAKE_HOME_UPDATER/.config/takumi009-ai-env"
  printf '%s\n' "$ENV_CONTENT" > "$FAKE_HOME_UPDATER/.config/takumi009-ai-env/bedrock.env"
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

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
