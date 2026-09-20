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
│   ├── settings.json          # ~/.claude/settings.json template (generated)
│   ├── hooks/                 # Claude Code hooks
│   └── agents/                # Worker role definitions (one .md per role)
├── codex/                     # AGENTS.md, hooks.json (symlink targets), config.toml template (generated)
├── scripts/
│   ├── install-main.sh        # Main-environment installer
│   ├── install-sub.sh         # Sub-environment installer
│   ├── install-backup.sh      # Vault-backup LaunchAgent installer
│   ├── install-maintenance.sh # Weekly-maintenance LaunchAgent installer (main only)
│   ├── install-usage-fetch.sh # Usage-fetch LaunchAgent installer
│   ├── codex-exec.sh          # Sole entry point for Codex (`codex exec` wrapper)
│   ├── claude-exec.sh         # Sole entry point for a worker as a separate `claude -p` process
│   ├── backup-vault.sh        # Git commits (+pushes) the Vault
│   ├── usage-fetch.sh         # Claude/Codex usage → cache read by dotfiles' cmux-usage-watch.sh
│   ├── maintenance.sh         # Weekly maintenance runner (main only)
│   ├── maintenance-kick.sh    # Manual kick of the weekly runner via launchd (same record as the scheduled run)
│   ├── fragments-reviewed.sh  # Closes out a Fragments promotion (see below)
│   ├── update-sub.sh          # Refreshes the sub's rules (sub only, manual)
│   ├── export-public-vault.sh # Vault public folder → vault-public/
│   ├── check-drift.sh         # Manual "drift" report tool
│   ├── audit.sh               # Pre-publish audit (`--quick` = current tree only)
│   ├── vault-agents/          # Detectors driven by maintenance.sh (main only)
│   ├── ngwords.txt            # NG words (private; **not in this repository**)
│   └── templates/             # README templates for the private skeleton folders
├── launchagents/              # backup-vault (every 6 hours) / maintenance (weekly) plists (main only)
├── vault-public/              # Snapshot of the Vault's public folders (see below)
├── Brewfile                   # `brew bundle` dependencies
└── tests/                     # Unit tests
```

### Roles: Orchestrator / Worker / Codex

`claude/agents/` and this environment's workflow are built around three role words:

- **Orchestrator (leader)**: The main Claude Code session. It makes decisions, talks with the user, and directs the overall workflow — it delegates implementation/investigation/testing to workers rather than doing them itself.
- **Worker**: A subagent launched from one of the role definitions under `claude/agents/` (one `.md` per role; the set is whatever the directory holds — currently requirements-analyst, system-designer, implementer, verifier, researcher, operator, adoption-critic, vault-scribe). Adding or removing a role = editing that directory and the local profile only (contract and steps: see 日本語 §「職種定義の契約と設定変更の手順」).
- **Codex**: The default cast for the verifier role, invoked via `scripts/codex-exec.sh` (a Bash wrapper around `codex exec`; continuation of a review thread uses the wrapper's `--resume` flag). Workers don't invoke it themselves — the orchestrator starts verification once a stage's deliverable is complete, and workers only apply the resulting findings.

How a worker is launched (`resolve-candidate`, in-process `Agent` rejection, `claude-exec.sh`) — details = the comment at the top of `scripts/claude-exec.sh`.

### About vault-public/

This repository's `vault-public/` is a full-copy snapshot of only the folders in the external brain (Obsidian Vault) that have been designated as "containing no personal information" (currently `Preferences/`). The remaining folders that may contain personal information (`Personal/` `Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/` `Blogs/`) are reproduced as **empty folders with just a README.md, no content** (so that a sub machine trying to write to them doesn't fail with "folder not found"). The export is triggered from two places: the weekly `maintenance.sh` Phase 0 and the close of each task on the main machine (`check-drift.sh` only reports a stale snapshot as informational).

Generation/updating is done by `scripts/export-public-vault.sh` (details = the comment at the top of the script).

### Setup

#### 0. Install dependencies (common)

```sh
brew bundle          # Reads the Brewfile and installs ripgrep, gitleaks, jq, gh, macmon
```

Claude Code / Codex themselves are outside brew's management, so install them separately from their official sites. `install-main.sh` requires `python3` (details = the comment at the top of `scripts/install-main.sh`).

`scripts/ngwords.txt` (NG-word definitions used by `export-public-vault.sh` and `audit.sh`) is **not included in this repository** because it's private data. To run `export-public-vault.sh`/`audit.sh` as-is, either set `NGWORDS_FILE=/path/to/your/ngwords.txt` to point at your own file, or write your own NG-word list.

#### Main environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # Local role-cast profile (real main-machine values)
cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # Model definitions (real main-machine values)
scripts/install-main.sh          # Symlinks claude/ and codex/ into ~/.claude and ~/.codex
scripts/install-backup.sh        # Installs the Vault-backup LaunchAgent
scripts/install-maintenance.sh   # Installs the weekly maintenance-runner LaunchAgent (main only)
scripts/install-usage-fetch.sh --dry-run  # Preview the usage-fetch install (prints the current state only)
scripts/install-usage-fetch.sh            # Installs the usage-fetch LaunchAgent
```

