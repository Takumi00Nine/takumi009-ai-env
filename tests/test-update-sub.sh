#!/usr/bin/env bash
# scripts/update-sub.sh のユニットテスト（2026-09-19 全面書き直し＝ai-env 全体最適化
# 着手順 3・θ「update-sub は pull→install-sub 委譲の直列 1 本」）。
#
# 実 ~/.claude・~/.codex・実Vault・実GitHub・実 launchd には一切依存しない。
# ローカルの使い捨て bare repo を「origin」に見立て、clone したサブ相当の repo に
# 対して *その clone の中の* scripts/update-sub.sh を実行する（pull で自分自身が
# 書き換わるケース＝US-2 を実物で踏むため）。配置の委譲先 scripts/install-sub.sh は
# 偽物（呼び出しを $CALLS へ 1 行追記して指定の rc で終わる）＝update-sub.sh が
# 「いつ・何回呼ぶか」だけを見る。install-sub.sh 自体の挙動は tests/test-install-sub.sh。
#
# 見るのは形（exit code・固定文の有無・呼び出し回数・配置物の有無）だけ。
# 値の完全一致・件数表は使わない（Decisions/2026-09-17-tests-rough-not-strict）。
#
# 実行方法: bash tests/test-update-sub.sh

set -euo pipefail

# macOS の BSD mktemp は裸の `mktemp -d` だと $TMPDIR を無視するため、必ず
# テンプレート付きで作る。$TMPDIR 末尾の / は剥がして二重スラッシュを避ける。
_TMPBASE="${TMPDIR:-/tmp}"
_TMPBASE="${_TMPBASE%/}"
[ -n "$_TMPBASE" ] || _TMPBASE="/tmp"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

# has <text> <pattern> — 固定文の有無を 1/0 で返す（grep -F）。
has() { printf '%s\n' "$1" | grep -qF -- "$2" && echo 1 || echo 0; }
# calls_count — 偽 install-sub.sh の呼び出し回数（記録ファイルが無ければ 0）。
calls_count() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
# head_of <repo> — HEAD の commit id。
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null || echo ''; }

