---
name: orca
description: 🐋 Workflow-agnostic multi-pane orchestrator. Spawns and coordinates worker sessions in cmux or tmux panes via pluggable playbooks. Use when the user invokes /orca, asks to "orchestrate", "manage workstreams in parallel", "run multiple agents", or wants something to keep multiple Claude/codex/dev-server sessions advancing without manual juggling. Orca picks a backend at runtime (cmux if available, else tmux), reads playbooks from .orca/playbooks/ (project) or ~/.orca/playbooks/ (global) or its bundled defaults, and drives workers via spawn/send/read primitives. Orca NEVER writes project code — it only delegates to worker panes.
---

# 🐋 orca

Workflow-agnostic multi-pane orchestrator. Spawns workers in cmux or tmux panes, applies a **playbook** that defines the workflow, monitors progress, escalates when stuck.

## Core Constraint

**Orca never writes project code.** No Edit/Write/Bash on project files outside `.orca/`. If a task requires touching code, spawn a worker pane and delegate. The intelligence lives in playbooks — orca is just the muxer + dispatcher.

## On Invocation

| User says | Action |
|-----------|--------|
| `/orca` | Read `.orca/state.json` if present; otherwise enter planning mode (ask what to orchestrate) |
| `/orca <playbook> key=value …` | Apply named playbook with args (skip planning) |
| `/orca status` | Capture-pane each tracked worker, summarize signals |
| `/orca stop <pane-ref>` | Close one worker pane, update state |
| `/orca kill` | Close all orca-managed panes, clear state |

## Backend Detection (first thing every run)

```bash
if cmux current-window >/dev/null 2>&1; then
  ORCA_BACKEND=cmux
elif [[ -n "${TMUX:-}" ]]; then
  ORCA_BACKEND=tmux
else
  echo "🐋 orca needs cmux or tmux. Launch tmux (tmux new -s orca) or open cmux, then re-run."
  exit 1
fi
```

Save the chosen backend to `.orca/state.json` so subsequent ticks don't re-probe. See [references/backends.md](./references/backends.md) for the full primitive table — every other section in this skill assumes you've selected one.

## Playbooks

A playbook is a YAML-frontmatter markdown file telling orca how to drive a particular kind of worker (GSD phases, codex agentic loop, dev server, etc.).

**Lookup precedence** (first match wins on name conflict):
1. `./.orca/playbooks/*.md` — project-local
2. `~/.orca/playbooks/*.md` — user global
3. `~/.claude/skills/orca/playbooks/*.md` — bundled defaults

**Frontmatter shape** (full spec in [references/playbook-format.md](./references/playbook-format.md), TBD — see [`playbooks/gsd.md`](./playbooks/gsd.md) for a worked example):

```yaml
---
name: gsd
description: GSD multi-repo phase orchestration
triggers: ["gsd", "run phase"]
params:
  - name: repo
    required: true
  - name: phase
    required: true
spawn:
  cwd: "{repo}"
  launcher: cdp                     # MUST be auto-perms variant; see "Auto-perms" below
  initial: "/clear && /gsd:plan-phase {phase}"
watch:
  - pattern: "PHASE N COMPLETE ✓"
    action: advance
  - pattern: "Do you want to make this edit?"
    action: send_enter
stop_when:
  - "MILESTONE COMPLETE"
---
```

The markdown body holds free-form notes orca reads as natural-language guidance (quirks, escalation hints, manual recovery steps).

## Auto-permission Mode

All worker launchers default to their **dangerous/auto-approval** flag. Orca cannot babysit interactive permission prompts — they would block every action.

| Tool | Auto launcher |
|------|---------------|
| Claude Code | `cdp` (skip-permissions wrapper) |
| codex | `codex --dangerously-bypass-approvals-and-sandbox` (or current full-auto flag) |
| Other agentic CLIs | their equivalent unattended flag |

A playbook may set `launcher_mode: safe` to opt out, but this is rare — the user has already accepted the safety tradeoff for orchestration ergonomics.

## Workflow

### 1. Plan or load

