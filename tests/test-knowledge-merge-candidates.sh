#!/usr/bin/env bash
# scripts/vault-agents/knowledge_merge_candidates.py のユニットテスト
# （外部脳Knowledge自律整理・柱②「検出」専用CLI。LLM不使用・決定的処理のみ）。
#
# 実Ollama・実ネットワークには一切依存しない（knowledge_merge_candidates.py自体が
# インデックスを読むだけでOllama通信を行わないため）。埋め込みインデックスの
# フィクスチャは tests/build_fixture_index.py で既知のベクトル値を直接注入して
# 構築する（cosine類似度・閾値境界・同点タイを決定的に再現するため）。
# 実 $HOME/.claude/logs・実Vaultには依存しない（毎回tempディレクトリへ--vault/
# --index-dir/--out-dirを向ける）。
#
# 実行方法: bash tests/test-knowledge-merge-candidates.sh

set -uo pipefail

# 実HOME配下（~/.claude/tmp/vault-merge.lock等）への書込を構造的に不可能にする
# （2026-07-12 実インシデント対応: 本テストのrun_kmc呼出しの大半が--lock-file
# を明示指定しておらず、knowledge_merge_candidates.pyの既定値DEFAULT_LOCK_FILE
# （pathlib.Path.home()ベース＝knowledge_merge.pyと共有する実運用中の本物の
# lockファイル）へ実際にflockする経路が残っていたことが監査で判明した。
# 個々の呼出しへの引数指定漏れに頼らず、テストプロセス全体のHOMEを隔離する
# ことで「デフォルトパスへ書けと指定し忘れても実環境には書けない」構造にする
# ＝正本ルール: 実環境テストはsandbox/temp HOMEで隔離（Vault: Knowledge/mistakes.md）。
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vault-agents/knowledge_merge_candidates.py"
BUILD_INDEX="$TESTS_DIR/build_fixture_index.py"

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

# $1=vault $2=idx $3=spec(JSON文字列)
build_index() {
  local vault="$1" idx="$2" spec="$3" specfile
  specfile="$(mktemp)"
  printf '%s' "$spec" > "$specfile"
  python3 "$BUILD_INDEX" --vault "$vault" --idx "$idx" --spec-file "$specfile" >/dev/null
  rm -f "$specfile"
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

# N日前/後のYYYY-MM-DD（BSD date。tests/test-check-drift.shと同じ考え方）。
d_date() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -v"${n}"d +%F; }

# インデックス内のノート0番・1番の実際のcosine類似度を返す（float32格納の丸め誤差込みの
# 「実際にランタイムが見る値」を使うことで、閾値境界テストを浮動小数の想定誤差に
# 依存させない）。
compute_actual_sim() {
  local idx_dir="$1"
  python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import embedding_index as ei
idx = ei.load_index(sys.argv[1], expected_model=None)
print(repr(ei.cosine_similarity(idx.vector(0), idx.vector(1))))
" "$idx_dir"
}

echo "=== 1. Knowledge同フォルダの相互最近傍(mutual top-1)が閾値以上でレビュー待ち候補になる ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 3,
    "notes": {
      "Knowledge/a.md": {"body": "ノートA本文", "vector": [1.0, 0.0, 0.0]},
      "Knowledge/b.md": {"body": "ノートB本文", "vector": [0.99, 0.1411, 0.0]},
      "Knowledge/c.md": {"body": "ノートC本文", "vector": [0.0, 0.0, 1.0]}
    }
  }'

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "レビュー待ち候補1件のログ" "$out" "レビュー待ち候補 1 件"

  report="$(cat "$OUT_DIR"/20*.md)"
  assert_contains "候補a/bが表に載る" "$report" "Knowledge/a"
  assert_not_contains "frontmatterにprocessedが無い(bootstrap/check-drift検知対象のまま)" "$report" "processed:"
  assert_contains "レビュー待ち候補である旨の明記" "$report" "レビュー待ち候補"
  assert_contains "マージ確定ではない旨の明記" "$report" "マージが確定したものではない"

  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "候補は1件のみ(a-b。cはmutual top-1にならない)" "1" "$(echo "$ids" | wc -w | tr -d ' ')"
  status="$(state_field "$OUT_DIR/state.json" candidates "$ids" status)"
  assert_eq "初回状態はpending" "pending" "$status"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 2. 候補IDはノートrelpathペアの正規化から決定的に導出される(順序非依存) ==="
{
  id1="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.stable_pair_id('Knowledge/a.md', 'Knowledge/b.md'))
")"
  id2="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.stable_pair_id('Knowledge/b.md', 'Knowledge/a.md'))
")"
  assert_eq "引数の順序に関わらず同じID" "$id1" "$id2"

  id3="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.stable_pair_id('Knowledge/a.md', 'Knowledge/c.md'))
")"
  if [[ "$id1" != "$id3" ]]; then pass "別ペアは別ID"; else fail_case "別ペアなのに同じIDになっている"; fi
}

