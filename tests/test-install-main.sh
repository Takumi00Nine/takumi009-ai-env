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

# 2026-09-01 配役表解凍（設計書§3.9）: v2雛形はrole.leaderがunknownのまま
# 配布されるため、リーダー配役が未確定の状態でinstall-main.shを（対話・
# --non-interactiveいずれも指定せず）実行すると、対話可否の判定に落ちる
# （TTY接続時は対話に入り本ファイルのテスト用の入力を待ってしまい、非TTY
# 実行環境ではLEADER_UNCONFIGURED_NONINTERACTIVEでexit非0になる）。
# §3.9対話そのもの・AIENV_LEADER_ROLEの詳細を検証しないテスト（多くの既存
# テスト）は、この既定値をexportしておくことで「未確定→envの値を検査して
# 採用（質問しない）」経路を常に通り、決定的にsettings.json生成まで進む。
# §3.9固有のテストブロックでは、必要に応じてunset/上書きする。
export AIENV_LEADER_ROLE='provider=anthropic-api model=claude-sonnet-5'

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

echo "=== 5b. 通知系アプリ管理キー2つ（agentPushNotifEnabled/inputNeededNotifEnabled）がテンプレ収載により生成settings.jsonにも含まれる（2026-09-02 本人決定。従来はテンプレ未収載のため再生成のたびにアプリ側の追記が脱落しうる状態だった） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  assert_eq "生成settings.jsonのagentPushNotifEnabledはtrue" "True" \
    "$(python3 -c "import json; print(json.load(open('$FAKE_HOME/.claude/settings.json'))['agentPushNotifEnabled'])")"
  assert_eq "生成settings.jsonのinputNeededNotifEnabledはtrue" "True" \
    "$(python3 -c "import json; print(json.load(open('$FAKE_HOME/.claude/settings.json'))['inputNeededNotifEnabled'])")"

  rm -rf "$FAKE_HOME"
}

echo "=== 5c. profile.md（実体プロファイル）へのRead allowルールがテンプレ収載により生成settings.jsonにも含まれる（2026-09-02 SessionStartフックの必読リストにprofile.mdが載ったがadditionalDirectoriesは~/.configを含まないため個別allowが必要。Read tool allow rule は working directory 外でも単一ファイル指定で機能する＝https://code.claude.com/docs/en/permissions の Read(~/.zshrc) 例で確認済み） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1

  assert_true "生成settings.jsonのpermissions.allowにprofile.md用Read allowルールが含まれる" \
    "$(python3 -c "import json; d=json.load(open('$FAKE_HOME/.claude/settings.json')); exit(0 if 'Read(~/.config/takumi009-ai-env/profile.md)' in d['permissions']['allow'] else 1)" && echo 1 || echo 0)"

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

  # このfixtureはv1形式（schema_version・role.*行を持たない7キーのみ）。
  # 2026-09-01 配役表解凍§3.9「v1と分類されたら対話しない（AIENV_LEADER_ROLE
  # 指定時も非0終了）」に該当するため、本ファイル冒頭のexportを打ち消す
  # （このテストの主眼＝雛形コピーの正しさとは無関係な理由でinstallerを
  # 失敗させないため）。
  env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" >/dev/null 2>&1

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

    # fileとdirは既存実体がv1相当（schema_version・role.*行を持たない）に
    # 分類されるため、AIENV_LEADER_ROLEを指定したまま実行すると
    # 「v1と分類されたら対話しない」規則で非0終了してしまう
    # （symlink/broken_symlinkはsymlink判定で早期returnするため元々無関係）。
    # 本テストの主眼＝非破壊性の検証とは無関係なので打ち消しておく。
    # 2026-09-01 配役表解凍: dir/symlink/broken_symlinkのkindは、既存の
    # profile.mdが「通常ファイルとして読めない」状態そのものであり、
    # resolve_leader_runtime()がPROFILE_UNREADABLEとして正しく非0終了する
    # ようになった（S2「プロファイル解決不能→生成しない・既存があれば保持・
    # 非0終了」）。fileのみ内容がv1相当に分類され legacy 委譲で成功する。
    # `|| true`でrcを捕まえ、`set -e`で全体を落とさないようにする。
    rc=0
    out="$(env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?

    case "$kind" in
      file) assert_eq "[$kind] v1相当としてlegacy委譲されexit 0で完走する" "0" "$rc" ;;
      *) assert_true "[$kind] profile.mdが読めない状態のためexit非0で中止する（既存settings.json等は保持）" \
           "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)" ;;
    esac
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

# write_v2_profile_with_bedrock_role <dest> <alias> — role.researcherを
# provider=bedrock model=<alias>で配役したv2プロファイルを書く（§4.2-d動的
# Bedrock許可キーのテスト用フィクスチャ）。role.leaderはグローバルexportの
# AIENV_LEADER_ROLE（provider=anthropic-api model=claude-sonnet-5）と一致する
# 値をあらかじめconfigured済みにしておき、対話に入らず冪等に通す。
write_v2_profile_with_bedrock_role() {
  local dest="$1" alias="$2"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
---
schema_version: 2
profile_slug: test
role.leader: configured provider=anthropic-api model=claude-sonnet-5
role.researcher: configured provider=bedrock model=${alias}
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF
}

echo "=== 10. Bedrock最小セット: envファイルの値がsettings.jsonのenvブロックへ取り込まれる（§9.0 A-1-4・2026-09-01 §4.2-d動的許可キー） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  # 2026-09-01 §4.2-d: ANTHROPIC_DEFAULT_OPUS_MODELは固定許可から動的許可へ
  # 変わった（プロファイルのrole.*/fallback.*が実際にprovider=bedrock
  # model=opusを使っているときだけ許可）。ここでは role.researcher を
  # provider=bedrock model=opus に配役し、動的に許可されることを確認する。
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
# コメント行
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8

