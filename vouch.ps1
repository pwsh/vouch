#Requires -Version 7

<#
.SYNOPSIS
    Captures audit-evidence screenshots of web application configuration pages.

.DESCRIPTION
    Drives Microsoft Edge through the Chrome DevTools Protocol (CDP) and takes REAL
    screen captures (GDI CopyFromScreen) of the primary display, so the Windows taskbar
    clock is part of every image. Long pages are captured as a series of viewport
    segments. Everything is assembled into a single self-contained HTML report with
    base64-embedded images. -CaptureArea can narrow the images to the Edge window or to
    the page content only (see below).

.PARAMETER CsvPath
    Path to the capture definition CSV. Header: Name,Url,Steps,ScrollFullPage,Notes
    Defaults to captures.csv in the script's own folder, so the script behaves the same
    when started by Task Scheduler (whose working directory is C:\Windows\System32).

.PARAMETER ConfigPath
    Path to a configuration file (JSON) holding the pages and every setting; see
    captures.sample.json. Use it instead of -CsvPath, not together with it. Relative
    folders in the file are read from the file's own folder. A parameter typed on the
    command line still beats the same setting in the file.

.PARAMETER Only
    Run only these pages, by id (p001) or by name. Works with -ConfigPath and -CsvPath
    (CSV rows get the ids p001, p002, ... in order). Pages switched off in the
    configuration ("enabled": false) still run when named here.

.PARAMETER OutputDir
    Folder for the report. Defaults to the reports folder next to the script.

.PARAMETER FailOnWarning
    Exit with code 3 when no item failed but at least one produced a warning (for
    example an expired session redirecting to a sign-in page). Without it, warnings
    exit with 0.

.PARAMETER Verify
    Check a report instead of capturing: re-hash every embedded screenshot, compare the
    metadata inside each image with the report, recompute the manifest hash, and check
    saved images against SHA256SUMS. Exit code 0 when everything matches, 4 when not.
    Needs no browser. Example: .\vouch.ps1 -Verify .\reports\VouchReport_2026-09-24_060231.html

.PARAMETER UseVirtualDesktop
    Capture on a fresh virtual desktop (Task View) that the run opens and closes again,
    so other open applications are not in the taskbar of the evidence. Pinned taskbar
    icons still show. The report's Desktop line records whether the switch was confirmed.

.PARAMETER CaptureArea
    What each screenshot shows. screen (default): the whole primary display, with the
    taskbar clock. window: the Edge window only (title bar, tabs and address bar; no
    taskbar). page: the page content only, taken by the browser itself - Edge does not
    need to be in front, but the image has no address bar or clock (the capture time
    and URL are in the report and inside each image file). A configuration file sets
    it per run (defaults.captureArea) or per page (overrides).

.PARAMETER ZoomPercent
    Shows the pages zoomed, 25 to 500 (default 100), like Ctrl+plus/minus but without
    changing anything in the Edge profile; the page reflows to the zoomed width. Set per
    run or per page (defaults.zoomPercent / overrides) in a configuration file.

.PARAMETER JsonSummary
    Also write the results as JSON next to the report (same name, .json): run metadata
    and per-item status, URLs, details, steps and capture timestamps - no image data.
    For monitoring and tests; Install-VouchSchedule.ps1 sets it.

.PARAMETER LogDir
    Write a transcript of the run (vouch_<date>_<time>.log) to this folder. Meant for
    unattended runs; Install-VouchSchedule.ps1 sets it.

.PARAMETER LoginSetup
    First-run onboarding: opens Edge with the dedicated audit profile (no debugging
    flags) so you can sign in to your applications. Sessions persist for later runs.

.PARAMETER NoPrompt
    Never ask anything: a "pause" action is skipped and a page that is not ready (or
    asks for a sign-in) is captured with a warning, as in a scheduled run. Without it,
    a run started by a person shows the Vouch dialog for those (Continue / Wait /
    Skip this page); a run started with pwsh -NonInteractive never does.

.PARAMETER EventLogPath
    Write the progress of the run to this file, one JSON object per line (for the
    Vouch Designer and other programs that follow a run). Creating a file with the same
    name plus ".stop" next to it stops the run cleanly: the report is still written for
    what was captured so far.

.PARAMETER TabId
    Use this Edge tab (its DevTools target id, as listed by /json/list) instead of the
    first one. Only for an Edge that is already running; the tab is never closed.

.EXAMPLE
    .\vouch.ps1 -LoginSetup

.EXAMPLE
    .\vouch.ps1 -CsvPath .\captures.csv -OutputDir .\reports

.EXAMPLE
    .\vouch.ps1 -ConfigPath .\captures.json -Only p002

.EXAMPLE
    .\vouch.ps1 -ImageFormat png -SaveImages -KeepBrowserOpen
#>

[CmdletBinding()]
param(
    [string]$CsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'captures.csv'),

    [string]$ConfigPath = '',

    [string[]]$Only = @(),

    [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'reports'),

    [string]$ReportName = '',

    [string]$EdgeProfileDir = (Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Vouch\EdgeProfile'),

    [ValidateRange(1024, 65535)]
    [int]$DebugPort = 9222,

    [ValidateRange(5, 600)]
    [int]$NavigationTimeoutSec = 30,

    [ValidateRange(0, 120)]
    [double]$SettleSeconds = 2,

    [ValidateRange(0, 120)]
    [double]$ScrollSettleSeconds = 1,

    [ValidateRange(1, 500)]
    [int]$MaxScrollSegments = 30,

    [ValidateSet('jpeg', 'png')]
    [string]$ImageFormat = 'jpeg',

    [ValidateRange(1, 100)]
    [int]$JpegQuality = 85,

    [switch]$SaveImages,

    [switch]$KeepBrowserOpen,

    [switch]$FailOnWarning,

    [string]$LogDir = '',

    [switch]$JsonSummary,

    [switch]$UseVirtualDesktop,

    [ValidateSet('screen', 'window', 'page')]
    [string]$CaptureArea = 'screen',

    [ValidateRange(25, 500)]
    [int]$ZoomPercent = 100,

    [string]$Verify = '',

    [switch]$LoginSetup,

    [switch]$NoPrompt,

    [string]$EventLogPath = '',

    [string]$TabId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion       = '1.3.0'
$script:ExitCode          = 0
$script:CdpSocket         = $null
$script:CdpWebSocketUrl   = ''
$script:CdpPort           = 0
$script:CdpMessageId      = 0
$script:CdpDefaultTimeout = 30
$script:EdgeProcess       = $null
$script:BrowserWsUrl      = ''
$script:LaunchedEdge      = $false
$script:ReusedEdge        = $false
# The page zoom in effect on the current DevTools connection (Set-PageZoom); 100 = none.
$script:PageZoomPercent   = 100
# A zoom that a reconnect could not set again (Restore-CdpConnection); 0 = none.
$script:PageZoomLost      = 0
# The tab -TabId asked for (Get-CdpPageTarget); '' = the first web tab.
$script:CdpTabId          = ''
# Whether a person can answer the Vouch dialog (Test-InteractiveRun, set per run).
$script:InteractiveRun    = $false
# -EventLogPath of the current run ('' = no events, no stop file) and its run id.
$script:EventLogPath      = ''
$script:EventRunId        = ''
# The page whose events are being written (its id, e.g. p001).
$script:EventPageId       = ''
# Set once the stop file has been seen (Test-StopRequested); stays set for the run.
$script:StopRequested     = $false

# DevTools binds to the IPv4 loopback only; "localhost" can resolve to ::1 and fail.
$script:CdpHost = '127.0.0.1'

#region Environment -----------------------------------------------------------

function Assert-Environment {
    if (-not $IsWindows) {
        throw 'vouch.ps1 runs on Windows only (it uses GDI screen capture and Win32 window APIs).'
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7 or later is required. Detected $($PSVersionTable.PSVersion)."
    }
}

function Initialize-NativeInterop {
    if (-not ('Vouch.Native' -as [type])) {
        $code = @'
using System;
using System.Runtime.InteropServices;

namespace Vouch
{
    public static class Native
    {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    }

    // The documented part of the virtual desktop API: it can tell which desktop a window
    // is on, but it cannot create or switch desktops (that is done with the shell's own
    // keyboard shortcuts).
    [ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, [MarshalAs(UnmanagedType.Bool)] out bool onCurrentDesktop);
        [PreserveSig] int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
        [PreserveSig] int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    [ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
    public class VirtualDesktopManagerClass { }

    // CRC-32 as used by PNG chunks (ISO 3309 polynomial).
    public static class Crc32
    {
        private static readonly uint[] Table = Build();

        private static uint[] Build()
        {
            var table = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++) { c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; }
                table[n] = c;
            }
            return table;
        }

        public static uint Compute(byte[] data)
        {
            uint c = 0xFFFFFFFFu;
            foreach (byte b in data) { c = Table[(c ^ b) & 0xFF] ^ (c >> 8); }
            return c ^ 0xFFFFFFFFu;
        }
    }

    public static class VirtualDesktop
    {
        // 1 = on the current desktop, 0 = on another desktop, -1 = unknown.
        public static int IsOnCurrent(IntPtr window)
        {
            try
            {
                var manager = (IVirtualDesktopManager)new VirtualDesktopManagerClass();
                bool onCurrent;
                if (manager.IsWindowOnCurrentVirtualDesktop(window, out onCurrent) != 0) { return -1; }
                return onCurrent ? 1 : 0;
            }
            catch
            {
                return -1;
            }
        }
    }
}
'@
        Add-Type -TypeDefinition $code -Language CSharp
    }

    # Window geometry is a type of its own, with its own check: a PowerShell session
    # keeps a compiled type until it ends, so one that already loaded Vouch.Native from
    # an older vouch.ps1 would never see members added to it. A new type name loads
    # beside the old one.
    if (-not ('Vouch.WindowGeometry' -as [type])) {
        $geometryCode = @'
using System;
using System.Runtime.InteropServices;

namespace Vouch
{
    [StructLayout(LayoutKind.Sequential)]
    public struct WindowRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class WindowGeometry
    {
        // DWMWA_EXTENDED_FRAME_BOUNDS: the window as drawn on screen, without the
        // invisible resize borders that GetWindowRect includes.
        public const int ExtendedFrameBounds = 9;

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out WindowRect pvAttribute, int cbAttribute);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out WindowRect lpRect);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsZoomed(IntPtr hWnd);
    }
}
'@
        Add-Type -TypeDefinition $geometryCode -Language CSharp
    }

    # Without this, CopyFromScreen returns a scaled/cropped image on displays with
    # any scaling other than 100%. It must be called before any screen geometry is read.
    [void][Vouch.Native]::SetProcessDPIAware()
}

function Get-OperatingSystemDescription {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return "$($os.Caption) (build $($os.BuildNumber))"
    }
    catch {
        return [System.Environment]::OSVersion.VersionString
    }
}

function Find-EdgeExecutable {
    $appPathsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    try {
        if (Test-Path -LiteralPath $appPathsKey) {
            $item = Get-ItemProperty -LiteralPath $appPathsKey -ErrorAction Stop
            $defaultValue = $item.PSObject.Properties['(default)']
            if ($null -ne $defaultValue) {
                $candidate = [string]$defaultValue.Value
                if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        }
    }
    catch {
        Write-Verbose "Could not read Edge path from the registry: $($_.Exception.Message)"
    }

    $fallbacks = @(
        (Join-Path -Path "$env:ProgramFiles" -ChildPath 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path -Path "${env:ProgramFiles(x86)}" -ChildPath 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($path in $fallbacks) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw 'Microsoft Edge (msedge.exe) was not found. Install Edge, or make sure it is registered under HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe.'
}

function Find-EdgeBrowserProcess {
    <#
        The msedge.exe that Start-Process returns is a launcher that exits almost at once;
        the browser that owns the windows and the DevTools port is a new process. Find it
        by its command line instead: the main browser process is the one without --type=.
        Other users' command lines are not readable, so their Edge is never matched.
    #>
    param(
        [string]$ProfileDir = '',
        [int]$Port = 0
    )

    $candidates = @()
    try {
        $candidates = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop)
    }
    catch {
        Write-Verbose "Could not enumerate Edge processes: $($_.Exception.Message)"
        return $null
    }

    $profileText = $ProfileDir.TrimEnd('\')
    foreach ($candidate in $candidates) {
        $commandLine = [string]$candidate.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine -match '\s--type=') { continue }
        if ($Port -gt 0 -and $commandLine -notmatch "--remote-debugging-port=$Port(?!\d)") { continue }
        if ($profileText -ne '' -and
            -not $commandLine.Contains($profileText, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            return Get-Process -Id $candidate.ProcessId -ErrorAction Stop
        }
        catch {
            Write-Verbose "Edge process $($candidate.ProcessId) exited while being inspected."
        }
    }
    return $null
}

#endregion

#region CSV -------------------------------------------------------------------

function Get-CsvField {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][string]$Field
    )
    $property = $Row.PSObject.Properties[$Field]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return ([string]$property.Value).Trim()
}

function ConvertTo-BooleanFlag {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return @('y', 'yes', 'true', '1') -contains $Value.Trim().ToLowerInvariant()
}

function Test-BooleanFlagText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return @('y', 'yes', 'true', '1', 'n', 'no', 'false', '0') -contains $Value.Trim().ToLowerInvariant()
}

function ConvertTo-StepList {
    <#
        Parses the semicolon-separated Steps cell. Returns a list of step objects and
        appends any problems to the supplied error list. Only the FIRST colon splits the
        verb from its argument, so CSS selectors such as "a:nth-child(2)" survive intact.
    #>
    param(
        [string]$StepsText,
        [Parameter(Mandatory)][int]$LineNumber,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    # The leading comma stops PowerShell from unrolling the list on return.
    if ([string]::IsNullOrWhiteSpace($StepsText)) { return , $steps }

    foreach ($rawStep in $StepsText.Split(';')) {
        $step = $rawStep.Trim()
        if ([string]::IsNullOrWhiteSpace($step)) { continue }

        $separator = $step.IndexOf(':')
        if ($separator -lt 1) {
            $Errors.Add("Line ${LineNumber}: step '$step' is not valid. Expected click:<css>, clicktext:<text> or wait:<seconds>.")
            continue
        }

        $verb = $step.Substring(0, $separator).Trim().ToLowerInvariant()
        $argument = $step.Substring($separator + 1).Trim()

        switch ($verb) {
            'click' {
                if ([string]::IsNullOrWhiteSpace($argument)) {
                    $Errors.Add("Line ${LineNumber}: 'click:' requires a CSS selector.")
                }
                else {
                    $steps.Add([pscustomobject]@{ Verb = 'click'; Argument = $argument; Text = $step })
                }
            }
            'clicktext' {
                if ([string]::IsNullOrWhiteSpace($argument)) {
                    $Errors.Add("Line ${LineNumber}: 'clicktext:' requires the visible text to match.")
                }
                else {
                    $steps.Add([pscustomobject]@{ Verb = 'clicktext'; Argument = $argument; Text = $step })
                }
            }
            'wait' {
                # Parse culture-independently: on a de-DE machine TryParse would read
                # '2.5' as 25. A comma is accepted as the decimal separator as well.
                $seconds = 0.0
                $parsed = [double]::TryParse($argument.Replace(',', '.'), [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
                if (-not $parsed -or [double]::IsNaN($seconds) -or $seconds -lt 0 -or $seconds -gt 300) {
                    $Errors.Add("Line ${LineNumber}: 'wait:$argument' is not a number of seconds between 0 and 300.")
                }
                else {
                    $steps.Add([pscustomobject]@{ Verb = 'wait'; Argument = $seconds; Text = $step })
                }
            }
            default {
                $Errors.Add("Line ${LineNumber}: unknown step verb '$verb'. Supported verbs: click, clicktext, wait.")
            }
        }
    }

    return , $steps
}

function Import-CaptureDefinition {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Capture definition CSV not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw "The CSV '$Path' contains a header but no capture rows."
    }

    $headers = @($rows[0].PSObject.Properties.Name)
    foreach ($required in @('Name', 'Url')) {
        if ($headers -notcontains $required) {
            throw "The CSV '$Path' is missing the required '$required' column. Expected header: Name,Url,Steps,ScrollFullPage,Notes"
        }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $definitions = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 1   # the header line

    foreach ($row in $rows) {
        $lineNumber++

        $name = Get-CsvField -Row $row -Field 'Name'
        $url = Get-CsvField -Row $row -Field 'Url'
        $stepsText = Get-CsvField -Row $row -Field 'Steps'
        $scrollText = Get-CsvField -Row $row -Field 'ScrollFullPage'
        $notes = Get-CsvField -Row $row -Field 'Notes'

        # Excel leaves rows of bare commas behind when rows are cleared; skip them.
        if (-not ($name + $url + $stepsText + $scrollText + $notes)) { continue }
        $index = $definitions.Count + 1

        if ([string]::IsNullOrWhiteSpace($name)) {
            $errors.Add("Line ${lineNumber}: 'Name' is required.")
        }
        if ([string]::IsNullOrWhiteSpace($url)) {
            $errors.Add("Line ${lineNumber}: 'Url' is required.")
        }
        elseif ($url -notmatch '^(?i)https?://\S') {
            $errors.Add("Line ${lineNumber}: 'Url' must start with http:// or https:// (found '$url').")
        }
        if (-not (Test-BooleanFlagText -Value $scrollText)) {
            $errors.Add("Line ${lineNumber}: 'ScrollFullPage' must be blank, Y/N, Yes/No, True/False or 1/0 (found '$scrollText').")
        }

        $steps = ConvertTo-StepList -StepsText $stepsText -LineNumber $lineNumber -Errors $errors
        $scrollFullPage = ConvertTo-BooleanFlag -Value $scrollText

        # Id, Enabled, Overrides and Actions make a CSV row the same shape as a page of
        # a configuration file (ConvertTo-CaptureDefinition), so -Only and the
        # Designer's CSV import treat both alike.
        $definitions.Add([pscustomobject]@{
            Index          = $index
            LineNumber     = $lineNumber
            Name           = $name
            Url            = $url
            StepsText      = $stepsText
            Steps          = $steps
            ScrollFullPage = $scrollFullPage
            Notes          = $notes
            Id             = 'p{0:d3}' -f $index
            Enabled        = $true
            Overrides      = [ordered]@{}
            Actions        = (ConvertTo-ActionList -Steps @($steps) -ScrollFullPage $scrollFullPage)
        })
    }

    if ($definitions.Count -eq 0 -and $errors.Count -eq 0) {
        throw "The CSV '$Path' contains no capture rows (only blank lines)."
    }

    if ($errors.Count -gt 0) {
        Write-Host ''
        Write-Host "The capture definition CSV has $($errors.Count) problem(s):" -ForegroundColor Red
        foreach ($message in $errors) { Write-Host "  - $message" -ForegroundColor Red }
        Write-Host ''
        throw "Fix '$Path' and run again. Nothing was launched."
    }

    return , $definitions
}

#endregion

#region Configuration file ---------------------------------------------------

function Get-VouchConfigSchema {
    <#
        The configuration file format (schemaVersion 1) in one place: every key, its
        type, allowed values and default. Validation (Test-VouchConfig), the default
        configuration and filling in missing keys all read this, so they cannot drift.
        Ranges of settings that are also script parameters match the parameters'
        ValidateRange attributes; the command line and the file accept the same values.
    #>
    $text = @{ Type = 'string'; Default = '' }
    $defaultsKeys = [ordered]@{
        account              = $text
        captureArea          = @{ Type = 'enum'; Allowed = @('screen', 'window', 'page'); Default = 'screen' }
        zoomPercent          = @{ Type = 'int'; Min = 25; Max = 500; Default = 100 }
        navigationTimeoutSec = @{ Type = 'int'; Min = 5; Max = 600; Default = 30 }
        settleSeconds        = @{ Type = 'number'; Min = 0; Max = 120; Default = 2 }
        scrollSettleSeconds  = @{ Type = 'number'; Min = 0; Max = 120; Default = 1 }
        maxScrollSegments    = @{ Type = 'int'; Min = 1; Max = 500; Default = 30 }
        waitFor              = $text
        onNotReady           = @{ Type = 'enum'; Allowed = @('warn', 'prompt'); Default = 'warn' }
        promptTimeoutSec     = @{ Type = 'int'; Min = 1; Max = 3600; Default = 300 }
    }
    return [ordered]@{
        schemaVersion = @{ Type = 'schemaVersion'; Default = 1 }
        name          = $text
        browser       = @{ Type = 'object'; Fields = [ordered]@{
                profileDir        = $text
                debugPort         = @{ Type = 'int'; Min = 1024; Max = 65535; Default = 9222 }
                useVirtualDesktop = @{ Type = 'bool'; Default = $false }
                keepBrowserOpen   = @{ Type = 'bool'; Default = $false }
            }
        }
        defaults      = @{ Type = 'object'; Fields = $defaultsKeys }
        output        = @{ Type = 'object'; Fields = [ordered]@{
                dir           = @{ Type = 'string'; Default = 'reports' }
                reportName    = $text
                imageFormat   = @{ Type = 'enum'; Allowed = @('jpeg', 'png'); Default = 'jpeg' }
                jpegQuality   = @{ Type = 'int'; Min = 1; Max = 100; Default = 85 }
                saveImages    = @{ Type = 'bool'; Default = $false }
                embedImages   = @{ Type = 'bool'; Default = $true }
                jsonSummary   = @{ Type = 'bool'; Default = $false }
                logDir        = $text
                failOnWarning = @{ Type = 'bool'; Default = $false }
                openReport    = @{ Type = 'bool'; Default = $false }
                zip           = @{ Type = 'object'; Fields = [ordered]@{
                        enabled = @{ Type = 'bool'; Default = $false }
                        name    = @{ Type = 'string'; Default = '{report}.zip' }
                    }
                }
            }
        }
        report        = @{ Type = 'object'; Fields = [ordered]@{
                title          = @{ Type = 'string'; Default = 'Audit Evidence Report' }
                logoPath       = $text
                showIndex      = @{ Type = 'bool'; Default = $true }
                company        = @{ Type = 'object'; Fields = [ordered]@{ name = $text; details = $text } }
                description    = $text
                origin         = $text
                generatedBy    = $text
                period         = @{ Type = 'object'; Fields = [ordered]@{ from = $text; to = $text; label = $text } }
                classification = @{ Type = 'enum'; Allowed = @('', 'Public', 'Internal', 'Private', 'Confidential'); Default = '' }
            }
        }
        pages         = @{ Type = 'pages' }
    }
}

function Get-VouchActionSchema {
    <#
        The keys each kind of page action takes. Kept beside Get-VouchConfigSchema;
        'type' is common to all and checked separately.
    #>
    return [ordered]@{
        click     = [ordered]@{ selector = @{ Type = 'string'; Required = 'the CSS selector of what to click' } }
        clickText = [ordered]@{ text = @{ Type = 'string'; Required = 'the visible text to click' } }
        wait      = [ordered]@{ seconds = @{ Type = 'number'; Min = 0; Max = 300; Required = 'the number of seconds to wait' } }
        waitFor   = [ordered]@{
            selector   = @{ Type = 'string'; Required = 'the CSS selector of the element to wait for' }
            timeoutSec = @{ Type = 'int'; Min = 1; Max = 600 }
        }
        pause     = [ordered]@{ message = @{ Type = 'string' } }
        capture   = [ordered]@{
            label  = @{ Type = 'string' }
            scroll = @{ Type = 'object'; Fields = [ordered]@{
                    mode     = @{ Type = 'enum'; Allowed = @('none', 'auto', 'page', 'area'); Default = 'none' }
                    selector = @{ Type = 'string'; Default = '' }
                    as       = @{ Type = 'enum'; Allowed = @('segments', 'single'); Default = 'segments' }
                }
            }
        }
    }
}

function New-VouchConfigNode {
    <#
        The default values of one schema object, built fresh on every call: the defaults
        are handed out as live dictionaries that callers fill in and change, so two
        configurations (or two pages) must never share one.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Keys)
    $node = [ordered]@{}
    foreach ($key in $Keys.Keys) {
        $spec = $Keys[$key]
        $node[$key] = switch ($spec.Type) {
            'object' { New-VouchConfigNode -Keys $spec.Fields }
            'pages'  { , [System.Collections.Generic.List[object]]::new() }
            default  { $spec.Default }
        }
    }
    return $node
}

function Get-DefaultVouchConfig {
    <#
        A complete configuration holding only defaults and no pages: what the Designer's
        New starts from, and what Complete-VouchConfig fills missing keys from.
        Objects are ordered, case-insensitive dictionaries (the same shape
        ConvertFrom-VouchJson produces), so either can be saved with ConvertTo-Json.
    #>
    return New-VouchConfigNode -Keys (Get-VouchConfigSchema)
}

function ConvertFrom-VouchJsonElement {
    <#
        Walks a System.Text.Json element into plain PowerShell values: objects become
        ordered case-insensitive dictionaries, arrays List[object], numbers Int64 or
        Double. ConvertFrom-Json is not used because it turns date-like text such as
        "2026-07-01" into DateTime and stops on keys that differ only in case with a
        message no user can act on.
    #>
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $node = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                $childPath = if ($Path) { "$Path.$($property.Name)" } else { $property.Name }
                if ($node.Contains($property.Name)) {
                    throw "'$childPath' is written twice. Keep one of them (capital letters do not make a key different)."
                }
                $node[$property.Name] = ConvertFrom-VouchJsonElement -Element $property.Value -Path $childPath
            }
            return $node
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            $position = 0
            foreach ($child in $Element.EnumerateArray()) {
                $list.Add((ConvertFrom-VouchJsonElement -Element $child -Path "$Path[$position]"))
                $position++
            }
            return , $list
        }
        'String' { return $Element.GetString() }
        'Number' {
            $whole = [long]0
            if ($Element.TryGetInt64([ref]$whole)) { return $whole }
            return $Element.GetDouble()
        }
        'True'  { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function ConvertFrom-VouchJson {
    <#
        Parses configuration text. Comments and trailing commas are allowed because
        people edit the file by hand in Notepad. A syntax error is reported with the
        line and column a person can find, not the parser's byte offsets.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'The file is empty.' }
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
    $options.AllowTrailingCommas = $true
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Text, $options)
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        if ($exception.PSObject.Properties['LineNumber'] -and $null -ne $exception.LineNumber) {
            $column = if ($null -ne $exception.BytePositionInLine) { $exception.BytePositionInLine + 1 } else { 1 }
            throw "The file is not valid JSON: there is a mistake on line $($exception.LineNumber + 1) near column $column (a missing comma, quote or bracket is the usual cause)."
        }
        throw "The file is not valid JSON: $($exception.Message)"
    }
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'The file must hold one JSON object: it starts with { and ends with }.'
        }
        return ConvertFrom-VouchJsonElement -Element $document.RootElement -Path ''
    }
    finally {
        $document.Dispose()
    }
}

function Format-VouchConfigValue {
    <#
        Shows a value in a validation message the way it looks in the file ("2" in
        quotes, true, a list [ ]), not as PowerShell prints it (System.Collections...,
        True): the reader is looking at the JSON and must recognise what is meant.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return '"' + $Value + '"' }
    if ($Value -is [System.Collections.IDictionary]) { return 'an object { }' }
    if ($Value -is [System.Collections.IList]) { return 'a list [ ]' }
    if ($Value -is [double]) { return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function Test-VouchConfigNumber {
    <#
        Numbers only: PowerShell would happily cast true or "30" in quotes to a number,
        so a range check with -lt / -gt alone accepts values the file format does not.
        NaN and infinity are refused as well, because every comparison with them is false.
    #>
    param([AllowNull()][object]$Value, [switch]$Whole)
    $isNumber = $Value -is [long] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal]
    if (-not $isNumber) { return $false }
    if ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) { return $false }
    if ($Whole) { return [Math]::Floor([double]$Value) -eq [double]$Value }
    return $true
}

function Add-VouchConfigProblem {
    <#
        One place that builds a problem record { Path; Message }, so errors and warnings
        have the same shape everywhere: the console listing and the Designer both show
        the path next to the message and must not have to guess the format.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    $List.Add([pscustomobject]@{ Path = $Path; Message = $Message })
}

function Test-VouchConfigScalar {
    <#
        Checks one plain value against its schema entry. null means "use the default"
        and is accepted. The messages say what to write, because the reader is the
        person editing the file, not a developer.
    #>
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Errors
    )
    if ($null -eq $Value) { return }
    $found = Format-VouchConfigValue -Value $Value
    switch ($Spec.Type) {
        'string' {
            if ($Value -isnot [string]) {
                Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be text in double quotes (found $found)."
            }
        }
        'bool' {
            if ($Value -isnot [bool]) {
                Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be true or false, without quotes (found $found)."
            }
        }
        'int' {
            if (-not (Test-VouchConfigNumber -Value $Value -Whole) -or $Value -lt $Spec.Min -or $Value -gt $Spec.Max) {
                Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be a whole number from $($Spec.Min) to $($Spec.Max), without quotes (found $found)."
            }
        }
        'number' {
            if (-not (Test-VouchConfigNumber -Value $Value) -or $Value -lt $Spec.Min -or $Value -gt $Spec.Max) {
                Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be a number from $($Spec.Min) to $($Spec.Max), without quotes; use a dot for decimals (found $found)."
            }
        }
        'enum' {
            if ($Value -isnot [string] -or @($spec.Allowed) -notcontains $Value) {
                $allowed = (@($spec.Allowed) | ForEach-Object { '"' + $_ + '"' }) -join ', '
                Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be one of $allowed (found $found)."
            }
        }
    }
}

function Test-VouchConfigObject {
    <#
        Checks an object against a schema object: unknown keys are warnings (a typo must
        not stop a scheduled run, but the user should hear about it), known keys are
        checked by type, nested objects recursively.
    #>
    param(
        [AllowNull()][object]$Node,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Keys,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Warnings
    )
    if ($null -eq $Node) { return }
    if ($Node -isnot [System.Collections.IDictionary]) {
        Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be an object in { } (found $(Format-VouchConfigValue -Value $Node))."
        return
    }
    foreach ($key in @($Node.Keys)) {
        $childPath = if ($Path) { "$Path.$key" } else { [string]$key }
        if (-not $Keys.Contains($key)) {
            Add-VouchConfigProblem -List $Warnings -Path $childPath -Message 'is not a setting Vouch knows, so it is ignored. Check the spelling.'
            continue
        }
        $spec = $Keys[$key]
        $value = $Node[$key]
        switch ($spec.Type) {
            'object' {
                Test-VouchConfigObject -Node $value -Keys $spec.Fields -Path $childPath -Errors $Errors -Warnings $Warnings
            }
            'pages' {
                Test-VouchConfigPageList -Pages $value -Errors $Errors -Warnings $Warnings
            }
            'schemaVersion' {
                if (-not (Test-VouchConfigNumber -Value $value -Whole) -or $value -lt 1) {
                    Add-VouchConfigProblem -List $Errors -Path $childPath -Message "must be 1 (found $(Format-VouchConfigValue -Value $value))."
                }
                elseif ($value -gt 1) {
                    Add-VouchConfigProblem -List $Errors -Path $childPath -Message "is $($value): this file was made by a newer version of Vouch, which this copy cannot read correctly. Use the newer vouch.ps1."
                }
            }
            default {
                Test-VouchConfigScalar -Value $value -Spec $spec -Path $childPath -Errors $Errors
            }
        }
    }
}

function Get-VouchPageId {
    <#
        The id -Only and the Designer use for a page. A hand-written page may leave it
        out; it then gets p001, p002, ... by position, the same ids CSV rows get.
    #>
    param(
        [Parameter(Mandatory)][object]$Page,
        [Parameter(Mandatory)][int]$Position
    )
    if ($Page -is [System.Collections.IDictionary] -and $Page.Contains('id') -and
        $Page['id'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Page['id'])) {
        return $Page['id'].Trim()
    }
    return 'p{0:d3}' -f $Position
}

function Get-VouchActionType {
    <#
        The action type in the spelling the schema uses, or '' when it is not one. People
        write "clicktext" or "ClickText" by hand; -eq ignores case, and every later
        comparison can then use the one canonical spelling.
    #>
    param([AllowNull()][object]$Type)
    if ($Type -isnot [string]) { return '' }
    foreach ($known in (Get-VouchActionSchema).Keys) {
        if ($known -eq $Type.Trim()) { return $known }
    }
    return ''
}

function Test-VouchPageAction {
    <#
        Checks one page action. The type decides which keys are allowed, so the type is
        checked first and the rest only when it is known: an unknown type would otherwise
        produce a warning for every key it has, burying the one real mistake. Required
        values and the "area needs a selector" rule are checked here because the schema
        alone cannot express them.
    #>
    param(
        [AllowNull()][object]$Action,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Warnings
    )
    if ($Action -isnot [System.Collections.IDictionary]) {
        Add-VouchConfigProblem -List $Errors -Path $Path -Message "must be an object in { } with a ""type"" (found $(Format-VouchConfigValue -Value $Action))."
        return
    }
    $actionSchema = Get-VouchActionSchema
    $type = Get-VouchActionType -Type $Action['type']
    if (-not $type) {
        $allowed = (@($actionSchema.Keys) | ForEach-Object { '"' + $_ + '"' }) -join ', '
        $found = if ($Action.Contains('type')) { Format-VouchConfigValue -Value $Action['type'] } else { 'nothing' }
        Add-VouchConfigProblem -List $Errors -Path "$Path.type" -Message "must be one of $allowed (found $found)."
        return
    }
    $keys = $actionSchema[$type]
    $rest = [ordered]@{}
    foreach ($key in @($Action.Keys)) { if ($key -ne 'type') { $rest[$key] = $Action[$key] } }
    Test-VouchConfigObject -Node $rest -Keys $keys -Path $Path -Errors $Errors -Warnings $Warnings

    foreach ($key in $keys.Keys) {
        $spec = $keys[$key]
        if (-not $spec.Contains('Required')) { continue }
        $value = $Action[$key]
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            Add-VouchConfigProblem -List $Errors -Path "$Path.$key" -Message "is missing: a ""$type"" action needs $($spec.Required)."
        }
    }

    if ($type -eq 'capture' -and $Action['scroll'] -is [System.Collections.IDictionary]) {
        $scroll = $Action['scroll']
        if ($scroll['mode'] -is [string] -and $scroll['mode'] -eq 'area' -and
            -not ($scroll['selector'] -is [string] -and -not [string]::IsNullOrWhiteSpace($scroll['selector']))) {
            Add-VouchConfigProblem -List $Errors -Path "$Path.scroll.selector" -Message 'is missing: scroll mode "area" needs the CSS selector of the area to scroll.'
        }
    }
}

