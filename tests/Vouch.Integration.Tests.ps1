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

        It 'gives each reason a named area cannot be used its own code (<Case>)' -ForEach @(
            @{ Case = 'not a CSS selector'; Page = 'innerscroll?rows=20'; Selector = 'div['; Fallback = 'invalid' }
            @{ Case = 'matches nothing'; Page = 'innerscroll?rows=20'; Selector = '#nope'; Fallback = 'notfound' }
            @{ Case = 'a frame from another site'; Page = 'xframe'; Selector = 'iframe'; Fallback = 'crossorigin' }
            @{ Case = 'does not scroll'; Page = 'innerscroll?rows=20'; Selector = 'header'; Fallback = 'notscrollable' }
        ) {
            $url = if ($Page -eq 'xframe') { "$Web/xframe?to=http://localhost:$($script:OtherOriginPort)/tall" } else { "$Web/$Page" }
            [void](Open-TestPage $url)
            (Invoke-CdpEval -Expression (Get-ScrollTargetScript -Mode area -Selector $Selector)).fallback | Should -Be $Fallback
        }

        It 'does not take a named area with overflow-y: clip, which script cannot scroll' {
            [void](Open-TestPage "$Web/innerscroll?rows=20")
            [void](Invoke-CdpEval -Expression "document.getElementById('main').style.overflowY = 'hidden'")
            $hidden = Invoke-CdpEval -Expression (Get-ScrollTargetScript -Mode area -Selector '#main')
            $hidden.fallback | Should -Be '' -Because 'overflow hidden still scrolls by script'
            $hidden.description | Should -Be 'div#main'
            [void](Invoke-CdpEval -Expression "document.getElementById('main').style.overflowY = 'clip'")
            (Invoke-CdpEval -Expression (Get-ScrollTargetScript -Mode area -Selector '#main')).fallback | Should -Be 'notscrollable'
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
            'Status', 'HttpStatus', 'Details', 'StepLog', 'Captures', 'CaptureArea', 'ZoomPercent')
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
        @{ Case = 'is not a CSS selector'; Selector = 'div['; Pattern = "*'div?' of the capture 'Panel' is not a CSS selector the browser understands*div#main*" }
    ) {
        $result = Invoke-TestPage -Url "$Web/innerscroll?rows=20" -Actions @((New-Capture 'Panel' 'area' $Selector))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like $Pattern }).Count | Should -Be 1 -Because ($item.Details -join ' | ')
        $item.ScrollArea | Should -Be 'div#main'
        $item.Captures.Count | Should -BeGreaterOrEqual 2
    }

    It 'says a named area that is a frame from another site cannot be scrolled' {
        $result = Invoke-TestPage -Url "$Web/xframe?to=http://localhost:$($script:OtherOriginPort)/tall" -Actions @((New-Capture 'Frame' 'area' 'iframe'))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like "*'iframe' of the capture 'Frame' is a frame from another site*" }).Count |
            Should -Be 1 -Because ($item.Details -join ' | ')
        ($item.Details -join ' ') | Should -Not -Match 'does not scroll'
    }

    It 'takes "as": "single" as segments for the screen area and says so once, without a warning' {
        $single = [ordered]@{ type = 'capture'; label = 'One'; scroll = [ordered]@{ mode = 'page'; as = 'single' } }
        $result = Invoke-TestPage -Url "$Web/tall?px=3000" -Actions @($single, $single)
        $item = $result.Item
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        @($item.Details | Where-Object { $_ -like '*only possible with the page capture area*screen-sized segments*' }).Count | Should -Be 1
        @($item.Captures | Where-Object CaptureNumber -eq 1).Count | Should -BeGreaterOrEqual 2
        @($item.Captures.CaptureArea | Sort-Object -Unique) | Should -Be @('screen')
    }

    It 'does not wait for the page''s wait-for element on a sign-in page' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-TestPage -Url "$Web/protected" -WaitFor '#late' -TimeoutSec 6 -Actions @((New-Capture))
        $watch.Stop()
        $item = $result.Item
        ($item.Details -join ' ') | Should -Match 'sign-in page'
        ($item.Details -join ' ') | Should -Not -Match "did not show '#late'"
        $item.Captures.Count | Should -Be 1
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5 -Because 'the 6 s wait-for timeout must not be spent'
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

