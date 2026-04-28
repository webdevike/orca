---
name: code-review
description: Codex-driven code review of a diff/PR/worktree, writes findings to .orca/reviews/ and files medium+ findings into beads when a beads DB exists
category: review
triggers:
  - "code review"
  - "review code"
  - "code-review"
  - "review the diff"
  - "review the pr"
supported_agents: [codex]
default_agent: codex
poll_interval_s: 60
idle_threshold_s: 600
params:
  - name: worktree
    required: true
    description: Absolute path to the repo root the reviewer should cd into
  - name: target
    required: true
    description: What to review — "PR#42", "main..feature/auth", "uncommitted", branch name, or freeform path glob
  - name: prd
    required: false
    description: Path (relative to worktree) to a PRD or acceptance-criteria doc to ground the review
    default: ""
spawn:
  cwd: "{worktree}"
  agents:
    codex:
      launcher: codex --dangerously-bypass-approvals-and-sandbox
      initial_wait_s: 8
      initial: |-
        You are a code review worker spawned by orca. You DO NOT fix code. You read it, judge it, and write a structured review file. That's it.

        Your worker_id is {worker_id}. Your target is: {target}
        PRD (if any): {prd}

        ## What to do

        1. Figure out what changed for `{target}`:
           - PR number → `gh pr diff <number>` then `gh pr view <number> --json files,title,body`
           - Commit range like `main..feature/x` → `git diff main..feature/x` + `git log main..feature/x --stat`
           - "uncommitted" → `git diff` + `git diff --staged`
           - Branch name → `git diff $(git merge-base main HEAD)..HEAD` (or origin/main if main is missing)
           - Anything else → ask yourself what makes sense, default to `git diff HEAD~1` if truly stuck

        2. Code-review the diff. For every issue, capture:
           - file:line (use the post-change line numbers)
           - severity: critical | high | medium | low
           - why it matters (one sentence)
           - concrete fix (one to three sentences — actionable, not "consider refactoring")

           Look for: bugs, race conditions, null/undefined hazards, error-handling gaps, security issues (injection, auth, secrets), performance regressions, breaking API changes, dead code introduced by the diff, missing tests for new branches, type-safety regressions, dependency risk.

           If the PRD path is set, cross-check the diff against it: does the change satisfy the acceptance criteria? Flag gaps.

        3. Write your review to `.orca/reviews/code-{worker_id}-{ts}.md` (relative to {worktree}). Use this exact shape:

           ```
           ---
           type: code-review
           worker_id: {worker_id}
           target: <the target string>
           status: pass | fail | needs-attention
           issue_count: <int>
           created_at: <ISO8601>
           worktree: {worktree}
           prd: <prd or empty>
           severity_breakdown:
             critical: <int>
             high: <int>
             medium: <int>
             low: <int>
           reviewer_agent: codex
           duration_s: <int>
           ---

           ## Summary
           One paragraph: what changed, your verdict, why.

           ## Issues
           1. **[severity]** `file:line` — what's wrong
              - Why it matters
              - How to fix

           2. ...

           ## Actionable items for next agent
           - Imperative, file:line cited, ready to send verbatim to a coding agent.
           - One bullet per item.

           ## Notes
           Optional.
           ```

           See `~/.claude/skills/orca/references/review-format.md` for the full convention if any field is unclear.

        4. **File actionable items into beads (if a beads DB exists).** Probe with `bd ready` in `{worktree}` — if it errors (beads not installed, or no DB initialized), skip this step entirely. Otherwise, for each entry under `## Actionable items for next agent` whose underlying issue severity is medium, high, or critical, run:

           ```
           bd create "[<severity>] <file:line> — <short summary>" \
             -d "<why it matters>

           Fix: <how to fix>

           Source: .orca/reviews/code-{worker_id}-{ts}.md" \
             -p <priority> \
             -l code-review,severity-<severity>
           ```

           Severity → priority mapping: `critical` → `P0`, `high` → `P1`, `medium` → `P2`. Skip low-severity items — they stay in the review file only. Title is **positional** in `bd create` (not `--title`); body goes via `-d`/`--description`. If a `bd create` call errors, append a one-line note to the review's `## Notes` section (e.g., "beads: failed to file <title>: <error>") and continue. Don't fail the review over beads.

        5. After the file is written (and beads issues filed if applicable), echo this single line on its own, with NO other text on that line:

           ```
           REVIEW_DONE
           ```

           If you couldn't write the file (filesystem error, permissions, etc.), still write a placeholder review with `status: fail` explaining the reason in `## Summary`, then echo `REVIEW_DONE`. The orchestrator reads frontmatter+body to triage; a missing file would be ambiguous, so always emit something. Beads-filing failures do NOT trigger `status: fail` — log them in `## Notes` and proceed.

        ## Hard rules

        - Never edit project code. No Edit, no Write outside `.orca/reviews/`. No commits. No `git apply`.
        - Don't run the app, install deps, or change repo state. Reading is fine.
        - Don't ask clarifying questions — make a judgment and capture uncertainty in the review's `## Notes` section.
        - Don't summarize in chat at the end. The review file IS your output.
        - If `{target}` is malformed or you can't figure out the diff, write a `status: fail` review explaining what you tried and exit via REVIEW_DONE anyway. Do not stall.