EOF
  chmod 644 "$ENV_FILE"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" >/dev/null 2>&1

  assert_true "CLAUDE_CODE_USE_BEDROCKがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "AWS_REGIONがenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('AWS_REGION')=='us-east-1' else 1)" && echo 1 || echo 0)"
  assert_true "role.researcherがprovider=bedrock model=opusを使っているため、ANTHROPIC_DEFAULT_OPUS_MODELが動的に許可されenvへ取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('ANTHROPIC_DEFAULT_OPUS_MODEL')=='us.anthropic.claude-opus-4-8' else 1)" && echo 1 || echo 0)"
  assert_true "テンプレ由来のDISABLE_AUTOUPDATERは残る" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('DISABLE_AUTOUPDATER')=='1' else 1)" && echo 1 || echo 0)"
  perm="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  assert_eq "envファイルのパーミッションが0600へ揃えられる" "600" "$perm"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 10b. Bedrock最小セット: role.*/fallback.*がprovider=bedrockでその別名を使っていなければANTHROPIC_DEFAULT_*_MODELは許可されない（2026-09-01 §4.2-d改訂・名前だけ許可リストに合う任意キーへ秘密値を入れる穴を塞ぐ回帰確認） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # プロファイルを一切置かない（実サンプルはbedrock役職を持たないため
  # v1相当のlegacy委譲になる＝role.*行が無くANTHROPIC_DEFAULT_*_MODELの
  # 入力元も無い、最も基本的な「未使用」ケース）。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8
ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5
EOF
  chmod 644 "$ENV_FILE"

  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)"

  assert_true "CLAUDE_CODE_USE_BEDROCK（固定許可）は引き続き取り込まれる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "ANTHROPIC_DEFAULT_OPUS_MODELは未使用のため取り込まれない" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if 'ANTHROPIC_DEFAULT_OPUS_MODEL' not in d.get('env',{}) else 1)" && echo 1 || echo 0)"
  assert_true "ANTHROPIC_DEFAULT_HAIKU_MODELは未使用のため取り込まれない" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if 'ANTHROPIC_DEFAULT_HAIKU_MODEL' not in d.get('env',{}) else 1)" && echo 1 || echo 0)"
  assert_true "未使用キーは許可リスト外のWARNとして扱われる" \
    "$(echo "$out" | grep -q '許可リスト外のキーがあったため取り込みませんでした' && echo 1 || echo 0)"

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

    # 2026-09-01 リーダー裁定（差し戻し対応・設計書S4）: bedrock.envが
    # 「実在するのに読めない/解析できない」場合はinstaller全体を非0終了に
    # する（「不在」は非Bedrock機の正常系なのでexit 0のまま維持するが、
    # こちらは--print-bedrock-env-json側と同じ「fail-openで偽装しない」
    # 契約に揃える。旧アサーション「exit 0で完走」から反転）。
    assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
      "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
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

  # 2026-09-01 リーダー裁定（差し戻し対応・設計書S4）: 実在して壊れている
  # （ディレクトリ）場合はinstaller全体を非0終了にする。
  assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
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

  # 2026-09-01 リーダー裁定（差し戻し対応・設計書S4）: 実在して壊れている
  # （dangling symlink）場合はinstaller全体を非0終了にする。
  assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
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

  # 2026-09-01 リーダー裁定（差し戻し対応・設計書S4）: 実在して壊れている
  # （UTF-8不正で解析失敗）場合はinstaller全体を非0終了にする。
  assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
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

  # 2026-09-01 リーダー裁定（差し戻し対応・設計書S4）: 探索権限不足で
  # 「読めない」と確定した場合もinstaller全体を非0終了にする（判定不能を
  # ABSENT扱いにしない・§4.2-b「静かに既定モデルへ倒れない」と同じ精神）。
  assert_true "settings.json生成は中止されるがinstaller全体は非0終了する（設計書S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
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

echo "=== 14b. --print-bedrock-env-json: role.*がprovider=bedrockを使っていれば動的許可キー(ANTHROPIC_DEFAULT_*_MODEL)も含まれる（2026-09-01 §4.2-d・値出力口一本化の回帰確認: update-sub.sh/check-drift.shはこの出力口だけを見るため、ここで固定2キーのままだとBedrockのモデルpinが常に脱落する） ==="
{
  FAKE_HOME="$(mktemp -d)"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null
  ENV_FILE="$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"
  cat > "$ENV_FILE" <<'EOF'
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8-dummy-pin
ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-sonnet-4-8-dummy-pin
EOF

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-bedrock-env-json)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "role.researcherがprovider=bedrock model=opusを使っているため、ANTHROPIC_DEFAULT_OPUS_MODELが--print-bedrock-env-jsonの出力にも含まれる" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d['env'].get('ANTHROPIC_DEFAULT_OPUS_MODEL')=='us.anthropic.claude-opus-4-8-dummy-pin' else 1)" && echo 1 || echo 0)"
  assert_true "CLAUDE_CODE_USE_BEDROCK（固定許可）も引き続き含まれる" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d['env'].get('CLAUDE_CODE_USE_BEDROCK')=='1' else 1)" && echo 1 || echo 0)"
  assert_true "profileが参照していないANTHROPIC_DEFAULT_SONNET_MODELはenvへ含まれない（2026-09-01 Codex差分レビュー指摘・MINOR対応: 動的許可が将来全別名へ広がる回帰を検出する）" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'ANTHROPIC_DEFAULT_SONNET_MODEL' not in d['env'] else 1)" && echo 1 || echo 0)"
  assert_true "ANTHROPIC_DEFAULT_SONNET_MODELはrejected_keysへキー名だけ載る" \
    "$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'ANTHROPIC_DEFAULT_SONNET_MODEL' in d['rejected_keys'] else 1)" && echo 1 || echo 0)"

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

# ============================================================
# 2026-09-01 配役表解凍（設計書§4.2-a〜g・§3.9）: --print-leader-runtime・
# --check-profile・リーダー配役の対話確定のテスト。
# ============================================================

echo "=== 17. --print-leader-runtime: v2でrole.leaderがconfigured（effortなし）ならJSONにeffortキーを含めない ==="
{
  FAKE_HOME="$(mktemp -d)"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null
  # role.leaderはprovider=anthropic-api model=claude-sonnet-5（effortなし）で
  # write_v2_profile_with_bedrock_role が既に書いている。

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "JSON出力ちょうど1行" '{"model": "claude-sonnet-5"}' "$out"
  assert_true "effortキーを含まない（未指定＝正常な省略）" \
    "$(echo "$out" | grep -q 'effort' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 18. --print-leader-runtime: effort指定時はJSONに含める ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  cat > "$FAKE_HOME/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: configured provider=anthropic-api model=claude-opus-5 effort=high
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime)"
  assert_eq "JSONにmodel/effort両方を含む" '{"model": "claude-opus-5", "effort": "high"}' "$out"

  rm -rf "$FAKE_HOME"
}

