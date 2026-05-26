# Migration from v0.2 to v0.3.0

## 目标

从旧的 v0.2 命名和目录习惯迁移到 dual-harness canonical 结构，并保留可控回滚路径。

## 旧 -> 新映射

| v0.2 习惯 | v0.3.0 canonical |
| --- | --- |
| `skills/longtask` | `skills/claude-longtask` |
| `skills/longtaskPlan` | `skills/claude-longtask-plan` |
| `skills/longtaskCode` | `skills/claude-longtask-code` |
| （新增） | `skills/claude-longtask-review` |
| （新增） | `skills/codex-longtask` |
| （新增） | `skills/codex-longtask-code` |

## 仍然可用的能力

1. Fast path（plan -> codex code -> review）
2. Safe path（Claude 主路径）
3. Codex-only path

## 有意的破坏性变化

1. 旧目录名不再是 active canonical skill 目录。
2. `codex-extension.json` 不作为当前 runtime authority（P1 discovery: `manifest-deferred`）。
3. Codex 安装只允许两个技能软链接，不做全量目录注入。

## Claude 升级方式

使用 canonical 的 Claude skill 名称：

- `claude-longtask`
- `claude-longtask-plan`
- `claude-longtask-code`
- `claude-longtask-review`

## Codex 安装方式

```bash
bash scripts/install-codex.sh \
  --source-dir "$PWD" \
  --codex-home "${CODEX_HOME:-$HOME/.codex}"
```

如需演练：

```bash
bash scripts/install-codex.sh --dry-run
```

## 三步 Fast Path（v0.3.0）

```text
claude-longtask-plan <spec>
codex-longtask-code <handoff-manifest>
claude-longtask-review <handoff-manifest>
```

## Safe Path（v0.3.0）

```text
claude-longtask <spec>
claude-longtask-code <plan-or-handoff>
```

## 回滚与卸载

卸载：

```bash
bash scripts/uninstall-codex.sh \
  --source-dir "$PWD" \
  --codex-home "${CODEX_HOME:-$HOME/.codex}"
```

从备份恢复：

```bash
bash scripts/uninstall-codex.sh \
  --source-dir "$PWD" \
  --codex-home "${CODEX_HOME:-$HOME/.codex}" \
  --restore-backup "<codex-home>/longtask-backups/<stamp>"
```

恢复目录如果不在 `<codex-home>/longtask-backups/` 下会被拒绝（`ERROR_PATH_ESCAPE`）。

## stale-reference 排障

运行扫描：

```bash
bash scripts/scan-stale-references.sh --fail-active
```

匹配分类：

- `forbidden_active_reference`: 会导致失败
- `allowed_historical_reference`
- `allowed_non_authoritative_search_phrase`

`longtaskPlan` / `longtaskCode` / `plugin/` 等 legacy 词可以作为历史说明或检索短语存在，但不能作为 active executable 路径契约。
