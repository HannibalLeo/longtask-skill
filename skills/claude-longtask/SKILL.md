---
name: longtask
description: Multi-phase spec execution — Claude opus orchestrator + per-phase Claude worker (sonnet/opus, tier-selectable per phase) + Codex GPT-5.5 verifier via `codex exec --output-schema`, with cross-rounds roundtable (codex lenses → codex mid-summary → claude lenses → claude end-summary, repeated 1-3 rounds per stage) and opus 4.7 xhigh terminal review. Use when a written spec file declares phased work (P1, P2…) and strict separation of executor/verifier/judge is desired. Triggers on /longtask, "execute this spec", "run the spec", "long task", "长任务", "spec 文件执行".
---

# /longtask — v0.4 cross-rounds (Claude + Codex)

> **Quality bar — non-negotiable.** No hidden defects, no minimal patches that paper over symptoms. Every decision serves "ships to real users", not "the test happens to be green". The 4 production-grade principles (simplicity beats cleverness, evals before optimization, tight iteration over big leaps, taste is part of shippable) are summarized in [README.md](README.md).

## When to use

Use when ALL of: a written spec file declares phased work (P1, P2, P3...); task is M/L (>5 min, multi-step); user wants Codex CLI to do the bulk of code work while Claude owns architecture judgment, judgment gates, and final verification.

**Recommended starting point** when the spec does not yet exist: run `gstack /office-hours` to interrogate the idea, then `gstack /plan-ceo-review` + `gstack /plan-eng-review` to lock product/architecture decisions. v2 also supports running the **built-in spec-classifier → roundtable → plan-writer → plan-integrity** pipeline against a raw `source_spec` input — see `## Pipeline overview` step 1-4.

Skip for: <5 min tasks; single-file edits where verifying is "read the diff".

## Owner 四步分工 (required reading — defines who runs what)

| Step | Owner | Scope |
|---|---|---|
| **(a) Claude does architecture** | Claude opus (main session + Agent tool) | Spec classification, plan writing, plan-integrity review. All "understand the spec, split it, decide who verifies" judgments. |
| **(b) Claude + Codex discuss** | Mixed | Cross-rounds roundtable (v0.4): every round is a cross-pair (codex × all lenses → codex xhigh mid-summary → claude × all lenses → claude opus end-summary). Lenses are NOT model-bound — every lens runs both codex and claude per round. Consensus editor is single Claude opus; cross-rounds-final-review (opus 4.7 xhigh) is the terminal gate. |
| **(c) Claude worker writes; Codex verifier judges** | Claude (sonnet default, opus / haiku per `model_tier`) via Agent tool + Codex GPT-5.5 via `codex exec --output-schema` | Phase worker writes code in a fresh Claude Agent; phase verifier is a separate Codex GPT-5.5 process that re-reads the working tree, runs `verify_cmd`, and emits schema-driven JSON. The cross-model split is load-bearing: the judge has a different distribution of blindspots than the worker, and `--output-schema` enforces parseable JSON regardless of how the worker phrased its own progress. |
| **(d) Claude finalizes** | Claude opus (main session) | Reads every verifier JSON to decide PASS/retry, runs hybrid decision/plan-integrity/final-alignment gates, runs final E2E2 (browser/screenshots via Claude harness), syncs docs, ships. |

**Load-bearing invariants for (c)→(d):**

1. **Worker is Claude, verifier is Codex.** This is the cross-model split. Do
   not swap roles even if it looks more convenient. Worker = `claude-{tier}`
   selected per phase; verifier = Codex GPT-5.5 (`gpt-5.5/xhigh` default via
   `lib/codex-wrapper.sh`).
2. **Codex emits schema-conforming JSON, Claude reads it.** The verifier uses
   `codex exec --output-schema schemas/verifier-result.schema.json` so the
   verdict is parseable by construction. The Claude sub-agent and main
   session never read source files during PASS/FAIL judgment (preserves
   context budget) but hold final authority (preserves safety).

## Pipeline overview (v0.4)

