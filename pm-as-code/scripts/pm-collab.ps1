#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PMRoot = ".pm"
$script:Scope = if ($env:PM_SCOPE) { $env:PM_SCOPE } else { "default" }

$script:PMDir = ""
$script:LockDir = ""
$script:LockInfo = ""
$script:ClaimsFile = ""
$script:PulseFile = ""
$script:TicketsFile = ""

$script:LockWaitSeconds = 120
$script:LockStaleSeconds = 900
$script:LockPollSeconds = 1

if ($env:PM_LOCK_WAIT_SECONDS) {
    $script:LockWaitSeconds = [int]$env:PM_LOCK_WAIT_SECONDS
}
if ($env:PM_LOCK_STALE_SECONDS) {
    $script:LockStaleSeconds = [int]$env:PM_LOCK_STALE_SECONDS
}
if ($env:PM_LOCK_POLL_SECONDS) {
    $script:LockPollSeconds = [int]$env:PM_LOCK_POLL_SECONDS
}

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:PMTicket = Join-Path $script:ScriptDir "pm-ticket.ps1"
$script:LockToken = ""

function Write-Usage {
    @'
Usage:
  pm-collab.ps1 [--scope <name>] init
  pm-collab.ps1 [--scope <name>] claim <T-0001> [note]
  pm-collab.ps1 [--scope <name>] claim <agent> <T-0001> [note]
  pm-collab.ps1 [--scope <name>] unclaim <T-0001>
  pm-collab.ps1 [--scope <name>] unclaim <agent> <T-0001>
  pm-collab.ps1 [--scope <name>] claims
  pm-collab.ps1 [--scope <name>] run [<agent>] -- <pm-ticket command...>
  pm-collab.ps1 [--scope <name>] run <pm-ticket command...>
  pm-collab.ps1 [--scope <name>] lock-info
  pm-collab.ps1 [--scope <name>] unlock-stale

Examples:
  scripts/pm-collab.ps1 --scope backend init
  scripts/pm-collab.ps1 --scope backend run move T-0001 in-progress
  scripts/pm-collab.ps1 --scope backend run done T-0001 "src/api/auth.ts" "tests passed"
  scripts/pm-collab.ps1 --scope backend claim agent-a T-0001 "taking API task"
'@ | Write-Output
}

function Get-NowTs {
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

function Sanitize([string]$Text) {
    if ($null -eq $Text) {
        return ""
    }
    return ($Text -replace "`t", " " -replace "`r", " " -replace "`n", " ")
}

function Get-DefaultAgentName {
    if ($env:PM_AGENT) {
        return (Sanitize $env:PM_AGENT)
    }
    if ($env:CODEX_THREAD_ID) {
        $head = ($env:CODEX_THREAD_ID -split "-", 2)[0]
        return (Sanitize "codex-$head")
    }
    if ($env:CLAUDE_SESSION_ID) {
        $head = ($env:CLAUDE_SESSION_ID -split "-", 2)[0]
        return (Sanitize "claude-$head")
    }

    $parentPid = ""
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        if ($null -ne $proc -and $proc.ParentProcessId) {
            $parentPid = [string]$proc.ParentProcessId
        }
    } catch {
        $parentPid = ""
    }
    if ($parentPid -eq "") {
        $parentPid = [string]$PID
    }

    $user = if ($env:USERNAME) { $env:USERNAME } else { "agent" }
    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    return (Sanitize "$user@$hostName:$parentPid")
}

function Validate-ScopeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "error: scope cannot be empty"
    }
    if ($Name -notmatch "^[A-Za-z0-9._-]+$") {
        throw "error: invalid scope '$Name' (allowed: letters, digits, ., _, -)"
    }
}