Details = the comments at the top of `scripts/install-main.sh` (`config/*.sample`, generated files), `scripts/lib/managed-symlink.sh` (backups), `claude/hooks/lib/role_candidates.py`, `scripts/install-backup.sh`/`install-maintenance.sh` (no kickstart), `scripts/codex-exec.sh --help`, and `scripts/claude-exec.sh`.

On the main environment, a **private patch (a separate private repository)** is layered on top of this base package. The private patch contains the Vault's substance (`~/Data/obsidian`) and settings that cannot be made public. See that repository's own documentation for its setup steps.

#### Sub environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # then edit machine_role (and role.leader if needed)
cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # then trim/enable the model defs this machine actually uses
scripts/install-sub.sh
```

Details = the comments at the top of `scripts/install-sub.sh`, `claude/hooks/check-sub-update.sh`, and `scripts/update-sub.sh`.

##### Updating an existing sub machine (when a new schema/config lands)

1. `git pull --ff-only` (a plain pull, not `update-sub.sh` — with the old profile still in place, `update-sub.sh` itself would refuse to run).
2. Only if the schema changed: copy the samples over the real files (`cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md`, `cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf`; back up the existing real file first, permission `0600`) and edit the profile for this sub machine — at least `machine_role: configured value=sub` (the samples carry the main machine's values), plus `role.leader`, `no_read_paths`, `team_mode` as needed. `scripts/install-sub.sh --check-profile` prints the resolve result as one line with no side effects.
3. `scripts/update-sub.sh` — pull → `install-sub.sh` → `vault-public/Preferences/` re-sync, every run (no flags; the old re-sync flag is gone). Confirm it ends with `done.`; a new session's mode line should then show the current version. If it prints `AGENTS: dangling`, delete the file(s) it names.

⚠️ `update-sub.sh`'s failure message attributes the cause to "the role-cast profile's `machine_role` isn't `sub`", but the exact same message also appears when the real cause is an old-schema profile whose fixed keys read as `unknown` (the resolver's own `stderr` is discarded). Run `profile_resolve.py resolve` directly first to see what it's actually reading before assuming which cause applies.

#### Also install dotfiles (a separate component)

```sh
scripts/install-main.sh --with-dotfiles   # or install-sub.sh --with-dotfiles
cd ~/work/dotfiles && git pull --ff-only && ./install.sh   # refresh an existing dotfiles checkout
```

cmux Dock's "Project"/"Task" panes — details = `Decisions/2026-09-15-cmux-dock-two-repo-split` in the Vault.

### Vault Backup Operations

`scripts/backup-vault.sh` targets `$HOME/Data/obsidian`: if there are changes, it runs `git add -A && git commit` (message: `backup: YYYY-MM-DD HH:MM`), and pushes only if the `origin` remote is already configured (if not, it stops with a warning after committing). Details = the comment at the top of the script.

### Weekly Maintenance Runner (main only)

`scripts/maintenance.sh` is the single weekly runner (Monday 06:00, installed by `scripts/install-maintenance.sh`). Details = the comment at the top of the script.

**State record contract (schema 2)** — `~/.claude/logs/maintenance/last-run.json` is the single source of truth for the weekly runner's result, read by the health judge (`claude/hooks/lib/health_judge.py`, via the SessionStart hook and the Dock). The legacy 6 keys (`started_at` / `last_success_at` / `last_result` / `last_result_summary` / `fragments_candidates` / `fragments_since`) are still written for the older readers; the new readers use only the keys below.

- `run` — the most recent **start** and how it ended. Written unconditionally at start (`status: running`, together with `started_at`), and rewritten **as a whole with the runner's own content** on every one of the 6 endings: completed (finish / Phase 0 snapshot failure / Vault write-lock failure / run-dir creation failure) → `status: completed`; busy-skip (Phase 0 backup busy → `skipped` + `skip_reason: busy:backup0`; Vault write-lock busy → `skipped` + `busy:lock`). Fields = `run_id` (`<date>/<HHMMSS-pid>`), `run_dir`, `started_at`, `trigger` (`scheduled` / `manual`), `status`, `stale_after_seconds` (a copy of `MAINTENANCE_STALE_LOCK_SECONDS`; the reader uses it to tell "still running" from "interrupted"), `skip_reason`, `finished_at`. A record left at `running` past `stale_after_seconds` means the runner died without a completion record.
- `completed` — the most recent **completion record** (only the 4 completed endings write it; busy-skips leave the previous one). `fully_ok` is true only for a fully clean run. `steps[]` holds **one entry per abnormal step** (clean steps are not listed): `id` (`phase0-dir` / `phase0-lock` / `phase0-backup` / `phase0-export` / `phase1-drift` / `phase1-fragments` / `phase1-inventory` / `phase3-summary` / `phase3-backup` / `phase3-record`), `name`, `result` (`fail` / `warn` — a child's failure the runner continued past is still `fail`; `warn` is only a drift finding), `reason` (verbatim, never truncated; control characters normalized to spaces), `actor` (`AI` / `本人` from the runner's fixed table — drift findings are `本人`, everything else `AI`, unknown ids fall to `本人`), `log_ref` (that step's log under `run_dir`). `info[]` = informational notes that are not steps (unknown `config.toml` keys, declaration prune not performed).
- `success_streak` — number of consecutive fully-clean completions (reset to 0 on any abnormal completion).
- `ack` — the leader AI's "handled, judge on the next run" note (see *Acknowledging a finding*). The runner deletes it on the next fully-clean completion and keeps it on a re-failure (the judge then reports "re-failed after ack" because `ack.run_id != completed.run_id`).

**Manual kick (`scripts/maintenance-kick.sh`)** — runs the weekly runner through launchd (`launchctl kickstart` without `-k`), so it uses the same executable, environment (plist `HOME` / `PATH` / `USER`) and record as the scheduled run; it leaves a marker so the record says `trigger: manual` (a raw `launchctl kickstart` is recorded as `scheduled`). It refuses to start when the LaunchAgent is not loaded (`KICK_REFUSED:not_loaded`, exit 2), when the Vault write-lock is held or `run.status` is `running` within `stale_after_seconds` (`KICK_REFUSED:busy`, exit 3), or when the marker cannot be written (exit 4); `KICK_FAILED` (5) if kickstart fails, `KICK_TIMEOUT` (6) if no new `run.run_id` appears within 30 s (this also removes the marker — a run that starts late past this point is recorded as `scheduled`, not `manual`). On success it prints `RUN_ID:<id>` and `STATE_FILE:<path>`; with `--wait` it also waits until `run.status != running` and prints `STATUS:<completed|skipped>` plus `FULLY_OK:<true|false>` (or `SKIP_REASON:<busy:…>` — a busy-skip is not a failure; re-run a few minutes later). `KICK_WAIT_TIMEOUT` (7) if the completion record never appears.

**Closing out a promotion (`scripts/fragments-reviewed.sh`)** — run this once you've finished handling the Fragments promotion candidates the Dock's weekly line counted (after the recorder has marked each handled entry `status: promoted`), so the count returns to 0 without waiting for the next weekly run. It re-counts unprocessed Fragments starting exclusively from today (`fragments_log.py --since <today>`; today's own entries aren't counted — see the known limitation below), then writes `fragments_reviewed_at` (now, UTC), `fragments_candidates` and `fragments_since` to `last-run.json` atomically; the next weekly run's `--since` prefers `fragments_reviewed_at` over `last_success_at` when it's valid (not malformed, not in the future, within 30 days — otherwise it falls back the same way `last_success_at` always has). On any failure (the detector script failing/timing out, malformed JSON, or a contract violation) it writes nothing and exits non-zero with a one-line reason on stderr. `--dry-run` shows the 3 values it would write without writing them. Env vars for testing: `LAST_RUN_FILE`, `FRAGMENTS_LOG_PY`, `TIMEOUT_FRAGMENTS_LOG` (same defaults as `maintenance.sh`). Known limitation: because the window is date-granularity (`since_date < d`), Fragments added the *same day* the CLI runs won't be counted until the next day — run it last, after all promotions for the session are done.

**Acknowledging a finding (`health_judge.py ack`)** — the leader AI records "handled; judge on the next production run" in `last-run.json`'s `ack`:

```
python3 ~/work/takumi009-ai-env/claude/hooks/lib/health_judge.py ack \
  --last-run <path> --note "<what was done, one line>" \
  [--session-id <sid>] [--observation <session-observation.json>]
