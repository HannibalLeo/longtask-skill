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

## Codex role boundary (load-bearing invariant — REQ-008, 2026-05-27 refactor)

Codex sub-agents are limited to **two role categories** in claude-flow:

- **Discussion**: codex spec sanity (Step 2). Plan-stage Codex cross-voice is
  no longer dispatched by the orchestrator directly — it is handled internally
  by the gstack `autoplan` skill at Step 4 (autoplan runs each role as both a
  Claude subagent and a Codex voice, and degrades gracefully to Claude-only
  when Codex is unavailable).
- **Verification**: phase verifier (Step 6), plan-integrity secondary
  (Step 5), decision-review secondary (Step 6 gate), final-alignment
  secondary (Step 8).

**All authoring, editing, and worker roles stay on Claude:** spec classifier,
plan writer, final E2E2 report, decision-review primary, plan-integrity
primary, final-alignment primary, docs-sync, ship, and the Step 6 phase
worker. Any new role that lands here MUST classify into one of those two codex
categories above; otherwise it stays on Claude.

## Owner 四步分工（必读不可改）

**(a) Claude 做架构** — input classification, plan writing, plan-integrity review,
orchestrator dispatch logic, scope gate adjudication.

**(b) Claude + Codex 讨论** — two checkpoints, both lightweight:
1. **Codex spec sanity** (Step 2) — single Codex pass over the spec,
   automated, anti-blindspot audit for omissions / hallucinations /
   contradictions / source-spec consistency before plan-writer. Returns
   `CLEAN` | `NEEDS_REVISION`. `CLEAN` → straight to plan-writer;
   `NEEDS_REVISION` → exactly one spec-revision pass, then continue.
