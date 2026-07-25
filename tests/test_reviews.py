"""The review console channel: raise → wait → answer/clear round trips."""

import json
import subprocess
import sys
import threading
import time
from pathlib import Path

BIN = str(Path(__file__).resolve().parent.parent / "bin" / "continuation")


def raise_review(cli, kind="question", session="sess-1", payload=None):
    proc = cli("review", "raise", "--session", session, "--kind", kind,
               "--cwd", "/tmp/project", "--summary", "Pick one",
               "--payload", "-",
               stdin=json.dumps(payload or {"questions": []}))
    return proc.stdout.strip()


def test_raise_lists_open_review(cli, store):
    review_id = raise_review(cli)
    listing = json.loads(cli("review", "list").stdout)
    assert [r["id"] for r in listing["reviews"]] == [int(review_id)]
    entry = listing["reviews"][0]
    assert entry["kind"] == "question"
    assert entry["summary"] == "Pick one"
    assert entry["session_ref"] == "sess-1"


def test_answer_resolves_wait(cli, store):
    review_id = raise_review(cli)
    decision = {"answers": {"Pick one": "Option A"}}

    def answer_later():
        time.sleep(0.7)
        cli("review", "answer", review_id, "--decision", "-",
            stdin=json.dumps(decision))

    thread = threading.Thread(target=answer_later)
    thread.start()
    proc = cli("review", "wait", review_id, "--timeout", "10")
    thread.join()
    assert json.loads(proc.stdout) == decision
    assert json.loads(cli("review", "list").stdout)["reviews"] == []


def test_wait_times_out(cli, store):
    review_id = raise_review(cli)
    proc = cli("review", "wait", review_id, "--timeout", "0.5", expect=3)
    assert proc.stdout == ""


def test_clear_ends_wait_without_decision(cli, store):
    review_id = raise_review(cli, session="sess-2")

    def clear_later():
        time.sleep(0.7)
        cli("review", "clear", "--session", "sess-2")

    thread = threading.Thread(target=clear_later)
    thread.start()
    proc = cli("review", "wait", review_id, "--timeout", "10", expect=4)
    thread.join()
    assert proc.stdout == ""


def test_clear_is_kind_scoped(cli, store):
    question = raise_review(cli, kind="question", session="sess-3")
    stopped = raise_review(cli, kind="stopped", session="sess-3")
    cli("review", "clear", "--session", "sess-3", "--kind", "stopped")
    open_ids = [r["id"] for r in
                json.loads(cli("review", "list").stdout)["reviews"]]
    assert open_ids == [int(question)]
    assert int(stopped) not in open_ids


def test_answer_refuses_non_open(cli, store):
    review_id = raise_review(cli)
    cli("review", "answer", review_id, "--decision", "-", stdin="{}")
    cli("review", "answer", review_id, "--decision", "-", stdin="{}",
        expect=1)


def test_session_start_is_discoverable_and_end_retires_it(cli, store):
    cli("session", "start", "--session", "s-1", "--cwd", "/tmp/project",
        "--source", "startup")
    listing = json.loads(cli("session", "list").stdout)["sessions"]
    assert [s["session_ref"] for s in listing] == ["s-1"]
    assert listing[0]["cwd"] == "/tmp/project"
    assert listing[0]["source"] == "startup"

    # A resume of the same session keeps its original start time.
    started = listing[0]["started_at"]
    cli("session", "start", "--session", "s-1", "--cwd", "/tmp/project",
        "--source", "resume")
    again = json.loads(cli("session", "list").stdout)["sessions"][0]
    assert again["started_at"] == started
    assert again["source"] == "resume"

    cli("session", "end", "--session", "s-1")
    assert json.loads(cli("session", "list").stdout)["sessions"] == []


def test_sessions_and_reviews_are_independent(cli, store):
    cli("session", "start", "--session", "s-2", "--cwd", "/tmp/p")
    raise_review(cli, session="s-2", kind="stopped")
    assert len(json.loads(cli("session", "list").stdout)["sessions"]) == 1
    assert len(json.loads(cli("review", "list").stdout)["reviews"]) == 1
    # Clearing the wait leaves the session discovered.
    cli("review", "clear", "--session", "s-2")
    assert json.loads(cli("review", "list").stdout)["reviews"] == []
    assert len(json.loads(cli("session", "list").stdout)["sessions"]) == 1
