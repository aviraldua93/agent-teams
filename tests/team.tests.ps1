#!/usr/bin/env pwsh
# Pester v5 tests for agent-teams CLI (team.ps1)
# Covers all non-interactive commands: init, role, task, status, list, clean, unblock

BeforeAll {
    $Script:TeamScript = Join-Path $PSScriptRoot "..\team.ps1"
    $Script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "agent-teams-test-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $Script:TestDir | Out-Null
}

AfterAll {
    Remove-Item $Script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ── init ────────────────────────────────────────────────────────────────────

Describe "team init" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "creates team directory structure" {
        & $Script:TeamScript init "test-team" "Test scenario" 6>&1 | Out-Null
        ".agent-teams\test-team" | Should -Exist
        ".agent-teams\test-team\manifest.json" | Should -Exist
        ".agent-teams\test-team\tasks.json" | Should -Exist
        ".agent-teams\test-team\protocol.md" | Should -Exist
        ".agent-teams\test-team\artifacts" | Should -Exist
        ".agent-teams\test-team\mailbox" | Should -Exist
        ".agent-teams\test-team\roles" | Should -Exist
        ".agent-teams\test-team\heartbeat" | Should -Exist
        ".agent-teams\test-team\logs" | Should -Exist
        ".agent-teams\test-team\.launch" | Should -Exist
    }

    It "stores correct manifest data" {
        & $Script:TeamScript init "test-team" "Build a thing" 6>&1 | Out-Null
        $manifest = Get-Content ".agent-teams\test-team\manifest.json" -Raw | ConvertFrom-Json
        $manifest.team | Should -Be "test-team"
        $manifest.scenario | Should -Be "Build a thing"
        $manifest.project_dir | Should -Be $Script:TestDir
        $manifest.roles | Should -Not -Be $null
    }

    It "creates tasks.json with empty tasks array" {
        & $Script:TeamScript init "test-team" "A scenario" 6>&1 | Out-Null
        $tasks = Get-Content ".agent-teams\test-team\tasks.json" -Raw | ConvertFrom-Json
        @($tasks.tasks).Count | Should -Be 0
    }

    It "creates protocol.md from template" {
        & $Script:TeamScript init "test-team" "A scenario" 6>&1 | Out-Null
        $protocol = Get-Content ".agent-teams\test-team\protocol.md" -Raw
        # The template replaces {team-name} with the actual team name
        $protocol | Should -Match "test-team"
    }

    It "pre-creates mailbox/lead.inbox" {
        & $Script:TeamScript init "test-team" "A scenario" 6>&1 | Out-Null
        ".agent-teams\test-team\mailbox\lead.inbox" | Should -Exist
    }

    It "fails gracefully if team already exists" {
        & $Script:TeamScript init "test-team" "First" 6>&1 | Out-Null
        $output = & $Script:TeamScript init "test-team" "Second" 6>&1
        $output | Should -Match "already exists"
    }

    It "stores created timestamp in manifest" {
        & $Script:TeamScript init "test-team" "A scenario" 6>&1 | Out-Null
        $manifest = Get-Content ".agent-teams\test-team\manifest.json" -Raw | ConvertFrom-Json
        $manifest.created | Should -Not -BeNullOrEmpty
    }
}

# ── role ────────────────────────────────────────────────────────────────────

Describe "team role" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
        & $Script:TeamScript init "test-team" "Test scenario" 6>&1 | Out-Null
    }

    It "adds role to manifest.json" {
        & $Script:TeamScript role "test-team" "architect" "Designs the architecture" 6>&1 | Out-Null
        $manifest = Get-Content ".agent-teams\test-team\manifest.json" -Raw | ConvertFrom-Json
        $manifest.roles.architect | Should -Not -BeNullOrEmpty
        $manifest.roles.architect.description | Should -Be "Designs the architecture"
    }

    It "creates role file at roles/{key}.md" {
        & $Script:TeamScript role "test-team" "architect" "Designs the architecture" 6>&1 | Out-Null
        ".agent-teams\test-team\roles\architect.md" | Should -Exist
    }

    It "role file contains correct YAML frontmatter" {
        & $Script:TeamScript role "test-team" "lead-dev" "Leads development" "claude-opus-4" 6>&1 | Out-Null
        $content = Get-Content ".agent-teams\test-team\roles\lead-dev.md" -Raw
        $content | Should -Match "name: Lead Dev"
        $content | Should -Match "key: lead-dev"
        $content | Should -Match "description: Leads development"
        $content | Should -Match "model: claude-opus-4"
    }

    It "uses default model when none specified" {
        & $Script:TeamScript role "test-team" "coder" "Writes code" 6>&1 | Out-Null
        $content = Get-Content ".agent-teams\test-team\roles\coder.md" -Raw
        $content | Should -Match "model: claude-sonnet-4"
    }

    It "stores role_file path in manifest" {
        & $Script:TeamScript role "test-team" "architect" "Designs things" 6>&1 | Out-Null
        $manifest = Get-Content ".agent-teams\test-team\manifest.json" -Raw | ConvertFrom-Json
        $manifest.roles.architect.role_file | Should -Be "roles/architect.md"
    }

    It "fails if team doesn't exist" {
        & $Script:TeamScript role "nonexistent" "key" "desc" 6>&1 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}

