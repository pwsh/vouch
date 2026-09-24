#Requires -Version 7

<#
.SYNOPSIS
    Sets up (or removes) a Windows scheduled task that runs vouch.ps1 automatically.

.DESCRIPTION
    Screen captures need a signed-in, unlocked desktop, so the task runs in YOUR
    interactive session ("Run only when user is logged on"). It never runs in the
    background session that "Run whether user is logged on or not" would use, because
    that session has no desktop and would produce blank evidence.

    The task:
      - runs PowerShell 7 hidden, with -NoProfile and -ExecutionPolicy Bypass
      - starts in the script folder and passes absolute paths
      - writes a log of every run (the console is not visible)
      - passes -FailOnWarning, so an expired login shows up as Last Run Result 0x3
      - starts a missed run as soon as possible and never runs twice at once

    Re-running the install replaces the existing task with the new settings.

.PARAMETER Schedule
    Weekdays (default), Daily, Weekly (with -DaysOfWeek) or AtLogOn (a few minutes after
    you sign in - the desktop is guaranteed to be unlocked then).

.PARAMETER At
    Time of day for Weekdays/Daily/Weekly, e.g. 07:30.

.PARAMETER AllowWarnings
    Do not pass -FailOnWarning: runs with warnings then report success (0).

.PARAMETER Status
    Show the task, its next and last run, and the newest report and log.

.PARAMETER RunNow
    Start the task immediately, e.g. to try it out.

.PARAMETER Uninstall
    Remove the task. Reports, logs and the audit browser profile are kept.

.EXAMPLE
    .\Install-VouchSchedule.ps1 -At 07:30

.EXAMPLE
    .\Install-VouchSchedule.ps1 -Schedule Weekly -DaysOfWeek Monday -At 06:00 -CsvPath .\q3-itgc.csv -OutputDir C:\Audit\Q3

.EXAMPLE
    .\Install-VouchSchedule.ps1 -Status

