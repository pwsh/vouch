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
            Without -AuditPort it never connects to a browser (-NoBrowser); with it, it
            attaches to the headless Edge listening there and never starts one.
        #>
        param([string]$ConfigPath = '', [string]$Name = 'server', [int]$AuditPort = 0, [string]$AuditProfile = '')
        $folder = Join-Path -Path $TestDrive -ChildPath $Name
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $ready = Join-Path -Path $folder -ChildPath 'ready.json'
        $literal = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
        $browser = if ($AuditPort -gt 0) { "-DebugPort $AuditPort -AuditProfileDir $(& $literal $AuditProfile) -NoBrowserLaunch" } else { '-NoBrowser' }
        $hostScript = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $(& $literal (Join-Path $PSScriptRoot 'TestHelpers.ps1'))
. ([scriptblock]::Create((Get-VouchFunctionSource -Path $(& $literal $script:VouchPath), $(& $literal $script:DesignerPath))))
Start-VouchDesigner -ScriptPath $(& $literal $script:VouchPath) -ConfigPath $(& $literal $ConfigPath) -NoPanel -ReadyFile $(& $literal $ready) -Version 'test' $browser
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
        'POST /api/run', 'GET /api/run', 'POST /api/run/stop', 'GET /preview/run1/001.jpg') {
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

    It 'stops waiting for a body that never comes (408) and goes on serving' {
        $client = [System.Net.Sockets.TcpClient]::new('localhost', $script:Live.Port)
        try {
            $stream = $client.GetStream()
            $head = "POST /api/config/validate HTTP/1.1`r`nHost: localhost:$($script:Live.Port)`r`nX-Vouch-Token: $($script:Live.Token)`r`nOrigin: $($script:Live.Base)`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n{"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($bytes, 0, $bytes.Length)
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $stream.ReadTimeout = 20000
            $reader = [System.IO.StreamReader]::new($stream)
            $status = $reader.ReadLine()
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
            $status | Should -Match ' 408 '
        }
        finally { $client.Dispose() }
        (Invoke-RawRequest -Url "$($script:Live.Base)/api/state" -Headers @{ 'X-Vouch-Token' = $script:Live.Token }).Status | Should -Be 200
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

    It 'shows the browser buttons as unavailable while no browser is connected, with the reason and Retry' {
        $r = Invoke-Panel @'
D.setTab('pages');
const pick = Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === 'pick-click');
pick.click();
await new Promise(r => setTimeout(r, 50));
const strip = document.querySelector('#browser-strip');
return { disabled: pick.getAttribute('aria-disabled'), toast: document.querySelector('#toast').textContent,
  strip: strip.textContent, off: strip.classList.contains('is-off'),
  retry: !!Array.from(strip.querySelectorAll('button')).find(b => b.dataset.fkey === 'bs-retry') };
'@
        $r.disabled | Should -Be 'true'
        $r.toast | Should -Match 'audit browser, which is not connected'
        $r.off | Should -BeTrue
        $r.strip | Should -Match 'Browser not connected'
        $r.retry | Should -BeTrue
    }

    It 'keeps the logo preview with the path it was picked for, through Undo and Redo' {
        $logo = Join-Path $TestDrive 'logo.png'
        $r = Invoke-Panel @"
const realFetch = window.fetch;
window.fetch = (url, options) => url === '/api/dialog'
  ? Promise.resolve(new Response(JSON.stringify({ path: $(ConvertTo-Json $logo), value: 'logo.png', logo: { path: $(ConvertTo-Json $logo), dataUri: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', warning: '' } }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
  : realFetch(url, options);
try {
  D.setTab('report');
  const before = __cfg().report.logoPath || '';
  Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === 'browse:report.logoPath').click();
  await new Promise(r => setTimeout(r, 100));
  const picked = { path: __cfg().report.logoPath, img: !!document.querySelector('.logo-thumb') };
  D.undo();
  const undone = { path: __cfg().report.logoPath || '', img: !!document.querySelector('.logo-thumb') };
  D.redo();
  const redone = { path: __cfg().report.logoPath, img: !!document.querySelector('.logo-thumb') };
  D.undo();
  return { before, picked, undone, redone };
} finally { window.fetch = realFetch; }
"@
        $r.picked.path | Should -Be 'logo.png'
        $r.picked.img | Should -BeTrue
        $r.undone.path | Should -Be $r.before
        $r.undone.img | Should -BeFalse
        $r.redone.path | Should -Be 'logo.png'
        $r.redone.img | Should -BeTrue
    }

    It 'keeps the waiting dialogs open while their request is pending, even when Esc closes them' {
        $r = Invoke-Panel @'
let release;
const pending = D.whileServerDialog(() => new Promise(r => { release = r; }));
await new Promise(r => setTimeout(r, 30));
const busy = document.querySelector('#busy');
busy.close();
await new Promise(r => setTimeout(r, 30));
const busyAfterClose = busy.open;
release('x'); await pending;
const busyAfterAnswer = busy.open;
const picking = document.querySelector('#picking');
const free = D.holdOpen(picking);
picking.close();
await new Promise(r => setTimeout(r, 30));
const pickingAfterClose = picking.open;
free();
return { busyAfterClose, busyAfterAnswer, pickingAfterClose, pickingAfterRelease: picking.open };
'@
        $r.busyAfterClose | Should -BeTrue
        $r.busyAfterAnswer | Should -BeFalse
        $r.pickingAfterClose | Should -BeTrue
        $r.pickingAfterRelease | Should -BeFalse
    }

    It 'finds a page by its id, not its position, when a cleared value is put back after pages were moved' {
        $r = Invoke-Panel @'
D.setTab('pages');
const ids = __cfg().pages.map(p => p.id);
// Page 4 (index 3) has "overrides" in the file; page 1 does not. Move page 4 to the top,
// then clear an override of the page now at the top and of the one now second.
D.movePage(3, 0, false);
S.overridesOpen = true; D.selectPage(0);
const top = JSON.stringify(__cfg().pages[0].overrides);
for (const key of Object.keys(__cfg().pages[0].overrides || {})) {
  const reset = Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === 'reset:pages[0].overrides.' + key);
  if (reset) reset.click();
}
const afterTop = JSON.stringify(__cfg().pages[0].overrides);
D.selectPage(1);
__type('pages[1].overrides.zoomPercent', '90');
__type('pages[1].overrides.zoomPercent', '');
const second = 'overrides' in __cfg().pages[1];
D.undo(); D.undo(); D.undo();
for (let n = 0; n < 10 && JSON.stringify(__cfg().pages.map(p => p.id)) !== JSON.stringify(ids); n++) D.undo();
return { top, afterTop, second, back: JSON.stringify(__cfg().pages.map(p => p.id)) === JSON.stringify(ids) };
'@
        $saved = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($script:PanelConfig))
        $r.top | Should -Not -BeNullOrEmpty
        # The moved page (p004) had real overrides in the file, so emptying them removes the
        # key - even though the page that was FIRST in the file (p001) has "overrides": {}.
        @($saved['pages'][3]['overrides'].Keys).Count | Should -BeGreaterThan 0
        @($saved['pages'][0]['overrides'].Keys).Count | Should -Be 0
        $r.afterTop | Should -BeNullOrEmpty
        # p001, now second, had "overrides": {} in the file: it is put back as it was.
        $r.second | Should -BeTrue
        $r.back | Should -BeTrue
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

Describe 'Browser link and picker: routes and rules without a browser' {
    BeforeEach { $script:State = New-TestState }

    It 'refuses with 409 and the reason when no browser is connected: <_>' -ForEach @(
        @('POST', '/api/browser/navigate', @{ url = 'https://example.com/' }),
        @('POST', '/api/pick/start', @{ mode = 'click' }),
        @('POST', '/api/action/test', @{ action = @{ type = 'click'; selector = '#x' } }),
        @('POST', '/api/page/from-current', @{}),
        @('POST', '/api/browser/zoom-off', @{})) {
        Mock Update-DesignerBrowser { }
        $script:State.Browser.Problem = Get-DesignerBrowserProblem -Code 'gone'
        $r = Invoke-TestRoute $_[0] $_[1] -Body $_[2] -State $script:State
        $r.Status | Should -Be 409
        $r.Data.code | Should -Be 'no-browser'
        $r.Data.error | Should -Be 'The audit browser is not connected.'
        $r.Data.detail | Should -Be 'The audit Edge window was closed.'
    }

    It 'opens only web addresses: <_>' -ForEach @('javascript:alert(1)', 'file:///C:/Windows/win.ini', 'edge://settings', '', 'http://', 'ftp://example.com/', 'about:blank') {
        $script:State.Browser.Connected = $true
        $r = Invoke-TestRoute POST '/api/browser/navigate' -Body @{ url = $_ } -State $script:State
        $r.Status | Should -Be 400
        $r.Data.code | Should -Be 'url'
    }

    It 'checks the pick mode and the action before anything else' {
        (Invoke-TestRoute POST '/api/pick/start' -Body @{ mode = 'area' } -State $script:State).Status | Should -Be 400
        (Invoke-TestRoute POST '/api/pick/start' -Body @{ mode = 'Click' } -State $script:State).Data.code | Should -Be 'mode'
        (Invoke-TestRoute POST '/api/action/test' -Body @{} -State $script:State).Data.code | Should -Be 'action'
        (Invoke-TestRoute POST '/api/action/test' -Body @{ action = @{ type = 'jump' } } -State $script:State).Status | Should -Be 400
        (Invoke-TestRoute POST '/api/action/test' -Body @{ action = @{ type = 'click'; selector = ' ' } } -State $script:State).Status | Should -Be 400
        foreach ($type in 'capture', 'pause') {
            $r = Invoke-TestRoute POST '/api/action/test' -Body @{ action = @{ type = $type } } -State $script:State
            $r.Status | Should -Be 200
            $r.Data.ok | Should -BeFalse
            $r.Data.message | Should -Match 'Test this page'
        }
    }

    It 'answers the pick routes while nothing is being picked, and 405 for wrong methods' {
        (Invoke-TestRoute GET '/api/pick' -State $script:State).Data.state | Should -Be 'idle'
        (Invoke-TestRoute POST '/api/pick/cancel' -State $script:State).Data.state | Should -Be 'idle'
        (Invoke-TestRoute GET '/api/browser/navigate' -State $script:State).Status | Should -Be 405
        (Invoke-TestRoute POST '/api/browser/current' -State $script:State).Status | Should -Be 405
        (Invoke-TestRoute GET '/api/pick/start' -State $script:State).Status | Should -Be 405
        (Invoke-TestRoute GET '/api/action/test' -State $script:State).Status | Should -Be 405
        (Invoke-TestRoute GET '/picker.js' -State $script:State).Status | Should -Be 404
    }

    It 'puts every new route behind the gate (token, Origin, JSON)' {
        foreach ($path in '/api/browser/connect', '/api/browser/navigate', '/api/browser/layout', '/api/browser/zoom-off', '/api/page/from-current', '/api/pick/start', '/api/pick/cancel', '/api/action/test') {
            $headers = New-GoodHeaders -State $script:State -Post
            $headers.Remove('X-Vouch-Token')
            (Test-DesignerRequest -Request (New-DesignerRequest -Method POST -Path $path -Headers $headers -BodyText '{}') -State $script:State).Status | Should -Be 403
            $headers = New-GoodHeaders -State $script:State -Post
            $headers.Remove('Origin')
            (Test-DesignerRequest -Request (New-DesignerRequest -Method POST -Path $path -Headers $headers -BodyText '{}') -State $script:State).Body | Should -Match 'no-origin'
            $headers = New-GoodHeaders -State $script:State -Post
            $headers['Content-Type'] = 'text/plain'
            (Test-DesignerRequest -Request (New-DesignerRequest -Method POST -Path $path -Headers $headers -BodyText '{}') -State $script:State).Status | Should -Be 415
            $headers = New-GoodHeaders -State $script:State -Post
            Test-DesignerRequest -Request (New-DesignerRequest -Method POST -Path $path -Headers $headers -BodyText '{}') -State $script:State | Should -BeNullOrEmpty
        }
        foreach ($path in '/api/browser/current', '/api/pick') {
            (Test-DesignerRequest -Request (New-DesignerRequest -Method GET -Path $path -Headers @{ Host = $script:State.HostHeader }) -State $script:State).Status | Should -Be 403
        }
    }

    It 'reports the browser in /api/state and turns the browser buttons on only when connected' {
        $r = Invoke-TestRoute GET '/api/state' -State $script:State
        $r.Data.capabilities.browser | Should -BeFalse
        $r.Data.browser.connected | Should -BeFalse
        $r.Data.pick.state | Should -Be 'idle'
        $script:State.Browser.Connected = $true
        $script:State.Browser.Title = 'Some page'
        Mock Get-DesignerBrowserSetting { [pscustomobject]@{ Port = 0; ProfileDir = ''; KeepOpen = $false } }
        $r = Invoke-TestRoute GET '/api/state' -State $script:State
        $r.Data.capabilities.browser | Should -BeTrue
        $r.Data.capabilities.pick | Should -BeTrue
        $r.Data.capabilities.test | Should -BeTrue
        $r.Data.capabilities.run | Should -BeFalse
        $r.Data.browser.title | Should -Be 'Some page'
        $r.Data.browser.settingsChanged | Should -BeFalse
    }

    It 'tells generated ids from stable ones: <Id> -> <Generated>' -ForEach @(
        @{ Id = 'save-settings'; Generated = $false }, @{ Id = 'tab-audit'; Generated = $false }, @{ Id = 'reports-a'; Generated = $false }
        @{ Id = 'item2'; Generated = $false }, @{ Id = 'main'; Generated = $false }, @{ Id = 'user_list_v2'; Generated = $false }
        @{ Id = 'ember4821'; Generated = $true }, @{ Id = 'row-123456'; Generated = $true }, @{ Id = '3f2a'; Generated = $true }
        @{ Id = 'a3f9c2d17b'; Generated = $true }, @{ Id = 'x-550e8400-e29b-41d4-a716-446655440000'; Generated = $true }
        @{ Id = ':r1:'; Generated = $true }, @{ Id = 'mui-12'; Generated = $true }, @{ Id = 'radix-7'; Generated = $true }
        @{ Id = 'k7Pq2xZ9a'; Generated = $true }, @{ Id = ''; Generated = $true }, @{ Id = ('a' * 70); Generated = $true }) {
        Test-DesignerGeneratedId -Id $Id | Should -Be $Generated
    }

    It 'plans the windows: Edge on the left, the panel on the right, full height' {
        $plan = Get-DesignerLayoutPlan -WorkingArea ([System.Drawing.Rectangle]::new(0, 0, 1920, 1040)) -PanelWidth 0 -DefaultWidth 480
        $plan.Panel | Should -Be ([System.Drawing.Rectangle]::new(1440, 0, 480, 1040))
        $plan.Edge | Should -Be ([System.Drawing.Rectangle]::new(0, 0, 1440, 1040))
        $plan = Get-DesignerLayoutPlan -WorkingArea ([System.Drawing.Rectangle]::new(-1920, 40, 1920, 1000)) -PanelWidth 600
        $plan.Panel | Should -Be ([System.Drawing.Rectangle]::new(-600, 40, 600, 1000))
        $plan.Edge.Right | Should -Be $plan.Panel.Left
        # Never more than half the screen, whatever width the panel had.
        (Get-DesignerLayoutPlan -WorkingArea ([System.Drawing.Rectangle]::new(0, 0, 640, 432)) -PanelWidth 900).Panel.Width | Should -Be 320
    }

    It 'leaves the windows alone, quickly, when there are none' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $layout = Set-DesignerLayout -State $script:State -Focus panel
        $watch.ElapsedMilliseconds | Should -BeLessThan 1000
        $layout.Ok | Should -BeFalse
        $layout.Message | Should -Match 'left as they are'
    }

    It 'names a page from the tab''s title' {
        ConvertTo-DesignerPageName -Title "  Audit`tLog -`n Settings  " -Url 'https://a.example/x' | Should -Be 'Audit Log - Settings'
        ConvertTo-DesignerPageName -Title '' -Url 'https://payroll.example.com/admin' | Should -Be 'payroll.example.com'
        $long = ConvertTo-DesignerPageName -Title (('word ' * 30).Trim()) -Url 'https://a.example/'
        $long.Length | Should -BeLessOrEqual 81
        $long | Should -BeLike "*$([char]0x2026)"
    }

    It 'explains a port that never opens in plain words, naming the RemoteDebuggingAllowed policy' {
        $p = Get-DesignerBrowserProblem -Code 'noport' -Port 9333 -ProfileDir 'C:\P\Audit'
        $p.message | Should -Match 'port 9333'
        ($p.causes -join ' ') | Should -Match 'RemoteDebuggingAllowed'
        ($p.causes -join ' ') | Should -Match 'C:\\P\\Audit'
        ($p.causes -join ' ') | Should -Match 'Another program may be using port 9333'
        (Get-DesignerBrowserProblem -Code 'policy').message | Should -Match 'RemoteDebuggingAllowed'
    }

    Context 'connecting (engine calls mocked)' {
        BeforeEach {
            $script:State.Browser.TypedPort = 9555
            $script:State.Browser.TypedProfileDir = 'C:\Throwaway\AuditProfile'
            Mock Assert-DesignerProfileSeparate { }
            Mock Find-EdgeExecutable { 'C:\Edge\msedge.exe' }
            Mock Get-EdgeDebugPolicy { $null }
            Mock Test-DesignerPortBusy { $false }
            Mock Start-EdgeDebug { throw 'should not start Edge' }
        }
        It 'says no Edge is listening when it may not start one' {
            Mock Get-DebugEndpointInfo { $null }
            $script:State.Browser.AllowLaunch = $false
            Connect-DesignerBrowser -State $script:State
            $script:State.Browser.Connected | Should -BeFalse
            $script:State.Browser.Problem['code'] | Should -Be 'notrunning'
            Should -Invoke Start-EdgeDebug -Times 0
        }
        It 'names the policy for certain when it forbids remote debugging, and starts nothing' {
            Mock Get-DebugEndpointInfo { $null }
            Mock Get-EdgeDebugPolicy { $false }
            Connect-DesignerBrowser -State $script:State
            $script:State.Browser.Problem['code'] | Should -Be 'policy'
            Should -Invoke Start-EdgeDebug -Times 0
        }
        It 'says another program has the port' {
            Mock Get-DebugEndpointInfo { $null }
            Mock Test-DesignerPortBusy { $true }
            Connect-DesignerBrowser -State $script:State
            $script:State.Browser.Problem['code'] | Should -Be 'portbusy'
            $script:State.Browser.Problem['message'] | Should -Match 'port 9555'
        }
        It 'tells Edge-already-open apart from a port that never opened' {
            Mock Get-DebugEndpointInfo { $null }
            Mock Start-EdgeDebug { throw 'Edge is already running with the audit profile (process 1) but without the DevTools port - typically ...' }
            Connect-DesignerBrowser -State $script:State
            $script:State.Browser.Problem['code'] | Should -Be 'profile-open'
            Mock Start-EdgeDebug { throw 'Edge did not open its DevTools endpoint on port 9555 within 15 seconds.' }
            Connect-DesignerBrowser -State $script:State
            $script:State.Browser.Problem['code'] | Should -Be 'noport'
            Should -Invoke Start-EdgeDebug -ParameterFilter { $Port -eq 9555 -and $ProfileDir -eq 'C:\Throwaway\AuditProfile' }
        }
        It 'refuses an audit profile that overlaps the panel''s, before touching Edge' {
            Mock Assert-DesignerProfileSeparate { throw 'The profiles overlap.' }
            Mock Get-DebugEndpointInfo { throw 'should not be reached' }
            Connect-DesignerBrowser -State $script:State
            $script:State.Browser.Problem['code'] | Should -Be 'profile'
            $script:State.Browser.Problem['message'] | Should -Be 'The profiles overlap.'
        }
        It 'closes at the end only an Edge it started, and not when it should be kept open' {
            Mock Stop-EdgeProcess { $script:Stopped = $script:LaunchedEdge }
            Mock Get-Process { [pscustomobject]@{ Id = 4242 } } -ParameterFilter { $Id -eq 4242 }
            Mock Get-DesignerBrowserSetting { [pscustomobject]@{ Port = 9555; ProfileDir = 'C:\Throwaway\AuditProfile'; KeepOpen = $script:Keep } }
            foreach ($case in @(@{ Launched = $true; Keep = $false; Closes = 1 }, @{ Launched = $true; Keep = $true; Closes = 0 }, @{ Launched = $false; Keep = $false; Closes = 0 })) {
                $script:Keep = $case.Keep
                $script:Stopped = $null
                $state = New-TestState
                $state.Browser.LaunchedByDesigner = $case.Launched
                $state.Browser.LaunchedPid = 4242
                Close-DesignerBrowser -State $state
                if ($case.Closes) { $script:Stopped | Should -BeTrue } else { $script:Stopped | Should -BeNullOrEmpty }
            }
            $script:LaunchedEdge | Should -BeFalse
        }
    }

    It 'puts mode, token and words into the picker only as JavaScript literals' {
        $script = Get-DesignerPickerScript -State $script:State -Mode click -Token 'x"); alert(1); ("'
        $script | Should -Match ([regex]::Escape('token: "x\"); alert(1); (\""'))
        $script | Should -Match ([regex]::Escape('function vouchDocs()'))
        $script.TrimEnd() | Should -BeLike '*})()'
    }

    It 'gives up on a request body that stalls, and answers 408' {
        $pipe = [System.IO.Pipes.AnonymousPipeServerStream]::new([System.IO.Pipes.PipeDirection]::In)
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $body = Read-DesignerRequestBody -Stream $pipe -Limit 1MB -TimeoutMs 400
            $watch.ElapsedMilliseconds | Should -BeLessThan 3000
            $body.TimedOut | Should -BeTrue
            $script:State.BodyTimeoutMs = 300
            $response = Invoke-DesignerExchange -Method POST -Path '/api/config/validate' -Headers (New-GoodHeaders -State $script:State -Post) -ContentLength 100 -BodyStream $pipe -State $script:State
            $response.Status | Should -Be 408
            ($response.Body | ConvertFrom-Json).code | Should -Be 'timeout'
        }
        finally { $pipe.Dispose() }
        $ok = Read-DesignerRequestBody -Stream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes('{"a":1}'))) -Limit 1MB
        $ok.Text | Should -Be '{"a":1}'
        $ok.TimedOut | Should -BeFalse
    }
}

