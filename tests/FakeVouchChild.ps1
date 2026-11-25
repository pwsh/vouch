#Requires -Version 7
<#
    A stand-in for vouch.ps1 in the Designer's run tests (Start-VouchDesigner -RunScriptPath,
    State.RunScriptPath). The Designer starts it exactly as it starts vouch.ps1. It writes a
    scripted event file instead of capturing, chosen by the configuration's "name":
    "fake:<scenario>". Any other name runs the real vouch.ps1 (the folder above this one)
    with the same arguments, so one Designer can drive both.

    It also writes the arguments it received to <EventLogPath>.args.json (the tests compare
    them with Get-VouchCommandLine), and waits for <EventLogPath>.answer to end a prompt.

    No param block on purpose: every argument arrives as given, and the real script gets
    them unchanged.
#>
$ErrorActionPreference = 'Stop'
# The arguments exactly as the process received them (pwsh -File would read "-Zip:$false"
# as a parameter of this script and split it), i.e. everything after this script's path.
$all = [Environment]::GetCommandLineArgs()
$self = [Array]::FindIndex($all, [Predicate[string]] { param($a) [string]::Equals([System.IO.Path]::GetFullPath($a), $PSCommandPath, [StringComparison]::OrdinalIgnoreCase) -and $a.EndsWith('.ps1') })
$arguments = @($all | Select-Object -Skip ($self + 1))
function Get-FakeArgument([string]$Name) {
    for ($i = 0; $i -lt $arguments.Count - 1; $i++) { if ($arguments[$i] -eq $Name) { return $arguments[$i + 1] } }
    return ''
}
$configPath = Get-FakeArgument '-ConfigPath'
$eventPath = Get-FakeArgument '-EventLogPath'
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -AsHashtable
$name = [string]$config['name']
if (-not $name.StartsWith('fake:')) {
    $real = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'vouch.ps1'
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $real @arguments
    exit $LASTEXITCODE
}
$scenario = $name.Substring(5)
if ($eventPath) {
    [System.IO.File]::WriteAllText("$eventPath.args.json", (ConvertTo-Json -InputObject $arguments -Compress), [System.Text.UTF8Encoding]::new($false))
}
$runId = [guid]::NewGuid().ToString()
$stopFile = "$eventPath.stop"
$outDir = Join-Path -Path (Split-Path -Path $eventPath -Parent) -ChildPath "fake-out-$runId"

