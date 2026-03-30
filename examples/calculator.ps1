#!/usr/bin/env pwsh
# ============================================================================
# Example: Build a calculator with an agent team
#
# This script shows how to use the `team` CLI to set up and launch
# a 3-agent team that designs, implements, and reviews a calculator app.
#
# Prerequisites:
#   - GitHub Copilot CLI installed (`copilot` command available)
#   - Windows Terminal (`wt` command available)
#   - Run install.ps1 first (adds `team` function to your profile)
#
# Usage:
#   cd your-project-directory
#   .\examples\calculator.ps1
# ============================================================================

Write-Host ""
Write-Host "  🚀 Agent Teams — Calculator Example" -ForegroundColor Cyan
Write-Host ""

# 1. Create the team (captures current directory as project_dir)
team init calculator "Build a basic calculator CLI app: add, subtract, multiply, divide. Node.js, with tests."

# 2. Define roles with models and tool permissions
team role calculator architect "Designs the API spec, file structure, and module boundaries" claude-sonnet-4
team role calculator coder "Implements TypeScript code from the architect's spec" claude-sonnet-4
team role calculator reviewer "Reviews implementation for correctness, edge cases, and test coverage"

# 3. Define tasks with dependencies
team task calculator design-spec "Design API spec: functions, CLI interface, file structure, edge cases" architect
team task calculator implement "Implement the calculator based on design-spec" coder design-spec
team task calculator write-tests "Write unit tests for all operations and edge cases" coder design-spec
team task calculator review "Review code and tests for correctness and completeness" reviewer implement,write-tests

# 4. Check the board
team status calculator

# 5. Launch all agents (opens 3 new terminal tabs)
Write-Host ""
Write-Host "  Ready to launch? This will open 3 terminal tabs." -ForegroundColor Yellow
Write-Host "  Press Enter to continue or Ctrl+C to abort." -ForegroundColor Gray
Read-Host

team launch calculator

Write-Host ""
Write-Host "  Agents launched! Monitor progress with:" -ForegroundColor Green
Write-Host "    team status calculator" -ForegroundColor Gray
Write-Host ""
Write-Host "  When done, clean up with:" -ForegroundColor Green
Write-Host "    team clean calculator" -ForegroundColor Gray
Write-Host ""