Describe 'Page zoom (headless Edge)' -Tag 'Integration' {
    BeforeAll {
        Connect-TestPage
        [void](Open-TestPage "$Web/ok")
        Clear-PageZoom
        $script:BaseSize = Invoke-CdpEval -Expression '({ width: innerWidth, height: innerHeight })'
    }
    AfterAll {
        try { Clear-PageZoom } catch { Write-Verbose 'no connection' }
        Close-CdpSocket
    }

    It 'zooms to <Percent>% as the formula predicts, keeps it across a navigation and a reconnect, and clears it' -ForEach @(
        @{ Percent = 50 }, @{ Percent = 150 }
    ) {
        $want = Get-ZoomDeviceMetrics -Width $script:BaseSize.width -Height $script:BaseSize.height -ZoomPercent $Percent
        Set-PageZoom -Percent $Percent
        $script:PageZoomPercent | Should -Be $Percent
        Invoke-CdpEval -Expression 'innerWidth' | Should -Be $want.width
        Invoke-CdpEval -Expression 'innerHeight' | Should -Be $want.height

        [void](Open-TestPage "$Web/tall?px=3000")
        Invoke-CdpEval -Expression 'innerWidth' | Should -Be $want.width -Because 'the zoom survives a navigation'

        # A timed-out command aborts the socket for good; the next one reconnects, and the
        # zoom (which belonged to the old connection) must be set again.
        { Invoke-CdpEval -Expression 'new Promise(r => setTimeout(r, 5000))' -TimeoutSec 2 } | Should -Throw
        Invoke-CdpEval -Expression 'innerWidth' | Should -Be $want.width -Because 'the zoom survives a reconnect'
        $script:PageZoomPercent | Should -Be $Percent

        Clear-PageZoom
        Invoke-CdpEval -Expression 'innerWidth' | Should -Be $script:BaseSize.width
        $script:PageZoomPercent | Should -Be 100
    }

    It 'records 100% and stops scaling page images after a reconnect loses the zoom half-way, and warns' {
        $script:RealSetPageZoomMid = ${function:Set-PageZoom}
        $script:RealGetPageCaptureMid = ${function:Get-PageCapture}
        $global:VouchMid = @{ Fail = $false; Calls = 0; Zooms = [System.Collections.Generic.List[int]]::new() }
        # After the first segment the socket dies (the override dies with it) and setting
        # the zoom again on the new connection fails.
        Mock Set-PageZoom {
            if ($global:VouchMid.Fail) { $script:PageZoomPercent = 100; throw 'Simulated: the override was refused' }
            & $script:RealSetPageZoomMid -Percent $Percent
        }
        Mock Get-PageCapture {
            $global:VouchMid.Calls++
            $global:VouchMid.Zooms.Add($ZoomPercent)
            $bytes = & $script:RealGetPageCaptureMid -Format $Format -Quality $Quality -ZoomPercent $ZoomPercent -Clip $Clip
            if ($global:VouchMid.Calls -eq 1) { $global:VouchMid.Fail = $true; $script:CdpSocket.Abort() }
            , $bytes
        }
        $context = @{ RunId = [guid]::NewGuid().ToString(); Format = 'jpeg'; Quality = 85; Extension = 'jpg'; SaveImages = $false; ImagesDir = ''; Screen = '1x1' }
        $run = Resolve-RunSettings -BoundParameters @{} -Config $null -Defaults @{
            NavigationTimeoutSec = 10; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10 }
        $definition = ConvertTo-CaptureDefinition -Index 1 -Page ([ordered]@{ name = 'Lost zoom'; url = "$Web/tall?px=3000"
                overrides = [ordered]@{ zoomPercent = 150; captureArea = 'page' }
                actions = @([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'page' } }) })
        $settings = Get-PageSettings -Settings $run -Definition $definition -Config (Get-DefaultVouchConfig)
        $item = Invoke-CaptureItem -Definition $definition -Settings $settings -CaptureContext $context 6>$null

        $item.Captures.Count | Should -BeGreaterOrEqual 3
        $global:VouchMid.Zooms[0] | Should -Be 150
        @($global:VouchMid.Zooms | Select-Object -Skip 1 | Sort-Object -Unique) | Should -Be @(100) -Because 'clip.scale follows the zoom the page shows'
        $item.Captures[0].ZoomPercent | Should -Be 150
        @($item.Captures | Select-Object -Skip 1 | ForEach-Object ZoomPercent | Sort-Object -Unique) | Should -Be @(100)
        $first = [Convert]::FromBase64String($item.Captures[0].Base64)
        $later = [Convert]::FromBase64String($item.Captures[1].Base64)
        (Get-ImageMetadata -Bytes $first).ZoomPercent | Should -Be 150
        (Get-ImageMetadata -Bytes $later).ZoomPercent | Should -Be 100
        (Get-ImagePixelSize -Bytes $later).Width | Should -Be ($script:BaseSize.width - 15) -Because 'an unscaled page image is the page width without the scroll bar'
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like '*page zoom of 150% could not be set again; the images taken after that show the page at 100%*' }).Count |
            Should -Be 1 -Because ($item.Details -join ' | ')
        Get-CaptureAreaText -Area page -ZoomPercent 150 -Captures @($item.Captures) | Should -Match 'page zoom 100% for \d+ of \d+ image\(s\), 150% for 1 of'
        $script:PageZoomPercent | Should -Be 100
        Invoke-CdpEval -Expression 'innerWidth' | Should -Be $script:BaseSize.width
        Remove-Variable -Name VouchMid -Scope Global
    }

    It 'takes the zoom off for a 100% page that follows a zoomed one, and zooms only the zoomed page' {
        Mock Set-EdgeForeground { $null }
        $global:VouchZoomShots = [System.Collections.Generic.List[int]]::new()
        Mock Get-ScreenCapture {
            $global:VouchZoomShots.Add([int](Invoke-CdpEval -Expression 'innerWidth' -TimeoutSec 10))
            , [byte[]](0xFF, 0xD8, 0xFF, 0xD9)
        }
        Mock Set-EdgeWindowMaximized { }
        $context = @{ RunId = [guid]::NewGuid().ToString(); Format = 'jpeg'; Quality = 85; Extension = 'jpg'; SaveImages = $false; ImagesDir = ''; Screen = '1x1' }
        $run = Resolve-RunSettings -BoundParameters @{} -Config $null -Defaults @{
            NavigationTimeoutSec = 10; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10 }
        $items = foreach ($zoom in 150, 100) {
            $definition = ConvertTo-CaptureDefinition -Index 1 -Page ([ordered]@{ name = "Zoom $zoom"; url = "$Web/ok"; overrides = [ordered]@{ zoomPercent = $zoom } })
            $settings = Get-PageSettings -Settings $run -Definition $definition -Config (Get-DefaultVouchConfig)
            Invoke-CaptureItem -Definition $definition -Settings $settings -CaptureContext $context 6>$null
        }
        $expected = (Get-ZoomDeviceMetrics -Width $script:BaseSize.width -Height $script:BaseSize.height -ZoomPercent 150).width
        @($global:VouchZoomShots) | Should -Be @($expected, $script:BaseSize.width)
        @($items.ZoomPercent) | Should -Be @(150, 100)
        @($items | ForEach-Object { $_.Captures[0].ZoomPercent }) | Should -Be @(150, 100)
        @($items.Status) | Should -Be @('OK', 'OK')
        # The window is sized before the zoom is worked out, for the zoomed screen page only.
        Should -Invoke Set-EdgeWindowMaximized -Times 1 -Exactly
        Remove-Variable -Name VouchZoomShots -Scope Global
    }
}

