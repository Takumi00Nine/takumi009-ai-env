#!/bin/bash
# claude/hooks/lib/health_judge.py（外部脳ヘルスの判定機）のユニットテスト。
# 案件 health-self-explain（要件 v1.3.2 §4 S-1〜S-23・設計 v1.2 §4／§8／§10.2）。
# 判定機 1 本の入出力で要件 fixture 23 本を閉じる（bootstrap・Dock は「判定機の写し」であることを
# tests/test-bootstrap-vault.sh・tests/test-cmux-next-model.sh が少数のケースで検査する）。
# 実 $HOME・実 launchd・実 cmux・実 Vault には触れない（fixture と一時ディレクトリだけ）。
#
# 実行方法: bash tests/test-health-judge.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JUDGE="$SCRIPT_DIR/../claude/hooks/lib/health_judge.py"
FX_ROOT="$SCRIPT_DIR/fixtures/health"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/health-judge-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  期待した文字列が見つかりません: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  含まれてはいけない文字列が見つかりました: $needle"
  else
    PASS=$(( PASS + 1 ))
  fi
}

# judge_fixture <fixture名> [追加引数...] — fixture の 4 入力＋now（＋plist があれば）で判定機を回し、
# JSON を $WORKDIR/verdict.json へ置く。rc を返す。時刻帯は Asia/Tokyo に固定して決定的にする（V-13）。
judge_fixture() {
  local fx="$1"; shift
  local d="$FX_ROOT/$fx" plist_args=""
  [ -f "$d/plist" ] && plist_args="--plist $d/plist"
  # shellcheck disable=SC2086
  python3 "$JUDGE" judge \
    --last-run "$d/last-run.json" --inventory-latest "$d/latest.json" \
    --observation "$d/observation.json" --recall-log "$d/vault-recall.tsv" \
    --reads-log "$d/vault-reads.tsv" --now "$(cat "$d/now")" --tz Asia/Tokyo \
    $plist_args "$@" > "$WORKDIR/verdict.json" 2> "$WORKDIR/verdict.err"
}

jv() { jq -r "$1" "$WORKDIR/verdict.json"; }
stage() { jv '.stage'; }
n_items() { jv '.n_items'; }
item() { jq -r ".items[$1]$2" "$WORKDIR/verdict.json"; }   # item <index> <jq path>

echo "=== 判定機は JSON を出せたとき常に rc=0・schema=health-verdict/1・judged_at=now・now_injected=true ==="
judge_fixture S-1
assert_eq "S-1: rc=0" "0" "$?"
assert_eq "S-1: schema" "health-verdict/1" "$(jv '.schema')"
assert_eq "S-1: judged_at は --now の写し" "$(cat "$FX_ROOT/S-1/now")" "$(jv '.judged_at')"
assert_eq "S-1: extras.now_injected" "true" "$(jv '.extras.now_injected')"

echo "=== S1_ok_header_only_no_warning_mark（AC-4）: 要対処 0・OK・state=completed・fragments_candidates は extras に ==="
assert_eq "S-1: stage=OK" "OK" "$(stage)"
assert_eq "S-1: items=0" "0" "$(n_items)"
assert_eq "S-1: maintenance.state" "completed" "$(jv '.sources.maintenance.state')"
assert_eq "S-1: inventory.actionable=0" "0" "$(jv '.sources.inventory.actionable')"
assert_eq "S-1: extras.fragments_candidates" "$(jq -r '.fragments_candidates' "$FX_ROOT/S-1/last-run.json")" "$(jv '.extras.fragments_candidates')"
assert_eq "S-1: success_streak（FR-24・fixture どおり）" "$(jq -r '.success_streak' "$FX_ROOT/S-1/last-run.json")" "$(jv '.sources.maintenance.success_streak')"

echo "=== S2_one_item_fail_ai_ack_none（AC-1）: ちょうど 1 件・4 項目・失敗・AI・ack=null ==="
judge_fixture S-2
assert_eq "S-2: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-2: items=1" "1" "$(n_items)"
assert_eq "S-2: ① 工程の識別（V-17 差し替え後は phase1-inventory）" "$(jq -r '.completed.steps[0].id' "$FX_ROOT/S-2/last-run.json")" "$(item 0 .id)"
assert_eq "S-2: ① 結果種別=失敗" "失敗" "$(item 0 .result)"
assert_eq "S-2: ② 理由が書き手の記録どおり" "$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-2/last-run.json")" "$(item 0 .reason)"
assert_contains "S-2: ③ OK に戻る条件（本番経路の再実行）" "$(item 0 .ok_when)" "完全正常終了する"
assert_eq "S-2: ④ 申告=null（描画側が該当なしに写す）" "null" "$(item 0 .ack)"
assert_eq "S-2: 主体=AI" "AI" "$(item 0 .actor)"
assert_eq "S-2: 所属源=maintenance" "maintenance" "$(item 0 .source)"
assert_eq "S-2: severity=WARNING" "WARNING" "$(item 0 .severity)"
assert_eq "S-2: log_ref（FR-23）" "$(jq -r '.completed.steps[0].log_ref' "$FX_ROOT/S-2/last-run.json")" "$(item 0 .log_ref)"
assert_eq "S-2: plist あり・予定を跨いでいない＝未起動 0（next_due が開始より前）" "0" "$(jq -r '[.items[] | select(.id == "not_started")] | length' "$WORKDIR/verdict.json")"
assert_eq "S-2: next_due は 2026-09-14 06:00 JST" "2026-09-14T06:00:00+09:00" "$(jv '.sources.maintenance.next_due')"

echo "=== S2_twice_same_now_identical（AC-17）: 同一内容・同一判定時刻で 2 回＝完全一致 ==="
cp "$WORKDIR/verdict.json" "$WORKDIR/verdict-1.json"
judge_fixture S-2
assert_eq "S-2: 2 回の出力が完全一致" "$(cat "$WORKDIR/verdict-1.json")" "$(cat "$WORKDIR/verdict.json")"

