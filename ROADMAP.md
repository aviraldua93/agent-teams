# Agent Teams — Roadmap

## Where We Are

**v0.5** (current) — Working CLI with wave orchestration, 13 templates, 3-probe failure detection, feasibility assessment, 43 unit tests, CI pipeline. Three successful E2E runs (calculator ×2, iris ML).

**15/22 issues closed.** Core infrastructure is solid. Missing: feedback loops, structured grading, context handoffs, cross-platform.

---

## v0.6 — Polish & Harden (next)

**Theme:** Close v0.x gaps, make existing features production-quality.

| # | Item | Issue | Effort |
|---|------|-------|--------|
| 1 | Richer role file templates with deliverable format guidance | #5 | Small |
| 2 | Dependency unblock notifications via role inbox | #6 | Small |
| 3 | `.done` signal reliability — investigate why `-p` mode doesn't trigger consistently | — | Medium |
| 4 | `team reset <name> <task-id>` — manual task state reset command | — | Small |
| 5 | Install: one-liner remote install (`irm | iex`) without cloning | — | Small |

**Exit criteria:** All v0.x issues closed. `.done` signals work reliably OR evidence-based recovery is documented as the primary path.

---

## v0.7 — Generator ↔ Evaluator Loop (the big one)

**Theme:** The single highest-value change from Anthropic's harness research. Turns linear pipelines into iterative refinement cycles.

| # | Item | Issue | Effort |
|---|------|-------|--------|
| 1 | Review feedback loop — reviewer creates fix tasks, orchestrator runs another wave | #21 | Medium |
| 2 | Structured grading criteria with hard thresholds in tasks.json | NEW | Medium |
| 3 | Max iteration limit per loop (default 3) to prevent infinite cycles | — | Small |
| 4 | Pivot-or-refine decision — coder prompted to iterate or try different approach | NEW | Small |

**Completed (moved from planned):**
- ✅ `harness` template — planner → generator ↔ evaluator (loop with grading)
- ✅ `doc-review` template — 4 parallel reviews → synthesize

**Exit criteria:** Review feedback loop works end-to-end. Evaluator grades against criteria, generator fixes until thresholds pass.

---

## v0.8 — Context Engineering

**Theme:** Handle long-running tasks that exceed context limits. Enable multi-hour autonomous work.

| # | Item | Issue | Effort |
|---|------|-------|--------|
| 1 | Checkpoint + handoff protocol — agent writes structured state file, fresh agent resumes | NEW | Large |
| 2 | Automatic context reset detection (agent self-detects context pressure) | NEW | Medium |
| 3 | `team resume <name>` — restart from last checkpoint | NEW | Medium |
| 4 | Handoff artifact format specification | NEW | Small |

**Exit criteria:** An agent that hits context limits gracefully checkpoints and a fresh session picks up from where it left off.

---

## v0.9 — Smart Planning

**Theme:** Planner composes teams from a role library, not fixed templates. Adapts to the actual codebase.

| # | Item | Issue | Effort |
|---|------|-------|--------|
| 1 | Role library — 30+ reusable `.role.md` files with full instructions | #19 | Large |
| 2 | Planner picks roles from library + adapts to codebase | #19 | Medium |
| 3 | `prd` template — user-researcher + pm + spec-writer + tech-reviewer + stakeholder-sim | NEW | Small |
| 4 | `incident` template — incident-commander + investigator + fixer + comms-writer | NEW | Small |
| 5 | Interface contracts for cross-boundary file access | #20 | Medium |

**Exit criteria:** `team plan "Build X"` composes a custom team from the role library based on codebase analysis. Templates are shortcuts, roles are atoms.

---

## v1.0 — Production Grade

**Theme:** Cross-platform, file safety, live testing, ready for real teams.

| # | Item | Issue | Effort |
|---|------|-------|--------|
| 1 | Bun rewrite — single binary, cross-platform (macOS/Linux/Windows) | NEW | XL |
| 2 | File locking for concurrent agent writes | #12 | Large |
| 3 | Rich TUI for orchestrated mode (pending Copilot CLI `--auto-exit` support) | #10 | Blocked |
| 4 | Playwright-based QA role (start dev server, navigate, screenshot, file bugs) | NEW | Large |
| 5 | Web dashboard — browser-based live monitoring (FastAPI/Bun.serve + WebSocket) | NEW | Large |
| 6 | Cost tracking — token usage per agent, per wave, per team | NEW | Medium |
| 7 | Branch-per-agent isolation (git worktrees) | NEW | Large |

**Exit criteria:** Install with `brew install agent-teams` or `npm install -g agent-teams`. Works on macOS and Linux. File-safe concurrent writes. Live QA testing.

---

## Principles

1. **Each version ships and works.** No half-done features. Every release is usable.
2. **Dogfood everything.** Use agent-teams to build agent-teams from v0.7 onward.
3. **Issues before code.** File the issue, design in the issue, then build.
4. **Branch discipline.** Feature branches → develop → master. PRs reviewed.
5. **Test everything.** Unit tests for CLI, E2E simulation for each template.

---

## Timeline

No dates — milestone-driven. Each version ships when exit criteria are met.

```
v0.6  →  v0.7  →  v0.8  →  v0.9  →  v1.0
polish   loops   context  planning  production
```
