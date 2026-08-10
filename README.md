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
│   ├── hooks/                 # bootstrap-vault.sh, check-sub-update.sh, delegation-gate-v2.sh, bash-danger-gate.sh, next-pane-resolve.sh, vault-recall.sh, vault-read-log.sh
│   └── agents/                # Worker role definitions (7 roles)
├── codex/
│   ├── AGENTS.md               # ~/.codex/AGENTS.md (symlink target)
│   ├── hooks.json               # ~/.codex/hooks.json (symlink target)
│   └── config.toml              # Template for ~/.codex/config.toml (generated, not a symlink; see below)
├── scripts/
│   ├── install-main.sh          # Installer for the main environment (symlink setup; supports --with-dotfiles)
│   ├── install-sub.sh           # Installer for the sub environment (sets up the Vault skeleton, then delegates to install-main.sh)
│   ├── install-backup.sh        # Installer for the Vault-backup LaunchAgent
│   ├── install-maintenance.sh   # Installer for the weekly maintenance-runner LaunchAgent (main only)
│   ├── setup-codex-mcp.sh       # Registers the codex MCP with Claude Code (auto-run by install-main.sh)
│   ├── backup-vault.sh          # Periodically git commits (+pushes) the Vault
│   ├── maintenance.sh           # Weekly maintenance runner (backup snapshot + detection + headless-Claude apply + summary; main only)
│   ├── update-sub.sh            # Manually-run command that refreshes the sub's rules (sub only; invoked on demand from the check-sub-update.sh SessionStart hook's guidance)
│   ├── export-public-vault.sh   # Exports the Vault's public folder to vault-public/
│   ├── check-drift.sh           # Manual audit tool that detects "drift" in symlinks/config.toml/repo/vault-public/private repo visibility
│   ├── audit.sh                 # One-shot pre-publish audit (NG words/username paths/secrets over full git history, tracked-file drift, completeness); `--quick` skips the (slow) history scan and only checks the current tree
│   ├── vault-agents/            # Detectors driven by maintenance.sh (vault_inventory.py, fragments_log.py, knowledge_merge_candidates.py, decision_propagation.py, maintenance_apply.py, etc.; main-only feature)
│   ├── ngwords.txt              # NG-word definitions (private data; **not included in this repository** — see "Setup" below)
│   └── templates/               # README templates for the private skeleton folders
├── launchagents/
│   ├── com.takumi009.backup-vault.plist       # Runs the Vault backup every 6 hours (main only)
│   └── com.takumi009.maintenance.plist        # Runs the weekly maintenance runner (main only)
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
brew bundle          # Reads the Brewfile and installs ripgrep, gitleaks, jq, gh, macmon
```

Claude Code / Codex themselves are outside brew's management, so install them separately from their official sites.

`scripts/ngwords.txt` (NG-word definitions used by `export-public-vault.sh` and `audit.sh`) is **not included in this repository** because it's private data. To run `export-public-vault.sh`/`audit.sh` as-is, either set `NGWORDS_FILE=/path/to/your/ngwords.txt` to point at your own file, or write your own NG-word list.

#### Main environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
scripts/install-main.sh          # Symlinks claude/ and codex/ into ~/.claude and ~/.codex
scripts/install-backup.sh        # Installs the Vault-backup LaunchAgent
scripts/install-maintenance.sh   # Installs the weekly maintenance-runner LaunchAgent (main only)
```