```

`--session-id` is optional; when omitted the current leader session id is read from the observation record (`${HEALTH_OBSERVATION_FILE:-$HOME/.claude/logs/health/session-observation.json}`, written by the SessionStart hook — there is no `CLAUDE_CODE_SESSION_ID` environment variable). If that cannot be read either, `session_id: null` is written (the ack still counts; the sid is for audit). It writes `{"at", "note", "session_id", "run_id"}` (`run_id` = the current `completed.run_id`) atomically. **Accepted only when** the record parses, `completed` exists, `completed.fully_ok == false` with at least one step, the runner is not running (`run.status == running` within `stale_after_seconds`) and the write-lock is not held; only `completed.steps` items can be acked (not-started / interrupted / broken / legacy / inventory / load / recall items have no ack — their OK condition is judged automatically on the next run or next session). Otherwise it prints one fixed line `ACK_REFUSED:<running|locked|broken|no_completed|nothing_to_ack>` and exits non-zero without touching the file. An ack never changes the health stage; only a production run does (expiry = deleted on the next fully-clean completion, kept on a re-failure).

### Usage Monitoring (usage_snapshot.py)

**Manual check**: `python3 claude/hooks/lib/usage_snapshot.py` prints the same 3 lines on demand (add `--json` for a single-line machine-readable snapshot). Details (the `UserPromptSubmit` block, prerequisite fetcher, Codex "tickets") = the docstring of `claude/hooks/lib/usage_snapshot.py`.

### Usage fetcher (scripts/usage-fetch.sh / scripts/install-usage-fetch.sh)

Install it with `scripts/install-usage-fetch.sh` (a plain bootstrap+enable installer, same shape as `install-backup.sh`; `--dry-run` only prints the current state). Details = the comments at the top of `scripts/usage-fetch.sh` and `scripts/install-usage-fetch.sh`.

### Drift Detection (check-drift.sh)

```sh
scripts/check-drift.sh
```

Checks the following 5 points and lists them (**it does not exit 1 even if drift is detected** = a report tool for manual checking): ① managed symlinks and the generated `~/.claude/settings.json`, ② the generated `~/.codex/config.toml`, ③ uncommitted changes in this repository, ④ `vault-public/Preferences` vs. the real Vault (informational only), ⑤ the Vault-backup / private-patch remote is still **private** on GitHub. Details = the comment at the top of the script.

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
mkdir -p ~/.config/takumi009-ai-env
cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # local config isn't part of any backup — recreate it
cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # (edit machine_role/model defs back to what this machine had)
scripts/install-main.sh --with-dotfiles   # symlinks + dotfiles
scripts/install-backup.sh                 # Resume periodic backups
scripts/install-maintenance.sh            # Resume the weekly maintenance runner
scripts/install-usage-fetch.sh --dry-run  # Resume usage tracking: print the current state first
scripts/install-usage-fetch.sh            # Resume usage tracking

# 5. Log in to each app (manual): Claude Code / Codex / others
```

