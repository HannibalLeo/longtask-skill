# Review Fail Report (R13)

Generate a bounded fail report from review artifacts.
Do not include speculative implementation advice.

Required fields:
- `failed_stage` (`R1`-`R13`)
- `stage_status` (`REVIEW_FAIL`)
- `failed_requirement_ids[]` (when known)
- `artifact_paths[]`
- `preserved_phase_commits[]`
- recovery commands:
  - `resume_codex_command`
  - `plan_repair_command`
  - `safe_claude_command`
  - `review_retry_command`
  - `audited_human_override_command` (soft `safe_recommended` only)

Output JSON:
```json
{
  "failed_stage": "R1",
  "stage_status": "REVIEW_FAIL",
  "failed_requirement_ids": [],
  "artifact_paths": [],
  "preserved_phase_commits": [],
  "resume_codex_command": "",
  "plan_repair_command": "",
  "safe_claude_command": "",
  "review_retry_command": "",
  "audited_human_override_command": "",
  "reason": "short failure summary"
}
```
