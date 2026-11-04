#!/usr/bin/env python3
"""Detached project leaders, using codex-exec.sh. Local records are version 1.

Use --help and README.md for the command and record contracts. No daemon,
worker inference, model selection, or Vault writes are performed here.
"""
import argparse
import csv
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import tomllib
import unicodedata
from collections import deque
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
VERSION = 1
CODEX_AGENTS_DIR = Path(".codex/agents")
VIEW_INTERVAL = float(os.environ.get("AIENV_LEADER_VIEW_INTERVAL", "5"))
ASSIGN_COLUMNS = ("version id stage scope artifact role worker address parent_thread "
                  "candidate model effort selection_ref replaces handoff_ref state_ref").split()
WORK_STATES = ("working consulting consultation-wait slot-wait stop-requested stopped "
               "parent-wait user-wait done replaced unrecoverable unconfirmed").split()
REPLACEMENT_REASONS = ("quota-exhausted", "resume-unavailable")
WORKER_EVENTS = ("worker-started", "worker-ready", "worker-finished", "worker-done",
                 "worker-slot-wait", "worker-unavailable")
COORDINATION_EVENTS = ("consult", "decision", "stop-request", "stop-received", "stop-confirm",
                       "resume-permitted", "work-resumed", "quality-review")


def now():
    return datetime.now(timezone.utc).isoformat()


def read_json(path):
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON object required: {path}")
    return value


def save(path, value):
    # One parent writes records; no independent worker writers or locking service.
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def required(record, keys):
    for key in keys:
        if key not in record or record[key] in (None, ""):
            raise ValueError(f"required field: {key}")


def lookup(key):
    result = subprocess.run([str(ROOT / "core/assembly/ledger-tool.sh"), "lookup", key],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"component unavailable: {key}")
    return result.stdout.strip()


def cmux(*args):
    return subprocess.run([os.environ.get("CMUX_TASK_CMUX_BIN", "cmux"), *args],
                          capture_output=True, text=True, check=True)


def check_display(project, workspace, surface):
    # Reuse the declaration CLI's format and note-before-declaration boundary.
    pairs = subprocess.run([lookup("dock.task-declare"), "list"],
                           capture_output=True, text=True, check=True).stdout.splitlines()
    if f"{workspace}\t{project}" not in pairs:
        raise ValueError("declare the project in its workspace before registering the leader")
    cmux("read-screen", "--workspace", workspace, "--surface", surface, "--lines", "1")