echo "=== 19. --print-leader-runtime: role.leaderがunknownなら失敗時stdoutが空・stderrに機械可読コード ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  cat > "$FAKE_HOME/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: unknown
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime 2>/dev/null)" || rc=$?
  err="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime 2>&1 1>/dev/null)" || true
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_eq "stdoutは空" "" "$out"
  assert_true "stderrに機械可読コードLEADER_UNCONFIGUREDが出る" \
    "$(echo "$err" | grep -q '^LEADER_UNCONFIGURED' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 20. --print-leader-runtime: v1プロファイル（schema_versionなし）はlegacy委譲し、effortはlegacy値highになる（回帰） ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  cat > "$FAKE_HOME/.config/takumi009-ai-env/profile.md" <<'EOF'
---
inventory_source: configured(work-tools-dir)
reviewer: configured(codex-mcp)
vault_write: configured(via-scribe)
vault_scope: configured(full)
ui.user_call: configured(send-message)
git_role: configured(aienv-repo:commit)
web_verification: configured(websearch)
---
EOF

  out_main="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime)"
  out_sub="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime --sub-delegate)"
  assert_eq "main既定値+legacy effort=high" '{"model": "claude-fable-5[1m]", "effort": "high"}' "$out_main"
  assert_eq "sub既定値+legacy effort=high（--sub-delegateで切り替わる）" '{"model": "claude-opus-5", "effort": "high"}' "$out_sub"

  rm -rf "$FAKE_HOME"
}

echo "=== 21. --print-leader-runtime: プロファイル実体が無ければv1相当としてlegacy委譲する（P1未整備機を落とさない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  # profile.md自体を作らない。

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "既定値+legacy effort=high" '{"model": "claude-fable-5[1m]", "effort": "high"}' "$out"

  rm -rf "$FAKE_HOME"
}

echo "=== 22. --print-leader-runtime: symlinkのプロファイルはPROFILE_UNREADABLEで非0・stdout空 ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  TARGET="$FAKE_HOME/target.md"
  write_v2_profile_with_bedrock_role "$TARGET" "opus" >/dev/null
  ln -s "$TARGET" "$FAKE_HOME/.config/takumi009-ai-env/profile.md"

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime 2>/dev/null)" || rc=$?
  err="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime 2>&1 1>/dev/null)" || true
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_eq "stdoutは空" "" "$out"
  assert_true "stderrにPROFILE_UNREADABLE" \
    "$(echo "$err" | grep -q '^PROFILE_UNREADABLE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 23. --print-leader-runtime: 実効リーダーがfallback採用のときfallbackのmodel/effortが返る ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  # 本命はunavailable（provider/modelは残すのが契約）、fallbackがconfigured。
  cat > "$FAKE_HOME/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: unavailable provider=bedrock model=opus
fallback.leader: configured provider=anthropic-api model=claude-opus-5 effort=medium
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --print-leader-runtime)"
  assert_eq "fallbackのmodel/effortが返る" '{"model": "claude-opus-5", "effort": "medium"}' "$out"

  rm -rf "$FAKE_HOME"
}

