---
name: codex-longtask-code
description: Canonical Codex routing entrypoint for Step6 execution handoff.
---

# codex-longtask-code

`codex-longtask-code` owns Step 6 only. It consumes a validated handoff manifest
and executes bounded per-phase implementation plus verification loops.

## Scope Boundary

Allowed:

1. Step 6 startup gating.
2. Worker/verifier/retry orchestration for each implementation phase.
3. Scope gate and verifier schema gate.
4. Commit-on-PASS and partial-pass resume bookkeeping.
5. Writing `.longtask/state/{spec_basename}/codex-code-exit.json`.

Forbidden:

1. Final verification (`final_verify_cmd`).
2. Final E2E2 or screenshot runs.
3. Push, PR, publish, deploy.
4. Global install/uninstall mutation for Codex or Claude.
5. Runtime bypass flags that disable required safety gates.

## Startup Gates (Before Any Mutation)

1. Validate handoff manifest schema from `shared/schemas/handoff-manifest.schema.json`.
2. Validate routing consistency:
   - allow only `fast_allowed`
   - reject `safe_required` and `blocked_until_replan`
3. Validate `codex_handoff_compatible == true`.
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

`PARTIAL_PASS` must preserve already committed PASS phases and default resume
from the first non-PASS phase.