2. **Plan review via `autoplan`** (Step 4) — the gstack `autoplan` skill,
   invoked from the main session. It runs the CEO / design / eng / DevEx
   roles (each as both a Claude subagent and a Codex cross-voice), auto-decides
   most points via its 6 principles, surfaces taste decisions / codex
   disagreements at a user approval gate, and writes a `## GSTACK REVIEW
   REPORT` into the plan file. The orchestrator does NOT maintain its own
   plan-stage lens prompts or codex mid-summaries — autoplan owns that.

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
- Codex spec sanity JSON (Step 2)
- Implementation plan / execution spec
- Plan file's `## GSTACK REVIEW REPORT` section (written by autoplan at Step 4)
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
     "required_lenses": [],
     "risk_reasons": [],
     "pre_vetted": {"is_pre_vetted": true, "reason": "..."}
   }
   ```
   The classifier no longer emits a round-count axis — the spec/plan roundtable
   and its round-count knob were removed. `required_lenses` is now advisory
   context only (autoplan owns its own role set at Step 4). Legacy round-count
   and roundtable-mode fields (any `*_rounds` count, `tier_label`,
   `suggested_roundtable_mode`, `discussion_rounds`, `discussion_required`)
   are REJECTED — re-dispatch with an explicit "remove these fields"
   instruction once, then `BLOCKED_AGENT_TOOL_FAILURE` if still malformed.
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
     `pre_vetted.is_pre_vetted: true`). Codex spec sanity (Step 2) MAY be
     skipped for pre_vetted inputs; plan-writer (Step 3) is also skipped (the
     plan is the input); plan review via autoplan (Step 4) **still runs** as the
     safety-net pass before plan-integrity.
5. `input_shape` ∈ {`source_spec`, `hybrid`} → continue to Step 2. v2 frontmatter
   on the input is NOT required at this stage; plan-writer (Step 3) will
   generate a v2-formatted execution plan, and Step 3's validation will enforce
   the v2 schema on plan-writer's output.

---

## Step 2 — Codex Spec Sanity Audit (merged)

A single automated `codex exec` audit of the spec artifact, before plan-writer.
This is the merged successor of the old Step 2 (spec roundtable) + Step 3 (codex
spec sanity): there is **no multi-role roundtable at the spec stage** anymore —
one Codex pass is the spec-stage cross-model check.

**Skip rule.** `pre_vetted` inputs (classifier marked
`pre_vetted.is_pre_vetted == true`) MAY skip Step 2. When skipped, persist
`state.spec_sanity_skipped_reason = classification.pre_vetted.reason` and go
straight to Step 3 (or Step 4 for plan-shape inputs that also skip Step 3).
All other inputs run Step 2.

1. Build a prompt file embedding `prompts/spec-codex-sanity.md` + the current spec text
   (the raw input) + source-spec text (if any) + classification JSON.
2. Dispatch via wrapper:
   ```bash
   bash lib/codex-wrapper.sh <prompt-file> spec-sanity \
     "" \
     .longtask/state/{spec_basename}/spec-codex-sanity.json
   ```
   (No `--output-schema` reference unless a schema is later defined; the prompt's
   JSON contract is the gate.)
3. Read the JSON output. Required fields: `verdict` ∈ {CLEAN, NEEDS_REVISION}, four
   finding arrays (omissions / hallucinations / internal_contradictions /
   reward_hacking_bait), `confidence`, `recommended_action`.
4. Reconcile (prefer auto-loop over ASK_HUMAN; ASK_HUMAN is the last resort):
   - `verdict == CLEAN` → proceed straight to plan-writer (Step 3) with the
     sanity report attached.
   - `verdict == NEEDS_REVISION` → run **exactly one spec-revision pass**: the
     orchestrator applies Codex's findings as `known_concerns[]` that plan-writer
     (Step 3) MUST address via a repair phase, an added DoD bullet on an existing
     phase, or an explicit out-of-scope row with rationale (Step 5
     plan-integrity-review enforces this — `BLOCKED_SPEC_REWRITE` if missing).
     For plan-shape inputs that skip plan-writer, inject `known_concerns[]`
     directly onto the submitted plan; autoplan (Step 4) then reviews the
     concern-annotated plan. After this single revision pass, continue — do NOT
     loop Step 2.
   - **High-risk exception.** When `verdict == NEEDS_REVISION` AND
     `recommended_action == ask_human`, OR `hallucinations[]` is non-empty and
     any hallucination touches a categorical high-risk category (security
     boundary / data-loss / irreversible migration / external API contract /
     regulatory / production credentials), **run the Uncertainty Clarification
     Round** (see section below) before escalating. PROCEED → inject
     `known_concerns[]` plus the clarification's `residual_concerns[]`.
     ESCALATE → `ASK_HUMAN` with both perspectives attached.
5. Persist `spec_codex_sanity_path` + `spec_codex_sanity_verdict` to state.

**Why this is the only spec-stage check:** the old Claude-heavy multi-perspective
roundtable was over-engineered for ordinary specs. A single Codex audit with a
different training prior catches the omissions / hallucinations / contradictions
a same-distribution reviewer chain would miss; the heavy multi-role scrutiny now
lives at the plan stage (Step 4, autoplan), where the concrete execution contract
makes the criticism cheaper and sharper.

---

## Step 3 — Plan Writer

1. Dispatch Claude Agent (opus) with `prompts/plan-writer.md`.
   - Plan-writer invokes `superpowers:writing-plans` skill internally.
   - **Multi-agent mode**: when the plan will have ≥3 phases (estimate from the
     source spec's section count, or from sanity-audit-suggested phase count),
     plan-writer dispatches one Claude Agent **per phase** in parallel, then
     merges. Single-phase or 2-phase plans stay single-agent. See
     `prompts/plan-writer.md` for the multi-agent dispatch contract.
   - If Step 2 produced `known_concerns[]`, pass them in the prompt as required
     inputs (see Step 2 reconciliation rule).
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
6. If Step 2 surfaced `known_concerns[]`, require those concerns to appear in
   plan as either: (a) dedicated repair phase, (b) added dod bullets on
   relevant existing phases, or (c) explicit out-of-scope row with rationale.
   Missing → `BLOCKED_SPEC_REWRITE`.

---

## Step 4 — Plan Review via `autoplan` (ALWAYS RUN)

Step 4 hands the plan from Step 3 (or, for plan-shape inputs, the input plan
itself) to the gstack `autoplan` skill for multi-role review. autoplan runs the
CEO / design / eng / DevEx roles — **each as both a Claude subagent AND a Codex
cross-voice** — auto-decides most points via its 6 principles, and surfaces only
taste decisions / codex disagreements to the user at a final approval gate. It
degrades gracefully to Claude-only when Codex is unavailable. The longtask
orchestrator no longer maintains plan-stage lens prompts or codex mid-summaries
— autoplan owns all of that.

**Always run.** Plan review is non-skippable regardless of input shape (even
`pre_vetted`), because the plan is the concrete execution contract and
late-stage criticism is the cheapest defense against bad phase decomposition.

**Availability is hard-required.** Before invoking, confirm the gstack
`autoplan` skill is installed (the user has gstack globally). If `autoplan` is
not available, **FAIL with a clear message** — do NOT silently skip plan review:

```
BLOCKED_AGENT_TOOL_FAILURE: gstack `autoplan` skill not found. Plan review at
Step 4 requires gstack to be installed. Install gstack, then re-run /longtask.
```

**Invoke from the MAIN session — not a subagent.** autoplan is interactive: it
must reach the user for its final approval gate, so it cannot run inside an
isolated Agent-tool subagent. Invoke it via the Skill tool from this
orchestrator session, passing the plan file path from Step 3 as its input.

1. Invoke the `autoplan` Skill with the plan file
   `.longtask/plans/{spec_basename}-implementation-plan.md` as its target plan.
   autoplan's preamble (gstack update check, session bookkeeping) runs on
   invocation — this is expected, non-fatal noise.
2. autoplan reviews the plan, auto-decides intermediate points, surfaces taste
   decisions / User Challenges to the user at its approval gate, and **writes
   its verdict into the plan file** as a `## GSTACK REVIEW REPORT` section per
   its own contract (plus a Decision Audit Trail).
