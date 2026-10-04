#!/usr/bin/env bash
# core/assembly/install-main.sh のユニットテスト（settings.json登録フックとinstaller
# 配置の突合・雛形配置・Bedrock最小セット・--render-settings-json・
# --check-profile・職種定義の配布報告）。
#
# 値は resolver（team/executor/profile_resolve.py）の直叩きと突き合わせ、
# テストに literal で書かない。fixture の定義名は `t-` 接頭辞（config/*.sample
# の実名と結合しない＝tests/test-config-samples.sh AC-5）。
#
# 実行方法: bash tests/test-install-main.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/core/assembly/install-main.sh"
LIB="$REPO_ROOT/team/executor/profile_resolve.py"
FIXTURES="$TESTS_DIR/fixtures"

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
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# assert_agents_line <desc> <stdout> <kind:初回未配置|dangling> <role>
# 設計§2.1の固定文（kindごとの説明文・件数）を検査し、対象ロールが名前一覧に
# カンマ区切りの1トークンとして含まれることを確認する。
assert_agents_line() {
  local desc="$1" out="$2" kind="$3" role="$4"
  local line expected_desc names
  case "$kind" in
    初回未配置) expected_desc='正常・配置しました' ;;
    dangling) expected_desc='異常・repo から消えた定義のリンクが残っています。削除は本人が判断' ;;
    *) fail_case "$desc (assert_agents_line: 未知のkind=$kind)"; return ;;
  esac
  line="$(printf '%s\n' "$out" | grep "AGENTS: $kind " || true)"
  if [ -z "$line" ]; then
    fail_case "$desc (AGENTS: $kind の行自体が無い。out=[$out])"
    return
  fi
  if ! printf '%s' "$line" | grep -qE "AGENTS: ${kind} [0-9]+件（${expected_desc}）: .+"; then
    fail_case "$desc (固定文の型が一致しない。期待する説明文=[${expected_desc}]。行=[$line])"
    return
  fi
  names="$(printf '%s' "$line" | sed -E 's/.*[)）]: //')"
  case ",$names," in
    *",$role,"*) pass "$desc" ;;
    *) fail_case "$desc (名前一覧に $role が含まれない。行=[$line])" ;;
  esac
}

# write_models_conf_at <dir> — モデル定義ファイル（models.conf）を <dir>/models.conf
# へ書く。role行は`model=<定義名>[,...]`で定義名を参照するだけなので、role.leader
# の解決を伴うテストは全てこの定義ファイルを必要とする。
write_models_conf_at() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/models.conf" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5

[t-opus-high]
provider=anthropic-api
model=claude-opus-5-5
effort=high

[t-bedrock-opus]
provider=bedrock
model=opus
EOF
}

# make_fake_home_no_profile <home> — 実体プロファイルを置かない版（雛形配置＝
# profile.mdの生成・非破壊性そのものを検証するテスト専用）。
make_fake_home_no_profile() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

# make_fake_home <home> — 妥当な実体プロファイル＋models.confを置いた偽HOME。
# 本ファイルの多くのテストの主眼＝symlink化・settings.json生成の検証であり、
# 雛形配置に依存させない（テストの独立性）。
make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  mkdir -p "$home/.config/takumi009-ai-env"
  write_models_conf_at "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: test-install-main-machine
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-sonnet-high
---
EOF
}

# write_v2_profile_with_bedrock_role <dest> <alias> — role.researcherを
# provider=bedrock model=<alias>（定義名t-bedrock-<alias>経由）で配役した
# プロファイルを書く（動的Bedrock許可キーのテスト用）。併せて<dest>と同じ
# ディレクトリへmodels.confを書く。
write_v2_profile_with_bedrock_role() {
  local dest="$1" alias="$2"
  mkdir -p "$(dirname "$dest")"
  write_models_conf_at "$(dirname "$dest")"
  if [ "$alias" != "opus" ]; then
    cat >> "$(dirname "$dest")/models.conf" <<EOF

[t-bedrock-${alias}]
provider=bedrock
model=${alias}
EOF
  fi
  cat > "$dest" <<EOF
---
schema_version: 7
profile_slug: test
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=main
role.leader: configured model=t-sonnet-high
role.researcher: configured model=t-bedrock-${alias}
---
EOF
}