function Test-VouchConfigPageList {
    <#
        Checks the page list. Pages need rules the generic object check cannot express:
        name and url are required, the url must be http(s), ids must be unique (compared
        without regard to capitals, including the p001... ids given to pages without one,
        because -Only matches that way), and actions is a list of objects of several kinds.
    #>
    param(
        [AllowNull()][object]$Pages,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Warnings
    )
    if ($null -eq $Pages) { return }
    if ($Pages -isnot [System.Collections.IList]) {
        Add-VouchConfigProblem -List $Errors -Path 'pages' -Message "must be a list in [ ] (found $(Format-VouchConfigValue -Value $Pages))."
        return
    }
    $schema = Get-VouchConfigSchema
    $text = @{ Type = 'string' }
    $pageKeys = [ordered]@{
        id = $text; name = $text; url = $text; notes = $text
        enabled = @{ Type = 'bool' }
        overrides = $schema['defaults']
        actions = @{ Type = 'actions' }
    }
    $seenIds = @{}
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $page = $Pages[$i]
        $path = "pages[$i]"
        if ($page -isnot [System.Collections.IDictionary]) {
            Add-VouchConfigProblem -List $Errors -Path $path -Message "must be an object in { } (found $(Format-VouchConfigValue -Value $page))."
            continue
        }

        # actions is a list of objects of several kinds, checked below.
        $rest = [ordered]@{}
        foreach ($key in @($page.Keys)) { if ($key -ne 'actions') { $rest[$key] = $page[$key] } }
        Test-VouchConfigObject -Node $rest -Keys $pageKeys -Path $path -Errors $Errors -Warnings $Warnings

        foreach ($required in 'name', 'url') {
            $value = $page[$required]
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                Add-VouchConfigProblem -List $Errors -Path "$path.$required" -Message "is missing: every page needs a $required."
            }
        }
        $url = $page['url']
        if ($url -is [string] -and -not [string]::IsNullOrWhiteSpace($url) -and $url.Trim() -notmatch '^(?i)https?://\S') {
            Add-VouchConfigProblem -List $Errors -Path "$path.url" -Message "must start with http:// or https:// (found ""$url"")."
        }

        $id = Get-VouchPageId -Page $page -Position ($i + 1)
        if ($seenIds.ContainsKey($id)) {
            Add-VouchConfigProblem -List $Errors -Path "$path.id" -Message "is ""$id"", which $($seenIds[$id]) already uses. Every page needs its own id."
        }
        else { $seenIds[$id] = "pages[$i]" }

        $actions = $page['actions']
        if ($null -eq $actions) { continue }
        if ($actions -isnot [System.Collections.IList]) {
            Add-VouchConfigProblem -List $Errors -Path "$path.actions" -Message "must be a list in [ ] (found $(Format-VouchConfigValue -Value $actions))."
            continue
        }
        for ($j = 0; $j -lt $actions.Count; $j++) {
            Test-VouchPageAction -Action $actions[$j] -Path "$path.actions[$j]" -Errors $Errors -Warnings $Warnings
        }
    }
}

function Test-VouchConfig {
    <#
        Checks a whole configuration and returns every problem at once, so the user can
        fix the file in one go (as Import-CaptureDefinition does for a CSV). Pure: the
        object is not changed and nothing is printed.
        Returns { Errors; Warnings }, each a list of { Path; Message }. Path is where the
        problem is in the file, such as pages[2].actions[0].selector (counting from 0).
        Accepts the dictionaries ConvertFrom-VouchJson returns, or the objects
        ConvertFrom-Json returns (converted first, so both are checked the same way).
    #>
    param([AllowNull()][object]$Config)

    $errors = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $Config -and $Config -isnot [System.Collections.IDictionary] -and $Config -is [System.Management.Automation.PSCustomObject]) {
        $Config = ConvertFrom-VouchJson -Text ($Config | ConvertTo-Json -Depth 32)
    }
    if ($Config -isnot [System.Collections.IDictionary]) {
        Add-VouchConfigProblem -List $errors -Path '' -Message 'The configuration must be one JSON object: it starts with { and ends with }.'
        return [pscustomobject]@{ Errors = $errors; Warnings = $warnings }
    }

    if (-not $Config.Contains('schemaVersion')) {
        Add-VouchConfigProblem -List $warnings -Path 'schemaVersion' -Message 'is missing; the file is read as version 1. Add "schemaVersion": 1 at the top.'
    }
    Test-VouchConfigObject -Node $Config -Keys (Get-VouchConfigSchema) -Path '' -Errors $errors -Warnings $warnings
    return [pscustomobject]@{ Errors = $errors; Warnings = $warnings }
}

function Complete-VouchConfigNode {
    <#
        Fills missing or null keys from the defaults and writes enum values in the
        schema's spelling ("PNG" -> "png"). Only for a node that passed validation.
        Blank text counts as missing when the default is not blank: "dir": "" and no
        "dir" must send the report to the same folder, and a blank report title must not
        print an empty heading. (Resolve-RunSettings already treats blank as "default".)
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Node,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Keys
    )
    foreach ($key in $Keys.Keys) {
        $spec = $Keys[$key]
        $value = if ($Node.Contains($key)) { $Node[$key] } else { $null }
        if ($spec.Type -eq 'object') {
            if ($null -eq $value) { $Node[$key] = New-VouchConfigNode -Keys $spec.Fields }
            else { Complete-VouchConfigNode -Node $value -Keys $spec.Fields }
        }
        elseif ($spec.Type -eq 'pages') {
            if ($null -eq $value) { $Node[$key] = [System.Collections.Generic.List[object]]::new() }
        }
        elseif ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value) -and
                $spec.Contains('Default') -and -not [string]::IsNullOrWhiteSpace([string]$spec.Default))) {
            if ($spec.Contains('Default')) { $Node[$key] = $spec.Default }
        }
        elseif ($spec.Type -eq 'enum') {
            $Node[$key] = @($spec.Allowed | Where-Object { $_ -eq $value })[0]
        }
    }
}

function Complete-VouchConfig {
    <#
        Turns a validated configuration into a complete one: every setting present
        (missing ones get their defaults) and every page with an id, notes, enabled,
        overrides and actions. Code that reads the configuration later never has to ask
        whether a key exists. Changes the object it is given and returns it.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    Complete-VouchConfigNode -Node $Config -Keys (Get-VouchConfigSchema)
    $overrideKeys = (Get-VouchConfigSchema)['defaults'].Fields
    $position = 0
    foreach ($page in $Config['pages']) {
        $position++
        $page['id'] = Get-VouchPageId -Page $page -Position $position
        if ($null -eq $page['notes']) { $page['notes'] = '' }
        if ($null -eq $page['enabled']) { $page['enabled'] = $true }
        if ($null -eq $page['overrides']) { $page['overrides'] = [ordered]@{} }
        if ($null -eq $page['actions']) { $page['actions'] = [System.Collections.Generic.List[object]]::new() }
        foreach ($key in @($page['overrides'].Keys)) {
            $spec = $overrideKeys[$key]
            if ($null -ne $spec -and $spec.Type -eq 'enum' -and $null -ne $page['overrides'][$key]) {
                $page['overrides'][$key] = @($spec.Allowed | Where-Object { $_ -eq $page['overrides'][$key] })[0]
            }
        }
    }
    return $Config
}

function Resolve-VouchConfigPath {
    <#
        A folder or file named in a configuration is read from the configuration file's
        folder when it is relative, not from the current directory: Task Scheduler
        starts in C:\Windows\System32, and the Designer may start anywhere.
    #>
    param(
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$BaseDirectory
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathFullyQualified($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $Path))
}

function Import-VouchConfig {
    <#
        Reads, checks and completes a configuration file for a run. All problems are
        listed together and nothing is launched, like Import-CaptureDefinition. Unknown
        keys are listed as warnings and the run goes on. Relative folders (browser
        profile, output, log, logo) are made absolute against the file's own folder.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path`nCreate one from captures.sample.json, or pass -CsvPath instead."
    }
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    try {
        $config = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($fullPath))
    }
    catch {
        throw "The configuration file '$fullPath' could not be read. $($_.Exception.Message) Nothing was launched."
    }

    $result = Test-VouchConfig -Config $config
    $describe = { param($Problem) if ($Problem.Path) { "$($Problem.Path): $($Problem.Message)" } else { $Problem.Message } }
    if ($result.Warnings.Count -gt 0) {
        Write-Host "The configuration file has $($result.Warnings.Count) note(s):" -ForegroundColor Yellow
        foreach ($warning in $result.Warnings) { Write-Host "  - $(& $describe $warning)" -ForegroundColor Yellow }
    }
    if ($result.Errors.Count -gt 0) {
        Write-Host ''
        Write-Host "The configuration file has $($result.Errors.Count) problem(s):" -ForegroundColor Red
        foreach ($problem in $result.Errors) { Write-Host "  - $(& $describe $problem)" -ForegroundColor Red }
        Write-Host ''
        throw "Fix '$fullPath' and run again. Nothing was launched."
    }

    $config = Complete-VouchConfig -Config $config
    $folder = Split-Path -Path $fullPath -Parent
    $config['browser']['profileDir'] = Resolve-VouchConfigPath -Path $config['browser']['profileDir'] -BaseDirectory $folder
    $config['output']['dir'] = Resolve-VouchConfigPath -Path $config['output']['dir'] -BaseDirectory $folder
    $config['output']['logDir'] = Resolve-VouchConfigPath -Path $config['output']['logDir'] -BaseDirectory $folder
    $config['report']['logoPath'] = Resolve-VouchConfigPath -Path $config['report']['logoPath'] -BaseDirectory $folder
    return $config
}

function ConvertTo-ActionList {
    <#
        CSV steps as configuration actions: click:/clicktext:/wait: in order, then one
        capture that scrolls ("auto") when ScrollFullPage is Y and takes one screen
        ("none") when it is not.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
        [Parameter(Mandatory)][bool]$ScrollFullPage
    )
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($step in $Steps) {
        switch ($step.Verb) {
            'click'     { $actions.Add([ordered]@{ type = 'click'; selector = [string]$step.Argument }) }
            'clicktext' { $actions.Add([ordered]@{ type = 'clickText'; text = [string]$step.Argument }) }
            'wait'      { $actions.Add([ordered]@{ type = 'wait'; seconds = [double]$step.Argument }) }
        }
    }
    $mode = if ($ScrollFullPage) { 'auto' } else { 'none' }
    $actions.Add([ordered]@{ type = 'capture'; label = ''; scroll = [ordered]@{ mode = $mode; selector = ''; as = 'segments' } })
    return , $actions
}

function ConvertTo-NormalizedActionList {
    <#
        A page's actions in one predictable shape: type in the schema's spelling, only
        the keys that type uses, defaults filled in, and a capture appended when the
        page has none (a page is there to be captured). Expects validated actions.
    #>
    param([AllowNull()][object]$Actions)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($action in @($Actions)) {
        if ($null -eq $action) { continue }
        $type = Get-VouchActionType -Type $action['type']
        $normal = [ordered]@{ type = $type }
        switch ($type) {
            'click'     { $normal['selector'] = ([string]$action['selector']).Trim() }
            'clickText' { $normal['text'] = ([string]$action['text']).Trim() }
            'wait'      { $normal['seconds'] = [double]$action['seconds'] }
            'waitFor' {
                $normal['selector'] = ([string]$action['selector']).Trim()
                $normal['timeoutSec'] = if ($null -ne $action['timeoutSec']) { [int]$action['timeoutSec'] } else { $null }
            }
            'pause' { $normal['message'] = [string]$action['message'] }
            'capture' {
                $scroll = $action['scroll']
                $scrollKeys = (Get-VouchActionSchema)['capture']['scroll'].Fields
                $normalScroll = New-VouchConfigNode -Keys $scrollKeys
                if ($scroll -is [System.Collections.IDictionary]) {
                    foreach ($key in @($scrollKeys.Keys)) {
                        if ($null -ne $scroll[$key]) { $normalScroll[$key] = [string]$scroll[$key] }
                    }
                    Complete-VouchConfigNode -Node $normalScroll -Keys $scrollKeys
                }
                $normal['label'] = [string]$action['label']
                $normal['scroll'] = $normalScroll
            }
        }
        $result.Add($normal)
    }
    if (-not @($result | Where-Object { $_['type'] -eq 'capture' })) {
        $result.Add((ConvertTo-ActionList -Steps @() -ScrollFullPage $false)[0])
    }
    return , $result
}

function ConvertTo-LegacyStepText {
    <#
        One action as the CSV-style text the report's steps column and step log show
        ("clicktext:Audit Log", "wait:2.5"). The report predates configuration files and
        auditors already read this notation, so every action kind gets a text in it.
        Numbers use the invariant culture: wait:2,5 on a German PC would not read back.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Action)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    switch ($Action['type']) {
        'click'     { return "click:$($Action['selector'])" }
        'clickText' { return "clicktext:$($Action['text'])" }
        'wait'      { return 'wait:' + ([double]$Action['seconds']).ToString($invariant) }
        'waitFor'   { return "waitfor:$($Action['selector'])" }
        'pause'     { return $(if ($Action['message']) { "pause:$($Action['message'])" } else { 'pause' }) }
        'capture'   { return $(if ($Action['label']) { "capture:$($Action['label'])" } else { 'capture' }) }
    }
    return [string]$Action['type']
}

function ConvertTo-StepText {
    <#
        A page's actions as the semicolon-separated text of the CSV Steps column
        ("click:#tab; wait:2"), for the report's steps column. The final capture of a
        page with only one capture is left out: that is what every CSV row does
        implicitly, so a converted CSV row reads exactly as before.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions)
    $captures = @($Actions | Where-Object { $_['type'] -eq 'capture' })
    $parts = for ($i = 0; $i -lt $Actions.Count; $i++) {
        $action = $Actions[$i]
        if ($action['type'] -eq 'capture' -and $captures.Count -eq 1 -and $i -eq $Actions.Count - 1) { continue }
        ConvertTo-LegacyStepText -Action $action
    }
    return (@($parts) -join '; ')
}

function ConvertTo-CaptureDefinition {
    <#
        One configuration page as the definition object Invoke-CaptureItem takes: the
        same properties a CSV row gets from Import-CaptureDefinition. Actions is the
        normalised action list; Steps, StepsText and ScrollFullPage are derived from it,
        so the report, the JSON summary and the current engine work unchanged.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Page,
        # Position in the run (file names and the report number items by it).
        [Parameter(Mandatory)][int]$Index,
        # Position in the file, for the default id; defaults to Index.
        [int]$Position = 0
    )
    if ($Position -lt 1) { $Position = $Index }
    $actions = ConvertTo-NormalizedActionList -Actions $Page['actions']
    $steps = [System.Collections.Generic.List[object]]::new()
    foreach ($action in $actions) {
        $verb = switch ($action['type']) { 'click' { 'click' } 'clickText' { 'clicktext' } 'wait' { 'wait' } default { '' } }
        if (-not $verb) { continue }
        $argument = switch ($verb) { 'click' { $action['selector'] } 'clicktext' { $action['text'] } 'wait' { [double]$action['seconds'] } }
        $steps.Add([pscustomobject]@{ Verb = $verb; Argument = $argument; Text = (ConvertTo-LegacyStepText -Action $action) })
    }
    $lastCapture = @($actions | Where-Object { $_['type'] -eq 'capture' })[-1]
    $overrides = if ($Page['overrides'] -is [System.Collections.IDictionary]) { $Page['overrides'] } else { [ordered]@{} }

    return [pscustomobject]@{
        Index          = $Index
        LineNumber     = 0
        Name           = ([string]$Page['name']).Trim()
        Url            = ([string]$Page['url']).Trim()
        StepsText      = (ConvertTo-StepText -Actions @($actions))
        Steps          = $steps
        ScrollFullPage = ($lastCapture['scroll']['mode'] -ne 'none')
        Notes          = [string]$Page['notes']
        Id             = (Get-VouchPageId -Page $Page -Position $Position)
        Enabled        = ($Page['enabled'] -ne $false)
        Overrides      = $overrides
        Actions        = $actions
    }
}

function ConvertTo-VouchConfig {
    <#
        A capture CSV as a configuration: default settings plus one page per row, ids
        p001, p002, ... The Designer's "Import CSV" calls this. Reuses
        Import-CaptureDefinition, so a CSV with problems is refused with the same
        messages a run would give.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Definitions')][AllowEmptyCollection()][object[]]$Definitions
    )
    $config = Get-DefaultVouchConfig
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Definitions = (Import-CaptureDefinition -Path $Path).ToArray()
        $config['name'] = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }
    foreach ($definition in $Definitions) {
        $actions = [System.Collections.Generic.List[object]]::new()
        foreach ($action in $definition.Actions) { $actions.Add($action) }
        $config['pages'].Add([ordered]@{
            id        = $definition.Id
            name      = $definition.Name
            url       = $definition.Url
            notes     = $definition.Notes
            enabled   = $true
            overrides = [ordered]@{}
            actions   = $actions
        })
    }
    return $config
}

