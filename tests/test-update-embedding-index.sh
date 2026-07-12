#!/usr/bin/env bash
# scripts/vault-agents/update_embedding_index.py のユニットテスト（差分更新CLI）。
#
# 実CLIをsubprocessで叩く（既存test-recall-bench.sh等と同じ方針＝ロジック再実装で
# ドリフトさせない）。Ollama通信は tests/fake_ollama_server.py（127.0.0.1の一時ポート）
# でモックし、実Ollama・実ネットワークには一切依存しない。実Vault($HOME/Data/obsidian)
# にも依存せず、毎回tempディレクトリのfixtureへ--vault/--index-dirを向ける。
#
# 実行方法: bash tests/test-update-embedding-index.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/update_embedding_index.py"
FAKE_SERVER="$TESTS_DIR/fake_ollama_server.py"

# 実ホームの $HOME/.claude/logs/ollama-recall-activity.marker（想起フックとの活動
# 検知連携用マーカー・3巡目Codexレビュー指摘のTOCTOU対応で追加）に依存しないよう、
# このテストファイル全体で隔離パスへ差し替える（実環境の状態でテスト結果が揺れる
# のを防ぐ＝test-vault-recall.shで実際に踏んだ回帰の再発防止）。
export VAULT_EMBED_ACTIVITY_MARKER="$(mktemp -u)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれない: \"$needle\"／実際: $haystack)"; fi
}

FAKE_PID=""
FAKE_PORT=""
BASE_URL=""

start_fake_server() {
  # 呼び出し側が "FAKE_OLLAMA_XXX=... start_fake_server" の形で環境変数を前置すると、
  # bashのシンプルコマンド規則により本関数の実行中だけそれらがexportされる
  # （fake_ollama_server.pyはos.environから読む）。
  local outfile
  outfile="$(mktemp)"
  python3 "$FAKE_SERVER" 0 > "$outfile" 2>/dev/null &
  FAKE_PID=$!
  local waited=0
  while [ ! -s "$outfile" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  FAKE_PORT="$(cat "$outfile")"
  BASE_URL="http://127.0.0.1:${FAKE_PORT}"
  rm -f "$outfile"
}

stop_fake_server() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  wait "$FAKE_PID" 2>/dev/null
  FAKE_PID=""
}

write_note() {
  local path="$1" body="${2:-本文}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

echo "=== 1. 初回フルビルド: 全ノートを埋め込み、CURRENT/世代/meta.jsonが作られる ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Preferences/b.md" "ノートB"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "総数2件・新規2件のログ" "$out" "総数=2 新規/変更=2 再利用=0"
  assert_eq "CURRENTポインタが作られる" "1" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  gen="$(cat "$IDX_DIR/CURRENT")"
  count="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen/meta.json'))['count'])")"
  assert_eq "meta.jsonのcountは2" "2" "$count"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 1b. Personal/フォルダのノートも埋め込み対象に含まれる（2026-07-11決定・4→5フォルダ） ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Personal/devices.md" "モニターやキーボードの型番台帳"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "総数2件（Knowledge+Personal）" "$out" "総数=2 新規/変更=2"

  gen="$(cat "$IDX_DIR/CURRENT")"
  relpaths="$(python3 -c "
import json
meta = json.load(open('$IDX_DIR/$gen/meta.json'))
print(sorted(n['relpath'] for n in meta['notes']))
")"
  assert_contains "Personal/devices.mdがインデックスに含まれる" "$relpaths" "Personal/devices.md"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 2. 差分更新: 変更が無ければskipし世代が増えない ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"

  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  gen1="$(cat "$IDX_DIR/CURRENT")"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  gen2="$(cat "$IDX_DIR/CURRENT")"
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "変更なしログ" "$out" "変更なし"
  assert_eq "世代は増えない" "$gen1" "$gen2"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 3. 差分更新: 1件変更・1件削除・1件追加が正しく反映される ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Knowledge/b.md" "ノートB（削除される予定）"
  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1

  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA（変更後）"
  rm "$VAULT_DIR/Knowledge/b.md"
  write_note "$VAULT_DIR/Knowledge/c.md" "ノートC（新規）"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  assert_contains "新規/変更2件（a変更・c新規）" "$out" "新規/変更=2"
  assert_contains "削除1件" "$out" "削除=1"

  gen="$(cat "$IDX_DIR/CURRENT")"
  relpaths="$(python3 -c "
