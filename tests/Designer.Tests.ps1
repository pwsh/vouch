#Requires -Version 7
<#
    Tests for the Vouch Designer (designer\Designer.ps1 and the panel). The router and the
    security gate are called directly; one real listener runs in a child pwsh for the
    socket-level checks and for the panel, which is driven in a headless Edge (throwaway
    profile) over CDP. No window is ever shown: the server runs with -NoPanel and every
    file dialog is mocked.
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $script:DesignerPath = Join-Path -Path (Split-Path -Path $script:VouchPath -Parent) -ChildPath 'designer\Designer.ps1'
    . ([scriptblock]::Create((Get-VouchFunctionSource -Path $script:VouchPath, $script:DesignerPath)))
    $script:SamplePath = Join-Path -Path (Split-Path -Path $script:VouchPath -Parent) -ChildPath 'captures.sample.json'

    # A request body that counts what is read from it, or fails the test if read at all.
    if (-not ('VouchTest.CountingStream' -as [type])) {
        Add-Type -TypeDefinition @"
namespace VouchTest {
    public class CountingStream : System.IO.Stream {
        private readonly long length; private long position;
        public bool FailOnRead; public long BytesRead;
        public CountingStream(long length, bool failOnRead) { this.length = length; FailOnRead = failOnRead; }
        public override int Read(byte[] buffer, int offset, int count) {
            if (FailOnRead) throw new System.InvalidOperationException("The request body was read.");
            int n = (int)System.Math.Min(count, length - position);
            for (int i = 0; i < n; i++) buffer[offset + i] = (byte)'a';
            position += n; BytesRead += n; return n;
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return length; } }
        public override long Position { get { return position; } set { throw new System.NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long offset, System.IO.SeekOrigin origin) { throw new System.NotSupportedException(); }
        public override void SetLength(long value) { throw new System.NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new System.NotSupportedException(); }
    }
}
"@
    }

    # No test may open a real Windows dialog.
    Mock Show-DesignerFileDialog { throw 'A test reached a real file dialog; mock Show-DesignerFileDialog.' }

    function New-TestState {
        $state = New-DesignerState -ScriptPath $script:VouchPath -Port 50999 -Token 'test-token-0123456789' -Version '9.9.9'
        return $state
    }
    function ConvertFrom-TestBody([object]$Response) { return ([string]$Response.Body | ConvertFrom-Json -Depth 64) }
    function Invoke-TestRoute([string]$Method, [string]$Path, [System.Collections.IDictionary]$Body = @{}, [object]$State) {
        $response = Invoke-DesignerRequest -Method $Method -Path $Path -Body $Body -State $State
        $data = $null
        if ($response.Body -is [string] -and $response.Body) { $data = $response.Body | ConvertFrom-Json -Depth 64 }
        return [pscustomobject]@{ Status = $response.Status; Data = $data; Response = $response }
    }
    function Copy-Sample([string]$Name = 'sample.json') {
        $target = Join-Path -Path $TestDrive -ChildPath $Name
        Copy-Item -LiteralPath $script:SamplePath -Destination $target -Force
        return $target
    }
    function New-GoodHeaders([object]$State, [switch]$Post) {
        $headers = @{ Host = $State.HostHeader; 'X-Vouch-Token' = $State.Token }
        if ($Post) { $headers['Origin'] = $State.Origin; $headers['Content-Type'] = 'application/json' }
        return $headers
    }

    function Start-DesignerTestServer {
        <#
            A real Designer in a child pwsh: functions loaded the way the tests load them,
            -NoPanel (no window), and a ready file that gives the port and the token.
        #>
        param([string]$ConfigPath = '', [string]$Name = 'server')
        $folder = Join-Path -Path $TestDrive -ChildPath $Name
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $ready = Join-Path -Path $folder -ChildPath 'ready.json'
        $literal = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
        $hostScript = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $(& $literal (Join-Path $PSScriptRoot 'TestHelpers.ps1'))
. ([scriptblock]::Create((Get-VouchFunctionSource -Path $(& $literal $script:VouchPath), $(& $literal $script:DesignerPath))))
Start-VouchDesigner -ScriptPath $(& $literal $script:VouchPath) -ConfigPath $(& $literal $ConfigPath) -NoPanel -ReadyFile $(& $literal $ready) -Version 'test'
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($hostScript))
        $pwsh = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
            -RedirectStandardOutput (Join-Path $folder 'out.txt') -RedirectStandardError (Join-Path $folder 'err.txt')
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 150 }
        if (-not (Test-Path -LiteralPath $ready)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "The Designer test server did not start: $(Get-Content -Raw -LiteralPath (Join-Path $folder 'err.txt') -ErrorAction SilentlyContinue)"
        }
        $info = Get-Content -Raw -LiteralPath $ready | ConvertFrom-Json
        return [pscustomobject]@{ Process = $process; Port = [int]$info.port; Token = [string]$info.token; Url = [string]$info.url; Base = "http://localhost:$($info.port)" }
    }

    function Invoke-RawRequest {
        # HttpClient, so headers such as Host and Origin can be set exactly as a hostile page would.
        param(
            [string]$Method = 'GET', [Parameter(Mandatory)][string]$Url, [hashtable]$Headers = @{},
            [AllowNull()][string]$Body = $null, [string]$ContentType = '', [string]$HostHeader = '', [switch]$ExpectContinue
        )
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        try {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
            foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) }
            if ($HostHeader) { $request.Headers.Host = $HostHeader }
            if ($ExpectContinue) { $request.Headers.ExpectContinue = $true }
            if ($null -ne $Body) {
                $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8)
                $request.Content.Headers.ContentType = if ($ContentType) { [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType) } else { $null }
            }
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $headers = @{}
            foreach ($h in $response.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
            foreach ($h in $response.Content.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
            return [pscustomobject]@{ Status = [int]$response.StatusCode; Headers = $headers; Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        }
        finally { $client.Dispose() }
    }
}

Describe 'Designer request gate (Test-DesignerRequest)' {
    BeforeAll { $script:Gate = New-TestState; $script:Known = Add-DesignerKnownPath -State $script:Gate -Path (Join-Path $TestDrive 'known.json') -Kind config }

    It 'lets a request through: <Case>' -ForEach @(
        @{ Case = 'the page itself, without a token'; Method = 'GET'; Path = '/'; Headers = 'host' }
        @{ Case = 'the script, without a token'; Method = 'GET'; Path = '/app.js'; Headers = 'host' }
        @{ Case = 'GET /api/state with the token'; Method = 'GET'; Path = '/api/state'; Headers = 'get' }
        @{ Case = 'a JSON POST from the panel'; Method = 'POST'; Path = '/api/config/validate'; Headers = 'post'; Body = '{"config":{}}' }
        @{ Case = 'JSON with a charset'; Method = 'POST'; Path = '/api/config/new'; Headers = 'post'; Type = 'application/json; charset=utf-8'; Body = '{}' }
        @{ Case = 'a path the server handed out'; Method = 'POST'; Path = '/api/config/open'; Headers = 'post'; Body = 'KNOWN' }
    ) {
        $headers = switch ($Headers) { 'host' { @{ Host = $script:Gate.HostHeader } } 'get' { New-GoodHeaders $script:Gate } 'post' { New-GoodHeaders $script:Gate -Post } }
        if ($Type) { $headers['Content-Type'] = $Type }
        $text = if ($Body -eq 'KNOWN') { (@{ path = $script:Known } | ConvertTo-Json) } else { [string]$Body }
        $request = New-DesignerRequest -Method $Method -Path $Path -Headers $headers -BodyText $text
        Test-DesignerRequest -Request $request -State $script:Gate | Should -BeNullOrEmpty
    }

    It 'refuses <Case> with <Status> (<Code>)' -ForEach @(
        @{ Case = 'an API call without a token'; Status = 403; Code = 'token'; Change = { param($h) $h.Remove('X-Vouch-Token') } }
        @{ Case = 'a wrong token'; Status = 403; Code = 'token'; Change = { param($h) $h['X-Vouch-Token'] = 'test-token-0123456788' } }
        @{ Case = 'a token of another length'; Status = 403; Code = 'token'; Change = { param($h) $h['X-Vouch-Token'] = 'x' } }
        @{ Case = 'a preview without a token'; Status = 403; Code = 'token'; Path = '/preview/r/a.jpg'; Method = 'GET'; Change = { param($h) $h.Remove('X-Vouch-Token') } }
        @{ Case = 'a wrong Host'; Status = 400; Code = 'wrong-host'; Change = { param($h) $h['Host'] = 'evil.example:50999' } }
        @{ Case = 'Host 127.0.0.1'; Status = 400; Code = 'wrong-host'; Change = { param($h) $h['Host'] = '127.0.0.1:50999' } }
        @{ Case = 'a Host on another port'; Status = 400; Code = 'wrong-host'; Change = { param($h) $h['Host'] = 'localhost:50998' } }
        @{ Case = 'a missing Host'; Status = 400; Code = 'wrong-host'; Change = { param($h) $h.Remove('Host') } }
        @{ Case = 'a POST without Origin'; Status = 403; Code = 'no-origin'; Change = { param($h) $h.Remove('Origin') } }
        @{ Case = 'a POST from a foreign Origin'; Status = 403; Code = 'foreign-origin'; Change = { param($h) $h['Origin'] = 'http://localhost:9461' } }
        @{ Case = 'a GET from a foreign Origin'; Status = 403; Code = 'foreign-origin'; Method = 'GET'; Path = '/api/state'; Change = { param($h) $h['Origin'] = 'https://evil.example' } }
        @{ Case = 'a cross-site fetch'; Status = 403; Code = 'cross-site'; Change = { param($h) $h['Sec-Fetch-Site'] = 'cross-site' } }
        @{ Case = 'a same-site fetch from another port'; Status = 403; Code = 'cross-site'; Change = { param($h) $h['Sec-Fetch-Site'] = 'same-site' } }
        @{ Case = 'text/plain (a form or no-cors fetch)'; Status = 415; Code = 'content-type'; Change = { param($h) $h['Content-Type'] = 'text/plain' } }
        @{ Case = 'a form post'; Status = 415; Code = 'content-type'; Change = { param($h) $h['Content-Type'] = 'application/x-www-form-urlencoded' } }
        @{ Case = 'no content type'; Status = 415; Code = 'content-type'; Change = { param($h) $h.Remove('Content-Type') } }
        @{ Case = 'a CORS preflight'; Status = 403; Code = 'no-cors'; Method = 'OPTIONS'; Change = { param($h) } }
        @{ Case = 'PUT'; Status = 405; Code = 'method'; Method = 'PUT'; Change = { param($h) } }
        @{ Case = 'a POST to the page'; Status = 405; Code = 'method'; Path = '/'; Change = { param($h) } }
    ) {
        $headers = New-GoodHeaders $script:Gate -Post
        & $Change $headers
        $m = if ($Method) { $Method } else { 'POST' }
        $p = if ($Path) { $Path } else { '/api/config/validate' }
        $request = New-DesignerRequest -Method $m -Path $p -Headers $headers -BodyText '{"config":{}}'
        $refusal = Test-DesignerRequest -Request $request -State $script:Gate
        $refusal.Status | Should -Be $Status
        (ConvertFrom-TestBody $refusal).code | Should -Be $Code
        (ConvertFrom-TestBody $refusal).error | Should -Not -BeNullOrEmpty
    }

    It 'refuses an oversized body (413) and a body that is not JSON (400)' {
        $request = New-DesignerRequest -Method POST -Path '/api/config/validate' -Headers (New-GoodHeaders $script:Gate -Post) -BodyTooLarge
        (Test-DesignerRequest -Request $request -State $script:Gate).Status | Should -Be 413
        $request = New-DesignerRequest -Method POST -Path '/api/config/validate' -Headers (New-GoodHeaders $script:Gate -Post) -BodyText '{ not json'
        (Test-DesignerRequest -Request $request -State $script:Gate).Status | Should -Be 400
    }

    It 'refuses a file path the server did not hand out, on <_>' -ForEach @('/api/config/open', '/api/config/save', '/api/config/import-csv', '/api/command') {
        $body = @{ path = 'C:\Windows\win.ini'; config = @{} } | ConvertTo-Json
        $request = New-DesignerRequest -Method POST -Path $_ -Headers (New-GoodHeaders $script:Gate -Post) -BodyText $body
        $refusal = Test-DesignerRequest -Request $request -State $script:Gate
        $refusal.Status | Should -Be 403
        (ConvertFrom-TestBody $refusal).code | Should -Be 'unknown-path'
        # The router refuses it as well (defence in depth), without opening anything.
        (Invoke-TestRoute POST $_ ([ordered]@{ path = 'C:\Windows\win.ini'; config = [ordered]@{} }) -State $script:Gate).Status | Should -Be 403
    }

    It 'refuses <Case> before reading a byte of the body' -ForEach @(
        @{ Case = 'a 4 MB POST without a token'; Status = 403; Change = { param($h) $h.Remove('X-Vouch-Token') }; Length = 4MB }
        @{ Case = 'a 4 MB POST from another origin'; Status = 403; Change = { param($h) $h['Origin'] = 'https://evil.example' }; Length = 4MB }
        @{ Case = 'a no-cors text/plain POST'; Status = 415; Change = { param($h) $h['Content-Type'] = 'text/plain' }; Length = 4MB }
        @{ Case = 'a declared 5 MB body from the panel'; Status = 413; Change = { param($h) }; Length = 5MB }
    ) {
        $headers = New-GoodHeaders $script:Gate -Post
        & $Change $headers
        $stream = [VouchTest.CountingStream]::new($Length, $true)
        $response = Invoke-DesignerExchange -Method POST -Path '/api/config/validate' -Headers $headers -ContentLength $Length -BodyStream $stream -State $script:Gate
        $response.Status | Should -Be $Status
        $stream.BytesRead | Should -Be 0
    }

    It 'stops reading a body of unknown length one block past the limit (413)' {
        $stream = [VouchTest.CountingStream]::new(20MB, $false)
        $response = Invoke-DesignerExchange -Method POST -Path '/api/config/validate' -Headers (New-GoodHeaders $script:Gate -Post) -ContentLength -1 -BodyStream $stream -State $script:Gate
        $response.Status | Should -Be 413
        $stream.BytesRead | Should -BeLessOrEqual ($script:Gate.MaxBodyBytes + 65536)
    }

    It 'reads, checks and routes an ordinary request from the panel' {
        $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes('{}'))
        $response = Invoke-DesignerExchange -Method POST -Path '/api/config/new' -Headers (New-GoodHeaders $script:Gate -Post) -ContentLength 2 -BodyStream $stream -State $script:Gate
        $response.Status | Should -Be 200
        (Invoke-DesignerExchange -Method GET -Path '/app.css' -Headers @{ Host = $script:Gate.HostHeader } -State $script:Gate).Status | Should -Be 200
    }

    It 'compares tokens in constant time and makes long random tokens' {
        Test-DesignerTokenMatch -Given 'abc' -Expected 'abc' | Should -BeTrue
        Test-DesignerTokenMatch -Given 'abd' -Expected 'abc' | Should -BeFalse
        Test-DesignerTokenMatch -Given '' -Expected 'abc' | Should -BeFalse
        Test-DesignerTokenMatch -Given $null -Expected 'abc' | Should -BeFalse
        $a = New-DesignerToken; $b = New-DesignerToken
        $a | Should -Not -Be $b
        $a.Length | Should -BeGreaterOrEqual 43   # 256 bits in base64url
        $a | Should -Match '^[A-Za-z0-9_-]+$'
    }
}