```
Step 0  Preflight              Validate spec frontmatter + state schema
Step 1  Classifier             Claude Agent → JSON {input_shape, cross_rounds, required_lenses, risk_reasons, pre_vetted}
                               cross_rounds ∈ {1, 2, 3}; pre_vetted gates spec-stage skip
Step 2  Spec-roundtable        (skippable iff pre_vetted) cross_rounds × cross-pair rounds
                               (codex × lenses → codex mid-summary → claude × lenses → claude end-summary)
                               → spec-consensus-editor (single Claude opus, writes enhanced-spec)
                               → cross-rounds-final-review (opus 4.7 xhigh, terminal verdict)
Step 3  Codex spec sanity      (UNCONDITIONAL) Codex GPT-5.5 single pass: omissions / hallucinations / contradictions
                               / reward-hacking bait → JSON {verdict: CLEAN | NEEDS_REVISION}
Step 4  Plan-writer            Claude Agent invokes superpowers:writing-plans → implementation_plan.md
                               (multi-agent dispatch when plan has ≥3 phases)
Step 4b Plan-roundtable        (ALWAYS RUN, cross_rounds ≥ 1) Same cross-pair shape as Step 2
                               → plan-consensus-editor (single Claude opus, rewrites plan.md in place)
                               → cross-rounds-final-review (opus 4.7 xhigh, terminal verdict)
Step 5  Plan-integrity         HYBRID gate (Claude primary + Codex secondary) → PASS or BLOCKED_SPEC_REWRITE
Step 6  Per-phase loop         For each Pn: Claude sub-agent dispatches Claude worker (Agent tool, model from model_tier) → scope gate → Codex verifier (codex exec --output-schema)
                               → main-line JSON review → commit on PASS
Step 7  Final E2E2             Claude Agent runs final_verify_cmd + final_e2e2_cmd → screenshots → final_report
Step 8  Final-alignment        MANDATORY DUAL hybrid gate (Claude + Codex always both run) → PASS or escalate
Step 9  Ship (optional)        spec.docs_sync → update-docs; spec.ship → gstack /ship
```

**Step 2 (spec-roundtable)** is skipped **only** when classifier emits
`pre_vetted.is_pre_vetted == true` (inputs of shape `plan_with_source` /
`self_contained_plan`, or `source_spec` whose `gating: [office-hours,
plan-ceo-review, plan-eng-review]` already ran in the same session). All other
inputs run spec-roundtable at `cross_rounds`. **Step 4b (plan-roundtable) is
never skipped** — every plan gets at least 1 cross-pair round before
plan-integrity, because the plan is the concrete execution contract and
late-stage criticism is the cheapest defense against bad phase decomposition.
**Step 3 is also unconditional** — codex sanity audit always runs as the
cross-model second opinion on the spec.

**Subagent count per stage** = `2 × |required_lenses| × cross_rounds`
(lens dispatches) `+ 2 × cross_rounds` (mid-summary + end-summary per round)
`+ 2` (consensus-editor + cross-rounds-final-review). With the default 5
lenses, this is `12 × cross_rounds + 2` per stage: cross_rounds=1/2/3 →
14 / 26 / 38 dispatches per stage. Both stages combined (when spec runs) →
28 / 52 / 76. Note the shape is sequenced *within* a round (Phase 1-4) but
*parallel across lenses within each Phase*.

## Where details live (load-bearing — read before writing specs/plans)

| Artifact | What lives here | What does NOT live here |
|---|---|---|
| **Source spec** (you write) | Product intent, REQ-*, success criteria, business constraints | Implementation details, architecture decisions (those are derived in roundtable) |
| **Enhanced spec** (consensus editor writes) | Architecture decisions, formulas, threshold tables, schema shapes, named invariants, non-obvious constraints, REQ-E-* clarifications, out-of-scope items with rationale | Phase decomposition, code, test snippets |
| **Implementation plan** (plan-writer writes) | Phase decomposition (P1, P2, ...) — for each phase: `goals`, `file_scope`, `do_not_touch`, `verify_cmd`, `verify_passes_when`, `dod`, `source_requirements`, `max_retry_rounds`, optional `model_tier` / `reasoning_effort`; Source Requirements table; Alignment Matrix; Final E2E2 contract | Code snippets, test code, TDD micro-steps ("Step 1: write failing test..."), per-file change recipes, formulas, threshold tables, architecture diagrams, roundtable consensus dumps — **all these belong in the enhanced spec or are derived at runtime by the worker** |
| **Phase commit + worker output** | Real code, real tests, real diffs | — |
| **Verifier JSON** | PASS/FAIL + dod_results + reward_hacking_signals + verify_cmd output | — |

The plan is a **thin executable contract**, not a code draft. Detail that
already lives in the enhanced spec MUST NOT be copied into the plan.
Implementation details that the worker would derive correctly from a
clear contract MUST NOT be pre-decided in the plan. Worker input already
includes the plan as context AND the worker emits code as output — any
code in the plan is paid twice (input + output tokens for the same
content). TDD rhythm is enforced by the worker's TDD sub-skill, not by
plan-writer's micro-step lists.

**Line budget** (enforced by `plan-writer.md` / `plan-consensus-editor.md`):
- Per phase block: target 80-150 lines, hard cap 200 lines.
- Total plan: target ≤ 720 lines, hard cap 1000 lines regardless of
  phase count.
- Exceeding the hard cap → `BLOCKED_PLAN_REPAIR`: route detail to
  enhanced spec or split phases. Do not weaken the budget.

