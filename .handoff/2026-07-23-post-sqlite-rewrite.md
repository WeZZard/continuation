# Handoff — agentic-continuation, remaining work (2026-07-23)

Written for the next Claude Code session launched **in this repository**.
Prior work happened from the `jlens-app` session; this document is the
complete transfer of what is done, what is pending, and which decisions are
settled versus open.

## State snapshot

- HEAD: `a38058a` — "THE QUEUE as single source of truth — SQLite, one
  table, status transitions". Working tree clean.
- Tests: 56 passing. Run with:
  `uv run --no-project --with pytest pytest tests/ -q`
  (system `/usr/bin/python3` has no pytest; the tool itself is
  zero-dependency stdlib and must stay that way).
- Live store: `~/.local/share/agentic-continuation/` — already **migrated**
  to `store.db` (WAL). `registry.json.imported` is the disarmed legacy
  registry; legacy run files remain on disk as workspaces/archives.
- One real task is registered and load-bearing: see "Live task" below.

## What is DONE (do not redo)

- The CLI (`bin/agentic-continuation`): register / unregister / list / show /
  continue / tick / queue / log / verify / migrate / install-launchd /
  uninstall-launchd.
- Storage: one `queue` table as the single source of truth; completion is a
  status transition (`pending → consumed | ended | expired | invalid`);
  activations materialized at write time; consume-and-insert-children is one
  ACID transaction. Supporting tables: `tasks`, `runs` (lease columns),
  `events` (audit; autoincrement id doubles as a live-update cursor).
  `log.jsonl` is a derived mirror of `events` — export, never truth.
- Documents are rendered on demand (never stored state); each spawn archives
  its exact prompt as `tasks/<id>/runs/<run>/prompt--<cid>--<n>.md`.
- Claude Code plugin (`plugins/claude-code`): Stop-hook courier pipes the
  final message to `continue`; env-guarded (inert outside tool spawns);
  dispatcher post-exit fallback covers hook-never-ran AND hook-read-stale-
  transcript (both observed live). `pi` adapter exists but is untested live.
- Explicit `migrate` (already executed on the live store) with a loud
  refusal guard on every other subcommand while a legacy store exists.

## IMMEDIATE item — user action, blocks everything downstream

`install-launchd` has **never been run**. Until the user runs

```bash
bin/agentic-continuation install-launchd
```

no tick ever fires and the live task never evaluates. Assistant sessions are
policy-blocked from installing persistence (LaunchAgents) — hand the command
to the user; do not attempt it via Bash. Health-check afterwards:
`launchctl list | grep agentic-continuation` (empty output = not running).

## Next phase — queue server + mobile app (NOT DESIGNED YET)

The user's stated next step: a macOS server plus a mobile phone app to
examine the queue (continuations, details, history) and manage the daemon.

- **Nothing about it is decided.** A previous attempt to settle app form /
  transport via an options-question was rejected mid-ask. Do not re-ask it;
  raise design points as open discussion, and expect several rounds.
- The only primitives agreed because they shaped the storage design:
  the server reads the same `store.db` (WAL allows concurrent readers while
  the CLI writes), and `events.id` is the cursor for live updates (SSE-like
  tailing).
- Open, undecided: transport/exposure (LAN? Tailscale? tunnel?), auth, app
  form (native vs web), write surface (read-only vs controls: pause task,
  retry entry, daemon start/stop), and how daemon control maps onto launchd.

## Parked / deferred (acknowledged, not scheduled)

- **Sandbox enforcement**: `--allow-write` / `--allow-net` are recorded per
  task with `enforced: false`. Anthropic's `srt` runtime is the intended
  enforcer; it is not installed, and macOS `sandbox-exec` is deprecated.
  Today the policy is documentation + audit only.
- **Blast-radius hardening**: the whole store was once deleted externally
  (Jul 23 early AM incident, recovered from a /tmp copy of the continuation
  core). Ideas raised but never ruled on: `backup` subcommand
  (`VACUUM INTO`), store-as-git, mirror log outside the store directory.
