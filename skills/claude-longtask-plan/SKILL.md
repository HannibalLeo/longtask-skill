---
name: longtaskPlan
description: Spec-to-validated-plan pipeline — runs Steps 0 through 5 of /longtask:longtask (preflight → classify → spec-roundtable → codex spec sanity → plan-writer → plan-roundtable → plan-integrity), stops when the implementation plan passes plan-integrity-review. Output is a validated plan file ready to feed into /longtask:longtaskCode (which executes Steps 6-9). Use when you want plan-only iteration without committing to phase execution. Triggers on /longtask:longtaskPlan, "plan only", "spec to plan", "generate plan", "validate plan".
---

# /longtaskPlan — Steps 0-5 of /longtask

This skill is a **strict subset** of [/longtask:longtask](../longtask/SKILL.md). It runs
the planning half of the pipeline and stops at a validated implementation plan.
All prompts, schemas, and the codex wrapper live in the plugin root
(`../..` from this SKILL.md, i.e. `~/.claude/plugins/cache/longtask-skill/longtask/<version>/`);
this skill re-uses them by plugin-relative path — there is no duplicated artifact.

The execution-half companion is [/longtaskCode](../longtaskCode/SKILL.md).
`longtaskPlan` + `longtaskCode` together equal `longtask`; you can also run
`longtaskCode` independently against a hand-written plan or against a plan from
a previous `longtaskPlan` invocation.

## When to use

Use when ANY of:

- You want a roundtable-reviewed and integrity-checked plan *before* deciding
  whether to execute (e.g., you want to review the plan with a human reviewer,
  or feed it to a different pipeline).
- You ran `/longtaskPlan` once, the plan FAIL-ed plan-integrity-review, and you
  want to iterate on the source spec without burning per-phase cycles.
- You want to split the planning and execution into separate sessions or
  separate machines (planning can finish on a laptop; execution can run on a
  beefier worker).
- The user explicitly asks for "plan only", "spec to plan", or "validate plan".

Skip in favor of full `/longtask` when:

- The spec is small and you'd execute immediately after plan-integrity PASS
  anyway (no review loop in between).
- You want one command to plan + ship.

## Codex role boundary (load-bearing invariant — REQ-008, 2026-05-27 refactor)

In `claude-longtask-plan` (Steps 0-5), codex sub-agents are limited to two
role categories — Discussion and Verification — identical to the parent
`claude-longtask` skill:

- **Discussion**: spec-roundtable codex-phase lens (Step 2 Phase 1),
  plan-roundtable codex-phase lens (Step 4b Phase 1), codex mid-round
  summary (Step 2 Phase 2 / Step 4b Phase 2 — emits digest per REQ-005),
  codex spec sanity audit (Step 3).
- **Verification**: plan-integrity secondary (Step 5 hybrid gate).

**All authoring stays on Claude**: spec classifier, spec / plan consensus
editors, plan writer, spec / plan round-state editors, spec / plan
cross-rounds final review, plan-integrity primary. Steps 6-8 (worker,
verifier, decision gate, final-alignment, ship) are out of scope here and
covered by `claude-longtask-code` under the same boundary.

See `skills/claude-longtask/SKILL.md` § "Codex role boundary" for the full
rule including Step 6-8 categories.

## Owner four-step (subset)

| Step | Owner | Scope (subset of /longtask) |
|---|---|---|
| **(a) Architecture** | Claude opus (main session + Agent tool) | Spec classification, plan writing, plan-integrity review. |
| **(b) Discussion** | Cross-rounds roundtable (v0.4) | Spec-roundtable (Step 2, may be skipped when `pre_vetted`) + plan-roundtable (Step 4b, always runs). Each round = cross-pair (codex × lenses → codex mid-summary → claude × lenses → claude end-summary). Consensus editors: single Claude opus. Terminal gate: cross-rounds-final-review (opus 4.7 xhigh). **Spec stage uses `required_lenses` (default cap ≤ 3 per REQ-003); plan stage uses `plan_required_lenses` — a pruned subset (default `engineering + ceo-product`, other lenses opt in per phase `file_scope` match per REQ-004).** |
| (c) Work | — | Not in scope; deferred to `/longtaskCode`. |
| (d) Final verification | — | Not in scope; deferred to `/longtaskCode`. |

