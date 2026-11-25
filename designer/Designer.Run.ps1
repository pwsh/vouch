#Requires -Version 7
<#
    Vouch Designer: running and testing from the panel.

    Functions only, dot-sourced next to Designer.ps1 (vouch.ps1 -Designer loads both; the
    tests load both through Get-VouchFunctionSource). A run is a CHILD PROCESS - the same
    vouch.ps1 command line the Run tab shows (Get-VouchCommandLine), run on a copy of what
    the panel shows, plus a few session-only switches - so the Designer's server keeps
    answering while it runs, and a run started here behaves exactly like one started from
    a PowerShell window or a scheduled task.

    The child reports through its NDJSON event file (-EventLogPath), which the server tails
    from its loop (Update-DesignerRun), and is stopped through the stop file next to it.
    While it runs the Designer leaves the audit Edge alone (the child attaches to the same
    tab with -TabId); afterwards it connects again.
#>

#region Run state -------------------------------------------------------------------

function New-DesignerRunState {
    <#
        The run in progress, or the last one. Kept in State.Run; a new run replaces it.
        State is the stored state (idle, starting, running, stopping, done, failed);
        "waitingForUser" is derived from an open prompt when the run is reported.
    #>
    return [pscustomobject]@{
        Number           = 0
        State            = 'idle'
        Kind             = ''
        PageId           = ''
        PageName         = ''
        Process          = $null
        ProcessId        = 0
        OutputTask       = $null
        ErrorTask        = $null
        EventPath        = ''
        StopPath         = ''
        ConfigTempPath   = ''
        PreviewId        = ''
        PreviewFolder    = ''
        StartedAt        = [datetime]::MinValue
        EndedAt          = [datetime]::MinValue
        StopRequestedAt  = [datetime]::MinValue
        # Seconds after a stop request before "Force stop" is offered (Get-DesignerRunGrace).
        GraceSec         = 60
        # Event file reading: bytes read so far, the incomplete last line, lines skipped.
        Offset           = [long]0
        Pending          = [System.IO.MemoryStream]::new()
        Discarding       = $false
        Skipped          = 0
        Dropped          = 0
        Events           = [System.Collections.Generic.List[object]]::new()
        RunId            = ''
        Pages            = [ordered]@{}
        Prompt           = $null
        ErrorMessage     = ''
        RunEnd           = $null
        ExitCode         = $null
        Stopped          = $false
        Counts           = $null
        ReportPath       = ''
        ZipPath          = ''
        LogPath          = ''
        OutputFolder     = ''
        Message          = ''
        Output           = ''
        Forced           = $false
        Unsaved          = $false
        Notes            = [System.Collections.Generic.List[string]]::new()
        Flags            = [System.Collections.Generic.List[object]]::new()
        Arguments        = @()
        TabId            = ''
        # Connect to the audit Edge again when the run ends (it was connected before).
        Reconnect        = $false
        VirtualDesktop   = ''
        PreviewAvailable = $false
    }
}

function Test-DesignerRunActive {
    # Whether a child run is going: the Designer then keeps its hands off the audit Edge.
    param([Parameter(Mandatory)][object]$State)
    return ($null -ne $State.Run -and $State.Run.State -in 'starting', 'running', 'stopping')
}

function Get-DesignerRunDisplayState {
    <#
        The state as the panel shows it. A prompt without its answer means the engine's
        own topmost dialog is waiting for the person: "waitingForUser" (the dialog itself
        is not repeated in the panel; it would be hidden behind the browser anyway).
    #>
    param([Parameter(Mandatory)][object]$Run)
    if ($Run.State -eq 'running' -and $null -ne $Run.Prompt) { return 'waitingForUser' }
    return $Run.State
}

function Get-DesignerSessionFolder {
    <#
        The Designer's own temporary folder for this session: copies of the configuration
        being run, the event files and the previews of page tests. Made on first use and
        removed when the Designer stops (Remove-DesignerSessionFolder). Nothing of the
        person's own files is ever written here or from here.
    #>
    param([Parameter(Mandatory)][object]$State)
    if (-not $State.SessionFolder) {
        $bytes = [byte[]]::new(4)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $State.SessionFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("VouchDesigner-$PID-" + [Convert]::ToHexString($bytes).ToLowerInvariant())
    }
    if (-not [System.IO.Directory]::Exists($State.SessionFolder)) { [void][System.IO.Directory]::CreateDirectory($State.SessionFolder) }
    return $State.SessionFolder
}

function Remove-DesignerSessionFolder {
    # At the end of the Designer: the temporary copies, event files and previews go.
    param([Parameter(Mandatory)][object]$State)
    $State.Previews.Clear()
    if (-not $State.SessionFolder -or -not [System.IO.Directory]::Exists($State.SessionFolder)) { return }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { [System.IO.Directory]::Delete($State.SessionFolder, $true); return }
        catch { [System.Threading.Thread]::Sleep(200) }
    }
    Write-Verbose "The Designer's temporary folder could not be removed: $($State.SessionFolder)"
}

function New-DesignerRandomHex {
    # Random hex for file and preview names nobody can guess (previews are served by this name).
    param([int]$Bytes = 8)
    $buffer = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    return [Convert]::ToHexString($buffer).ToLowerInvariant()
}

#endregion

#region Planning a run ----------------------------------------------------------------

function Get-DesignerRunBaseFolder {
    <#
        The folder relative paths in the configuration are read from: the saved file's
        folder (as for any run of the file), or - for a configuration never saved - the
        person's Documents\Vouch folder, so a first test does not scatter reports into
        whatever folder the Designer happened to start in.
    #>
    param([AllowEmptyString()][string]$ConfigPath = '')
    if ($ConfigPath) { return (Split-Path -Path ([System.IO.Path]::GetFullPath($ConfigPath)) -Parent) }
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if (-not $documents) { $documents = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents' }
    return (Join-Path -Path $documents -ChildPath 'Vouch')
}

function Set-DesignerConfigPathValue {
    # Writes one path setting into a configuration copy, making the section when it is missing.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value)
    if ($Config[$Section] -isnot [System.Collections.IDictionary]) { $Config[$Section] = [ordered]@{} }
    $Config[$Section][$Key] = $Value
}

function Resolve-DesignerRunConfig {
    <#
        The copy of the shown configuration a run reads. It lives in the session folder,
        so its relative paths (output folder, log folder, logo, browser profile) are made
        absolute against the folder the person's file is in (Get-DesignerRunBaseFolder),
        exactly as the engine would resolve them for the saved file. Nothing else changes.
        Returns { Config; OutputFolder }.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$BaseFolder)
    $copy = Copy-VouchConfig -Config (Repair-VouchConfigKeyCase -Config $Config)
    $defaults = Get-DefaultVouchConfig
    $output = ''
    foreach ($entry in @(@('browser', 'profileDir'), @('output', 'dir'), @('output', 'logDir'), @('report', 'logoPath'))) {
        $found = Get-ConfigValue -Config $copy -Section $entry[0] -Key $entry[1]
        $value = if ($found.Found -and $found.Value -is [string]) { [string]$found.Value } else { '' }
        if ($entry[1] -eq 'dir' -and -not $value) { $value = [string]$defaults['output']['dir'] }
        if (-not $value) { continue }
        $full = Resolve-VouchConfigPath -Path $value.Trim() -BaseDirectory $BaseFolder
        Set-DesignerConfigPathValue -Config $copy -Section $entry[0] -Key $entry[1] -Value $full
        if ($entry[1] -eq 'dir') { $output = $full }
    }
    return [pscustomobject]@{ Config = $copy; OutputFolder = $output }
}

