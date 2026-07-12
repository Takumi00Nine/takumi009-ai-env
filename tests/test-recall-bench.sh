#!/usr/bin/env bash
# scripts/vault-agents/recall_bench.py のユニットテスト（想起ベンチマーク自動採点ハーネス）。
#
# 実Vault($HOME/Data/obsidian)には一切依存しない。--vault で毎回ダミーのfixture
# ディレクトリを指定する。実物の claude/hooks/vault-recall.sh をsubprocessで実際に
# 叩く採点方式のため、多くのケースはfixtureに対して実フックを走らせて確認する
# （ロジック再実装との一致を人手で保証しなくてよい設計そのものの検証を兼ねる）。
# フック異常系のみ、fixtureの偽hook（bashスクリプト）で意図的に壊す。
#
# 実行方法: bash tests/test-recall-bench.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/recall_bench.py"
HOOK="$REPO_ROOT/claude/hooks/vault-recall.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれない: \"$needle\")"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

write_note() {
  # write_note <path> <frontmatter本文(改行区切り)> [本文]
  local path="$1" fm="$2" body="${3:-本文}"
  mkdir -p "$(dirname "$path")"
  {
    echo "---"
    printf '%s\n' "$fm"
    echo "---"
    echo
    printf '%s\n' "$body"
  } > "$path"
}

echo "=== 1. 基本のpass/fail判定（実フックを実際に叩く） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/python-venv.md" \
    $'date: 2026-07-10\naliases:\n  - "venv未有効ブロック"'
  write_note "$VAULT_DIR/Knowledge/unrelated-note.md" \
    $'date: 2026-07-10\naliases:\n  - "veryspecificalias"'

  BENCH="$(mktemp)"
  {
    printf 'Pythonのパッケージをインストールするときのvenv未有効ブロックの決まりは？\tPreferences/python-venv.md\n'
    printf '全く関係ない話題について質問したいです\tKnowledge/nonexistent-note.md\n'
  } > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" 2>/tmp/recall-bench-test-err.log)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "Q1はPASS" "$out" "[ 1] PASS"
  assert_contains "Q2はFAIL" "$out" "[ 2] FAIL"
  assert_contains "サマリのヒット率が1/2" "$out" "ヒット率 1/2 (50.0%)"
  assert_contains "FAIL一覧にQ2が載る" "$out" "全く関係ない話題について質問したいです"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo "=== 2. 複数期待ノート(|区切り): どちらか1つ一致すればpass ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/git-workflow.md" \
    $'date: 2026-07-10\naliases:\n  - "public化はユーザー自身"'

  BENCH="$(mktemp)"
  printf 'リポジトリをpublic化はユーザー自身がやっていいの？\tPreferences/absolute-rules.md|Preferences/git-workflow.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" 2>/dev/null)"
  assert_contains "2つ目の期待ノートで一致してPASSになる" "$out" "[ 1] PASS"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo "=== 3. --json: 機械可読サマリの構造 ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/hit-note.md" $'date: 2026-07-10\naliases:\n  - "hitkeyword12345"'

  BENCH="$(mktemp)"
  printf 'hitkeyword12345について確認したい、十分な長さのプロンプトです\tKnowledge/hit-note.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" --json 2>/dev/null)"
  total="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')"
  hits="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hits"])')"
  rate="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hit_rate"])')"
  cand0="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["candidates"][0])')"
  assert_eq "total=1" "1" "$total"
  assert_eq "hits=1" "1" "$hits"
  assert_eq "hit_rate=1.0" "1.0" "$rate"
  assert_eq "resultsに提示候補が入る" "Knowledge/hit-note.md" "$cand0"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo "=== 4. --alias-overlay: 実Vaultを書き換えずに仮想的にaliasを足して採点できる ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/mcp-global-install.md" $'date: 2026-07-10'

  BENCH="$(mktemp)"
  printf 'npxで都度起動していいですか、十分な長さのプロンプトです\tPreferences/mcp-global-install.md\n' > "$BENCH"

  # VAULT_RECALL_DISABLE_VECTORで実行環境の実Vault埋め込みインデックス
  # （~/.cache/vault-embeddings/等）混入を遮断する。このテストは一時fixture Vaultに対して
  # フックを実行するが、フックはVECTOR_HELPERの既定インデックス置き場（実Vault分と共通）を
  # 参照するため、実インデックスに偶然relpathが一致するノートがあるとキーワード一致0件でも
  # ベクトル想起経由で候補提示されてしまい、このテストが環境依存でflakyになっていた
  # （実機で再現・原本コードでも同じ箇所が同じ理由で失敗することを確認済み）。本テストは
  # キーワード照合(alias-overlay)の検証が目的でありベクトル想起の挙動とは無関係なため、
  # 無効化してもテストの意図は変わらない。
  before_out="$(VAULT_RECALL_DISABLE_VECTOR=1 python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" 2>/dev/null)"
  assert_contains "overlay無しではFAIL（aliasが無いので提示されない）" "$before_out" "[ 1] FAIL"

  OVERLAY="$(mktemp)"
  printf 'Preferences/mcp-global-install.md\tnpxで都度起動\n' > "$OVERLAY"
  BEFORE_SUM="$(md5 -q "$VAULT_DIR/Preferences/mcp-global-install.md" 2>/dev/null || md5sum "$VAULT_DIR/Preferences/mcp-global-install.md" | cut -d' ' -f1)"

  after_out="$(VAULT_RECALL_DISABLE_VECTOR=1 python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" --alias-overlay "$OVERLAY" 2>/dev/null)"
  assert_contains "overlay適用後はPASSになる" "$after_out" "[ 1] PASS"

  AFTER_SUM="$(md5 -q "$VAULT_DIR/Preferences/mcp-global-install.md" 2>/dev/null || md5sum "$VAULT_DIR/Preferences/mcp-global-install.md" | cut -d' ' -f1)"
  assert_eq "実Vault側のノートは無変更（overlayは一時コピーのみに適用）" "$BEFORE_SUM" "$AFTER_SUM"

  rm -rf "$VAULT_DIR" "$BENCH" "$OVERLAY"
}