- Scope of what's restored = **everything up to the pushed state** (uncommitted work is lost)
- The maximum backup delay depends on the Mac's sleep state

#### Main migration (planned move to a new Mac)

1. On the old main, do a final sync: `scripts/backup-vault.sh` → `scripts/export-public-vault.sh` → confirm there's nothing unpushed with `scripts/check-drift.sh`
2. Run the "disaster recovery" procedure above on the new Mac
3. Stop the old main's LaunchAgents (`launchctl bootout gui/$(id -u)/com.takumi009.<label>`) — **there is always exactly one main** (this preserves the uniqueness of edit permission / push location)

### Session handoff (scripts/session-handoff.sh)

When a session gets long, write a resume note, then use this script to open a new cmux workspace, start `cct` (Claude Code) in it, and send the follow-up request as a single line.

```sh
scripts/session-handoff.sh <path-to-resume-note> "<follow-up request>" [--cwd <dir>] [--name <title>]
scripts/session-handoff.sh -h | --help
```

Arguments, exit codes, and environment variables = `scripts/session-handoff.sh -h`.

### Tests

```sh
for t in tests/test-*.sh; do bash "$t"; done
```

None of them depend on the real Vault, real GitHub, the real `~/.claude`, or the real `~/.codex` — they run entirely against disposable fixture directories (`rg` and `gitleaks` are required; both are already available once `brew bundle` has been run).

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
│   ├── settings.json          # ~/.claude/settings.json のテンプレ（生成）
│   ├── hooks/                 # Claude Code のフック
│   └── agents/                # ワーカー役割定義（1 ファイル＝1 職種）
├── codex/                     # AGENTS.md・hooks.json（symlink先）・config.toml（生成）
├── scripts/
│   ├── install-main.sh        # メイン環境インストーラ
│   ├── install-sub.sh         # サブ環境インストーラ
│   ├── install-backup.sh      # バックアップ LaunchAgent 導入
│   ├── install-maintenance.sh # 週次メンテ LaunchAgent 導入（メイン専用）
│   ├── install-usage-fetch.sh # 使用率取得器 LaunchAgent 導入
│   ├── codex-exec.sh          # Codex を呼ぶ唯一の口（`codex exec`）
│   ├── claude-exec.sh         # ワーカー起動の唯一の口（`claude -p`）
│   ├── backup-vault.sh        # Vault を git commit（+push）
│   ├── usage-fetch.sh         # 使用率 → cmux-usage-watch.sh 用キャッシュ
│   ├── maintenance.sh         # 週次メンテナンスランナー（メイン専用）
│   ├── maintenance-kick.sh    # 週次ランナーの手動起動（launchd 経由・定期実行と同じ記録先）
│   ├── fragments-reviewed.sh  # 昇格の締め（後述）
│   ├── update-sub.sh          # サブのルール更新（サブ専用・手動）
│   ├── export-public-vault.sh # public フォルダ → vault-public/
│   ├── check-drift.sh         # 「ズレ」の手動レポート
│   ├── audit.sh               # 公開前の総監査（`--quick`＝現在ツリーのみ）
│   ├── vault-agents/          # maintenance.sh の検出器群（メイン専用）
│   ├── ngwords.txt            # NGワード（私的データ・**リポジトリに含まれない**）
│   └── templates/             # private 骨格フォルダの README テンプレ
├── launchagents/              # backup-vault／maintenance の plist
├── vault-public/              # public フォルダのスナップショット（後述）
├── Brewfile                   # `brew bundle` の依存
└── tests/                     # ユニットテスト
```

### 役割: リーダー／ワーカー／Codex

`claude/agents/` およびこの環境のワークフローは、次の3つの役割語を軸に組み立てられています。

- **リーダー（orchestrator）**: メインの Claude Code セッション。意思決定・ユーザー対話・工程全体の采配を行い、実装/調査/テストは自分でやらずワーカーへ委任します。
- **ワーカー（worker）**: `claude/agents/` 配下の役割定義（1 ファイル＝1 職種。集合はディレクトリの中身そのもの＝現在は要件定義・設計・実装・検証・調査・運用・採用判定・記録）で起動されるサブエージェントです。
- **Codex**: 一次レビュアー専任（`scripts/codex-exec.sh`＝`codex exec`のBashラッパー経由。レビュースレッドの継続はラッパーの`--resume`で行う）。ワーカーがリーダーへ報告する前に、自分の成果物のレビューを依頼する相手です。

ワーカーの起動の仕組みの詳細＝`scripts/claude-exec.sh` 冒頭のコメント。

#### 職種定義の契約と設定変更の手順

**職種定義の契約**（`claude/agents/<職種>.md` 1 本の中で全部満たせる。検査＝`bash tests/test-agent-definitions.sh`）
(a) 職種名（ファイル名＝`name`）は `^[a-z][a-z-]*$`（英小文字とハイフンのみ・先頭は英字・数字と `:` は不可。⚠️ 配役表 resolver の禁止キー部分一致語＝`auth`・`token`・`secret`・`password`・`credential`・`cookie`・`passphrase`・`access_key`・`api_key`・`private_key` を含む名前は `role.<職種>` 行が MINIMAL で拒否される＝例 `test-author` は不可） (b) frontmatter `name:` がファイル名（拡張子除く）と一致 (c) 組込み種別名（Explore・Plan・general-purpose・claude・statusline-setup・claude-code-guide）と衝突しない (d) `description:`・`tools:` が非空・本文が非空 (e) frontmatter に `model:`・`effort:` を書かない (f) 本文に `## 権限` 見出しがちょうど 1 件・`worker-role-prompts` への参照 0 件 (g) Vault の AI 向け 6 フォルダへ書く職種だけ frontmatter に `aienv-vault-write: allowed` を**ちょうど 1 行**（値はこれのみ・行末コメント不可・同じキーを 2 行以上書かない・`aienv-` で始まる他のキーは不可）。宣言の無い職種はラッパー経路で柵（`vault-write-gate.sh`）が載る。

