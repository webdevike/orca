# 🐋 orca

> Workflow-agnostic multi-pane orchestrator for Claude Code skills. Spawns workers in cmux (or tmux) panes, coordinates them, never writes code itself.

Orca runs as a Claude Code skill (`/orca`). It picks a backend at runtime — cmux if you're inside a cmux workspace, tmux otherwise — and orchestrates worker sessions according to **playbooks** you write. Drop a playbook in `.orca/playbooks/` (project) or `~/.orca/playbooks/` (global) to teach orca a new workflow. A few starters ship in `playbooks/` here.

## Why

You can babysit one Claude Code session in one terminal. You probably can't babysit four — across two repos, with one running GSD phases, one running codex, and one tailing a dev server — without something coordinating spawns, prompt detection, and "this one needs a human."

Orca is that coordinator. It's deliberately minimal: backend abstraction, playbook loader, send/read primitives, escalation. The intelligence lives in playbooks, not in orca.

## Install

```bash
git clone <wherever you put this> ~/Code/orca
cd ~/Code/orca
./install.sh
```

`install.sh` symlinks this repo to `~/.claude/skills/orca/` (backing up any existing skill at that path to `orca.bak.<timestamp>`). After install, restart Claude Code to pick up the skill, then invoke with `/orca`.

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

- [`gsd.md`](./playbooks/gsd.md) — GSD multi-repo phase orchestration with auto-advance on `PHASE N COMPLETE ✓`
- _More to come: codex, claude-cdp, dev-server_

Format spec: see [`references/playbook-format.md`](./references/playbook-format.md) (TBD — for now, copy `gsd.md` and adapt).

Lookup precedence:
1. `./.orca/playbooks/*.md` (project-specific)
2. `~/.orca/playbooks/*.md` (global)
3. `~/.claude/skills/orca/playbooks/*.md` (bundled)

Project wins on name conflict.

## Constraints

- 🐋 **Orca never writes project code.** All code work is delegated to worker panes. The only files orca touches are inside `.orca/`.
- 🐋 **Auto-permission mode by default.** Workers launch with their dangerous/auto-approval flag (`cdp` for Claude Code, `codex --dangerously-bypass-approvals-and-sandbox`, etc.) so orca can drive them without permission prompts blocking. Override per-playbook if you need safe mode.
- 🐋 **Backend autodetected.** cmux if `cmux current-window` succeeds; tmux if `$TMUX` is set; bail if neither.

## License

MIT — see [`LICENSE`](./LICENSE).
