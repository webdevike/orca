# 🐋 orca — TODO

Deferred work. Not committed to a roadmap; just captured so it doesn't evaporate.

## Smoke-test gaps still open

These v1 surfaces have never been exercised end-to-end. The validator chain confirmed cmux/codex/code-review works; the rest is theoretical.

- [ ] **`ui-validator` playbook** — never invoked. Codex computer use against a real running app, screenshots, the full flow.
- [ ] **tmux backend** — only cmux exercised. References/backends.md says they're parallel; not verified.
- [ ] **Multiple concurrent workers** — only single-worker runs. Same-tick race fix from run #4 is documented but untested.
- [ ] **Crash recovery / state.json rehydration** — what happens when the orchestrator session dies mid-flow and restarts. State schema accommodates it; procedure isn't drilled.
- [ ] **pi as worker** — pi launcher path unused. AGENTS.md mentions it, never run.
- [ ] **codex as orchestrator** — AGENTS.md is written, never started codex in the orca repo with intent to coordinate workers.

## v1.1 candidates (additive, low risk)

- [ ] **Declarative `chain:` field** on playbook frontmatter so an implementation playbook can declare its own follow-up validators (gsd → auto-spawn code-review + ui-validator). Sketched in SKILL.md `## Review chain` "Future v1.1" subsection.
- [ ] **`dispatch_to <worker_id>` action** in playbook DSL — send findings to a live worker pane without manual `cmux send`. Closes the gap noted in SKILL.md aggregation step ("Manual in v1").
- [ ] **`scripts/validate-playbook.sh`** — referenced in `references/playbook-format.md` "## Validating a playbook" section as a TODO.
- [ ] **`scripts/spawn-worker.sh`** wrapper — encodes the Step 4b sequence (cd, launcher, sleep, trust prompt, /clear, brief) into one callable script. Reduces orchestrator drift across sessions.
- [ ] **`references/agent-quirks.md`** — pulls per-agent specifics out of SKILL.md (Claude Code vs codex trust prompt text, AGENTS.md/CLAUDE.md auto-load behavior, default boot times, slash-command availability). Keeps Step 4b clean.
- [ ] **`category: dev-server`** support — long-running support processes that don't terminate via `task_complete`. Frontmatter accepts the value (per playbook-format.md) but no SKILL.md procedure handles it specifically.

## v2 candidates (architectural)

- [ ] **Pluggable task sources** — `/orca beads` or `/orca linear` as alt entry modes. Today task source = the user typing playbook invocations. v2 could grow a "task source" concept parallel to backends, where orca pulls work from an external system (beads `bd ready`, Linear via MCP, etc.) instead of asking.
- [ ] **Trim review-chain out of SKILL.md core** — move the workflow-specific procedure into `playbooks/_review-chain-meta.md` (or similar). SKILL.md becomes pure muxer mechanics; multi-stage flow patterns live next to the playbooks that use them.

## Integration sketches

### Beads (Steve Yegge's coding-agent memory system — github.com/steveyegge/beads)

Two integration shapes:

1. **As a playbook** (v1.1): `playbooks/beads-pull.md` calls `bd ready --json`, picks the next issue, formats the body as a brief for a child playbook. Additive, orca knows nothing about beads.
2. **As an alt entry mode** (v2): `/orca beads` loops on `bd ready`, runs playbooks, files review-chain findings back as `bd create` issues with `blocks` relationships. Bigger commitment — touches orca's invocation surface.

Pair with the review-chain → beads sink: actionable items from validator runs become beads issues instead of evaporating after a session ends.

### Pi orchestrator (`pi/README.md` is currently a placeholder)

The pi-as-orchestrator config is a stub. Filling it would parallel AGENTS.md (codex) and SKILL.md (Claude Code). Open question: which pi extensibility surface fits — TS Extension, Skill, Prompt Template. Likely Skill for parity.

## Cleanup (small, low-priority)

- [ ] **Duplicate "Helper Scripts" sections in SKILL.md** (around lines 310 and 327). Pre-existing pre-v1 leftover. Merge into one block; the second is more complete.
- [ ] **Add `.orca/` to repo's `.gitignore`** — already done.
- [ ] **`scripts/poll.sh` and `scripts/detect-state.sh`** — referenced by SKILL.md but their actual contents may need refresh against the current playbook DSL (action vocab, signal vocab). Audit on next deliberate run.

## Known limitations to communicate (not bugs)

- `cmux new-split` has no `--cwd` flag — orca compensates by prepending `cd '<cwd>' && ` to the launcher per Step 4b#6. tmux honors `-c` natively. Documented; no fix planned (it's a cmux upstream concern).
- Trust prompt is per-directory-per-agent; second invocation in same dir skips it (verified in validator run #2). No action needed, just behavior to know.
- Codex's `--dangerously-bypass-approvals-and-sandbox` is the auto-perms launcher per AGENTS.md; user has accepted the security tradeoff for orchestration ergonomics.
