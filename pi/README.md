# 🐋 orca — pi orchestrator config (TODO)

[Pi](https://github.com/badlogic/pi-mono) (`@mariozechner/pi-coding-agent`) is a minimal terminal coding harness. It exposes four tools by default (read, write, edit, bash) and is extensible via **TypeScript Extensions**, **Skills**, **Prompt Templates**, and **Themes** — no permission prompts, runs in interactive / print / RPC / SDK modes.

To make pi an **orca orchestrator** (parallel to `SKILL.md` for Claude Code and `AGENTS.md` for codex), this directory should hold whichever pi extensibility surface fits best. The intent is identical: load orca's role + constraints + loop into pi's system context, expose enough about cmux/tmux primitives that pi can dispatch and monitor workers.

## Open questions

- **Surface choice**: TypeScript Extension (full programmatic control, can wrap cmux/tmux as tool calls) vs. Skill (markdown, minimal infra) vs. Prompt Template (one-shot system prompt). Best fit is probably a **Skill** for parity with the Claude Code/codex configs, since orca is more about prompt-engineering than tool-engineering. A TS Extension could later add typed tool wrappers around cmux/tmux for nicer ergonomics.
- **Skill format**: pi's skill loader expects a specific layout — confirm against [pi-mono extensions docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) before writing.
- **Auto-permission**: pi already has no permission prompts, so there's nothing to bypass. Worker spawn just runs `pi`.

## When ready to write

The Claude Code `SKILL.md` and codex `AGENTS.md` are the two reference points. The pi version should:

1. State the role (orchestrator, never writes project code).
2. Cover backend detection (cmux vs tmux).
3. Reference `playbooks/`, `references/backends.md`, and `references/state-schema.md`.
4. Describe the loop (plan → spawn → poll → advance → escalate → close).
5. Pick auto-permission launchers when spawning each agent type as a worker.

Until written, the workflow is: use Claude Code or codex as orchestrator and pi only as worker (`launcher: pi` in playbook agent blocks).