echo "=== 24. --check-profile: OKなプロファイルでprovider/modelグループの配役一覧を表示し、値は伏せない一覧専用表示である ==="
{
  FAKE_HOME="$(mktemp -d)"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" --check-profile 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "OK行が出る" "$(echo "$out" | grep -q '^OK' && echo 1 || echo 0)"
  assert_true "provider/modelでグループ化された一覧が出る（bedrock/opus）" \
    "$(echo "$out" | grep -q 'bedrock/opus:' && echo 1 || echo 0)"
  assert_true "role.researcherがそのグループの下に出る" \
    "$(echo "$out" | grep -q 'role.researcher(configured)' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 25. --check-profile --print-schema-version: 値なし・schema_versionだけを返す（U-7撤去条件判定用） ==="
{
  FAKE_HOME="$(mktemp -d)"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --check-profile --print-schema-version 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_eq "schema_versionの値だけを1行返す" "2" "$out"

  rm -rf "$FAKE_HOME"
}

echo "=== 26. 秘匿: --check-profileの出力にbedrock.envのpin実値が一切現れない（絶対厳守③） ==="
{
  FAKE_HOME="$(mktemp -d)"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  SECRET_PIN="us.anthropic.super-secret-inference-profile-id-DO-NOT-LEAK"
  cat > "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env" <<EOF
CLAUDE_CODE_USE_BEDROCK=1
ANTHROPIC_DEFAULT_OPUS_MODEL=${SECRET_PIN}
EOF
  chmod 600 "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  out="$(HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" --check-profile 2>&1)"
  assert_true "pin実値は--check-profile出力に一切現れない" \
    "$(echo "$out" | grep -q "$SECRET_PIN" && echo 0 || echo 1)"

  # settings.json生成（WARN含む）でも同様に漏れないことを併せて確認する。
  out2="$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 bash "$TMP_REPO/scripts/install-main.sh" 2>&1)"
  assert_true "pin実値はinstaller全体のWARN/ログにも一切現れない" \
    "$(echo "$out2" | grep -q "$SECRET_PIN" && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 27. §3.9対話: role.leader未確定・--non-interactiveなら非0終了（静かに既定モデルへ倒れない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  # ⚠️ AIENV_FORCE_TTY_FOR_TEST=1で「対話可能なTTYである」を強制したうえで
  # --non-interactiveを渡す（2026-09-01 Codex差分レビュー指摘・MAJOR対応:
  # このテストのコマンド置換自体が非TTYのため、AIENV_FORCE_TTY_FOR_TESTを
  # 付けないと「単に非TTYだから失敗した」のか「--non-interactiveがTTYより
  # 優先されたから失敗した」のかを区別できず、フラグの扱いを削除しても
  # テストが偽陽性で通ってしまう）。
  rc=0
  out="$(env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" --non-interactive 2>&1)" || rc=$?
  assert_true "exit非0（--non-interactiveがTTY強制より優先される）" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_UNCONFIGURED_NONINTERACTIVEが出る" \
    "$(echo "$out" | grep -q 'LEADER_UNCONFIGURED_NONINTERACTIVE' && echo 1 || echo 0)"
  assert_true "settings.jsonは生成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 28. §3.9対話: role.leader未確定・非TTY実行（--non-interactive無し）でも同じ機械可読コードで非0終了する（TTYだけで対話可否を判断しない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  rc=0
  out="$(env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" </dev/null 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_UNCONFIGURED_NONINTERACTIVEが出る" \
    "$(echo "$out" | grep -q 'LEADER_UNCONFIGURED_NONINTERACTIVE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 29. §3.9対話: Q1→Q2→Q3を対話で答えるとrole.leaderの1行だけが確定し、他の行は1バイトも変わらない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  # 実サンプルと同じ経路（雛形コピー）でrole.leader:unknownの実体を用意する。
  env -u AIENV_LEADER_ROLE HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" --dry-run >/dev/null 2>&1
  mkdir -p "$(dirname "$PROFILE_PATH")"
  # --dry-runは何も書かないため改めて雛形だけを直接生成する。
  python3 - "$TMP_REPO/vault-public/Preferences/profile-sample.md" "$PROFILE_PATH" <<'PYEOF'
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
blocks = re.findall(r"```yaml\n(.*?)\n```", text, re.DOTALL)
candidate = next(b for b in blocks if b.lstrip().startswith("---"))
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write(candidate.rstrip("\n") + "\n")
PYEOF
  PRE_CONTENT="$(cat "$PROFILE_PATH")"

  # Q1=1(anthropic-api) Q2=0(自分で入力)+claude-opus-5 Q3=3(medium)
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)"
  rc=$?
  assert_eq "対話完了後exit 0" "0" "$rc"
  assert_true "role.leader行がconfigured provider=anthropic-api model=claude-opus-5 effort=mediumになる" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"
  DIFF_LINES="$(diff <(printf '%s\n' "$PRE_CONTENT") "$PROFILE_PATH" | grep -c '^[<>]')" || true
  assert_eq "role.leader以外の行は変化しない（差分は置換した1行のみ＝旧行1・新行1の2エントリ）" "2" "$DIFF_LINES"
  # role.leader確定のログ行自体は値を再掲しない設計（write_and_verify_leader
  # 参照）。settings.json生成ログ（"model"を...へ設定）は既存の値出力口と
  # 同種の情報表示であり秘密ではないため、そちらに値が出ること自体は問題ない
  # （pin実値の非露出はテスト26で別途検証済み）。
  assert_true "role.leader確定のログ行自体には値を再掲しない" \
    "$(echo "$out" | grep 'role.leader を確定しました' | grep -q 'claude-opus-5' && echo 0 || echo 1)"
  assert_true "settings.jsonのmodelが対話で選んだ値になる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('model')=='claude-opus-5' else 1)" && echo 1 || echo 0)"
  assert_true "settings.jsonのeffortLevelが対話で選んだ値になる" \
    "$(python3 -c "import json;d=json.load(open('$FAKE_HOME/.claude/settings.json'));exit(0 if d.get('effortLevel')=='medium' else 1)" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 30. §3.9対話: 3回とも不正な回答が続くと中止し、profileは一切変更されない（回数は組単位） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  python3 - "$TMP_REPO/vault-public/Preferences/profile-sample.md" "$PROFILE_PATH" <<'PYEOF'
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
blocks = re.findall(r"```yaml\n(.*?)\n```", text, re.DOTALL)
candidate = next(b for b in blocks if b.lstrip().startswith("---"))
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write(candidate.rstrip("\n") + "\n")
PYEOF
  PRE_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  # Q1に3回とも不正な番号(9)を答え続ける。
  rc=0
  out="$(printf '9\n9\n9\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_DIALOG_FAILEDが出る" \
    "$(echo "$out" | grep -q 'LEADER_DIALOG_FAILED' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"
  assert_eq "profileは1バイトも変更されない" "$PRE_SHA" "$POST_SHA"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 31. §3.9対話: 対話中のEOFは即座に非0終了する（リトライしない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  python3 - "$TMP_REPO/vault-public/Preferences/profile-sample.md" "$PROFILE_PATH" <<'PYEOF'
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
blocks = re.findall(r"```yaml\n(.*?)\n```", text, re.DOTALL)
candidate = next(b for b in blocks if b.lstrip().startswith("---"))
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write(candidate.rstrip("\n") + "\n")
PYEOF

  rc=0
  # 入力を1行も与えない（即EOF）。
  out="$(printf '' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_DIALOG_ABORTEDが出る（3回リトライではなく即時中止）" \
    "$(echo "$out" | grep -q 'LEADER_DIALOG_ABORTED' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 32. §3.9対話: configuredなrole.leaderにAIENV_LEADER_ROLEが不一致・--reconfigure-leader無しならLEADER_ROLE_CONFLICTで非0終了 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  write_v2_profile_with_bedrock_role "$FAKE_HOME/.config/takumi009-ai-env/profile.md" "opus" >/dev/null

  rc=0
  out="$(AIENV_LEADER_ROLE='provider=anthropic-api model=claude-opus-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_ROLE_CONFLICTが出る" \
    "$(echo "$out" | grep -q 'LEADER_ROLE_CONFLICT' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 33. §3.9対話: --reconfigure-leader付きならAIENV_LEADER_ROLEの新しい値を採用する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile_with_bedrock_role "$PROFILE_PATH" "opus" >/dev/null

  rc=0
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-opus-5 effort=low' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --reconfigure-leader >/dev/null 2>&1
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "role.leaderが新しい値へ書き換わる" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=low' "$PROFILE_PATH" && echo 1 || echo 0)"
  assert_true "role.researcher行は変化しない（他の行は触らない）" \
    "$(grep -q '^role.researcher: configured provider=bedrock model=opus$' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 34. §3.9対話: configuredかつAIENV_LEADER_ROLE無し・--reconfigure-leader無しなら質問せずそのまま通す（冪等） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile_with_bedrock_role "$PROFILE_PATH" "opus" >/dev/null
  PRE_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  rc=0
  out="$(env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" </dev/null 2>&1)" || rc=$?
  assert_eq "exit code 0（質問しない）" "0" "$rc"
  assert_true "確定済みメッセージが出る" \
    "$(echo "$out" | grep -q 'リーダー配役は確定済みです' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"
  assert_eq "profileは変更されない（冪等）" "$PRE_SHA" "$POST_SHA"

  rm -rf "$FAKE_HOME"
}

echo "=== 35. §3.9対話: role.leader行が欠落している実体には挿入する（既存行の破壊・複数箇所置換をしない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 2
profile_slug: test
role.researcher: configured provider=anthropic-api model=claude-sonnet-5
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  rc=0
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-opus-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" >/dev/null 2>&1
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "role.leader行が新規に挿入される" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5' "$PROFILE_PATH" && echo 1 || echo 0)"
  assert_true "role.researcher行は変化しない" \
    "$(grep -q '^role.researcher: configured provider=anthropic-api model=claude-sonnet-5$' "$PROFILE_PATH" && echo 1 || echo 0)"
  assert_true "フロントマターの終端---が保たれている" \
    "$([[ "$(tail -1 "$PROFILE_PATH")" == "---" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 36. §3.9対話: role.leaderが2行ある実体は非0終了する（構文エラーT6として検出。書込み対象を誤らない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: unknown
