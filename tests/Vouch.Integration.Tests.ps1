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

        It 'clicktext: a partial match takes the shortest label' {
            # 'Log' has no exact match; of the partial matches "Log out", "Audit Log" and
            # "Logs", "Logs" is the shortest. The sign-out guard is tested on /signout.
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

        It 'clicktext find-only names the element the click then hits (<Case>)' -ForEach @(
            @{ Case = 'exact, a hidden twin first'; Text = 'Audit Log'; Id = 't-audit'; Exact = $true; Title = 'Audit Log' }
            @{ Case = 'partial, the shortest label'; Text = 'Log'; Id = 't-logs'; Exact = $false; Title = 'Logs' }
            @{ Case = 'sign-out when asked for it'; Text = 'log out'; Id = 'signout'; Exact = $true; Title = 'SIGNED OUT' }
        ) {
            $found = Invoke-CdpEval -Expression (Get-ClickTextScript -Text $Text -FindOnly)
            $found.found | Should -BeTrue
            $found.id | Should -Be $Id
            $found.exact | Should -Be $Exact
            $found.frame | Should -Be ''
            $found.visible | Should -BeTrue
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Tabs' -Because 'find-only clicks nothing'
            Invoke-ClickText -Text $Text
            Invoke-CdpEval -Expression 'document.title' | Should -Be $Title
        }

        It 'clicktext: a partial match skips a sign-out link even when it is the shortest (find-only and click)' {
            [void](Open-TestPage "$Web/signout")
            $found = Invoke-CdpEval -Expression (Get-ClickTextScript -Text 'log' -FindOnly)
            $found.id | Should -Be 'logsettings'
            $found.exact | Should -BeFalse
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Sign out'
            Invoke-ClickText -Text 'log'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'LOG SETTINGS'
        }

        It 'clicktext find-only says when only hidden elements match' {
            $found = Invoke-CdpEval -Expression (Get-ClickTextScript -Text 'Archive' -FindOnly)
            $found.found | Should -BeFalse
            $found.hidden | Should -BeTrue
        }

        It 'click find-only names the element a selector would click' {
            $found = Invoke-CdpEval -Expression (Get-ClickSelectorScript -Selector 'ul > li:nth-child(1) a.item' -FindOnly)
            $found.found | Should -BeTrue
            $found.tag | Should -Be 'a'
            $found.text | Should -Be 'A'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Tabs'
            (Invoke-CdpEval -Expression (Get-ClickSelectorScript -Selector '#nope' -FindOnly)).found | Should -BeFalse
        }
    }

    Context 'finding what scrolls' {
        It 'uses the window on an ordinary long page' {
            [void](Open-TestPage "$Web/tall?px=3000")
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript)
            $target.kind | Should -Be 'window'
            $target.total | Should -BeGreaterThan 2900
        }

        It 'finds nothing to scroll on a page that fits' {
            [void](Open-TestPage "$Web/ok")
            (Invoke-CdpEval -Expression (Get-ScrollTargetScript)).kind | Should -Be 'none'
        }

        It 'scrolls the inner panel of an app-style page' {
            [void](Open-TestPage "$Web/innerscroll?rows=20")
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript)
            $target.kind | Should -Be 'element'
            $target.description | Should -Be 'div#main'
            $target.total | Should -Be 2020   # 20 rows of 100 px plus a 1 px border each
            $target.view | Should -BeLessThan $target.total
            @($target.others).Count | Should -Be 0
            Invoke-CdpEval -Expression 'window.__vouchTarget.to(500)' | Should -Be 500
            Invoke-CdpEval -Expression "document.getElementById('main').scrollTop" | Should -Be 500
            Invoke-CdpEval -Expression 'window.scrollY' | Should -Be 0
        }

        It 'scrolls the frame that holds the content' {
            [void](Open-TestPage "$Web/framepage?rows=30")
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript)
            $target.kind | Should -Be 'frame'
            $target.description | Should -BeLike '*framecontent*'
            [void](Invoke-CdpEval -Expression 'window.__vouchTarget.to(700)')
            Invoke-CdpEval -Expression "document.getElementById('content').contentWindow.scrollY" | Should -Be 700
        }

        It 'reports a second large scrolling area it does not scroll' {
            [void](Open-TestPage "$Web/tworegions")
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript)
            $target.kind | Should -Be 'element'
            @($target.others).Count | Should -Be 1
        }

        It 'reports a large frame from another site' {
            [void](Open-TestPage "$Web/xframe?to=http://localhost:$($script:OtherOriginPort)/tall")
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript)
            @($target.blockedFrames).Count | Should -Be 1
            @($target.blockedFrames)[0] | Should -BeLike "*:$($script:OtherOriginPort)/tall"
        }
    }

    Context 'click steps inside frames' {
        BeforeEach { [void](Open-TestPage "$Web/framepage") }

        It 'clicktext: finds a button inside a same-site frame' {
            Invoke-ClickText -Text 'Frame button'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'FRAME CLICKED'
        }

        It 'click: finds a selector inside a same-site frame' {
            Invoke-ClickSelector -Selector '#frame-btn'
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'FRAME CLICKED'
        }

        It 'find-only names the frame the element is in' {
            $byText = Invoke-CdpEval -Expression (Get-ClickTextScript -Text 'Frame button' -FindOnly)
            $bySelector = Invoke-CdpEval -Expression (Get-ClickSelectorScript -Selector '#frame-btn' -FindOnly)
            foreach ($found in $byText, $bySelector) {
                $found.id | Should -Be 'frame-btn'
                $found.frame | Should -BeLike '*framecontent*'
            }
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Frame page'
        }

        It 'Wait-PageElement finds a visible element inside a same-site frame' {
            Wait-PageElement -Selector '#frame-btn' -TimeoutSec 5 | Should -BeTrue
            Wait-PageElement -Selector '#not-there' -TimeoutSec 0.5 | Should -BeFalse
            { Wait-PageElement -Selector 'div[' -TimeoutSec 5 } | Should -Throw '*not a CSS selector*'
        }

        It 'waits for a page loaded inside the frame by a click' {
            Set-StepNavigationProbe
            Invoke-ClickText -Text 'Frame next'
            Start-Sleep -Milliseconds 200
            Wait-StepNavigation -TimeoutSec 15
            Invoke-CdpEval -Expression "document.getElementById('content').contentDocument.title" | Should -Be 'Slow same'
        }

        It 'explains that frames from another site cannot be searched' {
            [void](Open-TestPage "$Web/xframe?to=http://localhost:$($script:OtherOriginPort)/tabs")
            { Invoke-ClickText -Text 'General' } | Should -Throw '*1 frame(s) from another site*'
            { Invoke-ClickSelector -Selector '#t-general' } | Should -Throw '*1 frame(s) from another site*'
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
Inner scrolling panel,$Web/innerscroll?rows=12,,Y,
Frame with a click,$Web/framepage?rows=12,clicktext:Frame button,Y,
Frame from another site,$Web/xframe?to=$other/tall,,Y,
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
        # A real (tiny) JPEG carrying the real metadata, so the report can be verified in full.
        Mock Get-ScreenCapture {
            $bitmap = [System.Drawing.Bitmap]::new(16, 10)
            try {
                if ($Metadata) { Set-JpegMetadata -Image $bitmap -Metadata $Metadata }
                $stream = [System.IO.MemoryStream]::new()
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                , $stream.ToArray()
            }
            finally { $bitmap.Dispose() }
        }
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
        $global:VouchE2E.Run.Total | Should -Be 14
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

    It 'captures an app-style page by scrolling its inner panel' {
        $item = $script:Items['Inner scrolling panel']
        ($item.Details -join ' | ') | Should -BeNullOrEmpty
        $item.Status | Should -Be 'OK'
        $item.ScrollArea | Should -Be 'div#main'
        # 1212 px of rows in a panel of roughly 600-740 px: two or three screens.
        $item.Captures.Count | Should -BeGreaterOrEqual 2
        $item.Captures.Count | Should -BeLessOrEqual 3
    }

    It 'clicks inside a frame, then captures by scrolling the frame' {
        $item = $script:Items['Frame with a click']
        $item.Status | Should -Be 'OK'
        $item.StepLog[0].Ok | Should -BeTrue
        $item.ScrollArea | Should -BeLike 'the frame *framecontent*'
        ($item.Details -join ' | ') | Should -BeNullOrEmpty
        $item.Captures.Count | Should -BeGreaterOrEqual 2
        $item.Captures.Count | Should -BeLessOrEqual 3
    }

    It 'warns that a frame from another site cannot be scrolled' {
        $item = $script:Items['Frame from another site']
        $item.Status | Should -Be 'WARNING'
        ($item.Details -join ' ') | Should -Match 'frame from another site'
        $item.Captures.Count | Should -Be 1
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

    It 'saves the images with -SaveImages, in a folder of their own with SHA256SUMS' {
        $imagesDir = Join-Path $OutputDir 'images\e2e'
        @(Get-ChildItem -LiteralPath $imagesDir -Filter '*.jpg').Count | Should -Be $global:VouchE2E.Run.CaptureCount
        $sums = @(Get-Content -LiteralPath (Join-Path $imagesDir 'SHA256SUMS'))
        $sums.Count | Should -Be $global:VouchE2E.Run.CaptureCount
        $global:VouchE2E.Run.ManifestSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'produces a report that -Verify accepts' {
        $results = @(Test-ReportIntegrity -Path $script:ReportFile)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($results | Where-Object Check -like 'Metadata *').Count | Should -Be $global:VouchE2E.Run.CaptureCount
        @($results | Where-Object Check -like 'File *').Count | Should -Be $global:VouchE2E.Run.CaptureCount
    }
}

Describe 'Invoke-Main with a configuration file (desktop functions mocked)' -Tag 'Integration' {
    # The same pages as the CSV run above, converted to a configuration file, plus a
    # switched-off page, a page that waits for an element and a page with its own timing.
    BeforeAll {
        Close-CdpSocket
        $script:CsvItems = $script:Items   # from the CSV end-to-end run above
        $script:RealNewHtmlReportForConfig = ${function:New-HtmlReport}
        $script:RealWaitPageReady = ${function:Wait-PageReady}
        $global:VouchCfg = @{ OwnTimeout = 0; OwnSettle = 0 }

        $other = "http://localhost:$($script:OtherOriginPort)"
        $slow = "http://localhost:$($script:SlowPort)"
        $csv = Join-Path -Path $TestDrive -ChildPath 'cfg-source.csv'
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
Inner scrolling panel,$Web/innerscroll?rows=12,,Y,
Frame with a click,$Web/framepage?rows=12,clicktext:Frame button,Y,
Frame from another site,$Web/xframe?to=$other/tall,,Y,
Unreachable host,http://localhost:1/,,N,
Slow page,$slow/slow?s=12,,N,
Plain page after the slow one,$Web/ok,,N,
"@ | Set-Content -LiteralPath $csv -Encoding utf8

        $config = ConvertTo-VouchConfig -Path $csv
        $config['browser']['profileDir'] = $script:ProfileDir
        $config['browser']['debugPort'] = $script:CdpPort
        $config['defaults']['navigationTimeoutSec'] = 5
        $config['defaults']['settleSeconds'] = 0.2
        $config['defaults']['scrollSettleSeconds'] = 0.1
        $config['defaults']['maxScrollSegments'] = 3
        $config['output']['dir'] = 'cfg-reports'          # relative to the configuration file
        $config['output']['reportName'] = 'cfg.html'
        $config['output']['saveImages'] = $true
        $config['output']['jsonSummary'] = $true
        $config['report']['title'] = 'Not applied yet'
        $capture = [ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'none' } }
        # Third in the file: the pages after it must keep the CSV run's numbers and file names.
        $config['pages'].Insert(2, [ordered]@{ id = 'off'; name = 'Switched off'; url = "$Web/ok"; enabled = $false; actions = @($capture) })
        $config['pages'].Add([ordered]@{ id = 'waits'; name = 'Waits for an element'; url = "$Web/ok"
            actions = @([ordered]@{ type = 'waitFor'; selector = 'h1' }, $capture) })
        $config['pages'].Add([ordered]@{ id = 'timing'; name = 'Own timing'; url = "$Web/ok"
            overrides = [ordered]@{ navigationTimeoutSec = 9; settleSeconds = 0.73 }; actions = @($capture) })

        $folder = Join-Path -Path $TestDrive -ChildPath 'cfg folder'
        [void](New-Item -ItemType Directory -Path $folder)
        $script:ConfigFile = Join-Path -Path $folder -ChildPath 'run.json'
        [System.IO.File]::WriteAllText($script:ConfigFile, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $script:CfgReportFile = Join-Path -Path $folder -ChildPath 'cfg-reports\cfg.html'

        Mock Set-EdgeForeground { $null }
        Mock Get-ScreenCapture {
            $bitmap = [System.Drawing.Bitmap]::new(16, 10)
            try {
                if ($Metadata) { Set-JpegMetadata -Image $bitmap -Metadata $Metadata }
                $stream = [System.IO.MemoryStream]::new()
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                , $stream.ToArray()
            }
            finally { $bitmap.Dispose() }
        }
        Mock New-HtmlReport {
            $global:VouchCfg.Items = $Items
            $global:VouchCfg.Run = $Run
            & $script:RealNewHtmlReportForConfig -Items $Items -Run $Run
        }
        # Record that the page's own timing reached the engine, then do the real work.
        Mock Wait-PageReady -ParameterFilter { $TimeoutSec -eq 9 } {
            $global:VouchCfg.OwnTimeout++
            & $script:RealWaitPageReady -TimeoutSec $TimeoutSec
        }
        Mock Start-Sleep -ParameterFilter { $Milliseconds -eq 730 } {
            $global:VouchCfg.OwnSettle++
            # Not Start-Sleep: Pester routes even a module-qualified call back into this mock.
            [System.Threading.Thread]::Sleep($Milliseconds)
        }

        # Only the configuration is typed; every other setting comes from the file.
        $script:CfgOutput = Invoke-Main -BoundParameters @{ ConfigPath = $script:ConfigFile } 6>&1 | Out-String
        $script:CfgExitCode = $script:ExitCode
        $script:CfgItems = [ordered]@{}
        foreach ($i in $global:VouchCfg.Items) { $script:CfgItems[$i.Name] = $i }
    }

    AfterAll { Remove-Variable -Name VouchCfg -Scope Global -ErrorAction SilentlyContinue }

    It 'gives every CSV page the same status, steps and screenshots as the CSV run' {
        if (-not $script:CsvItems) { Set-ItResult -Skipped -Because 'the CSV end-to-end run did not run in this session' }
        foreach ($name in $script:CsvItems.Keys) {
            $want = $script:CsvItems[$name]
            $got = $script:CfgItems[$name]
            $got | Should -Not -BeNullOrEmpty -Because $name
            $got.Index | Should -Be $want.Index -Because $name
            $got.Status | Should -Be $want.Status -Because $name
            $got.HttpStatus | Should -Be $want.HttpStatus -Because $name
            $got.ScrollFullPage | Should -Be $want.ScrollFullPage -Because $name
            $got.ScrollArea | Should -Be $want.ScrollArea -Because $name
            @($got.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) | Should -Be @($want.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) -Because $name
            @($got.Captures.FileName) | Should -Be @($want.Captures.FileName) -Because $name
        }
    }

    It 'exits 2 like the CSV run and reads its settings from the file' {
        $script:CfgExitCode | Should -Be 2
        $script:CfgReportFile | Should -Exist
        [System.IO.Path]::ChangeExtension($script:CfgReportFile, '.json') | Should -Exist
        $global:VouchCfg.Run.CsvPath | Should -Be $script:ConfigFile
        @(Get-ChildItem -LiteralPath (Join-Path (Split-Path $script:CfgReportFile) 'images\cfg') -Filter '*.jpg').Count |
            Should -Be $global:VouchCfg.Run.CaptureCount
    }

    It 'skips a switched-off page entirely' {
        $script:CfgItems.Contains('Switched off') | Should -BeFalse
        $global:VouchCfg.Run.Total | Should -Be 16
        @($global:VouchCfg.Items.Index) | Should -Be (1..16)
        $script:CfgOutput | Should -Match '1 other page\(s\) not selected or switched off'
    }

    It 'runs a page that waits for an element, and carries on' {
        $item = $script:CfgItems['Waits for an element']
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        @($item.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) | Should -Be @('waitfor:h1|True')
        $item.Captures.Count | Should -Be 1
        $item.HttpStatus | Should -Be 200
        $item.StepsText | Should -Be 'waitfor:h1'
        $script:CfgItems['Own timing'].Status | Should -Be 'OK' -Because ($script:CfgItems['Own timing'].Details -join ' | ')
    }

    It 'applies a page''s own timeout and settle time to that page only' {
        $global:VouchCfg.OwnTimeout | Should -Be 1
        $global:VouchCfg.OwnSettle | Should -Be 1
        $script:CfgItems['Own timing'].Captures.Count | Should -Be 1
    }

    It 'says once which settings have no effect yet' {
        $lines = @($script:CfgOutput -split "`r?`n" | Where-Object { $_ -like 'WARNING: this version of Vouch does not apply*' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'report\.title'
    }

    It 'produces a report that -Verify accepts' {
        $results = @(Test-ReportIntegrity -Path $script:CfgReportFile)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
    }
}

Describe 'vouch.ps1 with -ConfigPath (the real script)' -Tag 'Integration' {
    BeforeAll {
        function Invoke-VouchScript {
            param([string[]]$Arguments)
            $pwsh = (Get-Process -Id $PID).Path
            $log = Join-Path -Path $TestDrive -ChildPath ("out-{0}.txt" -f [guid]::NewGuid())
            $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
            $process = Start-Process -FilePath $pwsh -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log `
                -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', "`"$script:VouchPath`"") + $quoted)
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = (Get-Content -LiteralPath $log -Raw) }
        }
    }

    It 'refuses -CsvPath and -ConfigPath together' {
        $result = Invoke-VouchScript -Arguments '-CsvPath', 'a.csv', '-ConfigPath', 'b.json'
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Use either -CsvPath or -ConfigPath, not both'
    }

    It 'starts the log in output.logDir, next to the configuration file' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'log cfg'
        [void](New-Item -ItemType Directory -Path $folder)
        $path = Join-Path -Path $folder -ChildPath 'empty.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "output": { "logDir": "logs" }, "pages": [] }' -Encoding utf8
        $result = Invoke-VouchScript -Arguments '-ConfigPath', $path
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'has no pages'
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $folder 'logs') -Filter 'vouch_*.log')
        $logs.Count | Should -Be 1
        Get-Content -LiteralPath $logs[0].FullName -Raw | Should -Match 'has no pages'
    }
}

Describe 'Invoke-CaptureItem on its own (one page, desktop functions mocked)' -Tag 'Integration' {
    # The single-page path the Designer will use: no Invoke-Main, no CSV run.
    BeforeAll {
        Connect-TestPage
        Mock Set-EdgeForeground { $null }
        Mock Get-ScreenCapture { , [byte[]](0xFF, 0xD8, 0xFF, 0xD9) }

        $csv = Join-Path -Path $TestDrive -ChildPath 'single.csv'
        @"
Name,Url,Steps,ScrollFullPage,Notes
Tabs with a click,$Web/tabs,clicktext:General,N,one page
Tall page,$Web/tall?px=3000,,Y,
"@ | Set-Content -LiteralPath $csv -Encoding utf8
        $definitions = Import-CaptureDefinition -Path $csv

        $settings = Resolve-RunSettings -BoundParameters @{} -Config $null -Defaults @{
            NavigationTimeoutSec = 10; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10
        }
        $context = @{
            RunId = [guid]::NewGuid().ToString(); Format = 'jpeg'; Quality = 85; Extension = 'jpg'
            SaveImages = $false; ImagesDir = ''; Screen = '1x1'
        }
        $script:Single = Invoke-CaptureItem -Definition $definitions[0] -Settings $settings -CaptureContext $context 6>$null
        $script:Tall = Invoke-CaptureItem -Definition $definitions[1] -Settings $settings -CaptureContext $context 6>$null
    }

    AfterAll { Close-CdpSocket }

    It 'returns one item with the fields the report and the end-to-end run use' {
        @($script:Single).Count | Should -Be 1
        $script:Single.PSObject.Properties.Name | Should -Be @(
            'Index', 'Name', 'Url', 'FinalUrl', 'Notes', 'StepsText', 'ScrollFullPage', 'ScrollArea',
            'Status', 'HttpStatus', 'Details', 'StepLog', 'Captures')
        $script:Single.Captures.GetType().Name | Should -Be 'List`1'
    }

    It 'navigates, runs the step and captures one screen' {
        $script:Single.Status | Should -Be 'OK'
        $script:Single.HttpStatus | Should -Be 200
        $script:Single.FinalUrl | Should -Be "$Web/tabs"
        $script:Single.StepLog.Count | Should -Be 1
        $script:Single.StepLog[0].Ok | Should -BeTrue
        $script:Single.Captures.Count | Should -Be 1
        $script:Single.Captures[0].FileName | Should -Be '001_Tabs_with_a_click_seg01.jpg'
    }

    It 'scrolls a tall page into several segments' {
        $script:Tall.Status | Should -Be 'OK'
        $script:Tall.ScrollArea | Should -Be 'the page'
        $script:Tall.Captures.Count | Should -BeGreaterOrEqual 2
        $script:Tall.Captures[-1].SegmentCount | Should -Be $script:Tall.Captures.Count
    }
}

Describe 'Page actions (one page at a time, desktop functions mocked)' -Tag 'Integration' {
    # Each page runs through Invoke-CaptureItem. The screenshot is mocked, so the mock
    # records the page's state (a JavaScript probe) at the moment each image is taken.
    BeforeAll {
        Connect-TestPage
        Mock Set-EdgeForeground { $null }
        $global:VouchShots = [System.Collections.Generic.List[string]]::new()
        $global:VouchShotProbe = ''
        $global:VouchShotCalls = 0
        $global:VouchFailShots = @()
        Mock Get-ScreenCapture {
            $global:VouchShotCalls++
            if ($global:VouchFailShots -contains $global:VouchShotCalls) { throw 'Simulated screen capture failure' }
            $state = ''
            if ($global:VouchShotProbe) { $state = [string](Invoke-CdpEval -Expression $global:VouchShotProbe -TimeoutSec 10) }
            $global:VouchShots.Add($state)
            , [byte[]](0xFF, 0xD8, 0xFF, 0xD9)
        }

        function Invoke-TestPage {
            param(
                [Parameter(Mandatory)][string]$Url,
                [Parameter(Mandatory)][object[]]$Actions,
                [string]$Probe = 'document.title',
                [string]$WaitFor = '',
                [int]$TimeoutSec = 10,
                # Screenshot calls (1, 2, ...) that throw.
                [int[]]$FailShots = @()
            )
            $global:VouchShots.Clear()
            $global:VouchShotCalls = 0
            $global:VouchFailShots = $FailShots
            $global:VouchShotProbe = $Probe
            $definition = ConvertTo-CaptureDefinition -Index 7 -Page ([ordered]@{ name = 'Actions'; url = $Url; actions = $Actions })
            $run = Resolve-RunSettings -BoundParameters @{} -Config $null -Defaults @{
                NavigationTimeoutSec = $TimeoutSec; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10
            }
            $config = Get-DefaultVouchConfig
            $config['defaults']['waitFor'] = $WaitFor
            $settings = Get-PageSettings -Settings $run -Definition $definition -Config $config
            $context = @{
                RunId = [guid]::NewGuid().ToString(); Format = 'jpeg'; Quality = 85; Extension = 'jpg'
                SaveImages = $false; ImagesDir = ''; Screen = '1x1'
            }
            $item = Invoke-CaptureItem -Definition $definition -Settings $settings -CaptureContext $context 6>$null
            return [pscustomobject]@{ Item = $item; Shots = @($global:VouchShots) }
        }
        function New-Capture([string]$Label = '', [string]$Mode = 'none', [string]$Selector = '') {
            [ordered]@{ type = 'capture'; label = $Label; scroll = [ordered]@{ mode = $Mode; selector = $Selector } }
        }
    }

    AfterAll {
        Close-CdpSocket
        Remove-Variable -Name VouchShots, VouchShotProbe, VouchShotCalls, VouchFailShots -Scope Global -ErrorAction SilentlyContinue
    }

    It 'takes one capture set per tab: click A, capture, click B, capture' {
        $result = Invoke-TestPage -Url "$Web/tabs" -Actions @(
            [ordered]@{ type = 'click'; selector = '#t-general' }
            (New-Capture 'General tab')
            [ordered]@{ type = 'clickText'; text = 'Audit Log' }
            (New-Capture 'Audit tab'))
        $item = $result.Item
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        @($item.Captures.FileName) | Should -Be @('007_Actions_seg01.jpg', '007_Actions_c02_seg01.jpg')
        @($item.Captures.CaptureNumber) | Should -Be @(1, 2)
        @($item.Captures.Label) | Should -Be @('General tab', 'Audit tab')
        $result.Shots | Should -Be @('General', 'Audit Log')
        @($item.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) |
            Should -Be @('click:#t-general|True', 'capture:General tab|True', 'clicktext:Audit Log|True', 'capture:Audit tab|True')
        $item.StepsText | Should -Be 'click:#t-general; capture:General tab; clicktext:Audit Log; capture:Audit tab'
    }

    It 'records a failed action once, runs the rest and still takes every capture' {
        $result = Invoke-TestPage -Url "$Web/tabs" -Actions @(
            [ordered]@{ type = 'click'; selector = '#missing' }
            (New-Capture 'first')
            [ordered]@{ type = 'clickText'; text = 'No such tab' }
            [ordered]@{ type = 'click'; selector = '#t-logs' }
            (New-Capture 'second'))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like 'Completed with errors*' }) | Should -Be @('Completed with errors: 2 of 3 step(s) failed.')
        @($item.StepLog.Ok) | Should -Be @($false, $true, $false, $true, $true)
        $result.Shots | Should -Be @('Tabs', 'Logs')
    }

    It 'a capture that takes no screenshot fails the page, and the next actions still run' {
        $result = Invoke-TestPage -Url "$Web/tabs" -FailShots 1 -Actions @(
            (New-Capture 'General tab')
            [ordered]@{ type = 'click'; selector = '#t-logs' }
            (New-Capture 'Logs tab'))
        $item = $result.Item
        $item.Status | Should -Be 'FAILED'
        @($item.Details | Where-Object { $_ -like 'Capture 1 (General tab) failed and took no screenshot: *Simulated*' }).Count |
            Should -Be 1 -Because ($item.Details -join ' | ')
        ($item.Details -join ' ') | Should -Not -Match 'Unhandled error'
        @($item.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) |
            Should -Be @('capture:General tab|False', 'click:#t-logs|True', 'capture:Logs tab|True')
        @($item.Captures.FileName) | Should -Be @('007_Actions_c02_seg01.jpg')
        $result.Shots | Should -Be @('Logs')
    }

    It 'a capture that stops after some segments is a warning, and the next capture is complete' {
        $result = Invoke-TestPage -Url "$Web/tworegions" -FailShots 2 -Probe "document.getElementById('left').scrollTop + '|' + document.getElementById('right').scrollTop" -Actions @(
            (New-Capture 'Left' 'area' '#left')
            (New-Capture 'Right' 'area' '#right'))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like 'Capture 1 (Left) stopped after 1 screenshot(s)*Simulated*' }).Count |
            Should -Be 1 -Because ($item.Details -join ' | ')
        $item.StepLog[0].Ok | Should -BeFalse
        $item.StepLog[1].Ok | Should -BeTrue
        @($item.Captures | Where-Object CaptureNumber -eq 1).Count | Should -Be 1
        $second = @($item.Captures | Where-Object CaptureNumber -eq 2)
        $second.Count | Should -BeGreaterOrEqual 2
        $second[-1].SegmentIndex | Should -Be $second[-1].SegmentCount
        # The second set starts with the left area back at its top.
        $result.Shots[1] | Should -Match '^0\|0$'
    }

    It 'the one final capture of a CSV-style page still ends the page as before when it fails' {
        $result = Invoke-TestPage -Url "$Web/tabs" -FailShots 1 -Actions @(
            [ordered]@{ type = 'click'; selector = '#t-logs' }
            (New-Capture))
        $item = $result.Item
        $item.Status | Should -Be 'FAILED'
        ($item.Details -join ' ') | Should -Match 'Unhandled error while capturing this item: Simulated'
        @($item.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) | Should -Be @('click:#t-logs|True')
        $item.Captures.Count | Should -Be 0
    }

    It 'scrolls each named area in turn and does not report the other as missed' {
        $result = Invoke-TestPage -Url "$Web/tworegions" -Probe "document.getElementById('left').scrollTop + '|' + document.getElementById('right').scrollTop" -Actions @(
            (New-Capture 'Left' 'area' '#left')
            (New-Capture 'Right' 'area' '#right'))
        $item = $result.Item
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        ($item.Details -join ' ') | Should -Not -Match 'Another scrolling area'
        $item.ScrollArea | Should -Be 'div#left; div#right'
        $first = @($item.Captures | Where-Object CaptureNumber -eq 1)
        $second = @($item.Captures | Where-Object CaptureNumber -eq 2)
        $first.Count | Should -BeGreaterOrEqual 2
        $second.Count | Should -Be $first.Count
        # Second segment of each set: only its own area has moved.
        $result.Shots[1] | Should -Match '^[1-9]\d*\|0$'
        $result.Shots[$first.Count + 1] | Should -Match '^0\|[1-9]\d*$'
    }

    It 'still reports an area the page never captures' {
        $result = Invoke-TestPage -Url "$Web/tworegions" -Actions @((New-Capture 'Left' 'area' '#left'))
        $result.Item.Status | Should -Be 'WARNING'
        ($result.Item.Details -join ' ') | Should -Match 'Another scrolling area \(div#right\)'
    }

    It 'scrolls a frame named by its frame element' {
        $result = Invoke-TestPage -Url "$Web/framepage?rows=30" -Probe "document.getElementById('content').contentWindow.scrollY" -Actions @(
            (New-Capture 'Frame' 'area' '#content'))
        $item = $result.Item
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        $item.ScrollArea | Should -BeLike 'the frame *framecontent*'
        $item.Captures.Count | Should -BeGreaterOrEqual 2
        [int]$result.Shots[1] | Should -BeGreaterThan 0
    }

    It 'falls back to the automatic search when the area <Case>, and says so' -ForEach @(
        @{ Case = 'matches nothing'; Selector = '#nope'; Pattern = "*'#nope' of the capture 'Panel' matches no element*div#main*" }
        @{ Case = 'does not scroll'; Selector = 'header'; Pattern = "*'header' of the capture 'Panel' does not scroll*div#main*" }
    ) {
        $result = Invoke-TestPage -Url "$Web/innerscroll?rows=20" -Actions @((New-Capture 'Panel' 'area' $Selector))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like $Pattern }).Count | Should -Be 1 -Because ($item.Details -join ' | ')
        $item.ScrollArea | Should -Be 'div#main'
        $item.Captures.Count | Should -BeGreaterOrEqual 2
    }

    It 'scroll mode page scrolls the window even when a panel holds more' {
        $result = Invoke-TestPage -Url "$Web/bigpanel" -Probe "window.scrollY + '|' + document.getElementById('panel').scrollTop" -Actions @(
            (New-Capture 'Whole page' 'page'))
        $item = $result.Item
        $item.ScrollArea | Should -Be 'the page'
        $item.Captures.Count | Should -BeGreaterOrEqual 2
        $result.Shots[1] | Should -Match '^[1-9]\d*\|0$'
        ($item.Details -join ' ') | Should -Match 'Another scrolling area \(div#panel\)'
    }

    It 'scroll mode page takes one screen of a page whose window does not scroll' {
        $result = Invoke-TestPage -Url "$Web/innerscroll?rows=20" -Actions @((New-Capture '' 'page'))
        $result.Item.ScrollArea | Should -BeLike 'nothing to scroll*'
        $result.Item.Captures.Count | Should -Be 1
        ($result.Item.Details -join ' ') | Should -Match 'Another scrolling area \(div#main\)'
    }

    It 'a waitFor action waits until the element is visible' {
        $result = Invoke-TestPage -Url "$Web/delayed?ms=1500" -Probe "getComputedStyle(document.getElementById('late')).display" -Actions @(
            [ordered]@{ type = 'waitFor'; selector = '#late'; timeoutSec = 10 }
            (New-Capture))
        $result.Item.Status | Should -Be 'OK' -Because ($result.Item.Details -join ' | ')
        $result.Item.StepLog[0].Ok | Should -BeTrue
        $result.Shots | Should -Be @('block')
    }

    It 'a waitFor action that times out is a warning, and the page is still captured' {
        $result = Invoke-TestPage -Url "$Web/delayed?ms=8000" -Probe "getComputedStyle(document.getElementById('late')).display" -Actions @(
            [ordered]@{ type = 'waitFor'; selector = '#late'; timeoutSec = 1 }
            (New-Capture))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        $item.StepLog[0].Ok | Should -BeFalse
        $item.StepLog[0].Message | Should -BeLike "*'#late' within 1 second(s)*"
        $result.Shots | Should -Be @('none')
    }

    It 'without a wait-for the page is captured before the element shows' {
        $result = Invoke-TestPage -Url "$Web/delayed?ms=1500" -Probe "getComputedStyle(document.getElementById('late')).display" -Actions @((New-Capture))
        $result.Shots | Should -Be @('none')
    }

    It 'the page''s wait-for setting holds every action until the element shows' {
        $result = Invoke-TestPage -Url "$Web/delayed?ms=1500" -WaitFor '#late' -Probe "getComputedStyle(document.getElementById('late')).display" -Actions @((New-Capture))
        $result.Item.Status | Should -Be 'OK' -Because ($result.Item.Details -join ' | ')
        $result.Shots | Should -Be @('block')
    }

    It 'the page''s wait-for setting warns when the element never shows' {
        $result = Invoke-TestPage -Url "$Web/delayed?ms=60000" -WaitFor '#late' -TimeoutSec 2 -Probe "getComputedStyle(document.getElementById('late')).display" -Actions @((New-Capture))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        ($item.Details -join ' ') | Should -Match "did not show '#late' within 2 seconds"
        $item.Captures.Count | Should -Be 1
    }

    It 'skips a pause with a warning and runs the rest of the page' {
        $result = Invoke-TestPage -Url "$Web/tabs" -Actions @(
            [ordered]@{ type = 'pause'; message = 'Sign in' }
            [ordered]@{ type = 'clickText'; text = 'General' }
            (New-Capture))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        ($item.Details -join ' ') | Should -Match 'pause is not available yet'
        @($item.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) | Should -Be @('pause:Sign in|True', 'clicktext:General|True')
        $item.StepLog[0].Message | Should -BeLike '*not available yet*'
        $result.Shots | Should -Be @('General')
    }
}

