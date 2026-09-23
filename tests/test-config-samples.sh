#!/usr/bin/env bash
# tests/test-config-samples.sh — 設定ファイルsample配布-実装-2026-09-08.md
# の受入条件 AC-1〜AC-4（config/*.sample 3本が resolver・installer を
# 実際に通ること）と、AC-5（tests/ が sample の定義名・ローカル実体パスを
# 持たない＝設定値への結合の再発防止・2026-09-19 着手順 1）を検証する。
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
# ngwords はローカル実体（private repo）にしか無いので既定では指さない。
# 指定が無ければ AC-4 の ngwords 部分は skip（赤にしない）。
NGWORDS_FILE="${NGWORDS_FILE:-}"

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

echo "=== AC-1: resolve が OK・TEAM_MODE:<値>・MACHINE_ROLE:<値> の形を含み MODEL_MISMATCH を含まない ==="
{
  out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$PROFILE_SAMPLE" --agents-dir "$AGENTS_DIR")"; rc=$?
  assert_eq "AC-1: exit0" "0" "$rc"
  assert_starts_with "AC-1: OKで始まる" "$out" "OK"
  # 値でなく形を見る（sample の値を変えても赤にしない＝Decision 09-17 ③）。
  assert_eq "AC-1: TEAM_MODE:<値> の形" "1" "$(printf '%s' "$out" | grep -cE '(^|\t)TEAM_MODE:[a-z]+(\t|$)')"
  assert_eq "AC-1: MACHINE_ROLE:<値> の形" "1" "$(printf '%s' "$out" | grep -cE '(^|\t)MACHINE_ROLE:[a-z]+(\t|$)')"
  assert_not_contains "AC-1: MODEL_MISMATCHを含まない" "$out" "MODEL_MISMATCH"
  # 要件書 AC-1（形の不変条件の追加分）: 未定義参照が出ていない。
  # ⚠️ VACANT_REASON: の非包含は v1.5 で撤去した（要件書 FR-7）。未対応経路の
  # 候補を configured に書くと保留にしたいが、resolve は rc=0 のまま
  # VACANT_REASON: を1件出すため、この判定と両立できない。
  assert_not_contains "AC-1: UNKNOWN_EXTRA:を含まない" "$out" "UNKNOWN_EXTRA:"
}

echo "=== AC-1b: --bedrock-env を渡しても壊れない ==="
{
  out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$PROFILE_SAMPLE" --agents-dir "$AGENTS_DIR" --bedrock-env "$BEDROCK_SAMPLE")"; rc=$?
  assert_eq "AC-1b: exit0" "0" "$rc"
  assert_starts_with "AC-1b: OKで始まる" "$out" "OK"
}

echo "=== AC-1c: 配役表の職種名が職種定義ファイルの集合に収まる（要件書 AC-3・FR-3） ==="
{
  # `leader`/`navi`/`ja-doc` は職種定義ファイルを持たない spawn 対象外の3職種
  # （resolver の CORE_ROLES_WITHOUT_REPO_AGENT_FILE と同じ集合）。片方向
  # （配役表→マニフェスト）だけを見るので、行を書かない職種があっても通る。
  manifest="$( (ls "$AGENTS_DIR" | sed 's/\.md$//'; printf 'leader\nnavi\nja-doc\n') | sort -u )"
  used="$(grep -oE '^role\.[a-z-]+' "$PROFILE_SAMPLE" | sed 's/^role\.//' | sort -u)"
  used_not_in_manifest="$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$manifest"))"
  assert_eq "AC-1c: 配役表の職種名がマニフェストに収まる" "" "$used_not_in_manifest"
  # 要件書 AC-3 の2行目（空虚な真の禁止）。この節に assert_true は無いため
  # 既存の fail_case を直接使う（AC-2 側のガードと同じ扱い＝新しい
  # ヘルパを増やさない・NFR-1）。
  if [ -z "$used" ]; then
    fail_case "AC-1c: 配役表に role. 行が1件も無い（空虚な真の禁止）"
  fi
}