function Get-DesignerRunGrace {
    <#
        How long to wait after a stop request before offering "Force stop": the engine
        notices the stop file between steps, but a navigation already under way finishes
        first, so the longest page-load time limit in the file plus 30 seconds.
    #>
    param([AllowNull()][System.Collections.IDictionary]$Config)
    $longest = 30
    $found = Get-ConfigValue -Config $Config -Section 'defaults' -Key 'navigationTimeoutSec'
    if ($found.Found -and $found.Value -is [ValueType] -and $found.Value -isnot [bool]) { $longest = [int]$found.Value }
    if ($null -ne $Config -and $Config['pages'] -is [System.Collections.IEnumerable]) {
        foreach ($page in $Config['pages']) {
            if ($page -isnot [System.Collections.IDictionary] -or $page['overrides'] -isnot [System.Collections.IDictionary]) { continue }
            $value = $page['overrides']['navigationTimeoutSec']
            if ($value -is [ValueType] -and $value -isnot [bool] -and [int]$value -gt $longest) { $longest = [int]$value }
        }
    }
    return $longest + 30
}

function Find-DesignerRunPage {
    # The page a page test runs: its id (as -Only reads it) and name, or $null.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [AllowEmptyString()][string]$PageId)
    if (-not $PageId -or $Config['pages'] -isnot [System.Collections.IEnumerable]) { return $null }
    $position = 0
    foreach ($page in $Config['pages']) {
        $position++
        if ($page -isnot [System.Collections.IDictionary]) { continue }
        $id = Get-VouchPageId -Page $page -Position $position
        if ($id -ceq $PageId.Trim()) {
            $name = if ($page['name'] -is [string] -and $page['name'].Trim()) { $page['name'].Trim() } else { "Page $position" }
            return [pscustomobject]@{ Id = $id; Name = (ConvertTo-DesignerText -Value $name -Max 120); Position = $position }
        }
    }
    return $null
}

function Test-DesignerConfigUnsaved {
    <#
        Whether the shown configuration differs from the saved file (compared in canonical
        form, so key order and spacing do not count). A configuration never saved is
        "unsaved" too. The panel says "Running your current edits (not yet saved)" then.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [AllowEmptyString()][string]$ConfigPath = '')
    if (-not $ConfigPath) { return $true }
    try {
        $onDisk = Read-DesignerConfigFile -Path $ConfigPath
        return (ConvertTo-VouchConfigText -Config (Repair-VouchConfigKeyCase -Config $Config)) -cne (ConvertTo-VouchConfigText -Config $onDisk.Config)
    }
    catch { return $true }
}

function Get-DesignerRunPlan {
    <#
        Everything decided before a run starts, without starting it (so POST /api/run/plan
        can show it in the Run tab first): the problems that block it (Test-VouchConfig,
        the same messages Save shows), the page a page test runs, the folder relative paths
        are read from and the resolved output folder, whether unsaved edits are being run,
        and what happens to the virtual-desktop setting.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [AllowEmptyString()][string]$ConfigPath = '',
        [ValidateSet('full', 'page')][string]$Kind = 'full',
        [AllowEmptyString()][string]$PageId = ''
    )
    $config = Repair-VouchConfigKeyCase -Config $Config
    $check = Test-VouchConfig -Config $config
    $base = Get-DesignerRunBaseFolder -ConfigPath $ConfigPath
    $plan = [pscustomobject]@{
        Kind = $Kind; PageId = ''; PageName = ''; Errors = $check.Errors; Warnings = $check.Warnings
        ConfigPath = $ConfigPath; BaseFolder = $base; OutputFolder = ''; Unsaved = $true; Config = $null
        VirtualDesktop = 'off'; Notes = [System.Collections.Generic.List[string]]::new(); Problem = ''
    }
    $plan.Unsaved = Test-DesignerConfigUnsaved -Config $config -ConfigPath $ConfigPath
    if ($Kind -eq 'page') {
        $page = Find-DesignerRunPage -Config $config -PageId $PageId
        if ($null -eq $page) { $plan.Problem = 'Choose the page to test first: the page shown is not in the configuration.' }
        else { $plan.PageId = $page.Id; $plan.PageName = $page.Name }
    }
    if ($check.Errors.Count -gt 0) { return $plan }
    $resolved = Resolve-DesignerRunConfig -Config $config -BaseFolder $base
    $plan.Config = $resolved.Config
    $plan.OutputFolder = $resolved.OutputFolder
    if (-not $ConfigPath) {
        $plan.Notes.Add("This configuration has not been saved yet, so its folders are read from $base.")
    }
    $wantsDesktop = (Get-ConfigValue -Config $config -Section 'browser' -Key 'useVirtualDesktop').Value -eq $true
    if ($wantsDesktop) {
        if ($Kind -eq 'page') {
            $plan.VirtualDesktop = 'ignored'
            $plan.Notes.Add('A page test never uses a separate virtual desktop; it captures in the audit Edge you see.')
        }
        elseif ($State.Browser.LaunchedByDesigner -and $State.Browser.LaunchedPid -gt 0) {
            $plan.VirtualDesktop = 'used'
            $plan.Notes.Add('For a separate virtual desktop the Designer closes the audit Edge it opened, the run opens its own on that desktop, and the Designer opens Edge again when the run ends.')
        }
        else {
            $plan.VirtualDesktop = 'skipped'
            $plan.Notes.Add('This run does not use a separate virtual desktop: the audit Edge was already open before the Designer started, and Vouch closes only an Edge it opened itself. To use one, close that Edge and press Retry in the Designer, or run the command below from a PowerShell window.')
        }
    }
    if ($Kind -eq 'page') {
        $plan.Notes.Add('A page test saves its report and images in a temporary preview folder (never in the output folder), makes no zip and does not open the report; the preview is shown here.')
    }
    return $plan
}

function Get-DesignerRunSessionFlag {
    <#
        The switches the Designer adds to the command for this run only, each with the
        sentence the Run tab shows. Everything else comes from the configuration copy, so
        the run is the shown command with these added.
        - -EventLogPath: progress and the stop file (always).
        - -TabId / -DebugPort / -EdgeProfileDir: attach to the audit Edge and tab the
          Designer is linked to (its port and profile may have been typed with -Designer).
        - Page test: -Only the page, its own preview folder, image files kept for the
          preview, no zip, no opening of the report, no transcript, no virtual desktop.
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Plan, [Parameter(Mandatory)][string]$EventPath, [AllowEmptyString()][string]$PreviewFolder = '', [AllowEmptyString()][string]$TabId = '')
    $flags = [System.Collections.Generic.List[object]]::new()
    $add = { param($Arguments, $Note) $flags.Add([pscustomobject]@{ Arguments = [string[]]$Arguments; Note = $Note }) }
    & $add @('-EventLogPath', $EventPath) 'Progress for this window (-EventLogPath, a file in the Designer''s temporary folder).'
    $browser = $State.Browser
    if ($TabId -and $Plan.VirtualDesktop -ne 'used') {
        & $add @('-TabId', $TabId) 'The tab the Designer shows (-TabId).'
    }
    if ($browser.Port -gt 0) {
        & $add @('-DebugPort', [string]$browser.Port) "The audit Edge the Designer is connected to (-DebugPort $($browser.Port))."
        if ($browser.ProfileDir) { & $add @('-EdgeProfileDir', $browser.ProfileDir) 'Its profile folder (-EdgeProfileDir).' }
    }
    if ($browser.TypedKeepOpen) { & $add @('-KeepBrowserOpen') 'Keep the browser open (-KeepBrowserOpen, typed when the Designer was started).' }
    if ($Plan.Kind -eq 'page') {
        & $add @('-Only', $Plan.PageId) "Only this page (-Only $($Plan.PageId))."
        & $add @('-OutputDir', $PreviewFolder) 'A temporary preview folder instead of the output folder (-OutputDir).'
        & $add @('-SaveImages') 'Image files for the preview (-SaveImages).'
        & $add @('-Zip:$false') 'No zip (-Zip:$false).'
        & $add @('-OpenReport:$false') 'The report is shown here, not opened (-OpenReport:$false).'
        & $add @('-LogDir', '') 'No console transcript (-LogDir "").'
    }
    if ($Plan.VirtualDesktop -in 'ignored', 'skipped') {
        & $add @('-UseVirtualDesktop:$false') 'No separate virtual desktop (-UseVirtualDesktop:$false).'
    }
    return , $flags
}

