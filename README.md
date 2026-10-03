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

v1.1 component split:

The repository is split into 6 **functions** (what a human would choose to take or leave), each with up to 5 **layers** inside it (`data` / `rules` / `executor` / `connect` / `assembly`; `connect` has one subfolder per external provider — Claude Code, Codex, macOS, cmux, CODE27). The **ledger** (`core/data/ledger.tsv`) is the single place that can look up every component's function/layer/provider, every suite's function, and every "calling the human" site; the **move map** (`core/data/moves.tsv`) is the single old-path → new-path record. Both are checked against the real tree on every test run by `core/assembly/ledger-tool.sh check` (see "Component ledger" below).

```
takumi009-ai-env/
├── ai-brain/                   # Vault bootstrap, recall, read-log, write-gate, backup, weekly maintenance, public export
│   ├── executor/               # vault-recall.sh, vault-read-log.sh, bootstrap-vault.sh (SessionStart contribution), backup-vault.sh,
│   │                           # maintenance.sh / maintenance-kick.sh, export-public-vault.sh, fragments-reviewed.sh, health_judge.py,
│   │                           # the vault-agents detectors (apply_aliases.py, fragments_log.py, maintenance_run_step.py, vault_inventory.py, vault_lib.py)
│   ├── connect/
│   │   └── claude-code/        # vault-write-gate.sh (Vault-write guard loaded into a worker's child settings)
│   ├── assembly/                # install-backup.sh, install-maintenance.sh, the 2 LaunchAgent plists (backup-vault / maintenance)
│   └── data/
│       ├── templates/           # README templates for the private skeleton folders
│       └── vault-public/        # Snapshot of the Vault's public folders (see below; a compatibility symlink named `vault-public` still exists at the repo root)
├── team/                        # Worker launch, role definitions, cast/model resolution, delegation gates, the Codex connection
│   ├── rules/
│   │   └── agents/               # Worker role definitions (one .md per role)
│   ├── data/                     # profile.md.sample, models.conf.sample
│   ├── executor/                 # profile_resolve.py (cast/model resolver)
│   └── connect/
│       ├── claude-code/          # claude-exec.sh, delegation-gate-v2.sh, inprocess-gate.sh, agent-model-guard.sh,
│       │                         # codex-direct-call-gate.sh, role_candidates.py, guard_common.sh, bedrock.env.sample
│       └── codex/                # codex-exec.sh, AGENTS.md, hooks.json, config.toml template (generated)
├── usage/                        # Usage fetch, cache, injection into prompts
│   ├── executor/                 # usage-fetch.sh, usage-source.sh, usage-inject.sh, usage-block.sh, usage_snapshot.py,
│   │                             # usage-notify.sh (threshold judgement and notification state; sending goes through the mouth)
│   ├── connect/
│   │   ├── claude-code/          # fetch.sh + usage.env (provider declaration)
│   │   └── codex/                # fetch.sh + usage.env (provider declaration)
│   └── assembly/                  # install-usage-fetch.sh, the usage-fetch LaunchAgent plist
├── notify/                        # Calling the human (display is out of scope — see Dock below)
│   ├── executor/                  # notify.sh (the mouth: takes every call/answer and hands it to the senders the ledger routes it to)
│   └── connect/                   # one sender (deliver.sh) per destination; which notices it takes = the ledger's "notices" column
│       ├── macos/                 # deliver.sh (macOS notification)
│       ├── cmux/                  # deliver.sh (cmux notification; CODE27 speaks via the cmux settings' own hook chain)
│       └── code27/                # deliver.sh (clears the CODE27 call — answers only)
├── dock/                          # Supply side for the cmux Dock (drawing lives in the separate dotfiles repo)
│   └── executor/                   # cmux-next-model.sh, cmux-task-model.sh, cmux-task-declare.sh, dock-pane-resolve.sh, shared libs
├── core/                           # Full install, ledger, drift check, sub-machine update, and provider-independent generic parts
│   ├── executor/                   # pid-lock.sh, status-file.sh, vault-paths.sh, audit.sh, notice.sh (shared lib every notice goes through),
│   │                                # ngwords-path.sh (resolves the NG-word file default for audit.sh / export-public-vault.sh)
│   ├── connect/
│   │   └── claude-code/            # session-start-compose.sh (the SessionStart composer; this is the hook registered as `bootstrap-vault.sh`),
│   │                                # bash-danger-gate.sh, bash-policy-gate.sh, context-size-warn.sh, session-handoff.sh,
│   │                                # prompt-answer.sh (detects the human's input and sends the answer; registered as `code27-call-clear.sh`)
│   ├── assembly/                    # install-main.sh, install-sub.sh, update-sub.sh, check-drift.sh, check-sub-update.sh,
│   │                                # managed-symlink.sh, settings.json template (generated), ledger-tool.sh
│   └── data/
│       ├── ledger.tsv                # Component ledger (function/layer/provider/key for every part and suite — see below)
│       ├── moves.tsv                 # Old path → new path map (v1.1 component split)
│       └── ngwords.txt               # NG-word list (private, git-ignored; linked in by the private patch)
├── Brewfile                          # `brew bundle` dependencies
└── tests/                            # Unit tests
```

Note: the pre-v1.1 folders `claude/`, `codex/`, `scripts/`, `cmux/`, `config/`, `launchagents/` no longer hold real content. A handful of **compatibility forwarding symlinks** are kept at their old paths only where something outside this repository still names them directly (an already-registered `~/.claude/settings.json`/LaunchAgent, or the separate dotfiles repo): the 14 `claude/hooks/*.sh` registered hooks, `cmux/cmux-next-model.sh` / `cmux-task-model.sh` (dotfiles' default supply paths), `scripts/backup-vault.sh` / `maintenance.sh` / `usage-fetch.sh` (the 3 LaunchAgent targets), `scripts/install-sub.sh` (the old update command's fixed call site), and the repo-root `vault-public` symlink. Each one is a relative symlink into the real file above and is itself git-tracked; see `core/data/moves.tsv` for the full map.

### Roles: Orchestrator / Worker / Codex

`team/rules/agents/` and this environment's workflow are built around three role words:

- **Orchestrator (leader)**: The main Claude Code session. It makes decisions, talks with the user, and directs the overall workflow — it delegates implementation/investigation/testing to workers rather than doing them itself.
- **Worker**: A subagent launched from one of the role definitions under `team/rules/agents/` (one `.md` per role; the set is whatever the directory holds — currently requirements-analyst, system-designer, test-writer, implementer, verifier, test-runner, researcher, operator, adoption-critic, vault-scribe, vault-scribe-light). Adding or removing a role = editing that directory and the local profile only (contract and steps: see 日本語 §「職種定義の契約と設定変更の手順」).
- **Codex**: The default cast for the verifier role, invoked via `team/connect/codex/codex-exec.sh` (a Bash wrapper around `codex exec`; continuation of a review thread uses the wrapper's `--resume` flag). Workers don't invoke it themselves — the orchestrator starts verification once a stage's deliverable is complete, and workers only apply the resulting findings.

How a worker is launched (`resolve-candidate`, in-process `Agent` rejection, `claude-exec.sh`) — details = the comment at the top of `team/connect/claude-code/claude-exec.sh`.

### About the public Vault snapshot (`ai-brain/data/vault-public/`)

This repository's `ai-brain/data/vault-public/` is a full-copy snapshot of only the folders in the external brain (Obsidian Vault) that have been designated as "containing no personal information" (currently `Preferences/`). The remaining folders that may contain personal information (`Personal/` `Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/` `Blogs/`) are reproduced as **empty folders with just a README.md, no content** (so that a sub machine trying to write to them doesn't fail with "folder not found"). The export is triggered from two places: the weekly `maintenance.sh` Phase 0 and the close of each task on the main machine (`check-drift.sh` only reports a stale snapshot as informational). A compatibility symlink named `vault-public` is kept at the repo root (the old update command and the public repo's own look both still reach it there).

Generation/updating is done by `ai-brain/executor/export-public-vault.sh` (details = the comment at the top of the script).

### Component ledger (`core/data/ledger.tsv`)

Every tracked component (file or folder), every test suite, and every "calling the human" site is looked up through this one TSV file (columns: kind, path, function, layer, provider, key, note, notices). `core/assembly/ledger-tool.sh check` re-derives the real tree (via `git ls-files`), the old→new move map (`core/data/moves.tsv`), and this README's own Structure section, and reports any mismatch as a single line each. The same tool's `lookup <key>` is how one component calls into another function without naming it directly (e.g. "the AI Brain health judge", "the Dock declaration CLI") — a missing key is a planned no-op, a broken ledger or a missing/non-executable target is reported with a fixed `LEDGER: …` line. The 8th column, **notices**, is filled only on Notify's senders (`call.alert`, `call.usage`, `call.ask`, `answer`, comma-separated; a bare `call` takes every call), and `route <notice>` returns the senders for one notice (`<destination><TAB><path>`, in ledger order) — that is how the mouth finds where to deliver without naming any destination. Adding a part or a suite always means adding one row here (FR-14).

### Setup

#### 0. Install dependencies (common)

```sh
brew bundle          # Reads the Brewfile and installs ripgrep, gitleaks, jq, gh, macmon
```

Claude Code / Codex themselves are outside brew's management, so install them separately from their official sites. `install-main.sh` requires `python3` (details = the comment at the top of `core/assembly/install-main.sh`).

`core/data/ngwords.txt` (NG-word definitions used by `export-public-vault.sh` and `audit.sh`) is **not included in this repository** because it's private data. If the file is still only at the old default `scripts/ngwords.txt`, both tools stop and print the one command that moves it. To run `export-public-vault.sh`/`audit.sh` as-is, either set `NGWORDS_FILE=/path/to/your/ngwords.txt` to point at your own file, or write your own NG-word list.

#### Main environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # Local role-cast profile (real main-machine values)
cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # Model definitions (real main-machine values)
core/assembly/install-main.sh          # Symlinks the Claude Code / Codex connect parts into ~/.claude and ~/.codex
ai-brain/assembly/install-backup.sh    # Installs the Vault-backup LaunchAgent
ai-brain/assembly/install-maintenance.sh   # Installs the weekly maintenance-runner LaunchAgent (main only)
usage/assembly/install-usage-fetch.sh --dry-run  # Preview the usage-fetch install (prints the current state only)
usage/assembly/install-usage-fetch.sh            # Installs the usage-fetch LaunchAgent
```

Details = the comments at the top of `core/assembly/install-main.sh` (`*.sample`, generated files), `core/assembly/managed-symlink.sh` (backups), `team/connect/claude-code/role_candidates.py`, `ai-brain/assembly/install-backup.sh`/`install-maintenance.sh` (no kickstart), `team/connect/codex/codex-exec.sh --help`, and `team/connect/claude-code/claude-exec.sh`.

On the main environment, a **private patch (a separate private repository)** is layered on top of this base package. The private patch contains the Vault's substance (`~/Data/obsidian`) and settings that cannot be made public. See that repository's own documentation for its setup steps.

##### Taking in v1.1 on an existing main machine

If this machine already has a pre-v1.1 checkout, bring it up to date in **one place**:

```sh
cd ~/work/takumi009-ai-env
git pull --ff-only
core/assembly/install-main.sh --with-dotfiles   # re-run the full installer (re-links every hook, registers the new codex-direct-call-gate.sh, regenerates settings.json)
ai-brain/assembly/install-backup.sh             # re-register the Vault-backup LaunchAgent at its new target path
ai-brain/assembly/install-maintenance.sh        # re-register the weekly maintenance LaunchAgent at its new target path
usage/assembly/install-usage-fetch.sh           # re-register the usage-fetch LaunchAgent at its new target path
core/assembly/check-drift.sh                    # confirm 0 drift: every registered hook command and every LaunchAgent target must exist
```

The old paths (`claude/hooks/*.sh`, `cmux/cmux-next-model.sh` / `cmux-task-model.sh`, `scripts/backup-vault.sh` / `maintenance.sh` / `usage-fetch.sh` / `install-sub.sh`, `vault-public`) are kept only as compatibility symlinks to the files above, so every already-registered hook and LaunchAgent keeps working at each point of this sequence — right after `git pull`, and even if `install-main.sh` fails partway through (see "Component ledger" above and `core/data/moves.tsv` for the full map).

##### Taking in v1.2 (bundle B: the notification mouth) on an existing main machine

```sh
cd ~/work/takumi009-ai-env
git pull --ff-only
core/assembly/install-main.sh --with-dotfiles   # re-run the full installer (the `code27-call-clear.sh` hook now points at core/connect/claude-code/prompt-answer.sh)
core/executor/audit.sh --quick                  # if the NG-word file is still at the old scripts/ngwords.txt, this fails and prints one command — run it, then re-run this line
core/assembly/check-drift.sh                    # confirm 0 drift
```

The forwarding symlinks described above stay in place for now.

#### Sub environment

```sh
git clone <URL of this repository> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # then edit machine_role (and role.leader if needed)
cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # then trim/enable the model defs this machine actually uses
core/assembly/install-sub.sh
```

Details = the comments at the top of `core/assembly/install-sub.sh`, `core/assembly/check-sub-update.sh`, and `core/assembly/update-sub.sh`.

##### Updating an existing sub machine (when a new schema/config lands)

1. `git pull --ff-only` (a plain pull, not `update-sub.sh` — with the old profile still in place, `update-sub.sh` itself would refuse to run).
2. Only if the schema changed: copy the samples over the real files (`cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md`, `cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf`; back up the existing real file first, permission `0600`) and edit the profile for this sub machine — at least `machine_role: configured value=sub` (the samples carry the main machine's values), plus `role.leader`, `no_read_paths`, `team_mode` as needed. `core/assembly/install-sub.sh --check-profile` prints the resolve result as one line with no side effects.
3. `core/assembly/update-sub.sh` — pull → `install-sub.sh` → `ai-brain/data/vault-public/Preferences/` re-sync, every run (no flags; the old re-sync flag is gone). Confirm it ends with `done.`; a new session's mode line should then show the current version. If it prints `AGENTS: dangling`, delete the file(s) it names.

⚠️ `update-sub.sh`'s failure message attributes the cause to "the role-cast profile's `machine_role` isn't `sub`", but the exact same message also appears when the real cause is an old-schema profile whose fixed keys read as `unknown` (the resolver's own `stderr` is discarded). Run `profile_resolve.py resolve` directly first to see what it's actually reading before assuming which cause applies.

#### Also install dotfiles (a separate component)

```sh
core/assembly/install-main.sh --with-dotfiles   # or install-sub.sh --with-dotfiles
cd ~/work/dotfiles && git pull --ff-only && ./install.sh   # refresh an existing dotfiles checkout
```

cmux Dock's "Project"/"Task" panes — details = `Decisions/2026-09-15-cmux-dock-two-repo-split` in the Vault.

#### Declaring the project for a cmux workspace (`dock/executor/cmux-task-declare.sh`)

The "Task" pane shows the Tasks section of the project declared for the **focused cmux workspace**. Declare once per workspace with `~/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh set <slug>` (the leader runs it, never the hook). The declaration is keyed by the workspace UUID, which cmux keeps across restarts: after a cmux restart the declaration is still alive in the same (restored) workspace, so nothing needs to be re-declared there. A new workspace (freshly opened, or not restored) starts undeclared — the SessionStart injection (the `declare6` line contributed by the Dock declaration-state part, shown through the `bootstrap-vault.sh`-registered composer) shows the declaration state of the calling workspace (`宣言済み: <slug>` / `未宣言` / `宣言状態 不明`, plus `宣言記録破損` when the record file is unreadable), so read that line and declare once when it says `未宣言`. `list` / `unset` / `prune` are the other subcommands (the weekly maintenance runs `prune`).

### Vault Backup Operations

`ai-brain/executor/backup-vault.sh` targets `$HOME/Data/obsidian`: if there are changes, it runs `git add -A && git commit` (message: `backup: YYYY-MM-DD HH:MM`), and pushes only if the `origin` remote is already configured (if not, it stops with a warning after committing). Details = the comment at the top of the script.

### Weekly Maintenance Runner (main only)

`ai-brain/executor/maintenance.sh` is the single weekly runner (Monday 06:00, installed by `ai-brain/assembly/install-maintenance.sh`). Details = the comment at the top of the script.

**State record contract (schema 2)** — `~/.claude/logs/maintenance/last-run.json` is the single source of truth for the weekly runner's result, read by the health judge (`ai-brain/executor/health_judge.py`, via the SessionStart hook and the Dock). The legacy 6 keys (`started_at` / `last_success_at` / `last_result` / `last_result_summary` / `fragments_candidates` / `fragments_since`) are still written for the older readers; the new readers use only the keys below.

- `run` — the most recent **start** and how it ended. Written unconditionally at start (`status: running`, together with `started_at`), and rewritten **as a whole with the runner's own content** on every one of the 6 endings: completed (finish / Phase 0 snapshot failure / Vault write-lock failure / run-dir creation failure) → `status: completed`; busy-skip (Phase 0 backup busy → `skipped` + `skip_reason: busy:backup0`; Vault write-lock busy → `skipped` + `busy:lock`). Fields = `run_id` (`<date>/<HHMMSS-pid>`), `run_dir`, `started_at`, `trigger` (`scheduled` / `manual`), `status`, `stale_after_seconds` (a copy of `MAINTENANCE_STALE_LOCK_SECONDS`; the reader uses it to tell "still running" from "interrupted"), `skip_reason`, `finished_at`. A record left at `running` past `stale_after_seconds` means the runner died without a completion record.
- `completed` — the most recent **completion record** (only the 4 completed endings write it; busy-skips leave the previous one). `fully_ok` is true only for a fully clean run. `steps[]` holds **one entry per abnormal step** (clean steps are not listed): `id` (`phase0-dir` / `phase0-lock` / `phase0-backup` / `phase0-export` / `phase1-drift` / `phase1-fragments` / `phase1-inventory` / `phase3-summary` / `phase3-backup` / `phase3-record`), `name`, `result` (`fail` / `warn` — a child's failure the runner continued past is still `fail`; `warn` is only a drift finding), `reason` (verbatim, never truncated; control characters normalized to spaces), `actor` (`AI` / `本人` from the runner's fixed table — drift findings are `本人`, everything else `AI`, unknown ids fall to `本人`), `log_ref` (that step's log under `run_dir`). `info[]` = informational notes that are not steps (unknown `config.toml` keys, declaration prune not performed).
- `success_streak` — number of consecutive fully-clean completions (reset to 0 on any abnormal completion).
- `ack` — the leader AI's "handled, judge on the next run" note (see *Acknowledging a finding*). The runner deletes it on the next fully-clean completion and keeps it on a re-failure (the judge then reports "re-failed after ack" because `ack.run_id != completed.run_id`).

**Manual kick (`ai-brain/executor/maintenance-kick.sh`)** — runs the weekly runner through launchd (`launchctl kickstart` without `-k`), so it uses the same executable, environment (plist `HOME` / `PATH` / `USER`) and record as the scheduled run; it leaves a marker so the record says `trigger: manual` (a raw `launchctl kickstart` is recorded as `scheduled`). It refuses to start when the LaunchAgent is not loaded (`KICK_REFUSED:not_loaded`, exit 2), when the Vault write-lock is held or `run.status` is `running` within `stale_after_seconds` (`KICK_REFUSED:busy`, exit 3), or when the marker cannot be written (exit 4); `KICK_FAILED` (5) if kickstart fails, `KICK_TIMEOUT` (6) if no new `run.run_id` appears within 30 s (this also removes the marker — a run that starts late past this point is recorded as `scheduled`, not `manual`). On success it prints `RUN_ID:<id>` and `STATE_FILE:<path>`; with `--wait` it also waits until `run.status != running` and prints `STATUS:<completed|skipped>` plus `FULLY_OK:<true|false>` (or `SKIP_REASON:<busy:…>` — a busy-skip is not a failure; re-run a few minutes later). `KICK_WAIT_TIMEOUT` (7) if the completion record never appears.

**Closing out a promotion (`ai-brain/executor/fragments-reviewed.sh`)** — run this once you've finished handling the Fragments promotion candidates the Dock's weekly line counted (after the recorder has marked each handled entry `status: promoted`), so the count returns to 0 without waiting for the next weekly run. It re-counts unprocessed Fragments starting exclusively from today (`fragments_log.py --since <today>`; today's own entries aren't counted — see the known limitation below), then writes `fragments_reviewed_at` (now, UTC), `fragments_candidates` and `fragments_since` to `last-run.json` atomically; the next weekly run's `--since` prefers `fragments_reviewed_at` over `last_success_at` when it's valid (not malformed, not in the future, within 30 days — otherwise it falls back the same way `last_success_at` always has). On any failure (the detector script failing/timing out, malformed JSON, or a contract violation) it writes nothing and exits non-zero with a one-line reason on stderr. `--dry-run` shows the 3 values it would write without writing them. Env vars for testing: `LAST_RUN_FILE`, `FRAGMENTS_LOG_PY`, `TIMEOUT_FRAGMENTS_LOG` (same defaults as `maintenance.sh`). Known limitation: because the window is date-granularity (`since_date < d`), Fragments added the *same day* the CLI runs won't be counted until the next day — run it last, after all promotions for the session are done.

**Acknowledging a finding (`health_judge.py ack`)** — the leader AI records "handled; judge on the next production run" in `last-run.json`'s `ack`:

```
python3 ~/work/takumi009-ai-env/ai-brain/executor/health_judge.py ack \
  --last-run <path> --note "<what was done, one line>" \
  [--session-id <sid>] [--observation <session-observation.json>]
```

`--session-id` is optional; when omitted the current leader session id is read from the observation record (`${HEALTH_OBSERVATION_FILE:-$HOME/.claude/logs/health/session-observation.json}`, written by the SessionStart hook — there is no `CLAUDE_CODE_SESSION_ID` environment variable). If that cannot be read either, `session_id: null` is written (the ack still counts; the sid is for audit). It writes `{"at", "note", "session_id", "run_id"}` (`run_id` = the current `completed.run_id`) atomically. **Accepted only when** the record parses, `completed` exists, `completed.fully_ok == false` with at least one step, the runner is not running (`run.status == running` within `stale_after_seconds`) and the write-lock is not held; only `completed.steps` items can be acked (not-started / interrupted / broken / legacy / inventory / load / recall items have no ack — their OK condition is judged automatically on the next run or next session). Otherwise it prints one fixed line `ACK_REFUSED:<running|locked|broken|no_completed|nothing_to_ack>` and exits non-zero without touching the file. An ack never changes the health stage; only a production run does (expiry = deleted on the next fully-clean completion, kept on a re-failure).

### Usage Monitoring (usage_snapshot.py)

**Manual check**: `python3 usage/executor/usage_snapshot.py` prints the same 3 lines on demand (add `--json` for a single-line machine-readable snapshot). Details (the `UserPromptSubmit` block, prerequisite fetcher, Codex "tickets") = the docstring of `usage/executor/usage_snapshot.py`.

### Usage fetcher (usage/executor/usage-fetch.sh / usage/assembly/install-usage-fetch.sh)

Install it with `usage/assembly/install-usage-fetch.sh` (a plain bootstrap+enable installer, same shape as `install-backup.sh`; `--dry-run` only prints the current state). Details = the comments at the top of `usage/executor/usage-fetch.sh` and `usage/assembly/install-usage-fetch.sh`.

### Drift Detection (check-drift.sh)

```sh
core/assembly/check-drift.sh
```

Checks the following 5 points and lists them (**it does not exit 1 even if drift is detected** = a report tool for manual checking): ① managed symlinks and the generated `~/.claude/settings.json`, ② the generated `~/.codex/config.toml`, ③ uncommitted changes in this repository, ④ `ai-brain/data/vault-public/Preferences` vs. the real Vault (informational only), ⑤ the Vault-backup / private-patch remote is still **private** on GitHub. Details = the comment at the top of the script.

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
cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # local config isn't part of any backup — recreate it
cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # (edit machine_role/model defs back to what this machine had)
core/assembly/install-main.sh --with-dotfiles   # symlinks + dotfiles
ai-brain/assembly/install-backup.sh             # Resume periodic backups
ai-brain/assembly/install-maintenance.sh        # Resume the weekly maintenance runner
usage/assembly/install-usage-fetch.sh --dry-run  # Resume usage tracking: print the current state first
usage/assembly/install-usage-fetch.sh            # Resume usage tracking

# 5. Log in to each app (manual): Claude Code / Codex / others
```

- Scope of what's restored = **everything up to the pushed state** (uncommitted work is lost)
- The maximum backup delay depends on the Mac's sleep state

#### Main migration (planned move to a new Mac)

1. On the old main, do a final sync: `ai-brain/executor/backup-vault.sh` → `ai-brain/executor/export-public-vault.sh` → confirm there's nothing unpushed with `core/assembly/check-drift.sh`
2. Run the "disaster recovery" procedure above on the new Mac
3. Stop the old main's LaunchAgents (`launchctl bootout gui/$(id -u)/com.takumi009.<label>`) — **there is always exactly one main** (this preserves the uniqueness of edit permission / push location)

### Session handoff (core/connect/claude-code/session-handoff.sh)

When a session gets long, write a resume note, then use this script to open a new cmux workspace, start `cct` (Claude Code) in it, and send the follow-up request as a single line.

```sh
core/connect/claude-code/session-handoff.sh <path-to-resume-note> "<follow-up request>" [--cwd <dir>] [--name <title>]
core/connect/claude-code/session-handoff.sh -h | --help
```

Arguments, exit codes, and environment variables = `core/connect/claude-code/session-handoff.sh -h`.

### Tests

```sh
bash tests/run-all.sh
```

This runs every `tests/test-*.sh` suite one after another and exits non-zero at the end if any of them failed. None of them depend on the real Vault, real GitHub, the real `~/.claude`, or the real `~/.codex` — they run entirely against disposable fixture directories (`rg` and `gitleaks` are required; both are already available once `brew bundle` has been run). This run also includes the component-ledger check (`tests/test-ledger.sh`, driven by `core/assembly/ledger-tool.sh check`): every part and suite has exactly one ledger row, there are no cross-function references outside the key-lookup mechanism, every forwarding symlink reaches its successor, and every hook/LaunchAgent target that `install-main.sh` registers actually exists.

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

v1.1 機能の部品化:

repo は人が取る単位＝**機能** 6 つに分かれ、各機能の内側は**層**（`data`／`rules`／`executor`／`connect`／`assembly`。`connect` は提供元（Claude Code・Codex・macOS・cmux・CODE27）ごとに 1 フォルダ）で分かれています。**台帳**（`core/data/ledger.tsv`）が、全部品の機能・層・提供元、全スイートの機能、本人を呼ぶ箇所を引ける唯一の場所で、**移動表**（`core/data/moves.tsv`）が旧パス→新パスの唯一の記録です。両方とも `core/assembly/ledger-tool.sh check` がテスト実行のたびに実フォルダ・この README の構成節と突合します（詳細＝後述「台帳」節）。

```
takumi009-ai-env/
├── ai-brain/                   # Vault の読込・想起・読取記録・書込の柵・バックアップ・週次メンテ・公開出力
│   ├── executor/               # vault-recall.sh・vault-read-log.sh・bootstrap-vault.sh（SessionStart 合成器への寄与）・
│   │                           # backup-vault.sh・maintenance.sh／maintenance-kick.sh・export-public-vault.sh・
│   │                           # fragments-reviewed.sh・health_judge.py・vault-agents の検出器群
│   │                           # （apply_aliases.py・fragments_log.py・maintenance_run_step.py・vault_inventory.py・vault_lib.py）
│   ├── connect/
│   │   └── claude-code/        # vault-write-gate.sh（子向け Vault 保護柵）
│   ├── assembly/                # install-backup.sh・install-maintenance.sh・LaunchAgent plist 2 本（backup-vault／maintenance）
│   └── data/
│       ├── templates/           # private 骨格フォルダの README 雛形
│       └── vault-public/        # Vault の公開フォルダのスナップショット（後述。repo 直下に転送 symlink `vault-public` も残る）
├── team/                        # ワーカー起動・職種定義・配役表とモデル定義の解決・委任の柵・Codex 接続
│   ├── rules/
│   │   └── agents/               # ワーカー役割定義（1 ファイル＝1 職種）
│   ├── data/                     # profile.md.sample・models.conf.sample
│   ├── executor/                 # profile_resolve.py（配役表・モデル定義の解決器）
│   └── connect/
│       ├── claude-code/          # claude-exec.sh・delegation-gate-v2.sh・inprocess-gate.sh・agent-model-guard.sh・
│       │                         # codex-direct-call-gate.sh・role_candidates.py・guard_common.sh・bedrock.env.sample
│       └── codex/                # codex-exec.sh・AGENTS.md・hooks.json・config.toml テンプレ（生成）
├── usage/                        # 使用率の取得・保存・発言への注入
│   ├── executor/                 # usage-fetch.sh・usage-source.sh・usage-inject.sh・usage-block.sh・usage_snapshot.py・
│   │                             # usage-notify.sh（閾値の判定と通知状態の記録。送る段は口へ）
│   ├── connect/
│   │   ├── claude-code/          # fetch.sh＋usage.env（提供元の宣言）
│   │   └── codex/                # fetch.sh＋usage.env（提供元の宣言）
│   └── assembly/                  # install-usage-fetch.sh・使用率取得 LaunchAgent plist
├── notify/                        # 本人を呼ぶ（表示＝Dock は含まない）
│   ├── executor/                  # notify.sh（口＝呼出・応答を受け、台帳が引く送り手へ渡す）
│   └── connect/                   # 届け先ごとの送り手（deliver.sh）。受ける知らせ＝台帳の「知らせ」列
│       ├── macos/                 # deliver.sh（macOS 通知）
│       ├── cmux/                  # deliver.sh（cmux 通知。CODE27 の発話は cmux 設定のフックの連鎖）
│       └── code27/                # deliver.sh（CODE27 の呼出の消去＝応答だけ）
├── dock/                          # cmux Dock への供給側（描画は別リポジトリ dotfiles）
│   └── executor/                   # cmux-next-model.sh・cmux-task-model.sh・cmux-task-declare.sh・dock-pane-resolve.sh・共有 lib
├── core/                           # 全部入りの組立・台帳・ズレ検知・サブ機更新・特定機能に属さない汎用部品
│   ├── executor/                   # pid-lock.sh・status-file.sh・vault-paths.sh・audit.sh・notice.sh（知らせの共通部品）・
│   │                                # ngwords-path.sh（audit.sh・export-public-vault.sh の NG 語ファイルの既定の解決）
│   ├── connect/
│   │   └── claude-code/            # session-start-compose.sh（SessionStart 合成器。`bootstrap-vault.sh` の登録名で動く）・
│   │                                # bash-danger-gate.sh・bash-policy-gate.sh・context-size-warn.sh・session-handoff.sh・
│   │                                # prompt-answer.sh（本人の入力の検知→応答。`code27-call-clear.sh` の登録名で動く）
│   ├── assembly/                    # install-main.sh・install-sub.sh・update-sub.sh・check-drift.sh・check-sub-update.sh・
│   │                                # managed-symlink.sh・settings.json テンプレ（生成）・ledger-tool.sh
│   └── data/
│       ├── ledger.tsv                # 台帳（全部品・全スイートの機能・層・提供元・鍵。後述）
│       ├── moves.tsv                 # 旧パス→新パスの対応表（v1.1 機能の部品化）
│       └── ngwords.txt               # NG 語定義（私的・git 管理外。私的パッチが張る）
├── Brewfile                          # `brew bundle` の依存
└── tests/                            # ユニットテスト
```

注: v1.1 以前の `claude/`・`codex/`・`scripts/`・`cmux/`・`config/`・`launchagents/` は、もう実体を持ちません。本 repo の外から直接名指す先（配置済みの `~/.claude/settings.json`・LaunchAgent、別リポジトリ dotfiles）がある分だけ、旧パスに**転送 symlink**を残しています＝`claude/hooks/*.sh` の登録フック 14 本・`cmux/cmux-next-model.sh`／`cmux-task-model.sh`（dotfiles の既定供給パス）・`scripts/backup-vault.sh`／`maintenance.sh`／`usage-fetch.sh`（LaunchAgent の起動対象 3 本）・`scripts/install-sub.sh`（旧更新コマンドの固定呼び出し先）・repo 直下の `vault-public`。いずれも上記の実体への相対 symlink で、git 追跡対象です（一覧＝`core/data/moves.tsv`）。

### 役割: リーダー／ワーカー／Codex

`team/rules/agents/` およびこの環境のワークフローは、次の3つの役割語を軸に組み立てられています。

- **リーダー（orchestrator）**: メインの Claude Code セッション。意思決定・ユーザー対話・工程全体の采配を行い、実装/調査/テストは自分でやらずワーカーへ委任します。
- **ワーカー（worker）**: `team/rules/agents/` 配下の役割定義（1 ファイル＝1 職種。集合はディレクトリの中身そのもの＝現在は要件定義・設計・実装・検証・調査・運用・採用判定・記録）で起動されるサブエージェントです。
- **Codex**: 一次レビュアー専任（`team/connect/codex/codex-exec.sh`＝`codex exec`のBashラッパー経由。レビュースレッドの継続はラッパーの`--resume`で行う）。ワーカーがリーダーへ報告する前に、自分の成果物のレビューを依頼する相手です。

ワーカーの起動の仕組みの詳細＝`team/connect/claude-code/claude-exec.sh` 冒頭のコメント。

#### 職種定義の契約と設定変更の手順

**職種定義の契約**（`team/rules/agents/<職種>.md` 1 本の中で全部満たせる。検査＝`bash tests/test-agent-definitions.sh`）
(a) 職種名（ファイル名＝`name`）は `^[a-z][a-z-]*$`（英小文字とハイフンのみ・先頭は英字・数字と `:` は不可。⚠️ 配役表 resolver の禁止キー部分一致語＝`auth`・`token`・`secret`・`password`・`credential`・`cookie`・`passphrase`・`access_key`・`api_key`・`private_key` を含む名前は `role.<職種>` 行が MINIMAL で拒否される＝例 `test-author` は不可） (b) frontmatter `name:` がファイル名（拡張子除く）と一致 (c) 組込み種別名（Explore・Plan・general-purpose・claude・statusline-setup・claude-code-guide）と衝突しない (d) `description:`・`tools:` が非空・本文が非空 (e) frontmatter に `model:`・`effort:` を書かない (f) 本文に `## 権限` 見出しがちょうど 1 件・`worker-role-prompts` への参照 0 件 (g) Vault の AI 向け 6 フォルダへ書く職種だけ frontmatter に `aienv-vault-write: allowed` を**ちょうど 1 行**（値はこれのみ・行末コメント不可・同じキーを 2 行以上書かない・`aienv-` で始まる他のキーは不可）。宣言の無い職種はラッパー経路で柵（`vault-write-gate.sh`）が載る。

**設定変更の手順**（追加・削除・改名とも）: ① `team/rules/agents/<職種>.md` を書く／消す ② `~/.config/takumi009-ai-env/profile.md` の `role.<職種>: …` 行を足す／消す（`team/data/profile.md.sample` が当該職種を参照していればそちらも） ③ `bash tests/test-agent-definitions.sh` が exit 0（数秒） ④ 追加は `bash core/assembly/install-main.sh` を再実行して `~/.claude/agents/<職種>.md` を配置・削除は `rm ~/.claude/agents/<職種>.md`（dangling symlink の除去）。Agent 経路は次に起動するセッションから有効（起動中のセッションは追随しない）。ラッパー経路は即時。改名＝削除＋追加。コア規範が名指す職種（工程 9 職＋vault-scribe）の削除・改名は規範改訂を伴う通常の変更。

### 公開 Vault スナップショット（`ai-brain/data/vault-public/`）について

このリポジトリの `ai-brain/data/vault-public/` は、外部脳（Obsidian Vault）のうち「個人情報を含まない」と決めたフォルダ（現状 `Preferences/`）だけを丸ごとコピーしたスナップショットです。個人情報を含みうる残りのフォルダ（`Personal/` `Knowledge/` `Decisions/` `Projects/` `Fragments/` `Explorations/` `Blogs/`）は、**中身を含めず空フォルダ＋README.mdだけ**を再現しています（サブ機で書き込もうとした際に「フォルダが無い」で失敗しないようにするため）。export の起点は 2 つ＝週次 `maintenance.sh` の Phase 0 と、メイン機での案件の締め（`check-drift.sh` はスナップショットの遅れを informational として表示するだけ）。repo 直下には転送 symlink `vault-public` を残しています（旧更新コマンドと公開 repo の見た目の両方がそこを見る）。

生成・更新は `ai-brain/executor/export-public-vault.sh` が行います（詳細＝スクリプト冒頭のコメント）。

### 台帳（`core/data/ledger.tsv`）

全部品（ファイル・フォルダ）・全スイート・本人を呼ぶ全箇所は、この TSV 1 本（列＝種類・パス・機能・層・提供元・鍵・備考・知らせ）から引けます。`core/assembly/ledger-tool.sh check` が、実フォルダ（`git ls-files` から導出）・移動表（`core/data/moves.tsv`）・この README の構成節それぞれと突合し、食い違いを 1 件 1 行で報告します。同じツールの `lookup <鍵>` が、他機能の部品名を書かずに呼ぶ経路です（例＝「AI Brain のヘルス判定機」「Dock の宣言 CLI」）。鍵が無ければ予定された省略、台帳異常・実体異常は固定文 `LEDGER: …` で報告します。8 列目「知らせ」は Notify の送り手の行だけが持ち（`call.alert`・`call.usage`・`call.ask`・`answer` のカンマ区切り。`call` だけなら全ての呼出）、`route <知らせ>` がその知らせの送り手を台帳の行順に返します（`<届け先><TAB><パス>`）＝口は届け先の名前を持たずにこれで引きます。部品・スイートを足すときは、この台帳に 1 行を足します（FR-14）。

### 導入手順

#### 0. 依存ツールの導入（共通）

```sh
brew bundle          # Brewfile を見て ripgrep・gitleaks・jq・gh・macmon を導入
```

Claude Code / Codex 本体アプリは brew 管理外のため、各公式サイトから別途インストールしてください。`install-main.sh` は `python3` を必要とします（詳細＝`core/assembly/install-main.sh` 冒頭のコメント）。

`core/data/ngwords.txt`（`export-public-vault.sh`・`audit.sh` が使うNGワード定義）は私的データのため**このリポジトリには含まれません**。旧既定 `scripts/ngwords.txt` にだけある場合、両ツールは止まって移す 1 コマンドを表示します。`export-public-vault.sh`/`audit.sh` をそのまま実行するには、`NGWORDS_FILE=/path/to/your/ngwords.txt` で自分のファイルを指定するか、自分のNGワード定義を作成してください。

#### メイン環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # 配役表（メイン機の実値）
cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # モデル定義（メイン機の実値）
core/assembly/install-main.sh          # Claude Code／Codex の接続部品を ~/.claude・~/.codex へ symlink 化
ai-brain/assembly/install-backup.sh    # Vaultバックアップ用LaunchAgentを配置
ai-brain/assembly/install-maintenance.sh   # 週次メンテナンスランナー用LaunchAgentを配置（メイン専用機能）
usage/assembly/install-usage-fetch.sh --dry-run  # 使用率取得器: まず状態だけ確認（何もしない）
usage/assembly/install-usage-fetch.sh            # 使用率取得器のLaunchAgentを導入
```

詳細＝`core/assembly/install-main.sh`（`*.sample`・生成物）・`core/assembly/managed-symlink.sh`（退避規則）・`team/connect/claude-code/role_candidates.py`・`ai-brain/assembly/install-backup.sh`／`install-maintenance.sh`・`team/connect/codex/codex-exec.sh --help`・`team/connect/claude-code/claude-exec.sh` の冒頭コメント。

メイン環境では、この基本パッケージの上に**私的パッチ（別のprivateリポジトリ）**を重ねます。私的パッチには Vault の実体（`~/Data/obsidian`）や、公開できない設定が含まれます。私的パッチの導入手順は当該リポジトリ側のドキュメントを参照してください。

##### 既存メイン機の v1.1 取込み手順

この機にすでに v1.1 より前の checkout がある場合、以下を**この 1 か所**の手順でまとめて反映します:

```sh
cd ~/work/takumi009-ai-env
git pull --ff-only
core/assembly/install-main.sh --with-dotfiles   # 全部入りインストーラを再実行（全フックの再link・新設 codex-direct-call-gate.sh の登録・settings.json再生成）
ai-brain/assembly/install-backup.sh             # Vaultバックアップ LaunchAgent を新しい起動対象で再導入
ai-brain/assembly/install-maintenance.sh        # 週次メンテナンス LaunchAgent を新しい起動対象で再導入
usage/assembly/install-usage-fetch.sh           # 使用率取得器 LaunchAgent を新しい起動対象で再導入
core/assembly/check-drift.sh                    # drift 0 件を確認（登録フックの全コマンド・LaunchAgent の起動対象が実在すること）
```

旧パス（`claude/hooks/*.sh`・`cmux/cmux-next-model.sh`／`cmux-task-model.sh`・`scripts/backup-vault.sh`／`maintenance.sh`／`usage-fetch.sh`／`install-sub.sh`・`vault-public`）は上記の実体への転送 symlink として残るだけなので、`git pull` 直後や `install-main.sh` が途中で失敗した場合を含め、この手順のどの時点でも既存の登録フック・LaunchAgent は動作し続けます（一覧＝前述「台帳」節・`core/data/moves.tsv`）。

##### 既存メイン機の v1.2 取込み手順（束 B＝通知の口）

```sh
cd ~/work/takumi009-ai-env
git pull --ff-only
core/assembly/install-main.sh --with-dotfiles   # 全部入りインストーラを再実行（登録フック code27-call-clear.sh の実体が core/connect/claude-code/prompt-answer.sh へ）
core/executor/audit.sh --quick                  # NG 語ファイルが旧 scripts/ngwords.txt のままなら失敗して 1 コマンドを表示する＝それを実行してから、この行をもう一度
core/assembly/check-drift.sh                    # drift 0 件を確認
```

前述の転送 symlink は当面そのまま残ります。

#### サブ環境

```sh
git clone <このリポジトリのURL> ~/work/takumi009-ai-env
cd ~/work/takumi009-ai-env
mkdir -p ~/.config/takumi009-ai-env
cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # コピー後にmachine_role（必要ならrole.leaderも）を書き換える
cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # コピー後にこの機で使う定義だけ残す／有効化する
core/assembly/install-sub.sh
```

詳細＝`core/assembly/install-sub.sh`・`core/assembly/check-sub-update.sh`・`core/assembly/update-sub.sh` 冒頭のコメント。

##### 既存サブ機の更新（新しい schema・設定が届いたとき）

1. `git pull --ff-only`（`update-sub.sh` ではなく素の pull。旧プロファイルのままでは `update-sub.sh` 自体が拒否するため）。
2. schema が変わったときだけ: sample を実体へコピーし（`cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md`・`cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf`。既存の実体は先に退避・権限 `0600`）、プロファイルをサブ機用に編集する——最低限 `machine_role: configured value=sub`（sample はメイン機の値のため）、必要に応じて `role.leader`・`no_read_paths`・`team_mode` も。`core/assembly/install-sub.sh --check-profile` が resolve 結果を1行で返す（副作用ゼロ）。
3. `core/assembly/update-sub.sh` — pull → `install-sub.sh` → `ai-brain/data/vault-public/Preferences/` 再同期を毎回行う（引数なし・旧・再同期フラグは廃止）。`done.` で終わることを確認し、新しいセッションの開幕1行で版を確認する。`AGENTS: dangling` が出た場合は、表示されたファイルを削除する。

⚠️ `update-sub.sh` の失敗文面は原因を「配役表の `machine_role` が `sub` でない」と示しますが、実際の起点が「プロファイルが旧 schema で固定キーが `unknown` 扱いになっている」場合でも同じ文面になります（resolver 自身の `stderr` は捨てられます）。まず `profile_resolve.py resolve` を直接叩いて何が読めているかを確認してから、原因を判断してください。

#### dotfiles（部品）も一緒に導入する

```sh
core/assembly/install-main.sh --with-dotfiles   # または install-sub.sh --with-dotfiles
cd ~/work/dotfiles && git pull --ff-only && ./install.sh   # 既存の dotfiles を更新
```

cmux Dock の「Project」／「Task」枠の詳細＝Vault の `Decisions/2026-09-15-cmux-dock-two-repo-split`。

#### 案件宣言の使い方（`dock/executor/cmux-task-declare.sh`）

「Task」枠は、**フォーカス中の cmux ワークスペース**に宣言された案件の Tasks 節を出す。宣言はワークスペースごとに 1 回＝`~/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh set <slug>`（実行はリーダー。フックは呼ばない）。宣言の鍵はワークスペースの UUID で、cmux は再起動を越えて UUID を保持する＝**cmux の再起動後も同じワークスペースでは宣言が生きている**ので、そこでは宣言し直さなくてよい。新しいワークスペース（新規に開いた・復元されなかった）は未宣言から始まる＝SessionStart の注入文（`bootstrap-vault.sh` の登録名で動く合成器が組む、Dock の宣言状態の寄与＝⑥の行）が呼び出し元ワークスペースの**宣言状態**（`宣言済み: <slug>`／`未宣言`／`宣言状態 不明`・記録が読めないときは `宣言記録破損` も）を出すので、その行を見て `未宣言` なら 1 回宣言する。他のサブコマンド＝`list`／`unset`／`prune`（週次メンテが `prune` を実行する）。

### Vault バックアップの運用

`ai-brain/executor/backup-vault.sh` は `$HOME/Data/obsidian` を対象に、変更があれば `git add -A && git commit`（メッセージ: `backup: YYYY-MM-DD HH:MM`）し、remote `origin` が設定済みの場合のみ push します（未設定なら commit までで警告を出して終了）。詳細＝スクリプト冒頭のコメント。

### 週次メンテナンスランナー（メイン専用機能）

`ai-brain/executor/maintenance.sh` は単一の週次ランナーです（毎週月曜06:00・`ai-brain/assembly/install-maintenance.sh` が設置。詳細＝スクリプト冒頭のコメント）。

**状態記録の契約（schema 2）** — `~/.claude/logs/maintenance/last-run.json` が週次ランナーの実行結果の正本で、判定機（`ai-brain/executor/health_judge.py`＝SessionStart フックと Dock が呼ぶ）が読みます。旧 6 キー（`started_at`／`last_success_at`／`last_result`／`last_result_summary`／`fragments_candidates`／`fragments_since`）は旧読み手のため従来どおり書きますが、新しい読み手は下のキーだけを使います。

- `run` — **直近の開始**とその終わり方。開始時に無条件で書き（`status: running`・`started_at` と同時）、**終わり方 6 経路すべてでランナー自身の内容で丸ごと書き直します**: 完了記録に到達する 4 経路（完走／Phase 0 直前スナップショット失敗／Vault 書込ロック取得失敗／実行ディレクトリ作成失敗）→ `status: completed`、busy-skip の 2 経路（Phase 0 backup が busy → `skipped`＋`skip_reason: busy:backup0`、Vault 書込ロックが busy → `skipped`＋`busy:lock`）。フィールド＝`run_id`（`<日付>/<HHMMSS-pid>`）・`run_dir`・`started_at`・`trigger`（`scheduled`／`manual`）・`status`・`stale_after_seconds`（`MAINTENANCE_STALE_LOCK_SECONDS` の写し。読み手はこの値で「実行中」と「中断」を分ける）・`skip_reason`・`finished_at`。`running` のまま `stale_after_seconds` を過ぎた記録＝完了記録に到達せずランナーが止まった（中断）。
- `completed` — **直近の完了記録**（完了記録に到達する 4 経路だけが書く。busy-skip は前回のまま残す）。`fully_ok` は完全正常終了のときだけ true。`steps[]` は**異常工程 1 つにつき 1 要素**（正常な工程は書かない）＝`id`（`phase0-dir`／`phase0-lock`／`phase0-backup`／`phase0-export`／`phase1-drift`／`phase1-fragments`／`phase1-inventory`／`phase3-summary`／`phase3-backup`／`phase3-record`）・`name`・`result`（`fail`／`warn`。子の失敗をランナーが警告として継続し完走しても `fail`。`warn` は drift 検知だけ）・`reason`（逐語・切り詰めない・制御文字は空白へ正規化）・`actor`（`AI`／`本人`＝ランナーの固定表。drift 検知は `本人`、他は `AI`、表に無い id は `本人`）・`log_ref`（その工程のログ＝`run_dir` 配下）。`info[]`＝工程ではない参考情報（`config.toml` の未知キー・宣言掃除の未実施）。
- `success_streak` — 完全正常終了の連続回数（異常な完了で 0 に戻る）。
- `ack` — リーダー AI の対処済み申告（後述）。次の完全正常終了でランナーが削除し、再失敗なら残す（`ack.run_id != completed.run_id` を判定機が「申告後に再失敗」と読む）。

**手動起動（`ai-brain/executor/maintenance-kick.sh`）** — launchd 経由（`launchctl kickstart`・`-k` は付けない）で週次ランナーを起動するので、定期実行と同じ実行体・同じ環境（plist の `HOME`／`PATH`／`USER`）・同じ記録先を通ります。起動前に印ファイルを置き、記録には `trigger: manual` と載ります（`launchctl kickstart` を直接叩いた起動は `scheduled` と記録される＝監査用の既知の限界）。LaunchAgent が未ロード（`KICK_REFUSED:not_loaded`・終了 2）、Vault 書込ロック保持中または `run.status` が `running` で `stale_after_seconds` 未満（`KICK_REFUSED:busy`・終了 3）、印ファイルを作れない（終了 4）のときは起動しません。kickstart 失敗＝`KICK_FAILED`（5）、30 秒以内に新しい `run.run_id` が現れない＝`KICK_TIMEOUT`（6・この場合も印ファイルを消します＝この後に遅れて開始した run は `manual` ではなく `scheduled` として記録されうる）。成功時は `RUN_ID:<id>` と `STATE_FILE:<path>` を印字し、`--wait` を付けると `run.status != running` まで待って `STATUS:<completed|skipped>` と `FULLY_OK:<true|false>`（`skipped` なら `SKIP_REASON:<busy:…>`＝失敗ではなく再実行の対象。数分後に再実行）を印字します。完了記録が現れなければ `KICK_WAIT_TIMEOUT`（7）。

**昇格の締め（`ai-brain/executor/fragments-reviewed.sh`）** — Dock の週次行が数えた昇格候補への対応が終わったら（記録職が対応済みの各エントリへ `status: promoted` を付けた後に）実行し、次の週次を待たずに候補数を 0 件へ戻します。今日を排他的な起点として未処理 Fragments を数え直し（`fragments_log.py --since <今日>`・当日分は数えない。下記の既知の限界を参照）、`fragments_reviewed_at`（UTC の今）・`fragments_candidates`・`fragments_since` を `last-run.json` へ原子的に書きます。次回の週次メンテの `--since` は、`fragments_reviewed_at` が有効（形式正・未来でない・30 日以内）ならそれを優先し、無効なら従来どおり `last_success_at` へフォールバックします。失敗時（検出スクリプトの失敗/timeout・JSON 破損・契約違反のいずれか）は何も書かずに非 0 で終わり、理由を stderr へ 1 行出します。`--dry-run` は書く予定の 3 値を表示するだけで書き込みません。テスト用 env は `LAST_RUN_FILE`・`FRAGMENTS_LOG_PY`・`TIMEOUT_FRAGMENTS_LOG`（既定は `maintenance.sh` と同じ）。既知の限界＝窓は日付単位（`since_date < d`）なので、CLI を実行した**その日**に足した Fragments は翌日以降まで数えられません（昇格対応の一連の最後に実行してください）。

**対処済み申告（`health_judge.py ack`）** — リーダー AI が「対処した・次回の本番実行で判定する」を `last-run.json` の `ack` に残します:

```
python3 ~/work/takumi009-ai-env/ai-brain/executor/health_judge.py ack \
  --last-run <path> --note "<対処内容 1 行>" \
  [--session-id <sid>] [--observation <session-observation.json>]
```

`--session-id` は任意。省略時は観測記録（`${HEALTH_OBSERVATION_FILE:-$HOME/.claude/logs/health/session-observation.json}`＝SessionStart フックが書く）の `session_id`＝今回のリーダーセッションを読みます（`CLAUDE_CODE_SESSION_ID` という環境変数は存在しません）。観測記録も読めなければ `session_id: null` で書きます（申告は成立させる・sid は監査用）。書く内容＝`{"at", "note", "session_id", "run_id"}`（`run_id`＝そのときの `completed.run_id`）を原子的に。**受理条件（すべて満たすときだけ書く）**＝記録が解析できる ∧ `completed` がある ∧ `completed.fully_ok == false` かつ `steps` が 1 件以上 ∧ 実行中でない（`run.status == running` かつ経過 < `stale_after_seconds` ではない）∧ Vault 書込ロック保持中でない。申告対象は `completed.steps` の項目だけ（未起動・中断・破損・旧形式・棚卸し・読込・想起は申告を持たない＝各源の OK 条件は次回の本番実行・次セッションで自動的に判定される）。拒否時は固定文 `ACK_REFUSED:<running|locked|broken|no_completed|nothing_to_ack>` を 1 行出して非 0 で終わり、ファイルには触れません。申告は段階を変えません（OK は本番経路の実行結果だけが作る。失効＝次の完全正常終了で削除・再失敗なら残置）。

### 使用率の見える化（usage_snapshot.py）

**手動で見る口**: `python3 usage/executor/usage_snapshot.py` を実行すると同じ3行がその場で表示されます（`--json` を付けると機械可読の1行JSONになります）。詳細＝`usage/executor/usage_snapshot.py` の docstring。

### 使用率取得器（usage/executor/usage-fetch.sh／usage/assembly/install-usage-fetch.sh）

導入は `usage/assembly/install-usage-fetch.sh`（`install-backup.sh` と同型の素の bootstrap+enable インストーラ。`--dry-run` は現在の状態を表示するだけ）。詳細＝`usage/executor/usage-fetch.sh`・`usage/assembly/install-usage-fetch.sh` 冒頭のコメント。

### ズレの検知（check-drift.sh）

```sh
core/assembly/check-drift.sh
```

以下5点を検査し、一覧表示します（**検知しても exit 1 にはしません**＝手動確認用のレポートツール）: ① symlink と生成物 `~/.claude/settings.json`、② 生成物 `~/.codex/config.toml`、③ 未commitの変更、④ `ai-brain/data/vault-public/Preferences` の差分（informational）、⑤ private repo の remote が **private** のままか。詳細＝スクリプト冒頭のコメント。

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
cp team/data/profile.md.sample ~/.config/takumi009-ai-env/profile.md    # ローカル設定はバックアップ対象外のため作り直す
cp team/data/models.conf.sample ~/.config/takumi009-ai-env/models.conf  # （machine_role・モデル定義を旧機と同じ値へ戻す）
core/assembly/install-main.sh --with-dotfiles   # symlink 化＋dotfiles
ai-brain/assembly/install-backup.sh             # 定期バックアップ再開
ai-brain/assembly/install-maintenance.sh        # 週次メンテナンスランナー再開
usage/assembly/install-usage-fetch.sh --dry-run  # 使用率取得の再開: まず状態だけ確認
usage/assembly/install-usage-fetch.sh            # 使用率取得を再開

# 5. 各アプリのログイン（手動）: Claude Code / Codex / その他
```

- 復元される範囲＝**push 済みの状態まで**（未 commit の作業は失われる）
- バックアップの最大遅延は Mac のスリープに依存する

#### メインの移転（新しい Mac に計画的に乗り換えるとき）

1. 旧メインで最後の同期: `ai-brain/executor/backup-vault.sh` → `ai-brain/executor/export-public-vault.sh` → 未 push が無いことを `core/assembly/check-drift.sh` で確認
2. 新 Mac で上記「災害復旧」手順を実行
3. 旧メインの LaunchAgent を停止（`launchctl bootout gui/$(id -u)/com.takumi009.<label>`）— **メインは常に1台**（編集権限・push 地点の一意性を守る）

### セッション引き継ぎ（core/connect/claude-code/session-handoff.sh）

セッションが長くなったとき、再開メモを書いたあと本スクリプトで新しい cmux ワークスペースを開き、`cct`（Claude Code）を起動して続きの依頼を1行で投入する。

```sh
core/connect/claude-code/session-handoff.sh <再開メモのパス> "<続きの依頼>" [--cwd <dir>] [--name <題>]
core/connect/claude-code/session-handoff.sh -h | --help
```

引数・終了コード・環境変数＝`core/connect/claude-code/session-handoff.sh -h`。

### テスト

```sh
bash tests/run-all.sh
```

`tests/test-*.sh` の全スイートを続けて実行し、失敗があれば最後に非 0 で終わります。いずれも実 Vault・実 GitHub・実 `~/.claude`・実 `~/.codex` に依存せず、使い捨てのfixtureディレクトリ上で完結します（`rg`・`gitleaks` が必要。`brew bundle` 済みなら揃っています）。この一括実行には台帳の検査（`tests/test-ledger.sh`＝`core/assembly/ledger-tool.sh check` が行う）も含まれます＝全部品・全スイートが台帳にちょうど1行持つこと、鍵の照会以外で機能をまたぐ参照が無いこと、全転送 symlink が主後継へ届くこと、`install-main.sh` が登録する全フック・LaunchAgent の起動対象が実在すること。

### ライセンス

[MIT](LICENSE)
