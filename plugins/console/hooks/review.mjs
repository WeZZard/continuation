#!/usr/bin/env node
// The console channel between this agent session and Continuation.
//
// Node, not Python: Claude Code is a Node program, so whatever launched
// it can launch this — no interpreter to find, no version to match (the
// Python version broke on macOS's system 3.9 in a way that was invisible
// until a session lost its hooks).
//
// Raise a review item when the session needs the human (a question, a
// plan, a stop), hold the tool call while the review console decides,
// deliver the decision back in, and clear what the session resolves on
// its own. Every write goes through the `continuation` CLI — the single
// writer. Dispatcher-spawned sessions belong to the scheduler, never to
// the review box: AGENTIC_TASK_ID guards them out. A machine without the
// CLI stays silent: this hook never breaks a session.

import { spawnSync } from "node:child_process";
import { accessSync, appendFileSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = homedir();
const EXTRA_PATH = [
  join(HOME, ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
  "/usr/bin", "/bin",
].join(":");

/** Diagnostics, off unless CONTINUATION_HOOK_LOG names a file. */
function trace(line) {
  const path = process.env.CONTINUATION_HOOK_LOG;
  if (!path) return;
  try {
    appendFileSync(path, `${new Date().toISOString()} ${line}\n`);
  } catch {}
}

function executable(path) {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function findCLI() {
  const explicit = process.env.CONTINUATION_BIN;
  if (explicit && executable(explicit)) return explicit;
  for (const directory of `${process.env.PATH ?? ""}:${EXTRA_PATH}`.split(":")) {
    if (!directory) continue;
    const candidate = join(directory, "continuation");
    if (executable(candidate)) return candidate;
  }
  return null;
}

/** Run the CLI. The tool is a Python script behind a shebang, so a
 *  missing interpreter is retried explicitly rather than swallowed. */
function runCLI(cli, args, { input, timeout = 30_000 } = {}) {
  const options = {
    input,
    encoding: "utf8",
    timeout,
    env: { ...process.env, PATH: `${process.env.PATH ?? ""}:${EXTRA_PATH}` },
  };
  let result = spawnSync(cli, ["--actor", "console-hook", ...args], options);
  if (result.error && result.error.code === "ENOENT") {
    result = spawnSync("/usr/bin/python3",
                       [cli, "--actor", "console-hook", ...args], options);
  }
  trace(`cli=${cli} args=${args.slice(0, 3).join(" ")} `
        + `status=${result.status} error=${result.error?.code ?? ""} `
        + `stderr=${(result.stderr ?? "").trim().slice(0, 200)}`);
  return result;
}

function waitSeconds() {
  const raw = Number(process.env.CONTINUATION_REVIEW_WAIT ?? "300");
  return Number.isFinite(raw) && raw > 0 ? raw : 300;
}

/** Seconds an idle session is held open for the console, 0 for never.
 *
 *  Holding is what makes a message from the console land: the hook stays
 *  alive, so there is something to deliver to. A session that does not
 *  hold shows up in the review box with every action greyed out, which
 *  is the box failing at its one job — so sessions hold by default.
 *
 *  The window is a day, because a session idle since this morning is
 *  exactly the one worth a message this afternoon. A 30-minute window
 *  looked reasonable and failed the only way that matters: the user came
 *  back at 35 minutes to a dead box (2026-07-26).
 *
 *  It costs the terminal: Claude Code queues whatever is typed while a
 *  hook runs and dispatches no event for it, so a message typed into the
 *  terminal mid-hold is acted on only once the hold ends (measured: typed
 *  at 10s into a 60s hold, acted on at 61s). Dismiss in the console ends
 *  a hold at once, and CONTINUATION_REVIEW_HOLD=0 turns holding off for a
 *  session whose terminal must never wait. */
function holdSeconds() {
  const raw = Number(process.env.CONTINUATION_REVIEW_HOLD ?? "86400");
  return Number.isFinite(raw) && raw >= 0 ? raw : 86400;
}

/** A session that stopped is idle, and idle is a review item. When the
 *  session is held, the item is actionable: a message sent from the
 *  console arrives as the session's next instruction. Otherwise it is
 *  presence only, and the item says so, since an action that cannot
 *  land is worse than none offered. */
function idle(cli, session, cwd, summary) {
  const seconds = holdSeconds();
  runCLI(cli, ["review", "clear", "--session", session]);
  const raised = runCLI(cli,
    ["review", "raise", "--session", session, "--kind", "stopped",
     "--cwd", cwd, "--summary", summary, "--payload", "-"],
    // The hook that holds names itself. Interrupting it kills this
    // process without a word to anyone, and an item that goes on
    // offering Send after its listener died is a promise nobody kept.
    { input: JSON.stringify({ held: seconds > 0, holder: process.pid }) });
  if (seconds === 0 || raised.status !== 0) return;
  const reviewID = (raised.stdout ?? "").trim();

  const waited = runCLI(cli, ["review", "wait", reviewID,
                              "--timeout", String(seconds)],
                        { timeout: (seconds + 15) * 1000 });
  if (waited.status === 3) {
    // Held as long as we promised and nobody came. The session is still
    // idle and still worth seeing, so it stays in the box — saying
    // plainly that it can no longer be reached.
    runCLI(cli, ["review", "clear", "--session", session, "--kind", "stopped"]);
    runCLI(cli,
      ["review", "raise", "--session", session, "--kind", "stopped",
       "--cwd", cwd, "--summary", summary, "--payload", "-"],
      { input: JSON.stringify({ held: false }) });
    return;
  }
  if (waited.status !== 0) {
    // Cleared from the console or by the session moving on.
    runCLI(cli, ["review", "clear", "--session", session, "--kind", "stopped"]);
    return;
  }

  let decision;
  try {
    decision = JSON.parse(waited.stdout ?? "");
  } catch {
    return;
  }
  const message = (decision.message ?? "").trim();
  if (!message) return;
  process.stdout.write(JSON.stringify({
    decision: "block",
    reason: "The user sent this from the Continuation review console — "
            + `treat it as their next message:\n\n${message}`,
  }));
}

function emit(permission, reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: permission,
      permissionDecisionReason: reason,
    },
  }));
}

