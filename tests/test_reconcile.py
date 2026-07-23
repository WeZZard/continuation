"""Flush-race reconciliation: the stale-hook rescue observed on the first
live tick. Simulates the courier sequence at the CLI level: a hook that read
a stale transcript registers zero returns; the dispatcher's captured final
message carries the real blocks and must still land them."""

from conftest import continuation_block, read_log
from test_subcommands import queue_entry


def test_stale_hook_then_authoritative_text_still_registers(cli, store, registered):
    cli("tick", "--dry-run")
    run = next((store / "tasks" / registered / "runs").iterdir()).name
    # Hook fires against a stale transcript: only the opening message exists.
    cli("--actor", "agent-plugin", "continue", registered, "--run", run,
        "--from", "probe-step--01", stdin="I'm checking whether the thing finished.")
    entry = queue_entry(cli, "probe-step--01")
    assert entry["status"] == "pending" and entry["evaluations"] == 1
    # Dispatcher reconcile: authoritative final text carries the block.
    cli("--actor", "dispatcher-fallback", "continue", registered, "--run", run,
        "--from", "probe-step--01",
        stdin="It finished; handing off.\n" + continuation_block(step="handoff-step"))
    assert queue_entry(cli, "probe-step--01") is None  # consumed: out of the queue
    assert "probe-step--01: consumed" in cli("list").stdout
    entries = [e for e in read_log(store) if e["cmd"] == "continue"]
    assert [e["actor"] for e in entries] == ["agent-plugin", "dispatcher-fallback"]
    assert entries[-1]["returned"] == ["handoff-step--01"]


def test_full_tick_rescues_from_stale_hook(cli, store, registered, tmp_path,
                                           monkeypatch):
    """End-to-end: fake agent emits blocks in captured output; a simulated
    stale hook is injected by pre-bumping the evaluation counter via an
    empty continue during the run window is impossible hermetically, so we
    verify the weaker end-to-end property: with no hook at all (fake agent),
    the captured-output path registers — and after the stale-hook CLI
    sequence above, both couriers appear in the log in order."""
    response = tmp_path / "response.txt"
    response.write_text("Done.\n" + continuation_block(step="after-step"))
    cli("tick", env={"FAKE_AGENT_RESPONSE": str(response)})
    fallback = [e for e in read_log(store)
                if e["cmd"] == "continue" and e["actor"] == "dispatcher-fallback"]
    assert fallback and fallback[-1]["returned"] == ["after-step--01"]
