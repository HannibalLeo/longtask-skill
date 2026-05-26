---
source_spec_path: docs/specs/2026-05-27-token-waste-refactor-spec.md
source_spec_sha256: "e5be9a6f2a279ef671243ad31fac112236e49d401cd471daa46e3451e583da40"
enhanced_spec_path: null
enhanced_spec_sha256: null
final_verify_cmd: "bash scripts/verify-all.sh && bash scripts/scan-stale-references.sh"
final_e2e2_cmd: "bash scripts/e2e-dual-harness-smoke.sh --capture-dispatch-counts .longtask/reports/2026-05-27-token-waste-refactor/screenshots/"
final_report_path: ".longtask/reports/2026-05-27-token-waste-refactor/final-report.md"
default_model_tier: sonnet
default_reasoning_effort: medium
gating: []
ship: false
docs_sync: false
---

# Longtask Plugin Token-Waste Refactor — Implementation Plan / Execution Spec

> Plan for the source spec at
> `docs/specs/2026-05-27-token-waste-refactor-spec.md`. Six phases of
> prompt-surgery + protocol-change work; no production code touched.
> Working tree root = the plugin repo
> (`~/.claude/plugins/marketplaces/longtask-skill/`).
> Execute via `/longtask:longtaskCode docs/plans/2026-05-27-token-waste-refactor-plan.md`
> from a Claude Code session rooted in this repo.

## Source Requirements

| ID | Requirement | Source-spec section | Phases |
|---|---|---|---|
| REQ-001 | Externalize known-traps-appendix to runtime path; worker references via `Read` | § REQ-001 | P1 |
| REQ-002 | Split known-traps into universal (Cat 1-4) + claude-only (Cat 5); codex receives universal only | § REQ-002 | P1 |
| REQ-003 | spec-classifier default lens count ≤ 3; lenses 4-5 require risk_reasons | § REQ-003 | P2 |
| REQ-004 | plan-stage roundtable uses pruned lens set (engineering + ceo-product default) | § REQ-004 | P2 |
| REQ-005 | codex mid-summary outputs compressed digest, not full text | § REQ-005 | P3 |
| REQ-006 | round-state.md prose ≤ 150 lines; remove reconciliation section | § REQ-006 | P4 |
| REQ-007 | cross_rounds default = 1; auto-cap = 2; 3 only via spec frontmatter | § REQ-007 | P5 |
| REQ-008 | Codify codex = discussion + verification only invariant in all 3 SKILL.md + orchestrator | § REQ-008 | P6 |

## Alignment Matrix

| REQ | Phase | DoD evidence | Status |
|---|---|---|---|
| REQ-001 | P1 | DoD-P1-1 (file exists), DoD-P1-2 (sub-agent prompt updated), DoD-P1-3 (line-count of inlined appendix in worker prompt = 0) | planned |
| REQ-002 | P1 | DoD-P1-4 (universal + claude-only files exist), DoD-P1-5 (codex dispatch references universal only) | planned |
| REQ-003 | P2 | DoD-P2-1 (classifier output contract states max 3 default), DoD-P2-2 (≥4 requires non-empty risk_reasons) | planned |
| REQ-004 | P2 | DoD-P2-3 (plan-stage lens set declared as pruned subset), DoD-P2-4 (orchestrator Step 4b reflects pruned set) | planned |
| REQ-005 | P3 | DoD-P3-1 (mid-summary output contract = digest), DoD-P3-2 (Phase 3 lens input excludes raw codex outputs) | planned |
| REQ-006 | P4 | DoD-P4-1 (spec-round-state.md ≤ 150 lines), DoD-P4-2 (plan-round-state.md ≤ 150 lines), DoD-P4-3 (reconciliation section removed) | planned |
| REQ-007 | P5 | DoD-P5-1 (classifier policy cap = 2), DoD-P5-2 (SKILL.md cross_rounds section updated), DoD-P5-3 (orchestrator prompt aligned) | planned |
| REQ-008 | P6 | DoD-P6-1 (codex role boundary section in 3 SKILL.md), DoD-P6-2 (orchestrator preamble updated), DoD-P6-3 (Role × Model matrix audited; no codex authoring rows) | planned |

## Final E2E2 and Screenshot Report Contract