echo "=== 1. settings.jsonに登録済みの全フックがinstall-main.shでも配置される（installer漏れの再発防止） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  # core/assembly/settings.json の "command" フィールドから $HOME/.claude/hooks/*.sh の
  # パス一覧を抽出する（bash 3.2互換のため mapfile は使わない）。
  hook_paths=()
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    hook_paths+=("$name")
  done < <(grep -o '"command": "\$HOME/\.claude/hooks/[a-zA-Z0-9_-]*\.sh"' "$REPO_ROOT/core/assembly/settings.json" \
    | sed -E 's/.*hooks\/([a-zA-Z0-9_-]+\.sh)".*/\1/' | sort -u)

  assert_true "settings.jsonから1件以上のフックを抽出できた" \
    "$([[ "${#hook_paths[@]}" -ge 1 ]] && echo 1 || echo 0)"

  missing=0
  for name in "${hook_paths[@]}"; do
    if [[ ! -L "$FAKE_HOME/.claude/hooks/$name" ]]; then
      fail_case "settings.json登録フック '$name' がinstall-main.shで配置されていない"
      missing=$((missing + 1))
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    pass "settings.json登録済み全フック（${#hook_paths[@]}件）がsymlink配置されている"
  fi
  assert_eq "usage-inject.sh のsymlink先はrepo" "$REPO_ROOT/usage/executor/usage-inject.sh" \
    "$(readlink "$FAKE_HOME/.claude/hooks/usage-inject.sh")"
  # cmux/ 配下の3本は symlink せず repo内の実体を絶対パスで指す（chmod一覧への
  # 追加漏れが無いことだけを見る）。
  for f in cmux-task-model.sh cmux-next-model.sh cmux-task-declare.sh; do
    assert_true "cmux/${f} に実行権限が付与されている" \
      "$([[ -x "$REPO_ROOT/dock/executor/$f" ]] && echo 1 || echo 0)"
  done

  # テンプレ収載キー（通知系2つ・profile.md の Read allow ルール）が生成側にも
  # 含まれる（期待値はテンプレから動的に取る）。
  tpl="$REPO_ROOT/core/assembly/settings.json"
  for key in agentPushNotifEnabled inputNeededNotifEnabled; do
    exp="$(python3 -c "import json; d=json.load(open('$tpl')); print(d.get('$key'))")"
    act="$(python3 -c "import json; d=json.load(open('$FAKE_HOME/.claude/settings.json')); print(d.get('$key'))")"
    assert_eq "生成settings.jsonの${key}はテンプレと同値" "$exp" "$act"
  done
  rule="$(python3 -c "import json; print(next(r for r in json.load(open('$tpl'))['permissions']['allow'] if r.startswith('Read(') and r.endswith('profile.md)')))")"
  assert_true "生成settings.jsonのpermissions.allowにテンプレのprofile.md用Read allowルールが含まれる" \
    "$(python3 -c "import json; exit(0 if '$rule' in json.load(open('$FAKE_HOME/.claude/settings.json'))['permissions']['allow'] else 1)" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. ローカル実体プロファイルの雛形配置: サンプルがあり実体が無ければコピーする（P1機構） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home_no_profile "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  # 本テストの主眼＝雛形コピー自体の正しさ。installer本体の終了コードは見ない
  # （偽HOMEにはmodels.confが無いため後段のsettings.json生成は失敗しうる）。
  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" >/dev/null 2>&1 || true

  assert_true "profile.mdが作成される" \
    "$([[ -f "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"
  assert_true "symlinkではなく実ファイルとしてコピーされる（雛形は独立した実体）" \
    "$([[ ! -L "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"
  assert_true "実体はteam/data/profile.md.sampleとバイト完全一致する（生ファイルの単純コピー）" \
    "$(diff -q "$TMP_REPO/team/data/profile.md.sample" "$FAKE_HOME/.config/takumi009-ai-env/profile.md" >/dev/null 2>&1 && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 3. ローカル実体プロファイルの雛形配置: 非破壊性（既存が通常ファイル/ディレクトリ/symlink/broken symlinkのいずれでも上書きしない） ==="
{
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  for kind in file dir symlink broken_symlink; do
    FAKE_HOME="$(mktemp -d)"
    make_fake_home_no_profile "$FAKE_HOME"
    mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
    PROFILE_DEST="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
    case "$kind" in
      file) echo "既存の実体（変更不可）" > "$PROFILE_DEST" ;;
      dir) mkdir -p "$PROFILE_DEST" ;;
      symlink)
        ELSEWHERE="$(mktemp -d)/target.md"
        echo "symlink先の中身" > "$ELSEWHERE"
        ln -s "$ELSEWHERE" "$PROFILE_DEST"
        ;;
      broken_symlink) ln -s "/nonexistent-target-$$.md" "$PROFILE_DEST" ;;
    esac
    before_readlink="$( [[ -L "$PROFILE_DEST" ]] && readlink "$PROFILE_DEST" || echo "" )"

    # 4種とも「profile.mdが読めない／有効でない」状態なので resolver が非0を
    # 返し、settings.json は生成されず installer は非0で中止する（S2）。
    rc=0
    out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?

    assert_true "[$kind] profile.mdが読めない/有効でない状態のためexit非0で中止する" \
      "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
    assert_true "[$kind] 既存が壊れずに残る（上書きされない）" \
      "$([[ -e "$PROFILE_DEST" || -L "$PROFILE_DEST" ]] && echo 1 || echo 0)"
    if [[ -n "$before_readlink" ]]; then
      assert_eq "[$kind] symlinkの指向先は不変" "$before_readlink" "$(readlink "$PROFILE_DEST" 2>/dev/null || echo "")"
    fi
    assert_true "[$kind] 上書きskipのWARNが出る" \
      "$(echo "$out" | grep -q 'ローカル実体プロファイルは既に存在するため雛形コピーをskipしました' && echo 1 || echo 0)"

    rm -rf "$FAKE_HOME"
  done

  rm -rf "$TMP_REPO"
}

echo "=== 4. ローカル実体プロファイルの雛形配置: サンプルが無ければWARNのみ（雛形は作らない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home_no_profile "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  rm -f "$TMP_REPO/team/data/profile.md.sample"

  # サンプル無し→雛形無し→実体無しで resolver が PROFILE_NOT_FOUND を返すため
  # settings.json は生成されず非0で終わる（既定モデルへの縮退は退役済み）。
  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?
  assert_true "サンプル未整備のWARNが出る（詳細に「No such file」相当を含む）" \
    "$(echo "$out" | grep -q 'team/data/profile.md.sampleを読み取れませんでした' && echo "$out" | grep -q '詳細:.*[Nn]o such file' && echo 1 || echo 0)"
  assert_true "profile.mdは作成されない" \
    "$([[ ! -e "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"
  assert_true "実体が無いため settings.json は生成されず非0で終了する（既定モデルへ静かに倒れない）" \
    "$([[ "$rc" -ne 0 && ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo "$out" | grep -q 'PROFILE_NOT_FOUND' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 5. --dry-run: 雛形配置・settings.json生成・symlink化のいずれも行わず計画だけ表示する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  PRE_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "would generate/would link の計画表示が出る" \
    "$(echo "$out" | grep -q 'would generate (not symlink):.*settings.json' && echo "$out" | grep -q 'would link:' && echo 1 || echo 0)"
  assert_true "settings.jsonは生成されず、hooksもsymlink化されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" && ! -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
  assert_eq "profileは一切変更されない" "$PRE_SHA" "$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  # 実体が無い偽HOMEでは would copy の計画だけ出て実際には作らない。
  FAKE_HOME2="$(mktemp -d)"
  out2="$(HOME="$FAKE_HOME2" bash "$SCRIPT" --dry-run 2>&1)"
  assert_true "would copy profile sample の計画表示が出て、実際にはprofile.mdは作られない" \
    "$(echo "$out2" | grep -q 'would copy profile sample:.*profile.md.sample' && [[ ! -e "$FAKE_HOME2/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$FAKE_HOME2"
}

echo "=== 6. Bedrock最小セット: envファイルの値がsettings.jsonのenvブロックへ取り込まれる（動的許可キー） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # role.researcher を provider=bedrock model=opus に配役し、
  # ANTHROPIC_DEFAULT_OPUS_MODEL が動的に許可されることを確認する。
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
# コメント行
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8

