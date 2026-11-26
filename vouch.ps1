#Requires -Version 7

<#
.SYNOPSIS
    Captures audit-evidence screenshots of web application configuration pages.

.DESCRIPTION
    Drives Microsoft Edge through the Chrome DevTools Protocol (CDP) and takes REAL
    screen captures (GDI CopyFromScreen) of the primary display, so the Windows taskbar
    clock is part of every image. Long pages are captured as a series of viewport
    segments. Everything is assembled into a single self-contained HTML report with
    base64-embedded images (or, with -LinkImages, a report that links to the image
    files next to it). -CaptureArea can narrow the images to the Edge window or to
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

.PARAMETER ReportName
    File name of the report (.html is added when missing). Default:
    VouchReport_<date>_<time>.html. May contain the tokens {report} (the default name),
    {title}, {date} (yyyy-MM-dd), {time} (HHmmss), {period} and {classification}.
    Only the name, not a path: characters Windows forbids in a file name become "_",
    and spaces and dots at its beginning and end are dropped (the run says so).
    A report of the same name in the output folder is replaced.

.PARAMETER EdgeProfileDir
    The Edge profile the run uses (sign-ins are kept there). Default:
    %LOCALAPPDATA%\Vouch\EdgeProfile, the profile -LoginSetup prepares.

.PARAMETER DebugPort
    The local port Edge's debugging connection uses, 1024 to 65535 (default 9222). An
    Edge already listening there is reused and left open.

.PARAMETER NavigationTimeoutSec
    How long to wait for each page to finish loading, 5 to 600 seconds (default 30).

.PARAMETER SettleSeconds
    Extra time after a page has loaded (and after each click) before anything is
    captured, 0 to 120 seconds (default 2), for content that appears late.

.PARAMETER ScrollSettleSeconds
    Time after each scroll before the next screenshot, 0 to 120 seconds (default 1).

.PARAMETER MaxScrollSegments
    The most screenshots taken while scrolling one page, 1 to 500 (default 30). A page
    that is longer is reported with a warning.

.PARAMETER ImageFormat
    jpeg (default, smaller) or png (lossless).

.PARAMETER JpegQuality
    JPEG quality, 1 to 100 (default 85).

.PARAMETER SaveImages
    Also save every screenshot as a file in images\<report name>\ next to the report,
    with a SHA256SUMS file. -LinkImages always saves them.

.PARAMETER KeepBrowserOpen
    Leave the Edge this run started open at the end (an Edge that was already running
    is always left open).

.PARAMETER ReportTitle
    The report's title and main heading. Default: Audit Evidence Report.

.PARAMETER Classification
    Marks the report Public, Internal, Private or Confidential: a coloured banner at the
    top and bottom, repeated on every printed page. Empty (default): no marking.

.PARAMETER LogoPath
    A company logo (PNG, JPEG, GIF or SVG file, at most 1 MB) shown at the top of the
    report. It is copied into the report. A missing or unreadable logo is a warning; the
    report is still written without it.

.PARAMETER CompanyName
    The company name shown at the top of the report.

.PARAMETER CompanyDetails
    More lines about the company (address, engagement, ...), shown under its name. Line
    breaks are kept; a configuration file (report.company.details) is the easier place
    for several lines.

.PARAMETER Description
    What this evidence is for, shown in the report's run details.

.PARAMETER Origin
    Where the capture was made (for example the office, the system or the request it
    answers), shown in the run details.

.PARAMETER GeneratedBy
    Who produced the report, shown in the run details. Default: the Windows user that
    runs Vouch.

.PARAMETER PeriodFrom
    Start of the period the evidence covers, shown exactly as typed (for example
    2026-07-01). This is the period under audit, not the time of the captures, which
    the report records separately.

.PARAMETER PeriodTo
    End of the period the evidence covers, shown exactly as typed.

.PARAMETER PeriodLabel
    A name for the period (for example Q3 2026), shown with the dates.

.PARAMETER Account
    The account used to sign in to the applications (for example svc-audit@example.com),
    shown in the run details, on each page and inside each image file. A configuration
    file can name another account for a page (overrides.account); this switch beats both.

.PARAMETER NoIndex
    Leave out the contents list near the top of the report.

.PARAMETER LinkImages
    Keep the screenshots as separate files (images\<report name>\) that the report links
    to, instead of copying them into the report. The report is much smaller, but the
    image folder must always travel with it (or use -Zip). -Verify checks both forms.

.PARAMETER Zip
    After the report is written, put the report, the JSON summary (if any) and the image
    folder (if any) into one zip file in the output folder, ready to attach to a
    workpaper. Extracting it gives a working report.