def assignments(state):
    with (state / "assignments.tsv").open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def reference(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("invalid-reference: nonempty file path required")
    path = Path(value).expanduser().absolute()
    if not path.is_file() or not path.stat().st_size:
        raise ValueError(f"invalid-reference: nonempty file required: {path}")
    return path


def structured_event(data):
    return data.get("event") in COORDINATION_EVENTS and (
        data["event"] in ("decision", "stop-received", "work-resumed", "quality-review") or
        any(key in data for key in ("topic", "change", "review", "participants", "exchanges")))


def coordination(state, unconfirmed=False):
    """Project explicit history, never session logs, into ongoing topics and stops."""
    settings = dict(ref=None, consultation_round_limit=None)
    result = dict(status="recorded", reason=None, settings=settings, topics=[], changes=[], reviews=[])
    try:
        settings["ref"] = str(Path(os.environ.get("AIENV_TEAM_WORKFLOW_CONFIG") or
                                   lookup("team.workflow-settings")).expanduser())
        config = read_json(Path(settings["ref"]))
        limit = config["consultation_round_limit"]
        if config["version"] != VERSION or type(limit) is not int or limit <= 0:
            raise ValueError("positive consultation_round_limit required")
        settings["consultation_round_limit"] = limit
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        result.update(status="unconfirmed", reason="settings-unreadable")
    topics, changes, reviews = {}, {}, {}
    try:
        history = [json.loads(line) for line in (state / "events.jsonl").read_text().splitlines() if line.strip()]
        for event in history:
            name = event["event"]
            if event.get("execution") in ("running", "unknown"):
                for change in changes.values():
                    if event.get("assignment") in change["targets"]:
                        change["confirmed"] = [i for i in change["confirmed"] if i != event["assignment"]]
            if not structured_event(event):
                continue  # Old unstructured events do not establish stage 3 evidence.
            if name == "consult":
                topic = dict(event)
                limit = settings["consultation_round_limit"]
                rounds = len(event["exchanges"])
                topic.update(rounds=rounds, limit=limit,
                             over_limit=None if limit is None else rounds > limit)
                topics[event["topic"]] = topic
            elif name == "quality-review":
                reviews[event["review"]] = dict(event)
            elif name == "stop-request":
                change = changes.setdefault(event["change"], dict(change=event["change"],
                    topic=event["topic"], owner=event["owner"], targets=[], sent=[], received=[],
                    confirmed=[], permissions=[], resumed=[]))
                change["targets"] = list(dict.fromkeys(change["targets"] + event["targets"]))
                change["scope_ref"] = event["scope_ref"]
                change["sent"] = list(dict.fromkeys(change["sent"] + [r["assignment"] for r in event["sent_refs"]]))
                change["recorded_at"] = event["recorded_at"]
            elif name in ("stop-received", "stop-confirm", "resume-permitted", "work-resumed"):
                change = changes[event["change"]]
                if name == "stop-received":
                    change["received"] = list(dict.fromkeys(change["received"] + event["targets"]))
                elif name == "stop-confirm":
                    change["confirmed"] = [i for i in change["confirmed"] if i not in event["targets"]]
                    if (event["execution"] == "ended" and event["work"] == "stopped"
                            and event["incomplete"] is False and event["execution_ref"]):
                        change["confirmed"] += event["targets"]
                elif name == "resume-permitted":
                    change["permissions"].append({key: event[key] for key in
                                                 ("targets", "ref", "premises_ref", "scope_ref")})
                else:
                    change["resumed"] = list(dict.fromkeys(change["resumed"] + event["targets"]))
                change["recorded_at"] = event["recorded_at"]
    except (OSError, ValueError, KeyError, TypeError):
        result.update(status="unconfirmed", reason="record-error")
    for change in changes.values():
        change["pending_targets"] = [i for i in change["targets"] if i not in change["confirmed"]]
        change["all_stopped"] = bool(change["targets"]) and not change["pending_targets"] and not change["resumed"]
        change["phase"] = ("resumed" if change["targets"] and set(change["resumed"]) == set(change["targets"]) else
                           "resuming" if change["permissions"] else
                           "stopped" if change["all_stopped"] else "stopping")
    result.update(topics=list(topics.values()), changes=list(changes.values()), reviews=list(reviews.values()))
    if unconfirmed:
        result.update(status="unconfirmed", reason="parent-unconfirmed")
    return result


def waiting_for_permission(change, ident):
    return ident in change["targets"] and not any(ident in p["targets"] for p in change["permissions"])


def validate_review(data):
    required(data, ("review", "triggers", "scope_ref", "basis_ref", "reason"))
    if type(data.get("required")) is not bool or any(
            trigger not in ("irreversible-design", "release", "uncertain")
            for trigger in string_list(data, "triggers")):
        raise ValueError("invalid review requirement/triggers")
    for key in ("scope_ref", "basis_ref"):
        reference(data[key])
    if data["required"]:
        reference(data.get("request_ref"))


def normalize_wrapper_reason(reason):
    """Use the wrapper's no-reason marker for omitted, null or empty reasons."""
    if reason is None or reason == "":
        return "-"
    if not isinstance(reason, str):
        raise ValueError("wrapper_reason must be a string or null")
    return reason


def validate_coordination(state, project, data):
    """Validate new structured input; legacy history remains readable."""
    try:
        event = data["event"]
        rows = {r["id"]: r for r in assignments(state)}
        parent_thread = effective_parent_thread(state, project)

        def member(ident):
            row = rows.get(ident)
            if row is None or row["parent_thread"] != parent_thread:
                raise ValueError("assignment must belong to the same parent")
            return row

        parent = event in ("decision", "resume-permitted", "quality-review")
        if "assignment" not in data or (parent and (data["assignment"] is not None or data["worker"] != "parent")):
            raise ValueError("invalid coordination actor")
        if not parent and member(data["assignment"])["worker"] != data["worker"]:
            raise ValueError("assignment/worker mismatch")
        for key in ("topic", "change", "subject", "position", "reason", "next_action"):
            if key in data and (not isinstance(data[key], str) or not data[key].strip()):
                raise ValueError(f"nonempty string required: {key}")
        reference(data["ref"])
        previous = coordination(state)
        if event == "consult":
            required(data, ("topic", "subject", "scope_ref", "peer", "phase", "next_action"))
            reference(data["scope_ref"])
            participants = string_list(data, "participants")
            if data["assignment"] not in participants or not any(member(i)["worker"] == data["peer"] for i in participants):
                raise ValueError("peer must be a participant in the same parent")
            for ident in participants:
                member(ident)
            if data["phase"] not in ("open", "waiting", "parent-wait", "user-wait", "concluded"):
                raise ValueError("invalid consultation phase")
            string_list(data, "dependencies")
            receipt = data["receipt"]
            if receipt is not None:
                if receipt["assignment"] not in participants or receipt["kind"] not in ("answering", "redirect", "dependency-wait"):
                    raise ValueError("invalid receipt")
                reference(receipt["ref"])
            exchanges = data["exchanges"]
            if not isinstance(exchanges, list):
                raise ValueError("exchanges must be an ordered array")
            replies = []
            for pair in exchanges:
                required(pair, ("proposal_id", "reply_id", "proposal_summary", "reply_summary"))
                if any(not isinstance(pair[k], str) or not pair[k].strip() for k in
                       ("proposal_id", "reply_id", "proposal_summary", "reply_summary")):
                    raise ValueError("exchange ids and summaries must be nonempty strings")
                replies.append(pair["reply_id"])
            old = next((t for t in previous["topics"] if t["topic"] == data["topic"]), None)
            if len(replies) != len(set(replies)) or (old and exchanges[:len(old["exchanges"])] != old["exchanges"]):
                raise ValueError("preserve exchanges and count each reply once")
            outcome = data["outcome"]
            if outcome is not None:
                required(outcome, ("classification", "conclusion", "reason", "disposition", "next_action"))
                validate_decision(outcome)
        elif event == "decision":
            required(data, ("reason", "decider", "next_action"))
            if not data.get("topic") and not data.get("change"):
                raise ValueError("topic or change required")
            validate_decision(data)
            reference(data["decision_ref"])
        elif event == "quality-review":
            validate_review(data)
            if "wrapper_exit" in data or "wrapper_reason" in data:
                data["wrapper_reason"] = normalize_wrapper_reason(data.get("wrapper_reason"))
            if data["work"] not in ("parent-wait", "user-wait"):
                raise ValueError("review must preserve parent decision wait")
            if data["state"] not in ("not-required", "requested", "received", "adopted", "rejected", "held"):
                raise ValueError("invalid review state")
            if (data["state"] == "not-required") == data["required"]:
                raise ValueError("review state does not match requirement")
            if data["state"] in ("received", "adopted", "rejected"):
                old = next((r for r in previous["reviews"] if r["review"] == data["review"]), None)
                if old and any(old[k] != data[k] for k in ("scope_ref", "basis_ref")):
                    raise ValueError("review result must match the requested scope and basis")
                required(data, ("wrapper_out_ref", "verifier_report_ref"))
                if data["wrapper_exit"] != 0:
                    raise ValueError("failed review must remain held")
                wrapper = read_json(reference(data["wrapper_out_ref"]))
                if not isinstance(wrapper.get("result"), str) or not wrapper["result"].strip():
                    raise ValueError("review final response missing")
                reference(data["verifier_report_ref"])
                if data["state"] == "received":
                    returned = read_json(reference(data["ref"]))
                    returned["wrapper_reason"] = normalize_wrapper_reason(returned.get("wrapper_reason"))
                    keys = ("review", "scope_ref", "basis_ref", "wrapper_exit", "wrapper_reason", "wrapper_out_ref", "verifier_report_ref")
                    if (returned["version"] != VERSION or returned["parent_thread"] != parent_thread
                            or any(returned[k] != data[k] for k in keys)):
                        raise ValueError("review return must match parent, review and basis")
                else:
                    result_keys = ("wrapper_exit", "wrapper_reason", "wrapper_out_ref", "verifier_report_ref")
                    if old is None or old["state"] not in ("received", "adopted", "rejected"):
                        raise ValueError("record a verified receipt before deciding the review")
                    old = dict(old, wrapper_reason=normalize_wrapper_reason(old.get("wrapper_reason")))
                    if any(old[key] != data[key] for key in result_keys):
                        raise ValueError("review decision must use the received result")
                    reference(data["decision_ref"])
            if data["state"] == "held":
                required(data, ("next_action",))
        else:
            required(data, ("change", "targets"))
            targets = string_list(data, "targets")
            for ident in targets:
                member(ident)
            change = next((c for c in previous["changes"] if c["change"] == data["change"]), None)
            if event == "stop-request":
                required(data, ("topic", "owner", "scope_ref", "reason"))
                if data["owner"] != data["assignment"]:
                    raise ValueError("stop request must identify its owner")
                reference(data["scope_ref"])
                if change and (change["owner"] != data["owner"] or not set(change["targets"]) <= set(targets)):
                    raise ValueError("preserve stop owner and targets")
                if change and change["permissions"] and (
                        set(targets) != set(change["targets"]) or data["scope_ref"] != change["scope_ref"]
                        or data["topic"] != change["topic"]):
                    raise ValueError("changed targets or scope after permission require a new change")
                for sent in data["sent_refs"]:
                    if sent["assignment"] not in targets:
                        raise ValueError("unknown sent target")
                    reference(sent["ref"])
            else:
                if change is None or not set(targets) <= set(change["targets"]):
                    raise ValueError("unknown change/targets")
                if not parent and targets != [data["assignment"]]:
                    raise ValueError("worker reports only its own stop/resume")
                if event == "stop-received":
                    reference(data["received_ref"])
                elif event == "stop-confirm":
                    required(data, ("position", "execution_ref"))
                    if type(data["incomplete"]) is not bool:
                        raise ValueError("incomplete must be boolean")
                    string_list(data, "touched_refs")
                    reference(data["execution_ref"])
                elif event == "resume-permitted":
                    stopped = set(change["confirmed"])
                    # A permitted resumption does not invalidate the other targets' stops.
                    accounted = stopped | set(change["resumed"])
                    if (not set(change["targets"]) <= accounted or not set(targets) <= stopped
                            or previous["status"] != "recorded" or data["work"] != "parent-wait"):
                        raise ValueError("confirm all stops before permission")
                    for key in ("premises_ref", "scope_ref", "decision_ref", "recheck_ref"):
                        reference(data[key])
                    if any(p["ref"] == data["ref"] for c in previous["changes"] for p in c["permissions"]):
                        raise ValueError("permission requires a distinct reference")
                elif event == "work-resumed":
                    required(data, ("position", "permission_ref"))
                    if ((data["execution"], data["work"]) != ("running", "working") or
                            not any(p["ref"] == data["permission_ref"] and set(targets) <= set(p["targets"])
                                    for p in change["permissions"])):
                        raise ValueError("resume must match permission")
                    if any(waiting_for_permission(other, ident)
                           for other in previous["changes"] for ident in targets):
                        raise ValueError("another change still requires permission")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError(f"invalid-coordination: {error}") from error


def validate_decision(data):
    if (data["classification"] not in ("detail", "requirements-scope", "purpose-policy", "unresolved")
            or data["disposition"] not in ("effective", "withdrawn", "held")):
        raise ValueError("invalid decision classification/disposition")
    string_list(data, "diff_refs")
    if data.get("decision_ref") is not None:
        reference(data["decision_ref"])
    elif data["classification"] != "detail":
        raise ValueError("decision reference required")


def worker_prepare(state, args):
    """Read-only preparation; the parent performs and records native operations."""
    code = "invalid-request"
    try:
        request = read_json(Path(args.file))
        required(request, ("mode", "request_ref", "stop_remaining_percent", "stop_ref"))
        mode = request["mode"]
        if mode not in ("new", "resume", "replace"):
            raise ValueError("mode must be new/resume/replace")
        purpose = request.get("purpose", "work")
        if purpose not in ("work", "consultation"):
            raise ValueError("purpose must be work/consultation")
        stop = request["stop_remaining_percent"]
        if isinstance(stop, bool) or not isinstance(stop, (int, float)) or not 0 <= stop <= 100:
            raise ValueError("stop_remaining_percent must be between 0 and 100")
        if not isinstance(request.get("confirm_reading", False), bool):
            raise ValueError("confirm_reading must be boolean")
        if mode == "new":
            required(request, ("id", "role", "candidate", "stage", "scope", "artifact"))
        else:
            required(request, ("assignment",))
            forbidden = ("role", "stage", "scope", "artifact", "model", "effort")
            if mode == "resume":
                forbidden += ("id", "candidate")
            if any(key in request for key in forbidden):
                raise ValueError("saved assignment fields cannot be overridden")
            if mode == "replace":
                required(request, ("id", "candidate", "reason", "old_execution_ref", "handoff_ref"))
                if request["reason"] not in REPLACEMENT_REASONS:
                    raise ValueError("invalid replacement reason")
        code = "invalid-reference"
        request_ref = reference(request["request_ref"])
        stop_ref = reference(request["stop_ref"])
        if mode == "replace":
            reference(request["old_execution_ref"])
            reference(request["handoff_ref"])
        code = "record-error"
        project = read_json(state / "project.json")
        if project["version"] != VERSION:
            raise ValueError("unsupported record version")
        coordination_view = observe(state, project)["coordination"]
        related = dict(status=coordination_view["status"], topics=[], changes=[], waiting_for_permission=False)
        if coordination_view["status"] != "recorded" and (
                coordination_view["reason"] != "settings-unreadable" or purpose == "consultation"):
            return dict(version=VERSION, status="deferred", reason="coordination-unconfirmed", usage=None,
                        coordination=related)
        rows = assignments(state)
        history = [json.loads(line) for line in (state / "events.jsonl").read_text().splitlines() if line.strip()]
        replaced = {row["replaces"] for row in rows if row["replaces"]}
        code = "invalid-request"
        if mode != "resume" and any(row["id"] == request["id"] for row in rows):
            raise ValueError("assignment id already exists")
        old = None
        if mode != "new":
            code = "unknown-assignment"
            old = next((row for row in rows if row["id"] == request["assignment"] and row["id"] not in replaced), None)
            if old is None:
                raise ValueError("current assignment required")
            previous = next((e for e in reversed(history) if e["worker"] == old["worker"]), {})
            execution = previous.get("execution", "unknown")
            if execution != "ended":
                return dict(version=VERSION, status="deferred", usage=None,
                            coordination=related,
                            reason="already-running" if execution == "running" else "execution-unconfirmed")
        if mode == "new":
            assignment = {key: request[key] for key in ("id", "stage", "scope", "artifact", "role", "candidate")}
        else:
            assignment = {key: old[key] for key in ("id", "stage", "scope", "artifact", "role", "candidate", "model", "effort")}
            if mode == "replace":
                assignment.update(id=request["id"], candidate=request["candidate"],
                                  replaces=old["id"], handoff_ref=request["handoff_ref"])
        role = assignment["role"]
        code = "invalid-request"
        if not isinstance(role, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", role):
            raise ValueError("invalid role name")
        ident = old["id"] if old else assignment["id"]
        related["topics"] = [t["topic"] for t in coordination_view["topics"] if ident in t["participants"]]
        relevant_changes = [c for c in coordination_view["changes"] if ident in c["targets"] or ident == c["owner"]]
        related["changes"] = [c["change"] for c in relevant_changes]
        if coordination_view["status"] != "recorded" and relevant_changes:
            return dict(version=VERSION, status="deferred", reason="coordination-unconfirmed", usage=None,
                        coordination=related)
        waiting = any(waiting_for_permission(c, ident) for c in relevant_changes)
        related["waiting_for_permission"] = waiting
        owner_waiting = any(ident == c["owner"] and c["pending_targets"] and not c["permissions"]
                            for c in relevant_changes)
        if (waiting or owner_waiting) and purpose == "work":
            return dict(version=VERSION, status="deferred", reason="resume-not-permitted", usage=None,
                        coordination=related)
        # Reuse the existing candidate resolver and Usage presentation, including resets.
        code = "candidate-unresolved"
        spec = importlib.util.spec_from_file_location("team_candidates", lookup("team.role-candidates"))
        candidates = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(candidates)
        sys.path.insert(0, str(ROOT / "team/executor"))
        import profile_resolve
        profile = candidates._profile_path(None)
        # Candidate resolution uses Claude's directory; Codex TOMLs are checked below.
        agents = candidates._agents_dir(None)
        selected, error = candidates.resolve_candidate(profile, agents, role, assignment["candidate"])
        if mode == "resume" and (error or any(selected[key] != old[key] for key in ("model", "effort"))
                                  or selected["route"] != "external-cli"):
            return dict(version=VERSION, status="deferred", reason="resume-unavailable", usage=None,
                        coordination=related)
        if error:
            raise ValueError(error)
        if selected["route"] != "external-cli":
            raise ValueError("wrong-route: Codex external-cli candidate required")
        if not selected["model"] or selected["model"] == "default" or not selected["effort"]:
            raise ValueError("explicit model and effort required")
        assignment.update(model=selected["model"], effort=selected["effort"])
        sources = [str(Path(profile).absolute()), str(Path(profile_resolve.model_defs_path()).absolute())]
        role_definition = None
        if mode != "resume":
            code = "invalid-role-definition"
            role_definition = Path(project["cwd"]) / CODEX_AGENTS_DIR / (role + ".toml")
            if not role_definition.exists():
                role_definition = Path.home() / CODEX_AGENTS_DIR / (role + ".toml")
            definition = tomllib.loads(role_definition.read_text())
            notes = ("absolute-rules", "core-worker", "worker-role-" + role)
            if (set(definition) != {"name", "description", "developer_instructions"}
                    or definition["name"] != role
                    or not isinstance(definition["description"], str) or not definition["description"].strip()
                    or not isinstance(definition["developer_instructions"], str)
                    or not all(note + ".md" in definition["developer_instructions"] for note in notes)):
                raise ValueError("reference-only role definition required")
        code = "candidate-unresolved"
        usage = dict(candidates._usage_details(candidates._run_usage_snapshot(), selected["route"]),
                     checked_at=now(), stop_remaining_percent=stop,
                     stop_ref=str(stop_ref), candidate=assignment["candidate"])
        applicable = [usage[key] for key, window in (("h5", "five_hour"), ("d7", "seven_day"))
                      if window not in usage["not_applicable_windows"]]
        reason = ("quota-exhausted" if 0 in applicable else
                  "usage-unavailable" if None in applicable else
                  "stop-point" if usage["h5"] is not None and usage["h5"] <= stop else None)
        if reason:
            return dict(version=VERSION, status="deferred", reason=reason, usage=usage, coordination=related)
        confirmed = mode == "resume" and any(e.get("assignment") == old["id"] and
                    e["event"] == "worker-ready" for e in history)
        phase = "task" if confirmed and not request.get("confirm_reading", False) else "read-confirmation"
        if phase == "task" and purpose == "consultation":
            phase = "consultation"
        prefs = Path(os.environ.get("AIENV_PREFERENCES_DIR", "~/Data/obsidian/Preferences")).expanduser()
        code = "invalid-reference"
        notes = [reference(str(prefs / (name + ".md"))) for name in
                 ("absolute-rules", "core-worker", "worker-role-" + role)]
        message = (f"職種: {role}\n必読（着手前に全文読み、従う）: " + " → ".join(map(str, notes)) +
                   f"\n担当表: {state / 'assignments.tsv'}\n依頼（背景・目的・向き・範囲・受入条件・成果と報告先・禁止事項）: {request_ref}\n")
        if mode == "replace":
            message += f"旧担当と引き継ぎ: {old['id']} / {request['handoff_ref']}\n"
        if phase == "read-confirmation":
            message += "全文読了後、職種・読んだ必読文書名・やらないことの受け取り確認だけを返す。制作は始めない。\n"
        elif phase == "consultation":
            message += "依頼された確認・議論・報告だけを行う。制作・修正を始めない。\n"
        else:
            message += "依頼に従って担当範囲を進める。停止中・親の再開許可待ちは引き継ぎ、許可前に再開しない。本文が不足すれば作業前に必読を読み直す。\n"
        message += (f"状態記録: {state / 'events.jsonl'}\n共通設定: {coordination_view['settings']['ref']}\n"
                    f"論点: {', '.join(related['topics'])}\n変更: {', '.join(related['changes'])}\n")
        if waiting:
            message += "停止中・親の再開許可待ち。確認・議論・停止位置の報告だけ。制作・修正を始めない。\n"
        return dict(version=VERSION, status="ready", mode=mode, assignment=assignment,
                    coordination=related,
                    usage=usage, selection_sources=sources,
                    role_definition_source=str(role_definition) if role_definition else None,
                    operation="followup" if mode == "resume" else "spawn",
                    target=old["address"] if mode == "resume" else None, agent_type=role,
                    model=assignment["model"], reasoning_effort=assignment["effort"],
                    fork_turns="none", phase=phase, message=message)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if str(error).startswith(("invalid-reference:", "wrong-route:")):
            raise ValueError(str(error)) from error
        raise ValueError(f"{code}: {error}") from error


def current_thread(run):
    events = Path(run["out"] + ".events.jsonl")
    if events.exists():
        with events.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue  # The current line may still be being written.
                if event.get("type") == "thread.started":
                    return event.get("thread_id") or run.get("thread_id", "")
    return run.get("thread_id", "")


def effective_parent_thread(state, project, run=None):
    """Resolve first-run thread.started evidence before the persisted project ID."""
    if project.get("run"):
        run = run if run is not None else read_json(state / "runs" / project["run"] / "run.json")
        return current_thread(run) or project.get("thread_id", "")
    return project.get("thread_id", "")


def process_start(pid):
    return subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                          env=dict(os.environ, LC_ALL="C"), capture_output=True, text=True).stdout.strip()


def process_start_key(value):
    # New records use C locale; retain the Japanese ps format used by older records.
    value = " ".join(value.split())
    english = re.fullmatch(r"\S+ ([A-Z][a-z]{2}) (\d+) (\d{2}:\d{2}:\d{2}) (\d{4})", value)
    japanese = re.fullmatch(r"[日月火水木金土] (\d+)/\s*(\d+) (\d{2}:\d{2}:\d{2}) (\d{4})", value)
    if english:
        month, day, clock, year = english.groups()
        months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
        if month not in months:
            return value
        month = months.index(month) + 1
    elif japanese:
        month, day, clock, year = japanese.groups()
    else:
        return value  # Unknown representations must still match, never just the PID.
    return int(year), int(month), int(day), clock


def alive(pid, started):
    if not pid or not started:
        return False
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="],
                            env=dict(os.environ, LC_ALL="C"), capture_output=True, text=True)
    fields = result.stdout.strip().split(maxsplit=1)
    return (result.returncode == 0 and len(fields) == 2
            and not fields[0].startswith("Z") and process_start_key(fields[1]) == process_start_key(started))


