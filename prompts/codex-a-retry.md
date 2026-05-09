# Codex A Retry prompt prefix

> Prepended by sub-agent to a fresh Codex A prompt for rounds N≥2.
> Substitutions: `{N-1}`, `{max}`.

---

PRIOR ATTEMPT (round {N-1}/{max}) FAILED verification.

B's structured report:
<B's JSON verbatim>

Diff that failed:
<git diff>

Root-cause the failure. Production-quality fix, not a minimal patch. If the
failure points to a deeper architectural issue rather than a localized bug,
ABORT and report — do not paper over.

(Original A prompt follows.)

<original A prompt for {Pn}>