function Parse-GlobalOptions([string[]]$InputArgs) {
    $remaining = [System.Collections.Generic.List[string]]::new()
    $i = 0

    while ($i -lt $InputArgs.Count) {
        $arg = $InputArgs[$i]
        if ($arg -eq "--scope") {
            if ($i + 1 -ge $InputArgs.Count) {
                throw "error: --scope requires a value"
            }
            $script:Scope = $InputArgs[$i + 1]
            $i += 2
            continue
        }
        if ($arg.StartsWith("--scope=")) {
            $script:Scope = $arg.Substring(8)
            $i += 1
            continue
        }
        if ($arg -eq "-h" -or $arg -eq "--help") {
            Write-Usage
            exit 0
        }
        if ($arg -eq "--") {
            for ($j = $i + 1; $j -lt $InputArgs.Count; $j++) {
                $remaining.Add($InputArgs[$j])
            }
            $i = $InputArgs.Count
            break
        }

        for ($j = $i; $j -lt $InputArgs.Count; $j++) {
            $remaining.Add($InputArgs[$j])
        }
        $i = $InputArgs.Count
        break
    }

    Validate-ScopeName $script:Scope
    return @($remaining.ToArray())
}

function Set-ScopePaths {
    $script:PMDir = Join-Path $PMRoot ("scopes/" + $script:Scope)
    $script:LockDir = Join-Path $script:PMDir ".collab-lock"
    $script:LockInfo = Join-Path $script:LockDir "lock.env"
    $script:ClaimsFile = Join-Path $script:PMDir "claims.tsv"
    $script:PulseFile = Join-Path $script:PMDir "pulse.log"
    $script:TicketsFile = Join-Path $script:PMDir "tickets.tsv"
}

function Migrate-LegacyDefaultScope {
    if ($script:Scope -ne "default") {
        return
    }

    if (Test-Path -LiteralPath $script:PMDir -PathType Container) {
        return
    }

    $legacyFiles = @(
        "meta.env",
        "core.md",
        "tickets.tsv",
        "criteria.tsv",
        "evidence.tsv",
        "pulse.log",
        "claims.tsv"
    )

    $legacyFound = $false
    foreach ($f in $legacyFiles) {
        if (Test-Path -LiteralPath (Join-Path $PMRoot $f) -PathType Leaf) {
            $legacyFound = $true
            break
        }
    }

    if (-not $legacyFound) {
        return
    }

    New-Item -ItemType Directory -Path $script:PMDir -Force | Out-Null
    foreach ($f in $legacyFiles) {
        $oldPath = Join-Path $PMRoot $f
        $newPath = Join-Path $script:PMDir $f
        if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
            Move-Item -LiteralPath $oldPath -Destination $newPath -Force
        }
    }
}

function Require-PMTicket {
    if (-not (Test-Path -LiteralPath $script:PMTicket -PathType Leaf)) {
        throw "error: missing $script:PMTicket"
    }
}

function Read-LockField([string]$Key) {
    if (-not (Test-Path -LiteralPath $script:LockInfo -PathType Leaf)) {
        return ""
    }
    foreach ($line in Get-Content -LiteralPath $script:LockInfo) {
        if ($line -match "^\Q$Key\E=(.*)$") {
            return $Matches[1]
        }
    }
    return ""
}

