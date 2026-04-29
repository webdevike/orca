# 🐋 orca — Backend Reference

Side-by-side primitive table for cmux and tmux. Orca picks one backend per session (see SKILL.md's "Backend Detection") and uses only that backend's commands for the duration.

## Detection

```bash
if cmux current-window >/dev/null 2>&1; then
  ORCA_BACKEND=cmux
elif [[ -n "${TMUX:-}" ]]; then
  ORCA_BACKEND=tmux
else
  echo "🐋 needs cmux or tmux."
  exit 1
fi
```

Persist `ORCA_BACKEND` to `.orca/state.json` so subsequent ticks skip detection.

## Primitive Table

> **Ref format gotcha (cmux)** — `--surface` / `--workspace` parse a bare number as a **positional index**, not an ID. `cmux new-split` returns `OK surface:N workspace:M`; capture and pass the **full ref** every time. Stripping the prefix and passing the number alone fails as soon as the index shifts (and on most calls, immediately).
>
> ```bash
> # ❌ wrong — bare number is treated as a positional index
> cmux send --surface 36 "hello"          # Error: Surface index not found
>
> # ✅ right — full ref preserved from new-split / list-pane-surfaces
> cmux send --surface surface:36 "hello"  # OK surface:36 workspace:13
> ```

| Action | cmux | tmux |
|--------|------|------|
| Spawn pane (split) | `cmux new-split <left\|right\|up\|down>` → stdout `OK surface:N workspace:M` | `tmux split-window -d -h -t "<src>"` (or `-v`) |
| Spawn pane (window) | `cmux new-workspace` (separate tab; needs `--window` thereafter) | `tmux new-window -d -n "<label>" -c "<cwd>"` |
| Send text (no submit) | `cmux send --surface surface:N "<text>"` | `tmux send-keys -t "<label>" "<text>"` |
| Submit (Enter) | `cmux send-key --surface surface:N enter` | append `Enter` arg to `send-keys` |
| Read pane | `cmux read-screen --surface surface:N --lines 50` | `tmux capture-pane -t "<label>" -p -S -50` |
| List panes | `cmux list-pane-surfaces` (current ws) or `--workspace workspace:N` | `tmux list-panes -F "#{pane_id} #{pane_title}"` |
| Close pane | `cmux close-surface --surface surface:N` | `tmux kill-window -t "<label>"` (or `kill-pane`) |
| Pane title / label | implicit (surface ref) | `tmux rename-window -t "<old>" "<new>"` |

## cmux specifics

- `new-split` returns `OK surface:N workspace:M` on stdout — **parse it directly**; no need to diff `list-pane-surfaces` before/after.
- Splits live in the same workspace as the orchestrator → no `--window` flag needed for any send/read.
- Separate workspaces (created via `new-workspace`) frequently land in a **different cmux window** than the orchestrator. Every send/read targeting them must include `--window window:M`. Detect by comparing `cmux current-window` with the JSON output of `cmux --id-format both --json list-pane-surfaces --workspace workspace:N`. The misleading error `Error: invalid_params: Surface is not a terminal` (when the surface IS a terminal) means you forgot the flag.
- Sidebar status (`cmux set-status`, `cmux set-progress`) operates on `--workspace`, not surface. In split mode you only get one shared status for the whole workspace; in workspace mode you get per-tab status.

## tmux specifics

- Always pass `-d` (detached) when spawning so the orchestrator pane keeps focus.
- Use stable, descriptive labels (`-n "<label>"`) — tmux indexes are positional and shift when panes close.
- `capture-pane -p` prints to stdout; `-S -50` includes the last 50 lines of scrollback. Without `-S`, you only get the visible pane.
- For panes inside a layout (split-window), reference them with `<session>:<window>.<pane-id>` format. Stick to one window per worker if you can — it's simpler.

## Choosing splits vs separate windows/workspaces

| | Splits | Separate windows/workspaces |
|--|--|--|
| Visible at once | Yes — all panes on screen | No — one tab/window active at a time |
| Best for | 2–4 concurrent workers | 5+ workers, or workers you'll babysit individually |
| Sidebar/status | Shared (cmux) / per-window (tmux) | Per-tab (cmux) / per-window (tmux) |
| Cleanup | Close one surface/pane | Close whole window/workspace |

Default to splits up to 4 workers; switch to separate windows when you'd otherwise be tiling too small to read.

## Auto-permission launchers

Every spawn step launches the worker with its auto-approval flag — orca cannot answer interactive permission prompts in real time without an action handler in the playbook, and even then it's noisy.

| Tool | Auto launcher |
|------|---------------|
| Claude Code | `cdp` (skip-permissions wrapper) |
| codex | `codex --dangerously-bypass-approvals-and-sandbox` (or whatever the current full-auto flag is) |
| Other agentic CLIs | their equivalent unattended flag |

Playbooks set this in `spawn.launcher`. If a playbook needs safe mode, it can override with `spawn.launcher_mode: safe`, but this is rare.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Mixing cmux and tmux commands in one session | Pick one backend at start, stick with it. Persist in state. |
| Discarding `cmux new-split` stdout | The new `surface:N` is right there — parse it, don't re-list. |
| Omitting `--window` for cross-window cmux workspaces | Add `--window window:M` whenever the child workspace is in a different window. |
| Hard-coding tmux pane indexes | Use named labels (`-n`) and reference by name. |
| Forgetting `-d` on tmux spawns | Without `-d`, tmux switches focus to the new window. |
| Sub-60s polling | 60–120s active, 1200–1800s idle. |
| Closing other people's panes | Only close panes tracked in `.orca/state.json`. |
