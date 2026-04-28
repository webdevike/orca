# 🐋 orca — Playbook Format

A playbook is a **YAML-frontmatter markdown file** that tells orca how to drive a particular kind of worker. Playbooks are agent-agnostic: each declares one or more agent blocks under `spawn.agents.<name>` so any of {claude-code, codex, pi} can run the work.

## Lookup precedence

First match wins on `name` collision:

1. `./.orca/playbooks/*.md` — project-local
2. `~/.orca/playbooks/*.md` — user global
3. `<orca-repo>/playbooks/*.md` — bundled defaults (in the orca skill checkout)

The `name` field in frontmatter (not the filename) is the canonical identifier. Filenames should match `name` for sanity but it's not enforced.

## Frontmatter schema

```yaml
---
# REQUIRED
name: string                       # canonical playbook id
description: string                # one-line summary
supported_agents: [string, ...]    # subset of {claude-code, codex, pi} this playbook works under
default_agent: string              # one of supported_agents

# OPTIONAL
category: enum                     # see Categories below; default "implementation"
triggers: [string, ...]            # natural-language phrases that match user intent ("gsd", "run phase")
poll_interval_s: int               # default 90; how often to capture-pane in active mode
idle_threshold_s: int              # default 1800; no-output time before signal becomes "idle"
chain: [string, ...]               # see Chain below; review-class playbooks to auto-spawn on task_complete

# REQUIRED
params:                            # parameters the playbook needs at invocation time
  - name: string                   # used as {name} substitution in spawn.* fields
    required: bool
    description: string
    default: string                # optional; if omitted and required, orca prompts user

spawn:
  cwd: string                      # working directory (often "{repo}")
  agents:                          # at least one entry; key MUST be in supported_agents
    <agent-name>:
      launcher: string             # exact command, with auto-perms flag (cdp, codex --dangerously-...)
      initial_wait_s: int          # default 5; sleep after launcher before sending initial
      initial: string              # first prompt sent to the agent after launcher boot
  launcher_mode: "auto" | "safe"   # default auto; safe = use non-bypass launcher (rare)

watch:                             # ordered list of pattern-action rules
  - pattern: regex                 # matched against last 30-50 lines of pane on each poll
    action: enum                   # see Action vocabulary
    next: string                   # template for advance/send_text/clear_and_send actions

stop_when:                         # regex list; first match closes the pane
  - regex
---

(Markdown body — natural-language notes for orca, not parsed.)
```

## Categories

The `category` field tells the orchestrator how to fit this playbook into a multi-stage flow. Default is `implementation` if omitted — existing v1 playbooks stay valid without modification.

| Value | Meaning | Examples |
|-------|---------|----------|
| `implementation` | Produces code changes / does the actual work. Triggers a "want validators?" offer when it closes via `task_complete`. | `gsd`, custom feature playbooks, refactor playbooks |
| `review` | Produces structured findings under `.orca/reviews/`, never edits project code. Aggregated by the orchestrator after close. | `code-review`, `ui-validator`, future `security-review` / `perf-review` |
| `dev-server` | Long-running support process (dev server, watcher, log tail). Doesn't terminate via `task_complete` under normal conditions. Excluded from review-chain triggers. | `dev-server` (TBD) |
| `other` | Anything else. Orchestrator treats it generically — no special multi-stage hooks. | one-off automation |

Orchestrators MUST tolerate unknown values (treat as `other`) and MUST treat a missing `category` as `implementation`.

See `SKILL.md` `## Review chain` and Step 6 for how categories drive the post-close flow.

## Chain

Optional list of review-class playbook names to **auto-spawn** when this playbook closes via `task_complete`. Replaces the manual "want validators?" prompt for declarative workflows.

```yaml
chain:
  - code-review
  - ui-validator
```

Semantics:
- Each listed playbook MUST be a `category: review` playbook in the lookup paths. Unknown names → orchestrator escalates, does not silently skip.
- Auto-spawn fires only when the closed worker's `last_signal == task_complete` AND `category == implementation`. `dead`, `idle`, or non-implementation closes don't trigger.
- Param wiring: each chained playbook's `worktree` (or first dir-pointing param it declares) gets the closed worker's `cwd`. Other declared params on the chained playbook are looked up by name in the parent's invocation params; missing required params → orchestrator errors before any chain spawn (atomic — don't half-spawn).
- Chained spawns go through Step 4b independently and run in parallel — same pattern as the manual "spawn multiple validators" flow.
- A playbook that itself declares `category: review` must NOT have a `chain:` field (no chain-of-chains in v1).

Playbooks without `chain:` keep the existing manual-offer behavior. The chain is opt-in per playbook — `gsd.md` (no chain) and `gsd-verify.md` (with chain) coexist as the fast vs thorough modes.

## Action vocabulary

