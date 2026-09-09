#!/usr/bin/env bash
# scripts/install-sub.sh のユニットテスト。
#
# 実 ~/.claude・~/.codex・実Vaultには一切依存しない。HOME環境変数を
# 毎回ダミーのfixtureディレクトリへ差し替えてスクリプトを実行し、
# Vault骨格配置・claude/codex symlink化の委譲が正しく行われることを検証する。
#
# 注意: install-sub.sh は install-main.sh へ `--sub-delegate` を付けて委譲する。
# 週次drift通知LaunchAgent（com.takumi009.drift-check.plist）は2026-07-16簡素化で
# install-main.sh自体から撤去済み（メイン/サブ問わず誰も設置しない。旧・メイン専用
# skip実装＝H-2は撤去に伴い不要化した）。旧・codex MCP自動登録ステップ（当時の
# scripts/内の専用スクリプト）は2026-09-06 codex exec一本化に伴い
# install-main.sh から撤去済み（既存の呼び出しに残っているSKIP_CODEX_MCP=1
# 指定は無害な未使用変数。install-main.sh側では読まなくなった）。
# SKIP_LAUNCHCTL=1 も一部テストで付けて
# いるが、これは委譲先の install-main.sh 自身が同名の環境変数を宣言している
# ための互換目的であり、install-sub.sh 自体は現在launchctlを一切呼び出さない
# （下記2026-07-23の変更で撤去済み）。
#
# 2026-07-23: サブ専用の定期更新LaunchAgent（旧com.takumi009.update-sub・1日2回の
# 無人自動pull）自体を廃止した（SessionStartフックclaude/hooks/check-sub-update.sh
# による手動実行案内方式へ置き換え）ため、新しいLaunchAgentのインストールを
# 検証していた5b/7/12/13番のテストは撤去した。本人指示（実機のサブ機は
# install-sub.shを一度も適用したことが無く既設のLaunchAgentが存在しない）により、
# 旧ラベルのbootout/plist削除といった移行処理自体も実装しない方針となったため、
# 移行ロジックを検証していた7b以降のテスト群も撤去し、5番を
# 「LaunchAgentは一切設置されない」ことのみを確認する内容に更新した。
#
# 2026-07-24: メイン/サブ判定をVaultのprivate層ファイル不在（否定証明）から
# 旧マーカーファイル（積極的な証明）方式へ変更した（リーダー裁定・
# Codex一次レビュー指摘Major対応）。
#
# 2026-08-21: claude/settings.json を symlink から「テンプレ+生成」方式へ変更した
# （codex/config.tomlと同型。理由: JSONもシェル変数展開されない・symlinkのままだと
# セッション内`/model`実行時にClaude Code自身がrepo管理下のファイルを直接書き換えて
# しまう副作用があった）。"model"フィールドはマシン別（メイン=claude-fable-5[1m]・
# サブ=claude-opus-5。サブはProプランでFable 5非対応、[1m]も付けない＝リーダー指示）
# に出し分ける。決定は--sub-delegateの有無（＝install-sub.sh経由か直接実行か）から
# 直接行われ、旧マーカーの読み返しには依存しない。4番を旧来のsymlink検証
# から生成物検証へ更新し、4b〜4eでmodel出し分け・環境変数上書き・内容保持を追加検証する。
#
# 2026-09-07: 機役割の正本を旧マーカーファイルから配役表の能力軸`machine_role`
# （本人が実体プロファイルへ書く）へ移した（配役表-能力軸整理-設計-2026-09-07.md
# §5.1）。マーカー設置を検証していた7〜9番は撤去し、代わりに案内ログ1行が
# 出ることを7番・AIENV_LOCAL_PROFILE_PATH未設定でも到達することを7b番・
# 委譲が非0終了しても案内ログまで完走することを12番で確認する。
# 13・13b・14番の副作用ゼロ検査も、マーカー不在の確認から案内ログが
# 出ないことへ差し替えた。
#
# 実行方法: bash tests/test-install-sub.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-sub.sh"

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

