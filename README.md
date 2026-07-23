# agentic-continuation

A continuation-passing scheduler for agent tasks. Evaluating a task's
continuation returns zero, one, or a tuple of continuations — like a function
returning functions — and this tool is the trampoline that consumes them.

## Model

- A **task** (kebab-case id) has a task-level **continuation** and **runs**; each
  run is a flat set of **continuations** (values, not a graph — cycles and
  fan-out are both legal because nothing constrains them).
- A **continuation document** is synthesized by this program: the agent-
  influenced parts are only the seven core fields; every rule, schema
  instruction, and section heading is a program constant. Task-scoped
  MUST NOT rules come from the registry at registration time.
- The **schedule lives in the continuation** (versioned schema:
  `now` / `every` / `daily` / `at`). launchd only ticks the dispatcher every
  30 minutes; due-ness is computed from each continuation's own schedule.
- The agent **returns** continuations as `<CONTINUATION>` JSON blocks in its
  final message. The Claude Code Stop-hook plugin (or the dispatcher's
  post-exit fallback, which also covers `pi`) hands that message to
  `continue`, the CLI validates against the versioned schema and registers.
  **The CLI is the single writer**, and every subcommand invocation is
  recorded in the `events` table with injected task/run/continuation ids.
- **THE QUEUE is the single source of truth**: one SQLite table. An entry
  lives there forever; completing it is a status transition
  (`pending → consumed | ended | expired | invalid`), never a row moving
  between tables. Activation times are materialized at write time, so
  due-selection and ordering are reads of a column. Consuming an entry and
  inserting its returned children is one ACID transaction — mixed states
  are unrepresentable.
- Returning nothing keeps a continuation scheduled (that is how a step waits
  for the world); the terminal block `{"schema_version": 2, "step": "end"}`
  ends a line of work; a run is **settled** when every entry is consumed or
  ended (`expired` / `invalid` entries hold it open for a human). Single-run
  tasks disable themselves when settled; repetitive tasks start a fresh run
  from the task continuation on the next tick.
- **Observability**: `queue` (THE queue: due / scheduled / needs-attention,
  in activation order, `--json` for machines), `list` (per-task runs and
  entry states), `log` (the audit trail, filterable), `show` (documents,
  rendered on demand), `verify` (claimed artifact paths exist), Things 3
  todos on run-complete / failure / possibly-stuck.

## Quick start

```bash
BIN=~/Artifacts/Repositories/com.github/WeZZard/agentic-continuation/bin/agentic-continuation

# Register a task from a continuation core (7-key JSON)
$BIN register my-task --agent claude-code --single-run \
  --must-not "push to any git remote" \
  --continuation continuation.json

$BIN queue                   # THE queue: due / scheduled / needs attention
$BIN list
$BIN tick --dry-run          # what would run now
$BIN tick                    # evaluate due continuations once
$BIN install-launchd         # tick every 30 min from launchd
$BIN log --task my-task      # the audit trail

$BIN serve                   # node API: read-only HTTP + SSE on :7787
$BIN install-serve-launchd   # keep the node API running from launchd
```

## Node API (protocol v1)

`serve` exposes this store to fleet clients — the macOS app first, peer
nodes later. Versioned under `/v1/`, JSON over HTTP, plus an SSE tail:

| Endpoint | Returns |
|---|---|
| `GET /v1/node` | Identity + health: node id (a ULID minted once into `meta`), hostname, version, accepted schema editions, last tick, tick-agent state, queue counts |
| `GET /v1/queue` | The queue exactly as `queue --json` reports it |
| `GET /v1/tasks`, `/v1/tasks/<id>` | Registry; task detail carries runs and their entries |
| `GET /v1/tasks/<id>/runs/<run>/prompts[/<name>]` | Archived prompts of each spawn |
| `GET /v1/log?task=&run=&after=&limit=` | Event rows (`after` pages forward by `events.id`) |
| `GET /v1/events?after=<id>` | SSE stream of new events; `Last-Event-ID` resumes |

Request handling opens the database **read-only** — writes stay the CLI's
alone. Authentication is an exposure-layer concern by design: LAN trust
today, an authenticating edge (e.g. Cloudflare Access) when public; the
protocol itself carries none. On Macs the server advertises itself over
Bonjour as `_agentic-cont._tcp` via the system `dns-sd`.

## macOS app

`app/` — "Continuations", a SwiftUI fleet manager over the node protocol
(SwiftPM; `ContinuationsKit` holds the models, HTTP+SSE client, Bonjour
discovery, and fleet store, ready for the iOS port). It aggregates every
node's queue into one unified list; each node's `store.db` stays the only
truth, offline nodes show their last-seen snapshot labeled "as of".

```bash
cd app
swift test                  # end-to-end against a real `serve` on a temp store
scripts/bundle.sh           # builds dist/Continuations.app
```

Building needs a full Xcode (`DEVELOPER_DIR` is auto-detected by the
bundle script); plain CommandLineTools cannot drive swift-build.

## Store

`~/.local/share/agentic-continuation/` (override:
`AGENTIC_CONTINUATION_STORE`):

- `store.db` — THE store (SQLite, WAL): the `queue` table (single source of
  truth), plus `tasks` (registry), `runs` (workspaces + evaluation leases),
  and `events` (audit trail; its autoincrement id is a live-update cursor).
- `log.jsonl` — derived mirror of `events` for grep and git. Export, never
  truth.
- `tasks/<id>/runs/<run>/` — the run workspace: agent cwd plus an archived
  copy of every prompt actually sent (`prompt--<cid>--<n>.md`). Documents
  are otherwise not state — `show` renders them on demand from the queue.

Agent transcripts stay in each agent's own home; events store session
references, not copies. A pre-SQLite file store is imported once with
`$BIN migrate`; every other subcommand refuses loudly until that has run.

## Sandbox policy

`--allow-write` / `--allow-net` are recorded per task in the registry.
Enforcement is **not wired in v1** (Anthropic's `srt` sandbox runtime is the
intended enforcer once installed); today the declared policy is documentation
plus audit — spawned agents run with `--permission-mode auto`.

## Schema versioning

Continuations are persisted values that outlive tool versions. Every core
carries `schema_version`; the tool refuses unknown editions (newer or
unmigratable older) loudly with a Things todo instead of reinterpreting.
Any grammar change — even an additive schedule mode — bumps the edition.
Agents always author the current edition: the instruction section is a
program constant.

Editions so far: **1** — initial grammar. **2** — documents lead with the
`<REGISTRY>` core block and an instruction preamble; `when_to_continue`
may be `""` (a task with no continuation to continue), in which case the
rendered document replaces the return vocabulary with a `## Completion`
section carrying only the terminal end block. Edition-1 cores and
legacy top-`<CONTINUATION>` documents remain parseable.

## Agents (v1)

`claude-code` (`claude -p --output-format json --permission-mode auto
--plugin-dir plugins/claude-code`) and `pi` (`pi -p --mode json`).
