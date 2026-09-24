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
