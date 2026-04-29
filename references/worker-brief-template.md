# 🐋 orca — Worker Brief Template

A **worker brief** is the multi-line `initial:` payload a playbook sends to a freshly spawned worker. It's the worker's first message — it tells them who they are, what to do, and the contract with the orchestrator.

This reference is for **playbook authors**: a recommended structure plus the gotchas the orca community has hit.

## Why a template

Across runs, briefs that omit explicit guidance on these points cause repeated friction:

1. **No commit instruction** → workers signal `IMPLEMENTATION_COMPLETE` with a dirty working tree, forcing orchestrator to commit on their behalf. Observed at ~30% rate in the 2026-04-28 session before the brief was hardened.
2. **No completion signal format** → workers emit "I am done" / "implementation complete" / "✅ done" — none match the watch regex, orchestrator never advances.
3. **No blocked-state signal** → workers silently spin when stuck (hook fail, ambiguous scope, missing perms), orchestrator marks them `idle`, eventually escalates without context.
4. **No "where to find more context"** → workers ask the orchestrator questions whose answers are on disk (CLAUDE.md, .planning/, references/).

The template below addresses each.

## Recommended structure

```yaml
spawn:
  cwd: "{some_dir}"
  agents:
    claude-code:
      launcher: cdp
      initial_wait_s: 8
      initial: |-
        /clear

        # <Playbook name> — {scope_param}

        You are a worker spawned by orca to <one-sentence purpose>. Read this brief, then do the work. **Commit before you signal complete.**

        ## Project conventions (compressed — full detail in <auth file>)

        - <conv 1: e.g., app already running at port 3000 — don't restart>
        - <conv 2: e.g., `npm run db:push` blocked, use migrations>
        - <conv 3: test creds, key file paths, etc.>
        - <conv 4: tools the worker should prefer (agent-browser CLI, etc.)>

        ## Verification flow

        For <work type>, the proven path is:
        1. <step 1>
        2. <step 2>
        3. <step 3>
        ⚠ DO NOT <known-bad path with reason and date observed>.

        ## Commit discipline (orca contract)

        - Make the change → verify it → `git commit` yourself with a Conventional Commits message.
        - Emit `IMPLEMENTATION_COMPLETE` on its own line ONLY AFTER `git commit` succeeds.
        - If blocked (hook fails, scope ambiguous, missing perms), emit `IMPLEMENTATION_BLOCKED: <reason>` instead — orchestrator will help.

        ## Scope

        {scope_param}

        ---

        Begin work now. If the brief is unclear, read <auth files> before asking the orchestrator.
```

Pair the brief with these `watch` rules:

```yaml
watch:
  - pattern: "^IMPLEMENTATION_COMPLETE$"
    action: stop
  - pattern: "^IMPLEMENTATION_BLOCKED:"
    action: escalate
  # editor approval prompts, etc.
  - pattern: "Do you want to make this edit\\?"
    action: send_enter
  - pattern: "Continue\\?"
    action: send_enter
stop_when:
  - "^IMPLEMENTATION_COMPLETE$"
```

## Section-by-section rationale

### Lead with role + contract in the first paragraph

> "You are a worker spawned by orca to <X>. Read this brief, then do the work. **Commit before you signal complete.**"

The worker's first read needs to anchor: who they are, what they're for, what the deal is. Putting "commit before signal complete" in the lead — bolded — was the single biggest reduction in dirty-tree friction observed.

### Compressed project conventions, not the full CLAUDE.md

The worker has CLAUDE.md auto-loaded. The brief should NOT reproduce it. What the brief SHOULD do is highlight the 4-6 conventions most likely to trip the specific work this playbook drives. For a Flodoc fix playbook: the dev port, the blocked db:push, the test creds, the dev routes for verification. For a GSD playbook: where STATE.md is, how to read the active phase. For a code-review playbook: where to write the review file.

Rule of thumb: if the worker would lose >5 minutes by NOT knowing this convention, put it in the brief.

### Verification flow with explicit known-bad paths

When prior runs hit unreliable paths (flaky endpoints, broken CLIs, deprecated commands), name them with date observed:

> "DO NOT use the dev API verification endpoints — they 500'd repeatedly in the 2026-04-28 session."

This survives the next worker not having context about why. The date lets future authors prune stale warnings.

### Commit discipline as an explicit contract

The orchestrator literally cannot read minds. The two-line contract is:

1. `IMPLEMENTATION_COMPLETE` on its own line means "I committed and you can stop."
2. `IMPLEMENTATION_BLOCKED: <reason>` means "I need help."

Anything else (silence, "done!", a checkmark emoji) won't match the watch regex and the orchestrator will keep polling.

### Pointer to auth files at the bottom

> "If the brief is unclear, read CLAUDE.md and .claude/references/ before asking the orchestrator."

Workers under-utilize on-disk docs because they default to "ask the orchestrator." A one-line nudge to read first reduces back-and-forth.

## What NOT to put in the brief

- **Long preamble about orca itself** — the worker doesn't need to understand the orchestrator, only its contract.
- **Full content of CLAUDE.md or design docs** — point at them, don't paste them.
- **Exhaustive enumeration of edge cases** — workers can read the codebase. Briefs should be load-bearing context, not a wiki.
- **Apologies, hedges, "please be careful"** — wastes tokens, doesn't change behavior.
- **Tool-list dumps** ("you have Read, Write, Edit, Bash...") — Claude Code already knows.

## Iterating on a brief

If a playbook's workers repeatedly hit the same friction:

1. **Diagnose**: read 3–5 worker pane logs in `.orca/logs/`. What did they do wrong, and what could a brief have prevented?
2. **Add one line, not five**: every brief addition costs tokens on every worker. Add the minimum that addresses the friction.
3. **Date-stamp the known-bad warnings**: "DO NOT X — fails as of YYYY-MM-DD". Lets you prune them later when the underlying issue is fixed.
4. **Move stable conventions to CLAUDE.md / project references** so they don't need to live in every playbook brief.

## Example briefs in the wild

- `playbooks/code-review.md` — review-class brief, no commit instruction (writes a file, doesn't change code).
- `playbooks/ui-validator.md` — review-class brief, exhaustive on the report format because the report shape is the entire deliverable.
- Project-level example: `app.flodoc.ai/.orca/playbooks/flodoc-work.md` — implementation brief following this template.

## Related

- `references/playbook-format.md` — full frontmatter spec, action vocabulary.
- `references/review-format.md` — for review-class playbooks specifically.
- `SKILL.md` Step 4b — the spawn procedure that sends this brief.