- `install-main.sh` moves any existing real file to `<dest>.pre-aienv.bak` only the first time before replacing it with a symlink (safe to re-run = idempotent). Use the `--dry-run` option to preview the plan only.
- Only `codex/config.toml` is generated as a real file — not a symlink — with the placeholder (`__AIENV_HOME__`) replaced by the actual home path (because plain TOML doesn't support shell variable expansion).
- Both `install-backup.sh` and `install-maintenance.sh` only place the LaunchAgents (bootstrap+enable) — they do **not** trigger an immediate run (kickstart) (because initializing the Vault as a Git repository for the first time is meant to be a staged rollout. Either wait for the next scheduled run, or once you're ready, run `launchctl kickstart -k` manually).
- At the end, `install-main.sh` automatically runs `scripts/setup-codex-mcp.sh`, which **auto-registers the codex MCP** (`mcp__codex__codex`/`codex-reply`, the core of the review setup) (`claude mcp add codex -s user -- <absolute path to codex> mcp-server`; skipped/idempotent if already registered). On environments where Claude Code / the codex command aren't installed, registration fails, but the installer as a whole still continues with a WARN rather than stopping. To register manually, run `scripts/setup-codex-mcp.sh` standalone, or run the suggested `claude mcp add` command directly.
- The weekly drift-notification LaunchAgent (`com.takumi009.drift-check.plist` / `scripts/drift-notify.sh`) that `install-main.sh` used to install, and the standalone Vault-cultivation LaunchAgents (`vault-inventory`/`fragments-log`/`knowledge-merge-detect`) formerly installed by `install-vault-agents.sh`, were all removed/consolidated on 2026-07-16 (see [[Decisions/2026-07-16-nightly-batch-direct-write]] in the Vault). `install-maintenance.sh` migrates any of these 4 retired LaunchAgent labels still loaded on the machine (bootout + remove) before installing the new `com.takumi009.maintenance` LaunchAgent. The unattended weekly path now lives entirely in the new `maintenance.sh` runner.
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
4. **Rule-update check on every session start**: `install-sub.sh` writes a "machine-role marker" file (`$HOME/.config/takumi009-ai-env/machine-role`, containing the text `sub`) — this is the positive proof that a machine is a sub. Conversely, `install-main.sh` writes `main` to the same marker whenever it's run directly (i.e. *not* via the internal `--sub-delegate` path that `install-sub.sh` uses to delegate the shared symlink/config-generation work to it) — this covers the case where a machine that used to be a sub gets later turned into a main by running `install-main.sh` on it directly, overwriting any leftover `sub` marker. When `install-main.sh` is invoked *via* `--sub-delegate`, it never touches the marker at all, leaving that entirely to `install-sub.sh`. `claude/hooks/check-sub-update.sh` (a SessionStart hook) checks this marker on every Claude Code session start; if it isn't exactly `sub` (missing file, wrong content, unreadable, etc.) it does nothing and exits silently (fail-closed). On an actual sub machine it does a time-boxed `git fetch` (fail-open: any failure/timeout/offline situation is silently ignored so it never blocks session startup, though failures are logged to `/tmp/check-sub-update.log`), and if the repository is behind `origin/main`, prints a notice telling you to run `scripts/update-sub.sh` yourself. `scripts/update-sub.sh` itself also checks the same marker at the very start and refuses to run (via `fail()`) if it isn't `sub` — this is the last line of defense against accidentally running it on the main machine, where its `rsync --delete` step would wipe out the main Vault's `Preferences/`. (Until 2026-07-23 the detection here used to be based on the *absence* of Vault private-layer files, and the rule-update itself was driven by an unattended `com.takumi009.update-sub` LaunchAgent that ran twice a day at 09:00/13:00; both were replaced — the LaunchAgent by this session-start check + manual run, and the negative-proof detection by the explicit marker file, after a code review flagged the false-negative risk of the old absence-based check. `install-sub.sh` no longer installs any LaunchAgent for the sub machine at all.) Beyond the marker check, `scripts/update-sub.sh`'s own behavior is unchanged: it `git pull --ff-only`s this repository, and if there are changes, automatically regenerates `codex/config.toml`, re-syncs `vault-public/Preferences/` (**touches nothing outside Preferences**, so local `Fragments` etc. on the sub machine are not deleted), and fills in any new skeleton folders. If there are no changes, it exits quietly (since subs aren't meant to be edited, a `git pull` that can't fast-forward normally shouldn't happen, but if it does, it just prints a warning and stops rather than force-overwriting).

On sub machines, private notes such as `Personal/profile-personal.md` and `Knowledge/mistakes.md` don't exist, but since `bootstrap-vault.sh` (the SessionStart hook) is designed to only list **files that actually exist** as required reading, no "not found" warnings appear.

#### Also install dotfiles (a separate component)

```sh
scripts/install-main.sh --with-dotfiles   # or install-sub.sh --with-dotfiles
```

If `$HOME/work/dotfiles` doesn't exist, it `git clone`s it ([Takumi00Nine/dotfiles](https://github.com/Takumi00Nine/dotfiles)) and then calls `./install.sh` (if it already exists, skips the clone and just calls `install.sh`). Off by default (dotfiles are never touched unless this option is given). dotfiles are a "component" outside ai-env's scope, but the installer can call it as a subcontractor.

### Vault Backup Operations

`scripts/backup-vault.sh` targets `$HOME/Data/obsidian`: if there are changes, it runs `git add -A && git commit` (message: `backup: YYYY-MM-DD HH:MM`), and pushes only if the `origin` remote is already configured (if not, it stops with a warning after committing). It has locking to prevent concurrent runs (mutual exclusion via atomic file creation) and stale detection for `git index.lock`, and is meant to run unattended every 6 hours via `launchagents/com.takumi009.backup-vault.plist` (installed by `scripts/install-backup.sh`).

The user creates and configures the remote for the Vault's backup destination (a private repo) themselves (the scripts in this repository never create a remote on their own).

### Weekly Maintenance Runner (main only)

`scripts/maintenance.sh` is the single weekly runner (Monday 03:00, installed by `scripts/install-maintenance.sh`) that replaced the older separate Vault-cultivation LaunchAgents on 2026-07-16 (see [[Decisions/2026-07-16-nightly-batch-direct-write]] in the Vault — "the nightly batch writes to the Vault directly, no more report → leader-processes-it indirection"). It runs in 4 phases:

- **Phase 0** — takes a pre-run snapshot via `backup-vault.sh`, acquires a Vault write-lock (PID file, held through Phase 3), and retries `export-public-vault.sh` if the `vault-public/Preferences` snapshot is behind.
- **Phase 1 (detection only, read-only)** — runs, in order, `check-drift.sh` (environment health check; since 2026-08-10, a drift finding, execution error, or timeout no longer aborts the run — it's recorded as a warning and the run continues. The sole gate for Vault write safety is Phase 0's pre-run snapshot), `fragments_log.py`, `vault_inventory.py`, `knowledge_merge_candidates.py`, and `decision_propagation.py`. Steps 1–5 are isolated from each other's failures.
- **Phase 2** — `scripts/vault-agents/maintenance_apply.py` sends the Phase 1 detection results to a single headless Claude Code call (tool use fully disabled, JSON-Schema-constrained structured output, independently re-validated) and, only for validated, safe actions, promotes Fragments directly into `Knowledge/Decisions/Projects`, or non-destructively merges obviously-duplicate `Knowledge/` notes (2/week cap) — all with TOCTOU re-checks immediately before each write. A Fragment promoted to `Preferences` is **not** written to the Vault at all; the draft is saved outside the Vault as a pending proposal that requires the user and the leader to jointly review and explicitly approve it before it's created in the Vault (since Preferences notes are public and shape AI behavior).
- **Phase 3** — appends a one-line summary to today's Fragments file, updates `last-run.json` (`last_success_at` only on a fully clean run; `last_result` — success/warn/fail — is always recorded, and a warning or failure shows up as a ⚠️ line in the next session's startup health check), takes a final `backup-vault.sh` snapshot, releases the Vault write-lock, sends a macOS notification only if something went wrong, and prunes maintenance logs older than 30 days.