function Lock-AgeSeconds {
    if (-not (Test-Path -LiteralPath $script:LockDir -PathType Container)) {
        return 0
    }
    $item = Get-Item -LiteralPath $script:LockDir
    $age = [int]((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds
    if ($age -lt 0) {
        return 0
    }
    return $age
}

function Remove-LockDir {
    if (Test-Path -LiteralPath $script:LockInfo -PathType Leaf) {
        Remove-Item -LiteralPath $script:LockInfo -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:LockDir -PathType Container) {
        Remove-Item -LiteralPath $script:LockDir -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Lock-IsStale {
    if (-not (Test-Path -LiteralPath $script:LockDir -PathType Container)) {
        return $false
    }

    $host = Read-LockField "host"
    $pidRaw = Read-LockField "pid"
    $currentHost = [System.Net.Dns]::GetHostName()

    if ($pidRaw -ne "" -and $host -ne "" -and $host -eq $currentHost) {
        $pidVal = 0
        if ([int]::TryParse($pidRaw, [ref]$pidVal)) {
            $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                return $false
            }
        }
    }

    $age = Lock-AgeSeconds
    return ($age -ge $script:LockStaleSeconds)
}

function Release-Lock {
    if ($script:LockToken -eq "") {
        return
    }

    if (Test-Path -LiteralPath $script:LockDir -PathType Container) {
        $token = Read-LockField "token"
        if ($token -ne "" -and $token -eq $script:LockToken) {
            Remove-LockDir
        }
    }
    $script:LockToken = ""
}

function Acquire-Lock([string]$Agent) {
    if (-not (Test-Path -LiteralPath $script:PMDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:PMDir | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($script:LockWaitSeconds)
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $script:LockDir -ErrorAction Stop | Out-Null
            $script:LockToken = "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$PID-$(Get-Random)"
            $lockLines = @(
                "agent=$Agent"
                "pid=$PID"
                "host=$([System.Net.Dns]::GetHostName())"
                "token=$script:LockToken"
                "started=$(Get-NowTs)"
            )
            Set-Content -LiteralPath $script:LockInfo -Value $lockLines
            return
        } catch {
            if (Lock-IsStale) {
                Write-Warning "removing stale lock (age $(Lock-AgeSeconds)s)"
                Remove-LockDir
                continue
            }

            if ((Get-Date) -ge $deadline) {
                $owner = Read-LockField "agent"
                $host = Read-LockField "host"
                $pid = Read-LockField "pid"
                $started = Read-LockField "started"
                if ($owner -eq "") { $owner = "unknown" }
                if ($host -eq "") { $host = "unknown" }
                if ($pid -eq "") { $pid = "unknown" }
                if ($started -eq "") { $started = "unknown" }
                throw "error: lock timeout after $($script:LockWaitSeconds)s`nscope: $script:Scope`nlock owner: $owner`nlock host: $host`nlock pid: $pid`nlock started: $started"
            }

            Start-Sleep -Seconds $script:LockPollSeconds
        }
    }
}

function Append-Pulse([string]$TaskId, [string]$Event, [string]$Details = "") {
    $safeDetails = Sanitize $Details
    Add-Content -LiteralPath $script:PulseFile -Value "$(Get-NowTs)|$TaskId|$Event|$safeDetails"
}

function Ensure-PMInitialized {
    if (-not (Test-Path -LiteralPath $script:TicketsFile -PathType Leaf)) {
        throw "error: scope '$script:Scope' not initialized. Run: scripts/pm-collab.ps1 --scope $script:Scope init"
    }
}

function Ensure-ClaimsFile {
    if (-not (Test-Path -LiteralPath $script:PMDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:PMDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:ClaimsFile -PathType Leaf)) {
        Set-Content -LiteralPath $script:ClaimsFile -Value "id`tagent`tclaimed_at`tnote"
    }
}

function Read-Tickets {
    if (-not (Test-Path -LiteralPath $script:TicketsFile -PathType Leaf)) {
        return @()
    }
    $lines = Get-Content -LiteralPath $script:TicketsFile
    if ($lines.Count -le 1) {
        return @()
    }
    $rows = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "") { continue }
        $parts = $lines[$i].Split("`t", 6)
        while ($parts.Count -lt 6) { $parts += "" }
        $rows += [pscustomobject]@{
            id      = $parts[0]
            state   = $parts[1]
            title   = $parts[2]
            deps    = $parts[3]
            created = $parts[4]
            updated = $parts[5]
        }
    }
    return $rows
}

function Ticket-Exists([string]$TaskId) {
    $rows = Read-Tickets
    return ($rows | Where-Object { $_.id -eq $TaskId }).Count -gt 0
}

function Ticket-State([string]$TaskId) {
    $row = Read-Tickets | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
    if ($null -eq $row) {
        throw "error: task not found: $TaskId"
    }
    return $row.state
}

function Read-Claims {
    if (-not (Test-Path -LiteralPath $script:ClaimsFile -PathType Leaf)) {
        return @()
    }
    $lines = Get-Content -LiteralPath $script:ClaimsFile
    if ($lines.Count -le 1) {
        return @()
    }
    $rows = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "") { continue }
        $parts = $lines[$i].Split("`t", 4)
        while ($parts.Count -lt 4) { $parts += "" }
        $rows += [pscustomobject]@{
            id         = $parts[0]
            agent      = $parts[1]
            claimed_at = $parts[2]
            note       = $parts[3]
        }
    }
    return $rows
}

