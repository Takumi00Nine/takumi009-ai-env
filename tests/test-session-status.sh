#!/usr/bin/env bash
# 配役表の状態の寄与（Team 接続／Claude Code）と配役表の解決器のテスト（Team）。
# tests/test-bootstrap-vault.sh から移し替えた（由来＝分割元。v1.1 設計 v1.2 §4.3・実装計画 §8）:
#   開幕行（🧭 モード行・配役表セグメント）・⑤・machine_role 保留・実体プロファイル警告（P1 機構）と、
#   それを支える配役表の解決器（profile_resolve.py）の節（旧 10〜17・23〜68・70・72〜78。番号は旧のまま）。
#
# 実行方法: bash tests/test-session-status.sh
#
# 契約（テストが決めた口。設計 §5.5・§11、実装計画 §7・§9）:
#   寄与     team/connect/claude-code/profile-status.sh。stdin＝hook JSON。
#     --slots   {"slots":{"opening":…,"directive5":…,"machine-role-hold":…,"profile-warning":…}}（この 4 枠ちょうど・
#               空の枠は ""・文の末尾に改行を付けない）。枠の中身＝tests/test-session-start-compose.sh 冒頭の契約。
#     引数なし  {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":…}}＝空でない枠だけを
#               枠順（opening・directive5・machine-role-hold・profile-warning）に空行 1 つで連結したもの。
#   上書き口（現行名のまま）＝BOOTSTRAP_ENABLE_LOCAL_PROFILE・AIENV_LOCAL_PROFILE_PATH・AIENV_MODEL_DEFS_FILE・
#     PROFILE_RESOLVE_LIB・AIENV_AGENTS_DIR・BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY。
#   配役表の照会コマンドの文＝`python3 ~/work/takumi009-ai-env/team/connect/claude-code/role_candidates.py`（新パス）。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/team/connect/claude-code/profile-status.sh"
# 実 HOME（~/.claude/logs・~/.config/takumi009-ai-env）に触れない。
STATUS_HOME="$(mktemp -d)"
export HOME="$STATUS_HOME"
trap 'rm -rf "$STATUS_HOME"' EXIT
# PATHをspyディレクトリだけに絞る外部プロセス計数テスト（§10.5＝旧 70）で使う。
REAL_BASH="$(command -v bash)"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

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

# 移した節が Vault を作る行をそのまま持つ（寄与は Vault を読まない）ので、作る関数だけ残す。
make_full_vault() {
  local vault="$1"
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

# モデル定義ファイル（旧 test-bootstrap-vault.sh の共有 fixture をそのまま写した＝読取専用・全ケース共通）。
SHARED_MODELS_CONF="$(mktemp -d)/models.conf"
make_model_defs() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  if [ "$#" -eq 0 ]; then
    cat > "$path" <<'EOF'
[t-opus-high]
provider=anthropic-api
model=claude-opus-5-5
effort=high

[opus-noeffort]
provider=anthropic-api
model=claude-opus-5-5

[opus-max]
provider=anthropic-api
model=claude-opus-5-5
effort=max

[opus46-xhigh]
provider=anthropic-api
model=claude-opus-4.6
effort=xhigh

[fable-1m]
provider=anthropic-api
model=claude-fable-5[1m]

[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5

[sonnet-max]
provider=anthropic-api
model=claude-sonnet-5
effort=max

[bedrock-opus]
provider=bedrock
model=opus

[bedrock-opus-xhigh]
provider=bedrock
model=opus
effort=xhigh

[bedrock-haiku]
provider=bedrock
model=haiku

[bedrock-sonnet]
provider=bedrock
model=sonnet

[mantle-haiku]
provider=bedrock-mantle
model=anthropic.claude-3-haiku

[codex-review]
provider=external
execution=external-cli
model=codex-review-default
effort=high

[codex-other-tool]
provider=external
execution=external-cli
model=other-tool

[ext-api-bad]
provider=external
execution=external-api
model=codex-review-default

[codex-review-minimal]
provider=external
execution=external-cli
model=codex-review-default
effort=minimal
EOF
  else
    : > "$path"
    for block in "$@"; do printf '%s\n' "$block" >> "$path"; done
  fi
}
make_model_defs "$SHARED_MODELS_CONF"
export AIENV_MODEL_DEFS_FILE="$SHARED_MODELS_CONF"

STATUS_SESSION_JSON='{"session_id":"test-session-0000"}'
# run_status_with_profile <profile_path> [models_conf] — P1 機構を有効にして寄与を引数なしで起動し additionalContext を返す。
run_status_with_profile() {
  local profile_path="$1" models_conf="${2:-$SHARED_MODELS_CONF}"
  echo "$STATUS_SESSION_JSON" \
    | AIENV_MODEL_DEFS_FILE="$models_conf" BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 \
      AIENV_LOCAL_PROFILE_PATH="$profile_path" "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
# run_status — P1 機構を無効（BOOTSTRAP_ENABLE_LOCAL_PROFILE=0）にして寄与を引数なしで起動。
run_status() {
  echo "$STATUS_SESSION_JSON" | BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
# slots_with_profile <profile_path> — 同じ入力で --slots を起動し JSON を返す。
slots_with_profile() {
  echo "$STATUS_SESSION_JSON" \
    | BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$1" "$SCRIPT" --slots
}

# 「壊れていない」schema 7のprofile.md（旧 test-bootstrap-vault.sh の make_ok_profile をそのまま写した）。
make_ok_profile() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader:      configured model=t-opus-high
---
EOF
}

echo "=== S1. --slots 全枠モード（実装計画 §9）: 枠名 4 つちょうど・空の枠は \"\"・引数なし＝空でない枠を空行で連結 ==="
{
  set +e
  slots_json="$(echo "$STATUS_SESSION_JSON" | BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" --slots 2>/dev/null)"
  slots_rc=$?
  set -e
  assert_eq "S1: --slots の終了コード 0" "0" "$slots_rc"
  assert_eq "S1: 枠名＝directive5・machine-role-hold・opening・profile-warning" \
    "directive5,machine-role-hold,opening,profile-warning" \
    "$(printf '%s' "$slots_json" | jq -r '.slots | keys | join(",")' 2>/dev/null)"
  assert_eq "S1: machine_role の解決なし＝保留の枠は \"\"" '""' "$(printf '%s' "$slots_json" | jq -c '.slots["machine-role-hold"]' 2>/dev/null)"
  assert_eq "S1: 警告なし＝プロファイル節の枠は \"\"" '""' "$(printf '%s' "$slots_json" | jq -c '.slots["profile-warning"]' 2>/dev/null)"
  assert_eq "S1: opening＝転記指示・🧭 行・⚠️ 行の 3 行" \
    "【開幕1行】最初の応答の冒頭に、次の1行をそのまま転記する（1行だけ・要約しない）:
🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。
⚠️ この依頼に本人のモード指定が含まれていたら、上の行ではなく指定後のモードの行を1行だけ出す（2行出さない）。モードを変えられるのは本人だけ。" \
    "$(printf '%s' "$slots_json" | jq -r '.slots.opening' 2>/dev/null)"
  assert_eq "S1: directive5 は ⑤ で始まる 1 行" "1" \
    "$(printf '%s' "$slots_json" | jq -r '.slots.directive5' 2>/dev/null | grep -c '^⑤ ' || true)"
  hook_ctx="$(run_status 2>/dev/null || true)"
  assert_eq "S1: 引数なし＝空でない枠（opening・directive5）を空行で連結" \
    "$(printf '%s' "$slots_json" | jq -r '[.slots.opening, .slots.directive5] | join("\n\n")' 2>/dev/null)" "$hook_ctx"
  assert_eq "S1: 引数なしの hookEventName＝SessionStart" "SessionStart" \
    "$(echo "$STATUS_SESSION_JSON" | BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 "$SCRIPT" 2>/dev/null | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null || true)"
}
echo "=== 10. P1機構(ローカル実体プロファイル): ゲート無効(BOOTSTRAP_ENABLE_LOCAL_PROFILE=0明示。run_bootstrap()の固定値)では固定パスが必読リストに一切現れない（2026-09-02からコードの既定値は1・§9.0 A-1／rollout-runbook.md現行トラック§7） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_PATH="$(mktemp -d)/profile.md"
  make_ok_profile "$PROFILE_PATH"

  ctx="$(run_status)"
  assert_not_contains "ゲート無効では固定パスが必読リストに出ない" "$ctx" "$PROFILE_PATH"
  assert_not_contains "ゲート無効ではローカル実体プロファイル見出しも出ない" "$ctx" "【ローカル実体プロファイル】"

  rm -rf "$VAULT_DIR" "$(dirname "$PROFILE_PATH")"
}

echo "=== 11. FR-10(要件v1.2.1): 有効化しても実体プロファイルの固定パスは必読リストに一切現れない（旧P1受入条件①は撤回。FR-11のモード行セグメントで代替） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_ok_profile "$PROFILE_PATH"

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  occurrences="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "固定パスは必読リストに0件（FR-10）" "0" "$occurrences"
  assert_not_contains "壊れていないprofileでは最小能力警告は出ない" "$ctx" "最小能力"
  assert_contains "FR-11: モード行セグメントにschema_version=が含まれる" "$ctx" "schema_version=7"
  assert_contains "FR-11: モード行セグメントにmachine_role=が含まれる" "$ctx" "machine_role=main"
  assert_contains "FR-11: モード行セグメントに照会コマンド(role_candidates.py)が含まれる" "$ctx" "role_candidates.py"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 12. P1機構 T1(実体なし): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_PATH="$(mktemp -d)/nonexistent/profile.md"

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "T1: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T1: 実体なしの理由が出る" "$ctx" "T1"
  # FR-10差し戻し（検証1巡目MINOR-4・2026-09-17）: 失敗経路（T1）でも必読
  # リストへは一切追加しない（旧仕様は「未作成」の案内1行を必読リストへ
  # 出していた。案内は🧭モード行の「利用不可（T1）」セグメントへ一本化）。
  occurrences_t1="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "T1: 必読リストに実体プロファイルの行が0件" "0" "$occurrences_t1"

  # FR-12（要件v1.2.1）: 不在(T1)は🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（値の再掲は無く区分コードのみ）。
  mode_line_t1="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "T1: モード行に「利用不可」を含む" "$mode_line_t1" "利用不可"
  assert_contains "T1: モード行に「本人確認へ倒す」を含む" "$mode_line_t1" "本人確認へ倒す"
  assert_contains "T1: モード行の区分コードに（T1）を含む" "$mode_line_t1" "（T1）"

  rm -rf "$VAULT_DIR"
}

echo "=== 13. P1機構 T2-MINIMAL(未記入sentinel): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode: configured value=<fill-in>
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-opus-high
---
EOF

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "T2-MINIMAL: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T2-MINIMAL: 未記入sentinelの理由が出る" "$ctx" "T2-MINIMAL"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 14. P1機構 T5(既存キー欠落): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # machine_role キーだけを欠落させる（2026-09-05 P3段階4差し戻し対応でno_read_paths
  # を追加したため、この行にも書いて「欠落は machine_role の1件だけ」という
  # 回帰テストの意図を保つ＝Codex一次レビュー指摘・Minor対応の型を継承）。
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode: configured value=full
no_read_paths: unavailable
role.leader: configured model=t-opus-high
---
EOF

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "T5: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T5: 既存キー欠落の理由が出る" "$ctx" "T5"
  assert_contains "T5: 欠落キー名が出る" "$ctx" "machine_role"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 15. P1機構 T6(YAML破損): 最小能力+⚠️になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # frontmatterの終端区切りが無い壊れたファイル。
  cat > "$PROFILE_PATH" <<'EOF'