function Select-VouchPage {
    <#
        The pages a run captures: with -Only, the pages named there by id or name (in
        the file's order, even if switched off); otherwise every enabled page. Index is
        renumbered 1..n so the progress line, the report and the file names count the
        pages actually run. A name or id that matches nothing stops the run: a typo in a
        scheduled task must not quietly capture nothing.
        A single -Only value with commas is split when it matches nothing as a whole,
        because "pwsh -File vouch.ps1 -Only p001,p002" passes it as one string.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Definitions,
        [AllowEmptyCollection()][string[]]$Only = @()
    )
    $wanted = @($Only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $selected = [System.Collections.Generic.List[object]]::new()
    if ($wanted.Count -eq 0) {
        foreach ($definition in $Definitions) { if ($definition.Enabled) { $selected.Add($definition) } }
    }
    else {
        # Positions of the matching pages; -eq ignores case, like the rest of Vouch.
        $find = {
            param([string]$Token)
            @(for ($i = 0; $i -lt $Definitions.Count; $i++) {
                if ($Definitions[$i].Id -eq $Token -or $Definitions[$i].Name -eq $Token) { $i }
            })
        }
        $chosen = [System.Collections.Generic.HashSet[int]]::new()
        $unknown = [System.Collections.Generic.List[string]]::new()
        foreach ($token in $wanted) {
            $tokens = @($token)
            if (@(& $find $token).Count -eq 0 -and $token.Contains(',')) {
                $tokens = @($token.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            foreach ($part in $tokens) {
                $found = @(& $find $part)
                if ($found.Count -eq 0) { $unknown.Add($part) }
                foreach ($position in $found) { [void]$chosen.Add($position) }
            }
        }
        if ($unknown.Count -gt 0) {
            $available = (@($Definitions | ForEach-Object { "$($_.Id) ($($_.Name))" }) -join ', ')
            throw "-Only: no page has the id or name '$($unknown -join "', '")'. The pages are: $available"
        }
        for ($i = 0; $i -lt $Definitions.Count; $i++) { if ($chosen.Contains($i)) { $selected.Add($Definitions[$i]) } }
    }
    for ($i = 0; $i -lt $selected.Count; $i++) { $selected[$i].Index = $i + 1 }
    return , $selected
}

function Get-InactiveConfigSetting {
    <#
        TEMPORARY - shrink as each setting starts working (report fields, zip, open
        when done).
        Settings the file may set that this engine does not apply yet. A non-default
        value is listed so the user is told it had no effect rather than finding out
        from the evidence. Returns the setting paths, each once.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $defaults = Get-DefaultVouchConfig
    $names = [System.Collections.Generic.List[string]]::new()
    $check = {
        param([string]$Name, $Value, $Default)
        if ($null -eq $Value) { return }
        if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value) -and [string]::IsNullOrWhiteSpace([string]$Default)) { return }
        if ($Value -ne $Default -and -not $names.Contains($Name)) { $names.Add($Name) }
    }
    $pageKeys = @('account')
    foreach ($key in $pageKeys) { & $check "defaults.$key" $Config['defaults'][$key] $defaults['defaults'][$key] }
    foreach ($key in 'embedImages', 'openReport') { & $check "output.$key" $Config['output'][$key] $defaults['output'][$key] }
    & $check 'output.zip.enabled' $Config['output']['zip']['enabled'] $false
    foreach ($key in @($defaults['report'].Keys)) {
        if ($defaults['report'][$key] -is [System.Collections.IDictionary]) {
            foreach ($inner in @($defaults['report'][$key].Keys)) {
                & $check "report.$key.$inner" $Config['report'][$key][$inner] $defaults['report'][$key][$inner]
            }
        }
        else { & $check "report.$key" $Config['report'][$key] $defaults['report'][$key] }
    }
    foreach ($page in $Config['pages']) {
        if ($page['overrides'] -isnot [System.Collections.IDictionary]) { continue }
        foreach ($key in $pageKeys) { & $check "page overrides: $key" $page['overrides'][$key] $defaults['defaults'][$key] }
    }
    return , $names
}

#endregion

#region Edge / CDP ------------------------------------------------------------

function Get-DebugEndpointInfo {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 3
    )
    try {
        return Invoke-RestMethod -Uri "http://$($script:CdpHost):$Port/json/version" -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-BrowserWebSocketUrl {
    param([object]$VersionInfo)
    if ($null -ne $VersionInfo -and $VersionInfo.PSObject.Properties['webSocketDebuggerUrl']) {
        return [string]$VersionInfo.webSocketDebuggerUrl
    }
    return ''
}

function Start-EdgeDebug {
    <#
        Chromium 136+ refuses --remote-debugging-port when the default user profile is
        used, so a dedicated --user-data-dir is mandatory. Logins made with -LoginSetup
        live in that directory and persist between runs.
    #>
    param(
        [Parameter(Mandatory)][string]$EdgePath,
        [Parameter(Mandatory)][string]$ProfileDir,
        [Parameter(Mandatory)][int]$Port
    )

    $existing = Get-DebugEndpointInfo -Port $Port
    if ($null -ne $existing) {
        $script:ReusedEdge = $true
        $script:LaunchedEdge = $false
        $script:EdgeProcess = Find-EdgeBrowserProcess -Port $Port
        $script:BrowserWsUrl = Get-BrowserWebSocketUrl -VersionInfo $existing
        Write-Host "Reusing the Edge instance already listening on port $Port." -ForegroundColor Yellow
        return $existing
    }

    # Launching against a profile that an ordinary Edge window already holds just hands
    # the request to that window, and the DevTools port never opens.
    $holder = Find-EdgeBrowserProcess -ProfileDir $ProfileDir
    if ($null -ne $holder) {
        throw "Edge is already running with the audit profile (process $($holder.Id)) but without the DevTools port - typically a window left open after -LoginSetup. Close every Edge window that uses $ProfileDir and run again."
    }

    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        [void](New-Item -ItemType Directory -Path $ProfileDir -Force)
    }

    # Start-Process joins -ArgumentList with spaces but never quotes, so the path must
    # carry its own quotes or a profile under e.g. C:\Users\John Doe\ splits into two args.
    # TrimEnd('\') also prevents a trailing backslash from escaping the closing quote.
    $arguments = @(
        "--remote-debugging-port=$Port"
        "--user-data-dir=`"$($ProfileDir.TrimEnd('\'))`""
        '--no-first-run'
        '--no-default-browser-check'
        '--start-maximized'
        'about:blank'
    )

    Write-Host "Launching Edge with the audit profile ($ProfileDir)..."
    [void](Start-Process -FilePath $EdgePath -ArgumentList $arguments)
    $script:LaunchedEdge = $true

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $info = Get-DebugEndpointInfo -Port $Port
        if ($null -ne $info) {
            $script:EdgeProcess = Find-EdgeBrowserProcess -Port $Port -ProfileDir $ProfileDir
            if ($null -eq $script:EdgeProcess) {
                Write-Verbose 'Could not identify the Edge browser process; window focus falls back to title matching.'
            }
            $script:BrowserWsUrl = Get-BrowserWebSocketUrl -VersionInfo $info
            return $info
        }
    }

    throw "Edge did not open its DevTools endpoint on port $Port within 15 seconds. Close any running Edge instance that uses the audit profile and try again, or pick another port with -DebugPort."
}

function Get-DevToolsTargetList {
    <#
        PowerShell 7's Invoke-RestMethod writes a JSON array to the pipeline as ONE object,
        so @(Invoke-RestMethod ...) is a one-element array holding the whole list. Unroll
        it, or every lookup silently sees a single "target" with no type.
    #>
    param([Parameter(Mandatory)][int]$Port)
    $response = Invoke-RestMethod -Uri "http://$($script:CdpHost):$Port/json/list" -TimeoutSec 10 -NoProxy
    $response | ForEach-Object { $_ }
}

function Get-PageTargetKind {
    <#
        What a "page" target in /json/list really is. Edge lists its own pages and tools
        as page targets like any web page, and two decisions depend on telling them
        apart (which tab to attach to, which tabs to close), so both read this one
        classification:
        'browser' - Edge's own pages (edge://, chrome://), e.g. the sync dialog a fresh
                    profile opens on a work-joined PC;
        'tool'    - DevTools windows and extension pages (devtools://, chrome-extension://,
                    edge-extension://), which belong to something else;
        'web'     - everything else, the pages a run can use.
    #>
    param([AllowNull()][object]$Target)
    $url = if ($null -ne $Target -and $Target.PSObject.Properties['url']) { [string]$Target.url } else { '' }
    if ($url -match '^(?i)(edge|chrome)://') { return 'browser' }
    if ($url -match '^(?i)(devtools|chrome-extension|edge-extension)://') { return 'tool' }
    return 'web'
}

function Test-InternalPageTarget {
    <#
        Browser-internal tabs (edge://, chrome://, devtools:// and extension pages) are
        listed as "page" targets like any web page. A fresh Edge profile - especially on a
        work-joined PC - opens edge://sync-confirmation-dialog/ and lists it FIRST, so a
        run that took the first page attached to that dialog instead of its own tab.
    #>
    param([AllowNull()][object]$Target)
    return (Get-PageTargetKind -Target $Target) -ne 'web'
}

function Get-CdpPageTarget {
    <#
        Returns an existing tab, or opens one. Right after the DevTools port opens, a
        freshly launched Edge briefly lists no tabs at all even though its about:blank
        tab is on its way, so wait up to -WaitSeconds for it rather than opening a
        second tab that would then show up in every screenshot.
        Internal tabs (Test-InternalPageTarget) are never used: the run would navigate
        Edge's own dialog, and the real tab would stay behind it.
        -TabId (default: $script:CdpTabId, set from -TabId for the whole run) picks one
        tab by its target id - the Designer's visible tab, which is not necessarily the
        first in the list. That tab must exist: opening another would capture a tab the
        person is not looking at, so a missing one is an error.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [double]$WaitSeconds = 0,
        [AllowEmptyString()][string]$TabId = $script:CdpTabId
    )

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $targets = @()
        try {
            $targets = @(Get-DevToolsTargetList -Port $Port)
        }
        catch {
            Write-Verbose "Could not enumerate DevTools targets: $($_.Exception.Message)"
        }

        if ($TabId) {
            foreach ($target in $targets) {
                if ($target.PSObject.Properties['id'] -and [string]$target.id -eq $TabId -and
                    $target.PSObject.Properties['type'] -and $target.type -eq 'page' -and
                    $target.PSObject.Properties['webSocketDebuggerUrl'] -and
                    -not [string]::IsNullOrWhiteSpace($target.webSocketDebuggerUrl)) {
                    return $target
                }
            }
            if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
            continue
        }

        foreach ($target in $targets) {
            if ($target.PSObject.Properties['type'] -and $target.type -eq 'page' -and
                $target.PSObject.Properties['webSocketDebuggerUrl'] -and
                -not [string]::IsNullOrWhiteSpace($target.webSocketDebuggerUrl) -and
                -not (Test-InternalPageTarget -Target $target)) {
                return $target
            }
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    } while ((Get-Date) -lt $deadline)

    if ($TabId) {
        throw "Edge has no open tab with the id '$TabId' (on port $Port). The tab may have been closed, or this Edge was started by this run and has none of the earlier tabs. Open the page again, or leave out -TabId to use the first tab."
    }

    # Newer Chromium builds reject GET on /json/new; PUT is the supported verb.
    # GET is kept as a fallback for older builds.
    $newTargetUri = "http://$($script:CdpHost):$Port/json/new?about:blank"
    try {
        return Invoke-RestMethod -Method Put -Uri $newTargetUri -TimeoutSec 10 -NoProxy
    }
    catch {
        Write-Verbose "PUT /json/new failed ($($_.Exception.Message)); retrying with GET."
        return Invoke-RestMethod -Method Get -Uri $newTargetUri -TimeoutSec 10 -NoProxy
    }
}

function Close-OtherPageTargets {
    <#
        A fresh profile opens with more than one tab (the about:blank from the command line
        plus Edge's own start page). Every screenshot shows the tab strip, so close the
        tabs the run does not use. Only called for an Edge this run launched.
        Edge's own edge:// and chrome:// tabs are closed too: they would sit in the tab
        strip of every screenshot. (The sync sign-in dialog of a fresh profile is listed
        like a tab but answers "Target is closing" and stays: it is a dialog, and only
        --disable-sync at launch keeps it away.) DevTools windows and extension pages are
        left alone - they are not tabs of the run and closing them could break whatever
        opened them.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$KeepId
    )
    try {
        $targets = @(Get-DevToolsTargetList -Port $Port)
    }
    catch {
        Write-Verbose "Could not list tabs to tidy up: $($_.Exception.Message)"
        return
    }
    foreach ($target in $targets) {
        if (-not $target.PSObject.Properties['type'] -or $target.type -ne 'page') { continue }
        if ([string]$target.id -eq $KeepId) { continue }
        if ((Get-PageTargetKind -Target $target) -eq 'tool') { continue }
        try { [void](Invoke-RestMethod -Uri "http://$($script:CdpHost):$Port/json/close/$($target.id)" -TimeoutSec 10 -NoProxy) }
        catch { Write-Verbose "Could not close tab $($target.id): $($_.Exception.Message)" }
    }
}

function Connect-CdpSocket {
    param(
        [Parameter(Mandatory)][string]$WebSocketUrl,
        [int]$TimeoutSec = 15
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)

    # PowerShell binds GetAwaiter() on the task's runtime type, Task<VoidTaskResult>, so
    # GetResult() returns an object; [void] keeps it out of the function's output.
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        [void]$socket.ConnectAsync([Uri]::new($WebSocketUrl), $cts.Token).GetAwaiter().GetResult()
    }
    catch {
        $socket.Dispose()
        throw "Could not open the DevTools WebSocket ($WebSocketUrl): $($_.Exception.Message)"
    }
    finally {
        $cts.Dispose()
    }

    $script:CdpSocket = $socket
    $script:CdpWebSocketUrl = $WebSocketUrl
    $script:CdpMessageId = 0
}

function Restore-CdpConnection {
    <#
        Cancelling a ClientWebSocket receive (which is how a CDP timeout is implemented)
        aborts the socket for good. Open a fresh connection to the same tab so one slow
        page does not fail every row after it; if the tab is gone, attach to another.
        The page zoom (Set-PageZoom) belongs to the connection that set it and is gone
        with it, so it is set again on the new one.
    #>
    $url = $script:CdpWebSocketUrl
    Close-CdpSocket
    $connected = $false
    try {
        Connect-CdpSocket -WebSocketUrl $url
        $connected = $true
    }
    catch {
        Write-Verbose "Reconnecting to the same tab failed: $($_.Exception.Message)"
    }
    if (-not $connected) {
        if ($script:CdpPort -le 0) { throw 'The DevTools connection was lost and could not be re-established.' }
        $target = Get-CdpPageTarget -Port $script:CdpPort
        if ($null -eq $target -or -not $target.PSObject.Properties['webSocketDebuggerUrl']) {
            throw 'The DevTools connection was lost and no page target is available to reconnect to.'
        }
        Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
    }

    $zoom = $script:PageZoomPercent
    if ($zoom -ne 100) {
        try { Set-PageZoom -Percent $zoom }
        catch {
            # Set-PageZoom leaves the zoom recorded as 100, so the captures say what they
            # show; the flag lets the page being captured say so too (Add-ZoomLostDetail).
            $script:PageZoomLost = $zoom
            Write-Host "WARNING: the page zoom of $zoom% could not be set again after reconnecting to Edge; the page is shown at 100%: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Receive-CdpMessage {
    <#
        Reads exactly one WebSocket message. CDP payloads routinely exceed any single
        buffer, so frames are accumulated until EndOfMessage before decoding.
        -AsBytes returns the raw UTF-8 bytes instead of a string: a screenshot response
        can be tens of megabytes, and every text copy of it costs that again.
    #>
    param(
        [Parameter(Mandatory)][datetime]$Deadline,
        [switch]$AsBytes
    )

    $buffer = [byte[]]::new(65536)
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $stream = [System.IO.MemoryStream]::new()
    try {
        while ($true) {
            $remaining = $Deadline - (Get-Date)
            if ($remaining.TotalMilliseconds -le 0) {
                throw 'Timed out waiting for a response from the browser (DevTools WebSocket).'
            }

            $cts = [System.Threading.CancellationTokenSource]::new($remaining)
            try {
                $result = $script:CdpSocket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            }
            catch {
                # The token's timer can fire a few milliseconds before Get-Date reaches
                # the deadline; the cancellation is still the timeout, not some other
                # failure, so it gets the same message.
                if ($cts.IsCancellationRequested -or (Get-Date) -ge $Deadline) {
                    throw 'Timed out waiting for a response from the browser (DevTools WebSocket).'
                }
                throw
            }
            finally {
                $cts.Dispose()
            }

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'The browser closed the DevTools WebSocket.'
            }

            $stream.Write($buffer, 0, $result.Count)
            if ($result.EndOfMessage) { break }
        }

        if ($AsBytes) { return , $stream.ToArray() }
        return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}

function Send-CdpCommand {
    <#
        Synchronous request/response over CDP: send a command with an incrementing id,
        then read messages until the matching response arrives, discarding events.
        -ReturnDataBytes is for screenshots: it returns result.data decoded from base64
        as a byte[], read with System.Text.Json straight from the received bytes.
        ConvertFrom-Json builds the whole response as one string and a full-page PNG
        response of ~77 MB took ~1.8 GB of memory that way.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 0,
        [switch]$ReturnDataBytes
    )

    if ($TimeoutSec -le 0) { $TimeoutSec = $script:CdpDefaultTimeout }
    if ($null -eq $script:CdpSocket) { throw 'No DevTools connection is open.' }
    if ($script:CdpSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        Write-Verbose "DevTools socket is $($script:CdpSocket.State); reconnecting."
        Restore-CdpConnection
    }

    $script:CdpMessageId++
    $messageId = $script:CdpMessageId

    $json = (@{ id = $messageId; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $payload = [System.ArraySegment[byte]]::new($bytes)

    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        [void]$script:CdpSocket.SendAsync($payload, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
    }
    finally {
        $cts.Dispose()
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if ($ReturnDataBytes) {
            $answer = ConvertFrom-CdpDataResponse -Message (Receive-CdpMessage -Deadline $deadline -AsBytes) -MessageId $messageId -Method $Method
            if ($null -ne $answer) { return , $answer.Data }
            continue
        }
        $raw = Receive-CdpMessage -Deadline $deadline
        $message = $raw | ConvertFrom-Json

        if (-not $message.PSObject.Properties['id']) { continue }   # event notification
        if ([int]$message.id -ne $messageId) { continue }           # stale response

        if ($message.PSObject.Properties['error']) {
            $errorText = if ($message.error.PSObject.Properties['message']) { [string]$message.error.message } else { $raw }
            throw "CDP command '$Method' failed: $errorText"
        }
        if ($message.PSObject.Properties['result']) { return $message.result }
        return $null
    }
}

function ConvertFrom-CdpDataResponse {
    <#
        Reads one raw CDP message for Send-CdpCommand -ReturnDataBytes. Returns $null
        when it is not the awaited response (an event, or a stale reply), throws the
        browser's error, and otherwise returns { Data = byte[] } with result.data
        decoded from base64 (empty when the result has no data). System.Text.Json reads
        the UTF-8 bytes in place and decodes the base64 directly, so no string copy of
        a large screenshot is ever made.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Message,
        [Parameter(Mandatory)][int]$MessageId,
        [Parameter(Mandatory)][string]$Method
    )
    $stream = [System.IO.MemoryStream]::new($Message, $false)
    $document = [System.Text.Json.JsonDocument]::Parse($stream)
    try {
        # PowerShell cannot pick among TryGetProperty's overloads, so the properties are
        # looked up by walking them.
        $find = {
            param([System.Text.Json.JsonElement]$Element, [string]$Name)
            if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
            foreach ($property in $Element.EnumerateObject()) {
                if ($property.Name -ceq $Name) { return , $property.Value }
            }
            return $null
        }
        $root = $document.RootElement
        $id = & $find $root 'id'
        if ($null -eq $id -or $id.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $id.GetInt64() -ne $MessageId) { return $null }
        $errorElement = & $find $root 'error'
        if ($null -ne $errorElement) {
            $text = & $find $errorElement 'message'
            $errorText = if ($null -ne $text) { $text.ToString() } else { $errorElement.GetRawText() }
            throw "CDP command '$Method' failed: $errorText"
        }
        $data = $null
        $result = & $find $root 'result'
        if ($null -ne $result) { $data = & $find $result 'data' }
        if ($null -ne $data -and $data.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
            return [pscustomobject]@{ Data = $data.GetBytesFromBase64() }
        }
        return [pscustomobject]@{ Data = [byte[]]::new(0) }
    }
    finally {
        $document.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-JsLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return (ConvertTo-Json -InputObject $Value -Compress)
}

function Invoke-CdpEval {
    param(
        [Parameter(Mandatory)][string]$Expression,
        [int]$TimeoutSec = 0
    )

    $result = Send-CdpCommand -Method 'Runtime.evaluate' -TimeoutSec $TimeoutSec -Params @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = $true
        userGesture   = $true
    }

    if ($null -eq $result) { return $null }

    if ($result.PSObject.Properties['exceptionDetails'] -and $null -ne $result.exceptionDetails) {
        $details = $result.exceptionDetails
        $description = ''
        if ($details.PSObject.Properties['exception'] -and $null -ne $details.exception -and
            $details.exception.PSObject.Properties['description']) {
            $description = [string]$details.exception.description
        }
        if ([string]::IsNullOrWhiteSpace($description) -and $details.PSObject.Properties['text']) {
            $description = [string]$details.text
        }
        if ([string]::IsNullOrWhiteSpace($description)) { $description = 'unknown JavaScript error' }
        throw "JavaScript error in the page: $description"
    }

    if ($result.PSObject.Properties['result'] -and $null -ne $result.result -and
        $result.result.PSObject.Properties['value']) {
        return $result.result.value
    }
    return $null
}

function Set-NavigationMarker {
    <#
        Stamps the current document so Wait-PageReady can tell the new document from the
        old one. A navigation replaces the window object and the marker disappears with it.
    #>
    try { [void](Invoke-CdpEval -Expression 'window.__vouchMark = 1' -TimeoutSec 10) }
    catch { Write-Verbose "Could not set the navigation marker: $($_.Exception.Message)" }
}

function Wait-PageReady {
    <#
        Navigation completion is detected by polling rather than by subscribing to Page
        lifecycle events: no event pump is needed, and it behaves the same for classic
        navigations and for SPAs.

        readyState alone is not enough - for a moment after Page.navigate the previous
        document is still current and already reports 'complete'. The marker set before
        navigating disambiguates. Same-document navigations (a #fragment) keep the marker
        forever, so after a grace period a completed document is accepted regardless.
        Returns $false at once when the run is stopped (Test-StopRequested); the caller
        tells that apart from a page that never loaded.
    #>
    param(
        [Parameter(Mandatory)][int]$TimeoutSec,
        [double]$SameDocumentGraceSeconds = 3
    )

    $expression = "(typeof window.__vouchMark === 'undefined' ? 'new' : 'old') + '|' + document.readyState"
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        if (Test-StopRequested) { return $false }
        $state = $null
        try {
            $state = Invoke-CdpEval -Expression $expression -TimeoutSec 10
        }
        catch {
            Write-Verbose "readyState poll failed: $($_.Exception.Message)"
        }

        if ($state -is [string] -and $state.Contains('|')) {
            $parts = $state.Split('|')
            $isNewDocument = ($parts[0] -eq 'new')
            $isComplete = ($parts[1] -eq 'complete')
            $graceElapsed = ((Get-Date) - $start).TotalSeconds -ge $SameDocumentGraceSeconds
            if ($isComplete -and ($isNewDocument -or $graceElapsed)) { return $true }
        }

        Start-Sleep -Milliseconds 250
    }
    return $false
}

#endregion

#region Page zoom and page-content capture ---------------------------------------

function Get-ZoomDeviceMetrics {
    <#
        The Emulation.setDeviceMetricsOverride parameters that zoom a page the way
        Ctrl+plus/minus does: the layout gets W/z x H/z CSS pixels and is drawn at scale z
        into the unchanged window, so it reflows and fills the window exactly. Measured in
        a headed, maximised Edge: deviceScaleFactor alone changes nothing on screen, and
        scale without dontSetVisibleSize letterboxes or cuts off the page. deviceScaleFactor
        0 keeps the screen's own pixel ratio, so sites do not switch to high-DPI images.
        -Width/-Height: window.innerWidth/innerHeight measured with no override active.
    #>
    param(
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][ValidateRange(25, 500)][int]$ZoomPercent
    )
    $scale = $ZoomPercent / 100.0
    return @{
        width              = [int][Math]::Round($Width / $scale)
        height             = [int][Math]::Round($Height / $scale)
        deviceScaleFactor  = 0
        mobile             = $false
        scale              = $scale
        dontSetVisibleSize = $true
    }
}

function Set-PageZoom {
    <#
        Zooms the page in the connected tab (Get-ZoomDeviceMetrics). Nothing is stored in
        the Edge profile: the override belongs to this DevTools connection, survives
        navigation and redirects, and disappears when the connection closes - which is
        why Restore-CdpConnection sets it again and $script:PageZoomPercent remembers it.
        The window must already have its final size: the zoom is computed from it.
        100 removes any zoom. On failure the zoom is left at 100 and the error thrown.
    #>
    param([Parameter(Mandatory)][ValidateRange(25, 500)][int]$Percent)

    # Recorded as 100 until it really applies, so a reconnect in the middle of this
    # does not try to apply it from inside itself, and captures never claim a zoom
    # the page does not show.
    $script:PageZoomPercent = 100
    [void](Send-CdpCommand -Method 'Emulation.clearDeviceMetricsOverride' -TimeoutSec 10)
    if ($Percent -eq 100) { return }

    $size = Invoke-CdpEval -Expression '({ width: window.innerWidth, height: window.innerHeight })' -TimeoutSec 10
    $width = if ($null -ne $size) { [int]$size.width } else { 0 }
    $height = if ($null -ne $size) { [int]$size.height } else { 0 }
    if ($width -le 0 -or $height -le 0) {
        throw 'the browser window reported no size, so the zoom could not be worked out.'
    }
    $metrics = Get-ZoomDeviceMetrics -Width $width -Height $height -ZoomPercent $Percent
    [void](Send-CdpCommand -Method 'Emulation.setDeviceMetricsOverride' -Params $metrics -TimeoutSec 10)
    $script:PageZoomPercent = $Percent
}

function Clear-PageZoom {
    <#
        Shows the page at 100% again. Also called at the end of every run: the Designer
        keeps Edge open, and a page left zoomed would puzzle the person using it.
        Recorded as 100 only once the browser accepted it: if the command fails, the
        page may still be zoomed, and the captures must keep saying so.
    #>
    [void](Send-CdpCommand -Method 'Emulation.clearDeviceMetricsOverride' -TimeoutSec 10)
    $script:PageZoomPercent = 100
}

function Add-ZoomLostDetail {
    <#
        Turns a zoom that a reconnect could not set again ($script:PageZoomLost, set by
        Restore-CdpConnection) into a WARNING on the page being captured, once, and
        clears the flag. The reconnect happens deep inside some CDP call, where no item
        is at hand; without this the report would say OK above images whose zoom
        changed half-way through the page.
    #>
    param([Parameter(Mandatory)][object]$Item)
    $lost = $script:PageZoomLost
    if ($lost -le 0) { return }
    $script:PageZoomLost = 0
    if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
    $Item.Details.Add("The connection to Edge was lost and restored during this page, but the page zoom of $lost% could not be set again; any images of this page taken after that show it at 100%.")
}

function Get-SingleImagePlan {
    <#
        Whether a whole document fits in one image. Page.captureScreenshot returns an
        image of the full requested size above 16,384 pixels, but past that height it
        silently repeats the top of the page (measured, no error) - so the height the
        image WILL have is worked out before capturing: CSS height x the screen's pixel
        ratio x the zoom scale. Pure.
    #>
    param(
        [Parameter(Mandatory)][double]$CssHeight,
        [double]$DevicePixelRatio = 1,
        [int]$ZoomPercent = 100,
        [int]$MaxHeight = 16384
    )
    if ($DevicePixelRatio -le 0) { $DevicePixelRatio = 1 }
    $outputHeight = [int][Math]::Ceiling($CssHeight * $DevicePixelRatio * ($ZoomPercent / 100.0))
    return [pscustomobject]@{ OutputHeight = $outputHeight; Fits = ($outputHeight -le $MaxHeight -and $outputHeight -gt 0) }
}

function Get-PageContentSize {
    <#
        The size of the whole document in CSS pixels (Page.getLayoutMetrics, which is
        exact - window.scrollHeight misses margins) and the screen's pixel ratio, for a
        one-image capture.
    #>
    $metrics = Send-CdpCommand -Method 'Page.getLayoutMetrics' -TimeoutSec 10
    $content = if ($metrics.PSObject.Properties['cssContentSize']) { $metrics.cssContentSize } else { $metrics.contentSize }
    $ratio = 1.0
    try { $ratio = [double](Invoke-CdpEval -Expression 'window.devicePixelRatio' -TimeoutSec 10) }
    catch { Write-Verbose "Could not read the pixel ratio: $($_.Exception.Message)" }
    return [pscustomobject]@{
        Width            = [double]$content.width
        Height           = [double]$content.height
        DevicePixelRatio = $ratio
    }
}

function Get-PageCapture {
    <#
        An image of the page content only, taken by the browser (Page.captureScreenshot):
        no window, focus or visible desktop is needed, and it contains no address bar,
        taskbar or clock. The image comes back already encoded in the run's format, so
        a JPEG is compressed once only.
        Without -Clip: what the window shows now. The clip is the visible part of the
        document in document coordinates (cssVisualViewport pageX/pageY), and scale z
        makes the image the size it has on screen - a capture under the zoom override
        otherwise comes back at the emulated CSS size. The window's scroll bar is not
        part of the page and is left out.
        With -Clip @{ x; y; width; height } (CSS pixels): that part of the whole document,
        beyond the window (one tall image). Get-SingleImagePlan must have said it fits.
        Returns the encoded image (no Vouch metadata yet).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('jpeg', 'png')][string]$Format,
        [int]$Quality = 85,
        [int]$ZoomPercent = 100,
        [System.Collections.IDictionary]$Clip = $null
    )
    $scale = $ZoomPercent / 100.0
    $params = @{ format = $Format }
    if ($Format -eq 'jpeg') { $params.quality = $Quality }
    $timeoutSec = 30
    if ($null -ne $Clip) {
        $params.clip = @{ x = [double]$Clip.x; y = [double]$Clip.y; width = [double]$Clip.width; height = [double]$Clip.height; scale = $scale }
        $params.captureBeyondViewport = $true
        # A 16,000 px PNG of a busy page is ~77 MB of base64 and took 2 s; leave room.
        $timeoutSec = 120
    }
    else {
        $metrics = Send-CdpCommand -Method 'Page.getLayoutMetrics' -TimeoutSec 10
        $view = if ($metrics.PSObject.Properties['cssVisualViewport']) { $metrics.cssVisualViewport } else { $metrics.visualViewport }
        $params.clip = @{ x = [double]$view.pageX; y = [double]$view.pageY; width = [double]$view.clientWidth; height = [double]$view.clientHeight; scale = $scale }
    }
    $bytes = Send-CdpCommand -Method 'Page.captureScreenshot' -Params $params -TimeoutSec $timeoutSec -ReturnDataBytes
    if ($null -eq $bytes -or $bytes.Length -eq 0) { throw 'The browser returned an empty page image.' }
    return , $bytes
}

#endregion

#region Window focus and screen capture ---------------------------------------

function Get-EdgeWindowHandle {
    param(
        [int]$TimeoutSec = 10,
        [string]$ExpectedTitle = ''
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        # Re-query each time: MainWindowHandle is cached per Process object and the
        # browser may not have created its window yet.
        if ($null -ne $script:EdgeProcess) {
            try {
                $process = Get-Process -Id $script:EdgeProcess.Id -ErrorAction Stop
                if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return $process.MainWindowHandle }
            }
            catch {
                Write-Verbose "The audit Edge process is no longer available: $($_.Exception.Message)"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ExpectedTitle)) {
            # The browser process is unknown, so the user's personal Edge windows are
            # candidates too. Only a window showing the page just navigated qualifies;
            # focusing any other would put the wrong application into the evidence.
            $candidates = @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
            foreach ($candidate in $candidates) {
                if ($candidate.MainWindowTitle.Contains($ExpectedTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $candidate.MainWindowHandle
                }
            }
        }

        Start-Sleep -Milliseconds 300
    }

    return [IntPtr]::Zero
}

function Set-EdgeForeground {
    param(
        [int]$TimeoutSec = 10,
        [string]$ExpectedTitle = ''
    )

    $handle = Get-EdgeWindowHandle -TimeoutSec $TimeoutSec -ExpectedTitle $ExpectedTitle
    if ($handle -eq [IntPtr]::Zero) {
        return 'Could not locate the Edge window; the screenshot may show another application.'
    }

    [void][Vouch.Native]::ShowWindow($handle, 3)   # SW_MAXIMIZE
    [void][Vouch.Native]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 500

    if ([Vouch.Native]::GetForegroundWindow() -ne $handle) {
        # Windows ignores SetForegroundWindow from a background process - which is what
        # a scheduled run is - unless that process sent the last input event. A synthetic
        # Alt press and release satisfies the rule without typing anything.
        [Vouch.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # VK_MENU down
        [Vouch.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # KEYEVENTF_KEYUP
        [void][Vouch.Native]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 300
        if ([Vouch.Native]::GetForegroundWindow() -ne $handle) {
            return 'Windows refused to bring Edge to the foreground; check the screenshots for overlapping windows.'
        }
    }
    return $null
}

function Set-EdgeWindowMaximized {
    <#
        Maximises the Edge window ahead of the page, without waiting for the capture.
        A page zoom is computed from the window's size (Set-PageZoom), so the window must
        already have the size it will be captured at; Set-EdgeForeground maximises it
        only right before the screenshot. Called only for zoomed screen and window
        captures, so runs at 100% behave exactly as before. A window that cannot be found
        is left to Set-EdgeForeground to report.
    #>
    param(
        [int]$TimeoutSec = 3,
        [string]$ExpectedTitle = ''
    )
    $handle = Get-EdgeWindowHandle -TimeoutSec $TimeoutSec -ExpectedTitle $ExpectedTitle
    if ($handle -eq [IntPtr]::Zero) { return }
    if ([Vouch.WindowGeometry]::IsZoomed($handle)) { return }
    [void][Vouch.Native]::ShowWindow($handle, 3)   # SW_MAXIMIZE
    # The page learns its new size a moment after the window changes.
    Start-Sleep -Milliseconds 500
}

function Get-PrimaryScreenBounds {
    # The primary display in screen coordinates: what Get-ScreenCapture grabs.
    return [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
}

function Get-EdgeWindowBounds {
    <#
        Where the Edge window is on screen, as a Rectangle, or $null when the window is
        not found. DWMWA_EXTENDED_FRAME_BOUNDS is the window as drawn: GetWindowRect adds
        invisible resize borders of about 7 px on each side (8 px past the screen edge
        for a maximised window), which would put a strip of whatever is behind the window
        into the evidence. GetWindowRect is only the fallback when DWM cannot answer.
    #>
    param(
        [int]$TimeoutSec = 5,
        [string]$ExpectedTitle = ''
    )
    $handle = Get-EdgeWindowHandle -TimeoutSec $TimeoutSec -ExpectedTitle $ExpectedTitle
    if ($handle -eq [IntPtr]::Zero) { return $null }
    $rect = [Vouch.WindowRect]::new()
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Vouch.WindowRect])
    if ([Vouch.WindowGeometry]::DwmGetWindowAttribute($handle, [Vouch.WindowGeometry]::ExtendedFrameBounds, [ref]$rect, $size) -ne 0) {
        if (-not [Vouch.WindowGeometry]::GetWindowRect($handle, [ref]$rect)) { return $null }
    }
    return [System.Drawing.Rectangle]::FromLTRB($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
}

function Get-WindowCaptureRectangle {
    <#
        The part of the screen image to keep for a window-only capture: the window's
        bounds clipped to the primary display (what Get-ScreenCapture grabs), in that
        image's own coordinates. $null when nothing of the window is on the primary
        display - minimised, on another monitor, or empty bounds - so the caller can fall
        back to the whole screen. Display scaling needs no handling here: the process is
        DPI-aware (Initialize-NativeInterop), so both rectangles are in physical pixels.
        Pure.
    #>
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$WindowBounds,
        [Parameter(Mandatory)][System.Drawing.Rectangle]$ScreenBounds
    )
    if ($WindowBounds.Width -le 0 -or $WindowBounds.Height -le 0) { return $null }
    $visible = [System.Drawing.Rectangle]::Intersect($WindowBounds, $ScreenBounds)
    if ($visible.Width -le 0 -or $visible.Height -le 0) { return $null }
    return [System.Drawing.Rectangle]::new($visible.X - $ScreenBounds.X, $visible.Y - $ScreenBounds.Y, $visible.Width, $visible.Height)
}

function Send-KeyChord {
    # Presses the keys in order and releases them in reverse, like a person would.
    param([Parameter(Mandatory)][byte[]]$Keys)
    foreach ($key in $Keys) {
        $flags = if ($key -eq 0x5B) { 1 } else { 0 }   # the Windows key is an extended key
        [Vouch.Native]::keybd_event($key, 0, $flags, [UIntPtr]::Zero)
    }
    [array]::Reverse($Keys)
    foreach ($key in $Keys) {
        $flags = if ($key -eq 0x5B) { 3 } else { 2 }   # KEYEVENTF_KEYUP (| EXTENDEDKEY)
        [Vouch.Native]::keybd_event($key, 0, $flags, [UIntPtr]::Zero)
    }
}

function Get-TopLevelWindowHandles {
    # Main windows of every process in this session. Called before the audit Edge starts,
    # so these are all windows the capture desktop should leave behind.
    $sessionId = (Get-Process -Id $PID).SessionId
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId -and $_.MainWindowHandle -ne [IntPtr]::Zero } |
        ForEach-Object { $_.MainWindowHandle })
}

function New-CaptureDesktop {
    <#
        Opens a fresh virtual desktop (Win+Ctrl+D) so the capture happens where no other
        application's window exists: the taskbar then shows only what runs on that
        desktop, plus pinned icons and the clock. Windows has no supported API to create
        desktops, so the shell shortcut is used, and the documented
        IVirtualDesktopManager confirms the switch: every window that was open before
        must now be on another desktop.
    #>
    $before = Get-TopLevelWindowHandles
    # A window pinned to all desktops never leaves, so one window gone is proof enough.
    $switched = { @($before | Where-Object { [Vouch.VirtualDesktop]::IsOnCurrent($_) -eq 0 }).Count -gt 0 }
    $shortcut = [byte[]](0x5B, 0x11, 0x44)   # Win + Ctrl + D

    $state = [pscustomobject]@{ Created = $true; Verified = $false; ReferenceWindows = $before; Note = '' }
    if ($before.Count -eq 0) {
        # Nothing to confirm with, so a single attempt: a retry could open a second desktop.
        Send-KeyChord -Keys $shortcut
        Start-Sleep -Milliseconds 1500
        $state.Note = 'Separate virtual desktop requested (no other windows were open, so the switch could not be confirmed).'
        return $state
    }
    if (Invoke-DesktopShortcut -Keys $shortcut -Done $switched) {
        $state.Verified = $true
        $state.Note = 'Captured on a separate virtual desktop; other applications stayed on the original desktop.'
    }
    else {
        $state.Note = 'A separate virtual desktop was requested, but Windows did not switch to it; other applications may appear in the taskbar.'
        # Nothing was switched, so there is nothing to close later.
        $state.Created = $false
    }
    return $state
}

function Test-EdgeOnCaptureDesktop {
    # $true when the audit Edge window is on the desktop currently shown.
    $handle = Get-EdgeWindowHandle -TimeoutSec 10
    if ($handle -eq [IntPtr]::Zero) { return $false }
    return ([Vouch.VirtualDesktop]::IsOnCurrent($handle) -eq 1)
}

function Remove-CaptureDesktop {
    <#
        Closes the desktop the run opened (Win+Ctrl+F4), which returns the screen to the
        previous desktop; windows still on it move there too. Only when the original
        windows are still elsewhere - i.e. the capture desktop is the one showing - so
        the user's own desktop is never the one closed.
    #>
    param([object]$State)
    if ($null -eq $State -or -not $State.Created) { return }
    $elsewhere = @($State.ReferenceWindows | Where-Object { [Vouch.VirtualDesktop]::IsOnCurrent($_) -eq 0 })
    if ($elsewhere.Count -eq 0) {
        Write-Verbose 'The original desktop is already showing; not closing anything.'
        return
    }
    $backHome = { @($State.ReferenceWindows | Where-Object { [Vouch.VirtualDesktop]::IsOnCurrent($_) -eq 0 }).Count -eq 0 }
    if (-not (Invoke-DesktopShortcut -Keys ([byte[]](0x5B, 0x11, 0x73)) -Done $backHome)) {   # Win + Ctrl + F4
        Write-Host 'WARNING: the capture desktop could not be closed; close it in Task View (Win+Tab).' -ForegroundColor Yellow
    }
}

function Invoke-DesktopShortcut {
    <#
        Sends a virtual desktop shortcut and returns whether -Done confirms it worked.
        Windows discards simulated keys while an elevated window (e.g. an editor run as
        administrator) is in front and the sender is not elevated - the normal case for a
        scheduled run. The retry first hands focus to the taskbar, which runs with
        normal rights, so the second attempt gets through.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Keys,
        [Parameter(Mandatory)][scriptblock]$Done
    )
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($attempt -eq 2) {
            $taskbar = [Vouch.Native]::FindWindow('Shell_TrayWnd', $null)
            if ($taskbar -eq [IntPtr]::Zero) { return $false }
            [Vouch.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # Alt: permits the focus change
            [Vouch.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
            [void][Vouch.Native]::SetForegroundWindow($taskbar)
            Start-Sleep -Milliseconds 400
        }
        Send-KeyChord -Keys ([byte[]]$Keys.Clone())
        Start-Sleep -Milliseconds 1500   # the switch animates
        if (& $Done) { return $true }
    }
    return $false
}

#region Image metadata ----------------------------------------------------------

function New-CaptureMetadata {
    <#
        What each image carries inside itself, so it still says what it is when it is
        separated from the report: which page, when (local with offset, and UTC), which
        run, by whom and where - and what the image shows: the whole screen, the Edge
        window or the page content only (CaptureArea; Screen then describes that image),
        at which page zoom.
    #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$ItemIndex,
        [Parameter(Mandatory)][string]$ItemName,
        [Parameter(Mandatory)][string]$RequestedUrl,
        [AllowEmptyString()][string]$PageUrl = '',
        [Parameter(Mandatory)][System.DateTimeOffset]$CapturedAt,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][int]$SegmentCount,
        [string]$Computer = $env:COMPUTERNAME,
        [string]$User = "$env:USERDOMAIN\$env:USERNAME",
        [string]$Screen = '',
        [ValidateSet('screen', 'window', 'page')][string]$CaptureArea = 'screen',
        [int]$ZoomPercent = 100
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    return [ordered]@{
        Tool          = "vouch.ps1 $($script:ToolVersion)"
        RunId         = $RunId
        ItemIndex     = $ItemIndex
        ItemName      = $ItemName
        RequestedUrl  = $RequestedUrl
        PageUrl       = $PageUrl
        CapturedAt    = $CapturedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $invariant)
        CapturedAtUtc = $CapturedAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant)
        Segment       = "$SegmentIndex of $SegmentCount"
        Computer      = $Computer
        User          = $User
        Screen        = $Screen
        CaptureArea   = $CaptureArea
        ZoomPercent   = $ZoomPercent
    }
}

function New-ExifPropertyItem {
    # PropertyItem has no public constructor; GDI+ only needs the four fields set.
    param([int]$Id, [int16]$Type, [byte[]]$Value)
    $item = [System.Runtime.CompilerServices.RuntimeHelpers]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
    $item.Id = $Id
    $item.Type = $Type
    $item.Len = $Value.Length
    $item.Value = $Value
    return $item
}

function Set-JpegMetadata {
    <#
        Standard EXIF fields - shown by Windows Explorer under Properties > Details and
        by any EXIF viewer - plus the complete metadata as JSON in the XP comment.
        EXIF text fields are ASCII; non-ASCII characters there become '?', the JSON
        comment (UTF-16) keeps them.
    #>
    param(
        [Parameter(Mandatory)][System.Drawing.Image]$Image,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Metadata
    )
    $ascii = { param([string]$Text) [System.Text.Encoding]::ASCII.GetBytes($Text + [char]0) }
    $unicode = { param([string]$Text) [System.Text.Encoding]::Unicode.GetBytes($Text + [char]0) }
    $captured = [System.DateTimeOffset]::Parse($Metadata.CapturedAt, [System.Globalization.CultureInfo]::InvariantCulture)
    $exifTime = $captured.ToString('yyyy:MM:dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $json = $Metadata | ConvertTo-Json -Compress

    $fields = @(
        @(0x010E, 2, (& $ascii "$($Metadata.ItemName) - $($Metadata.PageUrl)")),   # ImageDescription
        @(0x013B, 2, (& $ascii $Metadata.User)),                                     # Artist
        @(0x0131, 2, (& $ascii $Metadata.Tool)),                                     # Software
        @(0x0132, 2, (& $ascii $exifTime)),                                          # DateTime
        @(0x9003, 2, (& $ascii $exifTime)),                                          # DateTimeOriginal
        @(0x9C9B, 1, (& $unicode $Metadata.ItemName)),                               # XPTitle
        @(0x9C9C, 1, (& $unicode $json)),                                            # XPComment
        @(0x9C9E, 1, (& $unicode 'vouch;audit evidence'))                            # XPKeywords
    )
    foreach ($field in $fields) {
        $Image.SetPropertyItem((New-ExifPropertyItem -Id $field[0] -Type $field[1] -Value $field[2]))
    }
}

function Add-PngTextChunks {
    <#
        Inserts iTXt (UTF-8 text) chunks before IEND. Keywords follow the PNG spec's
        predefined ones where they fit; "Vouch" holds the complete metadata as JSON.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Png,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Metadata
    )
    $iendOffset = $Png.Length - 12
    if ($iendOffset -lt 8 -or [System.Text.Encoding]::ASCII.GetString($Png, $iendOffset + 4, 4) -ne 'IEND') {
        throw 'Not a PNG image ending in an IEND chunk.'
    }

    $captured = [System.DateTimeOffset]::Parse($Metadata.CapturedAt, [System.Globalization.CultureInfo]::InvariantCulture)
    $entries = [ordered]@{
        'Title'         = $Metadata.ItemName
        'Description'   = "$($Metadata.ItemName) - $($Metadata.PageUrl)"
        'Author'        = $Metadata.User
        'Software'      = $Metadata.Tool
        'Creation Time' = $captured.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
        'Vouch'         = ($Metadata | ConvertTo-Json -Compress)
    }

    $output = [System.IO.MemoryStream]::new()
    try {
        $output.Write($Png, 0, $iendOffset)
        foreach ($key in $entries.Keys) {
            # keyword NUL, compression flag 0, method 0, empty language NUL, empty translated keyword NUL, text
            $body = [System.Collections.Generic.List[byte]]::new()
            $body.AddRange([System.Text.Encoding]::Latin1.GetBytes($key))
            $body.AddRange([byte[]](0, 0, 0, 0, 0))
            $body.AddRange([System.Text.Encoding]::UTF8.GetBytes([string]$entries[$key]))
            $typeAndData = [byte[]]([System.Text.Encoding]::ASCII.GetBytes('iTXt') + $body.ToArray())
            $length = [System.BitConverter]::GetBytes([uint32]$body.Count)
            $crc = [System.BitConverter]::GetBytes([Vouch.Crc32]::Compute($typeAndData))
            if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($length); [array]::Reverse($crc) }
            $output.Write($length, 0, 4)
            $output.Write($typeAndData, 0, $typeAndData.Length)
            $output.Write($crc, 0, 4)
        }
        $output.Write($Png, $iendOffset, 12)
        return , $output.ToArray()
    }
    finally {
        $output.Dispose()
    }
}

function Get-PngTextChunks {
    # Reads tEXt and uncompressed iTXt chunks into a keyword -> text dictionary.
    param([Parameter(Mandatory)][byte[]]$Png)
    $result = [ordered]@{}
    $offset = 8
    while ($offset + 12 -le $Png.Length) {
        $lengthBytes = $Png[$offset..($offset + 3)]
        if ([System.BitConverter]::IsLittleEndian) { [array]::Reverse($lengthBytes) }
        $length = [System.BitConverter]::ToUInt32([byte[]]$lengthBytes, 0)
        $type = [System.Text.Encoding]::ASCII.GetString($Png, $offset + 4, 4)
        $dataStart = $offset + 8
        if ($type -in 'tEXt', 'iTXt' -and $length -gt 0) {
            $data = [byte[]]$Png[$dataStart..($dataStart + $length - 1)]
            $nul = [array]::IndexOf($data, [byte]0)
            if ($nul -gt 0) {
                $keyword = [System.Text.Encoding]::Latin1.GetString($data, 0, $nul)
                if ($type -eq 'tEXt') {
                    $result[$keyword] = [System.Text.Encoding]::Latin1.GetString($data, $nul + 1, $data.Length - $nul - 1)
                }
                elseif ($data[$nul + 1] -eq 0) {
                    # skip compression flag and method, then the language tag and translated keyword
                    $position = $nul + 3
                    $position = [array]::IndexOf($data, [byte]0, $position) + 1
                    $position = [array]::IndexOf($data, [byte]0, $position) + 1
                    $result[$keyword] = [System.Text.Encoding]::UTF8.GetString($data, $position, $data.Length - $position)
                }
            }
        }
        if ($type -eq 'IEND') { break }
        $offset = $dataStart + $length + 4
    }
    return $result
}

