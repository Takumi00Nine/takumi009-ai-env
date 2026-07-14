#!/usr/bin/env bash
# claude/hooks/vault-recall.sh のベクトル想起マージ部分（8.1ラウンド追加）のユニット
# テスト。既存のtest-vault-recall.sh（キーワード照合ロジック）とは目的を分離し、
# 「キーワード候補∪ベクトル候補（最大3件・別枠表示）」「候補0件即exitの位置移動」
# 「付録A FR3の6ケース（真のfail-open 5ケース＋正常な防御的除外1ケース＝
# 2026-07-14修正でlog_fact()の事実記録へ分離）」を1:1の独立ケースとして検証する。
#
# 実Vault・実Ollamaには一切依存しない。埋め込みインデックスは
# scripts/vault-agents/update_embedding_index.py を tests/fake_ollama_server.py
# （マーカーベクトル方式）に向けて実際に構築して使う。
#
# 実行方法: bash tests/test-vault-recall-vector.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/claude/hooks/vault-recall.sh"
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
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"; fi
}

write_note() {
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  { echo "---"; printf '%s\n' "$fm"; echo "---"; echo; printf '%s\n' "$body"; } > "$path"
}

FAKE_PID=""
BASE_URL=""
start_fake_server() {
  local outfile
  outfile="$(mktemp)"
  python3 "$FAKE_SERVER" 0 > "$outfile" 2>/dev/null &
  FAKE_PID=$!
  local waited=0
  while [ ! -s "$outfile" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BASE_URL="http://127.0.0.1:$(cat "$outfile")"
  rm -f "$outfile"
}
stop_fake_server() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  wait "$FAKE_PID" 2>/dev/null
  FAKE_PID=""
}

# run_hook <session_id> <prompt> [追加env...]
run_hook() {
  local sid="$1" prompt="$2"
  shift 2
  printf '{"session_id":"%s","prompt":"%s"}' "$sid" "$prompt" \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_EMBED_INDEX_DIR="$IDX_DIR" \
      VAULT_EMBED_BASE_URL="$BASE_URL" "$@" "$SCRIPT"
}

setup_fixture() {
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  LOG="$(mktemp)"
  # topic-a: 想起フックのキーワード照合には一切一致しないaliasにする（マーカー語は
  # プロンプトにそのまま出現させることでベクトル専用ヒットにする）。
  write_note "$VAULT_DIR/Knowledge/note-gamma.md" \
    $'date: 2026-07-01\naliases:\n  - "こちらは別の言い回しです"' "__MARK_DELTA__ に関する内容の本文。"
  write_note "$VAULT_DIR/Preferences/keyword-hit-note.md" \
    $'date: 2026-07-01\naliases:\n  - "キーワードヒット専用語"' "本文。"
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
}

teardown_fixture() {
  rm -rf "$VAULT_DIR" "$IDX_DIR"
  rm -f "$LOG"
}

echo "=== 1. キーワード0件・ベクトルのみヒット: 別枠見出しで提示される ==="
{
  start_fake_server
  setup_fixture
  out="$(run_hook s1 "__MARK_DELTA__ について教えてほしい")"
  assert_contains "ベクトル専用の見出しが出る" "$out" "意味的に近い候補"
  assert_contains "対象ノートが含まれる" "$out" "note-gamma.md"
  assert_not_contains "キーワード見出しは出ない" "$out" "外部脳の関連ノート候補"
  stop_fake_server
  teardown_fixture
}

echo "=== 2. キーワードヒットあり・ベクトルはキーワードと重複しないものだけ追加（最大3件・別枠） ==="
{
  start_fake_server
  setup_fixture
  out="$(run_hook s2 "キーワードヒット専用語について、それと__MARK_DELTA__の話も教えてください")"
  assert_contains "キーワード見出しが出る" "$out" "外部脳の関連ノート候補"
  assert_contains "キーワードノートが出る" "$out" "keyword-hit-note.md"
  assert_contains "ベクトル見出しも別枠で出る" "$out" "意味的に近い候補"
  assert_contains "ベクトルノートも出る" "$out" "note-gamma.md"
  stop_fake_server
  teardown_fixture
}