EOF
  chmod 644 "$ENV_FILE"

  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  assert_true "CLAUDE_CODE_USE_BEDROCK・AWS_REGIONがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' and d['env'].get('AWS_REGION')=='us-east-1' else 1)" && echo 1 || echo 0)"
  assert_true "role.researcherがprovider=bedrock model=opusを使っているため、ANTHROPIC_DEFAULT_OPUS_MODELが動的に許可されenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('ANTHROPIC_DEFAULT_OPUS_MODEL')=='us.anthropic.claude-opus-4-8' else 1)" && echo 1 || echo 0)"
  assert_true "テンプレ由来のDISABLE_AUTOUPDATERは残る" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('DISABLE_AUTOUPDATER')=='1' else 1)" && echo 1 || echo 0)"
  perm="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  assert_eq "envファイルのパーミッションが0600へ揃えられる" "600" "$perm"

  rm -rf "$FAKE_HOME"
}

echo "=== 7. Bedrock最小セット: role.*がprovider=bedrockでその別名を使っていなければANTHROPIC_DEFAULT_*_MODELは許可されない（名前だけ許可リストに合う任意キーへ秘密値を入れる穴を塞ぐ） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"   # bedrock役職なし
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8
ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5
EOF
  chmod 644 "$ENV_FILE"

  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

  assert_true "CLAUDE_CODE_USE_BEDROCK（固定許可）は引き続き取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "ANTHROPIC_DEFAULT_OPUS/HAIKU_MODELは未使用のため取り込まれない" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));e=d.get('env',{});exit(0 if 'ANTHROPIC_DEFAULT_OPUS_MODEL' not in e and 'ANTHROPIC_DEFAULT_HAIKU_MODEL' not in e else 1)" && echo 1 || echo 0)"
  assert_true "未使用キーは許可リスト外のWARNとして扱われる" \
    "$(echo "$out" | grep -q '許可リスト外のキーがあったため取り込みませんでした' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 8. Bedrock最小セット: 許可リスト外のキー（AWS認証情報等を想定）は取り込まずWARNし、値はログにも出さない（絶対厳守③） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
DISABLE_AUTOUPDATER=0
AWS_ACCESS_KEY_ID=AKIAEXAMPLE
EOF

  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

  assert_true "テンプレ値(1)が保持される（envファイルの0では上書きされない）" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('DISABLE_AUTOUPDATER')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "許可リスト外キーのWARNが出る" \
    "$(echo "$out" | grep -q '許可リスト外のキーがあったため取り込みませんでした' && echo 1 || echo 0)"
  assert_true "AWS_ACCESS_KEY_IDはsettings.jsonへ一切取り込まれない" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if 'AWS_ACCESS_KEY_ID' not in d.get('env',{}) else 1)" && echo 1 || echo 0)"
  assert_true "AWS_ACCESS_KEY_IDの値そのものはログにも出ない（キー名のみ許容）" \
    "$(echo "$out" | grep -q 'AKIAEXAMPLE' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 9. Bedrock最小セット: Bedrock envパスがディレクトリ（実在するのに読めない）の場合はsettings.json本体の生成を中止し既存ファイルを保持して非0終了する（設計書S4） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?

  assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "ディレクトリである旨のWARNが出る（無警告のまま素通りしない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_true "中止のみで.pre-aienv.bakも一時ファイルも作られない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json.pre-aienv.bak" ]] && [[ "$(find "$FAKE_HOME/.claude" -maxdepth 1 -name '.settings.json.aienv-tmp.*' | wc -l | tr -d ' ')" = "0" ]] && echo 1 || echo 0)"
  assert_true "settings.json以外の処理(hooksのsymlink化)は正常に続行している" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 10. Bedrock最小セット: Bedrock envファイルの解析（読取）自体が失敗する場合もsettings.json本体の生成を中止し既存ファイルを保持する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{"model": "sentinel-pre-existing-value", "env": {"CLAUDE_CODE_USE_BEDROCK": "1"}}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  # 不正なUTF-8バイト列（python3 open()がUnicodeDecodeErrorで非0終了する）。
  printf '\xff\xfe\x00\x01invalid-utf8-\xfe' > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?

  assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "解析失敗のWARNが出る" \
    "$(echo "$out" | grep -q 'Bedrock envファイルの解析に失敗しました' && echo 1 || echo 0)"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"

  rm -rf "$FAKE_HOME"
}

echo "=== 11. Bedrock最小セット: 解析できない行は行番号付きでWARNし、値は出さない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
THIS_LINE_HAS_NO_EQUALS_SIGN_AND_MIGHT_LEAK_A_TOKEN_abcdef123456
=empty-key-value
EOF

  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

  assert_true "解析できない行のWARNが行番号付きで出る" \
    "$(echo "$out" | grep -q '解析できない行がありました（行番号: 2,3）' && echo 1 || echo 0)"
  assert_true "不正行の値そのものはログに出ない" \
    "$(echo "$out" | grep -q 'MIGHT_LEAK_A_TOKEN' && echo 0 || echo 1)"
  assert_true "正常行(CLAUDE_CODE_USE_BEDROCK)は取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 12. Bedrock最小セット: envファイルが無ければ何も変わらない（既存の全マシンの挙動を維持） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  assert_true "envブロックはテンプレどおりDISABLE_AUTOUPDATERのみ" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if list(d['env'].keys())==['DISABLE_AUTOUPDATER'] else 1)" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 13. --render-settings-json: 生成物だけを返し、偽HOMEには何も置かない（check-drift ①-2 の入力口・設計 §3.5） ==="
{
  FAKE_HOME="$(mktemp -d)"
  OUT_DIR="$(mktemp -d)"

  rc=0
  out="$(AIENV_LOCAL_PROFILE_PATH="$FIXTURES/profile.md" AIENV_MODEL_DEFS_FILE="$FIXTURES/models.conf" \
    HOME="$FAKE_HOME" bash "$SCRIPT" --render-settings-json "$OUT_DIR/settings.json" 2>/dev/null)" || rc=$?
  # 期待値は resolver 直叩き（resolve-leader）の JSON から取る（値をテストに書かない）。
  exp_model="$(AIENV_MODEL_DEFS_FILE="$FIXTURES/models.conf" python3 "$LIB" resolve-leader "$FIXTURES/profile.md" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')"
  act_model="$(python3 -c "import json; print(json.load(open('$OUT_DIR/settings.json')).get('model',''))" 2>/dev/null || echo "")"
  assert_true "RS-1: exit 0 で生成物の model がプレースホルダでなく resolver 直叩きの値と一致する" \
    "$([[ "$rc" -eq 0 && -n "$act_model" && "$act_model" != "__AIENV_MODEL__" && "$act_model" == "$exp_model" ]] && echo 1 || echo 0)"
  assert_true "RS-2: 偽 HOME に .claude/.codex/.config が作られない（生成物以外に何も置かない）" \
    "$([[ ! -e "$FAKE_HOME/.claude" && ! -e "$FAKE_HOME/.codex" && ! -e "$FAKE_HOME/.config" ]] && echo 1 || echo 0)"

  rc=0
  out="$(AIENV_LOCAL_PROFILE_PATH="$FAKE_HOME/nonexistent-profile.md" AIENV_MODEL_DEFS_FILE="$FIXTURES/models.conf" \
    HOME="$FAKE_HOME" bash "$SCRIPT" --render-settings-json "$OUT_DIR/fail.json" 2>/dev/null)" || rc=$?
  assert_true "RS-3: resolver 失敗で非0・stdout 空・生成物なし" \
    "$([[ "$rc" -ne 0 && -z "$out" && ! -e "$OUT_DIR/fail.json" ]] && echo 1 || echo 0)"

  rc=0
  HOME="$FAKE_HOME" bash "$SCRIPT" --render-settings-json >/dev/null 2>&1 || rc=$?
  assert_true "出力先パス無しは非0（unknown optionと同じ扱い）" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$OUT_DIR"
}

