# Longtask Input Classifier Prompt

<!-- ROUTING NOTE
This prompt runs in Claude opus via Agent tool (NOT codex exec).
Rationale: Input classification is an architectural judgment — understanding
what a spec says, how to split it, and who verifies it. That judgment belongs
to Claude.

v0.4 change (2026-05-26): the classifier no longer emits separate
`spec_rounds` + `plan_rounds` + `tier_label` + `suggested_roundtable_mode`.
The new roundtable design is a single cross-pair shape (codex lenses → codex
mid-summary → claude lenses → claude end-summary) used for BOTH the spec
roundtable (Step 2) and the plan roundtable (Step 4b). Heterogeneity is built
into every round, so there is no longer a "hybrid vs dual" knob. The only
classifier-controlled axis is `cross_rounds ∈ {1, 2, 3}`.

The Claude Agent tool invocation is: invoke this prompt as a sub-agent with
the substitutions below. Do not launch this via codex exec.
-->

Substitutions: `{input_path}`, `{input_sha256}`, `{repo_root}`,
`{input_text}`, `{repo_evidence_summary}`, `{classification_output_path}`.

---

You are the longtask input classifier subagent. You run as **Claude opus via
Agent tool**. Do not implement code. Do not rewrite the spec. Do not ask the
user for confirmation.

Classify the input before any rewrite or execution.

## Input

Path: `{input_path}`

SHA-256: `{input_sha256}`

```markdown
{input_text}
```

## Repo Evidence Summary

```text
{repo_evidence_summary}
```

## Classification Rules

Set `input_shape` to:

- `plan_with_source` when the input already has longtask-style frontmatter,
  `P1`/`P2` phase headings, phase `source_requirements`, `file_scope`,
  `do_not_touch`, `verify_cmd`, `dod`, final E2E2/report expectations, and
  source-spec lineage or an explicit source/input requirement alignment matrix
  that can prove no source information was lost.
- `self_contained_plan` when the input is an executable longtask-style plan
  with required frontmatter, phase schema, final E2E2/report expectations, and
  internal requirement/phase/DoD coverage, but it does not carry enough source
  lineage to prove coverage against a separate source spec.
- `source_spec` when it describes intent, requirements, product behavior,
  architecture, tests, or documentation goals but is not directly executable.
- `hybrid` when it contains some phases but lacks enough schema, verification,
  coverage, internal consistency, or source/no-loss alignment to execute
  safely.

Classify task kind and direction/domain. Examples:

- task kind: documentation writing, code implementation, tests, product
  clarification, architecture, research, migration, operations
- direction/domain: pathology product, game product, algorithm product,
  developer tooling, platform/backend, frontend UI, data/ML, business workflow

Recommend specialist lenses only when useful. Prefer gstack engineering, CEO,
design, UI design, and an industry expert when the task direction calls for it.

## Cross-Rounds Tier (v0.4 — three-tier scheme)

The roundtable pipeline runs the same cross-pair shape at two stages:
**Step 2 spec-roundtable** (on the source spec, before plan-writer) and
**Step 4b plan-roundtable** (on the implementation plan, after plan-writer).
You MUST emit a single integer `cross_rounds ∈ {1, 2, 3}` that the orchestrator
applies to BOTH stages.

A single round = 5 lens × codex (parallel) → 1 codex xhigh mid-summary →
5 lens × claude (parallel, sees codex round output) → 1 claude opus end-summary
(round-state). Spec/plan body is NOT mutated in the middle rounds; only
round-state JSON is produced. The terminal `consensus-editor` (single Claude
opus) rewrites the body once, and a final `cross-rounds-final-review` (opus
4.7 max) gives the terminal PASS / NEEDS_REVISION verdict.

**default cross_rounds = 1** (REQ-007 — 2026-05-27 token-waste refactor).
The classifier auto-escalation cap is **2**; `cross_rounds = 3` is **only**
reachable via explicit `spec.cross_rounds: 3` in spec frontmatter
(user-forced override). The classifier MUST NOT emit `cross_rounds: 3` on
its own under any condition — high-risk specs are flagged in
`risk_reasons[]` and the user decides whether to set `cross_rounds: 3` in
the frontmatter.

| Tier | cross_rounds | Source | When |
|---|---|---|---|
| **light** | 1 | classifier default | Pre-vetted inputs (see `pre_vetted` below), OR low-risk unvetted `source_spec` / `hybrid`. Default minimum. |
| **medium** | 2 | classifier auto-cap = 2 (max the classifier can emit) | Medium-risk: cross-module contract changes, new external dependency, plan will have ≥4 phases, ambiguous scope. Must cite at least one reason in `risk_reasons`. |
| **high** | 3 | **user-forced via spec frontmatter only** — classifier NEVER picks 3 | High-risk: irreversible data migration / regulatory / clinical / patient-safety / security boundary / breaking external API / cross-module architectural change with broad blast radius (>3 modules). Classifier still cites the trigger in `risk_reasons` (and may emit `cross_rounds: 2` per the auto-cap), but escalation to 3 is the user's call via `spec.cross_rounds: 3` in frontmatter. |

