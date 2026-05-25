---
name: longtask
description: Multi-phase spec execution pipeline with Claude+Codex hybrid orchestration. Claude opus orchestrator dispatches phase sub-agents (Claude Agent tool); each sub-agent runs Codex GPT-5.5 worker (writes code) ↔ Codex GPT-5.5 verifier (schema-driven JSON verdict) via `codex exec`, with Claude main-line reviewing every verdict. Hybrid judgment gates (Claude primary + Codex secondary) cover plan integrity, per-phase decisions, and final alignment; final-alignment-review is **mandatory dual**. Roundtable discussion uses per-lens model routing (engineering/design → Claude; product/domain → Codex) with a `roundtable_mode: hybrid|claude_only|codex_only|dual` switch. Use when there is a written spec file with phased work and strict separation of executor/verifier/judge is desired. Triggers on /longtask, "execute this spec", "run the spec", "long task", "长任务", "spec 文件执行".
---

> **Quality bar — non-negotiable.** No hidden defects. No minimal patches that paper over symptoms. Every decision serves "this ships to real users", not "the test happens to be green".

> **The 4 production-grade principles** — this skill's operational interpretation, aligned with the spirit of [Karpathy's engineering style](https://github.com/forrestchang/andrej-karpathy-skills). Phrasing below is mine; treat as the working standard for THIS skill, not a quotation:
>
> 1. **Simplicity beats cleverness.** Prefer boring straightforward code that any reader can grep once and understand. If a layer of indirection can be deleted without losing function, delete it. Three similar lines beat a premature abstraction.
> 2. **Evals before optimization.** What cannot be measured cannot be improved. Every phase's `verify_cmd` makes PASS/FAIL mechanical, not narrative — "looks right to me" is not allowed.
> 3. **Tight iteration over big leaps.** Three small verifiable changes beat one large change that's right "in principle". The retry loop exists for this. If a phase needs a 500-line diff to verify, the phase is too coarse — split it.
> 4. **Taste is part of "shippable".** A green test does not mean production-ready. Read the diff at the end of each phase. Ugly code that passes is the next phase's pothole; naming, structure, and discipline are part of the bar.

# /longtask — v2 hybrid (Claude + Codex)

## When to use

Use when ALL of: a written spec file declares phased work (P1, P2, P3...); task is M/L (>5 min, multi-step); user wants Codex CLI to do the bulk of code work while Claude owns architecture judgment, judgment gates, and final verification.

**Recommended starting point** when the spec does not yet exist: run `gstack /office-hours` to interrogate the idea, then `gstack /plan-ceo-review` + `gstack /plan-eng-review` to lock product/architecture decisions. v2 also supports running the **built-in spec-classifier → roundtable → plan-writer → plan-integrity** pipeline against a raw `source_spec` input — see `## Pipeline overview` step 1-4.

Skip for: <5 min tasks; single-file edits where verifying is "read the diff".

## Owner 四步分工 (required reading — defines who runs what)

| Step | Owner | Scope |
|---|---|---|
| **(a) Claude does architecture** | Claude opus (main session + Agent tool) | Spec classification, plan writing, plan-integrity review. All "understand the spec, split it, decide who verifies" judgments. |
| **(b) Claude + Codex discuss** | Mixed | Roundtable lenses route per-role to Claude (engineering/design/ui-design) or Codex (ceo-product/domain-expert). Consensus editor: Claude writes, Codex secondary reviews. |
| **(c) Codex does the work** | Codex GPT-5.5 via `codex exec` | Phase worker writes code; phase verifier produces schema-driven JSON. Heavy I/O (file reads, test runs) stays out of the Claude main-line context. |
| **(d) Claude finalizes** | Claude opus (main session) | Reads every verifier JSON to decide PASS/retry, runs hybrid decision/plan-integrity/final-alignment gates, runs final E2E2 (browser/screenshots via Claude harness), syncs docs, ships. |

**Load-bearing invariant for (c)→(d):** Codex writes structured JSON via `--output-schema`; Claude reads that JSON and applies the final PASS/FAIL judgment. Claude does **not** read source files (preserves context). Claude **does** hold final authority (preserves safety).

## Pipeline overview (8 steps)

```
Step 0  Preflight         Validate spec frontmatter + state schema
Step 1  Classifier        Claude Agent reads spec → JSON {input_shape, discussion_rounds, required_lenses, risk_reasons}
Step 2  Roundtable        (conditional) Per-lens hybrid discussion × N rounds → round-state editor → consensus editor
Step 3  Codex spec sanity (UNCONDITIONAL) Codex GPT-5.5 single pass: omissions / hallucinations / internal contradictions / reward-hacking bait → JSON {verdict: CLEAN | NEEDS_REVISION}
Step 4  Plan-writer       Claude Agent invokes superpowers:writing-plans → implementation_plan.md (multi-agent dispatch when plan has ≥3 phases)
Step 5  Plan-integrity    HYBRID gate (Claude primary + Codex secondary) → PASS or BLOCKED_SPEC_REWRITE
Step 6  Per-phase loop    For each Pn: Claude sub-agent dispatches Codex worker → scope gate → Codex verifier (schema) → main-line JSON review → commit on PASS
Step 7  Final E2E2        Claude Agent runs final_verify_cmd + final_e2e2_cmd → screenshots → final_report (subagent must proactively flag residual risks to Step 8)
Step 8  Final-alignment   MANDATORY DUAL hybrid gate (Claude + Codex always both run) → PASS or escalate
Step 9  Ship (optional)   spec.docs_sync → update-docs; spec.ship → gstack /ship
```

Step 2 is skipped when classifier outputs `input_shape ∈ {plan_with_source, self_contained_plan}` (the user already supplied a plan). **Step 3 is unconditional** — codex sanity audit always runs, especially when Step 2 was skipped (no Claude roundtable means codex is the only multi-model second opinion on the spec before plan-writer).

## Spec schema (REQUIRED — orchestrator validates at Step 0)

### Frontmatter — top-level v2 fields

```yaml
# === REQUIRED v2 fields (BLOCKED_SPEC if missing) ===

source_spec_path: docs/specs/2026-05-26-foo-design.md
# Path to the source spec/design doc the spec was derived from. Used by
# spec-classifier (input_shape detection), plan-writer (REQ-* anchor source),
# and final-alignment-review (chain integrity check spec → plan → commits → report).

source_spec_sha256: "<sha256 of source_spec contents>"
# Captured at preflight; if file content changes mid-run, orchestrator BLOCKED_SPEC.

final_verify_cmd: "pytest -q tests/ && npm test"
# Required. Hard final-verify command. MUST exit 0 for final-alignment-review to PASS.
# Stricter version of legacy verify_cmd — runs after ALL phases PASS, before ship.

final_e2e2_cmd: "gstack browse-e2e --scenarios=docs/CRITICAL_PATH.md --screenshots=.longtask/screenshots/{spec_basename}/"
# Required. End-to-end browser command that MUST produce screenshots.
# Missing screenshots → BLOCKED_E2E2_SCREENSHOT. Catches "all tests green but page broken".

final_report_path: .longtask/reports/{spec_basename}/final-report.md
# Required. Where final-e2e2-report writes the artifact.

# === OPTIONAL v2 fields ===

roundtable_mode: hybrid   # one of: hybrid (default), claude_only, codex_only, dual
# hybrid     — Each lens routes to one model per the routing table (default).
# claude_only — All lenses run as Claude Agent calls.
# codex_only  — All lenses run as codex exec.
# dual       — Each lens runs both Claude AND Codex; round-state editor must
#              surface cross-model disagreements; final consensus must explicitly
#              INCORPORATE or mark OUT_OF_SCOPE.
# EXCEPTION: final-alignment-review is ALWAYS dual regardless of this setting
#            (per decision #2; cheap, last-line-of-defense, only runs once).

discussion_required: false   # force 5-round roundtable even if classifier says 0
# Cannot force 0 rounds — that override is rejected.

# === LEGACY (preserved + bridged) ===

gating: [office-hours, plan-ceo-review, plan-eng-review]
# Optional. Skill names the orchestrator MUST invoke before P1 starts. Each is
# run via the Skill tool in order; the user must explicitly confirm "ok proceed"
# (or equivalent) before the next gate runs and before P1 begins. v2 keeps this
# fully backward compatible — gating fires BEFORE classifier in Step 1, so
# external review skills run first.

ship: true
# Optional. After Step 7 (final-alignment-review) PASSes, orchestrator invokes
# `gstack /ship`. A failure inside /ship does NOT roll back phase commits —
# orchestrator surfaces the error and waits for the user to decide.

final_smoke:                             # DEPRECATED alias of final_e2e2_cmd
  scenarios_doc: docs/CRITICAL_PATH.md
  scenarios: [doctor-login, reading-room-load]
  skill: gstack
  retry_on_fail: 2
  timeout_minutes: 20
# Legacy structured form (Claude-end May 9 vintage). v2 bridges this to
# final_e2e2_cmd if final_e2e2_cmd is absent. New specs should use
# final_e2e2_cmd directly — it is a hard contract (must produce screenshots).

docs_sync: true
# Optional. When true (or a list of doc paths), the per-phase sub-agent invokes
# the `update-docs` skill BEFORE committing each phase, passing the staged diff.
# - true → let update-docs decide which docs to touch
# - list of paths → whitelist
# - false / omitted → no doc sync
# Failure → phase FAIL with brief report; next round can fix.

inject_context:
  always: [docs/STYLE_GUIDE.md, docs/archive/CODEX_PROTOCOL.md]
  when_scope_matches:
    "ml/**": [docs/MODEL_RULES.md]
  exclude: [docs/API_CONTRACT.md]
# Optional. Override convention-based context auto-injection. See
# `## Project-specific tuning`. CODEX_PROTOCOL.md is the conventional "always"
# entry for per-repo Codex chestnuts (decision #3b layer).
```

### Per-phase block (one per Pn heading)

```yaml
# Pn (heading)
goals: <what this phase achieves>
file_scope: [paths the worker may touch]
do_not_touch: [paths the worker MUST NOT modify]
inputs: [artifacts/sha/symbols required from prior phases]
outputs: [artifacts produced for downstream phases]
verify_cmd: "<exact shell command verifier runs, e.g. 'pytest tests/p1_*.py -v'>"
verify_passes_when: "<concrete predicate, e.g. 'exit 0 and 0 failures'>"
max_retry_rounds: 3
cost_budget_usd: 5
idle_timeout_minutes: 10

# === v2 additions ===
source_requirements: [REQ-001, REQ-002]
# Required for traceability. List of REQ-* anchors from source_spec this phase
# satisfies. final-alignment-review verifies every REQ-* in source_spec maps to
# at least one phase. Empty list is allowed only for meta phases (e.g. P0 scaffolding).

dod:
  - "POST /healthz returns 200 with {status:ok} body"
  - "Existing /auth endpoints unchanged (sample test still passes)"
  - "OpenAPI spec includes the new path"
# Required. Acceptance criteria the verifier MUST evaluate per-bullet.
# Each becomes a row in verifier-result.dod_results[] with {bullet, passed,
# evidence}. Evidence must cite file:line or verify_cmd output excerpt.
# Empty dod is rejected (BLOCKED_SPEC).
```

Missing required field → orchestrator BLOCKED_SPEC, points at line/phase, no Codex invocation.

`idle_timeout_minutes` semantics — this is an **idle** timeout, not a wall-clock cap. The sub-agent stamps a heartbeat at every progress boundary; at every round transition it checks `now - last_heartbeat`; if the gap exceeds the threshold, it returns `BLOCKED_HARNESS_BACKGROUND` immediately. The wrapper's stall detector (10 min no new stdout line → kill) is a separate layer protecting against a stuck `codex` child.

## Architecture (Claude main + per-phase sub + Codex children)

```
Claude main session (opus)                = Orchestrator
  ├─ reads spec, state, JSON outputs
  ├─ dispatches Claude Agents (classifier, roundtable lenses, plan-writer,
  │   plan-integrity primary, final-e2e2, final-alignment primary, docs-sync, ship)
  └─ dispatches `codex exec` children for:
        roundtable (ceo-product/domain-expert lenses)
        plan-integrity secondary
        final-alignment secondary (MANDATORY DUAL)
        spec-consensus secondary
  ↓
Claude Sub-Agent (opus, fresh per phase)  = Phase Conductor
  ├─ runs per-phase loop end-to-end
  ├─ dispatches `codex exec` children for:
  │     codex-worker (writes code)
  │     codex-verifier (--output-schema verifier-result.schema.json)
  ├─ enforces scope gate (git diff --name-only vs file_scope)
  ├─ reads verifier JSON, applies main-line PASS/FAIL
  ├─ on worker-proposed decision_options[]: escalates to orchestrator for hybrid
  │     decision-review gate
  └─ commits on PASS, returns {verdict, rounds_used, commit_sha} to orchestrator
  ↓
codex exec children (one-shot, GPT-5.5)
  ├─ codex-worker         — writes code in file_scope only
  ├─ codex-verifier       — read-only; runs verify_cmd; produces schema JSON
  ├─ codex-worker-retry   — fed prior verifier JSON; fixes verifier-cited issues
  ├─ roundtable lens      — JSON-style markdown verdict per lens
  └─ judgment secondary   — plan-integrity / decision-review / final-alignment / consensus
```

| Tier | Reads source files? | Writes code? | Commits? | Persistence |
|---|---|---|---|---|
| **Orchestrator (Claude main)** | spec + state + JSON outputs only | NO | NO | survives whole spec |
| **Sub-Agent (Claude Agent)** | spec + git diff + verifier JSON + state | NO (only authors codex prompts) | YES (after main-line PASS) | per phase, killed on DONE |
| **codex-worker** | spec + scoped files | YES (working tree only) | NO | one-shot per round |
| **codex-verifier** | spec + working tree + verify_cmd output | NO | NO | one-shot per round; output is JSON |

## Role × Model dispatch matrix (15 roles, owner four-step assignments)

| Role | Primary | Secondary (key gates) | Dispatch | Step |
|---|---|---|---|---|
| Orchestrator | Claude main (opus) | — | this session | (a) |
| Per-phase sub-agent | Claude Agent (opus) | — | Agent tool | (a) |
| **Spec classifier** | Claude opus | — | Agent tool | **(a)** |
| Roundtable: engineering | Claude opus | — | Agent tool | (b) |
| Roundtable: ceo-product | Codex GPT-5.5 xhigh | — | `codex exec` | (b) |
| Roundtable: design | Claude opus | — | Agent tool | (b) |
| Roundtable: ui-design | Claude opus | — | Agent tool | (b) |
| Roundtable: domain-expert | Codex GPT-5.5 xhigh | — | `codex exec` | (b) |
| Round-state editor | Claude opus | — | Agent tool | (b) |
| Consensus editor | Claude opus | Codex GPT-5.5 secondary | Agent + `codex exec` | (b) |
| **Codex spec sanity** | **Codex GPT-5.5 xhigh** (unconditional second-opinion audit) | — | `codex exec --output-schema` | **(b)** |
| **Plan-writer** | **Claude opus** (invokes `superpowers:writing-plans`; multi-agent dispatch when plan ≥3 phases) | — | Agent tool | **(a)** |
| **Plan-integrity review** | **Claude opus** | **Codex GPT-5.5 xhigh** | hybrid (decision #6) | **(a)+(d)** |
| Phase worker | Codex GPT-5.5 (default xhigh; downgrade to high acceptable) | — | `codex exec` via wrapper | (c) |
| **Phase verifier** | Codex GPT-5.5 (schema-driven JSON) | **Claude main-line reads JSON** | `codex exec --output-schema` → Claude review | **(c)→(d)** |
| **Decision gate** | **Claude opus** | **Codex GPT-5.5 xhigh** | hybrid (decision #6) | **(b)+(d)** |
| Final E2E2 report | Claude opus | — | Agent tool (gstack browse skill) | (d) |
| **Final-alignment review** | **Claude opus** | **Codex GPT-5.5 xhigh** (**always dual**) | hybrid, mandatory dual (decision #2 exception) | **(d)** |
| Docs sync (`update-docs`) | Claude opus | — | Agent tool / Skill tool | (d) |
| Ship (`/ship`) | Claude main | — | Skill tool (gstack /ship) | (d) |

## Roundtable mode semantics (decision #2)

| Mode | Behavior |
|---|---|
| `hybrid` (default) | Each lens routes to one model per the matrix above. Best cost/heterogeneity ratio. |
| `claude_only` | All lenses run as Claude Agent. Use when Codex unavailable. |
| `codex_only` | All lenses run as `codex exec`. Use for cost-sensitive specs or to compare against `hybrid` for the same spec. |
| `dual` | Each lens runs both Claude AND Codex; round-state editor must surface cross-model disagreements in `cross_model_disagreements[]`. Consensus editor must mark each disagreement INCORPORATED or OUT_OF_SCOPE; silent drops are rejected. Use for safety/data-loss/security/clinical/regulatory specs (auto-suggested by classifier when `risk_reasons` flag those domains). |

**Length policy (decision #5):** classifier's `discussion_rounds`:
- `plan_with_source` / `self_contained_plan` → 0 rounds (Step 2 skipped entirely)
- low-risk `source_spec` → 1-2 rounds
- high-risk / ambiguous `source_spec` → 5 rounds
- `discussion_required: true` in spec forces 5 rounds (cannot force 0)

## Hybrid judgment gates — reconciliation (decision #6)

Three gates run as Claude-primary + Codex-secondary hybrid:
1. **plan-integrity-review** (Step 5)
2. **decision-review** (Step 6, when worker returns `decision_options[]`)
3. **final-alignment-review** (Step 8, **mandatory dual** regardless of `roundtable_mode`)

Reconciliation rules (each gate prompt restates these so reviewers know their `vetoes[]` matter):

1. Both verdicts agree → use that verdict.
2. Disagreement + any side `vetoes[]` non-empty → `ASK_HUMAN`. Veto categories: irreversible, security boundary, scope contract break, regulatory / data-loss.
3. Disagreement + no vetoes + `confidence` delta > 0.15 + the chosen option is **local + reversible + inside spec + mechanically verifiable** → higher-confidence side wins.
4. Otherwise → `ASK_HUMAN`.

**No third arbiter by default.** The orchestrator escalates to user rather than spawning a third model. A third arbiter is only justified when both verdicts are high-quality but disagree on *interpretation of the same evidence*; that judgment is the human's, not another LLM's.

## Phase verifier flow (the (c)→(d) handoff)

```
Codex worker writes code (working tree mutations only)
         ↓
Claude sub-agent: git status --porcelain + git diff --name-only HEAD
         ↓ (hard scope gate)
                paths all in file_scope?  → no → BLOCKED_SCOPE
                                          → yes → continue
         ↓
Claude sub-agent dispatches Codex verifier:
  codex exec --output-schema schemas/verifier-result.schema.json \
             -o $TMPDIR/verifier-{Pn}-r{N}.json
         ↓
Codex verifier produces JSON {verdict, summary, verify_cmd_exit,
  verify_cmd_excerpt, reward_hacking_signals[], dod_results[], root_cause_hint}
         ↓
Claude sub-agent reads JSON (does NOT read source):
  1. jsonschema.validate(content, schemas/verifier-result.schema.json)
     → schema fail → BLOCKED VERIFIER_SCHEMA_INVALID
  2. verify_cmd_exit == 0?
  3. every dod_results[i].passed == true?
  4. reward_hacking_signals == []?    ← inspect each {file,line,excerpt} on
                                         non-empty; flag is rejection-by-default
  5. root_cause_hint sensible? (FAIL especially)
         ↓
PASS → docs_sync (if enabled) → commit → report PASS to orchestrator
FAIL → spawn codex-worker-retry with prior verifier JSON embedded → next round
       (up to max_retry_rounds)
After max retries exhausted → BLOCKED + escalate to orchestrator
```

**Load-bearing invariant:** Codex writes JSON; Claude reads JSON. Claude does not read source files (context preservation); Claude holds the final PASS/FAIL judgment (safety).

## BLOCKED enum (10 codes)

All 10 codes are stable enum values. Each BLOCKED return writes a report to `.longtask/reports/{spec_basename}/blocked-{Pn}.md` with stderr / exit code / repro command. Codes inherited from Codex v0.0.5:

| Code | Trigger |
|---|---|
| `BLOCKED_SCOPE` | Worker wrote outside `file_scope` or touched a `do_not_touch` path. |
| `BLOCKED_SPEC` | Spec frontmatter missing required field, or `source_spec_sha256` drift detected mid-run. |
| `BLOCKED_SPEC_REWRITE` | plan-integrity-review FAIL — plan does not faithfully cover the source spec. |
| `BLOCKED_MODEL_UNAVAILABLE` | Codex CLI returns model-not-available; wrapper logs `model_requests[].model_degraded=true`. |
| `BLOCKED_E2E2_SCREENSHOT` | final_e2e2_cmd produced no screenshot files (or screenshot dir empty). |
| `VERIFIER_SCHEMA_INVALID` | Codex verifier output does not parse against `verifier-result.schema.json`. |

Claude-end additions (decision #4):

| Code | Trigger |
|---|---|
| `BLOCKED_AGENT_TOOL_FAILURE` | Claude Agent tool itself errored (transport / quota / harness issue). |
| `BLOCKED_CODEX_WRAPPER_FAILURE` | `codex-wrapper.sh` exited non-zero AND non-142 (142 = STALL, separate signal). |
| `BLOCKED_HARNESS_BACKGROUND` | Main-line harness background-task failure, or idle-timeout exceeded between heartbeats. |
| `BLOCKED_CONTEXT_BUDGET` | Orchestrator session approaches the 1M token cap; self-BLOCKED before token exhaustion. |

The enum is stable. Detailed stderr/exit/repro lives in the per-BLOCKED report, not in the code.

## Codex CLI invocation (`lib/codex-wrapper.sh`)

All Codex children — workers, verifiers, secondary reviewers — go through `lib/codex-wrapper.sh`. It is a stall-only wrapper around `codex exec` with v2 additions:

- **Default model** = `gpt-5.5` (env: `CODEX_LONGTASK_MODEL`)
- **Default reasoning** = `xhigh` (env: `CODEX_LONGTASK_REASONING`)
- **Sandbox** = `workspace-write` (env: `CODEX_LONGTASK_SANDBOX`)
- **Approvals** = `never` (env: `CODEX_LONGTASK_APPROVALS`) — no in-phase approval prompts
- **Stall kill** = 10 min no new stdout line → exit 142 (env: `CODEX_LONGTASK_STALL_SECONDS`)
- **Structured output** = pass `OUTPUT_SCHEMA` (arg 3) → adds `--output-schema <file>`; pass `LAST_MESSAGE` (arg 4) → adds `-o <file>` (canonical JSON of last message). Both used by verifier / hybrid-judgment dispatches.
- **JSONL events** = `--json` always on, so Claude main-line can parse per-turn events.
- **PTY workaround** = `script -q /dev/null` wraps the codex invocation to bypass codex#19945 (no-TTY + large prompt → silent exit). Set `CODEX_LONGTASK_DISABLE_PTY=1` to opt out for testing whether the upstream bug is fixed.
- **Stdin** = prompt MUST be passed as a file path (positional arg 1). Inline prompts via stdin pipe trigger a codex hang.

Exit codes:
- `0` — codex finished normally
- `142` — STALL_TIMEOUT (10 min no stdout line)
- `2` — wrapper usage error
- `*` — codex non-zero exit (propagated; becomes `BLOCKED_CODEX_WRAPPER_FAILURE` for non-142)

Model-policy logging: on each invocation, sub-agent records `state.model_requests[]` entry: `{role, requested, actual, reason, model_degraded}`. Fallback to `gpt-5.4 high` is permitted only as cost fallback and MUST log `model_degraded=true`.

## State file (v2 schema)

State lives at `.longtask/state/{spec_basename}.json`. Schema:

```json
{
  "mode": "claude-hybrid",
  "spec_path": "...",
  "spec_sha256": "...",
  "input_path": "<source_spec_path>",
  "input_sha256": "<source_spec_sha256>",
  "input_shape": "source_spec | hybrid | plan_with_source | self_contained_plan",
  "classification_path": ".longtask/state/{spec_basename}/classification.json",
  "enhanced_spec_path": ".longtask/state/{spec_basename}/enhanced-spec.md",
  "enhanced_spec_sha256": "...",
  "spec_update_path": ".longtask/state/{spec_basename}/spec-update.md",
  "preflight_skip_path": null,
  "round_state_paths": [".longtask/state/{spec_basename}/round-1.json", "..."],
  "implementation_plan_path": ".longtask/state/{spec_basename}/plan.md",
  "implementation_plan_sha256": "...",
  "plan_integrity_review_path": ".longtask/state/{spec_basename}/plan-integrity.json",

  "model_requests": [
    {"role": "phase-worker-P1-r1", "requested": "gpt-5.5/xhigh",
     "actual": "gpt-5.4/high", "reason": "model unavailable",
     "model_degraded": true}
  ],

  "agents": [
    {"agent_id": "...", "role": "phase-sub-agent", "phase": "P1", "round": 0,
     "start_at": "...", "end_at": "..."}
  ],

  "claude_subagents": [
    {"id": "claude-<uuid>", "role": "decision-review-primary", "model": "opus",
     "phase": "P3", "start_at": "...", "end_at": "..."}
  ],
  "codex_subagents": [
    {"id": "codex-<thread_id>", "role": "spec-classifier", "model": "gpt-5.5",
     "reasoning": "xhigh", "start_at": "...", "end_at": "..."}
  ],
  "hybrid_lens_assignments": {
    "decision-review": ["claude-opus-primary", "codex-gpt5.5-secondary"],
    "plan-integrity-review": ["claude-opus-primary", "codex-gpt5.5-secondary"],
    "final-alignment-review": ["claude-opus-primary", "codex-gpt5.5-secondary"],
    "roundtable.round-1.engineering": ["claude-opus-primary"],
    "roundtable.round-1.ceo-product": ["codex-gpt5.5-primary"]
  },

  "phases": {
    "P1": {
      "status": "PASS | FAIL | BLOCKED_* | running",
      "rounds_used": 2,
      "verifier_json_paths": [".longtask/state/.../verifier-P1-r1.json",
                              ".longtask/state/.../verifier-P1-r2.json"],
      "commit_sha": "...",
      "last_heartbeat": "ISO 8601",
      "heartbeats": [{"at": "...", "event": "phase-start"},
                     {"at": "...", "event": "round-1-codex-worker-start"}]
    }
  },

  "final_report_path": ".longtask/reports/.../final-report.md",
  "final_alignment_review_path": ".longtask/state/.../final-alignment.json"
}
```

**Resume protocol:** orchestrator reads state on `/longtask <spec> --resume` (or detects existing state path). Restarts from the first phase whose status is not `PASS`. Re-runs Steps 0-4 only if `input_sha256` differs from current source file (drift → BLOCKED_SPEC).

## Prompts and wrapper (file index)

```
~/.claude/skills/longtask/
├── SKILL.md                          # this file
├── README.md / README.en.md          # quick-start (Chinese / English)
├── lib/
│   ├── codex-wrapper.sh              # stall-only wrapper, --json + --output-schema
│   └── smoke.sh                      # static sanity check (schema parse + wrapper syntax)
├── schemas/
│   ├── verifier-result.schema.json   # phase verifier output
│   ├── decision-review.schema.json   # decision-gate verdict
│   └── plan-integrity-review.schema.json
└── prompts/
    # === Orchestrator + per-phase ===
    ├── claude-orchestrator.md        # main session checklist (Owner four-step + 9-step pipeline)
    ├── claude-sub-agent.md           # per-phase Claude Agent prompt (schema-driven verifier)
    # === Step 1-4 (a / b) ===
    ├── spec-classifier.md            # Claude Agent — input classification + risk
    ├── spec-roundtable.md            # per-lens hybrid roundtable
    ├── spec-round-state.md           # round-state editor (Claude Agent)
    ├── spec-consensus-editor.md      # hybrid consensus
    ├── spec-codex-sanity.md          # Codex single-pass spec audit (unconditional Step 3)
    ├── plan-writer.md                # Claude Agent invokes superpowers:writing-plans (multi-agent ≥3 phases)
    # === Step 5 / 6 / 8 hybrid gates ===
    ├── plan-integrity-review.md      # hybrid: Claude primary + Codex secondary
    ├── decision-review.md            # hybrid: Claude primary + Codex secondary
    ├── final-alignment-review.md     # hybrid: MANDATORY DUAL
    # === Step 6 codex children ===
    ├── codex-worker.md               # codex exec (writes code)
    ├── codex-verifier.md             # codex exec --output-schema (JSON verdict)
    ├── codex-worker-retry.md         # carries prior verifier JSON
    # === Step 7 ===
    ├── final-e2e2-report.md          # Claude Agent (gstack browse / screenshots; proactive residual-risk flagging)
    # === Cross-cutting ===
    └── known-traps-appendix.md       # 5 categories of execution-environment traps
```

## Project-specific tuning — convention-based context injection

Per-phase sub-agent auto-injects project context docs into worker prompts. Convention table (each row: convention path → scope filter):

| Path | When injected |
|---|---|
| `docs/archive/CODEX_PROTOCOL.md` | always (universal Codex chestnuts) — decision #3b |
| `docs/STYLE_GUIDE.md` | always |
| `docs/MODEL_RULES.md` | when `file_scope` matches `ml/**`, `models/**`, `training/**` |
| `docs/SECURITY_RULES.md` | when `file_scope` matches auth/, api/, security/, middleware/ |
| `docs/ALGO_RULES.md` | when `file_scope` matches algorithms/, solvers/, optim/ |
| `docs/_meta/code-truth-pointers.md` | always (concept → code path map) |

Spec frontmatter `inject_context:` (already shown above) overrides this table:
- `always:` — extra paths injected on every phase
- `when_scope_matches:` — extra scope-filtered paths
- `exclude:` — paths removed from the resolved set

If the cumulative injected bundle exceeds 10 KB, the sub-agent emits a `context-bundle-large` heartbeat and keeps going (does NOT silently truncate — the load-bearing invariant is that the worker reads the project's rules verbatim, not a summary).

## Known traps

See [`prompts/known-traps-appendix.md`](prompts/known-traps-appendix.md) for the full 5-category list:

1. **Codex CLI quirks** — #19945 PTY workaround, prompt must be file path, exit 142 = STALL
2. **Reward hacking patterns** — mock substitution, assert True, skip/xfail without reason, hardcoded returns, test deletion
3. **Scope drift** — worker writes outside file_scope, modifies do_not_touch, gradual cross-round drift
4. **Verifier integrity** — verifier writing source, skipping verify_cmd, schema-compliant but semantically empty
5. **Claude harness specifics** — Agent tool background timeout, 1M context budget, exit 142 ≠ FAIL, /ship cannot self-retry

The worker prompt receives the full appendix prepended. The verifier and decision-gate prompts receive only a checklist-style reference (`See known-traps-appendix.md categories 2 (reward hacking) and 4 (verifier integrity).`).

## Progress reporting (mandatory)

Per-phase sub-agent emits one progress line per heartbeat boundary. Format:

```
🔧 {Pn} round {N}/{max} · {role}-{state}
```

Examples: `🔧 P2 round 1/3 · codex-worker-start`, `🔧 P2 round 1/3 · codex-verifier-done verdict=FAIL`.

Orchestrator emits one progress line per Step boundary:

```
📋 Step {N} · {role} · {state}
```

Examples: `📋 Step 1 · classifier · in-progress`, `📋 Step 4 · plan-integrity · PASS`, `📋 Step 7 · final-alignment · MANDATORY DUAL · waiting`.

## Repo provenance (decision #8 — owner pending)

This skill repo and the Codex-end equivalent (`~/.codex/skills/longtask/`) both track `git@github.com:HannibalLeo/longtask-skill.git`. Push policy is an open call between:
- (a) push to the same `main` (different SKILL.md headings keep them disambiguated)
- (b) fork to a Claude-only repo (cleaner divergence; recommended by orchestrator)

Until decided, both ends commit locally and skip push.

## Roadmap (deferred enhancements — implement only when the underlying need bites)

- Cross-spec parallel execution (multiple `/longtask` runs sharing the same Claude session)
- Live progress dashboard (HTML view of state file)
- Auto-suggest `roundtable_mode: dual` when classifier `risk_reasons` includes regulatory / clinical / security
- Auto-extract REQ-* anchors from source_spec markdown headings (`<!-- REQ-XYZ -->`) instead of relying on spec-writer to enumerate
- Cost-model dashboard from `model_requests[]` aggregation
