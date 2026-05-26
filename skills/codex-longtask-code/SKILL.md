---
name: codex-longtask-code
description: Canonical Codex routing entrypoint for Step6 execution handoff. Accepts a schema-conformant handoff manifest, a flat plan-only-handoff.json produced by claude-longtask-plan, or a plan path directly — auto-promotes the latter two forms inline before phase execution.
---

# codex-longtask-code

`codex-longtask-code` owns Step 6 only. It consumes a validated handoff manifest
and executes bounded per-phase implementation plus verification loops.

## Input Contract (v0.4 — three accepted forms)

The user invokes this skill with ONE path argument. The startup procedure
detects which form the argument points at and proceeds accordingly.

### Form 1: Schema-conformant handoff manifest

```bash
codex-longtask-code .longtask/state/{spec_basename}/handoff-manifest.json
```

The file conforms to `shared/schemas/handoff-manifest.schema.json` (nested
`identity` / `source_lineage` / `implementation_plan` / `workflow_routing` /
`codex_handoff_compatible` / `repo_path_safety` / `artifacts` /
`next_commands`).

Detection rule: top-level JSON has a `manifest_version` field AND a
`workflow_routing` object.

### Form 2: Flat `plan-only-handoff.json` (claude-longtask-plan output)

```bash
codex-longtask-code .longtask/state/{spec_basename}/plan-only-handoff.json
```

The file is the flat handoff written by `claude-longtask-plan`. Detection
rule: top-level JSON has a `from_skill: "longtask:longtaskPlan"` field AND
flat top-level keys (`plan_path`, `plan_post_*_sha256`, `state_path`, etc.)
WITHOUT a `workflow_routing` object.

**Auto-promotion behavior** — before any phase mutation, internally promote
the flat handoff into a Form-1 manifest IN MEMORY (not persisted as a separate
file unless `--persist-manifest .longtask/state/{spec_basename}/handoff-manifest.json`
is passed):

1. Read the flat handoff's `plan_path`; resolve `implementation_plan_sha256`
   from `plan_post_cross_rounds_sha256` (v0.4) or
   `plan_post_roundtable_sha256` (v0.3 backward compat).
2. Resolve `source_spec_path`, `source_spec_sha256`, `enhanced_spec_path`,
   `enhanced_spec_sha256`, `alignment_matrix_path`, `state_path`,
   `plan_integrity_review_path` from the flat handoff's direct fields.
3. Read plan frontmatter for `final_verify_cmd`, `final_e2e2_cmd`,
   `final_report_path` → populate `artifacts{}`.
4. Compute `repo_head_sha_at_plan` = current `git rev-parse HEAD`;
   `base_sha_before_phases_expected` = same.
5. Aggregate `allowed_write_roots[]` from union of all phase `file_scope`
   prefix roots (truncate to first path segment).
6. Set `codex_handoff_compatible: true`, `routing_decision: "fast_allowed"`,
   `recommended_executor: "codex-longtask-code"` BY DEFAULT — Form 2 means
   "the user has chosen codex execution explicitly; trust them."
7. Set `execution_mode_hint: "codex-form-2-auto-promoted-from-plan-only-handoff"`.
8. Set `codex_handoff_compatibility_proof` with all four boolean guards
   `true` and `non_codex_executable_phases: []` (no scan; deferred to runtime
   failures).
9. Synthesize `next_commands` from the resolved paths.

