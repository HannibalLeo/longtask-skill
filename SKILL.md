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

final_smoke:
  scenarios_doc: docs/v3/CRITICAL_PATH.md   # required if section present: markdown file
                                            # listing scenario IDs, flows, and pass criteria.
  scenarios: [doctor-login, reading-room-load]   # optional subset; default = all in doc
  skill: gstack                             # optional, default "gstack"
  retry_on_fail: 2                          # optional, default 2 (visual verifiers can flake)
  timeout_minutes: 20                       # optional, default 20 (advisory budget for the skill)
# Optional. End-to-end browser verification of critical user flows, run AFTER all
# phases reach PASS but BEFORE ship. Catches the "all pytest green, but the page
# is broken" failure mode — Codex B answers "code matches spec", final_smoke
# answers "user flow actually works". FAIL → ESCALATE, ship is blocked. Omitted
# entirely → skip (legacy behavior, fully backward compatible).

docs_sync: true
# Optional. When true (or a list of doc paths), the sub-agent invokes the
# `update-docs` skill BEFORE committing each phase, passing the staged diff.
# The skill scans for code changes that imply doc updates (new endpoints →
# API_CONTRACT.md; new model fields → DATA_CONTRACT.md; new routes → HOME.md;
# etc.) and writes those updates. The doc edits are auto `git add`-ed so they
# land in the same commit as the code change — atomicity rule: code and docs
# ship together or not at all. Accepts:
#   - `true` — let update-docs decide which docs to touch
#   - list of paths — whitelist (skill only updates these files)
#   - `false` / omitted — no doc sync (legacy behavior)
# update-docs failure → phase FAIL with a brief report; next round can fix.

inject_context:
  always: [docs/STYLE_GUIDE.md]
  when_scope_matches:
    "ml/**": [docs/MODEL_RULES.md]
  exclude: [docs/API_CONTRACT.md]
# Optional. Override the convention-based context-doc auto-injection
# (see `## Project-specific tuning`). Use only when the default convention
# table doesn't fit the project — e.g. style guide lives at a non-standard
# path, or a particular spec wants to opt out of injecting one of the
# defaults. Sub-keys:
#   always:             extra paths injected on every phase
#   when_scope_matches: extra scope-filtered paths (glob → list of paths)
#   exclude:            paths removed from the resolved set even if convention
#                       table or `always:` would have included them
# Omitted entirely → use convention defaults only (the common case).
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

