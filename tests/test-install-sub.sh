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
# skip実装＝H-2は撤去に伴い不要化した）。install-sub.sh は install-main.sh 経由で
# scripts/setup-codex-mcp.sh も呼ぶため、実 claude/codex CLI がPATH上にある開発機で
# テストを走らせた場合の実MCP登録への副作用を避けるため SKIP_CODEX_MCP=1 を付ける
# （Codexレビュー指摘・Major）。SKIP_LAUNCHCTL=1 も一部テストで付けているが、これは
# 委譲先の install-main.sh 自身が同名の環境変数を宣言しているための互換目的で
# あり、install-sub.sh 自体は現在launchctlを一切呼び出さない（下記2026-07-23の
# 変更で撤去済み）。
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
# machine-roleマーカーファイル（積極的な証明）方式へ変更した（リーダー裁定・
# Codex一次レビュー指摘Major対応）。7〜9番でこのマーカー設置を検証する。
#
# 2026-08-21: claude/settings.json を symlink から「テンプレ+生成」方式へ変更した
# （codex/config.tomlと同型。理由: JSONもシェル変数展開されない・symlinkのままだと
# セッション内`/model`実行時にClaude Code自身がrepo管理下のファイルを直接書き換えて
# しまう副作用があった）。"model"フィールドはマシン別（メイン=claude-fable-5[1m]・
# サブ=claude-opus-5。サブはProプランでFable 5非対応、[1m]も付けない＝リーダー指示）
# に出し分ける。決定は--sub-delegateの有無（＝install-sub.sh経由か直接実行か）から
# 直接行われ、machine-roleマーカーの読み返しには依存しない。4番を旧来のsymlink検証
# から生成物検証へ更新し、4b〜4eでmodel出し分け・環境変数上書き・内容保持を追加検証する。
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

make_fake_home() {
  local home="$1"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
}

# 2026-09-01 配役表解凍（設計書§3.9）: v2雛形はrole.leaderがunknownのまま
# 配布されるため、リーダー配役が未確定のままinstall-main.sh（install-sub.sh
# 経由の委譲も含む）を対話・--non-interactiveいずれも指定せず実行すると
# 対話可否の判定で止まる。本ファイルの主眼＝Vault骨格配置・symlink化・
# machine-roleマーカーとは無関係なテストは、この既定値をexportしておくことで
# 「未確定→envの値を検査して採用（質問しない）」経路を常に通す。
export AIENV_LEADER_ROLE='provider=anthropic-api model=claude-sonnet-5'