echo "=== OPUS55-AC-1: config/models.conf.sample の opus-*定義がclaude-opus-5-5・他3定義は不変 ==="
{
  # Opus 5.5 採用（opus-*定義をclaude-opus-5-5へ）AC-1: [opus-high]/[opus-medium]/
  # [opus-low]のmodel=がclaude-opus-5-5（provider/effortは変えない）。
  # fable-high/sonnet-high/haikuは不変（値でなく対象3定義だけを見る）。
  model_of() { # model_of <定義名> — [定義名]セクション内のmodel=値を1つ返す
    awk -v name="[$1]" '
      $0==name{insec=1; next}
      /^\[/{insec=0}
      insec && /^model=/{sub(/^model=/,""); print; exit}
    ' "$MODELS_SAMPLE"
  }
  for name in opus-high opus-medium opus-low; do
    assert_eq "OPUS55-AC-1: [$name] model==claude-opus-5-5" "claude-opus-5-5" "$(model_of "$name")"
  done
  assert_eq "OPUS55-AC-1: [fable-high] model は不変" "claude-fable-5-1" "$(model_of fable-high)"
  assert_eq "OPUS55-AC-1: [sonnet-high] model は不変" "claude-sonnet-5" "$(model_of sonnet-high)"
  assert_eq "OPUS55-AC-1: [haiku] model は不変" "claude-haiku-4-5-20251001" "$(model_of haiku)"
}

echo "=== AC-2: 経路（provider×execution）ごとの代表1件が起動でき、未対応の経路は保留になる（要件書 FR-7・AC-2） ==="
{
  check_candidate() {
    local role="$1" def="$2" route="$3"
    local out rc=0
    out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve-candidate "$PROFILE_SAMPLE" --role "$role" --model-def "$def" --agents-dir "$AGENTS_DIR" 2>&1)" || rc=$?
    case "$out" in
      OK*)
        assert_eq "AC-2: route=$route role=$role def=$def exit0" "0" "$rc"
        assert_contains "AC-2: route=$route role=$role def=$def 定義名が現れる" "$out" "$def"
        ;;
      *SUBAGENT_PROVIDER_UNSUPPORTED*)
        # 要件書 FR-7: この機体で未対応の経路は赤にせず保留にする。
        echo "  hold - この機体で未対応の経路（${route}）"
        pass "AC-2: route=$route role=$role def=$def この機体で未対応のため保留"
        ;;
      *)
        fail_case "AC-2: route=$route role=$role def=$def exit0 (expected=[0] actual=[$rc] out=[$out])"
        ;;
    esac
  }
  # 要件書 AC-2・FR-7: 起動可能性は provider×execution の経路ごとに代表1件だけ
  # 見る。list-roles の configured 行を経路（provider/execution）でまとめ、
  # 経路ごと最初の1組だけを resolve-candidate に通す（テストに literal で
  # 列挙しない）。同じ経路の残りの候補・どこからも参照されていない定義は
  # 個別に検査しない。組が0件のときは検査が空回りしたものとして失敗させる
  # （空虚な真の禁止）。
  routes_reps="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" list-roles "$PROFILE_SAMPLE" \
    | awk -F'\t' '$2=="configured" && !seen[$4"/"$6]++ {print $1"\t"$3"\t"$4"/"$6}')"
  routes_count=0
  while IFS=$'\t' read -r role def route; do
    [ -n "$role" ] || continue
    check_candidate "$role" "$def" "$route"
    routes_count=$((routes_count + 1))
  done <<< "$routes_reps"
  if [ "$routes_count" -lt 1 ]; then
    fail_case "AC-2: サンプルから経路が1件も生成されなかった（空虚な真の禁止）"
  fi
}

echo "=== AC-3: --render-settings-json の生成物（sample 3本を入力）に認証情報キーが無く正常終了 ==="
{
  # AC-3 は「AIENV_BEDROCK_ENV_FILE＝bedrock.env.sample＋AIENV_LOCAL_PROFILE_PATH＝
  # profile.md.sample＋AIENV_MODEL_DEFS_FILE＝models.conf.sample の3変数を与えて
  # exit 0・生成物の env に認証情報キーなし」と定義する（旧 --print-bedrock-env-json
  # は 2026-09-19 に退役。生成物は installer 本番と同じ generate_settings_json() の
  # 出力＝同じ性質を検査できる）。bedrock.env は生成側が chmod 600 するため
  # repo のサンプルを直接指さず一時コピーを使う。HOME も偽装し実 ~/.claude を読まない。
  ac3_home="$WORK/ac3-home"; mkdir -p "$ac3_home"
  ac3_bedrock="$WORK/ac3-bedrock.env"; cp "$BEDROCK_SAMPLE" "$ac3_bedrock"
  ac3_out="$WORK/ac3-settings.json"
  AIENV_LOCAL_PROFILE_PATH="$PROFILE_SAMPLE" AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" AIENV_BEDROCK_ENV_FILE="$ac3_bedrock" \
    HOME="$ac3_home" "$INSTALL_MAIN" --render-settings-json "$ac3_out" >/dev/null 2>&1; rc=$?
  assert_eq "AC-3: exit0" "0" "$rc"
  env_keys="$(python3 -c "import json; print(' '.join(json.load(open('$ac3_out')).get('env', {}).keys()))" 2>/dev/null)"
  for cred_key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    assert_not_contains "AC-3: 生成物の env に ${cred_key} を含まない" "$env_keys" "$cred_key"
  done
  assert_contains "AC-3: 生成物の env に sample の許可キー（CLAUDE_CODE_USE_BEDROCK）が取り込まれる" "$env_keys" "CLAUDE_CODE_USE_BEDROCK"
  assert_eq "AC-3: 偽 HOME に .claude が作られない（生成物以外に何も置かない）" "" "$(ls -A "$ac3_home")"
}

