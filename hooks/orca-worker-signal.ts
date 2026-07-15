// 🐋 orca worker-signal hook (omp)
//
// The automatic half of orca's signal channel. When an omp session is launched
// as an orca worker, the orchestrator sets $ORCA_SIGNAL_FILE (+ $ORCA_WORKER_ID)
// and loads this hook via `--hook <orca>/hooks/orca-worker-signal.ts`. The hook
// then emits liveness events to the signal file automatically, so the
// orchestrator never has to screen-scrape the worker's TUI to know it's alive.
//
// Semantic milestones (phase_complete / done / blocked / ...) are still emitted
// by the worker itself via the `orca-signal` helper, driven by the playbook
// prompt. This hook only covers what the model shouldn't have to remember:
//   - turn_end        → heartbeat        (worker is producing output)
//   - agent_end       → idle             (worker finished a prompt, awaiting input)
//   - session_shutdown→ session_end      (worker process exiting)
//
// NO-OP unless $ORCA_SIGNAL_FILE is set, so it is harmless in every other omp
// session (it is safe to install user-globally or pass unconditionally).
import { appendFileSync, mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname } from "node:path";

function isoUtcSeconds(): string {
  // Match orca-signal's format exactly: no milliseconds, trailing Z.
  return new Date().toISOString().replace(/\.\d+Z$/, "Z");
}

// Event-driven wake: nudge the orchestrator's pane so it acts on this event now
// instead of on its next watchdog tick. Best-effort; a failed send is ignored
// (orca's slow watchdog is the safety net). Heartbeats never wake — only
// meaningful lifecycle events — to avoid spamming orca every turn.
function wake(event: string): void {
  const surface = process.env.ORCA_ORCHESTRATOR_SURFACE;
  if (!surface) return;
  const backend = process.env.ORCA_BACKEND ?? "cmux";
  const worker = process.env.ORCA_WORKER_ID ?? "unknown";
  const msg = `orca-wake: ${worker} ${event}`;
  try {
    if (backend === "tmux") {
      spawnSync("tmux", ["send-keys", "-t", surface, msg, "Enter"], { stdio: "ignore" });
    } else {
      spawnSync("cmux", ["send", "--surface", surface, msg], { stdio: "ignore" });
      spawnSync("cmux", ["send-key", "--surface", surface, "enter"], { stdio: "ignore" });
    }
  } catch {
    // best-effort
  }
}

function emit(event: string, extra: Record<string, string> = {}): void {
  const file = process.env.ORCA_SIGNAL_FILE;
  if (!file) return; // not an orca worker — do nothing
  const line = JSON.stringify({
    ts: isoUtcSeconds(),
    worker_id: process.env.ORCA_WORKER_ID ?? "unknown",
    event,
    ...extra,
  });
  try {
    mkdirSync(dirname(file), { recursive: true });
    appendFileSync(file, line + "\n");
  } catch {
    // best-effort telemetry — never break the worker over a failed write
  }
}

export default function (pi: {
  on: (event: string, handler: (event: unknown, ctx: unknown) => void) => void;
}): void {
  pi.on("turn_end", () => emit("heartbeat")); // file only — liveness, no wake
  pi.on("agent_end", () => { emit("idle"); wake("idle"); });
  pi.on("session_shutdown", () => { emit("session_end"); wake("session_end"); });
}
