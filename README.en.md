# longtask

Codex-native long-task skill: given a written phased spec, the parent session
acts as conductor and coordinates native subagents for implementation and
independent verification.

The `codex exec` runner is CI/CLI fallback only. It is not the default Codex app
path.

## Default Path: Native Subagents

Per phase:

1. Parent reads the phase and `.longtask/state/<spec>.json`.
2. Parent spawns one worker subagent with `prompts/worker.md`.
3. Worker edits only `file_scope`; it does not stage or commit.
4. Parent enforces git hard gates: changed files must be inside `file_scope`
   and outside `do_not_touch`.
5. Parent spawns one fresh verifier subagent with `prompts/verifier.md`.
6. Verifier only verifies and returns schema-compatible JSON.
7. On PASS, parent commits only changed phase files.
8. On FAIL, parent retries with `prompts/retry-worker.md`.

The parent keeps low context: spec, state, changed files, diff stat, verifier
JSON, blocked reports, and commit list.

Do not let all subagents inherit expensive high reasoning. Recommended default:
worker/verifier at `medium`, repeated failures or final reviewer at `high`, and
`xhigh` only for repeated BLOCKED, security, or data-loss risk. For risky phases,
prefer two independent `medium` verifier passes over one `xhigh` verifier.

## Minimal Spec

```markdown
---
final_verify_cmd: "npm test && npm run build"
final_smoke_cmd: "npm run test:e2e -- reading-room.spec.ts"
# final_gate: none  # only when deliberately skipping final integration gate
---

# P1: Add health endpoint
goals: Add GET /healthz returning status ok.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, .env*]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and health endpoint tests pass"
max_retry_rounds: 3
```

## Fallback Runner

Use only when native subagents are unavailable or the user explicitly asks for
CLI/CI automation:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo .
```

Dry run:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --dry-run
```

Resume:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --resume
```

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | Skill entrypoint and operating contract |
| `prompts/conductor.md` | Parent conductor checklist |
| `prompts/worker.md` | Worker subagent prompt |
| `prompts/retry-worker.md` | Retry worker prefix |
| `prompts/verifier.md` | Verifier subagent prompt |
| `schemas/verifier-result.schema.json` | Verifier output schema |
| `lib/longtask-runner.py` | Fallback runner |
| `lib/codex-wrapper.sh` | Fallback `codex exec` wrapper |

## Pressure Scenarios

At minimum, verify:

- untracked spec can run and is not committed
- worker asks to widen `file_scope`
- worker modifies `do_not_touch`
- verifier tries to edit files
- verifier returns PASS while tests fail
- no final gate and no explicit `final_gate: none`
- `verify_cmd` or final commands contain push/PR/deploy
- fallback runner is not mistaken for the default path