#endregion

#region Starting, following and stopping ---------------------------------------------------

function Start-DesignerChildProcess {
    <#
        Starts the run without a window. The arguments go to ProcessStartInfo.ArgumentList
        one by one, so .NET quotes each for Windows; no command string is ever put together
        here (a value with quotes, $, % or & reaches the engine as it is). Output and errors
        are redirected and read asynchronously by .NET - nothing in this process waits on
        them - so a chatty run never blocks on a full pipe; they give the last error text
        when a run cannot start. Its own function so the tests can see the arguments.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgumentList,
        [AllowEmptyString()][string]$WorkingDirectory = ''
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    $process = [System.Diagnostics.Process]::Start($info)
    try { $process.StandardInput.Close() } catch { Write-Verbose 'The run''s input was already closed.' }
    return $process
}

function Stop-DesignerChildProcess {
    # Force stop: the run's process and everything it started (only the tree the Designer started).
    param([AllowNull()][object]$Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { $Process.Kill($true) }
        [void]$Process.WaitForExit(10000)
    }
    catch { Write-Verbose "The run could not be ended: $($_.Exception.Message)" }
}

function Stop-DesignerBrowserForRun {
    <#
        Hands the audit Edge to the run: ends a pick, takes the zoom preview off and closes
        the Designer's DevTools connection (the run attaches to the same tab with -TabId).
        From now until the run ends nothing in the Designer touches the browser: the tick
        does not reconnect or look at tabs (Test-DesignerRunActive), and the browser routes
        answer 409.
    #>
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    if ($State.Pick.State -eq 'picking') { Stop-ElementPick -State $State -Message 'Picking stopped because a run started.' -NoLayout }
    if ($browser.Connected) { [void](Set-DesignerZoomPreview -State $State -Percent 100) }
    if ($null -ne $script:CdpSocket) { Close-CdpSocket }
    $script:PageZoomPercent = 100
    $browser.Connected = $false
    $browser.Connecting = $false
    $browser.ConnectPending = $false
    $browser.ZoomPercent = 100
    $browser.ZoomPage = ''
    $browser.Notice = ''
}

function Close-DesignerEdgeForRun {
    <#
        Virtual desktop: a reused Edge never gets one (the engine attaches to it where it
        is), so for a full run the Designer closes the audit Edge it opened itself and lets
        the run open its own. An Edge the Designer merely found is never closed (see
        Get-DesignerRunPlan: the run then goes without the virtual desktop).
    #>
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    $process = Get-Process -Id $browser.LaunchedPid -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        $script:LaunchedEdge = $true
        $script:EdgeProcess = $process
        $script:BrowserWsUrl = $browser.BrowserWsUrl
        Stop-EdgeProcess
    }
    $script:LaunchedEdge = $false
    $browser.LaunchedByDesigner = $false
    $browser.LaunchedPid = 0
    $browser.TabId = ''
}

function Start-DesignerRun {
    <#
        Starts a planned run (Get-DesignerRunPlan, without errors) as a child process:
        writes the configuration copy into the session folder, builds the argument list
        from Get-VouchCommandLine (the generator of the shown command) plus the session
        flags, hands the browser over and starts the child hidden. Returns the run; throws
        a plain message when the child cannot be started (the browser is connected again).
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Plan)
    if (Test-DesignerRunActive -State $State) { throw 'A run is already going. Wait until it ends, or stop it.' }
    $folder = Get-DesignerSessionFolder -State $State
    $State.RunCount++
    $run = New-DesignerRunState
    $run.Number = $State.RunCount
    $run.Kind = $Plan.Kind
    $run.PageId = $Plan.PageId
    $run.PageName = $Plan.PageName
    $run.Unsaved = [bool]$Plan.Unsaved
    $run.VirtualDesktop = $Plan.VirtualDesktop
    $run.GraceSec = Get-DesignerRunGrace -Config $Plan.Config
    foreach ($note in $Plan.Notes) { $run.Notes.Add($note) }
    $stem = 'run-{0:d3}-{1}' -f $run.Number, (New-DesignerRandomHex -Bytes 4)
    $run.ConfigTempPath = Join-Path -Path $folder -ChildPath "$stem.json"
    $run.EventPath = Join-Path -Path $folder -ChildPath "$stem.events.ndjson"
    $run.StopPath = "$($run.EventPath).stop"
    $run.OutputFolder = $Plan.OutputFolder
    if ($Plan.Kind -eq 'page') {
        # A newer test of the same page replaces the older preview, files and all.
        Remove-DesignerPreview -State $State -PageId $Plan.PageId
        $run.PreviewId = New-DesignerRandomHex -Bytes 16
        $safe = $Plan.PageId -replace '[^A-Za-z0-9_-]', '_'
        if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
        $run.PreviewFolder = Join-Path -Path $folder -ChildPath ("preview-$safe-$(New-DesignerRandomHex -Bytes 4)")
        [void][System.IO.Directory]::CreateDirectory($run.PreviewFolder)
        $run.OutputFolder = $run.PreviewFolder
        $State.OpenTargets.Remove('preview-report')
    }
    else {
        foreach ($kind in 'report', 'folder', 'log', 'zip') { $State.OpenTargets.Remove($kind) }
    }
    [System.IO.File]::WriteAllText($run.ConfigTempPath, (ConvertTo-VouchConfigText -Config $Plan.Config), [System.Text.UTF8Encoding]::new($false))

    if ($null -eq $State.RunParameterInfo) { $State.RunParameterInfo = Get-VouchParameterInfo -ScriptPath $State.RunScriptPath }
    $command = Get-VouchCommandLine -Config $Plan.Config -ConfigPath $run.ConfigTempPath -ScriptPath $State.RunScriptPath -ParameterInfo $State.RunParameterInfo

    $run.Reconnect = [bool]$State.Browser.Connected
    $run.TabId = if ($State.Browser.Connected) { [string]$State.Browser.TabId } else { '' }
    $flags = Get-DesignerRunSessionFlag -State $State -Plan $Plan -EventPath $run.EventPath -PreviewFolder $run.PreviewFolder -TabId $run.TabId
    foreach ($flag in $flags) { $run.Flags.Add($flag) }
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $command.RunArguments) { $arguments.Add($argument) }
    foreach ($flag in $flags) { foreach ($argument in $flag.Arguments) { $arguments.Add($argument) } }
    $run.Arguments = $arguments.ToArray()

    Stop-DesignerBrowserForRun -State $State
    if ($Plan.VirtualDesktop -eq 'used') {
        Close-DesignerEdgeForRun -State $State
        $run.Reconnect = $true
    }
    $State.Run = $run
    $run.State = 'starting'
    $run.StartedAt = Get-Date
    try {
        $pwsh = [Environment]::ProcessPath
        if (-not $pwsh -or [System.IO.Path]::GetFileNameWithoutExtension($pwsh) -notmatch '^pwsh') { $pwsh = (Get-Process -Id $PID).Path }
        $run.Process = Start-DesignerChildProcess -FilePath $pwsh -ArgumentList $run.Arguments -WorkingDirectory $folder
        $run.ProcessId = $run.Process.Id
        $run.OutputTask = $run.Process.StandardOutput.ReadToEndAsync()
        $run.ErrorTask = $run.Process.StandardError.ReadToEndAsync()
    }
    catch {
        $run.State = 'failed'
        $run.EndedAt = Get-Date
        $run.Message = "The run could not be started: $($_.Exception.Message)"
        Remove-DesignerRunFile -Run $run
        Restore-DesignerBrowserAfterRun -State $State
        throw $run.Message
    }
    return $run
}

