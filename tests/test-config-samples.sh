#!/usr/bin/env bash
# tests/test-config-samples.sh — 設定ファイルsample配布-実装-2026-09-08.md
# の受入条件 AC-1〜AC-4（config/*.sample 3本が resolver・installer を
# 実際に通ること）を検証する。
#
# 正本: ~/work/takumi009-ai-env-private/docs/core-split/
#   設定ファイルsample配布-実装-2026-09-08.md
#
# 実行方法: bash tests/test-config-samples.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
INSTALL_MAIN="$REPO_ROOT/scripts/install-main.sh"
CONFIG_DIR="$REPO_ROOT/config"
PROFILE_SAMPLE="$CONFIG_DIR/profile.md.sample"
MODELS_SAMPLE="$CONFIG_DIR/models.conf.sample"
BEDROCK_SAMPLE="$CONFIG_DIR/bedrock.env.sample"
AGENTS_DIR="$REPO_ROOT/claude/agents"
NGWORDS_FILE="${NGWORDS_FILE:-$HOME/work/takumi009-ai-env-private/ngwords.txt}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\" / 実際: $haystack)"
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}
assert_starts_with() {
  local desc="$1" haystack="$2" prefix="$3"
  case "$haystack" in
    "$prefix"*) pass "$desc" ;;
    *) fail_case "$desc ($prefix で始まらない / 実際: $haystack)" ;;
  esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in "$PROFILE_SAMPLE" "$MODELS_SAMPLE" "$BEDROCK_SAMPLE"; do
  [ -f "$f" ] || { fail_case "前提: $f が存在する"; }
done

echo "=== AC-1: resolve が OK・TEAM_MODE:full・MACHINE_ROLE:main を含み MODEL_MISMATCH を含まない ==="
{
  out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$PROFILE_SAMPLE" --agents-dir "$AGENTS_DIR")"; rc=$?
  assert_eq "AC-1: exit0" "0" "$rc"
  assert_starts_with "AC-1: OKで始まる" "$out" "OK"
  assert_contains "AC-1: TEAM_MODE:full" "$out" "TEAM_MODE:full"
  assert_contains "AC-1: MACHINE_ROLE:main" "$out" "MACHINE_ROLE:main"
  assert_not_contains "AC-1: MODEL_MISMATCHを含まない" "$out" "MODEL_MISMATCH"
}

echo "=== AC-1b: --bedrock-env を渡しても壊れない ==="
{
  out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$PROFILE_SAMPLE" --agents-dir "$AGENTS_DIR" --bedrock-env "$BEDROCK_SAMPLE")"; rc=$?
  assert_eq "AC-1b: exit0" "0" "$rc"
  assert_starts_with "AC-1b: OKで始まる" "$out" "OK"
}

echo "=== AC-2: resolve-candidate が各職種の候補で exit0（configured な role.* 全9行＋4定義） ==="
{
  check_candidate() {
    local role="$1" def="$2"
    local out rc=0
    out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve-candidate "$PROFILE_SAMPLE" --role "$role" --model-def "$def" --agents-dir "$AGENTS_DIR" 2>&1)" || rc=$?
    assert_eq "AC-2: role=$role def=$def exit0" "0" "$rc"
    assert_starts_with "AC-2: role=$role def=$def OKで始まる" "$out" "OK"
    assert_contains "AC-2: role=$role def=$def 定義名が現れる" "$out" "$def"
  }
  # profile.md.sampleのconfigured role行は9件（leader/requirements-analyst/
  # system-designer/adoption-critic/implementer/researcher/operator/
  # vault-scribe/verifier）。navi・ja-docはunknownなので対象外。全9件を通す
  # （2026-09-08 Codexレビュー指摘・MAJOR対応・1巡目: 代表5件だけでは
  # 職種ごとの候補所属判定を固定できない）。
  check_candidate leader fable-main
  check_candidate requirements-analyst opus-main
  check_candidate system-designer opus-main
  check_candidate adoption-critic opus-main
  check_candidate implementer sonnet-main
  check_candidate researcher sonnet-main
  check_candidate operator sonnet-main
  check_candidate vault-scribe sonnet-main
  check_candidate verifier codex-review-default

  # fallback.verifier（opus-main・候補ちょうど1件）は--model-defで直接指定
  # できない（D-5＝fallbackの定義名を直接指定させない）ので、role.verifierの
  # 候補を一時的にunavailableにした変異コピーでfallback発火を実際に通す
  # （2026-09-08 Codexレビュー指摘・MAJOR対応・1巡目）。
  mutant_fb="$WORK/profile-fallback-check.md.sample"
  sed 's/^role.verifier:             configured model=codex-review-default$/role.verifier:             unavailable model=codex-review-default/' \
    "$PROFILE_SAMPLE" > "$mutant_fb"
  grep -q '^role.verifier:             unavailable model=codex-review-default$' "$mutant_fb" \
    || fail_case "AC-2: 前提（role.verifierをunavailableへ書き換え済み）"
  fb_out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve-candidate "$mutant_fb" --role verifier --model-def codex-review-default --agents-dir "$AGENTS_DIR" 2>&1)"; fb_rc=$?
  assert_eq "AC-2: fallback.verifier発火時にexit0" "0" "$fb_rc"
  fb_def="$(printf '%s' "$fb_out" | sed -n '1p' | awk -F'\t' '{print $2}')"
  assert_eq "AC-2: fallback.verifierの定義名がopus-main" "opus-main" "$fb_def"
}