## Spec schema (REQUIRED — orchestrator validates at Step 1 or Step 4)

> **Where v2 frontmatter validation happens** — this matters for understanding
> what to put on a hand-written design doc vs. an executable plan:
>
> - **Hand-written `source_spec` / `hybrid` design docs** (the typical input):
>   you do NOT need to add `source_spec_path` / `final_verify_cmd` / etc. to
>   the frontmatter. plan-writer (Step 4) generates a v2-formatted execution
>   plan from your design doc, and the v2 schema is validated on **that
>   generated plan**, not on your input.
> - **Pre-built `plan_with_source` / `self_contained_plan` inputs**: these
>   skip plan-writer, so the v2 frontmatter MUST already be present on the
>   input. Step 1 (after classifier confirms the shape) enforces this with
>   `BLOCKED_SPEC` + a concrete diff of missing fields.
>
> Step 0 itself only checks that the file is readable and that the worktree is
> clean — it never asks the user "how should I handle the v2 schema gap?".

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

default_model_tier: sonnet   # one of: haiku | sonnet | opus
# Required (v0.4+). Default Claude model the Step 6 per-phase worker runs on
# when this spec is executed by claude-longtask.
# Tier → model:
#   haiku  → claude-haiku-4-5   (mechanical / trivial phases only)
#   sonnet → claude-sonnet-4-6  (DEFAULT — covers most implementation work)
#   opus   → claude-opus-4-7    (novel design, cross-module, fragile refactors)
# Resolution order at dispatch time:
#   phase.model_tier  >  spec.default_model_tier  >  hard fallback 'sonnet'
# Missing → BLOCKED_SPEC. Unrecognised tier → BLOCKED_SPEC.
# Ignored when this spec is executed by codex-longtask (codex uses
# default_reasoning_effort instead).

default_reasoning_effort: medium  # one of: medium | high | xhigh
# Required (v0.4+). Default `model_reasoning_effort` the Step 6
# worker / retry-worker / verifier sub-agents run on when this spec is
# executed by codex-longtask. Designed for the case where the main codex
# session (conductor) is running at `xhigh`, but the cost-dominant execution
# sub-agents should drop to `medium` unless a specific phase needs more
# headroom.
# Resolution order at dispatch time:
#   phase.reasoning_effort  >  spec.default_reasoning_effort  >  hard fallback 'medium'
# Retry rounds auto-escalate one tier (medium → high → xhigh) unless the
# phase explicitly pins reasoning_effort.
# Scope: applies ONLY to worker / retry-worker / verifier. Judgment-heavy
# roles (classifier, roundtable lenses, mid-summary, consensus editor, plan
# writer, plan-integrity, decision-review, final-alignment, cross-rounds
# final review) stay at `xhigh` regardless of this field.
# Missing → BLOCKED_SPEC. Unrecognised effort → BLOCKED_SPEC.
# Ignored when this spec is executed by claude-longtask.

# === OPTIONAL v2 fields ===

cross_rounds: 2   # one of: 1, 2, 3  (omit to let classifier decide)
# Override classifier's cross_rounds choice. Applied to BOTH spec-roundtable
# (Step 2) and plan-roundtable (Step 4b). Each round is a cross-pair:
#   Phase 1: codex × all lenses (parallel)
#   Phase 2: codex xhigh mid-round summary
#   Phase 3: claude × all lenses (parallel, sees Phase 1 + Phase 2 output)
#   Phase 4: claude opus end-round summary (writes round-state)
# After the final round, a single Claude opus consensus-editor rewrites the
# enhanced spec / plan in place, then a opus 4.7 xhigh cross-rounds-final-review
# does the terminal PASS / NEEDS_REVISION verdict.
#
# REMOVED v0.4: `roundtable_mode` (hybrid/dual). Cross-model heterogeneity is
# now built into every round by construction (every lens runs both codex and
# claude per round) — there is no longer a knob.
# REMOVED v0.3.x: legacy `discussion_required`, `discussion_rounds`,
# `spec_rounds`, `plan_rounds`, `tier_label`.

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

# Optional per-phase overrides.
# model_tier: opus            # haiku | sonnet | opus — claude-longtask worker
# reasoning_effort: high      # medium | high | xhigh — codex-longtask worker/retry-worker/verifier

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
  ├─ dispatches Claude Agents (classifier, roundtable claude-phase lenses,
  │   claude end-round summary, consensus-editor, cross-rounds-final-review (opus 4.7 xhigh),
  │   plan-writer, plan-integrity primary, final-e2e2, final-alignment primary,
  │   docs-sync, ship)
  └─ dispatches `codex exec` children for:
        roundtable codex-phase lenses (all 5 lenses, every round)
        codex mid-round summary (every round)
        codex spec sanity (Step 3)
        plan-integrity secondary
        decision-review secondary
        final-alignment secondary (MANDATORY DUAL)
  ↓