Describe 'Designer router (Invoke-DesignerRequest, no socket)' {
    BeforeEach { $script:State = New-TestState }

    It 'serves the four panel addresses with their content types, and nothing else' {
        foreach ($case in @(@('/', 'text/html'), @('/index.html', 'text/html'), @('/app.js', 'text/javascript'), @('/app.css', 'text/css'))) {
            $response = Invoke-DesignerRequest -Method GET -Path $case[0] -State $script:State
            $response.Status | Should -Be 200
            $response.ContentType | Should -BeLike "$($case[1]); charset=utf-8"
            ($response.Body -is [byte[]]) | Should -BeTrue
        }
        (Invoke-DesignerRequest -Method GET -Path '/Designer.ps1' -State $script:State).Status | Should -Be 404
        (Invoke-DesignerRequest -Method GET -Path '/../vouch.ps1' -State $script:State).Status | Should -Be 404
        (Invoke-DesignerRequest -Method GET -Path '/APP.JS' -State $script:State).Status | Should -Be 404
        (Invoke-DesignerRequest -Method GET -Path '/favicon.ico' -State $script:State).Status | Should -Be 204
    }

    It 'never writes inline script or style into the page' {
        $html = [System.IO.File]::ReadAllText((Join-Path (Split-Path $script:DesignerPath) 'index.html'))
        $html | Should -Not -Match '(?i)\sstyle\s*='
        $html | Should -Not -Match '(?i)<style'
        $html | Should -Not -Match '(?i)<script(?![^>]*\bsrc=)'
        $html | Should -Not -Match '(?i)\son[a-z]+\s*='
        $js = [System.IO.File]::ReadAllText((Join-Path (Split-Path $script:DesignerPath) 'app.js'))
        $js | Should -Not -Match '\.innerHTML|outerHTML|insertAdjacentHTML|document\.write|\.style\.|eval\(|new Function'
        $js | Should -Not -Match "setAttribute\(\s*'style'"
    }

    It 'GET /api/state gives the server facts, the schema and the later-step placeholders' {
        $r = Invoke-TestRoute GET '/api/state' -State $script:State
        $r.Status | Should -Be 200
        $r.Data.version | Should -Be '9.9.9'
        $r.Data.browser.connected | Should -BeFalse
        $r.Data.run.state | Should -Be 'idle'
        $r.Data.capabilities.pick | Should -BeFalse
        $r.Data.capabilities.run | Should -BeFalse
        $r.Data.schema.settings.'output.jpegQuality'.min | Should -Be 1
        $r.Data.schema.settings.'output.jpegQuality'.max | Should -Be 100
        $r.Data.schema.settings.'defaults.captureArea'.allowed | Should -Be @('screen', 'window', 'page')
        $r.Data.schema.settings.'output.captureLog'.default | Should -BeTrue
        $r.Data.schema.actions.capture.scroll.fields.mode.allowed | Should -Be @('none', 'auto', 'page', 'area')
        $r.Data.defaults.output.dir | Should -Be 'reports'
    }

    It 'POST /api/config/new gives every default and no pages' {
        $r = Invoke-TestRoute POST '/api/config/new' -State $script:State
        $r.Status | Should -Be 200
        $r.Data.config.schemaVersion | Should -Be 1
        @($r.Data.config.pages).Count | Should -Be 0
        $r.Data.config.report.title | Should -Be 'Audit Evidence Report'
    }

    It 'answers 501 with a plain message for <_>' -ForEach @(
        'POST /api/browser/navigate', 'GET /api/browser/current', 'POST /api/pick/start', 'GET /api/pick', 'POST /api/pick/cancel',
        'POST /api/action/test', 'POST /api/run', 'GET /api/run', 'POST /api/run/stop', 'GET /preview/run1/001.jpg') {
        $method, $path = $_ -split ' ', 2
        $r = Invoke-TestRoute $method $path -State $script:State
        $r.Status | Should -Be 501
        $r.Data.code | Should -Be 'later'
        $r.Data.detail | Should -Match 'later step'
    }

    It 'answers 405 for a known address with the wrong method, and 404 for an unknown one' {
        (Invoke-TestRoute GET '/api/config/save' -State $script:State).Status | Should -Be 405
        (Invoke-TestRoute POST '/api/state' -State $script:State).Status | Should -Be 405
        (Invoke-TestRoute GET '/api/nothing' -State $script:State).Status | Should -Be 404
    }

    It 'turns an unexpected failure into a 500 with a plain message and no stack trace' {
        Mock Get-DesignerStateData { throw 'boom in the handler' }
        $r = Invoke-TestRoute GET '/api/state' -State $script:State
        $r.Status | Should -Be 500
        $r.Data.error | Should -Be 'Something went wrong in the Designer.'
        $r.Data.detail | Should -Be 'boom in the handler'
        $r.Response.Body | Should -Not -Match 'at Get-|\.ps1:|line \d+|ScriptStackTrace'
    }

    Context 'open' {
        It 'opens a file the server knows as written, with no defaults filled in' {
            $path = Join-Path $TestDrive 'partial.json'
            Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "Output": { "Dir": "out" }, "pages": [ { "Name": "A", "url": "https://a.example/", "future": { "x": 1 } } ], "extra": true }' -Encoding utf8NoBOM
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $r = Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $path }) -State $script:State
            $r.Status | Should -Be 200
            $r.Data.path | Should -Be $path
            $r.Data.name | Should -Be 'partial.json'
            @($r.Data.config.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'output', 'pages', 'extra')
            @($r.Data.config.output.PSObject.Properties.Name) | Should -Be @('dir')
            $r.Data.config.output.dir | Should -Be 'out'
            @($r.Data.config.pages[0].PSObject.Properties.Name) | Should -Be @('name', 'url', 'future')
            $r.Data.config.pages[0].future.x | Should -Be 1
            @($r.Data.warnings.path) | Should -Contain 'extra'
            @($r.Data.warnings.path) | Should -Contain 'pages[0].future'
            $r.Data.hasComments | Should -BeFalse
            $script:State.ConfigPath | Should -Be $path
        }

        It 'still opens a file with problems, and lists them in plain words' {
            $path = Join-Path $TestDrive 'bad.json'
            Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "output": { "jpegQuality": 0 }, "pages": [ { "name": "A", "url": "ftp://x" } ] }' -Encoding utf8NoBOM
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $r = Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $path }) -State $script:State
            $r.Status | Should -Be 200
            @($r.Data.errors.path) | Should -Be @('output.jpegQuality', 'pages[0].url')
            ($r.Data.errors | Where-Object path -eq 'output.jpegQuality').text | Should -Be 'must be a whole number from 1 to 100 (found 0).'
        }

        It 'refuses a file that is not JSON with 422 and the line of the mistake' {
            $path = Join-Path $TestDrive 'broken.json'
            Set-Content -LiteralPath $path -Value "{`n  `"name`": `"x`"`n  `"pages`": []`n}" -Encoding utf8NoBOM
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $r = Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $path }) -State $script:State
            $r.Status | Should -Be 422
            $r.Data.detail | Should -Match 'line 3'
        }

        It 'asks with the Open dialog when no path is given, and remembers the answer' {
            $path = Copy-Sample
            $global:VouchDialogAnswer = $path
            Mock Show-DesignerFileDialog { $global:VouchDialogAnswer } -ParameterFilter { $Kind -eq 'open' }
            $r = Invoke-TestRoute POST '/api/config/open' -State $script:State
            $r.Status | Should -Be 200
            @($r.Data.config.pages).Count | Should -Be 4
            Test-DesignerKnownPath -State $script:State -Path $path -Kind config | Should -BeTrue
            $global:VouchDialogAnswer = ''
            (Invoke-TestRoute POST '/api/config/open' -State $script:State).Data.cancelled | Should -BeTrue
        }

        It 'says when a file has comments, and the first save says they were not kept (once)' {
            $path = Join-Path $TestDrive 'commented.json'
            Set-Content -LiteralPath $path -Value "{`n  // my note`n  `"schemaVersion`": 1, `"pages`": [],`n}" -Encoding utf8NoBOM
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $opened = Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $path }) -State $script:State
            $opened.Data.hasComments | Should -BeTrue
            $config = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($path))
            $first = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ path = $path; config = $config }) -State $script:State
            $first.Status | Should -Be 200
            @($first.Data.notices).Count | Should -Be 1
            $first.Data.notices[0] | Should -Match 'comments'
            [System.IO.File]::ReadAllText($path) | Should -Not -Match '//'
            $second = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ path = $path; config = $config }) -State $script:State
            @($second.Data.notices).Count | Should -Be 0
        }

        It 'never reads a logo path named inside an opened file (<Case>)' -ForEach @(
            @{ Case = 'a relative file'; Logo = 'logo.png' }
            @{ Case = 'a UNC path'; Logo = '\\\\attacker.example\\share\\logo.png' }
            @{ Case = 'a device path'; Logo = '\\\\.\\COM1' }
            @{ Case = 'a long-path device form'; Logo = '\\\\?\\UNC\\attacker.example\\share\\x.png' }
        ) {
            Mock Get-LogoDataUri { throw 'opening a file must not read its logo' }
            Mock Test-Path { throw 'opening a file must not probe its logo' } -ParameterFilter { "$LiteralPath$Path" -match 'attacker|COM1|logo\.png' }
            $path = Join-Path $TestDrive 'logo-open.json'
            Set-Content -LiteralPath $path -Value ('{ "schemaVersion": 1, "report": { "logoPath": "' + $Logo + '" }, "pages": [] }') -Encoding utf8NoBOM
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $r = Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $path }) -State $script:State
            $r.Status | Should -Be 200
            $r.Data.logo | Should -BeNullOrEmpty
            Should -Invoke Get-LogoDataUri -Exactly 0
        }
    }

    Context 'save' {
        It 'writes the sample back byte for byte after opening it unchanged' {
            $path = Copy-Sample 'roundtrip.json'
            $before = [System.IO.File]::ReadAllBytes($path)
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $opened = Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $path }) -State $script:State
            $config = (ConvertFrom-VouchJson -Text $opened.Response.Body)['config']
            $saved = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ path = $path; config = $config }) -State $script:State
            $saved.Status | Should -Be 200
            [System.IO.File]::ReadAllBytes($path) | Should -Be $before
            "$path.bak" | Should -Exist
            [System.IO.File]::ReadAllBytes("$path.bak") | Should -Be $before
        }

        It 'refuses a configuration with errors (422) and writes nothing' {
            $path = Copy-Sample 'refused.json'
            $before = [System.IO.File]::ReadAllText($path)
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $config = ConvertFrom-VouchJson -Text $before
            $config['pages'][1]['url'] = 'not a url'
            $config['pages'][1]['id'] = 'P001'
            $r = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ path = $path; config = $config }) -State $script:State
            $r.Status | Should -Be 422
            @($r.Data.errors.path) | Should -Contain 'pages[1].url'
            @($r.Data.errors.path) | Should -Contain 'pages[1].id'
            [System.IO.File]::ReadAllText($path) | Should -Be $before
            "$path.bak" | Should -Not -Exist
        }

        It 'writes atomically: stable key order, unknown keys kept, UTF-8 without BOM, a final line break, one .bak' {
            $path = Join-Path $TestDrive 'order.json'
            Set-Content -LiteralPath $path -Value '{ "old": 1 }' -Encoding utf8NoBOM -NoNewline
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $config = [ordered]@{
                pages = [System.Collections.Generic.List[object]]@([ordered]@{
                        actions = [System.Collections.Generic.List[object]]@([ordered]@{ scroll = [ordered]@{ as = 'single'; mode = 'page' }; label = 'L'; type = 'capture'; later = 'kept' })
                        url = 'https://a.example/'; zzz = 'unknown'; name = 'Ü “quoted” \ page'; id = 'p1'
                    })
                report = [ordered]@{ title = 'T'; company = [ordered]@{ details = "two`nlines"; name = 'C' } }
                future = [ordered]@{ a = 1 }
                schemaVersion = 1
                output = [ordered]@{ zip = [ordered]@{ name = 'z'; enabled = $true }; dir = 'out' }
            }
            $r = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ path = $path; config = $config }) -State $script:State
            $r.Status | Should -Be 200
            $r.Data.backup | Should -Be "$path.bak"
            [System.IO.File]::ReadAllText("$path.bak") | Should -Be '{ "old": 1 }'
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Be ([byte][char]'{')
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $text | Should -Match "}\r\n$"
            $expected = @(
                '{'
                '  "schemaVersion": 1,'
                '  "output": {'
                '    "dir": "out",'
                '    "zip": { "enabled": true, "name": "z" }'
                '  },'
                '  "report": {'
                '    "title": "T",'
                '    "company": { "name": "C", "details": "two\nlines" }'
                '  },'
                '  "pages": ['
                '    {'
                '      "id": "p1",'
                '      "name": "Ü “quoted” \\ page",'
                '      "url": "https://a.example/",'
                '      "actions": ['
                '        { "type": "capture", "label": "L", "scroll": { "mode": "page", "as": "single" }, "later": "kept" }'
                '      ],'
                '      "zzz": "unknown"'
                '    }'
                '  ],'
                '  "future": { "a": 1 }'
                '}') -join "`r`n"
            $text | Should -Be ($expected + "`r`n")
            @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp' -Force).Count | Should -Be 0
            (Test-VouchConfig -Config (ConvertFrom-VouchJson -Text $text)).Errors.Count | Should -Be 0
        }

        It 'keeps the line ends of an existing LF file' {
            $path = Join-Path $TestDrive 'lf.json'
            [System.IO.File]::WriteAllText($path, "{`n  `"schemaVersion`": 1`n}`n")
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            [void](Invoke-TestRoute POST '/api/config/save' ([ordered]@{ path = $path; config = [ordered]@{ schemaVersion = 1; name = 'x' } }) -State $script:State)
            [System.IO.File]::ReadAllText($path) | Should -Be "{`n  `"schemaVersion`": 1,`n  `"name`": `"x`"`n}`n"
        }

        It 'asks for a name with Save As, suggests one from the configuration name, and answers what was written' {
            $target = Join-Path $TestDrive 'new folder\saved as.json'
            [void](New-Item -ItemType Directory -Path (Split-Path $target) -Force)
            $global:VouchDialogAnswer = $target
            Mock Show-DesignerFileDialog { $global:VouchDialogAnswer } -ParameterFilter { $Kind -eq 'save' -and $FileName -eq 'Q3 ITGC.json' }
            $config = Get-DefaultVouchConfig
            $config['name'] = 'Q3 ITGC'
            $r = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ config = $config; saveAs = $true }) -State $script:State
            $r.Status | Should -Be 200
            $r.Data.path | Should -Be $target
            $r.Data.backup | Should -Be ''
            $r.Data.config.name | Should -Be 'Q3 ITGC'
            $script:State.ConfigPath | Should -Be $target
            Test-DesignerKnownPath -State $script:State -Path $target -Kind config | Should -BeTrue
            $global:VouchDialogAnswer = ''
            (Invoke-TestRoute POST '/api/config/save' ([ordered]@{ config = $config; saveAs = $true }) -State $script:State).Data.cancelled | Should -BeTrue
        }

        It 'saves a file it opened without changes as the same configuration (no semantic difference)' {
            $path = Copy-Sample 'semantic.json'
            $original = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($path))
            [void](Save-VouchConfig -Config $original -Path $path)
            $again = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($path))
            ($again | ConvertTo-Json -Depth 64) | Should -Be ($original | ConvertTo-Json -Depth 64)
        }
    }

    Context 'import, validate, dialogs, command, open, shutdown' {
        It 'imports a CSV exactly as ConvertTo-VouchConfig reads it' {
            $csv = Join-Path (Split-Path $script:VouchPath) 'captures.template.csv'
            $global:VouchDialogAnswer = $csv
            Mock Show-DesignerFileDialog { $global:VouchDialogAnswer } -ParameterFilter { $Kind -eq 'open' }
            $r = Invoke-TestRoute POST '/api/config/import-csv' -State $script:State
            $r.Status | Should -Be 200
            $expected = ConvertTo-VouchConfig -Path $csv
            ($r.Data.pages | ConvertTo-Json -Depth 64 -Compress) | Should -Be ($expected['pages'] | ConvertTo-Json -Depth 64 -Compress)
            $r.Data.title | Should -Be 'captures.template'
            # The same path may now be named again without a dialog.
            (Invoke-TestRoute POST '/api/config/import-csv' ([ordered]@{ path = $csv }) -State $script:State).Status | Should -Be 200
        }

        It 'lists the problems of a CSV that cannot be imported' {
            $csv = Join-Path $TestDrive 'bad.csv'
            Set-Content -LiteralPath $csv -Value "Name,Url,Steps,ScrollFullPage,Notes`nA,ftp://x,,N,`n,https://ok.example/,,Q," -Encoding utf8NoBOM
            [void](Add-DesignerKnownPath -State $script:State -Path $csv -Kind csv)
            $r = Invoke-TestRoute POST '/api/config/import-csv' ([ordered]@{ path = $csv }) -State $script:State
            $r.Status | Should -Be 422
            @($r.Data.problems).Count | Should -Be 3
            $r.Data.problems[0] | Should -Match "Line 2: 'Url' must start with http"
        }

        It 'validates and previews the report and zip names with the engine''s naming rules' {
            $config = Get-DefaultVouchConfig
            $config['output']['reportName'] = 'Evidence {period} {nope}'
            $config['output']['zip']['name'] = '{report} {classification}.zip'
            $config['report']['period']['label'] = 'Q3: 2026'
            $config['report']['classification'] = 'internal'
            $config['pages'].Add([ordered]@{ name = 'A'; url = 'x' })
            $r = Invoke-TestRoute POST '/api/config/validate' ([ordered]@{ config = $config }) -State $script:State
            @($r.Data.errors.path) | Should -Be @('pages[0].url')
            $r.Data.preview | Should -BeNullOrEmpty
            $config['pages'][0]['url'] = 'https://a.example/'
            $config['extra'] = 1
            $r = Invoke-TestRoute POST '/api/config/validate' ([ordered]@{ config = $config }) -State $script:State
            @($r.Data.errors).Count | Should -Be 0
            @($r.Data.warnings.path) | Should -Be @('extra')
            $r.Data.preview.reportFile | Should -Be 'Evidence Q3_ 2026 {nope}.html'
            $r.Data.preview.reportUnknown | Should -Be @('{nope}')
            $r.Data.preview.zipFile | Should -Be 'Evidence Q3_ 2026 {nope} Internal.zip'
        }

        It 'shows dialogs of each kind and hands out the chosen path; a picked path inside the configuration folder is written relative' {
            $configPath = Copy-Sample 'dialogs.json'
            $script:State.ConfigPath = $configPath
            $inside = Join-Path $TestDrive 'out\evidence'
            $global:VouchDialogAnswer = $inside
            Mock Show-DesignerFileDialog { $global:VouchDialogAnswer } -ParameterFilter { $Kind -eq 'folder' }
            $r = Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = 'folder'; title = 'Choose the output folder' }) -State $script:State
            $r.Data.path | Should -Be $inside
            $r.Data.value | Should -Be 'out\evidence'
            Test-DesignerKnownPath -State $script:State -Path $inside -Kind folder | Should -BeTrue
            Test-DesignerKnownPath -State $script:State -Path $inside -Kind config | Should -BeFalse
            Should -Invoke Show-DesignerFileDialog -ParameterFilter { $Title -eq 'Choose the output folder' } -Exactly 1
            Mock Show-DesignerFileDialog { 'D:\elsewhere\logo.png' } -ParameterFilter { $Kind -eq 'open' }
            $r = Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = 'image' }) -State $script:State
            $r.Data.value | Should -Be 'D:\elsewhere\logo.png'
            $r.Data.logo.warning | Should -Not -BeNullOrEmpty
            foreach ($kind in 'csv', 'config-open') { (Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = $kind }) -State $script:State).Status | Should -Be 200 }
            Mock Show-DesignerFileDialog { '' }
            (Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = 'config-save' }) -State $script:State).Data.cancelled | Should -BeTrue
            (Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = 'anything' }) -State $script:State).Status | Should -Be 400
        }

        It 'gives commands only for a saved file, and says when the file differs from what is shown' {
            $config = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($script:SamplePath))
            $none = Invoke-TestRoute POST '/api/command' ([ordered]@{ config = $config; path = '' }) -State $script:State
            $none.Data.unsaved | Should -BeTrue
            $none.Data.saved | Should -BeFalse
            $none.Data.run | Should -Be ''
            $path = Copy-Sample 'command.json'
            [void](Add-DesignerKnownPath -State $script:State -Path $path -Kind config)
            $same = Invoke-TestRoute POST '/api/command' ([ordered]@{ config = $config; path = $path }) -State $script:State
            $same.Data.unsaved | Should -BeFalse
            $same.Data.run | Should -BeLike "pwsh -NoProfile -ExecutionPolicy Bypass -File ""*vouch.ps1"" -ConfigPath ""$path"""
            $same.Data.schedule | Should -BeLike '*Install-VouchSchedule.ps1" -ConfigPath *'
            $config['pages'][0]['name'] = 'Changed'
            $changed = Invoke-TestRoute POST '/api/command' ([ordered]@{ config = $config; path = $path }) -State $script:State
            $changed.Data.unsaved | Should -BeTrue
            $changed.Data.notes[0] | Should -Match 'not saved'
        }

        It 'opens only what the server knows' {
            Mock Open-ReportFile { }
            (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'report' }) -State $script:State).Status | Should -Be 409
            (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'C:\Windows' }) -State $script:State).Status | Should -Be 400
            $script:State.ConfigPath = Copy-Sample 'open.json'
            $r = Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'config-folder' }) -State $script:State
            $r.Status | Should -Be 200
            Should -Invoke Open-ReportFile -Exactly 1 -ParameterFilter { $Path -eq $TestDrive }
            $script:State.OpenTargets['report'] = $script:State.ConfigPath
            (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'report' }) -State $script:State).Status | Should -Be 200
        }

        It 'accepts a handed-out path only for its own kind of file' {
            $config = Join-Path $TestDrive 'kind.json'; Copy-Item -LiteralPath $script:SamplePath -Destination $config
            $logo = Join-Path $TestDrive 'kind-logo.png'; [System.IO.File]::WriteAllBytes($logo, [byte[]](1, 2, 3))
            $csv = Join-Path (Split-Path $script:VouchPath) 'captures.template.csv'
            $global:VouchDialogAnswer = $logo
            Mock Show-DesignerFileDialog { $global:VouchDialogAnswer }
            [void](Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = 'image' }) -State $script:State)
            $global:VouchDialogAnswer = $csv
            [void](Invoke-TestRoute POST '/api/dialog' ([ordered]@{ kind = 'csv' }) -State $script:State)
            [void](Add-DesignerKnownPath -State $script:State -Path $config -Kind config)
            $minimal = [ordered]@{ schemaVersion = 1 }
            foreach ($case in @(
                    @('/api/config/save', $logo), @('/api/config/save', $csv), @('/api/config/save', "$config.bak"),
                    @('/api/config/open', $logo), @('/api/config/open', $csv), @('/api/command', $logo), @('/api/config/import-csv', $config))) {
                $r = Invoke-TestRoute POST $case[0] ([ordered]@{ path = $case[1]; config = $minimal }) -State $script:State
                $r.Status | Should -Be 403 -Because "$($case[0]) must refuse $($case[1])"
                $request = New-DesignerRequest -Method POST -Path $case[0] -Headers (New-GoodHeaders $script:State -Post) -BodyText (@{ path = $case[1]; config = @{} } | ConvertTo-Json)
                (Test-DesignerRequest -Request $request -State $script:State).Status | Should -Be 403
            }
            [System.IO.File]::ReadAllBytes($logo) | Should -Be ([byte[]](1, 2, 3))
            (Invoke-TestRoute POST '/api/config/import-csv' ([ordered]@{ path = $csv }) -State $script:State).Status | Should -Be 200
            (Invoke-TestRoute POST '/api/config/open' ([ordered]@{ path = $config }) -State $script:State).Status | Should -Be 200
        }

        It 'stops the loop on POST /api/shutdown' {
            $r = Invoke-TestRoute POST '/api/shutdown' -State $script:State
            $r.Status | Should -Be 200
            $script:State.Running | Should -BeFalse
        }
    }
}

