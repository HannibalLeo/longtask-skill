# Longtask Parent Conductor Checklist

The parent Codex session uses this checklist when running native subagent mode.
The parent writes no feature code.

## Context Budget

Read normally:

- spec
- `.longtask/state/<spec>.json`
- changed path list
- diff stat
- verifier JSON
- blocked report

Avoid during normal phase execution:

- full source files
- full diffs
- worker reasoning transcripts

Load full files or diffs only for BLOCKED/ESCALATE debugging or a final targeted
audit.

## Model Budget

Do not let worker/verifier subagents blindly inherit an expensive parent setting.
Use explicit reasoning choices:

- worker: `medium`
- first verifier: `medium`
- retry worker after repeated FAIL: `high`
- final reviewer: `high`
- `xhigh`: only for repeated BLOCKED, security/data-loss risk, or explicit user
  request

Prefer two independent `medium` verifier passes over one `xhigh` verifier for
risky phases.

## Decision Gate

When a worker/verifier returns a choice instead of a clear PASS/FAIL:

1. Require a compact decision report with 2-4 options.
2. Use repo evidence first.
3. Search official docs/release notes/upstream issues when the choice depends on
   current external behavior.
4. Run `prompts/decision-review.md`.
5. Validate the decision against `schemas/decision-review.schema.json`.
6. Auto-choose only when `confidence >= 0.72` and `decision == CHOOSE_OPTION`.
7. Ask the human only for `ASK_HUMAN`, `STOP_UNSAFE`, irreversible behavior,
   product-scope changes, or low confidence.

Use xhigh + CEO/Eng/Design-style review only for high-risk or low-confidence
decisions. Do not spend that budget on routine implementation choices.

## Per Phase

1. Parse the phase block and validate required fields.
2. Spawn one worker subagent with `prompts/worker.md`.
3. Wait for the worker.
4. If worker returns `decision_options`, run the Decision Gate and either pass
   the chosen follow-up to a retry worker or stop for human input.
5. Run git hard gates:
   - `git status --porcelain=v1`
   - `git diff --name-only HEAD`
   - reject paths outside `file_scope`
   - reject paths inside `do_not_touch`
6. Spawn one fresh verifier subagent with `prompts/verifier.md`.
7. Wait for verifier JSON.
8. Extract exactly one JSON object from the verifier final message, validate it
   against `schemas/verifier-result.schema.json`, and write it to
   `.longtask/reports/<spec>/<Pn>-r<N>-verdict.json`.
9. Confirm verifier did not mutate the worktree.
10. PASS only when verifier JSON, `verify_cmd_exit`, DoD bullets, and
   reward-hacking checks all pass.
11. Commit only changed phase files.
12. Retry with `prompts/retry-worker.md` until `max_retry_rounds`; then write a
    blocked report and stop.

## Resume

1. Read state and validate spec hash.
2. Verify each PASS commit still exists.
3. Check the worktree for unrelated dirty files.
4. Permit only pending files recorded in the first non-PASS phase.
5. Restart the first non-PASS phase with fresh subagents.
6. Append new `agents[]` evidence instead of overwriting old evidence.

## Stop Conditions

- dirty unrelated worktree
- worker asks to widen scope
- scope violation
- verifier mutation
- verifier malformed JSON
- verifier inconsistency
- repeated FAIL
- final verification failure
- security or data-loss concern
