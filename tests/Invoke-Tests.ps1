#Requires -Version 7
<#
.SYNOPSIS
    Runs the Vouch Pester suite.

.DESCRIPTION
    Unit tests need nothing but PowerShell 7 and Pester 5+. Integration tests also need
    Microsoft Edge; they run it headless with a throwaway profile, so no window appears
    and neither your own Edge profile nor the Vouch audit profile is touched.

    The whole suite takes about 7 minutes, most of it the integration tests; -UnitOnly
    is much quicker.

    Tests tagged KnownIssue assert the correct behaviour for bugs that are not fixed yet
    and are expected to fail. Use -ExcludeKnownIssues for a green/red regression signal.

    Tests tagged Interactive show a real window on the desktop (the Vouch dialog) and
    are left out unless -IncludeInteractive is given.

.EXAMPLE
    .\tests\Invoke-Tests.ps1

.EXAMPLE
    .\tests\Invoke-Tests.ps1 -UnitOnly -ExcludeKnownIssues

.EXAMPLE
    .\tests\Invoke-Tests.ps1 -ScriptPath C:\temp\vouch.patched.ps1 -ResultPath .\testResults.xml
#>
[CmdletBinding()]
param(
    [switch]$UnitOnly,
    [switch]$ExcludeKnownIssues,
    # Also run the tests that show a real window (tag Interactive).
    [switch]$IncludeInteractive,
    # Test another copy of vouch.ps1 instead of the one next to this folder.
    [string]$ScriptPath = '',
    # Also write NUnit XML results here (for CI).
    [string]$ResultPath = ''
)

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester) {
    Write-Host 'Pester 5 or later is required: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0' -ForegroundColor Red
    exit 1
}
Import-Module $pester -Force

if ($ScriptPath) { $env:VOUCH_PATH = (Resolve-Path -LiteralPath $ScriptPath).Path }

$config = New-PesterConfiguration
$config.Run.Path = if ($UnitOnly) {
    @('Vouch.Unit.Tests.ps1', 'Schedule.Unit.Tests.ps1', 'Integrity.Unit.Tests.ps1' | ForEach-Object { Join-Path $PSScriptRoot $_ })
}
else { $PSScriptRoot }
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
$excludeTags = @()
if ($ExcludeKnownIssues) { $excludeTags += 'KnownIssue' }
if (-not $IncludeInteractive) { $excludeTags += 'Interactive' }
if ($excludeTags.Count -gt 0) { $config.Filter.ExcludeTag = $excludeTags }
if ($ResultPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $ResultPath
}

try { Invoke-Pester -Configuration $config }
finally { Remove-Item Env:VOUCH_PATH -ErrorAction SilentlyContinue }
