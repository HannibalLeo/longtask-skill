#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scan_paths=(
  skills
  claude/prompts
  codex/prompts
  shared/prompts
)

pattern='CODEX_LONGTASK_(DISABLE_PTY|FORCE_PTY)'
allow_tag='[non-active-wrapper-env-mention]'

hits="$(rg -n --no-heading -e "$pattern" "${scan_paths[@]}" || true)"
if [ -z "$hits" ]; then
  echo "PASS: no active wrapper override env mentions found."
  exit 0
fi

violations=()
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  # Keep only explicitly classified non-active mentions.
  if [[ "$hit" != *"$allow_tag"* ]]; then
    violations+=("$hit")
  fi
done <<< "$hits"

if [ "${#violations[@]}" -gt 0 ]; then
  echo "FAIL: active wrapper override env mentions must be removed or tagged as non-active context." >&2
  printf '%s\n' "${violations[@]}" >&2
  exit 1
fi

echo "PASS: wrapper override env mentions are classified as non-active only."
