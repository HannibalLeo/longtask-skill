# Known Traps Appendix — DEPRECATED POINTER (2026-05-27 token-waste refactor)

> This single-file appendix was split into two files to stop prepending Claude
> harness specifics (Category 5) to codex worker / verifier dispatches that
> have no Agent tool, no 1M context budget, and no `/ship` Skill. See REQ-001
> and REQ-002 in `docs/specs/2026-05-27-token-waste-refactor-spec.md`.
>
> The split:
>
> - **`known-traps-universal.md`** — Categories 1–4 (codex CLI quirks, reward
>   hacking, scope drift, verifier integrity). Referenced by ALL workers and
>   verifiers (both Claude and codex pipelines).
> - **`known-traps-claude-only.md`** — Category 5 (Claude harness specifics:
>   Agent tool, 1M context budget, `/ship` Skill). Concatenated with the
>   universal file by `claude-sub-agent.md` into the per-phase runtime file
>   `.longtask/known-traps-active-{spec_basename}.md`. Claude workers
>   `Read` that combined file as their first action; codex workers and
>   verifiers never see it.
>
> Any dispatch prose still referring to `known-traps-appendix.md` should be
> updated:
>
> - Worker / verifier checklist references → `known-traps-universal.md`.
> - Claude worker prepended content → the runtime file
>   `.longtask/known-traps-active-{spec_basename}.md`.
> - Codex worker prepended content → `known-traps-universal.md` only.
