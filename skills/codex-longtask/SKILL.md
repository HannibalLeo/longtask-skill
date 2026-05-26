---
name: longtask
version: 0.0.5
description: Use when a user provides a written source spec or implementation plan for a large unattended task requiring durable phased execution, verification, resume, or final browser/E2E evidence.
---

# /longtask

> **v0.4 divergence note (2026-05-26):** The codex-end of this plugin still
> uses the 0.3.x single-model roundtable shape. The claude-end (`claude-longtask`,
> `claude-longtask-plan`) was restructured in 0.4.0 to a cross-pair design
> (codex × all lenses → codex mid-summary → claude × all lenses → claude
> end-summary, with a single `cross_rounds ∈ {1, 2, 3}` axis replacing the
> previous 4-tier scheme and the `hybrid` / `dual` mode knob). The codex-end
> cannot cross-dispatch into Claude Agent so it cannot implement the v0.4
> design as-is. If you have both harnesses available and want the v0.4
> cross-rounds behavior, prefer `claude-longtask` / `claude-longtask-plan`.
> See plugin root `CHANGELOG.md` v0.4.0 for details.

Run a written source spec or already-written implementation plan through Codex
**native subagents** without letting the parent chat become the place where
implementation context accumulates.

The parent Codex session is the **conductor**: it keeps state, spawns fresh
subagents for every task sub-step, enforces git-based scope checks, commits
verified phases, and reports only compact evidence. Input classification, spec
enhancement, implementation-plan writing, plan-integrity review,
implementation, verification, E2E2, screenshots, reports, decisions, and final
alignment review all happen in subagents. This keeps the parent sharp without
making it blind.

`codex exec` is not the default path. It is a fallback for CI or environments
where native subagents are unavailable.

## Invocation and Input

Expected invocation:

```text
[$longtask](/Users/leoleon/.codex/skills/longtask/SKILL.md) path/to/spec.md
```

The input may be either:

- a **source spec**, usually produced by `brainstorming`
- a **hybrid** document with some requirements and partial phases
- a **self-contained implementation plan / execution spec**
- an already-written **implementation plan / execution spec**
  with source-spec lineage

Do not ask the user to provide a separate plan. First classify the input shape.
If it is a source spec, enhance it and rewrite it into a single executable
artifact:

```text
.longtask/plans/<spec_basename>-implementation-plan.md
```

That artifact is both the implementation plan and the execution spec. Do not
create a second competing plan document. If the input file is already in the
longtask execution format, dynamically skip the spec-enhancement and plan-writing
preflight after confirming that it satisfies the execution schema. For a
`plan_with_source`, also prove source requirement coverage. For a
`self_contained_plan`, prove internal phase/DoD/final-gate coverage without
pretending to know an absent source spec. Record the skip decision in
`.longtask/reports/<spec>/preflight-skip.md`, then continue with
plan-integrity review and phase execution.

## When to Use

Use this skill when all are true:

- A written source spec or implementation plan exists.
- The task is too large for one tightly-coupled edit.
- The user wants no confirmation prompts between phases.
- Completion must mean scoped, verified, committed work plus final E2E2
  evidence and screenshots.

Skip for quick questions, small single-file edits, reviews, or brainstorming.

## Core Invariants

- **Classify before rewriting.** The input may already be an executable plan.
  Classify it first as `source_spec`, `hybrid`, `self_contained_plan`, or
  `plan_with_source`, and skip only the preflight steps that are provably
  redundant.
- **Source spec intent is preserved.** When the input is a source spec, the
  enhanced spec and implementation plan must preserve every requirement. If they
  diverge, stop and repair the plan; do not silently implement the divergence.
- **Enhancement preserves intent.** The enhanced spec may add clarity,
  constraints, evidence, domain framing, and acceptance criteria, but it must not
  drop, weaken, or reverse any source-spec requirement. If a tradeoff is needed,
  record it in the update document instead of hiding it.
- **One executable plan.** The implementation plan and execution spec are the
  same document.
- **All task sub-steps are subagents.** The parent conducts only: read compact
  contracts/evidence, spawn subagents, run git scope/status gates, validate
  schemas/artifacts, write state, stage/commit verified files, and report. The
  parent does not directly classify or enhance specs, write implementation
  plans, write implementation code, run product verification, produce
  screenshots, or author final reports.
