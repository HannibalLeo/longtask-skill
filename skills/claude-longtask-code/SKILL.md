---
name: longtaskCode
description: Plan-to-shipped-code execution pipeline — runs Steps 6 through 9 of /longtask:longtask (per-phase loop with Claude worker (sonnet/opus per model_tier) via Agent tool + Codex GPT-5.5 verifier via codex exec --output-schema → final E2E2 + screenshots → final-alignment-review → optional ship). Input is a validated implementation plan (typically the output of /longtask:longtaskPlan, or a hand-written plan that satisfies the v2 frontmatter contract). Use when planning is already settled and you want execution-only. Triggers on /longtask:longtaskCode, "execute plan", "run plan", "build phases", "code from plan".
---

# /longtask:longtaskCode — Steps 6-9 of /longtask:longtask

This skill is a **strict subset** of [/longtask:longtask](../longtask/SKILL.md). It runs
the execution half of the pipeline, starting from an already-validated plan.
All prompts, schemas, and the codex wrapper live in the plugin root
(`../..` from this SKILL.md, i.e. `~/.claude/plugins/cache/longtask-skill/longtask/<version>/`);
this skill re-uses them by plugin-relative path — there is no duplicated artifact.

The planning-half companion is [/longtask:longtaskPlan](../longtask:longtaskPlan/SKILL.md).
`longtaskPlan` + `longtaskCode` together equal `longtask`; you can also run
`longtaskCode` independently against a hand-written plan that already satisfies
the v2 frontmatter contract (`source_spec_path`, `source_spec_sha256`,
`final_verify_cmd`, `final_e2e2_cmd`, `final_report_path`,
`default_model_tier`, `default_reasoning_effort`, plus per-phase schema —
optional per-phase `model_tier` (claude flow) and `reasoning_effort`
(codex flow) override the defaults).

## When to use

Use when ANY of:

- You have a plan file from `/longtask:longtaskPlan` and want to execute it (possibly
  in a different session, on a different machine, or after a human review of
  the plan).
- You have a hand-authored plan that already passed plan-integrity-review
  externally and just needs the per-phase loop + final verification.
- You want to re-execute phases after fixing a `BLOCKED_*` without re-running
  the planning half — `/longtask:longtaskCode --resume` picks up at the first non-PASS
  phase using the existing state file.
- The user explicitly asks to "execute plan", "run plan", "build phases".

Skip in favor of full `/longtask` when:

- The plan does not yet exist or has not been validated through Step 5.
- You want one command to plan + ship.

## Owner four-step (subset)

| Step | Owner | Scope (subset of /longtask) |
|---|---|---|
| (a) Architecture | — | Not in scope; plan must already be settled. (Orchestrator does still hold final judgment authority on PASS/FAIL of every per-phase verifier JSON.) |
| (b) Discussion | Claude + Codex hybrid | Decision Gate (when a worker proposes `decision_options[]`) and Uncertainty Clarification Round are in scope. Roundtables (spec / plan) are NOT in scope — those ran in `/longtask:longtaskPlan`. |
| **(c) Work** | **Claude worker** (model from `model_tier`: sonnet default, haiku / opus available) via Agent tool **+ Codex GPT-5.5 verifier** via `codex exec --output-schema` | Phase worker writes code in a fresh Claude Agent; phase verifier is a separate Codex GPT-5.5 process that re-reads the working tree, runs `verify_cmd`, and emits schema-driven JSON. Cross-model split is load-bearing — see [/longtask:longtask SKILL.md](../longtask/SKILL.md) §"Phase verifier flow". The heart of this skill. |
| **(d) Final verification** | Claude opus | Reads every verifier JSON to decide PASS/retry; runs decision-review / final-alignment hybrid gates; runs final E2E2 (browser/screenshots); syncs docs; ships. |

## Pipeline (mirrors /longtask Steps 6-9)

```
Step 6  Per-phase loop     For each Pn in plan.md (in order):
                             - Claude sub-agent resolves model_tier
                               (phase.model_tier > spec.default_model_tier > 'sonnet')
                             - Claude sub-agent dispatches claude-worker via Agent tool
                               (model from resolved tier; writes code + worker-output.json)
                             - Hard scope gate (git diff --name-only vs file_scope)
                             - Codex verifier (codex exec --output-schema
                               verifier-result.schema.json)
                             - Main-line JSON review (verdict + reward_hacking_signals +
                               dod_results + root_cause_hint)
                             - On PASS: commit (docs_sync runs pre-commit if enabled)
                             - On FAIL: reset worktree, retry up to max_retry_rounds with
                               claude-worker-retry, then BLOCKED_*
                             - On decision_options[]: Decision Gate (HYBRID)

Step 7  Final E2E2          Claude Agent runs final_verify_cmd + final_e2e2_cmd →
                            captures screenshots → writes final-report.md.
                            Subagent MUST proactively flag residual risks to Step 8
                            (stub screenshots, dod gaps, etc.)

Step 8  Final-alignment     MANDATORY DUAL hybrid (Claude + Codex both required) →
                            PASS or escalate. Last-line-of-defense; runs once at
                            end-of-pipeline independent of cross-rounds outcomes.

Step 9  Ship (optional)     docs_sync → update-docs; ship → gstack /ship.
                            Failure inside /ship does NOT roll back phase commits —
                            orchestrator surfaces the error and waits.
```