.EXAMPLE
    .\Install-VouchSchedule.ps1 -Uninstall
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Weekdays', 'Daily', 'Weekly', 'AtLogOn')]
    [string]$Schedule = 'Weekdays',

    [Parameter(ParameterSetName = 'Install')]
    [ValidatePattern('^([01]?\d|2[0-3]):[0-5]\d$')]
    [string]$At = '08:00',

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string[]]$DaysOfWeek = @('Monday'),

    [Parameter(ParameterSetName = 'Install')]
    [string]$CsvPath = '',

    [Parameter(ParameterSetName = 'Install')]
    [string]$OutputDir = '',

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('jpeg', 'png')]
    [string]$ImageFormat = 'jpeg',

    [Parameter(ParameterSetName = 'Install')]
    [switch]$SaveImages,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$AllowWarnings,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(1, 24)]
    [int]$MaxRunHours = 2,

    # Only needed for a second schedule on the same machine: give each its own port
    # (and, if they sign in to different accounts, its own profile).
    [Parameter(ParameterSetName = 'Install')]
    [string]$EdgeProfileDir = '',

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(0, 65535)]
    [int]$DebugPort = 0,

    [Parameter(ParameterSetName = 'Status', Mandatory)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'RunNow', Mandatory)]
    [switch]$RunNow,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall,

    [string]$TaskName = 'Vouch evidence capture'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PwshPath {
    <#
        The task must keep working after PowerShell updates. The MSI install lives at a
        fixed path; the Store/winget (MSIX) install lives in a versioned folder that
        changes on every update, so use its app execution alias instead.
    #>
    $candidates = @(
        (Join-Path -Path "$env:ProgramFiles" -ChildPath 'PowerShell\7\pwsh.exe'),
        (Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Microsoft\WindowsApps\pwsh.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $current = Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'
    Write-Warning "Using $current. If PowerShell is updated or moved, run this installer again."
    return $current
}

function ConvertTo-TaskArgument {
    # Task Scheduler passes the argument string to CreateProcess as-is: quote every value
    # (paths may contain spaces) and drop a trailing backslash that would escape the quote.
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.TrimEnd('\') + '"'
}

function Get-VouchTaskArguments {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$LogDir,
        [string]$CsvPath = '',
        [string]$OutputDir = '',
        [string]$ImageFormat = 'jpeg',
        [bool]$SaveImages = $false,
        [bool]$FailOnWarning = $true,
        [string]$EdgeProfileDir = '',
        [int]$DebugPort = 0
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($fixed in @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File')) {
        $arguments.Add($fixed)
    }
    $arguments.Add((ConvertTo-TaskArgument -Value $ScriptPath))
    if ($CsvPath) { $arguments.Add('-CsvPath'); $arguments.Add((ConvertTo-TaskArgument -Value $CsvPath)) }
    if ($OutputDir) { $arguments.Add('-OutputDir'); $arguments.Add((ConvertTo-TaskArgument -Value $OutputDir)) }
    if ($ImageFormat -ne 'jpeg') { $arguments.Add('-ImageFormat'); $arguments.Add($ImageFormat) }
    if ($SaveImages) { $arguments.Add('-SaveImages') }
    if ($FailOnWarning) { $arguments.Add('-FailOnWarning') }
    if ($EdgeProfileDir) { $arguments.Add('-EdgeProfileDir'); $arguments.Add((ConvertTo-TaskArgument -Value $EdgeProfileDir)) }
    if ($DebugPort -gt 0) { $arguments.Add('-DebugPort'); $arguments.Add([string]$DebugPort) }
    # The JSON summary lets -Status report the last run's counts.
    $arguments.Add('-JsonSummary')
    $arguments.Add('-LogDir')
    $arguments.Add((ConvertTo-TaskArgument -Value $LogDir))
    return ($arguments -join ' ')
}

function New-VouchTrigger {
    param(
        [Parameter(Mandatory)][string]$Schedule,
        [Parameter(Mandatory)][string]$At,
        [string[]]$DaysOfWeek = @('Monday'),
        [Parameter(Mandatory)][string]$UserId
    )

    # 'H' takes one or two digits, so both 7:05 and 07:05 parse.
    $time = [datetime]::ParseExact($At, 'H:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    switch ($Schedule) {
        'Daily' { return New-ScheduledTaskTrigger -Daily -At $time }
        'Weekdays' {
            return New-ScheduledTaskTrigger -Weekly -At $time -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday
        }
        'Weekly' { return New-ScheduledTaskTrigger -Weekly -At $time -DaysOfWeek $DaysOfWeek }
        'AtLogOn' {
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
            # Give the desktop, taskbar and network time to settle after sign-in.
            $trigger.Delay = 'PT3M'
            return $trigger
        }
    }
}

function Get-ExitCodeMeaning {
    param([long]$Code)
    switch ($Code) {
        0 { return 'Success - all items OK' }
        1 { return 'The run could not start (bad CSV, Edge not found, DevTools port busy) - see the log' }
        2 { return 'At least one item FAILED - see the report' }
        3 { return 'Warnings only - often an expired login; run .\vouch.ps1 -LoginSetup' }
        267009 { return 'Running now' }
        267011 { return 'Has not run yet' }
        267014 { return 'Stopped: it ran longer than the time limit' }
        default { return ('Task Scheduler code 0x{0:X}' -f $Code) }
    }
}

function Get-NewestFile {
    param([string]$Directory, [string]$Filter)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return $null }
    return Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-TaskArgumentValue {
    # Reads a -Name "value" pair back out of the registered task's argument string.
    param([string]$Arguments, [string]$Name)
    if ($Arguments -match "-$Name\s+""([^""]+)""") { return $Matches[1] }
    return ''
}

function Get-VouchTask {
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -eq '\' } | Select-Object -First 1
}

function Show-VouchStatus {
    $task = Get-VouchTask
    if ($null -eq $task) {
        Write-Host "No scheduled task named '$TaskName'. Install it with .\Install-VouchSchedule.ps1" -ForegroundColor Yellow
        return
    }

    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $arguments = [string]$task.Actions[0].Arguments
    $outputDir = Get-TaskArgumentValue -Arguments $arguments -Name 'OutputDir'
    if (-not $outputDir) { $outputDir = Join-Path -Path $PSScriptRoot -ChildPath 'reports' }
    $logDir = Get-TaskArgumentValue -Arguments $arguments -Name 'LogDir'

    $lastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime } else { 'never' }
    $report = Get-NewestFile -Directory $outputDir -Filter '*.htm*'
    $log = Get-NewestFile -Directory $logDir -Filter 'vouch_*.log'
    $counts = ''
    $summaryFile = Get-NewestFile -Directory $outputDir -Filter '*.json'
    if ($null -ne $summaryFile) {
        try {
            $summary = Get-Content -LiteralPath $summaryFile.FullName -Raw | ConvertFrom-Json
            $counts = "$($summary.Run.OkCount) OK, $($summary.Run.WarnCount) warning(s), $($summary.Run.FailCount) failed, " +
                "$($summary.Run.CaptureCount) screenshot(s) - run of $($summary.Run.StartTime)"
        }
        catch {
            Write-Verbose "Could not read $($summaryFile.FullName): $($_.Exception.Message)"
        }
    }

    Write-Host "Task:        $TaskName ($($task.State))" -ForegroundColor Cyan
    Write-Host "Next run:    $(if ($info.NextRunTime) { $info.NextRunTime } else { 'not scheduled' })"
    Write-Host "Last run:    $lastRun"
    Write-Host "Last result: $(Get-ExitCodeMeaning -Code $info.LastTaskResult)"
    if ($counts) { Write-Host "Last report: $counts" }
    Write-Host "Command:     $($task.Actions[0].Execute) $arguments"
    Write-Host "Newest report: $(if ($report) { $report.FullName } else { 'none yet' })"
    Write-Host "Newest log:    $(if ($log) { $log.FullName } else { 'none yet' })"
}

function Install-VouchTask {
    $vouchScript = Join-Path -Path $PSScriptRoot -ChildPath 'vouch.ps1'
    $defaultProfileDir = Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Vouch\EdgeProfile'
    if (-not (Test-Path -LiteralPath $vouchScript -PathType Leaf)) {
        throw "vouch.ps1 was not found next to this installer ($PSScriptRoot)."
    }

    # Resolve relative paths now, against the folder the installer was started from;
    # the task itself starts in the script folder.
    $resolve = { param($Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $csv = if ($CsvPath) { & $resolve $CsvPath } else { Join-Path -Path $PSScriptRoot -ChildPath 'captures.csv' }
    $output = if ($OutputDir) { & $resolve $OutputDir } else { Join-Path -Path $PSScriptRoot -ChildPath 'reports' }
    $logDir = Join-Path -Path $output -ChildPath 'logs'

    if (-not (Test-Path -LiteralPath $csv -PathType Leaf)) {
        throw "Capture definition CSV not found: $csv`nCreate it first (copy captures.sample.csv), or pass -CsvPath."
    }
    $edgeProfile = if ($EdgeProfileDir) { & $resolve $EdgeProfileDir } else { '' }
    if (-not (Test-Path -LiteralPath $(if ($edgeProfile) { $edgeProfile } else { $defaultProfileDir }))) {
        Write-Warning 'The audit browser profile does not exist yet. Run .\vouch.ps1 -LoginSetup (with the same -EdgeProfileDir) and sign in before the first scheduled run of pages that need a login.'
    }

    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute (Get-PwshPath) -WorkingDirectory $PSScriptRoot -Argument (
        Get-VouchTaskArguments -ScriptPath $vouchScript -LogDir $logDir -CsvPath $csv -OutputDir $output `
            -ImageFormat $ImageFormat -SaveImages $SaveImages.IsPresent -FailOnWarning (-not $AllowWarnings) `
            -EdgeProfileDir $edgeProfile -DebugPort $DebugPort)
    $trigger = New-VouchTrigger -Schedule $Schedule -At $At -DaysOfWeek $DaysOfWeek -UserId $userId
    # Interactive: runs in your signed-in session, the only one with a desktop to capture.
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours $MaxRunHours) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    $description = 'Captures audit evidence screenshots with vouch.ps1. Needs you signed in with the screen unlocked. Managed by Install-VouchSchedule.ps1.'
    [void](Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $description -Force)

    $when = switch ($Schedule) {
        'Weekdays' { "every weekday at $At" }
        'Daily' { "every day at $At" }
        'Weekly' { "every $($DaysOfWeek -join ', ') at $At" }
        'AtLogOn' { '3 minutes after you sign in' }
    }
    Write-Host ''
    Write-Host "Scheduled task '$TaskName' installed: runs $when." -ForegroundColor Green
    Write-Host "  CSV:     $csv"
    Write-Host "  Reports: $output"
    Write-Host "  Logs:    $logDir"
    Write-Host ''
    Write-Host 'For the run to produce evidence:' -ForegroundColor Cyan
    Write-Host '  - Be signed in with the screen UNLOCKED at that time (a locked screen gives blank captures).'
    Write-Host '  - Keep the screen saver and display sleep from starting before then, or use -Schedule AtLogOn.'
    Write-Host '  - Over Remote Desktop, keep the session connected and not minimised.'
    Write-Host ''
    Write-Host 'Try it now:     .\Install-VouchSchedule.ps1 -RunNow'
    Write-Host 'Check results:  .\Install-VouchSchedule.ps1 -Status'
}

switch ($PSCmdlet.ParameterSetName) {
    'Status' { Show-VouchStatus }
    'RunNow' {
        if ($null -eq (Get-VouchTask)) { throw "No scheduled task named '$TaskName'. Install it first." }
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Started '$TaskName'. Leave the keyboard and mouse alone until Edge closes, then run -Status." -ForegroundColor Green
    }
    'Uninstall' {
        if ($null -eq (Get-VouchTask)) {
            Write-Host "No scheduled task named '$TaskName'; nothing to remove."
        }
        else {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
            Write-Host "Removed '$TaskName'. Reports, logs and the audit browser profile were kept." -ForegroundColor Green
        }
    }
    default { Install-VouchTask }
}