echo "=== 3. 相互最近傍でない(片方向のみ最近傍)ペアは候補にならない ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  # 検算: sim(A,B)=0.90・sim(A,C)=0.855・sim(B,C)=0.95（すべて単位ベクトル）。
  # A→Bが最大(0.90)なのでAの最近傍はBだが、Bにとっては sim(B,C)=0.95 > sim(A,B)=0.90
  # のためBの最近傍はC＝(A,B)は片方向のみで相互最近傍が成立しない。
  # 一方(B,C)はB→C・C→Bが相互に成立する＝有効な候補になる（対比のため同一fixtureで検証）。
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 3,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359, 0.0]},
      "Knowledge/c.md": {"body": "C", "vector": [0.855, 0.41411, 0.31225]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 >/dev/null
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "候補は1件のみ(B-C)" "1" "$(echo "$ids" | wc -w | tr -d ' ')"

  id_ab="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.stable_pair_id('Knowledge/a.md', 'Knowledge/b.md'))
")"
  id_bc="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.stable_pair_id('Knowledge/b.md', 'Knowledge/c.md'))
")"
  assert_not_contains "非mutualなA-Bは候補IDに含まれない" "$ids" "$id_ab"
  assert_contains "相互最近傍が成立するB-Cは候補になる" "$ids" "$id_bc"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 4. 類似度閾値の境界: 実測類似度ちょうどなら候補になる(includsive)・僅かに上回る閾値だと候補にならない ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  # float32格納の丸め誤差があるため、ベクトルから理論値(0.8)を仮定せず、
  # 実際にランタイムが計算する値をcompute_actual_sim()で取得してから閾値に使う
  # （境界テストを浮動小数の想定誤差に依存させないため）。
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.8, 0.6]}
    }
  }'
  actual_sim="$(compute_actual_sim "$IDX_DIR")"

  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold "$actual_sim" >/dev/null
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "閾値=実測類似度ちょうどなら候補になる(境界はinclusive)" "1" "$(echo "$ids" | wc -w | tr -d ' ')"
  rm -rf "$OUT_DIR"; OUT_DIR="$(mktemp -d)"

  threshold_above="$(python3 -c "print($actual_sim + 0.0005)")"
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold "$threshold_above" >/dev/null
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "閾値が実測類似度をわずかに上回ると候補にならない" "0" "$(echo "$ids" | wc -w | tr -d ' ')"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 5. 相互最近傍が同点タイの場合は「候補にしない」(FR10a判定が割れた場合のデフォルト) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  # Xに対してY・Zが全く同じ類似度(0.85)でタイ。Y-Z間は閾値未満で無関係。
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 3,
    "notes": {
      "Knowledge/x.md": {"body": "X", "vector": [1.0, 0.0, 0.0]},
      "Knowledge/y.md": {"body": "Y", "vector": [0.85, 0.5268, 0.0]},
      "Knowledge/z.md": {"body": "Z", "vector": [0.85, -0.5268, 0.0]}
    }
  }'
  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "タイの場合は候補0件" "0" "$(echo "$ids" | wc -w | tr -d ' ')"
  det_ids="$(state_ids "$OUT_DIR/state.json" detections)"
  assert_eq "検出ログにも載らない(Xのタイにより判定不能なため)" "0" "$(echo "$det_ids" | wc -w | tr -d ' ')"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 6. マージ対象はKnowledge同フォルダのみ: Preferences同フォルダは検出ログ扱い(候補にはならない) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Preferences/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Preferences/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.5 >/dev/null
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "Preferences同フォルダはマージ候補にならない" "0" "$(echo "$ids" | wc -w | tr -d ' ')"
  det_ids="$(state_ids "$OUT_DIR/state.json" detections)"
  assert_eq "検出ログ(観測のみ)には載る" "1" "$(echo "$det_ids" | wc -w | tr -d ' ')"
  kind="$(state_field "$OUT_DIR/state.json" detections "$det_ids" kind)"
  assert_eq "種別はsame_folder_other" "same_folder_other" "$kind"

  report="$(cat "$OUT_DIR"/20*.md)"
  assert_contains "検出ログ表にPreferencesペアが載る" "$report" "Preferences/a"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 7. フォルダ横断の相互最近傍はFR9cの検出ログとして集約され、複数週で連続検出回数が増える ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Preferences/b.md": {"body": "B", "vector": [0.95, 0.3122]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  det_ids="$(state_ids "$OUT_DIR/state.json" detections)"
  assert_eq "1件検出される" "1" "$(echo "$det_ids" | wc -w | tr -d ' ')"
  kind="$(state_field "$OUT_DIR/state.json" detections "$det_ids" kind)"
  assert_eq "種別はcross_folder" "cross_folder" "$kind"
  c1="$(state_field "$OUT_DIR/state.json" detections "$det_ids" consecutive_detections)"
  assert_eq "初回は連続検出回数1" "1" "$c1"

  # 同一暦日内の再実行(--force連打)では連続検出回数を水増ししない
  # （Codexレビュー指摘・Major対応: 以前は「実行回数」を数えており、
  # 同日中に2回実行しただけで2にカウントされていた）。
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  c_same_day="$(state_field "$OUT_DIR/state.json" detections "$det_ids" consecutive_detections)"
  assert_eq "同日内の再実行では連続検出回数は増えない" "1" "$c_same_day"

  # 2週目相当をシミュレート: last_seenを「前日」に人為的に書き換え、次回実行で
  # 暦日が進んだ状態を再現する（システム時計を偽装せずに複数週経過を検証する手法）。
  python3 -c "
