"""Subcommand integration tests: happy paths, corner cases, negative cases.

Every test drives the real CLI as a subprocess against a temp store; tick
tests run the full spawn loop through the fake agent binary.
"""

import json

from conftest import continuation_block, make_seed, read_log


# ------------------------------------------------------------------ register

def test_register_happy_renders_seed_and_logs(cli, store, seed_file):
    out = cli("register", "my-task", "--agent", "claude-code",
              "--seed", seed_file()).stdout
    assert "registered my-task" in out
    seed_doc = (store / "tasks" / "my-task" / "continuation.md").read_text()
    assert '"step": "probe-step"' in seed_doc
    assert "You **MUST NOT** write or edit any file" in seed_doc
    entries = read_log(store)
    assert entries[-1]["cmd"] == "register"
    assert entries[-1]["task_id"] == "my-task"
    assert entries[-1]["outcome"] == "ok"


def test_register_task_rules_rendered(cli, store, seed_file):
    cli("register", "ruled-task", "--agent", "pi",
        "--must-not", "touch the fits", "--must-not", "push to any git remote",
        "--seed", seed_file())
    doc = (store / "tasks" / "ruled-task" / "continuation.md").read_text()
    assert "You **MUST NOT** touch the fits" in doc
    assert "You **MUST NOT** push to any git remote" in doc


def test_register_seed_from_stdin(cli, store):
    cli("register", "stdin-task", "--agent", "claude-code", "--seed", "-",
        stdin=json.dumps(make_seed()))
    assert (store / "tasks" / "stdin-task" / "continuation.md").exists()


def test_register_duplicate_refused_force_replaces(cli, seed_file):
    cli("register", "dup-task", "--agent", "claude-code", "--seed", seed_file())
    proc = cli("register", "dup-task", "--agent", "claude-code",
               "--seed", seed_file(), expect=1)
    assert "already registered" in proc.stderr
    cli("register", "dup-task", "--agent", "claude-code", "--force",
        "--seed", seed_file(step="replacement-step"))


def test_register_non_kebab_id_refused(cli, seed_file):
    proc = cli("register", "Not_Kebab", "--agent", "claude-code",
               "--seed", seed_file(), expect=1)
    assert "kebab-case" in proc.stderr


def test_register_invalid_seed_refused(cli, seed_file, store):
    proc = cli("register", "bad-seed", "--agent", "claude-code",
               "--seed", seed_file(schedule={"mode": "cron", "expr": "*"}),
               expect=1)
    assert "invalid seed" in proc.stderr
    assert not (store / "tasks" / "bad-seed").exists()


def test_register_terminal_seed_refused(cli, tmp_path):
    path = tmp_path / "terminal.json"
    path.write_text(json.dumps({"schema_version": 1, "step": "end"}))
    proc = cli("register", "terminal-task", "--agent", "claude-code",
               "--seed", str(path), expect=1)
    assert "terminal" in proc.stderr


def test_register_future_schema_refused(cli, seed_file):
    proc = cli("register", "future-task", "--agent", "claude-code",
               "--seed", seed_file(schema_version=2), expect=1)
    assert "unsupported schema_version" in proc.stderr


# ---------------------------------------------------------------- unregister

def test_unregister_happy_retains_data(cli, store, registered):
    cli("unregister", registered)
    assert registered not in json.loads(
        (store / "registry.json").read_text())["tasks"]
    assert (store / "tasks" / registered / "continuation.md").exists()


def test_unregister_unknown_task(cli):
    proc = cli("unregister", "ghost-task", expect=1)
    assert "unknown task" in proc.stderr


# ---------------------------------------------------------------------- list

def test_list_empty_store(cli):
    assert "no tasks registered" in cli("list").stdout


def test_list_shows_pending_due_state(cli, store, registered):
    cli("tick", "--dry-run")
    out = cli("list").stdout
    assert "it-task" in out and "single-run" in out
    assert "probe-step--01: pending" in out and "DUE" in out


def test_list_reports_unparseable_document(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir())
    doc = next((run / "continuations").glob("*.md"))
    doc.write_text("garbage, not a rendered document")
    assert "INVALID" in cli("list").stdout


# ---------------------------------------------------------------------- show

