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
           / "plugins" / "console" / "hooks" / "review.mjs")


def run_hook(store, payload, extra_env=None, timeout=30):
    env = {**os.environ}
    env.pop("AGENTIC_TASK_ID", None)
    env.update({"AGENTIC_CONTINUATION_STORE": str(store),
                "CONTINUATION_BIN": BIN,
                "CONTINUATION_REVIEW_WAIT": "5",
                # Sessions hold by default; a test that is not about
                # holding says so, rather than waiting out the window.
                "CONTINUATION_REVIEW_HOLD": "0"})
    for key, value in (extra_env or {}).items():
        # None removes a key, so a test can exercise a real default the
        # harness overrides for speed.
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    # node exactly as hooks.json runs it: Claude Code is a Node program,
    # so node is present wherever a session is.
    return subprocess.run(
        ["node", HOOK], input=json.dumps(payload),
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
    # A started session is idle: it waits for the human, so it is IN the
    # review box from the moment it starts.
    assert [r["kind"] for r in open_reviews(cli)] == ["stopped"]
    assert open_reviews(cli)[0]["summary"] == "Waiting for your first message"

    run_hook(store, {"hook_event_name": "SessionEnd", "session_id": "sess-a"})
    assert sessions(cli) == []
    assert open_reviews(cli) == []


def test_first_prompt_clears_the_idle_wait(cli, store):
    run_hook(store, {"hook_event_name": "SessionStart", "session_id": "sess-i",
                     "cwd": "/tmp/proj", "source": "startup"})
    assert len(open_reviews(cli)) == 1
    run_hook(store, {"hook_event_name": "UserPromptSubmit",
                     "session_id": "sess-i", "cwd": "/tmp/proj"})
    assert open_reviews(cli) == []          # the human pushed it to work
    assert len(sessions(cli)) == 1          # still discovered


def test_resume_announces_the_same_session(cli, store):
    run_hook(store, {"hook_event_name": "SessionStart", "session_id": "sess-b",
                     "cwd": "/tmp/proj", "source": "resume"})
    assert [s["source"] for s in sessions(cli)] == ["resume"]


def test_presence_heals_without_session_start(cli, store):
    """Claude Code can dispatch SessionStart before a --plugin-dir plugin
    has loaded, so any later event must make the session discoverable."""
    run_hook(store, {"hook_event_name": "UserPromptSubmit",
                     "session_id": "sess-heal", "cwd": "/tmp/heal"})
    live = sessions(cli)
    assert [s["session_ref"] for s in live] == ["sess-heal"]
    assert live[0]["cwd"] == "/tmp/heal"

    # A stop keeps the same session and adds its wait.
    run_hook(store, {"hook_event_name": "Stop", "session_id": "sess-heal",
                     "cwd": "/tmp/heal"})
    assert len(sessions(cli)) == 1
    assert [r["kind"] for r in open_reviews(cli)] == ["stopped"]

    run_hook(store, {"hook_event_name": "SessionEnd",
                     "session_id": "sess-heal"})
    assert sessions(cli) == []
    assert open_reviews(cli) == []


def test_guarded_sessions_never_register(cli, store):
    run_hook(store, {"hook_event_name": "UserPromptSubmit",
                     "session_id": "sess-guard", "cwd": "/tmp"},
             extra_env={"AGENTIC_TASK_ID": "task"})
    assert sessions(cli) == []


def test_a_session_told_not_to_hold_returns_at_once(cli, store):
    """Holding costs the terminal, so a session whose terminal must never
    wait can opt out — and then says plainly that it takes no message."""
    result = run_hook(store, {"hook_event_name": "Stop",
                              "session_id": "sess-idle", "cwd": "/tmp/p"},
                      extra_env={"CONTINUATION_REVIEW_HOLD": "0"},
                      timeout=15)
    assert result.returncode == 0
    assert result.stdout.strip() == ""
    reviews = open_reviews(cli)
    assert [r["summary"] for r in reviews] == ["Waiting for your next message"]
    assert reviews[0]["payload"]["held"] is False


def test_a_held_session_takes_a_message_from_the_console(cli, store):
    """The whole point of holding: the hook is still alive, so a message
    typed in the app becomes the session's next instruction."""
    def send_from_console():
        deadline = time.time() + 15
        while time.time() < deadline:
            reviews = open_reviews(cli)
            if reviews:
                cli("review", "answer", str(reviews[0]["id"]),
                    "--decision", "-",
                    stdin=json.dumps({"message": "Run the tests again."}))
                return
            time.sleep(0.2)

    thread = threading.Thread(target=send_from_console)
    thread.start()
    result = run_hook(store, {"hook_event_name": "Stop",
                              "session_id": "sess-held", "cwd": "/tmp/p"},
                      extra_env={"CONTINUATION_REVIEW_HOLD": "20"}, timeout=40)
    thread.join()

    decision = json.loads(result.stdout)
    assert decision["decision"] == "block"
    assert "Run the tests again." in decision["reason"]


def test_a_held_item_says_so(cli, store):
    """The console offers Send only where it would land."""
    def read_then_clear():
        deadline = time.time() + 15
        while time.time() < deadline:
            reviews = open_reviews(cli)
            if reviews:
                assert reviews[0]["payload"]["held"] is True
                cli("review", "clear", "--session", "sess-held-flag")
                return
            time.sleep(0.2)

    thread = threading.Thread(target=read_then_clear)
    thread.start()
    run_hook(store, {"hook_event_name": "Stop",
                     "session_id": "sess-held-flag", "cwd": "/tmp/p"},
             extra_env={"CONTINUATION_REVIEW_HOLD": "20"}, timeout=40)
    thread.join()


def test_a_cleared_hold_leaves_the_queue(cli, store):
    """A typed message clears the item; when the hold ends there is
    nothing left claiming the session waits on a human."""
    def clear_it():
        deadline = time.time() + 15
        while time.time() < deadline:
            if open_reviews(cli):
                cli("review", "clear", "--session", "sess-cleared")
                return
            time.sleep(0.2)

    thread = threading.Thread(target=clear_it)
    thread.start()
    result = run_hook(store, {"hook_event_name": "Stop",
                              "session_id": "sess-cleared", "cwd": "/tmp/p"},
                      extra_env={"CONTINUATION_REVIEW_HOLD": "20"}, timeout=40)
    thread.join()
    assert result.stdout.strip() == ""
    assert open_reviews(cli) == []


def test_the_hook_names_the_process_its_session_belongs_to(cli, store):
    """The pid is how a killed session gets buried: nothing else about a
    kill reaches the store."""
    run_hook(store, {"hook_event_name": "Stop",
                     "session_id": "sess-pid", "cwd": "/tmp/p"},
             extra_env={"CLAUDE_PID": str(os.getpid())}, timeout=15)
    sessions = json.loads(cli("session", "list").stdout)["sessions"]
    assert [s["session_ref"] for s in sessions] == ["sess-pid"]
    assert sessions[0]["pid"] == os.getpid()


def test_a_session_holds_without_being_asked(cli, store):
    """The box's one job is to be actionable, so holding is the default:
    an idle session is reachable unless its terminal says otherwise."""
    def send_from_console():
        deadline = time.time() + 15
        while time.time() < deadline:
            reviews = open_reviews(cli)
            if reviews:
                assert reviews[0]["payload"]["held"] is True
                cli("review", "answer", str(reviews[0]["id"]),
                    "--decision", "-",
                    stdin=json.dumps({"message": "Carry on."}))
                return
            time.sleep(0.2)

    thread = threading.Thread(target=send_from_console)
    thread.start()
    result = run_hook(store, {"hook_event_name": "Stop",
                              "session_id": "sess-default-hold",
                              "cwd": "/tmp/p"},
                      extra_env={"CONTINUATION_REVIEW_HOLD": None}, timeout=40)
    thread.join()
    decision = json.loads(result.stdout)
    assert decision["decision"] == "block"
    assert "Carry on." in decision["reason"]


def test_an_expired_hold_leaves_the_session_visible(cli, store):
    """A hold that runs out does not delete the session from the box —
    it is still idle, and still worth seeing. It just stops claiming to
    be reachable."""
    result = run_hook(store, {"hook_event_name": "Stop",
                              "session_id": "sess-expired", "cwd": "/tmp/p"},
                      extra_env={"CONTINUATION_REVIEW_HOLD": "2"}, timeout=30)
    assert result.stdout.strip() == ""
    reviews = open_reviews(cli)
    assert [r["summary"] for r in reviews] == ["Waiting for your next message"]
    assert reviews[0]["payload"]["held"] is False
