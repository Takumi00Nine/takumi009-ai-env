#!/usr/bin/env bash
# scripts/install-main.sh のユニットテスト（--print-modelモード・
# settings.json登録フックとinstaller配置の全件突合）。
#
# codex MCP登録まわり（setup-codex-mcp.shの呼び分け）は
# tests/test-install-main-codex-mcp.sh が担当するため、本ファイルでは扱わない。
#
# 実行方法: bash tests/test-install-main.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-main.sh"

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

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

echo "=== 1. --print-model はメイン既定値を1行印字してexit 0（副作用ゼロ） ==="
{
  FAKE_HOME="$(mktemp -d)"
  # .claude・.codex いずれも事前に作らない（未インストール環境を模す）。

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-model 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "出力はメイン既定値ちょうど1行" "claude-fable-5[1m]" "$out"
  assert_true "settings.json等は一切生成されない（副作用ゼロ）" \
    "$([[ ! -e "$FAKE_HOME/.claude" ]] && echo 1 || echo 0)"
  assert_true "machine-roleマーカーも書かれない" \
    "$([[ ! -e "$FAKE_HOME/.config/takumi009-ai-env/machine-role" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. --print-model --sub-delegate はサブ既定値を印字する（副作用ゼロ） ==="
{
  FAKE_HOME="$(mktemp -d)"

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-model --sub-delegate 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "出力はサブ既定値ちょうど1行" "claude-opus-5" "$out"
  assert_true "machine-roleマーカーは書かれない（委譲元install-sub.shが書く責務のため）" \
    "$([[ ! -e "$FAKE_HOME/.config/takumi009-ai-env/machine-role" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 3. --print-model は環境変数上書きにも従う（値出力口としての一本化を裏付ける） ==="
{
  FAKE_HOME="$(mktemp -d)"

  out_main="$(AIENV_MODEL_MAIN='custom-main-model' HOME="$FAKE_HOME" bash "$SCRIPT" --print-model)"
  out_sub="$(AIENV_MODEL_SUB='custom-sub-model' HOME="$FAKE_HOME" bash "$SCRIPT" --print-model --sub-delegate)"
  assert_eq "AIENV_MODEL_MAIN上書きが反映される" "custom-main-model" "$out_main"
  assert_eq "AIENV_MODEL_SUB上書きが反映される" "custom-sub-model" "$out_sub"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. --print-model は python3 が無くても動く（生成処理より前に判定するため） ==="
{
  FAKE_HOME="$(mktemp -d)"
  EMPTY_BINDIR="$(mktemp -d)"
  # /usr/bin 等は残しつつ python3 だけ見えないようにする（実PATH汚染回避のため
  # 存在しないダミーディレクトリを先頭に置くだけでは他所のpython3が拾われる
  # 環境があるため、シェル組込・coreutilsに必要な最小限＋PATHを絞る）。
  rc=0
  out="$(PATH="$EMPTY_BINDIR:/usr/bin:/bin" HOME="$FAKE_HOME" bash "$SCRIPT" --print-model 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "python3依存チェックより前に印字して終了する" "claude-fable-5[1m]" "$out"

  rm -rf "$FAKE_HOME" "$EMPTY_BINDIR"
}

echo "=== 5. settings.jsonに登録済みの全フックがinstall-main.shでも配置される（installer漏れの再発防止・§9.0 A-0-2） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  # claude/settings.json の "command" フィールドから $HOME/.claude/hooks/*.sh の
  # パス一覧を抽出する（bash-danger-gate.sh のような他フックのcommand文字列内に
  # 埋め込まれた別コマンド呼び出しは対象外＝フック本体の起動コマンドのみ）。
  # bash 3.2（macOS既定）互換のため mapfile/readarray は使わない。
  hook_paths=()
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    hook_paths+=("$name")
  done < <(grep -o '"command": "\$HOME/\.claude/hooks/[a-zA-Z0-9_-]*\.sh"' "$REPO_ROOT/claude/settings.json" \
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

  assert_true "context-size-warn.sh が配置されている（§9.0 A-0-2で修理した具体の漏れ）" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/context-size-warn.sh" ]] && echo 1 || echo 0)"
  assert_eq "context-size-warn.sh のsymlink先はrepo" "$REPO_ROOT/claude/hooks/context-size-warn.sh" \
    "$(readlink "$FAKE_HOME/.claude/hooks/context-size-warn.sh")"
  assert_true "context-size-warn.sh に実行権限が付与されている" \
    "$([[ -x "$REPO_ROOT/claude/hooks/context-size-warn.sh" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

# vault-public/Preferences/profile-sample.md は本来の配置経路が
# Vault(Preferences/profile-sample.md)→export-public-vault.sh→vault-public/ の
# 正規パイプライン（vault-scribe工程）であり、このテストファイル（実装ワーカー）
# からVault管理下のファイルへ直接置くべきではない。そのためテスト6・7・9は
# 実repoを一時コピーし、そのコピーの中にだけfixtureサンプルを追加してから
# install-main.shを実行する（本物のvault-public/を一切変更しない）。
make_repo_with_profile_sample_fixture() {
  local tmp_repo="$1"
  cp -R "$REPO_ROOT/." "$tmp_repo/"
  mkdir -p "$tmp_repo/vault-public/Preferences"
  # 2026-08-30 工程横断レビュー指摘・BLOCKING対応: 実サンプル
  # （vault-public/Preferences/profile-sample.md）はObsidianノート形式であり、
  # 先頭frontmatterはノートのメタデータ（date/tags/…）で、最小能力表7キーは
  # 本文中の```yamlフェンスコードブロックの中にある。以前のfixtureは
  # 「先頭frontmatterがそのまま7キー」という誤った形（実物と乖離した形）を
  # 使っており、installer/resolverの入力形式不整合を結合テストが隠して
  # しまっていた。ここでは実物と同じ「ノートmetadata＋本文＋```yamlフェンス」
  # 構造を再現する。
  # ⚠️ 2026-08-30本人裁定「profile-sampleの初期値はメイン機の実値に戻す」に
  # 合わせ、このfixtureもsentinel(`<fill-in>`)ではなく実値で7キーを埋めた
  # （実サンプルの初期値方針の変更に追随。fixtureの目的自体は「コピー機構が
  # ノートmetadataを取り違えない」ことの確認であり、値そのものは何でもよい）。
  cat > "$tmp_repo/vault-public/Preferences/profile-sample.md" <<'EOF'
---
date: 2026-08-30
tags: [preference, core, profile, sample]
project: takumi009-ai-env
---
# プロファイルサンプル（fixture・テスト専用）

このノート自体のfrontmatter（上）は最小能力表7キーではない。7キーは下の
```yamlフェンス内にある（実物のvault-public/Preferences/profile-sample.mdと
同じ構造の再現）。

```yaml
---
inventory_source: Vault(Preferences/Knowledge直下)
reviewer: configured(Codex一次レビュー)
vault_write: configured(vault-scribe)
vault_scope: Vault全体(Data/obsidian配下)
ui.user_call: configured(SendMessage to: main)
git_role: push可(takumi009-ai-env repo限定)
web_verification: configured(WebSearch/WebFetch)
---
```
EOF
}

echo "=== 6. ローカル実体プロファイルの雛形配置: サンプルがあり実体が無ければコピーする（P1機構・§9.0 A-1） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  make_repo_with_profile_sample_fixture "$TMP_REPO"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" >/dev/null 2>&1

  assert_true "profile.mdが作成される" \
    "$([[ -f "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"
  assert_true "symlinkではなく実ファイルとしてコピーされる（雛形は独立した実体）" \
    "$([[ ! -L "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"
  # 2026-08-30 BLOCKING対応: コピーはノート全体の複製ではなく、```yaml
  # フェンス内の最小能力表ブロックだけを抽出したものになる。ノート本体の
  # frontmatter（date/tags等）は含まれず、7キーのYAML frontmatterだけが
  # そのまま実体になっていることを確認する。
  assert_true "実体はノートmetadata(date:)を含まない" \
    "$(grep -q '^date:' "$FAKE_HOME/.config/takumi009-ai-env/profile.md" && echo 0 || echo 1)"
  assert_true "実体は最小能力表7キーを含む" \
    "$(grep -q '^vault_scope: Vault全体(Data/obsidian配下)$' "$FAKE_HOME/.config/takumi009-ai-env/profile.md" && echo 1 || echo 0)"
  assert_true "実体は正しいYAML frontmatter形式（先頭行が---）" \
    "$([[ "$(head -1 "$FAKE_HOME/.config/takumi009-ai-env/profile.md")" == "---" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 7. ローカル実体プロファイルの雛形配置: 非破壊性（既存が通常ファイル/ディレクトリ/symlink/broken symlinkのいずれでも上書きしない） ==="
{
  TMP_REPO="$(mktemp -d)"
  make_repo_with_profile_sample_fixture "$TMP_REPO"

  for kind in file dir symlink broken_symlink; do
    FAKE_HOME="$(mktemp -d)"
    make_fake_home "$FAKE_HOME"
    mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
    PROFILE_DEST="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
    case "$kind" in
      file) echo "既存の実体（変更不可）" > "$PROFILE_DEST" ;;
      dir) mkdir -p "$PROFILE_DEST" ;;
      symlink)
        ELSEWHERE="$(mktemp -d)/target.md"
        mkdir -p "$(dirname "$ELSEWHERE")"
        echo "symlink先の中身" > "$ELSEWHERE"
        ln -s "$ELSEWHERE" "$PROFILE_DEST"
        ;;
      broken_symlink) ln -s "/nonexistent-target-$$.md" "$PROFILE_DEST" ;;
    esac
    before_kind_is_symlink=0
    [[ -L "$PROFILE_DEST" ]] && before_kind_is_symlink=1
    before_readlink="$( [[ -L "$PROFILE_DEST" ]] && readlink "$PROFILE_DEST" || echo "" )"

    out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)"

    assert_true "[$kind] 既存が壊れずに残る（上書きされない）" \
      "$([[ -e "$PROFILE_DEST" || -L "$PROFILE_DEST" ]] && echo 1 || echo 0)"
    if [[ "$before_kind_is_symlink" = "1" ]]; then
      assert_eq "[$kind] symlinkの指向先は不変" "$before_readlink" "$(readlink "$PROFILE_DEST" 2>/dev/null || echo "")"
    fi
    assert_true "[$kind] 上書きskipのWARNが出る" \
      "$(echo "$out" | grep -q 'ローカル実体プロファイルは既に存在するため雛形コピーをskipしました' && echo 1 || echo 0)"

    rm -rf "$FAKE_HOME"
  done

  rm -rf "$TMP_REPO"
}