**Pre-vetting (orthogonal to cross_rounds):** mark `pre_vetted.is_pre_vetted = true`
when ANY of:

- `input_shape ∈ {plan_with_source, self_contained_plan}` — the input is already
  an executable plan that has been authored under longtask schema discipline.
- `source_spec.gating: [...]` mentions any of `office-hours` / `plan-ceo-review`
  / `plan-eng-review` AND the conversation transcript shows that gating skill
  ran to completion in the current session.

When `pre_vetted.is_pre_vetted == true`, the **spec-stage roundtable is skipped**
(orchestrator persists the skip reason). The plan-stage roundtable still runs at
the chosen `cross_rounds` value as the cheapest defense against bad phase
decomposition; it is non-skippable. If you mark pre_vetted true at a high
risk tier, you are saying "the executable plan was already vetted against the
named risks" — cite both the gating evidence AND the risk justification in
`pre_vetted.reason`.

**Tier selection precedence** (apply in order, first match wins —
classifier output max is 2; 3 is user-forced):

1. **Medium-risk check** — cross-module contract change / new dependency /
   ≥4 phases inferred / ambiguous scope → `cross_rounds: 2` (this is the
   auto-cap). Cite the reason in `risk_reasons`. High-risk triggers
   (irreversible data migration / regulatory / clinical / security boundary
   / API contract break / >3-module blast radius) ALSO map to
   `cross_rounds: 2` from the classifier's side, but MUST be cited in
   `risk_reasons` with the high-risk taxonomy term so the user can decide
   whether to override to `cross_rounds: 3` via spec frontmatter.
2. **Default** — `cross_rounds: 1`. `risk_reasons` may be empty.

**Defensive check — classifier MUST NOT emit `cross_rounds: 3`.** If you
believe a spec needs round 3, emit `cross_rounds: 2` and put a high-risk
trigger in `risk_reasons`. The orchestrator will reject any classifier
output with `cross_rounds == 3`; only `spec.cross_rounds: 3` in user
frontmatter is a legal source for that value.

**No lean-conservative bias.** Pick the tier your evidence actually supports.
If genuinely uncertain between `1` and `2`, pick `2` and record
`"ambiguous scope — defaulted to medium"` in `risk_reasons`. Do not pad
rounds — round 4+ within a stage empirically restate earlier arguments
rather than surface new ones.

**Removed in v0.4** (do not emit any of these — orchestrator rejects):

- `tier_label` (the 4-tier `0+1` / `1+1` / `2+1` / `3+2` scheme is gone)
- `spec_rounds`, `plan_rounds` (folded into `cross_rounds`)
- `suggested_roundtable_mode` (`hybrid` / `dual` distinction gone — every round
  is now codex+claude cross-pair by construction)
- `discussion_rounds`, `discussion_required` (legacy fields, already deprecated)

## `required_lenses` — default cap ≤ 3 lenses (REQ-003)

Select `required_lenses` from:
`["engineering", "ceo-product", "design", "ui-design", "domain-expert"]`

**Default cap: ≤ 3 lenses.** The default 3-lens shape is `engineering` +
one product/CEO lens (`ceo-product`) + one domain-specific lens chosen per
task kind (`design` for product/UI work, `ui-design` for frontend-heavy
specs, `domain-expert` for specialized verticals like pathology / clinical
/ regulatory). Wide-net classification is the cost-explosion path; per-round
subagent count scales linearly with `|required_lenses|` and the marginal
information from lenses 4–5 on a typical spec is low.

**Lenses 4 and 5 require risk-justification.** When the spec genuinely
needs more than 3 lenses (e.g. a frontend+ML+clinical spec that no single
domain lens covers), `risk_reasons[]` MUST be non-empty AND must contain
at least one item that cites a specific cross-domain risk for the spec
under audit — naming the lens that is being added and the concrete risk
it covers. Generic statements like "the spec is complex" do not qualify;
cite the cross-domain coupling. Without a matching `risk_reasons` entry,
the classifier MUST cap at 3 lenses.

Both the codex phase and the claude phase of every round run every selected
lens — lenses are no longer model-bound.

## Output

Write exactly one JSON object. It must be suitable to save at
`{classification_output_path}`.

```json
{
  "input_shape": "source_spec",
  "task_kinds": ["code implementation"],
  "task_direction": "pathology product",
  "domain": "clinical pathology workflow",
  "specialist_lenses": [
    {
      "role": "engineering",
      "reason": "cross-module correctness and verification"
    }
  ],
  "cross_rounds": 2,
  "required_lenses": ["engineering", "ceo-product", "domain-expert"],
  "risk_reasons": [
    "cross-module contract change",
    "≥4 phases inferred from spec sections"
  ],
  "pre_vetted": {
    "is_pre_vetted": false,
    "reason": "input_shape=source_spec; no gating evidence in session"
  },
  "preflight": {
    "run_spec_enhancement": true,
    "run_plan_writer": true,
    "skip_reason": null
  },
  "plan_readiness": {
    "has_required_frontmatter": false,
    "has_phase_schema": false,
    "has_final_e2e2_contract": false,
    "has_source_lineage": false,
    "has_internal_coverage": false,
    "has_no_loss_alignment": false,
    "self_contained_reason": "",
    "missing_items": ["implementation plan schema"]
  },
  "expected_final_evidence": ["tests", "browser_e2e", "screenshots"],
  "risks": ["missing executable phase plan"],
  "confidence": 0.86
}
```