function Add-FakeText([string]$Text) {
    $stream = [System.IO.FileStream]::new($eventPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}
function Write-FakeEvent([string]$Type, [System.Collections.IDictionary]$Data = @{}) {
    $event = [ordered]@{ ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'); type = $Type; runId = $runId }
    foreach ($key in $Data.Keys) { $event[$key] = $Data[$key] }
    Add-FakeText ((ConvertTo-Json -InputObject $event -Compress -Depth 10) + "`n")
}
function Write-FakeRunEnd([int]$ExitCode, [bool]$Stopped = $false, [int]$Ok = 1, [int]$Warning = 0, [int]$Failed = 0, [int]$Run = 1, [int]$Pages = 1) {
    [void](New-Item -ItemType Directory -Path $outDir -Force)
    $report = Join-Path $outDir 'fake report.html'
    $log = Join-Path $outDir 'fake report.log'
    [System.IO.File]::WriteAllText($report, '<!doctype html><title>fake</title>')
    [System.IO.File]::WriteAllText($log, 'fake log')
    Write-FakeEvent 'runEnd' ([ordered]@{ exitCode = $ExitCode; reportPath = $report; jsonSummaryPath = ''
            counts = [ordered]@{ pages = $Pages; run = $Run; ok = $Ok; warning = $Warning; failed = $Failed; notRun = $Pages - $Run; captures = $Ok + $Warning }
            stopped = $Stopped; zipPath = ''; zipSha256 = ''; manifestSha256 = ''; elapsedSec = 1.0; logPath = $log; logComplete = $true })
}
function Wait-Fake([int]$Milliseconds) { [System.Threading.Thread]::Sleep($Milliseconds) }

Write-Host "Fake run: $scenario"
switch ($scenario) {
    'nothing' {
        Write-Host 'ERROR: The configuration file could not be read. Nothing was launched.'
        exit 1
    }
    'die' {
        Write-FakeEvent 'runStart' ([ordered]@{ toolVersion = 'fake'; pageCount = 1 })
        Write-FakeEvent 'pageStart' ([ordered]@{ pageId = 'p001'; pageIndex = 1; index = 1; total = 1; name = 'Doomed'; url = 'http://localhost/' })
        [Console]::Error.WriteLine('Something broke badly inside the run.')
        exit 7
    }
    'failstart' {
        Write-FakeEvent 'error' ([ordered]@{ message = 'Edge has no open tab with the id ''x''.' })
        Write-FakeEvent 'runEnd' ([ordered]@{ exitCode = 1; reportPath = ''; jsonSummaryPath = ''; counts = $null; stopped = $false; logPath = ''; logComplete = $true })
        exit 1
    }
    'ignorestop' {
        Write-FakeEvent 'runStart' ([ordered]@{ toolVersion = 'fake'; pageCount = 1 })
        Write-FakeEvent 'pageStart' ([ordered]@{ pageId = 'p001'; pageIndex = 1; index = 1; total = 1; name = 'Stubborn'; url = 'http://localhost/' })
        Wait-Fake 120000
        exit 0
    }
    default {
        $pageCount = if ($scenario -in 'stop', 'slow') { 6 } else { 2 }
        $delay = switch ($scenario) { 'slow' { 700 } 'stop' { 400 } default { 150 } }
        Write-FakeEvent 'runStart' ([ordered]@{ toolVersion = 'fake'; pageCount = $pageCount; outputDir = $outDir })
        if ($scenario -eq 'garbage') {
            Add-FakeText "this is not json`n"
            Add-FakeText "[1,2,3]`n"
            Add-FakeText "{`"noType`":true}`n"
            # A line written in two parts: the reader must wait for its end.
            $line = (ConvertTo-Json -Compress -InputObject ([ordered]@{ ts = 'x'; type = 'detail'; runId = $runId; pageId = 'p000'; pageIndex = 0; status = 'OK'; text = 'split line' }))
            Add-FakeText $line.Substring(0, 20)
            Wait-Fake 600
            Add-FakeText ($line.Substring(20) + "`n")
        }
        if ($scenario -eq 'longline') {
            Add-FakeText ('{"type":"detail","text":"' + ('x' * 3MB) + '"}' + "`n")
        }
        $ok = 0; $warning = 0; $failed = 0; $run = 0; $stopped = $false
        for ($i = 1; $i -le $pageCount; $i++) {
            if (Test-Path -LiteralPath $stopFile) { $stopped = $true; break }
            $run++
            $id = 'p{0:d3}' -f $i
            Write-FakeEvent 'pageStart' ([ordered]@{ pageId = $id; pageIndex = $i; index = $i; total = $pageCount; name = "Page $i 'quoted' & é"; url = "http://localhost/$i" })
            Wait-Fake $delay
            if ($scenario -eq 'prompt' -and $i -eq 1) {
                Write-FakeEvent 'prompt' ([ordered]@{ pageId = $id; kind = 'pause'; title = 'Vouch has paused'; message = 'Sign in, then Continue.'; pageName = "Page $i"; defaultDecision = 'Continue'; timeoutSec = 300 })
                $deadline = (Get-Date).AddSeconds(30)
                while (-not (Test-Path -LiteralPath "$eventPath.answer") -and -not (Test-Path -LiteralPath $stopFile) -and (Get-Date) -lt $deadline) { Wait-Fake 100 }
                Write-FakeEvent 'promptResult' ([ordered]@{ pageId = $id; kind = 'pause'; decision = 'Continue'; waitSeconds = 0; timedOut = $false; shown = $true })
            }
            $status = 'OK'
            $details = @()
            if ($scenario -eq 'failpage' -and $i -eq 2) {
                $status = 'FAILED'; $details = @('The page could not be loaded: net::ERR_NAME_NOT_RESOLVED')
                Write-FakeEvent 'detail' ([ordered]@{ pageId = $id; pageIndex = $i; status = 'FAILED'; text = $details[0] })
            }
            elseif ($i -eq 2) {
                $status = 'WARNING'; $details = @('Page truncated at 3 segments (raise -MaxScrollSegments to capture more).')
                Write-FakeEvent 'detail' ([ordered]@{ pageId = $id; pageIndex = $i; status = 'WARNING'; text = $details[0] })
            }
            if ($status -ne 'FAILED') {
                Write-FakeEvent 'capture' ([ordered]@{ pageId = $id; pageIndex = $i; captureNumber = 1; label = ''; segment = 1; segmentCount = 1; fileName = ('{0:d3}_Page_{0}_seg01.jpg' -f $i); area = 'page'; zoomPercent = 100 })
            }
            if (($scenario -in 'stop', 'slow') -and (Test-Path -LiteralPath $stopFile)) {
                $stopped = $true; $status = 'WARNING'; $details = @('Stopped by the user: the run ended here, so the rest of this page was not captured.')
            }
            switch ($status) { 'OK' { $ok++ } 'WARNING' { $warning++ } 'FAILED' { $failed++ } }
            Write-FakeEvent 'pageEnd' ([ordered]@{ pageId = $id; pageIndex = $i; index = $i; total = $pageCount; status = $status; details = @($details); captureCount = $(if ($status -eq 'FAILED') { 0 } else { 1 }); finalUrl = "http://localhost/$i"; stopped = $stopped })
            if ($stopped) { break }
        }
        if ($stopped -and (Test-Path -LiteralPath $stopFile)) { Remove-Item -LiteralPath $stopFile -Force }
        $code = if ($failed -gt 0) { 2 } else { 0 }
        Write-FakeRunEnd -ExitCode $code -Stopped $stopped -Ok $ok -Warning $warning -Failed $failed -Run $run -Pages $pageCount
        if ($scenario -eq 'garbage') { Add-FakeText '{"type":"pageStart","pageId":"cut-' }
        exit $code
    }
}
