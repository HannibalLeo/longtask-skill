# longtask

`longtask` is a Codex-native skill for executing a written, multi-phase spec.

Use it when you have already split a larger task into phases such as `P1`,
`P2`, and `P3`, and you want Codex to keep working with limited supervision:
implement each phase, verify it independently, commit recoverable checkpoints,
and stop with evidence when risk gets too high.

The goal is not "let the model try." The goal is a bounded, verified, resumable
execution pipeline.

## Problem

Long agentic tasks tend to fail in predictable ways:

- The parent chat accumulates too much context and judgment degrades.
- Implementation and verification happen in the same context.
- There are no clean checkpoints, so recovery is messy.
- Tests pass while code drifts out of scope, weakens tests, or breaks the full
  product flow.

`longtask` keeps the parent session small and makes fresh subagents do the heavy
work. Every phase must pass git scope checks, independent verification, the
phase test command, and a final integration gate.

## How It Works

The default path uses Codex native subagents. It does not default to
`codex exec`.

For each phase:

1. The parent session reads the phase from the spec.
2. The parent starts a worker subagent.
3. The worker implements only inside `file_scope` and does not commit.
4. The parent checks the actual git changes and rejects out-of-scope edits.
5. The parent starts a fresh verifier subagent.
6. The verifier only verifies, runs `verify_cmd`, and returns structured JSON.
7. The parent validates the verifier result and confirms the worktree was not
   mutated by the verifier.
8. On PASS, the parent commits only the current phase files.
9. On FAIL, the parent gives verifier evidence to a retry worker; after the
   retry limit, it stops and writes a blocked report.

The parent keeps low context: spec, state, changed file list, diff stat,
verifier JSON, blocked reports, and commit list. Full source files and large
diffs are loaded only for debugging.

## Roles

| Role | Responsibility |
| --- | --- |
| Conductor | Parent session. Parses the spec, starts subagents, gates changes, commits, resumes. |
| Worker | Implements the current phase. Edits allowed files only. Does not commit. |
| Verifier | Independently verifies the current phase. Runs tests, checks DoD, checks reward-hacking. |
| Final reviewer | Reviews cross-phase risk after all phases pass. |

Reasoning level should be deliberate. Workers and verifiers usually start at
`medium`; repeated failures or final review can escalate to `high`; `xhigh` is
reserved for repeated blocked states, security risk, or data-loss risk.

## Spec Format

A spec is a normal Markdown file. Each phase starts with a heading such as `P1`
or `P2`.

```markdown
---
final_verify_cmd: "npm test && npm run build"
final_smoke_cmd: "npm run test:e2e -- reading-room.spec.ts"
---

# P1: Add health endpoint
goals: Add GET /healthz returning status ok.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, .env*]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and health endpoint tests pass"
max_retry_rounds: 3
```

Required fields:

- `goals`: what the phase must accomplish.
- `file_scope`: paths the worker may edit.
- `do_not_touch`: paths that must not be edited.
- `verify_cmd`: command the verifier must run.
- `verify_passes_when`: objective pass criteria.

A final integration gate is expected. Prefer `final_verify_cmd` or
`final_smoke_cmd`. If there is intentionally no final gate, write
`final_gate: none`; otherwise longtask treats the missing gate as a risk.

## Running and Resuming

In the Codex app, triggering `longtask` uses the native subagent workflow. State
is written to:

```text
.longtask/state/<spec>.json
```

On resume, longtask reads the state, verifies the spec hash, verifies commits
for completed phases, checks the worktree, and restarts from the first phase
that is not marked PASS.

## Stop Conditions

Longtask stops instead of papering over these cases:

- The spec is missing required fields or the phase is ambiguous.
- The worker asks to expand `file_scope`.
- Actual changes are outside `file_scope` or inside `do_not_touch`.
- The verifier mutates the worktree.
- The verifier output is malformed or inconsistent.
- Tests fail or DoD checks fail.
- `verify_cmd` or final commands try to push, open a PR, deploy, or mutate
  infrastructure.
- Final integration verification fails.

Blocked reports are written under `.longtask/reports/<spec>/...` so the task can
be resumed after the spec or code is fixed.

## CLI Fallback

`lib/longtask-runner.py` is a fallback for CI or terminal-only environments
without native subagents. It is not the default Codex app path.

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo .
```

Validate only:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --dry-run
```

Resume:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --resume
```

## Files

| File | Purpose |
| --- | --- |
| `SKILL.md` | Skill operating contract |
| `prompts/conductor.md` | Parent-session checklist |
| `prompts/worker.md` | Worker subagent prompt |
| `prompts/retry-worker.md` | Retry worker prompt |
| `prompts/verifier.md` | Verifier subagent prompt |
| `schemas/verifier-result.schema.json` | Verifier output schema |
| `lib/longtask-runner.py` | CLI fallback runner |
| `lib/codex-wrapper.sh` | CLI fallback wrapper |