# seed_v1_profile <home> — v1形式（schema_version・role.*行を持たない7キー
# のみ）のプロファイルをあらかじめ置く。§4.2-a「v1と分類されたらlegacy実装
# （AIENV_MODEL_MAIN/AIENV_MODEL_SUB）へ委譲する」経路を強制し、
# AIENV_LEADER_ROLEやv2の対話確定を経由させたくないテスト
# （model値そのものの置換ロジックを検証する4b/4c/4d/4f）で使う。
seed_v1_profile() {
  local home="$1"
  local dest="$home/.config/takumi009-ai-env/profile.md"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'EOF'
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
  assert_true "settings.jsonが生成されている（symlinkではなく実ファイル。2026-08-21 machine-role対応でsymlinkから変更）" \
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
  # 無関係なため）。
  seed_v1_profile "$FAKE_HOME"

  env -u AIENV_LEADER_ROLE SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  settings_content="$(cat "$FAKE_HOME/.claude/settings.json")"
  assert_true "modelがclaude-opus-5になっている" \
    "$(printf '%s' "$settings_content" | grep -q '"model": "claude-opus-5"' && echo 1 || echo 0)"
  assert_true "__AIENV_MODEL__プレースホルダが残っていない" \
    "$(printf '%s' "$settings_content" | grep -q '__AIENV_MODEL__' && echo 0 || echo 1)"
  assert_true "[1m]サフィックスは付かない（リーダー指示：サブはFable専用の1M contextを付けない）" \
    "$(printf '%s' "$settings_content" | grep -q '\[1m\]' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4c. install-main.sh単体実行(--sub-delegate無し)で生成されるsettings.jsonのmodelはメイン既定値(claude-fable-5[1m])に置換される ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  seed_v1_profile "$FAKE_HOME"

  env -u AIENV_LEADER_ROLE SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install-main.sh" >/dev/null

  settings_content="$(cat "$FAKE_HOME/.claude/settings.json")"
  assert_true "modelがclaude-fable-5[1m]になっている" \
    "$(printf '%s' "$settings_content" | grep -q '"model": "claude-fable-5\[1m\]"' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4d. AIENV_MODEL_MAIN/AIENV_MODEL_SUB環境変数でmodel値を上書きできる（テスト用） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  seed_v1_profile "$FAKE_HOME"

  env -u AIENV_LEADER_ROLE AIENV_MODEL_SUB="custom-test-model" SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  settings_content="$(cat "$FAKE_HOME/.claude/settings.json")"
  assert_true "AIENV_MODEL_SUBで上書きした値が反映される" \
    "$(printf '%s' "$settings_content" | grep -q '"model": "custom-test-model"' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 4e. settings.json生成後も他のキー（permissions等）はテンプレの中身を保っている（プレースホルダ以外は無変更であることの確認） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_true "permissions.allowの中身がテンプレ由来のまま含まれている" \
    "$(grep -q 'mcp__codex__codex' "$FAKE_HOME/.claude/settings.json" && echo 1 || echo 0)"
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

  env -u AIENV_LEADER_ROLE AIENV_MODEL_SUB='weird"model\value' SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_true "生成物が有効なJSONとしてパースできる（引用符・バックスラッシュを含む値でも壊れない）" \
    "$(python3 -c "import json; json.load(open('$FAKE_HOME/.claude/settings.json'))" 2>/dev/null && echo 1 || echo 0)"
  assert_true "model値が完全一致で読み戻せる" \
    "$(python3 -c "
import json
d = json.load(open('$FAKE_HOME/.claude/settings.json'))
print(1 if d.get('model') == 'weird\"model\\\\value' else 0)
" 2>/dev/null)"

  rm -rf "$FAKE_HOME"
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

echo "=== 7. machine-roleマーカー: 実行すると \$HOME/.config/takumi009-ai-env/machine-role に「sub」が書き込まれる ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"

  out=$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT")

  assert_true "マーカーファイルが作られる" "$([[ -f "$MARKER" ]] && echo 1 || echo 0)"
  assert_eq "マーカーの中身が「sub」" "sub" "$(cat "$MARKER" | tr -d '[:space:]')"
  assert_true "設置した旨のログが出る" \
    "$(echo "$out" | grep -q "machine-role マーカーを設置しました" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 7b. machine-roleマーカー: --dry-run では書き込まれない ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"

  out=$(HOME="$FAKE_HOME" bash "$SCRIPT" --dry-run)

  assert_true "マーカーファイルは作られない" "$([[ ! -e "$MARKER" ]] && echo 1 || echo 0)"
  assert_true "would writeのdry-runログが出る" \
    "$(echo "$out" | grep -q 'would write' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 8. machine-roleマーカー: install-main.sh単体実行(--sub-delegateを付けない直接実行)では「main」が書き込まれる（サブ機だった機体をメイン機へ移行する場合の旧「sub」マーカー上書き＝Codex一次レビュー指摘Major対応） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"

  SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install-main.sh" >/dev/null

  assert_true "install-main.sh単体実行ではマーカーファイルが作られる" \
    "$([[ -f "$MARKER" ]] && echo 1 || echo 0)"
  assert_eq "マーカーの中身が「main」" "main" "$(cat "$MARKER" | tr -d '[:space:]')"

  rm -rf "$FAKE_HOME"
}

echo "=== 8b. machine-roleマーカー: 旧「sub」マーカーが残っていても、install-main.sh単体実行なら「main」へ上書きされる（実際のサブ→メイン移行シナリオの再現） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"
  mkdir -p "$(dirname "$MARKER")"
  printf 'sub\n' > "$MARKER"

  SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install-main.sh" >/dev/null

  assert_eq "旧「sub」は「main」へ上書きされる" "main" "$(cat "$MARKER" | tr -d '[:space:]')"

  rm -rf "$FAKE_HOME"
}

