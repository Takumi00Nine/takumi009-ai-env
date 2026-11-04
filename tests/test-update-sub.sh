#!/usr/bin/env bash
# pull・導入・同期の順序と失敗時の非破壊。ローカル repo のみ使う。

set -euo pipefail

# macOS の BSD mktemp は裸の `mktemp -d` だと $TMPDIR を無視するため、必ず
# テンプレート付きで作る。$TMPDIR 末尾の / は剥がして二重スラッシュを避ける。
_TMPBASE="${TMPDIR:-/tmp}"
_TMPBASE="${_TMPBASE%/}"
[ -n "$_TMPBASE" ] || _TMPBASE="/tmp"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"

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

# calls_count — 偽 install-sub.sh の呼び出し回数（記録ファイルが無ければ 0）。
calls_count() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
# head_of <repo> — HEAD の commit id。
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null || echo ''; }

# 「origin」相当の bare repo と、そこへ push する作業コピー (src) を作る。
# 実物＝update-sub.sh・pid-lock.sh・profile_resolve.py／偽物＝install-sub.sh。
make_origin() {
  local bare="$1" src="$2"
  git init -q --bare "$bare"
  mkdir -p "$src/core/assembly" "$src/core/executor" "$src/team/executor" \
    "$src/ai-brain/data/vault-public/Preferences" "$src/ai-brain/data/vault-public/Fragments" "$src/ai-brain/data/vault-public/Decisions"
  cp "$REPO_ROOT/core/assembly/update-sub.sh" "$src/core/assembly/update-sub.sh"
  cp "$REPO_ROOT/core/executor/pid-lock.sh" "$src/core/executor/pid-lock.sh"
  cp "$REPO_ROOT/team/executor/profile_resolve.py" "$src/team/executor/profile_resolve.py"
  cat > "$src/core/assembly/install-sub.sh" <<'EOF'
#!/usr/bin/env bash
# 偽 install-sub.sh（テスト用）: 呼び出しを $CALLS へ記録し、$FAKE_INSTALL_SUB_RC で終わる。
echo "install-sub $*" >> "${CALLS:?}"
echo "[fake-install-sub] called (VAULT=${VAULT:-unset})"
exit "${FAKE_INSTALL_SUB_RC:-0}"
EOF
  chmod +x "$src/core/assembly/update-sub.sh" "$src/core/assembly/install-sub.sh"
  echo "# 初期方針" > "$src/ai-brain/data/vault-public/Preferences/rule1.md"
  echo "# Fragments 骨格" > "$src/ai-brain/data/vault-public/Fragments/README.md"
  echo "# Decisions 骨格" > "$src/ai-brain/data/vault-public/Decisions/README.md"
  git -C "$src" init -q
  git -C "$src" config user.name test
  git -C "$src" config user.email test@example.invalid
  git -C "$src" remote add origin "$bare"
  git -C "$src" add -A
  git -C "$src" commit -q -m init
  git -C "$src" push -q origin HEAD:main
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
}

# push_change <src> <msg> — src の作業ツリーの変更を commit して origin へ push する。
push_change() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  git -C "$1" push -q origin HEAD:main
}

# origin から clone した「サブ機相当」の repo を作る。
make_sub_clone() {
  local bare="$1" sub="$2"
  git clone -q "$bare" "$sub"
  git -C "$sub" config user.name test
  git -C "$sub" config user.email test@example.invalid
}

# make_sub_profile <home> [machine_role] — schema 8 の実体プロファイル＋models.conf
# を偽 HOME へ置く（既定＝machine_role: sub）。定義名は t- 接頭辞のダミー。
make_sub_profile() {
  local home="$1" role="${2:-sub}"
  mkdir -p "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
EOF
  cat > "$home/.config/takumi009-ai-env/profile.md" <<EOF
---
schema_version: 8
profile_slug: test-update-sub-machine
team_mode: configured value=team
no_read_paths: unavailable
machine_role: configured value=${role}
role.leader: configured model=t-sonnet-high
---
EOF
}

# new_case — 1 ケース分の fixture 一式をグローバルへ用意する:
#   WORK / BARE / SRC / SUB / FAKE_HOME / VAULT_DIR / LOCK / CALLS
# サブ機の Vault には「Preferences に消えるべき stale.md」「Fragments に消えては
# いけない mine.md」「Decisions/README.md（既存＝上書きされない）」を仕込む。
new_case() {
  WORK="$(mktemp -d "$_TMPBASE/test-update-sub.XXXXXX")"
  BARE="$WORK/origin.git"
  SRC="$WORK/src"
  SUB="$WORK/sub"
  FAKE_HOME="$WORK/home"
  VAULT_DIR="$FAKE_HOME/Data/obsidian"
  LOCK="$WORK/lock"
  CALLS="$WORK/install-sub.calls"
  make_origin "$BARE" "$SRC"
  make_sub_clone "$BARE" "$SUB"
  mkdir -p "$VAULT_DIR/Preferences" "$VAULT_DIR/Fragments" "$VAULT_DIR/Decisions"
  echo "stale" > "$VAULT_DIR/Preferences/stale.md"
  echo "mine" > "$VAULT_DIR/Fragments/mine.md"
  echo "keep" > "$VAULT_DIR/Decisions/README.md"
}