role.leader: configured provider=anthropic-api model=claude-opus-5
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "PROFILE_INVALID:T6が出る（重複キー）" \
    "$(echo "$out" | grep -q 'PROFILE_INVALID:T6' && echo 1 || echo 0)"
  assert_true "settings.jsonは生成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "即時fail()経路（S2/S3相当）でも生成物が存在しない場合はNO_GENERATED_FILEが明示される（2026-09-01工程横断レビュー指摘・MINOR-2追加対応: deferred経路〈S4・S18〉だけでなく即時fail()経路にも同じ契約を適用する）" \
    "$(echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 37. S16: profile更新は成功したがsettings.json生成に失敗した場合、新profile＋旧settingsを保持し非0終了する（追完・2026-09-01リーダー指示） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile_with_bedrock_role "$PROFILE_PATH" "opus" >/dev/null
  # role.leaderは既にconfigured provider=anthropic-api model=claude-sonnet-5。
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{
  "model": "sentinel-pre-existing-value",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1"
  }
}
EOF
  PRE_SETTINGS_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # bedrock.envのパスをディレクトリにして、settings.json生成だけを確実に
  # 失敗させる（§4.2-a〜gの実装がprofile更新→settings生成の順で走ることを
  # 前提に、後段だけを狙い撃ちする）。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-opus-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --reconfigure-leader >/dev/null 2>&1 || rc=$?

  assert_true "installer全体は非0終了する（設計書S16・S4）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "profile.mdは新しいリーダー値へ更新されている（profile更新自体は成功）" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5' "$PROFILE_PATH" && echo 1 || echo 0)"
  POST_SETTINGS_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "settings.jsonは旧内容のまま保持される（バイト単位で不変）" "$PRE_SETTINGS_SHA" "$POST_SETTINGS_SHA"

  rm -rf "$FAKE_HOME"
}

echo "=== 38. §3.9優先順位表 行1: DRY_RUN=1は他条件によらず一切変更しない（リーダー配役の対話メッセージのみ表示） ==="
{
  FAKE_HOME="$(mktemp -d)"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile_with_bedrock_role "$PROFILE_PATH" "opus" >/dev/null
  PRE_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  out="$(env -u AIENV_LEADER_ROLE HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run --reconfigure-leader 2>&1)"
  assert_true "[dry-run]リーダー配役対話メッセージが出る" \
    "$(echo "$out" | grep -q '\[dry-run\] リーダー配役を対話で確認します' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"
  assert_eq "profileは一切変更されない" "$PRE_SHA" "$POST_SHA"
  assert_true "settings.jsonも生成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 39. §3.9優先順位表 行2: 未確定+AIENV_LEADER_ROLE有(任意reconfigure)→質問せずenv値を検査して採用 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: unknown
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  rc=0
  # --non-interactive を付けていても（対話可否によらず）質問されずに
  # env値がそのまま採用されることを確認する（表の「対話可否」列が「—」＝
  # 無関係であることの直接確認）。
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-opus-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --non-interactive >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0（質問されない）" "0" "$rc"
  assert_true "role.leaderがAIENV_LEADER_ROLEの値で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 40. §3.9優先順位表 行5: configured+AIENV_LEADER_ROLE有(既存と一致)+reconfigure無→そのまま通す(冪等) ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile_with_bedrock_role "$PROFILE_PATH" "opus" >/dev/null
  PRE_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  rc=0
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-sonnet-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  POST_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"
  assert_eq "既存値と一致するAIENV_LEADER_ROLEはprofileを変更しない（冪等）" "$PRE_SHA" "$POST_SHA"

  rm -rf "$FAKE_HOME"
}

echo "=== 41. §3.9優先順位表 行9: configured+AIENV_LEADER_ROLE無+reconfigure有+対話可→既存値を既定候補として質問 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  # ⚠️ effortを明示的に設定しておく（Enterのみで「既定候補を維持」できるのは
  # 既存値がある場合だけ＝ask_q3の契約。既存値が無いeffortでEnterを送ると
  # 「未指定を選ぶ」意思表示にならず入力不正扱いになるため、Q1〜Q3すべてで
  # Enterのみが有効な組み合わせになるようeffort=mediumを持つ実体を使う）。
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: configured provider=anthropic-api model=claude-sonnet-5 effort=medium
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF

  # 全問Enterのみ（空行）で答え、既存値(anthropic-api/claude-sonnet-5/
  # effort=medium)がそのまま既定候補として採用されることを確認する。
  rc=0
  out="$(printf '\n\n\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$SCRIPT" --reconfigure-leader 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "Q1〜Q3すべてEnterで既存値(claude-sonnet-5・effort=medium)がそのまま採用される" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-sonnet-5 effort=medium$' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 42. §3.9優先順位表 行10: configured+AIENV_LEADER_ROLE無+reconfigure有+対話不可→非0終了 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  write_v2_profile_with_bedrock_role "$PROFILE_PATH" "opus" >/dev/null
  PRE_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"

  rc=0
  out="$(env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
    HOME="$FAKE_HOME" bash "$SCRIPT" --reconfigure-leader --non-interactive 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_UNCONFIGURED_NONINTERACTIVEが出る" \
    "$(echo "$out" | grep -q 'LEADER_UNCONFIGURED_NONINTERACTIVE' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$PROFILE_PATH" | awk '{print $1}')"
  assert_eq "profileは変更されない" "$PRE_SHA" "$POST_SHA"

  rm -rf "$FAKE_HOME"
}

