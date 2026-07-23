# Handoff — interactive dispatch: the `continuation:schedule` plugin (2026-07-24)

Supersedes `2026-07-23-serve-and-mac-app.md` as the current state; its
rulings all still bind. `2026-07-23-update-command-requirement.md` remains
a LIVE, separate, unimplemented requirement (an `update` command, design
with the user first).

## What this session decided (user-approved)

1. **Interactive sessions dispatch through the CLI, never through serve.**
   The user asked for a plugin so interactive Claude Code and pi sessions
   "just dispatch continuations to the running continuation server". Design
   ruling: dispatch = a local `register` invocation. The CLI stays the
   single writer, `serve` stays read-only, and the planted flag (exposure
   layer before any insert endpoint) stays planted. Phase 3 cross-node
   handoff will go through the same CLI, so the plugin surface won't change.
2. **Naming: `continuation:schedule`** — plugin `continuation`, skill
   `schedule` (user's pick, after first choosing `continue` and then
   rejecting both `continue` and `dispatch`: "continue" is a reserved CLI
   verb and a false-positive trigger magnet — users say bare "continue"
   constantly — and neither verb carries the feature's later-ness; the
   skill description leads with "Schedule work" accordingly). Distinct
   from the dispatcher's spawned-session plugin `plugins/claude-code`
   (Stop hook, injected via `--plugin-dir`), which is untouched.
3. **The grammar keeps one home.** The skill carries NO copy of the core
   schema; it shells to the new `authoring` verb. An edition bump edits
   `CORE_SHAPE`/`CORE_GRAMMAR` in the CLI and reaches both agents with
   zero plugin changes. A test enforces the no-copy rule.

## What was BUILT and verified (do not redo)

- **CLI `authoring` verb**: prints the current edition's core-authoring
  guide, composed from new `CORE_SHAPE` + `CORE_GRAMMAR` constants;
  `CONTINUATION_SECTION` is recomposed from the same constants —
  **byte-identical** (sha256 of `CONTINUATION_SECTION` and `PRINCIPLES`
  verified unchanged before/after), so rendered documents did not move.
  Logs an `authoring` event; works on a virgin store. `--actor` help now
  names `interactive-agent`. VERSION bumped 0.2.0 → 0.3.0.
  (`register --continuation -` for stdin already existed.)
- **Plugin** `plugins/continuation/`: `.claude-plugin/plugin.json` (v0.1.0
  — user's call; an intra-session 0.1.0→0.2.0 bump for the skill rename
  was rolled back by uninstalling, purging the plugin cache, and
  reinstalling clean, so cached 0.1.0 IS the `schedule` skill, verified
  by diff) + `skills/schedule/SKILL.md`. Skill flow: spawned-session guard
  (`AGENTIC_TASK_ID` set → return blocks, never register), preflight
  (`launchctl list | grep agentic-continuation`), fetch grammar via
  `authoring`, draft, **explicit user approval before register** (lasting
  side effect), register with `--actor interactive-agent --continuation -`,
  confirm via `queue`. Non-interactive with no user: do not register; put
  the draft in the final message.
- **Repo root is now a plugin marketplace**: `.claude-plugin/marketplace.json`
  (name `agentic-continuation`) listing `./plugins/continuation`.
- **Installed on this Mac (both agents)**:
  - Claude Code: `claude plugin marketplace add <repo>` +
    `claude plugin install continuation@agentic-continuation` — user scope,
    enabled; cache verified in sync. NOTE: the cache is keyed by plugin
    version — after editing the skill, bump plugin.json's version and run
    `claude plugin update continuation@agentic-continuation`.
  - pi (0.81.1, `@earendil-works/pi-coding-agent`): `plugins/continuation`
    doubles as a pi PACKAGE — its `package.json` carries the `pi` manifest
    (`{"pi": {"skills": ["./skills/schedule"]}}`), so one directory serves
    both agents from one SKILL.md. Installed with `pi install <dir>`
    (user scope, recorded as a local package in
    `~/.pi/agent/settings.json`; local packages are referenced IN PLACE,
    so skill edits track live — no update step, unlike Claude's cache).
    Verified by driving pi's own `DefaultResourceLoader` via node: the
    `schedule` skill resolves from the repo path. An earlier
    `~/.pi/agent/skills/schedule` symlink was removed — superseded.
    A test (`test_plugin_manifests_agree`) pins the two manifests to the
    same name/version/skill path.
- **Tests**: 72 passing (`uv run --no-project --with pytest pytest tests/ -q`),
  up from 68: authoring prints grammar + logs event + needs no existing
  state (test_subcommands), grammar-has-one-home + skill-carries-no-copy
  (test_core).
- **Docs**: README quick-start + "Interactive dispatch" section; CLAUDE.md
  single-writer hard rule rescoped (spawned agents return blocks;
  interactive sessions register via the skill with user approval; never
  `continue`/`tick`, never HTTP).

## Addendum: distributability (same day)

- The skill's hardcoded `$HOME/Artifacts/...` BIN path made the plugin
  undistributable (user flagged it; a marketplace-cached install does not
  even sit next to the CLI). Ruling: **the CLI on PATH is the contract.**
  The skill resolves `command -v agentic-continuation` and stops with
  install guidance when absent; a test bans machine paths from the skill.
  This Mac: `~/.local/bin/agentic-continuation` → repo bin (installed,
  verified). Fleet installs need the same one-time link.
- Repo pushed to the new **private** remote `github.com/WeZZard/continuation`
  (`origin`, SSH). Local dir name still `agentic-continuation` — renaming
  is a coordinated migration (paths are load-bearing in CLAUDE.md, launchd
  plists, pi's package reference, the minis' mirror), deliberately not done.

## Not done / open

- **Not published to the wezzard-skills marketplace** — that catalog pins
  GitHub tags+SHAs (cross-repo release work). The local marketplace add
  covers this Mac. If fleet Macs want the skill interactively, run the two
  `claude plugin` commands + the pi symlink there (repo path is mirrored).
- Nothing committed yet this session — working tree carries all of the
  above.
- First real interactive use of the skill hasn't happened; watch that the
  model reaches for it at the right moments (description tuning is cheap).
- Live store untouched; jlens task untouched.
