# Longtask Parent Conductor Checklist

The parent Codex session uses this checklist when running native subagent mode.
The parent writes no feature code and performs no task sub-step directly.

The parent may only conduct: read compact contracts/evidence, spawn subagents,
run git scope/status gates, validate schemas/artifacts, write state,
stage/commit verified files, and report. Input classification, spec
enhancement, plan writing, plan-integrity review, implementation, verification
commands, E2E2, screenshots, reports, decisions, and final alignment review are
subagent work.

## Context Budget

Read normally:

- source/input spec
- enhanced spec and spec-update document, when created
- round-state artifacts, when spec enhancement runs
- preflight skip document, when the input is already an implementation plan
- implementation plan / execution spec
- plan-integrity review JSON
- `.longtask/state/<spec>.json`
- changed path list
- diff stat
- verifier JSON
- blocked report
- final report and screenshot paths

Avoid during normal phase execution:

- full source files
- full diffs
- worker reasoning transcripts

Load full files or diffs only for BLOCKED/ESCALATE debugging or a final targeted
audit.

## Model Budget

Do not let worker/verifier subagents blindly inherit an expensive parent setting.
The conductor session itself typically runs at `gpt-5.5` + `xhigh`; **execution
sub-agents must drop down** unless the phase frontmatter explicitly bumps.

**For worker / retry-worker / verifier, read the reasoning effort from the
plan frontmatter, not from the conductor's runtime setting.** Resolution:

```
phase.reasoning_effort  >  spec.default_reasoning_effort  >  hard fallback 'medium'
```

When dispatching the codex subagent, pass `-c model_reasoning_effort="<resolved>"`
explicitly to the wrapper or set `CODEX_LONGTASK_REASONING` in the call's env.

Use explicit reasoning choices:

- worker: resolved from frontmatter (default `medium`); pass via
  `model_reasoning_effort` config when spawning
- retry worker: same as worker, **auto-escalated one tier** (medium → high →
  xhigh) per retry round, unless the phase pinned `reasoning_effort` (a pin
  disables auto-escalation; log `model_degraded: false, reason:
  "pinned_by_phase"`)
- verifier: same resolved effort as the worker for the same phase; escalate
  one tier on next round if verifier JSON came back inconsistent or
  reward-hacking-suspicious
- input classifier: `gpt-5.5` with `xhigh` reasoning
- spec specialist discussion agents: `gpt-5.5` with `high` reasoning, escalating
  to `xhigh` for high-risk domain/product/data/security/UI decisions
- round-state editor: `gpt-5.5` with `high` reasoning, escalating to `xhigh`
  when disagreement changes scope, data, safety, or product contract
- consensus editor: `gpt-5.5` with `xhigh` reasoning
- implementation plan writer: `gpt-5.5` with `xhigh` reasoning
- plan integrity reviewer: `gpt-5.5` with `xhigh` reasoning
- decision reviewer: `gpt-5.5` with `xhigh` reasoning, including simple local
  auto-decisions
- final E2E2/report subagent: `gpt-5.5` with `xhigh` reasoning
- final alignment reviewer: `gpt-5.5` with `xhigh` reasoning

Prefer two independent `medium` verifier passes over one `xhigh` verifier for
risky phases. Do not spend `gpt-5.5` + `xhigh` on ordinary worker/verifier
passes unless the phase frontmatter explicitly pins `reasoning_effort: xhigh`.

If a preferred model or reasoning override is unavailable, use the strongest
available model/reasoning, record `model_degraded: true` plus requested/actual
model details in state, and continue when the work is local, reversible, and
mechanically verifiable. Stop with `BLOCKED_MODEL_UNAVAILABLE` only for
security-sensitive, data-loss, externally visible, irreversible, or out-of-spec
product decisions.

## Input Classification And Preflight

The user may invoke longtask with a source spec, hybrid spec/plan, a
self-contained implementation plan, or a plan with source-spec lineage.

Before phase execution:

1. Read the input document.
2. Spawn a fresh input classifier subagent using `gpt-5.5` with `xhigh`
   reasoning and `prompts/spec-classifier.md`.
3. Record `.longtask/reports/<spec>/spec-classification.json`.
4. If the classifier says `self_contained_plan`, confirm execution schema,
   internal phase/DoD/final-gate coverage, and self-consistency. Write
   `.longtask/reports/<spec>/preflight-skip.md` and skip only spec enhancement
   and plan writing.
