#!/usr/bin/env bash
# 疎結合の受入（Core）＝受入① AI Brain は Claude Code 抜きで shell から使える・受入② 提供元の追加は
# 接続フォルダ 1 つと台帳の行で済む・受入③ AI Brain＋Core だけでも 4 入口が働く。
# 正本＝docs/v1.1-components の要件 v1.5 §7（AC-1 ①〜④・AC-2 ①②⑤・AC-5 ②・FX-3〜8・FX-10・FX-11）・
# 設計 v1.4 §10.3・§13。AC-2 ③④・AC-5 ① は締めの実走（tests/closing/）が見る。
# v1.2 束 C（台帳駆動の組立・転送の撤去）＝要件 v1.4 §7 AC-9・FX-12 ZZ・設計 v1.4 §3.2・リーダー裁定録
# leader-rulings-v1.2.md「束 C 着手ゲート」ゲート①レビュー X-06（zz-cli fixture から移動表の行の追加を外す）。
#
# 実行方法: bash tests/test-decoupling.sh
#
# 契約（テストが決めた口。台帳と台帳ツールの口は tests/test-ledger.sh 冒頭の契約と同じ）:
#   AI Brain の 4 入口＝台帳の鍵 ai-brain.recall・ai-brain.bootstrap・ai-brain.backup・ai-brain.maintenance を
#   その複製の台帳ツール `lookup` で引いて起動する（実装計画 §3）。
#   入口の上書き口（現行名のまま）＝想起 VAULT_RECALL_VAULT・VAULT_RECALL_LOG／読込 BOOTSTRAP_VAULT／
#   バックアップ VAULT・LOCK_FILE・VAULT_WRITER_LOCK_FILE／メンテ VAULT・AIENV_REPO（状態記録は
#   $HOME/.claude/logs/maintenance/last-run.json＝README「状態記録の契約」）。
#   zz-cli 接続＝共有の雛形 tests/fixtures/zz-cli/connect/（変換シム・登録雛形・配置手順の 3 点。書式は
#   同フォルダの README.md）を ai-brain/connect/zz-cli/ へ丸ごと写し、変換シムの __RECALL_REL__ を
#   想起の実行器への相対パス（../../executor/vault-recall.sh）に置き換える。
#   台帳の行＝ファイルごと 3 行（フォルダ単位の 1 行にはしない＝フォルダは実行可能でなく `run` を持てない
#   ・実装計画 §2）。recall-shim.sh・register.tmpl は配置 `-`、install.sh は配置 `run:$HOME/.zz-cli/`
#   （v1.2 FR-13・AC-9）。移動表には行を足さない（v1.2 FR-20＝v1.1 の後の新規部品に移動表の行を求めない。
#   X-06＝旧版は移動表にも由来行を足していたが FR-20 と矛盾するため外した）。
# 隔離: HOME＝空の一時ディレクトリ（FX-3）・PATH 先頭に FX-6 の偽物・PATH に claude／codex 無し・
#   Vault＝一時の複製（FX-4／FX-5）・repo＝一時の複製（FX-7／FX-8）。実 HOME・実 Vault・実 repo に書かない。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれない: \"$3\")"; fi; }

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
lf_mk_fx6 "$WORK/stub"
NOCLI_PATH="$WORK/stub:$(lf_path_without claude codex)"
BASE="$WORK/base"
lf_copy_repo "$REPO_ROOT" "$BASE"
VAULT_PUBLIC_REL="$(lf_ledger_paths "$BASE/$LF_LEDGER_REL" '$1=="part" && $2 ~ /ai-brain\/data\/vault-public\/$/' 2>/dev/null | head -1)"

echo "=== 0. 前提: FX-6 の PATH に claude・codex が無い ==="
assert_true "command -v claude が非 0" "$(PATH="$NOCLI_PATH" command -v claude >/dev/null 2>&1 && echo 0 || echo 1)"
assert_true "command -v codex が非 0" "$(PATH="$NOCLI_PATH" command -v codex >/dev/null 2>&1 && echo 0 || echo 1)"
assert_true "台帳に公開スナップショット（ai-brain/data/vault-public/）の行がある（FX-4 の元）" "$([ -n "$VAULT_PUBLIC_REL" ] && echo 1 || echo 0)"

# entry <repo> <鍵> — その複製の台帳ツールで入口のパスを引く（1 行目）。
entry() { bash "$1/$LF_LEDGER_TOOL_REL" lookup "$2" 2>/dev/null | head -1; }

