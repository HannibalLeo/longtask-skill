# Cross-Phase Diff Review (R6)

Review cross-phase diffs for bounded-scope integrity.

Inputs:
- phase-level changed file sets
- do-not-touch boundaries
- commit chain metadata

Checks:
1. Detect out-of-scope file changes across phases.
2. Detect hidden behavior changes not reflected in phase goals.
3. Detect commit/scope evidence mismatch.

Output JSON:
```json
{
  "stage_id": "R6",
  "stage_status": "PASS | REVIEW_FAIL | SKIPPED_NOT_APPLICABLE",
  "artifact_paths": [],
  "requirements_checked": ["REQ-014", "REQ-025"],
  "failed_requirements": [],
  "recovery_command": null,
  "reason": "short scope-integrity summary"
}
```