Describe 'Browser link and picker in headless Edge (functions called directly)' -Tag 'Integration' {
    BeforeAll {
        $script:Web1 = Get-FreeTcpPort
        $script:Web2 = Get-FreeTcpPort
        $script:PickServer = Start-TestServer -Port $script:Web1, $script:Web2
        $script:Base = "http://localhost:$($script:Web1)"
        $script:PickCdp = Get-FreeTcpPort
        $script:PickProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-audit-$($script:PickCdp)"
        $script:PickEdge = Start-HeadlessEdge -Port $script:PickCdp -ProfileDir $script:PickProfile
        Close-CdpSocket
        $script:B = New-TestState
        $script:B.Browser.TypedPort = $script:PickCdp
        $script:B.Browser.TypedProfileDir = $script:PickProfile
        $script:B.Browser.AllowLaunch = $false
        Connect-DesignerBrowser -State $script:B
        $script:Replay = [pscustomobject]@{ NavigationTimeoutSec = 5; SettleSeconds = 0 }

        function Open-TestPage([string]$Path) {
            Set-NavigationMarker
            [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = "$($script:Base)$Path" })
            [void](Wait-PageReady -TimeoutSec 15)
            # Frames finish a moment later.
            [void](Invoke-CdpEval -TimeoutSec 10 -Expression "new Promise(r => { const ok = () => Array.from(document.querySelectorAll('iframe')).every(f => { try { return !f.contentDocument || f.contentDocument.readyState === 'complete'; } catch (e) { return true; } }); const t = () => ok() ? r(true) : setTimeout(t, 50); t(); })")
        }
        function Get-TestPoint([string]$Element) {
            # The centre of an element in the top window's coordinates (through same-site frames).
            return Invoke-CdpEval -Expression @"
(function () {
  var el = ($Element); el.scrollIntoView({ block: 'nearest' });
  var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2, w = el.ownerDocument.defaultView;
  while (w.frameElement) { var f = w.frameElement.getBoundingClientRect(); x += f.left + w.frameElement.clientLeft; y += f.top + w.frameElement.clientTop; w = w.parent; }
  return { x: x, y: y };
})()
"@
        }
        function Send-TestClick([object]$Point) {
            foreach ($type in 'mouseMoved', 'mousePressed', 'mouseReleased') {
                $params = @{ type = $type; x = [double]$Point.x; y = [double]$Point.y }
                if ($type -ne 'mouseMoved') { $params.button = 'left'; $params.clickCount = 1 }
                [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params $params)
            }
        }
        function Wait-TestPick {
            $deadline = (Get-Date).AddSeconds(10)
            do { Start-Sleep -Milliseconds 100; $r = Get-ElementPickResult -State $script:B } while ($r.state -eq 'picking' -and (Get-Date) -lt $deadline)
            return $r
        }
        function Invoke-TestPick([string]$Mode, [string]$Element) {
            $point = Get-TestPoint $Element
            [void](Start-ElementPick -State $script:B -Mode $Mode)
            $script:During = Invoke-CdpEval -Expression "({ ui: document.querySelectorAll('vouch-picker-ui').length, ns: typeof window.__vouchPicker })"
            Send-TestClick $point
            return Wait-TestPick
        }
        function Get-PageTrace {
            # Everything a pick could leave behind: globals, the DOM of the page and its
            # same-site frames, and the event listeners on their windows and documents.
            $dom = Invoke-CdpEval -Expression @'
(function () {
  function docs(d) { var out = [d]; d.querySelectorAll('iframe,frame').forEach(function (f) { try { if (f.contentDocument) { out = out.concat(docs(f.contentDocument)); } } catch (e) { } }); return out; }
  return JSON.stringify({ globals: Object.getOwnPropertyNames(window).sort(), dom: docs(document).map(function (d) { return d.documentElement.outerHTML; }) });
})()
'@
            # DevTools does not list listeners on a frame's window whose handler belongs to the
            # top page (the picker's), so frames are checked by behaviour instead
            # (Assert-FramesFree): a click inside the frame must reach the site again.
            $listeners = [System.Collections.Generic.List[string]]::new()
            $targets = [ordered]@{ top = 'window'; document = 'document' }
            foreach ($name in $targets.Keys) {
                $answer = Send-CdpCommand -Method 'Runtime.evaluate' -Params @{ expression = $targets[$name]; returnByValue = $false }
                if (-not $answer.result.PSObject.Properties['objectId']) { continue }
                $found = Send-CdpCommand -Method 'DOMDebugger.getEventListeners' -Params @{ objectId = $answer.result.objectId }
                foreach ($l in @($found.listeners)) { $listeners.Add("${name}:$($l.type):$($l.useCapture)") }
                [void](Send-CdpCommand -Method 'Runtime.releaseObject' -Params @{ objectId = $answer.result.objectId })
            }
            return $dom + '|' + (($listeners | Sort-Object) -join ';')
        }
        function Assert-SiteUntouched([string]$Title = 'Pick me') {
            Invoke-CdpEval -Expression 'JSON.stringify(window.__hits || [])' | Should -Be '[]'
            Invoke-CdpEval -Expression 'window.__downs || 0' | Should -Be 0
            Invoke-CdpEval -Expression 'document.title' | Should -Be $Title
        }
        function Assert-FramesFree {
            # After a pick, a click inside the same-site frame reaches the site's handler: the
            # picker's capture listeners on the frame's window are gone.
            Invoke-CdpEval -Expression "document.getElementById('sameframe').contentDocument.getElementById('framebtn').click(); JSON.stringify(window.__hits)" | Should -Be '["frame"]'
        }
        function Invoke-TestReplay([System.Collections.IDictionary]$Action, [string]$Page) {
            Open-TestPage $Page
            $entry = Invoke-PageAction -Action $Action -Settings $script:Replay
            $entry.Ok | Should -BeTrue -Because "replaying $($Action | ConvertTo-Json -Compress) must work: $($entry.Message)"
        }
        function ConvertTo-TestAction([object]$Action) {
            if ($Action -is [System.Collections.IDictionary]) { return $Action }
            $copy = [ordered]@{}
            foreach ($p in $Action.PSObject.Properties) { $copy[$p.Name] = $p.Value }
            return $copy
        }
    }
    AfterAll {
        Close-CdpSocket
        Stop-HeadlessEdge -ProfileDir $script:PickProfile
        if ($null -ne $script:PickServer) { Stop-Process -Id $script:PickServer.Id -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryWithRetry -Path $script:PickProfile
    }

    It 'connects to the tab in front and reports it' {
        $script:B.Browser.Connected | Should -BeTrue
        $script:B.Browser.LaunchedByDesigner | Should -BeFalse
        Open-TestPage '/ok'
        $r = Invoke-TestRoute GET '/api/browser/current' -State $script:B
        $r.Data.connected | Should -BeTrue
        $r.Data.url | Should -Be "$($script:Base)/ok"
        $r.Data.title | Should -Be 'OK page'
        $r.Data.tabId | Should -Be $script:B.Browser.TabId
        @($r.Data.tabs | Where-Object current).Count | Should -Be 1
        $from = Invoke-TestRoute POST '/api/page/from-current' -State $script:B
        $from.Data.name | Should -Be 'OK page'
        $from.Data.url | Should -Be "$($script:Base)/ok"
    }

    It 'click pick: <Case>' -ForEach @(
        @{ Case = 'the second of two links with the same words (never offered as words)'; El = "document.querySelectorAll('#navrow a')[1]"; Hit = 'reports-2'; First = 'path'; Values = @('#navrow > a:nth-of-type(2)'); NoKind = 'text' }
        @{ Case = 'the first of them (the words reach it)'; El = "document.getElementById('reports-a')"; Hit = 'reports-1'; First = 'text'; Values = @('Reports', '#reports-a') }
        @{ Case = 'an icon inside a button (climbs to the button)'; El = "document.getElementById('favicon')"; Hit = 'fav'; First = 'text'; Values = @("$([char]0x2605) Favourite", '#fav'); Climbed = 'span' }
        @{ Case = 'a button with a test id'; El = "document.querySelector('[data-testid=save-settings]')"; Hit = 'save'; First = 'text'; Values = @('Save settings', '[data-testid="save-settings"]') }
        @{ Case = 'a button with a generated-looking id (id not offered)'; El = "document.getElementById('ember4821')"; Hit = 'generated'; First = 'text'; Values = @('Archive now'); NotValue = '#ember4821' }
        @{ Case = 'a button with only an aria-label (an svg inside)'; El = "document.getElementById('xsvg')"; Hit = 'close'; First = 'attribute'; Values = @('button[aria-label="Close dialog"]'); NoKind = 'text' }
        @{ Case = 'a deep element only a layout path reaches'; El = "document.querySelector('em')"; Hit = 'deep'; First = 'path'; Values = @('div > div > div > div > em'); NoKind = 'text' }
        @{ Case = 'a button in a frame from the same site'; El = "document.getElementById('sameframe').contentDocument.getElementById('framebtn')"; Hit = 'frame'; First = 'text'; Values = @('Frame action', '#framebtn') }
    ) {
        $page = "/pickme?x=$($script:Web2)"
        Open-TestPage $page
        $before = Get-PageTrace
        $r = Invoke-TestPick 'click' $El
        $script:During.ui | Should -Be 1
        $script:During.ns | Should -Be 'object'
        $r.state | Should -Be 'done' -Because $r['message']
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
        Assert-FramesFree
        $candidates = @($r.result.candidates)
        $candidates.Count | Should -BeGreaterThan 0
        $candidates.Count | Should -BeLessOrEqual 3
        $candidates[0].kind | Should -Be $First
        foreach ($value in $Values) { @($candidates | ForEach-Object { $_.value }) | Should -Contain $value }
        if ($NoKind) { @($candidates | Where-Object { $_.kind -eq $NoKind }).Count | Should -Be 0 }
        if ($NotValue) { @($candidates | ForEach-Object { $_.value }) | Should -Not -Contain $NotValue }
        if ($Climbed) { $r.result.element.climbedFrom | Should -Be $Climbed; $r.result.element.climbedNote | Should -Match 'records the whole button' }
        foreach ($c in $candidates) {
            $c.description | Should -Not -BeNullOrEmpty
            $c.robustness | Should -BeIn 'best', 'good', 'fair', 'fragile'
            Invoke-TestReplay -Action (ConvertTo-TestAction $c.action) -Page $page
            Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be "[`"$Hit`"]" -Because "$($c.kind) '$($c.value)' must click the picked element"
        }
    }

    It 'says plainly that <Case> cannot be recorded, and the site never sees the click' -ForEach @(
        @{ Case = 'a frame from another site'; El = "document.getElementById('otherframe')"; Code = 'crossorigin'; Words = 'frame from another site' }
        @{ Case = 'a button in shadow DOM'; El = "document.getElementById('shadowhost')"; Code = 'shadow'; Words = 'shadow DOM' }
    ) {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $before = Get-PageTrace
        $r = Invoke-TestPick 'click' $El
        $r.state | Should -Be 'error'
        $r.code | Should -Be $Code
        $r.message | Should -Match 'cannot be recorded'
        $r.message | Should -Match $Words
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
        Assert-FramesFree
    }

    It 'scroll pick: <Case>' -ForEach @(
        @{ Case = 'a scrolling panel'; Page = '/pickme'; El = "document.querySelector('#leftpanel div:nth-child(3)')"; Kind = 'element'; First = '#leftpanel'; Probe = "document.getElementById('leftpanel').scrollTop" }
        @{ Case = 'the other scrolling panel'; Page = '/pickme'; El = "document.querySelector('#rightpanel div:nth-child(2)')"; Kind = 'element'; First = '#rightpanel'; Probe = "document.getElementById('rightpanel').scrollTop" }
        @{ Case = 'a frame whose page scrolls'; Page = '/pickme'; El = "document.getElementById('sameframe').contentDocument.querySelector('div')"; Kind = 'frame'; First = '#sameframe'; Probe = "document.getElementById('sameframe').contentWindow.scrollY" }
        @{ Case = 'an overflow clip box (the page scrolls instead)'; Page = '/pickme'; El = "document.querySelector('#clipbox div')"; Kind = 'window'; First = ''; Probe = 'window.scrollY' }
        @{ Case = 'the tall page itself'; Page = '/pickme'; El = "document.getElementById('spacer')"; Kind = 'window'; First = ''; Probe = 'window.scrollY' }
        @{ Case = 'the inner panel of /innerscroll'; Page = '/innerscroll'; El = "document.querySelector('#main .row:nth-child(2)')"; Kind = 'element'; First = '#main'; Probe = "document.getElementById('main').scrollTop" }
        @{ Case = 'the right region of /tworegions'; Page = '/tworegions'; El = "document.querySelector('#right div:nth-child(2)')"; Kind = 'element'; First = '#right'; Probe = "document.getElementById('right').scrollTop" }
        @{ Case = 'the frame of /framepage'; Page = '/framepage'; El = "document.getElementById('content').contentDocument.querySelector('div')"; Kind = 'frame'; First = '#content'; Probe = "document.getElementById('content').contentWindow.scrollY" }
    ) {
        $path = if ($Page -eq '/pickme') { "/pickme?x=$($script:Web2)" } else { $Page }
        Open-TestPage $path
        $before = Get-PageTrace
        $r = Invoke-TestPick 'scroll' $El
        $r.state | Should -Be 'done' -Because $r['message']
        (Get-PageTrace) | Should -BeExactly $before
        if ($Page -eq '/pickme') { Assert-FramesFree }
        $r.result.element.kind | Should -Be $Kind
        $candidates = @($r.result.candidates)
        if ($Kind -eq 'window') {
            $candidates.Count | Should -Be 1
            $candidates[0].kind | Should -Be 'page'
            $candidates[0].scroll.mode | Should -Be 'page'
            $candidates[0].description | Should -Match 'whole page'
        }
        else {
            $candidates[0].value | Should -Be $First
            foreach ($c in $candidates) {
                $c.scroll.mode | Should -Be 'area'
                $c.scroll.selector | Should -Be $c.value
            }
        }
        foreach ($c in $candidates) {
            # The capture finds exactly this area to scroll, with no fallback, and scrolls it.
            Open-TestPage $path
            $mode = if ($c.scroll.mode -eq 'page') { 'page' } else { 'area' }
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript -Mode $mode -Selector ([string]$c.value))
            $target.fallback | Should -Be ''
            $target.kind | Should -Be $Kind
            [void](Invoke-CdpEval -Expression 'window.__vouchTarget.to(100)')
            Invoke-CdpEval -Expression $Probe | Should -Be 100 -Because "$($c.value) must scroll the picked area"
        }
    }

    It 'wait-for pick offers selectors the engine''s wait finds, never words' {
        $page = "/pickme?x=$($script:Web2)"
        Open-TestPage $page
        $before = Get-PageTrace
        $r = Invoke-TestPick 'waitFor' "document.querySelector('[data-testid=save-settings]')"
        $r.state | Should -Be 'done'
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
        Assert-FramesFree
        $candidates = @($r.result.candidates)
        $candidates[0].selector | Should -Be '[data-testid="save-settings"]'
        @($candidates | Where-Object { $_.kind -eq 'text' }).Count | Should -Be 0
        foreach ($c in $candidates) {
            Open-TestPage $page
            (Invoke-PageAction -Action ([ordered]@{ type = 'waitFor'; selector = $c.selector; timeoutSec = 2 }) -Settings $script:Replay).Ok | Should -BeTrue
            (Invoke-CdpEval -Expression (Get-ClickSelectorScript -Selector $c.selector -FindOnly)).text | Should -Be 'Save settings'
        }
    }

    It 'works on the existing fixtures: a tab on /tabs and a button in the frame of /framepage' {
        Open-TestPage '/tabs'
        $r = Invoke-TestPick 'click' "document.getElementById('t-audit')"
        $r.state | Should -Be 'done'
        Invoke-CdpEval -Expression 'document.title' | Should -Be 'Tabs'
        $r.result.candidates[0].action.type | Should -Be 'clickText'
        $r.result.candidates[0].action.text | Should -Be 'Audit Log'
        $r.result.candidates[0].description | Should -Be "the $([char]0x2018)Audit Log$([char]0x2019) tab"
        foreach ($c in $r.result.candidates) {
            Open-TestPage '/tabs'
            (Invoke-PageAction -Action (ConvertTo-TestAction $c.action) -Settings $script:Replay).Ok | Should -BeTrue
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'Audit Log'
        }
        Open-TestPage '/framepage'
        $r = Invoke-TestPick 'click' "document.getElementById('content').contentDocument.getElementById('frame-btn')"
        $r.state | Should -Be 'done'
        $r.result.element.frame | Should -Match 'framecontent'
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#frame-btn'
        foreach ($c in $r.result.candidates) {
            Open-TestPage '/framepage'
            (Invoke-PageAction -Action (ConvertTo-TestAction $c.action) -Settings $script:Replay).Ok | Should -BeTrue
            Invoke-CdpEval -Expression 'document.title' | Should -Be 'FRAME CLICKED'
        }
    }

    It 'cancels with Esc in the page and with Cancel in the panel, leaving nothing behind' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $before = Get-PageTrace
        [void](Start-ElementPick -State $script:B -Mode click)
        foreach ($type in 'keyDown', 'keyUp') {
            [void](Send-CdpCommand -Method 'Input.dispatchKeyEvent' -Params @{ type = $type; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 })
        }
        $r = Wait-TestPick
        $r.state | Should -Be 'cancelled'
        $r.message | Should -Match 'Esc'
        Invoke-CdpEval -Expression 'window.__keys' | Should -Be 0
        (Get-PageTrace) | Should -BeExactly $before
        [void](Start-ElementPick -State $script:B -Mode scroll)
        # Control: while picking, a click inside the frame is swallowed by the picker.
        Invoke-CdpEval -Expression "document.getElementById('sameframe').contentDocument.getElementById('framebtn').click(); JSON.stringify(window.__hits)" | Should -Be '[]'
        (Invoke-TestRoute POST '/api/pick/cancel' -State $script:B).Data.state | Should -Be 'cancelled'
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
        Assert-FramesFree
    }

    It 'keeps picking after the page reloads, and the loop is never held up' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        [void](Invoke-CdpEval -Expression 'setTimeout(() => location.reload(), 10); true')
        Start-Sleep -Milliseconds 800
        $notice = ''
        $deadline = (Get-Date).AddSeconds(5)
        do {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Get-ElementPickResult -State $script:B
            $watch.ElapsedMilliseconds | Should -BeLessThan 1500
            $r.state | Should -Be 'picking'
            if ($r['notice']) { $notice = $r['notice'] }
            Start-Sleep -Milliseconds 250
        } while (-not $notice -and (Get-Date) -lt $deadline)
        $notice | Should -Match 'page changed'
        Invoke-CdpEval -Expression 'typeof window.__vouchPicker' | Should -Be 'object'
        Send-TestClick (Get-TestPoint "document.querySelector('[data-testid=save-settings]')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done'
        Assert-SiteUntouched
    }

    It 'tests one action at a time through the engine: <Case>' -ForEach @(
        @{ Case = 'a click by selector'; Page = '/tabs'; Action = @{ type = 'click'; selector = '#t-logs' }; Ok = $true; Title = 'Logs'; Navigated = $false; Words = 'stayed' }
        @{ Case = 'a click by words'; Page = '/tabs'; Action = @{ type = 'clickText'; text = 'Audit Log' }; Ok = $true; Title = 'Audit Log'; Navigated = $false; Words = 'Clicked' }
        @{ Case = 'a click that opens another page'; Page = 'LINKS'; Action = @{ type = 'click'; selector = '#go' }; Ok = $true; Title = 'OK page'; Navigated = $true; Words = '/ok' }
        @{ Case = 'a click on nothing'; Page = '/tabs'; Action = @{ type = 'click'; selector = '#nope' }; Ok = $false; Title = 'Tabs'; Navigated = $false; Words = 'No element matched' }
        @{ Case = 'a wait'; Page = '/tabs'; Action = @{ type = 'wait'; seconds = 0.2 }; Ok = $true; Title = 'Tabs'; Navigated = $false; Words = 'Waited 0.2' }
        @{ Case = 'a wait-for that finds it'; Page = '/tabs'; Action = @{ type = 'waitFor'; selector = '#t-general' }; Ok = $true; Title = 'Tabs'; Navigated = $false; Words = 'visible' }
        @{ Case = 'a wait-for that does not'; Page = '/tabs'; Action = @{ type = 'waitFor'; selector = '#nope'; timeoutSec = 1 }; Ok = $false; Title = 'Tabs'; Navigated = $false; Words = 'No visible element' }
    ) {
        $path = if ($Page -eq 'LINKS') { "/links?to=$([uri]::EscapeDataString("$($script:Base)/ok"))" } else { $Page }
        Open-TestPage $path
        $r = Invoke-TestRoute POST '/api/action/test' -Body @{ action = $Action; config = (Get-DefaultVouchConfig); pageIndex = -1 } -State $script:B
        $r.Status | Should -Be 200
        $r.Data.ok | Should -Be $Ok
        $r.Data.navigated | Should -Be $Navigated
        $r.Data.message | Should -Match ([regex]::Escape($Words))
        Invoke-CdpEval -Expression 'document.title' | Should -Be $Title
    }

    It 'opens a page with Go at the zoom the run uses, and takes the zoom off again' {
        $config = Get-DefaultVouchConfig
        $config['pages'] = [System.Collections.Generic.List[object]]@(
            [ordered]@{ id = 'p001'; name = 'Zoomed'; url = "$($script:Base)/ok"; overrides = [ordered]@{ zoomPercent = 50 } },
            [ordered]@{ id = 'p002'; name = 'Plain'; url = "$($script:Base)/tabs" })
        Open-TestPage '/ok'
        $base = [int](Invoke-CdpEval -Expression 'window.innerWidth')
        $r = Invoke-TestRoute POST '/api/browser/navigate' -Body @{ url = "$($script:Base)/tabs"; config = $config; pageIndex = 0 } -State $script:B
        $r.Status | Should -Be 200
        $r.Data.status | Should -Be 'loaded'
        $r.Data.title | Should -Be 'Tabs'
        $r.Data.zoom.percent | Should -Be 50
        $r.Data.zoom.page | Should -Be 'Zoomed'
        [int](Invoke-CdpEval -Expression 'window.innerWidth') | Should -Be ($base * 2)
        (Invoke-TestRoute GET '/api/state' -State $script:B).Data.browser.zoom.percent | Should -Be 50
        $r = Invoke-TestRoute POST '/api/browser/navigate' -Body @{ url = "$($script:Base)/ok"; config = $config; pageIndex = 1 } -State $script:B
        $r.Data.zoom.percent | Should -Be 100
        [int](Invoke-CdpEval -Expression 'window.innerWidth') | Should -Be $base
        [void](Invoke-TestRoute POST '/api/browser/navigate' -Body @{ url = "$($script:Base)/ok"; config = $config; pageIndex = 0 } -State $script:B)
        [int](Invoke-CdpEval -Expression 'window.innerWidth') | Should -Be ($base * 2)
        (Invoke-TestRoute POST '/api/browser/zoom-off' -State $script:B).Data.zoom.percent | Should -Be 100
        [int](Invoke-CdpEval -Expression 'window.innerWidth') | Should -Be $base
        $script:PageZoomPercent | Should -Be 100
    }

    It 'follows the tab in front, and never attaches to Edge''s own pages or to the panel' {
        Open-TestPage '/ok'
        $first = $script:B.Browser.TabId
        $second = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($script:PickCdp)/json/new?$($script:Base)/tabs" -NoProxy
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$($second.id)" -NoProxy)
        Start-Sleep -Milliseconds 500
        Update-DesignerBrowser -State $script:B -Force
        $script:B.Browser.TabId | Should -Be $second.id
        $script:B.Browser.Title | Should -Be 'Tabs'
        foreach ($url in 'edge://version', "http://localhost:$($script:B.Port)/") {
            $other = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($script:PickCdp)/json/new?$url" -NoProxy
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$($other.id)" -NoProxy)
            Start-Sleep -Milliseconds 500
            Update-DesignerBrowser -State $script:B -Force
            $script:B.Browser.TabId | Should -Be $second.id -Because "$url must be ignored"
            @($script:B.Browser.Tabs | ForEach-Object { $_.id }) | Should -Not -Contain $other.id
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/close/$($other.id)" -NoProxy)
        }
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$first" -NoProxy)
        Start-Sleep -Milliseconds 500
        Update-DesignerBrowser -State $script:B -Force
        $script:B.Browser.TabId | Should -Be $first
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/close/$($second.id)" -NoProxy)
    }

    It 'ends a pick plainly when its tab is closed, and moves to the tab that is left' {
        $extra = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($script:PickCdp)/json/new?$($script:Base)/ok" -NoProxy
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$($script:B.Browser.TabId)" -NoProxy)
        Start-Sleep -Milliseconds 300
        Update-DesignerBrowser -State $script:B -Force
        $picked = $script:B.Browser.TabId
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/close/$picked" -NoProxy)
        $r = Wait-TestPick
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'tab'
        $r.message | Should -Match 'was closed'
        Update-DesignerBrowser -State $script:B -Force
        $script:B.Browser.Connected | Should -BeTrue
        $script:B.Browser.TabId | Should -Be $extra.id
    }

    It 'says when the browser has gone, and Retry connects again' {
        Stop-HeadlessEdge -ProfileDir $script:PickProfile
        Start-Sleep -Milliseconds 800
        Update-DesignerBrowser -State $script:B -Force
        $script:B.Browser.Connected | Should -BeFalse
        $state = (Invoke-TestRoute GET '/api/state' -State $script:B).Data
        $state.capabilities.pick | Should -BeFalse
        $state.browser.problem.code | Should -Be 'gone'
        $state.browser.message | Should -Be 'The audit Edge window was closed.'
        (Invoke-TestRoute POST '/api/pick/start' -Body @{ mode = 'click' } -State $script:B).Status | Should -Be 409
        $script:PickEdge = Start-HeadlessEdge -Port $script:PickCdp -ProfileDir $script:PickProfile
        $r = Invoke-TestRoute POST '/api/browser/connect' -State $script:B
        $r.Data.connected | Should -BeTrue
        $r.Data.problem | Should -BeNullOrEmpty
        Close-DesignerBrowser -State $script:B
        $script:B.Browser.Connected | Should -BeFalse
        # A reused Edge is never closed by the Designer.
        Get-DebugEndpointInfo -Port $script:PickCdp | Should -Not -BeNullOrEmpty
    }
}

Describe 'The panel with an audit browser (two headless Edges, real server)' -Tag 'Integration' {
    BeforeAll {
        $script:W1 = Get-FreeTcpPort
        $script:WebBase = "http://localhost:$($script:W1)"
        $script:UiServer = Start-TestServer -Port $script:W1
        $script:AuditCdp = Get-FreeTcpPort
        $script:AuditProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-ui-audit-$($script:AuditCdp)"
        [void](Start-HeadlessEdge -Port $script:AuditCdp -ProfileDir $script:AuditProfile)
        $script:Sockets = @{}
        $script:CurrentCdp = ''
        function Use-Cdp([string]$Name) {
            # The test drives two browsers; the engine keeps one socket, so swap them.
            if ($script:CurrentCdp) { $script:Sockets[$script:CurrentCdp] = @{ Socket = $script:CdpSocket; Url = $script:CdpWebSocketUrl; Id = $script:CdpMessageId } }
            $saved = $script:Sockets[$Name]
            $script:CdpSocket = $saved.Socket; $script:CdpWebSocketUrl = $saved.Url; $script:CdpMessageId = $saved.Id
            $script:CurrentCdp = $Name
        }
        function Connect-TestTab([string]$Name, [int]$Port) {
            if ($script:CurrentCdp) { Use-Cdp $script:CurrentCdp; $script:CdpSocket = $null }
            $target = Get-CdpPageTarget -Port $Port -WaitSeconds 5 -TabId ''
            Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
            $script:CurrentCdp = $Name
            $script:Sockets[$Name] = @{ Socket = $script:CdpSocket; Url = $script:CdpWebSocketUrl; Id = $script:CdpMessageId }
        }
        $script:CdpPort = 0
        $script:CurrentCdp = ''
        $script:CdpSocket = $null
        Connect-TestTab -Name 'audit' -Port $script:AuditCdp
        Set-NavigationMarker
        [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = "$($script:WebBase)/tabs" })
        [void](Wait-PageReady -TimeoutSec 15)

        $script:UiConfig = Copy-Sample 'ui.json'
        $script:Ui = Start-DesignerTestServer -ConfigPath $script:UiConfig -Name 'ui' -AuditPort $script:AuditCdp -AuditProfile $script:AuditProfile
        $script:UiPanelCdp = Get-FreeTcpPort
        $script:UiPanelProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-ui-panel-$($script:UiPanelCdp)"
        [void](Start-HeadlessEdge -Port $script:UiPanelCdp -ProfileDir $script:UiPanelProfile)
        Connect-TestTab -Name 'panel' -Port $script:UiPanelCdp
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
        [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $script:Ui.Url })
        [void](Wait-PageReady -TimeoutSec 15)
        [void](Invoke-CdpEval -Expression 'window.VouchDesigner.ready.then(() => true)' -TimeoutSec 20)
        function Invoke-UiPanel([string]$Script) {
            Use-Cdp 'panel'
            $json = Invoke-CdpEval -TimeoutSec 40 -Expression "(async () => { const D = window.VouchDesigner; const S = D.S; const until = async (f, ms) => { const end = Date.now() + (ms || 10000); while (Date.now() < end) { const v = f(); if (v) return v; await new Promise(r => setTimeout(r, 100)); } return null; }; const btnByKey = k => Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === k); const r = await (async () => { $Script })(); return JSON.stringify(r === undefined ? null : r); })()"
            if ($null -eq $json) { return $null }
            return $json | ConvertFrom-Json -Depth 64
        }
        function Invoke-Audit([string]$Expression) { Use-Cdp 'audit'; try { return Invoke-CdpEval -Expression $Expression } finally { Use-Cdp 'panel' } }
        function Send-AuditClick([string]$Element) {
            Use-Cdp 'audit'
            try {
                $p = Invoke-CdpEval -Expression "(function () { var r = ($Element).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()"
                foreach ($type in 'mouseMoved', 'mousePressed', 'mouseReleased') {
                    $params = @{ type = $type; x = [double]$p.x; y = [double]$p.y }
                    if ($type -ne 'mouseMoved') { $params.button = 'left'; $params.clickCount = 1 }
                    [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params $params)
                }
            }
            finally { Use-Cdp 'panel' }
        }
    }
    AfterAll {
        foreach ($name in @($script:Sockets.Keys)) { Use-Cdp $name; Close-CdpSocket }
        $script:CurrentCdp = ''
        if ($null -ne $script:Ui) { Stop-Process -Id $script:Ui.Process.Id -Force -ErrorAction SilentlyContinue }
        Stop-HeadlessEdge -ProfileDir $script:UiPanelProfile
        Stop-HeadlessEdge -ProfileDir $script:AuditProfile
        if ($null -ne $script:UiServer) { Stop-Process -Id $script:UiServer.Id -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryWithRetry -Path $script:UiPanelProfile
        Remove-DirectoryWithRetry -Path $script:AuditProfile
    }

    It 'shows the connected browser with the page in front, and turns the browser buttons on' {
        $r = Invoke-UiPanel @'
await until(() => S.browser.connected && S.capabilities.pick, 15000);
D.setTab('pages');
const strip = document.querySelector('#browser-strip');
return { connected: S.browser.connected, on: strip.classList.contains('is-on'), text: strip.textContent,
  tidy: !!btnByKey('bs-tidy'), pickDisabled: btnByKey('pick-click').getAttribute('aria-disabled') };
'@
        $r.connected | Should -BeTrue
        $r.on | Should -BeTrue
        $r.text | Should -Match 'Browser connected'
        $r.text | Should -Match 'Tabs'
        $r.text | Should -Match ([regex]::Escape("$($script:WebBase)/tabs"))
        $r.tidy | Should -BeTrue
        $r.pickDisabled | Should -BeNullOrEmpty
    }

    It 'adds the page in front as a new page, named after its title' {
        $r = Invoke-UiPanel @'
const before = S.config.pages.length;
await D.addPageFromCurrentTab();
const p = S.config.pages[S.config.pages.length - 1];
return { added: S.config.pages.length - before, name: p.name, url: p.url, selected: S.page === S.config.pages.length - 1 };
'@
        $r.added | Should -Be 1
        $r.name | Should -Be 'Tabs'
        $r.url | Should -Be "$($script:WebBase)/tabs"
        $r.selected | Should -BeTrue
    }

    It 'opens a page with Go, previews its zoom, and shows it at 100% again on request' {
        $width = Invoke-Audit 'window.innerWidth'
        $r = Invoke-UiPanel @"
const n = S.config.pages.length - 1;
S.config.pages[n].url = '$($script:WebBase)/ok';
S.config.pages[n].overrides = { zoomPercent: 50 };
await D.goToUrl(n);
await until(() => S.browser.zoom && S.browser.zoom.percent === 50, 6000);
const zoomText = document.querySelector('#browser-strip').textContent;
btnByKey('bs-zoomoff').click();
await until(() => S.browser.zoom.percent === 100, 6000);
const after = document.querySelector('#browser-strip').textContent;
delete S.config.pages[n].overrides;
S.config.pages[n].url = '$($script:WebBase)/tabs';
await D.goToUrl(n);
return { zoomText, after };
"@
        $r.zoomText | Should -Match 'Zoom preview'
        $r.zoomText | Should -Match '50%'
        $r.after | Should -Not -Match 'Zoom preview'
        Invoke-Audit 'location.pathname' | Should -Be '/tabs'
        Invoke-Audit 'window.innerWidth' | Should -Be $width
    }

    It 'records a click by pointing at it: from the panel button to a verified action row' {
        Invoke-UiPanel @'
D.setTab('pages'); D.selectPage(S.config.pages.length - 1);
window.__pick = null;
btnByKey('pick-click').click();
return await until(() => document.querySelector('#picking').open, 8000);
'@ | Should -BeTrue
        # Esc in the panel (a closed dialog) does not end the wait.
        Invoke-UiPanel "document.querySelector('#picking').close(); await new Promise(r => setTimeout(r, 50)); return document.querySelector('#picking').open;" | Should -BeTrue
        Start-Sleep -Milliseconds 300
        Send-AuditClick "document.getElementById('t-logs')"
        $r = Invoke-UiPanel @'
const open = await until(() => document.querySelector('#modal').open && document.querySelector('#modal-title').textContent === 'Record this?', 10000);
const labels = Array.from(document.querySelectorAll('#modal-body .cand-row label')).map(l => l.textContent);
const values = Array.from(document.querySelectorAll('#modal-body .cand-value')).map(c => c.textContent);
const checked = document.querySelector('#modal-body input[type=radio]:checked').value;
const edit = document.querySelector('#modal-body .cand-edit input').value;
const count = S.config.pages[S.page].actions.length;
document.querySelector('#modal-buttons .btn-primary').click();
await until(() => !document.querySelector('#modal').open && S.config.pages[S.page].actions.length > count, 3000);
const page = S.config.pages[S.page];
const added = page.actions[page.actions.length - 1];
return { open: !!open, labels, values, checked, edit, added, picking: document.querySelector('#picking').open, page: S.page, count: S.config.pages.length, actions: page.actions,
  row: Array.from(document.querySelectorAll('.action-text')).pop().textContent };
'@
        $r.open | Should -BeTrue
        $r.labels[0] | Should -Be "The $([char]0x2018)Logs$([char]0x2019) tab"
        $r.values | Should -Contain 'Logs'
        $r.values | Should -Contain '#t-logs'
        $r.checked | Should -Be '0'
        $r.edit | Should -Be 'Logs'
        $r.added.type | Should -Be 'clickText' -Because "page $($r.page) of $($r.count): $($r.actions | ConvertTo-Json -Compress)"
        $r.added.text | Should -Be 'Logs'
        $r.picking | Should -BeFalse
        $r.row | Should -Match 'Logs'
        # The site never saw the click.
        Invoke-Audit 'document.title' | Should -Be 'Tabs'
    }

    It 'tests the action in the browser and shows the result under it' {
        $r = Invoke-UiPanel @'
const page = S.config.pages[S.page];
const j = page.actions.length - 1;
const button = btnByKey('action-test:' + j);
const label = button.textContent, aria = button.getAttribute('aria-label');
button.click();
const result = await until(() => document.querySelectorAll('.action-result').length ? document.querySelector('.action-result') : null, 10000);
return { label, aria, text: result ? result.textContent : '', ok: result ? result.classList.contains('is-ok') : false };
'@
        $r.label | Should -Be 'Test (really clicks)'
        $r.aria | Should -Match 'really clicks'
        $r.ok | Should -BeTrue
        $r.text | Should -Match 'Test worked'
        Invoke-Audit 'document.title' | Should -Be 'Logs'
    }

    It 'cancels picking from the panel' {
        $r = Invoke-UiPanel @'
btnByKey('pick-click').click();
await until(() => document.querySelector('#picking').open, 8000);
document.querySelector('#picking-cancel').click();
const closed = await until(() => !document.querySelector('#picking').open, 8000);
return { closed: !!closed, toast: document.querySelector('#toast').textContent };
'@
        $r.closed | Should -BeTrue
        $r.toast | Should -Match 'cancelled'
        Invoke-Audit "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
    }

    It 'had no CSP violation, script error or console error' {
        Use-Cdp 'panel'
        Invoke-CdpEval -Expression "Array.isArray(window.__errs) ? JSON.stringify(window.__errs) : 'missing'" | Should -Be '[]'
    }

    It 'says when the browser has gone, with Retry, and Retry connects again' {
        Use-Cdp 'audit'; Close-CdpSocket; Use-Cdp 'panel'
        Stop-HeadlessEdge -ProfileDir $script:AuditProfile
        $r = Invoke-UiPanel @'
const off = await until(() => document.querySelector('#browser-strip').classList.contains('is-off'), 12000);
const strip = document.querySelector('#browser-strip');
return { off: !!off, text: strip.textContent, retry: !!btnByKey('bs-retry'), pick: btnByKey('pick-click') ? btnByKey('pick-click').getAttribute('aria-disabled') : 'gone' };
'@
        $r.off | Should -BeTrue
        $r.text | Should -Match 'Browser not connected'
        $r.text | Should -Match 'The audit Edge window was closed'
        $r.retry | Should -BeTrue
        $r.pick | Should -Be 'true'
        [void](Start-HeadlessEdge -Port $script:AuditCdp -ProfileDir $script:AuditProfile)
        $r = Invoke-UiPanel @'
const retry = btnByKey('bs-retry');
if (retry) retry.click();
const on = await until(() => S.browser.connected && document.querySelector('#browser-strip').classList.contains('is-on'), 15000);
return { on: !!on, text: document.querySelector('#browser-strip').textContent };
'@
        $r.on | Should -BeTrue
        $r.text | Should -Match 'Browser connected'
    }
}
