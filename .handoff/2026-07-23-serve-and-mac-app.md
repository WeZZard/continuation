# Handoff — node API + macOS fleet app landed (2026-07-23, second session)

Supersedes `2026-07-23-post-sqlite-rewrite.md` as the current state. Read
that one for the SQLite-rewrite rulings; everything there still binds.
`2026-07-23-update-command-requirement.md` (dropped in by another session
mid-day) is a LIVE, separate requirement: an `update` command, designed
with the user first — explicitly not implemented yet.

## What this session decided (design rulings, all user-approved)

1. **Fleet, not single daemon.** Multiple machines each run the full stack
   (store + tick + serve); the Mac app manages all of them. No central
   aggregator; the app is the aggregation point.
2. **Continuations become messages (vision).** Handoff between machines is
   **ownership transfer**: the continuation moves into the target node's
   queue (idempotent insert by globally unique id, origin transitions to
   `handed-off` after confirmation). NOT remote execution — a sleeping
   master must not stall slaves. Master/slave are roles, not software.
   Placement recommendation (explicit targeting, not automatic) is
   raised but NOT ruled on yet.
3. **The "single unique list" is a computed view** (unified inbox), never
   a persisted global index. Per-node last-seen snapshots labeled
   "as of" are cache-of-truth, never written back.
4. **Auth is an exposure-layer concern.** The protocol carries none, ever.
   LAN trust now; Cloudflare Access (or similar edge) when public. The
   user explicitly ruled: no in-tool authentication in the first release.
   Flag planted: before the future handoff *insert* endpoint ships,
   the exposure layer must be real.
5. **v1 scope**: observe-only (no write verbs in the app). Phase 2 verbs
   (tick-now, pause/resume) require CLI verbs FIRST (`pause` does not
   exist in the CLI today); the server only shells out to the CLI.
6. macOS app first, iOS soon — one SwiftPM codebase, `ContinuationsKit`
   holds everything below the views.

## What was BUILT and verified (do not redo)

- **`serve` subcommand** (`bin/agentic-continuation serve`): node protocol
  v1 — `/v1/node`, `/v1/queue`, `/v1/tasks[...]`, prompts endpoints,
  `/v1/log`, `/v1/events` (SSE; `events.id` cursor, `Last-Event-ID`
  resume, poll default 1.5s). Request handling opens the DB strictly
  read-only (`file:...?mode=ro`); the only writes are startup bookkeeping
  (node-id mint into new `meta` table + one `serve` event). Bonjour
  advertisement `_agentic-cont._tcp` via spawned `dns-sd` (15-byte
  service-name cap is why the name is truncated). `--port 0` supported
  for tests; `--no-mdns`; `--sse-poll`.
- **Node identity**: ULID in `meta` (`ensure_node_id`). The live store's
  node id is `01KY7E1SXKGCNCDV28SM8KV1RC`.
- **launchd**: `launchd/...serve.plist` (KeepAlive) +
  `install-serve-launchd` / `uninstall-serve-launchd`.
- **Tests**: `tests/test_serve.py` — 10 tests driving a real serve
  subprocess (identity, stable node id across restarts, queue-vs-CLI
  parity, task detail, prompt listing + path-traversal rejection, log
  cursor/filters, live SSE delivery, reads-write-nothing). Suite total:
  66 passing (`uv run --no-project --with pytest pytest tests/ -q`).
- **macOS app** (`app/`, working name "Continuations", placeholder —
  naming parked): SwiftPM, macOS 14+/iOS 17 platforms, Swift language
  mode v5. `ContinuationsKit` = Models (explicit CodingKeys), NodeClient
  (async HTTP + SSE via URLSession.bytes), BonjourDiscovery (NWBrowser +
  resolve-via-throwaway-connection), FleetStore (per-node loops: fetch →
  SSE tail → refetch on queue-changing events; snapshot persistence in
  `~/Library/Application Support/Continuations/`), Persistence.
  App target: three-pane NavigationSplitView per the approved wireframes
  (unified inbox default, Needs Attention, Activity feed, node view with
  health header + Queue/Tasks/History segments, continuation detail with
  full core + evaluations + prompt viewer + MUST NOTs, menu bar extra,
  Add Node sheet, Settings). Selection carries ids, not snapshots.
- **Swift tests**: 4 end-to-end tests spawning the real Python serve
  (`app/Tests/.../NodeClientTests.swift`). All pass.
- **Build**: `swift build/test` needs full Xcode — CommandLineTools
  cannot init the build system. Xcode 27 betas exist in /Applications;
  `app/scripts/bundle.sh` auto-picks the newest Xcode via DEVELOPER_DIR
  and produces `dist/Continuations.app` (ad-hoc signed, Info.plist with
  NSLocalNetworkUsageDescription + NSBonjourServices).
- **Live smoke (verified end-to-end)**: serve ran against the live store;
  the bundled app launched, connected via the seeded manual node
  `127.0.0.1:7787`, and rendered the real jlens continuation with full
  core and constraints (screenshot: /tmp/continuations-smoke-main.png).

## User actions pending

1. `bin/agentic-continuation install-serve-launchd` — the node API is
   NOT installed as a LaunchAgent yet (assistant sessions must not load
   LaunchAgents). Until then the app only sees data when serve is run
   by hand.
2. First real app launch may prompt for Local Network permission
   (Bonjour). The manual node `127.0.0.1:7787` is already seeded in
   `~/Library/Application Support/Continuations/manual-nodes.json`, so
   loopback works regardless.
3. Later, per machine (Mac minis): clone repo, `install-launchd` +
   `install-serve-launchd` — the app will discover them via Bonjour.

## Known quirks / not-yet-chased

- Bonjour+manual duplicate of the same node: FleetStore dedupes by
  node_id (manual wins), but a Bonjour re-callback can transiently
  re-add before the next dedupe. Cosmetic churn at worst; fix later by
  remembering dismissed (source,key)→node_id pairs.
- During the smoke, the sidebar landed on the node row rather than
  "All Continuations" (default). Once, unreproduced-in-anger; suspect
  List-selection restoration. Watch for it.
- `queue_counts` in `/v1/node` and the node loop refetch both call
  `collect_queue` — fine at this scale.
- The jlens `--02` one-shot in the live store was the USER's manual
  `continue` at 04:52 UTC superseding the 12h poll (cap-end arithmetic
  in its context) — not an automated tick. Automated ticks since
  install have correctly evaluated nothing.

## Next phase pointers

- Phase 2 (verbs): add `pause`/`resume` to the CLI first (likely a
  `tasks.enabled` toggle + events), then POST endpoints that shell out,
  then app toolbar buttons in the reserved spots.
- Phase 3 (handoff): `target` on continuation cores (edition bump),
  transfer protocol (in-flight status on origin → idempotent insert on
  target → `handed-off`), peers config, lineage in the detail pane.
  Exposure-layer auth BEFORE the insert endpoint.
- iOS: add an iOS app target over ContinuationsKit; gateway/aggregate
  endpoint on one node + Cloudflare tunnel for remote access.