echo "=== 43. 設計書S6: python3不在時はsettings.json生成そのものに着手せず、既存ファイルを一切変更せず非0終了する（従来は手動確認のみだったため専用テストを追加・§10残課題台帳#5対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{"model": "sentinel-pre-existing-value"}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # python3を含まない最小限のPATHを組み立てる（他の外部コマンドは実PATHから
  # symlinkで拾う。EMPTY_BINDIRのみをPATHにするためpython3自体は解決不能になる）。
  BINDIR="$(mktemp -d)"
  for b in bash dirname basename mkdir mv cp chmod stat sed awk grep sort uniq cat cut tr wc date shasum mktemp rm ln find env true false head tail printf; do
    p="$(command -v "$b" 2>/dev/null)"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$b"
  done

  rc=0
  out="$(PATH="$BINDIR" SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "python3不在の理由が出る" \
    "$(echo "$out" | grep -q 'python3 が見つかりません' && echo 1 || echo 0)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存のsettings.jsonがバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
  assert_true "machine-roleマーカーも書かれない（settings.json生成に着手する前に停止する）" \
    "$([[ ! -e "$FAKE_HOME/.config/takumi009-ai-env/machine-role" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo "=== 43b. 設計書S6×S8: python3不在かつ生成物が一度も存在しない（真の初回インストール）場合はNO_GENERATED_FILEが明示される（2026-09-01工程横断レビュー指摘・MINOR-2追加対応: S6のような即時fail()経路でもS8の契約〈生成物が存在しない状態でS2〜S7〉を満たすことの回帰テスト） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # settings.jsonを事前に一切作らない（真の初回インストール）。
  BINDIR="$(mktemp -d)"
  for b in bash dirname basename mkdir mv cp chmod stat sed awk grep sort uniq cat cut tr wc date shasum mktemp rm ln find env true false head tail printf; do
    p="$(command -v "$b" 2>/dev/null)"
    [ -n "$p" ] && ln -s "$p" "$BINDIR/$b"
  done

  rc=0
  out="$(PATH="$BINDIR" SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "settings.jsonは一切生成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "NO_GENERATED_FILEが明示される" \
    "$(echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$BINDIR"
}

echo "=== 43c. 設計書S5×S8: テンプレの\"model\"が__AIENV_MODEL__の目印でない（誰かが特定モデルをハードコードした）場合、生成物が一度も存在しなければNO_GENERATED_FILEが明示される（従来はS5自体の専用テストが無かったため追加・2026-09-01工程横断レビュー指摘・MINOR-2追加対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  # テンプレの"model"目印を具体値へ書き換える（誰かがテンプレへ直接
  # ハードコードしてしまった回帰を模す）。
  python3 -c "
import json
with open('$TMP_REPO/claude/settings.json') as f:
    data = json.load(f)
data['model'] = 'claude-hardcoded-regression'
with open('$TMP_REPO/claude/settings.json', 'w') as f:
    json.dump(data, f, indent=2)
"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "テンプレ検証失敗の理由が出る" \
    "$(echo "$out" | grep -q '__AIENV_MODEL__' && echo 1 || echo 0)"
  assert_true "settings.jsonは一切生成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "NO_GENERATED_FILEが明示される" \
    "$(echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 43d. 設計書S7×S8: settings.json配置先の親ディレクトリが作成できない（mkdir失敗）場合、生成物が一度も存在しなければNO_GENERATED_FILEが明示される（従来はS7自体の専用テスト・メッセージ自体が無く裸のset -eで無言終了していたため追加・2026-09-01工程横断レビュー指摘・MINOR-2追加対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  # .claude を通常ファイルとして作る（mkdir -p "$(dirname .../settings.json)"
  # ＝mkdir -p "$FAKE_HOME/.claude" が「同名の非ディレクトリが既にある」ため
  # 決定的に失敗する。make_fake_homeは使わない＝.claudeをディレクトリとして
  # 先に作ってしまうため）。
  mkdir -p "$FAKE_HOME"
  : > "$FAKE_HOME/.claude"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "配置先ディレクトリを作成できない旨の理由が出る" \
    "$(echo "$out" | grep -q '配置先ディレクトリを作成できません' && echo 1 || echo 0)"
  assert_true "settings.jsonは一切生成されない（同名の通常ファイルのまま）" \
    "$([[ ! -d "$FAKE_HOME/.claude" ]] && echo 1 || echo 0)"
  assert_true "NO_GENERATED_FILEが明示される" \
    "$(echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 43e. 設計書S7: settings.jsonのバックアップ作成(cp)が失敗した場合、誤って『backed up』ログを出さず既存settings.jsonを保持したまま非0終了する（backup_once()を\`cmd || fail_settings_generation\`の左辺で呼ぶとbash仕様上その関数本体全体でset -eが無効化され、cp失敗が握り潰されて生成続行してしまう回帰があったため専用テストを追加・2026-09-01工程横断レビュー指摘・MAJOR対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{"model": "sentinel-pre-existing-value"}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  # $HOME/.claudeディレクトリの書込権限を外す（cp "$dest" "$dest.pre-aienv.bak"
  # が新規ファイル作成に失敗する＝決定的なバックアップ失敗を再現する）。
  # mkdir -p自体は既存ディレクトリに対しては書込権限が無くても成功するため、
  # S7のうちbackup_once()のcp失敗だけを狙い撃ちできる。
  chmod 555 "$FAKE_HOME/.claude"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  chmod 755 "$FAKE_HOME/.claude" 2>/dev/null
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "バックアップ作成失敗の理由が出る" \
    "$(echo "$out" | grep -q 'settings.jsonの既存バックアップ作成に失敗しました' && echo 1 || echo 0)"
  assert_true "settings.jsonについて誤った『backed up』ログは出ない（cp失敗が握り潰されて生成続行していない証拠）" \
    "$(echo "$out" | grep -q 'backed up:.*settings\.json' && echo 0 || echo 1)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存settings.jsonがバイト単位で一切変更されていない(SHA-256不変・上書きされていない)" "$PRE_SHA" "$POST_SHA"
  assert_true "既存ファイルが在るためNO_GENERATED_FILEは付かない（保持と欠落の区別）" \
    "$(echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 44. 設計書S8: 生成物が存在しない状態でS2〜S7（bedrock.env読取不能=S4）が発生すると、settings.jsonは一切生成されないままinstaller全体が非0終了する（他の配置処理は完走する。従来は手動確認のみだったため専用テストを追加・§10残課題台帳#5対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # settings.jsonを事前に一切作らない（真の初回インストール＝生成物が存在
  # しない状態）。bedrock.envをディレクトリにしてS4（読めない/解析できない）
  # を発火させる。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env"
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0（NO_GENERATED_FILE相当：出力なしのまま起動させない）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "settings.jsonは一切生成されない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "他の配置処理（hooksのsymlink化）は完走する（settings.json以外は続行する設計）" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
  assert_true "締めの警告が出る" \
    "$(echo "$out" | grep -q '非0終了します' && echo 1 || echo 0)"
  assert_true "最終的な終了理由に機械可読トークンNO_GENERATED_FILEが明示される（2026-09-01工程横断レビュー指摘・MINOR-2対応: 従来は終了コードのみでテキスト上は区別できなかった）" \
    "$(echo "$out" | grep -q 'NO_GENERATED_FILE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

# 45a〜45d: §3.9 Q2 v11契約（F-22）: 候補一覧を生成できない4区分
# （サンプル読取不能／yaml抽出失敗／構造検証失敗／選択したproviderの候補
# 0件）のそれぞれで、理由が区別して表示され、かつ『0) 自分で入力する』が
# 必ず残って対話が止まらず完了することを固定する（従来は一律「候補は
# ありません」でWARN文言のみだったため専用テストを追加・§10「結合（対話・
# U-1）」の新検証項目に1対1対応）。

_write_test_leader_profile() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
---
schema_version: 2
profile_slug: test
role.leader: unknown
role.researcher: configured provider=anthropic-api model=claude-sonnet-5
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
EOF
}

