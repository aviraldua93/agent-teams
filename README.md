# Agent Teams

**Coordinate multiple GitHub Copilot CLI sessions as a team of specialists.**

Each agent runs in its own terminal tab with a dedicated role, tools, and file ownership. Agents coordinate through shared files — no APIs, no servers, no dependencies. Just PowerShell.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D6)
![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE)
![Version](https://img.shields.io/badge/Version-0.5.0-green)
![GitHub Copilot CLI](https://img.shields.io/badge/GitHub%20Copilot-CLI-8957e5)
[![GitHub Issues](https://img.shields.io/github/issues/aviraldua93/agent-teams)](https://github.com/aviraldua93/agent-teams/issues)
![Zero Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen)

```mermaid
graph LR
    Lead["🧑‍💼 You"] -->|team plan| Plan["📋 Plan"]
    Plan -->|team apply| Team["🏗️ Team"]
    Team -->|team launch| A1["⚙️ Agent 1"]
    Team --> A2["🎨 Agent 2"]
    Team --> A3["🔍 Agent 3"]
    Team --> AN["💻 Agent N"]
    A1 --> FS[".agent-teams/"]
    A2 --> FS
    A3 --> FS
    AN --> FS

    style Lead fill:#4a90d9,color:#fff,stroke:none
    style Plan fill:#6c5ce7,color:#fff,stroke:none
    style Team fill:#00b894,color:#fff,stroke:none
    style FS fill:#2d3436,color:#fff,stroke:#636e72
```

---

## Quick Start

Describe what you want. The planner assesses feasibility, designs roles, and generates a team plan.

```powershell
# From your project directory:
team plan "Build a login page with email/password auth"
```

Three assessors (tech, scope, risk) explore your codebase in parallel, then a synthesizer produces a plan with roles, tasks, acceptance criteria, and a **feasibility verdict** (`go` / `risky` / `no-go`). Review and apply:

```powershell
team apply     # shows the plan, asks for confirmation, creates the team
team launch login-page
```

The orchestrator spawns agents in **waves** — first the roles with no dependencies, waits for them to finish, auto-unblocks downstream tasks, then spawns the next wave. Repeat until done.

Monitor progress from your lead session:

```powershell
team status login-page
```

```
  ╔══════════════════════════════════════════════╗
  ║  Team: login-page                            ║
  ╚══════════════════════════════════════════════╝

  Scenario: Build a login page with email/password auth
  Project:  C:\Users\dev\my-app

  AGENTS
    🟢 architect — active (task: design, 10s ago)
    🔴 coder — no heartbeat
    🟡 reviewer — idle (2m ago)

  TASKS
    ✅ design → architect [done]
    🔄 implement → coder [in_progress]
    🚫 review → reviewer [blocked] (← implement)

  Progress: 1/3 tasks done
```

Or watch it live with auto-refresh:

```powershell
team watch login-page    # refreshes every 3s, Ctrl+C to stop
```

<details>
<summary><b>Manual setup (without planner)</b></summary>

You can also skip the planner and use templates directly:

```powershell
team init login-page "Build a login page with email/password auth" feature
team launch login-page
```

</details>

---

## Why?

A single Copilot CLI session handles small tasks well. Bigger work needs parallel specialists.

| | Single Session | Agent Teams |
|---|---|---|
| **Scope** | One conversation, one context | Multiple specialists, isolated contexts |
| **Parallelism** | Sequential (design → code → review) | Parallel tabs, dependency-aware tasks |
| **Coordination** | Copy-paste between windows | Automatic via shared files + protocol |
| **Monitoring** | Check each tab manually | `team status` dashboard with heartbeats |
| **Reproducibility** | Ad-hoc prompts | Role files + task definitions = repeatable |

---

## Install

```powershell
git clone https://github.com/aviraldua93/agent-teams.git
cd agent-teams
.\install.ps1    # copies to ~/.agent-teams/, adds `team` to your profile
```

Restart your terminal (or `. $PROFILE`).

**Requirements:** [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli) (`copilot`), [Windows Terminal](https://aka.ms/terminal) (`wt`), PowerShell 7+ (`pwsh`).

---

## 📋 Templates

Eight preset templates so you don't have to define roles and tasks from scratch.

| Template | Roles | Tasks | Use Case |
|----------|-------|-------|----------|
| **`feature`** | architect, coder, reviewer | design → implement → review | Standard feature development |
| **`fullstack`** | architect, backend, frontend, reviewer | design → backend + frontend → review | Full-stack features spanning API + UI |
| **`sprint`** | pm, architect, coder, qa, reviewer | scope → design → implement → QA + review | Full sprint team with PM and QA |
| **`bugfix`** | investigator, fixer, reviewer | investigate → fix → review | Bug investigation and patching |
| **`refactor`** | explorer, refactorer, tester, reviewer | map → refactor → test → review | Safe codebase refactoring |
| **`research`** | researcher ×3, synthesizer | research ×3 → synthesize | Parallel investigation with synthesis |
| **`ship`** | release-manager, qa, reviewer | QA + review → ship | Release workflow with QA gate |
| **`audit`** | security, perf, quality, synthesizer | 3 parallel audits → synthesize | Parallel code audit with prioritized findings |

```powershell
team init auth-flow "Add OAuth2 login flow" feature
team init flaky-tests "Tests failing intermittently on CI" bugfix
team init api-redesign "Migrate REST endpoints to v2 schema" refactor
team init framework-eval "Evaluate React vs Svelte vs Solid" research
team init dashboard "Build analytics dashboard with API" fullstack
team init v2-release "Ship v2.0 to production" ship
team init q4-sprint "Q4 feature: user notifications" sprint
team init security-review "Audit before SOC2 compliance" audit
```

<details>
<summary><b>📊 Template flow diagrams</b> (click to expand)</summary>

#### feature
```mermaid
graph LR
    A["🏗️ Architect"] --> C["💻 Coder"] --> R["🔍 Reviewer"]
```

#### fullstack
```mermaid
graph LR
    A["🏗️ Architect"] --> B["⚙️ Backend"]
    A --> F["🎨 Frontend"]
    B --> R["🔍 Reviewer"]
    F --> R
```

#### sprint
```mermaid
graph LR
    PM["📋 PM"] --> A["🏗️ Architect"] --> C["💻 Coder"]
    C --> QA["🧪 QA"]
    C --> R["🔍 Reviewer"]
```

#### audit
```mermaid
graph LR
    S["🔒 Security"] --> Syn["📊 Synthesizer"]
    P["⚡ Performance"] --> Syn
    Q["📏 Quality"] --> Syn
```

#### research
```mermaid
graph LR
    R1["🔍 Researcher 1"] --> Syn["📊 Synthesizer"]
    R2["🔍 Researcher 2"] --> Syn
    R3["🔍 Researcher 3"] --> Syn
```

#### ship
```mermaid
graph LR
    QA["🧪 QA"] --> RM["📦 Release Manager"]
    R["🔍 Reviewer"] --> RM
```

#### bugfix
```mermaid
graph LR
    I["🔎 Investigator"] --> F["🔧 Fixer"] --> R["🔍 Reviewer"]
```

#### refactor
```mermaid
graph LR
    E["🗺️ Explorer"] --> C["💻 Coder"]
    E --> T["🧪 Tester"]
    C --> R["🔍 Reviewer"]
    T --> R
```

</details>

Templates are JSON files in `templates/presets/`. Create your own or edit the built-ins.

---

## ⚙️ How It Works

### Team Directory Structure

```
.agent-teams/{name}/
├── manifest.json        # Team config: roles, project dir, scenario
├── protocol.md          # Coordination rules every agent reads on startup
├── tasks.json           # Shared task board with dependencies
├── roles/               # Per-role Markdown files (YAML frontmatter)
│   ├── architect.md
│   ├── coder.md
│   └── reviewer.md
├── artifacts/           # Deliverables (each role owns specific files)
├── mailbox/             # Append-only message files (inter-agent messaging)
│   └── lead.inbox       # Activity log for the lead
├── heartbeat/           # Per-agent liveness signals (JSON)
├── logs/                # Session output (via Start-Transcript)
└── .launch/             # Generated prompts + launcher scripts
```

### Coordination Flow

1. `team plan` spawns 3 assessors in parallel (tech, scope, risk), waits for all to finish, then spawns a synthesizer that produces `proposed-plan.json` with a feasibility gate (`go` / `risky` / `no-go`), roles, tasks, and acceptance criteria
2. `team apply` shows the plan for review and creates the team (roles, tasks, acceptance criteria)
3. `team init` (alternative) scaffolds the team directory from a template or manually
4. `team launch` runs a **wave-based orchestrator**: finds roles with pending tasks → spawns them in parallel → waits for completion using **3-probe detection** (`.done` signal file → task evidence in `tasks.json` → heartbeat liveness) → runs `unblock` to transition blocked tasks → spawns next wave
5. Each agent reads `protocol.md` → `roles/{key}.md` → `tasks.json`
6. Agents claim tasks, write deliverables to `artifacts/`, message via `mailbox/`
7. Agents update `heartbeat/{key}.json` so the lead can monitor liveness
8. Lead runs `team status` or `team watch` to see the dashboard

### Mailbox Protocol

Agents communicate through append-only inbox files. Messages are never deleted or edited.

```
[2025-07-17T10:32:00Z] architect → lead
Design spec written to artifacts/design.md. Ready for implementation.
---
```

### Heartbeat Monitoring

Each agent maintains a `heartbeat/{key}.json` file with its current status, active task, and last-active timestamp. The `team status` dashboard reads these to show 🟢 active, 🟡 idle, or 🔴 unresponsive agents.

---

## 📝 Role Files

Each role gets a Markdown file with YAML frontmatter defining its scope, tool permissions, and file ownership. Inspired by [gstack](https://github.com/nichochar/gstack)'s SKILL.md pattern.

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
You are the Architect. Your job is to explore the codebase,
design the spec, and write it to artifacts/design.md.
```

Edit `roles/{key}.md` to customize instructions, tool permissions, and sub-agent policies per role.

### Two-Tier Agent Architecture

Each team session can spawn its own sub-agents internally. Max depth = 2.

```
Lead (your session)
├── Team Session: Architect  → spawns explore sub-agents
├── Team Session: Coder      → spawns explore + task + general-purpose sub-agents
└── Team Session: Reviewer   → spawns explore + code-review sub-agents
```

---

## 🛠️ Commands

| Command | Description |
|---------|-------------|
| `team plan <scenario> [template-seed]` | AI-generate a team plan (3 assessors → synthesizer) |
| `team apply` | Review and create a team from the proposed plan |
| `team init <name> <scenario> [template]` | Create a team (optionally from a preset template) |
| `team role <name> <key> <desc> [model]` | Add a role manually (generates role file) |
| `team task <name> <id> <title> <role> [deps]` | Add a task (deps: comma-separated task IDs) |
| `team launch <name>` | Orchestrate: spawn waves, wait for completion, unblock, repeat |
| `team launch <name> <role>` | Spawn a single role (manual, non-blocking) |
| `team unblock <name>` | Transition blocked tasks to pending when deps are met |
| `team status <name>` | Dashboard with heartbeats and task progress |
| `team watch <name>` | Live auto-refreshing dashboard (3s interval) |
| `team list` | List all teams |
| `team clean <name>` | Remove a team and its directory |

### Manual Setup (Without Templates or Planner)

```powershell
team init calculator "Build a calculator CLI"

team role calculator architect "Designs the spec and file structure" claude-sonnet-4
team role calculator coder "Implements code from spec" claude-sonnet-4
team role calculator reviewer "Reviews for correctness and edge cases"

team task calculator design "Design the architecture" architect
team task calculator implement "Build the code" coder design
team task calculator review "Review the implementation" reviewer implement

team launch calculator
```

---

## 🧭 Design Principles

From the [Multi-Agent Playbook](https://github.com/aviraldua93/multi-agent-playbook):

1. **Docs-as-Bus** — Agents coordinate through files, not messages passed through an orchestrator. The filesystem IS the shared memory.
2. **File Ownership** — Each role owns specific files. No two agents write to the same file. Ever.
3. **Append-Only Mailbox** — Messages are never deleted or edited. Consistency without locks.
4. **Max 3 Deliverables** — No agent has more than 3 tasks. Split the work if needed.
5. **Wave Ordering** — Explore → Implement → Review → Validate → Ship.

### Auto-Filed Issues

Agents are instructed to auto-file GitHub issues on [`aviraldua93/agent-teams`](https://github.com/aviraldua93/agent-teams) when they encounter coordination system bugs (task corruption, heartbeat failures, mailbox conflicts). This dogfoods the tool and surfaces real-world edge cases.

### Known Limitations

- **Orchestrated mode uses `-p` (plain output).** When `team launch` runs the full orchestrator, agents are spawned with `copilot -p` (non-interactive) so the process exits on completion and triggers the `.done` signal file. Single-role launch (`team launch <name> <role>`) uses `-i` (interactive TUI) instead.

---

## 🗺️ Roadmap

- [x] `team watch` — live auto-refreshing dashboard
- [x] Role preset templates (feature, bugfix, refactor, research, fullstack, sprint, ship, audit)
- [x] Heartbeat liveness monitoring
- [x] Session logging via `Start-Transcript`
- [x] Mailbox-based inter-agent messaging
- [x] YAML frontmatter role files with tool permissions
- [x] `team plan` / `team apply` — AI-generated planning with 3 assessors + synthesizer
- [x] Feasibility gate (go / risky / no-go) with confidence scoring
- [x] Acceptance criteria on tasks (sprint contracts)
- [x] `team unblock` — auto-transition blocked tasks when deps complete
- [x] Wave-based orchestrator with 3-probe completion detection
- [x] Signal-based blocking for `team plan` and `team launch`
- [ ] TUI for orchestrated mode ([#10](https://github.com/aviraldua93/agent-teams/issues/10))
- [ ] Data science templates ([#11](https://github.com/aviraldua93/agent-teams/issues/11))
- [ ] File locking ([#12](https://github.com/aviraldua93/agent-teams/issues/12))
- [ ] Cross-platform support (Bun rewrite → single binary for Windows/macOS/Linux)
- [ ] Web dashboard — browser-based live monitoring
- [ ] Integration with [Conductor](https://github.com/microsoft/conductor) workflows

---

## Inspired By

- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams) — the concept of coordinated agent sessions
- [gstack](https://github.com/nichochar/gstack) — SKILL.md pattern for role definitions with YAML frontmatter
- [Multi-Agent Playbook](https://github.com/aviraldua93/multi-agent-playbook) — the coordination patterns (docs-as-bus, file ownership, wave ordering)

---

## License

MIT — see [LICENSE](LICENSE) for details.
