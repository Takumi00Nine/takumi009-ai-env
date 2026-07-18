#!/usr/bin/env bash
# scripts/vault-agents/knowledge_merge_candidates.py のユニットテスト
# （外部脳Knowledge自律整理・柱②「検出」専用CLI。LLM不使用・決定的処理のみ）。
#
# 2026-07-16簡素化（[[Decisions/2026-07-16-remove-vector-search-embedding-infra]]）で
# 埋め込みcosine類似度からキーワード系重み付きJaccard類似度（設計書§3.3・
# 重み aliases=0.4/タイトルトークン=0.3/タグ=0.2/outbound links=0.1）へ全面的に
# 作り替えたことに伴い、本ファイルも全面的に書き直した（旧実装は
# `git log -p -- tests/test-knowledge-merge-candidates.sh` 参照。
# tests/build_fixture_index.pyは埋め込みインデックス専用フィクスチャのため
# 本ファイルはもう使わない）。
#
# 実 $HOME/.claude/logs・実Vaultには依存しない（毎回tempディレクトリへ--vault/
# --out-dirを向ける）。類似度は各特徴量カテゴリ（aliases/タイトル/タグ/リンク）を
# 個別に一致・不一致させることで狙った値に決定的に制御する（重みが0.4/0.3/0.2/0.1
# と離散的なため、カテゴリ単位のON/OFFで正確な合成値を作れる）。
#
# 実行方法: bash tests/test-knowledge-merge-candidates.sh

set -uo pipefail

# 実HOME配下（~/.claude/tmp/vault-merge.lock等）への書込を構造的に不可能にする
# （2026-07-12 実インシデント対応の教訓を踏襲＝正本ルール: 実環境テストは
# sandbox/temp HOMEで隔離）。
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/knowledge_merge_candidates.py"

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

run_kmc() {
  python3 "$SCRIPT" "$@"
}

# $1=state.json $2=セクション(candidates/detections) $3=candidate_id $4=フィールド名
state_field() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get(sys.argv[2], {}).get(sys.argv[3], {}).get(sys.argv[4], ''))
" "$1" "$2" "$3" "$4"
}

# state.json内のcandidate_idを標準出力へ列挙する（セクション別）。$1=state.json $2=セクション
state_ids() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(' '.join(sorted(d.get(sys.argv[2], {}).keys())))
" "$1" "$2"
}

# N日前/後のYYYY-MM-DD（BSD date）。
d_date() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%F; }

# write_note <vault> <相対パス> <tags(スペース区切り・空可)> <links(スペース区切り・空可)> <aliases(スペース区切り・空可)>
# タイトル（ファイル名）は呼び出し側が完全にユニーク・無関係な語にすることで
# タイトルトークンjaccardの意図しない寄与を避ける（各テストで明示的に指定）。
write_note() {
  local vault="$1" rel="$2" tags="$3" links="$4" aliases="$5"
  mkdir -p "$(dirname "$vault/$rel")"
  {
    echo "---"
    echo "date: 2026-01-01"
    if [[ -n "$tags" ]]; then
      local tags_csv
      tags_csv="$(echo "$tags" | tr ' ' '\n' | paste -sd, -)"
      echo "tags: [$tags_csv]"
    fi
    if [[ -n "$aliases" ]]; then
      echo "aliases:"
      for a in $aliases; do echo "  - \"$a\""; done
    fi
    echo "---"
    echo
    for l in $links; do echo "参照: [[$l]]"; done
    echo "本文。"
  } > "$vault/$rel"
}

echo "=== 1. Knowledge同フォルダの相互最近傍(mutual top-1)が閾値以上でレビュー待ち候補になる ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  # aliases一致(0.4)+tags一致(0.2)=0.6・タイトル/リンクは無関係にして寄与ゼロにする。
  write_note "$VAULT" "Knowledge/xylophone.md" "shared-tag" "" "shared-alias"
  write_note "$VAULT" "Knowledge/quokka.md" "shared-tag" "" "shared-alias"

  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.5)"
  cid="$(state_ids "$OUT/state.json" candidates)"
  n_cand="$(echo "$cid" | wc -w | tr -d ' ')"
  assert_eq "候補が1件生成される" "1" "$n_cand"
  status="$(state_field "$OUT/state.json" candidates "$cid" status)"
  assert_eq "状態はpending" "pending" "$status"
  sim="$(state_field "$OUT/state.json" candidates "$cid" similarity)"
  assert_eq "類似度は0.6(alias0.4+tags0.2)" "0.6" "$sim"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 2. 候補IDはノートrelpathペアの正規化から決定的に導出される(順序非依存) ==="
{
  VAULT="$(mktemp -d)"; OUT1="$(mktemp -d)"; OUT2="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/aaa.md" "t" "" ""
  write_note "$VAULT" "Knowledge/zzz.md" "t" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT1" --sim-threshold 0.1 >/dev/null
  cid1="$(state_ids "$OUT1/state.json" candidates)"

  # 同じペアをファイル走査順が変わりうる別ディレクトリでもう一度実行してもIDは同じ。
  run_kmc --vault "$VAULT" --out-dir "$OUT2" --sim-threshold 0.1 >/dev/null
  cid2="$(state_ids "$OUT2/state.json" candidates)"

  assert_eq "候補IDは決定的(2回とも同じ)" "$cid1" "$cid2"
  [[ "$cid1" == cand-* ]] && pass "IDはcand-プレフィックスを持つ" || fail_case "IDはcand-プレフィックスを持つ"

  rm -rf "$VAULT" "$OUT1" "$OUT2"
}

echo "=== 3. 相互最近傍でない(片方向のみ最近傍)ペアは候補にならない ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  # A-Bはtags一致(0.2)、A-Cはalias一致(0.4)。Aから見た最近傍はC(0.4>0.2)。
  # Bから見た最近傍はA(唯一のtags一致相手)。B<->Aは相互ではない（Aの最近傍はC）。
  write_note "$VAULT" "Knowledge/one.md" "shared-tag" "" "shared-alias"
  write_note "$VAULT" "Knowledge/two.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/three.md" "" "" "shared-alias"

  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json)"
  n_cand="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_candidates"])')"
  assert_eq "相互最近傍の1ペアのみ候補になる(one<->three)" "1" "$n_cand"
  cid="$(state_ids "$OUT/state.json" candidates)"
  note_a="$(state_field "$OUT/state.json" candidates "$cid" note_a)"
  note_b="$(state_field "$OUT/state.json" candidates "$cid" note_b)"
  assert_contains "one.mdが候補に含まれる" "$note_a $note_b" "one.md"
  assert_contains "three.mdが候補に含まれる" "$note_a $note_b" "three.md"
  assert_not_contains "two.mdは候補に含まれない(片方向最近傍のため)" "$note_a $note_b" "two.md"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 4. 類似度閾値の境界: 閾値ちょうどなら候補になる(inclusive)・僅かに上回る閾値だと候補にならない ==="
{
  VAULT="$(mktemp -d)"; OUT1="$(mktemp -d)"; OUT2="$(mktemp -d)"
  # tags一致のみ→類似度は厳密に0.2（浮動小数の丸めが乗らない単純な値）。
  # ファイル名はタイトルトークンが一切重ならないよう完全に無関係な語にする
  # （例えば"border-a"/"border-b"だと"border"が共有トークンになりタイトル
  # jaccardが混入してしまう＝実際に踏んだ回帰・修正済み）。
  write_note "$VAULT" "Knowledge/quokka.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/xylophone.md" "shared-tag" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT1" --sim-threshold 0.2 >/dev/null
  n1="$(state_ids "$OUT1/state.json" candidates | wc -w | tr -d ' ')"
  assert_eq "閾値ちょうど(0.2)なら候補になる(inclusive)" "1" "$n1"

  run_kmc --vault "$VAULT" --out-dir "$OUT2" --sim-threshold 0.2001 >/dev/null
  n2="$(state_ids "$OUT2/state.json" candidates | wc -w | tr -d ' ')"
  assert_eq "僅かに上回る閾値(0.2001)だと候補にならない" "0" "$n2"

  rm -rf "$VAULT" "$OUT1" "$OUT2"
}