import json
meta = json.load(open('$IDX_DIR/$gen/meta.json'))
print(sorted(n['relpath'] for n in meta['notes']))
")"
  case "$relpaths" in
    *"Knowledge/b.md"*) fail_case "削除されたノートが残っている: $relpaths" ;;
    *) pass "削除ノートは新世代のnotesから除外される" ;;
  esac
  assert_contains "cが含まれる" "$relpaths" "Knowledge/c.md"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 4. Ollama不通: ログのみでexit 0（fail-open・既存インデックスは無変更） ==="
{
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "http://127.0.0.1:1" --tags-timeout 1 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "Ollama不通のskipログ" "$out" "Ollamaに接続できません"
  assert_eq "CURRENTは作られない" "0" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 5. モデル未pull: /api/tagsにモデルが無ければログのみでexit 0 ==="
{
  FAKE_OLLAMA_MODEL="other-model" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" --model "qwen3-embedding:0.6b" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "未pullのskipログ" "$out" "pullされていません"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 6. schema_version/model_digest不一致: フルリビルドされる ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  stop_fake_server

  # digestが変わった状態（モデル更新相当）を新しい偽サーバでシミュレートする
  FAKE_OLLAMA_DIGEST="newdigest456" start_fake_server
  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  assert_contains "フルリビルド理由が記録される" "$out" "フルリビルド理由"
  assert_contains "再利用0件（全件再embed）" "$out" "再利用=0"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 6b. num_ctx/num_batch変更（環境変数上書き）: フルリビルドされる（2026-07-11リーダー指示） ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  gen1="$(cat "$IDX_DIR/CURRENT")"
  num_ctx1="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen1/meta.json'))['num_ctx'])")"
  assert_eq "既定のnum_ctxが記録される" "4096" "$num_ctx1"

  # VAULT_EMBED_NUM_CTX/BATCHで8192へ上書きして再実行するとフルリビルドされるはず。
  out="$(VAULT_EMBED_NUM_CTX=8192 VAULT_EMBED_NUM_BATCH=8192 \
    python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  assert_contains "num_ctx変更でフルリビルド理由が記録される" "$out" "フルリビルド理由"
  assert_contains "再利用0件（全件再embed）" "$out" "再利用=0"

  gen2="$(cat "$IDX_DIR/CURRENT")"
  num_ctx2="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen2/meta.json'))['num_ctx'])")"
  assert_eq "新世代には上書き後のnum_ctx(8192)が記録される" "8192" "$num_ctx2"

  # 変更後の値のまま再実行すれば変更なしに戻る（フルリビルドの連鎖を起こさない）。
  out2="$(VAULT_EMBED_NUM_CTX=8192 VAULT_EMBED_NUM_BATCH=8192 \
    python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  assert_contains "同じnum_ctxのままなら変更なしになる" "$out2" "変更なし"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 7. writer lock(flock): 実際にロックを保持している別プロセスがあれば今回はskip ==="
{
  # flockはOS管理の排他ロックであり、ファイル内容(PID文字列)を書くだけでは再現できない
  # （8.1ラウンド2巡目Codexレビュー指摘・Major: 旧PIDファイル方式のTOCTOUをflockへの
  # 切替で構造的に解消したことに伴い、テストも「実際にflockを保持するプロセス」を
  # 立てる形に作り直した）。バックグラウンドでロックを取得したまま数秒スリープする
  # 子プロセスを起動し、その間に本体を実行してskipされることを確認する。
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  mkdir -p "$IDX_DIR"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  LOCK_FILE="$IDX_DIR/writer.lock"
  READY_FILE="$(mktemp -u)"

  # 固定sleepでの同期は高負荷環境で不安定になりうる（Codexレビュー指摘・Minor）ため、
  # 子プロセスが実際にflockを取得した後にreadyファイルを作成し、親はそれを短い
  # ポーリングで待ってから本体を起動する。
  python3 -c "
import fcntl, sys, time
f = open(sys.argv[1], 'a+')
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
open(sys.argv[2], 'w').close()
time.sleep(3)
" "$LOCK_FILE" "$READY_FILE" &
  HOLDER_PID=$!
  waited=0
  while [ ! -f "$READY_FILE" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" --lock-file "$LOCK_FILE" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "skipログ" "$out" "既に実行中です"
  assert_eq "CURRENTは作られない" "0" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  wait "$HOLDER_PID" 2>/dev/null
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$READY_FILE"
}

echo "=== 8. writer lock(flock): 内容だけのロックファイル（保持プロセス無し）は即座に取得できる ==="
{
  # flock方式では「ファイルは存在するがOSレベルのロックは誰も保持していない」状態に
  # stale判定は不要（flockが無ければ即座に新規ロックを取得できる＝クラッシュ後の
  # 自動回復がOS任せで保証される）。
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  mkdir -p "$IDX_DIR"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  echo "999999" > "$IDX_DIR/writer.lock"  # 前回プロセスの残骸相当（flockは保持されていない）

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "CURRENTは作られる" "1" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 8b. writer lock: ロックパスがsymlinkの場合はリンク先を破壊せず失敗する（3巡目Codexレビュー指摘・Major） ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  mkdir -p "$IDX_DIR"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  TARGET_FILE="$(mktemp)"
  printf 'このファイルは破壊されてはいけない' > "$TARGET_FILE"
  ln -s "$TARGET_FILE" "$IDX_DIR/writer.lock"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0（ロック取得失敗としてskip扱い）" "0" "$rc"
  assert_eq "リンク先ファイルの内容は破壊されない" "このファイルは破壊されてはいけない" "$(cat "$TARGET_FILE")"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$TARGET_FILE"
}

echo "=== 9. 埋め込みAPI異常: FAILでexit 1・既存インデックスは無変更 ==="
{
  FAKE_OLLAMA_FAIL_EMBED=1 start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"

  # --embed-retries/--embed-backoff-sを小さくしてテストを高速化する（本番既定は
  # 実機検証で判明した間欠的EOF/400対策のため手厚め＝retries6・backoff1.5s）。
  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" \
    --embed-retries 1 --embed-backoff-s 0.05 2>&1)"
  rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "FAILログ" "$out" "FAIL"
  assert_eq "CURRENTは作られない" "0" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9c. embed_with_retry: 途中で回復すれば成功する（2巡目Codexレビュー指摘・Minor対応） ==="
{
  # 最初の2回だけ/api/embedを失敗させ、3回目以降は成功させる。--embed-retries 3なら
  # （1回目失敗→backoff→2回目失敗→backoff→3回目成功）で最終的に成功するはず。
  FAKE_OLLAMA_FAIL_EMBED_FIRST_N=2 start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" \
    --embed-retries 3 --embed-backoff-s 0.05 2>&1)"
  rc=$?
  assert_eq "2回失敗しても3回目で回復しexit 0になる" "0" "$rc"
  assert_eq "CURRENTが作られる（回復後は正常にインデックス更新される）" "1" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9d. update_embedding_index.py: --embed-retries/--embed-backoff-sに負値を渡すと引数エラー（2巡目Codexレビュー指摘・Minor対応） ==="
{
  out="$(python3 "$SCRIPT" --vault "$(mktemp -d)" --embed-retries -1 2>&1)"
  rc=$?
  assert_eq "負のembed-retriesはexit非0(argparseエラー)" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_contains "エラーメッセージが分かりやすい" "$out" "embed-retries"

  out2="$(python3 "$SCRIPT" --vault "$(mktemp -d)" --embed-backoff-s -1 2>&1)"
  rc2=$?
  assert_eq "負のembed-backoff-sはexit非0(argparseエラー)" "1" "$([ "$rc2" -ne 0 ] && echo 1 || echo 0)"
  assert_contains "エラーメッセージが分かりやすい" "$out2" "embed-backoff-s"
}

echo "=== 9b. 長文ノートを含む差分更新が成功する（リーダー実機検証で確定した回帰: 配列input送信への退行防止） ==="
{
  # tests/fake_ollama_server.py は「配列(バッチ)inputに長文アイテムが1件でもあると400」
  # という実Ollama 0.31.1の挙動を疑似再現する（FAKE_OLLAMA_MAX_ITEM_CHARS）。
  # update_embedding_index.pyが1ノート=1リクエスト・文字列inputで送っている限り、
  # 何文字の長文ノートでも成功するはず（もし将来コードが配列バッチ送信へ退行したら
  # このテストが即座に落ちる＝復活防止の回帰テスト）。
  FAKE_OLLAMA_MAX_ITEM_CHARS=100 start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/short.md" "短いノート"
  write_note "$VAULT_DIR/Knowledge/long.md" "$(python3 -c 'print("長文ノート本体。" * 50)')"  # 明らかに100字超

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0（長文ノートがあっても失敗しない）" "0" "$rc"
  assert_contains "総数2件・新規2件のログ" "$out" "総数=2 新規/変更=2"
  assert_eq "CURRENTが作られる" "1" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9e. n_batch超過ノートでも成功する（リーダー実機検証で確定した機序: options.num_ctx/num_batch指定への退行防止） ==="
{
  # tests/fake_ollama_server.py は「n_batch(既定2048)を超えるトークン数(疑似的に文字数)の
  # 入力は、options.num_batchを十分な値で明示しない限り400」という実Ollama挙動を疑似
  # 再現する（FAKE_OLLAMA_NBATCH_CHARS/FAKE_OLLAMA_REQUIRED_NUM_BATCH）。
  # embedding_index.ollama_embed()が全リクエストにoptions.num_ctx/num_batchを付与して
  # いる限り成功するはず（もし将来コードがoptions指定を落としたら、このテストが即座に
  # 落ちる＝退行防止の回帰テスト）。
  FAKE_OLLAMA_NBATCH_CHARS=100 FAKE_OLLAMA_REQUIRED_NUM_BATCH=4096 start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/nbatch-note.md" "$(python3 -c 'print("n_batch超過を再現するための長文本体。" * 30)')"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0（n_batch超過ノートでも失敗しない）" "0" "$rc"
  assert_eq "CURRENTが作られる" "1" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9ea. truncate検知: 長文ノートがtruncated_notesへ記録され、ログにも出力される（2026-07-11リーダー指示） ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/short.md" "短いノート"
  # EMBED_NUM_CTX(既定4096)*CHARS_PER_TOKEN_CONSERVATIVE(既定1・実Vault較正で2から
  # 引き下げ済み)=4096字を明らかに超える長文ノートを用意する（is_likely_truncated()
  # の(2)条件で検知されるはず）。
  write_note "$VAULT_DIR/Knowledge/very-long.md" "$(python3 -c 'print("長文ノートの本体です。" * 1000)')"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "truncate検知のログ行が出る" "$out" "truncate検知: 1件"
  assert_contains "検知されたノート名がログに出る" "$out" "Knowledge/very-long.md"

  gen="$(cat "$IDX_DIR/CURRENT")"
  truncated="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen/meta.json'))['truncated_notes'])")"
  assert_contains "meta.jsonのtruncated_notesに長文ノートが記録される" "$truncated" "Knowledge/very-long.md"
  case "$truncated" in
    *short.md*) fail_case "短いノートが誤ってtruncated_notesに入っている: $truncated" ;;
    *) pass "短いノートはtruncated_notesに入らない" ;;
  esac

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9eb. truncate検知: 該当ノートが無い場合はログ行自体が出ない（静穏さ優先） ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/short.md" "短いノート"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  case "$out" in
    *truncate検知*) fail_case "truncate該当が無いのにログ行が出ている: $out" ;;
    *) pass "truncate該当0件ならログ行は出ない" ;;
  esac

  gen="$(cat "$IDX_DIR/CURRENT")"
  truncated="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen/meta.json'))['truncated_notes'])")"
  assert_eq "truncated_notesは空リスト" "[]" "$truncated"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9ec. truncate検知: 差分更新で再利用されたノートもtruncated_notesへ引き継がれる ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/very-long.md" "$(python3 -c 'print("長文ノートの本体です。" * 1000)')"
  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1

  # 新規ノートを1件追加するだけの差分更新（very-long.mdは内容変更なし＝再利用される）。
  write_note "$VAULT_DIR/Knowledge/new-short.md" "新しい短いノート"
  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1

  gen="$(cat "$IDX_DIR/CURRENT")"
  truncated="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen/meta.json'))['truncated_notes'])")"
  assert_contains "再利用ノートでもtruncated_notesに引き継がれる" "$truncated" "Knowledge/very-long.md"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9f. keep_alive:0はノート埋め込みには付与されず、ループ完了後の専用アンロード要求として1回だけ送られる（3巡目Codexレビュー指摘・Major対応） ==="
{
  # FAKE_OLLAMA_LOG_REQUESTSはfake_ollama_server.pyプロセス自身の環境変数として
  # 必要なため、start_fake_server（サーバ起動）の前に前置する（サーバ起動後に
  # SCRIPT呼び出し側だけへ渡しても、別プロセスであるサーバには伝わらない）。
  #
  # 「最後の1件にkeep_alive:0を付与する」実装は、その1件がretry+backoffで待たされて
  # いる間に対話利用判定が古びるTOCTOUがあったため廃止し、通常のノート埋め込み
  # リクエストにはkeep_aliveを一切付けず、ループ完了後に専用の空inputリクエストを
  # 1回だけ（送信直前に判定し直して）送る設計へ変更した。3ノート分の通常リクエスト
  # ＋1件の専用アンロードリクエスト＝合計4件になるはず。
  REQ_LOG="$(mktemp)"
  FAKE_OLLAMA_LOG_REQUESTS="$REQ_LOG" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Knowledge/b.md" "ノートB"
  write_note "$VAULT_DIR/Knowledge/c.md" "ノートC"

  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  rc=$?
  assert_eq "exit code 0" "0" "$rc"

  total_reqs="$(wc -l < "$REQ_LOG" | tr -d ' ')"
  assert_eq "3ノート分＋専用アンロード1件＝4リクエスト" "4" "$total_reqs"

  ka_count="$(grep -c '"keep_alive"' "$REQ_LOG")"
  assert_eq "keep_aliveキーを含むのは1件（専用アンロード要求）だけ" "1" "$ka_count"

  last_line="$(tail -n 1 "$REQ_LOG")"
  assert_contains "keep_alive:0は最後の行(専用アンロードリクエスト)に付いている" "$last_line" '"keep_alive": 0'
  assert_contains "専用アンロードリクエストのinputは空文字" "$last_line" '"input": ""'

  first_line="$(head -n 1 "$REQ_LOG")"
  case "$first_line" in
    *keep_alive*) fail_case "1件目(通常ノート)にkeep_aliveが付いてはいけない: $first_line" ;;
    *) pass "1件目(通常ノート)にはkeep_aliveが付かない（Ollama既定に委ねる）" ;;
  esac

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$REQ_LOG"
}

