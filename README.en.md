# longtask — Spec-Driven Multi-Phase Execution Skill for Claude Code

[简体中文](README.md) · **English**

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

### Required accounts & access (author's reference setup)

> **Author's reference setup = Claude (orchestrator + sub-agent) + Codex (A and B), two models.** But the skill is **model-agnostic by design** — the only two invariants that matter are ① fresh context per round, and ② strict JSON verdict against the spec's `verify_cmd`. **Single-model setups work fine**; see "Single-model setup" below.

For the reference setup:

- **Anthropic account** with Claude Code access — the orchestrator and per-phase sub-agents
  run as Claude `opus`. Get a Pro / Max plan or use a Claude API key with sufficient quota.
  Sign in via `claude auth login` (or by running Claude Code; it'll guide you).
- **OpenAI account** with **Codex CLI** access AND **GPT-5.5** model access — both Codex A
  and Codex B run `codex exec ... -c model="gpt-5.5"` with `model_reasoning_effort="xhigh"`.
  Authenticate via `codex auth login` or by setting `OPENAI_API_KEY`. Verify with
  `codex exec --skip-git-repo-check -c model="gpt-5.5" "say hi"`.

If you don't yet have GPT-5.5 access, you can edit the model name in `SKILL.md`'s `## Codex CLI invocation` section to a model your account supports (e.g. `gpt-5`, `gpt-4.1`). The dual-role A↔B loop is unchanged.

### Single-model setup (optional)

`longtask` does NOT require Claude + Codex specifically. The two **load-bearing invariants** are:

1. **Fresh context per round** — both A's and B's prompts are freshly composed; no shared memory across rounds.
2. **Strict JSON verdict against `verify_cmd`** — B does not "read code and decide freely"; it runs the spec's command and returns a fixed-schema JSON.

As long as those two hold, A and B can run on **any** model — single-model setups work just as well. The reason is that fresh context is enforced at the **prompt** layer, not at the model layer. Even if A and B are the same model, B's prompt contains only the spec + working tree + `verify_cmd` output — **none of A's reasoning chain leaks through**. Verifier capture is cut off by prompt construction, not by model heterogeneity.

Heterogeneous models (the author's Claude + Codex pairing) give you a bonus: **cross-model verification** is harder to fool — B's failure modes don't match A's. But this is a strength booster, not a correctness requirement.

#### Common alternative combinations

**Claude-only (you only have an Anthropic plan)**

- Orchestrator + sub-agent stay on Claude Code (no change).
- Replace the command in `SKILL.md`'s `## Codex CLI invocation` section with:

  ```bash
  timeout 1800 claude --print --model claude-sonnet-4-5 "<A or B prompt>"
  ```

- Same command for both A and B; only the prompts differ. Fresh context still holds.
- The strict-JSON output requirement is enforced in B's prompt skeleton (any malformed output → `VERIFIER_MALFORMED_OUTPUT` ESCALATE), so it doesn't depend on the model having a native JSON mode.

**Codex-only (you have OpenAI but no Anthropic plan)**

- Not recommended — Claude Code's `Skill` / `Agent` tools are a load-bearing dependency for the orchestrator. If you have no Anthropic at all, the better path is **Claude Code Pro for orchestrator + sub-agent, codex for A / B** (which is the author's reference setup).
- A truly Codex-only setup would require rewriting the orchestrator and sub-agent as external shell scripts driving codex; that's outside the scope of this skill's defaults.

**Gemini / any other stateless one-shot CLI**

- Replace the command in the Codex CLI invocation section with the equivalent CLI (`gemini`, `llm`, etc.). Same principle: every invocation is a stateless one-shot, called via Bash.
- Avoid CLIs that **carry conversation history by default** — that breaks the fresh-context invariant.

#### Picking a setup

- Solo dev, lowest barrier to entry: **Claude-only (sonnet or opus)** — one account, one auth, works.
- Strongest cross-model verification: the author's reference setup (Claude `opus` orchestrator + Codex `gpt-5.5 xhigh` A/B).
- Whichever combination you pick, **a tightly-written `verify_cmd` matters far more than picking the strongest model**. Long-task failures almost always trace back to a sloppy spec, not to insufficient model capability.

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

## Relationship to Superpowers / GSD / the three-stack workflow

`longtask` is **not** a dependency of [Superpowers](https://github.com/obra/superpowers)
or [GSD (get-shit-done)](https://github.com/gsd-build/get-shit-done), and neither tool
depends on `longtask`. The only Claude-Code skill `longtask` calls out to is
[gstack](https://github.com/garrytan/gstack), and only when you opt in via the spec's
`gating:` / `ship:` fields. Everything else is independent.

That said, the four projects share intellectual ancestry. Each owns a different layer:

| Layer | Tool | What it owns |
|-------|------|--------------|
| Decisions / product planning | gstack `/office-hours`, `/plan-ceo-review`, `/plan-eng-review` | "Are we building the right thing?" |
| Spec phasing | GSD `/gsd-discuss-phase`, `/gsd-plan-phase` | "How do we slice the work into context-safe chunks?" |
| Execution discipline | Superpowers `/test-driven-development`, `/using-git-worktree`, `/subagent-driven-development` | "How do we write the code without skipping verification?" |
| **Phase-level execution** | **`longtask`** (this skill) | "Run THIS spec, with strict A/B verifier separation, until each phase passes." |
| Shipping | gstack `/ship`, Superpowers `/finishing-development-branch` | "Open the PR cleanly." |

`longtask` **internalizes** two of these ideas without calling the external tools:

- **GSD's "slice into phases"** — your spec already has P1/P2/P3, and each phase gets a
  fresh sub-agent. You don't run GSD inside `/longtask`.
- **Superpowers' "verify-first" discipline** — Codex B is a strict, fresh-context verifier
  that judges artifacts against `verify_cmd`. You don't run Superpowers' TDD loop inside
  `/longtask`.

The integration points that `longtask` does expose are explicit and minimal: only `gating:`
(pre-P1 decision skills) and `ship:` (post-Pn shipping). Both default to off.

### When to use what

- **No spec yet** → run gstack `/office-hours` + `/plan-ceo-review` + `/plan-eng-review`
  (or GSD `/gsd-discuss-phase`) to think the design through, then write `spec.md`.
  `longtask` does not help with the un-thought-through stage on purpose.
- **Phasing is unclear** → GSD's phase-discussion flow is the right place; drop the
  resulting structure into `spec.md` and run `/longtask`.
- **Spec is finished, just execute it** → `longtask` is the executor. Use `--skip-gating`
  if you already did the design work outside the skill.
- **Want gating + shipping bundled** → `/longtask spec.md` with both `gating:` and `ship:`
  declared.

### Do I need all four on the same machine?

If you're doing greenfield product work and want the YouTube-demoed
"Claude-headless + Ralph-Loop" 16-step pipeline, yes — Superpowers + GSD + gstack +
`longtask` cover the full Think → Plan → Execute → Ship arc.

If you already have a workflow you trust and `longtask` alone covers it, no — the four
stacks are complementary, not required together. They live in different skill
namespaces and don't compete for the same trigger words.

---

## Hang protection: idle timeout + verifier integrity check

Two failure modes show up after enough production use, both worth understanding
before they bite:

**1. Verifier inconsistency** — Codex B occasionally returns `verdict: "FAIL"`
while every entry in `dod_results[*].passed` is `true` (or the inverse). The
verdict and the AC list contradict each other. This is almost always a sign
that `verify_passes_when` is poorly worded, not that the code is wrong; the next
retry round generates more of the same contradiction.

The sub-agent now runs an integrity check on B's JSON before trusting the
verdict. Any of these mismatches **immediately ESCALATE** — no retries spawned:

- `VERIFIER_INCONSISTENT_FAIL_BUT_AC_PASS`
- `VERIFIER_INCONSISTENT_PASS_BUT_AC_FAIL`
- `VERIFIER_MALFORMED_OUTPUT` (missing or empty `dod_results`)

The escalation report includes B's full JSON so you can decide whether to
tighten `verify_passes_when`, rewrite the offending DoD bullet, or relax
`verify_cmd`.

**2. Sub-agent silent hang** — between Codex CLI calls the sub-agent runs its
own Bash + reasoning steps. Without a watchdog, a stuck sub-agent can sit idle
for an hour while every individual `codex exec` invocation has long since
finished or timed out. The new `idle_timeout_minutes` field (default **10**)
puts a heartbeat-based watchdog in place:

- Every progress boundary (round start, Codex A start/done, Codex B start/done,
  commit, BLOCKED return) writes a heartbeat to
  `.longtask/state/<spec>.json` under `phases.<Pn>.last_heartbeat` plus the
  `heartbeats[]` audit trail.
- At every round transition the sub-agent checks `now - last_heartbeat`. If
  the gap exceeds `idle_timeout_minutes`, it returns
  `BLOCKED reason="IDLE_TIMEOUT"` immediately, attaching the heartbeat tail.
- This is an **idle** timeout, not a hard wall clock. As long as the sub-agent
  keeps emitting progress (one heartbeat per round transition), the timer
  resets. Real long work renews itself; only true hangs trip the watchdog.

The default 10 minutes is deliberately tight — long-running Codex executions
themselves are already capped at 30 min by `timeout 1800`, so the only thing
that should ever exceed 10 minutes between heartbeats is a stuck sub-agent.
Bump per phase only when you observe a real reason to.

```yaml
# spec phase override
idle_timeout_minutes: 20   # only if you've measured a legitimate need
```

When `IDLE_TIMEOUT` triggers, the report's `heartbeats[]` tail tells you
exactly where the gap opened (between which two events). That's almost always
enough to diagnose whether the spec needs a fix or a simple `--resume` is safe.

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
