#Requires -Version 7
# Image metadata, hashes, manifest and -Verify. Builds small images in memory; nothing
# touches the screen or a browser.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-VouchFunctionSource)))
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-NativeInterop

    $script:CapturedAt = [System.DateTimeOffset]::new(2026, 9, 24, 6, 1, 2, 345, [TimeSpan]::FromHours(-7))

    function New-TestMetadata([string]$Name = 'Admin – users', [int]$Segment = 1) {
        New-CaptureMetadata -RunId '11111111-2222-3333-4444-555555555555' -ItemIndex 3 -ItemName $Name `
            -RequestedUrl 'https://app.example.com/admin' -PageUrl 'https://app.example.com/admin/users?page=1' `
            -CapturedAt $script:CapturedAt -SegmentIndex $Segment -SegmentCount 2 -Computer 'PC01' -User 'CORP\auditor' -Screen '1280x800'
    }

    function New-TestImage([string]$Format, $Metadata) {
        $bitmap = [System.Drawing.Bitmap]::new(64, 40)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::SteelBlue)
            $graphics.Dispose()
            $stream = [System.IO.MemoryStream]::new()
            if ($Format -eq 'jpeg') {
                if ($Metadata) { Set-JpegMetadata -Image $bitmap -Metadata $Metadata }
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                return , $stream.ToArray()
            }
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $png = $stream.ToArray()
            if ($Metadata) { $png = Add-PngTextChunks -Png $png -Metadata $Metadata }
            return , $png
        }
        finally { $bitmap.Dispose() }
    }

    function New-TestReport([string]$Folder, [switch]$SaveImages, [switch]$Linked, [switch]$Full, [string]$Classification = 'Confidential', [string]$Name = 'report') {
        if ($Linked) { $SaveImages = [switch]$true }
        # -Name: the report's file name without .html, as Get-ReportFileName gives it.
        $name = $Name
        $imagesDir = Join-Path $Folder "images\$name"
        [void][System.IO.Directory]::CreateDirectory($imagesDir)
        $captures = [System.Collections.Generic.List[object]]::new()
        foreach ($segment in 1, 2) {
            $metadata = New-TestMetadata -Segment $segment
            $bytes = New-TestImage -Format jpeg -Metadata $metadata
            $fileName = "003_Admin_users_seg0$segment.jpg"
            $filePath = ''
            if ($SaveImages) { $filePath = Join-Path $imagesDir $fileName; [System.IO.File]::WriteAllBytes($filePath, $bytes) }
            # -Full: two labelled captures of one page (index sub-entries, figure anchors).
            $setArguments = if ($Full) { @{ CaptureNumber = $segment; Label = "Label $segment <img src=x> &period;" } } else { @{} }
            $captures.Add((New-CaptureRecord -Bytes $bytes -Url $metadata.PageUrl -SegmentIndex $segment -SegmentCount 2 `
                -FilePath $filePath -FileName $fileName -CapturedAt $script:CapturedAt -NoBase64:$Linked @setArguments))
        }
        $item = [pscustomobject]@{
            Index = 3; Name = 'Admin – users'; Url = 'https://app.example.com/admin'; FinalUrl = 'https://app.example.com/admin/users?page=1'
            Notes = ''; StepsText = ''; ScrollFullPage = $true; Status = 'OK'; HttpStatus = 200
            Details = [System.Collections.Generic.List[string]]::new(); StepLog = [System.Collections.Generic.List[object]]::new(); Captures = $captures
        }
        if ($Full) {
            $item | Add-Member -NotePropertyName Account -NotePropertyValue 'admin@example.com <b>'
            $item.Notes = 'notes <!-- hi --> style="x"'
            $item.Details.Add('detail & <img src=x> &nbsp;')
            $item.StepLog.Add([pscustomobject]@{ Text = 'click:a[href="x"] > b'; Ok = $false; Message = 'No <element> &period;' })
        }
        $manifest = Get-CaptureManifest -Items @($item)
        if ($SaveImages) { [System.IO.File]::WriteAllText((Join-Path $imagesDir 'SHA256SUMS'), $manifest, [System.Text.UTF8Encoding]::new($false)) }
        $run = [pscustomobject]@{
            StartTime = 's'; EndTime = 'e'; TimeZone = 'tz'; Computer = 'PC01'; User = 'CORP\auditor'; OperatingSystem = 'os'
            EdgeVersion = 'Edg'; BrowserInstance = 'b'; CaptureDesktop = 'd'; ToolVersion = 'test'; CsvPath = 'c'; ImageFormat = 'jpeg'
            ImageDescription = 'JPEG'; ScreenResolution = '1280x800'; Total = 1; OkCount = 1; WarnCount = 0; FailCount = 0; CaptureCount = 2
            RunId = '11111111-2222-3333-4444-555555555555'
            ManifestSha256 = Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($manifest))
        }
        $path = Join-Path $Folder "$name.html"
        # The images folder as a capture run passes it: relative to the report, as Windows spells it.
        $imageFolder = [System.IO.Path]::GetRelativePath($Folder, $imagesDir)
        $options = if ($Linked) { New-ReportOptions -EmbedImages $false -ImageFolder $imageFolder } else { $null }
        if ($Full) {
            # Everything 2.0 can add: logo, company, classification (print CSS), index, run details.
            $evil = 'x <img src=x> <!-- hi --> &period; &nbsp; style="x" url( '' > < & ü 日本'
            $options = New-ReportOptions -EmbedImages (-not $Linked) -ImageFolder $(if ($Linked) { $imageFolder } else { '' }) -Title "Q3 $evil" `
                -Classification $Classification -CompanyName "ACME $evil" -CompanyDetails "1 Main St`nSpringfield $evil" -Description "Why $evil" -Origin $evil `
                -GeneratedBy "Jane $evil" -PeriodFrom '2026-07-01' -PeriodTo '2026-09-30' -PeriodLabel $evil -Account "svc $evil" -CaptureLogName 'report.log' `
                -LogoDataUri 'data:image/png;base64,iVBORw0KGgo='
        }
        [System.IO.File]::WriteAllText($path, (New-HtmlReport -Items @($item) -Run $run -Options $options), [System.Text.UTF8Encoding]::new($false))
        return $path
    }
}

Describe 'New-CaptureMetadata' {
    It 'records the capture time with its offset and in UTC, to the millisecond' {
        $metadata = New-TestMetadata
        $metadata.CapturedAt | Should -Be '2026-09-24T06:01:02.345-07:00'
        $metadata.CapturedAtUtc | Should -Be '2026-09-24T13:01:02.345Z'
        $metadata.Segment | Should -Be '1 of 2'
        $metadata.Tool | Should -BeLike 'vouch.ps1 *'
        @($metadata.Keys) | Should -Be @('Tool', 'RunId', 'ItemIndex', 'ItemName', 'RequestedUrl', 'PageUrl', 'CapturedAt',
            'CapturedAtUtc', 'Segment', 'Computer', 'User', 'Screen', 'CaptureArea', 'ZoomPercent', 'Account')
        $metadata.CaptureArea | Should -Be 'screen'
        $metadata.ZoomPercent | Should -Be 100
        $metadata.Account | Should -Be ''
    }

    It 'records the account the page was captured with, and it reads back from the image' {
        $metadata = New-CaptureMetadata -RunId 'r' -ItemIndex 1 -ItemName 'A' -RequestedUrl 'https://a/' -CapturedAt $script:CapturedAt `
            -SegmentIndex 1 -SegmentCount 1 -Account 'svc-audit@example.com'
        $metadata.Account | Should -Be 'svc-audit@example.com'
        (Get-ImageMetadata -Bytes (New-TestImage -Format jpeg -Metadata $metadata)).Account | Should -Be 'svc-audit@example.com'
        (Get-ImageMetadata -Bytes (New-TestImage -Format png -Metadata $metadata)).Account | Should -Be 'svc-audit@example.com'
    }
}

Describe 'JPEG metadata (EXIF)' {
    It 'round-trips the full metadata, including non-ASCII text' {
        $bytes = New-TestImage -Format jpeg -Metadata (New-TestMetadata)
        $read = Get-ImageMetadata -Bytes $bytes
        $read.ItemName | Should -Be 'Admin – users'
        $read.PageUrl | Should -Be 'https://app.example.com/admin/users?page=1'
        $read.CapturedAt | Should -Be '2026-09-24T06:01:02.345-07:00'
        $read.RunId | Should -Be '11111111-2222-3333-4444-555555555555'
    }

    It 'fills the standard EXIF fields other tools show' {
        $bytes = New-TestImage -Format jpeg -Metadata (New-TestMetadata)
        $image = [System.Drawing.Image]::FromStream([System.IO.MemoryStream]::new($bytes))
        try {
            $text = { param($Id) [System.Text.Encoding]::ASCII.GetString($image.GetPropertyItem($Id).Value).TrimEnd([char]0) }
            & $text 0x9003 | Should -Be '2026:09:24 06:01:02'
            & $text 0x013B | Should -Be 'CORP\auditor'
            & $text 0x010E | Should -Be 'Admin ? users - https://app.example.com/admin/users?page=1'
            & $text 0x0131 | Should -BeLike 'vouch.ps1 *'
        }
        finally { $image.Dispose() }
    }

    It 'returns nothing for an image without Vouch metadata' {
        Get-ImageMetadata -Bytes (New-TestImage -Format jpeg -Metadata $null) | Should -BeNullOrEmpty
    }
}

Describe 'PNG metadata (text chunks)' {
    It 'computes the PNG CRC-32 correctly' {
        # The CRC of every IEND chunk is AE 42 60 82.
        [Vouch.Crc32]::Compute([System.Text.Encoding]::ASCII.GetBytes('IEND')) | Should -Be 0xAE426082u
    }

    It 'round-trips the metadata and keeps a valid image' {
        $bytes = New-TestImage -Format png -Metadata (New-TestMetadata)
        $read = Get-ImageMetadata -Bytes $bytes
        $read.ItemName | Should -Be 'Admin – users'
        $read.CapturedAtUtc | Should -Be '2026-09-24T13:01:02.345Z'
        $chunks = Get-PngTextChunks -Png $bytes
        $chunks['Title'] | Should -Be 'Admin – users'
        $chunks['Author'] | Should -Be 'CORP\auditor'
        $image = [System.Drawing.Image]::FromStream([System.IO.MemoryStream]::new($bytes))
        try { $image.Width | Should -Be 64 } finally { $image.Dispose() }
        [System.Text.Encoding]::ASCII.GetString($bytes, $bytes.Length - 8, 4) | Should -Be 'IEND'
    }

    It 'rejects data that is not a PNG' {
        { Add-PngTextChunks -Png ([byte[]](1..40)) -Metadata (New-TestMetadata) } | Should -Throw '*Not a PNG*'
    }
}

Describe 'Hashes and manifest' {
    It 'hashes the exact bytes (lower-case hex SHA-256)' {
        Get-Sha256Hex -Bytes ([System.Text.Encoding]::ASCII.GetBytes('abc')) |
            Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }

    It 'records the hash and file name on each capture' {
        $record = New-CaptureRecord -Bytes ([byte[]](1, 2, 3)) -Url 'https://a/' -SegmentIndex 1 -SegmentCount 1 -FileName 'x.jpg' -CapturedAt $script:CapturedAt
        $record.Sha256 | Should -Be (Get-Sha256Hex -Bytes ([byte[]](1, 2, 3)))
        $record.FileName | Should -Be 'x.jpg'
        $record.CapturedAt | Should -Be '2026-09-24T06:01:02.345-07:00'
        $record.Timestamp | Should -Be '2026-09-24 06:01:02'
    }

    It 'writes the manifest in sha256sum format' {
        $captures = [System.Collections.Generic.List[object]]::new()
        $captures.Add([pscustomobject]@{ Sha256 = ('a' * 64); FileName = '001_A_seg01.jpg' })
        $captures.Add([pscustomobject]@{ Sha256 = ('b' * 64); FileName = '001_A_seg02.jpg' })
        Get-CaptureManifest -Items @([pscustomobject]@{ Captures = $captures }) |
            Should -BeExactly "$('a' * 64)  001_A_seg01.jpg`n$('b' * 64)  001_A_seg02.jpg`n"
    }
}

Describe 'Test-ReportIntegrity (-Verify)' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $folder)
    }

    It 'passes an untouched report and its saved images' {
        $report = New-TestReport -Folder $folder -SaveImages
        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($results | Where-Object Check -like 'Image *').Count | Should -Be 2
        @($results | Where-Object Check -like 'Metadata *').Count | Should -Be 2
        @($results | Where-Object Check -eq 'Manifest').Count | Should -Be 1
        @($results | Where-Object Check -like 'File *').Count | Should -Be 2
        @($results | Where-Object Check -eq 'SHA256SUMS').Ok | Should -BeTrue
    }

    It 'catches an image changed inside the report' {
        $report = New-TestReport -Folder $folder
        $html = [System.IO.File]::ReadAllText($report)
        $match = [regex]::Match($html, 'base64,([A-Za-z0-9+/=]+)"')
        $bytes = [System.Convert]::FromBase64String($match.Groups[1].Value)
        $bytes[$bytes.Length - 20] = $bytes[$bytes.Length - 20] -bxor 0xFF
        $html = $html.Replace($match.Groups[1].Value, [System.Convert]::ToBase64String($bytes))
        [System.IO.File]::WriteAllText($report, $html)
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok })
        $failed.Count | Should -Be 1
        $failed[0].Check | Should -BeLike 'Image *seg01.jpg'
    }

    It 'catches a hash edited to hide a changed image' {
        $report = New-TestReport -Folder $folder
        $html = [System.IO.File]::ReadAllText($report)
        $hash = [regex]::Match($html, 'data-sha256="([0-9a-f]{64})"').Groups[1].Value
        [System.IO.File]::WriteAllText($report, $html.Replace("data-sha256=""$hash""", "data-sha256=""$('0' * 64)"""))
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }).Check
        $failed | Should -Contain 'Manifest'
    }

    It 'catches a report edited to show a different capture time' {
        $report = New-TestReport -Folder $folder
        $html = [System.IO.File]::ReadAllText($report)
        [System.IO.File]::WriteAllText($report, $html.Replace('data-captured="2026-09-24T06:01:02.345-07:00"', 'data-captured="2026-09-20T06:01:02.345-07:00"'))
        @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }).Check | Should -Contain 'Metadata 003_Admin_users_seg01.jpg'
    }

    It 'catches a saved image that was replaced' {
        $report = New-TestReport -Folder $folder -SaveImages
        $file = Join-Path $folder 'images\report\003_Admin_users_seg02.jpg'
        [System.IO.File]::WriteAllBytes($file, (New-TestImage -Format jpeg -Metadata $null))
        @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }).Check | Should -Be @('File 003_Admin_users_seg02.jpg')
    }

    It 'still writes the attributes of a self-contained report in the order Vouch 1.3''s -Verify reads' {
        $report = New-TestReport -Folder $folder
        $old = '<img alt="[^"]*" data-file="([^"]*)" data-sha256="([0-9a-f]{64})" data-captured="([^"]*)" data-url="([^"]*)" src="data:image/(?:jpeg|png);base64,([A-Za-z0-9+/=]+)">'
        ([regex]::Matches([System.IO.File]::ReadAllText($report), $old)).Count | Should -Be 2
    }

    It 'reads the attributes in any order' {
        $report = New-TestReport -Folder $folder
        $html = [System.IO.File]::ReadAllText($report)
        $html = [regex]::Replace($html, '<img alt="([^"]*)" data-file="([^"]*)" data-sha256="([0-9a-f]{64})" data-captured="([^"]*)" data-url="([^"]*)" src="([^"]*)">',
            { param($m) "<img src=""$($m.Groups[6].Value)"" data-url=""$($m.Groups[5].Value)"" data-captured=""$($m.Groups[4].Value)"" data-sha256=""$($m.Groups[3].Value)"" data-file=""$($m.Groups[2].Value)"" alt=""$($m.Groups[1].Value)"">" })
        [System.IO.File]::WriteAllText($report, $html)
        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($results | Where-Object Check -like 'Metadata *').Count | Should -Be 2
    }

    It 'refuses extra attributes, other case and single quotes, which the generator never writes' {
        $report = New-TestReport -Folder $folder
        $html = [System.IO.File]::ReadAllText($report)
        $html = [regex]::Replace($html, '<img alt="([^"]*)" data-file="([^"]*)" data-sha256="([0-9a-f]{64})" data-captured="([^"]*)" data-url="([^"]*)" src="([^"]*)">',
            { param($m) "<IMG loading=""lazy"" src=""$($m.Groups[6].Value)"" data-url=""$($m.Groups[5].Value)"" class='shot' data-captured='$($m.Groups[4].Value)' data-sha256=""$($m.Groups[3].Value)"" title=""x &amp; y"" data-file=""$($m.Groups[2].Value)"" alt=""$($m.Groups[1].Value)"" decoding=async>" })
        [System.IO.File]::WriteAllText($report, $html)
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok })
        @($failed | Where-Object Check -eq 'Report markup').Count | Should -BeGreaterOrEqual 1
        @($failed | Where-Object Check -like 'Metadata *').Count | Should -Be 0 -Because 'no screenshot is accepted from such a tag'
    }
}

Describe 'The committed example report' {
    It 'still verifies (examples\live-test-2026-09-24, written by Vouch 1.3)' {
        $report = Join-Path -Path $PSScriptRoot -ChildPath '..\examples\live-test-2026-09-24\live-test.html'
        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        $results.Count | Should -Be 71
    }
}

Describe 'Test-ReportMarkup' {
    It 'returns the screenshots of a genuine report with their decoded attributes' {
        $report = New-TestReport -Folder (Join-Path $TestDrive 'markup') -Full
        $scan = Test-ReportMarkup -Html ([System.IO.File]::ReadAllText($report))
        $scan.Problems | Should -BeNullOrEmpty
        @($scan.Images.Kind) | Should -Be @('logo', 'screenshot', 'screenshot')
        $scan.Images[1].Attributes['data-file'] | Should -Be '003_Admin_users_seg01.jpg'
        $scan.Images[1].Attributes['data-url'] | Should -Be 'https://app.example.com/admin/users?page=1'
    }
}
Describe 'Resolve-ReportImagePath (what -Verify may read)' {
    It 'accepts <Source>' -ForEach @(
        @{ Source = 'images/report/x.jpg'; Expected = 'C:\r\images\report\x.jpg' }
        @{ Source = 'images/My%20report/x.jpg'; Expected = 'C:\r\images\My report\x.jpg' }
        @{ Source = 'images/../images/report/x.jpg'; Expected = 'C:\r\images\report\x.jpg' }
        @{ Source = 'x.jpg'; Expected = 'C:\r\x.jpg' }
    ) {
        $located = Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source $Source
        $located.Problem | Should -Be ''
        $located.Path | Should -Be $Expected
    }

    It 'refuses <Source> with a plain reason' -ForEach @(
        @{ Source = 'C:\Windows\win.ini'; Reason = '*drive*' }
        @{ Source = 'c:x.jpg'; Reason = '*drive*' }
        @{ Source = 'C%3A%5CWindows%5Cwin.ini'; Reason = '*drive*' }
        @{ Source = '\\server\share\x.jpg'; Reason = '*rooted or network*' }
        @{ Source = '//server/share/x.jpg'; Reason = '*rooted or network*' }
        @{ Source = '/Windows/win.ini'; Reason = '*rooted or network*' }
        @{ Source = '\Windows\win.ini'; Reason = '*rooted or network*' }
        @{ Source = 'file:///C:/Windows/win.ini'; Reason = '*web or other address*' }
        @{ Source = 'http://example.com/x.jpg'; Reason = '*web or other address*' }
        @{ Source = 'https://example.com/x.jpg'; Reason = '*web or other address*' }
        @{ Source = '../secret.jpg'; Reason = '*outside the report*' }
        @{ Source = 'images/../../secret.jpg'; Reason = '*outside the report*' }
        @{ Source = '..%2F..%2Fsecret.jpg'; Reason = '*outside the report*' }
        @{ Source = 'images\..\..\secret.jpg'; Reason = '*outside the report*' }
        @{ Source = 'x.jpg:stream'; Reason = '*not a plain file name*' }
        @{ Source = 'x.jpg?v=1'; Reason = '*not a plain file name*' }
        @{ Source = ''; Reason = '*names no image*' }
    ) {
        $located = Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source $Source
        $located.Path | Should -Be ''
        $located.Problem | Should -BeLike $Reason
    }
}

Describe 'Linked reports (images as files next to the report)' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $folder)
    }

    It 'links each image by a relative src, with the same data-* attributes, and verifies' {
        $report = New-TestReport -Folder $folder -Linked
        $html = [System.IO.File]::ReadAllText($report)
        $html | Should -Not -Match 'base64,'
        $html | Should -Match ([regex]::Escape('data-url="https://app.example.com/admin/users?page=1" src="images/report/003_Admin_users_seg01.jpg">'))
        $html | Should -Match 'Linked report:'
        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($results | Where-Object Check -like 'Image *').Count | Should -Be 2
        @($results | Where-Object Check -like 'Metadata *').Count | Should -Be 2
    }

    It 'fails, naming the file, when one image file was altered' {
        $report = New-TestReport -Folder $folder -Linked
        $file = Join-Path $folder 'images\report\003_Admin_users_seg02.jpg'
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes[$bytes.Length - 20] = $bytes[$bytes.Length - 20] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($file, $bytes)
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }).Check
        $failed | Should -Contain 'Image 003_Admin_users_seg02.jpg'
        $failed | Should -Contain 'File 003_Admin_users_seg02.jpg'
        $failed | Should -Not -Contain 'Image 003_Admin_users_seg01.jpg'
    }

    It 'fails when one image file was removed' {
        $report = New-TestReport -Folder $folder -Linked
        Remove-Item -LiteralPath (Join-Path $folder 'images\report\003_Admin_users_seg01.jpg')
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok })
        ($failed | Where-Object Check -eq 'Image 003_Admin_users_seg01.jpg').Detail | Should -BeLike '*missing*'
    }

    It 'fails when two image files were swapped' {
        $report = New-TestReport -Folder $folder -Linked
        $a = Join-Path $folder 'images\report\003_Admin_users_seg01.jpg'
        $b = Join-Path $folder 'images\report\003_Admin_users_seg02.jpg'
        Rename-Item -LiteralPath $a -NewName 'tmp.jpg'
        Rename-Item -LiteralPath $b -NewName '003_Admin_users_seg01.jpg'
        Rename-Item -LiteralPath (Join-Path $folder 'images\report\tmp.jpg') -NewName '003_Admin_users_seg02.jpg'
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }).Check
        $failed | Should -Contain 'Image 003_Admin_users_seg01.jpg'
        $failed | Should -Contain 'Image 003_Admin_users_seg02.jpg'
    }

    It 'never reads a file outside the report''s folder, whatever a hostile report names (<Source>)' -ForEach @(
        @{ Source = '../outside.jpg' }
        @{ Source = 'C:/outside.jpg' }
        @{ Source = 'file:///C:/outside.jpg' }
        @{ Source = '\\localhost\c$\outside.jpg' }
    ) {
        $report = New-TestReport -Folder $folder -Linked
        # A valid image with the right hash next to (outside) the report's folder.
        $outside = Join-Path (Split-Path $folder -Parent) 'outside.jpg'
        Copy-Item -LiteralPath (Join-Path $folder 'images\report\003_Admin_users_seg01.jpg') -Destination $outside -Force
        $html = [System.IO.File]::ReadAllText($report).Replace('src="images/report/003_Admin_users_seg01.jpg"', "src=""$Source""")
        [System.IO.File]::WriteAllText($report, $html)
        Mock Get-Sha256Hex { throw 'never reached for the outside file' } -ParameterFilter { $false }
        $results = @(Test-ReportIntegrity -Path $report)
        ($results | Where-Object Check -eq 'Report markup').Detail | Should -BeLike "A screenshot's image address is not in the form Vouch writes*"
        @($results | Where-Object Check -like '* 003_Admin_users_seg01.jpg' | Where-Object Check -notlike 'File *').Count | Should -Be 0 -Because 'the screenshot is refused before any file is read'
        ($results | Where-Object Check -eq 'Manifest').Ok | Should -BeFalse
    }

    It 'Resolve-ReportImagePath still refuses <Source> on its own' -ForEach @(
        @{ Source = '../outside.jpg' }, @{ Source = 'C:/outside.jpg' }, @{ Source = 'file:///C:/outside.jpg' }, @{ Source = '\\localhost\c$\outside.jpg' }
    ) {
        (Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source $Source).Problem | Should -Not -BeNullOrEmpty
    }

    It 'reports a src that is neither an image nor a file as a failure, not an exception' {
        $report = New-TestReport -Folder $folder
        $html = [regex]::Replace([System.IO.File]::ReadAllText($report), 'src="data:image/jpeg;base64,[^"]*"', 'src="data:text/html;base64,PGI+"', 1)
        [System.IO.File]::WriteAllText($report, $html)
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok })
        ($failed | Where-Object Check -eq 'Report markup').Detail | Should -BeLike "A screenshot's image address is not in the form Vouch writes*"
    }
}

Describe 'Get-ScreenCapture with metadata' -Tag 'Desktop' {
    It 'embeds the metadata in a real <Format> screen capture' -ForEach @(@{ Format = 'jpeg' }, @{ Format = 'png' }) {
        $bytes = Get-ScreenCapture -Format $Format -Quality 60 -Metadata (New-TestMetadata)
        (Get-ImageMetadata -Bytes $bytes).ItemName | Should -Be 'Admin – users'
    }
}

Describe 'ConvertTo-EvidenceImage' {
    BeforeAll {
        function New-TestBitmap {
            $bitmap = [System.Drawing.Bitmap]::new(120, 80, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::White)
            $graphics.FillRectangle([System.Drawing.Brushes]::SteelBlue, 10, 10, 60, 30)
            $graphics.FillEllipse([System.Drawing.Brushes]::OrangeRed, 50, 30, 50, 40)
            $graphics.Dispose()
            return $bitmap
        }
        # The encoding Get-ScreenCapture had before ConvertTo-EvidenceImage was split out of it.
        function ConvertTo-OldPathImage([System.Drawing.Bitmap]$Bitmap, [string]$Format, [int]$Quality, $Metadata) {
            $stream = [System.IO.MemoryStream]::new()
            try {
                $encoder = $null
                if ($Format -eq 'jpeg') {
                    $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
                }
                if ($null -ne $encoder) {
                    if ($null -ne $Metadata) { Set-JpegMetadata -Image $Bitmap -Metadata $Metadata }
                    $parameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
                    $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
                    $Bitmap.Save($stream, $encoder, $parameters)
                    $parameters.Dispose()
                    return , $stream.ToArray()
                }
                $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $png = $stream.ToArray()
                if ($null -ne $Metadata) { $png = Add-PngTextChunks -Png $png -Metadata $Metadata }
                return , $png
            }
            finally { $stream.Dispose() }
        }
    }

    It 'gives the same <Format> bytes and metadata as the old screen-capture path for a bitmap' -ForEach @(@{ Format = 'jpeg' }, @{ Format = 'png' }) {
        $metadata = New-TestMetadata
        $first = New-TestBitmap
        $second = New-TestBitmap
        try {
            $old = ConvertTo-OldPathImage -Bitmap $first -Format $Format -Quality 70 -Metadata $metadata
            $new = ConvertTo-EvidenceImage -Bitmap $second -Format $Format -Quality 70 -Metadata $metadata
        }
        finally { $first.Dispose(); $second.Dispose() }
        , $new | Should -BeOfType [byte[]]
        Get-Sha256Hex -Bytes $new | Should -Be (Get-Sha256Hex -Bytes $old)
        (Get-ImageMetadata -Bytes $new).ItemName | Should -Be 'Admin – users'
    }

    It 'adds the metadata to a JPEG the browser encoded without touching the picture' {
        $bitmap = New-TestBitmap
        $stream = [System.IO.MemoryStream]::new()
        try { $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg); $plain = $stream.ToArray() }
        finally { $stream.Dispose(); $bitmap.Dispose() }

        $tagged = ConvertTo-EvidenceImage -EncodedImage $plain -Format jpeg -Metadata (New-TestMetadata)
        $read = Get-ImageMetadata -Bytes $tagged
        $read.ItemName | Should -Be 'Admin – users'
        $read.PageUrl | Should -Be 'https://app.example.com/admin/users?page=1'
        $read.CapturedAt | Should -Be '2026-09-24T06:01:02.345-07:00'
        $read.CaptureArea | Should -Be 'screen'
        # Same file with one APP1 segment more: SOI + JFIF APP0 first, everything after it unchanged.
        $app0 = 4 + ($plain[4] * 256 + $plain[5])
        $added = $tagged.Length - $plain.Length
        $added | Should -BeGreaterThan 100
        [byte[]]$tagged[0..($app0 - 1)] | Should -Be ([byte[]]$plain[0..($app0 - 1)])
        @($tagged[$app0], $tagged[$app0 + 1]) | Should -Be @(0xFF, 0xE1)
        Get-Sha256Hex -Bytes ([byte[]]$tagged[($app0 + $added)..($tagged.Length - 1)]) |
            Should -Be (Get-Sha256Hex -Bytes ([byte[]]$plain[$app0..($plain.Length - 1)]))
        $image = [System.Drawing.Image]::FromStream([System.IO.MemoryStream]::new($tagged))
        try {
            $image.Width | Should -Be 120
            [System.Text.Encoding]::ASCII.GetString($image.GetPropertyItem(0x013B).Value).TrimEnd([char]0) | Should -Be 'CORP\auditor'
        }
        finally { $image.Dispose() }
    }

    It 'adds the metadata to a PNG the browser encoded' {
        $png = New-TestImage -Format png -Metadata $null
        $tagged = ConvertTo-EvidenceImage -EncodedImage $png -Format png -Metadata (New-TestMetadata)
        (Get-ImageMetadata -Bytes $tagged).CapturedAtUtc | Should -Be '2026-09-24T13:01:02.345Z'
        [byte[]]$tagged[0..32] | Should -Be ([byte[]]$png[0..32])
    }

    It 'refuses data that is not a JPEG' {
        { ConvertTo-EvidenceImage -EncodedImage ([byte[]](1..40)) -Format jpeg -Metadata (New-TestMetadata) } | Should -Throw '*Not a JPEG*'
    }

    It 'records the capture area and zoom in the metadata' {
        $metadata = New-CaptureMetadata -RunId 'r' -ItemIndex 1 -ItemName 'n' -RequestedUrl 'https://a/' -PageUrl 'https://a/' `
            -CapturedAt $script:CapturedAt -SegmentIndex 1 -SegmentCount 1 -Screen '800x600 image of the page content only' -CaptureArea page -ZoomPercent 150
        $bytes = New-TestImage -Format jpeg -Metadata $metadata
        $read = Get-ImageMetadata -Bytes $bytes
        $read.CaptureArea | Should -Be 'page'
        $read.ZoomPercent | Should -Be 150
        $read.Screen | Should -BeLike '*page content only*'
    }
}

Describe 'Window capture (screen grab mocked)' {
    It 'cuts the window out of the screen image' {
        Mock Get-ScreenBitmap {
            $bitmap = [System.Drawing.Bitmap]::new(400, 300, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::Black)
            $graphics.FillRectangle([System.Drawing.Brushes]::Red, 100, 50, 200, 150)
            $graphics.Dispose()
            $bitmap
        }
        $bytes = Get-WindowCapture -Rectangle ([System.Drawing.Rectangle]::new(100, 50, 200, 150)) -Format png -Metadata (New-TestMetadata)
        $image = [System.Drawing.Bitmap]::new([System.IO.MemoryStream]::new($bytes))
        try {
            $image.Width | Should -Be 200
            $image.Height | Should -Be 150
            $image.GetPixel(0, 0).R | Should -Be 255
            $image.GetPixel(199, 149).R | Should -Be 255
        }
        finally { $image.Dispose() }
        (Get-ImageMetadata -Bytes $bytes).ItemName | Should -Be 'Admin – users'
    }
}

Describe 'What -Verify accepts: only what Vouch writes, in the whole document (fix round 3)' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $folder)
    }
    BeforeAll {
        function Edit-Report([string]$Path, [scriptblock]$Change) {
            [System.IO.File]::WriteAllText($Path, (& $Change ([System.IO.File]::ReadAllText($Path))))
        }
        function Get-FailedCheck([string]$Path) { @(Test-ReportIntegrity -Path $Path | Where-Object { -not $_.Ok }) }
        function Get-MarkupProblem([string]$Path) { @((Get-FailedCheck $Path) | Where-Object { $_.Check -in 'Report markup', 'Report styles' }) }
        $script:FirstShot = '<img alt="[^"]*" data-file="003_Admin_users_seg01\.jpg"[^>]*>'
    }

    It 'passes a genuine full-featured 2.0 report (<Classification>, <Form>) with hostile user text, all of it encoded' -ForEach @(
        @{ Classification = ''; Form = 'embedded'; Linked = $false }, @{ Classification = 'Public'; Form = 'embedded'; Linked = $false }
        @{ Classification = 'Internal'; Form = 'linked'; Linked = $true }, @{ Classification = 'Private'; Form = 'embedded'; Linked = $false }
        @{ Classification = 'Confidential'; Form = 'linked'; Linked = $true }, @{ Classification = 'Confidential'; Form = 'embedded'; Linked = $false }
    ) {
        $report = New-TestReport -Folder $folder -Linked:$Linked -Full -Classification $Classification
        $html = [System.IO.File]::ReadAllText($report)
        $html | Should -Match 'data-vouch-logo="true"'
        $html | Should -Match 'id="contents"'
        $html | Should -Match '<figure id="item-3-c2">'
        $html | Should -Match '&lt;img src=x&gt;'
        $html | Should -Match '&amp;period;'
        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($results | Where-Object Check -like 'Image *').Count | Should -Be 2
    }

    # (a) The logo where screenshot 1 was, the title moved to the end, the real screenshot hidden.
    It 'fails the logo moved into the evidence with the real screenshot hidden in <Wrapper>' -ForEach @(@{ Wrapper = 'noscript' }, @{ Wrapper = 'template' }) {
        $report = New-TestReport -Folder $folder -Full
        Edit-Report $report {
            param($h)
            $logo = [regex]::Match($h, '<img class="logo"[^>]*>').Value
            $title = [regex]::Match($h, '<h1>[^<]*</h1>').Value
            $shot = [regex]::Match($h, $script:FirstShot).Value
            $h = $h.Replace($logo, '').Replace($title, '').Replace('</body>', "$title</body>")
            $h.Replace($shot, "$logo<$Wrapper>$shot</$Wrapper>")
        }
        $problems = (Get-MarkupProblem $report).Detail -join ' | '
        $problems | Should -Match "<$Wrapper> element, which Vouch never writes|company logo is not at the start"
    }

    It 'fails a picture set through <Case>' -ForEach @(
        @{ Case = 'body background'; Old = '<body>'; New = '<body background="fake.png">'; Pattern = 'attribute background' }
        @{ Case = 'table background'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><table background="fake.png" width="2000" height="2000"></table>'; Pattern = 'attribute background' }
        @{ Case = 'a style attribute'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><div style="background:url(fake.png);width:1280px;height:800px"></div>'; Pattern = 'attribute style' }
        @{ Case = 'a second style sheet'; Old = '</head>'; New = '<style>@import url(http://evil.example/x.css); figure img{content:url(fake.png)}</style></head>'; Pattern = 'styles \(CSS\) are not|exactly one' }
    ) {
        $report = New-TestReport -Folder $folder -Linked
        Edit-Report $report { param($h) $h.Replace($Old, $New) }
        ((Get-MarkupProblem $report).Detail -join ' | ') | Should -Match $Pattern
    }

    It 'fails a linked src the browser and the checker would read differently (<Case>)' -ForEach @(
        @{ Case = '&period;'; From = '003_Admin_users_seg01.jpg"'; To = '003_Admin_users_seg01&period;jpg"' }
        @{ Case = 'a trailing &nbsp;'; From = '003_Admin_users_seg01.jpg"'; To = '003_Admin_users_seg01.jpg&nbsp;"' }
    ) {
        $report = New-TestReport -Folder $folder -Linked
        # The file the checker would have read, so only the markup rule can catch it.
        Copy-Item -LiteralPath (Join-Path $folder 'images\report\003_Admin_users_seg01.jpg') -Destination (Join-Path $folder "images\report\003_Admin_users_seg01$($Case -replace '[^a-z]', '').jpg")
        Edit-Report $report { param($h) ([regex][regex]::Escape($From)).Replace($h, $To, 1) }
        @(Get-MarkupProblem $report).Count | Should -BeGreaterOrEqual 1
    }

    It 'Resolve-ReportImagePath refuses edge spaces instead of trimming them' {
        (Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source 'images/r/x.jpg ').Problem | Should -BeLike '*starts or ends with a space'
        (Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source 'images/r/x.jpg%C2%A0').Problem | Should -BeLike '*starts or ends with a space'
    }

    It 'fails <Case>' -ForEach @(
        @{ Case = 'a foreign tag'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><marquee>x</marquee>'; Pattern = '<marquee> element' }
        @{ Case = 'a foreign attribute on a known tag'; Old = '<h2>Evidence</h2>'; New = '<h2 title="x">Evidence</h2>'; Pattern = 'attribute title' }
        @{ Case = 'an event attribute'; Old = '<body>'; New = '<body onload="x">'; Pattern = 'attribute onload' }
        @{ Case = 'a style attribute on a screenshot'; Old = '<img alt="'; New = '<img style="content:url(x)" alt="'; Pattern = 'attribute style' }
        @{ Case = 'an http href'; Old = 'href="#item-3"'; New = 'href="http://evil.example/"'; Pattern = 'href is not a value Vouch writes' }
        @{ Case = 'a javascript href'; Old = 'href="#item-3"'; New = 'href="javascript:alert(1)"'; Pattern = 'href is not a value Vouch writes' }
        @{ Case = 'a bare &'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence & more</h2>'; Pattern = 'character reference or &' }
        @{ Case = '&period;'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence&period;</h2>'; Pattern = 'character reference or &' }
        @{ Case = 'a raw > in text'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence > x</h2>'; Pattern = 'markup Vouch never writes' }
        @{ Case = 'an upper-case tag'; Old = '<h2>Evidence</h2>'; New = '<H2>Evidence</H2>'; Pattern = 'markup Vouch never writes' }
        @{ Case = 'a comment'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><!-- x -->'; Pattern = 'markup Vouch never writes' }
        @{ Case = 'a base element'; Old = '<head>'; New = '<head><base href="http://evil.example/">'; Pattern = '<base> element' }
        @{ Case = 'an image element'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><image src="fake.png">'; Pattern = '<image> element' }
        @{ Case = 'a script'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><script>1</script>'; Pattern = '<script> element' }
        @{ Case = 'a duplicate attribute'; Old = '<img alt="'; New = '<img alt="x" alt="'; Pattern = 'alt twice' }
        @{ Case = 'an unquoted value'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><img src=fake.png>'; Pattern = 'markup Vouch never writes' }
        @{ Case = 'a single-quoted value'; Old = '<h2>Evidence</h2>'; New = "<h2>Evidence</h2><img src='fake.png'>"; Pattern = 'markup Vouch never writes' }
        @{ Case = 'two h1'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2><h1>Again</h1>'; Pattern = '2 <h1> element' }
        @{ Case = 'a screenshot outside its figure'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2>@SHOT@'; Pattern = 'not inside the report''s evidence section' }
        @{ Case = 'a screenshot inside an unknown element'; Old = '<figure>'; New = '<figure><object>'; Pattern = '<object> element|not nested' }
        @{ Case = 'wrong nesting'; Old = '</figure>'; New = '</section></figure>'; Pattern = 'not nested the way Vouch writes' }
    ) {
        $report = New-TestReport -Folder $folder
        Edit-Report $report {
            param($h)
            $replacement = $New.Replace('@SHOT@', [regex]::Match($h, $script:FirstShot).Value)
            ([regex][regex]::Escape($Old)).Replace($h, $replacement, 1)
        }
        ((Get-MarkupProblem $report).Detail -join ' | ') | Should -Match $Pattern
    }

    It 'fails a style sheet changed by one character' {
        $report = New-TestReport -Folder $folder -Full
        Edit-Report $report { param($h) $h.Replace('h1 { font-size: 22px;', 'h1 { font-size: 23px;') }
        $failed = Get-FailedCheck $report
        ($failed | Where-Object Check -eq 'Report styles').Detail | Should -BeLike "The report's styles (CSS) are not a style sheet Vouch writes*"
    }

    It 'fails <Case>' -ForEach @(
        @{ Case = 'a second logo'; Old = '<header class="company"><img class="logo"'; New = '<header class="company">@LOGO@<img class="logo"'; Pattern = 'logo is not at the start' }
        @{ Case = 'a logo outside the header'; Old = '<h2>Evidence</h2>'; New = '<h2>Evidence</h2>@LOGO@'; Pattern = 'logo is not at the start' }
        @{ Case = 'a logo that is not stored in the report'; Old = 'src="data:image/png;base64,iVBORw0KGgo="'; New = 'src="logo.png"'; Pattern = 'not an image stored inside the report' }
        @{ Case = 'a header that is not at the top'; Old = '</body>'; New = '<header class="company"></header></body>'; Pattern = 'parts are not the ones Vouch writes' }
    ) {
        $report = New-TestReport -Folder $folder -Full
        Edit-Report $report {
            param($h)
            $replacement = $New.Replace('@LOGO@', [regex]::Match($h, '<img class="logo"[^>]*>').Value)
            ([regex][regex]::Escape($Old)).Replace($h, $replacement, 1)
        }
        ((Get-MarkupProblem $report).Detail -join ' | ') | Should -Match $Pattern
    }

    It 'fails a <Form> report with one screenshot tag duplicated' -ForEach @(@{ Form = 'embedded'; Linked = $false }, @{ Form = 'linked'; Linked = $true }) {
        $report = New-TestReport -Folder $folder -Linked:$Linked
        Edit-Report $report { param($h) $tag = [regex]::Match($h, $script:FirstShot).Value; $h.Replace($tag, "$tag`n$tag") }
        (Get-FailedCheck $report).Check | Should -Contain 'Manifest'
    }

    It 'fails a <Form> report with two screenshot tags swapped' -ForEach @(@{ Form = 'embedded'; Linked = $false }, @{ Form = 'linked'; Linked = $true }) {
        $report = New-TestReport -Folder $folder -Linked:$Linked
        Edit-Report $report {
            param($h)
            $tags = [regex]::Matches($h, '<img alt="[^"]*" data-file[^>]*>')
            $a = $tags[0].Value; $b = $tags[1].Value
            $h.Replace($a, '@@A@@').Replace($b, $a).Replace('@@A@@', $b)
        }
        (Get-FailedCheck $report).Check | Should -Contain 'Manifest'
    }

    It 'fails the <Form> report whose screenshot lacks <Attribute>' -ForEach @(
        @{ Form = 'embedded'; Linked = $false; Attribute = 'data-captured' }, @{ Form = 'embedded'; Linked = $false; Attribute = 'data-url' }
        @{ Form = 'linked'; Linked = $true; Attribute = 'data-captured' }, @{ Form = 'linked'; Linked = $true; Attribute = 'data-url' }
    ) {
        $report = New-TestReport -Folder $folder -Linked:$Linked
        Edit-Report $report { param($h) ([regex]" $Attribute=""[^""]*""").Replace($h, '', 1) }
        $failed = Get-FailedCheck $report
        ($failed | Where-Object Check -eq 'Report markup').Detail | Should -BeLike 'An image is neither a screenshot*'
        $failed.Check | Should -Contain 'Manifest'
    }
}

Describe 'Report style sheet pins' {
    It 'pins every style sheet this version writes, and keeps the 1.3.0 and 2.0.0 ones' {
        $known = Get-KnownReportCssHash
        $current = Get-CurrentReportCssHash
        $missing = @($current.Keys | Where-Object { -not $known.Contains($_) })
        $missing | Should -BeNullOrEmpty -Because "the report CSS (Get-ReportCss) changed: add these SHA-256 values to Get-KnownReportCssHash and keep the old ones there, or older reports stop verifying: $($missing -join ', ')"
        # Each sheet is pinned as the kind of report it belongs to: -Verify holds the document to it.
        @($current.Values) | Should -Be @('plain', 'options', 'Public', 'Internal', 'Private', 'Confidential')
        foreach ($hash in $current.Keys) { $known[$hash] | Should -BeExactly $current[$hash] -Because "$hash is the style sheet of a '$($current[$hash])' report" }
        # Released style sheets: removing any of these breaks -Verify for reports made by that version.
        foreach ($hash in 'c777d90eb3cf23596ed8e5f857508c5165ce399b7ae03676697aae9dcd251190', 'b159902f6ac1f1e8d0d58f5ef93ebc01c7c5c4d51c33cbd831195b918fd748b4',
            '2b4c494d2f22318be79409d18f969ae47b589600f08e2a4879eea93eec0748b1', '96805324fe4f2c698b02cf5e5032a077aba5d0414c36b3c3c91ae0744f061c17',
            '550b8033a6dc5924662ff306df27e3168166bf87aa51de75392ddaf5a83d3350', '584a9b4957c6ba72dfa3eebea97fe71e93182fdf5564f5ace1b71255930bebf0') {
            $known.Contains($hash) | Should -BeTrue -Because "$hash is the style sheet of a released Vouch version and must stay pinned"
        }
    }

    It 'pins the style sheet of the committed 1.3 example' {
        $html = [System.IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath '..\examples\live-test-2026-09-24\live-test.html'))
        $start = $html.IndexOf('<style>') + 7
        (Get-KnownReportCssHash).Contains((Get-ReportCssHash -Text $html.Substring($start, $html.IndexOf('</style>') - $start))) | Should -BeTrue
    }
}

Describe 'What -Verify accepts: a report of the kind its style sheet belongs to (fix round 4)' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $folder)
    }
    BeforeAll {
        function Get-FailedCheck([string]$Path) { @(Test-ReportIntegrity -Path $Path | Where-Object { -not $_.Ok }) }
        function Get-MarkupProblem([string]$Path) { @((Get-FailedCheck $Path) | Where-Object { $_.Check -in 'Report markup', 'Report styles' }) }
        function Edit-TestReport([string]$Path, [object[]]$Edits, [string]$Sheet) {
            <#
                Applies a test case to a genuine report: -Sheet swaps in another of Vouch's
                own style sheets; each edit replaces a pattern with literal text, in which
                @H1@, @FOOTER@, @LOGO@, @SHOT@, @FIGURE@, @SECTION@ stand for those parts of
                the genuine report and @BIGLOGO@ for a 1280x3000 SVG logo.
            #>
            $html = [System.IO.File]::ReadAllText($Path)
            $svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="3000"><rect width="1280" height="3000" fill="#e00"/></svg>'
            $parts = @{
                '@H1@' = [regex]::Match($html, '<h1>[^<]*</h1>').Value
                '@FOOTER@' = [regex]::Match($html, '<footer>[^<]*</footer>').Value
                '@LOGO@' = [regex]::Match($html, '<img class="logo"[^>]*>').Value
                '@SHOT@' = [regex]::Match($html, '<img alt="[^"]*" data-file="003_Admin_users_seg01\.jpg"[^>]*>').Value
                '@FIGURE@' = [regex]::Match($html, '(?s)<figure[^>]*>.*?</figure>').Value
                '@SECTION@' = [regex]::Match($html, '(?s)<section.*?</section>').Value
                '@BIGLOGO@' = '<img class="logo" data-vouch-logo="true" alt="Company logo" src="data:image/svg+xml;base64,' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($svg)) + '">'
            }
            if ($Sheet) {
                $options = switch ($Sheet) { 'plain' { $null } 'options' { New-ReportOptions } default { New-ReportOptions -Classification $Sheet } }
                $css = "`r`n" + (Get-ReportCss -Options $options) + "`r`n"
                $html = [regex]::Replace($html, '(?s)<style>.*?</style>', { "<style>$css</style>" })
            }
            foreach ($edit in @($Edits | Where-Object { $_ })) {
                $with = [string]$edit.With
                foreach ($key in $parts.Keys) { $with = $with.Replace($key, $parts[$key]) }
                $changed = ([regex]$edit.Regex).Replace($html, { $with }, 1)
                if ($changed -ceq $html) { throw "The test's edit '$($edit.Regex)' changed nothing." }
                $html = $changed
            }
            [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
        }
        function New-BareReport([string]$Path, [object[]]$Items, [AllowNull()][object]$Options) {
            $run = [pscustomobject]@{
                StartTime = 's'; EndTime = 'e'; TimeZone = 'tz'; Computer = 'PC01'; User = 'CORP\auditor'; OperatingSystem = 'os'
                EdgeVersion = 'Edg'; BrowserInstance = 'b'; CaptureDesktop = 'd'; ToolVersion = 'test'; CsvPath = 'c'; ImageFormat = 'jpeg'
                ImageDescription = 'JPEG'; ScreenResolution = '1280x800'; Total = @($Items).Count; OkCount = 0; WarnCount = 0; FailCount = @($Items).Count
                CaptureCount = 0; RunId = 'r'; ManifestSha256 = Get-Sha256Hex -Bytes ([byte[]]@())
            }
            [System.IO.File]::WriteAllText($Path, (New-HtmlReport -Items @($Items) -Run $run -Options $Options), [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'names the kind of a genuine report: <Kind>' -ForEach @(
        @{ Kind = 'plain'; Full = $false; Classification = '' }, @{ Kind = 'options'; Full = $true; Classification = '' }
        @{ Kind = 'Public'; Full = $true; Classification = 'Public' }, @{ Kind = 'Internal'; Full = $true; Classification = 'Internal' }
        @{ Kind = 'Private'; Full = $true; Classification = 'Private' }, @{ Kind = 'Confidential'; Full = $true; Classification = 'Confidential' }
    ) {
        $report = New-TestReport -Folder $folder -Full:$Full -Classification $Classification
        $scan = Test-ReportMarkup -Html ([System.IO.File]::ReadAllText($report))
        $scan.Problems | Should -BeNullOrEmpty
        $scan.Kind | Should -BeExactly $Kind
        $scan.Manifest | Should -Match '^[0-9a-f]{64}$'
        Get-FailedCheck $report | Should -BeNullOrEmpty
    }

    It 'still accepts a genuine report whose line ends a tool changed to LF' {
        $report = New-TestReport -Folder $folder -Full
        $html = [System.IO.File]::ReadAllText($report)
        $html | Should -Match "`r`n"
        [System.IO.File]::WriteAllText($report, $html.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        Get-FailedCheck $report | Should -BeNullOrEmpty
    }

    It 'accepts the markup of genuine reports with no page, a failed page without images, and the least of each option (<Case>)' -ForEach @(
        @{ Case = 'no options'; Options = @{}; Plain = $true }
        @{ Case = 'options, nothing set'; Options = @{}; Plain = $false }
        @{ Case = 'only a company name, no index'; Options = @{ CompanyName = 'ACME'; ShowIndex = $false }; Plain = $false }
        @{ Case = 'only a logo, classified'; Options = @{ LogoDataUri = 'data:image/gif;base64,R0lGODlhAQABAAAAACw='; Classification = 'Internal' }; Plain = $false }
        @{ Case = 'linked, classified'; Options = @{ EmbedImages = $false; ImageFolder = 'images\r'; Classification = 'Public' }; Plain = $false }
    ) {
        $failed = [pscustomobject]@{
            Index = 7; Name = 'Payroll <b>'; Url = 'https://a.example/?x=1&y=2'; FinalUrl = ''; Notes = 'n'; StepsText = 'click:#go > a'; ScrollFullPage = $false
            Status = 'FAILED'; HttpStatus = 0; Account = 'x@example.com'
            Details = [System.Collections.Generic.List[string]]@('one', 'two & three'); StepLog = [System.Collections.Generic.List[object]]::new()
            Captures = [System.Collections.Generic.List[object]]::new()
        }
        $stepped = $failed.PSObject.Copy()
        $stepped.Index = 8
        $stepped.StepLog = [System.Collections.Generic.List[object]]@(
            [pscustomobject]@{ Text = 'click:a'; Ok = $true; Message = '' }, [pscustomobject]@{ Text = 'wait:1'; Ok = $true; Message = 'done' }, [pscustomobject]@{ Text = 'click:b'; Ok = $false; Message = 'gone' })
        foreach ($set in 'none', 'two') {
            $items = if ($set -eq 'none') { @() } else { @($failed, $stepped) }
            $path = Join-Path $folder "bare-$set.html"
            $settings = $Options
            New-BareReport -Path $path -Items @($items) -Options $(if ($Plain) { $null } else { New-ReportOptions @settings })
            (Test-ReportMarkup -Html ([System.IO.File]::ReadAllText($path))).Problems | Should -BeNullOrEmpty
        }
    }

    It 'fails <Case>' -ForEach @(
        @{ Case = 'a company header with a huge logo added to a report without report options (no rule limits a logo there)'
            Edits = @(@{ Regex = '<body>'; With = "<body>`r`n<header class=""company"">@BIGLOGO@</header>" }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a full report given the style sheet without the logo limit, a huge logo, and its title moved to the end'; Full = $true; Sheet = 'plain'
            Edits = @(@{ Regex = '<img class="logo"[^>]*>'; With = '@BIGLOGO@' }, @{ Regex = '<h1>[^<]*</h1>'; With = '' }, @{ Regex = '</body>'; With = '@H1@</body>' })
            Pattern = 'only a report with report options has|parts are not the ones Vouch writes' }
        @{ Case = 'an unclassified full report given the style sheet without the logo limit'; Full = $true; Classification = ''; Sheet = 'plain'; Pattern = 'only a report with report options has' }
        @{ Case = 'a linked report given the style sheet of a report without report options'; Linked = $true; Sheet = 'plain'; Pattern = 'links its screenshots' }
        @{ Case = 'a report without report options given the style sheet of one with them'; Sheet = 'options'; Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a Confidential report given the Public style sheet'; Full = $true; Sheet = 'Public'; Pattern = 'those of a report classified Public' }
        @{ Case = 'a Confidential report given the unclassified style sheet'; Full = $true; Sheet = 'options'; Pattern = 'report options and no classification' }
        @{ Case = 'an unclassified report given the Confidential style sheet'; Full = $true; Classification = ''; Sheet = 'Confidential'; Pattern = 'those of a report classified Confidential' }
        @{ Case = 'a banner whose class says another level'; Full = $true; Edits = @(@{ Regex = 'top cls-confidential'; With = 'top cls-public' }); Pattern = 'banner does not read PUBLIC' }
        @{ Case = 'a banner whose text says another level'; Full = $true; Edits = @(@{ Regex = 'role="note">CONFIDENTIAL</div>'; With = 'role="note">PUBLIC</div>' }); Pattern = 'banner does not read CONFIDENTIAL' }
        @{ Case = 'a banner holding more than its text'; Full = $true; Edits = @(@{ Regex = 'role="note">CONFIDENTIAL</div>'; With = 'role="note">CONFIDENTIAL<strong>x</strong></div>' }); Pattern = 'banner holds more than its text' }
        @{ Case = 'the top banner removed'; Full = $true; Edits = @(@{ Regex = '<div class="classification top[^>]*>[^<]*</div>'; With = '' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'the bottom banner removed'; Full = $true; Edits = @(@{ Regex = '<div class="classification bottom[^>]*>[^<]*</div>'; With = '' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a banner added to an unclassified report'; Full = $true; Classification = ''
            Edits = @(@{ Regex = '<body>'; With = '<body><div class="classification top cls-public" role="note">PUBLIC</div>' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a banner inside a table cell'; Full = $true
            Edits = @(@{ Regex = '<td class="k">Run started</td><td>'; With = '<td class="k">Run started</td><td><div class="classification top cls-confidential" role="note">CONFIDENTIAL</div>' }); Pattern = '<div> directly inside a <td>' }
        @{ Case = 'the title moved to the end'; Edits = @(@{ Regex = '<h1>[^<]*</h1>'; With = '' }, @{ Regex = '</body>'; With = '@H1@</body>' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'the title moved above the company header'; Full = $true; Edits = @(@{ Regex = '<h1>[^<]*</h1>'; With = '' }, @{ Regex = '<header'; With = '@H1@<header' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'the footer moved above the evidence'; Edits = @(@{ Regex = '<footer>[^<]*</footer>'; With = '' }, @{ Regex = '<h2>Evidence</h2>'; With = '@FOOTER@<h2>Evidence</h2>' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a page section moved above the summary'; Edits = @(@{ Regex = '(?s)<section.*?</section>'; With = '' }, @{ Regex = '<h2>Summary</h2>'; With = '@SECTION@<h2>Summary</h2>' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'the note saying which form the report has removed'; Full = $true; Edits = @(@{ Regex = '<p class="integrity-note"><strong>.*?</p>'; With = '' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a paragraph added between the parts'; Edits = @(@{ Regex = '<h2>Evidence</h2>'; With = '<h2>Evidence</h2><p class="empty">All controls passed.</p>' }); Pattern = 'in a place where Vouch never writes one' }
        @{ Case = 'text added between the parts'; Edits = @(@{ Regex = '<h2>Evidence</h2>'; With = '<h2>Evidence</h2>All controls passed.' }); Pattern = 'text where Vouch writes none' }
        @{ Case = 'a no-break space between two table rows (text to a browser, which moves it out of the table)'; Edits = @(@{ Regex = '</tr>'; With = "</tr>$([char]0xA0)" }); Pattern = 'text where Vouch writes none' }
        @{ Case = 'text added after the document'; Edits = @(@{ Regex = '</html>'; With = '</html>All controls passed.' }); Pattern = 'text where Vouch writes none' }
        @{ Case = 'the head in another order'; Edits = @(@{ Regex = '<title>[^<]*</title>'; With = '' }, @{ Regex = '</head>'; With = '<title>x</title></head>' }); Pattern = 'not set out the way Vouch writes them' }
        @{ Case = 'a contents list in a report without report options'
            Edits = @(@{ Regex = '<h2>Summary</h2>'; With = '<nav class="contents-wrap" aria-label="Contents"><h2 id="contents">Contents</h2></nav><h2>Summary</h2>' }); Pattern = 'parts are not the ones Vouch writes' }
        @{ Case = 'a capture anchor in a report without report options'; Edits = @(@{ Regex = '<figure>'; With = '<figure id="item-3-c1">' }); Pattern = 'only a report with report options has' }
        @{ Case = 'a class Vouch does not put on that element'; Full = $true; Edits = @(@{ Regex = '<div class="company-name">'; With = '<div class="company-name logo">' }); Pattern = 'class is not a value Vouch writes' }
        @{ Case = 'a link to a place Vouch never links to'; Edits = @(@{ Regex = 'href="#item-3"'; With = 'href="#contents"' }); Pattern = 'href is not a value Vouch writes' }
        @{ Case = 'a screenshot in a figure inside the company header'; Full = $true; Edits = @(@{ Regex = '<div class="company-text">'; With = '<figure>@SHOT@</figure><div class="company-text">' }); Pattern = '<figure> directly inside a <header>' }
        @{ Case = 'the logo after the company text'; Full = $true; Edits = @(@{ Regex = '<img class="logo"[^>]*>'; With = '' }, @{ Regex = '</header>'; With = '@LOGO@</header>' }); Pattern = 'logo is not at the start' }
        @{ Case = 'a logo with another description'; Full = $true; Edits = @(@{ Regex = 'alt="Company logo"'; With = 'alt="Screenshot of payroll"' }); Pattern = 'neither a screenshot with its hash nor the company logo' }
        @{ Case = 'the screenshots under the heading of another page'; Edits = @(@{ Regex = '<section class="item" id="item-3">'; With = '<section class="item" id="item-4">' }); Pattern = 'not in the section of the page it was taken of' }
        @{ Case = 'a screenshot moved into the section of another page (order kept)'
            Edits = @(@{ Regex = '(?s)<figure[^>]*>.*?</figure>\r?\n'; With = '' }, @{ Regex = '<section class="item" id="item-3">'; With = "<section class=""item"" id=""item-2"">`r`n<h3>Screenshots</h3>`r`n@FIGURE@`r`n</section>`r`n<section class=""item"" id=""item-3"">" })
            Pattern = 'not in the section of the page it was taken of' }
        @{ Case = 'a linked screenshot whose address names another file than the one hashed'; Linked = $true
            Edits = @(@{ Regex = 'src="images/report/003_Admin_users_seg01.jpg"'; With = 'src="images/report/003_Admin_users_seg02.jpg"' }); Pattern = 'image address is not in the form Vouch writes' }
        @{ Case = 'linked and stored screenshots mixed'; Linked = $true
            Edits = @(@{ Regex = 'src="images/report/003_Admin_users_seg02.jpg"'; With = 'src="data:image/jpeg;base64,AAAA"' }); Pattern = 'not all stored the same way' }
        @{ Case = 'screenshots linked from two folders'; Linked = $true; CopyFolder = 'other'
            Edits = @(@{ Regex = 'src="images/report/003_Admin_users_seg02.jpg"'; With = 'src="images/other/003_Admin_users_seg02.jpg"' }); Pattern = 'not all in one folder' }
    ) {
        $report = New-TestReport -Folder $folder -Full:([bool]$Full) -Linked:([bool]$Linked) -Classification $(if ($null -ne $Classification) { $Classification } else { 'Confidential' })
        if ($CopyFolder) { Copy-Item -LiteralPath (Join-Path $folder 'images\report') -Destination (Join-Path $folder "images\$CopyFolder") -Recurse }
        Edit-TestReport -Path $report -Edits @($Edits) -Sheet $Sheet
        ((Get-MarkupProblem $report).Detail -join ' | ') | Should -Match $Pattern
    }
}

Describe 'Linked image addresses: only the spelling the generator writes (fix round 4)' {
    It 'accepts the folder part <Segment>' -ForEach @(
        @{ Segment = 'report' }, @{ Segment = 'My%20report' }, @{ Segment = 'Q3%20%231' }, @{ Segment = '100%25' }, @{ Segment = '%C3%9Cbersicht' }
        @{ Segment = 'a%2520b' }, @{ Segment = '%20Q3' }, @{ Segment = 'R%26D%20%27x%27%20%2B%3B%3D%40%24%2C%21~%5Bx%5D%28y%29' }, @{ Segment = '%F0%9F%98%80' }
    ) {
        Test-ReportImageFolderName -Segment $Segment | Should -BeTrue
    }

    It 'refuses the folder part <Segment> (<Why>)' -ForEach @(
        @{ Segment = '%FF'; Why = 'not UTF-8: .NET keeps it, Edge reads y-umlaut' }, @{ Segment = 'a%C2'; Why = 'cut-off UTF-8' }, @{ Segment = '%C0%AE%C0%AE'; Why = 'overlong dots' }
        @{ Segment = '%ED%A0%80'; Why = 'half a character pair' }, @{ Segment = '%2e%2e'; Why = 'escaped dots' }, @{ Segment = '%2E%2E'; Why = 'escaped dots' }
        @{ Segment = '..'; Why = 'parent folder' }, @{ Segment = '.'; Why = 'this folder' }, @{ Segment = 'x.'; Why = 'Windows drops the dot' }, @{ Segment = 'x%20'; Why = 'Windows drops the space' }
        @{ Segment = 'a%2Fb'; Why = 'a separator' }, @{ Segment = 'a%5Cb'; Why = 'a separator' }, @{ Segment = 'a%3Ab'; Why = 'a stream or drive' }, @{ Segment = 'a%3Fb'; Why = 'not a file name' }
        @{ Segment = 'r%65port'; Why = 'a letter needlessly escaped' }, @{ Segment = '%c3%9c'; Why = 'lower-case escape' }, @{ Segment = 'a%00'; Why = 'control character' }
        @{ Segment = 'a%0Ab'; Why = 'control character' }, @{ Segment = 'a b'; Why = 'raw space' }, @{ Segment = 'a%'; Why = 'bare percent' }, @{ Segment = 'a%zz'; Why = 'bare percent' }
        @{ Segment = 'a&amp;b'; Why = 'raw &' }, @{ Segment = ''; Why = 'empty' }
    ) {
        Test-ReportImageFolderName -Segment $Segment | Should -BeFalse
    }

    It 'fails a forged report whose folder is %FF, with the genuine images where .NET looks and others where Edge looks' {
        $folder = Join-Path $TestDrive 'ff'
        $report = New-TestReport -Folder $folder -Linked
        Copy-Item -LiteralPath (Join-Path $folder 'images\report') -Destination (Join-Path $folder 'images\%FF') -Recurse
        Copy-Item -LiteralPath (Join-Path $folder 'images\report') -Destination (Join-Path $folder "images\$([char]0xFF)") -Recurse
        [System.IO.File]::WriteAllText($report, [System.IO.File]::ReadAllText($report).Replace('src="images/report/', 'src="images/%FF/'), [System.Text.UTF8Encoding]::new($false))
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok })
        @($failed | Where-Object Detail -like "A screenshot's image address is not in the form Vouch writes*").Count | Should -Be 2
        @($failed | Where-Object Check -like 'Image *') | Should -BeNullOrEmpty -Because 'no file is read for a refused address'
    }

    It 'Resolve-ReportImagePath takes # written as %23 as part of a name, and refuses a raw # or ?' {
        (Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source 'images/Q3%20%231/001_a_seg01.jpg').Path | Should -Be 'C:\r\images\Q3 #1\001_a_seg01.jpg'
        (Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source 'images/Q3#1/001_a_seg01.jpg').Problem | Should -BeLike '*not a plain file name*'
        (Resolve-ReportImagePath -ReportDirectory 'C:\r' -Source 'images/Q3%3F1/001_a_seg01.jpg').Problem | Should -BeLike '*not a plain file name*'
    }
}

Describe 'Report names: every report Vouch writes verifies (fix round 4)' {
    It 'keeps the ordinary name <Name> as it is' -ForEach @(
        @{ Name = 'e2e.html'; Expected = 'e2e.html' }, @{ Name = 'typed'; Expected = 'typed.html' }, @{ Name = 'Q3 report'; Expected = 'Q3 report.html' }
        @{ Name = 'Contrôle d''accès 2026'; Expected = 'Contrôle d''accès 2026.html' }, @{ Name = 'Q3 #1 100% R&D (final) [v2]'; Expected = 'Q3 #1 100% R&D (final) [v2].html' }
        @{ Name = 'old.htm'; Expected = 'old.htm' }, @{ Name = 'LOUD.HTML'; Expected = 'LOUD.HTML' }, @{ Name = 'v1.2 notes'; Expected = 'v1.2 notes.html' }
    ) {
        $file = Get-ReportFileName -Name $Name -DefaultStem 'VouchReport_x'
        $file.Name | Should -BeExactly $Expected
        $file.Changed | Should -BeFalse
    }

    It 'gives the default name when none is asked for, and fills tokens' {
        (Get-ReportFileName -Name '  ' -DefaultStem 'VouchReport_x').Name | Should -Be 'VouchReport_x.html'
        $file = Get-ReportFileName -Name '{title}: {nope}' -DefaultStem 'VouchReport_x' -Values @{ title = 'Q3/ITGC' }
        $file.Name | Should -Be 'Q3_ITGC_ {nope}.html'
        $file.Unknown | Should -Be @('{nope}')
    }

    It 'makes <Label> a name that Windows keeps and a linked report can be followed and verified by' -ForEach @(
        @{ Label = 'a leading space'; Name = ' Q3'; Expected = 'Q3.html' }
        @{ Label = 'a trailing space'; Name = 'Q3 '; Expected = 'Q3.html' }
        @{ Label = 'a trailing dot'; Name = 'Q3.'; Expected = 'Q3.html' }
        @{ Label = 'a trailing dot before .html'; Name = 'Q3..html'; Expected = 'Q3.html' }
        @{ Label = 'a leading dot'; Name = '.Q3'; Expected = 'Q3.html' }
        @{ Label = 'a no-break space at the end'; Name = "Q3$([char]0xA0)"; Expected = 'Q3.html' }
        @{ Label = 'only dots'; Name = '...'; Expected = 'VouchReport_x.html' }
        @{ Label = 'only dots and spaces'; Name = ' . . '; Expected = 'VouchReport_x.html' }
        @{ Label = 'a #'; Name = 'Q3 #1'; Expected = 'Q3 #1.html' }
        @{ Label = 'a ?'; Name = 'what?'; Expected = 'what_.html' }
        @{ Label = 'a %'; Name = '100%'; Expected = '100%.html' }
        @{ Label = 'a % that looks like an escape'; Name = 'a%20b %FF %zz'; Expected = 'a%20b %FF %zz.html' }
        @{ Label = 'an &'; Name = 'R&D &amp; more'; Expected = 'R&D &amp; more.html' }
        @{ Label = 'an apostrophe'; Name = "Jane's"; Expected = "Jane's.html" }
        @{ Label = 'a +'; Name = 'a+b'; Expected = 'a+b.html' }
        @{ Label = 'a ;'; Name = 'a;b'; Expected = 'a;b.html' }
        @{ Label = 'an ='; Name = 'a=b'; Expected = 'a=b.html' }
        @{ Label = 'an @'; Name = 'a@b'; Expected = 'a@b.html' }
        @{ Label = 'a $'; Name = 'a$b $(x) ${y}'; Expected = 'a$b $(x) ${y}.html' }
        @{ Label = 'a comma'; Name = 'a,b'; Expected = 'a,b.html' }
        @{ Label = 'a !'; Name = 'a!b'; Expected = 'a!b.html' }
        @{ Label = 'a ~'; Name = '~a~b~1'; Expected = '~a~b~1.html' }
        @{ Label = 'square brackets'; Name = '[x] [*]'; Expected = '[x] [_].html' }
        @{ Label = 'round brackets'; Name = '(x)'; Expected = '(x).html' }
        @{ Label = 'a backtick and a caret'; Name = 'a`b^c'; Expected = 'a`b^c.html' }
        @{ Label = 'letters of other languages and an emoji'; Name = "Ünïcødé 日本語 $([char]::ConvertFromUtf32(0x1F600))"; Expected = "Ünïcødé 日本語 $([char]::ConvertFromUtf32(0x1F600)).html" }
        @{ Label = 'half a character pair'; Name = "a$([char]0xD83D)b"; Expected = 'a_b.html' }
        @{ Label = 'a tab and a line break'; Name = "a`tb`r`nc"; Expected = 'a_b_c.html' }
        @{ Label = 'characters Windows forbids'; Name = 'a/b\c:d*e"f<g>h|i'; Expected = 'a_b_c_d_e_f_g_h_i.html' }
        @{ Label = 'a path out of the folder'; Name = '..\..\evil'; Expected = '_.._evil.html' }
        @{ Label = 'the device name CON'; Name = 'CON'; Expected = '_CON.html' }
        @{ Label = 'the device name con.html'; Name = 'con.html'; Expected = '_con.html' }
        @{ Label = 'the device name NUL.txt'; Name = 'NUL.txt'; Expected = '_NUL.txt.html' }
        @{ Label = 'the device name COM1'; Name = 'COM1'; Expected = '_COM1.html' }
        @{ Label = 'the device name LPT with a superscript digit'; Name = "LPT$([char]0xB9)"; Expected = "_LPT$([char]0xB9).html" }
        @{ Label = 'the device name CONIN$'; Name = 'CONIN$'; Expected = '_CONIN$.html' }
        @{ Label = 'a very long name'; Name = ('Quarter 3 evidence ' * 20); Expected = $null }
        @{ Label = 'a very long name in another script'; Name = ('日本語' * 120); Expected = $null }
        @{ Label = 'a long name of emoji (pairs cut at the limit)'; Name = ('x' + ([char]::ConvertFromUtf32(0x1F600) * 100)); Expected = $null }
        @{ Label = 'a mix of all of it'; Name = ' .Q3 #1 100% & [x] (y) +;=@$,!~ Ü日本''s. '; Expected = 'Q3 #1 100% & [x] (y) +;=@$,!~ Ü日本''s.html' }
        @{ Label = 'an unknown token'; Name = 'a{nope}b'; Expected = 'a{nope}b.html' }
        @{ Label = 'two spaces'; Name = 'a  b'; Expected = 'a b.html' }
    ) {
        $file = Get-ReportFileName -Name $Name -DefaultStem 'VouchReport_x'
        if ($null -ne $Expected) { $file.Name | Should -BeExactly $Expected }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $stem.Length | Should -BeLessOrEqual 150
        $stem | Should -Not -Match '[\x00-\x1f\\/:*?"<>|]'
        $stem | Should -Not -Match '^[ .]|[ .]$'

        # The folder and files exactly as a capture run makes them, then the linked report.
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $folder)
        Assert-ReportLocation -ReportPath (Join-Path $folder $file.Name) -ImagesDir (Join-Path $folder "images\$stem")
        $report = New-TestReport -Folder $folder -Linked -Name $stem
        [System.IO.Path]::GetFileName($report) | Should -BeExactly "$stem.html"
        @(Get-ChildItem -LiteralPath (Join-Path $folder 'images')).Name | Should -BeExactly @($stem) -Because 'Windows must keep the folder name as written'

        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($results | Where-Object Check -like 'Image *').Count | Should -Be 2
        @($results | Where-Object Check -like 'File *').Count | Should -Be 2

        # What a browser does with each address: undo the %XX, look for that file.
        $sources = @([regex]::Matches([System.IO.File]::ReadAllText($report), ' src="(images/[^"]*)"') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
        $sources.Count | Should -Be 2
        foreach ($source in $sources) {
            $source | Should -Match '^images/[A-Za-z0-9._~%-]+/[A-Za-z0-9._-]+$'
            [System.IO.File]::Exists((Join-Path $folder ([System.Uri]::UnescapeDataString($source).Replace('/', '\')))) | Should -BeTrue -Because "$source must lead to the image"
        }
    }

    It 'refuses, before anything is captured, a report that cannot be saved where it is asked for' {
        $folder = Join-Path $TestDrive 'blocked'
        [void](New-Item -ItemType Directory -Path $folder)
        # A file where the images folder must be.
        Set-Content -LiteralPath (Join-Path $folder 'images') -Value 'x'
        { Assert-ReportLocation -ReportPath (Join-Path $folder 'r.html') -ImagesDir (Join-Path $folder 'images\r') } |
            Should -Throw -ExpectedMessage "The report cannot be saved as 'r.html' in '*blocked'*Choose a shorter or simpler report name*"
        { Assert-ReportLocation -ReportPath (Join-Path $folder 'no-such-folder\r.html') } | Should -Throw -ExpectedMessage 'The report cannot be saved as*'
        # A name Windows would quietly change is refused rather than written somewhere else.
        { Assert-ReportLocation -ReportPath (Join-Path $folder 'r.html') -ImagesDir (Join-Path $folder 'pictures\r.') } | Should -Throw -ExpectedMessage '*cannot keep an images folder of that name*'
        (Join-Path $folder 'r.html') | Should -Not -Exist
    }

    It 'leaves no trace of its test, and an existing report alone' {
        $folder = Join-Path $TestDrive 'free'
        [void](New-Item -ItemType Directory -Path $folder)
        Assert-ReportLocation -ReportPath (Join-Path $folder 'r.html') -ImagesDir (Join-Path $folder 'images\r')
        (Join-Path $folder 'r.html') | Should -Not -Exist
        (Join-Path $folder 'images\r') | Should -Exist
        Set-Content -LiteralPath (Join-Path $folder 'r.html') -Value 'earlier report'
        Assert-ReportLocation -ReportPath (Join-Path $folder 'r.html')
        Get-Content -LiteralPath (Join-Path $folder 'r.html') | Should -Be 'earlier report'
    }
}

Describe '-Verify on files that are not reports, and on very many faults (fix round 4)' {
    BeforeAll {
        $script:OddFolder = Join-Path $TestDrive 'odd'
        [void](New-Item -ItemType Directory -Path $script:OddFolder)
        $script:GenuineHtml = [System.IO.File]::ReadAllText((New-TestReport -Folder $script:OddFolder))
        $script:Utf8 = [System.Text.UTF8Encoding]::new($false)
    }

    It 'fails <Case> as a check, without an error (exit code 4)' -ForEach @(
        @{ Case = 'an empty file'; Bytes = { , [byte[]]@() } }
        @{ Case = 'only a doctype'; Bytes = { , $script:Utf8.GetBytes('<!DOCTYPE html>') } }
        @{ Case = 'binary garbage'; Bytes = { , [byte[]](0..255 * 40) } }
        @{ Case = 'a file of NUL bytes'; Bytes = { , [byte[]]::new(5000) } }
        @{ Case = 'an empty style sheet'; Bytes = { , $script:Utf8.GetBytes([regex]::Replace($script:GenuineHtml, '(?s)<style>.*?</style>', '<style></style>')) } }
        @{ Case = 'a second, empty style sheet'; Bytes = { , $script:Utf8.GetBytes($script:GenuineHtml.Replace('</head>', '<style></style></head>')) } }
        @{ Case = 'a style sheet that never ends'; Bytes = { , $script:Utf8.GetBytes($script:GenuineHtml.Replace('</style>', '')) } }
        @{ Case = 'a genuine report saved as UTF-16'; Bytes = { , ([System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($script:GenuineHtml)) } }
        @{ Case = 'a genuine report saved as UTF-32'; Bytes = { , ([System.Text.Encoding]::UTF32.GetPreamble() + [System.Text.Encoding]::UTF32.GetBytes($script:GenuineHtml)) } }
        @{ Case = 'a genuine report with a byte order mark'; Bytes = { , ([byte[]](0xEF, 0xBB, 0xBF) + $script:Utf8.GetBytes($script:GenuineHtml)) } }
        @{ Case = 'a genuine report with bytes that are not UTF-8 in its text'; Bytes = { , $script:Utf8.GetBytes($script:GenuineHtml.Replace('<footer>', '<footer>@@')) } }
        @{ Case = 'a document cut off in the middle'; Bytes = { , $script:Utf8.GetBytes($script:GenuineHtml.Substring(0, $script:GenuineHtml.IndexOf('<h2>Evidence'))) } }
    ) {
        $path = Join-Path $script:OddFolder "$([guid]::NewGuid()).html"
        $content = [byte[]](& $Bytes)
        if ($Case -like '*not UTF-8*') {
            # 0xC3 0x28: a lead byte followed by a byte that cannot follow it.
            $at = [System.Text.Encoding]::ASCII.GetString($content).IndexOf('@@')
            $content[$at] = 0xC3; $content[$at + 1] = 0x28
        }
        [System.IO.File]::WriteAllBytes($path, $content)
        { $script:OddResults = @(Test-ReportIntegrity -Path $path) } | Should -Not -Throw
        @($script:OddResults | Where-Object { -not $_.Ok }).Count | Should -BeGreaterOrEqual 1
        Invoke-VerifyReport -Path $path 6>$null | Should -Be 4
    }

    It 'fails a linked image file of 0 bytes as a check' {
        $folder = Join-Path $TestDrive 'zero'
        $report = New-TestReport -Folder $folder -Linked
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'images\report\003_Admin_users_seg01.jpg'), [byte[]]@())
        $failed = @(Test-ReportIntegrity -Path $report | Where-Object { -not $_.Ok }).Check
        $failed | Should -Contain 'Image 003_Admin_users_seg01.jpg'
        $failed | Should -Contain 'Metadata 003_Admin_users_seg01.jpg'
    }

    It 'stops reading a SHA256SUMS that lists one file again and again' {
        $folder = Join-Path $TestDrive 'sums'
        $report = New-TestReport -Folder $folder -Linked
        $sums = Join-Path $folder 'images\report\SHA256SUMS'
        $line = @(Get-Content -LiteralPath $sums)[0]
        [System.IO.File]::WriteAllText($sums, ("$line`n" * 50000))
        $results = @(Test-ReportIntegrity -Path $report)
        @($results | Where-Object Check -like 'File *').Count | Should -Be 2
        ($results | Where-Object Detail -like 'listed more than once*').Ok | Should -BeFalse
    }

    It 'lists the first 25 problems and says it stopped' {
        $html = $script:GenuineHtml.Replace('<footer>', ('<x>' * 500) + '<footer>')
        $scan = Test-ReportMarkup -Html $html
        $scan.Problems.Count | Should -Be 26
        $scan.Problems[0] | Should -BeLike 'The report contains a <x> element*'
        $scan.Problems[25] | Should -Be 'The check stopped here: only the first 25 problems are listed.'
    }

    It 'names the line of each problem' {
        $lines = $script:GenuineHtml -split "`r`n"
        $evidence = [array]::IndexOf($lines, '<h2>Evidence</h2>')
        $lines[$evidence] = '<h2>Evidence</h2><marquee>'
        $lines[3] = '<meta charset="utf-8"><base>'
        $problems = (Test-ReportMarkup -Html ($lines -join "`r`n")).Problems
        $problems[0] | Should -BeLike "The report contains a <base> element*(line 4, at '<base>*"
        $problems[1] | Should -BeLike "The report contains a <marquee> element*(line $($evidence + 1), at '<marquee>*"
    }

    It 'takes seconds, not minutes, over <Case>' -ForEach @(
        @{ Case = '32,000 unknown elements in a small report'; Insert = { '<x>' * 32000 }; Base = 'small' }
        @{ Case = '2,000 unknown elements in the 5 MB example'; Insert = { '<x>' * 2000 }; Base = 'example' }
        @{ Case = '100,000 broken references and paragraphs in the 5 MB example'; Insert = { '<p>&</p>' * 100000 }; Base = 'example' }
        @{ Case = '20 MB of line breaks before a fault'; Insert = { ("`n" * 20MB) + '<x>' }; Base = 'small' }
        @{ Case = '20 MB of <'; Insert = { '<' * 20MB }; Base = 'small' }
        @{ Case = 'one tag with 300,000 unknown attributes'; Insert = { '<p' + (' x="1"' * 300000) + '>' }; Base = 'small' }
        @{ Case = '50,000 valid elements more (a large genuine report)'; Insert = { '<section class="item" id="item-9"><h3>x</h3>' + ('<ul class="detail-list"><li>x</li></ul>' * 25000) + '</section>' }; Base = 'small'; Valid = $true }
    ) {
        $html = if ($Base -eq 'example') { [System.IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath '..\examples\live-test-2026-09-24\live-test.html')) } else { $script:GenuineHtml }
        $html = $html.Insert($html.LastIndexOf('<footer>'), (& $Insert))
        $path = Join-Path $script:OddFolder "$([guid]::NewGuid()).html"
        [System.IO.File]::WriteAllText($path, $html, $script:Utf8)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $results = @(Test-ReportIntegrity -Path $path)
        $watch.Stop()
        # Generous: each takes about a second on a desktop PC; before the fix they took from 20 seconds to many minutes.
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        $markup = @($results | Where-Object Check -eq 'Report markup')
        if ($Valid) { $markup | Should -BeNullOrEmpty }
        else {
            $markup.Count | Should -BeGreaterOrEqual 1
            $markup.Count | Should -BeLessOrEqual 26
        }
    }
}