echo "=== 3. キーワード・ベクトルとも0件: 無出力でexit 0（マージ後判定への移動確認） ==="
{
  start_fake_server
  setup_fixture
  out="$(run_hook s3 "全く無関係などうでもいい話題についての雑談です")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  stop_fake_server
  teardown_fixture
}

echo "=== 4. VAULT_RECALL_DISABLE_VECTOR=1: ベクトル想起を完全に無効化（AC1回帰確認用キルスイッチ） ==="
{
  start_fake_server
  setup_fixture
  out="$(run_hook s4 "__MARK_DELTA__ について教えてほしい" env VAULT_RECALL_DISABLE_VECTOR=1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "無効化時は完全に無出力（キーワードも一致しないため）" "" "$out"
  stop_fake_server
  teardown_fixture
}

echo "=== 5. fail-open ケース1: Ollamaプロセス不在（base-url不通） ==="
{
  start_fake_server
  setup_fixture
  stop_fake_server  # インデックス構築後にサーバを止め、以降の検索呼び出し時に不通にする
  out="$(run_hook s5 "キーワードヒット専用語についての質問")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "fail-openログが1行残る" "$(cat "$LOG")" "ベクトル想起をfail-openでskipしました"
  teardown_fixture
}

echo "=== 6. fail-open ケース2: 応答timeout（予算超過をシミュレート） ==="
{
  FAKE_OLLAMA_DELAY_MS=1500 start_fake_server
  setup_fixture_delay() {
    VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; LOG="$(mktemp)"
    write_note "$VAULT_DIR/Preferences/keyword-hit-note.md" \
      $'date: 2026-07-01\naliases:\n  - "キーワードヒット専用語"' "本文。"
  }
  setup_fixture_delay
  # インデックス構築だけ別の（遅延なし）サーバで行う
  stop_fake_server
  start_fake_server
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  stop_fake_server
  FAKE_OLLAMA_DELAY_MS=1500 start_fake_server  # 検索時だけ遅延させる
  out="$(run_hook s6 "キーワードヒット専用語についての質問" env VAULT_RECALL_VECTOR_BUDGET_MS=200 VAULT_RECALL_VECTOR_KILL_GRACE_MS=100)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "fail-openログが残る" "$(cat "$LOG")" "ベクトル想起をfail-openでskipしました"
  stop_fake_server
  teardown_fixture
}

echo "=== 6b. VECTOR_BUDGET_MS/VECTOR_KILL_GRACE_MSが不正値(非整数)でもフック自体はexit 0を維持する"\
     "（Codexレビュー指摘・Major対応: ポーリングループの整数演算$(( ))へ直接渡すため検証が必須） ==="
{
  start_fake_server
  setup_fixture
  for bad in "abc" "500.5" "-100" ""; do
    out="$(run_hook s6b "キーワードヒット専用語について" env VAULT_RECALL_VECTOR_BUDGET_MS="$bad")"
    rc=$?
    assert_eq "VECTOR_BUDGET_MS=${bad:-<空文字>} でもexit code 0（既定値へフォールバック）" "0" "$rc"
  done
  for bad in "xyz" "150.0" "-50"; do
    out="$(run_hook s6b2 "キーワードヒット専用語について" env VAULT_RECALL_VECTOR_KILL_GRACE_MS="$bad")"
    rc=$?
    assert_eq "VECTOR_KILL_GRACE_MS=${bad} でもexit code 0（既定値へフォールバック）" "0" "$rc"
  done
  # 先頭ゼロ付きの数字("08"/"09"等)は文字種チェック(0-9のみ)は通過するが、bashの
  # 算術展開では先頭ゼロの整数リテラルを8進数として解釈するため、8/9を含む値は
  # 不正な8進数となり算術エラーを起こしうる（Codexレビュー指摘・Major対応:
  # `10#$VAR`で10進数として明示評価するよう修正）。
  for zero_padded in "08" "09" "0009" "000500"; do
    out="$(run_hook s6b4 "キーワードヒット専用語について" env VAULT_RECALL_VECTOR_BUDGET_MS="$zero_padded")"
    rc=$?
    assert_eq "VECTOR_BUDGET_MS=${zero_padded}(先頭ゼロ)でもexit code 0（8進数誤解釈対策）" "0" "$rc"
    assert_contains "VECTOR_BUDGET_MS=${zero_padded}でもキーワード結果は正常に返る" "$out" "keyword-hit-note.md"
  done
  for zero_padded in "08" "09" "0009"; do
    out="$(run_hook s6b5 "キーワードヒット専用語について" env VAULT_RECALL_VECTOR_KILL_GRACE_MS="$zero_padded")"
    rc=$?
    assert_eq "VECTOR_KILL_GRACE_MS=${zero_padded}(先頭ゼロ)でもexit code 0（8進数誤解釈対策）" "0" "$rc"
  done
  # 不正値でも通常のヒット結果自体は壊れず返ることも確認する（フォールバック後は
  # 既定値1000/150で正常動作するはず）。
  out="$(run_hook s6b3 "キーワードヒット専用語について" env VAULT_RECALL_VECTOR_BUDGET_MS="not-a-number")"
  assert_contains "不正値フォールバック後もキーワード結果は正常に返る" "$out" "keyword-hit-note.md"
  stop_fake_server
  teardown_fixture
}