watch:
  - pattern: "^REVIEW_DONE$"
    action: stop
---

# Notes

## Purpose

Static code review pass after an implementation playbook (e.g. gsd) closes. Pairs naturally with `ui-validator.md` — invoke both against the same worktree and the orchestrator aggregates them via the `.orca/reviews/` convention.

## Why codex

Codex's bash + agentic loop is well-suited to "read large diffs, compare against criteria, produce structured output". claude-code is also viable but codex avoids the skill-collision quirk and keeps the orca repo usefully multi-agent.

## Cwd gotcha

`cmux new-split` does not honor `spawn.cwd` directly (no `--cwd` flag). The orchestrator must `cd "{worktree}" &&` prefix the launcher when spawning, or send `cd "{worktree}"` + Enter as a pre-launcher step. See SKILL.md Step 4b for the canonical recipe.

## Codex AGENTS.md collision

Codex auto-loads any `AGENTS.md` from cwd. If `{worktree}` has its own AGENTS.md, it merges with this brief. That's usually fine (the project conventions enrich the review) but if the project's AGENTS.md tells codex to "always fix issues you find", it conflicts with our hard rule above. The brief's hard rules win — codex resolves conflicts by preferring the most recent instruction, and the brief is sent after AGENTS.md is loaded.

## Beads integration

When a beads database exists in the worktree (`bd ready` succeeds), the worker also files medium-and-above findings as `bd create` issues. Findings stop evaporating after the review session — the orchestrator (or a future scout playbook) can later pull from beads to dispatch fixes.

This is the **worker's** concern, not orca's. Orca remains beads-agnostic; the integration lives entirely in this playbook prose. Beads-less repos are unaffected — the step is a no-op when no DB exists.

Known limitation: re-running review on the same diff will create duplicate beads issues. Dedup is not handled in v1; if it matters, close stale issues manually or via a future scout playbook.

## Output you should NOT trust

Don't read the body of the review file from the orchestrator's chat output — codex may print partial drafts as it works. Only trust the file on disk after `REVIEW_DONE`.

## Failure modes

The contract is single-marker: write the review file, emit `REVIEW_DONE`. Failure signal is `status: fail` in the file's frontmatter, NOT a separate marker. The orchestrator inspects the file after the worker closes.

| Symptom | Likely cause | Recovery |
|---------|--------------|----------|
| Worker closes but no review file in `.orca/reviews/` | Codex emitted `REVIEW_DONE` without writing first (contract violation) | Treat as `status: fail`. Check the captured pane log in `.orca/logs/<worker_id>-<ts>.txt` for what went wrong. Re-invoke if recoverable. |
| Review file has `status: fail` with "could not parse target" | Ambiguous `{target}` | Re-invoke with a more specific target (PR#, sha range) |
| Worker hangs without emitting `REVIEW_DONE` | Codex got stuck (long-running diff, network call) | Check the pane; if file is already on disk you can `/orca stop <worker_id>` to force close. Otherwise wait or re-invoke. |
| File written but `status: pass` and `issue_count: 0` despite obvious issues | Codex missed the diff entirely | Check the worker's pane log — likely `gh pr diff` returned empty. Re-invoke with explicit commit range. |
