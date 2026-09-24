#Requires -Version 7
<#
    Integration tests: a headless Edge (throwaway profile, no visible window) driven over
    CDP against a local test server. The end-to-end test runs the real Invoke-Main with
    only the two desktop-bound functions mocked (window focus and screen capture), so it
    does not disturb the desktop.
    Tests tagged KnownIssue assert the CORRECT behaviour and fail until the bug is fixed.
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-VouchFunctionSource)))

    $script:WebPort = Get-FreeTcpPort
    $script:OtherOriginPort = Get-FreeTcpPort
    $script:SlowPort = Get-FreeTcpPort
    $script:CdpPort = Get-FreeTcpPort
    $script:ProfileDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "vouch-test-profile-$($script:CdpPort)"

    $script:ServerProcess = Start-TestServer -Port $script:WebPort, $script:OtherOriginPort
    $script:SlowServerProcess = Start-TestServer -Port $script:SlowPort
    $script:EdgeTestProcess = Start-HeadlessEdge -Port $script:CdpPort -ProfileDir $script:ProfileDir

    $script:Web = "http://localhost:$($script:WebPort)"

    function Connect-TestPage {
        Close-CdpSocket
        $target = Get-CdpPageTarget -Port $script:CdpPort
        Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
    }

    function Open-TestPage([string]$Url) {
        Set-NavigationMarker
        $navigation = Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $Url } -TimeoutSec 15
        Wait-PageReady -TimeoutSec 15 | Should -BeTrue
        return $navigation
    }
}

AfterAll {
    Close-CdpSocket
    Stop-HeadlessEdge -ProfileDir $script:ProfileDir
    foreach ($process in @($script:ServerProcess, $script:SlowServerProcess)) {
        if ($null -ne $process) { Stop-ProcessTree -ProcessId $process.Id }
    }
    Remove-DirectoryWithRetry -Path $script:ProfileDir
}

