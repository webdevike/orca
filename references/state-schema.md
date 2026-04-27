# 🐋 orca — State Schema

Everything orca persists lives under `./.orca/` in the cwd where `/orca` was first invoked.

```
.orca/
├── state.json           # session state — orchestrator reads/writes every tick
├── prd-{name}.md        # per-workstream requirements (orchestrator reads to answer worker questions)
├── playbooks/*.md       # project-local playbook overrides (read-only from orca's POV)
└── logs/{worker_id}-{ISO_ts}.txt   # captured pane tail when escalating
```

## state.json

Single file, JSON, atomic-write (write to `.tmp`, then `mv`). Schema below.

```json
{
  "version": 1,
  "backend": "cmux",
  "started_at": "2026-04-27T10:42:00Z",
  "cwd": "/Users/ike/Code/Good",
  "workers": [
    {
      "id": "gsd-goodword-3",
      "playbook": "gsd",
      "category": "implementation",
      "agent": "claude-code",
      "cwd": "/Users/ike/Code/Good/GoodWord-App",
      "params": { "repo": "/Users/ike/Code/Good/GoodWord-App", "phase": "3" },
      "pane": {
        "ref": "surface:44",
        "workspace": "workspace:10",
        "window": null
      },
      "spawned_at": "2026-04-27T10:43:12Z",
      "last_poll_at": "2026-04-27T10:55:30Z",
      "last_signal": "executing",
      "blocked_by": [],
      "history": [
        { "ts": "2026-04-27T10:43:12Z", "signal": "spawning", "action": "send_initial" },
        { "ts": "2026-04-27T10:48:00Z", "signal": "phase_complete", "action": "advance" }
      ]
    }
  ],
  "questions_pending": []
}
```

### Field reference

| Field | Type | Notes |
|---|---|---|
| `version` | int | Schema version. Bump when shape changes incompatibly. v1 today. |
| `backend` | `"cmux"` \| `"tmux"` | Picked by orca at first run via detection. Persisted so subsequent ticks skip detection. |
| `started_at` | ISO8601 string | When `/orca` was first invoked in this cwd. |
| `cwd` | absolute path | Where `.orca/` lives. Sanity-check on every tick — if a different cwd, refuse and ask user to clean up or move. |
| `workers` | array | One entry per spawned worker pane. |
| `workers[].id` | string | Stable identifier orca assigns at spawn. Pattern: `{playbook}-{short-cwd}-{disambiguator}`. Used in log filenames. |
| `workers[].playbook` | string | Name of the playbook driving this worker (`gsd`, `claude-cdp`, etc.). |
| `workers[].category` | string | Playbook category copied from frontmatter at spawn — `implementation` \| `review` \| `dev-server` \| `other`. Default `implementation` if the playbook didn't declare one. Used by Step 6 to decide whether to offer the review chain. |
| `workers[].cwd` | absolute path | Resolved `spawn.cwd` after parameter substitution. Canonical worktree identifier — used by Step 6 review-chain matching regardless of which param name the playbook used (`repo`, `worktree`, …). Always populated at spawn. |
| `workers[].agent` | `"claude-code"` \| `"codex"` \| `"pi"` | Which agent runtime is in this pane. Determines which `spawn.agents.<name>` block was used. |
| `workers[].params` | object | Resolved params (from playbook frontmatter + user input + defaults). String values only. |
| `workers[].pane.ref` | string | Backend pane reference. cmux: `surface:N`. tmux: human label (`gsd-goodword-3`). |
| `workers[].pane.workspace` | string \| null | cmux only — `workspace:N` containing the surface. tmux: session name. |
| `workers[].pane.window` | string \| null | cmux only — `window:M` if the workspace lives in a different window from the orchestrator. `null` for splits in the same window. |
| `workers[].spawned_at` | ISO8601 string | Pane creation time. |
| `workers[].last_poll_at` | ISO8601 string | Most recent capture time. |
| `workers[].last_signal` | string | Result of the most recent classify (see Signals below). |
| `workers[].blocked_by` | array of worker ids | Other workers that must finish before this one's `stop_when` is meaningful. Used for cross-repo phase dependencies. |
| `workers[].history` | array | Append-only log of significant signal transitions + actions taken. Useful for debugging stuck flows; keep last 50 entries to bound size. |
| `questions_pending` | array | Worker questions captured but not yet answered (PRD lookup failed → escalated to user). See below. |

### Signals (`workers[].last_signal`)

Generic vocabulary that any playbook's `watch` rules ultimately resolve into:

| Signal | Meaning |
|--------|---------|
| `spawning` | Pane created, launcher running, initial prompt not yet sent. |
| `executing` | Worker actively producing output. Default cadence applies. |
| `waiting_input` | Worker hit a prompt orca should auto-answer (matched a `watch.action: send_*` rule). |
| `question` | Worker asked a question that needs human / PRD answer. Capture text into `questions_pending`. |
| `phase_complete` | Playbook-defined "advance" boundary hit. Apply `action: advance` if defined. |
| `task_complete` | Playbook's `stop_when` matched. Pane should be closed. |
| `error` | Output matched an error pattern. Escalate. |
| `idle` | No output change for `poll_interval_s × 5`. Probably stuck or done waiting; check before assuming dead. |
| `dead` | Pane unreachable (cmux/tmux returned no surface). Worker is gone — log + remove from active list. |

### `questions_pending` entries

```json
{
  "worker_id": "gsd-goodword-3",
  "captured_at": "2026-04-27T10:52:18Z",
  "question_text": "Do you want me to use option A (lazy) or option B (eager)?",
  "log_path": ".orca/logs/gsd-goodword-3-2026-04-27T10:52:18Z.txt",
  "asked_user_at": null
}
```

Set `asked_user_at` when the question is forwarded to the user. Remove the entry once answered (capture the answer in `workers[].history`).

## PRD template (`prd-{name}.md`)

Plain markdown — orca reads it as natural-language reference when a worker asks a question.

```markdown
# {Name} — PRD

## Goal
One-sentence outcome.

## Constraints
- Hard limits (compatibility, performance, deadline).

## Decisions
- {Key question} → {Answer}
- {Key question} → {Answer}

## Out of scope
- What we're explicitly not doing this round.

## Notes for workers
Free-form context. Workers can read this directly via `Read` if pointed at it.
```

When a worker asks a question, orca:
1. Searches the PRD's "Decisions" section first for keyword match.
2. If found, sends the answer via `send_text` action.
3. If silent, escalates — adds to `questions_pending`, posts to user.

## Logs (`logs/{worker_id}-{ISO_ts}.txt`)

Captured pane output written when escalating or closing on error. Plain text, last 50–100 lines of the pane. Append-only — never overwrite, always new file with timestamp.

## Atomicity rules

- **Always** write `state.json` via `state.json.tmp` + `mv` to avoid half-written state on crash.
- **Never** truncate `history` mid-tick — append-only within a tick, GC at tick start.
- **Never** delete a worker entry mid-tick — mark `last_signal: dead` first, GC on next tick after logging.