- New work, no playbook match → **planning mode**: ask the user what to orchestrate, optionally write a PRD to `.orca/prd-{name}.md` so future ticks can reference it (and so workers can read it).
- Recognized playbook (matched via `triggers` or explicit `/orca <name>`) → **apply mode**: gather any missing `params`, jump to spawn.

### 2. Spawn workers

Use the backend's pane-creation primitive:

- **cmux**: `cmux new-split <direction>` returns `OK surface:N workspace:M` on stdout — capture `surface:N`. No `--window` flag needed (same window as orchestrator).
- **tmux**: `tmux new-window -d -n "<label>" -c "<cwd>"` then `tmux send-keys` to it.

Then send the playbook's `launcher` and (after a short wait) the `initial` command. Always `/clear` before sending agentic commands to prevent context drift.

Per-worker tracking goes in `.orca/state.json` — see [references/state-schema.md](./references/state-schema.md).

### 3. Poll & detect signal

```bash
# cmux
cmux read-screen --surface surface:N --lines 50

# tmux
tmux capture-pane -t "<label>" -p -S -50
```

Match output against the playbook's `watch` patterns. Signals from the bundled set:

- `executing` → keep waiting
- `waiting_input` (matches an `action: send_enter` or similar pattern) → respond per the rule
- `phase_complete` / `task_complete` → run `action: advance` or close
- `error` → escalate
- `idle` (no progress in N seconds) → check if upstream stalled

Polling cadence: **60–120s** in active mode, **1200–1800s** in idle/waiting-on-human mode. Use `ScheduleWakeup` (in `/loop` mode) for long idle waits to amortize the prompt-cache miss.

### 4. Advance / answer / escalate

- Auto-actions defined by playbook (`send_enter`, `send_text`, `advance`, etc.) — execute directly.
- Question patterns (e.g., GSD `discuss-phase`) — check the PRD first; if covered, answer; otherwise escalate to the user.
- Escalation: capture last 50–100 lines to `.orca/logs/<pane>-<ts>.txt`, post a clear message ("worker X stuck on Y, here's what I see, what should I do?"), wait.

### 5. Close

When a playbook's `stop_when` matches OR the user says `stop <pane>` / `kill`:

- `cmux`: `cmux close-surface --surface surface:N`
- `tmux`: `tmux kill-window -t "<label>"`

Update `.orca/state.json` accordingly.

## State Files

`.orca/` lives in cwd where `/orca` was invoked. Schemas in [references/state-schema.md](./references/state-schema.md).

```
.orca/
├── state.json           # active workers, backend, last-poll timestamps, params
├── prd-{name}.md        # per-workstream requirements, used to answer worker questions
├── playbooks/           # project-local playbooks (override bundled/global)
└── logs/{pane}-{ts}.txt # captured pane output on escalation
```

## Helper Scripts

```bash
~/.claude/skills/orca/scripts/poll.sh              # capture every tracked pane, classify
~/.claude/skills/orca/scripts/detect-state.sh PANE # classify one pane against playbook patterns
```

These call the backend-appropriate primitive based on `.orca/state.json`'s `backend` field.

## References

| File | Use |
|------|-----|
| [references/backends.md](./references/backends.md) | cmux + tmux primitive table, gotchas, side-by-side commands |
| [references/state-schema.md](./references/state-schema.md) | `.orca/state.json` shape, PRD template, log format |
| [references/playbook-format.md](./references/playbook-format.md) | Full YAML schema, available actions, parameterization syntax |

## Anti-Patterns

| Don't | Do |
|-------|-----|
| Write project code from orca | Spawn a worker, delegate |
| Use `claude` instead of `cdp` (or any safe-mode equivalent) | Auto-perms launcher every time |
| Skip `/clear` between agentic commands | Always `/clear` + ~2s sleep before new dispatch |
| Hardcode workflow logic into orca | Put it in a playbook |
| Hardcode tmux or cmux commands | Use the backend abstraction in `references/backends.md` |
| Poll faster than 60s in active mode | Sub-60s burns compute for no benefit |
| Forget to capture `cmux new-split` stdout | The new `surface:N` is in the OK line — parse it; don't re-list |
| Forget `--window` for cross-window cmux workspaces | Splits don't need it; separate workspaces do |
| Auto-close panes you didn't spawn | Only kill panes tracked in `.orca/state.json` |
