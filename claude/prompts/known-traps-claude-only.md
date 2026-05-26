# Known Traps — Claude-only (harness specifics)

> Concatenated with `known-traps-universal.md` by `claude-sub-agent.md` into
> `.longtask/known-traps-active-{spec_basename}.md` once per phase. Claude
> workers `Read` that combined file as their first action.
>
> Codex workers and verifiers do **NOT** receive this file — codex has no
> Agent tool, no 1M context budget, no `/ship` Skill. The traps below are
> specific to the Claude-side longtask implementation and do not apply when
> running the Codex-side pipeline.
>
> Read in conjunction with `known-traps-universal.md`. The categories are
> additive: universal Categories 1–4 (codex CLI quirks, reward hacking, scope
> drift, verifier integrity) plus Category 5 below.

---

## Category 5 — Claude Harness Specifics

**Trap 5.1 — Agent tool background task timeout**
Long-running Agent tool calls (sub-agents) can time out in the Claude harness if the
background task takes too long without emitting output. The heartbeat mechanism in
the sub-agent (writing `last_heartbeat` to state) is the watchdog — ensure every
meaningful step emits a heartbeat. If the Agent tool itself errors (not the sub-agent
logic, but the harness-level dispatch), the orchestrator returns
`BLOCKED_AGENT_TOOL_FAILURE`. This is not the same as a sub-agent returning FAIL.

**Trap 5.2 — Main-session context approaching 1M**
The orchestrator Claude session accumulates context across all steps. At ~80% of 1M
tokens (roughly 800K tokens), the orchestrator should proactively emit
`BLOCKED_CONTEXT_BUDGET` and write a resume checkpoint to the state file. Do not
continue dispatching sub-agents from a degraded context — decision quality degrades
before the hard limit is hit. Resume in a fresh session using the state file.

**Trap 5.3 — codex-wrapper exit 142 = STALL, not implementation failure**
Exit 142 from `codex-wrapper.sh` means no new stdout line for 10 minutes. This is
not evidence that the implementation is wrong or that the worker encountered a test
failure. It means the process stalled (stdin hang, networking, reasoning budget).
Retry once before escalating. Two consecutive 142 exits for the same round →
`BLOCKED_CODEX_WRAPPER_FAILURE`. Never interpret 142 as a code-level FAIL.

**Trap 5.4 — Skill tool (`/ship`) failure requires human review**
When `spec.ship == true`, the orchestrator invokes `gstack /ship` via the Skill tool
at the end of the pipeline. If this call fails, the orchestrator must NOT retry
automatically. The ship step is externally visible and potentially irreversible
(deploys, releases, notifications). Stop, report the failure to the user, and wait
for explicit instruction before retrying.

**Trap 5.5 — `codex exec` wrapper non-zero non-142 exits**
Any non-zero exit from `codex-wrapper.sh` that is NOT 142 (e.g., 1, 2, 127, 130)
indicates a hard wrapper error: missing `codex` binary, invalid flag combination,
permission error, or wrapper script bug. This is `BLOCKED_CODEX_WRAPPER_FAILURE` —
do not retry with the same command. Inspect the wrapper invocation, verify `codex`
is on PATH, and check the wrapper's own stderr before retrying.
