#Requires -Version 7

<#
.SYNOPSIS
    Sets up (or removes) a Windows scheduled task that runs vouch.ps1 automatically.

.DESCRIPTION
    Screen captures need a signed-in, unlocked desktop, so the task runs in YOUR
    interactive session ("Run only when user is logged on"). It never runs in the
    background session that "Run whether user is logged on or not" would use, because
    that session has no desktop and would produce blank evidence.

    The pages come from a configuration file made with the Vouch Designer (-ConfigPath)
    or from a CSV file (-CsvPath, default captures.csv next to this script); not both.

    The task:
      - runs PowerShell 7 hidden, with -NoProfile and -ExecutionPolicy Bypass
      - starts in the script folder and passes absolute paths
      - passes -NoPrompt: a scheduled run never shows the Vouch dialog and never waits
        for an answer (a "pause" is skipped, a page that is not ready is captured with
        a warning)
      - asks for the JSON summary (-JsonSummary), so -Status can show the last counts
      - keeps a console transcript of every run (the window is not visible): in the
        configuration's own log folder when it names one, otherwise in a "logs" folder
        inside the output folder
      - passes -FailOnWarning, so an expired login shows up as Last Run Result 0x3
        instead of a success - for a configuration file too, whatever its "Count
        warnings as failure" setting says. -AllowWarnings turns that off.
      - starts a missed run as soon as possible and never runs twice at once

    With -ConfigPath, the file is checked first with the same checks vouch.ps1 makes;
    a file with problems is not scheduled. Settings that make no sense for an unattended
    run (open the report when done, asking when a page is not ready, pause actions) are
    pointed out, with what the scheduled run does instead.

    -OutputDir, -EdgeProfileDir, -ImageFormat, -SaveImages, -UseVirtualDesktop and
    -DebugPort: with -ConfigPath they are passed on only when you type them, and then
    beat the same setting in the file; without them the file decides. With a CSV file
    they work as before.

    Re-running the install replaces the existing task with the new settings.

.PARAMETER ConfigPath
    The configuration file (JSON) to run, as saved by the Vouch Designer. Cannot be
    used together with -CsvPath.

.PARAMETER CsvPath
    The CSV file with the pages. Default: captures.csv next to this script. Cannot be
    used together with -ConfigPath.

.PARAMETER Schedule
    Weekdays (default), Daily, Weekly (with -DaysOfWeek) or AtLogOn (a few minutes after
    you sign in - the desktop is guaranteed to be unlocked then).

.PARAMETER At
    Time of day for Weekdays/Daily/Weekly, e.g. 07:30.

.PARAMETER AllowWarnings
    Do not count warnings as failure: runs with warnings then report success (0). Without
    it every scheduled run - CSV or configuration file - counts warnings as failure (3).

.PARAMETER Status
    Show the task, its next and last run, the file it runs, where its reports go, and
    the newest report and log.

.PARAMETER RunNow
    Start the task immediately, e.g. to try it out.

.PARAMETER Uninstall
    Remove the task. Reports, logs and the audit browser profile are kept.

.EXAMPLE
    .\Install-VouchSchedule.ps1 -ConfigPath .\q3-itgc.json -Schedule AtLogOn

.EXAMPLE
    .\Install-VouchSchedule.ps1 -ConfigPath .\q3-itgc.json -At 07:30

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
    [string]$ConfigPath = '',

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
    [switch]$UseVirtualDesktop,

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
    <#
        Task Scheduler passes the argument string to CreateProcess as-is, and pwsh splits
        it by the Windows rules: every value goes in double quotes (paths may contain
        spaces, & ; ( ) or apostrophes, which are plain text inside them). A backslash
        right before the closing quote would escape it, so trailing backslashes are
        dropped - except for a drive root ("D:\"), where "D:" alone would mean the current
        folder of that drive: there the backslash is doubled, which Windows reads back as
        one. A path cannot contain a double quote, so nothing else needs escaping.
    #>
    param([Parameter(Mandatory)][string]$Value)
    $trimmed = $Value.TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') { return '"' + $trimmed + '\\"' }
    return '"' + $trimmed + '"'
}