import json
p = '$OUT_DIR/state.json'
d = json.load(open(p))
d['detections']['$det_ids']['last_seen'] = '$(d_date -1)'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  c2="$(state_field "$OUT_DIR/state.json" detections "$det_ids" consecutive_detections)"
  assert_eq "暦日が進んだ2週目相当では連続検出回数2" "2" "$c2"
  first_seen="$(state_field "$OUT_DIR/state.json" detections "$det_ids" first_seen)"
  assert_eq "初出日は変わらない" "$(d_date 0)" "$first_seen"

  # ジョブが長期停止していた場合のギャップリセット（Codexレビュー指摘・Major対応）:
  # last_seenを60日前に人為的に書き換え、GAP_RESET_DAYS(14日)を大幅に超える
  # 空白期間の後に再開したケースを再現する。連続検出回数・初出日ともに
  # 「今回を初出」として1へリセットされるべき（一律+1し続けない）。
  python3 -c "
import json
p = '$OUT_DIR/state.json'
d = json.load(open(p))
d['detections']['$det_ids']['last_seen'] = '$(d_date -60)'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  c_reset="$(state_field "$OUT_DIR/state.json" detections "$det_ids" consecutive_detections)"
  assert_eq "60日ギャップ後はストリークリセットで連続検出回数1" "1" "$c_reset"
  first_seen_reset="$(state_field "$OUT_DIR/state.json" detections "$det_ids" first_seen)"
  assert_eq "リセット時は初出日も今日にリセットされる" "$(d_date 0)" "$first_seen_reset"

  # 3週目: ノートを1件消して再検出されなくなる → ストリームが途切れて追跡終了(除去)。
  rm "$VAULT_DIR/Preferences/b.md"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  det_ids_after="$(state_ids "$OUT_DIR/state.json" detections)"
  assert_eq "再検出されなかったので検出ログから除去される" "0" "$(echo "$det_ids_after" | wc -w | tr -d ' ')"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 8. AC7相当: 複数週シミュレーション(pending→blocked→retry→引き継ぎ→merged→終端で除去) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'

  # 週1: 検出→pending
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  cid="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "週1: pending状態で1件検出" "pending" "$(state_field "$OUT_DIR/state.json" candidates "$cid" status)"

  # (外部プロセス=knowledge_merge.py相当が)blockedへ状態遷移させたと仮定してstate.jsonを直接編集
  python3 -c "
