#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/scan-stale-references.sh [--output PATH] [--fail-active] [--help]
EOF
}

OUTPUT_PATH=".longtask/reports/2026-05-26-longtask-dual-harness-restructure-design/stale-references.json"
FAIL_ACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "missing value for --output" >&2; exit 2; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --fail-active)
      FAIL_ACTIVE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_abs="$OUTPUT_PATH"
if [[ "$output_abs" != /* ]]; then
  output_abs="$repo_root/$output_abs"
fi
mkdir -p "$(dirname "$output_abs")"

python3 - "$repo_root" "$output_abs" "$FAIL_ACTIVE" <<'PY'
import json
import pathlib
import re
import subprocess
import sys
from collections import Counter

repo_root = pathlib.Path(sys.argv[1]).resolve()
output_path = pathlib.Path(sys.argv[2]).resolve()
fail_active = sys.argv[3] == "1"

scan_roots = [
    "skills",
    "claude",
    "codex",
    "shared",
    "scripts",
    "docs",
    "README.md",
    "CHANGELOG.md",
    "VERSION",
    "package.json",
    "codex-extension.json",
    ".claude-plugin/marketplace.json",
]
excluded_roots = [
    ".git/",
    ".longtask/reports/",
    "fixtures/**/tmp/",
    "fixtures/**/temp/",
]
patterns = [
    {"id": "legacy_skill_dir_longtask", "regex": r"skills/longtask(?:/|\\b)"},
    {"id": "legacy_skill_dir_longtask_plan", "regex": r"skills/longtaskPlan(?:/|\\b)"},
    {"id": "legacy_skill_dir_longtask_code", "regex": r"skills/longtaskCode(?:/|\\b)"},
    {"id": "legacy_plugin_root_path", "regex": r"(?:^|[^A-Za-z0-9_])plugin/"},
    {"id": "legacy_codex_home_path", "regex": r"~/.codex/skills/longtask(?:/|\\b)"},
    {"id": "legacy_claude_home_path", "regex": r"~/.claude/skills/longtask(?:/|\\b)"},
]

active_roots = [repo_root / p for p in scan_roots]
compiled = [(p["id"], re.compile(p["regex"])) for p in patterns]

rg_cmd = [
    "rg",
    "-n",
    "--no-heading",
    "--color=never",
    "-e",
    "skills/longtask",
    "-e",
    "skills/longtaskPlan",
    "-e",
    "skills/longtaskCode",
    "-e",
    "plugin/",
    "-e",
    "~/.codex/skills/longtask",
    "-e",
    "~/.claude/skills/longtask",
] + [str(p) for p in active_roots if p.exists()]

proc = subprocess.run(rg_cmd, cwd=repo_root, text=True, capture_output=True, check=False)
raw_lines = [line for line in proc.stdout.splitlines() if line.strip()]

def is_excluded(path: str) -> bool:
    if path.startswith(".git/"):
        return True
    if path.startswith(".longtask/reports/"):
        return True
    if "/tmp/" in path or "/temp/" in path:
        return True
    return False

def classify(path: str, line_text: str) -> tuple[str, str]:
    lower = line_text.lower()
    suffix = pathlib.Path(path).suffix.lower()
    if path == "scripts/scan-stale-references.sh":
        return ("allowed_historical_reference", "scanner_pattern_definition")
    if path.endswith("docs/migration-from-v0.2.md") or path == "CHANGELOG.md":
        return ("allowed_historical_reference", "migration_or_changelog_context")
    if suffix == ".md":
        if any(token in lower for token in ("legacy", "migration", "deprecated", "v0.2", "historical")):
            return ("allowed_historical_reference", "documented_legacy_context")
        return ("allowed_non_authoritative_search_phrase", "non_executable_markdown_text")
    stripped = line_text.lstrip()
    if stripped.startswith("#") or stripped.startswith("//"):
        return ("allowed_historical_reference", "comment_context_non_executable")
    return ("forbidden_active_reference", "active_executable_reference")

matches = []
for row in raw_lines:
    try:
        path, line_no, text = row.split(":", 2)
    except ValueError:
        continue
    path_obj = pathlib.Path(path)
    if path_obj.is_absolute():
        try:
            rel_path = path_obj.resolve().relative_to(repo_root).as_posix()
        except ValueError:
            rel_path = path_obj.as_posix()
    else:
        rel_path = path_obj.as_posix()
    if is_excluded(rel_path):
        continue
    pattern_ids = [pid for pid, cre in compiled if cre.search(text)]
    if not pattern_ids:
        continue
    cls, reason = classify(rel_path, text)
    matches.append(
        {
            "path": rel_path,
            "line": int(line_no),
            "text": text.strip(),
            "pattern_ids": pattern_ids,
            "match_class": cls,
            "reason": reason,
        }
    )

counts = Counter(m["match_class"] for m in matches)
counts_by_class = {
    "forbidden_active_reference": counts.get("forbidden_active_reference", 0),
    "allowed_historical_reference": counts.get("allowed_historical_reference", 0),
    "allowed_non_authoritative_search_phrase": counts.get("allowed_non_authoritative_search_phrase", 0),
}

report = {
    "schema_version": "v1",
    "scan_roots": scan_roots,
    "excluded_roots": excluded_roots,
    "patterns": patterns,
    "counts_by_class": counts_by_class,
    "matches": matches,
}

output_path.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
print(str(output_path.relative_to(repo_root)))
print(json.dumps(counts_by_class, sort_keys=True))

if fail_active and counts_by_class["forbidden_active_reference"] > 0:
    raise SystemExit(1)
PY