- Screenshots directory: `.longtask/reports/2026-05-27-token-waste-refactor/screenshots/`
- Final report path: `.longtask/reports/2026-05-27-token-waste-refactor/final-report.md`
- E2E2 evidence: the dual-harness smoke script runs a tiny synthetic spec
  end-to-end (or as far as the smoke script supports) and captures dispatch
  counts to a JSON sidecar in the screenshots dir. The report tabulates
  before/after dispatch counts per stage to prove the token reduction
  landed (target ≥ 30% reduction on the smoke spec; full ~50% is only
  visible on real multi-phase runs and is not in scope for this plan's
  E2E2).

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

All phases are prose-surgery + protocol-change work executable by any Claude
worker tier. No browser flow, no SSH, no Skill dispatch inside phase bodies.

---

## P1 — Externalize known-traps appendix; split universal vs claude-only

```yaml
source_requirements: [REQ-001, REQ-002]
goals: Stop prepending the 215-line known-traps appendix to every worker dispatch; split into universal + claude-only files; codex receives universal only.
file_scope:
  - claude/prompts/known-traps-appendix.md
  - claude/prompts/known-traps-universal.md
  - claude/prompts/known-traps-claude-only.md
  - claude/prompts/claude-sub-agent.md
  - claude/prompts/claude-orchestrator.md
  - codex/prompts/codex-longtask-code.md
  - codex/prompts/conductor.md
  - skills/claude-longtask/SKILL.md
  - skills/claude-longtask-code/SKILL.md
do_not_touch:
  - claude/lib/**
  - codex/lib/**
  - schemas/**
  - scripts/**
verify_cmd: "wc -l claude/prompts/known-traps-universal.md claude/prompts/known-traps-claude-only.md && ! grep -q 'Prepend `known-traps-appendix.md` full text' claude/prompts/claude-sub-agent.md && grep -q 'known-traps-active.md' claude/prompts/claude-sub-agent.md"
verify_passes_when: "exit 0; both new prompt files exist and are non-empty; legacy 'Prepend full text' instruction is gone from sub-agent prompt; sub-agent now references the runtime path"
max_retry_rounds: 3
dod:
  - "DoD-P1-1: claude/prompts/known-traps-universal.md exists, contains Categories 1-4 (codex CLI quirks / reward hacking / scope drift / verifier integrity), ≤ 180 lines."
  - "DoD-P1-2: claude/prompts/known-traps-claude-only.md exists, contains Category 5 (Claude harness specifics), ≤ 60 lines."
  - "DoD-P1-3: claude/prompts/claude-sub-agent.md Step 2a no longer prepends the appendix verbatim; instead writes a stable file at .longtask/known-traps-active-{spec_basename}.md (containing universal + claude-only concatenated for claude workers) once per phase and the worker prompt instructs the worker to Read that file before starting."
  - "DoD-P1-4: codex-side worker dispatch path (codex/prompts/codex-longtask-code.md and codex/prompts/conductor.md) references universal only, not claude-only."
  - "DoD-P1-5: skills/claude-longtask/SKILL.md and skills/claude-longtask-code/SKILL.md prompts-table rows describe the new split."
  - "DoD-P1-6: bash scripts/verify-all.sh passes (no structural break)."
approach_hint: |
  The split is a content move, not a rewrite. Copy Categories 1-4 verbatim
  into known-traps-universal.md; copy Category 5 verbatim into
  known-traps-claude-only.md; keep known-traps-appendix.md as a one-line
  pointer to both for back-compat ("Split into universal/ + claude-only/
  in 2026-05-27 refactor — see those files"). The sub-agent's
  write-once-per-phase needs `mkdir -p .longtask/ && cat universal
  claude-only > .longtask/known-traps-active-{spec_basename}.md`.
```

---

## P2 — spec-classifier lens cap + plan-stage pruned lens set