echo "=== S3_two_items_reasons_verbatim_actors_split（AC-2）: 2 件・理由の合計 >200 文字が逐語・警告/失敗・本人/AI ==="
judge_fixture S-3
assert_eq "S-3: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-3: items=2" "2" "$(n_items)"
r0="$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-3/last-run.json")"
r1="$(jq -r '.completed.steps[1].reason' "$FX_ROOT/S-3/last-run.json")"
total_len="$(python3 -c "import sys; print(len(sys.argv[1]) + len(sys.argv[2]))" "$r0" "$r1")"
assert_true "S-3: 2 工程の理由の合計が 200 文字を超える fixture（実測 ${total_len}）" "$([ "$total_len" -gt 200 ] && echo 1 || echo 0)"
assert_eq "S-3: [1] 理由が逐語（切り詰め 0）" "$r0" "$(item 0 .reason)"
assert_eq "S-3: [2] 理由が逐語（切り詰め 0）" "$r1" "$(item 1 .reason)"
assert_eq "S-3: 結果種別が 警告/失敗 に分かれる" "警告 失敗" "$(jq -r '[.items[].result] | join(" ")' "$WORKDIR/verdict.json")"
assert_eq "S-3: 主体が 本人/AI に分かれる" "本人 AI" "$(jq -r '[.items[].actor] | join(" ")' "$WORKDIR/verdict.json")"

echo "=== S4_interrupted（AC-3）: now ≥ 開始＋余裕 → 中断 1 件・WARNING・AI・前回の完了結果は出さない ==="
judge_fixture S-4
assert_eq "S-4: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-4: items=1" "1" "$(n_items)"
assert_eq "S-4: state=interrupted" "interrupted" "$(jv '.sources.maintenance.state')"
assert_eq "S-4: 結果種別=中断" "中断" "$(item 0 .result)"
assert_contains "S-4: 「開始したが完了記録が無い」と読める" "$(item 0 .reason)" "開始したが完了記録が無い"
assert_eq "S-4: 主体=AI" "AI" "$(item 0 .actor)"
assert_not_contains "S-4: 前回（fail 1 件）の理由 X は現在の結果として出ない" "$(jq -c '.items' "$WORKDIR/verdict.json")" "理由X"

echo "=== S5_broken（AC-3）: 破損 1 件・WARNING・AI ==="
judge_fixture S-5
assert_eq "S-5: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-5: items=1" "1" "$(n_items)"
assert_eq "S-5: state=broken" "broken" "$(jv '.sources.maintenance.state')"
assert_eq "S-5: 結果種別=破損" "破損" "$(item 0 .result)"
assert_eq "S-5: 主体=AI" "AI" "$(item 0 .actor)"

echo "=== S21_not_started（AC-3）: 予定超過・開始記録なし → 未起動 1 件・WARNING・AI ==="
judge_fixture S-21
assert_eq "S-21: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-21: items=1" "1" "$(n_items)"
assert_eq "S-21: id=not_started" "not_started" "$(item 0 .id)"
assert_eq "S-21: 結果種別=未起動" "未起動" "$(item 0 .result)"
assert_contains "S-21: 「予定時刻を過ぎて開始していない」と読める" "$(item 0 .reason)" "予定時刻を過ぎて開始していない"
assert_eq "S-21: 主体=AI" "AI" "$(item 0 .actor)"
assert_contains "S-21: ok_when＝手動起動または次の定期起動" "$(item 0 .ok_when)" "手動起動"
assert_eq "S-21: next_due=2026-09-21 06:00 JST（直前の実行 09-14 より後）" "2026-09-21T06:00:00+09:00" "$(jv '.sources.maintenance.next_due')"

echo "=== S6_ack_cleared_ok／S7_ack_refailed（AC-7）: 申告の失効 ==="
judge_fixture S-6
assert_eq "S-6: stage=OK" "OK" "$(stage)"
assert_eq "S-6: items=0（申告が消えている）" "0" "$(n_items)"
judge_fixture S-7
assert_eq "S-7: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-7: items=1" "1" "$(n_items)"
assert_eq "S-7: ack.state=refailed（申告後に再失敗）" "refailed" "$(item 0 .ack.state)"
assert_eq "S-7: ack.note が読める" "$(jq -r '.ack.note' "$FX_ROOT/S-7/last-run.json")" "$(item 0 .ack.note)"

echo "=== S8_inventory_two_items_actor_split_observe_excluded（AC-9）: 要確認 2 件に ①〜④・AI/本人・要観察は数えない ==="
judge_fixture S-8
assert_eq "S-8: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-8: items=2" "2" "$(n_items)"
assert_eq "S-8: 所属源は両方 inventory" "inventory inventory" "$(jq -r '[.items[].source] | join(" ")' "$WORKDIR/verdict.json")"
assert_eq "S-8: ① 種別" "date_drift owner_decision" "$(jq -r '[.items[].kind] | join(" ")' "$WORKDIR/verdict.json")"
assert_eq "S-8: ② 対象" "Knowledge/x.md Projects/y.md" "$(jq -r '[.items[].target] | join(" ")' "$WORKDIR/verdict.json")"
assert_eq "S-8: ③ 主体が AI/本人 に分かれる（表に無い kind は本人）" "AI 本人" "$(jq -r '[.items[].actor] | join(" ")' "$WORKDIR/verdict.json")"
assert_contains "S-8: ④ 数が減る条件" "$(item 0 .ok_when)" "件数が減る"
assert_eq "S-8: log_ref＝report_path（V-19）" "$(jq -r '.report_path' "$FX_ROOT/S-8/latest.json")" "$(item 0 .log_ref)"
assert_not_contains "S-8: 要観察（unread_pending）は項目に現れない" "$(jq -c '.items' "$WORKDIR/verdict.json")" "unread_pending"

echo "=== S9_ok（AC-5 判定機側）: 手動起動の完全正常終了 → OK・trigger=manual ==="
judge_fixture S-9
assert_eq "S-9: stage=OK" "OK" "$(stage)"
assert_eq "S-9: items=0" "0" "$(n_items)"
assert_eq "S-9: trigger=manual（FR-22）" "manual" "$(jv '.sources.maintenance.trigger')"