5. If the classifier says `plan_with_source`, confirm execution schema,
   source-requirement alignment, final E2E2/report contract, and no source
   information loss. Write `.longtask/reports/<spec>/preflight-skip.md` and skip
   only spec enhancement and plan writing.
6. If the classifier says `source_spec` or `hybrid`, run
   `prompts/spec-roundtable.md` for exactly five rounds with the needed gstack
   specialist lenses. After each round, run `prompts/spec-round-state.md` and
   write `.longtask/reports/<spec>/rounds/round-<N>-state.md`; the next round
   must use that state as its draft/consensus/disagreement source. Then have a
   consensus editor use
   `prompts/spec-consensus-editor.md` to write:
   - `.longtask/specs/<spec_basename>-enhanced-spec.md`
   - `.longtask/reports/<spec>/spec-update.md`
7. For `source_spec` or `hybrid` input, spawn the implementation plan writer with
   `prompts/plan-writer.md`; require it to use `writing-plans` and produce one
   artifact at `.longtask/plans/<spec_basename>-implementation-plan.md`.
8. Spawn the plan-integrity reviewer with `prompts/plan-integrity-review.md`.
   Extract exactly one JSON object, validate it against
   `schemas/plan-integrity-review.schema.json`, and require PASS before phase
   execution.
9. Validate that all source/input and enhanced requirements are represented in
   the alignment matrix, phase `source_requirements`, DoD, or an explicit
   out-of-scope row.
10. Require final E2E2/browser verification and screenshot reporting.
11. Stop with `BLOCKED_SPEC_REWRITE` on omissions, contradictions, missing final
    E2E2, an impossible screenshot contract, or failed plan-integrity review.

## Decision Gate

When a worker/verifier returns a choice instead of a clear PASS/FAIL:

1. Require a compact decision report with 2-4 options.
2. Use repo evidence first.
3. Search official docs/release notes/upstream issues when the choice depends on
   current external behavior.
4. Spawn a fresh decision-review subagent with `prompts/decision-review.md`
   using `gpt-5.5` with `xhigh` reasoning when available, otherwise follow the
   model degradation policy.
5. Validate the decision against `schemas/decision-review.schema.json`.
6. Auto-choose when `confidence >= 0.72` and `decision == CHOOSE_OPTION`.
7. If confidence is lower but the option is local, reversible, and inside spec,
   choose the most conservative complete option and record the assumption.
8. Ask the human only for irreversible behavior, security/data-loss risk,
   externally visible action, or an out-of-spec product change.

Use the CEO/Eng/Design lenses inside the `gpt-5.5` + `xhigh` review. The user
explicitly wants simple intermediate decisions handled by that reviewer instead
of pausing for confirmation.

## Per Phase

**Dispatch contract — MUST use `codex exec` children, MUST NOT run inline.**
Your interactive codex session is the conductor. Every worker, verifier,
and retry-worker turn is a **separate `codex exec` child** spawned via
`codex/lib/codex-wrapper.sh`. Inheriting your parent session's reasoning
effort (typically `xhigh`) for all phases is the bug this contract
prevents — drop down per phase per the resolved `reasoning_effort`.

1. Parse the phase block from the implementation plan / execution spec and
   validate required fields.
2. **Resolve worker reasoning effort**:
   `resolved_effort = phase.reasoning_effort or spec.default_reasoning_effort or 'medium'`.
   Unknown value → `BLOCKED_SPEC`.
