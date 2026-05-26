#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

groups=(
  "schema-reference"
  "handoff-routing-startup"
  "plan-integrity"
  "codex-exit"
  "review-precondition-and-evidence"
  "install-temp-home-safety"
  "wrapper-matrix"
  "final-evidence-classification"
)

bash "$repo_root/scripts/verify-schema-authority.sh"

tmp_report="$(mktemp "${TMPDIR:-/tmp}/verify-all-fixtures.XXXXXX.json")"
trap 'rm -f "$tmp_report"' EXIT

fixture_args=()
for g in "${groups[@]}"; do
  fixture_args+=(--group "$g")
done

bash "$repo_root/scripts/run-fixtures.sh" "${fixture_args[@]}" >"$tmp_report"
cat "$tmp_report"

python3 - "$tmp_report" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
errors = []

if report.get("status") != "pass":
    errors.append(f"fixture runner status is not pass: {report.get('status')!r}")

group_summary = report.get("group_summary", {})
required = [
    "schema-reference",
    "handoff-routing-startup",
    "plan-integrity",
    "codex-exit",
    "review-precondition-and-evidence",
    "install-temp-home-safety",
    "wrapper-matrix",
    "final-evidence-classification",
]

for group in required:
    stats = group_summary.get(group)
    if not isinstance(stats, dict):
        errors.append(f"missing group summary: {group}")
        continue
    total = stats.get("total")
    fail = stats.get("fail")
    if not isinstance(total, int) or total <= 0:
        errors.append(f"group {group} executed_cases must be > 0, got {total!r}")
    if fail != 0:
        errors.append(f"group {group} has failures: fail={fail!r}")

if errors:
    print(json.dumps({"status": "fail", "errors": errors}, indent=2, sort_keys=True))
    raise SystemExit(1)

print(json.dumps({"status": "pass", "checked_groups": required}, indent=2, sort_keys=True))
PY