import json
p = '$OUT_DIR/state.json'
d = json.load(open(p))
d['candidates']['$cid']['status'] = 'blocked'
d['candidates']['$cid']['blocked_reason'] = 'ALERT_UNRESOLVED'
json.dump(d, open(p, 'w'))
"

  # 週2: 再検出されるが、外部から付与されたblockedはこのスクリプトからは変更しない
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  assert_eq "週2: blockedのまま引き継がれる" "blocked" "$(state_field "$OUT_DIR/state.json" candidates "$cid" status)"
  assert_eq "週2: 未知フィールド(blocked_reason)も保持される" "ALERT_UNRESOLVED" \
    "$(state_field "$OUT_DIR/state.json" candidates "$cid" blocked_reason)"
  report2="$(cat "$OUT_DIR"/20*.md)"
  assert_contains "週2レポートにもcandidate_idが載る(繰り越し)" "$report2" "$cid"

  # retryへ遷移させ、かつ「再検出されなくても引き継がれる」ことを見るため
  # 一方のノートを削除して次回は検出不可にする。
  python3 -c "
import json
p = '$OUT_DIR/state.json'
d = json.load(open(p))
d['candidates']['$cid']['status'] = 'retry'
json.dump(d, open(p, 'w'))
"
  rm "$VAULT_DIR/Knowledge/b.md"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  assert_eq "週3: 再検出されなくてもretryは無条件で引き継がれる(FR9b)" "retry" \
    "$(state_field "$OUT_DIR/state.json" candidates "$cid" status)"

  # mergedへ遷移させる（非破壊マージ確定を模擬）
  python3 -c "
import json
p = '$OUT_DIR/state.json'
d = json.load(open(p))
d['candidates']['$cid']['status'] = 'merged'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  status_after_merge="$(state_field "$OUT_DIR/state.json" candidates "$cid" status)"
  assert_eq "週4: mergedのままtombstoneとしてstate.jsonに残る(キー自体は消えない)" "merged" "$status_after_merge"
  report4="$(cat "$OUT_DIR"/20*.md)"
  assert_not_contains "週4レポートには終端済み候補IDが載らない(表示上は除外)" "$report4" "$cid"

  # 週5: 再度実行しても、tombstone(merged)が再検出されて"pending"へ復活しない
  # ことを確認する（Codexレビュー指摘・Major対応の回帰防止）。
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  status_week5="$(state_field "$OUT_DIR/state.json" candidates "$cid" status)"
  assert_eq "週5: 再検出されてもmergedのまま(pendingへ復活しない)" "merged" "$status_week5"
  report5="$(cat "$OUT_DIR"/20*.md)"
  assert_not_contains "週5レポートにも終端済み候補IDは載らない" "$report5" "$cid"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 8b. 終端状態(skipped)も同一実行内で即座にpendingへ再生成されない(Codexレビュー指摘・Major) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  cid="$(state_ids "$OUT_DIR/state.json" candidates)"

  # skippedは原ノートを変更しない（rejectされただけ）ため、is_active_note()の
  # deprecatedチェックでは除外できない。tombstone機構だけがこのケースを守る。
  python3 -c "
import json
p = '$OUT_DIR/state.json'
d = json.load(open(p))
d['candidates']['$cid']['status'] = 'skipped'
json.dump(d, open(p, 'w'))
"
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force >/dev/null
  status_after="$(state_field "$OUT_DIR/state.json" candidates "$cid" status)"
  assert_eq "原ノート未変更でも再検出時にskippedからpendingへ復活しない" "skipped" "$status_after"
  ids_active="$(python3 -c "