- **Parent stays low-context.** It may read the source/input spec, implementation
  plan / execution spec, enhanced spec, spec update document, preflight skip
  document, plan-integrity verdict, state JSON, changed file list, diff stat,
  verifier report, blocked report, final alignment report, and final commit
  list. It does not read full implementation files during normal execution.
- **Subagent dispatch is `codex exec` via `lib/codex-wrapper.sh`, NEVER inline.**
  Every worker / verifier / retry-worker / lens / mid-summary / consensus /
  judgment turn is a separate `codex exec` child process with its own
  context, its own model, and its own `model_reasoning_effort` (resolved
  per phase from `default_reasoning_effort` + per-phase `reasoning_effort`
  — see [conductor.md](../../codex/prompts/conductor.md) § "Model Budget").
  If the parent session reads `prompts/worker.md` and starts writing code
  itself instead of running `bash codex/lib/codex-wrapper.sh ... worker`,
  that is the bug: every phase ends up paying the parent's
  reasoning-effort (typically `xhigh`) and the worker→verifier isolation
  collapses. The conductor prompt carries literal bash templates for each
  dispatch step — follow them.
- **Native subagents do the heavy work.** Each worker/verifier starts fresh.
- **Worker and verifier are separated.** The verifier gets no worker reasoning,
  only the execution spec, changed files, diff, and verification output.
- **Git is the source of truth.** Scope is enforced with `git status` and
  `git diff`, not by trusting prompts.
- **No hidden shipping.** Push/PR/deploy are separate explicit workflows after
  all phases pass.
- **Stop on hard risk.** Required subagent unavailable, unsafe model degradation,
  scope violation, malformed verifier output, repeated FAIL, dirty unexpected
  files, or security concern stops the run.

## Model and Reasoning Policy

Native subagents inherit the parent model/reasoning by default. Do not rely on
that default for longtask. The conductor should choose cheaper reasoning first
and escalate only when evidence says the task needs it.

**The Step 6 execution sub-agents (worker / retry-worker / verifier) read
their reasoning effort from the spec's frontmatter contract, not from the
conductor's runtime model state.** Two knobs:

- `default_reasoning_effort` (top-level frontmatter, required): default for
  the spec. Conventional value `medium` — meant for the case where the
  conductor session is running at `xhigh` but the cost-dominant execution
  sub-agents should run cheaper.
- `reasoning_effort` (per phase block, optional): overrides the default for
  that one phase. Use `high` for cross-module / fragile / security-sensitive
  phases; `xhigh` only for the genuinely hard ones.

Resolution at dispatch time:
`phase.reasoning_effort > spec.default_reasoning_effort > hard fallback 'medium'`.

**Retry escalation.** Retry rounds auto-bump one tier (medium → high →
xhigh) regardless of the resolved value, unless the phase pinned
`reasoning_effort` explicitly (a pinned value disables auto-escalation —
the conductor logs `model_degraded: false, reason: "pinned_by_phase"`).

Judgment-heavy roles ignore both knobs and stay at `xhigh` by policy.

Default policy:

| Role | First choice | Escalate when |
|---|---|---|
| input classifier | `gpt-5.5`, `xhigh` reasoning | always before deciding whether to skip preflight |
| spec specialist discussion agents | `gpt-5.5`, `high` reasoning | `xhigh` for high-risk domain, product, data, security, or UI decisions |
| round-state editor | `gpt-5.5`, `high` reasoning | `xhigh` when specialist disagreement affects scope, data, safety, or product contract |
| consensus editor | `gpt-5.5`, `xhigh` reasoning | always after five discussion rounds |
| implementation plan writer | `gpt-5.5`, `xhigh` reasoning | always when source spec must become a plan |
| plan integrity reviewer | `gpt-5.5`, `xhigh` reasoning | always before phase execution |
| **worker** | `gpt-5.5`, reasoning resolved from `phase.reasoning_effort > spec.default_reasoning_effort > 'medium'` | retry round auto-bumps one tier (unless phase pinned); explicit `high` / `xhigh` on phase block for cross-module / fragile / security-sensitive phases |
| **retry worker** | same as worker + auto +1 tier (medium → high → xhigh) | phase-block-pinned `reasoning_effort` disables auto-bump |
| **verifier** | `gpt-5.5`, same resolved effort as the worker for the same phase | verifier JSON inconsistent → escalate one tier on next round (auto) |
| decision reviewer | `gpt-5.5`, `xhigh` reasoning | always for auto-decisions, including simple local decisions |
| final E2E2/report subagent | `gpt-5.5`, `xhigh` reasoning | always for final E2E2 screenshot report |
| final alignment reviewer | `gpt-5.5`, `xhigh` reasoning | always before declaring complete |
| final reviewer | `high` reasoning | use only when separate non-alignment review is useful |

