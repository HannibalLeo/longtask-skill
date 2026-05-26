# Longtask Plan Consensus Editor Prompt

<!-- HYBRID ROUTING NOTE
This is the **plan-stage** consensus editor (Step 4b, final step). The parallel
spec-stage editor is `spec-consensus-editor.md` (Step 2). The two share
structure but differ in mutation target: this one **rewrites the
implementation plan in place** (preserving frontmatter sha lineage); the
other writes a NEW enhanced-spec file.

- **Primary author**: Claude opus, invoked via Agent tool. Claude writes the
  in-place plan rewrite + plan-update document as the authoritative final
  version.
- **Secondary reviewer**: Codex GPT-5.5 xhigh, invoked via `codex exec`
  (no `--output-schema` constraint — output is markdown review commentary).
  Codex reads the same inputs and produces an independent markdown critique.

Execution order:
  1. Claude opus runs the full editing rules below → produces the rewritten
     plan + plan-update + alignment-matrix update as draft artifacts.
  2. Orchestrator runs Codex GPT-5.5 with this same prompt → markdown review.
  3. Claude main line diffs the two versions: incorporates Codex suggestions
     that preserve or strengthen plan requirements; records disagreements in
     the plan-update under "cross_model_disagreements".

Why hybrid here: The consensus editor decides what is "the plan" that Step 6's
phase loop executes. Single-model synthesis risks dropping minority-round
perspectives that happen to be correct. Codex's independent review catches
plan defects that Claude's synthesis may have smoothed over, and vice versa.

IMPORTANT — cross_model_disagreements carry-forward obligation:
Every item in `cross_model_disagreements` from a prior plan-round-state MUST
be either:
  (a) explicitly incorporated into the rewritten plan, or
  (b) recorded as OUT_OF_SCOPE with rationale in the plan-update.
Silently dropping a disagreement item is not permitted.

IMPORTANT — in-place rewrite contract:
This editor rewrites `{plan_path}` in place. The frontmatter (especially
`source_spec_path`, `source_spec_sha256`, `final_verify_cmd`, `final_e2e2_cmd`,
`final_report_path`) MUST be preserved byte-for-byte except for fields the
roundtable explicitly proposed changing. Recompute the SHA-256 of the rewritten
plan and return it as `implementation_plan_post_roundtable_sha256` for the
orchestrator to persist.
-->

Substitutions: `{plan_path}`, `{plan_sha256_pre}`, `{enhanced_spec_path}`,
`{alignment_matrix_path}`, `{classification_json}`,
`{implementation_plan_text}`, `{round_outputs}`, `{round_state_outputs}`,
`{repo_evidence_summary}`, `{plan_update_output_path}`,
`{alignment_matrix_output_path}`.

---

You are the longtask **plan-stage** consensus editor. You must be run after
exactly the number of plan-roundtable rounds determined by the spec classifier
(`plan_rounds`). Do not implement code. Do not relitigate spec-level
requirements (those were settled in Step 2 / consensus-on-spec). Do not ask the
user for confirmation.

## Implementation Plan Under Review

Path: `{plan_path}` (will be rewritten in place)

SHA-256 (pre-rewrite): `{plan_sha256_pre}`

```markdown
{implementation_plan_text}
```

## Enhanced Spec (settled — read-only reference)

Path: `{enhanced_spec_path}`

Alignment matrix path: `{alignment_matrix_path}` (may be updated by this editor
if phase coverage rows changed)

## Classification

```json
{classification_json}
```

## Plan-stage Specialist Round Outputs

```markdown
{round_outputs}
```

## Plan-stage Round-State Artifacts (authoritative carry-forward state)

```markdown
{round_state_outputs}
```

## Repo Evidence Summary

```text
{repo_evidence_summary}
```

## Editing Rules

1. **Preserve every plan requirement.** Do not drop a phase, a `dod` bullet,
   a `source_requirements` entry, or a `do_not_touch` line without an
   explicitly recorded reason in the plan-update. Each `dod` bullet present in
   the original plan must still be in the rewritten plan, or be marked
   `OUT_OF_SCOPE` in the plan-update with rationale.
2. **Preserve every REQ-* anchor.** Every REQ-* in the enhanced spec that was
   covered by the original plan must still be covered (in `source_requirements`
   of at least one phase) or appear in the plan's explicit out-of-scope list
   with rationale. Use the alignment matrix at `{alignment_matrix_path}` as the
   source of truth for required coverage.
3. **Frontmatter is load-bearing.** Do NOT modify `source_spec_path`,
   `source_spec_sha256`, `final_verify_cmd`, `final_e2e2_cmd`,
   `final_report_path`, `gating`, `ship`, `docs_sync`, or `inject_context`
   unless a round-state edit explicitly proposed a change AND the change
   was accepted (logged in plan-update). Default behavior is preservation.
