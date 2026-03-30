# Contributing to Agent Teams

## Dogfood Rule (NON-NEGOTIABLE)

**All development on this repo MUST use agent-teams itself.**

| Change size | How to develop |
|---|---|
| 1 file, <20 lines (typo, config) | Direct edit, no team needed |
| 1-3 files, clear scope | `team init fix-x "..." bugfix` → `team launch` |
| 4+ files, needs design | `team plan "..."` → `team apply` → `team launch` |
| New feature or template | `team plan "..."` with feasibility check → full pipeline |

If you're tempted to skip agent-teams and "just do it yourself" — that's a signal the tool needs to be easier, not that you should bypass it. File an issue instead.

### Why
- Every real run surfaces bugs and UX gaps
- We catch issues users will hit before they hit them
- The tool improves itself through usage

## Branch Strategy

```
master   ← stable, only merge PRs
develop  ← integration branch
feature/* ← feature branches off develop
```

1. `git checkout -b feature/my-change develop`
2. Use `team plan` / `team launch` to build
3. Run `pwsh -File tests/run-tests.ps1` — all tests must pass
4. Push branch, create PR to develop
5. PR must be reviewed (use `team init pr-review "..." audit` if needed)
6. Merge to develop, then develop → master

## Tests

- Run: `pwsh -File tests/run-tests.ps1`
- All tests must pass before committing
- New templates need test cases in `tests/team.tests.ps1`
- New commands need at least basic happy-path tests

## Filing Issues

- Bugs found during dogfooding → file immediately on GitHub
- Use labels: `bug`, `enhancement`, `v0.x`, `v1.0`
- Include: what happened, expected behavior, repro steps