echo "=== 14. --check-profile: stdout の1行目が resolve 行（OK…）で配役一覧は出ない（check-drift ⑧ の契約・副作用ゼロ） ==="
{
  FAKE_HOME="$(mktemp -d)"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --check-profile 2>/dev/null)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "stdout 1行目が OK で始まるタブ区切りの resolve 行" \
    "$(printf '%s\n' "$out" | head -1 | grep -qE $'^OK\t' && echo 1 || echo 0)"
  assert_true "旧・配役一覧（role.*(configured)…）は出ない" \
    "$(echo "$out" | grep -q 'role\.researcher(configured)' && echo 0 || echo 1)"
  assert_true "settings.json等は一切生成されない（副作用ゼロ）" \
    "$([[ ! -e "$FAKE_HOME/.claude" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 15. 秘匿: --check-profile・installer全体の出力にbedrock.envのpin実値が一切現れない（絶対厳守③） ==="
{
  FAKE_HOME="$(mktemp -d)"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null
  SECRET_PIN="us.anthropic.super-secret-inference-profile-id-DO-NOT-LEAK"
  cat > "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env" <<EOF
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=${SECRET_PIN}
EOF
  chmod 600 "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --check-profile 2>&1)"
  assert_true "pin実値は--check-profile出力に一切現れない" \
    "$(echo "$out" | grep -q "$SECRET_PIN" && echo 0 || echo 1)"
  out2="$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$SCRIPT" 2>&1)"
  assert_true "pin実値はinstaller全体のWARN/ログにも一切現れない" \
    "$(echo "$out2" | grep -q "$SECRET_PIN" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 16. --check-profile: resolver本体（\$lib）が見つからないとき、全角括弧直後のunbound variable誤検知で握り潰されず、実パスを含むFAILメッセージがそのまま出る ==="
{
  FAKE_HOME="$(mktemp -d)"
  MISSING_LIB="$(mktemp -u)/nonexistent-resolver-lib.py"

  rc=0
  out="$(HOME="$FAKE_HOME" AIENV_PROFILE_RESOLVE_LIB="$MISSING_LIB" bash "$SCRIPT" --check-profile 2>&1)" || rc=$?

  assert_true "exit非0" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "unbound variableのbashエラーで意図したFAILが握り潰されない" \
    "$(echo "$out" | LC_ALL=C grep -q 'unbound variable' && echo 0 || echo 1)"
  assert_true "FAILメッセージ（resolver本体（…）が見つかりません）に実パスがそのまま含まれる" \
    "$(echo "$out" | grep -q 'resolver本体（.*）が見つかりません' && echo "$out" | grep -qF "$MISSING_LIB" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 17. 設計書S6: python3不在時はsettings.json生成そのものに着手せず、既存ファイルを一切変更せず非0終了する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{"model": "sentinel-pre-existing-value"}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # python3を含まない最小限のPATHを組み立てる。
  BINDIR="$(mktemp -d)"
  for b in bash dirname basename mkdir mv cp chmod stat sed awk grep sort uniq cat cut tr wc date shasum mktemp rm ln find env true false head tail printf; do
    p="$(command -v "$b" 2>/dev/null)"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$b"
  done

  rc=0
  out="$(PATH="$BINDIR" SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0・python3不在の理由が出る" \
    "$([[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'python3 が見つかりません' && echo 1 || echo 0)"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo "=== 18. 設計書S5×S8: テンプレの\"model\"が__AIENV_MODEL__の目印でない場合、生成物が一度も存在しなければNO_GENERATED_FILEが明示される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  python3 -c "
import json
with open('$TMP_REPO/core/assembly/settings.json') as f:
    data = json.load(f)
data['model'] = 'claude-hardcoded-regression'
with open('$TMP_REPO/core/assembly/settings.json', 'w') as f:
    json.dump(data, f, indent=2)
"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?
  assert_true "exit非0・テンプレ検証失敗の理由（__AIENV_MODEL__）が出る" \
    "$([[ "$rc" -ne 0 ]] && echo "$out" | grep -q '__AIENV_MODEL__' && echo 1 || echo 0)"
  assert_true "settings.jsonは一切生成されず、NO_GENERATED_FILEが明示される" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 19. 設計書S8: 生成物が存在しない状態でS4（bedrock.env読取不能）が発生すると、settings.jsonは生成されないままinstaller全体が非0終了する（他の配置処理は完走する） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0・settings.jsonは一切生成されない" \
    "$([[ "$rc" -ne 0 && ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "他の配置処理（hooksのsymlink化）は完走する" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
  assert_true "締めの警告に機械可読トークンNO_GENERATED_FILEが明示される" \
    "$(echo "$out" | grep -q '非0終了します' && echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 20. 動的Bedrock許可キーの算出失敗時はfail-openで固定2キーへ縮退せず、settings.json生成をスキップして既存ファイルを保持したうえでdeferred非0終了する（設計書S18） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{"model": "sentinel-pre-existing-value", "env": {"CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-4-8-dummy-pin"}}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"

  # resolve-leaderは成功させ、list-rolesだけが「算出そのものの失敗」を返す偽lib。
  FAKE_LIB="$(mktemp)"
  cat > "$FAKE_LIB" <<'PYEOF'
import sys
if len(sys.argv) >= 2 and sys.argv[1] == "resolve-leader":
    print('{"model": "claude-sonnet-5"}')
    sys.exit(0)
if len(sys.argv) >= 2 and sys.argv[1] == "list-roles":
    sys.stderr.write("PROFILE_INVALID:T6\tfake failure for test\n")
    sys.exit(1)
sys.exit(1)
PYEOF

  rc=0
  out="$(SKIP_LAUNCHCTL=1 AIENV_PROFILE_RESOLVE_LIB="$FAKE_LIB" HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "算出失敗＋settings.json生成スキップの旨がWARNに出る（固定2キーへの縮退文言は出ない）" \
    "$(echo "$out" | grep -q '動的Bedrock許可キーの算出に失敗しました' && echo "$out" | grep -q '生成をスキップし、既存ファイルを保持します' && ! echo "$out" | grep -q 'のみで続行します' && echo 1 || echo 0)"
  assert_eq "既存settings.json（動的pinを含む）がバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_true "settings.json以外の後続処理（hooksのsymlink化）は完走し、締めの警告が出る（即時中断ではなくdeferred非0）" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo "$out" | grep -q '他の配置処理は完了しましたが' && echo 1 || echo 0)"

  # --render-settings-json でも同じ失敗は非0・生成物なし。
  OUT_DIR="$(mktemp -d)"
  rc=0
  AIENV_PROFILE_RESOLVE_LIB="$FAKE_LIB" HOME="$FAKE_HOME" bash "$SCRIPT" --render-settings-json "$OUT_DIR/s.json" >/dev/null 2>&1 || rc=$?
  assert_true "--render-settings-json でも算出失敗は非0で生成物を書かない" \
    "$([[ "$rc" -ne 0 && ! -e "$OUT_DIR/s.json" ]] && echo 1 || echo 0)"

  rm -f "$FAKE_LIB"
  rm -rf "$FAKE_HOME" "$OUT_DIR"
}

# --- 職種定義の配布結果を必ず報告する（前提修正 P-2・設計§2.1）。TMP_REPO（実repoの
#     丸ごとcopy）へ team/rules/agents/*.md を追加・削除して symlink 配布の挙動を検証する。 ---

echo "=== 21. PA-4: repo に定義を1本足して実行すると symlink ができ、AGENTS: 初回未配置 の固定文に名前が出る（終了コード0） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  echo "# PA-4 用の追加ロール定義（テスト専用・内容は問わない）" > "$TMP_REPO/team/rules/agents/test-pa4-role.md"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "追加したロールのsymlinkができる" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa4-role.md" ]] && echo 1 || echo 0)"
  assert_agents_line "AGENTS: 初回未配置 の固定文にtest-pa4-roleが出る" "$out" "初回未配置" "test-pa4-role"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 22. PA-5: repo から定義を1本消して実行すると AGENTS: dangling の固定文に名前が出て終了コードが非0（symlink自体は消えない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  echo "# PA-5 用の一時ロール定義（次に削除する）" > "$TMP_REPO/team/rules/agents/test-pa5-role.md"

  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" >/dev/null 2>&1
  assert_true "前提: baseline実行でsymlinkができている" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa5-role.md" ]] && echo 1 || echo 0)"

  rm -f "$TMP_REPO/team/rules/agents/test-pa5-role.md"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?
  assert_true "終了コードが非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_agents_line "AGENTS: dangling の固定文にtest-pa5-roleが出る" "$out" "dangling" "test-pa5-role"
  assert_true "symlink自体は消えない（本人判断・削除しない方針）" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa5-role.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 23. PA-6: 追加もdanglingも無ければ AGENTS: 行が出ず終了コード0（既存の挙動が変わらない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" >/dev/null 2>&1

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "AGENTS: 行が一切出ない" \
    "$(echo "$out" | grep -q '^\[install-main\] AGENTS:' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 24. generate_settings_json()（意図的に毎回内容が変わる正規の再生成経路）は既存backupがあれば何度実行しても新規backupを量産しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  dest="$FAKE_HOME/.claude/settings.json"
  printf '{"pre-existing": true}' > "$dest"

  SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1
  assert_true "前提: settings.jsonの初回backupができる" \
    "$([[ -e "$dest.pre-aienv.bak" ]] && echo 1 || echo 0)"
  bak_content_before="$(<"$dest.pre-aienv.bak")"

  for _ in 1 2 3; do
    SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1
  done

  assert_eq "settings.jsonの.pre-aienv.bakは初回のまま変わらない" \
    "$bak_content_before" "$(<"$dest.pre-aienv.bak")"
  extra_count=0
  for f in "$dest".pre-aienv.bak.*; do
    [ -e "$f" ] && extra_count=$((extra_count + 1))
  done
  assert_eq "settings.jsonの追加backup(.pre-aienv.bak.<timestamp>)は1件も作られない" "0" "$extra_count"

  rm -rf "$FAKE_HOME"
}

echo "=== 25. 共有lib（core/assembly/managed-symlink.sh）を削ったfixtureでinstall-main.shが非0で終わる（lib欠落を静かに飲み込まない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  rm -f "$TMP_REPO/core/assembly/managed-symlink.sh"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 HOME="$FAKE_HOME" bash "$TMP_REPO/core/assembly/install-main.sh" 2>&1)" || rc=$?

  assert_true "共有lib欠落で非0終了し、明示的なFAILが出る" \
    "$([ "$rc" -ne 0 ] && echo "$out" | grep -q "共有ライブラリが読み取れません" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 26. 退役フラグ（旧 --print-* 系・対話式リーダー設定）は unknown option として非0・副作用ゼロ ==="
{
  FAKE_HOME="$(mktemp -d)"
  n_ok=0
  for flag in --print-bedrock-env-json --print-leader-model --reconfigure --non-interactive-mode; do
    rc=0
    HOME="$FAKE_HOME" bash "$SCRIPT" "$flag" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && n_ok=$((n_ok + 1))
  done
  assert_true "退役フラグはすべて非0で拒否され、偽HOMEに何も作られない" \
    "$([[ "$n_ok" -eq 4 && ! -e "$FAKE_HOME/.claude" && ! -e "$FAKE_HOME/.config" ]] && echo 1 || echo 0)"
  rm -rf "$FAKE_HOME"
}

# =============================================================================
# v1.2 束 C（台帳駆動の組立・選択）＝要件 v1.4 §7 FR-10〜FR-17・AC-8・AC-10・設計 v1.4 §3.1〜§3.3・
# 実装計画 §1 束 C（リーダー裁定録 leader-rulings-v1.2.md「束 C 着手ゲート」C4 の訂正を適用した実名）・§5。
# ここからは TOOL（台帳ツール）の `placement`・`--select`・`~/.config/takumi009-ai-env/components.env`
# （上書き AIENV_COMPONENTS_FILE）を使う。
# =============================================================================
TOOL="$REPO_ROOT/core/assembly/ledger-tool.sh"
COMPONENTS_REL=".config/takumi009-ai-env/components.env"

# placement_names <home> <--all|--select> [components_file] — 配置一覧（置き場）の basename 集合。
# （`placement` 未実装のうちは非 0／空出力＝下の全呼び出しが set -e で落ちないよう `|| true` で止める。）
placement_names() {
  local home="$1" mode="$2" flag=""
  local compfile="${3:-$home/$COMPONENTS_REL}"
  [ "$mode" = "--all" ] && flag="--all"
  { HOME="$home" AIENV_COMPONENTS_FILE="$compfile" bash "$TOOL" placement $flag 2>/dev/null \
    | awk -F'\t' '{print $2}' | xargs -n1 basename 2>/dev/null | sort -u; } || true
}
# live_names <home> — ライブ位置（hooks／agents／codex 配下）の名前集合。
live_names() {
  local home="$1"
  { { ls -1 "$home/.claude/hooks" 2>/dev/null; ls -1 "$home/.claude/agents" 2>/dev/null; ls -1 "$home/.codex" 2>/dev/null; } \
    | sort -u; } || true
}
# registered_names <home> — settings.json の全フックの command の basename 集合。
registered_names() {
  { jq -r '.hooks[][].hooks[].command' "$1/.claude/settings.json" 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -u; } || true
}
# run_select <home> [<--select 引数>] — install-main.sh を選択（省略で指定なし）で呼ぶ。終了コードは
# 落とさず $SELECT_RC へ（set -e 下でも、この関数自身は常に 0 を返す＝失敗ケースの試験でも落ちない）。
run_select() {
  local home="$1"; shift
  SELECT_RC=0
  SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 HOME="$home" bash "$SCRIPT" "$@" >"$home/.last-out" 2>&1 || SELECT_RC=$?
  SELECT_OUT="$(cat "$home/.last-out" 2>/dev/null || true)"
}

echo "=== 27. v1.2 AC-8 ①③: 選択 {ai-brain,core}（FX-13）＝ライブ位置・登録が選択の導出に一致し、選択外（team/usage/notify/dock）が0 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  rc=0; run_select "$FAKE_HOME" --select ai-brain,core || rc=$?
  assert_eq "FX-13: exit 0" "0" "$SELECT_RC"
  ALL_NAMES="$(placement_names "$FAKE_HOME" --all)"
  SEL_NAMES="$(placement_names "$FAKE_HOME" --select)"
  EXCLUDED="$(comm -23 <(printf '%s\n' "$ALL_NAMES") <(printf '%s\n' "$SEL_NAMES"))"
  assert_eq "FX-13 ①: ライブ位置の名前の集合＝placement（選択）の集合" "$SEL_NAMES" "$(live_names "$FAKE_HOME")"
  assert_eq "FX-13 ②: 選択外の名前がライブ位置に 0 件" "" "$(comm -12 <(printf '%s\n' "$EXCLUDED") <(live_names "$FAKE_HOME"))"
  assert_eq "FX-13 ②: 選択外の名前が settings.json 登録に 0 件" "" "$(comm -12 <(printf '%s\n' "$EXCLUDED") <(registered_names "$FAKE_HOME"))"
  REG_MISSING=0
  for n in $(registered_names "$FAKE_HOME"); do
    found=0
    for d in "$FAKE_HOME/.claude/hooks" "$FAKE_HOME/.claude/agents" "$FAKE_HOME/.codex"; do
      [ -e "$d/$n" ] && found=1
    done
    [ "$found" = "1" ] || REG_MISSING=$((REG_MISSING + 1))
  done
  assert_eq "FX-13 ③: 登録フックのコマンドが全て実在" "0" "$REG_MISSING"
  assert_eq "FX-13 ④: components.env の中身＝AIENV_COMPONENTS=ai-brain,core" \
    "AIENV_COMPONENTS=ai-brain,core" "$(cat "$FAKE_HOME/$COMPONENTS_REL" 2>/dev/null)"
  assert_true "FX-13: \$HOME/Library/LaunchAgents/ に本 repo の常駐の定義が無い" \
    "$([ ! -d "$FAKE_HOME/Library/LaunchAgents" ] && echo 1 || echo 0)"
  assert_true "FX-13: 出力に AI Brain の常駐の登録手順がある" "$(echo "$SELECT_OUT" | grep -qi 'install-backup\|install-maintenance' && echo 1 || echo 0)"
  BEFORE_NAMES="$(live_names "$FAKE_HOME")"
  rc=0; run_select "$FAKE_HOME" || rc=$?
  assert_eq "FX-13 ⑤: 指定なしの再実行後も exit 0" "0" "$SELECT_RC"
  assert_eq "FX-13 ⑤: 指定なしの再実行でも選択が保たれる（同じ集合）" "$BEFORE_NAMES" "$(live_names "$FAKE_HOME")"
  rm -rf "$FAKE_HOME"
}

echo "=== 28. v1.2 AC-8 ③: 選択 {Core}（FX-14）＝組立・配置の健全性検査・台帳の検査が全て exit 0・登録フックの実体が実在 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  rc=0; run_select "$FAKE_HOME" --select core || rc=$?
  assert_eq "FX-14: 組立 exit 0" "0" "$SELECT_RC"
  SEL_NAMES="$(placement_names "$FAKE_HOME" --select)"
  assert_eq "FX-14 ①: ライブ位置の名前の集合＝placement（{Core}）の集合" "$SEL_NAMES" "$(live_names "$FAKE_HOME")"
  rc=0; HOME="$FAKE_HOME" bash "$REPO_ROOT/core/assembly/check-drift.sh" --managed-symlinks-only >/dev/null 2>&1 || rc=$?
  assert_eq "FX-14: 配置の健全性検査 exit 0" "0" "$rc"
  rc=0; bash "$TOOL" check >/dev/null 2>"$FAKE_HOME/.ledger-check.err" || rc=$?
  assert_eq "FX-14: 台帳の検査 exit 0（選択に依らず本番 repo を見る）" "0" "$rc"
  assert_eq "FX-14 ④: components.env の中身＝AIENV_COMPONENTS=core" \
    "AIENV_COMPONENTS=core" "$(cat "$FAKE_HOME/$COMPONENTS_REL" 2>/dev/null)"
  rm -rf "$FAKE_HOME"
}

