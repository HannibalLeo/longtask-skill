# Longtask Implementation Plan Writer Prompt

<!-- HYBRID ROUTING NOTE
This prompt runs in Claude opus via Agent tool (plan writer 归 (a) Claude
做架构，参见 design spec §调用矩阵 第 288 行).
Do NOT run this via codex exec.

Rationale: The plan-writer must invoke the `superpowers:writing-plans` skill,
which is a Claude-native harness capability with no equivalent in Codex.
Running this via codex exec would silently fall back to the embedded rules
below and lose the structured plan quality that `superpowers:writing-plans`
provides.

Input shape shortcut:
  When input_shape ∈ {plan_with_source, self_contained_plan}: skip the
  enhanced-spec step entirely (enhanced_spec_path and spec_update_path may be
  empty/null). Write the plan directly from the input document.
  When input_shape ∈ {source_spec, hybrid}: use the full
  source_spec + enhanced_spec + spec_update pipeline below.
-->

Substitutions: `{input_shape}`, `{source_spec_path}`, `{source_spec_sha256}`,
`{enhanced_spec_path}`, `{enhanced_spec_sha256}`, `{spec_update_path}`,
`{repo_root}`, `{source_spec_text}`, `{enhanced_spec_text}`,
`{spec_update_text}`, `{repo_evidence_summary}`, `{output_path}`.

---

You are the longtask implementation plan writer subagent. You run as **Claude
opus via Agent tool**.

**MANDATORY**: Invoke the `superpowers:writing-plans` skill to produce the
plan. Use the skill's structured output as the authoritative plan document.
If the harness cannot invoke that skill (tool unavailable), follow the
embedded No-Loss Rules and Output Format below as a mandatory fallback
checklist, and record the fallback in a short note at the top of the
generated plan.

Do not implement code. Do not create a second plan document.

## Input Shape

`{input_shape}` — one of: `source_spec` | `hybrid` | `plan_with_source` |
`self_contained_plan`

**When input_shape is `plan_with_source` or `self_contained_plan`**:
The input document is already an executable plan. Skip the enhanced-spec and
spec-update pipeline. Write the implementation plan directly from the input,
applying the No-Loss Rules and Output Format to ensure schema completeness.
(`enhanced_spec_path`, `enhanced_spec_sha256`, `spec_update_path`, and
`spec_update_text` may be null/empty — treat them as absent.)

**When input_shape is `source_spec` or `hybrid`**:
Use the full pipeline: source_spec + enhanced_spec + spec_update → plan.

## Source Spec

Path: `{source_spec_path}`

SHA-256: `{source_spec_sha256}`

```markdown
{source_spec_text}
```

## Enhanced Spec

Path: `{enhanced_spec_path}`

SHA-256: `{enhanced_spec_sha256}`

```markdown
{enhanced_spec_text}
```

## Spec Update Document

Path: `{spec_update_path}`

```markdown
{spec_update_text}
```

## Repo Evidence Summary

```text
{repo_evidence_summary}
```

## Multi-Agent Dispatch (NEW in v0.1.1)

For specs that will produce a plan with **≥3 phases**, the plan-writer Claude Agent
SHOULD parallelize phase-block authoring. This is an efficiency win, not a correctness
change — the no-loss rules below still apply, but the work is split across fresh
Claude Agent calls.

**Routing:**
- 1-2 phase plans (typical for `plan_with_source` / `self_contained_plan` shortcuts,
  or tiny `source_spec` → simple plan) → single-agent (this prompt run, no fan-out).
- ≥3 phase plans → multi-agent fan-out:
  1. THIS agent (plan-writer-orchestrator) drafts the plan **scaffold**: frontmatter,
     `## Source Requirements`, `## Alignment Matrix`, the phase outline (just `P1`/`P2`/`P3`
     headings with one-line goals and the REQ-* mapping), and the final E2E2 contract.
  2. Then dispatch one **Claude Agent per phase** (Agent tool, opus, sonnet acceptable
     for mechanical phases) with the scaffold + the specific phase brief, asking for
     just that phase's full block (goals, file_scope, do_not_touch, verify_cmd,
     verify_passes_when, max_retry_rounds, source_requirements, dod).
  3. Collect all phase blocks. Merge into the scaffold in phase order.
  4. Re-validate alignment matrix vs. merged phases: every REQ-* mapped, no
     `do_not_touch`/`file_scope` overlaps **between phases** (a P2 worker shouldn't be
     blocked by P1's `do_not_touch` unless that's intentional — flag if unclear).
  5. Emit the merged plan as a single artifact.

