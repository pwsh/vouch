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
    $script:DesignerRunPath = Join-Path -Path (Split-Path -Path $script:VouchPath -Parent) -ChildPath 'designer\Designer.Run.ps1'
    $script:FakeChildPath = Join-Path -Path $PSScriptRoot -ChildPath 'FakeVouchChild.ps1'
    . ([scriptblock]::Create((Get-VouchFunctionSource -Path $script:VouchPath, $script:DesignerPath, $script:DesignerRunPath)))
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
        param([string]$ConfigPath = '', [string]$Name = 'server', [int]$AuditPort = 0, [string]$AuditProfile = '', [string]$RunScript = '', [string]$OpenLog = '')
        $folder = Join-Path -Path $TestDrive -ChildPath $Name
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $ready = Join-Path -Path $folder -ChildPath 'ready.json'
        $literal = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
        $browser = if ($AuditPort -gt 0) { "-DebugPort $AuditPort -AuditProfileDir $(& $literal $AuditProfile) -NoBrowserLaunch" } else { '-NoBrowser' }
        if ($RunScript) { $browser += " -RunScriptPath $(& $literal $RunScript)" }
        if ($OpenLog) { $browser += " -OpenLog $(& $literal $OpenLog)" }
        $hostScript = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $(& $literal (Join-Path $PSScriptRoot 'TestHelpers.ps1'))