echo "=== 29. v1.2 AC-8: --select all を明示するとファイルが消える（全部入り⇔ファイル無しの単一表現） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  run_select "$FAKE_HOME" --select core
  assert_true "前提: core だけの選択で components.env ができる" "$([ -e "$FAKE_HOME/$COMPONENTS_REL" ] && echo 1 || echo 0)"
  rc=0; run_select "$FAKE_HOME" --select all || rc=$?
  assert_eq "--select all: exit 0" "0" "$SELECT_RC"
  assert_true "--select all: components.env が消える" "$([ ! -e "$FAKE_HOME/$COMPONENTS_REL" ] && echo 1 || echo 0)"
  ALL_NAMES="$(placement_names "$FAKE_HOME" --all)"
  assert_eq "--select all: ライブ位置の名前の集合＝全部入りの配置の集合" "$ALL_NAMES" "$(live_names "$FAKE_HOME")"
  rm -rf "$FAKE_HOME"
}

echo "=== 30. v1.2 AC-8 ⑤: FX-15 RESEL＝全部入りで配置済みの HOME に無関係のファイルを置いてから FX-13 の選択で再実行 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  run_select "$FAKE_HOME"
  printf '#!/bin/bash\n:\n' > "$FAKE_HOME/.claude/hooks/zz-unrelated.sh"
  chmod +x "$FAKE_HOME/.claude/hooks/zz-unrelated.sh"
  ALL_NAMES="$(placement_names "$FAKE_HOME" --all)"
  rc=0; run_select "$FAKE_HOME" --select ai-brain,core || rc=$?
  assert_eq "FX-15: exit 0" "0" "$SELECT_RC"
  SEL_NAMES="$(placement_names "$FAKE_HOME" --select)"
  EXCLUDED="$(comm -23 <(printf '%s\n' "$ALL_NAMES") <(printf '%s\n' "$SEL_NAMES"))"
  assert_eq "FX-15: 外した機能の名前がライブ位置に 0 件" "" "$(comm -12 <(printf '%s\n' "$EXCLUDED") <(live_names "$FAKE_HOME"))"
  assert_eq "FX-15: 外した機能の登録が 0 件" "" "$(comm -12 <(printf '%s\n' "$EXCLUDED") <(registered_names "$FAKE_HOME"))"
  assert_true "FX-15: 無関係のファイルは残る" "$([ -e "$FAKE_HOME/.claude/hooks/zz-unrelated.sh" ] && echo 1 || echo 0)"
  assert_true "FX-15: 出力に外した機能の常駐の解除手順がある" "$(echo "$SELECT_OUT" | grep -qi 'launchctl' && echo 1 || echo 0)"
  rm -rf "$FAKE_HOME"
}