```yaml
source_requirements: [REQ-003, REQ-004]
goals: spec-classifier defaults to ≤ 3 required_lenses; lenses 4-5 require non-empty risk_reasons; plan-stage roundtable runs on a pruned subset (engineering + ceo-product default, others opt-in by file_scope match).
file_scope:
  - claude/prompts/spec-classifier.md
  - claude/prompts/claude-orchestrator.md
  - skills/claude-longtask/SKILL.md
  - skills/claude-longtask-plan/SKILL.md
do_not_touch:
  - claude/prompts/spec-roundtable.md
  - claude/prompts/plan-roundtable.md
  - claude/lib/**
  - schemas/**
verify_cmd: "grep -E 'max.*3.*default|default.*≤.*3|cap.*3.*lens' claude/prompts/spec-classifier.md && grep -E 'risk_reasons.*required|risk_reasons\\[\\] must be non-empty' claude/prompts/spec-classifier.md && grep -q 'plan-stage lens set' claude/prompts/claude-orchestrator.md"
verify_passes_when: "exit 0; spec-classifier prompt declares ≤3 default + risk_reasons gate for 4-5; orchestrator declares pruned plan-stage lens set"
max_retry_rounds: 3
dod:
  - "DoD-P2-1: spec-classifier.md output contract documents 'default required_lenses ≤ 3'; lenses 4 and 5 require a non-empty risk_reasons[] item that cites a cross-domain risk in the spec under audit."
  - "DoD-P2-2: spec-classifier.md output example shows 3 lenses by default (engineering + a product lens + a domain lens chosen per task kind); the 5-lens example is moved to an explicit 'high-risk specs only' subsection."
  - "DoD-P2-3: claude-orchestrator.md Step 4b explicitly states the plan-stage lens set is a pruned subset of the spec-stage set: engineering + ceo-product by default; other lenses included only when at least one phase file_scope matches the lens's domain (UI-design → frontend/UI globs; domain-expert → domain-specific paths)."
  - "DoD-P2-4: skills/claude-longtask/SKILL.md and skills/claude-longtask-plan/SKILL.md Roundtable sections describe the new lens-count policy and the spec-stage vs plan-stage distinction."
  - "DoD-P2-5: bash scripts/verify-all.sh passes."
```

---

## P3 — codex mid-summary outputs compressed digest

```yaml
source_requirements: [REQ-005]
goals: Change codex mid-round summary output contract from full lens text re-paste to a compressed digest (one bullet per lens ≤ 25 words + a single Codex-vs-Claude disagreement table). Update Phase 3 lens prompts to consume the digest, not raw codex-lens outputs.
file_scope:
  - claude/prompts/spec-codex-mid-summary.md
  - claude/prompts/plan-codex-mid-summary.md
  - claude/prompts/spec-roundtable.md
  - claude/prompts/plan-roundtable.md
  - claude/prompts/claude-orchestrator.md
do_not_touch:
  - claude/prompts/spec-round-state.md
  - claude/prompts/plan-round-state.md
  - claude/prompts/spec-consensus-editor.md
  - claude/prompts/plan-consensus-editor.md
  - claude/lib/**
  - schemas/**
verify_cmd: "grep -q 'digest format' claude/prompts/spec-codex-mid-summary.md && grep -q 'digest format' claude/prompts/plan-codex-mid-summary.md && grep -E '\\{codex_mid_summary_digest\\}|digest output' claude/prompts/spec-roundtable.md && grep -E '\\{codex_mid_summary_digest\\}|digest output' claude/prompts/plan-roundtable.md"
verify_passes_when: "exit 0; both mid-summary prompts declare a digest output format; both Phase 3 lens prompts reference the digest substitution token"
max_retry_rounds: 3
dod:
  - "DoD-P3-1: spec-codex-mid-summary.md output contract section specifies the digest format: per-lens one-bullet synthesis (≤ 25 words each) + one Codex-vs-Claude disagreement table with at most ~5 rows of {lens, codex_position, claude_position, reconciliation_proposal}. No verbatim re-paste of lens outputs."
  - "DoD-P3-2: plan-codex-mid-summary.md mirrors the same digest contract."
  - "DoD-P3-3: spec-roundtable.md Phase 3 (claude lens) input section references {codex_mid_summary_digest} instead of {codex_phase_outputs}; the raw lens outputs are written to disk for audit but are NOT injected into Phase 3 lens prompts."
  - "DoD-P3-4: plan-roundtable.md Phase 3 mirrors the same change."
  - "DoD-P3-5: claude-orchestrator.md Step 2 / Step 4b Phase 2 description reflects the digest output contract."
  - "DoD-P3-6: bash scripts/verify-all.sh passes; bash scripts/scan-stale-references.sh reports no broken substitution token references."
approach_hint: |
  The mid-summary already runs as a separate codex dispatch; the change is
  to its output contract, not its dispatch. Phase 3 lens prompts then
  point at the digest token. Raw lens outputs stay on disk (consensus
  editor at Phase 5 may still read them if it needs to drill into a
  specific lens; the digest is only the Phase 3 input channel).
```

---

## P4 — Compress spec-round-state.md + plan-round-state.md