echo "=== 5. 相互最近傍が同点タイの場合は「候補にしない」(FR10a判定が割れた場合のデフォルト) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  # hub.mdはleft.md・right.mdどちらともtagsで同点(0.2)一致。タイトルトークンが
  # 一切重ならない語を選び、tags以外の寄与を排除する（"tie"/"tie-a"/"tie-b"の
  # ような共通接頭辞は意図せずタイトルjaccardを混入させてしまうため避ける＝
  # 実際に踏んだ回帰）。hubから見てleft/rightは同点タイなので候補にならない。
  write_note "$VAULT" "Knowledge/hub.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/left.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/right.md" "shared-tag" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  n_cand="$(state_ids "$OUT/state.json" candidates | wc -w | tr -d ' ')"
  assert_eq "同点タイのため候補は0件" "0" "$n_cand"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 6. マージ対象はKnowledge同フォルダのみ: Preferences同フォルダは検出ログ扱い(候補にはならない) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Preferences/pref-a.md" "shared-tag" "" "shared-alias"
  write_note "$VAULT" "Preferences/pref-b.md" "shared-tag" "" "shared-alias"

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  n_cand="$(state_ids "$OUT/state.json" candidates | wc -w | tr -d ' ')"
  n_det="$(state_ids "$OUT/state.json" detections | wc -w | tr -d ' ')"
  assert_eq "Preferences同士はマージ候補にならない" "0" "$n_cand"
  assert_eq "代わりに検出ログ(観測のみ)に記録される" "1" "$n_det"
  cid="$(state_ids "$OUT/state.json" detections)"
  kind="$(state_field "$OUT/state.json" detections "$cid" kind)"
  assert_eq "kind=same_folder_other" "same_folder_other" "$kind"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 7. フォルダ横断の相互最近傍はFR9cの検出ログとして集約され、複数週で連続検出回数が増える ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/cross-k.md" "shared-tag" "" "shared-alias"
  write_note "$VAULT" "Preferences/cross-p.md" "shared-tag" "" "shared-alias"

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  cid="$(state_ids "$OUT/state.json" detections)"
  n1="$(state_field "$OUT/state.json" detections "$cid" consecutive_detections)"
  assert_eq "1週目の連続検出回数は1" "1" "$n1"
  kind="$(state_field "$OUT/state.json" detections "$cid" kind)"
  assert_eq "kind=cross_folder" "cross_folder" "$kind"

  # 2週目（1週間後）にも同じペアが検出される想定でstate.jsonのlast_seenを
  # 1週間前へ手動でずらし、再実行して連続検出回数が2に増えることを確認する。
  python3 -c "
import json
p = '$OUT/state.json'
d = json.load(open(p))
d['detections']['$cid']['last_seen'] = '$(d_date -7)'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  n2="$(state_field "$OUT/state.json" detections "$cid" consecutive_detections)"
  assert_eq "2週目の連続検出回数は2" "2" "$n2"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 8. 複数週シミュレーション: pending→skipped(終端)で以後再生成されない ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/multi-a.md" "shared-tag" "" "shared-alias"
  write_note "$VAULT" "Knowledge/multi-b.md" "shared-tag" "" "shared-alias"

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  cid="$(state_ids "$OUT/state.json" candidates)"
  status1="$(state_field "$OUT/state.json" candidates "$cid" status)"
  assert_eq "1週目はpending" "pending" "$status1"

  # リーダー/夜間ジョブがskippedへ状態遷移させたと仮定してstate.jsonを直接編集
  # （実際のMERGE適用はmaintenance_apply.py・PR2の役目・本テストのスコープ外）。
  python3 -c "
import json
p = '$OUT/state.json'
d = json.load(open(p))
d['candidates']['$cid']['status'] = 'skipped'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  status2="$(state_field "$OUT/state.json" candidates "$cid" status)"
  assert_eq "skipped後も再検出でstatusが変わらない(tombstone)" "skipped" "$status2"
  n_active="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
import json
d = json.load(open('$OUT/state.json'))
print(len(kmc.active_candidates_only(d['candidates'])))
")"
  assert_eq "アクティブ候補としては0件(表示・件数から除外)" "0" "$n_active"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 8b. 終端状態(skipped)は同一実行内で即座にpendingへ再生成されない ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/term-a.md" "shared-tag" "" "shared-alias"
  write_note "$VAULT" "Knowledge/term-b.md" "shared-tag" "" "shared-alias"
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  cid="$(state_ids "$OUT/state.json" candidates)"
  python3 -c "
import json
p = '$OUT/state.json'
d = json.load(open(p))
d['candidates']['$cid']['status'] = 'skipped'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  status="$(state_field "$OUT/state.json" candidates "$cid" status)"
  assert_eq "同一ペアが再検出されてもstatusはskippedのまま" "skipped" "$status"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 9. 既にスタブ化済み(deprecated: true)のノートはペア候補生成の対象から除外される ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  cat > "$VAULT/Knowledge/stub-a.md" <<'EOF'