echo "=== 31. v1.2 D-4/Q2: 常駐は手順を示すだけ（launchctl を実行しない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  LC_LOG="$FAKE_HOME/launchctl-calls.log"
  LC_STUB="$FAKE_HOME/stub"; mkdir -p "$LC_STUB"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$LC_LOG" > "$LC_STUB/launchctl"
  chmod +x "$LC_STUB/launchctl"
  rc=0
  SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 HOME="$FAKE_HOME" PATH="$LC_STUB:$PATH" bash "$SCRIPT" --select ai-brain,core >/dev/null 2>&1 || rc=$?
  assert_eq "exit 0" "0" "$rc"
  assert_true "偽 launchctl の呼び出し記録が 0 件（組立は launchctl を実行しない）" \
    "$([ ! -s "$LC_LOG" ] && echo 1 || echo 0)"
  rm -rf "$FAKE_HOME"
}

echo "=== 32. v1.2 AC-8 D-03: 選択の保存先が書込不可＝非0・ライブ位置と保存済みの旧い選択が不変・一時ファイルが残らない→権限を戻して再実行で FX-13 の集合へ収束 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  run_select "$FAKE_HOME" --select core
  assert_eq "前提: core だけで保存できている" "AIENV_COMPONENTS=core" "$(cat "$FAKE_HOME/$COMPONENTS_REL" 2>/dev/null)"
  BEFORE_NAMES="$(live_names "$FAKE_HOME")"
  BEFORE_SAVED="$(cat "$FAKE_HOME/$COMPONENTS_REL" 2>/dev/null || true)"
  COMP_DIR="$(dirname "$FAKE_HOME/$COMPONENTS_REL")"
  BEFORE_LISTING="$(ls -1a "$COMP_DIR" 2>/dev/null | sort || true)"
  chmod -w "$COMP_DIR"
  run_select "$FAKE_HOME" --select ai-brain,core
  assert_true "保存先が書込不可＝非0終了" "$([ "$SELECT_RC" != "0" ] && echo 1 || echo 0)"
  assert_eq "保存先が書込不可＝ライブ位置は不変" "$BEFORE_NAMES" "$(live_names "$FAKE_HOME")"
  assert_eq "保存先が書込不可＝保存済みの旧い選択は不変" "$BEFORE_SAVED" "$(cat "$FAKE_HOME/$COMPONENTS_REL" 2>/dev/null)"
  chmod +w "$COMP_DIR"
  AFTER_LISTING="$(ls -1a "$COMP_DIR" 2>/dev/null | sort || true)"
  chmod -w "$COMP_DIR"
  assert_eq "保存先が書込不可＝一時ファイルが残らない（フォルダの一覧が不変）" "$BEFORE_LISTING" "$AFTER_LISTING"
  chmod +w "$COMP_DIR"
  run_select "$FAKE_HOME" --select ai-brain,core
  assert_eq "権限を戻した同じコマンドの再実行＝exit 0" "0" "$SELECT_RC"
  SEL_NAMES="$(placement_names "$FAKE_HOME" --select)"
  assert_eq "権限を戻した再実行＝FX-13 の集合へ収束" "$SEL_NAMES" "$(live_names "$FAKE_HOME")"
  rm -rf "$FAKE_HOME"
}

