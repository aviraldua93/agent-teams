#!/usr/bin/env pwsh
# Run all Pester tests
$ErrorActionPreference = "Stop"

# Ensure Pester v5+
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]"5.0.0" })) {
    Write-Host "Installing Pester v5..." -ForegroundColor Yellow
    Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
}

Import-Module Pester -MinimumVersion 5.0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Output.Verbosity = "Detailed"
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot "test-results.xml"

Invoke-Pester -Configuration $config
