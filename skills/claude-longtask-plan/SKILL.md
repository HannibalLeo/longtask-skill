---
name: longtaskPlan
description: Spec-to-validated-plan pipeline — runs Steps 0 through 5 of /longtask:longtask (preflight → classify → codex spec sanity → plan-writer → plan review via gstack autoplan → plan-integrity), stops when the implementation plan passes plan-integrity-review. Output is a validated plan file ready to feed into /longtask:longtaskCode (which executes Steps 6-9). Use when you want plan-only iteration without committing to phase execution. Triggers on /longtask:longtaskPlan, "plan only", "spec to plan", "generate plan", "validate plan".
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

- You want an autoplan-reviewed and integrity-checked plan *before* deciding
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

- **Discussion**: codex spec sanity audit (Step 2). The plan-stage Codex
  cross-voice is handled internally by the gstack `autoplan` skill (Step 4),
  not dispatched by this skill directly.
- **Verification**: plan-integrity secondary (Step 5 hybrid gate).

**All authoring stays on Claude**: spec classifier, plan writer,
plan-integrity primary. Steps 6-8 (worker, verifier, decision gate,
final-alignment, ship) are out of scope here and covered by
`claude-longtask-code` under the same boundary.

See `skills/claude-longtask/SKILL.md` § "Codex role boundary" for the full
rule including Step 6-8 categories.

## Owner four-step (subset)

| Step | Owner | Scope (subset of /longtask) |
|---|---|---|
| **(a) Architecture** | Claude opus (main session + Agent tool) | Spec classification, plan writing, plan-integrity review. |
| **(b) Discussion** | Codex sanity + autoplan (v0.5) | Codex spec sanity (Step 2, one automated `codex exec` pass, may be skipped when `pre_vetted`) + plan review via gstack `autoplan` (Step 4, always runs — CEO/eng/design/DevEx roles, each a Claude subagent + Codex cross-voice, with a user approval gate). No longtask-owned roundtable / lens prompts. `required_lenses` is advisory only. |
| (c) Work | — | Not in scope; deferred to `/longtaskCode`. |
| (d) Final verification | — | Not in scope; deferred to `/longtaskCode`. |

## Pipeline (mirrors /longtask Steps 0-5)

```
Step 0  Preflight          Validate spec frontmatter + state schema (per /longtask SKILL.md)
Step 1  Classifier         Claude Agent → JSON {input_shape, required_lenses (advisory),
                           risk_reasons, pre_vetted}
                           pre_vetted gates the spec-stage skip
Step 2  Codex spec sanity  ONE automated codex exec pass: omissions / hallucinations /
                           contradictions / source-spec consistency / reward-hacking bait
                           → {verdict: CLEAN | NEEDS_REVISION}. CLEAN → plan-writer;
                           NEEDS_REVISION → exactly one spec-revision pass, then continue.
                           **Skipped when classifier.pre_vetted.is_pre_vetted == true**
                           (Merged old Step 2 spec-roundtable + Step 3 codex sanity.)
Step 3  Plan-writer        Claude Agent invokes superpowers:writing-plans → plan.md
                           (multi-agent dispatch when plan has ≥3 phases)
Step 4  Plan review        Invoke gstack `autoplan` from the MAIN session on plan.md.
        (autoplan)         CEO/eng/design/DevEx roles, each a Claude subagent + Codex
                           cross-voice; auto-decides via 6 principles; user approval gate;
                           writes `## GSTACK REVIEW REPORT` into plan.md.
                           **ALWAYS RUN. Hard-requires gstack/autoplan installed —
                           BLOCKED_AGENT_TOOL_FAILURE if missing (never silently skipped).**
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
| Step 2 | `spec-codex-sanity.md` | `codex exec` (the one spec-stage check) |
| Step 3 | `plan-writer.md` | Claude Agent (multi-agent ≥3 phases) |
| Step 4 | (gstack `autoplan` skill — no longtask-owned prompt) | Skill tool (main session) |
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
| Identity | `mode: "claude-plan-only"`, `spec_path`, `spec_sha256`, `input_path`, `input_sha256`, `input_shape` |
| Spec stage | `classification_path`, `spec_sanity_skipped_reason` (when pre_vetted only), `spec_codex_sanity_path`, `spec_codex_sanity_verdict` |
| Plan stage | `implementation_plan_path`, `implementation_plan_sha256`, `implementation_plan_post_review_sha256`, `autoplan_review_report_path`, `autoplan_review_status`, `plan_integrity_review_path` |
| Per-phase | (untouched — phases stay at status `pending`, populated by /longtaskCode) |
| Model accounting | `model_requests[]`, `agents[]`, `claude_subagents[]`, `codex_subagents[]`, `hybrid_gate_assignments` |
| Handoff | `plan_only_terminal: true`, `plan_only_terminated_at: <ISO 8601>`, `next_skill_hint: "longtaskCode"` |

When `/longtaskCode` resumes, it reads this state, asserts
`implementation_plan_post_review_sha256` matches the current plan file,
and starts at Step 6. Drift → `BLOCKED_SPEC`.

## BLOCKED enum (subset)

Only these can fire in Steps 0-5:

- `BLOCKED_SPEC` — Step 0/1 frontmatter / sha-drift / pre-vetting evidence gap
- `BLOCKED_SPEC_REWRITE` — Step 2 NEEDS_REVISION (unrecoverable) / Step 3 plan-writer fabrication / Step 5 plan-integrity FAIL
- `BLOCKED_AGENT_TOOL_FAILURE` — Claude Agent dispatch failure (classifier / plan-writer / plan-integrity primary), OR gstack `autoplan` not installed at Step 4
- `BLOCKED_CODEX_WRAPPER_FAILURE` — `codex exec` non-zero exit (Step 2 spec sanity / plan-integrity secondary)
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
  "version": "0.5.0",
  "plan_path": "<implementation_plan_path>",
  "plan_post_review_sha256": "<sha256 of plan after autoplan review>",
  "alignment_matrix_path": "<alignment matrix path>",
  "plan_integrity_review_path": "<path to PASS verdict JSON>",
  "autoplan_review_report_path": "<plan_path>#gstack-review-report",
  "autoplan_review_status": "<DONE | DONE_WITH_CONCERNS>",
  "pre_vetted": "<true | false>",
  "state_path": "<path to the .longtask/state/{spec}.json>",
  "next_step_hint": "Run /longtask:longtaskCode {plan_path} to execute Steps 6-9."
}
```

> **Downstream coupling note (v0.5):** earlier handoffs carried a
> post-roundtable plan sha, an enhanced-spec path, and a round-count field.
> These were removed. The post-review plan sha is now
> `plan_post_review_sha256`; there is no enhanced-spec artifact; and there is
> no round-count field. `/longtaskCode` and the manifest-bridge read
> `plan_post_review_sha256` for drift detection — they must NOT expect the
> removed keys.

The orchestrator then prints a one-line summary for the user:

```
✅ Plan validated. autoplan review {autoplan_review_status} · plan-integrity PASS.
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
`pre_vetted.is_pre_vetted: true` and the Step 2 Codex sanity check is skipped —
but plan review via `autoplan` (Step 4) still runs for every input shape.

**Planning review policy (v0.5):** the spec/plan roundtable and its round-count
knob were removed. The spec stage is one automated Codex sanity pass (Step 2,
skippable for `pre_vetted` inputs); the plan stage delegates to the gstack
`autoplan` skill (Step 4, always run, hard-requires gstack installed). See
`skills/claude-longtask/SKILL.md` § "Planning-stage review semantics" for the
full description.

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
