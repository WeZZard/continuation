---
name: schedule
description: Schedule work with the continuation scheduler on this Mac (macOS only). Use when work should happen later, on a schedule, or recur — nightly checks, polling until a condition holds, deferred follow-ups, multi-step lines of work that outlive this session — instead of waiting in-session or inventing bespoke launchd timers.
---

# Schedule a continuation

Hand a line of work to the continuation scheduler by registering a
task whose continuation the dispatcher evaluates on its own schedule. Your
whole job is to author a **continuation core** (a small JSON value) and pass
it to the CLI — the CLI is the single writer of scheduler state. You never
write anything under its store.

```bash
BIN="${CONTINUATION_BIN:-$(command -v continuation)}"
```

The CLI on PATH is the contract — the skill carries no machine paths, and
`CONTINUATION_BIN` lets a development session point at a checkout without
relinking. If neither resolves, the tool is not installed here: stop and
tell the user to clone the repo and link it, e.g.
`ln -sfn "<repo>/bin/continuation" ~/.local/bin/continuation`.

## When NOT to use this

- **You were spawned by the scheduler.** If `AGENTIC_TASK_ID` is set in
  your environment, this session IS an evaluation of a registered
  continuation. Do not register anything here; return `<CONTINUATION>`
  blocks in your final message exactly as your prompt's document instructs.
- **The user wants the work now.** Just do it in-session.

## Steps

1. **Preflight.** Resolve `BIN` as above — no CLI, no dispatch. Then
   `launchctl list | grep agentic-continuation` — if that prints nothing,
   the scheduler is not ticking on this machine: registration still lands
   in the queue, but nothing will evaluate it. Tell the user and point at
   `"$BIN" install-launchd`.

2. **Fetch the grammar.** Run `"$BIN" authoring` and follow it exactly.
   Never author a core from memory: the CLI is the single truth for the
   current schema edition, and this skill deliberately carries no copy.

3. **Draft.** Pick a kebab-case task id; the agent to run it
   (`claude-code` or `pi`); whether it is `--single-run` (one line of work,
   disables itself when settled) or repetitive (restarts from the task
   core each time a run settles); and task-scoped `--must-not` rules —
   things the scheduled agent must never do, e.g. "push to any git remote".
   Then author the core per the `authoring` output.

4. **Get approval.** Registering is a lasting side effect: it spawns agents
   on a schedule until the task settles or is unregistered. Show the user
   the drafted core plus task id, agent, run mode, and MUST NOT rules, and
   register only after they approve. Running non-interactively with no
   user to ask: do **not** register — put the drafted core and the exact
   register command in your final message instead.

5. **Register**, core on stdin, yourself as the actor:

   ```bash
   printf '%s' "$CORE_JSON" | "$BIN" --actor interactive-agent \
     register <task-id> --agent claude-code --continuation - \
     --must-not "..." [--single-run]
   ```

6. **Confirm.** `"$BIN" queue` shows the new entry and its activation;
   report both to the user. The undo is `"$BIN" unregister <task-id>`.

## Hard rules

- Never write or edit files under the scheduler's store
  (`~/.local/share/agentic-continuation/`).
- Never invoke the `continue` or `tick` subcommands — those belong to the
  dispatcher and its Stop-hook plugin, not to interactive sessions.
- Never register without the user's explicit approval of the draft.
