#Requires -Version 7

<#
.SYNOPSIS
    Captures audit-evidence screenshots of web application configuration pages.

.DESCRIPTION
    Drives Microsoft Edge through the Chrome DevTools Protocol (CDP) and takes REAL
    screen captures (GDI CopyFromScreen) of the primary display, so the Windows taskbar
    clock is part of every image. Long pages are captured as a series of viewport
    segments. Everything is assembled into a single self-contained HTML report with
    base64-embedded images.

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

    [string]$Verify = '',

    [switch]$LoginSetup
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

function Test-LegacyActionList {
    <#
        TEMPORARY - remove when the engine runs action lists (Invoke-PageAction).
        The engine still runs a page as "steps, then one capture that scrolls the page or
        not". A configuration may already describe more (waiting for an element,
        pausing for the user, several captures, scrolling a chosen area); running such a
        page the old way would produce different evidence than the file asks for, so the
        page is refused with a reason instead. Returns { Supported; Reason }.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions)

    $problems = [System.Collections.Generic.List[string]]::new()
    $captures = @($Actions | Where-Object { $_['type'] -eq 'capture' })
    if ($captures.Count -gt 1) { $problems.Add("$($captures.Count) captures") }
    foreach ($type in 'waitFor', 'pause') {
        if (@($Actions | Where-Object { $_['type'] -eq $type }).Count -gt 0) { $problems.Add("a ""$type"" action") }
    }
    if ($Actions.Count -gt 0 -and $Actions[-1]['type'] -ne 'capture') { $problems.Add('actions after the capture') }
    foreach ($capture in $captures) {
        $mode = [string]$capture['scroll']['mode']
        if ($mode -in 'page', 'area' -and -not $problems.Contains("scroll mode ""$mode""")) { $problems.Add("scroll mode ""$mode""") }
        if ($mode -ne 'none' -and $capture['scroll']['as'] -eq 'single' -and -not $problems.Contains('one tall image ("as": "single")')) {
            $problems.Add('one tall image ("as": "single")')
        }
    }
    if ($problems.Count -eq 0) { return [pscustomobject]@{ Supported = $true; Reason = '' } }
    return [pscustomobject]@{
        Supported = $false
        Reason    = "Not captured: this page uses $($problems -join ', '), which this version of Vouch cannot run yet. Remove it or use a newer vouch.ps1."
    }
}