.PARAMETER ZipName
    Name of the zip file (default {report}.zip). Tokens: {report} (the report's name),
    {title}, {date} (yyyy-MM-dd), {time} (HHmmss), {period}, {classification}. An existing
    file is never replaced: a number is added instead.

.PARAMETER OpenReport
    Open the report in the default browser when everything is finished. Only when a
    person started the run; never in a scheduled or -NoPrompt run.

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
    Write a raw transcript of the console (everything the window shows, including errors
    that stop the run before it starts) to vouch_<date>_<time>.log in this folder. Meant
    for troubleshooting unattended runs; Install-VouchSchedule.ps1 sets it. This is not
    the capture log (see -NoCaptureLog), which every capture run writes next to its
    report.

.PARAMETER NoCaptureLog
    Do not write the capture log. By default every capture run writes <report name>.log
    next to the report: a readable, time-stamped account of the run written while it
    happens (each page, action, question and answer, image with its SHA-256, warning,
    and the result), and it goes into the zip with the report. Not the same as -LogDir,
    which keeps a raw console transcript.

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

.PARAMETER Designer
    Open the Vouch Designer instead of capturing: a window beside your screen where you
    add pages, choose what to click and capture, set the report and output options, and
    save a configuration file. Double-clicking Vouch-Designer.cmd does the same. Give
    -ConfigPath as well to open that file at the start, and -EdgeProfileDir / -DebugPort
    when the audit profile or port is not the usual one (the Designer opens or reuses that
    Edge, and keeps its own window's profile apart from it); -KeepBrowserOpen leaves an
    Edge the Designer opened open when it stops. Needs the designer folder next to
    vouch.ps1; every other use of vouch.ps1 works without it.

.PARAMETER DesignerPort
    The local port the Designer listens on (only this computer can reach it). Default 0:
    a free port is chosen.

.EXAMPLE
    .\vouch.ps1 -Designer -ConfigPath .\captures.json

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

    [string]$TabId = '',

    [string]$ReportTitle = '',

    [ValidateSet('', 'Public', 'Internal', 'Private', 'Confidential')]
    [string]$Classification = '',

    [string]$LogoPath = '',

    [string]$CompanyName = '',

    [string]$CompanyDetails = '',

    [string]$Description = '',

    [string]$Origin = '',

    [string]$GeneratedBy = '',

    [string]$PeriodFrom = '',

    [string]$PeriodTo = '',

    [string]$PeriodLabel = '',

    [string]$Account = '',

    [switch]$NoIndex,

    [switch]$LinkImages,

    [switch]$Zip,

    [string]$ZipName = '',

    [switch]$OpenReport,

    [switch]$NoCaptureLog,

    [switch]$Designer,

    [ValidateRange(0, 65535)]
    [int]$DesignerPort = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion       = '2.0.0'
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
# The capture log of the current run ('' = none), whether every line reached it, and
# whether its write failure was already reported on the console.
$script:CaptureLogPath     = ''
$script:CaptureLogComplete = $true
$script:CaptureLogWarned   = $false
# The page whose details become "detail" events, and how many of them were written.
$script:EventItem          = $null
$script:EventDetailCount   = 0

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
                captureLog    = @{ Type = 'bool'; Default = $true }
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
        [int]$ZoomPercent = 100,
        # The account the application was signed in with ('' when none was named).
        [AllowEmptyString()][string]$Account = ''
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
        Account       = $Account
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
    # Empty input is allowed: a 0-byte image file or an empty <style> has a hash too.
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
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

function Test-RunEventSink {
    # Whether anything receives progress events (an event file or a capture log).
    return -not ([string]::IsNullOrEmpty($script:EventLogPath) -and [string]::IsNullOrEmpty($script:CaptureLogPath))
}

function Add-RunFileText {
    <#
        Appends text to a file that another program may be reading at the same time: the
        file is opened, appended, flushed and closed per call, with read/write/delete
        sharing, so every line is on disk as soon as it is written and a reader that keeps
        the file open blocks nothing. A reader that opens the file without write sharing
        (File.ReadAllText does) locks it for a moment; a few short retries keep the text.
        Throws when the text could not be written.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    for ($attempt = 1; ; $attempt++) {
        try {
            $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
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

function Write-RunEvent {
    <#
        One progress event, built once and handed to every sink that is on:
        - the event file (-EventLogPath): one JSON object per line (NDJSON, UTF-8
          without BOM, LF), for the Designer and other programs following the run;
        - the capture log (Start-CaptureLog): the same event as readable lines.
        Both are written as the run happens, so they, and the report built from the
        same items, cannot disagree. Details a page gained since the last event are
        written first (as "detail" events), so a warning appears where it happened.
        Events are a convenience: a failure to write one never fails the run. With no
        sink on this returns at once.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [AllowNull()][System.Collections.IDictionary]$Data = $null
    )
    $eventPath = $script:EventLogPath
    $logPath = $script:CaptureLogPath
    if ([string]::IsNullOrEmpty($eventPath) -and [string]::IsNullOrEmpty($logPath)) { return }
    if ($Type -in 'navigation', 'action', 'capture', 'prompt', 'promptResult', 'pageEnd', 'error') { Write-PendingDetailEvent }

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

    if (-not [string]::IsNullOrEmpty($eventPath)) {
        try { Add-RunFileText -Path $eventPath -Text ((ConvertTo-Json -InputObject $record -Compress -Depth 8) + "`n") }
        catch { Write-Verbose "Could not write the '$Type' event to '$eventPath': $($_.Exception.Message)" }
    }
    if (-not [string]::IsNullOrEmpty($logPath)) {
        try {
            $lines = Format-CaptureLogEntry -Record $record
            if ($lines.Count -gt 0) { Add-RunFileText -Path $logPath -Text (($lines -join "`r`n") + "`r`n") }
        }
        catch { Register-CaptureLogFailure -Message $_.Exception.Message }
    }
}

function Write-PendingDetailEvent {
    <#
        The details (warnings, notes) the current page gained since the last event, one
        "detail" event each. Details are added in many places of the capture code; the
        event writer collects them before each page event instead, so none is missed and
        each is logged once, close to when it happened.
    #>
    $item = $script:EventItem
    if ($null -eq $item -or -not $item.PSObject.Properties['Details']) { return }
    while ($script:EventDetailCount -lt $item.Details.Count) {
        $text = [string]$item.Details[$script:EventDetailCount]
        $script:EventDetailCount++
        Write-RunEvent -Type 'detail' -Data ([ordered]@{
            pageId = $script:EventPageId; pageIndex = $item.Index; status = [string]$item.Status; text = $text })
    }
}

function Start-CaptureLog {
    <#
        Starts the capture log of one run: the readable record of what the run did,
        written next to the report while the run happens (Write-RunEvent), so a crash or
        a stop still leaves a truthful log up to that point. A log that cannot be
        created is a warning, never a reason to stop the run. '' switches it off.
    #>
    param([AllowEmptyString()][string]$Path = '')
    $script:CaptureLogPath = ''
    $script:CaptureLogComplete = $true
    $script:CaptureLogWarned = $false
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        # A new, empty file: a report of the same name replaces the earlier one, and so does its log.
        [System.IO.File]::WriteAllBytes($Path, [byte[]]@())
        $script:CaptureLogPath = $Path
    }
    catch {
        Register-CaptureLogFailure -Message $_.Exception.Message -Path $Path
    }
}

function Register-CaptureLogFailure {
    <#
        A line of the capture log could not be written. The run goes on; the person is
        told once on the console, and the run's summary says the log is incomplete.
    #>
    param(
        [AllowEmptyString()][string]$Message = '',
        [AllowEmptyString()][string]$Path = $script:CaptureLogPath
    )
    $script:CaptureLogComplete = $false
    if ($script:CaptureLogWarned) { return }
    $script:CaptureLogWarned = $true
    Write-Host "WARNING: the capture log '$Path' could not be written ($Message). The run goes on, but the capture log will be incomplete." -ForegroundColor Yellow
}

function Format-CaptureLogEntry {
    <#
        One event as lines of the capture log: plain text an auditor reads top to
        bottom. Every entry starts with the local time and its UTC offset; lines of a
        page are indented under it; text that has line breaks of its own (a message, a
        note) continues on indented lines without a time, so each entry stays one block.
        Returns the lines (no line ends).
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $get = { param($Name) if ($Record.Contains($Name) -and $null -ne $Record[$Name]) { $Record[$Name] } else { '' } }
    $stamp = [string](& $get 'ts')
    $when = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParseExact($stamp, 'yyyy-MM-ddTHH:mm:ss.fffzzz', $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$when)) {
        $stamp = $when.ToString('yyyy-MM-dd HH:mm:ss.fff zzz', $invariant)
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$Text, [int]$Indent = 0)
        $parts = @(([string]$Text) -split "`r`n|`n|`r")
        $lines.Add("$stamp  $(' ' * $Indent)$($parts[0])")
        for ($i = 1; $i -lt $parts.Count; $i++) { $lines.Add("$(' ' * ($stamp.Length + 2 + $Indent + 4))$($parts[$i])") }
    }
    $areaText = @{ screen = 'full screen'; window = 'Edge window only'; page = 'page content only' }

    switch ([string](& $get 'type')) {
        'runStart' {
            & $add "Vouch $(& $get 'toolVersion') capture log - run $(& $get 'runId')"
            & $add 'This log is written line by line while the run happens; the report is made at the end.'
            & $add "Computer: $(& $get 'computer')"
            & $add "Windows user: $(& $get 'user')"
            if (& $get 'account') { & $add "Account: $(& $get 'account')" }
            & $add "Definition file: $(& $get 'source')"
            & $add "Output folder: $(& $get 'outputDir')"
            & $add "Report: $(& $get 'reportFile')"
            $area = [string](& $get 'captureArea')
            $areaName = if ($areaText.ContainsKey($area)) { $areaText[$area] } else { $area }
            & $add "Capture defaults: $areaName, zoom $(& $get 'zoomPercent')%, $(& $get 'imageFormat')"
            & $add "Classification: $(if (& $get 'classification') { & $get 'classification' } else { 'none' })"
            if ([bool](& $get 'interactive')) { & $add 'Mode: interactive - the Vouch dialog may ask for decisions' }
            else { & $add 'Mode: unattended - nothing is asked; pages that are not ready are captured with a warning' }
            & $add "Pages to capture: $(& $get 'pageCount')"
        }
        'pageStart' {
            & $add ("Page {0} of {1}: {2} ""{3}"" - {4}" -f (& $get 'index'), (& $get 'total'), (& $get 'pageId'), (& $get 'name'), (& $get 'url'))
        }
        'navigation' {
            $http = if ([int](& $get 'httpStatus') -gt 0) { "HTTP $(& $get 'httpStatus')" } else { 'HTTP status not reported by the browser' }
            & $add "Opened: $(& $get 'finalUrl') ($http)" 2
        }
        'action' {
            $text = if (& $get 'text') { & $get 'text' } else { & $get 'actionType' }
            $message = [string](& $get 'message')
            if ([bool](& $get 'ok')) { & $add ("Action {0} {1}: ok{2}" -f (& $get 'index'), $text, $(if ($message) { " - $message" } else { '' })) 2 }
            else { & $add ("Action {0} {1}: FAILED - {2}" -f (& $get 'index'), $text, $message) 2 }
        }
        'capture' {
            $label = if (& $get 'label') { " ""$(& $get 'label')""" } else { '' }
            $area = [string](& $get 'area')
            $size = if ([int](& $get 'width') -gt 0) { ", $(& $get 'width')x$(& $get 'height') px" } else { '' }
            & $add ("Image {0}: capture {1}{2}, segment {3} of {4}, {5}, zoom {6}%{7}, SHA-256 {8}" -f (& $get 'fileName'), (& $get 'captureNumber'), $label,
                (& $get 'segment'), (& $get 'segmentCount'), $(if ($areaText.ContainsKey($area)) { $areaText[$area] } else { $area }), (& $get 'zoomPercent'), $size, (& $get 'sha256')) 2
        }
        'prompt' {
            & $add "Question in the Vouch dialog ($(& $get 'kind')): $(& $get 'title')" 2
            & $add ([string](& $get 'message')) 4
            & $add "If nobody answers within $(& $get 'timeoutSec') seconds: $(& $get 'defaultDecision')" 4
        }
        'promptResult' {
            $decision = [string](& $get 'decision')
            $answer = switch ($decision) {
                'Wait' { "Wait $(& $get 'waitSeconds') seconds more" }
                'Skip' { 'Skip this page' }
                default { $decision }
            }
            if (-not [bool](& $get 'shown')) { & $add "The Vouch dialog could not be shown; nobody answered, so Vouch went on with: $answer" 2 }
            elseif ([bool](& $get 'timedOut')) { & $add "Nobody answered in time, so Vouch went on with: $answer" 2 }
            else { & $add "Answer: $answer" 2 }
        }
        'detail' {
            $kind = switch ([string](& $get 'status')) { 'OK' { 'Note' } 'WARNING' { 'Warning' } default { 'Problem' } }
            & $add "${kind}: $(& $get 'text')" 2
        }
        'pageEnd' {
            $stopped = if ([bool](& $get 'stopped')) { ' - stopped by the user' } else { '' }
            & $add ("Page {0} of {1} done: {2}, {3} image(s){4}" -f (& $get 'index'), (& $get 'total'), (& $get 'status'), (& $get 'captureCount'), $stopped)
        }
        'archive' {
            & $add "Creating archive $(& $get 'zipPath')"
            & $add 'The copy of this log inside the archive ends with this line; the lines after it are only in the log file next to the report.' 2
        }
        'error' {
            & $add "ERROR: $(& $get 'message')"
        }
        'runEnd' {
            $counts = & $get 'counts'
            if ($counts -is [System.Collections.IDictionary]) {
                & $add ("Run finished: {0} of {1} page(s) run - {2} OK, {3} warning(s), {4} failed, {5} not run; {6} image(s)" -f
                    $counts['run'], $counts['pages'], $counts['ok'], $counts['warning'], $counts['failed'], $counts['notRun'], $counts['captures'])
            }
            else { & $add 'Run ended with an error; no report was made.' }
            & $add "Stopped by the user: $(if ([bool](& $get 'stopped')) { 'yes' } else { 'no' })"
            if (& $get 'manifestSha256') { & $add "Manifest SHA-256: $(& $get 'manifestSha256')" }
            if (& $get 'reportPath') { & $add "Report: $(& $get 'reportPath')" }
            if ($counts -is [System.Collections.IDictionary]) {
                & $add "JSON summary: $(if (& $get 'jsonSummaryPath') { & $get 'jsonSummaryPath' } else { 'not written' })"
            }
            if (& $get 'zipPath') { & $add "Zip: $(& $get 'zipPath') (SHA-256 $(& $get 'zipSha256'))" }
            & $add "Exit code: $(& $get 'exitCode')"
            if ($Record.Contains('elapsedSec')) {
                & $add ("Elapsed: {0}" -f [TimeSpan]::FromSeconds([double](& $get 'elapsedSec')).ToString('hh\:mm\:ss', $invariant))
            }
            & $add 'End of capture log.'
        }
        default {
            & $add "Event: $(& $get 'type')"
        }
    }
    return , [string[]]$lines
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
        try { $title = [string](Invoke-CdpEval -Expression 'document.title' -TimeoutSec 2) }
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
        marks the element the person picked with a temporary property holding a one-time
        token; "mark" returns it, so a recorded step is only kept when THIS search lands
        on that very element - not merely on one that looks the same.
    #>
    return @'
function vouchDescribe(entry, el, exact) {
  var text = String(el.innerText || el.textContent || el.value || '').replace(/\s+/g, ' ').trim();
  var mark = typeof el.__vouchPickMark === 'string' ? el.__vouchPickMark.substring(0, 64) : '';
  return { found: true, tag: el.tagName.toLowerCase(), id: el.id || '', text: text.substring(0, 200),
    frame: entry.frame ? vouchFrameName(entry.frame) : '', exact: exact, visible: vouchVisible(entry, el), mark: mark };
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
        [int]$ZoomPercent = 100,
        # For a linked report: no base64 copy (Base64 = ''); the image is in its file.
        [switch]$NoBase64
    )

    # PowerShell hands a Nullable parameter over already unwrapped.
    $when = if ($null -ne $CapturedAt) { [System.DateTimeOffset]$CapturedAt } else { [System.DateTimeOffset]::Now }
    return [pscustomobject]@{
        Timestamp     = $when.ToString('yyyy-MM-dd HH:mm:ss')
        CapturedAt    = $when.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [System.Globalization.CultureInfo]::InvariantCulture)
        Url           = $Url
        SegmentIndex  = $SegmentIndex
        SegmentCount  = $SegmentCount
        Base64        = $(if ($NoBase64) { '' } else { [Convert]::ToBase64String($Bytes) })
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
        Account = $(if ($Item.PSObject.Properties['Account']) { [string]$Item.Account } else { '' })
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
    # A linked report (-LinkImages) reads the images from their files: the run then does
    # not keep a base64 copy of every image in memory until the report is written.
    $linked = $Context.ContainsKey('EmbedImages') -and -not $Context.EmbedImages
    $Item.Captures.Add((New-CaptureRecord -Bytes $bytes -Url $PageUrl -SegmentIndex $SegmentIndex -SegmentCount $SegmentCount `
        -FilePath $filePath -FileName $fileName -CapturedAt $capturedAt -CaptureNumber $CaptureNumber -Label $Label `
        -CaptureArea $area -ZoomPercent $ZoomPercent -NoBase64:$linked))
    if (Test-RunEventSink) {
        # The pixel size only when someone receives it: reading it costs a header decode.
        $record = $Item.Captures[$Item.Captures.Count - 1]
        $pixels = [pscustomobject]@{ Width = 0; Height = 0 }
        try { $pixels = Get-ImagePixelSize -Bytes $bytes } catch { Write-Verbose "Image size not read: $($_.Exception.Message)" }
        Write-RunEvent -Type 'capture' -Data ([ordered]@{
            pageId = $script:EventPageId; pageIndex = $Item.Index; captureNumber = $CaptureNumber; label = $Label
            segment = $SegmentIndex; segmentCount = $SegmentCount; fileName = $fileName; area = $area; zoomPercent = $ZoomPercent
            url = $PageUrl; capturedAt = $record.CapturedAt; width = [int]$pixels.Width; height = [int]$pixels.Height
            bytes = $record.Bytes; sha256 = $record.Sha256 })
    }
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

function Get-ClassificationStyle {
    <#
        The marking for a classification level: its banner text and one restrained colour
        per level, so a reader tells the levels apart at a glance and in grey-scale print
        (the text itself always names the level). '' or an unknown value: no marking.
        The spelling is the schema's, whatever case the command line used.
    #>
    param([AllowEmptyString()][string]$Level = '')
    $styles = [ordered]@{
        Public       = @{ Color = '#1c6b2c'; Border = '#9fd6ab'; Background = '#eef8f0' }
        Internal     = @{ Color = '#12507d'; Border = '#9cc2df'; Background = '#eaf2f9' }
        Private      = @{ Color = '#5b3a8c'; Border = '#c4b2df'; Background = '#f3eef9' }
        Confidential = @{ Color = '#9b1c1c'; Border = '#e0a0a0'; Background = '#fbecec' }
    }
    foreach ($name in $styles.Keys) {
        if ($name -eq $Level.Trim()) {
            $style = $styles[$name]
            return [pscustomobject]@{
                Level = $name; Text = $name.ToUpperInvariant(); CssClass = "cls-$($name.ToLowerInvariant())"
                Color = $style.Color; Border = $style.Border; Background = $style.Background
            }
        }
    }
    return $null
}

function Get-LogoDataUri {
    <#
        The company logo as a data URI, so the report stays one file. The type is read
        from the file's first bytes, not trusted from its name. An SVG can carry script:
        it is only ever used as the src of an <img>, where browsers never run it, and is
        never written into the page itself. A logo is decoration, not evidence, so every
        problem is a warning for the console and the report is written without it.
        Returns { DataUri; Warning } - one of them is ''.
    #>
    param(
        [AllowEmptyString()][string]$Path = '',
        [long]$MaxBytes = 1MB
    )
    $result = { param($Uri, $Warning) [pscustomobject]@{ DataUri = $Uri; Warning = $Warning } }
    if ([string]::IsNullOrWhiteSpace($Path)) { return (& $result '' '') }
    $noLogo = 'so the report has no logo.'
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return (& $result '' "The logo file '$Path' was not found, $noLogo")
        }
        $length = (Get-Item -LiteralPath $Path).Length
        if ($length -gt $MaxBytes) {
            return (& $result '' ("The logo file '{0}' is {1:N0} KB; a logo may be at most {2:N0} KB, {3} Use a smaller image." -f $Path, [Math]::Ceiling($length / 1KB), ($MaxBytes / 1KB), $noLogo))
        }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        return (& $result '' "The logo file '$Path' could not be read ($($_.Exception.Message)), $noLogo")
    }

    $starts = {
        param([byte[]]$Signature)
        if ($bytes.Length -lt $Signature.Length) { return $false }
        for ($i = 0; $i -lt $Signature.Length; $i++) { if ($bytes[$i] -ne $Signature[$i]) { return $false } }
        return $true
    }
    $mime = ''
    if (& $starts ([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))) { $mime = 'image/png' }
    elseif (& $starts ([byte[]](0xFF, 0xD8, 0xFF))) { $mime = 'image/jpeg' }
    elseif (& $starts ([byte[]](0x47, 0x49, 0x46, 0x38))) { $mime = 'image/gif' }
    elseif ([System.IO.Path]::GetExtension($Path) -eq '.svg') {
        $head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min($bytes.Length, 4096))
        if ($head -match '<svg[\s>]') { $mime = 'image/svg+xml' }
    }
    if (-not $mime) {
        return (& $result '' "The logo file '$Path' is not a PNG, JPEG, GIF or SVG image, $noLogo")
    }
    return (& $result "data:$mime;base64,$([Convert]::ToBase64String($bytes))" '')
}

function Get-PeriodText {
    <#
        The period the evidence covers, as the user wrote it. Dates are free text and are
        never parsed or reformatted: 03/04/2026 means another day in another country, and
        the report must say exactly what the auditor typed. '' when nothing was given.
    #>
    param(
        [AllowEmptyString()][string]$From = '',
        [AllowEmptyString()][string]$To = '',
        [AllowEmptyString()][string]$Label = ''
    )
    $From = $From.Trim(); $To = $To.Trim(); $Label = $Label.Trim()
    $range = if ($From -and $To) { "$From to $To" } elseif ($From) { "from $From" } elseif ($To) { "up to $To" } else { '' }
    if ($Label -and $range) { return "${Label}: $range" }
    if ($Label) { return $Label }
    return $range
}

function Get-CaptureWindow {
    <#
        When the screenshots were really taken: the first and last capture time of the
        run, each with its UTC offset. This is measured, unlike the period the user
        typed, so the report keeps the two apart. First/Last keep the records' own ISO
        text (for the JSON summary); Text is the report's line.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $times = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        foreach ($capture in @($item.Captures)) {
            if ($null -eq $capture -or -not $capture.PSObject.Properties['CapturedAt']) { continue }
            $parsed = [System.DateTimeOffset]::MinValue
            if ([System.DateTimeOffset]::TryParseExact([string]$capture.CapturedAt, 'yyyy-MM-ddTHH:mm:ss.fffzzz', $invariant,
                    [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $times.Add([pscustomobject]@{ When = $parsed; Text = [string]$capture.CapturedAt })
            }
        }
    }
    if ($times.Count -eq 0) { return [pscustomobject]@{ First = ''; Last = ''; Text = 'No screenshot was taken.' } }
    $sorted = @($times | Sort-Object -Property { $_.When.UtcDateTime })
    $show = { param($t) $t.When.ToString('yyyy-MM-dd HH:mm:ss', $invariant) + ' (UTC' + $t.When.ToString('zzz', $invariant) + ')' }
    $first = $sorted[0]
    $last = $sorted[-1]
    $text = if ($sorted.Count -eq 1) { "$(& $show $first) (one screenshot)" } else { "$(& $show $first) to $(& $show $last)" }
    return [pscustomobject]@{ First = $first.Text; Last = $last.Text; Text = $text }
}