Claude Sub-Agent (opus, fresh per phase)  = Phase Conductor
  ├─ runs per-phase loop end-to-end
  ├─ resolves model_tier (phase override > spec default > 'sonnet') → model id
  ├─ dispatches Claude worker via Agent tool:
  │     claude-worker  (writes code, writes worker-output.json)
  │     claude-worker-retry (carries prior verifier JSON)
  ├─ dispatches `codex exec` verifier:
  │     codex-verifier (--output-schema verifier-result.schema.json)
  ├─ enforces scope gate (git diff --name-only vs file_scope)
  ├─ reads verifier JSON, applies main-line PASS/FAIL
  ├─ on worker-proposed decision_options[]: escalates to orchestrator for hybrid
  │     decision-review gate
  └─ commits on PASS, returns {verdict, rounds_used, commit_sha} to orchestrator
  ↓
Claude worker children (Agent tool, one-shot, model from model_tier)
  ├─ claude-worker         — writes code in file_scope; writes worker-output.json
  └─ claude-worker-retry   — fed prior verifier JSON; same output contract
  ↓
codex exec children (one-shot, GPT-5.5)
  ├─ codex-verifier        — read-only; runs verify_cmd; produces schema JSON
  ├─ roundtable codex lens — Phase 1 of each cross-pair round, all lenses parallel
  ├─ codex mid-summary     — Phase 2 of each cross-pair round, xhigh
  └─ judgment secondary    — plan-integrity / decision-review / final-alignment
```

| Tier | Reads source files? | Writes code? | Commits? | Persistence |
|---|---|---|---|---|
| **Orchestrator (Claude main)** | spec + state + JSON outputs only | NO | NO | survives whole spec |
| **Sub-Agent (Claude Agent, opus)** | spec + git diff + verifier JSON + worker-output.json + state | NO (only authors worker / verifier prompts) | YES (after main-line PASS) | per phase, killed on DONE |
| **claude-worker** | spec + scoped files | YES (working tree only, file_scope) | NO | one-shot per round; output is worker-output.json |
| **codex-verifier** | spec + working tree + verify_cmd output | NO | NO | one-shot per round; output is JSON |

## Role × Model dispatch matrix (v0.4)

| Role | Model | Dispatch | Step |
|---|---|---|---|
| Orchestrator | Claude main (opus) | this session | (a) |
| Per-phase sub-agent | Claude Agent (opus) | Agent tool | (a) |
| **Spec classifier** | Claude opus | Agent tool | **(a)** |
| Spec-roundtable lens (codex phase, any lens) | Codex GPT-5.5 xhigh | `codex exec` | (b) |
| Spec-roundtable codex mid-round summary | Codex GPT-5.5 xhigh | `codex exec` | (b) |
| Spec-roundtable lens (claude phase, any lens) | Claude opus | Agent tool | (b) |
| Spec-roundtable claude end-round summary (round-state) | Claude opus | Agent tool | (b) |
| **Spec consensus editor** (single author, v0.4) | Claude opus | Agent tool | (b) |
| **Spec cross-rounds final review** | **Claude opus 4.7 xhigh** | Agent tool | **(b)+(d)** |
| **Codex spec sanity** | **Codex GPT-5.5 xhigh** (unconditional second-opinion audit) | `codex exec --output-schema` | **(b)** |
| **Plan-writer** | **Claude opus** (invokes `superpowers:writing-plans`; multi-agent dispatch when plan ≥3 phases) | Agent tool | **(a)** |
| Plan-roundtable lens (codex phase, any lens) | Codex GPT-5.5 xhigh | `codex exec` | (b) |
| Plan-roundtable codex mid-round summary | Codex GPT-5.5 xhigh | `codex exec` | (b) |
| Plan-roundtable lens (claude phase, any lens) | Claude opus | Agent tool | (b) |
| Plan-roundtable claude end-round summary (round-state) | Claude opus | Agent tool | (b) |
| **Plan consensus editor** (single author, v0.4) | Claude opus | Agent tool | (b) |
| **Plan cross-rounds final review** | **Claude opus 4.7 xhigh** | Agent tool | **(b)+(d)** |
| **Plan-integrity review** | **Claude opus primary + Codex GPT-5.5 xhigh secondary** | hybrid (decision #6) | **(a)+(d)** |
| Phase worker | **Claude** — model selected per phase: `claude-haiku-4-5` / `claude-sonnet-4-6` / `claude-opus-4-7`, resolved from `phase.model_tier > spec.default_model_tier > 'sonnet'` | `Agent` tool (one fresh Agent per round) | (c) |
| **Phase verifier** | Codex GPT-5.5 (schema-driven JSON) → Claude main-line reads JSON | `codex exec --output-schema` → Claude review | **(c)→(d)** |
| **Decision gate** | **Claude opus primary + Codex GPT-5.5 xhigh secondary** | hybrid (decision #6) | **(b)+(d)** |
| Final E2E2 report | Claude opus | Agent tool (gstack browse skill) | (d) |
| **Final-alignment review** | **Claude opus primary + Codex GPT-5.5 xhigh secondary** (**always dual**) | hybrid, mandatory dual | **(d)** |
| Docs sync (`update-docs`) | Claude opus | Agent tool / Skill tool | (d) |
| Ship (`/ship`) | Claude main | Skill tool (gstack /ship) | (d) |

**Lenses are NOT model-bound in v0.4.** Every selected lens (default 5:
engineering / ceo-product / design / ui-design / domain-expert) runs ONCE as
codex (Phase 1 of a round) and ONCE as Claude Agent (Phase 3 of a round).
Cross-model heterogeneity is built into every round by construction.

## Cross-rounds roundtable semantics (v0.4)

Every roundtable round is a **cross-pair** — codex and claude both reading
the same artifact, sequenced so the second model sees the first's output:

```
Round R (1..cross_rounds):
  Phase 1: codex × all required_lenses (parallel codex exec)
  Phase 2: codex xhigh mid-round summary (1 codex exec)
  Phase 3: claude × all required_lenses (parallel Claude Agent)
           Each claude-phase lens reads:
             - the same artifact
             - the codex-phase output for ALL lenses this round
             - the codex mid-summary
             - prior round-state (if any)
  Phase 4: claude opus end-round summary (writes round-state markdown + JSON)
