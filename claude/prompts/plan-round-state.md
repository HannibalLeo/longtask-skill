# Longtask Plan Round-State (Claude End-Round Summary) Prompt

<!-- Claude opus Agent. Phase 4 of plan-roundtable (after codex lenses → mid-summary → claude lenses). Produces durable plan-round-state; plan body NOT mutated. -->

Substitutions: `{plan_path}`, `{plan_sha256}`, `{enhanced_spec_path}`,
`{alignment_matrix_path}`, `{round_number}`, `{classification_json}`,
`{implementation_plan_text}`, `{previous_round_state}`, `{codex_phase_outputs}`,
`{codex_mid_summary}`, `{claude_phase_outputs}`, `{repo_evidence_summary}`,
`{output_path}`.

---

Longtask plan-stage **claude end-round summary** (Claude opus Agent).
Preserve every plan field (`goals`, `dod`, `source_requirements`,
`verify_cmd`, `file_scope`, `do_not_touch`) and every spec-level REQ-*
anchor. No code. No plan-body edits. No user confirmation. Round
`{round_number}` of `classification.cross_rounds`; stage = plan.

## Implementation Plan Under Review

Path: `{plan_path}` · SHA-256: `{plan_sha256}`

```markdown
{implementation_plan_text}
```

## Classification

```json
{classification_json}
```

## Enhanced Spec (settled — read-only)

Path: `{enhanced_spec_path}` · Alignment matrix: `{alignment_matrix_path}`

## Previous Round State (empty on round 1)

```markdown
{previous_round_state}
```

## This Round's Inputs (codex Phase 1 / mid-summary digest Phase 2 / claude Phase 3)

```markdown
{codex_phase_outputs}
```
```markdown
{codex_mid_summary}
```
```markdown
{claude_phase_outputs}
```

## Repo Evidence Summary

```text
{repo_evidence_summary}
```

## Aggregation Rule (REQ-006) — aggregate, do not re-derive

Phase 3 lenses already produced agree/disagree/extend entries against the
codex digest (see `plan-roundtable.md` Output Contract). Collect and
adjudicate those entries into the tables — do not re-perform
reconciliation reasoning. A topic the codex digest flagged for which no
Phase 3 lens issued a disagreement entry is a codex-blindspot signal. Net
weakening of plan integrity (`do_not_touch` relaxed / `verify_passes_when`
softened / `dod` dropped) without compensating evidence is a
`BLOCKED_SPEC_REWRITE` trigger.

## Required Artifact — write to `{output_path}` using this exact Markdown structure (the contract is the headings and column shapes):

```markdown
# Plan Round {round_number} State

## Consensus Accepted Edits (codex phase ∩ claude phase)

| Edit ID | Phase | Field | Accepted Change | Reason | Verifier Impact |
|---|---|---|---|---|---|

## Codex-vs-Claude-Phase Disagreements

| Topic | Phase | Codex Phase Position | Claude Phase Position | Smallest Safe Next Step |
|---|---|---|---|---|

## Codex Blindspot Resolution

Verdict ∈ {`real_consensus`, `codex_blindspot_corrected`, `still_ambiguous`}.

| Cluster ID | Phase | Codex Side | Claude Phase Side | Verdict |
|---|---|---|---|---|

## Plan Integrity Adjudication

Net Effect ∈ {`weakening_rejected`, `weakening_accepted_with_reason`,
`net_weakening_no_compensation` (BLOCKED trigger)}.

| Phase | Field | Codex Proposed Weakening | Claude Phase Verdict | Net Effect |
|---|---|---|---|---|

## Pending Edits Needing Other Phase Confirmation

| Edit ID | Phase That Proposed | Reason Other Phase Didn't Address | Carry to Next Round? |
|---|---|---|---|

## Rejected Or Deferred Edits

| Proposal | Reason | Plan Field Protected |
|---|---|---|

## REQ-* Coverage Snapshot

Status ∈ {covered, partial, missing, out_of_scope}. Any new `missing` /
`out_of_scope` MUST also appear in Codex-vs-Claude-Phase Disagreements or
Plan Integrity Adjudication.

| REQ-* anchor | Phase(s) | Status | Notes |
|---|---|---|---|

## Next Round Focus

- Concrete focus item (only when `{round_number} < classification.cross_rounds`;
  on the final round write "N/A — hand off to plan-consensus-editor")

## Residual Risks

- Risks the consensus editor must explicitly accept or address
```

## Final Response — exactly one JSON object

```json
{
  "status": "READY_FOR_NEXT_ROUND | READY_FOR_PLAN_CONSENSUS | BLOCKED_SPEC_REWRITE",
  "stage": "plan", "round_number": 1, "round_state_path": "<output_path>",
  "plan_requirements_preserved": true,
  "codex_vs_claude_disagreement_count": 0,
  "blindspot_resolutions": { "real_consensus": 0, "codex_blindspot_corrected": 0, "still_ambiguous": 0 },
  "integrity_net_weakenings": [], "req_anchors_at_risk": [],
  "next_round_focus": [], "blocked_reason": ""
}
```

`READY_FOR_NEXT_ROUND` when `{round_number} < classification.cross_rounds`;
`READY_FOR_PLAN_CONSENSUS` on the final round; `BLOCKED_SPEC_REWRITE` only
on net weakening without compensation or REQ-* drop —
`integrity_net_weakenings[]` + `req_anchors_at_risk[]` must enumerate.
