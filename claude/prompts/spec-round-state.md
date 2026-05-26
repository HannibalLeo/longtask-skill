# Longtask Spec Round-State (Claude End-Round Summary) Prompt

<!-- ROUTING NOTE
Claude opus via Agent tool. Invoked ONCE per spec-roundtable round as Phase 4
(after codex lenses → codex mid-summary → claude lenses). Produces the durable
round-state markdown the next round reads as `prior_round_state` and the
terminal `spec-consensus-editor` aggregates. Spec body is NOT mutated here.
-->

Substitutions: `{input_path}`, `{input_sha256}`, `{round_number}`,
`{classification_json}`, `{source_spec_text}`, `{previous_round_state}`,
`{codex_phase_outputs}`, `{codex_mid_summary}`, `{claude_phase_outputs}`,
`{repo_evidence_summary}`, `{output_path}`.

---

Longtask spec-stage **claude end-round summary** (Claude opus via Agent tool).
Compress this round into the durable state artifact below. Preserve the
source spec — never silently drop, weaken, or reverse a source requirement.
No code. No spec-body edits. No user confirmation.

- Round: `{round_number}` (of `classification.cross_rounds`), stage = spec.

## Source Spec

Path: `{input_path}` · SHA-256: `{input_sha256}`

```markdown
{source_spec_text}
```

## Classification

```json
{classification_json}
```

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

## Aggregation Rule (REQ-006)

**Aggregate, do not re-derive.** Phase 3 lenses already produced
agree/disagree/extend entries against the codex digest (see
`spec-roundtable.md` Output Contract). Collect and adjudicate those entries
into the tables — do not re-perform reconciliation reasoning. A topic the
codex digest flagged for which no Phase 3 lens issued a disagreement entry
is a codex-blindspot signal. Preserve every REQ-* anchor.

## Required Artifact

Write to `{output_path}` using this exact Markdown structure (tables only —
the contract is the headings and column shapes, not narrative around them):

```markdown
# Spec Round {round_number} State

## Consensus Accepted Edits (codex phase ∩ claude phase)

| Edit ID | Spec Section | Accepted Edit | Reason | Verification Impact |
|---|---|---|---|---|

## Codex-vs-Claude-Phase Disagreements

| Topic | Codex Phase Position | Claude Phase Position | Smallest Safe Next Step |
|---|---|---|---|

## Codex Blindspot Resolution

One row per `agreement_to_verify` cluster from the codex digest. Verdict ∈
{`real_consensus`, `codex_blindspot_corrected`, `still_ambiguous`}.

| Cluster ID | Codex Side | Claude Phase Side | Verdict |
|---|---|---|---|

## Pending Edits Needing Other Phase Confirmation

| Edit ID | Phase That Proposed | Reason Other Phase Didn't Address | Carry to Next Round? |
|---|---|---|---|

## Rejected Or Deferred Edits

| Proposal | Reason | Source Requirement Protected |
|---|---|---|

## Requirement Preservation Check

Status ∈ {`protected`, `weakening_accepted_with_reason`, `still_at_risk`}.
Any `still_at_risk` row MUST also appear in Codex-vs-Claude-Phase
Disagreements or trigger a BLOCKED return.

| Source Requirement (REQ-*) | Preserved In Carry-Forward | Status | Notes |
|---|---|---|---|

## Next Round Focus

- Concrete focus item (only when `{round_number} < classification.cross_rounds`;
  on the final round write "N/A — hand off to spec-consensus-editor")

## Residual Risks

- Risks the consensus editor must explicitly accept or address
```

## Final Response

Return exactly one JSON object:

```json
{
  "status": "READY_FOR_NEXT_ROUND | READY_FOR_SPEC_CONSENSUS | BLOCKED_SPEC_REWRITE",
  "stage": "spec",
  "round_number": 1,
  "round_state_path": "<output_path>",
  "source_requirements_preserved": true,
  "codex_vs_claude_disagreement_count": 0,
  "blindspot_resolutions": { "real_consensus": 0, "codex_blindspot_corrected": 0, "still_ambiguous": 0 },
  "still_at_risk_req_anchors": [],
  "next_round_focus": [],
  "blocked_reason": ""
}
```

`READY_FOR_NEXT_ROUND` when `{round_number} < classification.cross_rounds`;
`READY_FOR_SPEC_CONSENSUS` on the final round; `BLOCKED_SPEC_REWRITE` only
when source intent cannot survive without human repair —
`still_at_risk_req_anchors[]` must enumerate the triggering REQ-* anchors.
