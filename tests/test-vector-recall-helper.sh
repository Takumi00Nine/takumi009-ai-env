#!/usr/bin/env bash
# scripts/vault-agents/vector_recall_helper.py のユニットテスト（想起フック補助）。
#
# 実CLIをsubprocessで叩く。Ollama通信は tests/fake_ollama_server.py でモックし、
# 実Ollama・実ネットワークには依存しない。マーカーベクトル方式
#（fake_ollama_server.pyのヘッダコメント参照）で類似度判定の結果を決定的にする。
#
# 実行方法: bash tests/test-vector-recall-helper.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/vector_recall_helper.py"
UPDATE_SCRIPT="$REPO_ROOT/scripts/vault-agents/update_embedding_index.py"
FAKE_SERVER="$TESTS_DIR/fake_ollama_server.py"

# vector_recall_helper.pyはOllama呼び出し直前に活動マーカーを更新する（3巡目Codex
# レビュー指摘のTOCTOU対応で追加）。実 $HOME/.claude/logs/ 配下を汚さないよう隔離する。
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
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

# マーカー付きノート2件(TOPIC_A)+1件(TOPIC_B)を持つVault+インデックスを用意する。
setup_fixture() {
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/topic-a-1.md" "__MARK_TOPIC_A__ 本文1"
  write_note "$VAULT_DIR/Knowledge/topic-a-2.md" "__MARK_TOPIC_A__ 本文2"
  write_note "$VAULT_DIR/Preferences/topic-b.md" "__MARK_TOPIC_B__ 本文3"
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
}