# brain_judge <repo> <ラベル> — AI Brain 判定（AC-1 ①〜④）。毎回 新しい HOME（FX-3）と Vault の複製を使う。
brain_judge() {
  local repo="$1" label="$2" e out rc fx4 fx5 n0 n1 th
  # 引数の先頭の VAR=値（入口ごとの上書き口）も環境変数として渡すため env を通す。
  run_env() { HOME="$th" PATH="$NOCLI_PATH" LOCK_FILE="$th/backup.lock" \
      VAULT_WRITER_LOCK_FILE="$th/vault-writer.lock" env "$@"; }
  [ -n "$VAULT_PUBLIC_REL" ] || { fail_case "$label: FX-4 の元（ai-brain/data/vault-public/）が台帳で引けない"; return; }

  th="$WORK/$label-home1"; mkdir -p "$th"; fx4="$WORK/$label-fx4"
  lf_mk_fx4 "$repo/$VAULT_PUBLIC_REL" "$fx4"
  e="$(entry "$repo" ai-brain.recall)"
  assert_true "$label ①: 想起の入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  rc=0; out="$(printf '%s' '{"session_id":"s1","prompt":"想起プローブ甲 について"}' \
    | run_env VAULT_RECALL_VAULT="$fx4" VAULT_RECALL_LOG="$th/vault-recall.tsv" bash "${e:-/nonexistent}")" || rc=$?
  assert_eq "$label ① FX-17: exit 0" "0" "$rc"
  assert_contains "$label ① FX-17: additionalContext に Knowledge/zz-probe.md" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" "Knowledge/zz-probe.md"
  rc=0; out="$(printf '%s' '{"session_id":"s1","prompt":"今日の天気"}' \
    | run_env VAULT_RECALL_VAULT="$fx4" VAULT_RECALL_LOG="$th/vault-recall.tsv" bash "${e:-/nonexistent}")" || rc=$?
  assert_eq "$label ① FX-18: exit 0" "0" "$rc"
  assert_eq "$label ① FX-18: stdout 空" "" "$out"

  th="$WORK/$label-home2"; mkdir -p "$th"
  e="$(entry "$repo" ai-brain.bootstrap)"
  assert_true "$label ②: 読込の入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  rc=0; out="$(printf '{}' | run_env BOOTSTRAP_VAULT="$fx4" bash "${e:-/nonexistent}")" || rc=$?
  assert_eq "$label ②: exit 0" "0" "$rc"
  assert_contains "$label ②: additionalContext に Preferences/absolute-rules.md" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" "Preferences/absolute-rules.md"

  th="$WORK/$label-home3"; mkdir -p "$th"; fx5="$WORK/$label-fx5"
  lf_mk_fx5 "$repo/$VAULT_PUBLIC_REL" "$fx5"
  e="$(entry "$repo" ai-brain.backup)"
  assert_true "$label ③: バックアップの入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  n0="$(git -C "$fx5" rev-list --count HEAD 2>/dev/null)"
  rc=0; run_env VAULT="$fx5" bash "${e:-/nonexistent}" >/dev/null 2>&1 || rc=$?
  n1="$(git -C "$fx5" rev-list --count HEAD 2>/dev/null)"
  assert_eq "$label ③: exit 0" "0" "$rc"
  assert_eq "$label ③: FX-5 のコミット数が 1 増える" "$((n0 + 1))" "$n1"

  th="$WORK/$label-home4"; mkdir -p "$th"; fx5="$WORK/$label-fx5m"
  lf_mk_fx5 "$repo/$VAULT_PUBLIC_REL" "$fx5"
  e="$(entry "$repo" ai-brain.maintenance)"
  assert_true "$label ④: メンテの入口を台帳で引ける" "$([ -n "$e" ] && [ -f "$e" ] && echo 1 || echo 0)"
  run_env VAULT="$fx5" AIENV_REPO="$repo" bash "${e:-/nonexistent}" >/dev/null 2>&1
  local lr="$th/.claude/logs/maintenance/last-run.json"
  assert_eq "$label ④: run.status＝completed" "completed" "$(jq -r '.run.status' "$lr" 2>/dev/null)"
  # HOME は空から始めた＝記録は今回の実行だけが書いた。completed が今回の run のもの。
  assert_true "$label ④: completed が今回の run（completed.run_id＝run.run_id）" \
    "$(jq -e '.completed.run_id != null and .completed.run_id == .run.run_id' "$lr" >/dev/null 2>&1 && echo 1 || echo 0)"
}