function ConvertFrom-MetadataJson {
    <#
        ConvertFrom-Json turns ISO 8601 strings into DateTime objects (dropping the exact
        text, and before PowerShell 7.5 there is no switch to stop it). Evidence metadata
        must come back exactly as written, so read it with System.Text.Json: strings stay
        strings, numbers keep their text.
    #>
    param([Parameter(Mandatory)][string]$Json)
    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
        $result = [ordered]@{}
        foreach ($property in $document.RootElement.EnumerateObject()) {
            $value = $property.Value
            $result[$property.Name] = switch ($value.ValueKind) {
                'String' { $value.GetString() }
                'Number' { if ($value.TryGetInt64([ref]$null)) { $value.GetInt64() } else { $value.GetDouble() } }
                'True'   { $true }
                'False'  { $false }
                'Null'   { $null }
                default  { $value.GetRawText() }
            }
        }
        return [pscustomobject]$result
    }
    finally {
        $document.Dispose()
    }
}

function Get-ImageMetadata {
    <#
        Returns the metadata a Vouch capture carries (the JSON written at capture time),
        or $null when the image has none.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $isPng = $Bytes.Length -gt 8 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47
    try {
        if ($isPng) {
            $text = Get-PngTextChunks -Png $Bytes
            if ($text.Contains('Vouch')) { return (ConvertFrom-MetadataJson -Json $text['Vouch']) }
            return $null
        }
        $stream = [System.IO.MemoryStream]::new($Bytes)
        try {
            $image = [System.Drawing.Image]::FromStream($stream, $false, $false)
            try {
                if ($image.PropertyIdList -contains 0x9C9C) {
                    $json = [System.Text.Encoding]::Unicode.GetString($image.GetPropertyItem(0x9C9C).Value).TrimEnd([char]0)
                    return (ConvertFrom-MetadataJson -Json $json)
                }
            }
            finally {
                $image.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-Verbose "Could not read image metadata: $($_.Exception.Message)"
    }
    return $null
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

#endregion

function Get-ScreenCapture {
    <#
        Real screen capture of the primary display, so the taskbar clock is included in
        the evidence. Requires an unlocked, visible desktop. With -Metadata the image
        carries it inside (EXIF for JPEG, text chunks for PNG).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('jpeg', 'png')][string]$Format,
        [int]$Quality = 85,
        [System.Collections.IDictionary]$Metadata = $null
    )

    $bitmap = Get-ScreenBitmap
    try {
        $bytes = ConvertTo-EvidenceImage -Bitmap $bitmap -Format $Format -Quality $Quality -Metadata $Metadata
        # The leading comma keeps the byte array intact instead of streaming it out byte by byte.
        return , $bytes
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-ScreenBitmap {
    <#
        The primary display as a bitmap (GDI CopyFromScreen): the raw grab shared by the
        screen and window capture areas. The caller disposes it. Requires an unlocked,
        visible desktop.
    #>
    $bounds = Get-PrimaryScreenBounds
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
        }
        finally {
            $graphics.Dispose()
        }
    }
    catch {
        $bitmap.Dispose()
        throw
    }
    return $bitmap
}

function Get-WindowCapture {
    <#
        Window-only capture: the screen is grabbed exactly as for a screen capture and
        cut down to the Edge window (-Rectangle from Get-WindowCaptureRectangle), so the
        title bar, tabs and address bar are in the evidence and the taskbar and other
        windows are not. Cutting a real screen grab, rather than asking Windows to draw
        the window, keeps what is captured what the person saw.
    #>
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$Rectangle,
        [Parameter(Mandatory)][ValidateSet('jpeg', 'png')][string]$Format,
        [int]$Quality = 85,
        [System.Collections.IDictionary]$Metadata = $null
    )
    $screen = Get-ScreenBitmap
    try {
        $window = $screen.Clone($Rectangle, $screen.PixelFormat)
        try {
            $bytes = ConvertTo-EvidenceImage -Bitmap $window -Format $Format -Quality $Quality -Metadata $Metadata
            return , $bytes
        }
        finally {
            $window.Dispose()
        }
    }
    finally {
        $screen.Dispose()
    }
}

function Get-JpegEncoder {
    # GDI+'s JPEG encoder, or $null on the rare system without one (PNG is used then).
    return [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq 'image/jpeg' } |
        Select-Object -First 1
}

function ConvertTo-EvidenceImage {
    <#
        The one place an image becomes evidence: encoded in the run's format with the
        Vouch metadata inside it (EXIF for JPEG, text chunks for PNG). Every capture
        area goes through here, so the metadata, and with it -Verify, work the same for
        all of them.
        -Bitmap (screen and window captures): encoded here, exactly as screen captures
        always were - the bytes do not change with this split.
        -EncodedImage (page captures): an image the browser already encoded in -Format.
        It is not decoded and encoded again - that would compress a JPEG twice; the
        metadata is added to the file as it is (Add-JpegExifSegment, Add-PngTextChunks).
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Bitmap')][System.Drawing.Bitmap]$Bitmap,
        [Parameter(Mandatory, ParameterSetName = 'Encoded')][byte[]]$EncodedImage,
        [Parameter(Mandatory)][ValidateSet('jpeg', 'png')][string]$Format,
        [int]$Quality = 85,
        [System.Collections.IDictionary]$Metadata = $null
    )

    if ($PSCmdlet.ParameterSetName -eq 'Encoded') {
        if ($Format -eq 'png') {
            if ($null -eq $Metadata) { return , $EncodedImage }
            return , (Add-PngTextChunks -Png $EncodedImage -Metadata $Metadata)
        }
        if ($null -ne (Get-JpegEncoder)) {
            if ($null -eq $Metadata) { return , $EncodedImage }
            return , (Add-JpegExifSegment -Jpeg $EncodedImage -Metadata $Metadata)
        }
        # No JPEG encoder for the metadata: decode and take the bitmap path, which then
        # writes a PNG exactly as a screen capture would on such a system.
        $stream = [System.IO.MemoryStream]::new($EncodedImage)
        try {
            $decoded = [System.Drawing.Bitmap]::new($stream)
            try { return , (ConvertTo-EvidenceImage -Bitmap $decoded -Format $Format -Quality $Quality -Metadata $Metadata) }
            finally { $decoded.Dispose() }
        }
        finally { $stream.Dispose() }
    }

    $stream = [System.IO.MemoryStream]::new()
    try {
        $encoder = $null
        if ($Format -eq 'jpeg') { $encoder = Get-JpegEncoder }
        if ($null -ne $encoder) {
            if ($null -ne $Metadata) { Set-JpegMetadata -Image $Bitmap -Metadata $Metadata }
            $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
            try {
                $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
                $Bitmap.Save($stream, $encoder, $encoderParameters)
            }
            finally {
                $encoderParameters.Dispose()
            }
            return , $stream.ToArray()
        }

        # PNG (asked for, or no JPEG encoder available).
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $stream.ToArray()
        if ($null -ne $Metadata) { $png = Add-PngTextChunks -Png $png -Metadata $Metadata }
        return , $png
    }
    finally {
        $stream.Dispose()
    }
}

function Add-JpegExifSegment {
    <#
        Puts the Vouch EXIF metadata into an already encoded JPEG without re-encoding it.
        GDI+ can only write EXIF while it encodes, so it encodes a 1x1 image carrying the
        metadata (Set-JpegMetadata, the same fields a screen capture gets) and that
        image's APP1 "Exif" segment is copied in after SOI and the JFIF APP0 segment,
        where GDI+ itself puts it. The picture data is untouched.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Jpeg,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Metadata
    )
    if ($Jpeg.Length -lt 4 -or $Jpeg[0] -ne 0xFF -or $Jpeg[1] -ne 0xD8) { throw 'Not a JPEG image.' }

    $carrier = [System.Drawing.Bitmap]::new(1, 1)
    $stream = [System.IO.MemoryStream]::new()
    try {
        Set-JpegMetadata -Image $carrier -Metadata $Metadata
        $carrier.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $source = $stream.ToArray()
    }
    finally {
        $stream.Dispose()
        $carrier.Dispose()
    }

    # Walk the marker segments (FF xx, then a big-endian length that counts itself).
    $exifStart = -1
    $exifLength = 0
    $position = 2
    while ($position + 4 -le $source.Length -and $source[$position] -eq 0xFF) {
        $marker = $source[$position + 1]
        if ($marker -eq 0xDA -or $marker -eq 0xD9) { break }
        $length = $source[$position + 2] * 256 + $source[$position + 3]
        if ($marker -eq 0xE1 -and $position + 10 -le $source.Length -and
            [System.Text.Encoding]::ASCII.GetString($source, $position + 4, 4) -eq 'Exif') {
            $exifStart = $position
            $exifLength = 2 + $length
            break
        }
        $position += 2 + $length
    }
    if ($exifStart -lt 0) { throw 'GDI+ wrote no EXIF segment for the metadata.' }

    $insertAt = 2
    if ($Jpeg[2] -eq 0xFF -and $Jpeg[3] -eq 0xE0 -and $Jpeg.Length -ge 6) {
        $insertAt = 4 + ($Jpeg[4] * 256 + $Jpeg[5])
    }
    $output = [byte[]]::new($Jpeg.Length + $exifLength)
    [System.Array]::Copy($Jpeg, 0, $output, 0, $insertAt)
    [System.Array]::Copy($source, $exifStart, $output, $insertAt, $exifLength)
    [System.Array]::Copy($Jpeg, $insertAt, $output, $insertAt + $exifLength, $Jpeg.Length - $insertAt)
    return , $output
}

function Get-ImagePixelSize {
    # Width and height of an encoded image, read from its header (the pixels are not decoded).
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $stream = [System.IO.MemoryStream]::new($Bytes)
    try {
        $image = [System.Drawing.Image]::FromStream($stream, $false, $false)
        try { return [pscustomobject]@{ Width = $image.Width; Height = $image.Height } }
        finally { $image.Dispose() }
    }
    finally {
        $stream.Dispose()
    }
}

#endregion

#region Progress events, stop and the Vouch dialog -----------------------------

function Write-RunEvent {
    <#
        Appends one progress event to -EventLogPath: one JSON object per line (NDJSON,
        UTF-8 without BOM, LF), so another process - the Designer - can follow the run by
        reading new lines. The file is opened, appended and closed per event: every line
        is on disk for the reader as soon as it is written, and the reader may keep the
        file open (shared read/write access) without blocking the run. Events are a
        convenience: a failure to write one is never a reason to fail the run.
        Without an event log this returns at once.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [AllowNull()][System.Collections.IDictionary]$Data = $null
    )
    $path = $script:EventLogPath
    if ([string]::IsNullOrEmpty($path)) { return }
    try {
        $record = [ordered]@{
            ts    = [System.DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [System.Globalization.CultureInfo]::InvariantCulture)
            type  = $Type
            runId = $script:EventRunId
        }
        # ts, type and runId belong to the envelope; a field of the same name cannot replace them.
        if ($null -ne $Data) {
            foreach ($key in @($Data.Keys)) {
                if ([string]$key -notin 'ts', 'type', 'runId') { $record[[string]$key] = $Data[$key] }
            }
        }
        $line = (ConvertTo-Json -InputObject $record -Compress -Depth 8) + "`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
        # A reader that opens the file without write sharing (File.ReadAllText does)
        # locks it for a moment; a few short retries keep the event - runEnd above all.
        for ($attempt = 1; ; $attempt++) {
            try {
                $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                break
            }
            catch {
                # PowerShell wraps the .NET error; look for the IOException inside.
                $io = $_.Exception
                while ($null -ne $io -and $io -isnot [System.IO.IOException]) { $io = $io.InnerException }
                # 0x80070020 ERROR_SHARING_VIOLATION, 0x80070021 ERROR_LOCK_VIOLATION
                $sharing = $null -ne $io -and ($io.HResult -band 0xFFFF) -in 0x20, 0x21
                if (-not $sharing -or $attempt -ge 4) { throw }
                [System.Threading.Thread]::Sleep(50)
            }
        }
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-Verbose "Could not write the '$Type' event to '$path': $($_.Exception.Message)"
    }
}

function Get-StopFilePath {
    # The file whose existence stops the run: the event log's name plus ".stop".
    if ([string]::IsNullOrEmpty($script:EventLogPath)) { return '' }
    return "$($script:EventLogPath).stop"
}