---
team_mode: 本人
EOF

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "T6: 最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "T6: YAML破損の理由が出る" "$ctx" "T6"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 16. P1機構 T9'(UNKNOWN_EXTRA): 機械側は既知キー部分が有効(MINIMALへは倒さない)だが、AI向けには必読除外・最小能力(⚠️)になる（配役表解凍-設計-2026-09-01.md §4a・U-8裁定で2026-09-01に advisory→除外へ変更。旧仕様=ℹ️のまま読ませ続ける、はこの裁定で終了） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  # 既知の3キーはすべて揃えたうえで、将来のスキーマ拡張を想定した未知キーを追加する。
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-opus-high
future_new_key: 未来のスキーマが追加した値
---
EOF

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  # 機械側は解決失敗(MINIMAL)ではない＝「を解決できません」という汎用MINIMAL
  # 文言は出ない（既知キー部分は有効という§4a表の区別を保つ）。
  assert_not_contains "T9': 機械側の解決失敗(MINIMAL)ではない" "$ctx" "を解決できません"
  assert_contains "T9': 未知キー名が警告に出る" "$ctx" "future_new_key"
  assert_contains "T9': AI向けには必読除外・最小能力の⚠️警告になる（U-8裁定）" "$ctx" "⚠️ ローカル実体プロファイルに未知のキーがあります"
  assert_contains "T9': 取るべき行動（本人確認へ倒す）が明記される" "$ctx" "本人確認へ倒してください"
  assert_contains "T9': 「プロファイル利用不可＝最小能力」の文言が明示される（リーダー裁定・2026-09-01）" "$ctx" "プロファイル利用不可＝最小能力"
  assert_contains "T9': 「ワーカー起動は本人確認へ倒す」の文言が明示される（リーダー裁定・2026-09-01）" "$ctx" "ワーカー起動は本人確認へ倒してください"
  assert_not_contains "T9': 旧仕様のℹ️文言はもう出ない" "$ctx" "ℹ️ ローカル実体プロファイルに未知のキーがあります"
  assert_not_contains "T9': 全文Readの指示は付かない（必読除外）" "$ctx" "$PROFILE_PATH  （全"
  # FR-10差し戻し（検証1巡目MINOR-4・2026-09-17）: UNKNOWN_EXTRAでも必読
  # リストへは一切追加しない（旧仕様は⚠️の警告文とは別に必読リストへも
  # 「プロファイル利用不可のため全文はReadさせません」の案内1行を出していた）。
  occurrences_ue="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "T9': 必読リストに実体プロファイルの行が0件" "0" "$occurrences_ue"

  # FR-12（要件v1.2.1）: UNKNOWN_EXTRAも🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（区分コードはUNKNOWN_EXTRA）。
  mode_line_ue="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "T9': モード行に「利用不可」を含む" "$mode_line_ue" "利用不可"
  assert_contains "T9': モード行に「本人確認へ倒す」を含む" "$mode_line_ue" "本人確認へ倒す"
  assert_contains "T9': モード行の区分コードに（UNKNOWN_EXTRA）を含む" "$mode_line_ue" "（UNKNOWN_EXTRA）"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 17. P1機構: 実体がsymlinkの場合は受理せず最小能力+⚠️になる（Codex一次レビュー指摘・Major対応: repo/Vault管理下ファイルへのsymlinkでリモート更新が能力表へ暗黙反映される経路を防ぐ） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  REAL_TARGET="$PROFILE_DIR/real-target.md"
  make_ok_profile "$REAL_TARGET"
  ln -s "$REAL_TARGET" "$PROFILE_PATH"

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "symlinkでは最小能力+⚠️の警告が出る" "$ctx" "最小能力"
  assert_contains "SYMLINK理由コードが出る" "$ctx" "SYMLINK"
  # Codex二次レビュー指摘・Major対応: 必読リスト側の判定も揃っていることを
  # 検証する（resolve_local_profile()だけでなく、リスト表示のfor文自体が
  # `-f`のみで判定していると、信頼しないはずのsymlink内容を「全文をRead
  # すること」として読ませる指示が残ってしまう）。
  assert_not_contains "symlinkは「全文をReadすること」の必読指示に載らない" "$ctx" "$PROFILE_PATH  （全"
  # FR-10差し戻し（検証1巡目MINOR-4・2026-09-17）: symlinkでも必読リストへは
  # 一切追加しない（旧仕様は「symlinkのため実体として受理しません」の案内
  # 1行を必読リストへ出していた。案内は🧭モード行の「利用不可（SYMLINK）」
  # セグメントへ一本化する）。
  occurrences_symlink="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH" || true)"
  assert_eq "symlink: 必読リストに実体プロファイルの行が0件" "0" "$occurrences_symlink"

  # FR-12（要件v1.2.1）: symlinkも🧭モード行の同じ1行の中に「利用不可」
  # 「本人確認へ倒す」が含まれる（区分コードはSYMLINK）。
  mode_line_symlink="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "symlink: モード行に「利用不可」を含む" "$mode_line_symlink" "利用不可"
  assert_contains "symlink: モード行の区分コードに（SYMLINK）を含む" "$mode_line_symlink" "（SYMLINK）"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

# ============================================================================
# 23番以降: v2配役表解凍（配役表解凍-設計-2026-09-01.md 担当A）のユニット・結合
# テスト。team/executor/profile_resolve.py を直接CLI呼び出しする（parser・
# validator・候補評価は本libが唯一の正本＝§3.4）。DIRECTIVE統合部分だけ
# run_bootstrap_with_profile()を使う。2026-09-08 モデル定義ファイルと候補
# 指定対応（同設計§3.8・D-13）: 旧・分類ラッパー関数（旧・版分類サブコマンドの
# ラッパー）は撤去した——schema 6のコードは分類そのものを行わない。
# ============================================================================

PROFILE_LIB="$REPO_ROOT/team/executor/profile_resolve.py"
AGENTS_DIR="$REPO_ROOT/team/rules/agents"

resolve_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}
resolve_leader_v2() {
  local path="$1" bedrock_env="${2:-/nonexistent-dir/bedrock.env}" agents_dir="${3:-$AGENTS_DIR}"
  python3 "$PROFILE_LIB" resolve-leader "$path" --bedrock-env "$bedrock_env" --agents-dir "$agents_dir"
}

# v2の全5固定キー(メタ2+能力軸3)をすべて満たした最小の
# base雛形。呼び出し側がrole.行だけを足して各シナリオを作る。
# 2026-09-08 モデル定義ファイルと候補指定対応: EXPECTED_SCHEMA_VERSIONを
# 5→6へ引き上げた（モデル定義ファイルと候補指定-設計-2026-09-08.md・D-8）
# のに合わせてbaseも更新した。役割の行の属性はmodel=<定義名>[,…]だけになり、
# provider/execution/effortはモデル定義ファイル側（make_model_defs()）へ
# 移した。2026-09-16 代替配役の層と禁止モデル列挙の層の撤去-設計-
# 2026-09-16.mdでEXPECTED_SCHEMA_VERSIONを6→7へ引き上げたのに合わせて
# baseを再更新した。
# ⚠️ team_mode:の行末揃え（8スペース）は下部のsed置換が字面で参照するため
# 崩さないこと。
V2_BASE='---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main'

make_v2_profile() {
  # $1=path、以降の引数は role.行（そのまま追記）。
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "$V2_BASE"
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '---\n'
  } > "$path"
}

echo "=== 23. parser 4.1-a/4.1-b: ハイフンキー・コメント行・行末コメントが正しく扱われる ==="
{
  P="$(mktemp -d)/comment.md"
  make_v2_profile "$P" \
    "# これはコメント行（無視される）" \
    "role.leader: configured model=t-opus-high  # 行末コメントも無視" \
    "role.requirements-analyst: configured model=t-opus-high"
  out="$(resolve_v2 "$P")"  || true
  assert_contains "4.1-a: ハイフンを含むキー(role.requirements-analyst)がT6にならない" "$out" "OK"
  assert_not_contains "4.1-b: コメント行・行末コメントでT6にならない" "$out" "MINIMAL"
}

echo "=== 24. parser §3.1-7: 重複キー・重複属性・未許可属性はすべてT6（構文エラー） ==="
{
  DUPKEY="$(mktemp -d)/dupkey.md"
  make_v2_profile "$DUPKEY" \
    "role.leader: configured model=t-opus-high" \
    "role.leader: unknown"
  out="$(resolve_v2 "$DUPKEY")"  || true
  assert_contains "重複キーはMINIMAL/T6になる" "$out" "MINIMAL"
  assert_contains "T6コードが出る" "$out" "T6"

  DUPATTR="$(mktemp -d)/dupattr.md"
  make_v2_profile "$DUPATTR" \
    "role.leader: configured model=t-opus-high model=t-sonnet-high"
  out="$(resolve_v2 "$DUPATTR")"  || true
  assert_contains "重複属性はMINIMAL/T6になる" "$out" "MINIMAL	T6"

  UNKATTR="$(mktemp -d)/unkattr.md"
  make_v2_profile "$UNKATTR" \
    "role.leader: configured model=t-opus-high mystery=1"
  out="$(resolve_v2 "$UNKATTR")"  || true
  assert_contains "許可されない属性はMINIMAL/T6になる" "$out" "MINIMAL	T6"

  # エラー理由に行番号とキー名だけが含まれ、属性値そのもの(mystery=1の"1"等)は
  # 含まれないこと（§3.1-8）。
  assert_not_contains "エラー理由に属性の生値が含まれない（§3.1-8）" "$out" "mystery=1"
}

echo "=== 25. validator V8-a: 状態4値と属性有無の組み合わせ ==="
{
  NOTADOPT_ATTR="$(mktemp -d)/notadopt.md"
  make_v2_profile "$NOTADOPT_ATTR" \
    "role.leader: configured model=t-opus-high" \
    "role.researcher: not_adopted model=t-opus-high"
  out="$(resolve_v2 "$NOTADOPT_ATTR")"  || true
  assert_contains "not_adoptedが属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  MISSING_MODEL="$(mktemp -d)/missingmodel.md"
  make_v2_profile "$MISSING_MODEL" \
    "role.leader: configured"
  out="$(resolve_v2 "$MISSING_MODEL")"  || true
  assert_contains "configuredでmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNAVAIL_OK="$(mktemp -d)/unavailok.md"
  make_v2_profile "$UNAVAIL_OK" \
    "role.leader: configured model=t-opus-high" \
    "role.researcher: unavailable model=bedrock-haiku"
  out="$(resolve_v2 "$UNAVAIL_OK")"  || true
  assert_contains "unavailableはprovider/modelを持ってよい（意図の記録）" "$out" "OK"
}

echo "=== 26. validate_model_def(): provider毎のmodel形式・execution既定・external必須execution（2026-09-08 モデル定義ファイルと候補指定対応でV9-bの検査対象が役割の行からモデル定義ファイル側へ移った。§2.4） ==="
{
  # ⚠️ load_model_defs()は定義ファイル内の全定義を検証するため、role.leaderが
  # 実際にその定義を参照していなくても、ファイル内に1つでも不正な定義が
  # あればT12でMINIMALになる（役割の行の候補解決より前の段）。
  BADMODEL="$(mktemp -d)/badmodel.md"
  BADMODEL_CONF="$(mktemp -d)/badmodel.conf"
  make_model_defs "$BADMODEL_CONF" "[bad-model]" "provider=anthropic-api" "model=gpt-5"
  make_v2_profile "$BADMODEL" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$BADMODEL_CONF" resolve_v2 "$BADMODEL")"  || true
  assert_contains "anthropic-apiでmodelがclaude-接頭辞でないとT12でMINIMAL" "$out" "MINIMAL	T12"

  BEDROCKARN="$(mktemp -d)/bedrockarn.md"
  BEDROCKARN_CONF="$(mktemp -d)/bedrockarn.conf"
  make_model_defs "$BEDROCKARN_CONF" "[bad-arn]" "provider=bedrock" "model=arn:aws:bedrock:foo"
  make_v2_profile "$BEDROCKARN" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$BEDROCKARN_CONF" resolve_v2 "$BEDROCKARN")"  || true
  assert_contains "bedrockでarn:始まりのmodelはT12（別名限定）" "$out" "MINIMAL	T12"

  BEDROCKUS="$(mktemp -d)/bedrockus.md"
  BEDROCKUS_CONF="$(mktemp -d)/bedrockus.conf"
  make_model_defs "$BEDROCKUS_CONF" "[bad-us]" "provider=bedrock" "model=us.opus"
  make_v2_profile "$BEDROCKUS" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$BEDROCKUS_CONF" resolve_v2 "$BEDROCKUS")"  || true
  assert_contains "bedrockでus.始まりのmodelもT12" "$out" "MINIMAL	T12"

  EXTNOEXEC="$(mktemp -d)/extnoexec.md"
  EXTNOEXEC_CONF="$(mktemp -d)/extnoexec.conf"
  make_model_defs "$EXTNOEXEC_CONF" "[bad-noexec]" "provider=external" "model=default"
  make_v2_profile "$EXTNOEXEC" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$EXTNOEXEC_CONF" resolve_v2 "$EXTNOEXEC")"  || true
  assert_contains "provider=externalでexecution未記載はT12" "$out" "MINIMAL	T12"

  NONSUBEXEC="$(mktemp -d)/nonsubexec.md"
  NONSUBEXEC_CONF="$(mktemp -d)/nonsubexec.conf"
  make_model_defs "$NONSUBEXEC_CONF" "[bad-nonsub]" "provider=anthropic-api" "model=claude-opus-5-5" "execution=external-cli"
  make_v2_profile "$NONSUBEXEC" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$NONSUBEXEC_CONF" resolve_v2 "$NONSUBEXEC")"  || true
  assert_contains "anthropic-apiでexecution!=subagentはT12" "$out" "MINIMAL	T12"

  DEFAULTEXEC="$(mktemp -d)/defaultexec.md"
  make_v2_profile "$DEFAULTEXEC" \
    "role.leader: configured model=t-opus-high"
  out="$(resolve_v2 "$DEFAULTEXEC")"  || true
  assert_contains "execution未記載はsubagent既定でOKになる" "$out" "OK"
}

echo "=== 27. validator V9-d②: execution=external-apiは常にconfigured不可（2026-09-08 モデル定義ファイルと候補指定対応でハンドラ写像が(provider,execution,model)の三つ組から(provider,execution)の対へ縮まったため、旧『写像に無いmodel名』の陰性ケースは消滅した＝external-cliならどのmodelでも実装済み扱いになる。§2.4） ==="
{
  EXTAPI="$(mktemp -d)/extapi.md"
  make_v2_profile "$EXTAPI" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=ext-api-bad"
  out="$(resolve_v2 "$EXTAPI")"  || true
  assert_contains "execution=external-apiはハンドラ未実装でconfigured不可(V9-d)" "$out" "MINIMAL	T8	V9-d"

  EXTAPI_UNAVAIL="$(mktemp -d)/extapiunavail.md"
  make_v2_profile "$EXTAPI_UNAVAIL" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unavailable model=ext-api-bad"
  out="$(resolve_v2 "$EXTAPI_UNAVAIL")"  || true
  assert_contains "unavailableならexternal-apiでも構文上は許される(V9-d②はconfigured限定)" "$out" "OK"
}

echo "=== 29b. AC-5: 撤去済みキーが残存した実体はUNKNOWN_EXTRAとして扱われる（FR-3。エラーにも無視にもしない） ==="
{
  # ⚠️ 撤去済みキー名を検索語としてソースへ直書きしない（AC-1・AC-2の
  # repo検索に一致しないよう分割代入する。上のlegacy_excluded_keyと同じ手口）。
  retired_key_1="fall""back"".""verifier"
  retired_key_2="excluded""_models"

  RESIDUAL_1="$(mktemp -d)/residual1.md"
  cat > "$RESIDUAL_1" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader: configured model=t-opus-high
fallback.verifier: configured model=t-opus-high # RETIRED-FIXTURE
---
EOF
  out="$(resolve_v2 "$RESIDUAL_1")"  || true
  assert_contains "残存する旧キーの行はUNKNOWN_EXTRAに出る(1)" "$out" "UNKNOWN_EXTRA:${retired_key_1}"
  assert_not_contains "残存キーがあってもMINIMALへは倒さない(1)" "$out" "MINIMAL"

  RESIDUAL_2="$(mktemp -d)/residual2.md"
  cat > "$RESIDUAL_2" <<'EOF'
---
schema_version: 7
profile_slug: authoring
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader: configured model=t-opus-high
excluded_models: configured value=none # RETIRED-FIXTURE
---
EOF
  out="$(resolve_v2 "$RESIDUAL_2")"  || true
  assert_contains "残存する旧キーの行はUNKNOWN_EXTRAに出る(2)" "$out" "UNKNOWN_EXTRA:${retired_key_2}"
  assert_not_contains "残存キーがあってもMINIMALへは倒さない(2)" "$out" "MINIMAL"

  echo "--- 廃止済みの複数候補あいまいコードは復活しない（AC-4の回帰） ---"
  AMBIG="$(mktemp -d)/ambig.md"
  make_v2_profile "$AMBIG" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=t-opus-high,t-sonnet-high"
  err="$(python3 "$PROFILE_LIB" resolve-candidate "$AMBIG" --role verifier --model-def t-opus-high 2>&1 1>/dev/null)"  || true
  assert_not_contains "候補が複数あってもFALLBACK_AMBIGUOUSは出ない" "$err" "FALLBACK_AMBIGUOUS"  # RETIRED-FIXTURE
}

