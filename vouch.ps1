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

.PARAMETER LoginSetup
    First-run onboarding: opens Edge with the dedicated audit profile (no debugging
    flags) so you can sign in to your applications. Sessions persist for later runs.

.EXAMPLE
    .\vouch.ps1 -LoginSetup

.EXAMPLE
    .\vouch.ps1 -CsvPath .\captures.csv -OutputDir .\reports

.EXAMPLE
    .\vouch.ps1 -ImageFormat png -SaveImages -KeepBrowserOpen
#>

[CmdletBinding()]
param(
    [string]$CsvPath = '.\captures.csv',

    [string]$OutputDir = '.\reports',

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

    [switch]$LoginSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion       = '1.0.0'
$script:ExitCode          = 0
$script:CdpSocket         = $null
$script:CdpMessageId      = 0
$script:CdpDefaultTimeout = 30
$script:EdgeProcess       = $null
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
                $seconds = 0.0
                if (-not [double]::TryParse($argument, [ref]$seconds) -or $seconds -lt 0 -or $seconds -gt 300) {
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
    $index = 0

    foreach ($row in $rows) {
        $index++
        $lineNumber = $index + 1   # +1 for the header line

        $name = Get-CsvField -Row $row -Field 'Name'
        $url = Get-CsvField -Row $row -Field 'Url'
        $stepsText = Get-CsvField -Row $row -Field 'Steps'
        $scrollText = Get-CsvField -Row $row -Field 'ScrollFullPage'
        $notes = Get-CsvField -Row $row -Field 'Notes'

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

        $definitions.Add([pscustomobject]@{
            Index          = $index
            LineNumber     = $lineNumber
            Name           = $name
            Url            = $url
            StepsText      = $stepsText
            Steps          = $steps
            ScrollFullPage = (ConvertTo-BooleanFlag -Value $scrollText)
            Notes          = $notes
        })
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
        Write-Host "Reusing the Edge instance already listening on port $Port." -ForegroundColor Yellow
        return $existing
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
    $script:EdgeProcess = Start-Process -FilePath $EdgePath -ArgumentList $arguments -PassThru
    $script:LaunchedEdge = $true

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $info = Get-DebugEndpointInfo -Port $Port
        if ($null -ne $info) { return $info }
    }

    throw "Edge did not open its DevTools endpoint on port $Port within 15 seconds. Close any running Edge instance that uses the audit profile and try again, or pick another port with -DebugPort."
}

function Get-CdpPageTarget {
    param([Parameter(Mandatory)][int]$Port)

    $targets = @()
    try {
        $targets = @(Invoke-RestMethod -Uri "http://$($script:CdpHost):$Port/json/list" -TimeoutSec 10 -NoProxy)
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

function Connect-CdpSocket {
    param(
        [Parameter(Mandatory)][string]$WebSocketUrl,
        [int]$TimeoutSec = 15
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)

    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $socket.ConnectAsync([Uri]::new($WebSocketUrl), $cts.Token).GetAwaiter().GetResult()
    }
    catch {
        $socket.Dispose()
        throw "Could not open the DevTools WebSocket ($WebSocketUrl): $($_.Exception.Message)"
    }
    finally {
        $cts.Dispose()
    }

    $script:CdpSocket = $socket
    $script:CdpMessageId = 0
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

    $script:CdpMessageId++
    $messageId = $script:CdpMessageId

    $json = (@{ id = $messageId; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $payload = [System.ArraySegment[byte]]::new($bytes)

    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $script:CdpSocket.SendAsync($payload, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
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
        # The launched process may not own the visible window yet (or at all, if Edge
        # re-parented the session), so re-query and fall back to another msedge window.
        if ($null -ne $script:EdgeProcess) {
            try {
                $process = Get-Process -Id $script:EdgeProcess.Id -ErrorAction Stop
                if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return $process.MainWindowHandle }
            }
            catch {
                Write-Verbose "Launched Edge process is no longer available: $($_.Exception.Message)"
            }
        }

        # In the fallback the user's personal Edge windows are candidates too, so prefer
        # the window whose title carries the page we just navigated - focusing the wrong
        # window would put the wrong application into the evidence.
        $candidates = @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
        if ($candidates.Count -gt 0) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedTitle)) {
                foreach ($candidate in $candidates) {
                    if ($candidate.MainWindowTitle.Contains($ExpectedTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $candidate.MainWindowHandle
                    }
                }
            }
            return $candidates[0].MainWindowHandle
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
        [void][Vouch.Native]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 300
        if ([Vouch.Native]::GetForegroundWindow() -ne $handle) {
            return 'Windows refused to bring Edge to the foreground; check the screenshots for overlapping windows.'
        }
    }
    return $null
}

function Get-ScreenCapture {
    <#
        Real screen capture of the primary display, so the taskbar clock is included in
        the evidence. Requires an unlocked, visible desktop.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('jpeg', 'png')][string]$Format,
        [int]$Quality = 85
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
            if ($Format -eq 'jpeg') {
                $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                    Where-Object { $_.MimeType -eq 'image/jpeg' } |
                    Select-Object -First 1
                if ($null -eq $encoder) {
                    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                }
                else {
                    $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
                    try {
                        $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
                        $bitmap.Save($stream, $encoder, $encoderParameters)
                    }
                    finally {
                        $encoderParameters.Dispose()
                    }
                }
            }
            else {
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            # The leading comma keeps the byte array intact instead of streaming it out byte by byte.
            return , $stream.ToArray()
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

function Invoke-ClickSelector {
    param([Parameter(Mandatory)][string]$Selector)

    $literal = ConvertTo-JsLiteral -Value $Selector
    $expression = @"
(function (sel) {
  var el = document.querySelector(sel);
  if (!el) { return 'NOTFOUND'; }
  if (el.scrollIntoView) { el.scrollIntoView({ block: 'center' }); }
  el.click();
  return 'OK';
})($literal)
"@
    $outcome = Invoke-CdpEval -Expression $expression
    if ($outcome -ne 'OK') {
        throw "No element matched the CSS selector '$Selector'."
    }
}

function Invoke-ClickText {
    param([Parameter(Mandatory)][string]$Text)

    $literal = ConvertTo-JsLiteral -Value $Text
    $expression = @"
(function (wanted) {
  var target = String(wanted).trim().toLowerCase();
  var nodes = Array.prototype.slice.call(document.querySelectorAll(
    'a,button,[role=button],[role=tab],[role=menuitem],input[type=submit],input[type=button]'));
  var label = function (el) {
    var text = el.innerText || el.textContent || el.value || '';
    return String(text).replace(/\s+/g, ' ').trim().toLowerCase();
  };
  var pick = null;
  for (var i = 0; i < nodes.length; i++) {
    if (label(nodes[i]) === target) { pick = nodes[i]; break; }
  }
  if (!pick) {
    for (var j = 0; j < nodes.length; j++) {
      if (label(nodes[j]).indexOf(target) !== -1) { pick = nodes[j]; break; }
    }
  }
  if (!pick) { return 'NOTFOUND'; }
  if (pick.scrollIntoView) { pick.scrollIntoView({ block: 'center' }); }
  pick.click();
  return 'OK';
})($literal)
"@
    $outcome = Invoke-CdpEval -Expression $expression
    if ($outcome -ne 'OK') {
        throw "No clickable element with the text '$Text' was found."
    }
}

function Invoke-RowSteps {
    <#
        Runs the parsed steps for one row. Every step is isolated: a failure is recorded
        and the remaining steps still run, so a capture is always produced.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
        [Parameter(Mandatory)][double]$SettleSeconds
    )

    $log = [System.Collections.Generic.List[object]]::new()

    foreach ($step in $Steps) {
        $entry = [pscustomobject]@{ Text = $step.Text; Ok = $true; Message = '' }
        try {
            switch ($step.Verb) {
                'click' {
                    Invoke-ClickSelector -Selector ([string]$step.Argument)
                    Start-Sleep -Milliseconds ([int]($SettleSeconds * 1000))
                }
                'clicktext' {
                    Invoke-ClickText -Text ([string]$step.Argument)
                    Start-Sleep -Milliseconds ([int]($SettleSeconds * 1000))
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
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][int]$SegmentIndex,
        [Parameter(Mandatory)][int]$SegmentCount,
        [string]$FilePath = ''
    )

    return [pscustomobject]@{
        Timestamp    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Url          = $Url
        SegmentIndex = $SegmentIndex
        SegmentCount = $SegmentCount
        Base64       = [Convert]::ToBase64String($Bytes)
        Bytes        = $Bytes.Length
        FilePath     = $FilePath
    }
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
        [pscustomobject]@{ Label = 'Capture tool';      Text = "vouch.ps1 v$($Run.ToolVersion)" },
        [pscustomobject]@{ Label = 'Definition file';   Text = $Run.CsvPath },
        [pscustomobject]@{ Label = 'Image format';      Text = $Run.ImageDescription },
        [pscustomobject]@{ Label = 'Screen resolution'; Text = $Run.ScreenResolution }
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
        [void]$sb.AppendLine("<dt>Scroll capture</dt><dd>$(if ($item.ScrollFullPage) { 'Yes - full page in viewport segments' } else { 'No - single viewport' })</dd>")
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
                [void]$sb.Append('<img alt="')
                [void]$sb.Append((Encode-Html "$($item.Name) screenshot $($capture.SegmentIndex) of $($capture.SegmentCount)"))
                [void]$sb.Append('" src="data:')
                [void]$sb.Append($mimeType)
                [void]$sb.Append(';base64,')
                [void]$sb.Append($capture.Base64)
                [void]$sb.AppendLine('">')
                [void]$sb.AppendLine("<figcaption>Captured $(Encode-Html $capture.Timestamp)$segmentText &middot; $(Encode-Html $capture.Url)</figcaption>")
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
                $script:CdpSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult()
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
    if (-not $script:LaunchedEdge -or $null -eq $script:EdgeProcess) { return }
    try {
        $process = Get-Process -Id $script:EdgeProcess.Id -ErrorAction SilentlyContinue
        if ($null -eq $process) { return }
        # Close the window first so Edge flushes cookies/sessions to the audit profile.
        [void]$process.CloseMainWindow()
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
    $process = Start-Process -FilePath $EdgePath -ArgumentList $arguments -PassThru

    [void](Read-Host 'Press Enter when you have finished signing in')

    try {
        $running = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($null -ne $running) {
            [void]$running.CloseMainWindow()
            [void]$running.WaitForExit(10000)
        }
    }
    catch {
        Write-Verbose "Could not close the setup browser: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'Sessions saved. You can now run the script normally to capture evidence.' -ForegroundColor Green
}

function Invoke-Main {
    Assert-Environment

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-NativeInterop

    $edgePath = Find-EdgeExecutable

    if ($LoginSetup) {
        Invoke-LoginSetup -EdgePath $edgePath -ProfileDir $EdgeProfileDir
        $script:ExitCode = 0
        return
    }

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Capture definition CSV not found: $CsvPath`nCreate one from captures.sample.csv, or pass -CsvPath."
    }
    $resolvedCsvPath = (Resolve-Path -LiteralPath $CsvPath).Path

    $definitions = Import-CaptureDefinition -Path $resolvedCsvPath
    Write-Host "Loaded $($definitions.Count) capture item(s) from $resolvedCsvPath" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        [void](New-Item -ItemType Directory -Path $OutputDir -Force)
    }
    $resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

    $imagesDir = ''
    if ($SaveImages) {
        $imagesDir = Join-Path -Path $resolvedOutputDir -ChildPath 'images'
        if (-not (Test-Path -LiteralPath $imagesDir)) {
            [void](New-Item -ItemType Directory -Path $imagesDir -Force)
        }
    }

    $effectiveReportName = $ReportName
    if ([string]::IsNullOrWhiteSpace($effectiveReportName)) {
        $effectiveReportName = "VouchReport_$((Get-Date).ToString('yyyy-MM-dd_HHmmss')).html"
    }
    if ($effectiveReportName -notmatch '(?i)\.html?$') { $effectiveReportName += '.html' }
    $reportPath = Join-Path -Path $resolvedOutputDir -ChildPath $effectiveReportName

    $imageExtension = if ($ImageFormat -eq 'png') { 'png' } else { 'jpg' }
    $runStart = [System.DateTimeOffset]::Now
    $items = [System.Collections.Generic.List[object]]::new()

    try {
        $versionInfo = Start-EdgeDebug -EdgePath $edgePath -ProfileDir $EdgeProfileDir -Port $DebugPort

        $edgeVersion = 'unknown'
        if ($null -ne $versionInfo -and $versionInfo.PSObject.Properties['Browser']) {
            $edgeVersion = [string]$versionInfo.Browser
        }
        Write-Host "Connected to $edgeVersion"

        $target = Get-CdpPageTarget -Port $DebugPort
        if ($null -eq $target -or -not $target.PSObject.Properties['webSocketDebuggerUrl']) {
            throw 'Could not obtain a DevTools page target from Edge.'
        }
        Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)

        foreach ($definition in $definitions) {
            $item = [pscustomobject]@{
                Index          = $definition.Index
                Name           = $definition.Name
                Url            = $definition.Url
                FinalUrl       = ''
                Notes          = $definition.Notes
                StepsText      = $definition.StepsText
                ScrollFullPage = $definition.ScrollFullPage
                Status         = 'OK'
                HttpStatus     = 0
                Details        = [System.Collections.Generic.List[string]]::new()
                StepLog        = [System.Collections.Generic.List[object]]::new()
                Captures       = [System.Collections.Generic.List[object]]::new()
            }
            $items.Add($item)

            Write-Host ("[{0}/{1}] {2} - {3}" -f $definition.Index, $definitions.Count, $definition.Name, $definition.Url)

            try {
                Set-NavigationMarker
                $navigation = Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $definition.Url } -TimeoutSec $NavigationTimeoutSec
                if ($null -ne $navigation -and $navigation.PSObject.Properties['errorText'] -and
                    -not [string]::IsNullOrWhiteSpace([string]$navigation.errorText)) {
                    $item.Status = 'FAILED'
                    $item.Details.Add("The page could not be loaded: $([string]$navigation.errorText)")
                    Write-RowStatus -Message "    FAILED - $([string]$navigation.errorText)" -Status 'FAILED'
                    continue
                }

                if (-not (Wait-PageReady -TimeoutSec $NavigationTimeoutSec)) {
                    if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                    $item.Details.Add("The page did not finish loading within $NavigationTimeoutSec seconds; it was captured in whatever state it had reached.")
                }

                Start-Sleep -Milliseconds ([int]($SettleSeconds * 1000))

                # Chromium exposes the HTTP status of the main document on the
                # PerformanceNavigationTiming entry; older builds return 0.
                try {
                    $statusValue = Invoke-CdpEval -Expression "(performance.getEntriesByType('navigation')[0]||{}).responseStatus||0" -TimeoutSec 10
                    if ($null -ne $statusValue) { $item.HttpStatus = [int]$statusValue }
                }
                catch {
                    $item.Details.Add("The HTTP status could not be read from the page: $($_.Exception.Message)")
                }

                if ($item.HttpStatus -ge 400) {
                    $item.Status = 'FAILED'
                    $item.Details.Add("The server returned HTTP $($item.HttpStatus). The error page is captured below as evidence.")
                }

                $item.FinalUrl = Get-CurrentPageUrl
                $requestedOrigin = Get-OriginFromUrl -Url $definition.Url
                $finalOrigin = Get-OriginFromUrl -Url $item.FinalUrl
                if (-not [string]::IsNullOrWhiteSpace($finalOrigin) -and
                    -not [string]::IsNullOrWhiteSpace($requestedOrigin) -and
                    $finalOrigin -ne $requestedOrigin) {
                    if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                    $item.Details.Add("Redirected to $finalOrigin - possible login required.")
                }

                if ($definition.Steps.Count -gt 0) {
                    $stepLog = Invoke-RowSteps -Steps @($definition.Steps) -SettleSeconds $SettleSeconds
                    foreach ($entry in $stepLog) { $item.StepLog.Add($entry) }
                    $failedSteps = @($stepLog | Where-Object { -not $_.Ok })
                    if ($failedSteps.Count -gt 0) {
                        if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                        $item.Details.Add("Completed with errors: $($failedSteps.Count) of $($stepLog.Count) step(s) failed.")
                    }
                    $item.FinalUrl = Get-CurrentPageUrl
                }

                try { [void](Send-CdpCommand -Method 'Page.bringToFront' -TimeoutSec 10) }
                catch { Write-Verbose "Page.bringToFront failed: $($_.Exception.Message)" }

                $pageTitle = ''
                try { $pageTitle = [string](Invoke-CdpEval -Expression 'document.title' -TimeoutSec 10) }
                catch { Write-Verbose "Could not read the page title: $($_.Exception.Message)" }

                $focusWarning = Set-EdgeForeground -ExpectedTitle $pageTitle
                if ($null -ne $focusWarning) {
                    if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                    $item.Details.Add($focusWarning)
                }

                $segmentCount = 1
                $viewportHeight = 0.0
                if ($definition.ScrollFullPage) {
                    try {
                        [void](Invoke-CdpEval -Expression 'window.scrollTo(0, 0)' -TimeoutSec 10)
                        Start-Sleep -Milliseconds ([int]($ScrollSettleSeconds * 1000))

                        $viewportHeight = [double](Invoke-CdpEval -Expression 'window.innerHeight' -TimeoutSec 10)
                        $pageHeight = [double](Invoke-CdpEval -Expression 'Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight)' -TimeoutSec 10)

                        if ($viewportHeight -gt 0 -and $pageHeight -gt 0) {
                            $segmentCount = [int][Math]::Ceiling($pageHeight / $viewportHeight)
                        }
                        if ($segmentCount -lt 1) { $segmentCount = 1 }
                    }
                    catch {
                        if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                        $item.Details.Add("The page height could not be measured, so only the first screen was captured: $($_.Exception.Message)")
                        $segmentCount = 1
                        $viewportHeight = 0
                    }
                }

                if ($segmentCount -gt $MaxScrollSegments) {
                    $segmentCount = $MaxScrollSegments
                    if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                    $item.Details.Add("Page truncated at $MaxScrollSegments segments (raise -MaxScrollSegments to capture more).")
                }

                if ($definition.ScrollFullPage -and $segmentCount -gt 1 -and $viewportHeight -gt 0) {
                    $recheckDone = $false
                    for ($segment = 0; $segment -lt $segmentCount; $segment++) {
                        $offset = [int]([Math]::Round($segment * $viewportHeight))
                        [void](Invoke-CdpEval -Expression "window.scrollTo(0, $offset)" -TimeoutSec 10)
                        Start-Sleep -Milliseconds ([int]($ScrollSettleSeconds * 1000))

                        # Lazy-loading pages grow after the first scroll; re-measure once only.
                        if (-not $recheckDone) {
                            $recheckDone = $true
                            try {
                                $grownHeight = [double](Invoke-CdpEval -Expression 'Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight)' -TimeoutSec 10)
                                if ($grownHeight -gt 0) {
                                    $recomputed = [int][Math]::Ceiling($grownHeight / $viewportHeight)
                                    if ($recomputed -gt $segmentCount) {
                                        if ($recomputed -gt $MaxScrollSegments) {
                                            $recomputed = $MaxScrollSegments
                                            if ($item.Status -eq 'OK') { $item.Status = 'WARNING' }
                                            $item.Details.Add("Page truncated at $MaxScrollSegments segments (raise -MaxScrollSegments to capture more).")
                                        }
                                        $segmentCount = $recomputed
                                    }
                                }
                            }
                            catch {
                                Write-Verbose "Could not re-measure the page height: $($_.Exception.Message)"
                            }
                        }

                        $bytes = Get-ScreenCapture -Format $ImageFormat -Quality $JpegQuality
                        $filePath = ''
                        if ($SaveImages) {
                            $fileName = '{0:d3}_{1}_seg{2:d2}.{3}' -f $definition.Index, (Get-SafeFileName -Name $definition.Name), ($segment + 1), $imageExtension
                            $filePath = Join-Path -Path $imagesDir -ChildPath $fileName
                            [System.IO.File]::WriteAllBytes($filePath, $bytes)
                        }
                        $item.Captures.Add((New-CaptureRecord -Bytes $bytes -Url (Get-CurrentPageUrl) -SegmentIndex ($segment + 1) -SegmentCount $segmentCount -FilePath $filePath))
                    }

                    try { [void](Invoke-CdpEval -Expression 'window.scrollTo(0, 0)' -TimeoutSec 10) }
                    catch { Write-Verbose "Could not scroll back to the top: $($_.Exception.Message)" }
                }
                else {
                    $bytes = Get-ScreenCapture -Format $ImageFormat -Quality $JpegQuality
                    $filePath = ''
                    if ($SaveImages) {
                        $fileName = '{0:d3}_{1}_seg{2:d2}.{3}' -f $definition.Index, (Get-SafeFileName -Name $definition.Name), 1, $imageExtension
                        $filePath = Join-Path -Path $imagesDir -ChildPath $fileName
                        [System.IO.File]::WriteAllBytes($filePath, $bytes)
                    }
                    $item.Captures.Add((New-CaptureRecord -Bytes $bytes -Url $item.FinalUrl -SegmentIndex 1 -SegmentCount 1 -FilePath $filePath))
                }

                $summary = "    $($item.Status) - $($item.Captures.Count) capture(s)"
                if ($item.Details.Count -gt 0) { $summary += " - $($item.Details[0])" }
                Write-RowStatus -Message $summary -Status $item.Status
            }
            catch {
                $item.Status = 'FAILED'
                $item.Details.Add("Unhandled error while capturing this item: $($_.Exception.Message)")
                Write-RowStatus -Message "    FAILED - $($_.Exception.Message)" -Status 'FAILED'
            }
        }
    }
    finally {
        Close-CdpSocket
        if ($KeepBrowserOpen) {
            if ($script:LaunchedEdge) { Write-Host 'Leaving Edge open (-KeepBrowserOpen).' }
        }
        else {
            Stop-EdgeProcess
        }
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

    $imageDescription = if ($ImageFormat -eq 'png') { 'PNG (lossless)' } else { "JPEG (quality $JpegQuality)" }
    $browserInstance = if ($script:ReusedEdge) {
        "Existing Edge instance reused on port $DebugPort (not launched by this run)"
    }
    else {
        "Launched by this run on port $DebugPort using profile $EdgeProfileDir"
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
        ToolVersion      = $script:ToolVersion
        CsvPath          = $resolvedCsvPath
        ImageFormat      = $ImageFormat
        ImageDescription = $imageDescription
        ScreenResolution = $screenResolution
        Total            = $items.Count
        OkCount          = $okCount
        WarnCount        = $warnCount
        FailCount        = $failCount
        CaptureCount     = $captureCount
    }

    $html = New-HtmlReport -Items @($items) -Run $run
    [System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($false))

    $reportSizeMb = [Math]::Round((Get-Item -LiteralPath $reportPath).Length / 1MB, 1)

    Write-Host ''
    Write-Host "Done. $($items.Count) item(s): $okCount OK, $warnCount warning(s), $failCount failed. $captureCount screenshot(s)." -ForegroundColor Cyan
    if ($SaveImages) { Write-Host "Individual images: $imagesDir" }
    Write-Host "Report: $reportPath ($reportSizeMb MB)" -ForegroundColor Cyan

    $script:ExitCode = if ($failCount -gt 0) { 2 } else { 0 }
}

try {
    Invoke-Main
    exit $script:ExitCode
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($null -ne $_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
    exit 1
}

#endregion