function Test-StopRequested {
    <#
        Whether the person stopped the run: the Designer (or anyone) creates
        <EventLogPath>.stop. A file is the simplest signal two processes can share with
        nothing to install. Once seen, the stop holds for the rest of the run, even if
        the file is removed again. No event log means no stop, at no cost.
    #>
    if ($script:StopRequested) { return $true }
    $stopFile = Get-StopFilePath
    if (-not $stopFile) { return $false }
    if ([System.IO.File]::Exists($stopFile)) {
        $script:StopRequested = $true
        Write-Host 'Stop requested: finishing the report for what has been captured so far.' -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Wait-Interruptible {
    <#
        Sleeps, but notices a stop within a fifth of a second, so a 60-second wait
        action does not hold up a stopped run. Without an event log no stop can come,
        and it is exactly one Start-Sleep, as before. Returns $false when it was stopped.
    #>
    param([Parameter(Mandatory)][double]$Milliseconds)
    if ([string]::IsNullOrEmpty($script:EventLogPath)) {
        Start-Sleep -Milliseconds ([int][Math]::Max(0, $Milliseconds))
        return $true
    }
    $deadline = (Get-Date).AddMilliseconds([Math]::Max(0, $Milliseconds))
    while ($true) {
        if (Test-StopRequested) { return $false }
        $left = ($deadline - (Get-Date)).TotalMilliseconds
        if ($left -le 0) { return $true }
        Start-Sleep -Milliseconds ([int][Math]::Ceiling([Math]::Min(200, $left)))
    }
}

function Test-InteractiveRun {
    <#
        Whether a person can answer the Vouch dialog. Not with -NoPrompt; not in a
        process without a desktop (UserInteractive is false for a task that runs whether
        or not the user is signed in); and not when pwsh was started with
        -NonInteractive, which is how the scheduled task starts it - that switch is not
        visible to the script any other way, so pwsh's own command line is read, up to
        -File/-Command (what follows belongs to the script). pwsh accepts any
        abbreviation of -NonInteractive from -noni on, with -, -- or /.
        -CommandLineArgs and -UserInteractive replace the real values (for tests).
    #>
    param(
        [bool]$NoPrompt = $false,
        [AllowNull()][string[]]$CommandLineArgs = $null,
        [AllowNull()][object]$UserInteractive = $null
    )
    if ($NoPrompt) { return $false }
    $desktop = if ($null -ne $UserInteractive) { [bool]$UserInteractive } else { [System.Environment]::UserInteractive }
    if (-not $desktop) { return $false }
    if ($null -eq $CommandLineArgs) { $CommandLineArgs = [System.Environment]::GetCommandLineArgs() }
    for ($i = 1; $i -lt $CommandLineArgs.Count; $i++) {
        $argument = [string]$CommandLineArgs[$i]
        if ($argument -notmatch '^(?:--?|/)([A-Za-z]+)(?::.*)?$') {
            # "pwsh script.ps1 ...": the first .ps1 is the script; its arguments follow.
            if ($argument -match '(?i)\.ps1$') { break }
            continue
        }
        $name = $Matches[1].ToLowerInvariant()
        if ($name.StartsWith('noni') -and 'noninteractive'.StartsWith($name)) { return $false }
        if ('file'.StartsWith($name) -or 'command'.StartsWith($name) -or 'encodedcommand'.StartsWith($name) -or
            $name -in 'ec', 'cwa', 'commandwithargs') { break }
    }
    return $true
}

function Request-UserDecision {
    <#
        The one place where the run asks the person something (a pause, a page that is
        not ready, a sign-in). Everything else calls this, so tests replace this one
        function. When nobody can answer ($script:InteractiveRun is false: scheduled,
        -NonInteractive, -NoPrompt), or the run is already stopped, it returns the
        default at once, with no window and no event, and Prompted = $false so the
        caller can say nobody was asked. Otherwise the Vouch
        dialog (Show-ContinueDialog) asks; a dialog that cannot be shown counts as
        nobody there, because a run must never fail or hang over a question.
        Returns { Decision = Continue|Wait|Skip; WaitSeconds; TimedOut; Prompted }.
    #>
    param(
        [ValidateSet('pause', 'notReady', 'signIn')][string]$Kind = 'pause',
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$PageName = '',
        [ValidateSet('Continue', 'Skip')][string]$Default = 'Continue',
        [int]$TimeoutSec = 300,
        [int]$WaitSeconds = 30
    )
    if ($TimeoutSec -le 0) { $TimeoutSec = 300 }
    $unanswered = [pscustomobject]@{ Decision = $Default; WaitSeconds = 0; TimedOut = $false; Prompted = $false }
    # A stopped run asks nothing more: no window, no prompt event (the caller ends the page).
    if (-not $script:InteractiveRun -or (Test-StopRequested)) { return $unanswered }

    Write-RunEvent -Type 'prompt' -Data ([ordered]@{
        pageId = $script:EventPageId; kind = $Kind; title = $Title; message = $Message; pageName = $PageName
        defaultDecision = $Default; timeoutSec = $TimeoutSec })
    Write-Host "    Waiting for you in the Vouch dialog: $Title" -ForegroundColor Cyan
    try {
        $result = Show-ContinueDialog -Title $Title -Message $Message -PageName $PageName -Default $Default `
            -TimeoutSec $TimeoutSec -WaitSeconds $WaitSeconds -StopFile (Get-StopFilePath)
    }
    catch {
        Write-Host "WARNING: the Vouch dialog could not be shown, so the run carries on as if nobody were there: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-RunEvent -Type 'promptResult' -Data ([ordered]@{
            pageId = $script:EventPageId; kind = $Kind; decision = $Default; waitSeconds = 0; timedOut = $false; shown = $false })
        return $unanswered
    }
    $answer = [pscustomobject]@{
        Decision    = [string]$result.Decision
        WaitSeconds = [int]$result.WaitSeconds
        TimedOut    = [bool]$result.TimedOut
        Prompted    = $true
    }
    if ($answer.Decision -notin 'Continue', 'Wait', 'Skip') { $answer.Decision = $Default }
    Write-RunEvent -Type 'promptResult' -Data ([ordered]@{
        pageId = $script:EventPageId; kind = $Kind; decision = $answer.Decision; waitSeconds = $answer.WaitSeconds
        timedOut = $answer.TimedOut; shown = $true })
    return $answer
}

function New-ContinueDialog {
    <#
        Builds the Vouch dialog without showing it, so its logic can be tested without a
        window. The handlers are closures over the dialog's own state, because they run
        later, from the dialog's message loop (or a test), after this function returned.
        They use only .NET, which a closure can always reach.
        The countdown takes the default answer when -TimeoutSec runs out, so a forgotten
        prompt never holds a run forever; the stop file closes it at once.
        Returns { Form; State; Timer; ContinueButton; WaitButton; SkipButton; WaitInput;
        Countdown }; State.Tick is the timer's handler.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$PageName = '',
        [ValidateSet('Continue', 'Skip')][string]$Default = 'Continue',
        [int]$TimeoutSec = 300,
        [int]$WaitSeconds = 30,
        [AllowEmptyString()][string]$StopFile = ''
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ($TimeoutSec -le 0) { $TimeoutSec = 300 }
    $WaitSeconds = [Math]::Min(3600, [Math]::Max(5, $WaitSeconds))

    $state = @{
        Decision = ''; WaitSeconds = $WaitSeconds; TimedOut = $false; Stopped = $false
        Default = $Default; Deadline = [datetime]::Now.AddSeconds($TimeoutSec); StopFile = $StopFile; Tick = $null
    }
    $defaultText = if ($Default -eq 'Skip') { 'skip this page' } else { 'continue' }
    $countdownFormat = "If nobody answers, Vouch will $defaultText in {0}:{1:d2}."

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "Vouch - $Title"
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.AutoSize = $true
    $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.Font = [System.Drawing.SystemFonts]::MessageBoxFont
    $form.Padding = [System.Windows.Forms.Padding]::new(10)

    $layout = [System.Windows.Forms.TableLayoutPanel]::new()
    $layout.AutoSize = $true
    $layout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $layout.ColumnCount = 1
    $newLabel = {
        param([string]$Text, [bool]$Bold = $false)
        $label = [System.Windows.Forms.Label]::new()
        $label.AutoSize = $true
        $label.MaximumSize = [System.Drawing.Size]::new(420, 0)
        $label.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 8)
        $label.Text = $Text
        if ($Bold) { $label.Font = [System.Drawing.Font]::new($form.Font, [System.Drawing.FontStyle]::Bold) }
        return $label
    }
    $layout.Controls.Add((& $newLabel $Title $true))
    if ($PageName) { $layout.Controls.Add((& $newLabel "Page: $PageName")) }
    $layout.Controls.Add((& $newLabel $Message))
    $countdown = & $newLabel ''
    $layout.Controls.Add($countdown)

    $buttons = [System.Windows.Forms.FlowLayoutPanel]::new()
    $buttons.AutoSize = $true
    $buttons.WrapContents = $false
    $continueButton = [System.Windows.Forms.Button]::new()
    $continueButton.Text = 'Continue'
    $continueButton.AutoSize = $true
    $waitInput = [System.Windows.Forms.NumericUpDown]::new()
    $waitInput.Minimum = 5
    $waitInput.Maximum = 3600
    $waitInput.Value = $WaitSeconds
    $waitInput.Width = 60
    $waitInput.Margin = [System.Windows.Forms.Padding]::new(12, 5, 0, 0)
    $waitButton = [System.Windows.Forms.Button]::new()
    $waitButton.Text = "Wait $WaitSeconds s more"
    $waitButton.AutoSize = $true
    $skipButton = [System.Windows.Forms.Button]::new()
    $skipButton.Text = 'Skip this page'
    $skipButton.AutoSize = $true
    $skipButton.Margin = [System.Windows.Forms.Padding]::new(12, 3, 3, 3)
    foreach ($control in $continueButton, $waitInput, $waitButton, $skipButton) { $buttons.Controls.Add($control) }
    $layout.Controls.Add($buttons)
    $form.Controls.Add($layout)
    $form.AcceptButton = $continueButton

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 250

    # Decides only; the window is closed only once it exists. Close() on a form never
    # shown disposes it, and ShowDialog would then fail instead of returning the answer.
    $tick = {
        if ($state.Decision) { return }
        if ($state.StopFile -and [System.IO.File]::Exists($state.StopFile)) {
            $state.Stopped = $true
            $state.Decision = 'Skip'
            if ($form.IsHandleCreated) { $form.Close() }
            return
        }
        $left = [int][Math]::Ceiling(($state.Deadline - [datetime]::Now).TotalSeconds)
        if ($left -le 0) {
            $state.Decision = $state.Default
            $state.TimedOut = $true
            if ($form.IsHandleCreated) { $form.Close() }
            return
        }
        $countdown.Text = $countdownFormat -f [int][Math]::Floor($left / 60), ($left % 60)
    }.GetNewClosure()
    $state.Tick = $tick
    $timer.add_Tick($tick)

    $continueButton.add_Click({ $state.Decision = 'Continue'; $form.Close() }.GetNewClosure())
    $skipButton.add_Click({ $state.Decision = 'Skip'; $form.Close() }.GetNewClosure())
    $waitButton.add_Click({
        $state.WaitSeconds = [int]$waitInput.Value
        $state.Decision = 'Wait'
        $form.Close()
    }.GetNewClosure())
    $waitInput.add_ValueChanged({ $waitButton.Text = "Wait $([int]$waitInput.Value) s more" }.GetNewClosure())
    # Closed with the window's X: the same as letting the countdown run out, without the wait.
    $form.add_FormClosing({ if (-not $state.Decision) { $state.Decision = $state.Default } }.GetNewClosure())
    # Bottom right of the main display, over as little of the page as possible.
    $form.add_Load({
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Location = [System.Drawing.Point]::new($area.Right - $form.Width - 16, $area.Bottom - $form.Height - 16)
    }.GetNewClosure())
    # A pwsh started hidden or minimised gives its first window that style (measured):
    # the dialog would exist but never appear. SW_RESTORE shows it normally, TopMost
    # keeps it above a maximised Edge.
    # The countdown starts first: whatever happens to the window, the prompt must end.
    $form.add_Shown({
        $timer.Start()
        try {
            [void][Vouch.Native]::ShowWindow($form.Handle, 9)   # SW_RESTORE
            $form.Activate()
        }
        catch {
            [System.Diagnostics.Debug]::WriteLine("Vouch dialog: could not restore the window: $($_.Exception.Message)")
        }
        # Decided before it appeared (a stop): close at once.
        if ($state.Decision) { $form.Close() }
    }.GetNewClosure())

    # The first countdown text, without deciding anything before the window exists.
    $initialLeft = [int][Math]::Ceiling(($state.Deadline - [datetime]::Now).TotalSeconds)
    $countdown.Text = $countdownFormat -f [int][Math]::Floor($initialLeft / 60), ($initialLeft % 60)
    return [pscustomobject]@{
        Form = $form; State = $state; Timer = $timer; ContinueButton = $continueButton; WaitButton = $waitButton
        SkipButton = $skipButton; WaitInput = $waitInput; Countdown = $countdown
    }
}

function Show-ContinueDialog {
    <#
        Shows the Vouch dialog (New-ContinueDialog) and waits for the answer. Edge covers
        the screen during a run, and the Designer panel with it, so the question comes
        from a TopMost window of the engine itself; the same window serves a run started
        from a console. The dialog must never be in the evidence: it is closed and
        disposed, Edge is brought back to the front and the screen given a moment to
        repaint before this returns - and every screenshot is taken after it returns.
        Returns { Decision = Continue|Wait|Skip; WaitSeconds; TimedOut }.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$PageName = '',
        [ValidateSet('Continue', 'Skip')][string]$Default = 'Continue',
        [int]$TimeoutSec = 300,
        [int]$WaitSeconds = 30,
        [AllowEmptyString()][string]$StopFile = ''
    )
    $dialog = New-ContinueDialog -Title $Title -Message $Message -PageName $PageName -Default $Default `
        -TimeoutSec $TimeoutSec -WaitSeconds $WaitSeconds -StopFile $StopFile
    try {
        [void]$dialog.Form.ShowDialog()
    }
    finally {
        $dialog.Timer.Stop()
        $dialog.Timer.Dispose()
        $dialog.Form.Dispose()
        [System.Windows.Forms.Application]::DoEvents()
        Restore-EdgeForeground
        # Lets the window manager finish removing the dialog before anything is captured.
        Start-Sleep -Milliseconds 500
    }
    $state = $dialog.State
    $decision = if ($state.Decision) { [string]$state.Decision } else { $Default }
    return [pscustomobject]@{ Decision = $decision; WaitSeconds = [int]$state.WaitSeconds; TimedOut = [bool]$state.TimedOut }
}

function Restore-EdgeForeground {
    <#
        Hands the screen back to Edge after the Vouch dialog. Get-EdgeWindowHandle knows
        the window by its process; a reused Edge (the Designer's way of running) often
        has no known process, and then only its window title - which ends with the page's
        title - can find it. So the page title is read over the open DevTools connection
        and passed on. Without either there is nothing to look for, and the 1-second
        search that could only fail is skipped. Best-effort: a failure costs nothing but
        the hand-back.
    #>
    $title = ''
    if ($null -eq $script:EdgeProcess) {
        if (-not (Test-CdpSocketOpen)) { return }
        try { $title = [string](Invoke-CdpEval -Expression 'document.title' -TimeoutSec 5) }
        catch { Write-Verbose "Could not read the page title: $($_.Exception.Message)" }
        if ([string]::IsNullOrWhiteSpace($title)) { return }
    }
    $handle = Get-EdgeWindowHandle -TimeoutSec 1 -ExpectedTitle $title
    if ($handle -ne [IntPtr]::Zero) { [void][Vouch.Native]::SetForegroundWindow($handle) }
}

#endregion

#region Row execution ---------------------------------------------------------

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    # Whitelist rather than GetInvalidFileNameChars(), so names are predictable and
    # never collide with reserved characters, spaces or Unicode oddities.
    $safe = $Name -replace '[^A-Za-z0-9._-]+', '_'
    $safe = $safe -replace '_+', '_'
    $safe = $safe.Trim('_', '.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'capture' }
    if ($safe.Length -gt 48) { $safe = $safe.Substring(0, 48) }
    return $safe
}

function Test-HttpsUpgrade {
    <#
        http://host/ answered by https://host/ is a different origin, but it is the site
        enforcing TLS, not a login redirect. Only the scheme may change: same host, and
        default ports on both sides.
    #>
    param([string]$RequestedUrl, [string]$FinalUrl)
    try {
        $requested = [Uri]::new($RequestedUrl)
        $final = [Uri]::new($FinalUrl)
    }
    catch {
        return $false
    }
    return $requested.Scheme -eq 'http' -and $final.Scheme -eq 'https' -and
        $requested.IsDefaultPort -and $final.IsDefaultPort -and
        $requested.IdnHost -eq $final.IdnHost
}

function Get-OriginFromUrl {
    param([string]$Url)
    try {
        $uri = [Uri]::new($Url)
        return "$($uri.Scheme)://$($uri.Authority)"
    }
    catch {
        return ''
    }
}

function Test-LoginRedirect {
    <#
        Same-origin counterpart of the cross-origin redirect warning: many applications
        send an expired session to their own /login page. Flags a final URL that differs
        from the requested one and either looks like a sign-in URL (when the requested
        one did not) or shows a password field.
    #>
    param(
        [string]$RequestedUrl,
        [string]$FinalUrl,
        [bool]$HasPasswordField = $false
    )

    try {
        $requested = [Uri]::new($RequestedUrl)
        $final = [Uri]::new($FinalUrl)
    }
    catch {
        return $false
    }

    $requestedPath = ($requested.PathAndQuery + $requested.Fragment).TrimEnd('/')
    $finalPath = ($final.PathAndQuery + $final.Fragment).TrimEnd('/')
    if ($requestedPath -eq $finalPath) { return $false }

    $loginPattern = '(?i)(log-?in|sign-?in|log-?on|/auth(\b|/)|oauth|/sso(\b|/)|saml|openid|/adfs/|/idp/)'
    if ($finalPath -match $loginPattern -and $requestedPath -notmatch $loginPattern) { return $true }
    return $HasPasswordField
}

function Get-FrameDocsScript {
    <#
        Browser-side helpers shared by the click steps and the scroll-area search.
        vouchDocs() lists the page and every frame inside it that can be reached from
        the page - frames from the same site; the browser does not let a page look into
        a frame from another site, so those are listed separately as "blocked" (only
        frames big enough to matter, so tracking pixels and ads do not count).
        vouchVisible() is true when an element is rendered and so is every frame
        around it.
    #>
    return @'
function vouchDocs() {
  var list = [{ doc: document, win: window, frame: null, parent: null }];
  var blocked = [];
  for (var i = 0; i < list.length; i++) {
    var frames = list[i].doc.querySelectorAll('iframe,frame');
    for (var j = 0; j < frames.length; j++) {
      var f = frames[j], d = null;
      try { d = f.contentDocument; } catch (e) { d = null; }
      if (d && d.documentElement) {
        list.push({ doc: d, win: f.contentWindow, frame: f, parent: list[i] });
      } else {
        var r = f.getBoundingClientRect();
        if (r.width >= 50 && r.height >= 50) { blocked.push({ frame: f, parent: list[i] }); }
      }
    }
  }
  return { list: list, blocked: blocked };
}
function vouchVisible(entry, el) {
  var rect = el.getBoundingClientRect();
  var style = entry.win.getComputedStyle(el);
  if (!(rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none')) { return false; }
  for (var e = entry; e.frame; e = e.parent) {
    var fr = e.frame.getBoundingClientRect();
    if (!(fr.width > 0 && fr.height > 0)) { return false; }
  }
  return true;
}
function vouchFrameName(f) {
  return f.getAttribute('src') || f.getAttribute('name') || f.id || 'unnamed frame';
}
'@
}

function Get-ScrollTargetScript {
    <#
        Finds what actually scrolls on the page, for full-page capture. Many web
        applications keep the page itself still and scroll a panel inside it, or show
        their content in a frame; scrolling only the window would capture one screen of
        those and miss the rest.

        -Mode auto (the CSV's ScrollFullPage Y): candidates are the window; every element
        that scrolls vertically; every frame (same site) whose document scrolls -
        including elements inside frames. The one with the largest visible area wins, so
        an ordinary scrolling page keeps using the window. Areas smaller than a quarter
        of the screen are ignored (sidebars, code boxes).
        -Mode page: always the window, even when a panel inside holds more content - the
        person asked for the page as a whole.
        -Mode area: the first element matching -Selector in the page and its same-site
        frames (the order clicks use). A frame element, or the html/body of a frame,
        means that frame's document. When nothing matches or the match does not scroll,
        auto is used instead and "fallback" says why, so the item can say so.

        Other large scrolling areas, and large frames from another site, are reported so
        the item can be flagged: their hidden content is not captured. Areas the page
        captures explicitly in another capture (-ExplicitSelectors) are not reported:
        their content is in the evidence.

        Leaves window.__vouchTarget with measure() -> {view,total,top} and to(y) -> top.
    #>
    param(
        [ValidateSet('auto', 'page', 'area')][string]$Mode = 'auto',
        [AllowEmptyString()][string]$Selector = '',
        [AllowEmptyCollection()][string[]]$ExplicitSelectors = @()
    )
    $modeLiteral = ConvertTo-JsLiteral -Value $Mode
    $selectorLiteral = ConvertTo-JsLiteral -Value $Selector
    $explicitLiteral = '[' + ((@($ExplicitSelectors) | Where-Object { $_ } | ForEach-Object { ConvertTo-JsLiteral -Value $_ }) -join ',') + ']'
    return @"
(function (mode, wanted, explicit) {
$(Get-FrameDocsScript)
  var vw = window.innerWidth, vh = window.innerHeight, viewArea = vw * vh;
  function visibleArea(rect, off) {
    var l = Math.max(0, rect.left + off.x), t = Math.max(0, rect.top + off.y);
    var r = Math.min(vw, rect.right + off.x), b = Math.min(vh, rect.bottom + off.y);
    return Math.max(0, r - l) * Math.max(0, b - t);
  }
  function offsetOf(entry) {
    var x = 0, y = 0;
    for (var e = entry; e && e.frame; e = e.parent) { var r = e.frame.getBoundingClientRect(); x += r.left; y += r.top; }
    return { x: x, y: y };
  }
  function describe(el) {
    var d = el.tagName.toLowerCase();
    if (el.id) { d += '#' + el.id; }
    else if (typeof el.className === 'string' && el.className.trim()) { d += '.' + el.className.trim().split(/\s+/)[0]; }
    return d;
  }
  var docs = vouchDocs();
  var topScroller = document.scrollingElement || document.documentElement;
  function windowCandidate() {
    if (!(topScroller.scrollHeight > vh + 16)) { return null; }
    return { kind: 'window', area: viewArea, desc: 'the page', node: null, entry: docs.list[0] };
  }
  function frameCandidate(entry) {
    var fs = entry.doc.scrollingElement || entry.doc.documentElement;
    if (!(fs && fs.scrollHeight > entry.win.innerHeight + 16)) { return null; }
    return { kind: 'frame', area: visibleArea(entry.frame.getBoundingClientRect(), offsetOf(entry.parent)),
      desc: 'the frame ' + vouchFrameName(entry.frame), node: entry.frame, entry: entry };
  }
  // strict: only overflow auto/scroll/overlay, as the automatic search has always done;
  // an area the person named may also be overflow hidden (it still scrolls by script),
  // but not visible or clip: those cannot be scrolled at all.
  function elementCandidate(el, entry, off, strict) {
    if (el === entry.doc.documentElement || el.clientHeight < 50 || el.scrollHeight <= el.clientHeight + 16) { return null; }
    var oy = entry.win.getComputedStyle(el).overflowY;
    if (strict ? (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') : (oy === 'visible' || oy === 'clip')) { return null; }
    return { kind: 'element', area: visibleArea(el.getBoundingClientRect(), off),
      desc: describe(el) + (entry.frame ? ' in the frame ' + vouchFrameName(entry.frame) : ''), node: el, entry: entry };
  }
  // why: '' (usable), 'invalid' (not a CSS selector), 'notfound', 'crossorigin' (a frame
  // from another site, which the page cannot look into), 'notscrollable'.
  function areaFor(sel) {
    var hit = null;
    for (var i = 0; i < docs.list.length && !hit; i++) {
      var el = null;
      try { el = docs.list[i].doc.querySelector(sel); } catch (e) { return { cand: null, why: 'invalid' }; }
      if (el) { hit = { el: el, entry: docs.list[i] }; }
    }
    if (!hit) { return { cand: null, why: 'notfound' }; }
    var tag = hit.el.tagName.toLowerCase();
    var named = null;
    if (tag === 'iframe' || tag === 'frame') {
      var reachable = false;
      for (var j = 0; j < docs.list.length; j++) {
        if (docs.list[j].frame === hit.el) { reachable = true; named = frameCandidate(docs.list[j]); }
      }
      if (!reachable) { return { cand: null, why: 'crossorigin' }; }
    }
    else if (hit.el === hit.entry.doc.documentElement || hit.el === hit.entry.doc.body) {
      named = hit.entry.frame ? frameCandidate(hit.entry) : windowCandidate();
    }
    else { named = elementCandidate(hit.el, hit.entry, offsetOf(hit.entry), false); }
    return { cand: named, why: named ? '' : 'notscrollable' };
  }

  var candidates = [];
  var win = windowCandidate();
  if (win) { candidates.push(win); }
  docs.list.forEach(function (entry) {
    var off = offsetOf(entry);
    if (entry.frame) { var fc = frameCandidate(entry); if (fc) { candidates.push(fc); } }
    var all = entry.doc.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var c = elementCandidate(all[i], entry, off, true);
      if (c) { candidates.push(c); }
    }
  });

  var usable = candidates.filter(function (c) { return c.area >= viewArea * 0.25; })
    .sort(function (a, b) { return b.area - a.area; });
  var chosen = null, fallback = '';
  if (mode === 'page') { chosen = win; }
  else if (mode === 'area') {
    var wantedArea = areaFor(wanted);
    if (wantedArea.cand) { chosen = wantedArea.cand; } else { fallback = wantedArea.why; }
  }
  if (mode === 'auto' || fallback) { chosen = usable.length > 0 ? usable[0] : null; }

  function related(c, x) {
    if (!x) { return false; }
    if (c.kind === x.kind && c.node === x.node && c.entry === x.entry) { return true; }
    if (x.kind === 'frame' && c.entry === x.entry) { return true; }
    if (c.kind === 'frame' && x.entry === c.entry) { return true; }
    if (c.entry === x.entry && c.node && x.node && (c.node.contains(x.node) || x.node.contains(c.node))) { return true; }
    return false;
  }
  var elsewhere = explicit.map(function (s) { return areaFor(s).cand; }).filter(function (c) { return c; });
  var others = usable.filter(function (c) {
    if (related(c, chosen)) { return false; }
    return !elsewhere.some(function (x) { return related(c, x); });
  }).map(function (c) { return c.desc; });
  var blocked = docs.blocked.filter(function (b) {
    return visibleArea(b.frame.getBoundingClientRect(), offsetOf(b.parent)) >= viewArea * 0.25;
  }).map(function (b) { return vouchFrameName(b.frame); });

  var t = chosen;
  window.__vouchTarget = {
    measure: function () {
      if (!t) { return { view: window.innerHeight, total: window.innerHeight, top: 0 }; }
      if (t.kind === 'window') {
        var s = document.scrollingElement || document.documentElement;
        return { view: window.innerHeight, total: Math.max(document.body ? document.body.scrollHeight : 0, s.scrollHeight), top: window.scrollY };
      }
      if (t.kind === 'frame') {
        var f = t.entry.doc.scrollingElement || t.entry.doc.documentElement;
        return { view: t.entry.win.innerHeight, total: f.scrollHeight, top: t.entry.win.scrollY };
      }
      return { view: t.node.clientHeight, total: t.node.scrollHeight, top: t.node.scrollTop };
    },
    to: function (y) {
      if (!t) { return 0; }
      if (t.kind === 'window') { window.scrollTo(0, y); return window.scrollY; }
      if (t.kind === 'frame') { t.entry.win.scrollTo(0, y); return t.entry.win.scrollY; }
      t.node.scrollTop = y;
      return t.node.scrollTop;
    }
  };
  window.__vouchTarget.to(0);
  var m = window.__vouchTarget.measure();
  return { kind: t ? t.kind : 'none', description: t ? t.desc : '', view: m.view, total: m.total, others: others,
    blockedFrames: blocked, fallback: fallback };
})($modeLiteral, $selectorLiteral, $explicitLiteral)
"@
}

function Get-BlockedFrameNote {
    param([int]$Count)
    if ($Count -le 0) { return '' }
    return " The page also contains $Count frame(s) from another site, which Vouch cannot look inside."
}

function Get-ElementDescriptionScript {
    <#
        Browser-side helper for the find-only scripts: what a person needs to recognise
        an element (tag, id, its visible text, the frame it is in). The Designer's picker
        compares this with the element that was picked, so a recorded step is only kept
        when replaying it would hit the same element.
    #>
    return @'
function vouchDescribe(entry, el, exact) {
  var text = String(el.innerText || el.textContent || el.value || '').replace(/\s+/g, ' ').trim();
  return { found: true, tag: el.tagName.toLowerCase(), id: el.id || '', text: text.substring(0, 200),
    frame: entry.frame ? vouchFrameName(entry.frame) : '', exact: exact, visible: vouchVisible(entry, el) };
}
'@
}

function Get-ClickSelectorScript {
    <#
        The page script behind a click: step: the first element matching the selector,
        looking in the page first and then in its frames (same site only). With
        -FindOnly it clicks nothing and returns the element it would click, so the
        Designer can check a selector before recording it, through the very same search.
        Returns 'OK' / 'NOTFOUND|<blocked frames>', or with -FindOnly an object
        { found; tag; id; text; frame; exact; visible; blocked }.
    #>
    param(
        [Parameter(Mandatory)][string]$Selector,
        [switch]$FindOnly
    )
    $literal = ConvertTo-JsLiteral -Value $Selector
    $findOnlyJs = if ($FindOnly) { 'true' } else { 'false' }
    return @"
(function (sel, findOnly) {
$(Get-FrameDocsScript)
$(Get-ElementDescriptionScript)
  var docs = vouchDocs();
  for (var i = 0; i < docs.list.length; i++) {
    var el = docs.list[i].doc.querySelector(sel);
    if (!el) { continue; }
    if (findOnly) { var found = vouchDescribe(docs.list[i], el, true); found.blocked = docs.blocked.length; return found; }
    if (el.scrollIntoView) { el.scrollIntoView({ block: 'center' }); }
    el.click();
    return 'OK';
  }
  if (findOnly) { return { found: false, hidden: false, blocked: docs.blocked.length }; }
  return 'NOTFOUND|' + docs.blocked.length;
})($literal, $findOnlyJs)
"@
}

function Invoke-ClickSelector {
    <#
        Clicks the first element matching the selector, looking in the page first and
        then in its frames (same site only).
    #>
    param([Parameter(Mandatory)][string]$Selector)

    $outcome = [string](Invoke-CdpEval -Expression (Get-ClickSelectorScript -Selector $Selector))
    if ($outcome -ne 'OK') {
        $blocked = if ($outcome -match '\|(\d+)$') { [int]$Matches[1] } else { 0 }
        throw "No element matched the CSS selector '$Selector'.$(Get-BlockedFrameNote -Count $blocked)"
    }
}

function Get-ClickTextScript {
    <#
        The page script behind a clicktext: step. Only rendered elements are considered:
        hidden duplicates (collapsed mobile menus and the like) come earlier in the DOM
        surprisingly often. An exact match wins; otherwise the partial match with the
        shortest label, i.e. the closest one. A partial match never selects a sign-out
        control unless the wanted text itself says so - clicking "Log out" for "Log"
        would end the audit profile's session. The page is searched first, then its
        frames (same site only).
        With -FindOnly the same search runs but nothing is clicked: it returns the
        element it would click, so the Designer can check that a recorded text resolves
        to the element that was picked.
        Returns 'OK' / 'HIDDEN|<blocked>' / 'NOTFOUND|<blocked>', or with -FindOnly an
        object { found; hidden; tag; id; text; frame; exact; visible; blocked }.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$FindOnly
    )
    $literal = ConvertTo-JsLiteral -Value $Text
    $findOnlyJs = if ($FindOnly) { 'true' } else { 'false' }
    return @"
(function (wanted, findOnly) {
$(Get-FrameDocsScript)
$(Get-ElementDescriptionScript)
  var target = String(wanted).replace(/\s+/g, ' ').trim().toLowerCase();
  var label = function (el) {
    var text = el.innerText || el.textContent || el.value || '';
    return String(text).replace(/\s+/g, ' ').trim().toLowerCase();
  };
  var signOut = /\b(log|sign)\s*-?\s*(out|off)\b/;
  var docs = vouchDocs();
  var hiddenMatch = false;
  var exact = null, exactEntry = null;
  var partial = null, partialEntry = null;
  for (var d = 0; d < docs.list.length && !exact; d++) {
    var entry = docs.list[d];
    var nodes = entry.doc.querySelectorAll(
      'a,button,[role=button],[role=tab],[role=menuitem],input[type=submit],input[type=button]');
    for (var i = 0; i < nodes.length; i++) {
      var text = label(nodes[i]);
      if (text.indexOf(target) === -1) { continue; }
      if (!vouchVisible(entry, nodes[i])) { hiddenMatch = true; continue; }
      if (text === target) { exact = nodes[i]; exactEntry = entry; break; }
      if (signOut.test(text) && !signOut.test(target)) { continue; }
      if (!partial || text.length < label(partial).length) { partial = nodes[i]; partialEntry = entry; }
    }
  }
  var pick = exact || partial;
  if (findOnly) {
    if (!pick) { return { found: false, hidden: hiddenMatch, blocked: docs.blocked.length }; }
    var found = vouchDescribe(exact ? exactEntry : partialEntry, pick, !!exact);
    found.hidden = false;
    found.blocked = docs.blocked.length;
    return found;
  }
  if (!pick) { return (hiddenMatch ? 'HIDDEN' : 'NOTFOUND') + '|' + docs.blocked.length; }
  if (pick.scrollIntoView) { pick.scrollIntoView({ block: 'center' }); }
  pick.click();
  return 'OK';
})($literal, $findOnlyJs)
"@
}

function Invoke-ClickText {
    <#
        Clicks the element whose visible text matches (Get-ClickTextScript has the
        rules) and turns the outcome into a message a person can act on.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $outcome = [string](Invoke-CdpEval -Expression (Get-ClickTextScript -Text $Text))
    $blocked = if ($outcome -match '\|(\d+)$') { [int]$Matches[1] } else { 0 }
    if ($outcome -like 'HIDDEN*') {
        throw "Only hidden elements have the text '$Text'; nothing was clicked.$(Get-BlockedFrameNote -Count $blocked)"
    }
    if ($outcome -ne 'OK') {
        throw "No clickable element with the text '$Text' was found.$(Get-BlockedFrameNote -Count $blocked)"
    }
}

function Wait-PageElement {
    <#
        Waits until an element matching the selector is VISIBLE in the page or in one of
        its frames (same site only) - the same documents a click searches, so "wait for
        #grid, then click #grid tr" behaves the way it reads. Visible, because many
        applications put the element in the page at once and only show it when its data
        has arrived. Polling, like Wait-PageReady: no event pump is needed.
        Returns $true when it appeared, $false on timeout (and at once when the run is
        stopped); throws for a selector the browser cannot read, because waiting would
        never end well.
    #>
    param(
        [Parameter(Mandatory)][string]$Selector,
        [Parameter(Mandatory)][double]$TimeoutSec
    )
    $literal = ConvertTo-JsLiteral -Value $Selector
    $expression = @"
(function (sel) {
$(Get-FrameDocsScript)
  var docs = vouchDocs();
  for (var i = 0; i < docs.list.length; i++) {
    var nodes;
    try { nodes = docs.list[i].doc.querySelectorAll(sel); } catch (e) { return 'INVALID'; }
    for (var j = 0; j < nodes.length; j++) {
      if (vouchVisible(docs.list[i], nodes[j])) { return 'FOUND'; }
    }
  }
  return 'WAITING';
})($literal)
"@
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $state = ''
        try { $state = [string](Invoke-CdpEval -Expression $expression -TimeoutSec 10) }
        catch { Write-Verbose "Element check failed (the page may be loading): $($_.Exception.Message)" }
        if ($state -eq 'FOUND') { return $true }
        if ($state -eq 'INVALID') { throw "'$Selector' is not a CSS selector the browser understands." }
        if ((Get-Date) -ge $deadline -or (Test-StopRequested)) { return $false }
        Start-Sleep -Milliseconds 250
    }
}

function Set-StepNavigationProbe {
    <#
        Marks the page - and every frame in it from the same site - before a click.
        beforeunload fires as soon as a navigation starts, before the server has
        answered, so a click that opens another page (or loads another page inside a
        frame) is detectable even while the old one is still on screen.
    #>
    $expression = @"
(function () {
$(Get-FrameDocsScript)
  vouchDocs().list.forEach(function (entry) {
    entry.win.__vouchMark = 1;
    entry.win.__vouchLeaving = false;
    entry.win.addEventListener('beforeunload', function () { entry.win.__vouchLeaving = true; });
  });
  return true;
})()
"@
    try { [void](Invoke-CdpEval -Expression $expression -TimeoutSec 10) }
    catch { Write-Verbose "Could not set the step navigation probe: $($_.Exception.Message)" }
}

function Wait-StepNavigation {
    <#
        After a click: if it navigated (or started to), wait for the new document to
        finish loading so the screenshot does not show a half-loaded or the old page.
        The same for frames: a click that loads another page inside a frame waits until
        every frame has finished loading. In-page changes (tabs, SPA routes) keep the
        markers and return immediately.
    #>
    param([Parameter(Mandatory)][int]$TimeoutSec)

    $stateExpression = @"
(function () {
$(Get-FrameDocsScript)
  if (typeof window.__vouchMark === 'undefined') { return 'new'; }
  if (window.__vouchLeaving) { return 'leaving'; }
  var list = vouchDocs().list;
  for (var i = 1; i < list.length; i++) {
    var w = list[i].win;
    if (typeof w.__vouchMark === 'undefined' || w.__vouchLeaving || list[i].doc.readyState !== 'complete') { return 'frames'; }
  }
  return 'same';
})()
"@
    $probe = 'same'
    try {
        $probe = [string](Invoke-CdpEval -TimeoutSec 10 -Expression $stateExpression)
    }
    catch {
        # Evaluation can fail while a navigation commits; treat that as navigating.
        $probe = 'new'
    }
    if ($probe -eq 'same') { return }

    if ($probe -eq 'frames') {
        # A frame loaded a new page: wait until every frame document is complete and
        # none is still on its way out.
        $framesReady = @"
(function () {
$(Get-FrameDocsScript)
  var list = vouchDocs().list;
  for (var i = 1; i < list.length; i++) {
    if (list[i].win.__vouchLeaving || list[i].doc.readyState !== 'complete') { return false; }
  }
  return true;
})()
"@
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $ready = $false
            try { $ready = [bool](Invoke-CdpEval -TimeoutSec 10 -Expression $framesReady) }
            catch { Write-Verbose "Frame readiness check failed: $($_.Exception.Message)" }
            if ($ready -or (Test-StopRequested)) { return }
            Start-Sleep -Milliseconds 250
        }
        throw "The click loaded a page inside a frame that did not finish loading within $TimeoutSec seconds."
    }

    if (-not (Wait-PageReady -TimeoutSec $TimeoutSec -SameDocumentGraceSeconds $TimeoutSec)) {
        # A stopped run ends the page anyway; the page is not at fault.
        if (Test-StopRequested) { return }
        throw "The click opened a page that did not finish loading within $TimeoutSec seconds."
    }
}

function Get-DefinitionActionList {
    <#
        The ordered actions of a page. CSV rows and configuration pages both carry
        Actions; a definition built by hand with only Steps (older callers) gets the
        same list the CSV import would give it, so the engine has one path.
    #>
    param([Parameter(Mandatory)][object]$Definition)
    if ($Definition.PSObject.Properties['Actions'] -and $null -ne $Definition.Actions) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($action in $Definition.Actions) { $list.Add($action) }
        return , $list
    }
    $steps = if ($Definition.PSObject.Properties['Steps'] -and $null -ne $Definition.Steps) { @($Definition.Steps) } else { @() }
    return ConvertTo-ActionList -Steps $steps -ScrollFullPage ([bool]$Definition.ScrollFullPage)
}

function Invoke-PageAction {
    <#
        Runs one action of a page. Every action is isolated: a failure is returned in the
        log entry { Text; Ok; Message } and the caller carries on with the next action,
        so one failed capture (a scroll that timed out, a screenshot that could not be
        taken) does not lose the evidence of the captures after it. A failed capture
        makes the page FAILED when it took no image at all, WARNING when it took some.
        -PropagateCaptureError leaves a capture error to the caller instead: the one
        implied final capture of a CSV-style page, which nothing follows, so such a page
        ends exactly as it always has.
        A click waits SettleSeconds, then for any page it opened (Wait-StepNavigation),
        exactly as CSV steps always have.
        -Item, -CaptureContext and friends are needed for capture and pause only.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Action,
        # NavigationTimeoutSec, SettleSeconds (and the scroll settings for a capture).
        [Parameter(Mandatory)][object]$Settings,
        # The text the step log shows; ConvertTo-LegacyStepText when not given.
        [AllowEmptyString()][string]$Text = '',
        [object]$Item = $null,
        [hashtable]$CaptureContext = $null,
        [int]$CaptureNumber = 1,
        [bool]$BrowserErrorPage = $false,
        # Every scroll-area selector the page captures, for Get-ScrollTargetScript.
        [AllowEmptyCollection()][string[]]$ExplicitAreas = @(),
        [switch]$PropagateCaptureError
    )

    if (-not $Text) { $Text = ConvertTo-LegacyStepText -Action $Action }
    $entry = [pscustomobject]@{ Text = $Text; Ok = $true; Message = '' }
    $navigationTimeoutSec = [int]$Settings.NavigationTimeoutSec

    if ($Action['type'] -eq 'capture') {
        # Makes the run's tab the one Edge shows (and renders), for every capture area.
        try { [void](Send-CdpCommand -Method 'Page.bringToFront' -TimeoutSec 10) }
        catch { Write-Verbose "Page.bringToFront failed: $($_.Exception.Message)" }

        $pageTitle = ''
        try { $pageTitle = [string](Invoke-CdpEval -Expression 'document.title' -TimeoutSec 10) }
        catch { Write-Verbose "Could not read the page title: $($_.Exception.Message)" }

        # Page-content captures are taken by the browser itself: the window does not need
        # to be in front, so it is left where the person has it.
        if ((Get-PageCaptureMode -Settings $Settings).Area -ne 'page') {
            $focusWarning = Set-EdgeForeground -ExpectedTitle $pageTitle
            if ($null -ne $focusWarning) {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                if (-not $Item.Details.Contains($focusWarning)) { $Item.Details.Add($focusWarning) }
            }
        }

        $scroll = $Action['scroll']
        $mode = if ($scroll -is [System.Collections.IDictionary] -and $scroll['mode']) { [string]$scroll['mode'] } else { 'none' }
        $selector = if ($scroll -is [System.Collections.IDictionary] -and $scroll['selector']) { [string]$scroll['selector'] } else { '' }
        $as = if ($scroll -is [System.Collections.IDictionary] -and $scroll['as'] -eq 'single') { 'single' } else { 'segments' }
        $label = [string]$Action['label']
        $imagesBefore = $Item.Captures.Count
        try {
            Invoke-ScrollCapture -Item $Item -ScrollMode $mode -ScrollSelector $selector -ScrollAs $as -ExplicitAreas $ExplicitAreas `
                -CaptureNumber $CaptureNumber -Label $label -BrowserErrorPage $BrowserErrorPage `
                -Settings $Settings -CaptureContext $CaptureContext -PageTitle $pageTitle
        }
        catch {
            if ($PropagateCaptureError) { throw }
            $taken = $Item.Captures.Count - $imagesBefore
            $which = if ($label) { "Capture $CaptureNumber ($label)" } else { "Capture $CaptureNumber" }
            if ($taken -eq 0) {
                $Item.Status = 'FAILED'
                $Item.Details.Add("$which failed and took no screenshot: $($_.Exception.Message)")
            }
            else {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                $Item.Details.Add("$which stopped after $taken screenshot(s); the rest of it is missing: $($_.Exception.Message)")
            }
            $entry.Ok = $false
            $entry.Message = $_.Exception.Message
            # Leave the area at its top for the actions and captures that follow.
            try { [void](Invoke-CdpEval -Expression 'window.__vouchTarget && window.__vouchTarget.to(0)' -TimeoutSec 10) }
            catch { Write-Verbose "Could not scroll back to the top: $($_.Exception.Message)" }
        }
        return $entry
    }

    try {
        switch ($Action['type']) {
            'click' {
                Set-StepNavigationProbe
                Invoke-ClickSelector -Selector ([string]$Action['selector'])
                [void](Wait-Interruptible -Milliseconds ([int]($Settings.SettleSeconds * 1000)))
                Wait-StepNavigation -TimeoutSec $navigationTimeoutSec
            }
            'clickText' {
                Set-StepNavigationProbe
                Invoke-ClickText -Text ([string]$Action['text'])
                [void](Wait-Interruptible -Milliseconds ([int]($Settings.SettleSeconds * 1000)))
                Wait-StepNavigation -TimeoutSec $navigationTimeoutSec
            }
            'wait' {
                [void](Wait-Interruptible -Milliseconds ([int]([double]$Action['seconds'] * 1000)))
            }
            'waitFor' {
                $timeout = if ($Action.Contains('timeoutSec') -and $null -ne $Action['timeoutSec']) { [double]$Action['timeoutSec'] } else { $navigationTimeoutSec }
                $selector = [string]$Action['selector']
                if (-not (Wait-PageElement -Selector $selector -TimeoutSec $timeout)) {
                    if (Test-StopRequested) { throw 'Stopped by the user before the element showed.' }
                    # Invariant: "1.5 second(s)", not "1,5" on a German PC.
                    $seconds = ([double]$timeout).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                    throw "No visible element matched '$selector' within $seconds second(s); the next actions ran anyway."
                }
            }
            'pause' {
                Invoke-PauseAction -Action $Action -Settings $Settings -Text $Text -Item $Item -Entry $entry
            }
            default {
                throw "Unknown action '$($Action['type'])'."
            }
        }
    }
    catch {
        $entry.Ok = $false
        $entry.Message = $_.Exception.Message
    }
    return $entry
}

function Invoke-PauseAction {
    <#
        A "pause" action: the run waits until the person has done something in the Edge
        window (an MFA prompt, choosing a view) and says so in the Vouch dialog.
        Request-UserDecision alone knows whether anyone can answer. When nobody can (a
        scheduled run, -NoPrompt), the pause is passed over at once with a warning:
        waiting for an answer that never comes would only delay the evidence.
        Wait waits (a stop still ends it) and asks again. Skip ends the page: the log
        entry gets EndPage, and the screenshots already taken are kept. When the dialog
        times out its default is Continue - the page was meant to carry on after the
        pause - and the item says nobody answered.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Action,
        [Parameter(Mandatory)][object]$Settings,
        [AllowEmptyString()][string]$Text = '',
        [object]$Item = $null,
        [Parameter(Mandatory)][object]$Entry
    )
    $message = [string]$Action['message']
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'Vouch has paused so you can do something in the Edge window first, for example sign in or open the right view. Click Continue when the page is ready.'
    }
    $pageName = if ($null -ne $Item) { [string]$Item.Name } else { '' }
    $policy = Get-NotReadyPolicy -Settings $Settings
    $addDetail = {
        param([string]$Line)
        if ($null -eq $Item) { return }
        if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
        $Item.Details.Add($Line)
    }

    while ($true) {
        $answer = Request-UserDecision -Kind 'pause' -Title 'Vouch is paused' -Message $message -PageName $pageName `
            -Default 'Continue' -TimeoutSec $policy.PromptTimeoutSec
        $stopped = Test-StopRequested
        if (-not $stopped -and -not $answer.Prompted) {
            $Entry.Message = 'skipped: nobody was there to answer'
            & $addDetail "The pause ($Text) was skipped because nobody was there to answer it (an unattended run, or -NoPrompt); the actions after it ran straight away."
            return
        }
        # A stop during the extra wait ends the pause here: asking again would only
        # put a question on screen for a run that is already ending.
        if (-not $stopped -and $answer.Decision -eq 'Wait' -and
            (Wait-Interruptible -Milliseconds ([Math]::Max(1, [int]$answer.WaitSeconds) * 1000))) {
            continue
        }
        if ($stopped -or (Test-StopRequested)) {
            $Entry.Message = 'stopped by the user'
            if ($null -ne $Item) { Add-StopDetail -Item $Item }
            return
        }
        if ($answer.Decision -eq 'Skip') {
            $taken = if ($null -ne $Item) { $Item.Captures.Count } else { 0 }
            $kept = if ($taken -gt 0) { " The $taken screenshot(s) taken before it are kept." } else { ' No screenshot of it had been taken yet.' }
            $Entry.Message = 'the user skipped the rest of the page'
            $Entry | Add-Member -NotePropertyName EndPage -NotePropertyValue $true
            & $addDetail "Skipped by the user at the pause ($Text): the rest of this page was not run.$kept"
            return
        }
        if ($answer.TimedOut) {
            $Entry.Message = "continued: nobody answered within $($policy.PromptTimeoutSec) seconds"
            & $addDetail "Nobody answered the pause ($Text) within $($policy.PromptTimeoutSec) seconds, so Vouch carried on without it."
        }
        else {
            $Entry.Message = 'continued by the user'
        }
        return
    }
}

function Get-NotReadyPolicy {
    <#
        What a page does when it is not ready or asks for a sign-in (onNotReady: warn or
        prompt) and how long the Vouch dialog waits for an answer. Settings built
        without the page-level values (the single-page callers and the tests) mean what
        a run without a configuration file always meant: warn, 300 seconds.
    #>
    param([Parameter(Mandatory)][object]$Settings)
    $onNotReady = 'warn'
    if ($Settings.PSObject.Properties['OnNotReady'] -and [string]$Settings.OnNotReady -eq 'prompt') { $onNotReady = 'prompt' }
    $timeoutSec = 300
    if ($Settings.PSObject.Properties['PromptTimeoutSec'] -and [int]$Settings.PromptTimeoutSec -gt 0) { $timeoutSec = [int]$Settings.PromptTimeoutSec }
    return [pscustomobject]@{ OnNotReady = $onNotReady; PromptTimeoutSec = $timeoutSec }
}

function Resolve-PageNotReady {
    <#
        A page that did not finish loading, or did not show its wait-for element, in
        time. With onNotReady "warn", or when nobody can answer, the page is captured as
        it is with today's warning. With "prompt" the person decides in the Vouch dialog:
        Wait runs -Recheck again for the extra seconds (it returns as soon as the page is
        ready) and asks again if it is still not; Continue captures it as it is, with a
        warning; Skip ends the page. -Recheck takes the seconds to wait and returns
        $true once the page is ready.
        Returns 'ready', 'continued', 'skipped' or 'stopped'.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][scriptblock]$Recheck,
        # What did not happen, e.g. "finish loading" or "show '#grid'".
        [Parameter(Mandatory)][string]$Awaited,
        [Parameter(Mandatory)][int]$WaitedSec,
        [Parameter(Mandatory)][object]$Policy
    )
    $warn = {
        param([string]$Line)
        if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
        $Item.Details.Add($Line)
    }
    $waited = $WaitedSec
    if ($Policy.OnNotReady -ne 'prompt') {
        & $warn "The page did not $Awaited within $waited seconds; it was captured in whatever state it had reached."
        return 'continued'
    }

    while ($true) {
        $message = "The page did not $Awaited within $waited seconds. If it needs something from you (for example a sign-in, " +
            'a confirmation or a choice), do that in the Edge window first. Then choose Wait to give it more time, ' +
            'Continue to capture it as it is now, or Skip this page.'
        $answer = Request-UserDecision -Kind 'notReady' -Title 'The page is not ready' -Message $message -PageName ([string]$Item.Name) `
            -Default 'Continue' -TimeoutSec $Policy.PromptTimeoutSec
        if (Test-StopRequested) { return 'stopped' }
        if (-not $answer.Prompted) {
            & $warn "The page did not $Awaited within $waited seconds; it was captured in whatever state it had reached."
            return 'continued'
        }
        if ($answer.Decision -eq 'Wait') {
            $extra = [Math]::Max(1, [int]$answer.WaitSeconds)
            $ready = [bool](& $Recheck $extra)
            $waited += $extra
            if (Test-StopRequested) { return 'stopped' }
            if ($ready) { return 'ready' }
            continue
        }
        if ($answer.Decision -eq 'Skip') {
            & $warn "Skipped by the user: the page did not $Awaited within $waited seconds, so it was not captured."
            return 'skipped'
        }
        if ($answer.TimedOut) {
            & $warn "The page did not $Awaited within $waited seconds and nobody answered the Vouch dialog within $($Policy.PromptTimeoutSec) seconds; it was captured in whatever state it had reached."
        }
        else {
            & $warn "The page did not $Awaited within $waited seconds; it was captured as it was, as chosen in the Vouch dialog."
        }
        return 'continued'
    }
}

function Get-SignInDetail {
    <#
        Whether the page the browser ended up on looks like a sign-in page instead of the
        one requested, as the detail text the item gets, or '' when it does not. Two
        signs: a redirect to another site (not just http -> https), or - on the same
        site - a sign-in URL or a visible password field (Test-LoginRedirect). Read
        again after a sign-in prompt, so both visits are judged the same way.
    #>
    param(
        [Parameter(Mandatory)][string]$RequestedUrl,
        [AllowEmptyString()][string]$FinalUrl = '',
        [bool]$BrowserErrorPage = $false
    )
    $requestedOrigin = Get-OriginFromUrl -Url $RequestedUrl
    $finalOrigin = Get-OriginFromUrl -Url $FinalUrl
    if (-not [string]::IsNullOrWhiteSpace($finalOrigin) -and
        -not [string]::IsNullOrWhiteSpace($requestedOrigin) -and
        $finalOrigin -ne $requestedOrigin -and
        -not (Test-HttpsUpgrade -RequestedUrl $RequestedUrl -FinalUrl $FinalUrl)) {
        return "Redirected to $finalOrigin - possible login required."
    }
    if ($BrowserErrorPage -or [string]::IsNullOrWhiteSpace($FinalUrl)) { return '' }
    $hasPasswordField = $false
    try {
        $hasPasswordField = [bool](Invoke-CdpEval -TimeoutSec 10 -Expression (
            "Array.prototype.some.call(document.querySelectorAll('input[type=password]'), " +
            "function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; })"))
    }
    catch {
        Write-Verbose "Could not look for a password field: $($_.Exception.Message)"
    }
    if (Test-LoginRedirect -RequestedUrl $RequestedUrl -FinalUrl $FinalUrl -HasPasswordField $hasPasswordField) {
        return "Redirected to a sign-in page ($(([Uri]$FinalUrl).AbsolutePath)) - the session has probably expired. Run -LoginSetup."
    }
    return ''
}

function Add-StopDetail {
    <#
        The page that was running when the person stopped the run: a WARNING (the page
        did nothing wrong, but its evidence is incomplete), said once.
    #>
    param([Parameter(Mandatory)][object]$Item)
    $line = 'Stopped by the user: the run ended here, so the rest of this page was not captured.'
    if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
    if (-not $Item.Details.Contains($line)) { $Item.Details.Add($line) }
}

function Add-StepFailureDetail {
    <#
        Keeps one "Completed with errors" line per page, written where the first failure
        is noticed (before the next capture's own details, as it always was for CSV
        rows) and brought up to date when later actions fail too: one page, one line.
        Returns the line's position in Details (-1 while nothing failed).
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][int]$Failed,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$Position
    )
    if ($Failed -le 0) { return $Position }
    if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
    $line = "Completed with errors: $Failed of $Total step(s) failed."
    if ($Position -lt 0) {
        $Item.Details.Add($line)
        return $Item.Details.Count - 1
    }
    $Item.Details[$Position] = $line
    return $Position
}