import json
d = json.load(open('$OUT_DIR/state.json'))
print(' '.join(sorted(cid for cid, r in d['candidates'].items() if r.get('status') not in ('merged','skipped'))))
")"
  assert_eq "レポート表示対象のアクティブ候補は0件" "0" "$(echo "$ids_active" | wc -w | tr -d ' ')"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 9. 既にスタブ化済み(deprecated: true)のノートはペア候補生成の対象から除外される ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A本文", "vector": [1.0, 0.0], "frontmatter": {"deprecated": "true"}},
      "Knowledge/b.md": {"body": "B本文", "vector": [0.9, 0.4359]}
    }
  }'
  run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.5 >/dev/null
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "deprecated済みノートを含むペアは候補にならない" "0" "$(echo "$ids" | wc -w | tr -d ' ')"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 10. MIN_INTERVAL_DAYSガード: 前回レポートから既定日数未満の実行はskipする・--forceで無視できる ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  # 3日前の過去レポートを事前に置く（既定7日未満なのでskipされるはず）
  mkdir -p "$OUT_DIR"
  echo "# dummy" > "$OUT_DIR/$(d_date -3).md"

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  assert_contains "既定7日未満はskipする" "$out" "skip:"
  count_before="$(ls "$OUT_DIR"/20*.md | wc -l | tr -d ' ')"
  assert_eq "新しいレポートは作られない" "1" "$count_before"

  # --min-interval-daysを1に緩めれば、今日作られていない(3日前の)古いレポートの
  # ままでも実行される（--forceで既に当日レポートが出来ると条件が変わってしまう
  # ため、この検証は--forceの前に行う）。
  out_relaxed="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --min-interval-days 1)"
  assert_not_contains "--min-interval-daysを1にすれば3日前でも実行される" "$out_relaxed" "skip:"

  # 上のrelaxed実行で当日レポートが生成された状態から、さらに--forceで
  # (既定7日未満でも)無条件に再実行できることを確認する。
  out_forced="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --force)"
  assert_not_contains "--forceならガードを無視して実行する" "$out_forced" "skip:"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 11. インデックス不在はfail-open(レポート生成せず正常終了・exit 0) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  # IDX_DIRは空のまま(CURRENTポインタ無し)

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR")"
  rc=$?
  assert_eq "exit code 0(fail-open)" "0" "$rc"
  assert_contains "skipメッセージにインデックス不在の旨が出る" "$out" "埋め込みインデックスを読み込めません"
  n_reports="$(ls "$OUT_DIR"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "レポートは生成されない" "0" "$n_reports"
  assert_eq "state.jsonも生成されない" "0" "$([ -f "$OUT_DIR/state.json" ] && echo 1 || echo 0)"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 12. 対象ノートが1件以下のフォルダはエラーにならず候補0件になる ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]}
    }
  }'
  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.5)"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_contains "候補0件のログ" "$out" "レビュー待ち候補 0 件"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 13. state.jsonが壊れている場合はfail-open(書込せず正常終了・既存内容を保持) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  mkdir -p "$OUT_DIR"
  printf '{ this is not valid json' > "$OUT_DIR/state.json"
  broken_content="$(cat "$OUT_DIR/state.json")"

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  rc=$?
  assert_eq "exit code 0(fail-open)" "0" "$rc"
  assert_contains "state.json破損の旨がログに出る" "$out" "skip:"
  n_reports="$(ls "$OUT_DIR"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "レポートも生成されない" "0" "$n_reports"
  after_content="$(cat "$OUT_DIR/state.json")"
  assert_eq "壊れたstate.jsonの内容は変更されない(黙って空状態へ作り直さない)" "$broken_content" "$after_content"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 14. state.jsonが不正な形式(candidatesがオブジェクトでない等)でもfail-open ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  mkdir -p "$OUT_DIR"
  echo '{"candidates": "not-an-object", "detections": {}}' > "$OUT_DIR/state.json"

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  rc=$?
  assert_eq "exit code 0(fail-open)" "0" "$rc"
  assert_contains "形式不正の旨がログに出る" "$out" "skip:"
  n_reports="$(ls "$OUT_DIR"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "レポートも生成されない" "0" "$n_reports"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 14b. state.jsonにschema_versionが無い/不一致でもfail-open(Codexレビュー指摘) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  mkdir -p "$OUT_DIR"
  echo '{"candidates": {}, "detections": {}}' > "$OUT_DIR/state.json"

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  assert_eq "exit code 0(fail-open)" "0" "$?"
  assert_contains "schema_version欠如の旨がログに出る" "$out" "schema_version"
  n_reports="$(ls "$OUT_DIR"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "レポートも生成されない" "0" "$n_reports"
  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"

  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  mkdir -p "$OUT_DIR"
  echo '{"schema_version": 999, "candidates": {}, "detections": {}}' > "$OUT_DIR/state.json"

  out2="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8)"
  assert_eq "schema_version不一致でもexit code 0(fail-open)" "0" "$?"
  assert_contains "schema_version不一致の旨がログに出る" "$out2" "schema_version"
  n_reports2="$(ls "$OUT_DIR"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "schema_version不一致時もレポートは生成されない" "0" "$n_reports2"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 15. state.json排他ロックが競合していれば書込せずskipする(knowledge_merge.pyとの同時実行対策) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"; LOCK_FILE="$(mktemp -u)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  # 別プロセスがロックを保持している状況を模擬する（flock保持のまま少し待つ）。
  # 固定sleepで「保持されただろう」と仮定すると遅い環境で偽失敗し得るため、
  # 保持側がロック取得直後に作るreadyファイルの出現を有界ポーリングしてから
  # 本体を実行する（Codexレビュー指摘対応）。
  mkdir -p "$(dirname "$LOCK_FILE")"
  READY_FILE="$(mktemp -u)"
  python3 -c "
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], 'w').close()
time.sleep(3)
" "$LOCK_FILE" "$READY_FILE" &
  holder_pid=$!
  waited=0
  while [ ! -e "$READY_FILE" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done

  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold 0.8 --lock-file "$LOCK_FILE")"
  rc=$?
  assert_eq "exit code 0(fail-open)" "0" "$rc"
  assert_contains "ロック競合の旨がログに出る" "$out" "排他ロックを取得できません"
  n_reports="$(ls "$OUT_DIR"/20*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "ロック競合時はレポートも生成されない" "0" "$n_reports"

  wait "$holder_pid" 2>/dev/null
  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR" "$READY_FILE"
}

