---
name: gsd
description: GSD phase orchestration, one phase per fresh omp session, orchestrator advances phase-by-phase to milestone completion
category: implementation
triggers:
  - "gsd"
  - "run phase"
  - "execute phase"
  - "run gsd"
  - "/gsd-autonomous"
params:
  - name: repo
    required: true
    description: Path to the repo root containing .planning/
  - name: phase
    required: true
    description: Phase number (e.g., 4) or "next" to read .planning/STATE.md and pick the first incomplete phase
supported_agents: [pi, claude-code]   # pi == omp (@oh-my-pi/pi-coding-agent); GSD skills work under omp and Claude Code
default_agent: pi
spawn:
  cwd: "{repo}"
  agents:
    # PRIMARY: omp. GSD is installed as hyphen-form skills (/gsd-*). One fresh
    # omp session per phase (matches GSD's fresh-context design and the /next-gsd
    # habit); omp default approvalMode is yolo, so plain `omp`, no bypass flag.
    pi:
      launcher: omp
      initial_wait_s: 6
      initial: "/gsd-autonomous --only {phase}"
    # ALT: Claude Code. Colon-form /gsd:* commands, cdp launcher, in-pane /clear advance.
    claude-code:
      launcher: cdp
      initial_wait_s: 8
      initial: "/clear && /gsd-autonomous --only {phase}"
watch:
  # terminal
  - pattern: "MILESTONE COMPLETE"
    action: stop
  # one phase finished, close this pane; orchestrator spawns the NEXT phase as a
  # fresh omp session (see "Advance model" below). This is the fresh-session-per-phase advance.
  - pattern: "PHASE \\d+ COMPLETE"
    action: stop
  - pattern: "AUTONOMOUS (RUN )?COMPLETE"
    action: stop
  # genuine human decisions, never guess. escalate to the user.
  - pattern: "CHECKPOINT: Verification Required"
    action: escalate
  - pattern: "awaiting: user response"
    action: escalate
  - pattern: "Which .*\\?|Choose an option|Select .*:|\\? \\(y/n\\)"
    action: escalate
  # benign continue/approval prompts orca can clear itself
  - pattern: "No context.*Continue without"
    action: send_enter
  - pattern: "Do you want to make this edit\\?"
    action: send_enter
stop_when:
  - "MILESTONE COMPLETE"
  - "PHASE \\d+ COMPLETE"
  - "AUTONOMOUS RUN COMPLETE"
poll_interval_s: 120
idle_threshold_s: 1800
---

# Notes for orca (omp is the driver)

I (the orchestrator) run on **omp**, the workers I spawn are also omp. Per orca's core constraint I do NOT do the project coding in my own session; every phase runs in its own worker pane and I only spawn / watch / advance / escalate.

## GSD commands (omp, hyphen-form)

GSD-core installs as `/gsd-*` skills (NOT the Claude-Code `/gsd:*` colon form). The ones this playbook uses:

- `/gsd-autonomous --only {N}`: run phase N end-to-end (discuss → plan → execute) autonomously in a fresh session, pausing only for genuine user decisions. **This is the per-phase worker command.**
- `/gsd-execute-phase {N}`: execute an already-planned phase's remaining plans (use when a phase is mid-execution, e.g. a leftover unexecuted plan).
- `/gsd-verify-work`: the human-gated UAT pass (see below).
- `/gsd-progress`: situational router; reads STATE.md and reports/does the next right thing.

## Advance model, fresh omp session per phase

omp has no in-pane `/clear`-then-continue advance (that's the Claude Code pattern). Instead:

1. Spawn a fresh omp tab (cmux `new-split` in the current workspace, NOT a new workspace) running `/gsd-autonomous --only {phase}`.
2. Watch for `PHASE {phase} COMPLETE` → `stop` (close the pane).
3. Read `.planning/STATE.md` for the next incomplete phase, increment, and spawn a **new** omp tab for it. Repeat until `MILESTONE COMPLETE` or ROADMAP phases are exhausted.

This keeps context fresh per phase (each phase gets its own session near the ~59k floor) and keeps everything as tabs in one workspace.

## Verify is often human-gated (desktop / no web URL)

For UI projects with no browser-drivable target (e.g. a Tauri/Electron desktop app on macOS, WKWebView can't be driven by WebDriver/CDP), `/gsd-verify-work` produces UAT checkpoints that need a human. Two ways to shrink that:

- **Web-verify harness** (preferred when the frontend is a web build): run the dev server, mock the native bridge (e.g. Tauri `@tauri-apps/api/mocks` `mockIPC`), and drive/screenshot the UI states in a real browser. Covers presentational UAT; escalate only the true native round-trips.
- Otherwise `escalate` every `CHECKPOINT: Verification Required` / `awaiting: user response` to the user. NEVER fabricate a pass.

## Discuss-phase questions

`/gsd-autonomous` auto-answers routine discuss questions and pauses on grey-area decisions. When it pauses (an escalate pattern fires): if `.orca/prd-{name}.md` exists, search it for the answer and `send_text` it; if silent, escalate to the user, do NOT guess. Wrong answers compound across phases.

## Context budget

Long runs fill MY context too. Stay lean (delegate pane reads to subagents), let omp auto-compact, and self-monitor `contextSnapshot.promptTokens` in my own session JSONL, hand off to a fresh orchestrator session past ~75% of the window. See SKILL.md `## Orchestrator context budget & handoff`. GSD is sequential, so at most one live worker to reattach to (its surface ref is in `state.json`).

## Recovery

| Stuck on | Manual recovery |
|----------|-----------------|
| Editor / continue prompt | `send_enter` (already in `watch`) |
| Corrupted GSD state | fresh omp tab + `/gsd-health` + read diagnosis |
| PLAN.md never appears | capture pane, escalate; usually a planner tool error |
| Worker crashed | close pane, respawn same `repo`/`phase` |

## Required env

The repo must have GSD-core installed (the `/gsd-*` skills discoverable by omp) and its own auth configured. orca does not install GSD.
