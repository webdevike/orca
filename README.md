# 🐋 orca

> Workflow-agnostic multi-pane orchestrator. Spawns workers in cmux (or tmux) panes, coordinates them, never writes code itself. Primary runtime is **omp** (`@oh-my-pi/pi-coding-agent`); Claude Code and codex also supported.

Orca runs as a skill invoked with `/orca`, primarily under **omp**, also under Claude Code or codex. It picks a backend at runtime (cmux if you're inside a cmux workspace, tmux otherwise) and orchestrates worker sessions according to **playbooks** you write. Drop a playbook in `.orca/playbooks/` (project) or `~/.orca/playbooks/` (global) to teach orca a new workflow. A few starters ship in `playbooks/` here.

## Why

You can babysit one Claude Code session in one terminal. You probably can't babysit four — across two repos, with one running GSD phases, one running codex, and one tailing a dev server — without something coordinating spawns, prompt detection, and "this one needs a human."

Orca is that coordinator. It's deliberately minimal: backend abstraction, playbook loader, send/read primitives, escalation. The intelligence lives in playbooks, not in orca.

## Install

```bash
git clone <wherever you put this> ~/Code/orca
cd ~/Code/orca
./install.sh
```

`install.sh` symlinks this repo to `~/.claude/skills/orca/` (backing up any existing skill to `orca.bak.<timestamp>`). **omp** discovers it there via its `claude` skill provider, no separate install needed; restart omp (or Claude Code) and invoke `/orca`. See [`pi/README.md`](./pi/README.md) for omp specifics.

## Usage

```text
/orca                                # interactive — orca asks what to orchestrate
/orca gsd repo=foo phase=5           # apply the gsd playbook with these args
/orca status                         # capture-pane every active worker, summarize
/orca stop pane:N                    # close one worker
/orca kill                           # close all orca-managed panes, clear state
```

## Playbooks

A playbook is a markdown file with YAML frontmatter that tells orca how to drive a particular kind of worker. Bundled examples in [`playbooks/`](./playbooks):

- [`gsd.md`](./playbooks/gsd.md): GSD phase orchestration, omp-first, one fresh omp session per phase, advancing to `MILESTONE COMPLETE`
- _More to come: codex, claude-cdp, dev-server_

Format spec: [`references/playbook-format.md`](./references/playbook-format.md) — full schema, action vocabulary, parameter substitution.

Lookup precedence:
1. `./.orca/playbooks/*.md` (project-specific)
2. `~/.orca/playbooks/*.md` (global)
3. `<orca-checkout>/playbooks/*.md` (bundled)

Project wins on name conflict.

## Example flow

```text
$ /orca gsd repo=/Users/ike/Code/Good/GoodWord-App phase=3
🐋 backend: cmux (detected via cmux current-window)
🐋 playbook: gsd  agent: claude-code  worker_id: gsd-goodword-3
🐋 spawning surface:44 in workspace:10 → cd /Users/ike/Code/Good/GoodWord-App && cdp
🐋 (waited 8s for cdp boot)
🐋 sent: /clear
🐋 sent: /clear && /gsd:plan-phase 3
🐋 next poll in 90s.

$ # …90s later (or on /loop tick)
$ /orca
🐋 polling 1 worker
🐋 gsd-goodword-3: executing (planner running, 47s)
🐋 next poll in 90s.

$ # …several ticks later
🐋 gsd-goodword-3: phase_complete (matched "PHASE 3 COMPLETE ✓")
🐋 advancing → /clear && /gsd:execute-phase 3
🐋 next poll in 90s.

$ # …
🐋 gsd-goodword-3: task_complete (matched "MILESTONE COMPLETE")
🐋 closing surface:44, captured tail to .orca/logs/gsd-goodword-3-2026-04-27T11:42:00Z.txt
🐋 all workers done. /orca kill to remove state.
```

`/orca status` prints one line per active worker. `/orca stop <id>` closes one pane. `/orca kill` closes everything and clears state.

## Constraints

- 🐋 **Orca never writes project code.** All code work is delegated to worker panes. The only files orca touches are inside `.orca/`.
- 🐋 **Auto-permission mode by default.** Workers launch with their dangerous/auto-approval flag (`cdp` for Claude Code, `codex --dangerously-bypass-approvals-and-sandbox`, etc.) so orca can drive them without permission prompts blocking. Override per-playbook if you need safe mode.
- 🐋 **Backend autodetected.** cmux if `cmux current-window` succeeds; tmux if `$TMUX` is set; bail if neither.

## License

MIT — see [`LICENSE`](./LICENSE).