echo "=== 7. fail-open ケース3: インデックスファイル破損・JSON壊れ ==="
{
  start_fake_server
  setup_fixture
  gen="$(cat "$IDX_DIR/CURRENT")"
  echo "{not valid json" > "$IDX_DIR/$gen/meta.json"
  out="$(run_hook s7 "キーワードヒット専用語についての質問")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "fail-openログが残る" "$(cat "$LOG")" "ベクトル想起をfail-openでskipしました"
  stop_fake_server
  teardown_fixture
}

echo "=== 8. fail-open ケース4: 埋め込み次元不一致 ==="
{
  start_fake_server
  setup_fixture
  stop_fake_server
  FAKE_OLLAMA_DIM=8 start_fake_server  # クエリ側だけ別次元で応答させる
  out="$(run_hook s8 "キーワードヒット専用語についての質問")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "fail-openログが残る" "$(cat "$LOG")" "ベクトル想起をfail-openでskipしました"
  stop_fake_server
  teardown_fixture
}

echo "=== 9. fail-open ケース5: 権限エラー相当（helperスクリプトを読取不可にする） ==="
{
  start_fake_server
  setup_fixture
  NO_PERM_HELPER="$(mktemp)"
  cp "$REPO_ROOT/scripts/vault-agents/vector_recall_helper.py" "$NO_PERM_HELPER"
  chmod 000 "$NO_PERM_HELPER"
  out="$(run_hook s9 "キーワードヒット専用語についての質問" env VAULT_RECALL_VECTOR_HELPER="$NO_PERM_HELPER")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "fail-openログが残る" "$(cat "$LOG")" "ベクトル想起をfail-openでskipしました"
  chmod 644 "$NO_PERM_HELPER"
  rm -f "$NO_PERM_HELPER"
  stop_fake_server
  teardown_fixture
}

echo "=== 10. 付録A FR3ケース6（真の失敗ではない正常系）: 削除済みノートのベクトル残存（インデックスの最大1時間ラグ）はlog_fact()の事実記録として残る ==="
{
  start_fake_server
  setup_fixture
  rm "$VAULT_DIR/Knowledge/note-gamma.md"  # インデックス更新前にVaultから削除
  out="$(run_hook s10 "__MARK_DELTA__ について教えてほしい")"
  rc=$?
  assert_eq "exit code 0（このケースは異常ではなく正常な除外なので通常出力になりうる）" "0" "$rc"
  assert_not_contains "削除済みノートは候補に出ない" "$out" "note-gamma.md"
  assert_contains "除外件数がlog_fact()の事実記録としてログに残る（付録A FR3ケース6・全ケースでログ残すという要件）" \
    "$(cat "$LOG")" "削除済みノートのベクトル残存を"
  stop_fake_server
  teardown_fixture
}

echo "=== 11. helperの異常JSON出力もfail-openで1箇所に集約される ==="
{
  start_fake_server
  setup_fixture
  BAD_HELPER="$(mktemp)"
  cat > "$BAD_HELPER" <<'PYEOF'
print("this is not json")
PYEOF
  out="$(run_hook s11 "キーワードヒット専用語についての質問" env VAULT_RECALL_VECTOR_HELPER="$BAD_HELPER")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "JSON解析失敗のfail-openログ" "$(cat "$LOG")" "ベクトル想起をfail-openでskipしました"
  rm -f "$BAD_HELPER"
  stop_fake_server
  teardown_fixture
}

