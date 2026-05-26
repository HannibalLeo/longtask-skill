#!/usr/bin/env python3
"""Deterministic Step 6 contract helpers for codex-longtask-code."""

from __future__ import annotations

from typing import Any


FINAL_STATUSES = ("ALL_PASS", "PARTIAL_PASS", "REVIEW_FAIL")
FORBIDDEN_STEP6_ACTIONS = (
    "final_verify_cmd",
    "final_e2e2_cmd",
    "git push",
    "gh pr create",
    "publish",
    "deploy",
    "install-codex",
    "uninstall-codex",
)


def derive_overall_status(phase_results: dict[str, dict[str, Any]]) -> str:
    """Derive overall Step 6 status from per-phase statuses."""
    statuses = [str(v.get("phase_status", "")) for v in phase_results.values()]
    if statuses and all(status == "PASS" for status in statuses):
        return "ALL_PASS"
    if any(status == "BLOCKED" for status in statuses):
        return "PARTIAL_PASS"
    return "REVIEW_FAIL"


def forbidden_actions_present(candidate_text: str) -> list[str]:
    """Return forbidden action tokens found in a text blob."""
    found: list[str] = []
    lower = candidate_text.lower()
    for token in FORBIDDEN_STEP6_ACTIONS:
        if token.lower() in lower:
            found.append(token)
    return found


def require_recovery_fields(exit_state: dict[str, Any]) -> list[str]:
    """Return missing recovery fields that must exist in Step 6 exit state."""
    required = (
        "resume_default_command",
        "safe_path_recovery_command",
        "plan_repair_command",
        "review_retry_command",
        "human_override_instructions",
    )
    missing: list[str] = []
    for field in required:
        if field not in exit_state:
            missing.append(field)
    return missing
