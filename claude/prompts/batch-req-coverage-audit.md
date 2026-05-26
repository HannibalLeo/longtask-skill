# Batch Requirement Coverage Audit (R4)

Validate requirement coverage from artifacts. No coding.

Inputs:
- alignment matrix
- `source_requirements` per phase
- changed files and targeted diffs
- verifier outputs and final summaries

Checks:
1. Each requirement in scope is mapped to executed evidence.
2. Missing requirement coverage is reported with exact REQ IDs.
3. Requirement claims in Markdown are backed by JSON artifacts.

Output JSON:
```json
{
  "stage_id": "R4",
  "stage_status": "PASS | REVIEW_FAIL | SKIPPED_NOT_APPLICABLE",
  "artifact_paths": [],
  "requirements_checked": [],
  "failed_requirements": [],
  "recovery_command": null,
  "reason": "short coverage summary"
}
```
