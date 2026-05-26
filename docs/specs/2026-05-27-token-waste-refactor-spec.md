# Longtask Plugin Token-Waste Refactor — Source Spec

> Source spec for `docs/plans/2026-05-27-token-waste-refactor-plan.md`.
> Input shape: `source_spec`. Drives a `/longtask:longtaskCode` execution
> rooted at the plugin repo (`~/.claude/plugins/marketplaces/longtask-skill/`).

## Goal

Cut a typical 6-phase longtask run's token cost by ~50% by addressing the four
structural-waste patterns identified in the 2026-05-27 audit, plus codify the
claude-flow role partition (codex = discussion + verification only; Claude
owns authoring and the Step 6 worker) and tighten the default roundtable
round count.

## Why

A typical `cross_rounds=2` run currently issues 40+ roundtable lens
dispatches, prepends a 215-line known-traps appendix to every worker round,
and ships a round-state editor prompt that re-explains reconciliation rules
the Phase 3 lens work already performed. The audit estimates 40-50% total
token waste from these patterns. The fix is prose-surgery + protocol changes,
no new infrastructure.

## Source Requirements

REQ-001 — `claude/prompts/known-traps-appendix.md` is prepended verbatim to
every worker dispatch (`claude/prompts/claude-sub-agent.md` Step 2a). For a
6-phase run with avg 1.5 retries that is ~1900 line-prepends of identical
content per run. Externalize: write the appendix to a stable runtime path
once at orchestrator startup; worker prompt references the path via `Read`
instead of carrying inline content.

REQ-002 — `known-traps-appendix.md` Category 5 ("Claude harness specifics" —
Agent tool background timeout, 1M context budget, exit 142, `/ship`
specifics) is irrelevant to codex worker / verifier contexts (codex has no
Agent tool, no 1M context, no `/ship` harness). Split the appendix into a
universal core (Categories 1-4) and a claude-only addendum (Category 5).
Codex-side prompts receive the universal file only; claude-side worker /
sub-agent dispatches receive both.

REQ-003 — `claude/prompts/spec-classifier.md` defaults to 5
`required_lenses` (engineering + ceo-product + design + ui-design +
domain-expert). The output contract should cap default at 3 lenses
(engineering + one product/ceo-product + one domain-specific lens chosen
per task kind); lenses 4 and 5 require non-empty `risk_reasons[]` items
that cite a specific cross-domain risk for the spec under audit. Wide-net
classification is the cost-explosion path.

REQ-004 — The plan-stage roundtable (Step 4b) currently runs on the same
`required_lenses` set as the spec-stage roundtable. UI-design and
domain-expert lenses contribute little to phase decomposition / file_scope
/ verify_cmd authoring (their value already landed in the enhanced spec).
The plan-stage lens set must be a pruned subset of the spec-stage set: by
default engineering + ceo-product only. Other lenses opt in only when the
plan spans their domain (e.g. UI-design lens included only when ≥1 phase
has `file_scope` matching frontend / UI paths).

REQ-005 — `claude/prompts/spec-codex-mid-summary.md` and
`plan-codex-mid-summary.md` output protocol currently produces a synthesis
that Phase 3 (claude lens) inputs paste in full alongside the raw lens
outputs. Each Phase 3 lens dispatch ends up re-reading 5 codex-lens
outputs × full text plus the mid-summary. Change the mid-summary output
contract to emit a compressed **digest**: one bullet per codex-lens
position (≤ 25 words each) plus a single Codex-vs-Claude disagreement
table. Phase 3 lens dispatches consume the digest only; raw codex-lens
outputs remain on disk for audit but are not re-injected into Phase 3
context.

REQ-006 — `claude/prompts/spec-round-state.md` (211 lines) and
`plan-round-state.md` (235 lines) include a ~80-line reconciliation
section that re-teaches the model how to audit Codex-vs-Claude
disagreements. The Phase 3 lens dispatches already produced
disagreement entries; round-state editor's job is to aggregate, not
re-derive. Strip the reconciliation prose; reference Phase 3 lens
disagreement entries instead. Target ≤ 150 lines each.

REQ-007 — `cross_rounds` policy currently presents `{1, 2, 3}` as
equally-available classifier choices. In practice round 3 is for
irreversible / safety / regulatory work; defaulting to it on ambiguous
specs burns tokens. Change the policy:
- Default `cross_rounds = 1`.
- Classifier auto-escalation cap = 2 (only on `risk_reasons[]` that match
  the medium-risk taxonomy).
- `cross_rounds = 3` only when spec frontmatter explicitly sets it
  (user-forced); classifier never emits 3 on its own.

REQ-008 — Codify the claude-flow role partition as a load-bearing invariant
in `skills/claude-longtask/SKILL.md`, `skills/claude-longtask-plan/SKILL.md`,
`skills/claude-longtask-code/SKILL.md`, and the
`claude/prompts/claude-orchestrator.md` preamble. The rule:

- **Codex sub-agents are LIMITED to two role categories:**
  - **Discussion** — spec-roundtable codex-phase lens (Step 2 Phase 1),
    plan-roundtable codex-phase lens (Step 4b Phase 1), codex mid-round
    summary (Step 2 Phase 2 / Step 4b Phase 2), codex spec sanity
    (Step 3).
  - **Verification** — phase verifier (Step 6), plan-integrity secondary
    (Step 5), decision-review secondary (Step 6 decision gate),
    final-alignment secondary (Step 8).
- **All authoring and worker roles stay on Claude:** spec classifier,
  consensus editors (spec + plan), plan writer, round-state editors,
  cross-rounds final review, final E2E2 report, decision-review primary,
  plan-integrity primary, final-alignment primary, docs-sync, ship, and
  the Step 6 phase worker (already moved per the 2026-05-26 refactor).
- The rule applies to `claude-longtask`, `claude-longtask-plan`, and
  `claude-longtask-code` identically.

## Out of scope

These remain open from the audit and are deferred to a later refactor:

- Step 5 plan-integrity vs Step 8 final-alignment overlap audit (audit
  Finding #5).
- `claude/prompts/claude-orchestrator.md` (867 lines) split into core +
  reference (Finding #6).
- Plan-writer multi-agent fan-out threshold tuning (Finding #8).
- Heartbeat granularity reduction (Finding #9).
- spec-classifier output schema verbosity beyond the lens-count cap in
  REQ-003 (Finding #7).

These are flagged in the plan's `## Open Decisions` section for the user
to triage after this refactor lands and the actual token delta is
measured.
