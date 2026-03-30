#!/usr/bin/env pwsh
# ============================================================================
# team.ps1 — Agent Teams for GitHub Copilot CLI
# Version: 0.5.0
#
# Coordinates multiple Copilot CLI sessions as specialized agents.
# Each agent runs in its own terminal tab with a role-specific prompt,
# role files (Markdown w/ YAML frontmatter), heartbeat monitoring,
# session logs, and tool permissions.
#
# Coordination happens through shared files (docs-as-bus pattern).
#
# Usage: team <command> [arguments]
# Run without arguments for help.
# ============================================================================

$ErrorActionPreference = "Stop"
$ToolRoot = Join-Path $env:USERPROFILE ".agent-teams"
$TemplatesDir = Join-Path $ToolRoot "templates"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Helpers ─────────────────────────────────────────────────────────────────

function Get-TeamDir([string]$teamName) {
    # Team data is PROJECT-LOCAL: .agent-teams/{name}/ in the current directory
    return Join-Path (Get-Location).Path ".agent-teams\$teamName"
}

function Get-AllTeamDirs {
    # Scan .agent-teams/ in current directory for team subdirs
    $base = Join-Path (Get-Location).Path ".agent-teams"
    if (Test-Path $base) {
        return Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") }
    }
    return @()
}

function Assert-TeamExists([string]$teamName) {
    $dir = Get-TeamDir $teamName
    if (-not (Test-Path $dir)) {
        Write-Host "  Error: Team '$teamName' not found." -ForegroundColor Red
        Write-Host "  Run: team init $teamName `"<scenario>`"" -ForegroundColor Gray
        exit 1
    }
}

function Read-Json([string]$path) {
    return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Json([string]$path, $obj) {
    $tmp = "$path.tmp"
    $obj | ConvertTo-Json -Depth 10 | Set-Content $tmp -Encoding UTF8
    if (Test-Path $path) { Remove-Item $path -Force }
    Move-Item $tmp $path -Force
}

function Get-Manifest([string]$teamName) {
    return Read-Json (Join-Path (Get-TeamDir $teamName) "manifest.json")
}

function Save-Manifest([string]$teamName, $manifest) {
    Write-Json (Join-Path (Get-TeamDir $teamName) "manifest.json") $manifest
}

function Get-Tasks([string]$teamName) {
    return Read-Json (Join-Path (Get-TeamDir $teamName) "tasks.json")
}

function Save-Tasks([string]$teamName, $tasks) {
    Write-Json (Join-Path (Get-TeamDir $teamName) "tasks.json") $tasks
}

# Parse YAML frontmatter from a role Markdown file.
# Returns a hashtable of the frontmatter keys. Handles simple scalar values
# and arrays denoted by "  - item" lines. Stops at the closing "---".
function Read-RoleFrontmatter([string]$path) {
    $lines = Get-Content $path -Encoding UTF8
    $meta = [ordered]@{}
    $inFrontmatter = $false
    $currentKey = $null
    $currentList = $null

    foreach ($line in $lines) {
        # Detect frontmatter boundaries
        if ($line -match '^---\s*$') {
            if ($inFrontmatter) {
                # Flush any pending list
                if ($null -ne $currentKey -and $null -ne $currentList) {
                    $meta[$currentKey] = $currentList
                }
                break  # end of frontmatter
            }
            $inFrontmatter = $true
            continue
        }
        if (-not $inFrontmatter) { continue }

        # Array item: "  - value"
        if ($line -match '^\s+-\s+(.+)$') {
            if ($null -eq $currentList) { $currentList = @() }
            $currentList += $Matches[1].Trim()
            continue
        }

        # Key: value pair
        if ($line -match '^(\w[\w_]*):\s*(.*)$') {
            # Flush previous list if any
            if ($null -ne $currentKey -and $null -ne $currentList) {
                $meta[$currentKey] = $currentList
            }
            $currentKey = $Matches[1]
            $value = $Matches[2].Trim()
            $currentList = $null

            if ($value -ne '') {
                $meta[$currentKey] = $value
                $currentKey = $null   # scalar — no list to collect
            }
            # If value is empty, next lines may be array items
        }
    }
    return $meta
}

# Read the body (everything after the second "---") of a role file.
function Read-RoleBody([string]$path) {
    $raw = Get-Content $path -Raw -Encoding UTF8
    # Match everything after the second "---" line
    if ($raw -match '(?s)^---.*?---\r?\n(.+)$') {
        return $Matches[1].Trim()
    }
    return ""
}

# Format a relative timestamp from an ISO-8601 string.
function Format-TimeAgo([string]$isoTime) {
    try {
        $ts = [DateTimeOffset]::Parse($isoTime)
        $delta = [DateTimeOffset]::UtcNow - $ts
        if ($delta.TotalSeconds -lt 60)  { return "$([math]::Floor($delta.TotalSeconds))s ago" }
        if ($delta.TotalMinutes -lt 60)  { return "$([math]::Floor($delta.TotalMinutes))m ago" }
        if ($delta.TotalHours   -lt 24)  { return "$([math]::Floor($delta.TotalHours))h ago" }
        return "$([math]::Floor($delta.TotalDays))d ago"
    } catch {
        return "unknown"
    }
}

# ── Commands ────────────────────────────────────────────────────────────────

# ── init ────────────────────────────────────────────────────────────────────
# Creates the team directory scaffold with all v0.2 directories:
#   artifacts/, mailbox/, .launch/, roles/, heartbeat/, logs/
function Invoke-Init([string]$teamName, [string]$scenario, [string]$templateName) {
    if (-not $teamName -or -not $scenario) {
        Write-Host "  Usage: team init <name> <scenario> [template]" -ForegroundColor Yellow
        Write-Host "  Templates: feature, research, bugfix, refactor, fullstack" -ForegroundColor Gray
        return
    }

    $dir = Get-TeamDir $teamName
    if (Test-Path $dir) {
        Write-Host "  Team '$teamName' already exists at $dir" -ForegroundColor Yellow
        return
    }

    # Scaffold directories (v0.2: added roles/, heartbeat/, logs/)
    foreach ($sub in @("artifacts", "mailbox", ".launch", "roles", "heartbeat", "logs")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null
    }

    # Pre-create lead inbox so agents can append from the start
    Set-Content (Join-Path $dir "mailbox\lead.inbox") "" -Encoding UTF8

    # Manifest
    $manifest = [ordered]@{
        team        = $teamName
        scenario    = $scenario
        project_dir = (Get-Location).Path
        created     = (Get-Date -Format "o")
        roles       = [ordered]@{}
    }
    Write-Json (Join-Path $dir "manifest.json") $manifest

    # Tasks
    Write-Json (Join-Path $dir "tasks.json") @{ tasks = @() }

    # Protocol from template
    $templatePath = Join-Path $TemplatesDir "protocol.md"
    if (Test-Path $templatePath) {
        $protocol = (Get-Content $templatePath -Raw -Encoding UTF8) -replace '\{team-name\}', $teamName
        Set-Content (Join-Path $dir "protocol.md") $protocol -Encoding UTF8
    }

    Write-Host ""
    Write-Host "  ✅ Team '$teamName' created" -ForegroundColor Green
    Write-Host "  📁 $dir" -ForegroundColor Gray
    Write-Host "  📂 Project: $((Get-Location).Path)" -ForegroundColor Gray

    # ── Apply template if specified ────────────────────────────────────────
    if ($templateName) {
        $presetPath = Join-Path $ToolRoot "templates\presets\$templateName.json"
        if (-not (Test-Path $presetPath)) {
            $presetPath = Join-Path $ScriptDir "templates\presets\$templateName.json"
        }
        if (-not (Test-Path $presetPath)) {
            Write-Host ""
            Write-Host "  ⚠️  Template '$templateName' not found." -ForegroundColor Yellow
            Write-Host "  Available: feature, research, bugfix, refactor, fullstack" -ForegroundColor Gray
            Write-Host ""
            return
        }

        $preset = Read-Json $presetPath
        Write-Host "  📋 Template: $($preset.name) — $($preset.description)" -ForegroundColor Cyan
        Write-Host ""

        # Create roles from template
        foreach ($role in $preset.roles) {
            $model = $null
            if ($role.model) { $model = $role.model }
            Invoke-Role $teamName $role.key $role.description $model
        }

        # Create tasks from template
        foreach ($task in $preset.tasks) {
            $deps = ""
            if ($task.depends_on -and @($task.depends_on).Count -gt 0) {
                $deps = ($task.depends_on -join ",")
            }
            Invoke-Task $teamName $task.id $task.title $task.assigned_to $deps
        }

        Write-Host ""
        Invoke-Status $teamName
        return
    }

    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    team role $teamName <key> `"<description>`" [model]"
    Write-Host "    team task $teamName <id> `"<title>`" <role> [depends-on]"
    Write-Host "    team launch $teamName"
    Write-Host ""
}

# ── role ────────────────────────────────────────────────────────────────────
# Adds a role to the team. In v0.2 this also generates a Markdown role file
# at {team-dir}/roles/{key}.md with YAML frontmatter that agents read at
# launch time. The manifest still stores a summary for quick lookups.
function Invoke-Role([string]$teamName, [string]$roleKey, [string]$description, [string]$model) {
    if (-not $teamName -or -not $roleKey -or -not $description) {
        Write-Host "  Usage: team role <name> <key> <description> [model]" -ForegroundColor Yellow
        return
    }
    Assert-TeamExists $teamName

    $manifest = Get-Manifest $teamName
    $teamDir = Get-TeamDir $teamName
    $roleName = (Get-Culture).TextInfo.ToTitleCase(($roleKey -replace '-', ' '))

    # Default allowed tools per common role patterns
    $allowedTools = @("view", "glob", "grep", "explore")

    $ownsFiles  = @("artifacts/$roleKey-output.md")
    $readsFrom  = @("tasks.json", "protocol.md", "manifest.json", "mailbox/$roleKey.inbox")

    # ── Generate role Markdown file ────────────────────────────────────────
    $rolesDir = Join-Path $teamDir "roles"
    if (-not (Test-Path $rolesDir)) {
        New-Item -ItemType Directory -Force -Path $rolesDir | Out-Null
    }

    $toolsYaml  = ($allowedTools  | ForEach-Object { "  - $_" }) -join "`n"
    $ownsYaml   = ($ownsFiles     | ForEach-Object { "  - $_" }) -join "`n"
    $readsYaml  = ($readsFrom     | ForEach-Object { "  - $_" }) -join "`n"
    $modelLine  = if ($model) { $model } else { "claude-sonnet-4" }

    $roleFileContent = @"
---
name: $roleName
key: $roleKey
description: $description
model: $modelLine
allowed_tools:
$toolsYaml
owns_files:
$ownsYaml
reads_from:
$readsYaml
---

## Instructions

You are the $roleName. $description

Follow the team protocol (protocol.md) and coordinate via the mailbox system.
Write your deliverables to the artifacts/ directory.
"@

    $roleFilePath = Join-Path $rolesDir "$roleKey.md"
    Set-Content $roleFilePath $roleFileContent -Encoding UTF8

    # ── Update manifest (lightweight summary) ──────────────────────────────
    $role = [ordered]@{
        name          = $roleName
        description   = $description
        model         = if ($model) { $model } else { $null }
        role_file     = "roles/$roleKey.md"
        allowed_tools = $allowedTools
        owns_files    = $ownsFiles
        reads_from    = $readsFrom
    }

    $manifest.roles | Add-Member -NotePropertyName $roleKey -NotePropertyValue $role -Force
    Save-Manifest $teamName $manifest

    Write-Host "  ✅ Role '$roleKey' added" -ForegroundColor Green
    if ($model) { Write-Host "     Model: $model" -ForegroundColor Gray }
    Write-Host "     Role file: roles/$roleKey.md" -ForegroundColor Gray
    Write-Host ""
}

# ── task ────────────────────────────────────────────────────────────────────
# Adds a task to the team backlog. Automatically registers the deliverable
# in the assigned role's owns_files and updates the role Markdown file.
function Invoke-Task([string]$teamName, [string]$taskId, [string]$title, [string]$assignedTo, [string]$dependsOn) {
    if (-not $teamName -or -not $taskId -or -not $title -or -not $assignedTo) {
        Write-Host "  Usage: team task <name> <id> <title> <role> [depends-on]" -ForegroundColor Yellow
        Write-Host "  depends-on: comma-separated task IDs" -ForegroundColor Gray
        return
    }
    Assert-TeamExists $teamName

    $tasksObj = Get-Tasks $teamName

    $deps = @()
    if ($dependsOn) {
        $deps = @($dependsOn -split "," | ForEach-Object { $_.Trim() })
    }

    $task = [ordered]@{
        id          = $taskId
        title       = $title
        assigned_to = $assignedTo
        status      = if ($deps.Count -gt 0) { "blocked" } else { "pending" }
        depends_on  = $deps
        deliverable = "artifacts/$taskId.md"
    }

    # Append to tasks array
    $currentTasks = @($tasksObj.tasks)
    $currentTasks += $task
    $tasksObj.tasks = $currentTasks
    Save-Tasks $teamName $tasksObj

    # Auto-add deliverable to role's owns_files if not present
    $manifest = Get-Manifest $teamName
    $roleObj = $manifest.roles.$assignedTo
    if ($roleObj) {
        $currentOwns = @($roleObj.owns_files)
        if ($currentOwns -notcontains "artifacts/$taskId.md") {
            $currentOwns += "artifacts/$taskId.md"
            $roleObj.owns_files = $currentOwns
            Save-Manifest $teamName $manifest
        }

        # Also update the role Markdown file's owns_files frontmatter
        $teamDir = Get-TeamDir $teamName
        $roleFilePath = Join-Path $teamDir "roles\$assignedTo.md"
        if (Test-Path $roleFilePath) {
            $fm = Read-RoleFrontmatter $roleFilePath
            $body = Read-RoleBody $roleFilePath

            $existingOwns = @()
            if ($fm.Contains("owns_files")) { $existingOwns = @($fm["owns_files"]) }
            if ($existingOwns -notcontains "artifacts/$taskId.md") {
                $existingOwns += "artifacts/$taskId.md"
            }

            # Rebuild the role file with updated owns_files
            $toolsYaml = ($fm["allowed_tools"] | ForEach-Object { "  - $_" }) -join "`n"
            $ownsYaml  = ($existingOwns          | ForEach-Object { "  - $_" }) -join "`n"
            $readsYaml = ($fm["reads_from"]      | ForEach-Object { "  - $_" }) -join "`n"

            $updatedContent = @"
---
name: $($fm["name"])
key: $($fm["key"])
description: $($fm["description"])
model: $($fm["model"])
allowed_tools:
$toolsYaml
owns_files:
$ownsYaml
reads_from:
$readsYaml
---

$body
"@
            Set-Content $roleFilePath $updatedContent -Encoding UTF8
        }
    }

    $statusLabel = if ($deps.Count -gt 0) { "blocked `u{2190} $dependsOn" } else { "pending" }
    Write-Host "  ✅ Task '$taskId' → $assignedTo [$statusLabel]" -ForegroundColor Green
    Write-Host ""
}

# ── Helper: Role Launcher ───────────────────────────────────────────────────
# Builds prompt, writes launcher script, and spawns a terminal tab for one role.
# If DoneFile is provided, the launcher writes a signal file after copilot exits.
function New-RoleLauncher {
    param(
        [string]$TeamName,
        [string]$RoleKey,
        [PSObject]$Role,
        [string]$ProjectDir,
        [string]$TeamDir,
        [string]$DoneFile
    )

    $launchDir = Join-Path $TeamDir ".launch"

    # Resolve role file for instructions
    $roleFilePath = Join-Path $TeamDir "roles\$RoleKey.md"
    $roleInstructions = ""
    if (Test-Path $roleFilePath) {
        $roleInstructions = Read-RoleBody $roleFilePath
    }

    # Build tool permissions block
    $toolsList = @($Role.allowed_tools)
    $toolsBlock = ""
    if ($toolsList.Count -gt 0) {
        $toolLines = ($toolsList | ForEach-Object { "  - $_" }) -join "`n"
        $toolsBlock = @"

YOUR ALLOWED TOOLS (use only these):
$toolLines
"@
    }

    # Build file ownership block
    $ownsList  = (@($Role.owns_files)  | ForEach-Object { "  - $_" }) -join "`n"
    $readsList = (@($Role.reads_from)  | ForEach-Object { "  - $_" }) -join "`n"

    # Heartbeat instructions
    $manifest = Get-Manifest $TeamName
    $heartbeatPath = "$TeamDir\heartbeat\$RoleKey.json"
    $heartbeatBlock = @"

HEARTBEAT: You MUST maintain a heartbeat file so the team lead can monitor you.
File: $heartbeatPath
Update this file after starting each task and periodically while working.
Write valid JSON with this schema:
  {"status": "<active|idle|done>", "current_task": "<task-id or null>", "last_active": "<ISO-8601 UTC>", "pid": <your-process-id-or-0>}
Example:
  {"status": "active", "current_task": "design-spec", "last_active": "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')", "pid": 0}
Update "last_active" each time you write. Set status to "idle" between tasks, "done" when all tasks complete.
"@

    # Compose the full prompt
    $prompt = @"
You are the $($Role.name) on agent team "$TeamName".

TEAM DIRECTORY: $TeamDir
PROJECT DIRECTORY: $ProjectDir

YOUR ROLE FILE: $roleFilePath
Read this file for your full role definition and instructions.

YOUR STARTUP SEQUENCE:
1. Read $TeamDir\protocol.md for your operating rules.
2. Read your role file at $roleFilePath for your specific instructions.
3. Read $TeamDir\manifest.json and find your role "$RoleKey" under "roles".
4. Read $TeamDir\tasks.json and find tasks where assigned_to is "$RoleKey".
5. Write your initial heartbeat to $heartbeatPath.
6. Execute your tasks following the protocol. Write deliverables to artifacts/.

SCENARIO: $($manifest.scenario)

YOUR ROLE: $($Role.description)
$toolsBlock

FILES YOU OWN (only you write these):
$ownsList

FILES YOU READ FROM:
$readsList
$heartbeatBlock

$roleInstructions

IMPORTANT: Begin by reading protocol.md now. Then read your role file, then tasks.json, then start working.
WHEN ALL YOUR TASKS ARE COMPLETE: You MUST type /exit to end your session. This signals the orchestrator that you are done.
"@

    # Write prompt to file
    $promptFile = Join-Path $launchDir "$RoleKey.prompt"
    Set-Content $promptFile $prompt -Encoding UTF8

    # Write launcher script (with optional .done signal)
    $modelFlag = if ($Role.model) { " --model `"$($Role.model)`"" } else { "" }
    $logFile = "$TeamDir\logs\$RoleKey.log"

    $signalLine = ""
    if ($DoneFile) {
        $signalLine = "`nSet-Content '$($DoneFile -replace "'","''")' (Get-Date -Format 'o') -Encoding UTF8"
    }

    # Always use -i (interactive) for the nice TUI. Agents are told to /exit when done.
    $copilotFlag = "-i"
    $noExitFlag = if ($DoneFile) { "" } else { " -NoExit" }

    $launcherScript = @"
Set-Location '$($ProjectDir -replace "'","''")'
Start-Transcript -Path '$($logFile -replace "'","''")' -Append
`$promptText = Get-Content '$($promptFile -replace "'","''")' -Raw
copilot $copilotFlag `$promptText --add-dir '$($TeamDir -replace "'","''")' --yolo$modelFlag
Stop-Transcript$signalLine
"@
    $launcherFile = Join-Path $launchDir "launch-$RoleKey.ps1"
    Set-Content $launcherFile $launcherScript -Encoding UTF8

    # Spawn terminal tab
    $tabTitle = "$($Role.name) ($TeamName)"
    Start-Process "wt.exe" -ArgumentList "-w 0 new-tab --title `"$tabTitle`" pwsh$noExitFlag -File `"$launcherFile`""
}


# ── launch ──────────────────────────────────────────────────────────────────
# Spawns Copilot CLI sessions in new terminal tabs.
# Single-role launch: fire-and-forget (for manual use).
# Full team launch: wave-based blocking orchestrator — spawns roles with
# pending tasks, waits for .done signals, runs unblock, spawns next wave.
function Invoke-Launch([string]$teamName, [string]$specificRole) {
    if (-not $teamName) {
        Write-Host "  Usage: team launch <name> [role]" -ForegroundColor Yellow
        return
    }
    Assert-TeamExists $teamName

    $manifest = Get-Manifest $teamName
    $teamDir  = Get-TeamDir $teamName
    $projectDir = $manifest.project_dir
    $launchDir  = Join-Path $teamDir ".launch"

    # Ensure all required directories exist
    foreach ($sub in @(".launch", "heartbeat", "logs")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $teamDir $sub) | Out-Null
    }

    if ($specificRole) {
        # ── Single-role launch (fire-and-forget) ──────────────────────────
        $roleProp = $manifest.roles.PSObject.Properties | Where-Object { $_.Name -eq $specificRole }
        if (-not $roleProp) {
            Write-Host "  Error: Role '$specificRole' not found in team '$teamName'" -ForegroundColor Red
            return
        }

        Write-Host ""
        Write-Host "  `u{1F680} Launching '$specificRole' in team '$teamName'" -ForegroundColor Cyan
        Write-Host ""

        New-RoleLauncher -TeamName $teamName -RoleKey $specificRole -Role $roleProp.Value `
            -ProjectDir $projectDir -TeamDir $teamDir

        Write-Host "  `u{1F7E2} $($roleProp.Value.name) ($specificRole)" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Agent launched! Check your terminal tabs." -ForegroundColor Cyan
        Write-Host ""
        return
    }

    # ── Full orchestrated launch ──────────────────────────────────────────

    Write-Host ""
    Write-Host "  `u{1F680} Orchestrating team '$teamName'" -ForegroundColor Cyan
    Write-Host ""

    $waveNum = 0
    while ($true) {
        $waveNum++
        $tasksObj = Get-Tasks $teamName  # Re-read each wave

        # Find roles with pending tasks
        $pendingRoles = @()
        foreach ($task in $tasksObj.tasks) {
            if ($task.status -eq "pending" -and $pendingRoles -notcontains $task.assigned_to) {
                $pendingRoles += $task.assigned_to
            }
        }

        if ($pendingRoles.Count -eq 0) {
            $blockedCount = @($tasksObj.tasks | Where-Object { $_.status -eq "blocked" }).Count
            if ($blockedCount -gt 0) {
                Write-Host "  `u{26A0}`u{FE0F}  $blockedCount tasks still blocked `u{2014} dependencies may not have been marked done" -ForegroundColor Yellow
            } else {
                Write-Host "  `u{2705} All waves complete!" -ForegroundColor Green
            }
            break
        }

        Write-Host "  `u{2500}`u{2500} Wave $waveNum `u{2500}`u{2500}" -ForegroundColor Cyan

        # Spawn this wave's roles
        $doneFiles = @{}
        foreach ($roleKey in $pendingRoles) {
            $roleProp = $manifest.roles.PSObject.Properties | Where-Object { $_.Name -eq $roleKey }
            if (-not $roleProp) { continue }

            $doneFile = Join-Path $launchDir "$roleKey.done"
            $doneFiles[$roleKey] = $doneFile
            # Remove old .done file to avoid stale signals
            Remove-Item $doneFile -Force -ErrorAction SilentlyContinue

            New-RoleLauncher -TeamName $teamName -RoleKey $roleKey -Role $roleProp.Value `
                -ProjectDir $projectDir -TeamDir $teamDir -DoneFile $doneFile

            Write-Host "    `u{1F7E2} $($roleProp.Value.name) ($roleKey)" -ForegroundColor Green
            Start-Sleep -Milliseconds 800
        }

        # Wait for this wave to complete
        Write-Host ""
        $startTime = Get-Date
        while ($true) {
            Start-Sleep 5
            $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)

            $completed = @()
            foreach ($roleKey in $pendingRoles) {
                if (Test-Path $doneFiles[$roleKey]) { $completed += $roleKey }
            }

            $remaining = @($pendingRoles | Where-Object { $completed -notcontains $_ })
            if ($remaining.Count -gt 0) {
                Write-Host "    Waiting ($($elapsed)s): $($completed.Count)/$($pendingRoles.Count) done `u{2014} remaining: $($remaining -join ', ')" -ForegroundColor Gray
            }

            if ($completed.Count -eq $pendingRoles.Count) { break }

            # Timeout per wave: 15 minutes
            if ($elapsed -gt 900) {
                Write-Host "    `u{26A0}`u{FE0F}  Wave timed out after 15 minutes" -ForegroundColor Red
                break
            }
        }

        Write-Host "    `u{2705} Wave $waveNum complete" -ForegroundColor Green
        Write-Host ""

        # Unblock next wave
        Invoke-Unblock $teamName
    }

    # Final status
    Write-Host ""
    Invoke-Status $teamName
}


