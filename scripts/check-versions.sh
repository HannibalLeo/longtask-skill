#!/usr/bin/env bash
# Fail if any version-bearing file disagrees with VERSION.
# Catches the bc1c811 / df5f12e class of bug: bumping VERSION + package.json
# but forgetting .claude-plugin/plugin.json + .claude-plugin/marketplace.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected="$(cat VERSION)"
mismatches=0

check() {
  local file="$1" pattern="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "MISSING: $file" >&2
    mismatches=$((mismatches + 1))
    return
  fi
  local found
  found="$(grep -E "$pattern" "$file" | head -1 || true)"
  if [[ -z "$found" ]] || ! echo "$found" | grep -q "$expected"; then
    echo "MISMATCH: $label ($file)" >&2
    echo "  expected: $expected" >&2
    echo "  found:    ${found:-<no match>}" >&2
    mismatches=$((mismatches + 1))
  fi
}

check package.json                  '"version"' "package.json version"
check .claude-plugin/plugin.json    '"version"' "plugin.json version"
check .claude-plugin/marketplace.json '"version"' "marketplace.json plugins[].version"
check CHANGELOG.md                  '^## '      "CHANGELOG.md top heading"

if (( mismatches > 0 )); then
  echo "" >&2
  echo "VERSION says $expected — $mismatches file(s) disagree." >&2
  echo "Fix: update the listed files to match VERSION, or update VERSION." >&2
  exit 1
fi

echo "OK: all version markers agree on $expected"
