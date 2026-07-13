# orca — CHANGELOG

## 2026-07-13 — Signal channel (structured worker→orchestrator events)

orca's coordination rode entirely on **screen-scraping**: `poll.sh` captured the worker's TUI and regex-matched it against `watch[]` rules, with completion hinging on the worker printing a banner (`PHASE N COMPLETE ✓`) verbatim. Fragile to ANSI/redraw noise and prompt-phrasing drift, poll-laggy, and with no real liveness check (a hung pane looked identical to a working one). This adds a structured, event-driven channel with worker→orchestrator wake; screen-scraping remains the fallback.

### Changes
- **New** `scripts/orca-signal` — worker-side emitter. `orca-signal <event> [k=v …]` appends one JSON line to `$ORCA_SIGNAL_FILE`. No-op when unset, so prompts are safe off-orca.
- **New** `scripts/read-signal.sh` — orchestrator-side reader. Returns latest *semantic* event (heartbeats skipped), its fields, `heartbeat_age_s`, and `event_count`; exit 3 when no file yet (caller falls back to screen-scrape).
- **New** `hooks/orca-worker-signal.ts` — omp hook (loaded via `--hook` at spawn) emitting automatic `heartbeat` (turn_end), `idle` (agent_end), `session_end` (shutdown). No-op unless `$ORCA_SIGNAL_FILE` is set.
- `scripts/poll.sh` — per worker, prefers the signal channel (`read-signal.sh`) and only screen-scrapes workers with no signal file. **Also fixed a pre-existing bug**: the `IFS=$'\t' read` loop collapsed an empty `window` field (the common `window:null` same-window split), shifting `last_signal` into `window` and breaking capture. Now uses a `\x1f` (US) separator.
- `SKILL.md` — new `## Signal channel` section; Step 4b wires `ORCA_WORKER_ID`/`ORCA_SIGNAL_FILE` env + `--hook` into the launcher and persists `signal_file`; Step 5 gains a signal-channel-first poll path with an `events[]`-matching + `heartbeat_age_s > stuck_threshold_s` watchdog; anti-patterns + helper-script listings updated.
- `references/playbook-format.md` — new `events:` block (preferred over `watch:`), `stuck_threshold_s`, `{event.<field>}` substitution, `## Events (signal channel)` section.
- `references/state-schema.md` — `.orca/signals/<worker_id>.jsonl` in the tree; `signal_file`/`last_event`/`last_event_at`/`last_heartbeat_at` worker fields; `stuck` signal; signal-event format.
- `playbooks/gsd.md` — adopts `events:` (done/phase_complete/needs_input/session_end) + `stuck_threshold_s`, worker prompt emits `orca-signal` at milestones, `watch:` kept as fallback.
- `install.sh` — symlinks `orca-signal` into `~/.local/bin` and marks scripts executable.
- **Event-driven wake** — emitters `cmux send` an `orca-wake: <worker> <event>` nudge into the orchestrator's pane so orca acts immediately instead of on a timer. `orca-signal` wakes on every semantic call; the omp hook wakes on `idle`/`session_end` (not `heartbeat`). Step 4b exports `ORCA_ORCHESTRATOR_SURFACE` (orca's own `$CMUX_SURFACE_ID`) + `ORCA_BACKEND`; Step 5 + `## Polling cadence` reframed so the fast poll is gone for signal-wired workers — the timer is only a slow watchdog (`stuck_threshold_s`) for silent hangs. Omit `ORCA_ORCHESTRATOR_SURFACE` to disable wake (timer-only).

### Verified
- Standalone: emit→read round-trip (semantic event surfaced over heartbeats), env-unset no-op, missing-file exit 3, poll.sh both branches, fixed field parse.
- End-to-end: an omp worker launched in an unrelated repo with `--hook` auto-emitted `heartbeat`+`idle`; a worker-invoked `orca-signal phase_complete phase=7` landed; `read-signal.sh` returned it correctly over the heartbeats.
- Wake: `orca-signal` with `ORCA_ORCHESTRATOR_SURFACE` set delivered an `orca-wake: <worker> <event>` line into the target pane via `cmux send` (verified against a stand-in orchestrator pane).

### Worth noting (not coded)
- Fully backward compatible: playbooks with only `watch:` and workers that emit nothing keep working via the fallback path. The channel is opt-in per playbook.
- GSD emits semantics via a natural-language `initial` directive (run the command, then `orca-signal`), since GSD's own flow doesn't call orca. If a worker skips the emit, the `watch:` banners still catch completion.

## 2026-04-29 — Subagent delegation pattern for orchestrator context efficiency