```yaml
source_requirements: [REQ-006]
goals: Strip the ~80-line reconciliation section from both round-state editor prompts; target ≤ 150 lines each. Round-state editor aggregates Phase 3 lens disagreement entries; it does not re-derive them.
file_scope:
  - claude/prompts/spec-round-state.md
  - claude/prompts/plan-round-state.md
do_not_touch:
  - claude/prompts/spec-roundtable.md
  - claude/prompts/plan-roundtable.md
  - claude/prompts/spec-codex-mid-summary.md
  - claude/prompts/plan-codex-mid-summary.md
  - claude/prompts/spec-consensus-editor.md
  - claude/prompts/plan-consensus-editor.md
verify_cmd: "awk 'END{print NR}' claude/prompts/spec-round-state.md | awk '{exit ($1>150)}' && awk 'END{print NR}' claude/prompts/plan-round-state.md | awk '{exit ($1>150)}'"
verify_passes_when: "exit 0; both files are ≤ 150 lines"
max_retry_rounds: 3
dod:
  - "DoD-P4-1: claude/prompts/spec-round-state.md ≤ 150 lines (was 211)."
  - "DoD-P4-2: claude/prompts/plan-round-state.md ≤ 150 lines (was 235)."
  - "DoD-P4-3: the reconciliation-rules section (≈ lines 100-150 in the pre-edit file) is removed; replaced by a one-paragraph reference to 'see Phase 3 lens disagreement entries — aggregate, do not re-derive'."
  - "DoD-P4-4: required output sections (Consensus Accepted Edits / Pending Edits Needing Other Phase Confirmation / Codex-vs-Claude-Phase Disagreements table / Codex Blindspot Resolution / Plan Integrity Adjudication carry-forward) all remain — the cut is prose only, not contract."
  - "DoD-P4-5: bash scripts/verify-all.sh passes."
```

---

## P5 — cross_rounds default 1; auto-cap 2; 3 only via spec frontmatter

```yaml
source_requirements: [REQ-007]
goals: Change the cross_rounds policy across classifier, SKILL.md, and orchestrator. Default = 1; classifier auto-escalation cap = 2 (medium-risk taxonomy); 3 requires explicit spec-frontmatter override and the classifier may not emit 3 on its own.
file_scope:
  - claude/prompts/spec-classifier.md
  - claude/prompts/claude-orchestrator.md
  - skills/claude-longtask/SKILL.md
  - skills/claude-longtask-plan/SKILL.md
do_not_touch:
  - claude/prompts/spec-roundtable.md
  - claude/prompts/plan-roundtable.md
  - schemas/**
verify_cmd: "grep -E 'default.*cross_rounds.*1|cross_rounds.*default.*1' claude/prompts/spec-classifier.md && grep -E 'auto.*cap.*2|classifier.*max.*2' claude/prompts/spec-classifier.md && grep -q 'cross_rounds: 3' skills/claude-longtask/SKILL.md && grep -E 'user-forced|spec frontmatter only|explicit override' skills/claude-longtask/SKILL.md"
verify_passes_when: "exit 0; classifier declares default 1 + auto-cap 2; SKILL.md states cross_rounds=3 requires explicit frontmatter"
max_retry_rounds: 3
dod:
  - "DoD-P5-1: claude/prompts/spec-classifier.md output contract declares default cross_rounds=1; auto-escalation to 2 only on risk_reasons matching the medium-risk taxonomy (cross-module contract change / new external dependency / plan will have ≥4 phases / ambiguous scope). Classifier MUST NOT emit cross_rounds=3 on its own."
  - "DoD-P5-2: skills/claude-longtask/SKILL.md § 'Length policy — cross_rounds ∈ {1, 2, 3}' is rewritten: the 3-tier still exists but the table makes clear that 3 is user-forced (spec frontmatter only). The 'Mode resolution' precedence stays the same but emphasises classifier never picks 3."
  - "DoD-P5-3: claude-orchestrator.md cross_rounds-discussion sections (Step 1 classifier handling, Step 2 roundtable kickoff) reflect the new policy. The orchestrator must explicitly state 'if classifier emits cross_rounds=3, that is a bug; reject and re-classify' as a defensive check."
  - "DoD-P5-4: skills/claude-longtask-plan/SKILL.md cross_rounds reference is aligned with the new policy."
  - "DoD-P5-5: bash scripts/verify-all.sh passes."
```

---

## P6 — Codify codex = discussion + verification only (role partition invariant)