# ── task ────────────────────────────────────────────────────────────────────

Describe "team task" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
        & $Script:TeamScript init "test-team" "Test scenario" 6>&1 | Out-Null
        & $Script:TeamScript role "test-team" "architect" "Designs things" 6>&1 | Out-Null
        & $Script:TeamScript role "test-team" "coder" "Writes code" 6>&1 | Out-Null
    }

    It "adds task to tasks.json with correct fields" {
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        $tasks = Get-Content ".agent-teams\test-team\tasks.json" -Raw | ConvertFrom-Json
        $task = $tasks.tasks | Where-Object { $_.id -eq "design-spec" }
        $task | Should -Not -BeNullOrEmpty
        $task.title | Should -Be "Design the spec"
        $task.assigned_to | Should -Be "architect"
    }

    It "sets status to pending when no deps" {
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        $tasks = Get-Content ".agent-teams\test-team\tasks.json" -Raw | ConvertFrom-Json
        $task = $tasks.tasks | Where-Object { $_.id -eq "design-spec" }
        $task.status | Should -Be "pending"
    }

    It "sets status to blocked when deps specified" {
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        & $Script:TeamScript task "test-team" "implement" "Build it" "coder" "design-spec" 6>&1 | Out-Null
        $tasks = Get-Content ".agent-teams\test-team\tasks.json" -Raw | ConvertFrom-Json
        $task = $tasks.tasks | Where-Object { $_.id -eq "implement" }
        $task.status | Should -Be "blocked"
        @($task.depends_on) | Should -Contain "design-spec"
    }

    It "sets deliverable to artifacts/{id}.md" {
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        $tasks = Get-Content ".agent-teams\test-team\tasks.json" -Raw | ConvertFrom-Json
        $task = $tasks.tasks | Where-Object { $_.id -eq "design-spec" }
        $task.deliverable | Should -Be "artifacts/design-spec.md"
    }

    It "auto-adds deliverable to role's owns_files in manifest" {
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        $manifest = Get-Content ".agent-teams\test-team\manifest.json" -Raw | ConvertFrom-Json
        @($manifest.roles.architect.owns_files) | Should -Contain "artifacts/design-spec.md"
    }

    It "auto-adds deliverable to role file frontmatter" {
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        $content = Get-Content ".agent-teams\test-team\roles\architect.md" -Raw
        $content | Should -Match "artifacts/design-spec.md"
    }

    It "fails if team doesn't exist" {
        & $Script:TeamScript task "nonexistent" "t1" "title" "role" 6>&1 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}

# ── status ──────────────────────────────────────────────────────────────────

Describe "team status" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
        & $Script:TeamScript init "test-team" "Test scenario" 6>&1 | Out-Null
        & $Script:TeamScript role "test-team" "architect" "Designs things" 6>&1 | Out-Null
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
    }

    It "shows team name" {
        $output = & $Script:TeamScript status "test-team" 6>&1
        ($output | Out-String) | Should -Match "test-team"
    }

    It "shows scenario" {
        $output = & $Script:TeamScript status "test-team" 6>&1
        ($output | Out-String) | Should -Match "Test scenario"
    }

    It "shows roles" {
        $output = & $Script:TeamScript status "test-team" 6>&1
        ($output | Out-String) | Should -Match "architect"
    }

    It "shows tasks" {
        $output = & $Script:TeamScript status "test-team" 6>&1
        ($output | Out-String) | Should -Match "design-spec"
    }

    It "shows progress count correctly" {
        $output = & $Script:TeamScript status "test-team" 6>&1
        ($output | Out-String) | Should -Match "0/1 tasks done"
    }
}

# ── list ────────────────────────────────────────────────────────────────────

Describe "team list" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "shows no teams when empty" {
        $output = & $Script:TeamScript list 6>&1
        ($output | Out-String) | Should -Match "\(no teams\)"
    }

    It "lists teams in current directory" {
        & $Script:TeamScript init "alpha" "First team" 6>&1 | Out-Null
        & $Script:TeamScript init "beta" "Second team" 6>&1 | Out-Null
        $output = & $Script:TeamScript list 6>&1
        $text = $output | Out-String
        $text | Should -Match "alpha"
        $text | Should -Match "beta"
    }
}

# ── clean ───────────────────────────────────────────────────────────────────

Describe "team clean" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "removes team directory" {
        & $Script:TeamScript init "test-team" "A scenario" 6>&1 | Out-Null
        ".agent-teams\test-team" | Should -Exist
        & $Script:TeamScript clean "test-team" 6>&1 | Out-Null
        ".agent-teams\test-team" | Should -Not -Exist
    }

    It "shows message for non-existent team" {
        $output = & $Script:TeamScript clean "nonexistent" 6>&1
        ($output | Out-String) | Should -Match "not found"
    }
}

