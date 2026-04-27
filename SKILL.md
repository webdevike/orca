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

**Frontmatter shape** (full spec in [references/playbook-format.md](./references/playbook-format.md); worked example in [`playbooks/gsd.md`](./playbooks/gsd.md)):

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
supported_agents: [claude-code]            # which agents can run this playbook as workers
default_agent: claude-code
spawn:
  cwd: "{repo}"
  agents:
    claude-code:
      launcher: cdp                        # auto-perms variant per agent; see "Auto-perms" below
      initial: "/clear && /gsd:plan-phase {phase}"
    codex:
      launcher: codex --dangerously-bypass-approvals-and-sandbox
      initial: "Read .planning/STATE.md and execute phase {phase}'s plan…"
    pi:
      launcher: pi                         # pi has no permission prompts by default
      initial: "Read .planning/STATE.md and execute phase {phase}…"
watch:
  - pattern: "PHASE N COMPLETE ✓"
    action: advance
  - pattern: "Do you want to make this edit?"
    action: send_enter
stop_when:
  - "MILESTONE COMPLETE"
---
```

A playbook describes the **work** in an agent-agnostic way. Each entry under `spawn.agents` is the launcher + initial-prompt mapping for one agent runtime. `supported_agents` declares which are actually viable (e.g., GSD is Claude-Code-only because the `/gsd:*` commands are Claude Code skills). The orchestrator picks an agent per worker — defaulting to `default_agent`, overridable per-spawn.

The markdown body holds free-form notes orca reads as natural-language guidance (quirks, escalation hints, manual recovery steps).

## Agents as orchestrator OR worker

Coding agents (Claude Code, codex, pi) are interchangeable runtimes. Any of them can run **as orchestrator** (executing this skill / its peer configs) or **as worker** (spawned by an orchestrator, executing a playbook). The orca repo therefore ships multiple orchestrator configs so each agent has a way to play that role:

| Agent | Orchestrator config | Lives at |
|-------|--------------------|----------|
| Claude Code | `SKILL.md` (this file) | `~/.claude/skills/orca/SKILL.md` |
| codex | `AGENTS.md` (codex's project-config convention) | repo root, codex picks it up automatically when launched in the dir |
| pi | TBD — pi has TS Extensions / Skills / Prompt Templates; orca-as-pi-skill is a future addition | `pi/` directory in repo (placeholder) |

A worker pane only ever runs an agent in single-agent mode — the orchestration skill is irrelevant there. Workers consume the **playbook**, not orca itself.

## Auto-permission Mode

All worker launchers default to their **dangerous/auto-approval** flag. Orca cannot babysit interactive permission prompts — they would block every action.

| Tool | Auto launcher |
|------|---------------|
| Claude Code | `cdp` (skip-permissions wrapper) |
| codex | `codex --dangerously-bypass-approvals-and-sandbox` (or current full-auto flag) |
| Other agentic CLIs | their equivalent unattended flag |

A playbook may set `launcher_mode: safe` to opt out, but this is rare — the user has already accepted the safety tradeoff for orchestration ergonomics.

## Procedure

Follow these steps in order on every `/orca` invocation. Numbered steps are prescriptive — do them, in this order, every time.

### Step 1. Detect or read backend

```bash
if [[ -f .orca/state.json ]]; then
  BACKEND=$(jq -r '.backend' .orca/state.json)
else
  if cmux current-window >/dev/null 2>&1; then BACKEND=cmux
  elif [[ -n "${TMUX:-}" ]]; then BACKEND=tmux
  else echo "🐋 needs cmux or tmux. Launch one and re-run."; exit 1
  fi
