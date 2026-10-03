#!/usr/bin/env bash
# 着手ゲート B1（設計 v1.2 §7）＝束 B の基準（FX-2）を固定し、要件 v1.2 FX-9 (a)〜(d) を
# 基準側の経路（メンテ・Usage・UserPromptSubmit フック・`cmux notify` 直）で 2 回流して、
# v1.1 の「比較から除く値」（tests/closing/normalize-rules.tsv）で 2 回の結果が一致することを確かめる。
# 束 B は未着手（FX-1 は存在しない）なので基準側だけを見る。合格条件＝下の `gate-b1: ok` 行。
#
# 使い方: bash tests/closing/gate-b1.sh [<基準コミット>]（既定＝このファイルの repo の現在の HEAD）
# 安全: 基準は使い捨ての worktree（終了時に remove）。HOME は一時ディレクトリ・PATH 先頭に偽
#   launchctl・osascript・cmux・CODE27 取次（消去）。SKIP_LAUNCHCTL=1・LAUNCHCTL_TIMEOUT_SECS=1。
#   実 $HOME・実 cmux・実 launchd・実 CODE27 には書かない。

set -uo pipefail
CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-closing.sh
. "$CL_HERE/lib-closing.sh"

CL_SRC="$(cd "$CL_HERE/../.." && git rev-parse --show-toplevel)"
BASE_COMMIT="$(git -C "$CL_SRC" rev-parse --verify "${1:-HEAD}^{commit}")" || { echo "基準コミットが無い: ${1:-HEAD}" >&2; exit 2; }
FX1_COMMIT="$BASE_COMMIT"   # B1 は基準側だけを見る（FX-1＝束 B 未着手）。cl_norm の既定置換が参照するだけで使わない。