For verification, two independent `medium` verifier passes with different
prompts are often a better use of budget than one `xhigh` pass. Use this pattern
for risky phases:

1. **Spec verifier** checks phase goals, `verify_cmd`, DoD, and reward-hacking.
2. **Quality/security verifier** checks regression risk, unsafe side effects,
   scope drift, and maintainability.

Do not run every phase at `gpt-5.5` + `high/xhigh` by habit. High reasoning is
an escalation tool, not the baseline.

If a preferred model or reasoning override is unavailable, choose the strongest
available model/reasoning that can run the subagent, record
`model_degraded: true` with the requested and actual model in state, and
continue when the task is local, reversible, and mechanically verifiable. Stop
with `BLOCKED_MODEL_UNAVAILABLE` only when the missing model affects a
security-sensitive, data-loss, externally visible, irreversible, or
out-of-spec product decision.

## Decision Gate

Long tasks often block on choices that do not truly need the human: "which
approach should we take?", "should we patch locally or refactor?", "which API
pattern is current?", "is this design compromise acceptable?". Treat these as a
structured decision point before pausing or hard-stopping.

Worker/verifier agents may return a decision report with 2-4 options. The parent
then runs a Decision Gate:

1. **Classify risk.** Auto-decide only if the change is local, reversible, within
   spec, and has a clear verification path.
2. **Gather evidence.** Use repository evidence first. If the choice depends on
   current SDK/API/framework behavior, search official docs, release notes, or
   upstream issues before judging.
3. **Review with lenses.** Use `prompts/decision-review.md` to evaluate:
   complete problem solving, evidence/evals, engineering fit, product fit,
   design fit, and external truth.
4. **Review with `gpt-5.5` + `xhigh` when available.** The user explicitly wants
   simple intermediate decisions made this way. If that model/reasoning override
   is unavailable, use the model degradation policy above.
5. **Proceed without confirmation.** If confidence is at least `0.72` and there
   is no veto, choose the option and pass concrete follow-up instructions to the
   next worker. If confidence is lower but the option is local, reversible, and
   inside spec, choose the most conservative complete option and record the
   assumption. Ask the human only for irreversible behavior, security/data-loss
   risk, externally visible action, or an out-of-spec product change.

The CEO/Eng/Design lenses are not separate mandatory agents for every choice:

- **CEO lens:** Does this solve the user's real problem and preserve product
  value?
- **Engineering lens:** Is it correct, maintainable, scoped, and testable?
- **Design lens:** Does it preserve coherent user workflows and interface
  behavior?

Use the Karpathy-style production bar as the tie-breaker: simplicity, evals,
tight iteration, and taste. Prefer the smallest complete, verifiable solution.
Do not choose the smallest patch that merely gets past the current failure.

## Input Classification

Before any rewrite or phase execution, spawn a fresh **input classifier**
subagent using `gpt-5.5` with `xhigh` reasoning. Give it
`prompts/spec-classifier.md`, the input document, and any compact repo evidence
already known. The parent must not decide the input type directly.

The classifier must output:

- `input_shape`: `source_spec`, `hybrid`, `self_contained_plan`, or
  `plan_with_source`
- task kinds, such as documentation writing, code implementation, tests,
  product clarification, architecture, research, migration, or operations
- task direction/domain, such as pathology product, game product, algorithm
  product, developer tooling, platform/backend, frontend UI, data/ML, or
  business workflow
- recommended specialist lenses and why each is needed
- whether spec enhancement and plan writing should run or be skipped
- likely final verification and screenshot/E2E evidence category

If the input is already a valid implementation plan / execution spec, skip the
five-round spec discussion and plan-writing step only after confirming required
frontmatter, phase fields, final E2E2/report contract, and coverage appropriate
to the input shape:

- `plan_with_source`: source-requirement alignment proves no source information
  was lost.