# 「origin」相当の bare repo と、そこへ push する作業コピー (src) を作る。
# 実物＝update-sub.sh・pid-lock.sh・profile_resolve.py／偽物＝install-sub.sh。
make_origin() {
  local bare="$1" src="$2"
  git init -q --bare "$bare"
  mkdir -p "$src/scripts/lib" "$src/claude/hooks/lib" \
    "$src/vault-public/Preferences" "$src/vault-public/Fragments" "$src/vault-public/Decisions"
  cp "$REPO_ROOT/scripts/update-sub.sh" "$src/scripts/update-sub.sh"
  cp "$REPO_ROOT/scripts/lib/pid-lock.sh" "$src/scripts/lib/pid-lock.sh"
  cp "$REPO_ROOT/claude/hooks/lib/profile_resolve.py" "$src/claude/hooks/lib/profile_resolve.py"
  cat > "$src/scripts/install-sub.sh" <<'EOF'
#!/usr/bin/env bash
# 偽 install-sub.sh（テスト用）: 呼び出しを $CALLS へ記録し、$FAKE_INSTALL_SUB_RC で終わる。
echo "install-sub $*" >> "${CALLS:?}"
echo "[fake-install-sub] called (VAULT=${VAULT:-unset})"
exit "${FAKE_INSTALL_SUB_RC:-0}"
EOF
  chmod +x "$src/scripts/update-sub.sh" "$src/scripts/install-sub.sh"
  echo "# 初期方針" > "$src/vault-public/Preferences/rule1.md"
  echo "# Fragments 骨格" > "$src/vault-public/Fragments/README.md"
  echo "# Decisions 骨格" > "$src/vault-public/Decisions/README.md"
  git -C "$src" init -q
  git -C "$src" config user.name test
  git -C "$src" config user.email test@example.invalid
  git -C "$src" remote add origin "$bare"
  git -C "$src" add -A
  git -C "$src" commit -q -m init
  git -C "$src" push -q origin HEAD:main
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

# make_sub_profile <home> [machine_role] — schema 7 の実体プロファイル＋models.conf
# を偽 HOME へ置く（既定＝machine_role: sub）。定義名は t- 接頭辞のダミー。
make_sub_profile() {
  local home="$1" role="${2:-sub}"
  mkdir -p "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5
EOF
  cat > "$home/.config/takumi009-ai-env/profile.md" <<EOF
---
schema_version: 7
profile_slug: test-update-sub-machine
team_mode: configured value=full
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
    "$SUB/scripts/update-sub.sh" "$@"
}

echo "=== 1. US-1: pull 成功 → install-sub 1 回 → Preferences rsync → 骨格補充 → exit 0 ==="
{
  new_case
  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  mkdir -p "$SRC/vault-public/Knowledge"
  echo "# Knowledge 骨格" > "$SRC/vault-public/Knowledge/README.md"
  push_change "$SRC" "add rule2 + Knowledge skeleton"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "HEAD が origin まで進んでいる" "$(head_of "$SRC")" "$(head_of "$SUB")"
  assert_eq "install-sub.sh の呼び出しは 1 回" "1" "$(calls_count)"
  assert_true "Preferences が rsync されている（rule1・rule2 あり・stale.md は --delete で消える）" \
    "$([[ -f "$VAULT_DIR/Preferences/rule1.md" && -f "$VAULT_DIR/Preferences/rule2.md" && ! -e "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  assert_true "Preferences 以外には触らない（Fragments/mine.md が残る）" \
    "$([[ -f "$VAULT_DIR/Fragments/mine.md" ]] && echo 1 || echo 0)"
  assert_true "新しい骨格フォルダ Knowledge が README.md 付きで補充される" \
    "$([[ -f "$VAULT_DIR/Knowledge/README.md" ]] && echo 1 || echo 0)"
  assert_eq "既存の骨格フォルダ Decisions/README.md は上書きされない" "keep" "$(cat "$VAULT_DIR/Decisions/README.md")"
  assert_true "done. で終わる" "$(has "$out" "done.")"
  assert_true "順序: install-sub の呼び出しが Preferences 同期より先" \
    "$(printf '%s\n' "$out" | grep -n -E 'fake-install-sub|Preferences を再同期' | head -1 | grep -q 'fake-install-sub' && echo 1 || echo 0)"
  assert_true "US-1 pull 成功→install-sub 1 回→Preferences rsync→exit 0" \
    "$([[ "$rc" -eq 0 && "$(calls_count)" == "1" && -f "$VAULT_DIR/Preferences/rule2.md" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 2. US-2: HEAD 不変でも install-sub 1 回（--resync の代替）／pull が update-sub.sh 自身を書き換えても旧本文で完走 ==="
{
  new_case
  # (i) origin と同じ HEAD＝pull で何も進まない
  rc1=0
  out1="$(run_update 2>&1)" || rc1=$?
  assert_eq "HEAD 不変: exit code 0" "0" "$rc1"
  assert_eq "HEAD 不変: install-sub.sh は 1 回呼ばれる" "1" "$(calls_count)"
  assert_true "HEAD 不変: Preferences は毎回同期される（stale.md が消える）" \
    "$([[ ! -e "$VAULT_DIR/Preferences/stale.md" && -f "$VAULT_DIR/Preferences/rule1.md" ]] && echo 1 || echo 0)"

  # (ii) origin で update-sub.sh 自身を「別物」に差し替える＝pull で実行中の自分が書き換わる
  cat > "$SRC/scripts/update-sub.sh" <<'EOF'
#!/usr/bin/env bash
echo "NEWVERSION-RAN"
exit 99
EOF
  push_change "$SRC" "replace update-sub.sh"
  rc2=0
  out2="$(run_update 2>&1)" || rc2=$?
  assert_eq "自己書き換え: pull で clone 側の update-sub.sh が新版（別物）になっている" \
    "$(cat "$SRC/scripts/update-sub.sh")" "$(cat "$SUB/scripts/update-sub.sh")"
  assert_eq "自己書き換え: 旧本文のまま exit 0 で完走（新版の exit 99 にならない）" "0" "$rc2"
  assert_eq "自己書き換え: 新版の本文は実行されない" "0" "$(has "$out2" "NEWVERSION-RAN")"
  assert_eq "自己書き換え: install-sub.sh は通算 2 回（この run で 1 回）" "2" "$(calls_count)"
  assert_true "自己書き換え: done. まで到達" "$(has "$out2" "done.")"
  assert_true "US-2 HEAD 不変でも install-sub 1 回・自己書き換え pull でも旧本文で完走" \
    "$([[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$(calls_count)" == "2" && "$(has "$out2" "NEWVERSION-RAN")" == "0" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 3. US-3: pull 失敗（ff 不可）→ install-sub 0 回・exit 1・WARN・何も変えない ==="
{
  new_case
  echo "# origin 側の変更" > "$SRC/vault-public/Preferences/rule2.md"
  push_change "$SRC" "origin change"
  echo "# サブ側のローカル commit（ff 不可にする）" > "$SUB/vault-public/Preferences/local.md"
  git -C "$SUB" add -A
  git -C "$SUB" commit -q -m "local divergent commit"
  before="$(head_of "$SUB")"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "WARN: git pull --ff-only に失敗 が出る" "$(has "$out" "git pull --ff-only に失敗")"
  assert_eq "install-sub.sh は呼ばれない" "0" "$(calls_count)"
  assert_eq "HEAD は動かない" "$before" "$(head_of "$SUB")"
  assert_true "Preferences も触らない（stale.md が残る）" "$([[ -f "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  assert_true "ロックは解放されている（次回 run を阻まない）" "$([[ ! -e "$LOCK" ]] && echo 1 || echo 0)"
  assert_true "US-3 pull 失敗→install-sub 0 回・exit 1・stderr に git pull --ff-only に失敗" \
    "$([[ "$rc" -eq 1 && "$(calls_count)" == "0" && "$(has "$out" "git pull --ff-only に失敗")" == "1" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 4. US-4: install-sub 非0 → 同じ rc で exit・FAIL＋復旧コマンド・rsync 0 回 ==="
{
  new_case
  echo "# 追加方針" > "$SRC/vault-public/Preferences/rule2.md"
  push_change "$SRC" "add rule2"

  rc=0
  out="$(FAKE_INSTALL_SUB_RC=3 run_update 2>&1)" || rc=$?
  assert_eq "exit code は install-sub の rc（3）そのまま" "3" "$rc"
  assert_true "FAIL: install-sub.sh が非0終了 が出る" "$(has "$out" "install-sub.sh が非0終了")"
  assert_true "復旧コマンド（scripts/install-sub.sh を現地で再実行）が出る" "$(has "$out" "scripts/install-sub.sh を現地で再実行")"
  assert_eq "install-sub.sh の呼び出しは 1 回" "1" "$(calls_count)"
  assert_true "rsync は走らない（stale.md が残る・rule2 は来ない）" \
    "$([[ -f "$VAULT_DIR/Preferences/stale.md" && ! -e "$VAULT_DIR/Preferences/rule2.md" ]] && echo 1 || echo 0)"
  assert_eq "HEAD は進んでいる（pull 済み＝次回 run で収束）" "$(head_of "$SRC")" "$(head_of "$SUB")"
  assert_true "US-4 install-sub 非0→exit 同 rc・install-sub.sh が非0終了・rsync 0 回" \
    "$([[ "$rc" -eq 3 && "$(has "$out" "install-sub.sh が非0終了")" == "1" && -f "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 5. US-5: machine_role=main → exit 1・pull 0 回・lock も取らない（メイン機での誤実行を拒否） ==="
{
  new_case
  make_sub_profile "$FAKE_HOME" main
  echo "# origin 側の変更" > "$SRC/vault-public/Preferences/rule2.md"
  push_change "$SRC" "origin change"
  before="$(head_of "$SUB")"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "FAIL: サブ機として登録されていません が出る" "$(has "$out" "サブ機として登録されていません")"
  assert_eq "pull しない（HEAD 不変）" "$before" "$(head_of "$SUB")"
  assert_eq "install-sub.sh は呼ばれない" "0" "$(calls_count)"
  assert_true "Preferences は触らない（stale.md が残る）" "$([[ -f "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  assert_true "ロックファイルは作られない" "$([[ ! -e "$LOCK" ]] && echo 1 || echo 0)"
  assert_true "US-5 machine_role=main→exit 1・pull 0 回" \
    "$([[ "$rc" -eq 1 && "$before" == "$(head_of "$SUB")" && "$(calls_count)" == "0" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 6. US-6: lock 保持中（生存 PID）→ exit 1・pull 0 回 ==="
{
  new_case
  echo "$$" > "$LOCK"
  echo "# origin 側の変更" > "$SRC/vault-public/Preferences/rule2.md"
  push_change "$SRC" "origin change"
  before="$(head_of "$SUB")"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "既に実行中です（保持 PID 入り）が出る" "$(has "$out" "既に実行中です（pid=$$）")"
  assert_eq "pull しない（HEAD 不変）" "$before" "$(head_of "$SUB")"
  assert_eq "install-sub.sh は呼ばれない" "0" "$(calls_count)"
  assert_true "他プロセスのロックを消さない" "$([[ "$(cat "$LOCK")" == "$$" ]] && echo 1 || echo 0)"
  assert_true "US-6 lock 保持中→exit 1" "$([[ "$rc" -eq 1 && "$(calls_count)" == "0" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 7. 引数: --resync を含め引数は一切受け付けない（exit 1・何もしない） ==="
{
  new_case
  rc=0
  out="$(run_update --resync 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "引数は受け付けません が出る" "$(has "$out" "引数は受け付けません")"
  assert_eq "install-sub.sh は呼ばれない" "0" "$(calls_count)"
  rm -rf "$WORK"
}

echo "=== 8. machine_role: 実体プロファイルが無ければ fail-closed で拒否する（ja_JP.UTF-8 でも FAIL 文が握り潰されない） ==="
{
  new_case
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"   # profile.md は置かない
  rc=0
  out="$(LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 CALLS="$CALLS" DIR="$SUB" HOME="$FAKE_HOME" VAULT="$VAULT_DIR" LOCK_FILE="$LOCK" \
    "$SUB/scripts/update-sub.sh" 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "FAIL: サブ機として登録されていません が出る" "$(has "$out" "サブ機として登録されていません")"
  assert_true "実体プロファイルのパスが FAIL 文に出る" "$(has "$out" "$FAKE_HOME/.config/takumi009-ai-env/profile.md")"
  assert_eq "unbound variable で落ちていない" "0" "$(has "$out" "unbound variable")"
  assert_eq "install-sub.sh は呼ばれない" "0" "$(calls_count)"
  rm -rf "$WORK"
}

echo "=== 9. lock: stale（PID 死亡）のロックは回収して続行する ==="
{
  new_case
  # 既に終了した子プロセスの PID を書く（指紋行なし＝旧形式扱い・mtime を古くする）
  ( : ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  echo "$dead_pid" > "$LOCK"
  touch -t 202001010000 "$LOCK"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "stale ロックを検出した WARN が出る" "$(has "$out" "stale")"
  assert_eq "install-sub.sh は 1 回呼ばれる" "1" "$(calls_count)"
  assert_true "終了後にロックは解放されている" "$([[ ! -e "$LOCK" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 10. rsync: 同期元 vault-public/Preferences が欠けていれば FAIL・exit 1（install-sub は済んでいる） ==="
{
  new_case
  git -C "$SRC" rm -q -r vault-public/Preferences
  push_change "$SRC" "drop Preferences (checkout破損の再現)"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "FAIL: Preferences の rsync に失敗しました が出る" "$(has "$out" "Preferences の rsync に失敗しました")"
  assert_eq "install-sub.sh は 1 回呼ばれている（失敗は rsync 段）" "1" "$(calls_count)"
  assert_true "サブ機側の Preferences は消えない（stale.md が残る）" "$([[ -f "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 11. 骨格補充: Vault に書けなければ FAIL・exit 1（Preferences 同期は済んでいる） ==="
{
  new_case
  mkdir -p "$SRC/vault-public/Knowledge"
  echo "# Knowledge 骨格" > "$SRC/vault-public/Knowledge/README.md"
  push_change "$SRC" "add Knowledge skeleton"
  chmod 555 "$VAULT_DIR"

  rc=0
  out="$(run_update 2>&1)" || rc=$?
  chmod 755 "$VAULT_DIR"
  assert_eq "exit code 1" "1" "$rc"
  assert_true "FAIL: 骨格フォルダを作成できません が出る" "$(has "$out" "骨格フォルダを作成できません")"
  assert_true "Preferences の同期は済んでいる（stale.md は消えている）" "$([[ ! -e "$VAULT_DIR/Preferences/stale.md" ]] && echo 1 || echo 0)"
  assert_true "Knowledge は作られていない" "$([[ ! -e "$VAULT_DIR/Knowledge" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 12. 冪等: 同じ状態で 2 回続けて実行しても exit 0・毎回 install-sub が呼ばれる ==="
{
  new_case
  rc=0
  run_update >/dev/null 2>&1 || rc=$?
  run_update >/dev/null 2>&1 || rc=$?
  assert_eq "2 回とも exit 0" "0" "$rc"
  assert_eq "install-sub.sh は 2 回（HEAD 不変でも毎回）" "2" "$(calls_count)"
  assert_true "Fragments/mine.md は 2 回目も残る" "$([[ -f "$VAULT_DIR/Fragments/mine.md" ]] && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
