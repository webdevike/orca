# orca — CHANGELOG

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
