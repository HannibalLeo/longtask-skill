# longtask-skill v0.5.0

Dual-harness longtask repository (Claude + Codex).

Canonical skills:

- Claude: `claude-longtask`, `claude-longtask-plan`, `claude-longtask-code`, `claude-longtask-review`
- Codex: `codex-longtask`, `codex-longtask-code`

## v0.5.0 highlights

1. Claude-end planning simplified: the spec stage collapses to a single codex sanity check (one `NEEDS_REVISION` pass max); the plan stage now delegates to the gstack `autoplan` skill (CEO / eng / design / DevEx roles, each Claude + Codex cross-voice, with a user approval gate), replacing the bespoke cross-rounds roundtable (9 prompt files removed).
2. Model tier standardized to `claude-opus-4-8` (opus 4.8 xhigh).
3. plan->code handoff renamed: `plan_post_review_sha256`, mode `claude-plan-only` / `claude-hybrid`.
4. Requires gstack (for `autoplan`). final-alignment (Step 8) still mandatory dual Claude+Codex.

See [docs/specs/2026-06-05-planning-stage-simplification-design.md](docs/specs/2026-06-05-planning-stage-simplification-design.md).

## Codex install

Creates only:

- `${CODEX_HOME}/skills/codex-longtask`
- `${CODEX_HOME}/skills/codex-longtask-code`

```bash
bash scripts/install-codex.sh
```

Options:

```bash
bash scripts/install-codex.sh \
  --source-dir "$PWD" \
  --codex-home "${CODEX_HOME:-$HOME/.codex}" \
  --dry-run \
  --force-backup \
  --backup-conflicts
```

Deprecated hidden alias:

- `--force` -> warns and maps to `--force-backup` (does not back up foreign conflicts unless `--backup-conflicts` is also set)

## Codex uninstall

```bash
bash scripts/uninstall-codex.sh
```

Restore backups only from `<codex-home>/longtask-backups/`:

```bash
bash scripts/uninstall-codex.sh \
  --codex-home "${CODEX_HOME:-$HOME/.codex}" \
  --restore-backup "<codex-home>/longtask-backups/<stamp>"
```

## Workflow docs

- [docs/workflows.md](docs/workflows.md)
- [docs/migration-from-v0.2.md](docs/migration-from-v0.2.md)

## Discovery policy

Per P1 discovery, `codex-extension.json` remains provisional/non-authoritative (`manifest-deferred`) until runtime authority is explicitly proven.
