[English](#english) | [日本語](#日本語)

# takumi009-ai-env

![License](https://img.shields.io/badge/license-MIT-green)
![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black)

## English

This repository is the "base package" that makes an AI working environment centered on Claude Code / Codex **reproducible on any Mac**. The overall architecture is as follows:

```
Sub environment  = Base package (this repo, public)
Main environment = Base package (this repo, public) + Private patch (separate repo, private)
```

- **Base package (this repository)**: All of the AI's own code and rules (Claude/Codex configuration, hooks, agents, the export/backup mechanisms). Self-contained and works standalone as the sub environment.
- **Private patch (separate repository, private)**: The diff layered on top of the base package — the actual Vault data (personal notes) and settings that cannot be made public. Exists only on the personal Mac (main).

### Permission Model: Main / Sub

| Role | Machine | Permissions |
|---|---|---|
| **Main** | Personal Mac (always 1) | Has edit permission. Rule/config changes and additions happen only here. The only place that can push to either the public or the private repository |
| **Sub** | 2nd Mac and beyond | No edit permission (reference only). Just clone and pull this repository |

If a case arises on a sub machine where a rule needs fixing, don't fix it there — bring it back to the main machine, apply it, and distribute it on the next pull.

### Structure

```
takumi009-ai-env/
├── claude/
│   ├── settings.json          # ~/.claude/settings.json (symlink target)
│   ├── hooks/                 # bootstrap-vault.sh, delegation-gate-v2.sh, vault-recall.sh, vault-read-log.sh
│   └── agents/                # Worker role definitions (7 roles)
├── codex/
│   ├── AGENTS.md               # ~/.codex/AGENTS.md (symlink target)
│   ├── hooks.json               # ~/.codex/hooks.json (symlink target)
│   └── config.toml              # Template for ~/.codex/config.toml (generated, not a symlink; see below)
├── scripts/
│   ├── install-main.sh          # Installer for the main environment (symlink setup; supports --with-dotfiles)
│   ├── install-sub.sh           # Installer for the sub environment (sets up the Vault skeleton, then delegates to install-main.sh)
│   ├── install-backup.sh        # Installer for the Vault-backup LaunchAgent
│   ├── install-vault-agents.sh  # Installer for the 2 Vault-cultivation LaunchAgents (main only)
│   ├── setup-codex-mcp.sh       # Registers the codex MCP with Claude Code (auto-run by install-main.sh)
│   ├── backup-vault.sh          # Periodically git commits (+pushes) the Vault
│   ├── update-sub.sh            # Periodically refreshes the sub's rules (sub only; installed by install-sub.sh)
│   ├── export-public-vault.sh   # Exports the Vault's public folder to vault-public/
│   ├── check-drift.sh           # Manual audit tool that detects "drift" in symlinks/config.toml/repo/vault-public/private repo visibility
│   ├── drift-notify.sh          # Wrapper that runs check-drift.sh and sends a macOS notification if drift>0 (main only; auto-installed by install-main.sh)
│   ├── audit.sh                 # One-shot pre-publish audit (NG words/username paths/secrets over full git history, tracked-file drift, completeness); `--quick` skips the (slow) history scan and only checks the current tree
│   ├── vault-agents/            # 2 Vault-cultivation scripts (vault_inventory.py, etc.; main-only feature)
│   ├── ngwords.txt              # NG-word definitions (private data; **not included in this repository** — see "Setup" below)
│   └── templates/               # README templates for the private skeleton folders
├── launchagents/
│   ├── com.takumi009.vault-backup.plist       # Runs the Vault backup hourly (main only)
│   ├── com.takumi009.vault-inventory.plist    # Generates the Vault inventory report twice a month (main only)
│   ├── com.takumi009.fragments-log.plist      # Generates the Fragments promotion candidate log weekly (main only)
│   ├── com.takumi009.sub-update.plist         # Auto-refreshes the rules twice a day (sub only)
│   └── com.takumi009.drift-check.plist        # Detects drift weekly and sends a macOS notification if drift>0 (main only; auto-installed by install-main.sh)
├── vault-public/                # Snapshot of the Vault's designated public folders (see below)
├── Brewfile                     # Dependency formulae installed via `brew bundle` (see below)
└── tests/                       # Unit tests for the scripts above
```

### Roles: Orchestrator / Worker / Codex

`claude/agents/` and this environment's workflow are built around three role words:

- **Orchestrator (leader)**: The main Claude Code session. It makes decisions, talks with the user, and directs the overall workflow — it delegates implementation/investigation/testing to workers rather than doing them itself.
- **Worker**: A subagent launched from one of the 7 role definitions under `claude/agents/` — requirements-analyst, system-designer, implementer, tester, researcher, operator, adoption-critic.
- **Codex**: The dedicated first-pass reviewer (via the `mcp__codex__codex`/`codex-reply` MCP tools). Workers call it to review their own output before reporting back to the orchestrator.

### About vault-public/

This repository's `vault-public/` is a full-copy snapshot of only the folders in the external brain (Obsidian Vault) that have been designated as "containing no personal information" (currently `Preferences/`). The remaining folders that may contain personal information (`Personal/` `Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/` `Blogs/`) are reproduced as **empty folders with just a README.md, no content** (so that a sub machine trying to write to them doesn't fail with "folder not found").

Generation/updating is done by `scripts/export-public-vault.sh`. NG words and leaked secrets are always fail-fast (even one detected fails the run and blocks the commit). For wiki links into private folders (accidental links), only links into `Personal/` are fail-fast; links into the other private folders (`Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/`) are allowed and only reported (exit 0) — see the comment at the top of the script for details. Note that links into private folders are, by design, intentionally broken on the public side (they're listed in the report): they point to notes that exist only in the maintainer's own private Vault, so opening them in Obsidian shows them as unresolved links, which is expected and not a bug. Only `Personal/` is fail-fast (rather than merely reported) because, unlike the other private folders, its note names themselves tend to reveal personal matters. None of the checks touch the real `vault-public/` until every check has passed — everything is built and verified in a temporary staging directory first, so if any check fails, `vault-public/` remains completely unchanged (a later failure, e.g. missing git commit identity, happens only after promotion and is a separate, non-security concern — see the comment at the top of the script).

### Setup

#### 0. Install dependencies (common)

```sh
brew bundle          # Reads the Brewfile and installs ripgrep, gitleaks, jq, gh
```

Claude Code / Codex themselves are outside brew's management, so install them separately from their official sites.

`scripts/ngwords.txt` (NG-word definitions used by `export-public-vault.sh` and `audit.sh`) is **not included in this repository** because it's private data. To run `export-public-vault.sh`/`audit.sh` as-is, either set `NGWORDS_FILE=/path/to/your/ngwords.txt` to point at your own file, or write your own NG-word list.

#### Main environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
scripts/install-main.sh          # Symlinks claude/ and codex/ into ~/.claude and ~/.codex
scripts/install-backup.sh        # Installs the Vault-backup LaunchAgent
scripts/install-vault-agents.sh  # Installs the 2 Vault-cultivation LaunchAgents (optional, main only)
```

- `install-main.sh` moves any existing real file to `<dest>.pre-aienv.bak` only the first time before replacing it with a symlink (safe to re-run = idempotent). Use the `--dry-run` option to preview the plan only.
- Only `codex/config.toml` is generated as a real file — not a symlink — with the placeholder (`__AIENV_HOME__`) replaced by the actual home path (because plain TOML doesn't support shell variable expansion).
- Both `install-backup.sh` and `install-vault-agents.sh` only place the LaunchAgents (bootstrap+enable) — they do **not** trigger an immediate run (kickstart) (because initializing the Vault as a Git repository for the first time is meant to be a staged rollout. Either wait for the next scheduled run, or once you're ready, run `launchctl kickstart -k` manually).
- At the end, `install-main.sh` automatically runs `scripts/setup-codex-mcp.sh`, which **auto-registers the codex MCP** (`mcp__codex__codex`/`codex-reply`, the core of the review setup) (`claude mcp add codex -s user -- <absolute path to codex> mcp-server`; skipped/idempotent if already registered). On environments where Claude Code / the codex command aren't installed, registration fails, but the installer as a whole still continues with a WARN rather than stopping. To register manually, run `scripts/setup-codex-mcp.sh` standalone, or run the suggested `claude mcp add` command directly.
- At the end, `install-main.sh` likewise installs the **weekly drift-notification LaunchAgent** (`com.takumi009.drift-check.plist`, main only). It runs `scripts/drift-notify.sh` unattended every Monday at 09:30 (which runs `scripts/check-drift.sh` and sends a macOS notification via `osascript` if drift>0), preventing the situation where `scripts/check-drift.sh` is created but forgotten and goes stale (as with the other LaunchAgents, this only installs it — it does not kickstart it immediately). When delegated from `install-sub.sh` (internal flag `--sub-delegate`), this step is automatically skipped and not installed on sub machines.
- On the main environment, a **private patch (a separate private repository)** is layered on top of this base package. The private patch contains the Vault's substance (`~/Data/obsidian`) and settings that cannot be made public. See that repository's own documentation for its setup steps.

#### Sub environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
scripts/install-sub.sh
```

The sub environment is self-contained with just the base package and does not install the private patch (it also has no edit permission = pull only). `install-sub.sh` does the following:

1. If `$HOME/Data/obsidian` doesn't exist, copies the contents of `vault-public/` (public snapshot + private skeleton) to build the Vault skeleton (does not overwrite if it already exists).
2. Symlinking of `claude/`/`codex/` and codex MCP registration are done by calling `install-main.sh` directly (shared logic).
3. The Vault-cultivation and backup LaunchAgents are **not installed** (main-only features).
4. **Automatic rule updates**: installs `com.takumi009.sub-update.plist` (runs `scripts/update-sub.sh` twice a day, at 09:00/13:00). It `git pull --ff-only`s this repository, and if there are changes, automatically regenerates `codex/config.toml`, re-syncs `vault-public/Preferences/` (**touches nothing outside Preferences**, so local `Fragments` etc. on the sub machine are not deleted), and fills in any new skeleton folders. If there are no changes, it exits quietly (since subs aren't meant to be edited, a `git pull` that can't fast-forward normally shouldn't happen, but if it does, it just prints a warning and stops rather than force-overwriting).

On sub machines, private notes such as `Personal/profile-personal.md` and `Knowledge/mistakes.md` don't exist, but since `bootstrap-vault.sh` (the SessionStart hook) is designed to only list **files that actually exist** as required reading, no "not found" warnings appear.

#### Also install dotfiles (a separate component)

```sh
scripts/install-main.sh --with-dotfiles   # or install-sub.sh --with-dotfiles
```

If `$HOME/work/dotfiles` doesn't exist, it `git clone`s it ([Takumi00Nine/dotfiles](https://github.com/Takumi00Nine/dotfiles)) and then calls `./install.sh` (if it already exists, skips the clone and just calls `install.sh`). Off by default (dotfiles are never touched unless this option is given). dotfiles are a "component" outside ai-env's scope, but the installer can call it as a subcontractor.

### Vault Backup Operations

`scripts/backup-vault.sh` targets `$HOME/Data/obsidian`: if there are changes, it runs `git add -A && git commit` (message: `backup: YYYY-MM-DD HH:MM`), and pushes only if the `origin` remote is already configured (if not, it stops with a warning after committing). It has locking to prevent concurrent runs (mutual exclusion via atomic file creation) and stale detection for `git index.lock`, and is meant to run unattended every hour via `launchagents/com.takumi009.vault-backup.plist` (installed by `scripts/install-backup.sh`).

The user creates and configures the remote for the Vault's backup destination (a private repo) themselves (the scripts in this repository never create a remote on their own).

### Vault Cultivation Tools (main only)

`scripts/vault-agents/` contains 2 tools that periodically inventory and log the external brain (Obsidian Vault). All of them only read the Vault and write reports (Markdown) under `$HOME/.claude/logs/` — they never write into the Vault itself (moved out of `Explorations/` on 2026-07-11; see [[Decisions/2026-07-11-vault-maintenance-hands-off]] in the Vault — "don't put human-facing docs nobody reads inside the Vault").

| Script | Content | Schedule |
|---|---|---|
| `vault_inventory.py` | Inventory report of policy notes: missing `updated`, broken links, remnants of superseded policies, etc. | 1st and 15th of each month, 03:00 |
| `fragments_log.py` | Weekly log of Fragments (daily fragments) promotion candidates | Every Monday, 03:30 |

The corresponding 2 LaunchAgents are installed by `scripts/install-vault-agents.sh` (main only, optional). Note: these plists hard-code `/usr/bin/python3` (macOS's system Python) as the interpreter.

### Drift Detection (check-drift.sh)

```sh
scripts/check-drift.sh
```

Checks the following 5 points and lists them (**it does not exit 1 even if drift is detected** — it's purely a report tool for manual checking):

1. Whether the 12 symlink files point to the actual files in the repo
2. Whether `~/.codex/config.toml` (a generated file) matches the repo's template with the placeholder expansion applied
3. Whether this repository has any uncommitted changes
4. Whether `vault-public/Preferences` differs from the real Vault's `Preferences` (detects export omissions from `export-public-vault.sh`)
5. Whether the remote of the Vault backup / private-patch repo (`AIENV_PRIVATE_REPO`, default `~/work/takumi009-ai-env-private`) is still actually **private** on GitHub (`gh repo view --json visibility`). This is a standing check for whether a repository that should be private was accidentally made public. Not applicable if the remote isn't configured; if `gh` isn't installed/authenticated, it's shown only as a warning rather than counted as drift (the ai-env repo itself is "planned to go public," so it's excluded from this check)

This script itself is a manually-run report tool, but via `scripts/drift-notify.sh` it also runs unattended once a week (Monday 09:30) from `launchagents/com.takumi009.drift-check.plist` (main only; auto-installed by `install-main.sh`), and sends a macOS notification if there is even one item of drift.

### Restore Runbook (Disaster Recovery / Main Migration)

> An actual recovery drill has been performed in an isolated environment, confirming this procedure works (verified 2026-07-08).

#### When the main Mac breaks (disaster recovery)

On the new Mac, run the following in order:

```sh
# 1. Prerequisite tools (after installing Homebrew)
brew install gh && gh auth login          # GitHub auth (needed for the subsequent private clones)

# 2. Restore the Vault (external brain = memory)
git clone <URL of the Vault backup repo (private)> ~/Data/obsidian

# 3. Base package + private patch
git clone <URL of this repository> ~/work/takumi009-ai-env
git clone <URL of the private-patch repo (private)> ~/work/takumi009-ai-env-private
cd ~/work/takumi009-ai-env && brew bundle
~/work/takumi009-ai-env-private/install-private.sh   # Restores docs/ and ngwords

# 4. Rebuild the environment
scripts/install-main.sh --with-dotfiles   # symlinks + dotfiles + codex MCP registration + weekly drift notification
scripts/install-backup.sh                 # Resume hourly backups
scripts/install-vault-agents.sh           # Vault-cultivation tools (optional)

# 5. Log in to each app (manual): Claude Code / Codex / others
```

- Scope of what's restored = **everything up to the pushed state**. Uncommitted work is lost (guarded against day-to-day via `scripts/check-drift.sh`'s uncommitted-changes detection)
- The maximum backup delay depends on the Mac's sleep state (the LaunchAgent doesn't fire while asleep and catches up once on wake)

#### Main migration (planned move to a new Mac)

1. On the old main, do a final sync: `scripts/backup-vault.sh` → `scripts/export-public-vault.sh` → confirm there's nothing unpushed with `scripts/check-drift.sh`
2. Run the "disaster recovery" procedure above on the new Mac
3. Stop the old main's LaunchAgents (`launchctl bootout gui/$(id -u)/com.takumi009.<label>`) — **there is always exactly one main** (this preserves the uniqueness of edit permission / push location)

### Tests

```sh
bash tests/test-export-public-vault.sh
bash tests/test-backup-vault.sh
bash tests/test-bootstrap-vault.sh
bash tests/test-install-sub.sh
bash tests/test-install-vault-agents.sh
bash tests/test-with-dotfiles.sh
bash tests/test-check-drift.sh
bash tests/test-drift-notify.sh
bash tests/test-install-main-drift-check.sh
bash tests/test-setup-codex-mcp.sh
bash tests/test-install-main-codex-mcp.sh
bash tests/test-update-sub.sh
bash tests/test-audit.sh
```

None of them depend on the real Vault, real GitHub, the real `~/.claude`, or the real `~/.codex` — they run entirely against disposable fixture directories (`rg` and `gitleaks` are required; both are already available once `brew bundle` has been run). Currently 13 suites / 359 assertions, all passing.

### License

[MIT](LICENSE)

---

## 日本語

このリポジトリは、Claude Code / Codex を中心とした AI 作業環境を**どの Mac でも再現できる形**にした「基本パッケージ」です。全体のアーキテクチャは次のとおりです。

```
サブ環境   ＝ 基本パッケージ（このリポジトリ・public）
メイン環境 ＝ 基本パッケージ（このリポジトリ・public）＋ 私的パッチ（別リポジトリ・private）
```

- **基本パッケージ（このリポジトリ）**: AI本体のコード・ルールすべて（Claude/Codexの設定・hooks・agents・エクスポート/バックアップの仕組み）。単体でサブ環境として完結して動きます。
- **私的パッチ（別リポジトリ・private）**: 基本パッケージに被せる差分＝Vault実体（私的ノート群）や公開できない設定。個人Mac（メイン）にのみ存在します。

### 権限モデル: メイン／サブ

| 権限 | マシン | 権限 |
|---|---|---|
| **メイン** | 個人Mac（常に1台） | 編集権限あり。ルール・設定の変更/追加はここだけ。public/privateどちらのリポジトリへも push できる唯一の地点 |
| **サブ** | 2台目以降のMac | 編集権限なし（参照専用）。このリポジトリを clone して pull するだけ |

サブでルールを直したい事案が出た場合は、その場では直さずメインへ持ち帰って反映し、次回 pull で配布します。

### 構成

```
takumi009-ai-env/
├── claude/
│   ├── settings.json          # ~/.claude/settings.json （symlink先）
│   ├── hooks/                 # bootstrap-vault.sh・delegation-gate-v2.sh・vault-recall.sh・vault-read-log.sh
│   └── agents/                # ワーカー役割定義（7ロール）
├── codex/
│   ├── AGENTS.md               # ~/.codex/AGENTS.md （symlink先）
│   ├── hooks.json               # ~/.codex/hooks.json （symlink先）
│   └── config.toml              # ~/.codex/config.toml のテンプレ（symlinkではなく生成、後述）
├── scripts/
│   ├── install-main.sh          # メイン環境用インストーラ（symlink化。--with-dotfiles対応）
│   ├── install-sub.sh           # サブ環境用インストーラ（Vault骨格配置＋install-main.shへ委譲）
│   ├── install-backup.sh        # Vaultバックアップ用LaunchAgentのインストーラ
│   ├── install-vault-agents.sh  # Vault育成系LaunchAgent2種のインストーラ（メイン専用）
│   ├── setup-codex-mcp.sh       # codex MCPをClaude Codeへ登録するスクリプト（install-main.shが自動実行）
│   ├── backup-vault.sh          # Vaultを定期的にgit commit（+push）するスクリプト
│   ├── update-sub.sh            # サブのルールを定期的に最新化するスクリプト（サブ専用。install-sub.shが設置）
│   ├── export-public-vault.sh   # Vaultのpublicフォルダを vault-public/ へエクスポートするスクリプト
│   ├── check-drift.sh           # symlink/config.toml/repo/vault-public/private repo可視性の「ズレ」を検知する手動監査ツール
│   ├── drift-notify.sh          # check-drift.shを実行しdrift>0ならmacOS通知するラッパ（メイン専用。install-main.shが自動設置）
│   ├── audit.sh                 # public公開前の総監査ツール（git履歴全体のNGワード/実ユーザー名パス/シークレット・追跡ファイル逸脱・完備性）。`--quick` で履歴スキャン（重い）を省き現在ツリーのみ実行
│   ├── vault-agents/            # Vault育成系スクリプト2種（vault_inventory.py等。メイン専用機能）
│   ├── ngwords.txt              # NGワード定義（私的データのため**このリポジトリには含まれない**。詳細は「導入手順」参照）
│   └── templates/               # private骨格フォルダ用のREADMEテンプレ
├── launchagents/
│   ├── com.takumi009.vault-backup.plist       # Vaultバックアップを毎時実行（メイン専用）
│   ├── com.takumi009.vault-inventory.plist    # Vault棚卸しレポートを月2回生成（メイン専用）
│   ├── com.takumi009.fragments-log.plist      # Fragments昇格候補ログを毎週生成（メイン専用）
│   ├── com.takumi009.sub-update.plist         # ルールを1日2回自動最新化（サブ専用）
│   └── com.takumi009.drift-check.plist        # ズレを週1で検知しdrift>0ならmacOS通知（メイン専用。install-main.shが自動設置）
├── vault-public/                # Vaultのpublic指定フォルダのスナップショット（後述）
├── Brewfile                     # `brew bundle` で導入する依存formula（後述）
└── tests/                       # 上記スクリプト群のユニットテスト
```

### 役割: リーダー／ワーカー／Codex

`claude/agents/` およびこの環境のワークフローは、次の3つの役割語を軸に組み立てられています。

- **リーダー（orchestrator）**: メインの Claude Code セッション。意思決定・ユーザー対話・工程全体の采配を行い、実装/調査/テストは自分でやらずワーカーへ委任します。
- **ワーカー（worker）**: `claude/agents/` 配下の7つの役割定義（要件定義・設計・実装・テスト・調査・運用・採用判定）で起動されるサブエージェントです。
- **Codex**: 一次レビュアー専任（`mcp__codex__codex`/`codex-reply` MCPツール経由）。ワーカーがリーダーへ報告する前に、自分の成果物のレビューを依頼する相手です。

### vault-public/ について

このリポジトリの `vault-public/` は、外部脳（Obsidian Vault）のうち「個人情報を含まない」と決めたフォルダ（現状 `Preferences/`）だけを丸ごとコピーしたスナップショットです。個人情報を含みうる残りのフォルダ（`Personal/` `Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/` `Blogs/`）は、**中身を含めず空フォルダ＋README.mdだけ**を再現しています（サブ機で書き込もうとした際に「フォルダが無い」で失敗しないようにするため）。

生成・更新は `scripts/export-public-vault.sh` が行います。NGワード・シークレット混入は常に fail-fast（1件でも検知したら実行を失敗させて commit させない）です。private フォルダへの wiki link（うっかりリンク）については、fail-fast 対象は `Personal/` への link のみで、それ以外の private フォルダ（`Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/`）への link は許容し、レポート表示のみ（exit 0）です（詳細はスクリプト冒頭のコメント参照）。なお、private フォルダへの link は public 側では意図的にリンク切れになります（レポートに一覧表示されます）: リンク先は本人の非公開Vaultにしか存在しないノートを指しているため、Obsidianで開くと未解決リンクとして表示されますが、これは正常な状態でありバグではありません。`Personal/` だけが（レポートに留めず）fail-fast の対象になっているのは、他の private フォルダと違い `Personal/` はノート名自体が私事を示す傾向があるためです。いずれのチェックも全項目が通過するまで本番の `vault-public/` には一切触れません（一時ステージング領域で生成・検証してから昇格するため、チェックが1つでも失敗すれば `vault-public/` は完全に無変更のままです。昇格より後の失敗＝例えば git commit 用の identity 未設定は、セキュリティ上の懸念とは別の話としてスクリプト冒頭のコメントを参照してください）。

### 導入手順

#### 0. 依存ツールの導入（共通）

```sh
brew bundle          # Brewfile を見て ripgrep・gitleaks・jq・gh を導入
```

Claude Code / Codex 本体アプリは brew 管理外のため、各公式サイトから別途インストールしてください。

`scripts/ngwords.txt`（`export-public-vault.sh`・`audit.sh` が使うNGワード定義）は私的データのため**このリポジトリには含まれません**。`export-public-vault.sh`/`audit.sh` をそのまま実行するには、`NGWORDS_FILE=/path/to/your/ngwords.txt` で自分のファイルを指定するか、自分のNGワード定義を作成してください。

#### メイン環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
scripts/install-main.sh          # claude/・codex/ を ~/.claude・~/.codex へ symlink 化
scripts/install-backup.sh        # Vaultバックアップ用LaunchAgentを配置
scripts/install-vault-agents.sh  # Vault育成系LaunchAgent2種を配置（任意・メイン専用機能）
```

- `install-main.sh` は既存の実ファイルを初回だけ `<dest>.pre-aienv.bak` に退避してから symlink に置き換えます（再実行しても安全＝冪等）。`--dry-run` オプションで計画だけを確認できます。
- `codex/config.toml` だけは symlink ではなく、プレースホルダ（`__AIENV_HOME__`）を実ホームパスへ置換した実ファイルとして生成されます（plain TOML はシェル変数展開されないため）。
- `install-backup.sh`・`install-vault-agents.sh` はどちらも LaunchAgent の配置（bootstrap+enable）までを行い、**即時実行（kickstart）はしません**（Vault の初回git化は段階的ロールアウトが前提のため。初回実行は次回の定期発火を待つか、準備が整ってから手動で `launchctl kickstart -k` してください）。
- `install-main.sh` は末尾で `scripts/setup-codex-mcp.sh` を自動実行し、**codex MCP（`mcp__codex__codex`/`codex-reply`、レビュー体制の中核）を自動登録**します（`claude mcp add codex -s user -- <codexの絶対パス> mcp-server`。既に登録済みならskip・冪等）。Claude Code / codex コマンドが未導入の環境では登録に失敗しますが、その場合も installer 全体は止まらず WARN で続行します。手動で登録する場合は `scripts/setup-codex-mcp.sh` を単体実行するか、案内される `claude mcp add` コマンドを直接実行してください。
- `install-main.sh` は同じく末尾で**週次drift通知LaunchAgent**（`com.takumi009.drift-check.plist`。メイン専用）も配置します。毎週月曜09:30に `scripts/drift-notify.sh`（`scripts/check-drift.sh` を実行し drift>0 なら `osascript` でmacOS通知）を無人実行し、`scripts/check-drift.sh` を作っても実行し忘れて陳腐化する事態を防ぎます（他のLaunchAgentと同様、配置のみで即時kickstartはしません）。`install-sub.sh` からの委譲時（内部フラグ `--sub-delegate`）は自動的にskipされ、サブ機には設置されません。
- メイン環境では、この基本パッケージの上に**私的パッチ（別のprivateリポジトリ）**を重ねます。私的パッチには Vault の実体（`~/Data/obsidian`）や、公開できない設定が含まれます。私的パッチの導入手順は当該リポジトリ側のドキュメントを参照してください。

#### サブ環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
scripts/install-sub.sh
```

サブ環境は基本パッケージのみで完結し、私的パッチは導入しません（編集権限もありません＝pull専用）。`install-sub.sh` は以下を行います:

1. `$HOME/Data/obsidian` が無ければ `vault-public/` の中身（public スナップショット＋private骨格）をコピーして Vault の骨格を作る（既に存在する場合は上書きしません）。
2. `claude/`・`codex/` の symlink 化・codex MCP登録は `install-main.sh` をそのまま呼び出して行う（ロジックは共通）。
3. Vault育成系・バックアップの LaunchAgent は**インストールしません**（メイン専用機能）。
4. **ルールの自動最新化**: `com.takumi009.sub-update.plist`（`scripts/update-sub.sh` を1日2回＝09:00/13:00に起動）を設置します。このリポジトリを `git pull --ff-only` し、変化があれば `codex/config.toml` の再生成・`vault-public/Preferences/` の再同期（**Preferences以外には一切触れません**＝サブ機ローカルの `Fragments` 等は消えません）・新しい骨格フォルダの補充を自動で行います。変化が無ければ静かに終了します（サブは編集しない運用のため `git pull` が fast-forward できない事態は通常起きませんが、その場合は警告を出すだけで停止し、強制上書きはしません）。

サブ機では `Personal/profile-personal.md`・`Knowledge/mistakes.md` 等の private ノートが存在しませんが、`bootstrap-vault.sh`（SessionStartフック）は**存在するファイルだけ**を必読リストに載せる設計のため、「見つかりません」という警告は出ません。

#### dotfiles（部品）も一緒に導入する

```sh
scripts/install-main.sh --with-dotfiles   # または install-sub.sh --with-dotfiles
```

`$HOME/work/dotfiles` が無ければ `git clone`（[Takumi00Nine/dotfiles](https://github.com/Takumi00Nine/dotfiles)）してから `./install.sh` を呼びます（既に存在する場合は clone をskipして `install.sh` だけ呼びます）。既定は OFF（このオプションを付けない限りdotfilesには一切触れません）。dotfiles は ai-env のスコープ外の「部品」ですが、インストーラが下請けとして呼び出せるようにしています。

### Vault バックアップの運用

`scripts/backup-vault.sh` は `$HOME/Data/obsidian` を対象に、変更があれば `git add -A && git commit`（メッセージ: `backup: YYYY-MM-DD HH:MM`）し、remote `origin` が設定済みの場合のみ push します（未設定なら commit までで警告を出して終了）。多重起動防止のロック（原子的なファイル作成による排他制御）・`git index.lock` のstale検知つきで、`launchagents/com.takumi009.vault-backup.plist`（`scripts/install-backup.sh` が配置）から1時間おきに無人実行される想定です。

Vault のバックアップ先（private repo）の作成・remote設定は本人が行います（このリポジトリのスクリプトは remote を勝手に作成しません）。

### Vault育成系ツール（メイン専用機能）

`scripts/vault-agents/` には、外部脳(Obsidian Vault)を定期的に棚卸し・記録するツール2種を収録しています。いずれも Vault を読み取ってレポート（Markdown）を `$HOME/.claude/logs/` 配下へ出力するだけで、Vault 自体には一切書き込みません（2026-07-11、`Explorations/` 配下から移設。「読まれない人間向け資料をVaultに置かない」方針＝Vault内 `Decisions/2026-07-11-vault-maintenance-hands-off` 参照）。

| スクリプト | 内容 | 実行タイミング |
|---|---|---|
| `vault_inventory.py` | 方針ノートの updated 欠落・リンク切れ・旧方針の残存等の棚卸しレポート | 毎月1日・15日 03:00 |
| `fragments_log.py` | Fragments（日次断片）の週次昇格候補ログ | 毎週月曜 03:30 |

対応する LaunchAgent 2種は `scripts/install-vault-agents.sh` が配置します（メイン専用・任意）。注記: これらのplistはインタプリタとして `/usr/bin/python3`（macOS標準のPython）をハードコードしています。

### ズレの検知（check-drift.sh）

```sh
scripts/check-drift.sh
```

以下5点を検査し、一覧表示します（**検知しても exit 1 にはしません**。あくまで手動確認用のレポートツールです）:

1. symlink 12ファイルが repo の実体を指しているか
2. `~/.codex/config.toml`（生成物）が repo のテンプレとプレースホルダ展開込みで一致しているか
3. このリポジトリに未commitの変更が無いか
4. `vault-public/Preferences` と実Vaultの `Preferences` に差分が無いか（`export-public-vault.sh` のエクスポート漏れ検知）
5. Vaultバックアップ・私的パッチrepo（`AIENV_PRIVATE_REPO`、既定 `~/work/takumi009-ai-env-private`）の remote が GitHub上で実際に **private** のままか（`gh repo view --json visibility`）。private であるべきリポジトリが誤って public 化されていないかの恒久チェックです。remote未設定は対象外、`gh` 未導入・未認証時は drift にはせず警告表示のみ（ai-env 本体は「public化予定」のためこのチェックの対象外）

このスクリプト自体は手動実行のレポートツールですが、`scripts/drift-notify.sh` 経由で `launchagents/com.takumi009.drift-check.plist`（メイン専用・`install-main.sh` が自動設置）から週1（月曜09:30）で無人実行され、drift が1件でもあれば macOS 通知で知らせます。

### 復元 Runbook（災害復旧・メインの移転）

> 実際に隔離環境で復旧ドリルを実施し、この手順で復元できることを実測済み（2026-07-08）。

#### メイン Mac が壊れたとき（災害復旧）

新しい Mac で上から順に実行する:

```sh
# 1. 前提ツール（Homebrew 導入後）
brew install gh && gh auth login          # GitHub 認証（以降の private clone に必要）

# 2. Vault（外部脳＝記憶）の復元
git clone <Vaultバックアップrepo(private)のURL> ~/Data/obsidian

# 3. 基本パッケージ＋私的パッチ
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
git clone <私的パッチrepo(private)のURL> ~/work/takumi009-ai-env-private
cd ~/work/takumi009-ai-env && brew bundle
~/work/takumi009-ai-env-private/install-private.sh   # docs/・ngwords を張り戻す

# 4. 環境の再構築
scripts/install-main.sh --with-dotfiles   # symlink 化＋dotfiles＋codex MCP 登録＋週次drift通知
scripts/install-backup.sh                 # 毎時バックアップ再開
scripts/install-vault-agents.sh           # Vault 育成系（任意）

# 5. 各アプリのログイン（手動）: Claude Code / Codex / その他
```

- 復元される範囲＝**push 済みの状態まで**。未 commit の作業は失われる（`scripts/check-drift.sh` の未 commit 検知で日常的に守る）
- バックアップの最大遅延は Mac のスリープに依存する（LaunchAgent はスリープ中発火せず、復帰時に1回追いつく）

#### メインの移転（新しい Mac に計画的に乗り換えるとき）

1. 旧メインで最後の同期: `scripts/backup-vault.sh` → `scripts/export-public-vault.sh` → 未 push が無いことを `scripts/check-drift.sh` で確認
2. 新 Mac で上記「災害復旧」手順を実行
3. 旧メインの LaunchAgent を停止（`launchctl bootout gui/$(id -u)/com.takumi009.<label>`）— **メインは常に1台**（編集権限・push 地点の一意性を守る）

### テスト

```sh
bash tests/test-export-public-vault.sh
bash tests/test-backup-vault.sh
bash tests/test-bootstrap-vault.sh
bash tests/test-install-sub.sh
bash tests/test-install-vault-agents.sh
bash tests/test-with-dotfiles.sh
bash tests/test-check-drift.sh
bash tests/test-drift-notify.sh
bash tests/test-install-main-drift-check.sh
bash tests/test-setup-codex-mcp.sh
bash tests/test-install-main-codex-mcp.sh
bash tests/test-update-sub.sh
bash tests/test-audit.sh
```

いずれも実 Vault・実 GitHub・実 `~/.claude`・実 `~/.codex` に依存せず、使い捨てのfixtureディレクトリ上で完結します（`rg`・`gitleaks` が必要。`brew bundle` 済みなら揃っています）。現時点で13スイート・359アサーション、全てpassしています。

### ライセンス
[MIT](LICENSE)
</content>
