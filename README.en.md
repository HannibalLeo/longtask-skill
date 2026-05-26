# longtask-skill v0.3.0

Dual-harness longtask repository (Claude + Codex).

Canonical skills:

- Claude: `claude-longtask`, `claude-longtask-plan`, `claude-longtask-code`, `claude-longtask-review`
- Codex: `codex-longtask`, `codex-longtask-code`

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