echo "=== 8. ローカル実体プロファイルの雛形配置: サンプルが無ければWARNのみでinstaller全体は落とさない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  rm -f "$TMP_REPO/vault-public/Preferences/profile-sample.md"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "exit code 0（サンプル未整備でも致命的にしない）" "0" "$rc"
  assert_true "サンプル未整備のWARNが出る" \
    "$(echo "$out" | grep -q 'profile-sample.md が見つかりません' && echo 1 || echo 0)"
  assert_true "profile.mdは作成されない" \
    "$([[ ! -e "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 9. ローカル実体プロファイルの雛形配置: --dry-run では一切変更しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  TMP_REPO="$(mktemp -d)"
  make_repo_with_profile_sample_fixture "$TMP_REPO"

  out="$(HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" --dry-run 2>&1)"
  assert_true "would extractの計画表示が出る" \
    "$(echo "$out" | grep -q 'would extract profile schema block and write:.*profile-sample.md' && echo 1 || echo 0)"
  assert_true "実際にはprofile.mdは作られない" \
    "$([[ ! -e "$FAKE_HOME/.config/takumi009-ai-env/profile.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 10. Bedrock最小セット: envファイルの値がsettings.jsonのenvブロックへ取り込まれる（§9.0 A-1-4） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
# コメント行
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8

