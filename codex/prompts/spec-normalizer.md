# Longtask Spec Normalizer Prompt

Compatibility alias for `prompts/plan-writer.md`.

Use `prompts/plan-writer.md` for new longtask runs. The old "spec normalizer"
role has been split into:

1. `prompts/spec-classifier.md` for input shape, task kind, and domain.
2. `prompts/spec-roundtable.md` for five-round specialist spec enhancement.
3. `prompts/spec-round-state.md` for per-round carry-forward state.
4. `prompts/spec-consensus-editor.md` for the enhanced spec and update document.
5. `prompts/plan-writer.md` for the `writing-plans` implementation plan.
6. `prompts/plan-integrity-review.md` for no-loss auditing before execution.

If a runner still loads this file, treat it as a request to perform the
`plan-writer` role after classification and optional spec enhancement have
already completed. Preserve every source/enhanced requirement, write exactly one
implementation plan / execution spec, and require a separate plan-integrity
review before phase execution.