echo "=== 5. フック異常時の頑健性: 空出力(正常miss)は握りつぶさずfailにする ==="
{
  FAKE_HOOK="$(mktemp)"
  printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" 2>/dev/null)"
  rc=$?
  assert_eq "空出力でもrecall_bench.py自体はクラッシュしない" "0" "$rc"
  assert_contains "空出力はFAILとして扱われる" "$out" "[ 1] FAIL"
  assert_not_contains "空出力はhookエラーとしては報告しない(正常なヒット無し)" "$out" "hookエラー"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 6. フック異常時の頑健性: 壊れたJSON出力はエラーとして可視化される ==="
{
  FAKE_HOOK="$(mktemp)"
  printf '#!/bin/bash\ncat >/dev/null\necho "not valid json"\nexit 0\n' > "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" 2>/dev/null)"
  rc=$?
  assert_eq "壊れたJSON出力でもクラッシュしない" "2" "$rc"
  assert_contains "壊れたJSON出力はFAILになる" "$out" "[ 1] FAIL"
  assert_contains "無言のfail-openにせずhookエラーとして表示する" "$out" "⚠️ hookエラー"
  assert_contains "JSON解析失敗のメッセージが出る" "$out" "JSON解析に失敗"

  out_allow="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --allow-hook-errors 2>/dev/null)"
  rc_allow=$?
  assert_eq "--allow-hook-errorsを付けるとexit 0に戻る" "0" "$rc_allow"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 7. フック異常時の頑健性: 非0終了はエラーとして可視化される ==="
{
  FAKE_HOOK="$(mktemp)"
  printf '#!/bin/bash\ncat >/dev/null\necho "boom" >&2\nexit 1\n' > "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" 2>/dev/null)"
  rc=$?
  assert_eq "非0終了でもrecall_bench.py自体はクラッシュせずexit 2で異常を知らせる" "2" "$rc"
  assert_contains "非0終了時のエラーメッセージが表示される" "$out" "非0終了しました"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 8. フック異常時の頑健性: timeoutでもクラッシュせずエラーとして可視化される ==="
{
  FAKE_HOOK="$(mktemp)"
  printf '#!/bin/bash\ncat >/dev/null\nsleep 5\n' > "$FAKE_HOOK"

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" --hook-timeout 0.5 2>/dev/null)"
  rc=$?
  assert_eq "timeoutでもクラッシュせずexit 2で異常を知らせる" "2" "$rc"
  assert_contains "timeoutがエラーとして表示される" "$out" "timeout"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 9. 不正な引数はexit非0でFAILメッセージを出す ==="
{
  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf 'ダミーの質問文です十分な長さがあります\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "/nonexistent-hook-xyz.sh" 2>&1)"
  rc=$?
  assert_eq "存在しないhookパスは非0終了" "1" "$rc"
  assert_contains "hookが見つからない旨のメッセージ" "$out" "hookが見つかりません"

  out2="$(python3 "$SCRIPT" "$BENCH" --vault "/nonexistent-vault-xyz" --hook "$HOOK" 2>&1)"
  rc2=$?
  assert_eq "存在しないvaultパスは非0終了" "1" "$rc2"
  assert_contains "vaultが見つからない旨のメッセージ" "$out2" "vaultが見つかりません"

  EMPTY_BENCH="$(mktemp)"
  out3="$(python3 "$SCRIPT" "$EMPTY_BENCH" --vault "$VAULT_DIR" --hook "$HOOK" 2>&1)"
  rc3=$?
  assert_eq "空のベンチTSVは非0終了" "1" "$rc3"
  assert_contains "採点対象が無い旨のメッセージ" "$out3" "採点対象がありません"

  rm -rf "$VAULT_DIR" "$BENCH" "$EMPTY_BENCH"
}

echo "=== 10. ベンチTSVの壊れた行はWARNしてskipし、正常行だけ採点する ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Knowledge/hit-note.md" $'date: 2026-07-10\naliases:\n  - "hitkeyword12345"'

  BENCH="$(mktemp)"
  {
    echo "# コメント行"
    echo ""
    printf '列が足りない行\n'
    printf 'hitkeyword12345について確認したい、十分な長さのプロンプトです\tKnowledge/hit-note.md\n'
  } > "$BENCH"

  err="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" --json 2>&1 >/dev/null)"
  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" --json 2>/dev/null)"
  total="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')"
  assert_eq "壊れた行・コメント・空行を除いた1件だけが採点される" "1" "$total"
  assert_contains "壊れた行はWARNとしてstderrに出る" "$err" "WARN"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo "=== 11. FAIL一覧に期待ノートの現aliasesが併記される（alias改善の材料） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/target-note.md" \
    $'date: 2026-07-10\naliases:\n  - "既存alias1"\n  - "既存alias2"'

  BENCH="$(mktemp)"
  printf '全然関係ないので絶対に一致しない質問文です\tPreferences/target-note.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" 2>/dev/null)"
  assert_contains "FAIL一覧に現aliasesが表示される" "$out" "既存alias1, 既存alias2"

  rm -rf "$VAULT_DIR" "$BENCH"
}