Describe 'Command lines (Get-VouchCommandLine)' {
    It 'quotes <Case> so PowerShell reads it back exactly' -ForEach @(
        @{ Case = 'spaces'; Value = 'C:\Audit files\Q3 evidence.json'; Form = 'double' }
        @{ Case = 'an apostrophe'; Value = "C:\Eric's files\a.json"; Form = 'single' }
        @{ Case = 'a dollar sign'; Value = 'C:\x\$env:TEMP\a.json'; Form = 'single' }
        @{ Case = 'a backtick'; Value = 'C:\x\a`nb.json'; Form = 'single' }
        @{ Case = 'an ampersand and brackets'; Value = 'C:\R&D (2026)\a.json'; Form = 'double' }
        @{ Case = 'non-ASCII letters'; Value = 'C:\Prüfung\日本\é.json'; Form = 'double' }
        @{ Case = 'typographic quotes'; Value = "C:\x\it$([char]0x2019)s $([char]0x201C)quoted$([char]0x201D).json"; Form = 'single' }
        @{ Case = 'a double quote'; Value = 'Title "Q3"'; Form = 'single' }
        @{ Case = 'a trailing backslash'; Value = 'C:\out\'; Form = 'double' }
    ) {
        $quoted = ConvertTo-DesignerPowerShellArgument -Value $Value
        $errors = $null
        $quoted.Substring(0, 1) | Should -Be $(if ($Form -eq 'single') { "'" } else { '"' })
        $ast = [System.Management.Automation.Language.Parser]::ParseInput("x $quoted", [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        $argument = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements[1]
        $argument.Value | Should -BeExactly $Value
        $argument | Should -Not -BeOfType [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }

    It 'quotes for cmd.exe, doubling backslashes before the closing quote, and gives up on what cmd.exe would change' {
        ConvertTo-DesignerCmdArgument -Value 'C:\R&D (x)\a b.json' | Should -Be '"C:\R&D (x)\a b.json"'
        ConvertTo-DesignerCmdArgument -Value 'C:\out\' | Should -Be '"C:\out\\"'
        ConvertTo-DesignerCmdArgument -Value 'up ^ caret | pipe <x>' | Should -Be '"up ^ caret | pipe <x>"'
        foreach ($bad in 'say "hi"', '100% done', '%USERNAME%', 'hello!', "two`nlines", "cr`rhere") {
            ConvertTo-DesignerCmdArgument -Value $bad | Should -BeNullOrEmpty -Because $bad
        }
    }

    It 'leaves values cmd.exe would change out of the cmd.exe line, and gives no cmd.exe line for such a path' {
        $config = Get-DefaultVouchConfig
        $config['report']['company']['name'] = '100% %USERNAME% Ltd'
        $config['report']['origin'] = 'Hello!'
        $line = Get-VouchCommandLine -Config $config -ConfigPath (Join-Path $TestDrive 'plain\c.json') -ScriptPath $script:VouchPath
        $line.RunExpanded | Should -Match '-CompanyName "100% %USERNAME% Ltd"'
        $line.RunExpanded | Should -Match '-Origin "Hello!"'
        $line.RunExpandedCmd | Should -Not -Match 'CompanyName|Origin'
        ($line.Notes -join ' ') | Should -Match '-CompanyName is left out of the cmd.exe line'
        $odd = Get-VouchCommandLine -Config $config -ConfigPath (Join-Path $TestDrive '100% sure\c.json') -ScriptPath $script:VouchPath
        $odd.Run | Should -Not -BeNullOrEmpty
        $odd.RunCmd | Should -Be ''
        $odd.RunExpandedCmd | Should -Be ''
        $odd.ScheduleCmd | Should -Be ''
        ($odd.Notes -join ' ') | Should -Match 'no cmd.exe version'
    }

    It 'reads the parameter defaults from vouch.ps1 itself' {
        $info = Get-VouchParameterInfo -ScriptPath $script:VouchPath
        $info['DebugPort'].Default | Should -Be 9222
        $info['DebugPort'].Type | Should -Be 'int'
        $info['SaveImages'].Type | Should -Be 'switch'
        $info['OutputDir'].Default | Should -Be (Join-Path (Split-Path $script:VouchPath) 'reports')
        $info['EdgeProfileDir'].Default | Should -Be (Join-Path $env:LOCALAPPDATA 'Vouch\EdgeProfile')
        foreach ($definition in Get-RunSettingDefinition) { $info.Contains($definition.Name) | Should -BeTrue }
    }

    Context 'the expanded form' {
        BeforeAll {
            $script:CmdFolder = Join-Path $TestDrive 'Q3 $x & ''y'''
            [void](New-Item -ItemType Directory -Path $script:CmdFolder -Force)
            $script:CmdConfigPath = Join-Path $script:CmdFolder 'c.json'
            $config = Get-DefaultVouchConfig
            $config['output']['jpegQuality'] = 70
            $config['output']['saveImages'] = $true
            $config['output']['captureLog'] = $false
            $config['output']['embedImages'] = $false
            $config['output']['dir'] = 'out'
            $config['report']['title'] = 'Audit Evidence Report'     # the default: not written
            $config['report']['classification'] = 'Internal'
            $config['report']['company']['details'] = "two`nlines"     # cannot go on a command line
            $config['report']['description'] = 'He said "yes" & left'
            $config['report']['origin'] = '-starts with a dash'
            $config['report']['logoPath'] = 'logo.png'
            $config['defaults']['settleSeconds'] = 0.5
            $config['defaults']['captureArea'] = 'page'
            $config['pages'].Add([ordered]@{ id = 'p7'; name = 'A'; url = 'https://a.example/'; overrides = [ordered]@{ captureArea = 'window' } })
            $script:Cmd = Get-VouchCommandLine -Config $config -ConfigPath $script:CmdConfigPath -ScriptPath $script:VouchPath
        }

        It 'writes each setting that differs from the default as its switch, and leaves out what it must' {
            $names = @($script:Cmd.Switches | ForEach-Object { $_.name })
            $names | Should -Be @('OutputDir', 'SettleSeconds', 'JpegQuality', 'SaveImages', 'Classification', 'LogoPath', 'Description', 'LinkImages', 'NoCaptureLog')
            $script:Cmd.RunExpanded | Should -Match ' -JpegQuality 70 '
            $script:Cmd.RunExpanded | Should -Match ' -SettleSeconds 0\.5 '
            $script:Cmd.RunExpanded | Should -Match ' -SaveImages '
            $script:Cmd.RunExpanded | Should -Match ' -NoCaptureLog$'
            $script:Cmd.RunExpanded | Should -Not -Match 'ReportTitle|CompanyDetails|Origin|CaptureArea'
            ($script:Cmd.Notes -join ' ') | Should -Match '-CaptureArea is left out: page p7'
            ($script:Cmd.Notes -join ' ') | Should -Match '-CompanyDetails is left out because its value has several lines'
            ($script:Cmd.Notes -join ' ') | Should -Match '-Origin is left out because its value starts with a dash'
            ($script:Cmd.Notes -join ' ') | Should -Match '-Description is left out of the cmd.exe line'
            $script:Cmd.RunExpandedCmd | Should -Not -Match 'Description'
            ($script:Cmd.Switches | Where-Object name -eq 'LogoPath').value | Should -Be (Join-Path $script:CmdFolder 'logo.png')
        }

        It 'parses as PowerShell and binds to the real param block of vouch.ps1' {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:Cmd.RunExpanded, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0
            $elements = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements
            $elements[0].Value | Should -Be 'pwsh'
            $fileIndex = @($elements | ForEach-Object { $_.Extent.Text }).IndexOf('-File')
            $elements[$fileIndex + 1].Value | Should -Be $script:VouchPath
            $rest = @($elements | Select-Object -Skip ($fileIndex + 2) | ForEach-Object { $_.Extent.Text }) -join ' '
            $call = [System.Management.Automation.Language.Parser]::ParseInput("& '$($script:VouchPath.Replace("'", "''"))' $rest", [ref]$null, [ref]$null)
            $command = $call.Find({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
            $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($command, $true)
            $binding.BindingExceptions.Count | Should -Be 0
            @($binding.BoundParameters.Keys) | Should -Contain 'ConfigPath'
            $binding.BoundParameters['ConfigPath'].ConstantValue | Should -Be $script:CmdConfigPath
            $binding.BoundParameters['Description'].ConstantValue | Should -Be 'He said "yes" & left'
            $binding.BoundParameters['OutputDir'].ConstantValue | Should -Be (Join-Path $script:CmdFolder 'out')
            foreach ($name in 'JpegQuality', 'SaveImages', 'Classification', 'LinkImages', 'NoCaptureLog', 'SettleSeconds') { @($binding.BoundParameters.Keys) | Should -Contain $name }
        }
    }
}

Describe 'Running the command the Designer shows (real script, headless Edge)' -Tag 'Integration' {
    BeforeAll {
        $script:RunWeb = Get-FreeTcpPort
        $script:RunCdp = Get-FreeTcpPort
        $script:RunProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-run-$($script:RunCdp)"
        $script:RunServer = Start-TestServer -Port $script:RunWeb
        $script:RunEdge = Start-HeadlessEdge -Port $script:RunCdp -ProfileDir $script:RunProfile
        # Every quoting hazard in the folder name; the engine is copied there alone.
        $script:Odd = Join-Path $TestDrive 'Prüfung $x `y & ''z'' (Q3)'
        [void](New-Item -ItemType Directory -Path $script:Odd -Force)
        Copy-Item -LiteralPath $script:VouchPath -Destination (Join-Path $script:Odd 'vouch.ps1')
        $config = Get-DefaultVouchConfig
        $config['browser']['profileDir'] = $script:RunProfile
        $config['browser']['debugPort'] = $script:RunCdp
        $config['defaults']['captureArea'] = 'page'
        $config['defaults']['settleSeconds'] = 0.1
        $config['output']['dir'] = 'out'
        $config['output']['reportName'] = 'proof'
        $config['pages'].Add([ordered]@{ id = 'p001'; name = 'Plain page'; url = "http://localhost:$($script:RunWeb)/ok" })
        $script:OddConfig = Join-Path $script:Odd 'tiny config.json'
        [void](Save-VouchConfig -Config $config -Path $script:OddConfig)
        $script:OddCommand = Get-VouchCommandLine -Config $config -ConfigPath $script:OddConfig -ScriptPath (Join-Path $script:Odd 'vouch.ps1')
    }
    AfterAll {
        Stop-HeadlessEdge -ProfileDir $script:RunProfile
        if ($null -ne $script:RunServer) { Stop-ProcessTree -ProcessId $script:RunServer.Id }
        Remove-DirectoryWithRetry -Path $script:RunProfile
    }

    It 'the <Shell> command runs and makes a report that verifies' -ForEach @(@{ Shell = 'PowerShell' }, @{ Shell = 'cmd.exe' }) {
        $out = Join-Path $script:Odd 'out'
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        $log = Join-Path $TestDrive "run-$Shell.txt"
        if ($Shell -eq 'PowerShell') {
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:OddCommand.Run + '; exit $LASTEXITCODE'))
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
        }
        else {
            $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -ArgumentList "/d /s /c `"$($script:OddCommand.RunCmd)`""
        }
        $process.ExitCode | Should -Be 0 -Because (Get-Content -Raw -LiteralPath $log)
        $report = Join-Path $out 'proof.html'
        $report | Should -Exist
        $rows = @(Test-ReportIntegrity -Path $report)
        $rows.Count | Should -BeGreaterThan 2
        @($rows | Where-Object { -not $_.Ok }).Count | Should -Be 0
    }

    It 'the spelled-out <Shell> command passes every value it writes exactly, and the file supplies the rest' -ForEach @(@{ Shell = 'PowerShell' }, @{ Shell = 'cmd.exe' }) {
        $title = 'Q3 R&D ''review'' $HOME `n é (draft)'
        $description = 'He said "yes" & left'
        $company = '100% %USERNAME% Müller'
        $config = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($script:OddConfig))
        $config['output']['reportName'] = 'expanded'
        $config['output']['jsonSummary'] = $true
        $config['report']['title'] = $title
        $config['report']['description'] = $description
        $config['report']['company']['name'] = $company
        $file = Join-Path $script:Odd 'expanded.json'
        [void](Save-VouchConfig -Config $config -Path $file)
        $line = Get-VouchCommandLine -Config $config -ConfigPath $file -ScriptPath (Join-Path $script:Odd 'vouch.ps1')
        # The file now says something else: whatever the run shows from the file was not on the command line.
        $config['report']['title'] = 'FROM FILE title'
        $config['report']['description'] = 'FROM FILE description'
        $config['report']['company']['name'] = 'FROM FILE company'
        [void](Save-VouchConfig -Config $config -Path $file)
        $out = Join-Path $script:Odd 'out'
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        $log = Join-Path $TestDrive "expanded-$Shell.txt"
        if ($Shell -eq 'PowerShell') {
            $line.RunExpanded | Should -Match '-Description '
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($line.RunExpanded + '; exit $LASTEXITCODE'))
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
        }
        else {
            $line.RunExpandedCmd | Should -Match '-ReportTitle '
            $line.RunExpandedCmd | Should -Not -Match '-Description |-CompanyName '
            $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -ArgumentList "/d /s /c `"$($line.RunExpandedCmd)`""
        }
        $process.ExitCode | Should -Be 0 -Because (Get-Content -Raw -LiteralPath $log)
        $summary = Get-Content -Raw -LiteralPath (Join-Path $out 'expanded.json') | ConvertFrom-Json
        $summary.ReportDetails.Title | Should -BeExactly $title
        if ($Shell -eq 'PowerShell') {
            $summary.ReportDetails.Description | Should -BeExactly $description
            $summary.ReportDetails.Company.Name | Should -BeExactly $company
        }
        else {
            $summary.ReportDetails.Description | Should -BeExactly 'FROM FILE description'
            $summary.ReportDetails.Company.Name | Should -BeExactly 'FROM FILE company'
        }
    }}

Describe 'The real listener (child pwsh, real sockets)' -Tag 'Integration' {
    BeforeAll { $script:Live = Start-DesignerTestServer -Name 'live' }
    AfterAll { if ($null -ne $script:Live) { Stop-Process -Id $script:Live.Process.Id -Force -ErrorAction SilentlyContinue } }

    It 'serves the page with the security headers and no CORS header' {
        foreach ($case in @(@('/', 'text/html; charset=utf-8'), @('/app.js', 'text/javascript; charset=utf-8'), @('/app.css', 'text/css; charset=utf-8'))) {
            $r = Invoke-RawRequest -Url "$($script:Live.Base)$($case[0])"
            $r.Status | Should -Be 200
            $r.Headers['Content-Type'] | Should -Be $case[1]
            $r.Headers['Content-Security-Policy'] | Should -Be "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
            $r.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
            $r.Headers['Cache-Control'] | Should -Be 'no-store'
            $r.Headers.Keys | Where-Object { $_ -like 'Access-Control-*' } | Should -BeNullOrEmpty
        }
        (Invoke-RawRequest -Url "$($script:Live.Base)/designer.ps1").Status | Should -Be 404
    }

    It 'answers the token holder and refuses everyone else' {
        $token = @{ 'X-Vouch-Token' = $script:Live.Token }
        (Invoke-RawRequest -Url "$($script:Live.Base)/api/state" -Headers $token).Status | Should -Be 200
        (Invoke-RawRequest -Url "$($script:Live.Base)/api/state").Status | Should -Be 403
        (Invoke-RawRequest -Url "$($script:Live.Base)/api/state" -Headers @{ 'X-Vouch-Token' = 'wrong' }).Status | Should -Be 403
        # A wrong Host is refused by http.sys or by the gate; either way, 400 and nothing done.
        (Invoke-RawRequest -Url "$($script:Live.Base)/api/state" -Headers $token -HostHeader "evil.example:$($script:Live.Port)").Status | Should -Be 400
        (Invoke-RawRequest -Url "http://127.0.0.1:$($script:Live.Port)/api/state" -Headers $token).Status | Should -Be 400
        $post = @{ 'X-Vouch-Token' = $script:Live.Token }
        (Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/config/new" -Headers $post -Body '{}' -ContentType 'application/json').Status | Should -Be 403
        $foreign = Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/config/new" -Headers ($post + @{ Origin = 'http://localhost:1' }) -Body '{}' -ContentType 'application/json'
        $foreign.Status | Should -Be 403
        $foreign.Headers.Keys | Where-Object { $_ -like 'Access-Control-*' } | Should -BeNullOrEmpty
        $preflight = Invoke-RawRequest -Method OPTIONS -Url "$($script:Live.Base)/api/config/new" -Headers @{ Origin = 'http://localhost:1'; 'Access-Control-Request-Method' = 'POST' }
        $preflight.Status | Should -Be 403
        $preflight.Headers.Keys | Where-Object { $_ -like 'Access-Control-*' } | Should -BeNullOrEmpty
        $own = $post + @{ Origin = $script:Live.Base }
        (Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/config/new" -Headers $own -Body '{}' -ContentType 'text/plain').Status | Should -Be 415
        # Refused on the declared length alone; with Expect: 100-continue the client sends
        # the body only if the server asks for it, which it never does here.
        (Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/config/validate" -Headers $own -Body ('{"x":"' + ('a' * 5MB) + '"}') -ContentType 'application/json' -ExpectContinue).Status | Should -Be 413
        (Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/config/validate" -Headers @{ 'X-Vouch-Token' = 'wrong'; Origin = $script:Live.Base } -Body ('{"x":"' + ('a' * 5MB) + '"}') -ContentType 'application/json' -ExpectContinue).Status | Should -Be 403
        $ok = Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/config/new" -Headers $own -Body '{}' -ContentType 'application/json'
        $ok.Status | Should -Be 200
        ($ok.Body | ConvertFrom-Json).config.schemaVersion | Should -Be 1
    }

    It 'stops on /api/shutdown, and the process ends' {
        $own = @{ 'X-Vouch-Token' = $script:Live.Token; Origin = $script:Live.Base }
        (Invoke-RawRequest -Method POST -Url "$($script:Live.Base)/api/shutdown" -Headers $own -Body '{}' -ContentType 'application/json').Status | Should -Be 200
        $script:Live.Process.WaitForExit(10000) | Should -BeTrue
        { Invoke-RawRequest -Url "$($script:Live.Base)/" } | Should -Throw
    }
}

Describe 'The panel in headless Edge' -Tag 'Integration' {
    BeforeAll {
        $script:PanelConfig = Copy-Sample 'panel.json'
        $script:Panel = Start-DesignerTestServer -ConfigPath $script:PanelConfig -Name 'panel'
        $script:PanelCdp = Get-FreeTcpPort
        $script:PanelProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-panel-$($script:PanelCdp)"
        $script:PanelEdge = Start-HeadlessEdge -Port $script:PanelCdp -ProfileDir $script:PanelProfile
        Close-CdpSocket
        $target = Get-CdpPageTarget -Port $script:PanelCdp -WaitSeconds 5
        Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
        # A collector that runs before the panel's own script: CSP violations, errors,
        # rejected promises and console errors of the whole session end up in __errs.
        $collector = @'
window.__errs = [];
window.addEventListener('error', e => window.__errs.push('error: ' + (e.message || e.type) + ' ' + (e.filename || '')), true);
window.addEventListener('unhandledrejection', e => window.__errs.push('rejection: ' + ((e.reason && e.reason.message) || e.reason)));
document.addEventListener('securitypolicyviolation', e => window.__errs.push('csp: ' + e.violatedDirective + ' ' + e.blockedURI));
const vouchConsoleError = console.error;
console.error = function () { window.__errs.push('console: ' + Array.from(arguments).join(' ')); return vouchConsoleError.apply(console, arguments); };
'@
        [void](Send-CdpCommand -Method 'Page.enable')
        [void](Send-CdpCommand -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{ source = $collector })
        [void](Send-CdpCommand -Method 'Emulation.setDeviceMetricsOverride' -Params @{ width = 480; height = 900; deviceScaleFactor = 1; mobile = $false })
        Set-NavigationMarker
        [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $script:Panel.Url })
        [void](Wait-PageReady -TimeoutSec 15)
        [void](Invoke-CdpEval -Expression 'window.VouchDesigner.ready.then(() => true)' -TimeoutSec 20)
        $helpers = @'
window.__field = path => Array.from(document.querySelectorAll('[data-path]')).find(e => e.dataset.path === path && e.type !== 'radio');
window.__type = (path, value) => { const el = window.__field(path); if (!el) throw new Error('no field ' + path); el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); };
window.__tick = (path, checked) => { const el = window.__field(path); el.checked = checked; el.dispatchEvent(new Event('change', { bubbles: true })); };
window.__choose = (path, value) => { const el = window.__field(path); el.value = value; el.dispatchEvent(new Event('change', { bubbles: true })); };
window.__radio = (path, value) => { const el = Array.from(document.querySelectorAll('input[type=radio]')).find(e => e.dataset.path === path && e.value === String(value)); el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); };
window.__err = path => { const el = Array.from(document.querySelectorAll('[data-err-for]')).find(e => e.dataset.errFor === path); return el && !el.hidden ? el.textContent : ''; };
window.__cfg = () => window.VouchDesigner.S.config;
'@
        [void](Invoke-CdpEval -Expression $helpers)
        function Invoke-Panel([string]$Script) {
            # Runs an async body in the page and returns its JSON result.
            $json = Invoke-CdpEval -TimeoutSec 30 -Expression "(async () => { const D = window.VouchDesigner; const S = D.S; const r = await (async () => { $Script })(); return JSON.stringify(r === undefined ? null : r); })()"
            if ($null -eq $json) { return $null }
            return $json | ConvertFrom-Json -Depth 64
        }
    }
    AfterAll {
        Close-CdpSocket
        Stop-HeadlessEdge -ProfileDir $script:PanelProfile
        if ($null -ne $script:Panel) { Stop-Process -Id $script:Panel.Process.Id -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryWithRetry -Path $script:PanelProfile
    }

    It 'opens the file given at the start and shows the pages and the first page''s editor' {
        $r = Invoke-Panel @'
return { title: document.querySelector('#file-title').textContent, dirty: !document.querySelector('#dirty-marker').hidden,
  rows: Array.from(document.querySelectorAll('.page-name')).map(e => e.textContent), name: __field('pages[0].name').value,
  url: location.href, hasToken: location.href.includes('t='), path: S.path, actions: document.querySelectorAll('.action-row').length,
  tabs: Array.from(document.querySelectorAll('[role=tab]')).map(t => t.getAttribute('aria-selected')) };
'@
        $r.title | Should -Be 'panel.json'
        $r.dirty | Should -BeFalse
        $r.rows | Should -Be @('Intranet Dashboard', 'App Settings - Audit Log', 'Payroll - security settings', 'Admin User List')
        $r.name | Should -Be 'Intranet Dashboard'
        $r.hasToken | Should -BeFalse
        $r.path | Should -Be $script:PanelConfig
        $r.actions | Should -Be 1
        $r.tabs | Should -Be @('true', 'false', 'false', 'false')
    }

    It 'edits a field into the configuration in memory and marks it unsaved' {
        $r = Invoke-Panel @'
__type('pages[0].name', 'Dashboard (edited)');
return { name: __cfg().pages[0].name, listed: document.querySelector('.page-name').textContent, dirty: !document.querySelector('#dirty-marker').hidden, title: document.title };
'@
        $r.name | Should -Be 'Dashboard (edited)'
        $r.listed | Should -Be 'Dashboard (edited)'
        $r.dirty | Should -BeTrue
        $r.title | Should -BeLike '`* panel.json*'
    }

    It 'shows plain-language problems for a bad address and a duplicate id, and lists them' {
        $r = Invoke-Panel @'
__type('pages[0].url', 'intranet.example.com');
D.selectPage(1);
__type('pages[1].id', 'P001');
await D.validateNow();
const urlError = (D.selectPage(0), __err('pages[0].url'));
const invalid = __field('pages[0].url').getAttribute('aria-invalid');
D.selectPage(1);
return { urlError, invalid, idError: __err('pages[1].id'), issues: document.querySelector('.issues-toggle').textContent,
  problems: D.problems().errors.map(p => p.path) };
'@
        $r.urlError | Should -Be 'The address must start with http:// or https://.'
        $r.invalid | Should -Be 'true'
        $r.idError | Should -Match 'already uses the id'
        $r.issues | Should -Match '^.2 problems to fix'
        $r.problems | Should -Be @('pages[0].url', 'pages[1].id')
    }

    It 'jumps from the problem list to the field' {
        $r = Invoke-Panel @'
D.selectPage(3); D.setTab('report');
S.issuesOpen = true; D.jumpTo('pages[1].id');
return { tab: S.tab, page: S.page, focused: document.activeElement.dataset.path };
'@
        $r.tab | Should -Be 'pages'
        $r.page | Should -Be 1
        $r.focused | Should -Be 'pages[1].id'
    }

    It 'refuses to save while there are problems' {
        $r = Invoke-Panel @'
const saving = D.save(false);
await new Promise(r => setTimeout(r, 100));
const dialog = document.querySelector('#modal');
const open = dialog.open, title = document.querySelector('#modal-title').textContent;
dialog.close();
return { open, title, saved: await saving };
'@
        $r.open | Should -BeTrue
        $r.title | Should -Be 'Not saved yet'
        $r.saved | Should -BeFalse
    }

    It 'adds, moves, deletes and undoes pages and actions' {
        $r = Invoke-Panel @'
D.selectPage(0); __type('pages[0].url', 'https://intranet.example.com/dashboard');
D.selectPage(1); __type('pages[1].id', 'p002');
const before = __cfg().pages.map(p => p.id);
D.addPage();
const added = __cfg().pages.length, newId = __cfg().pages[4].id, focused = document.activeElement.dataset.path;
D.movePage(4, 0, true);
const moved = __cfg().pages.map(p => p.id), selected = S.page;
D.deletePage(0);
const afterDelete = __cfg().pages.map(p => p.id);
D.undo();
const afterUndo = __cfg().pages.map(p => p.id);
D.redo();
const afterRedo = __cfg().pages.map(p => p.id);
D.selectPage(2);
D.addAction(2, { type: 'wait', seconds: 4 });
const actions = __cfg().pages[2].actions.map(a => a.type);
D.moveAction(2, 7, 0);
const movedActions = __cfg().pages[2].actions.map(a => a.type);
const sentence = document.querySelector('.action-text').textContent;
D.deleteAction(2, 0);
const afterActionDelete = __cfg().pages[2].actions.length;
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', ctrlKey: true, bubbles: true }));
const afterCtrlZ = __cfg().pages[2].actions.length;
return { before, added, newId, focused, moved, selected, afterDelete, afterUndo, afterRedo, actions, movedActions, sentence, afterActionDelete, afterCtrlZ };
'@
        $r.before | Should -Be @('p001', 'p002', 'p003', 'p004')
        $r.added | Should -Be 5
        $r.newId | Should -Be 'p005'
        $r.focused | Should -Be 'pages[4].name'
        $r.moved | Should -Be @('p005', 'p001', 'p002', 'p003', 'p004')
        $r.selected | Should -Be 0
        $r.afterDelete | Should -Be @('p001', 'p002', 'p003', 'p004')
        $r.afterUndo | Should -Be @('p005', 'p001', 'p002', 'p003', 'p004')
        $r.afterRedo | Should -Be @('p001', 'p002', 'p003', 'p004')
        $r.actions | Should -Be @('pause', 'clickText', 'capture', 'click', 'waitFor', 'wait', 'capture', 'wait')
        $r.movedActions[0] | Should -Be 'wait'
        $r.sentence | Should -Be 'Wait 4 seconds'
        $r.afterActionDelete | Should -Be 7
        $r.afterCtrlZ | Should -Be 8
    }

    It 'moves a page with Alt+Down on its row and keeps the focus on it' {
        $r = Invoke-Panel @'
D.selectPage(0);
const row = Array.from(document.querySelectorAll('.page-select'))[0];
row.focus();
row.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', altKey: true, bubbles: true }));
const ids = __cfg().pages.map(p => p.id);
const focused = document.activeElement.dataset.fkey;
D.undo();
return { ids, focused };
'@
        $r.ids | Should -Be @('p002', 'p001', 'p003', 'p004')
        $r.focused | Should -Be 'page-select:1'
    }

    It 'edits an action and a page override, and resets the override to the run default' {
        $r = Invoke-Panel @'
D.selectPage(2); S.openAction = 7; S.overridesOpen = true; D.setTab('pages');
__radio('pages[2].actions[7].scroll.mode', 'page');
__radio('pages[2].actions[7].scroll.as', 'single');
const scroll = __cfg().pages[2].actions[7].scroll;
const summary = document.querySelectorAll('.action-text')[7].textContent;
__type('pages[2].overrides.zoomPercent', '90');
const zoom = __cfg().pages[2].overrides.zoomPercent;
Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === 'reset:pages[2].overrides.zoomPercent').click();
return { scroll, summary, zoom, after: 'zoomPercent' in __cfg().pages[2].overrides };
'@
        $r.scroll.mode | Should -Be 'page'
        $r.scroll.as | Should -Be 'single'
        $r.scroll.selector | Should -Be '#main'
        $r.summary | Should -Be "Capture: whole page by scrolling, as one tall image — $([char]0x2018)Lockout$([char]0x2019)"
        $r.zoom | Should -Be 90
        $r.after | Should -BeFalse
    }

    It 'round-trips Output and Report fields into the configuration' {
        $r = Invoke-Panel @'
D.setTab('output');
__type('output.jpegQuality', '70');
__tick('output.zip.enabled', true);
__type('output.zip.name', '{report} {classification}');
__radio('output.embedImages', false);
__tick('output.captureLog', false);
__radio('defaults.captureArea', 'window');
await D.validateNow();
const zipPreview = document.querySelector('[data-preview=zip]').textContent;
D.setTab('report');
__type('report.title', 'Q3 ITGC <evidence>');
__choose('report.classification', 'Internal');
__type('report.period.label', 'Q3 2026');
__type('report.company.details', 'Line 1\nLine 2');
__tick('report.showIndex', false);
const chip = document.querySelector('.cls-chip').textContent;
const o = __cfg().output, rep = __cfg().report;
return { q: o.jpegQuality, zip: o.zip, embed: o.embedImages, log: o.captureLog, area: __cfg().defaults.captureArea,
  zipPreview, title: rep.title, cls: rep.classification, label: rep.period.label, details: rep.company.details, index: rep.showIndex, chip,
  heading: document.querySelector('h1').textContent };
'@
        $r.q | Should -Be 70
        $r.zip.enabled | Should -BeTrue
        $r.zip.name | Should -Be '{report} {classification}'
        $r.embed | Should -BeFalse
        $r.log | Should -BeFalse
        $r.area | Should -Be 'window'
        $r.zipPreview | Should -Match 'VouchReport_\d{4}-\d\d-\d\d_\d{6} Confidential\.zip$'
        $r.title | Should -Be 'Q3 ITGC <evidence>'
        $r.cls | Should -Be 'Internal'
        $r.label | Should -Be 'Q3 2026'
        $r.details | Should -Be "Line 1`nLine 2"
        $r.index | Should -BeFalse
        $r.chip | Should -Be 'INTERNAL'
        $r.heading | Should -Be 'panel.json'
    }

    It 'shows the commands for the saved file and says when it has unsaved changes' {
        $r = Invoke-Panel @'
D.setTab('run');
await D.refreshCommand();
const box = document.querySelector('#command-box');
return { text: box.textContent, codes: [S.command.run], warning: !!box.querySelector('.callout-warning'),
  later: document.querySelector('.later-note') ? document.querySelector('.later-note').textContent : '' };
'@
        $r.warning | Should -BeTrue
        $r.codes[0] | Should -BeLike "pwsh -NoProfile -ExecutionPolicy Bypass -File *vouch.ps1`" -ConfigPath `"$($script:PanelConfig)`""
        $r.text | Should -Match 'Schedule it'
        $r.later | Should -Match 'later step'
    }

    It 'saves through the API, and the saved file reads back as the configuration shown' {
        $r = Invoke-Panel @'
const ok = await D.save(false);
await D.refreshCommand();
return { ok, dirty: D.isDirty(), marker: !document.querySelector('#dirty-marker').hidden, warning: !!document.querySelector('#command-box .callout-warning'),
  config: __cfg(), expanded: document.querySelectorAll('#command-box pre code')[1].textContent };
'@
        $r.ok | Should -BeTrue
        $r.dirty | Should -BeFalse
        $r.marker | Should -BeFalse
        $r.warning | Should -BeFalse
        $saved = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($script:PanelConfig))
        $saved['pages'][0]['name'] | Should -Be 'Dashboard (edited)'
        $saved['output']['jpegQuality'] | Should -Be 70
        $saved['report']['company']['details'] | Should -Be "Line 1`nLine 2"
        $saved['report']['title'] | Should -Be 'Q3 ITGC <evidence>'
        @($saved.Keys) | Should -Be @('schemaVersion', 'name', 'browser', 'defaults', 'output', 'report', 'pages')
        (Test-VouchConfig -Config $saved).Errors.Count | Should -Be 0
        ($r.config | ConvertTo-Json -Depth 64 -Compress) | Should -Be (($saved | ConvertTo-Json -Depth 64 -Compress))
        $r.expanded | Should -Match '-JpegQuality 70'
        "$($script:PanelConfig).bak" | Should -Exist
    }

    It 'shows each command one switch per line, and Copy gives the exact one-line command' {
        $r = Invoke-Panel @'
D.setTab('run');
await D.refreshCommand();
let copied = null;
Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: text => { copied = text; return Promise.resolve(); } } });
Array.from(document.querySelectorAll('#command-box button')).find(b => b.dataset.fkey === 'copy:expanded').click();
await new Promise(r => setTimeout(r, 50));
const pre = document.querySelectorAll('#command-box pre.command-text')[1];
const lines = Array.from(pre.querySelectorAll('.cmd-line')).map(e => e.textContent);
const box = document.querySelector('#command-box');
return { copied, api: S.command.runExpanded, lines, schedule: S.command.schedule, shown: box.textContent,
  later: document.querySelector('#panel-run .later-note').textContent };
'@
        $r.copied | Should -BeExactly $r.api
        ($r.lines -join ' ') | Should -BeExactly $r.api
        $r.lines[0] | Should -Be 'pwsh -NoProfile -ExecutionPolicy Bypass'
        $r.lines[1] | Should -BeLike '-File *vouch.ps1"'
        foreach ($line in $r.lines | Select-Object -Skip 1) { $line | Should -Match '^-[A-Za-z]+( |$)' }
        $r.lines | Should -Contain '-SaveImages'
        $r.schedule | Should -Not -BeNullOrEmpty
        $r.shown | Should -Not -Match 'Install-VouchSchedule'
        $r.shown | Should -Match 'on a schedule comes in a later step'
        $r.later | Should -Match 'copy the command below'
    }

    It 'keeps edits made while a save is on its way, and leaves them marked unsaved' {
        $r = Invoke-Panel @'
D.setTab('pages'); D.selectPage(0);
const saving = D.save(false);
__type('pages[0].notes', 'typed while saving');
const ok = await saving;
return { ok, notes: __cfg().pages[0].notes, dirty: D.isDirty(), marker: !document.querySelector('#dirty-marker').hidden, field: __field('pages[0].notes').value };
'@
        $r.ok | Should -BeTrue
        $r.notes | Should -Be 'typed while saving'
        $r.field | Should -Be 'typed while saving'
        $r.dirty | Should -BeTrue
        $r.marker | Should -BeTrue
        $saved = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($script:PanelConfig))
        $saved['pages'][0]['notes'] | Should -Not -Be 'typed while saving'
    }

    It 'blocks the panel while a server-side file dialog is open' {
        $r = Invoke-Panel @'
let release;
const pending = D.whileServerDialog(() => new Promise(r => { release = r; }));
await new Promise(r => setTimeout(r, 30));
const busy = document.querySelector('#busy');
const open = busy.open;
const before = JSON.stringify(__cfg());
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', ctrlKey: true, bubbles: true }));
busy.dispatchEvent(new Event('cancel', { cancelable: true }));
const stillOpen = busy.open;
const after = JSON.stringify(__cfg());
release('answer');
const value = await pending;
return { open, stillOpen, unchanged: before === after, value, closed: !busy.open, title: document.querySelector('#busy-title').textContent };
'@
        $r.open | Should -BeTrue
        $r.stillOpen | Should -BeTrue
        $r.unchanged | Should -BeTrue
        $r.value | Should -Be 'answer'
        $r.closed | Should -BeTrue
        $r.title | Should -Be 'Waiting for the file dialog…'
    }

    It 'leaves no empty strings or empty overrides behind, but keeps empties the file already had' {
        $r = Invoke-Panel @'
D.addPage();
const n = __cfg().pages.length - 1;
const newKeys = Object.keys(__cfg().pages[n]);
const captureKeys = Object.keys(__cfg().pages[n].actions[0]);
__type('pages[' + n + '].notes', 'n');
__type('pages[' + n + '].notes', '');
const notesKept = 'notes' in __cfg().pages[n];
D.deletePage(n);
D.selectPage(3); S.overridesOpen = true; D.setTab('pages');
Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === 'reset:pages[3].overrides.maxScrollSegments').click();
const overridesKept = 'overrides' in __cfg().pages[3];
D.undo();
D.selectPage(0); S.overridesOpen = true; D.setTab('pages');
__type('pages[0].overrides.zoomPercent', '90');
__type('pages[0].overrides.zoomPercent', '');
const emptyOverridesKept = JSON.stringify(__cfg().pages[0].overrides);
D.setTab('report');
__type('report.origin', 'x');
__type('report.origin', '');
const origin = __cfg().report.origin;
__type('report.company.name', '');
const company = 'name' in __cfg().report.company;
return { newKeys, captureKeys, notesKept, overridesKept, emptyOverridesKept, origin, company };
'@
        $r.newKeys | Should -Be @('id', 'name', 'url', 'enabled', 'actions')
        $r.captureKeys | Should -Be @('type', 'scroll')
        $r.notesKept | Should -BeFalse
        $r.overridesKept | Should -BeFalse
        $r.emptyOverridesKept | Should -Be '{}'
        $r.origin | Should -Be ''
        $r.company | Should -BeFalse
    }

    It 'keeps what was typed when switching a click between words and selector' {
        $r = Invoke-Panel @'
D.setTab('pages'); D.selectPage(1); S.openAction = 0; D.setTab('pages');
const path = 'pages[1].actions[0]';
const start = JSON.stringify(__cfg().pages[1].actions[0]);
__radio(path + '.type', 'click');
const asClick = JSON.stringify(__cfg().pages[1].actions[0]);
__type(path + '.selector', '#tab-audit');
__radio(path + '.type', 'clickText');
const back = JSON.stringify(__cfg().pages[1].actions[0]);
__radio(path + '.type', 'click');
const again = JSON.stringify(__cfg().pages[1].actions[0]);
S.openAction = -1; D.setTab('pages');
const stash = S.clickStash;
return { start, asClick, back, again, stash };
'@
        $r.start | Should -Be '{"type":"clickText","text":"Audit Log"}'
        $r.asClick | Should -Be '{"type":"click","selector":""}'
        $r.back | Should -Be '{"type":"clickText","text":"Audit Log"}'
        $r.again | Should -Be '{"type":"click","selector":"#tab-audit"}'
        $r.stash | Should -BeNullOrEmpty
    }

    It 'shows the later-step buttons as unavailable, with an explanation instead of an action' {
        $r = Invoke-Panel @'
D.setTab('pages');
const pick = Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === 'pick-click');
pick.click();
await new Promise(r => setTimeout(r, 50));
return { disabled: pick.getAttribute('aria-disabled'), toast: document.querySelector('#toast').textContent };
'@
        $r.disabled | Should -Be 'true'
        $r.toast | Should -Match 'later step'
    }

    It 'does not overflow sideways at <Width> px on any tab' -ForEach @(@{ Width = 380 }, @{ Width = 1100 }) {
        [void](Send-CdpCommand -Method 'Emulation.setDeviceMetricsOverride' -Params @{ width = $Width; height = 900; deviceScaleFactor = 1; mobile = $false })
        $r = Invoke-Panel @'
const out = {};
for (const tab of ['pages', 'output', 'report', 'run']) {
  D.setTab(tab);
  if (tab === 'run') await D.refreshCommand();
  if (tab === 'pages') { S.openAction = 6; S.overridesOpen = true; D.selectPage(2); }
  await new Promise(r => requestAnimationFrame(() => r()));
  out[tab] = document.documentElement.scrollWidth - document.documentElement.clientWidth;
}
return out;
'@
        foreach ($tab in 'pages', 'output', 'report', 'run') { $r.$tab | Should -BeLessOrEqual 0 -Because "the $tab tab must fit $Width px" }
    }

    It 'had no CSP violation, script error or console error in the whole session' {
        # 'missing' would mean the collector never ran, which must not pass as 'no errors'.
        Invoke-CdpEval -Expression "Array.isArray(window.__errs) ? JSON.stringify(window.__errs) : 'missing'" | Should -Be '[]'
    }
}