If the resulting in-memory manifest fails schema validation (e.g., the plan
file's frontmatter is missing required v0.4 fields), STOP with
`BLOCKED_PLAN_REPAIR` and tell the user to run `/longtask:longtaskPlan --resume`
first.

### Form 3: Plan path directly

```bash
codex-longtask-code .longtask/plans/{spec_basename}-implementation-plan.md
```

The argument is the plan file path itself (no handoff at all). Detection
rule: argument ends in `.md` and parses as a Markdown file with a
`source_spec_path` frontmatter field.

**Auto-promotion behavior** — internally synthesize a Form-1 manifest:

1. Read plan frontmatter for `source_spec_path`, `source_spec_sha256`,
   `final_verify_cmd`, `final_e2e2_cmd`, `final_report_path`, plus per-phase
   blocks.
2. Compute `implementation_plan_sha256` = sha256 of plan file content.
3. Set `state_path` to `.longtask/state/{spec_basename}.json`; if this file
   exists, read existing classification / spec fields; if not, leave nullable
   fields empty.
4. `enhanced_spec_path` / `enhanced_spec_sha256` / `alignment_matrix_path` /
   `plan_integrity_review_path` resolve from common conventional paths under
   `.longtask/`; missing files → leave null.
5. Same defaults as Form 2 step 6-9 (codex_handoff_compatible: true, etc.).
6. `execution_mode_hint: "codex-form-3-no-prior-handoff"`.

Form 3 is the "I have a plan file, just run it through codex" minimum-effort
path. Form 2 is the "I went through claude-longtask-plan and want codex to
finish" canonical path. Form 1 is the "I have a manifest produced by a
bridge / external tool and want codex to consume it as-is" power-user path.

### Form auto-detection priority

If the argument is a `.json` file: try Form 1, fall back to Form 2.
If the argument is a `.md` file: Form 3.
Otherwise: BLOCKED with usage hint.

## Scope Boundary

Allowed:

1. Step 6 startup gating (including Form 2 / Form 3 auto-promotion).
2. Worker/verifier/retry orchestration for each implementation phase.
3. Scope gate and verifier schema gate.
4. Commit-on-PASS and partial-pass resume bookkeeping.
5. Writing `.longtask/state/{spec_basename}/codex-code-exit.json`.
6. (Form 2 / Form 3 only) writing
   `.longtask/state/{spec_basename}/handoff-manifest.json` IFF the user
   passed `--persist-manifest`. Default is in-memory only.

Forbidden:

1. Final verification (`final_verify_cmd`).
2. Final E2E2 or screenshot runs.
3. Push, PR, publish, deploy.
4. Global install/uninstall mutation for Codex or Claude.
5. Runtime bypass flags that disable required safety gates.

## Startup Gates (Before Any Mutation)

After form detection + auto-promotion (Form 2 / Form 3), validate the
in-memory or on-disk manifest:

1. Validate handoff manifest schema from `shared/schemas/handoff-manifest.schema.json`.
2. Validate routing consistency:
   - allow only `fast_allowed`
   - reject `safe_required` and `blocked_until_replan` (the latter means the
     plan itself has structural defects; the user must rerun
     `/longtask:longtaskPlan` first)
   - `safe_recommended` is acceptable only if the manifest has a valid
     `override_record`
3. Validate `codex_handoff_compatible == true`.

   **Form 2 / Form 3 note:** auto-promotion sets this to `true` by default
   (trust-the-user policy). If the plan has phases that codex cannot execute
   (Skill dispatch / Agent tool / browser harness mid-phase / SSH where the
   codex sandbox forbids network egress), the codex worker / verifier will
   fail at runtime AND the orchestrator should `BLOCKED` that phase with
   evidence in the verifier JSON. Codex sandbox SSH support is a user-side
   configuration (e.g., `--sandbox workspace-write -c sandbox.network_access=true`
   or `--dangerously-bypass-approvals-and-sandbox`); this skill assumes the
   user has configured it appropriately for the plan they passed.

4. Validate source/plan lineage hashes and manifest SHA fields.
5. Validate repo/path safety:
   - all paths stay under repository root
   - required artifacts exist
6. Validate git base constraints against the manifest expectations.
7. Validate exit-state target path:
   - must resolve under `.longtask/state/`
   - no parent traversal
8. Validate no prohibited side-effect command is configured for Step 6.

If any startup gate fails, stop with blocked status and write exit-state without
creating phase commits.

## Phase Loop

For each phase in manifest order:

1. Run worker prompt (`codex/prompts/worker.md`).
2. Compute changed paths via git and enforce:
   - inside `file_scope`
   - outside `do_not_touch`
3. Run verifier prompt (`codex/prompts/verifier.md`) with schema-bound output.
4. Validate verifier JSON:
   - schema-valid
   - `verify_cmd_exit == 0`
   - `dod_results` all pass
   - no reward-hacking signals
5. On FAIL, run retry prompt (`codex/prompts/retry-worker.md`) up to
   `max_retry_rounds`.
6. On PASS, create phase commit and append commit-chain evidence.

## Exit-State Contract

Always write `codex-code-exit.json` with:

1. `overall_status`: `ALL_PASS` | `PARTIAL_PASS` | `REVIEW_FAIL`
2. `first_blocked_phase` and `blocked_reason` when non-pass
3. per-phase result map (status, changed files, verifier paths, commits, retries)
4. `phase_commit_chain` and `preserved_phase_commits`
5. decisions, model requests, wrapper evidence
6. recovery commands:
   - `resume_default_command`
   - `safe_path_recovery_command`
   - `plan_repair_command`
   - `review_retry_command`
   - `human_override_instructions`
7. review handoff fields for `claude-longtask-review`
8. `form_used`: `1 | 2 | 3` — which input form the run started from
9. `auto_promotion_summary` (Form 2 / Form 3 only): which fields the
   auto-promoter synthesized, which were resolved from existing files,
   which were left empty.

`PARTIAL_PASS` must preserve already committed PASS phases and default resume
from the first non-PASS phase.