echo "=== 12. --alias-overlay: 一時Vault外を指すパス(絶対パス・../脱出)は拒否してskipする（Codexレビュー指摘・Critical） ==="
{
  VAULT_DIR="$(mktemp -d)"
  write_note "$VAULT_DIR/Preferences/mcp-global-install.md" $'date: 2026-07-10'
  OUTSIDE="$(mktemp).md"
  printf 'outside marker\n' > "$OUTSIDE"
  OUTSIDE_SUM_BEFORE="$(md5 -q "$OUTSIDE" 2>/dev/null || md5sum "$OUTSIDE" | cut -d' ' -f1)"

  BENCH="$(mktemp)"
  printf 'ダミーの質問文です十分な長さがあります\tPreferences/mcp-global-install.md\n' > "$BENCH"

  OVERLAY="$(mktemp)"
  {
    # "../"で一時Vault外(親ディレクトリ)へ脱出を試みる行と、絶対パスで任意ファイルを
    # 指す行。どちらも一時Vault内のノートとしては存在しないので、
    # 一時Vault内へ書き込まれてはならない・実在の外部ファイルも変更されてはならない。
    printf '../outside-escape.md\tinjected-alias\n'
    printf '%s\tinjected-alias2\n' "$OUTSIDE"
  } > "$OVERLAY"

  err="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$HOOK" --alias-overlay "$OVERLAY" --json 2>&1 >/dev/null)"
  assert_contains "../での一時Vault外脱出はWARNしてskipする" "$err" "一時Vaultの外を指しているため"
  assert_contains "絶対パスでの一時Vault外指定もWARNしてskipする" "$err" "一時Vaultの外を指しているため"

  OUTSIDE_SUM_AFTER="$(md5 -q "$OUTSIDE" 2>/dev/null || md5sum "$OUTSIDE" | cut -d' ' -f1)"
  assert_eq "Vault外の実ファイルは書き換えられない" "$OUTSIDE_SUM_BEFORE" "$OUTSIDE_SUM_AFTER"

  rm -rf "$VAULT_DIR" "$BENCH" "$OVERLAY" "$OUTSIDE"
}