echo "=== 30. §3.5-L リーダー状態遷移: unknown/not_adopted/行が無い/unavailableは全てfail（resolveも非0・resolve-leaderも非0） ==="
{
  for state in "role.leader: unknown" "role.leader: not_adopted"; do
    P="$(mktemp -d)/leaderfail.md"
    make_v2_profile "$P" "$state"
    rc=0; out="$(resolve_v2 "$P")" || rc=$?
    assert_contains "leader=${state}はMINIMALになる" "$out" "MINIMAL"
    assert_eq "leader=${state}はresolveが非0終了する" "1" "$rc"
  done

  NOLEADER="$(mktemp -d)/noleader.md"
  make_v2_profile "$NOLEADER" "role.researcher: configured model=t-sonnet-high"
  out="$(resolve_v2 "$NOLEADER")"  || true
  assert_contains "role.leader行が無ければfail(MINIMAL)になる" "$out" "MINIMAL"

  UNAVAIL="$(mktemp -d)/leaderunavail.md"
  make_v2_profile "$UNAVAIL" "role.leader: unavailable model=t-opus-high"
  out="$(resolve_v2 "$UNAVAIL")"  || true
  assert_contains "leader=unavailableはfail" "$out" "MINIMAL"

  err="$(resolve_leader_v2 "$UNAVAIL" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderは機械可読コードLEADER_UNAVAILABLEをstderrへ出す" "$err" "LEADER_UNAVAILABLE"
  # 廃止済みコードは復活しない（AC-4の回帰。マーカー2/4本目）。
  assert_not_contains "旧コードLEADER_UNAVAILABLE_NO_FALLBACKは出ない" "$err" "LEADER_UNAVAILABLE_NO_FALLBACK"  # RETIRED-FIXTURE
}

echo "=== 31. §3.5-L: leader専用規則: 実効候補のproviderがexternalならfail ==="
{
  EXT_LEADER="$(mktemp -d)/extleader.md"
  make_v2_profile "$EXT_LEADER" \
    "role.leader: configured model=codex-review"
  out="$(resolve_v2 "$EXT_LEADER")"  || true
  assert_contains "leaderのprovider=externalはfailになる" "$out" "MINIMAL"
}

echo "=== 32. 候補評価§3.6: ワーカー職はV1-b/V9-d/V12単独では空席にならず、同じ行の2件目以降の候補が使えれば採用される ==="
{
  MULTI_CAND="$(mktemp -d)/workermulticand.md"
  make_v2_profile "$MULTI_CAND" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,t-sonnet-high"
  # bedrock.envを与えない(ABSENT=disabled)のでverifierの1件目(bedrock)はV9-dで使用不可・
  # 2件目(t-sonnet-high)は使用可。
  out="$(resolve_v2 "$MULTI_CAND")"  || true
  assert_not_contains "1件目が使用不可でも2件目が使えれば空席にならない" "$out" "VACANT:verifier"
  assert_contains "resolve自体はOKのまま" "$out" "OK"

  echo "--- 全候補が使用不可のときだけVACANT+VACANT_REASON、優先順はV1-b→V9-d→V12 ---"
  BOTH_BAD="$(mktemp -d)/bothbad.md"
  make_v2_profile "$BOTH_BAD" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus"
  out="$(resolve_v2 "$BOTH_BAD")"  || true
  assert_contains "全候補がbedrockで経路無効なら空席になる" "$out" "VACANT:verifier"
  assert_contains "空席理由の条件番号が出る(V9-d)" "$out" "VACANT_REASON:verifier=V9-d"

  echo "--- unavailableな行は候補を1件も評価せず、良い候補を持っていてもVACANTになる（§3.6：状態は行単位） ---"
  UNAVAIL_LINE="$(mktemp -d)/unavailline.md"
  make_v2_profile "$UNAVAIL_LINE" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unavailable model=t-sonnet-high"
  out="$(resolve_v2 "$UNAVAIL_LINE")"  || true
  assert_contains "unavailableな行は候補が良くてもVACANTになる（意図的な不使用）" "$out" "VACANT:verifier"
  assert_not_contains "評価しないので理由(VACANT_REASON)も付かない" "$out" "VACANT_REASON:verifier"
}

echo "=== 33. §3.7 判定不能: Bedrock経路の判定不能はワーカーなら通す・leaderならfail ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir
  UNREADABLE_ENV="/tmp/aienv-test-unreadable-env-dir/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV"
  chmod 0000 "$UNREADABLE_ENV"

  WORKER_UNKNOWN="$(mktemp -d)/workerunknown.md"
  make_v2_profile "$WORKER_UNKNOWN" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$WORKER_UNKNOWN" "$UNREADABLE_ENV")"  || true
  assert_not_contains "判定不能でもワーカーは空席にならない" "$out" "VACANT:verifier"
  assert_contains "resolve自体はOKのまま" "$out" "OK"

  LEADER_UNKNOWN="$(mktemp -d)/leaderunknownenv.md"
  make_v2_profile "$LEADER_UNKNOWN" \
    "role.leader: configured model=bedrock-opus"
  out="$(resolve_v2 "$LEADER_UNKNOWN" "$UNREADABLE_ENV")"  || true
  assert_contains "判定不能でもleaderはfailになる" "$out" "MINIMAL"

  chmod 0700 "$UNREADABLE_ENV"
  rm -rf /tmp/aienv-test-unreadable-env-dir
}

echo "=== 34. 秘匿: bedrock.envのピン留め実値がresolve/resolve-leaderのいずれの出力にも現れない ==="
{
  PIN_ENV="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn
AWS_ACCESS_KEY_ID=AKIA_SHOULD_NEVER_LEAK
EOF
  SECRET_PROFILE="$(mktemp -d)/secretprofile.md"
  make_v2_profile "$SECRET_PROFILE" \
    "role.leader: configured model=bedrock-opus"
  out="$(resolve_v2 "$SECRET_PROFILE" "$PIN_ENV")"  || true
  assert_not_contains "resolve出力にピン実値(ARN)が現れない" "$out" "supersecret-arn"
  assert_not_contains "resolve出力にAWSキーが現れない" "$out" "AKIA_SHOULD_NEVER_LEAK"

  json="$(resolve_leader_v2 "$SECRET_PROFILE" "$PIN_ENV")"  || true
  assert_not_contains "resolve-leader出力にもピン実値(ARN)が現れない" "$json" "supersecret-arn"
  assert_not_contains "resolve-leader出力にもAWSキーが現れない" "$json" "AKIA_SHOULD_NEVER_LEAK"
  assert_contains "resolve-leaderはmodelとして別名(opus)だけを返す" "$json" '"model": "opus"'
}

echo "=== 35. V15/T11: 禁止キー名はv1/v2どちらの分類でもpreflightでMINIMAL/T11・必読除外になる（v1経路への新規適用） ==="
{
  V15_V2="$(mktemp -d)/v15v2.md"
  make_v2_profile "$V15_V2" \
    "role.leader: configured model=t-opus-high"
  echo "api_key: configured value=xyz" >> "$V15_V2"
  # frontmatter終端---の後ろに付けると構文が壊れるので、専用のfixtureを作り直す。
  cat > "$V15_V2" <<'EOF'
---
schema_version: 7
profile_slug: authoring
role.leader: configured model=t-opus-high
api_key: configured value=xyz
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
---
EOF
  out="$(resolve_v2 "$V15_V2")"  || true
  assert_contains "v2でapi_keyというキー名があるとpreflightでMINIMAL/T11になる" "$out" "MINIMAL	T11"

  echo "--- 統合(DIRECTIVE)側: v1形式にforbidden keyを混ぜてもMINIMAL/T11で必読除外される ---"
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  cat > "$PROFILE_PATH" <<'EOF'
---
team_mode: 本人
no_read_paths: ~/work/old
auth_token: should-not-be-here
---
EOF
  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "v1でも禁止キー名検出で最小能力の警告が出る" "$ctx" "認証情報らしいキー名があります"
  assert_not_contains "全文Readの指示は付かない（必読除外）" "$ctx" "$PROFILE_PATH  （全"
  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 36. 結合（DIRECTIVE）: VACANT_UNKNOWN・VACANT_REASONが職種名と条件番号でDIRECTIVEへ注入される ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus"
  # 静的検証: このprofile単体でVACANT_REASON:verifier=V9-dが出ることを確認済み(#32)。
  # ここではDIRECTIVEへの伝播だけを確認する。

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  assert_contains "DIRECTIVEに配役表の状態行が出る" "$ctx" "配役表の状態"
  assert_contains "VACANT:teseterの職種名が出る" "$ctx" "VACANT:verifier"
  assert_contains "VACANT_REASONの条件番号が出る" "$ctx" "VACANT_REASON:verifier=V9-d"
  # ここで見るのは生の属性構文（`model=`・`provider=`のkey=value形式）が
  # DIRECTIVEへそのまま再掲されないこと（機構が値を再包装せず生のprofile行を
  # 横流しした場合の回帰を検知する）。
  assert_not_contains "配役の属性構文(model=)がそのまま再掲されない" "$ctx" "model="
  assert_not_contains "配役の属性構文(provider=)がそのまま再掲されない" "$ctx" "provider="
  # FR-11（要件v1.2.1）: 職種ごとの候補一覧（定義名のみ）の注入行は撤去した
  # （旧仕様=advisory直後にℹ️行を足す形。候補一覧コマンド新設に伴い
  # SessionStart注入からは0件になる＝NFR-5）。
  assert_eq "候補一覧のℹ️行は0件（FR-11で撤去）" "0" \
    "$(printf '%s\n' "$ctx" | grep -c '^ℹ️ 職種ごとのモデル候補' || true)"

  rm -rf "$VAULT_DIR" "$PROFILE_DIR"
}

echo "=== 37. FR-10対応: v2 OKでも全文Read指示は必読リストに載らない（旧仕様は撤回）。フィールドは固定順（OK→VACANT→VACANT_REASON→VACANT_UNKNOWN→ADVISORY→UNKNOWN_EXTRA） ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  PROFILE_DIR="$(mktemp -d)"
  PROFILE_PATH="$PROFILE_DIR/profile.md"
  make_v2_profile "$PROFILE_PATH" \
    "role.leader: configured model=t-opus-high" \
    "role.requirements-analyst: configured model=t-opus-high"

  ctx="$(run_status_with_profile "$PROFILE_PATH")"
  occurrences="$(printf '%s' "$ctx" | grep -c -- "- $PROFILE_PATH  （全" || true)"
  assert_eq "壊れていないv2プロファイルでも全文Read指示は0件（FR-10）" "0" "$occurrences"

  out="$(resolve_v2 "$PROFILE_PATH")"  || true
  order_ok=1
  case "$out" in
    OK*) ;;
    *) order_ok=0 ;;
  esac
  assert_eq "先頭フィールドは必ずOK" "1" "$order_ok"

  echo "--- フィールドが複数同時に出るケースで固定順を検証する（Codex一次レビュー指摘・Major対応: 従来は先頭がOKかしか見ていなかった） ---"
  MULTI="$(mktemp -d)/multi.md"
  make_v2_profile "$MULTI" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,bedrock-opus" \
    "role.researcher: configured model=t-sonnet-high"
  multi_out="$(resolve_v2 "$MULTI")"  || true
  # 期待: OK -> VACANT:verifier -> VACANT_REASON:verifier=V9-d -> VACANT_UNKNOWN
  # (コアマニフェストの他職種) -> ADVISORY:V1-a の順で、この並びどおりに現れること。
  idx_ok=$(printf '%s' "$multi_out" | grep -bo '^OK' | head -1 | cut -d: -f1)
  idx_vacant=$(printf '%s' "$multi_out" | grep -bo 'VACANT:' | head -1 | cut -d: -f1)
  idx_vacant_reason=$(printf '%s' "$multi_out" | grep -bo 'VACANT_REASON:' | head -1 | cut -d: -f1)
  idx_vacant_unknown=$(printf '%s' "$multi_out" | grep -bo 'VACANT_UNKNOWN:' | head -1 | cut -d: -f1)
  idx_advisory=$(printf '%s' "$multi_out" | grep -bo 'ADVISORY:' | head -1 | cut -d: -f1)
  assert_contains "複合ケースでVACANTにverifierが出る" "$multi_out" "VACANT:verifier"
  order_multi_ok=1
  [ -n "$idx_ok" ] && [ -n "$idx_vacant" ] && [ "$idx_ok" -lt "$idx_vacant" ] || order_multi_ok=0
  [ -n "$idx_vacant" ] && [ -n "$idx_vacant_reason" ] && [ "$idx_vacant" -lt "$idx_vacant_reason" ] || order_multi_ok=0
  [ -n "$idx_vacant_reason" ] && [ -n "$idx_vacant_unknown" ] && [ "$idx_vacant_reason" -lt "$idx_vacant_unknown" ] || order_multi_ok=0
  [ -n "$idx_vacant_unknown" ] && [ -n "$idx_advisory" ] && [ "$idx_vacant_unknown" -lt "$idx_advisory" ] || order_multi_ok=0
  assert_eq "OK→VACANT→VACANT_REASON→VACANT_UNKNOWN→ADVISORYの出現順が固定順どおり" "1" "$order_multi_ok"
}

