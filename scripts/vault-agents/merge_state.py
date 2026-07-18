#!/usr/bin/env python3
"""Knowledgeマージ候補の state.json 操作＋排他ロックを共有するモジュール
（2026-07-16簡素化・cleanup決定#10・設計書§2.4「state.json操作はknowledge_merge_
candidates.pyからscripts/vault-agents/merge_state.pyへ抽出し検出器・apply層で
共用」）。

抽出元: scripts/vault-agents/knowledge_merge_candidates.py（週次検出器）。
利用元: knowledge_merge_candidates.py（検出・pending追加）・
scripts/vault-agents/maintenance_apply.py（PR2・未実装＝MERGE適用時のstatus
遷移＝pending→merged/skipped）が同じstate.jsonファイル・同じロックを共有する。

ロジックは検出器から一切変更せずそのまま移設（旧・knowledge_merge.pyの
DEFAULT_LOCK_FILEと意図的に同じパスを使う設計も踏襲）。
"""
import fcntl
import json
import os
import pathlib

# state.json（旧・knowledge_merge.pyも同じファイルを読み書きしていた）の排他ロック。
# 検出側と適用側が別ロックだとlost updateが起こり得るため、同一lockファイルで
# 相互排他する。取得できない場合はfail-open（呼び出し元が「今回は書込せずexit 0」
# として扱う）。
DEFAULT_LOCK_FILE = pathlib.Path.home() / ".claude" / "tmp" / "vault-merge.lock"

STATE_SCHEMA_VERSION = 1

# 各候補の状態。merged/skippedは終端（次回以降追跡しない）。
# pending/blocked/retryは非終端（次回実行でも無条件で引き継ぐ）。
TERMINAL_STATUSES = ("merged", "skipped")


class StateError(Exception):
    """既存のstate.jsonが読めるが内容が壊れている/想定外の形式であることを表す。
    呼び出し側はこの例外を「今回は書込せずexit 0」のfail-openシグナルとして
    扱う（壊れたファイルを黙って上書きしない）。
    """


def empty_state():
    return {"schema_version": STATE_SCHEMA_VERSION, "candidates": {}, "detections": {}}


def load_state(path):
    """state.jsonを読み込む。ファイルが存在しない（初回実行）場合のみ空状態から
    始める。ファイルが存在するのに読込/解析に失敗する・形式が想定外・
    schema_versionが不一致の場合はStateErrorを送出する（既存データを破棄して
    空状態へ静かにフォールバックしない）。
    """
    p = pathlib.Path(path)
    if not p.is_file():
        return empty_state()
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise StateError(f"state.jsonの読込/解析に失敗しました: {e}") from e
    if not isinstance(data, dict):
        raise StateError("state.jsonの形式が不正です（オブジェクトではありません）")
    if "schema_version" not in data:
        raise StateError("state.jsonに'schema_version'がありません（破損/改ざんの可能性）")
    if data["schema_version"] != STATE_SCHEMA_VERSION:
        raise StateError(
            f"state.jsonのschema_versionが不一致です（index={data['schema_version']!r} "
            f"expected={STATE_SCHEMA_VERSION}）")
    if "candidates" in data and not isinstance(data["candidates"], dict):
        raise StateError("state.jsonの'candidates'がオブジェクトではありません")
    if "detections" in data and not isinstance(data["detections"], dict):
        raise StateError("state.jsonの'detections'がオブジェクトではありません")
    data.setdefault("candidates", {})
    data.setdefault("detections", {})
    return data


def save_state(path, state):
    """一時ファイルに書いてからos.replaceで原子更新する（更新途中の中途半端な
    内容を読み手に見せない）。"""
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.parent / f".{p.name}.tmp-{os.getpid()}"
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(str(tmp), str(p))


def acquire_lock(lock_path):
    """非blockingでflock排他ロックを取得する。取得できればファイルオブジェクトを、
    できなければNoneを返す。
    """
    lock_path = pathlib.Path(lock_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
        f = os.fdopen(fd, "r+")
    except OSError:
        return None
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close()
        return None
    return f


def release_lock(held):
    if held is None:
        return
    try:
        fcntl.flock(held.fileno(), fcntl.LOCK_UN)
    finally:
        held.close()
