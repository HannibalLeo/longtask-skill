# Handoff Manifest Contract

Canonical schema: `shared/schemas/handoff-manifest.schema.json`

This spec defines the cross-harness handoff contract produced by
`claude-longtask-plan` and consumed by `codex-longtask-code` plus
`claude-longtask-review`.

## Required contract areas

1. Identity:
   - `manifest_version`
   - `from_skill` (`claude-longtask-plan`)
   - `produced_at`
   - `longtask_version`
   - `session_id`
2. Source lineage:
   - `source_lineage.source_spec_path`
   - `source_lineage.source_spec_sha256`
   - optional enhanced lineage when present
3. Implementation plan contract:
   - `implementation_plan.input_shape`
   - `implementation_plan.implementation_plan_path`
   - `implementation_plan.implementation_plan_sha256`
   - `implementation_plan.plan_integrity_review_path`
   - `implementation_plan.alignment_matrix_path`
   - `implementation_plan.state_path`
4. Authoritative routing:
   - `workflow_routing.routing_decision` enum:
     - `fast_allowed`
     - `safe_recommended`
     - `safe_required`
     - `blocked_until_replan`
   - `workflow_routing.blocking_reason_codes[]`
   - `workflow_routing.advisory_reason_codes[]`
5. Repo/path safety:
   - `repo_path_safety.repo_root`
   - `repo_path_safety.allowed_write_roots[]`
   - `repo_path_safety.path_escape_rejected` must be `true`
   - git-base safety fields
6. Codex compatibility:
   - `codex_handoff_compatible`
   - `codex_handoff_compatibility_proof` with evidence and violations
7. Artifacts:
   - `artifacts.final_verify_cmd`
   - `artifacts.final_e2e2_cmd`
   - `artifacts.final_report_path`
8. NEXT and recovery commands:
   - `recommended_executor`
   - `next_step_hint`
   - `next_commands.next_command`
   - `next_commands.safe_path_recovery_command`
   - `next_commands.plan_repair_command`
   - `next_commands.review_retry_command`
   - `next_commands.human_override_instructions`

## Routing invariants

- `workflow_routing.routing_decision` is the single authoritative routing answer.
- `recommended_executor` and NEXT/recovery commands must be derived from
  `routing_decision`.
- `safe_required` and `blocked_until_replan` cannot route to
  `codex-longtask-code`.
- No runtime bypass for `safe_required` or `blocked_until_replan`.

## Override policy

- Only `safe_recommended` can carry `override_record`.
- `override_record` must include:
  - `actor`
  - `original_routing_decision` (must be `safe_recommended`)
  - `reason`
  - `timestamp`
  - `affected_phase_ids[]`
  - `preserved_blocking_checks[]`

Hard-safety cases are non-overridable, including schema invalid, path escape,
sha drift, git-base mismatch, missing artifacts, runtime mutation, and blocked
routing decisions.

## Enum authority

Routing reason-code vocabulary is closed in the schema and must be used exactly.
Blocked enums are authoritative via `common-enums.schema.json`, including:

- `BLOCKED_CODEX_WRAPPER_FAILURE`
- `BLOCKED_HARNESS_BACKGROUND`

## Compatibility proof minimum

`codex_handoff_compatibility_proof` must prove:

- no `/skill` dispatch in phase bodies
- no Agent/Skill tool dependency in phase bodies
- no browser/screenshot/web work inside implementation phases
- no subjective LLM-only DoD
- no interactive input requirements
- no cross-phase coordination dependency
- no final E2E2 inside a phase

When incompatible, set `codex_handoff_compatible: false` and provide explicit
`non_codex_executable_phases[]`, `violation_codes[]`, and `required_repairs[]`.