---
date: 2026-01-01
tags: [shared-tag]
deprecated: true
superseded_by: "[[Knowledge/stub-merged]]"
---
スタブ
EOF
  write_note "$VAULT" "Knowledge/stub-b.md" "shared-tag" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null
  n_cand="$(state_ids "$OUT/state.json" candidates | wc -w | tr -d ' ')"
  assert_eq "deprecated:trueのノートは除外され候補0件" "0" "$n_cand"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 10. 週次間隔ガードは撤去済み: 同日に複数回実行してもskipせず毎回検出処理を行う（tester独立検証F3対応・2026-07-16撤去） ==="
{
  # 旧MIN_INTERVAL_DAYSガード（--force・--min-interval-days）は撤去した。
  # 理由: ガードのskipメッセージが--json指定時も標準出力へ平文で出力されて
  # おり、maintenance.sh Phase1④が毎回有効なJSONを受け取れる契約に違反して
  # いた（tester独立検証F3）。リーダー裁定によりfragments_log.py・
  # vault_inventory.pyと同じ「ガード自体を持たない」方式へ統一した。
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/interval-a.md" "t" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT" >/dev/null
  n1="$(ls "$OUT"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "1回目はレポートが作られる" "1" "$n1"

  out2="$(run_kmc --vault "$VAULT" --out-dir "$OUT")"
  assert_not_contains "同日の2回目再実行でもskipメッセージは出ない(ガード撤去済み)" "$out2" "skip:"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 10b. --jsonは同日に複数回実行しても常に標準出力へ有効なJSONだけを返す（間隔ガード撤去による平文skip混入の回帰テスト・tester独立検証F3対応） ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/interval-json-a.md" "t" "" ""

  out1="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --json 2>/dev/null)"
  PARSE1_OK="$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('OK')" "$out1" 2>/dev/null || echo "FAIL")"
  assert_eq "1回目の--json出力は有効なJSONとしてパースできる" "OK" "$PARSE1_OK"

  # 同日に2回連続で--json実行しても（旧ガードなら平文skipが混じっていた）、
  # 標準出力は常に有効なJSONのみであることを確認する。
  out2="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --json 2>/dev/null)"
  PARSE2_OK="$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('OK')" "$out2" 2>/dev/null || echo "FAIL")"
  assert_eq "同日の2回目--json実行でも標準出力は有効なJSONのまま(平文skip混入なし)" "OK" "$PARSE2_OK"
  assert_not_contains "2回目の--json標準出力にskip:平文が混入しない" "$out2" "skip:"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 11. Vault不在はfail-open(レポート生成せず正常終了・exit 0) ==="
{
  OUT="$(mktemp -d)"
  rc=0
  out="$(run_kmc --vault "/nonexistent-vault-dir-$$" --out-dir "$OUT" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "Vault不在のskipメッセージが出る" "$out" "Vaultが見つかりません"
  n_reports="$(ls "$OUT"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "レポートは生成されない" "0" "$n_reports"

  rm -rf "$OUT"
}

echo "=== 12. 対象ノートが1件以下のフォルダはエラーにならず候補0件になる ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/only-one.md" "t" "" ""

  rc=0
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 >/dev/null || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  n_cand="$(state_ids "$OUT/state.json" candidates | wc -w | tr -d ' ')"
  assert_eq "候補0件" "0" "$n_cand"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 13. state.jsonが壊れている場合はfail-open(書込せず正常終了・既存内容を保持) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/broken-a.md" "t" "" ""
  mkdir -p "$OUT"
  echo "not valid json {{{" > "$OUT/state.json"
  cp "$OUT/state.json" "$OUT/state.json.orig"

  rc=0
  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "state.json解析失敗のskipメッセージが出る" "$out" "skip:"
  diff_result="$(diff "$OUT/state.json" "$OUT/state.json.orig" && echo same || echo different)"
  assert_eq "state.jsonの内容は変更されない" "same" "$diff_result"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 14. state.jsonが不正な形式(candidatesがオブジェクトでない等)でもfail-open ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/badformat-a.md" "t" "" ""
  mkdir -p "$OUT"
  echo '{"schema_version": 1, "candidates": [1,2,3], "detections": {}}' > "$OUT/state.json"

  rc=0
  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "不正形式のskipメッセージが出る" "$out" "オブジェクトではありません"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 14b. state.jsonにschema_versionが無い/不一致でもfail-open ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/noschema-a.md" "t" "" ""
  mkdir -p "$OUT"
  echo '{"candidates": {}, "detections": {}}' > "$OUT/state.json"

  rc=0
  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "schema_version欠如のskipメッセージが出る" "$out" "schema_version"

  OUT2="$(mktemp -d)"
  echo '{"schema_version": 999, "candidates": {}, "detections": {}}' > "$OUT2/state.json"
  rc2=0
  out2="$(run_kmc --vault "$VAULT" --out-dir "$OUT2" --sim-threshold 0.1 2>&1)" || rc2=$?
  assert_eq "schema_version不一致でもexit 0" "0" "$rc2"
  assert_contains "schema_version不一致のskipメッセージが出る" "$out2" "schema_versionが不一致"

  rm -rf "$VAULT" "$OUT" "$OUT2"
}

echo "=== 15. state.json排他ロックが競合していれば書込せずskipする ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/lock-a.md" "t" "" ""
  # ロックファイル専用の一時ディレクトリを切る（Codexレビュー指摘Critical
  # 対応: 以前は`mktemp -u`で共有一時ディレクトリ直下の未作成パスを取得し、
  # 後始末で`rm -rf "$(dirname "$LOCK")"`していたため、共有一時ディレクトリ
  # （$TMPDIR）自体を再帰削除してしまう危険があった。ロック専用ディレクトリを
  # 個別に持てば、削除対象をそのディレクトリだけに限定できる）。
  LOCK_DIR="$(mktemp -d)"
  LOCK="$LOCK_DIR/vault-merge.lock"
  READY="$LOCK_DIR/ready"

  # 別プロセスでロックを保持し続ける（Pythonでflockしてsleep）。flock成功後に
  # READYファイルを作ってから待つことで、シェル側は固定sleepではなく
  # 「ロックが実際に取得されたこと」を確認してから本体を起動できる
  # （Codexレビュー指摘Minor対応: 固定sleep 0.5だけだと高負荷環境で対象CLI側が
  # 先にロックを取得してしまい断続的に失敗しうる、というタイミング依存を解消）。
  python3 -c "
import fcntl, os, time, pathlib
p = pathlib.Path('$LOCK')
p.parent.mkdir(parents=True, exist_ok=True)
fd = os.open(str(p), os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
pathlib.Path('$READY').write_text('1', encoding='utf-8')
time.sleep(3)
" &
  holder_pid=$!
  # READYファイルの出現を最大5秒待つ（ポーリング。固定sleepより堅牢）。
  for _ in $(seq 1 50); do
    [ -f "$READY" ] && break
    sleep 0.1
  done

  rc=0
  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --lock-file "$LOCK" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "ロック競合のskipメッセージが出る" "$out" "排他ロックを取得できません"
  n_reports="$(ls "$OUT"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "ロック競合中はレポートも作られない" "0" "$n_reports"

  wait "$holder_pid" 2>/dev/null
  rm -rf "$VAULT" "$OUT" "$LOCK_DIR" 2>/dev/null
}

echo "=== 15b. --json指定時、state.json排他ロック競合のskipメッセージは標準出力に混入しない(Codexレビュー指摘Minor対応) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/lock-json-a.md" "t" "" ""
  # Codexレビュー指摘Critical対応（テスト15と同じ理由。共有一時ディレクトリの
  # 誤削除を避けるため、ロック専用ディレクトリを個別に持つ）。
  LOCK_DIR="$(mktemp -d)"
  LOCK="$LOCK_DIR/vault-merge.lock"
  READY="$LOCK_DIR/ready"

  # テスト15と同じくREADYファイルでロック取得完了を待つ（Codexレビュー指摘
  # Minor対応・固定sleepのタイミング依存を解消）。
  python3 -c "