echo "=== 1. マーカーが一致するノートのみ閾値以上で上位に来る ==="
{
  start_fake_server
  setup_fixture

  out="$(python3 "$SCRIPT" --query "__MARK_TOPIC_A__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 5000)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  relpaths="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print([c['relpath'] for c in d['candidates']])")"
  assert_contains "topic-a-1が候補に入る" "$relpaths" "topic-a-1.md"
  assert_contains "topic-a-2が候補に入る" "$relpaths" "topic-a-2.md"
  case "$relpaths" in
    *"topic-b.md"*) fail_case "無関係なtopic-bが混入している: $relpaths" ;;
    *) pass "無関係なtopic-bは閾値未満で候補に入らない" ;;
  esac

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 2. --threshold 0で全件（閾値なし）を返す ==="
{
  start_fake_server
  setup_fixture

  out="$(python3 "$SCRIPT" --query "__MARK_TOPIC_A__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 5000 --threshold 0)"
  n="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "閾値0なら3件全部返る" "3" "$n"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 3. --top-nで件数が絞られる ==="
{
  start_fake_server
  setup_fixture

  out="$(python3 "$SCRIPT" --query "__MARK_TOPIC_A__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 5000 --threshold 0 --top-n 1)"
  n="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "top-n=1で1件のみ" "1" "$n"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 4. 削除済みノート: インデックスに残っていてもVault上に無ければ除外される ==="
{
  start_fake_server
  setup_fixture
  rm "$VAULT_DIR/Knowledge/topic-a-2.md"  # インデックス更新前に削除（1時間ラグの再現）

  out="$(python3 "$SCRIPT" --query "__MARK_TOPIC_A__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 5000 --threshold 0)"
  relpaths="$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print([c['relpath'] for c in d['candidates']])")"
  case "$relpaths" in
    *"topic-a-2.md"*) fail_case "削除済みノートが候補に残っている: $relpaths" ;;
    *) pass "削除済みノートは候補から除外される（付録A FR3ケース6）" ;;
  esac

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 5. クエリ空: exit非0（bad query） ==="
{
  start_fake_server
  setup_fixture
  out="$(python3 "$SCRIPT" --query "" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  assert_eq "exit非0" "1" "$rc"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 6. インデックス未初期化: exit非0（fail-open素材） ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  out="$(python3 "$SCRIPT" --query "何か質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  [[ "$rc" -ne 0 ]] && pass "インデックス無しはexit非0" || fail_case "exit 0になってしまった"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 7. Ollama不通: exit非0（fail-open素材） ==="
{
  setup_fixture_no_server() {
    VAULT_DIR="$(mktemp -d)"
    IDX_DIR="$(mktemp -d)"
    start_fake_server
    write_note "$VAULT_DIR/Knowledge/a.md" "__MARK_X__ 本文"
    python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
    stop_fake_server
  }
  setup_fixture_no_server
  out="$(python3 "$SCRIPT" --query "何か質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "http://127.0.0.1:1" 2>&1)"
  rc=$?
  [[ "$rc" -ne 0 ]] && pass "Ollama不通はexit非0" || fail_case "exit 0になってしまった"
  assert_contains "呼び出し失敗のメッセージ" "$out" "失敗しました"
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 8. 予算超過(budget-ms=0): HTTP呼び出し前に打ち切りexit非0 ==="
{
  start_fake_server
  setup_fixture
  out="$(python3 "$SCRIPT" --query "__MARK_TOPIC_A__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 0 2>&1)"
  rc=$?
  [[ "$rc" -ne 0 ]] && pass "budget-ms=0はexit非0" || fail_case "exit 0になってしまった"
  assert_contains "打ち切りメッセージ" "$out" "打ち切りました"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 9. HTTP後の予算超過: Ollama応答に時間がかかると打ち切りexit非0 ==="
{
  FAKE_OLLAMA_DELAY_MS=800 start_fake_server
  setup_fixture
  out="$(python3 "$SCRIPT" --query "__MARK_TOPIC_A__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 200 2>&1)"
  rc=$?
  [[ "$rc" -ne 0 ]] && pass "遅延によるexit非0" || fail_case "exit 0になってしまった"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 10. クエリ埋め込みの次元がインデックスと不一致なら異常検知 ==="
{
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "__MARK_X__ 本文"
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  stop_fake_server

  # クエリ側は別次元のfakeサーバで応答させる（インデックスはDIM=16のまま）
  FAKE_OLLAMA_DIM=8 start_fake_server
  out="$(python3 "$SCRIPT" --query "何か質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" 2>&1)"
  rc=$?
  [[ "$rc" -ne 0 ]] && pass "次元不一致はexit非0" || fail_case "exit 0になってしまった"
  assert_contains "次元不一致のメッセージ" "$out" "次元"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 11. 長文クエリでも成功する（配列input送信への退行防止・リーダー実機検証で確定した回帰） ==="
{
  # tests/fake_ollama_server.py の「配列(バッチ)inputに長文アイテムがあると400」という
  # 疑似再現に対し、helperがクエリを常に文字列inputとして送っている限り成功するはず。
  FAKE_OLLAMA_MAX_ITEM_CHARS=100 start_fake_server
  setup_fixture
  long_query="$(python3 -c 'print("__MARK_TOPIC_A__ に関する長い質問文です。" * 20)')"
  out="$(python3 "$SCRIPT" --query "$long_query" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 5000 --threshold 0)"
  rc=$?
  assert_eq "exit code 0（長文クエリでも失敗しない）" "0" "$rc"
  n="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "候補は3件のまま返る" "3" "$n"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 12. n_batch超過クエリでも成功する（options.num_ctx/num_batch指定への退行防止・リーダー実機検証で確定した機序） ==="
{
  # tests/fake_ollama_server.py の「n_batch(既定2048)超過はoptions.num_batch未指定なら
  # 400」という疑似再現に対し、helperが常にoptions.num_ctx/num_batchを付与している
  # 限り成功するはず。
  FAKE_OLLAMA_NBATCH_CHARS=100 FAKE_OLLAMA_REQUIRED_NUM_BATCH=4096 start_fake_server
  setup_fixture
  long_query="$(python3 -c 'print("__MARK_TOPIC_A__ に関するn_batch超過再現用の長い質問文です。" * 20)')"
  out="$(python3 "$SCRIPT" --query "$long_query" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --budget-ms 5000 --threshold 0)"
  rc=$?
  assert_eq "exit code 0（n_batch超過クエリでも失敗しない）" "0" "$rc"
  n="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "候補は3件のまま返る" "3" "$n"
  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 13. モデル不一致: インデックス構築時と異なる期待モデルを渡すとexit非0（Codexレビュー指摘・model_digest/model検証の是正） ==="
{
  # update_embedding_index.pyは--modelが/api/tagsに無ければbuildをskipするため、
  # 構築時のモデル名でfakeサーバのtagsも合わせておく必要がある。読み込み側の
  # --model不一致検証はローカルのmeta.json比較のみで発火しHTTPには依存しないため、
  # ここではfakeサーバのモデル名は構築時の"model-a"のままでよい。
  FAKE_OLLAMA_MODEL="model-a" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "__MARK_X__ 本文"
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" --model "model-a" >/dev/null 2>&1

  out="$(python3 "$SCRIPT" --query "何か質問です十分な長さです" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --model "model-b" 2>&1)"
  rc=$?
  [[ "$rc" -ne 0 ]] && pass "モデル不一致はexit非0" || fail_case "exit 0になってしまった"
  assert_contains "モデル不一致のメッセージ" "$out" "modelが設定と一致しません"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo "=== 14. モデル一致: --modelで明示した期待モデルがインデックスと一致すれば従来どおり正常に候補が返る ==="
{
  FAKE_OLLAMA_MODEL="model-a" start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/a.md" "__MARK_X__ 本文"
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" --model "model-a" >/dev/null 2>&1

  out="$(python3 "$SCRIPT" --query "__MARK_X__ の質問" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" \
    --base-url "$BASE_URL" --model "model-a" --threshold 0)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  n="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "候補が1件返る" "1" "$n"

  stop_fake_server
  rm -rf "$VAULT_DIR" "$IDX_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