fi
```

Persist `BACKEND` to `state.json` on first run. Never re-detect once persisted.

### Step 2. Load or initialize state

If `.orca/state.json` exists, parse it and reconcile:
- For each `worker`, capture the pane (`cmux read-screen --surface <ref> --lines 30` or `tmux capture-pane -t <ref> -p -S -30`).
- If capture fails, mark `last_signal: dead`. GC dead workers on next tick.

If absent, create `.orca/` directory and write a fresh `state.json` skeleton (workers: [], questions_pending: [], backend, started_at, cwd) — see [references/state-schema.md](./references/state-schema.md).

### Step 3. Route by user input

| User input | Route |
|------------|-------|
| `/orca` (no args) | Step 4a: planning mode |
| `/orca <name> key=value …` | Step 4b: apply playbook directly |
| `/orca status` | Step 5: report and exit |
| `/orca stop <worker_id>` | Step 6 (close one), then exit |
| `/orca kill` | Step 6 (close all), then exit |
| `/orca` arrives via `/loop` rewake | Step 5: poll + advance, then re-schedule |

### Step 4a. Planning mode

1. List available playbooks (scan `./.orca/playbooks/`, then `~/.orca/playbooks/`, then bundled `playbooks/`).
2. Ask the user what to orchestrate. Match their answer against playbook `triggers` if possible. Otherwise treat as freeform — offer to write a PRD to `.orca/prd-<slug>.md` and proceed without a playbook (manual `watch` rules from the user, captured into a one-off in-memory playbook).
3. Once a playbook is selected, gather any missing required `params` (prompt for each).
4. Confirm the plan back to the user (one line: "spawning {playbook} for {params} as {agent} worker"). Wait for ack before spawning.
5. Proceed to Step 4b.

### Step 4b. Apply playbook (spawn worker)

For each worker the playbook implies (usually one — but cross-repo playbooks may declare more):

1. Resolve params (user input + playbook defaults). If any required param is missing, error and exit.
2. Pick agent: explicit `agent=` arg → playbook's `default_agent` → first `supported_agents` entry. Verify the agent block exists in `spawn.agents.<name>`.
3. Generate a `worker_id` (`{playbook}-{cwd-slug}-{disambiguator}`).
4. Spawn the pane:
   - **cmux**: `cmux new-split <direction>` (default `right`); capture `surface:N` and `workspace:M` from stdout (`OK surface:N workspace:M`).
   - **tmux**: `tmux new-window -d -n "<worker_id>" -c "<spawn.cwd>"`.
5. Sleep `spawn.agents.<agent>.initial_wait_s || 5` seconds.
6. Send the launcher (`spawn.agents.<agent>.launcher` — must be the auto-perms variant). `cmux send-key … enter` or `tmux send-keys … Enter` to submit.
7. Sleep ~8s (Claude Code / codex boot time).
8. Send `/clear` and Enter (skip if launcher is pi — pi has no slash command for that). Sleep 2s.
9. Send the playbook's `spawn.agents.<agent>.initial` (with param substitution applied) + Enter.
10. Append the worker to `state.json` with `last_signal: spawning`.

### Step 5. Poll + advance (every active tick)

For each worker in `state.json` whose `last_signal` is not `task_complete` or `dead`:

1. Capture pane (last `LINES` lines, default 30): `cmux read-screen --surface <ref> --lines 30` or `tmux capture-pane -t <ref> -p -S -30`. If capture fails twice in a row, mark `dead` and skip.
2. Match each `watch[].pattern` against the captured text **in order**. First match wins.
3. On first match, perform the corresponding `action`:

   | Action | Implementation |
   |--------|---------------|
   | `advance` | Send `/clear`, sleep 2s, send substituted `next` + Enter. Set `last_signal: phase_complete`. |
   | `send_enter` | Send Enter only. `last_signal: waiting_input`. |
   | `send_text` | Send substituted `next` + Enter. |
   | `clear_and_send` | Send `/clear`, sleep 2s, send `next` + Enter. |
   | `stop` | Mark `last_signal: task_complete`. Pane will be closed in Step 6. |
   | `escalate` | Capture last 100 lines to `.orca/logs/<worker_id>-<ts>.txt`, add to `questions_pending`, ping user, no further action this tick. |
   | `wait` | No-op. Update `last_signal` only. |

   Full action enum and `next` template syntax: [references/playbook-format.md](./references/playbook-format.md#action-vocabulary).

4. If no `watch` pattern matched, run `scripts/detect-state.sh --stdin` against the captured text for a generic signal (`executing` / `idle` / `error` / etc.). Log but don't act on generic signals — the playbook's rules are authoritative.
5. Append a `history` entry to the worker (`{ts, signal, action}`).
6. Update `state.json` atomically (`.tmp` + `mv`).

After processing all workers:
- If any worker had `task_complete` action → proceed to Step 6 for those.
- If all workers are `task_complete` or `dead` → print summary, exit.
- If user invoked `/orca status` → print one line per worker (id, signal, last-poll age) and exit.
- Otherwise → schedule next tick:
  - In `/loop` mode: `ScheduleWakeup` with delay = playbook's `poll_interval_s` (default 90s active, 1200–1800s if every worker is `idle`).
  - Outside `/loop`: print "next poll in {N}s" and exit. User re-invokes manually or via cron.

### Step 6. Close worker(s)

For each worker to close:

1. Capture last 100 lines to `.orca/logs/<worker_id>-<ts>.txt` (preserve evidence).
2. Close the pane:
   - **cmux**: `cmux close-surface --surface <ref>` (add `--window <window>` if the worker is in a separate workspace).
   - **tmux**: `tmux kill-window -t <worker_id>`.
3. Remove the worker entry from `state.json.workers` (or mark `last_signal: dead` if recovery is plausible — playbook-specific).
4. If `state.json.workers` is empty and `/orca kill` was invoked, optionally archive `state.json` to `.orca/state.<ts>.json.bak` and start fresh on next invocation.

## Polling cadence

- Active mode (any worker not `task_complete`/`dead`): **60–120s** between ticks. Default `poll_interval_s: 90`.
- Idle mode (every worker `idle` for ≥ `idle_threshold_s`): **1200–1800s**. The 5-min cache window matters here — never pick 300–600s, that's worst-of-both.
- Use `ScheduleWakeup` from `/loop` dynamic mode for self-pacing across context boundaries.

## State Files

`.orca/` lives in cwd where `/orca` was invoked. Schemas in [references/state-schema.md](./references/state-schema.md).

```
.orca/
├── state.json           # active workers, backend, last-poll timestamps, params
├── prd-{name}.md        # per-workstream requirements, used to answer worker questions
├── playbooks/           # project-local playbooks (override bundled/global)
├── reviews/             # review-class playbook output (code-review, ui-validator, …)
└── logs/{pane}-{ts}.txt # captured pane output on escalation
```

## Review chain

A **review-class playbook** is one whose output is a structured findings file, not a code change. Bundled examples: `code-review`, `ui-validator`. Future: `security-review`, `perf-review`, `accessibility-review`. They all follow the same convention — see [references/review-format.md](./references/review-format.md).

### When to invoke

After an **implementation playbook** (anything that ends in `task_complete` because real work shipped — `gsd`, custom feature playbooks, …) closes its workers, the orchestrator should offer to spawn review-class playbooks against the same worktree:

> "{playbook} finished. Want me to spawn code-review and ui-validator against {worktree}?"

Don't auto-spawn — confirm first. Validators are useful but not free (they consume the user's codex/Claude budget and a few minutes of wall time). The user should opt in.

### Spawning multiple validators in parallel

review-class playbooks don't depend on each other. Spawn them in the same tick:

```bash
# Each invocation goes through Step 4b independently
/orca code-review worktree=<path> target=<PR# or commit-range> [prd=<path>]
/orca ui-validator worktree=<path> app_url=<url> [target=<feature>] [acceptance_criteria=<path-or-text>]
```

Both end up in `state.json.workers[]` as separate entries. They run side-by-side in their own panes, write to `.orca/reviews/`, and close themselves via their `stop_when` rules.

### Aggregation (after validators close)

When a review-class worker closes (`task_complete` from matching `^REVIEW_DONE$`), don't just remove it from state and move on. Aggregate.

1. Find all review files written since the earliest validator's `spawned_at`:
   ```bash
   find .orca/reviews -type f -name "*.md" -newer "$earliest_spawn_marker"
   ```
2. For each file, read **frontmatter only** (skip the body for triage):
   ```bash
   awk '/^---$/{c++; next} c==1{print} c==2{exit}' <file>
   ```
   Capture: `type`, `status`, `issue_count`, `target`.
3. Build the user-facing summary:
   ```
   Review chain results:
   - code-review: <status> (<issue_count> issues) — target <target>
   - ui-validation: <status> (<issue_count> issues) — target <target>
   ```
4. If any `status` is `fail` or `needs-attention`, read those files' **`## Actionable items for next agent`** sections (the orchestrator's primary handoff target) and present them to the user with options:
   - **Forward to a fix run**: `/orca gsd repo=<...> phase=fix` (or whatever implementation playbook is appropriate), passing the actionable items as the brief.
   - **Send to specific live worker panes**: if any other workers are still in `state.json.workers[]`, `cmux send --surface <ref>` the relevant items per pane. (Manual in v1 — no `dispatch_to <worker>` action exists yet.)
   - **Stop here**: user reads, decides what to do offline.
