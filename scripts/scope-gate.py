#!/usr/bin/env python3
"""Verify current working-tree changes stay within a phase file_scope."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path


def _extract_phase_yaml(plan_text: str, phase: str) -> str:
    phase_header = rf"^## {re.escape(phase)}:"
    header_match = re.search(phase_header, plan_text, flags=re.MULTILINE)
    if not header_match:
        raise ValueError(f"phase heading not found: {phase}")
    rest = plan_text[header_match.end() :]
    fence_match = re.search(r"```yaml\s*\n(.*?)\n```", rest, flags=re.DOTALL)
    if not fence_match:
        raise ValueError(f"yaml block not found for phase: {phase}")
    return fence_match.group(1)


def _parse_list_field(yaml_block: str, field: str) -> list[str]:
    lines = yaml_block.splitlines()
    results: list[str] = []
    i = 0
    while i < len(lines):
        if lines[i].strip() == f"{field}:":
            i += 1
            while i < len(lines):
                line = lines[i]
                stripped = line.strip()
                if stripped.startswith("- "):
                    results.append(stripped[2:].strip())
                    i += 1
                    continue
                if line.startswith("  - "):
                    results.append(line.split("- ", 1)[1].strip())
                    i += 1
                    continue
                if not stripped:
                    i += 1
                    continue
                break
            break
        i += 1
    return results


def _git_changed_paths(repo_root: Path) -> list[str]:
    proc_diff = subprocess.run(
        ["git", "diff", "--name-only"],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    proc_untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    changed = {line.strip() for line in proc_diff.stdout.splitlines() if line.strip()}
    changed.update(line.strip() for line in proc_untracked.stdout.splitlines() if line.strip())
    return sorted(changed)


def _matches_any(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        normalized = pattern.strip().lstrip("./")
        if fnmatch.fnmatch(path, normalized):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Scope gate for longtask phases.")
    parser.add_argument("--phase", required=True, help="Phase id, for example P2")
    parser.add_argument("--plan", required=True, help="Path to implementation plan markdown")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    plan_path = (repo_root / args.plan).resolve() if not Path(args.plan).is_absolute() else Path(args.plan).resolve()
    plan_text = plan_path.read_text(encoding="utf-8")
    yaml_block = _extract_phase_yaml(plan_text, args.phase)
    file_scope = _parse_list_field(yaml_block, "file_scope")
    do_not_touch = _parse_list_field(yaml_block, "do_not_touch")
    changed = _git_changed_paths(repo_root)

    out_of_scope = [p for p in changed if not _matches_any(p, file_scope)]
    forbidden = [p for p in changed if _matches_any(p, do_not_touch)]
    ok = not out_of_scope and not forbidden

    report = {
        "phase": args.phase,
        "plan": str(plan_path),
        "file_scope": file_scope,
        "do_not_touch": do_not_touch,
        "changed_files": changed,
        "out_of_scope": out_of_scope,
        "forbidden_touched": forbidden,
        "status": "pass" if ok else "fail",
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