function Get-InactiveConfigSetting {
    <#
        TEMPORARY - shrink as each setting starts working (capture area and zoom,
        prompts, report fields, zip, open when done).
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
    $pageKeys = 'account', 'captureArea', 'zoomPercent', 'waitFor', 'onNotReady', 'promptTimeoutSec'
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

function Get-CdpPageTarget {
    <#
        Returns an existing tab, or opens one. Right after the DevTools port opens, a
        freshly launched Edge briefly lists no tabs at all even though its about:blank
        tab is on its way, so wait up to -WaitSeconds for it rather than opening a
        second tab that would then show up in every screenshot.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [double]$WaitSeconds = 0
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

        foreach ($target in $targets) {
            if ($target.PSObject.Properties['type'] -and $target.type -eq 'page' -and
                $target.PSObject.Properties['webSocketDebuggerUrl'] -and
                -not [string]::IsNullOrWhiteSpace($target.webSocketDebuggerUrl)) {
                $targetUrl = if ($target.PSObject.Properties['url']) { [string]$target.url } else { '' }
                if ($targetUrl -notlike 'devtools://*') { return $target }
            }
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    } while ((Get-Date) -lt $deadline)

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
    #>
    $url = $script:CdpWebSocketUrl
    Close-CdpSocket
    try {
        Connect-CdpSocket -WebSocketUrl $url
        return
    }
    catch {
        Write-Verbose "Reconnecting to the same tab failed: $($_.Exception.Message)"
    }
    if ($script:CdpPort -le 0) { throw 'The DevTools connection was lost and could not be re-established.' }
    $target = Get-CdpPageTarget -Port $script:CdpPort
    if ($null -eq $target -or -not $target.PSObject.Properties['webSocketDebuggerUrl']) {
        throw 'The DevTools connection was lost and no page target is available to reconnect to.'
    }
    Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
}

function Receive-CdpMessage {
    <#
        Reads exactly one WebSocket message. CDP payloads routinely exceed any single
        buffer, so frames are accumulated until EndOfMessage before decoding.
    #>
    param([Parameter(Mandatory)][datetime]$Deadline)

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
                if ((Get-Date) -ge $Deadline) {
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
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 0
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
    #>
    param(
        [Parameter(Mandatory)][int]$TimeoutSec,
        [double]$SameDocumentGraceSeconds = 3
    )

    $expression = "(typeof window.__vouchMark === 'undefined' ? 'new' : 'old') + '|' + document.readyState"
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
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
        run, by whom and where.
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
        [string]$Screen = ''
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

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
        }
        finally {
            $graphics.Dispose()
        }

        $stream = [System.IO.MemoryStream]::new()
        try {
            $encoder = $null
            if ($Format -eq 'jpeg') {
                $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                    Where-Object { $_.MimeType -eq 'image/jpeg' } |
                    Select-Object -First 1
            }
            if ($null -ne $encoder) {
                if ($null -ne $Metadata) { Set-JpegMetadata -Image $bitmap -Metadata $Metadata }
                $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
                try {
                    $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
                    $bitmap.Save($stream, $encoder, $encoderParameters)
                }
                finally {
                    $encoderParameters.Dispose()
                }
                # The leading comma keeps the byte array intact instead of streaming it out byte by byte.
                return , $stream.ToArray()
            }

            # PNG (asked for, or no JPEG encoder available).
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $png = $stream.ToArray()
            if ($null -ne $Metadata) { $png = Add-PngTextChunks -Png $png -Metadata $Metadata }
            return , $png
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $bitmap.Dispose()
    }
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

        Candidates: the window; every element that scrolls vertically; every frame (same
        site) whose document scrolls - including elements inside frames. The one with
        the largest visible area wins, so an ordinary scrolling page keeps using the
        window. Areas smaller than a quarter of the screen are ignored (sidebars, code
        boxes). Other large scrolling areas, and large frames from another site, are
        reported so the item can be flagged: their hidden content is not captured.

        Leaves window.__vouchTarget with measure() -> {view,total,top} and to(y) -> top.
    #>
    return @"
(function () {
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
  var candidates = [];
  var topScroller = document.scrollingElement || document.documentElement;
  if (topScroller.scrollHeight > vh + 16) {
    candidates.push({ kind: 'window', area: viewArea, desc: 'the page', node: null, entry: docs.list[0] });
  }
  docs.list.forEach(function (entry) {
    var off = offsetOf(entry);
    if (entry.frame) {
      var fs = entry.doc.scrollingElement || entry.doc.documentElement;
      if (fs && fs.scrollHeight > entry.win.innerHeight + 16) {
        candidates.push({ kind: 'frame', area: visibleArea(entry.frame.getBoundingClientRect(), offsetOf(entry.parent)),
          desc: 'the frame ' + vouchFrameName(entry.frame), node: entry.frame, entry: entry });
      }
    }
    var all = entry.doc.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el === entry.doc.documentElement || el.clientHeight < 50 || el.scrollHeight <= el.clientHeight + 16) { continue; }
      var oy = entry.win.getComputedStyle(el).overflowY;
      if (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') { continue; }
      candidates.push({ kind: 'element', area: visibleArea(el.getBoundingClientRect(), off),
        desc: describe(el) + (entry.frame ? ' in the frame ' + vouchFrameName(entry.frame) : ''), node: el, entry: entry });
    }
  });

  var usable = candidates.filter(function (c) { return c.area >= viewArea * 0.25; })
    .sort(function (a, b) { return b.area - a.area; });
  var chosen = usable.length > 0 ? usable[0] : null;
  function related(c) {
    if (!chosen) { return false; }
    if (chosen.kind === 'frame' && c.entry === chosen.entry) { return true; }
    if (c.kind === 'frame' && chosen.entry === c.entry) { return true; }
    if (c.entry === chosen.entry && c.node && chosen.node && (c.node.contains(chosen.node) || chosen.node.contains(c.node))) { return true; }
    return false;
  }
  var others = usable.slice(1).filter(function (c) { return !related(c); }).map(function (c) { return c.desc; });
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
  return { kind: t ? t.kind : 'none', description: t ? t.desc : '', view: m.view, total: m.total, others: others, blockedFrames: blocked };
})()
"@
}

function Get-BlockedFrameNote {
    param([int]$Count)
    if ($Count -le 0) { return '' }
    return " The page also contains $Count frame(s) from another site, which Vouch cannot look inside."
}

