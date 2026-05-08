# longtask — Spec-Driven Multi-Phase Execution Skill for Claude Code

A Claude Code skill that turns a phased spec file into an autonomous execution pipeline.
Each phase runs an ephemeral sub-agent that drives **Codex A (executor) ↔ Codex B (verifier)**
with fresh context and structured PASS/FAIL verdicts — up to N fix→verify rounds, then
escalates to web-search-driven decision before blocking.

---

## Why

LLM coding agents fail at long tasks for two reasons:

1. **Context rot** — the context window fills with stale reasoning halfway through.
2. **Verifier capture** — the same model that wrote the code judges whether it works.

`longtask` solves both:

- **Per-phase fresh sub-agent + per-round fresh Codex prompt** kill context rot.
- **Strict A/B separation** (different prompts, no shared memory, JSON-only verdict against
  the spec's `verify_cmd`) kills verifier capture.

The orchestrator (the Claude Code session) never reads source or runs tests — it only
dispatches sub-agents and tracks state. Sub-agents never expand scope. Codex A only writes
inside the phase's `file_scope`. Codex B only reads artifacts and runs the spec's
`verify_cmd`. Source-of-truth lives in the spec, not in the agents.

---

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

---

## Prerequisites

### Operating system

- **macOS** (tested on Apple Silicon)
- **Linux** (should work; not tested in CI)
- Windows is **not officially supported** — Claude Code on Windows still works, but the
  skill assumes a POSIX shell and `bash`-style heredocs in the prompt skeletons.

### Required runtimes

| Tool | Minimum version | Why |
|------|---|---|
| Claude Code CLI | latest | Skill harness; `Skill` and `Agent` tools; loads `~/.claude/skills/` |
| Codex CLI | recent (supports `codex exec`, `--skip-git-repo-check`, `-c model=...`, `-c model_reasoning_effort=...`) | Phase Conductor's executor / verifier loop |
| `bash` | 4+ | Sub-agent runs `codex exec` via Bash |
| `git` | 2.30+ | sub-agent commits each PASS |
| `timeout` (GNU coreutils) | any | Wraps every `codex exec` (30 min cap). On macOS `brew install coreutils` provides `gtimeout`; ensure your `PATH` exposes it as `timeout` if the shell can't find one |

### Required accounts & access

- **Anthropic account** with Claude Code access — the orchestrator and per-phase sub-agents
  run as Claude `opus`. Get a Pro / Max plan or use a Claude API key with sufficient quota.
  Sign in via `claude auth login` (or by running Claude Code; it'll guide you).
- **OpenAI account** with **Codex CLI** access AND **GPT-5.5** model access — both Codex A
  and Codex B run `codex exec ... -c model="gpt-5.5"` with `model_reasoning_effort="xhigh"`.
  Authenticate via `codex auth login` or by setting `OPENAI_API_KEY`. Verify with
  `codex exec --skip-git-repo-check -c model="gpt-5.5" "say hi"`.

> If you don't yet have GPT-5.5 access, you can edit the model name in `SKILL.md`'s
> `## Codex CLI invocation` section to a model your account supports (e.g. `gpt-5`,
> `gpt-4.1`). The skill is model-agnostic in design — only the verdict format (strict JSON)
> and the fresh-context discipline are load-bearing.

### Optional but recommended

- **[gstack](https://github.com/garrytan/gstack)** — required only if you use the
  `gating:` and `ship:` fields in your spec. Without gstack the skill works exactly as
  before (no gating, no auto-ship); gating list / ship flag default to off.
- **[claude-mem](https://github.com/thedotmack/claude-mem)** — cross-session memory
  capture; helpful when a single longtask spec spans multiple Claude Code sessions.

---

## Install

### 1. Install Claude Code (if you haven't)

Follow [Anthropic's docs](https://docs.anthropic.com/en/docs/claude-code). Verify with:

```bash
claude --version
```

### 2. Install Codex CLI and authenticate

Follow [OpenAI's instructions](https://github.com/openai/codex). Authenticate, then verify:

```bash
codex --version
codex exec --skip-git-repo-check -c model="gpt-5.5" -c model_reasoning_effort="xhigh" "say hi"
```

If the second command returns text, both auth and model access are ready.

### 3. (Optional) Install gstack

Skip this section if you don't plan to use `gating:` or `ship:`.

```bash
# bun is required by gstack's setup script (compiles the /browse binary)
brew install oven-sh/bun/bun

# clone + register
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
cd ~/.claude/skills/gstack && ./setup --quiet
```

### 4. Install the longtask skill

```bash
git clone --single-branch --depth 1 https://github.com/HannibalLeo/longtask-skill.git ~/.claude/skills/longtask
```

Claude Code auto-loads any skill placed under `~/.claude/skills/<name>/SKILL.md`, so the
next session will see `longtask`.

### 5. Verify

Open a fresh Claude Code session in any project directory. Ask:

```
list available skills
```

You should see `longtask` in the output. To smoke-test without committing real code, copy
the inline spec example from `SKILL.md` (`## Spec schema` → "Inline spec example with
gating + ship") into `spec.md`, set `gating: []` and `ship: false`, and run:

```
/longtask spec.md
```

The orchestrator will validate the schema and immediately surface any error if Codex CLI
or auth is misconfigured.

---

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
   for your "ok proceed" between each. Skip this step entirely by setting `gating: []`
   or omitting the field.
2. Spawn a fresh sub-agent for P1; the sub-agent runs Codex A↔B until PASS or BLOCKED.
3. Commit on PASS, write a state JSON at `.longtask/state/spec.json`, then advance.
4. After all phases PASS, invoke `gstack /ship` (push, open PR). Skip by omitting `ship:`.

Without the `gating:` and `ship:` lines, the spec runs with the legacy behavior (P1 starts
immediately, no auto-ship at end) — the new fields are fully backward compatible.

See `SKILL.md` for the full spec schema, prompt skeletons, retry/escalation logic,
state-file format, resume rules (`/longtask <spec> --resume`), and roadmap.

---

## Already have a design doc? Start later in the pipeline

Three common cases when the spec is already mature and you want to skip the front matter:

| You have... | Run | What it does |
|---|---|---|
| A spec, no decision review needed | `/longtask spec.md` (with `gating:` omitted from the spec) | P1→Pn directly, no gating loop. |
| A spec WITH `gating:` declared, but you've already done the design work elsewhere | `/longtask spec.md --skip-gating` | One-shot override: ignore the spec's `gating:` field, jump to P1. Spec stays unchanged. |
| Already implemented P1/P2 by hand, want longtask to drive from P3 onward | `/longtask spec.md --from P3` | Implies `--skip-gating`. Phases before P3 are written as `SKIPPED` in the state file (no commit sha, no rounds). P3 runs as if it were the entry phase. |
| Resuming a previously-blocked run | `/longtask spec.md --resume` | Reads `.longtask/state/<spec>.json`. Skips PASS phases. If state has `gating_cleared_at`, gating is also skipped. |

**`--from <Pn>` does NOT verify that earlier phases' outputs are actually present.** You're
asserting "P1 and P2 are done"; if they aren't, Codex A on P3 will likely fail verification
and fall into the normal retry/escalate flow. Combine with a sanity test (e.g. run the
spec's verify_cmd for P2 manually first) before using `--from`.

Combine flags where useful:

```bash
# spec was carefully reviewed already; jump straight in but with state tracking
/longtask spec.md --skip-gating

# I manually finished P1 and P2; pick up at P3 fresh
/longtask spec.md --from P3

# resumed yesterday's run; if the state already has P3 as PASS, advance to P4
/longtask spec.md --from P3 --resume
```

---

## Cost & rate limits

- Each phase typically runs 1–3 Codex A↔B rounds; each round is 2 `codex exec` calls.
- A 5-phase spec on a small refactor commonly burns 10–30 GPT-5.5 xhigh calls.
- Each phase optionally caps at `cost_budget_usd` (sub-agent stops + asks if exceeded).
- Codex A and B are wrapped in `timeout 1800` (30 min). Exit 124 → counts as one FAIL
  round.
- The Claude orchestrator stays at minimal context (only sees sub-agent return messages),
  so opus token burn on the orchestrator side is small relative to Codex spend.

If you're cost-sensitive, drop `model_reasoning_effort` from `xhigh` to `high` or `medium`
in `SKILL.md`'s Codex invocation section.

---

## Status

- Active personal skill, evolving in production use.
- Quality bar (codified in `SKILL.md`): **simplicity beats cleverness · evals before
  optimization · tight iteration over big leaps · taste is part of "shippable"**.
- Public, but personal — issues / PRs welcome but no SLA on response.

---

## License

MIT — see [`LICENSE`](LICENSE).
