#!/usr/bin/env bash
# SessionStart 合成器（Core 接続／Claude Code・旧ライブ名 bootstrap-vault.sh の主後継）のテスト。
# 正本＝docs/v1.1-components の設計 v1.2 §5.5（状態表・失敗モード）・§5.6・§10.4・§11・§13、実装計画 §3・§7・§9。
# tests/test-bootstrap-vault.sh から「ブロック全体の形・ワーカー判定・SessionStart の 2 フック・見出しの fail-open」の節を
# 移した（旧 9・8f の見出し・84 の全体部分。由来＝分割元）。旧 71（外部プロセス数）は設計 §5.5 の設計定数
# 「python3 の起動 3 回」の検査に置き換えた（リーダー裁定 2026-10-03＝shell の起動数は見ない）。
#
# 実行方法: bash tests/test-session-start-compose.sh
#
# 契約（テストが決めた口。台帳・台帳ツールの口は tests/test-ledger.sh 冒頭の契約と同じ）:
#   合成器   core/connect/claude-code/session-start-compose.sh。stdin＝hook JSON。stdout＝
#            {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":…}}・exit 0。
#            ワーカー（stdin の agent_type あり／BOOTSTRAP_TEAMS_DIR 配下の他チームの config.json に session_id）
#            なら無出力・exit 0。寄与は鍵 ai-brain.bootstrap・team.session-status・dock.declare-state を
#            台帳ツール lookup で引き（AIENV_LEDGER をそのまま渡す）、各 1 回 `--slots` で起動する（stdin は同じ JSON）。
#   寄与の --slots 出力＝{"slots":{"<枠名>":"<文>",…}}（空の枠は ""・文の末尾に改行を付けない）。
#     ai-brain.bootstrap   must-read＝「重要: 必読ノートの全文は…」から「④ 記録職＝…」の行まで／
#                          health＝【外部脳ヘルス】の節（ℹ️ 行があれば空行 1 つを挟んで続ける）
#     team.session-status  opening＝「【開幕1行】…:」・🧭 行・「⚠️ この依頼に…」の 3 行／directive5＝⑤ の行／
#                          machine-role-hold＝保留の 1 行／profile-warning＝「【ローカル実体プロファイル】」＋改行＋警告
#     dock.declare-state   declare6＝⑥ の行
#   配置（基準＝分岐元 2da911f の bootstrap-vault.sh 578〜604 行の heredoc）＝本ファイルの render_expected。
#   警告行＝本文の末尾に空行 1 つを置き、異常 1 件 1 行で LEDGER: …（固定文＝ledger-tool の lookup と同じ形）。
#            寄与の起動の異常（非 0・不正 JSON・枠欠落）も `LEDGER: part <鍵> <パス> <原因>` の形。同じ行を stderr へも。
# 隔離: HOME＝一時ディレクトリ・PATH 先頭に応答しない cmux（exit 9）・Vault／ログ／観測記録は一時パス。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"
COMPOSER="$REPO_ROOT/core/connect/claude-code/session-start-compose.sh"
LEDGER="$REPO_ROOT/$LF_LEDGER_REL"
resolve_real_cmd_for_spy() {
  local cmd="$1"
  if [ "$cmd" = "python3" ] && command -v pyenv >/dev/null 2>&1; then
    pyenv which python3 2>/dev/null && return 0
  fi
  command -v "$cmd" 2>/dev/null || true
}

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれない: \"$3\")"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれてはいけないのに含まれる: \"$3\")"; fi; }
# ①→②→④→⑤→⑥ の順序（旧 test-bootstrap-vault.sh の同名関数を写した）。
assert_ascending_line_positions() {
  local desc="$1"; shift
  local haystack="$1"; shift
  local prev=0 m line
  for m in "$@"; do
    line="$(printf '%s\n' "$haystack" | grep -n "^${m} " | head -1 | cut -d: -f1)"
    if [ -z "$line" ]; then fail_case "$desc (${m} の行が見つからない)"; return; fi
    if [ "$line" -le "$prev" ]; then fail_case "$desc (${m} の位置が順序どおりでない: line=$line prev=$prev)"; return; fi
    prev="$line"
  done
  pass "$desc"
}

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cmux-stub" "$WORK/home"
printf '#!/bin/bash\nexit 9\n' > "$WORK/cmux-stub/cmux"; chmod +x "$WORK/cmux-stub/cmux"
export PATH="$WORK/cmux-stub:$PATH" HOME="$WORK/home"
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT BOOTSTRAP_CMUX_LIB_DIR AIENV_LEDGER