echo "=== 38. 候補評価§3.6: 1件目と2件目の失敗理由が異なるとき、優先順(V1-b→V9-d→V12)で高い方が採用される（ホワイトボックス・Codex二次レビュー指摘・Major対応: CLI経由のfixtureでは1件目/2件目が同一職種名を共有するためV1-bは両者で必ず同じ結果になり、異なる理由の組み合わせを黒箱では再現できない。_evaluate_single_candidate()を差し替えて優先順ロジック自体を直接検証する） ==="
{
  # 2026-09-08 モデル定義ファイルと候補指定対応: evaluate_worker_candidate()の
  # シグネチャがresolved辞書（{name: [ModelDef,...]}）を取るように変わり、
  # 内部で候補ごとにCandidate(name, ModelDef)を組み立ててから
  # _evaluate_single_candidate()へ渡すようになった（1行1候補→1行n候補）。
  # そのためline識別はオブジェクトの同一性ではなくdef_nameで行う。
  # 2026-09-16 代替配役の層の撤去に合わせ、resolved辞書のキーを
  # (kind,name)からnameへ、evaluate_worker_candidate()の引数を5個へ縮める。
  result="$(PYTHONPATH="$REPO_ROOT/team/executor" python3 - <<'PYEOF'
import profile_resolve as pr


class Fake:
    def __init__(self, name):
        self.name = name
        self.state = "configured"


def make_def(name):
    d = pr.ModelDef(name, 0)
    d.provider = "anthropic-api"
    d.model = "claude-opus-5-5"
    d.execution = "subagent"
    return d


def fake_eval(cand, agents_dir, bedrock_env, is_leader):
    if cand.def_name == "first-def":
        return False, "V9-d", None
    return False, "V1-b", None


primary = Fake("verifier")
resolved = {
    "verifier": [make_def("first-def"), make_def("second-def")],
}
orig = pr._evaluate_single_candidate
pr._evaluate_single_candidate = fake_eval
try:
    cand = pr.evaluate_worker_candidate("verifier", {"verifier": primary}, resolved, None, None)
finally:
    pr._evaluate_single_candidate = orig
print(cand.vacant_reason)
PYEOF
)"
  assert_eq "1件目=V9-d・2件目=V1-bでもV1-bの方が優先順が高いのでV1-bが選ばれる" "V1-b" "$result"
}

echo "=== 39. §3.7 判定不能: ワーカーが判定不能で通ったこと自体がADVISORY(JUDGEMENT_UNKNOWN)として出る（Codex一次レビュー指摘・Major対応: 従来はunknown_noteを保持するだけで出力していなかった） ==="
{
  mkdir -p /tmp/aienv-test-unreadable-env-dir2
  UNREADABLE_ENV2="/tmp/aienv-test-unreadable-env-dir2/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$UNREADABLE_ENV2"
  chmod 0000 "$UNREADABLE_ENV2"

  ADV_UNKNOWN="$(mktemp -d)/advunknown.md"
  make_v2_profile "$ADV_UNKNOWN" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$ADV_UNKNOWN" "$UNREADABLE_ENV2")"  || true
  assert_contains "判定不能で通した職種があることがADVISORY:JUDGEMENT_UNKNOWNとして出る" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"

  chmod 0700 "$UNREADABLE_ENV2"
  rm -rf /tmp/aienv-test-unreadable-env-dir2
}

echo "=== 40. 代替配役の層の撤去の回帰: 職種の2件目の候補が採用されても撤去済みフィールドは一切出ない ==="
{
  # ⚠️ 撤去済みフィールド名を検索語としてソースへ直書きしない（AC-1の
  # repo検索に一致しないよう分割代入する。上のlegacy_excluded_keyと同じ手口）。
  retired_field_name="FALL""BACK:"
  MULTI_OK="$(mktemp -d)/multiok.md"
  make_v2_profile "$MULTI_OK" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku,t-sonnet-high"
  out="$(resolve_v2 "$MULTI_OK")"  || true
  assert_not_contains "1件目が使用不可で2件目が採用されても撤去済みフィールドは出ない" "$out" "$retired_field_name"
}

echo "=== 41. 秘匿: check-candidateとresolve-leaderのstderr（失敗時）にもピン実値・AWS認証情報が一切現れない（Codex一次レビュー指摘・Major対応: 従来のテストはresolveの標準出力だけを見ていた） ==="
{
  PIN_ENV2="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV2" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn-2
AWS_SECRET_ACCESS_KEY=SHOULD_NEVER_LEAK_2
EOF
  # Codex二次レビュー指摘・Major対応: --model opusはピン(ANTHROPIC_DEFAULT_
  # OPUS_MODEL)が満たされているためcheck-candidateはOK(成功)を返し、失敗経路の
  # 秘匿を検査したことにならなかった。ピンが無いhaikuを使いFAIL経路を通す。
  cc_out="$(python3 "$PROFILE_LIB" check-candidate --provider bedrock --model haiku \
    --role-name leader --for-leader --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1)"  || true
  assert_contains "check-candidateが実際にFAILを返している（テストの前提確認）" "$cc_out" "FAIL"
  assert_not_contains "check-candidate出力にピン実値が現れない" "$cc_out" "supersecret-arn-2"
  assert_not_contains "check-candidate出力にAWSキーが現れない" "$cc_out" "SHOULD_NEVER_LEAK_2"

  LEADER_FAIL_ENV="$(mktemp -d)/leaderfailenv.md"
  make_v2_profile "$LEADER_FAIL_ENV" "role.leader: configured model=bedrock-sonnet"
  leader_err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_FAIL_ENV" --bedrock-env "$PIN_ENV2" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_not_contains "resolve-leaderのstderrにもピン実値が現れない" "$leader_err" "supersecret-arn-2"
  assert_not_contains "resolve-leaderのstderrにもAWSキーが現れない" "$leader_err" "SHOULD_NEVER_LEAK_2"
}

echo "=== 42. §3.4 T4'(実体の版>コードの版): 未知キーを無視しADVISORY:T4-PRIME+UNKNOWN_EXTRAで通す(最小能力へは倒さない) ==="
{
  T4PRIME="$(mktemp -d)/t4prime.md"
  make_v2_profile "$T4PRIME" \
    "role.leader: configured model=t-opus-high"
  sed -i '' 's/schema_version: 7/schema_version: 8/' "$T4PRIME"
  # ---の直前に未知キーを挿入する。

  python3 - "$T4PRIME" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "future_key_v3: configured value=something")
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  out="$(resolve_v2 "$T4PRIME")"  || true
  assert_contains "T4-PRIME: MINIMALへは倒さない" "$out" "OK"
  assert_contains "T4-PRIME: ADVISORYコードが出る" "$out" "ADVISORY:T4-PRIME"
  assert_contains "T4-PRIME: 未知キーはUNKNOWN_EXTRAにも出る" "$out" "UNKNOWN_EXTRA:future_key_v3"
}

echo "=== 44. V8-b共通規則（Codex一次レビュー指摘・Major対応） ==="
{
  DUP_VALUE="$(mktemp -d)/dupvalue.md"
  make_v2_profile "$DUP_VALUE" \
    "role.leader: configured model=t-opus-high"
  sed -i '' 's/team_mode:        configured value=full/team_mode:        configured value=full,full/' "$DUP_VALUE"
  out="$(resolve_v2 "$DUP_VALUE")"  || true
  assert_contains "value内の重複要素はV8-bでMINIMALになる（共通規則）" "$out" "MINIMAL	T8	V8-b"
}

echo "=== 45. is_v2_resolve_output_well_formed(): ゴミ混入・重複・順序違反はいずれも拒否される（Codex三次レビュー指摘・Major対応） ==="
{
  source_well_formed() {
    # bootstrap-vault.sh から is_v2_resolve_output_well_formed だけを取り込む
    # （本体を実行させないよう、関数定義を含む範囲だけをsedで切り出す）。
    eval "$(sed -n '/^is_v2_resolve_output_well_formed()/,/^}/p' "$SCRIPT")"
  }
  source_well_formed

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "正常なOK単体は受理される" || fail_case "正常なOK単体は受理される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tGARBAGE:xyz')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "未知フィールド(GARBAGE)混入は拒否される" || fail_case "未知フィールド(GARBAGE)混入は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT:verifier\tVACANT:verifier')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "同一フィールドの重複は拒否される" || fail_case "同一フィールドの重複は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT_REASON:verifier=V9-d\tVACANT:verifier')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "フィールドの順序違反(VACANT_REASONがVACANTより先)は拒否される" || fail_case "フィールドの順序違反(VACANT_REASONがVACANTより先)は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 1 && pass "OKなのにexit1は拒否される" || fail_case "OKなのにexit1は拒否される"

  T="$(printf 'MINIMAL\tT6\t3行目: 解析できない行です')"
  is_v2_resolve_output_well_formed "$T" 1 && pass "正常なMINIMAL(exit1)は受理される" || fail_case "正常なMINIMAL(exit1)は受理される"

  T="$(printf 'MINIMAL\tT6\t理由')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MINIMALなのにexit0は拒否される" || fail_case "MINIMALなのにexit0は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\nEXTRA_LINE')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "複数行出力は拒否される" || fail_case "複数行出力は拒否される"

  T="$(printf 'MINIMAL\tT6\t3行目: 解析できない行です\tGARBAGE')"
  ! is_v2_resolve_output_well_formed "$T" 1 && pass "MINIMALの理由部分にタブで4つ目のフィールドが紛れ込むと拒否される（Codex三次レビュー指摘・Major対応）" \
    || fail_case "MINIMALの理由部分にタブで4つ目のフィールドが紛れ込むと拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\tVACANT_UNKNOWN:My_Role.v2')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "大文字・アンダースコア・ドットを含む職種名も受理される（Codex三次レビュー指摘・Major対応: parserのKEY_RE[A-Za-z0-9_.-]+と同じ文字集合に統一）" \
    || fail_case "大文字・アンダースコア・ドットを含む職種名も受理される"

  T="$(printf 'OK\tschema_version=2')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "TEAM_MODE:欠落は拒否される（3モード体制-設計-2026-09-06.md §4.2＝必須フィールド）" \
    || fail_case "TEAM_MODE:欠落は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:quick\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "TEAM_MODE:の値が4語のいずれでもないと拒否される" \
    || fail_case "TEAM_MODE:の値が4語のいずれでもないと拒否される"

  T="$(printf 'OK\tschema_version=2\tVACANT:verifier\tTEAM_MODE:full\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "TEAM_MODE:がschema_versionの直後以外の位置にあると拒否される" \
    || fail_case "TEAM_MODE:がschema_versionの直後以外の位置にあると拒否される"

  # 配役表-能力軸整理-設計-2026-09-07.md §4.2・D-2: MACHINE_ROLE:はTEAM_MODE:の
  # 直後・必須フィールド。
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:欠落は拒否される（D-2＝必須フィールド）" \
    || fail_case "MACHINE_ROLE:欠落は拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:primary')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:の値がmain/sub/unknown/unavailableのいずれでもないと拒否される" \
    || fail_case "MACHINE_ROLE:の値が不正だと拒否される"

  # TEAM_MODEは正しい位置のまま、MACHINE_ROLEだけをTEAM_MODEの直後以外へ
  # 動かす（TEAM_MODEの位置違反とは独立にMACHINE_ROLEの位置だけを検証する）。
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tVACANT:verifier\tMACHINE_ROLE:main')"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:がTEAM_MODE:の直後以外の位置にあると拒否される" \
    || fail_case "MACHINE_ROLE:がTEAM_MODE:の直後以外の位置にあると拒否される"

  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:unknown')"
  is_v2_resolve_output_well_formed "$T" 0 && pass "MACHINE_ROLE:unknownは受理される" \
    || fail_case "MACHINE_ROLE:unknownは受理される"

  # 検証1巡目MINOR-4対応（設計§6.3⑩）: 撤去済みフィールドを含む行は
  # 不正として拒否される（AC-1・AC-2に引っかからないよう分割代入する）。
  retired_field_name="FALL""BACK:verifier"
  T="$(printf 'OK\tschema_version=2\tTEAM_MODE:full\tMACHINE_ROLE:main\t%s' "$retired_field_name")"
  ! is_v2_resolve_output_well_formed "$T" 0 && pass "撤去済みフィールドを含む行は拒否される" \
    || fail_case "撤去済みフィールドを含む行は拒否される"
}

echo "=== 46. list-roles: state/定義名/execution既定値/not_adopted・unknownの空欄化（2026-09-16 代替配役の層の撤去で7列・単一role.表へ改訂＝設計§3.4） ==="
{
  LR="$(mktemp -d)/listroles.md"
  make_v2_profile "$LR" \
    "role.leader: configured model=t-opus-high" \
    "role.navi: unknown" \
    "role.researcher: not_adopted" \
    "role.system-designer: configured model=t-opus-high" \
    "role.verifier: unavailable model=bedrock-opus"
  out="$(python3 "$PROFILE_LIB" list-roles "$LR")"  || true

  assert_contains "role.leaderの行がstate=configured・定義名=t-opus-highで出る" "$out" "leader	configured	t-opus-high	anthropic-api	claude-opus-5-5	subagent	"
  assert_contains "executionが省略されていてもsubagentが補われて出る" "$out" "	subagent	"
  assert_contains "effortが指定されていればそのまま出る(system-designer=high)" "$out" "system-designer	configured	t-opus-high	anthropic-api	claude-opus-5-5	subagent	high"
  assert_contains "unknown状態は定義名以降が全て空文字になる（5フィールド）" "$out" "navi	unknown					"
  assert_contains "not_adopted状態も定義名以降が全て空文字になる（5フィールド）" "$out" "researcher	not_adopted					"
  assert_contains "unavailable状態は定義名・provider/modelを保持したまま出る（意図の記録）" "$out" "verifier	unavailable	bedrock-opus	bedrock	opus	subagent	"
  assert_not_contains "kind列は撤去済みなので先頭に'role'は出ない" "$out" "role	leader"

  count="$(printf '%s' "$out" | awk -F'\t' '{print NF}' | sort -u | wc -l | tr -d ' ')"
  assert_eq "全行が7列で揃っている（列数のばらつきが無い）" "1" "$count"
}

