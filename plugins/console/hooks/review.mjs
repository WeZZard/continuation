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

function emit(permission, reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: permission,
      permissionDecisionReason: reason,
    },
  }));
}

/** Register the session on ANY event, not only SessionStart: Claude Code
 *  dispatches SessionStart before a --plugin-dir plugin has loaded, so
 *  presence heals from whatever event arrives first. */
function ensureSession(cli, session, cwd, source) {
  runCLI(cli, ["session", "start", "--session", session,
               "--cwd", cwd, "--source", source ?? ""]);
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
      // what the review box is for.
      runCLI(cli, ["review", "clear", "--session", session]);
      runCLI(cli, ["review", "raise", "--session", session,
                   "--kind", "stopped", "--cwd", cwd,
                   "--summary", "Waiting for your first message"]);
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
      runCLI(cli, ["review", "clear", "--session", session]);
      runCLI(cli, ["review", "raise", "--session", session,
                   "--kind", "stopped", "--cwd", cwd,
                   "--summary", "Waiting for your next message"]);
      return;
    case "UserPromptSubmit":
      runCLI(cli, ["review", "clear", "--session", session]);
      return;
  }
}

main().catch((error) => {
  trace(`FAILED ${error?.stack ?? error}`);
});