# assert_agents_line <desc> <stdout> <kind:初回未配置|dangling> <role> —
# test-install-main.shと同じ検査（設計§2.1の固定文の型・件数と名前トークン数の
# 一致・対象ロールの厳密一致）。2026-09-07 Codex一次レビュー指摘・MINOR対応。
assert_agents_line() {
  local desc="$1" out="$2" kind="$3" role="$4"
  local line count names n_names expected_desc
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
    fail_case "$desc (固定文の型〈件数・説明文・句読点・コロン〉が一致しない。期待する説明文=[${expected_desc}]。行=[$line])"
    return
  fi
  count="$(printf '%s' "$line" | grep -oE '[0-9]+件' | head -1 | tr -d '件')"
  names="$(printf '%s' "$line" | sed -E 's/.*[)）]: //')"
  n_names="$(printf '%s' "$names" | awk -F',' '{print NF}')"
  if [ "$count" != "$n_names" ]; then
    fail_case "$desc (件数表記=${count}件と実際の名前トークン数=${n_names}が不一致。行=[$line])"
    return
  fi
  case ",$names," in
    *",$role,"*) pass "$desc" ;;
    *) fail_case "$desc (名前一覧に $role が厳密一致で含まれない。行=[$line])" ;;
  esac
}

# write_models_conf_at <dir> — モデル定義ファイル（models.conf）を<dir>/
# models.conf へ書く（モデル定義ファイルと候補指定-設計-2026-09-08.md
# §2.3・§2.4）。schema 6のrole/fallback行は`model=<定義名>[,...]`で定義名を
# 参照するだけになったため、role.leaderの解決を伴うテストは全てこの定義
# ファイルを必要とする（無いとT7で解決不能になる）。tests/test-install-main.sh
# と同じ最小の定義セットを使う。
write_models_conf_at() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/models.conf" <<'EOF'
[sonnet-main]
provider=anthropic-api
model=claude-sonnet-5

[opus-main]
provider=anthropic-api
model=claude-opus-5
EOF
}

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  # 配役表-能力軸整理-設計-2026-09-07.md §3: schema 5・新3キーの実体を
  # あらかじめ置く。本ファイルの主眼＝Vault骨格配置・symlink化・機役割の
  # 案内ログの検証とは無関係なテストは、install-main.shの雛形配置
  # （config/profile.md.sample からのコピー。2026-09-08 本人裁定A案で
  # 読み元をvault-public/Preferences/profile-sample.mdから付け替え）に
  # 依存させない（テストの独立性）。seed_v1_profile()・seed_v2_profile()・
  # 個別のcat上書きで置き換えるテストはこの既定値を上書きする（後勝ち）。
  mkdir -p "$home/.config/takumi009-ai-env"
  write_models_conf_at "$home/.config/takumi009-ai-env"
  cat > "$home/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 6
profile_slug: test-install-sub-machine
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=sub
excluded_models: configured value=none
role.leader: configured model=sonnet-main
---
EOF
}

# 2026-09-01 配役表解凍（設計書§3.9）: v2雛形はrole.leaderがunknownのまま
# 配布されるため、リーダー配役が未確定のままinstall-main.sh（install-sub.sh
# 経由の委譲も含む）を対話・--non-interactiveいずれも指定せず実行すると
# 対話可否の判定で止まる。本ファイルの主眼＝Vault骨格配置・symlink化・
# 機役割の案内ログとは無関係なテストは、この既定値をexportしておくことで
# 「未確定→envの値を検査して採用（質問しない）」経路を常に通す。
export AIENV_LEADER_ROLE='model=sonnet-main'

# seed_v1_profile <home> — ローカル実体プロファイルを不在にする。
# 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.8・D-13）: legacy
# 実装（AIENV_MODEL_MAIN/AIENV_MODEL_SUB）への委譲は「実体が本当に存在しない
# （PROFILE_NOT_FOUND）」場合だけに縮小された——実在するがschema_versionを
# 持たない実体はT4-LEGACYとして解決失敗する（委譲されない）。そのため
# 「v1相当を強制する」とは、make_fake_home()が書いたprofile.mdを消して
# 不在にすることを意味する。
# 呼び出し側は必ずrun_v1_legacy_repo()経由でTMP_REPO（config/profile.md.sample
# を除いた実repoの複製）に対して実行すること（$REPO_ROOTを直接使うと、
# install-main.sh自身のP1雛形自動配置が実サンプルをコピーしてしまい、コピー後に
# 「実在するschema 6の実体」という別の非委譲ケースへ倒れて本テストの意図＝
# legacy値置換ロジックの検証を阻害するため）。
seed_v1_profile() {
  local home="$1"
  local dest="$home/.config/takumi009-ai-env/profile.md"
  [ -e "$dest" ] && command rm "$dest"
  return 0
}

