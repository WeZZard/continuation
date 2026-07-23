# Handoff — requirement: `update` command; forbid direct JSON writing (2026-07-23)

Ruling from WeZZard, verbatim intent: **the registry needs an `update`
command, and direct JSON writing shall be forbidden.** This file records the
requirement and its motivating incident for the next session in this repo.
Read `.handoff/2026-07-23-post-sqlite-rewrite.md` first for full state.

## The requirement

Correcting a registered continuation must be a first-class CLI operation.
Today it is not: the only paths are

- hand-authoring a raw `<CONTINUATION>` JSON block and piping it through
  `continue` (a manual evaluation returning the corrected successor), or
- `register --force` / unregister-and-re-register surgery (which the
  single-run re-arm trap makes impossible without a new task id).

Both make a human write raw JSON by hand. That is the thing being
forbidden: **no workflow may require a person to author or edit
continuation JSON directly.** The CLI must offer an `update` command (exact
surface to be designed WITH the user — do not implement before that
discussion concludes).

## Motivating incident (2026-07-23)

The `jlens-mobile-lens-ab` task was registered with a wrong schedule:
`{"mode":"every","amount":12,"unit":"h"}` — a 12h agent-spawning poll —
when the intent was "invoke once when the lens fitting completes." The fit
job has no completion hook, but its end is bounded by the prompt cap, so
the correct schedule was the existing `at` primitive at the cap ETA.

The fix that actually landed (and is live now) used the system's native
mechanism: a manual `continue` consumed `collect-and-adjudicate-ab-fits--01`
and returned `--02` with `{"mode":"at","datetime":"2026-07-31 09:00"}`,
same task, same run, rationale recorded in the events log. Correct
semantics, good audit — but the successor block was hand-written JSON,
which is exactly the workflow to eliminate.

## Constraints already settled (do not violate while designing)

- Continuations are values; history is never edited in place. An update is
  a recorded transition (the consume-and-replace shape above is the natural
  candidate: same run, source consumed with a reason, corrected successor
  registered — one ACID transaction, one audit event).
- The CLI remains the single writer; every transition lands in `events`.
- The queue table stays the single source of truth.
- Schema validation applies to the updated value exactly as to a new one.

## Open design questions for the session (discuss first — hard norm)

1. Surface: field-level flags (`update <task> --schedule '{"mode":"at",...}'`,
   `--task-text ...`, `--stop ...` repeatable), or fetch-edit-apply with the
   tool rendering an editable form? Either way the human never touches raw
   store JSON; the tool composes, validates, and records the value.
2. Scope: update the task-level continuation (affects future runs), a
   pending queue entry (the live case), or both — and how the command names
   distinguish them.
3. Whether `register` keeps accepting a JSON file/stdin (machine callers
   need it) while human-facing paths get the structured surface — i.e., is
   "forbidden" a UX rule (no workflow requires it) or a hard gate.
4. The single-run re-arm trap (documented in the previous handoff) is
   adjacent: an `update` on a pending entry sidesteps it, but decide
   whether re-arm deserves its own primitive or stays impossible.

## Current live state (context, do not disturb)

Queue holds exactly one entry: `jlens-mobile-lens-ab / 20260722T205958Z /
collect-and-adjudicate-ab-fits--02`, pending,
`{"mode":"at","datetime":"2026-07-31 09:00"}`, evaluations 0. It fires only
if the dispatcher is ticking by then (`install-launchd` — user action,
still not run).