function New-ReportOptions {
    <#
        Everything New-HtmlReport may add to the report beyond the run's own data, in one
        object, so the report code never reads settings or files. Blank title means the
        default title; the classification is written in the schema's spelling.
        LogoDataUri is the logo already read (Get-LogoDataUri); LogoPath only names it.
        ImageFolder: for a linked report, the images folder relative to the report
        (images/<report name>), used as the start of every image's src.
    #>
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$Classification = '',
        [AllowEmptyString()][string]$LogoPath = '',
        [AllowEmptyString()][string]$LogoDataUri = '',
        [AllowEmptyString()][string]$CompanyName = '',
        [AllowEmptyString()][string]$CompanyDetails = '',
        [AllowEmptyString()][string]$Description = '',
        [AllowEmptyString()][string]$Origin = '',
        [AllowEmptyString()][string]$GeneratedBy = '',
        [AllowEmptyString()][string]$PeriodFrom = '',
        [AllowEmptyString()][string]$PeriodTo = '',
        [AllowEmptyString()][string]$PeriodLabel = '',
        [AllowEmptyString()][string]$Account = '',
        [bool]$ShowIndex = $true,
        [bool]$EmbedImages = $true,
        [AllowEmptyString()][string]$ImageFolder = '',
        # The capture log's file name ('' = none written).
        [AllowEmptyString()][string]$CaptureLogName = ''
    )
    $style = Get-ClassificationStyle -Level $Classification
    return [pscustomobject]@{
        Title          = $(if ([string]::IsNullOrWhiteSpace($Title)) { 'Audit Evidence Report' } else { $Title.Trim() })
        Classification = $(if ($null -ne $style) { $style.Level } else { '' })
        LogoPath       = $LogoPath
        LogoDataUri    = $LogoDataUri
        CompanyName    = $CompanyName.Trim()
        CompanyDetails = $CompanyDetails.Trim()
        Description    = $Description.Trim()
        Origin         = $Origin.Trim()
        GeneratedBy    = $GeneratedBy.Trim()
        PeriodFrom     = $PeriodFrom.Trim()
        PeriodTo       = $PeriodTo.Trim()
        PeriodLabel    = $PeriodLabel.Trim()
        Account        = $Account.Trim()
        ShowIndex      = $ShowIndex
        EmbedImages    = $EmbedImages
        ImageFolder    = $ImageFolder.Trim('/', '\').Replace('\', '/')
        CaptureLogName = $CaptureLogName
    }
}

function Get-CaptureSetList {
    <#
        A page's capture actions that produced images, in order: number, the label the
        report shows ("Capture 2: Lockout") and the anchor of its first image. Shared by
        the contents list and the item sections so their links and ids always agree.
    #>
    param([Parameter(Mandatory)][object]$Item)
    $sets = [ordered]@{}
    foreach ($capture in @($Item.Captures)) {
        $number = if ($capture.PSObject.Properties['CaptureNumber']) { [int]$capture.CaptureNumber } else { 1 }
        # String keys: an int would index an ordered dictionary by position.
        if ($sets.Contains("$number")) { continue }
        $label = if ($capture.PSObject.Properties['Label']) { [string]$capture.Label } else { '' }
        $sets["$number"] = [pscustomobject]@{
            Number = $number
            Text   = "Capture $number" + $(if ($label) { ": $label" } else { '' })
            Anchor = "item-$($Item.Index)-c$number"
            First  = $capture
        }
    }
    return , @($sets.Values)
}

function Get-ReportImageSource {
    <#
        The src of one image: the image itself (base64) in a self-contained report, or
        the path of its file next to the report in a linked one (images/<report>/<file>,
        each part URL-escaped so spaces, #, % and letters of any language in a report
        name still resolve from disk). -Verify accepts exactly this spelling and no other
        (Test-ReportImageFolderName), so do not change the escaping without it.
    #>
    param(
        [Parameter(Mandatory)][object]$Capture,
        [Parameter(Mandatory)][string]$MimeType,
        [AllowNull()][object]$Options = $null
    )
    if ($null -ne $Options -and -not $Options.EmbedImages) {
        $parts = @(@($Options.ImageFolder -split '/') + [string]$Capture.FileName | Where-Object { $_ } |
            ForEach-Object { [System.Uri]::EscapeDataString($_) })
        return (Encode-Html ($parts -join '/'))
    }
    return "data:$MimeType;base64,$($Capture.Base64)"
}