echo "=== 12. 複数行プロンプトの実改行がベクトル入力へそのまま渡る（キーワード用PROMPTの@tsvエスケープに巻き込まれない） ==="
{
  # 8.1ラウンド2巡目Codexレビュー指摘・Major対応の回帰テスト。helperをスタブに差し替え、
  # stdinで受け取った内容をそのままファイルへダンプさせて、実改行が"\n"の2文字リテラルに
  # 化けていないことを確認する。
  start_fake_server
  setup_fixture
  DUMP_FILE="$(mktemp)"
  DUMP_HELPER="$(mktemp)"
  cat > "$DUMP_HELPER" <<PYEOF
import sys
open("$DUMP_FILE", "w").write(sys.stdin.read())
print('{"candidates": [], "excluded_missing": 0}')
PYEOF
  payload='{"session_id":"s12","prompt":"1行目\n2行目\n3行目"}'
  printf '%s' "$payload" \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_EMBED_INDEX_DIR="$IDX_DIR" \
      VAULT_EMBED_BASE_URL="$BASE_URL" VAULT_RECALL_VECTOR_HELPER="$DUMP_HELPER" "$SCRIPT" >/dev/null

  # helperは非同期のbash killレース経由で起動されるため、書き込み完了を短くポーリングする。
  waited=0
  while [ ! -s "$DUMP_FILE" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done

  # $(...) はコマンド置換で末尾の改行を全て取り除いてしまうため、改行数のカウントは
  # 変数を経由せず直接ファイルに対して行う（内容チェック用のdumpedは別途変数で保持）。
  dumped="$(cat "$DUMP_FILE")"
  line_count="$(wc -l < "$DUMP_FILE" | tr -d ' ')"
  assert_eq "実改行3つ分（helperはstdinの末尾に改行を1つ追加で受け取るhere-string仕様どおり）がhelperへ渡る" "3" "$line_count"
  case "$dumped" in
    *'\n'*) fail_case "改行がリテラル\\nのまま残っている: $dumped" ;;
    *) pass "改行はリテラル化されず実改行のまま渡る" ;;
  esac

  rm -f "$DUMP_FILE" "$DUMP_HELPER"
  stop_fake_server
  teardown_fixture
}

echo "=== 13. Personal/フォルダもベクトル想起対象になり、profile-personal.mdはベクトル側でも除外される（2026-07-11決定・4→5フォルダ） ==="
{
  # Personal/personal-note.md と Personal/profile-personal.md の両方に同じマーカーを
  # 埋め込み、意図的に両方とも高い類似度でヒットする状況を作る。前者はベクトル候補と
  # して提示されるべきだが、後者は起動必読ファイルのため（キーワード枠と同様）
  # ベクトル枠でも除外されるべき＝vault-recall.shのEXCLUDE_RELPATHSチェックが
  # ベクトル側にも適用されていることの回帰確認。
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  LOG="$(mktemp)"
  write_note "$VAULT_DIR/Personal/personal-note.md" \
    $'date: 2026-07-11\naliases:\n  - "全く別の言い回しその2"' "__MARK_ZETA__ に関する内容の本文。"
  write_note "$VAULT_DIR/Personal/profile-personal.md" \
    $'date: 2026-07-11\naliases:\n  - "全く別の言い回しその3"' "__MARK_ZETA__ に関する内容の本文（プロフィール）。"
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1

  out="$(run_hook s13 "__MARK_ZETA__ について教えてほしい")"
  assert_contains "Personal/personal-note.mdはベクトル候補として提示される" "$out" "Personal/personal-note.md"
  assert_not_contains "Personal/profile-personal.mdはベクトル枠でも除外される" "$out" "profile-personal.md"

  stop_fake_server
  teardown_fixture
}