def test_show_seed_and_specific_continuation(cli, store, registered):
    assert '"step": "probe-step"' in cli("show", registered).stdout
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    out = cli("show", registered, "--run", run,
              "--continuation", "probe-step--01").stdout
    assert "## When to Continue" in out


def test_show_missing_document_fails(cli, registered):
    cli("show", registered, "--run", "20990101T000000Z",
        "--continuation", "nope--01", expect=1)


# ------------------------------------------------------------------ continue

def test_continue_happy_registers_child(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    out = cli("--actor", "agent-plugin", "continue", registered,
              "--run", run, "--from", "probe-step--01",
              stdin="All done.\n" + continuation_block(step="next-step")).stdout
    assert "next-step--01" in out
    entry = read_log(store)[-1]
    assert entry["cmd"] == "continue"
    assert entry["returned"] == ["next-step--01"]
    assert entry["summary"] == "All done."
    assert entry["actor"] == "agent-plugin"


def test_continue_fan_out_and_id_sequencing(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    text = ("Splitting.\n" + continuation_block(step="branch")
            + "\n" + continuation_block(step="branch"))
    out = cli("continue", registered, "--run", run,
              "--from", "probe-step--01", stdin=text).stdout
    assert "branch--01" in out and "branch--02" in out


def test_continue_zero_return_keeps_pending_and_counts_streak(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    for expected in (1, 2):
        cli("continue", registered, "--run", run, "--from", "probe-step--01",
            stdin="Still waiting on the world.")
        state = json.loads((store / "tasks" / registered / "runs" / run /
                            "continuations" / "probe-step--01.state.json").read_text())
        assert state["status"] == "pending"
        assert state["zero_return_streak"] == expected


def test_continue_terminal_ends_line(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    cli("continue", registered, "--run", run, "--from", "probe-step--01",
        stdin='Done.\n<CONTINUATION>{"schema_version": 1, "step": "end"}</CONTINUATION>')
    state = json.loads((store / "tasks" / registered / "runs" / run /
                        "continuations" / "probe-step--01.state.json").read_text())
    assert state["status"] == "ended"


def test_continue_mixed_valid_invalid_blocks(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    text = ("Partial.\n" + continuation_block(step="good-step")
            + "\n<CONTINUATION>{not json}</CONTINUATION>"
            + "\n<CONTINUATION>" + json.dumps(make_seed(schema_version=9)) + "</CONTINUATION>")
    cli("continue", registered, "--run", run, "--from", "probe-step--01",
        stdin=text)
    entry = read_log(store)[-1]
    assert entry["outcome"] == "partial"
    assert entry["returned"] == ["good-step--01"]
    assert len(entry["invalid_blocks"]) == 2


def test_continue_unknown_task_and_continuation(cli, registered, store):
    proc = cli("continue", "ghost-task", "--run", "r", "--from", "c",
               stdin="x", expect=1)
    assert "unknown task" in proc.stderr
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    proc = cli("continue", registered, "--run", run, "--from", "ghost--01",
               stdin="x", expect=1)
    assert "unknown continuation" in proc.stderr


# ---------------------------------------------------------------------- tick

def test_tick_dry_run_reports_and_spawns_nothing(cli, store, registered, tmp_path):
    capture = tmp_path / "capture.json"
    out = cli("tick", "--dry-run",
              env={"FAKE_AGENT_CAPTURE": str(capture)}).stdout
    assert "would evaluate" in out and "nothing due" not in out
    assert not capture.exists()


def test_tick_full_loop_via_fake_agent(cli, store, registered, tmp_path):
    response = tmp_path / "response.txt"
    response.write_text("Probed the thing; it finished.\n"
                        + continuation_block(step="report-step",
                                             schedule={"mode": "daily", "at": "23:59"}))
    capture = tmp_path / "capture.json"
    cli("tick", env={"FAKE_AGENT_RESPONSE": str(response),
                     "FAKE_AGENT_CAPTURE": str(capture)})
    # The fake agent ran in the run workspace with injected identifiers.
    captured = json.loads(capture.read_text())
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    assert captured["env"]["AGENTIC_TASK_ID"] == registered
    assert captured["env"]["AGENTIC_RUN_ID"] == run
    assert captured["env"]["AGENTIC_CONTINUATION_ID"] == "probe-step--01"
    assert captured["cwd"].endswith(f"runs/{run}")
    assert "rendered by agentic-continuation" in captured["prompt_head"]
    assert '"step": "probe-step"' in captured["prompt_head"]
    # Dispatcher fallback registered the returned child; source consumed.
    out = cli("list").stdout
    assert "probe-step--01: consumed" in out
    assert "report-step--01: pending" in out
    fallback = [e for e in read_log(store)
                if e["cmd"] == "continue" and e["actor"] == "dispatcher-fallback"]
    assert fallback and fallback[-1]["returned"] == ["report-step--01"]


def test_tick_not_due_schedule_skipped(cli, store, seed_file, fake_agent):
    cli("register", "later-task", "--agent", "claude-code",
        "--agent-command", fake_agent,
        "--seed", seed_file(schedule={"mode": "daily", "at": "23:59"}))
    assert "would evaluate" not in cli("tick", "--dry-run").stdout


def test_tick_single_run_settles_and_disables(cli, store, registered, tmp_path):
    response = tmp_path / "response.txt"
    response.write_text('Over.\n<CONTINUATION>{"schema_version": 1, "step": "end"}</CONTINUATION>')
    cli("tick", env={"FAKE_AGENT_RESPONSE": str(response)})
    registry = json.loads((store / "registry.json").read_text())
    assert registry["tasks"][registered]["enabled"] is False
    assert any(e["cmd"] == "tick.run-settled" for e in read_log(store))
    assert "would evaluate" not in cli("tick", "--dry-run").stdout


def test_tick_repetitive_task_reseeds_after_settle(cli, store, seed_file,
                                                   fake_agent, tmp_path):
    cli("register", "repeat-task", "--agent", "claude-code",
        "--agent-command", fake_agent, "--seed", seed_file())
    response = tmp_path / "response.txt"
    response.write_text('Cycle done.\n<CONTINUATION>{"schema_version": 1, "step": "end"}</CONTINUATION>')
    cli("tick", env={"FAKE_AGENT_RESPONSE": str(response)})
    cli("tick", env={"FAKE_AGENT_RESPONSE": str(response)})
    runs = list((store / "tasks" / "repeat-task" / "runs").iterdir())
    assert len(runs) == 2


def test_tick_missing_agent_binary_logged_stays_pending(cli, store, seed_file):
    cli("register", "broken-task", "--agent", "claude-code",
        "--agent-command", "/nonexistent/agent",
        "--seed", seed_file())
    cli("tick")
    entries = [e for e in read_log(store) if e.get("outcome") == "spawn-error"]
    assert entries and entries[-1]["task_id"] == "broken-task"
    assert "pending" in cli("list").stdout


def test_tick_quarantines_tampered_document(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir())
    doc = next((run / "continuations").glob("*.md"))
    doc.write_text("tampered — not a rendered document")
    cli("tick")
    state = json.loads(next((run / "continuations").glob("*.state.json")).read_text())
    assert state["status"] == "invalid"
    assert any(e.get("outcome") == "invalid-continuation" for e in read_log(store))


def test_tick_respects_run_lock(cli, store, registered, tmp_path):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir())
    (run / ".run-lock").write_text("held")
    capture = tmp_path / "capture.json"
    cli("tick", env={"FAKE_AGENT_CAPTURE": str(capture)})
    assert not capture.exists()


# ----------------------------------------------------------------- log/verify

def test_log_filters_by_task(cli, store, registered, seed_file):
    cli("register", "other-task", "--agent", "pi", "--seed", seed_file())
    out = cli("log", "--task", registered).stdout
    assert "other-task" not in out and registered in out


def test_log_empty_store(cli):
    assert "no log yet" in cli("log").stdout


def test_verify_reports_missing_and_present_paths(cli, store, registered,
                                                  tmp_path):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    artifact = tmp_path / "artifact.txt"
    artifact.write_text("evidence")
    cli("continue", registered, "--run", run, "--from", "probe-step--01",
        stdin="Done.\n" + continuation_block(
            step="verified-step",
            context=f"Wrote {artifact} and also /nonexistent/missing.bin."))
    proc = cli("verify", registered, expect=1)
    assert f"OK   {run}/verified-step--01: {artifact}" in proc.stdout
    assert "MISS" in proc.stdout
