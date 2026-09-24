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

    function New-TestReport([string]$Folder, [switch]$SaveImages) {
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
            $captures.Add((New-CaptureRecord -Bytes $bytes -Url $metadata.PageUrl -SegmentIndex $segment -SegmentCount 2 `
                -FilePath $filePath -FileName $fileName -CapturedAt $script:CapturedAt))
        }
        $item = [pscustomobject]@{
            Index = 3; Name = 'Admin – users'; Url = 'https://app.example.com/admin'; FinalUrl = 'https://app.example.com/admin/users?page=1'
            Notes = ''; StepsText = ''; ScrollFullPage = $true; Status = 'OK'; HttpStatus = 200
            Details = [System.Collections.Generic.List[string]]::new(); StepLog = [System.Collections.Generic.List[object]]::new(); Captures = $captures
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
        [System.IO.File]::WriteAllText($path, (New-HtmlReport -Items @($item) -Run $run), [System.Text.UTF8Encoding]::new($false))
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
            'CapturedAtUtc', 'Segment', 'Computer', 'User', 'Screen')
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
}

Describe 'Get-ScreenCapture with metadata' -Tag 'Desktop' {
    It 'embeds the metadata in a real <Format> screen capture' -ForEach @(@{ Format = 'jpeg' }, @{ Format = 'png' }) {
        $bytes = Get-ScreenCapture -Format $Format -Quality 60 -Metadata (New-TestMetadata)
        (Get-ImageMetadata -Bytes $bytes).ItemName | Should -Be 'Admin – users'
    }
}
