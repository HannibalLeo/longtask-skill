# Changelog

## 0.4.0 - 2026-05-26 (claude-end roundtable rewrite)

### Breaking changes (claude-end)

The roundtable subsystem on the claude-end (skills `claude-longtask`,
`claude-longtask-plan`) has been restructured. The codex-end (`codex-longtask`,
`codex-longtask-code`) is unchanged in 0.4.0 and remains on the 0.3.x
single-model roundtable shape; its top-level SKILL.md gains a one-line note
that it is not aligned with the claude-end v0.4 cross-rounds design.

The user-visible motivation: a /longtask:longtask run at the high tier was
spending hours dispatching subagents in `N_lens × 2_models × N_rounds`
combinations, where many of those calls produced same-distribution restatements
of earlier rounds. v0.4 collapses the round axis from `{0+1, 1+1, 2+1, 3+2}`
(four spec×plan combinations) to `{1, 2, 3}` (a single cross-rounds integer
applied symmetrically to both stages), and replaces the
`hybrid` / `dual` mode knob with a fixed cross-pair shape where every lens
runs both codex and claude per round by construction.

#### Output contract changes

- `spec-classifier` removed: `tier_label`, `spec_rounds`, `plan_rounds`,
  `suggested_roundtable_mode`, `discussion_rounds`, `discussion_required`.
- `spec-classifier` added: `cross_rounds` (one of `1`, `2`, `3`).
- Frontmatter removed: `roundtable_mode` (hybrid/dual no longer exists).
- Frontmatter added (optional override): `cross_rounds`.
- State schema renames: `spec_round_state_paths[]` →
  `spec_cross_round_state_paths[]`; `plan_round_state_paths[]` →
  `plan_cross_round_state_paths[]`;
  `implementation_plan_post_roundtable_sha256` →
  `implementation_plan_post_cross_rounds_sha256`; `hybrid_lens_assignments` →
  `hybrid_gate_assignments` (the assignments table is now for
  `plan-integrity-review` / `decision-review` / `final-alignment-review`
  only — lens assignments are deterministic by construction in v0.4).
- State schema added: `spec_cross_round_codex_mid_summary_paths[]`,
  `plan_cross_round_codex_mid_summary_paths[]`,
  `spec_consensus_editor_path`, `plan_consensus_editor_path`,
  `spec_cross_rounds_final_review_path`, `plan_cross_rounds_final_review_path`,
  `spec_cross_rounds_final_review_verdict`, `plan_cross_rounds_final_review_verdict`,
  `spec_cross_rounds_residual_risks[]`, `plan_cross_rounds_residual_risks[]`,
  `spec_roundtable_skipped_reason`.
- State `mode` enum: `claude-hybrid` → `claude-cross-rounds`;
  `claude-hybrid-plan-only` → `claude-cross-rounds-plan-only`;
  `claude-hybrid-code-only` → `claude-cross-rounds-code-only`.
- Handoff manifest example field: `plan_post_roundtable_sha256` →
  `plan_post_cross_rounds_sha256`.

#### Roundtable shape changes

- Each roundtable round is now a four-phase cross-pair:
  1. parallel codex × all selected lenses
  2. one codex xhigh mid-round summary
  3. parallel claude × all selected lenses (reads codex phase 1 + mid-summary)
  4. one Claude opus end-round summary (writes round-state)
- Lenses are no longer model-bound. Every selected lens runs both codex and
  claude per round.
- `cross_rounds: 1 | 2 | 3` applies to both spec-roundtable and
  plan-roundtable. `pre_vetted.is_pre_vetted == true` skips spec-roundtable
  entirely; plan-roundtable always runs (non-skippable).
- Consensus editors (`spec-consensus-editor`, `plan-consensus-editor`) are now
  single Claude opus invocations. The previous "Claude primary + Codex
  secondary" pattern was retired because every cross-round itself already
  digests cross-model signal.
- New terminal gate per stage: `cross-rounds-final-review` runs as
  Claude opus 4.7 xhigh once per stage, immediately after the consensus editor,
  with three verdicts: `PASS_CLEAN`, `PASS_WITH_RESIDUAL_RISKS` (carries
  blindspot list forward to downstream gates), `NEEDS_REVISION` (loops once
  to consensus editor with explicit `needs_revision_reasons[]`, then BLOCKED).

#### Subagent count comparison (default 5 lenses)

| cross_rounds | Per-stage dispatches | (legacy reference) |
|---|---|---|
| 1 | 14 | (legacy 0+1 hybrid: ~5; legacy 0+1 dual: ~10) |
| 2 | 26 | (legacy 2+1 hybrid: ~15; legacy 2+1 dual: ~30) |
| 3 | 38 | (legacy 3+2 hybrid: ~25; legacy 3+2 dual: ~50) |