5. If every `status` is `pass`, report clean and stop.

### What NOT to do

- **Don't** rewrite review files. They're append-only artifacts of the review run.
- **Don't** auto-chain into a fix playbook without confirmation. Findings could be wrong, the user should triage.
- **Don't** delete `.orca/reviews/` on `/orca kill`. They survive the session — `kill` only closes panes and clears `state.json.workers[]`.
- **Don't** treat a missing review file as success. If a validator closed without writing one, that's a `dead`/`error` signal, not pass.

### Future v1.1: declarative chaining

Today the user (or orchestrator's prompt) decides when to invoke validators. v1.1 may add a `chain:` field to playbook frontmatter so an implementation playbook can declare its own follow-up:

```yaml
chain:
  - playbook: code-review
    on_complete: true
    inherit_params: [worktree]
  - playbook: ui-validator
    on_complete: true
    inherit_params: [worktree]
    require_params: [app_url]
```

Not implemented in v1 — orchestrators must invoke validators manually for now.

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
| [references/playbook-format.md](./references/playbook-format.md) | Full YAML schema, action vocabulary, parameter substitution |

## Helper scripts

```bash
~/.claude/skills/orca/scripts/poll.sh                # capture + classify every tracked worker
~/.claude/skills/orca/scripts/detect-state.sh REF    # classify one pane via backend
~/.claude/skills/orca/scripts/detect-state.sh --stdin < pane-text  # classify without re-capturing
```

These dispatch by reading `backend` from `.orca/state.json`. Useful for one-off diagnostics outside the main loop.

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
