#Requires -Version 7
# Unit tests for the pure (browser- and desktop-free) parts of vouch.ps1.
# Tests tagged KnownIssue assert the CORRECT behaviour and fail until the bug is fixed.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-VouchFunctionSource)))

    function New-TestCsv {
        param([string]$Content)
        $path = Join-Path -Path $TestDrive -ChildPath ("{0}.csv" -f [guid]::NewGuid())
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return $path
    }
}

Describe 'ConvertTo-BooleanFlag / Test-BooleanFlagText' {
    It 'treats <Value> as <Expected>' -ForEach @(
        @{ Value = 'Y'; Expected = $true }, @{ Value = 'yes'; Expected = $true }
        @{ Value = 'TRUE'; Expected = $true }, @{ Value = '1'; Expected = $true }
        @{ Value = ' y '; Expected = $true }, @{ Value = 'N'; Expected = $false }
        @{ Value = ''; Expected = $false }, @{ Value = $null; Expected = $false }
    ) {
        ConvertTo-BooleanFlag -Value $Value | Should -Be $Expected
    }

    It 'accepts <Value> as valid flag text' -ForEach @(
        @{ Value = '' }, @{ Value = 'No' }, @{ Value = 'false' }, @{ Value = '0' }, @{ Value = 'Y' }
    ) {
        Test-BooleanFlagText -Value $Value | Should -BeTrue
    }

    It 'rejects <Value>' -ForEach @(@{ Value = 'maybe' }, @{ Value = '2' }, @{ Value = 'x' }) {
        Test-BooleanFlagText -Value $Value | Should -BeFalse
    }
}