function Invoke-ClickSelector {
    <#
        Clicks the first element matching the selector, looking in the page first and
        then in its frames (same site only).
    #>
    param([Parameter(Mandatory)][string]$Selector)

    $literal = ConvertTo-JsLiteral -Value $Selector
    $expression = @"
(function (sel) {
$(Get-FrameDocsScript)
  var docs = vouchDocs();
  for (var i = 0; i < docs.list.length; i++) {
    var el = docs.list[i].doc.querySelector(sel);
    if (!el) { continue; }
    if (el.scrollIntoView) { el.scrollIntoView({ block: 'center' }); }
    el.click();
    return 'OK';
  }
  return 'NOTFOUND|' + docs.blocked.length;
})($literal)
"@
    $outcome = [string](Invoke-CdpEval -Expression $expression)
    if ($outcome -ne 'OK') {
        $blocked = if ($outcome -match '\|(\d+)$') { [int]$Matches[1] } else { 0 }
        throw "No element matched the CSS selector '$Selector'.$(Get-BlockedFrameNote -Count $blocked)"
    }
}

function Invoke-ClickText {
    param([Parameter(Mandatory)][string]$Text)

    <#
        Only rendered elements are considered: hidden duplicates (collapsed mobile menus
        and the like) come earlier in the DOM surprisingly often. An exact match wins;
        otherwise the partial match with the shortest label, i.e. the closest one. A
        partial match never selects a sign-out control unless the wanted text itself
        says so - clicking "Log out" for "Log" would end the audit profile's session.
        The page is searched first, then its frames (same site only).
    #>
    $literal = ConvertTo-JsLiteral -Value $Text
    $expression = @"
(function (wanted) {
$(Get-FrameDocsScript)
  var target = String(wanted).replace(/\s+/g, ' ').trim().toLowerCase();
  var label = function (el) {
    var text = el.innerText || el.textContent || el.value || '';
    return String(text).replace(/\s+/g, ' ').trim().toLowerCase();
  };
  var signOut = /\b(log|sign)\s*-?\s*(out|off)\b/;
  var docs = vouchDocs();
  var hiddenMatch = false;
  var exact = null;
  var partial = null;
  for (var d = 0; d < docs.list.length && !exact; d++) {
    var entry = docs.list[d];
    var nodes = entry.doc.querySelectorAll(
      'a,button,[role=button],[role=tab],[role=menuitem],input[type=submit],input[type=button]');
    for (var i = 0; i < nodes.length; i++) {
      var text = label(nodes[i]);
      if (text.indexOf(target) === -1) { continue; }
      if (!vouchVisible(entry, nodes[i])) { hiddenMatch = true; continue; }
      if (text === target) { exact = nodes[i]; break; }
      if (signOut.test(text) && !signOut.test(target)) { continue; }
      if (!partial || text.length < label(partial).length) { partial = nodes[i]; }
    }
  }
  var pick = exact || partial;
  if (!pick) { return (hiddenMatch ? 'HIDDEN' : 'NOTFOUND') + '|' + docs.blocked.length; }
  if (pick.scrollIntoView) { pick.scrollIntoView({ block: 'center' }); }
  pick.click();
  return 'OK';
})($literal)
"@
    $outcome = [string](Invoke-CdpEval -Expression $expression)
    $blocked = if ($outcome -match '\|(\d+)$') { [int]$Matches[1] } else { 0 }
    if ($outcome -like 'HIDDEN*') {
        throw "Only hidden elements have the text '$Text'; nothing was clicked.$(Get-BlockedFrameNote -Count $blocked)"
    }
    if ($outcome -ne 'OK') {
        throw "No clickable element with the text '$Text' was found.$(Get-BlockedFrameNote -Count $blocked)"
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
            if ($ready) { return }
            Start-Sleep -Milliseconds 250
        }
        throw "The click loaded a page inside a frame that did not finish loading within $TimeoutSec seconds."
    }

    if (-not (Wait-PageReady -TimeoutSec $TimeoutSec -SameDocumentGraceSeconds $TimeoutSec)) {
        throw "The click opened a page that did not finish loading within $TimeoutSec seconds."
    }
}

