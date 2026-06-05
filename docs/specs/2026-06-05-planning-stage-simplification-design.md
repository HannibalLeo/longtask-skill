# Planning-Stage Simplification — Design

- **Date**: 2026-06-05
- **Status**: approved (pending implementation)
- **Scope**: `claude-longtask` (Steps 0–9) and `claude-longtask-plan` (Steps 0–5). The plan-stage logic is shared; changing `claude-longtask-plan` implies the same change in `claude-longtask`.
- **Out of scope**: `claude-longtask-code` (execution), `codex-longtask*` (Codex path), the manifest-bridge and review skills.

## Motivation

The planning stage is over-engineered. A full `/longtask:longtaskPlan` run routinely takes 2–3 hours because both the spec stage (Step 2) and the plan stage (Step 4b) run a heavyweight cross-pair roundtable (codex × lenses → codex mid-summary → claude × lenses → claude end-summary), optionally for multiple rounds, each capped by an opus terminal review.

Two goals:
1. **Cut the weight.** Cross-model review is valuable, but the current roundtable is too heavy for ordinary tasks.
2. **Stop reinventing the wheel.** gstack already ships `autoplan` — an auto-review pipeline that runs CEO / engineering / design / DevEx roles, each as **both a Claude subagent AND a Codex voice** (built-in cross-model), auto-decides most points, and only surfaces taste decisions / codex disagreements to the user at a final approval gate. It also degrades gracefully to Claude-only when Codex is unavailable. This is exactly the "Claude-side interactive + Codex-side automated" shape we want.

## Key decisions (locked)

1. **Spec stage: minimal.** Merge old Step 2 (spec roundtable) and Step 3 (codex spec sanity) into a single automated Codex sanity check. No multi-role roundtable at the spec stage.
2. **Plan stage: delegate to `autoplan`.** Replace the Step 4b cross-pair plan roundtable with a call to the gstack `autoplan` skill (multi-role + codex cross-voice + user approval gate).
3. **Roundtable / `cross_rounds` mechanism is removed** from the planning stage. The 1/2/3 round-count policy no longer exists — the user's "default to one round" concern is resolved more completely by deleting the loop entirely.
4. **Model tier**: every remaining opus call point standardizes to **`opus 4.8 xhigh`** (version bumped 4.7→4.8; effort `xhigh`, since "extra" is not a valid Claude effort value — valid values are low/medium/high/xhigh/max).
5. **Final-alignment (Step 8) unchanged** — already mandatory dual (Claude + Codex), lives in `claude-longtask-code`, not touched here.
6. **Codex cross-check fault tolerance**: keep `autoplan`'s built-in graceful degradation (Codex unavailable → Claude-only, continue). Not made hard-fail.

## New planning flow

| Step | Old | New |
|------|-----|-----|
| 0 | Preflight | **Preflight** (unchanged) |
| 1 | Classifier (incl. cross_rounds 1/2/3) | **Classifier** — keep input-shape / `pre_vetted` detection; **drop cross_rounds computation** |
| 2 + 3 | Spec roundtable (multi-round) + Codex spec sanity | **Step 2 = Codex spec sanity (merged)** — one `codex exec` pass: omissions / contradictions / hallucinations / source-spec consistency → `CLEAN` \| `NEEDS_REVISION`. No roundtable. |
| 4 | Plan-writer | **Step 3 = Plan-writer** (unchanged) |
| 4b | Plan roundtable (cross-pair, always) | **Step 4 = Plan review via `autoplan`** (multi-role + codex cross-voice + user approval gate) |
| 5 | Plan-integrity | **Step 5 = Plan-integrity** (kept; complements autoplan — "does the plan cover every REQ", not "is the plan good") |

**"Unless Codex demands a rewrite, run once"**: Step 2's sanity returns `CLEAN` → proceed straight to plan-writer; returns `NEEDS_REVISION` → exactly one spec revision pass (orchestrator applies Codex's notes), then proceed. `pre_vetted` inputs may skip Step 2 entirely.

## `autoplan` integration (Step 4)

- Called from the **main session** (autoplan is interactive — it must reach the user for the approval gate; it cannot run inside an isolated subagent).
- Input: the plan file produced by Step 3 (plan-writer).
- autoplan writes its verdict into the plan file (`## GSTACK REVIEW REPORT`) per its own contract; the orchestrator reads the plan back and records a pointer in longtask state.
- Codex cross-voice and the role set (CEO / eng / design / DevEx) are managed by autoplan internally — longtask no longer maintains its own lens prompts / codex mid-summaries for the plan stage.
- autoplan's preamble (gstack update check, session bookkeeping) will run on invocation — expected, non-fatal noise.

## File-level change plan

**Remove roundtable references (spec stage):**
- `claude/prompts/spec-roundtable.md`, `spec-round-state.md`, `spec-codex-mid-summary.md`, `spec-consensus-editor.md` — deprecate/remove; no longer referenced.

**Keep & promote:**
- `claude/prompts/spec-codex-sanity.md` — becomes the body of the new merged Step 2.

**Remove roundtable references (plan stage):**
- `claude/prompts/plan-roundtable.md`, `plan-round-state.md`, `plan-codex-mid-summary.md`, `plan-consensus-editor.md`, `cross-rounds-final-review.md` — deprecate/remove; superseded by autoplan.

**Rewrite:**
- `claude/prompts/claude-orchestrator.md` — remove roundtable phases; Step 2 = sanity (merged); Step 4 = invoke autoplan; clean up cross_round wiring.
- `claude/prompts/spec-classifier.md` — drop cross_rounds; keep input-shape / pre_vetted.
- `skills/claude-longtask/SKILL.md` and `skills/claude-longtask-plan/SKILL.md` — flow tables, step descriptions, subagent-count formulas, model tiers, state-field lists.
- `shared/schemas/state-example.json` — remove `*_cross_round_*` / `cross_rounds` fields; add autoplan-report pointer + spec-sanity fields.

**Model tier bump (after the above, on surviving opus call points only):**
- `opus 4.7 xhigh` / `4.7 max` → `opus 4.8 xhigh` across SKILL.md + remaining prompts (orchestrator, plan-writer, plan-integrity-review). Codex's own `xhigh` (OpenAI naming) is left unchanged.

## Risks & coupling

- **Dangling references**: removing roundtable means scrubbing every `cross_round` mention across 11 prompts + orchestrator + state schema. Must verify zero dangling references after.
- **State / handoff fields**: `plan-only-handoff.json` and state carry `*_cross_rounds_*` fields; downstream (`longtaskCode`, manifest-bridge) read them. Replace with safe defaults rather than leaving readers expecting missing keys.
- **Subagent-count formula** (`8×cross_rounds+2` etc.) in SKILL.md becomes obsolete — replace with the new shape (1 sanity call + 1 autoplan invocation).
- **autoplan availability**: requires gstack installed globally (it is). If gstack/autoplan is missing, Step 4 must fail with a clear message, not silently skip review.

## Rollout

1. Edit on the source repo (`marketplace/`, current HEAD).
2. Sync the whole plugin into the active cache (`~/.claude/plugins/cache/longtask-skill/claude-longtask-harness/0.4.0/`) so it takes effect in the annotation-AI project (this also lifts the cache from its older snapshot to current + this change).
3. `git commit` to the longtask repo.