def observe(state, project, *, latest=None, rows=None):
    # Overview can retain readable parent evidence when a child record is damaged.
    latest = read_json(state / "latest.json") if latest is None else latest
    rows = assignments(state) if rows is None else rows
    replaced = {row["replaces"] for row in rows if row["replaces"]}
    result = {"version": VERSION, "project": project["project"], "status": "not-started",
              "workspace": project["workspace"], "surface": project["surface"],
              "assignments": rows, "current_assignment_ids": [row["id"] for row in rows if row["id"] not in replaced],
              "last_recorded": latest["workers"],
              "worker_records_status": "last-recorded", "thread_id": project.get("thread_id", "")}
    if not project.get("run"):
        result["coordination"] = coordination(state)
        return result
    run_dir = state / "runs" / project["run"]
    run = read_json(run_dir / "run.json")
    processes = [(run.get(name + "_pid"), run.get(name + "_started")) for name in ("runner", "wrapper")]
    for name in ("runner", "codex"):
        pid_file = run_dir / (name + ".pid")
        if pid_file.exists():
            lines = pid_file.read_text().splitlines()
            if lines:
                processes.append((int(lines[0]), lines[1].strip() if len(lines) > 1 else ""))
    log = run_dir / "wrapper.log"
    text = log.read_text(encoding="utf-8") if log.exists() else ""
    codes = re.findall(r"^EXIT:(-?\d+)$", text, re.MULTILINE)
    code = int(codes[-1]) if codes else None
    running = any(alive(pid, started) for pid, started in processes)
    report_file = run_dir / "report.json"
    report = read_json(report_file) if report_file.exists() else None
    out = Path(run["out"])
    complete = code == 0 and out.is_file() and out.stat().st_size > 0 and report is not None
    status = "running" if running else ("finished" if complete else "unconfirmed")
    if run["mode"] == "recover" and not project.get("recovery_complete") and not running:
        status = "unconfirmed"
    result.update(status=status, run=project["run"], mode=run["mode"], pids=[pid for pid, _ in processes],
                  exit=code, out=str(out), log=str(log), report=report,
                  events=run["out"] + ".events.jsonl",
                  thread_id=effective_parent_thread(state, project, run), recovery_attempted=project["recovery_attempted"],
                  notification=(report or {}).get("notification", run.get("notification", "unknown")))
    # Never convert a parent's EXIT into a child's stopped/completed state.
    if status == "unconfirmed" or (run["mode"] == "recover" and not project.get("recovery_complete")):
        result["worker_records_status"] = "unconfirmed"
    result["coordination"] = coordination(state, result["worker_records_status"] == "unconfirmed")
    return result