## Pipeline (mirrors /longtask Steps 0-5)

```
Step 0  Preflight          Validate spec frontmatter + state schema (per /longtask SKILL.md)
Step 1  Classifier         Claude Agent → JSON {input_shape, cross_rounds,
                           required_lenses, risk_reasons, pre_vetted}
                           cross_rounds ∈ {1, 2, 3}; pre_vetted gates spec-stage skip
Step 2  Spec-roundtable    cross_rounds × cross-pair rounds (codex lenses → codex
                           mid-summary → claude lenses → claude end-summary) +
                           spec-consensus-editor (single Claude opus) +
                           cross-rounds-final-review (opus 4.7 xhigh) → enhanced-spec
                           **Skipped when classifier.pre_vetted.is_pre_vetted == true**
Step 3  Codex spec sanity  (UNCONDITIONAL) codex exec --output-schema single pass
                           → {verdict: CLEAN | NEEDS_REVISION}
Step 4  Plan-writer        Claude Agent invokes superpowers:writing-plans → plan.md
                           (multi-agent dispatch when plan has ≥3 phases)
Step 4b Plan-roundtable    cross_rounds × cross-pair rounds on the plan +
                           plan-consensus-editor (single Claude opus, in-place rewrite) +
                           cross-rounds-final-review (opus 4.7 xhigh)
                           **ALWAYS RUN, cross_rounds ≥ 1**
Step 5  Plan-integrity     HYBRID gate (Claude primary + Codex secondary) → PASS or
                           BLOCKED_SPEC_REWRITE. Includes textual fidelity check
                           against REQ-* anchors. **Terminal step for /longtaskPlan.**
```

