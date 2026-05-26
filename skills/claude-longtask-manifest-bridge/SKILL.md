---
name: longtask-manifest-bridge
description: Convert a flat `plan-only-handoff.json` produced by /longtask:longtaskPlan into a schema-conformant `handoff-manifest.json` that satisfies `shared/schemas/handoff-manifest.schema.json`. Performs honest codex_handoff_compatibility scan over every phase (11 violation codes including SSH/network egress) and emits a workflow_routing decision (fast_allowed | safe_recommended | safe_required | blocked_until_replan). Use before /longtask:codex-longtask-code or any tool that requires the formal handoff manifest. Triggers on /longtask:manifest-bridge, "convert plan-only handoff", "handoff manifest bridge", "bridge handoff", "plan handoff to manifest".
---

# /longtask:manifest-bridge — handoff schema adapter (v0.4)

## Why this skill exists

The 0.3.0 dual-harness restructure introduced two handoff contracts that never
converged:

| Producer | Output file | Schema shape | Consumer |
|---|---|---|---|
| `claude-longtask-plan` | `.longtask/state/{spec}/plan-only-handoff.json` | flat (`from_skill`, `plan_path`, `plan_post_*_sha256`, `state_path`, ...) | `claude-longtask-code` reads this directly |
| (none) | `.longtask/state/{spec}/handoff-manifest.json` | nested + workflow_routing + codex_handoff_compatible + repo_path_safety + artifacts + next_commands | `codex-longtask-code` requires this (Step 6 startup gate) |

There was no skill that consumed the flat form and produced the nested
schema-conformant form. The bridge fills that gap.

It also performs the **honest codex compatibility scan** that
`codex-longtask-code` startup expects to find pre-computed in the manifest:
walking every phase to detect SSH / network egress / Skill dispatch / browser
work / and 7 other violations that would cause a codex worker to fail inside
its sandbox. If any violation fires, the manifest routes the user away from
codex-longtask-code toward `claude-longtask-code` (Claude main-line, which can
issue SSH and dispatch sub-skills).

## When to use

Use this skill when ALL of:

- `/longtask:longtaskPlan` has completed and produced
  `.longtask/state/{spec_basename}/plan-only-handoff.json`.
- You want to know whether the plan is codex-end-executable, and produce a
  schema-conformant manifest so `codex-longtask-code` (or
  `claude-longtask-code`) startup gates pass.

Skip when:

- You are running `/longtask:longtask` end-to-end (it dispatches code
  execution internally; no manifest hand-off needed).
- You have already produced a schema-conformant manifest by another path.

## What this skill does NOT do

- Does **not** modify the plan, source spec, alignment matrix, or any source
  artifact. The bridge only writes the manifest at the configured output path.
- Does **not** repair plans that fail compatibility — it reports honestly so
  the user can either re-run the plan stage (`/longtask:longtaskPlan --resume`)
  or route to a more capable executor (`claude-longtask-code`).
- Does **not** override existing manifests. If
  `.longtask/state/{spec_basename}/handoff-manifest.json` already exists, the
  bridge stops and asks the user to confirm overwrite (or run with an explicit
  `--output` path).

## Invocation

```bash
/longtask:manifest-bridge .longtask/state/{spec_basename}/plan-only-handoff.json
```

Or pass the spec basename directly:

```bash
/longtask:manifest-bridge {spec_basename}
```

(The skill resolves `.longtask/state/{spec_basename}/plan-only-handoff.json`
itself.)

Optional flags:

- `--output <path>` — write manifest to a non-default path (default is
  `.longtask/state/{spec_basename}/handoff-manifest.json`).
- `--force` — overwrite an existing manifest at the output path.

## Pipeline

```
Step 0  Preflight       Verify plan-only-handoff.json exists, parses, and is
                        produced by claude-longtask-plan. Verify plan file
                        at handoff.plan_path exists and its sha256 matches
                        handoff.plan_post_*_sha256. Capture current git HEAD.

Step 1  Compatibility   Dispatch Claude Agent (opus) with
                        prompts/handoff-manifest-writer.md. The agent reads
                        plan body, plan-integrity-review, alignment matrix,
                        and scans every phase for the 11 violation codes
                        (incl. VIOLATION_SSH_OR_NETWORK_EGRESS_IN_PHASE
                        introduced in v0.4 for codex sandbox compatibility).

Step 2  Routing         Agent computes routing_decision from violation severity:
                        - no violations → fast_allowed + codex-longtask-code
                        - salvageable violations → safe_required + claude-longtask-code
                        - structural plan defects → blocked_until_replan + claude-longtask-plan

Step 3  Write manifest  Agent writes schema-conformant manifest to
                        {output_path}; orchestrator validates against
                        shared/schemas/handoff-manifest.schema.json.

Step 4  Return          Skill returns {manifest_path, recommended_executor,
                        routing_decision, codex_handoff_compatible,
                        violation_codes_seen, user_facing_summary}.
```

