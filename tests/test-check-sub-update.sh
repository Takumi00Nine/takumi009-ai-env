#!/usr/bin/env bash
# claude/hooks/check-sub-update.sh のユニットテスト。
#
# 実 ~/Data/obsidian・実 ~/work/takumi009-ai-env・実GitHubには一切依存しない。
# ローカルの使い捨てbare repoを「origin」に見立て、cloneしたサブ相当のrepoに
# 対してフックを実行する（tests/test-update-sub.shと同じ考え方）。
#
# 2026-07-24: メイン/サブ判定をVaultのprivate層ファイル不在（否定証明）から
# machine-roleマーカーファイル（積極的な証明。既定値はscripts/install-sub.sh・
# scripts/update-sub.shと共有）方式へ変更した（リーダー裁定・Codex一次レビュー
# 指摘Major対応）。旧1〜2番（private層ファイル存在によるメイン機判定）は
# マーカー方式の1〜2番へ差し替えた。CHECK_SUB_UPDATE_VAULTはもう使われないため
# run_hook()から除去し、AIENV_MACHINE_ROLE_MARKERへ差し替えた。
#
# 実行方法: bash tests/test-check-sub-update.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/claude/hooks/check-sub-update.sh"

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

# machine-roleマーカーファイルを作る（既定content="sub"）。
make_sub_marker() {
  local marker="$1" content="${2:-sub}"
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' "$content" > "$marker"
}

# フックを実行し、標準出力(additionalContext抽出済み)を返す。
run_hook() {
  local dir="$1" marker="$2" log="$3" timeout_secs="${4:-5}" stdin_json="${5:-\{\}}"
  printf '%s' "$stdin_json" \
    | CHECK_SUB_UPDATE_DIR="$dir" AIENV_MACHINE_ROLE_MARKER="$marker" \
      CHECK_SUB_UPDATE_LOG="$log" CHECK_SUB_UPDATE_TIMEOUT="$timeout_secs" "$SCRIPT"
}