- **Per-task agent timeout**: spawn timeout is hardcoded 3600s; there is no
  `timeout_seconds` column. Add only when a task needs it.
- **`verify` is a v1 heuristic** (regex for paths in `context`, stat them).
- Legacy `tasks/<id>/continuation.md` files linger post-migration; harmless,
  never read. Old event name `tick.break-stale-lock` appears in imported
  history; the live code emits `tick.break-stale-lease`.

## Settled design rulings — do NOT re-litigate

1. THE QUEUE is the single source of truth: a persisted first-class
   structure. Never reconstruct it by scanning files; no hybrid
   file-truth/DB-index designs (explicitly condemned as "dual-truth").
2. SQLite, **one** queue table; completing an entry is a status transition,
   never a row moving between tables (explicit user ruling).
3. This is NOT a DAG. A run's evaluation returns zero/one/a tuple of
   continuations — like functions returning functions. Cycles are legal;
   no join/edge/acyclicity machinery.
4. The term is **continuation** everywhere. "Seed" is abolished.
5. The CLI is the single writer. Agents only RETURN `<CONTINUATION>` blocks
   in their final message; they never write store state.
6. Documents are synthesized: program constants (instruction, schema
   vocabulary, principles) are never agent-generated; agent influence is
   limited to the 7 core fields. `<REGISTRY>` block leads every document.
7. Continuation cores carry `schema_version` (currently 2; {1,2} accepted);
   any grammar change bumps the edition; unknown editions are quarantined
   loudly (status `invalid`), never reinterpreted.
8. Agent transcripts stay in agent homes. Run dirs hold workspaces and
   prompt archives only. Events store session references, not copies.
9. Zero dependencies: `/usr/bin/python3` + launchd. stdlib only.
10. Atomicity by primitive (transactions), not by protocol (lock files,
    commit-point orderings). That war is over; the file store lost.

## Process norms this user enforces (violations caused real friction)

- **Discuss design before implementing.** Twice this project, implementation
  started while the user considered the discussion still open, and both
  times the work was discarded on principle ("may introduce hallucination").
  When a design conversation is running, the deliverable is the discussion —
  build only after an explicit go ("go with X" style ruling).
- Options-form questions (AskUserQuestion) about design have been rejected;
  present positions and recommendations in prose instead.
- Task records live in this tool, not in `~/CLAUDE.md` (that file holds only
  the pointer section "Agentic Continuation").
- New recurring agent workflows MUST register here, not as bespoke
  wrapper+plist pairs.

## Live task (load-bearing — treat with care)

`jlens-mobile-lens-ab` — single-run, agent claude-code. Collects and
adjudicates the A/B lens-fit experiment running on two LAN Mac minis
(192.168.50.4 = mixture corpus, 192.168.50.5 = WikiText control; both
`~/jlens-fit`, detached nohup+caffeinate). As of 2026-07-23 09:43 both are
at prompt 119/1000, ~12.1 min/prompt, ETA cap ≈ Jul 31 (earlier on
convergence). Details: `RUNNING_EXPERIMENTS.md` in the `jlens-app` repo.

- Schedule: every 12h once ticking (blocked on `install-launchd` above).
- Task MUST NOTs (recorded in the registry): never kill / restart /
  re-launch the fitting jobs on the minis — reading their logs and
  completed artifacts is allowed; never push to any git remote.
- Inspect: `bin/agentic-continuation queue` / `list` /
  `log --task jlens-mobile-lens-ab`.

## Known behaviors worth remembering

- A tick's due-threshold must be read AFTER `start_run` (a `"now"`-mode
  entry materializes its activation from a later clock read; taking `now`
  at loop top made fresh entries invisible — fixed, regression-tested).
- The stale-transcript reconcile intentionally allows one double-counted
  evaluation during a rescue; the events log shows both couriers.
- `run_is_settled` treats `expired`/`invalid` as holding the run open
  (a "run complete" notification would otherwise lie).