echo "=== 16. --sim-thresholdが不正値(NaN等)なら既定値へフォールバックする(クラッシュしない) ==="
{
  VAULT_DIR="$(mktemp -d)"; IDX_DIR="$(mktemp -d)"; OUT_DIR="$(mktemp -d)"
  build_index "$VAULT_DIR" "$IDX_DIR" '{
    "dim": 2,
    "notes": {
      "Knowledge/a.md": {"body": "A", "vector": [1.0, 0.0]},
      "Knowledge/b.md": {"body": "B", "vector": [0.9, 0.4359]}
    }
  }'
  out="$(run_kmc --vault "$VAULT_DIR" --index-dir "$IDX_DIR" --out-dir "$OUT_DIR" --sim-threshold nan)"
  rc=$?
  assert_eq "exit code 0(クラッシュしない)" "0" "$rc"
  assert_contains "不正値の警告が出る" "$out" "既定値"
  ids="$(state_ids "$OUT_DIR/state.json" candidates)"
  assert_eq "既定閾値(0.80)で通常どおり候補が検出される" "1" "$(echo "$ids" | wc -w | tr -d ' ')"

  rm -rf "$VAULT_DIR" "$IDX_DIR" "$OUT_DIR"
}

echo "=== 17. VAULT_MERGE_SIM_THRESHOLD環境変数が不正でもimport時にクラッシュしない ==="
{
  out="$(VAULT_MERGE_SIM_THRESHOLD="not-a-number" python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.DEFAULT_SIM_THRESHOLD)
")"
  assert_eq "不正な環境変数はハードコード既定値0.8にフォールバックする" "0.8" "$out"
}

echo "=== 17b. VAULT_MERGE_SIM_THRESHOLD環境変数が範囲外(cosine類似度の理論範囲[-1,1]外)でもフォールバックする(Codexレビュー指摘) ==="
{
  out="$(VAULT_MERGE_SIM_THRESHOLD="2" python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.DEFAULT_SIM_THRESHOLD)
")"
  assert_eq "範囲外の環境変数(2)は既定値0.8にフォールバックする" "0.8" "$out"
}

echo "=== 18. 候補IDはsha256の全桁(64 hex文字)を使う(衝突耐性・Codexレビュー指摘) ==="
{
  id="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/vault-agents')
import knowledge_merge_candidates as kmc
print(kmc.stable_pair_id('Knowledge/a.md', 'Knowledge/b.md'))
")"
  hexpart="${id#cand-}"
  assert_eq "cand-prefixの後ろは64文字" "64" "${#hexpart}"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
