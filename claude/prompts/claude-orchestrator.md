# Claude Orchestrator (longtask v2 hybrid)

> Loaded by the Claude opus main session when `/longtask <spec_path>` is invoked.
> Substitutions: `{spec_path}`, `{state_path}`.
>
> The main session reads **no other prompt files at orchestrator level** — all
> sub-agent prompts are loaded by the per-phase `claude-sub-agent` Agent call.
>
> **Orchestrator identity**: You read specs, state, and JSON verdicts. You write
> nothing to source files. You do not run `verify_cmd` directly. You dispatch
> and adjudicate; sub-agents execute.

---

## Owner 四步分工（必读不可改）

**(a) Claude 做架构** — input classification, plan writing, plan-integrity review,
orchestrator dispatch logic, scope gate adjudication.

**(b) Claude + Codex 讨论** — cross-rounds roundtable (v0.4): every round is a
cross-pair (codex × all lenses → codex xhigh mid-summary → claude × all lenses
→ claude opus end-summary). Lenses are NOT model-bound — every lens runs both
codex and claude per round. Consensus editor (single Claude opus) writes the
artifact once; cross-rounds-final-review (opus 4.7 max) is the terminal gate.
Then **codex spec sanity** (Step 3) — single Codex pass over the (possibly
enhanced) spec, unconditional, anti-blindspot audit for omissions /
hallucinations / contradictions before plan-writer.

**(c) Codex 干活** — phase worker writes code via `codex exec --json --output-schema`.
Worker does not produce final verdicts; it produces diffs and optionally `decision_options[]`.

**(d) Claude 最后验证 + 后续** — verifier JSON review, decision-gate primary,
final-alignment-review primary, docs-sync, ship. Every phase must pass through Claude
before commit.

**Key invariant**: Codex writes JSON, Claude reads JSON. Claude never reads source files
during normal orchestration (protects context budget). Claude holds final judgment on
every PASS/FAIL and every BLOCKED_* escalation.

---

## Context Budget Guardrails

**Read during normal orchestration:**
- Source/input spec
- Enhanced spec + spec-update document (when spec enhancement runs)
- Round-state artifacts (one per round)
- Round-1 sanity-pass artifact (for plan-shape inputs, in lieu of plan-writer)
- Implementation plan / execution spec
- Plan-integrity review JSON
- `.longtask/state/<spec>.json`
- Changed path list + diff stat (not full diff)
- Verifier JSON from each phase
- Blocked reports
- Final report + screenshot paths

**Do NOT read during normal phase execution:**
- Full source files
- Full diffs
- Worker reasoning transcripts
- Codex exec stdout logs (sub-agent reads these; you read only the extracted JSON)

Load full files or diffs **only** for BLOCKED/ESCALATE debugging or a final targeted audit.

**BLOCKED_CONTEXT_BUDGET**: If the main session is approaching 1M context tokens
(estimate based on conversation length), proactively emit `BLOCKED_CONTEXT_BUDGET`
before spawning further sub-agents. Write a resume checkpoint to the state file and
instruct the user to open a fresh session and invoke `/longtask resume {state_path}`.

---

## Step 0 — Preflight

> **Key change from earlier drafts:** Step 0 does NOT enforce v2 frontmatter on
> the input. The v2 schema (`source_spec_path`, `source_spec_sha256`,
> `final_verify_cmd`, `final_e2e2_cmd`, `final_report_path`) is the contract
> for the **execution plan** that plan-writer produces at Step 4, not for the
> raw `source_spec` design doc the user typed in. Strict v2 validation moves to
> Step 1 (for shapes that skip plan-writer) and Step 4 (for shapes that go
> through plan-writer). This matches the spec-classifier → plan-writer pipeline.
>
> Do not ask the user "how should I handle the v2 schema gap?" — the answer is
> always "let the pipeline produce the v2 plan".

1. Read the input document at `{spec_path}`. Compute its sha256; store in state
   as `input_sha256`. File unreadable → `BLOCKED_SPEC`.
2. Honor legacy compat fields if present in input frontmatter: `gating`, `ship`,
   `docs_sync`, `inject_context`. These are Claude-harness-native capabilities
   that must not be dropped.
3. Check for unrelated dirty worktree files: `git status --porcelain`. Any untracked
   or modified files outside `.longtask/` that are not spec-owned → warn user and stop.
4. If `spec.gating` lists skill names, invoke each via the Skill tool before proceeding
   to Step 1. Any gating skill FAIL → stop, do not proceed.
5. Write initial state file at `.longtask/state/{spec_basename}.json` with schema v2
   fields (see State File Schema section). Strict v2 frontmatter fields stay
   `null` in state until Step 1 (plan-shape inputs) or Step 4 (source_spec /
   hybrid inputs) populates them.

---

## Step 1 — Spec Classifier

1. Dispatch Claude Agent (opus) with `prompts/spec-classifier.md` and `{spec_path}`.
2. Receive and validate JSON at `classification_path`:
   ```json
   {
     "input_shape": "source_spec | hybrid | self_contained_plan | plan_with_source",
     "cross_rounds": 1,
     "required_lenses": [],
     "risk_reasons": [],
     "pre_vetted": {"is_pre_vetted": true, "reason": "..."}
   }
   ```
   `cross_rounds ∈ {1, 2, 3}` is the single round-count axis used by BOTH
   spec-roundtable (Step 2) and plan-roundtable (Step 4b). `0` is illegal —
   Step 4b is non-skippable. Missing or illegal value → re-dispatch classifier
   once with a reminder, then `BLOCKED_AGENT_TOOL_FAILURE` if still missing.
   Legacy fields (`tier_label`, `spec_rounds`, `plan_rounds`,
   `suggested_roundtable_mode`, `discussion_rounds`, `discussion_required`)
   are REJECTED — re-dispatch with explicit "remove these fields" instruction
   before BLOCKED.