make_full_vault() {
  local vault="$1" f
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}
VAULT_DIR="$WORK/vault"; make_full_vault "$VAULT_DIR"
MODELS_CONF="$WORK/models.conf"
printf '[t-opus-high]\nprovider=anthropic-api\nmodel=claude-opus-5-5\neffort=high\n\n[opus-noeffort]\nprovider=anthropic-api\nmodel=claude-opus-5-5\n' > "$MODELS_CONF"
V2_BASE='---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main'
make_v2_profile() {
  local path="$1" line; shift
  mkdir -p "$(dirname "$path")"
  { printf '%s\n' "$V2_BASE"; for line in "$@"; do printf '%s\n' "$line"; done; printf -- '---\n'; } > "$path"
}

SESSION_JSON='{"session_id":"test-session-0000"}'
PROFILE_ENABLE=0
PROFILE_PATH="/nonexistent-dir/profile.md"
# hook_env <コマンド…> — 合成器・寄与に同じ入力（既定が実ファイルの env は全て一時／不在パス）を与える。
# 観測記録は起動ごとに新しい一時パス＝どの起動も「前回の観測なし」から始まる（文字列等値の比較のため）。
hook_env() {
  local obs; obs="$(mktemp -d "$WORK/obs.XXXXXX")/session-observation.json"
  BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="${TEAMS_DIR:-/nonexistent-teams-dir}" \
    VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    VAULT_INVENTORY_LOG_DIR="${INV_DIR_OVR:-/nonexistent-dir/vault-inventory}" \
    MAINTENANCE_LAST_RUN_FILE="${LAST_RUN_OVR:-/nonexistent-dir/last-run.json}" \
    MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
    HEALTH_OBSERVATION_FILE="${OBS_FILE:-$obs}" HEALTH_JUDGE_NOW="2026-09-15T06:01:01Z" \
    AIENV_MODEL_DEFS_FILE="$MODELS_CONF" \
    BOOTSTRAP_ENABLE_LOCAL_PROFILE="$PROFILE_ENABLE" AIENV_LOCAL_PROFILE_PATH="$PROFILE_PATH" "$@"
}
# compose [stdin] — 合成器を起動。CTX＝additionalContext・RC＝終了コード・$WORK/c.out／c.err。
compose() {
  RC=0
  printf '%s\n' "${1:-$SESSION_JSON}" | hook_env bash "$COMPOSER" > "$WORK/c.out" 2>"$WORK/c.err" || RC=$?
  CTX="$(jq -r '.hookSpecificOutput.additionalContext' "$WORK/c.out" 2>/dev/null)"
}
# slot <鍵> <枠名> — その寄与を --slots で起動して 1 枠の文を返す。
slot() {
  local e; e="$(bash "$REPO_ROOT/$LF_LEDGER_TOOL_REL" lookup "$1" 2>/dev/null | head -1)"
  [ -n "$e" ] || return 0
  printf '%s\n' "$SESSION_JSON" | hook_env bash "$e" --slots 2>/dev/null | jq -r --arg k "$2" '.slots[$k]'
}
# render_expected — 寄与 3 の枠を基準の heredoc（2da911f bootstrap-vault.sh 578〜604 行）の骨格に入れた 1 ブロック。
# `read -r -d ''` が末尾の改行を落とすのも写す（$(…) が末尾の改行を落とす）。
render_expected() {
  local o m d5 d6 hold hs pw
  o="$(slot team.session-status opening)"; m="$(slot ai-brain.bootstrap must-read)"
  d5="$(slot team.session-status directive5)"; d6="$(slot dock.declare-state declare6)"
  hold="$(slot team.session-status machine-role-hold)"; hs="$(slot ai-brain.bootstrap health)"
  pw="$(slot team.session-status profile-warning)"
  printf '%s' "【セッション開始ブートストラップ｜ハーネス強制注入】

${o}

${m}
${d5}
${d6}
${hold:+
${hold}}

${hs}${pw:+

${pw}}"
}