Long orca sessions burn main-thread context on perception (pane polls, log tails, big state reads, multi-kilobyte brief drafts) even though orca itself does coordination, not analysis. Each `cmux read-screen` lands 500–2000 tokens of mostly-noise into orca's window; over 20 ticks × N workers this dominates spend and forces premature session resets.

### Changes
- `SKILL.md` — new top-level section "Delegate perception to subagents" between `## Auto-permission Mode` and `## Procedure`. Documents when to delegate (pane polls, big state files, log tails, brief drafting, screenshots, large diffs), when not to (single-call cmux primitives, Edit on state.json, decision-input reads), three concrete `Agent({…})` patterns, and the ~20:1 token-math illustration.
- `SKILL.md` — added "prefer subagent" callouts inside `### Step 4b` (near the brief-send sub-step) and `### Step 5` (above the per-worker poll loop) pointing at the new section. Existing procedure text unchanged so playbook authors don't have to re-learn the flow.

### Worth noting (not coded)
- The pattern is purely orchestrator-side. Worker spawning, polling cadence, and the cmux primitive layer are unchanged — only what flows through orca's main context shifts.
- Subagents are synchronous; coordination doesn't need parallelism, just lean reads. Re-poll between substantial state changes — don't cache a subagent's "no errors" across many ticks.

## 2026-04-28 — Worker brief template (from Flodoc orchestration session)

Real-world friction observed during a multi-worker CSS-modules conversion + bug-fix session in `app.flodoc.ai`: ~30% of workers emitted `IMPLEMENTATION_COMPLETE` with a dirty working tree, forcing the orchestrator to commit on their behalf. Two fixes shipped on the same SHA later in the session (`16e55e0`, `b64cc81`). Root cause was uneven coverage of the worker-orchestrator contract across custom playbooks — some briefs spelled it out, others didn't.

### Changes
- **New**: `references/worker-brief-template.md` — recommended structure for the multi-line `initial:` payload that playbook authors send to workers. Codifies four sections (role + contract lead, compressed conventions, verification flow with date-stamped known-bad paths, commit discipline) plus the `IMPLEMENTATION_COMPLETE` / `IMPLEMENTATION_BLOCKED:` watch-pattern pair.

### Worth noting (not coded)
- The orchestrator's session log (`.orca/log.md`, already documented in SKILL.md) reliably surfaces these patterns post-hoc — keep the practice alive across future sessions.
- "Recovery, not avoidance" stance: a worker forgetting to commit is no longer a hard failure; the orchestrator stages and commits the diff with a Conventional Commits message reflecting the worker's scope. The brief reduces the rate but doesn't have to eliminate it.

## 2026-04-28 — Ref format gotcha (worker `orca-doc-fix-01`)

Documentation fix: a previous orchestrator run hit `Error: Surface index not found` while sending to panes that `cmux new-split` had just returned. Root cause: bare numerics passed to `--surface` / `--workspace` are parsed by cmux as **positional indexes**, not IDs. The full ref (`surface:N`, `workspace:M`) — exactly the form `cmux new-split` prints on its `OK …` line — must be preserved end-to-end.

Reproduced against current `cmux help` (commands list shows `[--surface <id|ref|index>]` for every pane-targeting verb; the help text mentions both indexes and refs as valid, but in practice indexes are positional and shift, while refs are stable).

### Changes
- `references/backends.md` — added a "Ref format gotcha (cmux)" callout block immediately after the `## Primitive Table` heading, with a wrong/right side-by-side example (`--surface 36` → `Error: Surface index not found` vs `--surface surface:36` → `OK surface:36 workspace:13`).
- `SKILL.md` — added a one-paragraph "Ref format gotcha (cmux)" callout at the top of `### Step 4b. Apply playbook (spawn worker)`, since that step is where the orchestrator first captures and starts threading refs through subsequent commands. Cross-links to the backends reference.

### Verified, no change needed
- `references/backends.md` primitive table already keeps `send <text>` and `send-key <key>` as separate rows (rows 36 and 37). No conflated `send-key … <text>` patterns to split.
- `scripts/poll.sh` and `scripts/detect-state.sh` pass `"$ref"` and `"$window"` through from `.orca/state.json` without manipulation, and use the correct verbs (`read-screen` only — they don't send text/keys themselves). Their correctness now hinges on the orchestrator storing full refs, which the new SKILL.md callout demands.

### Discrepancy noted
`cmux help` documents `--surface <id|ref|index>` as accepting all three formats. Bare numerics technically work as **positional indexes** at the moment they're issued, but the index drifts as panes open/close and there is no orchestrator-level mechanism to keep an index pinned to a specific surface — so for orca's purposes (refs captured at spawn, used many ticks later), refs are the only stable choice. The new docs say "always use refs" and don't mention index-mode at all, to avoid tempting future authors back into the trap.
