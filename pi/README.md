# 🐋 orca, omp (pi) orchestrator config

**omp is orca's primary runtime.** [omp](https://github.com/oh-my-pi/pi-coding-agent) (`@oh-my-pi/pi-coding-agent`, the `omp` binary, descended from `pi-mono`, which is why orca's schema still names this agent `pi`) is the harness orca is tuned for. It runs in interactive / print / RPC / SDK modes and, by default, has **no permission prompts** (`tools.approvalMode: yolo`).

## Orchestrator config: there isn't a separate one, omp reads `../SKILL.md`

omp discovers the orca skill through its **`claude` skill provider** (priority 80), which scans `~/.claude/skills/`. Since `install.sh` symlinks this repo to `~/.claude/skills/orca/`, omp loads the top-level [`../SKILL.md`](../SKILL.md) as orca's orchestrator brain, the same file Claude Code uses. That file is written omp-first (launcher table, perception delegation, context self-monitoring all target omp). So there is deliberately **no separate `pi/SKILL.md`** to drift out of sync; this directory only documents omp-specific worker/launch details.

To invoke: in an omp session at a repo, run `/orca` (or `/orca gsd repo=<path> phase=<N>`). omp surfaces the skill as a `/orca`-style command when `skills.enableSkillCommands` is on; otherwise read `skill://orca` to load it.

## omp as WORKER (spawned by orca)

When orca spawns an omp worker in a cmux/tmux pane:

- **Launcher:** just `omp`, nothing else. Default `approvalMode: yolo` auto-approves read/write/exec, so there is no prompt to bypass (this is the omp parallel to Claude Code's `cdp`). If a user's global `~/.omp/agent/config.yml` lowered the mode to `write`/`always-ask`, launch `omp --yolo` (or `--auto-approve`) instead.
- **No trust prompt:** unlike Claude Code / codex, omp does not show a first-run "do you trust this directory?" dialog. Skip that step in the spawn procedure.
- **cwd context:** omp launched in the worker's cwd picks up that repo's `AGENTS.md` / project config, exactly what a worker should run under. Do not carry the orchestrator's identity into the worker.
- **Fresh session per unit of work:** omp has no in-pane `/clear`-then-continue advance. To "advance", close the pane and spawn a fresh `omp` tab for the next unit (see `playbooks/gsd.md` `## Advance model`).

## omp as ORCHESTRATOR (running orca itself)

- Detect backend, load/spawn/poll/advance/escalate/close per `../SKILL.md` `## Procedure`.
- **Delegate perception** to omp's `task` tool (or an `eval` `agent()` thunk), same 2-line-return contract as Claude Code's `Agent`. omp subagents run headless yolo with their own context window.
- **Watch your own context.** omp writes live occupancy to its session JSONL as `contextSnapshot.promptTokens` every turn; omp also auto-compacts. Self-monitor and hand off to a fresh orchestrator session past ~75% of the window; orchestration state is externalized to `.orca/`, so a fresh omp session resumes seamlessly. See `../SKILL.md` `## Orchestrator context budget & handoff`.

## Optional: omp-native skill location

The `claude`-provider path (`~/.claude/skills/orca`) already works for omp. If you prefer an omp-native location, symlink this repo into an omp skills root as well (e.g. `~/.omp/agent/skills/orca` or a project `./.agents/skills/orca`); first-match-by-name wins, so keep only one live.

## Future: TypeScript Extension

A pi/omp **TS Extension** could later wrap cmux/tmux primitives as typed tool calls for nicer ergonomics (typed `spawn`, `poll`, `send`). Not required, orca is prompt-engineering, not tool-engineering, but the option is open. Until then, orca drives the backend via bash primitives from `references/backends.md`.