KEY_BOOT=ai-brain.bootstrap; KEY_TEAM=team.session-status; KEY_DOCK=dock.declare-state
# 寄与ごとの目印（その寄与の枠にだけ現れる語）。
mark_of() { case "$1" in "$KEY_BOOT") echo "① タスクに着手する前に" ;; "$KEY_TEAM") echo "🧭 現在＝" ;; "$KEY_DOCK") echo "⑥ " ;; esac; }
# assert_only_missing <ラベル> <鍵> — その鍵の寄与の枠だけが無く、他 2 つの枠はある。見出しは出る。
assert_only_missing() {
  local label="$1" gone="$2" k
  assert_eq "$label: exit 0" "0" "$RC"
  assert_eq "$label: 見出しは出る（1 行目）" "【セッション開始ブートストラップ｜ハーネス強制注入】" "$(printf '%s\n' "$CTX" | head -1)"
  for k in "$KEY_BOOT" "$KEY_TEAM" "$KEY_DOCK"; do
    if [ "$k" = "$gone" ]; then
      assert_not_contains "$label: $k の枠は省かれる" "$CTX" "$(mark_of "$k")"
    else
      assert_contains "$label: $k の枠は残る" "$CTX" "$(mark_of "$k")"
    fi
  done
}
# assert_warning <ラベル> <先頭の固定文> — 末尾の行が警告行・その前が空行・stderr にも同じ行。
assert_warning() {
  local label="$1" head="$2" last prev
  last="$(printf '%s\n' "$CTX" | tail -1)"; prev="$(printf '%s\n' "$CTX" | tail -2 | head -1)"
  assert_true "$label: 末尾の行が警告行（${head}…）" "$([[ "$last" == "$head"* ]] && echo 1 || echo 0)"
  assert_true "$label: 警告行の前は空行か警告行" "$([ -z "$prev" ] || [[ "$prev" == "LEDGER: "* ]] && echo 1 || echo 0)"
  assert_true "$label: 同じ行を stderr へも" "$(grep -qF -- "$last" "$WORK/c.err" && echo 1 || echo 0)"
}
# ledger_without <鍵> [置き換えのパス] — 実台帳からその鍵の行を除いた台帳（パスを渡すと同じ列で 1 行足す）。
ledger_without() {
  local out="$WORK/ledger-$RANDOM.tsv"
  awk -F'\t' -v k="$1" '$6!=k' "$LEDGER" > "$out" 2>/dev/null
  [ -n "${2:-}" ] && awk -F'\t' -v OFS='\t' -v k="$1" -v p="$2" '$6==k && !done {$2=p; print; done=1}' "$LEDGER" >> "$out"
  printf '%s' "$out"
}

echo "=== 1. 充足・文字列等値（AC-12 ②・設計 §5.5）: 寄与 3 の枠を基準の骨格に入れた 1 ブロックと一致・警告行なし ==="
compose
assert_eq "exit 0" "0" "$RC"
assert_eq "hookEventName＝SessionStart" "SessionStart" "$(jq -r '.hookSpecificOutput.hookEventName' "$WORK/c.out" 2>/dev/null)"
assert_eq "基準の骨格と文字列等値" "$(render_expected)" "$CTX"
assert_eq "開幕の枠＝基準の 3 行（配役表の解決なし＝未確定行）" \
  "【開幕1行】最初の応答の冒頭に、次の1行をそのまま転記する（1行だけ・要約しない）:
🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。
⚠️ この依頼に本人のモード指定が含まれていたら、上の行ではなく指定後のモードの行を1行だけ出す（2行出さない）。モードを変えられるのは本人だけ。" \
  "$(printf '%s\n' "$CTX" | sed -n '3,5p')"
assert_eq "成功時は警告行なし" "0" "$(printf '%s\n' "$CTX" | grep -c '^LEDGER: ' || true)"
# 旧 84 の全体部分: ③は欠番・①②④⑤⑥ の順・【使用率】無し。
assert_eq "84: ③は欠番（番号は詰めない）" "0" "$(printf '%s\n' "$CTX" | grep -c '^③ ' || true)"
assert_eq "84: ④は vault-scribe を含むちょうど1行" "1" "$(printf '%s\n' "$CTX" | grep -cE '^④ .*vault-scribe' || true)"
assert_contains "84: ①が残る" "$CTX" "① タスクに着手する前に"
assert_contains "84: ②が残る" "$CTX" "② 上記を読み終えるまで"
assert_not_contains "84: 【使用率】ブロックは出ない（発言ごとの usage-inject.sh が正）" "$CTX" "【使用率】"
assert_ascending_line_positions "84: ①→②→④→⑤→⑥の順序が保たれる" "$CTX" "①" "②" "④" "⑤" "⑥"

