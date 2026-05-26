# longtask-skill — Claude Code plugin

Multi-phase spec execution pipeline for Claude Code. **Claude opus** orchestrator + **Codex GPT-5.5** worker/verifier via `codex exec`, with hybrid Claude+Codex judgment gates and two-stage roundtable (spec + plan).

Distributed as a Claude Code plugin with **three skills**:

| Skill | What it does |
|---|---|
| `longtask:longtask` | Full pipeline — preflight → classify → spec-roundtable → codex sanity → plan-writer → plan-roundtable → plan-integrity → per-phase loop → final E2E2 → final-alignment → optional ship |
| `longtask:longtaskPlan` | Steps 0-5 only — spec to validated plan, stop at plan-integrity PASS |
| `longtask:longtaskCode` | Steps 6-9 only — execute a validated plan to shipped code |

## Install

This repo is a self-hosting Claude Code marketplace (the `.claude-plugin/marketplace.json` at root registers a marketplace whose one plugin lives in `plugin/`).

```text
# Add this repo as a marketplace
/plugin marketplace add HannibalLeo/longtask-skill

# Install the longtask plugin from it
/plugin install longtask@longtask-skill
```

After install the three skills appear in Claude Code's skill list as `longtask:longtask`, `longtask:longtaskPlan`, `longtask:longtaskCode`. Plugin contents land in `~/.claude/plugins/cache/longtask-skill/longtask/<version>/`.

## Update

```text
/plugin marketplace update longtask-skill
/plugin update longtask@longtask-skill
```

## Repo layout

```
longtask-skill/
├── .claude-plugin/
│   └── marketplace.json          # marketplace manifest (registers this repo)
├── plugin/                       # the actual plugin payload
│   ├── package.json              # plugin manifest
│   ├── README.md                 # plugin user guide (read this for usage)
│   ├── README.en.md              # English version
│   ├── CHANGELOG.md              # version history
│   ├── VERSION
│   ├── skills/
│   │   ├── longtask/SKILL.md          # full pipeline (Steps 0-9)
│   │   ├── longtaskPlan/SKILL.md      # subset — Steps 0-5 only
│   │   └── longtaskCode/SKILL.md      # subset — Steps 6-9 only
│   ├── prompts/                  # 17 prompt templates shared across the 3 skills
│   ├── schemas/                  # 5 JSON Schemas for structured codex output
│   └── lib/                      # codex-wrapper.sh + smoke.sh
├── LICENSE
└── README.md                     # this file (GitHub landing page)
```

## Documentation

- **Plugin user guide**: [plugin/README.md](plugin/README.md) (Chinese, primary), [plugin/README.en.md](plugin/README.en.md) (English)
- **Full contract** of the orchestrator: [plugin/skills/longtask/SKILL.md](plugin/skills/longtask/SKILL.md)
- **Sub-skill contracts**: [longtaskPlan](plugin/skills/longtaskPlan/SKILL.md) / [longtaskCode](plugin/skills/longtaskCode/SKILL.md)
- **Version history**: [plugin/CHANGELOG.md](plugin/CHANGELOG.md)

## Companion: Codex-end

This is the **Claude end** of a two-end skill family. The **Codex end** (`~/.codex/skills/longtask/`) lives at a separate repo and uses Codex native subagents instead of Claude Agent + `codex exec`. The two ends share JSON schemas byte-for-byte; prompts diverge only on hybrid wiring.

## License

See [LICENSE](LICENSE).