3. **Spawn one worker subagent** with `prompts/worker.md` via the wrapper.
   Pass `CODEX_LONGTASK_REASONING=$resolved_effort` so the child runs at
   the resolved tier (not your conductor's tier):

   ```bash
   PROMPT=$(mktemp /tmp/longtask-worker-{Pn}-r{N}.XXXX.txt)
   cat > "$PROMPT" <<'PROMPTEOF'
   <assembled worker prompt — known-traps-universal.md (codex worker; no claude-only) + project context + worker.md>
   PROMPTEOF
   CODEX_LONGTASK_REASONING="$resolved_effort" \
   CODEX_LONGTASK_MODEL=gpt-5.5 \
     bash codex/lib/codex-wrapper.sh "$PROMPT" "{Pn}-r{N}-worker"
   ```

4. Wait for the worker.
5. If worker returns `decision_options`, run the Decision Gate and either pass
   the chosen follow-up to a retry worker or stop for a hard risk.
6. Run git hard gates **in your own context**:
   - `git status --porcelain=v1`
   - `git diff --name-only HEAD`
   - reject paths outside `file_scope`
   - reject paths inside `do_not_touch`
   - ignore `.longtask/**`, the source/input spec, and the implementation plan
     artifact unless the phase explicitly owns them
7. **Spawn one fresh verifier subagent** with `prompts/verifier.md` via the
   wrapper, **with schema enforcement**:

   ```bash
   B_PROMPT=$(mktemp /tmp/longtask-verifier-{Pn}-r{N}.XXXX.txt)
   VERDICT=.longtask/reports/<spec>/<Pn>-r<N>-verdict.json
   mkdir -p "$(dirname "$VERDICT")"
   cat > "$B_PROMPT" <<'PROMPTEOF'
   <assembled verifier prompt — known-traps-universal.md checklist reference (cats 2 + 4) + verifier.md>
   PROMPTEOF
   CODEX_LONGTASK_REASONING="$resolved_effort" \
   CODEX_LONGTASK_MODEL=gpt-5.5 \
     bash codex/lib/codex-wrapper.sh \
     "$B_PROMPT" "{Pn}-r{N}-verifier" \
     shared/schemas/verifier-result.schema.json \
     "$VERDICT"
   ```

8. Wait for verifier JSON.
9. Validate `$VERDICT` against `schemas/verifier-result.schema.json` (path
   already populated by `--output-schema` in step 7; if missing or invalid
   → `VERIFIER_SCHEMA_INVALID`).
10. Confirm verifier did not mutate the worktree.
11. PASS only when verifier JSON, `verify_cmd_exit`, DoD bullets, and
    reward-hacking checks all pass.
12. Commit only changed phase files (you, the conductor, run this — NOT the
    worker child):

    ```bash
    git add -A && git commit -m "[longtask:<spec_basename>:{Pn}] <one-liner>"
    ```

13. On FAIL: reset worktree, auto-bump `resolved_effort` one tier
    (medium → high → xhigh) unless phase pinned, spawn retry-worker child
    via the wrapper with `prompts/retry-worker.md` prepended carrying the
    prior verdict JSON. Up to `max_retry_rounds`. Then write a blocked
    report and stop.

**Anti-pattern to avoid:** do NOT read `worker.md` / `verifier.md` /
`retry-worker.md` and execute them inline in your own context. Your
context is the conductor — your job is `codex exec` dispatch, JSON
parsing, scope gate, commit. Running the phase work inline defeats the
cross-context isolation that prevents reward-hacking and keeps execution
at the resolved (cheaper) `reasoning_effort` instead of your session's
`xhigh`.

## Resume

1. Read state and validate input, enhanced-spec when present, and
   implementation-plan hashes.
2. Verify each PASS commit still exists.
3. Check the worktree for unrelated dirty files.
4. Permit only pending files recorded in the first non-PASS phase.
5. Restart the first non-PASS phase with fresh subagents.
6. Append new `agents[]` evidence instead of overwriting old evidence.

## Final E2E2 and Report

After all phases pass:

1. Spawn a fresh final E2E2/report subagent with
   `prompts/final-e2e2-report.md` using `gpt-5.5` with `xhigh` reasoning.
2. The subagent runs `final_verify_cmd`.
3. The subagent runs `final_e2e2_cmd` or an explicitly equivalent
   `final_smoke_cmd`.
4. The subagent saves screenshots under `.longtask/reports/<spec>/screenshots/`.
5. The subagent writes `.longtask/reports/<spec>/final-report.md` with:
   - source/input spec requirement -> enhanced spec -> plan phase/DoD/test
     alignment
   - plan -> source/input spec alignment and any explicit out-of-scope items
   - screenshot path -> visible content -> source requirement validated
   - command names, exit codes, and compact evidence excerpts
6. Spawn a fresh final alignment reviewer subagent with
   `prompts/final-alignment-review.md` using `gpt-5.5` + `xhigh` when
   available, otherwise follow the model degradation policy. Completion requires
   no omitted source requirements and screenshot evidence that matches the
   report.

## Stop Conditions

- dirty unrelated worktree
- required subagent unavailable
- input classification, spec enhancement, or plan-integrity omission or
  contradiction
- worker asks to widen scope
- scope violation
- verifier mutation
- verifier malformed JSON
- verifier inconsistency
- repeated FAIL
- final verification failure
- missing E2E2 screenshot evidence or final alignment mismatch
- security or data-loss concern