Per-stage formula: `12 × cross_rounds + 2`. The 2 trailing dispatches are
the consensus editor and the cross-rounds-final-review. Both stages combined
(when spec stage runs) give `2 × (12 × cross_rounds + 2)`.

The win over the legacy shape is in heterogeneity per round (no longer
"dual" vs "hybrid" — every round is cross-model by construction) and in
sequencing (the claude phase of each round sees the codex phase output for
the same round, which the legacy parallel-dual shape did not provide).

#### New prompts

- `claude/prompts/spec-codex-mid-summary.md`
- `claude/prompts/plan-codex-mid-summary.md`
- `claude/prompts/cross-rounds-final-review.md`

#### Rewritten prompts

- `claude/prompts/spec-classifier.md`
- `claude/prompts/spec-roundtable.md`
- `claude/prompts/plan-roundtable.md`
- `claude/prompts/spec-round-state.md`
- `claude/prompts/plan-round-state.md`
- `claude/prompts/spec-consensus-editor.md`
- `claude/prompts/plan-consensus-editor.md`
- `claude/prompts/claude-orchestrator.md` (Step 2 and Step 4b sections)

#### Updated docs

- `skills/claude-longtask/SKILL.md` (length policy, role matrix, pipeline)
- `skills/claude-longtask-plan/SKILL.md` (subset description, handoff manifest)
- `skills/claude-longtask-code/SKILL.md` (mode strings, sha field rename)
- `shared/schemas/state-example.json`

### New skill: `claude-longtask-manifest-bridge`

Fills the 0.3.0 dual-harness handoff gap. Reads the flat
`plan-only-handoff.json` produced by `claude-longtask-plan`, scans every phase
for the 11 codex compatibility violations (including the new
`VIOLATION_SSH_OR_NETWORK_EGRESS_IN_PHASE`), and writes a schema-conformant
`handoff-manifest.json` with an honest `routing_decision`
(`fast_allowed` / `safe_required` / `blocked_until_replan`) and
`recommended_executor`.

Adds:
- `skills/claude-longtask-manifest-bridge/SKILL.md`
- `claude/prompts/handoff-manifest-writer.md`

Existing inputs / outputs are unchanged. Both `claude-longtask-code` (flat
handoff) and `codex-longtask-code` (schema-conformant manifest) work the same
way they did before; the bridge is invoked optionally between the plan stage
and either executor when the schema-conformant form is needed.

### Schema fixes (handoff-manifest.schema.json)

Two pre-existing bugs in `shared/schemas/handoff-manifest.schema.json`
discovered while building the manifest bridge:

1. `repo_head_sha_at_plan` and `base_sha_before_phases_expected` were
   incorrectly constrained to sha256 (`^[a-f0-9]{64}$`), rejecting standard
   git sha1 (40-char) commit hashes. Added `git_sha` $def that accepts
   either sha1 (40 chars) or sha256 (64 chars); migrated both fields.
2. `non_codex_executable_phases.items` and `affected_phase_ids.items`
   pattern was `^P[0-9]+$`, rejecting valid sub-phase IDs like P1a / P3c.
   Relaxed to `^P[0-9]+[a-z]?$`.

Added violation code:
- `VIOLATION_SSH_OR_NETWORK_EGRESS_IN_PHASE` — phase verify_cmd contains
  `ssh `, `scp`, `rsync` to remote, `nc <hostname>`, non-localhost `curl`,
  `wget`, etc. Codex CLI default sandbox `workspace-write` disables DNS /
  network / SSH, so any such command in a phase verifier will fail in codex.

### Codex-end status

`codex-longtask` and `codex-longtask-code` continue to use the 0.3.x
single-model roundtable shape. The codex-end has no claude-agent dispatch
mechanism so it cannot run the v0.4 cross-pair design; aligning the two would
require an Anthropic API bridge inside codex which is out of scope for 0.4.0.
A short pointer paragraph has been added to `codex-longtask/SKILL.md` so codex
CLI users are aware the two harnesses now diverge on roundtable semantics.

## 0.3.0 - 2026-05-26

- Restructured into dual-harness canonical layout with six skills.
- Added Codex install/uninstall scripts with conservative ownership checks:
  - `scripts/install-codex.sh`
  - `scripts/uninstall-codex.sh`
- Added stale-reference scanning and report output:
  - `scripts/scan-stale-references.sh`
  - `.longtask/reports/2026-05-26-longtask-dual-harness-restructure-design/stale-references.json`
- Added workflow and migration docs:
  - `docs/workflows.md`
  - `docs/migration-from-v0.2.md`
- Added temp-home install safety fixtures in `fixtures/install-temp-home-safety/`.