All intermediate files and machine-readable status files for a given run live under `~/.claude/logs/maintenance/<YYYY-MM-DD>/<HHMMSS>-<pid>/`, with `~/.claude/logs/maintenance/latest` always pointing at the most recent run.

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

This script itself is a manually-run report tool. The former weekly unattended path (`scripts/drift-notify.sh` / `launchagents/com.takumi009.drift-check.plist`, Monday 09:30, macOS notification on drift>0) was removed on 2026-07-16; the unattended run now happens as check ① of the new `maintenance.sh` runner's Phase 1 (see above), with a `--json` mode added for that machine-readable use.

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
scripts/install-main.sh --with-dotfiles   # symlinks + dotfiles + codex MCP registration
scripts/install-backup.sh                 # Resume periodic backups
scripts/install-maintenance.sh            # Resume the weekly maintenance runner

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
bash tests/test-install-backup.sh
bash tests/test-install-maintenance.sh
bash tests/test-with-dotfiles.sh
bash tests/test-check-drift.sh
bash tests/test-setup-codex-mcp.sh
bash tests/test-install-main-codex-mcp.sh
bash tests/test-update-sub.sh
bash tests/test-check-sub-update.sh
bash tests/test-audit.sh
```

None of them depend on the real Vault, real GitHub, the real `~/.claude`, or the real `~/.codex` — they run entirely against disposable fixture directories (`rg` and `gitleaks` are required; both are already available once `brew bundle` has been run). This list predates several `tests/test-*.sh` files added during the 2026-07-16 simplification project (e.g. `test-shell-lib.sh`, `test-vault-lib.sh`, `test-merge-checks.sh`, `test-maintenance-run-step.sh`, and others) — run `ls tests/test-*.sh` for the full, current set and suite count (intentionally not restated here as a fixed number, to avoid drifting out of sync again).

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
│   ├── hooks/                 # bootstrap-vault.sh・check-sub-update.sh・delegation-gate-v2.sh・bash-danger-gate.sh・next-pane-resolve.sh・vault-recall.sh・vault-read-log.sh
│   └── agents/                # ワーカー役割定義（7ロール）
├── codex/
│   ├── AGENTS.md               # ~/.codex/AGENTS.md （symlink先）
│   ├── hooks.json               # ~/.codex/hooks.json （symlink先）
│   └── config.toml              # ~/.codex/config.toml のテンプレ（symlinkではなく生成、後述）
├── scripts/
│   ├── install-main.sh          # メイン環境用インストーラ（symlink化。--with-dotfiles対応）
│   ├── install-sub.sh           # サブ環境用インストーラ（Vault骨格配置＋install-main.shへ委譲）
│   ├── install-backup.sh        # Vaultバックアップ用LaunchAgentのインストーラ
│   ├── install-maintenance.sh   # 週次メンテナンスランナー用LaunchAgentのインストーラ（メイン専用）
│   ├── setup-codex-mcp.sh       # codex MCPをClaude Codeへ登録するスクリプト（install-main.shが自動実行）
│   ├── backup-vault.sh          # Vaultを定期的にgit commit（+push）するスクリプト
│   ├── maintenance.sh           # 週次メンテナンスランナー（バックアップ＋検出＋ヘッドレスClaude適用＋サマリ。メイン専用）
│   ├── update-sub.sh            # サブのルールを最新化する手動実行コマンド（サブ専用。check-sub-update.shの案内から本人が実行）
│   ├── export-public-vault.sh   # Vaultのpublicフォルダを vault-public/ へエクスポートするスクリプト
│   ├── check-drift.sh           # symlink/config.toml/repo/vault-public/private repo可視性の「ズレ」を検知する手動監査ツール
│   ├── audit.sh                 # public公開前の総監査ツール（git履歴全体のNGワード/実ユーザー名パス/シークレット・追跡ファイル逸脱・完備性）。`--quick` で履歴スキャン（重い）を省き現在ツリーのみ実行
│   ├── vault-agents/            # maintenance.shが起動する検出器群（vault_inventory.py・fragments_log.py・knowledge_merge_candidates.py・decision_propagation.py・maintenance_apply.py等。メイン専用機能）
│   ├── ngwords.txt              # NGワード定義（私的データのため**このリポジトリには含まれない**。詳細は「導入手順」参照）
│   └── templates/               # private骨格フォルダ用のREADMEテンプレ
├── launchagents/
│   ├── com.takumi009.backup-vault.plist       # Vaultバックアップを6時間ごとに実行（メイン専用）
│   └── com.takumi009.maintenance.plist        # 週次メンテナンスランナーを実行（メイン専用）
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
brew bundle          # Brewfile を見て ripgrep・gitleaks・jq・gh・macmon を導入
```

