---
name: longtask
description: Multi-phase spec execution pipeline. Spawns a no-code orchestrator (this session) that dispatches one ephemeral sub-agent per phase (P1, P2, P3...); each sub-agent runs Codex A (executor) ↔ Codex B (verifier, fresh context) via `codex exec` with GPT-5.5 xhigh, up to N fix→verify rounds, web-search decision, then escalates. Use when there is a written spec file with phased work and strict separation of executor/verifier is desired. Triggers on /longtask, "execute this spec", "run the spec", "long task", "长任务", "spec 文件执行".
---

> **Quality bar — non-negotiable.** No hidden defects. No minimal patches that paper over symptoms. Every decision serves "this ships to real users", not "the test happens to be green".

> **The 4 production-grade principles** — this skill's operational interpretation, aligned with the spirit of [Karpathy's engineering style](https://github.com/forrestchang/andrej-karpathy-skills). Phrasing below is mine; treat as the working standard for THIS skill, not a quotation:
>
> 1. **Simplicity beats cleverness.** Prefer boring straightforward code that any reader can grep once and understand. If a layer of indirection can be deleted without losing function, delete it. Three similar lines beat a premature abstraction.
> 2. **Evals before optimization.** What cannot be measured cannot be improved. Every phase's `verify_cmd` makes PASS/FAIL mechanical, not narrative — "looks right to me" is not allowed.
> 3. **Tight iteration over big leaps.** Three small verifiable changes beat one large change that's right "in principle". The 3-round A↔B loop exists for this. If a phase needs a 500-line diff to verify, the phase is too coarse — split it.
> 4. **Taste is part of "shippable".** A green test does not mean production-ready. Read the diff at the end of each phase. Ugly code that passes is the next phase's pothole; naming, structure, and discipline are part of the bar.

# /longtask — Spec-Driven Multi-Phase Execution

## When to use

Use when ALL of: a written spec file declares phased work (P1, P2, P3...); task is M/L (>5 min, multi-step); user wants Codex CLI to do the bulk of code work with strict executor/verifier separation.

**Recommended starting point** when the spec does not yet exist: run `gstack /office-hours` to interrogate the idea, then `gstack /plan-ceo-review` + `gstack /plan-eng-review` to lock product/architecture decisions, then write the spec from those artifacts. Long tasks usually fail because the spec is wrong, not because Codex cannot code. The optional `gating:` field below lets the spec itself enforce that flow.

Skip for: <5 min tasks; single-file edits where verifying is "read the diff".

## Spec schema (REQUIRED — orchestrator validates at step 1)

Both Codex A and Codex B use the same fixed CLI command (`gpt-5.5 + xhigh` — see `## Codex CLI invocation`); the spec does NOT parameterize models. Cross-check comes from fresh context (B has no memory of A) + structured JSON verdict against the spec's `verify_cmd`.

**Top-level (spec metadata, optional, default = empty / false)**:

```yaml
gating: [office-hours, plan-ceo-review, plan-eng-review]
# Optional. Skill names the orchestrator MUST invoke before P1 starts. Each is run
# via the Skill tool in order; the user must explicitly confirm "ok proceed" (or
# equivalent) before the next gate runs and before P1 begins. Empty / omitted →
# no gating, P1 starts immediately. Default skills assume gstack is installed;
# substitute project-specific skills (e.g. ["socratic-design"]) or set [] to opt
# out entirely.

ship: true
# Optional. After ALL phases reach PASS, orchestrator invokes `gstack /ship` to
# detect the base branch, run tests, bump VERSION, commit, push, and open the PR.
# A failure inside /ship does NOT roll back phase commits — the orchestrator
# surfaces the error and waits for the user to decide. Omitted / false → stop at
# the summary table (legacy behavior, fully backward compatible).
```

**Per phase block** (one block per Pn heading):

```yaml
# Pn (heading)
goals: <what this phase achieves>
file_scope: [paths Codex A may touch]
do_not_touch: [paths Codex A must NOT modify, even if related]
inputs: [artifacts/sha/symbols required from prior phases]   # may be empty for P1
outputs: [artifacts produced for downstream phases]           # may be empty for last phase
verify_cmd: "<exact shell command B runs, e.g. 'pytest tests/p1_*.py -v'>"
verify_passes_when: "<concrete predicate, e.g. 'exit 0 and 0 failures in output'>"
max_retry_rounds: 3                                           # default 3, bump for big refactors
cost_budget_usd: 5                                            # optional; sub-agent stops + asks if exceeded
idle_timeout_minutes: 10                                      # optional, default 10. anti-hang watchdog
```

Missing required field → orchestrator STOPs, points at line/phase, no codex invocation.

**`idle_timeout_minutes` semantics** — this is an **idle** timeout, not a hard wall-clock cap. The sub-agent stamps a heartbeat to the state file at every progress boundary (round start, Codex A start/done, Codex B start/done, commit, BLOCKED return). At every round transition it checks `now - last_heartbeat`; if the gap exceeds `idle_timeout_minutes`, it returns `BLOCKED reason="IDLE_TIMEOUT"` immediately. While the sub-agent is making progress (each progress line resets the timer), it can run as long as it needs. This protects against the "1-hour silent hang" failure mode where a sub-agent gets stuck in internal reasoning between rounds without timing out any single `codex exec` call.

The timeout does NOT cover Codex CLI execution itself — `codex exec` is already wrapped in `timeout 1800` (30 min hard cap). The two layers compose: codex's hard cap protects against a stuck CLI; the idle timeout protects against a stuck sub-agent.

**Inline spec example with gating + ship**:

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

When this spec runs:
1. Orchestrator runs `office-hours` → `plan-ceo-review` → `plan-eng-review` (each waits for user confirm).
2. P1 runs the Codex A↔B loop as before.
3. After P1 PASS, orchestrator invokes `gstack /ship` to push and open the PR.
4. Without the `gating:` and `ship:` lines, behavior is identical to legacy specs.

## Architecture (3 tiers)

```
You (this session, opus)         = Main Orchestrator
  ↓ Agent tool, one phase at a time
Sub-Agent (opus, fresh per phase) = Phase Conductor
  ↓ Bash → codex exec, sequence + retry loop
Codex A (executor)  ←→  Codex B (verifier, fresh context)
```

| Tier | Reads files? | Writes code? | Commits? | Persistence |
|------|---|---|---|---|
| **Orchestrator** | spec + state file + sub-agent reports | NO | NO | survives whole spec |
| **Sub-Agent** | spec + git diff + test output + state file | NO (only authors codex prompts) | YES (after B PASS) | per phase, killed on DONE |
| **Codex A** | spec + scoped files | YES (working tree only) | NO | one-shot per round |
| **Codex B** | spec + working tree + tests | NO | NO | one-shot per round |

Source touch → only Codex A. Test run → only Codex B (via spec's `verify_cmd`). Commit → only sub-agent (after B says PASS). Orchestrator NEVER reads source files or runs tests.

## State & resume

Each spec run writes `.longtask/state/<spec_basename>.json` (repo root, or `~/.longtask/` if no repo). Sub-agent updates at each phase transition:

```json
{
  "spec_path": "...",
  "spec_sha256": "...",
  "started_at": "2026-05-08T...",
  "gating_cleared_at": "2026-05-08T...",
  "ship_status": "PENDING | DONE | FAILED",
  "phases": {
    "P1": {
      "status": "PASS",
      "rounds": 1,
      "commit": "abc123",
      "duration_s": 142,
      "last_heartbeat": "2026-05-08T...",
      "heartbeats": [
        {"at": "2026-05-08T14:01:00+08:00", "event": "phase-start"},
        {"at": "2026-05-08T14:01:05+08:00", "event": "round-1-codex-a-start"},
        {"at": "2026-05-08T14:09:30+08:00", "event": "round-1-codex-a-done"},
        {"at": "2026-05-08T14:09:32+08:00", "event": "round-1-codex-b-start"},
        {"at": "2026-05-08T14:11:42+08:00", "event": "round-1-codex-b-done"},
        {"at": "2026-05-08T14:11:50+08:00", "event": "phase-pass"}
      ]
    },
    "P2": {"status": "BLOCKED", "rounds": 3, "report": ".longtask/reports/P2-blocked.md"},
    "P3": {"status": "PENDING"}
  }
}
```

`gating_cleared_at` is set on first gating success; absence means gating still pending. `ship_status` is omitted entirely when `ship: false` — its presence flags that ship was attempted at least once. Phase `status` enum: `PENDING | PASS | FAIL | BLOCKED | SKIPPED`. `SKIPPED` is written by `--from <Pn>` for every phase before `<Pn>` (no `commit` field, no rounds counted). `last_heartbeat` and `heartbeats[]` are the idle-timeout watchdog's audit trail; they let `--resume` skip immediately to the right round and let post-mortem reconstruct where time went.

- `/longtask <spec>` (no flag) + state exists → ask user **resume** (skip PASS) vs **restart** (clear state).
- `/longtask <spec> --resume` → silent resume from first non-PASS.
- spec sha256 changed since last run → force restart with warning (state stale).

## Timeouts and stop

- Every `codex exec` wrapped in `timeout 1800` (30 min). Exit 124 → FAIL reason `TIMEOUT`, counts as one round.
- Sub-agent checks `.longtask/.stop` flag every round. If exists: kill in-flight codex subprocess, return `BLOCKED reason="USER_STOPPED"`.

## Codex CLI invocation

Both A and B use the SAME fixed command. Only the prompt differs. Cross-check comes from fresh context + structured JSON verdict against the spec's `verify_cmd`, not from model heterogeneity.

```bash
timeout 1800 codex exec --skip-git-repo-check \
  -c model="gpt-5.5" \
  -c model_reasoning_effort="xhigh" \
  --dangerously-bypass-approvals-and-sandbox \
  "<sub-agent's A or B prompt>"
```

`codex exec` is one-shot stateless. Sub-agent rebuilds A's "context" between rounds by prepending prior diff + B's JSON verdict.

## CLI flags

`/longtask <spec> [flags]` — flags are parsed in step 1 and override behavior:

| Flag | Effect |
|------|--------|
| (none) | Run gating loop if declared, then phases P1→Pn, then ship if declared. |
| `--resume` | Read existing state file. Skip phases already marked `PASS`. If state has `gating_cleared_at`, skip gating loop too. |
| `--skip-gating` | One-shot: ignore the spec's `gating:` field entirely, jump to phase loop. Useful when the design work was already done outside `/longtask`. |
| `--from <Pn>` | Start the phase loop at `<Pn>` instead of P1. **Implies `--skip-gating`** — once you start mid-spec, gating is by definition behind you. The phases before `<Pn>` are NOT run; their state is left untouched. |

Combine where it makes sense:
- `--from P3 --resume` — start at P3, but if state shows P3 already PASS, advance to P4.
- `--skip-gating` alone — gating skip but start at P1 normally.
- `--from P3` alone — gating skip + jump straight to P3 from a clean slate (state file written from this point onward).

`--from <Pn>` does NOT validate that earlier phases' `outputs` exist. The user is asserting "those preconditions are already in place"; if they aren't, Codex A will likely fail verification on `<Pn>` and the normal retry/escalate flow takes over.

## Main Orchestrator behavior

1. Read **only** the spec file. Parse CLI flags (`--resume`, `--skip-gating`, `--from <Pn>`).
   Validate schema. Invalid → STOP and report. If `--from <Pn>` references a phase not in
   the spec → STOP and report.
1.5. **Gating** (skip if ANY of: `gating:` is omitted/empty; `--skip-gating` set; `--from`
   set; `--resume` of a run whose state has `gating_cleared_at`):
   a. For each skill name in `gating` list, in order: invoke via the Skill tool.
   b. Surface the skill's output to the user. **Wait** for explicit confirmation
      ("ok proceed", "继续", "go ahead", or equivalent) before invoking the next gate.
   c. If the user pauses, asks for changes, or says "stop" — STOP, do not enter P1.
      The user can edit the spec / artifacts and rerun.
   d. After ALL gates clear, record `{ "gating_cleared_at": "<iso8601>" }` in the
      state file so subsequent `--resume` skips the gating loop.
2. Check `.longtask/state/<spec_basename>.json`. Decide resume vs restart per rules above.
   If `--from <Pn>` set and no state file exists, create one with phases before `<Pn>`
   marked `SKIPPED` (status only, no commit sha). If state exists and `--from <Pn>`
   requests a phase already marked PASS, advance to the first non-PASS phase ≥ `<Pn>`
   (when combined with `--resume`) or warn + restart from `<Pn>` (when `--resume` absent).
3. For each non-PASS phase Pn in order **starting from the start phase** (P1 by default,
   `<Pn>` if `--from <Pn>`):
   a. Spawn sub-agent (Agent tool, opus, fresh context). Pass Sub-Agent Prompt with `{Pn}`, `{spec_path}`, `{state_path}` substituted.
   b. Wait. Sub-agent returns `DONE` | `BLOCKED` | `ESCALATE` + structured report.
   c. On `DONE`: discard sub-agent. Update state file. Move to Pn+1.
   d. On `BLOCKED` / `ESCALATE`: surface structured report to human. Await direction.
4. All phases DONE:
   a. Print summary table (phase / commit / duration). Mark SKIPPED phases explicitly.
   b. **Shipping** (skip if `ship:` is omitted or false): invoke `gstack /ship` via the
      Skill tool. The skill handles base-branch detection, tests, VERSION bump,
      CHANGELOG update, push, PR creation. Failures inside `/ship` do NOT roll back
      phase commits — surface the error and wait for the user to decide (rerun,
      manual ship, or abort).
   c. Exit.

The orchestrator does NOT: read source, run tests/builds, edit files, carry sub-agent reasoning forward. The orchestrator MAY invoke other skills via the Skill tool exclusively for the `gating` (step 1.5) and `ship` (step 4b) hooks above; it must not invoke skills that read or modify source files.

## Progress reporting (mandatory)

Sub-agent MUST emit ONE progress line per state transition. Orchestrator forwards to stdout (user is tailing the terminal).

```
📋 P1 starting · round 1/3
🔧 P1 round 1/3 · Codex A executing
🔍 P1 round 1/3 · Codex B verifying
✅ P1 PASS · round 1 · commit abc123 · 2.4 min
🔧 P2 round 2/3 · Codex A retrying after B's FAIL
🌐 P2 round 4 · 3 rounds exhausted, web-search decision in progress
✋ P2 BLOCKED · web-search inconclusive · see .longtask/reports/P2-blocked.md
```

## Sub-Agent Prompt (orchestrator passes verbatim, with substitutions)

```
You are the Phase Conductor for {Pn} of spec at {spec_path}.
State file: {state_path}.

You DO NOT write code. You author Codex prompts, invoke `codex exec` via Bash,
verify B's verdicts, commit on PASS, and report.

TOOL WHITELIST: Read (spec/state/diff/test output only); Bash (limited to:
codex exec, git status/diff/log/add/commit, the spec's verify_cmd, mkdir/cat
on .longtask/); WebSearch; WebFetch. Do NOT use Edit/Write on source files.

Procedure:

1. Read spec; extract {Pn}'s: goals, file_scope, do_not_touch, inputs, outputs,
   verify_cmd, verify_passes_when, max_retry_rounds (default 3), cost limits,
   idle_timeout_minutes (default 10).
   Read state file for prior round count if resuming.
   Contradiction or missing field → return ESCALATE.

   **Heartbeat helper**: every progress line you emit MUST also write to the
   state file under `phases.{Pn}.last_heartbeat` (ISO 8601) and append to
   `phases.{Pn}.heartbeats[]` an entry `{at: <iso8601>, event: <slug>}`.
   Slug naming: `phase-start`, `round-N-codex-a-start`, `round-N-codex-a-done`,
   `round-N-codex-b-start`, `round-N-codex-b-done`, `phase-pass`,
   `phase-blocked-<reason>`. This is the idle-timeout watchdog's audit trail.

   **Idle-timeout check** (run at every round transition, BEFORE invoking Codex):
   if `now - last_heartbeat > idle_timeout_minutes`, return immediately
   `BLOCKED reason="IDLE_TIMEOUT"` with the heartbeats[] tail attached. Do NOT
   spawn another Codex call — by definition you've been silent too long and
   the orchestrator/user needs to intervene.

2. Heartbeat `phase-start` (or `round-N-start` if resuming). Author Codex A
   prompt (skeleton below). Print "🔧 {Pn} round {N}/{max} · Codex A executing"
   and heartbeat `round-N-codex-a-start`.

3. Invoke Codex A:
   timeout 1800 codex exec --skip-git-repo-check \
     -c model="gpt-5.5" \
     -c model_reasoning_effort="xhigh" \
     --dangerously-bypass-approvals-and-sandbox "<A prompt>"
   Heartbeat `round-N-codex-a-done` immediately on return.
   On exit 124: treat as FAIL reason "TIMEOUT".
   Run `git status` + `git diff --stat`. Verify changes are within file_scope
   and not in do_not_touch. Violation → return ESCALATE.

4. Idle-timeout re-check. Author Codex B prompt (skeleton below). Print
   "🔍 {Pn} round {N}/{max} · Codex B verifying" and heartbeat
   `round-N-codex-b-start`.

5. Invoke Codex B with the SAME fixed command (only the prompt differs). Parse strict JSON output. Heartbeat `round-N-codex-b-done`.

5.5. **Verifier integrity check** (immediately after parsing B's JSON, BEFORE
   trusting the verdict):
   - Let `verdict_passes = (B.verdict == "PASS")` and
     `all_acs_pass = all(d.passed for d in B.dod_results)`.
   - If `not verdict_passes and all_acs_pass` (FAIL but every AC passed):
     return `ESCALATE reason="VERIFIER_INCONSISTENT_FAIL_BUT_AC_PASS"` with
     B's full JSON attached. The verdict and AC list contradict each other —
     this is a verifier failure or a poorly-worded `verify_passes_when`, NOT a
     code defect. Spawning round N+1 cannot fix it; the spec or the prompt
     skeleton needs human attention.
   - If `verdict_passes and not all_acs_pass` (PASS but some AC failed):
     return `ESCALATE reason="VERIFIER_INCONSISTENT_PASS_BUT_AC_FAIL"` with
     B's full JSON. Don't commit silently broken work.
   - If `dod_results` is empty or missing: return
     `ESCALATE reason="VERIFIER_MALFORMED_OUTPUT"` with the raw stdout.

6. If B.verdict == "PASS" (and integrity check passed):
   - `git add -A && git commit -m "[longtask:{spec_basename}:{Pn}] <one-line goal>"`
   - Capture commit sha. Update state file. Heartbeat `phase-pass`.
     Print "✅ {Pn} PASS ...".
   - Return DONE with commit sha + B's evidence summary.

7. If B.verdict == "FAIL" (and integrity check passed) and rounds_used < max_retry_rounds:
   - Build fresh Codex A prompt with Retry prompt prefix (B's JSON verbatim
     + git diff). Increment round. Loop to step 3.

8. If FAIL after max_retry_rounds:
   a. Web-search decision step:
      - Extract failing-DoD keywords + project lang/framework from B's JSON.
      - WebSearch / WebFetch + `gh search issues` for similar failures.
      - Prefer accepted SO answers, merged PRs in active repos, official docs.
      - Synthesize the MOST THOROUGH fix (NOT minimal patch). Cite source URLs.
      - Apply the 4 production-grade principles at top of this skill (simplicity / evals / iteration / taste) when judging tradeoffs.
   b. One more A→B round with the new approach.
   c. Still FAIL → write .longtask/reports/{Pn}-blocked.md including:
      - which DoD bullets failed, round-by-round summary
      - web-search findings + chosen approach + why it didn't work
      - actionable next-step suggestion (e.g. "extend file_scope to X",
        "DoD bullet Y contradicts phase Pm")
   d. Return BLOCKED with the report path.

9. Stop check every round: `.longtask/.stop` exists → kill codex subprocess,
   return BLOCKED reason="USER_STOPPED".

10. Cost check: track approximate cost (codex stdout reports tokens). If sum
    exceeds spec.cost_budget_usd, return BLOCKED reason="COST_BUDGET" with
    a request to bump or split the spec.

ESCALATE conditions (skip retries, return immediately):
- spec contradiction (two phases need incompatible state)
- security concern discovered (secret leak, RCE, data-loss path)
- Codex A repeatedly ABORTs due to spec scope insufficiency (owner must
  fix spec, not the code)
- A violates do_not_touch or file_scope

Final return: DONE | BLOCKED | ESCALATE + concise structured report (<300 words)
including commit sha and/or .longtask/reports/ path.
```

## Codex A Executor Prompt skeleton

```
You are Codex executor for {Pn} of spec at {spec_path}.

1. Read the spec section for {Pn}. Implement EXACTLY what goals say.
2. Touch ONLY paths in file_scope. NEVER modify paths in do_not_touch,
   even if "obviously related".
3. If scope is insufficient: write /tmp/{Pn}-abort.log with reason, print
   "ABORT: <reason>", exit. DO NOT expand scope on your own.
4. Update spec audit-tags as the spec defines (status fields, evidence links).
5. Stage your changes with `git add` but DO NOT `git commit` — the
   conductor commits after verification.

Print "DONE: <one-line summary>" on the last line.
```

## Retry prompt prefix (rounds 2+, prepended to fresh Codex A)

```
PRIOR ATTEMPT (round {N-1}/{max}) FAILED verification.

B's structured report:
<B's JSON verbatim>

Diff that failed:
<git diff>

Root-cause the failure. Production-quality fix, not a minimal patch. If the
failure points to a deeper architectural issue rather than a localized bug,
ABORT and report — do not paper over.

(Original A prompt follows.)

<original A prompt for {Pn}>
```

## Codex B Verifier Prompt skeleton

```
You are Codex verifier for {Pn}. NO context from any prior agent. Trust only
artifacts (git diff, files, test output).

Procedure:
1. Read spec at {spec_path}. Focus on {Pn}'s file_scope, verify_cmd,
   verify_passes_when.
2. Run: git diff (or git log -p -1 if already committed elsewhere).
3. Execute the spec's `verify_cmd` LITERALLY. Capture stdout+stderr+exit_code.
4. Independently judge each DoD bullet against artifacts.

Output STRICT JSON ONLY (no prose around it):
{
  "verdict": "PASS" | "FAIL",
  "summary": "<one sentence>",
  "verify_cmd_exit": <int>,
  "verify_cmd_excerpt": "<last ~30 lines of output>",
  "dod_results": [
    {"bullet": "<from spec>", "passed": true|false, "evidence": "file:line or test name or output excerpt"}
  ],
  "root_cause_hint": "<for FAIL only: what likely needs to change, no code>"
}

DO NOT propose code. DO NOT modify anything. Verify only.
```

## Phase done → next phase

When sub-agent returns DONE:
1. Orchestrator reads structured DONE report.
2. Orchestrator updates `.longtask/state/<spec>.json`.
3. Orchestrator discards sub-agent (no follow-up messages).
4. Orchestrator spawns fresh sub-agent for Pn+1. If Pn+1's `inputs` reference Pn's outputs (commit sha, file path, symbol), include that fact verbatim in the new Sub-Agent Prompt — but never carry Pn's reasoning chain.

## Escalation flow

```
B FAIL × max_retry_rounds + web-search FAIL → BLOCKED + .longtask/reports/{Pn}-blocked.md
spec / security / scope-violation issue     → ESCALATE
cost budget hit                              → BLOCKED reason="COST_BUDGET"
.longtask/.stop flag                         → BLOCKED reason="USER_STOPPED"
sub-agent silent > idle_timeout_minutes      → BLOCKED reason="IDLE_TIMEOUT"
B verdict=FAIL but all dod_results passed    → ESCALATE reason="VERIFIER_INCONSISTENT_FAIL_BUT_AC_PASS"
B verdict=PASS but some dod_results failed   → ESCALATE reason="VERIFIER_INCONSISTENT_PASS_BUT_AC_FAIL"
B JSON missing / empty dod_results           → ESCALATE reason="VERIFIER_MALFORMED_OUTPUT"

Orchestrator surfaces structured report. User options:
  - edit spec → `/longtask <spec> --resume`
  - manually fix → `/longtask <spec> --resume`
  - skip phase: edit state, mark Pn as SKIPPED, then resume
  - abort: rm .longtask/state/<spec>.json

For VERIFIER_INCONSISTENT_*, the fix is almost always one of:
  - tighten `verify_passes_when` so B can no longer split verdict from AC list
  - rewrite specific dod bullets that B keeps mis-judging
  - relax `verify_cmd` if it surfaces noise unrelated to the phase goals
Don't just bump max_retry_rounds — if B is inconsistent, more rounds spawn more
contradictions. The skill explicitly refuses to retry past an integrity failure.

For IDLE_TIMEOUT, inspect `phases.{Pn}.heartbeats[]` to see where the gap was:
  - long gap before any codex call → sub-agent stuck in spec parsing or state
    setup; spec likely has an ambiguity worth fixing before resume
  - long gap between `codex-a-done` and `codex-b-start` → sub-agent stuck
    interpreting A's diff; check git diff is sane, then resume
  - long gap before next round's `codex-a-start` → sub-agent stuck deciding
    next prompt after a FAIL; inspect last B JSON for malformed verdict
The default 10-minute idle window catches all these without making real work
hit the wall.
```

## Project-specific tuning

If project has `docs/CODEX_PROTOCOL.md` (or equivalent), sub-agent appends its content as a "Known traps" appendix to Codex A prompts (e.g. "avoid nested ssh+heredoc", vendor patch policy, project standing rules) — only the cautions relevant to the current phase's `file_scope`.

---

## Roadmap (deferred enhancements — flesh out only when the underlying need bites)

- **Phase inputs/outputs typing** — `inputs:` / `outputs:` are free-text now; promote to structured `{type, name, ref}` when chains exceed 3 phases deep.
- **Smoke-test demo spec** — ship `~/.claude/skills/longtask/example/demo-spec.md` (1-phase hello-world) so first-time users can validate setup with one command.
- **Skill self-evals** — golden spec + expected artifacts; manual job once a release to detect prompt-template regressions.
- **SKILL.md split** — if this file passes ~400 lines, move prompt skeletons to `prompts/sub-agent.md` etc. and reference by path.
- **Lessons-learned writeback** — sub-agent appends one-liners (per BLOCKED, or after retry-recovered PASS) to project's `docs/CODEX_PROTOCOL.md`.
- **Web-search decision template** — formal query-construction recipe + source-quality scoring (accepted SO / merged PR / official docs only).
- **Heterogeneous verifier (different model)** — current default: GPT-5.5 xhigh for both A and B (fresh context as the cross-check). Future option: spec-level override letting B use a different family (e.g. Claude via Agent tool, or `gpt-5-mini`) for stronger cross-model verification when fresh-context alone feels insufficient.
- **Tool-whitelist runtime enforcement** — currently advisory in sub-agent prompt; future hook to block Edit/Write on source files inside sub-agent context.
- **Idempotency on PASS** — `--rerun` flag forces re-verify (without re-execute) on PASS phases; useful when `verify_cmd` changes but `file_scope` didn't.
- **Cost telemetry aggregation** — per-spec `.longtask/cost.json` aggregating tokens × model price for retroactive budget tuning.
- **Status TUI** — `/longtask --status <spec>` rendering BLOCKED reports as a structured panel (not raw markdown).
