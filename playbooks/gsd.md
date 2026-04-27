---
name: gsd
description: GSD multi-repo phase orchestration with auto-advance on phase completion
category: implementation
triggers:
  - "gsd"
  - "run phase"
  - "execute phase"
  - "/gsd:execute"
  - "/gsd:plan"
params:
  - name: repo
    required: true
    description: Path to the repo root containing .planning/
  - name: phase
    required: true
    description: Phase number (e.g., 5) or "next" to read STATE.md and pick
supported_agents: [claude-code]   # GSD slash commands are Claude-Code-specific
default_agent: claude-code
spawn:
  cwd: "{repo}"
  agents:
    claude-code:
      launcher: cdp
      initial_wait_s: 8
      initial: "/clear && /gsd:plan-phase {phase}"
    # codex / pi can be added if/when GSD ships equivalents for those agents.
    # As of now, /gsd:* commands are Claude Code skills only.
watch:
  - pattern: "PHASE \\d+ COMPLETE ✓"
    action: advance
    next: "/clear && /gsd:execute-phase {phase}"
  - pattern: "QUICK TASK COMPLETE"
    action: stop
  - pattern: "MILESTONE COMPLETE"
    action: stop
  - pattern: "Do you want to make this edit\\?"
    action: send_enter
  - pattern: "No context.*Continue without"
    action: send_enter
  - pattern: "▶ Next Up.*?/gsd:execute-phase"
    action: clear_and_send
    next: "/gsd:execute-phase {phase}"
  - pattern: "▶ Next Up.*?/gsd:plan-phase"
    action: clear_and_send
    next: "/gsd:plan-phase {phase}"
stop_when:
  - "MILESTONE COMPLETE"
  - "QUICK TASK COMPLETE"
poll_interval_s: 90
---

# Notes for orca

GSD has two top-level commands worth distinguishing:

- `/gsd:plan-phase {N}` — produces `.planning/phase-{N}/PLAN.md` then waits at "next up" for executor.
- `/gsd:execute-phase {N}` — runs the executor, lands commits, marks phase complete.
- `/gsd:quick "<task>"` — one-shot task with similar shape; uses different pattern (`QUICK TASK COMPLETE`).

The executor's "almost done thinking" can run 10–18 minutes for a complex phase — don't escalate prematurely. Idle threshold should be 30+ minutes of zero stdout change.

## Discuss-phase questions

`/gsd:discuss-phase` produces interactive questions during planning. If the workspace has `.orca/prd-{name}.md`, orca should:

1. Capture the question.
2. Search the PRD for matching keywords / decisions.
3. If found, send the answer directly via `send_text`.
4. If silent, escalate to the user — do **not** guess. Wrong PRD answers compound.

## Multi-repo coordination

When orchestrating phases across multiple repos in parallel, each gets its own pane with its own `repo` and `phase` params. State each as a separate worker in `.orca/state.json` — same playbook applied multiple times.

If phase 5 in repo A depends on phase 5 in repo B finishing first, encode that with `blocked_by` in state and don't spawn the dependent worker until the upstream `stop_when` fires.

## Recovery

| Stuck on | Manual recovery |
|----------|-----------------|
| Editor approval prompt | `send_enter` (already in `watch`) |
| `/gsd:health` warning about corrupted state | Spawn debug pane: `cdp` + `/gsd:health` + ask for diagnosis |
| Phase plan never appears (`PLAN.md` not written) | Capture pane output, escalate; usually means planner hit a tool error |
| Worker crashed cdp | Kill pane, respawn from same `repo`/`phase` |

## Required env

The workspace must have GSD installed (`get-shit-done` CLI on `$PATH` — orca doesn't install it). Workers need their own auth (Anthropic, etc.) already configured.