- `self_contained_plan`: the plan is internally complete and self-consistent;
  do not claim source-spec no-loss because no separate source exists.

Write `.longtask/reports/<spec>/preflight-skip.md` with the reason and evidence,
then run plan-integrity review before phase execution.

## Spec Enhancement

For `source_spec` or `hybrid` input, run the enhancement pipeline before writing
the implementation plan. It does not wait for human confirmation between steps.

1. Based on the classifier result, spawn fresh specialist discussion subagents
   using `prompts/spec-roundtable.md`. Prefer gstack specialist reviewers when
   available:
   - Engineering / `gstack-plan-eng-review` for correctness, architecture,
     testing, security, performance, and maintainability
   - CEO/product / `gstack-plan-ceo-review` for product value, scope, sequencing,
     and business tradeoffs
   - Design / `gstack-plan-design-review` for UX, information architecture, and
     workflow coherence
   - UI design / `design-consultation` or `design-html` when the task includes
     visible UI, browser flows, interaction design, or visual deliverables
   - Industry expert for the classified domain, for example pathology product,
     game product, algorithm product, clinical workflow, data annotation, or
     model evaluation
2. Run exactly **five discussion rounds** unless a hard stop condition occurs.
   Each round receives the current enhanced-spec draft, prior consensus,
   unresolved disagreements, and compact repo evidence. Agents must converge on
   concrete spec edits, not produce open-ended commentary.
3. After each round, spawn a round-state editor using
   `prompts/spec-round-state.md` to write
   `.longtask/reports/<spec>/rounds/round-<N>-state.md`. That artifact becomes
   the next round's `current_enhanced_spec_draft`, `prior_consensus`, and
   `unresolved_disagreements` source. Without this artifact, do not continue to
   the next round.
4. After round five, spawn a consensus editor subagent using `gpt-5.5` with
   `xhigh` reasoning and `prompts/spec-consensus-editor.md` to write:
   - `.longtask/specs/<spec_basename>-enhanced-spec.md`
   - `.longtask/reports/<spec>/spec-update.md`
5. The update document must tell the user what changed:
   - added requirements, clarified requirements, removed ambiguity, verification
     additions, domain assumptions, product/design/engineering decisions,
     deferred or explicitly out-of-scope items, and unresolved risks
   - a source-spec-to-enhanced-spec alignment table proving no information was
     lost
6. If specialists disagree, the consensus editor chooses the smallest complete,
   reversible, verifiable option that preserves source intent and records the
   disagreement in the update document. Do not pause for human confirmation.

If `gpt-5.5` + `xhigh` cannot be selected for the input classifier, consensus
editor, plan writer, or plan-integrity reviewer subagents, apply the model
degradation policy instead of stopping reflexively.

## Implementation Plan Writing

For `source_spec` or `hybrid` input, spawn a fresh **implementation plan writer**
subagent using `gpt-5.5` with `xhigh` reasoning. Give it
`prompts/plan-writer.md`, the source spec, the enhanced spec, the spec update
document, and a compact repo evidence summary. The subagent must use
`writing-plans` to split the work into the implementation plan / execution spec:
explicitly load the `writing-plans` skill before writing, or follow the
`writing-plans` checklist embedded in `prompts/plan-writer.md` if skill loading
is unavailable.
The parent must not do this rewrite directly.

The plan writer must:

- Preserve every source-spec and enhanced-spec requirement or explicitly mark it
  out of scope with a reason.
- Assign stable requirement IDs and include an alignment matrix from source
  requirement to enhanced requirement, phase, DoD, verification command, and
  screenshot evidence.
- Split the work into phases named `P1`, `P2`, ...
- Add file scopes, `do_not_touch`, per-phase verification commands, and concrete
  DoD bullets.
- Add final E2E2 verification and screenshot-report requirements.
- Write the artifact to
  `.longtask/plans/<spec_basename>-implementation-plan.md`.

Long prompts and finer-grained tasks are acceptable. Dropping information is not.

After the plan writer finishes, or after an existing implementation plan is
accepted through input classification, spawn a fresh **plan integrity reviewer**
subagent using `gpt-5.5` with `xhigh` reasoning and
`prompts/plan-integrity-review.md`. It audits the source/input document,
enhanced spec if present, update or skip document, and implementation plan for
omissions, weakened requirements, missing verification, ambiguous phase
ownership, and reward-hacking risk. It writes
`.longtask/reports/<spec>/plan-integrity-review.json`.
The parent validates that JSON against
`schemas/plan-integrity-review.schema.json`; schema failure blocks phase
execution.

