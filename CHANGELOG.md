# /longtask — Changelog

Orchestrator decision-loop tightening, oldest first.

---

## 2026-05-26 — Stop asking the user about v2 schema gaps and roundtable mode

Three changes:

1. **Step 0 no longer validates v2 frontmatter on the input.** That check moved to Step 1 (for plan-shape inputs that skip plan-writer) and Step 4 (for source_spec / hybrid inputs whose v2 plan is produced by plan-writer).
2. **Classifier now emits `suggested_roundtable_mode`**, and orchestrator resolves the mode via strict precedence `spec.roundtable_mode > classifier.suggested > "hybrid"` with no `ASK_HUMAN` path.
3. **Low-risk `discussion_rounds` floor raised from 1–2 to 3**; intermediate values 1, 2, 4 are no longer emitted; classifier must pick 5 (and `suggested_roundtable_mode: "dual"`) when uncertain.

> Superseded by the **third pass** below — `discussion_rounds` was later replaced by `(spec_rounds, plan_rounds)`.

---

## 2026-05-26 (same day, second pass) — Uncertainty Clarification Round

Added the **Uncertainty Clarification Round** — one extra `codex exec` tie-breaker that fires automatically before any `ASK_HUMAN` that stems from model-vs-model uncertainty (not from a categorical veto). Wired into:

- **Step 3** (NEEDS_REVISION with ask_human or high-risk hallucination)
- **Decision Gate** (disagree + no veto + low confidence delta)

Vetoes still escalate immediately; Step 8 final-alignment-review is exempt (already mandatory dual).

New artifacts: `prompts/codex-clarification.md`, `schemas/codex-clarification.schema.json`.

**Net effect:** orchestrator only bothers the user when reasoning genuinely runs out or a categorical high-risk path is in play, never on "two models disagree, take your pick".

---

## 2026-05-26 (third pass) — Split roundtable into two stages; remove single-model modes

**Split roundtable into two stages** and replaced the single `discussion_rounds ∈ {1,3,5}` with a 4-tier `(spec_rounds, plan_rounds)` scheme `{0+1, 1+1, 2+1, 3+2}`.

- **Spec-roundtable (Step 2)** runs on the source spec before plan-writer.
- **Plan-roundtable (new Step 4b)** runs on the implementation plan after plan-writer, before plan-integrity. `plan_rounds ≥ 1` always — even pre-vetted 0+1 inputs get one plan-stage sanity round.

**Rationale:** roundtable's value depends on *when* it sees the artifact — spec-stage catches direction errors when pivoting is cheap; plan-stage catches execution-design errors when phases are concrete and verifiers can be checked for observability. A single late roundtable on a written plan is the worst of both worlds (too late to pivot direction, too abstract for execution detail).

Also **removed `claude_only` and `codex_only`** from `roundtable_mode` — single-model roundtable defeats the cross-model blindspot defense that motivates having roundtable at all (style mode collapse). Dispatch failure on either side is now `BLOCKED_*` rather than silent degradation.

State file gains `plan_round_state_paths[]` and `implementation_plan_post_roundtable_sha256`.

---

## 2026-05-26 (fifth pass) — v0.1.3: implement third-pass design + split into longtaskPlan / longtaskCode

Two changes shipped together:

### A. v0.1.3 prompt implementation (closes the gap left by v0.1.2)

- **New prompts**: `prompts/plan-roundtable.md`, `prompts/plan-round-state.md`, `prompts/plan-consensus-editor.md` — mirror the spec-stage trio with plan-stage question focus (phase decomposition sanity, verifier observability, scope hygiene, cross-phase deps, REQ-* coverage, risk surface per phase) and an **in-place plan rewrite** contract for the consensus editor (preserves frontmatter sha lineage; emits both pre- and post-roundtable SHA-256).
- **Schema migration**: `prompts/spec-classifier.md` output schema replaces the single `discussion_rounds ∈ {1,3,5}` field with `tier_label ∈ {"0+1","1+1","2+1","3+2"}` + `spec_rounds ∈ {0,1,2,3}` + `plan_rounds ∈ {1,2}` + a `pre_vetted: {is_pre_vetted, reason}` object for 0+1 evidence.
- **Classifier rules**: tier selection precedence is now (1) pre-vetted check → 0+1, (2) high-risk → 3+2 + force `dual`, (3) medium-risk → 2+1, (4) default → 1+1. `claude_only` / `codex_only` are not emitted.
- **Roundtable prompt sync**: `prompts/spec-roundtable.md` retired `discussion_rounds` references and the `claude_only` / `codex_only` lines from its HYBRID ROUTING NOTE.
- **Orchestrator checklist**: `prompts/claude-orchestrator.md` Step 1 validates the new schema; Step 2 is now `Spec-roundtable (skippable only at 0+1 tier)` with explicit `spec_rounds == 0` handling; **new Step 4b** "Plan Roundtable (ALWAYS RUN, plan_rounds ≥ 1)" inserted between plan-writer and plan-integrity-review with the in-place rewrite + dual-SHA-256 contract.

### B. Skill split: `/longtaskPlan` (Steps 0-5) + `/longtaskCode` (Steps 6-9)

Two new sibling skills, both **doc-only wrappers** that re-use the parent `longtask`'s prompts / schemas / wrapper by absolute path — no duplicated artifacts.

- **`~/.claude/skills/longtaskPlan/SKILL.md`** — runs preflight → classify → spec-roundtable → codex sanity → plan-writer → plan-roundtable → plan-integrity, stops at Step 5 PASS. Writes a handoff manifest at `.longtask/state/{spec}/plan-only-handoff.json` for `/longtaskCode` to consume. Mode in state: `claude-hybrid-plan-only`.
- **`~/.claude/skills/longtaskCode/SKILL.md`** — accepts either the handoff manifest from `/longtaskPlan` OR a plan path directly (auto-runs plan-integrity-review inline at Step 6 startup when no prior gate is recorded). Runs per-phase loop → final E2E2 → final-alignment-review → optional ship. Mode in state: `claude-hybrid` (resumed from plan-only) or `claude-hybrid-code-only` (direct invocation).
- **`/longtask <spec>` ≡ `/longtaskPlan <spec>` then `/longtaskCode <plan>`** in one session, no user-visible handoff. Use the sub-skills when you want a checkpoint between planning and execution (human review of plan; cross-session/cross-machine handoff; iterate on plan without burning per-phase cycles).

Net effect: design (v0.1.2) and implementation (v0.1.3) are now consistent; the orchestrator no longer treats Step 4b as a no-op; users can pick the granularity of invocation per task.

---

## 2026-05-26 (fourth pass) — SKILL.md slim-down

Cut SKILL.md from ~620 to ~380 lines without losing operational content:

- **Description** compressed from ~12 lines of dense architecture summary to 2 sentences (every skill-list scan was loading the long version into agents' context).
- **"Quality bar" + 4 production-grade principles preamble** moved to `README.md` (aspirational, didn't drive orchestrator behavior).
- **Changelog** split into this file (`CHANGELOG.md`) instead of accreting inside SKILL.md.
- **State schema JSON example** moved to `schemas/state-example.json`; SKILL.md keeps a field table + brief inline example.

No semantic changes — purely a docs reorganization to keep the orchestrator's per-invocation context lean.