```

The codex side surfaces same-distribution convergence and codex-side
blindspots; the claude side either confirms (real consensus) or
disagrees (codex blindspot corrected); the round-state captures both
verdicts and the unresolved cross-phase disagreements explicitly.

The previous `hybrid` / `dual` `roundtable_mode` knob is gone. Heterogeneity
is built in — there is no longer a single-model degraded mode at all.

**Length policy — `cross_rounds ∈ {1, 2, 3}`, three fixed tiers:**

| cross_rounds | When | Per-stage subagent count (5 lenses) |
|---|---|---|
| **1** | Low-risk unvetted `source_spec` / `hybrid`, OR pre-vetted inputs (`pre_vetted.is_pre_vetted == true` skips spec stage entirely; plan stage still runs at cross_rounds=1). Default minimum. | 14 |
| **2** | Medium-risk: cross-module contract change / new external dependency / plan will have ≥4 phases / ambiguous scope. Cite reason in `risk_reasons`. | 26 |
| **3** | High-risk: irreversible data migration / regulatory / clinical / patient-safety / security boundary / breaking external API contract / cross-module blast radius (>3 modules). Cite trigger in `risk_reasons`. | 38 |

- **plan-roundtable is non-skippable.** Even when `pre_vetted == true` (spec
  stage skipped), plan stage runs at the chosen `cross_rounds` because the
  plan is the final execution contract.
- **No mode knob in v0.4.** Cross-model heterogeneity is structural, not
  optional. If either Codex or Claude dispatch fails on any lens →
  `BLOCKED_CODEX_WRAPPER_FAILURE` / `BLOCKED_AGENT_TOOL_FAILURE`, not silent
  degradation.
- **No tier > 3.** Empirical observation: rounds 4+ within a stage restate
  earlier arguments rather than surface new ones. If a risk truly warrants
  more scrutiny than `cross_rounds: 3`, that is a `source_spec` rewrite
  signal, not a tuning-knob signal.
- **Pre-vetting is orthogonal to risk.** A high-risk pre-vetted plan still
  runs plan-roundtable at `cross_rounds: 3`. `pre_vetted` only gates the
  spec-stage skip; it does not lower the round count.

**Mode resolution (orchestrator never asks the user):**
```
spec.cross_rounds (frontmatter)  >  classifier.cross_rounds  >  classifier default (1)
```
The classifier is empowered to escalate based on `risk_reasons`. The user
can only override DOWNWARD via frontmatter (e.g., "I know better, run only
1 round even though classifier said 3") — escalation upward by user
frontmatter is honored but discouraged (let the classifier do its job).

## Hybrid judgment gates — reconciliation (decision #6)

Three gates run as Claude-primary + Codex-secondary hybrid:
1. **plan-integrity-review** (Step 5)
2. **decision-review** (Step 6, when worker returns `decision_options[]`)
3. **final-alignment-review** (Step 8, **mandatory dual** — last-line-of-defense)

Reconciliation rules (each gate prompt restates these so reviewers know their `vetoes[]` matter):

1. Both verdicts agree → use that verdict.
2. Disagreement + any side `vetoes[]` non-empty → `ASK_HUMAN` **immediately**, no Clarification Round. Veto categories: irreversible, security boundary, scope contract break, regulatory / data-loss.
3. Disagreement + no vetoes + `confidence` delta > 0.15 + the chosen option is **local + reversible + inside spec + mechanically verifiable** → higher-confidence side wins.
4. Otherwise → **Uncertainty Clarification Round** (one extra `codex exec` pass, see orchestrator's "Uncertainty Clarification Round" section). PROCEED → apply chosen option, log residual concerns. ESCALATE → `ASK_HUMAN` with full chain attached.

**Clarification Round vs. third arbiter.** The Clarification Round is not a vote-counting third opinion — it's a tie-breaker that sees both prior verdicts and the evidence, and either resolves the disagreement with cited reasoning or escalates. It NEVER fires when a veto is present (those are categorical) and NEVER fires at Step 8 final-alignment-review (already mandatory dual; the whole point there is to surface unresolved disagreement). The user is still the final arbiter when reasoning runs out.

## Phase verifier flow (the (c)→(d) handoff)

```
Claude worker (Agent tool, model from model_tier) writes code +
  worker-output.json (working tree mutations only, no commit)
         ↓
