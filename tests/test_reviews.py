"""The review console channel: raise → wait → answer/clear round trips."""

import json
import os
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


def test_serve_reads_a_store_whose_wal_needs_recovery(cli, store, tmp_path):
    """A writer killed mid-write leaves a WAL that only a writable open
    can replay; a read-only open fails until then. Serve must recover
    rather than drop the node off the fleet."""
    import signal
    import sqlite3
    import subprocess
    import sys
    import time

    cli("session", "start", "--session", "s-recover", "--cwd", "/tmp")
    db_path = store / "store.db"

    # A writer that holds an uncommitted WAL and dies without closing.
    script = tmp_path / "killer.py"
    script.write_text(
        "import sqlite3, sys, time\n"
        f"c = sqlite3.connect({str(db_path)!r}, isolation_level=None)\n"
        "c.execute('PRAGMA journal_mode=WAL')\n"
        "c.execute('BEGIN')\n"
        "c.execute(\"INSERT INTO sessions (session_ref, agent, cwd, source,"
        " started_at, updated_at) VALUES ('x','a','','', '1','1')\")\n"
        "print('ready', flush=True)\n"
        "time.sleep(30)\n")
    proc = subprocess.Popen([sys.executable, str(script)],
                            stdout=subprocess.PIPE, text=True)
    proc.stdout.readline()
    proc.send_signal(signal.SIGKILL)
    proc.wait()
    time.sleep(0.2)

    # Whatever state that left, serve's reader must still answer.
    listing = json.loads(cli("session", "list").stdout)["sessions"]
    assert [s["session_ref"] for s in listing] == ["s-recover"]


def dead_pid() -> int:
    """A pid that certainly belongs to nothing: run something trivial and
    wait for it to finish."""
    import subprocess
    proc = subprocess.Popen(["/usr/bin/true"])
    proc.wait()
    return proc.pid


def test_a_killed_session_is_reaped_with_what_it_was_waiting_on(cli, store):
    """A session ends by telling us; a killed one tells nobody. Its review
    would otherwise sit in the box forever, asking on behalf of a process
    that cannot answer."""
    gone = dead_pid()
    cli("session", "start", "--session", "s-dead", "--cwd", "/w/p",
        "--pid", str(gone))
    cli("review", "raise", "--session", "s-dead", "--kind", "stopped",
        "--cwd", "/w/p", "--summary", "Waiting for your next message")

    assert json.loads(cli("review", "list").stdout)["reviews"] != []
    reaped = int(cli("session", "reap").stdout.strip())

    assert reaped == 1
    assert json.loads(cli("session", "list").stdout)["sessions"] == []
    assert json.loads(cli("review", "list").stdout)["reviews"] == []


def test_a_live_session_survives_the_reaper(cli, store):
    cli("session", "start", "--session", "s-live", "--cwd", "/w/p",
        "--pid", str(os.getpid()))
    assert int(cli("session", "reap").stdout.strip()) == 0
    listing = json.loads(cli("session", "list").stdout)["sessions"]
    assert [s["session_ref"] for s in listing] == ["s-live"]


def test_a_session_without_a_pid_is_left_alone(cli, store):
    """Silence about liveness is not evidence of death: a plugin too old
    to report a pid still gets to be present."""
    cli("session", "start", "--session", "s-quiet", "--cwd", "/w/p")
    assert int(cli("session", "reap").stdout.strip()) == 0
    listing = json.loads(cli("session", "list").stdout)["sessions"]
    assert [s["session_ref"] for s in listing] == ["s-quiet"]


def test_listing_buries_the_dead_it_walks_past(cli, store):
    """The CLI is the writer, so listing is where a dead session is
    actually put to rest rather than merely hidden."""
    gone = dead_pid()
    cli("session", "start", "--session", "s-walk", "--cwd", "/w/p",
        "--pid", str(gone))
    assert json.loads(cli("session", "list").stdout)["sessions"] == []
    # Ended for real, not filtered out of one query.
    assert int(cli("session", "reap").stdout.strip()) == 0


def test_a_zombie_counts_as_dead(cli, store):
    """A killed agent whose parent never collects it keeps answering
    signals. That pid is not a session anyone can talk to."""
    import subprocess
    child = subprocess.Popen(["/usr/bin/true"])
    # Deliberately not waited on: the process exits and stays a zombie.
    time.sleep(0.5)
    state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(child.pid)],
                           capture_output=True, text=True).stdout.strip()
    assert state.startswith("Z"), f"expected a zombie, got {state!r}"
    # And the kernel still accepts signal 0 for it, which is the trap.
    os.kill(child.pid, 0)

    cli("session", "start", "--session", "s-zombie", "--cwd", "/w/p",
        "--pid", str(child.pid))
    cli("review", "raise", "--session", "s-zombie", "--kind", "stopped",
        "--cwd", "/w/p", "--summary", "Waiting for your next message")

    assert int(cli("session", "reap").stdout.strip()) == 1
    assert json.loads(cli("session", "list").stdout)["sessions"] == []
    assert json.loads(cli("review", "list").stdout)["reviews"] == []
    child.wait()


def test_a_killed_session_whose_parent_lingers_counts_as_dead(cli, store):
    """What a SIGKILLed agent actually looks like on macOS: not the
    textbook Z, but state `?Es` — trying to exit, parent not yet
    collecting. It answers signal 0 the whole time."""
    import pty
    import signal
    child, fd = pty.fork()
    if child == 0:
        os.execv("/bin/cat", ["/bin/cat"])       # blocks on the pty
    time.sleep(0.5)
    os.kill(child, signal.SIGKILL)
    time.sleep(0.5)

    state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(child)],
                           capture_output=True, text=True).stdout.strip()
    assert state, "expected the pid to still be listed"
    os.kill(child, 0)                            # still answers signals

    cli("session", "start", "--session", "s-exiting", "--cwd", "/w/p",
        "--pid", str(child))
    cli("review", "raise", "--session", "s-exiting", "--kind", "stopped",
        "--cwd", "/w/p", "--summary", "Waiting for your next message")

    assert int(cli("session", "reap").stdout.strip()) == 1
    assert json.loads(cli("review", "list").stdout)["reviews"] == []
    os.close(fd)
    try:
        os.waitpid(child, 0)
    except ChildProcessError:
        pass
