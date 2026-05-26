#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import json
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
shared = repo / "shared" / "schemas"

required_schemas = [
    "verifier-result.schema.json",
    "decision-review.schema.json",
    "plan-integrity-review.schema.json",
    "codex-clarification.schema.json",
    "handoff-manifest.schema.json",
    "codex-code-exit-state.schema.json",
    "review-stage-result.schema.json",
    "final-evidence-classification.schema.json",
]

errors = []
parsed = {}
for name in required_schemas:
    path = shared / name
    if not path.is_file():
        errors.append(f"missing required schema: {name}")
        continue
    try:
        parsed[name] = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        errors.append(f"invalid json in {name}: {exc}")

if "common-enums.schema.json" in [p.name for p in shared.glob("*.json")]:
    parsed["common-enums.schema.json"] = json.loads(
        (shared / "common-enums.schema.json").read_text(encoding="utf-8")
    )

expected_final = ["ALL_PASS", "PARTIAL_PASS", "REVIEW_FAIL"]
expected_blocked = [
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
]

common = parsed.get("common-enums.schema.json")
if not common:
    errors.append("missing shared/schemas/common-enums.schema.json")
else:
    final_enum = common.get("$defs", {}).get("final_status", {}).get("enum")
    blocked_enum = common.get("$defs", {}).get("blocked_reason", {}).get("enum")
    if final_enum != expected_final:
        errors.append(f"final status enum mismatch: {final_enum}")
    if blocked_enum != expected_blocked:
        errors.append("blocked enum set mismatch in common-enums.schema.json")

for schema_path in sorted(shared.glob("*.json")):
    data = json.loads(schema_path.read_text(encoding="utf-8"))
    stack = [data]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            if "$ref" in node and isinstance(node["$ref"], str):
                ref = node["$ref"]
                if ref.startswith("#") or "://" in ref:
                    pass
                else:
                    target_file = ref.split("#", 1)[0]
                    target = (schema_path.parent / target_file).resolve()
                    if not target.exists():
                        errors.append(f"unresolved $ref in {schema_path.name}: {ref}")
                    elif shared not in target.parents:
                        errors.append(f"$ref escapes shared/schemas in {schema_path.name}: {ref}")
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)

all_schemas = sorted(p.relative_to(repo).as_posix() for p in repo.glob("**/*.schema.json") if p.is_file())

def classify(path: str) -> str:
    if path.startswith("shared/schemas/"):
        return "active-authority"
    if (
        path.startswith("docs/")
        or path.startswith("openspec/")
        or path.startswith("migration/")
        or path.startswith("migrations/")
        or "/migration/" in path
        or "/migrations/" in path
        or "/archive/" in path
    ):
        return "allowed-non-executable"
    return "rejected-duplicate-active"

outside = [p for p in all_schemas if not p.startswith("shared/schemas/")]
rejected = [p for p in outside if classify(p) == "rejected-duplicate-active"]
if rejected:
    errors.append(f"duplicate active schemas outside shared/schemas: {rejected}")

report = {
    "required_schemas_checked": required_schemas,
    "all_schema_files": all_schemas,
    "outside_shared_schema_files": outside,
    "duplicate_rejections": rejected,
    "errors": errors,
}
print(json.dumps(report, indent=2, sort_keys=True))
if errors:
    raise SystemExit(1)
PY