function Invoke-RowSteps {
    <#
        Runs the parsed steps for one row. Every step is isolated: a failure is recorded
        and the remaining steps still run, so a capture is always produced.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
        [Parameter(Mandatory)][double]$SettleSeconds,
        [int]$NavigationTimeoutSec = 30
    )

    $log = [System.Collections.Generic.List[object]]::new()

    foreach ($step in $Steps) {
        $entry = [pscustomobject]@{ Text = $step.Text; Ok = $true; Message = '' }
        try {
            switch ($step.Verb) {
                'click' {
                    Set-StepNavigationProbe
                    Invoke-ClickSelector -Selector ([string]$step.Argument)
                    Start-Sleep -Milliseconds ([int]($SettleSeconds * 1000))
                    Wait-StepNavigation -TimeoutSec $NavigationTimeoutSec
                }
                'clicktext' {
                    Set-StepNavigationProbe
                    Invoke-ClickText -Text ([string]$step.Argument)
                    Start-Sleep -Milliseconds ([int]($SettleSeconds * 1000))
                    Wait-StepNavigation -TimeoutSec $NavigationTimeoutSec
                }
                'wait' {
                    Start-Sleep -Milliseconds ([int]([double]$step.Argument * 1000))
                }
            }
        }
        catch {
            $entry.Ok = $false
            $entry.Message = $_.Exception.Message
        }
        $log.Add($entry)
    }

    return , $log
}

function New-CaptureRecord {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        # Empty when the browser would not report its URL; the screenshot still counts.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Url,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][int]$SegmentCount,
        [string]$FilePath = '',
        [string]$FileName = '',
        [System.Nullable[System.DateTimeOffset]]$CapturedAt = $null
    )

    # PowerShell hands a Nullable parameter over already unwrapped.
    $when = if ($null -ne $CapturedAt) { [System.DateTimeOffset]$CapturedAt } else { [System.DateTimeOffset]::Now }
    return [pscustomobject]@{
        Timestamp    = $when.ToString('yyyy-MM-dd HH:mm:ss')
        CapturedAt   = $when.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [System.Globalization.CultureInfo]::InvariantCulture)
        Url          = $Url
        SegmentIndex = $SegmentIndex
        SegmentCount = $SegmentCount
        Base64       = [Convert]::ToBase64String($Bytes)
        Bytes        = $Bytes.Length
        Sha256       = Get-Sha256Hex -Bytes $Bytes
        FileName     = $FileName
        FilePath     = $FilePath
    }
}