function Write-Claims([array]$Rows) {
    $out = @("id`tagent`tclaimed_at`tnote")
    foreach ($row in $Rows) {
        $out += "$($row.id)`t$($row.agent)`t$($row.claimed_at)`t$($row.note)"
    }
    Set-Content -LiteralPath $script:ClaimsFile -Value $out
}

function Claim-Owner([string]$TaskId) {
    $row = Read-Claims | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
    if ($null -eq $row) {
        return ""
    }
    return $row.agent
}

function Remove-Claim([string]$TaskId) {
    $rows = Read-Claims
    $filtered = @($rows | Where-Object { $_.id -ne $TaskId })
    Write-Claims $filtered
}

function TaskId-FromPMCommand([string]$PMCmd, [string]$MaybeId = "") {
    switch ($PMCmd) {
        "move" { return $MaybeId }
        "criterion-add" { return $MaybeId }
        "criterion-check" { return $MaybeId }
        "evidence" { return $MaybeId }
        "done" { return $MaybeId }
        default { return "" }
    }
}

function Is-PMTicketCommand([string]$PMCmd) {
    switch ($PMCmd) {
        "init" { return $true }
        "new" { return $true }
        "move" { return $true }
        "criterion-add" { return $true }
        "criterion-check" { return $true }
        "evidence" { return $true }
        "done" { return $true }
        "list" { return $true }
        "render" { return $true }
        "render-context" { return $true }
        "next-id" { return $true }
        default { return $false }
    }
}