Describe 'CDP plumbing' -Tag 'Integration' {
    BeforeAll { Connect-TestPage }

    It 'navigates and detects the new document as ready' {
        [void](Open-TestPage "$Web/ok")
        Get-CurrentPageUrl | Should -Be "$Web/ok"
        Invoke-CdpEval -Expression 'document.title' | Should -Be 'OK page'
    }

    It 'reads the HTTP status of the main document' {
        [void](Open-TestPage "$Web/status/404")
        Invoke-CdpEval -Expression "(performance.getEntriesByType('navigation')[0]||{}).responseStatus||0" | Should -Be 404
    }

    It 'reports an unreachable host through Page.navigate errorText' {
        $navigation = Send-CdpCommand -Method 'Page.navigate' -Params @{ url = 'http://localhost:1/' } -TimeoutSec 15
        [string]$navigation.errorText | Should -Match '^net::ERR_'
    }

    It 'handles large CDP responses split across WebSocket frames' {
        $big = Invoke-CdpEval -Expression "'x'.repeat(300000)"
        $big.Length | Should -Be 300000
    }

    It 'surfaces JavaScript exceptions' {
        { Invoke-CdpEval -Expression 'throw new Error("boom")' } | Should -Throw '*boom*'
    }

    Context 'click steps' {
        BeforeEach { [void](Open-TestPage "$Web/tabs") }

        It 'click: uses the first element matching a selector with a pseudo-class' {
            Invoke-ClickSelector -Selector 'ul > li:nth-child(1) a.item'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'second'
        }

        It 'click: throws when nothing matches' {
            { Invoke-ClickSelector -Selector '#does-not-exist' } | Should -Throw '*No element matched*'
        }

        It 'clicktext: matches case-insensitively' {
            Invoke-ClickText -Text 'GENERAL'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'General'
        }

        It 'clicktext: prefers a visible element over a hidden one with the same text' {
            Invoke-ClickText -Text 'Audit Log'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Audit Log'
        }

        It 'clicktext: a partial match never lands on a sign-out link' {
            # 'Log' has no exact match; the first partial match in DOM order is "Log out".
            Invoke-ClickText -Text 'Log'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Logs'
        }

        It 'clicktext: still clicks a sign-out control when asked for it' {
            Invoke-ClickText -Text 'log out'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'SIGNED OUT'
        }

        It 'clicktext: says so when only hidden elements match' {
            { Invoke-ClickText -Text 'Archive' } | Should -Throw '*Only hidden elements*'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Tabs'
        }
    }

    Context 'after a command times out' {
        It 'the next command reconnects and succeeds' {
            { Invoke-CdpEval -Expression 'new Promise(r => setTimeout(r, 5000))' -TimeoutSec 2 } | Should -Throw '*Timed out*'
            # Cancelling ClientWebSocket.ReceiveAsync aborts the socket for good.
            $script:CdpSocket.State | Should -Be ([System.Net.WebSockets.WebSocketState]::Aborted)
            Invoke-CdpEval -Expression '1 + 1' | Should -Be 2
            $script:CdpSocket.State | Should -Be ([System.Net.WebSockets.WebSocketState]::Open)
        }
    }

    Context 'finding the browser process' {
        It 'finds the real browser, not the launcher Start-Process returned' {
            $browser = Find-EdgeBrowserProcess -Port $script:CdpPort
            $browser | Should -Not -BeNullOrEmpty
            $browser.Id | Should -Not -Be $script:EdgeTestProcess.Id
            $script:EdgeTestProcess.HasExited | Should -BeTrue
            (Find-EdgeBrowserProcess -ProfileDir $script:ProfileDir).Id | Should -Be $browser.Id
        }

        It 'returns nothing for a port or profile no Edge uses' {
            Find-EdgeBrowserProcess -Port 1 | Should -BeNullOrEmpty
            Find-EdgeBrowserProcess -ProfileDir 'C:\no\such\profile' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-Main end to end (desktop functions mocked)' -Tag 'Integration' {
    BeforeAll {
        Close-CdpSocket
        $script:RealNewHtmlReport = ${function:New-HtmlReport}
        $global:VouchE2E = @{}

        $other = "http://localhost:$($script:OtherOriginPort)"
        $slow = "http://localhost:$($script:SlowPort)"
        $csv = Join-Path -Path $TestDrive -ChildPath 'e2e.csv'
        @"
Name,Url,Steps,ScrollFullPage,Notes
Plain page,$Web/ok,,N,baseline
Very tall page,$Web/tall?px=20000,,Y,exceeds the segment cap
HTTP 404 with body,$Web/status/404,,N,
HTTP 404 empty body,$Web/status/404?empty=1,,N,
Expired session same origin,$Web/protected,,N,
Expired session other origin,$Web/xredirect?to=$other/login,,N,
Steps with a bad selector,$Web/tabs,clicktext:General;click:#missing,N,
Link to a slow page,$Web/links?to=$slow/slow?s=3,click:#go,N,
Unreachable host,http://localhost:1/,,N,
Slow page,$slow/slow?s=12,,N,
Plain page after the slow one,$Web/ok,,N,
"@ | Set-Content -LiteralPath $csv -Encoding utf8

        # Script parameters that Invoke-Main reads from its parent scope.
        $LoginSetup = $false
        $CsvPath = $csv
        $OutputDir = Join-Path -Path $TestDrive -ChildPath 'reports'
        $ReportName = 'e2e.html'
        $EdgeProfileDir = $script:ProfileDir
        $DebugPort = $script:CdpPort
        $NavigationTimeoutSec = 5
        $SettleSeconds = 0.2
        $ScrollSettleSeconds = 0.1
        $MaxScrollSegments = 3
        $ImageFormat = 'jpeg'
        $JpegQuality = 85
        $SaveImages = $true
        $KeepBrowserOpen = $false
        $FailOnWarning = $false

        Mock Set-EdgeForeground { $null }
        Mock Get-ScreenCapture { , [byte[]](0xFF, 0xD8, 0xFF, 0xD9) }
        Mock New-HtmlReport {
            $global:VouchE2E.Items = $Items
            $global:VouchE2E.Run = $Run
            & $script:RealNewHtmlReport -Items $Items -Run $Run
        }

        Invoke-Main 6>$null
        $script:Items = @{}
        foreach ($i in $global:VouchE2E.Items) { $script:Items[$i.Name] = $i }
        $script:ReportFile = Join-Path -Path $OutputDir -ChildPath 'e2e.html'
    }

    AfterAll { Remove-Variable -Name VouchE2E -Scope Global -ErrorAction SilentlyContinue }

    It 'writes the report and exits with code 2 because rows failed' {
        $script:ReportFile | Should -Exist
        $script:ExitCode | Should -Be 2
        $global:VouchE2E.Run.Total | Should -Be 11
    }

    It 'captures a plain page as OK' {
        $item = $script:Items['Plain page']
        $item.Status | Should -Be 'OK'
        $item.HttpStatus | Should -Be 200
        $item.Captures.Count | Should -Be 1
    }

    It 'truncates a tall page at -MaxScrollSegments with a warning' {
        $item = $script:Items['Very tall page']
        $item.Status | Should -Be 'WARNING'
        $item.Captures.Count | Should -Be 3
        $item.Captures[2].SegmentCount | Should -Be 3
    }

    It 'reports the truncation only once' {
        @($script:Items['Very tall page'].Details | Where-Object { $_ -like 'Page truncated*' }).Count | Should -Be 1
    }

    It 'fails an HTTP 404 but still captures the error page' {
        $item = $script:Items['HTTP 404 with body']
        $item.Status | Should -Be 'FAILED'
        $item.HttpStatus | Should -Be 404
        $item.Captures.Count | Should -Be 1
    }

    It 'captures an HTTP 404 with an empty body too, as the README promises' {
        # Chromium reports errorText net::ERR_HTTP_RESPONSE_CODE_FAILURE and shows its own
        # error page; that page is the evidence.
        $item = $script:Items['HTTP 404 empty body']
        $item.Status | Should -Be 'FAILED'
        $item.Captures.Count | Should -Be 1
        $item.FinalUrl | Should -Be "$Web/status/404?empty=1"
        ($item.Details -join ' ') | Should -Match 'empty body'
        ($item.Details -join ' ') | Should -Not -Match 'Redirected'
    }

    It 'flags a redirect to another origin as a possible login' {
        $item = $script:Items['Expired session other origin']
        $item.Status | Should -Be 'WARNING'
        ($item.Details -join ' ') | Should -Match 'possible login required'
    }

    It 'flags a redirect to a login page on the same origin' {
        $item = $script:Items['Expired session same origin']
        $item.FinalUrl | Should -Match '/login'
        $item.Status | Should -Be 'WARNING'
        ($item.Details -join ' ') | Should -Match 'sign-in page \(/login\)'
    }

    It 'waits for a page opened by a click step to load before capturing' {
        $item = $script:Items['Link to a slow page']
        $item.StepLog[0].Ok | Should -BeTrue
        $item.FinalUrl | Should -BeLike '*/slow?s=3'
        $item.Status | Should -Be 'OK'
    }

    It 'records a failed step as a warning and still captures' {
        $item = $script:Items['Steps with a bad selector']
        $item.Status | Should -Be 'WARNING'
        $item.StepLog.Count | Should -Be 2
        $item.StepLog[0].Ok | Should -BeTrue
        $item.StepLog[1].Ok | Should -BeFalse
        $item.Captures.Count | Should -Be 1
    }

    It 'fails an unreachable host without a screenshot' {
        $item = $script:Items['Unreachable host']
        $item.Status | Should -Be 'FAILED'
        $item.Captures.Count | Should -Be 0
        ($item.Details -join ' ') | Should -Match 'net::ERR_'
    }

    It 'fails a page that exceeds -NavigationTimeoutSec' {
        $script:Items['Slow page'].Status | Should -Be 'FAILED'
    }

    It 'keeps capturing the rows after a timed-out page' {
        $item = $script:Items['Plain page after the slow one']
        ($item.Details -join ' ') | Should -Not -Match 'Aborted'
        $item.Status | Should -Be 'OK'
    }

    It 'saves the images with -SaveImages' {
        @(Get-ChildItem -LiteralPath (Join-Path $OutputDir 'images') -Filter '*.jpg').Count |
            Should -Be $global:VouchE2E.Run.CaptureCount
    }
}

Describe 'Exit codes for warning-only runs' -Tag 'Integration' {
    BeforeAll {
        $csv = Join-Path -Path $TestDrive -ChildPath 'warn.csv'
        "Name,Url`nExpired session,$Web/protected" | Set-Content -LiteralPath $csv -Encoding utf8

        $LoginSetup = $false
        $CsvPath = $csv
        $OutputDir = Join-Path -Path $TestDrive -ChildPath 'warn-reports'
        $ReportName = ''
        $EdgeProfileDir = $script:ProfileDir
        $DebugPort = $script:CdpPort
        $NavigationTimeoutSec = 10
        $SettleSeconds = 0.1
        $ScrollSettleSeconds = 0.1
        $MaxScrollSegments = 3
        $ImageFormat = 'jpeg'
        $JpegQuality = 85
        $SaveImages = $false
        $KeepBrowserOpen = $false

        Mock Set-EdgeForeground { $null }
        Mock Get-ScreenCapture { , [byte[]](0xFF, 0xD8, 0xFF, 0xD9) }
    }

    It 'exits 0 by default' {
        $FailOnWarning = $false
        Invoke-Main 6>$null
        $script:ExitCode | Should -Be 0
    }

    It 'exits 3 with -FailOnWarning' {
        $FailOnWarning = $true
        Invoke-Main 6>$null
        $script:ExitCode | Should -Be 3
    }
}

Describe 'Browser lifecycle' -Tag 'Integration' {
    BeforeEach {
        $lifecycleProfile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "vouch-test-profile-life-$(Get-Random)"
    }
    AfterEach {
        Stop-HeadlessEdge -ProfileDir $lifecycleProfile
        Remove-DirectoryWithRetry -Path $lifecycleProfile
        $script:LaunchedEdge = $false
        $script:EdgeProcess = $null
        $script:BrowserWsUrl = ''
    }

    It 'Stop-EdgeProcess shuts down the Edge this run launched' {
        $port = Get-FreeTcpPort
        [void](Start-HeadlessEdge -Port $port -ProfileDir $lifecycleProfile)
        $info = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -NoProxy
        $script:LaunchedEdge = $true
        $script:EdgeProcess = Find-EdgeBrowserProcess -Port $port
        $script:BrowserWsUrl = Get-BrowserWebSocketUrl -VersionInfo $info
        $browserId = $script:EdgeProcess.Id

        Stop-EdgeProcess

        Get-Process -Id $browserId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-DebugEndpointInfo -Port $port -TimeoutSec 1 | Should -BeNullOrEmpty
    }

    It 'Get-CdpPageTarget uses the existing tab instead of opening another' {
        $port = Get-FreeTcpPort
        [void](Start-HeadlessEdge -Port $port -ProfileDir $lifecycleProfile)
        $target = Get-CdpPageTarget -Port $port -WaitSeconds 10
        $pages = @(Get-DevToolsTargetList -Port $port | Where-Object type -eq 'page')
        $pages.Count | Should -Be 1
        $target.id | Should -Be $pages[0].id
    }

    It 'Close-OtherPageTargets leaves only the tab in use' {
        $port = Get-FreeTcpPort
        [void](Start-HeadlessEdge -Port $port -ProfileDir $lifecycleProfile)
        $keep = Get-CdpPageTarget -Port $port -WaitSeconds 10
        1..2 | ForEach-Object { [void](Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$port/json/new?about:blank" -NoProxy) }
        @(Get-DevToolsTargetList -Port $port | Where-Object type -eq 'page').Count | Should -Be 3

        Close-OtherPageTargets -Port $port -KeepId $keep.id
        Start-Sleep -Milliseconds 500
        $pages = @(Get-DevToolsTargetList -Port $port | Where-Object type -eq 'page')
        $pages.Count | Should -Be 1
        $pages[0].id | Should -Be $keep.id
    }

    It 'Start-EdgeDebug refuses a profile an ordinary Edge window already holds' {
        # No DevTools port: the situation after -LoginSetup's window was left open.
        [void](Start-Process -FilePath (Get-EdgePathForTest) -ArgumentList @(
            '--headless=new', "--user-data-dir=`"$lifecycleProfile`"", '--no-first-run', 'about:blank'))
        $deadline = (Get-Date).AddSeconds(15)
        while ($null -eq (Find-EdgeBrowserProcess -ProfileDir $lifecycleProfile) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
        }

        { Start-EdgeDebug -EdgePath (Get-EdgePathForTest) -ProfileDir $lifecycleProfile -Port (Get-FreeTcpPort) } |
            Should -Throw '*already running with the audit profile*'
        $script:LaunchedEdge | Should -BeFalse
    }
}

Describe 'Running from another working directory (scheduled-task style)' -Tag 'Integration' {
    It 'finds captures.csv next to the script when -CsvPath is omitted' {
        # Task Scheduler starts in C:\Windows\System32 unless "Start in" is set; the
        # defaults .\captures.csv and .\reports resolve against that, not the script folder.
        $folder = Join-Path -Path $TestDrive -ChildPath 'install'
        [void](New-Item -ItemType Directory -Path $folder)
        Copy-Item -LiteralPath $script:VouchPath -Destination (Join-Path -Path $folder -ChildPath 'vouch.ps1')
        Set-Content -LiteralPath (Join-Path $folder 'captures.csv') -Value 'Name,Url,Steps,ScrollFullPage,Notes' -Encoding utf8
        $pwsh = (Get-Process -Id $PID).Path
        $log = Join-Path -Path $TestDrive -ChildPath 'wd-stdout.txt'
        $process = Start-Process -FilePath $pwsh -WorkingDirectory $env:SystemRoot -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $log -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$(Join-Path $folder 'vouch.ps1')`"")
        $output = Get-Content -LiteralPath $log -Raw
        $process.ExitCode | Should -Be 1
        $output | Should -Match 'ERROR:'
        # With the CSV found, the run stops at "no capture rows" instead of "not found".
        $output | Should -Not -Match 'Capture definition CSV not found'
    }
}
