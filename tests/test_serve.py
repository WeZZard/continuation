"""Node API integration tests: the real `serve` subprocess against a temp
store, driven over HTTP exactly the way the Mac app will drive it. Read
surface only — the one write `serve` ever performs is its own startup
bookkeeping (node id mint + serve event), asserted here too.
"""

import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

from conftest import BIN

SERVE_LINE = re.compile(r"serving node ([0-9A-HJKMNP-TV-Z]{26}) on [\d.]+:(\d+)")


def start_serve(store):
    proc = subprocess.Popen(
        [sys.executable, BIN, "serve", "--bind", "127.0.0.1", "--port", "0",
         "--no-mdns", "--sse-poll", "0.05"],
        env={**os.environ, "AGENTIC_CONTINUATION_STORE": str(store),
             "PATH": "/usr/bin:/bin"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = proc.stdout.readline()
    match = SERVE_LINE.search(line)
    assert match, f"unexpected serve banner: {line!r} / {proc.stderr.read()!r}"
    return proc, match.group(1), int(match.group(2))


@pytest.fixture()
def server(store, cli, continuation_file, fake_agent):
    """A serve process over a store holding one registered task."""
    cli("register", "it-task", "--agent", "claude-code",
        "--agent-command", fake_agent, "--must-not", "touch production",
        "--continuation", continuation_file())
    proc, node_id, port = start_serve(store)
    yield {"node_id": node_id, "base": f"http://127.0.0.1:{port}",
           "port": port, "proc": proc}
    proc.terminate()
    proc.wait(timeout=10)


def get_json(base, path):
    with urllib.request.urlopen(base + path, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_status(base, path):
    try:
        with urllib.request.urlopen(base + path, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as error:
        return error.code


# ------------------------------------------------------------------ /v1/node

def test_node_identity_and_health(server):
    node = get_json(server["base"], "/v1/node")
    assert node["proto"] == "v1"
    assert node["node_id"] == server["node_id"]
    assert len(node["node_id"]) == 26
    assert node["schema_versions"] == [1, 2]
    assert node["version"]
    assert node["hostname"]
    assert node["queue_counts"] == {"due": 0, "scheduled": 0, "attention": 0}
    assert node["last_tick_at"] is None  # no tick has run in this store


def test_node_id_stable_across_restarts(server, store):
    first = server["node_id"]
    proc, node_id, _port = start_serve(store)
    proc.terminate()
    proc.wait(timeout=10)
    assert node_id == first


# ----------------------------------------------------------------- /v1/queue

def test_queue_matches_cli_json(server, cli):
    cli("tick")  # starts the run; fake agent returns nothing -> stays pending
    via_http = get_json(server["base"], "/v1/queue")
    via_cli = json.loads(cli("queue", "--json").stdout)
    for section in ("due", "scheduled", "attention"):
        assert ([e["continuation"] for e in via_http[section]]
                == [e["continuation"] for e in via_cli[section]])
    entry = (via_http["due"] + via_http["scheduled"])[0]
    assert entry["task"] == "it-task"
    assert entry["continuation"] == "probe-step--01"


# ----------------------------------------------------------------- /v1/tasks

def test_tasks_listing_and_detail(server, cli):
    tasks = get_json(server["base"], "/v1/tasks")["tasks"]
    assert [t["id"] for t in tasks] == ["it-task"]
    assert tasks[0]["must_not"] == ["touch production"]
    assert tasks[0]["continuation"]["step"] == "probe-step"

    cli("tick")
    detail = get_json(server["base"], "/v1/tasks/it-task")
    assert detail["run_count"] == 1
    run = detail["runs"][0]
    assert run["settled"] is False
    entry = run["entries"][0]
    assert entry["cid"] == "probe-step--01"
    assert entry["status"] == "pending"
    assert entry["evaluations"] == 1
    assert entry["core"]["task"].startswith("Check whether")


def test_unknown_task_404(server):
    assert get_status(server["base"], "/v1/tasks/no-such-task") == 404
    assert get_status(server["base"], "/v1/nope") == 404
    assert get_status(server["base"], "/v2/node") == 404


# --------------------------------------------------------------- /v1/prompts

def test_prompt_listing_and_content(server, cli):
    cli("tick")
    run_id = get_json(server["base"], "/v1/tasks/it-task")["runs"][0]["run_id"]
    listing = get_json(
        server["base"], f"/v1/tasks/it-task/runs/{run_id}/prompts")["prompts"]
    assert [p["name"] for p in listing] == ["prompt--probe-step--01--001.md"]
    with urllib.request.urlopen(
            server["base"]
            + f"/v1/tasks/it-task/runs/{run_id}/prompts/{listing[0]['name']}",
            timeout=10) as resp:
        text = resp.read().decode("utf-8")
    assert "You are evaluating a registered continuation" in text
    assert "You **MUST NOT** touch production" in text


def test_prompt_path_traversal_rejected(server, cli):
    cli("tick")
    run_id = get_json(server["base"], "/v1/tasks/it-task")["runs"][0]["run_id"]
    # Raw request bypassing urllib path normalization.
    for name in ("..%2F..%2Fstore.db", "..", "prompt--%2e%2e--x.md",
                 "store.db", "prompt--nope.md"):
        conn = http.client.HTTPConnection("127.0.0.1", server["port"], timeout=10)
        conn.request("GET", f"/v1/tasks/it-task/runs/{run_id}/prompts/{name}")
        assert conn.getresponse().status == 404
        conn.close()


# ------------------------------------------------------------------- /v1/log

def test_log_cursor_and_filters(server, cli):
    cli("tick")
    events = get_json(server["base"], "/v1/log?after=0&limit=1000")["events"]
    ids = [e["id"] for e in events]
    assert ids == sorted(ids)
    assert any(e["cmd"] == "serve" for e in events)
    assert any(e["cmd"] == "register" and e["task_id"] == "it-task"
               for e in events)
    scoped = get_json(server["base"], "/v1/log?task=it-task&after=0")["events"]
    assert scoped and all(e["task_id"] == "it-task" for e in scoped)
    latest = get_json(server["base"], "/v1/log?limit=2")["events"]
    assert len(latest) == 2
    assert latest[0]["id"] > latest[1]["id"]  # newest first without a cursor


# ---------------------------------------------------------------- /v1/events

def test_sse_delivers_new_events_live(server, cli):
    node = get_json(server["base"], "/v1/node")
    assert node  # server warm
    last = get_json(server["base"], "/v1/log?limit=1")["events"][0]["id"]
    stream = urllib.request.urlopen(
        server["base"] + f"/v1/events?after={last}", timeout=10)
    cli("list")  # writes a `list` event the stream must deliver
    deadline = time.time() + 10
    got = None
    while time.time() < deadline:
        line = stream.readline().decode("utf-8").strip()
        if line.startswith("data: "):
            got = json.loads(line[len("data: "):])
            break
    stream.close()
    assert got is not None, "no SSE event arrived"
    assert got["cmd"] == "list"
    assert got["id"] == last + 1


# ------------------------------------------------------- read-only guarantee

def test_reads_write_nothing(server, cli):
    before = get_json(server["base"], "/v1/log?after=0&limit=1000")["events"]
    get_json(server["base"], "/v1/node")
    get_json(server["base"], "/v1/queue")
    get_json(server["base"], "/v1/tasks")
    get_json(server["base"], "/v1/tasks/it-task")
    get_status(server["base"], "/v1/nope")
    after = get_json(server["base"], "/v1/log?after=0&limit=1000")["events"]
    assert len(after) == len(before)  # request handling never writes