import fcntl, os, time, pathlib
p = pathlib.Path('$LOCK')
p.parent.mkdir(parents=True, exist_ok=True)
fd = os.open(str(p), os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
pathlib.Path('$READY').write_text('1', encoding='utf-8')
time.sleep(3)
" &
  holder_pid=$!
  for _ in $(seq 1 50); do
    [ -f "$READY" ] && break
    sleep 0.1
  done

  rc=0
  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --lock-file "$LOCK" --json 2>/dev/null)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "--json指定時、ロック競合のskipメッセージは標準出力に一切出ない(空)" "" "$stdout_out"

  wait "$holder_pid" 2>/dev/null
  rm -rf "$VAULT" "$OUT" "$LOCK_DIR" 2>/dev/null
}

echo "=== 15c. --json指定時、state.json破損のskipメッセージは標準出力に混入しない(Codexレビュー指摘Minor対応) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/state-corrupt-a.md" "t" "" ""
  echo "not valid json {{{" > "$OUT/state.json"

  rc=0
  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "--json指定時、state.json破損のskipメッセージは標準出力に一切出ない(空)" "" "$stdout_out"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 16. --sim-thresholdが不正値(NaN等)なら既定値へフォールバックする(クラッシュしない) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/nanthresh-a.md" "t" "" ""

  rc=0
  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold nan 2>&1)" || rc=$?
  assert_eq "exit code 0（クラッシュしない）" "0" "$rc"
  assert_contains "不正値フォールバックの警告が出る" "$out" "既定値"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 17. VAULT_MERGE_SIM_THRESHOLD環境変数が不正でもimport時にクラッシュしない ==="
{
  out="$(VAULT_MERGE_SIM_THRESHOLD="not-a-number" python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.DEFAULT_SIM_THRESHOLD)
" 2>&1)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "既定値0.35にフォールバックする" "0.35" "$out"
}

echo "=== 17b. VAULT_MERGE_SIM_THRESHOLD環境変数が範囲外([0,1]外)でもフォールバックする ==="
{
  out="$(VAULT_MERGE_SIM_THRESHOLD="2.0" python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.DEFAULT_SIM_THRESHOLD)
" 2>&1)"
  assert_eq "範囲外(2.0)の環境変数は既定値0.35にフォールバックする" "0.35" "$out"
}

echo "=== 18. 候補IDはsha256の全桁(64 hex文字)を使う(衝突耐性) ==="
{
  id_len="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
cid = kmc.stable_pair_id('Knowledge/a.md', 'Knowledge/b.md')
print(len(cid) - len('cand-'))
")"
  assert_eq "cand-prefixの後ろは64文字" "64" "$id_len"
}

echo "=== 19. note_similarity: 重み(0.4/0.3/0.2/0.1)どおりに各カテゴリが合成される ==="
{
  out="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
fa = {'aliases': {'x'}, 'title': set(), 'tags': set(), 'links': set()}
fb = {'aliases': {'x'}, 'title': set(), 'tags': set(), 'links': set()}
print(kmc.note_similarity(fa, fb))
")"
  assert_eq "aliasesのみ完全一致で類似度0.4" "0.4" "$out"

  out2="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
fa = {'aliases': set(), 'title': {'x'}, 'tags': set(), 'links': set()}
fb = {'aliases': set(), 'title': {'x'}, 'tags': set(), 'links': set()}
print(kmc.note_similarity(fa, fb))
")"
  assert_eq "タイトルトークンのみ完全一致で類似度0.3" "0.3" "$out2"

  out3="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
fa = {'aliases': set(), 'title': set(), 'tags': {'x'}, 'links': set()}
fb = {'aliases': set(), 'title': set(), 'tags': {'x'}, 'links': set()}
print(kmc.note_similarity(fa, fb))
")"
  assert_eq "タグのみ完全一致で類似度0.2" "0.2" "$out3"

  out4="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
fa = {'aliases': set(), 'title': set(), 'tags': set(), 'links': {'x'}}
fb = {'aliases': set(), 'title': set(), 'tags': set(), 'links': {'x'}}
print(kmc.note_similarity(fa, fb))
")"
  assert_eq "outbound linksのみ完全一致で類似度0.1" "0.1" "$out4"

  out5="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
fa = {'aliases': set(), 'title': set(), 'tags': set(), 'links': set()}
fb = {'aliases': set(), 'title': set(), 'tags': set(), 'links': set()}
print(kmc.note_similarity(fa, fb))
")"
  assert_eq "全カテゴリ空同士は無関係として類似度0.0(高類似度に誤判定しない)" "0.0" "$out5"
}

echo "=== 20. note_features: aliases/タグ/リンクをfrontmatter・本文から正しく抽出する ==="
{
  VAULT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/feat-test.md" "tag1 tag2" "Knowledge/target" "alias1"
  out="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
f = kmc.note_features('$VAULT', 'Knowledge/feat-test.md')
print(sorted(f['aliases']))
print(sorted(f['tags']))
print(sorted(f['links']))
print(sorted(f['title']))
")"
  assert_contains "aliasesが抽出される" "$out" "alias1"
  assert_contains "tagsが抽出される" "$out" "tag1"
  assert_contains "tagsが2件とも抽出される" "$out" "tag2"
  # resolver未指定時はfail-openで生文字列を小文字化しただけの値になる
  # （build_index()経由の実運用パスはby_full/by_baseを渡すため大小文字ゆれ・
  # 短縮リンク/フルパス表記も正規化される＝後続テスト参照）。
  assert_contains "outbound linksが抽出される(resolver無指定はlowercaseのみ)" "$out" "knowledge/target"
  assert_contains "titleトークンが抽出される" "$out" "feat"

  rm -rf "$VAULT"
}

echo "=== 21. --json: 標準出力はJSON1行のみ・candidatesを含む ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/json-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/json-b.md" "shared-tag" "" ""

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/tmp/kmc-test-stderr.log)"
  rc=0
  echo "$stdout_out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['n_candidates']==1" || rc=$?
  assert_eq "標準出力はJSONとしてパースでき候補数も一致する" "0" "$rc"
  stderr_out="$(cat /tmp/kmc-test-stderr.log)"
  assert_contains "人間向けメッセージは標準エラーに出る" "$stderr_out" "レポート生成:"

  rm -f /tmp/kmc-test-stderr.log
  rm -rf "$VAULT" "$OUT"
}

echo "=== 21b. --json: candidatesに両ノートの全文＋SHA-256が正しい対応関係で含まれる(設計書§2.2「マージ候補2ノートの全文＋各SHA-256を含める」) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/text-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/text-b.md" "shared-tag" "" ""

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  # note_a/note_bのどちらがtext-a.md/text-b.mdになるかは実装依存(sorted等)のため、
  # 「rec['note_a']が指すファイルの実際の内容・sha256がnote_a_text/note_a_sha256と
  # 一致する」という対応関係そのものを検証する（2026-07-16 Codexレビュー指摘Minor
  # 対応: 当初は「どちらか一致すればOK」という緩い検証で、note_aとnote_bの中身が
  # 入れ替わっていても検出できなかった）。
  info="$(printf '%s' "$stdout_out" | python3 -c "