Describe 'Capture area: page content, end to end (nothing mocked but the screen path)' -Tag 'Integration' {
    # A real configuration run in the headless Edge: the page images are taken by the
    # browser, so this checks the real images, their embedded metadata and -Verify.
    BeforeAll {
        Close-CdpSocket
        $script:RealNewHtmlReportForArea = ${function:New-HtmlReport}
        $script:RealClearPageZoom = ${function:Clear-PageZoom}
        $global:VouchArea = @{ ScreenShots = 0; Foreground = 0; Maximize = 0; Clears = 0 }
        $config = Get-DefaultVouchConfig
        $config['browser']['profileDir'] = $script:ProfileDir
        $config['browser']['debugPort'] = $script:CdpPort
        $config['defaults']['captureArea'] = 'page'
        $config['defaults']['navigationTimeoutSec'] = 10
        $config['defaults']['settleSeconds'] = 0.1
        $config['defaults']['scrollSettleSeconds'] = 0.1
        $config['output']['dir'] = 'out'
        $config['output']['reportName'] = 'area.html'
        $config['output']['saveImages'] = $true
        $config['output']['jsonSummary'] = $true
        $single = { param($Mode) [ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = $Mode; as = 'single' } } }
        $config['pages'].Add([ordered]@{ name = 'Plain'; url = "$Web/ok" })
        $config['pages'].Add([ordered]@{ name = 'Tall single'; url = "$Web/tall?px=5000"; actions = @((& $single 'page')) })
        $config['pages'].Add([ordered]@{ name = 'Too tall'; url = "$Web/tall?px=17000"; overrides = [ordered]@{ maxScrollSegments = 3 }; actions = @((& $single 'auto')) })
        $config['pages'].Add([ordered]@{ name = 'Inner single'; url = "$Web/innerscroll?rows=20"; actions = @((& $single 'auto')) })
        $config['pages'].Add([ordered]@{ name = 'Inner segments'; url = "$Web/innerscroll?rows=20"
                actions = @([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'auto' } }) })
        $config['pages'].Add([ordered]@{ name = 'Zoomed'; url = "$Web/tall?px=3000"; overrides = [ordered]@{ zoomPercent = 150 }; actions = @((& $single 'page')) })
        $config['pages'].Add([ordered]@{ name = 'After zoom'; url = "$Web/ok" })
        $config['pages'].Add([ordered]@{ name = 'Screen page'; url = "$Web/ok"; overrides = [ordered]@{ captureArea = 'screen' } })
        $folder = Join-Path -Path $TestDrive -ChildPath 'area'
        [void](New-Item -ItemType Directory -Path $folder)
        $path = Join-Path -Path $folder -ChildPath 'area.json'
        [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $script:AreaReport = Join-Path -Path $folder -ChildPath 'out\area.html'
        $script:AreaImages = Join-Path -Path $folder -ChildPath 'out\images\area'

        Mock Set-EdgeForeground { $global:VouchArea.Foreground++; $null }
        Mock Set-EdgeWindowMaximized { $global:VouchArea.Maximize++ }
        Mock Get-ScreenCapture {
            $global:VouchArea.ScreenShots++
            $bitmap = [System.Drawing.Bitmap]::new(16, 10)
            try {
                if ($Metadata) { Set-JpegMetadata -Image $bitmap -Metadata $Metadata }
                $stream = [System.IO.MemoryStream]::new()
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                , $stream.ToArray()
            }
            finally { $bitmap.Dispose() }
        }
        Mock Clear-PageZoom { $global:VouchArea.Clears++; & $script:RealClearPageZoom }
        Mock New-HtmlReport {
            $global:VouchArea.Items = $Items
            & $script:RealNewHtmlReportForArea -Items $Items -Run $Run
        }
        Invoke-Main -BoundParameters @{ ConfigPath = $path } 6>$null
        $script:AreaExit = $script:ExitCode
        $script:AreaItems = @{}
        foreach ($i in $global:VouchArea.Items) { $script:AreaItems[$i.Name] = $i }
        $script:AreaHtml = [System.IO.File]::ReadAllText($script:AreaReport)

        function Get-SavedImage([object]$Capture) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:AreaImages $Capture.FileName))
            $size = Get-ImagePixelSize -Bytes $bytes
            [pscustomobject]@{ Bytes = $bytes; Width = $size.Width; Height = $size.Height; Metadata = (Get-ImageMetadata -Bytes $bytes) }
        }
    }

    AfterAll { Remove-Variable -Name VouchArea -Scope Global -ErrorAction SilentlyContinue }

    It 'produces a report that -Verify accepts, with real page images and their metadata' {
        $script:AreaExit | Should -Be 0
        $results = @(Test-ReportIntegrity -Path $script:AreaReport)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        $total = ($global:VouchArea.Items | ForEach-Object { $_.Captures.Count } | Measure-Object -Sum).Sum
        @($results | Where-Object Check -like 'Metadata *').Count | Should -Be $total
        @($results | Where-Object Check -like 'File *').Count | Should -Be $total
    }

    It 'takes page images without the screen, the window or the foreground' {
        $global:VouchArea.ScreenShots | Should -Be 1 -Because 'only the page set to the screen area grabs the screen'
        $global:VouchArea.Foreground | Should -Be 1
        $global:VouchArea.Maximize | Should -Be 0 -Because 'a zoomed page-content capture does not need the window sized'
        $script:AreaItems['Screen page'].Captures[0].CaptureArea | Should -Be 'screen'
    }

    It 'stamps every page image with its area, an honest description, the page URL and the capture time' {
        foreach ($item in @($global:VouchArea.Items | Where-Object CaptureArea -eq 'page')) {
            foreach ($capture in $item.Captures) {
                $image = Get-SavedImage $capture
                $capture.CaptureArea | Should -Be 'page' -Because $item.Name
                $image.Metadata.CaptureArea | Should -Be 'page' -Because $item.Name
                $image.Metadata.Screen | Should -Be "$($image.Width)x$($image.Height) image of the page content only (no browser window, taskbar or clock)"
                $capture.Url | Should -BeLike "$Web/*" -Because $item.Name
                $image.Metadata.PageUrl | Should -Be $capture.Url
                $image.Metadata.CapturedAt | Should -Be $capture.CapturedAt
                $image.Bytes[0..1] | Should -Be @(0xFF, 0xD8)
                # The report shows the URL and time under each image: the image itself has no address bar or clock.
                $script:AreaHtml | Should -Match ([regex]::Escape("Captured $($capture.Timestamp)"))
            }
        }
        $script:AreaHtml | Should -Match '<dt>Capture area</dt><dd>Page content only'
        $script:AreaHtml | Should -Match 'page zoom 150%'
        $script:AreaHtml | Should -Match '<dt>Capture area</dt><dd>Full screen, including the taskbar clock</dd>'
    }

    It 'captures the window''s view for a page that does not scroll' {
        $plain = Get-SavedImage $script:AreaItems['Plain'].Captures[0]
        $plain.Width | Should -BeGreaterThan 800
        $plain.Height | Should -BeGreaterThan 400
        $script:AreaItems['Plain'].Status | Should -Be 'OK'
    }

    It 'takes one tall image of the whole document as "single"' {
        $item = $script:AreaItems['Tall single']
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        $item.Captures.Count | Should -Be 1
        $image = Get-SavedImage $item.Captures[0]
        $image.Height | Should -Be 5016 -Because 'the 5000 px div plus the 8 px body margin above and below'
        $image.Width | Should -BeGreaterThan 800
    }

    It 'falls back to segments with a warning when one image would be too tall' {
        $item = $script:AreaItems['Too tall']
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like 'The page is too tall for one image (17016 pixels*16,384)*segments*' }).Count |
            Should -Be 1 -Because ($item.Details -join ' | ')
        $item.Captures.Count | Should -Be 3
        $item.Captures[0].SegmentCount | Should -Be 3
    }

    It 'falls back to segments with a warning for "single" on an inner scrolling area' {
        $item = $script:AreaItems['Inner single']
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like '*only possible when the page itself scrolls; here div#main scrolls*segments*' }).Count |
            Should -Be 1 -Because ($item.Details -join ' | ')
        $item.Captures.Count | Should -BeGreaterOrEqual 2
    }

    It 'takes page images in segments of an inner scrolling area, like screen captures' {
        $item = $script:AreaItems['Inner segments']
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        $item.ScrollArea | Should -Be 'div#main'
        # 2020 px of rows in a panel of the window's height less the 60 px header.
        $item.Captures.Count | Should -BeGreaterOrEqual 3
        $item.Captures.Count | Should -BeLessOrEqual 5
        $item.Captures[-1].SegmentIndex | Should -Be $item.Captures[-1].SegmentCount
        @($item.Captures.Sha256 | Sort-Object -Unique).Count | Should -Be $item.Captures.Count -Because 'each segment shows other rows'
    }

    It 'scales a zoomed page image to its on-screen size, and the next page is back at 100%' {
        $zoomed = $script:AreaItems['Zoomed']
        $zoomed.Status | Should -Be 'OK' -Because ($zoomed.Details -join ' | ')
        $zoomed.ZoomPercent | Should -Be 150
        $zoomed.Captures[0].ZoomPercent | Should -Be 150
        $image = Get-SavedImage $zoomed.Captures[0]
        $image.Metadata.ZoomPercent | Should -Be 150
        $image.Height | Should -Be 4524 -Because '3016 CSS pixels at 150%'
        $after = Get-SavedImage $script:AreaItems['After zoom'].Captures[0]
        $plain = Get-SavedImage $script:AreaItems['Plain'].Captures[0]
        @($after.Width, $after.Height) | Should -Be @($plain.Width, $plain.Height)
        $after.Metadata.ZoomPercent | Should -Be 100
    }

    It 'lists the capture area of each page and image in the JSON summary' {
        $summary = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($script:AreaReport, '.json')) -Raw | ConvertFrom-Json
        $zoomed = @($summary.Items | Where-Object Name -eq 'Zoomed')[0]
        $zoomed.CaptureArea | Should -Be 'page'
        $zoomed.ZoomPercent | Should -Be 150
        $zoomed.Captures[0].CaptureArea | Should -Be 'page'
    }

    It 'removed the zoom for the next page and again at the end of the run' {
        $global:VouchArea.Clears | Should -Be 2 -Because 'once for the page after the zoomed one, once at the end'
        $script:PageZoomPercent | Should -Be 100
    }
}