. ([scriptblock]::Create((Get-VouchFunctionSource -Path $(& $literal $script:VouchPath), $(& $literal $script:DesignerPath), $(& $literal $script:DesignerRunPath))))
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

    It 'has no route left that answers 501 (runs are implemented)' {
        (Get-DesignerLaterRoute).Count | Should -Be 0
        (Invoke-TestRoute GET '/api/run' -State $script:State).Status | Should -Be 200
        (Invoke-TestRoute GET '/preview/run1/001.jpg' -State $script:State).Status | Should -Be 404
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

        It 'gives a schedule command that parses as PowerShell and binds to the real param block of Install-VouchSchedule.ps1' {
            $installer = Join-Path (Split-Path $script:VouchPath -Parent) 'Install-VouchSchedule.ps1'
            $script:Cmd.ScheduleNote | Should -Not -Match 'later step'
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:Cmd.Schedule, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0
            $elements = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements
            $elements[0].Value | Should -Be 'pwsh'
            $fileIndex = @($elements | ForEach-Object { $_.Extent.Text }).IndexOf('-File')
            $elements[$fileIndex + 1].Value | Should -Be $installer
            $rest = @($elements | Select-Object -Skip ($fileIndex + 2) | ForEach-Object { $_.Extent.Text }) -join ' '
            $call = [System.Management.Automation.Language.Parser]::ParseInput("& '$($installer.Replace("'", "''"))' $rest", [ref]$null, [ref]$null)
            $command = $call.Find({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
            $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($command, $true)
            $binding.BindingExceptions.Count | Should -Be 0
            @($binding.BoundParameters.Keys | Sort-Object) | Should -Be @('ConfigPath', 'Schedule')
            $binding.BoundParameters['ConfigPath'].ConstantValue | Should -Be $script:CmdConfigPath
            $binding.BoundParameters['Schedule'].ConstantValue | Should -Be 'AtLogOn'
            # The cmd.exe form names the same file and the same schedule.
            $script:Cmd.ScheduleCmd | Should -Be ('pwsh -NoProfile -ExecutionPolicy Bypass -File "' + $installer + '" -ConfigPath "' + $script:CmdConfigPath + '" -Schedule AtLogOn')
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
        $r.later | Should -Match 'need the audit browser'
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
const expandedCopy = copied;
Array.from(document.querySelectorAll('#command-box button')).find(b => b.dataset.fkey === 'copy:schedule').click();
await new Promise(r => setTimeout(r, 50));
const pre = document.querySelectorAll('#command-box pre.command-text')[1];
const lines = Array.from(pre.querySelectorAll('.cmd-line')).map(e => e.textContent);
const box = document.querySelector('#command-box');
return { copied: expandedCopy, scheduleCopied: copied, api: S.command.runExpanded, lines, schedule: S.command.schedule, shown: box.textContent,
  later: document.querySelector('#panel-run .later-note').textContent };
'@
        $r.copied | Should -BeExactly $r.api
        ($r.lines -join ' ') | Should -BeExactly $r.api
        $r.lines[0] | Should -Be 'pwsh -NoProfile -ExecutionPolicy Bypass'
        $r.lines[1] | Should -BeLike '-File *vouch.ps1"'
        foreach ($line in $r.lines | Select-Object -Skip 1) { $line | Should -Match '^-[A-Za-z]+( |$)' }
        $r.lines | Should -Contain '-SaveImages'
        # The schedule box is live: the installer command, its explanation, and Copy gives it exactly.
        $r.schedule | Should -BeLike '*Install-VouchSchedule.ps1" -ConfigPath *-Schedule AtLogOn'
        $r.scheduleCopied | Should -BeExactly $r.schedule
        $r.shown | Should -Match 'Install-VouchSchedule'
        $r.shown | Should -Match 'Paste into a PowerShell window to set up a Windows scheduled task'
        $r.shown | Should -Match 'replace -Schedule AtLogOn with -At 07:30'
        $r.shown | Should -Not -Match 'later step'
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

    It 'says the same when the designer folder lacks its run file (Designer.Run.ps1)' {
        $partial = Join-Path $TestDrive 'partial'
        [void](New-Item -ItemType Directory -Path (Join-Path $partial 'designer') -Force)
        Copy-Item -LiteralPath $script:VouchPath -Destination (Join-Path $partial 'vouch.ps1')
        Copy-Item -LiteralPath $script:DesignerPath -Destination (Join-Path $partial 'designer\Designer.ps1')
        $out = Join-Path $partial 'out.txt'
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out `
            -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$(Join-Path $partial 'vouch.ps1')`"", '-Designer'
        $process.ExitCode | Should -Be 1
        Get-Content -Raw -LiteralPath $out | Should -Match "needs the folder 'designer' next to vouch.ps1"
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
        # A run needs the connected audit Edge (the child attaches to its tab).
        $r.Data.capabilities.run | Should -BeTrue
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

    It 'looks at other tabs at most every 4 seconds, and stops a sweep at the first tab that does not answer' {
        $script:State.Browser.Connected = $true
        $script:State.Browser.Port = 9555
        $script:State.Browser.TabId = 'own'
        $tab = { param($id) [pscustomobject]@{ id = $id; type = 'page'; url = "https://a.example/$id"; title = $id; webSocketDebuggerUrl = "ws://x/$id" } }
        Mock Get-DevToolsTargetList { @((& $tab 'own'), (& $tab 'a'), (& $tab 'b'), (& $tab 'c')) }
        Mock Invoke-CdpEval { 'hidden' }
        Mock Get-DesignerTabVisibility { $script:Probes++; '' }
        $script:Probes = 0
        Update-DesignerBrowser -State $script:State -Force
        $script:Probes | Should -Be 1
        Update-DesignerBrowser -State $script:State -Force
        $script:Probes | Should -Be 1
        $script:State.Browser.LastSweep = (Get-Date).AddSeconds(-5)
        Update-DesignerBrowser -State $script:State -Force
        $script:Probes | Should -Be 2
        $script:State.Browser.TabId | Should -Be 'own'
        # A sweep also ends when its time is used up.
        Mock Get-DesignerTabVisibility { $script:Probes++; Start-Sleep -Milliseconds 300; 'hidden' }
        $script:Probes = 0
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        [void](Find-DesignerVisibleTab -State $script:State -Tabs @((& $tab 'a'), (& $tab 'b'), (& $tab 'c'), (& $tab 'd')) -Skip 'own' -BudgetMs 500)
        $script:Probes | Should -BeLessOrEqual 2
        $watch.ElapsedMilliseconds | Should -BeLessThan 1500
    }

    It 'reads the saved configuration again only when the file changed' {
        $path = Join-Path $TestDrive 'cache.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "browser": { "debugPort": 9333 }, "pages": [] }' -Encoding utf8NoBOM
        $script:State.ConfigPath = $path
        Mock Read-DesignerConfigFile { $script:Reads++; [pscustomobject]@{ Config = (ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($Path))); Text = '' } }
        $script:Reads = 0
        (Get-DesignerBrowserSetting -State $script:State).Port | Should -Be 9333
        (Get-DesignerBrowserSetting -State $script:State).Port | Should -Be 9333
        [void](Get-DesignerBrowserData -State $script:State)
        $script:Reads | Should -Be 1
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "browser": { "debugPort": 9444 }, "pages": [] }' -Encoding utf8NoBOM
        [System.IO.File]::SetLastWriteTimeUtc($path, (Get-Date).ToUniversalTime().AddMinutes(1))
        (Get-DesignerBrowserSetting -State $script:State).Port | Should -Be 9444
        $script:Reads | Should -Be 2
    }

    It 'checks a pick''s proposals within one deadline, and says so when it ran out' {
        $element = [ordered]@{ kind = 'element'; noun = 'button'; frame = '' }
        $proposals = @(1..16 | ForEach-Object { [pscustomobject]@{ kind = 'path'; value = "div:nth-of-type($_)"; anchorId = '' } })
        Mock Test-ElementPickProposal { $script:Checks++; Start-Sleep -Milliseconds 400; [pscustomobject]@{ Ok = $false; Exact = $false } }
        $script:Checks = 0
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Get-ElementPickCandidate -Mode click -Token 't' -Proposals $proposals -Element $element -DeadlineSec 1
        $watch.ElapsedMilliseconds | Should -BeLessThan 2500
        $r.TimedOut | Should -BeTrue
        $r.Candidates.Count | Should -Be 0
        $script:Checks | Should -BeLessOrEqual 4
        Mock Test-ElementPickProposal { Start-Sleep -Milliseconds 400; [pscustomobject]@{ Ok = $true; Exact = $true } }
        $r = Get-ElementPickCandidate -Mode click -Token 't' -Proposals $proposals -Element $element -DeadlineSec 0.6
        $r.TimedOut | Should -BeTrue
        $r.Candidates.Count | Should -BeGreaterThan 0
        Should -Invoke Test-ElementPickProposal -ParameterFilter { $TimeoutSec -ge 1 -and $TimeoutSec -le 1 }
    }

    It 'puts mode, token and words into the picker only as JavaScript literals' {
        $script = Get-DesignerPickerScript -State $script:State -Mode click -Token 'x"); alert(1); ("'
        $script | Should -Match ([regex]::Escape('token: "x\"); alert(1); (\""'))
        $script | Should -Match ([regex]::Escape('function vouchDocs()'))
        $script.TrimEnd() | Should -BeLike '*})()'
    }

    It 'has words for every note the picker can report, and none for a code it does not know' {
        foreach ($code in 'changed', 'changed-again', 'uncovered', 'uncovered-dialog', 'uncovered-popup', 'uncovered-fullscreen', 'shortcut') {
            Get-DesignerPickNote -Code $code | Should -Not -BeNullOrEmpty
            (Get-DesignerPickerText -Mode click)[$code] | Should -Be (Get-DesignerPickNote -Code $code)
        }
        Get-DesignerPickNote -Code 'shortcut' | Should -Match 'Vouch cancelled the click'
        Get-DesignerPickNote -Code '<script>' | Should -Be ''
        Get-DesignerPickNote -Code '' | Should -Be ''
    }

    It 'keeps the shield for new pages small and self-ending: it only swallows, lives in the picker''s own global and removes itself' {
        $shield = Get-DesignerPickShieldScript
        $shield | Should -Match ([regex]::Escape("var NS = '__vouchPicker'"))
        $shield | Should -Match 'setTimeout\(api\.stop, 4000\)'
        $shield | Should -Not -Match 'innerHTML|eval\(|fetch\(|XMLHttpRequest'
        $shield.Length | Should -BeLessThan 2000
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
  while (w.frameElement) {
    var fe = w.frameElement, f = fe.getBoundingClientRect(), cs = w.parent.getComputedStyle(fe);
    x += f.left + parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft); y += f.top + parseFloat(cs.borderTopWidth) + parseFloat(cs.paddingTop); w = w.parent;
  }
  // A tall element's centre can be below the window: stay inside it.
  return { x: Math.min(Math.max(x, 5), window.innerWidth - 5), y: Math.min(Math.max(y, 5), window.innerHeight - 5) };
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
            # The site's own window capture listeners (registered before the picker) saw no control as a target.
            Invoke-CdpEval -Expression 'JSON.stringify(window.__winHits || [])' | Should -Be '[]'
            Invoke-CdpEval -Expression 'window.__submits || 0' | Should -Be 0
            Invoke-CdpEval -Expression 'document.title' | Should -Be $Title
        }
        function Send-TestKey([string]$Key, [int]$Code) {
            foreach ($type in 'keyDown', 'keyUp') {
                $params = @{ type = $type; key = $Key; code = $(if ($Key -eq ' ') { 'Space' } else { $Key }); windowsVirtualKeyCode = $Code; nativeVirtualKeyCode = $Code }
                if ($type -eq 'keyDown' -and $Key -eq 'Enter') { $params.text = "`r" }
                [void](Send-CdpCommand -Method 'Input.dispatchKeyEvent' -Params $params)
            }
        }
        function Send-TestChord([string]$Key, [int]$Code, [int]$Modifiers = 0, [string]$Text = '', [string]$KeyCode = '') {
            # A real key press with modifiers (1 Alt, 2 Ctrl, 4 Meta, 8 Shift; 3 is AltGr).
            # -Text makes the press type that character; without it the key only acts.
            foreach ($type in 'keyDown', 'keyUp') {
                $params = @{ type = $type; key = $Key; code = $(if ($KeyCode) { $KeyCode } else { $Key }); windowsVirtualKeyCode = $Code; nativeVirtualKeyCode = $Code; modifiers = $Modifiers }
                if (($Modifiers -band 3) -eq 1) { $params.isSystemKey = $true }
                if ($type -eq 'keyDown') { if ($Text) { $params.text = $Text; $params.unmodifiedText = $Text } else { $params.type = 'rawKeyDown' } }
                [void](Send-CdpCommand -Method 'Input.dispatchKeyEvent' -Params $params)
            }
        }
        function Get-TestPickerPlace {
            # Where the picker's host is: the id of its parent, or of the component whose shadow root holds it.
            return Invoke-CdpEval -Expression @'
(function () {
  var h = document.querySelector('vouch-picker-ui');
  if (h) { return h.parentNode.id || h.parentNode.nodeName; }
  var all = document.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) { if (all[i].shadowRoot && all[i].shadowRoot.querySelector('vouch-picker-ui')) { return 'shadow:' + all[i].id; } }
  return 'none';
})()
'@
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
        # Control: while picking, a scripted click inside the frame is swallowed - and,
        # being the page's own doing, picks nothing: the pick goes on.
        Invoke-CdpEval -Expression "document.getElementById('sameframe').contentDocument.getElementById('framebtn').click(); JSON.stringify(window.__hits)" | Should -Be '[]'
        Start-Sleep -Milliseconds 400
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        (Invoke-TestRoute POST '/api/pick/cancel' -State $script:B).Data.state | Should -Be 'cancelled'
        [void](Invoke-CdpEval -Expression 'window.__winHits = []; true')
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
        # Nothing is left behind by the picker put back after the reload either.
        $after = Get-PageTrace
        Open-TestPage "/pickme?x=$($script:Web2)"
        $after | Should -BeExactly (Get-PageTrace)
    }

    It 'never lets the page pick or cancel by itself: scripted clicks, dispatched events and a scripted Esc' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        [void](Invoke-CdpEval -Expression @'
(function () {
  document.getElementById('fav').click();
  var b = document.querySelector('[data-testid=save-settings]'), r = b.getBoundingClientRect();
  b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + 2 }));
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
  document.getElementById('fav').focus();
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
  return true;
})()
'@)
        Start-Sleep -Milliseconds 500
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '[]'
        # The person can still pick afterwards.
        Send-TestClick (Get-TestPoint "document.getElementById('reports-a')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done'
        $r.result.candidates[0].value | Should -Be 'Reports'
    }

    It 'keeps scrolling possible during a pick: the wheel reaches the panel, the frame and the page under the pointer' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        foreach ($case in @(
                @{ El = "document.querySelector('#leftpanel div')"; Probe = "document.getElementById('leftpanel').scrollTop" },
                @{ El = "document.getElementById('sameframe').contentDocument.querySelector('div')"; Probe = "document.getElementById('sameframe').contentWindow.scrollY" },
                @{ El = "document.getElementById('spacer')"; Probe = 'window.scrollY' })) {
            $p = Get-TestPoint $case.El
            $was = [double](Invoke-CdpEval -Expression $case.Probe)
            [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseWheel'; x = [double]$p.x; y = [double]$p.y; deltaX = 0; deltaY = 120 })
            Start-Sleep -Milliseconds 300
            [double](Invoke-CdpEval -Expression $case.Probe) | Should -BeGreaterThan $was -Because "$($case.El) must scroll"
        }
        # Sideways too; the site's own wheel listeners do not see a wheel the picker handled.
        $p = Get-TestPoint "document.getElementById('hscroll')"
        [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseWheel'; x = [double]$p.x; y = [double]$p.y; deltaX = 120; deltaY = 0 })
        Start-Sleep -Milliseconds 300
        [double](Invoke-CdpEval -Expression "document.getElementById('hscroll').scrollLeft") | Should -BeGreaterThan 0
        Invoke-CdpEval -Expression 'window.__wheels.length' | Should -Be 0
        # Ctrl+wheel (the browser's zoom) is left alone: not prevented and seen by the site.
        # (Headless Edge has no browser zoom, so its own default action scrolls; a window does not.)
        $p = Get-TestPoint "document.getElementById('spacer')"
        $width = Invoke-CdpEval -Expression 'window.innerWidth'
        [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseWheel'; x = [double]$p.x; y = [double]$p.y; deltaX = 0; deltaY = 120; modifiers = 2 })
        Start-Sleep -Milliseconds 300
        $wheels = Invoke-CdpEval -Expression 'JSON.stringify(window.__wheels)'
        $wheels | Should -Be '[{"ctrl":true,"prevented":false}]'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
        Assert-SiteUntouched
        Invoke-CdpEval -Expression 'window.innerWidth' | Should -Be $width
    }

    It 'keeps every key from the page: focus taken once, Enter/Space/Tab/letters do nothing, scroll keys scroll, Esc cancels' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $before = Get-PageTrace
        # The page has a control focused when the pick starts: the picker takes the focus once.
        [void](Invoke-CdpEval -Expression "document.getElementById('fav').focus(); true")
        [void](Start-ElementPick -State $script:B -Mode click)
        Invoke-CdpEval -Expression 'document.activeElement.tagName' | Should -Be 'VOUCH-PICKER-UI'
        Send-TestKey -Key 'Enter' -Code 13
        Invoke-CdpEval -Expression 'window.__keyTargets.join()' | Should -Be 'VOUCH-PICKER-UI'
        # The page then focuses a control itself: not fought over; its keys still do nothing.
        [void](Invoke-CdpEval -Expression "setTimeout(function () { document.querySelector('[data-testid=save-settings]').focus(); }, 50); true")
        Start-Sleep -Milliseconds 400
        Invoke-CdpEval -Expression "document.activeElement.getAttribute('data-testid')" | Should -Be 'save-settings'
        [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseMoved'; x = 600.0; y = 700.0 })
        $scrolled = [double](Invoke-CdpEval -Expression 'window.scrollY')
        Send-TestKey -Key 'Enter' -Code 13
        Send-TestKey -Key 'Tab' -Code 9
        Send-TestKey -Key 'a' -Code 65
        Send-TestKey -Key ' ' -Code 32
        Start-Sleep -Milliseconds 300
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        [double](Invoke-CdpEval -Expression 'window.scrollY') | Should -BeGreaterThan $scrolled
        $p = Get-TestPoint "document.querySelector('#leftpanel div')"
        [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseMoved'; x = [double]$p.x; y = [double]$p.y })
        Send-TestKey -Key 'ArrowDown' -Code 40
        Start-Sleep -Milliseconds 200
        [double](Invoke-CdpEval -Expression "document.getElementById('leftpanel').scrollTop") | Should -BeGreaterThan 0
        $targets = @(Invoke-CdpEval -Expression 'window.__keyTargets')
        $targets.Count | Should -BeGreaterThan 2
        foreach ($t in $targets) { $t | Should -BeIn 'VOUCH-PICKER-UI', 'BODY', 'BUTTON' }
        Assert-SiteUntouched
        Send-TestKey -Key 'Escape' -Code 27
        $r = Wait-TestPick
        $r.state | Should -Be 'cancelled'
        [void](Invoke-CdpEval -Expression "window.scrollTo(0, 0); document.getElementById('leftpanel').scrollTop = 0; true")
        (Get-PageTrace) | Should -BeExactly $before
    }

    It 'keeps Enter, Space and Tab from a control focused inside a frame from another site' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        # A real click focuses the other site's button (and counts once in that page).
        Send-TestClick (Get-TestPoint "document.getElementById('otherframe')")
        Start-Sleep -Milliseconds 200
        $readClicks = {
            $tree = Send-CdpCommand -Method 'Page.getFrameTree'
            $frame = @($tree.frameTree.childFrames | Where-Object { $_.frame.url -like "*:$($script:Web2)/*" })[0]
            $world = Send-CdpCommand -Method 'Page.createIsolatedWorld' -Params @{ frameId = $frame.frame.id; worldName = 'vouch-test' }
            (Send-CdpCommand -Method 'Runtime.evaluate' -Params @{ expression = "document.body.getAttribute('data-clicks') + '|' + (document.activeElement && document.activeElement.id)"; contextId = $world.executionContextId; returnByValue = $true }).result.value
        }
        $start = & $readClicks
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 400
        Send-TestKey -Key 'Enter' -Code 13
        Send-TestKey -Key ' ' -Code 32
        Send-TestKey -Key 'Tab' -Code 9
        Start-Sleep -Milliseconds 300
        $after = & $readClicks
        ($after -split '\|')[0] | Should -Be (($start -split '\|')[0]) -Because "the other site's button had focus ($start) and must not activate"
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -BeIn 'picking', 'error'
        if ($r.state -eq 'error') { $r.code | Should -Be 'focus' }
        else { Invoke-CdpEval -Expression 'document.activeElement.tagName' | Should -Be 'VOUCH-PICKER-UI' }
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'picks inside top-layer content: <Case>' -ForEach @(
        @{ Case = 'a modal dialog open before the pick'; Page = '&dialog=1'; Open = ''; El = "document.getElementById('dlgbtn')"; Text = 'Dialog action'; Hit = 'dialog' }
        @{ Case = 'a modal dialog opened during the pick'; Page = ''; Open = "document.getElementById('dlg').showModal()"; El = "document.getElementById('dlgbtn')"; Text = 'Dialog action'; Hit = 'dialog' }
        @{ Case = 'a popover'; Page = '&popover=1'; Open = ''; El = "document.getElementById('popbtn')"; Text = 'Popover action'; Hit = 'popover' }
    ) {
        $page = "/pickme?x=$($script:Web2)$Page"
        Open-TestPage $page
        [void](Start-ElementPick -State $script:B -Mode click)
        if ($Open) { [void](Invoke-CdpEval -Expression "$Open; true"); Start-Sleep -Milliseconds 400 }
        Send-TestClick (Get-TestPoint $El)
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        Assert-SiteUntouched
        $r.result.candidates[0].action.text | Should -Be $Text
        Open-TestPage "/pickme?x=$($script:Web2)&$(if ($Hit -eq 'dialog') { 'dialog=1' } else { 'popover=1' })"
        (Invoke-PageAction -Action (ConvertTo-TestAction $r.result.candidates[0].action) -Settings $script:Replay).Ok | Should -BeTrue
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be "[`"$Hit`"]"
    }

    It 'never picks when the page opens a dialog at the press or changes what is under the pointer: <Case>' -ForEach @(
        @{ Case = 'a modal dialog opened at the press'; Query = '&openOnDown=1'; Notice = 'changed under the pointer' }
        @{ Case = 'the element swapped between press and release'; Query = '&swapOnUp=1'; Notice = 'changed under the pointer' }
    ) {
        Open-TestPage "/pickme?x=$($script:Web2)$Query"
        $point = Get-TestPoint "document.getElementById('reports-a')"
        [void](Start-ElementPick -State $script:B -Mode click)
        Send-TestClick $point
        Start-Sleep -Milliseconds 500
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -Be 'picking'
        $r.notice | Should -Match $Notice
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '[]'
        Invoke-CdpEval -Expression 'document.title' | Should -Be 'Pick me'
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
    }

    It 'puts the picking layer back when the page removes it, and picks safely afterwards' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $before = Get-PageTrace
        [void](Start-ElementPick -State $script:B -Mode click)
        Invoke-CdpEval -Expression "document.querySelector('vouch-picker-ui').remove(); document.querySelectorAll('vouch-picker-ui').length" | Should -Be 0
        Start-Sleep -Milliseconds 100
        Invoke-CdpEval -Expression "document.querySelectorAll('vouch-picker-ui').length" | Should -Be 1
        Send-TestClick (Get-TestPoint "document.querySelector('[data-testid=save-settings]')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done'
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
    }

    It 'keeps covering the window when <html> is transformed (or ends the pick safely)' {
        Open-TestPage "/pickme?x=$($script:Web2)&transform=1"
        [void](Invoke-CdpEval -Expression 'window.scrollTo(0, 200); true')
        [void](Start-ElementPick -State $script:B -Mode scroll)
        Start-Sleep -Milliseconds 400
        # The layer is in the top layer, whose box the transform of <html> does not move.
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -Be 'picking'
        Send-TestClick (Get-TestPoint "document.querySelector('#leftpanel div:nth-child(3)')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done'
        $r.result.candidates[0].value | Should -Be '#leftpanel'
        Assert-SiteUntouched
    }

    It 'picks in a frame that is <Case>' -ForEach @(
        @{ Case = 'padded, with a thick border'; Kind = 'pad' }
        @{ Case = 'only moved (translate)'; Kind = 'translate' }
        @{ Case = 'at rest: scale 1, rotate 0deg, zoom 1 and an identity matrix'; Kind = 'identity' }
    ) {
        Open-TestPage "/framegeom?kind=$Kind"
        $before = Get-PageTrace
        $r = Invoke-TestPick 'click' "document.getElementById('geomframe').contentDocument.getElementById('framebtn')"
        $r.state | Should -Be 'done' -Because $r['message']
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#framebtn'
        (Get-PageTrace) | Should -BeExactly $before
        Open-TestPage "/framegeom?kind=$Kind"
        (Invoke-PageAction -Action (ConvertTo-TestAction $r.result.candidates[0].action) -Settings $script:Replay).Ok | Should -BeTrue
        Invoke-CdpEval -Expression "document.getElementById('geomframe').contentDocument.body.getAttribute('data-clicks')" | Should -Be '1'
    }

    It 'refuses a frame drawn <Case>' -ForEach @(
        @{ Case = 'scaled'; Kind = 'scaled' }
        @{ Case = 'mirrored (same box size)'; Kind = 'mirror' }
        @{ Case = 'turned 180 degrees (same box size)'; Kind = 'rot180' }
        @{ Case = 'square and turned 90 degrees (same box size)'; Kind = 'rot90' }
        @{ Case = 'inside a turned box (an ancestor is transformed)'; Kind = 'ancestor' }
        @{ Case = 'turned along a motion path (offset-path, no transform at all)'; Kind = 'offset' }
    ) {
        Open-TestPage "/framegeom?kind=$Kind"
        $before = Get-PageTrace
        $r = Invoke-TestPick 'click' "document.getElementById('geomframe')"
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'transformed'
        $r.message | Should -Match 'scaled or turned'
        (Get-PageTrace) | Should -BeExactly $before
        Invoke-CdpEval -Expression "document.getElementById('geomframe').contentDocument.body.getAttribute('data-clicks')" | Should -BeNullOrEmpty
    }

    It 'refuses a full-screen element plainly (it stays above the picking layer), and the site never sees the click' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $entered = Invoke-CdpEval -Expression "document.getElementById('leftpanel').requestFullscreen().then(() => !!document.fullscreenElement, () => false)"
        if (-not $entered) { Set-ItResult -Skipped -Because 'this headless Edge does not enter full screen'; return }
        try {
            Start-Sleep -Milliseconds 300
            $point = Get-TestPoint "document.querySelector('#leftpanel div:nth-child(2)')"
            [void](Start-ElementPick -State $script:B -Mode scroll)
            Start-Sleep -Milliseconds 400
            Send-TestClick $point
            Start-Sleep -Milliseconds 500
            $r = Get-ElementPickResult -State $script:B
            $r.state | Should -Be 'picking'
            $r.notice | Should -Match 'shown full screen above everything else, so it cannot be picked by pointing'
            Assert-SiteUntouched
        }
        finally {
            [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
            [void](Invoke-CdpEval -Expression 'document.fullscreenElement ? document.exitFullscreen().then(() => true, () => true) : true')
        }
    }

    It 'does not fight a page''s focus trap: no recursion, few focus events, and picking inside it works' {
        Open-TestPage "/pickme?x=$($script:Web2)&trap=1"
        Invoke-CdpEval -Expression 'document.activeElement.id' | Should -Be 'trapfirst'
        [void](Invoke-CdpEval -Expression 'window.__trapEvents = 0; true')
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 1000
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        [int](Invoke-CdpEval -Expression 'window.__trapEvents') | Should -BeLessOrEqual 4
        Send-TestClick (Get-TestPoint "document.getElementById('trapsecond')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done'
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#trapsecond'
        [int](Invoke-CdpEval -Expression 'window.__trapEvents') | Should -BeLessOrEqual 4
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '[]'
    }

    It 'takes the focus from a field once at the start (its blur handler runs once) and does not give it back' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Invoke-CdpEval -Expression "document.getElementById('q').focus(); true")
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 800
        Invoke-CdpEval -Expression 'window.__blurs' | Should -Be 1
        Send-TestKey -Key 'Escape' -Code 27
        (Wait-TestPick).state | Should -Be 'cancelled'
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression 'window.__blurs + "|" + window.__changes + "|" + document.activeElement.tagName' | Should -Be '1|0|BODY'
    }

    It 'keeps a native menu (popover="auto") open while pointing, and picks its item or anything else' {
        foreach ($case in @(@{ El = "document.getElementById('autobtn')"; Value = 'Menu item' }, @{ El = "document.getElementById('fav')"; Value = '#fav' })) {
            Open-TestPage "/pickme?x=$($script:Web2)&autopop=1"
            $before = Get-PageTrace
            $r = Invoke-TestPick 'click' $case.El
            $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
            @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain $case.Value
            Invoke-CdpEval -Expression "document.getElementById('autopop').matches(':popover-open') + '|' + JSON.stringify(window.__toggles)" | Should -Be 'true|["open"]'
            Assert-SiteUntouched
            (Get-PageTrace) | Should -BeExactly $before
        }
    }

    It 'goes into the modal dialog that is really on top, even when it comes earlier in the page' {
        Open-TestPage "/pickme?x=$($script:Web2)&nested=1"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 600
        Invoke-CdpEval -Expression "document.querySelector('vouch-picker-ui').parentNode.id" | Should -Be 'dlg'
        Send-TestClick (Get-TestPoint "document.getElementById('dlgbtn')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        $r.result.candidates[0].action.text | Should -Be 'Dialog action'
        Assert-SiteUntouched
    }

    It 'ends the pick (coverage) instead of fighting a page that keeps throwing the layer out, and the tab stays responsive' {
        Open-TestPage "/pickme?x=$($script:Web2)&fight=1"
        [void](Start-ElementPick -State $script:B -Mode click)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Wait-TestPick
        $watch.ElapsedMilliseconds | Should -BeLessThan 5000
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'coverage'
        Invoke-CdpEval -Expression '1 + 1' -TimeoutSec 5 | Should -Be 2
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
    }

    It 'decides keys by where they go: aimed at the picking layer the browser''s shortcuts keep their default, aimed at the page nothing does' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        $r = Invoke-CdpEval -Expression @'
(function () {
  var layer = document.querySelector('vouch-picker-ui');
  var k = function (where, o) { return where.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ bubbles: true, cancelable: true, composed: true }, o))); };
  var keys = { reload: { key: 'r', ctrlKey: true }, f5: { key: 'F5' }, f4: { key: 'F4' }, find: { key: 'f', ctrlKey: true }, zoom: { key: '+', ctrlKey: true },
    back: { key: 'ArrowLeft', altKey: true }, paste: { key: 'v', ctrlKey: true }, plain: { key: 'a' }, enter: { key: 'Enter' }, esc: { key: 'Escape' } };
  var before = window.__keys, out = { layer: {}, body: {}, field: {} };
  Object.keys(keys).forEach(function (n) { out.layer[n] = k(layer, keys[n]); });
  Object.keys(keys).forEach(function (n) { out.body[n] = k(document.body, keys[n]); });
  document.getElementById('q').focus({ preventScroll: true });
  Object.keys(keys).forEach(function (n) { out.field[n] = k(document.getElementById('q'), keys[n]); });
  out.siteSaw = window.__keys - before;
  return out;
})()
'@
        # Aimed at the layer: function keys and Ctrl/Alt combinations are not prevented; plain keys and Esc are.
        foreach ($name in 'reload', 'f5', 'f4', 'find', 'zoom', 'back', 'paste') { $r.layer.$name | Should -BeTrue -Because "$name aimed at the picking layer keeps its default" }
        foreach ($name in 'plain', 'enter', 'esc') { $r.layer.$name | Should -BeFalse -Because "$name aimed at the picking layer is prevented" }
        # Aimed anywhere else: every key is prevented, no exemptions.
        foreach ($where in 'body', 'field') {
            foreach ($name in 'reload', 'f5', 'f4', 'find', 'zoom', 'back', 'paste', 'plain', 'enter', 'esc') { $r.$where.$name | Should -BeFalse -Because "$name aimed at the page ($where) is prevented" }
        }
        $r.siteSaw | Should -Be 0
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking' -Because 'keys the page makes itself never cancel'
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'keeps every menu open when a sub-menu comes EARLIER in the page than its menu: picking <Case>' -ForEach @(
        @{ Case = 'the sub-menu''s item'; El = "document.getElementById('subbtn')"; Value = 'Sub item' }
        @{ Case = 'the menu''s item'; El = "document.getElementById('autobtn')"; Value = 'Menu item' }
        @{ Case = 'something outside both'; El = "document.getElementById('fav')"; Value = '#fav' }
    ) {
        Open-TestPage "/pickme?x=$($script:Web2)&submenu=1"
        Invoke-CdpEval -Expression "document.getElementById('autopop').matches(':popover-open') + '|' + document.getElementById('submenu').matches(':popover-open')" | Should -Be 'true|true'
        $before = Get-PageTrace
        $point = Get-TestPoint $El
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        # The layer is in the menu on top of the popover stack (the sub-menu), not the last one in the page.
        Get-TestPickerPlace | Should -Be 'submenu'
        Send-TestClick $point
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain $Value
        Invoke-CdpEval -Expression "document.getElementById('autopop').matches(':popover-open') + '|' + document.getElementById('submenu').matches(':popover-open') + '|' + JSON.stringify(window.__toggles) + JSON.stringify(window.__subToggles)" |
            Should -Be 'true|true|["open"]["open"]' -Because 'neither menu may close, and the site must not see one close'
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
    }

    It 'keeps a menu inside a component (open shadow root) open: <Case>' -ForEach @(
        @{ Case = 'a popover in a shadow root'; Kind = 1; Id = 'shadowmenu'; Place = 'shadowmenu'; Open = "document.getElementById('menuhost').shadowRoot.getElementById('shadowmenu')"; Item = "document.getElementById('menuhost').shadowRoot.getElementById('shadowitem')" }
        @{ Case = 'a popover element that draws its content from its shadow root'; Kind = 2; Id = 'menuel'; Place = 'shadow:menuel'; Open = "document.getElementById('menuel')"; Item = "document.getElementById('menuel').shadowRoot.getElementById('elitem')" }
    ) {
        # Picking something outside the menu works and leaves the menu open.
        Open-TestPage "/pickme?x=$($script:Web2)&shadowmenu=$Kind"
        $before = Get-PageTrace
        $point = Get-TestPoint "document.getElementById('fav')"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        $place = Invoke-CdpEval -Expression "(function () { var h = ($Open).querySelector('vouch-picker-ui') || (($Open).shadowRoot && ($Open).shadowRoot.querySelector('vouch-picker-ui')); return h ? 'inside' : 'outside'; })()"
        $place | Should -Be 'inside' -Because 'the layer must be inside the open menu, or the press closes it'
        Send-TestClick $point
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#fav'
        Invoke-CdpEval -Expression "($Open).matches(':popover-open') + '|' + JSON.stringify(window.__shadowToggles)" | Should -Be "true|[`"${Id}:open`"]"
        Assert-SiteUntouched
        (Get-PageTrace) | Should -BeExactly $before
        Invoke-CdpEval -Expression "(function () { var o = ($Open); return o.querySelectorAll('vouch-picker-ui').length + (o.shadowRoot ? o.shadowRoot.querySelectorAll('vouch-picker-ui').length : 0); })()" | Should -Be 0
        # Pointing at the menu's own item: it is inside a component, so it cannot be recorded - said plainly, menu still open, nothing clicked.
        $point = Get-TestPoint $Item
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        Send-TestClick $point
        $r = Wait-TestPick
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'shadow'
        Invoke-CdpEval -Expression "($Open).matches(':popover-open') + '|' + JSON.stringify(window.__shadowToggles)" | Should -Be "true|[`"${Id}:open`"]"
        Assert-SiteUntouched
    }

    It 'still picks when a menu hides its inside in a CLOSED shadow root (known limit: that menu closes at the press)' {
        Open-TestPage "/pickme?x=$($script:Web2)&shadowmenu=3"
        $point = Get-TestPoint "document.getElementById('fav')"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 600
        # The layer cannot be drawn inside that menu, so it stays in the page - and the pick goes on.
        Get-TestPickerPlace | Should -Be 'HTML'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        Send-TestClick $point
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#fav'
        Assert-SiteUntouched
        # The stated limit, as it is today: the browser closed the menu at the press.
        Invoke-CdpEval -Expression 'JSON.stringify(window.__shadowToggles)' | Should -Be '["menuclosed:open","menuclosed:closed"]'
    }

    It 'follows menus the page opens and closes during the pick, and keeps its own keyboard focus when it moves' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $point = Get-TestPoint "document.getElementById('fav')"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        # Opened by the page: the layer is inside before the page's script has even returned.
        Invoke-CdpEval -Expression "document.getElementById('autopop').showPopover(); Promise.resolve().then(function () { var h = document.querySelector('vouch-picker-ui'); return h.parentNode.id + '|' + document.activeElement.tagName; })" | Should -Be 'autopop|VOUCH-PICKER-UI'
        Start-Sleep -Milliseconds 300
        Send-TestClick $point
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        Invoke-CdpEval -Expression "document.getElementById('autopop').matches(':popover-open') + '|' + JSON.stringify(window.__toggles)" | Should -Be 'true|["open"]'
        # Closed by the page with the layer inside: the layer is back over the page at once.
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        Get-TestPickerPlace | Should -Be 'autopop'
        Invoke-CdpEval -Expression "document.getElementById('autopop').hidePopover(); Promise.resolve().then(function () { var h = document.querySelector('vouch-picker-ui'); return h.parentNode.nodeName + '|' + document.elementFromPoint(300, 300).tagName; })" | Should -Be 'HTML|VOUCH-PICKER-UI'
        Start-Sleep -Milliseconds 300
        Send-TestClick $point
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        Assert-SiteUntouched
    }

    It 'does not count a menu''s own changes as repairs: a menu that keeps rewriting its rows can be picked in' {
        Open-TestPage "/pickme?x=$($script:Web2)&autopop=1&live=1"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 1500
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking' -Because 'twenty rows a second must not end the pick'
        Get-TestPickerPlace | Should -Be 'autopop'
        Send-TestClick (Get-TestPoint "document.getElementById('autobtn')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain 'Menu item'
        Invoke-CdpEval -Expression "document.getElementById('autopop').matches(':popover-open') + '|' + JSON.stringify(window.__toggles) + JSON.stringify(window.__hits)" | Should -Be 'true|["open"][]'
    }

    It 'Esc cancels the pick and leaves the page''s open <Case> open' -ForEach @(
        @{ Case = 'menu'; Query = 'autopop=1'; Probe = "document.getElementById('autopop').matches(':popover-open') + '|' + JSON.stringify(window.__toggles)"; Expected = 'true|["open"]' }
        @{ Case = 'modal dialog'; Query = 'dialog=1'; Probe = "document.getElementById('dlg').open + '|' + JSON.stringify(window.__dlgEvents)"; Expected = 'true|[]' }
    ) {
        # Control: without a pick, Esc in the page closes it.
        Open-TestPage "/pickme?x=$($script:Web2)&$Query"
        Send-TestKey -Key 'Escape' -Code 27
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression $Probe | Should -Not -Be $Expected
        Open-TestPage "/pickme?x=$($script:Web2)&$Query"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        Send-TestKey -Key 'Escape' -Code 27
        (Wait-TestPick).state | Should -Be 'cancelled'
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression $Probe | Should -Be $Expected
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
    }

    It 'lets no key edit a field the page focused inside a component: <Case>' -ForEach @(
        @{ Case = 'open shadow root'; Field = "document.getElementById('fieldhost').shadowRoot.getElementById('shadowfield')"; Value = 'open words here' }
        @{ Case = 'closed shadow root'; Field = 'window.__closedField'; Value = 'closed words here' }
        @{ Case = 'the page itself'; Field = "document.getElementById('q')"; Value = 'find' }
    ) {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        [void](Invoke-CdpEval -Expression "(function () { var f = ($Field); f.focus({ preventScroll: true }); f.setSelectionRange(f.value.length, f.value.length); return true; })()")
        Send-TestChord -Key 'Backspace' -Code 8 -Modifiers 2                      # Ctrl+Backspace: delete a word
        Send-TestChord -Key 'Delete' -Code 46 -Modifiers 2                        # Ctrl+Delete
        Send-TestChord -Key '@' -Code 81 -Modifiers 3 -Text '@' -KeyCode 'KeyQ'   # AltGr+Q types @
        Send-TestChord -Key 'x' -Code 88 -Text 'x' -KeyCode 'KeyX'                # a letter
        Send-TestChord -Key 'a' -Code 65 -Modifiers 2 -KeyCode 'KeyA'             # Ctrl+A, then
        Send-TestChord -Key 'Backspace' -Code 8                                   # Backspace would empty it
        Send-TestChord -Key 'x' -Code 88 -Modifiers 2 -KeyCode 'KeyX'             # Ctrl+X
        Send-TestChord -Key 'z' -Code 90 -Modifiers 2 -KeyCode 'KeyZ'             # Ctrl+Z
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression "($Field).value" | Should -Be $Value
        Invoke-CdpEval -Expression 'JSON.stringify(window.__inputs)' | Should -Be '[]'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        Assert-SiteUntouched
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'does not open or change a list (a select element) the page focused: F4, Alt+Down, arrows, letters' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $open = "(function () { try { return document.getElementById('sel').matches(':open'); } catch (e) { return 'unknown'; } })()"
        # Control: without a pick, F4 opens the list (so the check below means something).
        [void](Invoke-CdpEval -Expression "document.getElementById('sel').focus({ preventScroll: true }); true")
        Send-TestChord -Key 'F4' -Code 115
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression $open | Should -BeTrue
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        [void](Invoke-CdpEval -Expression "document.getElementById('sel').focus({ preventScroll: true }); true")
        foreach ($press in @(@{ Key = 'F4'; Code = 115; Mod = 0 }, @{ Key = 'ArrowDown'; Code = 40; Mod = 1 }, @{ Key = 'ArrowDown'; Code = 40; Mod = 0 }, @{ Key = 'Enter'; Code = 13; Mod = 0 })) {
            Send-TestChord -Key $press.Key -Code $press.Code -Modifiers $press.Mod
            Start-Sleep -Milliseconds 150
            Invoke-CdpEval -Expression $open | Should -BeFalse -Because "$($press.Key) (modifiers $($press.Mod)) must not open the list"
        }
        Send-TestChord -Key 't' -Code 84 -Text 't' -KeyCode 'KeyT'
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression "document.getElementById('sel').value + '|' + window.__selChanges" | Should -Be 'One|0'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        Assert-SiteUntouched
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'does not activate a <Case> the page focused: Enter, Ctrl+Enter, Alt+Enter, Shift+Enter, Space' -ForEach @(
        @{ Case = 'link'; Id = 'keylink' }
        @{ Case = 'button'; Id = 'akbtn' }
    ) {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        [void](Invoke-CdpEval -Expression "document.getElementById('$Id').focus({ preventScroll: true }); true")
        foreach ($mod in 0, 2, 1, 8) { Send-TestChord -Key 'Enter' -Code 13 -Modifiers $mod -Text "`r" }
        Send-TestChord -Key ' ' -Code 32 -Text ' ' -KeyCode 'Space'
        Start-Sleep -Milliseconds 200
        # Not even the site's listeners on window saw a click (the keys' defaults were prevented, so the browser made none).
        Assert-SiteUntouched
        Invoke-CdpEval -Expression "document.activeElement.id" | Should -Be $Id
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -Be 'picking'
        $r.notice | Should -BeNullOrEmpty
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'cancels text the browser is about to insert, and ends the pick when a composition starts in a page field' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        [void](Invoke-CdpEval -Expression "document.getElementById('q').focus({ preventScroll: true }); true")
        # Text committed in one go (how the emoji panel, clipboard history and voice typing deliver it): cancelled.
        [void](Send-CdpCommand -Method 'Input.insertText' -Params @{ text = 'X' })
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression "document.getElementById('q').value + '|' + JSON.stringify(window.__inputs)" | Should -Be 'find|[]'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        # A composition (an input method): it cannot be cancelled, so the pick ends and says so.
        [void](Send-CdpCommand -Method 'Input.imeSetComposition' -Params @{ text = 'ka'; selectionStart = 2; selectionEnd = 2 })
        $r = Wait-TestPick
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'typing'
        $r.message | Should -Match 'a field in the page started to change'
        $r.message | Should -Match 'click Pick again or type the words in the Designer'
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '[]'
    }

    It 'ends the pick with the plain "typing" message when the page fills in a field itself (execCommand insertText)' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        # The page's own script: execCommand fires no beforeinput in Edge, so the field changes
        # and its trusted input event ends the pick - an accepted, stated limit.
        [void](Invoke-CdpEval -Expression "(function () { var f = document.getElementById('q'); f.focus({ preventScroll: true }); document.execCommand('insertText', false, 'X'); return true; })()")
        $r = Wait-TestPick
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'typing'
        $r.message | Should -Match 'or the page filled it in itself'
        $r.message | Should -Not -Match 'focus|frame'
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
    }

    It 'removes the picker from the page by itself when the Designer stops asking for it (heartbeat)' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        # Polled now and then (as the Designer does): it stays for longer than the limit.
        for ($i = 0; $i -lt 7; $i++) { Start-Sleep -Milliseconds 1000; (Get-ElementPickResult -State $script:B).state | Should -Be 'picking' }
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'object|1'
        # Nobody asks any more (the Designer died, or gave up on the tab without stop()).
        Start-Sleep -Milliseconds 6000
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'undefined|0'
        # The page works again: a real click reaches its button.
        Send-TestClick (Get-TestPoint "document.querySelector('[data-testid=save-settings]')")
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '["save"]'
        Stop-ElementPick -State $script:B -NoLayout
    }

    It 'with the focus on the picking layer: Ctrl+Z does not undo the page''s typing, and a paste never reaches the page' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Invoke-CdpEval -Expression "(function () { var f = document.getElementById('q'); f.focus({ preventScroll: true }); f.setSelectionRange(4, 4); return true; })()")
        Send-TestChord -Key 'z' -Code 90 -Text 'z' -KeyCode 'KeyZ'
        Send-TestChord -Key 'y' -Code 89 -Text 'y' -KeyCode 'KeyY'
        Invoke-CdpEval -Expression "document.getElementById('q').value" | Should -Be 'findzy'
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        Invoke-CdpEval -Expression 'document.activeElement.tagName' | Should -Be 'VOUCH-PICKER-UI'
        [void](Invoke-CdpEval -Expression 'window.__inputs = []; true')
        Send-TestChord -Key 'z' -Code 90 -Modifiers 2 -KeyCode 'KeyZ'
        Send-TestChord -Key 'y' -Code 89 -Modifiers 2 -KeyCode 'KeyY'
        Send-TestChord -Key 'v' -Code 86 -Modifiers 2 -KeyCode 'KeyV'
        Send-TestChord -Key 'Insert' -Code 45 -Modifiers 8
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression "document.getElementById('q').value + '|' + JSON.stringify(window.__inputs) + '|' + window.__pastes" | Should -Be 'findzy|[]|0'
        # The keys were aimed at the layer and, being Ctrl combinations, kept their default (the browser's own shortcuts work).
        Invoke-CdpEval -Expression "JSON.stringify(window.__keyEvents.filter(function (e) { return e.ctrlKey && e.key !== 'Control'; }).map(function (e) { return e.key + ':' + e.defaultPrevented; }))" | Should -Be '["z:false","y:false","v:false"]'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'cancels the click of a page''s access key (Alt + letter), says so, and never picks from it' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        # Control: without a pick, Alt+K clicks the page's button.
        Send-TestChord -Key 'k' -Code 75 -Modifiers 1 -Text 'k' -KeyCode 'KeyK'
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '["accesskey"]'
        Open-TestPage "/pickme?x=$($script:Web2)"
        $before = Get-PageTrace
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        Send-TestChord -Key 'k' -Code 75 -Modifiers 1 -Text 'k' -KeyCode 'KeyK'
        Send-TestChord -Key 'j' -Code 74 -Modifiers 1 -Text 'j' -KeyCode 'KeyJ'
        Start-Sleep -Milliseconds 300
        # The control did not act: no handler ran, the checkbox did not change, the title is the same.
        Invoke-CdpEval -Expression "JSON.stringify(window.__hits) + '|' + document.getElementById('akcheck').checked + '|' + document.title" | Should -Be '[]|false|Pick me'
        # What Edge does not let a page script stop (the stated limit): the focus moved to the
        # page's control, and a listener of the site on window saw the click.
        Invoke-CdpEval -Expression 'document.activeElement.id' | Should -Be 'akcheck'
        Invoke-CdpEval -Expression 'JSON.stringify(window.__winHits)' | Should -Be '["click:akbtn","click:akcheck"]'
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -Be 'picking' -Because 'a click made by the browser for a key never picks'
        $r.notice | Should -Match 'shortcut of this page'
        # The person then picks with the mouse: what is under the pointer, not the access-key control.
        [void](Invoke-CdpEval -Expression 'window.__winHits = []; true')
        Send-TestClick (Get-TestPoint "document.getElementById('fav')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done'
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#fav'
        Assert-SiteUntouched
        [void](Invoke-CdpEval -Expression "document.activeElement.blur(); true")
        (Get-PageTrace) | Should -BeExactly $before
    }

    It 'keeps keys from a same-site frame that <Case> during the pick' -ForEach @(
        @{ Case = 'reloads'; Js = "new Promise(function (done) { var f = document.getElementById('sameframe'); f.addEventListener('load', function () { f.contentDocument.getElementById('framebtn').focus(); done(true); }, { once: true }); f.contentWindow.location.reload(); })"; Frame = "document.getElementById('sameframe')" }
        @{ Case = 'is added'; Js = "new Promise(function (done) { var f = document.createElement('iframe'); f.id = 'lateframe'; f.src = '/pickframe'; f.addEventListener('load', function () { f.contentDocument.getElementById('framebtn').focus(); done(true); }); document.body.prepend(f); })"; Frame = "document.getElementById('lateframe')" }
    ) {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        # The frame's new page focuses its own button as soon as it has loaded; Enter follows at once, several times over.
        foreach ($round in 1..4) {
            if ($round -gt 1 -and $Case -eq 'is added') { [void](Invoke-CdpEval -Expression "document.getElementById('lateframe').remove(); true") }
            [void](Invoke-CdpEval -Expression $Js -TimeoutSec 10)
            Send-TestChord -Key 'Enter' -Code 13 -Text "`r"
            Send-TestChord -Key ' ' -Code 32 -Text ' ' -KeyCode 'Space'
            Invoke-CdpEval -Expression "String(($Frame).contentDocument.body.getAttribute('data-clicks')) + '|' + JSON.stringify(window.__hits)" | Should -Be 'null|[]' -Because "round ${round}: the frame's new page must not get the key"
            Start-Sleep -Milliseconds (60 * $round)
        }
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        # The page then focuses a field of its own, back in the top page: left alone (no focus fight), keys still do nothing.
        [void](Invoke-CdpEval -Expression "document.getElementById('q').focus({ preventScroll: true }); true")
        Start-Sleep -Milliseconds 500
        Invoke-CdpEval -Expression 'document.activeElement.id' | Should -Be 'q'
        Send-TestChord -Key 'x' -Code 88 -Text 'x' -KeyCode 'KeyX'
        Invoke-CdpEval -Expression "document.getElementById('q').value" | Should -Be 'find'
        (Get-ElementPickResult -State $script:B).state | Should -Be 'picking'
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'takes the focus back from a frame hidden in a closed shadow root (its keys would never pass the picking layer)' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        [void](Invoke-CdpEval -TimeoutSec 10 -Expression "new Promise(function (done) { var c = document.createElement('div'); c.id = 'closedframe'; document.body.prepend(c); var r = c.attachShadow({ mode: 'closed' }); var f = document.createElement('iframe'); f.src = '/pickframe'; f.onload = function () { window.__cf = f; f.contentDocument.getElementById('framebtn').focus(); done(true); }; r.appendChild(f); })")
        Start-Sleep -Milliseconds 300
        Send-TestChord -Key 'Enter' -Code 13 -Text "`r"
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression "String(window.__cf.contentDocument.body.getAttribute('data-clicks')) + '|' + JSON.stringify(window.__hits)" | Should -Be 'null|[]'
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -BeIn 'picking', 'error'
        if ($r.state -eq 'error') { $r.code | Should -Be 'focus' }
        else { Invoke-CdpEval -Expression 'document.activeElement.tagName' | Should -Be 'VOUCH-PICKER-UI' }
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
    }

    It 'shields a page that reloads by itself during a pick until the picker is back: no click or key reaches the fresh page' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        $fav = Get-TestPoint "document.getElementById('fav')"
        $inFrame = Get-TestPoint "document.getElementById('sameframe').contentDocument.getElementById('framebtn')"
        [void](Start-ElementPick -State $script:B -Mode click)
        Start-Sleep -Milliseconds 300
        $ready = "new Promise(function (done) { var t = function () { (document.readyState === 'complete' && window.__hits && document.getElementById('sameframe').contentDocument.getElementById('framebtn')) ? done(true) : setTimeout(t, 20); }; t(); })"
        # The page reloads itself. The server is NOT asked in between (no poll), so the picker is not back yet.
        [void](Send-CdpCommand -Method 'Page.reload')
        [void](Invoke-CdpEval -Expression $ready -TimeoutSec 10)
        Invoke-CdpEval -Expression "typeof window.__vouchPicker + '|' + !!(window.__vouchPicker && window.__vouchPicker.shield) + '|' + document.querySelectorAll('vouch-picker-ui').length" | Should -Be 'object|true|0'
        Send-TestClick $fav
        Send-TestClick $inFrame
        [void](Invoke-CdpEval -Expression "document.getElementById('akbtn').focus({ preventScroll: true }); true")
        Send-TestChord -Key 'Enter' -Code 13 -Text "`r"
        [void](Invoke-CdpEval -Expression "document.getElementById('q').focus({ preventScroll: true }); true")
        Send-TestChord -Key 'x' -Code 88 -Text 'x' -KeyCode 'KeyX'
        [void](Send-CdpCommand -Method 'Input.insertText' -Params @{ text = 'X' })
        Start-Sleep -Milliseconds 200
        Invoke-CdpEval -Expression "document.getElementById('q').value + '|' + String(document.getElementById('sameframe').contentDocument.body.getAttribute('data-clicks'))" | Should -Be 'find|null'
        # The shield came before every listener of the site: not even those on window saw anything.
        Assert-SiteUntouched
        # The next poll puts the picker back (it replaces the shield), and picking goes on.
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -Be 'picking'
        Start-Sleep -Milliseconds 300
        Invoke-CdpEval -Expression "!!window.__vouchPicker.shield + '|' + document.querySelectorAll('vouch-picker-ui').length + '|' + typeof document.getElementById('sameframe').contentWindow.__vouchPicker" | Should -Be 'false|1|undefined'
        Send-TestClick (Get-TestPoint "document.getElementById('fav')")
        $r = Wait-TestPick
        $r.state | Should -Be 'done' -Because "$($r['message']) $($r['notice'])"
        @($r.result.candidates | ForEach-Object { $_.value }) | Should -Contain '#fav'
        Assert-SiteUntouched
        # After the pick the shield is taken back: a page loaded now is the site's own again, at once.
        [void](Send-CdpCommand -Method 'Page.reload')
        [void](Invoke-CdpEval -Expression $ready -TimeoutSec 10)
        Invoke-CdpEval -Expression 'typeof window.__vouchPicker' | Should -Be 'undefined'
        Send-TestClick (Get-TestPoint "document.getElementById('fav')")
        Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '["fav"]'
    }

    It 'lets the shield end by itself after 4 seconds, so a page is never left dead if the picker does not come back' {
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        try {
            [void](Send-CdpCommand -Method 'Page.reload')
            Start-Sleep -Milliseconds 1500
            Invoke-CdpEval -Expression '!!(window.__vouchPicker && window.__vouchPicker.shield)' | Should -BeTrue
            Start-Sleep -Milliseconds 3200
            Invoke-CdpEval -Expression 'typeof window.__vouchPicker' | Should -Be 'undefined'
            Send-TestClick (Get-TestPoint "document.getElementById('fav')")
            Invoke-CdpEval -Expression 'JSON.stringify(window.__hits)' | Should -Be '["fav"]'
        }
        finally {
            [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
            $script:B.Pick.ShieldId | Should -BeNullOrEmpty
        }
    }

    It 'says to type it in the Designer when the page changes under every click, and clears a note at the next press' {
        Open-TestPage "/pickme?x=$($script:Web2)&swapOnUp=1"
        [void](Start-ElementPick -State $script:B -Mode click)
        # Each click swaps whatever is under it again: make a new target for each round.
        foreach ($n in 1..3) {
            [void](Invoke-CdpEval -Expression "if (!document.getElementById('reports-a')) { var a = document.createElement('a'); a.id = 'reports-a'; a.href = '/ok'; a.textContent = 'Reports'; document.getElementById('navrow').prepend(a); } true")
            Send-TestClick (Get-TestPoint "document.getElementById('reports-a')")
            Start-Sleep -Milliseconds 300
        }
        $r = Get-ElementPickResult -State $script:B
        $r.state | Should -Be 'picking'
        $r.notice | Should -Match 'keeps changing under the pointer'
        $p = Get-TestPoint "document.getElementById('spacer')"
        [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mousePressed'; x = [double]$p.x; y = [double]$p.y; button = 'left'; clickCount = 1 })
        Start-Sleep -Milliseconds 300
        (Get-ElementPickResult -State $script:B).notice | Should -BeNullOrEmpty
        [void](Invoke-TestRoute POST '/api/pick/cancel' -State $script:B)
        [void](Send-CdpCommand -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseReleased'; x = [double]$p.x; y = [double]$p.y; button = 'left'; clickCount = 1 })
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
        # A pick in between turns the browser's Page domain on and off (for its shield): the preview stays as it is.
        [void](Start-ElementPick -State $script:B -Mode click)
        $script:B.Pick.ShieldId | Should -Not -BeNullOrEmpty
        (Invoke-TestRoute POST '/api/pick/cancel' -State $script:B).Data.state | Should -Be 'cancelled'
        $script:B.Pick.ShieldId | Should -BeNullOrEmpty
        [int](Invoke-CdpEval -Expression 'window.innerWidth') | Should -Be ($base * 2)
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
        $script:B.Browser.LastSweep = [datetime]::MinValue   # the 4 s sweep throttle
        Update-DesignerBrowser -State $script:B -Force
        $script:B.Browser.TabId | Should -Be $second.id
        $script:B.Browser.Title | Should -Be 'Tabs'
        foreach ($url in 'edge://version', "http://localhost:$($script:B.Port)/") {
            $other = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($script:PickCdp)/json/new?$url" -NoProxy
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$($other.id)" -NoProxy)
            Start-Sleep -Milliseconds 500
            $script:B.Browser.LastSweep = [datetime]::MinValue   # the 4 s sweep throttle
            Update-DesignerBrowser -State $script:B -Force
            $script:B.Browser.TabId | Should -Be $second.id -Because "$url must be ignored"
            @($script:B.Browser.Tabs | ForEach-Object { $_.id }) | Should -Not -Contain $other.id
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/close/$($other.id)" -NoProxy)
        }
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$first" -NoProxy)
        Start-Sleep -Milliseconds 500
        $script:B.Browser.LastSweep = [datetime]::MinValue   # the 4 s sweep throttle
        Update-DesignerBrowser -State $script:B -Force
        $script:B.Browser.TabId | Should -Be $first
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/close/$($second.id)" -NoProxy)
    }

    It 'ends a pick plainly when its tab is closed, and moves to the tab that is left' {
        $extra = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($script:PickCdp)/json/new?$($script:Base)/ok" -NoProxy
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/activate/$($script:B.Browser.TabId)" -NoProxy)
        Start-Sleep -Milliseconds 300
        $script:B.Browser.LastSweep = [datetime]::MinValue   # the 4 s sweep throttle
        Update-DesignerBrowser -State $script:B -Force
        $picked = $script:B.Browser.TabId
        Open-TestPage "/pickme?x=$($script:Web2)"
        [void](Start-ElementPick -State $script:B -Mode click)
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$($script:PickCdp)/json/close/$picked" -NoProxy)
        $r = Wait-TestPick
        $r.state | Should -Be 'error'
        $r.code | Should -Be 'tab'
        $r.message | Should -Match 'was closed'
        $script:B.Browser.LastSweep = [datetime]::MinValue   # the 4 s sweep throttle
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
D.selectPage(n);
const going = D.goToUrl(n);
const busyGo = { text: btnByKey('go').textContent, disabled: btnByKey('go').getAttribute('aria-disabled') };
await going;
const idleGo = btnByKey('go').textContent;
await until(() => S.browser.zoom && S.browser.zoom.percent === 50, 6000);
const zoomText = document.querySelector('#browser-strip').textContent;
btnByKey('bs-zoomoff').click();
await until(() => S.browser.zoom.percent === 100, 6000);
const after = document.querySelector('#browser-strip').textContent;
delete S.config.pages[n].overrides;
S.config.pages[n].url = '$($script:WebBase)/tabs';
await D.goToUrl(n);
return { zoomText, after, busyGo, idleGo };
"@
        $r.busyGo.text | Should -Be 'Opening…'
        $r.busyGo.disabled | Should -Be 'true'
        $r.idleGo | Should -Be 'Go'
        $r.zoomText | Should -Match 'Zoom preview'
        $r.zoomText | Should -Match '50%'
        $r.zoomText | Should -Match 'the run.s zoom'
        $r.zoomText | Should -Match 'layout may differ'
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

    It 'cancels the pick in the browser and says so when the Designer stops answering the poll' {
        $r = Invoke-UiPanel @'
const realFetch = window.fetch;
let cancelled = 0;
try {
  btnByKey('pick-click').click();
  await until(() => document.querySelector('#picking').open, 8000);
  window.fetch = (url, options) => {
    if (url === '/api/pick' && (!options || options.method === 'GET')) return Promise.reject(new TypeError('network down'));
    if (url === '/api/pick/cancel') cancelled++;
    return realFetch(url, options);
  };
  const shown = await until(() => document.querySelector('#modal').open, 8000);
  const title = document.querySelector('#modal-title').textContent;
  document.querySelector('#modal-buttons .btn').click();
  return { shown: !!shown, title, cancelled, picking: document.querySelector('#picking').open };
} finally { window.fetch = realFetch; }
'@
        $r.shown | Should -BeTrue
        $r.title | Should -Match 'Picking stopped'
        $r.cancelled | Should -Be 1
        $r.picking | Should -BeFalse
        Start-Sleep -Milliseconds 500
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

Describe 'Runs from the panel: routes, plan and rules (no browser, no child)' {
    BeforeAll {
        $script:R = New-TestState
        $script:R.SessionFolder = Join-Path $TestDrive 'runs-unit'
        function New-RunConfig {
            $config = Get-DefaultVouchConfig
            $config['pages'].Add([ordered]@{ id = 'p001'; name = 'One'; url = 'https://example.com/1' })
            $config['pages'].Add([ordered]@{ id = 'p002'; name = 'Two'; url = 'https://example.com/2'; enabled = $false })
            return $config
        }
    }
    AfterEach { $script:R.Run = New-DesignerRunState; $script:R.Browser.Connected = $false }

    It 'answers GET /api/run with the idle run, and reads "since" from the query string' {
        $r = Invoke-TestRoute GET '/api/run' -State $script:R
        $r.Status | Should -Be 200
        $r.Data.state | Should -Be 'idle'
        @($r.Data.events).Count | Should -Be 0
        $r.Data.next | Should -Be 0
        Get-DesignerQueryNumber -Query '?since=12' -Name 'since' | Should -Be 12
        Get-DesignerQueryNumber -Query '?a=1&since=7' -Name 'since' | Should -Be 7
        Get-DesignerQueryNumber -Query '?since=x' -Name 'since' | Should -Be 0
        Get-DesignerQueryNumber -Query '' -Name 'since' | Should -Be 0
    }

    It 'slices the events from "since" on, at most 500 at a time' {
        $run = New-DesignerRunState
        $run.Number = 1; $run.State = 'done'
        for ($i = 0; $i -lt 620; $i++) { $run.Events.Add([ordered]@{ type = 'detail'; n = $i }) }
        $script:R.Run = $run
        $first = ConvertFrom-TestBody (Invoke-DesignerRequest -Method GET -Path '/api/run' -Query '?since=0' -State $script:R)
        @($first.events).Count | Should -Be 500
        $first.next | Should -Be 500
        $rest = ConvertFrom-TestBody (Invoke-DesignerRequest -Method GET -Path '/api/run' -Query "?since=$($first.next)" -State $script:R)
        @($rest.events).Count | Should -Be 120
        $rest.events[0].n | Should -Be 500
        $rest.next | Should -Be 620
    }

    It 'refuses to run without the audit browser (409, with the reason)' {
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = (New-RunConfig); kind = 'full' }) -State $script:R
        $r.Status | Should -Be 409
        $r.Data.code | Should -Be 'no-browser'
    }

    It 'refuses a run with problems with the messages Save shows (422), and starts nothing' {
        $script:R.Browser.Connected = $true
        $config = New-RunConfig
        $config['pages'][0]['url'] = 'intranet.example.com'
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $config; kind = 'full' }) -State $script:R
        $r.Status | Should -Be 422
        $r.Data.code | Should -Be 'invalid'
        $r.Data.error | Should -Match 'problem\(s\), so it was not run'
        $save = Invoke-TestRoute POST '/api/config/save' ([ordered]@{ config = $config; path = '' }) -State $script:R
        ($r.Data.errors | ForEach-Object { $_.message }) | Should -Be ($save.Data.errors | ForEach-Object { $_.message })
        $script:R.Run.State | Should -Be 'idle'
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $config; kind = 'page'; pageId = 'p001' }) -State $script:R
        $r.Data.error | Should -Match 'so it was not tested'
    }

    It 'refuses an unknown kind (400), a page that is not there (400) and a path not handed out (403)' {
        $script:R.Browser.Connected = $true
        (Invoke-TestRoute POST '/api/run' ([ordered]@{ config = (New-RunConfig); kind = 'everything' }) -State $script:R).Status | Should -Be 400
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = (New-RunConfig); kind = 'page'; pageId = 'p999' }) -State $script:R
        $r.Status | Should -Be 400
        $r.Data.code | Should -Be 'page'
        foreach ($route in '/api/run', '/api/run/plan') {
            (Invoke-TestRoute POST $route ([ordered]@{ config = (New-RunConfig); path = 'C:\Windows\win.ini'; kind = 'full' }) -State $script:R).Status | Should -Be 403
            $request = New-DesignerRequest -Method POST -Path $route -Headers (New-GoodHeaders $script:R -Post) -BodyText '{"path":"C:\\Windows\\win.ini","config":{}}'
            (Test-DesignerRequest -Request $request -State $script:R).Status | Should -Be 403
        }
        $script:R.Run.State | Should -Be 'idle'
    }

    It 'keeps every run route behind the gate: <_>' -ForEach @('POST /api/run', 'GET /api/run', 'POST /api/run/stop', 'POST /api/run/plan', 'GET /preview/0123/001_a.jpg') {
        $method, $path = $_ -split ' ', 2
        $headers = New-GoodHeaders $script:R -Post:($method -eq 'POST')
        $headers.Remove('X-Vouch-Token')
        $request = New-DesignerRequest -Method $method -Path $path -Headers $headers -BodyText '{}'
        $refusal = Test-DesignerRequest -Request $request -State $script:R
        $refusal.Status | Should -Be 403
        (ConvertFrom-TestBody $refusal).code | Should -Be 'token'
        $headers = New-GoodHeaders $script:R -Post:($method -eq 'POST')
        $headers['Origin'] = 'https://evil.example'
        (Test-DesignerRequest -Request (New-DesignerRequest -Method $method -Path $path -Headers $headers -BodyText '{}') -State $script:R).Status | Should -Be 403
    }

    It 'answers 409 to a stop with nothing running, and 405 for a POST to a preview' {
        $r = Invoke-TestRoute POST '/api/run/stop' -State $script:R
        $r.Status | Should -Be 409
        $r.Data.code | Should -Be 'not-running'
        (Invoke-TestRoute POST '/preview/abc/x.jpg' -State $script:R).Status | Should -Be 405
        (Invoke-TestRoute GET '/api/run/stop' -State $script:R).Status | Should -Be 405
        (Invoke-TestRoute GET '/api/run/plan' -State $script:R).Status | Should -Be 405
    }

    It 'plans a run of a configuration never saved: folders from Documents\Vouch, "unsaved", the switches it adds' {
        $script:R.Browser.Connected = $true; $script:R.Browser.TabId = 'TAB-9'; $script:R.Browser.Port = 9555; $script:R.Browser.ProfileDir = 'C:\Audit'
        $r = Invoke-TestRoute POST '/api/run/plan' ([ordered]@{ config = (New-RunConfig); kind = 'full' }) -State $script:R
        $r.Status | Should -Be 200
        $documents = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Vouch'
        $r.Data.saved | Should -BeFalse
        $r.Data.unsaved | Should -BeTrue
        $r.Data.baseFolder | Should -Be $documents
        $r.Data.outputFolder | Should -Be (Join-Path $documents 'reports')
        ($r.Data.notes -join ' ') | Should -Match 'has not been saved yet'
        $r.Data.sessionFlags | Should -Contain 'The tab the Designer shows (-TabId).'
        ($r.Data.sessionFlags -join ' ') | Should -Match '-EventLogPath'
        ($r.Data.sessionFlags -join ' ') | Should -Match '-DebugPort 9555'
        $page = Invoke-TestRoute POST '/api/run/plan' ([ordered]@{ config = (New-RunConfig); kind = 'page'; pageId = 'p002' }) -State $script:R
        $page.Data.pageName | Should -Be 'Two'
        ($page.Data.sessionFlags -join ' ') | Should -Match '-Only:p002'
        ($page.Data.sessionFlags -join ' ') | Should -Match '-Zip:\$false'
        ($page.Data.sessionFlags -join ' ') | Should -Match '-OpenReport:\$false'
        ($page.Data.notes -join ' ') | Should -Match 'temporary preview folder'
    }

    It 'plans a saved configuration against its own folder, and sees whether the shown one differs from the file' {
        $folder = Join-Path $TestDrive 'plan saved'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $config = New-RunConfig
        $config['output']['dir'] = 'out\evidence'
        $config['report']['logoPath'] = 'logo.png'
        $file = Join-Path $folder 'c.json'
        [void](Save-VouchConfig -Config $config -Path $file)
        $known = Add-DesignerKnownPath -State $script:R -Path $file -Kind config
        $r = Invoke-TestRoute POST '/api/run/plan' ([ordered]@{ config = $config; path = $known; kind = 'full' }) -State $script:R
        $r.Data.saved | Should -BeTrue
        $r.Data.unsaved | Should -BeFalse
        $r.Data.outputFolder | Should -Be (Join-Path $folder 'out\evidence')
        $config['report']['title'] = 'Edited, not saved'
        (Invoke-TestRoute POST '/api/run/plan' ([ordered]@{ config = $config; path = $known; kind = 'full' }) -State $script:R).Data.unsaved | Should -BeTrue
        $resolved = Resolve-DesignerRunConfig -Config $config -BaseFolder $folder
        $resolved.Config['report']['logoPath'] | Should -Be (Join-Path $folder 'logo.png')
        $resolved.Config['output']['dir'] | Should -Be (Join-Path $folder 'out\evidence')
        $resolved.Config['report']['title'] | Should -Be 'Edited, not saved'
        # Nothing but the four paths changes; the shown configuration itself is not touched.
        $config['output']['dir'] | Should -Be 'out\evidence'
    }

    It 'plans the virtual desktop: <Case>' -ForEach @(
        @{ Case = 'a full run with the Edge the Designer opened'; Kind = 'full'; Launched = $true; Expect = 'used'; Words = 'closes the audit Edge it opened'; Flag = $false }
        @{ Case = 'a full run with an Edge the Designer found'; Kind = 'full'; Launched = $false; Expect = 'skipped'; Words = 'does not use a separate virtual desktop'; Flag = $true }
        @{ Case = 'a page test'; Kind = 'page'; Launched = $true; Expect = 'ignored'; Words = 'never uses a separate virtual desktop'; Flag = $true }
    ) {
        $script:R.Browser.LaunchedByDesigner = $Launched
        $script:R.Browser.LaunchedPid = $(if ($Launched) { 4242 } else { 0 })
        $config = New-RunConfig
        $config['browser']['useVirtualDesktop'] = $true
        $plan = Get-DesignerRunPlan -State $script:R -Config $config -Kind $Kind -PageId 'p001'
        $plan.VirtualDesktop | Should -Be $Expect
        ($plan.Notes -join ' ') | Should -Match $Words
        $flags = Get-DesignerRunSessionFlag -State $script:R -Plan $plan -EventPath 'e' -PreviewFolder 'p' -TabId 'T'
        $arguments = @($flags | ForEach-Object { $_.Arguments })
        ($arguments -contains '-UseVirtualDesktop:$false') | Should -Be $Flag
        (@($arguments | Where-Object { $_ -like '-TabId:*' }).Count -gt 0) | Should -Be ($Expect -ne 'used')
        $script:R.Browser.LaunchedByDesigner = $false; $script:R.Browser.LaunchedPid = 0
    }

    It 'gives the run''s arguments as an array that the shown command spells out exactly' {
        $file = Join-Path $TestDrive 'Prüfung $x `y & ''z'' 100% (Q3)\c.json'
        $command = Get-VouchCommandLine -Config (New-RunConfig) -ConfigPath $file -ScriptPath $script:VouchPath
        $command.RunArguments | Should -Be @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:VouchPath, '-ConfigPath', $file)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($command.Run, [ref]$null, [ref]$null)
        $elements = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements
        $values = @($elements | ForEach-Object { if ($_ -is [System.Management.Automation.Language.CommandParameterAst]) { '-' + $_.ParameterName } else { $_.SafeGetValue() } })
        $values | Should -Be (@('pwsh') + $command.RunArguments)
    }

    It 'answers 409 to every browser route while a run is going, and to a second run' {
        $script:R.Run.State = 'running'
        foreach ($route in 'GET /api/browser/current', 'POST /api/browser/connect', 'POST /api/browser/navigate', 'POST /api/browser/layout',
            'POST /api/browser/zoom-off', 'POST /api/page/from-current', 'POST /api/pick/start', 'POST /api/action/test') {
            $method, $path = $route -split ' ', 2
            $r = Invoke-TestRoute $method $path ([ordered]@{ url = 'https://example.com/'; mode = 'click'; action = [ordered]@{ type = 'wait'; seconds = 1 } }) -State $script:R
            $r.Status | Should -Be 409 -Because $route
            $r.Data.code | Should -Be 'running'
            $r.Data.error | Should -Be 'A run is using the audit browser.'
        }
        $script:R.Browser.Connected = $true
        (Invoke-TestRoute POST '/api/run' ([ordered]@{ config = (New-RunConfig); kind = 'full' }) -State $script:R).Data.code | Should -Be 'running'
        # Editing and saving go on.
        (Invoke-TestRoute POST '/api/config/validate' ([ordered]@{ config = (New-RunConfig) }) -State $script:R).Status | Should -Be 200
        $state = (Invoke-TestRoute GET '/api/state' -State $script:R).Data
        $state.run.state | Should -Be 'running'
        $state.capabilities.run | Should -BeTrue
        $script:R.Browser.Connected = $false
        $state = (Invoke-TestRoute GET '/api/state' -State $script:R).Data
        $state.browser.inRun | Should -BeTrue
        $state.browser.message | Should -Match 'A run is using the audit Edge'
        $state.capabilities.pick | Should -BeFalse
        # The tick leaves the browser alone.
        Mock Update-DesignerBrowser { throw 'The tick looked at the browser during a run.' }
        Mock Connect-DesignerBrowser { throw 'The tick reconnected during a run.' }
        $script:R.Browser.ConnectPending = $true
        Invoke-DesignerBrowserTick -State $script:R
        Should -Invoke Update-DesignerBrowser -Times 0
        Should -Invoke Connect-DesignerBrowser -Times 0
        $script:R.Browser.ConnectPending = $false
    }

    It 'refuses to shut down in the middle of a run unless asked to stop it' {
        $script:R.Run.State = 'running'
        $r = Invoke-TestRoute POST '/api/shutdown' -State $script:R
        $r.Status | Should -Be 409
        $script:R.Running | Should -BeTrue
    }

    It 'reads complete lines only: a split line waits for its end, garbage and over-long lines are skipped' {
        $run = New-DesignerRunState
        $run.EventPath = Join-Path $TestDrive 'manual.ndjson'
        $state = New-TestState
        $append = { param($t) [System.IO.File]::AppendAllText($run.EventPath, $t, [System.Text.UTF8Encoding]::new($false)) }
        Read-DesignerRunEvent -State $state -Run $run | Should -Be 0
        & $append '{"type":"runStart","runId":"r1"'
        Read-DesignerRunEvent -State $state -Run $run | Should -Be 0
        $run.Pending.Length | Should -BeGreaterThan 0
        & $append ("}`n" + '{"type":"pageStart","pageId":"p1","name":"Ä & ''b''","index":1,"total":1}' + "`nnot json`n[1]`n`n")
        Read-DesignerRunEvent -State $state -Run $run | Should -Be 2
        $run.Skipped | Should -Be 2
        $run.State = 'starting'
        $run.Pages['id:p1'].name | Should -Be "Ä & 'b'"
        # A line over the limit, read in small pieces, is dropped as a whole; the next one counts.
        & $append (('{"type":"detail","text":"' + ('y' * 300) + '"}') + "`n" + '{"type":"pageEnd","pageId":"p1","status":"OK","details":[],"captureCount":0}' + "`n")
        $added = 0
        for ($turn = 0; $turn -lt 20; $turn++) { $added += Read-DesignerRunEvent -State $state -Run $run -MaxBytes 64 -MaxLineBytes 100 }
        $added | Should -Be 1
        $run.Skipped | Should -Be 3
        $run.Pages['id:p1'].status | Should -Be 'OK'
        $state.PageResults['p1'].status | Should -Be 'OK'
        # At the end, an unfinished last line is lost, not half-read.
        & $append '{"type":"runEnd","exitCode":0'
        Read-DesignerRunEvent -State $state -Run $run -Final | Should -Be 0
        $run.Skipped | Should -Be 4
        $run.RunEnd | Should -BeNullOrEmpty
    }

    It 'puts the exit code into words: <Code>' -ForEach @(
        @{ Code = 0; RunEnd = $true; Words = 'Finished: every page was captured' }
        @{ Code = 2; RunEnd = $true; Words = 'page\(s\) failed' }
        @{ Code = 3; RunEnd = $true; Words = 'Fail on warnings' }
        @{ Code = 1; RunEnd = $true; Words = 'could not start: Edge has no tab' }
        @{ Code = 9; RunEnd = $false; Words = 'ended unexpectedly \(exit code 9\)' }
    ) {
        $run = New-DesignerRunState
        $run.ErrorMessage = 'Edge has no tab'
        if ($RunEnd) { $run.RunEnd = [ordered]@{ type = 'runEnd' }; $run.Counts = [ordered]@{ pages = 2; run = 2; ok = 1; warning = 0; failed = 1; notRun = 0; captures = 1 } }
        else { $run.Pages['id:p1'] = [ordered]@{} }
        Get-DesignerRunOutcome -Run $run -ProcessExitCode $Code | Should -Match $Words
    }
}