Claude Code / Codex 本体アプリは brew 管理外のため、各公式サイトから別途インストールしてください。

`scripts/ngwords.txt`（`export-public-vault.sh`・`audit.sh` が使うNGワード定義）は私的データのため**このリポジトリには含まれません**。`export-public-vault.sh`/`audit.sh` をそのまま実行するには、`NGWORDS_FILE=/path/to/your/ngwords.txt` で自分のファイルを指定するか、自分のNGワード定義を作成してください。

#### メイン環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
scripts/install-main.sh          # claude/・codex/ を ~/.claude・~/.codex へ symlink 化
scripts/install-backup.sh        # Vaultバックアップ用LaunchAgentを配置
scripts/install-maintenance.sh   # 週次メンテナンスランナー用LaunchAgentを配置（メイン専用機能）
```

- `install-main.sh` は既存の実ファイルを初回だけ `<dest>.pre-aienv.bak` に退避してから symlink に置き換えます（再実行しても安全＝冪等）。`--dry-run` オプションで計画だけを確認できます。
- `codex/config.toml` だけは symlink ではなく、プレースホルダ（`__AIENV_HOME__`）を実ホームパスへ置換した実ファイルとして生成されます（plain TOML はシェル変数展開されないため）。
- `install-backup.sh`・`install-maintenance.sh` はどちらも LaunchAgent の配置（bootstrap+enable）までを行い、**即時実行（kickstart）はしません**（Vault の初回git化は段階的ロールアウトが前提のため。初回実行は次回の定期発火を待つか、準備が整ってから手動で `launchctl kickstart -k` してください）。
- `install-main.sh` は末尾で `scripts/setup-codex-mcp.sh` を自動実行し、**codex MCP（`mcp__codex__codex`/`codex-reply`、レビュー体制の中核）を自動登録**します（`claude mcp add codex -s user -- <codexの絶対パス> mcp-server`。既に登録済みならskip・冪等）。Claude Code / codex コマンドが未導入の環境では登録に失敗しますが、その場合も installer 全体は止まらず WARN で続行します。手動で登録する場合は `scripts/setup-codex-mcp.sh` を単体実行するか、案内される `claude mcp add` コマンドを直接実行してください。
- `install-main.sh` が配置していた**週次drift通知LaunchAgent**（`com.takumi009.drift-check.plist`／`scripts/drift-notify.sh`）と、`install-vault-agents.sh`（撤去済み）が配置していたVault育成系LaunchAgent3種（`vault-inventory`／`fragments-log`／`knowledge-merge-detect`）は、いずれも2026-07-16の簡素化で撤去・統合しました（Vault内 `Decisions/2026-07-16-nightly-batch-direct-write` 参照）。`install-maintenance.sh` はこの旧4ラベルがまだマシンに残っていれば移行（bootout＋削除）してから新設の `com.takumi009.maintenance` LaunchAgentを設置します。週次無人実行の経路は新設の `maintenance.sh` ランナーへ完全に移りました。
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
4. **セッション開始のたびに更新有無を確認**: `install-sub.sh` は「machine-roleマーカー」ファイル（`$HOME/.config/takumi009-ai-env/machine-role`、中身は`sub`）を書き込みます。これは「このマシンがサブである」ことの積極的な証明です。逆に `install-main.sh` は、内部で`install-sub.sh`が使う`--sub-delegate`経路**を経由せず**直接実行された場合は、同じマーカーへ`main`を書き込みます（かつてサブ機だった機体を、後から`install-main.sh`を直接実行してメイン機へ移行する場合に、残っている旧`sub`マーカーを上書きするため）。`--sub-delegate`経由（＝`install-sub.sh`からの委譲）で呼ばれた場合、`install-main.sh`はマーカーに一切触れず、`install-sub.sh`側の書込に完全に委ねます。`claude/hooks/check-sub-update.sh`（SessionStartフック）はセッション起動のたびにこのマーカーを確認し、中身がちょうど`sub`でなければ（ファイル無し・中身違い・読めない等）何もせず静かにexitします（fail-closed）。実際のサブ機では時間上限つきの `git fetch` を実行し（fail-open＝失敗・タイムアウト・オフライン等は静かに無視してセッション起動をブロックしません。ただし失敗は `/tmp/check-sub-update.log` に記録されます）、`origin/main` より遅れていれば `scripts/update-sub.sh` を自分で実行するよう案内します。`scripts/update-sub.sh` 自体も冒頭で同じマーカーを確認し、`sub`でなければ`fail()`で拒否します（メイン機で誤って実行された場合、`rsync --delete`でメインVaultの`Preferences/`が消えてしまうのを防ぐ最後の砦）。（2026-07-23までは、この判定はVaultのprivate層ファイルが「無い」ことを根拠にしており、更新自体も `com.takumi009.update-sub` LaunchAgentによる1日2回＝09:00/13:00の無人自動pullでした。レビューで旧判定方式の誤検知リスク（否定証明）が指摘され、LaunchAgentはセッション起動時の確認＋手動実行に、判定方式は明示的なマーカーファイルに、それぞれ置き換えました。`install-sub.sh` はサブ機向けのLaunchAgentをもう一切設置しません）。マーカー確認を除く `scripts/update-sub.sh` 自体の処理内容は変更していません: このリポジトリを `git pull --ff-only` し、変化があれば `codex/config.toml` の再生成・`vault-public/Preferences/` の再同期（**Preferences以外には一切触れません**＝サブ機ローカルの `Fragments` 等は消えません）・新しい骨格フォルダの補充を自動で行います。変化が無ければ静かに終了します（サブは編集しない運用のため `git pull` が fast-forward できない事態は通常起きませんが、その場合は警告を出すだけで停止し、強制上書きはしません）。

サブ機では `Personal/profile-personal.md`・`Knowledge/mistakes.md` 等の private ノートが存在しませんが、`bootstrap-vault.sh`（SessionStartフック）は**存在するファイルだけ**を必読リストに載せる設計のため、「見つかりません」という警告は出ません。

#### dotfiles（部品）も一緒に導入する

```sh
scripts/install-main.sh --with-dotfiles   # または install-sub.sh --with-dotfiles
```

`$HOME/work/dotfiles` が無ければ `git clone`（[Takumi00Nine/dotfiles](https://github.com/Takumi00Nine/dotfiles)）してから `./install.sh` を呼びます（既に存在する場合は clone をskipして `install.sh` だけ呼びます）。既定は OFF（このオプションを付けない限りdotfilesには一切触れません）。dotfiles は ai-env のスコープ外の「部品」ですが、インストーラが下請けとして呼び出せるようにしています。

### Vault バックアップの運用

`scripts/backup-vault.sh` は `$HOME/Data/obsidian` を対象に、変更があれば `git add -A && git commit`（メッセージ: `backup: YYYY-MM-DD HH:MM`）し、remote `origin` が設定済みの場合のみ push します（未設定なら commit までで警告を出して終了）。多重起動防止のロック（原子的なファイル作成による排他制御）・`git index.lock` のstale検知つきで、`launchagents/com.takumi009.backup-vault.plist`（`scripts/install-backup.sh` が配置）から6時間ごとに無人実行される想定です。

Vault のバックアップ先（private repo）の作成・remote設定は本人が行います（このリポジトリのスクリプトは remote を勝手に作成しません）。

### 週次メンテナンスランナー（メイン専用機能）

`scripts/maintenance.sh` は、2026-07-16の簡素化で旧来の個別Vault育成系LaunchAgentを統合した単一の週次ランナーです（毎週月曜03:00・`scripts/install-maintenance.sh` が設置。Vault内 `Decisions/2026-07-16-nightly-batch-direct-write`「夜間バッチが直接Vaultへ書く・レポート→リーダー処理の間接ループを廃止」参照）。4フェーズで構成されます:

- **Phase 0** — `backup-vault.sh` で直前スナップショットを取得し、Vault書込ロック（PIDファイル・Phase 3終了まで保持）を取得。`vault-public/Preferences` のスナップショットが遅れていれば `export-public-vault.sh` を再試行。
- **Phase 1（検出のみ・読み取り専用）** — `check-drift.sh`（環境ヘルスの点検。2026-08-10からdrift検知・実行異常・timeoutを検知しても中断せず警告として記録し完走する。Vault書込み安全の門番はPhase 0の直前スナップショット取得のみに一本化されている）→ `fragments_log.py` → `vault_inventory.py` → `knowledge_merge_candidates.py` → `decision_propagation.py` の順で実行。①〜⑤は互いの失敗から隔離される。
- **Phase 2** — `scripts/vault-agents/maintenance_apply.py` がPhase 1の検出結果をヘッドレスClaude Codeへ1回だけ渡し（ツール使用を完全無効化・JSON Schemaで構造を強制した出力を独立に再検証）、安全と確認できたactionのみ、Fragmentsを `Knowledge/Decisions/Projects` へ直接昇格、またはKnowledge内の明白な重複ノートの非破壊マージ（週2件上限）のいずれかをVaultへ適用する（各書込み直前にTOCTOU再照合）。`Preferences` へのFragments昇格だけはVaultへ一切書き込まれない：下書きはVault外へ「承認待ちの提案」として保管され、本人とリーダーが協働レビューし明示的に承認して初めてVaultへ作成される（Preferencesは公開物かつAIの挙動を左右するため）。
- **Phase 3** — 実施サマリをFragments当日ファイルへ1行追記、`last-run.json` を更新（`last_success_at`は完全正常終了時のみ・`last_result`はsuccess/warn/failの実行結果を毎回記録し、警告/失敗があれば翌セッションの起動ヘルス行に⚠️で表示される）、`backup-vault.sh` で最終スナップショットを取得、Vault書込ロックを解放、異常時のみmacOS通知、30日超過のログを削除。

各回の中間ファイル・機械可読status-fileは `~/.claude/logs/maintenance/<YYYY-MM-DD>/<HHMMSS>-<pid>/` 配下にまとまり、`~/.claude/logs/maintenance/latest` が常に最新の実行を指します。

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

このスクリプト自体は手動実行のレポートツールです。従来の週次無人実行経路（`scripts/drift-notify.sh`／`launchagents/com.takumi009.drift-check.plist`。毎週月曜09:30・drift1件以上でmacOS通知）は2026-07-16に撤去し、無人実行は新設の `maintenance.sh` ランナーのPhase 1①として行うようになりました（機械可読な `--json` モードもこの用途で追加。上記Vault決定参照）。

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
scripts/install-main.sh --with-dotfiles   # symlink 化＋dotfiles＋codex MCP 登録
scripts/install-backup.sh                 # 定期バックアップ再開
scripts/install-maintenance.sh            # 週次メンテナンスランナー再開

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
bash tests/test-install-backup.sh
bash tests/test-install-maintenance.sh
bash tests/test-with-dotfiles.sh
bash tests/test-check-drift.sh
bash tests/test-setup-codex-mcp.sh
bash tests/test-install-main-codex-mcp.sh
bash tests/test-update-sub.sh
bash tests/test-check-sub-update.sh
bash tests/test-audit.sh
```

いずれも実 Vault・実 GitHub・実 `~/.claude`・実 `~/.codex` に依存せず、使い捨てのfixtureディレクトリ上で完結します（`rg`・`gitleaks` が必要。`brew bundle` 済みなら揃っています）。このリストは2026-07-16簡素化プロジェクトで追加された複数の`tests/test-*.sh`（例: `test-shell-lib.sh`・`test-vault-lib.sh`・`test-merge-checks.sh`・`test-maintenance-run-step.sh`等）を反映できていません。現時点の全テスト・スイート数は`ls tests/test-*.sh`で確認してください（本節が最後に更新された時点より増えているため、ここに固定の件数は書きません＝また食い違う事故を避けるため）。

### ライセンス
[MIT](LICENSE)
