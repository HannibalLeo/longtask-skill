# Longtask Retry Worker Prefix

Substitutions: `{Pn}`, `{N-1}`, `{max}`, `{verifier_json}`, `{changed_paths}`.

---

The prior worker attempt for `{Pn}` failed independent verification in round
`{N-1}/{max}`.

## Verifier result

```json
{verifier_json}
```

## Changed paths

```text
{changed_paths}
```

Run `git diff HEAD -- <changed paths>` yourself before editing. The parent does
not paste large diffs into the prompt.

Root-cause the failure and update the working tree without reverting valid
progress. Do not widen scope. If the verifier result proves the spec or
`file_scope` is wrong, stop and report `BLOCKED_SPEC_OR_SCOPE`.
Stay in Step 6 scope: do not run final verify/final E2E2/push/PR/publish/deploy
or install commands.

The original worker prompt follows.