function Add-ItemCapture {
    <#
        One screenshot for an item: stamp the metadata, capture, save (with -SaveImages)
        and record the SHA-256 of the exact bytes that went into the report and the file.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][int]$SegmentCount,
        [AllowEmptyString()][string]$PageUrl = '',
        [Parameter(Mandatory)][hashtable]$Context
    )

    $fileName = '{0:d3}_{1}_seg{2:d2}.{3}' -f $Item.Index, (Get-SafeFileName -Name $Item.Name), $SegmentIndex, $Context.Extension
    $capturedAt = [System.DateTimeOffset]::Now
    $metadata = New-CaptureMetadata -RunId $Context.RunId -ItemIndex $Item.Index -ItemName $Item.Name -RequestedUrl $Item.Url `
        -PageUrl $PageUrl -CapturedAt $capturedAt -SegmentIndex $SegmentIndex -SegmentCount $SegmentCount -Screen $Context.Screen
    $bytes = Get-ScreenCapture -Format $Context.Format -Quality $Context.Quality -Metadata $metadata

    $filePath = ''
    if ($Context.SaveImages) {
        $filePath = Join-Path -Path $Context.ImagesDir -ChildPath $fileName
        [System.IO.File]::WriteAllBytes($filePath, $bytes)
    }
    $Item.Captures.Add((New-CaptureRecord -Bytes $bytes -Url $PageUrl -SegmentIndex $SegmentIndex -SegmentCount $SegmentCount `
        -FilePath $filePath -FileName $fileName -CapturedAt $capturedAt))
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
    [void]$sb.AppendLine("<p class=""subtitle"">Screen captures of live application pages, including the Windows taskbar clock.</p>")

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
                if ($step.Ok) {
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
            foreach ($capture in $item.Captures) {
                $segmentText = if ($capture.SegmentCount -gt 1) { " &middot; segment $($capture.SegmentIndex) of $($capture.SegmentCount)" } else { '' }
                [void]$sb.AppendLine('<figure>')
                # The data-* attributes are what -Verify checks each image against; keep
                # their order in step with Test-ReportIntegrity.
                [void]$sb.Append('<img alt="')
                [void]$sb.Append((Encode-Html "$($item.Name) screenshot $($capture.SegmentIndex) of $($capture.SegmentCount)"))
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
                [void]$sb.AppendLine("<figcaption>Captured $(Encode-Html $capture.Timestamp)$segmentText &middot; $(Encode-Html $capture.Url)<br>" +
                    "<span class=""hash"">SHA-256 $($capture.Sha256) &middot; $(Encode-Html $capture.FileName)</span></figcaption>")
                [void]$sb.AppendLine('</figure>')
            }
        }

        [void]$sb.AppendLine('</section>')
    }

    [void]$sb.AppendLine("<footer>Generated by vouch.ps1 v$($Run.ToolVersion) on $(Encode-Html $Run.EndTime) ($(Encode-Html $Run.TimeZone)). Screenshots are unretouched captures of the primary display.</footer>")
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
        Settings without a config location (CsvPath, ConfigPath, Only, Verify, LoginSetup)
        are command-line only: they choose what the run does, not how it captures.
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
        [pscustomobject]@{ Name = 'Verify';               Type = 'string'; Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'LoginSetup';           Type = 'bool';   Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'ConfigPath';           Type = 'string'; Section = '';         Key = '' }
        [pscustomobject]@{ Name = 'Only';                 Type = 'list';   Section = '';         Key = '' }
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
    foreach ($setting in @(Get-RunSettingDefinition | Where-Object Section -eq 'defaults')) {
        if ($BoundNames -contains $setting.Name) { continue }
        $fromPage = Get-ConfigValue -Config $overrides -Section 'defaults' -Key $setting.Key
        if ($fromPage.Found) { $page[$setting.Name] = ConvertTo-SettingValue -Type $setting.Type -Value $fromPage.Value }
    }

    $schemaDefaults = Get-DefaultVouchConfig
    foreach ($key in 'account', 'captureArea', 'zoomPercent', 'waitFor', 'onNotReady', 'promptTimeoutSec') {
        $value = $schemaDefaults['defaults'][$key]
        $fromConfig = Get-ConfigValue -Config $Config -Section 'defaults' -Key $key
        if ($fromConfig.Found) { $value = $fromConfig.Value }
        $fromPage = Get-ConfigValue -Config $overrides -Section 'defaults' -Key $key
        if ($fromPage.Found) { $value = $fromPage.Value }
        $name = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
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
    }
}

function Invoke-ScrollCapture {
    <#
        Takes the screenshots for a page that is already loaded and in the foreground:
        one screen, or (ScrollFullPage) one per screen of whatever scrolls - the page, a
        panel inside it or a frame. Errors from scrolling itself are left to the caller
        (Invoke-CaptureItem marks the page FAILED and the run moves on).
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][bool]$ScrollFullPage,
        # The browser's own error page is shown: its URL is not the page's, so keep FinalUrl.
        [Parameter(Mandatory)][bool]$BrowserErrorPage,
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][hashtable]$CaptureContext
    )

    $maxScrollSegments = $Settings.MaxScrollSegments
    $scrollSettleMs = [int]($Settings.ScrollSettleSeconds * 1000)

    $segmentCount = 1
    $viewportHeight = 0.0
    if ($ScrollFullPage) {
        try {
            # Find what scrolls - the page, a panel inside it, or a frame - and start at its top.
            $scrollTarget = Invoke-CdpEval -Expression (Get-ScrollTargetScript) -TimeoutSec 20
            Start-Sleep -Milliseconds $scrollSettleMs

            $viewportHeight = [double]$scrollTarget.view
            $pageHeight = [double]$scrollTarget.total
            $Item.ScrollArea = switch ([string]$scrollTarget.kind) {
                'window'  { 'the page' }
                'none'    { 'nothing to scroll - the content fits on one screen' }
                default   { [string]$scrollTarget.description }
            }
            foreach ($other in @($scrollTarget.others)) {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                $Item.Details.Add("Another scrolling area ($other) was not scrolled; content hidden in it is not captured.")
            }
            foreach ($frameName in @($scrollTarget.blockedFrames)) {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                $Item.Details.Add("A frame from another site ($frameName) cannot be scrolled; content hidden in it is not captured.")
            }

            if ($viewportHeight -gt 0 -and $pageHeight -gt 0) {
                $segmentCount = [int][Math]::Ceiling($pageHeight / $viewportHeight)
            }
            if ($segmentCount -lt 1) { $segmentCount = 1 }
        }
        catch {
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            $Item.Details.Add("The page height could not be measured, so only the first screen was captured: $($_.Exception.Message)")
            $segmentCount = 1
            $viewportHeight = 0
        }
    }

    $truncationMessage = "Page truncated at $maxScrollSegments segments (raise -MaxScrollSegments to capture more)."
    $truncationNoted = $false
    if ($segmentCount -gt $maxScrollSegments) {
        $segmentCount = $maxScrollSegments
        if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
        $Item.Details.Add($truncationMessage)
        $truncationNoted = $true
    }

    if ($ScrollFullPage -and $segmentCount -gt 1 -and $viewportHeight -gt 0) {
        $recheckDone = $false
        for ($segment = 0; $segment -lt $segmentCount; $segment++) {
            $offset = [int]([Math]::Round($segment * $viewportHeight))
            [void](Invoke-CdpEval -Expression "window.__vouchTarget.to($offset)" -TimeoutSec 10)
            Start-Sleep -Milliseconds $scrollSettleMs

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
                                    $Item.Details.Add($truncationMessage)
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
            Add-ItemCapture -Item $Item -SegmentIndex ($segment + 1) -SegmentCount $segmentCount -PageUrl $segmentUrl -Context $CaptureContext
        }

        try { [void](Invoke-CdpEval -Expression 'window.__vouchTarget.to(0)' -TimeoutSec 10) }
        catch { Write-Verbose "Could not scroll back to the top: $($_.Exception.Message)" }
    }
    else {
        Add-ItemCapture -Item $Item -SegmentIndex 1 -SegmentCount 1 -PageUrl $Item.FinalUrl -Context $CaptureContext
    }
}