# run_v1_legacy_repo() — config/profile.md.sampleを除いたrepoの複製を作り、
# そのパスを標準出力へ書く（seed_v1_profile()と対で使う。4b/4c/4d/4fの
# 共通前処理。2026-09-08 本人裁定A案で除外対象をvault-public/Preferences/
# profile-sample.mdからconfig/profile.md.sampleへ付け替え）。
run_v1_legacy_repo() {
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$tmp_repo/"
  command rm "$tmp_repo/config/profile.md.sample"
  printf '%s\n' "$tmp_repo"
}

# seed_v2_profile <home> — v2形式（schema_version:6・新3キー・role.leaderが
# configured）のプロファイルをあらかじめ置く。--check-profile系テスト
# （13・14番）で使う。role.leaderは既にconfiguredのため、AIENV_LEADER_ROLEの
# 値には依存しない。
seed_v2_profile() {
  local home="$1"
  local dest="$home/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$dest")"
  write_models_conf_at "$(dirname "$dest")"
  cat > "$dest" <<'EOF'
---
schema_version: 6
profile_slug: test
role.leader: configured model=opus-main
excluded_models: configured value=none
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=sub
---
EOF
}

echo "=== 1. dry-run: 実際の変更を一切しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)
  assert_true "dry-run出力にwould copyが含まれる" \
    "$(echo "$out" | grep -q 'would copy' && echo 1 || echo 0)"
  assert_true "Vaultが実際には作られていない" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian" ]] && echo 1 || echo 0)"
  assert_true "settings.jsonが実際にはsymlink化されていない" \
    "$([[ ! -e "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 2. Vault未存在: vault-public/の中身が骨格として配置される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_true "Preferencesの中身がコピーされている（absolute-rules.md存在）" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"
  for dir in Personal Knowledge Decisions Projects Fragments Explorations Blogs; do
    n=$(find "$FAKE_HOME/Data/obsidian/$dir" -mindepth 1 -not -name '.DS_Store' | wc -l | tr -d ' ')
    assert_eq "$dir はREADME.mdのみ（ファイル数1）" "1" "$n"
  done

  rm -rf "$FAKE_HOME"
}