function Get-VouchTaskArguments {
    <#
        The argument string the task stores. -NoPrompt is always there: a scheduled run
        must never show a dialog or wait for an answer (pwsh's -NonInteractive already
        keeps the Vouch dialog away; -NoPrompt says so to the engine directly).
        CSV schedules: the installer's own settings, as always. Configuration schedules:
        only -ConfigPath, plus the settings in -Override, which hold exactly the installer
        parameters that were typed: a setting not typed is left to the file. Both count
        warnings as failure (-FailOnWarning) unless warnings are allowed: an expired
        sign-in in an unattended evidence run must never show as a success in Task
        Scheduler, so this scheduler rule beats the file's output.failOnWarning (allowed:
        -FailOnWarning:$false, which beats an "on" in the file the other way round). A typed switch is passed with its
        value (-SaveImages:$false), so "off" beats an "on" in the file too.
        -JsonSummary always; -LogDir only when given (a configuration that names its
        own log folder keeps it).
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyString()][string]$LogDir = '',
        [string]$CsvPath = '',
        [string]$ConfigPath = '',
        [System.Collections.IDictionary]$Override = @{},
        [string]$OutputDir = '',
        [string]$ImageFormat = 'jpeg',
        [bool]$SaveImages = $false,
        [bool]$FailOnWarning = $true,
        [string]$EdgeProfileDir = '',
        [int]$DebugPort = 0,
        [bool]$UseVirtualDesktop = $false
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($fixed in @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File')) {
        $arguments.Add($fixed)
    }
    $arguments.Add((ConvertTo-TaskArgument -Value $ScriptPath))
    $switchValue = { param($Name, $On) if ($On) { "-$Name" } else { "-$($Name):`$false" } }
    if ($ConfigPath) {
        $arguments.Add('-ConfigPath'); $arguments.Add((ConvertTo-TaskArgument -Value $ConfigPath))
        if ($Override.Contains('OutputDir')) { $arguments.Add('-OutputDir'); $arguments.Add((ConvertTo-TaskArgument -Value ([string]$Override['OutputDir']))) }
        if ($Override.Contains('ImageFormat')) { $arguments.Add('-ImageFormat'); $arguments.Add([string]$Override['ImageFormat']) }
        if ($Override.Contains('SaveImages')) { $arguments.Add((& $switchValue 'SaveImages' ([bool]$Override['SaveImages']))) }
        # -AllowWarnings is the opposite of the engine's -FailOnWarning; without it, always on.
        $allow = $Override.Contains('AllowWarnings') -and [bool]$Override['AllowWarnings']
        $arguments.Add((& $switchValue 'FailOnWarning' (-not $allow)))
        if ($Override.Contains('EdgeProfileDir')) { $arguments.Add('-EdgeProfileDir'); $arguments.Add((ConvertTo-TaskArgument -Value ([string]$Override['EdgeProfileDir']))) }
        if ($Override.Contains('DebugPort') -and [int]$Override['DebugPort'] -gt 0) { $arguments.Add('-DebugPort'); $arguments.Add([string][int]$Override['DebugPort']) }
        if ($Override.Contains('UseVirtualDesktop')) { $arguments.Add((& $switchValue 'UseVirtualDesktop' ([bool]$Override['UseVirtualDesktop']))) }
    }
    else {
        if ($CsvPath) { $arguments.Add('-CsvPath'); $arguments.Add((ConvertTo-TaskArgument -Value $CsvPath)) }
        if ($OutputDir) { $arguments.Add('-OutputDir'); $arguments.Add((ConvertTo-TaskArgument -Value $OutputDir)) }
        if ($ImageFormat -ne 'jpeg') { $arguments.Add('-ImageFormat'); $arguments.Add($ImageFormat) }
        if ($SaveImages) { $arguments.Add('-SaveImages') }
        if ($FailOnWarning) { $arguments.Add('-FailOnWarning') }
        if ($EdgeProfileDir) { $arguments.Add('-EdgeProfileDir'); $arguments.Add((ConvertTo-TaskArgument -Value $EdgeProfileDir)) }
        if ($DebugPort -gt 0) { $arguments.Add('-DebugPort'); $arguments.Add([string]$DebugPort) }
        if ($UseVirtualDesktop) { $arguments.Add('-UseVirtualDesktop') }
    }
    $arguments.Add('-NoPrompt')
    # The JSON summary lets -Status report the last run's counts.
    $arguments.Add('-JsonSummary')
    if ($LogDir) {
        $arguments.Add('-LogDir')
        $arguments.Add((ConvertTo-TaskArgument -Value $LogDir))
    }
    return ($arguments -join ' ')
}