function Invoke-CaptureItem {
    <#
        Captures one page in the tab the CDP socket is connected to: navigate, wait until
        ready, check for errors and sign-in redirects, run the steps, bring Edge to the
        front and take the screenshots. Never throws: whatever goes wrong is recorded on
        the item, because one failing page must not stop a run.
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

    Write-Host ("[{0}/{1}] {2} - {3}" -f $Definition.Index, $ItemCount, $Definition.Name, $Definition.Url)

    if ($Definition.PSObject.Properties['Actions']) {
        $legacy = Test-LegacyActionList -Actions @($Definition.Actions)
        if (-not $legacy.Supported) {
            $Item.Status = 'FAILED'
            $Item.Details.Add($legacy.Reason)
            Write-RowStatus -Message "    FAILED - $($legacy.Reason)" -Status 'FAILED'
            return $Item
        }
    }

    try {
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
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            $Item.Details.Add("The page did not finish loading within $navigationTimeoutSec seconds; it was captured in whatever state it had reached.")
        }

        Start-Sleep -Milliseconds ([int]($settleSeconds * 1000))

        # Chromium exposes the HTTP status of the main document on the
        # PerformanceNavigationTiming entry; older builds return 0.
        try {
            $statusValue = Invoke-CdpEval -Expression "(performance.getEntriesByType('navigation')[0]||{}).responseStatus||0" -TimeoutSec 10
            if ($null -ne $statusValue) { $Item.HttpStatus = [int]$statusValue }
        }
        catch {
            $Item.Details.Add("The HTTP status could not be read from the page: $($_.Exception.Message)")
        }

        if ($Item.HttpStatus -ge 400) {
            $Item.Status = 'FAILED'
            $Item.Details.Add("The server returned HTTP $($Item.HttpStatus). The error page is captured below as evidence.")
        }

        # Edge's error page lives at chrome-error://; the browser stayed on the
        # requested URL, so record that rather than report a redirect.
        $Item.FinalUrl = if ($browserErrorPage) { $Definition.Url } else { Get-CurrentPageUrl }
        $requestedOrigin = Get-OriginFromUrl -Url $Definition.Url
        $finalOrigin = Get-OriginFromUrl -Url $Item.FinalUrl
        if (-not [string]::IsNullOrWhiteSpace($finalOrigin) -and
            -not [string]::IsNullOrWhiteSpace($requestedOrigin) -and
            $finalOrigin -ne $requestedOrigin -and
            -not (Test-HttpsUpgrade -RequestedUrl $Definition.Url -FinalUrl $Item.FinalUrl)) {
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            $Item.Details.Add("Redirected to $finalOrigin - possible login required.")
        }
        elseif (-not $browserErrorPage -and -not [string]::IsNullOrWhiteSpace($Item.FinalUrl)) {
            $hasPasswordField = $false
            try {
                $hasPasswordField = [bool](Invoke-CdpEval -TimeoutSec 10 -Expression (
                    "Array.prototype.some.call(document.querySelectorAll('input[type=password]'), " +
                    "function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; })"))
            }
            catch {
                Write-Verbose "Could not look for a password field: $($_.Exception.Message)"
            }
            if (Test-LoginRedirect -RequestedUrl $Definition.Url -FinalUrl $Item.FinalUrl -HasPasswordField $hasPasswordField) {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                $Item.Details.Add("Redirected to a sign-in page ($(([Uri]$Item.FinalUrl).AbsolutePath)) - the session has probably expired. Run -LoginSetup.")
            }
        }

        if ($Definition.Steps.Count -gt 0) {
            $stepLog = Invoke-RowSteps -Steps @($Definition.Steps) -SettleSeconds $settleSeconds -NavigationTimeoutSec $navigationTimeoutSec
            foreach ($entry in $stepLog) { $Item.StepLog.Add($entry) }
            $failedSteps = @($stepLog | Where-Object { -not $_.Ok })
            if ($failedSteps.Count -gt 0) {
                if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
                $Item.Details.Add("Completed with errors: $($failedSteps.Count) of $($stepLog.Count) step(s) failed.")
            }
            if (-not $browserErrorPage) { $Item.FinalUrl = Get-CurrentPageUrl }
        }

        try { [void](Send-CdpCommand -Method 'Page.bringToFront' -TimeoutSec 10) }
        catch { Write-Verbose "Page.bringToFront failed: $($_.Exception.Message)" }

        $pageTitle = ''
        try { $pageTitle = [string](Invoke-CdpEval -Expression 'document.title' -TimeoutSec 10) }
        catch { Write-Verbose "Could not read the page title: $($_.Exception.Message)" }

        $focusWarning = Set-EdgeForeground -ExpectedTitle $pageTitle
        if ($null -ne $focusWarning) {
            if ($Item.Status -eq 'OK') { $Item.Status = 'WARNING' }
            $Item.Details.Add($focusWarning)
        }

        Invoke-ScrollCapture -Item $Item -ScrollFullPage ([bool]$Definition.ScrollFullPage) -BrowserErrorPage $browserErrorPage `
            -Settings $Settings -CaptureContext $CaptureContext

        $summary = "    $($Item.Status) - $($Item.Captures.Count) capture(s)"
        if ($Item.Details.Count -gt 0) { $summary += " - $($Item.Details[0])" }
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
    if ($boundNames -contains 'CsvPath' -and $boundNames -contains 'ConfigPath') {
        throw 'Use either -CsvPath or -ConfigPath, not both. -CsvPath reads the pages from a CSV file; -ConfigPath reads the pages and all settings from a configuration file.'
    }

    # The configuration path is command-line only, so it is known before the file is read.
    $settings = Resolve-RunSettings -BoundParameters $split.Bound -Defaults $split.Defaults -Config $null
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
        RunId      = [guid]::NewGuid().ToString()
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
        if ($script:LaunchedEdge) { Close-OtherPageTargets -Port $settings.DebugPort -KeepId ([string]$target.id) }

        foreach ($definition in $definitions) {
            # Added before the page is visited, so it is reported whatever happens to it.
            $item = New-CaptureItem -Definition $definition
            $items.Add($item)
            $pageSettings = Get-PageSettings -Settings $settings -Definition $definition -Config $config -BoundNames $boundNames
            [void](Invoke-CaptureItem -Definition $definition -Item $item -ItemCount $definitions.Count `
                -Settings $pageSettings -CaptureContext $captureContext)
        }
    }
    finally {
        Close-CdpSocket
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
    Write-Host "Done. $($items.Count) item(s): $okCount OK, $warnCount warning(s), $failCount failed. $captureCount screenshot(s)." -ForegroundColor Cyan
    if ($settings.SaveImages) { Write-Host "Individual images: $imagesDir" }
    Write-Host "Report: $reportPath ($reportSizeMb MB)" -ForegroundColor Cyan
    if ($summaryPath) { Write-Host "Summary: $summaryPath" }
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