EOF
  chmod 644 "$ENV_FILE"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  assert_true "CLAUDE_CODE_USE_BEDROCKがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "AWS_REGIONがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('AWS_REGION')=='us-east-1' else 1)" && echo 1 || echo 0)"
  assert_true "ANTHROPIC_DEFAULT_OPUS_MODELがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('ANTHROPIC_DEFAULT_OPUS_MODEL')=='us.anthropic.claude-opus-4-8' else 1)" && echo 1 || echo 0)"
  assert_true "テンプレ由来のDISABLE_AUTOUPDATERは残る" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('DISABLE_AUTOUPDATER')=='1' else 1)" && echo 1 || echo 0)"
  perm="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  assert_eq "envファイルのパーミッションが0600へ揃えられる" "600" "$perm"

  rm -rf "$FAKE_HOME"
}

echo "=== 11. Bedrock最小セット: 許可リスト外のキー（AWS認証情報等を想定）は取り込まずWARNする（Codex一次レビュー指摘・Major対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
DISABLE_AUTOUPDATER=0
AWS_ACCESS_KEY_ID=AKIAEXAMPLE
EOF

  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

  assert_true "テンプレ値(1)が保持される（envファイルの0では上書きされない）" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('DISABLE_AUTOUPDATER')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "許可リスト外キーのWARNが出る" \
    "$(echo "$out" | grep -q '許可リスト外のキーがあったため取り込みませんでした' && echo 1 || echo 0)"
  assert_true "AWS_ACCESS_KEY_IDはsettings.jsonへ一切取り込まれない（絶対厳守③）" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if 'AWS_ACCESS_KEY_ID' not in d.get('env',{}) else 1)" && echo 1 || echo 0)"
  assert_true "AWS_ACCESS_KEY_IDの値そのものはログにも出ない（キー名のみ許容）" \
    "$(echo "$out" | grep -q 'AKIAEXAMPLE' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 11b. Bedrock最小セット: 許可リスト内キーがテンプレ側envと衝突する場合はスキップしテンプレ値を保持する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  # テンプレのenvブロックに許可リスト内キー(AWS_REGION)をあらかじめ持たせて
  # 衝突を再現する（実際のテンプレには現状無いが、将来追加された場合の回帰用）。
  python3 -c "