echo "=== S10_reason_Y_only（AC-6）: 再失敗で理由が Y に置き換わる（X が残らない） ==="
judge_fixture S-10
assert_eq "S-10: items=1" "1" "$(n_items)"
assert_eq "S-10: 別工程・別理由（V-17 差し替え後は phase1-fragments）" "$(jq -r '.completed.steps[0].id' "$FX_ROOT/S-10/last-run.json")" "$(item 0 .id)"
assert_eq "S-10: 理由が書き手の記録どおり（新しい理由に置き換わる）" "$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-10/last-run.json")" "$(item 0 .reason)"
assert_not_contains "S-10: 元の失敗理由（S-11 と同じ最初の理由）が残らない" "$(jq -c '.items' "$WORKDIR/verdict.json")" "$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-11/last-run.json")"

echo "=== S11_ack_pending_still_warning（AC-8）: 申告だけでは OK にならない・④＝次回判定待ち ==="
judge_fixture S-11
assert_eq "S-11: stage=WARNING のまま" "WARNING" "$(stage)"
assert_eq "S-11: items=1" "1" "$(n_items)"
assert_eq "S-11: ack.state=pending（対処済み・次回判定待ち）" "pending" "$(item 0 .ack.state)"

echo "=== S8_then_S12_count_decreases（AC-16）: 対処すれば数が減る（2→1・本人のみ・WARNING のまま） ==="
judge_fixture S-8
n8="$(n_items)"
judge_fixture S-12
assert_eq "S-12: items=1" "1" "$(n_items)"
assert_true "S-8→S-12 で減っている" "$([ "$n8" -gt "$(n_items)" ] && echo 1 || echo 0)"
assert_eq "S-12: 残りは本人主体" "本人" "$(item 0 .actor)"
assert_eq "S-12: stage=WARNING のまま（FR-14）" "WARNING" "$(stage)"

echo "=== S13_two_items_fail_plus_not_started（AC-18）: 時間経過では OK にならない＝失敗 X＋未起動 ==="
judge_fixture S-13
assert_eq "S-13: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-13: items=2" "2" "$(n_items)"
assert_eq "S-13: id の集合＝not_started＋S-2 と同じ工程（V-17 差し替え後は phase1-inventory）" \
  "$(printf 'not_started\n%s\n' "$(jq -r '.completed.steps[0].id' "$FX_ROOT/S-2/last-run.json")" | sort | tr '\n' ' ' | sed 's/ $//')" \
  "$(jq -r '[.items[].id] | sort | join(" ")' "$WORKDIR/verdict.json")"
assert_contains "S-13: S-2 と同じ理由が残る" "$(cat "$WORKDIR/verdict.json")" "$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-2/last-run.json")"
assert_eq "S-13: 未起動の主体=AI" "AI" "$(jq -r '.items[] | select(.id == "not_started") | .actor' "$WORKDIR/verdict.json")"

echo "=== S14／S23（T-2）: 不在＝ファイル無し／キー無し → OK・要対処 0（予定超過でも先勝ち） ==="
judge_fixture S-14
assert_eq "S-14: stage=OK" "OK" "$(stage)"
assert_eq "S-14: items=0" "0" "$(n_items)"
assert_eq "S-14: state=absent" "absent" "$(jv '.sources.maintenance.state')"
assert_true "S-14: 予定は過ぎている（next_due が非 null）" "$([ "$(jv '.sources.maintenance.next_due')" != "null" ] && echo 1 || echo 0)"
judge_fixture S-23
assert_eq "S-23: stage=OK" "OK" "$(stage)"
assert_eq "S-23: items=0" "0" "$(n_items)"
assert_eq "S-23: state=absent（キー不在）" "absent" "$(jv '.sources.maintenance.state')"
assert_eq "S-23: fragments_candidates は extras に残る" "3" "$(jv '.extras.fragments_candidates')"

echo "=== S15（T-9）: 必読ノート 1 件が読めない → ERROR 1 件 ==="
judge_fixture S-15
assert_eq "S-15: stage=ERROR" "ERROR" "$(stage)"
assert_eq "S-15: items=1" "1" "$(n_items)"
assert_eq "S-15: source=load" "load" "$(item 0 .source)"
assert_eq "S-15: target" "Preferences/core-conduct.md" "$(item 0 .target)"
assert_eq "S-15: severity=ERROR" "ERROR" "$(item 0 .severity)"
assert_eq "S-15: actor=AI" "AI" "$(item 0 .actor)"

echo "=== S16_two_items_sources_error_source_one（AC-20）: 複数源の和・ERROR を生んだ源が 1 件 ==="
judge_fixture S-16
assert_eq "S-16: stage=ERROR（最悪値）" "ERROR" "$(stage)"
assert_eq "S-16: items=2" "2" "$(n_items)"
assert_eq "S-16: 所属源が読める" "maintenance load" "$(jq -r '[.items[].source] | join(" ")' "$WORKDIR/verdict.json")"
assert_eq "S-16: severity=ERROR の項目がちょうど 1 件" "1" "$(jq -r '[.items[] | select(.severity == "ERROR")] | length' "$WORKDIR/verdict.json")"
assert_eq "S-16: ERROR を生んだ源＝load" "load" "$(jq -r '.items[] | select(.severity == "ERROR") | .source' "$WORKDIR/verdict.json")"

echo "=== S17_child_failure_is_fail（AC-19 判定機側）: 09-14 型は「失敗」・理由が逐語・AI ==="
judge_fixture S-17
assert_eq "S-17: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-17: items=1" "1" "$(n_items)"
assert_eq "S-17: 結果種別=失敗（警告ではない）" "失敗" "$(item 0 .result)"
assert_eq "S-17: 理由が子の失敗理由どおり（切り詰め 0）" "$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-17/last-run.json")" "$(item 0 .reason)"
assert_eq "S-17: 主体=AI" "AI" "$(item 0 .actor)"
assert_eq "S-17: 旧欄 last_result=warn は判定に使わない（fixture の前提）" "warn" "$(jq -r '.last_result' "$FX_ROOT/S-17/last-run.json")"