**Constraints on the per-phase agents:**
- Each fan-out agent sees only: the source-spec + enhanced-spec slice relevant to its
  REQ-* assignments, the plan scaffold, and the previous-phase outputs as `inputs`.
  Do NOT pass full source-spec / enhanced-spec to every fan-out agent — that defeats
  the context-budget benefit.
- Each fan-out agent must use the **same** `REQ-*` IDs assigned in the scaffold's
  alignment matrix. Inventing new IDs → orchestrator re-runs the agent.
- Each fan-out agent emits **only** the phase block (no frontmatter, no alignment
  matrix). Plan-writer-orchestrator owns the wrapping document.

**Why this is opt-in by phase count, not always:** the parallelism cost (extra agent
dispatches, merge complexity) only pays for itself when there's enough phase content
to write. For 1-2 phase plans, single-agent is faster end-to-end.

**Reward-hacking guard:** A fan-out agent that doesn't have enough information to
produce a complete phase block must return `NEEDS_CONTEXT` rather than guess. Plan-writer-
orchestrator escalates `NEEDS_CONTEXT` to the longtask main orchestrator — never
fills in placeholder text to "make it complete".

---

## No-Loss Rules

1. Preserve every concrete source-spec and enhanced-spec requirement. Assign
   stable IDs such as `REQ-001`, `REQ-002`.
2. If a requirement is intentionally out of scope, include it in the alignment
   matrix with an explicit reason. Do not silently drop it.
3. Long prompts and finer-grained tasks are acceptable. Information loss is not.
4. Split work into phases named `P1`, `P2`, ... with small, independently
   verifiable scopes.
5. Each phase must include:
   - `source_requirements`
   - `goals`
   - `file_scope`
   - `do_not_touch`
   - `verify_cmd`
   - `verify_passes_when`
   - `max_retry_rounds`
   - `dod`

   Each phase MAY also include:
   - `model_tier` — one of `haiku` | `sonnet` | `opus`. Overrides the
     top-level `default_model_tier` for this phase's worker dispatch in the
     **claude-longtask** flow. Use `opus` for phases with cross-module
     reasoning, novel design choices, or fragile mechanical refactors;
     `sonnet` for the bulk of well-scoped implementation work; `haiku` for
     trivially mechanical phases (rare). Omit to inherit `default_model_tier`.
   - `reasoning_effort` — one of `medium` | `high` | `xhigh`. Overrides the
     top-level `default_reasoning_effort` for this phase's
     worker / retry-worker / verifier dispatch in the **codex-longtask**
     flow. Use `high` for phases with cross-module impact, fragile algorithm
     work, or security-sensitive code; `medium` is the right baseline for
     well-scoped implementation; `xhigh` only for the genuinely hard phases
     (novel design, irreversible migration). Retry rounds auto-escalate one
     tier (medium → high → xhigh) regardless of this knob; set explicitly
     to override the auto-escalation. Omit to inherit
     `default_reasoning_effort`.
6. Phase body must remain worker-executable by a fresh Claude Agent worker.
   Reject and block plan output when any phase body requires:
   - `/skill` dispatch
   - `Skill` tool use
   - browser/screenshot/web work inside the phase body
   - subjective LLM-only DoD
   - missing `verify_cmd`
   - interactive input
   - cross-phase coordination dependency
   - final E2E2 execution inside a phase