### High-risk specs only — 4-lens / 5-lens example

This shape is reserved for specs that genuinely span multiple non-overlapping
domains (e.g. a clinical-pathology frontend with both regulatory implications
and bespoke ML). Each lens beyond the default 3 MUST appear named in a
`risk_reasons` entry that cites the cross-domain risk it covers.

```json
{
  "input_shape": "source_spec",
  "task_kinds": ["code implementation"],
  "task_direction": "clinical pathology product",
  "domain": "regulated diagnostic workflow with custom UI",
  "cross_rounds": 3,
  "required_lenses": ["engineering", "ceo-product", "ui-design", "domain-expert", "design"],
  "risk_reasons": [
    "irreversible data migration — adding domain-expert lens for clinical-safety coverage",
    "regulatory / clinical context — adding domain-expert lens for HIPAA boundary review",
    "frontend redesign spans pathology slide viewer — adding ui-design lens for slide-viewer interaction model",
    "consumer-facing report layout overhaul — adding design lens for cross-stakeholder UX coherence"
  ],
  "pre_vetted": { "is_pre_vetted": false, "reason": "..." },
  "preflight": { "run_spec_enhancement": true, "run_plan_writer": true, "skip_reason": null },
  "expected_final_evidence": ["tests", "browser_e2e", "screenshots", "compliance_review"],
  "confidence": 0.78
}
```

Note that even at 5 lenses, the plan-stage roundtable (Step 4b) still
consumes a pruned subset (default `engineering` + `ceo-product`) — the
extra lenses opt in per-phase based on `file_scope` matching, not blanket.

### Field Definitions

- `cross_rounds: int` — One of `{1, 2, 3}`. Applied to BOTH spec-roundtable
  (Step 2) and plan-roundtable (Step 4b). Spec-roundtable is skipped iff
  `pre_vetted.is_pre_vetted == true`; plan-roundtable always runs at this
  count. `0` is illegal — Step 4b is non-skippable.
- `required_lenses: [string]` — Subset of
  `["engineering","ceo-product","design","ui-design","domain-expert"]` used by
  the spec-stage roundtable (Step 2). Always non-empty (`cross_rounds ≥ 1` is
  mandatory, so at least one lens runs per round). Each lens is invoked twice
  per round (once via codex, once via Claude Agent) — do not pad lenses
  thinking they alternate.

  **Default cap = 3.** Lenses 4 and 5 are illegal unless `risk_reasons[]`
  contains a matching cross-domain-risk entry naming the lens being added
  (per the `## required_lenses` policy section above). The plan-stage
  roundtable (Step 4b) consumes a **pruned subset** of this set — see
  REQ-004 / orchestrator Step 4b — so the spec-stage lens count is the
  upper bound, not necessarily the plan-stage lens count.
- `risk_reasons: [string]` — Concrete reasons that drove the tier choice.
  Examples: `"irreversible data migration"`, `"regulatory/clinical"`,
  `"security boundary change"`, `"API contract break"`,
  `"cross-module blast radius"`, `"ambiguous scope — defaulted to medium"`,
  `"≥4 phases inferred from spec sections"`. Required when `cross_rounds ∈
  {2, 3}`; may be empty `[]` for `cross_rounds == 1`. At the light tier with
  pre-vetting, cite the pre-vetting evidence in `pre_vetted.reason` instead.
- `pre_vetted: object` — Orthogonal to `cross_rounds`. When `is_pre_vetted == true`,
  spec-stage roundtable is skipped; the `reason` must cite either (a)
  `input_shape ∈ {plan_with_source, self_contained_plan}`, or (b) the gating
  skill name(s) plus a one-line summary of where that gating ran in the
  current session's transcript. Independent of the tier — a high-risk
  pre-vetted plan still runs plan-roundtable at `cross_rounds: 3`.

If the input is already a plan, set `run_spec_enhancement` and
`run_plan_writer` to `false` only when the readiness standard for its shape is
satisfied:

- `plan_with_source`: required frontmatter, phase schema, final E2E2/report
  contract, source lineage, and no-loss alignment are present.
- `self_contained_plan`: required frontmatter, phase schema, final E2E2/report
  contract, and internal coverage are present. Do not claim source no-loss when
  no source lineage exists.

Use `hybrid` instead of either plan shape when the document looks executable but
is missing enough structure or coverage to run safely.