Describe 'Runs with a stand-in child process (the run state machine)' -Tag 'Integration' {
    BeforeAll {
        function New-RunTestState([string]$Name) {
            $state = New-TestState
            $state.RunScriptPath = $script:FakeChildPath
            $state.SessionFolder = Join-Path $TestDrive $Name
            return $state
        }
        function New-RunTestConfig([string]$Scenario) {
            $config = Get-DefaultVouchConfig
            $config['name'] = "fake:$Scenario"
            $config['defaults']['navigationTimeoutSec'] = 5
            $config['pages'].Add([ordered]@{ id = 'p001'; name = 'One'; url = 'http://localhost/1' })
            $config['pages'].Add([ordered]@{ id = 'p002'; name = 'Two'; url = 'http://localhost/2' })
            return $config
        }
        function Start-TestRun([object]$State, [string]$Scenario, [string]$Kind = 'full', [string]$PageId = '', [object]$Config = $null) {
            if ($null -eq $Config) { $Config = New-RunTestConfig $Scenario }
            $plan = Get-DesignerRunPlan -State $State -Config $Config -Kind $Kind -PageId $PageId
            return Start-DesignerRun -State $State -Plan $plan
        }
        function Wait-TestRun([object]$State, [int]$TimeoutSec = 30, [scriptblock]$Until = $null) {
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                Update-DesignerRun -State $State
                if ($null -ne $Until) { if (& $Until) { break } }
                elseif (-not (Test-DesignerRunActive -State $State)) { break }
                Start-Sleep -Milliseconds 100
            }
            return Get-DesignerRunData -State $State
        }
        function Get-EventType([object]$Data) { return @($Data.events | ForEach-Object { $_['type'] }) }
        $script:Started = [System.Collections.Generic.List[object]]::new()
    }
    AfterAll {
        foreach ($run in $script:Started) { if ($null -ne $run.Process) { Stop-DesignerChildProcess -Process $run.Process } }
    }

    It 'follows a normal run: events in order, each page''s result, the counts, and this run''s paths only' {
        $state = New-RunTestState 'normal'
        $state.OpenTargets['report'] = 'C:\old\report.html'
        $run = Start-TestRun $state 'normal'
        $script:Started.Add($run)
        $run.State | Should -Be 'starting'
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.exitCode | Should -Be 0
        Get-EventType $data | Should -Be @('runStart', 'pageStart', 'capture', 'pageEnd', 'pageStart', 'detail', 'capture', 'pageEnd', 'runEnd')
        @($data.pages).Count | Should -Be 2
        $data.pages[0].status | Should -Be 'OK'
        $data.pages[0].name | Should -Be "Page 1 'quoted' & é"
        $data.pages[1].status | Should -Be 'WARNING'
        $data.pages[1].details | Should -Be @('Page truncated at 3 segments (raise -MaxScrollSegments to capture more).')
        $data.pages[1].captureCount | Should -Be 1
        $data.counts.warning | Should -Be 1
        $data.message | Should -Match '2 page\(s\) captured, 1 with warnings'
        $state.OpenTargets['report'] | Should -Be $data.reportPath
        $state.OpenTargets['folder'] | Should -Be (Split-Path $data.reportPath -Parent)
        $state.OpenTargets['log'] | Should -Be $data.logPath
        $state.OpenTargets.Contains('zip') | Should -BeFalse
        $data.pageResults['p002'].status | Should -Be 'WARNING'
        $data.pageResults['p002'].kind | Should -Be 'full'
        $data.pageResults['p002'].time | Should -Match '^\d\d:\d\d$'
        # The configuration copy and the stop file are gone; the saved file was never involved.
        $run.ConfigTempPath | Should -Not -Exist
        $run.StopPath | Should -Not -Exist
        $run.Process | Should -BeNullOrEmpty
    }

    It 'passes the shown command''s arguments plus the session flags, hazardous values intact' {
        $state = New-RunTestState 'Sess ''q'' $x %USERNAME% & é `b (1)'
        $state.Browser.Connected = $true
        $state.Browser.TabId = 'TAB-1'
        $state.Browser.Port = 9555
        $state.Browser.ProfileDir = 'C:\Audit "Profile" it''s $x %USERNAME% & é'
        Mock Connect-DesignerBrowser { $State.Browser.Connected = $true; $State.Browser.TabId = 'TAB-1' }
        Mock Set-DesignerLayout { [pscustomobject]@{ Ok = $true; Message = '' } }
        Mock Clear-PageZoom { }
        $run = Start-TestRun $state 'normal'
        $script:Started.Add($run)
        $state.Browser.Connected | Should -BeFalse
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $command = Get-VouchCommandLine -Config (New-RunTestConfig 'normal') -ConfigPath $run.ConfigTempPath -ScriptPath $script:FakeChildPath
        $flags = @("-EventLogPath:$($run.EventPath)", '-TabId:TAB-1', '-DebugPort:9555', "-EdgeProfileDir:$($state.Browser.ProfileDir)")
        $run.Arguments | Should -Be (@($command.RunArguments) + $flags)
        $received = @(Get-Content -Raw -LiteralPath "$($run.EventPath).args.json" | ConvertFrom-Json)
        $received | Should -Be (@($command.RunArguments | Select-Object -Skip 5) + $flags)
        # Connected again afterwards, to the same tab.
        Should -Invoke Connect-DesignerBrowser -Times 1 -Exactly
        $state.Browser.TabId | Should -Be 'TAB-1'
    }

    It 'shows the person is answering the Vouch dialog while a prompt has no answer yet' {
        $state = New-RunTestState 'prompt'
        $run = Start-TestRun $state 'prompt'
        $script:Started.Add($run)
        $data = Wait-TestRun $state -Until { (Get-DesignerRunData -State $state).state -eq 'waitingForUser' }
        $data.state | Should -Be 'waitingForUser'
        $data.prompt.title | Should -Be 'Vouch has paused'
        (Get-DesignerRunSummary -State $state).state | Should -Be 'waitingForUser'
        [System.IO.File]::WriteAllText("$($run.EventPath).answer", '')
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.prompt | Should -BeNullOrEmpty
        Get-EventType $data | Should -Contain 'promptResult'
    }

    It 'reports a failing page: exit code 2 in words' {
        $state = New-RunTestState 'failpage'
        $script:Started.Add((Start-TestRun $state 'failpage'))
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.exitCode | Should -Be 2
        $data.pages[1].status | Should -Be 'FAILED'
        $data.message | Should -Be 'Finished, but 1 page(s) failed. The report shows what went wrong on each.'
    }

    It 'stops a run cleanly through its stop file; the report is still written' {
        $state = New-RunTestState 'stop'
        $run = Start-TestRun $state 'stop'
        $script:Started.Add($run)
        [void](Wait-TestRun $state -Until { @((Get-DesignerRunData -State $state).pages).Count -ge 2 })
        $r = Invoke-TestRoute POST '/api/run/stop' -State $state
        $r.Status | Should -Be 200
        $r.Data.state | Should -Be 'stopping'
        $r.Data.stopRequested | Should -BeTrue
        $r.Data.forceAvailable | Should -BeFalse
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.stopped | Should -BeTrue
        $data.counts.notRun | Should -BeGreaterThan 0
        $data.message | Should -Match '^Stopped by you after \d of 6 page\(s\)'
        $data.reportPath | Should -Exist
        $run.StopPath | Should -Not -Exist
    }

    It 'offers Force stop only after the grace time, then ends the child''s process tree' {
        $state = New-RunTestState 'ignorestop'
        $run = Start-TestRun $state 'ignorestop'
        $script:Started.Add($run)
        $childId = $run.ProcessId
        [void](Wait-TestRun $state -Until { (Get-DesignerRunData -State $state).state -eq 'running' })
        $run.GraceSec | Should -Be 35
        $run.GraceSec = 2
        (Invoke-TestRoute POST '/api/run/stop' -State $state).Status | Should -Be 200
        $early = Invoke-TestRoute POST '/api/run/stop' ([ordered]@{ force = $true }) -State $state
        $early.Status | Should -Be 409
        $early.Data.code | Should -Be 'too-early'
        $data = Wait-TestRun $state -Until { (Get-DesignerRunData -State $state).forceAvailable }
        $data.forceAvailable | Should -BeTrue
        $r = Invoke-TestRoute POST '/api/run/stop' ([ordered]@{ force = $true }) -State $state
        $r.Status | Should -Be 200
        $r.Data.state | Should -Be 'failed'
        $r.Data.message | Should -Match 'force-stopped the run. Its report may be missing'
        $r.Data.nextStep | Should -Match 'Run it again'
        # The page that was going is not shown as captured.
        $r.Data.pages[0].status | Should -Be 'NOTFINISHED'
        $r.Data.pages[0].details | Should -Contain 'The run ended before this page finished.'
        $state.PageResults['p001'].status | Should -Be 'NOTFINISHED'
        Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $run.StopPath | Should -Not -Exist
    }

    It 'reports a run that died without its end as failed, with what it said: <Scenario>' -ForEach @(
        @{ Scenario = 'die'; Words = '(?s)ended unexpectedly \(exit code 7\).*Something broke badly inside the run' }
        @{ Scenario = 'nothing'; Words = '^The run could not start: The configuration file could not be read' }
        @{ Scenario = 'failstart'; Words = '^The run could not start: Edge has no open tab' }
    ) {
        $state = New-RunTestState $Scenario
        $script:Started.Add((Start-TestRun $state $Scenario))
        $data = Wait-TestRun $state
        $data.state | Should -Be 'failed'
        $data.message | Should -Match $Words
        $data.errorText | Should -Not -BeNullOrEmpty
        $data.nextStep | Should -Match 'copy the command below into a PowerShell window'
        $state.OpenTargets.Contains('report') | Should -BeFalse
        foreach ($page in @($data.pages)) { $page.status | Should -Be 'NOTFINISHED' }
        if ($Scenario -eq 'die') { $data.pages[0].name | Should -Be 'Doomed'; $data.pageResults['p001'].status | Should -Be 'NOTFINISHED' }
    }

    It 'reads non-ASCII text from a run that fails before it can say why (the child''s console code page)' {
        $state = New-RunTestState 'Sitzung Ärger é'
        $folder = Join-Path $TestDrive 'Prüfung Ärger'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        # A script whose -ConfigPath is a number: pwsh itself refuses the path, naming it.
        $script = Join-Path $folder 'refuses.ps1'
        [System.IO.File]::WriteAllText($script, "param([int]`$ConfigPath, [Parameter(ValueFromRemainingArguments)]`$Rest)`n'never'`n", [System.Text.UTF8Encoding]::new($false))
        $state.RunScriptPath = $script
        $script:Started.Add((Start-TestRun $state 'normal'))
        $data = Wait-TestRun $state
        $data.state | Should -Be 'failed'
        $data.message | Should -Match '^The run could not start: '
        $data.errorText | Should -Match ([regex]::Escape('Sitzung Ärger é'))
    }

    It 'always ends a run and hands the browser back, even when handling its end fails' {
        $state = New-RunTestState 'complete-fails'
        $state.Browser.Connected = $true
        $state.Browser.TabId = 'TAB-1'
        Mock Register-DesignerPreview { throw 'The preview could not be registered.' }
        Mock Connect-DesignerBrowser { $State.Browser.Connected = $true; $State.Browser.TabId = 'TAB-1' }
        Mock Set-DesignerLayout { [pscustomobject]@{ Ok = $true; Message = '' } }
        Mock Clear-PageZoom { }
        $run = Start-TestRun $state 'normal' -Kind page -PageId 'p001'
        $script:Started.Add($run)
        $data = Wait-TestRun $state
        Test-DesignerRunActive -State $state | Should -BeFalse
        $data.state | Should -Be 'done'
        ($data.notes -join ' ') | Should -Match 'could not finish reading'
        # The outcome says plainly that the page was captured but there is nothing to see here.
        $data.message | Should -Match '^Test finished: the page was captured, but its preview cannot be shown here \(The preview could not be registered\.\)\.$'
        $data.message | Should -Not -Match 'without problems'
        $data.nextStep | Should -Match 'Open the preview report'
        $data.open['preview-report'] | Should -BeTrue
        Should -Invoke Connect-DesignerBrowser -Times 1 -Exactly
        $state.Browser.Connected | Should -BeTrue
        $run.ConfigTempPath | Should -Not -Exist
        # And when the outcome itself fails, the run is failed, never "running".
        Mock Get-DesignerRunOutcome { throw 'broken' }
        $run = Start-TestRun $state 'normal'
        $script:Started.Add($run)
        $data = Wait-TestRun $state
        $data.state | Should -Be 'failed'
        $data.message | Should -Match 'could not read its result'
        Should -Invoke Connect-DesignerBrowser -Times 2 -Exactly
    }

    It 'skips a turn whose reading of the progress fails, and reads it all at the next turns' {
        $state = New-RunTestState 'read-hiccup'
        $script:ReadCalls = 0
        Mock Read-DesignerRunEvent { throw 'The file is in use by another process.' } -ParameterFilter { $script:ReadCalls++; $script:ReadCalls -le 3 }
        $run = Start-TestRun $state 'normal'
        $script:Started.Add($run)
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        Get-EventType $data | Should -Be @('runStart', 'pageStart', 'capture', 'pageEnd', 'pageStart', 'detail', 'capture', 'pageEnd', 'runEnd')
        $run.ReadFailures | Should -Be 0
    }

    It 'still ends a run whose progress can never be read, when its process ends' {
        $state = New-RunTestState 'read-broken'
        Mock Read-DesignerRunEvent { throw 'The disk is not ready.' }
        $run = Start-TestRun $state 'normal'
        $script:Started.Add($run)
        $data = Wait-TestRun $state
        Test-DesignerRunActive -State $state | Should -BeFalse
        $data.state | Should -Be 'failed'
        ($data.notes -join ' ') | Should -Match 'The last part of this run''s progress could not be read \(The disk is not ready\.\)'
        $run.ConfigTempPath | Should -Not -Exist
    }

    It 'treats a run it cannot check as still running, and never hands the browser back early' {
        $state = New-RunTestState 'cannot-tell'
        $self = Get-Process -Id $PID
        # A Process object tied to no process: reading HasExited throws.
        $broken = [System.Diagnostics.Process]::new()
        $run = New-DesignerRunState
        $run.Process = $broken
        # This process is alive and is the one that was started: not ended.
        $run.ProcessId = $PID
        $run.ProcessStartTime = $self.StartTime
        Test-DesignerChildExited -Run $run | Should -BeFalse
        # The start time cannot be compared: still not ended.
        $run.ProcessStartTime = [datetime]::MinValue
        Test-DesignerChildExited -Run $run | Should -BeFalse
        # Another process now has the id (another start time): ended.
        $run.ProcessStartTime = $self.StartTime.AddMinutes(-5)
        Test-DesignerChildExited -Run $run | Should -BeTrue
        # No process has the id any more: ended.
        $ended = Start-Process -FilePath $self.Path -ArgumentList '-NoProfile', '-Command', 'exit' -WindowStyle Hidden -PassThru
        $ended.WaitForExit()
        $run.ProcessId = $ended.Id
        Test-DesignerChildExited -Run $run | Should -BeTrue
        # In the loop: a run that cannot be checked stays running, the browser is not touched.
        Mock Complete-DesignerRun { }
        Mock Connect-DesignerBrowser { }
        $run.ProcessId = $PID
        $run.ProcessStartTime = $self.StartTime
        $run.State = 'running'
        $run.EventPath = Join-Path $TestDrive 'cannot-tell.ndjson'
        [System.IO.File]::WriteAllText($run.EventPath, '')
        $state.Run = $run
        Update-DesignerRun -State $state
        Should -Invoke Complete-DesignerRun -Times 0 -Exactly
        Should -Invoke Connect-DesignerBrowser -Times 0 -Exactly
        Test-DesignerRunActive -State $state | Should -BeTrue
        $state.Run = New-DesignerRunState
    }

    It 'keeps the browser away from a run whose force stop did not end it, until it has ended' {
        $state = New-RunTestState 'kill-fails'
        $state.Browser.Connected = $true
        $state.Browser.TabId = 'TAB-1'
        Mock Connect-DesignerBrowser { $State.Browser.Connected = $true; $State.Browser.TabId = 'TAB-1' }
        Mock Set-DesignerLayout { [pscustomobject]@{ Ok = $true; Message = '' } }
        Mock Clear-PageZoom { }
        Mock Stop-DesignerChildProcess { }
        $run = Start-TestRun $state 'ignorestop'
        $script:Started.Add($run)
        [void](Wait-TestRun $state -Until { (Get-DesignerRunData -State $state).state -eq 'running' })
        $refusal = Stop-DesignerRun -State $state -Force -Immediately
        $refusal.Status | Should -Be 500
        $body = $refusal.Body | ConvertFrom-Json
        $body.code | Should -Be 'kill-failed'
        $body.detail | Should -Match "process number $($run.ProcessId)"
        $run.KillFailed | Should -BeTrue
        $run.State | Should -Be 'stopping'
        Test-DesignerRunActive -State $state | Should -BeTrue
        ((Get-DesignerRunData -State $state).notes -join ' ') | Should -Match 'Windows did not end the run''s process'
        Should -Invoke Connect-DesignerBrowser -Times 0 -Exactly
        (Get-DesignerRunRefusal -State $state -Route 'POST /api/browser/navigate').Status | Should -Be 409
        # A later turn still does not hand the browser back while the process lives.
        Update-DesignerRun -State $state
        Should -Invoke Connect-DesignerBrowser -Times 0 -Exactly
        # Once the process is really gone, the run ends and the browser comes back.
        $run.Process.Kill($true)
        [void]$run.Process.WaitForExit(10000)
        $data = Wait-TestRun $state
        $data.state | Should -Be 'failed'
        $data.message | Should -Match 'force-stopped'
        Should -Invoke Connect-DesignerBrowser -Times 1 -Exactly
    }

    It 'keeps the older preview of a page when the new test cannot start' {
        $state = New-RunTestState 'keep-preview'
        $run = Start-TestRun $state 'normal' -Kind page -PageId 'p001'
        $script:Started.Add($run)
        [void](Wait-TestRun $state)
        $old = @($state.Previews.Keys)
        $old.Count | Should -Be 1
        $oldFolder = $state.Previews[$old[0]].Folder
        Mock Start-DesignerChildProcess { throw 'Windows refused to start it.' }
        { Start-TestRun $state 'normal' -Kind page -PageId 'p001' } | Should -Throw '*could not be started*'
        @($state.Previews.Keys) | Should -Be $old
        $oldFolder | Should -Exist
        @(Get-ChildItem -LiteralPath $state.SessionFolder -Directory -Filter 'preview-p001-*').Count | Should -Be 1
        $state.Run.State | Should -Be 'failed'
    }

    It 'reads one chunk of the event file per loop turn, the rest at the next turns' {
        $run = New-DesignerRunState
        $run.EventPath = Join-Path $TestDrive 'big.ndjson'
        $state = New-TestState
        $line = '{"type":"detail","pageId":"p1","status":"OK","text":"' + ('z' * 1000) + '"}' + "`n"
        [System.IO.File]::WriteAllText($run.EventPath, ($line * 3200), [System.Text.UTF8Encoding]::new($false))
        $length = (Get-Item -LiteralPath $run.EventPath).Length
        $first = Read-DesignerRunEvent -State $state -Run $run
        $run.Offset | Should -Be 1MB
        $first | Should -BeLessThan 3200
        $turns = 1
        while ($run.Offset -lt $length) { [void](Read-DesignerRunEvent -State $state -Run $run); $turns++ }
        $turns | Should -Be ([Math]::Ceiling($length / 1MB))
        $run.Events.Count | Should -Be 3200
    }

    It 'gives the next step for each kind of failure, and test wording for a page test' {
        $make = {
            param($Kind, $Code, $RunEnd, $Forced, $Pages)
            $run = New-DesignerRunState
            $run.Kind = $Kind; $run.ExitCode = $Code; $run.Forced = $Forced
            if ($RunEnd) { $run.RunEnd = [ordered]@{ type = 'runEnd' }; $run.Counts = [ordered]@{ pages = 1; run = 1; ok = 1; warning = 0; failed = 0; notRun = 0; captures = 1 } }
            if ($Pages) { $run.Pages['id:p1'] = [ordered]@{} }
            return $run
        }
        Get-DesignerRunNextStep -Run (& $make 'full' 1 $false $false $false) | Should -Match '^Fix what the message names, then try again\. To see everything'
        Get-DesignerRunNextStep -Run (& $make 'full' 7 $false $false $true) | Should -Match '^Try again\. If it happens again'
        Get-DesignerRunNextStep -Run (& $make 'full' -1 $false $true $true) | Should -Match '^Run it again'
        Get-DesignerRunNextStep -Run (& $make 'full' 2 $true $false $true) | Should -Match 'Open the report to see what went wrong'
        Get-DesignerRunNextStep -Run (& $make 'full' 3 $true $false $true) | Should -Match 'Fail on warnings'
        Get-DesignerRunNextStep -Run (& $make 'full' 0 $true $false $true) | Should -Be ''
        Get-DesignerRunOutcome -Run (& $make 'page' 0 $true $false $true) -ProcessExitCode 0 | Should -Be 'Test finished: this page was captured without problems.'
        Get-DesignerRunOutcome -Run (& $make 'page' 2 $true $false $true) -ProcessExitCode 2 | Should -Match '^Test finished, but the page failed'
        Get-DesignerRunOutcome -Run (& $make 'page' 1 $false $false $false) -ProcessExitCode 1 | Should -Match '^The test could not start'
        Get-DesignerRunOutcome -Run (& $make 'page' 0 $false $true $true) -ProcessExitCode 0 | Should -Match '^You force-stopped the test'
    }

    It 'removes the folders of Designers that are gone, and nothing else' {
        $temp = Join-Path $TestDrive 'temp-sweep'
        [void](New-Item -ItemType Directory -Path $temp -Force)
        $marker = Get-DesignerSessionMarkerName
        $new = {
            param($Name, $MarkerPid, $Started)
            $folder = Join-Path $temp $Name
            [void](New-Item -ItemType Directory -Path $folder -Force)
            [System.IO.File]::WriteAllText((Join-Path $folder 'run-001-aaaaaaaa.json'), '{}')
            if ($null -ne $MarkerPid) { [System.IO.File]::WriteAllText((Join-Path $folder $marker), (@{ pid = $MarkerPid; started = $Started } | ConvertTo-Json -Compress)) }
            return $folder
        }
        # A process that has ended (its id is free) and one that is alive.
        $ended = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit' -WindowStyle Hidden -PassThru
        $ended.WaitForExit()
        $alive = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -WindowStyle Hidden -PassThru
        try {
            $aliveTicks = $alive.StartTime.ToUniversalTime().Ticks
            $gone = & $new "VouchDesigner-$($ended.Id)-0a1b2c3d" $ended.Id 12345
            $reused = & $new "VouchDesigner-$($alive.Id)-11111111" $alive.Id ($aliveTicks - 10000000)
            $living = & $new "VouchDesigner-$($alive.Id)-22222222" $alive.Id $aliveTicks
            $noMarker = & $new "VouchDesigner-$($ended.Id)-33333333" $null 0
            $otherName = & $new "VouchDesigner-$($ended.Id)-zzzz" $ended.Id 12345
            $otherPid = & $new "VouchDesigner-$($ended.Id)-44444444" ($ended.Id + 1) 12345
            $removed = Clear-DesignerStaleSession -TempFolder $temp
            @($removed | Sort-Object) | Should -Be @(@($gone, $reused) | Sort-Object)
            $gone | Should -Not -Exist
            $reused | Should -Not -Exist
            foreach ($kept in $living, $noMarker, $otherName, $otherPid) { $kept | Should -Exist }
        }
        finally { Stop-Process -Id $alive.Id -Force -ErrorAction SilentlyContinue }
        # A session folder carries the marker naming this process.
        $state = New-TestState
        $state.SessionFolder = Join-Path $temp "VouchDesigner-$PID-55555555"
        $folder = Get-DesignerSessionFolder -State $state
        $own = Get-Content -Raw -LiteralPath (Join-Path $folder $marker) | ConvertFrom-Json
        $own.pid | Should -Be $PID
        $own.started | Should -Be (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        # Its own folder is never touched (the living one's owner has ended by now, so it goes).
        (Clear-DesignerStaleSession -TempFolder $temp) | Should -Not -Contain $folder
        $folder | Should -Exist
    }

    It 'never lets one odd folder stop the sweep, never deletes an owner it cannot determine, and retries a partly removed folder' {
        $temp = Join-Path $TestDrive 'temp-sweep-2'
        [void](New-Item -ItemType Directory -Path $temp -Force)
        $marker = Get-DesignerSessionMarkerName
        $new = {
            param($Name, [string]$MarkerJson)
            $folder = Join-Path $temp $Name
            [void](New-Item -ItemType Directory -Path $folder -Force)
            [System.IO.File]::WriteAllText((Join-Path $folder 'run-001-aaaaaaaa.json'), '{}')
            if ($MarkerJson) { [System.IO.File]::WriteAllText((Join-Path $folder $marker), $MarkerJson) }
            return $folder
        }
        $ended = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit' -WindowStyle Hidden -PassThru
        $ended.WaitForExit()
        $alive = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -WindowStyle Hidden -PassThru
        try {
            # Sorted first by name, so a throw there would have stopped the sweep before the rest.
            $tooBig = & $new 'VouchDesigner-0000000000-aaaaaaaa' '{"pid":0,"started":1}'
            $notInt = & $new 'VouchDesigner-9999999999-aaaaaaaa' '{"pid":9999999999,"started":12345}'
            $gone = & $new "VouchDesigner-$($ended.Id)-0a1b2c3d" ('{"pid":' + $ended.Id + ',"started":12345}')
            # The marker cannot be read completely: never deleted, even for a living unrelated process.
            $noStarted = & $new "VouchDesigner-$($alive.Id)-aaaa0001" ('{"pid":' + $alive.Id + '}')
            $textStarted = & $new "VouchDesigner-$($alive.Id)-aaaa0002" ('{"pid":' + $alive.Id + ',"started":"soon"}')
            $nullStarted = & $new "VouchDesigner-$($ended.Id)-aaaa0003" ('{"pid":' + $ended.Id + ',"started":null}')
            $textPid = & $new "VouchDesigner-$($ended.Id)-aaaa0004" ('{"pid":"' + $ended.Id + '","started":12345}')
            $notObject = & $new "VouchDesigner-$($ended.Id)-aaaa0005" '[1,2]'
            $removed = Clear-DesignerStaleSession -TempFolder $temp
            @($removed) | Should -Be @($gone)
            $gone | Should -Not -Exist
            foreach ($kept in $tooBig, $notInt, $noStarted, $textStarted, $nullStarted, $textPid, $notObject) { $kept | Should -Exist }
            # A file still in use: the folder is not removed, its marker stays, the next start retries.
            $busy = & $new "VouchDesigner-$($ended.Id)-bbbb0001" ('{"pid":' + $ended.Id + ',"started":12345}')
            $lock = [System.IO.File]::Open((Join-Path $busy 'run-002-locked.events.ndjson'), 'Create', 'ReadWrite', 'None')
            try {
                $first = Clear-DesignerStaleSession -TempFolder $temp
                ($first -contains $busy) | Should -BeFalse
                Join-Path $busy $marker | Should -Exist
                Join-Path $busy 'run-001-aaaaaaaa.json' | Should -Not -Exist
            }
            finally { $lock.Dispose() }
            $second = Clear-DesignerStaleSession -TempFolder $temp
            ($second -contains $busy) | Should -BeTrue
            $busy | Should -Not -Exist
            # Left empty by an earlier attempt (marker gone): removed once its owner is gone, kept while alive.
            $emptyGone = Join-Path $temp "VouchDesigner-$($ended.Id)-cccc0001"
            $emptyAlive = Join-Path $temp "VouchDesigner-$($alive.Id)-cccc0002"
            [void](New-Item -ItemType Directory -Path $emptyGone, $emptyAlive -Force)
            $removed = Clear-DesignerStaleSession -TempFolder $temp
            ($removed -contains $emptyGone) | Should -BeTrue
            ($removed -contains $emptyAlive) | Should -BeFalse
            $emptyGone | Should -Not -Exist
            $emptyAlive | Should -Exist
        }
        finally { Stop-Process -Id $alive.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'skips garbage, waits for a line written in two parts, and drops an unfinished last line' {
        $state = New-RunTestState 'garbage'
        $script:Started.Add((Start-TestRun $state 'garbage'))
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.skippedLines | Should -Be 4
        @($data.events | Where-Object { $_['text'] -eq 'split line' }).Count | Should -Be 1
        (Get-EventType $data)[-1] | Should -Be 'runEnd'
    }

    It 'skips a line of several megabytes and goes on' {
        $state = New-RunTestState 'longline'
        $script:Started.Add((Start-TestRun $state 'longline'))
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.skippedLines | Should -Be 1
        @($data.pages).Count | Should -Be 2
    }

    It 'virtual desktop (desktop functions mocked): closes only the Edge it opened, runs without -TabId, connects again after' {
        $state = New-RunTestState 'vdesk'
        $state.Browser.Connected = $true; $state.Browser.TabId = 'TAB-1'; $state.Browser.Port = 9556; $state.Browser.ProfileDir = 'C:\Audit'
        $state.Browser.LaunchedByDesigner = $true; $state.Browser.LaunchedPid = 4242
        Mock Get-Process { [pscustomobject]@{ Id = 4242 } } -ParameterFilter { $Id -eq 4242 }
        Mock Stop-EdgeProcess { }
        Mock New-CaptureDesktop { throw 'No real virtual desktop in a test.' }
        Mock Send-KeyChord { throw 'No keystrokes in a test.' }
        Mock Connect-DesignerBrowser { $State.Browser.Connected = $true; $State.Browser.TabId = 'TAB-2' }
        Mock Set-DesignerLayout { [pscustomobject]@{ Ok = $true; Message = '' } }
        Mock Clear-PageZoom { }
        Mock Get-DevToolsTargetList { @() }
        $config = New-RunTestConfig 'normal'
        $config['browser']['useVirtualDesktop'] = $true
        $run = Start-TestRun $state 'normal' -Config $config
        $script:Started.Add($run)
        Should -Invoke Stop-EdgeProcess -Times 1 -Exactly
        $state.Browser.LaunchedByDesigner | Should -BeFalse
        @($run.Arguments | Where-Object { $_ -like '-TabId*' }).Count | Should -Be 0
        $run.Arguments | Should -Not -Contain '-UseVirtualDesktop:$false'
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.virtualDesktop | Should -Be 'used'
        ($data.notes -join ' ') | Should -Match 'closes the audit Edge it opened'
        Should -Invoke Connect-DesignerBrowser -Times 1 -Exactly
        Should -Invoke New-CaptureDesktop -Times 0
        # An Edge the Designer only found is never closed: the run goes without the desktop.
        $state.Browser.LaunchedByDesigner = $false; $state.Browser.LaunchedPid = 0
        $run = Start-TestRun $state 'normal' -Config $config
        $script:Started.Add($run)
        Should -Invoke Stop-EdgeProcess -Times 1 -Exactly
        $run.Arguments | Should -Contain '-UseVirtualDesktop:$false'
        $run.Arguments | Should -Contain "-TabId:$($state.Browser.TabId)"
        $data = Wait-TestRun $state
        $data.virtualDesktop | Should -Be 'skipped'
        ($data.notes -join ' ') | Should -Match 'does not use a separate virtual desktop'
    }

    It 'stops a run cleanly when the Designer is closed from the panel (/api/shutdown {stopRun})' {
        $state = New-RunTestState 'shutdown'
        $run = Start-TestRun $state 'stop'
        $script:Started.Add($run)
        [void](Wait-TestRun $state -Until { (Get-DesignerRunData -State $state).state -eq 'running' })
        $r = Invoke-TestRoute POST '/api/shutdown' ([ordered]@{ stopRun = $true }) -State $state
        $r.Status | Should -Be 200
        $r.Data.waiting | Should -BeTrue
        $state.Running | Should -BeTrue
        $data = Wait-TestRun $state
        $data.state | Should -Be 'done'
        $data.stopped | Should -BeTrue
        $state.Running | Should -BeFalse
        $state.StopReason | Should -Match 'run was stopped'
    }

    It 'stops a run first when the Designer ends some other way (window closed, Ctrl+C), forcing it after the grace time' {
        $state = New-RunTestState 'exit'
        $run = Start-TestRun $state 'ignorestop'
        $script:Started.Add($run)
        $childId = $run.ProcessId
        [void](Wait-TestRun $state -Until { (Get-DesignerRunData -State $state).state -eq 'running' })
        $run.GraceSec = 1
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-DesignerRunForExit -State $state 6>$null
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 8
        $state.Run.State | Should -Be 'failed'
        $state.Run.Forced | Should -BeTrue
        Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Remove-DesignerSessionFolder -State $state
        $state.SessionFolder | Should -Not -Exist
    }
}

Describe 'A real run from the Designer (vouch.ps1 as a child, headless Edge, page capture area)' -Tag 'Integration' {
    BeforeAll {
        $script:RealWeb = Get-FreeTcpPort
        $script:RealBase = "http://localhost:$($script:RealWeb)"
        $script:RealServer = Start-TestServer -Port $script:RealWeb
        $script:RealCdp = Get-FreeTcpPort
        $script:RealProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-realrun-$($script:RealCdp)"
        [void](Start-HeadlessEdge -Port $script:RealCdp -ProfileDir $script:RealProfile)
        Close-CdpSocket
        $script:S = New-TestState
        $script:S.SessionFolder = Join-Path $TestDrive 'Sitzung ''q'' $x %USERNAME% & é (1)'
        $script:S.OpenLog = Join-Path $TestDrive 'opened.txt'
        $script:S.Browser.TypedPort = $script:RealCdp
        $script:S.Browser.TypedProfileDir = $script:RealProfile
        $script:S.Browser.AllowLaunch = $false
        Connect-DesignerBrowser -State $script:S
        Set-NavigationMarker
        [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = "$($script:RealBase)/ok" })
        [void](Wait-PageReady -TimeoutSec 15)
        $script:RealTab = $script:S.Browser.TabId
        $script:RealWidth = Invoke-CdpEval -Expression 'window.innerWidth'

        # The saved file: relative output folder, read from the file's own folder.
        $script:RealFolder = Join-Path $TestDrive 'Prüfung ''saved'' & 100% (Q3)'
        [void](New-Item -ItemType Directory -Path $script:RealFolder -Force)
        $config = Get-DefaultVouchConfig
        $config['defaults']['captureArea'] = 'page'
        $config['defaults']['settleSeconds'] = 0.1
        $config['defaults']['navigationTimeoutSec'] = 10
        $config['output']['dir'] = 'out'
        $config['output']['reportName'] = 'proof {title}'
        $config['output']['jsonSummary'] = $true
        $config['report']['title'] = 'Saved title'
        $config['pages'].Add([ordered]@{ id = 'p001'; name = 'Plain page'; url = "$($script:RealBase)/ok"; overrides = [ordered]@{ zoomPercent = 50 } })
        $config['pages'].Add([ordered]@{ id = 'p002'; name = 'Tabs'; url = "$($script:RealBase)/tabs"; actions = @([ordered]@{ type = 'clickText'; text = 'General' }, [ordered]@{ type = 'capture'; label = 'General' }) })
        $config['pages'].Add([ordered]@{ id = 'p003'; name = 'Switched off'; url = "$($script:RealBase)/ok"; enabled = $false })
        $script:RealFile = Join-Path $script:RealFolder 'captures.json'
        [void](Save-VouchConfig -Config $config -Path $script:RealFile)
        $script:RealKnown = Add-DesignerKnownPath -State $script:S -Path $script:RealFile -Kind config
        $script:RealBytes = [System.IO.File]::ReadAllBytes($script:RealFile)
        # What the panel shows: the saved file plus an edit that was not saved, with every quoting hazard.
        $script:Hazard = 'Q3 R&D ''review'' "quoted" $HOME %USERNAME% `n é (draft)'
        $script:Shown = Read-DesignerConfigFile -Path $script:RealFile
        $script:Shown.Config['report']['title'] = $script:Hazard

        function Wait-RealRun([int]$TimeoutSec = 90, [scriptblock]$Until = $null) {
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                Update-DesignerRun -State $script:S
                if ($null -ne $Until) { if (& $Until) { break } }
                elseif (-not (Test-DesignerRunActive -State $script:S)) { break }
                Start-Sleep -Milliseconds 150
            }
            return Get-DesignerRunData -State $script:S
        }
        function Get-PreviewResponse([string]$Path, [switch]$NoToken) {
            $headers = New-GoodHeaders $script:S
            if ($NoToken) { $headers.Remove('X-Vouch-Token') }
            return Invoke-DesignerExchange -Method GET -Path $Path -Headers $headers -State $script:S
        }
    }
    AfterAll {
        if ($null -ne $script:S -and $null -ne $script:S.Run.Process) { Stop-DesignerChildProcess -Process $script:S.Run.Process }
        Close-CdpSocket
        Stop-HeadlessEdge -ProfileDir $script:RealProfile
        if ($null -ne $script:RealServer) { Stop-Process -Id $script:RealServer.Id -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryWithRetry -Path $script:RealProfile
    }

    It 'runs every page as shown (unsaved edits included), hands the browser over and takes it back, and the report verifies' {
        $script:S.Browser.Connected | Should -BeTrue
        # A pick and a zoom preview in progress end before the run.
        [void](Set-DesignerZoomPreview -State $script:S -Percent 50)
        [void](Start-ElementPick -State $script:S -Mode click)
        $script:S.Pick.State | Should -Be 'picking'
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $script:Shown.Config; path = $script:RealKnown; kind = 'full' }) -State $script:S
        $r.Status | Should -Be 200 -Because ($r.Data | ConvertTo-Json -Depth 5)
        $r.Data.unsaved | Should -BeTrue
        $script:S.Pick.State | Should -Be 'cancelled'
        $script:S.Browser.ZoomPercent | Should -Be 100
        # During the run the Designer has no connection and leaves the browser alone.
        $during = Wait-RealRun -Until { (Get-DesignerRunData -State $script:S).state -eq 'running' }
        $during.state | Should -Be 'running'
        $script:CdpSocket | Should -BeNullOrEmpty
        $script:S.Browser.Connected | Should -BeFalse
        (Invoke-TestRoute GET '/api/browser/current' -State $script:S).Status | Should -Be 409
        (Invoke-TestRoute POST '/api/pick/start' ([ordered]@{ mode = 'click' }) -State $script:S).Status | Should -Be 409
        $data = Wait-RealRun
        $data.state | Should -Be 'done' -Because "$($data.message) $($data.errorText)"
        $data.exitCode | Should -Be 0
        $types = @($data.events | ForEach-Object { $_['type'] } | Where-Object { $_ -in 'runStart', 'pageStart', 'pageEnd', 'runEnd' })
        $types | Should -Be @('runStart', 'pageStart', 'pageEnd', 'pageStart', 'pageEnd', 'runEnd')
        @($data.pages | ForEach-Object { $_.pageId }) | Should -Be @('p001', 'p002')
        # Relative output folder: next to the SAVED file.
        $out = Join-Path $script:RealFolder 'out'
        Split-Path $data.reportPath -Parent | Should -Be $out
        # The unsaved title, with every hazard, reached the engine exactly.
        $summary = Get-Content -Raw -LiteralPath ([System.IO.Path]::ChangeExtension($data.reportPath, '.json')) | ConvertFrom-Json
        $summary.ReportDetails.Title | Should -BeExactly $script:Hazard
        (Get-Content -Raw -LiteralPath $data.logPath) | Should -Match ([regex]::Escape("Definition file: $($script:S.SessionFolder)"))
        # The saved file was never written.
        [System.IO.File]::ReadAllBytes($script:RealFile) | Should -Be $script:RealBytes
        # -Verify on the report, from the real script.
        $verify = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $TestDrive 'verify.txt') -ArgumentList '-NoProfile', '-File', "`"$script:VouchPath`"", '-Verify', "`"$($data.reportPath)`""
        $verify.ExitCode | Should -Be 0
        # Connected again to the same tab, no zoom left.
        $script:S.Browser.Connected | Should -BeTrue
        $script:S.Browser.TabId | Should -Be $script:RealTab
        Invoke-CdpEval -Expression 'window.innerWidth' | Should -Be $script:RealWidth
    }

    It 'opens only what this run produced, by kind, never a path from the request' {
        $data = Get-DesignerRunData -State $script:S
        Remove-Item -LiteralPath $script:S.OpenLog -ErrorAction SilentlyContinue
        (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'report'; path = 'C:\Windows\win.ini' }) -State $script:S).Status | Should -Be 200
        (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'folder' }) -State $script:S).Status | Should -Be 200
        (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'log' }) -State $script:S).Status | Should -Be 200
        (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'zip' }) -State $script:S).Status | Should -Be 409
        (Invoke-TestRoute POST '/api/open' ([ordered]@{ what = 'C:\Windows\win.ini' }) -State $script:S).Status | Should -Be 400
        $opened = @(Get-Content -LiteralPath $script:S.OpenLog)
        $opened | Should -Be @("report|$($data.reportPath)", "folder|$(Split-Path $data.reportPath -Parent)", "log|$($data.logPath)")
    }

    It 'tests one page (switched off, too) into a preview folder, never the output folder, and clears its zoom' {
        $out = Join-Path $script:RealFolder 'out'
        $before = @(Get-ChildItem -LiteralPath $out -Recurse | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
        foreach ($id in 'p003', 'p001') {
            $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $script:Shown.Config; path = $script:RealKnown; kind = 'page'; pageId = $id }) -State $script:S
            $r.Status | Should -Be 200
            $data = Wait-RealRun
            $data.state | Should -Be 'done' -Because "$($data.message) $($data.errorText)"
            $data.kind | Should -Be 'page'
            @($data.pages).Count | Should -Be 1
            $data.pages[0].pageId | Should -Be $id
            $data.previewAvailable | Should -BeTrue
            @($data.preview.images).Count | Should -Be 1
            $data.pageResults[$id].kind | Should -Be 'page'
        }
        # p001 runs at 50%: the engine cleared it at the end, and the Designer shows no zoom.
        Invoke-CdpEval -Expression 'window.innerWidth' | Should -Be $script:RealWidth
        $script:S.Browser.ZoomPercent | Should -Be 100
        $script:S.Browser.TabId | Should -Be $script:RealTab
        $after = @(Get-ChildItem -LiteralPath $out -Recurse | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
        $after | Should -Be $before
        [System.IO.File]::ReadAllBytes($script:RealFile) | Should -Be $script:RealBytes
        $folder = $script:S.Run.PreviewFolder
        $folder | Should -BeLike "$($script:S.SessionFolder)\preview-p001-*"
        Split-Path $data.reportPath -Parent | Should -Be $folder
        (Get-ChildItem -LiteralPath (Join-Path $folder 'images') -Recurse -Filter *.jpg).Count | Should -Be 1
        $script:PreviewUrl = $data.preview.images[0].url
        $script:PreviewData = $data
    }

    It 'serves the preview images only with the token, only the files this run made, nothing else' {
        $data = $script:PreviewData
        $id = $data.preview.id
        $name = $data.preview.images[0].name
        $ok = Get-PreviewResponse $script:PreviewUrl
        $ok.Status | Should -Be 200
        $ok.ContentType | Should -Be 'image/jpeg'
        $file = Join-Path $script:S.Run.PreviewFolder (Join-Path 'images' (Join-Path ([System.IO.Path]::GetFileNameWithoutExtension($data.reportPath)) $name))
        $ok.Body | Should -Be ([System.IO.File]::ReadAllBytes($file))
        (Get-DesignerSecurityHeader)['X-Content-Type-Options'] | Should -Be 'nosniff'
        (Get-PreviewResponse $script:PreviewUrl -NoToken).Status | Should -Be 403
        $reportName = [Uri]::EscapeDataString([System.IO.Path]::GetFileName($data.reportPath))
        foreach ($path in @(
                "/preview/$id/", "/preview/$id", "/preview/$id/$reportName", "/preview/$id/SHA256SUMS",
                "/preview/$id/..%2F..%2F$reportName", "/preview/$id/..%5C..%5C$reportName", "/preview/$id/../$name",
                "/preview/$id/$name/x", "/preview/0000$id/$name", "/preview/$($id.ToUpperInvariant())/$name", '/preview/')) {
            (Get-PreviewResponse $path).Status | Should -Be 404 -Because $path
        }
    }

    It 'replaces the preview with a newer test of the same page, and removes everything when the Designer stops' {
        $oldFolder = $script:S.Run.PreviewFolder
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $script:Shown.Config; path = $script:RealKnown; kind = 'page'; pageId = 'p001' }) -State $script:S
        $r.Status | Should -Be 200
        $oldFolder | Should -Not -Exist
        (Get-PreviewResponse $script:PreviewUrl).Status | Should -Be 404
        $data = Wait-RealRun
        $data.state | Should -Be 'done'
        (Get-PreviewResponse $data.preview.images[0].url).Status | Should -Be 200
        # The preview of the other page (p003) is still there until the Designer stops.
        @($script:S.Previews.Values | ForEach-Object { $_.PageId }) | Sort-Object | Should -Be @('p001', 'p003')
        Remove-DesignerSessionFolder -State $script:S
        (Get-PreviewResponse $data.preview.images[0].url).Status | Should -Be 404
        $script:S.SessionFolder | Should -Not -Exist
        $script:S.SessionFolder = Join-Path $TestDrive 'session two'
    }

    It 'stops a real run in the middle; the engine ends the page and still writes the report' {
        $config = Copy-VouchConfig -Config $script:Shown.Config
        $config['pages'][0]['actions'] = @([ordered]@{ type = 'wait'; seconds = 60 }, [ordered]@{ type = 'capture' })
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $config; path = $script:RealKnown; kind = 'full' }) -State $script:S
        $r.Status | Should -Be 200
        [void](Wait-RealRun -Until { @((Get-DesignerRunData -State $script:S).pages).Count -ge 1 })
        Start-Sleep -Milliseconds 500
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        (Invoke-TestRoute POST '/api/run/stop' -State $script:S).Data.state | Should -Be 'stopping'
        $data = Wait-RealRun
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        $data.state | Should -Be 'done'
        $data.stopped | Should -BeTrue
        $data.pages[0].status | Should -Be 'WARNING'
        ($data.pages[0].details -join ' ') | Should -Match 'Stopped by the user'
        $data.reportPath | Should -Exist
        $data.message | Should -Match '^Stopped by you'
        $script:S.Browser.Connected | Should -BeTrue
    }

    It 'tests pages whose id looks like a switch, a true/false value, or has spaces and a colon (<_>)' -ForEach @('-Zip', '-OutputDir', '-home', 'p 1: x', '$true', '$FALSE') {
        $config = Copy-VouchConfig -Config $script:Shown.Config
        $config['pages'].Add([ordered]@{ id = $_; name = "Odd id $_"; url = "$($script:RealBase)/ok"; enabled = $false })
        $r = Invoke-TestRoute POST '/api/run' ([ordered]@{ config = $config; path = $script:RealKnown; kind = 'page'; pageId = $_ }) -State $script:S
        $r.Status | Should -Be 200
        if ($_ -in '$true', '$false') {
            # Joined, pwsh -File would hand the engine the word True or False.
            $at = [array]::IndexOf([string[]]$script:S.Run.Arguments, '-Only')
            $at | Should -BeGreaterThan -1
            $script:S.Run.Arguments[$at + 1] | Should -BeExactly $_
        }
        else { $script:S.Run.Arguments | Should -Contain "-Only:$_" }
        $data = Wait-RealRun
        $data.state | Should -Be 'done' -Because "$($data.message) $($data.errorText)"
        $data.pages[0].pageId | Should -Be $_
        $data.message | Should -Be 'Test finished: this page was captured without problems.'
        $data.preview.images.Count | Should -Be 1
    }
}