echo "=== S18_vault_root_one_item_error（AC-20）: Vault ルート不在＝1 件（ノートごとに数えない）・ERROR ==="
judge_fixture S-18
assert_eq "S-18: stage=ERROR" "ERROR" "$(stage)"
assert_eq "S-18: items=1" "1" "$(n_items)"
assert_eq "S-18: id=vault_root" "vault_root" "$(item 0 .id)"
assert_eq "S-18: missing は 4 件あるが項目は 1" "4" "$(jq -r '.load.missing | length' "$FX_ROOT/S-18/observation.json")"

echo "=== S19_recall_direct_error／S20_recall_stale_warning（AC-22 恒） ==="
judge_fixture S-19
assert_eq "S-19: stage=ERROR" "ERROR" "$(stage)"
assert_eq "S-19: items=1" "1" "$(n_items)"
assert_eq "S-19: source=recall" "recall" "$(item 0 .source)"
assert_eq "S-19: id=recall_not_injected" "recall_not_injected" "$(item 0 .id)"
assert_contains "S-19: 前セッションの sid と reads 行数が理由に載る" "$(item 0 .reason)" "sess-prev-0001 は Vault を読んだ（reads 3 行）が想起の記録が 0 行"
judge_fixture S-20
assert_eq "S-20: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-20: items=1" "1" "$(n_items)"
assert_eq "S-20: id=recall_stale" "recall_stale" "$(item 0 .id)"
assert_eq "S-20: 最終有効行の経過日数=15（>7）" "15" "$(jv '.sources.recall.last_valid_row_age_days')"
assert_eq "S-20: actor=AI" "AI" "$(item 0 .actor)"

echo "=== S22_unknown_actor_normalized_to_person（AC-21）: 判定できない主体は本人に倒す ==="
judge_fixture S-22
assert_eq "S-22: stage=WARNING" "WARNING" "$(stage)"
assert_eq "S-22: items=1" "1" "$(n_items)"
assert_eq "S-22: actor=本人" "本人" "$(item 0 .actor)"
assert_eq "S-22: 書き手の actor は未知値（fixture の前提）" "unknown-actor" "$(jq -r '.completed.steps[0].actor' "$FX_ROOT/S-22/last-run.json")"

echo "=== truth_table_23（AC-11）: OK 5／WARNING 14／ERROR 4＝計 23（S-* 全件） ==="
declare_stage() {
  case "$1" in
    S-1|S-6|S-9|S-14|S-23) echo OK ;;
    S-15|S-16|S-18|S-19) echo ERROR ;;
    *) echo WARNING ;;
  esac
}
n_ok=0; n_warn=0; n_err=0; n_total=0
for d in "$FX_ROOT"/S-*; do
  fx="$(basename "$d")"
  judge_fixture "$fx"
  rc=$?
  n_total=$(( n_total + 1 ))
  assert_eq "truth_table_23: $fx rc=0" "0" "$rc"
  assert_eq "truth_table_23: $fx の段階" "$(declare_stage "$fx")" "$(stage)"
  assert_eq "truth_table_23: $fx の n_items と items の長さが一致" "$(n_items)" "$(jv '.items | length')"
  assert_eq "truth_table_23: $fx の全項目に severity（WARNING/ERROR）" "$(n_items)" "$(jq -r '[.items[] | select(.severity == "WARNING" or .severity == "ERROR")] | length' "$WORKDIR/verdict.json")"
  assert_eq "truth_table_23: $fx の全項目の actor が AI/本人" "$(n_items)" "$(jq -r '[.items[] | select(.actor == "AI" or .actor == "本人")] | length' "$WORKDIR/verdict.json")"
  case "$(stage)" in OK) n_ok=$(( n_ok + 1 )) ;; WARNING) n_warn=$(( n_warn + 1 )) ;; ERROR) n_err=$(( n_err + 1 )) ;; esac
done
assert_eq "truth_table_23: fixture 総数 23" "23" "$n_total"
assert_eq "truth_table_23: OK 5" "5" "$n_ok"
assert_eq "truth_table_23: WARNING 14" "14" "$n_warn"
assert_eq "truth_table_23: ERROR 4" "4" "$n_err"

echo "=== X1_scheduled_busy_skip_counts_not_started／X1b_manual_busy_skip_not_counted（V-2） ==="
judge_fixture X-1
assert_eq "X-1: stage=WARNING" "WARNING" "$(stage)"
assert_eq "X-1: items=1" "1" "$(n_items)"
assert_eq "X-1: id=not_started" "not_started" "$(item 0 .id)"
assert_eq "X-1: actor=AI" "AI" "$(item 0 .actor)"
assert_contains "X-1: 理由に busy-skip" "$(item 0 .reason)" "busy-skip"
assert_eq "X-1: state=skipped" "skipped" "$(jv '.sources.maintenance.state')"
judge_fixture X-1b
assert_eq "X-1b: stage=OK" "OK" "$(stage)"
assert_eq "X-1b: items=0（手動の busy-skip は加算しない）" "0" "$(n_items)"
assert_eq "X-1b: state=skipped" "skipped" "$(jv '.sources.maintenance.state')"
assert_eq "X-1b: skipped の理由" "busy:lock" "$(jv '.sources.maintenance.skipped')"
assert_eq "X-1b: prev_completed_run_id（「前回」明示の材料）" "2026-09-08/150001-1111" "$(jv '.sources.maintenance.prev_completed_run_id')"

echo "=== X2_completed_run_id_mismatch_is_broken（V-14） ==="
judge_fixture X-2
assert_eq "X-2: stage=WARNING" "WARNING" "$(stage)"
assert_eq "X-2: items=1" "1" "$(n_items)"
assert_eq "X-2: state=broken" "broken" "$(jv '.sources.maintenance.state')"
assert_contains "X-2: 理由に run_id 不一致" "$(item 0 .reason)" "completed.run_id が一致しない"

