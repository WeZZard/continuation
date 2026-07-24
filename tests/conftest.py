"""Integration-test harness: real CLI as a subprocess against a temp store,
with a fake agent binary standing in for claude/pi so the full
tick -> spawn -> extract -> register loop runs hermetically."""

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

BIN = str(Path(__file__).resolve().parent.parent / "bin" / "continuation")

FAKE_AGENT = """#!/usr/bin/env python3
import json, os, sys
prompt = sys.stdin.read()
response_file = os.environ.get("FAKE_AGENT_RESPONSE", "")
text = ""
if response_file and os.path.exists(response_file):
    text = open(response_file, encoding="utf-8").read()
capture = os.environ.get("FAKE_AGENT_CAPTURE", "")
if capture:
    with open(capture, "w", encoding="utf-8") as fh:
        json.dump({
            "cwd": os.getcwd(),
            "prompt_head": prompt[:400],
            "env": {k: v for k, v in os.environ.items() if k.startswith("AGENTIC_")},
        }, fh)
print(json.dumps({"result": text, "session_id": "fake-session"}))
"""


@pytest.fixture()
def store(tmp_path):
    return tmp_path / "store"


@pytest.fixture()
def cli(store, tmp_path):
    def run(*args, stdin=None, env=None, expect=0):
        full_env = {**os.environ, "AGENTIC_CONTINUATION_STORE": str(store),
                    "PATH": "/usr/bin:/bin",  # hide the real `things` CLI
                    **(env or {})}
        proc = subprocess.run(
            [sys.executable, BIN, *args],
            input=stdin, text=True, capture_output=True, env=full_env, timeout=120,
        )
        if expect is not None:
            assert proc.returncode == expect, (
                f"exit {proc.returncode} (wanted {expect})\n"
                f"stdout: {proc.stdout}\nstderr: {proc.stderr}")
        return proc
    return run


@pytest.fixture()
def fake_agent(tmp_path):
    path = tmp_path / "fake-agent"
    path.write_text(FAKE_AGENT)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


def make_continuation_core(**overrides):
    core = {
        "schema_version": 2,
        "step": "probe-step",
        "task": "Check whether the thing finished.",
        "when_to_stop": ["Thing still running - stop, return nothing."],
        "when_to_continue": "When done, return the next step.",
        "context": "Integration test continuation.",
        "schedule": {"mode": "now"},
    }
    core.update(overrides)
    return core


@pytest.fixture()
def continuation_file(tmp_path):
    def write(**overrides):
        path = tmp_path / "continuation.json"
        path.write_text(json.dumps(make_continuation_core(**overrides)))
        return str(path)
    return write


@pytest.fixture()
def registered(cli, continuation_file, fake_agent):
    """A registered single-run task wired to the fake agent."""
    cli("register", "it-task", "--agent", "claude-code", "--single-run",
        "--agent-command", fake_agent,
        "--must-not", "touch production",
        "--continuation", continuation_file())
    return "it-task"


def read_log(store):
    path = store / "log.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines()]


def continuation_block(**overrides):
    core = make_continuation_core(**overrides)
    return "<CONTINUATION>\n" + json.dumps(core) + "\n</CONTINUATION>"
