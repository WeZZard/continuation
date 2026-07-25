# continuation (agentic-continuation)

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
- Debugging the app means the DEBUG build, through
  `app/scripts/run-debug.sh` (rebuilds the debug bundle, deploys it to
  `/Applications/Continuation-Debug.app` — the debug app's home since
  2026-07-25, the user walks through the same copy — replaces the
  running instance, logs to `/tmp/continuation-debug.log`).
- Installing/loading launchd jobs on this Mac is fine when the user asks
  (an earlier session wrongly recorded a blanket prohibition — the user
  disavowed it 2026-07-24). The minis' `--daemon` installs require the
  user's sudo password and therefore genuinely need their hands.

## Working on it

- Tests: `uv run --no-project --with pytest pytest tests/ -q`
- Live store: `~/.local/share/agentic-continuation/` (override with
  `AGENTIC_CONTINUATION_STORE`; tests use temp stores automatically).
- Inspect: `bin/continuation queue | list | log | show` (the CLI was
  renamed 2026-07-24; `bin/agentic-continuation` remains a compat symlink
  because installed launchd plists reference it).
- The registered task `jlens-mobile-lens-ab` is real and load-bearing; its
  MUST NOTs (never touch the fitting jobs on the Mac minis, never push to
  git remotes) are recorded in the registry — honor them in any manual test.
- Hooks not firing is usually not the plugin: Claude Code skips ALL hook
  execution in a workspace whose trust was never accepted
  (`projects.<dir>.hasTrustDialogAccepted` in `~/.claude.json`, read at
  startup). Confirm with `claude --debug` and grep the named log for
  `trust` before touching hook code — this repo itself was untrusted
  until 2026-07-26 and no console hook had ever run in it.
- Probe a hook end to end with `CONTINUATION_HOOK_LOG=/tmp/x`; launch the
  probe with stdin held open (`sleep 30 | script -q /dev/null claude …`),
  since an immediate EOF declines whatever dialog is waiting.
- The CLI and console plugin that sessions actually run are the copies
  materialized under Application Support, not the repo — the app
  refreshes them on launch when its payload changes. After editing
  either, redeploy (`app/scripts/run-debug.sh`) before testing against a
  real session, or you are testing a version skew.