function Remove-DesignerRunFile {
    # The configuration copy and a stop file left behind; the event file stays for the session.
    param([Parameter(Mandatory)][object]$Run)
    foreach ($path in $Run.ConfigTempPath, $Run.StopPath) {
        if ($path) { try { [System.IO.File]::Delete($path) } catch { Write-Verbose "Not removed: $path" } }
    }
}

function Read-DesignerRunEvent {
    <#
        Reads what the run appended to its event file since the last look and applies each
        COMPLETE line (Add-DesignerRunEvent). Never blocks the loop: it reads what is there
        (at most -MaxBytes per call) with sharing that lets the run keep writing. An
        incomplete last line waits for its end; a line longer than -MaxLineBytes, or one
        that is not a JSON object with a "type", is skipped and counted. -Final treats an
        incomplete last line as lost (the run has ended). Returns the number of events.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Run,
        [switch]$Final,
        [int]$MaxBytes = 1MB,
        [int]$MaxLineBytes = 1MB
    )
    $added = 0
    for ($round = 0; $round -lt 64; $round++) {
        if (-not $Run.EventPath -or -not [System.IO.File]::Exists($Run.EventPath)) { break }
        $buffer = $null
        $read = 0
        try {
            $stream = [System.IO.FileStream]::new($Run.EventPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                $available = $stream.Length - $Run.Offset
                if ($available -gt 0) {
                    [void]$stream.Seek($Run.Offset, [System.IO.SeekOrigin]::Begin)
                    $buffer = [byte[]]::new([int][Math]::Min([long]$MaxBytes, $available))
                    while ($read -lt $buffer.Length) {
                        $n = $stream.Read($buffer, $read, $buffer.Length - $read)
                        if ($n -le 0) { break }
                        $read += $n
                    }
                }
            }
            finally { $stream.Dispose() }
        }
        catch { Write-Verbose "The run's event file could not be read yet: $($_.Exception.Message)"; break }
        if ($read -le 0) { break }
        $Run.Offset += $read
        $start = 0
        while ($start -lt $read) {
            $newline = [Array]::IndexOf($buffer, [byte]10, $start, $read - $start)
            $end = if ($newline -ge 0) { $newline } else { $read }
            $count = $end - $start
            if (-not $Run.Discarding) {
                if ($Run.Pending.Length + $count -gt $MaxLineBytes) { $Run.Discarding = $true; $Run.Pending.SetLength(0) }
                elseif ($count -gt 0) { $Run.Pending.Write($buffer, $start, $count) }
            }
            if ($newline -lt 0) { break }
            if ($Run.Discarding) { $Run.Discarding = $false; $Run.Skipped++ }
            else {
                $text = [System.Text.Encoding]::UTF8.GetString($Run.Pending.GetBuffer(), 0, [int]$Run.Pending.Length)
                $Run.Pending.SetLength(0)
                if (Add-DesignerRunLine -State $State -Run $Run -Text $text) { $added++ }
            }
            $start = $newline + 1
        }
        if (-not $Final -and $read -lt $MaxBytes) { break }
    }
    if ($Final -and ($Run.Pending.Length -gt 0 -or $Run.Discarding)) {
        $Run.Skipped++
        $Run.Pending.SetLength(0)
        $Run.Discarding = $false
    }
    return $added
}

function Add-DesignerRunLine {
    # One line of the event file: a JSON object with a "type" is an event; anything else is skipped.
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Run, [AllowEmptyString()][string]$Text)
    $line = $Text.Trim()
    if (-not $line) { return $false }
    $event = $null
    try { $event = ConvertFrom-VouchJson -Text $line } catch { $event = $null }
    if ($event -isnot [System.Collections.IDictionary] -or $event['type'] -isnot [string]) { $Run.Skipped++; return $false }
    Add-DesignerRunEvent -State $State -Run $Run -Event $event
    return $true
}

function Get-DesignerRunPageEntry {
    # The progress entry of the page an event belongs to (made at pageStart), or $null.
    param([Parameter(Mandatory)][object]$Run, [Parameter(Mandatory)][System.Collections.IDictionary]$Event, [switch]$Create)
    $id = ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Event -Name 'pageId') -Max 100
    $index = Get-DesignerBodyNumber -Body $Event -Name 'pageIndex'
    $key = if ($id) { "id:$id" } else { "index:$index" }
    if ($Run.Pages.Contains($key)) { return $Run.Pages[$key] }
    if (-not $Create) { return $null }
    $entry = [ordered]@{
        pageId = $id; index = (Get-DesignerBodyNumber -Body $Event -Name 'index'); total = (Get-DesignerBodyNumber -Body $Event -Name 'total')
        name = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Event -Name 'name') -Max 200)
        url = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Event -Name 'url') -Max 2000)
        status = 'RUNNING'; captureCount = 0
        details = [System.Collections.Generic.List[string]]::new()
        images = [System.Collections.Generic.List[object]]::new()
    }
    $Run.Pages[$key] = $entry
    return $entry
}