function Get-VouchEngineSource {
    <#
        The function definitions of vouch.ps1, read from the file itself, so a
        configuration is checked by the engine's own rules (Import-VouchConfig) and the
        installer can never drift from them. Only the definitions are taken: running
        vouch.ps1 would start a capture.
    #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "vouch.ps1 was not found next to this installer ($ScriptPath)."
    }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "vouch.ps1 could not be read ($($errors[0].Message)). Use an unchanged copy of vouch.ps1." }
    $functions = foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $statement.Extent.Text }
    }
    return (@($functions) -join "`n`n")
}

function Read-VouchScheduleConfig {
    <#
        Reads a configuration file the way vouch.ps1 does (Import-VouchConfig): every
        problem listed in the same words, notes for unknown keys, relative folders made
        absolute against the file's folder, missing settings filled with their defaults.
        Throws when the file has problems. -Quiet (for -Status) prints nothing and
        returns $null instead of throwing.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScriptPath,
        [switch]$Quiet
    )
    # The engine's functions exist only inside this function's scope.
    . ([scriptblock]::Create((Get-VouchEngineSource -ScriptPath $ScriptPath)))
    if (-not $Quiet) { return Import-VouchConfig -Path $Path }
    try { return (Import-VouchConfig -Path $Path 6>$null) }
    catch { return $null }
}

function Get-VouchScheduleConcern {
    <#
        Settings of a configuration that make no sense when nobody is at the computer,
        with what the scheduled run does instead. Only pages that are switched on count:
        the others do not run. Not errors: the run still produces its report.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $concerns = [System.Collections.Generic.List[string]]::new()
    if ($Config['output']['openReport']) {
        $concerns.Add('"Open the report when the run is finished" is on, but a scheduled run never opens the report (nobody is watching). The report is written as usual.')
    }
    $pages = @($Config['pages'] | Where-Object { $_['enabled'] -ne $false })
    $asking = [System.Collections.Generic.List[string]]::new()
    $pausing = [System.Collections.Generic.List[string]]::new()
    foreach ($page in $pages) {
        $onNotReady = $Config['defaults']['onNotReady']
        if ($page['overrides'] -is [System.Collections.IDictionary] -and $page['overrides'].Contains('onNotReady') -and $page['overrides']['onNotReady']) {
            $onNotReady = $page['overrides']['onNotReady']
        }
        if ($onNotReady -eq 'prompt') { $asking.Add([string]$page['name']) }
        if (@($page['actions'] | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['type'] -eq 'pause' }).Count -gt 0) { $pausing.Add([string]$page['name']) }
    }
    if ($asking.Count -gt 0) {
        $concerns.Add("Asks you when a page is not ready ($($asking -join ', ')): in a scheduled run nobody is asked; such a page is captured as it is, with a warning.")
    }
    if ($pausing.Count -gt 0) {
        $concerns.Add("Pauses for you ($($pausing -join ', ')): in a scheduled run the pause is skipped and the steps after it run straight away; the page gets a warning that says so.")
    }
    return , $concerns
}