echo "=== 9g. モデルが既に対話セッション側でロード済みならkeep_alive:0を送らない（Codexレビュー指摘・Major対応） ==="
{
  # FAKE_OLLAMA_PS_LOADED=1でGET /api/psが「対象モデルは既にロード済み」と応答する。
  # この場合、想起フック用に予熱されたモデルを毎時ジョブが勝手にアンロードして
  # しまわないよう、最後のリクエストにもkeep_alive:0を付与してはいけない。
  REQ_LOG="$(mktemp)"
  FAKE_OLLAMA_LOG_REQUESTS="$REQ_LOG" FAKE_OLLAMA_PS_LOADED=1 start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Knowledge/b.md" "ノートB"

  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  rc=$?
  assert_eq "exit code 0" "0" "$rc"

  ka_count="$(grep -c '"keep_alive"' "$REQ_LOG")"
  assert_eq "既にロード済みならkeep_aliveは1件も送られない" "0" "$ka_count"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$REQ_LOG"
}

echo "=== 9gb. 開始時点は未ロードでも、直近の想起フック活動マーカーがあればkeep_alive:0を送らない（3巡目Codexレビュー指摘・Major対応＝TOCTOU緩和） ==="
{
  # /api/psは既定(models: [])のまま(=開始時点は未ロード=should_unload_after_run=True)
  # だが、想起フック(vector_recall_helper.py)が使う活動マーカーを直前に更新しておく
  # ことで「実行中に対話利用が割り込んだ」状況を模擬する。この場合、送信直前の
  # _safe_to_unload_now()がFalseを返し、最後のリクエストにもkeep_alive:0が付かない
  # はず。
  REQ_LOG="$(mktemp)"
  FAKE_OLLAMA_LOG_REQUESTS="$REQ_LOG" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Knowledge/b.md" "ノートB"

  # VAULT_EMBED_ACTIVITY_MARKERは冒頭でこのテストファイル全体用にexport済み。
  # その隔離パスへ「たった今」touchすることで、直近の想起フック活動を模擬する。
  touch "$VAULT_EMBED_ACTIVITY_MARKER"

  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  rc=$?
  assert_eq "exit code 0" "0" "$rc"

  ka_count="$(grep -c '"keep_alive"' "$REQ_LOG")"
  assert_eq "直近の想起フック活動があればkeep_aliveは1件も送られない" "0" "$ka_count"

  rm -f "$VAULT_EMBED_ACTIVITY_MARKER"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$REQ_LOG"
}