echo "=== 3. Vault既存: 骨格配置をskipし、既存の中身を上書きしない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/Data/obsidian"
  echo "existing private note" > "$FAKE_HOME/Data/obsidian/my-note.md"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")
  assert_true "skipしますのメッセージが出る" \
    "$(echo "$out" | grep -q 'skipします' && echo 1 || echo 0)"
  assert_eq "既存ファイルの中身が変わっていない" "existing private note" \
    "$(cat "$FAKE_HOME/Data/obsidian/my-note.md")"
  assert_true "vault-publicのPreferencesが誤って混ざっていない" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian/Preferences" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4. claude/・codex/ の symlink化が install-main.sh 経由で行われる ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_eq "bootstrap-vault.shがrepoへのsymlinkになっている" "$REPO_ROOT/claude/hooks/bootstrap-vault.sh" \
    "$(readlink "$FAKE_HOME/.claude/hooks/bootstrap-vault.sh")"
  assert_true "settings.jsonが生成されている（symlinkではなく実ファイル。2026-08-21 機役割対応でsymlinkから変更）" \
    "$([[ -f "$FAKE_HOME/.claude/settings.json" && ! -L "$FAKE_HOME/.claude/settings.json" ]] && echo 1 || echo 0)"
  assert_true "config.tomlが生成されている（symlinkではなく実ファイル）" \
    "$([[ -f "$FAKE_HOME/.codex/config.toml" && ! -L "$FAKE_HOME/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4b. install-sub.sh 経由で生成されるsettings.jsonのmodelはサブ既定値(claude-opus-5・[1m]無し)に置換される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # v1相当に固定してlegacy委譲を強制する（本テストの主眼＝
  # AIENV_MODEL_MAIN/SUBの置換ロジックであり、v2配役表のリーダー確定とは
  # 無関係なため）。TMP_REPOはsample不在にして自動雛形配置を封じる
  # （seed_v1_profileのコメント参照）。
  seed_v1_profile "$FAKE_HOME"
  TMP_REPO="$(run_v1_legacy_repo)"

  env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" >/dev/null

  settings_content="$(cat "$FAKE_HOME/.claude/settings.json")"
  assert_true "modelがclaude-opus-5になっている" \
    "$(printf '%s' "$settings_content" | grep -q '"model": "claude-opus-5"' && echo 1 || echo 0)"
  assert_true "__AIENV_MODEL__プレースホルダが残っていない" \
    "$(printf '%s' "$settings_content" | grep -q '__AIENV_MODEL__' && echo 0 || echo 1)"
  assert_true "[1m]サフィックスは付かない（リーダー指示：サブはFable専用の1M contextを付けない）" \
    "$(printf '%s' "$settings_content" | grep -q '\[1m\]' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 4c. install-main.sh単体実行(--sub-delegate無し)で生成されるsettings.jsonのmodelはメイン既定値(claude-fable-5[1m])に置換される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  seed_v1_profile "$FAKE_HOME"
  TMP_REPO="$(run_v1_legacy_repo)"

  env -u AIENV_LEADER_ROLE SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-main.sh" >/dev/null

  settings_content="$(cat "$FAKE_HOME/.claude/settings.json")"
  assert_true "modelがclaude-fable-5[1m]になっている" \
    "$(printf '%s' "$settings_content" | grep -q '"model": "claude-fable-5\[1m\]"' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 4d. AIENV_MODEL_MAIN/AIENV_MODEL_SUB環境変数でmodel値を上書きできる（テスト用） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  seed_v1_profile "$FAKE_HOME"
  TMP_REPO="$(run_v1_legacy_repo)"

  env -u AIENV_LEADER_ROLE AIENV_MODEL_SUB="custom-test-model" SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" >/dev/null

  settings_content="$(cat "$FAKE_HOME/.claude/settings.json")"
  assert_true "AIENV_MODEL_SUBで上書きした値が反映される" \
    "$(printf '%s' "$settings_content" | grep -q '"model": "custom-test-model"' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 4e. settings.json生成後も他のキー（permissions等）はテンプレの中身を保っている（プレースホルダ以外は無変更であることの確認） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_true "permissions.allowの中身がテンプレ由来のまま含まれている" \
    "$(grep -q 'codex-exec.sh' "$FAKE_HOME/.claude/settings.json" && echo 1 || echo 0)"
  assert_true "生成物が有効なJSONとしてパースできる" \
    "$(python3 -c "import json; json.load(open('$FAKE_HOME/.claude/settings.json'))" 2>/dev/null && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4f. model値に引用符・バックスラッシュが含まれても壊れたJSONを生成しない（Codex一次レビュー指摘・Minor対応の回帰確認: sedプレースホルダ置換からpython3 json moduleでの直接キー代入へ変更した効果） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # v1相当に固定する（weird"model\valueはv2のmodel形式検証〈V9-b〉を
  # 通らないため、v2配役表経由では本テストの意図＝JSON生成側のエスケープ
  # 耐性を検証できない）。
  seed_v1_profile "$FAKE_HOME"
  TMP_REPO="$(run_v1_legacy_repo)"

  env -u AIENV_LEADER_ROLE AIENV_MODEL_SUB='weird"model\value' SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" >/dev/null

  assert_true "生成物が有効なJSONとしてパースできる（引用符・バックスラッシュを含む値でも壊れない）" \
    "$(python3 -c "import json; json.load(open('$FAKE_HOME/.claude/settings.json'))" 2>/dev/null && echo 1 || echo 0)"
  assert_true "model値が完全一致で読み戻せる" \
    "$(python3 -c "