import json
p = '$TMP_REPO/claude/settings.json'
d = json.load(open(p))
d['env']['AWS_REGION'] = 'ap-northeast-1'
json.dump(d, open(p, 'w'), indent=2)
"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
AWS_REGION=us-east-1
EOF

  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)"

  assert_true "テンプレ値(ap-northeast-1)が保持される（envファイルの値では上書きされない）" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('AWS_REGION')=='ap-northeast-1' else 1)" && echo 1 || echo 0)"
  assert_true "衝突キーのWARNが出る" \
    "$(echo "$out" | grep -q 'テンプレ側envと衝突したためスキップしました' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 11c. Bedrock最小セット: パーミッションを0600へ矯正できない場合はsettings.json本体の生成ごと中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR対応: 従来は取り込みだけskipしsettings.json本体は生成・上書きしていたため、既存設定にあったCLAUDE_CODE_USE_BEDROCK等が消え得た。設計書§11.2「生成失敗時は旧ファイルを触らない」契約どおりに修正。2026-08-30 リーダー追補: tester独立検証がbedrock.envを644＋chflags uchgで矯正恒久失敗させ、install-main.sh/update-sub.sh双方でCLAUDE_CODE_USE_BEDROCK・AWS_REGIONが黙って消えることを別経路で実再現済み＝本テストはその再現シナリオそのもの） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # 「既存のsettings.json」を模した番兵コンテンツを事前に置く（生成が中止され
  # 既存ファイルが一切触られないことを、単なる不在ではなく内容不変で検証する）。
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1"
  }
}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
EOF
  # tester再現シナリオ通り644を明示する（2026-08-30 Codex五次レビュー指摘・
  # Minor対応: umaskによっては`cat >`だけで既に600相当になり、パーミッション
  # 矯正の「失敗」自体が発生しないシナリオになりうるため、umaskに依存させない）。
  chmod 0644 "$ENV_FILE"
  # macOSのuser immutableフラグでchmodを失敗させる（chflagsが無い環境ではskip）。
  if command -v chflags >/dev/null 2>&1 && chflags uchg "$ENV_FILE" 2>/dev/null; then
    rc=0
    out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
    chflags nouchg "$ENV_FILE" 2>/dev/null || true

    assert_eq "settings.json生成が中止されてもinstall-main.sh全体はexit 0で完走する(set -eで全体を落とさない)" "0" "$rc"
    assert_true "パーミッション矯正失敗のWARNが出る" \
      "$(echo "$out" | grep -q 'パーミッションを0600へ揃えられませんでした' && echo 1 || echo 0)"
    assert_true "生成中止・既存ファイル保持のWARNが出る" \
      "$(echo "$out" | grep -q '既存ファイルを保持します' && echo 1 || echo 0)"
    POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
    assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
    # SHA-256不変は全内容の不変を含意するが、tester独立検証と同じ観点
    # （CLAUDE_CODE_USE_BEDROCK・AWS_REGIONが個別に消えていないか）も
    # 明示的に直接確認する。
    assert_true "CLAUDE_CODE_USE_BEDROCKが消えていない(tester独立検証と同一観点)" \
      "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
    assert_true "AWS_REGIONが消えていない(tester独立検証と同一観点)" \
      "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('env',{}).get('AWS_REGION')=='us-east-1' else 1)" && echo 1 || echo 0)"
    assert_true "settings.json以外の処理(hooksのsymlink化)は正常に続行している" \
      "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
    assert_true "中止のみで.pre-aienv.bakは新規作成されない(Codex四次レビュー指摘・Minor対応)" \
      "$([[ ! -e "$FAKE_HOME/.claude/settings.json.pre-aienv.bak" ]] && echo 1 || echo 0)"
    assert_eq "中止のみで一時ファイル(.settings.json.aienv-tmp.*)も残らない" "0" \
      "$(find "$FAKE_HOME/.claude" -maxdepth 1 -name '.settings.json.aienv-tmp.*' | wc -l | tr -d ' ')"
  else
    pass "chflagsが使えない環境のためskip（このマシンでは未検証）"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 11c2. Bedrock最小セット: Bedrock envパスがディレクトリの場合もsettings.json本体の生成を中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR対応: 従来は'-f'テストが無警告のまま偽になり、そのまま空設定で生成・上書きしていた） ==="
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
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  # Bedrock envのパスをディレクトリにする（'-f'テストが偽になるケース）。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?

  assert_eq "settings.json生成が中止されてもinstall-main.sh全体はexit 0で完走する" "0" "$rc"
  assert_true "ディレクトリである旨のWARNが出る（無警告のまま素通りしない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
  assert_true "中止のみで.pre-aienv.bakは新規作成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json.pre-aienv.bak" ]] && echo 1 || echo 0)"
  assert_eq "中止のみで一時ファイルも残らない" "0" \
    "$(find "$FAKE_HOME/.claude" -maxdepth 1 -name '.settings.json.aienv-tmp.*' | wc -l | tr -d ' ')"

  rm -rf "$FAKE_HOME"
}

