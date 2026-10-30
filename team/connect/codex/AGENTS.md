# Global Codex Instructions

- At the beginning of every new thread, tell the user: 「作業の根は `~/Workspace` です。起動時に選択されているフォルダーで作業します。」
- Do not assume the workspace can be changed after thread creation; clearly tell the user when a new thread must be created with that folder selected.

## Workspace Folder Rules (Finalized 2026-10-30)

- The workspace root is `~/Workspace`; its only direct subfolders are `Projects` and `Tools`.
- Each project uses `~/Workspace/Projects/<slug>/` with `docs`, `work`, and `output` subfolders.
- Start Codex and Claude from `~/Workspace` (Claude uses `cct`).

## Delegated-task tooling guard (Finalized 2026-06-22)

- Delegated tasks: do not use Computer Use / browser-UI automation; get web information via `web_search`. If UI control is unavoidable, stop and report back instead of driving the UI.

## Obsidian External Brain Role Assignment (Finalized 2026-10-31)

- The user shares an Obsidian Vault as an "external brain" among multiple assistants.
  - Vault path: `~/Data/obsidian`
  - Access method: **Direct filesystem access** (read/grep files directly; the leader also writes directly). **Do NOT use obsidian-mcp** — its ConnectionMonitor has a known bug that hangs requests (incl. reads); it is unmaintained (v1.0.6).
- **Only the leader writes to the Vault**, regardless of the size of the edit. Before writing, read `Preferences/vault-operation.md` in full and follow its writing and publication rules.
- **Workers never write to the Vault** (create, edit, delete, move, rename, or tag changes). This also applies when invoked as a worker through `codex-exec.sh`. Report knowledge to retain (resolved bug, decision, project-state change, preference) in the final report under `Vault記録候補:`; the leader writes it. Enforce this through role instructions; do not add a write-blocking mechanism.
- **Preferences edits and public snapshot generation/commits are main-machine-only**. Before doing either, check that `~/.config/takumi009-ai-env/profile.md` has `machine_role` configured with `value=main`.
- Do NOT broadly read or search the Vault on your own. Read ONLY the specific Vault notes the leader or user points you to for the task, given as folder-qualified paths (e.g. `Preferences/vrm-license-policy.md`), plus the writing rules required above before a Vault write.
- You MUST read `Preferences/absolute-rules.md` in full when directed to it and obey every rule in it without exception.

## Output & Reporting Conventions (Finalized 2026-06-20)

When reporting back to the orchestrator (Claude) / user:

- **Reply in Japanese** unless the task explicitly asks otherwise (deliverables like code/README follow the task's own spec).
- **Lead with the conclusion / answer first**, then supporting detail. No long preamble, no filler, no restating the request.
- **Use concise bullet points.** Keep it as short as the task allows.
- **Cite sources / file paths** when relevant (e.g. `path/to/file.ts:42`, or a URL for web findings).

### Context economy (important — keep the orchestrator's context small)

- **Do NOT paste large file contents, full logs, or raw dumps back.** Return the conclusion / summary only.
- For explore / investigate / "read and summarize" tasks: return the finding plus the relevant `file:line` references, NOT the file bodies. The orchestrator will open specifics if needed.
- If output would be long, summarize and offer to expand on request rather than dumping everything.
