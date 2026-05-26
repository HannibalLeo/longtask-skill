# /longtask — Claude × Codex hybrid spec-execution skill (v2)

[简体中文](README.md) · **English**

> Multi-phase spec execution pipeline. Claude opus runs as orchestrator and dispatches Claude Agents (architecture / discussion / judgment gates / final verification) plus `codex exec` GPT-5.5 children (code writing, schema-driven verifier JSON), following an Owner four-step division of labor.
>
> Full contract and field definitions live in [SKILL.md](SKILL.md). Version history in [CHANGELOG.md](CHANGELOG.md). This is the quick-start.

## 4 production-grade principles (this skill's working bar)

Inspired by [Karpathy's engineering style](https://github.com/forrestchang/andrej-karpathy-skills); phrasing is ours:

1. **Simplicity beats cleverness** — prefer boring straightforward code that a reader can grep once and understand. Delete a layer of indirection if it can go without losing function; three similar lines beat a premature abstraction.
2. **Evals before optimization** — what cannot be measured cannot be improved. Every phase's `verify_cmd` makes PASS/FAIL mechanical, not narrative; "looks right to me" is not allowed.
3. **Tight iteration over big leaps** — three small verifiable changes beat one large change that's right "in principle". The retry loop exists for this. A phase that needs a 500-line diff to verify is too coarse — split it.
4. **Taste is part of "shippable"** — a green test does not mean production-ready. Read the diff at the end of each phase. Ugly code that passes is the next phase's pothole; naming, structure, and discipline are part of the bar.

**Quality bar — non-negotiable.** No hidden defects, no minimal patches that paper over symptoms. Every decision serves "ships to real users", not "the test happens to be green".

## One line

Write a spec → `/longtask <spec_path>` → the main session runs all 9+1 steps (preflight / classify / **spec-roundtable** / codex-spec-sanity / plan-write / **plan-roundtable** / plan-integrity / per-phase / final-e2e2 / final-alignment); on all PASS optionally `/ship`.

## Owner four-step division

| Step | Owner |
|---|---|
| (a) Architecture | Claude opus — input classification, plan writing, plan-integrity review |
| (b) Discussion | Claude + Codex mixed — roundtable lenses routed per role; consensus editor: Claude primary + Codex secondary |
| (c) Work | Codex GPT-5.5 via `codex exec` — phase worker writes code; verifier produces schema JSON |
| (d) Final verification | Claude opus — reads verifier JSON to decide PASS/retry, runs decision / plan-integrity / final-alignment hybrid gates, runs final E2E2 + screenshots, docs sync, ship |

Load-bearing invariant: **Codex writes JSON, Claude reads JSON.** The main session does not read source files (preserves context) yet holds final judgment (preserves safety).

## Minimal spec example

```markdown
---
source_spec_path: docs/specs/2026-05-26-healthz-design.md
source_spec_sha256: "<sha256>"
final_verify_cmd: "pytest -q tests/"
final_e2e2_cmd: "gstack browse-e2e --scenarios=docs/CRITICAL_PATH.md --screenshots=.longtask/screenshots/healthz/"
final_report_path: .longtask/reports/healthz/final-report.md
roundtable_mode: hybrid     # default; safety-critical specs may set `dual`
gating: [office-hours, plan-ceo-review, plan-eng-review]   # optional
ship: true                                                 # optional
docs_sync: true                                            # optional
---

# P1: Add /healthz endpoint
goals: Expose `GET /healthz` returning `{"status":"ok"}` with 200 and no auth.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, src/db/**]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and 0 failures"
max_retry_rounds: 3
source_requirements: [REQ-001]
dod:
  - "GET /healthz returns 200 with {status:ok}"
  - "Existing /auth endpoints unchanged"
  - "OpenAPI spec includes the new path"
```

## 9-step pipeline

```
Step 0  Preflight          Validate frontmatter (source_spec_path / sha256 / final_verify_cmd
                           / final_e2e2_cmd / final_report_path are required)
Step 1  Classifier         Claude Agent → JSON {input_shape, spec_rounds, plan_rounds,
                           required_lenses, risk_reasons, suggested_roundtable_mode}
                           Picks one tier from {0+1, 1+1, 2+1, 3+2}
Step 2  Spec-roundtable    spec_rounds × 5 lenses hybrid discussion + spec-round-state
                           editor + spec-consensus-editor → enhanced-spec. **Skipped only
                           at the 0+1 tier** (pre-vetted: input_shape ∈ {plan_with_source,
                           self_contained_plan}, OR source_spec.gating already ran
                           office-hours / plan-ceo-review / plan-eng-review in the same
                           session)
Step 3  Codex spec sanity  (**UNCONDITIONAL**) codex exec --output-schema single pass:
                           omissions / hallucinations / internal contradictions /
                           reward-hacking bait → JSON {verdict: CLEAN | NEEDS_REVISION}.
                           Especially load-bearing when Step 2 was skipped — this is the
                           only cross-model second opinion before plan-writer
Step 4  Plan-writer        Claude Agent invokes superpowers:writing-plans → plan.md
                           (**multi-agent dispatch** when plan has ≥3 phases)
Step 4b Plan-roundtable    plan_rounds × 5 lenses hybrid discussion on the implementation
                           plan + plan-round-state editor + plan-consensus-editor
                           (in-place rewrites plan.md). **ALWAYS RUN** (plan_rounds ≥ 1)
                           — the plan is the concrete execution contract, must face one
                           multi-lens pass before plan-integrity. Question focus: phase
                           decomposition, verifier observability, cross-phase deps, risk
                           surface
Step 5  Plan-integrity     HYBRID gate (Claude primary + Codex secondary) →
                           PASS or BLOCKED_SPEC_REWRITE. Includes textual fidelity check:
                           every REQ-* code block / signature / docstring in source spec
                           must appear literally in plan goals + dod
Step 6  Per-phase loop     For each Pn: sub-agent → codex-worker → scope gate →
                           codex-verifier (schema JSON) → main-line JSON review →
                           commit (docs_sync runs pre-commit if enabled)
Step 7  Final E2E2         Claude Agent runs final_verify_cmd + final_e2e2_cmd →
                           captures screenshots → writes final-report.md.
                           Subagent MUST proactively flag residual risks to Step 8
                           (stub screenshots, dod gaps, etc.)
Step 8  Final-alignment    MANDATORY DUAL hybrid (Claude + Codex both required) →
                           PASS or escalate
Step 9  Ship (optional)    docs_sync → update-docs; ship → gstack /ship
```

## Key design decisions

| # | Decision | Implementation |
|---|---|---|
| 1 | Keep PTY workaround | `lib/codex-wrapper.sh` still wraps with `script -q /dev/null` to bypass codex#19945; `CODEX_LONGTASK_DISABLE_PTY=1` can disable it for testing |
| 2 | Hybrid roundtable by default | spec may set `roundtable_mode: hybrid \| dual`; **final-alignment-review is always dual** regardless (last line of defense, cheap, runs once). `claude_only` / `codex_only` removed 2026-05-26 — single-model roundtable defeats the cross-model blindspot defense; if either side dispatch fails → `BLOCKED_*` instead of silent degradation |
| 3 | Two-layer known-traps | (a) `prompts/known-traps-appendix.md` is the generic appendix (worker gets full text; verifier/decision-gate get checklist reference); (b) per-repo details flow through spec `inject_context.always` |
| 4 | 10 BLOCKED enum codes | 6 inherited from Codex side + 4 Claude-specific. Full list in SKILL.md `## BLOCKED enum` |
| 5 | Two-stage roundtable, 4 tiers of total rounds | classifier emits `(spec_rounds, plan_rounds)` picking one tier: **0+1** (pre-vetted) / **1+1** (default low-risk) / **2+1** (medium — cross-module contracts, new deps, phase count ≥4) / **3+2** (high — regulatory / clinical / data-loss / security / irreversible-migration; also forces `dual`). **`plan_rounds ≥ 1` is non-negotiable** — the plan is the final execution contract. Both stages require Codex + Claude lenses simultaneously; either-side dispatch failure → `BLOCKED_*` |
| 6 | Confidence + veto reconciliation | Verdicts agree → use; any `vetoes[]` → ASK_HUMAN; confidence delta > 0.15 + local/reversible/inside-spec → higher confidence wins; otherwise ASK_HUMAN. No third-arbiter LLM by default |
| 7 | Default gpt-5.5 / xhigh | `CODEX_LONGTASK_MODEL=gpt-5.5` / `CODEX_LONGTASK_REASONING=xhigh`; fallback to 5.4/high must log `state.model_requests[].model_degraded` |
| 8 | Repo provenance TBD | Claude-end and Codex-end both track `HannibalLeo/longtask-skill.git`; push policy is owner's decision |

## Relationship with the Codex-end skill

Both ends share `HannibalLeo/longtask-skill.git`. Codex-end (`~/.codex/skills/longtask/`) v0.0.5 dispatches via native Codex subagents; Claude-end uses Claude `Agent` tool + `codex exec`. Schemas (`schemas/*.schema.json`) are byte-identical across ends; prompts diverge on hybrid wiring.

Design spec: `docs/superpowers/specs/2026-05-26-longtask-claude-parity-design.md` (project-local).

## File layout

```
~/.claude/skills/longtask/
├── SKILL.md                              # full contract
├── README.md / README.en.md              # Chinese / English quick-start
├── lib/codex-wrapper.sh                  # codex exec wrapper (--json --output-schema --cd)
├── lib/smoke.sh                          # static sanity check
├── schemas/{verifier-result,decision-review,plan-integrity-review}.schema.json
└── prompts/                              # 16 prompts (see SKILL.md `## Prompts and wrapper`)
```

## Sanity self-check

```bash
bash ~/.claude/skills/longtask/lib/smoke.sh
# expect: 3 schemas OK + bash -n passes + usage gate passes + total FAIL=0
```

## Invocation

```bash
# From a project directory
/longtask docs/superpowers/specs/2026-05-26-foo-design.md

# Resume after interruption
/longtask docs/superpowers/specs/2026-05-26-foo-design.md --resume
# Orchestrator reads .longtask/state/foo-design.json and restarts from the
# first non-PASS phase. If source_spec_sha256 no longer matches the file →
# BLOCKED_SPEC
```

## Feedback loop

After a run, inspect:
1. `.longtask/state/<spec>.json` — `model_requests[]` for downgrade rate, `agents[]` for timings
2. `.longtask/reports/<spec>/final-report.md` — final-verification summary + screenshots
3. `.longtask/reports/<spec>/blocked-*.md` (if any) — stderr and repro for each BLOCKED escalation

Spec authoring lessons and known Codex CLI traps live in `prompts/known-traps-appendix.md` and the project-local `docs/archive/CODEX_PROTOCOL.md`.
