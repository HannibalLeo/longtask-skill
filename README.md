# /longtask — Claude × Codex hybrid spec-execution skill (v2)

**简体中文** · [English](README.en.md)

> 多阶段 spec 执行流水线。Claude opus 当 orchestrator，按 owner 四步分工调度 Claude Agent（架构 / 讨论 / 判断 gate / 终验）和 `codex exec` GPT-5.5（写代码、verifier 产 schema JSON）。
>
> 完整契约与字段定义见 [SKILL.md](SKILL.md)。版本历史见 [CHANGELOG.md](CHANGELOG.md)。本文是快速入门。

## 4 production-grade principles（this skill 的工作标准）

灵感来自 [Karpathy 工程风格](https://github.com/forrestchang/andrej-karpathy-skills)，表达方式是这里的：

1. **Simplicity beats cleverness** — 能 grep 一遍就读懂的朴素代码胜过聪明的间接层。能删一层而不丢功能就删；三行相似代码胜过过早抽象。
2. **Evals before optimization** — 不能量化就不能改进。每个 phase 的 `verify_cmd` 让 PASS/FAIL 机械化，"看着对"不算数。
3. **Tight iteration over big leaps** — 三个小步可验证胜过一个"原则上正确"的大跃进。retry 循环为此存在；500 行 diff 才能验的 phase 就是太粗，拆。
4. **Taste is part of "shippable"** — 测试绿不等于可上线。每 phase 结束读一遍 diff。能过的丑代码是下个 phase 的坑；命名、结构、纪律都属于"达标"的一部分。

**Quality bar — non-negotiable**：没有隐藏缺陷、没有用最小补丁糊掉症状。每个决定都为"上线给真用户"服务，不为"测试碰巧绿"服务。

## 一句话

写好 spec → `/longtask <spec_path>` → 主线 session 自动跑完 9+1 步（preflight / classify / **spec-roundtable** / codex-spec-sanity / plan-write / **plan-roundtable** / plan-integrity / per-phase / final-e2e2 / final-alignment），全部 PASS 后可选 `/ship`。

## Owner 四步分工

| 步骤 | 谁干 |
|---|---|
| (a) 架构 | Claude opus —— 输入分类、写 plan、plan-integrity review |
| (b) 讨论 | Claude + Codex 混合 —— roundtable 按 lens 分模型，consensus editor 主审 Claude + 副审 Codex |
| (c) 干活 | Codex GPT-5.5（`codex exec`）—— phase worker 写代码、verifier 产 schema JSON |
| (d) 终验 | Claude opus —— 读 verifier JSON 定 PASS/retry、跑 decision/plan-integrity/final-alignment hybrid gate、final E2E2 截图、docs sync、ship |

不变量：**Codex 写 JSON，Claude 读 JSON**。Claude 主线不读源代码（保 context），但拿最终判断权（保安全）。

## 一份最小 spec 长什么样

```markdown
---
source_spec_path: docs/specs/2026-05-26-healthz-design.md
source_spec_sha256: "<sha256>"
final_verify_cmd: "pytest -q tests/"
final_e2e2_cmd: "gstack browse-e2e --scenarios=docs/CRITICAL_PATH.md --screenshots=.longtask/screenshots/healthz/"
final_report_path: .longtask/reports/healthz/final-report.md
roundtable_mode: hybrid     # 默认；safety-critical 可设 dual
gating: [office-hours, plan-ceo-review, plan-eng-review]   # 可选
ship: true                                                 # 可选
docs_sync: true                                            # 可选
---

# P1: Add /healthz endpoint
goals: Expose `GET /healthz` returning `{"status":"ok"}` with 200 and no auth.
file_scope: [src/routes/health.ts, tests/health.test.ts]
do_not_touch: [src/auth/**, src/db/**]
verify_cmd: "npm test -- tests/health.test.ts"
verify_passes_when: "exit 0 and 0 failures"
max_retry_rounds: 3
source_requirements: [REQ-001]
dod:
  - "GET /healthz returns 200 with {status:ok}"
  - "Existing /auth endpoints unchanged"
  - "OpenAPI spec includes the new path"
```

## 9 步流水线

```
Step 0  Preflight          校验 frontmatter（source_spec_path / sha256 / final_verify_cmd /
                           final_e2e2_cmd / final_report_path 必填）
Step 1  Classifier         Claude Agent → JSON {input_shape, spec_rounds, plan_rounds,
                           required_lenses, risk_reasons, suggested_roundtable_mode}
                           tier 选一档：{0+1, 1+1, 2+1, 3+2}
Step 2  Spec-roundtable    spec_rounds × 5 lens hybrid 讨论 + spec-round-state editor +
                           spec-consensus-editor → enhanced-spec。**0+1 tier 时跳过**
                           （pre-vetted: plan_with_source / self_contained_plan，或
                           source_spec.gating 在同一 session 已跑完 office-hours /
                           plan-ceo-review / plan-eng-review）
Step 3  Codex spec sanity  （**无条件**）codex exec --output-schema 单跑：扫 omissions /
                           hallucinations / internal contradictions / reward-hacking bait
                           → JSON {verdict: CLEAN | NEEDS_REVISION}。Step 2 跳过时尤其
                           重要——这是唯一的跨模型 second opinion
Step 4  Plan-writer        Claude Agent 调 superpowers:writing-plans → plan.md
                           （**multi-agent dispatch**：phase ≥3 时按 phase 并行）
Step 4b Plan-roundtable    plan_rounds × 5 lens hybrid 讨论 implementation plan +
                           plan-round-state editor + plan-consensus-editor（in-place
                           改写 plan.md）。**始终运行**（plan_rounds ≥ 1）——plan 是最终
                           执行契约，必须过一次多 lens 兜底。问题焦点：phase 拆分合理性、
                           verifier 可观测性、跨 phase 依赖、风险面
Step 5  Plan-integrity     HYBRID gate（Claude 主 + Codex 副）→ PASS 或 BLOCKED_SPEC_REWRITE
                           含 textual fidelity check：REQ-* 里的 code block / 签名 /
                           docstring 必须在 plan 的 goals+dod 字面保留
Step 6  Per-phase loop     每 Pn：sub-agent → codex-worker 写代码 → scope gate →
                           codex-verifier 产 schema JSON → Claude 主线 review JSON →
                           commit（docs_sync 在 commit 前自动跑）
Step 7  Final E2E2         Claude Agent 跑 final_verify_cmd + final_e2e2_cmd → 截图
                           → 写 final-report.md；subagent **必须**主动 flag 残余风险
                           给 Step 8（stub 截图、未覆盖 dod 等）
Step 8  Final-alignment    强制 DUAL hybrid（Claude + Codex 都必须跑）→ PASS 或 escalate
Step 9  Ship（可选）       docs_sync → update-docs；ship → gstack /ship
```

## 关键设计决策

| # | 决议 | 实现要点 |
|---|---|---|
| 1 | 保留 PTY workaround | `lib/codex-wrapper.sh` 仍用 `script -q /dev/null` 绕 codex#19945；env `CODEX_LONGTASK_DISABLE_PTY=1` 可临时关 |
| 2 | 默认 hybrid roundtable | spec 可 `roundtable_mode: hybrid \| dual`，**final-alignment-review 强制 dual** 不受 spec 控制（最后一道防线，便宜，只一次）。`claude_only` / `codex_only` 2026-05-26 删除：单模型 roundtable 砍掉 cross-model blindspot 防御，与 roundtable 存在的理由冲突 |
| 3 | known-traps 双层 | (a) `prompts/known-traps-appendix.md` 通用版（worker 拿全文，verifier 拿 checklist 引用）；(b) per-repo 细节走 spec `inject_context.always` |
| 4 | 10 BLOCKED enum | 继承 Codex 6 个 + Claude 新增 4 个（详见 SKILL.md `## BLOCKED enum`）|
| 5 | 两阶段 roundtable + 四档总轮数 | classifier 输出 `(spec_rounds, plan_rounds)` 选一档：**0+1**（pre-vetted） / **1+1**（默认低风险） / **2+1**（中风险，跨模块契约 / 新依赖 / phase ≥4） / **3+2**（高风险，regulatory / clinical / data-loss / security / irreversible-migration，同时强制 `dual`）。**`plan_rounds ≥ 1` 不可降为 0**——plan 是最终执行契约。两阶段都强制 codex + claude 同时在场，任一边 dispatch 失败 → `BLOCKED_*` |
| 6 | Confidence + veto 仲裁 | 两 verdict 一致 → 用；任一方 vetoes[] → ASK_HUMAN；confidence delta>0.15 且选项 local/reversible/inside-spec → 高分胜；否则 ASK_HUMAN。不默认起第三仲裁 |
| 7 | 默认 gpt-5.5/xhigh | `CODEX_LONGTASK_MODEL=gpt-5.5` `CODEX_LONGTASK_REASONING=xhigh`；fallback 到 5.4/high 必须记 `state.model_requests[].model_degraded` |
| 8 | 仓库归属待定 | Claude 端和 Codex 端共用 `HannibalLeo/longtask-skill.git`，push 策略 owner 定 |

## 与 Codex 端的关系

两边同源 `HannibalLeo/longtask-skill.git`。Codex 端（`~/.codex/skills/longtask/`）v0.0.5 用 native Codex subagents 调度，Claude 端用 Claude `Agent` tool + `codex exec`。共享 schema（`schemas/*.schema.json` 跨端 1:1 相同），prompt 在 hybrid 字段上各自定制。

设计 spec：`docs/superpowers/specs/2026-05-26-longtask-claude-parity-design.md`（项目内）。

## 文件清单

```
~/.claude/skills/longtask/
├── SKILL.md                              # 完整契约
├── README.md / README.en.md              # 本文 / 英文版
├── lib/codex-wrapper.sh                  # codex exec 包装（--json --output-schema --cd）
├── lib/smoke.sh                          # 静态 sanity check
├── schemas/{verifier-result,decision-review,plan-integrity-review}.schema.json
└── prompts/                              # 16 个 prompt（详见 SKILL.md `## Prompts and wrapper`）
```

## sanity 自检

```bash
bash ~/.claude/skills/longtask/lib/smoke.sh
# 应输出：3 个 schema OK + bash -n 通过 + usage gate 通过 + 总 FAIL=0
```

## 调用

```bash
# 从项目目录跑
/longtask docs/superpowers/specs/2026-05-26-foo-design.md

# 中途中断后续跑
/longtask docs/superpowers/specs/2026-05-26-foo-design.md --resume
# orchestrator 读 .longtask/state/foo-design.json，从第一个非 PASS phase 重启
# 若 source_spec_sha256 与现文件不符 → BLOCKED_SPEC
```

## 反馈循环

跑完一个 spec 后，看：
1. `.longtask/state/<spec>.json` — `model_requests[]` 看降级率、`agents[]` 看耗时
2. `.longtask/reports/<spec>/final-report.md` — 终验摘要 + 截图
3. `.longtask/reports/<spec>/blocked-*.md`（若有）— 触发 BLOCKED 的 stderr / 复现命令

Spec 设计经验、Codex CLI 已知陷阱见 `prompts/known-traps-appendix.md` 和项目内 `docs/archive/CODEX_PROTOCOL.md`。