echo "=== 2. 空（予定）と空でない枠（設計 §5.5）: machine_role 未確定＋配役表の状態行＝保留行・プロファイル節つきでも文字列等値 ==="
PROFILE_ENABLE=1; PROFILE_PATH="$WORK/p-unknown.md"
make_v2_profile "$PROFILE_PATH" "role.leader: configured model=t-opus-high"
sed -i '' "s/machine_role:     configured value=main/machine_role:     unknown/" "$PROFILE_PATH"
compose
assert_true "保留の枠が空でない（前提）" "$([ -n "$(slot team.session-status machine-role-hold)" ] && echo 1 || echo 0)"
assert_true "プロファイル節の枠が空でない（前提）" "$([ -n "$(slot team.session-status profile-warning)" ] && echo 1 || echo 0)"
assert_eq "保留行・プロファイル節つきでも基準の骨格と文字列等値" "$(render_expected)" "$CTX"
assert_eq "保留行はちょうど 1 回" "1" "$(printf '%s\n' "$CTX" | grep -c '配役表の machine_role が未確定です' || true)"
PROFILE_ENABLE=0; PROFILE_PATH="/nonexistent-dir/profile.md"

echo "=== 3. 空（鍵なし）: 寄与ごとに台帳から鍵を除く（AIENV_LEDGER）＝その寄与の枠だけ省く・警告行なし ==="
for k in "$KEY_BOOT" "$KEY_TEAM" "$KEY_DOCK"; do
  AIENV_LEDGER="$(ledger_without "$k")" compose
  assert_only_missing "鍵なし $k" "$k"
  assert_eq "鍵なし $k: 警告行なし（予定された省略）" "0" "$(printf '%s\n' "$CTX" | grep -c '^LEDGER: ' || true)"
done

echo "=== 4. 空（台帳異常）: AIENV_LEDGER が無い＝寄与の枠を省き・見出しは出し・末尾に LEDGER: ledger ==="
AIENV_LEDGER="$WORK/no-such-dir/ledger.tsv" compose
assert_eq "台帳異常: exit 0" "0" "$RC"
assert_eq "台帳異常: 見出しは出る" "【セッション開始ブートストラップ｜ハーネス強制注入】" "$(printf '%s\n' "$CTX" | head -1)"
assert_not_contains "台帳異常: AI Brain の枠は無い" "$CTX" "$(mark_of "$KEY_BOOT")"
assert_warning "台帳異常" "LEDGER: ledger "

echo "=== 5. 空（実体異常・寄与不在）: 鍵の行のパスが無い＝その寄与の枠だけ省き・末尾に LEDGER: part <鍵> ==="
for k in "$KEY_BOOT" "$KEY_TEAM" "$KEY_DOCK"; do
  AIENV_LEDGER="$(ledger_without "$k" "core/executor/zz-missing-contrib.sh")" compose
  assert_only_missing "寄与不在 $k" "$k"
  assert_warning "寄与不在 $k" "LEDGER: part $k "
done

echo "=== 6. 空（実体異常・寄与異常）: 寄与が非 0／不正 JSON／枠欠落＝その寄与の枠だけ省き・末尾に LEDGER: part <鍵> ==="
# 偽の寄与は repo ルートの下に要る（台帳のパスは repo 相対）＝FX-1 の複製に置き、その複製の合成器を起動する。
COPY="$WORK/copy"; lf_copy_repo "$REPO_ROOT" "$COPY"
mkdir -p "$COPY/core/executor"
printf '#!/bin/bash\ncat >/dev/null\nexit 3\n' > "$COPY/core/executor/zz-contrib-nonzero.sh"
printf '#!/bin/bash\ncat >/dev/null\necho "not json"\n' > "$COPY/core/executor/zz-contrib-badjson.sh"
printf '#!/bin/bash\ncat >/dev/null\necho %s\n' "'{\"slots\":{}}'" > "$COPY/core/executor/zz-contrib-noslot.sh"
chmod +x "$COPY"/core/executor/zz-contrib-*.sh
for mode in nonzero badjson noslot; do
  for k in "$KEY_BOOT" "$KEY_TEAM" "$KEY_DOCK"; do
    COMPOSER_SAVE="$COMPOSER"; COMPOSER="$COPY/core/connect/claude-code/session-start-compose.sh"
    AIENV_LEDGER="$(ledger_without "$k" "core/executor/zz-contrib-$mode.sh")" compose
    COMPOSER="$COMPOSER_SAVE"
    assert_only_missing "寄与異常($mode) $k" "$k"
    assert_warning "寄与異常($mode) $k" "LEDGER: part $k "
  done
done

