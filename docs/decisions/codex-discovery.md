# Codex Discovery Decision (P1)

## Context

P1 restructures the repository into a dual-harness layout while preserving safe
runtime boundaries. Codex runtime installation authority is not fully proven in
this phase.

## Decision

- Selected `install_policy`: `manifest-deferred`.
- `codex-extension.json` is kept provisional and non-authoritative in P1.
- Source material is copied from `/Users/leoleon/.codex/skills/longtask` into
  repo-local `skills/codex-longtask`, `codex/prompts`, and `codex/lib` without
  mutating real Codex home.

## Consequences

- Claude plugin marketplace remains scoped to Claude skill discovery only.
- Later phases can promote Codex authority only with explicit runtime evidence.