echo "=== 47. list-roles: 失敗時（自己完結・resolve-leaderと同じコード体系）はstdoutが空でstderrへ機械可読コードが出る ==="
{
  err="$(python3 "$PROFILE_LIB" list-roles /nonexistent-dir/nope.md 2>&1 1>/dev/null)"  || true
  assert_contains "存在しないファイルはPROFILE_NOT_FOUNDになる" "$err" "PROFILE_NOT_FOUND"

  DUP="$(mktemp -d)/lrdup.md"
  make_v2_profile "$DUP" \
    "role.leader: configured model=t-opus-high" \
    "role.leader: unknown"
  out="$(python3 "$PROFILE_LIB" list-roles "$DUP" 2>/dev/null)"  || true
  err="$(python3 "$PROFILE_LIB" list-roles "$DUP" 2>&1 1>/dev/null)"  || true
  assert_eq "パース失敗時はstdoutが空" "" "$out"
  assert_contains "パース失敗時はstderrへPROFILE_INVALID:T6が出る" "$err" "PROFILE_INVALID:T6"
}

echo "=== 48. 秘匿: list-rolesの出力にもbedrock.envのピン実値・AWS認証情報が一切現れない（リーダー裁定2026-09-01の指示どおり§10の秘匿テストを追加） ==="
{
  PIN_ENV3="$(mktemp -d)/bedrock.env"
  cat > "$PIN_ENV3" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-supersecret-arn-3
AWS_SECRET_ACCESS_KEY=SHOULD_NEVER_LEAK_3
EOF
  LR_SECRET="$(mktemp -d)/lrsecret.md"
  make_v2_profile "$LR_SECRET" \
    "role.leader: configured model=bedrock-opus"
  # list-rolesはbedrock-envを引数に取らない（profile本体の値=別名しか扱わない
  # 設計）ため、そもそもbedrock.envを読まない。念のため実際に出力へ実値が
  # 混入していないことを確認する。
  out="$(python3 "$PROFILE_LIB" list-roles "$LR_SECRET")"  || true
  assert_not_contains "list-roles出力にピン実値(ARN)が現れない" "$out" "supersecret-arn-3"
  assert_not_contains "list-roles出力にAWSキーが現れない" "$out" "SHOULD_NEVER_LEAK_3"
  assert_contains "list-roles出力にはBedrockの別名(opus)だけが出る" "$out" "leader	configured	bedrock-opus	bedrock	opus	subagent	"
}

echo "=== 49. tester独立検証差し戻し(Major): bedrock.envに不正UTF-8があってもクラッシュせず、判定不能として扱われる（_read_bedrock_env_wanted()がUnicodeDecodeErrorを未捕捉だった実バグの回帰テスト） ==="
{
  BAD_UTF8_ENV="$(mktemp -d)/bedrock.env"
  printf 'CLAUDE_CODE_USE_BEDROCK=1\nANTHROPIC_DEFAULT_HAIKU_MODEL=\xff\xfebroken\n' > "$BAD_UTF8_ENV"

  WORKER_BAD_UTF8="$(mktemp -d)/workerbadutf8.md"
  make_v2_profile "$WORKER_BAD_UTF8" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-haiku"
  out="$(resolve_v2 "$WORKER_BAD_UTF8" "$BAD_UTF8_ENV")"  || true
  err="$(python3 "$PROFILE_LIB" resolve "$WORKER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "workerは判定不能で通り(JUDGEMENT_UNKNOWN)クラッシュしない" "$out" "ADVISORY:JUDGEMENT_UNKNOWN"
  assert_not_contains "workerはVACANTにならない" "$out" "VACANT:verifier"
  assert_not_contains "stderrにPythonのtracebackが出ない" "$err" "Traceback"

  LEADER_BAD_UTF8="$(mktemp -d)/leaderbadutf8.md"
  make_v2_profile "$LEADER_BAD_UTF8" "role.leader: configured model=bedrock-haiku"
  out2="$(resolve_v2 "$LEADER_BAD_UTF8" "$BAD_UTF8_ENV")"  || true
  err2="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "leaderはクリーンな機械可読コードで非0終了する" "$out2" "MINIMAL"
  assert_not_contains "resolveのstderrにもtracebackが出ない" "$(python3 "$PROFILE_LIB" resolve "$LEADER_BAD_UTF8" --bedrock-env "$BAD_UTF8_ENV" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)" "Traceback"
  assert_not_contains "resolve-leaderのstderrにtracebackが出ない" "$err2" "Traceback"
  assert_contains "resolve-leaderは機械可読コード(LEADER_CANDIDATE_INVALID)を返す" "$err2" "LEADER_CANDIDATE_INVALID"

  echo "--- --check-profile相当(list-roles)も不正UTF-8のbedrock.envの影響を受けない(list-rolesはbedrock.envを読まない設計のため無関係だが念のため) ---"
  lr_out="$(python3 "$PROFILE_LIB" list-roles "$WORKER_BAD_UTF8" 2>&1)"  || true
  assert_not_contains "list-rolesもtracebackを出さない" "$lr_out" "Traceback"
}

echo "=== 51. V14メタ構文の直接検証: schema_versionが正整数でない・profile_slugが規約に反する ==="
{
  BADVER="$(mktemp -d)/badver.md"
  make_v2_profile "$BADVER" "role.leader: configured model=t-opus-high"
  sed -i '' 's/schema_version: 7/schema_version: abc/' "$BADVER"
  out="$(resolve_v2 "$BADVER")"  || true
  assert_contains "schema_versionが数値でなければT3になる" "$out" "MINIMAL	T3"

  BADVER0="$(mktemp -d)/badver0.md"
  make_v2_profile "$BADVER0" "role.leader: configured model=t-opus-high"
  sed -i '' 's/schema_version: 7/schema_version: 0/' "$BADVER0"
  out="$(resolve_v2 "$BADVER0")"  || true
  assert_contains "schema_version=0(正整数でない)もT3になる" "$out" "MINIMAL	T3"

  BADSLUG="$(mktemp -d)/badslug.md"
  make_v2_profile "$BADSLUG" "role.leader: configured model=t-opus-high"
  sed -i '' 's/profile_slug: authoring/profile_slug: Bad_Slug!/' "$BADSLUG"
  out="$(resolve_v2 "$BADSLUG")"  || true
  assert_contains "profile_slugが規約(^[a-z0-9][a-z0-9-]*\$)に反するとT14になる" "$out" "MINIMAL	T14"
}

echo "=== 52. V8-a 状態4値×属性有無の網羅補充: unavailableでmodel欠落・unknownが属性を持つ ==="
{
  UNAVAIL_MISSING="$(mktemp -d)/unavailmissing.md"
  make_v2_profile "$UNAVAIL_MISSING" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unavailable"
  out="$(resolve_v2 "$UNAVAIL_MISSING")"  || true
  assert_contains "unavailableでもmodel欠落はV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  UNKNOWN_ATTR="$(mktemp -d)/unknownattr.md"
  make_v2_profile "$UNKNOWN_ATTR" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: unknown model=t-sonnet-high"
  out="$(resolve_v2 "$UNKNOWN_ATTR")"  || true
  assert_contains "unknown状態で属性を持つとV8-aでMINIMALになる" "$out" "MINIMAL	T8	V8-a"

  # 2026-09-08 モデル定義ファイルと候補指定対応: 旧「providerが無いこともV8-a
  # でMINIMALになる」ケースは撤去した——role行はもうprovider属性を持たない
  # ため、そのケース自体が成立しない（`model=claude-opus-5-5`は定義名として
  # 文法上妥当に読め、未定義参照ならV17で落ちる。V8-aの対象外）。
}

echo "=== 53. bedrock-mantle provider: 適合表(§3.3)の形式検査(モデル定義ファイル側=T12)とV12対象外(ピンチェックを課さない) ==="
{
  MANTLE_OK="$(mktemp -d)/mantleok.md"
  make_v2_profile "$MANTLE_OK" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=mantle-haiku"
  # bedrock.envは渡すがCLAUDE_CODE_USE_BEDROCKだけ有効にする(ピンは無し)。
  MANTLE_ENV="$(mktemp -d)/bedrock.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$MANTLE_ENV"
  out="$(resolve_v2 "$MANTLE_OK" "$MANTLE_ENV")"  || true
  assert_contains "bedrock-mantleは正しい形式(anthropic.で始まる)ならOKになる(V12の対象外)" "$out" "OK"
  assert_not_contains "bedrock-mantleはVACANTにならない(ピンチェック不要)" "$out" "VACANT:verifier"

  MANTLE_BAD="$(mktemp -d)/mantlebad.md"
  MANTLE_BAD_CONF="$(mktemp -d)/mantlebad.conf"
  make_model_defs "$MANTLE_BAD_CONF" "[bad-mantle]" "provider=bedrock-mantle" "model=not-anthropic-prefixed"
  make_v2_profile "$MANTLE_BAD" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$MANTLE_BAD_CONF" resolve_v2 "$MANTLE_BAD")"  || true
  assert_contains "bedrock-mantleでanthropic.始まりでないmodelはT12でMINIMALになる" "$out" "MINIMAL	T12"
}

echo "=== 54. effort enum境界の直接検証(V9-b/V9-e): Claude系max・Codex方言minimal・設定効果先の非対称 ==="
{
  WORKER_MAX="$(mktemp -d)/workermax.md"
  make_v2_profile "$WORKER_MAX" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=sonnet-max"
  out="$(resolve_v2 "$WORKER_MAX")"  || true
  assert_contains "ワーカー行はmaxを書ける(V9-bのenumはEFFORT_CLAUDEでmaxを含む)" "$out" "OK"

  LEADER_MAX="$(mktemp -d)/leadermax.md"
  make_v2_profile "$LEADER_MAX" "role.leader: configured model=opus-max"
  out="$(resolve_v2 "$LEADER_MAX")"  || true
  assert_contains "leader行はmaxだとV9-eで弾かれfailになる(settings.jsonのeffortLevelがmaxを受理しないため)" "$out" "MINIMAL"
  err="$(python3 "$PROFILE_LIB" resolve-leader "$LEADER_MAX" --agents-dir "$AGENTS_DIR" 2>&1 1>/dev/null)"  || true
  assert_contains "resolve-leaderのエラーコードにV9-eが出る" "$err" "V9-e"

  CODEX_MINIMAL="$(mktemp -d)/codexminimal.md"
  make_v2_profile "$CODEX_MINIMAL" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=codex-review-minimal"
  out="$(resolve_v2 "$CODEX_MINIMAL")"  || true
  assert_contains "Codexハンドラ(external-cli/codex-review-default)はminimalを書ける" "$out" "OK"

  # 2026-09-08 モデル定義ファイルと候補指定対応: effortの許可集合検査は
  # モデル定義ファイル側（validate_model_def・T12）へ移った。
  CODEX_MINIMAL_ELSEWHERE_CONF="$(mktemp -d)/codexminimalelsewhere.conf"
  make_model_defs "$CODEX_MINIMAL_ELSEWHERE_CONF" "[bad-sonnet-minimal]" "provider=anthropic-api" "model=claude-sonnet-5" "effort=minimal"
  CODEX_MINIMAL_ELSEWHERE="$(mktemp -d)/codexminimalelsewhere.md"
  make_v2_profile "$CODEX_MINIMAL_ELSEWHERE" "role.leader: configured model=t-opus-high"
  out="$(AIENV_MODEL_DEFS_FILE="$CODEX_MINIMAL_ELSEWHERE_CONF" resolve_v2 "$CODEX_MINIMAL_ELSEWHERE")"  || true
  assert_contains "Claude系(anthropic-api)でminimalはT12でMINIMALになる(Codex方言はexternalハンドラ限定)" "$out" "MINIMAL	T12"
}

echo "=== 55. V9-f直接検証: 既知の非対応モデル×xhigh はADVISORY、別名は判別不能としてEFFORT_COMPATIBILITY_UNVERIFIED ==="
{
  V9F_KNOWN="$(mktemp -d)/v9fknown.md"
  make_v2_profile "$V9F_KNOWN" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=opus46-xhigh"
  out="$(resolve_v2 "$V9F_KNOWN")"  || true
  # ADVISORYフィールドはコードをソートして併記する(§5)ため"V1-a,V9-f"に
  # なる。"ADVISORY:V9-f"という直結文字列を探すのは誤り(実測で判明)。
  assert_contains "既知の非対応モデル(claude-opus-4.6)×xhighはV9-fがADVISORYに含まれる(failにしない)" "$out" "V9-f"
  assert_contains "failにしない(OKのまま)" "$out" "OK"

  V9F_BEDROCK="$(mktemp -d)/v9fbedrock.md"
  make_v2_profile "$V9F_BEDROCK" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-opus-xhigh"
  out="$(resolve_v2 "$V9F_BEDROCK")"  || true
  assert_contains "bedrock別名は実モデル版を判別できないためEFFORT_COMPATIBILITY_UNVERIFIEDになる" "$out" "ADVISORY:EFFORT_COMPATIBILITY_UNVERIFIED"
}

echo "=== 56. BOOTSTRAP_ENABLE_LOCAL_PROFILE を指定しなければコードの既定値1でP1機構が有効になる ==="
{
  VAULT_DIR="$(mktemp -d)"
  make_full_vault "$VAULT_DIR"
  ctx="$(echo '{"session_id":"test-session-0000"}' \
    | env -u BOOTSTRAP_ENABLE_LOCAL_PROFILE \
        BOOTSTRAP_VAULT="$VAULT_DIR" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
        VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
        VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
        MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
        MAINTENANCE_PLIST_FILE="/nonexistent-dir/com.takumi009.maintenance.plist" \
        HEALTH_OBSERVATION_FILE="/nonexistent-dir/health/session-observation.json" \
        AIENV_LOCAL_PROFILE_PATH="/nonexistent-dir/profile-for-default-gate-test.md" \
        "$SCRIPT" \
    | jq -r '.hookSpecificOutput.additionalContext')"
  mode_line_default_gate="$(printf '%s\n' "$ctx" | grep '^🧭 現在＝')"
  assert_contains "フラグ未指定でも既定値1でP1機構が動く(T1のモード行区分コードが出る)" "$mode_line_default_gate" "（T1）"
  rm -rf "$VAULT_DIR"
}