echo "=== 45a. §3.9 Q2対話(F-22): サンプル本体が存在しない(SAMPLE_UNREADABLE)ときは理由『サンプル読取不能』が表示され、『0) 自分で入力する』で対話が完了する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  rm -f "$TMP_REPO/vault-public/Preferences/profile-sample.md"

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  _write_test_leader_profile "$PROFILE_PATH"

  rc=0
  # Q1=1(anthropic-api) Q2=候補0件のはずなので0(自分で入力)+claude-opus-5 Q3=3(medium)
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "対話完了後exit 0（候補0件でも対話は止まらない）" "0" "$rc"
  assert_true "理由『サンプル読取不能』が表示される（4区分の他の理由文言は出ない）" \
    "$(echo "$out" | grep -q '候補一覧を生成できません（理由: サンプル読取不能）。候補は使わず model を手入力してください' && echo 1 || echo 0)"
  assert_true "『0) 自分で入力する』が残る" \
    "$(echo "$out" | grep -q '0) 自分で入力する' && echo 1 || echo 0)"
  assert_true "role.leaderが自分で入力した値（claude-opus-5）で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 45a2. §3.9 Q2対話(F-22): サンプルが不正UTF-8で読めない(SAMPLE_UNREADABLE)ときも理由『サンプル読取不能』が表示される（[ -f ]は存在確認のみで読取可能性を保証しない・2026-09-01工程横断レビュー指摘・MINOR-1対応の回帰テスト） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  # 有効なUTF-8として読めないバイト列（0xff 0xfe）を書く。ファイルは実在
  # するが`open(..., encoding='utf-8')`がUnicodeDecodeErrorで失敗する。
  printf '\xff\xfe invalid utf8 bytes\n' > "$TMP_REPO/vault-public/Preferences/profile-sample.md"

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  _write_test_leader_profile "$PROFILE_PATH"

  rc=0
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "対話完了後exit 0（候補0件でも対話は止まらない）" "0" "$rc"
  assert_true "理由『サンプル読取不能』が表示される（誤って『yaml 抽出失敗』にならない）" \
    "$(echo "$out" | grep -q '候補一覧を生成できません（理由: サンプル読取不能）。候補は使わず model を手入力してください' && echo 1 || echo 0)"
  assert_true "role.leaderが自分で入力した値（claude-opus-5）で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 45a3. §3.9 Q2対話(F-22): サンプルが実在する通常ファイルなのに権限不足で読めない(SAMPLE_UNREADABLE)ときも理由『サンプル読取不能』が表示される（[ -f ]は通過するがopen()がPermissionErrorになるケース・2026-09-01工程横断レビュー指摘・MINOR-1対応の回帰テスト） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  # ⚠️ ディレクトリではなく実在する通常ファイルへchmod 000する（[ -f ]が
  # 真を返す＝旧実装のバグが実際に発火していた経路そのものを再現するため。
  # ディレクトリだと[ -f ]の時点で偽になり「実在しない」経路と区別できず
  # 本テストの意図を満たさない）。chmod 000はroot実行環境では読めてしまい
  # 未検証になりうる（test 16のコメント参照）が、本テストの実行ユーザーは
  # 非rootを前提とする。
  printf -- '---\nrole.leader: unknown\n---\n' > "$TMP_REPO/vault-public/Preferences/profile-sample.md"
  chmod 000 "$TMP_REPO/vault-public/Preferences/profile-sample.md"

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  _write_test_leader_profile "$PROFILE_PATH"

  rc=0
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "対話完了後exit 0（候補0件でも対話は止まらない）" "0" "$rc"
  assert_true "理由『サンプル読取不能』が表示される（誤って『yaml 抽出失敗』にならない）" \
    "$(echo "$out" | grep -q '候補一覧を生成できません（理由: サンプル読取不能）。候補は使わず model を手入力してください' && echo 1 || echo 0)"
  assert_true "role.leaderが自分で入力した値（claude-opus-5）で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"

  chmod 644 "$TMP_REPO/vault-public/Preferences/profile-sample.md" 2>/dev/null
  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 45b. §3.9 Q2対話(F-22): サンプルにyamlフェンスが無い(YAML_EXTRACT_FAILED)ときは理由『yaml 抽出失敗』が表示され、対話が完了する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  mkdir -p "$TMP_REPO/vault-public/Preferences"
  # yamlフェンスを持たない壊れたサンプルへ差し替える（extract_profile_schema_
  # block自体が失敗する＝sample_model_candidates()がfallback経路を通る）。
  echo "no yaml fence in this fixture" > "$TMP_REPO/vault-public/Preferences/profile-sample.md"

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  _write_test_leader_profile "$PROFILE_PATH"

  rc=0
  # Q1=1(anthropic-api) Q2=候補0件のはずなので0(自分で入力)+claude-opus-5 Q3=3(medium)
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "対話完了後exit 0（候補0件でも対話は止まらない）" "0" "$rc"
  assert_true "理由『yaml 抽出失敗』が表示される" \
    "$(echo "$out" | grep -q '候補一覧を生成できません（理由: yaml 抽出失敗）。候補は使わず model を手入力してください' && echo 1 || echo 0)"
  assert_true "role.leaderが自分で入力した値（claude-opus-5）で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 45c. §3.9 Q2対話(F-22): サンプルにrole.leaderの重複行がある(STRUCTURE_INVALID・list-rolesの構造検証失敗)ときは理由『構造検証失敗』が表示され、不正な行は候補として拾わずに対話が完了する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  mkdir -p "$TMP_REPO/vault-public/Preferences"
  # ```yaml抽出自体は成功するが、role.leaderが2行あるため§3.1-7の重複キー
  # 検査でlist-rolesの構造検証自体が落ちる（1行でも不正なら出力全体を
  # 失敗させる契約＝contract §4.5）。role.researcherの行自体は形式上正しい
  # が、「不正な行だけ落として残りを候補にする」ことをしない設計のため、
  # この行も候補には出ない。
  cat > "$TMP_REPO/vault-public/Preferences/profile-sample.md" <<'EOF'
