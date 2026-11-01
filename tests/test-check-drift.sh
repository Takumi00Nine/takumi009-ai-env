#!/usr/bin/env bash
# 配置・設定差分・未コミット・公開可視性・鮮度・秘匿を隔離 fixture で確認。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_REL="core/assembly/check-drift.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

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

# 形検査（値でなく形を見る＝Decisions/2026-09-17-tests-rough-not-strict）。
# symlink総数はSYMLINKS配列の増減で変わるため固定件数を判定に使わない。
assert_matches() {
  local desc="$1" haystack="$2" regex="$3"
  if [[ "$haystack" =~ $regex ]]; then
    pass "$desc"
  else
    fail_case "$desc (形が一致しない: /$regex/)"
  fi
}

# --jsonモード（設計書§1.2 maintenance.sh Phase1①向け）のJSONフィールド数値比較用。
assert_eq_num() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

# v1.2 束 C の追加分が使う汎用の等値・真偽（1/0）判定（既存の assert_eq_num・assert_contains とは別名）。

# 実際のフック（vault-recall.sh/vault-read-log.sh）は `date -u +...Z` でUTC時刻を
# 書く。テストのfixtureも同じくUTCで生成する（`-u`無しのローカル時刻に'Z'を付けた
# だけの値だと、check-drift.sh側の解析バグ〈N-5・ローカルTZとして誤解釈〉と
# 対称に間違えてしまい、テストがバグを覆い隠してしまうため＝2026-07-10
# 敵対的レビュー2回目 N-5 対応）。
d_ts() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"d +%Y-%m-%dT%H:%M:%SZ; }
# 最小構成の「repo」フィクスチャを作る（check-drift.shが参照する
# claude/・codex/・ai-brain/data/vault-public/・scripts/check-drift.sh本体だけをコピーする）。
make_fake_repo() {
  local repo="$1"
  mkdir -p "$repo/core/assembly" "$repo/core/connect/claude-code" "$repo/core/data" "$repo/core/executor" "$repo/team/rules/agents" "$repo/team/connect/claude-code" "$repo/team/connect/codex" "$repo/team/executor" "$repo/ai-brain/executor" "$repo/ai-brain/connect/claude-code" "$repo/dock/executor" "$repo/usage/executor" "$repo/ai-brain/data/vault-public/Preferences"
  cp "$REPO_ROOT/$SCRIPT_REL" "$repo/core/assembly/check-drift.sh"
  chmod +x "$repo/core/assembly/check-drift.sh"
  # T-C2: check-drift.sh ①（配置の健全性）は core/assembly/ledger-tool.sh placement
  # から配置一覧を導出し、--forward-refs は core/data/moves.tsv・core/executor/vault-paths.sh
  # を読む＝正本は台帳1か所なので実物を複製する（stubは書かない）。
  cp "$REPO_ROOT/core/data/ledger.tsv" "$repo/core/data/ledger.tsv"
  cp "$REPO_ROOT/core/data/moves.tsv" "$repo/core/data/moves.tsv"
  cp "$REPO_ROOT/core/data/codex-app-managed.sh" "$repo/core/data/codex-app-managed.sh"
  cp "$REPO_ROOT/core/assembly/ledger-tool.sh" "$repo/core/assembly/ledger-tool.sh"
  chmod +x "$repo/core/assembly/ledger-tool.sh"
  cp "$REPO_ROOT/core/executor/vault-paths.sh" "$repo/core/executor/vault-paths.sh"
  # check-drift.sh ①-2 は model/effort値を自前で持たず、fixture内の
  # core/assembly/install-main.sh --render-settings-json（生成関数そのもの）に
  # 一時ファイルへ再生成させて比べる（2026-09-19 着手順3・設計 §4.2）。
  # 実物をfixtureへコピーする（--render-settings-json は他の全処理より先に
  # exitする経路で、生成先は呼び出し側の一時ファイルのみ＝fixture内で呼んでも
  # 実システムに一切触れない）。
  cp "$REPO_ROOT/core/assembly/install-main.sh" "$repo/core/assembly/install-main.sh"
  chmod +x "$repo/core/assembly/install-main.sh"
  # install-main.shが冒頭でscripts/lib/managed-symlink.shをsourceするため同梱する。
  mkdir -p "$repo/core/assembly"
  cp "$REPO_ROOT/core/assembly/managed-symlink.sh" "$repo/core/assembly/managed-symlink.sh"
  mkdir -p "$repo/team/executor"
  # install_fake_home() が置くv2プロファイルを resolver（実物）で解決する。
  cp "$REPO_ROOT/team/executor/profile_resolve.py" "$repo/team/executor/profile_resolve.py"
  cat > "$repo/core/assembly/settings.json" <<'EOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "300000",
    "CTX_REWARN_STEP": "50000"
  },
  "permissions": {
    "allow": ["Bash(npm test)"]
  },
  "model": "__AIENV_MODEL__",
  "effortLevel": "__AIENV_EFFORT__"
}
EOF
  echo '#!/bin/bash' > "$repo/core/connect/claude-code/session-start-compose.sh"
  echo '#!/bin/bash' > "$repo/team/connect/claude-code/delegation-gate-v2.sh"
  echo '#!/bin/bash' > "$repo/core/connect/claude-code/bash-danger-gate.sh"
  echo '#!/bin/bash' > "$repo/core/connect/claude-code/bash-policy-gate.sh"
  echo '#!/bin/bash' > "$repo/ai-brain/executor/vault-recall.sh"
  echo '#!/bin/bash' > "$repo/ai-brain/executor/vault-read-log.sh"
  echo '#!/bin/bash' > "$repo/dock/executor/dock-pane-resolve.sh"
  echo '#!/bin/bash' > "$repo/core/assembly/check-sub-update.sh"
  echo '#!/bin/bash' > "$repo/core/connect/claude-code/context-size-warn.sh"
  echo '#!/bin/bash' > "$repo/team/connect/claude-code/inprocess-gate.sh"
  echo '#!/bin/bash' > "$repo/usage/executor/usage-inject.sh"
  # 実台帳の配置行（9列目）にある残り2本＝real ledger.tsv に合わせて追加
  # （本体は実装と無関係のstub。正本はコピーした台帳側）。
  echo '#!/bin/bash' > "$repo/core/connect/claude-code/prompt-answer.sh"
  chmod +x "$repo"/*/executor/*.sh "$repo"/*/connect/*/*.sh "$repo"/core/assembly/check-sub-update.sh
  echo '# agent' > "$repo/team/rules/agents/sample-agent.md"
  echo '# AGENTS' > "$repo/team/connect/codex/AGENTS.md"
  echo '{}' > "$repo/team/connect/codex/hooks.json"
  cat > "$repo/team/connect/codex/config.toml" <<'EOF'
service_tier = "default"
[mcp_servers.obsidian]
args = ["__AIENV_HOME__/Data/obsidian"]
EOF
  echo "# サンプル方針" > "$repo/ai-brain/data/vault-public/Preferences/sample.md"
}

# claude/・codex/ の symlink化（install-main.sh相当を簡易に再現）＋config.toml
# 生成を行う。settings.json は本物の生成関数（fixtureへコピーした
# core/assembly/install-main.sh --render-settings-json）で作る＝check-drift ①-2 が
# 同じ入力口で再生成した生成物と一致する陰性コントロールになる（2026-09-19
# 着手順3・設計 §4.2）。プロファイル（role.leader=fable-1m-high・
# machine_role=main）とモデル定義は $home/.config/takumi009-ai-env/ に置く
# （呼び出し元が先に置いていれば上書きしない）。
install_fake_home() {
  local repo="$1" home="$2"
  mkdir -p "$home/.claude/hooks" "$home/.claude/agents" "$home/.codex"
  if [ ! -e "$home/.config/takumi009-ai-env/profile.md" ]; then
    write_clean_profile "$home/.config/takumi009-ai-env/profile.md"
  fi
  render_settings_json "$repo" "$home" "$home/.claude/settings.json"
  ln -s "$repo/core/connect/claude-code/session-start-compose.sh" "$home/.claude/hooks/bootstrap-vault.sh"
  ln -s "$repo/team/connect/claude-code/delegation-gate-v2.sh" "$home/.claude/hooks/delegation-gate-v2.sh"
  ln -s "$repo/core/connect/claude-code/bash-danger-gate.sh" "$home/.claude/hooks/bash-danger-gate.sh"
  ln -s "$repo/core/connect/claude-code/bash-policy-gate.sh" "$home/.claude/hooks/bash-policy-gate.sh"
  ln -s "$repo/ai-brain/executor/vault-recall.sh" "$home/.claude/hooks/vault-recall.sh"
  ln -s "$repo/ai-brain/executor/vault-read-log.sh" "$home/.claude/hooks/vault-read-log.sh"
  ln -s "$repo/dock/executor/dock-pane-resolve.sh" "$home/.claude/hooks/dock-pane-resolve.sh"
  ln -s "$repo/core/assembly/check-sub-update.sh" "$home/.claude/hooks/check-sub-update.sh"
  ln -s "$repo/core/connect/claude-code/context-size-warn.sh" "$home/.claude/hooks/context-size-warn.sh"
  ln -s "$repo/team/connect/claude-code/inprocess-gate.sh" "$home/.claude/hooks/inprocess-gate.sh"
  ln -s "$repo/usage/executor/usage-inject.sh" "$home/.claude/hooks/usage-inject.sh"
  ln -s "$repo/core/connect/claude-code/prompt-answer.sh" "$home/.claude/hooks/code27-call-clear.sh"
  ln -s "$repo/team/rules/agents/sample-agent.md" "$home/.claude/agents/sample-agent.md"
  ln -s "$repo/team/connect/codex/AGENTS.md" "$home/.codex/AGENTS.md"
  ln -s "$repo/team/connect/codex/hooks.json" "$home/.codex/hooks.json"
  # install-main.sh の generate_config_toml() と同じくエスケープしてから置換する
  # （$home に # を含むテスト（1b）で、エスケープ無しだと置換自体が壊れて
  # 「正しく生成されたはずのconfig.tomlがテンプレと不一致」という偽陽性になるため）。
  local escaped_home
  escaped_home=$(printf '%s' "$home" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$repo/team/connect/codex/config.toml" > "$home/.codex/config.toml"
}

# write_clean_profile <dest> — ⑧（--check-profile）でadvisory・未知キーが出ない
# 最小のv2プロファイル（role表＝leader＋コア職種manifest〈navi・ja-doc〉＋
# fixtureのclaude/agents/sample-agent.md）。⑧の陽性ケースは各テストが
# write_v2_profile() で上書きする。
write_clean_profile() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  {
    echo "---"
    echo "schema_version: 7"
    echo "profile_slug: test"
    echo "team_mode: configured value=full"
    echo "no_read_paths: unavailable"
    echo "role.leader: configured model=fable-1m-high"
    echo "role.navi: not_adopted"
    echo "role.ja-doc: not_adopted"
    echo "role.sample-agent: configured model=fable-1m-high"
    echo "machine_role: configured value=main"
    echo "---"
  } > "$dest"
  write_model_defs "$(dirname "$dest")/models.conf"
}

# render_settings_json <repo> <home> <dest> — fixtureの install-main.sh に
# settings.json を生成させる（HOMEを偽HOMEへ向ける＝実 ~/.claude には触れない。
# プロファイル・モデル定義は $home/.config/takumi009-ai-env/ から読まれる）。
render_settings_json() {
  local repo="$1" home="$2" dest="$3"
  SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 HOME="$home" bash "$repo/core/assembly/install-main.sh" --render-settings-json "$dest" >/dev/null 2>&1
}

run_check() {
  # bash 3.2（macOSシステムbash）では、同一 `local` 文中で直前に代入した変数を
  # 続く代入の右辺で参照すると、set -u下で「unbound variable」になる既知の癖がある
  # （実測: `local a=1 b=$a` は b=$a の評価時点で a が未束縛扱いになるケースがある）。
  # 各代入を別行に分けて回避する。
  local repo="$1"
  local home="$2"
  local vault="${3:-$home/Data/obsidian}"
  DIR="$repo" HOME="$home" VAULT="$vault" bash "$repo/core/assembly/check-drift.sh"
}

# --jsonモード版run_check（2026-07-16簡素化・設計書§1.2 maintenance.sh Phase1①向け）。
run_check_json() {
  local repo="$1"
  local home="$2"
  local vault="${3:-$home/Data/obsidian}"
  DIR="$repo" HOME="$home" VAULT="$vault" bash "$repo/core/assembly/check-drift.sh" --json
}

# --jsonモード出力の最終行（JSON本体）だけを取り出す。
last_line() { printf '%s\n' "$1" | tail -1; }

# JSON中の特定フィールドの数値を取り出す（python3使用。テストの依存を増やさず
# 既存のtests/配下の他ファイルもpython3を前提にしているため合わせる）。
json_field() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])" "$1" "$2"; }

# 偽launchctl（実launchdには一切触れない）。check-drift.sh ⑥のmaintenance新鮮度
# チェックがlaunchctl printを呼ぶようになったため（リーダー裁定2026-07-16
# 「(a) plist存在＋launchctl登録」対応・check-drift.sh初のlaunchctl呼び出し）、
# 本ファイルの全テストで実launchctlに一切触れないよう、PATH先頭へ既定で
# 差し込む（scripts/install-maintenance.sh等の偽launchctlパターンを踏襲）。
# 既定は「print常に失敗＝未ロード」の安全側。個別テストで「ロード済み」を
# 模擬したい場合はFAKE_LAUNCHCTL_LOADED_LABELSにラベル名を設定してから
# refresh_fake_launchctl を呼び直す。
# ⚠️ B1-b（使用率取得器移設・check-drift.sh ⑨）でprint-disabledへの対応を
# 追加した（既存のprint分岐は無改修＝既存テストへの影響なし。追加前は
# print-disabled自体がデフォルトのexit 1に落ちて「照会不能」扱いになって
# いたため、⑨のUSAGE-FETCH-DISABLED等をこの共有スタブでは検証できなかった）。
FAKE_LAUNCHCTL_BIN="$(mktemp -d)"
FAKE_LAUNCHCTL_CALL_LOG="$FAKE_LAUNCHCTL_BIN/calls.log"
FAKE_LAUNCHCTL_LOADED_LABELS=""    # スペース区切りでロード済み扱いにするラベル名
FAKE_LAUNCHCTL_DISABLED_LABELS=""  # スペース区切りでdisabled扱いにするラベル名
refresh_fake_launchctl() {
  cat > "$FAKE_LAUNCHCTL_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$FAKE_LAUNCHCTL_CALL_LOG"
if [ "\$1" = "print" ]; then
  for label in $FAKE_LAUNCHCTL_LOADED_LABELS; do
    case "\$2" in
      *"\$label") exit 0 ;;
    esac
  done
  exit 1
fi
if [ "\$1" = "print-disabled" ]; then
  for label in $FAKE_LAUNCHCTL_DISABLED_LABELS; do
    printf '"%s" => disabled\n' "\$label"
  done
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE_LAUNCHCTL_BIN/launchctl"
}
refresh_fake_launchctl
export PATH="$FAKE_LAUNCHCTL_BIN:$PATH"
trap 'rm -rf "$FAKE_LAUNCHCTL_BIN"' EXIT

# maintenance.sh週次ランナーの健全なfixtureを作る（plist配置＋launchd上ロード
# 済みを模擬＋last-run.jsonにstarted_atを書く）。$1=HOME_DIR $2=started_atに
# 使うd_ts()と同じ符号規約のオフセット（省略時0＝今日。負値=過去N日・
# 正値=未来N日。d_ts()同様に符号なし数字は将来扱いになる点に注意）。
setup_maintenance_fixture() {
  local home="$1" ts_offset="${2:-0}"
  mkdir -p "$home/Library/LaunchAgents" "$home/.claude/logs/maintenance"
  touch "$home/Library/LaunchAgents/com.takumi009.maintenance.plist"
  FAKE_LAUNCHCTL_LOADED_LABELS="com.takumi009.maintenance"
  refresh_fake_launchctl
  python3 -c "
import json, pathlib
p = pathlib.Path('$home/.claude/logs/maintenance/last-run.json')
p.write_text(json.dumps({'started_at': '$(d_ts "$ts_offset")'}), encoding='utf-8')
"
}

# write_model_defs <dest> — モデル定義ファイル（本ファイル内のwrite_v2_profile
# 呼び出しが参照する定義名の全集合）を書く。2026-09-08 モデル定義ファイルと
# 候補指定対応（同設計§2.3・§11.3）。role.leaderに書ける属性がmodel（定義名）
# だけになったため、実体（provider/model/effort）はここへ集約する。
write_model_defs() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'EOF'
[t-sonnet-high]
provider=anthropic-api
model=claude-sonnet-5-5

[fable-1m-high]
provider=anthropic-api
model=claude-fable-5[1m]
effort=high
EOF
}

# write_v2_profile <dest> <leader-line> [extra-lines...] — 最小のv2プロファイル
# を書く（tests/test-update-sub.shのwrite_v2_profile()と同じ最小セットの
# 流儀に揃える＝担当Cの他ファイルと様式を合わせる）。2026-09-08 モデル定義
# ファイルと候補指定対応: schema_versionを6へ・role.leaderの属性をmodel=
# <定義名>だけへ・HOMEがfixture専用のためmodel_defs_path()の既定パス
# （$HOME/.config/takumi009-ai-env/models.conf）へ定義ファイルを同梱する
# （run_check()がHOMEを切り替えるので実ファイルへは触れない）。schema 6は
# team_mode/no_read_paths/machine_roleの3能力軸すべてが既知キーとして必須
# （欠落はT5）になったため、呼び出し元がmachine_roleを明示しない場合の既定値
# （main）も足す。
write_v2_profile() {
  local dest="$1" leader_line="$2"
  shift 2
  mkdir -p "$(dirname "$dest")"
  local has_machine_role=0
  local extra
  for extra in "$@"; do
    case "$extra" in machine_role:*) has_machine_role=1 ;; esac
  done
  {
    echo "---"
    echo "schema_version: 7"
    echo "profile_slug: test"
    echo "team_mode: configured value=full"
    echo "no_read_paths: unavailable"
    echo "role.leader: ${leader_line}"
    for extra in "$@"; do
      printf '%s\n' "$extra"
    done
    if [ "$has_machine_role" = "0" ]; then
      echo "machine_role: configured value=main"
    fi
    echo "reviewer: configured value=codex-mcp"
    echo "---"
  } > "$dest"
  write_model_defs "$(dirname "$dest")/models.conf"
}


# 指定パスに git リポジトリを作り、origin remote を設定する。
make_git_repo_with_remote() {
  local path="$1" remote="$2"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" remote add origin "$remote"
}

# モックの gh コマンドを作る。mode: PRIVATE / PUBLIC / fail（未認証等でrepo viewが失敗する想定）。
make_mock_gh() {
  local bindir="$1" mode="$2"
  mkdir -p "$bindir"
  if [ "$mode" = "fail" ]; then
    cat > "$bindir/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  else
    cat > "$bindir/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "repo view" ]; then
  echo "$mode"
  exit 0
fi
exit 1
EOF
  fi
  chmod +x "$bindir/gh"
}

# N時間前/後のepoch秒（BSD date。⑦のfixture用。origin/mainのコミット日時を
# 過去/未来に固定するために使う＝ハードコード日付を使わない）。
d_epoch_hours() { local n="$1"; [[ "$n" != -* ]] && n="+$n"; date -u -v"${n}"H +%s; }

# ⑦のfixture用: 指定パスをVault風のgitリポジトリにし、ローカルのbare originを
# 設定する（tests/test-backup-vault.shの「8. remote origin設定済みならpush
# される」と同じ方式＝実ネットワーク不要）。ブランチ名は本番のVaultと同じ main に
# 固定する（環境のinit.defaultBranch設定に依存しないよう -b で明示）。
make_vault_with_bare_origin() {
  local vault="$1" bare="$2"
  git init -q --bare "$bare"
  mkdir -p "$vault"
  git -C "$vault" init -q -b main
  git -C "$vault" config user.name test
  git -C "$vault" config user.email test@example.invalid
  git -C "$vault" remote add origin "$bare"
}

# ⑦のfixture用: 指定epoch秒でVaultへ1コミット追加する。
vault_commit_at() {
  local vault="$1" epoch="$2" msg="$3"
  echo "$msg" >> "$vault/note.md"
  git -C "$vault" add -A
  GIT_AUTHOR_DATE="@${epoch} +0000" GIT_COMMITTER_DATE="@${epoch} +0000" \
    git -C "$vault" commit -q -m "$msg"
}

echo "=== 1. 全項目ズレ無し（陰性コントロール） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_matches "symlink drift 0件" "$out" 'symlink総数: [0-9]+件 / drift: 0件'
  assert_contains "settings.json一致（①-2）" "$out" "settings.jsonはテンプレと一致しています"
  assert_contains "config.toml一致" "$out" "TOML三分類で一致しています"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 2. ①symlinkが無い（未インストール）を検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  mkdir -p "$HOME_DIR/.claude/hooks" "$HOME_DIR/.claude/agents" "$HOME_DIR/.codex"
  # symlink化しない（未インストール状態を模擬）

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "MISSING検知" "$out" "[MISSING]"
  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== SD-2. ①-2 permissions.allowの1要素を書き換えると[SETTINGS-DIFF]がキー名つきで出る（値は出さない） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  python3 -c "
import json
p = '$HOME_DIR/.claude/settings.json'
d = json.load(open(p))
d['permissions']['allow'][0] = 'Bash(secret-value-must-not-leak)'
json.dump(d, open(p, 'w'))
"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "SD-2: [SETTINGS-DIFF] キー 'permissions'" "$out" "[SETTINGS-DIFF] キー 'permissions'"
  assert_not_contains "値そのものは出ない" "$out" "secret-value-must-not-leak"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== SD-3. ①-2 render失敗（プロファイルを壊す）は[SETTINGS-RENDER-FAILED] 1件＝監視不能をdrift計上 ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  echo "broken profile" > "$HOME_DIR/.config/takumi009-ai-env/profile.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "SD-3: [SETTINGS-RENDER-FAILED]" "$out" "[SETTINGS-RENDER-FAILED]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 5. ②テンプレ記載キーの値がテンプレと異なる場合は[DIFF]として検知する（TOML三分類ケース1: テンプレ記載キー） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # service_tier はテンプレでキュレートされているキー（denylist/既知アプリ管理
  # キー一覧のどちらにも属さない）で、手動編集がここに入れば必ずdrift計上
  # されなければならない。
  sed 's/service_tier = "default"/service_tier = "high"/' "$HOME_DIR/.codex/config.toml" > "$HOME_DIR/.codex/config.toml.tmp"
  mv "$HOME_DIR/.codex/config.toml.tmp" "$HOME_DIR/.codex/config.toml"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "config.toml DIFF検知（テンプレ記載キーの値差分）" "$out" "[DIFF] キー 'service_tier'"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 6. ③repoに未commitの変更があるとUNCOMMITTEDを検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name test
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"
  echo "dirty change" >> "$REPO/ai-brain/data/vault-public/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "UNCOMMITTED検知" "$out" "[UNCOMMITTED]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 8. ④実Vaultとvault-publicのPreferencesに差分があるとINFO表示する（driftには数えない） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  # わざと内容を変えてエクスポート漏れを模擬する
  echo "# 実Vault側だけの更新（未エクスポート）" > "$HOME_DIR/Data/obsidian/Preferences/sample.md"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "Preferences差分はℹ️ INFO表示（driftにしない・2026-09-19 設計 §4.3）" "$out" "ℹ️ INFO: 実Vault と ai-brain/data/vault-public/Preferences に差分が"
  assert_contains "総drift件数0（④はinformational）" "$out" "総drift件数: 0"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 13. --json: ④以外(例: ③UNCOMMITTED)のdriftはdrift_excluding_item4>0でexit 1になる ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name test
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"
  # ai-brain/data/vault-public/Preferences以外の(④に影響しない)ファイルを変更してUNCOMMITTEDを
  # 起こす（ai-brain/data/vault-public/Preferences自体を変更すると④も同時にdriftしてしまい、
  # このテストの主眼〈④以外のみのdrift〉を検証できなくなるため・実装中に自分で
  # 気付いて修正）。
  echo "dirty change" >> "$REPO/core/assembly/check-drift.sh.orig-marker"

  rc=0
  out="$(run_check_json "$REPO" "$HOME_DIR")" || rc=$?
  json="$(last_line "$out")"
  assert_eq_num "exit code 1(③のdriftはfail-fast対象)" "$rc" "1"
  assert_eq_num "item4_drift=0(④は健全)" "$(json_field "$json" item4_drift)" "0"
  assert_eq_num "drift_excluding_item4=total_drift(④以外のdriftのみ)" \
    "$(json_field "$json" drift_excluding_item4)" "$(json_field "$json" total_drift)"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 11. ⑤Vault・私的パッチrepoとも PRIVATE ならdriftにならない ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin git@github.com:someone/myvault.git
  make_git_repo_with_remote "$PRIVATE_REPO" "https://github.com/someone/aienv-private.git"
  make_mock_gh "$BINDIR" "PRIVATE"

  out="$(PATH="$BINDIR:$PATH" AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_contains "Vaultバックアップ: PRIVATE確認メッセージ" "$out" "Vaultバックアップ (someone/myvault): ✅ PRIVATE"
  assert_contains "私的パッチrepo: PRIVATE確認メッセージ" "$out" "私的パッチrepo (someone/aienv-private): ✅ PRIVATE"
  assert_not_contains "[VISIBILITY]は出ない" "$out" "[VISIBILITY]"

  rm -rf "$REPO" "$HOME_DIR" "$BINDIR" "$PRIVATE_REPO"
}

echo "=== 12. ⑤GitHub上でPUBLICになっているとdriftとして検知する ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BINDIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin git@github.com:someone/myvault.git
  make_git_repo_with_remote "$PRIVATE_REPO" "https://github.com/someone/aienv-private.git"
  make_mock_gh "$BINDIR" "PUBLIC"

  out="$(PATH="$BINDIR:$PATH" AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_contains "Vaultバックアップの[VISIBILITY]検知" "$out" "[VISIBILITY] Vaultバックアップ (someone/myvault)"
  assert_contains "私的パッチrepoの[VISIBILITY]検知" "$out" "[VISIBILITY] 私的パッチrepo (someone/aienv-private)"

  rm -rf "$REPO" "$HOME_DIR" "$BINDIR" "$PRIVATE_REPO"
}

echo "=== 18. ⑤解析できない/GitHub以外のURLに認証情報が含まれていてもログに露出しない（Codexレビュー指摘・Major回帰） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  PRIVATE_REPO="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # Vault: github.comらしきURLだがパス部が無く解析不能（[GH-URL-UNPARSEABLE]経路）
  git -C "$HOME_DIR/Data/obsidian" init -q
  git -C "$HOME_DIR/Data/obsidian" remote add origin "https://user:sup3rSecretToken@github.com"
  # 私的パッチrepo: GitHub以外（対象外経路）
  make_git_repo_with_remote "$PRIVATE_REPO" "https://user:sup3rSecretToken@gitlab.com/someone/aienv-private.git"

  out="$(AIENV_PRIVATE_REPO="$PRIVATE_REPO" run_check "$REPO" "$HOME_DIR")"
  assert_not_contains "認証トークンがログに出ない" "$out" "sup3rSecretToken"
  assert_contains "代わりにredactedと表示される（Vault側）" "$out" "<redacted>@github.com"
  assert_contains "代わりにredactedと表示される（私的パッチrepo側）" "$out" "<redacted>@gitlab.com"

  rm -rf "$REPO" "$HOME_DIR" "$PRIVATE_REPO"
}

echo "=== 20. ⑥maintenance週次ランナーの最終開始(started_at)が期限超過(STALE)だと検知する（リーダー裁定2026-07-16: 週次+猶予1日=8日超） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences" "$HOME_DIR/.claude/logs"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  # 目安8日を超える10日前が最終started_at
  setup_maintenance_fixture "$HOME_DIR" -10
  printf '%s\tsess1\tKnowledge/x.md\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-reads.tsv"
  printf '%s\tsess1\tKnowledge/x.md\tk\n' "$(d_ts 0)" > "$HOME_DIR/.claude/logs/vault-recall.tsv"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "MAINTENANCE-STALEが検知される" "$out" "[MAINTENANCE-STALE]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 44. ⑦未反映commit自体が24時間超過して待たされているとVAULT-PUSH-STALEとしてdrift計上する（2026-07-13 外部脳round4対応・欠陥① / Codex一次レビュー指摘・Major対応で『最も古い未反映commit』基準に変更） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  BARE="$(mktemp -d)/origin.git"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"
  make_vault_with_bare_origin "$HOME_DIR/Data/obsidian" "$BARE"
  # origin側のtipは100時間前（十分に古いが、それ自体はもうpush済みなので無関係）。
  # 「未反映のまま30時間待たされているcommit」がある、という状態を再現する
  # （旧実装はorigin tipの古さだけを見ていたため、直近の未反映commitが実際には
  # 新しくてもtipが古いだけでSTALE誤報していた＝Codexレビュー指摘・Major）。
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -100)" "pushed 100時間前"
  git -C "$HOME_DIR/Data/obsidian" push -q origin main
  vault_commit_at "$HOME_DIR/Data/obsidian" "$(d_epoch_hours -30)" "unpushed 30時間前"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "VAULT-PUSH-STALEが検知される" "$out" "[VAULT-PUSH-STALE]"

  rm -rf "$REPO" "$HOME_DIR" "$(dirname "$BARE")"
}

echo "=== 65. ①-3 ANTHROPIC_MODEL環境変数が設定されているとEFFECTIVE_MODEL_OVERRIDE_PRESENTとして検知される（値は出さない・V13） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/Data/obsidian/Preferences"
  cp "$REPO/ai-brain/data/vault-public/Preferences/sample.md" "$HOME_DIR/Data/obsidian/Preferences/sample.md"

  out="$(ANTHROPIC_MODEL='claude-should-not-leak' DIR="$REPO" HOME="$HOME_DIR" VAULT="$HOME_DIR/Data/obsidian" bash "$REPO/core/assembly/check-drift.sh")"
  assert_contains "EFFECTIVE_MODEL_OVERRIDE_PRESENTが検知される" "$out" "[EFFECTIVE_MODEL_OVERRIDE_PRESENT]"
  assert_not_contains "値そのものは出ない" "$out" "claude-should-not-leak"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 68. ⑧ --check-profileが非0終了するとPROFILE-VALIDATION-FAILEDとしてdrift計上される（2026-09-01 設計書§4.4） ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  # V15（禁止キー名ガード）に違反する行を書く＝fail区分のvalidator違反を
  # 決定的に起こす（構文エラーの中でも最も再現しやすいケースを選ぶ）。
  write_v2_profile "$HOME_DIR/.config/takumi009-ai-env/profile.md" \
    "configured model=t-sonnet-high" \
    "role.leader_api_token: configured model=t-sonnet-high"

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "PROFILE-VALIDATION-FAILEDとして検知される" "$out" "[PROFILE-VALIDATION-FAILED]"

  rm -rf "$REPO" "$HOME_DIR"
}

echo "=== 使用率キャッシュの鮮度 ==="
{
  REPO="$(mktemp -d)"
  HOME_DIR="$(mktemp -d)"
  make_fake_repo "$REPO"
  install_fake_home "$REPO" "$HOME_DIR"
  mkdir -p "$HOME_DIR/.cache/claude-codex-usage"
  stale_epoch=$(( $(date -u +%s) - 60 * 40 ))
  cat > "$HOME_DIR/.cache/claude-codex-usage/claude-cache.json" <<EOF
{"schema_version":1,"service":"claude","fetched_at":$stale_epoch,"updated_at":$stale_epoch,"five_hour":{"used_percent":10},"seven_day":{"used_percent":10},"last_error":null}
EOF
  FAKE_LAUNCHCTL_LOADED_LABELS=""
  FAKE_LAUNCHCTL_DISABLED_LABELS=""
  refresh_fake_launchctl

  out="$(run_check "$REPO" "$HOME_DIR")"
  assert_contains "40分経過でSTALEを検知する" "$out" "[USAGE-FETCH-STALE]"
  assert_contains "分経過の内訳が出る" "$out" "40 分経過"

  rm -rf "$REPO" "$HOME_DIR"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