echo "=== AC-3: --print-bedrock-env-json が認証情報キーを1つも出さず正常終了 ==="
{
  # 2026-09-08 検証職(Codex)1巡目指摘・リーダー裁定でAC-3の定義を確定:
  # --print-bedrock-env-jsonは動的Bedrock許可キーの算出のためAIENV_LOCAL_
  # PROFILE_PATH（compute_allowed_bedrock_env_keys()がrole.*/fallback.*の
  # 候補を読む）・AIENV_MODEL_DEFS_FILE（同候補の解決に使う）も読む
  # （scripts/install-main.sh の compute_allowed_bedrock_env_keys()参照）。
  # AC-3は「AIENV_BEDROCK_ENV_FILE単体」ではなく「AIENV_BEDROCK_ENV_FILE＋
  # AIENV_LOCAL_PROFILE_PATH=config/profile.md.sample＋AIENV_MODEL_DEFS_
  # FILE=config/models.conf.sampleの3変数を与えてexit 0・認証情報キー
  # なし」と定義する（本人のローカル実体・schema 4のままだと動的キー算出が
  # そちらを読みに行きT4-LEGACYでexit 1になる＝サンプルbedrock.envをサンプル
  # profile/models.confと組で検査するのが本来の意図）。
  out="$(AIENV_LOCAL_PROFILE_PATH="$PROFILE_SAMPLE" AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" AIENV_BEDROCK_ENV_FILE="$BEDROCK_SAMPLE" "$INSTALL_MAIN" --print-bedrock-env-json)"; rc=$?
  assert_eq "AC-3: exit0" "0" "$rc"
  for cred_key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    assert_not_contains "AC-3: 出力に${cred_key}を含まない" "$out" "$cred_key"
  done
  assert_contains "AC-3: 出力がJSONのenvキーを持つ" "$out" '"env"'
}

