#!/usr/bin/env python3
"""配置済みリーダーフックの接続状態と信頼ハッシュを読む。"""
import json
import os
from pathlib import Path
import shlex
import tomllib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "executor"))
from health_judge import codex_hook_hash


def recall_connections():
    """配置済みの両ハンドラ・実行ファイルと Codex の有効/信頼状態を読む。"""
    result = {}
    for leader in ("claude", "codex"):
        try:
            home = Path.home() / (".claude" if leader == "claude" else ".codex")
            config = (tomllib.loads((home / "config.toml").read_text()) if leader == "codex"
                      else json.loads((home / "settings.json").read_text()))
            if leader == "claude" and config.get("disableAllHooks"):
                result[leader] = "構成異常"
                continue
            sources = [(home / "settings.json", config.get("hooks", {}))]
            if leader == "codex":
                if config.get("features", {}).get("hooks") is not True:
                    result[leader] = "構成異常"
                    continue
                sources = [(home / "config.toml", config.get("hooks", {}))]
                if (home / "hooks.json").exists():
                    sources.append((home / "hooks.json", json.loads((home / "hooks.json").read_text())["hooks"]))
            found = set()
            waiting = False
            disabled = False
            for source, hooks in sources:
                for gi, group in enumerate(hooks.get("UserPromptSubmit", [])):
                    for hi, handler in enumerate(group.get("hooks", [])):
                        command = handler.get("command", "")
                        words = shlex.split(command)
                        if not words or Path(words[0]).name != "vault-recall.sh":
                            continue
                        if "--leader" not in words or words[words.index("--leader") + 1] != leader:
                            continue
                        executable = Path(os.path.expandvars(words[0]))
                        if not os.access(executable, os.X_OK) or not executable.resolve().with_name("recall_runtime.py").is_file():
                            continue
                        found.add("expected" if "--observe" in words else "recall")
                        if leader == "codex":
                            key = f"{source}:user_prompt_submit:{gi}:{hi}"
                            state = config.get("hooks", {}).get("state", {}).get(key, {})
                            disabled |= state.get("enabled") is False
                            waiting |= state.get("trusted_hash") != codex_hook_hash(group, handler)
            result[leader] = ("構成異常" if found != {"expected", "recall"} or disabled else
                              "本人の承認待ち" if waiting else None)
        except (OSError, ValueError, KeyError, IndexError):
            result[leader] = "構成異常"
    return result