Claude sub-agent: parse worker-output.json; git status --porcelain +
  git diff --name-only HEAD
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
FAIL → reset worktree → spawn claude-worker-retry (same model_tier) with prior
       verifier JSON embedded → next round (up to max_retry_rounds)
After max retries exhausted → BLOCKED + escalate to orchestrator
```

**Load-bearing invariants:**

1. Worker = Claude Agent; verifier = Codex `codex exec --output-schema`.
   Cross-model heterogeneity prevents reward-hacking and reduces shared blindspots.
2. Codex emits JSON; Claude reads JSON. Claude sub-agent does not read source
   files during PASS/FAIL judgment (context preservation); Claude holds the
   final PASS/FAIL judgment (safety).

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

All remaining Codex children — **phase verifier** (Step 6), roundtable lenses
(Steps 2 / 4b), roundtable mid-summary, codex spec sanity (Step 3),
plan-integrity / decision-review / final-alignment secondaries — go through
`lib/codex-wrapper.sh`. **The Step 6 worker no longer uses this wrapper** —
worker dispatch moved to the `Agent` tool with model resolved per phase from
`model_tier`. It is a stall-only wrapper around `codex exec` with v2 additions:

- **Default model** = `gpt-5.5` (env: `CODEX_LONGTASK_MODEL`)
- **Default reasoning** = `xhigh` (env: `CODEX_LONGTASK_REASONING`) — kept at
  `xhigh` because the wrapper now only serves the verifier and judgment-gate
  roles where reasoning quality is load-bearing; the worker (previously the
  cost-dominant caller at `xhigh`) is on Claude now and pays no cost here.
- **Sandbox** = `workspace-write` (env: `CODEX_LONGTASK_SANDBOX`)
- **Approvals** = `never` (env: `CODEX_LONGTASK_APPROVALS`) — no in-phase approval prompts
- **Stall kill** = 10 min no new stdout line → exit 142 (env: `CODEX_LONGTASK_STALL_SECONDS`)
- **Structured output** = pass `OUTPUT_SCHEMA` (arg 3) → adds `--output-schema <file>`; pass `LAST_MESSAGE` (arg 4) → adds `-o <file>` (canonical JSON of last message). Both used by verifier / hybrid-judgment dispatches.
- **JSONL events** = `--json` always on, so Claude main-line can parse per-turn events.
- **PTY routing + overrides** = `script -q /dev/null` is used adaptively: default PTY when stderr is not a TTY, default direct when stderr is a TTY. [non-active-wrapper-env-mention] Maintainer-only debug escape hatch: `CODEX_LONGTASK_DISABLE_PTY=1` forces direct and `CODEX_LONGTASK_FORCE_PTY=1` forces PTY; do not instruct sub-agents to set these in normal execution.
- **Stdin** = prompt MUST be passed as a file path (positional arg 1). Inline prompts via stdin pipe trigger a codex hang.

Exit codes:
- `0` — codex finished normally
- `142` — STALL_TIMEOUT (10 min no stdout line)
- `2` — wrapper usage error
- `*` — codex non-zero exit (propagated; becomes `BLOCKED_CODEX_WRAPPER_FAILURE` for non-142)

Model-policy logging: on each invocation, sub-agent records `state.model_requests[]` entry: `{role, requested, actual, reason, model_degraded}`. Fallback to `gpt-5.4 high` is permitted only as cost fallback and MUST log `model_degraded=true`.

## State file (v2 schema)

State lives at `.longtask/state/{spec_basename}.json`. Full reference example: [`schemas/state-example.json`](schemas/state-example.json). Field groups the orchestrator must write/read:

| Group | Keys | Purpose |
|---|---|---|
| Identity | `mode`, `spec_path`, `spec_sha256`, `input_path`, `input_sha256`, `input_shape` | Pin the run to a specific spec sha; resume drift check |
| Spec stage | `classification_path`, `spec_roundtable_skipped_reason`, `spec_cross_round_codex_mid_summary_paths[]`, `spec_cross_round_state_paths[]`, `spec_consensus_editor_path`, `enhanced_spec_path`, `enhanced_spec_sha256`, `spec_update_path`, `spec_cross_rounds_final_review_path`, `spec_cross_rounds_final_review_verdict`, `spec_cross_rounds_residual_risks[]` | Step 1-3 artifacts |
| Plan stage | `implementation_plan_path`, `implementation_plan_sha256`, `plan_cross_round_codex_mid_summary_paths[]`, `plan_cross_round_state_paths[]`, `plan_consensus_editor_path`, `implementation_plan_post_cross_rounds_sha256`, `plan_cross_rounds_final_review_path`, `plan_cross_rounds_final_review_verdict`, `plan_cross_rounds_residual_risks[]`, `plan_integrity_review_path` | Step 4 / 4b / 5 artifacts |
| Per-phase | `phases.{Pn}.{status, rounds_used, verifier_json_paths[], commit_sha, last_heartbeat, heartbeats[]}` | Step 6 progress + commit chain |
| Final | `final_report_path`, `final_alignment_review_path` | Step 7-8 artifacts |
| Model accounting | `model_requests[]` (`{role, requested, actual, reason, model_degraded}`), `agents[]`, `claude_subagents[]`, `codex_subagents[]`, `hybrid_gate_assignments` | Auditability + cost dashboard |

Minimal example (one phase mid-run):

```json
{
  "mode": "claude-cross-rounds",
  "spec_path": "...", "spec_sha256": "...",
  "input_shape": "source_spec",
  "implementation_plan_sha256": "...",
  "implementation_plan_post_cross_rounds_sha256": "...",
  "phases": {"P1": {"status": "running", "rounds_used": 1, "last_heartbeat": "..."}}
}
```

**Resume protocol:** orchestrator reads state on `/longtask <spec> --resume` (or detects existing state path). Restarts from the first phase whose status is not `PASS`. Re-runs Steps 0-4b only if `input_sha256` differs from current source file (drift → BLOCKED_SPEC).

## Prompts and wrapper (file index)

> **Path convention** — this skill is a plugin (`longtask` plugin in the
> `longtask-skill` marketplace). All paths below are **relative to the plugin
> root** (the directory containing `package.json`). At runtime that resolves to
> `~/.claude/plugins/cache/longtask-skill/longtask/<version>/`. From this
> SKILL.md's location (`skills/longtask/SKILL.md`) the plugin root is `../..`,
> so e.g. `prompts/spec-classifier.md` lives at
> `../../prompts/spec-classifier.md`.

```
<plugin-root>/                                # = ~/.claude/plugins/cache/longtask-skill/longtask/<version>/
├── package.json                              # plugin manifest
├── README.md / README.en.md                  # quick-start (Chinese / English)
├── CHANGELOG.md                              # version history
├── VERSION                                   # current version string
├── LICENSE
├── lib/
│   ├── codex-wrapper.sh                      # stall-only wrapper, --json + --output-schema
│   └── smoke.sh                              # static sanity check (schema parse + wrapper syntax)
├── schemas/
│   ├── verifier-result.schema.json           # phase verifier output
│   ├── decision-review.schema.json           # decision-gate verdict
│   ├── plan-integrity-review.schema.json
│   ├── codex-clarification.schema.json       # uncertainty clarification verdict
│   └── state-example.json                    # reference example of .longtask/state/{spec}.json
├── prompts/
│   # === Orchestrator + per-phase ===
│   ├── claude-orchestrator.md                # main session checklist (Owner four-step + 9+1 pipeline)
│   ├── claude-sub-agent.md                   # per-phase Claude Agent prompt (schema-driven verifier)
│   # === Step 1-4b (a / b) ===
│   ├── spec-classifier.md                    # Claude Agent — input classification + tier {0+1, 1+1, 2+1, 3+2}
│   ├── spec-roundtable.md                    # Step 2 cross-pair lens prompt (codex phase + claude phase, same prompt)
│   ├── spec-codex-mid-summary.md             # Step 2 Phase 2 codex xhigh mid-round summary (NEW v0.4)
│   ├── spec-round-state.md                   # Step 2 Phase 4 claude opus end-round summary (round-state)
│   ├── spec-consensus-editor.md              # single Claude opus consensus → enhanced-spec
│   ├── spec-codex-sanity.md                  # Codex single-pass spec audit (unconditional Step 3)
│   ├── plan-writer.md                        # Step 4 — Claude Agent invokes superpowers:writing-plans (multi-agent ≥3 phases)
│   ├── plan-roundtable.md                    # Step 4b cross-pair lens prompt (codex phase + claude phase)
│   ├── plan-codex-mid-summary.md             # Step 4b Phase 2 codex xhigh mid-round summary (NEW v0.4)
│   ├── plan-round-state.md                   # Step 4b Phase 4 claude opus end-round summary (round-state)
│   ├── plan-consensus-editor.md              # single Claude opus consensus that revises plan.md in place
│   ├── cross-rounds-final-review.md          # Step 2 / 4b Phase 6 opus 4.7 xhigh terminal verdict (NEW v0.4)
│   # === Step 5 / 6 / 8 hybrid gates ===
│   ├── plan-integrity-review.md              # hybrid: Claude primary + Codex secondary
│   ├── decision-review.md                    # hybrid: Claude primary + Codex secondary
│   ├── final-alignment-review.md             # hybrid: MANDATORY DUAL
│   # === Step 6 children ===
│   ├── claude-worker.md                      # Agent tool (writes code; model from model_tier)
│   ├── claude-worker-retry.md                # Agent tool retry (carries prior verifier JSON)
│   ├── codex-verifier.md                     # codex exec --output-schema (JSON verdict)
│   ├── codex-worker.md                       # LEGACY — kept for codex-longtask variant
│   ├── codex-worker-retry.md                 # LEGACY — kept for codex-longtask variant
│   # === Step 7 ===
│   ├── final-e2e2-report.md                  # Claude Agent (gstack browse / screenshots; proactive residual-risk flagging)
│   # === Cross-cutting ===
│   ├── codex-clarification.md                # one-shot codex tie-breaker before any uncertainty-driven ASK_HUMAN
│   ├── known-traps-universal.md              # Categories 1-4 (codex CLI / reward hacking / scope / verifier) — all workers + verifiers
│   ├── known-traps-claude-only.md            # Category 5 (Claude harness specifics) — Claude workers only
│   └── known-traps-appendix.md               # DEPRECATED pointer (2026-05-27 split for token-waste refactor)
└── skills/
    ├── longtask/SKILL.md                     # this file — full pipeline (Steps 0-9)
    ├── longtaskPlan/SKILL.md                 # subset — Steps 0-5 (plan-only)
    └── longtaskCode/SKILL.md                 # subset — Steps 6-9 (execute a validated plan)