import json
d = json.load(open('$FAKE_HOME/.claude/settings.json'))
print(1 if d.get('model') == 'weird\"model\\\\value' else 0)
" 2>/dev/null)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 5. LaunchAgent類は一切インストールされない（メイン専用機能に加え、旧サブ専用の定期自動pull運用も2026-07-23廃止済み） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")

  assert_true "Library/LaunchAgents/ ディレクトリ自体が作られない（何も設置しないため）" \
    "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents" ]] && echo 1 || echo 0)"
  for name in backup-vault vault-inventory fragments-log drift-check update-sub sub-update; do
    assert_true "$name.plist は入らない" \
      "$([[ ! -e "$FAKE_HOME/Library/LaunchAgents/com.takumi009.$name.plist" ]] && echo 1 || echo 0)"
  done
  assert_true "launchagents/ 配下にサブ用plistのソース自体がもう存在しない（撤去済み）" \
    "$([[ ! -e "$REPO_ROOT/launchagents/com.takumi009.update-sub.plist" ]] && echo 1 || echo 0)"
  assert_true "廃止済みの旨のログが出る" \
    "$(echo "$out" | grep -q "定期更新LaunchAgentも廃止済み" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 6. 冪等性: 2回実行してもエラーにならず状態が壊れない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null
  rc=0
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null || rc=$?
  assert_eq "2回目もexit 0" "0" "$rc"
  assert_true "2回目もVaultのPreferencesは健在" \
    "$([[ -f "$FAKE_HOME/Data/obsidian/Preferences/absolute-rules.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 7. 機役割の案内: 実行すると machine_role を本人が書くよう促す案内ログが1行出る（実体は書き換えない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE="$FAKE_HOME/.config/takumi009-ai-env/profile.md"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")

  assert_true "案内ログが出る" \
    "$(echo "$out" | grep -qF 'machine_role: configured value=sub を1行書いてください' && echo 1 || echo 0)"
  assert_true "案内ログに実体プロファイルの実パスが出る" \
    "$(echo "$out" | grep -qF "$PROFILE" && echo 1 || echo 0)"
  assert_true "本スクリプトは実体を書き換えない旨も明示される" \
    "$(echo "$out" | grep -q '本スクリプトは実体を書き換えません' && echo 1 || echo 0)"
  # 2026-09-08 Codexレビュー指摘・MINOR対応（差し戻しA案6巡目）: 「実体を
  # 書き換えない」という部分文字列だけでは、「既存の実体は対象・不在時は
  # config/profile.md.sampleから新規作成する」という限定の有無を区別できず、
  # この限定を誤って削除する回帰を検出できない。両方の限定句も検査する。
  assert_true "「既存の実体が対象」という限定が明示される" \
    "$(echo "$out" | grep -q '既存の実体が対象' && echo 1 || echo 0)"
  assert_true "「不在時はconfig/profile.md.sampleから新規作成」という限定が明示される" \
    "$(echo "$out" | grep -q 'config/profile.md.sampleからの新規作成' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 7b. 機役割の案内: AIENV_LOCAL_PROFILE_PATHが未設定でもset -euo pipefail下で案内ログまで到達する（配役表-能力軸整理-設計-2026-09-07.md §5.1） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  rc=0
  out="$(env -u AIENV_LOCAL_PROFILE_PATH SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "AIENV_LOCAL_PROFILE_PATH未設定でも案内ログが出る（既定値の初期化位置が案内ログより前にある）" \
    "$(echo "$out" | grep -qF 'machine_role: configured value=sub を1行書いてください' && echo 1 || echo 0)"
  assert_true "unbound variableで落ちていない" \
    "$(echo "$out" | grep -qi 'unbound variable' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 10. §3.9対話フラグの転送: --non-interactiveがinstall-main.shへ転送される（追完・2026-09-01リーダー指示） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # 本テストの主眼＝role.leaderが未確定のときの対話可否判定であり、
  # make_fake_home()の既定プロファイル（role.leader確定済み）を
  # role.leader未確定へ上書きする。
  cat > "$FAKE_HOME/.config/takumi009-ai-env/profile.md" <<'EOF'
---
schema_version: 6
profile_slug: test-install-sub-machine
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=sub
excluded_models: configured value=none
role.leader: unknown
---
EOF

  # ⚠️ AIENV_FORCE_TTY_FOR_TESTで対話可能を強制したうえで--non-interactive
  # を渡す（2026-09-01 Codex差分レビュー指摘・MAJOR対応: コマンド置換自体が
  # 非TTYのため、これを付けないと「単に非TTYだから失敗した」のか「転送された
  # --non-interactiveが優先されたから失敗した」のかを区別できず、転送処理
  # そのものを削除してもテストが偽陽性で通ってしまう）。
  rc=0
  out="$(env -u AIENV_LEADER_ROLE AIENV_FORCE_TTY_FOR_TEST=1 SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --non-interactive 2>&1)" || rc=$?
  assert_true "exit非0（--non-interactiveがinstall-main.shへ転送されTTY強制より優先される）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "LEADER_UNCONFIGURED_NONINTERACTIVEが出る" \
    "$(echo "$out" | grep -q 'LEADER_UNCONFIGURED_NONINTERACTIVE' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 11. §3.9対話フラグの転送: --reconfigure-leaderがinstall-main.shへ転送される（追完・2026-09-01リーダー指示） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  PROFILE_PATH="$FAKE_HOME/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$PROFILE_PATH")"
  cat > "$PROFILE_PATH" <<'EOF'
