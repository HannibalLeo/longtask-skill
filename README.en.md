# /longtask — Claude × Codex hybrid spec-execution skill (v2)

[简体中文](README.md) · **English**

> Multi-phase spec execution pipeline. Claude opus runs as orchestrator and dispatches Claude Agents (architecture / discussion / judgment gates / final verification) plus `codex exec` GPT-5.5 children (code writing, schema-driven verifier JSON), following an Owner four-step division of labor.
>
> Full contract and field definitions live in [SKILL.md](SKILL.md). This is the quick-start.

## One line

Write a spec → `/longtask <spec_path>` → the main session runs all 9 steps (preflight / classify / roundtable / **codex-spec-sanity** / plan-write / plan-integrity / per-phase / final-e2e2 / final-alignment); on all PASS optionally `/ship`.

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
Step 0  Preflight         Validate frontmatter (source_spec_path / sha256 / final_verify_cmd
                          / final_e2e2_cmd / final_report_path are required)
Step 1  Classifier        Claude Agent → JSON {input_shape, discussion_rounds,
                          required_lenses, risk_reasons}
Step 2  Roundtable        (conditional) N rounds × 5 lenses hybrid discussion +
                          round-state editor + consensus editor. Skipped when
                          input_shape ∈ {plan_with_source, self_contained_plan}
Step 3  Codex spec sanity (**UNCONDITIONAL**) codex exec --output-schema single pass:
                          omissions / hallucinations / internal contradictions /
                          reward-hacking bait → JSON {verdict: CLEAN | NEEDS_REVISION}.
                          Especially load-bearing when Step 2 was skipped — this is the
                          only cross-model second opinion before plan-writer
Step 4  Plan-writer       Claude Agent invokes superpowers:writing-plans → plan.md
                          (**multi-agent dispatch** when plan has ≥3 phases)
Step 5  Plan-integrity    HYBRID gate (Claude primary + Codex secondary) →
                          PASS or BLOCKED_SPEC_REWRITE. Includes textual fidelity check:
                          every REQ-* code block / signature / docstring in source spec
                          must appear literally in plan goals + dod
Step 6  Per-phase loop    For each Pn: sub-agent → codex-worker → scope gate →
                          codex-verifier (schema JSON) → main-line JSON review →
                          commit (docs_sync runs pre-commit if enabled)
Step 7  Final E2E2        Claude Agent runs final_verify_cmd + final_e2e2_cmd →
                          captures screenshots → writes final-report.md.
                          Subagent MUST proactively flag residual risks to Step 8
                          (stub screenshots, dod gaps, etc.)
Step 8  Final-alignment   MANDATORY DUAL hybrid (Claude + Codex both required) →
                          PASS or escalate
Step 9  Ship (optional)   docs_sync → update-docs; ship → gstack /ship
```

## Key design decisions

| # | Decision | Implementation |
|---|---|---|
| 1 | Keep PTY workaround | `lib/codex-wrapper.sh` still wraps with `script -q /dev/null` to bypass codex#19945; `CODEX_LONGTASK_DISABLE_PTY=1` can disable it for testing |
| 2 | Hybrid roundtable by default | spec may set `roundtable_mode: hybrid \| claude_only \| codex_only \| dual`; **final-alignment-review is always dual** regardless (last line of defense, cheap, runs once) |
| 3 | Two-layer known-traps | (a) `prompts/known-traps-appendix.md` is the generic appendix (worker gets full text; verifier/decision-gate get checklist reference); (b) per-repo details flow through spec `inject_context.always` |
| 4 | 10 BLOCKED enum codes | 6 inherited from Codex side + 4 Claude-specific. Full list in SKILL.md `## BLOCKED enum` |
| 5 | Variable-length roundtable | classifier emits `discussion_rounds` derived from `input_shape` + risk (0 / 1-2 / 5); `discussion_required: true` in spec forces 5 rounds (cannot force 0) |
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
