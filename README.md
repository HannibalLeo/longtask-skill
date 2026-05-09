# longtask — Claude Code 的 Spec 驱动多阶段执行 Skill

**简体中文** · [English](README.en.md)

一个 Claude Code skill：把一份分阶段的 spec 文件变成自动化执行流水线。每个 phase 拉起一个一次性的 sub-agent，sub-agent 驱动 **Codex A（执行者）↔ Codex B（验证者）**，每轮都用全新上下文 + 严格 JSON 格式的 PASS/FAIL 判定 — 最多 N 轮 fix→verify 循环，超出后转 web 搜索决策、再不行就升级到人。

---

## 为什么要这个

LLM 编码 Agent 在长任务里失败的根因有两个：

1. **Context rot（上下文腐烂）** — 半路上上下文窗口已被无关推理塞满。
2. **Verifier capture（验证者被俘获）** — 写代码的模型同时判断代码对不对。

`longtask` 同时解决这两个问题：

- **每个 phase 一个全新 sub-agent + 每轮一次性 Codex 提示** → 杀掉 context rot。
- **A / B 严格分离**（提示不同、无共享记忆、只输出对照 spec `verify_cmd` 的 JSON 判定）→ 杀掉 verifier capture。

Orchestrator（当前 Claude Code 会话）从不读源码、从不跑测试 — 它只派发 sub-agent、维护状态。Sub-agent 不能扩大 scope。Codex A 只能写 phase 的 `file_scope` 内文件。Codex B 只读 artifact 与跑 spec 的 `verify_cmd`。真源在 spec 里，不在 agent 里。

---

## 架构

```
你（当前会话，opus）             = 主 Orchestrator
  ↓ Agent 工具，一次一个 phase
Sub-Agent（opus，每 phase 全新） = Phase Conductor
  ↓ Bash → codex exec，序列化 + 重试循环
Codex A（执行者）  ←→  Codex B（验证者，全新上下文）
```

| 层 | 读源码？ | 写代码？ | 提交？ | 持续期 |
|---|---|---|---|---|
| Orchestrator | spec + 状态文件 + sub-agent 报告 | NO | NO | 整个 spec 期间 |
| Sub-Agent | spec + git diff + 测试输出 + 状态文件 | NO（只写 codex 提示词） | YES（B 判 PASS 后） | 单 phase，DONE 后销毁 |
| Codex A | spec + scope 内文件 | YES（仅工作树） | NO | 每轮一次性 |
| Codex B | spec + 工作树 + 测试 | NO | NO | 每轮一次性 |

---

## 前置条件

### 操作系统

- **macOS**（在 Apple Silicon 实测过）
- **Linux**（应该可以，未跑 CI）
- **Windows 不官方支持** — Claude Code 在 Windows 仍可用，但 skill 假设是 POSIX shell + bash 风格 heredoc

### 必需的运行时

