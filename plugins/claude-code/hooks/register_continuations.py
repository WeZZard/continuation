#!/usr/bin/env python3
"""Stop hook: pass the agent's returned continuations to the CLI.

Reads the hook payload from stdin (transcript_path), pulls the final
assistant message's text from the transcript, and hands it to
`agentic-continuation continue` — which extracts, validates, registers,
and logs. The hook itself never writes store files and never blocks the
stop; if anything fails here, the dispatcher's post-exit fallback repeats
the extraction from the captured final message.
"""

import json
import os
import subprocess
import sys


def final_assistant_text(transcript_path: str) -> str:
    text = ""
    try:
        with open(transcript_path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                message = entry.get("message") or {}
                if message.get("role") != "assistant":
                    continue
                parts = message.get("content")
                if isinstance(parts, str):
                    text = parts
                elif isinstance(parts, list):
                    joined = "".join(
                        part.get("text", "")
                        for part in parts
                        if isinstance(part, dict) and part.get("type") == "text"
                    )
                    if joined.strip():
                        text = joined
    except OSError:
        pass
    return text


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    task_id = os.environ.get("AGENTIC_TASK_ID")
    run_id = os.environ.get("AGENTIC_RUN_ID")
    from_id = os.environ.get("AGENTIC_CONTINUATION_ID")
    cli = os.environ.get("AGENTIC_CLI")
    if not all((task_id, run_id, from_id, cli)):
        return 0  # not spawned by agentic-continuation — do nothing
    text = final_assistant_text(payload.get("transcript_path", ""))
    if not text:
        return 0
    subprocess.run(
        [
            "/usr/bin/python3", cli, "--actor", "agent-plugin",
            "continue", task_id, "--run", run_id, "--from", from_id,
            "--session-ref", payload.get("session_id", ""),
        ],
        input=text, text=True, capture_output=True, timeout=120,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