def launch(state, project, args):
    status = observe(state, project)
    if status["status"] == "running":
        raise ValueError("the old execution is still running; defer requests until its report boundary")
    if args.command == "start" and project.get("run"):
        raise ValueError("already started; use resume with the saved conversation")
    if args.command != "start":
        if not status.get("thread_id"):
            raise ValueError("no saved conversation to resume")
        if args.command == "recover":
            if status["status"] != "unconfirmed" or project["recovery_attempted"]:
                raise ValueError("recovery is allowed once, only for an unconfirmed execution")
        elif status["status"] != "finished":
            raise ValueError("unconfirmed execution; recovery is required before new work")
    usage = Path(args.usage_ref).resolve()
    if not usage.is_file() or not usage.read_text(encoding="utf-8").strip():
        raise ValueError("supply the Mac leader's current usage check (including stop-point judgement)")
    prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    if not prompt.strip():
        raise ValueError("empty prompt")
    check_display(project["project"], project["workspace"], project["surface"])
    run_id = str(project.get("sequence", 0) + 1)
    run_dir = state / "runs" / run_id
    run_dir.mkdir(parents=True)
    report_command = shlex.join([sys.executable, str(Path(__file__).resolve()), "report",
                                 "--state-dir", str(state), "--file", "<report.json>"])
    intro = (f"案件ノートを最初に読む: {project['note']}\n"
             f"目的・ゴール: {project['goal']}\n本人指定の参照: {project['source']}\n"
             f"担当表: {state / 'assignments.tsv'}\n状態履歴: {state / 'events.jsonl'}\n"
             f"報告を終える前に要約・判断待ち・終了理由・読了文書・書いたノート一覧を保存する。\n"
             f"保存・📣通知コマンド（プレースホルダーを実ファイルに置換）: {report_command}\n"
             "この report コマンドが親による既存の口への通知を兼ねる。在席・離席を問わず報告終了前に実行し、"
             "同じ報告で通知口を別途呼ばない。\n")
    if args.command == "start":
        intro += "初回は作業一覧・見積り・停止点・体制の報告まで。本人承認前の実作業・ワーカー起動には進まない。\n"
    if args.command == "recover":
        intro += ("復旧確認のみ。新しい制作は始めない。担当表の全員の実行有無・停止位置・差分・書きかけを確認し、"
                  "明示記録を復旧する。確認不能なら停止済みとせず報告する。確認が揃ったら親が"
                  "recovery-complete イベントを記録する。\n")
        project["recovery_attempted"] = True
        project["recovery_complete"] = False
    (run_dir / "prompt.md").write_text(intro + "\n" + prompt, encoding="utf-8")
    run = {"version": VERSION, "mode": args.command, "started_at": now(),
           "thread_id": status.get("thread_id", ""), "usage_ref": str(usage),
           "out": str(run_dir / "final.md"), "notification": "unknown"}
    save(run_dir / "run.json", run)
    project.update(run=run_id, sequence=int(run_id), thread_id=run["thread_id"])
    save(state / "project.json", project)
    # nohup + a separate session: closing the viewer or launching shell cannot end the parent.
    with (run_dir / "runner.log").open("a", encoding="utf-8") as log:
        child = subprocess.Popen(["nohup", sys.executable, str(Path(__file__).resolve()),
                                  "_run", "--state-dir", str(state), "--run-id", run_id],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    (run_dir / "runner.pid").write_text(f"{child.pid}\n{process_start(child.pid)}\n", encoding="utf-8")
    return {"run": run_id, "runner_pid": child.pid, "state_dir": str(state)}


def run_parent(state, project, run_id):
    directory = state / "runs" / run_id
    run = read_json(directory / "run.json")
    run["runner_pid"] = os.getpid()
    run["runner_started"] = process_start(os.getpid())
    save(directory / "run.json", run)
    command = ["bash", str(HERE / "codex-exec.sh"), "--project-leader", "--cwd", project["cwd"],
               "--sandbox", project["sandbox"], "--out", run["out"], "--prompt-file", str(directory / "prompt.md"),
               "--model", project["model"], "--effort", project["effort"], "--pid-file", str(directory / "codex.pid")]
    if run["thread_id"]:
        command.extend(["--resume", run["thread_id"]])
    with (directory / "wrapper.log").open("w", encoding="utf-8") as log:
        environment = dict(os.environ, CMUX_WORKSPACE_ID=project["workspace"], CMUX_SURFACE_ID=project["surface"])
        wrapper = subprocess.Popen(command, stdout=log, stderr=log, env=environment)
        run["wrapper_pid"] = wrapper.pid
        run["wrapper_started"] = process_start(wrapper.pid)
        save(directory / "run.json", run)
        code = wrapper.wait()
    run.update(ended_at=now(), thread_id=current_thread(run), exit=code)
    # The parent may have added an explicit recovery-complete event while running.
    project = read_json(state / "project.json")
    project["thread_id"] = run["thread_id"]
    save(state / "project.json", project)
    report_file = directory / "report.json"
    report = read_json(report_file) if report_file.exists() else {}
    # The parent already notified through report before exiting. Only retain its outcome.
    run["notification"] = report.get("notification", "unknown")
    save(directory / "run.json", run)


def string_list(data, key):
    value = data[key]
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise ValueError(f"array of nonempty strings required: {key}")
    return value


def validate_worker_event(state, data):
    """Validate stage 2 additions before appending to the existing version 1 files."""
    rows = {row["id"]: row for row in assignments(state)}
    event = data["event"]
    if "assignment" not in data:
        raise ValueError("required field: assignment")
    planned = event == "worker-slot-wait" and data["assignment"] is None
    if planned:
        required(data, ("planned_id", "request_ref"))
        if (data["worker"], data["execution"], data["work"]) != ("parent", "running", "slot-wait"):
            raise ValueError("unstarted slot wait must be recorded by parent")
        if data["planned_id"] in rows:
            raise ValueError("planned id already registered")
        reference(data["request_ref"])
    else:
        row = rows.get(data["assignment"])
        if row is None or row["worker"] != data["worker"]:
            raise ValueError("assignment/worker mismatch")
    reference(data["ref"])
    if event == "worker-slot-wait":
        required(data, ("queue_class", "queue_order", "blocked_by"))
        if (data["queue_class"] not in ("consultation", "production")
                or type(data["queue_order"]) is not int or data["queue_order"] <= 0
                or any(ident not in rows for ident in string_list(data, "blocked_by"))):
            raise ValueError("invalid queue class/order/dependencies")
        if not planned and (data["execution"] not in ("ended", "unknown") or data["work"] != "slot-wait"):
            raise ValueError("invalid worker slot wait state")
    elif event == "worker-unavailable":
        required(data, ("reason",))
        if (data["reason"] not in REPLACEMENT_REASONS + ("stop-point", "usage-unavailable", "operation-failed")
                or data["execution"] not in ("ended", "unknown")
                or data["work"] not in ("parent-wait", "unrecoverable", "unconfirmed")):
            raise ValueError("invalid unavailable reason/state")
    elif event == "worker-started":
        required(data, ("prepare_ref", "selection"))
        prepared = read_json(reference(data["prepare_ref"]))
        selection = data["selection"]
        required(selection, ("candidate", "model", "effort", "usage", "selection_sources"))
        allowed_work = ("consulting",) if prepared.get("phase") == "consultation" else ("parent-wait", "working")
        if (data["execution"] != "running" or data["work"] not in allowed_work
                or prepared.get("status") != "ready"
                or prepared["assignment"]["id"] != row["id"]
                or Path(row["selection_ref"]).resolve() != state / "events.jsonl"
                or any(selection[key] != prepared[key] for key in ("usage", "selection_sources"))
                or any(selection[key] != row[key] or selection[key] != prepared["assignment"][key]
                       for key in ("candidate", "model", "effort"))):
            raise ValueError("started selection must match preparation and assignment")
    else:
        expected_work = "done" if event == "worker-done" else "parent-wait"
        if (data["execution"], data["work"]) != ("ended", expected_work):
            raise ValueError("invalid worker result state")
        if event == "worker-ready":
            required(data, ("role", "read_notes", "prohibitions"))
            notes = {Path(note).stem for note in string_list(data, "read_notes")}
            if (data["role"] != row["role"] or not string_list(data, "prohibitions")
                    or not {"absolute-rules", "core-worker", "worker-role-" + row["role"]} <= notes):
                raise ValueError("role, all three read notes and prohibitions required")
        elif event == "worker-finished":
            required(data, ("report_ref", "artifact_refs", "prepare_ref"))
            reference(data["report_ref"])
            reference(data["prepare_ref"])
            for value in string_list(data, "artifact_refs"):
                if not Path(value).expanduser().exists():
                    raise ValueError(f"artifact missing: {value}")
        else:
            required(data, ("handoff_ref",))
            reference(data["handoff_ref"])


def record(state, project, args):
    data = read_json(Path(args.file))
    if args.command == "assign":
        required(data, ASSIGN_COLUMNS[1:13])
        rows = assignments(state)
        if any(row["id"] == data["id"] for row in rows):
            raise ValueError("assignment id already exists; append a new id and replaces link")
        if data.get("replaces") and data["replaces"] not in {row["id"] for row in rows}:
            raise ValueError("unknown replaced assignment")
        if any(not isinstance(value, (str, int)) or any(c in str(value) for c in "\t\r\n")
               for value in data.values()):
            raise ValueError("assignment values must be single-line TSV fields")
        if Path(data["selection_ref"]).resolve() == state / "events.jsonl":
            if data["parent_thread"] != effective_parent_thread(state, project):
                raise ValueError("assignment must belong to the saved parent conversation")
            if any(row["worker"] == data["worker"] or row["address"] == data["address"] for row in rows):
                raise ValueError("new assignments require a distinct worker and address; resume keeps its row")
            if data.get("replaces"):
                old = next(row for row in rows if row["id"] == data["replaces"])
                latest = read_json(state / "latest.json")["workers"].get(old["worker"], {})
                if (any(row["replaces"] == old["id"] for row in rows) or old["role"] != data["role"]
                        or latest.get("execution") != "ended"):
                    raise ValueError("replacement requires current same-role assignment and ended execution")
                reference(data.get("handoff_ref"))
        data.update(version=VERSION, state_ref=str(state / "events.jsonl"))
        with (state / "assignments.tsv").open("a", encoding="utf-8", newline="") as stream:
            csv.DictWriter(stream, fieldnames=ASSIGN_COLUMNS, delimiter="\t").writerow(data)
    elif args.command == "report":
        required(data, ("summary", "pending", "reason", "read_notes", "written_notes"))
        for key in ("pending", "read_notes", "written_notes"):
            if not isinstance(data[key], list):
                raise ValueError(f"array required: {key}")
        if "claude_review" in data:
            try:
                validate_review(data["claude_review"])
                review = data["claude_review"]
                collected = any(r["review"] == review["review"] and r["basis_ref"] == review["basis_ref"]
                                and r["state"] in ("received", "adopted", "rejected")
                                for r in coordination(state)["reviews"])
                if review["required"] and not collected and review["review"] not in data["pending"]:
                    raise ValueError("required review must remain pending until collected")
            except (OSError, ValueError, KeyError, TypeError) as error:
                raise ValueError(f"invalid-coordination: {error}") from error
        if "worker_refs" in data:
            ids = {row["id"] for row in assignments(state)}
            if any(ident not in ids for ident in string_list(data, "worker_refs")):
                raise ValueError("unknown worker_refs assignment")
        directory = state / "runs" / project["run"]
        report_file = directory / "report.json"
        previous = read_json(report_file) if report_file.exists() else {}
        data.update(version=VERSION, recorded_at=now(), notification_attempted=True,
                    notification=previous.get("notification", "unknown"))
        # Save summary/decision waits before the parent's single notification attempt.
        save(report_file, data)
        if not previous.get("notification_attempted"):
            run = read_json(directory / "run.json")
            try:
                result = subprocess.run([lookup("notify.send"), "call", "ask", f"📣 {project['project']}",
                                         f"{data['reason']}\n報告先: {run['out']}"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                data["notification"] = "sent" if result.returncode == 0 else "unknown"
            except (OSError, ValueError):
                data["notification"] = "unknown"
            save(report_file, data)
    else:
        required(data, ("actor", "event", "worker", "execution", "work", "ref"))
        if data["actor"] != "parent":
            raise ValueError("the parent records operation results and worker notifications")
        if data["execution"] not in ("running", "ended", "unknown") or data["work"] not in WORK_STATES:
            raise ValueError("invalid execution/work state")
        if data["event"] in WORKER_EVENTS:
            validate_worker_event(state, data)
        if structured_event(data):
            validate_coordination(state, project, data)
        if data["event"] == "consult":
            required(data, ("peer",))
        if data["event"] in ("stop-request", "stop-confirm", "resume-permitted"):
            required(data, ("targets",))
        if data["event"] == "recovery-complete":
            if (not project["recovery_attempted"] or data["worker"] != "parent"
                    or read_json(state / "runs" / project["run"] / "run.json")["mode"] != "recover"):
                raise ValueError("recovery-complete requires a recovery run and the parent")
        data.update(version=VERSION, recorded_at=now(), run=project.get("run"))
        with (state / "events.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(data, ensure_ascii=False) + "\n")
        latest = read_json(state / "latest.json")
        latest["workers"][data["worker"]] = data
        save(state / "latest.json", latest)
        if data["event"] == "recovery-complete":
            project["recovery_complete"] = True
            save(state / "project.json", project)
    return data


def init(state, args):
    if (state / "project.json").exists():
        raise ValueError("project already registered")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.project) or args.project in (".", ".."):
        raise ValueError("invalid project slug")
    project_dir = Path(args.project_dir).resolve()
    if not all((project_dir / part).is_dir() for part in ("docs", "work", "output")):
        raise ValueError("prepare the project docs/work/output directories first")
    note = Path(args.note).resolve()
    if not note.is_file() or note.stem != args.project:
        raise ValueError("prepare the matching Projects note first")
    if not Path(args.cwd).is_dir():
        raise ValueError("cwd is not a directory")
    check_display(args.project, args.workspace, args.surface)
    state.mkdir(parents=True, exist_ok=True)
    project = {"version": VERSION, "project": args.project, "project_dir": str(project_dir),
               "cwd": str(Path(args.cwd).resolve()), "note": str(note), "goal": args.goal,
               "source": args.source, "workspace": args.workspace, "surface": args.surface,
               "candidate": args.candidate, "model": args.model, "effort": args.effort,
               "selection_ref": args.selection_ref, "sandbox": args.sandbox,
               "created_at": now(), "recovery_attempted": False, "recovery_complete": False}
    with (state / "assignments.tsv").open("w", encoding="utf-8", newline="") as stream:
        csv.writer(stream, delimiter="\t").writerow(ASSIGN_COLUMNS)
    (state / "events.jsonl").touch()
    save(state / "latest.json", {"version": VERSION, "workers": {}})
    save(state / "project.json", project)
    return project


def view(state, args):
    while True:
        if args.watch:
            print("\033[2J\033[H", end="")
        if not (state / "project.json").exists():
            print("準備中 / preparing")
        else:
            status = observe(state, read_json(state / "project.json"))
            print(f"{status['project']} — {status['status']}\n会話: {status['thread_id']}")
            print("子の状態: 最新の明示記録を参照" if status["worker_records_status"] == "last-recorded" else
                  "子の現在状態は未確認。保存記録は最終記録としてのみ参照。")
            if status.get("report"):
                print(json.dumps(status["report"], ensure_ascii=False, indent=2))
            coordination_view = status["coordination"]
            print(f"連携: {coordination_view['status']} / {coordination_view['reason'] or '-'}")
            for topic in coordination_view["topics"]:
                print(f"論点 {topic['topic']}: {topic['rounds']}/{topic['limit']} {topic['phase']} — {topic['next_action']}")
            for change in coordination_view["changes"]:
                print(f"変更 {change['change']}: {change['phase']} 停止待ち={','.join(change['pending_targets'])}")
            for key in ("events", "log", "out"):
                if key not in status:
                    continue
                path = Path(status[key])
                if path.is_file():
                    print(f"\n--- {key}: {path} ---")
                    with path.open(encoding="utf-8") as stream:
                        print("".join(deque(stream, maxlen=args.lines)), end="")
        sys.stdout.flush()
        if not args.watch:
            return
        time.sleep(args.interval)


def overview_time():
    return now().replace("+00:00", "Z")


def overview_issue(result, code, ref, message):
    result["issues"].append(dict(code=code, ref=str(ref) if ref is not None else None, message=str(message)))


def overview_note(path, result):
    # Use the Dock's frontmatter/Tasks reader, without its filtering or health frame.
    try:
        fields = subprocess.run([lookup("dock.next-model"), "--read-note", str(path)],
                                capture_output=True, text=True, check=True).stdout.split("\0")
        project, status, next_action = fields[:3]
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result["connection"] = "unconfirmed"
        overview_issue(result, "record-error", path, error)
        return None
    if not project:
        return "not-project"
    result.update(project_status=status or None, next=next_action or None)
    if project and project != result["project"]:
        overview_issue(result, "reference-mismatch", path, "frontmatter project differs from note slug")
        result["connection"] = "unconfirmed"
        return None
    section, references = False, []
    for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^#{1,2}\s", line):
            section = bool(re.fullmatch(r"##[ \t]+正本の所在[ \t]*", line))
        elif section and re.match(r"^[ \t]*-[ \t]*状態記録", line):
            references.append(line)
    if len(references) != 1:
        raise ValueError("exactly one 状態記録 reference required in 正本の所在")
    line = references[0]
    if line == "- 状態記録: 従来経路":
        return "legacy"
    match = re.fullmatch(r"- 状態記録: (準備中|三段) \[state\]\(<([^<>\r\n]+)>\)", line)
    if not match:
        raise ValueError("invalid 状態記録 reference")
    raw = match[2]
    if (re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", raw) or "$" in raw or "`" in raw
            or raw.startswith("~") and not raw.startswith("~/")):
        raise ValueError("local literal state path required")
    state = Path(raw).expanduser()
    result["state_dir"] = os.path.abspath(path.parent / state)
    return match[1]


def overview_rows(state, result):
    rows, complete = [], True
    try:
        with (state / "assignments.tsv").open(encoding="utf-8", newline="") as stream:
            reader = csv.DictReader(stream, delimiter="\t")
            if reader.fieldnames != ASSIGN_COLUMNS:
                raise ValueError("invalid assignment columns")
            for row in reader:
                if (None in row or None in row.values() or any(row.get(key) in (None, "") for key in
                                       ("id", "worker", "address", "parent_thread"))
                        or row["version"] != str(VERSION) or any(row["id"] == r["id"] for r in rows)):
                    complete = False
                else:
                    rows.append(row)
        ids = {row["id"] for row in rows}
        if any(row["replaces"] and row["replaces"] not in ids for row in rows):
            complete = False
        if not complete:
            raise ValueError("incomplete assignment rows or replacement relation")
    except (OSError, ValueError, csv.Error) as error:
        complete = False
        overview_issue(result, "record-error", state / "assignments.tsv", error)
    return rows, complete


def overview_project(result, route, shared=False):
    if route is None:
        return result
    if route == "legacy":
        result["connection"] = "legacy"
        result["parent"]["status"] = "not-applicable"
        overview_issue(result, "legacy", result["note"], "explicit legacy route; native worker counts unknown")
        return result
    state = Path(result["state_dir"])
    if shared:
        result["connection"] = "unconfirmed"
        overview_issue(result, "reference-mismatch", state, "state directory shared by different projects")
        return result
    try:
        empty = not state.exists() or (state.is_dir() and not any(state.iterdir()))
        if route == "準備中" and empty:
            result.update(connection="preparing", working_complete=True)
            result["parent"]["status"] = "not-started"
            result["counts"] = {key: dict(known=0, exact=0) for key in result["counts"]}
            return result
    except OSError as error:
        overview_issue(result, "record-error", state, error)
    result["connection"] = "connected"
    project = None
    try:
        project = read_json(state / "project.json")
        if project["version"] != VERSION or project["project"] != result["project"]:
            overview_issue(result, "reference-mismatch", state / "project.json", "project or version mismatch")
            result["connection"] = "unconfirmed"
            return result
    except (OSError, ValueError, KeyError, TypeError) as error:
        project = None
        overview_issue(result, "record-error", state / "project.json", error)
        result["connection"] = "unconfirmed"
    rows, complete = overview_rows(state, result)
    if not complete:
        result["connection"] = "unconfirmed"
    latest = dict(workers={})
    try:
        latest = read_json(state / "latest.json")
        if latest["version"] != VERSION or not isinstance(latest["workers"], dict):
            raise ValueError("invalid latest worker records")
    except (OSError, ValueError, KeyError, TypeError) as error:
        latest = dict(workers={})
        result["connection"] = "unconfirmed"
        overview_issue(result, "record-error", state / "latest.json", error)
    observation = None
    if project is not None:
        try:
            observation = observe(state, project, latest=latest, rows=rows)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            result["connection"] = "unconfirmed"
            overview_issue(result, "record-error", state, error)
        parent = result["parent"]
        parent.update(observed_at=overview_time(), thread_id=project.get("thread_id"))
        parent["evidence"] = [str(state / "project.json")]
        if project.get("run"):
            try:
                directory = state / "runs" / project["run"]
                parent["evidence"] += [str(directory / name) for name in ("run.json", "wrapper.log", "report.json")]
                # A corrupt child/run record must not hide an independently readable saved report.
                parent["report"] = read_json(directory / "report.json")
            except (OSError, ValueError, TypeError):
                pass
        if observation:
            parent.update(status="unconfirmed" if observation["worker_records_status"] == "unconfirmed" else observation["status"],
                          thread_id=observation["thread_id"] or None,
                          exit=observation.get("exit"), report=observation.get("report"))
    uncertain = result["parent"]["status"] == "unconfirmed" or (
        observation is not None and observation["worker_records_status"] == "unconfirmed")
    # Explicit history is independent of project registration and parent observation.
    # Retain readable topics/stops/reviews as last records even without project.json.
    result["coordination"] = (observation["coordination"] if observation else
                              coordination(state, unconfirmed=uncertain))
    if uncertain:
        overview_issue(result, "parent-unconfirmed", state, "parent execution unconfirmed; child states are last records")
    replaced = {row["replaces"] for row in rows if row["replaces"]}
    for row in rows:
        event = latest["workers"].get(row["worker"])
        if not isinstance(event, dict):
            event = None
        valid = (event is not None and event.get("execution") in ("running", "ended", "unknown")
                 and event.get("work") in WORK_STATES and event.get("recorded_at") and event.get("ref"))
        confirmed = bool(valid and not uncertain)
        worker = {key: row[key] for key in ("worker", "address", "role", "stage", "scope", "artifact", "parent_thread")}
        worker.update(assignment=row["id"], current=row["id"] not in replaced, replaces=row["replaces"] or None,
                      execution=event["execution"] if confirmed else "unknown",
                      work=event["work"] if confirmed else "unconfirmed",
                      certainty="last-recorded" if confirmed else "unconfirmed",
                      recorded_at=(event or {}).get("recorded_at"), ref=(event or {}).get("ref"), last_recorded=event)
        result["workers"].append(worker)
        if not valid:
            overview_issue(result, "record-error", state / "latest.json", f"missing/invalid worker event: {row['id']}")
        if event and event.get("event") == "consult" and not structured_event(event):
            overview_issue(result, "record-error", event.get("ref"), "unstructured consultation cannot establish a topic")
    current = [worker for worker in result["workers"] if worker["current"]]
    running = sum(worker["execution"] == "running" for worker in current)
    running_complete = complete and not uncertain and all(worker["execution"] != "unknown" for worker in current)
    cumulative = len({(row["parent_thread"], row["address"]) for row in rows})
    result["counts"] = dict(current_started=dict(known=len(current), exact=len(current) if complete else None),
                            running=dict(known=running, exact=running if running_complete else None),
                            cumulative_started=dict(known=cumulative, exact=cumulative if complete else None))
    result["working_workers"] = [worker["assignment"] for worker in current if worker["work"] == "working"]
    result["working_complete"] = complete and not uncertain and all(
        w["certainty"] == "last-recorded" and w["work"] != "unconfirmed" for w in current)
    coordination_view = result["coordination"]
    for topic in sorted(coordination_view["topics"], key=lambda item: item["topic"]):
        consultation = {key: topic.get(key) for key in ("topic", "subject", "participants", "phase", "dependencies",
                                                       "rounds", "recorded_at", "ref", "outcome", "next_action")}
        kind = (topic.get("receipt") or {}).get("kind")
        reception = ("concluded" if topic["phase"] == "concluded" else
                     "unreceived" if topic.get("receipt") is None else
                     "received" if kind == "answering" else kind)
        consultation.update(reception=reception, active=reception not in ("concluded", "redirect"),
                            certainty="last-recorded" if coordination_view["status"] == "recorded" and not uncertain else "unconfirmed")
        result["consultations"].append(consultation)
    if coordination_view["status"] != "recorded":
        overview_issue(result, "record-error", state / "events.jsonl", coordination_view["reason"])
        if coordination_view["reason"] == "record-error":
            result["connection"] = "unconfirmed"
    if route == "準備中" and result["connection"] == "connected":
        overview_issue(result, "preparing-reference", result["note"], "registered state takes precedence over preparing reference")
    result["evidence"] += [str(state / name) for name in ("project.json", "assignments.tsv", "latest.json", "events.jsonl")]
    return result


def overview_snapshot(args):
    directory, declarations = args.projects_dir, args.declarations
    try:
        notes = {path.stem: path for path in directory.iterdir()
                 if path.suffix == ".md" and path.name.lower() != "readme.md" and path.is_file()}
    except OSError as error:
        raise ValueError(f"overview-source-error: {error}") from error
    result = dict(version=VERSION, mode="watch" if args.watch else "once",
                  interval_seconds=args.interval if args.watch else None,
                  sources=dict(projects_dir=str(directory), declarations=str(declarations)),
                  discovery_complete=True, projects=[], totals={}, issues=[])
    workspaces = {}
    try:
        if declarations.exists():
            declared = read_json(declarations)
            if declared["version"] != VERSION or not isinstance(declared["workspaces"], dict):
                raise ValueError("invalid declaration record")
            for workspace, slug in declared["workspaces"].items():
                if not isinstance(slug, str) or not slug or Path(slug).name != slug or slug in (".", ".."):
                    raise ValueError("invalid declared slug")
                workspaces.setdefault(slug, []).append(workspace)
    except (OSError, ValueError, KeyError, TypeError) as error:
        result["discovery_complete"] = False
        overview_issue(result, "declaration-error", declarations, error)
    routes = {}
    for slug in sorted(notes.keys() | workspaces.keys()):
        note = notes.get(slug)
        project = dict(project=slug, note=str(note) if note else None,
                       declared_workspaces=sorted(workspaces.get(slug, [])), state_dir=None,
                       connection="unconnected", project_status=None, next=None,
                       parent=dict(status="unconfirmed", observed_at=None, thread_id=None, exit=None, report=None, evidence=[]),
                       counts={key: dict(known=0, exact=None) for key in ("current_started", "running", "cumulative_started")},
                       workers=[], working_workers=[], working_complete=False, consultations=[],
                       coordination=dict(status="unconfirmed", reason="unconnected", settings=dict(ref=None,
                           consultation_round_limit=None), topics=[], changes=[], reviews=[]),
                       evidence=[str(note)] if note else [], issues=[])
        route = None
        try:
            if note is None:
                raise ValueError("declaration has no Projects note")
            route = overview_note(note, project)
            if route == "not-project":
                if slug not in workspaces:
                    continue
                project.update(note=None, evidence=[])
                route = None
                raise ValueError("declared slug has no project frontmatter in its note")
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            overview_issue(project, "unconnected", note, error)
        routes[slug] = route
        result["projects"].append(project)
    states = [Path(project["state_dir"]).resolve() for project in result["projects"] if project["state_dir"]]
    for project in result["projects"]:
        shared = project["state_dir"] and states.count(Path(project["state_dir"]).resolve()) > 1
        try:
            overview_project(project, routes[project["project"]], shared)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, subprocess.SubprocessError) as error:
            # Malformed individual records must not suppress other projects or claim current work.
            overview_issue(project, "record-error", project["state_dir"], error)
            project["connection"] = "unconfirmed"
            project["parent"]["status"] = "unconfirmed"
            project["counts"]["running"] = dict(known=0, exact=None)
            project.update(working_workers=[], working_complete=False)
            for worker in project["workers"]:
                worker.update(execution="unknown", work="unconfirmed", certainty="unconfirmed")
            for topic in project["consultations"]:
                topic["certainty"] = "unconfirmed"
            project["coordination"].update(status="unconfirmed", reason="record-error")
    result["totals"]["project_count"] = len(result["projects"])
    for key in ("current_started", "running", "cumulative_started"):
        known = sum(project["counts"][key]["known"] for project in result["projects"])
        unknown = [project["project"] for project in result["projects"] if project["counts"][key]["exact"] is None]
        result["totals"][key] = dict(known=known, exact=known if not unknown and result["discovery_complete"] else None,
                                     unknown_projects=unknown)
    result["generated_at"] = overview_time()
    return result


def overview_label(value):
    return {
        "connected": "接続済", "preparing": "準備中", "unconnected": "未接続", "legacy": "従来経路",
        "unconfirmed": "未確認", "not-started": "未起動", "not-applicable": "対象外",
        "running": "実行中", "finished": "正常終了", "ended": "終了", "unknown": "未確認",
        "working": "作業", "consulting": "相談", "consultation-wait": "相談待ち", "slot-wait": "枠待ち",
        "stop-requested": "停止要求中", "stopped": "停止", "parent-wait": "親判断待ち", "user-wait": "本人判断待ち",
        "done": "一旦終了", "replaced": "交代済", "unrecoverable": "再開不能", "last-recorded": "最終記録",
        "unreceived": "未受領", "received": "受領後", "dependency-wait": "依存先待ち", "redirect": "宛先訂正",
        "concluded": "結論済", "waiting": "待ち", "recorded": "記録済", "requested": "依頼済",
        "adopted": "採用", "rejected": "却下", "held": "保留", "not-required": "不要",
        "stopping": "停止確認中", "resuming": "再開途中", "resumed": "再開済み",
    }.get(value, value or "未確認")


def overview_details(project):
    parent, coordination_view = project["parent"], project["coordination"]
    print(f"\n詳細: {project['project']} | ノート={project['note']} | 状態記録={project['state_dir']}")
    print(f"  親: {overview_label(parent['status'])} 観測={parent['observed_at'] or '未確認'}"
          f" 終了値={parent['exit']} 会話={parent['thread_id'] or '未確認'}")
    for worker in project["workers"]:
        last = worker["last_recorded"] or {}
        print(f"  担当 {worker['assignment']} ({'現担当' if worker['current'] else '旧担当'}):"
              f" {worker['address']} {worker['role']} {overview_label(worker['work'])}/{overview_label(worker['execution'])}"
              f" {overview_label(worker['certainty'])} 記録={worker['recorded_at'] or '未記録'}"
              f" 最終状態={overview_label(last.get('work'))}/{overview_label(last.get('execution'))} 根拠={worker['ref']}")
        print(f"    工程={worker['stage']} 範囲={worker['scope']} 成果={worker['artifact']} 交代元={worker['replaces'] or 'なし'}")
    for topic in project["consultations"]:
        print(f"  相談 {topic['topic']} {topic['subject']}: {','.join(topic['participants'])}"
              f" {overview_label(topic['phase'])}/{overview_label(topic['reception'])} {overview_label(topic['certainty'])}"
              f" {topic['rounds']}往復 記録={topic['recorded_at'] or '未記録'} 依存={','.join(topic['dependencies']) or 'なし'}"
              f" 次={topic['next_action']} 根拠={topic['ref']}")
        outcome = topic["outcome"]
        if outcome:
            print(f"    結論={outcome.get('conclusion')} 分類={outcome.get('classification')} 扱い={outcome.get('disposition')}"
                  f" 理由={outcome.get('reason')} 判断={outcome.get('decision_ref')} 差分={', '.join(outcome.get('diff_refs', []))}"
                  f" 次={outcome.get('next_action')}")
    settings = coordination_view["settings"]
    print(f"  連携: {overview_label(coordination_view['status'])} 理由={coordination_view['reason'] or 'なし'}"
          f" 相談上限={settings['consultation_round_limit']} 設定={settings['ref']}")
    for change in coordination_view["changes"]:
        print(f"  変更 {change['change']}: {overview_label(change['phase'])} 対象={','.join(change['targets'])}"
              f" 送信={','.join(change['sent']) or 'なし'} 受領={','.join(change['received']) or 'なし'}"
              f" 停止確認={','.join(change['confirmed']) or 'なし'} 有効な停止確認なし={','.join(change['pending_targets']) or 'なし'}"
              f" 再開={','.join(change['resumed']) or 'なし'} 記録={change['recorded_at']} 範囲={change.get('scope_ref')}")
        for permission in change["permissions"]:
            print(f"    再開許可: {','.join(permission['targets'])} 前提={permission['premises_ref']}"
                  f" 範囲={permission['scope_ref']} 根拠={permission['ref']}")
    for review in coordination_view["reviews"]:
        print(f"  Claude確認 {review['review']}: {overview_label(review['state'])} 要否={review['required']}"
              f" 理由={review['reason']} 記録={review['recorded_at']} 範囲={review['scope_ref']} 基準={review['basis_ref']}"
              f" 依頼={review.get('request_ref')} 終了値={review.get('wrapper_exit')} 終了理由={review.get('wrapper_reason')}"
              f" 結果={review.get('wrapper_out_ref')} 報告={review.get('verifier_report_ref')} 判断={review.get('decision_ref')}")
    report = parent["report"]
    if report:
        print(f"  親の要約: {report.get('summary')} | 判断待ち: {'; '.join(report.get('pending', [])) or 'なし'}"
              f" | 理由: {report.get('reason')}")
        print(f"  読了: {', '.join(report.get('read_notes', [])) or 'なし'} | 記録先: {', '.join(report.get('written_notes', [])) or 'なし'}")
    print(f"  案件status={project['project_status']} 次={project['next']} 宣言={','.join(project['declared_workspaces']) or 'なし'}")
    for ref in dict.fromkeys(project["evidence"] + parent["evidence"]):
        print(f"  根拠: {ref}")
    for issue in project["issues"]:
        print(f"  診断 {issue['code']}: {issue['message']} | 確認先={issue['ref']}")


def display_width(text):
    return sum(0 if unicodedata.combining(char) else
               2 if unicodedata.east_asian_width(char) in ("W", "F") else 1 for char in text)


def clip_display(text, width):
    if display_width(text) <= width:
        return text
    shown = ""
    for char in text:
        if display_width(shown + char + "…") > width:
            break
        shown += char
    return shown + "…"


def overview_row(cells, width):
    if display_width(" | ".join(cells)) <= width:
        return " | ".join(cells)
    # Counts are immutable. Preserve status and uncertainty even when other values shorten.
    protected = ["", cells[1], cells[2].split()[0], cells[3], "", "", ""]
    for index, text in enumerate(cells):
        for flag in ("現在未確認", "未確認", "未記録", "未観測"):
            if flag in text and flag not in protected[index]:
                protected[index] += (" " if protected[index] else "") + flag
    limits = [display_width(text) for text in cells]
    minimum = [display_width(required) + (required != text) for required, text in zip(protected, cells)]
    minimum[0] = limits[0]  # Keep project identity before shortening descriptive fields.
    overflow = sum(limits) + len(cells) - 1 - width  # Compact separators need one column.
    while overflow > 0:
        index = max(range(len(cells)), key=lambda i: limits[i] - minimum[i])
        reduction = min(overflow, limits[index] - minimum[index])
        if reduction <= 0:
            short_name = min(limits[0], display_width(cells[0][:1] + "…"))
            if minimum[0] > short_name:
                minimum[0] = short_name
                continue
            break  # Never remove counts or uncertainty to fit an impossibly narrow terminal.
        limits[index] -= reduction
        overflow -= reduction
    shown = []
    for text, limit, required in zip(cells, limits, protected):
        if display_width(text) <= limit:
            shown.append(text)
        else:
            body = text[len(required):] if text.startswith(required) else " " + text.replace(required, "", 1)
            shown.append(required + clip_display(body, limit - display_width(required)))
    return "|".join(shown)


def overview_time_label(value, display_date):
    if not value:
        return "未観測"
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return value
    return stamp.strftime("%H:%M:%SZ" if stamp.date().isoformat() == display_date else "%Y-%m-%d %H:%M:%SZ")


def overview_text(snapshot, args):
    labels = (("現担当", "current_started"), ("実行中", "running"), ("累計", "cumulative_started"))
    totals = snapshot["totals"]
    print(f"{snapshot['generated_at']} UTC | {totals['project_count']}案件")
    print("三段の確認済み人数: " + "／".join(f"{label} {totals[key]['known']}人" for label, key in labels)
          + "（従来経路の人数は含まない）")
    print("未確定の案件数: " + "／".join(f"{label} {len(totals[key]['unknown_projects'])}件" for label, key in labels))
    print("全案件の総人数は未確定" if any(totals[key]["exact"] is None for _, key in labels) else "全案件の確定合計")
    if not snapshot["discovery_complete"]:
        print("案件の列挙自体も未確認")
    width = shutil.get_terminal_size().columns
    display_date = snapshot["generated_at"][:10]
    print("人数は確認済み分（＋未確認は不明分）。…は省略、--detailsで確認。")
    mismatch_label = "未確認（参照の不一致など）"
    groups = {"未接続": [], "従来経路": [], mismatch_label: []}
    visible = []
    for project in snapshot["projects"]:
        group = None
        if project["connection"] in ("unconnected", "legacy"):
            group = overview_label(project["connection"])
        elif (project["connection"] == "unconfirmed" and project["state_dir"] is None
              and project["note"] and any(issue["code"] == "reference-mismatch" and
                  issue["ref"] == project["note"] for issue in project["issues"])):
            group = mismatch_label
        if group is None or args.all or (args.details and group == mismatch_label):
            visible.append(project)
        else:
            groups[group].append(project["project"])
    print("案件 | 接続 | 親/観測 | 現担当/実行中/累計 | 各人の状態 | 相談 | 最終記録")
    for project in visible:
        parent, coordination_view = project["parent"], project["coordination"]
        counts = [str(project["counts"][key]["exact"]) if project["counts"][key]["exact"] is not None
                  else f"{project['counts'][key]['known']}＋未確認" for _, key in labels]
        workers = [w for w in project["workers"] if w["current"]]
        work = [f"{w['assignment']}:" + ("現在未確認" if w["certainty"] == "unconfirmed" else
                f"{overview_label(w['work'])}/{overview_label(w['execution'])}") for w in workers]
        topics = []
        for topic in project["consultations"]:
            if topic["active"]:
                state = ("現在未確認" if topic["certainty"] == "unconfirmed" else overview_label(topic["reception"]))
                phase = overview_label(topic["phase"]) if topic["phase"] in ("parent-wait", "user-wait") else ""
                topics.append(f"{topic['topic']} {','.join(topic['participants'])} {state} {phase}".strip())
        recorded = [w["recorded_at"] for w in workers] + [t["recorded_at"] for t in project["consultations"]]
        dates = [overview_time_label(date, display_date) for date in sorted({date for date in recorded if date})]
        span = (dates[0] if len(dates) == 1 else f"{dates[0]}〜{dates[-1]}") if dates else "未確認"
        if any(date is None for date in recorded):
            span += "＋未記録"
        consultation = "; ".join(topics) or ("なし" if coordination_view["status"] == "recorded" else "未確認")
        work_text = " ".join(work) or ("なし" if project["working_complete"] else "未確認")
        parent_text = overview_label(parent["status"])
        if parent["observed_at"]:
            parent_text += " " + overview_time_label(parent["observed_at"], display_date)
        print(overview_row([project["project"], overview_label(project["connection"]), parent_text,
                            "/".join(counts), work_text, consultation, span], width))
    for label, slugs in groups.items():
        if not slugs:
            continue
        prefix = f"{label} {len(slugs)}件: "
        shown = []
        for slug in slugs:
            candidate = shown + [slug]
            suffix = f" (人数不明;省略{len(slugs) - len(candidate)}件;--all)"
            if display_width(prefix + ', '.join(candidate) + suffix) > width:
                break
            shown.append(slug)
        omitted = len(slugs) - len(shown)
        print(prefix + ", ".join(shown) + f" (人数不明;省略{omitted}件;--all)")
    for project in visible:
        reasons = []
        coordination_view = project["coordination"]
        if (project["connection"] == "unconfirmed" or project["parent"]["status"] == "unconfirmed"
                or coordination_view["status"] == "unconfirmed"):
            reasons.append("状態未確認")
        if (project["parent"]["report"] or {}).get("pending") or any(
                t["phase"] in ("parent-wait", "user-wait") for t in project["consultations"]):
            reasons.append("判断待ち")
        if coordination_view["status"] == "recorded" and any(
                c["phase"] == "stopping" and c["pending_targets"] for c in coordination_view["changes"]):
            reasons.append("停止確認待ち")
        if reasons:
            print(f"確認: {project['project']} {','.join(reasons)} | 確認先={project['state_dir'] or project['note']} (--details)")
    if snapshot["issues"]:
        print("一覧の診断: " + "; ".join(f"{i['message']} 確認先={i['ref']}" for i in snapshot["issues"]))
    if args.details:
        for project in visible:
            overview_details(project)


def positive_interval(value):
    try:
        number = float(value)
        if math.isfinite(number) and number > 0:
            return number
    except (ValueError, TypeError, OverflowError):
        pass
    raise argparse.ArgumentTypeError("interval must be positive and finite")


def overview(args):
    if args.watch and args.interval is None:
        try:
            path = Path(os.environ.get("AIENV_TEAM_WORKFLOW_CONFIG") or lookup("team.workflow-settings")).expanduser()
            config = read_json(path)
            value = config["overview_interval_seconds"]
            if config["version"] != VERSION or type(value) not in (int, float):
                raise ValueError("invalid overview interval settings")
            args.interval = positive_interval(value)
        except (OSError, ValueError, KeyError, TypeError, argparse.ArgumentTypeError, subprocess.SubprocessError) as error:
            raise ValueError(f"overview-settings-error: {error}") from error
    try:
        while True:
            snapshot = overview_snapshot(args)
            if args.format == "json":
                print(json.dumps(snapshot, ensure_ascii=False))
            else:
                if args.watch and sys.stdout.isatty():
                    print("\033[2J\033[H", end="")
                overview_text(snapshot, args)
            sys.stdout.flush()
            if not args.watch:
                return
            time.sleep(args.interval)
    except KeyboardInterrupt:
        sys.exit(130)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    overview_command = commands.add_parser("overview", help="read all projects without controlling their workers")
    overview_command.add_argument("--projects-dir", type=Path,
                                  default=Path(os.environ.get("CMUX_NEXT_VAULT", str(Path.home() / "Data/obsidian"))) / "Projects")
    overview_command.add_argument("--declarations", type=Path,
                                  default=Path(os.environ.get("CMUX_TASK_STATE", str(Path.home() / ".config/cmux-task-watch/workspaces.json"))))
    overview_command.add_argument("--format", choices=("text", "json"), default="text")
    overview_command.add_argument("--watch", action="store_true")
    overview_command.add_argument("--all", action="store_true", help="show unconnected and legacy projects individually in text")
    overview_command.add_argument("--details", action="store_true", help="show recorded worker and coordination details in text")
    overview_command.add_argument("--interval", type=positive_interval)
    for name in ("init", "start", "resume", "recover", "status", "collect", "assign", "event", "report", "worker-prepare", "display", "view", "_run"):
        command = commands.add_parser(name)
        command.add_argument("--state-dir", type=Path, required=True)
        if name == "init":
            for key in ("project", "project-dir", "cwd", "note", "goal", "source", "workspace", "surface",
                        "candidate", "model", "effort", "selection-ref"):
                command.add_argument("--" + key, required=True)
            command.add_argument("--sandbox", choices=("read-only", "workspace-write", "danger-full-access"),
                                 required=True, help="親の既定方針: danger-full-access を明示（保管庫外の記録・案件ノートの保存用）")
        if name in ("start", "resume", "recover"):
            command.add_argument("--prompt-file", required=True)
            command.add_argument("--usage-ref", required=True)
        if name in ("assign", "event", "report", "worker-prepare"):
            command.add_argument("--file", required=True)
        if name == "display":
            command.add_argument("--workspace", required=True)
            command.add_argument("--surface", required=True)
        if name == "view":
            command.add_argument("--watch", action="store_true")
            command.add_argument("--interval", type=float, default=VIEW_INTERVAL)
            command.add_argument("--lines", type=int, default=20)
        if name == "_run":
            command.add_argument("--run-id", required=True)
    args = parser.parse_args()
    if args.command == "overview":
        args.projects_dir = args.projects_dir.expanduser().absolute()
        args.declarations = args.declarations.expanduser().absolute()
        try:
            overview(args)
        except KeyboardInterrupt:
            sys.exit(130)
        return
    state = args.state_dir.resolve()
    # Operational data must stay outside public program repositories (including worktrees).
    if any((parent / ".git").exists() for parent in (state, *state.parents)):
        parser.error("state-dir must be outside a git repository, in private project output")
    if args.command == "view":
        if args.interval <= 0 or args.lines <= 0:
            parser.error("interval and lines must be positive")
        view(state, args)
        return
    if args.command == "worker-prepare":
        result = worker_prepare(state, args)
    elif args.command == "init":
        result = init(state, args)
    else:
        project = read_json(state / "project.json")
        if project["version"] != VERSION:
            raise ValueError("unsupported record version")
        if args.command in ("start", "resume", "recover"):
            result = launch(state, project, args)
        elif args.command == "_run":
            run_parent(state, project, args.run_id)
            return
        elif args.command in ("assign", "event", "report"):
            result = record(state, project, args)
        elif args.command == "display":
            check_display(project["project"], args.workspace, args.surface)
            project.update(workspace=args.workspace, surface=args.surface)
            save(state / "project.json", project)
            result = project
        else:
            result = observe(state, project)
            if args.command == "collect":
                if result["status"] != "finished":
                    raise ValueError("collect requires EXIT:0, the final report and its saved summary")
                result["final_report"] = Path(result["out"]).read_text(encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.command == "worker-prepare" and result["status"] == "deferred":
        sys.exit(3)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"project-leader: {error}", file=sys.stderr)
        sys.exit(1)