echo "=== 33. v1.2 §3.1: 語彙外の選択＝何も変えずに非0・理由 1 行（静かに全部入りへ戻らない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  run_select "$FAKE_HOME" --select core
  BEFORE_NAMES="$(live_names "$FAKE_HOME")"
  rc=0; run_select "$FAKE_HOME" --select zz-not-a-function || rc=$?
  assert_true "語彙外の機能名＝非0" "$([ "$SELECT_RC" != "0" ] && echo 1 || echo 0)"
  assert_eq "語彙外の機能名＝理由が 1 行" "1" "$(echo "$SELECT_OUT" | grep -ci 'zz-not-a-function' || true)"
  assert_eq "語彙外の機能名＝ライブ位置は不変（全部入りへ静かに戻らない）" "$BEFORE_NAMES" "$(live_names "$FAKE_HOME")"
  rm -rf "$FAKE_HOME"
}

echo "=== 34. v1.2 §3.2: 掃除の退避＝gen・run の置き場は中身を消さず退避名へ・link は台帳の当該部品を指すときだけ消す ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  run_select "$FAKE_HOME" --select ai-brain,core,team,usage,notify,dock
  CODEX_TOML="$FAKE_HOME/.codex/config.toml"
  assert_true "前提: gen の置き場（config.toml）がある" "$([ -e "$CODEX_TOML" ] && echo 1 || echo 0)"
  CODEX_TOML_SUM_BEFORE="$(cksum "$CODEX_TOML" 2>/dev/null || true)"
  rc=0; run_select "$FAKE_HOME" --select ai-brain,core || rc=$?
  assert_eq "exit 0" "0" "$SELECT_RC"
  assert_true "gen の置き場は退避名で残る（中身は消えない）" \
    "$(ls "$CODEX_TOML".aienv-removed.bak* >/dev/null 2>&1 && echo 1 || echo 0)"
  assert_eq "退避した内容は選択外にする直前と同じ" "$CODEX_TOML_SUM_BEFORE" "$(cksum "$CODEX_TOML".aienv-removed.bak* 2>/dev/null | head -1)"
  OTHER_LINK="$FAKE_HOME/.claude/hooks/zz-other-target.sh"
  ln -s "/bin/echo" "$OTHER_LINK"
  rc=0; run_select "$FAKE_HOME" || rc=$?
  assert_true "台帳の部品を指さない別の symlink は触らない（1 行報告のうえ残る）" \
    "$([ -L "$OTHER_LINK" ] && [ "$(readlink "$OTHER_LINK")" = "/bin/echo" ] && echo 1 || echo 0)"
  rm -rf "$FAKE_HOME"
}