function Looks-LikeTaskId([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return ($Value -match "^T-\d{4}$")
}

function Is-MutatingPMCommand([string]$PMCmd) {
    switch ($PMCmd) {
        "init" { return $true }
        "new" { return $true }
        "move" { return $true }
        "criterion-add" { return $true }
        "criterion-check" { return $true }
        "evidence" { return $true }
        "done" { return $true }
        "render" { return $true }
        default { return $false }
    }
}

function Ensure-TaskClaimedOrAuto([string]$Agent, [string]$TaskId, [string]$PMCmd) {
    $owner = Claim-Owner $TaskId
    if ($owner -ne "") {
        if ($owner -ne $Agent) {
            throw "error: $TaskId is claimed by '$owner' (agent '$Agent' cannot modify it)"
        }
        return
    }

    $state = Ticket-State $TaskId
    if ($state -eq "DONE") {
        throw "error: cannot auto-claim completed task $TaskId"
    }

    $note = "auto-claim via run $PMCmd"
    Add-Content -LiteralPath $script:ClaimsFile -Value "$TaskId`t$Agent`t$(Get-NowTs)`t$note"
    Append-Pulse $TaskId "CLAIM" "agent=$Agent auto=1 command=$PMCmd"
}

function Get-PowerShellExe {
    if ($PSVersionTable.PSEdition -eq "Core") {
        $path = (Get-Process -Id $PID).Path
        if ($path) {
            return $path
        }
    }
    return "powershell.exe"
}

function Invoke-PMTicket([string[]]$Args) {
    $psExe = Get-PowerShellExe
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $script:PMTicket --scope $script:Scope @Args
    if ($LASTEXITCODE -ne 0) {
        throw "error: pm-ticket failed with exit code $LASTEXITCODE"
    }
}

function Cmd-Init {
    Acquire-Lock "SYSTEM"
    try {
        Invoke-PMTicket @("init")
        Ensure-ClaimsFile
        Append-Pulse "SYSTEM" "COLLAB_INIT" "collab lock and claims enabled (scope=$script:Scope)"
        Invoke-PMTicket @("render")
    } finally {
        Release-Lock
    }
}

function Cmd-Claim([string]$Agent, [string]$TaskId, [string]$Note = "") {
    $safeNote = Sanitize $Note

    Acquire-Lock $Agent
    try {
        Ensure-PMInitialized
        Ensure-ClaimsFile

        if (-not (Ticket-Exists $TaskId)) {
            throw "error: task not found: $TaskId"
        }

        $state = Ticket-State $TaskId
        if ($state -eq "DONE") {
            throw "error: cannot claim completed task $TaskId"
        }

        $owner = Claim-Owner $TaskId
        if ($owner -ne "") {
            if ($owner -eq $Agent) {
                Write-Output "$TaskId already claimed by $Agent"
                return
            }
            throw "error: $TaskId already claimed by $owner"
        }

        Add-Content -LiteralPath $script:ClaimsFile -Value "$TaskId`t$Agent`t$(Get-NowTs)`t$safeNote"
        $details = "agent=$Agent"
        if ($safeNote -ne "") {
            $details = "$details note=$safeNote"
        }
        Append-Pulse $TaskId "CLAIM" $details
        Invoke-PMTicket @("render")
        Write-Output "$TaskId claimed by $Agent"
    } finally {
        Release-Lock
    }
}

function Cmd-Unclaim([string]$Agent, [string]$TaskId) {
    Acquire-Lock $Agent
    try {
        Ensure-PMInitialized
        Ensure-ClaimsFile

        $owner = Claim-Owner $TaskId
        if ($owner -eq "") {
            throw "error: task is not claimed: $TaskId"
        }
        if ($owner -ne $Agent) {
            throw "error: $TaskId is claimed by $owner (not $Agent)"
        }

        Remove-Claim $TaskId
        Append-Pulse $TaskId "UNCLAIM" "agent=$Agent"
        Invoke-PMTicket @("render")
        Write-Output "$TaskId released by $Agent"
    } finally {
        Release-Lock
    }
}

function Cmd-Claims {
    Ensure-PMInitialized
    Ensure-ClaimsFile
    $rows = Read-Claims
    if ($rows.Count -eq 0) {
        Write-Output "(none)"
        return
    }
    foreach ($row in $rows) {
        Write-Output "$($row.id)`t$($row.agent)`t$($row.claimed_at)`t$($row.note)"
    }
}

function Cmd-LockInfo {
    if (-not (Test-Path -LiteralPath $script:LockDir -PathType Container)) {
        Write-Output "lock: free"
        Write-Output "scope: $script:Scope"
        return
    }
    $owner = Read-LockField "agent"
    $host = Read-LockField "host"
    $pid = Read-LockField "pid"
    $started = Read-LockField "started"
    if ($owner -eq "") { $owner = "unknown" }
    if ($host -eq "") { $host = "unknown" }
    if ($pid -eq "") { $pid = "unknown" }
    if ($started -eq "") { $started = "unknown" }
    Write-Output "lock: held"
    Write-Output "scope: $script:Scope"
    Write-Output "owner: $owner"
    Write-Output "host: $host"
    Write-Output "pid: $pid"
    Write-Output "started: $started"
    Write-Output "age_seconds: $(Lock-AgeSeconds)"
}

function Cmd-UnlockStale {
    if (-not (Test-Path -LiteralPath $script:LockDir -PathType Container)) {
        Write-Output "lock already free"
        return
    }
    if (Lock-IsStale) {
        Remove-LockDir
        Write-Output "stale lock removed"
        return
    }
    throw "error: lock is active and not stale"
}

function Cmd-Run([string[]]$RunArgs) {
    $argsList = @($RunArgs)
    if ($argsList.Count -lt 1) {
        throw "error: run requires a pm-ticket command"
    }

    $agent = ""
    if ($argsList[0] -eq "--") {
        if ($argsList.Count -eq 1) {
            throw "error: run requires a pm-ticket command"
        }
        $argsList = @($argsList[1..($argsList.Count - 1)])
    } elseif (Is-PMTicketCommand $argsList[0]) {
        # auto-agent path
    } else {
        $agent = $argsList[0]
        if ($argsList.Count -eq 1) {
            throw "error: run requires a pm-ticket command"
        }
        $argsList = @($argsList[1..($argsList.Count - 1)])
    }

    if ($argsList.Count -gt 0 -and $argsList[0] -eq "--") {
        if ($argsList.Count -eq 1) {
            throw "error: run requires a pm-ticket command"
        }
        $argsList = @($argsList[1..($argsList.Count - 1)])
    }
    if ($argsList.Count -lt 1) {
        throw "error: run requires a pm-ticket command"
    }

    if ($agent -eq "") {
        $agent = Get-DefaultAgentName
    } else {
        $agent = Sanitize $agent
    }

    $pmCmd = $argsList[0]
    $taskId = ""
    if ($argsList.Count -ge 2) {
        $taskId = TaskId-FromPMCommand $pmCmd $argsList[1]
    } else {
        $taskId = TaskId-FromPMCommand $pmCmd ""
    }

    Acquire-Lock $agent
    try {
        if ($pmCmd -ne "init") {
            Ensure-PMInitialized
            Ensure-ClaimsFile
        }

        if ($taskId -ne "") {
            Ensure-TaskClaimedOrAuto $agent $taskId $pmCmd
        }

        Invoke-PMTicket $argsList

        if ($taskId -ne "" -and $pmCmd -eq "done") {
            $owner = Claim-Owner $taskId
            if ($owner -eq $agent) {
                Remove-Claim $taskId
                Append-Pulse $taskId "UNCLAIM" "auto-release on done by $agent"
            }
        }

        if ((Is-MutatingPMCommand $pmCmd) -and $pmCmd -ne "render") {
            Invoke-PMTicket @("render")
        }
    } finally {
        Release-Lock
    }
}

$remainingArgs = Parse-GlobalOptions $args
Set-ScopePaths
Migrate-LegacyDefaultScope
Require-PMTicket

if ($remainingArgs.Count -lt 1) {
    Write-Usage
    exit 1
}

$command = $remainingArgs[0]
$rest = @()
if ($remainingArgs.Count -gt 1) {
    $rest = $remainingArgs[1..($remainingArgs.Count - 1)]
}

try {
    switch ($command) {
        "init" {
            Cmd-Init
        }
        "claim" {
            if ($rest.Count -lt 1) { throw "error: claim requires <task-id> or <agent> <task-id>" }
            if (Looks-LikeTaskId $rest[0]) {
                $note = if ($rest.Count -ge 2) { $rest[1] } else { "" }
                Cmd-Claim (Get-DefaultAgentName) $rest[0] $note
            } else {
                if ($rest.Count -lt 2) { throw "error: claim requires <agent> <task-id>" }
                $note = if ($rest.Count -ge 3) { $rest[2] } else { "" }
                Cmd-Claim $rest[0] $rest[1] $note
            }
        }
        "unclaim" {
            if ($rest.Count -lt 1) { throw "error: unclaim requires <task-id> or <agent> <task-id>" }
            if (Looks-LikeTaskId $rest[0]) {
                Cmd-Unclaim (Get-DefaultAgentName) $rest[0]
            } else {
                if ($rest.Count -lt 2) { throw "error: unclaim requires <agent> <task-id>" }
                Cmd-Unclaim $rest[0] $rest[1]
            }
        }
        "claims" {
            Cmd-Claims
        }
        "run" {
            if ($rest.Count -lt 1) { throw "error: run requires command args" }
            Cmd-Run $rest
        }
        "lock-info" {
            Cmd-LockInfo
        }
        "unlock-stale" {
            Cmd-UnlockStale
        }
        default {
            Write-Usage
            throw "error: unknown command '$command'"
        }
    }
} catch {
    Write-Error $_
    exit 1
}
