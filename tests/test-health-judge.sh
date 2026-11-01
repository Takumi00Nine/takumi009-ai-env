#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JUDGE="$SCRIPT_DIR/../ai-brain/executor/health_judge.py"
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
item() { jq -r ".items[$1]$2" "$WORKDIR/verdict.json"; }   # item <index> <jq path>
echo "=== 正常判定のJSON契約 ==="
judge_fixture S-1
assert_eq "S-1: rc=0" "0" "$?"
assert_eq "S-1: schema" "health-verdict/1" "$(jv '.schema')"
assert_eq "S-1: stage=OK" "OK" "$(stage)"
assert_eq "S-1: maintenance.state" "completed" "$(jv '.sources.maintenance.state')"
echo "=== 失敗の判定と理由の逐語保持 ==="
judge_fixture S-2
assert_eq "失敗の判定と結果種別" "WARNING 失敗" "$(jv '"\(.stage) \(.items[0].result)"')"
assert_eq "S-2: ② 理由が書き手の記録どおり" "$(jq -r '.completed.steps[0].reason' "$FX_ROOT/S-2/last-run.json")" "$(item 0 .reason)"
echo "=== 中断の判定 ==="
judge_fixture S-4
assert_eq "S-4: state=interrupted" "interrupted" "$(jv '.sources.maintenance.state')"
assert_eq "S-4: 結果種別=中断" "中断" "$(item 0 .result)"
echo "=== 破損の判定 ==="
judge_fixture S-5
assert_eq "S-5: state=broken" "broken" "$(jv '.sources.maintenance.state')"
echo "=== 未起動の判定 ==="
judge_fixture S-21
assert_eq "S-21: id=not_started" "not_started" "$(item 0 .id)"
assert_eq "S-21: 結果種別=未起動" "未起動" "$(item 0 .result)"
assert_contains "S-21: 「予定時刻を過ぎて開始していない」と読める" "$(item 0 .reason)" "予定時刻を過ぎて開始していない"
echo "=== 必読ノートが読めなければERROR ==="
judge_fixture S-15
assert_eq "S-15: stage=ERROR" "ERROR" "$(stage)"
echo "=== 環境の秘密値を出力しない ==="
SECRET_MARK="SECRET-MARK-$$"
AWS_SECRET_ACCESS_KEY="$SECRET_MARK" judge_fixture S-2
assert_not_contains "S-2: env の値が出力に現れない" "$(cat "$WORKDIR/verdict.json")" "$SECRET_MARK"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