If the source spec or hybrid input is too ambiguous to preserve intent after the five-round
discussion, stop with `BLOCKED_SPEC_REWRITE` instead of guessing. Phase
execution cannot begin until the plan-integrity reviewer returns PASS.

## Implementation Plan / Execution Spec Schema

Top-level frontmatter in the implementation plan / execution spec is required:

```yaml
---
source_spec_path: "docs/superpowers/specs/example-design.md"
source_spec_sha256: "..."
final_verify_cmd: "npm test && npm run build"
final_e2e2_cmd: "npm run test:e2e -- reading-room.spec.ts"
final_report_path: ".longtask/reports/example/final-report.md"
---
```

`final_verify_cmd` and `final_e2e2_cmd` are required. `final_smoke_cmd` may be
accepted only as an alias when it is explicitly an E2E2/browser screenshot
command. A longtask without a final E2E2 gate is BLOCKED unless the user
explicitly overrides this skill for that run.

`verify_cmd`, `final_verify_cmd`, `final_e2e2_cmd`, and `final_smoke_cmd` must
not push, open PRs, deploy, mutate infrastructure, or perform externally visible
actions. Shipping is a separate workflow requiring explicit user intent.

Each phase is a markdown heading beginning with `P1`, `P2`, etc.

Required fields:

```yaml
source_requirements: [REQ-001, REQ-002]
goals: one sentence describing what this phase must achieve
file_scope: [src/path/**, tests/path/test_file.py]
do_not_touch: [src/auth/**, .env*, data/**]
verify_cmd: "pytest tests/path/test_file.py -v"
verify_passes_when: "exit 0 and the named regression tests pass"
dod:
  - "Concrete acceptance criterion tied to the source or enhanced spec"
```

Optional fields:

```yaml
inputs: [P1 commit, generated artifact]
outputs: [symbol or file expected by later phases]
max_retry_rounds: 3
```

Keep phases small. If a verifier failure would not tell the next worker exactly
where to focus, split the phase.

## Native Subagent Loop

Before the first phase:

1. Read the input document and initialize/update
   `.longtask/state/<spec_basename>.json`.
2. Spawn the `gpt-5.5` + `xhigh` input classifier and record
   `.longtask/reports/<spec>/spec-classification.json`.
3. If the classifier says the input is `self_contained_plan` or
   `plan_with_source`, write
   `.longtask/reports/<spec>/preflight-skip.md`, set
   `implementation_plan_path` to the input or refreshed plan artifact, and skip
   only spec enhancement and plan writing.
4. If the classifier says the input is `source_spec` or `hybrid`, run the
   five-round specialist discussion and consensus edit to produce the enhanced
   spec and spec-update document.
5. For `source_spec` or `hybrid` input, spawn the `gpt-5.5` + `xhigh`
   implementation plan writer using `writing-plans` to produce or refresh the
   implementation plan / execution spec.
6. Spawn the `gpt-5.5` + `xhigh` plan-integrity reviewer and require PASS.
7. Validate that every source/input and enhanced-spec requirement appears in the
   plan alignment matrix, phase `source_requirements`, DoD, or explicit
   out-of-scope list.
8. Stop on omissions, contradictions, missing final E2E2, missing screenshot
   report contract, or failed plan-integrity review.

For each phase in the implementation plan / execution spec:

1. Validate required fields and initialize/update
   `.longtask/state/<spec_basename>.json`.
2. Spawn one **worker** subagent for the phase:
   - give it the phase block, `file_scope`, `do_not_touch`, relevant prior
     outputs, and `prompts/worker.md`
   - assign ownership of only the phase files
   - tell it there may be other agents in the workspace
   - require it to edit files directly, not commit, and list changed paths
   - require its final message to be the worker JSON described in
     `prompts/worker.md`; `BLOCKED_*` stops the phase
3. Wait for the worker.
   - If the worker returns `decision_options`, run the Decision Gate before
     retrying or stopping for a hard risk.
4. Parent runs a lightweight hard gate:
   - `git status --porcelain=v1`
   - `git diff --name-only HEAD`
   - reject changes outside `file_scope`
   - reject changes inside `do_not_touch`
   - ignore `.longtask/**` artifacts, the source/input spec, and the implementation
     plan artifact unless the phase explicitly owns them