echo "=== X3_unparsable_json_is_broken_not_absent（V-21） ==="
judge_fixture X-3
assert_eq "X-3: stage=WARNING" "WARNING" "$(stage)"
assert_eq "X-3: items=1" "1" "$(n_items)"
assert_eq "X-3: state=broken（absent でない）" "broken" "$(jv '.sources.maintenance.state')"
assert_contains "X-3: 理由に解析不能" "$(item 0 .reason)" "解析できない"

echo "=== X4_inventory_missing_only_when_completed（V-6）: latest.json 無し × 週次の状態 ==="
X4="$FX_ROOT/X-4"
x4_judge() {   # $1=last-run のパス
  python3 "$JUDGE" judge --last-run "$1" --inventory-latest "$X4/latest.json" \
    --observation "$X4/observation.json" --recall-log "$X4/vault-recall.tsv" \
    --now "$2" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
}
assert_true "X-4: latest.json は意図的に無い" "$([ ! -e "$X4/latest.json" ] && echo 1 || echo 0)"
x4_judge "$X4/last-run.json" "$(cat "$X4/now")"
assert_eq "X-4 completed(steps 空): phase1-inventory 1 件" "phase1-inventory" "$(jq -r '[.items[].id] | join(" ")' "$WORKDIR/verdict.json")"
assert_eq "X-4 completed(steps 空): actor=AI" "AI" "$(item 0 .actor)"
x4_judge "/nonexistent-dir/last-run.json" "$(cat "$X4/now")"
assert_eq "X-4 absent: 加算なし（OK）" "OK 0" "$(jv '"\(.stage) \(.n_items)"')"
x4_judge "$X4/variants/interrupted.json" "$(cat "$FX_ROOT/S-4/now")"
assert_eq "X-4 interrupted: 中断 1 件だけ" "interrupted" "$(jq -r '[.items[].id] | join(" ")' "$WORKDIR/verdict.json")"
x4_judge "$X4/variants/broken.json" "$(cat "$X4/now")"
assert_eq "X-4 broken: 破損 1 件だけ" "broken" "$(jq -r '[.items[].id] | join(" ")' "$WORKDIR/verdict.json")"
x4_judge "$X4/variants/with-inventory-step.json" "$(cat "$X4/now")"
assert_eq "X-4 completed(steps に phase1-inventory あり): 二重計上しない＝1 件" "1" "$(jq -r '[.items[] | select(.id == "phase1-inventory")] | length' "$WORKDIR/verdict.json")"

echo "=== X5_running_shows_prev_completed_only（W-3・§14-6）: 実行中＝前回の fail 1 件のみ・WARNING ==="
judge_fixture X-5
assert_eq "X-5: state=running" "running" "$(jv '.sources.maintenance.state')"
assert_eq "X-5: stage=WARNING" "WARNING" "$(stage)"
assert_eq "X-5: items=1（前回の fail のみ）" "1" "$(n_items)"
assert_eq "X-5: 項目 id" "phase1-fragments" "$(item 0 .id)"
assert_eq "X-5: 未起動 0・中断 0・破損 0" "0" "$(jq -r '[.items[] | select(.id == "not_started" or .id == "interrupted" or .id == "broken")] | length' "$WORKDIR/verdict.json")"
assert_eq "X-5: prev_completed_run_id は run と異なる" "2026-09-08/150001-1111" "$(jv '.sources.maintenance.prev_completed_run_id')"
# V-17 差し替え後の注記＝A の書き手（H-8＝writer_interrupted_S4_run_only）は「completed 無し（開始の
# 記録のみ）」を厳密に守るため、S-4（中断）は前回の completed を持たない。X-5（running・前回 completed
# 付き）は B が手書きした独立の fixture のまま（S-4 と now だけが違う対、という設計 §10.2 の想定どおりの
# 組は作れない＝実物との食い違い。リーダー判断が要る点として報告する）。ここでは各々が自分の fixture の
# 前提（S-4＝completed 無し／X-5＝completed あり）を満たすことだけを検査する。
assert_eq "S-4: completed は無い（開始の記録のみ・V-17 差し替え後の実物）" "false" "$(jq -r 'has("completed")' "$FX_ROOT/S-4/last-run.json")"
assert_eq "X-5: completed がある（前回の fail 1 件・B の手書き fixture のまま）" "true" "$(jq -r 'has("completed")' "$FX_ROOT/X-5/last-run.json")"

echo "=== running の前段でも ④ の型・時刻検査は通る: run.started_at が未来なら broken（§4.1 ③ 前段の注記） ==="
FUT="$WORKDIR/future-running.json"
jq '.run.status = "running" | .run.started_at = "2099-01-01T00:00:00Z" | .run.finished_at = null' "$FX_ROOT/S-1/last-run.json" > "$FUT"
python3 "$JUDGE" judge --last-run "$FUT" --inventory-latest "$FX_ROOT/S-1/latest.json" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-1/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "未来の running: state=broken" "broken" "$(jv '.sources.maintenance.state')"

echo "=== running_without_stale_after_is_broken（検証 B-1・設計 §3.2 線の複製禁止）: run.stale_after_seconds が無い／整数でない → 表示状態を決めず broken ==="
NOSTALE="$WORKDIR/no-stale-running.json"
jq 'del(.run.stale_after_seconds) | .run.status = "running" | .run.started_at = "2026-09-15T06:00:01Z" | .run.finished_at = null' "$FX_ROOT/S-1/last-run.json" > "$NOSTALE"
python3 "$JUDGE" judge --last-run "$NOSTALE" --inventory-latest "$FX_ROOT/S-1/latest.json" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-1/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "stale_after_seconds 欠落（running 中）: 判定機は既定値を発明せず state=broken" "broken" "$(jv '.sources.maintenance.state')"
assert_contains "stale_after_seconds 欠落: 理由に「無いか整数ではない」" "$(item 0 .reason)" "無いか整数ではない"