function Add-DesignerRunEvent {
    <#
        Applies one event of the run's stream (schema: Tasks 5 and 6) to what the panel
        shows: the run's state, each page's status, image count and details, an open
        question in the Vouch dialog, and at the end the paths of THIS run's report, folder,
        capture log and zip (the only paths /api/open will ever open for it).
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Run, [Parameter(Mandatory)][System.Collections.IDictionary]$Event)
    if ($Run.Events.Count -lt 20000) { $Run.Events.Add($Event) } else { $Run.Dropped++ }
    $type = [string]$Event['type']
    $text = { param($Name, $Max) ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Event -Name $Name) -Max $Max }
    switch -CaseSensitive ($type) {
        'runStart' {
            if ($Run.State -eq 'starting') { $Run.State = 'running' }
            $Run.RunId = & $text 'runId' 100
            $folder = & $text 'outputDir' 2000
            if ($folder) { $Run.OutputFolder = $folder }
        }
        'pageStart' { [void](Get-DesignerRunPageEntry -Run $Run -Event $Event -Create) }
        'capture' {
            $entry = Get-DesignerRunPageEntry -Run $Run -Event $Event -Create
            $entry.captureCount++
            if ($entry.images.Count -lt 200) {
                $entry.images.Add([ordered]@{
                        fileName = (& $text 'fileName' 260); label = (& $text 'label' 200)
                        segment = (Get-DesignerBodyNumber -Body $Event -Name 'segment'); segmentCount = (Get-DesignerBodyNumber -Body $Event -Name 'segmentCount')
                    })
            }
        }
        'detail' {
            $entry = Get-DesignerRunPageEntry -Run $Run -Event $Event -Create
            $status = & $text 'status' 20
            if ($status -cin 'OK', 'WARNING', 'FAILED' -and $entry.status -ne 'FAILED') { $entry.status = $(if ($status -eq 'OK') { 'RUNNING' } else { $status }) }
            if ($entry.details.Count -lt 100) { $entry.details.Add((& $text 'text' 2000)) }
        }
        'prompt' {
            $Run.Prompt = [ordered]@{ kind = (& $text 'kind' 40); title = (& $text 'title' 300); message = (& $text 'message' 2000); pageName = (& $text 'pageName' 200) }
        }
        'promptResult' { $Run.Prompt = $null }
        'pageEnd' {
            $entry = Get-DesignerRunPageEntry -Run $Run -Event $Event -Create
            $status = & $text 'status' 20
            $entry.status = if ($status -cin 'OK', 'WARNING', 'FAILED') { $status } else { 'WARNING' }
            $entry.captureCount = [Math]::Max(0, (Get-DesignerBodyNumber -Body $Event -Name 'captureCount'))
            $details = Get-DesignerValue -Object $Event -Name 'details'
            if ($details -is [System.Collections.IEnumerable] -and $details -isnot [string]) {
                $entry.details.Clear()
                foreach ($detail in $details) { if ($entry.details.Count -lt 100) { $entry.details.Add((ConvertTo-DesignerText -Value $detail -Max 2000)) } }
            }
            $Run.Prompt = $null
            if ($entry.pageId) {
                $summary = if ($entry.details.Count -gt 0) { $entry.details[0] } else { '' }
                $State.PageResults[$entry.pageId] = [ordered]@{ status = $entry.status; kind = $Run.Kind; time = (Get-Date).ToString('HH:mm'); text = $summary; captureCount = $entry.captureCount }
            }
        }
        'error' { $Run.ErrorMessage = & $text 'message' 2000 }
        'runEnd' {
            $Run.RunEnd = $Event
            $Run.Prompt = $null
            $code = Get-DesignerValue -Object $Event -Name 'exitCode'
            if ($code -is [ValueType] -and $code -isnot [bool]) { $Run.ExitCode = [int]$code }
            $Run.Stopped = (Get-DesignerValue -Object $Event -Name 'stopped') -eq $true
            $counts = Get-DesignerValue -Object $Event -Name 'counts'
            if ($counts -is [System.Collections.IDictionary]) {
                $Run.Counts = [ordered]@{}
                foreach ($name in 'pages', 'run', 'ok', 'warning', 'failed', 'notRun', 'captures') { $Run.Counts[$name] = [Math]::Max(0, (Get-DesignerBodyNumber -Body $counts -Name $name)) }
            }
            $Run.ReportPath = & $text 'reportPath' 2000
            $Run.ZipPath = & $text 'zipPath' 2000
            $Run.LogPath = & $text 'logPath' 2000
        }
    }
}

function Get-DesignerRunOutput {
    # What the run wrote to its console (output and errors), for a run that could not start: the last part, plain text.
    param([Parameter(Mandatory)][object]$Run, [int]$Max = 2000)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($task in $Run.OutputTask, $Run.ErrorTask) {
        if ($null -eq $task) { continue }
        try { if ($task.Wait(3000)) { $parts.Add([string]$task.Result) } } catch { Write-Verbose 'The run''s console text could not be read.' }
    }
    $text = ($parts -join "`n") -replace "`e\[[0-9;?]*[A-Za-z]", '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
    $text = ($text -replace "`r`n", "`n").Trim()
    if ($text.Length -gt $Max) { $text = [char]0x2026 + $text.Substring($text.Length - ($Max - 1)) }
    return $text
}

function Get-DesignerRunErrorText {
    # The reason a run could not start: the engine's own error event, else its last "ERROR:" line, else the end of its output.
    param([Parameter(Mandatory)][object]$Run)
    if ($Run.ErrorMessage) { return $Run.ErrorMessage }
    $lines = @($Run.Output -split "`n" | Where-Object { $_.Trim() })
    $errorLine = $lines | Where-Object { $_ -match '^\s*ERROR:\s*' } | Select-Object -Last 1
    if ($errorLine) { return ($errorLine -replace '^\s*ERROR:\s*', '').Trim() }
    if ($lines.Count -gt 0) { return (($lines | Select-Object -Last 6) -join "`n") }
    return ''
}

function Get-DesignerRunOutcome {
    <#
        The engine's exit code in plain words (0 all good, 2 some pages failed, 3 warnings
        with "fail on warning", 1 could not start); a run that ended without its runEnd
        event, or was forced to stop, is a failure said as such.
    #>
    param([Parameter(Mandatory)][object]$Run, [int]$ProcessExitCode = 0)
    $counts = $Run.Counts
    if ($Run.Forced) {
        return 'You force-stopped the run. Its report may be missing or incomplete.'
    }
    if ($null -eq $Run.RunEnd) {
        $why = Get-DesignerRunErrorText -Run $Run
        if ($ProcessExitCode -eq 1 -and $Run.Pages.Count -eq 0) {
            if ($why) { return "The run could not start: $why" }
            return 'The run could not start, and it gave no reason.'
        }
        $text = "The run ended unexpectedly (exit code $ProcessExitCode) before it finished its report."
        if ($why) { $text += " What it said last: $why" }
        return $text
    }
    switch ($ProcessExitCode) {
        0 {
            if ($Run.Stopped) {
                $done = if ($null -ne $counts) { "$($counts['run']) of $($counts['pages'])" } else { 'some' }
                return "Stopped by you after $done page(s). The report has what was captured until then."
            }
            if ($null -ne $counts -and $counts['warning'] -gt 0) { return "Finished: $($counts['run']) page(s) captured, $($counts['warning']) with warnings. Look at the warnings before you rely on the report." }
            return 'Finished: every page was captured without problems.'
        }
        2 {
            $failed = if ($null -ne $counts) { $counts['failed'] } else { 'Some' }
            return "Finished, but $failed page(s) failed. The report shows what went wrong on each."
        }
        3 { return 'Finished with warnings, and "Fail on warnings" is on, so the run counts as not passed (exit code 3). The report shows the warnings.' }
        1 {
            $why = Get-DesignerRunErrorText -Run $Run
            if ($why) { return "The run could not start: $why" }
            return 'The run could not start.'
        }
        default { return "The run ended with exit code $ProcessExitCode." }
    }
}

function Update-DesignerRun {
    <#
        The run's share of each loop turn (about every 200 ms): read what the run wrote,
        notice when it has ended, and - when the Designer is closing - force it to stop
        once the grace time after the stop request has passed. Never waits on the run.
    #>
    param([Parameter(Mandatory)][object]$State)
    if (-not (Test-DesignerRunActive -State $State)) { return }
    $run = $State.Run
    [void](Read-DesignerRunEvent -State $State -Run $run)
    $exited = $true
    try { $exited = ($null -eq $run.Process) -or $run.Process.HasExited } catch { $exited = $true }
    if ($exited) { Complete-DesignerRun -State $State; return }
    if ($State.ShutdownAfterRun -and (Test-DesignerRunForceAvailable -Run $run)) {
        [void](Stop-DesignerRun -State $State -Force)
    }
}