echo "=== 1. メイン機判定: machine-roleマーカーが存在しなければ無出力・exit 0(fail-closed) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/nonexistent-marker-dir/machine-role"
  # upstreamに変更をpushして「本来なら通知が出るはず」の状況を作る
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "マーカー無しは無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 2. メイン機判定: machine-roleマーカーの中身が「sub」以外(例: main)なら無出力・exit 0 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER" "main"
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "中身がmainなら無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 2b. メイン機判定: machine-roleマーカーの中身が空文字列でも無出力・exit 0 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  : > "$MARKER"
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "中身が空なら無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 2c. サブ機判定: machine-roleマーカーの中身が前後空白付きの「sub」でも正常動作する(trim確認) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  printf '  sub  \n' > "$MARKER"
  echo "追加1" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update1" && git -C "$SRC" push -q origin HEAD:main

  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_true "前後空白付きでも遅れ1コミットの案内が出る" \
    "$(printf '%s' "$ctx" | grep -q '1 コミット遅れ' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2e. メイン機判定: machine-roleマーカーの中身が「s u b」(内部に空白を含む)なら「sub」と誤認せず無出力(Codex再レビュー指摘Minor対応: tr -d '[:space:]'は内部の空白も消してしまう穴があった) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  printf 's u b\n' > "$MARKER"
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "内部に空白を含む中身は「sub」と誤認されず無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 3. ワーカー/サブエージェント起動時(agent_type付き)はスキップする(サブ機・遅れありでも無出力) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt" 5 '{"agent_type":"worker"}')" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "ワーカー起動時は無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 4. サブ機・最新(遅れ0件): 無出力・exit 0 ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "最新なら無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 5. サブ機・1コミット遅れ: 案内メッセージが出る ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"
  echo "追加1" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update1" && git -C "$SRC" push -q origin HEAD:main

  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_true "SessionStartのhookEventNameが正しい" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' | grep -q '^SessionStart$' && echo 1 || echo 0)"
  assert_true "遅れ1コミットの文言が出る" \
    "$(printf '%s' "$ctx" | grep -q '1 コミット遅れ' && echo 1 || echo 0)"
  assert_true "手動実行コマンドの案内が出る(update-sub.shへの実パス)" \
    "$(printf '%s' "$ctx" | grep -qF "$SUB/scripts/update-sub.sh" && echo 1 || echo 0)"
  assert_true "セッション内実行の ! プレフィックス形式で案内される" \
    "$(printf '%s' "$ctx" | grep -qF "\`! $SUB/scripts/update-sub.sh\`" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 6. サブ機・3コミット遅れ: 件数が正しく反映される ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"
  for i in 1 2 3; do
    echo "追加$i" >> "$SRC/README.md"
    git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update$i"
  done
  git -C "$SRC" push -q origin HEAD:main

  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  assert_true "遅れ3コミットの文言が出る" \
    "$(printf '%s' "$ctx" | grep -q '3 コミット遅れ' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 7. リポジトリが無い(.git無し): 無出力・exit 0 ==="
{
  WORK="$(mktemp -d)"
  NOREPO="$WORK/norepo"
  mkdir -p "$NOREPO"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"

  rc=0
  out="$(run_hook "$NOREPO" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_eq "リポジトリが無ければ無出力" "" "$out"

  rm -rf "$WORK"
}

echo "=== 8. fetch失敗(存在しないremote): 静かにexit 0・失敗はログに残す(fail-openだが無言ではない) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  git -C "$SUB" remote set-url origin "https://127.0.0.1:1/does-not-exist.git"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt" 3)" || rc=$?
  assert_eq "exit 0(fail-open)" "0" "$rc"
  assert_eq "fetch失敗時は無出力" "" "$out"
  assert_true "失敗がログファイルに記録される(無言のfail-openにはしない)" \
    "$([[ -s "$WORK/log.txt" ]] && grep -q 'git fetch failed' "$WORK/log.txt" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 9. fetchが応答しない(決定的fixture): 設定タイムアウト秒数以内に必ず終了しexit 0になり、TERMを無視する孫プロセスもKILLで確実に後始末される ==="
{
  # Codex一次レビュー指摘・Major/Minor対応:
  # - 従来はブラックホールIP宛の実ネットワーク到達不能に頼っていたが、環境に
  #   よっては即座に「到達不能」判定（経路無し等）でfetchが早期に失敗し得るため、
  #   「本当にタイムアウト機構が効いてハングを止めたか」を確実に検証できていな
  #   かった（即時失敗でも見かけ上パスしてしまう）。
  # - また、当初のrun_with_timeout()実装は`git fetch`本体のPIDにしかTERM/KILLを
  #   送れず、gitが内部で起動する子孫プロセス（git-remote-https等）が生き残る
  #   可能性があった。
  # この2点を同時に検証するため、PATH上に「fetch呼び出し時にSIGTERMを無視し、
  # 孫プロセス(sleep)を起動してから終了まで無限に待つ」偽の`git`を配置する
  # （他のgitサブコマンドは本物のgitへ委譲する）。これにより
  # (a) 何があっても指定タイムアウト+猶予以内に必ず終了すること
  # (b) 孫プロセスまで含めてプロセスグループごと後始末されること（残骸なし）
  # の両方を決定的に検証する。
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  git init -q --bare "$BARE"
  SUB="$WORK/sub"
  git clone -q "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"

  REAL_GIT="$(command -v git)"
  STUB_BIN="$(mktemp -d)"
  CHILD_PID_FILE="$WORK/child.pid"
  cat > "$STUB_BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "fetch" ]; then
    trap '' TERM
    sleep 100 &
    echo "\$!" > "$CHILD_PID_FILE"
    wait "\$!"
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$STUB_BIN/git"

  TIMEOUT_SECS=2
  START=$(date +%s)
  rc=0
  out="$(printf '%s' '{}' | PATH="$STUB_BIN:$PATH" CHECK_SUB_UPDATE_DIR="$SUB" AIENV_MACHINE_ROLE_MARKER="$MARKER" \
    CHECK_SUB_UPDATE_LOG="$WORK/log.txt" CHECK_SUB_UPDATE_TIMEOUT="$TIMEOUT_SECS" "$SCRIPT")" || rc=$?
  END=$(date +%s)
  ELAPSED=$((END - START))

  assert_eq "exit 0(fail-open)" "0" "$rc"
  assert_eq "無応答時は無出力" "" "$out"
  # タイムアウト秒数+実行オーバーヘッド(watcherのKILL猶予1秒+プロセス起動コスト)を
  # 十分に見込んだ上限（タイムアウトが機能せず無限ハングしていないことの確認が
  # 目的であり、正確なミリ秒精度は求めない）。
  assert_true "タイムアウト秒数+余裕(10秒)以内に終了する(ハングしない)" \
    "$([[ "$ELAPSED" -le 10 ]] && echo 1 || echo 0)"
  assert_true "タイムアウトによる失敗がログに残る" \
    "$([[ -s "$WORK/log.txt" ]] && grep -q 'git fetch failed' "$WORK/log.txt" && echo 1 || echo 0)"

  # フック終了後、少し待ってから孫プロセス(sleep)が本当に死んでいるか確認する
  # （プロセスグループごとkillされていれば、TERM無視でも猶予後のKILLで死ぬはず）。
  sleep 1
  GRANDCHILD_PID="$(cat "$CHILD_PID_FILE" 2>/dev/null)"
  assert_true "孫プロセス(sleep)のPIDが記録されている(テスト自体が意図通り動いた確認)" \
    "$([[ -n "$GRANDCHILD_PID" ]] && echo 1 || echo 0)"
  assert_true "TERMを無視する孫プロセスもプロセスグループごとKILLされ残骸が無い" \
    "$(! kill -0 "$GRANDCHILD_PID" 2>/dev/null && echo 1 || echo 0)"
  # フック側に回帰が起きて孫プロセスが生き残ってしまった場合でも、テスト自体が
  # `sleep 100`の残骸をこのマシンに残さないよう明示的に後始末する（Codex再レビュー
  # 指摘・Minor: assertが失敗するだけではkillされず、fixture削除後も最大100秒
  # 残ってしまっていた）。`kill -0`で生存を確認してからKILLする（Codex再々レビュー
  # 指摘・Minor: 生存確認なしにPIDへ無条件KILLすると、既に終了しOS側でPIDが
  # 再利用された場合に無関係な別プロセスを誤ってkillしかねないため）。
  if [ -n "$GRANDCHILD_PID" ] && kill -0 "$GRANDCHILD_PID" 2>/dev/null; then
    kill -KILL "$GRANDCHILD_PID" 2>/dev/null || true
  fi

  rm -rf "$WORK" "$STUB_BIN"
}

echo "=== 9b. fetchが応答しない(実ネットワーク・補助的スモークテスト): ブラックホールIP宛でもハングしない ==="
{
  # 9番の決定的fixtureに加え、実ネットワークの黒穴IPアドレス（RFC 1918の
  # プライベートレンジ内で到達不能なアドレス）宛でも実際に固まらないことを
  # 補助的に確認する（環境によっては即時失敗になり得るため必須の検証はしない。
  # 9番のような即時失敗を誤ってパスさせない決定性は無いが、実運用に近い経路の
  # 動作確認として残す）。
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  git init -q --bare "$BARE"
  SUB="$WORK/sub"
  git clone -q "$BARE" "$SUB"
  git -C "$SUB" remote set-url origin "https://10.255.255.1/blackhole.git"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"

  TIMEOUT_SECS=3
  START=$(date +%s)
  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt" "$TIMEOUT_SECS")" || rc=$?
  END=$(date +%s)
  ELAPSED=$((END - START))

  assert_eq "exit 0(fail-open)" "0" "$rc"
  assert_eq "無応答時は無出力" "" "$out"
  assert_true "タイムアウト秒数+余裕(10秒)以内に終了する(ハングしない)" \
    "$([[ "$ELAPSED" -le 10 ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 10. origin/mainが存在しない(既定ブランチ名が違う等): 静かにexit 0(fail-open) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"
  git init -q --bare --initial-branch=trunk "$BARE" 2>/dev/null || git init -q --bare "$BARE"
  SRC="$WORK/src"
  mkdir -p "$SRC"
  git -C "$SRC" init -q -b trunk 2>/dev/null || git -C "$SRC" init -q
  git -C "$SRC" config user.name test
  git -C "$SRC" config user.email test@example.invalid
  echo "x" > "$SRC/x.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m init
  git -C "$SRC" remote add origin "$BARE"
  git -C "$SRC" branch -M trunk
  git -C "$SRC" push -q origin HEAD:trunk
  SUB="$WORK/sub"
  git clone -q "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"

  rc=0
  out="$(run_hook "$SUB" "$MARKER" "$WORK/log.txt")" || rc=$?
  assert_eq "exit 0(fail-open)" "0" "$rc"
  assert_eq "origin/mainが無ければ無出力" "" "$out"
  assert_true "判定不能の旨がログに残る" \
    "$([[ -s "$WORK/log.txt" ]] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 11. jqが最終出力生成に失敗(非0終了しつつ何らかの出力を残す)しても静かにexit 0(fail-open)・ログに残る(Codex再レビュー指摘Minor対応: 出力の有無だけでなく終了コードも見る) ==="
{
  WORK="$(mktemp -d)"
  BARE="$WORK/origin.git"; SRC="$WORK/src"
  make_origin "$BARE" "$SRC"
  SUB="$WORK/sub"
  make_sub_clone "$BARE" "$SUB"
  MARKER="$WORK/marker"
  make_sub_marker "$MARKER"
  echo "追加" >> "$SRC/README.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m "update" && git -C "$SRC" push -q origin HEAD:main

  REAL_JQ="$(command -v jq)"
  STUB_BIN="$(mktemp -d)"
  cat > "$STUB_BIN/jq" <<EOF
#!/usr/bin/env bash
# agent_type抽出(-rオプション)は本物のjqへ委譲し、通常どおり進ませる。
# 最終出力生成(-nオプション)だけ「非0終了しつつ何か出力する」異常を再現する
# （出力の有無だけを見るとfail-openの穴を見逃すケースの回帰テスト）。
if [ "\$1" = "-n" ]; then
  echo '{"broken": true}'
  exit 3
fi
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$STUB_BIN/jq"

  rc=0
  out="$(printf '%s' '{}' | PATH="$STUB_BIN:$PATH" CHECK_SUB_UPDATE_DIR="$SUB" AIENV_MACHINE_ROLE_MARKER="$MARKER" \
    CHECK_SUB_UPDATE_LOG="$WORK/log.txt" "$SCRIPT")" || rc=$?
  assert_eq "exit 0(fail-open)" "0" "$rc"
  assert_eq "jq異常終了時は(壊れた出力ではなく)無出力" "" "$out"
  assert_true "jqの異常終了がログに残る(無言のfail-openにはしない)" \
    "$([[ -s "$WORK/log.txt" ]] && grep -q 'jqでの出力JSON生成に失敗しました' "$WORK/log.txt" && echo 1 || echo 0)"

  rm -rf "$WORK" "$STUB_BIN"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