function Get-ReportCss {
    <#
        The report's style sheet - the one place it is built, so New-HtmlReport writes it
        and -Verify can recognise it (Test-ReportMarkup accepts only a <style> whose text
        is one Vouch writes). It depends only on whether there are options and on the
        classification level.
        MAINTAINERS: changing anything here changes the SHA-256 of reports' styles. Add the
        NEW hashes to Get-KnownReportCssHash and keep the OLD ones there, or reports made
        by earlier versions stop verifying (the unit test "Report style sheet pins" says
        which hashes are missing).
    #>
    param([AllowNull()][object]$Options = $null)
    $withOptions = $null -ne $Options
    $classification = if ($withOptions) { Get-ClassificationStyle -Level $Options.Classification } else { $null }

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
    if ($withOptions) {
        $css += @'

.company { display: flex; align-items: center; gap: 18px; margin: 0 0 18px 0; padding-bottom: 14px; border-bottom: 1px solid #d5dbe1; }
.company .logo { max-height: 64px; max-width: 220px; width: auto; height: auto; }
.company-name { font-size: 16px; font-weight: 700; }
.company-details, .multiline { white-space: pre-line; }
.company-details { color: #3a4149; font-size: 13px; }
.classification { text-align: center; font-weight: 700; letter-spacing: 2px; padding: 5px 10px; border: 1px solid; border-radius: 3px; }
.classification.top { margin: 0 0 20px 0; }
.classification.bottom { margin: 22px 0 0 0; }
table.contents td.sub { padding-left: 26px; }
table.contents ul { margin: 4px 0 0 0; padding-left: 18px; }
.contents-wrap { margin-bottom: 26px; }
'@
        if ($null -ne $classification) {
            # On screen and on the first and last printed page: the banners. On every
            # printed page: the page margin boxes, which Edge repeats per page. The text
            # comes from the fixed list of levels, never from free text.
            $css += "`n.classification { color: $($classification.Color); border-color: $($classification.Border); background: $($classification.Background); }`n"
            $css += "@media print { .classification { background: #ffffff; } }`n"
            $css += "@page {`n  margin: 16mm 12mm;`n" +
                "  @top-center { content: ""$($classification.Text)""; color: $($classification.Color); font: 700 9pt ""Segoe UI"", Arial, sans-serif; letter-spacing: 2px; }`n" +
                "  @bottom-center { content: ""$($classification.Text)""; color: $($classification.Color); font: 700 9pt ""Segoe UI"", Arial, sans-serif; letter-spacing: 2px; }`n}`n"
        }
    }

    return $css
}
function New-HtmlReport {
    <#
        The report. Without -Options it is the report Vouch has always written. -Options
        (New-ReportOptions) adds the title, classification banners, company block, run
        details, contents list and per-page account, and chooses between images inside
        the file and images linked from the images folder. Every value a user typed goes
        through Encode-Html. The img data-* attributes keep their order in both forms:
        Vouch 1.3's -Verify reads self-contained reports with a fixed pattern.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][object]$Run,
        [AllowNull()][object]$Options = $null
    )

    $mimeType = if ($Run.ImageFormat -eq 'png') { 'image/png' } else { 'image/jpeg' }
    $runId = if ($Run.PSObject.Properties['RunId']) { [string]$Run.RunId } else { '' }
    $manifestHash = if ($Run.PSObject.Properties['ManifestSha256']) { [string]$Run.ManifestSha256 } else { '' }
    $withOptions = $null -ne $Options
    $defaultTitle = 'Audit Evidence Report'
    $classification = if ($withOptions) { Get-ClassificationStyle -Level $Options.Classification } else { $null }
    # Multi-line text (company details, description): encoded, then CSS keeps the breaks.
    $multiLine = { param([string]$Text) Encode-Html (($Text -replace "`r`n", "`n").Trim()) }

    $css = Get-ReportCss -Options $Options

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    # The default title reads as it always did; a title of the user's own stands alone.
    $customTitle = $withOptions -and $Options.Title -and $Options.Title -ne $defaultTitle
    if ($customTitle) {
        [void]$sb.AppendLine("<title>$(Encode-Html $Options.Title) - $(Encode-Html $Run.StartTime)</title>")
    }
    else {
        [void]$sb.AppendLine("<title>Vouch &mdash; Audit Evidence Report - $(Encode-Html $Run.StartTime)</title>")
    }
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine($css)
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')

    if ($null -ne $classification) {
        [void]$sb.AppendLine("<div class=""classification top $($classification.CssClass)"" role=""note"">$($classification.Text)</div>")
    }
    if ($withOptions -and ($Options.LogoDataUri -or $Options.CompanyName -or $Options.CompanyDetails)) {
        [void]$sb.Append('<header class="company">')
        if ($Options.LogoDataUri) {
            # Only ever an <img> source: an SVG logo shown this way cannot run script.
            # data-vouch-logo: -Verify accepts one such image without a hash, as the first
            # thing in this header (Test-ReportMarkup). Only name="value" attributes.
            [void]$sb.Append("<img class=""logo"" data-vouch-logo=""true"" alt=""Company logo"" src=""$(Encode-Html $Options.LogoDataUri)"">")
        }
        [void]$sb.Append('<div class="company-text">')
        if ($Options.CompanyName) { [void]$sb.Append("<div class=""company-name"">$(Encode-Html $Options.CompanyName)</div>") }
        if ($Options.CompanyDetails) { [void]$sb.Append("<div class=""company-details"">$(& $multiLine $Options.CompanyDetails)</div>") }
        [void]$sb.AppendLine('</div></header>')
    }

    if ($customTitle) { [void]$sb.AppendLine("<h1>$(Encode-Html $Options.Title)</h1>") }
    else { [void]$sb.AppendLine('<h1>Vouch &mdash; Audit Evidence Report</h1>') }
    # Pages captured as the window or the page content only have no taskbar clock: the
    # general wording must then not promise one. Screen-only reports read as before.
    $allScreen = -not @($Items | Where-Object {
            ($_.PSObject.Properties['CaptureArea'] -and $_.CaptureArea -ne 'screen') -or
            @($_.Captures | Where-Object { $_.PSObject.Properties['CaptureArea'] -and $_.CaptureArea -ne 'screen' }).Count -gt 0 })
    $subtitle = if ($allScreen) { 'Screen captures of live application pages, including the Windows taskbar clock.' }
    else { 'Captures of live application pages. Each page states what its images show (its capture area).' }
    [void]$sb.AppendLine("<p class=""subtitle"">$subtitle</p>")

    [void]$sb.AppendLine('<div class="meta"><table>')
    $metaRows = [System.Collections.Generic.List[object]]::new()
    if ($withOptions) {
        # What the user said about the evidence first, then what the run measured.
        $addRow = { param($Label, $Text, [switch]$MultiLine) if (-not [string]::IsNullOrWhiteSpace([string]$Text)) { $metaRows.Add([pscustomobject]@{ Label = $Label; Text = [string]$Text; MultiLine = [bool]$MultiLine }) } }
        if ($null -ne $classification) { & $addRow 'Classification' $classification.Level }
        & $addRow 'Description' $Options.Description -MultiLine
        & $addRow 'Origin' $Options.Origin
        & $addRow 'Period covered' (Get-PeriodText -From $Options.PeriodFrom -To $Options.PeriodTo -Label $Options.PeriodLabel)
        & $addRow 'Capture window' (Get-CaptureWindow -Items $Items).Text
        & $addRow 'Account used' $Options.Account
        & $addRow 'Report generated by' $(if ($Options.GeneratedBy) { $Options.GeneratedBy } else { [string]$Run.User })
        if ($Options.PSObject.Properties['CaptureLogName']) { & $addRow 'Capture log' $Options.CaptureLogName }
    }
    foreach ($row in @(
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
    )) { $metaRows.Add($row) }
    foreach ($row in $metaRows) {
        if ($row.PSObject.Properties['MultiLine'] -and $row.MultiLine) {
            [void]$sb.AppendLine("<tr><td class=""k"">$(Encode-Html $row.Label)</td><td class=""multiline"">$(& $multiLine ([string]$row.Text))</td></tr>")
        }
        else {
            [void]$sb.AppendLine("<tr><td class=""k"">$(Encode-Html $row.Label)</td><td>$(Encode-Html ([string]$row.Text))</td></tr>")
        }
    }
    [void]$sb.AppendLine('</table></div>')

    if ($withOptions -and $Options.ShowIndex) {
        # Plain #anchors: they work from disk, in any browser, and as links in a PDF printed from the report.
        $withAccount = @($Items | Where-Object { $_.PSObject.Properties['Account'] -and $_.Account }).Count -gt 0
        [void]$sb.AppendLine('<nav class="contents-wrap" aria-label="Contents"><h2 id="contents">Contents</h2>')
        [void]$sb.AppendLine('<table class="summary contents">')
        [void]$sb.AppendLine('<thead><tr><th>#</th><th>Page</th><th>Status</th><th>Images</th>' + $(if ($withAccount) { '<th>Account</th>' } else { '' }) + '</tr></thead>')
        [void]$sb.AppendLine('<tbody>')
        foreach ($item in $Items) {
            $sets = Get-CaptureSetList -Item $item
            $sub = ''
            if ($sets.Count -gt 1) {
                $sub = '<ul>' + (($sets | ForEach-Object { "<li><a href=""#$($_.Anchor)"">$(Encode-Html $_.Text)</a></li>" }) -join '') + '</ul>'
            }
            $account = if ($item.PSObject.Properties['Account'] -and $item.Account) { Encode-Html $item.Account } else { '&mdash;' }
            [void]$sb.AppendLine("<tr><td>$($item.Index)</td><td><a href=""#item-$($item.Index)"">$(Encode-Html $item.Name)</a>$sub</td>" +
                "<td><span class=""$(Get-StatusCssClass -Status $item.Status)"">$(Encode-Html $item.Status)</span></td>" +
                "<td>$(@($item.Captures).Count)</td>" + $(if ($withAccount) { "<td>$account</td>" } else { '' }) + '</tr>')
        }
        [void]$sb.AppendLine('</tbody></table></nav>')
    }

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
        'record it in the workpaper at capture time. <code>vouch.ps1 -Verify &lt;report&gt;</code> later confirms that the screenshots are the ones ' +
        'captured and that the report is built the way Vouch writes it; it does not cover the report&#39;s text. Saved images can be checked with ' +
        '<code>sha256sum -c SHA256SUMS</code>.</p>')
    if ($withOptions) {
        if ($Options.EmbedImages) {
            [void]$sb.AppendLine('<p class="integrity-note"><strong>Self-contained report:</strong> every screenshot is stored inside this file, so it can be moved or attached on its own.</p>')
        }
        else {
            [void]$sb.AppendLine("<p class=""integrity-note""><strong>Linked report:</strong> the screenshots are separate files in the folder <code>$(Encode-Html $Options.ImageFolder)</code> next to this file. " +
                'That folder must always travel with the report (keep them together, or send the zip Vouch made); without it the screenshots are not shown and the report cannot be verified.</p>')
        }
    }
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
        if ($withOptions -and $item.PSObject.Properties['Account'] -and $item.Account) {
            [void]$sb.AppendLine("<dt>Account</dt><dd>$(Encode-Html $item.Account)</dd>")
        }
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
            # The first image of each capture gets the id the contents list links to.
            $anchors = @{}
            if ($withOptions -and $captureSets -gt 1) {
                foreach ($set in (Get-CaptureSetList -Item $item)) { $anchors[$set.Number] = $set.Anchor }
            }
            foreach ($capture in $item.Captures) {
                $segmentText = if ($capture.SegmentCount -gt 1) { " &middot; segment $($capture.SegmentIndex) of $($capture.SegmentCount)" } else { '' }
                $captureNumber = if ($capture.PSObject.Properties['CaptureNumber']) { [int]$capture.CaptureNumber } else { 1 }
                $label = if ($capture.PSObject.Properties['Label']) { [string]$capture.Label } else { '' }
                $setText = ''
                if ($captureSets -gt 1 -or $label) {
                    $setText = "Capture $captureNumber" + $(if ($label) { ": $label" } else { '' })
                }
                $anchor = $anchors[$captureNumber]
                if ($anchor) { $anchors.Remove($captureNumber); [void]$sb.AppendLine("<figure id=""$anchor"">") }
                else { [void]$sb.AppendLine('<figure>') }
                # The data-* attributes are what -Verify checks each image against. Their
                # order is kept for Vouch 1.3's -Verify, which reads self-contained reports
                # with a fixed pattern; Test-ReportIntegrity itself reads them in any order.
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
                [void]$sb.Append('" src="')
                [void]$sb.Append((Get-ReportImageSource -Capture $capture -MimeType $mimeType -Options $Options))
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
    if ($null -ne $classification) {
        [void]$sb.AppendLine("<div class=""classification bottom $($classification.CssClass)"" role=""note"">$($classification.Text)</div>")
    }
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
        metadata and per-item results, without the image data. With -Options it also
        carries what the report says about the evidence (ReportDetails) and, with -Zip,
        the evidence package (Zip; its hash is known only after the zip was made, so the
        copy of this file inside the zip has Sha256 null).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][object]$Run,
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowNull()][object]$Options = $null,
        # { Path; Sha256 } of the zip, or $null when none is made.
        [AllowNull()][object]$Zip = $null,
        # The capture log ('' = none) and whether every line of it was written.
        [AllowEmptyString()][string]$LogPath = '',
        [bool]$LogComplete = $true
    )

    $summary = [ordered]@{
        Report    = $ReportPath
        ExitCode  = $ExitCode
        Run       = $Run
    }
    if ($null -ne $Options) {
        $window = Get-CaptureWindow -Items $Items
        $summary['ReportDetails'] = [ordered]@{
            Title          = $Options.Title
            Classification = $Options.Classification
            Company        = [ordered]@{ Name = $Options.CompanyName; Details = $Options.CompanyDetails }
            LogoPath       = $(if ($Options.LogoDataUri) { $Options.LogoPath } else { '' })
            Description    = $Options.Description
            Origin         = $Options.Origin
            GeneratedBy    = $(if ($Options.GeneratedBy) { $Options.GeneratedBy } elseif ($Run.PSObject.Properties['User']) { [string]$Run.User } else { '' })
            Period         = [ordered]@{ From = $Options.PeriodFrom; To = $Options.PeriodTo; Label = $Options.PeriodLabel }
            CaptureWindow  = [ordered]@{ First = $window.First; Last = $window.Last }
            Account        = $Options.Account
            ShowIndex      = [bool]$Options.ShowIndex
            ImageForm      = $(if ($Options.EmbedImages) { 'embedded' } else { 'linked' })
            ImageFolder    = $(if ($Options.EmbedImages) { '' } else { $Options.ImageFolder })
        }
    }
    if ($null -ne $Zip) { $summary['Zip'] = [ordered]@{ Path = [string]$Zip.Path; Sha256 = $Zip.Sha256 } }
    if ($LogPath) {
        $summary['LogPath'] = $LogPath
        $summary['LogComplete'] = $LogComplete
    }
    $summary['Items'] = @(foreach ($item in $Items) {
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
                Account        = $(if ($item.PSObject.Properties['Account']) { [string]$item.Account } else { '' })
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
    return ($summary | ConvertTo-Json -Depth 6)
}

function Get-KnownReportCssHash {
    <#
        SHA-256 of every style sheet a released Vouch writes into its reports (the text
        between <style> and </style>, line ends made LF). -Verify accepts a report only
        with one of these, or with one the current Get-ReportCss makes. Never remove an
        entry: reports made by that version would stop verifying.
        The value is the KIND of report the sheet belongs to, which -Verify holds the
        document to (Test-ReportMarkup): 'plain' (no report options: no company header,
        logo, contents or banner - and no rule that limits a logo's size), 'options'
        (report options, no classification) or the classification level, whose banner
        the document must then carry.
    #>
    return [ordered]@{
        'c777d90eb3cf23596ed8e5f857508c5165ce399b7ae03676697aae9dcd251190' = 'plain'         # 1.3.0, and 2.0.0 without report options
        'b159902f6ac1f1e8d0d58f5ef93ebc01c7c5c4d51c33cbd831195b918fd748b4' = 'options'       # 2.0.0
        '2b4c494d2f22318be79409d18f969ae47b589600f08e2a4879eea93eec0748b1' = 'Public'        # 2.0.0
        '96805324fe4f2c698b02cf5e5032a077aba5d0414c36b3c3c91ae0744f061c17' = 'Internal'      # 2.0.0
        '550b8033a6dc5924662ff306df27e3168166bf87aa51de75392ddaf5a83d3350' = 'Private'       # 2.0.0
        '584a9b4957c6ba72dfa3eebea97fe71e93182fdf5564f5ace1b71255930bebf0' = 'Confidential'  # 2.0.0
    }
}

function Get-ReportCssHash {
    # The hash Get-KnownReportCssHash lists for a style text: line ends made LF, UTF-8.
    param([AllowEmptyString()][string]$Text)
    $normal = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    return Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($normal))
}

function Get-CurrentReportCssHash {
    # The style sheets this version writes, hash -> kind (see Get-KnownReportCssHash):
    # without options, with options, and with each classification.
    $hashes = [ordered]@{}
    foreach ($level in @($null, '', 'Public', 'Internal', 'Private', 'Confidential')) {
        $options = if ($null -eq $level) { $null } else { New-ReportOptions -Classification $level }
        $kind = if ($null -eq $level) { 'plain' } elseif ($level -eq '') { 'options' } else { $level }
        # New-HtmlReport writes the sheet on lines of its own between <style> and </style>.
        $hashes[(Get-ReportCssHash -Text ("`n" + (Get-ReportCss -Options $options) + "`n"))] = $kind
    }
    return $hashes
}

function Get-ReportMarkupRule {
    <#
        The markup New-HtmlReport writes (Vouch 1.3 and 2.0; 1.3's is a subset, so one
        table serves both). Anything not listed is not Vouch's.
        Attributes: per element, the attributes it may carry with the pattern their raw
        value must match (class values are the exact ones written, not any mix).
        Required: attributes the generator always writes on that element.
        Children: which elements are written directly inside which.
        Placement: for the elements whose class decides where they belong (Placed),
        "element.class" -> the parents ("element.class") they are written in.
        TextIn: the elements that hold text; anywhere else only line breaks are written.
    #>
    $text = '^[^"<>]*$'
    $none = @{}
    $attributes = @{
        html = @{ lang = '^en$' }; head = $none; body = $none; title = $none; style = $none
        meta = @{ charset = '^utf-8$'; name = '^viewport$'; content = '^width=device-width, initial-scale=1$' }
        h1 = $none; h2 = @{ id = '^contents$' }; h3 = $none
        p = @{ class = '^(?:subtitle|counts|integrity-note|manifest|empty)$'; 'data-manifest-sha256' = '^(?:[0-9a-f]{64})?$' }
        div = @{ class = '^(?:meta|item-head|notes|company-text|company-name|company-details|classification (?:top|bottom) cls-(?:public|internal|private|confidential))$'; role = '^note$' }
        table = @{ class = '^summary(?: contents| hashes)?$' }; thead = $none; tbody = $none; tr = $none; th = $none
        td = @{ class = '^(?:k|multiline)$' }
        a = @{ href = '^#item-[0-9]+(?:-c[0-9]+)?$' }
        span = @{ class = '^(?:badge (?:ok|warn|fail)|hash)$' }; strong = $none; code = $none; br = $none
        ul = @{ class = '^(?:detail-list|steps)$' }; li = @{ class = '^bad$' }
        dl = $none; dt = $none; dd = $none
        section = @{ class = '^item$'; id = '^item-[0-9]+$' }
        figure = @{ id = '^item-[0-9]+-c[0-9]+$' }; figcaption = $none
        # data-file: Get-CaptureFileName's form, 001_Name_seg01.jpg.
        img = @{ alt = $text; 'data-file' = '^[0-9]{3,}_[A-Za-z0-9._-]+_seg[0-9]{2,}\.(?:jpg|png)$'; 'data-sha256' = '^[0-9a-f]{64}$'
            'data-captured' = $text; 'data-url' = $text; src = $text; class = '^logo$'; 'data-vouch-logo' = '^true$' }
        footer = $none; header = @{ class = '^company$' }; nav = @{ class = '^contents-wrap$'; 'aria-label' = '^Contents$' }
    }
    $required = @{
        html = @('lang'); section = @('class', 'id'); header = @('class'); nav = @('class', 'aria-label'); a = @('href')
    }
    $children = @{
        html = @('head', 'body'); head = @('meta', 'title', 'style')
        body = @('div', 'header', 'h1', 'p', 'nav', 'h2', 'table', 'section', 'footer')
        header = @('img', 'div'); nav = @('h2', 'table'); div = @('table', 'h2', 'span', 'strong', 'div')
        table = @('thead', 'tbody', 'tr'); thead = @('tr'); tbody = @('tr'); tr = @('th', 'td')
        td = @('a', 'span', 'br', 'ul', 'code'); ul = @('li'); li = @('a', 'code')
        p = @('span', 'strong', 'code', 'br'); span = @('strong', 'span')
        section = @('div', 'dl', 'h3', 'ul', 'p', 'figure'); dl = @('dt', 'dd')
        figure = @('img', 'figcaption'); figcaption = @('strong', 'br', 'span')
    }
    $placement = @{
        'div.meta' = @('body.'); 'div.item-head' = @('section.item'); 'div.notes' = @('section.item')
        'div.company-text' = @('header.company'); 'div.company-name' = @('div.company-text'); 'div.company-details' = @('div.company-text')
        'p.subtitle' = @('body.'); 'p.counts' = @('body.'); 'p.integrity-note' = @('body.'); 'p.manifest' = @('body.'); 'p.empty' = @('section.item')
        'table.' = @('div.meta'); 'table.summary' = @('body.'); 'table.summary hashes' = @('body.'); 'table.summary contents' = @('nav.contents-wrap')
        'ul.' = @('td.'); 'ul.detail-list' = @('section.item'); 'ul.steps' = @('section.item')
        'h2.' = @('body.', 'div.item-head', 'nav.contents-wrap')
        'span.' = @('p.counts'); 'span.hash' = @('figcaption.')
    }
    foreach ($badge in 'ok', 'warn', 'fail') { $placement["span.badge $badge"] = @('td.', 'span.', 'div.item-head') }
    foreach ($level in 'public', 'internal', 'private', 'confidential') {
        $placement["div.classification top cls-$level"] = @('body.')
        $placement["div.classification bottom cls-$level"] = @('body.')
    }
    $textIn = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in 'title', 'h1', 'h2', 'h3', 'p', 'div', 'td', 'th', 'a', 'span', 'strong', 'code', 'li', 'dt', 'dd', 'figcaption', 'footer') { [void]$textIn.Add($name) }
    return [pscustomobject]@{
        Attributes = $attributes; Required = $required; Children = $children
        Placed = @{ div = 1; p = 1; table = 1; ul = 1; h2 = 1; span = 1 }; Placement = $placement; TextIn = $textIn
    }
}

function Test-ReportImageFolderName {
    <#
        Whether the folder part of a linked image's address is exactly what the generator
        writes: EscapeDataString of a folder name Windows holds as written. Only that one
        spelling is accepted, because for any other a browser and .NET may not mean the
        same folder: %FF (not UTF-8) stays the three characters "%FF" for .NET but is the
        letter y-umlaut for Edge; %2e%2e is ".." for both, yet never what Vouch wrote.
        Round-tripping through the generator's own encoder leaves exactly the valid,
        upper-case UTF-8 escapes of a real name.
    #>
    param([AllowEmptyString()][string]$Segment = '')
    if ($Segment -cnotmatch '^[A-Za-z0-9._~%-]+$') { return $false }
    try {
        $name = [System.Uri]::UnescapeDataString($Segment)
        if ([System.Uri]::EscapeDataString($name) -cne $Segment) { return $false }
    }
    catch { return $false }
    if ($name -match '[\x00-\x1f\\/:*?"<>|]') { return $false }
    # Windows drops dots and spaces at the end of a name: "x." and "x" would be one folder.
    return -not ($name.EndsWith('.') -or $name.EndsWith(' '))
}