echo "=== AC-4: ngwords・/Users/・禁止キー名を含まない（3本） ==="
{
  if [ -f "$NGWORDS_FILE" ]; then
    for f in "$PROFILE_SAMPLE" "$MODELS_SAMPLE" "$BEDROCK_SAMPLE"; do
      hit="$(grep -n -F -f "$NGWORDS_FILE" "$f" || true)"
      assert_eq "AC-4: $(basename "$f") がngwordsに当たらない" "" "$hit"
    done
  else
    fail_case "AC-4: NGWORDS_FILE($NGWORDS_FILE)が見つからない"
  fi

  # 禁止キー名の判定は claude/hooks/lib/profile_resolve.py の
  # FORBIDDEN_KEY_SUBSTRINGS（V15・大小文字を問わない部分一致）を単一の値表
  # として直接読み込む（2026-09-08 Codexレビュー指摘・MAJOR対応・1巡目:
  # 固定6キー名の直書きだとOPENAI_API_KEYやCLIENT_SECRETのような新種を
  # 検出できない）。key=value・key: の両形式からキー名だけを緩く抜き出す。
  forbidden_substrings="$(python3 -c "
import sys
sys.path.insert(0, '$(dirname "$LIB")')
import profile_resolve as pr
for s in pr.FORBIDDEN_KEY_SUBSTRINGS:
    print(s)
")"; forbidden_rc=$?
  # 2026-09-08 Codexレビュー指摘・MAJOR対応・2巡目: import失敗時に
  # forbidden_substringsが空のまま検査が無効化されて緑になる（fail-open）
  # のを防ぐ。import失敗・空・既知の代表2件（secret/api_key）が無ければ
  # fail-closedで即座に落とす。
  if [ "$forbidden_rc" -ne 0 ] || [ -z "$forbidden_substrings" ]; then
    fail_case "AC-4: FORBIDDEN_KEY_SUBSTRINGSのimportに失敗した（fail-closed）"
  fi
  assert_contains "AC-4: FORBIDDEN_KEY_SUBSTRINGSにsecretを含む（importの健全性）" "$forbidden_substrings" "secret"
  assert_contains "AC-4: FORBIDDEN_KEY_SUBSTRINGSにapi_keyを含む（importの健全性）" "$forbidden_substrings" "api_key"
  # forbidden_key_hits <file> — ファイル内の key=value / key: 形式のキー名を
  # 緩く抜き出し、FORBIDDEN_KEY_SUBSTRINGSに部分一致（大小文字非依存）する
  # ものを "<キー>(<一致した部分文字列>) " の列で標準出力へ返す（assertしない）。
  forbidden_key_hits() {
    local f="$1"
    local key sub hit_line
    hit_line=""
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      local lower_key
      lower_key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
      while IFS= read -r sub; do
        [ -n "$sub" ] || continue
        case "$lower_key" in
          *"$sub"*) hit_line="${hit_line}${key}(${sub}) " ;;
        esac
      done <<< "$forbidden_substrings"
    done < <(grep -oE '^[[:space:]]*#?[[:space:]]*\[?[A-Za-z0-9_.-]+\]?[[:space:]]*[:=]' "$f" | sed -E 's/^[[:space:]]*#?[[:space:]]*\[?//; s/\]?[[:space:]]*[:=]$//')
    printf '%s' "$hit_line"
  }
  check_forbidden_keys() {
    local f="$1"
    assert_eq "AC-4: $(basename "$f") が禁止キー名の部分一致を含まない" "" "$(forbidden_key_hits "$f")"
  }

  # 陽性対照（2026-09-08 Codexレビュー指摘・MAJOR対応・2巡目）: 検査ロジック
  # 自体が実際に禁止キーを検出できることを、固定6キー名の直書きには無い
  # 新種（OPENAI_API_KEY）と大小混在（Client_Secret）の一時コピーで確認する
  # （検査が空文字の恒真判定に陥っていないことの証拠）。
  positive_ctrl="$WORK/bedrock-forbidden-positive.env.sample"
  cp "$BEDROCK_SAMPLE" "$positive_ctrl"
  printf 'OPENAI_API_KEY=xxxx\nClient_Secret=yyyy\n' >> "$positive_ctrl"
  ctrl_hits="$(forbidden_key_hits "$positive_ctrl")"
  assert_contains "AC-4陽性対照: OPENAI_API_KEYを検出する" "$ctrl_hits" "OPENAI_API_KEY(api_key)"
  assert_contains "AC-4陽性対照: Client_Secret（大小混在）を検出する" "$ctrl_hits" "Client_Secret(secret)"

  for f in "$PROFILE_SAMPLE" "$MODELS_SAMPLE" "$BEDROCK_SAMPLE"; do
    hit="$(grep -n '/Users/' "$f" || true)"
    assert_eq "AC-4: $(basename "$f") が/Users/を含まない" "" "$hit"
    check_forbidden_keys "$f"
  done
}

echo "=== 変異確認: schema_version を5に書き換えた一時コピーでAC-1が赤になる ==="
{
  mutant="$WORK/profile-schema5.md.sample"
  sed 's/^schema_version: 6$/schema_version: 5/' "$PROFILE_SAMPLE" > "$mutant"
  grep -q '^schema_version: 5$' "$mutant" || fail_case "変異確認: 前提（schema_versionを5へ書き換え済み）"
  out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$mutant" --agents-dir "$AGENTS_DIR")"; rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" != OK* ]]; then
    pass "変異確認: schema_version=5でAC-1が赤になる（サンプルが実際にresolverを通っている証拠）"
  else
    fail_case "変異確認: schema_version=5でも通ってしまった（実際=$out）"
  fi
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
