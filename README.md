# longtask

`longtask` 是一个 Codex 原生 skill，用来执行已经写好的分阶段 spec。

它适合这样的任务：你已经把需求拆成 `P1`、`P2`、`P3` 等阶段，希望 Codex 在较少人工干预的情况下持续推进，实现每个阶段、独立验证、提交可恢复的阶段结果，并在风险变高时停下来给出证据。

它的目标不是“让模型尽量做一下”，而是把长任务变成一条有边界、有验证、有恢复点的执行流水线。

## 它解决什么问题

普通长任务容易失败在几个地方：

- 主会话上下文越来越大，后面判断质量下降。
- 实现和验证混在同一个上下文里，模型容易自证正确。
- 阶段之间没有明确提交点，失败后很难恢复。
- 测试绿了，但实际改动越界、弱化测试或破坏整体流程。

`longtask` 的设计是让主会话只做调度和门禁，把重上下文工作交给新的子 agent。每个阶段都要通过 git 范围检查、独立 verifier、测试命令和最终整体验证。

## 工作方式

默认路径是 Codex native subagents，不是 `codex exec`。

一次 phase 的流程是：

1. 主会话读取 spec 中的当前 phase。
2. 主会话启动 worker subagent。
3. worker 只在 `file_scope` 内实现代码，不提交。
4. 主会话用 git 检查实际改动文件，拒绝越界改动。
5. 主会话启动新的 verifier subagent。
6. verifier 只验证，不修改代码，运行 `verify_cmd` 并返回结构化结果。
7. 主会话校验 verifier 结果和工作区状态。
8. 通过后，主会话只提交本 phase 的改动。
9. 失败则把 verifier 证据交给下一轮 worker；超过重试次数后停止并写 blocked report。

主会话保持低上下文：正常只看 spec、状态文件、改动文件列表、diff stat、verifier JSON、blocked report 和 commit 列表。完整源码和大 diff 只在故障排查时读取。

## 决策点处理

执行中经常会出现“有几个方案，应该选哪个”的分叉。`longtask` 不会默认把这些都抛给人，也不会每次都启用最贵模型。

worker 或 verifier 可以返回 2-4 个候选方案。主会话会先做 Decision Gate：

1. 看这个选择是否局部、可逆、在 spec 范围内，并且能被测试验证。
2. 优先使用仓库里的证据；如果涉及当前 SDK/API/框架行为，再查官方文档、release notes 或上游 issue。
3. 用产品、工程、设计三个视角评估方案。
4. 置信度足够且没有 veto 时自动选择，并把具体 follow-up 交给下一轮 worker。
5. 只有产品范围变化、不可逆数据行为、安全风险、低置信度时才问人。

高风险决策可以升级到 `xhigh` 和 CEO/Eng/Design 风格评审。普通实现分叉优先用结构化 rubric 自动裁决。

## 角色分工

| 角色 | 职责 |
| --- | --- |
| Conductor | 主会话。解析 spec、启动子 agent、做 git 门禁、提交、恢复。 |
| Worker | 实现当前 phase。只改允许范围，不提交。 |
| Verifier | 独立验证当前 phase。运行测试、检查 DoD、检查 reward-hacking。 |
| Final reviewer | 多阶段全部完成后做整体风险审查。 |

默认推理档位不追求越高越好：worker/verifier 通常用 `medium`；重复失败或最终审查再升到 `high`；`xhigh` 只用于反复 blocked、安全风险或数据丢失风险。

## Spec 格式

一个 spec 是普通 Markdown 文件。每个阶段用 `P1`、`P2` 这样的标题标记。

```markdown
---
final_verify_cmd: "npm test && npm run build"
final_smoke_cmd: "npm run test:e2e -- reading-room.spec.ts"
---

# P1: Add health endpoint
goals: Add GET /healthz returning status ok.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, .env*]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and health endpoint tests pass"
max_retry_rounds: 3
```

必填字段：

- `goals`：这个阶段要完成什么。
- `file_scope`：worker 允许修改的路径。
- `do_not_touch`：绝对不能修改的路径。
- `verify_cmd`：verifier 必须运行的命令。
- `verify_passes_when`：验证通过的客观条件。

最终阶段也需要整体验证。推荐提供 `final_verify_cmd` 或 `final_smoke_cmd`。如果你明确不需要最终验证，写 `final_gate: none`，否则 longtask 会把缺失 final gate 视为风险。

## 运行与恢复

在 Codex app 里，触发 `longtask` 后主会话会按 native subagent 流程执行。它会把状态写到：

```text
.longtask/state/<spec>.json
```

恢复时会读取 state，校验 spec hash、已通过 phase 的 commit、工作区状态，然后从第一个未通过 phase 重新派发新的 worker/verifier。

## 什么时候会停止

这些情况不会自动糊过去：

- spec 缺字段或 phase 太模糊。
- worker 请求扩大 `file_scope`。
- 实际改动越过 `file_scope` 或命中 `do_not_touch`。
- verifier 修改了工作区。
- verifier 输出格式错误或自相矛盾。
- 测试失败或 DoD 未通过。
- `verify_cmd` / final command 试图 push、开 PR、deploy 或改基础设施。
- 最终整体验证失败。

停止时会留下 `.longtask/reports/<spec>/...`，用于继续修 spec、手动修复或恢复执行。

## CLI fallback

`lib/longtask-runner.py` 是给 CI 或没有 native subagents 的终端环境用的 fallback，不是 Codex app 的默认路径。

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo .
```

只检查 spec：

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --dry-run
```

恢复：

```bash
python3 ~/.codex/skills/longtask/lib/longtask-runner.py path/to/spec.md --repo . --resume
```

## 文件结构

| 文件 | 用途 |
| --- | --- |
| `SKILL.md` | skill 的操作契约 |
| `prompts/conductor.md` | 主会话执行 checklist |
| `prompts/worker.md` | worker subagent prompt |
| `prompts/retry-worker.md` | retry worker prompt |
| `prompts/verifier.md` | verifier subagent prompt |
| `prompts/decision-review.md` | decision gate prompt |
| `schemas/verifier-result.schema.json` | verifier 输出 schema |
| `schemas/decision-review.schema.json` | decision gate 输出 schema |
| `lib/longtask-runner.py` | CLI fallback runner |
| `lib/codex-wrapper.sh` | CLI fallback wrapper |