echo "=== 57. V1-aマニフェスト: team/rules/agents/vault-scribe.mdは職種名'vault-scribe'としてファイル名そのままマニフェストへ数えられ、旧職種名'scribe'は入らない（2026-09-03本人裁定・方針変更: 対応表〈旧AGENT_FILE_TO_ROLE〉でファイル名と職種名の不一致を吸収する方式は、サブ機で『role.scribeを見てsubagent_type=scribeでspawn→定義ファイルが無く失敗』という実害が起きたため撤回し、配役表側のキーをrole.vault-scribeへ改名して職種名＝ファイル名の不変条件に揃える方式へ変更した） ==="
{
  # role_and_core_manifest_diff()本体を直接呼ぶ（マニフェスト計算ロジックの
  # 再実装ではなく、実装コードそのものを検証する）。role表は空にし、
  # only_in_manifest（＝マニフェスト全件）をそのまま確認する。
  result="$(PYTHONPATH="$REPO_ROOT/team/executor" python3 - "$AGENTS_DIR" <<'PYEOF'
import sys
import profile_resolve as pr


class FakeParsed:
    roles: dict = {}


agents_dir = sys.argv[1]
_, only_in_manifest = pr.role_and_core_manifest_diff(FakeParsed(), agents_dir)
print("vault_scribe_count=" + str(only_in_manifest.count("vault-scribe")))
print("scribe_present=" + str("scribe" in only_in_manifest))
PYEOF
)"
  assert_contains "マニフェストに'vault-scribe'が1回だけ入る（ファイル名そのまま）" "$result" "vault_scribe_count=1"
  assert_contains "旧職種名'scribe'はマニフェストに入らない" "$result" "scribe_present=False"
}

echo "=== 58. V1-aマニフェスト(結合): role.vault-scribeを含む現行の全ロール構成でresolve()を通してもADVISORY:V1-aが出ない（57.の単体確認をCLI経由でも裏付け。2026-09-03本人裁定・方針変更対応） ==="
{
  # 実AGENTS_DIR（team/rules/agents/）を使い、現行のコア職種マニフェスト全件
  # （CORE_ROLES_WITHOUT_REPO_AGENT_FILE + team/rules/agents/*.md＝ファイル名
  # そのまま）ちょうどをrole.表へ宣言する。leader以外は状態を"unknown"に
  # して属性検証（V9-b等）を回避し、V1-aの対称差判定だけに焦点を絞る
  # （他ロールのstateはV1-aの結果に影響しない＝role_and_core_manifest_diff()
  # はparsed.rolesのキーのみを見る）。
  #
  # ロースター行は職種名をハードコードせず、CORE_ROLES_WITHOUT_REPO_AGENT_FILE
  # と AGENTS_DIR の *.md の stem から生成する（2026-09-20 設計 §4.4: 職種の
  # 追加・削除でこのテストの改修が要らないようにする）。bash 3.2 のため
  # 連想配列は使わず通常配列で組む。
  CORE_ROLE_NAMES="$(PYTHONPATH="$REPO_ROOT/team/executor" python3 -c \
    'import profile_resolve as pr; print("\n".join(sorted(pr.CORE_ROLES_WITHOUT_REPO_AGENT_FILE)))')"
  AGENT_FILE_STEMS=""
  for f in "$AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    stem="${f##*/}"; stem="${stem%.md}"
    AGENT_FILE_STEMS="${AGENT_FILE_STEMS}${stem}"$'\n'
  done
  # 生成の前提（空虚な真の禁止）: team/rules/agents/*.md が0件ならロースターが
  # 成立しないので、後続の判定に進む前にここで fail にする。
  stems_present=0
  [ -n "$AGENT_FILE_STEMS" ] && stems_present=1
  assert_true "生成の前提: team/rules/agents/*.md が1件以上ある（0件ならロースター生成不能）" "$stems_present"

  ROSTER_LINES=()
  while IFS= read -r role_name; do
    [ -n "$role_name" ] || continue
    if [ "$role_name" = "leader" ]; then
      ROSTER_LINES+=("role.leader: configured model=t-opus-high")
    else
      ROSTER_LINES+=("role.${role_name}: unknown")
    fi
  done <<ROSTER_EOF
$CORE_ROLE_NAMES
$AGENT_FILE_STEMS
ROSTER_EOF

  COMPLETE_ROSTER="$(mktemp -d)/complete-roster.md"
  make_v2_profile "$COMPLETE_ROSTER" "${ROSTER_LINES[@]}"

  out="$(resolve_v2 "$COMPLETE_ROSTER")"  || true
  # bash 3.2(macOS既定)では`$(case ... esac)`のような command substitution
  # 内caseの構文解析に既知の不具合があるため、他のテスト（22番等）と同じく
  # caseを独立文として使い、結果を変数へ代入する方式に揃える。
  head_ok=0
  case "$out" in
    OK*) head_ok=1 ;;
  esac
  assert_eq "先頭フィールドはOK（プロファイル自体は妥当）" "1" "$head_ok"
  assert_not_contains "role.vault-scribeで揃えればADVISORY:V1-aが出ない" "$out" "ADVISORY:V1-a"
}

echo "=== 58b. V1-aマニフェスト(結合・回帰防止・対照実験): 完全ロースターのうち'role.vault-scribe'の1行だけを旧キー'role.scribe'へ差し替えると、他は一切変えていないのにADVISORY:V1-aが出るようになる（受入条件どおり・2026-09-03本人裁定: 特別な互換処理は入れない＝'行を書かなかった職種はunknown'の既存規則に従い、vault-scribeはVACANT_UNKNOWN・scribeはマニフェストに無いキーとしてV1-a advisoryに出る。Codexレビュー指摘・Minor対応: 当初はleaderとscribeの2行だけの疎なプロファイルで検証しており、他の10職種が欠けていること自体でもV1-aが出てしまうため『role.scribeへの置換だけが原因』というこの受入条件を厳密に隔離できていなかった。58.の完全ロースターから1行だけ差し替える対照実験にすることで、原因を旧キーの使用だけに絞り込む） ==="
{
  # 58.で生成した完全ロースター（ROSTER_LINES）から、'role.vault-scribe'の
  # 行だけを'role.scribe'（旧キー）へ差し替える。他の行（leader含む）は58.と
  # 完全に同一。vault-scribeは固定職種なのでここでの名指しは可。
  OLD_KEY_LINES=()
  replaced=0
  for line in "${ROSTER_LINES[@]}"; do
    if [ "$line" = "role.vault-scribe: unknown" ]; then
      OLD_KEY_LINES+=("role.scribe: unknown"); replaced=1
    else
      OLD_KEY_LINES+=("$line")
    fi
  done
  assert_true "対照実験の前提: 58.のロースターに role.vault-scribe の行がある（差し替え対象が存在する）" "$replaced"

  OLD_KEY_ROSTER="$(mktemp -d)/old-key-roster.md"
  make_v2_profile "$OLD_KEY_ROSTER" "${OLD_KEY_LINES[@]}"

  out="$(resolve_v2 "$OLD_KEY_ROSTER")"  || true
  assert_contains "58.の完全ロースターと1行しか違わないのに、旧キー'role.scribe'のままではADVISORY:V1-aが出る（改名を促す）" "$out" "ADVISORY:V1-a"
  assert_contains "vault-scribeはマニフェストにあるがrole表に無いためVACANT_UNKNOWNに出る" "$out" "vault-scribe"
}

echo "=== 59. 方針変更の反映確認: 旧方式の対応表（AGENT_FILE_TO_ROLE・ROLE_LOCAL_AGENT_FILE）がコードから完全に撤去されている（2026-09-03本人裁定・方針変更。将来誰かが対応表方式を再導入する回帰を検知する） ==="
{
  result="$(PYTHONPATH="$REPO_ROOT/team/executor" python3 - <<'PYEOF'
import profile_resolve as pr

print("has_agent_file_to_role=" + str(hasattr(pr, "AGENT_FILE_TO_ROLE")))
print("has_role_local_agent_file=" + str(hasattr(pr, "ROLE_LOCAL_AGENT_FILE")))
PYEOF
)"
  assert_contains "AGENT_FILE_TO_ROLE対応表は存在しない" "$result" "has_agent_file_to_role=False"
  assert_contains "ROLE_LOCAL_AGENT_FILE対応表は存在しない" "$result" "has_role_local_agent_file=False"
}

echo "=== 60. V1-b直接検証: role_definition_exists('vault-scribe', 'subagent', agents_dir)が対応表を介さずagents_dir配下を職種名そのままで引いて実在有無を正しく判定する（'scribe'という旧職種名では定義ファイルが無いと判定される＝職種名＝ファイル名の不変条件の直接確認） ==="
{
  result="$(PYTHONPATH="$REPO_ROOT/team/executor" python3 - "$AGENTS_DIR" <<'PYEOF'
import sys
import profile_resolve as pr

agents_dir = sys.argv[1]
print("vault_scribe=" + str(pr.role_definition_exists("vault-scribe", "subagent", agents_dir)))
print("scribe=" + str(pr.role_definition_exists("scribe", "subagent", agents_dir)))
PYEOF
)"
  assert_contains "'vault-scribe'はagents_dir配下にvault-scribe.mdがあるためTrue" "$result" "vault_scribe=True"
  assert_contains "旧職種名'scribe'はscribe.mdが無いためFalse（対応表による救済はしない）" "$result" "scribe=False"
}

# ============================================================================
# 61番以降: 3モード体制（3モード体制-設計-2026-09-06.md／同要件-2026-09-05.md）
# の team_mode スロット・開幕1行・改名対応のユニット・結合テスト。
# ============================================================================

echo "=== 61. FX-P1〜P3: resolver単体・team_modeがsolo/lean/fullのときTEAM_MODE:がそれぞれ1つだけ現れexit0（AC-1①） ==="
{
  for v in solo lean full; do
    FXP="$(mktemp -d)/fxp-$v.md"
    make_v2_profile "$FXP" \
      "role.leader: configured model=t-opus-high"
    sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=$v/" "$FXP"
    # ⚠️ `out="$(cmd)" || true`は`||`の右辺が常に成功するため直後の`$?`は
    # 常に0になり、resolve_v2自身の終了コードを検証できない（Codex一次
    # レビュー指摘・MAJOR対応）。if/elseで実際の終了コードを取る。
    if out="$(resolve_v2 "$FXP")"; then rc=0; else rc=$?; fi
    assert_contains "FX-P$([ "$v" = solo ] && echo 1 || { [ "$v" = lean ] && echo 2 || echo 3; }): TEAM_MODE:${v}が現れる" "$out" "TEAM_MODE:${v}"
    assert_eq "FX-P(${v}): exit0（AC-1①）" "0" "$rc"
    head_ok=0
    case "$out" in OK*) head_ok=1 ;; esac
    assert_eq "FX-P(${v}): 先頭フィールドはOK" "1" "$head_ok"
    # TEAM_MODE:はちょうど1回だけ現れる（重複が無いこと）。
    count="$(printf '%s' "$out" | grep -o 'TEAM_MODE:' | wc -l | tr -d ' ')"
    assert_eq "FX-P(${v}): TEAM_MODE:はちょうど1回だけ現れる" "1" "$count"
  done
}

echo "=== 62. FX-P4〜P5: resolver単体・team_modeがunknown/unavailableならTEAM_MODE:unknown・exit0（AC-2） ==="
{
  FXP4="$(mktemp -d)/fxp4.md"
  make_v2_profile "$FXP4" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unknown/" "$FXP4"
  if out="$(resolve_v2 "$FXP4")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P4(team_mode:unknown): TEAM_MODE:unknownが出る" "$out" "TEAM_MODE:unknown"
  assert_eq "FX-P4: exit0（AC-2）" "0" "$rc"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-P4: 先頭フィールドはOK" "1" "$head_ok"

  FXP5="$(mktemp -d)/fxp5.md"
  make_v2_profile "$FXP5" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unavailable/" "$FXP5"
  if out="$(resolve_v2 "$FXP5")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P5(team_mode:unavailable): TEAM_MODE:unknownが出る" "$out" "TEAM_MODE:unknown"
  assert_eq "FX-P5: exit0（AC-2）" "0" "$rc"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-P5: 先頭フィールドはOK" "1" "$head_ok"
}

echo "=== 63. FX-P6〜P7: resolver単体・team_modeの値形式違反はMINIMAL・exit1・TEAM_MODE:が出ない（AC-3） ==="
{
  FXP6="$(mktemp -d)/fxp6.md"
  make_v2_profile "$FXP6" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=solo,lean/" "$FXP6"
  if out="$(resolve_v2 "$FXP6")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P6(カンマ列挙): MINIMALになる" "$out" "MINIMAL"
  assert_eq "FX-P6: exit1（AC-3）" "1" "$rc"
  assert_not_contains "FX-P6: TEAM_MODE:は出ない" "$out" "TEAM_MODE:"

  FXP7="$(mktemp -d)/fxp7.md"
  make_v2_profile "$FXP7" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=quick/" "$FXP7"
  if out="$(resolve_v2 "$FXP7")"; then rc=0; else rc=$?; fi
  assert_contains "FX-P7(未知の語): MINIMALになる" "$out" "MINIMAL"
  assert_eq "FX-P7: exit1（AC-3）" "1" "$rc"
  assert_not_contains "FX-P7: TEAM_MODE:は出ない" "$out" "TEAM_MODE:"
}