Describe 'Invoke-Main with several captures per page (desktop functions mocked)' -Tag 'Integration' {
    BeforeAll {
        Close-CdpSocket
        $script:RealNewHtmlReportForMulti = ${function:New-HtmlReport}
        $global:VouchMulti = @{}
        $config = Get-DefaultVouchConfig
        $config['browser']['profileDir'] = $script:ProfileDir
        $config['browser']['debugPort'] = $script:CdpPort
        $config['defaults']['navigationTimeoutSec'] = 10
        $config['defaults']['settleSeconds'] = 0.1
        $config['defaults']['scrollSettleSeconds'] = 0.1
        $config['output']['dir'] = 'out'
        $config['output']['reportName'] = 'multi.html'
        $config['output']['saveImages'] = $true
        $config['output']['jsonSummary'] = $true
        $config['pages'].Add([ordered]@{ name = 'Plain'; url = "$Web/ok" })
        $config['pages'].Add([ordered]@{ name = 'Tabs'; url = "$Web/tabs"; actions = @(
                [ordered]@{ type = 'click'; selector = '#t-general' }
                [ordered]@{ type = 'capture'; label = 'General' }
                [ordered]@{ type = 'click'; selector = '#t-logs' }
                [ordered]@{ type = 'capture'; label = 'Logs' }) })
        $config['pages'].Add([ordered]@{ name = 'Regions'; url = "$Web/tworegions"; actions = @(
                [ordered]@{ type = 'capture'; label = 'Left'; scroll = [ordered]@{ mode = 'area'; selector = '#left' } }
                [ordered]@{ type = 'capture'; label = 'Right'; scroll = [ordered]@{ mode = 'area'; selector = '#right' } }) })
        $folder = Join-Path -Path $TestDrive -ChildPath 'multi'
        [void](New-Item -ItemType Directory -Path $folder)
        $path = Join-Path -Path $folder -ChildPath 'multi.json'
        [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $script:MultiReport = Join-Path -Path $folder -ChildPath 'out\multi.html'

        Mock Set-EdgeForeground { $null }
        Mock Get-ScreenCapture {
            $bitmap = [System.Drawing.Bitmap]::new(16, 10)
            try {
                if ($Metadata) { Set-JpegMetadata -Image $bitmap -Metadata $Metadata }
                $stream = [System.IO.MemoryStream]::new()
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                , $stream.ToArray()
            }
            finally { $bitmap.Dispose() }
        }
        Mock New-HtmlReport {
            $global:VouchMulti.Items = $Items
            & $script:RealNewHtmlReportForMulti -Items $Items -Run $Run
        }
        Invoke-Main -BoundParameters @{ ConfigPath = $path } 6>$null
        $script:MultiExit = $script:ExitCode
    }

    AfterAll { Remove-Variable -Name VouchMulti -Scope Global -ErrorAction SilentlyContinue }

    It 'names the extra capture sets _c02 and keeps the first set''s names' {
        $script:MultiExit | Should -Be 0
        $tabs = @($global:VouchMulti.Items | Where-Object Name -eq 'Tabs')[0]
        @($tabs.Captures.FileName) | Should -Be @('002_Tabs_seg01.jpg', '002_Tabs_c02_seg01.jpg')
        $plain = @($global:VouchMulti.Items | Where-Object Name -eq 'Plain')[0]
        @($plain.Captures.FileName) | Should -Be @('001_Plain_seg01.jpg')
        $images = Join-Path (Split-Path $script:MultiReport) 'images\multi'
        Join-Path $images '002_Tabs_c02_seg01.jpg' | Should -Exist
        Join-Path $images '003_Regions_c02_seg02.jpg' | Should -Exist
    }

    It 'produces a report that -Verify accepts, listing every image in order with its label' {
        $results = @(Test-ReportIntegrity -Path $script:MultiReport)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        $html = [System.IO.File]::ReadAllText($script:MultiReport)
        $files = @([regex]::Matches($html, 'data-file="([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
        $files[1..2] | Should -Be @('002_Tabs_seg01.jpg', '002_Tabs_c02_seg01.jpg')
        $html | Should -Match '<strong>Capture 2: Logs</strong>'
    }

    It 'lists the capture number and label of each image in the JSON summary' {
        $summary = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($script:MultiReport, '.json')) -Raw | ConvertFrom-Json
        $tabs = @($summary.Items | Where-Object Name -eq 'Tabs')[0]
        @($tabs.Captures.Label) | Should -Be @('General', 'Logs')
        @($tabs.Captures.CaptureNumber) | Should -Be @(1, 2)
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

    It 'never attaches to an edge:// tab listed first, and closes it' {
        # A fresh profile on a work-joined PC lists edge://sync-confirmation-dialog/ first.
        $port = Get-FreeTcpPort
        [void](Start-HeadlessEdge -Port $port -ProfileDir $lifecycleProfile)
        [void](Get-CdpPageTarget -Port $port -WaitSeconds 10)
        [void](Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$port/json/new?$Web/ok" -NoProxy)
        [void](Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$port/json/new?edge://version" -NoProxy)
        @(Get-DevToolsTargetList -Port $port | Where-Object type -eq 'page')[0].url | Should -BeLike 'edge://*'

        $target = Get-CdpPageTarget -Port $port -WaitSeconds 10
        $target.url | Should -Be "$Web/ok"

        Close-OtherPageTargets -Port $port -KeepId $target.id
        Start-Sleep -Milliseconds 500
        $pages = @(Get-DevToolsTargetList -Port $port | Where-Object type -eq 'page')
        $pages.Count | Should -Be 1
        $pages[0].id | Should -Be $target.id
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