function Get-CaptureFileName {
    <#
        The file name of one screenshot: 001_Name_seg01.jpg. A page's first capture keeps
        exactly the names Vouch has always used, so SHA256SUMS files and workpapers that
        cite them stay valid; the second and later captures of a page add _c02, _c03 ...
        so every name is unique and sorts in the order the captures were taken.
    #>
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][string]$Extension,
        [int]$CaptureNumber = 1
    )
    $capturePart = if ($CaptureNumber -gt 1) { '_c{0:d2}' -f $CaptureNumber } else { '' }
    return '{0:d3}_{1}{2}_seg{3:d2}.{4}' -f $Index, (Get-SafeFileName -Name $Name), $capturePart, $SegmentIndex, $Extension
}

function New-CaptureRecord {
    <#
        The record of one screenshot. CaptureNumber and Label say which capture action
        of the page took it (1 and '' for a page with one unlabelled capture), so the
        report and the JSON summary can keep a page's capture sets apart.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        # Empty when the browser would not report its URL; the screenshot still counts.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Url,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][int]$SegmentCount,
        [string]$FilePath = '',
        [string]$FileName = '',
        [System.Nullable[System.DateTimeOffset]]$CapturedAt = $null,
        [int]$CaptureNumber = 1,
        [AllowEmptyString()][string]$Label = '',
        # What the image shows (screen, window, page) and at which page zoom.
        [ValidateSet('screen', 'window', 'page')][string]$CaptureArea = 'screen',
        [int]$ZoomPercent = 100
    )

    # PowerShell hands a Nullable parameter over already unwrapped.
    $when = if ($null -ne $CapturedAt) { [System.DateTimeOffset]$CapturedAt } else { [System.DateTimeOffset]::Now }
    return [pscustomobject]@{
        Timestamp     = $when.ToString('yyyy-MM-dd HH:mm:ss')
        CapturedAt    = $when.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [System.Globalization.CultureInfo]::InvariantCulture)
        Url           = $Url
        SegmentIndex  = $SegmentIndex
        SegmentCount  = $SegmentCount
        Base64        = [Convert]::ToBase64String($Bytes)
        Bytes         = $Bytes.Length
        Sha256        = Get-Sha256Hex -Bytes $Bytes
        FileName      = $FileName
        FilePath      = $FilePath
        CaptureNumber = $CaptureNumber
        Label         = $Label
        CaptureArea   = $CaptureArea
        ZoomPercent   = $ZoomPercent
    }
}

function Add-ItemCapture {
    <#
        One screenshot for an item: stamp the metadata, capture, save (with -SaveImages)
        and record the SHA-256 of the exact bytes that went into the report and the file.
        -CaptureArea picks what is captured: the whole screen (Get-ScreenCapture, as
        always), the Edge window cut out of a screen grab, or the page content taken by
        the browser (-PageClip for one tall image of the document). When the window
        cannot be found on the primary display, the whole screen is captured instead
        and the item says so: a screenshot of something is better evidence than none,
        and the record names the area the image really shows.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][int]$SegmentCount,
        [AllowEmptyString()][string]$PageUrl = '',
        [Parameter(Mandatory)][hashtable]$Context,
        # Which capture action of the page this is (Get-CaptureFileName), and its label.
        [int]$CaptureNumber = 1,
        [AllowEmptyString()][string]$Label = '',
        [ValidateSet('screen', 'window', 'page')][string]$CaptureArea = 'screen',
        # The zoom the page is shown at (Set-PageZoom); page captures are scaled by it.
        [int]$ZoomPercent = 100,
        # Page captures only: the part of the document for one tall image.
        [System.Collections.IDictionary]$PageClip = $null,
        # The page's title, to find a window that is not known by its process.
        [AllowEmptyString()][string]$PageTitle = ''
    )

    $fileName = Get-CaptureFileName -Index $Item.Index -Name $Item.Name -SegmentIndex $SegmentIndex `
        -Extension $Context.Extension -CaptureNumber $CaptureNumber
    $area = $CaptureArea
    $screenText = [string]$Context.Screen
    $windowRectangle = $null
    if ($area -eq 'window') {
        $screenBounds = Get-PrimaryScreenBounds
        # Set-EdgeForeground has just looked for the window for up to 10 s; a short
        # look is enough, and keeps a run without a window from waiting per segment.
        $windowBounds = Get-EdgeWindowBounds -ExpectedTitle $PageTitle -TimeoutSec 2
        if ($null -ne $windowBounds) {
            $windowRectangle = Get-WindowCaptureRectangle -WindowBounds $windowBounds -ScreenBounds $screenBounds
        }
        if ($null -eq $windowRectangle) {
            $area = 'screen'
            $fallback = 'The Edge window could not be found on the main display, so the whole screen was captured instead of the window only.'
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            if (-not $Item.Details.Contains($fallback)) { $Item.Details.Add($fallback) }
        }
        else {
            $screenText = '{0}x{1} Edge window at ({2},{3}) of the {4}x{5} primary display' -f $windowRectangle.Width, $windowRectangle.Height,
                ($windowRectangle.X + $screenBounds.X), ($windowRectangle.Y + $screenBounds.Y), $screenBounds.Width, $screenBounds.Height
            $partial = Get-PartialWindowDetail -WindowBounds $windowBounds -Visible $windowRectangle
            if ($partial) {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                if (-not $Item.Details.Contains($partial)) { $Item.Details.Add($partial) }
            }
        }
    }

    $capturedAt = [System.DateTimeOffset]::Now
    $metadataArguments = @{
        RunId = $Context.RunId; ItemIndex = $Item.Index; ItemName = $Item.Name; RequestedUrl = $Item.Url; PageUrl = $PageUrl
        CapturedAt = $capturedAt; SegmentIndex = $SegmentIndex; SegmentCount = $SegmentCount; CaptureArea = $area; ZoomPercent = $ZoomPercent
    }
    if ($area -eq 'page') {
        $encoded = Get-PageCapture -Format $Context.Format -Quality $Context.Quality -ZoomPercent $ZoomPercent -Clip $PageClip
        if ($script:PageZoomPercent -ne $ZoomPercent) {
            # The connection was restored during the capture and the zoom changed with it
            # (Restore-CdpConnection): the image was scaled for a zoom the page no longer
            # shows, so take it again at the zoom it has now.
            $ZoomPercent = $script:PageZoomPercent
            $metadataArguments.ZoomPercent = $ZoomPercent
            $capturedAt = [System.DateTimeOffset]::Now
            $metadataArguments.CapturedAt = $capturedAt
            $encoded = Get-PageCapture -Format $Context.Format -Quality $Context.Quality -ZoomPercent $ZoomPercent -Clip $PageClip
        }
        # The image is not a screen: say what it is, at the size it came back.
        $size = Get-ImagePixelSize -Bytes $encoded
        $screenText = "$($size.Width)x$($size.Height) image of the page content only (no browser window, taskbar or clock)"
        $metadata = New-CaptureMetadata @metadataArguments -Screen $screenText
        $bytes = ConvertTo-EvidenceImage -EncodedImage $encoded -Format $Context.Format -Quality $Context.Quality -Metadata $metadata
    }
    elseif ($area -eq 'window') {
        $metadata = New-CaptureMetadata @metadataArguments -Screen $screenText
        $bytes = Get-WindowCapture -Rectangle $windowRectangle -Format $Context.Format -Quality $Context.Quality -Metadata $metadata
    }
    else {
        $metadata = New-CaptureMetadata @metadataArguments -Screen $screenText
        $bytes = Get-ScreenCapture -Format $Context.Format -Quality $Context.Quality -Metadata $metadata
    }

    $filePath = ''
    if ($Context.SaveImages) {
        $filePath = Join-Path -Path $Context.ImagesDir -ChildPath $fileName
        [System.IO.File]::WriteAllBytes($filePath, $bytes)
    }
    $Item.Captures.Add((New-CaptureRecord -Bytes $bytes -Url $PageUrl -SegmentIndex $SegmentIndex -SegmentCount $SegmentCount `
        -FilePath $filePath -FileName $fileName -CapturedAt $capturedAt -CaptureNumber $CaptureNumber -Label $Label `
        -CaptureArea $area -ZoomPercent $ZoomPercent))
    Write-RunEvent -Type 'capture' -Data ([ordered]@{
        pageId = $script:EventPageId; pageIndex = $Item.Index; captureNumber = $CaptureNumber; label = $Label
        segment = $SegmentIndex; segmentCount = $SegmentCount; fileName = $fileName; area = $area; zoomPercent = $ZoomPercent
        url = $PageUrl; capturedAt = $Item.Captures[$Item.Captures.Count - 1].CapturedAt })
}

function Get-PartialWindowDetail {
    <#
        The detail for an Edge window that is only partly on the main display (moved
        half off it, or spread over two monitors): the image shows only the part on the
        main display. Up to 8 px a side is ignored - GetWindowRect, the fallback when
        DWM cannot answer, counts invisible borders that stick out that far on a
        maximised window. '' when the window is (all but) entirely visible. Pure.
    #>
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$WindowBounds,
        [Parameter(Mandatory)][System.Drawing.Rectangle]$Visible
    )
    if ($WindowBounds.Width - $Visible.Width -le 16 -and $WindowBounds.Height - $Visible.Height -le 16) { return '' }
    return 'Part of the Edge window is outside the main display, so the images show only the part on it ({0}x{1} of the {2}x{3} window).' -f
        $Visible.Width, $Visible.Height, $WindowBounds.Width, $WindowBounds.Height
}

function Get-CaptureManifest {
    <#
        "<sha256>  <file name>" per screenshot, in sha256sum format: the same text is
        saved as SHA256SUMS next to the images (sha256sum -c works on it) and its own
        SHA-256 is the run's manifest hash - one value that covers every image.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)
    $lines = foreach ($item in $Items) {
        foreach ($capture in $item.Captures) { "$($capture.Sha256)  $($capture.FileName)" }
    }
    return (@($lines) -join "`n") + "`n"
}

function Get-CurrentPageUrl {
    try {
        $url = Invoke-CdpEval -Expression 'window.location.href' -TimeoutSec 10
        if ($null -eq $url) { return '' }
        return [string]$url
    }
    catch {
        return ''
    }
}

#endregion

#region HTML report -----------------------------------------------------------

function Encode-Html {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
        Justification = 'Local HTML-escaping helper, never exported as a command.')]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $encoded = $Text
    $encoded = $encoded.Replace('&', '&amp;')   # must run first
    $encoded = $encoded.Replace('<', '&lt;')
    $encoded = $encoded.Replace('>', '&gt;')
    $encoded = $encoded.Replace('"', '&quot;')
    $encoded = $encoded.Replace("'", '&#39;')
    return $encoded
}

function Get-StatusCssClass {
    param([string]$Status)
    switch ($Status) {
        'OK'      { return 'badge ok' }
        'WARNING' { return 'badge warn' }
        default   { return 'badge fail' }
    }
}

function Get-CaptureAreaText {
    <#
        The report's one-line description of what a page's images show. It is read from
        the capture records - what each image really got - not from the page's settings:
        a window capture that fell back to the full screen, or a zoom that could not be
        applied, must not be described as asked for. Mixed results are counted. The
        settings (-Area, -ZoomPercent) only describe a page without images, as such.
        A page-content image has no address bar or clock, so the line says where the
        URL and the capture time are instead.
    #>
    param(
        [AllowEmptyString()][string]$Area = 'screen',
        [int]$ZoomPercent = 100,
        [AllowNull()][object[]]$Captures = @()
    )
    $long = @{
        screen = 'Full screen, including the taskbar clock'
        window = 'Edge window only (title bar, tabs and address bar; no taskbar or clock)'
        page   = 'Page content only (no address bar, taskbar or clock; the URL and capture time are under each image and inside each image file)'
    }
    $short = @{ screen = 'the full screen'; window = 'the Edge window only'; page = 'the page content only' }
    if ($Area -notin 'screen', 'window', 'page') { $Area = 'screen' }

    $images = @($Captures | Where-Object { $null -ne $_ })
    if ($images.Count -eq 0) {
        $text = "$($long[$Area]) - as set; no image was taken"
        if ($ZoomPercent -gt 0 -and $ZoomPercent -ne 100) { $text += "; page zoom $ZoomPercent% as set" }
        return $text
    }

    $total = $images.Count
    $areaOf = { param($c) if ($c.PSObject.Properties['CaptureArea'] -and [string]$c.CaptureArea -in 'screen', 'window', 'page') { [string]$c.CaptureArea } else { 'screen' } }
    $zoomOf = { param($c) if ($c.PSObject.Properties['ZoomPercent'] -and [int]$c.ZoomPercent -gt 0) { [int]$c.ZoomPercent } else { 100 } }
    $areas = @($images | ForEach-Object { & $areaOf $_ } | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name)
    # The line leads with the area that was asked for when any image has it.
    $main = if (@($areas.Name) -contains $Area) { $Area } else { [string]$areas[0].Name }
    $text = $long[$main]
    foreach ($group in $areas) {
        if ($group.Name -eq $main) { continue }
        $text += "; $($group.Count) of $total image(s) fell back to $($short[$group.Name])"
    }
    if ($main -ne $Area) { $text += " ($($short[$Area]) was asked for)" }

    $zooms = @($images | ForEach-Object { & $zoomOf $_ } | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name)
    if ($zooms.Count -eq 1) {
        if ([int]$zooms[0].Name -ne 100) { $text += "; page zoom $($zooms[0].Name)%" }
    }
    else {
        $text += '; page zoom ' + (($zooms | ForEach-Object { "$($_.Name)% for $($_.Count) of $total image(s)" }) -join ', ')
    }
    return $text
}

function New-HtmlReport {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][object]$Run
    )

    $mimeType = if ($Run.ImageFormat -eq 'png') { 'image/png' } else { 'image/jpeg' }
    $runId = if ($Run.PSObject.Properties['RunId']) { [string]$Run.RunId } else { '' }
    $manifestHash = if ($Run.PSObject.Properties['ManifestSha256']) { [string]$Run.ManifestSha256 } else { '' }

    $css = @'
:root { color-scheme: light; }
* { box-sizing: border-box; }
body {
  font-family: "Segoe UI", -apple-system, BlinkMacSystemFont, Roboto, "Helvetica Neue", Arial, sans-serif;
  font-size: 14px; line-height: 1.45; color: #1b1f24; background: #ffffff;
  margin: 0; padding: 28px 32px 64px 32px;
}
h1 { font-size: 22px; margin: 0 0 4px 0; }
h2 { font-size: 17px; margin: 0 0 10px 0; }
h3 { font-size: 15px; margin: 22px 0 8px 0; color: #3a4149; }
.subtitle { color: #5a6570; margin: 0 0 22px 0; }
.meta { border: 1px solid #d5dbe1; border-radius: 4px; margin-bottom: 26px; }
.meta table { border-collapse: collapse; width: 100%; }
.meta td { padding: 6px 12px; border-bottom: 1px solid #eceff2; vertical-align: top; }
.meta tr:last-child td { border-bottom: none; }
.meta td.k { width: 210px; color: #5a6570; font-weight: 600; background: #f7f9fa; }
table.summary { border-collapse: collapse; width: 100%; margin-bottom: 12px; }
table.summary th, table.summary td { border: 1px solid #d5dbe1; padding: 7px 10px; text-align: left; vertical-align: top; }
table.summary th { background: #f0f3f5; font-weight: 600; }
table.summary tr:nth-child(even) td { background: #fbfcfd; }
.badge { display: inline-block; padding: 2px 9px; border-radius: 10px; font-size: 12px; font-weight: 700; letter-spacing: .3px; white-space: nowrap; }
.badge.ok { background: #e3f5e6; color: #1c6b2c; border: 1px solid #9fd6ab; }
.badge.warn { background: #fdf2d9; color: #8a5a00; border: 1px solid #e8c477; }
.badge.fail { background: #fbe3e3; color: #9b1c1c; border: 1px solid #e0a0a0; }
.counts { margin: 0 0 22px 0; color: #3a4149; }
.counts span { margin-right: 18px; }
.item { border-top: 3px solid #1b1f24; padding-top: 14px; margin-top: 34px; page-break-before: always; break-before: page; }
.item:first-of-type { page-break-before: auto; break-before: auto; }
.item-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
.item dl { display: grid; grid-template-columns: 150px 1fr; gap: 4px 14px; margin: 10px 0 14px 0; }
.item dt { color: #5a6570; font-weight: 600; }
.item dd { margin: 0; word-break: break-all; }
.notes { background: #f7f9fa; border-left: 3px solid #b9c3cc; padding: 8px 12px; margin: 10px 0 14px 0; }
ul.steps { margin: 6px 0 14px 0; padding-left: 20px; }
ul.steps li { margin-bottom: 3px; }
ul.steps li.bad { color: #9b1c1c; }
ul.steps code { background: #f0f3f5; padding: 1px 5px; border-radius: 3px; }
.detail-list { margin: 6px 0 0 0; padding-left: 18px; }
figure { margin: 0 0 22px 0; page-break-inside: avoid; break-inside: avoid; }
figure img { display: block; width: 100%; max-width: 100%; height: auto; border: 1px solid #7d8894; }
figcaption { font-size: 12px; color: #4a545e; padding: 6px 2px 0 2px; border-bottom: 1px solid #eceff2; word-break: break-all; }
figcaption .hash, table.hashes code, .manifest code { font-family: Consolas, "Cascadia Mono", monospace; font-size: 11px; }
.manifest { background: #f7f9fa; border-left: 3px solid #12507d; padding: 8px 12px; }
.integrity-note { color: #3a4149; }
.empty { color: #8a5a00; font-style: italic; }
footer { margin-top: 46px; padding-top: 12px; border-top: 1px solid #d5dbe1; color: #5a6570; font-size: 12px; }
a { color: #12507d; }
@media print {
  body { padding: 0; font-size: 11px; }
  a { color: #1b1f24; text-decoration: none; }
  .meta td.k { background: #ffffff; }
}
'@

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine("<title>Vouch &mdash; Audit Evidence Report - $(Encode-Html $Run.StartTime)</title>")
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine($css)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')

    [void]$sb.AppendLine('<h1>Vouch &mdash; Audit Evidence Report</h1>')
    # Pages captured as the window or the page content only have no taskbar clock: the
    # general wording must then not promise one. Screen-only reports read as before.
    $allScreen = -not @($Items | Where-Object {
            ($_.PSObject.Properties['CaptureArea'] -and $_.CaptureArea -ne 'screen') -or
            @($_.Captures | Where-Object { $_.PSObject.Properties['CaptureArea'] -and $_.CaptureArea -ne 'screen' }).Count -gt 0 })
    $subtitle = if ($allScreen) { 'Screen captures of live application pages, including the Windows taskbar clock.' }
    else { 'Captures of live application pages. Each page states what its images show (its capture area).' }
    [void]$sb.AppendLine("<p class=""subtitle"">$subtitle</p>")

    [void]$sb.AppendLine('<div class="meta"><table>')
    $metaRows = @(
        [pscustomobject]@{ Label = 'Run started';       Text = $Run.StartTime },
        [pscustomobject]@{ Label = 'Run finished';      Text = $Run.EndTime },
        [pscustomobject]@{ Label = 'Time zone';         Text = $Run.TimeZone },
        [pscustomobject]@{ Label = 'Computer';          Text = $Run.Computer },
        [pscustomobject]@{ Label = 'Captured by';       Text = $Run.User },
        [pscustomobject]@{ Label = 'Operating system';  Text = $Run.OperatingSystem },
        [pscustomobject]@{ Label = 'Browser';           Text = $Run.EdgeVersion },
        [pscustomobject]@{ Label = 'Browser instance';  Text = $Run.BrowserInstance },
        [pscustomobject]@{ Label = 'Desktop';           Text = $(if ($Run.PSObject.Properties['CaptureDesktop']) { $Run.CaptureDesktop } else { '' }) },
        [pscustomobject]@{ Label = 'Capture tool';      Text = "vouch.ps1 v$($Run.ToolVersion)" },
        [pscustomobject]@{ Label = 'Definition file';   Text = $Run.CsvPath },
        [pscustomobject]@{ Label = 'Image format';      Text = $Run.ImageDescription },
        [pscustomobject]@{ Label = 'Screen resolution'; Text = $Run.ScreenResolution },
        [pscustomobject]@{ Label = 'Run ID';            Text = $runId },
        [pscustomobject]@{ Label = 'Manifest SHA-256';  Text = $manifestHash }
    )
    foreach ($row in $metaRows) {
        [void]$sb.AppendLine("<tr><td class=""k"">$(Encode-Html $row.Label)</td><td>$(Encode-Html ([string]$row.Text))</td></tr>")
    }
    [void]$sb.AppendLine('</table></div>')

    [void]$sb.AppendLine('<h2>Summary</h2>')
    [void]$sb.AppendLine('<p class="counts">' +
        "<span><strong>$($Run.Total)</strong> item(s)</span>" +
        "<span><span class=""badge ok"">OK</span> $($Run.OkCount)</span>" +
        "<span><span class=""badge warn"">WARNING</span> $($Run.WarnCount)</span>" +
        "<span><span class=""badge fail"">FAILED</span> $($Run.FailCount)</span>" +
        "<span><strong>$($Run.CaptureCount)</strong> screenshot(s)</span>" +
        '</p>')

    [void]$sb.AppendLine('<table class="summary">')
    [void]$sb.AppendLine('<thead><tr><th>#</th><th>Name</th><th>Requested URL</th><th>Final URL</th><th>Status</th><th>Details</th><th>Captures</th></tr></thead>')
    [void]$sb.AppendLine('<tbody>')
    foreach ($item in $Items) {
        $badgeClass = Get-StatusCssClass -Status $item.Status
        $details = if ($item.Details.Count -gt 0) { (($item.Details | ForEach-Object { Encode-Html $_ }) -join '<br>') } else { '&mdash;' }
        $finalUrl = if ([string]::IsNullOrWhiteSpace($item.FinalUrl)) { '&mdash;' } else { Encode-Html $item.FinalUrl }
        [void]$sb.AppendLine(
            "<tr><td><a href=""#item-$($item.Index)"">$($item.Index)</a></td>" +
            "<td>$(Encode-Html $item.Name)</td>" +
            "<td>$(Encode-Html $item.Url)</td>" +
            "<td>$finalUrl</td>" +
            "<td><span class=""$badgeClass"">$(Encode-Html $item.Status)</span></td>" +
            "<td>$details</td>" +
            "<td>$($item.Captures.Count)</td></tr>")
    }
    [void]$sb.AppendLine('</tbody></table>')

    [void]$sb.AppendLine('<h2>Integrity</h2>')
    [void]$sb.AppendLine('<p class="integrity-note">Each screenshot carries its own metadata (page, capture time, run ID, computer and user) ' +
        'inside the image file, and is identified below by the SHA-256 hash of that file. The manifest hash covers all of them at once: ' +
        'record it in the workpaper at capture time, and anyone can later confirm the evidence is unchanged with ' +
        '<code>vouch.ps1 -Verify &lt;report&gt;</code>, or check saved images with <code>sha256sum -c SHA256SUMS</code>.</p>')
    [void]$sb.AppendLine("<p class=""manifest"" data-manifest-sha256=""$(Encode-Html $manifestHash)"">Run ID <code>$(Encode-Html $runId)</code><br>" +
        "Manifest SHA-256 <code>$(Encode-Html $manifestHash)</code></p>")
    [void]$sb.AppendLine('<table class="summary hashes"><thead><tr><th>#</th><th>File</th><th>Captured</th><th>SHA-256</th></tr></thead><tbody>')
    foreach ($item in $Items) {
        foreach ($capture in $item.Captures) {
            [void]$sb.AppendLine("<tr><td><a href=""#item-$($item.Index)"">$($item.Index)</a></td><td>$(Encode-Html $capture.FileName)</td>" +
                "<td>$(Encode-Html $capture.CapturedAt)</td><td><code>$($capture.Sha256)</code></td></tr>")
        }
    }
    [void]$sb.AppendLine('</tbody></table>')

    [void]$sb.AppendLine('<h2>Evidence</h2>')

    foreach ($item in $Items) {
        $badgeClass = Get-StatusCssClass -Status $item.Status
        [void]$sb.AppendLine("<section class=""item"" id=""item-$($item.Index)"">")
        [void]$sb.AppendLine("<div class=""item-head""><h2>$($item.Index). $(Encode-Html $item.Name)</h2><span class=""$badgeClass"">$(Encode-Html $item.Status)</span></div>")

        [void]$sb.AppendLine('<dl>')
        [void]$sb.AppendLine("<dt>Requested URL</dt><dd>$(Encode-Html $item.Url)</dd>")
        $finalUrlText = if ([string]::IsNullOrWhiteSpace($item.FinalUrl)) { 'not reached' } else { $item.FinalUrl }
        [void]$sb.AppendLine("<dt>Final URL</dt><dd>$(Encode-Html $finalUrlText)</dd>")
        $statusText = if ($item.HttpStatus -gt 0) { [string]$item.HttpStatus } else { 'not reported by the browser' }
        [void]$sb.AppendLine("<dt>HTTP status</dt><dd>$(Encode-Html $statusText)</dd>")
        $scrollText = if (-not $item.ScrollFullPage) { 'No - single viewport' }
        else {
            $area = if ($item.PSObject.Properties['ScrollArea'] -and $item.ScrollArea) { " (scrolled: $($item.ScrollArea))" } else { '' }
            "Yes - full page in viewport segments$area"
        }
        [void]$sb.AppendLine("<dt>Scroll capture</dt><dd>$(Encode-Html $scrollText)</dd>")
        $itemArea = if ($item.PSObject.Properties['CaptureArea']) { [string]$item.CaptureArea } else { 'screen' }
        $itemZoom = if ($item.PSObject.Properties['ZoomPercent']) { [int]$item.ZoomPercent } else { 100 }
        [void]$sb.AppendLine("<dt>Capture area</dt><dd>$(Encode-Html (Get-CaptureAreaText -Area $itemArea -ZoomPercent $itemZoom -Captures @($item.Captures)))</dd>")
        [void]$sb.AppendLine('</dl>')

        if (-not [string]::IsNullOrWhiteSpace($item.Notes)) {
            [void]$sb.AppendLine("<div class=""notes""><strong>Notes:</strong> $(Encode-Html $item.Notes)</div>")
        }

        if ($item.Details.Count -gt 0) {
            [void]$sb.AppendLine('<h3>Status details</h3><ul class="detail-list">')
            foreach ($detail in $item.Details) {
                [void]$sb.AppendLine("<li>$(Encode-Html $detail)</li>")
            }
            [void]$sb.AppendLine('</ul>')
        }

        if ($item.StepLog.Count -gt 0) {
            [void]$sb.AppendLine('<h3>Steps executed</h3><ul class="steps">')
            foreach ($step in $item.StepLog) {
                if ($step.Ok -and -not [string]::IsNullOrWhiteSpace([string]$step.Message)) {
                    [void]$sb.AppendLine("<li><code>$(Encode-Html $step.Text)</code> &mdash; $(Encode-Html $step.Message)</li>")
                }
                elseif ($step.Ok) {
                    [void]$sb.AppendLine("<li><code>$(Encode-Html $step.Text)</code> &mdash; ok</li>")
                }
                else {
                    [void]$sb.AppendLine("<li class=""bad""><code>$(Encode-Html $step.Text)</code> &mdash; failed: $(Encode-Html $step.Message)</li>")
                }
            }
            [void]$sb.AppendLine('</ul>')
        }
        elseif (-not [string]::IsNullOrWhiteSpace($item.StepsText)) {
            [void]$sb.AppendLine("<h3>Steps executed</h3><p class=""empty"">Steps were defined (<code>$(Encode-Html $item.StepsText)</code>) but could not be run.</p>")
        }

        [void]$sb.AppendLine('<h3>Screenshots</h3>')
        if ($item.Captures.Count -eq 0) {
            [void]$sb.AppendLine('<p class="empty">No screenshot could be taken for this item.</p>')
        }
        else {
            # A page with several capture actions: say which capture each image belongs
            # to, in the order they were taken. A page with one unlabelled capture reads
            # exactly as before.
            $captureSets = @($item.Captures | ForEach-Object { if ($_.PSObject.Properties['CaptureNumber']) { [int]$_.CaptureNumber } else { 1 } } |
                Sort-Object -Unique).Count
            foreach ($capture in $item.Captures) {
                $segmentText = if ($capture.SegmentCount -gt 1) { " &middot; segment $($capture.SegmentIndex) of $($capture.SegmentCount)" } else { '' }
                $captureNumber = if ($capture.PSObject.Properties['CaptureNumber']) { [int]$capture.CaptureNumber } else { 1 }
                $label = if ($capture.PSObject.Properties['Label']) { [string]$capture.Label } else { '' }
                $setText = ''
                if ($captureSets -gt 1 -or $label) {
                    $setText = "Capture $captureNumber" + $(if ($label) { ": $label" } else { '' })
                }
                [void]$sb.AppendLine('<figure>')
                # The data-* attributes are what -Verify checks each image against; keep
                # their order in step with Test-ReportIntegrity.
                [void]$sb.Append('<img alt="')
                [void]$sb.Append((Encode-Html "$($item.Name)$(if ($setText) { " - $setText" }) screenshot $($capture.SegmentIndex) of $($capture.SegmentCount)"))
                [void]$sb.Append('" data-file="')
                [void]$sb.Append((Encode-Html $capture.FileName))
                [void]$sb.Append('" data-sha256="')
                [void]$sb.Append($capture.Sha256)
                [void]$sb.Append('" data-captured="')
                [void]$sb.Append((Encode-Html $capture.CapturedAt))
                [void]$sb.Append('" data-url="')
                [void]$sb.Append((Encode-Html $capture.Url))
                [void]$sb.Append('" src="data:')
                [void]$sb.Append($mimeType)
                [void]$sb.Append(';base64,')
                [void]$sb.Append($capture.Base64)
                [void]$sb.AppendLine('">')
                $setHtml = if ($setText) { "<strong>$(Encode-Html $setText)</strong> &middot; " } else { '' }
                [void]$sb.AppendLine("<figcaption>$($setHtml)Captured $(Encode-Html $capture.Timestamp)$segmentText &middot; $(Encode-Html $capture.Url)<br>" +
                    "<span class=""hash"">SHA-256 $($capture.Sha256) &middot; $(Encode-Html $capture.FileName)</span></figcaption>")
                [void]$sb.AppendLine('</figure>')
            }
        }

        [void]$sb.AppendLine('</section>')
    }

    $footerNote = if ($allScreen) { 'Screenshots are unretouched captures of the primary display.' }
    else { 'Screenshots are unretouched captures of the primary display, the Edge window, or the page content as rendered by Edge, as each page states.' }
    [void]$sb.AppendLine("<footer>Generated by vouch.ps1 v$($Run.ToolVersion) on $(Encode-Html $Run.EndTime) ($(Encode-Html $Run.TimeZone)). $footerNote</footer>")
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    return $sb.ToString()
}

#endregion

#region Main ------------------------------------------------------------------

function Write-RowStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Status
    )
    $color = switch ($Status) {
        'OK'      { 'Green' }
        'WARNING' { 'Yellow' }
        default   { 'Red' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Close-CdpSocket {
    if ($null -eq $script:CdpSocket) { return }
    try {
        if ($script:CdpSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(5))
            try {
                [void]$script:CdpSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult()
            }
            finally {
                $cts.Dispose()
            }
        }
    }
    catch {
        Write-Verbose "Ignoring WebSocket close error: $($_.Exception.Message)"
    }
    finally {
        try { $script:CdpSocket.Dispose() } catch { Write-Verbose 'WebSocket already disposed.' }
        $script:CdpSocket = $null
    }
}

function Stop-EdgeProcess {
    if (-not $script:LaunchedEdge) { return }

    # Browser.close shuts every window down in order, so Edge flushes cookies and
    # sessions to the audit profile and the DevTools port closes with it.
    $closeRequested = $false
    if (-not [string]::IsNullOrWhiteSpace($script:BrowserWsUrl)) {
        try {
            Connect-CdpSocket -WebSocketUrl $script:BrowserWsUrl -TimeoutSec 5
            try { [void](Send-CdpCommand -Method 'Browser.close' -TimeoutSec 5) }
            catch { Write-Verbose "Browser.close: $($_.Exception.Message)" }   # the socket may drop before the reply
            $closeRequested = $true
        }
        catch {
            Write-Verbose "Could not reach the browser DevTools endpoint: $($_.Exception.Message)"
        }
        finally {
            Close-CdpSocket
        }
    }

    if ($null -eq $script:EdgeProcess) { return }
    try {
        $process = Get-Process -Id $script:EdgeProcess.Id -ErrorAction SilentlyContinue
        if ($null -eq $process) { return }
        if (-not $closeRequested) { [void]$process.CloseMainWindow() }
        if (-not $process.WaitForExit(10000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Verbose "Could not close Edge cleanly: $($_.Exception.Message)"
    }
}

function Invoke-LoginSetup {
    param(
        [Parameter(Mandatory)][string]$EdgePath,
        [Parameter(Mandatory)][string]$ProfileDir
    )

    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        [void](New-Item -ItemType Directory -Path $ProfileDir -Force)
    }

    Write-Host ''
    Write-Host 'Vouch - first-time login setup' -ForegroundColor Cyan
    Write-Host "Profile directory: $ProfileDir"
    Write-Host ''
    Write-Host 'Edge is opening with the dedicated audit profile (no debugging flags).'
    Write-Host 'Sign in to every application you want to capture, complete any MFA prompts,'
    Write-Host 'and choose "stay signed in" where offered. Then come back here.'
    Write-Host ''

    $arguments = @(
        "--user-data-dir=`"$($ProfileDir.TrimEnd('\'))`""
        '--no-first-run'
        '--no-default-browser-check'
        '--start-maximized'
        'about:blank'
    )
    [void](Start-Process -FilePath $EdgePath -ArgumentList $arguments)

    [void](Read-Host 'Press Enter when you have finished signing in')

    # Start-Process only returns Edge's short-lived launcher, so find the browser by its
    # profile. Close its windows one at a time so every session is flushed to disk.
    $browser = Find-EdgeBrowserProcess -ProfileDir $ProfileDir
    $deadline = (Get-Date).AddSeconds(20)
    while ($null -ne $browser -and (Get-Date) -lt $deadline) {
        try {
            $browser = Get-Process -Id $browser.Id -ErrorAction Stop
            if ($browser.MainWindowHandle -ne [IntPtr]::Zero) { [void]$browser.CloseMainWindow() }
            if ($browser.WaitForExit(2000)) { $browser = $null }
        }
        catch {
            $browser = $null
        }
    }

    Write-Host ''
    if ($null -ne $browser) {
        Write-Host 'Edge is still running with the audit profile. Close all of its windows before starting a capture run.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Sessions saved. You can now run the script normally to capture evidence.' -ForegroundColor Green
    }
}

