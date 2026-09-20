#!/usr/bin/env python3
"""claude_exec.py — scripts/claude-exec.sh が使うJSON処理部分（設計
ラッパー起動-設計-v1.1.1.md §2・D-1）。

子環境のキー列挙・職種ごとの `--settings` 組み立て・失敗分類・
`invocation` 行の生成と排他追記を担う。判定式はここへ1箇所だけ持ち、
Bash側（scripts/claude-exec.sh）へ複製しない。

外部ライブラリに依存しない（標準ライブラリのみ）。

サブコマンド:
  env-keys
      現在の環境（os.environ）のうち ^ANTHROPIC_/^AWS_/^CLAUDE_CODE_ に
      一致するキー名を、FR-8の固定1キー（CLAUDE_CODE_WRAPPER_BIN）を除いて
      NUL区切りで標準出力する（値は出さない＝FR-15）。

  child-settings --src <path> --role <職種> --child-cwd <絶対パス> --agents-dir <dir>
      設計§2.5のとおり、(1)親から抽出する層 + (2)Vault保護の柵（裁定A・
      Vault 書込を宣言した職種以外＝`<dir>/<職種>.md` の frontmatter
      `aienv-vault-write: allowed` の有無を agent_def.vault_declared_writable で
      読む）+ (3)カナリア（SessionEnd）を組んだ `--settings` インラインJSONを
      標準出力する。抽出元が読めない／解析できない／(1)が0command／宣言が
      不正（重複・不正値・未知の aienv- キー）／定義が読めないなら非0で
      終わる（呼び出し側はexit 8にする＝F3）。

  classify --raw <path> [--timed-out]
      子の標準出力（--output-format json）ファイルを読み、FR-19の分類器
      （§2.8）にかける。REASON_CODE/EXIT_CODE/SESSION_ID の3行
      （KEY\\tVALUE）を標準出力する。⑤その他のときはresultの全文を標準
      エラーへ1行出す（AC-19b⑤）。

  log-append --log <path> --invocation-id <id> --task-id <id> --role <role>
      --candidate-def <def> --exit-code <n> --reason-code <code|->
      --artifact-path <path> --child-session-id <sid|-> --child-cwd <cwd|->
      `type=invocation` の1行をJSON Linesで`fcntl.flock`排他のうえ追記する
      （FR-18・AC-21）。キーはちょうど11個。
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sys
from datetime import datetime, timezone

# 同じ lib/ に在る（スクリプト実行時の sys.path[0]）＝追加の path 操作は不要。
import agent_def

# --- env-keys ---------------------------------------------------------

_PREFIX_RE = re.compile(r"^(ANTHROPIC_|AWS_|CLAUDE_CODE_)")
_WRAPPER_BIN_KEY = "CLAUDE_CODE_WRAPPER_BIN"


def cmd_env_keys(_args: argparse.Namespace) -> int:
    keys = sorted(
        k for k in os.environ if _PREFIX_RE.match(k) and k != _WRAPPER_BIN_KEY
    )
    out = "\0".join(keys)
    if keys:
        out += "\0"
    sys.stdout.write(out)
    return 0


# --- child-settings -----------------------------------------------------

# 設計§2.5(1): この2本を含む command を持つフックはリーダー専用として
# 除外する（agent-model-guard.sh・delegation-gate-v2.sh）。
_LEADER_ONLY_MARKERS = ("delegation-gate-v2.sh", "agent-model-guard.sh")

_VAULT_GATE_ENTRY = {
    "matcher": "Edit|Write|NotebookEdit",
    "hooks": [
        {
            "type": "command",
            "command": "$HOME/.claude/hooks/vault-write-gate.sh",
        }
    ],
}


def _filter_pretooluse(entries: list) -> list:
    """(1) 親から抽出する層。command単位でリーダー専用を除き、0本になった
    エントリはエントリごと落とす（DR1-m5）。"""
    kept_entries = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        hooks = entry.get("hooks")
        if not isinstance(hooks, list):
            continue
        kept_hooks = [
            h
            for h in hooks
            if isinstance(h, dict)
            and not any(
                marker in (h.get("command") or "") for marker in _LEADER_ONLY_MARKERS
            )
        ]
        if kept_hooks:
            new_entry = dict(entry)
            new_entry["hooks"] = kept_hooks
            kept_entries.append(new_entry)
    return kept_entries


def cmd_child_settings(args: argparse.Namespace) -> int:
    try:
        with open(args.src, "r", encoding="utf-8") as f:
            src = json.load(f)
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"CHILD_SETTINGS_SRC_UNREADABLE: {exc}\n")
        return 1

    hooks = src.get("hooks") if isinstance(src, dict) else None
    pretooluse = hooks.get("PreToolUse") if isinstance(hooks, dict) else None
    if not isinstance(pretooluse, list):
        pretooluse = []

    layer1 = _filter_pretooluse(pretooluse)
    if not layer1:
        sys.stderr.write("CHILD_SETTINGS_LAYER1_EMPTY: (1)の柵が0本です\n")
        return 1

    # (2) Vault 保護の柵＝定義ファイルの宣言が無い職種にだけ載せる（職種名の
    # 名指しはしない＝設計 2026-09-20 §3.1・FR-10）。宣言が不正なら fail-close
    # （既存 2 コードと同じ出し方＝stderr 1 行・stdout 空・return 1）。
    try:
        declared = agent_def.vault_declared_writable(args.agents_dir, args.role)
    except agent_def.AgentDefError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1

    combined = list(layer1)
    if not declared:
        combined.append(_VAULT_GATE_ENTRY)

    canary_path = os.path.join(args.child_cwd, ".claude-exec-hooks-alive")
    # シェル側で展開させない（パスをそのままcommandに埋め込む＝設計§2.5(3)）。
    canary_command = ': > "{}"'.format(canary_path.replace('"', '\\"'))

    result = {
        "hooks": {
            "PreToolUse": combined,
            "SessionEnd": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": canary_command,
                        }
                    ]
                }
            ],
        }
    }
    sys.stdout.write(json.dumps(result, ensure_ascii=False))
    return 0


# --- classify -------------------------------------------------------------


def _classify(parsed: object) -> tuple[str | None, int, str]:
    """FR-19（設計§2.8）の分類器本体。戻り値=(reason_code or None, exit_code,
    session_id)。"""
    if not isinstance(parsed, dict):
        return "other", 14, ""

    is_error = bool(parsed.get("is_error"))
    api_status = parsed.get("api_error_status")
    result_text = parsed.get("result")
    result_text = result_text if isinstance(result_text, str) else ""
    session_id = parsed.get("session_id")
    session_id = session_id if isinstance(session_id, str) else ""
    denials = parsed.get("permission_denials")

    if (
        is_error
        and api_status == 429
        and result_text.startswith("API Error: Request rejected (429)")
    ):
        return "limit_reached", 10, session_id

    if is_error and (
        api_status in (401, 403)
        or (
            api_status is None
            and (
                result_text.startswith("Not logged in")
                or result_text.startswith("Login expired")
            )
        )
    ):
        return "auth_failed", 11, session_id

    if is_error:
        sys.stderr.write(result_text + "\n")
        return "other", 14, session_id

    if isinstance(denials, list) and len(denials) > 0:
        return "permission_denied", 13, session_id

    return None, 0, session_id


def cmd_classify(args: argparse.Namespace) -> int:
    if args.timed_out:
        sys.stdout.write("REASON_CODE\ttimeout\n")
        sys.stdout.write("EXIT_CODE\t12\n")
        sys.stdout.write("SESSION_ID\t\n")
        return 0

    raw = None
    try:
        with open(args.raw, "r", encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        raw = None

    parsed = None
    if raw is not None and raw.strip():
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None

    reason_code, exit_code, session_id = _classify(parsed)

    sys.stdout.write(f"REASON_CODE\t{reason_code or ''}\n")
    sys.stdout.write(f"EXIT_CODE\t{exit_code}\n")
    sys.stdout.write(f"SESSION_ID\t{session_id}\n")
    return 0


# --- log-append -------------------------------------------------------------

_INVOCATION_KEYS = (
    "ts",
    "type",
    "invocation_id",
    "task_id",
    "role",
    "candidate_def",
    "exit_code",
    "reason_code",
    "artifact_path",
    "child_session_id",
    "child_cwd",
)


def _null_if_placeholder(value: str | None) -> str | None:
    if value is None or value in ("", "-"):
        return None
    return value


def cmd_log_append(args: argparse.Namespace) -> int:
    now = datetime.now(timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"

    record = {
        "ts": ts,
        "type": "invocation",
        "invocation_id": args.invocation_id,
        "task_id": args.task_id,
        "role": args.role,
        "candidate_def": args.candidate_def,
        "exit_code": int(args.exit_code),
        "reason_code": _null_if_placeholder(args.reason_code),
        "artifact_path": args.artifact_path,
        "child_session_id": _null_if_placeholder(args.child_session_id),
        "child_cwd": _null_if_placeholder(args.child_cwd),
    }
    # キーはちょうど11個（AC-21①）。`python3 -O` でも消えないよう assert では
    # なく明示の分岐にする（DR1-m4）。
    if set(record.keys()) != set(_INVOCATION_KEYS):
        raise ValueError(
            f"invocation record keys mismatch: {sorted(record.keys())} != "
            f"{sorted(_INVOCATION_KEYS)}"
        )

    line = json.dumps(record, ensure_ascii=False) + "\n"

    log_dir = os.path.dirname(args.log)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    with open(args.log, "a", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write(line)
            f.flush()
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
    return 0


# --- CLI --------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="claude_exec.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("env-keys")

    p_child_settings = sub.add_parser("child-settings")
    p_child_settings.add_argument("--src", required=True)
    p_child_settings.add_argument("--role", required=True)
    p_child_settings.add_argument("--child-cwd", required=True)
    p_child_settings.add_argument("--agents-dir", required=True)

    p_classify = sub.add_parser("classify")
    p_classify.add_argument("--raw", required=True)
    p_classify.add_argument("--timed-out", action="store_true")

    p_log_append = sub.add_parser("log-append")
    p_log_append.add_argument("--log", required=True)
    p_log_append.add_argument("--invocation-id", required=True)
    p_log_append.add_argument("--task-id", required=True)
    p_log_append.add_argument("--role", required=True)
    p_log_append.add_argument("--candidate-def", required=True)
    p_log_append.add_argument("--exit-code", required=True)
    p_log_append.add_argument("--reason-code", default="")
    p_log_append.add_argument("--artifact-path", required=True)
    p_log_append.add_argument("--child-session-id", default="")
    p_log_append.add_argument("--child-cwd", default="")

    args = parser.parse_args(argv)

    if args.cmd == "env-keys":
        return cmd_env_keys(args)
    if args.cmd == "child-settings":
        return cmd_child_settings(args)
    if args.cmd == "classify":
        return cmd_classify(args)
    if args.cmd == "log-append":
        return cmd_log_append(args)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
