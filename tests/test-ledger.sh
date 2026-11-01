#!/usr/bin/env bash
# 台帳検査の合否・lookup/route/placement・選択の fail-close。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"
LEDGER="$REPO_ROOT/$LF_LEDGER_REL"
TOOL="$REPO_ROOT/$LF_LEDGER_TOOL_REL"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
lf_mk_fx6 "$WORK/stub"
export HOME="$WORK/home" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 PATH="$WORK/stub:$PATH"
mkdir -p "$HOME"


# run_check <repo ルート> — その repo の台帳ツールで check。出力を $WORK/check.out、終了コードを CHECK_RC に。
run_check() {
  CHECK_RC=0
  bash "$1/$LF_LEDGER_TOOL_REL" check > "$WORK/check.out" 2>"$WORK/check.err" || CHECK_RC=$?
}

# 台帳検査は整合した隔離 fixture を土台にする。
BASE="$WORK/base"
lf_copy_repo "$REPO_ROOT" "$BASE"
# 退役で消えたスイートの行は fixture に持ち込まない。実台帳の掃除はリーダーが行う。
python3 - "$BASE" "$LF_LEDGER_REL" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); p=root/sys.argv[2]
rows=p.read_text().splitlines(True)
p.write_text(''.join(row for row in rows if not (
    row.startswith('suite\t') and not (root/row.split('\t')[1]).is_file()
)))
PY
lf_commit_all "$BASE"
echo "=== 台帳検査の正常系 ==="
run_check "$BASE"
assert_true "整合した台帳は検査に合格する" "$([[ "$CHECK_RC" -eq 0 && ! -s "$WORK/check.out" ]] && echo 1 || echo 0)"

echo "=== 台帳に無い部品を検出する ==="
printf '#!/bin/bash\n:\n' > "$BASE/ai-brain/executor/zz-unlisted.sh"
chmod +x "$BASE/ai-brain/executor/zz-unlisted.sh"
lf_commit_all "$BASE"
run_check "$BASE"
assert_true "未登録部品は不合格・対象パスを報告" \
  "$([ "$CHECK_RC" -ne 0 ] && grep -q '^part ai-brain/executor/zz-unlisted.sh ' "$WORK/check.out" && echo 1 || echo 0)"

echo "=== 照会の成功・鍵なし・台帳異常・実体異常 ==="
rc=0; out="$(bash "$TOOL" lookup core.ledger 2>"$WORK/lookup.err")" || rc=$?
assert_true "鍵から実行可能な部品を引ける" "$([[ "$rc" -eq 0 && -x "$out" && ! -s "$WORK/lookup.err" ]] && echo 1 || echo 0)"
rc=0; out="$(bash "$TOOL" lookup zz.missing 2>"$WORK/lookup.err")" || rc=$?
assert_true "鍵なしは rc1・出力なし" "$([[ "$rc" -eq 1 && -z "$out" && ! -s "$WORK/lookup.err" ]] && echo 1 || echo 0)"
rc=0; out="$(AIENV_LEDGER="$WORK/missing.tsv" bash "$TOOL" lookup core.ledger 2>"$WORK/lookup.err")" || rc=$?
assert_true "台帳異常は rc2・理由を示す" "$([[ "$rc" -eq 2 && -z "$out" ]] && grep -q '^LEDGER: ledger ' "$WORK/lookup.err" && echo 1 || echo 0)"
cp "$LEDGER" "$WORK/bad-part.tsv"
printf 'part\tai-brain/executor/zz-missing.sh\tai-brain\texecutor\t-\tzz.missing\t-\t-\t-\n' >> "$WORK/bad-part.tsv"
rc=0; out="$(AIENV_LEDGER="$WORK/bad-part.tsv" bash "$TOOL" lookup zz.missing 2>"$WORK/lookup.err")" || rc=$?
assert_true "実体異常は rc3・理由を示す" "$([[ "$rc" -eq 3 && -z "$out" ]] && grep -q '^LEDGER: part zz.missing ' "$WORK/lookup.err" && echo 1 || echo 0)"

echo "=== route と placement の形 ==="
rc=0; out="$(bash "$TOOL" route call.alert)" || rc=$?
assert_true "知らせの経路を照会できる" "$([[ "$rc" -eq 0 && -n "$out" ]] && echo 1 || echo 0)"
rc=0; out="$(bash "$TOOL" placement --all)" || rc=$?
assert_true "配置一覧は4列" "$([ "$rc" -eq 0 ] && printf '%s\n' "$out" | awk -F'\t' 'NF!=4 {bad=1} END{exit bad || NR==0}' && echo 1 || echo 0)"

echo "=== 選択が照会と配置へ反映される ==="
printf 'AIENV_COMPONENTS=core\n' > "$WORK/components.env"
rc=0
AIENV_COMPONENTS_FILE="$WORK/components.env" bash "$TOOL" lookup team.codex-exec >"$WORK/selected.out" 2>/dev/null || rc=$?
assert_true "選択外の鍵は無いものとして扱う" "$([[ "$rc" -eq 1 && ! -s "$WORK/selected.out" ]] && echo 1 || echo 0)"
out="$(AIENV_COMPONENTS_FILE="$WORK/components.env" bash "$TOOL" placement)"
assert_true "選択外を配置しない" "$(printf '%s\n' "$out" | awk -F'\t' '$4!="core" {bad=1} END{exit bad || NR==0}' && echo 1 || echo 0)"
printf 'AIENV_COMPONENTS=zz-invalid\n' > "$WORK/components.env"
rc=0; out="$(AIENV_COMPONENTS_FILE="$WORK/components.env" bash "$TOOL" lookup core.ledger 2>"$WORK/lookup.err")" || rc=$?
assert_true "不正な選択では全部入りへ戻らず拒否する" "$([[ "$rc" -eq 2 && -z "$out" ]] && grep -q '^LEDGER: ledger ' "$WORK/lookup.err" && echo 1 || echo 0)"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