```yaml
source_requirements: [REQ-008]
goals: Add an explicit "Codex role boundary" load-bearing invariant section to the three claude-flow SKILL.md files and the orchestrator preamble. Audit the current Role × Model matrix in each file; any codex row that does authoring / editing / decision-primary / worker work is a defect to repair.
file_scope:
  - skills/claude-longtask/SKILL.md
  - skills/claude-longtask-plan/SKILL.md
  - skills/claude-longtask-code/SKILL.md
  - claude/prompts/claude-orchestrator.md
do_not_touch:
  - claude/prompts/spec-roundtable.md
  - claude/prompts/plan-roundtable.md
  - claude/prompts/spec-codex-mid-summary.md
  - claude/prompts/plan-codex-mid-summary.md
  - claude/prompts/codex-verifier.md
  - claude/prompts/codex-clarification.md
  - claude/prompts/spec-codex-sanity.md
  - claude/lib/**
  - codex/**
verify_cmd: "grep -q 'Codex role boundary' skills/claude-longtask/SKILL.md && grep -q 'Codex role boundary' skills/claude-longtask-plan/SKILL.md && grep -q 'Codex role boundary' skills/claude-longtask-code/SKILL.md && grep -q 'Codex role boundary' claude/prompts/claude-orchestrator.md"
verify_passes_when: "exit 0; the boundary section heading appears in all four files"
max_retry_rounds: 3
dod:
  - "DoD-P6-1: each of the three SKILL.md files gains a top-level '## Codex role boundary (load-bearing invariant)' section that enumerates the two allowed codex role categories (Discussion + Verification) with concrete examples per the spec § REQ-008, plus an explicit list of roles that must stay on Claude (classifier, consensus editors, plan writer, round-state editors, cross-rounds final review, final E2E2 report, decision-review primary, plan-integrity primary, final-alignment primary, docs-sync, ship, Step 6 phase worker)."
  - "DoD-P6-2: claude-orchestrator.md preamble (before § 'Owner four-step') gains the same boundary statement, condensed to ~10 lines."
  - "DoD-P6-3: the Role × Model matrix in skills/claude-longtask/SKILL.md and claude-orchestrator.md is audited; any row whose 'Primary' is Codex and whose role is NOT in the allowed Discussion+Verification list is repaired (move to Claude) and recorded in the final report. (Expectation: matrix is already aligned per prior commits; this step certifies it.)"
  - "DoD-P6-4: skills/claude-longtask-manifest-bridge/SKILL.md and skills/claude-longtask-review/SKILL.md (if they exist and dispatch codex sub-agents) are also audited; report whether they introduce any codex authoring role."
  - "DoD-P6-5: bash scripts/verify-all.sh passes."
approach_hint: |
  The boundary section is documentation, not behavior change. Most of the
  work is auditing the Role × Model matrices and confirming the prior
  commits already aligned them. If P6 finds drift (e.g. a codex
  consensus-editor row still exists somewhere), that drift is a P6
  finding, not a separate phase — fix it here and note in the final
  report.
```

---

## Notes for the executing session

- This plan is `self_contained_plan` in shape: the source spec at
  `docs/specs/2026-05-27-token-waste-refactor-spec.md` is the only
  external dependency.
- All phases default to `model_tier: sonnet` and `reasoning_effort: medium`.
  No phase warrants opus or xhigh — this is prose / protocol surgery.
- `max_retry_rounds: 3` for all phases. If a phase exceeds 2 retries, that
  is a signal the DoD bullets are not testable enough — flag as a
  BLOCKED_SPEC rather than burning the third retry.
- After all phases PASS, the final E2E2 step runs
  `scripts/e2e-dual-harness-smoke.sh` with a dispatch-count flag (the
  flag itself is not in scope for this plan — if the flag does not
  exist yet, the final-e2e2 sub-agent should add it as a one-line
  addition to the smoke script and capture before/after dispatch
  counts manually by re-running the smoke script on the pre-refactor
  HEAD vs HEAD).
- The final report MUST tabulate before/after dispatch counts and
  appendix line-prepend counts to verify the token reduction landed.

## Open Decisions (deferred to a later sprint per source spec § Out of scope)

- OD-1: Step 5 plan-integrity vs Step 8 final-alignment overlap — defer
  until this refactor's token-delta is measured; the overlap may be
  smaller-than-estimated once REQ-001 through REQ-007 land.
- OD-2: `claude-orchestrator.md` (867 lines) split into core +
  reference — defer; the orchestrator file is the main session's loaded
  context but only once per run, not per-phase, so the cumulative cost
  is lower than the per-phase issues this plan addresses.
- OD-3: Heartbeat granularity reduction — defer; the state-file write
  cost is small relative to LLM dispatch cost.
- OD-4: Plan-writer multi-agent fan-out threshold tuning — defer; the
  plan thinness contract (prior 2026-05-27 commit) already reduces the
  fan-out volume.

These OD-* items are NOT planned in this run; they are listed so the
post-run final report can flag them as known deferrals.