```yaml
---
schema_version: 2
profile_slug: broken
role.leader: unknown
role.leader: unknown
role.researcher: configured provider=anthropic-api model=claude-sonnet-5
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
```
EOF

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  _write_test_leader_profile "$PROFILE_PATH"

  rc=0
  # Q1=1(anthropic-api) Q2=候補0件のはずなので0(自分で入力)+claude-opus-5 Q3=3(medium)
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "対話完了後exit 0（候補0件でも対話は止まらない）" "0" "$rc"
  assert_true "理由『構造検証失敗』が表示される（role.researcherの行も候補に出ない）" \
    "$(echo "$out" | grep -q '候補一覧を生成できません（理由: 構造検証失敗）。候補は使わず model を手入力してください' && echo 1 || echo 0)"
  assert_true "不正行の全文・属性値はログに出ない（§3.1-8）" \
    "$(echo "$out" | grep -q 'role.leader: unknown' && echo 0 || echo 1)"
  assert_true "role.leaderが自分で入力した値（claude-opus-5）で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 45d. §3.9 Q2対話(F-22): サンプルは構造上健全だが選んだprovider向けのconfigured行が無い(PROVIDER_NO_CANDIDATES)ときは理由『選択した provider の候補が0件』が表示され、対話が完了する ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  mkdir -p "$TMP_REPO/vault-public/Preferences"
  # サンプル自体は構造上健全だがrole.researcherがprovider=bedrockのみ。
  # Q1でanthropic-apiを選ぶため、この provider の configured 行は0件になる
  # （⚠️ Q1でbedrock/bedrock-mantleを選ぶと、最終確定時のcheck-candidate
  # --for-leaderがV9-d③〈bedrock.envでCLAUDE_CODE_USE_BEDROCK有効〉を要求
  # してしまい、本テストの主眼〈候補0件の理由表示〉と無関係な前提を増やす
  # ため、最終選択はbedrock.env不要なanthropic-apiのままにする）。
  cat > "$TMP_REPO/vault-public/Preferences/profile-sample.md" <<'EOF'
```yaml
---
schema_version: 2
profile_slug: ok
role.leader: unknown
role.researcher: configured provider=bedrock model=opus
excluded_models: configured value=none
inventory_source: configured value=work-tools-dir
reviewer: configured value=codex-mcp
vault_write: configured value=via-scribe
vault_scope: configured value=full
ui.user_call: configured value=send-message
git_role: configured value=aienv-repo:commit
web_verification: configured value=websearch
---
```
EOF

  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  _write_test_leader_profile "$PROFILE_PATH"

  rc=0
  # Q1=1(anthropic-api) Q2=候補0件のはずなので0(自分で入力)+claude-opus-5 Q3=3(medium)
  out="$(printf '1\n0\nclaude-opus-5\n3\n' \
    | env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 \
      HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" 2>&1)" || rc=$?
  assert_eq "対話完了後exit 0（候補0件でも対話は止まらない）" "0" "$rc"
  assert_true "理由『選択した provider の候補が0件』が表示される" \
    "$(echo "$out" | grep -q '候補一覧を生成できません（理由: 選択した provider の候補が0件）。候補は使わず model を手入力してください' && echo 1 || echo 0)"
  assert_true "role.leaderが自分で入力した値（claude-opus-5）で確定する" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-opus-5 effort=medium' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 46. 動的Bedrock許可キーの算出失敗時はfail-openで固定2キーへ縮退せず、settings.json生成をスキップして既存ファイルを保持したうえで非0終了する（2026-09-01工程横断レビュー差し戻し・MAJOR対応の回帰テスト。旧実装はWARNのみで固定2キーへ縮退し生成を続行しており、未知のworker別名1件でも他の正常な動的pinキーが許可集合から落ち、既存settingsのpinが静かに消え得た） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  cat > "$FAKE_HOME/.claude/settings.json" <<'EOF'
{"model": "sentinel-pre-existing-value", "env": {"CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-4-8-dummy-pin"}}
EOF
  PRE_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"

  # resolve-leaderは成功させ（後段のcompute_allowed_bedrock_env_keys()に
  # 到達させるため）、list-rolesだけが「算出そのものの失敗」
  # （PROFILE_LEGACY_V1/PROFILE_NOT_FOUND以外のエラー）を返す偽libで、
  # 「動的キー0件（正常）」と「算出不能（異常）」の区別を呼び出し側で
  # 再現する（実プロファイルでこの組み合わせ＝leaderは解決できるのに
  # list-rolesだけ失敗、を自然発生させるのが困難なため専用の偽libを使う）。
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
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 AIENV_PROFILE_RESOLVE_LIB="$FAKE_LIB" \
    HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "exit非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "算出失敗＋settings.json生成スキップの旨がWARNに出る（固定2キーへの縮退文言は出ない）" \
    "$(echo "$out" | grep -q '動的Bedrock許可キーの算出に失敗しました' && echo "$out" | grep -q '生成をスキップし、既存ファイルを保持します' && echo 1 || echo 0)"
  assert_true "『固定2キー…のみで続行します』という旧文言は出ない（fail-openで偽装しない）" \
    "$(echo "$out" | grep -q 'のみで続行します' && echo 0 || echo 1)"
  POST_SHA="$(shasum -a 256 "$FAKE_HOME/.claude/settings.json" | awk '{print $1}')"
  assert_eq "既存settings.json（動的pinを含む）がバイト単位で一切変更されていない(SHA-256不変)" "$PRE_SHA" "$POST_SHA"
  # ⚠️ ここまでの3つのassertは「即時中断（settings.json以外も全部止める）」
  # 誤実装でも通ってしまう（Codex一次レビュー指摘・MINOR対応）。設計書
  # §6.2-B S18は「deferred非0」＝settings.json以外の後続処理（hooksの
  # symlink化等）は完走させたうえで末尾のみ非0にする契約のため、それを
  # 直接固定する2つを追加する。
  assert_true "settings.json以外の後続処理（hooksのsymlink化）は完走する（即時中断ではなくdeferred非0）" \
    "$([[ -L "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh" ]] && echo 1 || echo 0)"
  assert_true "締めの警告『他の配置処理は完了しましたが…非0終了します』が出る" \
    "$(echo "$out" | grep -q '他の配置処理は完了しましたが' && echo 1 || echo 0)"

  rm -f "$FAKE_LIB"
  rm -rf "$FAKE_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