function Test-DesignerRunForceAvailable {
    # "Force stop" is offered only after a stop request has had its grace time (Get-DesignerRunGrace).
    param([Parameter(Mandatory)][object]$Run)
    if ($Run.State -ne 'stopping' -or $Run.StopRequestedAt -eq [datetime]::MinValue) { return $false }
    return ((Get-Date) - $Run.StopRequestedAt).TotalSeconds -ge $Run.GraceSec
}

function Complete-DesignerRun {
    <#
        The child has ended: the last events are read, the exit code (the final truth) is
        put into words, the paths of THIS run become openable, a page test's preview is
        registered, the temporary copy and stop file go, and the Designer connects to the
        audit Edge again.
    #>
    param([Parameter(Mandatory)][object]$State)
    $run = $State.Run
    [void](Read-DesignerRunEvent -State $State -Run $run -Final)
    $exitCode = -1
    try { if ($null -ne $run.Process) { [void]$run.Process.WaitForExit(5000); $exitCode = $run.Process.ExitCode } } catch { $exitCode = -1 }
    $run.Output = Get-DesignerRunOutput -Run $run
    $run.EndedAt = Get-Date
    $run.Prompt = $null
    $finished = $null -ne $run.RunEnd -and -not $run.Forced -and $exitCode -in 0, 2, 3
    $run.Message = Get-DesignerRunOutcome -Run $run -ProcessExitCode $exitCode
    $run.ExitCode = $exitCode
    $run.State = if ($finished) { 'done' } else { 'failed' }
    if ($null -ne $run.RunEnd) {
        if ($run.Kind -eq 'page') {
            if ($run.ReportPath) { $State.OpenTargets['preview-report'] = $run.ReportPath }
        }
        else {
            if ($run.ReportPath) { $State.OpenTargets['report'] = $run.ReportPath; $State.OpenTargets['folder'] = Split-Path -Path $run.ReportPath -Parent }
            if ($run.LogPath) { $State.OpenTargets['log'] = $run.LogPath }
            if ($run.ZipPath) { $State.OpenTargets['zip'] = Split-Path -Path $run.ZipPath -Parent }
        }
    }
    if ($run.Kind -eq 'page') { Register-DesignerPreview -State $State -Run $run }
    Remove-DesignerRunFile -Run $run
    try { if ($null -ne $run.Process) { $run.Process.Dispose() } } catch { Write-Verbose 'The run''s process was already released.' }
    $run.Process = $null
    Restore-DesignerBrowserAfterRun -State $State
    if ($State.ShutdownAfterRun) {
        $State.Running = $false
        $State.StopReason = 'The run was stopped and the Designer was closed from its window.'
    }
}

function Restore-DesignerBrowserAfterRun {
    <#
        After a run: connect to the audit Edge again (Connect-DesignerBrowser; after a
        virtual-desktop run that opens Edge again), back to the tab the run used when it
        is still there, with no zoom left on it (a run clears its zoom when it ends; a
        forced stop takes it with the run's connection - cleared here in any case), and
        the windows side by side with the panel in front. Nothing else is re-applied.
    #>
    param([Parameter(Mandatory)][object]$State)
    $run = $State.Run
    $browser = $State.Browser
    $browser.ZoomPercent = 100
    $browser.ZoomPage = ''
    $script:PageZoomPercent = 100
    if (-not $run.Reconnect) { return }
    try {
        Connect-DesignerBrowser -State $State
        if ($browser.Connected -and $run.TabId -and $browser.TabId -ne $run.TabId) {
            $tabs = Get-DesignerWebTab -State $State -Targets @(Get-DevToolsTargetList -Port $browser.Port)
            $same = $tabs | Where-Object { [string](Get-DesignerValue -Object $_ -Name 'id') -eq $run.TabId } | Select-Object -First 1
            if ($null -ne $same) {
                Connect-DesignerTab -State $State -Target $same
                Set-DesignerTabInfo -State $State -Tabs $tabs
            }
        }
        if ($browser.Connected) {
            try { Clear-PageZoom } catch { Write-Verbose "No zoom to clear: $($_.Exception.Message)" }
            [void](Set-DesignerLayout -State $State -Focus panel)
        }
    }
    catch { Write-Verbose "The browser could not be connected again after the run: $($_.Exception.Message)" }
}

function Stop-DesignerRun {
    <#
        Stop: creates the run's stop file; the engine finishes the current step, ends the
        page, and still writes the report. -Force (offered only after the grace time) ends
        the child's process tree - only the one the Designer started - and says the report
        may be missing. Returns $null, or a refusal.
    #>
    param([Parameter(Mandatory)][object]$State, [switch]$Force, [switch]$Immediately)
    $run = $State.Run
    if (-not (Test-DesignerRunActive -State $State)) {
        return New-DesignerError -Status 409 -Code 'not-running' -Message 'Nothing is running.' -Detail 'There is no run to stop.'
    }
    if ($Force) {
        if (-not $Immediately -and -not (Test-DesignerRunForceAvailable -Run $run)) {
            return New-DesignerError -Status 409 -Code 'too-early' -Message 'The run is still stopping.' -Detail "Force stop is offered when the run has not stopped $($run.GraceSec) seconds after you asked."
        }
        $run.Forced = $true
        Stop-DesignerChildProcess -Process $run.Process
        Complete-DesignerRun -State $State
        return $null
    }
    if ($run.StopRequestedAt -eq [datetime]::MinValue) {
        try { [System.IO.File]::WriteAllText($run.StopPath, '') }
        catch { return New-DesignerError -Status 500 -Code 'stop' -Message 'The run could not be told to stop.' -Detail ([string]$_.Exception.Message) }
        $run.StopRequestedAt = Get-Date
    }
    $run.State = 'stopping'
    return $null
}

function Stop-DesignerRunForExit {
    <#
        The Designer is closing (its window closed, /api/shutdown or Ctrl+C) while a run is
        going: stop it cleanly first and give it its grace time, reading its events
        meanwhile; only then end it by force. The browser is not connected again.
    #>
    param([Parameter(Mandatory)][object]$State)
    if (-not (Test-DesignerRunActive -State $State)) { return }
    $run = $State.Run
    $run.Reconnect = $false
    Write-Host 'A run is going: asking it to stop first...'
    [void](Stop-DesignerRun -State $State)
    $deadline = $run.StopRequestedAt.AddSeconds($run.GraceSec)
    while ((Test-DesignerRunActive -State $State) -and (Get-Date) -lt $deadline) {
        Update-DesignerRun -State $State
        if (Test-DesignerRunActive -State $State) { [System.Threading.Thread]::Sleep(200) }
    }
    if (Test-DesignerRunActive -State $State) {
        [void](Stop-DesignerRun -State $State -Force -Immediately)
        Write-Host 'The run did not stop in time and was ended; its report may be missing.' -ForegroundColor Yellow
    }
    else { Write-Host 'The run stopped.' }
}

function Invoke-DesignerRunTick {
    # The run's tick handler (registered in Start-VouchDesigner).
    param([Parameter(Mandatory)][object]$State)
    Update-DesignerRun -State $State
}

#endregion

#region Previews ------------------------------------------------------------------------

function Register-DesignerPreview {
    <#
        Makes a page test's images available to the panel as /preview/<id>/<file>: only
        the image files THIS run reported in its capture events, found in the images
        folder of its report inside its own preview folder. Nothing else in the folder -
        and no other folder - can ever be asked for (the route looks names up in this list;
        no path from a request reaches the disk).
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Run)
    if (-not $Run.PreviewId -or -not $Run.PreviewFolder) { return }
    $files = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $folder = [System.IO.Path]::GetFullPath($Run.PreviewFolder).TrimEnd('\')
    $report = ''
    if ($Run.ReportPath) {
        $candidate = [System.IO.Path]::GetFullPath($Run.ReportPath)
        if ([System.IO.Path]::GetDirectoryName($candidate) -eq $folder -and [System.IO.File]::Exists($candidate)) { $report = $candidate }
    }
    if ($report) {
        $images = Join-Path -Path $folder -ChildPath (Join-Path 'images' ([System.IO.Path]::GetFileNameWithoutExtension($report)))
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        foreach ($entry in $Run.Pages.Values) {
            foreach ($image in $entry.images) {
                $name = [string]$image['fileName']
                if (-not $name -or $name.IndexOfAny($invalid) -ge 0 -or $name -ne [System.IO.Path]::GetFileName($name)) { continue }
                if ([System.IO.Path]::GetExtension($name).ToLowerInvariant() -notin '.jpg', '.jpeg', '.png') { continue }
                $full = [System.IO.Path]::GetFullPath((Join-Path -Path $images -ChildPath $name))
                if ([System.IO.Path]::GetDirectoryName($full) -ne $images -or -not [System.IO.File]::Exists($full)) { continue }
                $files[$name] = $full
            }
        }
    }
    $State.Previews[$Run.PreviewId] = [pscustomobject]@{ PageId = $Run.PageId; Folder = $folder; Files = $files; ReportPath = $report }
    $Run.PreviewAvailable = $files.Count -gt 0 -or [bool]$report
}

function Remove-DesignerPreview {
    # A newer test of the same page replaces the older preview: its folder is deleted and its address stops working.
    param([Parameter(Mandatory)][object]$State, [AllowEmptyString()][string]$PageId)
    foreach ($id in @($State.Previews.Keys)) {
        $entry = $State.Previews[$id]
        if ($entry.PageId -cne $PageId) { continue }
        [void]$State.Previews.Remove($id)
        try { if ([System.IO.Directory]::Exists($entry.Folder)) { [System.IO.Directory]::Delete($entry.Folder, $true) } }
        catch { Write-Verbose "The old preview could not be removed: $($_.Exception.Message)" }
    }
}

function Invoke-DesignerPreview {
    <#
        GET /preview/<id>/<file>: one image of a page test's preview, behind the usual gate
        (the token header: the panel fetches it and shows it as a data: image, so the
        Content-Security-Policy stays as it is). Only names registered for that preview
        (Register-DesignerPreview); no listing, no other file, nothing after the preview was
        replaced or the Designer stopped. Images only, with their own content type
        (and nosniff, as every answer).
    #>
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$State)
    if ($Method -ne 'GET') { return New-DesignerError -Status 405 -Code 'method' -Message 'This kind of request is not supported.' }
    $notFound = New-DesignerError -Status 404 -Code 'not-found' -Message 'There is no such preview image.' -Detail 'Test the page again to see its images.'
    $rest = $Path.Substring('/preview/'.Length)
    $parts = $rest.Split('/')
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return $notFound }
    $name = ''
    try { $name = [Uri]::UnescapeDataString($parts[1]) } catch { return $notFound }
    if (-not $State.Previews.ContainsKey($parts[0])) { return $notFound }
    $entry = $State.Previews[$parts[0]]
    if (-not $entry.Files.ContainsKey($name)) { return $notFound }
    $file = $entry.Files[$name]
    if (-not [System.IO.File]::Exists($file)) { return $notFound }
    $type = switch ([System.IO.Path]::GetExtension($file).ToLowerInvariant()) { '.png' { 'image/png' } default { 'image/jpeg' } }
    return New-DesignerResponse -ContentType $type -Body ([System.IO.File]::ReadAllBytes($file))
}