5. Spawn one fresh **verifier** subagent:
   - give it `prompts/verifier.md`, the phase block and changed path list
   - tell it to run `git diff HEAD -- <changed-paths>` itself inside the
     subagent context; the parent does not paste large diffs
   - require it to run `verify_cmd` literally
   - require structured JSON matching
     `schemas/verifier-result.schema.json`
   - forbid edits, staging, and commits
6. Parent checks the verifier did not mutate the worktree.
7. Parent extracts exactly one JSON object from the verifier final message,
   validates it against `schemas/verifier-result.schema.json`, and writes it to
   `.longtask/reports/<spec>/<Pn>-r<N>-verdict.json`. Schema failure is
   `VERIFIER_SCHEMA_INVALID`.
8. PASS requires:
   - `verdict == "PASS"`
   - `verify_cmd_exit == 0`
   - every `dod_results[].passed == true`
   - `reward_hacking_signals == []`
9. On PASS, parent commits only phase files:
   `git add -- <changed-files>` then
   `git commit -m "[longtask:<spec>:<Pn>] <goal>"`.
10. On FAIL, spawn a new worker subagent with
    `prompts/retry-worker.md`, verifier JSON, and changed path list. The retry
    worker runs its own targeted `git diff`. Retry up to `max_retry_rounds`.
11. If still failing, write
    `.longtask/reports/<spec>/<Pn>-blocked.md` and stop.

For high-risk phases, spawn a second verifier before commit using the
quality/security verifier role from the model policy. Commit only if both
verifiers pass.

If a decision review chooses an option, record the decision JSON at
`.longtask/reports/<spec>/<Pn>-decision-r<N>.json` and include its follow-up
instructions in the next worker prompt.

State should record native evidence, not just phase names:

- `mode: "native-subagents"`
- `input_path`
- `input_sha256`
- `input_shape`
- `source_spec_path`
- `source_spec_sha256`
- `enhanced_spec_path`, if created
- `enhanced_spec_sha256`, if created
- `spec_update_path`, if created
- `preflight_skip_path`, if preflight was skipped
- `classification_path`
- `round_state_paths[]`, if spec enhancement ran
- `implementation_plan_path`
- `implementation_plan_sha256`
- `plan_integrity_review_path`
- `model_degraded`
- `model_requests[]` with role, requested model/reasoning, actual
  model/reasoning, and degradation reason
- `base_head`
- `agents[]` with `agent_id`, role, phase, round, start/end time
- `pre_status` and `post_status`
- changed files and diff stat
- verifier artifact path or verifier final JSON
- integration commit
- blocked reason, if any

The parent can continue this loop unattended. It does not ask the user between
phases.

## Final Verification

After all phases pass:

1. Spawn a fresh final E2E2/report subagent using `gpt-5.5` with `xhigh`
   reasoning.
2. The final E2E2/report subagent runs `final_verify_cmd`.
3. The final E2E2/report subagent runs `final_e2e2_cmd` (or `final_smoke_cmd`
   only when it is explicitly the E2E2/browser screenshot command).
4. The final E2E2/report subagent saves screenshots under
   `.longtask/reports/<spec>/screenshots/`.
5. The final E2E2/report subagent writes
   `.longtask/reports/<spec>/final-report.md` covering:
   - source/input spec requirement -> enhanced spec -> implementation plan
     phase/DoD alignment
   - implementation plan -> source/input spec alignment, including explicit
     proof of no omitted requirements
   - screenshot path -> visible content -> source requirement validated
   - commands run, exit codes, and compact output excerpts
   - residual risks or blocked evidence, if any
6. Spawn a fresh final alignment reviewer subagent with
   `prompts/final-alignment-review.md` using `gpt-5.5` + `xhigh` over the
   source/input spec, enhanced spec if present, implementation plan, final
   report, screenshot list, command excerpts, diff stat, and commit list.
7. Update `.longtask/state/<spec>.json`.
8. Stop before push/PR/deploy unless the user separately invokes a shipping
   workflow.

Browser QA should be an explicit command when possible, for example Playwright.
If a project needs visual gstack QA, the verifier must still return a compact
structured report and screenshot paths under `.longtask/reports/<spec>/`.

## Resume

State file:

```json
{
  "spec_path": "...",
  "spec_sha256": "...",
  "input_path": "...",
  "input_sha256": "...",
  "input_shape": "source_spec",
  "source_spec_path": "...",
  "source_spec_sha256": "...",
  "enhanced_spec_path": ".longtask/specs/example-enhanced-spec.md",
  "enhanced_spec_sha256": "...",
  "spec_update_path": ".longtask/reports/example/spec-update.md",
  "preflight_skip_path": null,
  "classification_path": ".longtask/reports/example/spec-classification.json",
  "round_state_paths": [".longtask/reports/example/rounds/round-1-state.md"],
  "implementation_plan_path": ".longtask/plans/example-implementation-plan.md",
  "implementation_plan_sha256": "...",
  "plan_integrity_review_path": ".longtask/reports/example/plan-integrity-review.json",
  "model_degraded": false,
  "model_requests": [],
  "started_at": "...",
  "phases": {
    "P1": {
      "status": "PASS",
      "rounds": 1,
      "commit": "abc123",
      "changed_files": ["..."],
      "verdict": ".longtask/reports/spec/P1-r1-verdict.json"
    }
  }
}
```

Native resume protocol:

1. Read `.longtask/state/<spec>.json`.
2. Verify `input_sha256`, `enhanced_spec_sha256` when present, and
   `implementation_plan_sha256` still match. If the input changed, stop and
   rerun classification, optional five-round discussion, optional plan writing,
   and plan-integrity review before resuming.
3. For every phase marked `PASS`, verify its commit still exists with
   `git cat-file -e <commit>^{commit}`.
4. Verify the worktree has no unrelated dirty files. Pending files recorded in a
   non-PASS phase may be retried; any new dirty file blocks resume.
5. Skip verified PASS phases.
6. Restart the first non-PASS phase with fresh worker/verifier subagents.
7. Append new `agents[]` entries instead of mutating old evidence.

## Fallback Runner

`lib/longtask-runner.py` and `lib/codex-wrapper.sh` remain as a fallback for CI
or terminal-only environments. They are not the preferred Codex app path. Do not
choose them when native subagents are available.

Fallback command:

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py .longtask/plans/<spec>-implementation-plan.md --repo .
```

Use fallback only when:

- the user explicitly asks for CLI/CI automation, or
- native subagents are unavailable in the current environment.

The fallback runner accepts only a pre-normalized implementation plan /
execution spec. It does not classify, enhance, or rewrite a brainstorming source
spec.

## Files

| File | Purpose |
|---|---|
| `prompts/worker.md` | Worker subagent contract |
| `prompts/retry-worker.md` | Retry worker prefix |
| `prompts/verifier.md` | Verifier subagent contract |
| `prompts/conductor.md` | Parent conductor checklist |
| `prompts/spec-classifier.md` | Input shape, task-kind, and domain classifier prompt |
| `prompts/spec-roundtable.md` | Five-round specialist discussion and consensus prompt |
| `prompts/spec-round-state.md` | Per-round draft/consensus/disagreement state prompt |
| `prompts/spec-consensus-editor.md` | Enhanced spec and spec-update writer prompt |
| `prompts/plan-writer.md` | Enhanced spec to implementation plan prompt using `writing-plans` |
| `prompts/plan-integrity-review.md` | Source/enhanced spec to plan no-loss audit prompt |
| `prompts/spec-normalizer.md` | Compatibility alias for the plan writer prompt |
| `prompts/final-e2e2-report.md` | Final E2E2 screenshot report subagent contract |
| `prompts/final-alignment-review.md` | Final spec/plan/report/screenshot alignment reviewer prompt |
| `prompts/decision-review.md` | Decision Gate reviewer prompt |
| `schemas/verifier-result.schema.json` | Verifier JSON contract |
| `schemas/decision-review.schema.json` | Decision Gate JSON contract |
| `schemas/plan-integrity-review.schema.json` | Plan integrity review JSON contract |
| `lib/longtask-runner.py` | Deprecated fallback runner for CI/CLI |
| `lib/codex-wrapper.sh` | Deprecated fallback wrapper for CI/CLI |

## Known Limits

- Native subagent file integration depends on the current Codex environment.
  The parent must verify actual git diff before committing.
- The fallback runner has a simple phase parser; avoid complex YAML there.
- This skill does not push, open PRs, or deploy.