```

Invocation namespacing (plugin → skill): `/longtask:longtask`,
`/longtask:longtaskPlan`, `/longtask:longtaskCode`.

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

Split into two files per the 2026-05-27 token-waste refactor (REQ-001 / REQ-002):

- [`prompts/known-traps-universal.md`](prompts/known-traps-universal.md) — Categories 1–4 (universal across harnesses):
  1. **Codex CLI quirks** — #19945 PTY workaround, prompt must be file path, exit 142 = STALL
  2. **Reward hacking patterns** — mock substitution, assert True, skip/xfail without reason, hardcoded returns, test deletion
  3. **Scope drift** — worker writes outside file_scope, modifies do_not_touch, gradual cross-round drift
  4. **Verifier integrity** — verifier writing source, skipping verify_cmd, schema-compliant but semantically empty
- [`prompts/known-traps-claude-only.md`](prompts/known-traps-claude-only.md) — Category 5 (Claude harness specifics only):
  5. **Claude harness specifics** — Agent tool background timeout, 1M context budget, exit 142 ≠ FAIL, `/ship` cannot self-retry

Dispatch rules (set by `claude-sub-agent.md` Step 2a):
- **Claude worker** → `claude-sub-agent.md` concatenates universal + claude-only once per phase into `.longtask/known-traps-active-{spec_basename}.md`; the worker `Read`s that path as its first action (no verbatim prepend; saves ~215 lines × every worker dispatch).
- **Codex worker** → universal only (codex has no Agent tool, no 1M context, no `/ship` Skill).
- **Verifier / decision-gate / final-alignment** → checklist reference only: `See known-traps-universal.md categories 2 (reward hacking) and 4 (verifier integrity).`

`known-traps-appendix.md` remains as a back-compat pointer to the two new files.

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
- Auto-extract REQ-* anchors from source_spec markdown headings (`<!-- REQ-XYZ -->`) instead of relying on spec-writer to enumerate
- Cost-model dashboard from `model_requests[]` aggregation

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for orchestrator decision-loop tightening history.