echo "=== 35. v1.2 FR-16: 失敗の注入（計画 §5）＝\$HOME/.codex を読取専用にして全部入りの組立→配置を1件以上変えた後・登録の前で非0 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  BEFORE_SETTINGS="$FAKE_HOME/.claude/settings.json"
  run_select "$FAKE_HOME"
  BEFORE_SUM="$(cksum "$BEFORE_SETTINGS" 2>/dev/null || true)"
  FAKE_HOME2="$(mktemp -d)"
  make_fake_home "$FAKE_HOME2"
  mkdir -p "$FAKE_HOME2/.codex"
  chmod -w "$FAKE_HOME2/.codex"
  rc=0; run_select "$FAKE_HOME2" || rc=$?
  assert_true "\$HOME/.codex 読取専用＝非0終了" "$([ "$SELECT_RC" != "0" ] && echo 1 || echo 0)"
  assert_true "配置を 1 件以上変えた後で止まる（.claude/hooks の一部は置かれている）" \
    "$([ -n "$(ls -A "$FAKE_HOME2/.claude/hooks" 2>/dev/null)" ] && echo 1 || echo 0)"
  REG_MISSING=0
  for n in $(registered_names "$FAKE_HOME2"); do
    found=0
    for d in "$FAKE_HOME2/.claude/hooks" "$FAKE_HOME2/.claude/agents" "$FAKE_HOME2/.codex"; do
      [ -e "$d/$n" ] && found=1
    done
    [ "$found" = "1" ] || REG_MISSING=$((REG_MISSING + 1))
  done
  assert_eq "登録フックのコマンドは全て実在（旧 settings のまま。登録は配置の後＝未配置の新規登録は無い）" "0" "$REG_MISSING"
  assert_true "報告に終わらなかった項目（仕方・置き場）がある" "$(echo "$SELECT_OUT" | grep -qE 'gen:|run:|\.codex' && echo 1 || echo 0)"
  assert_true "報告に再実行のコマンド（選択を明示した形）がある" "$(echo "$SELECT_OUT" | grep -q -- '--select' && echo 1 || echo 0)"
  chmod +w "$FAKE_HOME2/.codex"
  rc=0; run_select "$FAKE_HOME2" || rc=$?
  assert_eq "権限を戻した同じコマンドの再実行で完了＝exit 0" "0" "$SELECT_RC"
  ALL_NAMES="$(placement_names "$FAKE_HOME2" --all)"
  assert_eq "再実行後＝集合が全部入りの導出に等しい（FR-16）" "$ALL_NAMES" "$(live_names "$FAKE_HOME2")"
  rm -rf "$FAKE_HOME" "$FAKE_HOME2"
}

echo "=== 36. v1.2 束 C 着手ゲート C4: dotfiles の既定は DOTFILES_DIR 1 か所（新しい環境変数名を増やさない） ==="
{
  assert_eq "install-main.sh・check-drift.sh のどちらにも AIENV_DOTFILES_DIR という名前が無い" "0" \
    "$(grep -l 'AIENV_DOTFILES_DIR' "$SCRIPT" "$REPO_ROOT/core/assembly/check-drift.sh" 2>/dev/null | grep -c . || true)"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