echo "=== 64. known-keysがSCHEMA_VERSION:7・FIXED:にteam_mode/machine_roleを含み廃止5キーを含まない・要素数は5（配役表-能力軸整理-設計-2026-09-07.md §3・代替配役の層と禁止モデル列挙の層の撤去-設計-2026-09-16.mdでschema 6→7。要件AC-1・AC-2の基本口Kの実測はtest-core-docs-placeholder-schema.shが担う） ==="
{
  kk="$(python3 "$PROFILE_LIB" known-keys)"
  assert_contains "known-keys: SCHEMA_VERSION:7" "$kk" "SCHEMA_VERSION:7"
  fixed_line="$(printf '%s' "$kk" | grep '^FIXED:')"
  assert_contains "known-keys: FIXED:にteam_modeを含む" "$fixed_line" "team_mode"
  assert_contains "known-keys: FIXED:にmachine_roleを含む" "$fixed_line" "machine_role"
  # ⚠️ 廃止済み能力軸キー名をソースへ直接書かない（AC-5の0件検査に自分自身が
  # 引っかかるため）。実行時に文字列を組み立てる。
  _underscore='_'
  _retired_key="git${_underscore}role"
  assert_not_contains "known-keys: FIXED:に廃止済み能力軸キーを含まない（本人決定Decisions/2026-09-07-profile-axes-consolidation対象の1つ）" "$fixed_line" "$_retired_key"
  n="$(printf '%s' "${fixed_line#FIXED:}" | tr ',' '\n' | grep -c .)"
  assert_eq "known-keys: FIXED:の要素数は5（メタ2＋能力軸3）" "5" "$n"

  # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 上のcontains/件数
  # チェックだけでは、誤った5キーへ全体が同時に変わっても通ってしまう
  # （例: team_mode/machine_roleが偶然両方含まれる別の5キー集合）。
  # 要件AC-1が定めるリテラル5キー集合と、ソート済み文字列として直接比較する。
  actual_sorted="$(printf '%s' "${fixed_line#FIXED:}" | tr ',' '\n' | sort | tr '\n' ',')"
  expected_sorted="$(printf 'schema_version\nprofile_slug\nteam_mode\nno_read_paths\nmachine_role\n' | sort | tr '\n' ',')"
  assert_eq "AC-1: known-keysのFIXED集合が期待5キー(リテラル集合)と完全一致する" "$expected_sorted" "$actual_sorted"
}

# FR-11・FR-12（要件v1.2.1・タスク2）: 🧭モード行の末尾セグメント（bootstrap-
# vault.sh側の実装と同じ固定書式）を組み立てるヘルパー。BOOTSTRAP_ENABLE_
# LOCAL_PROFILE=1で実体プロファイルを解決したとき、4本の固定文面（solo/
# lean/full/未確定）の末尾にこの1セグメントが付く（行数は増やさない＝
# ちょうど1行のまま）。
mode_success_segment() {  # $1=schema_version $2=machine_role
  printf '｜配役表＝OK schema_version=%s machine_role=%s 照会＝python3 ~/work/takumi009-ai-env/team/connect/claude-code/role_candidates.py [--role <職種>]' "$1" "$2"
}
mode_failure_segment() {  # $1=区分コード（T1/SYMLINK/T5/T4-LEGACY/UNKNOWN_EXTRA等）
  printf '｜配役表＝利用不可（%s）＝最小能力として振る舞う・ワーカー起動は本人確認へ倒す' "$1"
}

echo "=== 65. FX-I1〜I3: bootstrap結合・3モードの開幕1行がそれぞれちょうど1行現れ、他2モードは0行（AC-6①）。2026-09-17 FR-11対応でモード行末尾に配役表セグメントが付く形へexpect=を更新 ==="
{
  # ⚠️ 「ちょうど1行」の計数は`grep -Fx -c`で行全体の完全一致を見る。
  # `-F`のみ（部分一致）だと、開幕行の末尾に余計な文言が付いても
  # 「含む」判定で1件とカウントしてしまい、末尾改変を見逃す偽陽性経路になる
  # （検証職・第3巡MAJOR指摘4の反映。本セクション以降の全`$UNCONFIRMED`
  # 計数も同様に`-Fx`へ揃える）。
  for v in solo lean full; do
    VD="$(mktemp -d)"; make_full_vault "$VD"
    FXI="$(mktemp -d)/fxi-$v.md"
    make_v2_profile "$FXI" \
      "role.leader: configured model=t-opus-high"
    sed -i '' "s/team_mode:        configured value=full/team_mode:        configured value=$v/" "$FXI"
    ctx="$(run_status_with_profile "$FXI")"

    case "$v" in
      solo) expect='🧭 現在＝単独モード（リーダーが全工程を自分で行います。第三者検証はありません）。他のモード＝軽量／フル。切り替えたいときは言ってください' ;;
      lean) expect='🧭 現在＝軽量モード（実装者と検証職を置き、適用工程ごとに1巡で回します）。他のモード＝単独／フル。切り替えたいときは言ってください' ;;
      full) expect='🧭 現在＝フルモード（職種ごとに担当を立て、指摘が収まるまで検証を回します）。他のモード＝単独／軽量。切り替えたいときは言ってください' ;;
    esac
    # FX-Iのfixture（V2_BASE）はschema_version=7・machine_role=mainで解決OK。
    expect="${expect}$(mode_success_segment 7 main)"
    assert_contains "FX-I(${v}): 期待文字列と完全一致する行が含まれる" "$ctx" "$expect"
    n="$(printf '%s' "$ctx" | grep -Fx -c "$expect" || true)"
    assert_eq "FX-I(${v}): 期待文字列の行がちょうど1行" "1" "$n"
    total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
    assert_eq "FX-I(${v}): 🧭で始まる行が合計ちょうど1行（他モードは0行）" "1" "$total_mode_lines"
    rm -rf "$VD"
  done
}

echo "=== 66. FX-I4・FX-I6: bootstrap結合・team_modeがunknown、またはresolveがMINIMALのときは未確定行がちょうど1行（AC-7）。2026-09-17 FR-11/FR-12対応でセグメント込みのexpect=へ更新 ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'

  VD="$(mktemp -d)"; make_full_vault "$VD"
  FXI4="$(mktemp -d)/fxi4.md"
  make_v2_profile "$FXI4" \
    "role.leader: configured model=t-opus-high"
  sed -i '' "s/team_mode:        configured value=full/team_mode:        unknown/" "$FXI4"
  ctx="$(run_status_with_profile "$FXI4")"
  # ⚠️ FX-I4はteam_mode自体が"unknown"状態なだけで、配役表全体の解決
  # （schema_version/machine_role）は成功する（FXI4はrole.leader・
  # machine_role等は正常なまま）＝モード行は「未確定」固定文面＋成功セグメント。
  fxi4_expect="${UNCONFIRMED}$(mode_success_segment 7 main)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$fxi4_expect" || true)"
  assert_eq "FX-I4(team_mode:unknown): 未確定行(成功セグメント込み)がちょうど1行" "1" "$n"
  total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "FX-I4: 🧭行の合計もちょうど1行（3モードの行は0行）" "1" "$total_mode_lines"
  rm -rf "$VD"

  # FX-I6: resolveがMINIMALを返す実体（既存のT5＝既知キー欠落を流用する）。
  VD2="$(mktemp -d)"; make_full_vault "$VD2"
  FXI6="$(mktemp -d)/fxi6.md"
  make_v2_profile "$FXI6" \
    "role.leader: configured model=t-opus-high"
  python3 - "$FXI6" <<'PYEOF'
import sys
path = sys.argv[1]
lines = [l for l in open(path).read().splitlines() if not l.startswith("machine_role:")]
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  # FX-I6は解決そのものが失敗する（T5＝既知キーmachine_role欠落）ので
  # モード行は「未確定」固定文面＋失敗セグメント（区分=T5）になる。
  UNCONFIRMED="${UNCONFIRMED}$(mode_failure_segment T5)"
  ctx="$(run_status_with_profile "$FXI6")"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED" || true)"
  assert_eq "FX-I6(MINIMAL/T5): 未確定行(失敗セグメント込み)がちょうど1行" "1" "$n"
  total_mode_lines="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "FX-I6: 🧭行の合計もちょうど1行（3モードの行は0行）" "1" "$total_mode_lines"
  rm -rf "$VD2"
}

echo "=== 67. FX-R1・FX-R2（AC-10）: 退役キー'primary-reviewer'はV1-bで空席、改名後'verifier'はagents/verifier.mdが実在するので同じ行の2件目の候補が採用される ==="
{
  FXR1="$(mktemp -d)/fxr1.md"
  make_v2_profile "$FXR1" \
    "role.leader: configured model=t-opus-high" \
    "role.primary-reviewer: configured model=t-opus-high"
  out="$(resolve_v2 "$FXR1")"  || true
  assert_contains "FX-R1(陰性): VACANT:にprimary-reviewerが出る" "$out" "VACANT:primary-reviewer"
  assert_contains "FX-R1: VACANT_REASONがprimary-reviewer=V1-b" "$out" "VACANT_REASON:primary-reviewer=V1-b"

  FXR2="$(mktemp -d)/fxr2.md"
  make_v2_profile "$FXR2" \
    "role.leader: configured model=t-opus-high" \
    "role.verifier: configured model=bedrock-opus,t-opus-high"
  # bedrock.envを与えない(ABSENT=disabled)ので1件目(bedrock-opus)はV9-dで
  # 使用不可・2件目(t-opus-high)はagents/verifier.mdが実在するので使用可。
  out="$(resolve_v2 "$FXR2")"  || true
  assert_not_contains "FX-R2(陽性): 1件目が使用不可でも2件目で採用されVACANT:に現れない" "$out" "VACANT:verifier"
  head_ok=0; case "$out" in OK*) head_ok=1 ;; esac
  assert_eq "FX-R2: 先頭フィールドはOK（exit0）" "1" "$head_ok"
}

echo "=== 68. §6.3縮退経路の回帰(ID無し・要件のfixture表とは別枠): BOOTSTRAP_ENABLE_LOCAL_PROFILE=0／LEGACY_V1(v1実体)／UNKNOWN_EXTRAを伴うOK行のいずれも、未確定行がちょうど1行・3モードの行は0行。2026-09-17 FR-11/FR-12対応で②③はセグメント込みのexpect=へ更新（①はBOOTSTRAP_ENABLE_LOCAL_PROFILE=0で解決自体を行わないためセグメント無しのまま） ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'

  # ①BOOTSTRAP_ENABLE_LOCAL_PROFILE=0（解決そのものを行わない）。
  VD="$(mktemp -d)"; make_full_vault "$VD"
  ctx="$(run_status)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$UNCONFIRMED" || true)"
  assert_eq "①ゲート無効: 未確定行(セグメント無し。解決自体を行わないため)がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "①ゲート無効: 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD"

  # ②旧版（T4-LEGACY。schema_versionの行が無い実体＝team_modeという概念自体
  # を機械が読めない）。
  VD2="$(mktemp -d)"; make_full_vault "$VD2"
  V1P="$(mktemp -d)/v1legacy.md"
  cat > "$V1P" <<'EOF'
---
team_mode: 本人
no_read_paths: ~/work/old
machine_role: 本人
---
EOF
  ctx="$(run_status_with_profile "$V1P")"
  unconfirmed_t4legacy="${UNCONFIRMED}$(mode_failure_segment T4-LEGACY)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$unconfirmed_t4legacy" || true)"
  assert_eq "②旧版(T4-LEGACY): 未確定行(失敗セグメント込み)がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "②旧版(T4-LEGACY): 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD2"

  # ③UNKNOWN_EXTRAを伴うOK行（team_mode自体は正しく読めていても、未知キーが
  # あれば必読除外・最小能力へ倒すので未確定行になる）。
  VD3="$(mktemp -d)"; make_full_vault "$VD3"
  FXUE="$(mktemp -d)/fxue.md"
  make_v2_profile "$FXUE" \
    "role.leader: configured model=t-opus-high"
  python3 - "$FXUE" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "future_key_v5: configured value=something")
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  ctx="$(run_status_with_profile "$FXUE")"
  unconfirmed_unknown_extra="${UNCONFIRMED}$(mode_failure_segment UNKNOWN_EXTRA)"
  n="$(printf '%s' "$ctx" | grep -Fx -c "$unconfirmed_unknown_extra" || true)"
  assert_eq "③UNKNOWN_EXTRA: 未確定行(失敗セグメント込み)がちょうど1行" "1" "$n"
  total="$(printf '%s' "$ctx" | grep -c '^🧭 現在＝')"
  assert_eq "③UNKNOWN_EXTRA: 🧭行の合計もちょうど1行" "1" "$total"
  rm -rf "$VD3"
}

# ⚠️ §10.3-10（開幕1行の文面がcore-conduct.mdと一致する）は
# tests/test-agent-definitions.sh 側の検査項目として実装した（設計§10.3の
# 収容先指定どおり）。本ファイルからは重複させない。

echo "=== 70. §10.5: builtinだけで書けている（BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLYは外部プロセスを1つも起こさない） ==="
{
  SPY0="$(mktemp -d)"
  for cmd in python3 jq wc grep sed awk tail cat tr date sort basename dirname readlink diff; do
    real="$(resolve_real_cmd_for_spy "$cmd")"
    [ -z "$real" ] && continue
    cat > "$SPY0/$cmd" <<EOF
#!/bin/bash
printf '%s\n' "$cmd" >> "$SPY0/calls.log"
exec "$real" "\$@"
EOF
    chmod +x "$SPY0/$cmd"
  done
  : > "$SPY0/calls.log"
  PATH="$SPY0" BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1 "$REAL_BASH" "$SCRIPT" </dev/null >/dev/null
  # ⚠️ resolve_bootstrap_self_dir()（symlink解決・全エントリポイント共通の
  # 既存処理）が1回だけ外部の`dirname`を呼ぶため、これは新設部分より前の
  # 前提処理として許容する（BOOTSTRAP_PRINT_KNOWN_KEYS_ONLYと共有する既存の
  # オーバーヘッドであって、team_mode機能が新たに増やした外部プロセスではない）。
  # ⚠️ ここで見るのは「dirname以外が1つも呼ばれていないこと」＝
  # compose_team_mode_line()（4パターンの文面組み立て）だけがbuiltinだけで
  # 書けている証明（Codex一次レビュー指摘・MAJOR対応で訂正: 本フックは
  # 値の取り出し=OK行からのTEAM_MODE:抽出ロジックには到達しない——その
  # コードはこの早期exitより後段のDIRECTIVE組み立て内にあるため）。値の
  # 取り出し自体がbuiltinだけであることは、後段のテスト71（AC-1②・実際の
  # SessionStart全体を走らせて外部プロセス総数が変更前から増加しないことを
  # 見る。実測は29→28＝設計v1.5反映済み）が間接的に証明する。
  calls="$(cat "$SPY0/calls.log")"
  assert_eq "BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1: dirname以外の外部プロセスは0件" "" "$(printf '%s\n' "$calls" | grep -v '^dirname$' | grep -v '^$' || true)"
  rm -rf "$SPY0"
}