3. After autoplan returns, **read the plan file back**. Recompute the plan
   sha256 (autoplan edits the plan in place) and persist as
   `state.implementation_plan_post_review_sha256`. The pre-review sha256 stays
   in `state.implementation_plan_sha256` for diff audit.
4. Record a pointer to the review report:
   `state.autoplan_review_report_path = "<plan_path>#gstack-review-report"`
   (the report lives inside the plan file as the `## GSTACK REVIEW REPORT`
   section — store the plan path plus the section anchor). Also persist
   `state.autoplan_review_status` from autoplan's completion status
   (`DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`).
5. If autoplan returns `BLOCKED` or `NEEDS_CONTEXT`, stop and surface its
   reason to the user; do not proceed to Step 5 on an unreviewed plan.

Step 4 output gates Step 5: plan-integrity review reads
`implementation_plan_post_review_sha256` (or the same as
`implementation_plan_sha256` if autoplan made no edits).

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

- **Step 2** — `verdict == NEEDS_REVISION` + `recommended_action == ask_human`
- **Step 2** — `verdict == NEEDS_REVISION` + `hallucinations[]` non-empty + any
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
  or the codex sanity verdict (for Step 2)
- `{secondary_verdict_json}` — Codex secondary verdict, or `{}` for Step 2
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
      "trigger": "step-2-codex-sanity-needs-revision-high-risk-hallucination",
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
   - Source/input spec requirement → plan phase/DoD/test alignment matrix
   - Plan → spec alignment and explicit out-of-scope items
   - Screenshot path → visible content → source requirement validated
   - Command names, exit codes, compact evidence excerpts
5. Missing screenshots → `BLOCKED_E2E2_SCREENSHOT`; do not proceed.

---

## Step 8 — Final Alignment Review (MANDATORY DUAL)

This step is **always** dual (Claude opus primary + Codex GPT-5.5 xhigh
secondary, independent dispatches) regardless of the Step 4 autoplan outcome.
Note: autoplan already runs a Claude+Codex review at the plan stage, but
final-alignment-review is a separate last-line-of-defense gate that runs only
once at end-of-pipeline. It is intentionally redundant with Step 5
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
| `BLOCKED_SPEC_REWRITE` | Plan integrity review FAIL; alignment matrix incomplete; plan-writer produced contradictory plan |
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
  "preflight_skip_path": null,
  "classification_path": "...",
  "spec_sanity_skipped_reason": null,
  "spec_codex_sanity_path": null,
  "spec_codex_sanity_verdict": null,
  "implementation_plan_path": "...",
  "implementation_plan_sha256": "...",
  "implementation_plan_post_review_sha256": null,
  "autoplan_review_report_path": null,
  "autoplan_review_status": null,
  "plan_integrity_review_path": "...",
  "model_degraded": false,
  "model_requests": [
    {
      "role": "verifier",
      "requested": "gpt-5.5/xhigh",
      "actual": "gpt-5.4/high",
      "reason": "gpt-5.5 unavailable",
      "model_degraded": true
    },
    {
      "role": "worker",
      "requested": "claude-sonnet-4-6",
      "actual": "claude-sonnet-4-6",
      "reason": "tier=sonnet",
      "model_degraded": false
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
| Codex spec sanity (Step 2) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Plan writer | Claude opus via Agent tool | — | — |
| Plan review (Step 4) | gstack `autoplan` skill (main session; internal CEO/eng/design/DevEx roles + codex cross-voice, Claude-only graceful degradation) | — | — |
| Plan integrity review (primary) | Claude opus via Agent tool | — | — |
| Plan integrity review (secondary) | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
| Phase worker | **Claude** via `Agent` tool — `claude-haiku-4-5` / `claude-sonnet-4-6` / `claude-opus-4-8`, resolved from `phase.model_tier > spec.default_model_tier > 'sonnet'` | — | escalate `model_tier` one step (sonnet→opus, haiku→sonnet) on retry, log as `model_degraded=true` |
| Phase verifier | Codex GPT-5.5 via codex exec | xhigh | gpt-5.4 high |
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
   (and `implementation_plan_post_review_sha256` if set) still match.
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
- Input classification, codex spec sanity, or plan-integrity omission or contradiction
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