| 工具 | 最低版本 | 用途 |
|---|---|---|
| Claude Code CLI | latest | Skill 宿主；提供 `Skill` / `Agent` 工具；自动加载 `~/.claude/skills/` |
| Codex CLI | 较新版本（支持 `codex exec`、`--skip-git-repo-check`、`-c model=...`、`-c model_reasoning_effort=...`） | Phase Conductor 的 executor / verifier 循环 |
| `bash` | 4+ | sub-agent 通过 Bash 调 `codex exec` |
| `git` | 2.30+ | sub-agent 在每个 PASS 后 commit |
| `script(1)` | 任意 | 给 `codex exec` 重新挂 pseudo-TTY，绕开 [openai/codex#19945](https://github.com/openai/codex/issues/19945) 的 no-TTY 静默退出 bug。BSD（macOS 自带）和 util-linux 都支持 `script -q /dev/null <cmd>` 形式 |

### 必需的账号 / 访问权限

> **作者参考配置 = Claude（orchestrator + sub-agent）+ Codex（A 与 B）双模型**。但 skill 设计是**模型无关**的 — 真正不能动的不变量是 ① 每轮 fresh context，② 严格 JSON verdict 对照 spec 的 `verify_cmd`。所以**单模型也能跑**，详见下方「单模型设置」章节。

按作者参考配置：

- **Anthropic 账号** + Claude Code 访问 — Orchestrator 与每个 phase 的 sub-agent 都跑在 Claude `opus`。需要 Pro / Max 订阅，或者用 Claude API key（带足够配额）。通过 `claude auth login` 登录（运行 Claude Code 也会引导）。
- **OpenAI 账号** + **Codex CLI** 访问 + **GPT-5.5** 模型权限 — Codex A 和 Codex B 都跑 `codex exec ... -c model="gpt-5.5"`，`model_reasoning_effort="xhigh"`。通过 `codex auth login` 登录或设置 `OPENAI_API_KEY`。验证一行：

  ```bash
  codex exec --skip-git-repo-check -c model="gpt-5.5" -c model_reasoning_effort="xhigh" "say hi"
  ```

如果没有 GPT-5.5 权限，可以改 `SKILL.md` 里 `## Codex CLI invocation` 那段的模型名，换成你账号能用的（如 `gpt-5`、`gpt-4.1`），Codex CLI 那段的双角色循环不变。

### 单模型设置（可选）

`longtask` 不强制要求 Claude + Codex 双模型，两个**真正不能动的不变量**是：

1. **每轮 fresh context** — A 和 B 的 prompt 都是当轮新写的，没有跨轮共享 memory。
2. **严格 JSON verdict 对照 `verify_cmd`** — B 不"读了代码自由判断"，而是跑 spec 写明的命令、回固定 schema 的 JSON。

只要这两条满足，A / B 用什么模型都可以，**单模型同样跑得通**。底层原因：fresh context 是**提示词层面**的（每轮重写 prompt、不传 history），不是模型层面的。即使 A 和 B 是同一个模型，B 看到的 prompt 也只有 spec + 工作树 + `verify_cmd` 的输出，**完全没有 A 的 reasoning 链**，verifier capture 就被切断了。

异质模型（如作者用的 Claude + Codex）的额外好处是 **cross-model 验证**更稳 — B 的失败 mode 和 A 不同，更难一起出错。但这是"加分项"，不是 longtask 正确性的必要条件。

#### 常见替代组合

**全 Claude（只有 Anthropic 订阅）**

- Orchestrator 与 sub-agent 仍是 Claude Code 自身（不用动）
- 把 `SKILL.md` 里 `## Codex CLI invocation` 那段的命令换成：

  ```bash
  set -o pipefail
  SECONDS=0
  claude --print --model claude-sonnet-4-5 "$(cat <prompt_file>)" 2>&1 \
  | { while IFS= read -r -t 600 line; do
        SECONDS=0
        printf "%s\n" "$line"
      done
      [ $SECONDS -ge 600 ] && exit 142
      exit 0
    }
  ```

  Stall-only 杀逻辑：内层 `read -t 600` + `SECONDS` 区分 = 10 min 无新 stdout 行才 kill（exit 142）。**没有 wall-clock 硬上限**——claude 在出 token 就让它跑。`SECONDS` reset 是为了兼容 macOS bash 3.2（`read -t` 超时和 EOF 都返回 1，需要 SECONDS 区分）。如果你的替代 CLI 没有 codex#19945 那个 no-TTY bug（claude --print 就没有），可以省掉 `script -q /dev/null` 那层。

- 同一段命令，A 和 B 只是 prompt 不同；fresh context 仍然成立。
- B 的 JSON 输出强约束保留（提示词里要求"严格 JSON、否则视为 VERIFIER_MALFORMED_OUTPUT"），不依赖模型本身能不能"按 JSON 模式"。

**全 Codex（只有 OpenAI 账号、不想跑 Claude Code）**

- 这个组合不推荐 — Claude Code 的 `Skill` / `Agent` 工具是 longtask orchestrator 的关键依赖。如果你完全没有 Anthropic 账号，建议**用 Claude Code Pro 跑 orchestrator + sub-agent，A / B 仍走 codex**（这本来就是作者参考配置）。
- 真要全 Codex 跑，需要把 orchestrator / sub-agent 重写成外部 shell 脚本调度 codex，工作量较大，不在本 skill 默认 scope。

**全 Gemini / 其他 stateless one-shot CLI**

- 把 `## Codex CLI invocation` 段命令换成对应 CLI（gemini、`llm` 之类），原则同上：每次调用是 stateless 一次性的、Bash 调起。
- 不要选**默认带 history 的 CLI**（会破坏 fresh-context 不变量）。

#### 选型建议

- 单兵开发、想最低成本起步：**全 Claude（sonnet 或 opus）** —— 一个账号、一个鉴权、跑得通。
- 想要最强 cross-model 验证：作者参考组合（Claude `opus` orchestrator + Codex `gpt-5.5 xhigh` A/B）。
- 不论哪种组合，**`verify_cmd` 写得严谨**比"模型用最强款"对最终结果影响大得多 — 长任务失败几乎都是 spec 写崩，不是模型不够强。

### 可选但推荐

- **[gstack](https://github.com/garrytan/gstack)** — 仅当你用 spec 的 `gating:` / `ship:` 字段时需要。不装 gstack 也能用 longtask（`gating` 字段省略 / `ship: false` 默认就关），效果与不带这两个字段一致。
- **[claude-mem](https://github.com/thedotmack/claude-mem)** — 跨会话自动记忆；当一份 longtask spec 跨多个 Claude Code 会话时有用。

---

## 安装

### 1. 装 Claude Code（如果还没装）

按 [Anthropic 官方文档](https://docs.anthropic.com/en/docs/claude-code) 安装。验证：

```bash
claude --version
```

### 2. 装 Codex CLI 并登录

按 [OpenAI 的指南](https://github.com/openai/codex) 安装、登录，然后跑：

```bash
codex --version
codex exec --skip-git-repo-check -c model="gpt-5.5" -c model_reasoning_effort="xhigh" "say hi"
```

第二条命令返回了文字 → 鉴权和模型权限都就绪。

### 3.（可选）装 gstack

不打算用 `gating:` / `ship:` 的话跳过这一步。

```bash
# bun 是 gstack setup 脚本编译 /browse 二进制需要的
brew install oven-sh/bun/bun

# clone + 注册
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
cd ~/.claude/skills/gstack && ./setup --quiet
```

### 4. 装 longtask skill

```bash
git clone --single-branch --depth 1 https://github.com/HannibalLeo/longtask-skill.git ~/.claude/skills/longtask
```

Claude Code 自动加载 `~/.claude/skills/<name>/SKILL.md` 下的所有 skill，下次会话就能看到 `longtask`。

### 5. 验证

打开一个新的 Claude Code 会话（任何项目目录都行）。问：

```
list available skills
```

输出里应该能看到 `longtask`。冒烟测试可以把 `SKILL.md` 里 `## Spec schema` 那段的 inline 例子复制成 `spec.md`，把 `gating: []` 和 `ship: false` 设上，跑：

```
/longtask spec.md
```

Orchestrator 会校验 schema，立刻报出 Codex CLI 或鉴权配错的信息（如有）。

---

## 快速上手

在 `<repo>/spec.md` 写一份 spec：

```markdown
---
gating: [office-hours, plan-ceo-review, plan-eng-review]
ship: true
---

# P1: 加 /healthz 端点
goals: 暴露 `GET /healthz`，返回 `{"status":"ok"}`，HTTP 200，无需鉴权。
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, src/db/**]
inputs: []
outputs: [src/routes/health.ts（已注册到 app router）]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 且 0 个 failures"
max_retry_rounds: 3
```

然后在 Claude Code 里：

```
/longtask spec.md
```

Orchestrator 会：

1. 跑 gating skill（`office-hours` → `plan-ceo-review` → `plan-eng-review`），每个 gate 之间等你说"ok proceed"。`gating: []` 或省略字段 → 整段跳过。
2. 派一个全新 sub-agent 跑 P1；sub-agent 内部 Codex A↔B 循环，直到 PASS 或 BLOCKED。
3. PASS 后自动 commit、写状态到 `.longtask/state/spec.json`，进 P2。
4. 全部 phase PASS 后调 `gstack /ship`（push、开 PR）。省略 `ship:` → 不执行最后一步。

不写 `gating:` 和 `ship:` → 跑现有的旧行为（P1 立即开始、最后不自动 ship），新字段完全向后兼容。

完整字段、提示模板、重试 / 升级逻辑、状态文件格式、resume 规则（`/longtask <spec> --resume`）、roadmap，都在 `SKILL.md`。

---

## 已有设计文档？从中段开始

spec 已经成熟、想跳过前置时，常见三种用法：

| 你的情况 | 命令 | 行为 |
|---|---|---|
| spec 写好，不需要 review | `/longtask spec.md`（spec 不写 `gating:`） | 直接 P1→Pn，无 gating 循环 |
| spec 里写了 `gating:`，但你已经在 longtask 之外做完了决策 | `/longtask spec.md --skip-gating` | 一次性覆盖：忽略 spec 的 `gating:` 字段，直接进 P1。spec 文件不动 |
| 已经手动做完 P1/P2，要 longtask 从 P3 接手 | `/longtask spec.md --from P3` | 隐含 `--skip-gating`。P3 之前的 phase 在状态文件里写为 `SKIPPED`（无 commit sha、无轮数）。P3 当作起始 phase 跑 |
| 续接昨天 BLOCKED 的运行 | `/longtask spec.md --resume` | 读 `.longtask/state/<spec>.json`，跳过 PASS 的 phase。如果状态里有 `gating_cleared_at`，gating 也跳 |

**`--from <Pn>` 不验证之前 phase 的 outputs 是否真的存在**。你在断言"P1 / P2 已经做完"；如果其实没做完，Codex A 在 P3 大概率会 verify 失败，进入正常的 retry / escalate 流程。配合用法：先手动跑一下 P2 的 verify_cmd 确认通过，再 `--from P3`。

可以组合 flag：

```bash
# spec 已经精心 review 过；直接跑但保留状态追踪
/longtask spec.md --skip-gating

# P1 / P2 我手动做完了；从 P3 开干
/longtask spec.md --from P3

# 接昨天的运行；如果状态显示 P3 已 PASS，自动跳到 P4
/longtask spec.md --from P3 --resume
```

---

## 与 Superpowers / GSD / 三栈工作流的关系

`longtask` **不依赖** [Superpowers](https://github.com/obra/superpowers) 或 [GSD (get-shit-done)](https://github.com/gsd-build/get-shit-done)，反过来这两者也不依赖 `longtask`。`longtask` 唯一会主动调用的外部 Claude Code skill 是 [gstack](https://github.com/garrytan/gstack)，且只有当你在 spec 里 opt-in 写了 `gating:` / `ship:` 字段时才调。其他一切都是独立的。

但这四个项目方法论同源，分别占据不同层：

| 层 | 工具 | 解决的问题 |
|---|---|---|
| 决策 / 产品规划 | gstack `/office-hours`、`/plan-ceo-review`、`/plan-eng-review` | "我们要做的是不是对的事？" |
| Spec 切阶段 | GSD `/gsd-discuss-phase`、`/gsd-plan-phase` | "怎么把活切成上下文安全的小块？" |
| 执行纪律 | Superpowers `/test-driven-development`、`/using-git-worktree`、`/subagent-driven-development` | "怎么写代码而不跳过验证？" |
| **Phase 级执行** | **`longtask`**（本 skill） | "把这份 spec 跑出来，每个 phase 都过严格的 A/B 验证。" |
| 收尾发布 | gstack `/ship`、Superpowers `/finishing-development-branch` | "干净地把 PR 提了。" |

`longtask` **内化了**其中两条思想，不调用外部工具：

- **GSD 的"切阶段"** — spec 里已经有 P1 / P2 / P3，每个 phase 拉全新 sub-agent。你不会在 `/longtask` 里再跑 GSD。
- **Superpowers 的"verify-first"纪律** — Codex B 是个严格的、全新上下文的验证者，必须按 `verify_cmd` 判定 artifact。你不会在 `/longtask` 里再跑 Superpowers 的 TDD loop。

`longtask` 真正暴露的整合点显式而最小：只有 `gating:`（P1 之前的决策 skill）和 `ship:`（最后一个 phase 之后的发布）。两者默认关闭。

### 什么时候用什么

- **还没有 spec** → 用 gstack `/office-hours` + `/plan-ceo-review` + `/plan-eng-review`（或 GSD `/gsd-discuss-phase`）把设计想清楚，然后写 `spec.md`。`longtask` 故意不解决"设计还没想清楚"这个阶段。
- **阶段切分不明确** → GSD 的 phase-discussion 流程最合适；把切好的结构落到 `spec.md` 里，再 `/longtask`。
- **spec 已写好、只想执行** → `longtask` 就是执行器。如果设计工作已经在 skill 之外做完，加 `--skip-gating`。
- **想把 gating + shipping 打包成一条命令** → `/longtask spec.md`，spec 里同时写 `gating:` 和 `ship:`。

### 一台机器上四个全装吗？

如果你做绿地产品、想跑 YouTube 演示里那套"Claude-headless + Ralph-Loop"16 阶段流水线 → 装齐 Superpowers + GSD + gstack + `longtask`，覆盖 Think → Plan → Execute → Ship 全弧线。

如果你已经有一套靠谱的工作流、`longtask` 单装就够 → 不必都装。这四套互补但不强依赖，它们在不同 skill 命名空间，触发词不冲突。

---

## 假死防护：idle timeout + verifier 一致性检查

生产环境用了一段时间后，会冒出两种失败模式，提前理解很必要：

**1. Verifier 不一致** — Codex B 偶尔返回 `verdict: "FAIL"` 但 `dod_results[*].passed` 全是 `true`（或者相反）。verdict 和 AC 列表自相矛盾。这几乎总是 `verify_passes_when` 写得不够明确，而不是代码错——下一轮 retry 只会复制同样的矛盾。

Sub-agent 现在在收到 B 的 JSON 之后、信任 verdict 之前先跑一致性检查。任何下列矛盾**立即 ESCALATE**，**不再 spawn retry**：

- `VERIFIER_INCONSISTENT_FAIL_BUT_AC_PASS`
- `VERIFIER_INCONSISTENT_PASS_BUT_AC_FAIL`
- `VERIFIER_MALFORMED_OUTPUT`（`dod_results` 缺失或为空）

升级报告附 B 的完整 JSON，让你直接判断是该收紧 `verify_passes_when`、重写出错的 DoD 条目，还是放宽 `verify_cmd`。

**2. Sub-agent 静默假死** — 两次 Codex CLI 调用之间，sub-agent 跑自己的 Bash + reasoning 步骤。如果没看门狗，一个卡住的 sub-agent 可以静坐一小时——而每次 `codex exec` 自己早已超时退出。新的 `idle_timeout_minutes` 字段（默认 **10**）放了一个**心跳式**看门狗：

- 每个 progress 边界（round 开始、Codex A 开始/完成、Codex B 开始/完成、commit、BLOCKED 返回）都写一个心跳到 `.longtask/state/<spec>.json` 的 `phases.<Pn>.last_heartbeat`，并 append 到 `heartbeats[]` 审计轨迹。
- 每个 round transition 时 sub-agent 检查 `now - last_heartbeat`。超出 `idle_timeout_minutes` → 立刻 `BLOCKED reason="IDLE_TIMEOUT"`，附 heartbeat 尾。
- 这是 **idle 超时，不是硬 wall clock**。只要 sub-agent 持续输出 progress（每个 round transition 一次心跳），计时器就 reset。真正在工作就一直续命；只有真正卡死才被杀。

默认 10 分钟是有意收紧的——长跑的 Codex 本身已经被 10 min stdout-stall 兜底（见 `SKILL.md → ## Codex CLI invocation`，**没有 wall-clock 上限**——只要在出 token 就一直跑），所以两次心跳之间唯一会超过 10 分钟的，就是卡死的 sub-agent。只在确有需要时按 phase override：

```yaml
# spec phase 覆盖
idle_timeout_minutes: 20   # 仅当确实测出合理需要
```

`IDLE_TIMEOUT` 触发时，报告里的 `heartbeats[]` 尾巴会告诉你卡在哪两个事件之间。这一信息基本足够你判断是改 spec 还是直接 `--resume`。

---

## 成本 & 速率限制

- 每个 phase 通常跑 1–3 轮 Codex A↔B；每轮 = 2 次 `codex exec`。
- 一份 5-phase 的中等重构 spec 通常烧 10–30 次 GPT-5.5 xhigh 调用。
- 每个 phase 可设 `cost_budget_usd` 上限（超出后 sub-agent 停下来问你）。
- Codex A / B 都包了 stall-only 杀：内层 `read -t 600`（10 min 无新 stdout 行）→ Exit 142（`STALL_TIMEOUT`）算一次 FAIL。**没有 wall-clock 硬上限**——codex 在出 token 就让它跑（owner 意图："不强杀正在产出的 codex"）。Cost 兜底走 `cost_budget_usd` 软限制。
- Orchestrator 上下文极小（只看 sub-agent 返回值），所以 opus 那一侧的 token 消耗相对 Codex 那侧很少。

如果想压成本，把 `SKILL.md` Codex invocation 段里的 `model_reasoning_effort` 从 `xhigh` 降到 `high` 或 `medium`。

---

## 状态

- 个人在用的 active skill，在生产场景持续迭代。
- 质量底线（写在 `SKILL.md` 里）：**简单胜过聪明 · 度量先于优化 · 小步快跑胜过一锤定音 · 品味是"shippable"的一部分**。
- 公开仓库，但是个人项目 — issues / PR 欢迎，但响应没有 SLA。

---

## License

MIT — 见 [`LICENSE`](LICENSE)。