**設定変更の手順**（追加・削除・改名とも）: ① `claude/agents/<職種>.md` を書く／消す ② `~/.config/takumi009-ai-env/profile.md` の `role.<職種>: …` 行を足す／消す（`config/profile.md.sample` が当該職種を参照していればそちらも） ③ `bash tests/test-agent-definitions.sh` が exit 0（数秒） ④ 追加は `bash scripts/install-main.sh` を再実行して `~/.claude/agents/<職種>.md` を配置・削除は `rm ~/.claude/agents/<職種>.md`（dangling symlink の除去）。Agent 経路は次に起動するセッションから有効（起動中のセッションは追随しない）。ラッパー経路は即時。改名＝削除＋追加。コア規範が名指す職種（工程 7 職＋vault-scribe）の削除・改名は規範改訂を伴う通常の変更。

### vault-public/ について

このリポジトリの `vault-public/` は、外部脳（Obsidian Vault）のうち「個人情報を含まない」と決めたフォルダ（現状 `Preferences/`）だけを丸ごとコピーしたスナップショットです。個人情報を含みうる残りのフォルダ（`Personal/` `Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/` `Blogs/`）は、**中身を含めず空フォルダ＋README.mdだけ**を再現しています（サブ機で書き込もうとした際に「フォルダが無い」で失敗しないようにするため）。export の起点は 2 つ＝週次 `maintenance.sh` の Phase 0 と、メイン機での案件の締め（`check-drift.sh` はスナップショットの遅れを informational として表示するだけ）。

生成・更新は `scripts/export-public-vault.sh` が行います（詳細＝スクリプト冒頭のコメント）。

### 導入手順

#### 0. 依存ツールの導入（共通）

```sh
brew bundle          # Brewfile を見て ripgrep・gitleaks・jq・gh・macmon を導入
```

Claude Code / Codex 本体アプリは brew 管理外のため、各公式サイトから別途インストールしてください。`install-main.sh` は `python3` を必要とします（詳細＝同スクリプト冒頭のコメント）。

`scripts/ngwords.txt`（`export-public-vault.sh`・`audit.sh` が使うNGワード定義）は私的データのため**このリポジトリには含まれません**。`export-public-vault.sh`/`audit.sh` をそのまま実行するには、`NGWORDS_FILE=/path/to/your/ngwords.txt` で自分のファイルを指定するか、自分のNGワード定義を作成してください。