---
schema_version: 6
profile_slug: test
role.leader: configured model=opus-main
excluded_models: configured value=none
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=sub
---
EOF

  rc=0
  AIENV_LEADER_ROLE='model=sonnet-main' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --reconfigure-leader >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "--reconfigure-leaderがinstall-main.shへ転送され、AIENV_LEADER_ROLEの新しい値が採用される" \
    "$(grep -qE '^role\.leader:.*configured model=sonnet-main' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 12. install-main.shへの委譲が非0終了(設計書S4)でも、機役割の案内ログ等の後続処理は完走したうえで最終的に非0終了する（2026-09-01 Codex差分レビュー指摘・MAJOR対応の設計を2026-09-07にmachine_role案内ログへ引き継いだ: 裸呼び出しだとset -eで案内ログ出力前に即終了していた） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  # bedrock.envのパスをディレクトリにして、install-main.sh側のsettings.json
  # 生成だけを確実に失敗させる（設計書S4・install-main.sh側で非0終了する
  # ようになった状態を再現する）。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "install-sub.sh全体は非0終了する（install-mainの非0を伝播）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "機役割の案内ログは出る（後続処理が完走している）" \
    "$(echo "$out" | grep -qF 'machine_role: configured value=sub を1行書いてください' && echo 1 || echo 0)"
  assert_true "委譲が非0終了した旨のWARNが出る" \
    "$(echo "$out" | grep -q 'install-main.sh への委譲が非0終了しました' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 13. --check-profile: install-main.sh へ転送され、直接呼び出しと同じ結果を返す・副作用ゼロ（2026-09-02追加） ==="
{
  FAKE_HOME_SUB="$(mktemp -d)"
  make_fake_home "$FAKE_HOME_SUB"
  seed_v2_profile "$FAKE_HOME_SUB"
  FAKE_HOME_MAIN="$(mktemp -d)"
  make_fake_home "$FAKE_HOME_MAIN"
  seed_v2_profile "$FAKE_HOME_MAIN"
  # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§5.2 FR-19①）:
  # --check-profileはモデル定義ファイルの絶対パスを1行ログへ出すようになった。
  # $FAKE_HOME_SUB/$FAKE_HOME_MAINはmktempで異なる絶対パスになるため、
  # AIENV_MODEL_DEFS_FILEを共通の1ファイルへ固定し、出力の完全一致比較が
  # HOMEの違いだけに左右されないようにする。
  SHARED_MODEL_DEFS_DIR="$(mktemp -d)"
  write_models_conf_at "$SHARED_MODEL_DEFS_DIR"
  SHARED_MODEL_DEFS="$SHARED_MODEL_DEFS_DIR/models.conf"

  rc_sub=0
  out_sub="$(AIENV_MODEL_DEFS_FILE="$SHARED_MODEL_DEFS" HOME="$FAKE_HOME_SUB" bash "$SCRIPT" --check-profile 2>&1)" || rc_sub=$?
  rc_main=0
  out_main="$(AIENV_MODEL_DEFS_FILE="$SHARED_MODEL_DEFS" HOME="$FAKE_HOME_MAIN" bash "$REPO_ROOT/scripts/install-main.sh" --check-profile 2>&1)" || rc_main=$?

  assert_eq "install-sub.sh経由もexit code 0" "0" "$rc_sub"
  assert_eq "exit codeがinstall-main.sh直接呼び出しと一致" "$rc_main" "$rc_sub"
  assert_eq "出力がinstall-main.sh直接呼び出しと完全一致" "$out_main" "$out_sub"
  assert_true "OK行が出る" "$(echo "$out_sub" | grep -q '^OK' && echo 1 || echo 0)"
  assert_true "Vaultは作られない（副作用ゼロ・step1をskip）" \
    "$([[ ! -e "$FAKE_HOME_SUB/Data/obsidian" ]] && echo 1 || echo 0)"
  assert_true "機役割の案内ログは出ない（副作用ゼロ・step5をskip）" \
    "$(echo "$out_sub" | grep -qF 'machine_role: configured value=sub を1行書いてください' && echo 0 || echo 1)"
  assert_true "settings.json・config.tomlも生成されない（step2の委譲先でcheck-profileが自身exitするため）" \
    "$([[ ! -e "$FAKE_HOME_SUB/.claude/settings.json" && ! -e "$FAKE_HOME_SUB/.codex/config.toml" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME_SUB" "$FAKE_HOME_MAIN" "$SHARED_MODEL_DEFS_DIR"
}

