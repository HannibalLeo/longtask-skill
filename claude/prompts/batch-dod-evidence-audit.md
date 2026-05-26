# Batch DoD Evidence Audit (R3)

Review DoD evidence only. Do not modify implementation.

Inputs:
- phase `dod` bullets from the plan
- verifier outputs
- command logs and referenced artifact paths

Checks:
1. Every DoD bullet has at least one mechanical evidence item.
2. Evidence path exists and corresponds to the claimed check.
3. DoD pass claims are not inferred from prose-only statements.

Output JSON:
```json
{
  "stage_id": "R3",
  "stage_status": "PASS | REVIEW_FAIL | SKIPPED_NOT_APPLICABLE",
  "artifact_paths": [],
  "requirements_checked": ["REQ-014", "REQ-018"],
  "failed_requirements": [],
  "recovery_command": null,
  "reason": "short evidence-based summary"
}
```
