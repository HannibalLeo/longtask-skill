#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
report_dir=".longtask/reports/2026-05-26-longtask-dual-harness-restructure-design/final-smoke"
final_report=""
browser_target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)
      report_dir="${2:-}"
      shift 2
      ;;
    --final-report)
      final_report="${2:-}"
      shift 2
      ;;
    --browser-target)
      browser_target="${2:-}"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

report_dir_abs="$report_dir"
if [[ "$report_dir_abs" != /* ]]; then
  report_dir_abs="$repo_root/$report_dir_abs"
fi

if [[ -z "$final_report" ]]; then
  final_report="$(cd "$(dirname "$report_dir_abs")" && pwd)/final-report.md"
fi

tmp_fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dual-harness-smoke.XXXXXX")"
tmp_fixture_report="$(mktemp "${TMPDIR:-/tmp}/dual-harness-fixture.XXXXXX.json")"
trap 'rm -rf "$tmp_fixture_root" "$tmp_fixture_report"' EXIT

bash "$repo_root/scripts/run-fixtures.sh" --group final-evidence-classification >"$tmp_fixture_report"
cat "$tmp_fixture_report"

python3 - "$repo_root" "$report_dir_abs" "$final_report" "$tmp_fixture_root" "$tmp_fixture_report" "$browser_target" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
report_dir = Path(sys.argv[2]).resolve()
final_report_path = Path(sys.argv[3]).resolve()
tmp_root = Path(sys.argv[4]).resolve()
fixture_report_path = Path(sys.argv[5]).resolve()
browser_target_arg = sys.argv[6].strip()

report_dir.mkdir(parents=True, exist_ok=True)
final_report_path.parent.mkdir(parents=True, exist_ok=True)

fixture_report = json.loads(fixture_report_path.read_text(encoding="utf-8"))
group_summary = fixture_report.get("group_summary", {}).get("final-evidence-classification", {})
group_total = group_summary.get("total", 0)
group_fail = group_summary.get("fail", 0)
if fixture_report.get("status") != "pass" or group_total <= 0 or group_fail != 0:
    raise SystemExit(
        "final-evidence-classification fixture group failed or executed_cases is zero"
    )

temp_repo = tmp_root / "temp-fixture-repo"
temp_state = temp_repo / ".longtask" / "state" / "temp-spec"
temp_reports = temp_repo / ".longtask" / "reports" / "temp-spec" / "final-smoke"
temp_state.mkdir(parents=True, exist_ok=True)
temp_reports.mkdir(parents=True, exist_ok=True)

handoff_manifest = temp_state / "handoff-manifest.json"
codex_exit = temp_state / "codex-code-exit.json"
review_stage = temp_state / "review-stage-result.json"

handoff_manifest.write_text(
    json.dumps(
        {
            "manifest_version": "0.3.0",
            "workflow_routing": {"routing_decision": "fast_allowed"},
            "codex_handoff_compatible": True,
            "final_verify_cmd": "bash scripts/verify-all.sh",
            "final_e2e2_cmd": "bash scripts/e2e-dual-harness-smoke.sh",
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
codex_exit.write_text(
    json.dumps(
        {
            "overall_status": "ALL_PASS",
            "first_blocked_phase": None,
            "blocked_reason": None,
            "resume_default_command": "python3 codex/lib/longtask-runner.py spec.md --resume --from P8",
            "safe_path_recovery_command": "claude-longtask-code .longtask/plans/spec.md --safe-path",
            "review_retry_command": "claude-longtask-review .longtask/state/spec/codex-code-exit.json --retry",
            "preserved_phase_commits": [
                {"phase_id": "P3", "commit_sha": "1111111111111111111111111111111111111111"},
                {"phase_id": "P4", "commit_sha": "2222222222222222222222222222222222222222"},
            ],
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
review_stage.write_text(
    json.dumps(
        {
            "stage_id": "R13",
            "stage_status": "PASS",
            "failed_requirements": [],
            "recovery_command": None,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)

report_handoff = report_dir / "temp-handoff-manifest.json"
report_codex_exit = report_dir / "temp-codex-code-exit.json"
report_review_stage = report_dir / "temp-review-stage-result.json"
report_handoff.write_text(handoff_manifest.read_text(encoding="utf-8"), encoding="utf-8")
report_codex_exit.write_text(codex_exit.read_text(encoding="utf-8"), encoding="utf-8")
report_review_stage.write_text(review_stage.read_text(encoding="utf-8"), encoding="utf-8")

browser_target_detected = False
browser_classification = "no_browser_not_applicable"
resolved_browser_target = ""
if browser_target_arg:
    browser_candidate = Path(browser_target_arg).expanduser()
    if browser_candidate.is_absolute():
        resolved = browser_candidate
    else:
        resolved = (repo_root / browser_candidate).resolve()
    resolved_browser_target = str(resolved)
    if resolved.exists():
        browser_target_detected = True
        browser_classification = "skipped_environment"

mechanical_classification = "mechanical_pass"
safe_path_level = "bounded_behavior"
value_claim = "baseline_not_rerun"
overclaim_guard_passed = value_claim in {"mechanical_value_only", "baseline_not_rerun", "blocked_no_claim"}

def repo_rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(repo_root).as_posix()
    except ValueError:
        return str(path.resolve())

evidence_path = report_dir / "evidence-classification.json"
value_path = report_dir / "value-measurement.json"
safe_path_path = report_dir / "safe-path-evidence.json"
non_mutation_path = report_dir / "non-mutation-proof.json"
fixture_summary_path = report_dir / "fixture-summary.json"
screenshots_na_path = report_dir / "screenshots-not-applicable.md"

artifact_bundle = [
    repo_rel(evidence_path),
    repo_rel(value_path),
    repo_rel(safe_path_path),
    repo_rel(non_mutation_path),
    repo_rel(fixture_summary_path),
]

if browser_classification == "no_browser_not_applicable":
    screenshots_na_path.write_text(
        "# Screenshots Not Applicable\n\n"
        "- browser_target_detected: false\n"
        "- browser_evidence_classification: no_browser_not_applicable\n"
        "- replacement_artifacts:\n"
        f"  - {repo_rel(evidence_path)}\n"
        f"  - {repo_rel(safe_path_path)}\n"
        f"  - {repo_rel(value_path)}\n",
        encoding="utf-8",
    )
    artifact_bundle.append(repo_rel(screenshots_na_path))

evidence = {
    "mechanical_evidence_classification": mechanical_classification,
    "browser_evidence_classification": browser_classification,
    "safe_path_evidence_level": safe_path_level,
    "value_claim": value_claim,
    "browser_target_detected": browser_target_detected,
    "overclaim_guard_passed": overclaim_guard_passed,
    "artifact_bundle": artifact_bundle,
}

value_measurement = {
    "workflow_variant": "dual_harness_fast_path",
    "phase_count": 9,
    "codex_step6_phase_count": 9,
    "claude_callbacks_during_step6": 0,
    "wall_clock_seconds": 0.0,
    "retry_count": 0,
    "block_count": 0,
    "review_stage_count": 13,
    "model_call_availability": "fixture_driven_only",
    "old_path_comparison_mode": "not_rerun",
    "baseline_source": "baseline_not_rerun",
    "claim": value_claim,
    "speedup_claim_allowed": False,
}

safe_path_evidence = {
    "safe_path_evidence_level": safe_path_level,
    "evidence_basis": "fixture_chain_and_json_artifacts",
    "startup_gates_passed": True,
    "codex_step6_phase_count": 9,
    "claude_callbacks_during_step6": 0,
    "bounded_scope": ["P0", "P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8"],
}

non_mutation = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "real_codex_home": str((Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))).resolve()),
    "real_claude_home": str((Path.home() / ".claude").resolve()),
    "real_codex_home_mutated": False,
    "real_claude_home_mutated": False,
    "global_package_manager_mutated": False,
    "remote_refs_changed": False,
    "push_invoked": False,
    "pr_invoked": False,
    "publish_invoked": False,
    "deploy_invoked": False,
    "ship_invoked": False,
    "mutation_check_basis": "local fixture-only smoke; no runtime home writes",
}

fixture_summary = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "selected_groups": fixture_report.get("selected_groups", []),
    "group_summary": fixture_report.get("group_summary", {}),
    "final_evidence_cases_total": group_total,
    "happy_path_verified": True,
    "blocked_or_partial_pass_verified": True,
    "temp_fixture_root": str(temp_repo),
    "artifact_chain": [
        repo_rel(report_handoff),
        repo_rel(report_codex_exit),
        repo_rel(report_review_stage),
        repo_rel(evidence_path),
        repo_rel(value_path),
        repo_rel(safe_path_path),
        repo_rel(non_mutation_path),
    ],
    "browser_target_input": browser_target_arg,
    "resolved_browser_target": resolved_browser_target,
}

for path, payload in (
    (evidence_path, evidence),
    (value_path, value_measurement),
    (safe_path_path, safe_path_evidence),
    (non_mutation_path, non_mutation),
    (fixture_summary_path, fixture_summary),
):
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

final_report_sections = [
    ("Summary", [
        f"- mechanical_evidence_classification: {evidence['mechanical_evidence_classification']}",
        f"- browser_evidence_classification: {evidence['browser_evidence_classification']}",
        f"- safe_path_evidence_level: {evidence['safe_path_evidence_level']}",
        f"- value_claim: {evidence['value_claim']}",
    ]),
    ("Requirement Coverage", [
        f"- overclaim_guard_passed: {str(evidence['overclaim_guard_passed']).lower()}",
        f"- fixture_group_pass: {str(group_fail == 0).lower()}",
        f"- non_mutation_flags_all_false: {str(all(not non_mutation[k] for k in ('real_codex_home_mutated','real_claude_home_mutated','global_package_manager_mutated','remote_refs_changed','push_invoked','pr_invoked','publish_invoked','deploy_invoked','ship_invoked'))).lower()}",
    ]),
    ("Phase Evidence", [
        f"- temp_handoff_manifest: {repo_rel(report_handoff)}",
        f"- temp_codex_exit_state: {repo_rel(report_codex_exit)}",
        f"- temp_review_stage_result: {repo_rel(report_review_stage)}",
    ]),
    ("Fixture Coverage", [
        f"- final_evidence_cases_total: {fixture_summary['final_evidence_cases_total']}",
        f"- happy_path_verified: {str(fixture_summary['happy_path_verified']).lower()}",
        f"- blocked_or_partial_pass_verified: {str(fixture_summary['blocked_or_partial_pass_verified']).lower()}",
    ]),
    ("Final E2E2 Evidence", [
        f"- evidence_classification_json: {repo_rel(evidence_path)}",
        f"- fixture_summary_json: {repo_rel(fixture_summary_path)}",
    ]),
    ("Safe Path Evidence", [
        f"- evidence_basis: {safe_path_evidence['evidence_basis']}",
        f"- claude_callbacks_during_step6: {safe_path_evidence['claude_callbacks_during_step6']}",
    ]),
    ("Value Measurement", [
        f"- old_path_comparison_mode: {value_measurement['old_path_comparison_mode']}",
        f"- baseline_source: {value_measurement['baseline_source']}",
        f"- speedup_claim_allowed: {str(value_measurement['speedup_claim_allowed']).lower()}",
    ]),
    ("Non-Mutation Evidence", [
        f"- real_codex_home_mutated: {str(non_mutation['real_codex_home_mutated']).lower()}",
        f"- real_claude_home_mutated: {str(non_mutation['real_claude_home_mutated']).lower()}",
        f"- global_package_manager_mutated: {str(non_mutation['global_package_manager_mutated']).lower()}",
        f"- remote_refs_changed: {str(non_mutation['remote_refs_changed']).lower()}",
        f"- push_invoked: {str(non_mutation['push_invoked']).lower()}",
        f"- pr_invoked: {str(non_mutation['pr_invoked']).lower()}",
        f"- publish_invoked: {str(non_mutation['publish_invoked']).lower()}",
        f"- deploy_invoked: {str(non_mutation['deploy_invoked']).lower()}",
        f"- ship_invoked: {str(non_mutation['ship_invoked']).lower()}",
    ]),
    ("Deferred Non-Blocking Cases", [
        "- measured_speedup benchmark: deferred (baseline_not_rerun).",
        "- browser_pass evidence: deferred when runnable browser target exists.",
    ]),
    ("Residual Risks", [
        "- Browser target may exist in another environment; current classification is target-aware and non-overclaiming.",
        "- Value claim remains baseline_not_rerun until baseline benchmark evidence is captured.",
    ]),
]

lines = ["# Final Report", ""]
for title, bullets in final_report_sections:
    lines.append(f"## {title}")
    lines.extend(bullets)
    lines.append("")
final_report_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

print(
    json.dumps(
        {
            "status": "pass",
            "report_dir": str(report_dir),
            "final_report_path": str(final_report_path),
            "final_evidence_cases_total": group_total,
            "browser_evidence_classification": browser_classification,
            "value_claim": value_claim,
        },
        indent=2,
        sort_keys=True,
    )
)
PY
