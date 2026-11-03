#!/usr/bin/env python3
"""Detached project leaders, using codex-exec.sh. Local records are version 1.

Use --help and README.md for the command and record contracts. No daemon,
worker inference, model selection, or Vault writes are performed here.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from collections import deque
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
VERSION = 1
VIEW_INTERVAL = float(os.environ.get("AIENV_LEADER_VIEW_INTERVAL", "5"))
ASSIGN_COLUMNS = ("version id stage scope artifact role worker address parent_thread "
                  "candidate model effort selection_ref replaces handoff_ref state_ref").split()
WORK_STATES = ("working consulting consultation-wait slot-wait stop-requested stopped "
               "parent-wait user-wait done replaced unrecoverable unconfirmed").split()


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


def process_start(pid):
    return subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                          capture_output=True, text=True).stdout.strip()


def alive(pid, started):
    if not pid or not started:
        return False
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="], capture_output=True, text=True)
    fields = result.stdout.strip().split(maxsplit=1)
    return (result.returncode == 0 and len(fields) == 2
            and not fields[0].startswith("Z") and fields[1].strip() == started)


def observe(state, project):
    latest = read_json(state / "latest.json")
    rows = assignments(state)
    replaced = {row["replaces"] for row in rows if row["replaces"]}
    result = {"version": VERSION, "project": project["project"], "status": "not-started",
              "workspace": project["workspace"], "surface": project["surface"],
              "assignments": rows, "current_assignment_ids": [row["id"] for row in rows if row["id"] not in replaced],
              "last_recorded": latest["workers"],
              "worker_records_status": "last-recorded", "thread_id": project.get("thread_id", "")}
    if not project.get("run"):
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
                  thread_id=current_thread(run), recovery_attempted=project["recovery_attempted"],
                  notification=(report or {}).get("notification", run.get("notification", "unknown")))
    # Never convert a parent's EXIT into a child's stopped/completed state.
    if status == "unconfirmed" or (run["mode"] == "recover" and not project.get("recovery_complete")):
        result["worker_records_status"] = "unconfirmed"
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


def record(state, project, args):
    data = read_json(Path(args.file))
    if args.command == "assign":
        required(data, ASSIGN_COLUMNS[1:13])
        rows = assignments(state)
        if any(row["id"] == data["id"] for row in rows):
            raise ValueError("assignment id already exists; append a new id and replaces link")
        if data.get("replaces") and data["replaces"] not in {row["id"] for row in rows}:
            raise ValueError("unknown replaced assignment")
        data.update(version=VERSION, state_ref=str(state / "events.jsonl"))
        with (state / "assignments.tsv").open("a", encoding="utf-8", newline="") as stream:
            csv.DictWriter(stream, fieldnames=ASSIGN_COLUMNS, delimiter="\t").writerow(data)
    elif args.command == "report":
        required(data, ("summary", "pending", "reason", "read_notes", "written_notes"))
        for key in ("pending", "read_notes", "written_notes"):
            if not isinstance(data[key], list):
                raise ValueError(f"array required: {key}")
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "start", "resume", "recover", "status", "collect", "assign", "event", "report", "display", "view", "_run"):
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
        if name in ("assign", "event", "report"):
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
    state = args.state_dir.resolve()
    # Operational data must stay outside public program repositories (including worktrees).
    if any((parent / ".git").exists() for parent in (state, *state.parents)):
        parser.error("state-dir must be outside a git repository, in private project output")
    if args.command == "view":
        if args.interval <= 0 or args.lines <= 0:
            parser.error("interval and lines must be positive")
        view(state, args)
        return
    if args.command == "init":
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


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"project-leader: {error}", file=sys.stderr)
        sys.exit(1)