echo "=== fully_ok_true_with_anomalous_steps_is_broken（検証 B-8・書き手契約） ==="
FOKTRUE="$WORKDIR/fully-ok-true-with-steps.json"
jq '.completed.fully_ok = true' "$FX_ROOT/S-2/last-run.json" > "$FOKTRUE"
python3 "$JUDGE" judge --last-run "$FOKTRUE" --inventory-latest "$FX_ROOT/S-2/latest.json" \
  --observation "$FX_ROOT/S-2/observation.json" --recall-log "$FX_ROOT/S-2/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-2/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "fully_ok=true なのに異常工程がある: state=broken" "broken" "$(jv '.sources.maintenance.state')"
assert_contains "fully_ok=true なのに異常工程がある: 理由に「異常工程がある」" "$(item 0 .reason)" "異常工程がある"

echo "=== 旧形式（移行期・S0 の記録）: started_at／last_result だけ → success=0 件・warn/fail=1 件（主体=本人） ==="
LEG="$WORKDIR/legacy.json"
printf '{"started_at":"2026-09-15T06:00:01Z","last_success_at":"2026-09-15T06:00:45Z","last_result":"success","last_result_summary":""}\n' > "$LEG"
python3 "$JUDGE" judge --last-run "$LEG" --inventory-latest "$FX_ROOT/S-1/latest.json" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-1/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "legacy success: OK・0 件" "OK 0" "$(jv '"\(.stage) \(.n_items)"')"
assert_eq "legacy: state=legacy" "legacy" "$(jv '.sources.maintenance.state')"
printf '{"started_at":"2026-09-15T06:00:01Z","last_success_at":"2026-09-08T06:00:44Z","last_result":"fail","last_result_summary":"旧要旨"}\n' > "$LEG"
python3 "$JUDGE" judge --last-run "$LEG" --inventory-latest "$FX_ROOT/S-1/latest.json" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-1/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "legacy fail: WARNING・1 件・id=legacy・本人" "WARNING 1 legacy 本人" "$(jv '"\(.stage) \(.n_items) \(.items[0].id) \(.items[0].actor)"')"

echo "=== plist_missing_means_no_schedule（F-11）: plist 不在／StartCalendarInterval 無し＝next_due=null・未起動 (A) 0 ==="
python3 "$JUDGE" judge --last-run "$FX_ROOT/S-21/last-run.json" --inventory-latest "$FX_ROOT/S-21/latest.json" \
  --observation "$FX_ROOT/S-21/observation.json" --recall-log "$FX_ROOT/S-21/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-21/now")" --tz Asia/Tokyo --plist /nonexistent-dir/x.plist > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "plist 不在: next_due=null" "null" "$(jv '.sources.maintenance.next_due')"
assert_eq "plist 不在: S-21 でも未起動 0（線が無い）" "OK 0" "$(jv '"\(.stage) \(.n_items)"')"
NOSCI="$WORKDIR/nosci.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>x</string></dict></plist>\n' > "$NOSCI"
python3 "$JUDGE" judge --last-run "$FX_ROOT/S-21/last-run.json" --inventory-latest "$FX_ROOT/S-21/latest.json" \
  --observation "$FX_ROOT/S-21/observation.json" --recall-log "$FX_ROOT/S-21/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-21/now")" --tz Asia/Tokyo --plist "$NOSCI" > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "StartCalendarInterval 無し: next_due=null・未起動 0" "null OK" "$(jv '"\(.sources.maintenance.next_due) \(.stage)"')"
python3 "$JUDGE" judge --last-run "$FX_ROOT/S-21/last-run.json" --inventory-latest "$FX_ROOT/S-21/latest.json" \
  --observation "$FX_ROOT/S-21/observation.json" --recall-log "$FX_ROOT/S-21/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-21/now")" --tz Asia/Tokyo --plist "$FX_ROOT/S-21/vault-recall.tsv" > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "解析不能な plist: next_due=null・rc は 0（判定機は落ちない）" "null" "$(jv '.sources.maintenance.next_due')"

echo "=== plist_wildcard_keys_and_day_or_weekday（V-13）: 省略キー＝ワイルドカード・Day と Weekday はどちらか一致 ==="
mk_plist() {   # $1=出力 $2..=<key> <int> の対
  local out="$1"; shift
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>StartCalendarInterval</key><dict>'
    while [ $# -ge 2 ]; do printf '<key>%s</key><integer>%s</integer>' "$1" "$2"; shift 2; done
    printf '</dict></dict></plist>\n'
  } > "$out"
}
wild_judge() {   # $1=plist $2=now $3=run.started_at
  local lr="$WORKDIR/wild-last-run.json"
  jq --arg s "$3" '.run.started_at = $s | .run.finished_at = $s | .completed.started_at = $s | .completed.finished_at = $s | .started_at = $s' "$FX_ROOT/S-1/last-run.json" > "$lr"
  python3 "$JUDGE" judge --last-run "$lr" --inventory-latest "$FX_ROOT/S-1/latest.json" \
    --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
    --now "$2" --tz UTC --plist "$1" > "$WORKDIR/verdict.json" 2>/dev/null
}
mk_plist "$WORKDIR/w1.plist" Minute 30                          # Hour 省略＝毎時 30 分
wild_judge "$WORKDIR/w1.plist" "2026-09-17T00:10:00Z" "2026-09-16T23:00:00Z"
assert_eq "Minute だけ: 直近の予定＝前の時の 30 分" "2026-09-16T23:30:00+00:00" "$(jv '.sources.maintenance.next_due')"
assert_eq "Minute だけ: 開始 23:00 < 予定 23:30 → 未起動 1" "1" "$(jq -r '[.items[] | select(.id == "not_started")] | length' "$WORKDIR/verdict.json")"
wild_judge "$WORKDIR/w1.plist" "2026-09-17T00:10:00Z" "2026-09-16T23:40:00Z"
assert_eq "Minute だけ: 開始 23:40 ≥ 予定 23:30 → 未起動 0" "0" "$(jq -r '[.items[] | select(.id == "not_started")] | length' "$WORKDIR/verdict.json")"
mk_plist "$WORKDIR/w2.plist" Day 15 Weekday 1 Hour 6 Minute 0   # Day か Weekday のどちらか一致
wild_judge "$WORKDIR/w2.plist" "2026-09-17T00:00:00Z" "2026-09-15T05:00:00Z"
assert_eq "Day∨Weekday: 火曜 15 日（Day 一致）が直近の予定" "2026-09-15T06:00:00+00:00" "$(jv '.sources.maintenance.next_due')"
wild_judge "$WORKDIR/w2.plist" "2026-09-15T00:00:00Z" "2026-09-13T05:00:00Z"
assert_eq "Day∨Weekday: 15 日より前なら月曜 14 日（Weekday 一致）" "2026-09-14T06:00:00+00:00" "$(jv '.sources.maintenance.next_due')"
mk_plist "$WORKDIR/w3.plist" Weekday 7 Hour 6 Minute 0          # Weekday 7＝日曜（0 と同じ）
wild_judge "$WORKDIR/w3.plist" "2026-09-15T00:00:00Z" "2026-09-13T05:00:00Z"
assert_eq "Weekday 7＝日曜" "2026-09-13T06:00:00+00:00" "$(jv '.sources.maintenance.next_due')"
mk_plist "$WORKDIR/w4.plist" Weekday 1 Hour 6 Minute 0
wild_judge "$WORKDIR/w4.plist" "2026-09-15T00:00:00Z" "2026-09-13T05:00:00Z"
python3 "$JUDGE" judge --last-run "$WORKDIR/wild-last-run.json" --inventory-latest "$FX_ROOT/S-1/latest.json" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "2026-09-15T00:00:00Z" --tz Asia/Tokyo --plist "$WORKDIR/w4.plist" > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "--tz の壁時計で解釈（JST の月曜 06:00）" "2026-09-14T06:00:00+09:00" "$(jv '.sources.maintenance.next_due')"

