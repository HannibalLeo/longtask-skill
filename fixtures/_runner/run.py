#!/usr/bin/env python3
"""Table-driven fixture runner for longtask dual-harness contracts."""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "fixtures" / "_runner" / "manifest.json"
SHARED_SCHEMA_ROOT = REPO_ROOT / "shared" / "schemas"


def _collect_refs(node: Any) -> list[str]:
    refs: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                refs.append(value)
            refs.extend(_collect_refs(value))
    elif isinstance(node, list):
        for item in node:
            refs.extend(_collect_refs(item))
    return refs


def _resolve_ref_file(schema_file: Path, ref_value: str) -> Path | None:
    if ref_value.startswith("#"):
        return None
    if "://" in ref_value:
        return None
    file_part = ref_value.split("#", 1)[0]
    if not file_part:
        return None
    return (schema_file.parent / file_part).resolve()


def _classify_schema_path(path: str) -> str:
    normalized = path.strip().lstrip("./")
    if not normalized.endswith(".schema.json"):
        return "not-schema"
    if normalized.startswith("shared/schemas/"):
        return "active-authority"
    allowed_patterns = (
        "docs/**",
        "openspec/**",
        "migration/**",
        "migrations/**",
        "**/migration/**",
        "**/migrations/**",
        "**/archive/**",
    )
    if any(fnmatch.fnmatch(normalized, pat) for pat in allowed_patterns):
        return "allowed-non-executable"
    return "rejected-duplicate-active"


