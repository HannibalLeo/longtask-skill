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
  echo "usage: $0 --fixture fixtures/codex-exit/all-pass" >&2
  exit 2
fi

python3 - "$repo_root" "$fixture" <<'PY'
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
fixture_arg = sys.argv[2].strip().strip("/")
manifest = json.loads((repo / "fixtures/_runner/manifest.json").read_text(encoding="utf-8"))
group_cases = manifest.get("groups", {}).get("codex-exit", {}).get("cases", [])
errors: list[str] = []

if not group_cases:
    errors.append("codex-exit fixture group is empty")

fixture_matches = [p for p in group_cases if p.startswith(fixture_arg + "/")]
if not fixture_matches:
    errors.append(f"no codex-exit cases found under fixture prefix: {fixture_arg}")

required_case_markers = (
    "/all-pass/",
    "/partial-pass/",
    "/blocked-before-mutation/",
    "/missing-pass-commit/",
    "/malformed-verifier-json/",
)
for marker in required_case_markers:
    if not any(marker in case_path for case_path in group_cases):
        errors.append(f"missing required codex-exit case marker: {marker}")

allowed_status = {"ALL_PASS", "PARTIAL_PASS", "REVIEW_FAIL"}
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

for case_path in group_cases:
    data = json.loads((repo / case_path).read_text(encoding="utf-8"))
    actual = data.get("actual", {})
    status = actual.get("overall_status")
    if status not in allowed_status:
        errors.append(f"{case_path}: invalid overall_status {status!r}")
    blocked = actual.get("blocked_reason")
    if blocked is not None and blocked not in allowed_blocked:
        errors.append(f"{case_path}: invalid blocked_reason {blocked!r}")

    for key in (
        "resume_default_command",
        "safe_path_recovery_command",
        "plan_repair_command",
        "review_retry_command",
        "human_override_instructions",
    ):
        if key not in actual:
            errors.append(f"{case_path}: missing recovery field {key}")

    phase_results = actual.get("phase_results", {})
    commit_chain = actual.get("phase_commit_chain", [])
    preserved = actual.get("preserved_phase_commits", [])
    commit_set = {entry.get("commit_sha") for entry in commit_chain + preserved if isinstance(entry, dict)}
    blocked_reason = actual.get("blocked_reason")
    for phase_id, phase in phase_results.items():
        if not isinstance(phase, dict):
            continue
        if phase.get("phase_status") == "PASS":
            commit_sha = phase.get("commit_sha")
            if not commit_sha and blocked_reason != "BLOCKED_COMMIT_CHAIN_INVALID":
                errors.append(f"{case_path}: PASS phase {phase_id} missing commit_sha without commit-chain-invalid reason")
            if commit_sha and commit_sha not in commit_set:
                errors.append(f"{case_path}: PASS phase {phase_id} commit_sha not present in commit chain/preserved commits")

    forbidden = actual.get("step6_forbidden_actions")
    if not isinstance(forbidden, dict):
        errors.append(f"{case_path}: missing step6_forbidden_actions map")
    else:
        required_forbidden = (
            "final_verify_cmd",
            "final_e2e2_cmd",
            "push",
            "pr",
            "publish",
            "deploy",
            "global_install",
        )
        for key in required_forbidden:
            if forbidden.get(key) is not False:
                errors.append(f"{case_path}: forbidden action {key} must be false")

skill_text = (repo / "skills/codex-longtask-code/SKILL.md").read_text(encoding="utf-8")
prompt_text = (repo / "codex/prompts/codex-longtask-code.md").read_text(encoding="utf-8")
for required_phrase in (
    "Final verification (`final_verify_cmd`).",
    "Final E2E2",
    "Push, PR, publish, deploy.",
):
    if required_phrase not in skill_text:
        errors.append(f"skills/codex-longtask-code/SKILL.md missing phrase: {required_phrase}")
for required_phrase in (
    "stop before final verification",
    "final E2E2",
    "publish/deploy",
):
    if required_phrase not in prompt_text:
        errors.append(f"codex/prompts/codex-longtask-code.md missing phrase: {required_phrase}")

lib_path = repo / "codex/lib/codex_step6_contract.py"
if not lib_path.is_file():
    errors.append("missing codex/lib/codex_step6_contract.py")

result = {
    "status": "pass" if not errors else "fail",
    "fixture": fixture_arg,
    "codex_exit_registered_cases": len(group_cases),
    "fixture_case_matches": len(fixture_matches),
    "errors": errors,
}
print(json.dumps(result, indent=2, sort_keys=True))
if errors:
    raise SystemExit(1)
PY
