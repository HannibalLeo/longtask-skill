# longtask — Spec-Driven Multi-Phase Execution Skill for Claude Code

A Claude Code skill that turns a phased spec file into an autonomous execution pipeline.
Each phase runs an ephemeral sub-agent that drives **Codex A (executor) ↔ Codex B (verifier)**
with fresh context and structured PASS/FAIL verdicts — up to N fix→verify rounds, then
escalates to web-search-driven decision before blocking.

## Why

LLM coding agents fail at long tasks for two reasons:
1. **Context rot** — the context window fills with stale reasoning halfway through.
2. **Verifier capture** — the same model that wrote the code judges whether it works.

`longtask` solves both:
- **Per-phase fresh sub-agent + per-round fresh Codex prompt** kill context rot.
- **Strict A/B separation** (different prompts, no shared memory, JSON-only verdict against
  spec's `verify_cmd`) kills verifier capture.

The orchestrator (this Claude Code session) never reads source or runs tests — it only
dispatches sub-agents and tracks state. Sub-agents never expand scope. Codex A only writes
inside the phase's `file_scope`. Codex B only reads artifacts and runs the spec's
`verify_cmd`. Source-of-truth lives in the spec, not in the agents.

## Architecture

```
You (this session, opus)         = Main Orchestrator
  ↓ Agent tool, one phase at a time
Sub-Agent (opus, fresh per phase) = Phase Conductor
  ↓ Bash → codex exec, sequence + retry loop
Codex A (executor)  ←→  Codex B (verifier, fresh context)
```

| Tier | Reads files? | Writes code? | Commits? | Persistence |
|------|---|---|---|---|
| Orchestrator | spec + state file + sub-agent reports | NO | NO | survives whole spec |
| Sub-Agent | spec + git diff + test output + state file | NO (only authors codex prompts) | YES (after B PASS) | per phase, killed on DONE |
| Codex A | spec + scoped files | YES (working tree only) | NO | one-shot per round |
| Codex B | spec + working tree + tests | NO | NO | one-shot per round |

## Install

```bash
git clone --single-branch --depth 1 https://github.com/HannibalLeo/longtask-skill.git ~/.claude/skills/longtask
```

The next Claude Code session will auto-load the skill from `~/.claude/skills/longtask/SKILL.md`.

### Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (or any harness honoring `~/.claude/skills/`)
- [OpenAI Codex CLI](https://github.com/openai/codex) — `codex exec` available, GPT-5.5 access
- Optional but recommended: [gstack](https://github.com/garrytan/gstack) installed (for the
  `gating` and `ship` integration hooks documented in `SKILL.md`)

## Quick start

Write a spec file at `<repo>/spec.md`:

```markdown
---
gating: [office-hours, plan-ceo-review, plan-eng-review]
ship: true
---

# P1: Add /healthz endpoint
goals: Expose `GET /healthz` returning `{"status":"ok"}` with 200 and no auth.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, src/db/**]
inputs: []
outputs: [src/routes/health.ts (registered in app router)]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and 0 failures"
max_retry_rounds: 3
```

Then in Claude Code:

```
/longtask spec.md
```

The orchestrator will:
1. Run the gating skills (`office-hours`, `plan-ceo-review`, `plan-eng-review`) and wait
   for your "ok proceed" between each.
2. Spawn a fresh sub-agent for P1; sub-agent runs Codex A↔B until PASS or BLOCKED.
3. Commit on PASS, write a state JSON, then advance.
4. After all phases PASS, invoke `gstack /ship` to push and open the PR.

Without the `gating:` and `ship:` lines, the spec runs with the legacy behavior (P1 starts
immediately, no auto-ship at end) — the new fields are fully backward compatible.

See `SKILL.md` for the full spec schema, prompt skeletons, retry/escalation logic,
state-file format, resume rules, and roadmap.

## Status

- Active personal skill, evolving in production use.
- Quality bar (codified in `SKILL.md`): simplicity beats cleverness · evals before
  optimization · tight iteration over big leaps · taste is part of "shippable".

## License

MIT — see `LICENSE`.
