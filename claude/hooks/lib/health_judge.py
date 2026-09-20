#!/usr/bin/env python3
"""health_judge.py — 外部脳ヘルスの判定機（唯一の判定ロジック＝FR-16）。

案件 health-self-explain（設計 v1.2 §4・§8）。状態記録 4 本（週次メンテの
`last-run.json`・棚卸しの `latest.json`・SessionStart の観測記録・想起ログ）を
読み、段階（OK／WARNING／ERROR）・要対処項目・付記を JSON 1 個
（`health-verdict/1`）で返す。bootstrap-vault.sh（注入ブロック）と
cmux-next-model.sh（Dock の B 行）はどちらもこの出力の写しを描くだけで、
自分では判定しない。

  python3 health_judge.py judge --last-run <last-run.json> \
      --inventory-latest <latest.json> --observation <session-observation.json> \
      --recall-log <vault-recall.tsv> [--reads-log <vault-reads.tsv>] \
      [--plist <com.takumi009.maintenance.plist>] [--now <RFC3339 UTC>] \
      [--recall-stale-days 7] [--tz <IANA 名>]
  python3 health_judge.py ack --last-run <last-run.json> --note "<対処内容>" \
      [--session-id <sid>] [--observation <session-observation.json>] \
      [--lock-file <vault-writer.lock>]

契約:
- `judge` は JSON を出せたときは常に終了コード 0。非 0 は判定機自身の異常
  （呼び出し側は fail-open で「判定不能」扱い＝設計 §4.5 F-10）。
- `--now` 省略時は現在時刻。恒久テストは必ず `--now` を渡す（再現性＝AC-17）。
- `--tz` 省略時は OS のローカル時刻帯（launchd が StartCalendarInterval を
  解釈する壁時計と同じ）。判定機は既定の時刻帯名を持たない。
- `--plist` 省略・不在・解析不能＝予定が無い（線が無い）＝時刻による未起動は
  判定しない。省略キーはワイルドカード（man launchd.plist）。
- 標準ライブラリだけで動く（macOS 同梱 python3 で動く範囲）。

評価順（週次メンテ・要件 §1 の 4 状態＋表示状態・設計 §4.1）:
  前提: JSON として解析不能／トップが object でない → ④ へ直行（broken）
  ① 不在（ファイル無し・{}・4 キーすべて無し）→ 要対処 0・終了
  ② 未起動 (A) 予定超過で開始記録なし／(B) 定期起動の busy-skip → 1 件を加えて続行
  ③ 前段: running（余裕未満）／skipped は表示状態（項目を足さず ④⑤ へ）
  ③ 中断: running かつ余裕以上 → 1 件・終了
  ④ 破損: 型違反・時刻解析不能／未来・書き手契約違反 → 1 件・終了
  ⑤ 完了記録: completed.steps[] を 1 件ずつ
  ⑥ 棚卸し記録の整合: ⑤ を評価したときだけ（steps に phase1-inventory が無いとき）
  旧形式（run／completed が無く started_at／last_result だけ）: last_result で 1 件／0 件

秘匿（NFR-4）: 状態記録の値をそのまま写すだけで、env・引数・ロックの中身は
出力に載せない。
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import plistlib
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

SCHEMA_VERDICT = "health-verdict/1"

# 結果種別の表示語（要件 §1 の 3 値＋状態記録の 3 状態）
RESULT_LABEL = {
    "fail": "失敗",
    "warn": "警告",
    "interrupted": "中断",
    "not_started": "未起動",
    "broken": "破損",
}

# ok_when の固定文（設計 §4.3 表）
OK_WHEN = {
    "step": "次回の本番経路の実行（定期起動または scripts/maintenance-kick.sh）が完全正常終了する",
    "not_started": "手動起動（scripts/maintenance-kick.sh）または次の定期起動が開始記録を残し、完全正常終了する",
    "interrupted": "手動起動で新しい完了記録が書かれ、完全正常終了する",
    "broken": "手動起動が記録を書き直し、完全正常終了する（記録ファイルを手で直さない）",
    "legacy": "次回の本番経路の実行が新契約（run／completed）で完了記録を書き、完全正常終了する",
    "inventory": "対処後、次回の週次メンテの棚卸し工程で検出されなくなる（件数が減る）",
    "load": "同セッション内で当該ノートを Read で読み直せる（1 回）。状態記録上の OK は次のセッション開始で成立",
    "recall_direct": "同セッション内で想起フックを手動起動して候補が出ることを確認（1 回）。状態記録上の OK は次のセッション開始で成立",
    "recall_stale": "10 文字以上のプロンプトで想起フックが有効な記録（候補提示または heartbeat）を書く（手動起動でも可）",
}

# 棚卸し種別 → 主体（設計 §3.5 の固定表）。表に無い kind は「本人」。
INVENTORY_ACTOR = {
    "unreadable": "AI",
    "missing_updated": "AI",
    "date_drift": "AI",
    "broken_links": "AI",
    "stale_keywords": "AI",
    "status_future_dated": "AI",
    "missing_aliases": "AI",
    "generic_aliases": "AI",
    "review_overdue": "AI",
    "review_invalid": "AI",
}

ACTORS = ("AI", "本人")
RECALL_TAIL_ROWS = 50
SEVERITY_RANK = {"OK": 0, "WARNING": 1, "ERROR": 2}


class JudgeError(Exception):
    """判定機自身の異常（呼び出し側は判定不能として扱う）。"""


# ---------------------------------------------------------------------------
# 時刻
# ---------------------------------------------------------------------------

def parse_rfc3339(value: Any) -> Optional[_dt.datetime]:
    """RFC3339／ISO8601 文字列を aware datetime（UTC）へ。解析不能なら None。"""
    if not isinstance(value, str) or not value.strip():
        return None
    s = value.strip()
    if s.endswith("Z") or s.endswith("z"):
        s = s[:-1] + "+00:00"
    try:
        d = _dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=_dt.timezone.utc)
    return d.astimezone(_dt.timezone.utc)


def fmt_utc(d: Optional[_dt.datetime]) -> Optional[str]:
    if d is None:
        return None
    return d.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fmt_local(d: Optional[_dt.datetime], tz: _dt.tzinfo) -> Optional[str]:
    if d is None:
        return None
    return d.astimezone(tz).strftime("%Y-%m-%d %H:%M %Z")


def resolve_tz(name: Optional[str]) -> _dt.tzinfo:
    """`--tz` があればその IANA 名、無ければ OS のローカル時刻帯。"""
    if name:
        try:
            from zoneinfo import ZoneInfo  # Python 3.9+
            return ZoneInfo(name)
        except Exception as exc:  # noqa: BLE001
            raise JudgeError(f"--tz が解決できません: {name}: {exc}") from exc
    env_tz = os.environ.get("TZ")
    if env_tz:
        try:
            from zoneinfo import ZoneInfo
            return ZoneInfo(env_tz)
        except Exception:  # noqa: BLE001
            pass
    try:
        from zoneinfo import ZoneInfo
        with open("/etc/localtime", "rb") as fh:
            return ZoneInfo.from_file(fh, key="localtime")
    except Exception:  # noqa: BLE001
        pass
    return _dt.datetime.now().astimezone().tzinfo or _dt.timezone.utc


def resolve_now(value: Optional[str]) -> Tuple[_dt.datetime, bool]:
    if value:
        d = parse_rfc3339(value)
        if d is None:
            raise JudgeError(f"--now が解析できません: {value}")
        return d, True
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0), False


# ---------------------------------------------------------------------------
# plist（配置済み LaunchAgent）から直近の予定時刻
# ---------------------------------------------------------------------------

def load_calendar_intervals(path: Optional[str]) -> Optional[List[Dict[str, int]]]:
    """StartCalendarInterval（辞書または辞書の配列）を読む。無し／不在／解析不能は None。"""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(data, dict):
        return None
    sci = data.get("StartCalendarInterval")
    if isinstance(sci, dict):
        sci = [sci]
    if not isinstance(sci, list):
        return None
    out: List[Dict[str, int]] = []
    for entry in sci:
        if not isinstance(entry, dict):
            continue
        spec: Dict[str, int] = {}
        for key in ("Month", "Day", "Weekday", "Hour", "Minute"):
            if key in entry:
                try:
                    spec[key] = int(entry[key])
                except (TypeError, ValueError):
                    spec = {}
                    break
        else:
            out.append(spec)
    return out or None


def _weekday_matches(spec_weekday: int, day: _dt.date) -> bool:
    launchd_wd = (day.weekday() + 1) % 7  # launchd: 0/7=日曜・1=月曜
    return spec_weekday % 7 == launchd_wd


def _day_matches(spec: Dict[str, int], day: _dt.date) -> bool:
    if "Month" in spec and spec["Month"] != day.month:
        return False
    has_day = "Day" in spec
    has_wd = "Weekday" in spec
    if has_day and has_wd:
        return spec["Day"] == day.day or _weekday_matches(spec["Weekday"], day)
    if has_day:
        return spec["Day"] == day.day
    if has_wd:
        return _weekday_matches(spec["Weekday"], day)
    return True


def latest_due(intervals: List[Dict[str, int]], now: _dt.datetime, tz: _dt.tzinfo) -> Optional[_dt.datetime]:
    """`now` 以前で最も新しい発火時刻（tz の壁時計）。最大 366 日遡る。"""
    now_local = now.astimezone(tz)
    best: Optional[_dt.datetime] = None
    for spec in intervals:
        hours = [spec["Hour"]] if "Hour" in spec else list(range(23, -1, -1))
        minutes = [spec["Minute"]] if "Minute" in spec else list(range(59, -1, -1))
        hours = sorted(hours, reverse=True)
        minutes = sorted(minutes, reverse=True)
        found: Optional[_dt.datetime] = None
        for back in range(0, 367):
            day = (now_local - _dt.timedelta(days=back)).date()
            if not _day_matches(spec, day):
                continue
            for h in hours:
                for m in minutes:
                    if not (0 <= h <= 23 and 0 <= m <= 59):
                        continue
                    try:
                        cand = _dt.datetime(day.year, day.month, day.day, h, m, tzinfo=tz)
                    except ValueError:
                        continue
                    if cand <= now_local:
                        found = cand
                        break
                if found is not None:
                    break
            if found is not None:
                break
        if found is not None and (best is None or found > best):
            best = found
    return best


# ---------------------------------------------------------------------------
# 入力の読み込み
# ---------------------------------------------------------------------------

def read_json_file(path: Optional[str]) -> Tuple[str, Any]:
    """('absent'|'unparsable'|'ok', data)"""
    if not path or not os.path.isfile(path):
        return "absent", None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return "ok", json.load(fh)
    except (OSError, ValueError, UnicodeDecodeError):
        return "unparsable", None


def normalize_actor(value: Any) -> str:
    return value if value in ACTORS else "本人"


def _as_str(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False)


# ---------------------------------------------------------------------------
# 週次メンテ（§4.1）
# ---------------------------------------------------------------------------

def _mk_maint_item(item_id: str, name: str, result_key: str, reason: str, actor: str,
                   ok_when: str, log_ref: Optional[str], ack: Any = None) -> Dict[str, Any]:
    return {
        "source": "maintenance",
        "severity": "WARNING",
        "id": item_id,
        "name": name,
        "result": RESULT_LABEL[result_key],
        "reason": reason,
        "actor": normalize_actor(actor),
        "ok_when": ok_when,
        "ack": ack,
        "log_ref": log_ref,
    }


def evaluate_maintenance(last_run_path: Optional[str], plist_path: Optional[str],
                         now: _dt.datetime, tz: _dt.tzinfo,
                         inventory_probe: Dict[str, Any]) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    src: Dict[str, Any] = {
        "state": None, "run_id": None, "trigger": None, "started_at": None, "finished_at": None,
        "success_streak": None, "skipped": None, "info_count": 0, "run_dir": None,
        "next_due": None, "prev_completed_run_id": None, "broken_reason": None, "legacy": False,
        "fully_ok": None,
    }
    items: List[Dict[str, Any]] = []
    intervals = load_calendar_intervals(plist_path)
    due = latest_due(intervals, now, tz) if intervals else None
    src["next_due"] = due.isoformat() if due else None

    status, data = read_json_file(last_run_path)

    def broken(reason: str) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
        src["state"] = "broken"
        src["broken_reason"] = reason
        items.append(_mk_maint_item("broken", "状態記録", "broken", f"破損: {reason}", "AI",
                                    OK_WHEN["broken"], last_run_path))
        return src, items

    # 前提: 解析不能／object でない → ④ へ直行
    if status == "unparsable":
        return broken("last-run.json が JSON として解析できない")
    if status == "ok" and not isinstance(data, dict):
        return broken("last-run.json のトップが object ではない")

    # ① 不在
    key_set = ("run", "completed", "started_at", "last_success_at")
    if status == "absent" or not data or not any(k in data for k in key_set):
        src["state"] = "absent"
        return src, items

    run = data.get("run")
    completed = data.get("completed")
    has_new = ("run" in data) or ("completed" in data)

    # 旧形式（移行期）
    if not has_new:
        src["legacy"] = True
        started = data.get("started_at")
        success = data.get("last_success_at")
        for label, v in (("started_at", started), ("last_success_at", success)):
            if v is None or v == "":
                continue
            d = parse_rfc3339(v)
            if d is None:
                return broken(f"{label} が解析できない")
            if d > now:
                return broken(f"{label} が未来時刻")
        started_dt = parse_rfc3339(started) if started else None
        src["started_at"] = fmt_utc(started_dt)
        if started_dt is not None and due is not None and due > started_dt:
            items.append(_mk_maint_item(
                "not_started", "状態記録", "not_started",
                f"予定時刻を過ぎて開始していない（予定 {fmt_local(due, tz)}・直近の開始 {fmt_utc(started_dt)}）",
                "AI", OK_WHEN["not_started"], last_run_path))
        last_result = data.get("last_result")
        src["state"] = "legacy"
        src["run_id"] = None
        if last_result in ("warn", "fail"):
            items.append(_mk_maint_item(
                "legacy", "前回の週次メンテ（旧形式の記録）", last_result,
                _as_str(data.get("last_result_summary")) or "（旧形式の記録・理由の内訳なし）",
                "本人", OK_WHEN["legacy"], last_run_path))
        return src, items

    # 以降は新契約。型の前検査（④ の材料）は ③ の後で行うが、②③ が読む値だけ先に取る。
    run_ok = isinstance(run, dict)
    run_started = parse_rfc3339(run.get("started_at")) if run_ok else None
    if run_started is None and not run_ok:
        run_started = parse_rfc3339(data.get("started_at"))
    run_status = run.get("status") if run_ok else None
    run_trigger = run.get("trigger") if run_ok else None
    if run_ok:
        src["run_id"] = _as_str(run.get("run_id"))
        src["trigger"] = _as_str(run_trigger)
        src["run_dir"] = _as_str(run.get("run_dir"))
        src["started_at"] = fmt_utc(run_started)
        src["finished_at"] = fmt_utc(parse_rfc3339(run.get("finished_at")))
    if isinstance(completed, dict):
        src["prev_completed_run_id"] = _as_str(completed.get("run_id"))
        src["fully_ok"] = completed.get("fully_ok")
        info = completed.get("info")
        src["info_count"] = len(info) if isinstance(info, list) else 0
    streak = data.get("success_streak")
    src["success_streak"] = streak if isinstance(streak, int) and not isinstance(streak, bool) else None

    # ② 未起動（加えて続行）
    not_started_reason = None
    if due is not None and run_started is not None and due > run_started:
        not_started_reason = f"予定時刻を過ぎて開始していない（予定 {fmt_local(due, tz)}・直近の開始 {fmt_utc(run_started)}）"
    if run_ok and run_status == "skipped" and run_trigger == "scheduled":
        reason_b = (f"当該予定の起動が実行なしに終わった（busy-skip: {_as_str(run.get('skip_reason')) or '理由不明'}・"
                    f"開始 {fmt_local(run_started, tz) or '不明'}）")
        not_started_reason = reason_b if not_started_reason is None else f"{not_started_reason}／{reason_b}"
    if not_started_reason is not None:
        items.append(_mk_maint_item("not_started", "状態記録", "not_started", not_started_reason,
                                    "AI", OK_WHEN["not_started"], last_run_path))

    # ③ 前段（表示状態）／中断
    # stale_after_seconds は書き手（maintenance.sh）が毎回 run に書く値をそのまま読むだけ
    # （線を判定機側に複製しない＝設計 §3.2）。無い／整数でないときは表示状態を決めず、
    # ④ で破損として扱う（欠落＝破損に統一・検証 B-1）。
    display_state = None
    stale_raw = run.get("stale_after_seconds") if run_ok else None
    stale_valid = isinstance(stale_raw, int) and not isinstance(stale_raw, bool)
    if run_ok and run_status == "running" and run_started is not None and stale_valid:
        elapsed = (now - run_started).total_seconds()
        if elapsed >= stale_raw:
            src["state"] = "interrupted"
            items.append(_mk_maint_item(
                "interrupted", "状態記録", "interrupted",
                f"開始したが完了記録が無い（開始 {fmt_utc(run_started)}・余裕 {stale_raw} 秒を超過）",
                "AI", OK_WHEN["interrupted"], _as_str(run.get("run_dir")) or last_run_path))
            return src, items
        display_state = "running"
    elif run_ok and run_status == "skipped":
        display_state = "skipped"
        src["skipped"] = _as_str(run.get("skip_reason")) or "busy"

    # ④ 破損（型・時刻・書き手契約）
    if run is not None and not run_ok:
        return broken("run が object ではない")
    if completed is not None and not isinstance(completed, dict):
        return broken("completed が object ではない")
    if run_ok:
        if run_started is None:
            return broken("run.started_at が無いか解析できない")
        if run_started > now:
            return broken("run.started_at が未来時刻")
        if run_status not in ("running", "completed", "skipped"):
            return broken(f"run.status が未知の値（{_as_str(run_status)}）")
        fin = run.get("finished_at")
        if fin is not None:
            fin_dt = parse_rfc3339(fin)
            if fin_dt is None:
                return broken("run.finished_at が解析できない")
            if fin_dt > now:
                return broken("run.finished_at が未来時刻")
        if not stale_valid:
            return broken("run.stale_after_seconds が無いか整数ではない")
    if isinstance(completed, dict):
        if not isinstance(completed.get("run_id"), str) or not completed.get("run_id"):
            return broken("completed.run_id が無い")
        if not isinstance(completed.get("fully_ok"), bool):
            return broken("completed.fully_ok が真偽値ではない")
        steps = completed.get("steps")
        if not isinstance(steps, list) or any(not isinstance(s, dict) for s in steps):
            return broken("completed.steps が配列ではない")
        for label in ("started_at", "finished_at"):
            v = completed.get(label)
            if v is None:
                continue
            d = parse_rfc3339(v)
            if d is None:
                return broken(f"completed.{label} が解析できない")
            if d > now:
                return broken(f"completed.{label} が未来時刻")
        anomalous = [s for s in steps if s.get("result") in ("fail", "warn")]
        if completed.get("fully_ok") is False and not anomalous:
            return broken("completed.fully_ok=false なのに異常工程が 0 件（書き手契約違反）")
        if completed.get("fully_ok") is True and anomalous:
            return broken("completed.fully_ok=true なのに異常工程がある（書き手契約違反）")
    if run_ok and run_status == "completed":
        if not isinstance(completed, dict):
            return broken("run.status=completed なのに completed が無い")
        if completed.get("run_id") != run.get("run_id"):
            return broken(f"run.status=completed なのに completed.run_id が一致しない"
                          f"（run={_as_str(run.get('run_id'))}, completed={completed.get('run_id')}）")
    if run is None and completed is None:
        # started_at／last_success_at だけの新旧混在（run/completed キーは在るが null）
        return broken("run と completed が両方とも null")

    # ⑤ 完了記録
    src["state"] = display_state or "completed"
    ack = data.get("ack") if isinstance(data.get("ack"), dict) else None
    if isinstance(completed, dict):
        fully_ok = completed.get("fully_ok")
        for step in completed.get("steps", []):
            result = step.get("result")
            if result not in ("fail", "warn"):
                continue
            ack_view = None
            if ack is not None and fully_ok is False:
                state = "pending" if ack.get("run_id") == completed.get("run_id") else "refailed"
                ack_view = {
                    "at": _as_str(ack.get("at")),
                    "note": _as_str(ack.get("note")),
                    "session_id": _as_str(ack.get("session_id")),
                    "state": state,
                }
            items.append(_mk_maint_item(
                _as_str(step.get("id")) or "unknown-step",
                _as_str(step.get("name")) or _as_str(step.get("id")) or "（工程名なし）",
                result,
                _as_str(step.get("reason")) or "（理由の記録なし）",
                step.get("actor"),
                OK_WHEN["step"],
                _as_str(step.get("log_ref")) or _as_str(completed.get("run_dir")) or last_run_path,
                ack_view,
            ))

    # ⑥ 棚卸し記録の整合（⑤ を評価したときだけ・steps に phase1-inventory が無いときだけ）
    step_ids = {s.get("id") for s in (completed.get("steps", []) if isinstance(completed, dict) else [])}
    if "phase1-inventory" not in step_ids and inventory_probe.get("inconsistent"):
        items.append(_mk_maint_item(
            "phase1-inventory", "Phase1③ vault_inventory（記録の整合）", "fail",
            f"棚卸しの状態記録が読めない／不整合（{inventory_probe.get('reason')}）",
            "AI", OK_WHEN["step"], inventory_probe.get("path")))
    return src, items


# ---------------------------------------------------------------------------
# 棚卸し（§3.5・§4.2）
# ---------------------------------------------------------------------------

def probe_inventory(path: Optional[str]) -> Dict[str, Any]:
    """latest.json の読み取り。inconsistent＝⑥ の材料（無し／解析不能／len(items)≠actionable）。"""
    status, data = read_json_file(path)
    probe: Dict[str, Any] = {"path": path, "status": status, "data": None, "inconsistent": False,
                             "reason": None, "legacy": False}
    if status == "absent":
        probe["inconsistent"] = True
        probe["reason"] = "latest.json が無い"
        return probe
    if status == "unparsable" or not isinstance(data, dict):
        probe["inconsistent"] = True
        probe["reason"] = "latest.json が解析できない"
        return probe
    probe["data"] = data
    actionable = data.get("actionable")
    items = data.get("items")
    if "items" not in data:
        probe["legacy"] = True
        return probe
    if not isinstance(items, list) or not isinstance(actionable, int) or isinstance(actionable, bool) \
            or len(items) != actionable:
        probe["inconsistent"] = True
        probe["reason"] = f"len(items)={len(items) if isinstance(items, list) else '?'} と actionable={_as_str(actionable)} が一致しない"
    return probe


def evaluate_inventory(probe: Dict[str, Any]) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    src: Dict[str, Any] = {"date": None, "actionable": None, "report_path": None, "legacy": probe["legacy"],
                           "readable": probe["status"] == "ok" and isinstance(probe["data"], dict)}
    items: List[Dict[str, Any]] = []
    data = probe.get("data")
    if not isinstance(data, dict):
        return src, items
    src["date"] = _as_str(data.get("date"))
    src["report_path"] = _as_str(data.get("report_path"))
    actionable = data.get("actionable")
    src["actionable"] = actionable if isinstance(actionable, int) and not isinstance(actionable, bool) else None
    log_ref = src["report_path"] or probe["path"]
    if probe["legacy"]:
        if isinstance(src["actionable"], int) and src["actionable"] >= 1:
            items.append({
                "source": "inventory", "severity": "WARNING", "kind": "legacy", "target": "（旧形式の棚卸し記録）",
                "detail": f"旧形式の棚卸し記録（内訳不明・要確認 {src['actionable']} 件）", "actor": "AI",
                "ok_when": OK_WHEN["inventory"], "ack": None, "log_ref": log_ref,
            })
        return src, items
    if probe["inconsistent"]:
        return src, items
    for entry in data.get("items", []):
        if not isinstance(entry, dict):
            continue
        kind = _as_str(entry.get("kind")) or "unknown"
        items.append({
            "source": "inventory", "severity": "WARNING", "kind": kind,
            "target": _as_str(entry.get("target")) or "（対象なし）",
            "detail": _as_str(entry.get("detail")) or "（詳細なし）",
            "actor": INVENTORY_ACTOR.get(kind, "本人"),
            "ok_when": OK_WHEN["inventory"], "ack": None, "log_ref": log_ref,
        })
    return src, items


# ---------------------------------------------------------------------------
# 読込・想起（§4.2）
# ---------------------------------------------------------------------------

def evaluate_observation(path: Optional[str]) -> Tuple[Dict[str, Any], Dict[str, Any], List[Dict[str, Any]], Optional[bool]]:
    load_src: Dict[str, Any] = {"observed_at": None, "session_id": None, "missing_count": 0,
                                "vault_root_readable": None, "observed": False}
    recall_src: Dict[str, Any] = {"prev_session_id": None, "injected": None, "reads_rows": None,
                                  "recall_valid_rows": None, "last_valid_row_age_days": None, "observed": False}
    items: List[Dict[str, Any]] = []
    status, data = read_json_file(path)
    if status != "ok" or not isinstance(data, dict):
        return load_src, recall_src, items, None
    load_src["observed_at"] = _as_str(data.get("observed_at"))
    load_src["session_id"] = _as_str(data.get("session_id"))
    load = data.get("load")
    if isinstance(load, dict):
        load_src["observed"] = True
        readable = load.get("vault_root_readable")
        load_src["vault_root_readable"] = readable if isinstance(readable, bool) else None
        missing = load.get("missing")
        missing_list = [m for m in missing if isinstance(m, str)] if isinstance(missing, list) else []
        if readable is False:
            load_src["missing_count"] = 1
            items.append({
                "source": "load", "severity": "ERROR", "id": "vault_root", "target": "Vault ルート",
                "result": "Vault ルートが読めない（必読ノートが 0 件）", "actor": "AI",
                "ok_when": OK_WHEN["load"], "ack": None, "log_ref": None,
            })
        else:
            load_src["missing_count"] = len(missing_list)
            for m in missing_list:
                items.append({
                    "source": "load", "severity": "ERROR", "id": "load_missing", "target": m,
                    "result": "読めない（本来存在するはずの必読ノート）", "actor": "AI",
                    "ok_when": OK_WHEN["load"], "ack": None, "log_ref": None,
                })
    injected: Optional[bool] = None
    rp = data.get("recall_prev")
    if isinstance(rp, dict):
        recall_src["observed"] = True
        recall_src["prev_session_id"] = _as_str(rp.get("session_id"))
        inj = rp.get("injected")
        injected = inj if isinstance(inj, bool) else None
        recall_src["injected"] = injected
        for k in ("reads_rows", "recall_valid_rows"):
            v = rp.get(k)
            recall_src[k] = v if isinstance(v, int) and not isinstance(v, bool) else None
        if injected is False:
            items.append({
                "source": "recall", "severity": "ERROR", "id": "recall_not_injected",
                "result": (f"前セッション（{recall_src['prev_session_id'] or '不明'}）で注入なし（直接観測）"),
                "reason": (f"前セッション {recall_src['prev_session_id'] or '不明'} は Vault を読んだ"
                           f"（reads {recall_src['reads_rows'] if recall_src['reads_rows'] is not None else '?'} 行）"
                           f"が想起の記録が 0 行"),
                "actor": "AI", "ok_when": OK_WHEN["recall_direct"], "ack": None, "log_ref": None,
            })
    return load_src, recall_src, items, injected


def last_valid_row_age_days(path: Optional[str], now: _dt.datetime) -> Optional[int]:
    """TSV の末尾 50 行のうち 3 列目が非空の最終行の経過日数。無ければ None（fail-open）。"""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    lines = raw.decode("utf-8", errors="replace").splitlines()[-RECALL_TAIL_ROWS:]
    last_ts: Optional[_dt.datetime] = None
    for line in lines:
        cols = line.split("\t")
        if len(cols) >= 3 and cols[2] != "":
            d = parse_rfc3339(cols[0])
            if d is not None:
                last_ts = d
    if last_ts is None:
        return None
    return int((now - last_ts).total_seconds() // 86400)


def evaluate_recall_stale(recall_log: Optional[str], now: _dt.datetime, stale_days: int,
                          injected: Optional[bool], recall_src: Dict[str, Any]) -> List[Dict[str, Any]]:
    age = last_valid_row_age_days(recall_log, now)
    recall_src["last_valid_row_age_days"] = age
    if injected is False:
        return []  # 直接観測が優先（二重にしない）
    if age is not None and age > stale_days:
        return [{
            "source": "recall", "severity": "WARNING", "id": "recall_stale",
            "result": f"直近 {stale_days} 日以内に有効な想起の記録なし（疑い・最終有効行 {age} 日前）",
            "reason": f"vault-recall.tsv の最終有効行が {age} 日前（線＝{stale_days} 日・直接観測なし）",
            "actor": "AI", "ok_when": OK_WHEN["recall_stale"], "ack": None, "log_ref": recall_log,
        }]
    return []


# ---------------------------------------------------------------------------
# judge
# ---------------------------------------------------------------------------

def judge(args: argparse.Namespace) -> Dict[str, Any]:
    now, now_injected = resolve_now(args.now)
    tz = resolve_tz(args.tz)
    stale_days = args.recall_stale_days

    inv_probe = probe_inventory(args.inventory_latest)
    maint_src, maint_items = evaluate_maintenance(args.last_run, args.plist, now, tz, inv_probe)
    inv_src, inv_items = evaluate_inventory(inv_probe)
    load_src, recall_src, obs_items, injected = evaluate_observation(args.observation)
    stale_items = evaluate_recall_stale(args.recall_log, now, stale_days, injected, recall_src)

    items = maint_items + inv_items + obs_items + stale_items
    for n, item in enumerate(items, start=1):
        item_ordered = {"n": n}
        item_ordered.update(item)
        items[n - 1] = item_ordered
    stage = "OK"
    for item in items:
        if SEVERITY_RANK[item["severity"]] > SEVERITY_RANK[stage]:
            stage = item["severity"]

    reads_age = last_valid_row_age_days(args.reads_log, now) if args.reads_log else None
    reads_log_stale: Optional[bool]
    if not args.reads_log or not os.path.isfile(args.reads_log):
        reads_log_stale = None
    else:
        reads_log_stale = (reads_age is None) or (reads_age > stale_days)

    fragments = None
    _st, lr = read_json_file(args.last_run)
    if isinstance(lr, dict):
        fc = lr.get("fragments_candidates")
        if isinstance(fc, int) and not isinstance(fc, bool) and fc >= 0:
            fragments = fc
        elif isinstance(fc, float) and fc >= 0 and fc == int(fc):
            fragments = int(fc)

    return {
        "schema": SCHEMA_VERDICT,
        "judged_at": fmt_utc(now),
        "stage": stage,
        "n_items": len(items),
        "items": items,
        "sources": {
            "maintenance": maint_src,
            "inventory": inv_src,
            "load": load_src,
            "recall": recall_src,
        },
        "extras": {
            "fragments_candidates": fragments,
            "reads_log_stale": reads_log_stale,
            "recall_stale_days": stale_days,
            "now_injected": now_injected,
            "tz": str(tz),
        },
    }


# ---------------------------------------------------------------------------
# ack（§8）
# ---------------------------------------------------------------------------

def _pid_lock_held(lock_file: Optional[str]) -> bool:
    """scripts/lib/pid-lock.sh の is_pid_lock_held と同じ読み取り専用の判定。"""
    if not lock_file or not os.path.isfile(lock_file):
        return False
    try:
        with open(lock_file, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return True  # 判定不能→held 扱い（fail-closed）
    if not lines or not lines[0].strip():
        return False
    try:
        pid = int(lines[0].strip())
    except ValueError:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    stored_fp = lines[1].strip() if len(lines) >= 2 else ""
    if not stored_fp or stored_fp == "FINGERPRINT-UNAVAILABLE":
        return True
    try:
        env = dict(os.environ, LC_ALL="C", TZ="UTC")
        out = subprocess.run([os.environ.get("PID_LOCK_PS_BIN", "ps"), "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True, env=env, check=False)
        if out.returncode != 0 or not out.stdout.strip():
            return True
        current_fp = " ".join(out.stdout.split())
    except OSError:
        return True
    return current_fp == stored_fp


def ack(args: argparse.Namespace) -> int:
    def refuse(reason: str) -> int:
        print(f"ACK_REFUSED:{reason}")
        return 1

    status, data = read_json_file(args.last_run)
    if status != "ok" or not isinstance(data, dict):
        return refuse("broken")

    now = _dt.datetime.now(_dt.timezone.utc)
    # 受理条件の「実行中」「破損」は判定機の評価順 ③④ と同じ関数（evaluate_maintenance）で
    # 判定する＝線・型検査を ack 側に複製しない（検証 B-1・B-4）。棚卸し整合（⑥）は
    # ack の受理条件に無関係なので常に整合ありとして渡す。
    inv_probe: Dict[str, Any] = {"inconsistent": False, "reason": None, "path": None}
    maint_src, _maint_items = evaluate_maintenance(args.last_run, None, now, _dt.timezone.utc, inv_probe)
    if maint_src.get("state") == "running":
        return refuse("running")

    lock_file = args.lock_file
    if lock_file is None:
        lock_file = os.path.join(os.path.dirname(os.path.abspath(args.last_run)), "vault-writer.lock")
    if _pid_lock_held(lock_file):
        return refuse("locked")

    if maint_src.get("state") == "broken":
        return refuse("broken")

    completed = data.get("completed")
    if not isinstance(completed, dict):
        return refuse("no_completed")
    steps = completed.get("steps")
    if completed.get("fully_ok") is not False or not isinstance(steps, list) or len(steps) < 1:
        return refuse("nothing_to_ack")

    session_id = args.session_id
    if not session_id:
        obs_path = args.observation or os.environ.get("HEALTH_OBSERVATION_FILE") or os.path.join(
            os.path.expanduser("~"), ".claude", "logs", "health", "session-observation.json")
        _s, obs = read_json_file(obs_path)
        if isinstance(obs, dict) and isinstance(obs.get("session_id"), str):
            session_id = obs.get("session_id")
        else:
            session_id = None
    data["ack"] = {
        "at": fmt_utc(now),
        "note": args.note,
        "session_id": session_id,
        "run_id": completed.get("run_id"),
    }
    tmp = f"{args.last_run}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, args.last_run)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"ACK_FAILED:{exc.__class__.__name__}")
        return 2
    print(f"ACK_WRITTEN:{completed.get('run_id')}")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="health_judge.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    j = sub.add_parser("judge", help="状態記録 4 本から health-verdict/1 を出す")
    j.add_argument("--last-run", required=True)
    j.add_argument("--inventory-latest", required=True)
    j.add_argument("--observation", required=True)
    j.add_argument("--recall-log", required=True)
    j.add_argument("--reads-log", default=None, help="vault-reads.tsv（extras.reads_log_stale の材料・任意）")
    j.add_argument("--plist", default=None)
    j.add_argument("--now", default=None, help="判定時刻（RFC3339 UTC）。省略時は現在時刻")
    j.add_argument("--recall-stale-days", type=int, default=7)
    j.add_argument("--tz", default=None, help="IANA 時刻帯名（テスト用）。省略時は OS ローカル")

    a = sub.add_parser("ack", help="対処済み申告を last-run.json の ack に書く")
    a.add_argument("--last-run", required=True)
    a.add_argument("--note", required=True)
    a.add_argument("--session-id", default=None)
    a.add_argument("--observation", default=None)
    a.add_argument("--lock-file", default=None, help="既定＝last-run.json と同じディレクトリの vault-writer.lock")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd == "judge":
        try:
            verdict = judge(args)
        except JudgeError as exc:
            print(f"JUDGE_ERROR:{exc}", file=sys.stderr)
            return 2
        json.dump(verdict, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    if args.cmd == "ack":
        return ack(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