#endregion

#region Run routes ----------------------------------------------------------------------

function Get-DesignerRunBodyKind {
    # 'full' or 'page' from a request ("all" is the panel's older word for full).
    param([AllowNull()][object]$Body)
    $kind = Get-DesignerBodyText -Body $Body -Name 'kind'
    if ($kind -cin 'full', 'all') { return 'full' }
    if ($kind -ceq 'page') { return 'page' }
    return ''
}

function Get-DesignerRunBodyPage {
    # The page id of a page test: "pageId", or the first of "only".
    param([AllowNull()][object]$Body)
    $id = Get-DesignerBodyText -Body $Body -Name 'pageId'
    if ($id) { return $id }
    $only = Get-DesignerValue -Object $Body -Name 'only'
    if ($only -is [System.Collections.IEnumerable] -and $only -isnot [string]) { foreach ($item in $only) { if ($item -is [string]) { return $item } } }
    return ''
}

function ConvertTo-DesignerPlanData {
    # The plan as the Run tab shows it before a run.
    param([Parameter(Mandatory)][object]$Plan)
    return [ordered]@{
        kind           = $Plan.Kind
        pageId         = $Plan.PageId
        pageName       = $Plan.PageName
        saved          = [bool]$Plan.ConfigPath
        unsaved        = [bool]$Plan.Unsaved
        baseFolder     = $Plan.BaseFolder
        outputFolder   = $Plan.OutputFolder
        virtualDesktop = $Plan.VirtualDesktop
        errors         = (ConvertTo-DesignerProblem -Problems $Plan.Errors)
        notes          = $Plan.Notes.ToArray()
        problem        = $Plan.Problem
    }
}

function Invoke-DesignerRunPlan {
    <#
        POST /api/run/plan {config, path?, kind?, pageId?}: what a run would do now - the
        resolved output folder, whether unsaved edits would run, the virtual-desktop
        outcome, and the switches the Designer adds - so the Run tab can say so before
        anything starts.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $config = $Body['config']
    if ($config -isnot [System.Collections.IDictionary]) {
        return New-DesignerError -Status 400 -Code 'no-config' -Message 'There was no configuration.' -Detail 'The request did not hold a configuration object.'
    }
    $kind = Get-DesignerRunBodyKind -Body $Body
    if (-not $kind) { $kind = 'full' }
    $plan = Get-DesignerRunPlan -State $State -Config $config -ConfigPath (Resolve-DesignerPath -Path (Get-DesignerBodyText -Body $Body -Name 'path')) -Kind $kind -PageId (Get-DesignerRunBodyPage -Body $Body)
    $data = ConvertTo-DesignerPlanData -Plan $plan
    $data['sessionFlags'] = @(Get-DesignerRunFlagText -State $State -Plan $plan)
    return New-DesignerJsonResponse -Data $data
}

function Get-DesignerRunFlagText {
    # The session-only switches as the Run tab lists them (the values of the run itself are only known when it starts).
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Plan)
    $tab = if ($State.Browser.Connected) { [string]$State.Browser.TabId } else { '' }
    $flags = Get-DesignerRunSessionFlag -State $State -Plan $Plan -EventPath '<temporary event file>' -PreviewFolder '<temporary preview folder>' -TabId $tab
    return @($flags | ForEach-Object { $_.Note })
}