def _run_case_schema_parse(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    pattern = case["schema_glob"]
    matched = sorted(p for p in REPO_ROOT.glob(pattern) if p.is_file())
    errors: list[str] = []
    for schema_path in matched:
        try:
            json.loads(schema_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            rel = schema_path.relative_to(REPO_ROOT).as_posix()
            errors.append(f"{rel}: {exc}")
    details = {
        "schema_glob": pattern,
        "matched": [p.relative_to(REPO_ROOT).as_posix() for p in matched],
        "errors": errors,
    }
    return len(matched) > 0 and not errors, details


def _run_case_ref_resolution(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    schema_paths = [REPO_ROOT / p for p in case["schema_paths"]]
    failures: list[str] = []
    checked_refs: list[dict[str, str]] = []
    for schema_path in schema_paths:
        rel_schema = schema_path.relative_to(REPO_ROOT).as_posix()
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        refs = _collect_refs(schema)
        for ref in refs:
            resolved = _resolve_ref_file(schema_path, ref)
            if resolved is None:
                checked_refs.append({"schema": rel_schema, "ref": ref, "resolved": "<inline-or-uri>"})
                continue
            rel_resolved = resolved.relative_to(REPO_ROOT).as_posix() if resolved.exists() else "<missing>"
            checked_refs.append({"schema": rel_schema, "ref": ref, "resolved": rel_resolved})
            if not resolved.exists():
                failures.append(f"{rel_schema}: unresolved ref '{ref}' -> {resolved}")
                continue
            if not resolved.is_file():
                failures.append(f"{rel_schema}: ref '{ref}' resolved to non-file path")
                continue
            if SHARED_SCHEMA_ROOT not in resolved.parents:
                failures.append(f"{rel_schema}: ref '{ref}' escapes shared/schemas ({rel_resolved})")
    return not failures, {"checked_refs": checked_refs, "failures": failures}


def _run_case_duplicate_rejection(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    sample_candidates = case.get("sample_candidates", [])
    sample_classification = [
        {"path": p, "classification": _classify_schema_path(p)} for p in sample_candidates
    ]
    expected_rejected = sorted(case.get("expected_rejected", []))
    actual_rejected = sorted(
        item["path"] for item in sample_classification if item["classification"] == "rejected-duplicate-active"
    )

    repo_candidates = sorted(
        p.relative_to(REPO_ROOT).as_posix()
        for p in REPO_ROOT.glob("**/*.schema.json")
        if p.is_file() and SHARED_SCHEMA_ROOT not in p.parents
    )
    repo_classification = [
        {"path": p, "classification": _classify_schema_path(p)} for p in repo_candidates
    ]
    repo_rejected = [
        item["path"] for item in repo_classification if item["classification"] == "rejected-duplicate-active"
    ]

    ok = actual_rejected == expected_rejected and not repo_rejected
    details = {
        "sample_classification": sample_classification,
        "expected_rejected": expected_rejected,
        "actual_rejected": actual_rejected,
        "repo_external_schema_classification": repo_classification,
        "repo_rejected_duplicates": repo_rejected,
    }
    return ok, details


def _run_case_allowed_doc_migration(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    sample_paths = case["sample_paths"]
    expected_allowed = sorted(case["expected_allowed"])
    actual_allowed = sorted(p for p in sample_paths if _classify_schema_path(p) == "allowed-non-executable")
    details = {
        "sample_paths": sample_paths,
        "expected_allowed": expected_allowed,
        "actual_allowed": actual_allowed,
        "classifications": [{"path": p, "classification": _classify_schema_path(p)} for p in sample_paths],
    }
    return actual_allowed == expected_allowed, details


def _compare_expected_fields(actual: Any, expected: Any, path: str = "root") -> list[str]:
    mismatches: list[str] = []
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {type(actual).__name__}"]
        for key, expected_value in expected.items():
            if key not in actual:
                mismatches.append(f"{path}.{key}: missing key")
                continue
            mismatches.extend(_compare_expected_fields(actual[key], expected_value, f"{path}.{key}"))
        return mismatches
    if isinstance(expected, list):
        if actual != expected:
            mismatches.append(f"{path}: expected {expected!r}, got {actual!r}")
        return mismatches
    if actual != expected:
        mismatches.append(f"{path}: expected {expected!r}, got {actual!r}")
    return mismatches


def _run_case_contract_case(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    actual = case.get("actual")
    expected = case.get("expected")
    if expected is None:
        return False, {"error": "missing_expected"}
    mismatches = _compare_expected_fields(actual, expected)
    return not mismatches, {"actual": actual, "expected": expected, "mismatches": mismatches}


CASE_DISPATCH = {
    "schema_parse": _run_case_schema_parse,
    "ref_resolution": _run_case_ref_resolution,
    "duplicate_active_schema_rejection": _run_case_duplicate_rejection,
    "allowed_doc_migration_references": _run_case_allowed_doc_migration,
    "contract_case": _run_case_contract_case,
}


def _load_manifest(manifest_path: Path) -> dict[str, Any]:
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Run longtask fixture groups.")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--group", action="append", default=[])
    args = parser.parse_args()

    manifest_path = Path(args.manifest).resolve()
    try:
        manifest = _load_manifest(manifest_path)
    except Exception as exc:  # pragma: no cover
        print(json.dumps({"status": "error", "error": f"manifest_load_failed: {exc}"}), flush=True)
        return 2

    canonical_groups = manifest.get("canonical_groups", [])
    groups = manifest.get("groups", {})
    selected_groups = args.group or canonical_groups
    unknown = sorted(set(selected_groups) - set(canonical_groups))
    if unknown:
        print(
            json.dumps(
                {
                    "status": "error",
                    "error": "unknown_group",
                    "unknown_groups": unknown,
                    "allowed_groups": canonical_groups,
                },
                indent=2,
                sort_keys=True,
            ),
            flush=True,
        )
        return 2

    case_results: list[dict[str, Any]] = []
    group_summary: dict[str, dict[str, int]] = {}
    any_failure = False

    for group_name in selected_groups:
        group_cfg = groups.get(group_name, {})
        case_paths = group_cfg.get("cases", [])
        group_pass = 0
        group_fail = 0
        for case_path in case_paths:
            case_abs = (REPO_ROOT / case_path).resolve()
            case_data = json.loads(case_abs.read_text(encoding="utf-8"))
            case_type = case_data["case_type"]
            handler = CASE_DISPATCH.get(case_type)
            if handler is None:
                result = {
                    "group": group_name,
                    "case_id": case_data.get("case_id", case_abs.name),
                    "case_path": case_path,
                    "pass": False,
                    "error": f"unknown_case_type:{case_type}",
                }
                case_results.append(result)
                any_failure = True
                group_fail += 1
                continue
            passed, details = handler(case_data)
            result = {
                "group": group_name,
                "case_id": case_data.get("case_id", case_abs.name),
                "case_path": case_path,
                "pass": passed,
                "details": details,
            }
            case_results.append(result)
            if passed:
                group_pass += 1
            else:
                group_fail += 1
                any_failure = True
        group_summary[group_name] = {"pass": group_pass, "fail": group_fail, "total": group_pass + group_fail}

    report = {
        "status": "pass" if not any_failure else "fail",
        "manifest_path": manifest_path.relative_to(REPO_ROOT).as_posix(),
        "selected_groups": selected_groups,
        "group_summary": group_summary,
        "case_results": case_results,
    }
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if not any_failure else 1


if __name__ == "__main__":
    sys.exit(main())