echo "=== 14. 除外対象ノートが上位を占めても、有効なベクトル候補3件は枯渇しない（3巡目Codexレビュー指摘・Major対応） ==="
{
  # EXCLUDE_RELPATHS該当ノート(6件・起動必読)を、有効な候補(3件)より高い類似度で
  # 上位に来るよう作為的に用意する。helper側のtop-n既定値が小さすぎると、上位が
  # 除外対象で埋まった時点で有効な候補がhelperの応答自体に含まれず、bash側の
  # 除外チェックが機能する前に取りこぼされる（旧既定値8では6件の除外対象だけで
  # ほぼ埋まってしまい、3件目以降の有効候補が返らないケースがあった）。
  # fake_ollama_server.pyのマーカーベクトル方式を使い、除外対象ノートには
  # クエリと完全一致するマーカー(__MARK_STARVE__のみ)を、有効ノートにはそれに加えて
  # 別マーカー(__MARK_STARVE2__)も持たせることで、cosine類似度を意図的に
  # 1.0(除外対象) > 約0.707(有効ノート) の順で確定させる。
  start_fake_server
  VAULT_DIR="$(mktemp -d)"
  IDX_DIR="$(mktemp -d)"
  LOG="$(mktemp)"

  # EXCLUDE_RELPATHSと完全一致する6件（実ファイルパスで作成・高類似度マーカーのみ）。
  write_note "$VAULT_DIR/Knowledge/mistakes.md" $'date: 2026-07-11' "__MARK_STARVE__ 本文。"
  write_note "$VAULT_DIR/Preferences/absolute-rules.md" $'date: 2026-07-11' "__MARK_STARVE__ 本文。"
  write_note "$VAULT_DIR/Preferences/profile.md" $'date: 2026-07-11' "__MARK_STARVE__ 本文。"
  write_note "$VAULT_DIR/Preferences/coding-delegation.md" $'date: 2026-07-11' "__MARK_STARVE__ 本文。"
  write_note "$VAULT_DIR/Preferences/vault-operation.md" $'date: 2026-07-11' "__MARK_STARVE__ 本文。"
  write_note "$VAULT_DIR/Personal/profile-personal.md" $'date: 2026-07-11' "__MARK_STARVE__ 本文。"
  # 有効な候補3件（除外対象より弱いが閾値は超える類似度＝約0.707）。
  for n in 1 2 3; do
    fm="date: 2026-07-11
aliases:
  - \"全く別の言い回しstarve${n}\""
    write_note "$VAULT_DIR/Knowledge/valid-candidate-$n.md" "$fm" \
      "__MARK_STARVE__ __MARK_STARVE2__ 本文その${n}。"
  done
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1

  out="$(run_hook s14 "__MARK_STARVE__ について教えてほしい")"
  for n in 1 2 3; do
    assert_contains "有効候補${n}が除外対象6件の陰で枯渇せず提示される" "$out" "valid-candidate-$n.md"
  done
  assert_not_contains "除外対象(mistakes.md)はベクトル枠に出ない" "$out" "mistakes.md"

  stop_fake_server
  teardown_fixture
}

echo "=== 15. 自己打ち切り（段階縮退）その1: フック予算が起動前から既に尽きていればベクトル起動自体をスキップする（8.3ラウンド新設） ==="
{
  start_fake_server
  setup_fixture
  # HOOK_BUDGET_MS=1・DEGRADE_TAIL_RESERVE_MS=0 → 打ち切り閾値1ms。stdin解析等の
  # セットアップだけで確実にこれを超えるため、ベクトルは起動されずキーワードのみで
  # 返る（fakeサーバへは実際に接続を試みないため遅延指定は不要）。
  out="$(run_hook s15 "キーワードヒット専用語についての質問" \
    env VAULT_RECALL_HOOK_BUDGET_MS=1 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=0)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_not_contains "ベクトル枠の見出しは出ない（起動自体をスキップしたため）" "$out" "意味的に近い候補"
  assert_contains "自己打ち切り（段階縮退）のログが残る" "$(cat "$LOG")" \
    "自己打ち切り（段階縮退）: フック予算(1ms)の残りが乏しいため"
  assert_contains "起動自体をスキップした旨が明記される" "$(cat "$LOG")" "起動自体をスキップ"
  stop_fake_server
  teardown_fixture
}

