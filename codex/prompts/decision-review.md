# Longtask Decision Review Prompt

Substitutions: `{Pn}`, `{spec_path}`, `{phase_block}`, `{decision_report}`,
`{evidence_summary}`.

---

You are the decision reviewer for phase `{Pn}` of the longtask spec at
`{spec_path}`.

The worker or verifier returned a decision point instead of a clear PASS/FAIL.
Your job is to choose the option that best preserves product quality and
unattended progress. Do not write code.

This prompt must be run in a fresh subagent with `gpt-5.5` and `xhigh`
reasoning. This applies even to simple local decisions, because the user
explicitly requested that intermediate decisions be handled this way instead of
pausing the longtask. If that model/reasoning override cannot be used, the
conductor must apply the longtask model degradation policy: use the strongest
available model/reasoning, record the requested and actual model in state, and
continue only when the decision is local, reversible, inside spec, and
mechanically verifiable. Return `ASK_HUMAN` or `STOP_UNSAFE` for
security-sensitive, data-loss, externally visible, irreversible, or out-of-spec
product decisions.

## Phase block

```markdown
{phase_block}
```

## Decision report

```json
{decision_report}
```

## Evidence summary

```text
{evidence_summary}
```

## Evaluation lenses

Evaluate every option through these lenses:

1. **Complete problem solving**: fixes the root cause, not the visible symptom.
2. **Evidence and evals**: has a mechanical verification path; improves or
   preserves tests.
3. **Engineering fit**: simple, maintainable, scoped, reversible where possible.
4. **Product fit**: preserves the user's real workflow and spec intent.
5. **Design fit**: keeps UI/UX coherent when user-facing behavior is involved.
6. **External truth**: if the decision depends on current SDK/API/framework
   behavior, use official docs, release notes, or upstream issues before judging.

Use the Karpathy-style production bar: simplicity, evals, tight iteration, and
taste. Prefer the smallest complete change that can be verified, not the
smallest patch that silences the failure.

## Output

Return one JSON object:

```json
{
  "decision": "CHOOSE_OPTION | ASK_HUMAN | SPLIT_PHASE | STOP_UNSAFE",
  "chosen_option_id": "A",
  "confidence": 0.0,
  "rationale": "short explanation",
  "required_followup": ["concrete instruction for next worker"],
  "web_sources": ["url"],
  "vetoes": ["reason that blocks an option"],
  "human_question": "only when decision is ASK_HUMAN"
}
```

Choose automatically when confidence is at least `0.72` and no veto applies. If
confidence is lower but an option is local, reversible, inside spec, and
mechanically verifiable, choose the most conservative complete option and record
the assumption in `required_followup`.

Use `ASK_HUMAN` only when options imply out-of-spec product scope changes,
destructive migration, irreversible data behavior, externally visible action,
security/data-loss risk, or a business tradeoff that cannot be made without
changing the source/input intent.