# ── status ──────────────────────────────────────────────────────────────────
# Displays the full team dashboard: agents (with heartbeat), tasks, artifacts,
# logs, and the lead inbox.
function Invoke-Status([string]$teamName) {
    if (-not $teamName) {
        Write-Host "  Usage: team status <name>" -ForegroundColor Yellow
        return
    }
    Assert-TeamExists $teamName

    $manifest = Get-Manifest $teamName
    $tasksObj = Get-Tasks $teamName
    $teamDir  = Get-TeamDir $teamName

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  Team: $($teamName.PadRight(38))║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Scenario: $($manifest.scenario)" -ForegroundColor White
    Write-Host "  Project:  $($manifest.project_dir)" -ForegroundColor Gray
    Write-Host ""

    # ── Agents (with heartbeat) ────────────────────────────────────────────
    Write-Host "  AGENTS" -ForegroundColor Yellow
    $heartbeatDir = Join-Path $teamDir "heartbeat"

    foreach ($prop in $manifest.roles.PSObject.Properties) {
        $key      = $prop.Name
        $roleName = $prop.Value.name
        $hbPath   = Join-Path $heartbeatDir "$key.json"

        if (Test-Path $hbPath) {
            try {
                $hb = Read-Json $hbPath
                $timeAgo = Format-TimeAgo $hb.last_active

                switch ($hb.status) {
                    "active" {
                        $taskLabel = if ($hb.current_task) { "task: $($hb.current_task), " } else { "" }
                        Write-Host "    🟢 $key — active ($taskLabel$timeAgo)" -ForegroundColor Green
                    }
                    "idle" {
                        Write-Host "    🟡 $key — idle ($timeAgo)" -ForegroundColor Yellow
                    }
                    "done" {
                        Write-Host "    ✅ $key — done ($timeAgo)" -ForegroundColor DarkGreen
                    }
                    default {
                        Write-Host "    ⚪ $key — $($hb.status) ($timeAgo)" -ForegroundColor Gray
                    }
                }
            } catch {
                Write-Host "    🔴 $key — heartbeat unreadable" -ForegroundColor Red
            }
        } else {
            Write-Host "    🔴 $key — no heartbeat" -ForegroundColor Red
        }
    }
    Write-Host ""

    # ── Roles ──────────────────────────────────────────────────────────────
    Write-Host "  ROLES" -ForegroundColor Yellow
    foreach ($prop in $manifest.roles.PSObject.Properties) {
        $modelTag = if ($prop.Value.model) { " [$($prop.Value.model)]" } else { "" }
        $toolTag  = ""
        $tools    = @($prop.Value.allowed_tools)
        if ($tools.Count -gt 0) {
            $toolTag = " tools: $($tools -join ', ')"
        }
        Write-Host "    $($prop.Name): $($prop.Value.description)$modelTag" -ForegroundColor White
        if ($toolTag) {
            Write-Host "      $toolTag" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # ── Tasks ──────────────────────────────────────────────────────────────
    Write-Host "  TASKS" -ForegroundColor Yellow
    $doneCount  = 0
    $totalCount = @($tasksObj.tasks).Count
    foreach ($task in $tasksObj.tasks) {
        $icon = switch ($task.status) {
            "done"        { "`u{2705}" }   # ✅
            "in_progress" { "`u{1F504}" }  # 🔄
            "blocked"     { "`u{1F6AB}" }  # 🚫
            "pending"     { "`u{23F3}" }   # ⏳
            default       { "`u{2753}" }   # ❓
        }
        if ($task.status -eq "done") { $doneCount++ }
        $deps = if (@($task.depends_on).Count -gt 0) { " (`u{2190} $($task.depends_on -join ', '))" } else { "" }
        Write-Host "    $icon $($task.id) `u{2192} $($task.assigned_to) [$($task.status)]$deps" -ForegroundColor White
        Write-Host "       $($task.title)" -ForegroundColor DarkGray
        # Show acceptance criteria if present
        if ($task.acceptance_criteria) {
            foreach ($ac in $task.acceptance_criteria) {
                $acIcon = if ($task.status -eq "done") { "`u{2611}" } else { "`u{2610}" }
                Write-Host "       $acIcon $ac" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
    $progressColor = if ($totalCount -gt 0 -and $doneCount -eq $totalCount) { "Green" } else { "Yellow" }
    Write-Host "  Progress: $doneCount/$totalCount tasks done" -ForegroundColor $progressColor
    Write-Host ""

    # ── Artifacts ──────────────────────────────────────────────────────────
    $artifactsDir = Join-Path $teamDir "artifacts"
    $artifacts = Get-ChildItem $artifactsDir -File -ErrorAction SilentlyContinue
    Write-Host "  ARTIFACTS" -ForegroundColor Yellow
    if ($artifacts) {
        foreach ($f in $artifacts) {
            $size = if ($f.Length -gt 1024) { "$([math]::Round($f.Length/1024, 1))KB" } else { "$($f.Length)B" }
            Write-Host "    📄 $($f.Name) ($size)" -ForegroundColor White
        }
    } else {
        Write-Host "    (none yet)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # ── Logs ───────────────────────────────────────────────────────────────
    $logsDir = Join-Path $teamDir "logs"
    $logFiles = Get-ChildItem $logsDir -File -Filter "*.log" -ErrorAction SilentlyContinue
    Write-Host "  LOGS" -ForegroundColor Yellow
    if ($logFiles) {
        foreach ($lf in $logFiles) {
            $size = if ($lf.Length -gt 1024) { "$([math]::Round($lf.Length/1024, 1))KB" } else { "$($lf.Length)B" }
            $age = Format-TimeAgo $lf.LastWriteTimeUtc.ToString("o")
            Write-Host "    📝 $($lf.Name) ($size, updated $age)" -ForegroundColor White
        }
    } else {
        Write-Host "    (none yet)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # ── Lead Inbox ─────────────────────────────────────────────────────────
    $inboxPath = Join-Path $teamDir "mailbox\lead.inbox"
    Write-Host "  LEAD INBOX" -ForegroundColor Yellow
    if (Test-Path $inboxPath) {
        $content = Get-Content $inboxPath -Encoding UTF8
        foreach ($line in $content) {
            if ($line -match '^\[FROM:') {
                Write-Host "    $line" -ForegroundColor Cyan
            } elseif ($line -eq '---') {
                Write-Host "    $line" -ForegroundColor DarkGray
            } else {
                Write-Host "    $line" -ForegroundColor White
            }
        }
    } else {
        Write-Host "    (empty)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ── list ────────────────────────────────────────────────────────────────────
# Lists all teams under the teams root directory.
function Invoke-List {
    Write-Host ""
    Write-Host "  TEAMS" -ForegroundColor Yellow
    $teams = Get-AllTeamDirs
    if ($teams) {
        foreach ($t in $teams) {
            $manifestPath = Join-Path $t.FullName "manifest.json"
            if (Test-Path $manifestPath) {
                $m = Read-Json $manifestPath
                $roleCount = @($m.roles.PSObject.Properties).Count
                $taskPath = Join-Path $t.FullName "tasks.json"
                $taskCount = 0
                $doneCount = 0
                if (Test-Path $taskPath) {
                    $tObj = Read-Json $taskPath
                    $taskCount = @($tObj.tasks).Count
                    $doneCount = @($tObj.tasks | Where-Object { $_.status -eq "done" }).Count
                }
                Write-Host "    📋 $($t.Name) — $($m.scenario)" -ForegroundColor White
                Write-Host "       $roleCount roles, $doneCount/$taskCount tasks done" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "    (no teams)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ── clean ───────────────────────────────────────────────────────────────────
# Removes a team directory and all its contents.
function Invoke-Clean([string]$teamName) {
    if (-not $teamName) {
        Write-Host "  Usage: team clean <name>" -ForegroundColor Yellow
        return
    }
    $dir = Get-TeamDir $teamName
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir
        Write-Host "  🗑️  Team '$teamName' removed." -ForegroundColor Green
    } else {
        Write-Host "  Team '$teamName' not found." -ForegroundColor Yellow
    }
}

# ── help ────────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  Agent Teams for GitHub Copilot CLI   v0.5  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  COMMANDS" -ForegroundColor Yellow
    Write-Host "    init   <name> <scenario> [template]        Create a new team" -ForegroundColor White
    Write-Host "           templates: feature, fullstack, sprint, bugfix, refactor, research, ship, audit" -ForegroundColor Gray
    Write-Host "    role   <name> <key> <description> [model]  Add a role (generates role file)" -ForegroundColor White
    Write-Host "    task   <name> <id> <title> <role> [deps]   Add a task" -ForegroundColor White
    Write-Host "    launch <name>                              Orchestrate: spawn waves, wait, unblock, repeat" -ForegroundColor White
    Write-Host "    launch <name> <role>                       Spawn single role (manual, non-blocking)" -ForegroundColor White
    Write-Host "    unblock <name>                             Unblock tasks with met deps" -ForegroundColor White
    Write-Host "    status <name>                              Dashboard with heartbeats" -ForegroundColor White
    Write-Host "    watch  <name>                              Live dashboard (refreshes 3s)" -ForegroundColor White
    Write-Host "    plan   <scenario> [template-seed]          AI-generate a team plan (blocking)" -ForegroundColor White
    Write-Host "    apply                                      Create team from plan" -ForegroundColor White
    Write-Host "    list                                       List all teams" -ForegroundColor White
    Write-Host "    clean  <name>                              Remove a team" -ForegroundColor White
    Write-Host ""
    Write-Host "  QUICK START" -ForegroundColor Yellow
    Write-Host '    team init calculator "Build a basic calculator app"' -ForegroundColor Gray
    Write-Host '    team role calculator architect "Designs the spec and file structure" claude-sonnet-4' -ForegroundColor Gray
    Write-Host '    team role calculator coder "Implements code from spec" claude-sonnet-4' -ForegroundColor Gray
    Write-Host '    team role calculator reviewer "Reviews for correctness" claude-sonnet-4' -ForegroundColor Gray
    Write-Host '    team task calculator design-spec "Design the architecture" architect' -ForegroundColor Gray
    Write-Host '    team task calculator implement "Build the code" coder design-spec' -ForegroundColor Gray
    Write-Host '    team task calculator review "Review the code" reviewer implement' -ForegroundColor Gray
    Write-Host "    team launch calculator" -ForegroundColor Gray
    Write-Host "    team status calculator" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  v0.5 FEATURES" -ForegroundColor Yellow
    Write-Host "    - Signal-based blocking orchestrator for team plan and team launch" -ForegroundColor Gray
    Write-Host "    - team plan: blocks, polls .done signals, spawns synthesizer after assessors" -ForegroundColor Gray
    Write-Host "    - team launch: wave-based orchestrator with automatic unblock between waves" -ForegroundColor Gray
    Write-Host "    - .done signal files written by launcher scripts after copilot exits" -ForegroundColor Gray
    Write-Host "    - Prompt/launcher generation extracted to New-RoleLauncher helper" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  v0.4 FEATURES" -ForegroundColor Yellow
    Write-Host "    - team plan: AI-generated team planning via planner session" -ForegroundColor Gray
    Write-Host "    - team apply: create a team from a proposed plan" -ForegroundColor Gray
    Write-Host "    - Acceptance criteria on tasks (sprint contracts)" -ForegroundColor Gray
    Write-Host "    - Status dashboard shows acceptance criteria as checkboxes" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  v0.3 FEATURES" -ForegroundColor Yellow
    Write-Host "    - Atomic JSON writes via tmp+rename (crash-safe)" -ForegroundColor Gray
    Write-Host "    - Live dashboard: team watch <name>" -ForegroundColor Gray
    Write-Host "    - Role files: roles/{key}.md with YAML frontmatter" -ForegroundColor Gray
    Write-Host "    - Heartbeat:  heartbeat/{key}.json for liveness monitoring" -ForegroundColor Gray
    Write-Host "    - Logs:       logs/{key}.log for session output" -ForegroundColor Gray
    Write-Host "    - Tools:      allowed_tools per role, enforced in prompt" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  DIRECTORIES" -ForegroundColor Yellow
    Write-Host "    artifacts/   Deliverables written by agents" -ForegroundColor Gray
    Write-Host "    mailbox/     Inter-agent messaging" -ForegroundColor Gray
    Write-Host "    roles/       Role definition files (Markdown)" -ForegroundColor Gray
    Write-Host "    heartbeat/   Agent liveness signals (JSON)" -ForegroundColor Gray
    Write-Host "    logs/        Session output logs" -ForegroundColor Gray
    Write-Host "    .launch/     Generated prompts and launcher scripts" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NOTES" -ForegroundColor Yellow
    Write-Host "    - deps are comma-separated task IDs: dep1,dep2" -ForegroundColor Gray
    Write-Host "    - model is optional (e.g., claude-sonnet-4, gpt-5.2)" -ForegroundColor Gray
    Write-Host "    - launch opens new terminal tabs in current window" -ForegroundColor Gray
    Write-Host "    - agents coordinate via files in .agent-teams/<name>/" -ForegroundColor Gray
    Write-Host "    - edit roles/{key}.md to customize agent instructions" -ForegroundColor Gray
    Write-Host ""
}

# ── watch ────────────────────────────────────────────────────────────────────
# Live dashboard that refreshes every 3 seconds. Shows heartbeats, tasks,
# recent log lines, and lead inbox. Press Ctrl+C to stop.
function Invoke-Watch([string]$teamName) {
    if (-not $teamName) {
        Write-Host "  Usage: team watch <name>" -ForegroundColor Yellow
        return
    }
    Assert-TeamExists $teamName

    $teamDir = Get-TeamDir $teamName

    while ($true) {
        Clear-Host
        $manifest = Get-Manifest $teamName
        $tasksObj = Get-Tasks $teamName

        $now = Get-Date -Format "HH:mm:ss"
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║  WATCH: $($teamName.PadRight(30)) $now ║" -ForegroundColor Cyan
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        # ── Progress bar ──────────────────────────────────────────────────
        $totalCount = @($tasksObj.tasks).Count
        $doneCount  = @($tasksObj.tasks | Where-Object { $_.status -eq "done" }).Count
        $barWidth   = 30
        $filled     = if ($totalCount -gt 0) { [math]::Floor($doneCount / $totalCount * $barWidth) } else { 0 }
        $empty      = $barWidth - $filled
        $bar        = ("█" * $filled) + ("░" * $empty)
        $pct        = if ($totalCount -gt 0) { [math]::Floor($doneCount / $totalCount * 100) } else { 0 }
        Write-Host "  [$bar] $doneCount/$totalCount ($pct%)" -ForegroundColor $(if ($doneCount -eq $totalCount -and $totalCount -gt 0) { "Green" } else { "Yellow" })
        Write-Host ""

        # ── Heartbeats ────────────────────────────────────────────────────
        Write-Host "  HEARTBEATS" -ForegroundColor Yellow
        $heartbeatDir = Join-Path $teamDir "heartbeat"
        foreach ($prop in $manifest.roles.PSObject.Properties) {
            $key    = $prop.Name
            $hbPath = Join-Path $heartbeatDir "$key.json"
            if (Test-Path $hbPath) {
                try {
                    $hb = Read-Json $hbPath
                    $timeAgo = Format-TimeAgo $hb.last_active
                    $taskLabel = if ($hb.current_task) { " task:$($hb.current_task)" } else { "" }
                    $icon = switch ($hb.status) {
                        "active" { "🟢" }
                        "idle"   { "🟡" }
                        "done"   { "✅" }
                        default  { "⚪" }
                    }
                    $color = switch ($hb.status) {
                        "active" { "Green" }
                        "idle"   { "Yellow" }
                        "done"   { "DarkGreen" }
                        default  { "Gray" }
                    }
                    Write-Host "    $icon $key — $($hb.status)$taskLabel ($timeAgo)" -ForegroundColor $color
                } catch {
                    Write-Host "    🔴 $key — heartbeat unreadable" -ForegroundColor Red
                }
            } else {
                Write-Host "    🔴 $key — no heartbeat" -ForegroundColor Red
            }
        }
        Write-Host ""

        # ── Task board ────────────────────────────────────────────────────
        Write-Host "  TASKS" -ForegroundColor Yellow
        foreach ($task in $tasksObj.tasks) {
            $icon = switch ($task.status) {
                "done"        { "`u{2705}" }
                "in_progress" { "`u{1F504}" }
                "blocked"     { "`u{1F6AB}" }
                "pending"     { "`u{23F3}" }
                default       { "`u{2753}" }
            }
            Write-Host "    $icon $($task.id) `u{2192} $($task.assigned_to) [$($task.status)]" -ForegroundColor White
        }
        Write-Host ""

        # ── Recent logs ───────────────────────────────────────────────────
        $logsDir = Join-Path $teamDir "logs"
        $logFiles = Get-ChildItem $logsDir -File -Filter "*.log" -ErrorAction SilentlyContinue
        if ($logFiles) {
            Write-Host "  RECENT LOGS" -ForegroundColor Yellow
            foreach ($lf in $logFiles) {
                $agentName = [System.IO.Path]::GetFileNameWithoutExtension($lf.Name)
                $lines = Get-Content $lf.FullName -Tail 5 -ErrorAction SilentlyContinue
                if ($lines) {
                    Write-Host "    ── $agentName ──" -ForegroundColor DarkCyan
                    foreach ($line in $lines) {
                        $trimmed = if ($line.Length -gt 80) { $line.Substring(0, 77) + "..." } else { $line }
                        Write-Host "      $trimmed" -ForegroundColor DarkGray
                    }
                }
            }
            Write-Host ""
        }

        # ── Lead inbox (last 3 messages) ──────────────────────────────────
        $inboxPath = Join-Path $teamDir "mailbox\lead.inbox"
        if (Test-Path $inboxPath) {
            Write-Host "  LEAD INBOX (recent)" -ForegroundColor Yellow
            $inboxLines = Get-Content $inboxPath -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($inboxLines) {
                # Find message boundaries (lines starting with [FROM:) and take last 3 messages
                $msgStarts = @()
                for ($i = 0; $i -lt $inboxLines.Count; $i++) {
                    if ($inboxLines[$i] -match '^\[FROM:') { $msgStarts += $i }
                }
                $startIdx = if ($msgStarts.Count -gt 3) { $msgStarts[$msgStarts.Count - 3] } elseif ($msgStarts.Count -gt 0) { $msgStarts[0] } else { 0 }
                for ($i = $startIdx; $i -lt $inboxLines.Count; $i++) {
                    $line = $inboxLines[$i]
                    if ($line -match '^\[FROM:') {
                        Write-Host "    $line" -ForegroundColor Cyan
                    } elseif ($line -eq '---') {
                        Write-Host "    $line" -ForegroundColor DarkGray
                    } else {
                        Write-Host "    $line" -ForegroundColor White
                    }
                }
            } else {
                Write-Host "    (empty)" -ForegroundColor DarkGray
            }
            Write-Host ""
        }

        Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
        Start-Sleep 3
    }
}

# ── plan ─────────────────────────────────────────────────────────────────────
# Spawns a planner Copilot session that explores the codebase and writes
# a proposed team plan to .agent-teams/.plan/proposed-plan.json.
# Assessors run in parallel, then synthesizer runs after all assessors complete.
# Parent polls for .done signal files and shows live progress.
function Invoke-Plan([string]$scenario, [string]$seedTemplate) {
    if (-not $scenario) {
        Write-Host "  Usage: team plan <scenario> [template-seed]" -ForegroundColor Yellow
        return
    }

    $projectDir = (Get-Location).Path
    $planDir = Join-Path $projectDir ".agent-teams\.plan"
    New-Item -ItemType Directory -Force -Path $planDir | Out-Null

    # Clean stale files from any previous run
    foreach ($stale in @("tech-assessment.md", "scope-assessment.md", "risk-assessment.md", "proposed-plan.json",
                         "tech-assessor.done", "scope-assessor.done", "risk-assessor.done", "synthesizer.done")) {
        $stalePath = Join-Path $planDir $stale
        if (Test-Path $stalePath) { Remove-Item $stalePath -Force }
    }

    $seedInfo = ""
    if ($seedTemplate) {
        $seedPath = Join-Path $ToolRoot "templates\presets\$seedTemplate.json"
        if (-not (Test-Path $seedPath)) {
            $seedPath = Join-Path (Split-Path $MyInvocation.ScriptName -Parent) "templates\presets\$seedTemplate.json"
        }
        if (Test-Path $seedPath) {
            $seedInfo = "SEED TEMPLATE ($seedTemplate): $(Get-Content $seedPath -Raw)"
        }
    }

    # Common context for all assessors
    $commonContext = @"
PROJECT DIRECTORY: $projectDir
SCENARIO: $scenario
$seedInfo

RULES:
- Explore the project quickly (file tree, README, package.json/pyproject.toml, key config files).
- Spend max 2 minutes exploring. Be efficient.
- Write your assessment as Markdown to the specified output file.
- After writing, stop. Do not modify any project files.
"@

    # --- Tech Assessor ---
    $techPrompt = @"
You are the TECHNICAL FEASIBILITY ASSESSOR on a planning board.

$commonContext

YOUR TASK:
Assess whether this scenario is technically feasible in the current codebase.

WRITE YOUR ASSESSMENT TO: $planDir\tech-assessment.md

INCLUDE:
1. Tech stack summary (language, framework, key dependencies)
2. Files that would need to change (list them)
3. Estimated number of files to create/modify
4. Technical complexity (low/medium/high/extreme)
5. Missing dependencies or infrastructure needed
6. Technical blockers or unknowns
7. Your verdict: feasible / challenging / infeasible

Be specific. Reference actual files and code patterns you found.
After writing the file, say "Assessment written" and stop.
"@

    # --- Scope Assessor ---
    $scopePrompt = @"
You are the SCOPE ASSESSOR on a planning board.

$commonContext

YOUR TASK:
Assess whether the scope is right for a single team run (2-4 agents, <2 hours).

WRITE YOUR ASSESSMENT TO: $planDir\scope-assessment.md

INCLUDE:
1. How many distinct roles are needed? (max 5 per team)
2. How many tasks? (max 3 per role)
3. Can this be done in one team run, or should it be phased?
4. If phased, what's Phase 1 (minimum viable)?
5. Are there parallel work streams possible?
6. Dependencies between tasks (what blocks what?)
7. Your verdict: right-sized / needs-reduction / needs-phasing

Be practical. A team run should produce a shippable result, not a half-done mess.
After writing the file, say "Assessment written" and stop.
"@

    # --- Risk Assessor ---
    $riskPrompt = @"
You are the RISK ASSESSOR on a planning board.

$commonContext

YOUR TASK:
Identify what could go wrong if a team of agents attempts this.

WRITE YOUR ASSESSMENT TO: $planDir\risk-assessment.md

INCLUDE:
1. Breaking change risks (will this break existing functionality?)
2. File conflict risks (will multiple agents need the same files?)
3. Missing test coverage for affected areas
4. Security concerns (auth changes, data exposure, injection risks)
5. Dependency risks (new packages, version conflicts)
6. Integration risks (does this touch APIs, databases, external services?)
7. Rollback difficulty (how hard to undo if it goes wrong?)
8. Your verdict: low-risk / medium-risk / high-risk / showstopper

Be pessimistic. Your job is to find problems before agents waste tokens on them.
After writing the file, say "Assessment written" and stop.
"@

    # --- Synthesizer ---
    $synthPrompt = @"
You are the SYNTHESIZER on a planning board.

$commonContext

YOUR TASK:
1. Read all 3 assessment files (they are already complete):
   - $planDir\tech-assessment.md
   - $planDir\scope-assessment.md
   - $planDir\risk-assessment.md

2. Synthesize into a SINGLE proposed-plan.json at: $planDir\proposed-plan.json

OUTPUT FORMAT (proposed-plan.json):
{
  "scenario": "$scenario",
  "feasibility": {
    "verdict": "go|risky|no-go",
    "confidence": 0.0-1.0,
    "concerns": ["combined concerns from all assessors"],
    "recommendation": "what to do",
    "alternative": "simpler approach or null",
    "assessor_verdicts": {
      "technical": "feasible|challenging|infeasible",
      "scope": "right-sized|needs-reduction|needs-phasing",
      "risk": "low-risk|medium-risk|high-risk|showstopper"
    }
  },
  "rationale": "1-2 sentences on why this team structure",
  "roles": [
    {
      "key": "role-key",
      "description": "what this role does for THIS specific task",
      "model": null,
      "why": "why this role is needed"
    }
  ],
  "tasks": [
    {
      "id": "task-id",
      "title": "specific task title",
      "assigned_to": "role-key",
      "depends_on": [],
      "acceptance_criteria": [
        "Specific verifiable criterion 1",
        "Specific verifiable criterion 2"
      ]
    }
  ]
}

RULES:
- verdict = "go" if all assessors are positive (confidence > 0.7)
- verdict = "risky" if any assessor flags concerns (confidence 0.3-0.7)
- verdict = "no-go" if any assessor says infeasible/showstopper (confidence < 0.3)
- Every task MUST have 2-5 acceptance criteria
- Max 5 roles, max 3 tasks per role
- If scope assessor says "needs-phasing", only plan Phase 1
- Be honest. Don't create an optimistic plan that ignores assessor warnings.

After writing proposed-plan.json, say "Plan written to proposed-plan.json" and stop.
"@

    # Write all prompt files
    Set-Content (Join-Path $planDir "tech-assessor.prompt") $techPrompt -Encoding UTF8
    Set-Content (Join-Path $planDir "scope-assessor.prompt") $scopePrompt -Encoding UTF8
    Set-Content (Join-Path $planDir "risk-assessor.prompt") $riskPrompt -Encoding UTF8
    Set-Content (Join-Path $planDir "synthesizer.prompt") $synthPrompt -Encoding UTF8

    # Write launcher scripts with .done signals
    foreach ($role in @("tech-assessor", "scope-assessor", "risk-assessor", "synthesizer")) {
        $promptFile = Join-Path $planDir "$role.prompt"
        $doneFile = Join-Path $planDir "$role.done"
        $launcherScript = @"
Set-Location '$($projectDir -replace "'","''")'
Start-Transcript -Path '$($planDir -replace "'","''")\$role.log' -Append
`$promptText = Get-Content '$($promptFile -replace "'","''")' -Raw
copilot -i `$promptText --add-dir '$($planDir -replace "'","''")' --yolo
Stop-Transcript
Set-Content '$($doneFile -replace "'","''")' (Get-Date -Format 'o') -Encoding UTF8
"@
        Set-Content (Join-Path $planDir "launch-$role.ps1") $launcherScript -Encoding UTF8
    }

    # Spawn assessors in parallel
    Write-Host ""
    Write-Host "  `u{1F50D} Planning board for: $scenario" -ForegroundColor Cyan
    Write-Host ""

    foreach ($role in @("tech-assessor", "scope-assessor", "risk-assessor")) {
        $launcherFile = Join-Path $planDir "launch-$role.ps1"
        $title = switch ($role) {
            "tech-assessor"  { "Tech Assessor" }
            "scope-assessor" { "Scope Assessor" }
            "risk-assessor"  { "Risk Assessor" }
        }
        Start-Process "wt.exe" -ArgumentList "-w 0 new-tab --title `"$title (planning)`" pwsh -File `"$launcherFile`""
        $desc = switch ($role) {
            "tech-assessor"  { "analyzing codebase and complexity" }
            "scope-assessor" { "evaluating scope and phasing" }
            "risk-assessor"  { "identifying risks and blockers" }
        }
        Write-Host "  `u{1F7E2} $title `u{2014} $desc" -ForegroundColor Green
        Start-Sleep -Milliseconds 800
    }

    # Poll for assessor completion, then spawn synthesizer
    Write-Host ""
    $startTime = Get-Date
    $assessorRoles = @("tech-assessor", "scope-assessor", "risk-assessor")
    $synthLaunched = $false

    while ($true) {
        Start-Sleep 5
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)

        # Check assessor .done files
        $assessorsDone = @()
        foreach ($role in $assessorRoles) {
            $doneFile = Join-Path $planDir "$role.done"
            if (Test-Path $doneFile) { $assessorsDone += $role }
        }

        # If all assessors done and synthesizer not launched, launch it
        if ($assessorsDone.Count -eq 3 -and -not $synthLaunched) {
            $synthLauncher = Join-Path $planDir "launch-synthesizer.ps1"
            Start-Process "wt.exe" -ArgumentList "-w 0 new-tab --title `"Synthesizer (planning)`" pwsh -File `"$synthLauncher`""
            $synthLaunched = $true
            Write-Host "`n  `u{1F7E2} Synthesizer `u{2014} launched (all assessments ready)" -ForegroundColor Yellow
        }

        # Check synthesizer done
        $synthDone = Test-Path (Join-Path $planDir "synthesizer.done")

        # Display progress
        Write-Host "`r  Progress ($($elapsed)s):" -NoNewline -ForegroundColor Gray
        foreach ($role in $assessorRoles) {
            if ($assessorsDone -contains $role) {
                Write-Host " `u{2705}$role" -NoNewline -ForegroundColor Green
            } else {
                Write-Host " `u{1F504}$role" -NoNewline -ForegroundColor Yellow
            }
        }
        if ($synthLaunched -and $synthDone) {
            Write-Host " `u{2705}synthesizer" -NoNewline -ForegroundColor Green
        } elseif ($synthLaunched) {
            Write-Host " `u{1F504}synthesizer" -NoNewline -ForegroundColor Yellow
        } else {
            Write-Host " `u{23F8}`u{FE0F}synth" -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ""

        if ($synthDone) { break }

        # Timeout after 10 minutes
        if ($elapsed -gt 600) {
            Write-Host "`n  `u{26A0}`u{FE0F}  Planning timed out after 10 minutes." -ForegroundColor Red
            break
        }
    }

    Write-Host ""
    Write-Host "  `u{2705} Plan ready! Run: team apply" -ForegroundColor Green
    Write-Host ""
}


# ── apply ────────────────────────────────────────────────────────────────────
# Reads a proposed plan from .agent-teams/.plan/proposed-plan.json, shows it
# for approval, and creates the team with roles, tasks, and acceptance criteria.
function Invoke-Apply {
    $projectDir = (Get-Location).Path
    $planFile = Join-Path $projectDir ".agent-teams\.plan\proposed-plan.json"

    if (-not (Test-Path $planFile)) {
        Write-Host "  No plan found. Run 'team plan <scenario>' first." -ForegroundColor Yellow
        return
    }

    $plan = Read-Json $planFile

    # Show the plan for review
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  PROPOSED PLAN                               ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Scenario:  $($plan.scenario)" -ForegroundColor White
    Write-Host "  Rationale: $($plan.rationale)" -ForegroundColor Gray
    Write-Host ""

    # Show feasibility assessment
    if ($plan.feasibility) {
        $f = $plan.feasibility
        $verdictIcon = switch ($f.verdict) {
            "go"    { "✅" }
            "risky" { "⚠️" }
            "no-go" { "🛑" }
            default { "❓" }
        }
        $verdictColor = switch ($f.verdict) {
            "go"    { "Green" }
            "risky" { "Yellow" }
            "no-go" { "Red" }
            default { "Gray" }
        }
        
        $confidencePct = [math]::Round($f.confidence * 100)
        Write-Host ""
        Write-Host "  FEASIBILITY" -ForegroundColor Yellow
        Write-Host "    $verdictIcon $($f.verdict.ToUpper()) (confidence: $confidencePct%)" -ForegroundColor $verdictColor
        
        if ($f.concerns) {
            Write-Host ""
            foreach ($concern in $f.concerns) {
                Write-Host "    • $concern" -ForegroundColor $verdictColor
            }
        }
        
        if ($f.recommendation) {
            Write-Host ""
            Write-Host "    Recommendation: $($f.recommendation)" -ForegroundColor White
        }
        
        if ($f.alternative) {
            Write-Host "    Alternative: $($f.alternative)" -ForegroundColor Cyan
        }
        Write-Host ""
        
        # Block on no-go
        if ($f.verdict -eq "no-go") {
            Write-Host "  🛑 Plan is marked NO-GO. Review concerns above." -ForegroundColor Red
            Write-Host "  Edit .agent-teams/.plan/proposed-plan.json to override, or run 'team plan' with a different scope." -ForegroundColor Gray
            $override = Read-Host "  Force apply anyway? [y/N]"
            if ($override -ne 'y') { return }
        }
    }

    Write-Host "  ROLES" -ForegroundColor Yellow
    foreach ($role in $plan.roles) {
        $modelTag = if ($role.model) { " [$($role.model)]" } else { "" }
        Write-Host "    $($role.key): $($role.description)$modelTag" -ForegroundColor White
        Write-Host "      Why: $($role.why)" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "  TASKS" -ForegroundColor Yellow
    foreach ($task in $plan.tasks) {
        $deps = if (@($task.depends_on).Count -gt 0) { " (`u{2190} $($task.depends_on -join ', '))" } else { "" }
        Write-Host "    $($task.id) `u{2192} $($task.assigned_to)$deps" -ForegroundColor White
        Write-Host "       $($task.title)" -ForegroundColor DarkGray
        if ($task.acceptance_criteria) {
            foreach ($ac in $task.acceptance_criteria) {
                Write-Host "       `u{2610} $ac" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""

    $confirm = Read-Host "  Apply this plan? [Y/n]"
    if ($confirm -eq 'n') {
        Write-Host "  Plan not applied. Edit .agent-teams/.plan/proposed-plan.json and run 'team apply' again." -ForegroundColor Yellow
        return
    }

    # Auto-generate team name from scenario (slugify: lowercase, replace non-alphanumeric with hyphens, trim)
    $autoName = ($plan.scenario -replace '[^a-zA-Z0-9\s]', '' -replace '\s+', '-').ToLower()
    if ($autoName.Length -gt 30) { $autoName = $autoName.Substring(0, 30) -replace '-$', '' }
    $teamName = Read-Host "  Team name (default: $autoName)"
    if (-not $teamName) { $teamName = $autoName }

    # Init team
    Invoke-Init $teamName $plan.scenario

    # Create roles
    foreach ($role in $plan.roles) {
        $model = $null
        if ($role.model) { $model = $role.model }
        Invoke-Role $teamName $role.key $role.description $model
    }

    # Create tasks
    foreach ($task in $plan.tasks) {
        $deps = if (@($task.depends_on).Count -gt 0) { ($task.depends_on -join ",") } else { $null }
        Invoke-Task $teamName $task.id $task.title $task.assigned_to $deps
    }

    # Store acceptance criteria in tasks.json
    $tasksObj = Get-Tasks $teamName
    foreach ($planTask in $plan.tasks) {
        $match = $tasksObj.tasks | Where-Object { $_.id -eq $planTask.id }
        if ($match -and $planTask.acceptance_criteria) {
            $match | Add-Member -NotePropertyName "acceptance_criteria" -NotePropertyValue @($planTask.acceptance_criteria) -Force
        }
    }
    Save-Tasks $teamName $tasksObj

    Write-Host ""
    # Show status
    Invoke-Status $teamName

    Write-Host "  Ready! Run 'team launch $teamName' to start." -ForegroundColor Green
    Write-Host ""

    # Clean up plan directory
    $planDir = Join-Path (Get-Location).Path ".agent-teams\.plan"
    if (Test-Path $planDir) {
        Remove-Item $planDir -Recurse -Force
        Write-Host "  🗑️  Plan directory cleaned up." -ForegroundColor Gray
    }
    Write-Host ""
}

# ── unblock ──────────────────────────────────────────────────────────────────
# Checks blocked tasks and transitions them to pending if all dependencies are done.
# Notifies downstream agents via their mailbox.
function Invoke-Unblock([string]$teamName) {
    if (-not $teamName) {
        Write-Host "  Usage: team unblock <name>" -ForegroundColor Yellow
        return
    }
    Assert-TeamExists $teamName

    $tasksObj = Get-Tasks $teamName
    $teamDir  = Get-TeamDir $teamName
    $unblocked = @()

    foreach ($task in $tasksObj.tasks) {
        if ($task.status -ne "blocked") { continue }

        $deps = @($task.depends_on)
        if ($deps.Count -eq 0) {
            # No deps but marked blocked — unblock it
            $task.status = "pending"
            $unblocked += $task
            continue
        }

        $allDone = $true
        foreach ($depId in $deps) {
            $depTask = $tasksObj.tasks | Where-Object { $_.id -eq $depId }
            if (-not $depTask -or $depTask.status -ne "done") {
                $allDone = $false
                break
            }
        }

        if ($allDone) {
            $task.status = "pending"
            $unblocked += $task
        }
    }

    if ($unblocked.Count -eq 0) {
        Write-Host "  No tasks were unblocked. Dependencies not yet met." -ForegroundColor Yellow
        return
    }

    Save-Tasks $teamName $tasksObj

    # Notify agents via mailbox
    $mailboxDir = Join-Path $teamDir "mailbox"
    if (-not (Test-Path $mailboxDir)) {
        New-Item -ItemType Directory -Force -Path $mailboxDir | Out-Null
    }

    $now = Get-Date -Format "o"
    foreach ($task in $unblocked) {
        $inboxPath = Join-Path $mailboxDir "$($task.assigned_to).inbox"
        $msg = @"
[FROM: lead] [TIME: $now]
Your task "$($task.id)" is now unblocked. Dependencies complete. Begin work.
---
"@
        Add-Content $inboxPath $msg -Encoding UTF8
    }

    Write-Host ""
    foreach ($task in $unblocked) {
        Write-Host "  `u{2705} $($task.id) `u{2192} $($task.assigned_to) [unblocked]" -ForegroundColor Green
    }
    Write-Host ""
}

# ── Main Dispatch ───────────────────────────────────────────────────────────
# IMPORTANT: Use $args[N] directly — do NOT assign to intermediate variable.
# PowerShell has a scalar coercion bug when slicing single-element arrays.

switch ($args[0]) {
    "init"   { Invoke-Init   $args[1] $args[2] $args[3] }
    "role"   { Invoke-Role   $args[1] $args[2] $args[3] $args[4] }
    "task"   { Invoke-Task   $args[1] $args[2] $args[3] $args[4] $args[5] }
    "launch" { Invoke-Launch $args[1] $args[2] }
    "status" { Invoke-Status $args[1] }
    "watch"  { Invoke-Watch  $args[1] }
    "list"   { Invoke-List }
    "clean"   { Invoke-Clean   $args[1] }
    "unblock" { Invoke-Unblock $args[1] }
    "plan"    { Invoke-Plan   $args[1] $args[2] }
    "apply"  { Invoke-Apply }
    default  { Show-Help }
}
