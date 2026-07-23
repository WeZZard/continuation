# agentic-continuation

A continuation-passing scheduler for agent tasks. Read `README.md` for the
model; read the newest document in `.handoff/` **before doing anything** —
it carries the current state, pending work, and the settled design rulings.

## Hard rules

- THE QUEUE (the `queue` table in `store.db`) is the single source of truth.
  Never derive state by scanning files; never introduce a second truth.
- One queue table; completing an entry is a status transition, never a row
  moving between tables. Multi-item transitions are single ACID transactions.
- Not a DAG: evaluation returns zero/one/a tuple of continuations; cycles
  are legal. The term is "continuation" — never "seed".
- The CLI is the single writer. Dispatcher-spawned agents only RETURN
  `<CONTINUATION>` blocks; interactive sessions dispatch new tasks only
  through `register` via the `continuation:schedule` skill after explicit
  user approval — never through `continue`/`tick`, never via HTTP.
- Zero dependencies: `/usr/bin/python3` stdlib + launchd. Keep it that way.
- Discuss design with the user before implementing; build only after an
  explicit go. Present design options in prose, not option-forms.
- Installing/loading launchd jobs on this Mac is fine when the user asks
  (an earlier session wrongly recorded a blanket prohibition — the user
  disavowed it 2026-07-24). The minis' `--daemon` installs require the
  user's sudo password and therefore genuinely need their hands.

## Working on it

- Tests: `uv run --no-project --with pytest pytest tests/ -q`
- Live store: `~/.local/share/agentic-continuation/` (override with
  `AGENTIC_CONTINUATION_STORE`; tests use temp stores automatically).
- Inspect: `bin/agentic-continuation queue | list | log | show`.
- The registered task `jlens-mobile-lens-ab` is real and load-bearing; its
  MUST NOTs (never touch the fitting jobs on the Mac minis, never push to
  git remotes) are recorded in the registry — honor them in any manual test.