Describe 'ConvertTo-StepList' {
    BeforeEach {
        $errors = [System.Collections.Generic.List[string]]::new()
    }

    It 'returns an empty list for blank input' {
        $steps = ConvertTo-StepList -StepsText '  ' -LineNumber 2 -Errors $errors
        , $steps | Should -BeOfType [System.Collections.Generic.List[object]]
        $steps.Count | Should -Be 0
        $errors.Count | Should -Be 0
    }

    It 'keeps colons inside CSS selectors' {
        $steps = ConvertTo-StepList -StepsText 'click:ul > li:nth-child(2) a:hover' -LineNumber 2 -Errors $errors
        $steps[0].Verb | Should -Be 'click'
        $steps[0].Argument | Should -Be 'ul > li:nth-child(2) a:hover'
    }

    It 'parses a mixed, spaced step list in order' {
        $steps = ConvertTo-StepList -StepsText ' click:#settings-tab ; ClickText: Audit Log ;wait:3; ' -LineNumber 2 -Errors $errors
        $errors.Count | Should -Be 0
        $steps.Verb | Should -Be @('click', 'clicktext', 'wait')
        $steps[1].Argument | Should -Be 'Audit Log'
        $steps[2].Argument | Should -Be 3
    }

    It 'reports <Text> as an error' -ForEach @(
        @{ Text = 'click:'; Pattern = '*requires a CSS selector*' }
        @{ Text = 'clicktext:'; Pattern = '*requires the visible text*' }
        @{ Text = 'wait:abc'; Pattern = '*not a number of seconds*' }
        @{ Text = 'wait:301'; Pattern = '*not a number of seconds*' }
        @{ Text = 'wait:-1'; Pattern = '*not a number of seconds*' }
        @{ Text = 'hover:#x'; Pattern = "*unknown step verb 'hover'*" }
        @{ Text = ':#x'; Pattern = '*is not valid*' }
        @{ Text = 'justtext'; Pattern = '*is not valid*' }
    ) {
        $steps = ConvertTo-StepList -StepsText $Text -LineNumber 7 -Errors $errors
        $steps.Count | Should -Be 0
        $errors.Count | Should -Be 1
        $errors[0] | Should -BeLike 'Line 7:*'
        $errors[0] | Should -BeLike $Pattern
    }

    It 'rejects wait:NaN' {
        # NaN passes both range comparisons, then [int](NaN * 1000) would throw at run time.
        $steps = ConvertTo-StepList -StepsText 'wait:NaN' -LineNumber 2 -Errors $errors
        $errors.Count | Should -Be 1
        $steps.Count | Should -Be 0
    }

    It 'accepts a comma as the decimal separator in wait:' {
        $steps = ConvertTo-StepList -StepsText 'wait:2,5' -LineNumber 2 -Errors $errors
        $errors.Count | Should -Be 0
        $steps[0].Argument | Should -Be 2.5
    }

    Context 'on a machine whose decimal separator is a comma (de-DE)' {
        BeforeAll {
            $originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
        }
        AfterAll {
            [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture
        }

        It 'reads wait:2.5 as 2.5 seconds, not 25' {
            # A culture-sensitive [double]::TryParse would read '.' as the de-DE
            # thousands separator and return 25.
            $steps = ConvertTo-StepList -StepsText 'wait:2.5' -LineNumber 2 -Errors $errors
            $errors.Count | Should -Be 0
            $steps[0].Argument | Should -Be 2.5
        }
    }
}

Describe 'Import-CaptureDefinition' {
    It 'loads the shipped sample CSV' {
        $sample = Join-Path -Path $PSScriptRoot -ChildPath '..\captures.sample.csv'
        $definitions = Import-CaptureDefinition -Path $sample
        $definitions.Count | Should -Be 4
        $definitions[0].Name | Should -Be 'Intranet Dashboard'
        $definitions[0].ScrollFullPage | Should -BeFalse
        $definitions[1].ScrollFullPage | Should -BeTrue
        $definitions[1].Steps[0].Verb | Should -Be 'clicktext'
        $definitions[1].Notes | Should -BeLike '*retention setting*'
        $definitions[2].Steps.Count | Should -Be 2
        $definitions[2].LineNumber | Should -Be 4
    }

    It 'loads every example row of the copy-and-paste template' {
        $template = Join-Path -Path $PSScriptRoot -ChildPath '..\captures.template.csv'
        $definitions = Import-CaptureDefinition -Path $template 6>$null
        $definitions.Count | Should -Be 10
        ($definitions | Where-Object Name -eq 'Two clicks in a row').Steps.Count | Should -Be 2
        ($definitions | Where-Object Name -eq 'Slow page - wait first').Steps[0].Argument | Should -Be 5
        ($definitions | Where-Object Name -eq 'Click an exact element (selector)').Steps[0].Verb | Should -Be 'click'
        ($definitions | Where-Object Name -eq 'Notes with commas').Notes | Should -BeLike '*commas, like this one, in*'
    }

    It 'loads the rows the getting-started guide shows for copying' {
        $guide = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\docs\getting-started.md') -Raw
        $block = [regex]::Match($guide, '(?s)ready to paste into Notepad.*?```\r?\n(.*?)```').Groups[1].Value
        $path = New-TestCsv $block
        (Import-CaptureDefinition -Path $path 6>$null).Count | Should -Be 9
    }

    It 'throws when the file is missing' {
        { Import-CaptureDefinition -Path (Join-Path $TestDrive 'nope.csv') } | Should -Throw '*not found*'
    }

    It 'throws when a required column is missing' {
        $path = New-TestCsv "Name,Link`nA,https://x"
        { Import-CaptureDefinition -Path $path } | Should -Throw "*missing the required 'Url' column*"
    }

    It 'throws when there are no data rows' {
        $path = New-TestCsv 'Name,Url,Steps,ScrollFullPage,Notes'
        { Import-CaptureDefinition -Path $path } | Should -Throw '*no capture rows*'
    }

    It 'collects every row problem before failing' {
        $path = New-TestCsv @'
Name,Url,Steps,ScrollFullPage,Notes
,https://a.example,,,
B,ftp://b.example,,,
C,https://c.example,bogus:1,maybe,
'@
        { Import-CaptureDefinition -Path $path 6>$null } | Should -Throw '*Nothing was launched*'
    }

    It 'accepts header names in any case' {
        $path = New-TestCsv "name,URL`nA,https://a.example"
        (Import-CaptureDefinition -Path $path)[0].Url | Should -Be 'https://a.example'
    }

    It 'ignores completely blank rows, such as the trailing rows Excel leaves' {
        $path = New-TestCsv "Name,Url,Steps,ScrollFullPage,Notes`nA,https://a.example,,,`n,,,,`nB,https://b.example,,,`n,,,,"
        $definitions = Import-CaptureDefinition -Path $path 6>$null
        $definitions.Count | Should -Be 2
        $definitions[1].Index | Should -Be 2
        $definitions[1].LineNumber | Should -Be 4
    }

    It 'throws when every row is blank' {
        $path = New-TestCsv "Name,Url,Steps,ScrollFullPage,Notes`n,,,,`n,,,,"
        { Import-CaptureDefinition -Path $path } | Should -Throw '*no capture rows*'
    }
}

Describe 'Test-LoginRedirect' {
    It 'returns <Expected> for <Requested> -> <Final> (password field: <Password>)' -ForEach @(
        @{ Requested = 'https://a/admin/users'; Final = 'https://a/login?returnUrl=%2Fadmin'; Password = $false; Expected = $true }
        @{ Requested = 'https://a/admin/users'; Final = 'https://a/Account/SignIn'; Password = $false; Expected = $true }
        @{ Requested = 'https://a/app#/settings'; Final = 'https://a/app#/auth/login'; Password = $false; Expected = $true }
        @{ Requested = 'https://a/admin/users'; Final = 'https://a/portal/start'; Password = $true; Expected = $true }
        @{ Requested = 'https://a/admin/users'; Final = 'https://a/admin/users/'; Password = $true; Expected = $false }
        @{ Requested = 'https://a/admin/users'; Final = 'https://a/admin/users/list'; Password = $false; Expected = $false }
        @{ Requested = 'https://a/admin/login-policy'; Final = 'https://a/admin/login-policy/v2'; Password = $false; Expected = $false }
        @{ Requested = 'https://a/admin/users'; Final = ''; Password = $false; Expected = $false }
    ) {
        Test-LoginRedirect -RequestedUrl $Requested -FinalUrl $Final -HasPasswordField $Password | Should -Be $Expected
    }
}

Describe 'Get-SafeFileName' {
    It 'maps <Name> to <Expected>' -ForEach @(
        @{ Name = 'App Settings - Audit Log'; Expected = 'App_Settings_-_Audit_Log' }
        @{ Name = '..\..\evil'; Expected = 'evil' }
        @{ Name = '***'; Expected = 'capture' }
        @{ Name = 'Contrôle d''accès'; Expected = 'Contr_le_d_acc_s' }
    ) {
        Get-SafeFileName -Name $Name | Should -Be $Expected
    }

    It 'caps names at 48 characters' {
        (Get-SafeFileName -Name ('x' * 200)).Length | Should -Be 48
    }
}

Describe 'Get-OriginFromUrl' {
    It 'returns <Expected> for <Url>' -ForEach @(
        @{ Url = 'https://App.Example.com/a/b?c=1'; Expected = 'https://app.example.com' }
        @{ Url = 'http://localhost:8080/x'; Expected = 'http://localhost:8080' }
        @{ Url = 'https://a.example:443/'; Expected = 'https://a.example' }
        @{ Url = 'not a url'; Expected = '' }
        @{ Url = ''; Expected = '' }
    ) {
        Get-OriginFromUrl -Url $Url | Should -Be $Expected
    }
}

Describe 'Test-HttpsUpgrade' {
    It 'returns <Expected> for <Requested> -> <Final>' -ForEach @(
        @{ Requested = 'http://example.com/'; Final = 'https://example.com/'; Expected = $true }
        @{ Requested = 'http://Example.com/a'; Final = 'https://example.com/b'; Expected = $true }
        @{ Requested = 'http://example.com/'; Final = 'https://www.example.com/'; Expected = $false }
        @{ Requested = 'http://example.com/'; Final = 'https://login.example.net/'; Expected = $false }
        @{ Requested = 'http://example.com:8080/'; Final = 'https://example.com/'; Expected = $false }
        @{ Requested = 'https://example.com/'; Final = 'http://example.com/'; Expected = $false }
        @{ Requested = 'http://example.com/'; Final = ''; Expected = $false }
    ) {
        Test-HttpsUpgrade -RequestedUrl $Requested -FinalUrl $Final | Should -Be $Expected
    }
}

Describe 'ConvertTo-RunSummaryJson' {
    It 'carries the run, the items and capture metadata but no image data' {
        $captures = [System.Collections.Generic.List[object]]::new()
        $captures.Add((New-CaptureRecord -Bytes ([byte[]](1, 2, 3)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FilePath 'C:\x.jpg'))
        $item = [pscustomobject]@{
            Index = 1; Name = 'A'; Url = 'https://a/'; FinalUrl = 'https://a/'; Status = 'OK'; HttpStatus = 200
            ScrollFullPage = $false; Details = [System.Collections.Generic.List[string]]::new()
            StepLog = [System.Collections.Generic.List[object]]::new(); Captures = $captures
        }
        $run = [pscustomobject]@{ OkCount = 1; WarnCount = 0; FailCount = 0; CaptureCount = 1 }
        $json = ConvertTo-RunSummaryJson -Items @($item) -Run $run -ReportPath 'C:\r.html' -ExitCode 0
        $json | Should -Not -Match 'Base64|AQID'
        $parsed = $json | ConvertFrom-Json
        $parsed.ExitCode | Should -Be 0
        $parsed.Run.OkCount | Should -Be 1
        $parsed.Items[0].Status | Should -Be 'OK'
        @($parsed.Items[0].Details).Count | Should -Be 0
        $parsed.Items[0].Captures[0].FilePath | Should -Be 'C:\x.jpg'
        $parsed.Items[0].Captures[0].Bytes | Should -Be 3
    }
}

Describe 'Encode-Html and ConvertTo-JsLiteral' {
    It 'escapes all five HTML special characters, ampersand first' {
        Encode-Html -Text '<a href="x">Tom & Jerry''s</a>' |
            Should -Be '&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;'
    }

    It 'returns an empty string for null' {
        Encode-Html -Text $null | Should -Be ''
    }

    It 'produces a JSON string literal that round-trips <Value>' -ForEach @(
        @{ Value = 'a "quoted" \ back\slash' }, @{ Value = "line`nbreak" }, @{ Value = "it's" }, @{ Value = '日本語' }
    ) {
        $literal = ConvertTo-JsLiteral -Value $Value
        $literal | Should -Match '^".*"$'
        ($literal | ConvertFrom-Json) | Should -BeExactly $Value
    }
}

Describe 'New-HtmlReport' {
    BeforeAll {
        $run = [pscustomobject]@{
            StartTime = '2026-09-23 10:00:00'; EndTime = '2026-09-23 10:05:00'; TimeZone = 'UTC'
            Computer = 'PC'; User = 'DOM\user'; OperatingSystem = 'Windows'; EdgeVersion = 'Edg/1'
            BrowserInstance = 'test'; ToolVersion = 'test'; CsvPath = 'c.csv'; ImageFormat = 'jpeg'
            ImageDescription = 'JPEG'; ScreenResolution = '1x1'; Total = 1; OkCount = 0
            WarnCount = 1; FailCount = 0; CaptureCount = 2
        }
        $details = [System.Collections.Generic.List[string]]::new()
        $details.Add('Redirected to <b>evil</b>')
        $captures = [System.Collections.Generic.List[object]]::new()
        $captures.Add((New-CaptureRecord -Bytes ([byte[]](1, 2, 3)) -Url 'https://a/?x=<y>' -SegmentIndex 1 -SegmentCount 2))
        $captures.Add((New-CaptureRecord -Bytes ([byte[]](4, 5, 6)) -Url 'https://a/' -SegmentIndex 2 -SegmentCount 2))
        $stepLog = [System.Collections.Generic.List[object]]::new()
        $stepLog.Add([pscustomobject]@{ Text = 'click:#a'; Ok = $false; Message = 'No element <x>' })
        $item = [pscustomobject]@{
            Index = 1; Name = '<script>alert(1)</script>'; Url = 'https://a/'; FinalUrl = ''
            Notes = 'Notes & "quotes"'; StepsText = 'click:#a'; ScrollFullPage = $true
            Status = 'WARNING'; HttpStatus = 0; Details = $details; StepLog = $stepLog; Captures = $captures
        }
        $html = New-HtmlReport -Items @($item) -Run $run
    }

    It 'never emits user-supplied markup unescaped' {
        $html | Should -Not -Match '<script>alert'
        $html | Should -Not -Match '<b>evil</b>'
        $html | Should -Not -Match 'No element <x>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Match 'Notes &amp; &quot;quotes&quot;'
    }

    It 'embeds each capture as a base64 data URI' {
        ([regex]::Matches($html, 'src="data:image/jpeg;base64,')).Count | Should -Be 2
        $html | Should -Match ([regex]::Escape('base64,AQID"'))
        $html | Should -Match 'segment 2 of 2'
    }

    It 'shows the warning badge and the missing final URL' {
        $html | Should -Match '<span class="badge warn">WARNING</span>'
        $html | Should -Match '<dd>not reached</dd>'
        $html | Should -Match 'not reported by the browser'
    }
}

Describe 'Resolve-RunSettings' {
    BeforeAll {
        # The script's own parameter defaults (paths shortened).
        $defaults = @{
            CsvPath = 'C:\v\captures.csv'; OutputDir = 'C:\v\reports'; ReportName = ''
            EdgeProfileDir = 'C:\p'; DebugPort = 9222; NavigationTimeoutSec = 30
            SettleSeconds = [double]2; ScrollSettleSeconds = [double]1; MaxScrollSegments = 30
            ImageFormat = 'jpeg'; JpegQuality = 85; SaveImages = [switch]$false
            KeepBrowserOpen = [switch]$false; FailOnWarning = [switch]$false; LogDir = ''
            JsonSummary = [switch]$false; UseVirtualDesktop = [switch]$false; Verify = ''
            LoginSetup = [switch]$false; ConfigPath = ''; Only = [string[]]@()
        }
        $config = '{
            "browser":  { "profileDir": "C:\\cfg-profile", "debugPort": 9333, "keepBrowserOpen": true },
            "defaults": { "navigationTimeoutSec": 45, "settleSeconds": 0.5, "maxScrollSegments": 12 },
            "output":   { "dir": "C:\\cfg-out", "reportName": "", "imageFormat": "png", "saveImages": true }
        }' | ConvertFrom-Json
    }

    It 'returns the parameter defaults unchanged when nothing is bound and there is no config' {
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults $defaults -Config $null
        foreach ($name in $defaults.Keys) {
            $settings.$name | Should -Be $defaults[$name] -Because $name
        }
        @($settings.PSObject.Properties).Count | Should -Be $defaults.Count
    }

    It 'uses plain types: switches become booleans, numbers keep their type' {
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults $defaults -Config $null
        $settings.SaveImages | Should -BeOfType [bool]
        $settings.SettleSeconds | Should -BeOfType [double]
        $settings.DebugPort | Should -BeOfType [int]
    }

    It 'takes config values over the defaults' {
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults $defaults -Config $config
        $settings.EdgeProfileDir | Should -Be 'C:\cfg-profile'
        $settings.DebugPort | Should -Be 9333
        $settings.NavigationTimeoutSec | Should -Be 45
        $settings.SettleSeconds | Should -Be 0.5
        $settings.MaxScrollSegments | Should -Be 12
        $settings.OutputDir | Should -Be 'C:\cfg-out'
        $settings.ImageFormat | Should -Be 'png'
        $settings.SaveImages | Should -BeTrue
        $settings.KeepBrowserOpen | Should -BeTrue
    }

    It 'keeps the default where the config is silent or blank' {
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults $defaults -Config $config
        $settings.ReportName | Should -Be ''
        $settings.ScrollSettleSeconds | Should -Be 1
        $settings.JpegQuality | Should -Be 85
        $settings.CsvPath | Should -Be 'C:\v\captures.csv'
    }

    It 'takes a bound parameter over the config and the default' {
        $bound = @{ DebugPort = 9444; ImageFormat = 'jpeg'; SettleSeconds = [double]3 }
        $settings = Resolve-RunSettings -BoundParameters $bound -Defaults $defaults -Config $config
        $settings.DebugPort | Should -Be 9444
        $settings.ImageFormat | Should -Be 'jpeg'
        $settings.SettleSeconds | Should -Be 3
        $settings.NavigationTimeoutSec | Should -Be 45
    }

    It 'lets a switch bound to $false beat a config true' {
        $bound = @{ SaveImages = [switch]$false; KeepBrowserOpen = [switch]$false }
        $settings = Resolve-RunSettings -BoundParameters $bound -Defaults $defaults -Config $config
        $settings.SaveImages | Should -BeFalse
        $settings.KeepBrowserOpen | Should -BeFalse
    }

    It 'reads a real $PSBoundParameters dictionary' {
        # The script passes its own $PSBoundParameters, a generic Dictionary, not a hashtable.
        function Get-TestBoundParameters { param([switch]$SaveImages, [int]$DebugPort) return , $PSBoundParameters }
        $bound = Get-TestBoundParameters -SaveImages:$false -DebugPort 9555
        $bound | Should -Not -BeOfType [hashtable]
        $settings = Resolve-RunSettings -BoundParameters $bound -Defaults $defaults -Config $config
        $settings.SaveImages | Should -BeFalse
        $settings.DebugPort | Should -Be 9555
        $settings.KeepBrowserOpen | Should -BeTrue
    }

    It 'accepts a config given as nested hashtables' {
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults $defaults -Config @{ output = @{ jpegQuality = 60 } }
        $settings.JpegQuality | Should -Be 60
    }

    It 'keeps -Only as a list of trimmed names, even for one value' {
        $settings = Resolve-RunSettings -BoundParameters @{ Only = ' p002 ' } -Defaults $defaults -Config $null
        , $settings.Only | Should -BeOfType [string[]]
        $settings.Only | Should -Be @('p002')
    }
}

Describe 'Split-BoundParameter' {
    BeforeAll {
        $inScope = @{ DebugPort = 9222; SettleSeconds = [double]2; SaveImages = [switch]$false; ConfigPath = 'C:\c.json' }
        $config = @{ browser = @{ debugPort = 9333 }; defaults = @{ settleSeconds = 0.5 }; output = @{ saveImages = $true } }
    }

    It 'treats an unbound parameter as a default, which loses to the config' {
        $split = Split-BoundParameter -InScope $inScope -BoundParameters @{ ConfigPath = 'C:\c.json'; SettleSeconds = [double]4 }
        @($split.Bound.Keys | Sort-Object) | Should -Be @('ConfigPath', 'SettleSeconds')
        $split.Defaults.DebugPort | Should -Be 9222
        $split.Defaults.ContainsKey('SettleSeconds') | Should -BeFalse

        $settings = Resolve-RunSettings -BoundParameters $split.Bound -Defaults $split.Defaults -Config $config
        $settings.DebugPort | Should -Be 9333        # unbound: config beats the default
        $settings.SaveImages | Should -BeTrue
        $settings.SettleSeconds | Should -Be 4       # bound: beats the config
    }

    It 'counts every visible value as typed when there are no bound parameters' {
        $split = Split-BoundParameter -InScope $inScope -BoundParameters $null
        $split.Bound.Count | Should -Be $inScope.Count
        $split.Defaults.Count | Should -Be 0
    }

    It 'does not change what it is given' {
        $bound = @{ DebugPort = 1 }
        [void](Split-BoundParameter -InScope $inScope -BoundParameters $bound)
        $bound.Count | Should -Be 1
        $inScope.Count | Should -Be 4
    }
}

Describe 'Configuration file' {
    BeforeAll {
        function New-TestConfig {
            # The default configuration with one valid page, as parsed dictionaries.
            $config = Get-DefaultVouchConfig
            $config['pages'].Add([ordered]@{
                id = 'p001'; name = 'Page'; url = 'https://a.example/'; notes = ''; enabled = $true
                overrides = [ordered]@{}; actions = [System.Collections.Generic.List[object]]::new()
            })
            return $config
        }
        function Write-TestConfig {
            param([string]$Json, [string]$Folder = $TestDrive)
            $path = Join-Path -Path $Folder -ChildPath ("{0}.json" -f [guid]::NewGuid())
            [System.IO.File]::WriteAllText($path, $Json, [System.Text.UTF8Encoding]::new($false))
            return $path
        }
    }

    Context 'Get-DefaultVouchConfig and Test-VouchConfig' {
        It 'gives a default configuration that validates clean' {
            $result = Test-VouchConfig -Config (Get-DefaultVouchConfig)
            $result.Errors.Count | Should -Be 0
            $result.Warnings.Count | Should -Be 0
        }

        It 'holds the documented defaults' {
            $config = Get-DefaultVouchConfig
            $config['schemaVersion'] | Should -Be 1
            $config['browser']['debugPort'] | Should -Be 9222
            $config['defaults']['captureArea'] | Should -Be 'screen'
            $config['defaults']['zoomPercent'] | Should -Be 100
            $config['defaults']['onNotReady'] | Should -Be 'warn'
            $config['defaults']['promptTimeoutSec'] | Should -Be 300
            $config['output']['dir'] | Should -Be 'reports'
            $config['output']['embedImages'] | Should -BeTrue
            $config['output']['zip']['name'] | Should -Be '{report}.zip'
            $config['report']['title'] | Should -Be 'Audit Evidence Report'
            $config['report']['showIndex'] | Should -BeTrue
            $config['report']['classification'] | Should -Be ''
            $config['pages'].Count | Should -Be 0
            @($config.Keys) | Should -Be @('schemaVersion', 'name', 'browser', 'defaults', 'output', 'report', 'pages')
        }

        It 'reports <Case> at <Path>' -ForEach @(
            @{ Case = 'text where a number belongs'; Path = 'defaults.settleSeconds'; Pattern = '*must be a number from 0 to 120*found "2"*'
               Change = { param($c) $c['defaults']['settleSeconds'] = '2' } }
            @{ Case = 'a number written as text'; Path = 'browser.debugPort'; Pattern = '*whole number from 1024 to 65535*found "abc"*'
               Change = { param($c) $c['browser']['debugPort'] = 'abc' } }
            @{ Case = 'text where true/false belongs'; Path = 'output.saveImages'; Pattern = '*true or false*found "yes"*'
               Change = { param($c) $c['output']['saveImages'] = 'yes' } }
            @{ Case = 'a number where text belongs'; Path = 'report.title'; Pattern = '*text in double quotes*found 5*'
               Change = { param($c) $c['report']['title'] = 5 } }
            @{ Case = 'a list where an object belongs'; Path = 'output.zip'; Pattern = '*object in { }*'
               Change = { param($c) $c['output']['zip'] = [System.Collections.Generic.List[object]]::new() } }
            @{ Case = 'a bad capture area'; Path = 'defaults.captureArea'; Pattern = '*"screen", "window", "page"*found "desktop"*'
               Change = { param($c) $c['defaults']['captureArea'] = 'desktop' } }
            @{ Case = 'a bad classification'; Path = 'report.classification'; Pattern = '*"Confidential"*found "Secret"*'
               Change = { param($c) $c['report']['classification'] = 'Secret' } }
            @{ Case = 'a bad on-not-ready'; Path = 'defaults.onNotReady'; Pattern = '*"warn", "prompt"*'
               Change = { param($c) $c['defaults']['onNotReady'] = 'ask' } }
            @{ Case = 'a bad image format'; Path = 'output.imageFormat'; Pattern = '*"jpeg", "png"*'
               Change = { param($c) $c['output']['imageFormat'] = 'gif' } }
            @{ Case = 'a JPEG quality of 0'; Path = 'output.jpegQuality'; Pattern = '*from 1 to 100*found 0*'
               Change = { param($c) $c['output']['jpegQuality'] = 0 } }
            @{ Case = 'a timeout below the parameter range'; Path = 'defaults.navigationTimeoutSec'; Pattern = '*from 5 to 600*'
               Change = { param($c) $c['defaults']['navigationTimeoutSec'] = 4 } }
            @{ Case = 'a fractional segment count'; Path = 'defaults.maxScrollSegments'; Pattern = '*whole number from 1 to 500*found 2.5*'
               Change = { param($c) $c['defaults']['maxScrollSegments'] = 2.5 } }
            @{ Case = 'a missing page name'; Path = 'pages[0].name'; Pattern = '*every page needs a name*'
               Change = { param($c) $c['pages'][0].Remove('name') } }
            @{ Case = 'a blank page url'; Path = 'pages[0].url'; Pattern = '*every page needs a url*'
               Change = { param($c) $c['pages'][0]['url'] = ' ' } }
            @{ Case = 'a url that is not http(s)'; Path = 'pages[0].url'; Pattern = '*http:// or https://*ftp://a*'
               Change = { param($c) $c['pages'][0]['url'] = 'ftp://a' } }
            @{ Case = 'a duplicate page id'; Path = 'pages[1].id'; Pattern = '*"P001", which pages[[]0[]] already uses*'
               Change = { param($c) $c['pages'].Add([ordered]@{ id = 'P001'; name = 'B'; url = 'https://b.example/' }) } }
            @{ Case = 'an id that clashes with a generated one'; Path = 'pages[1].id'; Pattern = '*"p001"*'
               Change = { param($c) $c['pages'][0].Remove('id'); $c['pages'].Add([ordered]@{ id = 'p001'; name = 'B'; url = 'https://b.example/' }) } }
            @{ Case = 'a bad page override'; Path = 'pages[0].overrides.zoomPercent'; Pattern = '*from 25 to 500*'
               Change = { param($c) $c['pages'][0]['overrides']['zoomPercent'] = 10 } }
            @{ Case = 'a newer schemaVersion'; Path = 'schemaVersion'; Pattern = '*newer version of Vouch*'
               Change = { param($c) $c['schemaVersion'] = 2 } }
            @{ Case = 'schemaVersion 0'; Path = 'schemaVersion'; Pattern = '*must be 1*'
               Change = { param($c) $c['schemaVersion'] = 0 } }
            @{ Case = 'a click without a selector'; Path = 'pages[0].actions[0].selector'; Pattern = '*"click" action needs the CSS selector*'
               Change = { param($c) $c['pages'][0]['actions'].Add([ordered]@{ type = 'click' }) } }
            @{ Case = 'an unknown action type'; Path = 'pages[0].actions[0].type'; Pattern = '*one of "click", "clickText"*found "hover"*'
               Change = { param($c) $c['pages'][0]['actions'].Add([ordered]@{ type = 'hover' }) } }
            @{ Case = 'a wait that is too long'; Path = 'pages[0].actions[0].seconds'; Pattern = '*from 0 to 300*'
               Change = { param($c) $c['pages'][0]['actions'].Add([ordered]@{ type = 'wait'; seconds = 301 }) } }
            @{ Case = 'a scroll area without a selector'; Path = 'pages[0].actions[0].scroll.selector'; Pattern = '*"area" needs the CSS selector*'
               Change = { param($c) $c['pages'][0]['actions'].Add([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'area' } }) } }
            @{ Case = 'a bad scroll mode'; Path = 'pages[0].actions[0].scroll.mode'; Pattern = '*"none", "auto", "page", "area"*'
               Change = { param($c) $c['pages'][0]['actions'].Add([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'all' } }) } }
            @{ Case = 'actions that are not a list'; Path = 'pages[0].actions'; Pattern = '*list in [[] []]*'
               Change = { param($c) $c['pages'][0]['actions'] = 'click:#a' } }
        ) {
            $config = New-TestConfig
            & $Change $config
            $result = Test-VouchConfig -Config $config
            $result.Errors.Count | Should -Be 1 -Because (($result.Errors | ForEach-Object { "$($_.Path): $($_.Message)" }) -join ' | ')
            $result.Errors[0].Path | Should -Be $Path
            $result.Errors[0].Message | Should -BeLike $Pattern
            $result.Errors[0].Message | Should -Not -Match 'Cannot convert|System\.|Exception'
        }

        It 'warns about unknown keys, and nothing else' {
            $config = New-TestConfig
            $config['colour'] = 'blue'
            $config['output']['sendEmail'] = $true
            $config['pages'][0]['owner'] = 'me'
            $config['pages'][0]['actions'].Add([ordered]@{ type = 'click'; selector = '#a'; delay = 1 })
            $result = Test-VouchConfig -Config $config
            $result.Errors.Count | Should -Be 0
            @($result.Warnings.Path) | Should -Be @('output.sendEmail', 'pages[0].owner', 'pages[0].actions[0].delay', 'colour')
            $result.Warnings[0].Message | Should -BeLike '*ignored*'
        }

        It 'warns when schemaVersion is missing, and reads the file as version 1' {
            $config = New-TestConfig
            $config.Remove('schemaVersion')
            $result = Test-VouchConfig -Config $config
            $result.Errors.Count | Should -Be 0
            $result.Warnings[0].Path | Should -Be 'schemaVersion'
        }

        It 'reports every problem at once' {
            $config = New-TestConfig
            $config['defaults']['settleSeconds'] = 'slow'
            $config['output']['imageFormat'] = 'bmp'
            $config['pages'][0]['url'] = 'intranet'
            (Test-VouchConfig -Config $config).Errors.Count | Should -Be 3
        }

        It 'accepts enum values and keys in any capital letters' {
            $config = New-TestConfig
            $config['output']['imageFormat'] = 'PNG'
            $config['pages'][0]['actions'].Add([ordered]@{ type = 'clicktext'; text = 'Go' })
            (Test-VouchConfig -Config $config).Errors.Count | Should -Be 0
        }

        It 'accepts null as "use the default"' {
            $config = New-TestConfig
            $config['defaults']['settleSeconds'] = $null
            (Test-VouchConfig -Config $config).Errors.Count | Should -Be 0
        }

        It 'checks an object from ConvertFrom-Json the same way' {
            $parsed = '{ "schemaVersion": 1, "output": { "jpegQuality": "high" }, "pages": [] }' | ConvertFrom-Json
            $result = Test-VouchConfig -Config $parsed
            $result.Errors[0].Path | Should -Be 'output.jpegQuality'
        }

        It 'rejects anything that is not an object' {
            (Test-VouchConfig -Config 'text').Errors.Count | Should -Be 1
        }
    }

    Context 'ConvertFrom-VouchJson' {
        It 'keeps date-like text as text and numbers as numbers' {
            $config = ConvertFrom-VouchJson -Text '{ "period": { "from": "2026-07-01" }, "a": 30, "b": 2.5, "c": "30" }'
            $config['period']['from'] | Should -BeOfType [string]
            $config['a'] | Should -BeOfType [long]
            $config['b'] | Should -BeOfType [double]
            $config['c'] | Should -BeOfType [string]
        }

        It 'allows comments and trailing commas' {
            $config = ConvertFrom-VouchJson -Text "{`n  // the port`n  `"a`": 1,`n}"
            $config['a'] | Should -Be 1
        }

        It 'names the line of a syntax error' {
            { ConvertFrom-VouchJson -Text "{`n  `"a`": 1`n  `"b`": 2`n}" } | Should -Throw '*line 3*'
        }

        It 'refuses a key written twice' {
            { ConvertFrom-VouchJson -Text '{ "output": { "dir": "a", "Dir": "b" } }' } | Should -Throw "*'output.Dir' is written twice*"
        }

        It 'refuses an empty file and a file that is not an object' {
            { ConvertFrom-VouchJson -Text '  ' } | Should -Throw '*empty*'
            { ConvertFrom-VouchJson -Text '[1]' } | Should -Throw '*one JSON object*'
        }
    }

    Context 'Import-VouchConfig' {
        It 'resolves relative folders against the configuration file''s folder' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'cfg folder'
            [void](New-Item -ItemType Directory -Path $folder -Force)
            $path = Write-TestConfig -Folder $folder -Json '{
                "schemaVersion": 1,
                "browser": { "profileDir": "profile" },
                "output": { "dir": "..\\out", "logDir": "logs" },
                "report": { "logoPath": "logo.png" },
                "pages": [ { "name": "A", "url": "https://a.example/" } ]
            }'
            $config = Import-VouchConfig -Path $path
            $config['browser']['profileDir'] | Should -Be (Join-Path $folder 'profile')
            $config['output']['dir'] | Should -Be (Join-Path $TestDrive 'out')
            $config['output']['logDir'] | Should -Be (Join-Path $folder 'logs')
            $config['report']['logoPath'] | Should -Be (Join-Path $folder 'logo.png')
        }

        It 'keeps absolute folders and leaves blank ones blank' {
            $path = Write-TestConfig -Json '{ "schemaVersion": 1, "output": { "dir": "C:\\Evidence" }, "pages": [] }'
            $config = Import-VouchConfig -Path $path
            $config['output']['dir'] | Should -Be 'C:\Evidence'
            $config['output']['logDir'] | Should -Be ''
            $config['browser']['profileDir'] | Should -Be ''
        }

        It 'fills in missing settings and page fields' {
            $path = Write-TestConfig -Json '{ "schemaVersion": 1, "output": { "imageFormat": "PNG" }, "pages": [ { "name": "A", "url": "https://a.example/" } ] }'
            $config = Import-VouchConfig -Path $path
            $config['defaults']['settleSeconds'] | Should -Be 2
            $config['report']['period']['label'] | Should -Be ''
            $config['output']['imageFormat'] | Should -BeExactly 'png'
            $config['pages'][0]['id'] | Should -Be 'p001'
            $config['pages'][0]['enabled'] | Should -BeTrue
            $config['pages'][0]['actions'].Count | Should -Be 0
        }

        It 'treats blank text like a missing key when the default is not blank' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'blank dir'
            [void](New-Item -ItemType Directory -Path $folder -Force)
            $blank = Import-VouchConfig -Path (Write-TestConfig -Folder $folder -Json '{ "schemaVersion": 1, "output": { "dir": "  " }, "report": { "title": "" }, "pages": [] }')
            $missing = Import-VouchConfig -Path (Write-TestConfig -Folder $folder -Json '{ "schemaVersion": 1, "pages": [] }')
            $blank['output']['dir'] | Should -Be $missing['output']['dir']
            $blank['output']['dir'] | Should -Be (Join-Path $folder 'reports')
            $blank['report']['title'] | Should -Be 'Audit Evidence Report'
            # A blank default stays blank: "" is a real choice there.
            $blank['report']['classification'] | Should -Be ''
            $blank['output']['logDir'] | Should -Be ''
        }

        It 'reads a configuration given as a PowerShell drive path (TestDrive:\)' {
            $path = Write-TestConfig -Json '{ "schemaVersion": 1, "output": { "dir": "out", "logDir": "logs" }, "pages": [] }'
            $drivePath = 'TestDrive:\' + (Split-Path -Path $path -Leaf)
            $config = Import-VouchConfig -Path $drivePath
            $config['output']['dir'] | Should -Be (Join-Path $TestDrive 'out')
            Get-RunLogDirectory -BoundParameters @{} -LogDir 'C:\D' -ConfigPath $drivePath | Should -Be (Join-Path $TestDrive 'logs')
        }

        It 'lists every problem with its place in the file and launches nothing' {
            $path = Write-TestConfig -Json '{ "schemaVersion": 1, "browser": { "debugPort": "x" }, "pages": [ { "name": "A" } ] }'
            $output = & { try { Import-VouchConfig -Path $path } catch { "THROWN: $($_.Exception.Message)" } } 6>&1 | Out-String
            $output | Should -Match '2 problem\(s\)'
            $output | Should -Match 'browser\.debugPort: must be a whole number'
            $output | Should -Match 'pages\[0\]\.url: is missing'
            $output | Should -Match 'THROWN: Fix .* Nothing was launched'
            $output | Should -Not -Match 'Cannot convert'
        }

        It 'explains a JSON syntax error' {
            $path = Write-TestConfig -Json "{`n `"schemaVersion`": 1`n `"pages`": []`n}"
            { Import-VouchConfig -Path $path } | Should -Throw '*not valid JSON*line 3*Nothing was launched*'
        }

        It 'says so when the file is missing' {
            { Import-VouchConfig -Path (Join-Path $TestDrive 'none.json') } | Should -Throw '*Configuration file not found*'
        }

        It 'loads the shipped captures.sample.json without errors or notes' {
            $sample = Join-Path -Path $PSScriptRoot -ChildPath '..\captures.sample.json'
            $parsed = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($sample))
            $result = Test-VouchConfig -Config $parsed
            $result.Errors.Count | Should -Be 0
            $result.Warnings.Count | Should -Be 0
            $config = Import-VouchConfig -Path $sample 6>$null
            $config['pages'].Count | Should -BeGreaterOrEqual 3
            @($config['pages'] | Where-Object { $_['actions'].Count -gt 2 -and $_['overrides'].Count -gt 0 }).Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'CSV to configuration and back' {
        It 'gives the same definitions as Import-CaptureDefinition for <File>' -ForEach @(
            @{ File = 'captures.template.csv' }, @{ File = 'captures.sample.csv' }
        ) {
            $csv = Join-Path -Path $PSScriptRoot -ChildPath "..\$File"
            $expected = Import-CaptureDefinition -Path $csv 6>$null
            $config = ConvertTo-VouchConfig -Path $csv 6>$null

            # Through JSON text, as the Designer saves and reopens it.
            $reloaded = ConvertFrom-VouchJson -Text ($config | ConvertTo-Json -Depth 20)
            $check = Test-VouchConfig -Config $reloaded
            $check.Errors.Count | Should -Be 0
            $check.Warnings.Count | Should -Be 0
            $reloaded['pages'].Count | Should -Be $expected.Count

            for ($i = 0; $i -lt $expected.Count; $i++) {
                $want = $expected[$i]
                $got = ConvertTo-CaptureDefinition -Page $reloaded['pages'][$i] -Index ($i + 1)
                $because = "row $($i + 1) ($($want.Name))"
                $got.Index | Should -Be $want.Index -Because $because
                $got.Id | Should -Be $want.Id -Because $because
                $got.Name | Should -BeExactly $want.Name -Because $because
                $got.Url | Should -BeExactly $want.Url -Because $because
                $got.Notes | Should -BeExactly $want.Notes -Because $because
                $got.ScrollFullPage | Should -Be $want.ScrollFullPage -Because $because
                $got.Steps.Count | Should -Be $want.Steps.Count -Because $because
                for ($j = 0; $j -lt $want.Steps.Count; $j++) {
                    $got.Steps[$j].Verb | Should -Be $want.Steps[$j].Verb -Because $because
                    $got.Steps[$j].Argument | Should -Be $want.Steps[$j].Argument -Because $because
                }
                # StepsText may differ in spacing and capitals, never in meaning.
                $errors = [System.Collections.Generic.List[string]]::new()
                $reparsed = ConvertTo-StepList -StepsText $got.StepsText -LineNumber 1 -Errors $errors
                $errors.Count | Should -Be 0
                @($reparsed | ForEach-Object { "$($_.Verb)|$($_.Argument)" }) | Should -Be @($want.Steps | ForEach-Object { "$($_.Verb)|$($_.Argument)" })
                (Test-LegacyActionList -Actions @($got.Actions)).Supported | Should -BeTrue -Because $because
            }
        }

        It 'gives CSV rows the same shape as configuration pages' {
            $csv = Join-Path -Path $PSScriptRoot -ChildPath '..\captures.sample.csv'
            $row = (Import-CaptureDefinition -Path $csv)[2]
            $row.Id | Should -Be 'p003'
            $row.Enabled | Should -BeTrue
            @($row.Actions | ForEach-Object { $_['type'] }) | Should -Be @('click', 'wait', 'capture')
            $row.Actions[2]['scroll']['mode'] | Should -Be 'none'
        }
    }

    Context 'ConvertTo-CaptureDefinition' {
        It 'appends a capture to a page that has none' {
            $definition = ConvertTo-CaptureDefinition -Page ([ordered]@{ name = 'A'; url = 'https://a/'; actions = @([ordered]@{ type = 'click'; selector = '#x' }) }) -Index 4
            @($definition.Actions | ForEach-Object { $_['type'] }) | Should -Be @('click', 'capture')
            $definition.ScrollFullPage | Should -BeFalse
            $definition.Id | Should -Be 'p004'
            $definition.Enabled | Should -BeTrue
            $definition.StepsText | Should -Be 'click:#x'
            $definition.Steps[0].Text | Should -Be 'click:#x'
        }

        It 'maps a final auto-scroll capture to ScrollFullPage' {
            $page = [ordered]@{ id = 'x'; name = 'A'; url = 'https://a/'; enabled = $false
                actions = @([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'Auto' } }) }
            $definition = ConvertTo-CaptureDefinition -Page $page -Index 1
            $definition.ScrollFullPage | Should -BeTrue
            $definition.Actions[0]['scroll']['mode'] | Should -BeExactly 'auto'
            $definition.Enabled | Should -BeFalse
            $definition.Id | Should -Be 'x'
        }
    }

    Context 'ConvertTo-StepText' {
        It 'writes <Expected>' -ForEach @(
            @{ Expected = 'click:#a; clicktext:Audit Log; wait:2.5'
               Actions = @(@{ type = 'click'; selector = '#a' }, @{ type = 'clickText'; text = 'Audit Log' }, @{ type = 'wait'; seconds = 2.5 }, @{ type = 'capture'; label = '' }) }
            @{ Expected = ''; Actions = @(@{ type = 'capture'; label = '' }) }
            @{ Expected = 'wait:3'; Actions = @(@{ type = 'wait'; seconds = [long]3 }, @{ type = 'capture' }) }
            @{ Expected = 'pause:Sign in; capture:Before; waitfor:#t; capture:After'
               Actions = @(@{ type = 'pause'; message = 'Sign in' }, @{ type = 'capture'; label = 'Before' }, @{ type = 'waitFor'; selector = '#t' }, @{ type = 'capture'; label = 'After' }) }
        ) {
            ConvertTo-StepText -Actions $Actions | Should -BeExactly $Expected
        }

        Context 'on a machine whose decimal separator is a comma (de-DE)' {
            BeforeAll {
                $originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
                [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
            }
            AfterAll { [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture }

            It 'still writes wait:2.5' {
                ConvertTo-StepText -Actions @(@{ type = 'wait'; seconds = 2.5 }) | Should -Be 'wait:2.5'
            }
        }
    }

    Context 'Test-LegacyActionList' {
        It 'accepts <Case>' -ForEach @(
            @{ Case = 'steps then one capture'; Actions = @('click', 'clickText', 'wait', 'capture:none') }
            @{ Case = 'one scrolling capture'; Actions = @('capture:auto') }
        ) {
            $list = foreach ($entry in $Actions) {
                $type, $mode = $entry.Split(':')
                if ($type -eq 'capture') { [ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = $mode; as = 'segments' } } }
                else { [ordered]@{ type = $type } }
            }
            (Test-LegacyActionList -Actions @($list)).Supported | Should -BeTrue
        }

        It 'refuses <Case> with a reason' -ForEach @(
            @{ Case = 'two captures'; Pattern = '*2 captures*'
               Actions = @(@{ type = 'capture'; scroll = @{ mode = 'none'; as = 'segments' } }, @{ type = 'capture'; scroll = @{ mode = 'none'; as = 'segments' } }) }
            @{ Case = 'a waitFor'; Pattern = '*"waitFor" action*'
               Actions = @(@{ type = 'waitFor'; selector = '#a' }, @{ type = 'capture'; scroll = @{ mode = 'none'; as = 'segments' } }) }
            @{ Case = 'a pause'; Pattern = '*"pause" action*'
               Actions = @(@{ type = 'pause' }, @{ type = 'capture'; scroll = @{ mode = 'none'; as = 'segments' } }) }
            @{ Case = 'scrolling a chosen area'; Pattern = '*scroll mode "area"*'
               Actions = @(@{ type = 'capture'; scroll = @{ mode = 'area'; selector = '#m'; as = 'segments' } }) }
            @{ Case = 'scroll mode page'; Pattern = '*scroll mode "page"*'
               Actions = @(@{ type = 'capture'; scroll = @{ mode = 'page'; as = 'segments' } }) }
            @{ Case = 'one tall image'; Pattern = '*"as": "single"*'
               Actions = @(@{ type = 'capture'; scroll = @{ mode = 'auto'; as = 'single' } }) }
            @{ Case = 'a click after the capture'; Pattern = '*actions after the capture*'
               Actions = @(@{ type = 'capture'; scroll = @{ mode = 'none'; as = 'segments' } }, @{ type = 'click'; selector = '#a' }) }
        ) {
            $result = Test-LegacyActionList -Actions $Actions
            $result.Supported | Should -BeFalse
            $result.Reason | Should -BeLike $Pattern
            $result.Reason | Should -BeLike '*cannot run yet*'
        }
    }

    Context 'Select-VouchPage (-Only)' {
        BeforeAll {
            function New-TestDefinitions {
                @(
                    [pscustomobject]@{ Index = 1; Id = 'p001'; Name = 'Users'; Enabled = $true }
                    [pscustomobject]@{ Index = 2; Id = 'p002'; Name = 'Roles'; Enabled = $false }
                    [pscustomobject]@{ Index = 3; Id = 'p003'; Name = 'Audit, log'; Enabled = $true }
                )
            }
        }

        It 'runs every enabled page when -Only is empty, numbered from 1' {
            $selected = Select-VouchPage -Definitions (New-TestDefinitions) -Only @()
            @($selected.Id) | Should -Be @('p001', 'p003')
            @($selected.Index) | Should -Be @(1, 2)
        }

        It 'selects by id, in file order, ignoring capitals' {
            $selected = Select-VouchPage -Definitions (New-TestDefinitions) -Only @('P003', 'p001')
            @($selected.Id) | Should -Be @('p001', 'p003')
        }

        It 'selects by name, and runs a switched-off page when it is named' {
            $selected = Select-VouchPage -Definitions (New-TestDefinitions) -Only @('roles')
            @($selected.Id) | Should -Be @('p002')
            $selected[0].Index | Should -Be 1
        }

        It 'reads a name with a comma as a name, and "p001,p002" as two ids' {
            @((Select-VouchPage -Definitions (New-TestDefinitions) -Only 'Audit, log').Id) | Should -Be @('p003')
            @((Select-VouchPage -Definitions (New-TestDefinitions) -Only 'p001,p002').Id) | Should -Be @('p001', 'p002')
        }

        It 'stops on an id or name that matches no page, listing the pages' {
            { Select-VouchPage -Definitions (New-TestDefinitions) -Only @('p001', 'p009') } |
                Should -Throw "*no page has the id or name 'p009'*p001 (Users)*"
        }
    }

    Context 'Get-PageSettings' {
        BeforeAll {
            $run = Resolve-RunSettings -BoundParameters @{} -Config $null -Defaults @{
                NavigationTimeoutSec = 30; SettleSeconds = [double]2; ScrollSettleSeconds = [double]1; MaxScrollSegments = 30
            }
            $config = Get-DefaultVouchConfig
            $config['defaults']['zoomPercent'] = 90
            $page = [pscustomobject]@{
                Overrides = [ordered]@{ settleSeconds = 0.5; navigationTimeoutSec = [long]60; captureArea = 'page'; waitFor = '' }
            }
        }

        It 'applies the page overrides to its timing settings' {
            $settings = Get-PageSettings -Settings $run -Definition $page -Config $config
            $settings.SettleSeconds | Should -Be 0.5
            $settings.SettleSeconds | Should -BeOfType [double]
            $settings.NavigationTimeoutSec | Should -Be 60
            $settings.NavigationTimeoutSec | Should -BeOfType [int]
            $settings.MaxScrollSegments | Should -Be 30
        }

        It 'carries the page-level settings: page override > config defaults > schema default' {
            $settings = Get-PageSettings -Settings $run -Definition $page -Config $config
            $settings.CaptureArea | Should -Be 'page'
            $settings.ZoomPercent | Should -Be 90
            $settings.OnNotReady | Should -Be 'warn'
            $settings.WaitFor | Should -Be ''
            $settings.PromptTimeoutSec | Should -Be 300
        }

        It 'lets a value typed on the command line beat the page override' {
            $settings = Get-PageSettings -Settings $run -Definition $page -Config $config -BoundNames 'SettleSeconds'
            $settings.SettleSeconds | Should -Be 2
            $settings.NavigationTimeoutSec | Should -Be 60
        }

        It 'leaves the run settings alone' {
            [void](Get-PageSettings -Settings $run -Definition $page -Config $config)
            $run.SettleSeconds | Should -Be 2
        }

        It 'works for a CSV row without a configuration' {
            $row = [pscustomobject]@{ Overrides = [ordered]@{} }
            $settings = Get-PageSettings -Settings $run -Definition $row -Config $null
            $settings.SettleSeconds | Should -Be 2
            $settings.CaptureArea | Should -Be 'screen'
        }
    }

    Context 'Get-InactiveConfigSetting' {
        It 'lists nothing for the defaults' {
            (Get-InactiveConfigSetting -Config (Get-DefaultVouchConfig)).Count | Should -Be 0
        }

        It 'lists each setting that is set but not applied yet, once' {
            $config = Get-DefaultVouchConfig
            $config['defaults']['captureArea'] = 'window'
            $config['output']['zip']['enabled'] = $true
            $config['output']['embedImages'] = $false
            $config['report']['title'] = 'Q3'
            $config['report']['period']['label'] = 'Q3 2026'
            $config['defaults']['settleSeconds'] = 5
            foreach ($n in 1, 2) {
                $config['pages'].Add([ordered]@{ overrides = [ordered]@{ zoomPercent = 80; settleSeconds = 1 } })
            }
            $inactive = Get-InactiveConfigSetting -Config $config
            $inactive | Should -Be @(
                'defaults.captureArea', 'output.embedImages', 'output.zip.enabled', 'report.title', 'report.period.label', 'page overrides: zoomPercent')
        }
    }

    Context 'Get-RunLogDirectory' {
        BeforeAll {
            $folder = Join-Path -Path $TestDrive -ChildPath 'logcfg'
            [void](New-Item -ItemType Directory -Path $folder -Force)
            $path = Write-TestConfig -Folder $folder -Json '{ "schemaVersion": 1, "output": { "logDir": "logs" } }'
        }

        It 'reads output.logDir relative to the configuration file' {
            Get-RunLogDirectory -BoundParameters @{ ConfigPath = $path } -LogDir '' -ConfigPath $path | Should -Be (Join-Path $folder 'logs')
        }

        It 'lets -LogDir typed on the command line win' {
            Get-RunLogDirectory -BoundParameters @{ LogDir = 'C:\L' } -LogDir 'C:\L' -ConfigPath $path | Should -Be 'C:\L'
        }

        It 'falls back to -LogDir without a configuration or with an unreadable one' {
            Get-RunLogDirectory -BoundParameters @{} -LogDir 'C:\D' -ConfigPath '' | Should -Be 'C:\D'
            $broken = Write-TestConfig -Json '{ nope'
            Get-RunLogDirectory -BoundParameters @{} -LogDir '' -ConfigPath $broken | Should -Be ''
        }
    }

    Context 'Get-VouchFunctionSource' {
        It 'loads functions from several files' {
            $extra = Join-Path -Path $TestDrive -ChildPath 'extra.ps1'
            Set-Content -LiteralPath $extra -Value "`$script:ExtraState = 1`nfunction Get-ExtraThing { 42 }`nWrite-Host 'not loaded'"
            $source = Get-VouchFunctionSource -Path $script:VouchPath, $extra
            $source | Should -Match 'function Get-ExtraThing'
            $source | Should -Match 'function Invoke-Main'
            $source | Should -Match '\$script:ExtraState = 1'
            $source | Should -Not -Match 'not loaded'
        }
    }
}

Describe 'Get-ScreenCapture' -Tag 'Desktop' {
    # Reads the pixels of the primary display into memory only; nothing is saved.
    BeforeAll {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        Initialize-NativeInterop
    }

    It 'returns a JPEG byte array' {
        $bytes = Get-ScreenCapture -Format jpeg -Quality 50
        , $bytes | Should -BeOfType [byte[]]
        $bytes[0..1] | Should -Be @(0xFF, 0xD8)
    }

    It 'returns a PNG byte array at full primary-screen resolution' {
        $bytes = Get-ScreenCapture -Format png
        $bytes[1..3] | Should -Be @(0x50, 0x4E, 0x47)
        $stream = [System.IO.MemoryStream]::new($bytes)
        $image = [System.Drawing.Image]::FromStream($stream)
        try {
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $image.Width | Should -Be $bounds.Width
            $image.Height | Should -Be $bounds.Height
        }
        finally { $image.Dispose(); $stream.Dispose() }
    }
}