echo "=== 11c1b. Bedrock最小セット: --dry-run の計画表示は実実行の判定と一致する（Bedrock envがディレクトリなら'would back up'を表示しない。2026-08-30 Codex五次レビュー指摘・Minor対応: 従来はUNAVAILABLE判定より前に無条件でwould-back-upを表示しており、実実行では作られない.pre-aienv.bakの計画が混在していた） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run 2>&1)"

  assert_true "settings.json生成中止見込みのログが出る" \
    "$(echo "$out" | grep -q '生成は中止され既存ファイルが保持される見込みです' && echo 1 || echo 0)"
  assert_true "実際には作られないwould-back-upは表示されない" \
    "$(echo "$out" | grep -q 'would back up.*settings.json' && echo 0 || echo 1)"
  assert_true "would generate/would merge も表示されない（生成自体が中止見込みのため）" \
    "$(echo "$out" | grep -qE 'would generate.*settings\.json|would merge env' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 11c2b. Bedrock最小セット: Bedrock envパスがdangling symlink(実体が既に無いsymlink)の場合もsettings.json本体の生成を中止し既存ファイルを保持する（2026-08-30 Codex四次レビュー指摘・MAJOR対応: 従来は'[ -e ]'だけの判定だとdangling symlinkが「存在しない＝ABSENT」に丸められ、無警告のまま空設定で生成・上書きしていた） ==="
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
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  # 実体を作ってからsymlinkを張り、実体だけ削除してdangling symlinkにする。
  DANGLING_TARGET="$FAKE_HOME/.config/takumi009-ai-env/bedrock-target.env"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$DANGLING_TARGET"
  ln -s "$DANGLING_TARGET" "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  rm -f "$DANGLING_TARGET"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?

  assert_eq "settings.json生成が中止されてもinstall-main.sh全体はexit 0で完走する" "0" "$rc"
  assert_true "dangling symlinkである旨のWARNが出る（ABSENT扱いで無警告のまま素通りしない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$FAKE_HOME"
}