Describe 'Designer mode in vouch.ps1 and the panel window' {
    It 'says plainly that the designer folder is missing, and writes no events or logs' {
        $alone = Join-Path $TestDrive 'alone'
        [void](New-Item -ItemType Directory -Path $alone -Force)
        Copy-Item -LiteralPath $script:VouchPath -Destination (Join-Path $alone 'vouch.ps1')
        $events = Join-Path $alone 'events.ndjson'
        $out = Join-Path $alone 'out.txt'
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out `
            -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$(Join-Path $alone 'vouch.ps1')`"", '-Designer', '-EventLogPath', "`"$events`"", '-LogDir', "`"$alone\logs`""
        $process.ExitCode | Should -Be 1
        $text = Get-Content -Raw -LiteralPath $out
        $text | Should -Match "needs the folder 'designer' next to vouch.ps1"
        $text | Should -Match 'Everything else vouch.ps1 does works without it'
        $events | Should -Not -Exist
        "$alone\logs" | Should -Not -Exist
    }

    It 'has a launcher that starts the Designer and explains a missing PowerShell 7 (Windows line ends)' {
        $cmd = Join-Path (Split-Path $script:VouchPath) 'Vouch-Designer.cmd'
        $bytes = [System.IO.File]::ReadAllBytes($cmd)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Match 'pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0vouch.ps1" -Designer'
        $text | Should -Match 'needs PowerShell 7'
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0
    }

    It 'opens the panel as an app window with its own profile, at the right edge, with sync off' {
        $arguments = Get-DesignerPanelArgument -Url 'http://localhost:5/?t=x' -ProfileDir (Get-DesignerPanelProfile) -Bounds ([pscustomobject]@{ X = 1433; Y = 0; Width = 494; Height = 1047 })
        $arguments | Should -Contain '--app=http://localhost:5/?t=x'
        $arguments | Should -Contain '--disable-sync'
        $arguments | Should -Contain '--no-first-run'
        $arguments | Should -Contain '--no-default-browser-check'
        $arguments | Should -Contain '--window-size=494,1047'
        $arguments | Should -Contain '--window-position=1433,0'
        $profile = Get-DesignerPanelProfile
        $profile | Should -Be (Join-Path $env:LOCALAPPDATA 'Vouch\DesignerPanel')
        $profile.Contains((Join-Path $env:LOCALAPPDATA 'Vouch\EdgeProfile'), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
        { Start-DesignerPanel -Url 'http://localhost:5/' -ProfileDir (Join-Path $env:LOCALAPPDATA 'Vouch\EdgeProfile\x') } | Should -Throw '*overlap*'
    }

    It 'keeps the panel profile and the audit profile apart: <Case>' -ForEach @(
        @{ Case = 'audit profile whose name starts with the panel''s'; Audit = 'C:\P\Vouch\DesignerPanel2'; Bad = $true }
        @{ Case = 'audit profile inside the panel profile'; Audit = 'C:\P\Vouch\DesignerPanel\audit'; Bad = $true }
        @{ Case = 'panel profile inside the audit profile'; Audit = 'C:\P\Vouch'; Bad = $true }
        @{ Case = 'the same folder, other capitals'; Audit = 'c:\p\vouch\designerpanel\'; Bad = $true }
        @{ Case = 'separate folders'; Audit = 'C:\P\Vouch\EdgeProfile'; Bad = $false }
    ) {
        $problem = Test-DesignerProfileOverlap -PanelProfile 'C:\P\Vouch\DesignerPanel' -AuditProfile $Audit
        if ($Bad) { $problem | Should -Match 'overlap' } else { $problem | Should -Be '' }
    }

    It 'finds the audit profile in effect and checks it at start' {
        $folder = Join-Path $TestDrive 'audit'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $config = Join-Path $folder 'c.json'
        Set-Content -LiteralPath $config -Value '{ "schemaVersion": 1, "browser": { "profileDir": "profiles\\DesignerPanel-copy" }, "pages": [] }' -Encoding utf8NoBOM
        Get-DesignerAuditProfile -ConfigPath $config | Should -Be (Join-Path $folder 'profiles\DesignerPanel-copy')
        Get-DesignerAuditProfile -EdgeProfileDir 'C:\typed' -ConfigPath $config | Should -Be 'C:\typed'
        Get-DesignerAuditProfile | Should -Be (Join-Path $env:LOCALAPPDATA 'Vouch\EdgeProfile')
        $state = New-TestState
        $state.PanelProfileDir = Join-Path $folder 'profiles\DesignerPanel'
        { Assert-DesignerProfileSeparate -State $state -AuditProfile (Get-DesignerAuditProfile -ConfigPath $config) } | Should -Throw '*overlap*'
        Assert-DesignerProfileSeparate -State $state -AuditProfile 'C:\elsewhere\EdgeProfile'
        $state.AuditProfileDir | Should -Be 'C:\elsewhere\EdgeProfile'
        { Start-VouchDesigner -ScriptPath $script:VouchPath -ConfigPath $config -NoPanel -PanelProfileDir (Join-Path $folder 'profiles\DesignerPanel') 6>$null } | Should -Throw '*overlap*'
    }

    It 'puts the panel about 480 px wide at the right of the working area, full height' {
        $bounds = Get-DesignerPanelBounds
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $bounds.Width | Should -Be 494
        ($bounds.X + $bounds.Width - 7) | Should -Be $area.Right
        $bounds.Y | Should -Be $area.Top
        $bounds.Height | Should -Be ($area.Height + 7)
    }

    It 'stops the loop when the panel window has gone' {
        $state = New-TestState
        $state.PanelProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
        $state.PanelProcess.WaitForExit()
        Mock Find-EdgeBrowserProcess { $null }
        $state.TickHandlers.Add({ param($s) $script:TickSeen = $s.Port })
        Invoke-DesignerTick -State $state
        $state.Running | Should -BeFalse
        $state.StopReason | Should -Be 'The Designer window was closed.'
        $script:TickSeen | Should -Be 50999
    }
}
