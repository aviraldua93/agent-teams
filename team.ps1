#!/usr/bin/env pwsh
# ============================================================================
# team.ps1 — Agent Teams for GitHub Copilot CLI
# Version: 0.3.0
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
$TeamsRoot = Join-Path $env:USERPROFILE ".copilot\teams"
$TemplatesDir = Join-Path $TeamsRoot "templates"

# ── Helpers ─────────────────────────────────────────────────────────────────

function Get-TeamDir([string]$teamName) {
    return Join-Path $TeamsRoot $teamName
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
function Invoke-Init([string]$teamName, [string]$scenario) {
    if (-not $teamName -or -not $scenario) {
        Write-Host "  Usage: team init <name> <scenario>" -ForegroundColor Yellow
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
    $allowedTools = @("Read", "glob", "grep", "explore")

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

# ── launch ──────────────────────────────────────────────────────────────────
# Spawns Copilot CLI sessions in new terminal tabs. Each agent gets:
#   - A prompt pointing to its role file (roles/{key}.md)
#   - Heartbeat instructions (agent writes heartbeat/{key}.json periodically)
#   - Tool permission constraints from allowed_tools
#   - Session logging via Tee-Object to logs/{key}.log
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

    $roles = $manifest.roles.PSObject.Properties
    if ($specificRole) {
        $roles = @($roles | Where-Object { $_.Name -eq $specificRole })
        if ($roles.Count -eq 0) {
            Write-Host "  Error: Role '$specificRole' not found in team '$teamName'" -ForegroundColor Red
            return
        }
    }

    Write-Host ""
    Write-Host "  🚀 Launching team '$teamName'" -ForegroundColor Cyan
    Write-Host ""

    foreach ($roleProp in $roles) {
        $key  = $roleProp.Name
        $role = $roleProp.Value

        # ── Resolve role file for instructions ─────────────────────────────
        $roleFilePath = Join-Path $teamDir "roles\$key.md"
        $roleInstructions = ""
        if (Test-Path $roleFilePath) {
            $roleInstructions = Read-RoleBody $roleFilePath
        }

        # ── Build tool permissions block ───────────────────────────────────
        $toolsList = @($role.allowed_tools)
        $toolsBlock = ""
        if ($toolsList.Count -gt 0) {
            $toolLines = ($toolsList | ForEach-Object { "  - $_" }) -join "`n"
            $toolsBlock = @"

YOUR ALLOWED TOOLS (use only these):
$toolLines
"@
        }

        # ── Build file ownership block ─────────────────────────────────────
        $ownsList  = (@($role.owns_files)  | ForEach-Object { "  - $_" }) -join "`n"
        $readsList = (@($role.reads_from)  | ForEach-Object { "  - $_" }) -join "`n"

        # ── Heartbeat instructions ─────────────────────────────────────────
        $heartbeatPath = "$teamDir\heartbeat\$key.json"
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

        # ── Compose the full prompt ────────────────────────────────────────
        $prompt = @"
You are the $($role.name) on agent team "$teamName".

TEAM DIRECTORY: $teamDir
PROJECT DIRECTORY: $projectDir

YOUR ROLE FILE: $roleFilePath
Read this file for your full role definition and instructions.

YOUR STARTUP SEQUENCE:
1. Read $teamDir\protocol.md for your operating rules.
2. Read your role file at $roleFilePath for your specific instructions.
3. Read $teamDir\manifest.json and find your role "$key" under "roles".
4. Read $teamDir\tasks.json and find tasks where assigned_to is "$key".
5. Write your initial heartbeat to $heartbeatPath.
6. Execute your tasks following the protocol. Write deliverables to artifacts/.

SCENARIO: $($manifest.scenario)

YOUR ROLE: $($role.description)
$toolsBlock

FILES YOU OWN (only you write these):
$ownsList

FILES YOU READ FROM:
$readsList
$heartbeatBlock

$roleInstructions

IMPORTANT: Begin by reading protocol.md now. Then read your role file, then tasks.json, then start working.
"@

        # Write prompt to file (avoids quoting hell in process args)
        $promptFile = Join-Path $launchDir "$key.prompt"
        Set-Content $promptFile $prompt -Encoding UTF8

        # ── Write launcher script ──────────────────────────────────────────
        # The launcher: sets dir, runs copilot, tees output to logs/{key}.log
        $modelFlag = if ($role.model) { " --model `"$($role.model)`"" } else { "" }
        $logFile = "$teamDir\logs\$key.log"

        $launcherScript = @"
Set-Location '$($projectDir -replace "'","''")'
`$promptText = Get-Content '$($promptFile -replace "'","''")' -Raw
copilot -i `$promptText --add-dir '$($teamDir -replace "'","''")'$modelFlag 2>&1 | Tee-Object -FilePath '$($logFile -replace "'","''")'
"@
        $launcherFile = Join-Path $launchDir "launch-$key.ps1"
        Set-Content $launcherFile $launcherScript -Encoding UTF8

        # ── Spawn terminal tab ─────────────────────────────────────────────
        $tabTitle = "$($role.name) ($teamName)"
        Start-Process "wt.exe" -ArgumentList "-w 0 new-tab --title `"$tabTitle`" pwsh -NoExit -File `"$launcherFile`""

        Write-Host "  🟢 $($role.name) ($key)" -ForegroundColor Green
        Start-Sleep -Milliseconds 800  # stagger to avoid terminal race
    }

    Write-Host ""
    Write-Host "  All agents launched! Check your terminal tabs." -ForegroundColor Cyan
    Write-Host "  Run 'team status $teamName' to monitor progress." -ForegroundColor Gray
    Write-Host ""
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
    $teams = Get-ChildItem $TeamsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "templates" -and $_.Name -ne "bin" }
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
    Write-Host "  ║  Agent Teams for GitHub Copilot CLI   v0.3  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  COMMANDS" -ForegroundColor Yellow
    Write-Host "    init   <name> <scenario>                   Create a new team" -ForegroundColor White
    Write-Host "    role   <name> <key> <description> [model]  Add a role (generates role file)" -ForegroundColor White
    Write-Host "    task   <name> <id> <title> <role> [deps]   Add a task" -ForegroundColor White
    Write-Host "    launch <name> [role]                       Spawn agent tabs (with logs)" -ForegroundColor White
    Write-Host "    status <name>                              Dashboard with heartbeats" -ForegroundColor White
    Write-Host "    watch  <name>                              Live dashboard (refreshes 3s)" -ForegroundColor White
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
    Write-Host "    - agents coordinate via files in ~/.copilot/teams/<name>/" -ForegroundColor Gray
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

# ── Main Dispatch ───────────────────────────────────────────────────────────
# IMPORTANT: Use $args[N] directly — do NOT assign to intermediate variable.
# PowerShell has a scalar coercion bug when slicing single-element arrays.

switch ($args[0]) {
    "init"   { Invoke-Init   $args[1] $args[2] }
    "role"   { Invoke-Role   $args[1] $args[2] $args[3] $args[4] }
    "task"   { Invoke-Task   $args[1] $args[2] $args[3] $args[4] $args[5] }
    "launch" { Invoke-Launch $args[1] $args[2] }
    "status" { Invoke-Status $args[1] }
    "watch"  { Invoke-Watch  $args[1] }
    "list"   { Invoke-List }
    "clean"  { Invoke-Clean  $args[1] }
    default  { Show-Help }
}