function Test-ReportMarkup {
    <#
        Whether a report is made only of the markup and styling Vouch writes - checked by
        whitelist over the whole document, not by reading it the way a browser would. The
        raw text is cut into tokens of the generator's strict grammar: the exact
        <!DOCTYPE html>, start tags <name( attr="value")*>, end tags </name>, and text
        without < or >. Element and attribute names, values, nesting and places must be
        in Get-ReportMarkupRule; character references only those Encode-Html (and the
        generator's own text) writes. The one <style> must be a style sheet Vouch writes
        (Get-KnownReportCssHash / Get-ReportCss), and the document must be the KIND of
        report that sheet belongs to: the parts of <body> in the generator's order, the
        company header, logo, contents and linked images only with the sheet of a report
        with options (the one that limits the logo's size), and the classification
        banners exactly with the sheet of that level. Every <img> is either a screenshot
        inside the <section class="item"> of its page, in a <figure> (exact attributes,
        generator-form src), or the one logo, first thing in <header class="company">.
        Never throws and never takes long: it stops listing after a few problems, and
        naming their places costs one pass over the text.
        Returns { Images (each { Attributes (decoded); Position; Kind }); Problems;
        Kind (of the style sheet); Manifest (the manifest hash the report states) }.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
    $images = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{ Images = $images; Problems = $problems; Kind = ''; Manifest = '' }
    if (-not $Html.StartsWith('<!DOCTYPE html>', [System.StringComparison]::Ordinal)) {
        $problems.Add('The report does not start the way Vouch writes it (<!DOCTYPE html>).')
        return $result
    }
    # A hostile file can hold any number of faults; the first ones say enough.
    $limit = 25
    $seen = @{ At = 0; Line = 1 }
    $where = {
        param([int]$Index)
        # Lines are counted on from the last place named, not from the top each time.
        $Index = [Math]::Max(0, [Math]::Min($Index, $Html.Length))
        if ($Index -lt $seen.At) { $seen.At = 0; $seen.Line = 1 }
        $between = $Html.Substring($seen.At, $Index - $seen.At)
        $seen.Line += $between.Length - $between.Replace("`n", '').Length
        $seen.At = $Index
        $snippet = $Html.Substring($Index, [Math]::Min(70, $Html.Length - $Index)) -replace '\s+', ' '
        "line $($seen.Line), at '$snippet'"
    }
    $rule = Get-ReportMarkupRule
    # Plain variables for what the loop reads at every tag: the loop is the whole cost
    # of checking a large report.
    $ruleAttributes = $rule.Attributes; $ruleRequired = $rule.Required; $ruleChildren = $rule.Children
    $rulePlaced = $rule.Placed; $rulePlacement = $rule.Placement; $textIn = $rule.TextIn
    $special = @{ div = 1; p = 1; h2 = 1; style = 1; img = 1; meta = 1; figure = 1; td = 1; a = 1; section = 1; header = 1 }
    $noAttributes = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $noRaw = @{}
    $void = @{ meta = 1; br = 1; img = 1 }
    $badReference = [regex]'&(?!(?:amp|lt|gt|quot|#39|mdash|middot);)'
    $notBlank = [regex]'[^ \t\r\n]'
    $tokens = [regex]::new('(?<doctype><!DOCTYPE html>)|</(?<end>[a-z][a-z0-9]*)>|<(?<start>[a-z][a-z0-9]*)(?<attributes>(?: [a-z][a-z0-9-]*="[^"<>]*")*)>|(?<text>[^<>]+)')
    $attributePattern = [regex]' ([a-z][a-z0-9-]*)="([^"<>]*)"'
    $counts = @{}
    # The open elements: the name and "name.class" of each.
    $names = [System.Collections.Generic.List[string]]::new()
    $keys = [System.Collections.Generic.List[string]]::new()
    $sectionId = ''
    $headerChildren = 0
    $htmlParts = [System.Collections.Generic.List[string]]::new()
    $headParts = [System.Collections.Generic.List[string]]::new()
    $bodyParts = [System.Collections.Generic.List[string]]::new()
    $kind = ''
    $currentSheets = $null
    $sourceForm = $null
    $banner = 0
    $bannerText = ''
    $position = 0
    $styleEnd = -1
    $stopped = $false

    foreach ($token in $tokens.Matches($Html)) {
        if ($token.Index -lt $styleEnd) { continue }
        if ($problems.Count -ge $limit) { $stopped = $true; break }
        if ($token.Index -ne $position) {
            $problems.Add("The report contains markup Vouch never writes ($(& $where $position)).")
            $stopped = $true
            break
        }
        $position = $token.Index + $token.Length
        $depth = $names.Count
        $isText = $Html[$token.Index] -cne '<'
        $isEnd = -not $isText -and $Html[$token.Index + 1] -ceq '/'

        # A classification banner holds its level's text and nothing else.
        if ($banner -eq 1) {
            $banner = 2
            if (-not $isText -or $token.Value -cne $bannerText) { $problems.Add("A classification banner does not read $bannerText, as its style does ($(& $where $token.Index)).") }
        }
        elseif ($banner -eq 2) {
            $banner = 0
            if (-not $isEnd) { $problems.Add("A classification banner holds more than its text ($(& $where $token.Index)).") }
        }

        if ($isText) {
            $value = $token.Value
            if ($value.IndexOf('&') -ge 0) {
                $bad = $badReference.Match($value)
                if ($bad.Success) { $problems.Add("The report contains a character reference or & that Vouch never writes ($(& $where ($token.Index + $bad.Index))).") }
            }
            # Only what HTML itself takes for blank space: a no-break space between two
            # table rows, say, is text to a browser, which then moves it out of the table.
            if (($depth -eq 0 -or -not $textIn.Contains($names[$depth - 1])) -and $notBlank.IsMatch($value)) {
                $problems.Add("The report has text where Vouch writes none ($(& $where $token.Index)).")
            }
            continue
        }
        if ($isEnd) {
            $name = $token.Groups['end'].Value
            if ($depth -eq 0 -or $names[$depth - 1] -cne $name) {
                $problems.Add("The report's elements are not nested the way Vouch writes them (</$name>; $(& $where $token.Index)).")
                $stopped = $true
                break
            }
            $names.RemoveAt($depth - 1); $keys.RemoveAt($depth - 1)
            continue
        }
        if ($Html[$token.Index + 1] -ceq '!') {
            if ($token.Index -ne 0) { $problems.Add("The report has a second document type ($(& $where $token.Index)).") }
            continue
        }

        # A start tag.
        $name = $token.Groups['start'].Value
        $allowed = $ruleAttributes[$name]
        if ($null -eq $allowed) {
            $problems.Add("The report contains a <$name> element, which Vouch never writes ($(& $where $token.Index)).")
            continue
        }
        $counts[$name] = 1 + [int]$counts[$name]
        $attributes = $noAttributes
        $raw = $noRaw
        if ($token.Groups['attributes'].Length -gt 0) {
            $attributes = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
            $raw = @{}
            $attributeText = $token.Groups['attributes'].Value
            foreach ($match in $attributePattern.Matches($attributeText)) {
                if ($problems.Count -ge $limit) { break }
                $attribute = $match.Groups[1].Value
                $value = $match.Groups[2].Value
                if ($attributes.ContainsKey($attribute)) { $problems.Add("The report has a <$name> with the attribute $attribute twice ($(& $where $token.Index))."); continue }
                if (-not $allowed.ContainsKey($attribute)) { $problems.Add("The report has a <$name> with the attribute $attribute, which Vouch never writes ($(& $where $token.Index))."); continue }
                if ($value -cnotmatch $allowed[$attribute]) { $problems.Add("The report has a <$name> whose $attribute is not a value Vouch writes ($(& $where $token.Index))."); continue }
                if ($value.IndexOf('&') -ge 0 -and $badReference.IsMatch($value)) { $problems.Add("The report contains a character reference or & that Vouch never writes ($(& $where $token.Index))."); continue }
                $raw[$attribute] = $value
                $attributes[$attribute] = if ($value.IndexOf('&') -ge 0) { [System.Net.WebUtility]::HtmlDecode($value) } else { $value }
            }
        }
        if ($ruleRequired.ContainsKey($name)) {
            foreach ($attribute in $ruleRequired[$name]) {
                if (-not $raw.ContainsKey($attribute)) { $problems.Add("The report has a <$name> without the $attribute Vouch always writes ($(& $where $token.Index)).") }
            }
        }
        $class = [string]$raw['class']
        $key = "$name.$class"
        $parentName = ''
        $parentKey = ''
        if ($depth -gt 0) { $parentName = $names[$depth - 1]; $parentKey = $keys[$depth - 1] }

        # Where it is: inside the right kind of element, and for the parts told apart by
        # their class, inside the very part the generator writes them in.
        if ($depth -eq 0) {
            if ($name -cne 'html') { $problems.Add("The report has a <$name> outside its <html> ($(& $where $token.Index)).") }
        }
        elseif ($ruleChildren[$parentName] -cnotcontains $name) {
            $problems.Add("The report has a <$name> directly inside a <$parentName>, where Vouch never writes one ($(& $where $token.Index)).")
        }
        elseif ($rulePlaced.ContainsKey($name) -and $rulePlacement[$key] -cnotcontains $parentKey) {
            $problems.Add("The report has a <$name> (class ""$class"") in a place where Vouch never writes one ($(& $where $token.Index)).")
        }
        if ($depth -le 2) {
            if ($parentName -ceq 'body') { $bodyParts.Add($key) }
            elseif ($parentName -ceq 'html') { $htmlParts.Add($name) }
            elseif ($parentName -ceq 'head') { $headParts.Add($(if ($name -ceq 'meta') { 'meta:' + (@($raw.Keys | Sort-Object) -join ',') } else { $name })) }
        }
        if ($parentName -ceq 'header') { $headerChildren++ }

        if (-not $special.ContainsKey($name)) { }
        elseif ($name -ceq 'figure' -or $name -ceq 'td' -or $name -ceq 'a') {
            # A report without report options has none of what the options add.
            if ($kind -ceq 'plain' -and (($name -ceq 'figure' -and $raw.ContainsKey('id')) -or $key -ceq 'td.multiline' -or ($name -ceq 'a' -and $parentName -ceq 'li'))) {
                $problems.Add("The report has a part only a report with report options has, but its styles are those of a report without them ($(& $where $token.Index)).")
            }
        }
        elseif ($name -ceq 'section') { $sectionId = [string]$raw['id'] }
        elseif ($name -ceq 'header') { $headerChildren = 0 }
        elseif ($name -ceq 'div') {
            $isBanner = $key.StartsWith('div.classification ', [System.StringComparison]::Ordinal)
            if ($raw.ContainsKey('role') -ne $isBanner) { $problems.Add("The report has a <div> whose role is not as Vouch writes it ($(& $where $token.Index)).") }
            if ($isBanner) { $banner = 1; $bannerText = ($class -replace '^.*cls-', '').ToUpperInvariant() }
        }
        elseif ($name -ceq 'p') {
            if ($raw.ContainsKey('data-manifest-sha256') -ne ($key -ceq 'p.manifest')) { $problems.Add("The report's manifest hash is not where Vouch writes it ($(& $where $token.Index)).") }
            elseif ($key -ceq 'p.manifest') { $result.Manifest = $raw['data-manifest-sha256'] }
        }
        elseif ($name -ceq 'h2') {
            if ($raw.ContainsKey('id') -ne ($parentName -ceq 'nav')) { $problems.Add("The report has a heading whose id is not as Vouch writes it ($(& $where $token.Index)).") }
        }
        elseif ($name -ceq 'style') {
            $close = $Html.IndexOf('</style>', $position, [System.StringComparison]::Ordinal)
            if ($close -lt 0) {
                $problems.Add("The report's <style> never ends ($(& $where $token.Index)).")
                $stopped = $true
                break
            }
            $hash = Get-ReportCssHash -Text $Html.Substring($position, $close - $position)
            $sheet = (Get-KnownReportCssHash)[$hash]
            if (-not $sheet) {
                if ($null -eq $currentSheets) { $currentSheets = Get-CurrentReportCssHash }
                $sheet = $currentSheets[$hash]
            }
            if (-not $sheet) { $problems.Add("The report's styles (CSS) are not a style sheet Vouch writes (SHA-256 $hash).") }
            elseif ([int]$counts['style'] -eq 1) { $kind = [string]$sheet }
            $position = $close
            $styleEnd = $close
        }
        elseif ($name -ceq 'img') {
            $set = (@($attributes.Keys | Sort-Object) -join ',')
            $place = $names -join '>'
            if ($set -ceq 'alt,data-captured,data-file,data-sha256,data-url,src') {
                # Stored inside the report, or the file images/<report>/<data-file> next to it.
                $source = $raw['src']
                $form = ''
                if ($source.StartsWith('data:', [System.StringComparison]::Ordinal)) {
                    if ($source -cmatch '^data:image/(?:jpeg|png);base64,[A-Za-z0-9+/=]+$') { $form = 'data:' }
                }
                else {
                    $linked = [regex]::Match($source, '^images/([^/]+)/([^/]+)$')
                    if ($linked.Success -and $linked.Groups[2].Value -ceq $raw['data-file'] -and (Test-ReportImageFolderName -Segment $linked.Groups[1].Value)) {
                        $form = $linked.Groups[1].Value
                    }
                }
                if (-not $form) {
                    $problems.Add("A screenshot's image address is not in the form Vouch writes ($(& $where $token.Index)).")
                }
                elseif ($place -cne 'html>body>section>figure' -or $keys[2] -cne 'section.item') {
                    $problems.Add("A screenshot is not inside the report's evidence section ($(& $where $token.Index)).")
                }
                elseif (($raw['data-file'] -replace '_.*$').TrimStart('0') -cne ($sectionId -replace '^item-').TrimStart('0')) {
                    $problems.Add("A screenshot is not in the section of the page it was taken of ($(& $where $token.Index)).")
                }
                elseif ($kind -ceq 'plain' -and $form -cne 'data:') {
                    $problems.Add("The report links its screenshots, which only a report with report options does, but its styles are those of a report without them ($(& $where $token.Index)).")
                }
                elseif ($null -ne $sourceForm -and $sourceForm -cne $form) {
                    $problems.Add("The report's screenshots are not all stored the same way, or not all in one folder ($(& $where $token.Index)).")
                }
                else {
                    $sourceForm = $form
                    $images.Add([pscustomobject]@{ Attributes = $attributes; Position = $token.Index; Kind = 'screenshot' })
                }
            }
            elseif ($set -ceq 'alt,class,data-vouch-logo,src' -and $raw['alt'] -ceq 'Company logo') {
                # $headerChildren counts this image too: 1 means nothing is before it.
                if ($place -cne 'html>body>header' -or $parentKey -cne 'header.company' -or $headerChildren -ne 1) {
                    $problems.Add("The company logo is not at the start of the report's header ($(& $where $token.Index)).")
                }
                elseif ($raw['src'] -cnotmatch '^data:image/(?:png|jpeg|gif|svg\+xml);base64,[A-Za-z0-9+/=]+$') {
                    $problems.Add("The company logo is not an image stored inside the report ($(& $where $token.Index)).")
                }
                else {
                    $images.Add([pscustomobject]@{ Attributes = $attributes; Position = $token.Index; Kind = 'logo' })
                }
            }
            else {
                $problems.Add("An image is neither a screenshot with its hash nor the company logo ($(& $where $token.Index)).")
            }
        }
        elseif ($name -ceq 'meta') {
            if ((@($raw.Keys | Sort-Object) -join ',') -notin 'charset', 'content,name') { $problems.Add("The report has a <meta> Vouch never writes ($(& $where $token.Index)).") }
        }

        if (-not $void.ContainsKey($name)) { $names.Add($name); $keys.Add($key) }
    }

    if ($problems.Count -ge $limit) { $stopped = $true }
    if (-not $stopped) {
        if ($position -ne $Html.Length) { $problems.Add("The report contains markup Vouch never writes ($(& $where $position))."); $stopped = $true }
        elseif ($names.Count -gt 0) { $problems.Add("The report's <$($names[$names.Count - 1])> is never closed."); $stopped = $true }
    }
    if (-not $stopped) {
        # The whole document was read: is it built the way the generator builds one?
        foreach ($name in 'html', 'head', 'body', 'title', 'style', 'h1') {
            if ([int]$counts[$name] -ne 1) { $problems.Add("The report has $([int]$counts[$name]) <$name> element(s); Vouch writes exactly one.") }
        }
        if (($htmlParts -join ' ') -cne 'head body' -or ($headParts -join ' ') -cne 'meta:charset meta:content,name title style') {
            $problems.Add("The report's <head> and <body> are not set out the way Vouch writes them.")
        }
        if ($kind) {
            # New-HtmlReport's order, for the kind of report the style sheet belongs to.
            $level = if ($kind -cin 'plain', 'options') { '' } else { $kind.ToLowerInvariant() }
            $withOptions = $kind -cne 'plain'
            $pattern = '\A' +
                $(if ($level) { "div\.classification top cls-$level\n" }) +
                $(if ($withOptions) { '(?:header\.company\n)?' }) +
                'h1\.\np\.subtitle\ndiv\.meta\n' +
                $(if ($withOptions) { '(?:nav\.contents-wrap\n)?' }) +
                'h2\.\np\.counts\ntable\.summary\nh2\.\np\.integrity-note\n' +
                $(if ($withOptions) { 'p\.integrity-note\n' }) +
                'p\.manifest\ntable\.summary hashes\nh2\.\n(?:section\.item\n)*footer\.\n' +
                $(if ($level) { "div\.classification bottom cls-$level\n" }) + '\z'
            if ((($bodyParts -join "`n") + "`n") -cnotmatch $pattern) {
                $what = if ($level) { "a report classified $kind" } elseif ($withOptions) { 'a report with report options and no classification' } else { 'a report without report options' }
                $problems.Add("The report's parts are not the ones Vouch writes, in its order, for the styles it has (those of $what): classification banner, company header, title, run details, contents, summary, integrity, evidence, footer, banner.")
            }
        }
    }
    if ($problems.Count -ge $limit) {
        if ($problems.Count -gt $limit) { $problems.RemoveRange($limit, $problems.Count - $limit) }
        $problems.Add("The check stopped here: only the first $limit problems are listed.")
    }
    $result.Kind = $kind
    return $result
}

function Resolve-ReportImagePath {
    <#
        Where a linked image's file is, for -Verify. The report is untrusted input: a
        tampered or hostile report must not make -Verify read files elsewhere on the
        machine or on the network. Only a relative path that stays inside the report's
        own folder is accepted; anything rooted, on another drive or share, with a URL
        scheme, an alternate data stream (any ':'), a query or fragment, or climbing out
        with '..' is refused with a plain reason. Never throws.
        Returns { Path; Problem } - one of them is ''.
    #>
    param(
        [Parameter(Mandatory)][string]$ReportDirectory,
        [AllowEmptyString()][string]$Source = ''
    )
    $refuse = { param([string]$Why) [pscustomobject]@{ Path = ''; Problem = $Why } }
    if ([string]::IsNullOrWhiteSpace($Source)) { return (& $refuse 'the report names no image for it') }
    # Nothing is trimmed away: a browser keeps edge spaces (as %20 or %C2%A0), so the
    # file read here could differ from the one shown.
    if ($Source -cne $Source.Trim()) { return (& $refuse "its image address '$Source' starts or ends with a space") }
    try { $relative = [System.Uri]::UnescapeDataString($Source) }
    catch { return (& $refuse "its image address '$Source' cannot be read") }
    if ($relative -cne $relative.Trim()) { return (& $refuse "its image address '$Source' starts or ends with a space") }

    # A raw # starts a fragment for a browser; written as %23 it is part of a folder's
    # name (a report called "Q3 #1"), which is how the generator writes it.
    if ($Source.Contains('#')) { return (& $refuse "its image '$Source' is not a plain file name (it has a ? or #)") }
    foreach ($text in @($Source, $relative)) {
        if ($text -match '^[A-Za-z]:') { return (& $refuse "its image '$Source' is on a drive of this computer, not next to the report; only images in the report's own folder are checked") }
        if ($text -match '^[A-Za-z][A-Za-z0-9+\-]*:') { return (& $refuse "its image '$Source' is a web or other address, not a file next to the report; only images in the report's own folder are checked") }
        if ($text -match '^[\\/]') { return (& $refuse "its image '$Source' is not inside the report's folder (a rooted or network path); only images in the report's own folder are checked") }
        if ($text.Contains(':')) { return (& $refuse "its image '$Source' is not a plain file name") }
        if ($text.Contains('?')) { return (& $refuse "its image '$Source' is not a plain file name (it has a ? or #)") }
        if ($text -match '[\x00-\x1f]') { return (& $refuse "its image '$Source' contains control characters") }
    }
    try {
        $root = [System.IO.Path]::GetFullPath($ReportDirectory).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative.Replace('/', '\')))
    }
    catch { return (& $refuse "its image '$Source' is not a valid file name") }
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (& $refuse "its image '$Source' points outside the report's folder; only images in the report's own folder are checked")
    }
    return [pscustomobject]@{ Path = $full; Problem = '' }
}

function Test-ReportIntegrity {
    <#
        Re-checks a report without trusting anything but its own contents: every image
        is hashed again and compared with the hash printed for it, the metadata inside
        each image must match the report (capture time, page URL), the manifest hash is
        recomputed from the per-image hashes, and saved images (images\<report>\ with
        SHA256SUMS) are hashed from disk. Returns one row per check.
        Images may be inside the report (data: URIs) or, in a linked report, files next
        to it (Resolve-ReportImagePath decides which files may be read at all). A
        problem with one image is a failed check with a reason, never an exception.

        This shows that the screenshots are the ones the hashes name and that the report
        is built the way Vouch writes it - not that its text is unchanged (Test-ReportMarkup
        checks structure, not words). It cannot tell on its own whether someone rebuilt all
        hashes together, which is why the manifest hash should be kept outside the report.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Report not found: $Path" }
    $results = [System.Collections.Generic.List[object]]::new()
    $add = { param($Check, $Ok, $Detail) $results.Add([pscustomobject]@{ Check = $Check; Ok = [bool]$Ok; Detail = $Detail }) }

    # Whatever the file holds, the answer is a list of checks: a file that cannot be read
    # as a report fails a check; -Verify never ends with an error over a file's contents.
    try {
        $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
        $reportDirectory = Split-Path -Path $Path -Parent
        # Vouch writes UTF-8 without a byte order mark, and the report says so itself
        # (<meta charset>). Read exactly as that, and refuse anything else: with another
        # mark or with bytes that are not UTF-8, .NET and a browser can read two
        # different documents out of one file.
        try { $html = [System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path)) }
        catch [System.ArgumentException] { $html = $null }
        if ($null -eq $html -or ($html.Length -gt 0 -and $html[0] -eq [char]0xFEFF)) {
            & $add 'Report markup' $false 'The report is not plain UTF-8 text without a byte order mark, which is how Vouch writes it.'
            return $results
        }

        # Whitelist: the report may contain only markup and styles Vouch writes, so every
        # picture it can show is a screenshot checked below or the one header logo.
        $scan = Test-ReportMarkup -Html $html
        foreach ($problem in $scan.Problems) {
            $check = if ($problem -like "The report's styles*") { 'Report styles' } else { 'Report markup' }
            & $add $check $false $problem
        }
        $images = @($scan.Images | Where-Object Kind -eq 'screenshot')
        if ($images.Count -eq 0) { & $add 'Report' $false 'No hashed screenshots found - not a Vouch 1.2+ report, or it has no captures.' }

        $manifestLines = [System.Collections.Generic.List[string]]::new()
        $number = 0
        # Vouch shows each screenshot file once. A report that names one again is failed
        # for it once, and no image is read or hashed a second time: otherwise a small
        # report naming one large file thousands of times keeps -Verify busy for minutes.
        # Names and paths are compared as Windows compares them, ignoring case.
        $seenFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # Path -> hash of every image file read here, for the SHA256SUMS check further down.
        $hashByPath = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $repeatReported = $false
        $reportRepeat = {
            param([string]$Name)
            if (-not $repeatReported) {
                & $add 'Report' $false "The report shows the screenshot file '$Name' more than once; a report made by Vouch shows each file once. Repeated screenshots were not checked again."
            }
        }
        foreach ($image in $images) {
            $number++
            $attributes = $image.Attributes
            $read = { param($Name) if ($attributes.ContainsKey($Name)) { [string]$attributes[$Name] } else { '' } }
            $file = & $read 'data-file'
            $listed = & $read 'data-sha256'
            $label = if ($file) { $file } else { "#$number" }
            $manifestLines.Add("$listed  $file")
            if ($file -and -not $seenFiles.Add($file)) { & $reportRepeat $file; $repeatReported = $true; continue }
            if ($listed -cnotmatch '^[0-9a-f]{64}$') {
                & $add "Image $label" $false 'the report lists no valid SHA-256 hash for it'
                continue
            }


            $bytes = $null
            $source = & $read 'src'
            try {
                if ($source -match '^\s*data:') {
                    $embedded = [regex]::Match($source, '^\s*data:image/(?:jpeg|png);base64,([A-Za-z0-9+/=\s]+)$')
                    if (-not $embedded.Success) { & $add "Image $label" $false 'it is not an embedded JPEG or PNG image'; continue }
                    $bytes = [System.Convert]::FromBase64String($embedded.Groups[1].Value)
                }
                else {
                    $located = Resolve-ReportImagePath -ReportDirectory $reportDirectory -Source $source
                    if ($located.Problem) { & $add "Image $label" $false "not checked: $($located.Problem)"; continue }
                    if (-not $seenPaths.Add($located.Path)) { & $reportRepeat $file; $repeatReported = $true; continue }
                    if (-not (Test-Path -LiteralPath $located.Path -PathType Leaf)) {
                        & $add "Image $label" $false "the image file '$source' is missing (a linked report needs its images folder next to it)"
                        continue
                    }
                    $bytes = [System.IO.File]::ReadAllBytes($located.Path)
                    $hashByPath[$located.Path] = Get-Sha256Hex -Bytes $bytes
                }
            }
            catch {
                & $add "Image $label" $false "the image could not be read: $($_.Exception.Message)"
                continue
            }

            $actual = if ($source -match '^\s*data:') { Get-Sha256Hex -Bytes $bytes } else { $hashByPath[$located.Path] }
            & $add "Image $label" ($actual -eq $listed) $(if ($actual -eq $listed) { "SHA-256 $actual" } else { "hash is $actual, report lists $listed" })

            $metadata = $null
            try { $metadata = Get-ImageMetadata -Bytes $bytes }
            catch { Write-Verbose "No metadata readable in $label`: $($_.Exception.Message)" }
            if ($null -eq $metadata) {
                & $add "Metadata $label" $false 'no embedded metadata'
            }
            else {
                $problems = @()
                if ([string]$metadata.CapturedAt -ne (& $read 'data-captured')) { $problems += "capture time $($metadata.CapturedAt) differs from the report" }
                if ([string]$metadata.PageUrl -ne (& $read 'data-url')) { $problems += "page URL $($metadata.PageUrl) differs from the report" }
                & $add "Metadata $label" ($problems.Count -eq 0) $(if ($problems.Count -eq 0) { "$($metadata.ItemName) | $($metadata.CapturedAt) | $($metadata.PageUrl)" } else { $problems -join '; ' })
            }
        }

        # The manifest hash the report states, read from the one place Vouch writes it.
        $stated = [string]$scan.Manifest
        if ($images.Count -gt 0) {
            $recomputed = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes((@($manifestLines) -join "`n") + "`n"))
            if (-not $stated) { & $add 'Manifest' $false 'the report states no manifest hash' }
            else {
                $ok = $recomputed -eq $stated
                & $add 'Manifest' $ok $(if ($ok) { "SHA-256 $recomputed" } else { "recomputed $recomputed, report states $stated" })
            }
        }

        # Saved image files, when the run used -SaveImages (or a linked report).
        $imagesDir = Join-Path -Path $reportDirectory -ChildPath (Join-Path 'images' ([System.IO.Path]::GetFileNameWithoutExtension($Path)))
        $sums = Join-Path -Path $imagesDir -ChildPath 'SHA256SUMS'
        if (Test-Path -LiteralPath $sums -PathType Leaf) {
            $sumsText = [System.IO.File]::ReadAllText($sums)
            $sumsHash = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($sumsText))
            & $add 'SHA256SUMS' ($stated -and $sumsHash -eq $stated) "file hashes to $sumsHash"
            $listedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($line in ($sumsText -split "`n" | Where-Object { $_ -match '^([0-9a-f]{64})  (.+)$' })) {
                $null = $line -match '^([0-9a-f]{64})  (.+)$'
                $expected = $Matches[1]
                $name = $Matches[2]
                # Vouch lists each file once; a list that repeats one is not read on and on.
                if (-not $listedNames.Add($name)) { & $add "File $name" $false 'listed more than once in SHA256SUMS; the rest of the list was not checked'; break }
                # A name from the file is checked like a linked src: it must stay in the folder.
                $located = Resolve-ReportImagePath -ReportDirectory $imagesDir -Source ([System.Uri]::EscapeDataString($name))
                if ($located.Problem) { & $add "File $name" $false "not checked: $($located.Problem)"; continue }
                $filePath = $located.Path
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { & $add "File $name" $false 'missing'; continue }
                $actual = if ($hashByPath.ContainsKey($filePath)) { $hashByPath[$filePath] } else { Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($filePath)) }
                & $add "File $name" ($actual -eq $expected) $(if ($actual -eq $expected) { 'matches' } else { "hash is $actual, expected $expected" })
            }
        }
    }
    catch {
        & $add 'Report' $false "This file could not be checked as a Vouch report: $($_.Exception.Message)"
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

function Expand-NameTemplate {
    <#
        Fills the tokens of a file name template ("{title} {period}.zip"). Token names
        ignore case. A token Vouch does not know is left exactly as written and listed in
        Unknown, so the caller can say so: a typo must show, not silently vanish.
        Returns { Text; Unknown }. The result is not yet a safe file name
        (ConvertTo-SafeOutputName).
    #>
    param(
        [AllowEmptyString()][string]$Template = '',
        # Token name (without braces) -> value.
        [System.Collections.IDictionary]$Values = @{}
    )
    $known = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Values.Keys) { $known[[string]$key] = [string]$Values[$key] }
    $unknown = [System.Collections.Generic.List[string]]::new()
    $text = [regex]::Replace($Template, '\{([^{}]*)\}', {
            param($match)
            $name = $match.Groups[1].Value
            if ($known.ContainsKey($name)) { return $known[$name] }
            if (-not $unknown.Contains($match.Value)) { $unknown.Add($match.Value) }
            return $match.Value
        })
    return [pscustomobject]@{ Text = $text; Unknown = [string[]]@($unknown) }
}