After Step 5 PASS, `/longtaskPlan` writes a handoff manifest (see "Output
manifest" below) and stops. `/longtaskCode` consumes that manifest to run Steps
6 onward.

## Prompts (all in `../../prompts/` relative to this SKILL.md = plugin root's `prompts/`)

| Step | Prompt file | Dispatch |
|---|---|---|
| Orchestration | `claude-orchestrator.md` | Main session reads as its checklist; runs Steps 0-5 only |
| Step 1 | `spec-classifier.md` | Claude Agent |
| Step 2 Phase 1 lens (codex) | `spec-roundtable.md` (phase=codex) | `codex exec` per lens |
| Step 2 Phase 2 mid-summary | `spec-codex-mid-summary.md` | `codex exec` xhigh (NEW v0.4) |
| Step 2 Phase 3 lens (claude) | `spec-roundtable.md` (phase=claude) | Claude Agent per lens |
| Step 2 Phase 4 round-state | `spec-round-state.md` | Claude Agent (end-round summary) |
| Step 2 Phase 5 consensus | `spec-consensus-editor.md` | Single Claude opus (v0.4) |
| Step 2 Phase 6 final review | `cross-rounds-final-review.md` | Claude opus 4.7 xhigh (NEW v0.4) |
| Step 3 | `spec-codex-sanity.md` | `codex exec` |
| Step 4 | `plan-writer.md` | Claude Agent (multi-agent ≥3 phases) |
| Step 4b Phase 1 lens (codex) | `plan-roundtable.md` (phase=codex) | `codex exec` per lens |
| Step 4b Phase 2 mid-summary | `plan-codex-mid-summary.md` | `codex exec` xhigh (NEW v0.4) |
| Step 4b Phase 3 lens (claude) | `plan-roundtable.md` (phase=claude) | Claude Agent per lens |
| Step 4b Phase 4 round-state | `plan-round-state.md` | Claude Agent (end-round summary) |
| Step 4b Phase 5 consensus | `plan-consensus-editor.md` | Single Claude opus (v0.4) |
| Step 4b Phase 6 final review | `cross-rounds-final-review.md` | Claude opus 4.7 xhigh (NEW v0.4) |
| Step 5 | `plan-integrity-review.md` | Hybrid (Claude primary + Codex secondary) |
| Cross-cutting | `codex-clarification.md` | One-shot tie-breaker before any uncertainty-driven ASK_HUMAN |
| Cross-cutting | `known-traps-appendix.md` | Worker/verifier context (used in Step 6+, not here) |

Schemas reused from `../../schemas/` (plugin root's `schemas/`):
- `plan-integrity-review.schema.json` (Step 5)
- `codex-clarification.schema.json` (cross-cutting)

Wrapper: `../../lib/codex-wrapper.sh`.

## State file (subset of /longtask state)

State lives at `.longtask/state/{spec_basename}.json` — same path as full
`/longtask` so a later `/longtaskCode` invocation can resume seamlessly. The
fields written by `/longtaskPlan` (a strict subset; see
`../../schemas/state-example.json` for the full reference):

| Field group | Keys written by /longtaskPlan |
|---|---|
| Identity | `mode: "claude-cross-rounds-plan-only"`, `spec_path`, `spec_sha256`, `input_path`, `input_sha256`, `input_shape` |
| Spec stage | `classification_path`, `spec_roundtable_skipped_reason` (when pre_vetted only), `spec_cross_round_codex_mid_summary_paths[]`, `spec_cross_round_state_paths[]`, `spec_consensus_editor_path`, `enhanced_spec_path`, `enhanced_spec_sha256`, `spec_update_path`, `spec_cross_rounds_final_review_path`, `spec_cross_rounds_final_review_verdict`, `spec_cross_rounds_residual_risks[]` |
| Plan stage | `implementation_plan_path`, `implementation_plan_sha256`, `plan_cross_round_codex_mid_summary_paths[]`, `plan_cross_round_state_paths[]`, `plan_consensus_editor_path`, `implementation_plan_post_cross_rounds_sha256`, `plan_cross_rounds_final_review_path`, `plan_cross_rounds_final_review_verdict`, `plan_cross_rounds_residual_risks[]`, `plan_integrity_review_path` |
| Per-phase | (untouched — phases stay at status `pending`, populated by /longtaskCode) |
| Model accounting | `model_requests[]`, `agents[]`, `claude_subagents[]`, `codex_subagents[]`, `hybrid_gate_assignments` |
| Handoff | `plan_only_terminal: true`, `plan_only_terminated_at: <ISO 8601>`, `next_skill_hint: "longtaskCode"` |

When `/longtaskCode` resumes, it reads this state, asserts
`implementation_plan_post_cross_rounds_sha256` matches the current plan file,
and starts at Step 6. Drift → `BLOCKED_SPEC`.

## BLOCKED enum (subset)

Only these can fire in Steps 0-5:

- `BLOCKED_SPEC` — Step 0/1 frontmatter / sha-drift / pre-vetting evidence gap
- `BLOCKED_SPEC_REWRITE` — Step 3 NEEDS_REVISION (unrecoverable) / Step 4 plan-writer fabrication / Step 4b consensus-editor refusal / Step 5 plan-integrity FAIL
- `BLOCKED_AGENT_TOOL_FAILURE` — Claude Agent dispatch failure (classifier / lens / round-state / consensus / plan-writer / plan-integrity primary)
- `BLOCKED_CODEX_WRAPPER_FAILURE` — `codex exec` non-zero exit (sanity / Codex-side lenses / plan-integrity secondary)
- `BLOCKED_HARNESS_BACKGROUND` — sub-agent idle timeout
- `BLOCKED_CONTEXT_BUDGET` — orchestrator approaching 1M context

Phase-execution BLOCKEDs (`BLOCKED_SCOPE`, `BLOCKED_E2E2_SCREENSHOT`,
`VERIFIER_SCHEMA_INVALID`, `BLOCKED_MODEL_UNAVAILABLE`) cannot fire in
`/longtaskPlan` — they belong to `/longtaskCode`.

## Output manifest (handoff to /longtaskCode)

On Step 5 PASS, write:

```text
.longtask/state/{spec_basename}/plan-only-handoff.json
```

```json
{
  "from_skill": "longtask:longtaskPlan",
  "version": "0.4.0",
  "plan_path": "<implementation_plan_path>",
  "plan_post_cross_rounds_sha256": "<sha256>",
  "enhanced_spec_path": "<enhanced_spec_path or null if pre_vetted spec skip>",
  "alignment_matrix_path": "<alignment matrix path>",
  "plan_integrity_review_path": "<path to PASS verdict JSON>",
  "cross_rounds": "<1 | 2 | 3 from classification>",
  "pre_vetted": "<true | false>",
  "state_path": "<path to the .longtask/state/{spec}.json>",
  "next_step_hint": "Run /longtask:longtaskCode {plan_path} to execute Steps 6-9."
}
```

The orchestrator then prints a one-line summary for the user:

```
✅ Plan validated. cross_rounds={cross_rounds} · plan-integrity PASS.
   Next: /longtask:longtaskCode {plan_path}
```

## Invocation

```bash
/longtask:longtaskPlan docs/superpowers/specs/2026-05-26-foo-design.md

# Resume after interruption (re-runs Steps 0-5 from the first non-PASS step):
/longtask:longtaskPlan docs/superpowers/specs/2026-05-26-foo-design.md --resume
```

If the source spec already carries v2 frontmatter (`source_spec_path`,
`source_spec_sha256`, `final_verify_cmd`, `final_e2e2_cmd`, `final_report_path`,
plus per-phase block on a `plan_with_source` shape), the classifier marks
`pre_vetted.is_pre_vetted: true` and Step 2 is skipped — but plan-roundtable
(Step 4b) still runs at `cross_rounds` (default 1 for plan-shape inputs).

**cross_rounds policy (REQ-007 — 2026-05-27 token-waste refactor):**
default = 1; classifier auto-cap = 2 (medium-risk taxonomy); `cross_rounds: 3`
is **user-forced via `spec.cross_rounds: 3` in spec frontmatter only** —
the classifier never picks 3. The orchestrator rejects classifier JSON
with `cross_rounds == 3` (defensive check). See
`skills/claude-longtask/SKILL.md` § "Length policy" for the full tier
table.

## Relationship to /longtask:manifest-bridge

`claude-longtask-plan` writes a **flat** `plan-only-handoff.json` that the
claude-end `claude-longtask-code` consumes directly. If you need to run the
plan through `codex-longtask-code` (codex CLI Step 6 entry) or any other
consumer that requires the schema-conformant
`shared/schemas/handoff-manifest.schema.json`, run:

```bash
/longtask:manifest-bridge .longtask/state/{spec_basename}/plan-only-handoff.json
```

after this skill completes. The bridge scans every phase for the 11
codex-compatibility violations (SSH, network egress, browser, Skill dispatch,
etc.) and writes a `handoff-manifest.json` with an honest `routing_decision`
and `recommended_executor`. See
`skills/claude-longtask-manifest-bridge/SKILL.md` for details.

## Relationship to /longtask:longtask

`/longtask:longtask <spec>` is equivalent to `/longtask:longtaskPlan <spec>`
followed **automatically** by `/longtask:longtaskCode <plan_path>` in the same
session, with no user-visible handoff. If you want the handoff (review the
plan, hand it to another reviewer, switch sessions), use the two skills
separately.

## Quality bar

Same as `/longtask:longtask` — see [SKILL.md](../longtask/SKILL.md) "Quality bar" and
the 4 production-grade principles in the plugin root's
[README.md](../../README.md).
