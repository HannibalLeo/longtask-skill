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
#      `script -q /dev/null` re-attach is kept, but now selected adaptively:
#      default PTY when stderr is not a TTY, default direct when stderr is a
#      TTY. `CODEX_LONGTASK_DISABLE_PTY=1` forces direct.
#      `CODEX_LONGTASK_FORCE_PTY=1` forces PTY.
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
#   CODEX_LONGTASK_STALL_SECONDS default: 600 (no-output timeout, exit 142)
#   CODEX_LONGTASK_DISABLE_PTY   set to 1 to force direct mode
#   CODEX_LONGTASK_FORCE_PTY     set to 1 to force PTY mode
#   CODEX_LONGTASK_TEST_STDERR_IS_TTY test-only fixture override; do not use
#                                  for production routing decisions.
#
# === Exit codes ===
#   0   codex completed normally
#   2   wrapper usage error (missing / invalid prompt file)
#   142 no output line observed for STALL_SECONDS
#   *   codex non-zero exit, propagated
#
# === Stdin requirement ===
#   Prompt MUST be a file path, not inline.  Long inline prompts trigger
#   codex's stdin-pipe hang (see memory feedback_codex_cli_stdin_pipe.md).
#
set -u

PROMPT_FILE="${1:-}"
RUN_ID="${2:-$$}"
OUTPUT_SCHEMA="${3:-}"
LAST_MESSAGE="${4:-}"

MODEL="${CODEX_LONGTASK_MODEL:-gpt-5.5}"
REASONING="${CODEX_LONGTASK_REASONING:-xhigh}"
SANDBOX="${CODEX_LONGTASK_SANDBOX:-workspace-write}"
APPROVALS="${CODEX_LONGTASK_APPROVALS:-never}"
REPO="${CODEX_LONGTASK_REPO:-}"
DISABLE_PTY="${CODEX_LONGTASK_DISABLE_PTY:-0}"
FORCE_PTY="${CODEX_LONGTASK_FORCE_PTY:-0}"
# Test-only fixture hook: override TTY detection deterministically.
TEST_STDERR_IS_TTY="${CODEX_LONGTASK_TEST_STDERR_IS_TTY:-}"
STALL_SECONDS="${CODEX_LONGTASK_STALL_SECONDS:-600}"

if ! [[ "$STALL_SECONDS" =~ ^[0-9]+$ ]] || [ "$STALL_SECONDS" -le 0 ]; then
  STALL_SECONDS=600
fi

STDERR_IS_TTY=0
if [ "$TEST_STDERR_IS_TTY" = "1" ]; then
  STDERR_IS_TTY=1
elif [ "$TEST_STDERR_IS_TTY" = "0" ]; then
  STDERR_IS_TTY=0
elif [ -t 2 ]; then
  STDERR_IS_TTY=1
fi

MODE="direct"
REASON="stderr_is_tty"
if [ "$FORCE_PTY" = "1" ]; then
  MODE="pty"
  REASON="forced_by_env"
elif [ "$DISABLE_PTY" = "1" ]; then
  MODE="direct"
  REASON="disabled_by_env"
elif [ "$STDERR_IS_TTY" = "1" ]; then
  MODE="direct"
  REASON="stderr_is_tty"
else
  MODE="pty"
  REASON="stderr_not_tty"
fi

printf '[codex-wrapper] mode=%s reason=%s\n' "$MODE" "$REASON" >&2

if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "codex-wrapper.sh: missing or invalid prompt file: ${PROMPT_FILE:-<empty>}" >&2
  echo "usage: $0 <prompt_file> [run_id] [output_schema_json] [last_message_json]" >&2
  exit 2
fi

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

# Run the launcher in direct or PTY mode with no-output stall timeout.
HEARTBEAT_FILE="/tmp/codex-heartbeat-${RUN_ID}.txt"
date +%s > "$HEARTBEAT_FILE"

# Launch in a subshell so timeout kill can terminate the full wrapper command
# tree without leaking late child output after exit 142.
if [ "$MODE" = "pty" ]; then
  (
    script -q /dev/null "$LAUNCHER" \
      > >(while IFS= read -r line; do
            printf "%s\n" "$line"
            date +%s > "$HEARTBEAT_FILE"
          done) \
      2> >(while IFS= read -r line; do
            printf "%s\n" "$line" >&2
            date +%s > "$HEARTBEAT_FILE"
          done)
  ) &
else
  (
    bash "$LAUNCHER" \
      > >(while IFS= read -r line; do
            printf "%s\n" "$line"
            date +%s > "$HEARTBEAT_FILE"
          done) \
      2> >(while IFS= read -r line; do
            printf "%s\n" "$line" >&2
            date +%s > "$HEARTBEAT_FILE"
          done)
  ) &
fi
CHILD_PID=$!

kill_process_tree() {
  local sig="$1"
  local root_pid="$2"
  local child_pids=""
  local child_pid=""

  if command -v pgrep >/dev/null 2>&1; then
    child_pids="$(pgrep -P "$root_pid" 2>/dev/null || true)"
    for child_pid in $child_pids; do
      kill_process_tree "$sig" "$child_pid"
    done
  fi

  kill "-$sig" "$root_pid" 2>/dev/null || true
}

TIMED_OUT=0
while kill -0 "$CHILD_PID" 2>/dev/null; do
  sleep 1
  now_epoch="$(date +%s)"
  last_epoch="$(cat "$HEARTBEAT_FILE" 2>/dev/null || printf '%s\n' "$now_epoch")"
  if [ $((now_epoch - last_epoch)) -ge "$STALL_SECONDS" ]; then
    TIMED_OUT=1
    kill_process_tree TERM "$CHILD_PID"
    kill_process_tree KILL "$CHILD_PID"
    break
  fi
done

if [ "$TIMED_OUT" = "1" ]; then
  wait "$CHILD_PID" 2>/dev/null || true
  EXIT=142
else
  wait "$CHILD_PID"
  EXIT=$?
fi

rm -f "$HEARTBEAT_FILE"

# Cleanup launcher unless caller passed an explicit RUN_ID (they own the path).
if [ -z "${2:-}" ]; then
  rm -f "$LAUNCHER"
fi

exit $EXIT