import json, sys, hashlib, pathlib
d = json.load(sys.stdin)
c = d['candidates'][0]
print('id' in c)
vault = pathlib.Path('$VAULT')
real_text_a = (vault / c['note_a']).read_text()
real_text_b = (vault / c['note_b']).read_text()
print(c['note_a_text'] == real_text_a)
print(c['note_b_text'] == real_text_b)
print(c['note_a_sha256'] == hashlib.sha256(real_text_a.encode('utf-8')).hexdigest())
print(c['note_b_sha256'] == hashlib.sha256(real_text_b.encode('utf-8')).hexdigest())
")"
  has_id="$(echo "$info" | sed -n '1p')"
  text_a_match="$(echo "$info" | sed -n '2p')"
  text_b_match="$(echo "$info" | sed -n '3p')"
  sha_a_match="$(echo "$info" | sed -n '4p')"
  sha_b_match="$(echo "$info" | sed -n '5p')"
  assert_eq "候補レコードにidフィールドがある" "True" "$has_id"
  assert_eq "note_a_textはrec['note_a']が指すファイルの実際の内容と一致する" "True" "$text_a_match"
  assert_eq "note_b_textはrec['note_b']が指すファイルの実際の内容と一致する" "True" "$text_b_match"
  assert_eq "note_a_sha256はnote_a_textから計算したsha256と一致する" "True" "$sha_a_match"
  assert_eq "note_b_sha256はnote_b_textから計算したsha256と一致する" "True" "$sha_b_match"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 21c. --json: 「両ノート合計」で8,000字判定される(各ノート単体では超えない場合でも合計超過ならtruncated・境界値も検証) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  # 各ノート単体は8,000字未満だが合計は超える(4500+4500=9000>8000)組み合わせ。
  # これにより「各ノート単体で8,000字」ではなく「両ノート合計で8,000字」判定
  # であることを直接証明する（2026-07-16 Codexレビュー指摘Minor対応: 当初の
  # テストは片方だけ9,000字にしており、単体判定でも合計判定でも同じ結果になり
  # 判定方法自体を証明できていなかった）。
  {
    echo "---"; echo "date: 2026-01-01"; echo "tags: [shared-tag]"; echo "---"; echo
    python3 -c "print('あ' * 4500)"
  } > "$VAULT/Knowledge/combined-a.md"
  {
    echo "---"; echo "date: 2026-01-01"; echo "tags: [shared-tag]"; echo "---"; echo
    python3 -c "print('い' * 4500)"
  } > "$VAULT/Knowledge/combined-b.md"

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  info="$(printf '%s' "$stdout_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d['candidates']))
print(len(d['candidates_truncated']))
tc = d['candidates_truncated'][0]
print(tc['non_actionable'])
print('note_a_text' not in tc and 'note_b_text' not in tc)
print(tc['combined_chars'] > 8000)
print(d['n_candidates'])
")"
  n_candidates_list="$(echo "$info" | sed -n '1p')"
  n_truncated="$(echo "$info" | sed -n '2p')"
  non_actionable="$(echo "$info" | sed -n '3p')"
  no_text_in_truncated="$(echo "$info" | sed -n '4p')"
  combined_over="$(echo "$info" | sed -n '5p')"
  n_candidates_field="$(echo "$info" | sed -n '6p')"
  assert_eq "各ノート単体は4,500字(8,000字未満)でも合計超過でtruncatedになる(合計判定の証明)" "0" "$n_candidates_list"
  assert_eq "candidates_truncatedに1件入る" "1" "$n_truncated"
  assert_eq "non_actionableフィールドはtruncated" "truncated" "$non_actionable"
  assert_eq "truncated側には本文テキストを含めない(JSON肥大化防止・Codexレビュー指摘Minor対応)" "True" "$no_text_in_truncated"
  assert_eq "combined_charsは実際に8,000字を超えている" "True" "$combined_over"
  assert_eq "n_candidatesはtruncated分を含まない(actionableのみ)" "0" "$n_candidates_field"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 21c2. --json: 8,000字ちょうどはtruncatedにならず、8,001字はtruncatedになる(境界値) ==="
{
  # write_note()はfrontmatter+空行+本文という構造のため、正確な合計文字数を
  # 得るには本文サイズを実測してから調整する。
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge"
  make_note_with_body_chars() {
    local path="$1" n="$2"
    { echo "---"; echo "date: 2026-01-01"; echo "tags: [shared-tag]"; echo "---"; echo -n ""; python3 -c "import sys; sys.stdout.write('あ' * $n)"; } > "$path"
  }

  measure_total_chars() {
    python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
t1 = open('$1').read()
t2 = open('$2').read()
print(len(t1) + len(t2))
"
  }

  # ちょうど8,000字になるよう本文サイズを調整する。
  make_note_with_body_chars "$VAULT/Knowledge/exact-a.md" 10
  make_note_with_body_chars "$VAULT/Knowledge/exact-b.md" 10
  total="$(measure_total_chars "$VAULT/Knowledge/exact-a.md" "$VAULT/Knowledge/exact-b.md")"
  # 差分をnote-bへ追加してちょうど8,000字に合わせる。
  diff_n=$((8000 - total))
  python3 -c "
import sys
sys.stdout = open('$VAULT/Knowledge/exact-b.md', 'a')
sys.stdout.write('あ' * $diff_n)
"
  total_check="$(measure_total_chars "$VAULT/Knowledge/exact-a.md" "$VAULT/Knowledge/exact-b.md")"
  assert_eq "テスト前提: 合計をちょうど8,000字に調整できている" "8000" "$total_check"

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  n_at_boundary="$(printf '%s' "$stdout_out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "ちょうど8,000字はtruncatedにならない(超過のみtruncated・>8000)" "1" "$n_at_boundary"
  rm -rf "$OUT"

  # 1字追加して8,001字にする。
  OUT="$(mktemp -d)"
  python3 -c "
sys_stdout = open('$VAULT/Knowledge/exact-b.md', 'a')
sys_stdout.write('あ')
"
  stdout_out2="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  n_over_boundary="$(printf '%s' "$stdout_out2" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['candidates']))")"
  assert_eq "8,001字はtruncatedになる" "0" "$n_over_boundary"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 21d. --json: 候補の一方のノートが検出後にVaultから削除されていた場合、今回のJSON出力からは除外する(fail-open・state.jsonは変更しない) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/gone-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/gone-b.md" "shared-tag" "" ""

  # 1回目: 通常どおり候補を検出させ、state.jsonへpendingとして記録させる。
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json >/dev/null 2>&1
  cp "$OUT/state.json" "$OUT/state-before.json"

  # 検出後にVaultから一方のノートが削除された状況を模擬する。
  rm -f "$VAULT/Knowledge/gone-a.md"

  # 2回目:で即時再実行し、JSON出力を確認する（state.json上はまだpending
  # のはずだが、ノート実体が無いため--json出力からは除外されるべき）。
  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>"$OUT/stderr.log")"
  n_candidates="$(printf '%s' "$stdout_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['n_candidates'])")"
  assert_eq "読込失敗ノートを含む候補はJSON出力から除外される" "0" "$n_candidates"
  assert_contains "FACTログで除外理由が分かる" "$(cat "$OUT/stderr.log")" "ノート読込に失敗したため今回のJSON出力から"

  # state.json自体の候補レコード(status/similarity等)は変更されていないこと
  # （＝次回実行時に自然に再検出される）を検証する（2026-07-16 Codexレビュー
  # 指摘Minor対応。ファイル同士をPythonへ直接読ませ、シェル変数へJSON文字列を
  # 埋め込まない＝内容にクォート等が含まれても壊れない安全な比較方法にする）。
  candidates_unchanged="$(python3 -c "
