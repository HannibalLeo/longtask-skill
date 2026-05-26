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

## Owner four-step (subset)

| Step | Owner | Scope (subset of /longtask) |
|---|---|---|
| **(a) Architecture** | Claude opus (main session + Agent tool) | Spec classification, plan writing, plan-integrity review. |
| **(b) Discussion** | Claude + Codex hybrid | Spec-roundtable (Step 2, may be skipped at 0+1 tier) + plan-roundtable (Step 4b, always runs). Consensus editors: Claude primary + Codex secondary. |
| (c) Work | — | Not in scope; deferred to `/longtaskCode`. |
| (d) Final verification | — | Not in scope; deferred to `/longtaskCode`. |

## Pipeline (mirrors /longtask Steps 0-5)

```
Step 0  Preflight          Validate spec frontmatter + state schema (per /longtask SKILL.md)
Step 1  Classifier         Claude Agent → JSON {input_shape, tier_label, spec_rounds,
                           plan_rounds, required_lenses, risk_reasons,
                           suggested_roundtable_mode, pre_vetted}
                           Tier ∈ {0+1, 1+1, 2+1, 3+2}
Step 2  Spec-roundtable    spec_rounds × N lens hybrid discussion + spec-round-state
                           editor + spec-consensus-editor → enhanced-spec
                           **Skipped only at the 0+1 tier**
Step 3  Codex spec sanity  (UNCONDITIONAL) codex exec --output-schema single pass
                           → {verdict: CLEAN | NEEDS_REVISION}
Step 4  Plan-writer        Claude Agent invokes superpowers:writing-plans → plan.md
                           (multi-agent dispatch when plan has ≥3 phases)
Step 4b Plan-roundtable    plan_rounds × N lens hybrid discussion on the plan +
                           plan-round-state editor + plan-consensus-editor (in-place
                           rewrites plan.md)
                           **ALWAYS RUN, plan_rounds ≥ 1**
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
| Step 2 lenses | `spec-roundtable.md` | Hybrid (per lens routing matrix) |
| Step 2 round state | `spec-round-state.md` | Claude Agent |
| Step 2 consensus | `spec-consensus-editor.md` | Claude primary + Codex secondary |
| Step 3 | `spec-codex-sanity.md` | `codex exec` |
| Step 4 | `plan-writer.md` | Claude Agent (multi-agent ≥3 phases) |
| Step 4b lenses | `plan-roundtable.md` | Hybrid (per lens routing matrix) |
| Step 4b round state | `plan-round-state.md` | Claude Agent |
| Step 4b consensus | `plan-consensus-editor.md` | Claude primary + Codex secondary |
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
| Identity | `mode: "claude-hybrid-plan-only"`, `spec_path`, `spec_sha256`, `input_path`, `input_sha256`, `input_shape` |
| Spec stage | `classification_path`, `spec_roundtable_skipped_reason` (0+1 only), `enhanced_spec_path`, `enhanced_spec_sha256`, `spec_update_path`, `spec_round_state_paths[]` |
| Plan stage | `implementation_plan_path`, `implementation_plan_sha256`, `plan_round_state_paths[]`, `implementation_plan_post_roundtable_sha256`, `plan_integrity_review_path` |
| Per-phase | (untouched — phases stay at status `pending`, populated by /longtaskCode) |
| Model accounting | `model_requests[]`, `agents[]`, `claude_subagents[]`, `codex_subagents[]`, `hybrid_lens_assignments` |
| Handoff | `plan_only_terminal: true`, `plan_only_terminated_at: <ISO 8601>`, `next_skill_hint: "longtaskCode"` |

When `/longtaskCode` resumes, it reads this state, asserts
`implementation_plan_post_roundtable_sha256` matches the current plan file, and
starts at Step 6. Drift → `BLOCKED_SPEC`.

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
  "version": "0.2.0",
  "plan_path": "<implementation_plan_path>",
  "plan_post_roundtable_sha256": "<sha256>",
  "enhanced_spec_path": "<enhanced_spec_path or null if 0+1 tier>",
  "alignment_matrix_path": "<alignment matrix path>",
  "plan_integrity_review_path": "<path to PASS verdict JSON>",
  "tier_label": "<from classification>",
  "roundtable_mode_resolved": "<hybrid|dual>",
  "state_path": "<path to the .longtask/state/{spec}.json>",
  "next_step_hint": "Run /longtask:longtaskCode {plan_path} to execute Steps 6-9."
}
```

The orchestrator then prints a one-line summary for the user:

```
✅ Plan validated. {tier_label} · {plan_rounds} plan rounds · plan-integrity PASS.
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
plus per-phase block on a `plan_with_source` shape), the classifier picks the
0+1 tier and Step 2 is skipped — but plan-roundtable (Step 4b) still runs.

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