echo "=== AC-4: ngwords・/Users/・禁止キー名を含まない（3本） ==="
{
  if [ -n "$NGWORDS_FILE" ] && [ -f "$NGWORDS_FILE" ]; then
    for f in "$PROFILE_SAMPLE" "$MODELS_SAMPLE" "$BEDROCK_SAMPLE"; do
      hit="$(grep -n -F -f "$NGWORDS_FILE" "$f" || true)"
      assert_eq "AC-4: $(basename "$f") がngwordsに当たらない" "" "$hit"
    done
  else
    echo "  skip - AC-4 ngwords: NGWORDS_FILE 未指定（または不在）"
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

echo "=== AC-5: tests/ が sample の定義名・ローカル実体パスを持たない（再発防止） ==="
{
  # (a) 定義名: 行頭 [name] を毎回 sample から取る。別名 4 語（fable/opus/sonnet/haiku）と同名の定義は除外
  names="$(grep -oE '^\[[a-z0-9][a-z0-9-]*\]' "$MODELS_SAMPLE" | tr -d '[]' | grep -vxE 'fable|opus|sonnet|haiku' | paste -sd'|' -)"
  # (b) ローカル実体・private repo（HOME 偽装で吸収できない literal 形だけ）。
  #     ~/.claude/・~/Data/obsidian の形は入れない（ゲート系テストが deny 入力として正当に使う）
  paths='takumi009-ai-env-private|/Users/[^/[:space:]]+/(Data/obsidian|\.config|\.claude|\.codex)'
  # 除外＝自ファイルだけ（パターン定義行が自己一致する）
  excl='tests/test-config-samples.sh'
  scan() {  # scan <file...> → 該当行（コメント行・見出し行を除く）
    grep -nHE "(^|[^a-z0-9-])(${names})([^a-z0-9-]|$)|${paths}" "$@" \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|^[^:]+:[0-9]+:echo "===' || true
  }
  [ -n "$names" ] || { fail_case "AC-5: sample から定義名を 1 件も抽出できない（空虚な真の禁止）"; names='__none__'; }
  targets="$(ls "$TESTS_DIR"/test-*.sh "$TESTS_DIR"/lib-*.sh | grep -vE "(${excl})$")"
  hits="$(scan $targets)"
  assert_eq "AC-5: 該当 0 行" "" "$hits"
  # 陽性対照: 先頭の定義名と private パスを書いた一時ファイルが両方 hit する
  first="${names%%|*}"; ctrl="$WORK/ac5-positive.sh"
  printf 'x=%s\ny=$HOME/work/takumi009-ai-env-private/ngwords.txt\n' "$first" > "$ctrl"
  assert_eq "AC-5 陽性対照: 2 行 hit" "2" "$(scan "$ctrl" | wc -l | tr -d ' ')"
}

echo "=== 変異確認: schema_version を 1 つ下げた一時コピーでAC-1が赤になる ==="
{
  mutant="$WORK/profile-schema-prev.md.sample"
  cur="$(python3 "$LIB" print-schema-version "$PROFILE_SAMPLE")"
  sed "s/^schema_version: ${cur}\$/schema_version: $((cur-1))/" "$PROFILE_SAMPLE" > "$mutant"
  grep -q "^schema_version: $((cur-1))\$" "$mutant" || fail_case "変異確認: 前提（schema_versionを$((cur-1))へ書き換え済み）"
  out="$(AIENV_MODEL_DEFS_FILE="$MODELS_SAMPLE" python3 "$LIB" resolve "$mutant" --agents-dir "$AGENTS_DIR")"; rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" != OK* ]]; then
    pass "変異確認: schema_version=$((cur-1))でAC-1が赤になる（サンプルが実際にresolverを通っている証拠）"
  else
    fail_case "変異確認: schema_version=$((cur-1))でも通ってしまった（実際=$out）"
  fi
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