| Action | Effect | `next` field |
|--------|--------|-------------|
| `advance` | Send `/clear`, wait 2s, then send `next` template (with param substitution). Logs as `phase_complete` signal. | required |
| `send_enter` | Send a single Enter keypress to the pane. For "Press Enter to continue" / edit-approval prompts. | not used |
| `send_text` | Send `next` (with substitution) followed by Enter. No `/clear` first. | required |
| `clear_and_send` | Send `/clear`, wait 2s, send `next` + Enter. | required |
| `stop` | Mark worker `task_complete`, close pane, remove from active list. | not used |
| `escalate` | Capture pane to `.orca/logs/`, add to `questions_pending`, ping user, do nothing else this tick. | not used |
| `wait` | Do nothing. Useful when you want to log a signal without acting (e.g., classify long-running thinking states). | not used |
| `delegate` | Spawn a child playbook on first match; on subsequent matches, replay the child's queued responses back to this pane via `send_text`. Uses structured fields (`to`, `with`, `relay_section`) instead of `next`. See `## Delegate action` below. | structured |

Custom actions are not supported in v1. If you need new behavior, propose adding it to this enum.

## Delegate action

The `delegate` action lets a watch rule spawn a child playbook on first match (e.g. ui-validator answering GSD verify-work checkpoints), then route the child's structured output back into the parent's pane on subsequent matches.

```yaml
watch:
  - pattern: "CHECKPOINT[\\s\\S]{0,300}Test (\\d+):"   # capture group [0] = test number
    action: delegate
    to: ui-validator                                    # child playbook name
    with:                                               # params for child spawn (substitution applies)
      worktree: "{cwd}"
      app_url: "{app_url}"
      acceptance_criteria: ".planning/phases/{phase}-*/{phase}-UAT.md"
    relay_section: "## UAT Responses"                   # section in child's review file to parse
```

Required fields: `to`, `with`. Optional: `relay_section` (default `## Responses`).

Lifecycle: see `SKILL.md` `## Delegation`.

## Pattern syntax

- POSIX extended regex (`grep -E` compatible).
- Case-sensitive by default; prefix with `(?i)` for insensitive.
- Patterns match against the **last 30–50 lines** of pane output captured each poll. Multi-line patterns work but anchor to single lines when possible (e.g., `^PHASE \d+ COMPLETE`).
- First matching `watch` rule wins per tick — order matters. Put exit/stop conditions before noise patterns.
- **Capture groups**: parens in the pattern produce captures, addressable as `{capture[0]}`, `{capture[1]}`, … in `next:` templates and `delegate.with` substitution. `{capture[0]}` is the *first* capture group (NOT the whole match — bash-style numbering, not POSIX).

## Parameter substitution

`{name}` placeholders are replaced everywhere in `spawn.cwd`, `spawn.agents.*.initial`, and `watch[].next`. Substitution is literal — no quoting, no escaping.

| Built-in placeholder | Value |
|----------------------|-------|
| `{worker_id}` | Auto-assigned by orca at spawn. |
| `{playbook}` | The playbook's `name` field. |
| `{agent}` | The selected agent for this worker. |
| `{cwd}` | Resolved `spawn.cwd`. |
| `{ts}` | Current ISO8601 timestamp. |
| `{<param>}` | Any param from `params:` resolved at invocation. |

Missing params with no default → orca prompts user before spawning. Missing required params from a non-interactive `/orca <name> key=...` call → error and exit, do not partial-spawn.

## Worked example

See [`playbooks/gsd.md`](../playbooks/gsd.md) for a full real playbook — GSD multi-repo phase orchestration, claude-code-only since `/gsd:*` slash commands are Claude Code skills.

Minimal skeleton for a new playbook:

```yaml
---
name: my-playbook
description: What this orchestrates
supported_agents: [claude-code]
default_agent: claude-code
triggers: ["my keyword"]
params:
  - name: target
    required: true
    description: What to operate on

spawn:
  cwd: "{target}"
  agents:
    claude-code:
      launcher: cdp
      initial: "Do the thing for {target}."

watch:
  - pattern: "✅ done"
    action: stop

stop_when:
  - "✅ done"
---

# Notes
Free-form guidance for orca.
```

## Validating a playbook

Until `scripts/validate-playbook.sh` exists, manually verify:

1. `name` is set and unique within the lookup directory.
2. `default_agent` ∈ `supported_agents`.
3. Every key under `spawn.agents.*` is in `supported_agents`.
4. Every `params[].name` referenced in `spawn.*` or `watch[].next` is declared.
5. Every `watch[].action` is in the action vocabulary above.
6. Patterns compile (test with `echo "sample text" | grep -E "your pattern"`).

## Versioning

This format is v1. Backwards-incompatible changes will bump the version and require a top-level `version: 2` field in playbook frontmatter. v1 playbooks omit `version`.
