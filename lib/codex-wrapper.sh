#!/usr/bin/env bash
# Stall-only kill wrapper for `codex exec` with PTY workaround.
#
# === Kill model: stall-only ===
# Single rule: 10 min with no new stdout line → kill (exit 142).
# - codex's own token stream IS the progress signal; as long as it's emitting
#   reasoning we let it run (no wall-clock cap).
# - Discriminator: SECONDS resets on every successful read line, then is
#   checked after the read loop exits. SECONDS≥600 means timeout (not EOF).
#   Needed for macOS bash 3.2 where `read -t` returns exit 1 on both timeout
#   AND EOF; only bash 4+ uses >128.
# - "Falsely flagging '10+ min silent then exit 0' as STALL is acceptable" —
#   that pattern is itself a likely hang.
#
# Why no GNU `timeout` envelope: a hard wall-clock cap kills codex even when
# it's actively producing tokens. Owner's intent is "don't strong-kill while
# work is happening" — the previous timeout-600 outer was a bug.
#
# Why no watchdog with active polling + status echoes: codex's own stdout
# is the progress signal. A separate watchdog status line just clutters the
# stream that the verifier has to parse.
#
# === codex#19945 PTY workaround ===
# codex 0.124.0+ (still broken in 0.130.0) silently exits when stdout is not
# a TTY and prompt > ~10KB. Fix: re-attach a pseudo-TTY via `script(1)`.
# `script -q /dev/null <command>` works on both BSD (macOS) and util-linux.
# Refs: https://github.com/openai/codex/issues/19945
#
# Harmless stderr noise: `codex_core::session: failed to record rollout
# items: thread not found` may appear (codex#19945 follow-up). Verifier
# prompts ignore it. Do NOT tighten parsing to fail on this line.
#
# === Stdin requirement ===
# Prompt MUST be passed as a file path (not inline). Long inline prompts
# trigger codex's stdin-pipe hang (see memory feedback_codex_cli_stdin_pipe.md).
#
# === Usage ===
# bash ~/.claude/skills/longtask/lib/codex-wrapper.sh <prompt_file> [run_id]
#
# === Exit codes ===
# 0   → codex finished normally
# 142 → STALL_TIMEOUT (10 min no stdout line)
# *   → CRASH (codex's own non-zero exit, propagated via pipefail)
#
# (No exit 124 — there is no wall-clock cap.)
#
# === Substitute CLI ===
# Replace the codex line in the launcher heredoc. Requirements:
#   (a) stateless one-shot
#   (b) line-buffered stdout
#   (c) stdin-redirectable (`< file`)
# Drop `script -q /dev/null` if your CLI doesn't have the no-TTY bug.

set -u

PROMPT_FILE="${1:-}"
RUN_ID="${2:-$$}"

if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "codex-wrapper.sh: missing or invalid prompt file: ${PROMPT_FILE:-<empty>}" >&2
  echo "usage: $0 <prompt_file> [run_id]" >&2
  exit 2
fi

LAUNCHER="/tmp/codex-launch-${RUN_ID}.sh"

# step 1: write launcher (codex with stdin redirect from prompt file).
# Heredoc unquoted so $PROMPT_FILE expands at write time.
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
codex exec --skip-git-repo-check \\
  -c model="gpt-5.5" \\
  -c model_reasoning_effort="xhigh" \\
  --dangerously-bypass-approvals-and-sandbox \\
  < "$PROMPT_FILE"
LAUNCHEOF
chmod +x "$LAUNCHER"

# step 2: run launcher under script(1) PTY with inline stall detector.
# No outer wall-clock — only stall kills.
set -o pipefail
SECONDS=0
script -q /dev/null "$LAUNCHER" 2>&1 \
| { while IFS= read -r -t 600 line; do
      SECONDS=0
      printf "%s\n" "$line"
    done
    [ $SECONDS -ge 600 ] && exit 142
    exit 0
  }
EXIT=$?

# Cleanup launcher unless caller pinned RUN_ID (they own the path).
if [ -z "${2:-}" ]; then
  rm -f "$LAUNCHER"
fi

exit $EXIT