echo "=== 8d. machine-roleマーカー: 直接実行の途中で後続処理が失敗しても、マーカーの「main」書込は他の全処理より先に完了している(Codex再レビュー指摘Major対応) ==="
{
  # 「後続処理より先にマーカーを確定させる」設計を検証するため、claude/ symlink化の
  # 最初の呼び出し(link()内のmkdir -p)がクラッシュするようFAKE_HOMEを壊す
  # （$HOME/.claudeを ディレクトリではなくファイルにしておくと、link()の
  # `mkdir -p "$(dirname "$dest")"` が失敗しset -eでスクリプト全体が停止する）。
  # 本物のリポジトリ(REPO_ROOT)には一切手を加えない。
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.codex"
  echo "not a directory" > "$FAKE_HOME/.claude"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"

  rc=0
  SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install-main.sh" >/dev/null 2>&1 || rc=$?
  assert_true "後続処理(claude/のsymlink化)は実際に失敗している(テスト前提の確認)" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "後続処理が失敗していてもマーカーは既に「main」で書き込まれている" \
    "$([[ -f "$MARKER" ]] && [[ "$(cat "$MARKER" | tr -d '[:space:]')" == "main" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 8c. machine-roleマーカー: install-main.shを--sub-delegate付きで呼ぶ経路(install-sub.sh経由)では、install-main.sh自身はマーカーに一切触れない ==="
{
  # install-sub.sh の最終ステップ(サブ用マーカー"sub"書込)より前に、委譲先の
  # install-main.shが誤って"main"を書いてから直後に"sub"で上書き…という
  # レースにならないことを保証する（設計上--sub-delegate経由では
  # install-main.shはmarker処理自体をまるごとskipする）。install-main.sh単体を
  # --sub-delegate付きで直接呼び、マーカーが一切作られないことを確認する。
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"

  SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install-main.sh" --sub-delegate >/dev/null

  assert_true "--sub-delegate経由ではinstall-main.sh自身はマーカーを作らない" \
    "$([[ ! -e "$MARKER" ]] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 9. machine-roleマーカー: 2回実行しても内容は「sub」のまま壊れない（冪等性） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"

  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null
  SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" >/dev/null

  assert_eq "2回目もマーカーの中身は「sub」のまま" "sub" "$(cat "$MARKER" | tr -d '[:space:]')"

  rm -rf "$FAKE_HOME"
}

echo "=== 10. §3.9対話フラグの転送: --non-interactiveがinstall-main.shへ転送される（追完・2026-09-01リーダー指示） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"

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
schema_version: 2
profile_slug: test
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
  AIENV_LEADER_ROLE='provider=anthropic-api model=claude-sonnet-5' \
    SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" --reconfigure-leader >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "--reconfigure-leaderがinstall-main.shへ転送され、AIENV_LEADER_ROLEの新しい値が採用される" \
    "$(grep -qE '^role\.leader:.*configured provider=anthropic-api model=claude-sonnet-5' "$PROFILE_PATH" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== 12. install-main.shへの委譲が非0終了(設計書S4)でも、machine-roleマーカー等の後続処理は完走したうえで最終的に非0終了する（2026-09-01 Codex差分レビュー指摘・MAJOR対応: 裸呼び出しだとset -eでmarker設置前に即終了していた） ==="
{
  FAKE_HOME="$(mktemp -d)"
  make_fake_home "$FAKE_HOME"
  MARKER="$FAKE_HOME/.config/takumi009-ai-env/machine-role"
  # bedrock.envのパスをディレクトリにして、install-main.sh側のsettings.json
  # 生成だけを確実に失敗させる（設計書S4・install-main.sh側で非0終了する
  # ようになった状態を再現する）。
  mkdir -p "$FAKE_HOME/.config/takumi009-ai-env/bedrock.env"

  rc=0
  out="$(SKIP_LAUNCHCTL=1 SKIP_CODEX_MCP=1 HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)" || rc=$?
  assert_true "install-sub.sh全体は非0終了する（install-mainの非0を伝播）" \
    "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
  assert_true "machine-roleマーカーは設置される（後続処理が完走している）" \
    "$([[ -f "$MARKER" ]] && [[ "$(cat "$MARKER" | tr -d '[:space:]')" == "sub" ]] && echo 1 || echo 0)"
  assert_true "委譲が非0終了した旨のWARNが出る" \
    "$(echo "$out" | grep -q 'install-main.sh への委譲が非0終了しました' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
