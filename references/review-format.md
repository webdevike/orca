# 🐋 orca — Review Format

The `.orca/reviews/` convention. Any review-class playbook (code-review, ui-validator, security-review, perf-review, accessibility-review, …) writes findings here in a uniform shape so the orchestrator can aggregate across reviewers without re-reading every file body.

## Directory layout

```
.orca/reviews/
├── code-{worker_id}-{ts}.md
├── ui-{worker_id}-{ts}.md
└── security-{worker_id}-{ts}.md   # future
```

- One file per review run, never overwritten.
- Filename pattern: `<type>-<worker_id>-<ISO8601_ts>.md`. The leading `<type>` lets the orchestrator glob by category (`.orca/reviews/code-*.md`).
- Use the same `<ts>` the worker recorded in frontmatter so the filename and `created_at` agree.

## Frontmatter schema

```yaml
---
# REQUIRED
type: code-review | ui-validation | security-review | perf-review | accessibility-review
worker_id: string                  # the spawning worker's id (matches state.json)
target: string                     # what was reviewed (PR#, commit range, branch, "uncommitted", URL)
status: pass | fail | needs-attention
issue_count: int                   # total issues regardless of severity
created_at: ISO8601 string

# OPTIONAL
worktree: absolute path            # repo root if applicable
app_url: string                    # for UI/QA reviews
prd: relative path                 # PRD the review was grounded against
severity_breakdown:                # if useful for triage
  critical: int
  high: int
  medium: int
  low: int
reviewer_agent: claude-code | codex | pi   # which runtime produced this
duration_s: int                    # wall-clock time the review took
---
```

Required fields are the minimum the orchestrator needs to triage. Optional fields are reviewer-specific affordances; orchestrators must tolerate their absence.

### `status` semantics

| Value | Meaning |
|-------|---------|
| `pass` | No actionable issues. Body may still contain notes. |
| `needs-attention` | Issues exist but none are blocking. Aggregator should mention but not gate. |
| `fail` | Blocking issues. Aggregator should surface prominently and propose follow-up actions. |

Reviewers must pick exactly one. If unsure between `needs-attention` and `fail`, prefer `fail` and let the orchestrator decide whether to gate.

## Body structure

Markdown sections in this order. Reviewers may skip sections that don't apply but should not invent new top-level sections — put extra context in `## Notes`.

```markdown
## Summary
One paragraph. What was reviewed, what the verdict is, why.

## Issues
Numbered list. Each issue must include enough for someone else to act on it
without re-reading the diff:

1. **[severity]** `path/to/file:line` — what's wrong
   - Why it matters
   - How to fix (concrete, not "consider refactoring")

2. ...

## Actionable items for next agent
Concrete to-dos in a form a coding agent can execute. One bullet per item.
Cite file:line. Keep imperative voice.

- Fix `src/auth.ts:42` race: wrap the token refresh in a single transaction
- Add unit test for the empty-input branch in `validateForm()`

## Notes
Anything else worth keeping that didn't fit above. Optional.
```

The **Actionable items** section is the orchestrator's primary handoff target. When informing other workers (via `cmux send` or a follow-up `/orca gsd …` invocation), prefer those bullets verbatim — they were written to be sent.

## Output contract from the reviewer

A review-class playbook's worker writes to `.orca/reviews/<type>-<worker_id>-<ts>.md`, then echoes a single marker on its own line:

```
REVIEW_DONE
```

Caught by the playbook's `watch` rule with `action: stop` — the orchestrator marks the worker `task_complete`, closes the pane, then runs the review-chain aggregation step (see `SKILL.md`). The aggregator reads the file from disk and triages by frontmatter `status`.

**Why one marker, not two**: an earlier draft used `REVIEW_REPORT_READY: <path>` (escalate) followed by `REVIEW_DONE` (stop). With both markers in the captured pane tail, ordered watch matching kept escalating on every tick because `escalate` doesn't advance pane state. One marker + `action: stop` is unambiguous.

**Failure handling**: workers MUST always emit `REVIEW_DONE`, even on failure. Write a placeholder review with `status: fail` and the reason in `## Summary`, then emit the marker. A missing review file is ambiguous (worker crashed? still running? confused?) — a fail-status file is unambiguous.

## Aggregation (orchestrator side)

After one or more review-class workers close, the orchestrator:

1. Globs `.orca/reviews/*.md` modified after the earliest reviewer's `spawned_at`.
2. Reads frontmatter from each (no body parse needed for triage).
3. Builds a one-screen summary: `<type>: <status> (<issue_count> issues)` per reviewer.
4. If any `status: fail` or `needs-attention`: reads those bodies' **Actionable items** sections and presents to user, with options:
   - Forward items to a new playbook run (e.g. `/orca gsd repo=… phase=fix`)
   - Send items directly to specific worker panes (manual `cmux send`)
   - Stop here, let the user act
5. If everything is `pass`: report clean and stop.

The orchestrator does **not** rewrite review files. They are append-only artifacts of the review run.

## Versioning

This format is v1. Backwards-incompatible changes will bump the version and require a top-level `review_format_version: 2` field in frontmatter. v1 reviews omit it.