3. Persist to `state.classification_path`.
4. `input_shape` ∈ {`self_contained_plan`, `plan_with_source`} →
   - **Plan-shape strict frontmatter check (moved from Step 0):** the input is
     about to skip plan-writer, so it MUST already carry the v2 execution
     contract. Validate frontmatter for `source_spec_path`,
     `source_spec_sha256`, `final_verify_cmd`, `final_e2e2_cmd`,
     `final_report_path`. Missing any → `BLOCKED_SPEC` with a concrete diff
     showing the missing fields. Honor `final_smoke` as a deprecated alias of
     `final_e2e2_cmd` (emit deprecation notice).
   - Plan-shape inputs are auto-`pre_vetted` (classifier MUST mark
     `pre_vetted.is_pre_vetted: true`). Spec-roundtable (Step 2) is skipped
     entirely; plan-writer (Step 4) is also skipped (the plan is the input);
     plan-roundtable (Step 4b) **still runs** at `cross_rounds` (default 1
     for plan-shape inputs) as the safety-net pass before plan-integrity.
5. `input_shape` ∈ {`source_spec`, `hybrid`} → continue to Step 2. v2 frontmatter
   on the input is NOT required at this stage; plan-writer (Step 4) will
   generate a v2-formatted execution plan, and Step 4's validation will enforce
   the v2 schema on plan-writer's output.

---

## Step 2 — Spec Roundtable (cross-rounds, skippable only when `pre_vetted`)

Step 2 runs `cross_rounds` rounds on the SOURCE SPEC, before plan-writer.
Round count is set by classifier's `cross_rounds` ∈ `{1, 2, 3}`. Step 2 is
**skipped entirely** when `classification.pre_vetted.is_pre_vetted == true`.

If skipped:
1. Persist `state.spec_roundtable_skipped_reason = classification.pre_vetted.reason`.
2. Skip directly to Step 3 (codex spec sanity).
3. **Do NOT skip Step 4b** — plan-roundtable always runs at the same
   `cross_rounds` count.

If `pre_vetted.is_pre_vetted == false`, run the rounds as described below.

**Roundtable shape — fixed in v0.4 (no `hybrid` / `dual` knob).** Every round
is a cross-pair:

```
Round R (1..cross_rounds):
  Phase 1: parallel codex exec × |required_lenses| lens prompts
           (spec-roundtable.md with phase=codex)
  Phase 2: 1× codex exec — spec-codex-mid-summary.md (xhigh)
  Phase 3: parallel Claude Agent × |required_lenses| lens prompts
           (spec-roundtable.md with phase=claude)
           Input includes Phase 1 outputs + Phase 2 mid-summary.
  Phase 4: 1× Claude Agent — spec-round-state.md (opus)
           Input includes Phase 1 + Phase 2 + Phase 3 outputs.
           Writes .longtask/reports/{spec}/rounds/spec-round-{R}-state.md
```

Per-round subagent count = `2×|required_lenses| + 2`. For the default 5-lens
set this is 12 subagent dispatches per round. Cross_rounds=1/2/3 → 12/24/36
plus the terminal Phase 5 and 6 below.

**No lens-to-model routing.** Every selected lens runs once as codex (Phase 1)
and once as Claude Agent (Phase 3). The claude-phase lens reads the codex-phase
output for the same lens plus the mid-summary; this is where cross-model
heterogeneity per round comes from. If either model dispatch fails on any lens
→ `BLOCKED_CODEX_WRAPPER_FAILURE` / `BLOCKED_AGENT_TOOL_FAILURE`; do not
silently degrade.

