#!/usr/bin/env bash
# 記録職廃止（リーダー裁定 2026-10-31・案B）の受入テスト。
# 実行方法: bash tests/test-scribe-retired.sh
# fixture は一時ディレクトリ内だけ。実 claude・実 HOME・Vault は使わない。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$TESTS_DIR" "${BASH_SOURCE[0]}" <<'PY'
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

tests_dir = Path(sys.argv[1])
repo = tests_dir.parent
self_path = Path(sys.argv[2]).resolve()
agents = repo / "team/rules/agents"
sample = repo / "team/data/profile.md.sample"
resolver = repo / "team/executor/profile_resolve.py"
retired = ("vault-scribe", "vault-scribe-light")
passed = failed = 0


def check(name, condition):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok - {name}", flush=True)
    else:
        failed += 1
        print(f"  NG - {name}", flush=True)


def run(argv, env, cwd):
    return subprocess.run(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=60)


def no_retired_names(text):
    return not any(name in text for name in retired)


def is_vault_gate_entry(entry):
    try:
        matcher = re.compile(entry.get("matcher", ""))
    except re.error:
        return False
    if not all(matcher.fullmatch(tool) for tool in ("Edit", "Write", "NotebookEdit")):
        return False
    for hook in entry.get("hooks", []):
        if hook.get("type") != "command":
            continue
        try:
            command = shlex.split(hook.get("command", ""))
        except ValueError:
            continue
        # パス1語の直接実行だけを認める。echo・シェル演算子・置換は認めない。
        if len(command) == 1 and re.fullmatch(
                r"(?:[A-Za-z0-9_./~ -]|\$HOME|\$\{HOME\})+/vault-write-gate\.sh",
                command[0]):
            return True
    return False


# AC-1: 両方の職種定義が無い（壊れたリンクも残さない）。
check("AC-1 記録職の定義が2本とも無い",
      all(not os.path.lexists(agents / f"{name}.md") for name in retired))

# AC-2: 見本の配役行が無い。
check("AC-2 見本に記録職の配役行が無い",
      not re.search(r"^\s*role\.vault-scribe[^:]*:",
                    sample.read_text(), re.MULTILINE))