function ConvertTo-RunSummaryJson {
    <#
        Machine-readable companion to the HTML report (-JsonSummary): the same run
        metadata and per-item results, without the image data.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][object]$Run,
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][int]$ExitCode
    )

    $summary = [ordered]@{
        Report    = $ReportPath
        ExitCode  = $ExitCode
        Run       = $Run
        Items     = @(foreach ($item in $Items) {
            [ordered]@{
                Index          = $item.Index
                Name           = $item.Name
                Url            = $item.Url
                FinalUrl       = $item.FinalUrl
                Status         = $item.Status
                HttpStatus     = $item.HttpStatus
                ScrollFullPage = $item.ScrollFullPage
                ScrollArea     = $(if ($item.PSObject.Properties['ScrollArea']) { $item.ScrollArea } else { '' })
                CaptureArea    = $(if ($item.PSObject.Properties['CaptureArea']) { $item.CaptureArea } else { 'screen' })
                ZoomPercent    = $(if ($item.PSObject.Properties['ZoomPercent']) { $item.ZoomPercent } else { 100 })
                Details        = @($item.Details)
                Steps          = @($item.StepLog | ForEach-Object { [ordered]@{ Text = $_.Text; Ok = $_.Ok; Message = $_.Message } })
                Captures       = @($item.Captures | ForEach-Object {
                    [ordered]@{
                        Timestamp    = $_.Timestamp
                        CapturedAt   = $_.CapturedAt
                        Sha256       = $_.Sha256
                        FileName     = $_.FileName
                        Url          = $_.Url
                        SegmentIndex = $_.SegmentIndex
                        SegmentCount = $_.SegmentCount
                        Bytes        = $_.Bytes
                        FilePath     = $_.FilePath
                        # Which capture action of the page took it (1, 2, ...) and its label.
                        CaptureNumber = $(if ($_.PSObject.Properties['CaptureNumber']) { $_.CaptureNumber } else { 1 })
                        Label         = $(if ($_.PSObject.Properties['Label']) { $_.Label } else { '' })
                        # What the image shows (screen, window, page) and the page zoom.
                        CaptureArea   = $(if ($_.PSObject.Properties['CaptureArea']) { $_.CaptureArea } else { 'screen' })
                        ZoomPercent   = $(if ($_.PSObject.Properties['ZoomPercent']) { $_.ZoomPercent } else { 100 })
                    }
                })
            }
        })
    }
    return ($summary | ConvertTo-Json -Depth 6)
}

function Test-ReportIntegrity {
    <#
        Re-checks a report without trusting anything but its own contents: every embedded
        image is hashed again and compared with the hash printed for it, the metadata
        inside each image must match the report (capture time, page URL), the manifest
        hash is recomputed from the per-image hashes, and saved images (images\<report>\
        with SHA256SUMS) are hashed from disk. Returns one row per check.

        This proves the report and images are unchanged since the manifest hash was
        recorded; it cannot tell on its own whether someone rebuilt all hashes together,
        which is why the manifest hash should be kept outside the report as well.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Report not found: $Path" }
    $html = [System.IO.File]::ReadAllText($Path)
    $decode = { param([string]$Text) [System.Net.WebUtility]::HtmlDecode($Text) }
    $results = [System.Collections.Generic.List[object]]::new()
    $add = { param($Check, $Ok, $Detail) $results.Add([pscustomobject]@{ Check = $Check; Ok = [bool]$Ok; Detail = $Detail }) }

    $pattern = '<img alt="[^"]*" data-file="([^"]*)" data-sha256="([0-9a-f]{64})" data-captured="([^"]*)" data-url="([^"]*)" src="data:image/(?:jpeg|png);base64,([A-Za-z0-9+/=]+)">'
    $images = [regex]::Matches($html, $pattern)
    if ($images.Count -eq 0) { & $add 'Report' $false 'No hashed screenshots found - not a Vouch 1.2+ report, or it has no captures.' }

    $manifestLines = [System.Collections.Generic.List[string]]::new()
    foreach ($image in $images) {
        $file = & $decode $image.Groups[1].Value
        $listed = $image.Groups[2].Value
        $bytes = [System.Convert]::FromBase64String($image.Groups[5].Value)
        $actual = Get-Sha256Hex -Bytes $bytes
        $manifestLines.Add("$listed  $file")
        & $add "Image $file" ($actual -eq $listed) $(if ($actual -eq $listed) { "SHA-256 $actual" } else { "hash is $actual, report lists $listed" })

        $metadata = Get-ImageMetadata -Bytes $bytes
        if ($null -eq $metadata) {
            & $add "Metadata $file" $false 'no embedded metadata'
        }
        else {
            $problems = @()
            if ([string]$metadata.CapturedAt -ne (& $decode $image.Groups[3].Value)) { $problems += "capture time $($metadata.CapturedAt) differs from the report" }
            if ([string]$metadata.PageUrl -ne (& $decode $image.Groups[4].Value)) { $problems += "page URL $($metadata.PageUrl) differs from the report" }
            & $add "Metadata $file" ($problems.Count -eq 0) $(if ($problems.Count -eq 0) { "$($metadata.ItemName) | $($metadata.CapturedAt) | $($metadata.PageUrl)" } else { $problems -join '; ' })
        }
    }

    $stated = [regex]::Match($html, 'data-manifest-sha256="([0-9a-f]{64})"')
    if ($images.Count -gt 0) {
        $recomputed = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes((@($manifestLines) -join "`n") + "`n"))
        if (-not $stated.Success) { & $add 'Manifest' $false 'the report states no manifest hash' }
        else {
            $ok = $recomputed -eq $stated.Groups[1].Value
            & $add 'Manifest' $ok $(if ($ok) { "SHA-256 $recomputed" } else { "recomputed $recomputed, report states $($stated.Groups[1].Value)" })
        }
    }

    # Saved image files, when the run used -SaveImages.
    $imagesDir = Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath (Join-Path 'images' ([System.IO.Path]::GetFileNameWithoutExtension($Path)))
    $sums = Join-Path -Path $imagesDir -ChildPath 'SHA256SUMS'
    if (Test-Path -LiteralPath $sums -PathType Leaf) {
        $sumsText = [System.IO.File]::ReadAllText($sums)
        $sumsHash = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($sumsText))
        & $add 'SHA256SUMS' ($stated.Success -and $sumsHash -eq $stated.Groups[1].Value) "file hashes to $sumsHash"
        foreach ($line in ($sumsText -split "`n" | Where-Object { $_ -match '^([0-9a-f]{64})  (.+)$' })) {
            $null = $line -match '^([0-9a-f]{64})  (.+)$'
            $expected = $Matches[1]
            $name = $Matches[2]
            $filePath = Join-Path -Path $imagesDir -ChildPath $name
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { & $add "File $name" $false 'missing'; continue }
            $actual = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($filePath))
            & $add "File $name" ($actual -eq $expected) $(if ($actual -eq $expected) { 'matches' } else { "hash is $actual, expected $expected" })
        }
    }
    return $results
}

function Invoke-VerifyReport {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    $results = @(Test-ReportIntegrity -Path $Path)
    Write-Host "Verifying $Path" -ForegroundColor Cyan
    foreach ($result in $results) {
        $colour = if ($result.Ok) { 'Green' } else { 'Red' }
        Write-Host ('  {0,-4} {1,-58} {2}' -f $(if ($result.Ok) { 'OK' } else { 'FAIL' }), $result.Check, $result.Detail) -ForegroundColor $colour
    }
    $failed = @($results | Where-Object { -not $_.Ok }).Count
    Write-Host ''
    if ($failed -eq 0) {
        Write-Host "VERIFIED: $($results.Count) check(s) passed." -ForegroundColor Green
        return 0
    }
    Write-Host "NOT VERIFIED: $failed of $($results.Count) check(s) failed." -ForegroundColor Red
    return 4
}

function Start-RunLog {
    <#
        Unattended runs have no console to read, so -LogDir keeps a transcript of each
        run (everything the console would have shown, including the exit code).
        Returns $true when a transcript was started.
    #>
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            [void](New-Item -ItemType Directory -Path $Directory -Force)
        }
        $logPath = Join-Path -Path $Directory -ChildPath "vouch_$((Get-Date).ToString('yyyy-MM-dd_HHmmss')).log"
        [void](Start-Transcript -LiteralPath $logPath -Force)
        return $true
    }
    catch {
        Write-Host "WARNING: could not start the log in '$Directory': $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Get-RunSettingDefinition {
    <#
        The one list of run-level settings: the script parameter each one comes from, the
        type it is used as, and where a configuration file keeps it. Resolve-RunSettings
        and Invoke-Main both read it, so a setting added here is picked up by both.
        Settings without a config location (CsvPath, ConfigPath, Only, Verify, LoginSetup,
        NoPrompt, EventLogPath, TabId) are command-line only: they choose what the run
        does or how it is driven, not how it captures.
    #>
    return @(
        [pscustomobject]@{ Name = 'CsvPath';              Type = 'string'; Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'OutputDir';            Type = 'string'; Section = 'output';   Key = 'dir' }
        [pscustomobject]@{ Name = 'ReportName';           Type = 'string'; Section = 'output';   Key = 'reportName' }
        [pscustomobject]@{ Name = 'EdgeProfileDir';       Type = 'string'; Section = 'browser';  Key = 'profileDir' }
        [pscustomobject]@{ Name = 'DebugPort';            Type = 'int';    Section = 'browser';  Key = 'debugPort' }
        [pscustomobject]@{ Name = 'NavigationTimeoutSec'; Type = 'int';    Section = 'defaults'; Key = 'navigationTimeoutSec' }
        [pscustomobject]@{ Name = 'SettleSeconds';        Type = 'double'; Section = 'defaults'; Key = 'settleSeconds' }
        [pscustomobject]@{ Name = 'ScrollSettleSeconds';  Type = 'double'; Section = 'defaults'; Key = 'scrollSettleSeconds' }
        [pscustomobject]@{ Name = 'MaxScrollSegments';    Type = 'int';    Section = 'defaults'; Key = 'maxScrollSegments' }
        [pscustomobject]@{ Name = 'ImageFormat';          Type = 'string'; Section = 'output';   Key = 'imageFormat' }
        [pscustomobject]@{ Name = 'JpegQuality';          Type = 'int';    Section = 'output';   Key = 'jpegQuality' }
        [pscustomobject]@{ Name = 'SaveImages';           Type = 'bool';   Section = 'output';   Key = 'saveImages' }
        [pscustomobject]@{ Name = 'KeepBrowserOpen';      Type = 'bool';   Section = 'browser';  Key = 'keepBrowserOpen' }
        [pscustomobject]@{ Name = 'FailOnWarning';        Type = 'bool';   Section = 'output';   Key = 'failOnWarning' }
        [pscustomobject]@{ Name = 'LogDir';               Type = 'string'; Section = 'output';   Key = 'logDir' }
        [pscustomobject]@{ Name = 'JsonSummary';          Type = 'bool';   Section = 'output';   Key = 'jsonSummary' }
        [pscustomobject]@{ Name = 'UseVirtualDesktop';    Type = 'bool';   Section = 'browser';  Key = 'useVirtualDesktop' }
        [pscustomobject]@{ Name = 'CaptureArea';          Type = 'string'; Section = 'defaults'; Key = 'captureArea' }
        [pscustomobject]@{ Name = 'ZoomPercent';          Type = 'int';    Section = 'defaults'; Key = 'zoomPercent' }
        [pscustomobject]@{ Name = 'Verify';               Type = 'string'; Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'LoginSetup';           Type = 'bool';   Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'ConfigPath';           Type = 'string'; Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'Only';                 Type = 'list';   Section = '';         Key = '' }
        # Run plumbing for the Designer and the scheduler: how this run is driven, never
        # part of a configuration file.
        [pscustomobject]@{ Name = 'NoPrompt';             Type = 'bool';   Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'EventLogPath';         Type = 'string'; Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'TabId';                Type = 'string'; Section = '';         Key = '' }
    )
}

function Get-ConfigValue {
    <#
        Reads one value from a configuration object that may be a parsed JSON object
        (ConvertFrom-Json) or a hashtable. Returns $found = $false for a missing section
        or key, a null value, or a blank string: the config file template writes "" for
        "use the default", so blank must not override the parameter default.
    #>
    param(
        [AllowNull()][object]$Config,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $notFound = [pscustomobject]@{ Found = $false; Value = $null }
    if ($null -eq $Config) { return $notFound }

    $container = $null
    if ($Config -is [System.Collections.IDictionary]) {
        if (@($Config.Keys) -contains $Section) { $container = $Config[$Section] }
    }
    elseif ($Config.PSObject.Properties[$Section]) { $container = $Config.$Section }
    if ($null -eq $container) { return $notFound }

    $value = $null
    if ($container -is [System.Collections.IDictionary]) {
        if (@($container.Keys) -notcontains $Key) { return $notFound }
        $value = $container[$Key]
    }
    elseif ($container.PSObject.Properties[$Key]) { $value = $container.$Key }
    else { return $notFound }

    if ($null -eq $value) { return $notFound }
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return $notFound }
    return [pscustomobject]@{ Found = $true; Value = $value }
}

function Resolve-RunSettings {
    <#
        One place where every run-level value is decided, so the capture code never reads
        script parameters and a single page can be run on its own (Designer, -Only).
        Precedence: a parameter the user typed > the configuration file > the parameter's
        default. "Typed" means present in the bound parameters, so -SaveImages:$false
        still beats "saveImages": true in a config. Pure: no variables outside its own
        parameters are read.
    #>
    param(
        # $PSBoundParameters of the script (or any dictionary of explicitly chosen values).
        [AllowNull()][System.Collections.IDictionary]$BoundParameters,
        # The parameter defaults, by parameter name.
        [AllowNull()][System.Collections.IDictionary]$Defaults,
        # A parsed configuration (sections browser / defaults / output); $null for none.
        [AllowNull()][object]$Config = $null
    )

    $settings = [ordered]@{}
    foreach ($definition in Get-RunSettingDefinition) {
        $name = $definition.Name
        $value = $null
        if ($null -ne $BoundParameters -and @($BoundParameters.Keys) -contains $name) {
            $value = $BoundParameters[$name]
        }
        else {
            $fromConfig = [pscustomobject]@{ Found = $false; Value = $null }
            if ($definition.Section) {
                $fromConfig = Get-ConfigValue -Config $Config -Section $definition.Section -Key $definition.Key
            }
            if ($fromConfig.Found) { $value = $fromConfig.Value }
            elseif ($null -ne $Defaults -and @($Defaults.Keys) -contains $name) { $value = $Defaults[$name] }
        }

        $settings[$name] = ConvertTo-SettingValue -Type $definition.Type -Value $value
    }
    return [pscustomobject]$settings
}

function ConvertTo-SettingValue {
    <#
        [bool] turns a [switch] into a plain true/false; [string] turns a missing value
        into '' - both read the same way the script's own parameters did. Config values
        reach this only after Test-VouchConfig accepted their type, so no conversion
        here can fail on a user's typo.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [AllowNull()][object]$Value
    )
    if ($Type -eq 'list') {
        return , [string[]]@(@($Value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    }
    switch ($Type) {
        'bool'   { return [bool]$Value }
        'int'    { return [int]$Value }
        'double' { return [double]$Value }
        default  { return [string]$Value }
    }
}

function Split-BoundParameter {
    <#
        Sorts the setting values visible to Invoke-Main into "typed by the user" and
        "parameter defaults". An unbound script parameter still holds its default, so the
        values of the parameters missing from $PSBoundParameters are the defaults and are
        not written out a second time. Without bound parameters (the end-to-end tests set
        plain variables) every visible value counts as typed. Pure.
    #>
    param(
        # Setting name -> current value, as read from the calling scope.
        [AllowNull()][System.Collections.IDictionary]$InScope = @{},
        [AllowNull()][System.Collections.IDictionary]$BoundParameters = $null
    )
    $bound = @{}
    $defaults = @{}
    if ($null -eq $InScope) { $InScope = @{} }
    if ($null -eq $BoundParameters) {
        foreach ($name in @($InScope.Keys)) { $bound[$name] = $InScope[$name] }
    }
    else {
        $boundNames = @($BoundParameters.Keys)
        foreach ($name in $boundNames) { $bound[$name] = $BoundParameters[$name] }
        foreach ($name in @($InScope.Keys)) {
            if ($boundNames -notcontains $name) { $defaults[$name] = $InScope[$name] }
        }
    }
    return [pscustomobject]@{ Bound = $bound; Defaults = $defaults }
}

function Get-PageSettings {
    <#
        The settings for one page: the run's settings with the page's "overrides"
        applied, plus the page-level settings the configuration adds (Account,
        CaptureArea, ZoomPercent, WaitFor, OnNotReady, PromptTimeoutSec). One object per
        page, so Invoke-CaptureItem reads everything from -Settings and never has to
        know where a value came from.
        A value typed on the command line beats a page override too: the precedence is
        command line > configuration > default, whatever part of the file it is in.
        (-CaptureArea and -ZoomPercent are the page-level settings that also have a
        command-line switch.)
    #>
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][object]$Definition,
        [AllowNull()][object]$Config = $null,
        # Settings typed on the command line.
        [AllowEmptyCollection()][string[]]$BoundNames = @()
    )
    $page = [ordered]@{}
    foreach ($property in $Settings.PSObject.Properties) { $page[$property.Name] = $property.Value }

    $overrides = $null
    if ($Definition.PSObject.Properties['Overrides'] -and $Definition.Overrides -is [System.Collections.IDictionary]) {
        $overrides = @{ defaults = $Definition.Overrides }
    }
    # The page-level keys are decided by the second loop alone (schema default <
    # configuration < page override), also the two that are run settings as well.
    $pageLevelKeys = 'account', 'captureArea', 'zoomPercent', 'waitFor', 'onNotReady', 'promptTimeoutSec'
    foreach ($setting in @(Get-RunSettingDefinition | Where-Object Section -eq 'defaults')) {
        if ($BoundNames -contains $setting.Name -or $pageLevelKeys -contains $setting.Key) { continue }
        $fromPage = Get-ConfigValue -Config $overrides -Section 'defaults' -Key $setting.Key
        if ($fromPage.Found) { $page[$setting.Name] = ConvertTo-SettingValue -Type $setting.Type -Value $fromPage.Value }
    }

    $schemaDefaults = Get-DefaultVouchConfig
    foreach ($key in $pageLevelKeys) {
        $name = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
        # -CaptureArea / -ZoomPercent typed on the command line: already in the run settings.
        if ($BoundNames -contains $name) { continue }
        $value = $schemaDefaults['defaults'][$key]
        $fromConfig = Get-ConfigValue -Config $Config -Section 'defaults' -Key $key
        if ($fromConfig.Found) { $value = $fromConfig.Value }
        $fromPage = Get-ConfigValue -Config $overrides -Section 'defaults' -Key $key
        if ($fromPage.Found) { $value = $fromPage.Value }
        $page[$name] = if ($value -is [string]) { $value } else { [int]$value }
    }
    return [pscustomobject]$page
}

function Get-RunLogDirectory {
    <#
        The transcript starts before Invoke-Main, so that a configuration that fails to
        load is still logged; it therefore needs output.logDir before the settings are
        resolved. Reads only that one value: -LogDir typed on the command line wins, then
        the configuration (relative to its folder), then the -LogDir default. Any
        problem with the file is left for Invoke-Main to report.
    #>
    param(
        [AllowNull()][System.Collections.IDictionary]$BoundParameters,
        [AllowEmptyString()][string]$LogDir = '',
        [AllowEmptyString()][string]$ConfigPath = ''
    )
    if ($null -ne $BoundParameters -and @($BoundParameters.Keys) -contains 'LogDir') { return $LogDir }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return $LogDir }
    try {
        $fullPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
        $config = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($fullPath))
        $fromConfig = Get-ConfigValue -Config $config -Section 'output' -Key 'logDir'
        if ($fromConfig.Found -and $fromConfig.Value -is [string]) {
            return Resolve-VouchConfigPath -Path $fromConfig.Value -BaseDirectory (Split-Path -Path $fullPath -Parent)
        }
    }
    catch {
        Write-Verbose "Log folder not read from the configuration: $($_.Exception.Message)"
    }
    return $LogDir
}

function New-CaptureItem {
    <#
        The result record for one page. Built before the page is visited, so the page
        still appears in the report (as FAILED) whatever goes wrong while capturing it.
    #>
    param([Parameter(Mandatory)][object]$Definition)

    return [pscustomobject]@{
        Index          = $Definition.Index
        Name           = $Definition.Name
        Url            = $Definition.Url
        FinalUrl       = ''
        Notes          = $Definition.Notes
        StepsText      = $Definition.StepsText
        ScrollFullPage = $Definition.ScrollFullPage
        ScrollArea     = ''
        Status         = 'OK'
        HttpStatus     = 0
        Details        = [System.Collections.Generic.List[string]]::new()
        StepLog        = [System.Collections.Generic.List[object]]::new()
        Captures       = [System.Collections.Generic.List[object]]::new()
        # The page's capture area and zoom as set; each capture records what it got.
        CaptureArea    = 'screen'
        ZoomPercent    = 100
    }
}

function Get-PageCaptureMode {
    <#
        The capture area and zoom a page's settings ask for. Settings built without the
        page-level values (Resolve-RunSettings with no defaults for them, as the
        single-page callers and the tests do) mean what they always meant: the screen,
        at 100%.
    #>
    param([Parameter(Mandatory)][object]$Settings)
    $area = 'screen'
    if ($Settings.PSObject.Properties['CaptureArea'] -and [string]$Settings.CaptureArea -in 'screen', 'window', 'page') {
        $area = ([string]$Settings.CaptureArea).ToLowerInvariant()
    }
    $zoom = 100
    if ($Settings.PSObject.Properties['ZoomPercent'] -and [int]$Settings.ZoomPercent -ge 25 -and [int]$Settings.ZoomPercent -le 500) {
        $zoom = [int]$Settings.ZoomPercent
    }
    return [pscustomobject]@{ Area = $area; ZoomPercent = $zoom }
}

