# Agent Teams

Coordinate multiple [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli) sessions as a team. Each session runs in its own terminal tab with a role-specific prompt. Agents coordinate through shared files — no APIs, no frameworks, just the filesystem.

```
You (Lead Session)
├── Tab 2: Architect  → explores codebase, writes spec
├── Tab 3: Coder      → implements from spec, runs tests
├── Tab 4: Reviewer   → reviews code, flags issues
```

## Why

A single Copilot CLI session works great for small tasks. But for larger work — multi-layer features, parallel research, competing hypotheses — you want multiple specialists working in parallel. Agent Teams gives you that with zero infrastructure.

**Inspired by** [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams) and [gstack](https://github.com/nichochar/gstack)'s SKILL.md pattern.

## Install

```powershell
git clone https://github.com/aviraldua93/agent-teams.git
cd agent-teams
.\install.ps1    # copies to ~/.agent-teams/, adds `team` to your profile
```

Then restart your terminal (or `. $PROFILE`).

## Quick Start

```powershell
# 1. Create a team (run from your project directory)
team init calculator "Build a calculator CLI: add, subtract, multiply, divide"

# 2. Add roles
team role calculator architect "Designs the API spec and file structure" claude-sonnet-4
team role calculator coder "Implements TypeScript code from spec" claude-sonnet-4
team role calculator reviewer "Reviews for correctness and edge cases"

# 3. Add tasks (with dependencies)
team task calculator design "Design the architecture" architect
team task calculator implement "Build the code" coder design
team task calculator review "Review the implementation" reviewer implement

# 4. Launch — opens terminal tabs, agents start working
team launch calculator

# 5. Monitor progress
team status calculator
```

## How It Works

### Architecture

```
.agent-teams/{name}/
├── manifest.json        # Team config: roles, project dir, scenario
├── protocol.md          # Rules every agent reads on startup
├── tasks.json           # Shared task board with dependencies
├── roles/               # Per-role Markdown files (instructions + permissions)
│   ├── architect.md
│   ├── coder.md
│   └── reviewer.md
├── artifacts/           # Deliverables (each role owns specific files)
├── mailbox/             # Append-only message files
│   └── lead.inbox       # Activity log for the lead
├── heartbeat/           # Per-agent liveness signals
│   ├── architect.json
│   └── coder.json
├── logs/                # Session output (piped via Tee-Object)
└── .launch/             # Generated prompts + launcher scripts
```

### Coordination Protocol

1. **Lead** creates the team, defines roles and tasks
2. **`team launch`** opens a terminal tab per role, each running `copilot -i "..."` with:
   - A role-specific prompt pointing to `protocol.md` and `roles/{key}.md`
   - `--add-dir` for the team directory
   - `--model` if specified
   - Output piped to `logs/{key}.log`
3. Each agent reads `protocol.md` → `roles/{key}.md` → `tasks.json`
4. Agents claim tasks, write deliverables to `artifacts/`, message via `mailbox/`
5. Agents update `heartbeat/{key}.json` so the lead can monitor liveness
6. Lead runs `team status` to see the dashboard

### Role Files

Each role gets a Markdown file with YAML frontmatter (inspired by gstack's SKILL.md):

```yaml
---
name: Architect
key: architect
description: Designs the API spec
model: claude-sonnet-4
allowed_tools:
  - Read
  - glob
  - grep
  - explore
owns_files:
  - artifacts/design.md
reads_from:
  - tasks.json
  - protocol.md
---

## Instructions
You are the Architect. Your job is to...
```

Edit `roles/{key}.md` to customize instructions, tool permissions, and sub-agent policies per role.

### Two-Tier Agent Architecture

Each team session can spawn its own sub-agents internally:

```
Lead (your session)
├── Team Session: Architect  → spawns explore sub-agents
├── Team Session: Coder      → spawns explore + task + general-purpose sub-agents
└── Team Session: Reviewer   → spawns explore + code-review sub-agents
```

**Max depth = 2.** Lead → Session → Sub-agents. Sub-agents cannot spawn sub-agents.

| Role | explore | general-purpose | task | code-review |
|------|---------|----------------|------|-------------|
| Architect | ✅ Heavy | ❌ | ✅ Light | ❌ |
| Coder | ✅ Moderate | ✅ 1/file | ✅ Heavy | ❌ |
| Reviewer | ✅ Moderate | ❌ | ✅ Light | ✅ Heavy |

## Commands

| Command | Description |
|---------|-------------|
| `team init <name> <scenario>` | Create a new team |
| `team role <name> <key> <desc> [model]` | Add a role (generates role file) |
| `team task <name> <id> <title> <role> [deps]` | Add a task (deps: comma-separated) |
| `team launch <name> [role]` | Spawn agent tabs |
| `team status <name>` | Dashboard with heartbeats |
| `team list` | List all teams |
| `team clean <name>` | Remove a team |

## Requirements

- [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli) (`copilot` command)
- [Windows Terminal](https://aka.ms/terminal) (`wt` command)
- PowerShell 7+ (`pwsh`)

## Design Principles

From the [Multi-Agent Playbook](https://github.com/aviraldua93/multi-agent-playbook):

1. **Docs-as-Bus** — Agents coordinate through files, not messages. The filesystem IS the shared memory.
2. **File Ownership** — Each role owns specific files. No two agents write to the same file.
3. **Append-Only Mailbox** — Messages are never deleted or edited.
4. **Max 3 Deliverables** — No agent has more than 3 tasks. Split if needed.
5. **Wave Ordering** — Explore → Implement → Review → Validate → Ship.

## Roadmap

- [ ] Cross-platform support (Bun rewrite → single binary)
- [ ] `team watch` — live tail of all agent logs
- [ ] `team unblock` — auto-transition blocked tasks when deps complete
- [ ] Role presets (architect, coder, reviewer, tester)
- [ ] Integration with [Conductor](https://github.com/microsoft/conductor) workflows

## License

MIT