# ── unblock ─────────────────────────────────────────────────────────────────

Describe "team unblock" {
    BeforeEach {
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue
        & $Script:TeamScript init "test-team" "Test scenario" 6>&1 | Out-Null
        & $Script:TeamScript role "test-team" "architect" "Designs things" 6>&1 | Out-Null
        & $Script:TeamScript role "test-team" "coder" "Writes code" 6>&1 | Out-Null
        & $Script:TeamScript task "test-team" "design-spec" "Design the spec" "architect" 6>&1 | Out-Null
        & $Script:TeamScript task "test-team" "implement" "Build it" "coder" "design-spec" 6>&1 | Out-Null
    }

    It "does NOT transition when deps aren't done" {
        & $Script:TeamScript unblock "test-team" 6>&1 | Out-Null
        $tasks = Get-Content ".agent-teams\test-team\tasks.json" -Raw | ConvertFrom-Json
        $task = $tasks.tasks | Where-Object { $_.id -eq "implement" }
        $task.status | Should -Be "blocked"
    }

    It "transitions blocked→pending when deps are done" {
        # Manually mark dependency as done
        $tasksPath = ".agent-teams\test-team\tasks.json"
        $tasksObj = Get-Content $tasksPath -Raw | ConvertFrom-Json
        ($tasksObj.tasks | Where-Object { $_.id -eq "design-spec" }).status = "done"
        $tasksObj | ConvertTo-Json -Depth 10 | Set-Content $tasksPath -Encoding UTF8

        & $Script:TeamScript unblock "test-team" 6>&1 | Out-Null

        $tasks = Get-Content $tasksPath -Raw | ConvertFrom-Json
        $task = $tasks.tasks | Where-Object { $_.id -eq "implement" }
        $task.status | Should -Be "pending"
    }

    It "writes notification to role's mailbox inbox" {
        # Mark dependency as done
        $tasksPath = ".agent-teams\test-team\tasks.json"
        $tasksObj = Get-Content $tasksPath -Raw | ConvertFrom-Json
        ($tasksObj.tasks | Where-Object { $_.id -eq "design-spec" }).status = "done"
        $tasksObj | ConvertTo-Json -Depth 10 | Set-Content $tasksPath -Encoding UTF8

        & $Script:TeamScript unblock "test-team" 6>&1 | Out-Null

        $inboxPath = ".agent-teams\test-team\mailbox\coder.inbox"
        $inboxPath | Should -Exist
        $content = Get-Content $inboxPath -Raw
        $content | Should -Match "implement"
        $content | Should -Match "unblocked"
    }
}

# ── Template init ───────────────────────────────────────────────────────────

Describe "template init" {
    $templateCases = @(
        @{ Name = "feature";   ExpectedRoles = 3; ExpectedTasks = 4 }
        @{ Name = "bugfix";    ExpectedRoles = 3; ExpectedTasks = 3 }
        @{ Name = "research";  ExpectedRoles = 4; ExpectedTasks = 4 }
        @{ Name = "refactor";  ExpectedRoles = 4; ExpectedTasks = 4 }
        @{ Name = "fullstack"; ExpectedRoles = 4; ExpectedTasks = 4 }
        @{ Name = "sprint";    ExpectedRoles = 5; ExpectedTasks = 5 }
        @{ Name = "ship";      ExpectedRoles = 3; ExpectedTasks = 3 }
        @{ Name = "audit";          ExpectedRoles = 4; ExpectedTasks = 4 }
        @{ Name = "data-science";   ExpectedRoles = 4; ExpectedTasks = 5 }
        @{ Name = "ml-experiment";  ExpectedRoles = 4; ExpectedTasks = 4 }
        @{ Name = "data-pipeline";  ExpectedRoles = 4; ExpectedTasks = 4 }
        @{ Name = "doc-review";     ExpectedRoles = 5; ExpectedTasks = 5 }
    )

    It "template '<Name>' creates <ExpectedRoles> roles and <ExpectedTasks> tasks" -TestCases $templateCases {
        param($Name, $ExpectedRoles, $ExpectedTasks)
        Set-Location $Script:TestDir
        Remove-Item ".agent-teams" -Recurse -Force -ErrorAction SilentlyContinue

        & $Script:TeamScript init "tpl-$Name" "Test $Name template" $Name 6>&1 | Out-Null

        $manifest = Get-Content ".agent-teams\tpl-$Name\manifest.json" -Raw | ConvertFrom-Json
        $roleCount = @($manifest.roles.PSObject.Properties).Count
        $roleCount | Should -Be $ExpectedRoles

        $tasksObj = Get-Content ".agent-teams\tpl-$Name\tasks.json" -Raw | ConvertFrom-Json
        @($tasksObj.tasks).Count | Should -Be $ExpectedTasks
    }
}