echo "=== 11c3. Bedrock最小セット: Bedrock envファイルの解析（読取）自体が失敗する場合もsettings.json本体の生成を中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR対応: 従来はcompute_bedrock_env_json()の失敗を空payloadへ丸めてそのまま生成・上書きしていた） ==="
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
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  # 不正なUTF-8バイト列にする（compute_bedrock_env_json()内のpython3 open()が
  # UnicodeDecodeErrorで非0終了することを実測で確認済み。パーミッション自体は
  # 正しく0600へ矯正できる＝11cとは異なる失敗経路を狙い撃ちする）。
  printf '\xff\xfe\x00\x01invalid-utf8-\xfe' > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?

  assert_eq "settings.json生成が中止されてもinstall-main.sh全体はexit 0で完走する" "0" "$rc"
  assert_true "解析失敗のWARNが出る" \
    "$(echo "$out" | grep -q 'Bedrock envファイルの解析に失敗しました' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
  assert_true "中止のみで.pre-aienv.bakは新規作成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json.pre-aienv.bak" ]] && echo 1 || echo 0)"
  assert_eq "中止のみで一時ファイルも残らない" "0" \
    "$(find "$FAKE_HOME/.claude" -maxdepth 1 -name '.settings.json.aienv-tmp.*' | wc -l | tr -d ' ')"

  rm -rf "$FAKE_HOME"
}

echo "=== 11c3b. Bedrock最小セット: 親ディレクトリの探索権限不足(EACCES)で存在確認自体ができない場合もsettings.json本体の生成を中止し既存ファイルを保持する（2026-08-30 Codex五次レビュー指摘・Minor対応: bedrock_env_file_kind()のFileNotFoundError以外のOSError→UNAVAILABLE経路をchmod 000で直接踏む。dangling symlinkとは異なる経路） ==="
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
  # machine-roleマーカー用ディレクトリ($FAKE_HOME/.config/takumi009-ai-env)
  # とは別のディレクトリにBedrock envを置き、そのディレクトリだけ探索権限を
  # 剥奪する（同じディレクトリを巻き込むとmarker書込自体がset -eで落ちて
  # 本題のBedrock経路を検証できなくなるため分離する）。
  LOCKED_DIR="$FAKE_HOME/.config/bedrock-locked"
  mkdir -p "$LOCKED_DIR"
  echo "CLAUDE_CODE_USE_BEDROCK=1" > "$LOCKED_DIR/bedrock.env"
  chmod 000 "$LOCKED_DIR"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" AIENV_BEDROCK_ENV_FILE="$LOCKED_DIR/bedrock.env" bash "$SCRIPT" 2>&1)" || rc=$?
  chmod 700 "$LOCKED_DIR"

  assert_eq "settings.json生成が中止されてもinstall-main.sh全体はexit 0で完走する" "0" "$rc"
  assert_true "通常ファイルではない旨のWARNが出る（探索権限不足もABSENT扱いにされない）" \
    "$(echo "$out" | grep -q '通常ファイルではありません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"

  rm -rf "$FAKE_HOME"
}