#### メイン環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # 配役表（メイン機の実値）
cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # モデル定義（メイン機の実値）
scripts/install-main.sh          # claude/・codex/ を ~/.claude・~/.codex へ symlink 化
scripts/install-backup.sh        # Vaultバックアップ用LaunchAgentを配置
scripts/install-maintenance.sh   # 週次メンテナンスランナー用LaunchAgentを配置（メイン専用機能）
scripts/install-usage-fetch.sh --dry-run  # 使用率取得器: まず状態だけ確認（何もしない）
scripts/install-usage-fetch.sh            # 使用率取得器のLaunchAgentを導入
```

詳細＝`scripts/install-main.sh`（`config/*.sample`・生成物）・`scripts/lib/managed-symlink.sh`（退避規則）・`claude/hooks/lib/role_candidates.py`・`scripts/install-backup.sh`／`install-maintenance.sh`・`scripts/codex-exec.sh --help`・`scripts/claude-exec.sh` の冒頭コメント。

メイン環境では、この基本パッケージの上に**私的パッチ（別のprivateリポジトリ）**を重ねます。私的パッチには Vault の実体（`~/Data/obsidian`）や、公開できない設定が含まれます。私的パッチの導入手順は当該リポジトリ側のドキュメントを参照してください。

#### サブ環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # コピー後にmachine_role（必要ならrole.leaderも）を書き換える
cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # コピー後にこの機で使う定義だけ残す／有効化する
scripts/install-sub.sh
```

詳細＝`scripts/install-sub.sh`・`claude/hooks/check-sub-update.sh`・`scripts/update-sub.sh` 冒頭のコメント。

##### 既存サブ機の更新（新しい schema・設定が届いたとき）

1. `git pull --ff-only`（`update-sub.sh` ではなく素の pull。旧プロファイルのままでは `update-sub.sh` 自体が拒否するため）。
2. schema が変わったときだけ: sample を実体へコピーし（`cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md`・`cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf`。既存の実体は先に退避・権限 `0600`）、プロファイルをサブ機用に編集する——最低限 `machine_role: configured value=sub`（sample はメイン機の値のため）、必要に応じて `role.leader`・`no_read_paths`・`team_mode` も。`scripts/install-sub.sh --check-profile` が resolve 結果を1行で返す（副作用ゼロ）。
3. `scripts/update-sub.sh` — pull → `install-sub.sh` → `vault-public/Preferences/` 再同期を毎回行う（引数なし・旧・再同期フラグは廃止）。`done.` で終わることを確認し、新しいセッションの開幕1行で版を確認する。`AGENTS: dangling` が出た場合は、表示されたファイルを削除する。

⚠️ `update-sub.sh` の失敗文面は原因を「配役表の `machine_role` が `sub` でない」と示しますが、実際の起点が「プロファイルが旧 schema で固定キーが `unknown` 扱いになっている」場合でも同じ文面になります（resolver 自身の `stderr` は捨てられます）。まず `profile_resolve.py resolve` を直接叩いて何が読めているかを確認してから、原因を判断してください。

#### dotfiles（部品）も一緒に導入する

```sh
scripts/install-main.sh --with-dotfiles   # または install-sub.sh --with-dotfiles
cd ~/work/dotfiles && git pull --ff-only && ./install.sh   # 既存の dotfiles を更新
```

cmux Dock の「Project」／「Task」枠の詳細＝Vault の `Decisions/2026-09-15-cmux-dock-two-repo-split`。

### Vault バックアップの運用

`scripts/backup-vault.sh` は `$HOME/Data/obsidian` を対象に、変更があれば `git add -A && git commit`（メッセージ: `backup: YYYY-MM-DD HH:MM`）し、remote `origin` が設定済みの場合のみ push します（未設定なら commit までで警告を出して終了）。詳細＝スクリプト冒頭のコメント。

### 週次メンテナンスランナー（メイン専用機能）

`scripts/maintenance.sh` は単一の週次ランナーです（毎週月曜06:00・`scripts/install-maintenance.sh` が設置。詳細＝スクリプト冒頭のコメント）。

**状態記録の契約（schema 2）** — `~/.claude/logs/maintenance/last-run.json` が週次ランナーの実行結果の正本で、判定機（`claude/hooks/lib/health_judge.py`＝SessionStart フックと Dock が呼ぶ）が読みます。旧 6 キー（`started_at`／`last_success_at`／`last_result`／`last_result_summary`／`fragments_candidates`／`fragments_since`）は旧読み手のため従来どおり書きますが、新しい読み手は下のキーだけを使います。

- `run` — **直近の開始**とその終わり方。開始時に無条件で書き（`status: running`・`started_at` と同時）、**終わり方 6 経路すべてでランナー自身の内容で丸ごと書き直します**: 完了記録に到達する 4 経路（完走／Phase 0 直前スナップショット失敗／Vault 書込ロック取得失敗／実行ディレクトリ作成失敗）→ `status: completed`、busy-skip の 2 経路（Phase 0 backup が busy → `skipped`＋`skip_reason: busy:backup0`、Vault 書込ロックが busy → `skipped`＋`busy:lock`）。フィールド＝`run_id`（`<日付>/<HHMMSS-pid>`）・`run_dir`・`started_at`・`trigger`（`scheduled`／`manual`）・`status`・`stale_after_seconds`（`MAINTENANCE_STALE_LOCK_SECONDS` の写し。読み手はこの値で「実行中」と「中断」を分ける）・`skip_reason`・`finished_at`。`running` のまま `stale_after_seconds` を過ぎた記録＝完了記録に到達せずランナーが止まった（中断）。
- `completed` — **直近の完了記録**（完了記録に到達する 4 経路だけが書く。busy-skip は前回のまま残す）。`fully_ok` は完全正常終了のときだけ true。`steps[]` は**異常工程 1 つにつき 1 要素**（正常な工程は書かない）＝`id`（`phase0-dir`／`phase0-lock`／`phase0-backup`／`phase0-export`／`phase1-drift`／`phase1-fragments`／`phase1-inventory`／`phase3-summary`／`phase3-backup`／`phase3-record`）・`name`・`result`（`fail`／`warn`。子の失敗をランナーが警告として継続し完走しても `fail`。`warn` は drift 検知だけ）・`reason`（逐語・切り詰めない・制御文字は空白へ正規化）・`actor`（`AI`／`本人`＝ランナーの固定表。drift 検知は `本人`、他は `AI`、表に無い id は `本人`）・`log_ref`（その工程のログ＝`run_dir` 配下）。`info[]`＝工程ではない参考情報（`config.toml` の未知キー・宣言掃除の未実施）。
- `success_streak` — 完全正常終了の連続回数（異常な完了で 0 に戻る）。
- `ack` — リーダー AI の対処済み申告（後述）。次の完全正常終了でランナーが削除し、再失敗なら残す（`ack.run_id != completed.run_id` を判定機が「申告後に再失敗」と読む）。

**手動起動（`scripts/maintenance-kick.sh`）** — launchd 経由（`launchctl kickstart`・`-k` は付けない）で週次ランナーを起動するので、定期実行と同じ実行体・同じ環境（plist の `HOME`／`PATH`／`USER`）・同じ記録先を通ります。起動前に印ファイルを置き、記録には `trigger: manual` と載ります（`launchctl kickstart` を直接叩いた起動は `scheduled` と記録される＝監査用の既知の限界）。LaunchAgent が未ロード（`KICK_REFUSED:not_loaded`・終了 2）、Vault 書込ロック保持中または `run.status` が `running` で `stale_after_seconds` 未満（`KICK_REFUSED:busy`・終了 3）、印ファイルを作れない（終了 4）のときは起動しません。kickstart 失敗＝`KICK_FAILED`（5）、30 秒以内に新しい `run.run_id` が現れない＝`KICK_TIMEOUT`（6・この場合も印ファイルを消します＝この後に遅れて開始した run は `manual` ではなく `scheduled` として記録されうる）。成功時は `RUN_ID:<id>` と `STATE_FILE:<path>` を印字し、`--wait` を付けると `run.status != running` まで待って `STATUS:<completed|skipped>` と `FULLY_OK:<true|false>`（`skipped` なら `SKIP_REASON:<busy:…>`＝失敗ではなく再実行の対象。数分後に再実行）を印字します。完了記録が現れなければ `KICK_WAIT_TIMEOUT`（7）。

**昇格の締め（`scripts/fragments-reviewed.sh`）** — Dock の週次行が数えた昇格候補への対応が終わったら（記録職が対応済みの各エントリへ `status: promoted` を付けた後に）実行し、次の週次を待たずに候補数を 0 件へ戻します。今日を排他的な起点として未処理 Fragments を数え直し（`fragments_log.py --since <今日>`・当日分は数えない。下記の既知の限界を参照）、`fragments_reviewed_at`（UTC の今）・`fragments_candidates`・`fragments_since` を `last-run.json` へ原子的に書きます。次回の週次メンテの `--since` は、`fragments_reviewed_at` が有効（形式正・未来でない・30 日以内）ならそれを優先し、無効なら従来どおり `last_success_at` へフォールバックします。失敗時（検出スクリプトの失敗/timeout・JSON 破損・契約違反のいずれか）は何も書かずに非 0 で終わり、理由を stderr へ 1 行出します。`--dry-run` は書く予定の 3 値を表示するだけで書き込みません。テスト用 env は `LAST_RUN_FILE`・`FRAGMENTS_LOG_PY`・`TIMEOUT_FRAGMENTS_LOG`（既定は `maintenance.sh` と同じ）。既知の限界＝窓は日付単位（`since_date < d`）なので、CLI を実行した**その日**に足した Fragments は翌日以降まで数えられません（昇格対応の一連の最後に実行してください）。

**対処済み申告（`health_judge.py ack`）** — リーダー AI が「対処した・次回の本番実行で判定する」を `last-run.json` の `ack` に残します:

```
python3 ~/work/takumi009-ai-env/claude/hooks/lib/health_judge.py ack \
  --last-run <path> --note "<対処内容 1 行>" \
  [--session-id <sid>] [--observation <session-observation.json>]
```

`--session-id` は任意。省略時は観測記録（`${HEALTH_OBSERVATION_FILE:-$HOME/.claude/logs/health/session-observation.json}`＝SessionStart フックが書く）の `session_id`＝今回のリーダーセッションを読みます（`CLAUDE_CODE_SESSION_ID` という環境変数は存在しません）。観測記録も読めなければ `session_id: null` で書きます（申告は成立させる・sid は監査用）。書く内容＝`{"at", "note", "session_id", "run_id"}`（`run_id`＝そのときの `completed.run_id`）を原子的に。**受理条件（すべて満たすときだけ書く）**＝記録が解析できる ∧ `completed` がある ∧ `completed.fully_ok == false` かつ `steps` が 1 件以上 ∧ 実行中でない（`run.status == running` かつ経過 < `stale_after_seconds` ではない）∧ Vault 書込ロック保持中でない。申告対象は `completed.steps` の項目だけ（未起動・中断・破損・旧形式・棚卸し・読込・想起は申告を持たない＝各源の OK 条件は次回の本番実行・次セッションで自動的に判定される）。拒否時は固定文 `ACK_REFUSED:<running|locked|broken|no_completed|nothing_to_ack>` を 1 行出して非 0 で終わり、ファイルには触れません。申告は段階を変えません（OK は本番経路の実行結果だけが作る。失効＝次の完全正常終了で削除・再失敗なら残置）。

### 使用率の見える化（usage_snapshot.py）

**手動で見る口**: `python3 claude/hooks/lib/usage_snapshot.py` を実行すると同じ3行がその場で表示されます（`--json` を付けると機械可読の1行JSONになります）。詳細＝`claude/hooks/lib/usage_snapshot.py` の docstring。

### 使用率取得器（scripts/usage-fetch.sh／scripts/install-usage-fetch.sh）

導入は `scripts/install-usage-fetch.sh`（`install-backup.sh` と同型の素の bootstrap+enable インストーラ。`--dry-run` は現在の状態を表示するだけ）。詳細＝`scripts/usage-fetch.sh`・`scripts/install-usage-fetch.sh` 冒頭のコメント。

### ズレの検知（check-drift.sh）

```sh
scripts/check-drift.sh
```

以下5点を検査し、一覧表示します（**検知しても exit 1 にはしません**＝手動確認用のレポートツール）: ① symlink と生成物 `~/.claude/settings.json`、② 生成物 `~/.codex/config.toml`、③ 未commitの変更、④ `vault-public/Preferences` の差分（informational）、⑤ private repo の remote が **private** のままか。詳細＝スクリプト冒頭のコメント。

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
mkdir -p ~/.config/takumi009-ai-env
cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # ローカル設定はバックアップ対象外のため作り直す
cp config/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # （machine_role・モデル定義を旧機と同じ値へ戻す）
scripts/install-main.sh --with-dotfiles   # symlink 化＋dotfiles
scripts/install-backup.sh                 # 定期バックアップ再開
scripts/install-maintenance.sh            # 週次メンテナンスランナー再開
scripts/install-usage-fetch.sh --dry-run  # 使用率取得の再開: まず状態だけ確認
scripts/install-usage-fetch.sh            # 使用率取得を再開

# 5. 各アプリのログイン（手動）: Claude Code / Codex / その他
```

- 復元される範囲＝**push 済みの状態まで**（未 commit の作業は失われる）
- バックアップの最大遅延は Mac のスリープに依存する

#### メインの移転（新しい Mac に計画的に乗り換えるとき）

1. 旧メインで最後の同期: `scripts/backup-vault.sh` → `scripts/export-public-vault.sh` → 未 push が無いことを `scripts/check-drift.sh` で確認
2. 新 Mac で上記「災害復旧」手順を実行
3. 旧メインの LaunchAgent を停止（`launchctl bootout gui/$(id -u)/com.takumi009.<label>`）— **メインは常に1台**（編集権限・push 地点の一意性を守る）

### セッション引き継ぎ（scripts/session-handoff.sh）

セッションが長くなったとき、再開メモを書いたあと本スクリプトで新しい cmux ワークスペースを開き、`cct`（Claude Code）を起動して続きの依頼を1行で投入する。

```sh
scripts/session-handoff.sh <再開メモのパス> "<続きの依頼>" [--cwd <dir>] [--name <題>]
scripts/session-handoff.sh -h | --help
```

引数・終了コード・環境変数＝`scripts/session-handoff.sh -h`。

### テスト

```sh
for t in tests/test-*.sh; do bash "$t"; done
```

いずれも実 Vault・実 GitHub・実 `~/.claude`・実 `~/.codex` に依存せず、使い捨てのfixtureディレクトリ上で完結します（`rg`・`gitleaks` が必要。`brew bundle` 済みなら揃っています）。

### ライセンス

[MIT](LICENSE)