function ConvertTo-SafeOutputName {
    <#
        A file name a person reads (the report or the zip), made safe for Windows but
        kept readable: spaces, dots and letters of any language stay; only what Windows
        forbids in a name (\ / : * ? " < > | and control characters) becomes "_" - so a
        name can never point into another folder. Like Get-SafeFileName it never ends
        with a dot or space and never gives a reserved device name (CON, NUL, COM1...).
        -Extension is added when the name does not already end with it.
    #>
    param(
        [AllowEmptyString()][string]$Name = '',
        [Parameter(Mandatory)][string]$Extension,
        [string]$Fallback = 'VouchEvidence'
    )
    $Extension = '.' + $Extension.TrimStart('.')
    $safe = $Name -replace '[\x00-\x1f\x7f\\/:*?"<>|]+', '_'
    $safe = ($safe -replace '\s+', ' ').Trim(' ', '.')
    if ($safe.EndsWith($Extension, [System.StringComparison]::OrdinalIgnoreCase)) {
        $safe = $safe.Substring(0, $safe.Length - $Extension.Length).Trim(' ', '.')
    }
    if ($safe.Length -gt 150) { $safe = $safe.Substring(0, 150) }
    # Half of a character pair (cut in two just above, or typed that way) cannot be
    # written into a link: a linked report's images folder carries this name.
    $safe = ($safe -replace '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]', '_').Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($safe) -or $safe -match '^_+$') { $safe = $Fallback }
    if ($safe -match '^(?i)(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9¹²³]|LPT[0-9¹²³])(\..*)?$') { $safe = "_$safe" }
    return "$safe$Extension"
}

