# Longtask Retry Worker Prompt (Claude via Agent tool)

> This prompt runs in a fresh Claude Agent (model resolved from `model_tier`)
> via the `Agent` tool. It is the retry worker — called by the Claude
> sub-agent **only after** the codex verifier returned `verdict: FAIL`.
>
> Calling convention: parent prepends this preamble to the full
> `claude-worker.md` body, then dispatches via `Agent`.
>
> Substitutions: `{Pn}`, `{N-1}`, `{max}`, `{verifier_json}`, `{changed_paths}`.

---

The prior worker attempt for phase `{Pn}` failed independent verification in
round `{N-1}/{max}`.

## Verifier result (full JSON from prior round)

```json
{verifier_json}
```

Pay particular attention to:

- `reward_hacking_signals[]` — each entry names a specific file, line, and
  anti-pattern the verifier flagged. You must address each one directly.
  Adding `# noqa`, removing the test, or weakening the assertion is not
  acceptable — the verifier will flag the same pattern again.
- `dod_results[]` where `passed: false` — these are the concrete acceptance
  criteria that were not met. Fix the implementation, not the tests.
- `root_cause_hint` — the verifier's diagnosis of why the phase failed.
  Treat it as a starting hypothesis, not gospel. If you believe it points at
  the wrong location, see "Escalation rule" below.
- `verify_cmd_excerpt` — the actual failing output. Read it before guessing.

## Changed paths (from prior attempt)

```text
{changed_paths}
```

Run `git diff HEAD -- <changed paths>` yourself before editing. The parent
has already reset the worktree to HEAD before invoking you, so you are
starting from a clean tree (do not assume the prior diff is still applied).

## Constraints (same as the original worker, strictly enforced)

- Fix only the issues the verifier identified. Do not widen `file_scope`.
- Never adjust tests or test configuration to make `verify_cmd` pass — fix
  the production code.
- Do not revert unrelated, valid progress from the prior attempt — re-apply
  the parts of the prior diff that were correct, plus the targeted fix.
- Stage changes with `git add` but do **not** `git commit`.

## Escalation rule

If you conclude the verifier's assessment is incorrect (e.g., it flagged a
legitimate pattern as reward-hacking, or its `root_cause_hint` points to the
wrong location), do NOT try to override it yourself. Write the output JSON
with:

```json
{
  "status": "BLOCKED_OTHER",
  "blocked_reason": "RETRY_DISAGREE: <concise reason why the verifier assessment is wrong>",
  ...
}
```

The Claude sub-agent will review your disagreement against the verifier
JSON and decide the next step. You are not authorised to override the
verifier's verdict yourself.

## Original worker prompt

The original task for phase `{Pn}` follows. Apply it with the fixes required
by the verifier above.

---

(claude-worker.md content injected here by the caller)