/** The agent process this hook belongs to. A killed session announces
 *  nothing, so the pid is what lets the store bury it: Claude Code sets
 *  CLAUDE_PID, and is our parent when it does not. */
function agentPID() {
  const declared = Number(process.env.CLAUDE_PID);
  if (Number.isInteger(declared) && declared > 1) return declared;
  return Number.isInteger(process.ppid) && process.ppid > 1 ? process.ppid : 0;
}

/** Register the session on ANY event, not only SessionStart: Claude Code
 *  dispatches SessionStart before a --plugin-dir plugin has loaded, so
 *  presence heals from whatever event arrives first. */
function ensureSession(cli, session, cwd, source) {
  const base = ["session", "start", "--session", session,
                "--cwd", cwd, "--source", source ?? ""];
  const started = runCLI(cli, [...base, "--pid", String(agentPID())]);
  // A CLI older than --pid would otherwise leave the session
  // unregistered and its reviews orphaned. Presence first; being
  // reapable is the improvement, not the requirement.
  if (started.status !== 0) runCLI(cli, base);
}

function preToolUse(cli, data, session, cwd) {
  const tool = data.tool_name ?? "";
  const input = data.tool_input ?? {};
  let kind, summary;
  if (tool === "AskUserQuestion") {
    kind = "question";
    const questions = input.questions ?? [];
    summary = (questions[0]?.question ?? "Question").slice(0, 200);
  } else if (tool === "ExitPlanMode") {
    kind = "plan";
    const plan = (input.plan ?? "").trim();
    summary = (plan.split("\n")[0] || "Plan ready").slice(0, 200);
  } else {
    return;
  }

  const raised = runCLI(cli,
    ["review", "raise", "--session", session, "--kind", kind,
     "--cwd", cwd, "--summary", summary, "--payload", "-"],
    { input: JSON.stringify(input) });
  if (raised.status !== 0) return;
  const reviewID = (raised.stdout ?? "").trim();

  const seconds = waitSeconds();
  const waited = runCLI(cli, ["review", "wait", reviewID,
                              "--timeout", String(seconds)],
                        { timeout: (seconds + 15) * 1000 });
  // Timed out or cleared: the terminal takes over, and PostToolUse
  // clears the item once the human answers there.
  if (waited.status !== 0) return;

  let decision;
  try {
    decision = JSON.parse(waited.stdout ?? "");
  } catch {
    return;
  }

  if (kind === "question") {
    const answers = decision.answers ?? {};
    const lines = Object.entries(answers)
      .map(([question, answer]) => `- ${question}: ${answer}`).join("\n");
    emit("deny",
         "The user answered through the Continuation review console:\n"
         + lines + "\nProceed with these answers; do not ask again.");
  } else if (decision.approve) {
    emit("allow", "Plan approved in the Continuation review console.");
  } else {
    const feedback = (decision.feedback ?? "").trim();
    emit("deny",
         "The user reviewed the plan in the Continuation review console"
         + (feedback ? ` and requests changes:\n${feedback}` : " and requests changes."));
  }
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  if (process.env.AGENTIC_TASK_ID) return;
  const cli = findCLI();
  let data;
  try {
    data = JSON.parse(await readStdin());
  } catch {
    return;
  }
  const event = data.hook_event_name ?? "";
  const session = data.session_id ?? "";
  const cwd = data.cwd ?? "";
  trace(`EVENT ${event} session=${session} cli=${cli}`);
  if (!cli || !session) return;

  if (event === "SessionEnd") {
    runCLI(cli, ["review", "clear", "--session", session]);
    runCLI(cli, ["session", "end", "--session", session]);
    return;
  }

  // Everything else means the session is alive: make it discoverable.
  ensureSession(cli, session, cwd, data.source);

  switch (event) {
    case "SessionStart":
      // A session that has just started or resumed is idle: it is
      // waiting for the human to push it into work, which is exactly
      // what the review box is for. It cannot be held here, whatever
      // the setting — a hook that waits at SessionStart holds up the
      // session's own startup, and Claude Code starts no turn for a
      // message delivered this early. Driving begins at the first stop.
      runCLI(cli,
        ["review", "clear", "--session", session]);
      runCLI(cli,
        ["review", "raise", "--session", session, "--kind", "stopped",
         "--cwd", cwd, "--summary", "Waiting for your first message",
         "--payload", "-"],
        { input: JSON.stringify({ held: false }) });
      return;
    case "PreToolUse":
      preToolUse(cli, data, session, cwd);
      return;
    case "PostToolUse": {
      const kind = { AskUserQuestion: "question", ExitPlanMode: "plan" }[
        data.tool_name ?? ""];
      if (kind) {
        runCLI(cli, ["review", "clear", "--session", session, "--kind", kind]);
      }
      return;
    }
    case "Stop":
      idle(cli, session, cwd, "Waiting for your next message");
      return;
    case "UserPromptSubmit":
      runCLI(cli, ["review", "clear", "--session", session]);
      return;
  }
}

main().catch((error) => {
  trace(`FAILED ${error?.stack ?? error}`);
});
