---
name: gsd-verify
description: GSD multi-repo phase orchestration with auto-fired codex review chain (code-review + ui-validator) on phase completion. Thorough mode — pair with `gsd` for the fast/lighter version.
category: implementation
chain:
  - code-review
  - ui-validator
triggers:
  - "gsd verify"
  - "gsd-verify"
  - "gsd thorough"
  - "verify phase"
  - "gsd with review"
params:
  - name: repo
    required: true
    description: Path to the repo root containing .planning/
  - name: phase
    required: true
    description: Phase number (e.g., 5) or "next" to read STATE.md and pick
  - name: app_url
    required: true
    description: Running app URL for the ui-validator chain (e.g. http://localhost:3000)
  - name: target
    required: false
    description: Code-review target — "PR#42", "main..feature/auth", or branch name. Defaults to main..HEAD.
    default: "main..HEAD"
supported_agents: [claude-code]
default_agent: claude-code
spawn:
  cwd: "{repo}"
  agents:
    claude-code:
      launcher: cdp
      initial_wait_s: 8
      initial: "/clear && /gsd:plan-phase {phase}"
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

This is `gsd.md` with a declarative `chain:` field — same body, same watch patterns, same recovery procedures. The only difference is post-completion: when GSD closes via `task_complete`, orca auto-spawns `code-review` and `ui-validator` against the same worktree without prompting the user.

## When to use this vs `gsd`

Two modes deliberately coexist; pick by intent at invocation time:

- `/orca gsd repo=... phase=...` — **fast mode**. Just GSD. No automatic review. Use for routine work where GSD's own planning/execution/verify cycle is enough.
- `/orca gsd-verify repo=... phase=... app_url=...` — **thorough mode**. GSD plus auto-fired codex review chain. Use when you need high confidence: meta-level concerns (conventions, DRY/WET), UI smoke testing via computer use, or anything close to ship-ready.

The codex chain isn't free — extra wall time, extra token budget. `gsd` stays the default; reach for `gsd-verify` when the stakes warrant it.

## Param wiring

The chain processor (SKILL.md Step 6 substep 4) auto-wires params on spawn:

- **`code-review`** receives `worktree={repo}` (cwd → worktree) and `target={target}` (name match from this invocation).
- **`ui-validator`** receives `worktree={repo}` and `app_url={app_url}`.

`app_url` is required at invocation — orca escalates BEFORE spawning the gsd worker if it's missing. Atomic chain: either the whole flow is wired up, or none of it spawns.

## Everything else

See `gsd.md` for the full procedural notes — discuss-phase questions, multi-repo coordination, recovery table. Those apply identically here; the chain field doesn't change GSD's internal behavior, only what happens after it closes.
