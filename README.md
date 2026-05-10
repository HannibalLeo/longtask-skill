# longtask

Codex 原生长任务 skill：给一份写好的分阶段 spec，由主会话作为 conductor，
按 phase 调度 native subagents 做实现和独立验证。目标是无人值守完成，而不是
“模型试着做了一下”。

`codex exec` runner 只保留为 CI/CLI fallback，不是 Codex app 默认路径。

## 默认路径：native subagents

每个 phase：

1. 主会话读取 spec phase 和 `.longtask/state/<spec>.json`。
2. 主会话 spawn 一个 worker subagent，使用 `prompts/worker.md`。
3. worker 只改 `file_scope`，不 stage、不 commit。
4. 主会话用 git 做硬门禁：changed files 必须在 `file_scope` 内，且不在
   `do_not_touch` 内。
5. 主会话 spawn 一个 fresh verifier subagent，使用 `prompts/verifier.md`。
6. verifier 只验证，不修改文件，返回符合 schema 的 JSON。
7. PASS 后主会话只提交本 phase changed files。
8. FAIL 则用 `prompts/retry-worker.md` 派下一轮 worker。

主会话保持低上下文：正常只看 spec、state、changed files、diff stat、
verifier JSON、blocked report 和 commit 列表。

默认不要让所有子 agent 继承高推理档位。推荐 worker/verifier 用 `medium`，
重复失败或 final reviewer 再升到 `high`；`xhigh` 只用于反复 BLOCKED、安全或
数据丢失风险。高风险 phase 优先跑两个独立 `medium` verifier，而不是一个
`xhigh` verifier。

## Spec 最小格式

```markdown
---
final_verify_cmd: "npm test && npm run build"
final_smoke_cmd: "npm run test:e2e -- reading-room.spec.ts"
# final_gate: none  # only when deliberately skipping final integration gate
---

# P1: Add health endpoint
goals: Add GET /healthz returning status ok.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, .env*]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and health endpoint tests pass"
max_retry_rounds: 3
```

## Fallback runner

只在 native subagents 不可用、或用户明确要 CLI/CI 自动化时使用：

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo .
```

检查 spec：

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --dry-run
```

断点恢复：

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --resume
```

## 文件

| 文件 | 用途 |
|---|---|
| `SKILL.md` | Codex skill 入口和操作契约 |
| `prompts/conductor.md` | 主会话 conductor checklist |
| `prompts/worker.md` | worker subagent prompt |
| `prompts/retry-worker.md` | retry worker prefix |
| `prompts/verifier.md` | verifier subagent prompt |
| `schemas/verifier-result.schema.json` | verifier 输出 schema |
| `lib/longtask-runner.py` | fallback runner |
| `lib/codex-wrapper.sh` | fallback `codex exec` wrapper |

## 压力场景

验证这个 skill 时至少覆盖：

- 未跟踪 spec 文件也能启动，且不会被提交。
- worker 请求扩大 `file_scope` 时停止。
- worker 修改 `do_not_touch` 时停止。
- verifier 尝试修代码时停止。
- verifier 返回 PASS 但测试失败时停止。
- `final_verify_cmd` 失败时停止。
- 没有 final gate 且未显式 `final_gate: none` 时停止。
- `verify_cmd/final_*_cmd` 包含 push/PR/deploy 时停止。
- fallback runner 不会被误当成默认路径。