function Invoke-ScrollCapture {
    <#
        Takes the screenshots of one capture action, for a page that is already loaded
        (and in the foreground, for the screen and window areas): one screen
        (-ScrollMode none), or one per screen of what scrolls - found automatically
        (auto), the window (page) or a named area (area; see Get-ScrollTargetScript).
        The page's capture area decides what each image shows (Add-ItemCapture); the
        scrolling is the same for all three, so auto, page and area behave alike.
        -ScrollAs single: one tall image of the whole document instead of segments. Only
        the browser can make such an image, so only for the page capture area, only when
        the window itself scrolls (an inner panel or frame is not part of the document's
        height), and only when the image stays within 16,384 pixels (Get-SingleImagePlan).
        Otherwise it is taken as segments and the item says why.
        Errors from scrolling itself are left to the caller (Invoke-CaptureItem marks
        the page FAILED and the run moves on).
        A page may capture several times; a detail an earlier capture of the same page
        already reported is not repeated.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [ValidateSet('none', 'auto', 'page', 'area')][string]$ScrollMode = 'none',
        [AllowEmptyString()][string]$ScrollSelector = '',
        [ValidateSet('segments', 'single')][string]$ScrollAs = 'segments',
        # Every area the page captures explicitly; never reported as "not scrolled".
        [AllowEmptyCollection()][string[]]$ExplicitAreas = @(),
        [int]$CaptureNumber = 1,
        [AllowEmptyString()][string]$Label = '',
        # The browser's own error page is shown: its URL is not the page's, so keep FinalUrl.
        [Parameter(Mandatory)][bool]$BrowserErrorPage,
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][hashtable]$CaptureContext,
        # The page's title, to find the window for window captures.
        [AllowEmptyString()][string]$PageTitle = ''
    )

    $maxScrollSegments = $Settings.MaxScrollSegments
    $scrollSettleMs = [int]($Settings.ScrollSettleSeconds * 1000)
    $scrolls = $ScrollMode -ne 'none'
    $earlierDetails = @($Item.Details)
    $addDetail = {
        param([string]$Text)
        if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
        if ($earlierDetails -notcontains $Text) { $Item.Details.Add($Text) }
    }
    $area = (Get-PageCaptureMode -Settings $Settings).Area
    # The zoom is read at the moment of each shot: a reconnect between two segments can
    # lose it (Restore-CdpConnection), and every image must record - and, for page
    # captures, be scaled by - the zoom the page shows at that moment.
    $shoot = {
        param([int]$Index, [int]$Count, [string]$Url, $Clip)
        Add-ZoomLostDetail -Item $Item
        Add-ItemCapture -Item $Item -SegmentIndex $Index -SegmentCount $Count -PageUrl $Url -Context $CaptureContext `
            -CaptureNumber $CaptureNumber -Label $Label -CaptureArea $area -ZoomPercent $script:PageZoomPercent -PageClip $Clip -PageTitle $PageTitle
        Add-ZoomLostDetail -Item $Item
    }
    $theCapture = if ($Label) { "the capture '$Label'" } else { 'the capture' }

    $single = $scrolls -and $ScrollAs -eq 'single'
    if ($single -and $area -ne 'page') {
        # Not a problem with the page, so the status stays as it is; said once per page.
        $note = "One tall image (""as"": ""single"") is only possible with the page capture area, so with the $area area $theCapture was taken as screen-sized segments."
        if (-not $Item.Details.Contains($note)) { $Item.Details.Add($note) }
        $single = $false
    }

    $segmentCount = 1
    $viewportHeight = 0.0
    $singleClip = $null
    if ($scrolls) {
        try {
            # Find what scrolls - the page, a panel inside it, or a frame - and start at its top.
            $scrollTarget = Invoke-CdpEval -TimeoutSec 20 -Expression (
                Get-ScrollTargetScript -Mode $ScrollMode -Selector $ScrollSelector -ExplicitSelectors $ExplicitAreas)
            [void](Wait-Interruptible -Milliseconds $scrollSettleMs)

            $viewportHeight = [double]$scrollTarget.view
            $pageHeight = [double]$scrollTarget.total
            $areaText = switch ([string]$scrollTarget.kind) {
                'window'  { 'the page' }
                'none'    { 'nothing to scroll - the content fits on one screen' }
                default   { [string]$scrollTarget.description }
            }
            if (-not $Item.ScrollArea) { $Item.ScrollArea = $areaText }
            elseif (@($Item.ScrollArea -split '; ') -notcontains $areaText) { $Item.ScrollArea += "; $areaText" }

            $fallback = if ($scrollTarget.PSObject.Properties['fallback']) { [string]$scrollTarget.fallback } else { '' }
            if ($fallback) {
                $which = if ($Label) { " of the capture '$Label'" } else { '' }
                $why = switch ($fallback) {
                    'notfound'    { 'matches no element on the page' }
                    'invalid'     { 'is not a CSS selector the browser understands' }
                    'crossorigin' { 'is a frame from another site, which Vouch cannot look into or scroll' }
                    default       { 'does not scroll' }
                }
                & $addDetail "The scroll area '$ScrollSelector'$which $why, so Vouch scrolled what it found itself ($areaText)."
            }
            foreach ($other in @($scrollTarget.others)) {
                & $addDetail "Another scrolling area ($other) was not scrolled; content hidden in it is not captured."
            }
            foreach ($frameName in @($scrollTarget.blockedFrames)) {
                & $addDetail "A frame from another site ($frameName) cannot be scrolled; content hidden in it is not captured."
            }

            if ($viewportHeight -gt 0 -and $pageHeight -gt 0) {
                $segmentCount = [int][Math]::Ceiling($pageHeight / $viewportHeight)
            }
            if ($segmentCount -lt 1) { $segmentCount = 1 }
        }
        catch {
            & $addDetail "The page height could not be measured, so only the first screen was captured: $($_.Exception.Message)"
            $segmentCount = 1
            $viewportHeight = 0
            $single = $false
        }

        if ($single -and $segmentCount -gt 1) {
            if ([string]$scrollTarget.kind -eq 'window') {
                try {
                    $content = Get-PageContentSize
                    $plan = Get-SingleImagePlan -CssHeight $content.Height -DevicePixelRatio $content.DevicePixelRatio -ZoomPercent $script:PageZoomPercent
                    if ($plan.Fits) {
                        $singleClip = @{ x = 0; y = 0; width = [Math]::Ceiling($content.Width); height = [Math]::Ceiling($content.Height) }
                        $singleContent = $content
                    }
                    else {
                        & $addDetail ("The page is too tall for one image ({0} pixels; images cannot be taller than 16,384), so {1} was taken as screen-sized segments." -f
                            $plan.OutputHeight.ToString([System.Globalization.CultureInfo]::InvariantCulture), $theCapture)
                    }
                }
                catch {
                    & $addDetail "The size of the page could not be measured for one image, so $theCapture was taken as screen-sized segments: $($_.Exception.Message)"
                }
            }
            else {
                & $addDetail "One tall image is only possible when the page itself scrolls; here $areaText scrolls inside the page, so $theCapture was taken as screen-sized segments."
            }
        }
    }

    if ($null -ne $singleClip) {
        if (Test-StopRequested) {
            Add-StopDetail -Item $Item
            return
        }
        $singleUrl = if ($BrowserErrorPage) { $Item.FinalUrl } else { Get-CurrentPageUrl }
        $before = $Item.Captures.Count
        & $shoot 1 1 $singleUrl $singleClip
        # Content that loads while the image is taken (lazy loading) makes the page
        # taller than the image planned for it: say so rather than let a cut-off image
        # pass as the whole page.
        if ($Item.Captures.Count -gt $before) {
            try {
                $record = $Item.Captures[$Item.Captures.Count - 1]
                $imageHeight = (Get-ImagePixelSize -Bytes ([Convert]::FromBase64String($record.Base64))).Height
                # Planned at the zoom the image really got (a reconnect can change it).
                $planned = Get-SingleImagePlan -CssHeight ([Math]::Ceiling($singleContent.Height)) -DevicePixelRatio $singleContent.DevicePixelRatio -ZoomPercent $record.ZoomPercent
                $after = Get-PageContentSize
                $afterPlan = Get-SingleImagePlan -CssHeight $after.Height -DevicePixelRatio $after.DevicePixelRatio -ZoomPercent $record.ZoomPercent
                $problem = Get-TallImageProblem -ImageHeight $imageHeight -PlannedHeight $planned.OutputHeight `
                    -HeightAfter $afterPlan.OutputHeight -What $theCapture
                if ($problem) { & $addDetail $problem }
            }
            catch {
                Write-Verbose "Could not check the height of the one tall image: $($_.Exception.Message)"
            }
        }
        return
    }

    $truncationMessage = "Page truncated at $maxScrollSegments segments (raise -MaxScrollSegments to capture more)."
    $truncationNoted = $false
    if ($segmentCount -gt $maxScrollSegments) {
        $segmentCount = $maxScrollSegments
        & $addDetail $truncationMessage
        $truncationNoted = $true
    }

    if ($scrolls -and $segmentCount -gt 1 -and $viewportHeight -gt 0) {
        $recheckDone = $false
        for ($segment = 0; $segment -lt $segmentCount; $segment++) {
            if (Test-StopRequested) {
                Add-StopDetail -Item $Item
                break
            }
            $offset = [int]([Math]::Round($segment * $viewportHeight))
            [void](Invoke-CdpEval -Expression "window.__vouchTarget.to($offset)" -TimeoutSec 10)
            if (-not (Wait-Interruptible -Milliseconds $scrollSettleMs)) {
                Add-StopDetail -Item $Item
                break
            }

            # Lazy-loading pages grow after the first scroll; re-measure once only.
            if (-not $recheckDone) {
                $recheckDone = $true
                try {
                    $grownHeight = [double](Invoke-CdpEval -Expression 'window.__vouchTarget.measure().total' -TimeoutSec 10)
                    if ($grownHeight -gt 0) {
                        $recomputed = [int][Math]::Ceiling($grownHeight / $viewportHeight)
                        if ($recomputed -gt $segmentCount) {
                            if ($recomputed -gt $maxScrollSegments) {
                                $recomputed = $maxScrollSegments
                                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                                if (-not $truncationNoted) {
                                    & $addDetail $truncationMessage
                                    $truncationNoted = $true
                                }
                            }
                            $segmentCount = $recomputed
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not re-measure the page height: $($_.Exception.Message)"
                }
            }

            $segmentUrl = if ($BrowserErrorPage) { $Item.FinalUrl } else { Get-CurrentPageUrl }
            & $shoot ($segment + 1) $segmentCount $segmentUrl $null
        }

        try { [void](Invoke-CdpEval -Expression 'window.__vouchTarget.to(0)' -TimeoutSec 10) }
        catch { Write-Verbose "Could not scroll back to the top: $($_.Exception.Message)" }
    }
    else {
        if (Test-StopRequested) {
            Add-StopDetail -Item $Item
            return
        }
        & $shoot 1 1 $Item.FinalUrl $null
    }
}

function Get-TallImageProblem {
    <#
        Checks one tall page image after it was taken. Its height must be what was
        planned (the document's height x pixel ratio x zoom), and the document must not
        have grown since: lazy content that loads during the capture makes the page
        longer than the image, whose bottom then misses it. 2 px are allowed for
        rounding. Returns the detail text, or '' when the image is whole. Pure.
    #>
    param(
        [Parameter(Mandatory)][int]$ImageHeight,
        [Parameter(Mandatory)][int]$PlannedHeight,
        [int]$HeightAfter = 0,
        [string]$What = 'the capture'
    )
    $expected = [Math]::Max($PlannedHeight, $HeightAfter)
    if ([Math]::Abs($ImageHeight - $PlannedHeight) -le 2 -and $HeightAfter -le $ImageHeight + 2) { return '' }
    return ("The one tall image of {0} is {1} pixels high, but the page measured {2} pixels; content that loaded or changed while it was taken may be missing from it." -f
        $What, $ImageHeight.ToString([System.Globalization.CultureInfo]::InvariantCulture), $expected.ToString([System.Globalization.CultureInfo]::InvariantCulture))
}

function Invoke-CaptureItem {
    <#
        Captures one page in the tab the CDP socket is connected to: navigate, wait until
        ready (and for the page's wait-for element), check for errors and sign-in
        redirects, then run the page's actions in order - clicks, waits and captures, so
        "click tab A, capture, click tab B, capture" gives one set of screenshots per tab.
        Never throws: whatever goes wrong is recorded on the item, because one failing
        page must not stop a run.
        Pass -Item to fill a record the caller already holds (Invoke-Main adds it to the
        run before visiting the page); otherwise a new one is made. Returns the item.
    #>
    param(
        # One row from Import-CaptureDefinition or one page from ConvertTo-CaptureDefinition.
        [Parameter(Mandatory)][object]$Definition,
        # From Resolve-RunSettings, or Get-PageSettings for the page's own overrides.
        [Parameter(Mandatory)][object]$Settings,
        # Run-wide capture values for Add-ItemCapture (RunId, Format, ImagesDir, ...).
        [Parameter(Mandatory)][hashtable]$CaptureContext,
        # Only for the "[n/total]" progress line.
        [int]$ItemCount = 1,
        [object]$Item = $null
    )

    if ($null -eq $Item) { $Item = New-CaptureItem -Definition $Definition }
    $navigationTimeoutSec = $Settings.NavigationTimeoutSec
    $settleSeconds = $Settings.SettleSeconds
    $script:EventPageId = if ($Definition.PSObject.Properties['Id']) { [string]$Definition.Id } else { '' }
    $policy = Get-NotReadyPolicy -Settings $Settings
    # Ends the page early (stopped, or skipped by the person) with its summary line.
    $endPage = {
        param([string]$Why)
        Write-RowStatus -Message "    $($Item.Status) - $($Item.Captures.Count) capture(s) - $Why" -Status $Item.Status
    }

    Write-Host ("[{0}/{1}] {2} - {3}" -f $Definition.Index, $ItemCount, $Definition.Name, $Definition.Url)

    $captureMode = Get-PageCaptureMode -Settings $Settings
    $Item.CaptureArea = $captureMode.Area
    $Item.ZoomPercent = $captureMode.ZoomPercent

    try {
        # The zoom goes on before the page loads, so the page lays itself out once, at
        # the zoomed size. It is worked out from the window's size, so a window that will
        # be captured is maximised first - Set-EdgeForeground would only do that right
        # before the screenshot. A page at 100% after a zoomed one gets the zoom removed.
        try {
            if ($captureMode.ZoomPercent -ne 100) {
                if ($captureMode.Area -ne 'page') {
                    $currentTitle = ''
                    try { $currentTitle = [string](Invoke-CdpEval -Expression 'document.title' -TimeoutSec 10) }
                    catch { Write-Verbose "Could not read the page title: $($_.Exception.Message)" }
                    Set-EdgeWindowMaximized -ExpectedTitle $currentTitle
                }
                Set-PageZoom -Percent $captureMode.ZoomPercent
            }
            elseif ($script:PageZoomPercent -ne 100) {
                Clear-PageZoom
            }
        }
        catch {
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            $Item.Details.Add("The page zoom could not be set to $($captureMode.ZoomPercent)%, so the page may be shown at another size: $($_.Exception.Message)")
        }
        # A zoom lost before this page started is not this page's concern: it was just set anew.
        $script:PageZoomLost = 0

        Set-NavigationMarker
        $navigation = Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $Definition.Url } -TimeoutSec $navigationTimeoutSec
        $browserErrorPage = $false
        if ($null -ne $navigation -and $navigation.PSObject.Properties['errorText'] -and
            -not [string]::IsNullOrWhiteSpace([string]$navigation.errorText)) {
            $errorText = [string]$navigation.errorText
            $Item.Status = 'FAILED'
            if ($errorText -eq 'net::ERR_HTTP_RESPONSE_CODE_FAILURE') {
                # An HTTP error with an empty body: Edge shows its own error page
                # instead, which is evidence like any other error page.
                $browserErrorPage = $true
                $Item.Details.Add("The server returned an HTTP error with an empty body ($errorText). The browser's error page is captured below as evidence.")
            }
            else {
                $Item.Details.Add("The page could not be loaded: $errorText")
                Write-RowStatus -Message "    FAILED - $errorText" -Status 'FAILED'
                return $Item
            }
        }

        if (-not (Wait-PageReady -TimeoutSec $navigationTimeoutSec)) {
            $outcome = 'stopped'
            if (-not (Test-StopRequested)) {
                $outcome = Resolve-PageNotReady -Item $Item -Awaited 'finish loading' -WaitedSec $navigationTimeoutSec -Policy $policy `
                    -Recheck { param($Seconds) Wait-PageReady -TimeoutSec $Seconds -SameDocumentGraceSeconds 0 }
            }
            if ($outcome -eq 'stopped') { Add-StopDetail -Item $Item; & $endPage 'stopped by the user'; return $Item }
            if ($outcome -eq 'skipped') { & $endPage 'skipped by the user'; return $Item }
        }

        if (-not (Wait-Interruptible -Milliseconds ([int]($settleSeconds * 1000)))) {
            Add-StopDetail -Item $Item; & $endPage 'stopped by the user'; return $Item
        }

        # Chromium exposes the HTTP status of the main document on the
        # PerformanceNavigationTiming entry; older builds return 0. Read again after a
        # sign-in prompt opened the page a second time.
        $httpReported = @{ Done = $false }
        $readPageState = {
            try {
                $statusValue = Invoke-CdpEval -Expression "(performance.getEntriesByType('navigation')[0]||{}).responseStatus||0" -TimeoutSec 10
                if ($null -ne $statusValue) { $Item.HttpStatus = [int]$statusValue }
            }
            catch {
                $Item.Details.Add("The HTTP status could not be read from the page: $($_.Exception.Message)")
            }

            if ($Item.HttpStatus -ge 400 -and -not $httpReported.Done) {
                $httpReported.Done = $true
                $Item.Status = 'FAILED'
                $Item.Details.Add("The server returned HTTP $($Item.HttpStatus). The error page is captured below as evidence.")
            }

            # Edge's error page lives at chrome-error://; the browser stayed on the
            # requested URL, so record that rather than report a redirect.
            $Item.FinalUrl = if ($browserErrorPage) { $Definition.Url } else { Get-CurrentPageUrl }
        }
        & $readPageState
        $signInDetail = Get-SignInDetail -RequestedUrl $Definition.Url -FinalUrl $Item.FinalUrl -BrowserErrorPage $browserErrorPage

        # A sign-in page with onNotReady "prompt": the person signs in in the Edge window
        # and says so; the page is then opened again ONCE. A page that still asks for a
        # sign-in keeps the usual warning - never a loop.
        if ($signInDetail -and $policy.OnNotReady -eq 'prompt') {
            $where = if ($signInDetail -like 'Redirected to a sign-in page*') { "a sign-in page ($(([Uri]$Item.FinalUrl).AbsolutePath))" } else { "another site ($(Get-OriginFromUrl -Url $Item.FinalUrl))" }
            $message = "Edge was sent to $where instead of this page, so it probably needs you to sign in. Sign in in the Edge window " +
                '(including any MFA prompt), then click Continue: Vouch opens the page again and captures it. Skip this page leaves it out.'
            while ($true) {
                $answer = Request-UserDecision -Kind 'signIn' -Title 'Sign-in needed' -Message $message -PageName ([string]$Item.Name) `
                    -Default 'Continue' -TimeoutSec $policy.PromptTimeoutSec
                if (Test-StopRequested) { Add-StopDetail -Item $Item; & $endPage 'stopped by the user'; return $Item }
                if (-not $answer.Prompted) { break }
                if ($answer.Decision -eq 'Wait') {
                    # A stop during the wait ends the page; it is not asked again.
                    if (Wait-Interruptible -Milliseconds ([Math]::Max(1, [int]$answer.WaitSeconds) * 1000)) { continue }
                    Add-StopDetail -Item $Item; & $endPage 'stopped by the user'; return $Item
                }
                if ($answer.Decision -eq 'Skip') {
                    if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                    $Item.Details.Add("Skipped by the user: the page asked for a sign-in. $signInDetail")
                    & $endPage 'skipped by the user'
                    return $Item
                }
                # Continue (also when nobody answered: opening the page again costs little).
                if ((Get-CurrentPageUrl) -ne $Definition.Url) {
                    Set-NavigationMarker
                    [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $Definition.Url } -TimeoutSec $navigationTimeoutSec)
                    if (-not (Wait-PageReady -TimeoutSec $navigationTimeoutSec) -and -not (Test-StopRequested)) {
                        if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                        $Item.Details.Add("The page did not finish loading within $navigationTimeoutSec seconds after the sign-in; it was captured in whatever state it had reached.")
                    }
                    if (-not (Wait-Interruptible -Milliseconds ([int]($settleSeconds * 1000)))) {
                        Add-StopDetail -Item $Item; & $endPage 'stopped by the user'; return $Item
                    }
                }
                & $readPageState
                $signInDetail = Get-SignInDetail -RequestedUrl $Definition.Url -FinalUrl $Item.FinalUrl -BrowserErrorPage $browserErrorPage
                break
            }
        }
        $signInShown = [bool]$signInDetail
        if ($signInShown) {
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            $Item.Details.Add($signInDetail)
        }

        # The page's wait-for element (defaults.waitFor or its override): the page is
        # only ready when it shows. Not on an error page or a sign-in page, which will
        # never show it - waiting the full timeout there would only delay the run.
        $readySelector = if ($Settings.PSObject.Properties['WaitFor']) { [string]$Settings.WaitFor } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($readySelector) -and $Item.Status -ne 'FAILED' -and -not $signInShown) {
            $outcome = 'ready'
            try {
                if (-not (Wait-PageElement -Selector $readySelector -TimeoutSec $navigationTimeoutSec)) {
                    $outcome = 'stopped'
                    if (-not (Test-StopRequested)) {
                        $outcome = Resolve-PageNotReady -Item $Item -Awaited "show '$readySelector'" -WaitedSec $navigationTimeoutSec -Policy $policy `
                            -Recheck { param($Seconds) Wait-PageElement -Selector $readySelector -TimeoutSec $Seconds }
                    }
                }
            }
            catch {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                $Item.Details.Add("Vouch could not wait for '$readySelector': $($_.Exception.Message)")
            }
            if ($outcome -eq 'stopped') { Add-StopDetail -Item $Item; & $endPage 'stopped by the user'; return $Item }
            if ($outcome -eq 'skipped') { & $endPage 'skipped by the user'; return $Item }
        }

        $actions = Get-DefinitionActionList -Definition $Definition
        $captureCount = @($actions | Where-Object { $_['type'] -eq 'capture' }).Count
        $stepCount = $actions.Count - $captureCount
        $explicitAreas = [string[]]@($actions | Where-Object {
                $_['type'] -eq 'capture' -and $_['scroll'] -is [System.Collections.IDictionary] -and
                $_['scroll']['mode'] -eq 'area' -and $_['scroll']['selector'] } |
            ForEach-Object { [string]$_['scroll']['selector'] })
        # CSV rows log each step as it was written in the file ("Click: #go").
        $stepTexts = [System.Collections.Generic.Queue[string]]::new()
        if ($Definition.PSObject.Properties['Steps'] -and $null -ne $Definition.Steps) {
            foreach ($step in $Definition.Steps) { $stepTexts.Enqueue([string]$step.Text) }
        }

        $captureNumber = 0
        $failedSteps = 0
        $stepsSinceUrl = 0
        $failureLine = -1
        $actionEvent = {
            param([int]$Position, [object]$Action, [object]$Entry)
            Write-RunEvent -Type 'action' -Data ([ordered]@{
                pageId = $script:EventPageId; pageIndex = $Item.Index; index = $Position + 1; actionType = [string]$Action['type']
                text = [string]$Entry.Text; ok = [bool]$Entry.Ok; message = [string]$Entry.Message })
        }
        $endedEarly = ''
        for ($position = 0; $position -lt $actions.Count; $position++) {
            if (Test-StopRequested) {
                Add-StopDetail -Item $Item
                $endedEarly = 'stopped by the user'
                break
            }
            $action = $actions[$position]
            if ($action['type'] -eq 'capture') {
                $captureNumber++
                $failureLine = Add-StepFailureDetail -Item $Item -Failed $failedSteps -Total $stepCount -Position $failureLine
                if ($stepsSinceUrl -gt 0 -and -not $browserErrorPage) { $Item.FinalUrl = Get-CurrentPageUrl }
                $stepsSinceUrl = 0
                # The one final capture of a page is implied, as in a CSV row: its errors
                # end the page as they always have. Any other capture is a step of its own.
                $implied = $captureCount -eq 1 -and $position -eq $actions.Count - 1
                $entry = Invoke-PageAction -Action $action -Settings $Settings -Item $Item -CaptureContext $CaptureContext `
                    -CaptureNumber $captureNumber -BrowserErrorPage $browserErrorPage -ExplicitAreas $explicitAreas `
                    -PropagateCaptureError:$implied
                if (-not $implied) { $Item.StepLog.Add($entry) }
                & $actionEvent $position $action $entry
                continue
            }

            $text = ''
            if ($action['type'] -in 'click', 'clickText', 'wait' -and $stepTexts.Count -gt 0) { $text = $stepTexts.Dequeue() }
            $entry = Invoke-PageAction -Action $action -Settings $Settings -Text $text -Item $Item
            $Item.StepLog.Add($entry)
            & $actionEvent $position $action $entry
            $stepsSinceUrl++
            # An action cut short by a stop did not fail; the stop detail says what happened.
            if (-not $entry.Ok -and -not (Test-StopRequested)) { $failedSteps++ }
            if ($entry.PSObject.Properties['EndPage'] -and $entry.EndPage) {
                $endedEarly = 'skipped by the user'
                break
            }
        }
        $failureLine = Add-StepFailureDetail -Item $Item -Failed $failedSteps -Total $stepCount -Position $failureLine
        if ($stepsSinceUrl -gt 0 -and -not $browserErrorPage) { $Item.FinalUrl = Get-CurrentPageUrl }

        $summary = "    $($Item.Status) - $($Item.Captures.Count) capture(s)"
        if ($endedEarly) { $summary += " - $endedEarly" }
        elseif ($Item.Details.Count -gt 0) { $summary += " - $($Item.Details[0])" }
        Write-RowStatus -Message $summary -Status $Item.Status
    }
    catch {
        $Item.Status = 'FAILED'
        $Item.Details.Add("Unhandled error while capturing this item: $($_.Exception.Message)")
        Write-RowStatus -Message "    FAILED - $($_.Exception.Message)" -Status 'FAILED'
    }
    return $Item
}

function Invoke-Main {
    <#
        Runs the whole job (Invoke-CaptureRun) and owns what must outlive it or end with
        it: a run that throws still tells a program following the event log why
        (error + runEnd), and the event log and stop state end with the run, so a later
        page captured in the same session (the Designer) is neither logged into this
        run's file nor stopped by its stop file.
    #>
    param([AllowNull()][System.Collections.IDictionary]$BoundParameters = $null)
    try {
        Invoke-CaptureRun -BoundParameters $BoundParameters
    }
    catch {
        Write-RunFailedEvent -Message $_.Exception.Message
        throw
    }
    finally {
        $script:EventLogPath = ''
        $script:StopRequested = $false
    }
}

function Invoke-CaptureRun {
    <#
        Runs the whole job: verify, login setup, or a capture run.
        Settings come from Resolve-RunSettings. The script passes -BoundParameters
        $PSBoundParameters; the parameter defaults are then the values of the script
        parameters it did not bind, read from the calling scope.
        Without -BoundParameters (the end-to-end tests set the parameters as plain
        variables and call Invoke-Main with no arguments), every value visible in the
        calling scope counts as explicitly chosen, so it would also beat a config file.
        Nothing below the settings resolution reads a script parameter directly.
        With -ConfigPath the pages and settings come from the configuration file, and
        each page runs with its own settings (Get-PageSettings).
    #>
    param([AllowNull()][System.Collections.IDictionary]$BoundParameters = $null)

    $inScope = @{}
    foreach ($definition in Get-RunSettingDefinition) {
        $variable = Get-Variable -Name $definition.Name -ErrorAction SilentlyContinue
        if ($null -ne $variable) { $inScope[$definition.Name] = $variable.Value }
    }
    $split = Split-BoundParameter -InScope $inScope -BoundParameters $BoundParameters
    $boundNames = [string[]]@($split.Bound.Keys)

    # The configuration path is command-line only, so it is known before the file is read.
    $settings = Resolve-RunSettings -BoundParameters $split.Bound -Defaults $split.Defaults -Config $null

    # Events and the stop file first, so that even a run that cannot start says why.
    Initialize-RunEvent -EventLogPath $settings.EventLogPath
    $script:CdpTabId = $settings.TabId

    if ($boundNames -contains 'CsvPath' -and $boundNames -contains 'ConfigPath') {
        throw 'Use either -CsvPath or -ConfigPath, not both. -CsvPath reads the pages from a CSV file; -ConfigPath reads the pages and all settings from a configuration file.'
    }
    $config = $null
    if ($settings.ConfigPath -and -not $settings.Verify) {
        $config = Import-VouchConfig -Path $settings.ConfigPath
        $settings = Resolve-RunSettings -BoundParameters $split.Bound -Defaults $split.Defaults -Config $config
    }

    Assert-Environment

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-NativeInterop

    if ($settings.Verify) {
        # Needs no browser: works on any Windows machine the report is copied to.
        $script:ExitCode = Invoke-VerifyReport -Path $settings.Verify
        return
    }

    $edgePath = Find-EdgeExecutable

    # Absolute, so Edge receives the same path the process lookups search for.
    $profileDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($settings.EdgeProfileDir)

    if ($settings.LoginSetup) {
        Invoke-LoginSetup -EdgePath $edgePath -ProfileDir $profileDir
        $script:ExitCode = 0
        return
    }

    if ($null -ne $config) {
        $sourcePath = (Resolve-Path -LiteralPath $settings.ConfigPath).ProviderPath
        $allDefinitions = [System.Collections.Generic.List[object]]::new()
        foreach ($page in $config['pages']) {
            $allDefinitions.Add((ConvertTo-CaptureDefinition -Page $page -Index ($allDefinitions.Count + 1)))
        }
        if ($allDefinitions.Count -eq 0) {
            throw "The configuration file '$sourcePath' has no pages. Add at least one page under ""pages""."
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $settings.CsvPath -PathType Leaf)) {
            throw "Capture definition CSV not found: $($settings.CsvPath)`nCreate one from captures.sample.csv, or pass -CsvPath."
        }
        $sourcePath = (Resolve-Path -LiteralPath $settings.CsvPath).Path
        $allDefinitions = Import-CaptureDefinition -Path $sourcePath
    }

    $definitions = Select-VouchPage -Definitions @($allDefinitions) -Only $settings.Only
    if ($definitions.Count -eq 0) {
        throw "Every page in '$sourcePath' is switched off (""enabled"": false), so there is nothing to capture."
    }
    $loaded = "Loaded $($definitions.Count) capture item(s) from $sourcePath"
    if ($definitions.Count -lt $allDefinitions.Count) {
        $loaded += " ($($allDefinitions.Count - $definitions.Count) other page(s) not selected or switched off)"
    }
    Write-Host $loaded -ForegroundColor Cyan
    if ($null -ne $config) {
        $inactive = Get-InactiveConfigSetting -Config $config
        if ($inactive.Count -gt 0) {
            Write-Host "WARNING: this version of Vouch does not apply these configuration settings yet, so they have no effect: $($inactive -join ', ')." -ForegroundColor Yellow
        }
    }

    if (-not (Test-Path -LiteralPath $settings.OutputDir)) {
        [void](New-Item -ItemType Directory -Path $settings.OutputDir -Force)
    }
    $resolvedOutputDir = (Resolve-Path -LiteralPath $settings.OutputDir).Path

    $effectiveReportName = $settings.ReportName
    if ([string]::IsNullOrWhiteSpace($effectiveReportName)) {
        $effectiveReportName = "VouchReport_$((Get-Date).ToString('yyyy-MM-dd_HHmmss')).html"
    }
    if ($effectiveReportName -notmatch '(?i)\.html?$') { $effectiveReportName += '.html' }
    $reportPath = Join-Path -Path $resolvedOutputDir -ChildPath $effectiveReportName

    # One folder per report, so a later run never overwrites the images (and with them
    # the hashes) of an earlier one.
    $imagesDir = ''
    if ($settings.SaveImages) {
        $imagesDir = Join-Path -Path $resolvedOutputDir -ChildPath (Join-Path 'images' ([System.IO.Path]::GetFileNameWithoutExtension($effectiveReportName)))
        if (-not (Test-Path -LiteralPath $imagesDir)) {
            [void](New-Item -ItemType Directory -Path $imagesDir -Force)
        }
    }

    $imageExtension = if ($settings.ImageFormat -eq 'png') { 'png' } else { 'jpg' }
    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $captureContext = @{
        RunId      = $script:EventRunId
        Format     = $settings.ImageFormat
        Quality    = $settings.JpegQuality
        Extension  = $imageExtension
        SaveImages = [bool]$settings.SaveImages
        ImagesDir  = $imagesDir
        Screen     = "$($screenBounds.Width)x$($screenBounds.Height)"
    }
    $runStart = [System.DateTimeOffset]::Now
    $items = [System.Collections.Generic.List[object]]::new()
    $captureDesktop = $null
    $desktopNote = 'The signed-in desktop (-UseVirtualDesktop not set)'
    $script:InteractiveRun = Test-InteractiveRun -NoPrompt $settings.NoPrompt
    Write-RunEvent -Type 'runStart' -Data ([ordered]@{
        toolVersion = $script:ToolVersion; pageCount = $definitions.Count; reportPath = $reportPath
        source = $sourcePath; interactive = $script:InteractiveRun; stopFile = (Get-StopFilePath); processId = $PID })

    try {
        if ($settings.UseVirtualDesktop) {
            if ($null -ne (Get-DebugEndpointInfo -Port $settings.DebugPort)) {
                # An Edge that is already running keeps its window on its own desktop.
                $desktopNote = 'No separate virtual desktop: an already running Edge was reused.'
            }
            else {
                Write-Host 'Switching to a separate virtual desktop for the capture...'
                $captureDesktop = New-CaptureDesktop
                $desktopNote = $captureDesktop.Note
            }
            if (-not ($captureDesktop -and $captureDesktop.Verified)) { Write-Host "WARNING: $desktopNote" -ForegroundColor Yellow }
        }

        $versionInfo = Start-EdgeDebug -EdgePath $edgePath -ProfileDir $profileDir -Port $settings.DebugPort
        $script:CdpPort = $settings.DebugPort

        if ($null -ne $captureDesktop -and $captureDesktop.Verified -and -not (Test-EdgeOnCaptureDesktop)) {
            $desktopNote = 'A separate virtual desktop was opened, but Edge did not appear on it; other applications may appear in the taskbar.'
            Write-Host "WARNING: $desktopNote" -ForegroundColor Yellow
        }

        $edgeVersion = 'unknown'
        if ($null -ne $versionInfo -and $versionInfo.PSObject.Properties['Browser']) {
            $edgeVersion = [string]$versionInfo.Browser
        }
        Write-Host "Connected to $edgeVersion"

        $target = Get-CdpPageTarget -Port $settings.DebugPort -WaitSeconds 10
        if ($null -eq $target -or -not $target.PSObject.Properties['webSocketDebuggerUrl']) {
            throw 'Could not obtain a DevTools page target from Edge.'
        }
        Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
        if ($script:LaunchedEdge -and -not $settings.TabId) { Close-OtherPageTargets -Port $settings.DebugPort -KeepId ([string]$target.id) }

        $position = 0
        foreach ($definition in $definitions) {
            # A stop ends the run between pages: the pages not started are not reported.
            if (Test-StopRequested) { break }
            $position++
            # Added before the page is visited, so it is reported whatever happens to it.
            $item = New-CaptureItem -Definition $definition
            $items.Add($item)
            $pageId = if ($definition.PSObject.Properties['Id']) { [string]$definition.Id } else { '' }
            Write-RunEvent -Type 'pageStart' -Data ([ordered]@{
                pageId = $pageId; pageIndex = $definition.Index; index = $position; total = $definitions.Count
                name = [string]$definition.Name; url = [string]$definition.Url })
            $pageSettings = Get-PageSettings -Settings $settings -Definition $definition -Config $config -BoundNames $boundNames
            [void](Invoke-CaptureItem -Definition $definition -Item $item -ItemCount $definitions.Count `
                -Settings $pageSettings -CaptureContext $captureContext)
            Write-RunEvent -Type 'pageEnd' -Data ([ordered]@{
                pageId = $pageId; pageIndex = $item.Index; index = $position; total = $definitions.Count
                status = $item.Status; details = @($item.Details); captureCount = $item.Captures.Count
                finalUrl = [string]$item.FinalUrl; stopped = [bool]$script:StopRequested })
        }
    }
    finally {
        # A zoom must not outlive the run, also when it failed or reused an Edge that
        # stays open. Only over a live connection: a dead one took its zoom with it,
        # and reconnecting just to clear it could open a tab in a reused Edge.
        if (Test-CdpSocketOpen) {
            try { Clear-PageZoom }
            catch { Write-Verbose "Could not remove the page zoom: $($_.Exception.Message)" }
        }
        $script:PageZoomPercent = 100
        $script:InteractiveRun = $false
        Close-CdpSocket
        $script:CdpTabId = ''
        if ($settings.KeepBrowserOpen) {
            if ($script:LaunchedEdge) { Write-Host 'Leaving Edge open (-KeepBrowserOpen).' }
        }
        else {
            Stop-EdgeProcess
        }
        Remove-CaptureDesktop -State $captureDesktop
    }

    $runEnd = [System.DateTimeOffset]::Now
    $okCount = @($items | Where-Object { $_.Status -eq 'OK' }).Count
    $warnCount = @($items | Where-Object { $_.Status -eq 'WARNING' }).Count
    $failCount = @($items | Where-Object { $_.Status -eq 'FAILED' }).Count
    $captureCount = ($items | ForEach-Object { $_.Captures.Count } | Measure-Object -Sum).Sum
    if ($null -eq $captureCount) { $captureCount = 0 }

    $screenResolution = 'unknown'
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $screenResolution = "$($bounds.Width) x $($bounds.Height) (primary display)"
    }
    catch {
        Write-Verbose "Could not read the screen resolution: $($_.Exception.Message)"
    }

    $imageDescription = if ($settings.ImageFormat -eq 'png') { 'PNG (lossless)' } else { "JPEG (quality $($settings.JpegQuality))" }
    $browserInstance = if ($script:ReusedEdge) {
        "Existing Edge instance reused on port $($settings.DebugPort) (not launched by this run)"
    }
    else {
        "Launched by this run on port $($settings.DebugPort) using profile $profileDir"
    }

    $run = [pscustomobject]@{
        StartTime        = $runStart.ToString('yyyy-MM-dd HH:mm:ss')
        EndTime          = $runEnd.ToString('yyyy-MM-dd HH:mm:ss')
        TimeZone         = "$([System.TimeZoneInfo]::Local.DisplayName) (UTC$($runEnd.ToString('zzz')))"
        Computer         = $env:COMPUTERNAME
        User             = "$env:USERDOMAIN\$env:USERNAME"
        OperatingSystem  = (Get-OperatingSystemDescription)
        EdgeVersion      = $edgeVersion
        BrowserInstance  = $browserInstance
        CaptureDesktop   = $desktopNote
        ToolVersion      = $script:ToolVersion
        CsvPath          = $sourcePath
        ImageFormat      = $settings.ImageFormat
        ImageDescription = $imageDescription
        ScreenResolution = $screenResolution
        Total            = $items.Count
        OkCount          = $okCount
        WarnCount        = $warnCount
        FailCount        = $failCount
        CaptureCount     = $captureCount
        RunId            = $captureContext.RunId
        ManifestSha256   = ''
    }

    $manifest = Get-CaptureManifest -Items @($items)
    $run.ManifestSha256 = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($manifest))
    if ($settings.SaveImages) {
        [System.IO.File]::WriteAllText((Join-Path -Path $imagesDir -ChildPath 'SHA256SUMS'), $manifest, [System.Text.UTF8Encoding]::new($false))
    }

    $html = New-HtmlReport -Items @($items) -Run $run
    [System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($false))

    $reportSizeMb = [Math]::Round((Get-Item -LiteralPath $reportPath).Length / 1MB, 1)
    $script:ExitCode = if ($failCount -gt 0) { 2 } elseif ($settings.FailOnWarning -and $warnCount -gt 0) { 3 } else { 0 }

    $summaryPath = ''
    if ($settings.JsonSummary) {
        $summaryPath = [System.IO.Path]::ChangeExtension($reportPath, '.json')
        $json = ConvertTo-RunSummaryJson -Items @($items) -Run $run -ReportPath $reportPath -ExitCode $script:ExitCode
        [System.IO.File]::WriteAllText($summaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Host ''
    if ($script:StopRequested) {
        Write-Host "Stopped by the user after $($items.Count) of $($definitions.Count) page(s)." -ForegroundColor Yellow
    }
    Write-Host "Done. $($items.Count) item(s): $okCount OK, $warnCount warning(s), $failCount failed. $captureCount screenshot(s)." -ForegroundColor Cyan
    if ($settings.SaveImages) { Write-Host "Individual images: $imagesDir" }
    Write-Host "Report: $reportPath ($reportSizeMb MB)" -ForegroundColor Cyan
    if ($summaryPath) { Write-Host "Summary: $summaryPath" }
    Remove-StopFile
    Write-RunEvent -Type 'runEnd' -Data ([ordered]@{
        exitCode = $script:ExitCode; reportPath = $reportPath; jsonSummaryPath = $summaryPath
        counts = [ordered]@{
            pages = $definitions.Count; run = $items.Count; ok = $okCount; warning = $warnCount; failed = $failCount
            notRun = $definitions.Count - $items.Count; captures = [int]$captureCount }
        stopped = [bool]$script:StopRequested })
}

function Initialize-RunEvent {
    <#
        Prepares the progress events and the stop file for one run (-EventLogPath). The
        path is made absolute (the Designer and the run need not share a working folder)
        and its folder created. A stop file left over from an earlier run with the same
        path is removed: it would otherwise stop this run before its first page. The run
        id is made here so every event, the images and the report carry the same one.
        Without a path, events and stops are off.
    #>
    param([AllowEmptyString()][string]$EventLogPath = '')
    $script:EventRunId = [guid]::NewGuid().ToString()
    $script:StopRequested = $false
    $script:EventPageId = ''
    $script:EventLogPath = ''
    if ([string]::IsNullOrWhiteSpace($EventLogPath)) { return }
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EventLogPath)
    try {
        $folder = Split-Path -Path $path -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
        $stale = "$path.stop"
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }
    catch {
        Write-Verbose "Could not prepare the event log '$path': $($_.Exception.Message)"
    }
    $script:EventLogPath = $path
}

function Test-CdpSocketOpen {
    # True only for a DevTools connection that is open now (not closed or aborted).
    return $null -ne $script:CdpSocket -and $script:CdpSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open
}

function Remove-StopFile {
    <#
        Removes the stop file of a run that honoured it, before runEnd, so nothing is
        left behind for the next run or the person to trip over. Only when the stop was
        seen: a file that appears after that moment belongs to nobody yet. Best-effort.
    #>
    if (-not $script:StopRequested) { return }
    $stopFile = Get-StopFilePath
    if (-not $stopFile) { return }
    try { [System.IO.File]::Delete($stopFile) }
    catch { Write-Verbose "Could not remove the stop file '$stopFile': $($_.Exception.Message)" }
}

function Write-RunFailedEvent {
    <#
        The events of a run that ended with an error (exit code 1): what went wrong and
        a runEnd, so a program following the event log is never left waiting for an end
        that does not come. Called by Invoke-Main when the run throws.
    #>
    param([AllowEmptyString()][string]$Message = '')
    Write-RunEvent -Type 'error' -Data ([ordered]@{ message = $Message })
    Remove-StopFile
    Write-RunEvent -Type 'runEnd' -Data ([ordered]@{
        exitCode = 1; reportPath = ''; jsonSummaryPath = ''; counts = $null; stopped = [bool]$script:StopRequested })
}

$transcribing = Start-RunLog -Directory (Get-RunLogDirectory -BoundParameters $PSBoundParameters -LogDir $LogDir -ConfigPath $ConfigPath)
try {
    Invoke-Main -BoundParameters $PSBoundParameters
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($null -ne $_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
    $script:ExitCode = 1
}
finally {
    if ($transcribing) {
        Write-Host "Exit code: $($script:ExitCode)"
        try { [void](Stop-Transcript) } catch { Write-Verbose 'Transcript already stopped.' }
    }
}
exit $script:ExitCode

#endregion
