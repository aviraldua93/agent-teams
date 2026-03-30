#!/usr/bin/env pwsh
# ============================================================================
# install.ps1 — Install Agent Teams for GitHub Copilot CLI
#
# What this does:
#   1. Copies team.ps1 + templates to ~/.agent-teams/
#   2. Adds the `team` function to your PowerShell profile
#
# Usage:
#   .\install.ps1
#
# To uninstall:
#   Remove the `team` function line from your PowerShell profile
#   Remove ~/.agent-teams/ directory
# ============================================================================

$ErrorActionPreference = "Stop"

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir = Join-Path $env:USERPROFILE ".agent-teams"
$TemplatesTarget = Join-Path $TargetDir "templates"

Write-Host ""
Write-Host "  Agent Teams — Installer" -ForegroundColor Cyan
Write-Host ""

# 1. Copy files
Write-Host "  📁 Installing to $TargetDir" -ForegroundColor White
New-Item -ItemType Directory -Force -Path $TemplatesTarget | Out-Null

Copy-Item (Join-Path $SourceDir "team.ps1") $TargetDir -Force
Copy-Item (Join-Path $SourceDir "templates\protocol.md") $TemplatesTarget -Force
Copy-Item (Join-Path $SourceDir "templates\role.md") $TemplatesTarget -Force

Write-Host "     ✅ team.ps1" -ForegroundColor Green
Write-Host "     ✅ templates/protocol.md" -ForegroundColor Green
Write-Host "     ✅ templates/role.md" -ForegroundColor Green

# 2. Add to PowerShell profile
# Always write to $PROFILE (CurrentUserCurrentHost) — this is what `. $PROFILE` loads
$profilePath = $PROFILE
$parentDir = Split-Path $profilePath -Parent
if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Force -Path $parentDir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }
$aliasLine = 'function team { & "$env:USERPROFILE\.agent-teams\team.ps1" @args }'
$marker = "# Agent Teams CLI"

if (Test-Path $profilePath) {
    $profileContent = Get-Content $profilePath -Raw -Encoding UTF8
} else {
    $profileContent = ""
    New-Item -ItemType File -Force -Path $profilePath | Out-Null
}

if ($profileContent -match "Agent Teams CLI") {
    Write-Host "  ⏭️  Profile alias already exists — updating" -ForegroundColor Yellow
    $profileContent = $profileContent -replace '(?m)^# Agent Teams CLI\r?\nfunction team \{[^\}]+\}', "$marker`n$aliasLine"
    Set-Content $profilePath $profileContent -Encoding UTF8
} else {
    $addition = "`n$marker`n$aliasLine`n"
    Add-Content $profilePath $addition -Encoding UTF8
    Write-Host "  ✅ Added 'team' function to $profilePath" -ForegroundColor Green
}

Write-Host ""
Write-Host "  ✅ Installed!" -ForegroundColor Green
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "    1. Restart your terminal (or run:  . `$PROFILE )" -ForegroundColor White
Write-Host "    2. cd into your project directory" -ForegroundColor White
Write-Host "    3. Run:" -ForegroundColor White
Write-Host ""
Write-Host '       team init my-feature "Build feature X with tests"' -ForegroundColor Cyan
Write-Host '       team role my-feature architect "Designs the spec"' -ForegroundColor Cyan
Write-Host '       team role my-feature coder "Implements the code" claude-sonnet-4' -ForegroundColor Cyan
Write-Host '       team role my-feature reviewer "Reviews for correctness"' -ForegroundColor Cyan
Write-Host '       team task my-feature design "Design the architecture" architect' -ForegroundColor Cyan
Write-Host '       team task my-feature implement "Build it" coder design' -ForegroundColor Cyan
Write-Host '       team task my-feature review "Review it" reviewer implement' -ForegroundColor Cyan
Write-Host '       team launch my-feature' -ForegroundColor Cyan
Write-Host ""
Write-Host "  This opens 3 terminal tabs — one per agent — all working in parallel." -ForegroundColor Gray
Write-Host "  Monitor with:  team status my-feature" -ForegroundColor Gray
Write-Host ""