echo "=== 13. フック異常時の頑健性: additionalContextはあるが候補行が抽出できない場合(表示フォーマット変更)もエラーにする ==="
{
  FAKE_HOOK="$(mktemp)"
  # additionalContextはあるが、実フックの "- relpath（一致: ...）" 形式ではない
  # （表示フォーマットが将来変わった場合を模す）。
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
cat >/dev/null
echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"想定外のフォーマットです（候補行なし）"}}'
HOOKEOF

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" 2>/dev/null)"
  rc=$?
  assert_eq "候補行が抽出できないフォーマット変更もexit 2で異常として扱う" "2" "$rc"
  assert_contains "無言でmiss扱いにせずhookエラーとして表示する" "$out" "候補行を1件も抽出できませんでした"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo "=== 14. フック異常時の頑健性: 「- 」箇条書き行はあるが（一致:）区切りが無い場合もエラーにする（Codexレビュー指摘・Major回帰） ==="
{
  FAKE_HOOK="$(mktemp)"
  # "- "始まりの箇条書き行自体はあるが、区切りが「（一致: 」ではなく別の書式に変わった
  # ケースを模す（緩い判定だとrelpathを誤って別文字列として抽出してしまう回帰）。
  cat > "$FAKE_HOOK" <<'HOOKEOF'
#!/bin/bash
cat >/dev/null
echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"外部脳の関連ノート候補:\n- Knowledge/anything.md (match: x)"}}'
HOOKEOF

  VAULT_DIR="$(mktemp -d)"
  BENCH="$(mktemp)"
  printf '何かについて質問したい、十分な長さのプロンプトです\tKnowledge/anything.md\n' > "$BENCH"

  out="$(python3 "$SCRIPT" "$BENCH" --vault "$VAULT_DIR" --hook "$FAKE_HOOK" 2>/dev/null)"
  rc=$?
  assert_eq "区切り文字が変わった箇条書き行もexit 2で異常として扱う" "2" "$rc"
  assert_contains "誤ったrelpathを候補として採用せずhookエラーとして表示する" "$out" "候補行の形式が想定と異なります"
  assert_not_contains "誤ったrelpathがPASS扱いのcandidatesとして混入しない" "$out" "PASS"

  rm -rf "$VAULT_DIR" "$BENCH" "$FAKE_HOOK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
