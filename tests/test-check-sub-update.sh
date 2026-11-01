#!/usr/bin/env bash
# 機役割による案内の許可・抑止と fetch 失敗時の継続。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/core/assembly/check-sub-update.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# 「origin」相当のbare repoと、そこへpushするための作業コピー(SRC)を作る。
make_origin() {
  local bare="$1" src="$2"
  git init -q --bare "$bare"
  mkdir -p "$src"
  echo "# 初期状態" > "$src/README.md"
  git -C "$src" init -q
  git -C "$src" config user.name test
  git -C "$src" config user.email test@example.invalid
  git -C "$src" remote add origin "$bare"
  git -C "$src" add -A
  git -C "$src" commit -q -m init
  git -C "$src" push -q origin HEAD:main
  # bare側のシンボリックHEADをmainへ明示的に設定する（Codex一次レビュー指摘・
  # Major対応: `git init --bare`直後のデフォルトブランチ名は`init.defaultBranch`の
  # ローカル/グローバルgit設定に依存するため、`master`が既定の環境では
  # `HEAD:main`へpushしただけではbare側のHEADが未成立のままになり、clone後の
  # サブ側で`rev-list HEAD..origin/main`が失敗する非hermeticなfixtureになって
  # いた。`init.defaultBranch`の値に依存しないよう明示的にHEADを張り直す）。
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
}

make_sub_clone() {
  local bare="$1" sub="$2"
  git clone -q "$bare" "$sub"
  git -C "$sub" config user.name test
  git -C "$sub" config user.email test@example.invalid
}

# ローカル実体プロファイル（schema 5・新3キー）を作る。$2はmachine_role行の
# 状態＋属性部分（既定 "configured value=sub"）。配役表-能力軸整理-設計-
# 2026-09-07.md §6.1のFX-P1と同型の共通ベースを使う。
write_profile() {
  local path="$1" mr="${2:-configured value=sub}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
schema_version: 7
profile_slug: test-check-sub-update-machine
team_mode: configured value=full
no_read_paths: unavailable
machine_role: ${mr}
role.leader: configured model=t-sonnet-high
---
EOF
  # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§11.3・schema6）:
  # role.leaderがmodel=<定義名>だけになったため、定義の実体（provider/model）
  # をこのプロファイルと同じディレクトリのmodels.confへ置く。run_hook()/
  # run_hook_home()がAIENV_MODEL_DEFS_FILEをこのパスへ向ける（向け忘れると
  # 本人の実ファイルを読みに行くため必ず対にする）。
  cat > "$(dirname "$path")/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
EOF
}

# フックを実行し、標準出力(additionalContext抽出済み)を返す。$2はローカル実体
# プロファイルのパス（無ければ「解決失敗」＝メイン機扱いのfail-closed経路）。
# AIENV_BEDROCK_ENV_FILEは実行機のホームを参照させないようWORK配下の
# 実在しないパスへ固定する（テストのhermeticity）。
run_hook() {
  local dir="$1" profile="$2" log="$3" timeout_secs="${4:-5}" stdin_json="${5:-\{\}}"
  printf '%s' "$stdin_json" \
    | CHECK_SUB_UPDATE_DIR="$dir" AIENV_LOCAL_PROFILE_PATH="$profile" \
      AIENV_MODEL_DEFS_FILE="$(dirname "$profile")/models.conf" \
      AIENV_BEDROCK_ENV_FILE="$(dirname "$log")/nonexistent-bedrock.env" \
      CHECK_SUB_UPDATE_LOG="$log" CHECK_SUB_UPDATE_TIMEOUT="$timeout_secs" "$SCRIPT"
}


echo "=== 1. メイン機判定: 配役表が解決できなければ無出力・exit 0(fail-closed) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  PROFILE="$WORK/nonexistent-profile-dir/profile.md"
  # upstreamに変更をpushして「本来なら通知が出るはず」の状況を作る
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$PROFILE" "$WORK/log.txt")" || rc=$?
  assert_true "プロファイル無しは無出力・exit 0" "$([[ "$rc" -eq 0 && -z "$out" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2. メイン機判定: machine_roleが「sub」以外(例: main)なら無出力・exit 0 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  PROFILE="$WORK/profile.md"
  write_profile "$PROFILE" "configured value=main"
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$PROFILE" "$WORK/log.txt")" || rc=$?
  assert_true "メイン機は無出力・exit 0" "$([[ "$rc" -eq 0 && -z "$out" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 5. サブ機・1コミット遅れ: 案内メッセージが出る ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  PROFILE="$WORK/profile.md"
  write_profile "$PROFILE"
  echo "追加1" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update1" && git -C "$SRC" push -q origin HEAD:main

  out="$(run_hook "$SUB" "$PROFILE" "$WORK/log.txt")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_true "SessionStartのhookEventNameが正しい" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' | grep -q '^SessionStart$' && echo 1 || echo 0)"
  assert_true "サブ機に更新コマンドを案内する" \
    "$(printf '%s' "$ctx" | grep -qF "$SUB/core/assembly/update-sub.sh" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 8. fetch失敗(存在しないremote): 静かにexit 0・失敗はログに残す(fail-openだが無言ではない) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  git -C "$SUB" remote set-url origin "$WORK/no-such-origin.git"
  PROFILE="$WORK/profile.md"
  write_profile "$PROFILE"

  rc=0
  out="$(run_hook "$SUB" "$PROFILE" "$WORK/log.txt" 3)" || rc=$?
  assert_true "fetch 失敗でもセッションを止めず、ログに記録する" \
    "$([[ "$rc" -eq 0 && -z "$out" ]] && grep -q 'git fetch failed' "$WORK/log.txt" && echo 1 || echo 0)"

  rm -rf "$WORK"
}


echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