## Prompts (all in `../../prompts/` relative to this SKILL.md = plugin root's `prompts/`)

| Step | Prompt file | Dispatch |
|---|---|---|
| Orchestration | `claude-orchestrator.md` | Main session reads as its checklist; runs Steps 6-9 only |
| Step 6 sub-agent | `claude-sub-agent.md` | Claude Agent, opus (per phase, fresh per phase) |
| Step 6 worker | `claude-worker.md` | `Agent` tool (one fresh Agent per round; model from resolved `model_tier`) |
| Step 6 verifier | `codex-verifier.md` | `codex exec --output-schema verifier-result.schema.json` |
| Step 6 retry | `claude-worker-retry.md` | `Agent` tool (same model_tier; carries prior verifier JSON) |
| Step 6 decision gate | `decision-review.md` | Hybrid (Claude primary + Codex secondary) |
| Step 6 cross-cutting | `codex-clarification.md` | One-shot tie-breaker before any uncertainty-driven ASK_HUMAN |
| Step 6 cross-cutting | `known-traps-universal.md` + `known-traps-claude-only.md` | Claude worker `Read`s `.longtask/known-traps-active-{spec_basename}.md` (universal + claude-only, concatenated once per phase by `claude-sub-agent.md`); codex worker / verifier / decision gate get checklist reference to universal only. `known-traps-appendix.md` is a back-compat pointer. |
| Step 7 | `final-e2e2-report.md` | Claude Agent (gstack browse / screenshots; proactive residual-risk flagging) |
| Step 8 | `final-alignment-review.md` | Hybrid: MANDATORY DUAL (Claude + Codex always both run) |

