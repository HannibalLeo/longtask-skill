# Longtask Retry Worker Prompt (Codex GPT-5.5)

> This prompt runs in Codex GPT-5.5 via `codex exec` (owner 四步分工 step **(c) Codex 干活**).
> It is the retry worker — called by the Claude sub-agent **only after** the
> verifier returned `verdict: FAIL`.
> Calling convention: see `lib/codex-wrapper.sh`.
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
- `dod_results[]` where `passed: false` — these are the concrete acceptance
  criteria that were not met. Fix the implementation, not the tests.
- `root_cause_hint` — the verifier's diagnosis of why the phase failed.

## Changed paths (from prior attempt)

```text
{changed_paths}
```

Run `git diff HEAD -- <changed paths>` yourself before editing. Do not rely on
the parent to paste the diff.

## Constraints (same as original worker, strictly enforced)

- Fix only the issues the verifier identified. Do not widen `file_scope`.
- Never adjust tests or test configuration to make the verify_cmd pass — fix
  the production code.
- Do not revert unrelated, valid progress from the prior attempt.
- Stage changes with `git add` but do **not** `git commit`.

## Escalation rule

If you conclude that the verifier's assessment is incorrect (e.g., it flagged a
legitimate pattern as reward-hacking, or its root_cause_hint points to the wrong
location), you must output exactly:

```
RETRY_DISAGREE: <concise reason why the verifier assessment is wrong>
```

Do not continue fixing in that case. The Claude sub-agent will review and decide
the next step. You are not authorised to override the verifier's verdict yourself.

## Original worker prompt

The original task for phase `{Pn}` follows. Apply it with the fixes required by
the verifier above.

---

(codex-worker.md content injected here by the caller)

## Output contract

End your response with EXACTLY this stop signal line:

```
Worker DONE: <one-line summary of what was changed in this retry>
```

Then, on the next line, a single JSON object using the same schema as the
original worker (see `codex-worker.md` output contract). Set `status` to
`READY_FOR_VERIFIER` when the fix is complete, or `BLOCKED_*` if a hard
blocker remains.