echo "=== judge の自身の異常＝非 0（--now が解析不能） ==="
python3 "$JUDGE" judge --last-run "$FX_ROOT/S-1/last-run.json" --inventory-latest "$FX_ROOT/S-1/latest.json" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "not-a-time" > "$WORKDIR/verdict.json" 2>"$WORKDIR/verdict.err"
assert_true "--now 不正: 非 0" "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
assert_true "--now 不正: stdout は空（JSON を出さない）" "$([ ! -s "$WORKDIR/verdict.json" ] && echo 1 || echo 0)"

echo "=== 判定の入力に旧形式の棚卸し記録（items 無し・F-8）: 1 件に畳む（N≥1）・0 なら 0 件 ==="
LEGINV="$WORKDIR/legacy-latest.json"
printf '{"date":"2026-09-15","actionable":6,"report_path":"/x/2026-09-15.md"}\n' > "$LEGINV"
python3 "$JUDGE" judge --last-run "$FX_ROOT/S-1/last-run.json" --inventory-latest "$LEGINV" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-1/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "旧形式 N=6: WARNING・1 件・kind=legacy・AI" "WARNING 1 legacy AI" "$(jv '"\(.stage) \(.n_items) \(.items[0].kind) \(.items[0].actor)"')"
assert_eq "旧形式: inventory.legacy=true・週次 ⑥ は立たない" "true" "$(jv '.sources.inventory.legacy')"
printf '{"date":"2026-09-15","actionable":0}\n' > "$LEGINV"
python3 "$JUDGE" judge --last-run "$FX_ROOT/S-1/last-run.json" --inventory-latest "$LEGINV" \
  --observation "$FX_ROOT/S-1/observation.json" --recall-log "$FX_ROOT/S-1/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-1/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "旧形式 N=0: OK・0 件" "OK 0" "$(jv '"\(.stage) \(.n_items)"')"