## Validation gates

After the writer agent returns, the orchestrator runs three gates BEFORE
declaring success:

1. **Schema gate** — `jsonschema.validate(manifest, handoff-manifest.schema.json)`.
   Schema-invalid manifest → re-dispatch agent once with the validation error
   embedded; then BLOCKED_AGENT_TOOL_FAILURE if still invalid.
2. **Self-consistency gate** — confirm `recommended_executor` matches the
   `routing_decision` per the schema's `allOf` conditional rules. E.g.,
   `routing_decision: "fast_allowed"` requires
   `recommended_executor: "codex-longtask-code"` AND
   `codex_handoff_compatible: true`. Mismatch → BLOCKED.
3. **Violation-routing gate** — if `violation_codes[]` is non-empty,
   `codex_handoff_compatible` MUST be `false`. Inverse holds: if
   `codex_handoff_compatible` is `false`, at least one violation MUST be cited
   (otherwise the bridge is producing an unjustified BLOCKED routing). Either
   inconsistency → BLOCKED.

## Output

Manifest path: `.longtask/state/{spec_basename}/handoff-manifest.json`
(default).

User-facing summary (printed after success):

```
✅ Manifest written: <path>
   Routing:          <routing_decision>
   Executor:         <recommended_executor>
   Codex-compatible: <true | false>
   Violations:       <count> [<codes>]
   Next:             <next_step_hint>
```

## State trace

The skill persists a one-line trace into the spec state file:

```json
{
  "manifest_bridge_runs": [
    {
      "manifest_path": ".longtask/state/{spec}/handoff-manifest.json",
      "manifest_sha256": "...",
      "routing_decision": "safe_required",
      "recommended_executor": "claude-longtask-code",
      "codex_handoff_compatible": false,
      "violation_codes_seen": ["VIOLATION_SSH_OR_NETWORK_EGRESS_IN_PHASE"],
      "produced_at": "2026-05-26T15:30:48Z"
    }
  ]
}
```

Multiple runs (e.g., after the user edits the plan and re-runs the bridge)
are appended, not overwritten.

## BLOCKED enum (subset)

| Code | Trigger |
|---|---|
| `BLOCKED_SPEC` | plan-only-handoff.json missing / unreadable / not produced by claude-longtask-plan. |
| `BLOCKED_SPEC_REWRITE` | plan has structural defects (`VIOLATION_MISSING_VERIFY_CMD` / `VIOLATION_SUBJECTIVE_LLM_ONLY_DOD`) → plan must be rewritten before any executor will accept it. |
| `BLOCKED_PLAN_REPAIR` | Synonym surfaced by the writer agent for the same condition. |
| `BLOCKED_AGENT_TOOL_FAILURE` | Writer agent produced schema-invalid manifest twice. |
| `BLOCKED_HARNESS_BACKGROUND` | Background task failure / idle timeout. |

## Relationship to other longtask skills

```
/longtask:longtaskPlan
  → .longtask/state/{spec}/plan-only-handoff.json    (flat, claude-end native)

/longtask:manifest-bridge {plan-only-handoff.json}
  → .longtask/state/{spec}/handoff-manifest.json     (schema-conformant)

/longtask:codex-longtask-code <handoff-manifest.json>   (if codex_handoff_compatible)
/longtask:claude-longtask-code <handoff-manifest.json>  (always works)
/longtask:claude-longtask-code <plan-only-handoff.json> (flat-shape direct)
```

The bridge is OPTIONAL when running through claude-longtask-code (it accepts
flat handoffs). The bridge is REQUIRED when running through codex-longtask-code
(it accepts only schema-conformant manifests).

## Future integration

A future v0.5 may integrate this writer into the `claude-longtask-plan`
pipeline as Step 5b, so plan always emits BOTH the flat handoff (for claude-end
direct use) and the schema-conformant manifest (for codex-end / external
consumers). Until then, the bridge is invoked explicitly.

## Quality bar

Same as `/longtask:longtask` — see `skills/claude-longtask/SKILL.md` "Quality
bar" and the 4 production-grade principles in the plugin root README.md.
Honest compatibility evaluation is non-negotiable: a false
`codex_handoff_compatible: true` will burn hours inside codex-longtask-code
before failing.
