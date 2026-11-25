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

    # A test run inside Invoke-Main counts as interactive (pwsh on a desktop): no test
    # may ever reach the real Vouch dialog. Tests that need answers mock
    # Request-UserDecision or Show-ContinueDialog themselves.
    Mock Show-ContinueDialog { throw 'A test reached the real Vouch dialog; mock Request-UserDecision or Show-ContinueDialog.' }

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
            & $script:RealNewHtmlReport -Items $Items -Run $Run -Options $Options
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
        $config['report']['title'] = 'Configured title'
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
            & $script:RealNewHtmlReportForConfig -Items $Items -Run $Run -Options $Options
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

    It 'applies every setting of the file: the report title is used, and nothing is listed as having no effect' {
        $script:CfgOutput | Should -Not -Match 'does not apply'
        [System.IO.File]::ReadAllText($script:CfgReportFile) | Should -Match '<h1>Configured title</h1>'
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
            'Status', 'HttpStatus', 'Details', 'StepLog', 'Captures', 'CaptureArea', 'ZoomPercent', 'Account')
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
                [int[]]$FailShots = @(),
                [string]$OnNotReady = 'warn'
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
            $config['defaults']['onNotReady'] = $OnNotReady
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

    It 'skips a pause with a warning when nobody can answer, and runs the rest of the page' {
        $script:InteractiveRun = $false
        $result = Invoke-TestPage -Url "$Web/tabs" -Actions @(
            [ordered]@{ type = 'pause'; message = 'Sign in' }
            [ordered]@{ type = 'clickText'; text = 'General' }
            (New-Capture))
        $item = $result.Item
        $item.Status | Should -Be 'WARNING'
        ($item.Details -join ' ') | Should -Match 'The pause \(pause:Sign in\) was skipped because nobody was there to answer it'
        @($item.StepLog | ForEach-Object { "$($_.Text)|$($_.Ok)" }) | Should -Be @('pause:Sign in|True', 'clicktext:General|True')
        $item.StepLog[0].Message | Should -Be 'skipped: nobody was there to answer'
        $result.Shots | Should -Be @('General')
    }

    Context 'answers from the person (Request-UserDecision mocked)' {
        BeforeAll {
            function New-Answer([string]$Decision, [int]$WaitSeconds = 0, [bool]$TimedOut = $false) {
                [pscustomobject]@{ Decision = $Decision; WaitSeconds = $WaitSeconds; TimedOut = $TimedOut; Prompted = $true }
            }
            $global:VouchAnswers = [System.Collections.Generic.Queue[object]]::new()
            $global:VouchAsked = [System.Collections.Generic.List[string]]::new()
            # Each call takes the next prepared answer; an answer may first do something
            # in the browser, as the person would (a script block before it in the queue).
            Mock Request-UserDecision {
                $global:VouchAsked.Add($Kind)
                $next = $global:VouchAnswers.Dequeue()
                if ($next -is [scriptblock]) { [void](& $next); $next = $global:VouchAnswers.Dequeue() }
                $next
            }
        }
        BeforeEach {
            $global:VouchAnswers.Clear()
            $global:VouchAsked.Clear()
        }
        AfterAll { Remove-Variable -Name VouchAnswers, VouchAsked -Scope Global -ErrorAction SilentlyContinue }

        It 'a pause answered with Continue carries on with no warning' {
            $global:VouchAnswers.Enqueue((New-Answer 'Continue'))
            $result = Invoke-TestPage -Url "$Web/tabs" -Actions @(
                [ordered]@{ type = 'pause'; message = 'Complete MFA' }
                [ordered]@{ type = 'clickText'; text = 'General' }
                (New-Capture))
            $result.Item.Status | Should -Be 'OK' -Because ($result.Item.Details -join ' | ')
            @($global:VouchAsked) | Should -Be @('pause')
            Should -Invoke Request-UserDecision -Times 1 -Exactly -ParameterFilter { $Message -eq 'Complete MFA' -and $Default -eq 'Continue' -and $TimeoutSec -eq 300 }
            $result.Item.StepLog[0].Message | Should -Be 'continued by the user'
            $result.Shots | Should -Be @('General')
        }

        It 'a pause answered with Wait waits, then asks again' {
            $global:VouchAnswers.Enqueue((New-Answer 'Wait' 1))
            $global:VouchAnswers.Enqueue((New-Answer 'Continue'))
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-TestPage -Url "$Web/ok" -Actions @([ordered]@{ type = 'pause' }, (New-Capture))
            $watch.Stop()
            $result.Item.Status | Should -Be 'OK' -Because ($result.Item.Details -join ' | ')
            @($global:VouchAsked) | Should -Be @('pause', 'pause')
            $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 1
            $result.Item.Captures.Count | Should -Be 1
        }

        It 'a pause answered with Skip ends the page and keeps the screenshots already taken' {
            $global:VouchAnswers.Enqueue((New-Answer 'Skip'))
            $result = Invoke-TestPage -Url "$Web/tabs" -Actions @(
                (New-Capture 'Before')
                [ordered]@{ type = 'pause'; message = 'Check the tab' }
                [ordered]@{ type = 'clickText'; text = 'General' }
                (New-Capture 'After'))
            $item = $result.Item
            $item.Status | Should -Be 'WARNING'
            $item.Captures.Count | Should -Be 1
            @($item.StepLog.Text) | Should -Be @('capture:Before', 'pause:Check the tab')
            ($item.Details -join ' ') | Should -Match 'Skipped by the user at the pause \(pause:Check the tab\): the rest of this page was not run\. The 1 screenshot\(s\) taken before it are kept\.'
        }

        It 'a pause nobody answers in time carries on, with a warning' {
            $global:VouchAnswers.Enqueue((New-Answer 'Continue' 0 $true))
            $result = Invoke-TestPage -Url "$Web/ok" -Actions @([ordered]@{ type = 'pause'; message = 'MFA' }, (New-Capture))
            $result.Item.Status | Should -Be 'WARNING'
            ($result.Item.Details -join ' ') | Should -Match 'Nobody answered the pause \(pause:MFA\) within 300 seconds'
            $result.Item.Captures.Count | Should -Be 1
        }

        It 'a page that waits for the person: Wait, the person confirms, and the page is captured as ready' {
            $key = [guid]::NewGuid().ToString('n')
            $global:VouchGateOpen = "fetch('/gate/open?key=$key').then(function (r) { return r.status; })"
            $global:VouchAnswers.Enqueue({ Invoke-CdpEval -Expression $global:VouchGateOpen -TimeoutSec 10 })
            $global:VouchAnswers.Enqueue((New-Answer 'Wait' 20))
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-TestPage -Url "$Web/gate?key=$key" -WaitFor '#content' -OnNotReady 'prompt' -TimeoutSec 2 `
                -Probe "getComputedStyle(document.getElementById('content')).display" -Actions @((New-Capture))
            $watch.Stop()
            $result.Item.Status | Should -Be 'OK' -Because ($result.Item.Details -join ' | ')
            @($global:VouchAsked) | Should -Be @('notReady')
            Should -Invoke Request-UserDecision -Times 1 -Exactly -ParameterFilter { $Message -like "*did not show '#content' within 2 seconds*" }
            $result.Shots | Should -Be @('block')
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 12 -Because 'the wait ends as soon as the content shows, not after 20 s'
        }

        It 'a page that is not ready, answered with Continue, is captured as it is with a warning' {
            $global:VouchAnswers.Enqueue((New-Answer 'Continue'))
            $result = Invoke-TestPage -Url "$Web/gate?key=$([guid]::NewGuid().ToString('n'))" -WaitFor '#content' -OnNotReady 'prompt' -TimeoutSec 2 `
                -Probe "getComputedStyle(document.getElementById('content')).display" -Actions @((New-Capture))
            $result.Item.Status | Should -Be 'WARNING'
            @($result.Item.Details) | Should -Contain "The page did not show '#content' within 2 seconds; it was captured as it was, as chosen in the Vouch dialog."
            $result.Shots | Should -Be @('none')
        }

        It 'a page that is not ready, answered with Skip, is not captured' {
            $global:VouchAnswers.Enqueue((New-Answer 'Skip'))
            $result = Invoke-TestPage -Url "$Web/gate?key=$([guid]::NewGuid().ToString('n'))" -WaitFor '#content' -OnNotReady 'prompt' -TimeoutSec 2 -Actions @((New-Capture))
            $result.Item.Status | Should -Be 'WARNING'
            $result.Item.Captures.Count | Should -Be 0
            @($result.Item.Details) | Should -Contain "Skipped by the user: the page did not show '#content' within 2 seconds, so it was not captured."
        }

        It 'with onNotReady "warn" nobody is asked, as before' {
            $result = Invoke-TestPage -Url "$Web/gate?key=x" -WaitFor '#content' -TimeoutSec 1 -Actions @((New-Capture))
            Should -Invoke Request-UserDecision -Times 0 -Exactly
            @($result.Item.Details) | Should -Contain "The page did not show '#content' within 1 seconds; it was captured in whatever state it had reached."
        }

        It 'a sign-in page: the person signs in, Continue opens the page again once and captures it' {
            $key = [guid]::NewGuid().ToString('n')
            $global:VouchSignIn = "fetch('/signin?key=$key').then(function (r) { return r.status; })"
            $global:VouchAnswers.Enqueue({ Invoke-CdpEval -Expression $global:VouchSignIn -TimeoutSec 10 })
            $global:VouchAnswers.Enqueue((New-Answer 'Continue'))
            $result = Invoke-TestPage -Url "$Web/protected?key=$key" -OnNotReady 'prompt' -Actions @((New-Capture))
            $item = $result.Item
            $item.Status | Should -Be 'OK' -Because ($item.Details -join ' | ')
            @($global:VouchAsked) | Should -Be @('signIn')
            $item.FinalUrl | Should -Be "$Web/protected?key=$key"
            $result.Shots | Should -Be @('Protected')
            $item.HttpStatus | Should -Be 200
        }

        It 'a sign-in page that still asks for a sign-in after Continue keeps the warning, without asking again' {
            $global:VouchAnswers.Enqueue((New-Answer 'Continue'))
            $result = Invoke-TestPage -Url "$Web/protected?key=nobody" -OnNotReady 'prompt' -Actions @((New-Capture))
            $item = $result.Item
            $item.Status | Should -Be 'WARNING'
            @($global:VouchAsked) | Should -Be @('signIn')
            @($item.Details | Where-Object { $_ -like 'Redirected to a sign-in page (/login)*' }).Count | Should -Be 1
            $item.Captures.Count | Should -Be 1
        }

        It 'a sign-in page answered with Skip is not captured' {
            $global:VouchAnswers.Enqueue((New-Answer 'Skip'))
            $result = Invoke-TestPage -Url "$Web/protected?key=nobody" -OnNotReady 'prompt' -Actions @((New-Capture))
            $result.Item.Status | Should -Be 'WARNING'
            $result.Item.Captures.Count | Should -Be 0
            ($result.Item.Details -join ' ') | Should -Match '^Skipped by the user: the page asked for a sign-in\. Redirected to a sign-in page'
        }
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
            & $script:RealNewHtmlReportForMulti -Items $Items -Run $Run -Options $Options
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
        @($item.Details | Where-Object { $_ -like '*page zoom of 150% could not be set again; any images of this page taken after that show it at 100%*' }).Count |
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
            & $script:RealNewHtmlReportForArea -Items $Items -Run $Run -Options $Options
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

    It 'warns when the page grew while its one tall image was being taken' {
        $script:RealContentSize = ${function:Get-PageContentSize}
        $global:VouchSizeCalls = 0
        # The second measurement, after the image, finds 2000 px of lazily loaded content.
        Mock Get-PageContentSize {
            $global:VouchSizeCalls++
            $size = & $script:RealContentSize
            if ($global:VouchSizeCalls -ge 2) { $size.Height += 2000 }
            $size
        }
        $definition = ConvertTo-CaptureDefinition -Index 5 -Page ([ordered]@{ name = 'Grows'; url = "$Web/tall?px=3000"
                actions = @([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'page'; as = 'single' } }) })
        $run = Resolve-RunSettings -BoundParameters @{ CaptureArea = 'page' } -Config $null -Defaults @{
            NavigationTimeoutSec = 10; SettleSeconds = 0.1; ScrollSettleSeconds = 0.1; MaxScrollSegments = 10 }
        $context = @{ RunId = [guid]::NewGuid().ToString(); Format = 'jpeg'; Quality = 85; Extension = 'jpg'; SaveImages = $false; ImagesDir = ''; Screen = '1x1' }
        $item = Invoke-CaptureItem -Definition $definition -Settings $run -CaptureContext $context 6>$null
        $item.Captures.Count | Should -Be 1
        $item.Status | Should -Be 'WARNING'
        @($item.Details) | Should -Be @('The one tall image of the capture is 3016 pixels high, but the page measured 5016 pixels; content that loaded or changed while it was taken may be missing from it.')
        $global:VouchSizeCalls | Should -Be 2
        Remove-Variable -Name VouchSizeCalls -Scope Global
    }

    It 'does not reconnect at the end of the run to clear a zoom on a connection that died' {
        Close-CdpSocket
        $global:VouchDead = @{ Clears = 0 }
        Mock Clear-PageZoom { $global:VouchDead.Clears++ }
        Mock Invoke-CaptureItem { Set-PageZoom -Percent 150; $script:CdpSocket.Abort() }
        $tabsBefore = @(Get-DevToolsTargetList -Port $script:CdpPort | Where-Object type -eq 'page').Count
        $config = Get-DefaultVouchConfig
        $config['browser']['profileDir'] = $script:ProfileDir
        $config['browser']['debugPort'] = $script:CdpPort
        $config['output']['dir'] = 'out'
        $config['pages'].Add([ordered]@{ name = 'Plain'; url = "$Web/ok" })
        $path = Join-Path -Path $TestDrive -ChildPath 'dead.json'
        [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))

        Invoke-Main -BoundParameters @{ ConfigPath = $path } 6>$null
        $global:VouchDead.Clears | Should -Be 0
        $script:PageZoomPercent | Should -Be 100
        @(Get-DevToolsTargetList -Port $script:CdpPort | Where-Object type -eq 'page').Count | Should -Be $tabsBefore
        Remove-Variable -Name VouchDead -Scope Global
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

    It 'says so when part of the window is off the main display' {
        Mock Get-EdgeWindowBounds { [System.Drawing.Rectangle]::new(1600, 50, 640, 480) }
        $item = Invoke-WindowPage
        $item.Status | Should -Be 'WARNING'
        @($item.Details) | Should -Be @('Part of the Edge window is outside the main display, so the images show only the part on it (320x480 of the 640x480 window).')
        $item.Captures[0].CaptureArea | Should -Be 'window'
        $image = [System.Drawing.Bitmap]::new([System.IO.MemoryStream]::new([Convert]::FromBase64String($item.Captures[0].Base64)))
        try { @($image.Width, $image.Height) | Should -Be @(320, 480) } finally { $image.Dispose() }
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

Describe 'Progress events, stop and -TabId (headless Edge, desktop functions mocked)' -Tag 'Integration' {
    BeforeAll {
        Close-CdpSocket
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

        function New-RunConfig {
            param([string]$Folder, [object[]]$Pages)
            $config = Get-DefaultVouchConfig
            $config['browser']['profileDir'] = $script:ProfileDir
            $config['browser']['debugPort'] = $script:CdpPort
            $config['defaults']['navigationTimeoutSec'] = 5
            $config['defaults']['settleSeconds'] = 0.1
            $config['defaults']['scrollSettleSeconds'] = 0.1
            $config['output']['dir'] = 'out'
            $config['output']['reportName'] = 'run.html'
            foreach ($page in $Pages) { $config['pages'].Add($page) }
            $path = Join-Path -Path $TestDrive -ChildPath $Folder
            [void](New-Item -ItemType Directory -Path $path -Force)
            $file = Join-Path -Path $path -ChildPath 'run.json'
            [System.IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            return $file
        }
        function Read-RunEvent([string]$Path, [switch]$All) {
            # The Task 5 event types; navigation and detail events (added for the capture
            # log) are left out unless -All, so these tests keep checking the same order.
            @(Get-Content -LiteralPath $Path -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $All -or $_.type -notin 'navigation', 'detail' })
        }
        function New-TestTab([string]$Url) {
            Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($script:CdpPort)/json/new?$Url" -NoProxy
        }
        function Remove-TestTab([string]$Id) {
            try { [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:CdpPort)/json/close/$Id" -NoProxy) } catch { Write-Verbose 'already closed' }
        }
    }

    It 'Get-CdpPageTarget -TabId picks the named tab among two web tabs, and refuses an unknown id' {
        $first = New-TestTab "$Web/ok?tab=first"
        $second = New-TestTab "$Web/ok?tab=second"
        try {
            (Get-CdpPageTarget -Port $script:CdpPort -TabId $second.id).id | Should -Be $second.id
            (Get-CdpPageTarget -Port $script:CdpPort -TabId $first.id).id | Should -Be $first.id
            $before = @(Get-DevToolsTargetList -Port $script:CdpPort | Where-Object type -eq 'page').Count
            { Get-CdpPageTarget -Port $script:CdpPort -TabId 'NO-SUCH-TAB' -WaitSeconds 1 } | Should -Throw "*no open tab with the id 'NO-SUCH-TAB'*"
            @(Get-DevToolsTargetList -Port $script:CdpPort | Where-Object type -eq 'page').Count | Should -Be $before -Because 'no tab is opened instead'
        }
        finally {
            Remove-TestTab $first.id
            Remove-TestTab $second.id
        }
    }

    It 'logs a two-page run as one valid JSON event per line, in order, in the tab named by -TabId' {
        $tab = New-TestTab 'about:blank'
        try {
            $file = New-RunConfig -Folder 'events' -Pages @(
                [ordered]@{ id = 'gate'; name = 'Gate'; url = "$Web/gate?key=$([guid]::NewGuid().ToString('n'))"
                    overrides = [ordered]@{ waitFor = '#content'; onNotReady = 'prompt'; promptTimeoutSec = 60 } }
                [ordered]@{ id = 'plain'; name = 'Plain'; url = "$Web/ok" })
            $log = Join-Path -Path $TestDrive -ChildPath 'events\progress.ndjson'
            Mock Test-InteractiveRun { $true }
            Mock Show-ContinueDialog { [pscustomobject]@{ Decision = 'Skip'; WaitSeconds = 0; TimedOut = $false } }

            Invoke-Main -BoundParameters @{ ConfigPath = $file; EventLogPath = $log; TabId = [string]$tab.id } 6>$null
            $script:ExitCode | Should -Be 0

            $lines = @(Get-Content -LiteralPath $log -Encoding utf8)
            foreach ($line in $lines) { { $line | ConvertFrom-Json } | Should -Not -Throw -Because $line }
            $events = Read-RunEvent $log
            @($events.type) | Should -Be @('runStart', 'pageStart', 'prompt', 'promptResult', 'pageEnd', 'pageStart', 'capture', 'action', 'pageEnd', 'runEnd')
            @($events.runId | Sort-Object -Unique).Count | Should -Be 1
            # Since the capture log: what each page loaded and every detail, as they happened.
            $all = Read-RunEvent $log -All
            @($all.type) | Should -Be @('runStart', 'pageStart', 'navigation', 'prompt', 'promptResult', 'detail', 'pageEnd',
                'pageStart', 'navigation', 'capture', 'action', 'pageEnd', 'runEnd')
            ($all | Where-Object type -eq 'detail').text | Should -Match 'Skipped by the user'
            ($all | Where-Object type -eq 'navigation')[1].httpStatus | Should -Be 200

            $runStart = $events[0]
            $runStart.toolVersion | Should -Be $script:ToolVersion
            $runStart.pageCount | Should -Be 2
            Split-Path -Path $runStart.reportPath -Leaf | Should -Be 'run.html'
            $runStart.interactive | Should -BeTrue
            $runStart.stopFile | Should -Be "$log.stop"

            $events[1].pageId | Should -Be 'gate'
            $events[1].index | Should -Be 1
            $events[1].total | Should -Be 2
            $events[1].name | Should -Be 'Gate'
            $events[2].kind | Should -Be 'notReady'
            $events[2].pageId | Should -Be 'gate'
            $events[2].timeoutSec | Should -Be 60
            $events[3].decision | Should -Be 'Skip'
            $events[4].status | Should -Be 'WARNING'
            $events[4].captureCount | Should -Be 0
            @($events[4].details) -join ' ' | Should -Match 'Skipped by the user'

            $events[5].pageId | Should -Be 'plain'
            $events[5].url | Should -Be "$Web/ok"
            $events[6].fileName | Should -Be '002_Plain_seg01.jpg'
            $events[6].area | Should -Be 'screen'
            $events[6].segment | Should -Be 1
            $events[6].captureNumber | Should -Be 1
            $events[7].actionType | Should -Be 'capture'
            $events[7].index | Should -Be 1
            $events[7].ok | Should -BeTrue
            $events[8].status | Should -Be 'OK'
            $events[8].finalUrl | Should -Be "$Web/ok"
            $events[8].captureCount | Should -Be 1

            $runEnd = $events[9]
            $runEnd.exitCode | Should -Be 0
            $runEnd.stopped | Should -BeFalse
            $runEnd.reportPath | Should -Be $runStart.reportPath
            $runEnd.reportPath | Should -Exist
            $runEnd.counts.ok | Should -Be 1
            $runEnd.counts.warning | Should -Be 1
            $runEnd.counts.captures | Should -Be 1
            $runEnd.counts.notRun | Should -Be 0

            # The run used the named tab, and left it open.
            $after = @(Get-DevToolsTargetList -Port $script:CdpPort | Where-Object { $_.id -eq $tab.id })
            $after.Count | Should -Be 1
            $after[0].url | Should -Be "$Web/ok"
            $script:CdpTabId | Should -Be '' -Because 'the tab choice ends with the run'
            $script:InteractiveRun | Should -BeFalse -Because 'the prompt setting ends with the run'
        }
        finally {
            Remove-TestTab $tab.id
        }
    }

    It 'stops within about 2 seconds when the stop file appears during a long wait, and still writes the report' {
        $file = New-RunConfig -Folder 'stop' -Pages @(
            [ordered]@{ id = 'long'; name = 'Long wait'; url = "$Web/ok"; actions = @(
                    [ordered]@{ type = 'capture'; label = 'Before' }
                    [ordered]@{ type = 'wait'; seconds = 60 }
                    [ordered]@{ type = 'capture'; label = 'After' }) }
            [ordered]@{ id = 'next'; name = 'Never reached'; url = "$Web/ok" })
        $log = Join-Path -Path $TestDrive -ChildPath 'stop\progress.ndjson'
        # Another thread plays the Designer: once the wait has begun, it asks the run to stop.
        $job = Start-ThreadJob -ArgumentList $log -ScriptBlock {
            param($Log)
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline) {
                $text = ''
                try {
                    $stream = [System.IO.FileStream]::new($Log, 'Open', 'Read', 'ReadWrite, Delete')
                    try { $text = [System.IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
                }
                catch { $text = '' }
                if ($text -match '"type":"action"') { break }
                Start-Sleep -Milliseconds 100
            }
            Start-Sleep -Milliseconds 1000
            [System.IO.File]::WriteAllText("$Log.stop", '')
            [datetime]::Now
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-Main -BoundParameters @{ ConfigPath = $file; EventLogPath = $log } 6>$null
            $ended = [datetime]::Now
        }
        finally {
            $stoppedAt = $job | Wait-Job -Timeout 70 | Receive-Job
            $job | Remove-Job -Force
        }
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30 -Because 'the 60 s wait was cut short'
        ($ended - $stoppedAt).TotalSeconds | Should -BeLessThan 2.5

        $events = Read-RunEvent $log
        $runEnd = $events[-1]
        $runEnd.type | Should -Be 'runEnd'
        $runEnd.stopped | Should -BeTrue
        $runEnd.exitCode | Should -Be 0
        $runEnd.counts.run | Should -Be 1
        $runEnd.counts.notRun | Should -Be 1
        $pageEnd = @($events | Where-Object type -eq 'pageEnd')
        $pageEnd.Count | Should -Be 1
        $pageEnd[0].status | Should -Be 'WARNING'
        $pageEnd[0].stopped | Should -BeTrue
        $pageEnd[0].captureCount | Should -Be 1
        @($pageEnd[0].details) | Should -Contain 'Stopped by the user: the run ended here, so the rest of this page was not captured.'
        @($events | Where-Object type -eq 'pageStart').Count | Should -Be 1

        $runEnd.reportPath | Should -Exist
        @(Test-ReportIntegrity -Path $runEnd.reportPath | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        "$log.stop" | Should -Not -Exist -Because 'a stop that was honoured is cleaned up before runEnd'
        $script:StopRequested | Should -BeFalse -Because 'the stop ends with the run'
        $script:EventLogPath | Should -Be '' -Because 'the event log ends with the run'
    }

    It 'a stop during a pause''s Wait ends the run without asking again' {
        $file = New-RunConfig -Folder 'pausestop' -Pages @(
            [ordered]@{ id = 'pause'; name = 'Pause'; url = "$Web/ok"; actions = @(
                    [ordered]@{ type = 'pause'; message = 'Complete MFA' }
                    [ordered]@{ type = 'capture' }) }
            [ordered]@{ id = 'next'; name = 'Never reached'; url = "$Web/ok" })
        $log = Join-Path -Path $TestDrive -ChildPath 'pausestop\progress.ndjson'
        Mock Test-InteractiveRun { $true }
        Mock Show-ContinueDialog { [pscustomobject]@{ Decision = 'Wait'; WaitSeconds = 60; TimedOut = $false } }
        # The person answers "Wait 60 s", then stops the run from the Designer.
        $job = Start-ThreadJob -ArgumentList $log -ScriptBlock {
            param($Log)
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline) {
                $text = ''
                try {
                    $stream = [System.IO.FileStream]::new($Log, 'Open', 'Read', 'ReadWrite, Delete')
                    try { $text = [System.IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
                }
                catch { $text = '' }
                if ($text -match '"type":"promptResult"') { break }
                Start-Sleep -Milliseconds 100
            }
            Start-Sleep -Milliseconds 500
            [System.IO.File]::WriteAllText("$Log.stop", '')
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $output = Invoke-Main -BoundParameters @{ ConfigPath = $file; EventLogPath = $log } 6>&1 | Out-String
        }
        finally {
            $job | Wait-Job -Timeout 70 | Remove-Job -Force
        }
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'the 60 s wait was cut short'
        Should -Invoke Show-ContinueDialog -Times 1 -Exactly
        $output | Should -Not -Match 'could not be shown'
        $events = Read-RunEvent $log
        @($events.type) | Should -Be @('runStart', 'pageStart', 'prompt', 'promptResult', 'action', 'pageEnd', 'runEnd')
        $events[3].decision | Should -Be 'Wait'
        $events[4].actionType | Should -Be 'pause'
        $events[4].message | Should -Be 'stopped by the user'
        $events[5].status | Should -Be 'WARNING'
        $events[5].stopped | Should -BeTrue
        @($events[5].details) | Should -Contain 'Stopped by the user: the run ended here, so the rest of this page was not captured.'
        $events[6].stopped | Should -BeTrue
        $events[6].counts.notRun | Should -Be 1
        "$log.stop" | Should -Not -Exist
    }

    It 'the real script logs an error and a runEnd when the run cannot start' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'broken'
        [void](New-Item -ItemType Directory -Path $folder)
        $config = Join-Path -Path $folder -ChildPath 'empty.json'
        Set-Content -LiteralPath $config -Value '{ "schemaVersion": 1, "pages": [] }' -Encoding utf8
        $log = Join-Path -Path $folder -ChildPath 'events.ndjson'
        $pwsh = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $pwsh -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $folder 'out.txt') `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$script:VouchPath`"", '-ConfigPath', "`"$config`"", '-EventLogPath', "`"$log`"")
        $process.ExitCode | Should -Be 1
        $events = Read-RunEvent $log
        @($events.type) | Should -Be @('error', 'runEnd')
        $events[0].message | Should -Match 'has no pages'
        $events[1].exitCode | Should -Be 1
    }
}

Describe 'Report form, zip and opening the report (headless Edge, page capture area, nothing of the page path mocked)' -Tag 'Integration' {
    BeforeAll {
        Close-CdpSocket
        # The page capture area needs neither the screen nor the window; they must not be used.
        Mock Get-ScreenCapture { throw 'the screen must not be captured in a page-area run' }
        Mock Set-EdgeForeground { throw 'the window must not be brought forward in a page-area run' }
        $script:RealNewHtmlReportForForm = ${function:New-HtmlReport}
        $global:VouchForm = @{ Opened = @() }
        Mock Open-ReportFile { $global:VouchForm.Opened += $Path }
        Mock New-HtmlReport {
            $global:VouchForm.Items = $Items
            $global:VouchForm.Options = $Options
            & $script:RealNewHtmlReportForForm -Items $Items -Run $Run -Options $Options
        }

        $folder = Join-Path -Path $TestDrive -ChildPath 'form'
        [void](New-Item -ItemType Directory -Path $folder)
        $bitmap = [System.Drawing.Bitmap]::new(40, 20)
        try { $bitmap.Save((Join-Path $folder 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }

        $config = Get-DefaultVouchConfig
        $config['browser']['profileDir'] = $script:ProfileDir
        $config['browser']['debugPort'] = $script:CdpPort
        $config['defaults']['captureArea'] = 'page'
        $config['defaults']['account'] = 'svc-audit@example.com'
        $config['defaults']['navigationTimeoutSec'] = 10
        $config['defaults']['settleSeconds'] = 0.1
        $config['defaults']['scrollSettleSeconds'] = 0.1
        $config['output']['dir'] = 'out'
        $config['output']['reportName'] = 'evidence {date}'
        $config['output']['embedImages'] = $false
        $config['output']['jsonSummary'] = $true
        $config['output']['openReport'] = $true
        $config['output']['zip']['enabled'] = $true
        $config['output']['zip']['name'] = '{report} {classification} {nope}'
        $config['report']['title'] = 'Q3 ITGC <evidence>'
        $config['report']['classification'] = 'Confidential'
        $config['report']['logoPath'] = 'logo.png'
        $config['report']['company']['name'] = 'ACME Audit'
        $config['report']['company']['details'] = "1 Main Street`nSpringfield"
        $config['report']['period']['from'] = '2026-07-01'
        $config['report']['period']['to'] = '2026-09-30'
        $config['pages'].Add([ordered]@{ id = 'p1'; name = 'Plain'; url = "$Web/ok" })
        $config['pages'].Add([ordered]@{ id = 'p2'; name = 'Tabs'; url = "$Web/tabs"; overrides = [ordered]@{ account = 'admin@example.com' }
                actions = @([ordered]@{ type = 'capture'; label = 'First view' }
                    [ordered]@{ type = 'capture'; label = 'Tall'; scroll = [ordered]@{ mode = 'page' } }) })
        $script:FormConfig = Join-Path -Path $folder -ChildPath 'form.json'
        [System.IO.File]::WriteAllText($script:FormConfig, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $script:FormLog = Join-Path -Path $folder -ChildPath 'events.ndjson'

        Mock Test-InteractiveRun { $true }
        $script:FormOutput = Invoke-Main -BoundParameters @{ ConfigPath = $script:FormConfig; EventLogPath = $script:FormLog } 6>&1 | Out-String
        $script:FormExit = $script:ExitCode
        $script:FormItems = @($global:VouchForm.Items)
        $script:FormEvents = @(Get-Content -LiteralPath $script:FormLog -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
        $script:FormEnd = $script:FormEvents[-1]
        $script:FormReport = $script:FormEnd.reportPath
        $script:FormHtml = [System.IO.File]::ReadAllText($script:FormReport)

        function Invoke-VouchVerify([string]$Report) {
            $pwsh = (Get-Process -Id $PID).Path
            $out = Join-Path -Path $TestDrive -ChildPath ("verify-{0}.txt" -f [guid]::NewGuid())
            $process = Start-Process -FilePath $pwsh -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$script:VouchPath`"", '-Verify', "`"$Report`"")
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = (Get-Content -LiteralPath $out -Raw) }
        }
        function Copy-Evidence([string]$Name) {
            # A copy of the extracted zip, to be tampered with.
            $target = Join-Path -Path $TestDrive -ChildPath $Name
            [System.IO.Compression.ZipFile]::ExtractToDirectory($script:FormEnd.zipPath, $target)
            return Join-Path -Path $target -ChildPath ([System.IO.Path]::GetFileName($script:FormReport))
        }
        Add-Type -AssemblyName System.IO.Compression.ZipFile
    }

    AfterAll { Remove-Variable -Name VouchForm -Scope Global -ErrorAction SilentlyContinue }

    It 'writes a linked report that verifies, and keeps no base64 copy of the images' {
        $script:FormExit | Should -Be 0 -Because $script:FormOutput
        $script:FormReport | Should -BeLike "*\out\evidence $((Get-Date).ToString('yyyy-MM-dd')).html"
        $results = @(Test-ReportIntegrity -Path $script:FormReport)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        $images = @($script:FormItems | ForEach-Object { $_.Captures })
        $images.Count | Should -BeGreaterOrEqual 3
        @($results | Where-Object Check -like 'Image *').Count | Should -Be $images.Count
        @($images | Where-Object { $_.Base64 }) | Should -BeNullOrEmpty
        $script:FormHtml | Should -Not -Match 'data:image/jpeg'
        $script:FormHtml | Should -Match ([regex]::Escape("src=""images/evidence%20$((Get-Date).ToString('yyyy-MM-dd'))/001_Plain_seg01.jpg"""))
        $script:FormHtml | Should -Match '<strong>Linked report:</strong>'
    }

    It 'shows the report fields from the file' {
        $script:FormHtml | Should -Match '<h1>Q3 ITGC &lt;evidence&gt;</h1>'
        $script:FormHtml | Should -Match 'class="classification top cls-confidential"'
        $script:FormHtml | Should -Match '<img class="logo" alt="Company logo" src="data:image/png;base64,'
        $script:FormHtml | Should -Match '<div class="company-name">ACME Audit</div>'
        $script:FormHtml | Should -Match '<td class="k">Period covered</td><td>2026-07-01 to 2026-09-30</td>'
        $script:FormHtml | Should -Match '<td class="k">Account used</td><td>svc-audit@example.com</td>'
        $script:FormHtml | Should -Match '<dt>Account</dt><dd>admin@example.com</dd>'
        $script:FormHtml | Should -Match '<li><a href="#item-2-c2">Capture 2: Tall</a></li>'
        $script:FormHtml | Should -Match '<figure id="item-2-c2">'
    }

    It 'records the page''s account inside each image file' {
        $tabs = $script:FormItems | Where-Object Name -eq 'Tabs'
        $bytes = [System.IO.File]::ReadAllBytes($tabs.Captures[0].FilePath)
        (Get-ImageMetadata -Bytes $bytes).Account | Should -Be 'admin@example.com'
    }

    It 'makes one zip with exactly the report, the summary and the images, named from the template' {
        $output = $script:FormOutput
        $output | Should -Match 'the zip name has the token \{nope\}'
        $zip = $script:FormEnd.zipPath
        $zip | Should -Exist
        [System.IO.Path]::GetFileName($zip) | Should -Be "evidence $((Get-Date).ToString('yyyy-MM-dd')) Confidential {nope}.zip"
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($script:FormReport)
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try { $entries = @($archive.Entries.FullName | Sort-Object) } finally { $archive.Dispose() }
        $expected = @("$stem.html", "$stem.json", "$stem.log", "images/$stem/SHA256SUMS") + @($script:FormItems | ForEach-Object { $_.Captures } | ForEach-Object { "images/$stem/$($_.FileName)" })
        $entries | Should -Be @($expected | Sort-Object)
        $entries | Should -Not -Contain 'events.ndjson'
        $script:FormHtml | Should -Not -Match '\.zip'
    }

    It 'records the zip and its SHA-256 on the console, in the JSON summary and in runEnd' {
        $hash = (Get-FileHash -LiteralPath $script:FormEnd.zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:FormEnd.zipSha256 | Should -Be $hash
        $script:FormOutput | Should -Match ([regex]::Escape("Zip: $($script:FormEnd.zipPath) (SHA-256 $hash)"))
        $summary = Get-Content -LiteralPath $script:FormEnd.jsonSummaryPath -Raw | ConvertFrom-Json -DateKind String
        $summary.Zip.Path | Should -Be $script:FormEnd.zipPath
        $summary.Zip.Sha256 | Should -Be $hash
        $summary.ReportDetails.ImageForm | Should -Be 'linked'
        $summary.LogPath | Should -Be ([System.IO.Path]::ChangeExtension($script:FormReport, '.log'))
        $summary.LogComplete | Should -BeTrue
        $script:FormEnd.logPath | Should -Be $summary.LogPath
        $script:FormEnd.logComplete | Should -BeTrue
        $script:FormHtml | Should -Match ([regex]::Escape("<td class=""k"">Capture log</td><td>$([System.IO.Path]::GetFileName($summary.LogPath))</td>"))
        $summary.ReportDetails.Classification | Should -Be 'Confidential'
        $summary.ReportDetails.CaptureWindow.First | Should -Not -BeNullOrEmpty
        ($summary.Items | Where-Object Name -eq 'Tabs').Account | Should -Be 'admin@example.com'
    }

    It 'gives an extracted copy that verifies on its own, with the capture log up to the archive line' {
        $copy = Copy-Evidence 'extracted'
        @(Test-ReportIntegrity -Path $copy | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        $inside = @(Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($copy, '.log')))
        $inside[-2] | Should -Match 'Creating archive .*\.zip$'
        $inside[-1] | Should -Match 'inside the archive ends with this line'
        $onDisk = @(Get-Content -LiteralPath $script:FormEnd.logPath)
        $onDisk[0..($inside.Count - 1)] | Should -Be $inside
        $onDisk[-1] | Should -Match 'End of capture log\.$'
        $summary = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($copy, '.json')) -Raw | ConvertFrom-Json
        $summary.Zip.Sha256 | Should -BeNullOrEmpty -Because 'a file inside the zip cannot hold the zip''s own hash'
    }

    It 'opens the report once, after everything, in an interactive run' {
        @($global:VouchForm.Opened) | Should -Be @($script:FormReport)
        $script:FormEvents[-1].type | Should -Be 'runEnd'
    }

    It '-Verify exits 4, naming the file, when one linked image was altered' {
        $copy = Copy-Evidence 'altered'
        $name = ($script:FormItems | Where-Object Name -eq 'Tabs').Captures[1].FileName
        $file = Join-Path (Split-Path $copy) "images\$([System.IO.Path]::GetFileNameWithoutExtension($copy))\$name"
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes[$bytes.Length - 30] = $bytes[$bytes.Length - 30] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($file, $bytes)
        $result = Invoke-VouchVerify $copy
        $result.ExitCode | Should -Be 4
        $result.Output | Should -Match "FAIL\s+Image $([regex]::Escape($name))"
        $result.Output | Should -Match 'NOT VERIFIED'
    }

    It 'the real script with -Verify writes nothing into an event file' {
        $log = Join-Path -Path $TestDrive -ChildPath 'verify-events.ndjson'
        $pwsh = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $pwsh -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'verify-events.txt') `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$script:VouchPath`"", '-Verify', "`"$($script:FormReport)`"", '-EventLogPath', "`"$log`"")
        $process.ExitCode | Should -Be 0
        $log | Should -Not -Exist
    }

    It '-Verify fails when one linked image was removed' {
        $copy = Copy-Evidence 'removed'
        $name = ($script:FormItems | Where-Object Name -eq 'Plain').Captures[0].FileName
        Remove-Item -LiteralPath (Join-Path (Split-Path $copy) "images\$([System.IO.Path]::GetFileNameWithoutExtension($copy))\$name")
        $result = Invoke-VouchVerify $copy
        $result.ExitCode | Should -Be 4
        $result.Output | Should -Match "FAIL\s+Image $([regex]::Escape($name))\s+the image file .* is missing"
    }

    It 'takes every report switch typed on the command line over the file, and embeds the images with -LinkImages:$false' {
        Mock Test-InteractiveRun { $false }
        $bound = @{
            ConfigPath = $script:FormConfig; ReportName = 'typed'; ReportTitle = 'Typed title'; Classification = 'Public'
            LogoPath = (Join-Path $TestDrive 'no-such-logo.png'); CompanyName = 'Typed Co'; CompanyDetails = 'Typed details'
            Description = 'Typed description'; Origin = 'Typed origin'; GeneratedBy = 'Typed person'
            PeriodFrom = 'typed-from'; PeriodTo = 'typed-to'; PeriodLabel = 'Typed period'; Account = 'typed@example.com'
            NoIndex = [switch]$true; LinkImages = [switch]$false; Zip = [switch]$true; ZipName = '{title} {period}'; OpenReport = [switch]$true
        }
        $output = Invoke-Main -BoundParameters $bound 6>&1 | Out-String
        $script:ExitCode | Should -Be 0 -Because $output
        $report = Join-Path (Split-Path $script:FormConfig) 'out\typed.html'
        $html = [System.IO.File]::ReadAllText($report)
        $html | Should -Match '<h1>Typed title</h1>'
        $html | Should -Match 'class="classification top cls-public"'
        $html | Should -Not -Match 'class="logo"'
        $output | Should -Match 'WARNING: The logo file .*no-such-logo\.png. was not found, so the report has no logo\.'
        foreach ($text in 'Typed Co', 'Typed details', 'Typed description', 'Typed origin', 'Typed person', 'Typed period: typed-from to typed-to') {
            $html | Should -Match ([regex]::Escape($text)) -Because $text
        }
        $html | Should -Match '<dt>Account</dt><dd>typed@example.com</dd>'
        $html | Should -Not -Match 'admin@example.com' -Because '-Account beats the page''s own account too'
        $html | Should -Not -Match 'id="contents"'
        $html | Should -Match '<strong>Self-contained report:</strong>'
        ([regex]::Matches($html, 'src="data:image/jpeg;base64,')).Count | Should -BeGreaterOrEqual 3
        @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        (Join-Path (Split-Path $report) 'Typed title Typed period.zip') | Should -Exist
        @($global:VouchForm.Opened).Count | Should -Be 1 -Because 'only the interactive run before opened it'
        $output | Should -Match 'The report is not opened: nobody is watching this run'

        # The same zip name again: a number is added, nothing is replaced.
        $before = (Get-FileHash -LiteralPath (Join-Path (Split-Path $report) 'Typed title Typed period.zip')).Hash
        Invoke-Main -BoundParameters $bound 6>$null
        (Join-Path (Split-Path $report) 'Typed title Typed period_2.zip') | Should -Exist
        (Get-FileHash -LiteralPath (Join-Path (Split-Path $report) 'Typed title Typed period.zip')).Hash | Should -Be $before
    }

    It 'takes the report switches in a CSV run too' {
        Mock Test-InteractiveRun { $false }
        $csv = Join-Path -Path $TestDrive -ChildPath 'switches.csv'
        "Name,Url,Steps,ScrollFullPage,Notes`r`nPlain,$Web/ok,,N,`r`nTall,$Web/tall?px=2500,,Y," | Set-Content -LiteralPath $csv -Encoding utf8
        $out = Join-Path -Path $TestDrive -ChildPath 'csv-out'
        $bound = @{
            CsvPath = $csv; OutputDir = $out; ReportName = 'csv-{classification}'; EdgeProfileDir = $script:ProfileDir; DebugPort = $script:CdpPort
            NavigationTimeoutSec = 10; SettleSeconds = [double]0.1; ScrollSettleSeconds = [double]0.1; MaxScrollSegments = 5; ImageFormat = 'jpeg'
            JpegQuality = 80; CaptureArea = 'page'; ZoomPercent = 100
            ReportTitle = 'CSV title'; Classification = 'internal'; Account = 'csv@example.com'; LinkImages = [switch]$true; Zip = [switch]$true
        }
        Invoke-Main -BoundParameters $bound 6>$null
        $script:ExitCode | Should -Be 0
        $report = Join-Path $out 'csv-Internal.html'
        $html = [System.IO.File]::ReadAllText($report)
        $html | Should -Match '<h1>CSV title</h1>'
        $html | Should -Match 'cls-internal'
        $html | Should -Match '<td class="k">Account used</td><td>csv@example.com</td>'
        $html | Should -Match '<h2 id="contents">Contents</h2>'
        $html | Should -Match 'src="images/csv-Internal/001_Plain_seg01.jpg"'
        @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        (Join-Path $out 'csv-Internal.zip') | Should -Exist
    }
}

Describe 'Capture log (headless Edge, page capture area)' -Tag 'Integration' {
    BeforeAll {
        Close-CdpSocket
        Mock Get-ScreenCapture { throw 'the screen must not be captured in a page-area run' }
        Mock Set-EdgeForeground { throw 'the window must not be brought forward in a page-area run' }
        $script:RealSetNavigationMarker = ${function:Set-NavigationMarker}

        function New-LogConfig {
            param([string]$Folder, [object[]]$Pages, [hashtable]$Output = @{})
            $config = Get-DefaultVouchConfig
            $config['browser']['profileDir'] = $script:ProfileDir
            $config['browser']['debugPort'] = $script:CdpPort
            $config['defaults']['captureArea'] = 'page'
            $config['defaults']['navigationTimeoutSec'] = 5
            $config['defaults']['settleSeconds'] = 0.1
            $config['defaults']['scrollSettleSeconds'] = 0.1
            $config['output']['dir'] = 'out'
            $config['output']['reportName'] = 'run.html'
            $config['output']['jsonSummary'] = $true
            foreach ($key in $Output.Keys) { $config['output'][$key] = $Output[$key] }
            foreach ($page in $Pages) { $config['pages'].Add($page) }
            $path = Join-Path -Path $TestDrive -ChildPath $Folder
            [void](New-Item -ItemType Directory -Path $path -Force)
            $file = Join-Path -Path $path -ChildPath 'run.json'
            [System.IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            return $file
        }
        function Read-SharedText([string]$Path) {
            # As a person tailing the log would: shared read while the run writes.
            $stream = [System.IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite, Delete')
            try { return [System.IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
        }
        function Get-LogBody([string]$Path) {
            # The entries without their time stamps.
            @(Get-Content -LiteralPath $Path -Encoding utf8 | ForEach-Object { if ($_ -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} [+-]\d\d:\d\d  (.*)$') { $Matches[1] } else { "+$($_.Trim())" } })
        }

        $global:VouchLog = @{ Navigations = 0; MidRun = '' }
        # Before the second page is opened, read what the log already holds.
        Mock Set-NavigationMarker {
            $global:VouchLog.Navigations++
            if ($global:VouchLog.Navigations -eq 2 -and $global:VouchLog.LogPath) { $global:VouchLog.MidRun = Read-SharedText $global:VouchLog.LogPath }
            & $script:RealSetNavigationMarker
        }
        $file = New-LogConfig -Folder 'log2' -Pages @(
            [ordered]@{ id = 'p1'; name = 'Plain'; url = "$Web/ok" }
            [ordered]@{ id = 'p2'; name = 'Tabs'; url = "$Web/tabs"; actions = @(
                    [ordered]@{ type = 'clickText'; text = 'Audit Log' }
                    [ordered]@{ type = 'capture'; label = "Audit`nlog" }) })
        $global:VouchLog.LogPath = Join-Path (Split-Path $file) 'out\run.log'
        Invoke-Main -BoundParameters @{ ConfigPath = $file } 6>$null
        $script:LogExit = $script:ExitCode
        $script:LogFile = $global:VouchLog.LogPath
        $script:LogSummary = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($script:LogFile, '.json')) -Raw | ConvertFrom-Json -DateKind String
    }

    AfterAll { Remove-Variable -Name VouchLog -Scope Global -ErrorAction SilentlyContinue }

    It 'writes the log of a run without -EventLogPath, entries in the order they happened' {
        $script:LogExit | Should -Be 0
        $script:LogFile | Should -Exist
        $body = Get-LogBody $script:LogFile
        $body[0] | Should -Match '^Vouch 2\.0\.0 capture log - run [0-9a-f-]{36}$'
        $order = @($body | ForEach-Object {
                switch -Regex ($_) {
                    '^Page \d of 2: ' { 'pageStart' } '^  Opened: ' { 'navigation' } '^  Action ' { 'action' } '^  Image ' { 'image' }
                    '^Page \d of 2 done' { 'pageEnd' } '^Run finished' { 'runEnd' } '^End of capture log' { 'end' }
                } })
        $order | Should -Be @('pageStart', 'navigation', 'image', 'action', 'pageEnd', 'pageStart', 'navigation', 'action', 'image', 'action', 'pageEnd', 'runEnd', 'end')
        $body | Should -Contain '  Action 1 clicktext:Audit Log: ok'
        $body | Should -Contain "Report: $([System.IO.Path]::ChangeExtension($script:LogFile, '.html'))"
        $body | Should -Contain 'Exit code: 0'
        $body | Should -Contain "Manifest SHA-256: $($script:LogSummary.Run.ManifestSha256)"
        [System.IO.File]::ReadAllBytes($script:LogFile)[0] | Should -Not -Be 0xEF
    }

    It 'names the same files with the same SHA-256 values as the JSON summary' {
        # An entry with continuation lines (the two-line label) is joined back into one.
        $entries = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-LogBody $script:LogFile)) { if ($line.StartsWith('+')) { $entries[$entries.Count - 1] += " $($line.Substring(1))" } else { $entries.Add($line) } }
        $logged = @($entries | Where-Object { $_ -match '^  Image (\S+): .*SHA-256 ([0-9a-f]{64})$' } | ForEach-Object { "$($Matches[1]) $($Matches[2])" })
        $summary = @($script:LogSummary.Items | ForEach-Object { $_.Captures } | ForEach-Object { "$($_.FileName) $($_.Sha256)" })
        $logged.Count | Should -Be 2
        $logged | Should -Be $summary
    }

    It 'keeps a multi-line label in one indented entry' {
        $body = Get-LogBody $script:LogFile
        $index = [array]::FindIndex([string[]]$body, [Predicate[string]] { param($l) $l -like '  Image 002_Tabs_seg01.jpg*' })
        $body[$index] | Should -Match 'capture 1 "Audit$'
        $body[$index + 1] | Should -Match '^\+log", segment 1 of 1, page content only, zoom 100%, \d+x\d+ px, SHA-256 [0-9a-f]{64}$'
    }

    It 'already holds the first page while the second page is running' {
        $global:VouchLog.MidRun | Should -Match 'Page 1 of 2 done: OK, 1 image\(s\)'
        $global:VouchLog.MidRun | Should -Match 'Page 2 of 2: p2 "Tabs"'
        $global:VouchLog.MidRun | Should -Not -Match 'Opened: .*/tabs'
        $global:VouchLog.MidRun | Should -Not -Match 'Run finished'
    }

    It 'closes the log of a run that was stopped' {
        $file = New-LogConfig -Folder 'logstop' -Pages @([ordered]@{ id = 'a'; name = 'A'; url = "$Web/ok" }, [ordered]@{ id = 'b'; name = 'B'; url = "$Web/ok" }, [ordered]@{ id = 'c'; name = 'C'; url = "$Web/ok" })
        $events = Join-Path (Split-Path $file) 'events.ndjson'
        $global:VouchLog.Navigations = 0
        # The person presses Stop as the second page is opened.
        Mock Set-NavigationMarker {
            $global:VouchLog.Navigations++
            if ($global:VouchLog.Navigations -eq 2) { [System.IO.File]::WriteAllText("$($global:VouchLog.Events).stop", '') }
            & $script:RealSetNavigationMarker
        }
        $global:VouchLog.Events = $events
        Invoke-Main -BoundParameters @{ ConfigPath = $file; EventLogPath = $events } 6>$null
        $body = Get-LogBody (Join-Path (Split-Path $file) 'out\run.log')
        $body | Should -Contain 'Page 2 of 3 done: WARNING, 0 image(s) - stopped by the user'
        $body | Should -Contain '  Warning: Stopped by the user: the run ended here, so the rest of this page was not captured.'
        $body | Should -Not -Contain ('Page 3 of 3: c "C" - ' + "$Web/ok")
        $body | Should -Contain 'Run finished: 2 of 3 page(s) run - 1 OK, 1 warning(s), 0 failed, 1 not run; 1 image(s)'
        $body | Should -Contain 'Stopped by the user: yes'
        $body[-1] | Should -Be 'End of capture log.'
    }

    It 'closes the log of a run with a failing page, with the problem where it happened' {
        $file = New-LogConfig -Folder 'logfail' -Pages @([ordered]@{ id = 'bad'; name = 'Unreachable'; url = 'http://localhost:1/' }, [ordered]@{ id = 'ok'; name = 'Fine'; url = "$Web/ok" })
        Invoke-Main -BoundParameters @{ ConfigPath = $file } 6>$null
        $script:ExitCode | Should -Be 2
        $body = Get-LogBody (Join-Path (Split-Path $file) 'out\run.log')
        $first = [array]::IndexOf([string[]]$body, 'Page 1 of 2 done: FAILED, 0 image(s)')
        $first | Should -BeGreaterThan 0
        $body[$first - 1] | Should -Match '^  Problem: The page could not be loaded: net::'
        $body | Should -Contain 'Page 2 of 2 done: OK, 1 image(s)'
        $body | Should -Contain 'Exit code: 2'
        $body[-1] | Should -Be 'End of capture log.'
    }

    It 'closes the log of a run that ends with an error after it started' {
        $file = New-LogConfig -Folder 'logcrash' -Pages @([ordered]@{ id = 'a'; name = 'A'; url = "$Web/ok" })
        Mock Start-EdgeDebug { throw 'Edge could not be started.' }
        { Invoke-Main -BoundParameters @{ ConfigPath = $file } 6>$null } | Should -Throw '*could not be started*'
        $body = Get-LogBody (Join-Path (Split-Path $file) 'out\run.log')
        $body | Should -Contain 'ERROR: Edge could not be started.'
        $body | Should -Contain 'Run ended with an error; no report was made.'
        $body[-1] | Should -Be 'End of capture log.'
        $script:CaptureLogPath | Should -Be '' -Because 'the log ends with the run'
    }

    It 'writes no log with <Case>' -ForEach @(@{ Case = '-NoCaptureLog'; Switch = $true }, @{ Case = 'output.captureLog false'; Switch = $false }) {
        $folder = "nolog$Switch"
        $file = if ($Switch) { New-LogConfig -Folder $folder -Pages @([ordered]@{ id = 'a'; name = 'A'; url = "$Web/ok" }) }
        else { New-LogConfig -Folder $folder -Pages @([ordered]@{ id = 'a'; name = 'A'; url = "$Web/ok" }) -Output @{ captureLog = $false } }
        $bound = @{ ConfigPath = $file }
        if ($Switch) { $bound.NoCaptureLog = [switch]$true }
        Invoke-Main -BoundParameters $bound 6>$null
        $script:ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path (Split-Path $file) 'out') -Filter '*.log').Count | Should -Be 0
        $summary = Get-Content -LiteralPath (Join-Path (Split-Path $file) 'out\run.json') -Raw | ConvertFrom-Json
        $summary.PSObject.Properties['LogPath'] | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText((Join-Path (Split-Path $file) 'out\run.html')) | Should -Not -Match 'Capture log'
    }

    It 'writes no log for -Verify' {
        $report = [System.IO.Path]::ChangeExtension($script:LogFile, '.html')
        $copyFolder = Join-Path $TestDrive 'verifylog'
        [void](New-Item -ItemType Directory -Path $copyFolder)
        Copy-Item -LiteralPath $report -Destination $copyFolder
        Invoke-Main -BoundParameters @{ Verify = (Join-Path $copyFolder 'run.html') } 6>$null
        $script:ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $copyFolder -Filter '*.log').Count | Should -Be 0
    }
}