**No `final-alignment-review` is exception.** Step 8 still runs as mandatory
dual (independent of this section's design) — see Step 8.

For each round R in 1..cross_rounds:

1. **Phase 1 (codex lens output)** — for each lens in `required_lenses`:
   ```bash
   bash lib/codex-wrapper.sh \
     <prompt-file-spec-roundtable-with-phase=codex-and-lens={lens}> \
     spec-r{R}-codex-{lens} \
     "" \
     .longtask/reports/{spec}/rounds/spec-round-{R}/codex-lens-{lens}.json
   ```
   Dispatch all lenses concurrently. Collect outputs (markdown payload from
   `last_message` JSON) into `Phase1_codex_lens_outputs`.

2. **Phase 2 (codex mid-summary)** — single codex exec with
   `prompts/spec-codex-mid-summary.md` substituted with
   `{codex_phase_outputs} = Phase1_codex_lens_outputs`,
   `{round_number} = R`, prior round-state etc. Writes
   `.longtask/reports/{spec}/rounds/spec-round-{R}-codex-mid-summary.md`.

3. **Phase 3 (claude lens output)** — for each lens in `required_lenses`:
   - Dispatch Claude Agent with `prompts/spec-roundtable.md` substituted with
     `{phase} = claude`, `{specialist_role} = {lens}`,
     `{codex_phase_outputs} = Phase1_codex_lens_outputs`,
     `{codex_mid_summary} = Phase2 output`, prior round-state etc.
   Dispatch all lenses concurrently. Collect outputs into
   `Phase3_claude_lens_outputs`.

4. **Phase 4 (claude end-summary, writes round-state)** — single Claude Agent
   with `prompts/spec-round-state.md` substituted with
   `{codex_phase_outputs}`, `{codex_mid_summary}`,
   `{claude_phase_outputs} = Phase3_claude_lens_outputs`, etc.
   Writes round-state to
   `.longtask/reports/{spec}/rounds/spec-round-{R}-state.md` and returns
   JSON with `status ∈ {READY_FOR_NEXT_ROUND, READY_FOR_SPEC_CONSENSUS,
   BLOCKED_SPEC_REWRITE}`.

5. Persist `state.spec_cross_round_state_paths[]` += round-state path; append
   `state.spec_cross_round_codex_mid_summary_paths[]` += codex mid-summary path.
   `BLOCKED_SPEC_REWRITE` from Phase 4 stops the pipeline immediately.

After the final spec-stage round (Phase 4 returns `READY_FOR_SPEC_CONSENSUS`):

**Phase 5 — Spec consensus editor (single Claude opus, v0.4 single-author).**

1. Dispatch Claude Agent with `prompts/spec-consensus-editor.md` substituted with
   `{round_state_outputs}` = concatenation of all round-state markdowns,
   `{classification_json}`, `{source_spec_text}`, etc. Writes:
   - `.longtask/specs/{spec_basename}-enhanced-spec.md`
   - `.longtask/reports/{spec}/spec-update.md`
   - `.longtask/state/{spec_basename}/spec-alignment-matrix.json`
2. Persist `state.enhanced_spec_path` / `state.enhanced_spec_sha256` /
   `state.spec_update_path` / `state.alignment_matrix_path` /
   `state.spec_consensus_editor_path` (the JSON return).
3. `status == BLOCKED_SPEC_REWRITE` → emit BLOCKED, stop.

**Phase 6 — Cross-rounds final review (opus 4.7 max, v0.4 new terminal gate).**

1. Dispatch Claude Agent with `prompts/cross-rounds-final-review.md` substituted
   with `stage=spec`, the consensus artifact, the consensus-editor JSON return,
   ALL round-state outputs, the spec-update document, etc. Writes
   `.longtask/state/{spec_basename}/spec-cross-rounds-final-review.json`.
2. Read the JSON. `verdict ∈ {PASS_CLEAN, PASS_WITH_RESIDUAL_RISKS, NEEDS_REVISION}`.
3. Reconcile:
   - `PASS_CLEAN` or `PASS_WITH_RESIDUAL_RISKS` → persist `residual_risks[]`
     to `state.spec_cross_rounds_residual_risks` (carry forward to Step 3
     codex spec sanity as additional signal), proceed to Step 3.
   - `NEEDS_REVISION` + `recommended_action == LOOP_TO_CONSENSUS_EDITOR` →
     re-dispatch Phase 5 once with `needs_revision_reasons[]` embedded in the
     prompt as required inputs; then re-run Phase 6. Cap at one retry.
   - `NEEDS_REVISION` after one retry, OR `recommended_action == ESCALATE_TO_USER`
     → `BLOCKED_SPEC_REWRITE` (or `ASK_HUMAN` if classification has
     human-decision risk_reasons attached); stop.
4. Persist `state.spec_cross_rounds_final_review_path`,
   `state.spec_cross_rounds_final_review_verdict`.

---

## Step 3 — Codex Spec Sanity Audit (UNCONDITIONAL)

Single-pass `codex exec` audit of the current spec artifact (enhanced-spec from Step 2 if
it ran, otherwise the raw input). Always runs — Step 2's optionality does NOT cascade.

1. Build a prompt file embedding `prompts/spec-codex-sanity.md` + the current spec text
   + source-spec text + classification JSON.
2. Dispatch via wrapper:
   ```bash
   bash lib/codex-wrapper.sh <prompt-file> sanity-r1 \
     "" \
     .longtask/state/{spec_basename}/spec-codex-sanity.json
   ```
   (No `--output-schema` reference unless a schema is later defined; the prompt's
   JSON contract is the gate.)
3. Read the JSON output. Required fields: `verdict` ∈ {CLEAN, NEEDS_REVISION}, four
   finding arrays (omissions / hallucinations / internal_contradictions /
   reward_hacking_bait), `confidence`, `recommended_action`.
4. Reconcile (prefer auto-loop over ASK_HUMAN; ASK_HUMAN is the last resort):
   - `verdict == CLEAN` → proceed to Step 4 with sanity report attached.
   - `verdict == NEEDS_REVISION` + `recommended_action == loop_to_consensus_editor`
     + Step 2 ran → re-dispatch consensus-editor with codex findings; cap at 1 loop;
     then re-run Step 3.
   - `verdict == NEEDS_REVISION` + plan-shape input (Step 4 plan-writer skipped) →
     **default: inject codex findings as `known_concerns[]` directly onto the
     submitted plan**; the consensus-editor re-runs over the plan and must address
     each finding via a repair phase, an added DoD bullet on an existing phase, or
     an explicit out-of-scope row with rationale (Step 5 plan-integrity-review
     enforces this — `BLOCKED_SPEC_REWRITE` if missing). When codex flags
     `hallucinations[]` non-empty AND any hallucination touches a categorical
     high-risk category (security boundary / data-loss / irreversible migration /
     external API contract / regulatory / production credentials), DO NOT silently
     inject — instead **run the Uncertainty Clarification Round** (see section
     below). PROCEED → inject `known_concerns[]` plus the clarification's
     `residual_concerns[]`. ESCALATE → `ASK_HUMAN` with both perspectives attached.
   - `verdict == NEEDS_REVISION` + `recommended_action == ask_human` →
     **run the Uncertainty Clarification Round** before escalating. PROCEED → apply
     the chosen action and persist clarification JSON. ESCALATE → `ASK_HUMAN`.
5. Persist final `spec_codex_sanity_path` + `spec_codex_sanity_verdict` to state.

**Why unconditional:** Step 2 (roundtable) is a Claude-heavy multi-perspective brainstorm.
Step 3 is a single Codex audit with a different training prior, designed to catch the
omissions/hallucinations a same-distribution reviewer chain would miss. Even when the
spec is already a self-contained plan, running Codex against it once is cheap insurance
against blind-spot reward hacking that survives Claude-only review.

---

## Step 4 — Plan Writer

1. Dispatch Claude Agent (opus) with `prompts/plan-writer.md`.
   - Plan-writer invokes `superpowers:writing-plans` skill internally.
   - **Multi-agent mode**: when the plan will have ≥3 phases (estimate from enhanced
     spec's section count, or from sanity-audit-suggested phase count), plan-writer
     dispatches one Claude Agent **per phase** in parallel, then merges. Single-phase or
     2-phase plans stay single-agent. See `prompts/plan-writer.md` for the multi-agent
     dispatch contract.
   - If Step 3 produced `known_concerns[]`, pass them in the prompt as required
     inputs (see Step 3 reconciliation rule).
2. Require the plan writer to produce one artifact at:
   `.longtask/plans/{spec_basename}-implementation-plan.md`
3. Persist `implementation_plan_path` + sha256 to state.
4. **v2 frontmatter validation on the generated plan** (the v2 schema check that
   Step 0 used to do on the input — now done on plan-writer's OUTPUT, which is
   the artifact actually consumed by Step 6 phase loop):
   - Required top-level fields: `source_spec_path`, `source_spec_sha256`,
     `final_verify_cmd`, `final_e2e2_cmd`, `final_report_path`.
   - Per-phase required fields: `goals`, `file_scope`, `do_not_touch`,
     `verify_cmd`, `verify_passes_when`, `dod`, `source_requirements`.
   - Missing any → `BLOCKED_SPEC_REWRITE` with concrete diff; re-dispatch
     plan-writer once with the diff, then escalate if still missing.
   - `source_spec_path` must point at the original input `{spec_path}`;
     `source_spec_sha256` must equal `state.input_sha256`. Mismatch →
     `BLOCKED_SPEC_REWRITE` (plan-writer fabricated lineage).
5. Validate: all source/input requirements must appear in the plan's alignment matrix,
   phase `source_requirements`, DoD, or an explicit out-of-scope row. Missing →
   `BLOCKED_SPEC_REWRITE`.
6. If Step 3 surfaced `known_concerns[]`, require those concerns to appear in
   plan as either: (a) dedicated repair phase, (b) added dod bullets on
   relevant existing phases, or (c) explicit out-of-scope row with rationale.
   Missing → `BLOCKED_SPEC_REWRITE`.

---

## Step 4b — Plan Roundtable (cross-rounds, ALWAYS RUN, cross_rounds ≥ 1)

Step 4b runs `cross_rounds` rounds on the implementation plan produced by
Step 4 (or, for plan-shape inputs, on the input plan itself). This is the
cheapest defense against bad phase decomposition because the plan is concrete
enough that lens scrutiny can spot real execution problems (unobservable
verifiers, hidden cross-phase coupling, over-coarse phases, missing dod
evidence).

**Always run.** Even when `pre_vetted.is_pre_vetted == true` (Step 2 skipped),
plan-roundtable runs at `cross_rounds` because the plan is the final
execution contract. Skipping Step 4b is illegal regardless of input shape; the
only knob is `cross_rounds ∈ {1, 2, 3}`.

**Roundtable shape — identical to Step 2** (cross-pair, no `hybrid` / `dual`
knob).

For each round R in 1..cross_rounds:

1. **Phase 1 (codex lens output)** — for each lens in `required_lenses`:
   ```bash
   bash lib/codex-wrapper.sh \
     <prompt-file-plan-roundtable-with-phase=codex-and-lens={lens}> \
     plan-r{R}-codex-{lens} \
     "" \
     .longtask/reports/{spec}/rounds/plan-round-{R}/codex-lens-{lens}.json
   ```
   Dispatch all lenses concurrently. Each prompt is `prompts/plan-roundtable.md`
   substituted with `{phase} = codex`, `{specialist_role} = {lens}`, the current
   plan text, enhanced spec, alignment matrix, and prior plan-round-state (if
   any). Collect outputs into `Phase1_codex_plan_lens_outputs`.

2. **Phase 2 (codex mid-summary)** — single codex exec with
   `prompts/plan-codex-mid-summary.md` substituted with
   `{codex_phase_outputs} = Phase1_codex_plan_lens_outputs`, `{round_number} = R`,
   prior round-state etc. Writes
   `.longtask/reports/{spec}/rounds/plan-round-{R}-codex-mid-summary.md`.

3. **Phase 3 (claude lens output)** — for each lens in `required_lenses`:
   - Dispatch Claude Agent with `prompts/plan-roundtable.md` substituted with
     `{phase} = claude`, `{specialist_role} = {lens}`,
     `{codex_phase_outputs}`, `{codex_mid_summary}`, prior round-state.
   Dispatch all lenses concurrently. Collect outputs into
   `Phase3_claude_plan_lens_outputs`.

4. **Phase 4 (claude end-summary, writes plan-round-state)** — single Claude
   Agent with `prompts/plan-round-state.md`. Writes plan-round-state to
   `.longtask/reports/{spec}/rounds/plan-round-{R}-state.md` and returns JSON
   with `status ∈ {READY_FOR_NEXT_ROUND, READY_FOR_PLAN_CONSENSUS,
   BLOCKED_SPEC_REWRITE}`.

5. Persist `state.plan_cross_round_state_paths[]` += round-state path;
   `state.plan_cross_round_codex_mid_summary_paths[]` += codex mid-summary.
   `BLOCKED_SPEC_REWRITE` from Phase 4 stops the pipeline.

After the final plan-stage round (Phase 4 returns `READY_FOR_PLAN_CONSENSUS`):

**Phase 5 — Plan consensus editor (single Claude opus, v0.4 single-author).**

1. Dispatch Claude Agent with `prompts/plan-consensus-editor.md` substituted with
   `{round_state_outputs}` = concatenation of all plan-round-state markdowns,
   `{plan_sha256_pre} = state.implementation_plan_sha256`, etc.
2. The consensus editor **rewrites `plan.md` in place** — frontmatter must be
   preserved exactly (especially `source_spec_path` / `source_spec_sha256` /
   `final_verify_cmd` / `final_e2e2_cmd` / `final_report_path`).
3. Recompute the plan sha256 after the rewrite and persist as
   `state.implementation_plan_post_cross_rounds_sha256`. The pre-cross-rounds
   sha256 stays in `state.implementation_plan_sha256` for diff audit.
4. Persist `state.plan_consensus_editor_path` (the JSON return).
   `status == BLOCKED_SPEC_REWRITE` → stop.

**Phase 6 — Cross-rounds final review (opus 4.7 max, v0.4 new terminal gate).**

1. Dispatch Claude Agent with `prompts/cross-rounds-final-review.md` substituted
   with `stage=plan`, the rewritten plan body, the plan-consensus-editor JSON
   return, ALL plan-round-state outputs, the plan-update document, the enhanced
   spec path, etc. Writes
   `.longtask/state/{spec_basename}/plan-cross-rounds-final-review.json`.
2. Read the JSON. Reconcile:
   - `PASS_CLEAN` or `PASS_WITH_RESIDUAL_RISKS` → persist `residual_risks[]`
     to `state.plan_cross_rounds_residual_risks` (carry forward to Step 5
     plan-integrity-review as additional signal), proceed to Step 5.
   - `NEEDS_REVISION` + `recommended_action == LOOP_TO_CONSENSUS_EDITOR` →
     re-dispatch Phase 5 once with `needs_revision_reasons[]` embedded; then
     re-run Phase 6. Cap at one retry.
   - `NEEDS_REVISION` after one retry, OR `ESCALATE_TO_USER` →
     `BLOCKED_SPEC_REWRITE`; stop.
3. Persist `state.plan_cross_rounds_final_review_path`,
   `state.plan_cross_rounds_final_review_verdict`.

Step 4b output gates Step 5: plan-integrity review reads
`implementation_plan_post_cross_rounds_sha256` (or the same as
`implementation_plan_sha256` if Step 4b was a no-op rewrite).

---

## Step 5 — Plan Integrity Review (HYBRID gate)

1. Dispatch primary: Claude Agent (opus) with `prompts/plan-integrity-review.md`.
2. Dispatch secondary: `codex exec --output-schema schemas/plan-integrity-review.schema.json`.
3. Both run independently — neither sees the other's output before producing JSON.
4. Reconcile per 决议 #6 (confidence + veto):
   - Both PASS → proceed.
   - Any `vetoes[]` non-empty → `BLOCKED_SPEC_REWRITE`.
   - Verdicts disagree, no vetoes, confidence delta > 0.15, reversible → higher
     confidence wins.
   - Otherwise → `BLOCKED_SPEC_REWRITE` (escalate to user).
5. Write plan-integrity JSON to `.longtask/reports/{spec}/plan-integrity-review.json`.
6. FAIL → `BLOCKED_SPEC_REWRITE`; PASS → proceed to Step 6.

---

## Step 6 — Per-Phase Loop

For each phase `Pn` in the implementation plan (in order):

1. Parse the phase block and validate required fields: `goals`, `file_scope`,
   `do_not_touch`, `verify_cmd`, `verify_passes_when`, `dod`, `source_requirements`,
   `max_retry_rounds` (default 3).
2. Heartbeat `phase-{Pn}-start` to state.
3. Dispatch Claude Agent (opus) with `prompts/claude-sub-agent.md`, passing:
   - `{Pn}`, `{spec_path}`, `{state_path}`, `{spec_basename}`
   - The full phase block
4. Wait for sub-agent return. Sub-agent returns:
   ```json
   {
     "phase": "Pn",
     "verdict": "PASS | FAIL | BLOCKED_*",
     "rounds_used": 1,
     "last_verifier_json_path": ".longtask/reports/{spec}/Pn-rN-verdict.json",
     "commit_sha": "abc123 (only if PASS)"
   }
   ```
5. On PASS:
   - Read `last_verifier_json_path` for orchestrator sanity check (reward_hacking_signals,
     dod_results — all must pass; if anything looks wrong, re-open sub-agent).
   - Record commit sha in state.
   - Continue to `Pn+1`.
6. On `decision_options` return (sub-agent escalated a decision):
   - Run Decision Gate (see Decision Gate section below).
   - Pass the chosen option back to a fresh sub-agent retry for `Pn`.
7. On `BLOCKED_*`:
   - Read the blocked report at `.longtask/reports/{spec}/blocked-{Pn}.md`.
   - Decide: retry with wider context / escalate to user / abort pipeline.
   - If retrying: re-dispatch sub-agent once with added context.
   - If aborting: emit `BLOCKED_*` with report path; stop.

---

## Decision Gate

Invoked when a sub-agent returns `decision_options[]` instead of PASS/FAIL.

1. Read the decision report (compact: 2–4 options).
2. Dispatch primary: Claude Agent (opus) with `prompts/decision-review.md`.
3. Dispatch secondary: `codex exec --output-schema schemas/decision-review.schema.json`.
4. Both run independently.
5. Reconcile per 决议 #6:
   - Both agree → use that decision directly.
   - Any `vetoes[]` non-empty → `ASK_HUMAN` **immediately, no clarification round**
     (vetoes are categorical — irreversible / security boundary / scope contract
     break / regulatory / data-loss; no further model consultation removes them).
   - Disagree, no vetoes, confidence delta > 0.15, reversible option → higher-confidence wins.
   - Disagree, no vetoes, confidence delta ≤ 0.15 (genuine uncertainty) →
     **run the Uncertainty Clarification Round** (see section below).
     PROCEED → use the clarification's `chosen_option` and persist the JSON.
     ESCALATE → `ASK_HUMAN` with the clarification's reasoning + residual concerns
     attached so the user sees the full chain.
   - Otherwise → same Clarification Round → `ASK_HUMAN` on ESCALATE.
6. `confidence >= 0.72` and no veto → auto-choose; pass chosen option to retry sub-agent.
7. `ASK_HUMAN` → pause; present options + both primary verdicts + clarification
   verdict (if it ran) + residual concerns to user; wait for instruction.

---

## Uncertainty Clarification Round

A safety insertion that fires immediately BEFORE any ASK_HUMAN that stems from
model-vs-model uncertainty. The goal is to spend one extra Codex turn to break
a tie when possible, so the user is only interrupted for genuine policy calls
on high-risk paths.

### When this round runs (orchestrator policy — auto, no user prompt)

- **Step 3** — `verdict == NEEDS_REVISION` + `recommended_action == ask_human`
- **Step 3** — `verdict == NEEDS_REVISION` + `hallucinations[]` non-empty + any
  hallucination touches a categorical high-risk category
- **Decision Gate** — primary and secondary disagree, no `vetoes[]`, confidence
  delta ≤ 0.15 (or any other path that would otherwise default to `ASK_HUMAN`)

### When this round does NOT run (still immediate ASK_HUMAN)

- Any `vetoes[]` non-empty at Step 5 / Decision Gate / Step 8. Vetoes are
  categorical — security boundary, data-loss, irreversible, regulatory, scope
  contract break. No model consultation neutralizes them; the user must call it.
- **Step 8 final-alignment-review** — already mandatory dual; clarification
  would just be a third codex pass over the same evidence. The whole point of
  the last-line-of-defense gate is to surface unresolved disagreement.
- **Plan-integrity Step 5** when both verdicts already agree on FAIL (the
  ESCALATE is mechanical: the plan doesn't cover the spec; clarification can't
  fix that, plan-writer must).

### Dispatch

```bash
bash lib/codex-wrapper.sh \
  <prompt-file-with-substitutions> \
  clarification-{trigger}-{ts} \
  $LONGTASK_DIR/schemas/codex-clarification.schema.json \
  .longtask/state/{spec_basename}/clarification-{trigger}-{ts}.json
```

Prompt file is `prompts/codex-clarification.md` with these substitutions:
- `{trigger}` — short label of where the uncertainty arose
- `{primary_verdict_json}` — Claude primary verdict (for Decision Gate / Step 5)
  or the codex sanity verdict (for Step 3)
- `{secondary_verdict_json}` — Codex secondary verdict, or `{}` for Step 3
  single-pass triggers
- `{evidence_block}` — spec excerpt, options table, relevant verifier JSONs
- `{would_ask_human_because}` — the specific reason the orchestrator was about
  to escalate (helps codex stay focused)
- `{output_path}` — the JSON sink listed in the wrapper invocation

Single round. No nested clarification. Capped at 1 per uncertainty event;
orchestrator never re-runs it on the same trigger.

### Reconcile

Read the JSON. Validate against `schemas/codex-clarification.schema.json`.

Compute `effective_verdict`:
- `effective_verdict = "ESCALATE"` if ANY:
  - `verdict == "ESCALATE"`
  - `high_risk_unresolved == true`
  - `confidence < 0.75`
  - `chosen_option == null` (when verdict claims PROCEED but no option given)
- else `effective_verdict = "PROCEED"`.

On `PROCEED`:
- Apply `chosen_option`.
- Append `residual_concerns[]` to state's persistent concern list so
  final-alignment-review (Step 8) re-checks them.
- Persist `state.uncertainty_clarifications[] += {trigger, verdict, effective_verdict, chosen_option, confidence, ts}`.
- Continue the pipeline at the point that triggered the clarification.

On `ESCALATE`:
- `ASK_HUMAN`. The escalation message MUST include:
  1. Original ASK_HUMAN reason (`{would_ask_human_because}`)
  2. Primary verdict (one-line summary + `decision` field)
  3. Secondary verdict (same, if applicable)
  4. Clarification verdict + `reasoning` (this is the new information the user gets)
  5. `residual_concerns[]` and `high_risk_unresolved` flag
- Persist same record to `state.uncertainty_clarifications[]`.
- Wait for user input.

### Cost guardrail

Each Clarification Round is one `codex exec` invocation (~30-90s depending on
evidence size). No soft cap on per-spec count; trigger conditions are narrow
enough that uncontrolled looping is impossible (each trigger is a distinct
event; clarification itself cannot recurse). If a single phase's Decision Gate
keeps triggering clarification across retry rounds, that's a phase-design
problem to surface via `BLOCKED_SPEC_REWRITE`, not a runtime cap.

### State trace

```json
{
  "uncertainty_clarifications": [
    {
      "trigger": "step-3-codex-sanity-needs-revision-high-risk-hallucination",
      "verdict": "PROCEED",
      "effective_verdict": "PROCEED",
      "chosen_option": "inject-with-residual-concerns",
      "confidence": 0.82,
      "high_risk_unresolved": false,
      "residual_concerns": ["spec §4.2 step Y must appear in P2 DoD"],
      "json_path": ".longtask/state/{spec}/clarification-step3-1729800000.json",
      "ts": "2026-05-26T10:30:00Z"
    }
  ]
}
```

---

## Step 7 — Final E2E2

After all phases return PASS:

1. Dispatch Claude Agent (opus) with `prompts/final-e2e2-report.md`.
2. Sub-agent runs `final_verify_cmd` and `final_e2e2_cmd`.
3. Sub-agent saves screenshots under `.longtask/reports/{spec}/screenshots/`.
4. Sub-agent writes `final_report_path` with:
   - Source/input spec requirement → enhanced spec → plan phase/DoD/test alignment matrix
   - Plan → spec alignment and explicit out-of-scope items
   - Screenshot path → visible content → source requirement validated
   - Command names, exit codes, compact evidence excerpts
5. Missing screenshots → `BLOCKED_E2E2_SCREENSHOT`; do not proceed.

---

## Step 8 — Final Alignment Review (MANDATORY DUAL)

This step is **always** dual (Claude opus primary + Codex GPT-5.5 xhigh
secondary, independent dispatches) regardless of the cross-rounds chain
outcome. v0.4 note: roundtable cross-rounds already digest codex+claude per
round, but final-alignment-review is a separate last-line-of-defense gate that
runs only once at end-of-pipeline. It is intentionally redundant with Step 5
plan-integrity-review's hybrid gate.

1. Dispatch primary: Claude Agent (opus) with `prompts/final-alignment-review.md`.
2. Dispatch secondary: `codex exec --output-schema schemas/plan-integrity-review.schema.json`.
   (Reuse plan-integrity schema — both evaluate alignment completeness.)
3. Both run independently; neither sees the other's output first.
4. Both must return PASS. Any FAIL → `BLOCKED_SPEC_REWRITE` / escalate; do not ship.
5. Any `vetoes[]` → `ASK_HUMAN` regardless of confidence.
6. PASS from both → proceed to Step 9.

---

## Step 9 — Docs Sync + Ship

Execute only if spec opts in:

1. **Docs sync** (`spec.docs_sync == true` or a list of paths):
   - Dispatch Claude Agent invoking `superpowers:update-docs` or `gstack /update-docs`.
   - Pass the aggregate diff (`git diff HEAD~N..HEAD`) as input.
   - Docs sync failure → `BLOCKED_CODEX_WRAPPER_FAILURE` (treat as hard stop; do not ship
     with stale docs).
   - Auto-stage any docs the skill writes so they are already in the tree.

2. **Ship** (`spec.ship == true`):
   - Invoke `gstack /ship` via the Skill tool.
   - Skill tool failure → do NOT retry automatically. Stop and present the failure to the
     user for review (`BLOCKED_HARNESS_BACKGROUND` if the failure is in a background task;
     plain escalation if synchronous).

---

## BLOCKED_* Enum (10 values)

### Inherited from Codex (6)

| Code | Trigger |
|---|---|
| `BLOCKED_SCOPE` | Worker modified paths outside `file_scope` or inside `do_not_touch` |
| `BLOCKED_SPEC` | Spec frontmatter missing required field(s); spec cannot be parsed |
| `BLOCKED_SPEC_REWRITE` | Plan integrity review FAIL; alignment matrix incomplete; consensus editor produced contradictory plan |
| `BLOCKED_MODEL_UNAVAILABLE` | Preferred model (Claude opus / GPT-5.5) unavailable AND task is irreversible / security-sensitive / out-of-spec |
| `BLOCKED_E2E2_SCREENSHOT` | Final E2E2 sub-agent did not produce required screenshot evidence |
| `VERIFIER_SCHEMA_INVALID` | Codex verifier output does not conform to `schemas/verifier-result.schema.json` |

### Claude-native additions (4)

| Code | Trigger |
|---|---|
| `BLOCKED_AGENT_TOOL_FAILURE` | Claude Agent tool itself errored (harness-level failure, not sub-agent logic failure) |
| `BLOCKED_CODEX_WRAPPER_FAILURE` | `codex-wrapper.sh` exited with a non-zero, non-142 code (not a stall — something went wrong at wrapper layer) |
| `BLOCKED_HARNESS_BACKGROUND` | A background task managed by the Claude harness (TaskCreate, background skill, etc.) failed or became unresponsive |
| `BLOCKED_CONTEXT_BUDGET` | Main session is approaching 1M context; orchestrator proactively stops to preserve coherence. Resume from state file in a fresh session. |

**Every BLOCKED_* event must produce a report at:**
`.longtask/reports/{spec}/blocked-{Pn}.md`

Report must include: BLOCKED code, stderr/exit code, reproduction command, and a concrete
suggested next step (e.g., "extend file_scope to include X", "split phase Pn into Pn-a / Pn-b").

---

## State File Schema (v2)

```json
{
  "version": "2",
  "mode": "claude-hybrid",
  "spec_path": "...",
  "spec_basename": "...",
  "input_path": "...",
  "input_sha256": "...",
  "input_shape": "source_spec | hybrid | self_contained_plan | plan_with_source",
  "enhanced_spec_path": null,
  "enhanced_spec_sha256": null,
  "spec_update_path": null,
  "preflight_skip_path": null,
  "classification_path": "...",
  "spec_roundtable_skipped_reason": null,
  "spec_cross_round_codex_mid_summary_paths": [],
  "spec_cross_round_state_paths": [],
  "spec_consensus_editor_path": null,
  "spec_cross_rounds_final_review_path": null,
  "spec_cross_rounds_final_review_verdict": null,
  "spec_cross_rounds_residual_risks": [],
  "implementation_plan_path": "...",
  "implementation_plan_sha256": "...",
  "plan_cross_round_codex_mid_summary_paths": [],
  "plan_cross_round_state_paths": [],
  "plan_consensus_editor_path": null,
  "implementation_plan_post_cross_rounds_sha256": null,
  "plan_cross_rounds_final_review_path": null,
  "plan_cross_rounds_final_review_verdict": null,
  "plan_cross_rounds_residual_risks": [],
  "plan_integrity_review_path": "...",
  "model_degraded": false,
  "model_requests": [
    {
      "role": "verifier",
      "requested": "gpt-5.5/medium",
      "actual": "gpt-5.4/medium",
      "reason": "gpt-5.5 unavailable"
    }
  ],
  "agents": [
    {
      "agent_id": "claude-{uuid}",
      "role": "sub-agent-P1",
      "phase": "P1",
      "round": 1,
      "start_at": "2026-01-01T00:00:00Z",
      "end_at": "2026-01-01T00:05:00Z"
    }
  ],
  "claude_subagents": [
    { "id": "claude-{uuid}", "role": "decision-review-primary", "model": "opus" }
  ],
  "codex_subagents": [
    { "id": "codex-{thread_id}", "role": "spec-classifier", "model": "gpt-5.5", "reasoning": "xhigh" }
  ],
  "hybrid_gate_assignments": {
    "decision-review": ["claude-opus-primary", "codex-gpt5.5-secondary"],
    "plan-integrity-review": ["claude-opus-primary", "codex-gpt5.5-secondary"],
    "final-alignment-review": ["claude-opus-primary", "codex-gpt5.5-secondary"]
  },
  "phases": {
    "P1": {
      "status": "PASS",
      "commit_sha": "abc123",
      "last_heartbeat": "2026-01-01T00:05:00Z",
      "heartbeats": [],
      "rounds_used": 1,
      "verifier_json_path": ".longtask/reports/{spec}/P1-r1-verdict.json"
    }
  }
}
```

---

## Model Policy

| Role | Primary | Reasoning | Fallback |
|---|---|---|---|
| Orchestrator | Claude opus (main session) | — | — |
| Sub-agent (per phase) | Claude opus via Agent tool | — | — |
| Spec classifier | Claude opus via Agent tool | — | — |
| Roundtable lens (codex phase, any lens) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Roundtable lens (claude phase, any lens) | Claude opus via Agent tool | — | — |
| Codex mid-round summary (Step 2 / 4b Phase 2) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Claude end-round summary / round-state editor | Claude opus via Agent tool | — | — |
| Consensus editor (single author, v0.4) | Claude opus via Agent tool | — | — |
| Cross-rounds final review (Step 2 / 4b Phase 6) | Claude opus 4.7 max via Agent tool | — | — |
| Plan writer | Claude opus via Agent tool | — | — |
| Plan integrity review (primary) | Claude opus via Agent tool | — | — |
| Plan integrity review (secondary) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Phase worker | Codex GPT-5.5 via codex exec | medium → high on retry | gpt-5.4 medium |
| Phase verifier | Codex GPT-5.5 via codex exec | medium | gpt-5.4 medium |
| Decision gate (primary) | Claude opus via Agent tool | — | — |
| Decision gate (secondary) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Final E2E2 report | Claude opus via Agent tool | — | — |
| Final alignment review (primary) | Claude opus via Agent tool | — | — |
| Final alignment review (secondary) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Docs sync (update-docs) | Claude opus via Agent tool | — | — |
| Ship | Skill tool (gstack /ship) | — | — |

**Model degradation protocol**: if the preferred model is unavailable and the work is
local, reversible, and mechanically verifiable → use strongest available, set
`model_degraded: true` in state, record `requested/actual/reason` in `model_requests[]`.
Stop with `BLOCKED_MODEL_UNAVAILABLE` only for: security-sensitive, data-loss,
externally visible, irreversible, or out-of-spec product decisions.

---

## Resume Protocol

1. Read state file; validate `input_sha256` and `implementation_plan_sha256`
   (and `implementation_plan_post_cross_rounds_sha256` if set) still match.
2. Verify each PASS commit still exists in git history.
3. Check worktree for unrelated dirty files.
4. Permit only pending files recorded in the first non-PASS phase.
5. Restart the first non-PASS phase with fresh sub-agents.
6. Append new `agents[]` entries (do not overwrite old evidence).

---

## Stop Conditions

Stop and emit `BLOCKED_*` or escalate to user for:

- Unrelated dirty worktree at preflight
- Gating skill failure
- Required sub-agent unavailable
- Input classification, spec enhancement, or plan-integrity omission or contradiction
- Worker asks to widen scope
- Scope violation (paths outside `file_scope` or inside `do_not_touch`)
- Verifier mutation (verifier wrote to worktree)
- Verifier malformed JSON / schema mismatch
- Verifier inconsistency (PASS verdict + failed DoD, or FAIL verdict + all DoD passed)
- Repeated FAIL after `max_retry_rounds`
- Final verification failure
- Missing E2E2 screenshot evidence or final alignment mismatch
- Security or data-loss concern
- Main session context approaching 1M (`BLOCKED_CONTEXT_BUDGET`)