# ============================================================================
# 72番以降: 配役表-能力軸整理-要件-2026-09-07.md §7の受入条件のうち、本ファイル
# 担当分（AC-3・AC-4・AC-8・AC-9・AC-11）をfixture単位で直接検証する。
# fixture定義・期待値は同要件書§6.2の表のとおり（FX-P1が共通ベース）。
# ============================================================================

echo "=== 72. AC-3(FR-1): machine_roleの状態enumの陽性2件(FX-P1・FX-P2)・陰性2件(FX-P3・FX-P4) ==="
{
  # ⚠️ Codex一次レビュー指摘（MAJOR-5・2026-09-07）対応: 先頭文字列とexit
  # codeだけでは、fixture表（要件§6.2）が定めるTEAM_MODE:full・UNKNOWN_EXTRA:
  # 不在という残りの期待を固定していなかった。両方を明示的に検査する。
  FXP1_72="$(mktemp -d)/fxp1.md"
  make_v2_profile "$FXP1_72" "role.leader: configured model=t-opus-high"
  rc=0; out="$(resolve_v2 "$FXP1_72")" || rc=$?
  assert_eq "FX-P1: OK<TAB>schema_version=7で始まる" "1" \
    "$([[ "$out" == $'OK\tschema_version=7'* ]] && echo 1 || echo 0)"
  assert_eq "FX-P1: exit 0" "0" "$rc"
  assert_contains "FX-P1: TEAM_MODE:fullを含む" "$out" "TEAM_MODE:full"
  assert_not_contains "FX-P1: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"

  FXP2_72="$(mktemp -d)/fxp2.md"
  make_v2_profile "$FXP2_72" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     configured value=sub/" "$FXP2_72"
  rc=0; out="$(resolve_v2 "$FXP2_72")" || rc=$?
  assert_eq "FX-P2: OK<TAB>schema_version=7で始まる" "1" \
    "$([[ "$out" == $'OK\tschema_version=7'* ]] && echo 1 || echo 0)"
  assert_eq "FX-P2: exit 0" "0" "$rc"
  assert_contains "FX-P2: TEAM_MODE:fullを含む" "$out" "TEAM_MODE:full"
  assert_not_contains "FX-P2: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"

  FXP3_72="$(mktemp -d)/fxp3.md"
  make_v2_profile "$FXP3_72" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     not_adopted/" "$FXP3_72"
  rc=0; out="$(resolve_v2 "$FXP3_72")" || rc=$?
  assert_contains "FX-P3: V7(machine_roleの状態が不正)を含む" "$out" "V7: machine_roleの状態が不正です"
  assert_eq "FX-P3: exit 1" "1" "$rc"

  FXP4_72="$(mktemp -d)/fxp4.md"
  make_v2_profile "$FXP4_72" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     configured value=primary/" "$FXP4_72"
  rc=0; out="$(resolve_v2 "$FXP4_72")" || rc=$?
  assert_contains "FX-P4: V8-b(machine_roleのvalue形式が不正)を含む" "$out" "V8-b: machine_roleのvalue形式が不正です"
  assert_eq "FX-P4: exit 1" "1" "$rc"
}

echo "=== 73. AC-4(FR-5): no_read_pathsの実パス書式の陽性1件(FX-P9)・陰性2件(FX-P10・FX-P11) ==="
{
  FXP9_73="$(mktemp -d)/fxp9.md"
  make_v2_profile "$FXP9_73" "role.leader: configured model=t-opus-high"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=~/work/old,~/Data/private#" "$FXP9_73"
  rc=0; out="$(resolve_v2 "$FXP9_73")" || rc=$?
  assert_eq "FX-P9: OKで始まる（大文字を含む実パスも受理）" "1" \
    "$([[ "$out" == OK* ]] && echo 1 || echo 0)"
  assert_eq "FX-P9: exit 0" "0" "$rc"

  FXP10_73="$(mktemp -d)/fxp10.md"
  make_v2_profile "$FXP10_73" "role.leader: configured model=t-opus-high"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=~/work/old, ~/tmp/x#" "$FXP10_73"
  rc=0; out="$(resolve_v2 "$FXP10_73")" || rc=$?
  assert_contains "FX-P10: T6を含む" "$out" "T6"
  assert_contains "FX-P10: 属性の形式が不正ですを含む" "$out" "属性の形式が不正です"
  assert_eq "FX-P10: exit 1" "1" "$rc"

  FXP11_73="$(mktemp -d)/fxp11.md"
  make_v2_profile "$FXP11_73" "role.leader: configured model=t-opus-high"
  sed -i '' "s#no_read_paths:    unavailable#no_read_paths:    configured value=/work/old#" "$FXP11_73"
  rc=0; out="$(resolve_v2 "$FXP11_73")" || rc=$?
  assert_contains "FX-P11: V8-b(no_read_pathsのvalue形式が不正)を含む" "$out" "V8-b: no_read_pathsのvalue形式が不正です"
  assert_eq "FX-P11: exit 1" "1" "$rc"
}

echo "=== 75. AC-9(FR-13): 廃止キー残存時のUNKNOWN_EXTRA契約の陽性1件(FX-P7)・陰性1件(FX-P1) ==="
{
  FXP7_75="$(mktemp -d)/fxp7-ac9.md"
  make_v2_profile "$FXP7_75" "role.leader: configured model=t-opus-high"
  # frontmatter終端(---)の直前に挿入する（末尾に追記すると frontmatter の
  # 外側になってしまうため）。AC5-ALLOW:FX-P7
  python3 - "$FXP7_75" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
idx = len(lines) - 1  # 末尾の "---"
lines.insert(idx, "git_role: unavailable")  # AC5-ALLOW:FX-P7
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  rc=0; out="$(resolve_v2 "$FXP7_75")" || rc=$?
  assert_contains "FX-P7: R=UNKNOWN_EXTRA:git_roleを含む（機械側は既知キーで解決）" "$out" "UNKNOWN_EXTRA:git_role"  # AC5-ALLOW:FX-P7
  assert_eq "FX-P7: R=exit 0" "0" "$rc"
  ctx="$(run_status_with_profile "$FXP7_75")"
  assert_contains "FX-P7: I=プロファイル利用不可の文言を含む（AI側は降格）" "$ctx" "プロファイル利用不可"
  assert_contains "FX-P7: I=最小能力の文言を含む" "$ctx" "最小能力"

  FXP1_75="$(mktemp -d)/fxp1-ac9.md"
  make_v2_profile "$FXP1_75" "role.leader: configured model=t-opus-high"
  out="$(resolve_v2 "$FXP1_75")"
  assert_not_contains "FX-P1: R=UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"
  ctx="$(run_status_with_profile "$FXP1_75")"
  # FR-10で全文Read指示自体を撤去した。解決成功はFR-11のモード行セグメント
  # （schema_version=・machine_role=・role_candidates.py）で示す。
  assert_not_contains "FX-P1: I=もう全文Readは指示しない（FR-10）" "$ctx" "Readで全文を読むこと"
  assert_contains "FX-P1: I=モード行セグメントにschema_version=が含まれる" "$ctx" "schema_version=7"
  assert_contains "FX-P1: I=モード行セグメントにmachine_role=が含まれる" "$ctx" "machine_role=main"
  assert_contains "FX-P1: I=モード行セグメントに照会コマンド(role_candidates.py)が含まれる" "$ctx" "role_candidates.py"
}
echo "=== 76. AC-11(FR-9): machine_roleがunknownのときだけ保留の1行が増える（FX-P8陽性・FX-P1陰性・同一HOME・同一パスでmachine_roleの値だけを変える） ==="
{
  # 旧 76 は本文全体を diff して「追加 1 行だけ」を見ていた。寄与へ移した後は枠ごとに比べる＝
  # 保留の枠だけが "" → 1 行になり、他の枠は MACHINE_ROLE:<値>・machine_role=<値> を正規化すれば一致する。
  FXP_76="$(mktemp -d)/fxp-ac11.md"
  make_v2_profile "$FXP_76" "role.leader: configured model=t-opus-high"
  slots_p1="$(slots_with_profile "$FXP_76" 2>/dev/null || true)"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     unknown/" "$FXP_76"
  slots_p8="$(slots_with_profile "$FXP_76" 2>/dev/null || true)"

  norm() { printf '%s' "$1" | jq -S 'del(.slots["machine-role-hold"])' 2>/dev/null \
    | sed -E 's/MACHINE_ROLE:[a-z]+/MACHINE_ROLE:X/g; s/machine_role=[a-z]+/machine_role=X/g'; }
  assert_true "保留の枠以外は正規化すると一致（前提: 枠が取れている）" \
    "$([ -n "$(norm "$slots_p1")" ] && [ "$(norm "$slots_p1")" = "$(norm "$slots_p8")" ] && echo 1 || echo 0)"
  hold_p1="$(printf '%s' "$slots_p1" | jq -r '.slots["machine-role-hold"]' 2>/dev/null)"
  hold_p8="$(printf '%s' "$slots_p8" | jq -r '.slots["machine-role-hold"]' 2>/dev/null)"
  assert_eq "FX-P1(main): 保留の枠は空" "" "$hold_p1"
  assert_eq "FX-P8(unknown): 保留の枠はちょうど1行" "1" "$(printf '%s\n' "$hold_p8" | grep -c . || true)"
  assert_eq "FX-P8(unknown): その1行が保留の文" "1" "$(printf '%s\n' "$hold_p8" | grep -c '配役表の machine_role が未確定です' || true)"
}
echo "=== 76b. AC-11(FR-9)陰性・MAJOR-1対応: machine_roleがunavailableのときは保留行を出さない（unknownとは区別する） ==="
{
  VD_76B="$(mktemp -d)"; make_full_vault "$VD_76B"

  FXP_76B="$(mktemp -d)/fxp-ac11-unavailable.md"
  make_v2_profile "$FXP_76B" "role.leader: configured model=t-opus-high"
  sed -i '' "s/machine_role:     configured value=main/machine_role:     unavailable/" "$FXP_76B"
  ctx_unavail="$(run_status_with_profile "$FXP_76B")"

  hold_count_unavail="$(printf '%s\n' "$ctx_unavail" | grep -c '配役表の machine_role が未確定です' || true)"
  assert_eq "machine_role=unavailable: 保留の行は0回（unknownと違い明示的な申告のため）" "0" "$hold_count_unavail"
  assert_contains "machine_role=unavailable: 診断行にはMACHINE_ROLE:unavailableがそのまま出る" "$ctx_unavail" "MACHINE_ROLE:unavailable"

  rm -rf "$VD_76B"
}

echo "=== 77. 設計§11.3新設2件の①: AIENV_MODEL_DEFS_FILEが相対パスならR・L・LD・Cに加えI（bootstrap-vault.sh経由）もT13相当でloudに落ちる（Codexレビュー指摘・MAJOR-3対応・1巡目。R/L/LD/Cの4口はtest-model-definitions.shで既に検証済み） ==="
{
  UNCONFIRMED='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。'
  VD77="$(mktemp -d)"; make_full_vault "$VD77"
  FXP77="$(mktemp -d)/fxp77.md"
  make_v2_profile "$FXP77" "role.leader: configured model=t-opus-high"
  ctx77="$(run_status_with_profile "$FXP77" "relative/models.conf")"
  unconfirmed_t13="${UNCONFIRMED}$(mode_failure_segment T13)"
  n77="$(printf '%s' "$ctx77" | grep -Fx -c "$unconfirmed_t13" || true)"
  assert_eq "I(T13): AIENV_MODEL_DEFS_FILEが相対パスだと未確定行(失敗セグメント込み)がちょうど1行（resolve自体がT13でloud失敗する）" "1" "$n77"
  total77="$(printf '%s' "$ctx77" | grep -c '^🧭 現在＝')"
  assert_eq "I(T13): 🧭行の合計もちょうど1行" "1" "$total77"
  rm -rf "$VD77"
}

echo "=== 78. 設計§11.3新設2件の②: 同じ絶対パスのAIENV_MODEL_DEFS_FILEなら、Iを呼び出すcwdを変えても同じ結果になる（Codexレビュー指摘・MAJOR-3対応・1巡目。R/L/LD/Cの4口はtest-model-definitions.shで既に検証済み） ==="
{
  VD78="$(mktemp -d)"; make_full_vault "$VD78"
  FXP78="$(mktemp -d)/fxp78.md"
  make_v2_profile "$FXP78" "role.leader: configured model=t-opus-high"
  ctx78_tmp="$(cd /tmp && run_status_with_profile "$FXP78" "$SHARED_MODELS_CONF")"
  ctx78_repo="$(cd "$REPO_ROOT" && run_status_with_profile "$FXP78" "$SHARED_MODELS_CONF")"
  ctx78_vd="$(cd "$VD78" && run_status_with_profile "$FXP78" "$SHARED_MODELS_CONF")"
  assert_eq "I(cwd不変性): /tmp とREPO_ROOTで同じ結果" "$ctx78_tmp" "$ctx78_repo"
  assert_eq "I(cwd不変性): /tmp とVault作業ディレクトリで同じ結果" "$ctx78_tmp" "$ctx78_vd"
  rm -rf "$VD78"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