echo "=== 11d. Bedrock最小セット: 解析できない行は行番号付きでWARNし、値は出さない（Codex二次レビュー指摘・Minor対応: update-sub.sh側だけでなくinstall-main.sh側でも直接検証する） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
THIS_LINE_HAS_NO_EQUALS_SIGN_AND_MIGHT_LEAK_A_TOKEN_abcdef123456
=empty-key-value
EOF

  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

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

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  assert_true "envブロックはテンプレどおりDISABLE_AUTOUPDATERのみ" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if list(d['env'].keys())==['DISABLE_AUTOUPDATER'] else 1)" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 13. 結合: installerがコピーした雛形をそのままbootstrap-vault.shへ渡すと、実サンプルの7キーが正しく抽出される（BLOCKING対応。値の内容には依存しない＝2026-08-30本人裁定でサンプルの初期値がsentinel/unknownから実値へ変わったため、T2-MINIMAL固定ではなくキー抽出の正しさだけを検証する） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  # ⚠️ ここだけは合成fixtureを使わず、追跡中の実サンプル
  # （$REPO_ROOT/vault-public/Preferences/profile-sample.md）を直接入力にする
  # （工程横断レビュー指摘: 従来はfixtureが「先頭frontmatter=7キー」という
  # 実物と違う形を使っており、installer/resolverの入力形式不整合を隠していた）。
  # ⚠️ アサーションはサンプルの「値の中身」（sentinelか実値か）に依存しない
  # 形にしている——本人裁定でサンプルの初期値が変わりうる（現に一度、
  # sentinel方式から実値方式へ変わった）ため、値の中身ではなく「7キーが
  # ノートmetadataと取り違えられずに正しく抽出されているか」（BLOCKING対応の
  # 本質）だけを固定的に検証する。
  if [ ! -f "$REPO_ROOT/vault-public/Preferences/profile-sample.md" ]; then
    fail_case "前提: 実サンプル(vault-public/Preferences/profile-sample.md)が見つからない"
  else
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install-main.sh" >/dev/null 2>&1
    PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
    VAULT_FIXTURE="$(mktemp -d)"

    ctx="$(echo '{"session_id":"test-session-e2e"}' \
      | BOOTSTRAP_VAULT="$VAULT_FIXTURE" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
        VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
        VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
        PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
        MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
        AIENV_MACHINE_ROLE_MARKER="/nonexistent-dir/machine-role" \
        BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 AIENV_LOCAL_PROFILE_PATH="$PROFILE_PATH" \
        bash "$REPO_ROOT/claude/hooks/bootstrap-vault.sh" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])")"

    missing_keys=0
    for k in inventory_source reviewer vault_write vault_scope ui.user_call git_role web_verification; do
      if ! grep -q "^${k}:" "$PROFILE_PATH"; then
        fail_case "実サンプルから最小能力表7キーの1つ(${k})がノートmetadataと取り違えられ抽出できていない"
        missing_keys=$((missing_keys + 1))
      fi
    done
    if [ "$missing_keys" -eq 0 ]; then
      pass "実サンプルからノートmetadataではなく最小能力表7キー全てが正しく抽出されている（T5にならない）"
    fi
    assert_true "T5(既存キー欠落)にはならない（BLOCKING対応の直接確認・値の中身に依存しない）" \
      "$(echo "$ctx" | grep -q 'T5' && echo 0 || echo 1)"
    assert_true "T6(YAML破損)にもならない（抽出したブロックが正しいYAML frontmatterであることの確認）" \
      "$(echo "$ctx" | grep -q 'T6' && echo 0 || echo 1)"

    rm -rf "$VAULT_FIXTURE"
  fi

  rm -rf "$FAKE_HOME"
}

