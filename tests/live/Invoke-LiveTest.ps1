#Requires -Version 7
<#
.SYNOPSIS
    Live end-to-end test: runs the real vouch.ps1 against public websites on this
    desktop and checks every result against the expectations in the CSV.

.DESCRIPTION
    Unlike the Pester suite, this takes over the screen: Edge opens maximised and the
    primary display is captured, exactly as in production. Run it on a machine you can
    leave alone for a few minutes, signed in and unlocked. Needs internet access.

    It uses its own throwaway Edge profile and DevTools port, so it never touches the
    audit profile or a capture run that is already in progress.

    Checks, per CSV row (columns Expect, ExpectCaptures, ExpectFinalUrl):
      - status is OK / WARNING / FAILED as expected
      - number of screenshots: exact ("0", "1") or a minimum ("2+")
      - final URL matches the wildcard pattern, when one is given
    and for the whole run:
      - every screenshot file exists, has the primary display's size and is not blank
      - the bottom rows of every screenshot (the taskbar) are not blank
      - the exit code is the one the expectations imply
      - the Edge the run launched is gone afterwards (DevTools port closed)

    With -ViaScheduler the run goes through Install-VouchSchedule.ps1 as a temporary
    scheduled task (installed, started, removed), covering the unattended path too.

.EXAMPLE
    pwsh .\tests\live\Invoke-LiveTest.ps1

.EXAMPLE
    pwsh .\tests\live\Invoke-LiveTest.ps1 -ViaScheduler
#>
[CmdletBinding()]
param(
    [string]$CsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'public-sites.csv'),
    [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'output'),
    [switch]$ViaScheduler,
    [ValidateRange(1024, 65535)]
    [int]$DebugPort = 9333,
    [ValidateRange(1, 60)]
    [int]$SchedulerTimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
$vouch = Join-Path -Path $repoRoot -ChildPath 'vouch.ps1'
$installer = Join-Path -Path $repoRoot -ChildPath 'Install-VouchSchedule.ps1'
$profileDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'vouch-live-test-profile'
$runDir = Join-Path -Path $OutputDir -ChildPath ((Get-Date).ToString('yyyy-MM-dd_HHmmss') + $(if ($ViaScheduler) { '_scheduled' } else { '' }))
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $failures.Add($Message)
    Write-Host "  FAIL  $Message" -ForegroundColor Red
}

function Test-ImageContent {
    <#
        Returns problems with one screenshot: wrong size, blank overall (locked or
        disconnected session), or a blank bottom strip (taskbar and clock missing).
    #>
    param([string]$Path, [int]$Width, [int]$Height)

    $problems = [System.Collections.Generic.List[string]]::new()
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        if ($bitmap.Width -ne $Width -or $bitmap.Height -ne $Height) {
            $problems.Add("is $($bitmap.Width)x$($bitmap.Height), expected ${Width}x${Height}")
        }
        $distinct = {
            param([int]$Top, [int]$Bottom)
            $colours = [System.Collections.Generic.HashSet[int]]::new()
            for ($y = $Top; $y -lt $Bottom; $y += [Math]::Max(1, [int](($Bottom - $Top) / 12))) {
                for ($x = 0; $x -lt $bitmap.Width; $x += [Math]::Max(1, [int]($bitmap.Width / 40))) {
                    # Coarse buckets so JPEG noise does not count as content.
                    $c = $bitmap.GetPixel($x, $y)
                    [void]$colours.Add((($c.R -shr 4) -shl 8) -bor (($c.G -shr 4) -shl 4) -bor ($c.B -shr 4))
                }
            }
            return $colours.Count
        }
        if ((& $distinct 0 $bitmap.Height) -lt 4) { $problems.Add('looks blank (locked or disconnected session?)') }
        $taskbarTop = [Math]::Max(0, $bitmap.Height - 40)
        if ((& $distinct $taskbarTop $bitmap.Height) -lt 3) { $problems.Add('has a blank bottom strip - taskbar/clock not visible') }
    }
    finally {
        $bitmap.Dispose()
    }
    return $problems
}

function Get-ExpectedCaptureCheck([string]$Text) {
    if ($Text -match '^(\d+)\+$') { return @{ Min = [int]$Matches[1]; Exact = -1 } }
    if ($Text -match '^\d+$') { return @{ Min = [int]$Text; Exact = [int]$Text } }
    return $null
}

# --- preflight -----------------------------------------------------------------

if (-not $IsWindows) { throw 'The live test needs Windows.' }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) {
    throw 'The workstation looks locked (LogonUI is running). Unlock it and run again.'
}
$portBusy = $false
try {
    $null = Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json/version" -TimeoutSec 2 -NoProxy
    $portBusy = $true
}
catch {
    Write-Verbose "Port $DebugPort is free."
}
if ($portBusy) { throw "A DevTools endpoint already listens on port $DebugPort. Close it or pass -DebugPort." }

$rows = @(Import-Csv -LiteralPath $CsvPath)
[void](New-Item -ItemType Directory -Path $runDir -Force)

Write-Host "Live test: $($rows.Count) sites from $CsvPath" -ForegroundColor Cyan
Write-Host "Output:    $runDir"
Write-Host 'Edge is about to take over the screen. Do not touch the mouse or keyboard until it finishes.' -ForegroundColor Yellow
Start-Sleep -Seconds 3

