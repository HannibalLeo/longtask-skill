---
name: longtask
version: 0.0.3
description: Use when a user provides a written phased spec and wants unattended execution, durable resume, phase-by-phase verification, or production-grade completion instead of a best-effort patch.
---

# /longtask

Run a written phased spec through Codex **native subagents** without letting the
parent chat become the place where implementation context accumulates.

The parent Codex session is the **conductor**: it parses the spec, keeps state,
spawns fresh worker/verifier subagents, enforces git-based scope checks, commits
verified phases, and reports only compact evidence. Worker and verifier agents
carry the heavy code context. This keeps the parent sharp without making it
blind.

`codex exec` is not the default path. It is a fallback for CI or environments
where native subagents are unavailable.

## When to Use

Use this skill when all are true:

- A written spec has phases named `P1`, `P2`, ...
- The task is too large for one tightly-coupled edit.
- The user wants no confirmation prompts between phases.
- Completion must mean scoped, verified, committed work.

Skip for quick questions, small single-file edits, reviews, or brainstorming.

## Core Invariants

- **Parent stays low-context.** It may read the spec, state JSON, changed file
  list, diff stat, verifier report, blocked report, and final commit list. It
  does not read full implementation files during normal execution.
- **Native subagents do the heavy work.** Each worker/verifier starts fresh.
- **Worker and verifier are separated.** The verifier gets no worker reasoning,
  only the spec, changed files, diff, and verification output.
- **Git is the source of truth.** Scope is enforced with `git status` and
  `git diff`, not by trusting prompts.
- **No hidden shipping.** Push/PR/deploy are separate explicit workflows after
  all phases pass.
- **Stop on hard risk.** Scope violation, malformed verifier output, repeated
  FAIL, dirty unexpected files, or security concern stops the run.

## Model and Reasoning Policy

Native subagents inherit the parent model/reasoning by default. Do not rely on
that default for longtask. The conductor should choose cheaper reasoning first
and escalate only when evidence says the task needs it.

Default policy:

| Role | First choice | Escalate when |
|---|---|---|
| worker | same model family as parent, `medium` reasoning | verifier FAIL twice for non-trivial root cause |
| retry worker | `medium`, then `high` after repeated FAIL | architecture ambiguity, cross-module refactor, security-sensitive code |
| verifier | `medium` reasoning | verifier JSON inconsistent, tests ambiguous, reward-hacking suspicion |
| final reviewer | `high` reasoning | always for multi-phase specs before declaring complete |
| xhigh | avoid by default | only for repeated BLOCKED, data-loss/security risk, or user explicitly asks |

For verification, two independent `medium` verifier passes with different
prompts are often a better use of budget than one `xhigh` pass. Use this pattern
for risky phases:

1. **Spec verifier** checks phase goals, `verify_cmd`, DoD, and reward-hacking.
2. **Quality/security verifier** checks regression risk, unsafe side effects,
   scope drift, and maintainability.

Do not run every phase at `gpt-5.5` + `high/xhigh` by habit. High reasoning is
an escalation tool, not the baseline.

## Spec Schema

Top-level frontmatter is optional:

```yaml
---
final_verify_cmd: "npm test && npm run build"
final_smoke_cmd: "npm run test:e2e -- reading-room.spec.ts"
# If there is intentionally no final gate, write this explicitly:
# final_gate: none
---
```

`final_verify_cmd` or `final_smoke_cmd` is required unless the spec explicitly
sets `final_gate: none`. A longtask without a final gate is not silently treated
as complete.

`verify_cmd`, `final_verify_cmd`, and `final_smoke_cmd` must not push, open PRs,
deploy, mutate infrastructure, or perform externally visible actions. Shipping
is a separate workflow requiring explicit user intent.

Each phase is a markdown heading beginning with `P1`, `P2`, etc.

Required fields:

```yaml
goals: one sentence describing what this phase must achieve
file_scope: [src/path/**, tests/path/test_file.py]
do_not_touch: [src/auth/**, .env*, data/**]
verify_cmd: "pytest tests/path/test_file.py -v"
verify_passes_when: "exit 0 and the named regression tests pass"
```

Optional fields:

```yaml
inputs: [P1 commit, generated artifact]
outputs: [symbol or file expected by later phases]
max_retry_rounds: 3
```

Keep phases small. If a verifier failure would not tell the next worker exactly
where to focus, split the phase.

## Native Subagent Loop

For each phase:

1. Validate required fields and initialize/update
   `.longtask/state/<spec_basename>.json`.
2. Spawn one **worker** subagent for the phase:
   - give it the phase block, `file_scope`, `do_not_touch`, relevant prior
     outputs, and `prompts/worker.md`
   - assign ownership of only the phase files
   - tell it there may be other agents in the workspace
   - require it to edit files directly, not commit, and list changed paths
   - require its final message to be the worker JSON described in
     `prompts/worker.md`; `BLOCKED_*` stops the phase
