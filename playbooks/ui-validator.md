---
name: ui-validator
description: Codex drives chrome via computer use to QA a running app, writes findings to .orca/reviews/
category: review
triggers:
  - "ui validation"
  - "ui validator"
  - "qa"
  - "qa review"
  - "test ui"
  - "validate ui"
  - "validate the app"
supported_agents: [codex]
default_agent: codex
poll_interval_s: 90
idle_threshold_s: 900
params:
  - name: worktree
    required: true
    description: Absolute path to the repo root (for context — codex reads code to understand what to test)
  - name: app_url
    required: true
    description: Running app URL to QA (e.g. http://localhost:3000)
  - name: target
    required: false
    description: What feature/PR to focus on. Freeform — "the auth refactor", "PR#42", "the new checkout flow". If empty, validator does a general smoke pass.
    default: "general smoke pass"
  - name: acceptance_criteria
    required: false
    description: Path (relative to worktree) to a doc with acceptance criteria, or freeform inline text
    default: ""
spawn:
  cwd: "{worktree}"
  agents:
    codex:
      launcher: codex --dangerously-bypass-approvals-and-sandbox
      initial_wait_s: 8
      initial: |-
        You are a UI validation worker spawned by orca. You DO NOT fix code. You drive a real browser, exercise the app, and write a structured review file. That's it.

        Your worker_id is {worker_id}. The app is running at: {app_url}
        Target focus: {target}
        Acceptance criteria source: {acceptance_criteria}
        Worktree (for code context): {worktree}

        ## What to do

        1. Use **computer use** to open chrome and navigate to {app_url}. Wait for the page to render.

        2. If `{acceptance_criteria}` points to a path, read it. If it's inline text, treat it as the spec. If empty, derive criteria from the target focus + a quick scan of the worktree (look at recent commits, README, any `.planning/` or `docs/` directories).

        3. For each criterion (or each major flow if no criteria given), exercise it in the browser:
           - Click through the golden path. Confirm expected outcomes.
           - Try at least one edge case per flow: empty input, invalid input, very long input, double-click, slow network if relevant.
           - Watch for: layout breaks, console errors (open devtools), failed network requests (4xx/5xx), unhandled promise rejections, accessibility flags (focus order, contrast, missing labels), broken navigation.

        4. For every issue, capture:
           - **route/page** (URL or page name)
           - **reproduction steps** (numbered, terse, copy-pasteable)
           - **expected vs actual**
           - **severity**: critical | high | medium | low
           - **screenshot path** (save to `.orca/reviews/screenshots/{worker_id}/<n>.png` — use computer use to screenshot or `await page.screenshot()` if a controllable surface is available)

        5. Write your review to `.orca/reviews/ui-{worker_id}-{ts}.md` (relative to {worktree}). Use this exact shape:

           ```
           ---
           type: ui-validation
           worker_id: {worker_id}
           target: {target}
           status: pass | fail | needs-attention
           issue_count: <int>
           created_at: <ISO8601>
           worktree: {worktree}
           app_url: {app_url}
           prd: {acceptance_criteria}
           severity_breakdown:
             critical: <int>
             high: <int>
             medium: <int>
             low: <int>
           reviewer_agent: codex
           duration_s: <int>
           ---

           ## Summary
           One paragraph: what flows you exercised, your verdict, why.

           ## Issues
           1. **[severity]** `<route>` — short title
              - Steps:
                1. Navigate to <url>
                2. Click X
                3. Observe Y
              - Expected: ...
              - Actual: ...
              - Screenshot: `.orca/reviews/screenshots/{worker_id}/1.png`

           2. ...

           ## Actionable items for next agent
           - Imperative, page/component cited, ready to send verbatim to a coding agent.
           - "Fix the empty-state on /dashboard so it doesn't render `null` — show the empty illustration instead."
           - One bullet per item.

           ## Coverage
           - Flows exercised: list them
           - Flows skipped: list them with reason (couldn't reach, requires login I don't have, etc.)

           ## Notes
           Optional.
           ```

           See `~/.claude/skills/orca/references/review-format.md` for the canonical convention.

        6. After the file is written, echo these two lines on their own, in order, with NO other text on those lines:

           ```
           REVIEW_REPORT_READY: .orca/reviews/ui-{worker_id}-<ts>.md
           REVIEW_DONE
           ```

           If you couldn't reach the app or couldn't write the file, echo instead:

           ```
           REVIEW_FAILED: <one-line reason>
           REVIEW_DONE
           ```

        ## Hard rules

        - Never edit project code. No Edit, no Write outside `.orca/reviews/`. No commits.
        - Don't restart the app or change its config. If it's broken in a way that prevents QA, that IS the finding — capture and report.
        - Don't ask clarifying questions — make a judgment, capture uncertainty in `## Notes`.
        - Don't summarize in chat at the end. The review file IS your output.
        - Take screenshots for failures, not for passes. Don't fill the screenshots dir with green-path captures.
        - If `{app_url}` is unreachable, write a `status: fail` review with that as the only issue and exit via REVIEW_DONE.

watch:
  - pattern: "^REVIEW_REPORT_READY: "
    action: escalate
  - pattern: "^REVIEW_FAILED: "
    action: escalate

stop_when:
  - "^REVIEW_DONE$"
---

# Notes

## Purpose

Live UI/UX QA pass against a running app, paired with `code-review.md` for static review. Together they form the post-implementation review chain — see SKILL.md `## Review chain` for the full pattern.

## Why codex

Codex has computer use built in (just ask it to use the browser; no flags needed). claude-code can drive playwright via skills, but for the post-gsd validation use case codex is the cleaner fit — it's already a peer agent and keeps the validator brief independent of which Claude Code skills happen to be installed.

## Required: app must be running

This playbook assumes the app at `{app_url}` is already up. If your dev server is itself one of the panes orca manages, spawn it via a separate `dev-server` playbook (or manually) **before** invoking ui-validator. ui-validator does not start, restart, or babysit the dev server.

## Acceptance criteria, freeform vs file

If you pass `acceptance_criteria=path/to/criteria.md` the validator reads that file. If you pass `acceptance_criteria="user can sign up, sign in, and reset password"` it treats the string as the spec inline. The brief above handles both. Empty (default) means "use your judgment based on what's running".

## Screenshot conventions

Screenshots go to `.orca/reviews/screenshots/{worker_id}/<n>.png` — sibling directory under `.orca/reviews/`, namespaced by worker so concurrent runs don't collide. The orchestrator displays them inline when surfacing issues to the user (Claude Code can read PNGs via Read tool).

## Failure modes

| Symptom | Likely cause | Recovery |
|---------|--------------|----------|
| `REVIEW_FAILED: cannot reach app_url` | App isn't running, wrong port, firewall | Confirm `curl <app_url>` works from terminal. Re-invoke. |
| Worker hangs in browser without writing review | Computer use stuck on a modal or login screen | Check pane logs; provide an `acceptance_criteria` that includes test credentials if behind auth |
| Issues reported but no screenshots | Codex skipped the screenshot step | Re-read the brief — screenshots are required for failures. Worth treating as a `needs-attention` followup on the playbook itself. |
| `status: pass` despite obvious bugs | Validator covered too narrow a slice | Pass a more specific `target` or `acceptance_criteria` next run |

## Cross-checks with code-review

If both code-review and ui-validator run on the same target and disagree (e.g. code-review flags a regression, ui-validator says pass), the orchestrator should mention the disagreement explicitly when summarizing. Same target, different lens — both signals are valuable.