Describe 'Capture area: page content as PNG, and the end of a failed run' -Tag 'Integration' {
    BeforeAll {
        Connect-TestPage
        Mock Set-EdgeForeground { throw 'page captures must not bring the window to the front' }
        Mock Get-ScreenCapture { throw 'page captures must not grab the screen' }
    }
    AfterAll { Close-CdpSocket }

    It 'asks the browser for a PNG and adds the metadata to it' {
        $definition = ConvertTo-CaptureDefinition -Index 4 -Page ([ordered]@{ name = 'Png'; url = "$Web/tall?px=3000"
                actions = @([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'page'; as = 'single' } }) })
        $run = Resolve-RunSettings -BoundParameters @{ CaptureArea = 'page' } -Config $null -Defaults @{
            NavigationTimeoutSec = 10; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10 }
        $context = @{ RunId = [guid]::NewGuid().ToString(); Format = 'png'; Quality = 85; Extension = 'png'; SaveImages = $false; ImagesDir = ''; Screen = '1x1' }
        $item = Invoke-CaptureItem -Definition $definition -Settings $run -CaptureContext $context 6>$null
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        $item.Captures.Count | Should -Be 1
        $bytes = [Convert]::FromBase64String($item.Captures[0].Base64)
        [System.Text.Encoding]::ASCII.GetString($bytes, 1, 3) | Should -Be 'PNG'
        (Get-ImagePixelSize -Bytes $bytes).Height | Should -Be 3016
        $metadata = Get-ImageMetadata -Bytes $bytes
        $metadata.CaptureArea | Should -Be 'page'
        $metadata.PageUrl | Should -Be "$Web/tall?px=3000"
        $item.Captures[0].FileName | Should -Be '004_Png_seg01.png'
    }

    It 'clears the zoom on the open connection when the run fails' {
        Close-CdpSocket
        $script:RealClearForFailure = ${function:Clear-PageZoom}
        $global:VouchFail = @{ Clears = 0; Ok = 0 }
        Mock Clear-PageZoom {
            $global:VouchFail.Clears++
            & $script:RealClearForFailure
            $global:VouchFail.Ok++
        }
        Mock Invoke-CaptureItem { Set-PageZoom -Percent 150; throw 'Simulated failure in the middle of a page' }
        $config = Get-DefaultVouchConfig
        $config['browser']['profileDir'] = $script:ProfileDir
        $config['browser']['debugPort'] = $script:CdpPort
        $config['output']['dir'] = 'out'
        $config['pages'].Add([ordered]@{ name = 'Plain'; url = "$Web/ok" })
        $path = Join-Path -Path $TestDrive -ChildPath 'fail.json'
        [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))

        { Invoke-Main -BoundParameters @{ ConfigPath = $path } 6>$null } | Should -Throw '*Simulated failure*'
        $global:VouchFail.Clears | Should -Be 1
        $global:VouchFail.Ok | Should -Be 1 -Because 'the override was removed over the connection that set it'
        $script:PageZoomPercent | Should -Be 100
        Remove-Variable -Name VouchFail -Scope Global
    }
}