echo "=== 1. AC-1 受入①: FX-7（Claude Code の接続フォルダを全機能分除いた複製）で AI Brain 判定 ==="
FX7="$WORK/fx7"; cp -a "$BASE" "$FX7"
for func in $(lf_ledger_paths "$BASE/$LF_LEDGER_REL" '$4=="connect" && $5=="claude-code"' 2>/dev/null | cut -d/ -f1 | sort -u); do
  rm -rf "$FX7/$func/connect/claude-code"
done
assert_eq "FX-7: Claude Code の接続フォルダが残っていない" "" "$(cd "$FX7" && ls -d */connect/claude-code 2>/dev/null)"
brain_judge "$FX7" "FX-7"

echo "=== 2. AC-5 ② 受入③: FX-8（AI Brain と Core だけ）で AI Brain 判定 ==="
FX8="$WORK/fx8"; cp -a "$BASE" "$FX8"
rm -rf "$FX8/team" "$FX8/usage" "$FX8/notify" "$FX8/dock" "$FX8"/*/connect/claude-code
assert_true "FX-8: 機能フォルダは ai-brain と core だけ" \
  "$([ -d "$FX8/ai-brain" ] && [ -d "$FX8/core" ] && [ ! -e "$FX8/team" ] && [ ! -e "$FX8/dock" ] && echo 1 || echo 0)"
brain_judge "$FX8" "FX-8"

echo "=== 3. AC-2 受入② ①②: FX-10（AI Brain の zz-cli 接続フォルダ＋台帳の行）＝式 A 0 行・台帳の突合が合格 ==="
# mk_zz_connect <repo> — 共有の雛形を接続フォルダへ写し、台帳へファイルごとの行を足す（コミットはしない
# ＝式 A が見る差分）。X-06（ゲート①レビュー）＝移動表の行は足さない（v1.2 FR-20）。
ZZ_TEMPLATE="$TESTS_DIR/fixtures/zz-cli/connect"
ZZ_PATH="ai-brain/connect/zz-cli/"
ZZ_PATH_RECALL="ai-brain/connect/zz-cli/recall-shim.sh"
ZZ_PATH_TMPL="ai-brain/connect/zz-cli/register.tmpl"
ZZ_PATH_INSTALL="ai-brain/connect/zz-cli/install.sh"
ZZ_LEDGER_LINES=$'part\t'"$ZZ_PATH_RECALL"$'\tai-brain\tconnect\tzz-cli\t-\t偽 zz-cli 変換シム（試験）\t-\t-\npart\t'"$ZZ_PATH_TMPL"$'\tai-brain\tconnect\tzz-cli\t-\t偽 zz-cli 登録雛形（試験）\t-\t-\npart\t'"$ZZ_PATH_INSTALL"$'\tai-brain\tconnect\tzz-cli\t-\t偽 zz-cli 配置手順（試験・AC-9）\t-\trun:$HOME/.zz-cli/'
# mk_zz_connect <repo> — 共有の雛形を接続フォルダへ写し、台帳（2 列目のパス）に install.sh の行が
# 無ければファイルごと 3 行を足す（フォルダ単位 1 行にはしない＝フォルダは実行可能でなく `run` を
# 持てない・実装計画 §2）。鍵は持たず、備考など他列が違う行（締めの実走が別に足すものを含む）が
# 既にあっても重ねない。
mk_zz_connect() {
  local d="$1/ai-brain/connect/zz-cli"
  mkdir -p "$d"
  cp -p "$ZZ_TEMPLATE"/* "$d"/
  sed -i '' 's#__RECALL_REL__#../../executor/vault-recall.sh#' "$d/recall-shim.sh"
  cut -f2 "$1/$LF_LEDGER_REL" | grep -qxF -- "$ZZ_PATH_INSTALL" || printf '%s\n' "$ZZ_LEDGER_LINES" >> "$1/$LF_LEDGER_REL"
}
# 式 A（要件 §7 の形のまま。<…> を設計で決まったパスに置き換えたもの）。移動表は触らない
# （X-06＝接続フォルダの追加は台帳の行だけで閉じる・移動表は対象外）。
formula_a() {
  git -C "$1" status --porcelain --untracked-files=all \
    | cut -c4- \
    | grep -vE '^ai-brain/connect/zz-cli/' \
    | grep -vxF "$LF_LEDGER_REL"
}
FX10="$WORK/fx10"; cp -a "$BASE" "$FX10"
mk_zz_connect "$FX10"
assert_eq "AC-2 ① FX-10: 式 A の出力 0 行" "" "$(formula_a "$FX10")"
TH="$WORK/home-check"; mkdir -p "$TH"
check_out="$(HOME="$TH" PATH="$WORK/stub:$PATH" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 \
  bash "$FX10/$LF_LEDGER_TOOL_REL" check 2>/dev/null)"; check_rc=$?
assert_true "AC-2 ② FX-10: 台帳ツールが動いた（終了 127 でない）" "$([ "$check_rc" != "127" ] && [ -f "$FX10/$LF_LEDGER_TOOL_REL" ] && echo 1 || echo 0)"
assert_eq "AC-2 ② FX-10: AC-3 ① の突合（part・suite）に不合格行なし" "" "$(printf '%s\n' "$check_out" | grep -E '^(part|suite) ' || true)"

echo "=== 4. AC-2 ⑤: FX-11（FX-10＋接続外の追跡ファイル 1 本に 1 行）＝式 A がそのパス 1 行 ==="
FX11="$WORK/fx11"; cp -a "$BASE" "$FX11"
mk_zz_connect "$FX11"
printf '\n' >> "$FX11/README.md"
assert_eq "AC-2 ⑤ FX-11: 式 A の出力＝README.md の 1 行" "README.md" "$(formula_a "$FX11")"

echo "=== 5. v1.2 束 C AC-9（FX-12 ZZ）: 台帳の行だけで zz-cli の配置が全部入りの組立に自動で乗る ==="
{
  # make_home_for_install <home> — 組立に要る最小の実体プロファイル＋モデル定義（test-install-main.sh と同じ流儀）。
  make_home_for_install() {
    local home="$1"
    mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex" "$home/.config/takumi009-ai-env"
    cat > "$home/.config/takumi009-ai-env/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5
EOF
    cat > "$home/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: test-decoupling-ac9
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-sonnet-high
---
EOF
  }

  FX12="$WORK/fx12"; cp -a "$BASE" "$FX12"
  mk_zz_connect "$FX12"
  assert_eq "AC-9 前提（X-06）: 式 A（zz-cli 接続フォルダと台帳を除外）0 行＝移動表・組立・配置の健全性検査の部品は無変更" \
    "" "$(formula_a "$FX12")"

  TH12="$WORK/ac9-home"; mkdir -p "$TH12"
  make_home_for_install "$TH12"
  rc=0
  INSTALL_OUT="$(HOME="$TH12" PATH="$WORK/stub:$PATH" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 \
    bash "$FX12/core/assembly/install-main.sh" 2>&1)" || rc=$?
  assert_eq "AC-9 ①: 全部入りの組立（台帳の行だけで zz-cli を拾う）は exit 0" "0" "$rc"

  ZZBIN="$WORK/zzbin"; mkdir -p "$ZZBIN"
  cp "$TESTS_DIR/fixtures/zz-cli/zz-cli" "$ZZBIN/zz-cli"; chmod +x "$ZZBIN/zz-cli"
  FX4_AC9="$WORK/ac9-fx4"
  lf_mk_fx4 "$FX12/$VAULT_PUBLIC_REL" "$FX4_AC9"
  rc=0
  ZZ_OUT="$(HOME="$TH12" PATH="$ZZBIN:$PATH" VAULT_RECALL_VAULT="$FX4_AC9" "$ZZBIN/zz-cli" "想起プローブ甲 について" 2>&1)" || rc=$?
  assert_eq "AC-9 ①: zz-cli <問い合わせ文> は exit 0" "0" "$rc"
  assert_contains "AC-9 ①: 出力に Knowledge/zz-probe.md を含む" "$ZZ_OUT" "Knowledge/zz-probe.md"

  rc=0
  HOME="$TH12" PATH="$WORK/stub:$PATH" bash "$FX12/core/assembly/check-drift.sh" --managed-symlinks-only >/dev/null 2>&1 || rc=$?
  assert_eq "AC-9 ③ 1 回目: 配置の健全性検査は exit 0" "0" "$rc"
  rm -rf "$TH12/.zz-cli"
  rc=0
  drift_out="$(HOME="$TH12" PATH="$WORK/stub:$PATH" bash "$FX12/core/assembly/check-drift.sh" --managed-symlinks-only 2>&1)" || rc=$?
  assert_true "AC-9 ③ 2 回目（zz-cli の登録を消した後）: 非 0" "$([ "$rc" != "0" ] && echo 1 || echo 0)"
  assert_contains "AC-9 ③ 2 回目: zz-cli の配置を報告" "$drift_out" "zz-cli"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
