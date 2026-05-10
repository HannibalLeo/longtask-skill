#!/usr/bin/env bash
# Deprecated fallback Codex longtask wrapper.
#
# Purpose:
#   Run one fresh `codex exec` child with machine-readable JSONL events and an
#   optional structured final response schema. Native Codex subagents are the
#   preferred Codex app path; this wrapper is for CI/CLI fallback only.
#
# Usage:
#   bash ~/.codex/skills/longtask/lib/codex-wrapper.sh \
#     <prompt_file> <run_id> [output_schema_json] [last_message_json]
#
# Environment:
#   CODEX_LONGTASK_MODEL       default: gpt-5.4
#   CODEX_LONGTASK_REASONING   default: medium
#   CODEX_LONGTASK_SANDBOX     default: workspace-write
#   CODEX_LONGTASK_APPROVALS   default: never (passed as approval_policy config)
#   CODEX_LONGTASK_REPO        optional: repo cwd for the child
#
# Exit codes:
#   0   codex completed
#   2   wrapper usage error
#   142 no output line for STALL_SECONDS
#   *   codex non-zero exit

set -u

PROMPT_FILE="${1:-}"
RUN_ID="${2:-$$}"
OUTPUT_SCHEMA="${3:-}"
LAST_MESSAGE="${4:-}"

if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "codex-wrapper.sh: missing or invalid prompt file: ${PROMPT_FILE:-<empty>}" >&2
  echo "usage: $0 <prompt_file> <run_id> [output_schema_json] [last_message_json]" >&2
  exit 2
fi

MODEL="${CODEX_LONGTASK_MODEL:-gpt-5.4}"
REASONING="${CODEX_LONGTASK_REASONING:-medium}"
SANDBOX="${CODEX_LONGTASK_SANDBOX:-workspace-write}"
APPROVALS="${CODEX_LONGTASK_APPROVALS:-never}"
REPO="${CODEX_LONGTASK_REPO:-}"
STALL_SECONDS="${CODEX_LONGTASK_STALL_SECONDS:-600}"

ARGS=(
  exec
  --json
  --model "$MODEL"
  --sandbox "$SANDBOX"
  --skip-git-repo-check
  -c "model_reasoning_effort=\"$REASONING\""
  -c "approval_policy=\"$APPROVALS\""
)

if [ -n "$REPO" ]; then
  ARGS+=(--cd "$REPO")
fi

if [ -n "$OUTPUT_SCHEMA" ]; then
  ARGS+=(--output-schema "$OUTPUT_SCHEMA")
fi

if [ -n "$LAST_MESSAGE" ]; then
  ARGS+=(-o "$LAST_MESSAGE")
fi

ARGS+=(-)

set -o pipefail
SECONDS=0
codex "${ARGS[@]}" < "$PROMPT_FILE" 2>&1 \
| { while IFS= read -r -t "$STALL_SECONDS" line; do
      SECONDS=0
      printf "%s\n" "$line"
    done
    [ "$SECONDS" -ge "$STALL_SECONDS" ] && exit 142
    exit 0
  }
exit $?