function Get-ReportFileName {
    <#
        The report's file name from what the user asked for (-ReportName or
        output.reportName, tokens allowed). The images folder of the report carries the
        same name and a linked report's HTML points into it, so the name must be one
        that Windows keeps exactly as written and a browser can follow: every name goes
        through ConvertTo-SafeOutputName - also one typed without tokens, which used to
        be taken as it was (" Q3" or "Q3." then gave a report -Verify could not follow).
        Ordinary names come out unchanged. Returns { Name; Unknown (tokens); Changed }.
    #>
    param(
        [AllowEmptyString()][string]$Name = '',
        [Parameter(Mandatory)][string]$DefaultStem,
        [System.Collections.IDictionary]$Values = @{}
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [pscustomobject]@{ Name = "$DefaultStem.html"; Unknown = [string[]]@(); Changed = $false }
    }
    $text = $Name
    $unknown = [string[]]@()
    if ($text -match '\{[^{}]*\}') {
        $expanded = Expand-NameTemplate -Template $text -Values $Values
        $text = $expanded.Text
        $unknown = $expanded.Unknown
    }
    # The ending as typed (.html, .htm, .HTML) is kept; .html is added when there is none.
    $extension = if ($text.TrimEnd(' ', '.') -match '(?i)\.(html?)$') { $Matches[1] } else { 'html' }
    $safe = ConvertTo-SafeOutputName -Name $text -Extension $extension -Fallback $DefaultStem
    return [pscustomobject]@{ Name = $safe; Unknown = $unknown; Changed = ($safe -cne $text -and $safe -cne "$text.$extension") }
}

function Assert-ReportLocation {
    <#
        Makes the images folder and proves the report file can be made, before anything
        is captured: a name or folder Windows cannot hold (too long, no permission, a
        file in the way) must stop the run at its start with a plain message - not at
        the end, after all the pages, or with a report whose images are somewhere else.
    #>
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [AllowEmptyString()][string]$ImagesDir = ''
    )
    try {
        if ($ImagesDir) {
            [void][System.IO.Directory]::CreateDirectory($ImagesDir)
            # Windows may quietly store another name than the one asked for.
            $made = [System.IO.DirectoryInfo]::new($ImagesDir)
            if (-not $made.Exists -or $made.Name -cne [System.IO.Path]::GetFileName($ImagesDir)) { throw 'Windows cannot keep an images folder of that name.' }
        }
        if ([System.IO.Directory]::Exists($ReportPath)) { throw 'A folder of that name is in the way.' }
        if (-not [System.IO.File]::Exists($ReportPath)) {
            [System.IO.File]::WriteAllText($ReportPath, '', [System.Text.UTF8Encoding]::new($false))
            $made = [System.IO.FileInfo]::new($ReportPath)
            $kept = $made.Exists -and $made.Name -ceq [System.IO.Path]::GetFileName($ReportPath)
            [System.IO.File]::Delete($ReportPath)
            if (-not $kept) { throw 'Windows cannot keep a file of that name.' }
        }
    }
    catch {
        throw ("The report cannot be saved as '$([System.IO.Path]::GetFileName($ReportPath))' in '$(Split-Path -Path $ReportPath -Parent)': $($_.Exception.Message)`n" +
            'Choose a shorter or simpler report name (-ReportName, or "reportName" in the configuration file) or another output folder.')
    }
}