echo "=== 16. 自己打ち切り（段階縮退）その2: 起動後にベクトルが長引く場合、自身のkill-after到達を待たずポーリングループ側で打ち切る ==="
{
  setup_fixture_delay2() {
    VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; LOG="$(mktemp)"
    write_note "$VAULT_DIR/Preferences/keyword-hit-note.md" \
      $'date: 2026-07-01\naliases:\n  - "キーワードヒット専用語"' "本文。"
  }
  start_fake_server
  setup_fixture_delay2
  # インデックス構築は遅延なしサーバで行う。
  python3 "$UPDATE_SCRIPT" --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --base-url "$BASE_URL" >/dev/null 2>&1
  stop_fake_server
  # 検索時は900ms遅延させる。ベクトル自身のkill-after（budget+grace=5000+100ms）は
  # 十分大きく取り、従来の「ベクトル自身の予算超過」killでは説明できないタイミング
  # （打ち切り閾値500ms＜900ms遅延＜5100ms kill-after）で打ち切られることを検証する。
  # 打ち切り閾値は500ms（HOOK_BUDGET_MS=600・RESERVE=100）とやや大きめに取り、
  # 起動前チェック（自己打ち切りその1）へ誤って倒れないよう、典型的なセットアップ
  # 時間（数十ms）との間に十分なマージンを確保する（Codexレビュー指摘・Minor:
  # CI負荷でセットアップが遅延すると閾値に競合しテストが不安定になりうるため）。
  FAKE_OLLAMA_DELAY_MS=900 start_fake_server
  t0_ns="$(date +%s%N 2>/dev/null || echo "")"
  out="$(run_hook s16 "キーワードヒット専用語についての質問" \
    env VAULT_RECALL_HOOK_BUDGET_MS=600 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=100 \
        VAULT_RECALL_VECTOR_BUDGET_MS=5000 VAULT_RECALL_VECTOR_KILL_GRACE_MS=100)"
  rc=$?
  t1_ns="$(date +%s%N 2>/dev/null || echo "")"
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "自己打ち切り（段階縮退）のログが残る（ベクトル自身のkill-after到達メッセージではない）" \
    "$(cat "$LOG")" "打ち切り閾値500ms到達"
  assert_not_contains "従来の予算超過メッセージにはならない" "$(cat "$LOG")" "helperの応答が予算(5000ms"
  if [ -n "$t0_ns" ] && [ -n "$t1_ns" ] && [ "${#t0_ns}" -ge 19 ] && [ "${#t1_ns}" -ge 19 ]; then
    elapsed_ms=$(( (10#$t1_ns - 10#$t0_ns) / 1000000 ))
    # 900ms遅延を律儀に待っていれば900ms超になるはず。自己打ち切りにより
    # 800ms未満（打ち切り閾値500ms＋後処理・プロセス起動オーバーヘッドの余裕）で
    # 完了していることを確認する（環境負荷で多少ぶれてもよいよう緩めに800ms未満とする）。
    assert_eq "900ms遅延を律儀に待たず打ち切られた（実測${elapsed_ms}ms<800ms）" "1" \
      "$([ "$elapsed_ms" -lt 800 ] && echo 1 || echo 0)"
  else
    echo "  (skip) date +%s%N が使えない環境のため所要時間の実測アサーションを省略"
  fi
  stop_fake_server
  teardown_fixture
}

echo "=== 17. ハートビート: 自己打ち切りでベクトルを諦めた結果キーワードも0件のときはハートビートを書かない（Codex一次レビュー指摘・Major対応） ==="
{
  start_fake_server
  setup_fixture
  # プロンプトはキーワード・ベクトルどちらとも一致しない語にする（setup_fixtureの
  # 2ノートいずれのalias/マーカーとも無関係）。HOOK_BUDGET_MS=1で自己打ち切りその1
  # （起動前スキップ）を確実に発火させ、ベクトルは試みられない＝結果的にキーワードも
  # ベクトルも0件になる。この場合でもERROR行（自己打ち切りのログ）はあるので
  # ハートビートは書かない。
  out="$(run_hook s17 "全く無関係などうでもいい話題についての雑談です" \
    env VAULT_RECALL_HOOK_BUDGET_MS=1 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=0)"
  rc=$?
  logtext="$(cat "$LOG" 2>/dev/null || true)"
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "標準出力は空" "" "$out"
  assert_contains "自己打ち切りのERROR行は残る" "$logtext" "起動自体をスキップ"
  assert_not_contains "ハートビートは書かれない（PIPELINE_HAD_ERRORにより抑止）" "$logtext" "(heartbeat)"
  stop_fake_server
  teardown_fixture
}

echo "=== 18. 自己打ち切り: date +%s%N が使えない環境ではこの機能だけがfail-openで無効化され、通常の想起処理は継続する（Codexレビュー指摘） ==="
{
  start_fake_server
  setup_fixture
  REAL_DATE="$(command -v date)"
  BINDIR="$(mktemp -d)"
  cat > "$BINDIR/date" <<EOF
#!/bin/bash
if [ "\$1" = "+%s%N" ]; then
  echo "12345N"
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
  chmod +x "$BINDIR/date"
  # HOOK_BUDGET_MS=1なら通常は自己打ち切りその1が即発火してベクトルは起動されない
  # はずだが、date+%s%N が使えない（now_ms()が空文字を返す）ためこの判定自体が
  # 無効化され、従来どおりベクトルは起動・完走することを確認する。
  out="$(PATH="$BINDIR:$PATH" run_hook s18 "__MARK_DELTA__ について教えてほしい" \
    env VAULT_RECALL_HOOK_BUDGET_MS=1 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=0)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "date+%s%N不通でも自己打ち切りは発火せずベクトルが正常に起動・完走する" "$out" "意味的に近い候補"
  assert_not_contains "自己打ち切りログは残らない" "$(cat "$LOG")" "自己打ち切り"
  rm -rf "$BINDIR"
  stop_fake_server
  teardown_fixture
}

echo "=== 19. 自己打ち切り: DEGRADE_TAIL_RESERVE_MS > HOOK_BUDGET_MS でも負数化せず閾値0にクランプされクラッシュしない（境界値・Codexレビュー指摘） ==="
{
  start_fake_server
  setup_fixture
  out="$(run_hook s19 "キーワードヒット専用語についての質問" \
    env VAULT_RECALL_HOOK_BUDGET_MS=100 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=500)"
  rc=$?
  assert_eq "exit code 0（負数閾値にならずクラッシュしない）" "0" "$rc"
  assert_contains "キーワード結果は保持される" "$out" "keyword-hit-note.md"
  assert_contains "打ち切り閾値は0msにクランプされる" "$(cat "$LOG")" "打ち切り閾値0ms"
  stop_fake_server
  teardown_fixture
}

echo "=== 20. 自己打ち切り: HOOK_BUDGET_MS/DEGRADE_TAIL_RESERVE_MSが7桁以上（オーバーフロー対策の上限）でも既定値へフォールバックする（Codex一次レビュー2巡目指摘・Minor） ==="
{
  start_fake_server
  setup_fixture
  # HOOK_BUDGET_MS=1000000(7桁)が既定値2000msへ正しくフォールバックするなら、
  # DEGRADE_TAIL_RESERVE_MS=2500(有効値)との差は 2000-2500=-500 → 0にクランプされ、
  # 打ち切り閾値0msで即座に起動前スキップが発火するはず（もしフォールバックせず
  # 1000000のまま算術展開に渡っていれば、差は997500で大きくベクトルは正常完走する
  # ため、両者は観測結果で区別できる）。
  out="$(run_hook s20a "キーワードヒット専用語についての質問" \
    env VAULT_RECALL_HOOK_BUDGET_MS=1000000 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=2500)"
  rc=$?
  assert_eq "HOOK_BUDGET_MS=1000000(7桁)でもexit code 0" "0" "$rc"
  assert_not_contains "ベクトル枠は出ない（フォールバックにより即スキップ）" "$out" "意味的に近い候補"
  assert_contains "HOOK_BUDGET_MSが既定値2000msへフォールバックした結果として打ち切り閾値0msになる" \
    "$(cat "$LOG")" "フック予算(2000ms)の残りが乏しいため"

  # 同様にDEGRADE_TAIL_RESERVE_MS=9999999(7桁)が既定値400msへ正しくフォールバック
  # するなら、HOOK_BUDGET_MS=999999(有効な6桁最大値)との差は999599で大きくベクトルは
  # 正常完走するはず（もしフォールバックせず9999999のままなら差が大きく負になり
  # 閾値0msで即スキップされるため、両者は区別できる）。
  out="$(run_hook s20b "__MARK_DELTA__ について教えてほしい" \
    env VAULT_RECALL_HOOK_BUDGET_MS=999999 VAULT_RECALL_DEGRADE_TAIL_RESERVE_MS=9999999)"
  rc=$?
  assert_eq "DEGRADE_TAIL_RESERVE_MS=9999999(7桁)でもexit code 0" "0" "$rc"
  assert_contains "DEGRADE_TAIL_RESERVE_MSが既定値400msへフォールバックしベクトルは正常完走する" \
    "$out" "意味的に近い候補"
  # このブロック内で共有しているLOGにはs20aの自己打ち切りログも既に入っているため、
  # s20bのセッションIDに限定して自己打ち切りが発火していないことを確認する。
  assert_not_contains "s20bでは自己打ち切りは発火しない" "$(grep 's20b' "$LOG" 2>/dev/null)" "自己打ち切り"
  stop_fake_server
  teardown_fixture
}

echo "=== 21. --model明示渡し: vector_recall_helper.pyへVAULT_EMBED_MODEL（既定はei.DEFAULT_MODELと同じ\"qwen3-embedding:0.6b\"）を明示的に--modelとして渡す（2026-07-14修正・外部脳の想起・ベンチ機構の総点検・環境変数一致への暗黙依存の解消） ==="
{
  # 実Ollama・実インデックスは不要（helperをスタブに差し替え、受け取ったargvを
  # そのままファイルへダンプさせて--modelの値だけを確認する。テスト12のDUMP_HELPER
  # と同じ手法）。
  VAULT_DIR="$(mktemp -d)"
  LOG="$(mktemp)"
  write_note "$VAULT_DIR/Knowledge/dummy-note.md" $'date: 2026-07-14' "本文。"

  ARGV_FILE="$(mktemp)"
  ARGV_HELPER="$(mktemp)"
  cat > "$ARGV_HELPER" <<PYEOF
import sys
open("$ARGV_FILE", "w").write(" ".join(sys.argv[1:]))
print('{"candidates": [], "excluded_missing": 0}')
PYEOF

  printf '{"session_id":"s21a","prompt":"十分な長さのダミープロンプトです"}' \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_VECTOR_HELPER="$ARGV_HELPER" \
      "$SCRIPT" >/dev/null

  waited=0
  while [ ! -s "$ARGV_FILE" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  argv_text="$(cat "$ARGV_FILE")"
  assert_contains "VAULT_EMBED_MODEL未設定時は既定値qwen3-embedding:0.6bが--modelとして渡る" "$argv_text" "--model qwen3-embedding:0.6b"

  : > "$ARGV_FILE"
  printf '{"session_id":"s21b","prompt":"十分な長さのダミープロンプトです"}' \
    | VAULT_RECALL_VAULT="$VAULT_DIR" VAULT_RECALL_LOG="$LOG" VAULT_RECALL_VECTOR_HELPER="$ARGV_HELPER" \
      VAULT_EMBED_MODEL="custom-test-model" "$SCRIPT" >/dev/null

  waited=0
  while [ ! -s "$ARGV_FILE" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  argv_text="$(cat "$ARGV_FILE")"
  assert_contains "VAULT_EMBED_MODEL設定時はその値が--modelとして渡る（環境変数一致への暗黙依存ではなく明示引数）" \
    "$argv_text" "--model custom-test-model"

  rm -f "$ARGV_FILE" "$ARGV_HELPER"
  rm -rf "$VAULT_DIR"
  rm -f "$LOG"
}

echo "=== 22. --model明示渡し: 既定値"qwen3-embedding:0.6b"の文字列リテラルはembedding_index.DEFAULT_MODELのフォールバック値と一致する（SSOT検証・値のドリフト防止） ==="
{
  hook_literal="$(grep -v '^[[:space:]]*#' "$SCRIPT" \
    | grep -oE 'VECTOR_MODEL="\$\{VAULT_EMBED_MODEL:-[^}]+\}"' \
    | grep -oE ':-[^}]+\}"$' | sed -E 's/^:-//; s/\}"$//')"
  py_literal="$(python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents'); import os; os.environ.pop('VAULT_EMBED_MODEL', None); import importlib; import embedding_index as ei; importlib.reload(ei); print(ei.DEFAULT_MODEL)")"
  if [[ -z "$hook_literal" ]]; then
    fail_case "vault-recall.shからVECTOR_MODELの既定値リテラルを抽出できなかった（grepパターンがフック側の変更でズレた可能性）"
  else
    assert_eq "hook側のVECTOR_MODEL既定値リテラルがembedding_index.DEFAULT_MODELのフォールバック値と一致" "$py_literal" "$hook_literal"
  fi
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