echo "=== 14. --print-bedrock-env-json: 許可リスト内キーだけをJSONで印字する（副作用ゼロ・check-drift.shの値出力口＝2026-08-30 工程横断レビュー指摘・MAJOR-5対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=should-not-appear
EOF

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-bedrock-env-json)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  # 2026-08-30 工程横断レビュー指摘・MAJOR-A対応: 出力形式が構造化された
  # {"env": {...}, "rejected_keys": [...], "malformed_lines": [...]} へ変更
  # された（rejected_keys/malformed_linesを呼び出し側〈generate_settings_json・
  # update-sub.sh〉へ伝えるため。値表・解析ロジックの完全な一本化の一環）。
  assert_true "CLAUDE_CODE_USE_BEDROCKがenv配下に含まれる" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "AWS_REGIONがenv配下に含まれる" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d['env'].get('AWS_REGION')=='us-east-1' else 1)" && echo 1 || echo 0)"
  assert_true "許可リスト外のAWS_ACCESS_KEY_IDはenv配下に含まれない（絶対厳守③）" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'AWS_ACCESS_KEY_ID' not in d['env'] else 1)" && echo 1 || echo 0)"
  assert_true "AWS_ACCESS_KEY_IDはrejected_keysへキー名だけ載る（値は載らない）" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'AWS_ACCESS_KEY_ID' in d['rejected_keys'] else 1)" && echo 1 || echo 0)"
  assert_true "設定ファイル等は一切生成されない（副作用ゼロ）" \
    "$([[ ! -e "$FAKE_HOME/.claude" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 15. --print-bedrock-env-json: envファイルが無ければ空のenv/rejected_keys/malformed_linesを返す ==="
{
  FAKE_HOME="$(mktemp -d)"

  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-bedrock-env-json)"
  assert_eq "空の構造化オブジェクトが返る" '{"env": {}, "rejected_keys": [], "malformed_lines": []}' "$out"

  rm -rf "$FAKE_HOME"
}

echo "=== 15b. ローカル実体プロファイルの雛形配置: 抽出失敗時のWARNに実際のエラー詳細が含まれる（Codex二次レビュー指摘・Minor対応: 従来はstdout/stderr両方をファイルへ吸い込んでいて詳細が常に空だった） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  mkdir -p "$TMP_REPO/vault-public/Preferences"
  echo "no yaml fence in this fixture" > "$TMP_REPO/vault-public/Preferences/profile-sample.md"

  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)"

  assert_true "抽出失敗のWARNが出る" \
    "$(echo "$out" | grep -q '抽出できませんでした' && echo 1 || echo 0)"
  assert_true "詳細（フェンスが見つからない旨）がWARNに含まれる（従来は空だった）" \
    "$(echo "$out" | grep -q '詳細:.*が見つかりません' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 16. --print-bedrock-env-json: envファイルが存在するのに読めない場合はfail-openで{}を返さず非0終了する（Codex二次レビュー指摘・Major対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  # bedrock.envをディレクトリとして作る（Codex三次レビュー指摘・Minor対応:
  # chmod 000はroot実行環境では読めてしまい未検証になりうるが、
  # open()がディレクトリに対して常にIsADirectoryErrorで失敗するのは
  # 実行uidに依存しない決定的な失敗経路のため、こちらを使う）。
  mkdir -p "$ENV_FILE"

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-bedrock-env-json 2>/dev/null)" || rc=$?
  assert_eq "読取失敗時は非0終了する" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "失敗時は{}を出力しない（fail-openで偽装しない）" \
    "$([[ -z "$out" || "$out" != "{}" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
