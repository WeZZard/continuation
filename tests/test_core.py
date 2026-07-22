"""Pure-function tests: schema validation, schedules, extraction, rendering."""

import importlib.util
import json
from datetime import datetime
from importlib.machinery import SourceFileLoader
from pathlib import Path

_loader = SourceFileLoader(
    "ac", str(Path(__file__).resolve().parent.parent / "bin" / "agentic-continuation"))
_spec = importlib.util.spec_from_loader("ac", _loader)
ac = importlib.util.module_from_spec(_spec)
_loader.exec_module(ac)


def make_core(**overrides):
    core = {
        "schema_version": 2,
        "step": "collect-results",
        "task": "Check the thing.",
        "when_to_stop": ["Thing still running — stop, return nothing."],
        "when_to_continue": "When the thing is done, return the next step.",
        "context": "Launched yesterday.",
        "schedule": {"mode": "every", "amount": 12, "unit": "h"},
    }
    core.update(overrides)
    return core


def test_valid_core_passes():
    assert ac.validate_core(make_core()) is None


def test_terminal_block_passes():
    assert ac.validate_core({"schema_version": 2, "step": "end"}) is None


def test_unknown_schema_version_refused():
    problem = ac.validate_core(make_core(schema_version=3))
    assert "unsupported schema_version" in problem


def test_extra_key_refused():
    core = make_core()
    core["surprise"] = "x"
    assert ac.validate_core(core) is not None


def test_non_kebab_step_refused():
    assert ac.validate_core(make_core(step="Not Kebab")) is not None


def test_schedule_variants():
    assert ac.validate_schedule({"mode": "now"}) is None
    assert ac.validate_schedule({"mode": "daily", "at": "09:03"}) is None
    assert ac.validate_schedule({"mode": "at", "datetime": "2026-07-24 09:00"}) is None
    assert ac.validate_schedule({"mode": "every", "amount": 0, "unit": "h"}) is not None
    assert ac.validate_schedule({"mode": "cron", "expr": "* * * * *"}) is not None
    assert ac.validate_schedule({"mode": "now", "extra": 1}) is not None


def test_due_semantics():
    now = datetime(2026, 7, 23, 10, 0)
    assert ac.schedule_due({"mode": "now"}, None, now)
    every = {"mode": "every", "amount": 12, "unit": "h"}
    assert ac.schedule_due(every, None, now)
    assert not ac.schedule_due(every, datetime(2026, 7, 23, 0, 0), now)
    assert ac.schedule_due(every, datetime(2026, 7, 22, 20, 0), now)
    daily = {"mode": "daily", "at": "09:00"}
    assert ac.schedule_due(daily, datetime(2026, 7, 22, 9, 30), now)
    assert not ac.schedule_due(daily, datetime(2026, 7, 23, 9, 30), now)
    once = {"mode": "at", "datetime": "2026-07-23 09:00"}
    assert ac.schedule_due(once, datetime(2026, 7, 22, 8, 0), now)
    assert not ac.schedule_due(once, datetime(2026, 7, 23, 9, 30), now)


def test_extraction_tuple_and_errors():
    text = (
        "Did the work.\n"
        "<CONTINUATION>" + json.dumps(make_core(step="branch-a")) + "</CONTINUATION>\n"
        "<CONTINUATION>" + json.dumps(make_core(step="branch-b")) + "</CONTINUATION>\n"
        "<CONTINUATION>{not json}</CONTINUATION>\n"
    )
    cores, errors = ac.extract_blocks(text)
    assert [core["step"] for core in cores] == ["branch-a", "branch-b"]
    assert len(errors) == 1


def test_render_parse_roundtrip():
    core = make_core()
    doc = ac.render_document(core, ["touch the fits on the minis"])
    parsed = ac.parse_document_core(doc)
    assert parsed == core
    # The schema block inside <TASK> must not confuse the core parser.
    assert doc.count("<CONTINUATION>") >= 3
    # Task-scoped rule rendered with the house prefix.
    assert "You **MUST NOT** touch the fits on the minis" in doc


def test_render_is_deterministic():
    core = make_core()
    assert ac.render_document(core, []) == ac.render_document(core, [])


def test_edition_1_still_accepted():
    assert ac.validate_core(make_core(schema_version=1)) is None


def test_edition_2_allows_empty_when_to_continue():
    assert ac.validate_core(make_core(when_to_continue="")) is None


def test_edition_1_refuses_empty_when_to_continue():
    problem = ac.validate_core(make_core(schema_version=1, when_to_continue=""))
    assert "schema_version 1" in problem


def test_registry_block_is_first_tag():
    doc = ac.render_document(make_core(), [])
    assert doc.startswith("<REGISTRY>")
    assert "You are evaluating a registered continuation" in doc


def test_terminal_task_document_omits_return_vocabulary():
    doc = ac.render_document(make_core(when_to_continue=""), [])
    assert "## Completion" in doc
    assert "## Continuation" not in doc
    assert "## When to Continue" not in doc
    assert '{ "schema_version": 2, "step": "end" }' in doc


def test_legacy_top_continuation_layout_still_parses():
    core = make_core(schema_version=1)
    legacy = ("<CONTINUATION>\n" + json.dumps(core) + "\n</CONTINUATION>\n\n"
              "<TASK>\nbody\n</TASK>\n")
    assert ac.parse_document_core(legacy) == core