echo "=== 7. ワーカー判定（旧 9・設計 §5.5 ブロックなし）: agent_type 付き／他チームの config に載る＝無出力・exit 0 ==="
OBS_FILE="$WORK/worker-obs/session-observation.json" compose '{"session_id":"test-session-worker","agent_type":"worker"}'
assert_eq "agent_type 付き: exit 0" "0" "$RC"
assert_eq "agent_type 付き: stdout 空" "" "$(cat "$WORK/c.out")"
assert_true "agent_type 付き: 寄与を起動しない（観測記録が書かれない）" "$([ ! -e "$WORK/worker-obs/session-observation.json" ] && echo 1 || echo 0)"
TEAMS="$WORK/teams"; mkdir -p "$TEAMS/session-otherlead"
printf '{"members":[{"session_id":"sess-member-0001"}]}\n' > "$TEAMS/session-otherlead/config.json"
TEAMS_DIR="$TEAMS" compose '{"session_id":"sess-member-0001"}'
assert_eq "他チームの config に載る: exit 0" "0" "$RC"
assert_eq "他チームの config に載る: stdout 空" "" "$(cat "$WORK/c.out")"
TEAMS_DIR="$TEAMS" compose '{"session_id":"sess-other-9999"}'
assert_contains "どのチームにも載らない: ブロックを出す" "$CTX" "【セッション開始ブートストラップ｜ハーネス強制注入】"

echo "=== 8. SessionStart の 2 フック（設計 §5.5 既存コードへの影響）: 登録は旧ライブ名のまま・サブ機更新確認と並ぶ ==="
assert_eq "settings 雛形の SessionStart 登録＝bootstrap-vault.sh と check-sub-update.sh" \
  "\$HOME/.claude/hooks/bootstrap-vault.sh
\$HOME/.claude/hooks/check-sub-update.sh" \
  "$(jq -r '.hooks.SessionStart[].hooks[].command' "$REPO_ROOT/core/assembly/settings.json" 2>/dev/null)"

echo "=== 9. 旧 8f（NFR-2 fail-open）: 判定機の入力が壊れていても見出し・本文は止めない（見出し＝配置表の固定文） ==="
{
  INV8F="$(mktemp -d "$WORK/inv8f.XXXXXX")"
  printf 'not json' > "$INV8F/latest.json"
  INV_DIR_OVR="$INV8F" LAST_RUN_OVR="$TESTS_DIR/fixtures/health/S-1/last-run.json" compose
  assert_eq "8f: exit 0" "0" "$RC"
  assert_contains "8f: 本文は健在（見出し）" "$CTX" "【セッション開始ブートストラップ｜ハーネス強制注入】"
  assert_contains "8f: 本文は健在（必読一覧）" "$CTX" "① タスクに着手する前に"
  assert_contains "8f: latest.json 破損はヘルス節の項目 1 件（段階の写し）" "$CTX" "step=Phase1③ vault_inventory（記録の整合） result=失敗 actor=AI"
  assert_eq "8f: 警告行なし（台帳・寄与は正常）" "0" "$(printf '%s\n' "$CTX" | grep -c '^LEDGER: ' || true)"
}

echo "=== 10. 旧 71 の置き換え（設計 §5.5 設計定数）: SessionStart 1 回の python3 起動＝3 回（Team 解決器 2＋ヘルス判定機 1）。shell の起動数は見ない ==="
{
  SPY_PY="$(mktemp -d "$WORK/spy-py.XXXXXX")"
  REAL_PY="$(resolve_real_cmd_for_spy python3)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.log"\nexec "%s" "$@"\n' "$SPY_PY" "$REAL_PY" > "$SPY_PY/python3"
  chmod +x "$SPY_PY/python3"
  : > "$SPY_PY/calls.log"
  PROFILE_ENABLE=1; PROFILE_PATH="$WORK/p-solo.md"
  make_v2_profile "$PROFILE_PATH" "role.leader: configured model=opus-noeffort"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=solo/" "$PROFILE_PATH"
  PATH="$SPY_PY:$PATH" compose
  PROFILE_ENABLE=0; PROFILE_PATH="/nonexistent-dir/profile.md"
  assert_eq "71': exit 0" "0" "$RC"
  assert_contains "71': 正常分岐（配役表を解決できた）を通っている" "$CTX" "🧭 現在＝単独モード"
  assert_contains "71': ヘルス判定機が動いた（段階が出る）" "$CTX" "stage="
  assert_eq "71': python3 の起動はちょうど 3 回" "3" "$(grep -c . "$SPY_PY/calls.log" || true)"
  assert_eq "71': うちヘルス判定機 1 回" "1" "$(grep -c 'health_judge' "$SPY_PY/calls.log" || true)"
  assert_eq "71': うち配役表の解決器 2 回" "2" "$(grep -c 'profile_resolve' "$SPY_PY/calls.log" || true)"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
