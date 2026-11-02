#!/usr/bin/env python3
"""両 leader と手動の共通入口。期限・JSONL・包みだけを担当する。"""
import time

PROCESS_STARTED = time.monotonic()

import argparse
import json
import os
from pathlib import Path
import signal
import sys
import uuid
from datetime import datetime, timezone

from keyword_recall_helper import (BudgetExceeded, RECALL_CONFIG_PATH,
                                   load_recall_config, recall_situations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--leader", choices=load_recall_config()["leaders"], required=True)
    parser.add_argument("--observe", action="store_true", help="独立した発火期待だけを記録")
    parser.add_argument("--manual", action="store_true", help="stdin の任意文を同じ照合へ渡す")
    parser.add_argument("--session-id", default="manual")
    parser.add_argument("--vault", default=os.environ.get("VAULT_RECALL_VAULT", str(Path.home() / "Data/obsidian")))
    parser.add_argument("--budget-ms", type=float)
    parser.add_argument("--max-items", type=int)
    parser.add_argument("--threshold", type=float)
    args = parser.parse_args()
    # 既存の worker 印と hook 入力で対象を除く。cmux の条件は使わない。
    if os.environ.get("AIENV_CODEX_WORKER") == "1":
        return
    raw = sys.stdin.read()
    input_failed = False
    try:
        payload = {} if args.manual else json.loads(raw)
    except ValueError:
        payload, input_failed = {}, True
    if payload.get("agent_id") or payload.get("agent_type"):
        return
    session = args.session_id if args.manual else payload.get("session_id", "")
    mode = "manual" if args.manual else "hook"
    run_id = None if args.observe else str(uuid.uuid4())
    # 既定値は JSON のみ。読めない・壊れた JSON は外側で診断し、health も記録障害にする。
    # JSON を読めた後の設定値不備は、既定の記録先へ残す。
    defaults = json.loads(Path(RECALL_CONFIG_PATH).read_text())
    log_path = Path(os.environ.get("VAULT_RECALL_LOG", defaults["log_path"])).expanduser()

    def record(event, items=None, error=None):
        row = {"schema": "vault-recall/1", "at": datetime.now(timezone.utc).isoformat(),
               "leader": args.leader, "session_id": session, "mode": mode,
               "event": event, "items": items or [], "error": error}
        if run_id:
            row["run_id"] = run_id
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
            return True
        except OSError:
            print("想起: 記録先へ書き込めません", file=sys.stderr)
            return False

    try:
        config = load_recall_config(budget_ms=args.budget_ms, max_items=args.max_items,
                                    threshold=args.threshold)
        log_path = Path(config["log_path"])
    except (OSError, ValueError, KeyError):
        if not args.observe:
            record("started")
            record("failed", error={"kind": "config", "reason": "想起設定を確認してください"})
        else:
            record("expected")
        return
    if args.observe:
        if not args.manual:
            record("expected")
        return
    if not record("started"):
        return

    def timeout(_signum, _frame):
        raise BudgetExceeded()

    if input_failed:
        record("failed", error={"kind": "input", "reason": "hook 入力の JSON が不正"})
        return
    error = None
    try:
        remaining = config["budget_ms"] / 1000 - (time.monotonic() - PROCESS_STARTED)
        if remaining <= 0:
            raise BudgetExceeded()
        signal.signal(signal.SIGALRM, timeout)
        signal.setitimer(signal.ITIMER_REAL, remaining)
        if not Path(args.vault).is_dir():
            raise FileNotFoundError()
        prompt = raw if args.manual else payload.get("prompt", "")
        result = recall_situations(args.vault, prompt, config, started_at=PROCESS_STARTED)
    except BudgetExceeded:
        error = {"kind": "timeout", "reason": "待ち時間上限を超過"}
    except (OSError, UnicodeError):
        error = {"kind": "read", "reason": "Vault の読み取りに失敗"}
    except Exception:
        error = {"kind": "matcher", "reason": "照合器の実行に失敗"}
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    if error:
        record("failed", error=error)
        return
    if not record("completed", items=[item["id"] for item in result["candidates"]]):
        return
    if result["text"]:
        if args.manual:
            print(result["text"])
        else:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                                    "additionalContext": result["text"]}}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"想起: 入力・入口の異常（{type(exc).__name__}）", file=sys.stderr)
    # hook は常に終了0。本文・入力値を stderr に写さない。
