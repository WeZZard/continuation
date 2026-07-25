#!/usr/bin/env python3
"""The console channel between this agent session and Continuation.

Raise a review item when the session needs the human (a question, a
plan, a stop), hold the tool call while the review console decides,
deliver the decision back into the session, and clear items the session
resolves on its own. Every write goes through the `continuation` CLI —
the single writer.

Dispatcher-spawned sessions belong to the scheduler, never to the review
box: AGENTIC_TASK_ID guards them out. A machine without the CLI stays
silent — this hook never breaks a session.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys


def find_cli() -> str | None:
    explicit = os.environ.get("CONTINUATION_BIN")
    if explicit and os.access(explicit, os.X_OK):
        return explicit
    found = shutil.which("continuation")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/bin/continuation")
    if os.access(fallback, os.X_OK):
        return fallback
    return None


def run_cli(cli: str, args: list, stdin: str | None = None,
            timeout: float = 30):
    return subprocess.run(
        [cli, "--actor", "console-hook", *args],
        input=stdin, text=True, capture_output=True, timeout=timeout)


def ensure_session(cli: str, session: str, cwd: str, source: str = "") -> None:
    """Register the session on ANY event, not only SessionStart.

    Claude Code dispatches SessionStart before a --plugin-dir plugin has
    finished loading (observed 2026-07-26: the event never reaches the
    hook, while every later event does), so presence has to heal itself
    from whatever event arrives first. `session start` is an upsert and
    keeps the original start time.
    """
    run_cli(cli, ["session", "start", "--session", session,
                  "--cwd", cwd, "--source", source])


def wait_seconds() -> float:
    try:
        return float(os.environ.get("CONTINUATION_REVIEW_WAIT", "300"))
    except ValueError:
        return 300.0


def emit(permission: str, reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": permission,
        "permissionDecisionReason": reason,
    }}))


def pre_tool_use(cli: str, data: dict, session: str, cwd: str) -> int:
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    if tool == "AskUserQuestion":
        kind = "question"
        questions = tool_input.get("questions") or []
        summary = (questions[0].get("question", "")
                   if questions else "Question")[:200]
    elif tool == "ExitPlanMode":
        kind = "plan"
        plan = (tool_input.get("plan") or "").strip()
        summary = (plan.splitlines()[0] if plan else "Plan ready")[:200]
    else:
        return 0

    raised = run_cli(cli, ["review", "raise", "--session", session,
                           "--kind", kind, "--cwd", cwd,
                           "--summary", summary, "--payload", "-"],
                     stdin=json.dumps(tool_input))
    if raised.returncode != 0:
        return 0
    review_id = raised.stdout.strip()

    seconds = wait_seconds()
    try:
        waited = run_cli(cli, ["review", "wait", review_id,
                               "--timeout", str(seconds)],
                         timeout=seconds + 15)
    except subprocess.TimeoutExpired:
        return 0
    if waited.returncode != 0:
        # Timed out or cleared: the terminal takes over; PostToolUse
        # clears the item once the human answers there.
        return 0
    try:
        decision = json.loads(waited.stdout)
    except json.JSONDecodeError:
        return 0

    if kind == "question":
        answers = decision.get("answers") or {}
        lines = "\n".join(f"- {question}: {answer}"
                          for question, answer in answers.items())
        emit("deny",
             "The user answered through the Continuation review console:\n"
             + lines
             + "\nProceed with these answers; do not ask again.")
    elif decision.get("approve"):
        emit("allow", "Plan approved in the Continuation review console.")
    else:
        feedback = (decision.get("feedback") or "").strip()
        emit("deny",
             "The user reviewed the plan in the Continuation review console"
             + (f" and requests changes:\n{feedback}" if feedback
                else " and requests changes."))
    return 0


def main() -> int:
    if os.environ.get("AGENTIC_TASK_ID"):
        return 0
    cli = find_cli()
    if cli is None:
        return 0
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    event = data.get("hook_event_name", "")
    session = data.get("session_id", "")
    cwd = data.get("cwd", "")
    if not session:
        return 0

    if event == "SessionEnd":
        run_cli(cli, ["review", "clear", "--session", session])
        run_cli(cli, ["session", "end", "--session", session])
        return 0

    # Everything else means the session is alive: make it discoverable.
    ensure_session(cli, session, cwd, data.get("source", ""))

    if event == "SessionStart":
        run_cli(cli, ["review", "clear", "--session", session])
        return 0
    if event == "PreToolUse":
        return pre_tool_use(cli, data, session, cwd)
    if event == "PostToolUse":
        kind = {"AskUserQuestion": "question",
                "ExitPlanMode": "plan"}.get(data.get("tool_name", ""))
        if kind:
            run_cli(cli, ["review", "clear", "--session", session,
                          "--kind", kind])
        return 0
    if event == "Stop":
        run_cli(cli, ["review", "clear", "--session", session])
        run_cli(cli, ["review", "raise", "--session", session,
                      "--kind", "stopped", "--cwd", cwd,
                      "--summary", "Waiting for your next message"])
        return 0
    if event == "UserPromptSubmit":
        run_cli(cli, ["review", "clear", "--session", session])
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