echo "=== 9h. 途中のノートで恒久的に失敗しても、best-effortでモデルのアンロードを試みる（Codexレビュー指摘・Major対応） ==="
{
  # 3ノートのうち中間の1件だけをFAKE_OLLAMA_FAIL_IF_CONTAINSで恒久失敗させる。
  # 「最後の1件にのみkeep_alive:0」という単純な実装だと、この場合は最後のリクエスト
  # まで到達できずアンロード要求が一度も送られない。finallyブロックのbest-effort
  # 後始末が機能していることを、REQ_LOGに記録される追加の空inputリクエスト
  # （後始末用の明示的なアンロード呼び出し）で確認する。
  REQ_LOG="$(mktemp)"
  FAKE_OLLAMA_LOG_REQUESTS="$REQ_LOG" FAKE_OLLAMA_FAIL_IF_CONTAINS="FAILME" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  write_note "$VAULT_DIR/Knowledge/b-fails.md" "ノートB FAILME"
  write_note "$VAULT_DIR/Knowledge/c.md" "ノートC"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" \
    --embed-retries 1 --embed-backoff-s 0.05 2>&1)"
  rc=$?
  assert_eq "exit code 1（b-fails.mdで恒久失敗）" "1" "$rc"
  assert_eq "CURRENTは作られない" "0" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  # 後始末用の明示的なアンロード呼び出し（input=""でkeep_alive:0）が記録されている
  # ことを確認する（a.mdの通常リクエストと区別するためinputが空文字であることを見る）。
  cleanup_count="$(python3 -c "
import json
n = 0
for line in open('$REQ_LOG'):
    d = json.loads(line)
    if d.get('input') == '' and d.get('keep_alive') == 0:
        n += 1
print(n)
")"
  assert_eq "後始末用のアンロード呼び出しが1件記録される" "1" "$cleanup_count"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$REQ_LOG"
}

