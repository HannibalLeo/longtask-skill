#!/usr/bin/env bash
# Claude-side longtask wrapper for `codex exec` — v2 hybrid.
#
# This is the CLAUDE-SIDE wrapper. It differs from the Codex-side wrapper
# (~/.codex/skills/longtask/lib/codex-wrapper.sh) in the following ways:
#
#   1. Default model / reasoning:
#      - CODEX_LONGTASK_MODEL   = gpt-5.5   (Codex side: gpt-5.4)
#      - CODEX_LONGTASK_REASONING = xhigh   (Codex side: medium)
#      Rationale: Claude harness dispatches codex only for heavy-IO phase
#      workers and hybrid-judgment gates; these need max reasoning quality
#      to justify the cross-model round-trip.  See design spec decision #7.
#
#   2. Structured output params (new vs old Claude wrapper):
#      - OUTPUT_SCHEMA (arg 3): path to a JSON Schema file; passed as
#        --output-schema <file> to force codex to emit a schema-conforming
#        JSON final response.  Used by verifier, decision-gate, plan-integrity.
#      - LAST_MESSAGE (arg 4): path to a JSON file; passed as -o <file> to
#        capture only the last assistant message.  Used by verifier pipeline.
#
#   3. --json flag (new vs old Claude wrapper):
#      Forces JSONL event stream on stdout so the Claude main-line can parse
#      per-turn metadata (token counts, tool calls, errors) without regex on
#      free-text.
#
#   4. PTY workaround is RETAINED (decision #1):
#      codex 0.132.0 release notes do NOT mention a fix for issue #19945
#      (silent exit when stdout is not a TTY and prompt > ~10KB).  The
#      `script -q /dev/null` re-attach is kept until a controlled before/after
#      test on macOS + Linux confirms the bug is gone.
#      Set CODEX_LONGTASK_DISABLE_PTY=1 to bypass the workaround for testing.
#      Refs: https://github.com/openai/codex/issues/19945
#
# === Usage ===
#   bash ~/.claude/skills/longtask/lib/codex-wrapper.sh \
#     <prompt_file> [run_id] [output_schema_json] [last_message_json]
#
# === Environment ===
#   CODEX_LONGTASK_MODEL         default: gpt-5.5
#   CODEX_LONGTASK_REASONING     default: xhigh
#   CODEX_LONGTASK_SANDBOX       default: workspace-write
#   CODEX_LONGTASK_APPROVALS     default: never
#   CODEX_LONGTASK_REPO          optional: repo cwd for the child (--cd)
#   CODEX_LONGTASK_STALL_SECONDS default: 600  (10 min no stdout line → kill)
#   CODEX_LONGTASK_DISABLE_PTY   set to 1 to skip script(1) PTY workaround
#
# === Exit codes ===
#   0   codex completed normally
#   2   wrapper usage error (missing / invalid prompt file)
#   142 STALL_TIMEOUT: no stdout line for STALL_SECONDS
#   *   CRASH: codex non-zero exit, propagated via pipefail
#
# === Stdin requirement ===
#   Prompt MUST be a file path, not inline.  Long inline prompts trigger
#   codex's stdin-pipe hang (see memory feedback_codex_cli_stdin_pipe.md).
#
# === Kill model: stall-only ===
#   No wall-clock cap.  SECONDS resets on every read line; checked after
#   the read loop exits.  SECONDS >= STALL_SECONDS means timeout, not EOF.
#   (macOS bash 3.2: `read -t` returns exit 1 on both timeout and EOF; only
#   bash 4+ distinguishes via exit >128.)

set -u

PROMPT_FILE="${1:-}"
RUN_ID="${2:-$$}"
OUTPUT_SCHEMA="${3:-}"
LAST_MESSAGE="${4:-}"

if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "codex-wrapper.sh: missing or invalid prompt file: ${PROMPT_FILE:-<empty>}" >&2
  echo "usage: $0 <prompt_file> [run_id] [output_schema_json] [last_message_json]" >&2
  exit 2
fi

MODEL="${CODEX_LONGTASK_MODEL:-gpt-5.5}"
REASONING="${CODEX_LONGTASK_REASONING:-xhigh}"
SANDBOX="${CODEX_LONGTASK_SANDBOX:-workspace-write}"
APPROVALS="${CODEX_LONGTASK_APPROVALS:-never}"
REPO="${CODEX_LONGTASK_REPO:-}"
STALL_SECONDS="${CODEX_LONGTASK_STALL_SECONDS:-600}"
DISABLE_PTY="${CODEX_LONGTASK_DISABLE_PTY:-0}"

LAUNCHER="/tmp/codex-launch-${RUN_ID}.sh"

# Build the codex argument list inside the launcher script.
# We write a launcher file so that script(1) can exec a named command
# (PTY workaround requires a file, not a bash -c string, on some platforms).
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
CODEX_ARGS=(
  exec
  --json
  --model "$MODEL"
  --sandbox "$SANDBOX"
  --skip-git-repo-check
  -c "model_reasoning_effort=\\"$REASONING\\""
  -c "approval_policy=\\"$APPROVALS\\""
)
LAUNCHEOF

# Append optional flags to the launcher.
if [ -n "$REPO" ]; then
  printf '  CODEX_ARGS+=(--cd "%s")\n' "$REPO" >> "$LAUNCHER"
fi

if [ -n "$OUTPUT_SCHEMA" ]; then
  printf '  CODEX_ARGS+=(--output-schema "%s")\n' "$OUTPUT_SCHEMA" >> "$LAUNCHER"
fi

if [ -n "$LAST_MESSAGE" ]; then
  printf '  CODEX_ARGS+=(-o "%s")\n' "$LAST_MESSAGE" >> "$LAUNCHER"
fi

# Append the stdin redirect and the exec call.
cat >> "$LAUNCHER" <<LAUNCHEOF
CODEX_ARGS+=(-)
codex "\${CODEX_ARGS[@]}" < "$PROMPT_FILE"
LAUNCHEOF

chmod +x "$LAUNCHER"

# Run the launcher, optionally under script(1) for PTY workaround.
# DISABLE_PTY=1 lets the owner run before/after tests for issue #19945.
set -o pipefail
SECONDS=0

if [ "$DISABLE_PTY" = "1" ]; then
  bash "$LAUNCHER" 2>&1 \
  | { while IFS= read -r -t "$STALL_SECONDS" line; do
        SECONDS=0
        printf "%s\n" "$line"
      done
      [ "$SECONDS" -ge "$STALL_SECONDS" ] && exit 142
      exit 0
    }
else
  # PTY workaround: re-attach pseudo-TTY via script(1).
  # `script -q /dev/null <cmd>` works on BSD (macOS) and util-linux.
  script -q /dev/null "$LAUNCHER" 2>&1 \
  | { while IFS= read -r -t "$STALL_SECONDS" line; do
        SECONDS=0
        printf "%s\n" "$line"
      done
      [ "$SECONDS" -ge "$STALL_SECONDS" ] && exit 142
      exit 0
    }
fi
EXIT=$?

# Cleanup launcher unless caller passed an explicit RUN_ID (they own the path).
if [ -z "${2:-}" ]; then
  rm -f "$LAUNCHER"
fi

exit $EXIT