Schemas reused from `../../schemas/` (plugin root's `schemas/`):
- `verifier-result.schema.json` (Step 6 verifier output)
- `decision-review.schema.json` (Step 6 decision gate)
- `codex-clarification.schema.json` (cross-cutting)

Wrapper: `../../lib/codex-wrapper.sh`.

## Input contract

`/longtask:longtaskCode` accepts the input in one of two forms:

### Form 1: Handoff manifest from `/longtask:longtaskPlan`

```bash
/longtask:longtaskCode .longtask/state/{spec_basename}/plan-only-handoff.json
```

The manifest contains `plan_path`, `plan_post_cross_rounds_sha256`,
`state_path`, and the alignment-matrix path. Orchestrator:
1. Reads the manifest.
2. Asserts the plan file SHA-256 matches `plan_post_cross_rounds_sha256`.
   Drift → `BLOCKED_SPEC`.
3. Loads the existing state file (`mode` transitions from
   `claude-cross-rounds-plan-only` → `claude-cross-rounds`).
4. Starts at Step 6 for `P1`.

### Form 2: Plan path directly (with or without prior `/longtask:longtaskPlan` state)

```bash
/longtask:longtaskCode docs/superpowers/specs/2026-05-26-foo-plan.md
```

Orchestrator:
1. Reads the plan file. Validates v2 frontmatter (Step 4's check applies here):
   `source_spec_path`, `source_spec_sha256`, `final_verify_cmd`,
   `final_e2e2_cmd`, `final_report_path`, `default_model_tier`,
   `default_reasoning_effort` MUST be present. Missing → `BLOCKED_SPEC`.
   Unrecognised `default_model_tier` / per-phase `model_tier` value (not in
   `haiku | sonnet | opus`) → `BLOCKED_SPEC`. Unrecognised
   `default_reasoning_effort` / per-phase `reasoning_effort` value (not in
   `medium | high | xhigh`) → `BLOCKED_SPEC`.
2. Loads the source spec at `source_spec_path` and asserts its current SHA-256
   equals `source_spec_sha256`. Drift → `BLOCKED_SPEC`.
3. Validates per-phase fields (`goals`, `file_scope`, `do_not_touch`,
   `verify_cmd`, `verify_passes_when`, `dod`, `source_requirements`).
   Missing → `BLOCKED_SPEC`.
4. If a state file exists at `.longtask/state/{spec_basename}.json`, loads it;
   if not, initializes a fresh state file with
   `mode: "claude-cross-rounds-code-only"` and the plan-derived identity fields.
5. Starts at Step 6 for the first phase whose status is not `PASS`.

### Resume

```bash
/longtask:longtaskCode <plan_or_manifest> --resume
```

Same as `/longtask:longtask --resume` but bounded to Steps 6-9. Re-runs from the first
phase whose status is not `PASS`. Re-runs Steps 7-8 if any phase commit sha is
newer than the last final-alignment timestamp.

## State file (subset of /longtask state, with handoff transition)

When started from a `/longtask:longtaskPlan` handoff:
- `mode` flips `claude-cross-rounds-plan-only` → `claude-cross-rounds`.
- Spec-stage / plan-stage fields are read-only — `/longtask:longtaskCode` must not
  modify them; if it does, the next `/longtask:longtaskCode --resume` would fail
  sha-drift check.

When started from a plan file directly (no prior `/longtask:longtaskPlan`):
- `mode` is `claude-cross-rounds-code-only`.
- Spec-stage fields (`classification_path`, `enhanced_spec_path`,
  `spec_cross_round_state_paths`, etc.) are absent. `plan_integrity_review_path`
  may also be absent — this signals "no formal Step 5 gate ran in this
  session"; the orchestrator MUST run plan-integrity-review (Step 5 from
  `/longtask`) inline at Step 6 startup as a precondition before dispatching
  any phase worker. This is the only Step 5 invocation `/longtask:longtaskCode` may
  perform. Failure → `BLOCKED_SPEC_REWRITE` and the user is told to run
  `/longtask:longtaskPlan` first.

Fields `/longtask:longtaskCode` writes:

| Field group | Keys |
|---|---|
| Per-phase | `phases.{Pn}.{status, rounds_used, verifier_json_paths[], commit_sha, last_heartbeat, heartbeats[]}` |
| Final | `final_report_path`, `final_alignment_review_path` |
| Model accounting | `model_requests[]`, `agents[]`, `claude_subagents[]`, `codex_subagents[]`, `hybrid_gate_assignments` (decision-review / final-alignment-review keys only) |
| Ship | `ship_attempted`, `ship_pr_url` (when spec.ship == true) |

## BLOCKED enum (subset)

These can fire in Steps 6-9:

- `BLOCKED_SCOPE` — Step 6 worker wrote outside `file_scope` or touched `do_not_touch`
- `BLOCKED_SPEC` — Step 6 startup: plan/spec frontmatter or sha drift
- `BLOCKED_SPEC_REWRITE` — Step 6 startup: no prior plan-integrity gate AND inline plan-integrity-review FAILed
- `BLOCKED_MODEL_UNAVAILABLE` — `gpt-5.5` unavailable and no fallback acceptable per spec
- `BLOCKED_E2E2_SCREENSHOT` — Step 7 final-e2e2 produced no screenshots when `final_e2e2_cmd` was supposed to
- `VERIFIER_SCHEMA_INVALID` — Step 6 verifier output failed schema validation
- `BLOCKED_AGENT_TOOL_FAILURE` — Claude Agent dispatch failure (sub-agent / decision primary / final-e2e2 / final-alignment primary)
- `BLOCKED_CODEX_WRAPPER_FAILURE` — `codex exec` non-zero exit (worker / verifier / decision secondary / final-alignment secondary)
- `BLOCKED_HARNESS_BACKGROUND` — sub-agent idle timeout (`idle_timeout_minutes` exceeded with no heartbeat progress)
- `BLOCKED_CONTEXT_BUDGET` — orchestrator approaching 1M context

Planning BLOCKEDs (Step 1/2/4/4b/5 internal) cannot fire here.

## Invocation

```bash
# From a /longtask:longtaskPlan handoff:
/longtask:longtaskCode .longtask/state/foo-design/plan-only-handoff.json

# From a plan path directly:
/longtask:longtaskCode docs/superpowers/specs/2026-05-26-foo-plan.md

# Resume after interruption:
/longtask:longtaskCode .longtask/state/foo-design/plan-only-handoff.json --resume
```

## Relationship to /longtask:longtask and /longtask:longtaskPlan

- `/longtask:longtask <spec>` = `/longtask:longtaskPlan <spec>` + `/longtask:longtaskCode <plan>` in one
  session, no user handoff between them.
- `/longtask:longtaskPlan` + manual review + `/longtask:longtaskCode` = same end-state with an
  explicit human (or AI) checkpoint at the plan stage.
- `/longtask:longtaskCode` solo = trust the plan as-is, skip planning checks (Step 5
  still runs inline if no prior gate was recorded — see "State file" above).

## Quality bar

Same as `/longtask:longtask` — no hidden defects, no minimal patches that
paper over symptoms, taste is part of "shippable". See the plugin root's
[README.md](../../README.md) for the 4 production-grade principles.