with tempfile.TemporaryDirectory(prefix="test-scribe-retired-") as tmp:
    work = Path(tmp)
    home = work / "home"
    home.mkdir()
    env = os.environ.copy()
    # 呼出元の試験設定・親sidを引き継がず、書込先を一時領域へ固定する。
    for key in list(env):
        if key.startswith("AIENV_") or key == "CLAUDE_CODE_SESSION_ID":
            del env[key]
    env.update(HOME=str(home), PYTHONDONTWRITEBYTECODE="1")
    models = work / "models.conf"
    models.write_text("[probe-sonnet]\nprovider=anthropic-api\n"
                      "model=claude-sonnet-5-5\neffort=high\n")
    env["AIENV_MODEL_DEFS_FILE"] = str(models)
    profile = work / "profile.md"
    profile.write_text("---\nschema_version: 7\nprofile_slug: retirement-probe\n"
                       "team_mode: configured value=full\n"
                       "no_read_paths: unavailable\n"
                       "machine_role: configured value=main\n"
                       "role.leader: configured model=probe-sonnet\n---\n")

    # AC-3a: 配役行を省いた職種はマニフェスト由来の VACANT_UNKNOWN に出る。
    # 内部関数の import ではなく CLI の実際の解決結果で観測する。
    result = run([sys.executable, str(resolver), "resolve", str(profile),
                  "--agents-dir", str(agents)], env, work)
    check("AC-3a CLIの職種マニフェストに記録職が出ない",
          result.returncode == 0 and result.stdout.startswith("OK\t")
          and "VACANT_UNKNOWN:" in result.stdout
          and no_retired_names(result.stdout))

    sample_env = dict(env, AIENV_MODEL_DEFS_FILE=str(repo / "team/data/models.conf.sample"))
    result = run([sys.executable, str(resolver), "resolve", str(sample),
                  "--agents-dir", str(agents)], sample_env, work)
    check("AC-3b 見本のCLI解決で記録職の空席が出ない",
          result.returncode == 0 and result.stdout.startswith("OK\t")
          and no_retired_names(result.stdout))

    # AC-4: 既存 test-claude-exec.sh と同じ偽 claude・最小の試験用定義。
    probe_agents = work / "agents"
    probe_agents.mkdir()
    binary = work / "claude"
    shutil.copy2(tests_dir / "fake-claude/claude", binary)
    binary.chmod(0o700)
    settings = work / "settings.json"
    settings.write_text(json.dumps({"hooks": {"PreToolUse": [
        {"matcher": "Bash", "hooks": [
            {"type": "command", "command": "echo fixture-guard"}]}]}}))
    prompt = work / "prompt.txt"
    prompt.write_text("~/Data/obsidian/Preferences/absolute-rules.md を全文読む。試験用依頼。\n")
    env.update(AIENV_LOCAL_PROFILE_PATH=str(profile),
               AIENV_AGENT_SOURCE_DIR=str(probe_agents),
               AIENV_CHILD_SETTINGS_SRC=str(settings),
               AIENV_CLAUDE_EXEC_LOG=str(work / "invocations.jsonl"),
               AIENV_CLAUDE_EXEC_TIMEOUT_SECS="30",
               GATE_MARKER_DIR=str(work / "markers"),
               CLAUDE_CODE_WRAPPER_BIN=str(binary))
    for suffix, declaration, condition_id in (
            ("declared", "aienv-vault-write: allowed\n", "AC-4a"),
            ("plain", "", "AC-4b")):
        role = f"probe-{suffix}"
        (probe_agents / f"{role}.md").write_text(
            f"---\nname: {role}\ndescription: retirement probe\ntools: Read\n"
            f"{declaration}---\nprobe body\n\n## 権限\n"
            "成果物への書込＝なし／テスト＝なし／実行＝なし\n")
        profile.write_text(profile.read_text().replace(
            "\n---\n", f"\nrole.{role}: configured model=probe-sonnet\n---\n"))
        log = work / f"{role}.jsonl"
        env["AIENV_CLAUDE_STUB_LOG"] = str(log)
        result = run(["bash", str(repo / "team/connect/claude-code/claude-exec.sh"),
                      "--role", role, "--prompt-file", str(prompt),
                      "--out", str(work / f"{role}.json"),
                      "--task-id", role, "--model-def", "probe-sonnet"], env, work)
        protected = False
        if result.returncode == 0 and log.is_file():
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            if len(calls) == 1:
                argv = calls[0]["argv"]
                if "--settings" in argv:
                    child_settings = json.loads(argv[argv.index("--settings") + 1])
                    protected = sum(
                        is_vault_gate_entry(entry)
                        for entry in child_settings.get("hooks", {}).get("PreToolUse", [])
                    ) >= 1
        check(f"{condition_id} {suffix}: 子にVault保護の柵が載る", protected)

# AC-5: 未追跡・隠しファイルも対象。検索内容は出さず真偽だけを判定する。
# .git・公開の写し・本テスト以外を勝手に除外しない。
clean = True
excluded_public = repo / "ai-brain/data/vault-public"
needles = (b"vault-scribe", b"aienv-vault-write")
try:
    def walk_error(error):
        raise error

    for directory, dirs, files in os.walk(repo, onerror=walk_error):
        parent = Path(directory)
        dirs[:] = [name for name in dirs
                   if name != ".git" and parent / name != excluded_public]
        for name in files:
            path = parent / name
            # grep -r と同様、探索中のシンボリックリンクは辿らない。
            if path.is_symlink() or path.resolve() == self_path:
                continue
            content = path.read_bytes()
            if any(needle in content for needle in needles):
                clean = False
except OSError:
    clean = False
check("AC-5 指定の除外以外に退役名・書込宣言キーが0件", clean)

print(f"\n=== summary: {passed} passed, {failed} failed ===", flush=True)
sys.exit(0 if failed == 0 else 1)
PY