OUT="$CL_HERE/out/gate-b1-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
WORK="$(cl_realpath "$(mktemp -d "${TMPDIR:-/tmp}/gate-b1.XXXXXX")")"
WT0="$WORK/wt0"; WT1=""
cleanup() {
  chmod -R u+w "$WT0" "$WORK" 2>/dev/null
  git -C "$CL_SRC" worktree remove --force "$WT0" >/dev/null 2>&1 || true
  git -C "$CL_SRC" worktree prune >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! why="$(cl_check_env)"; then echo "環境が FX-6 の前提を満たさない:$why" >&2; exit 2; fi
git -C "$CL_SRC" worktree add -q --detach "$WT0" "$BASE_COMMIT" || { echo "基準の worktree を作れない" >&2; exit 2; }

CL_SUBS=("$WORK/home=<HOME>" "$WORK=<WORK>" \
  "$BASE_COMMIT=<COMMIT>" "$(git -C "$CL_SRC" rev-parse --short "$BASE_COMMIT")=<COMMIT>" "${BASE_COMMIT:0:7}=<COMMIT>")

# FX-9 (a)〜(d) を基準側の経路で 1 回流す（$1＝出力先ディレクトリ）。
gate_b1_emit() {
  local rd="$1" h s V rc
  mkdir -p "$rd"
  h="$rd/home"; s="$rd/stub"; rm -rf "$h" "$s"; mkdir -p "$h"; cl_stubs "$s"
  # 偽 CODE27 取次（消去・発話）＝共有雛形 tests/fixtures/code27-call/（B が最小を作った＝README 参照）
  mkdir -p "$s/c27"
  cp -R "$CL_DIR/../fixtures/code27-call/bin" "$s/c27/bin"
  : > "$s/c27/calls.log"

  # --- (a) メンテが異常ありで終わる入力（Vault の branch を main 以外にして backup-vault.sh を失敗させる＝Phase0 中断）
  V="$h/$CLOSING_VAULT_REL"; cl_mk_vault_fx5 "$V"
  git -C "$V" checkout -q -b other-branch
  rc=0
  cl_run "$h" "$s" "$WT0" AIENV_REPO="$WT0" "$WT0/$CLOSING_MAINT_OLD" </dev/null >"$rd/a.stdout" 2>"$rd/a.stderr" || rc=$?
  printf '%s\n' "$rc" > "$rd/a.rc"

  # --- (b) Usage の取得で警告の閾値（既定 80）を超える固定の取得結果
  rc=0
  cl_run "$h" "$s" "$WT0" "$(cl_path "$s" "$CL_FIX/usage-bin")" \
    STUB_CURL_STATUS=200 \
    STUB_CURL_BODY='{"five_hour":{"used_percent":85,"resets_at":"2026-09-09T00:00:00Z"},"seven_day":{"used_percent":85,"resets_at":"2026-09-14T00:00:00Z"}}' \
    STUB_SECURITY_JSON='{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":99999999999999}}' \
    STUB_CODEX_RESULT_LINE="$(cat "$CL_FIX/usage-bin/codex_success_result_line.json")" \
    "$WT0/$CLOSING_USAGE_FETCH_OLD" </dev/null >"$rd/b.stdout" 2>"$rd/b.stderr" || rc=$?
  printf '%s\n' "$rc" > "$rd/b.rc"

  # --- (c) UserPromptSubmit の stdin 2 件（同じ HOME・同じセッション＝1 件目だけ消去が起きる）
  rc=0
  printf '{"session_id":"s1","prompt":"了解"}' | cl_run "$h" "$s" "$WT0" CODE27_CALL_BIN="$s/c27/bin/code27-call-clear" \
    "$WT0/claude/hooks/code27-call-clear.sh" >"$rd/c1.stdout" 2>"$rd/c1.stderr" || rc=$?
  printf '%s\n' "$rc" > "$rd/c1.rc"
  cp "$s/c27/calls.log" "$rd/c1.calls"
  rc=0
  printf '{"session_id":"s1","prompt":"<task-notification>x"}' | cl_run "$h" "$s" "$WT0" CODE27_CALL_BIN="$s/c27/bin/code27-call-clear" \
    "$WT0/claude/hooks/code27-call-clear.sh" >"$rd/c2.stdout" 2>"$rd/c2.stderr" || rc=$?
  printf '%s\n' "$rc" > "$rd/c2.rc"
  cp "$s/c27/calls.log" "$rd/c2.calls"

  # --- (d) 📣 の呼出 1 件（基準側＝`cmux notify` を直接）
  rc=0
  cl_run "$h" "$s" "$WT0" cmux notify --title "📣 テスト呼出" --body "本文" >"$rd/d.stdout" 2>"$rd/d.stderr" || rc=$?
  printf '%s\n' "$rc" > "$rd/d.rc"
  cp "$s/calls.log" "$rd/d.calls"
}

echo "1 回目を実行..." >&2
gate_b1_emit "$WORK/run1"
echo "2 回目を実行..." >&2
gate_b1_emit "$WORK/run2"

bad=""
for label in a b c1 c2 d; do
  for f in rc stdout calls; do
    p1="$WORK/run1/$label.$f"; p2="$WORK/run2/$label.$f"
    [ -f "$p1" ] || : > "$p1"; [ -f "$p2" ] || : > "$p2"
    n1="$OUT/run1-$label.$f.n"; n2="$OUT/run2-$label.$f.n"
    cl_norm base "$WORK/run1" < "$p1" > "$n1"
    cl_norm base "$WORK/run2" < "$p2" > "$n2"
    if ! diff -u "$n1" "$n2" > "$OUT/$label.$f.diff"; then
      bad="$bad $label.$f"
    fi
  done
done

# 追加の確認（要件 AC-2 の判定文言の下敷き＝記録の内容そのもの。B1 自体の合否は上の一致判定）
{
  echo "--- (a) メンテ rc / osascript 記録"
  cat "$WORK/run1/a.rc"; grep -c . "$WORK/run1/stub/calls.log" 2>/dev/null
  echo "--- (b) Usage rc / osascript 記録"
  cat "$WORK/run1/b.rc"
  echo "--- (c) CODE27 消去 記録数（1件目のみ 1 のはず）"
  grep -c . "$WORK/run1/c1.calls"; grep -c . "$WORK/run1/c2.calls"
  echo "--- (d) cmux 記録"
  cat "$WORK/run1/d.calls"
} > "$OUT/observation.txt" 2>&1

echo "詳細: $OUT"
if [ -z "$bad" ]; then
  echo "gate-b1: ok（2 回の結果が normalize-rules.tsv の正規化後に一致）"
  exit 0
else
  echo "gate-b1: NG（不一致:$bad ＝ $OUT/<label>.<種別>.diff）"
  exit 1
fi
