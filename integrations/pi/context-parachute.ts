/**
 * context-parachute — Pi extension.
 *
 * Wires the context-parachute bash hooks into Pi's lifecycle. The hooks own
 * all of the logic; this file only maps Pi events to hook stdin JSON and hook
 * stdout to Pi messages.
 *
 *   before_agent_start      parachute-watch.sh      (UserPromptSubmit)
 *   turn_end                parachute-watch.sh      (PostToolUse, throttled by the hook)
 *   session_before_compact  parachute-precompact.sh (PreCompact)
 *   session_compact         parachute-resume.sh     (SessionStart compact), --tool pi
 *
 * Install (the symlink is resolved to the repo file at load time):
 *   ln -s <repo>/integrations/pi/context-parachute.ts ~/.pi/agent/extensions/context-parachute.ts
 *
 * FAIL-OPEN: every handler swallows its errors and never cancels a compaction.
 */

import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// integrations/pi/context-parachute.ts -> repo root (through the symlink, if any)
const REPO = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "..");
const MESSAGE_TYPE = "context-parachute";

// Runs one hook with a JSON event on stdin and returns its stdout ("" on timeout or spawn failure).
function runHook(ctx: ExtensionContext, script: string, event: Record<string, unknown>, args: string[] = []): string {
  const env: NodeJS.ProcessEnv = { ...process.env, PARACHUTE_HOST: "pi" };
  const contextWindow = ctx.getContextUsage()?.contextWindow;
  if (contextWindow) env.PARACHUTE_CONTEXT_WINDOW = String(contextWindow);
  else delete env.PARACHUTE_CONTEXT_WINDOW;
  const input = JSON.stringify({
    ...event,
    session_id: ctx.sessionManager.getSessionId(),
    transcript_path: ctx.sessionManager.getSessionFile(),
    cwd: ctx.cwd,
  });
  const result = spawnSync("bash", [join(REPO, "hooks", script), ...args], {
    input,
    env,
    encoding: "utf8",
    timeout: 5000,
  });
  return result.error ? "" : (result.stdout ?? "").trim();
}

// PostToolUse stdout is {hookSpecificOutput: {additionalContext}}; anything else yields "".
function additionalContext(stdout: string): string {
  try {
    const text = JSON.parse(stdout)?.hookSpecificOutput?.additionalContext;
    return typeof text === "string" ? text : "";
  } catch {
    return "";
  }
}

// Hidden custom message: reaches the model as context, never rendered in the TUI.
function hidden(content: string) {
  return { customType: MESSAGE_TYPE, content, display: false };
}

export default function (pi: ExtensionAPI): void {
  // UserPromptSubmit: the watcher's stdout becomes a hidden message for this run.
  pi.on("before_agent_start", (_event, ctx) => {
    try {
      const text = runHook(ctx, "parachute-watch.sh", { hook_event_name: "UserPromptSubmit" });
      if (text) return { message: hidden(text) };
    } catch {
      // fail-open
    }
    return undefined;
  });

  // PostToolUse: long tool loops never reach before_agent_start, so the watcher runs after each turn.
  // triggerTurn false keeps it from starting a run; the message joins the running one at the next boundary.
  pi.on("turn_end", (_event, ctx) => {
    try {
      const text = additionalContext(runHook(ctx, "parachute-watch.sh", { hook_event_name: "PostToolUse" }));
      if (text) pi.sendMessage(hidden(text), { deliverAs: "steer", triggerTurn: false });
    } catch {
      // fail-open
    }
  });

  // PreCompact: the snapshot hook; the resume card is queued by session_compact, so no marker is needed.
  pi.on("session_before_compact", (event, ctx) => {
    try {
      runHook(ctx, "parachute-precompact.sh", { trigger: event.reason === "manual" ? "manual" : "auto" });
    } catch {
      // fail-open: never cancel the compaction
    }
  });

  // SessionStart(compact): the resume card is queued for the next prompt, after the compaction summary.
  pi.on("session_compact", (_event, ctx) => {
    try {
      const text = runHook(ctx, "parachute-resume.sh", { source: "compact" }, ["--tool", "pi"]);
      if (text) pi.sendMessage(hidden(text), { deliverAs: "nextTurn" });
    } catch {
      // fail-open
    }
  });
}