The timeout does NOT cover Codex CLI execution itself — `codex exec` is wrapped only in a 10 min stdout-stall detector (no wall-clock cap; codex's own token stream is the progress signal). See "Codex CLI invocation". The two layers compose: the wrapper's stall detector protects against a stuck CLI process; the idle timeout protects against a stuck sub-agent between rounds.

**Inline spec example with gating + smoke + ship**:

```markdown
---
gating: [office-hours, plan-ceo-review, plan-eng-review]
final_smoke:
  scenarios_doc: docs/CRITICAL_PATH.md
  scenarios: [healthz-200]
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
3. After P1 PASS, orchestrator runs `final_smoke` (browses `/healthz`, asserts 200 + body). FAIL → ESCALATE, no ship.
4. Smoke PASS → orchestrator invokes `gstack /ship` to push and open the PR.
5. Without the `gating:` / `final_smoke:` / `ship:` lines, behavior is identical to legacy specs.

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
    "P2": {"status": "BLOCKED", "rounds": 3, "report": ".longtask/reports/<spec>/P2-blocked.md"},
    "P3": {"status": "PENDING"}
  },
  "final_smoke": {
    "status": "PASS | FAIL | PENDING",
    "scenarios_run": ["doctor-login", "reading-room-load"],
    "retries_used": 1,
    "report_path": ".longtask/reports/<spec>/smoke-final.md",
    "completed_at": "2026-05-08T..."
  }
}
```

`gating_cleared_at` is set on first gating success; absence means gating still pending. `ship_status` is omitted entirely when `ship: false` — its presence flags that ship was attempted at least once. `final_smoke` is omitted when `final_smoke:` is not declared in the spec; otherwise it tracks the final-smoke verdict so `--resume` can skip a previously-PASSed smoke. Phase `status` enum: `PENDING | PASS | FAIL | BLOCKED | SKIPPED`. `SKIPPED` is written by `--from <Pn>` for every phase before `<Pn>` (no `commit` field, no rounds counted). `last_heartbeat` and `heartbeats[]` are the idle-timeout watchdog's audit trail; they let `--resume` skip immediately to the right round and let post-mortem reconstruct where time went.

- `/longtask <spec>` (no flag) + state exists → ask user **resume** (skip PASS) vs **restart** (clear state).
- `/longtask <spec> --resume` → silent resume from first non-PASS.
- spec sha256 changed since last run → force restart with warning (state stale).

**Artifact retention** — `state/<spec>.json`, `prompts/<spec>/*.md`, and `reports/<spec>/*.md` (phase-blocked / smoke-final reports) are **durable evidence** and survive across runs. Only `reports/<spec>/*.png` screenshots are wiped at fresh-run start (step 1.6) — they're voluminous and only useful for diagnosing the run that just produced them. `--resume` and `--from` skip the wipe so you can keep looking at the failure that triggered the rerun.

## Timeouts and stop

- Every `codex exec` wrapped in a stall-only kill: `read -t 600` in a pipe — 10 min with no new stdout line → exit 142 (`STALL_TIMEOUT`). Counts as one round. **No wall-clock cap** — codex's own token stream is the progress signal; as long as it's emitting we let it run. Owner intent: "don't strong-kill while work is happening".
- Sub-agent checks `.longtask/.stop` flag every round. If exists: kill in-flight codex subprocess, return `BLOCKED reason="USER_STOPPED"`.

## Codex CLI invocation

Both A and B use the SAME fixed command. Only the prompt differs. Cross-check comes from fresh context + structured JSON verdict against the spec's `verify_cmd`, **not** from model heterogeneity. (See README → "Single-model setup" — replacing both A and B with the same `claude --print` invocation is fully supported; the load-bearing invariants are prompt-layer fresh context + strict JSON verdict, not "two different models".)

The wrapper lives at [`lib/codex-wrapper.sh`](lib/codex-wrapper.sh). Sub-agent invokes it with a **prompt FILE PATH** (not a string — long inline prompts trigger codex's stdin-pipe hang):

```bash
bash ~/.claude/skills/longtask/lib/codex-wrapper.sh <prompt_file> [run_id]
```

Two layers of protection:

1. **`read -t 600` stall detector** — 10 min with no new stdout line → kill (exit 142). When `read` times out, the pipe closes and codex dies on SIGPIPE on its next write. `SECONDS` resets on each line read and is checked after the loop to discriminate stall (≥600) vs EOF (≈0) — needed because macOS bash 3.2's `read -t` returns exit 1 on both timeout AND EOF; only bash 4+ uses >128.
2. **`script -q /dev/null` PTY re-attach** — workaround for [openai/codex#19945](https://github.com/openai/codex/issues/19945): codex 0.124.0+ silently exits when stdout is not a TTY and the prompt is >~10KB. The wrapper writes a launcher script (the codex invocation + stdin redirect from prompt file), then runs that launcher under `script` to re-attach a pseudo-TTY. Two-step launcher avoids inline-bash escaping. The form `script -q /dev/null <launcher>` works on both BSD (macOS) and util-linux without an `-c` flag. Harmless side-effect: a stderr line `codex_core::session: failed to record rollout items: thread not found` may appear; verifier prompts ignore it. Remove the `script` wrapper when the upstream fix lands (track 0.131.0+ release notes).

**No wall-clock cap.** codex's own token stream is the progress signal — as long as it's emitting, the wrapper lets it run indefinitely. The previous outer `timeout 600` was a bug: it killed actively-running codex at 10 min, contradicting owner intent "don't strong-kill while work is happening". Removing the wall-clock also drops the dependency on GNU `timeout` (macOS doesn't ship it). Cost / runaway protection lives one layer up in `cost_budget_usd`.

`codex exec` is one-shot stateless. Sub-agent rebuilds A's "context" between rounds by prepending prior diff + B's JSON verdict (see [`prompts/codex-a-retry.md`](prompts/codex-a-retry.md)).

**Model substitution.** To run on a different stack, edit [`lib/codex-wrapper.sh`](lib/codex-wrapper.sh) — replace the codex line inside the launcher heredoc, leave the rest (pipefail, read-t stall detector, `script` PTY re-attach). Three requirements for any substitute CLI: (a) **stateless one-shot** — every call is independent, no conversation history carried by default; (b) **line-buffered stdout** — produces newline-terminated output during execution (most reasoning CLIs do; if not, prepend `stdbuf -oL`); (c) **stdin-redirectable** — accepts the prompt via `< file` (positional inline-arg breaks codex; check yours). Examples: `claude --print --model <name>`, `gemini --prompt`, `llm -m <model>`. CLIs that maintain a session by default (REPL-style) break the fresh-context invariant and must NOT be used. If your substitute CLI does NOT have the no-TTY bug, drop the `script -q /dev/null` line — it adds harmless overhead and the `^D`/control-char noise.

## CLI flags

`/longtask <spec> [flags]` — flags are parsed in step 1 and override behavior:

| Flag | Effect |
|------|--------|
| (none) | Run gating loop if declared, then phases P1→Pn, then final_smoke if declared, then ship if declared. |
| `--dry-run` | Parse + schema-validate spec only. Print phase list, all missing/contradictory fields, whether `final_smoke.scenarios_doc` exists, whether `docs_sync` is a valid type. Exit without spawning a sub-agent, invoking codex, or touching git. Useful as the first thing you run on a new spec — surfaces schema errors in seconds instead of after gating completes. |
| `--resume` | Read existing state file. Skip phases already marked `PASS`. If state has `gating_cleared_at`, skip gating loop too. Also skips the step 1.6 screenshot wipe so you can keep looking at the prior run's PNGs while debugging. |
| `--skip-gating` | One-shot: ignore the spec's `gating:` field entirely, jump to phase loop. Useful when the design work was already done outside `/longtask`. |
| `--skip-smoke` | One-shot: ignore the spec's `final_smoke:` field, go straight from phase loop to ship. Use when smoke flaked on something you already verified manually and you don't want to burn another retry cycle. Does NOT bypass ship. |
| `--from <Pn>` | Start the phase loop at `<Pn>` instead of P1. **Implies `--skip-gating`** — once you start mid-spec, gating is by definition behind you. The phases before `<Pn>` are NOT run; their state is left untouched. |

Combine where it makes sense:
- `--from P3 --resume` — start at P3, but if state shows P3 already PASS, advance to P4.
- `--skip-gating` alone — gating skip but start at P1 normally.
- `--from P3` alone — gating skip + jump straight to P3 from a clean slate (state file written from this point onward).

`--from <Pn>` does NOT validate that earlier phases' `outputs` exist. The user is asserting "those preconditions are already in place"; if they aren't, Codex A will likely fail verification on `<Pn>` and the normal retry/escalate flow takes over.

## Main Orchestrator behavior

1. Read **only** the spec file. Parse CLI flags (`--dry-run`, `--resume`, `--skip-gating`,
   `--skip-smoke`, `--from <Pn>`). Validate schema. Invalid → STOP and report. If
   `--from <Pn>` references a phase not in the spec → STOP and report.

   **`--dry-run` short-circuit** — when this flag is set, after schema validation:
   - Print the parsed phase list (`P1`, `P2`, ... + `goals` one-liner each).
   - Print whether `gating:` / `final_smoke:` / `ship:` / `docs_sync:` are set, and
     for `final_smoke.scenarios_doc` print whether the file exists.
   - Print all missing required fields per phase, all contradictions
     (e.g. `inputs:` referencing an undefined output).
   - Print "DRY-RUN OK — no codex / git / skill side effects." and exit.
   Do NOT enter gating, do NOT spawn sub-agent, do NOT touch `.longtask/state/`.
1.5. **Gating** (skip if ANY of: `gating:` is omitted/empty; `--skip-gating` set; `--from`
   set; `--resume` of a run whose state has `gating_cleared_at`):
   a. For each skill name in `gating` list, in order: invoke via the Skill tool.
   b. Surface the skill's output to the user. **Wait** for explicit confirmation
      ("ok proceed", "继续", "go ahead", or equivalent) before invoking the next gate.
   c. If the user pauses, asks for changes, or says "stop" — STOP, do not enter P1.
      The user can edit the spec / artifacts and rerun.
   d. After ALL gates clear, record `{ "gating_cleared_at": "<iso8601>" }` in the
      state file so subsequent `--resume` skips the gating loop.
1.6. **Stale screenshot cleanup** (skip if `--resume` or `--from` is set):
   `find .longtask/reports/<spec_basename>/ -type f -name '*.png' -delete 2>/dev/null || true`.
   Only PNGs are wiped — markdown reports (`P*-blocked.md`, `smoke-final.md`),
   prompts under `.longtask/prompts/<spec_basename>/`, and the state file itself
   are evidence and survive across runs. Other specs' artifacts under
   `.longtask/reports/<other-spec>/` are untouched. `--resume` skips this step
   so a mid-flight rerun keeps the screenshots from the prior failure visible
   while you debug.
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
   a.5. **Final smoke** (skip if `final_smoke:` is omitted): invoke configured skill
      (default `gstack`) via the Skill tool with the scenarios from `scenarios_doc`,
      filtered to `scenarios:` if set. See `## Final smoke verification` for the
      contract and retry semantics. PASS → continue to ship. FAIL after retries →
      write report to `.longtask/reports/<spec>/smoke-final.md`, return
      `ESCALATE reason="SMOKE_FAIL"`, **do NOT proceed to ship**. The user
      decides: fix and rerun, ship anyway (`/longtask ... --skip-smoke`, see
      flags), or abort.
   b. **Shipping** (skip if `ship:` is omitted or false; also skip if `final_smoke:`
      was set and FAILED): invoke `gstack /ship` via the Skill tool. The skill
      handles base-branch detection, tests, VERSION bump, CHANGELOG update, push,
      PR creation. Failures inside `/ship` do NOT roll back phase commits —
      surface the error and wait for the user to decide (rerun, manual ship, or
      abort).
   c. Exit.

The orchestrator does NOT: read source, run tests/builds, edit files, carry sub-agent reasoning forward. The orchestrator MAY invoke other skills via the Skill tool exclusively for the `gating` (step 1.5), `final_smoke` (step 4a.5), and `ship` (step 4b) hooks above; it must not invoke skills that read or modify source files. The `docs_sync` hook is invoked by the **sub-agent** (not the orchestrator) at commit time — see [`prompts/sub-agent.md`](prompts/sub-agent.md) step 6.

## Progress reporting (mandatory)

Sub-agent MUST emit ONE progress line per state transition. Orchestrator forwards to stdout (user is tailing the terminal).

```
📋 P1 starting · round 1/3
🔧 P1 round 1/3 · Codex A executing
🔍 P1 round 1/3 · Codex B verifying
✅ P1 PASS · round 1 · commit abc123 · 2.4 min
🔧 P2 round 2/3 · Codex A retrying after B's FAIL
🌐 P2 round 4 · 3 rounds exhausted, web-search decision in progress
✋ P2 BLOCKED · web-search inconclusive · see .longtask/reports/<spec>/P2-blocked.md
🌐 final_smoke starting · scenarios=5 · skill=gstack
🔍 final_smoke scenario 3/5 · reading-room-load
🚨 final_smoke FAIL retry 1/2 · reading-room-load · WSI canvas empty after 10s
✅ final_smoke PASS · 5/5 scenarios · 8.2 min
```

## Prompts and wrapper (external files)

To keep this file readable, the verbatim Sub-Agent prompt and the Codex A/B/retry skeletons live in sibling files. The orchestrator passes the sub-agent prompt at Agent-tool spawn time, with `{Pn}` / `{spec_path}` / `{state_path}` / `{spec_basename}` substituted.

| File | Loaded by | Purpose |
|---|---|---|
| `prompts/sub-agent.md` | Orchestrator → Agent tool | Phase Conductor procedure (idle-timeout, A↔B loop, integrity check, loop detection, docs_sync hook, web-search escalation) |
| `prompts/codex-a.md` | Sub-agent → Codex A | Executor skeleton — reads spec, edits file_scope, stages diff |
| `prompts/codex-a-retry.md` | Sub-agent → Codex A (rounds N≥2) | Retry prefix prepended to A; carries B's prior JSON + failed diff |
| `prompts/codex-b.md` | Sub-agent → Codex B | Verifier skeleton — strict JSON output, includes reward-hacking check |
| `lib/codex-wrapper.sh` | Sub-agent (Bash) | Stall-only kill wrapper (10 min no-stdout-line → exit 142) + `script` PTY workaround for codex#19945 — single source of truth, no inline duplication |

**Single source of truth.** When updating the wrapper or any prompt skeleton, edit only the external file — SKILL.md must not re-inline them. The sub-agent loads `lib/codex-wrapper.sh` directly via `bash <path>`; it loads the prompt skeletons by reading them with the Read tool.

## Phase done → next phase

When sub-agent returns DONE:
1. Orchestrator reads structured DONE report.
2. Orchestrator updates `.longtask/state/<spec>.json`.
3. Orchestrator discards sub-agent (no follow-up messages).
4. Orchestrator spawns fresh sub-agent for Pn+1. If Pn+1's `inputs` reference Pn's outputs (commit sha, file path, symbol), include that fact verbatim in the new Sub-Agent Prompt — but never carry Pn's reasoning chain.

## Escalation flow

```
B FAIL × max_retry_rounds + web-search FAIL → BLOCKED + .longtask/reports/{spec_basename}/{Pn}-blocked.md
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

## Final smoke verification

After every phase reaches PASS, the orchestrator runs an end-to-end smoke pass against the running product **before** ship. This catches the failure mode where every phase's `verify_cmd` (pytest/grep) is green but the actual user-facing flow is broken — common in UI-heavy work where backend tests can't observe what a real user sees.

**Why a separate step, not part of Codex B:** Codex B answers "does the code do what the spec says?" against the spec's `verify_cmd`. Final smoke answers "does the user flow actually work end-to-end?" against a running browser. Different prompt, different evidence (screenshots vs. pytest output), different failure modes. Mixing them is how you get "all green" with a broken page — Codex B is happy because pytest passed; nobody clicked anything.

**Mechanics:**

1. Orchestrator reads `final_smoke.scenarios_doc` (markdown listing flow IDs + steps + pass criteria — see "Scenarios doc format" below). Missing file → STOP and report (same severity as missing spec field).
2. If `final_smoke.scenarios:` is set, filter the doc's scenarios to those IDs; else run all scenarios in the doc.
3. Heartbeat `final-smoke-start`. Invoke `final_smoke.skill` (default `gstack`) via the Skill tool. Pass: scenarios doc path, filtered ID list, `timeout_minutes` advisory budget. The skill is responsible for: starting/connecting to a browser, executing each scenario, capturing a screenshot per scenario (PASS or FAIL — both auditable), returning structured per-scenario verdicts.
4. On any scenario FAIL: retry **only the failed scenarios** up to `retry_on_fail` times (default 2). Visual-verification skills are non-deterministic — same prompt occasionally false-fails on a misread screenshot or transient network blip. Re-running just the failed subset is much cheaper than re-running all and gives a quick signal whether a flake or a real bug.
5. All scenarios PASS (eventually) → heartbeat `final-smoke-pass`. Continue to ship.
6. Some scenarios still FAIL after retries → write report to `.longtask/reports/<spec>/smoke-final.md` with: scenario ID, screenshot path, `observed_vs_expected` line, retry history. Heartbeat `final-smoke-fail`. Return `ESCALATE reason="SMOKE_FAIL"`. Ship is blocked. The user fixes (rerun) or overrides (`--skip-smoke`).

**Skill contract.** Any substitute for `gstack` MUST return structured output that includes:

- `scenarios: [{ id, passed: bool, screenshot_path: str, observed_vs_expected: str | null, duration_s: number }]`
- `summary: { total, passed, failed, duration_s }`

Skills that only return prose ("looked good overall") are not acceptable — same reason Codex B requires strict JSON. If the skill returns malformed output, the orchestrator returns `ESCALATE reason="SMOKE_MALFORMED"` and attaches the raw skill output for debugging.

**Screenshot location is fixed.** Skills MUST write all PNGs under `.longtask/reports/<spec_basename>/` (the orchestrator's screenshot cleanup in step 1.6 only touches that prefix). Returning a `screenshot_path` outside this directory is a contract violation — the orchestrator does not relocate skill output. Markdown reports (`smoke-final.md`) live in the same directory and are NOT cleaned, since they are durable evidence.

**Why a skill, not codex exec.** Codex CLI doesn't drive a browser. The skill ecosystem already has `gstack` / `browse` / `qa` for headless-browser dogfooding via MCP. Reusing one of them keeps the orchestrator out of the screenshot/diff business. The orchestrator's only role here is "call skill, parse result, retry or escalate" — same shape as gating and ship hooks.

**Scenarios doc format** (`docs/<project>/CRITICAL_PATH.md` — author once per project, reuse across longtasks). Each scenario is a level-2 heading with `flow:` and `pass when:` lines:

```markdown
## doctor-login
**flow:** open `/login` → enter test_doctor / pw → submit
**pass when:** redirected to `/tasks`, list contains ≥1 item

## reading-room-load
**flow:** from `/tasks` click first task → wait for WSI viewer
**pass when:** canvas non-empty within 10s, console has 0 errors
```

Keep each scenario ≤ 10 steps with one observable pass criterion. The skill agent reads this markdown directly — no special parsing required. Update the doc when adding user-facing capabilities; treat it like the project's API_CONTRACT but for end-to-end flows.

**State file:** smoke pass/fail goes into `.longtask/state/<spec>.json` as `final_smoke: { status: "PASS" | "FAIL", scenarios_run: [...], retries_used, report_path, completed_at }`. `--resume` honors this: if state shows smoke PASS, `--resume` skips smoke (it already ran); if smoke FAILED, `--resume` re-runs it (assuming the user fixed the underlying bug).

**Why retry the failed subset only, not the full sweep.** A false-fail on scenario 3 of 5 doesn't invalidate scenarios 1-2's PASS or 4-5's PASS. Re-running everything would (a) cost 5x more, (b) introduce more chances for flake on previously-green scenarios. The cost: if scenario 3 actually broke scenarios 4-5 (state pollution between runs), you'd miss it. Mitigation: every scenario must be self-contained (start from a clean state — login fresh, no shared cookies between scenarios). Document this in `CRITICAL_PATH.md` as a hard rule.

## Project-specific tuning — convention-based context injection

Sub-agent automatically discovers project-level convention documents and injects them into Codex A's prompt. **Zero spec configuration required**: drop a markdown file at one of the convention paths below and it's picked up. Missing files are silently skipped — no project is required to have all of them.

**Convention table** (case-sensitive filenames, all under `docs/` at repo root):

| Path | Injected into Codex A when … | Purpose |
|---|---|---|
| `docs/CODEX_PROTOCOL.md` | always | Project standing rules / known traps (e.g. "avoid nested ssh+heredoc", vendor patch policy) |
| `docs/SECURITY_RULES.md` | always | Cross-cutting security constraints (secret handling, auth invariants, data-loss paths) |
| `docs/DESIGN_SYSTEM.md` | phase `file_scope` matches `**/frontend/**`, `**/web/**`, `**/views/**`, `**/components/**` | Visual / UI style guide (tokens, component whitelist, anti-patterns) |
| `docs/API_CONVENTIONS.md`, `docs/API_CONTRACT.md` | phase `file_scope` matches `**/api/**`, `**/gateway/**`, `**/routers/**`, `**/schemas/**` | API shape, status codes, error envelope, versioning |
| `docs/DATA_CONTRACT.md` | phase `file_scope` matches `**/models/**`, `**/migrations/**`, `**/schemas/**`, `**/db/**` | Data model invariants, migration rules, FK constraints |

The sub-agent reads each existing file in full and prepends them to the Codex A prompt under a `### Project context (auto-injected)` header, with the source path labelled per file. Codex A treats them as binding constraints, same priority as the spec's `do_not_touch` / `verify_passes_when`.

**Per-spec override** when convention defaults don't fit (rare):

```yaml
# spec frontmatter
inject_context:
  always: [docs/STYLE_GUIDE.md]            # in addition to the convention table
  when_scope_matches:
    "ml/**": [docs/MODEL_RULES.md]          # extra path for ML-touching phases
  exclude: [docs/API_CONTRACT.md]           # opt out of a convention default for this run
```

**What this is NOT**:

- NOT a synthesizer — sub-agent does not summarize / re-write the docs; full content goes into the prompt verbatim. Token cost is real; keep convention docs lean.
- NOT for `final_smoke` scenarios — `docs/CRITICAL_PATH.md` lives outside this table because it's consumed by the smoke skill (see `## Final smoke verification`), not by Codex A.
- NOT for spec-internal docs — references to `docs/SOMETHING.md` inside the spec body don't trigger auto-injection; only the convention paths above + `inject_context:` overrides do.

---

## Roadmap (deferred enhancements — flesh out only when the underlying need bites)

- **Phase inputs/outputs typing** — `inputs:` / `outputs:` are free-text now; promote to structured `{type, name, ref}` when chains exceed 3 phases deep.
- **Smoke-test demo spec** — ship `~/.claude/skills/longtask/example/demo-spec.md` (1-phase hello-world) so first-time users can validate setup with one command.
- **Skill self-evals** — golden spec + expected artifacts; manual job once a release to detect prompt-template regressions.
- **Codex no-TTY bug workaround tracking** — current `script -q /dev/null` wrapper around codex exec works around [openai/codex#19945](https://github.com/openai/codex/issues/19945) (0.124.0+ silent exit when stdout is not a TTY; 0.130.0 still unfixed). Remove the `script` line in `lib/codex-wrapper.sh` when the upstream fix lands; track 0.131.0+ release notes.
- **Lessons-learned writeback** — sub-agent appends one-liners (per BLOCKED, or after retry-recovered PASS) to project's `docs/CODEX_PROTOCOL.md`.
- **Web-search decision template** — formal query-construction recipe + source-quality scoring (accepted SO / merged PR / official docs only).
- **Heterogeneous verifier (different model)** — current default: GPT-5.5 xhigh for both A and B (fresh context as the cross-check). Future option: spec-level override letting B use a different family (e.g. Claude via Agent tool, or `gpt-5-mini`) for stronger cross-model verification when fresh-context alone feels insufficient.
- **Tool-whitelist runtime enforcement** — currently advisory in sub-agent prompt; future hook to block Edit/Write on source files inside sub-agent context.
- **Idempotency on PASS** — `--rerun` flag forces re-verify (without re-execute) on PASS phases; useful when `verify_cmd` changes but `file_scope` didn't.
- **Cost telemetry aggregation** — per-spec `.longtask/cost.json` aggregating tokens × model price for retroactive budget tuning.
- **Status TUI** — `/longtask --status <spec>` rendering BLOCKED reports as a structured panel (not raw markdown).
