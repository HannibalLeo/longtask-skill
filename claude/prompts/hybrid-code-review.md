# Hybrid Code Review (R5)

This is an artifact-constrained review pass, not an implementation task.

Inputs:
- targeted diffs for changed files
- decision records from Step 6
- verifier summaries and reward-hacking signals

Checks:
1. Validate change intent matches phase goals and requirements.
2. Surface hidden regressions, unsafe shortcuts, or scope drift.
3. Mark sensitive-risk triggers (security/auth/install/path/git/PII) for R7.

Output JSON:
```json
{
  "stage_id": "R5",
  "stage_status": "PASS | REVIEW_FAIL | SKIPPED_NOT_APPLICABLE",
  "artifact_paths": [],
  "requirements_checked": ["REQ-014", "REQ-017"],
  "failed_requirements": [],
  "recovery_command": null,
  "reason": "short code-risk summary",
  "sensitive_risk_triggers": []
}
```