Describe 'Running and testing from the panel (two headless Edges, real server)' -Tag 'Integration' {
    BeforeAll {
        $script:RunUiWeb = Get-FreeTcpPort
        $script:RunUiBase = "http://localhost:$($script:RunUiWeb)"
        $script:RunUiServer = Start-TestServer -Port $script:RunUiWeb
        $script:RunAuditCdp = Get-FreeTcpPort
        $script:RunAuditProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-runui-audit-$($script:RunAuditCdp)"
        [void](Start-HeadlessEdge -Port $script:RunAuditCdp -ProfileDir $script:RunAuditProfile)
        $script:RunSockets = @{}
        $script:RunCurrent = ''
        function Use-RunCdp([string]$Name) {
            if ($script:RunCurrent) { $script:RunSockets[$script:RunCurrent] = @{ Socket = $script:CdpSocket; Url = $script:CdpWebSocketUrl; Id = $script:CdpMessageId } }
            $saved = $script:RunSockets[$Name]
            $script:CdpSocket = $saved.Socket; $script:CdpWebSocketUrl = $saved.Url; $script:CdpMessageId = $saved.Id
            $script:RunCurrent = $Name
        }
        function Connect-RunTab([string]$Name, [int]$Port) {
            if ($script:RunCurrent) { Use-RunCdp $script:RunCurrent; $script:CdpSocket = $null }
            $target = Get-CdpPageTarget -Port $Port -WaitSeconds 5 -TabId ''
            Connect-CdpSocket -WebSocketUrl ([string]$target.webSocketDebuggerUrl)
            $script:RunCurrent = $Name
            $script:RunSockets[$Name] = @{ Socket = $script:CdpSocket; Url = $script:CdpWebSocketUrl; Id = $script:CdpMessageId }
        }
        $script:CdpPort = 0
        $script:CdpSocket = $null
        Connect-RunTab -Name 'audit' -Port $script:RunAuditCdp
        Set-NavigationMarker
        [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = "$($script:RunUiBase)/ok" })
        [void](Wait-PageReady -TimeoutSec 15)

        $folder = Join-Path $TestDrive 'runui'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $config = Get-DefaultVouchConfig
        $config['defaults']['captureArea'] = 'page'
        $config['defaults']['settleSeconds'] = 0.1
        $config['defaults']['navigationTimeoutSec'] = 10
        $config['output']['dir'] = 'out'
        $config['pages'].Add([ordered]@{ id = 'p001'; name = 'Plain page'; url = "$($script:RunUiBase)/ok" })
        $config['pages'].Add([ordered]@{ id = 'p002'; name = 'Tall page'; url = "$($script:RunUiBase)/tall?px=2200"; actions = @([ordered]@{ type = 'capture'; scroll = [ordered]@{ mode = 'page' } }) })
        $script:RunUiFile = Join-Path $folder 'panel runs.json'
        [void](Save-VouchConfig -Config $config -Path $script:RunUiFile)
        $script:RunUiBytes = [System.IO.File]::ReadAllBytes($script:RunUiFile)
        $script:RunUiOpenLog = Join-Path $TestDrive 'runui-opened.txt'
        $script:RunUi = Start-DesignerTestServer -ConfigPath $script:RunUiFile -Name 'runui' -AuditPort $script:RunAuditCdp -AuditProfile $script:RunAuditProfile -RunScript $script:FakeChildPath -OpenLog $script:RunUiOpenLog

        $script:RunPanelCdp = Get-FreeTcpPort
        $script:RunPanelProfile = Join-Path ([System.IO.Path]::GetTempPath()) "vouch-designer-runui-panel-$($script:RunPanelCdp)"
        [void](Start-HeadlessEdge -Port $script:RunPanelCdp -ProfileDir $script:RunPanelProfile)
        Connect-RunTab -Name 'panel' -Port $script:RunPanelCdp
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
        [void](Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $script:RunUi.Url })
        [void](Wait-PageReady -TimeoutSec 15)
        [void](Invoke-CdpEval -Expression 'window.VouchDesigner.ready.then(() => true)' -TimeoutSec 20)
        [void](Invoke-CdpEval -Expression @'
window.__field = path => Array.from(document.querySelectorAll('[data-path]')).find(e => e.dataset.path === path && e.type !== 'radio');
window.__type = (path, value) => { const el = window.__field(path); if (!el) throw new Error('no field ' + path); el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); };
true
'@)
        function Invoke-RunPanel([string]$Script, [int]$TimeoutSec = 60) {
            Use-RunCdp 'panel'
            $json = Invoke-CdpEval -TimeoutSec $TimeoutSec -Expression "(async () => { const D = window.VouchDesigner; const S = D.S; const until = async (f, ms) => { const end = Date.now() + (ms || 10000); while (Date.now() < end) { const v = f(); if (v) return v; await new Promise(r => setTimeout(r, 100)); } return null; }; const btnByKey = k => Array.from(document.querySelectorAll('button')).find(b => b.dataset.fkey === k); const r = await (async () => { $Script })(); return JSON.stringify(r === undefined ? null : r); })()"
            if ($null -eq $json) { return $null }
            return $json | ConvertFrom-Json -Depth 64
        }
        function Get-RunUiChild {
            # The stand-in run the server started (its command line names FakeVouchChild.ps1).
            return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('FakeVouchChild.ps1') -and $_.ParentProcessId -eq $script:RunUi.Process.Id })
        }
    }
    AfterAll {
        foreach ($name in @($script:RunSockets.Keys)) { Use-RunCdp $name; Close-CdpSocket }
        $script:RunCurrent = ''
        if ($null -ne $script:RunUi) { Stop-Process -Id $script:RunUi.Process.Id -Force -ErrorAction SilentlyContinue }
        Get-RunUiChild | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-HeadlessEdge -ProfileDir $script:RunPanelProfile
        Stop-HeadlessEdge -ProfileDir $script:RunAuditProfile
        if ($null -ne $script:RunUiServer) { Stop-Process -Id $script:RunUiServer.Id -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryWithRetry -Path $script:RunPanelProfile
        Remove-DirectoryWithRetry -Path $script:RunAuditProfile
    }

    It 'shows what a run would do before it starts, and says when unsaved edits run' {
        $r = Invoke-RunPanel @'
await until(() => S.browser.connected && S.capabilities.run, 15000);
D.setTab('run');
await D.refreshRunPlan();
const saved = { text: document.querySelector('#panel-run').textContent, unsaved: S.runPlan.unsaved, folder: S.runPlan.outputFolder };
D.setTab('report');
__type('report.title', 'Edited in the panel');
D.setTab('run');
// The plan follows edits by itself (debounced); wait for the one made with this edit.
await until(() => S.runPlan && S.runPlan.unsaved, 8000);
await new Promise(r => setTimeout(r, 100));
const edited = document.querySelector('#panel-run .run-plan').textContent;
return { saved, edited, runAll: btnByKey('run-all').getAttribute('aria-disabled') };
'@
        $r.saved.unsaved | Should -BeFalse
        $r.saved.folder | Should -Be (Join-Path (Split-Path $script:RunUiFile -Parent) 'out')
        $r.saved.text | Should -Match ([regex]::Escape("Reports of a full run go to: $($r.saved.folder)"))
        $r.saved.text | Should -Not -Match 'Running your current edits'
        $r.edited | Should -Match 'Running your current edits \(not yet saved\)\. The saved file is not changed by a run\.'
        $r.edited | Should -Match 'What the Designer adds'
        $r.runAll | Should -BeNullOrEmpty
    }

    It 'blocks a run with problems, with the list Save shows' {
        $r = Invoke-RunPanel @'
const before = S.run.number;
D.setTab('pages'); D.selectPage(0);
__type('pages[0].url', 'intranet.example.com');
D.setTab('run');
const going = D.startRun('all');
await until(() => document.querySelector('#modal').open, 5000);
const title = document.querySelector('#modal-title').textContent, body = document.querySelector('#modal-body').textContent;
document.querySelector('#modal').close();
const started = await going;
D.setTab('pages'); __type('pages[0].url', S.savedJson ? JSON.parse(S.savedJson).pages[0].url : '');
return { title, body, started, same: S.run.number === before };
'@
        $r.title | Should -Be 'Not run'
        $r.body | Should -Match 'Address \(URL\)'
        $r.started | Should -BeFalse
        $r.same | Should -BeTrue
    }

    It 'runs all pages from the button: live progress per page, the result, and links that open this run''s files' {
        $r = Invoke-RunPanel -TimeoutSec 120 @'
D.setTab('run');
btnByKey('run-all').click();
const running = await until(() => ['running', 'starting'].includes(S.run.state) && document.querySelector('.run-state').textContent, 10000);
const strip = await until(() => S.browser.inRun && document.querySelector('#browser-strip').textContent, 8000);
const stopShown = !!btnByKey('run-stop');
await until(() => S.run.state === 'done' || S.run.state === 'failed', 90000);
await until(() => S.browser.connected, 15000);
const pages = Array.from(document.querySelectorAll('.run-page')).map(li => ({ name: li.querySelector('.run-page-name').textContent, chip: li.querySelector('.chip').textContent, count: li.querySelector('.run-page-count').textContent, details: li.querySelector('details') ? li.querySelector('details summary').textContent : '' }));
const message = document.querySelector('#panel-run .run-message').textContent;
btnByKey('open-report').click(); await new Promise(r => setTimeout(r, 300));
btnByKey('open-folder').click(); await new Promise(r => setTimeout(r, 300));
btnByKey('open-log').click(); await new Promise(r => setTimeout(r, 300));
D.setTab('pages');
const chips = Array.from(document.querySelectorAll('.page-row .chip')).map(c => c.textContent);
D.setTab('run');
return { running, strip, stopShown, state: S.run.state, pages, message, report: S.run.reportPath, log: S.run.logPath, chips, unsaved: S.run.unsaved, zip: !!btnByKey('open-zip') };
'@
        $r.state | Should -Be 'done' -Because $r.message
        $r.running | Should -Match 'Running|Starting'
        $r.strip | Should -Match 'A run is using the audit browser'
        $r.stopShown | Should -BeTrue
        $r.unsaved | Should -BeTrue
        @($r.pages).Count | Should -Be 2
        $r.pages[0].name | Should -Be 'Plain page'
        $r.pages[0].chip | Should -Be 'OK'
        $r.pages[0].count | Should -Be '1 image'
        $r.pages[1].chip | Should -BeIn 'OK', 'Warning'
        $r.message | Should -Match '^Finished'
        $r.zip | Should -BeFalse
        @($r.chips | Where-Object { $_ -match '^Run (OK|: warning) \d\d:\d\d$' }).Count | Should -Be 2
        $opened = @(Get-Content -LiteralPath $script:RunUiOpenLog)
        $opened | Should -Be @("report|$($r.report)", "folder|$(Split-Path $r.report -Parent)", "log|$($r.log)")
        $r.report | Should -Exist
        Split-Path $r.report -Parent | Should -Be (Join-Path (Split-Path $script:RunUiFile -Parent) 'out')
        (Get-Content -Raw -LiteralPath $r.report) | Should -Match 'Edited in the panel'
        [System.IO.File]::ReadAllBytes($script:RunUiFile) | Should -Be $script:RunUiBytes
    }

    It 'tests the selected page from its editor and shows the screenshots as a preview' {
        $r = Invoke-RunPanel -TimeoutSec 120 @'
D.setTab('pages'); D.selectPage(1);
btnByKey('test-page').click();
await until(() => S.tab === 'run' && S.run.kind === 'page', 10000);
await until(() => S.run.state === 'done' || S.run.state === 'failed', 90000);
await until(() => document.querySelectorAll('.thumb-img').length > 0, 15000);
const imgs = Array.from(document.querySelectorAll('.thumb-img')).map(i => ({ src: i.getAttribute('src').slice(0, 23), ok: i.complete && i.naturalWidth > 0 }));
const heading = document.querySelector('.preview-block h3').textContent;
const note = document.querySelector('.preview-block .preview-note').textContent;
const outcome = document.querySelector('#panel-run .run-message').textContent;
document.querySelector('.thumb').click();
await until(() => document.querySelector('#modal').open, 3000);
const large = document.querySelector('#modal-body img.preview-large');
const largeOk = !!large && large.getAttribute('src').startsWith('data:image/jpeg;base64,');
document.querySelector('#modal').close();
btnByKey('open-preview').click(); await new Promise(r => setTimeout(r, 300));
D.setTab('pages');
const chip = document.querySelectorAll('.page-row .chip')[1].textContent;
D.setTab('run');
return { state: S.run.state, imgs, heading, note, outcome, largeOk, chip, count: S.run.preview.images.length, segments: S.run.preview.images.map(i => i.segmentCount) };
'@
        $r.state | Should -Be 'done'
        $r.heading | Should -Be 'Preview of the page test: Tall page'
        $r.note | Should -Be 'This is a test, not evidence. Use Run all pages to make the report.'
        $r.outcome | Should -Match '^Test finished: this page was captured'
        @($r.imgs).Count | Should -Be $r.count
        @($r.imgs).Count | Should -BeGreaterThan 1
        foreach ($img in $r.imgs) { $img.src | Should -Be 'data:image/jpeg;base64,'; $img.ok | Should -BeTrue }
        $r.largeOk | Should -BeTrue
        $r.chip | Should -Match '^Test (OK|: warning) \d\d:\d\d$'
        (Get-Content -LiteralPath $script:RunUiOpenLog)[-1] | Should -Match '^preview-report\|.*\\VouchDesigner-\d+-[0-9a-f]+\\preview-p002-'
    }

    It 'shows a run that waits for the person in the Vouch window, and stops it from the panel' {
        $r = Invoke-RunPanel -TimeoutSec 90 @'
S.config.name = 'fake:prompt';
D.setTab('run');
btnByKey('run-all').click();
const waiting = await until(() => S.run.state === 'waitingForUser' && document.querySelector('#panel-run .callout[role=alert]'), 20000);
const text = waiting ? waiting.textContent : '';
const status = document.querySelector('.run-state').textContent;
btnByKey('run-stop').click();
const stopping = await until(() => S.run.state === 'stopping' || S.run.state === 'done', 5000);
await until(() => S.run.state === 'done' || S.run.state === 'failed', 30000);
return { text, status, stopping: !!stopping, state: S.run.state, stopped: S.run.stopped, message: S.run.message };
'@
        $r.text | Should -Match 'Waiting for you in the Vouch window over the browser'
        $r.text | Should -Match 'Vouch has paused'
        $r.status | Should -Match 'Waiting for your answer'
        $r.stopping | Should -BeTrue
        $r.state | Should -Be 'done'
        $r.stopped | Should -BeTrue
        $r.message | Should -Match '^Stopped by you'
    }

    It 'shows live progress while a run goes, and a run that failed with what it said' {
        $r = Invoke-RunPanel -TimeoutSec 90 @'
S.config.name = 'fake:slow';
D.setTab('run');
btnByKey('run-all').click();
const firstDone = await until(() => S.run.state === 'running' && Array.from(document.querySelectorAll('.run-page .chip')).some(c => c.textContent === 'OK') && Array.from(document.querySelectorAll('.run-page .chip')).some(c => c.textContent === 'Running…'), 20000);
const liveStatus = document.querySelector('.run-state').textContent;
btnByKey('run-stop').click();
await until(() => S.run.state === 'done' || S.run.state === 'failed', 30000);
S.config.name = 'fake:die';
btnByKey('run-all').click();
await until(() => S.run.state === 'failed', 30000);
const callout = document.querySelector('#panel-run .callout-error');
const rows = Array.from(document.querySelectorAll('.run-page')).map(li => li.querySelector('.chip').textContent);
const failedStatus = document.querySelector('.run-state').textContent;
D.setTab('pages');
const pageChip = document.querySelectorAll('.page-row .chip')[0].textContent;
D.setTab('run');
return { live: !!firstDone, liveStatus, failedStatus, state: S.run.state, failed: callout ? callout.textContent : '', rows, pageChip, errs: window.__errs };
'@
        $r.live | Should -BeTrue
        $r.liveStatus | Should -Match 'Running…'
        $r.liveStatus | Should -Match 'of 6 pages done'
        # The page the run died on is not counted as done.
        $r.failedStatus | Should -Match '0 of 1 page done'
        $r.state | Should -Be 'failed'
        $r.failed | Should -Match 'ended unexpectedly \(exit code 7\)'
        $r.failed | Should -Match 'Something broke badly inside the run'
        $r.failed | Should -Match 'What to do: Try again'
        $r.rows | Should -Be @('Not finished')
        $r.pageChip | Should -Match '^Run: not finished \d\d:\d\d$'
    }

    It 'had no CSP violation, error or rejection in the whole session' {
        $r = Invoke-RunPanel 'return { errs: window.__errs, collector: Array.isArray(window.__errs) };'
        $r.collector | Should -BeTrue
        @($r.errs).Count | Should -Be 0 -Because ($r.errs -join "`n")
    }

    It 'asks before closing the Designer during a run, stops the run first, then ends' {
        $r = Invoke-RunPanel -TimeoutSec 60 @'
S.config.name = 'fake:slow';
D.setTab('run');
btnByKey('run-all').click();
await until(() => S.run.state === 'running', 15000);
btnByKey('btn:Close').click();
await until(() => document.querySelector('#modal').open, 5000);
const title = document.querySelector('#modal-title').textContent;
Array.from(document.querySelectorAll('#modal-buttons button')).find(b => b.textContent === 'Stop the run and close').click();
await until(() => document.querySelector('#modal').open && document.querySelector('#modal-title').textContent !== title, 3000);
const second = document.querySelector('#modal').open ? document.querySelector('#modal-title').textContent : '';
if (document.querySelector('#modal').open) Array.from(document.querySelectorAll('#modal-buttons button')).find(b => b.textContent === 'Don’t save').click();
await until(() => S.closed, 10000);
return { title, second, closed: S.closed, text: document.querySelector('#app').textContent };
'@
        $r.title | Should -Be 'A run is going'
        # Unsaved changes are asked about next, in the same dialog, without the first answer closing it.
        $r.second | Should -Be 'Save your changes first?'
        $r.closed | Should -BeTrue
        $r.text | Should -Match 'The run is being stopped'
        $children = Get-RunUiChild
        $script:RunUi.Process.WaitForExit(30000) | Should -BeTrue
        foreach ($child in $children) { Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
        [System.IO.File]::ReadAllBytes($script:RunUiFile) | Should -Be $script:RunUiBytes
    }
}
