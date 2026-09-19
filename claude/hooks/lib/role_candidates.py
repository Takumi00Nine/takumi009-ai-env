#!/usr/bin/env python3
"""role_candidates.py — 名前無し subagent の起動候補を1回で引くための
AI 専用コマンド（設計-v1.2.md §4「D-3 候補一覧コマンド」・
要件v1.2.1 FR-14〜24）。

用途はリーダーが spawn 直前に候補を照会することだけ（人向けの体裁は
持たない・色や整形やsummaryは無い＝FR-14・SO-9）。判定式（provider の
enum・`AGENT_MODEL` の別名表・拒否条件・`execution` の既定）はすべて
`profile_resolve.py`（`list-candidates`サブコマンド）に委ね、ここでは
複製しない（FR-18）。使用率は`usage_snapshot.py --json`を1回呼ぶだけ
（FR-19・NFR-2）。

依存はどちらも subprocess 経由（python の import はしない・設計§4.1「依存の
呼び方」）。exit code は常に0（提示専用・FR-23）。配役表が解決できない、
またはこのコマンド自身が想定外の例外を投げた場合は、stdout にヘッダ1行
だけを出し、stderr に機械可読の1行 `UNRESOLVED<TAB><code>` を出す
（設計§4.6）。

⚠️ 秘匿方針の明示的な例外口（要件v1.2.1 OV-10）: この出力は AI が明示的に
このコマンドを呼んだときだけ、定義名・起動値（`pass`）を返す。セッション
開始の注入には一切出さない。

置き場: `claude/hooks/lib/` は元から symlink されない場所（repo 実体パスを
直接叩く）。したがって check-drift.sh の管理symlink集合にも載らない
（設計§4.1）。

呼び方（README 2026-09-19）: Any role whose `tools:` frontmatter includes `Bash` can look up its own launch candidates (definition name, resolved route, pass/fail, and remaining usage) with `python3 ~/work/takumi009-ai-env/claude/hooks/lib/role_candidates.py [--role <role>]` — an AI-facing command, not meant for interactive use.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from typing import Optional

HEADER = "role\tdef\troute\tpass\tok\th5\td7"

# 既定パス（設計§4.1）。⚠️ このコマンドは実配置を渡す（C-6）——「Claude Code
# が今読む定義が実在するか」を見る口だから（素材ディレクトリを渡す経路は
# 案件③ B-1 D-4で退役した effort 生成方式の名残であり現存しない）。
DEFAULT_PROFILE_PATH = "~/.config/takumi009-ai-env/profile.md"
DEFAULT_AGENTS_DIR = "~/.claude/agents"

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
PROFILE_RESOLVE_PY = os.path.join(_LIB_DIR, "profile_resolve.py")
USAGE_SNAPSHOT_PY = os.path.join(_LIB_DIR, "usage_snapshot.py")

# 枠の対応（設計§4.5・FR-19）。route がこの2つ以外（該当なし・候補なし職種の
# 空文字を含む）は両方 "-"。
POOL_FOR_ROUTE = {
    "subagent": "claude-subscription",
    "external-cli": "codex-subscription",
}


def _profile_path(cli_value: Optional[str]) -> str:
    if cli_value:
        return os.path.expanduser(cli_value)
    raw = os.environ.get("AIENV_LOCAL_PROFILE_PATH") or DEFAULT_PROFILE_PATH
    return os.path.expanduser(raw)


def _agents_dir(cli_value: Optional[str]) -> str:
    if cli_value:
        return os.path.expanduser(cli_value)
    return os.path.expanduser(DEFAULT_AGENTS_DIR)


def _run_list_candidates(profile_path: str, agents_dir: str) -> tuple[Optional[list[list[str]]], Optional[str]]:
    """`profile_resolve.py list-candidates`をsubprocessで1回呼ぶ（設計§4.1
    「依存の呼び方」＝python importはしない）。
    戻り値: (行のリスト（各行はTSVを分割したフィールド一覧） or None,
    UNRESOLVEDコード or None)。
    """
    proc = subprocess.run(
        [
            sys.executable,
            PROFILE_RESOLVE_PY,
            "list-candidates",
            profile_path,
            "--agents-dir",
            agents_dir,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        code = "UNKNOWN"
        first_line = (proc.stderr or "").splitlines()
        if first_line:
            head = first_line[0].split("\t", 1)[0]
            if head:
                code = head
        return None, code

    rows = [line.split("\t") for line in proc.stdout.splitlines() if line != ""]
    return rows, None


def _run_usage_snapshot() -> Optional[dict]:
    """`usage_snapshot.py --json`をsubprocessで1回呼ぶ。呼び出し自体が失敗
    しても fail-soft（設計§4.5＝全行`-`にするだけ・`ok`はresolverの判定
    だけで決める）。
    """
    try:
        proc = subprocess.run(
            [sys.executable, USAGE_SNAPSHOT_PY, "--json"],
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout)
    except (ValueError, TypeError):
        return None
    return data if isinstance(data, dict) else None


def _remaining_percent(snapshot: Optional[dict], pool_ref: str, window_name: str) -> str:
    """設計§4.5。`-`（取得不能・stale等）または切り捨て整数の文字列。"""
    if snapshot is None:
        return "-"
    pools = snapshot.get("pools")
    if not isinstance(pools, list):
        return "-"
    pool = next(
        (p for p in pools if isinstance(p, dict) and p.get("pool_ref") == pool_ref), None
    )
    if pool is None or pool.get("usage_state") != "ok":
        return "-"
    windows = pool.get("windows")
    if not isinstance(windows, list):
        return "-"
    window = next(
        (w for w in windows if isinstance(w, dict) and w.get("window") == window_name), None
    )
    if window is None:
        return "-"
    remaining = window.get("remaining_percent")
    if not isinstance(remaining, (int, float)) or isinstance(remaining, bool):
        return "-"
    return str(math.floor(remaining))


def _usage_pair(snapshot: Optional[dict], route: str) -> tuple[str, str]:
    pool_ref = POOL_FOR_ROUTE.get(route)
    if pool_ref is None:
        return "-", "-"
    return (
        _remaining_percent(snapshot, pool_ref, "five_hour"),
        _remaining_percent(snapshot, pool_ref, "seven_day"),
    )


def _ok_value(verdict: str, h5: str, d7: str) -> str:
    """FR-17。`no`になるのは①その枠が上限（h5またはd7が0）②resolverが拒否
    （verdict!="OK"）——この2つだけ。`-`（取得不能・stale）は0と等しくない
    ので枠を理由に`no`にしない（FR-19）。
    """
    if verdict != "OK":
        return "no"
    if h5 == "0" or d7 == "0":
        return "no"
    return "ok"


def build_output_lines(
    rows: list[list[str]], snapshot: Optional[dict], role_filter: Optional[str]
) -> tuple[list[str], int]:
    """`list-candidates`の行（6列）をこのコマンドの7列/2列へ写像する
    （設計§4.3）。`--role`はこの写像の後に行を絞るだけ（§4.3-4）。
    戻り値の第2要素は捨てた行数（想定外の形の行）。1件でもあれば
    呼び出し側（main）がstderrにUNRESOLVED行を1つ出す（設計§4.6・
    MINOR-8＝静かな失敗にしない）。
    """
    out_lines = []
    dropped = 0
    for fields in rows:
        if len(fields) < 6:
            dropped += 1  # 想定外の形（防御）。行は捨てるが黙ってはいない。
            continue
        role, state, def_name, route, pass_value, verdict = fields[:6]
        if role_filter is not None and role != role_filter:
            continue
        if def_name == "":
            # 候補を持たない職種（not_adopted/unknown）＝2フィールド
            # （FR-21。空列でのパディングはしない）。
            out_lines.append(f"{role}\t{state}")
            continue
        pass_out = pass_value if pass_value else "-"
        h5, d7 = _usage_pair(snapshot, route)
        ok = _ok_value(verdict, h5, d7)
        out_lines.append("\t".join([role, def_name, route, pass_out, ok, h5, d7]))
    return out_lines, dropped


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="role_candidates.py",
        description="名前無し subagent の起動候補一覧（AI専用・人向け整形はしない・FR-14）",
    )
    parser.add_argument("--profile", default=None, help="ローカル実体プロファイルのパス（既定はAIENV_LOCAL_PROFILE_PATHまたは~/.config/takumi009-ai-env/profile.md）")
    parser.add_argument("--agents-dir", default=None, help="職種定義の実配置ディレクトリ（既定は~/.claude/agents＝C-6）")
    parser.add_argument("--role", default=None, help="この職種の行だけに絞る（省略時は全職種）")
    args = parser.parse_args(argv)

    # ヘッダは常に出す（--role指定時・該当0件時・UNRESOLVED時も＝設計§4.3-1）。
    print(HEADER)

    try:
        profile_path = _profile_path(args.profile)
        agents_dir = _agents_dir(args.agents_dir)

        rows, unresolved_code = _run_list_candidates(profile_path, agents_dir)
        if unresolved_code is not None:
            sys.stderr.write(f"UNRESOLVED\t{unresolved_code}\n")
            return 0

        snapshot = _run_usage_snapshot()
        lines, dropped = build_output_lines(rows, snapshot, args.role)
        for line in lines:
            print(line)
        if dropped:
            # MINOR-8: 壊れた行を1件でも捨てたら、stdoutはそのまま・stderrに
            # 機械可読の1行を出す（設計§4.6の既存口を再利用・exit 0のまま）。
            sys.stderr.write("UNRESOLVED\tINTERNAL_ERROR\n")
        return 0
    except Exception:
        # 想定外例外（設計§4.6）。静かに0行を返さず、機械可読の1行を出す。
        sys.stderr.write("UNRESOLVED\tINTERNAL_ERROR\n")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