echo "=== ack_refused_reasons_five（F-14・§8）: running／locked／broken／no_completed／nothing_to_ack ==="
ACKD="$WORKDIR/ack"; mkdir -p "$ACKD"
ack_run() { python3 "$JUDGE" ack --last-run "$1" --note "対処した" --lock-file "${2:-/nonexistent-dir/vault-writer.lock}" --observation /nonexistent-dir/obs.json > "$WORKDIR/ack.out" 2>&1; }
# running（開始が今・余裕未満）
jq --arg s "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.run.status = "running" | .run.started_at = $s | .run.finished_at = null' "$FX_ROOT/S-2/last-run.json" > "$ACKD/running.json"
ack_run "$ACKD/running.json"
assert_true "ack running: 非 0" "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
assert_eq "ack running: 固定文" "ACK_REFUSED:running" "$(cat "$WORKDIR/ack.out")"
# locked（生存 PID＝このシェル・指紋は UNAVAILABLE＝PID 生存のみで held）
cp "$FX_ROOT/S-2/last-run.json" "$ACKD/locked.json"
printf '%s\nFINGERPRINT-UNAVAILABLE\n' "$$" > "$ACKD/vault-writer.lock"
ack_run "$ACKD/locked.json" "$ACKD/vault-writer.lock"
assert_eq "ack locked: 固定文" "ACK_REFUSED:locked" "$(cat "$WORKDIR/ack.out")"
assert_eq "ack locked: 記録は書き換えない" "null" "$(jq -r '.ack' "$ACKD/locked.json")"
# broken（JSON として解析不能）
printf '{' > "$ACKD/broken.json"
ack_run "$ACKD/broken.json"
assert_eq "ack broken: 固定文" "ACK_REFUSED:broken" "$(cat "$WORKDIR/ack.out")"
assert_eq "ack broken: 破損した記録を {} に潰さない（中身が不変）" "{" "$(cat "$ACKD/broken.json")"
# broken（型破損＝completed.run_id が run.run_id と不一致・検証 B-4）: 判定機の ④ 相当を通す＝申告を書かない
jq '.completed.run_id = "other-run-id"' "$FX_ROOT/S-2/last-run.json" > "$ACKD/broken-type.json"
ack_run "$ACKD/broken-type.json"
assert_eq "ack broken（型破損＝run_id 不一致）: 固定文" "ACK_REFUSED:broken" "$(cat "$WORKDIR/ack.out")"
assert_eq "ack broken（型破損）: 記録は書き換えない（ack が null のまま）" "null" "$(jq -r '.ack' "$ACKD/broken-type.json")"
# broken（型破損＝run.stale_after_seconds が無い・running 中でも表示状態を決めない＝検証 B-1）
jq 'del(.run.stale_after_seconds) | .run.status = "running" | .run.started_at = "2026-09-15T06:00:01Z" | .run.finished_at = null' "$FX_ROOT/S-2/last-run.json" > "$ACKD/broken-nostale.json"
ack_run "$ACKD/broken-nostale.json"
assert_eq "ack broken（stale_after_seconds 無し）: 固定文" "ACK_REFUSED:broken" "$(cat "$WORKDIR/ack.out")"
# no_completed（run.status=skipped で completed が無い＝completed が一度も書かれていない記録。
# run.status=completed のまま completed を消すと型破損＝broken になる＝上のケースと区別する）
jq 'del(.completed) | .run.status = "skipped"' "$FX_ROOT/S-2/last-run.json" > "$ACKD/nocompleted.json"
ack_run "$ACKD/nocompleted.json"
assert_eq "ack no_completed: 固定文" "ACK_REFUSED:no_completed" "$(cat "$WORKDIR/ack.out")"
# nothing_to_ack（fully_ok=true・steps 空）
cp "$FX_ROOT/S-1/last-run.json" "$ACKD/nothing.json"
ack_run "$ACKD/nothing.json"
assert_eq "ack nothing_to_ack: 固定文" "ACK_REFUSED:nothing_to_ack" "$(cat "$WORKDIR/ack.out")"
# 受理＝S-2 の記録に書ける（run_id＝completed.run_id・失効前の形）
cp "$FX_ROOT/S-2/last-run.json" "$ACKD/ok.json"
python3 "$JUDGE" ack --last-run "$ACKD/ok.json" --note "一時ロックを解除した" --session-id sess-ack-9 --lock-file /nonexistent-dir/lock > "$WORKDIR/ack.out" 2>&1
assert_eq "ack 受理: rc=0" "0" "$?"
assert_eq "ack 受理: ACK_WRITTEN 固定文" "ACK_WRITTEN:$(jq -r '.completed.run_id' "$FX_ROOT/S-2/last-run.json")" "$(cat "$WORKDIR/ack.out")"
assert_eq "ack 受理: ack.run_id＝completed.run_id" "$(jq -r '.completed.run_id' "$ACKD/ok.json")" "$(jq -r '.ack.run_id' "$ACKD/ok.json")"
assert_eq "ack 受理: note・session_id" "一時ロックを解除した sess-ack-9" "$(jq -r '"\(.ack.note) \(.ack.session_id)"' "$ACKD/ok.json")"
assert_eq "ack 受理: 旧 6 キーはそのまま" "$(jq -r '.last_result' "$FX_ROOT/S-2/last-run.json")" "$(jq -r '.last_result' "$ACKD/ok.json")"
# 申告後に判定機で読むと pending（S-11 と同じ）
python3 "$JUDGE" judge --last-run "$ACKD/ok.json" --inventory-latest "$FX_ROOT/S-2/latest.json" \
  --observation "$FX_ROOT/S-2/observation.json" --recall-log "$FX_ROOT/S-2/vault-recall.tsv" \
  --now "$(cat "$FX_ROOT/S-2/now")" --tz Asia/Tokyo > "$WORKDIR/verdict.json" 2>/dev/null
assert_eq "ack 受理→判定: WARNING のまま・ack.state=pending" "WARNING pending" "$(jv '"\(.stage) \(.items[0].ack.state)"')"

echo "=== ack_session_id_from_observation（V-7）: --session-id 省略時は観測記録の session_id・観測記録も無ければ null ==="
cp "$FX_ROOT/S-2/last-run.json" "$ACKD/sid.json"
python3 "$JUDGE" ack --last-run "$ACKD/sid.json" --note "n" --observation "$FX_ROOT/S-2/observation.json" --lock-file /nonexistent-dir/lock > /dev/null 2>&1
assert_eq "ack: 観測記録の session_id が入る" "sess-cur-0002" "$(jq -r '.ack.session_id' "$ACKD/sid.json")"
cp "$FX_ROOT/S-2/last-run.json" "$ACKD/sid2.json"
python3 "$JUDGE" ack --last-run "$ACKD/sid2.json" --note "n" --observation /nonexistent-dir/obs.json --lock-file /nonexistent-dir/lock > /dev/null 2>&1
assert_eq "ack: 観測記録が無ければ session_id=null（申告は成立）" "null" "$(jq -r '.ack.session_id' "$ACKD/sid2.json")"
# --observation 省略時は HEALTH_OBSERVATION_FILE env が fixture へ向けば拾える（検証 B-5）
cp "$FX_ROOT/S-2/last-run.json" "$ACKD/sid3.json"
HEALTH_OBSERVATION_FILE="$FX_ROOT/S-2/observation.json" python3 "$JUDGE" ack --last-run "$ACKD/sid3.json" --note "n" --lock-file /nonexistent-dir/lock > /dev/null 2>&1
assert_eq "ack: --observation 省略時は HEALTH_OBSERVATION_FILE env から session_id が拾える" "sess-cur-0002" "$(jq -r '.ack.session_id' "$ACKD/sid3.json")"

echo "=== 秘匿（NFR-4）: 出力に env の値を写さない（判定機は記録の値だけを載せる） ==="
SECRET_MARK="SECRET-MARK-$$"
AWS_SECRET_ACCESS_KEY="$SECRET_MARK" judge_fixture S-2
assert_not_contains "S-2: env の値が出力に現れない" "$(cat "$WORKDIR/verdict.json")" "$SECRET_MARK"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