Describe 'Capture area: Edge window (window position mocked)' -Tag 'Integration' {
    BeforeAll {
        Connect-TestPage
        Mock Set-EdgeForeground { $null }
        Mock Get-PrimaryScreenBounds { [System.Drawing.Rectangle]::new(0, 0, 1920, 1080) }
        Mock Get-ScreenBitmap {
            $bitmap = [System.Drawing.Bitmap]::new(1920, 1080, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::Black)
            $graphics.FillRectangle([System.Drawing.Brushes]::Red, 100, 50, 640, 480)
            $graphics.Dispose()
            $bitmap
        }
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
        function Invoke-WindowPage {
            $definition = ConvertTo-CaptureDefinition -Index 2 -Page ([ordered]@{ name = 'Window'; url = "$Web/ok" })
            $run = Resolve-RunSettings -BoundParameters @{ CaptureArea = 'window' } -Config $null -Defaults @{
                NavigationTimeoutSec = 10; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10 }
            $context = @{ RunId = [guid]::NewGuid().ToString(); Format = 'png'; Quality = 85; Extension = 'png'; SaveImages = $false; ImagesDir = ''; Screen = '1920x1080' }
            Invoke-CaptureItem -Definition $definition -Settings $run -CaptureContext $context 6>$null
        }
    }
    AfterAll { Close-CdpSocket }

    It 'cuts the screen image down to the window' {
        Mock Get-EdgeWindowBounds { [System.Drawing.Rectangle]::new(100, 50, 640, 480) }
        $item = Invoke-WindowPage
        $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
        $item.CaptureArea | Should -Be 'window'
        $item.Captures[0].CaptureArea | Should -Be 'window'
        $bytes = [Convert]::FromBase64String($item.Captures[0].Base64)
        $image = [System.Drawing.Bitmap]::new([System.IO.MemoryStream]::new($bytes))
        try {
            @($image.Width, $image.Height) | Should -Be @(640, 480)
            $image.GetPixel(0, 0).R | Should -Be 255
            $image.GetPixel(639, 479).R | Should -Be 255
        }
        finally { $image.Dispose() }
        $metadata = Get-ImageMetadata -Bytes $bytes
        $metadata.CaptureArea | Should -Be 'window'
        $metadata.Screen | Should -Be '640x480 Edge window at (100,50) of the 1920x1080 primary display'
        $metadata.PageUrl | Should -Be "$Web/ok"
        Should -Invoke Get-ScreenCapture -Times 0 -Exactly
    }

    It 'captures the whole screen with a warning when <Case>' -ForEach @(
        @{ Case = 'the window is not found'; Bounds = $null }
        @{ Case = 'the window is on another monitor'; Bounds = @(2500, 0, 800, 600) }
    ) {
        $script:TestBounds = if ($Bounds) { [System.Drawing.Rectangle]::new($Bounds[0], $Bounds[1], $Bounds[2], $Bounds[3]) } else { $null }
        Mock Get-EdgeWindowBounds { $script:TestBounds }
        $item = Invoke-WindowPage
        $item.Status | Should -Be 'WARNING'
        @($item.Details | Where-Object { $_ -like 'The Edge window could not be found on the main display, so the whole screen was captured*' }).Count | Should -Be 1
        $item.Captures.Count | Should -Be 1
        $item.Captures[0].CaptureArea | Should -Be 'screen'
        (Get-ImageMetadata -Bytes ([Convert]::FromBase64String($item.Captures[0].Base64))).CaptureArea | Should -Be 'screen'
        Should -Invoke Get-ScreenCapture -Times 1 -Exactly
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
