"""Migration of a pre-SQLite file store into the queue: happy path,
refusal guard on every other subcommand, and idempotent re-entry."""

import importlib.util
import json
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path

from conftest import make_continuation_core, read_log

_loader = SourceFileLoader(
    "ac_migrate", str(Path(__file__).resolve().parent.parent / "bin" / "agentic-continuation"))
_spec = importlib.util.spec_from_loader("ac_migrate", _loader)
ac = importlib.util.module_from_spec(_spec)
_loader.exec_module(ac)

RUN_ID = "20260722T205958Z"


def build_legacy_store(store):
    """A file store exactly as the pre-SQLite tool laid it out."""
    task_core = make_continuation_core(
        step="probe-step", schedule={"mode": "every", "amount": 12, "unit": "h"})
    task_dir = store / "tasks" / "legacy-task"
    task_dir.mkdir(parents=True)
    (task_dir / "continuation.md").write_text(
        ac.render_document(task_core, ["push to any git remote"]))
    (store / "registry.json").write_text(json.dumps({"tasks": {"legacy-task": {
        "agent": "claude-code", "single_run": True, "enabled": True,
        "must_not": ["push to any git remote"],
        "sandbox": {"allow_write": [], "allow_net": [], "enforced": False},
        "registered_at": "2026-07-22T20:59:42+00:00",
    }}}))
    cont_dir = task_dir / "runs" / RUN_ID / "continuations"
    cont_dir.mkdir(parents=True)
    last_eval = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    (cont_dir / "probe-step--01.md").write_text(
        ac.render_document(task_core, ["push to any git remote"]))
    (cont_dir / "probe-step--01.state.json").write_text(json.dumps({
        "status": "pending", "registered_at": "2026-07-22T20:59:58+00:00",
        "origin": "task-continuation", "evaluations": 1,
        "last_evaluated_at": last_eval, "zero_return_streak": 1,
    }))
    done_core = make_continuation_core(step="done-step")
    (cont_dir / "done-step--01.md").write_text(ac.render_document(done_core, []))
    (cont_dir / "done-step--01.state.json").write_text(json.dumps({
        "status": "consumed", "registered_at": "2026-07-22T20:59:58+00:00",
        "origin": "probe-step--01", "evaluations": 1,
        "last_evaluated_at": last_eval, "zero_return_streak": 0,
    }))
    (store / "log.jsonl").write_text("\n".join([
        json.dumps({"ts": "2026-07-22T20:59:42+00:00", "cmd": "register",
                    "actor": "human", "task_id": "legacy-task", "outcome": "ok"}),
        json.dumps({"ts": "2026-07-22T21:00:35+00:00", "cmd": "continue",
                    "actor": "agent-plugin", "task_id": "legacy-task",
                    "run_id": RUN_ID, "continuation_id": "probe-step--01",
                    "outcome": "ok", "returned": [],
                    "summary": "Checked the fits; still running."}),
    ]) + "\n")


def test_commands_refuse_until_migrated(cli, store):
    build_legacy_store(store)
    for command in (["list"], ["queue"], ["tick", "--dry-run"]):
        proc = cli(*command, expect=1)
        assert "migrate" in proc.stderr


def test_migrate_imports_queue_runs_events_and_summaries(cli, store):
    build_legacy_store(store)
    out = cli("migrate").stdout
    assert "migrated: 1 task(s), 1 run(s), 2 queue entries, 2 event(s)" in out
    assert (store / "registry.json.imported").exists()
    assert not (store / "registry.json").exists()
    listing = cli("list").stdout
    assert "legacy-task" in listing and "single-run" in listing
    assert "probe-step--01: pending" in listing
    assert "done-step--01: consumed" in listing
    queue = json.loads(cli("queue", "--json").stdout)
    entry = next(e for e in queue["due"] + queue["scheduled"] + queue["attention"]
                 if e["continuation"] == "probe-step--01")
    assert entry["evaluations"] == 1 and entry["zero_return_streak"] == 1
    # Summary backfilled from the imported continue event.
    assert entry["last_summary"] == "Checked the fits; still running."
    assert entry["last_actor"] == "agent-plugin"
    # Imported events are queryable, and the mirror keeps working.
    log_out = cli("log", "--task", "legacy-task").stdout
    assert '"cmd": "register"' in log_out
    assert any(e["cmd"] == "migrate" for e in read_log(store))


def test_migrate_is_idempotent(cli, store):
    build_legacy_store(store)
    cli("migrate")
    assert "no legacy file store to migrate" in cli("migrate").stdout
    # The store still lists exactly one task afterwards.
    assert cli("list").stdout.count("legacy-task") == 1
