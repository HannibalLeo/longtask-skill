#!/usr/bin/env bash
# Sanity smoke test for ~/.claude/skills/longtask/
#
# Purpose: verify the three JSON schemas are valid Draft 2020-12 documents,
#          check codex-wrapper.sh for bash syntax errors, and confirm the
#          wrapper exits 2 (usage error) when called with no arguments.
#
# Does NOT call `codex exec` — safe to run in environments without codex.
# If codex is absent the codex-related tests are skipped (exit 0 still).
#
# Usage:
#   bash ~/.claude/skills/longtask/lib/smoke.sh
#
# Exit codes:
#   0  all checks passed (or skipped)
#   1  one or more checks failed

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMAS_DIR="$SKILL_DIR/schemas"
WRAPPER="$SKILL_DIR/lib/codex-wrapper.sh"

PASS=0
FAIL=0

ok()   { echo "OK   $*"; }
fail() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP $*"; }

# ── 1. Validate JSON schemas (self-check) ────────────────────────────────────

check_schema() {
  local file="$1"
  local name
  name="$(basename "$file")"
  if python3 - <<PYEOF 2>/dev/null
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(10)
with open("$file") as f:
    schema = json.load(f)
jsonschema.Draft202012Validator.check_schema(schema)
PYEOF
  then
    ok "schema valid: $name"
  else
    local exit_code=$?
    if [ "$exit_code" -eq 10 ]; then
      skip "jsonschema not installed — cannot validate $name (pip install jsonschema to enable)"
    else
      fail "schema invalid: $name"
    fi
  fi
}

for schema in \
  "$SCHEMAS_DIR/verifier-result.schema.json" \
  "$SCHEMAS_DIR/decision-review.schema.json" \
  "$SCHEMAS_DIR/plan-integrity-review.schema.json" \
  "$SCHEMAS_DIR/codex-clarification.schema.json"
do
  if [ -f "$schema" ]; then
    check_schema "$schema"
  else
    fail "schema file missing: $schema"
  fi
done

# ── 2. Bash syntax check on codex-wrapper.sh ─────────────────────────────────

if [ -f "$WRAPPER" ]; then
  if bash -n "$WRAPPER" 2>/dev/null; then
    ok "bash -n: $WRAPPER"
  else
    fail "bash syntax error in: $WRAPPER"
    bash -n "$WRAPPER"
  fi
else
  fail "wrapper missing: $WRAPPER"
fi

# ── 3. Usage-gate: wrapper exits 2 with no args ──────────────────────────────

if [ -f "$WRAPPER" ]; then
  bash "$WRAPPER" >/dev/null 2>&1
  exit_code=$?
  if [ "$exit_code" -eq 2 ]; then
    ok "usage gate: codex-wrapper.sh exits 2 with no args"
  else
    fail "usage gate: expected exit 2, got $exit_code"
  fi
fi

# ── 4. Codex availability notice (informational) ─────────────────────────────

if ! command -v codex >/dev/null 2>&1; then
  skip "codex not in PATH — runtime tests skipped (install codex to enable)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "OK  smoke.sh: all checks passed (FAIL=0)"
  exit 0
else
  echo "FAIL smoke.sh: $FAIL check(s) failed"
  exit 1
fi