function Get-AvailableFilePath {
    <#
        The path itself when nothing is there yet, otherwise the first free "name_2.ext",
        "name_3.ext", ...: evidence packages are never replaced without anyone noticing.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $folder = Split-Path -Path $Path -Parent
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    for ($n = 2; ; $n++) {
        $candidate = Join-Path -Path $folder -ChildPath "${stem}_$n$extension"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
}

function Get-NameTokenValues {
    <#
        The values of the name tokens for one run: {report} {title} {date} {time}
        {period} {classification}. The date and time are those the run started at, so
        the report and its zip carry the same ones.
    #>
    param(
        [Parameter(Mandatory)][datetime]$When,
        [AllowEmptyString()][string]$Report = '',
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$PeriodFrom = '',
        [AllowEmptyString()][string]$PeriodTo = '',
        [AllowEmptyString()][string]$PeriodLabel = '',
        [AllowEmptyString()][string]$Classification = ''
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $period = if ($PeriodLabel.Trim()) { $PeriodLabel.Trim() } else { (@($PeriodFrom.Trim(), $PeriodTo.Trim()) | Where-Object { $_ }) -join ' to ' }
    return [ordered]@{
        report         = $Report
        title          = $(if ($Title.Trim()) { $Title.Trim() } else { 'Audit Evidence Report' })
        date           = $When.ToString('yyyy-MM-dd', $invariant)
        time           = $When.ToString('HHmmss', $invariant)
        period         = $period
        classification = $(if ($null -ne ($style = Get-ClassificationStyle -Level $Classification)) { $style.Level } else { '' })
    }
}

function New-EvidenceArchive {
    <#
        The evidence package: one zip holding the report, its JSON summary, its capture
        log (as written so far) and its image folder with SHA256SUMS, at the same relative
        places, so the extracted copy is a working report whose links and -Verify still
        work. Only these files go in - not the -LogDir transcript, the event file or
        anything else that happens to be in the output folder.
        The zip is created new (never over an existing file) and removed again if it
        cannot be completed. Returns { Path; Sha256; Entries }.
    #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ReportPath,
        [AllowEmptyString()][string]$SummaryPath = '',
        # The capture log, as far as it is written when the zip is made.
        [AllowEmptyString()][string]$LogPath = '',
        [AllowEmptyString()][string]$ImagesDir = '',
        # The image file names to include (the run's own, from its manifest).
        [AllowEmptyCollection()][string[]]$ImageFiles = @()
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.ZipFile
    $reportFolder = Split-Path -Path $ReportPath -Parent
    $files = [System.Collections.Generic.List[object]]::new()
    $files.Add([pscustomobject]@{ Source = $ReportPath; Entry = [System.IO.Path]::GetFileName($ReportPath) })
    if ($SummaryPath -and (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
        $files.Add([pscustomobject]@{ Source = $SummaryPath; Entry = [System.IO.Path]::GetFileName($SummaryPath) })
    }
    if ($LogPath -and (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        $files.Add([pscustomobject]@{ Source = $LogPath; Entry = [System.IO.Path]::GetFileName($LogPath) })
    }
    if ($ImagesDir -and (Test-Path -LiteralPath $ImagesDir -PathType Container)) {
        $folderEntry = [System.IO.Path]::GetRelativePath($reportFolder, $ImagesDir).Replace('\', '/')
        foreach ($name in @(@($ImageFiles) + 'SHA256SUMS' | Select-Object -Unique)) {
            $source = Join-Path -Path $ImagesDir -ChildPath $name
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $files.Add([pscustomobject]@{ Source = $source; Entry = "$folderEntry/$name" })
            }
        }
    }

    $stream = [System.IO.FileStream]::new($ZipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $completed = $false
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in $files) {
                # Images are already compressed; the HTML and JSON shrink a lot.
                $level = if ($file.Entry -match '(?i)\.(jpe?g|png)$') { [System.IO.Compression.CompressionLevel]::NoCompression } else { [System.IO.Compression.CompressionLevel]::Optimal }
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.Source, $file.Entry, $level)
            }
        }
        finally { $archive.Dispose() }
        $completed = $true
    }
    finally {
        $stream.Dispose()
        if (-not $completed) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{
        Path    = $ZipPath
        Sha256  = Get-FileSha256Hex -Path $ZipPath
        Entries = [string[]]@($files.Entry)
    }
}

function Get-FileSha256Hex {
    # SHA-256 of a file read as a stream: a zip of a large run need not fit in memory.
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}

function Open-ReportFile {
    <#
        Opens the finished report with whatever Windows uses for .html files. Its own
        function so the tests can see whether it was called without a browser opening.
    #>
    param([Parameter(Mandatory)][string]$Path)
    Invoke-Item -LiteralPath $Path
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
        # The report, its form and the output package. A dotted key is a nested value
        # (report.period.from). Invert: the switch says the opposite of the file's key
        # (-NoIndex = "showIndex": false, -LinkImages = "embedImages": false).
        [pscustomobject]@{ Name = 'Account';              Type = 'string'; Section = 'defaults'; Key = 'account' }
        [pscustomobject]@{ Name = 'ReportTitle';          Type = 'string'; Section = 'report';   Key = 'title' }
        [pscustomobject]@{ Name = 'Classification';       Type = 'string'; Section = 'report';   Key = 'classification' }
        [pscustomobject]@{ Name = 'LogoPath';             Type = 'string'; Section = 'report';   Key = 'logoPath' }
        [pscustomobject]@{ Name = 'CompanyName';          Type = 'string'; Section = 'report';   Key = 'company.name' }
        [pscustomobject]@{ Name = 'CompanyDetails';       Type = 'string'; Section = 'report';   Key = 'company.details' }
        [pscustomobject]@{ Name = 'Description';          Type = 'string'; Section = 'report';   Key = 'description' }
        [pscustomobject]@{ Name = 'Origin';               Type = 'string'; Section = 'report';   Key = 'origin' }
        [pscustomobject]@{ Name = 'GeneratedBy';          Type = 'string'; Section = 'report';   Key = 'generatedBy' }
        [pscustomobject]@{ Name = 'PeriodFrom';           Type = 'string'; Section = 'report';   Key = 'period.from' }
        [pscustomobject]@{ Name = 'PeriodTo';             Type = 'string'; Section = 'report';   Key = 'period.to' }
        [pscustomobject]@{ Name = 'PeriodLabel';          Type = 'string'; Section = 'report';   Key = 'period.label' }
        [pscustomobject]@{ Name = 'NoIndex';              Type = 'bool';   Section = 'report';   Key = 'showIndex'; Invert = $true }
        [pscustomobject]@{ Name = 'LinkImages';           Type = 'bool';   Section = 'output';   Key = 'embedImages'; Invert = $true }
        [pscustomobject]@{ Name = 'Zip';                  Type = 'bool';   Section = 'output';   Key = 'zip.enabled' }
        [pscustomobject]@{ Name = 'ZipName';              Type = 'string'; Section = 'output';   Key = 'zip.name' }
        [pscustomobject]@{ Name = 'OpenReport';           Type = 'bool';   Section = 'output';   Key = 'openReport' }
        [pscustomobject]@{ Name = 'NoCaptureLog';         Type = 'bool';   Section = 'output';   Key = 'captureLog'; Invert = $true }
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

    # A dotted key ("period.from") walks into nested objects.
    $value = $container
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $value) { return $notFound }
        if ($value -is [System.Collections.IDictionary]) {
            if (@($value.Keys) -notcontains $part) { return $notFound }
            $value = $value[$part]
        }
        elseif ($value -isnot [string] -and $value -isnot [ValueType] -and $value.PSObject.Properties[$part]) { $value = $value.$part }
        else { return $notFound }
    }

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
            if ($fromConfig.Found) {
                $value = $fromConfig.Value
                if ($definition.PSObject.Properties['Invert'] -and $definition.Invert) { $value = -not [bool]$value }
            }
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
        (-Account, -CaptureArea and -ZoomPercent are the page-level settings that also
        have a command-line switch.)
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
        # -Account / -CaptureArea / -ZoomPercent typed on the command line: already in the run settings.
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
        # The account the page is captured with (defaults.account or the page's own), '' for none.
        Account        = ''
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
    if ($Item.PSObject.Properties['Account'] -and $Settings.PSObject.Properties['Account']) { $Item.Account = ([string]$Settings.Account).Trim() }

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
            Write-RunEvent -Type 'navigation' -Data ([ordered]@{
                pageId = $script:EventPageId; pageIndex = $Item.Index; finalUrl = [string]$Item.FinalUrl; httpStatus = [int]$Item.HttpStatus })
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
        $script:CaptureLogPath = ''
        $script:CaptureLogComplete = $true
        $script:CaptureLogWarned = $false
        $script:EventItem = $null
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

    # Events and the stop file first, so that even a run that cannot start says why -
    # but only for a capture run: -Verify and -LoginSetup capture nothing and must not
    # write into an event file a program may be following.
    if (Test-CaptureRunMode -Settings $settings) {
        Initialize-RunEvent -EventLogPath $settings.EventLogPath
    }
    else {
        $script:EventLogPath = ''
    }
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

    if (-not (Test-Path -LiteralPath $settings.OutputDir)) {
        [void](New-Item -ItemType Directory -Path $settings.OutputDir -Force)
    }
    $resolvedOutputDir = (Resolve-Path -LiteralPath $settings.OutputDir).Path

    # One moment names everything of this run: the default report name, {date}, {time}.
    $runStamp = Get-Date
    $tokenArguments = @{
        When = $runStamp; Title = $settings.ReportTitle; Classification = $settings.Classification
        PeriodFrom = $settings.PeriodFrom; PeriodTo = $settings.PeriodTo; PeriodLabel = $settings.PeriodLabel
    }
    $defaultReportStem = "VouchReport_$($runStamp.ToString('yyyy-MM-dd_HHmmss'))"
    # {report} in the report's own name is the name it would have had.
    $reportFile = Get-ReportFileName -Name $settings.ReportName -DefaultStem $defaultReportStem -Values (Get-NameTokenValues @tokenArguments -Report $defaultReportStem)
    foreach ($token in $reportFile.Unknown) { Write-Host "WARNING: the report name has the token $token, which Vouch does not know; it is left as written." -ForegroundColor Yellow }
    $effectiveReportName = $reportFile.Name
    if ($reportFile.Changed) {
        Write-Host "NOTE: the report is saved as '$effectiveReportName': the name asked for has characters, or a beginning or ending, that Windows does not keep in a file name." -ForegroundColor Yellow
    }
    $reportPath = Join-Path -Path $resolvedOutputDir -ChildPath $effectiveReportName
    $reportStem = [System.IO.Path]::GetFileNameWithoutExtension($effectiveReportName)

    # A linked report shows the image files, so they must be saved.
    $embedImages = -not $settings.LinkImages
    if (-not $embedImages) { $settings.SaveImages = $true }

    # One folder per report, so a later run never overwrites the images (and with them
    # the hashes) of an earlier one.
    $imagesDir = ''
    if ($settings.SaveImages) {
        $imagesDir = Join-Path -Path $resolvedOutputDir -ChildPath (Join-Path 'images' ([System.IO.Path]::GetFileNameWithoutExtension($effectiveReportName)))
    }
    Assert-ReportLocation -ReportPath $reportPath -ImagesDir $imagesDir

    $imageExtension = if ($settings.ImageFormat -eq 'png') { 'png' } else { 'jpg' }
    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $captureContext = @{
        RunId      = $script:EventRunId
        Format     = $settings.ImageFormat
        Quality    = $settings.JpegQuality
        Extension  = $imageExtension
        SaveImages = [bool]$settings.SaveImages
        ImagesDir  = $imagesDir
        EmbedImages = $embedImages
        Screen     = "$($screenBounds.Width)x$($screenBounds.Height)"
    }
    $runStart = [System.DateTimeOffset]::Now
    $items = [System.Collections.Generic.List[object]]::new()
    $captureDesktop = $null
    $desktopNote = 'The signed-in desktop (-UseVirtualDesktop not set)'
    $script:InteractiveRun = Test-InteractiveRun -NoPrompt $settings.NoPrompt
    # Kept for the end of the run (opening the report): InteractiveRun is reset before that.
    $interactiveRun = $script:InteractiveRun
    # The capture log starts now and grows with the run (Write-RunEvent), next to the report.
    $captureLogPath = if ($settings.NoCaptureLog) { '' } else { [System.IO.Path]::ChangeExtension($reportPath, '.log') }
    Start-CaptureLog -Path $captureLogPath
    $imageText = if ($settings.ImageFormat -eq 'png') { 'PNG images' } else { "JPEG images (quality $($settings.JpegQuality))" }
    $runClassification = Get-ClassificationStyle -Level $settings.Classification
    Write-RunEvent -Type 'runStart' -Data ([ordered]@{
        toolVersion = $script:ToolVersion; pageCount = $definitions.Count; reportPath = $reportPath
        source = $sourcePath; interactive = $script:InteractiveRun; stopFile = (Get-StopFilePath); processId = $PID
        computer = [string]$env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; account = ([string]$settings.Account).Trim()
        outputDir = $resolvedOutputDir; reportFile = $effectiveReportName; captureArea = (Get-PageCaptureMode -Settings $settings).Area
        zoomPercent = (Get-PageCaptureMode -Settings $settings).ZoomPercent; imageFormat = $imageText
        classification = $(if ($null -ne $runClassification) { $runClassification.Level } else { '' })
        logPath = $script:CaptureLogPath })

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
            # From here the page's details become "detail" events as they are added.
            $script:EventItem = $item
            $script:EventDetailCount = 0
            $pageSettings = Get-PageSettings -Settings $settings -Definition $definition -Config $config -BoundNames $boundNames
            [void](Invoke-CaptureItem -Definition $definition -Item $item -ItemCount $definitions.Count `
                -Settings $pageSettings -CaptureContext $captureContext)
            Write-RunEvent -Type 'pageEnd' -Data ([ordered]@{
                pageId = $pageId; pageIndex = $item.Index; index = $position; total = $definitions.Count
                status = $item.Status; details = @($item.Details); captureCount = $item.Captures.Count
                finalUrl = [string]$item.FinalUrl; stopped = [bool]$script:StopRequested })
            $script:EventItem = $null
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

    # A logo is decoration: any problem with it is a warning and the report goes on.
    $logoPath = $settings.LogoPath
    if ($logoPath) { $logoPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($logoPath) }
    $logo = Get-LogoDataUri -Path $logoPath
    if ($logo.Warning) { Write-Host "WARNING: $($logo.Warning)" -ForegroundColor Yellow }
    $reportOptions = New-ReportOptions -Title $settings.ReportTitle -Classification $settings.Classification `
        -LogoPath $logoPath -LogoDataUri $logo.DataUri -CompanyName $settings.CompanyName -CompanyDetails $settings.CompanyDetails `
        -Description $settings.Description -Origin $settings.Origin -GeneratedBy $settings.GeneratedBy `
        -PeriodFrom $settings.PeriodFrom -PeriodTo $settings.PeriodTo -PeriodLabel $settings.PeriodLabel `
        -Account $settings.Account -ShowIndex (-not $settings.NoIndex) -EmbedImages $embedImages `
        -CaptureLogName $(if ($script:CaptureLogPath) { [System.IO.Path]::GetFileName($script:CaptureLogPath) } else { '' }) `
        -ImageFolder $(if ($imagesDir) { [System.IO.Path]::GetRelativePath($resolvedOutputDir, $imagesDir) } else { '' })

    $html = New-HtmlReport -Items @($items) -Run $run -Options $reportOptions
    [System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($false))
    $html = $null

    $reportSizeMb = [Math]::Round((Get-Item -LiteralPath $reportPath).Length / 1MB, 1)
    $script:ExitCode = if ($failCount -gt 0) { 2 } elseif ($settings.FailOnWarning -and $warnCount -gt 0) { 3 } else { 0 }

    # The zip's name is known before the summary is written, so the summary inside the
    # zip can name it; its hash is known only afterwards (see ConvertTo-RunSummaryJson).
    $zipPath = ''
    if ($settings.Zip) {
        $zipTemplate = if ([string]::IsNullOrWhiteSpace($settings.ZipName)) { '{report}.zip' } else { $settings.ZipName }
        $expanded = Expand-NameTemplate -Template $zipTemplate -Values (Get-NameTokenValues @tokenArguments -Report $reportStem)
        foreach ($token in $expanded.Unknown) { Write-Host "WARNING: the zip name has the token $token, which Vouch does not know; it is left as written." -ForegroundColor Yellow }
        $zipPath = Get-AvailableFilePath -Path (Join-Path -Path $resolvedOutputDir -ChildPath (ConvertTo-SafeOutputName -Name $expanded.Text -Extension 'zip' -Fallback $reportStem))
    }

    $summaryPath = ''
    $writeSummary = {
        param($Zip)
        $json = ConvertTo-RunSummaryJson -Items @($items) -Run $run -ReportPath $reportPath -ExitCode $script:ExitCode -Options $reportOptions -Zip $Zip `
            -LogPath $captureLogPath -LogComplete ([bool]$script:CaptureLogComplete)
        [System.IO.File]::WriteAllText($summaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    }
    if ($settings.JsonSummary) {
        $summaryPath = [System.IO.Path]::ChangeExtension($reportPath, '.json')
        & $writeSummary $(if ($zipPath) { [pscustomobject]@{ Path = $zipPath; Sha256 = $null } } else { $null })
    }

    $archive = $null
    if ($zipPath) {
        # Said before the zip is made, so the log inside the zip says where it ends.
        Write-RunEvent -Type 'archive' -Data ([ordered]@{ zipPath = $zipPath })
        try {
            $archive = New-EvidenceArchive -ZipPath $zipPath -ReportPath $reportPath -SummaryPath $summaryPath -LogPath $script:CaptureLogPath -ImagesDir $imagesDir `
                -ImageFiles ([string[]]@($items | ForEach-Object { $_.Captures } | ForEach-Object { $_.FileName }))
        }
        catch {
            # The report itself is written and complete; only the package is missing.
            Write-Host "WARNING: the zip file '$zipPath' could not be made: $($_.Exception.Message) The report and its files are in $resolvedOutputDir." -ForegroundColor Yellow
            $archive = $null
        }
        # Now with the zip's hash - or without the zip, which then does not exist.
        if ($summaryPath) { & $writeSummary $archive }
    }

    Write-Host ''
    if ($script:StopRequested) {
        Write-Host "Stopped by the user after $($items.Count) of $($definitions.Count) page(s)." -ForegroundColor Yellow
    }
    Write-Host "Done. $($items.Count) item(s): $okCount OK, $warnCount warning(s), $failCount failed. $captureCount screenshot(s)." -ForegroundColor Cyan
    if ($settings.SaveImages) { Write-Host "Individual images: $imagesDir" }
    Write-Host "Report: $reportPath ($reportSizeMb MB)" -ForegroundColor Cyan
    if ($summaryPath) { Write-Host "Summary: $summaryPath" }
    if ($null -ne $archive) { Write-Host "Zip: $($archive.Path) (SHA-256 $($archive.Sha256))" -ForegroundColor Cyan }
    if ($script:CaptureLogPath) {
        Write-Host "Capture log: $($script:CaptureLogPath)"
        if (-not $script:CaptureLogComplete) { Write-Host 'WARNING: the capture log is incomplete: some of its lines could not be written.' -ForegroundColor Yellow }
    }
    elseif ($captureLogPath) { Write-Host "WARNING: no capture log was written ($captureLogPath could not be created)." -ForegroundColor Yellow }
    Remove-StopFile
    Write-RunEvent -Type 'runEnd' -Data ([ordered]@{
        exitCode = $script:ExitCode; reportPath = $reportPath; jsonSummaryPath = $summaryPath
        counts = [ordered]@{
            pages = $definitions.Count; run = $items.Count; ok = $okCount; warning = $warnCount; failed = $failCount
            notRun = $definitions.Count - $items.Count; captures = [int]$captureCount }
        stopped = [bool]$script:StopRequested
        zipPath = $(if ($null -ne $archive) { $archive.Path } else { '' })
        zipSha256 = $(if ($null -ne $archive) { $archive.Sha256 } else { '' })
        manifestSha256 = $run.ManifestSha256; elapsedSec = [Math]::Round(([System.DateTimeOffset]::Now - $runStart).TotalSeconds, 1)
        logPath = $script:CaptureLogPath; logComplete = [bool]$script:CaptureLogComplete })

    # Last of all, when everything (the zip too) is finished - and only for a person.
    if ($settings.OpenReport) {
        if ($interactiveRun) {
            try { Open-ReportFile -Path $reportPath }
            catch { Write-Host "WARNING: the report could not be opened: $($_.Exception.Message) It is at $reportPath." -ForegroundColor Yellow }
        }
        else {
            Write-Host 'The report is not opened: nobody is watching this run (a scheduled or -NoPrompt run).'
        }
    }
}

function Test-CaptureRunMode {
    <#
        Whether these settings start a capture run (and so a run with progress events),
        rather than -Verify or -LoginSetup, which capture nothing. A further mode that
        captures nothing (the Designer) belongs on the "no" side here too.
    #>
    param([Parameter(Mandatory)][object]$Settings)
    foreach ($mode in 'Verify', 'LoginSetup', 'Designer') {
        if ($Settings.PSObject.Properties[$mode] -and $Settings.$mode) { return $false }
    }
    return $true
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
        exitCode = 1; reportPath = ''; jsonSummaryPath = ''; counts = $null; stopped = [bool]$script:StopRequested
        logPath = $script:CaptureLogPath; logComplete = [bool]$script:CaptureLogComplete })
}

function Invoke-DesignerMode {
    <#
        -Designer: serves the Designer panel instead of running a capture. It returns before
        any of a capture run's setup (no transcript, no run events, no capture log). The
        Designer's code lives in designer\Designer.ps1 and Designer.Run.ps1 so that this file stays one
        self-contained engine; it is loaded only here, and a copy of vouch.ps1 without the
        folder still does everything else.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyString()][string]$ConfigPath = '',
        [int]$Port = 0,
        # The audit profile the Designer must stay apart from, when typed (-EdgeProfileDir).
        [AllowEmptyString()][string]$EdgeProfileDir = '',
        # The audit Edge's port when typed (-DebugPort); 0 = the configuration's, else 9222.
        [int]$DebugPort = 0,
        [switch]$KeepBrowserOpen,
        [AllowEmptyCollection()][string[]]$IgnoredParameters = @()
    )
    Assert-Environment
    $designerScript = Join-Path -Path (Split-Path -Path $ScriptPath -Parent) -ChildPath 'designer\Designer.ps1'
    # Runs from the panel live in a second functions-only file next to it.
    $designerRunScript = Join-Path -Path (Split-Path -Path $ScriptPath -Parent) -ChildPath 'designer\Designer.Run.ps1'
    if (-not (Test-Path -LiteralPath $designerScript -PathType Leaf) -or -not (Test-Path -LiteralPath $designerRunScript -PathType Leaf)) {
        throw ("The Vouch Designer needs the folder 'designer' next to vouch.ps1 ($(Split-Path -Path $designerScript -Parent)), and it is not there. " +
            'Copy the whole Vouch folder, not only vouch.ps1. Everything else vouch.ps1 does works without it.')
    }
    if ($IgnoredParameters.Count -gt 0) {
        Write-Host "NOTE: with -Designer only -ConfigPath, -DesignerPort, -EdgeProfileDir, -DebugPort and -KeepBrowserOpen are used; these are ignored: -$($IgnoredParameters -join ', -')" -ForegroundColor Yellow
    }
    . $designerScript
    . $designerRunScript
    Start-VouchDesigner -ScriptPath $ScriptPath -ConfigPath $ConfigPath -Port $Port -Version $script:ToolVersion -AuditProfileDir $EdgeProfileDir `
        -DebugPort $DebugPort -KeepBrowserOpen:$KeepBrowserOpen
}

if ($Designer) {
    try {
        $ignored = @($PSBoundParameters.Keys | Where-Object { $_ -notin 'Designer', 'DesignerPort', 'ConfigPath', 'EdgeProfileDir', 'DebugPort', 'KeepBrowserOpen', 'Verbose', 'Debug' })
        $auditProfile = if ($PSBoundParameters.ContainsKey('EdgeProfileDir')) { $EdgeProfileDir } else { '' }
        $auditPort = if ($PSBoundParameters.ContainsKey('DebugPort')) { $DebugPort } else { 0 }
        Invoke-DesignerMode -ScriptPath $PSCommandPath -ConfigPath $ConfigPath -Port $DesignerPort -EdgeProfileDir $auditProfile `
            -DebugPort $auditPort -KeepBrowserOpen:$KeepBrowserOpen -IgnoredParameters $ignored
    }
    catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($null -ne $_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
        exit 1
    }
    exit 0
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
