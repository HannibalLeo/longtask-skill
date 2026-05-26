# longtask-skill v0.3.0

双执行面（Claude + Codex）的 longtask 技能仓库。

- Claude 面：`claude-longtask`、`claude-longtask-plan`、`claude-longtask-code`、`claude-longtask-review`
- Codex 面：`codex-longtask`、`codex-longtask-code`

## v0.3.0 关键点

1. 仓库统一为单一 canonical 结构（`skills/`, `claude/`, `codex/`, `shared/`, `fixtures/`）。
2. 共享可执行 schema 仅在 `shared/schemas/`。
3. 提供保守的 Codex 安装/卸载脚本：
   - `scripts/install-codex.sh`
   - `scripts/uninstall-codex.sh`
4. 增加 stale reference 扫描：
   - `scripts/scan-stale-references.sh`

## 安装（Codex）

默认仅创建两个软链接：

- `${CODEX_HOME}/skills/codex-longtask`
- `${CODEX_HOME}/skills/codex-longtask-code`

```bash
bash scripts/install-codex.sh
```

常用参数：

```bash
bash scripts/install-codex.sh \
  --source-dir "$PWD" \
  --codex-home "${CODEX_HOME:-$HOME/.codex}" \
  --dry-run
```

冲突处理：

- `--force-backup`：允许替换 owned 链接
- `--backup-conflicts`：与 `--force-backup` 联用时，允许备份并替换 foreign conflict
- 隐藏兼容参数 `--force`：会打印弃用告警并映射到 `--force-backup`

## 卸载（Codex）

```bash
bash scripts/uninstall-codex.sh
```

支持恢复备份（仅允许 `<codex-home>/longtask-backups/` 下路径）：

```bash
bash scripts/uninstall-codex.sh \
  --codex-home "${CODEX_HOME:-$HOME/.codex}" \
  --restore-backup "<codex-home>/longtask-backups/<stamp>"
```

## 工作流

- Fast path（计划 -> 执行 -> 评审）：见 [docs/workflows.md](docs/workflows.md)
- Safe path（全 Claude 路由）：见 [docs/workflows.md](docs/workflows.md)
- v0.2 迁移：见 [docs/migration-from-v0.2.md](docs/migration-from-v0.2.md)

## Discovery 决策（P1）

- `codex-extension.json` 当前是**provisional / non-authoritative**
- 安装策略证据为 `manifest-deferred`
- 运行时权威结论以前端发现证据为准：
  - [docs/decisions/codex-discovery.md](docs/decisions/codex-discovery.md)
  - `.longtask/reports/.../discovery/codex-discovery.json`

## Stale References

生成报告：

```bash
bash scripts/scan-stale-references.sh --fail-active
```

默认输出：

`.longtask/reports/2026-05-26-longtask-dual-harness-restructure-design/stale-references.json`