echo "=== 13b. --check-profile: 不正プロファイル（role.leader重複=T6）でも非0終了コード・エラー内容がinstall-main.sh直接呼び出しと一致する・副作用ゼロ（Codex一次レビュー指摘・Minor対応: 正常系だけでは委譲先の非0を誤ってexit 0へ変換する回帰を検出できないため） ==="
{
  FAKE_HOME_SUB="$(mktemp -d)"
  make_fake_home "$FAKE_HOME_SUB"
  FAKE_HOME_MAIN="$(mktemp -d)"
  make_fake_home "$FAKE_HOME_MAIN"
  invalid_profile='---
schema_version: 6
profile_slug: test
role.leader: unknown
role.leader: configured model=opus-main
excluded_models: configured value=none
team_mode: configured value=full
no_read_paths: unavailable
machine_role: configured value=sub
---'
  # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§5.2 FR-19①）:
  # --check-profileはlist-roles呼び出しより前にモデル定義ファイルの絶対パスを
  # 1行ログへ出すため、T6検出前でもこの行が出力に含まれる。$FAKE_HOME_SUBと
  # $FAKE_HOME_MAINで絶対パスが異なると完全一致比較が壊れるため、
  # AIENV_MODEL_DEFS_FILEを共通の1ファイルへ固定する（テスト13と同じ方針）。
  SHARED_MODEL_DEFS_DIR="$(mktemp -d)"
  write_models_conf_at "$SHARED_MODEL_DEFS_DIR"
  SHARED_MODEL_DEFS="$SHARED_MODEL_DEFS_DIR/models.conf"
  for h in "$FAKE_HOME_SUB" "$FAKE_HOME_MAIN"; do
    mkdir -p "$h/.config/takumi009-ai-env"
    printf '%s\n' "$invalid_profile" > "$h/.config/takumi009-ai-env/profile.md"
  done

  rc_sub=0
  out_sub="$(AIENV_MODEL_DEFS_FILE="$SHARED_MODEL_DEFS" HOME="$FAKE_HOME_SUB" bash "$SCRIPT" --check-profile 2>&1)" || rc_sub=$?
  rc_main=0
  out_main="$(AIENV_MODEL_DEFS_FILE="$SHARED_MODEL_DEFS" HOME="$FAKE_HOME_MAIN" bash "$REPO_ROOT/scripts/install-main.sh" --check-profile 2>&1)" || rc_main=$?

  assert_true "install-sub.sh経由も非0終了する（委譲先の非0をexit 0へ握り潰さない）" \
    "$([[ "$rc_sub" -ne 0 ]] && echo 1 || echo 0)"
  assert_eq "exit codeがinstall-main.sh直接呼び出しと一致" "$rc_main" "$rc_sub"
  assert_eq "エラー内容(PROFILE_INVALID:T6)がinstall-main.sh直接呼び出しと完全一致" "$out_main" "$out_sub"
  assert_true "PROFILE_INVALID:T6が出る" \
    "$(echo "$out_sub" | grep -q 'PROFILE_INVALID:T6' && echo 1 || echo 0)"
  assert_true "Vaultは作られない（副作用ゼロ）" \
    "$([[ ! -e "$FAKE_HOME_SUB/Data/obsidian" ]] && echo 1 || echo 0)"
  assert_true "機役割の案内ログは出ない（副作用ゼロ）" \
    "$(echo "$out_sub" | grep -qF 'machine_role: configured value=sub を1行書いてください' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME_SUB" "$FAKE_HOME_MAIN" "$SHARED_MODEL_DEFS_DIR"
}

echo "=== 14. --check-profile --print-schema-version: install-sub.sh経由でもschema_versionの値だけを1行返す・副作用ゼロ（2026-09-02追加） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  seed_v2_profile "$FAKE_HOME"

  rc=0
  out="$(HOME="$FAKE_HOME" bash "$SCRIPT" --check-profile --print-schema-version 2>&1)" || rc=$?

  assert_eq "exit code 0" "0" "$rc"
  assert_eq "schema_versionの値だけを1行返す（見出しログ等が混ざらない）" "6" "$out"
  assert_true "Vaultは作られない（副作用ゼロ）" \
    "$([[ ! -e "$FAKE_HOME/Data/obsidian" ]] && echo 1 || echo 0)"
  assert_true "機役割の案内ログは出ない（副作用ゼロ）" \
    "$(echo "$out" | grep -qF 'machine_role: configured value=sub を1行書いてください' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