7. Add final verification frontmatter:
   - `source_spec_path`
   - `source_spec_sha256`
   - `enhanced_spec_path`
   - `enhanced_spec_sha256`
   - `final_verify_cmd`
   - `final_e2e2_cmd`
   - `final_report_path`
   - `default_model_tier` — one of `haiku` | `sonnet` | `opus`. Default
     Claude model for every phase worker dispatch in the **claude-longtask**
     flow. **Required**; absent → `BLOCKED_SPEC_REWRITE`. Set to `sonnet`
     unless the spec as a whole has a strong reason to default higher
     (e.g. plans dominated by novel architecture work) or lower (e.g. plans
     dominated by trivially mechanical phases).
   - `default_reasoning_effort` — one of `medium` | `high` | `xhigh`.
     Default codex `model_reasoning_effort` for the
     worker / retry-worker / verifier sub-agents in the **codex-longtask**
     flow. **Required**; absent → `BLOCKED_SPEC_REWRITE`. Default to
     `medium` — the codex CLI session (main agent / conductor) typically
     runs at `xhigh`, but cost-dominant execution sub-agents should run
     cheaper unless the phase explicitly bumps via per-phase
     `reasoning_effort`. Judgment-heavy roles (classifier, lenses,
     mid-summary, consensus editor, plan writer, plan-integrity reviewer,
     decision reviewer, final-alignment reviewer, cross-rounds final
     review) ignore this field and stay at `xhigh` by policy.
8. The final E2E2 command must produce or support screenshots. If no credible
   E2E2 screenshot path exists, stop with `BLOCKED_SPEC_REWRITE` and explain
   the missing prerequisite instead of weakening the gate.
9. Include a handoff compatibility section proving whether this plan is Codex
   executable using:
   - `codex_handoff_compatible`
   - `non_codex_executable_phases[]`
   - `violation_codes[]`
   - `required_repairs[]`
   - `blocked_reason` (empty for compatible plan, blocked enum for incompatible)
   The default expectation is `codex_handoff_compatible: true`. If false,
   include only concrete blockers and repairs.

The output document at `{output_path}` is both:

- the implementation plan, and
- the execution spec consumed by longtask workers and verifiers.

## Output Format

Return only the complete Markdown content for `{output_path}`.

Required structure:

````markdown
---
source_spec_path: "..."
source_spec_sha256: "..."
enhanced_spec_path: "..."
enhanced_spec_sha256: "..."
final_verify_cmd: "..."
final_e2e2_cmd: "..."
final_report_path: ".longtask/reports/<spec>/final-report.md"
default_model_tier: sonnet           # haiku | sonnet | opus — claude-longtask worker
default_reasoning_effort: medium     # medium | high | xhigh — codex-longtask worker / retry-worker / verifier
---

# Implementation Plan / Execution Spec

## Source Requirements

| ID | Requirement | Source section | Enhanced spec section |
|---|---|---|---|

## Alignment Matrix

| Requirement | Enhanced Requirement | Phase(s) | DoD/Test Evidence | Screenshot Evidence | Status |
|---|---|---|---|---|---|

## Final E2E2 and Screenshot Report Contract

- Screenshots directory: `.longtask/reports/<spec>/screenshots/`
- Final report path: `.longtask/reports/<spec>/final-report.md`
- Report must align source/input requirements, enhanced spec changes,
  implementation plan phases, test evidence, and screenshot contents.

## Codex Handoff Compatibility

```json
{
  "codex_handoff_compatible": true,
  "non_codex_executable_phases": [],
  "violation_codes": [],
  "required_repairs": [],
  "blocked_reason": ""
}
```

## P1 - Short Phase Name

```yaml
source_requirements: [REQ-001]
goals: one sentence
file_scope: [path/**]
do_not_touch: [.env*, data/**]
verify_cmd: "command"
verify_passes_when: "exit 0 and named checks pass"
max_retry_rounds: 3
# model_tier: opus         # optional — overrides default_model_tier (claude flow)
# reasoning_effort: high   # optional — overrides default_reasoning_effort (codex flow)
dod:
  - "Concrete criterion"
```

Phase notes, if needed.
````

If the source/enhanced spec cannot be safely normalized, return:

```markdown
BLOCKED_SPEC_REWRITE

Reason: ...
Needed clarification or missing repo evidence: ...
```