function Invoke-DesignerRunStart {
    <#
        POST /api/run {config, path?, kind: "full"|"page", pageId?}: runs what the panel
        shows - unsaved edits included - without touching the saved file. Problems in the
        configuration block it with the messages Save shows (422 "invalid"). One run at a
        time (409), and only with the audit Edge connected (409 with the reason).
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    if (Test-DesignerRunActive -State $State) {
        return New-DesignerError -Status 409 -Code 'running' -Message 'A run is already going.' -Detail 'Wait until it ends, or stop it, before you start another.'
    }
    $config = $Body['config']
    if ($config -isnot [System.Collections.IDictionary]) {
        return New-DesignerError -Status 400 -Code 'no-config' -Message 'There was no configuration to run.' -Detail 'The request did not hold a configuration object.'
    }
    $kind = Get-DesignerRunBodyKind -Body $Body
    if (-not $kind) {
        return New-DesignerError -Status 400 -Code 'kind' -Message 'This kind of run does not exist.' -Detail 'kind must be full or page.'
    }
    $refusal = Get-DesignerBrowserRefusal -State $State
    if ($null -ne $refusal) { return $refusal }
    $plan = Get-DesignerRunPlan -State $State -Config $config -ConfigPath (Resolve-DesignerPath -Path (Get-DesignerBodyText -Body $Body -Name 'path')) -Kind $kind -PageId (Get-DesignerRunBodyPage -Body $Body)
    if ($plan.Errors.Count -gt 0) {
        $what = if ($kind -eq 'page') { 'tested' } else { 'run' }
        return New-DesignerError -Status 422 -Code 'invalid' -Message "The configuration has $($plan.Errors.Count) problem(s), so it was not $what." -Detail 'Fix the problems listed, then try again.' -Extra ([ordered]@{
                errors = (ConvertTo-DesignerProblem -Problems $plan.Errors); warnings = (ConvertTo-DesignerProblem -Problems $plan.Warnings) })
    }
    if ($plan.Problem) { return New-DesignerError -Status 400 -Code 'page' -Message $plan.Problem -Detail 'Select the page in the Pages tab, then press Test this page.' }
    try { [void](Start-DesignerRun -State $State -Plan $plan) }
    catch { return New-DesignerError -Status 500 -Code 'not-started' -Message 'The run could not be started.' -Detail ([string]$_.Exception.Message) }
    return New-DesignerJsonResponse -Data (Get-DesignerRunData -State $State)
}

function Invoke-DesignerRunStop {
    # POST /api/run/stop {force?}: Stop (the stop file), or Force stop once it is offered.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $refusal = Stop-DesignerRun -State $State -Force:($Body['force'] -eq $true)
    if ($null -ne $refusal) { return $refusal }
    return New-DesignerJsonResponse -Data (Get-DesignerRunData -State $State)
}

function Get-DesignerRunSummary {
    # The run in GET /api/state: enough for the panel to know when to ask for the details.
    param([Parameter(Mandatory)][object]$State)
    $run = $State.Run
    return [ordered]@{ state = (Get-DesignerRunDisplayState -Run $run); kind = $run.Kind; pageId = $run.PageId; number = $run.Number }
}

function Get-DesignerRunData {
    <#
        GET /api/run?since=<n>: the run as the Run tab shows it. events are the run's
        events from index n on (at most 500; "next" is where to continue), plus everything
        derived from them: each page's progress, the counts, the exit code in words, and
        which results can be opened. Paths are shown, but /api/open opens them only by kind.
    #>
    param([Parameter(Mandatory)][object]$State, [int]$Since = 0)
    $run = $State.Run
    $since = [Math]::Max(0, [Math]::Min($Since, $run.Events.Count))
    $take = [Math]::Min(500, $run.Events.Count - $since)
    $events = if ($take -gt 0) { $run.Events.GetRange($since, $take).ToArray() } else { @() }
    $end = if ($run.EndedAt -ne [datetime]::MinValue) { $run.EndedAt } else { Get-Date }
    $elapsed = if ($run.StartedAt -ne [datetime]::MinValue) { [Math]::Round(($end - $run.StartedAt).TotalSeconds, 0) } else { 0 }
    $pages = foreach ($entry in $run.Pages.Values) {
        [ordered]@{ pageId = $entry.pageId; name = $entry.name; url = $entry.url; index = $entry.index; total = $entry.total; status = $entry.status; captureCount = $entry.captureCount; details = $entry.details.ToArray() }
    }
    $preview = $null
    if ($run.Kind -eq 'page' -and $run.PreviewId -and $State.Previews.ContainsKey($run.PreviewId)) {
        $entry = $State.Previews[$run.PreviewId]
        $images = foreach ($page in $run.Pages.Values) {
            foreach ($image in $page.images) {
                $name = [string]$image['fileName']
                if (-not $entry.Files.ContainsKey($name)) { continue }
                [ordered]@{ name = $name; url = "/preview/$($run.PreviewId)/$([Uri]::EscapeDataString($name))"; label = $image['label']; segment = $image['segment']; segmentCount = $image['segmentCount'] }
            }
        }
        $preview = [ordered]@{ id = $run.PreviewId; images = @($images); report = [bool]$entry.ReportPath }
    }
    $force = Test-DesignerRunForceAvailable -Run $run
    $forceIn = 0
    if ($run.State -eq 'stopping' -and -not $force -and $run.StopRequestedAt -ne [datetime]::MinValue) {
        $forceIn = [int][Math]::Ceiling($run.GraceSec - ((Get-Date) - $run.StopRequestedAt).TotalSeconds)
    }
    $openable = [ordered]@{}
    foreach ($kind in 'report', 'folder', 'log', 'zip', 'preview-report') { $openable[$kind] = $State.OpenTargets.Contains($kind) }
    return [ordered]@{
        state            = (Get-DesignerRunDisplayState -Run $run)
        number           = $run.Number
        kind             = $run.Kind
        pageId           = $run.PageId
        pageName         = $run.PageName
        since            = $since
        next             = $since + $take
        events           = @($events)
        pages            = @($pages)
        counts           = $run.Counts
        exitCode         = $run.ExitCode
        stopped          = [bool]$run.Stopped
        stopRequested    = $run.StopRequestedAt -ne [datetime]::MinValue
        forceAvailable   = $force
        forceInSec       = $forceIn
        reportPath       = $run.ReportPath
        zipPath          = $run.ZipPath
        logPath          = $run.LogPath
        outputFolder     = $run.OutputFolder
        previewAvailable = [bool]$run.PreviewAvailable
        preview          = $preview
        prompt           = $run.Prompt
        message          = $run.Message
        errorText        = $(if ($run.State -eq 'failed') { Get-DesignerRunErrorText -Run $run } else { '' })
        skippedLines     = $run.Skipped
        elapsedSec       = $elapsed
        unsaved          = [bool]$run.Unsaved
        virtualDesktop   = $run.VirtualDesktop
        notes            = $run.Notes.ToArray()
        sessionFlags     = @($run.Flags | ForEach-Object { $_.Note })
        open             = $openable
        pageResults      = $State.PageResults
    }
}

function Get-DesignerRunRefusal {
    <#
        While a run is going the Designer does not touch the audit Edge: routes that would
        (reconnect, look at the tabs, open a page, pick, test an action, tidy the windows)
        answer 409 with a plain sentence. $null when the route may go ahead.
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][string]$Route)
    if (-not (Test-DesignerRunActive -State $State)) { return $null }
    $browserRoutes = 'GET /api/browser/current', 'POST /api/browser/connect', 'POST /api/browser/navigate', 'POST /api/browser/layout',
        'POST /api/browser/zoom-off', 'POST /api/page/from-current', 'POST /api/pick/start', 'POST /api/action/test'
    if ($Route -cnotin $browserRoutes) { return $null }
    return New-DesignerError -Status 409 -Code 'running' -Message 'A run is using the audit browser.' -Detail 'Wait until the run has ended (or stop it in the Run tab); the Designer connects to the browser again by itself.'
}

#endregion
