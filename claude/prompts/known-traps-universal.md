# Known Traps — Universal (codex CLI + reward hacking + scope + verifier)

> Referenced by every worker and verifier prompt as mandatory pre-task
> orientation. Harness-independent — applies equally to Claude- and
> codex-orchestrated runs. Claude workers additionally consume
> `known-traps-claude-only.md` (Category 5 — Agent tool / 1M context / `/ship`
> Skill); codex workers and verifiers receive this file only. Per-repo project
> details belong in `CODEX_PROTOCOL.md` or `spec.inject_context.always`, not
> here.

---

## Category 1 — Codex CLI Quirks

**Trap 1.1 — No-TTY + large prompt: silent exit (issue #19945)**
Feeding a large prompt string inline via stdin in no-TTY environments (e.g. a CI pipe
or a background shell) causes codex to exit 0 silently without producing any output or
diff. The `codex-wrapper.sh` works around this with a `script -q /dev/null` PTY
attachment and writes the prompt to a temp file rather than piping it inline. Never
pass the prompt as a heredoc directly to codex stdin; always use a file path.

**Trap 1.2 — `codex_core::session` rollout error is noise**
The stderr line `codex_core::session: failed to record rollout items: thread not found`
appears under the `script` PTY wrapper in some codex versions. It is not a failure
signal — codex still ran and produced output. Ignore it when parsing exit codes and
output. Do not treat it as `BLOCKED_CODEX_WRAPPER_FAILURE`.

**Trap 1.3 — Prompt must be a file path**
The codex wrapper requires a **file path** as its first argument. Inline prompts,
here-string injection, or shell substitution of large strings all trigger the stdin
pipe hang from issue #19945. Write the prompt to `/tmp/codex-prompt-{Pn}-r{N}.txt`
first, then pass that path to the wrapper.

**Trap 1.4 — `exit 142` = STALL, not permanent FAIL**
The wrapper kills codex after 10 minutes of no new stdout line and returns exit 142.
This is a stall signal (stdin pipe hang, auth hang, networking deadlock, or reasoning
budget exhausted mid-generation). First occurrence → retry. Two consecutive 142 exits
for the same phase round → return `BLOCKED_CODEX_WRAPPER_FAILURE`. Do not treat 142
as evidence that the implementation is wrong; the worker may not have had the chance
to start writing.

**Trap 1.5 — `--output-schema` enforces structure on last message only**
When using `codex exec --output-schema <file> -o <last_message.json>`, the schema is
applied to the final assistant message. If the codex session produces multiple assistant
turns, only the last one is captured in `-o`. Ensure verifier and decision-review prompts
explicitly instruct the model to emit the JSON object as its final and only output.

---

## Category 2 — Reward Hacking Patterns

These patterns cause tests to appear to pass without actually verifying the requirement.
The verifier must scan the diff for all of them. Any match forces `verdict: FAIL`.

**Trap 2.1 — Mock replacing real implementation**
Worker returns a stub or mock that satisfies the test surface but does not implement
the actual behavior. Signal: the implementation function body contains only `return
mock_value` or `pass`, or the "implementation" file is a test fixture.

**Trap 2.2 — Assertion weakening**
- `assert True` / `assert 1 == 1` — trivially passing assertion
- Removed `assert` statement replaced with `return` or a comment
- `assertTrue(True)` / `assertIsNotNone(anything)` without semantic check
- `try/except AssertionError: pass` — swallowing the failure

**Trap 2.3 — Test skipping without justification**
- `@pytest.mark.skip` without a `reason` keyword argument
- `pytest.skip()` outside a conditional guard (e.g. version/platform check)
- `@pytest.mark.xfail` added without a linked issue or `reason` explaining why the
  failure is expected and acceptable

**Trap 2.4 — Hardcoded fixtures / return values**
- Function returns a literal value specifically crafted to pass the one assertion
  being checked (detectable when the literal matches the test's expected value verbatim)
- Expected values copy-pasted from the new implementation's output rather than derived
  from the spec requirement

**Trap 2.5 — Test deletion or rename**
- Test file deleted rather than fixed
- Test function removed from a file that previously contained it
- Test renamed to something not matching the discovery pattern (e.g. `_disabled_test_foo`)

**Trap 2.6 — Test configuration loosening**
- Changes to `conftest.py`, `pytest.ini`, `setup.cfg`, `pyproject.toml` test config,
  or the `verify_cmd` itself that relax what counts as passing
- New environment variable or flag that makes assertions never execute, where the same
  flag is also set by the implementation

**Trap 2.7 — Suppression without explanation**
- `# noqa` added to suppress a linting or typing error introduced by the change
  (pre-existing `# noqa` in unchanged lines is acceptable)
- `# type: ignore` added on lines the worker modified

---

## Category 3 — Scope Drift

**Trap 3.1 — Writing outside `file_scope`**
Worker modifies a file not covered by any glob in `file_scope`. The sub-agent must
run `git diff --name-only HEAD` after each worker pass and compare every path against
`file_scope`. Any match outside → `BLOCKED_SCOPE`. Reset worktree before retry.

**Trap 3.2 — Unauthorized meta-file changes**
Worker modifies `README.md`, `CHANGELOG.md`, migration files, or other meta-files
that are not in `file_scope` and not listed in `do_not_touch` (but still outside scope).
These changes are often well-intentioned but violate the phase contract and pollute
the commit.

**Trap 3.3 — Touching `do_not_touch` paths**
Any file matching a `do_not_touch` glob must not appear in the diff, even if the
change looks beneficial. The `do_not_touch` constraint is a hard gate, not a suggestion.

**Trap 3.4 — Incremental scope creep across retries**
On retry rounds, the worker may expand the diff slightly each time ("just fixing one
more thing"), eventually drifting far outside the original scope. Compare each retry
diff against the Phase 1 scope gate result; reject any new paths that were not present
in the first successful scope check.

---

## Category 4 — Verifier Integrity

**Trap 4.1 — Verifier modifying source files**
The verifier must be strictly read-only. If `git status --porcelain` shows any new
or modified files after the verifier runs, the sub-agent must reject the verdict as
`VERIFIER_SCHEMA_INVALID` and report verifier mutation. The orchestrator must be
informed; do not commit.

**Trap 4.2 — Verifier fabricating `verify_cmd` results**
The verifier must run the literal `verify_cmd` from the spec and capture its actual
exit code. A verifier that infers "the tests probably pass" or "the diff looks correct"
without running the command is fabricating the verdict. Signal: `verify_cmd_exit: 0`
in the JSON but no corresponding `verify_cmd_excerpt` that shows actual test output.

**Trap 4.3 — Verifier skipping DoD evaluation**
Every `dod[]` bullet from the phase block must appear as a distinct entry in
`dod_results[]`. A verifier that groups multiple bullets into one entry, marks all
bullets as passed without citing evidence, or omits bullets entirely is not
performing genuine evaluation. `dod_results` must have at least as many entries as
there are bullets in `dod[]`.

**Trap 4.4 — Verifier rewarding "looks complete"**
The verifier may have alignment pressure toward marking work as PASS when the diff
looks substantive. Require the verifier to cite concrete `file:line` or command output
excerpts for every `dod_results[].passed == true` entry. "Implementation matches
spec intent" with no citation is not evidence.

**Trap 4.5 — Schema conformance but semantic inconsistency**
A JSON output that passes schema validation can still be semantically wrong:
`verdict: "PASS"` with any `dod_results[].passed == false` is a contradiction.
`verdict: "FAIL"` with all `dod_results[].passed == true` and
`reward_hacking_signals == []` is also a contradiction. The sub-agent's Step 5.5
checks handle these; verifiers should be aware they will be caught.

---

## Usage Summary

```
Claude worker prompt: Read .longtask/known-traps-active-{spec_basename}.md
                      (this file + known-traps-claude-only.md, concatenated
                      once per phase by claude-sub-agent.md)
Codex worker prompt:  prepend this file (universal only — no claude-only)
Verifier / decision-gate / final-alignment:
                      checklist reference only — "See known-traps-universal.md
                      categories 2 (reward hacking) and 4 (verifier integrity)."
```

Claude harness specifics (Agent tool / 1M context / `/ship` Skill) live in the
sibling `known-traps-claude-only.md`.