import json
before = json.load(open('$OUT/state-before.json'))['candidates']
after = json.load(open('$OUT/state.json'))['candidates']
print(before == after)
")"
  assert_eq "state.jsonのcandidatesは書込前後で不変(pendingのまま)" "True" "$candidates_unchanged"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 21e. --json: 検出後にノートがsymlinkへ差し替えられていた場合、Vault外の内容を送信せず今回のJSON出力から除外する(Codexレビュー指摘Major対応) ==="
{
  OUTER="$(mktemp -d)"
  VAULT="$OUTER/vault"
  mkdir -p "$VAULT/Knowledge"
  OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/sym-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/sym-b.md" "shared-tag" "" ""

  # 1回目: 通常どおり候補を検出させる。
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json >/dev/null 2>&1

  # 検出後、Vault外の秘密ファイルを指すsymlinkへ差し替える(多層防御の検証)。
  echo "SECRET: Vault外の内容" > "$OUTER/secret.md"
  rm -f "$VAULT/Knowledge/sym-a.md"
  ln -s "$OUTER/secret.md" "$VAULT/Knowledge/sym-a.md"

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  info="$(printf '%s' "$stdout_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['n_candidates'])
all_text = json.dumps(d)
print('SECRET' in all_text)
")"
  n_candidates="$(echo "$info" | sed -n '1p')"
  secret_leaked="$(echo "$info" | sed -n '2p')"
  assert_eq "symlinkへ差し替えられた候補はJSON出力から除外される" "0" "$n_candidates"
  assert_eq "Vault外ファイルの内容がJSON出力に含まれていない" "False" "$secret_leaked"

  rm -rf "$OUTER" "$OUT"
}

echo "=== 21f. --json: 検出後にノートがdeprecated:trueになっていた場合(既にstub化済み)、今回のJSON出力から除外する(Codexレビュー指摘Major対応) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/dep-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/dep-b.md" "shared-tag" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json >/dev/null 2>&1

  # 検出後、一方が別経路(例えば別のマージ)で既にstub化されたと仮定する。
  cat > "$VAULT/Knowledge/dep-a.md" <<'EOF'
---
date: 2026-01-01
deprecated: true
superseded_by: "[[Knowledge/other-merged]]"
---
このノートは統合されました。
EOF

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  n_candidates="$(printf '%s' "$stdout_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['n_candidates'])")"
  assert_eq "deprecated化された候補はJSON出力から除外される" "0" "$n_candidates"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 21g. --json: state.jsonが破損/改ざんされ相対パスに'..'が混入していても、Vault外へは一切出ずJSON出力から除外される(Codexレビュー4巡目指摘Major対応) ==="
{
  OUTER="$(mktemp -d)"
  VAULT="$OUTER/vault"
  mkdir -p "$VAULT/Knowledge"
  OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/legit-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/legit-b.md" "shared-tag" "" ""

  # 通常どおり検出させ、state.jsonへ候補を記録させる。
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json >/dev/null 2>&1
  cid="$(state_ids "$OUT/state.json" candidates)"

  # Vault外に秘密ファイルを置き、state.jsonのnote_aを'..'越境パスへ直接改ざんする
  # （is_active_note()単体では相対パスのVault境界を検証していなかったため、
  # 通常ファイルでありさえすれば通過してしまっていた欠陥の回帰テスト）。
  echo "SECRET: Vault外の内容(state.json改ざん経路)" > "$OUTER/secret2.md"
  python3 -c "
import json
p = '$OUT/state.json'
d = json.load(open(p))
d['candidates']['$cid']['note_a'] = '../secret2.md'
json.dump(d, open(p, 'w'))
"

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  info="$(printf '%s' "$stdout_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['n_candidates'])
print('SECRET' in json.dumps(d))
")"
  n_candidates="$(echo "$info" | sed -n '1p')"
  secret_leaked="$(echo "$info" | sed -n '2p')"
  assert_eq "'..'越境パスへ改ざんされた候補はJSON出力から除外される" "0" "$n_candidates"
  assert_eq "Vault外ファイル(secret2.md)の内容はJSON出力に含まれない" "False" "$secret_leaked"

  rm -rf "$OUTER" "$OUT"
}

echo "=== 21h. _read_note_text_or_none: 単体テスト(境界チェック・O_NOFOLLOWによるsymlink拒否・通常ファイルの正常読込) ==="
{
  # このファイルには共通run_py()ヘルパーが無いため(他テストはpython3 -cを都度
  # インラインで書く慣習)、ここだけ小さなラッパーをローカル定義して使う。
  run_py_kmc() {
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
$1
"
  }

  OUTER="$(mktemp -d)"
  VAULT="$OUTER/vault"
  mkdir -p "$VAULT/Knowledge"

  # 正常系: 通常のVault内ファイルは読める。
  printf -- '---\ndate: 2026-01-01\n---\n本文\n' > "$VAULT/Knowledge/normal.md"
  out_normal="$(run_py_kmc "
print(kmc._read_note_text_or_none('$VAULT', 'Knowledge/normal.md') is not None)
")"
  assert_eq "通常ファイルは読める" "True" "$out_normal"

  # '..'越境: Vault外への相対パスは拒否する。
  echo "outside" > "$OUTER/outside.md"
  out_traversal="$(run_py_kmc "
print(kmc._read_note_text_or_none('$VAULT', '../outside.md'))
")"
  assert_eq "'..'越境パスはNoneを返す(拒否)" "None" "$out_traversal"

  # symlink: O_NOFOLLOWで拒否する(中身がVault内の正当なノートと同じ内容でも)。
  ln -s "$OUTER/outside.md" "$VAULT/Knowledge/symlinked.md"
  out_symlink="$(run_py_kmc "
print(kmc._read_note_text_or_none('$VAULT', 'Knowledge/symlinked.md'))
")"
  assert_eq "symlinkはO_NOFOLLOWで拒否されNoneを返す" "None" "$out_symlink"

  # 存在しないファイル: Noneを返す。
  out_missing="$(run_py_kmc "
print(kmc._read_note_text_or_none('$VAULT', 'Knowledge/does-not-exist.md'))
")"
  assert_eq "存在しないファイルはNoneを返す" "None" "$out_missing"

  # deprecated:true: Noneを返す。
  printf -- '---\ndate: 2026-01-01\ndeprecated: true\n---\n本文\n' > "$VAULT/Knowledge/deprecated.md"
  out_deprecated="$(run_py_kmc "
print(kmc._read_note_text_or_none('$VAULT', 'Knowledge/deprecated.md'))
")"
  assert_eq "deprecated:trueのノートはNoneを返す" "None" "$out_deprecated"

  rm -rf "$OUTER"
}