# run_update [extra args...] — clone 側の update-sub.sh を偽 HOME で実行する。
# 実体プロファイルは呼び出し元が置いていなければ machine_role: sub で自動設置。
run_update() {
  [ -f "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ] || make_sub_profile "$FAKE_HOME"
  CALLS="$CALLS" DIR="$SUB" HOME="$FAKE_HOME" VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    "$SUB/core/assembly/update-sub.sh" "$@"
}

echo "=== 1. US-1: pull 成功 → install-sub 1 回 → Preferences rsync → 骨格補充 → exit 0 ==="
{
  new_case
  echo "# 追加方針" > "$SRC/ai-brain/data/vault-public/Preferences/rule2.md"
  mkdir -p "$SRC/ai-brain/data/vault-public/Knowledge"
  echo "# Knowledge 骨格" > "$SRC/ai-brain/data/vault-public/Knowledge/README.md"
  push_change "$SRC" "add rule2 + Knowledge skeleton"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_true "pull して install-sub を呼ぶ" \
    "$([[ "$rc" -eq 0 && "$(head_of "$SRC")" == "$(head_of "$SUB")" && "$(calls_count)" == 1 ]] && echo 1 || echo 0)"
  assert_true "install-sub の後に Preferences を同期する" \
    "$([[ -f "$VAULT_DIR/Preferences/rule2.md" && ! -e "$VAULT_DIR/Preferences/stale.md" ]] && printf '%s\n' "$out" | grep -n -E 'fake-install-sub|Preferences を再同期' | head -1 | grep -q fake-install-sub && echo 1 || echo 0)"
  assert_true "個人ノートを保持し不足する骨格だけ補充する" \
    "$([[ "$(cat "$VAULT_DIR/Fragments/mine.md")" == mine && "$(cat "$VAULT_DIR/Decisions/README.md")" == keep && -f "$VAULT_DIR/Knowledge/README.md" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 3. US-3: pull 失敗（ff 不可）→ install-sub 0 回・exit 1・WARN・何も変えない ==="
{
  new_case
  echo "# origin 側の変更" > "$SRC/ai-brain/data/vault-public/Preferences/rule2.md"
  push_change "$SRC" "origin change"
  echo "# サブ側のローカル commit（ff 不可にする）" > "$SUB/ai-brain/data/vault-public/Preferences/local.md"
  git -C "$SUB" add -A
  git -C "$SUB" commit -q -m "local divergent commit"
  before="$(head_of "$SUB")"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_true "pull 失敗では導入・同期へ進まない" \
    "$([[ "$rc" -ne 0 && "$(calls_count)" == 0 && -f "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  assert_eq "pull 失敗でも HEAD は不変" "$before" "$(head_of "$SUB")"
  rm -rf "$WORK"
}

echo "=== 4. US-4: install-sub 非0 → 同じ rc で exit・FAIL＋復旧コマンド・rsync 0 回 ==="
{
  new_case
  echo "# 追加方針" > "$SRC/ai-brain/data/vault-public/Preferences/rule2.md"
  push_change "$SRC" "add rule2"

  rc=0
  out="$(FAKE_INSTALL_SUB_RC=3 run_update 2>&1)" || rc=$?
  assert_true "install-sub 失敗では rc を返して同期を止める" \
    "$([[ "$rc" -eq 3 && -f "$VAULT_DIR/Preferences/stale.md" && ! -e "$VAULT_DIR/Preferences/rule2.md" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 5. US-5: machine_role=main → exit 1・pull 0 回・lock も取らない（メイン機での誤実行を拒否） ==="
{
  new_case
  make_sub_profile "$FAKE_HOME" main
  echo "# origin 側の変更" > "$SRC/ai-brain/data/vault-public/Preferences/rule2.md"
  push_change "$SRC" "origin change"
  before="$(head_of "$SUB")"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_true "メイン機では pull・導入を拒否する" \
    "$([[ "$rc" -ne 0 && "$before" == "$(head_of "$SUB")" && "$(calls_count)" == 0 ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}


echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
