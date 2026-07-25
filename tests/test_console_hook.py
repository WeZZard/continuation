"""The console plugin's hook, driven exactly as Claude Code drives it:
hook-event JSON on stdin, decisions on stdout, a real CLI + temp store
underneath."""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

BIN = str(Path(__file__).resolve().parent.parent / "bin" / "continuation")
HOOK = str(Path(__file__).resolve().parent.parent
           / "plugins" / "console" / "hooks" / "review.py")


def run_hook(store, payload, extra_env=None, timeout=30):
    env = {**os.environ}
    env.pop("AGENTIC_TASK_ID", None)
    env.update({"AGENTIC_CONTINUATION_STORE": str(store),
                "CONTINUATION_BIN": BIN,
                "CONTINUATION_REVIEW_WAIT": "5"})
    env.update(extra_env or {})
    # /usr/bin/python3 exactly as hooks.json runs it — the system Python
    # is older than any dev interpreter and must stay supported.
    return subprocess.run(
        ["/usr/bin/python3", HOOK], input=json.dumps(payload),
        text=True, capture_output=True, env=env, timeout=timeout)


def open_reviews(cli):
    return json.loads(cli("review", "list").stdout)["reviews"]


def test_question_answered_from_console(cli, store):
    payload = {
        "hook_event_name": "PreToolUse",
        "session_id": "sess-q",
        "cwd": "/tmp/project",
        "tool_name": "AskUserQuestion",
        "tool_input": {"questions": [{
            "question": "Which color?",
            "options": [{"label": "Red"}, {"label": "Blue"}],
        }]},
    }

    def answer_from_console():
        deadline = time.time() + 10
        while time.time() < deadline:
            reviews = open_reviews(cli)
            if reviews:
                cli("review", "answer", str(reviews[0]["id"]),
                    "--decision", "-",
                    stdin=json.dumps({"answers": {"Which color?": "Blue"}}))
                return
            time.sleep(0.2)

    thread = threading.Thread(target=answer_from_console)
    thread.start()
    proc = run_hook(store, payload)
    thread.join()
    assert proc.returncode == 0
    output = json.loads(proc.stdout)
    assert output["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Blue" in output["hookSpecificOutput"]["permissionDecisionReason"]


def test_plan_approval_allows_tool(cli, store):
    payload = {
        "hook_event_name": "PreToolUse",
        "session_id": "sess-p",
        "cwd": "/tmp/project",
        "tool_name": "ExitPlanMode",
        "tool_input": {"plan": "# The plan\nDo the thing."},
    }

    def approve():
        deadline = time.time() + 10
        while time.time() < deadline:
            reviews = open_reviews(cli)
            if reviews:
                cli("review", "answer", str(reviews[0]["id"]),
                    "--decision", "-", stdin=json.dumps({"approve": True}))
                return
            time.sleep(0.2)

    thread = threading.Thread(target=approve)
    thread.start()
    proc = run_hook(store, payload)
    thread.join()
    output = json.loads(proc.stdout)
    assert output["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_timeout_falls_back_to_terminal(cli, store):
    payload = {
        "hook_event_name": "PreToolUse",
        "session_id": "sess-t",
        "cwd": "",
        "tool_name": "AskUserQuestion",
        "tool_input": {"questions": [{"question": "Q?"}]},
    }
    proc = run_hook(store, payload, extra_env={"CONTINUATION_REVIEW_WAIT": "1"})
    assert proc.returncode == 0
    assert proc.stdout == ""          # no decision: the terminal renders it
    assert len(open_reviews(cli)) == 1  # stays visible until PostToolUse

    cleared = run_hook(store, {
        "hook_event_name": "PostToolUse",
        "session_id": "sess-t",
        "tool_name": "AskUserQuestion",
        "tool_input": {},
    })
    assert cleared.returncode == 0
    assert open_reviews(cli) == []


def test_stop_raises_and_prompt_clears(cli, store):
    run_hook(store, {"hook_event_name": "Stop", "session_id": "sess-s",
                     "cwd": "/tmp/x"})
    reviews = open_reviews(cli)
    assert [r["kind"] for r in reviews] == ["stopped"]

    run_hook(store, {"hook_event_name": "UserPromptSubmit",
                     "session_id": "sess-s"})
    assert open_reviews(cli) == []


def test_dispatcher_spawned_sessions_are_guarded_out(cli, store):
    proc = run_hook(store, {
        "hook_event_name": "Stop", "session_id": "sess-d", "cwd": "",
    }, extra_env={"AGENTIC_TASK_ID": "some-task"})
    assert proc.returncode == 0
    assert open_reviews(cli) == []


def sessions(cli):
    return json.loads(cli("session", "list").stdout)["sessions"]


def test_session_start_announces_and_end_retires(cli, store):
    run_hook(store, {"hook_event_name": "SessionStart", "session_id": "sess-a",
                     "cwd": "/tmp/proj", "source": "startup"})
    live = sessions(cli)
    assert [s["session_ref"] for s in live] == ["sess-a"]
    assert live[0]["source"] == "startup"

    run_hook(store, {"hook_event_name": "SessionEnd", "session_id": "sess-a"})
    assert sessions(cli) == []


def test_resume_announces_the_same_session(cli, store):
    run_hook(store, {"hook_event_name": "SessionStart", "session_id": "sess-b",
                     "cwd": "/tmp/proj", "source": "resume"})
    assert [s["source"] for s in sessions(cli)] == ["resume"]