# --- 前提修正 P-2 の回帰テスト（2026-09-07）: install-sub.sh 経由（install-main.sh
#     への委譲）でも職種定義の配布結果が同じ固定文で報告されることを確認する
#     （設計§2.2「3本すべて」）。DIR は install-sub.sh 自身の場所から算出され
#     install-main.sh もそのDIR配下を呼ぶため、TMP_REPO（実repoの丸ごとcopy）を
#     使えばそのまま install-sub.sh 経由の委譲を検証できる。 ---

echo "=== 15. PA-4: install-sub.sh 経由でも repo に定義を1本足すと symlink ができ、AGENTS: 初回未配置 の固定文に名前が出る（終了コード0） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  echo "# PA-4 用の追加ロール定義（テスト専用・内容は問わない）" > "$TMP_REPO/claude/agents/test-pa4-role.md"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "追加したロールのsymlinkができる" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa4-role.md" ]] && echo 1 || echo 0)"
  assert_agents_line "AGENTS: 初回未配置 の固定文にtest-pa4-roleが厳密一致で出る（件数・句読点も検査）" \
    "$out" "初回未配置" "test-pa4-role"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 16. PA-5: install-sub.sh 経由でも repo から定義を1本消すと AGENTS: dangling の固定文に名前が出て終了コードが非0（symlink自体は消えない） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  echo "# PA-5 用の一時ロール定義（次に削除する）" > "$TMP_REPO/claude/agents/test-pa5-role.md"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" >/dev/null 2>&1
  assert_true "前提: baseline実行でsymlinkができている" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa5-role.md" ]] && echo 1 || echo 0)"

  rm -f "$TMP_REPO/claude/agents/test-pa5-role.md"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" 2>&1)" || rc=$?
  assert_true "終了コードが非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_agents_line "AGENTS: dangling の固定文にtest-pa5-roleが厳密一致で出る（件数・句読点も検査）" \
    "$out" "dangling" "test-pa5-role"
  assert_true "symlink自体は消えない（本人判断・削除しない方針）" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa5-role.md" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 17. PA-6: install-sub.sh 経由で追加もdanglingも無ければ AGENTS: 行が出ず終了コード0 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" >/dev/null 2>&1

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" 2>&1)" || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "AGENTS: 行が一切出ない" \
    "$(echo "$out" | grep -q '\[install-main\] AGENTS:' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo "=== 18. PA-12: install-sub.sh 経由でも追加と削除の複合ケースで両方の固定文が出て新規は配置・旧は残存・終了コード非0 ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  TMP_REPO="$(mktemp -d)"
  cp -R "$REPO_ROOT/." "$TMP_REPO/"
  echo "# PA-12 用の退役予定ロール（1回目は存在・2回目に消す）" > "$TMP_REPO/claude/agents/test-pa12-old-role.md"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" >/dev/null 2>&1
  assert_true "前提: old-role がbaselineで配置されている" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa12-old-role.md" ]] && echo 1 || echo 0)"

  rm -f "$TMP_REPO/claude/agents/test-pa12-old-role.md"
  echo "# PA-12 用の新設ロール" > "$TMP_REPO/claude/agents/test-pa12-new-role.md"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$TMP_REPO/scripts/install-sub.sh" 2>&1)" || rc=$?

  assert_agents_line "① AGENTS: 初回未配置 に new-role が厳密一致で出る" \
    "$out" "初回未配置" "test-pa12-new-role"
  assert_agents_line "② AGENTS: dangling に old-role が厳密一致で出る" \
    "$out" "dangling" "test-pa12-old-role"
  assert_true "③ new-role のsymlinkが作られている" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa12-new-role.md" ]] && echo 1 || echo 0)"
  assert_true "④ old-role のsymlinkは残っている（削除しない）" \
    "$([[ -L "$FAKE_HOME/.claude/agents/test-pa12-old-role.md" ]] && echo 1 || echo 0)"
  assert_true "⑤ 終了コードが非0" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$TMP_REPO"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
