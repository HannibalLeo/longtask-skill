#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture)
      fixture="${2:-}"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$fixture" ]]; then
  echo "usage: $0 --fixture fixtures/review-precondition-and-evidence/valid-input" >&2
  exit 2
fi

python3 - "$repo_root" "$fixture" <<'PY'
import json
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
fixture_arg = sys.argv[2].strip().strip("/")
manifest = json.loads((repo / "fixtures/_runner/manifest.json").read_text(encoding="utf-8"))
group_cases = manifest.get("groups", {}).get("review-precondition-and-evidence", {}).get("cases", [])
errors: list[str] = []

if not group_cases:
    errors.append("review-precondition-and-evidence fixture group is empty")

fixture_matches = [p for p in group_cases if p.startswith(fixture_arg + "/")]
if not fixture_matches:
    errors.append(f"no review cases found under fixture prefix: {fixture_arg}")

required_case_markers = (
    "/valid-input/",
    "/missing-inputs/",
    "/missing-verifier/",
    "/commit-scope-defect/",
    "/absent-evidence/",
    "/final-report-overclaim/",
)
for marker in required_case_markers:
    if not any(marker in case_path for case_path in group_cases):
        errors.append(f"missing required review case marker: {marker}")

allowed_stage_status = {"PASS", "REVIEW_FAIL", "SKIPPED_NOT_APPLICABLE"}
allowed_blocked = {
    "BLOCKED_MANIFEST_SCHEMA_INVALID",
    "BLOCKED_MANIFEST_INCOMPATIBLE",
    "BLOCKED_INCOMPATIBLE_ROUTING",
    "BLOCKED_SPEC_DRIFT",
    "BLOCKED_PATH_ESCAPE",
    "BLOCKED_MISSING_ARTIFACT",
    "BLOCKED_GIT_BASE_MISMATCH",
    "BLOCKED_PLAN_INTEGRITY",
    "BLOCKED_SCOPE_VIOLATION",
    "BLOCKED_VERIFIER_SCHEMA_INVALID",
    "BLOCKED_COMMIT_CHAIN_INVALID",
    "BLOCKED_REVIEW_PRECONDITION",
    "BLOCKED_EVIDENCE_OVERCLAIM",
    "BLOCKED_RUNTIME_MUTATION",
    "BLOCKED_CODEX_WRAPPER_FAILURE",
    "BLOCKED_HARNESS_BACKGROUND",
}

stage_re = re.compile(r"^R([1-9]|1[0-3])$")

for case_path in group_cases:
    case = json.loads((repo / case_path).read_text(encoding="utf-8"))
    if case.get("case_type") != "contract_case":
        errors.append(f"{case_path}: case_type must be contract_case")
        continue
    actual = case.get("actual", {})
    expected = case.get("expected", {})
    stage_result = actual.get("stage_result")
    if not isinstance(stage_result, dict):
        errors.append(f"{case_path}: missing actual.stage_result")
        continue
    stage_id = stage_result.get("stage_id")
    stage_status = stage_result.get("stage_status")
    if not isinstance(stage_id, str) or not stage_re.match(stage_id):
        errors.append(f"{case_path}: invalid stage_id {stage_id!r}")
    if stage_status not in allowed_stage_status:
        errors.append(f"{case_path}: invalid stage_status {stage_status!r}")

    artifact_paths = stage_result.get("artifact_paths")
    if not isinstance(artifact_paths, list) or not artifact_paths:
        errors.append(f"{case_path}: stage_result.artifact_paths must be non-empty list")
    requirements_checked = stage_result.get("requirements_checked")
    if not isinstance(requirements_checked, list) or not requirements_checked:
        errors.append(f"{case_path}: stage_result.requirements_checked must be non-empty list")
    failed_requirements = stage_result.get("failed_requirements")
    if not isinstance(failed_requirements, list):
        errors.append(f"{case_path}: stage_result.failed_requirements must be a list")
    recovery_command = stage_result.get("recovery_command")
    if stage_status == "REVIEW_FAIL":
        if not failed_requirements:
            errors.append(f"{case_path}: REVIEW_FAIL must include failed requirements")
        if not isinstance(recovery_command, str) or not recovery_command.strip():
            errors.append(f"{case_path}: REVIEW_FAIL must include non-empty recovery command")

    blocked_reason = actual.get("blocked_reason")
    if blocked_reason is not None and blocked_reason not in allowed_blocked:
        errors.append(f"{case_path}: invalid blocked_reason {blocked_reason!r}")

    expected_stage = expected.get("stage_result", {})
    for field in ("stage_id", "stage_status", "failed_requirements", "recovery_command"):
        if field not in expected_stage:
            errors.append(f"{case_path}: expected.stage_result missing {field}")

    if "/commit-scope-defect/" in case_path:
        preserved = actual.get("preserved_phase_commits")
        if not isinstance(preserved, list) or not preserved:
            errors.append(f"{case_path}: commit-scope-defect requires preserved_phase_commits")

    if "/final-report-overclaim/" in case_path:
        overclaim = actual.get("overclaim_check")
        if not isinstance(overclaim, dict):
            errors.append(f"{case_path}: overclaim case must include overclaim_check object")
        else:
            if overclaim.get("classification") != "overclaim_detected":
                errors.append(f"{case_path}: overclaim classification must be overclaim_detected")
            if overclaim.get("json_overclaim_guard_passed") is not False:
                errors.append(f"{case_path}: json_overclaim_guard_passed must be false")
    else:
        if "overclaim_check" not in actual:
            errors.append(f"{case_path}: actual.overclaim_check field is required (null when not applicable)")

valid_cases = [p for p in group_cases if "/valid-input/" in p]
if len(valid_cases) != 1:
    errors.append(f"expected exactly one valid-input case, got {len(valid_cases)}")
else:
    valid_case = json.loads((repo / valid_cases[0]).read_text(encoding="utf-8"))
    valid_stage = valid_case.get("actual", {}).get("stage_result", {})
    if valid_stage.get("stage_id") != "R13" or valid_stage.get("stage_status") != "PASS":
        errors.append("valid-input case must PASS at R13")

result = {
    "status": "pass" if not errors else "fail",
    "fixture": fixture_arg,
    "review_registered_cases": len(group_cases),
    "fixture_case_matches": len(fixture_matches),
    "errors": errors,
}
print(json.dumps(result, indent=2, sort_keys=True))
if errors:
    raise SystemExit(1)
PY
