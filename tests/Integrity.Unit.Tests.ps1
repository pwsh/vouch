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

    function New-TestReport([string]$Folder, [switch]$SaveImages, [switch]$Linked, [switch]$Full, [string]$Classification = 'Confidential') {
        if ($Linked) { $SaveImages = [switch]$true }
        $name = 'report'
        $imagesDir = Join-Path $Folder "images\$name"
        [void](New-Item -ItemType Directory -Path $imagesDir -Force)
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
        $options = if ($Linked) { New-ReportOptions -EmbedImages $false -ImageFolder "images/$name" } else { $null }
        if ($Full) {
            # Everything 2.0 can add: logo, company, classification (print CSS), index, run details.
            $evil = 'x <img src=x> <!-- hi --> &period; &nbsp; style="x" url( '' > < & ü 日本'
            $options = New-ReportOptions -EmbedImages (-not $Linked) -ImageFolder $(if ($Linked) { "images/$name" } else { '' }) -Title "Q3 $evil" `
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
        @{ Case = 'a header that is not at the top'; Old = '</body>'; New = '<header class="company"></header></body>'; Pattern = 'header is not at its top|2 headers' }
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
        $missing = @($current | Where-Object { -not $known.Contains($_) })
        $missing | Should -BeNullOrEmpty -Because "the report CSS (Get-ReportCss) changed: add these SHA-256 values to Get-KnownReportCssHash and keep the old ones there, or older reports stop verifying: $($missing -join ', ')"
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