echo "=== 21i. --json: state.jsonが改ざんされKnowledge以外(例: Personal)のノートを指すようになっていても、フォルダ制約違反として除外される(Codexレビュー5巡目指摘Major対応・is_active_note系のVault境界検証だけでは防げなかった経路) ==="
{
  VAULT="$(mktemp -d)"
  mkdir -p "$VAULT/Knowledge" "$VAULT/Personal"
  OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/folder-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/folder-b.md" "shared-tag" "" ""
  # Personal配下に実在する正当なノートを用意する(symlinkでもVault外でもない・
  # is_active_note系のチェックだけでは正当と判定されてしまう)。
  write_note "$VAULT" "Personal/private-note.md" "" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json >/dev/null 2>&1
  cid="$(state_ids "$OUT/state.json" candidates)"

  # note_bをPersonal配下の実在ノートへ差し替える（folderフィールドはKnowledgeの
  # ままにする＝「パスだけ差し替えてfolderフィールドは更新し忘れた」改ざんを模擬。
  # note_a/note_bとfolderの整合性検証・cidとの整合性検証の両方が効くことを見る）。
  python3 -c "
import json
p = '$OUT/state.json'
d = json.load(open(p))
d['candidates']['$cid']['note_b'] = 'Personal/private-note.md'
json.dump(d, open(p, 'w'))
"

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  info="$(printf '%s' "$stdout_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['n_candidates'])
print('private-note' in json.dumps(d))
")"
  n_candidates="$(echo "$info" | sed -n '1p')"
  leaked="$(echo "$info" | sed -n '2p')"
  assert_eq "Personal配下を指すよう改ざんされた候補は除外される" "0" "$n_candidates"
  assert_eq "Personal配下ノートの内容(パス文字列含む)がJSON出力に含まれない" "False" "$leaked"

  rm -rf "$VAULT" "$OUT"
}

echo "=== 21j. _candidate_record_is_valid_for_enrichment: 単体テスト(folder制約・note_a=note_b拒否・cid不整合拒否・正当なレコードは通る) ==="
{
  run_py_kmc2() {
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
$1
"
  }

  out_folder="$(run_py_kmc2 "
rec = {'folder': 'Personal', 'note_a': 'Personal/a.md', 'note_b': 'Personal/b.md'}
cid = kmc.stable_pair_id(rec['note_a'], rec['note_b'])
print(kmc._candidate_record_is_valid_for_enrichment(cid, rec))
")"
  assert_eq "folder=Personal(Knowledge以外)は拒否される" "False" "$out_folder"

  out_same="$(run_py_kmc2 "
rec = {'folder': 'Knowledge', 'note_a': 'Knowledge/a.md', 'note_b': 'Knowledge/a.md'}
cid = kmc.stable_pair_id(rec['note_a'], rec['note_b'])
print(kmc._candidate_record_is_valid_for_enrichment(cid, rec))
")"
  assert_eq "note_a==note_bは拒否される" "False" "$out_same"

  out_mismatch="$(run_py_kmc2 "
rec = {'folder': 'Knowledge', 'note_a': 'Knowledge/a.md', 'note_b': 'Knowledge/b.md'}
wrong_cid = 'cand-' + ('0' * 64)
print(kmc._candidate_record_is_valid_for_enrichment(wrong_cid, rec))
")"
  assert_eq "cidがnote_a/note_bの再計算値と一致しなければ拒否される" "False" "$out_mismatch"

  out_folder_mismatch="$(run_py_kmc2 "
rec = {'folder': 'Knowledge', 'note_a': 'Knowledge/a.md', 'note_b': 'Personal/b.md'}
cid = kmc.stable_pair_id(rec['note_a'], rec['note_b'])
print(kmc._candidate_record_is_valid_for_enrichment(cid, rec))
")"
  assert_eq "note_bの実フォルダがfolderフィールドと食い違えば拒否される" "False" "$out_folder_mismatch"

  out_valid="$(run_py_kmc2 "
rec = {'folder': 'Knowledge', 'note_a': 'Knowledge/a.md', 'note_b': 'Knowledge/b.md'}
cid = kmc.stable_pair_id(rec['note_a'], rec['note_b'])
print(kmc._candidate_record_is_valid_for_enrichment(cid, rec))
")"
  assert_eq "正当なKnowledge同フォルダ・cid整合のレコードは通る" "True" "$out_valid"
}

echo "=== 21k. --json: note_a/note_bとcidの両方を一貫して改ざんしても(traversal/サブディレクトリ/README.md)、直下1階層の正規形チェックで除外される(Codexレビュー6巡目指摘Major対応: cid整合性検証だけでは防げなかった経路) ==="
{
  OUTER="$(mktemp -d)"
  VAULT="$OUTER/vault"
  mkdir -p "$VAULT/Knowledge" "$VAULT/Personal"
  OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/base-a.md" "shared-tag" "" ""
  write_note "$VAULT" "Knowledge/base-b.md" "shared-tag" "" ""
  write_note "$VAULT" "Personal/private-note2.md" "" "" ""
  mkdir -p "$VAULT/Knowledge/sub"
  write_note "$VAULT" "Knowledge/sub/nested.md" "" "" ""

  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json >/dev/null 2>&1

  # note_bを「Knowledge/../Personal/private-note2.md」（traversal経由でPersonal
  # を指す）へ差し替え、かつcid（stateのキー）もstable_pair_id()の再計算値へ
  # 一貫して更新する（＝cid整合性検証『だけ』では防げない改ざんを模擬。
  # 21iはcidを更新しない改ざんだったため、この経路は21iでは検出できていなかった）。
  python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
import json
p = '$OUT/state.json'
d = json.load(open(p))
old_cid = list(d['candidates'].keys())[0]
rec = d['candidates'].pop(old_cid)
rec['note_b'] = 'Knowledge/../Personal/private-note2.md'
new_cid = kmc.stable_pair_id(rec['note_a'], rec['note_b'])
d['candidates'][new_cid] = rec
json.dump(d, open(p, 'w'))
"
  # base-a.md/base-b.mdの本来のペアが2回目の実行で再検出され、正当な新規候補
  # として別途追加されると(それ自体は正しい挙動)、本テストの主眼である
  # 「改ざんされた候補が除外されること」の検証がn_candidatesの単純比較では
  # 埋もれてしまう。base-b.mdを削除して再検出されないようにし、改ざんされた
  # 候補だけが対象になる状況を作る。
  rm -f "$VAULT/Knowledge/base-b.md"

  stdout_out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.1 --json 2>/dev/null)"
  info="$(printf '%s' "$stdout_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['n_candidates'])
