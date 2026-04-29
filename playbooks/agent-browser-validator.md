---
name: agent-browser-validator
description: Headless UI validation via agent-browser CLI + lightpanda CDP engine. Drives a real-DOM headless browser (no Chrome required), captures snapshots/screenshots, writes findings to .orca/reviews/. Cheap, parallel-friendly, CI-ready alternative to ui-validator.md.
category: review
triggers:
  - "headless ui validation"
  - "lightpanda validation"
  - "agent browser"
  - "ab validate"
  - "ci ui check"
  - "smoke test ui"
supported_agents: [claude-code, codex]
default_agent: claude-code
poll_interval_s: 60
idle_threshold_s: 600
params:
  - name: worktree
    required: true
    description: Absolute path to the repo root (worker reads code for context, writes review under .orca/reviews/ here)
  - name: app_url
    required: true
    description: Running app URL to validate (e.g. http://localhost:3000). Must be reachable from the agent's shell — lightpanda has no extension/auth-replay support, so anything behind SSO/oauth needs a publicly reachable bypass or a session cookie passed via acceptance_criteria.
  - name: target
    required: false
    description: What feature/PR to focus on. Freeform — "the auth refactor", "PR#42", "the new checkout flow". If empty, runs a general smoke pass over discoverable routes.
    default: "general smoke pass"
  - name: acceptance_criteria
    required: false
    description: Path (relative to worktree) to a doc with acceptance criteria, OR freeform inline text, OR empty (let validator infer). Supports `*-UAT.md` glob → enters UAT mode.
    default: ""
  - name: lightpanda_port
    required: false
    description: TCP port for the lightpanda CDP server. Pick a unique port per concurrent worker so parallel validators don't collide.
    default: "9222"
  - name: cookies
    required: false
    description: Optional path (relative to worktree) to a JSON file of cookies to inject before navigation, e.g. for auth-gated routes. Format = output of `agent-browser cookies get all`. Empty = no cookies.
    default: ""
spawn:
  cwd: "{worktree}"
  agents:
    claude-code:
      launcher: cdp
      initial_wait_s: 8
      initial: |-
        You are a headless UI validation worker spawned by orca. You DO NOT fix code. You drive a headless browser via the `agent-browser` CLI backed by the `lightpanda` engine, exercise the running app at {app_url}, and write a structured review file. That's the whole job.

        Your worker_id is {worker_id}. Worktree (for code context only): {worktree}
        App: {app_url}
        Target focus: {target}
        Acceptance criteria source: {acceptance_criteria}
        Lightpanda CDP port: {lightpanda_port}
        Cookies file (optional): {cookies}

        ## Step 0 — Configure tooling (idempotent; skip already-installed pieces)

        Run these checks in order. If a check passes, skip its install. If it fails, install, then re-check. Do NOT proceed to Step 1 until both `lightpanda` and `agent-browser` answer `--version` cleanly.

        1. **Verify lightpanda binary**: `command -v lightpanda && lightpanda --version`. If missing:
           - macOS arm64: `curl -L -o /tmp/lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-aarch64-macos && chmod +x /tmp/lightpanda && sudo mv /tmp/lightpanda /usr/local/bin/lightpanda`
           - Linux x86_64: `curl -L -o /tmp/lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux && chmod +x /tmp/lightpanda && sudo mv /tmp/lightpanda /usr/local/bin/lightpanda`
           - Other platforms: tell the user via `## Notes` in the review and set `status: fail`. Do not try to build from source.

        2. **Verify agent-browser CLI**: `command -v agent-browser && agent-browser --version`. If missing:
           - Prefer `npm install -g agent-browser` (cross-platform).
           - macOS fallback: `brew install agent-browser`.

        3. **Start lightpanda CDP server in the background** on port {lightpanda_port}:
           ```bash
           # Kill any stale instance on this port (orca leaves nothing behind on clean exit, but be defensive).
           lsof -ti tcp:{lightpanda_port} | xargs -r kill -9 2>/dev/null
           nohup lightpanda serve --host 127.0.0.1 --port {lightpanda_port} \
             > .orca/logs/lightpanda-{worker_id}.log 2>&1 &
           echo $! > .orca/logs/lightpanda-{worker_id}.pid
           ```
           Wait up to 10s for the port to accept connections (`nc -z 127.0.0.1 {lightpanda_port}`). If it never opens, tail the log into the review's `## Notes`, set `status: fail`, emit `REVIEW_DONE`, and stop. Do not retry past 10s — lightpanda failing to bind almost always means a port collision or a binary-arch mismatch.

        4. **Point agent-browser at lightpanda for THIS shell**:
           ```bash
           export AGENT_BROWSER_ENGINE=lightpanda
           export AGENT_BROWSER_CDP_ENDPOINT=ws://127.0.0.1:{lightpanda_port}
           ```
           Sanity check: `agent-browser --engine lightpanda open about:blank && agent-browser get title`. If this errors, capture stderr to the review, set `status: fail`, emit `REVIEW_DONE`.

        5. **Reachability of the app**: `curl -fsS -o /dev/null -w '%{http_code}\n' {app_url}`. Anything other than 2xx/3xx → write a placeholder review with `status: fail` and the curl exit info, emit `REVIEW_DONE`. Lightpanda can't reach what curl can't reach.

        6. **Cookies (optional)**: if `{cookies}` is non-empty, after `agent-browser open {app_url}` (Step 1.1 below), inject them via `agent-browser cookies set` (one call per cookie from the JSON file). If injection fails, log to `## Notes` and continue without auth — partial coverage is better than skipping entirely.

        ## Step 1 — Resolve acceptance criteria

        Resolve `{acceptance_criteria}` exactly as ui-validator does:
        - **Glob characters** (`*`, `?`, `[]`): expand. Zero matches → `status: fail` with reason. Multiple matches → pick most recently modified (`ls -t`).
        - **Path**: read file.
        - **Inline text**: treat string as the spec.
        - **Empty**: derive from `{target}` + a quick scan of the worktree (recent commits, README, `.planning/`, `docs/`).
        - **`*-UAT.md` filename match**: enter **UAT mode** — see `## UAT mode` in the playbook body.

        ## Step 2 — Validate

        For each criterion (or each major flow if no criteria given), use agent-browser to exercise it. The standard loop is:

        ```bash
        agent-browser open {app_url}/<route>
        agent-browser snapshot              # accessibility tree with @e1, @e2, … refs
        agent-browser click @eN             # interact by ref from snapshot
        agent-browser fill @eM "test input"
        agent-browser wait --load networkidle
        agent-browser get text @eK          # assert
        agent-browser screenshot .orca/reviews/screenshots/{worker_id}/<n>.png
        ```

        For each flow, cover at least:
        - **Golden path**: navigate → primary action → expected outcome.
        - **One edge case**: empty input, invalid input, very long input, or rapid double-submit. Pick one that makes sense for the flow.
        - **Console / network errors**: after each major interaction, run `agent-browser eval 'JSON.stringify(window.__errors||[])'` if the app exposes an error log, OR check that no 4xx/5xx network responses fired (use `agent-browser network route` if needed to capture).

        Watch for:
        - Layout breaks (visible via screenshot diff against an "empty" baseline isn't supported here — eyeball the screenshot in the review)
        - JS exceptions surfaced via `agent-browser eval`
        - Failed network requests
        - Broken navigation (404s, redirects to error pages)
        - Missing/inaccessible elements when snapshot is empty for a region you expected to populate

        **Lightpanda limitations to remember**:
        - No persistent profile / storage state across sessions. Don't rely on localStorage or session cookies surviving a `close` → `open`.
        - No file uploads (`agent-browser fill` on `<input type="file">` is unsupported).
        - No extensions. If the app requires a Chrome extension, this playbook can't validate it — note that in `## Coverage` and skip those flows.
        - No headed mode. Visual regressions you'd catch by *watching* the browser must be inferred from screenshots.
        - Some heavy JS frameworks may render slowly or incompletely vs. real Chrome. If a route gives suspiciously empty snapshots, retry with `agent-browser wait --load networkidle` first; if still empty, mark the flow `skipped:` in coverage with reason "lightpanda render gap".

        ## Step 3 — Capture findings

        For every issue, capture the full ui-validator schema:
        - **route/page** (URL or page name)
        - **reproduction steps** (numbered, terse, copy-pasteable as `agent-browser` commands when possible)
        - **expected vs actual**
        - **severity**: critical | high | medium | low
        - **screenshot path** (`.orca/reviews/screenshots/{worker_id}/<n>.png`)

        ## Step 4 — Write the review

        Write to `.orca/reviews/ui-{worker_id}-{ts}.md` (relative to {worktree}). Use this exact shape:

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
        engine: lightpanda
        engine_version: <output of `lightpanda --version`>
        agent_browser_version: <output of `agent-browser --version`>
        severity_breakdown:
          critical: <int>
          high: <int>
          medium: <int>
          low: <int>
        reviewer_agent: claude-code
        duration_s: <int>
        ---

        ## Summary
        One paragraph: flows exercised, verdict, why. Mention any lightpanda-specific coverage gaps.

        ## Issues
        1. **[severity]** `<route>` — short title
           - Steps:
             1. `agent-browser open {app_url}/<route>`
             2. `agent-browser click @e3`
             3. `agent-browser get text @e7` → got "<actual>"
           - Expected: ...
           - Actual: ...
           - Screenshot: `.orca/reviews/screenshots/{worker_id}/1.png`

        2. ...

        ## Actionable items for next agent
        - Imperative, file/route cited, ready to send verbatim to a coding agent.
        - One bullet per item.

        ## Coverage
        - Flows exercised: list them
        - Flows skipped: list them with reason. Be explicit about lightpanda-imposed skips ("requires file upload — not supported by engine", "auth wall, no cookies provided").

        ## Notes
        Optional. Lightpanda render gaps, server log excerpts, anything weird.
        ```

        Same canonical convention as `~/.claude/skills/orca/references/review-format.md`.

        ## Step 5 — File actionable items into beads (if available)

        Same contract as ui-validator: probe `bd ready` in `{worktree}`. If it works, file each medium+ actionable item as `bd create "[<severity>] <route> — <summary>" -d "<repro+expected+actual+screenshot+source>" -p <priority> -l agent-browser-validator,severity-<severity>`. Severity → priority: critical=P0, high=P1, medium=P2. Skip low. Beads failures → log to `## Notes`, do not fail the review.

        ## Step 6 — Cleanup, then signal done

        Always run cleanup BEFORE emitting REVIEW_DONE so orca's pane close doesn't leave a stray lightpanda holding the port:

        ```bash
        agent-browser close 2>/dev/null || true
        if [[ -f .orca/logs/lightpanda-{worker_id}.pid ]]; then
          kill "$(cat .orca/logs/lightpanda-{worker_id}.pid)" 2>/dev/null || true
          rm -f .orca/logs/lightpanda-{worker_id}.pid
        fi
        ```

        Then echo this single line on its own, with NO other text on that line:

        ```
        REVIEW_DONE
        ```

        On any failure path above (lightpanda won't start, app unreachable, agent-browser broken, write error), still write a placeholder review with `status: fail` and the cause in `## Summary`, then run cleanup, then echo `REVIEW_DONE`. Missing review files are ambiguous; status:fail files are not.

        ## Hard rules

        - Never edit project code. No Edit, no Write outside `.orca/reviews/` and `.orca/logs/`. No commits.
        - Don't restart the app or change its config. If it's broken in a way that prevents QA, that IS the finding.
        - Don't ask clarifying questions — make a judgment, capture uncertainty in `## Notes`.
        - Don't summarize in chat at the end. The review file IS your output.
        - Take screenshots for failures, not for passes. Don't fill the screenshots dir with green-path captures.
        - Always cleanup the lightpanda process and its pidfile, even on fail paths.
    codex:
      launcher: codex --dangerously-bypass-approvals-and-sandbox
      initial_wait_s: 8
      initial: |-
        Same brief as the claude-code variant of this playbook — copy the entire `claude-code` block above and run it as-is. You have shell access; agent-browser is a CLI; lightpanda is a CLI. Computer use is NOT required for this playbook (that's what makes it cheap and parallelizable). Use shell commands only.

        Your worker_id is {worker_id}. Worktree: {worktree}. App: {app_url}. Target: {target}. Criteria: {acceptance_criteria}. Lightpanda port: {lightpanda_port}. Cookies: {cookies}.

        Output contract is identical: write `.orca/reviews/ui-{worker_id}-{ts}.md` with frontmatter (`reviewer_agent: codex`), then echo `REVIEW_DONE`. Cleanup the background lightpanda process before signaling done.

watch:
  - pattern: "^REVIEW_DONE$"
    action: stop
---

# Notes

## Purpose

Cheap, parallel-friendly, CI-friendly UI validation. The peer of `ui-validator.md`:

| Dimension | `ui-validator.md` (codex + computer use) | `agent-browser-validator.md` (any agent + lightpanda) |
|-----------|------------------------------------------|--------------------------------------------------------|
| Browser | Real Chrome, headed-ish (computer-use surface) | Lightpanda headless (CDP, no Chrome) |
| Cost | Higher — computer-use tokens are expensive | Lower — pure CLI roundtrips, compact text output |
| Parallelism | One Chrome surface at a time | One lightpanda port per worker → easy fan-out |
| Auth flows | Real-browser SSO, MFA, etc. work | Cookie injection only; SSO doesn't survive a session |
| Visual regressions | Eye-on-screen catches more | Screenshot-only, must be inferred |
| File uploads, extensions | Supported | Unsupported |
| CI/CD fit | Awkward (computer use needs a display surface) | Native fit |

Pick this playbook when you want a fast smoke pass, or want to run several validators in parallel against the same target, or are running in CI. Pick `ui-validator.md` when the bug is visual or the flow needs a real browser.

## Why claude-code as default agent

Both `claude-code` and `codex` can drive shell CLIs trivially — neither needs computer use for this. Defaulting to `claude-code` because it's the orchestrator's own runtime in the common case, so trust prompts and auth are already handled. Codex is the explicit alternative for users who prefer it (`/orca agent-browser-validator agent=codex …`).

## Required: app must be running

Same constraint as `ui-validator.md`. This playbook does not start, restart, or babysit your dev server. Have it up at `{app_url}` before invoking. Spawn a `dev-server` playbook (or run `npm run dev` in another pane) first if needed.

## Lightpanda configuration knobs

The brief uses sensible defaults; deeper knobs you might surface as params later if needed:

- `--obey-robots` / `--no-obey-robots` — default obeys robots.txt. For internal apps you may want to skip; not currently exposed as a param.
- `--log-level` — `info` is fine for the per-worker log; switch to `debug` only when troubleshooting.
- `--user-agent` — lightpanda sends its own UA by default; if your app sniffs UA and refuses unknown clients, override via `agent-browser` headers (post-Step-0 brief addition).

If you find yourself overriding these often, promote them to playbook params and template them into the `lightpanda serve` line in Step 0.3.

## Port collisions in parallel runs

The `{lightpanda_port}` param defaults to `9222` (lightpanda's own default). If you spawn multiple agent-browser-validator workers in the same tick (e.g., one against staging, one against local), each MUST get a distinct port:

```
/orca agent-browser-validator worktree=/path app_url=http://localhost:3000 lightpanda_port=9222
/orca agent-browser-validator worktree=/path app_url=http://localhost:3001 lightpanda_port=9223
```

The brief's Step 0.3 defensively kills any stale process on the chosen port before binding, so single-worker re-runs are safe. Cross-worker port collision is the user's responsibility to avoid via distinct params.

## Failure modes

| Symptom | Likely cause | Recovery |
|---------|--------------|----------|
| Review has `status: fail` with "lightpanda failed to bind" | Port already in use; arch mismatch on binary | Pick a different `lightpanda_port`; verify `file $(command -v lightpanda)` matches your platform |
| Review has `status: fail` with "cannot reach app_url" | App isn't running, wrong port, firewall | `curl {app_url}` from a terminal in the same shell context. Re-invoke. |
| Snapshots come back empty for a SPA route | Lightpanda render gap on heavy JS | Brief retries with `wait --load networkidle`; if still empty, validator marks flow `skipped:` in coverage. Consider `ui-validator.md` for those flows. |
| Worker hangs without emitting `REVIEW_DONE` | agent-browser session deadlocked, or lightpanda crashed mid-run | Tail `.orca/logs/lightpanda-<worker_id>.log`. Send `cmux send` of `agent-browser close` to unstick. Manual `/orca stop <worker_id>` if needed. |
| Issues reported but no screenshots | Worker skipped Step 2's screenshot calls | Re-read the brief — screenshots required for failures. Treat as a `needs-attention` followup on this playbook |
| `status: pass` despite obvious bugs | Validator covered too narrow a slice OR the bug is visual and lightpanda's screenshot didn't surface it | Pass a more specific `target` / `acceptance_criteria`, or re-run via `ui-validator.md` for visual confirmation |

## UAT mode

Identical to ui-validator's UAT mode — triggered when `{acceptance_criteria}` resolves to a `*-UAT.md` file. Parse the `## Tests` section; for each `### N. Name` with `expected:` line, exercise it via agent-browser; emit a `## UAT Responses` section with one line per test (`pass`, `issue: <text>`, or `skipped: <reason>`) numbered to match.

This playbook can serve as the `delegate.to:` target for GSD's `/gsd:verify-work` checkpoints exactly like `ui-validator` does — set `to: agent-browser-validator` instead of `to: ui-validator` in the GSD playbook's delegate rule when you want headless UAT instead of computer-use UAT.

Standard issue capture (`## Issues`) STILL applies in UAT mode; UAT Responses is *additional*.

## Cross-checks with code-review and ui-validator

Three-way cross-check is fine: spawn `code-review` + `ui-validator` + `agent-browser-validator` against the same target. Same review-chain aggregation handles all three (all write to `.orca/reviews/`, all use the canonical frontmatter schema). Disagreements between the two UI validators are interesting signal — they exercised the same app with different engines.

## Beads integration

Same as `ui-validator.md`: probe `bd ready`, file medium+ actionable items, label with `agent-browser-validator,severity-<severity>` so beads queries can distinguish findings by validator. Beads-less repos are unaffected.

## What this playbook deliberately omits

- **Self-healing flake retries**. If lightpanda flakes on a flow, the validator notes it and moves on. Adding retry-with-backoff would mask real instability.
- **Headed-mode fallback**. If you need to *watch* the browser, use `ui-validator.md` instead — that's what it's for.
- **Multi-engine fanout from one worker**. One worker = one engine. Want to compare engines? Spawn two workers.