# --- run -----------------------------------------------------------------------

$started = Get-Date
if ($ViaScheduler) {
    $taskName = 'Vouch live test (temporary)'
    & $installer -TaskName $taskName -Schedule Weekly -DaysOfWeek Sunday -At 03:00 -CsvPath $CsvPath `
        -OutputDir $runDir -SaveImages -AllowWarnings -EdgeProfileDir $profileDir -DebugPort $DebugPort 6>$null
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddMinutes($SchedulerTimeoutMinutes)
        do {
            Start-Sleep -Seconds 5
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            # 267009 = running, 267011 = has not run yet (the start is still being processed)
        } while ($info.LastTaskResult -in 267009, 267011 -and (Get-Date) -lt $deadline)
        $exitCode = [int]$info.LastTaskResult
    }
    finally {
        & $installer -TaskName $taskName -Uninstall 6>$null
    }
}
else {
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $vouch -CsvPath $CsvPath -OutputDir $runDir `
        -ReportName 'live-test.html' -SaveImages -JsonSummary -EdgeProfileDir $profileDir -DebugPort $DebugPort
    $exitCode = $LASTEXITCODE
}
$elapsed = (Get-Date) - $started

# --- check ---------------------------------------------------------------------

Write-Host ''
Write-Host "Checking results (run took $([int]$elapsed.TotalSeconds) s, exit code $exitCode)" -ForegroundColor Cyan

$summaryFile = Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -eq $summaryFile) {
    Add-Failure 'No JSON summary was written - the run did not complete. See the log or console output.'
}
else {
    $summary = Get-Content -LiteralPath $summaryFile.FullName -Raw | ConvertFrom-Json
    $items = @($summary.Items)
    if ($items.Count -ne $rows.Count) { Add-Failure "Expected $($rows.Count) items in the summary, found $($items.Count)." }

    for ($i = 0; $i -lt [Math]::Min($rows.Count, $items.Count); $i++) {
        $row = $rows[$i]
        $item = $items[$i]
        $problems = [System.Collections.Generic.List[string]]::new()

        if ($row.Expect -and $item.Status -ne $row.Expect) {
            $problems.Add("status $($item.Status), expected $($row.Expect)")
        }
        $captureCount = @($item.Captures).Count
        $check = Get-ExpectedCaptureCheck $row.ExpectCaptures
        if ($null -ne $check) {
            if (($check.Exact -ge 0 -and $captureCount -ne $check.Exact) -or $captureCount -lt $check.Min) {
                $problems.Add("$captureCount screenshot(s), expected $($row.ExpectCaptures)")
            }
        }
        if ($row.ExpectFinalUrl -and $item.FinalUrl -notlike $row.ExpectFinalUrl) {
            $problems.Add("final URL '$($item.FinalUrl)', expected '$($row.ExpectFinalUrl)'")
        }
        foreach ($capture in @($item.Captures)) {
            if (-not $capture.FilePath -or -not (Test-Path -LiteralPath $capture.FilePath)) {
                $problems.Add("screenshot file missing: '$($capture.FilePath)'")
                continue
            }
            foreach ($issue in (Test-ImageContent -Path $capture.FilePath -Width $screen.Width -Height $screen.Height)) {
                $problems.Add("$(Split-Path -Leaf $capture.FilePath) $issue")
            }
        }

        $label = '{0,2}. {1,-40} {2,-8} {3,2} shot(s)' -f $item.Index, $item.Name, $item.Status, $captureCount
        if ($problems.Count -eq 0) {
            Write-Host "  PASS  $label" -ForegroundColor Green
        }
        else {
            Add-Failure "$label - $($problems -join '; ')"
            foreach ($detail in @($item.Details)) { Write-Host "          detail: $detail" -ForegroundColor DarkGray }
        }
    }

    # FAILED rows make vouch exit 2; warnings exit 0 here (no -FailOnWarning).
    $expectedExit = if (@($rows | Where-Object Expect -eq 'FAILED').Count -gt 0) { 2 } else { 0 }
    if ($exitCode -ne $expectedExit) { Add-Failure "exit code $exitCode, expected $expectedExit" }
    else { Write-Host "  PASS  exit code $exitCode" -ForegroundColor Green }
}

# Edge must be shut down so the DevTools port does not stay open.
Start-Sleep -Seconds 2
$leftover = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msedge.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match "--remote-debugging-port=$DebugPort(?!\d)" })
if ($leftover.Count -gt 0) {
    Add-Failure "Edge is still running with DevTools port $DebugPort after the run."
    $leftover | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
else {
    Write-Host '  PASS  Edge closed and the DevTools port is shut' -ForegroundColor Green
}

Write-Host ''
$report = Get-ChildItem -LiteralPath $runDir -Filter '*.htm*' -File | Select-Object -First 1
if ($report) { Write-Host "Report: $($report.FullName)" }
if ($failures.Count -eq 0) {
    Write-Host "LIVE TEST PASSED ($($rows.Count) sites)" -ForegroundColor Green
    exit 0
}
Write-Host "LIVE TEST FAILED: $($failures.Count) problem(s)" -ForegroundColor Red
exit 1