3. Wait for the worker.
4. Parent runs a lightweight hard gate:
   - `git status --porcelain=v1`
   - `git diff --name-only HEAD`
   - reject changes outside `file_scope`
   - reject changes inside `do_not_touch`
   - ignore `.longtask/**` artifacts and the spec file itself
5. Spawn one fresh **verifier** subagent:
   - give it `prompts/verifier.md`, the phase block and changed path list
   - tell it to run `git diff HEAD -- <changed-paths>` itself inside the
     subagent context; the parent does not paste large diffs
   - require it to run `verify_cmd` literally
   - require structured JSON matching
     `schemas/verifier-result.schema.json`
   - forbid edits, staging, and commits
6. Parent checks the verifier did not mutate the worktree.
7. Parent extracts exactly one JSON object from the verifier final message,
   validates it against `schemas/verifier-result.schema.json`, and writes it to
   `.longtask/reports/<spec>/<Pn>-r<N>-verdict.json`. Schema failure is
   `VERIFIER_SCHEMA_INVALID`.
8. PASS requires:
   - `verdict == "PASS"`
   - `verify_cmd_exit == 0`
   - every `dod_results[].passed == true`
   - `reward_hacking_signals == []`
9. On PASS, parent commits only phase files:
   `git add -- <changed-files>` then
   `git commit -m "[longtask:<spec>:<Pn>] <goal>"`.
10. On FAIL, spawn a new worker subagent with
    `prompts/retry-worker.md`, verifier JSON, and changed path list. The retry
    worker runs its own targeted `git diff`. Retry up to `max_retry_rounds`.
11. If still failing, write
    `.longtask/reports/<spec>/<Pn>-blocked.md` and stop.

For high-risk phases, spawn a second verifier before commit using the
quality/security verifier role from the model policy. Commit only if both
verifiers pass.

State should record native evidence, not just phase names:

- `mode: "native-subagents"`
- `base_head`
- `agents[]` with `agent_id`, role, phase, round, start/end time
- `pre_status` and `post_status`
- changed files and diff stat
- verifier artifact path or verifier final JSON
- integration commit
- blocked reason, if any

The parent can continue this loop unattended. It does not ask the user between
phases.

## Final Verification

After all phases pass:

1. Run `final_verify_cmd` or `final_smoke_cmd`.
2. If neither exists and `final_gate: none` was not explicit, stop as BLOCKED.
3. Update `.longtask/state/<spec>.json`.
4. Stop before push/PR/deploy unless the user separately invokes a shipping
   workflow.

Browser QA should be an explicit command when possible, for example Playwright.
If a project needs visual gstack QA, the verifier must still return a compact
structured report and screenshot paths under `.longtask/reports/<spec>/`.

## Resume

State file:

```json
{
  "spec_path": "...",
  "spec_sha256": "...",
  "started_at": "...",
  "phases": {
    "P1": {
      "status": "PASS",
      "rounds": 1,
      "commit": "abc123",
      "changed_files": ["..."],
      "verdict": ".longtask/reports/spec/P1-r1-verdict.json"
    }
  }
}
```

Native resume protocol:

1. Read `.longtask/state/<spec>.json`.
2. Verify `spec_sha256` still matches the spec. If not, stop and require a
   restart.
3. For every phase marked `PASS`, verify its commit still exists with
   `git cat-file -e <commit>^{commit}`.
4. Verify the worktree has no unrelated dirty files. Pending files recorded in a
   non-PASS phase may be retried; any new dirty file blocks resume.
5. Skip verified PASS phases.
6. Restart the first non-PASS phase with fresh worker/verifier subagents.
7. Append new `agents[]` entries instead of mutating old evidence.

## Fallback Runner

`lib/longtask-runner.py` and `lib/codex-wrapper.sh` remain as a fallback for CI
or terminal-only environments. They are not the preferred Codex app path. Do not
choose them when native subagents are available.

Fallback command:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo .
```

Use fallback only when:

- the user explicitly asks for CLI/CI automation, or
- native subagents are unavailable in the current environment.

## Files

| File | Purpose |
|---|---|
| `prompts/worker.md` | Worker subagent contract |
| `prompts/retry-worker.md` | Retry worker prefix |
| `prompts/verifier.md` | Verifier subagent contract |
| `prompts/conductor.md` | Parent conductor checklist |
| `schemas/verifier-result.schema.json` | Verifier JSON contract |
| `lib/longtask-runner.py` | Deprecated fallback runner for CI/CLI |
| `lib/codex-wrapper.sh` | Deprecated fallback wrapper for CI/CLI |

## Known Limits

- Native subagent file integration depends on the current Codex environment.
  The parent must verify actual git diff before committing.
- The fallback runner has a simple phase parser; avoid complex YAML there.
- This skill does not push, open PRs, or deploy.
