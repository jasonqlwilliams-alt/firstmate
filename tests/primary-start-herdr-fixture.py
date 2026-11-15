#!/usr/bin/env python3
"""Fake CLI/process table for primary-start tests. Never starts a harness."""
import json
import os
from pathlib import Path
import sys
import time

state_path = Path(os.environ["FM_PRIMARY_TEST_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
pid = int(os.environ["FM_PRIMARY_TEST_PID"])

if Path(sys.argv[0]).name == "ps":
    if "-axo" in args:
        print(f"{pid} 1 bash")
    elif "-o" in args:
        field = args[args.index("-o") + 1]
        print({"stat=": "S", "comm=": "claude", "args=": "claude", "ppid=": "1",
               "lstart=": "fixture-start claude"}.get(field, ""))
    sys.exit(0)

if len(args) < 2 or args[-2:] != ["--session", "fixture"]:
    raise SystemExit("fake Herdr refuses a missing or unexpected trailing session")
args = args[:-2]
with open(os.environ["FM_PRIMARY_TEST_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "fm_home": os.environ.get("FM_HOME"),
                          "claudecode": os.environ.get("CLAUDECODE")}) + "\n")


def save():
    state_path.write_text(json.dumps(state))


def emit(result):
    print(json.dumps({"result": result}))


def error(code):
    print(json.dumps({"error": {"code": code}}))
    sys.exit(1)


def option(name):
    return args[args.index(name) + 1]


def create(workspace, home):
    number = len(state["panes"]) + 1
    pane = {"pane_id": f"{workspace}:p{number}", "workspace_id": workspace,
            "tab_id": f"{workspace}:t{number}", "cwd": home,
            "terminal_id": f"term-{number}", "active": False}
    state["panes"].append(pane)
    save()
    return pane


def public(pane):
    return {k: v for k, v in pane.items() if k not in ("active", "kind", "status", "process")}


command = args[:2]
if args[0] == "status":
    print(json.dumps({"client": {"protocol": 22, "version": "fixture"}, "server": {
        "running": state.get("running", True), "compatible": state.get("compatible", True),
        "protocol": 22}}))
elif args == ["server"]:
    state["running"] = True
    save()
elif command == ["workspace", "list"]:
    emit({"workspaces": state["workspaces"]})
elif command == ["pane", "list"]:
    emit({"panes": [public(p) for p in state["panes"]]})
elif command in (["workspace", "create"], ["tab", "create"]):
    time.sleep(state.get("delay_create", 0))
    if command[0] == "workspace":
        workspace = f"w{len(state['workspaces']) + 1}"
        state["workspaces"].append({"workspace_id": workspace, "label": option("--label")})
    else:
        workspace = option("--workspace")
    pane = create(workspace, option("--cwd"))
    if state.get("lost_create"):
        error("simulated_lost_response")
    emit({"root_pane": public(pane), "workspace": {"workspace_id": workspace},
          "tab": {"tab_id": pane["tab_id"]}})
elif command in (["pane", "get"], ["pane", "process-info"], ["agent", "get"],
                 ["pane", "run"], ["agent", "rename"]):
    target = option("--pane") if "--pane" in args else args[2]
    pane = next((p for p in state["panes"] if p["pane_id"] == target), None)
    if pane is None:
        error("pane_not_found")
    if command == ["pane", "get"]:
        state["gets"] = state.get("gets", 0) + 1
        if state.get("change_terminal") and state["gets"] >= 2:
            pane["terminal_id"] = "foreign-terminal"
        save()
        emit({"pane": public(pane)})
    elif command == ["pane", "process-info"]:
        process = pane.get("process", "claude" if pane["active"] else "bash")
        emit({"type": "pane_process_info", "process_info": {
            "pane_id": target, "shell_pid": pid, "foreground_process_group_id": pid,
            "foreground_processes": [{"pid": pid, "name": process, "argv0": process,
                                      "argv": [process], "cmdline": process}]}})
    elif command == ["agent", "get"]:
        if not pane["active"]:
            error("agent_not_found")
        emit({"agent": {"agent": pane.get("kind", "claude"),
                        "agent_status": pane.get("status", "idle")}})
    elif command == ["pane", "run"]:
        state["submitted"] = args[3]
        if not state.get("stall"):
            pane["active"] = True
        save()
        emit({"type": "submitted"})
    else:
        emit({"type": "renamed"})
else:
    raise SystemExit(f"unexpected fake command {args!r}")