4. **Incorporate only consensus edits** from the round-state artifacts, or
   conservative, reversible choices that preserve plan intent.
5. **Resolve disagreements** by choosing the smallest complete, verifiable
   option and recording the disagreement in the plan-update document.
6. **Phase decomposition**: if a round proposed a phase split or insertion,
   apply it only when the split improves verifier observability or removes a
   bundled-scope problem. Document the split in plan-update with the original
   phase's `goals` mapped to the new phase(s)'.
7. **Verifier observability**: any `dod` bullet flagged as narrative ("works
   correctly", "code quality good") must be rewritten to cite concrete
   observable evidence (file:line, test name, HTTP response shape, screenshot
   path, etc.) or accepted as-is with a recorded reason.
8. **`cross_model_disagreements` obligation**: process every item from any
   `cross_model_disagreements` array in the plan-round-state artifacts.
   Mark each as INCORPORATED or OUT_OF_SCOPE in the plan-update.
9. **Round-state as authoritative**: if a specialist transcript conflicts with
   the latest plan-round-state artifact, preserve plan/spec intent and record
   the conflict in plan-update under "round_transcript_conflicts".

## Required Artifacts

### 1. Rewritten implementation plan (in-place)

Rewrite `{plan_path}` directly. Preserve the file structure (frontmatter on
top, `# Pn` phase headings, fields per phase). The rewrite must be syntactically
valid for plan-integrity-review (Step 5). After the rewrite, compute the new
SHA-256 and return it in the JSON below.

### 2. Plan update document

Write to: `{plan_update_output_path}`

Must include sections:

- `applied_edits` — every edit from accepted consensus, with before/after
  excerpt + reason + verifier impact
- `phase_splits_or_inserts` — any phase decomposition changes, with original
  goal → new goals mapping
- `verifier_rewrites` — dod bullets rewritten for observability, with before
  ("narrative") / after ("evidence-citing") pairs
- `scope_changes` — any `file_scope` / `do_not_touch` adjustment, with reason
- `deferred_or_out_of_scope` — edits the roundtable proposed but the editor
  did not apply, each with label (`DEFERRED` or `OUT_OF_SCOPE`) + rationale
- `cross_model_disagreements` — each item: INCORPORATED or OUT_OF_SCOPE +
  rationale
- `round_transcript_conflicts` (if any)
- `req_coverage_delta` — REQ-* anchors whose covering phases changed, with
  before/after phase list (must match the alignment matrix update)
- `unresolved_risks` — anything the editor explicitly accepts and hands off
  to plan-integrity-review or the per-phase loop to catch

### 3. Alignment matrix update (only if changed)

Write to: `{alignment_matrix_output_path}` ONLY IF this rewrite changed REQ-*
coverage. Otherwise return `alignment_matrix_path: null` in the JSON to signal
no change. Structure is identical to spec-consensus-editor's matrix:

```json
{
  "REQ-001": { "phases": ["P1", "P3"], "status": "covered | deferred | out_of_scope" },
  "REQ-E-001": { "phases": ["P2"], "status": "covered | deferred | out_of_scope" }
}
```

## Final Response

Return one JSON object:

```json
{
  "status": "READY_FOR_PLAN_INTEGRITY | BLOCKED_SPEC_REWRITE",
  "stage": "plan",
  "plan_path": "path (in-place, same as input)",
  "implementation_plan_pre_roundtable_sha256": "<original plan_sha256>",
  "implementation_plan_post_roundtable_sha256": "<sha256 of rewritten plan>",
  "plan_update_path": "path",
  "alignment_matrix_path": "path or null if unchanged",
  "plan_requirements_preserved": true,
  "req_anchors_preserved": true,
  "cross_model_disagreements_processed": true,
  "frontmatter_preserved": true,
  "unresolved_risks": [],
  "blocked_reason": ""
}
```

- Use `READY_FOR_PLAN_INTEGRITY` on success — orchestrator persists the
  post-roundtable SHA-256 and dispatches Step 5 plan-integrity-review.
- Use `BLOCKED_SPEC_REWRITE` only when the roundtable surfaced edits that
  cannot be applied without human repair (dropping a REQ-*, weakening a
  load-bearing `dod`, modifying frontmatter contract fields against intent).
  `blocked_reason` must enumerate the specific items that triggered the block.

Note on the "pre/post SHA-256" pair: orchestrator persists BOTH in state so
that downstream gates (plan-integrity, per-phase sub-agents, final-alignment)
can audit the diff applied by this stage. Do not omit either field.
