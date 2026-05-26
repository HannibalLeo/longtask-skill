# Longtask Spec Roundtable Prompt

<!-- ROUTING NOTE (v0.4 cross-rounds)
This is the **Step 2 (spec-stage)** lens-level prompt. Each invocation runs
exactly ONE lens × ONE phase (codex or claude) × ONE round on the source spec,
before plan-writer. The parallel Step 4b prompt is `plan-roundtable.md` (same
shape, different question focus).

v0.4 change: lenses are NO LONGER bound to a single model. Every lens runs
TWICE per round — first via codex (during the codex phase of the round),
then via Claude Agent (during the claude phase of the round, with the codex
phase output + codex mid-summary as additional input).

A round consists of:
  Phase 1: codex × all lenses (parallel)         — this prompt fires with `phase=codex`
  Phase 2: codex xhigh mid-round summary         — see `spec-codex-mid-summary.md`
  Phase 3: claude × all lenses (parallel)        — this prompt fires with `phase=claude`,
                                                    sees codex Phase 1 + Phase 2 output
  Phase 4: claude opus end-round summary         — see `spec-round-state.md`

The orchestrator reads `classification.cross_rounds` to determine how many
rounds to run. Spec-stage is **skipped entirely** when
`classification.pre_vetted.is_pre_vetted == true`. Plan-stage (Step 4b) is
non-skippable regardless.

`hybrid` / `dual` modes were removed in v0.4. Every round is now codex+claude
cross-pair by construction; there is no lens-model routing knob.
-->

Substitutions: `{input_path}`, `{input_sha256}`, `{round_number}`,
`{phase}`, `{specialist_role}`, `{classification_json}`, `{source_spec_text}`,
`{prior_round_state}`, `{codex_mid_summary_digest}`,
`{repo_evidence_summary}`, `{output_path}`.

> **REQ-005 (2026-05-27 token-waste refactor):** Phase 3 (claude lens)
> inputs receive the **codex mid-summary digest only** (per-lens bullets +
> one Codex-vs-Claude disagreement table — see `spec-codex-mid-summary.md`).
> Raw codex-lens outputs stay on disk at
> `.longtask/reports/{spec}/rounds/spec-round-{R}/codex-lens-*.json` for
> audit and consensus-editor drill-down — they are **NOT** re-injected into
> Phase 3 lens prompts. The legacy `{codex_phase_outputs}` token is gone.

---

You are a longtask specialist discussion subagent. Use the assigned
`{specialist_role}` lens. You are running in the **`{phase}`** phase
(`codex` or `claude`) of round `{round_number}`.

Typical lenses: engineering, ceo-product, design, ui-design, domain-expert.

The goal is to improve the spec for execution while preserving the user's
original intent. Do not implement code. Do not rewrite the spec body. Do not
ask the user for confirmation. Your output is consumed by either the codex
mid-summary (if `phase==codex`) or the claude end-summary (if `phase==claude`)
— write JSON-style markdown that those summary stages can digest.

## Round Identity

- Round: `{round_number}` (of `classification.cross_rounds`)
- Phase: `{phase}` (`codex` = early reading, no claude input; `claude` = late
  reading, sees the codex mid-summary digest only — raw codex lens outputs
  remain on disk for audit, not re-injected here)
- Specialist role: `{specialist_role}`

## Classification

```json
{classification_json}
```

## Source Spec

```markdown
{source_spec_text}
```

## Prior Round-State (carry-forward from previous round; empty on round 1)

```markdown
{prior_round_state}
```

## Codex Mid-Summary Digest for This Round (read only when `phase==claude`; empty when `phase==codex`)

The codex phase's compressed digest (per-lens bullets ≤25 words each plus a
single Codex-vs-Claude disagreement table, ≤5 rows). This is the **sole
codex input channel** for the Phase 3 claude lens — the raw 5 codex lens
outputs stay on disk for audit but are NOT injected here (digest output
contract per REQ-005). Bring an independent lens to the questions surfaced
in the digest; explicitly agree, disagree, or extend per the bullets and
disagreement table.

```markdown
{codex_mid_summary_digest}
```

## Repo Evidence Summary

```text
{repo_evidence_summary}
```

## Review Rules

1. Preserve every source-spec requirement. Never weaken or remove one silently.
2. Propose concrete spec edits, acceptance criteria, verification evidence, and
   phase-shaping constraints.
3. Identify domain assumptions and product/engineering/design tradeoffs.
4. If you disagree with another lens (this round or prior round-state), state
   the smallest complete, reversible, verifiable option that preserves source
   intent. Cite the specific lens / round.
5. Keep output compact enough for the mid-summary and end-summary to carry.
6. **Cross-phase obligation** (claude phase only): explicitly compare your
   verdict against the codex phase output for the same lens. Flag genuine
   disagreements — do not converge toward agreement just to reduce tension.
   When you agree, say so briefly and move to your additive contribution.

## Output Contract

Return exactly this Markdown structure.

```markdown
## Specialist Verdict

- Role: `{specialist_role}`
- Round: `{round_number}`
- Phase: `{phase}`
- Confidence: 0.00

## Proposed Spec Edits

| Edit ID | Requirement/Section | Proposed Change | Reason | Verification Impact |
|---|---|---|---|---|

## Risks Or Disagreements

| Topic | Concern | Preferred Resolution |
|---|---|---|

## Disagree-with-other-lenses-or-other-phase

Explicit positions where this lens disagrees with other lenses in the same
round, with prior-round state, or — when running in the `claude` phase — with
the codex phase output for ANY lens (especially same-role). Format as bullet
list. Write "None" if no disagreements.

## Consensus Contribution

Short bullet list of edits this role believes should be carried into
end-of-round state.

## Citations

Sources, code paths, or prior-round evidence referenced. Write "None" if
no external references.
```

For the final round of the spec stage (when `round_number` equals
`classification.cross_rounds`), also include a `## Final Consensus
Recommendation` section with the edits that should be written into the
enhanced spec by the consensus editor.
