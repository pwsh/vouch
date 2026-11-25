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
            CaptureArea = 'screen'; ZoomPercent = 100
            NoPrompt = [switch]$false; EventLogPath = ''; TabId = ''
            Account = ''; ReportTitle = ''; Classification = ''; LogoPath = ''; CompanyName = ''; CompanyDetails = ''
            Description = ''; Origin = ''; GeneratedBy = ''; PeriodFrom = ''; PeriodTo = ''; PeriodLabel = ''
            NoIndex = [switch]$false; LinkImages = [switch]$false; Zip = [switch]$false; ZipName = ''; OpenReport = [switch]$false
        }
        $config = '{
            "browser":  { "profileDir": "C:\\cfg-profile", "debugPort": 9333, "keepBrowserOpen": true },
            "defaults": { "navigationTimeoutSec": 45, "settleSeconds": 0.5, "maxScrollSegments": 12, "captureArea": "page", "zoomPercent": 80 },
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
        $settings.CaptureArea | Should -Be 'page'
        $settings.ZoomPercent | Should -Be 80
        $settings.ZoomPercent | Should -BeOfType [int]
    }

    It 'takes -CaptureArea and -ZoomPercent typed on the command line over the config' {
        $settings = Resolve-RunSettings -BoundParameters @{ CaptureArea = 'window'; ZoomPercent = 150 } -Defaults $defaults -Config $config
        $settings.CaptureArea | Should -Be 'window'
        $settings.ZoomPercent | Should -Be 150
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
            # Get-PageCaptureMode would quietly read these as screen / 100%, so the file must refuse them.
            @{ Case = 'an unknown capture area'; Path = 'defaults.captureArea'; Pattern = '*"screen", "window", "page"*found "full"*'
               Change = { param($c) $c['defaults']['captureArea'] = 'full' } }
            @{ Case = 'an unknown page capture area'; Path = 'pages[0].overrides.captureArea'; Pattern = '*"screen", "window", "page"*found "full"*'
               Change = { param($c) $c['pages'][0]['overrides']['captureArea'] = 'full' } }
            @{ Case = 'a zoom above the range'; Path = 'defaults.zoomPercent'; Pattern = '*from 25 to 500*found 600*'
               Change = { param($c) $c['defaults']['zoomPercent'] = 600 } }
            @{ Case = 'a page zoom above the range'; Path = 'pages[0].overrides.zoomPercent'; Pattern = '*from 25 to 500*found 600*'
               Change = { param($c) $c['pages'][0]['overrides']['zoomPercent'] = 600 } }
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

    Context 'Every setting of the file now works' {
        It 'has no list of settings without effect any more' {
            Get-Command -Name Get-InactiveConfigSetting -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $script:VouchPath -Raw) | Should -Not -Match 'does not apply these configuration settings'
        }
    }

    Context 'The account: defaults.account, a page''s own, and -Account' {
        BeforeAll {
            $config = Get-DefaultVouchConfig
            $config['defaults']['account'] = 'svc-audit@example.com'
            $run = Resolve-RunSettings -BoundParameters @{} -Config $config -Defaults @{ Account = ''; SettleSeconds = [double]2 }
            $own = [pscustomobject]@{ Overrides = [ordered]@{ account = 'admin@example.com' } }
            $plain = [pscustomobject]@{ Overrides = [ordered]@{} }
        }

        It 'gives a page the run''s account, or its own' {
            $run.Account | Should -Be 'svc-audit@example.com'
            (Get-PageSettings -Settings $run -Definition $plain -Config $config).Account | Should -Be 'svc-audit@example.com'
            (Get-PageSettings -Settings $run -Definition $own -Config $config).Account | Should -Be 'admin@example.com'
        }

        It 'lets -Account typed on the command line beat the file and the page' {
            $typed = Resolve-RunSettings -BoundParameters @{ Account = 'typed@example.com' } -Config $config -Defaults @{ Account = '' }
            $typed.Account | Should -Be 'typed@example.com'
            (Get-PageSettings -Settings $typed -Definition $own -Config $config -BoundNames 'Account').Account | Should -Be 'typed@example.com'
        }

        It 'puts it on the item and so into each image''s metadata' {
            $item = New-CaptureItem -Definition ([pscustomobject]@{ Index = 1; Name = 'A'; Url = 'https://a/'; Notes = ''; StepsText = ''; ScrollFullPage = $false })
            $item.Account | Should -Be ''
            @($item.PSObject.Properties.Name)[-1] | Should -Be 'Account'
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

Describe 'Get-CaptureFileName' {
    It 'keeps today''s names for a page''s first capture' {
        Get-CaptureFileName -Index 1 -Name 'Users & roles' -SegmentIndex 2 -Extension 'jpg' | Should -Be '001_Users_roles_seg02.jpg'
        Get-CaptureFileName -Index 12 -Name 'A' -SegmentIndex 1 -Extension 'png' -CaptureNumber 1 | Should -Be '012_A_seg01.png'
    }

    It 'adds _c02, _c03 ... for later captures of the same page' {
        Get-CaptureFileName -Index 3 -Name 'Tabs' -SegmentIndex 1 -Extension 'jpg' -CaptureNumber 2 | Should -Be '003_Tabs_c02_seg01.jpg'
        Get-CaptureFileName -Index 3 -Name 'Tabs' -SegmentIndex 4 -Extension 'jpg' -CaptureNumber 11 | Should -Be '003_Tabs_c11_seg04.jpg'
    }
}

Describe 'Capture sets in the report and the JSON summary' {
    BeforeAll {
        $run = [pscustomobject]@{
            StartTime = '2026-09-23 10:00:00'; EndTime = '2026-09-23 10:05:00'; TimeZone = 'UTC'
            Computer = 'PC'; User = 'DOM\user'; OperatingSystem = 'Windows'; EdgeVersion = 'Edg/1'
            BrowserInstance = 'test'; ToolVersion = 'test'; CsvPath = 'c.json'; ImageFormat = 'jpeg'
            ImageDescription = 'JPEG'; ScreenResolution = '1x1'; Total = 1; OkCount = 1
            WarnCount = 0; FailCount = 0; CaptureCount = 3
        }
        function New-TestItem([object[]]$Captures) {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($capture in $Captures) { $list.Add($capture) }
            $stepLog = [System.Collections.Generic.List[object]]::new()
            $stepLog.Add([pscustomobject]@{ Text = 'pause:Sign in'; Ok = $true; Message = 'skipped: pause is not available yet' })
            [pscustomobject]@{
                Index = 1; Name = 'Tabs'; Url = 'https://a/'; FinalUrl = 'https://a/'; Notes = ''; StepsText = ''
                ScrollFullPage = $false; ScrollArea = ''; Status = 'OK'; HttpStatus = 200
                Details = [System.Collections.Generic.List[string]]::new(); StepLog = $stepLog; Captures = $list
            }
        }
        $multi = New-TestItem @(
            (New-CaptureRecord -Bytes ([byte[]](1)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FileName '001_Tabs_seg01.jpg' -Label 'General')
            (New-CaptureRecord -Bytes ([byte[]](2)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 2 -FileName '001_Tabs_c02_seg01.jpg' -CaptureNumber 2 -Label 'Audit <log>')
            (New-CaptureRecord -Bytes ([byte[]](3)) -Url 'https://a/' -SegmentIndex 2 -SegmentCount 2 -FileName '001_Tabs_c02_seg02.jpg' -CaptureNumber 2 -Label 'Audit <log>'))
        $script:MultiHtml = New-HtmlReport -Items @($multi) -Run $run
        $script:MultiJson = ConvertTo-RunSummaryJson -Items @($multi) -Run $run -ReportPath 'C:\r.html' -ExitCode 0 | ConvertFrom-Json
        $single = New-TestItem @((New-CaptureRecord -Bytes ([byte[]](1)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FileName '001_Tabs_seg01.jpg'))
        $script:SingleHtml = New-HtmlReport -Items @($single) -Run $run
    }

    It 'names each capture set, in the order taken, with its label' {
        $captions = @([regex]::Matches($script:MultiHtml, '<figcaption><strong>([^<]*)</strong>') | ForEach-Object { $_.Groups[1].Value })
        $captions | Should -Be @('Capture 1: General', 'Capture 2: Audit &lt;log&gt;', 'Capture 2: Audit &lt;log&gt;')
    }

    It 'leaves a page with one unlabelled capture as it was' {
        $script:SingleHtml | Should -Not -Match '<figcaption><strong>'
        $script:SingleHtml | Should -Match 'alt="Tabs screenshot 1 of 1"'
    }

    It 'shows a note on a step that ran without doing its work' {
        $script:MultiHtml | Should -Match '<code>pause:Sign in</code> &mdash; skipped: pause is not available yet'
    }

    It 'carries the capture number and label into the JSON summary' {
        @($script:MultiJson.Items[0].Captures.CaptureNumber) | Should -Be @(1, 2, 2)
        $script:MultiJson.Items[0].Captures[1].Label | Should -Be 'Audit <log>'
    }
}

Describe 'Browser-internal tabs' {
    It 'recognises <Url> as internal: <Internal>' -ForEach @(
        @{ Url = 'edge://sync-confirmation-dialog/'; Internal = $true }
        @{ Url = 'chrome://newtab/'; Internal = $true }
        @{ Url = 'devtools://devtools/bundled/inspector.html'; Internal = $true }
        @{ Url = 'edge-extension://abc/popup.html'; Internal = $true }
        @{ Url = 'chrome-extension://abc/options.html'; Internal = $true }
        @{ Url = 'about:blank'; Internal = $false }
        @{ Url = 'https://intranet.example/edge://x'; Internal = $false }
    ) {
        Test-InternalPageTarget -Target ([pscustomobject]@{ url = $Url }) | Should -Be $Internal
    }

    It 'classifies <Url> as <Kind>, the one rule both tab decisions use' -ForEach @(
        @{ Url = 'edge://sync-confirmation-dialog/'; Kind = 'browser' }
        @{ Url = 'CHROME://newtab/'; Kind = 'browser' }
        @{ Url = 'devtools://devtools/bundled/inspector.html'; Kind = 'tool' }
        @{ Url = 'edge-extension://abc/popup.html'; Kind = 'tool' }
        @{ Url = 'chrome-extension://abc/options.html'; Kind = 'tool' }
        @{ Url = 'about:blank'; Kind = 'web' }
        @{ Url = 'https://intranet.example/edge://x'; Kind = 'web' }
    ) {
        Get-PageTargetKind -Target ([pscustomobject]@{ url = $Url }) | Should -Be $Kind
        Get-PageTargetKind -Target ([pscustomobject]@{ id = 'no url' }) | Should -Be 'web'
    }

    It 'Get-CdpPageTarget skips the sync dialog Edge lists first' {
        Mock Get-DevToolsTargetList {
            [pscustomobject]@{ id = 'sync'; type = 'page'; url = 'edge://sync-confirmation-dialog/'; webSocketDebuggerUrl = 'ws://x/sync' }
            [pscustomobject]@{ id = 'worker'; type = 'service_worker'; url = 'https://a/sw.js'; webSocketDebuggerUrl = 'ws://x/sw' }
            [pscustomobject]@{ id = 'tab'; type = 'page'; url = 'about:blank'; webSocketDebuggerUrl = 'ws://x/tab' }
        }
        (Get-CdpPageTarget -Port 9 -WaitSeconds 0).id | Should -Be 'tab'
    }

    It 'Close-OtherPageTargets closes Edge''s own tabs but leaves DevTools and extensions alone' {
        Mock Get-DevToolsTargetList {
            [pscustomobject]@{ id = 'sync'; type = 'page'; url = 'edge://sync-confirmation-dialog/' }
            [pscustomobject]@{ id = 'tab'; type = 'page'; url = 'https://a/' }
            [pscustomobject]@{ id = 'other'; type = 'page'; url = 'about:blank' }
            [pscustomobject]@{ id = 'tools'; type = 'page'; url = 'devtools://devtools/inspector.html' }
            [pscustomobject]@{ id = 'ext'; type = 'page'; url = 'edge-extension://abc/page.html' }
        }
        $script:Closed = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod { $script:Closed.Add(($Uri -split '/')[-1]) }
        Close-OtherPageTargets -Port 9 -KeepId 'tab'
        @($script:Closed) | Should -Be @('sync', 'other')
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

Describe 'Capture area: window crop' {
    BeforeAll { Add-Type -AssemblyName System.Drawing }

    It 'keeps a window that is fully on the screen as it is (<Case>)' -ForEach @(
        @{ Case = 'at the origin'; Window = @(0, 0, 1600, 900); Screen = @(0, 0, 2560, 1440); Expected = @(0, 0, 1600, 900) }
        @{ Case = 'inside'; Window = @(100, 50, 800, 600); Screen = @(0, 0, 1920, 1080); Expected = @(100, 50, 800, 600) }
    ) {
        $rect = Get-WindowCaptureRectangle -WindowBounds ([System.Drawing.Rectangle]::new($Window[0], $Window[1], $Window[2], $Window[3])) `
            -ScreenBounds ([System.Drawing.Rectangle]::new($Screen[0], $Screen[1], $Screen[2], $Screen[3]))
        @($rect.X, $rect.Y, $rect.Width, $rect.Height) | Should -Be $Expected
    }

    It 'clips a window that hangs over the edges of the screen' {
        $rect = Get-WindowCaptureRectangle -WindowBounds ([System.Drawing.Rectangle]::new(-50, -20, 800, 600)) `
            -ScreenBounds ([System.Drawing.Rectangle]::new(0, 0, 1920, 1080))
        @($rect.X, $rect.Y, $rect.Width, $rect.Height) | Should -Be @(0, 0, 750, 580)
        $rect = Get-WindowCaptureRectangle -WindowBounds ([System.Drawing.Rectangle]::new(1500, 900, 800, 600)) `
            -ScreenBounds ([System.Drawing.Rectangle]::new(0, 0, 1920, 1080))
        @($rect.X, $rect.Y, $rect.Width, $rect.Height) | Should -Be @(1500, 900, 420, 180)
    }

    It 'gives coordinates inside the screen image when the primary display does not start at 0,0' {
        $rect = Get-WindowCaptureRectangle -WindowBounds ([System.Drawing.Rectangle]::new(-1000, 100, 500, 400)) `
            -ScreenBounds ([System.Drawing.Rectangle]::new(-1920, 0, 1920, 1080))
        @($rect.X, $rect.Y, $rect.Width, $rect.Height) | Should -Be @(920, 100, 500, 400)
    }

    It 'returns nothing for a window that is <Case>' -ForEach @(
        @{ Case = 'on another monitor'; Window = @(2000, 0, 800, 600) }
        @{ Case = 'minimised (parked at -32000)'; Window = @(-32000, -32000, 160, 28) }
        @{ Case = 'empty'; Window = @(10, 10, 0, 0) }
        @{ Case = 'touching the edge only'; Window = @(1920, 0, 800, 600) }
    ) {
        Get-WindowCaptureRectangle -WindowBounds ([System.Drawing.Rectangle]::new($Window[0], $Window[1], $Window[2], $Window[3])) `
            -ScreenBounds ([System.Drawing.Rectangle]::new(0, 0, 1920, 1080)) | Should -BeNullOrEmpty
    }
}

Describe 'Page zoom: the device metrics override' {
    It 'zooms <Percent>% from a <Width>x<Height> window to a <ExpectedWidth>x<ExpectedHeight> layout' -ForEach @(
        @{ Percent = 50; Width = 1256; Height = 708; ExpectedWidth = 2512; ExpectedHeight = 1416 }
        @{ Percent = 80; Width = 1256; Height = 708; ExpectedWidth = 1570; ExpectedHeight = 885 }
        @{ Percent = 125; Width = 5112; Height = 1308; ExpectedWidth = 4090; ExpectedHeight = 1046 }
        @{ Percent = 150; Width = 1256; Height = 708; ExpectedWidth = 837; ExpectedHeight = 472 }
    ) {
        $metrics = Get-ZoomDeviceMetrics -Width $Width -Height $Height -ZoomPercent $Percent
        $metrics.width | Should -Be $ExpectedWidth
        $metrics.height | Should -Be $ExpectedHeight
        $metrics.scale | Should -Be ($Percent / 100)
        # Measured in a headed window: only this combination fills the window.
        $metrics.deviceScaleFactor | Should -Be 0
        $metrics.mobile | Should -BeFalse
        $metrics.dontSetVisibleSize | Should -BeTrue
        $metrics | Should -BeOfType [hashtable]
    }

    It 'reads the capture area and zoom of a page, defaulting to the screen at 100%' {
        $mode = Get-PageCaptureMode -Settings ([pscustomobject]@{ CaptureArea = 'Page'; ZoomPercent = 150 })
        $mode.Area | Should -BeExactly 'page'
        $mode.ZoomPercent | Should -Be 150
        $mode = Get-PageCaptureMode -Settings ([pscustomobject]@{ CaptureArea = ''; ZoomPercent = 0 })
        $mode.Area | Should -Be 'screen'
        $mode.ZoomPercent | Should -Be 100
        (Get-PageCaptureMode -Settings ([pscustomobject]@{ SettleSeconds = 1 })).Area | Should -Be 'screen'
    }

    It 'sets the zoom from the unzoomed window and records it only once it applied' {
        $script:Sent = [System.Collections.Generic.List[object]]::new()
        Mock Send-CdpCommand { $script:Sent.Add([pscustomobject]@{ Method = $Method; Params = $Params }) }
        Mock Invoke-CdpEval { [pscustomobject]@{ width = 1256; height = 708 } }
        Set-PageZoom -Percent 150
        @($script:Sent.Method) | Should -Be @('Emulation.clearDeviceMetricsOverride', 'Emulation.setDeviceMetricsOverride')
        $script:Sent[1].Params.width | Should -Be 837
        $script:PageZoomPercent | Should -Be 150
        Clear-PageZoom
        $script:PageZoomPercent | Should -Be 100
        $script:Sent[-1].Method | Should -Be 'Emulation.clearDeviceMetricsOverride'
    }

    It 'leaves the zoom at 100 when it cannot be applied' {
        Mock Send-CdpCommand { if ($Method -eq 'Emulation.setDeviceMetricsOverride') { throw 'boom' } }
        Mock Invoke-CdpEval { [pscustomobject]@{ width = 1256; height = 708 } }
        $script:PageZoomPercent = 80
        { Set-PageZoom -Percent 150 } | Should -Throw '*boom*'
        $script:PageZoomPercent | Should -Be 100
    }

    It 'keeps the zoom recorded when removing it fails, because the page is still zoomed' {
        Mock Send-CdpCommand { throw 'connection lost' }
        $script:PageZoomPercent = 150
        { Clear-PageZoom } | Should -Throw '*connection lost*'
        $script:PageZoomPercent | Should -Be 150
        $script:PageZoomPercent = 100
    }

    It 'turns a zoom a reconnect could not set again into one warning on the page' {
        $item = [pscustomobject]@{ Status = 'OK'; Details = [System.Collections.Generic.List[string]]::new() }
        Add-ZoomLostDetail -Item $item
        $item.Status | Should -Be 'OK'
        $script:PageZoomLost = 150
        Add-ZoomLostDetail -Item $item
        Add-ZoomLostDetail -Item $item
        $item.Status | Should -Be 'WARNING'
        @($item.Details) | Should -Be @('The connection to Edge was lost and restored during this page, but the page zoom of 150% could not be set again; any images of this page taken after that show it at 100%.')
        $script:PageZoomLost | Should -Be 0
    }

    It 'flags a zoom that a reconnect could not set again' {
        Mock Close-CdpSocket { }
        Mock Connect-CdpSocket { }
        Mock Set-PageZoom { $script:PageZoomPercent = 100; throw 'override refused' }
        $script:PageZoomPercent = 150
        $script:PageZoomLost = 0
        $script:CdpWebSocketUrl = 'ws://127.0.0.1:9/devtools/page/x'
        Restore-CdpConnection 6>$null
        Should -Invoke Connect-CdpSocket -Times 1 -Exactly
        $script:PageZoomPercent | Should -Be 100
        $script:PageZoomLost | Should -Be 150
        $script:PageZoomLost = 0
    }
}

Describe 'One tall image: the height limit' {
    It 'an output of <Css> CSS px x <Ratio> x <Zoom>% is <Output> px high: fits <Fits>' -ForEach @(
        @{ Css = 16096; Ratio = 1; Zoom = 100; Output = 16096; Fits = $true }
        @{ Css = 16384; Ratio = 1; Zoom = 100; Output = 16384; Fits = $true }
        @{ Css = 16385; Ratio = 1; Zoom = 100; Output = 16385; Fits = $false }
        @{ Css = 12000; Ratio = 1; Zoom = 150; Output = 18000; Fits = $false }
        @{ Css = 30000; Ratio = 1; Zoom = 50; Output = 15000; Fits = $true }
        @{ Css = 10000; Ratio = 1.5; Zoom = 100; Output = 15000; Fits = $true }
        @{ Css = 10000; Ratio = 2; Zoom = 100; Output = 20000; Fits = $false }
        @{ Css = 100.2; Ratio = 1; Zoom = 100; Output = 101; Fits = $true }
    ) {
        $plan = Get-SingleImagePlan -CssHeight $Css -DevicePixelRatio $Ratio -ZoomPercent $Zoom
        $plan.OutputHeight | Should -Be $Output
        $plan.Fits | Should -Be $Fits
    }
}

Describe 'Reading a screenshot response without ConvertFrom-Json' {
    BeforeAll {
        function ConvertTo-TestMessage([string]$Json) { , [System.Text.Encoding]::UTF8.GetBytes($Json) }
    }

    It 'decodes result.data of the awaited response' {
        $data = [byte[]](1, 2, 3, 250)
        $answer = ConvertFrom-CdpDataResponse -MessageId 7 -Method 'Page.captureScreenshot' `
            -Message (ConvertTo-TestMessage "{""id"":7,""result"":{""data"":""$([Convert]::ToBase64String($data))""}}")
        , $answer.Data | Should -BeOfType [byte[]]
        $answer.Data | Should -Be $data
    }

    It 'skips events and other responses' {
        ConvertFrom-CdpDataResponse -MessageId 7 -Method 'm' -Message (ConvertTo-TestMessage '{"method":"Page.loadEventFired","params":{}}') | Should -BeNullOrEmpty
        ConvertFrom-CdpDataResponse -MessageId 7 -Method 'm' -Message (ConvertTo-TestMessage '{"id":6,"result":{"data":"AQ=="}}') | Should -BeNullOrEmpty
    }

    It 'throws the browser''s error' {
        { ConvertFrom-CdpDataResponse -MessageId 7 -Method 'Page.captureScreenshot' -Message (ConvertTo-TestMessage '{"id":7,"error":{"code":-32000,"message":"Unable to capture"}}') } |
            Should -Throw "*'Page.captureScreenshot' failed: Unable to capture*"
    }

    It 'returns no bytes for a result without data' {
        (ConvertFrom-CdpDataResponse -MessageId 7 -Method 'm' -Message (ConvertTo-TestMessage '{"id":7,"result":{}}')).Data.Length | Should -Be 0
    }
}

Describe 'Capture area and zoom in the report and the JSON summary' {
    BeforeAll {
        $run = [pscustomobject]@{
            StartTime = 's'; EndTime = 'e'; TimeZone = 'tz'; Computer = 'c'; User = 'u'; OperatingSystem = 'os'
            EdgeVersion = 'Edg'; BrowserInstance = 'b'; CaptureDesktop = 'd'; ToolVersion = 't'; CsvPath = 'x'; ImageFormat = 'jpeg'
            ImageDescription = 'JPEG'; ScreenResolution = 'r'; Total = 1; OkCount = 1; WarnCount = 0; FailCount = 0; CaptureCount = 1
        }
        function New-AreaItem([string]$Area, [int]$Zoom) {
            $captures = [System.Collections.Generic.List[object]]::new()
            $captures.Add((New-CaptureRecord -Bytes ([byte[]](1, 2, 3)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FileName 'f.jpg' -CaptureArea $Area -ZoomPercent $Zoom))
            $item = New-CaptureItem -Definition ([pscustomobject]@{ Index = 1; Name = 'A'; Url = 'https://a/'; Notes = ''; StepsText = ''; ScrollFullPage = $false })
            $item.CaptureArea = $Area
            $item.ZoomPercent = $Zoom
            foreach ($capture in $captures) { $item.Captures.Add($capture) }
            return $item
        }
    }

    It 'describes <Area> at <Zoom>% as "<Pattern>"' -ForEach @(
        @{ Area = 'screen'; Zoom = 100; Pattern = 'Full screen, including the taskbar clock</dd>' }
        @{ Area = 'window'; Zoom = 100; Pattern = 'Edge window only*no taskbar or clock)</dd>' }
        @{ Area = 'page'; Zoom = 150; Pattern = 'Page content only*URL and capture time are under each image*; page zoom 150%</dd>' }
    ) {
        $html = New-HtmlReport -Items @((New-AreaItem $Area $Zoom)) -Run $run
        $line = @($html -split "`n" | Where-Object { $_ -like '<dt>Capture area</dt>*' })
        $line.Count | Should -Be 1
        $line[0].TrimEnd() | Should -BeLike "*$Pattern"
    }

    It 'keeps the screen wording of the report for screen captures, and drops the clock promise otherwise' {
        $screen = New-HtmlReport -Items @((New-AreaItem 'screen' 100)) -Run $run
        $screen | Should -Match 'including the Windows taskbar clock\.</p>'
        $screen | Should -Match 'unretouched captures of the primary display\.</footer>'
        $page = New-HtmlReport -Items @((New-AreaItem 'page' 100)) -Run $run
        $page | Should -Not -Match 'taskbar clock\.</p>'
        $page | Should -Match 'the page content as rendered by Edge'
    }

    It 'reads an item and captures without the new fields as screen captures' {
        $old = [pscustomobject]@{
            Index = 1; Name = 'A'; Url = 'https://a/'; FinalUrl = ''; Notes = ''; StepsText = ''; ScrollFullPage = $false
            Status = 'OK'; HttpStatus = 200; Details = [System.Collections.Generic.List[string]]::new()
            StepLog = [System.Collections.Generic.List[object]]::new(); Captures = [System.Collections.Generic.List[object]]::new()
        }
        $old.Captures.Add([pscustomobject]@{ Timestamp = 't'; CapturedAt = 'c'; Url = 'https://a/'; SegmentIndex = 1; SegmentCount = 1
            Base64 = 'AQID'; Bytes = 3; Sha256 = ('a' * 64); FileName = 'f.jpg'; FilePath = '' })
        New-HtmlReport -Items @($old) -Run $run | Should -Match '<dt>Capture area</dt><dd>Full screen, including the taskbar clock</dd>'
    }

    It 'describes what the images got, not what was asked for: <Case>' -ForEach @(
        @{ Case = 'window, 2 of 5 fell back to the screen'; Area = 'window'; Zoom = 100
           Shots = @('window/100', 'screen/100', 'window/100', 'screen/100', 'window/100')
           Expected = 'Edge window only (title bar, tabs and address bar; no taskbar or clock); 2 of 5 image(s) fell back to the full screen' }
        @{ Case = 'window, every image fell back'; Area = 'window'; Zoom = 100; Shots = @('screen/100', 'screen/100')
           Expected = 'Full screen, including the taskbar clock (the Edge window only was asked for)' }
        @{ Case = 'zoom 150 that could not be applied'; Area = 'page'; Zoom = 150; Shots = @('page/100')
           Expected = 'Page content only (no address bar, taskbar or clock; the URL and capture time are under each image and inside each image file)' }
        @{ Case = 'zoom lost half-way'; Area = 'screen'; Zoom = 150; Shots = @('screen/150', 'screen/100', 'screen/100')
           Expected = 'Full screen, including the taskbar clock; page zoom 100% for 2 of 3 image(s), 150% for 1 of 3 image(s)' }
        @{ Case = 'zoom applied'; Area = 'screen'; Zoom = 80; Shots = @('screen/80')
           Expected = 'Full screen, including the taskbar clock; page zoom 80%' }
        @{ Case = 'no image taken'; Area = 'window'; Zoom = 150; Shots = @()
           Expected = 'Edge window only (title bar, tabs and address bar; no taskbar or clock) - as set; no image was taken; page zoom 150% as set' }
    ) {
        $captures = foreach ($shot in $Shots) {
            $parts = $shot -split '/'
            New-CaptureRecord -Bytes ([byte[]](1, 2, 3)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -CaptureArea $parts[0] -ZoomPercent ([int]$parts[1])
        }
        Get-CaptureAreaText -Area $Area -ZoomPercent $Zoom -Captures @($captures) | Should -BeExactly $Expected

        $item = New-AreaItem $Area $Zoom
        $item.Captures.Clear()
        foreach ($capture in @($captures)) { $item.Captures.Add($capture) }
        $line = @((New-HtmlReport -Items @($item) -Run $run) -split "`n" | Where-Object { $_ -like '<dt>Capture area</dt>*' })
        $line[0].TrimEnd() | Should -BeExactly "<dt>Capture area</dt><dd>$(Encode-Html $Expected)</dd>"
    }

    It 'lists the capture area and zoom of each page and image in the JSON summary' {
        $summary = ConvertTo-RunSummaryJson -Items @((New-AreaItem 'page' 80)) -Run $run -ReportPath 'r.html' -ExitCode 0 | ConvertFrom-Json
        $summary.Items[0].CaptureArea | Should -Be 'page'
        $summary.Items[0].ZoomPercent | Should -Be 80
        $summary.Items[0].Captures[0].CaptureArea | Should -Be 'page'
        $summary.Items[0].Captures[0].ZoomPercent | Should -Be 80
    }
}

Describe 'Get-PageSettings and -CaptureArea / -ZoomPercent on the command line' {
    It 'keeps the typed values over the page override and the configuration' {
        $run = Resolve-RunSettings -BoundParameters @{ CaptureArea = 'window'; ZoomPercent = 125 } -Config $null -Defaults @{ NavigationTimeoutSec = 30 }
        $config = Get-DefaultVouchConfig
        $config['defaults']['zoomPercent'] = 90
        $page = [pscustomobject]@{ Overrides = [ordered]@{ captureArea = 'page'; zoomPercent = 80 } }
        $settings = Get-PageSettings -Settings $run -Definition $page -Config $config -BoundNames 'CaptureArea', 'ZoomPercent'
        $settings.CaptureArea | Should -Be 'window'
        $settings.ZoomPercent | Should -Be 125
        $settings = Get-PageSettings -Settings $run -Definition $page -Config $config
        $settings.CaptureArea | Should -Be 'page'
        $settings.ZoomPercent | Should -Be 80
    }
}

Describe 'A waitFor action that times out, on a German PC' {
    BeforeAll {
        $originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
    }
    AfterAll { [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture }

    It 'writes the seconds with a dot' {
        Mock Wait-PageElement { $false }
        $entry = Invoke-PageAction -Action ([ordered]@{ type = 'waitFor'; selector = '#late'; timeoutSec = 1.5 }) `
            -Settings ([pscustomobject]@{ NavigationTimeoutSec = 30; SettleSeconds = 0 })
        $entry.Ok | Should -BeFalse
        $entry.Message | Should -BeLike "*'#late' within 1.5 second(s)*"
    }
}

Describe 'Test-InteractiveRun' {
    It 'is <Expected> for <Case>' -ForEach @(
        @{ Case = 'a console run'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '-NoProfile', '-File', 'vouch.ps1'); Expected = $true }
        @{ Case = '-NoPrompt'; NoPrompt = $true; Desktop = $true; CommandLine = @('pwsh.dll', '-File', 'vouch.ps1'); Expected = $false }
        @{ Case = 'no desktop (UserInteractive false)'; NoPrompt = $false; Desktop = $false; CommandLine = @('pwsh.dll', '-File', 'vouch.ps1'); Expected = $false }
        @{ Case = 'the scheduled task (-NonInteractive)'; NoPrompt = $false; Desktop = $true
           CommandLine = @('pwsh.dll', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', 'C:\v\vouch.ps1', '-CsvPath', 'x.csv'); Expected = $false }
        @{ Case = '-noni'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '-noni', '-f', 'vouch.ps1'); Expected = $false }
        @{ Case = '/NonInteractive'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '/NonInteractive', '-File', 'vouch.ps1'); Expected = $false }
        @{ Case = '--noninteractive'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '--noninteractive', '-c', 'x'); Expected = $false }
        @{ Case = 'a script argument after -File'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '-File', 'vouch.ps1', '-NonInteractive'); Expected = $true }
        @{ Case = 'a script argument after an implied file'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', 'C:\v\vouch.ps1', '-noni'); Expected = $true }
        @{ Case = '-NoLogo (not -noni)'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '-NoLogo', '-No', '-File', 'vouch.ps1'); Expected = $true }
        @{ Case = 'the Designer child (hidden window)'; NoPrompt = $false; Desktop = $true; CommandLine = @('pwsh.dll', '-NoProfile', '-WindowStyle', 'Hidden', '-File', 'vouch.ps1', '-EventLogPath', 'e.ndjson'); Expected = $true }
    ) {
        Test-InteractiveRun -NoPrompt $NoPrompt -UserInteractive $Desktop -CommandLineArgs $CommandLine | Should -Be $Expected
    }

    It 'reads the real process when nothing is passed' {
        Test-InteractiveRun | Should -BeOfType [bool]
        Test-InteractiveRun -NoPrompt $true | Should -BeFalse
    }
}

Describe 'Request-UserDecision' {
    BeforeEach {
        $script:EventLogPath = ''
        $script:InteractiveRun = $false
        Mock Show-ContinueDialog { [pscustomobject]@{ Decision = 'Wait'; WaitSeconds = 45; TimedOut = $false } }
    }
    AfterEach {
        $script:EventLogPath = ''
        $script:InteractiveRun = $false
    }

    It 'returns the default at once, with no window, when nobody can answer' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $answer = Request-UserDecision -Title 'T' -Message 'M' -PageName 'P' -Default 'Skip' -TimeoutSec 300
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 1
        $answer.Decision | Should -Be 'Skip'
        $answer.Prompted | Should -BeFalse
        $answer.TimedOut | Should -BeFalse
        Should -Invoke Show-ContinueDialog -Times 0 -Exactly
    }

    It 'asks through the dialog in an interactive run, and logs the question and the answer' {
        $script:InteractiveRun = $true
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'ask.ndjson'
        $script:EventPageId = 'p004'
        $answer = Request-UserDecision -Kind 'notReady' -Title 'Not ready' -Message 'Waiting for #grid' -PageName 'Users' -TimeoutSec 120 6>$null
        $answer.Decision | Should -Be 'Wait'
        $answer.WaitSeconds | Should -Be 45
        $answer.Prompted | Should -BeTrue
        Should -Invoke Show-ContinueDialog -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 120 -and $Default -eq 'Continue' -and $PageName -eq 'Users' }
        $events = @(Get-Content -LiteralPath $script:EventLogPath | ForEach-Object { $_ | ConvertFrom-Json })
        @($events.type) | Should -Be @('prompt', 'promptResult')
        $events[0].kind | Should -Be 'notReady'
        $events[0].message | Should -Be 'Waiting for #grid'
        $events[0].pageId | Should -Be 'p004'
        $events[0].timeoutSec | Should -Be 120
        $events[1].decision | Should -Be 'Wait'
        $events[1].waitSeconds | Should -Be 45
        $events[1].shown | Should -BeTrue
        $script:EventPageId = ''
    }

    It 'asks nothing and logs nothing once the run is stopped' {
        $script:InteractiveRun = $true
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'stopped.ndjson'
        Set-Content -LiteralPath "$($script:EventLogPath).stop" -Value ''
        try {
            $answer = Request-UserDecision -Title 'T' -Message 'M' 6>$null
            $answer.Decision | Should -Be 'Continue'
            $answer.Prompted | Should -BeFalse
            Should -Invoke Show-ContinueDialog -Times 0 -Exactly
            $script:EventLogPath | Should -Not -Exist -Because 'no prompt event is written'
        }
        finally { $script:StopRequested = $false }
    }

    It 'carries on as if nobody were there when the dialog cannot be shown' {
        $script:InteractiveRun = $true
        Mock Show-ContinueDialog { throw 'no desktop' }
        $answer = Request-UserDecision -Title 'T' -Message 'M' 6>$null
        $answer.Decision | Should -Be 'Continue'
        $answer.Prompted | Should -BeFalse
    }
}

Describe 'The Vouch dialog, built but not shown' {
    BeforeAll { Add-Type -AssemblyName System.Windows.Forms }
    BeforeEach { $script:Dialogs = [System.Collections.Generic.List[object]]::new() }
    AfterEach { foreach ($d in $script:Dialogs) { $d.Timer.Dispose(); $d.Form.Dispose() } }

    It 'counts down and takes the default answer when the time runs out' {
        $dialog = New-ContinueDialog -Title 'Paused' -Message 'Sign in' -PageName 'Payroll' -Default 'Skip' -TimeoutSec 125
        $script:Dialogs.Add($dialog)
        $dialog.Countdown.Text | Should -Match '^If nobody answers, Vouch will skip this page in 2:0[45]\.$'
        $dialog.WaitButton.Text | Should -Be 'Wait 30 s more'
        $dialog.Form.TopMost | Should -BeTrue
        $dialog.State.Deadline = [datetime]::Now.AddSeconds(-1)
        & $dialog.State.Tick
        $dialog.State.Decision | Should -Be 'Skip'
        $dialog.State.TimedOut | Should -BeTrue
    }

    It 'decides nothing and stays usable when the stop file exists before it is shown' {
        $stop = Join-Path -Path $TestDrive -ChildPath 'early.ndjson.stop'
        Set-Content -LiteralPath $stop -Value ''
        $dialog = New-ContinueDialog -Title 'Paused' -Message 'm' -StopFile $stop
        $script:Dialogs.Add($dialog)
        $dialog.State.Decision | Should -Be ''
        $dialog.Form.IsDisposed | Should -BeFalse
        $dialog.Countdown.Text | Should -Match '^If nobody answers, Vouch will continue in 4:(59|60)\.$|^If nobody answers, Vouch will continue in 5:00\.$'
        # A tick before the window exists decides, but never closes (Close would dispose it).
        & $dialog.State.Tick
        $dialog.State.Decision | Should -Be 'Skip'
        $dialog.Form.IsDisposed | Should -BeFalse
    }

    It 'closes with Skip as soon as the stop file appears' {
        $stop = Join-Path -Path $TestDrive -ChildPath 'run.ndjson.stop'
        $dialog = New-ContinueDialog -Title 'Paused' -Message 'm' -StopFile $stop
        $script:Dialogs.Add($dialog)
        & $dialog.State.Tick
        $dialog.State.Decision | Should -Be ''
        Set-Content -LiteralPath $stop -Value ''
        & $dialog.State.Tick
        $dialog.State.Decision | Should -Be 'Skip'
        $dialog.State.Stopped | Should -BeTrue
        $dialog.State.TimedOut | Should -BeFalse
    }

    It 'answers <Expected> for its button' -ForEach @(
        @{ Button = 'ContinueButton'; Expected = 'Continue' }
        @{ Button = 'SkipButton'; Expected = 'Skip' }
        @{ Button = 'WaitButton'; Expected = 'Wait' }
    ) {
        $dialog = New-ContinueDialog -Title 'Paused' -Message 'm' -WaitSeconds 30
        $script:Dialogs.Add($dialog)
        $dialog.WaitInput.Value = 90
        $dialog.WaitButton.Text | Should -Be 'Wait 90 s more'
        # PerformClick needs a window on screen; OnClick runs the same handler.
        $onClick = [System.Windows.Forms.Button].GetMethod('OnClick', [System.Reflection.BindingFlags]'NonPublic, Instance')
        [void]$onClick.Invoke($dialog.$Button, @([System.EventArgs]::Empty))
        $dialog.State.Decision | Should -Be $Expected
        $dialog.State.TimedOut | Should -BeFalse
        if ($Expected -eq 'Wait') { $dialog.State.WaitSeconds | Should -Be 90 }
    }

    It 'keeps the wait between 5 seconds and an hour' {
        $low = New-ContinueDialog -Title 'T' -Message 'm' -WaitSeconds 1
        $high = New-ContinueDialog -Title 'T' -Message 'm' -WaitSeconds 99999
        $script:Dialogs.Add($low); $script:Dialogs.Add($high)
        $low.WaitInput.Value | Should -Be 5
        $high.WaitInput.Value | Should -Be 3600
    }
}

Describe 'The real Vouch dialog (opt-in: shows a window for 2 seconds)' -Tag 'Interactive' {
    It 'appears, counts down and closes itself with the default answer' {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Initialize-NativeInterop
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $answer = Show-ContinueDialog -Title 'Vouch test' -Message 'This window closes by itself.' -PageName 'Test' -TimeoutSec 2
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 6
        $answer.Decision | Should -Be 'Continue'
        $answer.TimedOut | Should -BeTrue
    }
}

Describe 'Progress events' {
    BeforeEach { $script:EventRunId = 'run-1' }
    AfterEach { $script:EventLogPath = ''; $script:EventRunId = '' }

    It 'writes nothing, and no file, without an event log' {
        $script:EventLogPath = ''
        Write-RunEvent -Type 'runStart' -Data @{ pageCount = 1 }
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.ndjson').Count | Should -Be 0
    }

    It 'writes one JSON object per line that reads back with ConvertFrom-Json' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'events.ndjson'
        $details = [System.Collections.Generic.List[string]]::new()
        $details.Add('Line one "quoted"'); $details.Add("two`nlines")
        Write-RunEvent -Type 'pageEnd' -Data ([ordered]@{ type = 'not the envelope'; runId = 'x'; pageId = 'p001'; status = 'WARNING'; details = @($details); captureCount = 2; finalUrl = 'https://x/ä' })
        Write-RunEvent -Type 'runEnd' -Data ([ordered]@{ exitCode = 0; counts = [ordered]@{ ok = 1 }; stopped = $false })
        $bytes = [System.IO.File]::ReadAllBytes($script:EventLogPath)
        $bytes[0] | Should -Be ([byte][char]'{') -Because 'no BOM'
        $lines = [System.Text.Encoding]::UTF8.GetString($bytes) -split "`n"
        $lines.Count | Should -Be 3
        $lines[2] | Should -Be ''
        $first = $lines[0] | ConvertFrom-Json
        $first.type | Should -Be 'pageEnd'
        $first.runId | Should -Be 'run-1'
        # ConvertFrom-Json turns the time into a DateTime; the raw text is what a reader sees.
        $lines[0] | Should -Match '^\{"ts":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d","type":"pageEnd","runId":"run-1",'
        @($first.details) | Should -Be @('Line one "quoted"', "two`nlines")
        $first.finalUrl | Should -Be 'https://x/ä'
        ($lines[1] | ConvertFrom-Json).counts.ok | Should -Be 1
    }

    It 'keeps writing while another program holds the file open' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'tailed.ndjson'
        Write-RunEvent -Type 'runStart'
        $reader = [System.IO.FileStream]::new($script:EventLogPath, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            Write-RunEvent -Type 'pageStart' -Data @{ index = 1 }
            $text = [System.IO.StreamReader]::new($reader).ReadToEnd()
            @($text -split "`n" | Where-Object { $_ }).Count | Should -Be 2
        }
        finally { $reader.Dispose() }
    }

    It 'retries while a reader holds the file without write sharing, and keeps the event' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'locked.ndjson'
        Write-RunEvent -Type 'runStart'
        $lock = [System.IO.FileStream]::new($script:EventLogPath, 'Open', 'Read', 'Read')
        # Released by another thread after about 80 ms, as File.ReadAllText would.
        $job = Start-ThreadJob -ArgumentList $lock -ScriptBlock { param($Stream) Start-Sleep -Milliseconds 80; $Stream.Dispose() }
        try {
            Write-RunEvent -Type 'runEnd' -Data @{ exitCode = 0 }
        }
        finally {
            $job | Wait-Job | Remove-Job
            $lock.Dispose()
        }
        @(Get-Content -LiteralPath $script:EventLogPath | ForEach-Object { ($_ | ConvertFrom-Json).type }) | Should -Be @('runStart', 'runEnd')
    }

    It 'gives up quietly after a few retries when the file stays locked' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'held.ndjson'
        Write-RunEvent -Type 'runStart'
        $lock = [System.IO.FileStream]::new($script:EventLogPath, 'Open', 'Read', 'Read')
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            { Write-RunEvent -Type 'runEnd' } | Should -Not -Throw
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 1
        }
        finally { $lock.Dispose() }
        @(Get-Content -LiteralPath $script:EventLogPath).Count | Should -Be 1
    }

    It 'never fails the run when the file cannot be written' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'no such folder\e.ndjson'
        { Write-RunEvent -Type 'runStart' } | Should -Not -Throw
    }

    It 'writes the error and a runEnd for a run that failed' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'failed.ndjson'
        Write-RunFailedEvent -Message 'Edge did not start'
        $events = @(Get-Content -LiteralPath $script:EventLogPath | ForEach-Object { $_ | ConvertFrom-Json })
        @($events.type) | Should -Be @('error', 'runEnd')
        $events[0].message | Should -Be 'Edge did not start'
        $events[1].exitCode | Should -Be 1
        $events[1].stopped | Should -BeFalse
    }
}

Describe 'Stop file' {
    AfterEach {
        $script:EventLogPath = ''
        $script:StopRequested = $false
    }

    It 'never stops a run without an event log' {
        Initialize-RunEvent -EventLogPath ''
        Test-StopRequested | Should -BeFalse
        Get-StopFilePath | Should -Be ''
    }

    It 'stops once the event log name plus .stop exists, and stays stopped' {
        $path = Join-Path -Path $TestDrive -ChildPath 'stop\run.ndjson'
        Initialize-RunEvent -EventLogPath $path
        Test-Path -LiteralPath (Split-Path $path) | Should -BeTrue -Because 'the folder is created'
        Get-StopFilePath | Should -Be "$path.stop"
        Test-StopRequested | Should -BeFalse
        Set-Content -LiteralPath "$path.stop" -Value ''
        Test-StopRequested 6>$null | Should -BeTrue
        Remove-Item -LiteralPath "$path.stop"
        Test-StopRequested | Should -BeTrue
    }

    It 'removes a stop file left over from an earlier run, and gives each run its own id' {
        $path = Join-Path -Path $TestDrive -ChildPath 'stale.ndjson'
        Set-Content -LiteralPath "$path.stop" -Value ''
        Initialize-RunEvent -EventLogPath $path
        $first = $script:EventRunId
        "$path.stop" | Should -Not -Exist
        Test-StopRequested | Should -BeFalse
        Initialize-RunEvent -EventLogPath $path
        $script:EventRunId | Should -Not -Be $first
    }

    It 'sleeps in one piece without an event log, exactly as before' {
        Initialize-RunEvent -EventLogPath ''
        Mock Start-Sleep { }
        Wait-Interruptible -Milliseconds 730 | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 730 }
    }

    It 'notices a stop within a second during a long wait' {
        $path = Join-Path -Path $TestDrive -ChildPath 'waiting.ndjson'
        Initialize-RunEvent -EventLogPath $path
        Set-Content -LiteralPath "$path.stop" -Value ''
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-Interruptible -Milliseconds 60000 6>$null | Should -BeFalse
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 1
    }
}

Describe 'Ending a run: stop file, events and state' {
    AfterEach {
        $script:EventLogPath = ''
        $script:StopRequested = $false
    }

    It 'removes the stop file only when the stop was honoured' {
        $script:EventLogPath = Join-Path -Path $TestDrive -ChildPath 'end.ndjson'
        Set-Content -LiteralPath "$($script:EventLogPath).stop" -Value ''
        $script:StopRequested = $false
        Remove-StopFile
        "$($script:EventLogPath).stop" | Should -Exist
        $script:StopRequested = $true
        Remove-StopFile
        "$($script:EventLogPath).stop" | Should -Not -Exist
    }

    It 'Invoke-Main logs error and runEnd for a run that throws, removes an honoured stop file and ends the event log and stop with the run' {
        $script:TestLog = Join-Path -Path $TestDrive -ChildPath 'throws.ndjson'
        Set-Content -LiteralPath "$($script:TestLog).stop" -Value ''
        Mock Invoke-CaptureRun {
            $script:EventLogPath = $script:TestLog
            [void](Test-StopRequested 6>$null)
            throw 'Edge did not start'
        }
        { Invoke-Main -BoundParameters @{} } | Should -Throw '*Edge did not start*'
        $events = @(Get-Content -LiteralPath $script:TestLog | ForEach-Object { $_ | ConvertFrom-Json })
        @($events.type) | Should -Be @('error', 'runEnd')
        $events[1].stopped | Should -BeTrue
        "$($script:TestLog).stop" | Should -Not -Exist
        $script:EventLogPath | Should -Be ''
        $script:StopRequested | Should -BeFalse
    }
}

Describe 'Handing the screen back to Edge after the dialog' {
    AfterEach { $script:EdgeProcess = $null }

    It 'does not search at all for a reused Edge with no known process and no connection' {
        $script:EdgeProcess = $null
        Mock Test-CdpSocketOpen { $false }
        Mock Get-EdgeWindowHandle { [IntPtr]::Zero }
        Restore-EdgeForeground
        Should -Invoke Get-EdgeWindowHandle -Times 0 -Exactly
    }

    It 'looks for a reused Edge by the title of the page it shows' {
        $script:EdgeProcess = $null
        Mock Test-CdpSocketOpen { $true }
        Mock Invoke-CdpEval { 'Users - Admin' }
        Mock Get-EdgeWindowHandle { [IntPtr]::Zero }
        Restore-EdgeForeground
        Should -Invoke Get-EdgeWindowHandle -Times 1 -Exactly -ParameterFilter { $ExpectedTitle -eq 'Users - Admin' -and $TimeoutSec -eq 1 }
        # A busy page must not hold the run up for long after the dialog.
        Should -Invoke Invoke-CdpEval -Times 1 -Exactly -ParameterFilter { $TimeoutSec -le 2 }
    }

    It 'looks for an Edge it knows by its process without reading the title' {
        $script:EdgeProcess = [pscustomobject]@{ Id = 1 }
        Mock Invoke-CdpEval { throw 'not needed' }
        Mock Get-EdgeWindowHandle { [IntPtr]::Zero }
        Restore-EdgeForeground
        Should -Invoke Get-EdgeWindowHandle -Times 1 -Exactly -ParameterFilter { $ExpectedTitle -eq '' }
        Should -Invoke Invoke-CdpEval -Times 0 -Exactly
    }
}

Describe 'Receive-CdpMessage when the timeout fires a moment early' {
    It 'says it timed out, not "The operation was canceled."' {
        # The cancellation token fires while Get-Date still reads just before the deadline.
        $script:FakeDeadline = [datetime]::Now.AddMinutes(5)
        $deadline = $script:FakeDeadline
        Mock Get-Date { $script:FakeDeadline.AddMilliseconds(-150) }
        $fake = [pscustomobject]@{}
        $fake | Add-Member -MemberType ScriptMethod -Name ReceiveAsync -Value {
            param($Segment, $Token)
            [System.Threading.Tasks.Task]::Delay([System.Threading.Timeout]::Infinite, $Token)
        }
        $saved = $script:CdpSocket
        $script:CdpSocket = $fake
        try {
            { Receive-CdpMessage -Deadline $deadline } | Should -Throw 'Timed out waiting for a response from the browser*'
        }
        finally { $script:CdpSocket = $saved }
    }
}

Describe 'Small checks added with the prompts' {
    It 'Test-CdpSocketOpen is false for no socket and for a socket that is not open' {
        $saved = $script:CdpSocket
        try {
            $script:CdpSocket = $null
            Test-CdpSocketOpen | Should -BeFalse
            $script:CdpSocket = [System.Net.WebSockets.ClientWebSocket]::new()
            Test-CdpSocketOpen | Should -BeFalse
            $script:CdpSocket.Abort()
            Test-CdpSocketOpen | Should -BeFalse
        }
        finally {
            if ($script:CdpSocket) { $script:CdpSocket.Dispose() }
            $script:CdpSocket = $saved
        }
    }

    It 'Get-TallImageProblem accepts a whole image and flags a page that grew (<Case>)' -ForEach @(
        @{ Case = 'whole'; Image = 5016; Planned = 5016; After = 5016; Problem = $false }
        @{ Case = 'rounding'; Image = 4525; Planned = 4524; After = 4524; Problem = $false }
        @{ Case = 'grew while captured'; Image = 5016; Planned = 5016; After = 7016; Problem = $true }
        @{ Case = 'image not the planned height'; Image = 4000; Planned = 5016; After = 5016; Problem = $true }
    ) {
        $text = Get-TallImageProblem -ImageHeight $Image -PlannedHeight $Planned -HeightAfter $After -What "the capture 'All'"
        if ($Problem) { $text | Should -Match "^The one tall image of the capture 'All' is $Image pixels high, but the page measured \d+ pixels" }
        else { $text | Should -Be '' }
    }

    It 'Get-PartialWindowDetail says when part of the window is off the main display (<Case>)' -ForEach @(
        @{ Case = 'all on it'; Window = @(100, 50, 640, 480); Visible = @(100, 50, 640, 480); Expected = '' }
        @{ Case = 'maximised, borders counted'; Window = @(-8, -8, 1936, 1056); Visible = @(0, 0, 1920, 1040); Expected = '' }
        @{ Case = 'half off to the right'; Window = @(1600, 100, 640, 480); Visible = @(1600, 100, 320, 480)
           Expected = 'Part of the Edge window is outside the main display, so the images show only the part on it (320x480 of the 640x480 window).' }
    ) {
        $w = [System.Drawing.Rectangle]::new($Window[0], $Window[1], $Window[2], $Window[3])
        $v = [System.Drawing.Rectangle]::new($Visible[0], $Visible[1], $Visible[2], $Visible[3])
        Get-PartialWindowDetail -WindowBounds $w -Visible $v | Should -Be $Expected
    }

    It 'Get-NotReadyPolicy reads onNotReady and the prompt timeout, with safe defaults' {
        $policy = Get-NotReadyPolicy -Settings ([pscustomobject]@{ NavigationTimeoutSec = 30 })
        $policy.OnNotReady | Should -Be 'warn'
        $policy.PromptTimeoutSec | Should -Be 300
        $policy = Get-NotReadyPolicy -Settings ([pscustomobject]@{ OnNotReady = 'prompt'; PromptTimeoutSec = 45 })
        $policy.OnNotReady | Should -Be 'prompt'
        $policy.PromptTimeoutSec | Should -Be 45
    }
}

Describe 'Report content (-Options)' {
    BeforeAll {
        $script:Markup = '<script>alert(1)</script>'
        $run = [pscustomobject]@{
            StartTime = '2026-09-23 10:00:00'; EndTime = '2026-09-23 10:05:00'; TimeZone = 'UTC'; Computer = 'PC'; User = 'DOM\user'
            OperatingSystem = 'Windows'; EdgeVersion = 'Edg/1'; BrowserInstance = 'b'; CaptureDesktop = 'd'; ToolVersion = '2.0.0'
            CsvPath = 'c.json'; ImageFormat = 'jpeg'; ImageDescription = 'JPEG'; ScreenResolution = '1x1'; Total = 2; OkCount = 2
            WarnCount = 0; FailCount = 0; CaptureCount = 4; RunId = 'r'; ManifestSha256 = ('a' * 64)
        }
        $at = { param($Minute) [System.DateTimeOffset]::new(2026, 9, 23, 10, $Minute, 0, [TimeSpan]::FromHours(2)) }
        function New-OptionItem([int]$Index, [string]$Name, [string]$Account, [object[]]$Captures) {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $Captures) { $list.Add($c) }
            [pscustomobject]@{
                Index = $Index; Name = $Name; Url = 'https://a/'; FinalUrl = 'https://a/'; Notes = ''; StepsText = ''; ScrollFullPage = $false
                ScrollArea = ''; Status = 'OK'; HttpStatus = 200; Details = [System.Collections.Generic.List[string]]::new()
                StepLog = [System.Collections.Generic.List[object]]::new(); Captures = $list; CaptureArea = 'page'; ZoomPercent = 100; Account = $Account
            }
        }
        $script:Items = @(
            (New-OptionItem 1 "Payroll $($script:Markup)" "svc<b>@example.com" @(
                (New-CaptureRecord -Bytes ([byte[]](1)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FileName '001_P_seg01.jpg' -Label "Policy $($script:Markup)" -CapturedAt (& $at 3))
                (New-CaptureRecord -Bytes ([byte[]](2)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 2 -FileName '001_P_c02_seg01.jpg' -CaptureNumber 2 -CapturedAt (& $at 4))
                (New-CaptureRecord -Bytes ([byte[]](3)) -Url 'https://a/' -SegmentIndex 2 -SegmentCount 2 -FileName '001_P_c02_seg02.jpg' -CaptureNumber 2 -CapturedAt (& $at 5))))
            (New-OptionItem 2 'Plain' '' @(
                (New-CaptureRecord -Bytes ([byte[]](4)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FileName '002_Plain_seg01.jpg' -CapturedAt (& $at 1)))))
        $script:Options = New-ReportOptions -Title "Q3 $($script:Markup)" -Classification 'confidential' -CompanyName "ACME $($script:Markup)" `
            -CompanyDetails "1 Main St`r`nSpringfield <b>x</b>" -Description "Why`nwe $($script:Markup)" -Origin "HQ $($script:Markup)" `
            -GeneratedBy "Jane $($script:Markup)" -PeriodFrom '01/07/2026' -PeriodTo '2026-09-30' -PeriodLabel "Q3 $($script:Markup)" `
            -Account "svc-default $($script:Markup)" -LogoDataUri 'data:image/png;base64,iVBORw0KGgo='
        $script:Html = New-HtmlReport -Items $script:Items -Run $run -Options $script:Options
        $script:Run = $run
    }

    It 'never emits a typed value unencoded' {
        $script:Html | Should -Not -Match '<script>alert'
        $script:Html | Should -Not -Match '<b>'
        ([regex]::Matches($script:Html, '&lt;script&gt;alert\(1\)&lt;/script&gt;')).Count | Should -BeGreaterOrEqual 9
    }

    It 'uses the title as the page title and the main heading' {
        $script:Html | Should -Match '<title>Q3 &lt;script&gt;alert\(1\)&lt;/script&gt; - 2026-09-23 10:00:00</title>'
        $script:Html | Should -Match '<h1>Q3 &lt;script&gt;alert\(1\)&lt;/script&gt;</h1>'
        $script:Html | Should -Not -Match 'Vouch &mdash; Audit Evidence Report'
    }

    It 'keeps the old heading for the default title' {
        $html = New-HtmlReport -Items $script:Items -Run $script:Run -Options (New-ReportOptions)
        $html | Should -Match '<h1>Vouch &mdash; Audit Evidence Report</h1>'
    }

    It 'shows the company block with the logo as an image and the details on their own lines' {
        $script:Html | Should -Match '<header class="company"><img class="logo" alt="Company logo" src="data:image/png;base64,iVBORw0KGgo=">'
        $script:Html | Should -Match '<div class="company-name">ACME &lt;script&gt;'
        $script:Html | Should -Match "<div class=""company-details"">1 Main St`nSpringfield &lt;b&gt;x&lt;/b&gt;</div>"
        $script:Html | Should -Match 'white-space: pre-line'
    }

    It 'adds the run details: <Label>' -ForEach @(
        @{ Label = 'Classification'; Text = 'Confidential' }
        @{ Label = 'Origin'; Text = 'HQ &lt;script&gt;alert(1)&lt;/script&gt;' }
        @{ Label = 'Period covered'; Text = 'Q3 &lt;script&gt;alert(1)&lt;/script&gt;: 01/07/2026 to 2026-09-30' }
        @{ Label = 'Capture window'; Text = '2026-09-23 10:01:00 (UTC+02:00) to 2026-09-23 10:05:00 (UTC+02:00)' }
        @{ Label = 'Account used'; Text = 'svc-default &lt;script&gt;alert(1)&lt;/script&gt;' }
        @{ Label = 'Report generated by'; Text = 'Jane &lt;script&gt;alert(1)&lt;/script&gt;' }
        @{ Label = 'Captured by'; Text = 'DOM\user' }
    ) {
        $script:Html | Should -Match ([regex]::Escape("<tr><td class=""k"">$Label</td><td>$Text</td></tr>"))
    }

    It 'keeps the line breaks of the description' {
        $script:Html | Should -Match ([regex]::Escape("<td class=""k"">Description</td><td class=""multiline"">Why`nwe &lt;script&gt;"))
    }

    It 'falls back to the Windows user for "generated by"' {
        New-HtmlReport -Items $script:Items -Run $script:Run -Options (New-ReportOptions) |
            Should -Match ([regex]::Escape('<tr><td class="k">Report generated by</td><td>DOM\user</td></tr>'))
    }

    It 'shows the period exactly as typed (<Case>)' -ForEach @(
        @{ Case = 'both dates'; From = '2026-07-01'; To = '30.09.2026'; Label = ''; Expected = '2026-07-01 to 30.09.2026' }
        @{ Case = 'from only'; From = '07/01/2026'; To = ''; Label = ''; Expected = 'from 07/01/2026' }
        @{ Case = 'to only'; From = ''; To = '2026-09-30'; Label = ''; Expected = 'up to 2026-09-30' }
        @{ Case = 'label only'; From = ''; To = ''; Label = 'FY2026'; Expected = 'FY2026' }
        @{ Case = 'nothing'; From = ''; To = ''; Label = ''; Expected = '' }
    ) {
        Get-PeriodText -From $From -To $To -Label $Label | Should -Be $Expected
    }

    It 'measures the capture window from the images, not from what was typed' {
        $window = Get-CaptureWindow -Items $script:Items
        $window.First | Should -Be '2026-09-23T10:01:00.000+02:00'
        $window.Last | Should -Be '2026-09-23T10:05:00.000+02:00'
        (Get-CaptureWindow -Items @()).Text | Should -Be 'No screenshot was taken.'
    }

    It 'shows the account on each page that has one' {
        $script:Html | Should -Match '<dt>Account</dt><dd>svc&lt;b&gt;@example.com</dd>'
        ([regex]::Matches($script:Html, '<dt>Account</dt>')).Count | Should -Be 1
    }

    Context 'classification banner' {
        It 'shows a <Level> banner at the top and the bottom, and on every printed page' -ForEach @(
            @{ Level = 'Public'; Color = '#1c6b2c' }, @{ Level = 'Internal'; Color = '#12507d' }
            @{ Level = 'Private'; Color = '#5b3a8c' }, @{ Level = 'Confidential'; Color = '#9b1c1c' }
        ) {
            $html = New-HtmlReport -Items $script:Items -Run $script:Run -Options (New-ReportOptions -Classification $Level)
            $upper = $Level.ToUpperInvariant()
            $banners = [regex]::Matches($html, "<div class=""classification (top|bottom) cls-$($Level.ToLowerInvariant())"" role=""note"">$upper</div>")
            @($banners | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('top', 'bottom')
            $html.IndexOf('class="classification top') | Should -BeLessThan $html.IndexOf('<h1>')
            $html.IndexOf('class="classification bottom') | Should -BeGreaterThan $html.IndexOf('<footer>')
            $html | Should -Match "@top-center \{ content: ""$upper""; color: $Color"
            $html | Should -Match "@bottom-center \{ content: ""$upper"""
            $html | Should -Match "\.classification \{ color: $Color"
        }

        It 'shows no banner, no marking and no page margin rule without a classification' {
            $html = New-HtmlReport -Items $script:Items -Run $script:Run -Options (New-ReportOptions)
            $html | Should -Not -Match 'class="classification'
            $html | Should -Not -Match '@page'
            $html | Should -Not -Match '<td class="k">Classification</td>'
        }

        It 'ignores a level that is not in the list' {
            (New-ReportOptions -Classification 'Secret').Classification | Should -Be ''
        }
    }

    Context 'contents index' {
        It 'lists every page in order with its status, image count and account' {
            $index = [regex]::Match($script:Html, '(?s)<nav class="contents-wrap".*?</nav>').Value
            $index | Should -Not -BeNullOrEmpty
            $index | Should -Match '<th>Account</th>'
            $rows = [regex]::Matches($index, '<tr><td>(\d+)</td><td><a href="#(item-\d+)">([^<]*)</a>')
            @($rows | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('1', '2')
            $rows[0].Groups[3].Value | Should -Be 'Payroll &lt;script&gt;alert(1)&lt;/script&gt;'
            $index | Should -Match '<td><span class="badge ok">OK</span></td><td>3</td><td>svc&lt;b&gt;@example.com</td>'
            $index | Should -Match '<td>1</td><td>&mdash;</td></tr>'
            $script:Html.IndexOf('id="contents"') | Should -BeLessThan $script:Html.IndexOf('<h2>Summary</h2>')
        }

        It 'lists the captures of a page with several as sub-entries' {
            $index = [regex]::Match($script:Html, '(?s)<nav class="contents-wrap".*?</nav>').Value
            $subs = [regex]::Matches($index, '<li><a href="#(item-1-c\d)">([^<]*)</a></li>')
            @($subs | ForEach-Object { $_.Groups[2].Value }) | Should -Be @('Capture 1: Policy &lt;script&gt;alert(1)&lt;/script&gt;', 'Capture 2')
            $index | Should -Not -Match 'item-2-c'
        }

        It 'links only to ids that exist in the report, each once' {
            $targets = @([regex]::Matches($script:Html, 'href="#([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $targets | Should -Contain 'item-1-c2'
            foreach ($target in $targets) {
                ([regex]::Matches($script:Html, "id=""$([regex]::Escape($target))""")).Count | Should -Be 1 -Because $target
            }
        }

        It 'puts the capture anchor on the first image of each capture' {
            $script:Html | Should -Match '<figure id="item-1-c2">\r?\n<img alt="Payroll &lt;script&gt;alert\(1\)&lt;/script&gt; - Capture 2 screenshot 1 of 2"'
        }

        It 'is shown for one page with one capture too' {
            $html = New-HtmlReport -Items @($script:Items[1]) -Run $script:Run -Options (New-ReportOptions)
            $html | Should -Match '<h2 id="contents">Contents</h2>'
            $html | Should -Not -Match '<th>Account</th>'
        }

        It 'is left out with showIndex false' {
            $html = New-HtmlReport -Items $script:Items -Run $script:Run -Options (New-ReportOptions -ShowIndex $false)
            $html | Should -Not -Match 'id="contents"'
        }
    }

    Context 'report form' {
        It 'says a self-contained report is self-contained' {
            $script:Html | Should -Match '<strong>Self-contained report:</strong>'
            ([regex]::Matches($script:Html, 'src="data:image/jpeg;base64,')).Count | Should -Be 4
        }

        It 'links images of a linked report by relative, escaped paths, and says the folder must travel with it' {
            $html = New-HtmlReport -Items $script:Items -Run $script:Run -Options (New-ReportOptions -EmbedImages $false -ImageFolder 'images\Q3 #1')
            $html | Should -Not -Match 'base64,'
            $html | Should -Match ([regex]::Escape('data-url="https://a/" src="images/Q3%20%231/001_P_c02_seg01.jpg">'))
            $html | Should -Match ([regex]::Escape('<strong>Linked report:</strong> the screenshots are separate files in the folder <code>images/Q3 #1</code>'))
        }
    }

    Context 'without options (as before this version)' {
        BeforeAll {
            $script:Plain = New-HtmlReport -Items $script:Items -Run $script:Run
        }

        It 'has the same title, heading, sections and image markup as before' {
            $script:Plain | Should -Match '<title>Vouch &mdash; Audit Evidence Report - 2026-09-23 10:00:00</title>'
            $script:Plain | Should -Match '<h1>Vouch &mdash; Audit Evidence Report</h1>'
            @([regex]::Matches($script:Plain, '<h2>([^<]*)</h2>') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 3) |
                Should -Be @('Summary', 'Integrity', 'Evidence')
            ([regex]::Matches($script:Plain, '<figure>')).Count | Should -Be 4
            $metaLabels = @([regex]::Matches($script:Plain, '<tr><td class="k">([^<]*)</td>') | ForEach-Object { $_.Groups[1].Value })
            $metaLabels | Should -Be @('Run started', 'Run finished', 'Time zone', 'Computer', 'Captured by', 'Operating system', 'Browser',
                'Browser instance', 'Desktop', 'Capture tool', 'Definition file', 'Image format', 'Screen resolution', 'Run ID', 'Manifest SHA-256')
        }

        It 'adds nothing of the options' {
            foreach ($pattern in 'contents', 'classification', 'company', 'Self-contained report', 'Linked report', '<dt>Account</dt>', 'multiline', '@page', 'id="item-1-c') {
                $script:Plain | Should -Not -Match ([regex]::Escape($pattern)) -Because $pattern
            }
        }
    }

    Context 'JSON summary' {
        It 'carries every report field under clear names' {
            $zip = [pscustomobject]@{ Path = 'C:\out\r.zip'; Sha256 = ('c' * 64) }
            $json = ConvertTo-RunSummaryJson -Items $script:Items -Run $script:Run -ReportPath 'C:\out\r.html' -ExitCode 0 -Options $script:Options -Zip $zip | ConvertFrom-Json -DateKind String
            $details = $json.ReportDetails
            $details.Title | Should -Be "Q3 $($script:Markup)"
            $details.Classification | Should -Be 'Confidential'
            $details.Company.Name | Should -Be "ACME $($script:Markup)"
            $details.Company.Details | Should -Be "1 Main St`r`nSpringfield <b>x</b>"
            $details.Description | Should -Be "Why`nwe $($script:Markup)"
            $details.Origin | Should -Be "HQ $($script:Markup)"
            $details.GeneratedBy | Should -Be "Jane $($script:Markup)"
            $details.Period.From | Should -Be '01/07/2026'
            $details.Period.To | Should -Be '2026-09-30'
            $details.Period.Label | Should -Be "Q3 $($script:Markup)"
            $details.CaptureWindow.First | Should -Be '2026-09-23T10:01:00.000+02:00'
            $details.CaptureWindow.Last | Should -Be '2026-09-23T10:05:00.000+02:00'
            $details.Account | Should -Be "svc-default $($script:Markup)"
            $details.ShowIndex | Should -BeTrue
            $details.ImageForm | Should -Be 'embedded'
            $json.Zip.Path | Should -Be 'C:\out\r.zip'
            $json.Zip.Sha256 | Should -Be ('c' * 64)
            $json.Items[0].Account | Should -Be 'svc<b>@example.com'
            $json.Items[1].Account | Should -Be ''
        }

        It 'has neither without options or a zip' {
            $json = ConvertTo-RunSummaryJson -Items $script:Items -Run $script:Run -ReportPath 'C:\r.html' -ExitCode 0 | ConvertFrom-Json
            $json.PSObject.Properties['ReportDetails'] | Should -BeNullOrEmpty
            $json.PSObject.Properties['Zip'] | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-LogoDataUri' {
    BeforeAll {
        $folder = Join-Path $TestDrive 'logos'
        [void](New-Item -ItemType Directory -Path $folder)
        $write = { param($Name, [byte[]]$Bytes) $path = Join-Path $folder $Name; [System.IO.File]::WriteAllBytes($path, $Bytes); $path }
        $script:Logos = @{
            png  = & $write 'logo.png' ([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2))
            jpeg = & $write 'logo.jpg' ([byte[]](0xFF, 0xD8, 0xFF, 0xE0, 1, 2))
            gif  = & $write 'logo.gif' ([System.Text.Encoding]::ASCII.GetBytes('GIF89a....'))
            svg  = & $write 'logo.svg' ([System.Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'))
            text = & $write 'logo.png.txt' ([System.Text.Encoding]::ASCII.GetBytes('hello'))
            fake = & $write 'fake.png' ([System.Text.Encoding]::ASCII.GetBytes('<svg></svg>'))
        }
    }

    It 'embeds a <Kind> logo as <Mime>, read from the file''s content' -ForEach @(
        @{ Kind = 'png'; Mime = 'image/png' }, @{ Kind = 'jpeg'; Mime = 'image/jpeg' }
        @{ Kind = 'gif'; Mime = 'image/gif' }, @{ Kind = 'svg'; Mime = 'image/svg+xml' }
    ) {
        $logo = Get-LogoDataUri -Path $script:Logos[$Kind]
        $logo.Warning | Should -Be ''
        $logo.DataUri | Should -BeLike "data:$($Mime);base64,*"
        [System.Convert]::FromBase64String($logo.DataUri.Substring($logo.DataUri.IndexOf(',') + 1)) |
            Should -Be ([System.IO.File]::ReadAllBytes($script:Logos[$Kind]))
    }

    It 'only ever puts an SVG into an img src, base64-encoded, never into the page' {
        $logo = Get-LogoDataUri -Path $script:Logos.svg
        $html = New-HtmlReport -Items @() -Run ([pscustomobject]@{ ImageFormat = 'jpeg'; StartTime = 's'; EndTime = 'e'; User = 'u' }) `
            -Options (New-ReportOptions -LogoDataUri $logo.DataUri -CompanyName 'ACME')
        $html | Should -Not -Match '<svg'
        $html | Should -Not -Match '<script>'
        $html | Should -Match '<img class="logo" alt="Company logo" src="data:image/svg\+xml;base64,'
    }

    It 'warns and gives no logo for <Case>' -ForEach @(
        @{ Case = 'a missing file'; Key = ''; Pattern = '*was not found, so the report has no logo.' }
        @{ Case = 'a file that is no image'; Key = 'text'; Pattern = '*is not a PNG, JPEG, GIF or SVG image*' }
        @{ Case = 'a .png that is not one'; Key = 'fake'; Pattern = '*is not a PNG, JPEG, GIF or SVG image*' }
    ) {
        $path = if ($Key) { $script:Logos[$Key] } else { Join-Path $TestDrive 'nope.png' }
        $logo = Get-LogoDataUri -Path $path
        $logo.DataUri | Should -Be ''
        $logo.Warning | Should -BeLike $Pattern
    }

    It 'warns and gives no logo above the size limit' {
        $logo = Get-LogoDataUri -Path $script:Logos.png -MaxBytes 4
        $logo.DataUri | Should -Be ''
        $logo.Warning | Should -BeLike '*a logo may be at most*Use a smaller image.'
        $big = Join-Path $TestDrive 'big.png'
        [System.IO.File]::WriteAllBytes($big, [byte[]]::new(1MB + 1))
        (Get-LogoDataUri -Path $big).Warning | Should -BeLike '*1,025 KB; a logo may be at most 1,024 KB*'
    }

    It 'does nothing without a path' {
        $logo = Get-LogoDataUri -Path ''
        $logo.DataUri | Should -Be ''
        $logo.Warning | Should -Be ''
    }
}

Describe 'File names from templates' {
    It 'fills every known token' {
        $values = Get-NameTokenValues -When ([datetime]'2026-09-30 17:05:09') -Report 'VouchReport_x' -Title 'Q3 ITGC' `
            -PeriodFrom '2026-07-01' -PeriodTo '2026-09-30' -Classification 'confidential'
        $result = Expand-NameTemplate -Template '{report}|{TITLE}|{date}|{time}|{period}|{classification}' -Values $values
        $result.Text | Should -Be 'VouchReport_x|Q3 ITGC|2026-09-30|170509|2026-07-01 to 2026-09-30|Confidential'
        $result.Unknown.Count | Should -Be 0
    }

    It 'prefers the period label, and uses the default title when none is set' {
        $values = Get-NameTokenValues -When (Get-Date) -PeriodFrom 'a' -PeriodTo 'b' -PeriodLabel 'Q3 2026'
        $values.period | Should -Be 'Q3 2026'
        $values.title | Should -Be 'Audit Evidence Report'
    }

    It 'leaves an unknown token as written and lists it' {
        $result = Expand-NameTemplate -Template '{report}-{client}-{client}.zip' -Values @{ report = 'r' }
        $result.Text | Should -Be 'r-{client}-{client}.zip'
        $result.Unknown | Should -Be @('{client}')
    }

    It 'makes <Name> the safe file name <Expected>' -ForEach @(
        @{ Name = 'Q3 ITGC: payroll/HR?.zip'; Expected = 'Q3 ITGC_ payroll_HR_.zip' }
        @{ Name = '..\..\evil'; Expected = '_.._evil.zip' }
        @{ Name = 'C:\Windows\x'; Expected = 'C_Windows_x.zip' }
        @{ Name = 'report  {x} .'; Expected = 'report {x}.zip' }
        @{ Name = 'CON'; Expected = '_CON.zip' }
        @{ Name = ''; Expected = 'VouchEvidence.zip' }
        @{ Name = 'Contrôle d''accès 2026'; Expected = 'Contrôle d''accès 2026.zip' }
        @{ Name = 'already.ZIP'; Expected = 'already.zip' }
    ) {
        ConvertTo-SafeOutputName -Name $Name -Extension 'zip' | Should -Be $Expected
    }

    It 'adds a number instead of replacing an existing file' {
        $folder = Join-Path $TestDrive 'names'
        [void](New-Item -ItemType Directory -Path $folder)
        $path = Join-Path $folder 'r.zip'
        Get-AvailableFilePath -Path $path | Should -Be $path
        Set-Content -LiteralPath $path -Value 'x'
        Get-AvailableFilePath -Path $path | Should -Be (Join-Path $folder 'r_2.zip')
        Set-Content -LiteralPath (Join-Path $folder 'r_2.zip') -Value 'x'
        Get-AvailableFilePath -Path $path | Should -Be (Join-Path $folder 'r_3.zip')
    }
}

Describe 'The report switches on the command line' {
    BeforeAll {
        $script:FileConfig = @{
            defaults = @{ account = 'file-account' }
            output   = @{ embedImages = $false; openReport = $true; zip = @{ enabled = $true; name = '{title}.zip' } }
            report   = @{
                title = 'File title'; classification = 'Internal'; logoPath = 'C:\file-logo.png'; showIndex = $false
                company = @{ name = 'File Co'; details = 'File details' }; description = 'File description'; origin = 'File origin'
                generatedBy = 'File person'; period = @{ from = 'f-from'; to = 'f-to'; label = 'f-label' }
            }
        }
    }

    It 'reads <Name> from the file as <FromFile>' -ForEach @(
        @{ Name = 'Account'; FromFile = 'file-account' }
        @{ Name = 'ReportTitle'; FromFile = 'File title' }
        @{ Name = 'Classification'; FromFile = 'Internal' }
        @{ Name = 'LogoPath'; FromFile = 'C:\file-logo.png' }
        @{ Name = 'CompanyName'; FromFile = 'File Co' }
        @{ Name = 'CompanyDetails'; FromFile = 'File details' }
        @{ Name = 'Description'; FromFile = 'File description' }
        @{ Name = 'Origin'; FromFile = 'File origin' }
        @{ Name = 'GeneratedBy'; FromFile = 'File person' }
        @{ Name = 'PeriodFrom'; FromFile = 'f-from' }
        @{ Name = 'PeriodTo'; FromFile = 'f-to' }
        @{ Name = 'PeriodLabel'; FromFile = 'f-label' }
        @{ Name = 'NoIndex'; FromFile = $true }
        @{ Name = 'LinkImages'; FromFile = $true }
        @{ Name = 'Zip'; FromFile = $true }
        @{ Name = 'ZipName'; FromFile = '{title}.zip' }
        @{ Name = 'OpenReport'; FromFile = $true }
    ) {
        (Resolve-RunSettings -BoundParameters @{} -Defaults @{} -Config $script:FileConfig).$Name | Should -Be $FromFile
    }

    It 'lets -<Name> typed on the command line beat the file' -ForEach @(
        @{ Name = 'Account'; Typed = 'typed' }, @{ Name = 'ReportTitle'; Typed = 'typed' }, @{ Name = 'Classification'; Typed = 'Public' }
        @{ Name = 'LogoPath'; Typed = 'typed' }, @{ Name = 'CompanyName'; Typed = 'typed' }, @{ Name = 'CompanyDetails'; Typed = 'typed' }
        @{ Name = 'Description'; Typed = 'typed' }, @{ Name = 'Origin'; Typed = 'typed' }, @{ Name = 'GeneratedBy'; Typed = 'typed' }
        @{ Name = 'PeriodFrom'; Typed = 'typed' }, @{ Name = 'PeriodTo'; Typed = 'typed' }, @{ Name = 'PeriodLabel'; Typed = 'typed' }
        @{ Name = 'NoIndex'; Typed = $false }, @{ Name = 'LinkImages'; Typed = $false }, @{ Name = 'Zip'; Typed = $false }
        @{ Name = 'ZipName'; Typed = 'typed.zip' }, @{ Name = 'OpenReport'; Typed = $false }
    ) {
        $bound = @{ $Name = $(if ($Typed -is [bool]) { [switch]$Typed } else { $Typed }) }
        (Resolve-RunSettings -BoundParameters $bound -Defaults @{} -Config $script:FileConfig).$Name | Should -Be $Typed
    }

    It 'shows the index and embeds images when the file says nothing' {
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults @{ NoIndex = [switch]$false; LinkImages = [switch]$false } -Config @{ report = @{}; output = @{} }
        $settings.NoIndex | Should -BeFalse
        $settings.LinkImages | Should -BeFalse
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults @{} -Config @{ report = @{ showIndex = $true }; output = @{ embedImages = $true } }
        $settings.NoIndex | Should -BeFalse
        $settings.LinkImages | Should -BeFalse
    }

    It 'has a switch and help for every run-level setting, and help for every parameter' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:VouchPath, [ref]$null, [ref]$null)
        $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($definition in Get-RunSettingDefinition) { $parameters | Should -Contain $definition.Name }
        $help = $ast.GetHelpContent()
        foreach ($name in $parameters) { $help.Parameters.Keys | Should -Contain $name.ToUpperInvariant() -Because "-$name needs .PARAMETER help" }
    }

    It 'accepts the classification levels and none on the command line, and nothing else' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:VouchPath, [ref]$null, [ref]$null)
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Classification' }
        $set = $parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        @($set.PositionalArguments.Value) | Should -Be @('', 'Public', 'Internal', 'Private', 'Confidential')
    }
}

Describe 'Which runs write progress events' {
    It 'counts a run as a capture run unless it is <Mode>' -ForEach @(@{ Mode = 'Verify'; Value = 'r.html' }, @{ Mode = 'LoginSetup'; Value = $true }, @{ Mode = 'Designer'; Value = $true }) {
        Test-CaptureRunMode -Settings ([pscustomobject]@{ Verify = ''; LoginSetup = $false }) | Should -BeTrue
        Test-CaptureRunMode -Settings ([pscustomobject]@{ $Mode = $Value }) | Should -BeFalse
    }

    It 'writes nothing into the event file for -<Mode>, even when it fails' -ForEach @(
        @{ Mode = 'Verify'; Bound = @{ Verify = 'C:\no\such\report.html' } }
        @{ Mode = 'LoginSetup'; Bound = @{ LoginSetup = [switch]$true; EdgeProfileDir = 'C:\no\such\profile' } }
    ) {
        $log = Join-Path $TestDrive "events-$Mode.ndjson"
        Mock Assert-Environment { }
        Mock Initialize-NativeInterop { }
        Mock Find-EdgeExecutable { 'C:\edge.exe' }
        Mock Invoke-LoginSetup { throw 'login setup failed' }
        $bound = @{ EventLogPath = $log } + $Bound
        { Invoke-Main -BoundParameters $bound 6>$null } | Should -Throw -ExpectedMessage $(if ($Mode -eq 'Verify') { 'Report not found*' } else { 'login setup failed' })
        $log | Should -Not -Exist
        $script:EventLogPath | Should -Be ''
    }
}