function Get-VouchScheduleSetup {
    <#
        Everything the task will do, worked out and checked before anything is
        registered: which file it runs, where reports and logs go, the argument string,
        and what to point out. Throws a plain message when the schedule cannot work
        (both or a missing definition file, a configuration with problems or no page
        switched on, a value Task Scheduler would change).
        -Parameters holds the installer parameters that were typed ($PSBoundParameters):
        with a configuration file, only those beat the file.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [System.Collections.IDictionary]$Parameters = @{}
    )
    # A plain copy: $PSBoundParameters is a generic dictionary without .Contains().
    $copy = @{}
    foreach ($key in $Parameters.Keys) { $copy[$key] = $Parameters[$key] }
    $Parameters = $copy
    $typed = { param($Name) $Parameters.Contains($Name) }
    $value = { param($Name, $Default) if ($Parameters.Contains($Name)) { $Parameters[$Name] } else { $Default } }
    $vouchScript = Join-Path -Path $ScriptRoot -ChildPath 'vouch.ps1'
    if (-not (Test-Path -LiteralPath $vouchScript -PathType Leaf)) {
        throw "vouch.ps1 was not found next to this installer ($ScriptRoot)."
    }
    $config = [string](& $value 'ConfigPath' '')
    $csvValue = [string](& $value 'CsvPath' '')
    if ($config -and $csvValue) {
        throw 'Use either -CsvPath or -ConfigPath, not both. -CsvPath reads the pages from a CSV file; -ConfigPath reads the pages and all settings from a configuration file.'
    }
    $port = [int](& $value 'DebugPort' 0)
    if ($port -gt 0 -and $port -lt 1024) { throw "-DebugPort must be from 1024 to 65535 (found $port)." }

    # Resolve relative paths now, against the folder the installer was started from;
    # the task itself starts in the script folder.
    $resolve = { param($Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $concerns = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $defaultProfileDir = Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Vouch\EdgeProfile'

    if ($config) {
        $configFile = & $resolve $config
        if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
            throw "Configuration file not found: $configFile`nSave it from the Vouch Designer first, or check the path."
        }
        # The engine's own check prints every problem; its last sentence is about a run.
        try { $loaded = Read-VouchScheduleConfig -Path $configFile -ScriptPath $vouchScript }
        catch { throw ([string]$_.Exception.Message -replace 'Nothing was launched\.$', 'Nothing was scheduled.') }
        $enabled = @($loaded['pages'] | Where-Object { $_['enabled'] -ne $false })
        if (@($loaded['pages']).Count -eq 0) { throw "The configuration file '$configFile' has no pages, so a scheduled run would have nothing to capture. Add pages in the Vouch Designer first. Nothing was scheduled." }
        if ($enabled.Count -eq 0) { throw "Every page in '$configFile' is switched off, so a scheduled run would have nothing to capture. Switch at least one on in the Vouch Designer first. Nothing was scheduled." }

        $override = [ordered]@{}
        if (& $typed 'OutputDir') { $override['OutputDir'] = & $resolve ([string]$Parameters['OutputDir']) }
        if (& $typed 'ImageFormat') { $override['ImageFormat'] = [string]$Parameters['ImageFormat'] }
        if (& $typed 'SaveImages') { $override['SaveImages'] = [bool]$Parameters['SaveImages'] }
        if (& $typed 'AllowWarnings') { $override['AllowWarnings'] = [bool]$Parameters['AllowWarnings'] }
        if (& $typed 'EdgeProfileDir') { $override['EdgeProfileDir'] = & $resolve ([string]$Parameters['EdgeProfileDir']) }
        if ((& $typed 'DebugPort') -and $port -gt 0) { $override['DebugPort'] = $port }
        if (& $typed 'UseVirtualDesktop') { $override['UseVirtualDesktop'] = [bool]$Parameters['UseVirtualDesktop'] }

        $output = if ($override.Contains('OutputDir')) { $override['OutputDir'] } else { [string]$loaded['output']['dir'] }
        # The file's own log folder wins; otherwise the transcript goes where it always did.
        $configLog = [string]$loaded['output']['logDir']
        $logDir = if ($configLog) { $configLog } else { Join-Path -Path $output -ChildPath 'logs' }
        $passLog = if ($configLog) { '' } else { $logDir }
        $profilePath = if ($override.Contains('EdgeProfileDir')) { $override['EdgeProfileDir'] } elseif ($loaded['browser']['profileDir']) { [string]$loaded['browser']['profileDir'] } else { $defaultProfileDir }

        foreach ($concern in (Get-VouchScheduleConcern -Config $loaded)) { $concerns.Add($concern) }
        # Scheduler policy: warnings count as failure unless -AllowWarnings (whatever the file says).
        if ($override.Contains('AllowWarnings') -and $override['AllowWarnings']) {
            $notes.Add('Warnings count as success (-AllowWarnings): a run whose pages only have warnings (often an expired sign-in) shows as a success in Task Scheduler.')
        }
        elseif (-not [bool]$loaded['output']['failOnWarning']) {
            $notes.Add('Scheduled runs count warnings as failure (Last Run Result 0x3), although "Count warnings as failure" is off in the file, so an expired sign-in never shows as a success. Add -AllowWarnings to allow warnings.')
        }
        $arguments = Get-VouchTaskArguments -ScriptPath $vouchScript -LogDir $passLog -ConfigPath $configFile -Override $override
        $kind = 'config'
        $definition = $configFile
    }
    else {
        $definition = if ($csvValue) { & $resolve $csvValue } else { Join-Path -Path $ScriptRoot -ChildPath 'captures.csv' }
        if (-not (Test-Path -LiteralPath $definition -PathType Leaf)) {
            throw "Capture definition CSV not found: $definition`nCreate it first (copy captures.sample.csv), or pass -CsvPath."
        }
        $outputValue = [string](& $value 'OutputDir' '')
        $output = if ($outputValue) { & $resolve $outputValue } else { Join-Path -Path $ScriptRoot -ChildPath 'reports' }
        $logDir = Join-Path -Path $output -ChildPath 'logs'
        $profileValue = [string](& $value 'EdgeProfileDir' '')
        $edgeProfile = if ($profileValue) { & $resolve $profileValue } else { '' }
        $profilePath = if ($edgeProfile) { $edgeProfile } else { $defaultProfileDir }
        $arguments = Get-VouchTaskArguments -ScriptPath $vouchScript -LogDir $logDir -CsvPath $definition -OutputDir $output `
            -ImageFormat ([string](& $value 'ImageFormat' 'jpeg')) -SaveImages ([bool](& $value 'SaveImages' $false)) `
            -FailOnWarning (-not [bool](& $value 'AllowWarnings' $false)) -EdgeProfileDir $edgeProfile -DebugPort $port `
            -UseVirtualDesktop ([bool](& $value 'UseVirtualDesktop' $false))
        $kind = 'csv'
    }

    # Task Scheduler may replace %NAME% in the stored command with the value of that
    # Windows variable, and there is no way to escape it: refuse what it would change.
    if ([System.Environment]::ExpandEnvironmentVariables($arguments) -cne $arguments) {
        throw 'A path contains a name between % signs (like %USERNAME%) that Task Scheduler would replace with its value. Rename that folder or file, or move it to a folder without % in its name. Nothing was scheduled.'
    }
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $concerns.Add('The audit browser profile does not exist yet. Run .\vouch.ps1 -LoginSetup (with the same profile folder) and sign in before the first scheduled run of pages that need a login.')
    }

    return [pscustomobject]@{
        Kind       = $kind
        Definition = $definition
        OutputDir  = $output
        LogDir     = $logDir
        ProfileDir = $profilePath
        ScriptPath = $vouchScript
        Arguments  = $arguments
        Concerns   = $concerns.ToArray()
        Notes      = $notes.ToArray()
    }
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
        1 { return 'The run could not start (bad CSV or configuration file, Edge not found, DevTools port busy) - see the log' }
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
    # Reads a -Name "value" pair back out of the registered task's argument string
    # (a drive root is stored as "D:\\", see ConvertTo-TaskArgument).
    param([string]$Arguments, [string]$Name)
    if ($Arguments -match "-$Name\s+""([^""]+)""") {
        $found = $Matches[1]
        if ($found -match '^[A-Za-z]:\\\\$') { return $found.Substring(0, 3) }
        return $found
    }
    return ''
}

function Get-VouchTask {
    param([string]$Name = $TaskName)
    return Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -eq '\' } | Select-Object -First 1
}

function Get-VouchTaskTarget {
    <#
        What a registered task runs and where its files go, read back from its argument
        string: the configuration or CSV file, the output folder and the transcript
        folder. Without -OutputDir / -LogDir on the task, a configuration file names
        them itself (read from the file as it is now); a CSV task uses the reports
        folder next to the script.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments,
        [Parameter(Mandatory)][string]$ScriptRoot
    )
    $configFile = Get-TaskArgumentValue -Arguments $Arguments -Name 'ConfigPath'
    $csvFile = Get-TaskArgumentValue -Arguments $Arguments -Name 'CsvPath'
    $outputDir = Get-TaskArgumentValue -Arguments $Arguments -Name 'OutputDir'
    $logDir = Get-TaskArgumentValue -Arguments $Arguments -Name 'LogDir'
    $problem = ''
    if ($configFile) {
        $definition = "$configFile (configuration file)"
        if (-not $outputDir -or -not $logDir) {
            $script = Get-TaskArgumentValue -Arguments $Arguments -Name 'File'
            if (-not $script) { $script = Join-Path -Path $ScriptRoot -ChildPath 'vouch.ps1' }
            $loaded = $null
            if (Test-Path -LiteralPath $configFile -PathType Leaf) { $loaded = Read-VouchScheduleConfig -Path $configFile -ScriptPath $script -Quiet }
            if ($null -eq $loaded) {
                $problem = 'The configuration file is missing or has problems now, so the scheduled run will stop at once. Open it in the Vouch Designer, fix it and save.'
            }
            else {
                if (-not $outputDir) { $outputDir = [string]$loaded['output']['dir'] }
                if (-not $logDir) { $logDir = [string]$loaded['output']['logDir'] }
            }
        }
    }
    else {
        if (-not $csvFile) { $csvFile = Join-Path -Path $ScriptRoot -ChildPath 'captures.csv' }
        $definition = "$csvFile (CSV file)"
        if (-not $outputDir) { $outputDir = Join-Path -Path $ScriptRoot -ChildPath 'reports' }
    }
    return [pscustomobject]@{ Definition = $definition; OutputDir = $outputDir; LogDir = $logDir; Problem = $problem }
}

function Show-VouchStatus {
    param(
        [string]$Name = $TaskName,
        [string]$ScriptRoot = $PSScriptRoot
    )
    $task = Get-VouchTask -Name $Name
    if ($null -eq $task) {
        Write-Host "No scheduled task named '$Name'. Install it with .\Install-VouchSchedule.ps1" -ForegroundColor Yellow
        return
    }

    $info = Get-ScheduledTaskInfo -TaskName $Name
    $arguments = [string]$task.Actions[0].Arguments
    $target = Get-VouchTaskTarget -Arguments $arguments -ScriptRoot $ScriptRoot
    $outputDir = $target.OutputDir
    $logDir = $target.LogDir

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

    Write-Host "Task:        $Name ($($task.State))" -ForegroundColor Cyan
    Write-Host "Next run:    $(if ($info.NextRunTime) { $info.NextRunTime } else { 'not scheduled' })"
    Write-Host "Last run:    $lastRun"
    Write-Host "Last result: $(Get-ExitCodeMeaning -Code $info.LastTaskResult)"
    if ($counts) { Write-Host "Last report: $counts" }
    Write-Host "Pages from:  $($target.Definition)"
    Write-Host "Reports go:  $(if ($outputDir) { $outputDir } else { 'unknown' })"
    if ($target.Problem) { Write-Host "Problem:     $($target.Problem)" -ForegroundColor Yellow }
    Write-Host "Command:     $($task.Actions[0].Execute) $arguments"
    Write-Host "Newest report: $(if ($report) { $report.FullName } else { 'none yet' })"
    Write-Host "Newest log:    $(if ($log) { $log.FullName } elseif ($logDir) { 'none yet' } else { 'no console transcript is kept' })"
}

function Install-VouchTask {
    <#
        Checks everything first (Get-VouchScheduleSetup), then registers the task. A
        schedule that cannot work is never registered.
    #>
    param(
        [string]$ScriptRoot = $PSScriptRoot,
        [System.Collections.IDictionary]$Parameters = @{}
    )
    $copy = @{}
    foreach ($key in $Parameters.Keys) { $copy[$key] = $Parameters[$key] }
    $Parameters = $copy
    $value = { param($Name, $Default) if ($Parameters.Contains($Name)) { $Parameters[$Name] } else { $Default } }
    $name = [string](& $value 'TaskName' 'Vouch evidence capture')
    $when = [string](& $value 'Schedule' 'Weekdays')
    $at = [string](& $value 'At' '08:00')
    $days = [string[]](& $value 'DaysOfWeek' @('Monday'))
    $hours = [int](& $value 'MaxRunHours' 2)

    $setup = Get-VouchScheduleSetup -ScriptRoot $ScriptRoot -Parameters $Parameters

    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute (Get-PwshPath) -WorkingDirectory $ScriptRoot -Argument $setup.Arguments
    $trigger = New-VouchTrigger -Schedule $when -At $at -DaysOfWeek $days -UserId $userId
    # Interactive: runs in your signed-in session, the only one with a desktop to capture.
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours $hours) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    $description = 'Captures audit evidence screenshots with vouch.ps1. Needs you signed in with the screen unlocked. Managed by Install-VouchSchedule.ps1.'
    [void](Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $description -Force)

    $whenText = switch ($when) {
        'Weekdays' { "every weekday at $at" }
        'Daily' { "every day at $at" }
        'Weekly' { "every $($days -join ', ') at $at" }
        'AtLogOn' { '3 minutes after you sign in' }
    }
    Write-Host ''
    Write-Host "Scheduled task '$name' installed: runs $whenText." -ForegroundColor Green
    if ($setup.Kind -eq 'config') { Write-Host "  Configuration: $($setup.Definition)" }
    else { Write-Host "  CSV:     $($setup.Definition)" }
    Write-Host "  Reports: $($setup.OutputDir)"
    Write-Host "  Logs:    $($setup.LogDir)"
    if ($setup.Concerns.Count -gt 0) {
        Write-Host ''
        Write-Host 'Please note:' -ForegroundColor Yellow
        foreach ($concern in $setup.Concerns) { Write-Host "  - $concern" -ForegroundColor Yellow }
    }
    foreach ($note in $setup.Notes) { Write-Host "  Note: $note" }
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
    default { Install-VouchTask -Parameters $PSBoundParameters }
}