print('private-note2' in json.dumps(d))
")"
  n_candidates="$(echo "$info" | sed -n '1p')"
  leaked="$(echo "$info" | sed -n '2p')"
  assert_eq "cidも一貫して更新されたtraversal改ざんも除外される" "0" "$n_candidates"
  assert_eq "Vault外相当(Personal)ノートの内容がJSON出力に含まれない" "False" "$leaked"

  rm -rf "$OUTER" "$OUT"
}

echo "=== 21l. _is_direct_merge_eligible_note: 単体テスト(直下1階層のみ許可・サブディレクトリ/traversal/README.md/非.mdを拒否) ==="
{
  run_py_kmc3() {
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
$1
"
  }

  out1="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Knowledge/foo.md'))")"
  assert_eq "Knowledge直下の.mdは許可される" "True" "$out1"

  out2="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Knowledge/sub/a.md'))")"
  assert_eq "サブディレクトリは拒否される" "False" "$out2"

  out3="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Knowledge/../Personal/private.md'))")"
  assert_eq "'..'によるtraversalは拒否される(partsの要素数が2にならないため)" "False" "$out3"

  out4="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Knowledge/README.md'))")"
  assert_eq "README.mdは拒否される(索引ファイルでありマージ対象ではない)" "False" "$out4"

  out5="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Knowledge/foo.txt'))")"
  assert_eq ".md以外は拒否される" "False" "$out5"

  out6="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Personal/foo.md'))")"
  assert_eq "MERGE_ELIGIBLE_FOLDERS(Knowledge)以外のフォルダは拒否される" "False" "$out6"

  out7="$(run_py_kmc3 "print(kmc._is_direct_merge_eligible_note('Knowledge//foo.md'))")"
  assert_eq "冗長な区切り(二重スラッシュ)は正規形と不一致のため拒否される" "False" "$out7"
}

echo "=== 22. extract_tags: scalar形式(tags: foo)・#tag表記もリスト形式と同一視する(Codexレビュー指摘対応) ==="
{
  out="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(sorted(kmc.extract_tags({'tags': 'foo'})))
print(sorted(kmc.extract_tags({'tags': ['#foo', 'Bar']})))
print(sorted(kmc.extract_tags({'tags': 42})))
print(sorted(kmc.extract_tags({})))
")"
  assert_contains "scalar文字列tagsが1要素として抽出される" "$out" "['foo']"
  assert_contains "リスト内の#tag表記は#を除いて小文字化される" "$out" "['bar', 'foo']"
  assert_contains "数値等の壊れた値は空集合にfail-openする" "$out" "[]"
}

echo "=== 23. build_link_resolver/extract_outbound_links: 短縮リンク・フルパス・.md付き・大文字小文字ゆれが同じ正規relpathへ解決される ==="
{
  resolved_out="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
notes = [{'relpath': 'Knowledge/Target-Note.md'}, {'relpath': 'Knowledge/other.md'}]
by_full, by_base = kmc.build_link_resolver(notes)
# 表記ゆれ4種が全て同じ正規relpathへ解決されることを確認する。
forms = ['target-note', 'Knowledge/Target-Note', 'Knowledge/Target-Note.md', 'TARGET-NOTE']
resolved = {kmc.resolve_link_target(f, by_full, by_base) for f in forms}
print(len(resolved), sorted(resolved))
")"
  assert_contains "4種の表記ゆれが単一の正規relpathへ解決される" "$resolved_out" "1 ['Knowledge/Target-Note']"

  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  # aが短縮リンク・bがフルパス+.md付きリンクで同じtargetノートを指す。
  # target自体は候補外(links側の重みだけを見るため他ノートと無関係な語にする)。
  write_note "$VAULT" "Knowledge/hub.md" "" "" ""
  write_note "$VAULT" "Knowledge/left.md" "" "hub" ""
  write_note "$VAULT" "Knowledge/right.md" "" "Knowledge/hub.md" ""
  out="$(run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.05)"
  cid="$(state_ids "$OUT/state.json" candidates)"
  n_cand="$(echo "$cid" | wc -w | tr -d ' ')"
  assert_eq "短縮形/フルパス.md付きの表記ゆれでもoutbound linkが一致し候補が出る" "1" "$n_cand"
  rm -rf "$VAULT" "$OUT"
}

echo "=== 24. build_index: SCAN_DIRS直下1階層のみを走査する(サブディレクトリは対象外・Codexレビュー指摘Major対応) ==="
{
  VAULT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/top-level.md" "" "" ""
  write_note "$VAULT" "Knowledge/nested/sub-note.md" "" "" ""
  write_note "$VAULT" "Knowledge/README.md" "" "" ""
  out="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
idx = kmc.build_index('$VAULT')
print(len(idx), sorted(n['relpath'] for n in idx.notes))
")"
  assert_contains "直下1階層のノートのみ列挙される(サブディレクトリは除外)" "$out" "['Knowledge/top-level.md']"
  assert_contains "NoteIndex.__len__()が件数を返す" "$out" "1 "
  rm -rf "$VAULT"
}

echo "=== 25. collect_active_features: 非アクティブ(deprecated/symlink)ノートは特徴量読取そのものが行われない ==="
{
  VAULT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/active-one.md" "" "" ""
  write_note "$VAULT" "Knowledge/active-two.md" "" "" ""
  # deprecated: true のノート本文に、意図的に読み取れば例外になる無効UTF-8バイト列を仕込む。
  # collect_active_features()がis_active_note()の非アクティブ判定を先に行い、この
  # ノートを一切読み取らないことを検証する（Codexレビュー指摘Minor対応）。
  {
    echo "---"
    echo "date: 2026-01-01"
    echo "deprecated: true"
    echo "---"
  } > "$VAULT/Knowledge/deprecated-broken.md"
  printf '\xff\xfe invalid utf-8 tail' >> "$VAULT/Knowledge/deprecated-broken.md"
  out="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
idx = kmc.build_index('$VAULT')
active, features = kmc.collect_active_features(idx, '$VAULT')
active_relpaths = sorted(idx.notes[i]['relpath'] for i in active)
print(active_relpaths)
")"
  assert_contains "deprecatedノートはactiveから除外され例外も起きない" "$out" "['Knowledge/active-one.md', 'Knowledge/active-two.md']"
  rm -rf "$VAULT"
}

echo "=== 26. note_features/is_active_note: 非UTF-8ファイルでもUnicodeDecodeErrorでCLI全体が落ちない(fail-open) ==="
{
  VAULT="$(mktemp -d)"; OUT="$(mktemp -d)"
  write_note "$VAULT" "Knowledge/normal-one.md" "" "" ""
  write_note "$VAULT" "Knowledge/normal-two.md" "" "" ""
  mkdir -p "$VAULT/Knowledge"
  printf '\xff\xfe\x00\x01broken binary content' > "$VAULT/Knowledge/broken-binary.md"
  rc=0
  run_kmc --vault "$VAULT" --out-dir "$OUT" --sim-threshold 0.5 >/tmp/kmc-test-26.log 2>&1 || rc=$?
  assert_eq "非UTF-8ノートが混在してもCLIは例外終了しない(exit 0)" "0" "$rc"
  rm -f /tmp/kmc-test-26.log
  rm -rf "$VAULT" "$OUT"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
