# Shared helpers for the Vouch Pester tests.

# $env:VOUCH_PATH points the suite at another copy of the script (e.g. a patched one).
$script:VouchPath = if ($env:VOUCH_PATH) {
    (Resolve-Path -LiteralPath $env:VOUCH_PATH).Path
}
else {
    (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\vouch.ps1')).Path
}

function Get-VouchFunctionSource {
    <#
        vouch.ps1 runs Invoke-Main and calls exit when dot-sourced (and the installer acts
        on the Task Scheduler), so the tests load only function definitions and script
        state, extracted from the AST. Several files can be given (vouch.ps1 and
        designer\Designer.ps1); their state comes first, then their functions, in order.
    #>
    param([string[]]$Path = @($script:VouchPath))
    $state = [System.Collections.Generic.List[string]]::new()
    $functions = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $Path) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "$file has parse errors: $($errors[0].Message)" }

        foreach ($statement in $ast.EndBlock.Statements) {
            if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $functions.Add($statement.Extent.Text)
            }
            # The script-level state ($script:CdpSocket = $null, ...) comes along too, so
            # the tests never drift from the script's own initial values.
            elseif ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $statement.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $statement.Left.VariablePath.UserPath -like 'script:*') {
                $state.Add($statement.Extent.Text)
            }
        }
    }

    return ($state -join "`n") + "`n`n" + ($functions -join "`n`n")
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Get-EdgePathForTest {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    $path = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    foreach ($candidate in @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                             "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Start-TestServer {
    param([Parameter(Mandatory)][int[]]$Port)
    $pwsh = (Get-Process -Id $PID).Path
    $script = Join-Path -Path $PSScriptRoot -ChildPath 'TestServer.ps1'
    $process = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', "`"$script`"", '-Port', ($Port -join ','))
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try {
            [void](Invoke-WebRequest -Uri "http://localhost:$($Port[0])/ok" -TimeoutSec 2 -NoProxy)
            return $process
        }
        catch { Start-Sleep -Milliseconds 250 }
    }
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Test server on port $($Port -join ',') did not start."
}

function Start-HeadlessEdge {
    <#
        A headless Edge with a throwaway profile: never shows a window, never touches the
        user's own Edge profile or the Vouch audit profile. --disable-sync: a fresh profile
        on a work-joined PC otherwise opens edge://sync-confirmation-dialog/ as an extra tab.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ProfileDir
    )
    $edge = Get-EdgePathForTest
    if (-not $edge) { throw 'Microsoft Edge is not installed.' }
    $process = Start-Process -FilePath $edge -PassThru -ArgumentList @(
        '--headless=new', "--remote-debugging-port=$Port", "--user-data-dir=`"$ProfileDir`"",
        '--no-first-run', '--no-default-browser-check', '--disable-sync', '--window-size=1280,800', 'about:blank')
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try {
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -NoProxy)
            return $process
        }
        catch { Start-Sleep -Milliseconds 300 }
    }
    throw "Headless Edge did not open port $Port."
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Stop-HeadlessEdge {
    <#
        The msedge.exe that Start-Process returns is a launcher that exits at once; the
        real browser is a child with another PID. Match every process on the profile path.
    #>
    param([Parameter(Mandatory)][string]$ProfileDir)
    Get-CimInstance -ClassName Win32_Process -Filter "Name='msedge.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ProfileDir, [System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Remove-DirectoryWithRetry {
    # Edge's child processes keep profile files locked for a moment after the kill.
    param([string]$Path)
    for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $Path); $attempt++) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
        catch { Start-Sleep -Milliseconds 500 }
    }
}
