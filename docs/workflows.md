# Workflows (v0.5.0)

## 1) Fast Path

```text
claude-longtask-plan <spec>
codex-longtask-code <handoff-manifest>
claude-longtask-review <handoff-manifest>
```

适用：本地、可逆、可机械验证、并且 phase 可由 Codex 执行。

## 2) Safe Path

```text
claude-longtask <spec>
claude-longtask-code <plan-or-handoff>
```

适用：高风险、合规/临床、安全、不可逆迁移、外部发布等场景。

## 3) Codex-only Path

```text
codex-longtask <spec>
```

适用：全程在 Codex 内执行 longtask。

## 4) Codex 安装与卸载

安装：

```bash
bash scripts/install-codex.sh --source-dir "$PWD" --codex-home "${CODEX_HOME:-$HOME/.codex}"
```

卸载：

```bash
bash scripts/uninstall-codex.sh --source-dir "$PWD" --codex-home "${CODEX_HOME:-$HOME/.codex}"
```

恢复备份：

```bash
bash scripts/uninstall-codex.sh \
  --source-dir "$PWD" \
  --codex-home "${CODEX_HOME:-$HOME/.codex}" \
  --restore-backup "<codex-home>/longtask-backups/<stamp>"
```

## 5) 稳定 transcript 合同

安装/卸载脚本输出固定前缀：

```text
LONGTASK_CODEX_HOME=<abs>
LONGTASK_SOURCE_DIR=<abs>
ACTION install|uninstall|restore|dry-run
ENTRY name=<skill> status=<status> target=<abs-or-null> backup=<path-or-null>
NEXT verify_command=<command>
```

状态枚举：

- install: `INSTALLED`, `UNCHANGED`, `REPLACED_OWNED`, `BACKED_UP_CONFLICT`, `CONFLICT_NON_SYMLINK`, `CONFLICT_FOREIGN_SYMLINK`, `SKIPPED_DRY_RUN`, `ERROR_PATH_ESCAPE`
- uninstall/restore: `REMOVED`, `SKIPPED_ABSENT`, `SKIPPED_FOREIGN`, `SKIPPED_NON_SYMLINK`, `RESTORED_BACKUP`, `SKIPPED_DRY_RUN`, `ERROR_PATH_ESCAPE`

## 6) Discovery 与安装策略

P1 discovery 当前结论：

- `codex-extension.json` 是 provisional/non-authoritative
- policy: `manifest-deferred`

因此 v0.3.0 的默认可执行安装方式是 `scripts/install-codex.sh` symlink 安装。

## 7) Stale Reference 扫描

```bash
bash scripts/scan-stale-references.sh --fail-active
```

报告输出：

`.longtask/reports/2026-05-26-longtask-dual-harness-restructure-design/stale-references.json`