echo "=== 9i. 1件目のノートが恒久的に失敗（成功が1件も無い）場合でも、best-effortでモデルのアンロードを試みる（3巡目Codexレビュー指摘・Major対応） ==="
{
  # 9hは「中間の1件」が失敗するケースだったが、こちらは「最初の(=唯一の成功実績も
  # 無い)1件」が失敗するケース。判定を「1件でも成功したか」ではなく「to_embedが
  # 非空＝embedを試行したか」にしたことで、成功実績が0件でも後始末が行われることを
  # 確認する。
  REQ_LOG="$(mktemp)"
  FAKE_OLLAMA_LOG_REQUESTS="$REQ_LOG" FAKE_OLLAMA_FAIL_IF_CONTAINS="FAILME" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a-fails.md" "ノートA FAILME"
  write_note "$VAULT_DIR/Knowledge/b.md" "ノートB"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" \
    --embed-retries 1 --embed-backoff-s 0.05 2>&1)"
  rc=$?
  assert_eq "exit code 1（a-fails.mdで恒久失敗・成功実績0件）" "1" "$rc"
  assert_eq "CURRENTは作られない" "0" "$([ -f "$IDX_DIR/CURRENT" ] && echo 1 || echo 0)"

  cleanup_count="$(python3 -c "
import json
n = 0
for line in open('$REQ_LOG'):
    d = json.loads(line)
    if d.get('input') == '' and d.get('keep_alive') == 0:
        n += 1
print(n)
")"
  assert_eq "成功実績0件でも後始末用のアンロード呼び出しが1件記録される" "1" "$cleanup_count"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$REQ_LOG"
}

echo "=== 10. Vaultが1件もノートを持たない場合: 未初期化のままexit 0 ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  mkdir -p "$VAULT_DIR/Knowledge"

  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "対象ノート0件のログ" "$out" "対象ノートが1件もなく"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 11. Vault不在: exit 1で明確に落ちる（定期実行の設定ミスに気付けるように） ==="
{
  out="$(python3 "$SCRIPT" --vault "/nonexistent/vault/path" --index-dir "$(mktemp -d)" 2>&1)"
  rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_contains "vaultが見つからないFAIL" "$out" "vaultが見つかりません"
}

echo "=== 12. 全ノート削除: 空の新世代が書かれる（notesが空リストでもクラッシュしない）==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "ノートA"
  python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1

  rm "$VAULT_DIR/Knowledge/a.md"
  out="$(python3 "$SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  gen="$(cat "$IDX_DIR/CURRENT")"
  count="$(python3 -c "import json; print(json.load(open('$IDX_DIR/$gen/meta.json'))['count'])")"
  assert_eq "新世代のcountは0" "0" "$count"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
