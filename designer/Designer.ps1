#Requires -Version 7
<#
    Vouch Designer: the local web server behind the Designer panel.

    Functions only. vouch.ps1 dot-sources this file in -Designer mode (Invoke-DesignerMode);
    the tests load it together with vouch.ps1 through Get-VouchFunctionSource. It uses the
    engine's own configuration functions (ConvertFrom-VouchJson, Test-VouchConfig,
    Get-VouchConfigSchema, Resolve-RunSettings, ...) so the panel and a run can never
    disagree about what a configuration file means.

    Security model, in short: the server listens on http://localhost:<port>/ only. Every
    /api/ and /preview/ request must carry the session token (X-Vouch-Token), come from
    the panel's own origin, and name only files that the server itself handed out in this
    session. The page is served with a strict Content-Security-Policy and no CORS headers.
#>

#region State and request checks ------------------------------------------------

function New-DesignerToken {
    <#
        256 random bits from the operating system's generator, as URL-safe text. The token
        is the only thing that tells the panel's requests from those of any other web page
        open on this computer, so it must not be guessable.
    #>
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-DesignerState {
    <#
        Everything the server knows about this session, in one object that is passed to
        every handler. The router never reads globals, so the tests can build a state,
        call Invoke-DesignerRequest and look at the answer without a socket.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$Port,
        [string]$Token = '',
        [AllowEmptyString()][string]$Version = '',
        [string]$DesignerDirectory = ''
    )
    if (-not $Token) { $Token = New-DesignerToken }
    if (-not $DesignerDirectory) { $DesignerDirectory = Join-Path -Path (Split-Path -Path $ScriptPath -Parent) -ChildPath 'designer' }
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    return [pscustomobject]@{
        Version              = $Version
        ScriptPath           = [System.IO.Path]::GetFullPath($ScriptPath)
        DesignerDirectory    = [System.IO.Path]::GetFullPath($DesignerDirectory)
        Port                 = $Port
        Token                = $Token
        HostHeader           = "localhost:$Port"
        Origin               = "http://localhost:$Port"
        StartupPath          = ''
        ConfigPath           = ''
        # Paths handed to the panel, kept apart by kind (Add-DesignerKnownPath).
        KnownPaths           = @{
            config = [System.Collections.Generic.HashSet[string]]::new($comparer)
            csv    = [System.Collections.Generic.HashSet[string]]::new($comparer)
            image  = [System.Collections.Generic.HashSet[string]]::new($comparer)
            folder = [System.Collections.Generic.HashSet[string]]::new($comparer)
        }
        # The audit browser profile in effect (Get-DesignerAuditProfile), for the profile guard.
        AuditProfileDir      = ''
        PendingCommentNotice = $false
        # Paths the last run produced, by kind (report, folder, log, zip, preview-report):
        # filled only from that run's runEnd event (Complete-DesignerRun).
        OpenTargets          = [ordered]@{}
        # Tests only: append the path to this file instead of opening it (no window).
        OpenLog              = ''
        Running              = $true
        StopReason           = ''
        PanelProcess         = $null
        PanelStartedAt       = [datetime]::MinValue
        # The panel process's own start time: a process found later under the same id with
        # another start time is not the panel (Test-DesignerProcessExited).
        PanelProcessStart    = [datetime]::MinValue
        PanelProfileDir      = ''
        # Called once per loop turn (about every 200 ms) with the state: the hook later
        # steps use to follow the browser and a run without blocking the server.
        TickHandlers         = [System.Collections.Generic.List[scriptblock]]::new()
        ParameterInfo        = $null
        Schema               = $null
        MaxBodyBytes         = 4MB
        # How long a request body may take to arrive once its headers are in: the loop
        # serves one request at a time, so a sender that stalls must not hold it up.
        BodyTimeoutMs        = 5000
        # The saved configuration as last read (Get-DesignerSavedConfig).
        ConfigCache          = $null
        # The link to the audit Edge (Connect-DesignerBrowser) and the pick in progress.
        Browser              = New-DesignerBrowserState
        Pick                 = New-DesignerPickState
        # Runs (designer\Designer.Run.ps1): the run in progress or the last one, the script a
        # run starts (vouch.ps1; a stand-in in tests), the session's temporary folder, the
        # previews of page tests (id -> files) and each page's last result in this session.
        Run                  = New-DesignerRunState
        RunScriptPath        = [System.IO.Path]::GetFullPath($ScriptPath)
        RunParameterInfo     = $null
        RunCount             = 0
        SessionFolder        = ''
        Previews             = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        PageResults          = [ordered]@{}
        # /api/shutdown during a run: stop it first, then end the loop.
        ShutdownAfterRun     = $false
        StartedAt            = Get-Date
    }
}

function New-DesignerBrowserState {
    <#
        What the Designer knows about the audit Edge. The DevTools socket itself is the
        engine's ($script:CdpSocket), because the engine's own functions (clicks, waits,
        zoom) are what the Designer uses on the page; this object says which tab that
        socket is attached to and why it is or is not connected.
    #>
    return [pscustomobject]@{
        Connected          = $false
        Connecting         = $false
        # Connect at the first loop turn (Start-VouchDesigner), after the panel has loaded.
        ConnectPending     = $false
        # Plumbing for tests: attach to an Edge already listening, never start one.
        AllowLaunch        = $true
        # -DebugPort / -EdgeProfileDir / -KeepBrowserOpen typed on the command line (0/''/$false: not typed).
        TypedPort          = 0
        TypedProfileDir    = ''
        TypedKeepOpen      = $false
        Port               = 0
        ProfileDir         = ''
        KeepOpen           = $false
        TabId              = ''
        Url                = ''
        Title              = ''
        Tabs               = @()
        LaunchedByDesigner = $false
        LaunchedPid        = 0
        BrowserWsUrl       = ''
        Problem            = $null
        Notice             = ''
        # The zoom shown for a page opened with Go (100 = none), and that page's name.
        ZoomPercent        = 100
        ZoomPage           = ''
        LastCheck          = [datetime]::MinValue
        LastProbe          = [datetime]::MinValue
        LastSweep          = [datetime]::MinValue
    }
}

function New-DesignerPickState {
    # The pick in progress or last finished (Start-ElementPick, Get-ElementPickResult).
    return [pscustomobject]@{
        State     = 'idle'
        Mode      = ''
        Token     = ''
        TabId     = ''
        Result    = $null
        Message   = ''
        Code      = ''
        Notice    = ''
        # The picker's current note (Get-DesignerPickNote words), '' when it has none.
        PageNote  = ''
        Reinjects = 0
        Failures  = 0
        # The browser's id for the shield script (Add-ElementPickShield), '' when there is none.
        ShieldId  = ''
        StartedAt = [datetime]::MinValue
        LastPoll  = [datetime]::MinValue
    }
}

function Resolve-DesignerPath {
    # A full, normalised path, or '' when the text is not a usable Windows path.
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [System.IO.Path]::GetFullPath($Path.Trim()) }
    catch { return '' }
}

function Add-DesignerKnownPath {
    <#
        Remembers a path the server handed to the panel (from a dialog, an open or a save).
        Only such paths may come back in a later request: the panel can never name a file
        on its own, so even a page that stole the token could not read or write anything
        the person did not pick. Paths are kept by kind (config, csv, image, folder) and a
        route accepts only its own kind, so a picked logo or CSV can never be overwritten
        by a configuration save.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('config', 'csv', 'image', 'folder')][string]$Kind
    )
    $full = Resolve-DesignerPath -Path $Path
    if ($full) { [void]$State.KnownPaths[$Kind].Add($full) }
    return $full
}

function Test-DesignerKnownPath {
    param(
        [Parameter(Mandatory)][object]$State,
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('config', 'csv', 'image', 'folder')][string]$Kind
    )
    $full = Resolve-DesignerPath -Path $Path
    return [bool]($full -and $State.KnownPaths[$Kind].Contains($full))
}

function Test-DesignerTokenMatch {
    <#
        Constant-time comparison, so the time an answer takes says nothing about how much
        of a guessed token was right.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Given,
        [Parameter(Mandatory)][string]$Expected
    )
    if ([string]::IsNullOrEmpty($Given)) { return $false }
    $a = [System.Text.Encoding]::UTF8.GetBytes($Given)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $b)
}

function Get-DesignerAsset {
    <#
        The only files the server ever reads from disk for a GET: an explicit list, so no
        request path can reach another file in the folder or outside it.
    #>
    param([Parameter(Mandatory)][string]$Path)
    switch -CaseSensitive ($Path) {
        '/'           { return @{ File = 'index.html'; ContentType = 'text/html; charset=utf-8' } }
        '/index.html' { return @{ File = 'index.html'; ContentType = 'text/html; charset=utf-8' } }
        '/app.js'     { return @{ File = 'app.js'; ContentType = 'text/javascript; charset=utf-8' } }
        '/app.css'    { return @{ File = 'app.css'; ContentType = 'text/css; charset=utf-8' } }
    }
    return $null
}

function New-DesignerRequest {
    <#
        One request as the gate and the router see it. The listener builds it from the
        HttpListener context; the tests build it directly. The body is parsed here with the
        engine's JSON reader (ordered, case-insensitive dictionaries); a body that cannot be
        parsed is kept as BodyError for the gate to refuse.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.IDictionary]$Headers = @{},
        [AllowEmptyString()][string]$BodyText = '',
        [switch]$BodyTooLarge,
        # The declared Content-Length; -1 when none was sent (chunked) or not known.
        [long]$ContentLength = -1
    )
    $headerTable = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Headers.Keys) { $headerTable[[string]$key] = [string]$Headers[$key] }
    $body = [ordered]@{}
    $bodyError = ''
    if (-not $BodyTooLarge -and -not [string]::IsNullOrWhiteSpace($BodyText)) {
        try { $body = ConvertFrom-VouchJson -Text $BodyText }
        catch { $bodyError = $_.Exception.Message }
    }
    return [pscustomobject]@{
        Method       = $Method.ToUpperInvariant()
        Path         = $Path
        Headers      = $headerTable
        BodyText     = $BodyText
        BodyTooLarge = [bool]$BodyTooLarge
        ContentLength = $ContentLength
        Body         = $body
        BodyError    = $bodyError
    }
}

function Get-DesignerPathRoute {
    # The routes whose body may name a file ("path"), and the kind of file each accepts.
    return @{
        '/api/config/open'       = 'config'
        '/api/config/save'       = 'config'
        '/api/command'           = 'config'
        '/api/run'               = 'config'
        '/api/run/plan'          = 'config'
        '/api/config/import-csv' = 'csv'
    }
}

function Test-DesignerRequest {
    <#
        The whole gate for a request whose body is already read (the tests, and the
        router's callers): the header checks, then the body checks.
    #>
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$State
    )
    $refusal = Test-DesignerRequestHeader -Request $Request -State $State
    if ($null -ne $refusal) { return $refusal }
    return Test-DesignerRequestBody -Request $Request -State $State
}

function Test-DesignerRequestHeader {
    <#
        The security gate in front of the router, first half: everything that can be
        decided from the request line and headers, BEFORE a byte of the body is read -
        so a page in another tab cannot make the single-threaded server read or parse
        megabytes just to be refused. Returns $null when the request may proceed,
        otherwise the refusal to send. Each rule closes a door a web page in another tab
        could use:
        - Host must be exactly localhost:<port> (DNS rebinding; http.sys already refuses
          most, this is the second lock).
        - A foreign Origin, or a cross-site Sec-Fetch-Site, is refused for every path.
        - OPTIONS is refused and no CORS header is ever sent, so no other origin can read
          an answer.
        - /api/ and /preview/ need the session token in X-Vouch-Token.
        - A POST must carry our Origin and Content-Type: application/json (a plain HTML
          form can send neither) and declare no more than the size limit (413).
        The body rules (too large while streaming, valid JSON, known "path") are in
        Test-DesignerRequestBody.
    #>
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$State
    )
    $header = { param($Name) if ($Request.Headers.ContainsKey($Name)) { [string]$Request.Headers[$Name] } else { '' } }

    if ((& $header 'Host') -cne $State.HostHeader) {
        return New-DesignerError -Status 400 -Code 'wrong-host' -Message 'This address is not the Vouch Designer.' -Detail "Open the Designer at http://localhost:$($State.Port)/ (start it with Vouch-Designer.cmd)."
    }
    $origin = & $header 'Origin'
    if ($origin -and $origin -cne $State.Origin) {
        return New-DesignerError -Status 403 -Code 'foreign-origin' -Message 'This request came from another web page and was refused.' -Detail 'Only the Vouch Designer window may use the Designer.'
    }
    $site = & $header 'Sec-Fetch-Site'
    if ($site -and $site -notin 'same-origin', 'none') {
        return New-DesignerError -Status 403 -Code 'cross-site' -Message 'This request came from another web page and was refused.' -Detail 'Only the Vouch Designer window may use the Designer.'
    }
    if ($Request.Method -eq 'OPTIONS') {
        return New-DesignerError -Status 403 -Code 'no-cors' -Message 'Requests from other web pages are not allowed.' -Detail 'The Vouch Designer does not share anything with other web sites.'
    }
    if ($Request.Method -notin 'GET', 'POST') {
        return New-DesignerError -Status 405 -Code 'method' -Message 'This kind of request is not supported.' -Detail "The Designer answers GET and POST only (got $($Request.Method))."
    }

    $protected = $Request.Path.StartsWith('/api/', [System.StringComparison]::Ordinal) -or
        $Request.Path -eq '/api' -or $Request.Path.StartsWith('/preview/', [System.StringComparison]::Ordinal)
    if (-not $protected) {
        if ($Request.Method -ne 'GET') {
            return New-DesignerError -Status 405 -Code 'method' -Message 'This kind of request is not supported.' -Detail 'Only the Designer page itself can be loaded here.'
        }
        return $null
    }

    if (-not (Test-DesignerTokenMatch -Given (& $header 'X-Vouch-Token') -Expected $State.Token)) {
        return New-DesignerError -Status 403 -Code 'token' -Message 'This request did not come from the Vouch Designer window.' -Detail 'Close this window and start the Designer again with Vouch-Designer.cmd.'
    }
    if ($Request.Method -eq 'POST') {
        if (-not $origin) {
            return New-DesignerError -Status 403 -Code 'no-origin' -Message 'This request did not say where it came from and was refused.' -Detail 'Only the Vouch Designer window may change anything.'
        }
        $mediaType = ((& $header 'Content-Type') -split ';')[0].Trim()
        if ($mediaType -ne 'application/json') {
            return New-DesignerError -Status 415 -Code 'content-type' -Message 'The request was not in the expected form.' -Detail 'The Designer accepts JSON only (Content-Type: application/json).'
        }
        if ($Request.ContentLength -gt $State.MaxBodyBytes) {
            return New-DesignerError -Status 413 -Code 'too-large' -Message 'The request is too large.' -Detail "A configuration sent to the Designer may be at most $([int]($State.MaxBodyBytes / 1MB)) MB."
        }
    }
    return $null
}

function Test-DesignerRequestBody {
    <#
        The gate's second half, after the body was read (up to the size limit): too
        large while streaming, not JSON, or a "path" that is not one the server handed
        out in this session for this kind of file.
    #>
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$State
    )
    if ($Request.Method -eq 'POST') {
        if ($Request.BodyTooLarge) {
            return New-DesignerError -Status 413 -Code 'too-large' -Message 'The request is too large.' -Detail "A configuration sent to the Designer may be at most $([int]($State.MaxBodyBytes / 1MB)) MB."
        }
        if ($Request.BodyError) {
            return New-DesignerError -Status 400 -Code 'bad-json' -Message 'The request was not understood.' -Detail 'Its content is not valid JSON.'
        }
    }
    $routes = Get-DesignerPathRoute
    if ($routes.ContainsKey($Request.Path)) {
        $path = Get-DesignerBodyText -Body $Request.Body -Name 'path'
        if ($path -and -not (Test-DesignerKnownPath -State $State -Path $path -Kind $routes[$Request.Path])) {
            return New-DesignerError -Status 403 -Code 'unknown-path' -Message 'That file was not chosen in the Designer.' -Detail 'Choose the file with Open, Save As or Browse; the Designer only uses files picked in its own dialogs.'
        }
    }
    return $null
}

#endregion

#region Responses ----------------------------------------------------------------

function New-DesignerResponse {
    # The response object the router returns and Send-DesignerResponse writes.
    param(
        [int]$Status = 200,
        [string]$ContentType = 'application/json; charset=utf-8',
        [AllowNull()][object]$Body = '',
        [System.Collections.IDictionary]$Headers = @{}
    )
    return [pscustomobject]@{ Status = $Status; ContentType = $ContentType; Body = $Body; Headers = $Headers }
}

function New-DesignerJsonResponse {
    <#
        A JSON answer. ConvertTo-Json keeps the ordered dictionaries' key order and writes
        Int64 and Double as numbers, which is what the panel needs for the configuration.
    #>
    param(
        [AllowNull()][object]$Data,
        [int]$Status = 200
    )
    $json = if ($null -eq $Data) { 'null' } else { ConvertTo-Json -InputObject $Data -Depth 64 -Compress }
    return New-DesignerResponse -Status $Status -Body $json
}

function New-DesignerError {
    <#
        Every error is { error, detail, code }: plain sentences for the panel to show, and
        a short code for programs. Never a stack trace or a .NET type name.
    #>
    param(
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$Detail = '',
        [string]$Code = '',
        [System.Collections.IDictionary]$Extra = @{}
    )
    $data = [ordered]@{ error = $Message; detail = $Detail; code = $Code }
    foreach ($key in $Extra.Keys) { $data[$key] = $Extra[$key] }
    return New-DesignerJsonResponse -Status $Status -Data $data
}

function Get-DesignerSecurityHeader {
    <#
        Sent with every answer. The policy allows only the panel's own script, style sheet
        and connections (and data: images for the logo preview): no inline script or style,
        no framing, no forms, no other site. no-store keeps the token-bearing page and the
        configuration out of the browser's cache.
    #>
    return [ordered]@{
        'Content-Security-Policy'      = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        'X-Content-Type-Options'       = 'nosniff'
        'Cache-Control'                = 'no-store'
        'Referrer-Policy'              = 'no-referrer'
        'X-Frame-Options'              = 'DENY'
        'Cross-Origin-Resource-Policy' = 'same-origin'
        'Cross-Origin-Opener-Policy'   = 'same-origin'
    }
}

function Send-DesignerResponse {
    <#
        Writes one response. A panel that went away mid-answer must not stop the server,
        so write errors are swallowed.
    #>
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][object]$Response
    )
    $out = $Context.Response
    try {
        $out.StatusCode = $Response.Status
        $security = Get-DesignerSecurityHeader
        foreach ($key in $security.Keys) { $out.Headers[$key] = $security[$key] }
        foreach ($key in $Response.Headers.Keys) { $out.Headers[[string]$key] = [string]$Response.Headers[$key] }
        $bytes = if ($Response.Body -is [byte[]]) { $Response.Body } else { [System.Text.Encoding]::UTF8.GetBytes([string]$Response.Body) }
        if ($Response.Status -ne 204) {
            $out.ContentType = $Response.ContentType
            $out.ContentLength64 = $bytes.Length
            $out.OutputStream.Write($bytes, 0, $bytes.Length)
        }
    }
    catch {
        Write-Verbose "Could not send the answer: $($_.Exception.Message)"
    }
    finally {
        try { $out.Close() } catch { Write-Verbose 'The connection was already closed.' }
    }
}

#endregion

#region Router -------------------------------------------------------------------

function Get-DesignerBodyText {
    # A text value from a request body, '' when missing or not text.
    param([AllowNull()][object]$Body, [Parameter(Mandatory)][string]$Name)
    if ($Body -is [System.Collections.IDictionary] -and $Body.Contains($Name) -and $Body[$Name] -is [string]) { return [string]$Body[$Name] }
    return ''
}

function Get-DesignerLaterRoute {
    <#
        Endpoints a later step implements answer 501 with a plain message, so the panel
        can be built against them before. None are left; the table stays for the next.
    #>
    return [ordered]@{}
}

function Get-DesignerQueryNumber {
    # A whole number from the query string (?since=12), or -Default.
    param([AllowEmptyString()][string]$Query = '', [Parameter(Mandatory)][string]$Name, [int]$Default = 0)
    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        $parts = $pair.Split('=', 2)
        $value = 0
        if ($parts.Count -eq 2 -and $parts[0] -ceq $Name -and [int]::TryParse($parts[1], [ref]$value)) { return $value }
    }
    return $Default
}

function Invoke-DesignerRequest {
    <#
        The router: method + path + parsed body + state in, a response object out. Pure
        apart from what the handlers do on purpose (file dialogs, reading and writing the
        chosen files), so every route can be tested without a socket. Assumes the request
        passed Test-DesignerRequest; the file-path rule is checked again here anyway.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Body = $null,
        [Parameter(Mandatory)][object]$State,
        # The query string of a GET (GET /api/run?since=12), '' when none.
        [AllowEmptyString()][string]$Query = ''
    )
    if ($Body -isnot [System.Collections.IDictionary]) { $Body = [ordered]@{} }
    $Method = $Method.ToUpperInvariant()
    try {
        $asset = Get-DesignerAsset -Path $Path
        if ($null -ne $asset) {
            if ($Method -ne 'GET') { return New-DesignerError -Status 405 -Code 'method' -Message 'This kind of request is not supported.' }
            return Get-DesignerStaticResponse -Asset $asset -State $State
        }
        if ($Path -eq '/favicon.ico') { return New-DesignerResponse -Status 204 }

        $pathRoutes = Get-DesignerPathRoute
        if ($pathRoutes.ContainsKey($Path)) {
            $named = Get-DesignerBodyText -Body $Body -Name 'path'
            if ($named -and -not (Test-DesignerKnownPath -State $State -Path $named -Kind $pathRoutes[$Path])) {
                return New-DesignerError -Status 403 -Code 'unknown-path' -Message 'That file was not chosen in the Designer.' -Detail 'Choose the file with Open, Save As or Browse.'
            }
        }

        $route = "$Method $Path"
        $busy = Get-DesignerRunRefusal -State $State -Route $route
        if ($null -ne $busy) { return $busy }
        switch -CaseSensitive ($route) {
            'GET /api/state'               { return New-DesignerJsonResponse -Data (Get-DesignerStateData -State $State) }
            'POST /api/config/new'         { return Invoke-DesignerNewConfig -State $State }
            'POST /api/config/open'        { return Invoke-DesignerOpenConfig -Body $Body -State $State }
            'POST /api/config/save'        { return Invoke-DesignerSaveConfig -Body $Body -State $State }
            'POST /api/config/import-csv'  { return Invoke-DesignerImportCsv -Body $Body -State $State }
            'POST /api/config/validate'    { return Invoke-DesignerValidateConfig -Body $Body -State $State }
            'POST /api/dialog'             { return Invoke-DesignerDialog -Body $Body -State $State }
            'POST /api/command'            { return Invoke-DesignerCommand -Body $Body -State $State }
            'POST /api/open'               { return Invoke-DesignerOpenTarget -Body $Body -State $State }
            'GET /api/browser/current'     { return Invoke-DesignerBrowserCurrent -State $State }
            'POST /api/browser/connect'    { return Invoke-DesignerBrowserConnect -State $State }
            'POST /api/browser/navigate'   { return Invoke-DesignerNavigate -Body $Body -State $State }
            'POST /api/browser/layout'     { return Invoke-DesignerLayoutRequest -State $State }
            'POST /api/browser/zoom-off'   { return Invoke-DesignerZoomOff -State $State }
            'POST /api/page/from-current'  { return Invoke-DesignerPageFromCurrent -State $State }
            'POST /api/pick/start'         { return Invoke-DesignerPickStart -Body $Body -State $State }
            'GET /api/pick'                { return New-DesignerJsonResponse -Data (Get-ElementPickResult -State $State) }
            'POST /api/pick/cancel'        { return Invoke-DesignerPickCancel -State $State }
            'POST /api/action/test'        { return Invoke-DesignerActionTest -Body $Body -State $State }
            'POST /api/run'                { return Invoke-DesignerRunStart -Body $Body -State $State }
            'GET /api/run'                 { return New-DesignerJsonResponse -Data (Get-DesignerRunData -State $State -Since (Get-DesignerQueryNumber -Query $Query -Name 'since')) }
            'POST /api/run/plan'           { return Invoke-DesignerRunPlan -Body $Body -State $State }
            'POST /api/run/stop'           { return Invoke-DesignerRunStop -Body $Body -State $State }
            'POST /api/shutdown' {
                if (Test-DesignerRunActive -State $State) {
                    # Closing during a run: the panel asked the person first; stop the run
                    # cleanly, and the loop ends when it has (Complete-DesignerRun).
                    if ($Body['stopRun'] -ne $true) {
                        return New-DesignerError -Status 409 -Code 'running' -Message 'A run is going.' -Detail 'Stop the run first, or confirm closing the Designer, which stops it.'
                    }
                    $State.ShutdownAfterRun = $true
                    [void](Stop-DesignerRun -State $State)
                    return New-DesignerJsonResponse -Data ([ordered]@{ ok = $true; waiting = $true; message = 'Stopping the run first; the Vouch Designer closes when it has stopped.' })
                }
                $State.Running = $false
                $State.StopReason = 'The Designer was closed from its window.'
                return New-DesignerJsonResponse -Data ([ordered]@{ ok = $true; message = 'The Vouch Designer has stopped. You can close this window.' })
            }
        }

        $later = Get-DesignerLaterRoute
        if ($later.Contains($route)) {
            return New-DesignerError -Status 501 -Code 'later' -Message 'Not available yet.' -Detail $later[$route]
        }
        if ($Path.StartsWith('/preview/', [System.StringComparison]::Ordinal)) {
            return Invoke-DesignerPreview -Method $Method -Path $Path -State $State
        }
        foreach ($known in @('/api/state', '/api/config/new', '/api/config/open', '/api/config/save', '/api/config/import-csv', '/api/config/validate',
                '/api/dialog', '/api/command', '/api/open', '/api/shutdown', '/api/browser/current', '/api/browser/connect', '/api/browser/navigate',
                '/api/browser/layout', '/api/browser/zoom-off', '/api/page/from-current', '/api/pick/start', '/api/pick', '/api/pick/cancel',
                '/api/action/test', '/api/run', '/api/run/plan', '/api/run/stop') + @($later.Keys | ForEach-Object { ($_ -split ' ', 2)[1] })) {
            if ($known -ceq $Path) { return New-DesignerError -Status 405 -Code 'method' -Message 'This kind of request is not supported here.' -Detail "$Method is not used for $Path." }
        }
        return New-DesignerError -Status 404 -Code 'not-found' -Message 'There is nothing at this address.' -Detail $Path
    }
    catch {
        return New-DesignerError -Status 500 -Code 'failed' -Message 'Something went wrong in the Designer.' -Detail ([string]$_.Exception.Message)
    }
}

function Get-DesignerStaticResponse {
    # One of the allow-listed panel files, read fresh (no cache; editing them needs no restart).
    param([Parameter(Mandatory)][hashtable]$Asset, [Parameter(Mandatory)][object]$State)
    $file = Join-Path -Path $State.DesignerDirectory -ChildPath $Asset.File
    if (-not [System.IO.File]::Exists($file)) {
        return New-DesignerError -Status 404 -Code 'not-found' -Message 'A file of the Designer is missing.' -Detail "$($Asset.File) is not in $($State.DesignerDirectory). Copy the whole Vouch folder again."
    }
    return New-DesignerResponse -ContentType $Asset.ContentType -Body ([System.IO.File]::ReadAllBytes($file))
}

function Get-DesignerSchema {
    <#
        The configuration schema in the form the panel uses: every setting by its dotted
        path with type, range, choices and default, and the action kinds with their keys.
        Built from Get-VouchConfigSchema / Get-VouchActionSchema, so the panel never keeps
        its own copy of a default or a range.
    #>
    $settings = [ordered]@{}
    $walk = {
        param($Fields, $Prefix)
        foreach ($key in $Fields.Keys) {
            $spec = $Fields[$key]
            $path = if ($Prefix) { "$Prefix.$key" } else { $key }
            if ($spec.Type -eq 'object') { & $walk $spec.Fields $path; continue }
            if ($spec.Type -eq 'pages') { continue }
            $entry = [ordered]@{ type = $spec.Type }
            foreach ($name in 'Min', 'Max', 'Default') { if ($spec.Contains($name)) { $entry[$name.ToLowerInvariant()] = $spec[$name] } }
            if ($spec.Contains('Allowed')) { $entry['allowed'] = @($spec.Allowed) }
            $settings[$path] = $entry
        }
    }
    & $walk (Get-VouchConfigSchema) ''
    $actions = [ordered]@{}
    $actionSchema = Get-VouchActionSchema
    foreach ($type in $actionSchema.Keys) {
        $keys = [ordered]@{}
        foreach ($key in $actionSchema[$type].Keys) {
            $spec = $actionSchema[$type][$key]
            $entry = [ordered]@{ type = $spec.Type; required = $spec.Contains('Required') }
            foreach ($name in 'Min', 'Max') { if ($spec.Contains($name)) { $entry[$name.ToLowerInvariant()] = $spec[$name] } }
            if ($spec.Type -eq 'object') {
                $fields = [ordered]@{}
                foreach ($field in $spec.Fields.Keys) {
                    $f = $spec.Fields[$field]
                    $fields[$field] = [ordered]@{ type = $f['Type']; default = $f['Default']; allowed = $(if ($f.Contains('Allowed')) { @($f['Allowed']) } else { @() }) }
                }
                $entry['fields'] = $fields
            }
            $keys[$key] = $entry
        }
        $actions[$type] = $keys
    }
    return [ordered]@{
        settings     = $settings
        actions      = $actions
        pageKeys     = @('id', 'name', 'url', 'notes', 'enabled', 'overrides', 'actions')
        overrideKeys = @((Get-VouchConfigSchema)['defaults'].Fields.Keys)
    }
}

function Get-DesignerStateData {
    <#
        GET /api/state: facts about the server, not about the configuration (the panel owns
        that): the link to the audit browser as last seen (no browser call is made here;
        the loop keeps it current), what the panel may offer, and the run's state
        (the details come from GET /api/run). A run needs the connected audit Edge.
    #>
    param([Parameter(Mandatory)][object]$State)
    if ($null -eq $State.Schema) { $State.Schema = Get-DesignerSchema }
    $connected = [bool]$State.Browser.Connected
    $running = Test-DesignerRunActive -State $State
    return [ordered]@{
        version      = $State.Version
        port         = $State.Port
        configPath   = $State.ConfigPath
        startupPath  = $State.StartupPath
        scriptFolder = (Split-Path -Path $State.ScriptPath -Parent)
        browser      = (Get-DesignerBrowserData -State $State)
        pick         = [ordered]@{ state = $State.Pick.State }
        run          = (Get-DesignerRunSummary -State $State)
        capabilities = [ordered]@{ browser = $connected; pick = $connected; test = $connected; run = ($connected -or $running) }
        schema       = $State.Schema
        defaults     = Get-DefaultVouchConfig
    }
}

function Get-DesignerFolder {
    # Where dialogs start: the current file's folder, else the Vouch folder.
    param([Parameter(Mandatory)][object]$State)
    if ($State.ConfigPath) { return (Split-Path -Path $State.ConfigPath -Parent) }
    return (Split-Path -Path $State.ScriptPath -Parent)
}

function ConvertTo-DesignerProblem {
    <#
        Validation problems for the panel: the path, the engine's message, and the message
        without the hints that only make sense to someone typing JSON ("without quotes").
    #>
    param([AllowNull()][object]$Problems)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($problem in @($Problems)) {
        if ($null -eq $problem) { continue }
        $text = [string]$problem.Message
        foreach ($noise in ', without quotes', ' in double quotes', '; use a dot for decimals') { $text = $text.Replace($noise, '') }
        $list.Add([ordered]@{ path = [string]$problem.Path; message = [string]$problem.Message; text = $text })
    }
    return , $list.ToArray()
}

function Invoke-DesignerNewConfig {
    # POST /api/config/new: a configuration holding every default and no pages.
    param([Parameter(Mandatory)][object]$State)
    $State.ConfigPath = ''
    $State.PendingCommentNotice = $false
    return New-DesignerJsonResponse -Data ([ordered]@{ path = ''; name = ''; config = (Get-DefaultVouchConfig); errors = @(); warnings = @() })
}

function Test-VouchJsonComment {
    # Whether the text holds comments (or trailing commas), which a save does not keep.
    param([Parameter(Mandatory)][string]$Text)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Text, $options)
        $document.Dispose()
        return $false
    }
    catch { return $true }
}

function Read-DesignerConfigFile {
    <#
        Reads a configuration file as written: no defaults filled in and relative paths
        left relative (the engine resolves them only for a run). Only the spelling of
        known keys is made canonical, which changes nothing for the engine (it ignores
        capitals) but lets the panel find them. Throws a plain message.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { throw "The file '$Path' is not there any more." }
    $text = [System.IO.File]::ReadAllText($Path)
    $config = ConvertFrom-VouchJson -Text $text
    return [pscustomobject]@{ Config = (Repair-VouchConfigKeyCase -Config $config); Text = $text }
}

function Get-DesignerLogoPreview {
    <#
        The logo as a data: image for the Report tab, read the way the report will read it
        (Get-LogoDataUri: type from content, size limit). Only for a logo named by a file
        the person opened or picked; '' when there is none.
    #>
    param([AllowEmptyString()][string]$LogoPath = '', [AllowEmptyString()][string]$ConfigPath = '')
    if ([string]::IsNullOrWhiteSpace($LogoPath)) { return $null }
    $base = if ($ConfigPath) { Split-Path -Path $ConfigPath -Parent } else { '' }
    $full = if ([System.IO.Path]::IsPathFullyQualified($LogoPath)) { $LogoPath } elseif ($base) { Resolve-VouchConfigPath -Path $LogoPath -BaseDirectory $base } else { '' }
    if (-not $full) {
        return [ordered]@{ path = $LogoPath; dataUri = ''; warning = 'Save the configuration first: a relative logo path is read from the folder of the configuration file.' }
    }
    $logo = Get-LogoDataUri -Path $full
    return [ordered]@{ path = $full; dataUri = $logo.DataUri; warning = $logo.Warning }
}

function Invoke-DesignerOpenConfig {
    <#
        POST /api/config/open {path?}: the file as written plus its problems. A file with
        problems still opens (the panel is where they get fixed); one that is not JSON
        cannot. Without a path, the Open dialog asks.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $path = Get-DesignerBodyText -Body $Body -Name 'path'
    if (-not $path) {
        $path = Show-DesignerFileDialog -Kind open -Title 'Open a Vouch configuration' -Filter (Get-DesignerDialogFilter -Kind 'config') -InitialDirectory (Get-DesignerFolder -State $State)
        if (-not $path) { return New-DesignerJsonResponse -Data ([ordered]@{ cancelled = $true }) }
    }
    $path = Add-DesignerKnownPath -State $State -Path $path -Kind config
    try { $file = Read-DesignerConfigFile -Path $path }
    catch {
        return New-DesignerError -Status 422 -Code 'unreadable' -Message "'$([System.IO.Path]::GetFileName($path))' cannot be opened." -Detail ([string]$_.Exception.Message)
    }
    $check = Test-VouchConfig -Config $file.Config
    $hasComments = Test-VouchJsonComment -Text $file.Text
    $State.ConfigPath = $path
    $State.PendingCommentNotice = $hasComments
    # No logo preview here: opening a file must not touch any path named inside it (a
    # \\server\share logo would make Windows send this user's credentials to that
    # server). The panel previews a logo only when it is picked with Browse.
    $logo = $null
    return New-DesignerJsonResponse -Data ([ordered]@{
            path        = $path
            name        = [System.IO.Path]::GetFileName($path)
            folder      = (Split-Path -Path $path -Parent)
            config      = $file.Config
            errors      = (ConvertTo-DesignerProblem -Problems $check.Errors)
            warnings    = (ConvertTo-DesignerProblem -Problems $check.Warnings)
            hasComments = $hasComments
            logo        = $logo
        })
}

function Get-DesignerCommentNotice {
    return 'The comments (// or /* */) that were in this file were not kept: the Designer writes the file afresh. Keep notes in the pages'' "notes" instead.'
}

function Invoke-DesignerSaveConfig {
    <#
        POST /api/config/save {config, path?, saveAs?}: checks with Test-VouchConfig (a
        file with errors is never written; warnings are fine), asks for a name when needed,
        then writes atomically with a .bak of the previous version.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $config = $Body['config']
    if ($config -isnot [System.Collections.IDictionary]) {
        return New-DesignerError -Status 400 -Code 'no-config' -Message 'There was no configuration to save.' -Detail 'The request did not hold a configuration object.'
    }
    $config = Repair-VouchConfigKeyCase -Config $config
    $check = Test-VouchConfig -Config $config
    if ($check.Errors.Count -gt 0) {
        return New-DesignerError -Status 422 -Code 'invalid' -Message "The configuration has $($check.Errors.Count) problem(s), so it was not saved." -Detail 'Fix the problems listed and save again.' -Extra ([ordered]@{
                errors = (ConvertTo-DesignerProblem -Problems $check.Errors); warnings = (ConvertTo-DesignerProblem -Problems $check.Warnings) })
    }
    $path = Get-DesignerBodyText -Body $Body -Name 'path'
    if ($Body['saveAs'] -eq $true -or -not $path) {
        $suggested = if ($path) { [System.IO.Path]::GetFileName($path) }
        elseif ($config['name'] -is [string] -and $config['name'].Trim()) { ConvertTo-SafeOutputName -Name $config['name'] -Extension 'json' -Fallback 'captures' }
        else { 'captures.json' }
        $path = Show-DesignerFileDialog -Kind save -Title 'Save the Vouch configuration' -Filter (Get-DesignerDialogFilter -Kind 'config') -InitialDirectory (Get-DesignerFolder -State $State) -FileName $suggested -DefaultExtension 'json'
        if (-not $path) { return New-DesignerJsonResponse -Data ([ordered]@{ cancelled = $true }) }
    }
    $path = Add-DesignerKnownPath -State $State -Path $path -Kind config
    try { $saved = Save-VouchConfig -Config $config -Path $path }
    catch {
        return New-DesignerError -Status 500 -Code 'not-saved' -Message "'$([System.IO.Path]::GetFileName($path))' could not be saved." -Detail ([string]$_.Exception.Message)
    }
    $notices = [System.Collections.Generic.List[string]]::new()
    if ($State.PendingCommentNotice) { $notices.Add((Get-DesignerCommentNotice)); $State.PendingCommentNotice = $false }
    $State.ConfigPath = $path
    $written = Read-DesignerConfigFile -Path $path
    return New-DesignerJsonResponse -Data ([ordered]@{
            path     = $path
            name     = [System.IO.Path]::GetFileName($path)
            folder   = (Split-Path -Path $path -Parent)
            backup   = $saved.Backup
            config   = $written.Config
            warnings = (ConvertTo-DesignerProblem -Problems $check.Warnings)
            notices  = $notices.ToArray()
        })
}

function Invoke-DesignerImportCsv {
    <#
        POST /api/config/import-csv {path?}: the pages of a capture CSV, converted exactly as
        a run would read them (ConvertTo-VouchConfig). The CSV's problems are listed one by
        one, as the console would show them.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $path = Get-DesignerBodyText -Body $Body -Name 'path'
    if (-not $path) {
        $path = Show-DesignerFileDialog -Kind open -Title 'Import a capture list (CSV)' -Filter (Get-DesignerDialogFilter -Kind 'csv') -InitialDirectory (Get-DesignerFolder -State $State)
        if (-not $path) { return New-DesignerJsonResponse -Data ([ordered]@{ cancelled = $true }) }
    }
    $path = Add-DesignerKnownPath -State $State -Path $path -Kind csv
    $info = $null
    try {
        $converted = ConvertTo-VouchConfig -Path $path -InformationVariable info 6>$null
    }
    catch {
        $lines = @($info | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -match '^\s+- ' } | ForEach-Object { $_.Trim().Substring(2) })
        return New-DesignerError -Status 422 -Code 'csv' -Message "'$([System.IO.Path]::GetFileName($path))' cannot be imported." -Detail ([string]$_.Exception.Message) -Extra ([ordered]@{ problems = $lines })
    }
    return New-DesignerJsonResponse -Data ([ordered]@{
            path  = $path
            name  = [System.IO.Path]::GetFileName($path)
            title = $converted['name']
            pages = $converted['pages']
        })
}

function Invoke-DesignerValidateConfig {
    # POST /api/config/validate {config}: problems, plus the report and zip names a run would use now.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $config = $Body['config']
    $check = Test-VouchConfig -Config $config
    $preview = $null
    if ($check.Errors.Count -eq 0 -and $config -is [System.Collections.IDictionary]) { $preview = Get-DesignerNamePreview -Config $config }
    return New-DesignerJsonResponse -Data ([ordered]@{
            errors   = (ConvertTo-DesignerProblem -Problems $check.Errors)
            warnings = (ConvertTo-DesignerProblem -Problems $check.Warnings)
            preview  = $preview
        })
}

function Get-DesignerNamePreview {
    <#
        The report and zip file names a run started now would use, made by the engine's own
        naming functions (Get-ReportFileName, Expand-NameTemplate, ConvertTo-SafeOutputName)
        so the preview cannot differ from the real names. $null when the configuration
        cannot be read that far.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [datetime]$When = (Get-Date))
    try {
        $completed = Complete-VouchConfig -Config (Copy-VouchConfig -Config $Config)
        $settings = Resolve-RunSettings -BoundParameters @{} -Defaults @{} -Config $completed
        $tokens = @{
            When = $When; Title = $settings.ReportTitle; Classification = $settings.Classification
            PeriodFrom = $settings.PeriodFrom; PeriodTo = $settings.PeriodTo; PeriodLabel = $settings.PeriodLabel
        }
        $stem = "VouchReport_$($When.ToString('yyyy-MM-dd_HHmmss'))"
        $report = Get-ReportFileName -Name $settings.ReportName -DefaultStem $stem -Values (Get-NameTokenValues @tokens -Report $stem)
        $reportStem = [System.IO.Path]::GetFileNameWithoutExtension($report.Name)
        $zipTemplate = if ([string]::IsNullOrWhiteSpace($settings.ZipName)) { '{report}.zip' } else { $settings.ZipName }
        $zip = Expand-NameTemplate -Template $zipTemplate -Values (Get-NameTokenValues @tokens -Report $reportStem)
        return [ordered]@{
            reportFile    = $report.Name
            reportUnknown = @($report.Unknown)
            reportChanged = [bool]$report.Changed
            zipFile       = (ConvertTo-SafeOutputName -Name $zip.Text -Extension 'zip' -Fallback $reportStem)
            zipUnknown    = @($zip.Unknown)
        }
    }
    catch {
        Write-Verbose "No name preview: $($_.Exception.Message)"
        return $null
    }
}

function Get-DesignerDialogFilter {
    param([Parameter(Mandatory)][ValidateSet('config', 'csv', 'image')][string]$Kind)
    switch ($Kind) {
        'config' { return 'Vouch configuration (*.json)|*.json|All files (*.*)|*.*' }
        'csv'    { return 'Capture list (*.csv)|*.csv|All files (*.*)|*.*' }
        'image'  { return 'Images (*.png;*.jpg;*.jpeg;*.gif;*.svg)|*.png;*.jpg;*.jpeg;*.gif;*.svg|All files (*.*)|*.*' }
    }
}

function Get-DesignerRelativeValue {
    <#
        What to write into the configuration for a picked path: relative to the
        configuration file's folder when the path is inside it (the file keeps working when
        the folder is moved or shared), otherwise the full path.
    #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$ConfigPath = '')
    if (-not $ConfigPath) { return $Path }
    $base = Split-Path -Path $ConfigPath -Parent
    $relative = [System.IO.Path]::GetRelativePath($base, $Path)
    if ($relative -eq '.' -or [System.IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..\') -or $relative.StartsWith('../')) { return $Path }
    return $relative
}

function Invoke-DesignerDialog {
    <#
        POST /api/dialog {kind, title?}: a Windows file or folder dialog on the server side.
        The answer's path becomes one the panel may send back (Add-DesignerKnownPath).
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $kind = Get-DesignerBodyText -Body $Body -Name 'kind'
    $title = (Get-DesignerBodyText -Body $Body -Name 'title') -replace '[\x00-\x1f]', ' '
    if ($title.Length -gt 120) { $title = $title.Substring(0, 120) }
    $folder = Get-DesignerFolder -State $State
    $path = switch -CaseSensitive ($kind) {
        'folder'      { Show-DesignerFileDialog -Kind folder -Title $(if ($title) { $title } else { 'Choose a folder' }) -InitialDirectory $folder }
        'image'       { Show-DesignerFileDialog -Kind open -Title $(if ($title) { $title } else { 'Choose a logo' }) -Filter (Get-DesignerDialogFilter -Kind 'image') -InitialDirectory $folder }
        'csv'         { Show-DesignerFileDialog -Kind open -Title $(if ($title) { $title } else { 'Choose a capture list (CSV)' }) -Filter (Get-DesignerDialogFilter -Kind 'csv') -InitialDirectory $folder }
        'config-open' { Show-DesignerFileDialog -Kind open -Title 'Open a Vouch configuration' -Filter (Get-DesignerDialogFilter -Kind 'config') -InitialDirectory $folder }
        'config-save' { Show-DesignerFileDialog -Kind save -Title 'Save the Vouch configuration' -Filter (Get-DesignerDialogFilter -Kind 'config') -InitialDirectory $folder -FileName 'captures.json' -DefaultExtension 'json' }
        default {
            return New-DesignerError -Status 400 -Code 'kind' -Message 'This kind of dialog does not exist.' -Detail 'kind must be folder, image, csv, config-open or config-save.'
        }
    }
    if (-not $path) { return New-DesignerJsonResponse -Data ([ordered]@{ cancelled = $true }) }
    $knownKind = @{ 'folder' = 'folder'; 'image' = 'image'; 'csv' = 'csv'; 'config-open' = 'config'; 'config-save' = 'config' }[$kind]
    $path = Add-DesignerKnownPath -State $State -Path $path -Kind $knownKind
    $data = [ordered]@{ path = $path; value = (Get-DesignerRelativeValue -Path $path -ConfigPath $State.ConfigPath) }
    if ($kind -eq 'image') { $data['logo'] = Get-DesignerLogoPreview -LogoPath $path }
    return New-DesignerJsonResponse -Data $data
}

function Invoke-DesignerCommand {
    <#
        POST /api/command {config, path}: the commands that run this configuration. They
        name the saved file, so "unsaved" says whether the file on disk still differs from
        what the panel shows (compared in canonical form, so key order and spacing do not
        count) - a command for a file that does not hold the shown pages would mislead.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $config = $Body['config']
    if ($config -isnot [System.Collections.IDictionary]) {
        return New-DesignerError -Status 400 -Code 'no-config' -Message 'There was no configuration.' -Detail 'The request did not hold a configuration object.'
    }
    $path = Get-DesignerBodyText -Body $Body -Name 'path'
    if (-not $path) {
        return New-DesignerJsonResponse -Data ([ordered]@{
                run = ''; runCmd = ''; runExpanded = ''; runExpandedCmd = ''; schedule = ''; scheduleCmd = ''; scheduleNote = ''
                unsaved = $true; saved = $false
                notes = @('Save the configuration to a file first: the commands run a saved file.')
            })
    }
    $path = Resolve-DesignerPath -Path $path
    $unsaved = $true
    $notes = [System.Collections.Generic.List[string]]::new()
    try {
        $onDisk = Read-DesignerConfigFile -Path $path
        $unsaved = (ConvertTo-VouchConfigText -Config (Repair-VouchConfigKeyCase -Config $config)) -cne (ConvertTo-VouchConfigText -Config $onDisk.Config)
    }
    catch { $notes.Add("The file is not readable any more: $($_.Exception.Message)") }
    if ($null -eq $State.ParameterInfo) { $State.ParameterInfo = Get-VouchParameterInfo -ScriptPath $State.ScriptPath }
    $command = Get-VouchCommandLine -Config $config -ConfigPath $path -ScriptPath $State.ScriptPath -ParameterInfo $State.ParameterInfo
    if ($unsaved) { $notes.Insert(0, 'You have changes that are not saved yet. These commands run the file as it was last saved; save first.') }
    foreach ($note in $command.Notes) { $notes.Add($note) }
    return New-DesignerJsonResponse -Data ([ordered]@{
            run            = $command.Run
            runCmd         = $command.RunCmd
            runExpanded    = $command.RunExpanded
            runExpandedCmd = $command.RunExpandedCmd
            schedule       = $command.Schedule
            scheduleCmd    = $command.ScheduleCmd
            scheduleNote   = $command.ScheduleNote
            switches       = @($command.Switches)
            unsaved        = $unsaved
            saved          = $true
            notes          = $notes.ToArray()
        })
}

function Invoke-DesignerOpenTarget {
    <#
        POST /api/open {what}: opens a file or folder the server knows - the last run's
        report, its folder, its capture log or the folder of its zip, a page test's preview
        report (all learned from that run's runEnd event), or the configuration's folder -
        never a path from the request.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $what = Get-DesignerBodyText -Body $Body -Name 'what'
    $target = ''
    if ($what -ceq 'config-folder') { if ($State.ConfigPath) { $target = Split-Path -Path $State.ConfigPath -Parent } }
    elseif ($what -cin 'report', 'folder', 'log', 'zip', 'preview-report') { if ($State.OpenTargets.Contains($what)) { $target = [string]$State.OpenTargets[$what] } }
    else {
        return New-DesignerError -Status 400 -Code 'what' -Message 'There is nothing of that kind to open.' -Detail 'what must be report, folder, log, zip, preview-report or config-folder.'
    }
    if (-not $target -or -not (Test-Path -LiteralPath $target)) {
        return New-DesignerError -Status 409 -Code 'nothing' -Message 'There is nothing to open yet.' -Detail $(if ($what -eq 'config-folder') { 'Save the configuration first.' } else { 'Run the configuration first; the report, its folder and its log appear here afterwards.' })
    }
    if ($State.OpenLog) { [System.IO.File]::AppendAllText($State.OpenLog, "$what|$target`n", [System.Text.UTF8Encoding]::new($false)) }
    else { Open-ReportFile -Path $target }
    return New-DesignerJsonResponse -Data ([ordered]@{ ok = $true; path = $target })
}

#endregion

#region Configuration files --------------------------------------------------------

function Copy-VouchConfig {
    # A deep copy (through the canonical text), so completing or resolving never touches the original.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    return ConvertFrom-VouchJson -Text (ConvertTo-VouchConfigText -Config $Config)
}

function New-VouchConfigLayoutNode {
    # The key order and child layouts of one schema object (Get-VouchConfigLayout).
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Fields)
    $children = @{}
    foreach ($key in $Fields.Keys) {
        $spec = $Fields[$key]
        if ($spec.Type -eq 'object') { $children[$key] = New-VouchConfigLayoutNode -Fields $spec.Fields }
    }
    return @{ Order = [string[]]@($Fields.Keys); Children = $children }
}

function Get-VouchConfigLayout {
    <#
        How a configuration file is laid out when saved: the key order of every object
        (the order of Get-VouchConfigSchema, which is the order of captures.sample.json)
        and which lists hold pages and actions. Keys the schema does not know are kept and
        written after the known ones, in their own order.
    #>
    $schema = Get-VouchConfigSchema
    $root = New-VouchConfigLayoutNode -Fields $schema
    $page = @{
        Order    = [string[]]@('id', 'name', 'url', 'notes', 'enabled', 'overrides', 'actions')
        Children = @{
            overrides = (New-VouchConfigLayoutNode -Fields $schema['defaults'].Fields)
            actions   = @{ Order = [string[]]@(); Children = @{}; Element = @{ Action = $true; Order = [string[]]@(); Children = @{} } }
        }
    }
    $root.Children['pages'] = @{ Order = [string[]]@(); Children = @{}; Element = $page }
    return $root
}

function Get-VouchConfigLayoutForAction {
    # An action's layout depends on its type: type first, then that type's keys in schema order.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Action)
    $type = Get-VouchActionType -Type $Action['type']
    $layout = @{ Order = [string[]]@('type'); Children = @{}; Inline = $true }
    if ($type) {
        $keys = (Get-VouchActionSchema)[$type]
        $layout.Order = [string[]](@('type') + @($keys.Keys))
        foreach ($key in $keys.Keys) {
            if ($keys[$key].Type -eq 'object') { $layout.Children[$key] = New-VouchConfigLayoutNode -Fields $keys[$key].Fields }
        }
    }
    return $layout
}

function Get-VouchConfigOrderedKey {
    # The keys of one object: the layout's known keys first (as present), then the rest as found.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Node, [AllowNull()][object]$Layout)
    $present = @($Node.Keys | ForEach-Object { [string]$_ })
    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Layout) {
        foreach ($name in $Layout.Order) {
            foreach ($key in $present) { if ($key -eq $name -and -not $result.Contains($key)) { $result.Add($key) } }
        }
    }
    foreach ($key in $present) { if (-not $result.Contains($key)) { $result.Add($key) } }
    return , $result.ToArray()
}

function Repair-VouchConfigKeyCase {
    <#
        Writes the known keys in the schema's spelling ("Name" -> "name"). The engine
        ignores capitals in keys, so the meaning is unchanged, but the panel looks keys up
        exactly. Unknown keys are kept as written. Returns a new object.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    return Repair-VouchConfigNodeKeyCase -Value $Config -Layout (Get-VouchConfigLayout)
}

function Repair-VouchConfigNodeKeyCase {
    param([AllowNull()][object]$Value, [AllowNull()][object]$Layout)
    if ($Value -is [System.Collections.IDictionary]) {
        if ($null -ne $Layout -and $Layout.ContainsKey('Action')) { $Layout = Get-VouchConfigLayoutForAction -Action $Value }
        $node = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $name = [string]$key
            if ($null -ne $Layout) { foreach ($known in $Layout.Order) { if ($known -eq $name) { $name = $known } } }
            $child = if ($null -ne $Layout -and $Layout.Children.ContainsKey($name)) { $Layout.Children[$name] } else { $null }
            $node[$name] = Repair-VouchConfigNodeKeyCase -Value $Value[$key] -Layout $child
        }
        return $node
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        $list = [System.Collections.Generic.List[object]]::new()
        $element = if ($null -ne $Layout -and $Layout.ContainsKey('Element')) { $Layout.Element } else { $null }
        foreach ($item in $Value) { $list.Add((Repair-VouchConfigNodeKeyCase -Value $item -Layout $element)) }
        return , $list
    }
    return $Value
}

function Format-VouchJsonString {
    # A JSON string: only what JSON requires is escaped; other letters stay readable (UTF-8).
    param([AllowEmptyString()][string]$Text)
    $escaped = [regex]::Replace($Text, '["\\\x00-\x1f]', {
            param($m)
            switch -CaseSensitive ($m.Value) {
                '"' { return '\"' }
                '\' { return '\\' }
                "`n" { return '\n' }
                "`r" { return '\r' }
                "`t" { return '\t' }
                "`b" { return '\b' }
                "`f" { return '\f' }
                default { return '\u{0:x4}' -f [int][char]$m.Value }
            }
        })
    return '"' + $escaped + '"'
}

function Test-VouchJsonScalar {
    param([AllowNull()][object]$Value)
    return -not ($Value -is [System.Collections.IDictionary] -or ($Value -is [System.Collections.IList] -and $Value -isnot [string]))
}

function Format-VouchConfigJson {
    <#
        One value as configuration-file JSON. The layout matches captures.sample.json: two
        spaces per level; an action on one line; a small object of plain values only (at
        most three keys, short) on one line, such as "zip" or "period"; everything else one key
        per line.
    #>
    param(
        [AllowNull()][object]$Value,
        [AllowNull()][object]$Layout = $null,
        [int]$Indent = 0,
        [switch]$Inline
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return Format-VouchJsonString -Text $Value }
    if ($Value -is [double] -or $Value -is [single]) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 'null' }
        return ([double]$Value).ToString('R', $invariant)
    }
    if ($Value -is [long] -or $Value -is [int] -or $Value -is [decimal] -or $Value -is [short] -or $Value -is [byte]) { return ([System.IFormattable]$Value).ToString($null, $invariant) }
    $pad = ' ' * ($Indent + 2)
    $end = ' ' * $Indent
    if ($Value -is [System.Collections.IDictionary]) {
        if ($null -ne $Layout -and $Layout.ContainsKey('Action')) { $Layout = Get-VouchConfigLayoutForAction -Action $Value }
        $keys = Get-VouchConfigOrderedKey -Node $Value -Layout $Layout
        if ($keys.Count -eq 0) { return '{}' }
        $childOf = { param($k) if ($null -ne $Layout -and $Layout.Children.ContainsKey($k)) { $Layout.Children[$k] } else { $null } }
        $inlineHere = $Inline -or ($null -ne $Layout -and $Layout.ContainsKey('Inline') -and $Layout.Inline)
        if (-not $inlineHere -and $Indent -gt 0 -and $keys.Count -le 3) {
            $plain = $true
            foreach ($k in $keys) { if (-not (Test-VouchJsonScalar -Value $Value[$k])) { $plain = $false; break } }
            if ($plain) {
                $candidate = '{ ' + (@($keys | ForEach-Object { (Format-VouchJsonString -Text $_) + ': ' + (Format-VouchConfigJson -Value $Value[$_] -Layout (& $childOf $_) -Inline) }) -join ', ') + ' }'
                if ($candidate.Length -le 80) { return $candidate }
            }
        }
        if ($inlineHere) {
            return '{ ' + (@($keys | ForEach-Object { (Format-VouchJsonString -Text $_) + ': ' + (Format-VouchConfigJson -Value $Value[$_] -Layout (& $childOf $_) -Inline) }) -join ', ') + ' }'
        }
        $lines = foreach ($k in $keys) { $pad + (Format-VouchJsonString -Text $k) + ': ' + (Format-VouchConfigJson -Value $Value[$k] -Layout (& $childOf $k) -Indent ($Indent + 2)) }
        return "{`n" + ($lines -join ",`n") + "`n$end}"
    }
    if ($Value -is [System.Collections.IList]) {
        if ($Value.Count -eq 0) { return '[]' }
        $element = if ($null -ne $Layout -and $Layout.ContainsKey('Element')) { $Layout.Element } else { $null }
        $allScalar = $true
        foreach ($item in $Value) { if (-not (Test-VouchJsonScalar -Value $item)) { $allScalar = $false; break } }
        if ($Inline -or $allScalar) {
            $candidate = '[' + (@($Value | ForEach-Object { Format-VouchConfigJson -Value $_ -Layout $element -Inline }) -join ', ') + ']'
            if ($Inline -or $candidate.Length -le 80) { return $candidate }
        }
        $lines = foreach ($item in $Value) { $pad + (Format-VouchConfigJson -Value $item -Layout $element -Indent ($Indent + 2)) }
        return "[`n" + ($lines -join ",`n") + "`n$end]"
    }
    return Format-VouchJsonString -Text ([string]$Value)
}

function ConvertTo-VouchConfigText {
    <#
        A configuration as the text of a file: keys in the stable order of the schema
        (unknown keys kept, after the known ones), two-space indent, a line break at the
        end. The same configuration always gives the same text, so "is it saved?" is a
        plain text comparison.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string]$NewLine = "`n"
    )
    $text = Format-VouchConfigJson -Value $Config -Layout (Get-VouchConfigLayout)
    return ($text -replace "`n", $NewLine) + $NewLine
}

function Save-VouchConfig {
    <#
        Writes a configuration file so that it is never half-written: the text goes to a
        temporary file in the same folder, which then replaces the old file in one step
        (File.Replace), keeping the previous version as <file>.bak - one generation, for
        the "I saved the wrong thing" moment. UTF-8 without BOM. An existing file keeps its
        line ends (a file from git may use LF); a new one gets Windows line ends.
        Returns { Path; Backup } (Backup '' when there was no earlier file).
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $folder = Split-Path -Path $full -Parent
    if (-not [System.IO.Directory]::Exists($folder)) { throw "The folder '$folder' does not exist." }
    $newLine = "`r`n"
    $exists = [System.IO.File]::Exists($full)
    if ($exists) {
        $old = [System.IO.File]::ReadAllText($full)
        if ($old.Contains("`n") -and -not $old.Contains("`r`n")) { $newLine = "`n" }
    }
    $text = ConvertTo-VouchConfigText -Config $Config -NewLine $newLine
    $temp = Join-Path -Path $folder -ChildPath (".$([System.IO.Path]::GetFileName($full)).$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp")
    $backup = ''
    try {
        [System.IO.File]::WriteAllText($temp, $text, [System.Text.UTF8Encoding]::new($false))
        if ($exists) {
            $backup = "$full.bak"
            try { [System.IO.File]::Replace($temp, $full, $backup, $true) }
            catch {
                # Some network shares cannot do Replace: copy the backup, then move over.
                [System.IO.File]::Copy($full, $backup, $true)
                [System.IO.File]::Move($temp, $full, $true)
            }
        }
        else {
            [System.IO.File]::Move($temp, $full)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temp)) { try { [System.IO.File]::Delete($temp) } catch { Write-Verbose "Temporary file left: $temp" } }
    }
    return [pscustomobject]@{ Path = $full; Backup = $backup }
}

#endregion

#region Command line ------------------------------------------------------------------

function Get-VouchParameterInfo {
    <#
        The parameters of vouch.ps1 as its param block declares them: type and default
        value, read from the script itself (not a copy here), so the command the Designer
        shows cannot drift from the script. Defaults that name the script's folder
        ($PSScriptRoot) are computed for that folder.
    #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errors)
    $folderLiteral = "'" + (Split-Path -Path ([System.IO.Path]::GetFullPath($ScriptPath)) -Parent).Replace("'", "''") + "'"
    $info = [ordered]@{}
    # A script without a param block (a test stand-in for vouch.ps1) has no parameters to read.
    if ($null -eq $ast.ParamBlock) { return $info }
    foreach ($parameter in $ast.ParamBlock.Parameters) {
        $name = $parameter.Name.VariablePath.UserPath
        $type = $parameter.StaticType
        $kind = if ($type -eq [System.Management.Automation.SwitchParameter]) { 'switch' }
        elseif ($type -eq [int]) { 'int' } elseif ($type -eq [double]) { 'double' }
        elseif ($type -eq [string[]]) { 'string[]' } else { 'string' }
        $default = switch ($kind) { 'switch' { $false } 'int' { 0 } 'double' { 0.0 } 'string[]' { , [string[]]@() } default { '' } }
        if ($null -ne $parameter.DefaultValue) {
            $text = [regex]::Replace($parameter.DefaultValue.Extent.Text, '\$PSScriptRoot\b', { param($m) $folderLiteral }, 'IgnoreCase')
            $default = & ([scriptblock]::Create($text))
        }
        $info[$name] = [pscustomobject]@{ Type = $kind; Default = $default }
    }
    return $info
}

function Test-DesignerArgumentProblem {
    <#
        Why a value cannot be passed safely on a command line, or ''. A line break ends the
        command; a value starting with a dash is read by pwsh -File as a parameter name.
    #>
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '[\r\n]') { return 'has several lines' }
    if ($Value -match '^[-–—―]') { return 'starts with a dash' }
    return ''
}

function ConvertTo-DesignerPowerShellArgument {
    <#
        A value quoted for a PowerShell command line. Double quotes when nothing in it is
        special (the familiar form), else single quotes, which keep $, backticks and double
        quotes literal. PowerShell treats the typographic quotes as quotes too, so they are
        doubled like ' inside single quotes, and force single quotes like " does.
    #>
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[`$"“”„‘’‚‛'']') { return '"' + $Value + '"' }
    return "'" + ($Value -replace "(['‘’‚‛])", '$1$1') + "'"
}

function ConvertTo-DesignerCmdArgument {
    <#
        A value quoted for cmd.exe (and the Windows argument rules pwsh uses): in double
        quotes, where & | < > ^ ( ) are plain text; backslashes before the closing quote
        are doubled. Some values cannot be written so that cmd.exe passes them on
        unchanged: a double quote (it ends the quoting for cmd.exe), % (cmd.exe replaces
        %NAME% even inside quotes), ! (replaced when delayed expansion is on) and line
        breaks. For those: $null, and the caller leaves the value out.
    #>
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '["%!\r\n]') { return $null }
    $trailing = ([regex]::Match($Value, '\\*$')).Value
    return '"' + $Value + $trailing + '"'
}

function Test-DesignerSettingEqual {
    param([AllowNull()][object]$A, [AllowNull()][object]$B, [string]$Name = '')
    if ($Name -in 'OutputDir', 'EdgeProfileDir', 'LogDir', 'LogoPath') {
        $fa = Resolve-DesignerPath -Path ([string]$A)
        $fb = Resolve-DesignerPath -Path ([string]$B)
        if ($fa -and $fb) { return [string]::Equals($fa.TrimEnd('\'), $fb.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) }
    }
    if ($A -is [string] -or $B -is [string]) { return [string]$A -ceq [string]$B }
    return $A -eq $B
}

function Get-VouchCommandSwitch {
    <#
        The run-level settings of a configuration that differ from what vouch.ps1 does
        without them, as command-line switches. Values are what a run would use: relative
        folders and the logo made absolute against the configuration's folder (on a
        command line they would be read from the current folder instead). A setting a page
        overrides is left out: a typed switch beats page overrides (the precedence rule),
        so writing it would change what that page captures.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][object]$ParameterInfo,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Notes
    )
    $switches = [System.Collections.Generic.List[object]]::new()
    $check = Test-VouchConfig -Config $Config
    if ($check.Errors.Count -gt 0) {
        $Notes.Add('The configuration has problems, so the settings are not spelled out as switches. Fix them first.')
        return , $switches
    }
    $completed = Complete-VouchConfig -Config (Copy-VouchConfig -Config $Config)
    $folder = Split-Path -Path $ConfigPath -Parent
    $completed['browser']['profileDir'] = Resolve-VouchConfigPath -Path $completed['browser']['profileDir'] -BaseDirectory $folder
    $completed['output']['dir'] = Resolve-VouchConfigPath -Path $completed['output']['dir'] -BaseDirectory $folder
    $completed['output']['logDir'] = Resolve-VouchConfigPath -Path $completed['output']['logDir'] -BaseDirectory $folder
    $completed['report']['logoPath'] = Resolve-VouchConfigPath -Path $completed['report']['logoPath'] -BaseDirectory $folder

    $defaults = @{}
    foreach ($name in $ParameterInfo.Keys) { $defaults[$name] = $ParameterInfo[$name].Default }
    $settings = Resolve-RunSettings -BoundParameters @{} -Defaults $defaults -Config $completed
    $schemaDefaults = Get-DefaultVouchConfig

    $overridden = @{}
    foreach ($page in $completed['pages']) {
        if ($page['overrides'] -isnot [System.Collections.IDictionary]) { continue }
        foreach ($key in $page['overrides'].Keys) {
            $value = $page['overrides'][$key]
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { continue }
            if (-not $overridden.ContainsKey($key)) { $overridden[$key] = [string]$page['id'] }
        }
    }

    foreach ($definition in Get-RunSettingDefinition) {
        if (-not $definition.Section -or -not $ParameterInfo.Contains($definition.Name)) { continue }
        $value = $settings.($definition.Name)
        $default = ConvertTo-SettingValue -Type $definition.Type -Value $defaults[$definition.Name]
        if (Test-DesignerSettingEqual -A $value -B $default -Name $definition.Name) { continue }
        if ($definition.Type -eq 'string' -and [string]$default -eq '') {
            $schemaValue = Get-ConfigValue -Config $schemaDefaults -Section $definition.Section -Key $definition.Key
            if ($schemaValue.Found -and [string]$value -ceq [string]$schemaValue.Value) { continue }
        }
        if ($definition.Section -eq 'defaults' -and $overridden.ContainsKey($definition.Key)) {
            $Notes.Add("-$($definition.Name) is left out: page $($overridden[$definition.Key]) sets its own $($definition.Key), and a typed -$($definition.Name) would replace it. The file supplies the value.")
            continue
        }
        $switches.Add([pscustomobject]@{ Name = $definition.Name; Type = $ParameterInfo[$definition.Name].Type; Value = $value })
    }
    return , $switches
}

function Get-VouchCommandLine {
    <#
        The command lines for a saved configuration:
        - Run / RunCmd: the short command (PowerShell, and cmd.exe or a shortcut);
        - RunExpanded / RunExpandedCmd: the same plus every run-level setting that differs
          from vouch.ps1's own default as its switch (the pages still come from the file),
          for people who want to see or change one switch;
        - Schedule / ScheduleCmd: the Install-VouchSchedule.ps1 command that runs it
          automatically after sign-in.
        Notes says what was left out and why. A switch's value is written only when both
        shells pass it through unchanged; otherwise it is left to the file (which holds it
        anyway) and a note says so.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowNull()][object]$ParameterInfo = $null
    )
    $script = [System.IO.Path]::GetFullPath($ScriptPath)
    $configFull = [System.IO.Path]::GetFullPath($ConfigPath)
    $installer = Join-Path -Path (Split-Path -Path $script -Parent) -ChildPath 'Install-VouchSchedule.ps1'
    if ($null -eq $ParameterInfo) { $ParameterInfo = Get-VouchParameterInfo -ScriptPath $script }
    $notes = [System.Collections.Generic.List[string]]::new()
    $ps = { param($v) ConvertTo-DesignerPowerShellArgument -Value $v }
    $cmd = { param($v) ConvertTo-DesignerCmdArgument -Value $v }
    $head = 'pwsh -NoProfile -ExecutionPolicy Bypass -File'

    $run = "$head $(& $ps $script) -ConfigPath $(& $ps $configFull)"
    # The same command as arguments, one by one, for a process start (the Designer's runs
    # add their session-only switches to this list): never a string to be split again.
    $runArguments = [string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-ConfigPath', $configFull)
    # A path cmd.exe would change cannot be left out like a setting: no cmd.exe lines then.
    $cmdSafe = $null -ne (& $cmd $script) -and $null -ne (& $cmd $configFull) -and $null -ne (& $cmd $installer)
    $runCmd = if ($cmdSafe) { "$head $(& $cmd $script) -ConfigPath $(& $cmd $configFull)" } else { '' }
    if (-not $cmdSafe) {
        $notes.Add('A folder or file name contains % or !, which cmd.exe would change, so there is no cmd.exe version. Use the PowerShell command, or rename the folder.')
    }

    $switches = Get-VouchCommandSwitch -Config $Config -ConfigPath $configFull -ParameterInfo $ParameterInfo -Notes $notes
    $psParts = [System.Collections.Generic.List[string]]::new()
    $cmdParts = [System.Collections.Generic.List[string]]::new()
    $included = [System.Collections.Generic.List[object]]::new()
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($switch in $switches) {
        if ($switch.Type -eq 'switch') {
            $psParts.Add("-$($switch.Name)"); $cmdParts.Add("-$($switch.Name)"); $included.Add($switch); continue
        }
        if ($switch.Type -in 'int', 'double') {
            $number = ([System.IFormattable]$switch.Value).ToString($null, $invariant)
            $psParts.Add("-$($switch.Name) $number"); $cmdParts.Add("-$($switch.Name) $number"); $included.Add($switch); continue
        }
        $text = [string]$switch.Value
        $problem = Test-DesignerArgumentProblem -Value $text
        if ($problem) {
            $notes.Add("-$($switch.Name) is left out because its value $problem; the file supplies it.")
            continue
        }
        $psParts.Add("-$($switch.Name) $(& $ps $text)")
        $included.Add($switch)
        $cmdValue = & $cmd $text
        if ($null -eq $cmdValue) {
            if ($cmdSafe) { $notes.Add("-$($switch.Name) is left out of the cmd.exe line because its value contains "" % or !, which cmd.exe would not pass on unchanged; the file supplies it.") }
        }
        else { $cmdParts.Add("-$($switch.Name) $cmdValue") }
    }
    $runExpanded = (@($run) + $psParts) -join ' '
    $runExpandedCmd = if ($cmdSafe) { (@($runCmd) + $cmdParts) -join ' ' } else { '' }

    # Only a command to copy: the Designer never sets up a scheduled task itself.
    $schedule = "$head $(& $ps $installer) -ConfigPath $(& $ps $configFull) -Schedule AtLogOn"
    $scheduleCmd = if ($cmdSafe) { "$head $(& $cmd $installer) -ConfigPath $(& $cmd $configFull) -Schedule AtLogOn" } else { '' }
    $scheduleNote = 'Paste into a PowerShell window to set up a Windows scheduled task that runs the saved file 3 minutes after you sign in, without asking anything. It checks the file first and sets up nothing if the file has problems. Scheduled runs count warnings as failure, whatever the file says, so an expired sign-in never shows as a success; add -AllowWarnings to allow warnings. For a set time instead, replace -Schedule AtLogOn with -At 07:30 (every weekday at 07:30). The Designer itself does not set up the task.'

    return [pscustomobject]@{
        Run            = $run
        RunArguments   = $runArguments
        RunCmd         = $runCmd
        RunExpanded    = $runExpanded
        RunExpandedCmd = $runExpandedCmd
        Schedule       = $schedule
        ScheduleCmd    = $scheduleCmd
        ScheduleNote   = $scheduleNote
        Switches       = @($included | ForEach-Object { [ordered]@{ name = $_.Name; value = $_.Value } })
        Notes          = $notes.ToArray()
    }
}

#endregion

#region Dialogs and the panel window ---------------------------------------------------

function Initialize-DesignerInterop {
    <#
        ShowWindow/SetForegroundWindow for the dialog owner. A type of its own (not
        Vouch.Native): Initialize-NativeInterop also makes the process DPI-aware, which
        would change the units of the panel's screen position.
    #>
    if (-not ('Vouch.DesignerNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Vouch
{
    public static class DesignerNative
    {
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
'@ -Language CSharp
    }
}

function Show-DesignerFileDialog {
    <#
        A Windows Open/Save/Folder dialog shown from the server loop. pwsh -File runs on an
        STA thread, so the dialogs work here directly. Only the first dialog of a process
        comes to the front on its own; later ones open behind the panel unless they have a
        visible, topmost owner window - a 1x1 borderless form (spike 4). Returns the chosen
        path, or '' when cancelled. The loop waits while the dialog is open.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('open', 'save', 'folder')][string]$Kind,
        [string]$Title = '',
        [string]$Filter = '',
        [string]$InitialDirectory = '',
        [string]$FileName = '',
        [string]$DefaultExtension = ''
    )
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-DesignerInterop
    $owner = [System.Windows.Forms.Form]::new()
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $owner.Size = [System.Drawing.Size]::new(1, 1)
    $dialog = $null
    try {
        $owner.Show()
        [void][Vouch.DesignerNative]::ShowWindow($owner.Handle, 5)
        [void][Vouch.DesignerNative]::SetForegroundWindow($owner.Handle)
        $owner.Activate()
        switch ($Kind) {
            'folder' {
                $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
                $dialog.Description = $Title
                $dialog.UseDescriptionForTitle = $true
                $dialog.ShowNewFolderButton = $true
                if ($InitialDirectory -and [System.IO.Directory]::Exists($InitialDirectory)) { $dialog.SelectedPath = $InitialDirectory }
            }
            default {
                $dialog = if ($Kind -eq 'open') { [System.Windows.Forms.OpenFileDialog]::new() } else { [System.Windows.Forms.SaveFileDialog]::new() }
                $dialog.Title = $Title
                if ($Filter) { $dialog.Filter = $Filter }
                if ($InitialDirectory -and [System.IO.Directory]::Exists($InitialDirectory)) { $dialog.InitialDirectory = $InitialDirectory }
                if ($FileName) { $dialog.FileName = $FileName }
                if ($Kind -eq 'open') { $dialog.CheckFileExists = $true; $dialog.Multiselect = $false }
                else { $dialog.OverwritePrompt = $true; $dialog.AddExtension = $true; if ($DefaultExtension) { $dialog.DefaultExt = $DefaultExtension } }
            }
        }
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $(if ($Kind -eq 'folder') { $dialog.SelectedPath } else { $dialog.FileName })
        }
        return ''
    }
    finally {
        if ($null -ne $dialog) { $dialog.Dispose() }
        $owner.Close()
        $owner.Dispose()
    }
}

function Get-DesignerPanelBounds {
    <#
        Where the panel goes: about 480 px wide at the right edge of the primary screen's
        working area, full height. The values are in the units Edge's --window-size uses
        (this process is not DPI-aware, so Windows reports them scaled the same way), and
        include the 7 px invisible resize borders Windows adds left, right and below.
    #>
    Add-Type -AssemblyName System.Windows.Forms
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = 480
    return [pscustomobject]@{ X = $area.Right - $width - 7; Y = $area.Top; Width = $width + 14; Height = $area.Height + 7 }
}

function Get-DesignerPanelArgument {
    <#
        The Edge command line for the panel: an app window (no tabs or address bar) with a
        profile of its own - never the audit profile, whose path must not even be contained
        in it (Find-EdgeBrowserProcess matches profile paths as text) - and --disable-sync,
        without which a fresh profile on a work PC opens a sign-in window (spike 2).
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ProfileDir,
        [Parameter(Mandatory)][object]$Bounds
    )
    return @(
        "--user-data-dir=`"$ProfileDir`"", "--app=$Url",
        "--window-size=$($Bounds.Width),$($Bounds.Height)", "--window-position=$($Bounds.X),$($Bounds.Y)",
        '--no-first-run', '--no-default-browser-check', '--disable-sync')
}

function Get-DesignerPanelProfile {
    # %LOCALAPPDATA%\Vouch\DesignerPanel: beside, never inside, the audit profile.
    return Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Vouch\DesignerPanel'
}

function Get-DesignerAuditProfile {
    <#
        The audit browser profile a run would use: a typed -EdgeProfileDir, else the
        configuration's browser.profileDir (relative to the file's folder), else the
        engine's default. Never throws: an unreadable file means the default.
    #>
    param(
        [AllowEmptyString()][string]$EdgeProfileDir = '',
        [AllowNull()][object]$Config = $null,
        [AllowEmptyString()][string]$ConfigPath = ''
    )
    $default = Join-Path -Path "$env:LOCALAPPDATA" -ChildPath 'Vouch\EdgeProfile'
    if ($EdgeProfileDir) { return Resolve-DesignerPath -Path $EdgeProfileDir }
    try {
        if ($null -eq $Config -and $ConfigPath -and [System.IO.File]::Exists($ConfigPath)) { $Config = (Read-DesignerConfigFile -Path $ConfigPath).Config }
        $found = Get-ConfigValue -Config $Config -Section 'browser' -Key 'profileDir'
        if ($found.Found -and $found.Value -is [string]) {
            $base = if ($ConfigPath) { Split-Path -Path $ConfigPath -Parent } else { (Get-Location).ProviderPath }
            return Resolve-DesignerPath -Path (Resolve-VouchConfigPath -Path $found.Value -BaseDirectory $base)
        }
    }
    catch { Write-Verbose "Audit profile not read from the configuration: $($_.Exception.Message)" }
    return $default
}

function Test-DesignerProfileOverlap {
    <#
        Why the panel's profile and the audit profile cannot be used together, or ''. The
        engine finds its Edge by looking for the profile path as text in command lines
        (Find-EdgeBrowserProcess), so neither path may contain the other: the panel's Edge
        would be taken for the audit browser, or the other way round.
    #>
    param([Parameter(Mandatory)][string]$PanelProfile, [Parameter(Mandatory)][string]$AuditProfile)
    $panel = (Resolve-DesignerPath -Path $PanelProfile).TrimEnd('\')
    $audit = (Resolve-DesignerPath -Path $AuditProfile).TrimEnd('\')
    if (-not $panel -or -not $audit) { return '' }
    if ($panel.Contains($audit, [System.StringComparison]::OrdinalIgnoreCase) -or $audit.Contains($panel, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "The Designer window's browser profile ($panel) and the audit browser profile ($audit) overlap: one folder name contains the other, so Vouch could mistake one Edge for the other. Choose an audit profile folder (browser.profileDir or -EdgeProfileDir) whose path does not contain, and is not contained in, $panel."
    }
    return ''
}

function Assert-DesignerProfileSeparate {
    <#
        Checks the panel profile against the audit profile in effect and remembers that
        audit profile in the state. Start-VouchDesigner calls it at the start; later steps
        call it again whenever the configuration's browser.profileDir changes, before they
        start or attach to the audit Edge. Throws the plain message from
        Test-DesignerProfileOverlap.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$AuditProfile,
        [string]$PanelProfile = ''
    )
    if (-not $PanelProfile) { $PanelProfile = if ($State.PanelProfileDir) { $State.PanelProfileDir } else { Get-DesignerPanelProfile } }
    $problem = Test-DesignerProfileOverlap -PanelProfile $PanelProfile -AuditProfile $AuditProfile
    if ($problem) { throw $problem }
    $State.AuditProfileDir = Resolve-DesignerPath -Path $AuditProfile
}

function Get-DesignerAlreadyOpenMessage {
    # What a second Designer says before it stops (exit code 1).
    return 'The Vouch Designer is already open. Look for its window on the taskbar. (If that window shows only an error, close it and start the Designer again.)'
}

function Show-DesignerExistingPanel {
    <#
        Brings the window of the Designer that is already open to the front, so a second
        double-click is not left wondering. Best effort: Windows may refuse, and nothing
        else is done to that Edge.
    #>
    param([AllowNull()][object]$Process)
    if ($null -eq $Process) { return }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.Interaction]::AppActivate([int]$Process.Id)
    }
    catch { Write-Verbose "The open Designer window could not be brought to the front: $($_.Exception.Message)" }
}

function Enter-DesignerInstance {
    <#
        One Designer with a panel per Windows session. A second one would join the first
        one's panel Edge (one profile, one browser process), watch that process instead
        of its own window, close or kill it - unsaved edits and all - when it stops, and
        drive the same audit Edge on the same port. So a second start stops with a plain
        message. Two signs that a Designer is open: a live Edge holds the panel profile
        (also left over from a Designer that was killed, whose window is still open), or
        another process holds the named mutex. Windows releases a mutex when its owner
        dies, however it ends, so a killed Designer never blocks the next start (no marker
        file to go stale). Returns the held mutex for Exit-DesignerInstance; throws the
        message otherwise. Designers started with -NoPanel (tests, programs) do not call it.
    #>
    param(
        [string]$Name = 'Local\VouchDesignerPanel',
        [string]$PanelProfile = (Get-DesignerPanelProfile)
    )
    $holder = Find-EdgeBrowserProcess -ProfileDir $PanelProfile
    if ($null -ne $holder) {
        Show-DesignerExistingPanel -Process $holder
        throw (Get-DesignerAlreadyOpenMessage)
    }
    $mutex = [System.Threading.Mutex]::new($false, $Name)
    $owned = $false
    try { $owned = $mutex.WaitOne(0) }
    catch {
        # The previous owner ended without releasing it: the mutex is now ours.
        if ($_.Exception.GetBaseException() -is [System.Threading.AbandonedMutexException]) { $owned = $true }
        else { $mutex.Dispose(); throw }
    }
    if (-not $owned) {
        $mutex.Dispose()
        throw (Get-DesignerAlreadyOpenMessage)
    }
    return $mutex
}

function Exit-DesignerInstance {
    # Lets the next Designer start (Enter-DesignerInstance). Same thread that entered.
    param([AllowNull()][object]$Instance)
    if ($null -eq $Instance) { return }
    try { $Instance.ReleaseMutex() } catch { Write-Verbose "The Designer instance was already released: $($_.Exception.Message)" }
    $Instance.Dispose()
}

function Start-DesignerPanel {
    <#
        Opens the panel in its own Edge process. With a profile no other Edge holds, the
        process Start-Process returns is the browser itself (spike 2), so its exit means
        the person closed the panel. An Edge that already holds the profile belongs to
        another Designer (Enter-DesignerInstance normally stops before this): the window
        is not opened into it, because this Designer would then watch - and at its end
        close - that other Designer's window.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$ProfileDir = (Get-DesignerPanelProfile),
        [string]$AuditProfileDir = (Get-DesignerAuditProfile)
    )
    $problem = Test-DesignerProfileOverlap -PanelProfile $ProfileDir -AuditProfile $AuditProfileDir
    if ($problem) { throw $problem }
    $edge = Find-EdgeExecutable
    if (-not (Test-Path -LiteralPath $ProfileDir)) { [void](New-Item -ItemType Directory -Path $ProfileDir -Force) }
    if ($null -ne (Find-EdgeBrowserProcess -ProfileDir $ProfileDir)) { throw (Get-DesignerAlreadyOpenMessage) }
    return Start-Process -FilePath $edge -ArgumentList (Get-DesignerPanelArgument -Url $Url -ProfileDir $ProfileDir -Bounds (Get-DesignerPanelBounds)) -PassThru
}

function Test-DesignerProcessExited {
    <#
        Whether a process has ended. Process.HasExited is read as a METHOD (get_HasExited):
        PowerShell hides an exception thrown by a property read, so .HasExited on a handle
        that cannot be read just gives $null - which must not count as an answer. Then
        the process id is looked up: no process, or one that started at another time
        (-StartTime, a reused id), means ended. When nothing can tell, -Unknown is the
        answer: each caller decides which way is safe for it.
    #>
    param(
        [AllowNull()][object]$Process,
        [int]$ProcessId = 0,
        [datetime]$StartTime = [datetime]::MinValue,
        [bool]$Unknown = $false
    )
    if ($null -eq $Process -and $ProcessId -le 0) { return $true }
    if ($null -ne $Process) {
        try {
            $value = $Process.get_HasExited()
            if ($value -is [bool]) { return $value }
        }
        catch { Write-Verbose "Whether the process has ended could not be read directly: $($_.Exception.Message)" }
        if ($ProcessId -le 0) { try { $ProcessId = [int]$Process.get_Id() } catch { $ProcessId = 0 } }
    }
    if ($ProcessId -le 0) { return $Unknown }
    try {
        $found = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $found) { return $true }
        if ($StartTime -ne [datetime]::MinValue -and $found.StartTime -ne $StartTime) { return $true }
        return $false
    }
    catch { Write-Verbose "Whether the process has ended could not be told: $($_.Exception.Message)" }
    return $Unknown
}

function Get-DesignerProcessStartTime {
    # A process's start time, or MinValue when it cannot be read (then it is not compared).
    param([AllowNull()][object]$Process)
    if ($null -eq $Process) { return [datetime]::MinValue }
    try { return [datetime]$Process.get_StartTime() } catch { return [datetime]::MinValue }
}

function Stop-DesignerPanel {
    <#
        Closes the panel window the way a person would (WM_CLOSE), so Edge does not offer
        to "restore pages" next time; kills it only if it does not go within 3 seconds.
        Only a process this session started: one that started before -LaunchedAt (the
        moment this Designer opened its panel), or whose start time cannot be read, or
        any process when no panel was launched, may belong to another Designer or to the
        person, and is never closed or killed.
    #>
    param(
        [AllowNull()][System.Diagnostics.Process]$Process,
        [datetime]$LaunchedAt = [datetime]::MinValue
    )
    if ($null -eq $Process) { return }
    if ($LaunchedAt -eq [datetime]::MinValue) { return }
    $started = Get-DesignerProcessStartTime -Process $Process
    # A second of leeway: the process start time and Get-Date are read from different clocks.
    if ($started -eq [datetime]::MinValue -or $started -lt $LaunchedAt.AddSeconds(-1)) {
        Write-Verbose "The window process $($Process.Id) was not started by this Designer and is left open."
        return
    }
    try {
        if (Test-DesignerProcessExited -Process $Process) { return }
        [void]$Process.CloseMainWindow()
        if (-not $Process.WaitForExit(3000)) { $Process.Kill($true) }
    }
    catch { Write-Verbose "The Designer window could not be closed: $($_.Exception.Message)" }
}

#endregion

#region Browser link -------------------------------------------------------------------

function Get-DesignerValue {
    <#
        One field of an object that came from the page or a request, or $null. Such data
        can have any shape (a page can even replace the picker's functions), and StrictMode
        throws on a missing property.
    #>
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object -is [string] -or $Object -is [ValueType]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-DesignerText {
    <#
        Text that came from a web page (a title, an address, an element's words) made safe
        to pass on as data: a string without control characters, at most -Max characters.
        Anything that is not text (a page can return any shape) becomes ''. The panel
        shows such text with textContent only.
    #>
    param([AllowNull()][object]$Value, [int]$Max = 200)
    if ($Value -isnot [string]) { return '' }
    $text = $Value -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ' '
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max - 1) + [char]0x2026 }
    return $text
}

function Get-DesignerBodyNumber {
    # A whole number from a request body, or -1 when missing or not a number.
    param([AllowNull()][object]$Body, [Parameter(Mandatory)][string]$Name)
    $value = Get-DesignerValue -Object $Body -Name $Name
    if ($value -is [ValueType] -and $value -isnot [bool]) {
        try { return [int]$value } catch { return -1 }
    }
    return -1
}

function Get-DesignerBrowserSetting {
    <#
        The audit Edge a run of the open configuration would use: the port and profile
        typed with -Designer, else the configuration file's browser section, else the
        engine's defaults. Read from the file as saved, because that is what a run reads;
        the panel says when it differs from the Edge the Designer is connected to.
    #>
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    $config = Get-DesignerSavedConfig -State $State
    $port = 9222
    if ($browser.TypedPort -gt 0) { $port = [int]$browser.TypedPort }
    else {
        $found = Get-ConfigValue -Config $config -Section 'browser' -Key 'debugPort'
        if ($found.Found -and $found.Value -is [ValueType] -and $found.Value -isnot [bool]) {
            $value = [int]$found.Value
            if ($value -ge 1024 -and $value -le 65535) { $port = $value }
        }
    }
    $keep = [bool]$browser.TypedKeepOpen
    if (-not $keep) {
        $found = Get-ConfigValue -Config $config -Section 'browser' -Key 'keepBrowserOpen'
        $keep = ($found.Found -and $found.Value -eq $true)
    }
    $configPath = if ($null -ne $config) { $State.ConfigPath } else { '' }
    $profileDir = Get-DesignerAuditProfile -EdgeProfileDir $browser.TypedProfileDir -Config $config -ConfigPath $configPath
    return [pscustomobject]@{ Port = $port; ProfileDir = $profileDir; KeepOpen = $keep }
}

function Get-DesignerSavedConfig {
    <#
        The configuration file as saved, read again only when it changed (path, last
        write time and size): GET /api/state asks for the browser settings on every
        poll of the panel, and parsing the file each time would be wasted work. $null
        when there is no file or it cannot be read.
    #>
    param([Parameter(Mandatory)][object]$State)
    $path = $State.ConfigPath
    if (-not $path -or -not [System.IO.File]::Exists($path)) { return $null }
    $info = [System.IO.FileInfo]::new($path)
    $stamp = "$($info.LastWriteTimeUtc.Ticks)|$($info.Length)"
    $cache = $State.ConfigCache
    if ($null -ne $cache -and $cache.Path -eq $path -and $cache.Stamp -eq $stamp) { return $cache.Config }
    $config = $null
    try { $config = (Read-DesignerConfigFile -Path $path).Config }
    catch { Write-Verbose "Browser settings not read from the configuration: $($_.Exception.Message)" }
    $State.ConfigCache = [pscustomobject]@{ Path = $path; Stamp = $stamp; Config = $config }
    return $config
}

function Get-EdgeDebugPolicy {
    <#
        Whether an organisation policy decides Edge's remote debugging: $false when the
        policy RemoteDebuggingAllowed is 0 (Edge then never opens the port, whatever Vouch
        does), $true when it allows it, $null when no policy is set. Machine policy first:
        it wins over the user's.
    #>
    foreach ($root in 'HKLM:', 'HKCU:') {
        try {
            $item = Get-ItemProperty -LiteralPath "$root\SOFTWARE\Policies\Microsoft\Edge" -Name 'RemoteDebuggingAllowed' -ErrorAction Stop
            return ([int]$item.RemoteDebuggingAllowed -ne 0)
        }
        catch { Write-Verbose "No RemoteDebuggingAllowed policy under $root." }
    }
    return $null
}

function Test-DesignerPortBusy {
    # Whether something already accepts connections on the port (used when it is not Edge's DevTools).
    param([Parameter(Mandatory)][int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try { return [bool]$client.ConnectAsync('127.0.0.1', $Port).Wait(500) }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-DesignerBrowserProblem {
    <#
        Why the Designer is not connected to the audit Edge, in words for the panel's
        first screen: what happened, and what the person can do (causes). A port that
        never opens has three usual reasons; when the organisation's policy is known to
        forbid remote debugging, that one is named for certain.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [int]$Port = 0,
        [AllowEmptyString()][string]$ProfileDir = '',
        [AllowEmptyString()][string]$Detail = ''
    )
    $causes = @()
    switch ($Code) {
        'profile' {
            $message = $Detail
        }
        'noedge' {
            $message = 'Microsoft Edge was not found on this computer, so the Designer cannot open pages.'
            if ($Detail) { $causes = @($Detail) }
        }
        'notrunning' {
            $message = "No Edge is waiting for Vouch on port $Port."
            $causes = @('Start the audit Edge with that port, then press Retry.')
        }
        'portbusy' {
            $message = "Another program is using port $Port, which Vouch needs to control Edge."
            $causes = @('Close that program and press Retry, or choose another port: Output tab, Advanced, "Browser connection port". Save, then press Retry.')
        }
        'profile-open' {
            $message = 'Edge is already open with the audit profile, but without the connection Vouch needs.'
            $causes = @("Close every Edge window that uses $ProfileDir (look on the taskbar and on other desktops), then press Retry. Vouch opens it again with the connection.")
        }
        'policy' {
            $message = 'Your organisation has switched off remote debugging in Edge (the Edge policy RemoteDebuggingAllowed), and Vouch needs it to control the browser.'
            $causes = @('Ask your IT department to allow it on this computer. Until then Vouch cannot open or capture pages; you can still edit and save configurations here.')
        }
        'noport' {
            $message = "Edge did not open the connection Vouch needs (port $Port)."
            $causes = @(
                "Edge may already be open with the audit profile without that connection, for example a window left from -LoginSetup: close every Edge window that uses $ProfileDir, then press Retry.",
                'Your organisation may have switched off remote debugging in Edge (the Edge policy RemoteDebuggingAllowed). If so, ask your IT department to allow it.',
                "Another program may be using port ${Port}: choose another port (Output tab, Advanced, ""Browser connection port""), save, then press Retry.")
        }
        'gone' {
            $message = 'The audit Edge window was closed.'
            $causes = @('Press Retry to open it again.')
        }
        'notab' {
            $message = 'The audit Edge has no web page open.'
            $causes = @('Open a page in the Edge window (or press Retry).')
        }
        default {
            $message = if ($Detail) { $Detail } else { 'The Designer is not connected to the audit Edge.' }
        }
    }
    return [ordered]@{ code = $Code; message = $message; causes = @($causes) }
}

function Get-DesignerWebTab {
    <#
        The tabs of the audit Edge the Designer may attach to: web pages only - never
        Edge's own pages, DevTools or extensions (Get-PageTargetKind) - and never the
        Designer panel itself, should someone open its address in the audit Edge.
    #>
    param([Parameter(Mandatory)][object]$State, [AllowNull()][object[]]$Targets)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        if ([string](Get-DesignerValue -Object $target -Name 'type') -ne 'page') { continue }
        if (-not [string](Get-DesignerValue -Object $target -Name 'webSocketDebuggerUrl')) { continue }
        if ((Get-PageTargetKind -Target $target) -ne 'web') { continue }
        $url = [string](Get-DesignerValue -Object $target -Name 'url')
        $panel = $false
        foreach ($prefix in "http://localhost:$($State.Port)/", "http://127.0.0.1:$($State.Port)/", "http://[::1]:$($State.Port)/") {
            if ($url.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $panel = $true }
        }
        if (-not $panel) { $list.Add($target) }
    }
    return , $list
}

function Use-DesignerProbeSocket {
    <#
        Runs -Script with a short-lived DevTools connection to another tab, then puts the
        engine's connection back exactly as it was. The engine keeps one socket in script
        variables; the zoom and the fall-back target are cleared while probing so that a
        reconnect inside the probe can neither zoom nor attach to some other tab.
    #>
    param([Parameter(Mandatory)][string]$WebSocketUrl, [Parameter(Mandatory)][scriptblock]$Script)
    $saved = @{
        Socket = $script:CdpSocket; Url = $script:CdpWebSocketUrl; Id = $script:CdpMessageId
        Port = $script:CdpPort; Zoom = $script:PageZoomPercent; Tab = $script:CdpTabId
    }
    $script:CdpSocket = $null
    $script:CdpPort = 0
    $script:PageZoomPercent = 100
    $script:CdpTabId = ''
    try {
        Connect-CdpSocket -WebSocketUrl $WebSocketUrl -TimeoutSec 2
        return (& $Script)
    }
    finally {
        Close-CdpSocket
        $script:CdpSocket = $saved.Socket
        $script:CdpWebSocketUrl = $saved.Url
        $script:CdpMessageId = $saved.Id
        $script:CdpPort = $saved.Port
        $script:PageZoomPercent = $saved.Zoom
        $script:CdpTabId = $saved.Tab
    }
}

function Get-DesignerTabVisibility {
    # 'visible' or 'hidden' for one tab (document.visibilityState), '' when it cannot be asked.
    param([Parameter(Mandatory)][object]$Target)
    try {
        return [string](Use-DesignerProbeSocket -WebSocketUrl ([string](Get-DesignerValue -Object $Target -Name 'webSocketDebuggerUrl')) -Script {
                Invoke-CdpEval -Expression 'document.visibilityState' -TimeoutSec 1 })
    }
    catch { return '' }
}

function Find-DesignerVisibleTab {
    <#
        The tab the person is looking at: the one whose document is "visible" (spike 3;
        Edge shows one tab per window). The attached tab is asked over the open socket,
        the others over a short socket each. $null when none is visible - a minimised
        window has every tab hidden, and the Designer then stays where it is.
        The loop waits while this runs, so a sweep is bounded: it stops at the first tab
        that does not answer (a sleeping background tab can take its full timeout every
        time) and when -BudgetMs is used up; the next sweep tries again.
    #>
    param([Parameter(Mandatory)][object]$State, [AllowNull()][object[]]$Tabs, [string]$Skip = '', [int]$BudgetMs = 2500)
    $deadline = (Get-Date).AddMilliseconds($BudgetMs)
    foreach ($tab in @($Tabs)) {
        if ($null -eq $tab) { continue }
        if ((Get-Date) -ge $deadline) { break }
        $id = [string](Get-DesignerValue -Object $tab -Name 'id')
        if ($Skip -and $id -eq $Skip) { continue }
        $visibility = ''
        if ($State.Browser.Connected -and $id -eq $State.Browser.TabId -and $null -ne $script:CdpSocket) {
            try { $visibility = [string](Invoke-CdpEval -Expression 'document.visibilityState' -TimeoutSec 2) }
            catch { $visibility = '' }
        }
        else {
            $visibility = Get-DesignerTabVisibility -Target $tab
            if (-not $visibility) { break }
        }
        if ($visibility -eq 'visible') { return $tab }
    }
    return $null
}

function Set-DesignerTabInfo {
    # Address, title and the tab list as the panel shows them (page text: capped, never trusted).
    param([Parameter(Mandatory)][object]$State, [AllowNull()][object[]]$Tabs)
    $browser = $State.Browser
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($tab in @($Tabs) | Select-Object -First 20) {
        $id = [string](Get-DesignerValue -Object $tab -Name 'id')
        $entry = [ordered]@{
            id      = (ConvertTo-DesignerText -Value $id -Max 100)
            url     = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $tab -Name 'url') -Max 2000)
            title   = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $tab -Name 'title') -Max 300)
            current = ($id -eq $browser.TabId)
        }
        if ($entry.current) { $browser.Url = $entry.url; $browser.Title = $entry.title }
        $list.Add($entry)
    }
    $browser.Tabs = $list.ToArray()
}

function Connect-DesignerTab {
    <#
        Attaches the engine's connection to one tab. A zoom preview belongs to the
        connection that set it (spike 1), so it ends here; the panel is told why.
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Target)
    $browser = $State.Browser
    $wasConnected = $browser.Connected
    if ($null -ne $script:CdpSocket) { Close-CdpSocket }
    if ($wasConnected -and $browser.ZoomPercent -ne 100) { $browser.Notice = 'The zoom preview ended because another tab came to the front.' }
    $browser.ZoomPercent = 100
    $browser.ZoomPage = ''
    $script:PageZoomPercent = 100
    $script:PageZoomLost = 0
    $browser.Connected = $false
    Connect-CdpSocket -WebSocketUrl ([string](Get-DesignerValue -Object $Target -Name 'webSocketDebuggerUrl')) -TimeoutSec 5
    $script:CdpTabId = [string](Get-DesignerValue -Object $Target -Name 'id')
    $browser.TabId = $script:CdpTabId
    $browser.Url = ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Target -Name 'url') -Max 2000
    $browser.Title = ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Target -Name 'title') -Max 300
    $browser.Connected = $true
    $browser.Problem = $null
}

function Disconnect-DesignerBrowser {
    <#
        Marks the link as lost and says why. The socket is closed; whatever was being
        picked ends with a message. An Edge the Designer started that is gone is no
        longer the Designer's to close.
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][string]$Code, [AllowEmptyString()][string]$Detail = '')
    $browser = $State.Browser
    if ($null -ne $script:CdpSocket) { Close-CdpSocket }
    $script:PageZoomPercent = 100
    $browser.Connected = $false
    $browser.TabId = ''
    $browser.Url = ''
    $browser.Title = ''
    $browser.Tabs = @()
    $browser.ZoomPercent = 100
    $browser.ZoomPage = ''
    $browser.Problem = Get-DesignerBrowserProblem -Code $Code -Port $browser.Port -ProfileDir $browser.ProfileDir -Detail $Detail
    if ($browser.LaunchedPid -gt 0 -and $null -eq (Get-Process -Id $browser.LaunchedPid -ErrorAction SilentlyContinue)) {
        $browser.LaunchedByDesigner = $false
        $browser.LaunchedPid = 0
    }
    if ($State.Pick.State -eq 'picking') {
        $State.Pick.State = 'error'
        $State.Pick.Code = 'browser'
        $State.Pick.Message = "Picking stopped: $($browser.Problem['message'])"
    }
}

function Connect-DesignerBrowser {
    <#
        Connects the Designer to the audit Edge: the profile and port a run of the open
        configuration would use (Get-DesignerBrowserSetting), checked against the panel's
        profile first (Assert-DesignerProfileSeparate). An Edge already listening on the
        port is reused (Start-EdgeDebug's own rule) and never closed by the Designer; one
        the Designer starts is closed when it stops, unless keepBrowserOpen is set.
        Attaches to the tab the person is looking at. Never throws: a failure leaves the
        reason in State.Browser.Problem for the panel's first screen.
        Blocks while Edge starts (at most about 15 seconds, Start-EdgeDebug's limit).
    #>
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    $browser.Connecting = $true
    $browser.ConnectPending = $false
    $browser.Notice = ''
    try {
        $setting = Get-DesignerBrowserSetting -State $State
        $browser.Port = $setting.Port
        $browser.ProfileDir = $setting.ProfileDir
        $browser.KeepOpen = $setting.KeepOpen
        if ($State.Pick.State -eq 'picking') { Stop-ElementPick -State $State -Message 'Picking stopped because the browser was connected again.' }
        if ($null -ne $script:CdpSocket) { Close-CdpSocket }
        $browser.Connected = $false
        $browser.ZoomPercent = 100
        $browser.ZoomPage = ''
        $script:PageZoomPercent = 100
        try { Assert-DesignerProfileSeparate -State $State -AuditProfile $setting.ProfileDir }
        catch { Disconnect-DesignerBrowser -State $State -Code 'profile' -Detail $_.Exception.Message; return }

        $script:CdpPort = $setting.Port
        $script:CdpTabId = ''
        $info = Get-DebugEndpointInfo -Port $setting.Port -TimeoutSec 2
        $launched = $false
        if ($null -eq $info) {
            if (-not $browser.AllowLaunch) { Disconnect-DesignerBrowser -State $State -Code 'notrunning'; return }
            if (Test-DesignerPortBusy -Port $setting.Port) { Disconnect-DesignerBrowser -State $State -Code 'portbusy'; return }
            if ((Get-EdgeDebugPolicy) -eq $false) { Disconnect-DesignerBrowser -State $State -Code 'policy'; return }
            $edgePath = ''
            try { $edgePath = Find-EdgeExecutable }
            catch { Disconnect-DesignerBrowser -State $State -Code 'noedge' -Detail $_.Exception.Message; return }
            try {
                $info = Start-EdgeDebug -EdgePath $edgePath -ProfileDir $setting.ProfileDir -Port $setting.Port
                $launched = [bool]$script:LaunchedEdge
            }
            catch {
                $code = if ($_.Exception.Message -like '*already running with the audit profile*') { 'profile-open' } else { 'noport' }
                Disconnect-DesignerBrowser -State $State -Code $code -Detail $_.Exception.Message
                return
            }
        }
        else {
            $script:ReusedEdge = $true
            $script:LaunchedEdge = $false
            $script:EdgeProcess = Find-EdgeBrowserProcess -Port $setting.Port
            $script:BrowserWsUrl = Get-BrowserWebSocketUrl -VersionInfo $info
        }
        $edgeId = if ($null -ne $script:EdgeProcess) { $script:EdgeProcess.Id } else { 0 }
        if ($launched) {
            $browser.LaunchedByDesigner = $true
            $browser.LaunchedPid = $edgeId
            $browser.BrowserWsUrl = $script:BrowserWsUrl
        }
        elseif (-not ($browser.LaunchedPid -gt 0 -and $browser.LaunchedPid -eq $edgeId)) {
            $browser.LaunchedByDesigner = $false
            $browser.LaunchedPid = 0
        }

        # A freshly started Edge lists its first tab a moment after the port opens.
        $tabs = [System.Collections.Generic.List[object]]::new()
        $deadline = (Get-Date).AddSeconds(5)
        do {
            try { $tabs = Get-DesignerWebTab -State $State -Targets @(Get-DevToolsTargetList -Port $setting.Port) }
            catch { Write-Verbose "No tab list yet: $($_.Exception.Message)" }
            if ($tabs.Count -gt 0) { break }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        $target = Find-DesignerVisibleTab -State $State -Tabs $tabs
        if ($null -eq $target -and $tabs.Count -gt 0) { $target = $tabs[0] }
        if ($null -eq $target) {
            try { $target = Get-CdpPageTarget -Port $setting.Port -TabId '' }
            catch { Disconnect-DesignerBrowser -State $State -Code 'notab'; return }
        }
        Connect-DesignerTab -State $State -Target $target
        Set-DesignerTabInfo -State $State -Tabs $tabs
    }
    catch {
        Disconnect-DesignerBrowser -State $State -Code 'failed' -Detail "The Designer could not connect to Edge: $($_.Exception.Message)"
    }
    finally {
        $browser.Connecting = $false
        $browser.LastCheck = Get-Date
    }
}

function Update-DesignerBrowser {
    <#
        Follows the audit Edge between requests (about once a second): the tab the person
        looks at (they may open others; the Designer moves to the visible one), a closed
        tab, a closed Edge. Never attaches to Edge's own pages or to the panel. While a
        pick runs, the tab stays the same: the pick belongs to it.
        When not connected it only looks, every few seconds, whether an Edge is back on
        the port (started by the person); starting one is left to Retry.
    #>
    param([Parameter(Mandatory)][object]$State, [switch]$Force)
    $browser = $State.Browser
    if (-not $Force -and ((Get-Date) - $browser.LastCheck).TotalMilliseconds -lt 1000) { return }
    $browser.LastCheck = Get-Date
    if ($browser.Connecting -or $browser.ConnectPending) { return }
    if (-not $browser.Connected) {
        $code = if ($null -ne $browser.Problem) { [string]$browser.Problem['code'] } else { '' }
        if ($browser.Port -gt 0 -and $code -in 'gone', 'notrunning', 'notab' -and ((Get-Date) - $browser.LastProbe).TotalSeconds -ge 3) {
            $browser.LastProbe = Get-Date
            if ($null -ne (Get-DebugEndpointInfo -Port $browser.Port -TimeoutSec 1)) {
                $allow = $browser.AllowLaunch
                $browser.AllowLaunch = $false
                try { Connect-DesignerBrowser -State $State } finally { $browser.AllowLaunch = $allow }
            }
        }
        return
    }
    $targets = $null
    try { $targets = @(Get-DevToolsTargetList -Port $browser.Port) }
    catch { Disconnect-DesignerBrowser -State $State -Code 'gone'; return }
    $tabs = Get-DesignerWebTab -State $State -Targets $targets
    $current = $tabs | Where-Object { [string](Get-DesignerValue -Object $_ -Name 'id') -eq $browser.TabId } | Select-Object -First 1
    if ($State.Pick.State -eq 'picking') { Set-DesignerTabInfo -State $State -Tabs $tabs; return }
    if ($null -eq $current) {
        $next = Find-DesignerVisibleTab -State $State -Tabs $tabs
        if ($null -eq $next -and $tabs.Count -gt 0) { $next = $tabs[0] }
        if ($null -eq $next) { Disconnect-DesignerBrowser -State $State -Code 'notab'; return }
        try { Connect-DesignerTab -State $State -Target $next; $browser.Notice = 'The tab the Designer was using was closed; it now uses the one in front.' }
        catch { Disconnect-DesignerBrowser -State $State -Code 'gone'; return }
    }
    else {
        $visibility = ''
        try { $visibility = [string](Invoke-CdpEval -Expression 'document.visibilityState' -TimeoutSec 2) }
        catch { $visibility = '' }
        # Looking at the other tabs costs a connection each, so at most every 4 seconds.
        if ($visibility -eq 'hidden' -and ((Get-Date) - $browser.LastSweep).TotalSeconds -ge 4) {
            $browser.LastSweep = Get-Date
            $next = Find-DesignerVisibleTab -State $State -Tabs $tabs -Skip $browser.TabId
            if ($null -ne $next) {
                try { Connect-DesignerTab -State $State -Target $next }
                catch { Disconnect-DesignerBrowser -State $State -Code 'gone'; return }
            }
        }
    }
    Set-DesignerTabInfo -State $State -Tabs $tabs
}

function Get-DesignerBrowserData {
    # The link to the audit Edge as the panel shows it (GET /api/state "browser").
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    $different = $false
    if ($browser.Connected) {
        try {
            $setting = Get-DesignerBrowserSetting -State $State
            $different = ($setting.Port -ne $browser.Port) -or -not [string]::Equals($setting.ProfileDir, $browser.ProfileDir, [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch { $different = $false }
    }
    $running = Test-DesignerRunActive -State $State
    $message = if ($browser.Connected) { 'Connected to the audit Edge.' }
    elseif ($running) { 'A run is using the audit Edge. The Designer connects to it again when the run ends.' }
    elseif ($browser.Connecting -or $browser.ConnectPending) { 'Connecting to the audit Edge…' }
    elseif ($null -ne $browser.Problem) { [string]$browser.Problem['message'] }
    else { 'Not connected to the audit Edge.' }
    return [ordered]@{
        connected          = [bool]$browser.Connected
        connecting         = [bool]($browser.Connecting -or $browser.ConnectPending)
        tabId              = $browser.TabId
        url                = $browser.Url
        title              = $browser.Title
        port               = $browser.Port
        profileDir         = $browser.ProfileDir
        launchedByDesigner = [bool]$browser.LaunchedByDesigner
        problem            = $(if ($running) { $null } else { $browser.Problem })
        inRun              = $running
        zoom               = [ordered]@{ percent = [int]$browser.ZoomPercent; page = $browser.ZoomPage }
        settingsChanged    = $different
        notice             = $browser.Notice
        message            = $message
    }
}

function Close-DesignerBrowser {
    <#
        At the end of the Designer: ends a pick, takes the zoom preview off, closes the
        socket, and closes the audit Edge only if the Designer started it and the
        configuration does not ask to keep it open. An Edge it merely reused is the
        person's and stays.
    #>
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    if ($State.Pick.State -eq 'picking') { Stop-ElementPick -State $State -Message 'The Designer stopped.' -NoLayout }
    if ($browser.Connected -and $browser.ZoomPercent -ne 100) {
        try { Clear-PageZoom } catch { Write-Verbose "The zoom preview could not be cleared: $($_.Exception.Message)" }
    }
    if ($null -ne $script:CdpSocket) { Close-CdpSocket }
    $browser.Connected = $false
    $keep = $browser.KeepOpen
    try { $keep = (Get-DesignerBrowserSetting -State $State).KeepOpen } catch { Write-Verbose 'keepBrowserOpen not read again.' }
    if ($browser.LaunchedByDesigner -and -not $keep -and $browser.LaunchedPid -gt 0) {
        $process = Get-Process -Id $browser.LaunchedPid -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $script:LaunchedEdge = $true
            $script:EdgeProcess = $process
            $script:BrowserWsUrl = $browser.BrowserWsUrl
            Stop-EdgeProcess
        }
    }
    $script:LaunchedEdge = $false
}

function Invoke-DesignerBrowserTick {
    <#
        The browser's share of each loop turn: the first connection (after the panel has
        loaded), the pick in progress (polled with short evaluations, so the loop never
        waits on the person), and following the visible tab.
    #>
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    # A run has the browser (it attaches to the same tab): no reconnecting, no looking at tabs.
    if (Test-DesignerRunActive -State $State) { return }
    if ($browser.ConnectPending) {
        Connect-DesignerBrowser -State $State
        [void](Set-DesignerLayout -State $State -Focus panel)
        return
    }
    if ($State.Pick.State -eq 'picking') { Update-ElementPick -State $State }
    Update-DesignerBrowser -State $State
}

function Get-DesignerBrowserRefusal {
    # 409 when a request needs the audit Edge and there is none, with the reason; $null when connected.
    param([Parameter(Mandatory)][object]$State)
    if ($State.Browser.Connected) { return $null }
    $why = if ($null -ne $State.Browser.Problem) { [string]$State.Browser.Problem['message'] } else { 'The Designer is still connecting to Edge.' }
    return New-DesignerError -Status 409 -Code 'no-browser' -Message 'The audit browser is not connected.' -Detail $why
}

function Test-DesignerUrl {
    <#
        Why an address cannot be opened, or ''. The rule of the configuration check
        (http:// or https:// and something after it), plus a parse, so nothing but a web
        page ever reaches Page.navigate (no file:, javascript: or edge: address).
    #>
    param([AllowEmptyString()][string]$Url)
    $text = $Url.Trim()
    if (-not $text) { return 'Enter the address of the page first.' }
    if ($text.Length -gt 4000) { return 'The address is too long.' }
    if ($text -notmatch '^(?i)https?://\S') { return 'The address must start with http:// or https://.' }
    $uri = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https' -or -not $uri.Host) {
        return 'This is not an address Edge can open.'
    }
    return ''
}

function Get-DesignerPageSetting {
    <#
        The settings a run would use for one page of the configuration the panel shows
        (saved or not), made by the engine's own Complete-VouchConfig, Resolve-RunSettings
        and Get-PageSettings - so Go zooms as the run will, and a tested click waits as
        long as the run would. A configuration that cannot be read that far gives the
        defaults.
    #>
    param([AllowNull()][object]$Config, [int]$PageIndex = -1)
    $name = ''
    try {
        if ($Config -isnot [System.Collections.IDictionary]) { throw 'no configuration' }
        $completed = Complete-VouchConfig -Config (Copy-VouchConfig -Config (Repair-VouchConfigKeyCase -Config $Config))
        $run = Resolve-RunSettings -BoundParameters @{} -Defaults @{} -Config $completed
        $pages = @($completed['pages'])
        $page = if ($PageIndex -ge 0 -and $PageIndex -lt $pages.Count) { $pages[$PageIndex] } else { $null }
        $overrides = if ($page -is [System.Collections.IDictionary] -and $page['overrides'] -is [System.Collections.IDictionary]) { $page['overrides'] } else { $null }
        if ($page -is [System.Collections.IDictionary] -and $page['name'] -is [string]) { $name = ConvertTo-DesignerText -Value $page['name'] -Max 120 }
        $settings = Get-PageSettings -Settings $run -Definition ([pscustomobject]@{ Overrides = $overrides }) -Config $completed
        return [pscustomobject]@{ Settings = $settings; Name = $name }
    }
    catch {
        $completed = Complete-VouchConfig -Config (Get-DefaultVouchConfig)
        $run = Resolve-RunSettings -BoundParameters @{} -Defaults @{} -Config $completed
        $settings = Get-PageSettings -Settings $run -Definition ([pscustomobject]@{ Overrides = $null }) -Config $completed
        return [pscustomobject]@{ Settings = $settings; Name = $name }
    }
}

function Set-DesignerZoomPreview {
    <#
        Shows the page at the zoom the run will use (Set-PageZoom: nothing is stored in
        Edge, and it ends with the Designer's connection), or takes it off at 100.
        Returns '' or why the zoom could not be shown.
    #>
    param([Parameter(Mandatory)][object]$State, [int]$Percent = 100, [AllowEmptyString()][string]$PageName = '')
    $browser = $State.Browser
    if ($Percent -eq 100) {
        if ($browser.ZoomPercent -ne 100 -or $script:PageZoomPercent -ne 100) {
            try { Clear-PageZoom } catch { Write-Verbose "The zoom preview could not be cleared: $($_.Exception.Message)" }
        }
        $browser.ZoomPercent = 100
        $browser.ZoomPage = ''
        return ''
    }
    try {
        Set-PageZoom -Percent $Percent
        $browser.ZoomPercent = $Percent
        $browser.ZoomPage = $PageName
        return ''
    }
    catch {
        $browser.ZoomPercent = 100
        $browser.ZoomPage = ''
        return "The page could not be shown at $Percent%: $($_.Exception.Message)"
    }
}

function Update-DesignerZoomPreview {
    # After the window changed size: the zoom is worked out from the window's size, so set it again.
    param([Parameter(Mandatory)][object]$State)
    $browser = $State.Browser
    if (-not $browser.Connected -or $browser.ZoomPercent -eq 100) { return }
    Start-Sleep -Milliseconds 300
    try { Set-PageZoom -Percent $browser.ZoomPercent }
    catch { $browser.ZoomPercent = 100; $browser.ZoomPage = ''; $browser.Notice = 'The zoom preview was lost when the window changed size.' }
}

function ConvertTo-DesignerPageName {
    <#
        A page name from a tab's title: one line, no control characters, at most 80
        characters (cut at a word). An empty title gives the site's host name.
    #>
    param([AllowEmptyString()][string]$Title = '', [AllowEmptyString()][string]$Url = '')
    $name = ($Title -replace '[\x00-\x1F\x7F]', ' ' -replace '\s+', ' ').Trim()
    if ($name.Length -gt 80) {
        $cut = $name.Substring(0, 80)
        $space = $cut.LastIndexOf(' ')
        $name = $(if ($space -ge 40) { $cut.Substring(0, $space) } else { $cut }).TrimEnd(' ', '-', '|', ',', ':') + [char]0x2026
    }
    if (-not $name) {
        $uri = $null
        if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Host) { $name = $uri.Host } else { $name = 'New page' }
    }
    return $name
}

function Invoke-DesignerBrowserCurrent {
    # GET /api/browser/current: the attached tab, looked at now, and the other web tabs.
    param([Parameter(Mandatory)][object]$State)
    Update-DesignerBrowser -State $State -Force
    $browser = $State.Browser
    return New-DesignerJsonResponse -Data ([ordered]@{
            connected          = [bool]$browser.Connected
            tabId              = $browser.TabId
            url                = $browser.Url
            title              = $browser.Title
            tabs               = @($browser.Tabs)
            launchedByDesigner = [bool]$browser.LaunchedByDesigner
        })
}

function Invoke-DesignerBrowserConnect {
    # POST /api/browser/connect: the panel's Retry / Reconnect - connect (or start Edge) now, then tidy the windows.
    param([Parameter(Mandatory)][object]$State)
    Connect-DesignerBrowser -State $State
    if ($State.Browser.Connected) { [void](Set-DesignerLayout -State $State -Focus panel) }
    return New-DesignerJsonResponse -Data (Get-DesignerBrowserData -State $State)
}

function Invoke-DesignerLayoutRequest {
    # POST /api/browser/layout: "Tidy windows".
    param([Parameter(Mandatory)][object]$State)
    $layout = Set-DesignerLayout -State $State -Focus panel
    return New-DesignerJsonResponse -Data ([ordered]@{ ok = [bool]$layout.Ok; message = $layout.Message })
}

function Invoke-DesignerZoomOff {
    # POST /api/browser/zoom-off: show the page at 100% again.
    param([Parameter(Mandatory)][object]$State)
    $refusal = Get-DesignerBrowserRefusal -State $State
    if ($null -ne $refusal) { return $refusal }
    [void](Set-DesignerZoomPreview -State $State -Percent 100)
    return New-DesignerJsonResponse -Data (Get-DesignerBrowserData -State $State)
}

function Invoke-DesignerPageFromCurrent {
    # POST /api/page/from-current: a name (from the tab's title) and the address of the page in front.
    param([Parameter(Mandatory)][object]$State)
    Update-DesignerBrowser -State $State -Force
    $refusal = Get-DesignerBrowserRefusal -State $State
    if ($null -ne $refusal) { return $refusal }
    $url = $State.Browser.Url
    if (Test-DesignerUrl -Url $url) {
        return New-DesignerError -Status 409 -Code 'no-page' -Message 'The tab in front shows no web page.' -Detail 'Open the page in the audit Edge window first (sign in if needed), then add it.'
    }
    return New-DesignerJsonResponse -Data ([ordered]@{ name = (ConvertTo-DesignerPageName -Title $State.Browser.Title -Url $url); url = $url })
}

function Invoke-DesignerNavigate {
    <#
        POST /api/browser/navigate {url, config?, pageIndex?}: opens the page in the
        attached tab and waits for it with the engine's own wait (Wait-PageReady). With
        the configuration and the page's position, the page is shown at the zoom the run
        will use (or at 100% again).
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $url = (Get-DesignerBodyText -Body $Body -Name 'url').Trim()
    $problem = Test-DesignerUrl -Url $url
    if ($problem) { return New-DesignerError -Status 400 -Code 'url' -Message $problem -Detail 'Correct the address of the page, then press Go again.' }
    $refusal = Get-DesignerBrowserRefusal -State $State
    if ($null -ne $refusal) { return $refusal }
    if ($State.Pick.State -eq 'picking') { Stop-ElementPick -State $State -Message 'Picking stopped because another page was opened.' -NoLayout }
    $page = Get-DesignerPageSetting -Config $Body['config'] -PageIndex (Get-DesignerBodyNumber -Body $Body -Name 'pageIndex')
    $zoom = (Get-PageCaptureMode -Settings $page.Settings).ZoomPercent
    $zoomProblem = Set-DesignerZoomPreview -State $State -Percent $zoom -PageName $page.Name
    $status = 'loaded'
    $message = ''
    try {
        Set-NavigationMarker
        $navigation = Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $url } -TimeoutSec 30
        $errorText = [string](Get-DesignerValue -Object $navigation -Name 'errorText')
        if ($errorText) {
            $status = 'error'
            $message = "Edge could not open the page ($(ConvertTo-DesignerText -Value $errorText -Max 120))."
        }
        elseif (-not (Wait-PageReady -TimeoutSec ([int]$page.Settings.NavigationTimeoutSec))) {
            $status = 'slow'
            $message = "The page had not finished loading after $([int]$page.Settings.NavigationTimeoutSec) seconds; it is shown as far as it got."
        }
    }
    catch {
        Update-DesignerBrowser -State $State -Force
        return New-DesignerError -Status 502 -Code 'navigate' -Message 'The browser could not open the page.' -Detail ([string]$_.Exception.Message)
    }
    $title = ''
    $final = $url
    try {
        $title = ConvertTo-DesignerText -Value (Invoke-CdpEval -Expression 'document.title' -TimeoutSec 5) -Max 300
        $final = ConvertTo-DesignerText -Value (Invoke-CdpEval -Expression 'location.href' -TimeoutSec 5) -Max 2000
    }
    catch { Write-Verbose "The page's title could not be read: $($_.Exception.Message)" }
    $State.Browser.Url = $final
    $State.Browser.Title = $title
    if (-not $message) { $message = 'Opened.' }
    if ($zoomProblem) { $message += " $zoomProblem" }
    return New-DesignerJsonResponse -Data ([ordered]@{
            url     = $final
            title   = $title
            status  = $status
            message = $message
            zoom    = [ordered]@{ percent = [int]$State.Browser.ZoomPercent; page = $State.Browser.ZoomPage }
        })
}

function Invoke-DesignerActionTest {
    <#
        POST /api/action/test {action, config?, pageIndex?}: runs ONE action on the page
        in front, through the engine's own Invoke-PageAction with the settings the run
        would use for that page - so it really clicks. Captures and pauses belong to a
        page test (they need the whole page run). Waits are capped at 15 seconds here so
        the Designer does not sit still for minutes; the answer says so.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $action = $Body['action']
    if ($action -isnot [System.Collections.IDictionary]) {
        return New-DesignerError -Status 400 -Code 'action' -Message 'There was no action to test.' -Detail 'The request did not hold an action.'
    }
    $type = Get-VouchActionType -Type $action['type']
    if ($type -in 'capture', 'pause') {
        return New-DesignerJsonResponse -Data ([ordered]@{
                ok = $false; navigated = $false; url = $State.Browser.Url
                message = $(if ($type -eq 'capture') { 'A capture is tried with "Test this page", which takes the screenshots the way the run will.' } else { 'A pause is tried with "Test this page": it needs the run''s Vouch dialog.' })
            })
    }
    if ($type -notin 'click', 'clickText', 'wait', 'waitFor') {
        return New-DesignerError -Status 400 -Code 'action' -Message 'This kind of action cannot be tested.' -Detail 'Only clicks, waits and wait-fors can be tried one by one.'
    }
    $copy = [ordered]@{ type = $type }
    $note = ''
    switch ($type) {
        'click' {
            $copy['selector'] = [string](Get-DesignerValue -Object $action -Name 'selector')
            if (-not $copy['selector'].Trim()) { return New-DesignerError -Status 400 -Code 'action' -Message 'Enter the selector of what to click first.' }
        }
        'clickText' {
            $copy['text'] = [string](Get-DesignerValue -Object $action -Name 'text')
            if (-not $copy['text'].Trim()) { return New-DesignerError -Status 400 -Code 'action' -Message 'Enter the words to click first.' }
        }
        'wait' {
            $seconds = Get-DesignerValue -Object $action -Name 'seconds'
            if ($seconds -isnot [ValueType] -or $seconds -is [bool] -or [double]$seconds -lt 0) { return New-DesignerError -Status 400 -Code 'action' -Message 'Enter the number of seconds to wait first.' }
            $copy['seconds'] = [Math]::Min([double]$seconds, 15)
            if ([double]$seconds -gt 15) { $note = ' (A test waits at most 15 seconds; the run waits the full time.)' }
        }
        'waitFor' {
            $copy['selector'] = [string](Get-DesignerValue -Object $action -Name 'selector')
            if (-not $copy['selector'].Trim()) { return New-DesignerError -Status 400 -Code 'action' -Message 'Enter the selector of the element to wait for first.' }
        }
    }
    $refusal = Get-DesignerBrowserRefusal -State $State
    if ($null -ne $refusal) { return $refusal }
    if ($State.Pick.State -eq 'picking') { Stop-ElementPick -State $State -Message 'Picking stopped because an action was tested.' -NoLayout }
    $page = Get-DesignerPageSetting -Config $Body['config'] -PageIndex (Get-DesignerBodyNumber -Body $Body -Name 'pageIndex')
    $settings = $page.Settings
    if ($type -eq 'waitFor') {
        $timeout = Get-DesignerValue -Object $action -Name 'timeoutSec'
        $limit = if ($timeout -is [ValueType] -and $timeout -isnot [bool] -and [double]$timeout -gt 0) { [double]$timeout } else { [double]$settings.NavigationTimeoutSec }
        $copy['timeoutSec'] = [Math]::Min($limit, 15)
        if ($limit -gt 15) { $note = ' (A test waits at most 15 seconds; the run waits up to the full time limit.)' }
    }
    $before = ''
    try { $before = [string](Invoke-CdpEval -Expression 'location.href' -TimeoutSec 5) } catch { $before = '' }
    $entry = Invoke-PageAction -Action $copy -Settings $settings
    $after = $before
    $newDocument = $false
    try {
        $after = [string](Invoke-CdpEval -Expression 'location.href' -TimeoutSec 5)
        $newDocument = $type -in 'click', 'clickText' -and [bool](Invoke-CdpEval -Expression "typeof window.__vouchMark === 'undefined'" -TimeoutSec 5)
    }
    catch { Write-Verbose "The page after the test could not be read: $($_.Exception.Message)" }
    $navigated = ($after -ne $before) -or $newDocument
    $after = ConvertTo-DesignerText -Value $after -Max 2000
    $State.Browser.Url = $after
    if ($entry.Ok) {
        $message = switch ($type) {
            'click' { if ($navigated) { "Clicked. The browser then showed $after." } else { 'Clicked. The page stayed where it was.' } }
            'clickText' { if ($navigated) { "Clicked. The browser then showed $after." } else { 'Clicked. The page stayed where it was.' } }
            'wait' { "Waited $(([double]$copy['seconds']).ToString([System.Globalization.CultureInfo]::InvariantCulture)) second(s)." }
            'waitFor' { 'Found: the element is on the page and visible.' }
        }
    }
    else { $message = "Did not work: $(ConvertTo-DesignerText -Value ([string]$entry.Message) -Max 400)" }
    [void](Set-DesignerLayout -State $State -Focus panel)
    return New-DesignerJsonResponse -Data ([ordered]@{ ok = [bool]$entry.Ok; message = $message + $note; navigated = $navigated; url = $after })
}

#endregion

#region Windows ------------------------------------------------------------------------

function Initialize-DesignerWindowInterop {
    <#
        Moving and sizing the two windows. A type of its own (Vouch.DesignerWindow): a
        PowerShell session keeps a compiled type, so members cannot be added to
        Vouch.DesignerNative in a session that already loaded it.
    #>
    if (-not ('Vouch.DesignerWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Vouch
{
    [StructLayout(LayoutKind.Sequential)]
    public struct DesignerRect { public int Left; public int Top; public int Right; public int Bottom; }

    public static class DesignerWindow
    {
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out DesignerRect rect);
        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out DesignerRect rect, int size);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int command);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    }
}
'@ -Language CSharp
    }
}

function Get-DesignerWindowHandle {
    # The main window of a process, looked up afresh (Process caches it), or zero: never waits.
    param([int]$ProcessId = 0)
    if ($ProcessId -le 0) { return [IntPtr]::Zero }
    try { return (Get-Process -Id $ProcessId -ErrorAction Stop).MainWindowHandle }
    catch { return [IntPtr]::Zero }
}

function Get-DesignerLayoutPlan {
    <#
        Where the two windows go (pure): the panel at the right edge of the working area,
        the audit Edge filling the rest, both full height and not maximised. The panel
        keeps its current width when that is sensible (the person may have widened it),
        never more than half the screen.
    #>
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$WorkingArea,
        [int]$PanelWidth = 0,
        [int]$DefaultWidth = 480
    )
    $width = if ($PanelWidth -ge 320) { $PanelWidth } else { $DefaultWidth }
    $width = [Math]::Max(1, [Math]::Min($width, [int][Math]::Floor($WorkingArea.Width / 2)))
    return [pscustomobject]@{
        Edge  = [System.Drawing.Rectangle]::new($WorkingArea.Left, $WorkingArea.Top, $WorkingArea.Width - $width, $WorkingArea.Height)
        Panel = [System.Drawing.Rectangle]::new($WorkingArea.Right - $width, $WorkingArea.Top, $width, $WorkingArea.Height)
    }
}

function Get-DesignerWindowFrame {
    <#
        A window's visible bounds (DWM extended frame bounds: what is drawn) and its outer
        bounds (GetWindowRect, with the invisible resize borders), so a window can be put
        exactly where its visible edge should be.
    #>
    param([Parameter(Mandatory)][IntPtr]$Handle)
    $outer = [Vouch.DesignerRect]::new()
    if (-not [Vouch.DesignerWindow]::GetWindowRect($Handle, [ref]$outer)) { return $null }
    $visible = [Vouch.DesignerRect]::new()
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Vouch.DesignerRect])
    if ([Vouch.DesignerWindow]::DwmGetWindowAttribute($Handle, 9, [ref]$visible, $size) -ne 0) { $visible = $outer }
    return [pscustomobject]@{
        Outer   = [System.Drawing.Rectangle]::FromLTRB($outer.Left, $outer.Top, $outer.Right, $outer.Bottom)
        Visible = [System.Drawing.Rectangle]::FromLTRB($visible.Left, $visible.Top, $visible.Right, $visible.Bottom)
    }
}

function Move-DesignerWindow {
    <#
        Puts a window's visible edges on -Bounds. A minimised or maximised window is
        restored first (a maximised window ignores a new size), and the invisible borders
        are added back so no gap or overlap shows between the two windows.
    #>
    param([Parameter(Mandatory)][IntPtr]$Handle, [Parameter(Mandatory)][System.Drawing.Rectangle]$Bounds)
    if (-not [Vouch.DesignerWindow]::IsWindow($Handle)) { return $false }
    if ([Vouch.DesignerWindow]::IsIconic($Handle) -or [Vouch.DesignerWindow]::IsZoomed($Handle)) {
        [void][Vouch.DesignerWindow]::ShowWindow($Handle, 9)   # SW_RESTORE
        Start-Sleep -Milliseconds 150
    }
    $frame = Get-DesignerWindowFrame -Handle $Handle
    if ($null -eq $frame) { return $false }
    $left = $frame.Visible.Left - $frame.Outer.Left
    $top = $frame.Visible.Top - $frame.Outer.Top
    $right = $frame.Outer.Right - $frame.Visible.Right
    $bottom = $frame.Outer.Bottom - $frame.Visible.Bottom
    # SWP_NOZORDER | SWP_NOACTIVATE
    return [bool][Vouch.DesignerWindow]::SetWindowPos($Handle, [IntPtr]::Zero, $Bounds.Left - $left, $Bounds.Top - $top,
        $Bounds.Width + $left + $right, $Bounds.Height + $top + $bottom, 0x0014)
}

function Set-DesignerForegroundWindow {
    <#
        Brings a window to the front. Windows refuses SetForegroundWindow to a process
        that did not send the last input; a synthetic Alt press and release (as the
        engine's Set-EdgeForeground does) satisfies the rule without typing anything.
    #>
    param([Parameter(Mandatory)][IntPtr]$Handle)
    if ([Vouch.DesignerWindow]::SetForegroundWindow($Handle) -and [Vouch.DesignerWindow]::GetForegroundWindow() -eq $Handle) { return $true }
    [Vouch.DesignerWindow]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [Vouch.DesignerWindow]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][Vouch.DesignerWindow]::SetForegroundWindow($Handle)
    return ([Vouch.DesignerWindow]::GetForegroundWindow() -eq $Handle)
}

function Set-DesignerLayout {
    <#
        The audit Edge on the left and the panel on the right of the primary screen's
        working area, neither maximised (Get-DesignerLayoutPlan); -Focus panel then brings
        the panel to the front. Safe when either window is missing (no panel, a headless
        or closed Edge) or minimised: it does what it can and says what it did.
        The process is made DPI-aware first (Initialize-NativeInterop), so the screen and
        every window are measured and placed in the same physical pixels; the panel was
        launched before that, at its --window-size in the units Edge expects.
    #>
    param([Parameter(Mandatory)][object]$State, [ValidateSet('panel', 'none')][string]$Focus = 'none')
    $panelId = if ($null -ne $State.PanelProcess) { try { $State.PanelProcess.Id } catch { 0 } } else { 0 }
    $edgeId = if ($State.Browser.Connected -and $null -ne $script:EdgeProcess) { try { $script:EdgeProcess.Id } catch { 0 } } else { 0 }
    $panel = Get-DesignerWindowHandle -ProcessId $panelId
    $edge = Get-DesignerWindowHandle -ProcessId $edgeId
    if ($panel -eq [IntPtr]::Zero -or $edge -eq [IntPtr]::Zero) {
        $missing = if ($panel -eq [IntPtr]::Zero -and $edge -eq [IntPtr]::Zero) { 'Neither the Designer window nor an audit Edge window was found' }
        elseif ($panel -eq [IntPtr]::Zero) { 'The Designer window was not found' } else { 'No audit Edge window was found' }
        return [pscustomobject]@{ Ok = $false; Message = "$missing, so the windows were left as they are." }
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Initialize-NativeInterop
        Initialize-DesignerWindowInterop
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $scale = 1.0
        $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { $scale = $graphics.DpiX / 96.0 } finally { $graphics.Dispose() }
        $width = 0
        if (-not [Vouch.DesignerWindow]::IsIconic($panel) -and -not [Vouch.DesignerWindow]::IsZoomed($panel)) {
            $frame = Get-DesignerWindowFrame -Handle $panel
            if ($null -ne $frame) { $width = $frame.Visible.Width }
        }
        $plan = Get-DesignerLayoutPlan -WorkingArea $area -PanelWidth $width -DefaultWidth ([int][Math]::Round(480 * $scale))
        $edgeMoved = Move-DesignerWindow -Handle $edge -Bounds $plan.Edge
        $panelMoved = Move-DesignerWindow -Handle $panel -Bounds $plan.Panel
        if ($Focus -eq 'panel') { [void](Set-DesignerForegroundWindow -Handle $panel) }
        Update-DesignerZoomPreview -State $State
        if ($edgeMoved -and $panelMoved) { return [pscustomobject]@{ Ok = $true; Message = 'The browser is on the left and the Designer on the right.' } }
        return [pscustomobject]@{ Ok = $false; Message = 'Windows did not let the Designer move every window.' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Message = "The windows could not be arranged: $($_.Exception.Message)" }
    }
}

function Show-DesignerAuditWindow {
    <#
        Brings the audit Edge to the front for a pick, maximised - the size the run sees
        the page at (Set-EdgeForeground, as a screen capture does), because many sites lay
        out differently at the narrower tiled width and a selector picked there could miss
        at run time. The zoom preview is worked out again for the new size.
    #>
    param([Parameter(Mandatory)][object]$State)
    $edgeId = if ($null -ne $script:EdgeProcess) { try { $script:EdgeProcess.Id } catch { 0 } } else { 0 }
    if ((Get-DesignerWindowHandle -ProcessId $edgeId) -eq [IntPtr]::Zero) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Initialize-NativeInterop
        [void](Set-EdgeForeground -TimeoutSec 2)
        Update-DesignerZoomPreview -State $State
    }
    catch { Write-Verbose "The browser could not be brought to the front: $($_.Exception.Message)" }
}

#endregion

#region Picker ---------------------------------------------------------------------------

function Get-DesignerPickerText {
    # The words the picker shows in the page, per mode (passed in as data, never as code).
    param([Parameter(Mandatory)][ValidateSet('click', 'scroll', 'waitFor')][string]$Mode)
    $banner = switch ($Mode) {
        'click' { 'Vouch: click what Vouch should click. Esc cancels.' }
        'scroll' { 'Vouch: click inside the area Vouch should scroll. Esc cancels.' }
        'waitFor' { 'Vouch: click the element Vouch should wait for. Esc cancels.' }
    }
    return [ordered]@{
        banner      = $banner
        crossorigin = 'This part is a frame from another site: Vouch cannot record anything inside it.'
        transformed = 'This frame is shown scaled or turned, so Vouch cannot tell exactly what you point at in it.'
        shadow      = 'This is inside a page component (shadow DOM) that Vouch cannot look into.'
        changed     = (Get-DesignerPickNote -Code 'changed')
        'changed-again' = (Get-DesignerPickNote -Code 'changed-again')
        uncovered   = (Get-DesignerPickNote -Code 'uncovered')
        'uncovered-dialog'     = (Get-DesignerPickNote -Code 'uncovered-dialog')
        'uncovered-popup'      = (Get-DesignerPickNote -Code 'uncovered-popup')
        'uncovered-fullscreen' = (Get-DesignerPickNote -Code 'uncovered-fullscreen')
        shortcut    = (Get-DesignerPickNote -Code 'shortcut')
        page        = 'The whole page'
        nothing     = 'Nothing here scrolls. Point inside the area with the scroll bar.'
        climbed     = 'part of it'
        checking    = 'Checking that Vouch can replay this…'
    }
}

function Get-DesignerPickNote {
    <#
        The words for a short note the picker reports by code while picking goes on: the
        page changed between press and release, the click landed on something the page
        shows above the picking layer, or the browser clicked one of the page's controls
        for an access key (Alt + a letter; Edge offers no way to switch those off, the
        picker cancels the click). Codes only come from the page, so an unknown one
        gives ''.
    #>
    param([AllowEmptyString()][string]$Code)
    $type = 'Type its words or selector in the Designer instead.'
    switch -CaseSensitive ($Code) {
        'changed' { return 'The page changed under the pointer between press and release, so nothing was picked. Click again.' }
        'changed-again' { return "The page keeps changing under the pointer, so pointing does not work here. $type" }
        'uncovered' { return "That part of the page is shown above Vouch's picking layer, so it cannot be picked by pointing. $type" }
        'uncovered-dialog' { return "That is in a pop-up dialog the page shows above everything else, so it cannot be picked by pointing. $type" }
        'uncovered-popup' { return "That is in a pop-up the page shows above everything else, so it cannot be picked by pointing. $type" }
        'uncovered-fullscreen' { return "That is in a part of the page shown full screen above everything else, so it cannot be picked by pointing. $type" }
        'shortcut' { return 'That key is a shortcut of this page (Alt and a letter): the page moved the keyboard focus to one of its controls. Vouch cancelled the click that goes with it, so nothing was picked. Click with the mouse to pick.' }
    }
    return ''
}

function Get-DesignerPickerScript {
    <#
        The picker (designer\picker.js) as one expression for Invoke-CdpEval, inside a
        closure that holds the engine's own frame helpers (Get-FrameDocsScript), so the
        picker walks exactly the documents a click searches. Mode, token and texts go in
        through ConvertTo-JsLiteral; picker.js is never served to the panel.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][ValidateSet('click', 'scroll', 'waitFor')][string]$Mode,
        [Parameter(Mandatory)][string]$Token
    )
    $file = Join-Path -Path $State.DesignerDirectory -ChildPath 'picker.js'
    if (-not [System.IO.File]::Exists($file)) { throw "A file of the Designer is missing: picker.js is not in $($State.DesignerDirectory). Copy the whole Vouch folder again." }
    $source = [System.IO.File]::ReadAllText($file)
    $texts = Get-DesignerPickerText -Mode $Mode
    $pairs = foreach ($key in $texts.Keys) { "$(ConvertTo-JsLiteral -Value $key): $(ConvertTo-JsLiteral -Value $texts[$key])" }
    $config = "{ mode: $(ConvertTo-JsLiteral -Value $Mode), token: $(ConvertTo-JsLiteral -Value $Token), texts: { $($pairs -join ', ') } }"
    return "(function () {`n$(Get-FrameDocsScript)`nreturn ($source`n)($config);`n})()"
}

function Get-DesignerPickShieldScript {
    <#
        What the browser runs at the very start of every NEW document in the tab while a
        pick is on (Page.addScriptToEvaluateOnNewDocument), in the page and in its frames
        from the same site. A frame from another site runs in a process of its own, which
        this connection does not reach: the shield is not there, so in a freshly loaded
        page clicks and keys inside such a frame act normally until the picker is back.
        A page that reloads or moves on by itself takes the picker with it, and the picker
        only comes back at the next poll: without this, a click in between would act on
        the fresh page (established in headless Edge: a click 250 ms after
        location.reload() reached the site's button).
        The shield only swallows - clicks, keys, edits - and picks nothing. It sits in the
        picker's own global, so the picker replaces it when it arrives (its start stops
        whatever was there), and Close-ElementPick's stop() removes it. It also removes
        itself after 4 seconds: should the Designer ever fail to take the script back,
        a page is never left dead for longer than that.
    #>
    return @'
(function () {
  'use strict';
  var NS = '__vouchPicker';
  if (window[NS]) { return; }
  var types = ['pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu',
    'touchstart', 'touchend', 'touchcancel', 'dragstart', 'drop', 'submit', 'keydown', 'keypress', 'keyup', 'beforeinput', 'cut', 'paste'];
  var timer = 0;
  function swallow(ev) { ev.preventDefault(); ev.stopImmediatePropagation(); ev.stopPropagation(); }
  var api = { shield: true, stop: function () {
    types.forEach(function (type) { window.removeEventListener(type, swallow, true); });
    if (timer) { clearTimeout(timer); timer = 0; }
    if (window[NS] === api) { try { delete window[NS]; } catch (e) { window[NS] = undefined; } }
    return true;
  } };
  types.forEach(function (type) { window.addEventListener(type, swallow, true); });
  timer = setTimeout(api.stop, 4000);
  Object.defineProperty(window, NS, { value: api, configurable: true, enumerable: false, writable: true });
})();
'@
}

function Add-ElementPickShield {
    <#
        Has the browser put the shield into every new document of the tab from now on.
        Edge only runs such scripts while the connection's Page domain is enabled
        (established: registered without it, the script never ran), so it is enabled for
        the pick and disabled again afterwards - nothing else here uses it.
        Without the shield picking still works as before (the page is then unprotected
        for a moment after it reloads by itself), so a browser that refuses is not an error.
    #>
    param([Parameter(Mandatory)][object]$Pick)
    try {
        [void](Send-CdpCommand -Method 'Page.enable' -TimeoutSec 5)
        $answer = Send-CdpCommand -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{ source = (Get-DesignerPickShieldScript) } -TimeoutSec 5
        $Pick.ShieldId = [string](Get-DesignerValue -Object $answer -Name 'identifier')
    }
    catch { Write-Verbose "The shield for new pages could not be set: $($_.Exception.Message)" }
}

function Remove-ElementPickShield {
    <#
        Takes the shield script back, so pages loaded after the pick are left alone. A
        connection that is gone took the script with it (it belongs to the connection);
        a shield already in a page ends with the picker's stop() or by itself.
    #>
    param([Parameter(Mandatory)][object]$Pick, [int]$TimeoutSec = 3)
    if (-not $Pick.ShieldId) { return }
    $id = $Pick.ShieldId
    $Pick.ShieldId = ''
    try {
        [void](Send-CdpCommand -Method 'Page.removeScriptToEvaluateOnNewDocument' -Params @{ identifier = $id } -TimeoutSec $TimeoutSec)
        [void](Send-CdpCommand -Method 'Page.disable' -TimeoutSec $TimeoutSec)
    }
    catch { Write-Verbose "The shield for new pages could not be taken back: $($_.Exception.Message)" }
}

function Test-DesignerGeneratedId {
    <#
        Whether an id looks made up afresh by a program (so it would differ on the next
        visit and must not be recorded): long digit runs, UUIDs, hash-like hex, letters
        and digits shuffled together, and the numbered prefixes common frameworks use.
    #>
    param([AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $true }
    if ($Id.Length -gt 64) { return $true }
    if ($Id -match '\d{4,}' -or $Id -match '^\d' -or $Id -match '[:«»]') { return $true }
    if ($Id -match '(?i)[0-9a-f]{8}-[0-9a-f]{4}') { return $true }
    foreach ($run in [regex]::Matches($Id, '(?i)[0-9a-f]{8,}')) {
        if ($run.Value -match '\d' -and $run.Value -match '(?i)[a-f]') { return $true }
    }
    if ($Id -match '(?i)^(ember|ext-gen|ext-comp|yui_|ui-id-|mui-|react-|radix-|headlessui-|rc-|gwt-uid-|j_id|jsx-|__next)\S*\d') { return $true }
    if ($Id -cmatch '[A-Za-z]+\d+[A-Za-z]+\d+[A-Za-z]+\d') { return $true }
    return $false
}

function Test-DesignerShadowHost {
    <#
        Whether the picked element hosts a shadow root, open or closed. The picker sees
        into open ones itself; a closed one hides where the click really landed. Neither
        the engine's selectors nor its words reach inside, so such a pick cannot be
        recorded. DOM.describeNode sees both kinds (no DOM.enable needed).
    #>
    $objectId = ''
    try {
        $answer = Send-CdpCommand -Method 'Runtime.evaluate' -TimeoutSec 5 -Params @{
            expression = '(window.__vouchPicker && typeof window.__vouchPicker.element === "function") ? window.__vouchPicker.element() : null'
            returnByValue = $false
        }
        $objectId = [string](Get-DesignerValue -Object (Get-DesignerValue -Object $answer -Name 'result') -Name 'objectId')
        if (-not $objectId) { return $false }
        $described = Send-CdpCommand -Method 'DOM.describeNode' -Params @{ objectId = $objectId; depth = 1 } -TimeoutSec 5
        $roots = Get-DesignerValue -Object (Get-DesignerValue -Object $described -Name 'node') -Name 'shadowRoots'
        # Form fields have a browser-made ("user-agent") shadow root; only the page's own count.
        return (@($roots | Where-Object { $null -ne $_ -and [string](Get-DesignerValue -Object $_ -Name 'shadowRootType') -ne 'user-agent' }).Count -gt 0)
    }
    catch { return $false }
    finally {
        if ($objectId) {
            try { [void](Send-CdpCommand -Method 'Runtime.releaseObject' -Params @{ objectId = $objectId } -TimeoutSec 5) }
            catch { Write-Verbose 'The picked element could not be released.' }
        }
    }
}

function Test-ElementPickProposal {
    <#
        The proof behind every candidate: the ENGINE's own scripts, run on the live page,
        must resolve the proposal to the very element the person picked (the picker
        marked it with this pick's token). Text: the clicktext search in find-only mode.
        Selector: the click's search (first match in the page, then its same-site frames).
        Wait-for: that, and Wait-PageElement finds a visible match now. Scroll area: that,
        and the scroll search in "area" mode takes it with no fallback; the whole page:
        the scroll search in "page" mode finds the window scrolling.
        Returns { Ok; Exact }.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('click', 'scroll', 'waitFor')][string]$Mode,
        [Parameter(Mandatory)][string]$Kind,
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Token,
        [string]$ScrollKind = '',
        # Each evaluation's limit (what is left of the pick's overall deadline).
        [int]$TimeoutSec = 10
    )
    $no = [pscustomobject]@{ Ok = $false; Exact = $false }
    $TimeoutSec = [Math]::Max(1, $TimeoutSec)
    try {
        if ($Mode -eq 'scroll' -and $Kind -eq 'page') {
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript -Mode page) -TimeoutSec $TimeoutSec
            return [pscustomobject]@{ Ok = ([string](Get-DesignerValue -Object $target -Name 'kind') -eq 'window'); Exact = $true }
        }
        if ($Kind -eq 'text') {
            if ($Mode -ne 'click') { return $no }
            $found = Invoke-CdpEval -Expression (Get-ClickTextScript -Text $Value -FindOnly) -TimeoutSec $TimeoutSec
            $hit = ((Get-DesignerValue -Object $found -Name 'found') -eq $true) -and ([string](Get-DesignerValue -Object $found -Name 'mark') -ceq $Token)
            return [pscustomobject]@{ Ok = $hit; Exact = ((Get-DesignerValue -Object $found -Name 'exact') -eq $true) }
        }
        $found = Invoke-CdpEval -Expression (Get-ClickSelectorScript -Selector $Value -FindOnly) -TimeoutSec $TimeoutSec
        $hit = ((Get-DesignerValue -Object $found -Name 'found') -eq $true) -and ([string](Get-DesignerValue -Object $found -Name 'mark') -ceq $Token)
        if (-not $hit) { return $no }
        if ($Mode -eq 'waitFor') { return [pscustomobject]@{ Ok = [bool](Wait-PageElement -Selector $Value -TimeoutSec 0); Exact = $true } }
        if ($Mode -eq 'scroll') {
            $target = Invoke-CdpEval -Expression (Get-ScrollTargetScript -Mode area -Selector $Value) -TimeoutSec $TimeoutSec
            $ok = ([string](Get-DesignerValue -Object $target -Name 'fallback') -eq '') -and ([string](Get-DesignerValue -Object $target -Name 'kind') -eq $ScrollKind)
            return [pscustomobject]@{ Ok = $ok; Exact = $true }
        }
        return [pscustomobject]@{ Ok = $true; Exact = $true }
    }
    catch {
        # An invalid selector, or a page that went away: not offered.
        return $no
    }
}

function New-ElementPickCandidate {
    <#
        One verified candidate as the panel offers it: what is recorded (the action, the
        scroll settings or the selector), a plain description built here from capped page
        text, and how robust it is.
    #>
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Kind,
        [AllowEmptyString()][string]$Value,
        [bool]$Exact = $true,
        [AllowEmptyString()][string]$Attr = '',
        [AllowEmptyString()][string]$AttrValue = '',
        [Parameter(Mandatory)][System.Collections.IDictionary]$Element
    )
    $q = { param($t) [char]0x2018 + (ConvertTo-DesignerText -Value ([string]$t) -Max 60) + [char]0x2019 }
    $noun = [string]$Element['noun']
    if ($Mode -eq 'scroll') { $noun = if ($Element['kind'] -eq 'frame') { 'frame' } else { 'scrolling area' } }
    $where = if ($Element['frame']) { " in the frame $(& $q $Element['frame'])" } else { '' }
    $short = ConvertTo-DesignerText -Value $AttrValue -Max 60
    switch ($Kind) {
        'page' { $description = 'the whole page (its own scroll bar)'; $robustness = 'best'; $note = 'Scrolls the page itself from top to bottom.' }
        'text' {
            if ($Exact) { $description = "the $(& $q $Value) $noun$where"; $robustness = 'best'; $note = 'Clicks what shows exactly these words, so it keeps working when the page''s design changes.' }
            else { $description = "the $noun showing $(& $q $Value)$where"; $robustness = 'fair'; $note = 'Less robust: it matches only part of the words on it, so a change on the page could make Vouch click something else.' }
        }
        'testid' { $description = "the $noun with the test id $short$where"; $robustness = 'good'; $note = 'Test ids are put there by the site''s developers and usually stay the same.' }
        'id' { $description = "the $noun with the id $short$where"; $robustness = 'good'; $note = 'Keeps working as long as the page keeps this id.' }
        'attribute' {
            $description = switch ($Attr) {
                'aria-label' { "the $noun labelled $(& $q $AttrValue)$where" }
                'name' { "the $noun named $(& $q $AttrValue)$where" }
                default { "the $noun with the hint $(& $q $AttrValue)$where" }
            }
            $robustness = 'fair'; $note = 'Changes when the site changes this wording.'
        }
        default { $description = "the $noun at this place in the page's layout$where"; $robustness = 'fragile'; $note = 'Fragile: it depends on the page''s layout and breaks when that changes. Use it only when nothing better is offered.' }
    }
    $candidate = [ordered]@{ kind = $Kind; value = $Value; description = $description; robustness = $robustness; note = $note }
    switch ($Mode) {
        'click' { $candidate['action'] = if ($Kind -eq 'text') { [ordered]@{ type = 'clickText'; text = $Value } } else { [ordered]@{ type = 'click'; selector = $Value } } }
        'scroll' { $candidate['scroll'] = if ($Kind -eq 'page') { [ordered]@{ mode = 'page' } } else { [ordered]@{ mode = 'area'; selector = $Value } } }
        'waitFor' { $candidate['selector'] = $Value }
    }
    return $candidate
}

function Get-ElementPickCandidate {
    <#
        The picker's proposals turned into what may be recorded, in the order of
        preference (words, test id, stable id, label/name/hint, layout path): each kept
        only when Test-ElementPickProposal proves the engine replays it onto the picked
        element. At most one text and three candidates; generated-looking ids are never
        offered, nor paths anchored on them. Proposal values are page data: only strings
        of a sane length are even tried. Returns { Candidates; TimedOut } - TimedOut when
        -DeadlineSec ran out before every proposal was checked.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('click', 'scroll', 'waitFor')][string]$Mode,
        [Parameter(Mandatory)][string]$Token,
        [AllowNull()][object[]]$Proposals,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Element,
        # One limit for the whole check: a page that answers slowly must not hold the
        # Designer for proposals x checks x their own timeouts.
        [double]$DeadlineSec = 10
    )
    $list = [System.Collections.Generic.List[object]]::new()
    $values = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $haveText = $false
    $deadline = (Get-Date).AddSeconds($DeadlineSec)
    $timedOut = $false
    foreach ($proposal in @($Proposals) | Select-Object -First 16) {
        if ($list.Count -ge 3) { break }
        $left = ($deadline - (Get-Date)).TotalSeconds
        if ($left -le 0) { $timedOut = $true; break }
        $kind = [string](Get-DesignerValue -Object $proposal -Name 'kind')
        $value = Get-DesignerValue -Object $proposal -Name 'value'
        if ($kind -notin 'text', 'testid', 'id', 'attribute', 'path', 'page') { continue }
        if ($value -isnot [string] -or $value.Length -gt 300) { continue }
        if ($kind -ne 'page' -and -not $value.Trim()) { continue }
        if ($kind -eq 'text' -and $haveText) { continue }
        if ($values.Contains("$kind|$value")) { continue }
        $attr = ConvertTo-DesignerText -Value (Get-DesignerValue -Object $proposal -Name 'attr') -Max 40
        $attrValue = ConvertTo-DesignerText -Value (Get-DesignerValue -Object $proposal -Name 'attrValue') -Max 120
        if ($kind -eq 'id' -and (Test-DesignerGeneratedId -Id $attrValue)) { continue }
        $anchor = Get-DesignerValue -Object $proposal -Name 'anchorId'
        if ($kind -eq 'path' -and $anchor -is [string] -and $anchor -and (Test-DesignerGeneratedId -Id $anchor)) { continue }
        $check = Test-ElementPickProposal -Mode $Mode -Kind $kind -Value $value -Token $Token -ScrollKind ([string]$Element['kind']) -TimeoutSec ([int][Math]::Ceiling($left))
        if ((Get-Date) -ge $deadline) { $timedOut = $true }
        if (-not $check.Ok) { if ($timedOut) { break }; continue }
        if ($kind -eq 'text') { $haveText = $true }
        [void]$values.Add("$kind|$value")
        $list.Add((New-ElementPickCandidate -Mode $Mode -Kind $kind -Value $value -Exact $check.Exact -Attr $attr -AttrValue $attrValue -Element $Element))
        if ($timedOut) { break }
    }
    return [pscustomobject]@{ Candidates = $list; TimedOut = $timedOut }
}

function ConvertTo-ElementPickInfo {
    # What the picker says about the picked element, reduced to capped strings and known words.
    param([AllowNull()][object]$Info, [Parameter(Mandatory)][string]$Mode)
    $nouns = 'link', 'button', 'tab', 'menu item', 'checkbox', 'choice', 'field', 'list', 'table', 'picture', 'frame', 'element', 'area', 'page'
    $noun = [string](Get-DesignerValue -Object $Info -Name 'noun')
    if ($noun -notin $nouns) { $noun = 'element' }
    $kind = [string](Get-DesignerValue -Object $Info -Name 'kind')
    if ($kind -notin 'element', 'frame', 'window') { $kind = 'element' }
    $climbed = ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Info -Name 'climbedFrom') -Max 20
    $element = [ordered]@{
        kind        = $kind
        tag         = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Info -Name 'tag') -Max 20)
        id          = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Info -Name 'id') -Max 120)
        noun        = $noun
        text        = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Info -Name 'text') -Max 120)
        frame       = (ConvertTo-DesignerText -Value (Get-DesignerValue -Object $Info -Name 'frame') -Max 200)
        climbedFrom = $climbed
        climbedNote = ''
    }
    if ($climbed -and $Mode -eq 'click') {
        $part = if ($climbed -in 'svg', 'path', 'use', 'g', 'circle', 'rect', 'line', 'polyline', 'polygon', 'i') { 'an icon inside it' }
        elseif ($climbed -eq 'img') { 'a picture inside it' } else { "a part of it (a $climbed element)" }
        $element['climbedNote'] = "You pointed at $part; Vouch records the whole $noun, which is what the page responds to."
    }
    return $element
}

function Start-ElementPick {
    <#
        Starts a pick in the attached tab: injects the picker, makes the tab the one Edge
        shows, brings Edge to the front maximised (Show-DesignerAuditWindow) and returns
        at once. The person's click is collected later by Update-ElementPick, from the
        loop, with short evaluations - the server never waits for the person.
    #>
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][ValidateSet('click', 'scroll', 'waitFor')][string]$Mode)
    if ($State.Pick.State -eq 'picking') { Stop-ElementPick -State $State -Message 'A new pick replaced this one.' -NoLayout }
    $pick = New-DesignerPickState
    $pick.Mode = $Mode
    $pick.Token = (New-DesignerToken).Substring(0, 22)
    $pick.TabId = $State.Browser.TabId
    $pick.StartedAt = Get-Date
    $pick.LastPoll = Get-Date
    $State.Pick = $pick
    try {
        [void](Invoke-CdpEval -Expression (Get-DesignerPickerScript -State $State -Mode $Mode -Token $pick.Token) -TimeoutSec 10)
    }
    catch {
        $pick.State = 'error'
        $pick.Code = 'inject'
        $pick.Message = "Picking could not start in this page: $($_.Exception.Message)"
        return $pick
    }
    $pick.State = 'picking'
    Add-ElementPickShield -Pick $pick
    try { [void](Send-CdpCommand -Method 'Page.bringToFront' -TimeoutSec 5) } catch { Write-Verbose "Page.bringToFront: $($_.Exception.Message)" }
    Show-DesignerAuditWindow -State $State
    return $pick
}

function Close-ElementPick {
    <#
        Ends a pick: the shield for new pages is taken back, the picker removes everything
        it put into the page, the result is kept for the panel, and the windows go back
        side by side with the panel in front.
    #>
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][ValidateSet('done', 'cancelled', 'error')][string]$Outcome,
        [AllowEmptyString()][string]$Code = '',
        [AllowEmptyString()][string]$Message = '',
        [AllowNull()][object]$Result = $null,
        [switch]$NoLayout
    )
    $pick = $State.Pick
    if ($State.Browser.Connected) {
        Remove-ElementPickShield -Pick $pick
        try { [void](Invoke-CdpEval -Expression '(window.__vouchPicker && typeof window.__vouchPicker.stop === "function") ? window.__vouchPicker.stop() : false' -TimeoutSec 3) }
        catch { Write-Verbose "The picker could not be removed from the page: $($_.Exception.Message)" }
    }
    $pick.State = $Outcome
    $pick.Code = $Code
    $pick.Message = $Message
    $pick.Result = $Result
    if (-not $NoLayout) { [void](Set-DesignerLayout -State $State -Focus panel) }
}

function Stop-ElementPick {
    # Cancels the pick in progress (the panel's Cancel, a new pick, a navigation, the end of the Designer).
    param([Parameter(Mandatory)][object]$State, [AllowEmptyString()][string]$Message = 'Picking was cancelled.', [switch]$NoLayout)
    if ($State.Pick.State -ne 'picking') { return }
    Close-ElementPick -State $State -Outcome cancelled -Code 'stopped' -Message $Message -NoLayout:$NoLayout
}

function Complete-ElementPick {
    <#
        The person clicked: reads what the picker proposes, has the engine prove each
        proposal (Get-ElementPickCandidate), puts back the scroll positions the engine's
        checks moved, and ends the pick with the candidates - or with a plain reason why
        nothing can be recorded.
    #>
    param([Parameter(Mandatory)][object]$State)
    $pick = $State.Pick
    $info = $null
    $proposals = @()
    try {
        $info = Invoke-CdpEval -Expression 'window.__vouchPicker.info()' -TimeoutSec 5
        $proposals = @(Invoke-CdpEval -Expression 'window.__vouchPicker.proposals()' -TimeoutSec 5)
    }
    catch {
        Close-ElementPick -State $State -Outcome error -Code 'read' -Message "What you picked could not be read from the page: $($_.Exception.Message)"
        return
    }
    $element = ConvertTo-ElementPickInfo -Info $info -Mode $pick.Mode
    if ($pick.Mode -ne 'scroll' -and (Test-DesignerShadowHost)) {
        Close-ElementPick -State $State -Outcome error -Code 'shadow' -Message 'This cannot be recorded: it is inside a page component (shadow DOM) that Vouch cannot look into, so a run could not find it. Pick something outside it, or use a wait instead.'
        return
    }
    $checked = Get-ElementPickCandidate -Mode $pick.Mode -Token $pick.Token -Proposals $proposals -Element $element
    $candidates = $checked.Candidates
    try { [void](Invoke-CdpEval -Expression '(window.__vouchPicker && typeof window.__vouchPicker.restore === "function") ? window.__vouchPicker.restore() : false' -TimeoutSec 5) }
    catch { Write-Verbose "Scroll positions not restored: $($_.Exception.Message)" }
    if ($candidates.Count -eq 0 -and $checked.TimedOut) {
        Close-ElementPick -State $State -Outcome error -Code 'slow' -Message 'The page stopped answering while Vouch checked what you picked. Wait until the page has settled, then pick again.'
        return
    }
    if ($candidates.Count -eq 0) {
        $what = switch ($pick.Mode) { 'scroll' { 'scroll this area' } 'waitFor' { 'find this element' } default { 'click this' } }
        Close-ElementPick -State $State -Outcome error -Code 'nocandidate' -Message "Vouch found no way to $what that it can replay exactly. Pick another part of it, or type a selector yourself."
        return
    }
    $result = [ordered]@{
        mode       = $pick.Mode
        element    = $element
        candidates = $candidates.ToArray()
        url        = $State.Browser.Url
        title      = $State.Browser.Title
        note       = $(if ($checked.TimedOut) { 'The page answered slowly, so Vouch stopped checking after these; each one shown was checked.' } else { '' })
    }
    Close-ElementPick -State $State -Outcome done -Result $result
}

function Update-ElementPick {
    <#
        One look at the pick in progress (from the loop, at most every 200 ms): a short
        evaluation reads the picker's state. A page that navigated or reloaded lost the
        picker and gets it again; a closed tab or a gone Edge ends the pick with a
        message; a click is checked and turned into candidates (Complete-ElementPick).
    #>
    param([Parameter(Mandatory)][object]$State, [switch]$Force)
    $pick = $State.Pick
    if ($pick.State -ne 'picking') { return }
    if (-not $Force -and ((Get-Date) - $pick.LastPoll).TotalMilliseconds -lt 200) { return }
    $pick.LastPoll = Get-Date
    if (-not $State.Browser.Connected) {
        Close-ElementPick -State $State -Outcome error -Code 'browser' -Message 'Picking stopped: the browser is not connected.'
        return
    }
    $status = $null
    try {
        $status = Invoke-CdpEval -Expression '(window.__vouchPicker && typeof window.__vouchPicker.status === "function") ? window.__vouchPicker.status() : null' -TimeoutSec 3
        $pick.Failures = 0
    }
    catch {
        $pick.Failures++
        $tabs = $null
        try { $tabs = Get-DesignerWebTab -State $State -Targets @(Get-DevToolsTargetList -Port $State.Browser.Port) }
        catch {
            Disconnect-DesignerBrowser -State $State -Code 'gone'
            Close-ElementPick -State $State -Outcome error -Code 'browser' -Message 'Picking stopped: the audit Edge window was closed.'
            return
        }
        $still = @($tabs | Where-Object { [string](Get-DesignerValue -Object $_ -Name 'id') -eq $pick.TabId }).Count -gt 0
        if (-not $still -or $pick.Failures -ge 3) {
            $State.Browser.LastCheck = [datetime]::MinValue
            $pick.State = 'error'
            $pick.Code = 'tab'
            $pick.Message = if ($still) { 'Picking stopped: the tab stopped answering. Pick again.' } else { 'Picking stopped: the tab you were picking in was closed.' }
            if ($still) { Remove-ElementPickShield -Pick $pick -TimeoutSec 1 }
            [void](Set-DesignerLayout -State $State -Focus panel)
            Update-DesignerBrowser -State $State -Force
        }
        return
    }
    if ($null -eq $status) {
        # The page navigated or reloaded and took the picker with it: put it back.
        $pick.Reinjects++
        if ($pick.Reinjects -gt 20) {
            Close-ElementPick -State $State -Outcome error -Code 'navigated' -Message 'Picking stopped: the page kept changing. Wait until it has loaded, then pick again.'
            return
        }
        try {
            [void](Invoke-CdpEval -Expression (Get-DesignerPickerScript -State $State -Mode $pick.Mode -Token $pick.Token) -TimeoutSec 5)
            $pick.Notice = 'The page changed while you were picking; picking goes on in the new page.'
        }
        catch { Write-Verbose "The picker could not be put back yet (the page may still be loading): $($_.Exception.Message)" }
        return
    }
    $phase = [string](Get-DesignerValue -Object $status -Name 'phase')
    $code = [string](Get-DesignerValue -Object $status -Name 'code')
    switch ($phase) {
        'picking' {
            # A short note while picking goes on (the page changed, or the click landed on
            # something above the picking layer): known codes only, words from here.
            # It follows the page: when the picker's note clears, so does this one.
            $pick.PageNote = Get-DesignerPickNote -Code ([string](Get-DesignerValue -Object $status -Name 'note'))
            return
        }
        'picked' { Complete-ElementPick -State $State }
        'cancelled' { Close-ElementPick -State $State -Outcome cancelled -Code 'esc' -Message 'You cancelled picking in the browser (Esc).' }
        'blocked' {
            switch ($code) {
                'crossorigin' { $message = 'This cannot be recorded: it is inside a frame from another site, which Vouch cannot look into or click in. Open that frame''s address as a page of its own, or pick something outside the frame.' }
                'transformed' { $message = 'This cannot be recorded by pointing: it is inside a frame the page shows scaled or turned, so Vouch cannot tell exactly what you point at. Pick something outside it, or type a selector in the Designer.' }
                default { $code = 'shadow'; $message = 'This cannot be recorded: it is inside a page component (shadow DOM) that Vouch cannot look into, so a run could not find it. Pick something outside it, or use a wait instead.' }
            }
            Close-ElementPick -State $State -Outcome error -Code $code -Message $message
        }
        'error' {
            switch ($code) {
                'focus' { Close-ElementPick -State $State -Outcome error -Code 'focus' -Message 'Picking stopped: the keyboard focus stayed inside a frame from another site, where Vouch cannot keep keys from acting on the page. Click outside that frame in Edge, then pick again.' }
                'typing' { Close-ElementPick -State $State -Outcome error -Code 'typing' -Message 'Picking stopped: a field in the page started to change. Typing reached it (for example from an input method, the emoji panel, clipboard history or voice typing), or the page filled it in itself. Vouch cannot hold that back, so it stopped rather than go on. Check the field in the page, then click Pick again or type the words in the Designer.' }
                'coverage' { Close-ElementPick -State $State -Outcome error -Code 'coverage' -Message 'Picking stopped: this page is built in a way that lets clicks past the picking layer (for example it replaces or transforms the whole page), so picking could not go on safely. Type the words or selector in the Designer instead.' }
                default { Close-ElementPick -State $State -Outcome error -Code 'picker' -Message 'Picking stopped unexpectedly in the page. Pick again.' }
            }
        }
        default { Close-ElementPick -State $State -Outcome error -Code 'picker' -Message 'Picking stopped unexpectedly in the page. Pick again.' }
    }
}

function Get-ElementPickResult {
    <#
        GET /api/pick: the pick's state - picking (with the words to show), done (with the
        verified candidates), cancelled or error (with a plain reason). Looks at the page
        first, so the answer is current.
    #>
    param([Parameter(Mandatory)][object]$State)
    Update-ElementPick -State $State
    $pick = $State.Pick
    $data = [ordered]@{ state = $pick.State; mode = $pick.Mode }
    switch ($pick.State) {
        'picking' { $data['message'] = 'Waiting for you to click in the browser… (Esc there cancels.)'; $data['notice'] = $(if ($pick.PageNote) { $pick.PageNote } else { $pick.Notice }) }
        'done' { $data['result'] = $pick.Result }
        'cancelled' { $data['message'] = $pick.Message; $data['code'] = $pick.Code }
        'error' { $data['message'] = $pick.Message; $data['code'] = $pick.Code }
    }
    return $data
}

function Invoke-DesignerPickStart {
    # POST /api/pick/start {mode: click|scroll|waitFor}.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)][object]$State)
    $mode = Get-DesignerBodyText -Body $Body -Name 'mode'
    if ($mode -cnotin 'click', 'scroll', 'waitFor') {
        return New-DesignerError -Status 400 -Code 'mode' -Message 'This kind of pick does not exist.' -Detail 'mode must be click, scroll or waitFor.'
    }
    Update-DesignerBrowser -State $State -Force
    $refusal = Get-DesignerBrowserRefusal -State $State
    if ($null -ne $refusal) { return $refusal }
    $pick = Start-ElementPick -State $State -Mode $mode
    if ($pick.State -eq 'error') {
        return New-DesignerError -Status 502 -Code 'pick' -Message 'Picking could not start in this page.' -Detail $pick.Message
    }
    return New-DesignerJsonResponse -Data (Get-ElementPickResult -State $State)
}

function Invoke-DesignerPickCancel {
    # POST /api/pick/cancel: the panel's Cancel.
    param([Parameter(Mandatory)][object]$State)
    Stop-ElementPick -State $State -Message 'You cancelled picking.'
    return New-DesignerJsonResponse -Data (Get-ElementPickResult -State $State)
}

#endregion

#region Listener and loop -------------------------------------------------------------

function Get-DesignerFreePort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return $probe.LocalEndpoint.Port } finally { $probe.Stop() }
}

function Start-DesignerListener {
    <#
        An HttpListener on http://localhost:<port>/ only. The localhost prefix needs no
        administrator rights, and http.sys itself refuses requests addressed to any other
        host name (spike 6). Port 0 picks a free one; a port taken between the check and
        the start is retried.
    #>
    param([int]$Port = 0)
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $candidate = if ($Port -gt 0) { $Port } else { Get-DesignerFreePort }
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$candidate/")
        try {
            $listener.Start()
            return [pscustomobject]@{ Listener = $listener; Port = $candidate }
        }
        catch {
            $listener.Close()
            if ($Port -gt 0) { throw "The Designer cannot use port $Port ($($_.Exception.Message)). Leave out -DesignerPort to use a free one." }
        }
    }
    throw 'The Designer could not find a free local port to listen on.'
}

function Read-DesignerRequestBody {
    <#
        Reads a request body up to the limit and no further: one byte past it and the
        reading stops (TooLarge). Called only after the header checks passed, so only
        the panel itself can make the server read anything.
        The whole body must arrive within -TimeoutMs (TimedOut otherwise): the server
        handles one request at a time, and a sender that sends its headers and then
        stalls would otherwise hold every other request for http.sys's two minutes. The
        read is asynchronous so the wait can end; the stream is abandoned, not read on.
    #>
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Limit,
        [int]$TimeoutMs = 5000
    )
    $memory = [System.IO.MemoryStream]::new()
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    try {
        $buffer = [byte[]]::new(65536)
        while ($true) {
            $left = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalMilliseconds)
            if ($left -le 0) { return [pscustomobject]@{ Text = ''; TooLarge = $false; TimedOut = $true } }
            $task = $Stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $task.Wait($left)) { return [pscustomobject]@{ Text = ''; TooLarge = $false; TimedOut = $true } }
            $read = $task.Result
            if ($read -le 0) { break }
            $memory.Write($buffer, 0, $read)
            if ($memory.Length -gt $Limit) { return [pscustomobject]@{ Text = ''; TooLarge = $true; TimedOut = $false } }
        }
        return [pscustomobject]@{ Text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray()); TooLarge = $false; TimedOut = $false }
    }
    finally { $memory.Dispose() }
}

function Invoke-DesignerExchange {
    <#
        One request from arrival to answer, without the socket: header checks first
        (Host, Origin, Sec-Fetch-Site, method, token, content type, declared length),
        then the body - read only now, up to the limit - then the body checks, then the
        router. The tests drive it with a stream that fails if anything reads it.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.IDictionary]$Headers = @{},
        [long]$ContentLength = -1,
        [AllowNull()][System.IO.Stream]$BodyStream = $null,
        [Parameter(Mandatory)][object]$State,
        [AllowEmptyString()][string]$Query = ''
    )
    $head = New-DesignerRequest -Method $Method -Path $Path -Headers $Headers -ContentLength $ContentLength
    $refusal = Test-DesignerRequestHeader -Request $head -State $State
    if ($null -ne $refusal) { return $refusal }
    $body = [pscustomobject]@{ Text = ''; TooLarge = $false; TimedOut = $false }
    if ($head.Method -eq 'POST' -and $null -ne $BodyStream) {
        $body = Read-DesignerRequestBody -Stream $BodyStream -Limit $State.MaxBodyBytes -TimeoutMs $State.BodyTimeoutMs
        if ($body.TimedOut) {
            return New-DesignerError -Status 408 -Code 'timeout' -Message 'The request did not arrive in time.' -Detail "Its content did not arrive within $([int]($State.BodyTimeoutMs / 1000)) seconds, so the Designer stopped waiting for it."
        }
    }
    $request = New-DesignerRequest -Method $Method -Path $Path -Headers $Headers -ContentLength $ContentLength -BodyText $body.Text -BodyTooLarge:$body.TooLarge
    $refusal = Test-DesignerRequestBody -Request $request -State $State
    if ($null -ne $refusal) { return $refusal }
    return Invoke-DesignerRequest -Method $request.Method -Path $request.Path -Body $request.Body -State $State -Query $Query
}

function Invoke-DesignerContext {
    # One request from the listener: Invoke-DesignerExchange, then send. Nothing here may stop the loop.
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context, [Parameter(Mandatory)][object]$State)
    try {
        $request = $Context.Request
        $headers = @{}
        foreach ($name in $request.Headers.AllKeys) { if ($name) { $headers[$name] = $request.Headers[$name] } }
        $length = if ($request.HasEntityBody) { $request.ContentLength64 } else { 0 }
        $stream = if ($request.HasEntityBody) { $request.InputStream } else { $null }
        $response = Invoke-DesignerExchange -Method $request.HttpMethod -Path $request.Url.AbsolutePath -Headers $headers -ContentLength $length -BodyStream $stream -State $State -Query ([string]$request.Url.Query)
    }
    catch {
        $response = New-DesignerError -Status 500 -Code 'failed' -Message 'Something went wrong in the Designer.' -Detail ([string]$_.Exception.Message)
    }
    Send-DesignerResponse -Context $Context -Response $response
}

function Invoke-DesignerTick {
    <#
        Runs between requests, about every 200 ms: notices the panel window closing and
        calls the tick handlers later steps register (browser link, runs).
    #>
    param([Parameter(Mandatory)][object]$State)
    $panel = $State.PanelProcess
    if ($null -ne $panel) {
        # Cannot tell counts as closed, as before: the server must not outlive its window.
        $gone = Test-DesignerProcessExited -Process $panel -StartTime $State.PanelProcessStart -Unknown $true
        if ($gone) {
            # A launcher that handed over to another Edge exits at once; look for the browser.
            $replacement = $null
            if (((Get-Date) - $State.PanelStartedAt).TotalSeconds -lt 10 -and $State.PanelProfileDir) {
                $replacement = Find-EdgeBrowserProcess -ProfileDir $State.PanelProfileDir
            }
            if ($null -ne $replacement -and $replacement.Id -ne $panel.Id) {
                $State.PanelProcess = $replacement
                $State.PanelProcessStart = Get-DesignerProcessStartTime -Process $replacement
            }
            else {
                $State.PanelProcess = $null
                $State.Running = $false
                $State.StopReason = 'The Designer window was closed.'
            }
        }
    }
    foreach ($handler in @($State.TickHandlers)) {
        try { & $handler $State }
        catch { Write-Verbose "A Designer tick handler failed: $($_.Exception.Message)" }
    }
}

function Invoke-DesignerLoop {
    <#
        The single-threaded server loop. GetContextAsync().Wait(200) instead of the
        blocking GetContext(): the blocking call ignores Ctrl+C until the next request
        arrives (spike 6), and the 200 ms turns give the tick handlers their chance.
    #>
    param([Parameter(Mandatory)][System.Net.HttpListener]$Listener, [Parameter(Mandatory)][object]$State)
    $pending = $Listener.GetContextAsync()
    while ($State.Running) {
        $ready = $false
        try { $ready = $pending.Wait(200) }
        catch {
            if (-not $Listener.IsListening) { break }
            $pending = $Listener.GetContextAsync()
            continue
        }
        if ($ready) {
            $context = $pending.Result
            $pending = $Listener.GetContextAsync()
            Invoke-DesignerContext -Context $context -State $State
        }
        Invoke-DesignerTick -State $State
    }
}

function Start-VouchDesigner {
    <#
        The Designer's entry point (vouch.ps1 -Designer): starts the listener, opens the
        panel window and serves until the panel closes, /api/shutdown, or Ctrl+C. The
        listener and the panel are always closed on the way out.
        -NoPanel and -ReadyFile are for tests and for programs that start the Designer:
        no window, and a JSON file { port, token, url, pid } once the server listens.
        The audit Edge is connected at the first loop turn, so the panel loads at once and
        shows "Connecting"; -NoBrowser leaves it unconnected until Retry, -NoBrowserLaunch
        only ever attaches to an Edge already listening (both plumbing for tests). On the
        way out the audit Edge is closed only if the Designer started it.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyString()][string]$ConfigPath = '',
        [int]$Port = 0,
        [AllowEmptyString()][string]$Version = '',
        [switch]$NoPanel,
        [string]$ReadyFile = '',
        [string]$PanelProfileDir = (Get-DesignerPanelProfile),
        # A typed -EdgeProfileDir; otherwise the configuration's or the default.
        [AllowEmptyString()][string]$AuditProfileDir = '',
        # A typed -DebugPort (0: the configuration's, else 9222) and -KeepBrowserOpen.
        [int]$DebugPort = 0,
        [switch]$KeepBrowserOpen,
        [switch]$NoBrowser,
        [switch]$NoBrowserLaunch,
        # Tests only: the script a run starts instead of vouch.ps1, and a file that
        # records what /api/open would open instead of opening it.
        [string]$RunScriptPath = '',
        [string]$OpenLog = ''
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $designerFolder = Join-Path -Path (Split-Path -Path ([System.IO.Path]::GetFullPath($ScriptPath)) -Parent) -ChildPath 'designer'
    # A second Designer with a window stops here, before it opens or changes anything.
    $instance = if ($NoPanel) { $null } else { Enter-DesignerInstance -PanelProfile $PanelProfileDir }
    $panelLaunchedAt = [datetime]::MinValue
    try { $started = Start-DesignerListener -Port $Port }
    catch { Exit-DesignerInstance -Instance $instance; throw }
    $listener = $started.Listener
    $state = $null
    try {
        $state = New-DesignerState -ScriptPath $ScriptPath -Port $started.Port -Version $Version -DesignerDirectory $designerFolder
        if ($ConfigPath) {
            $full = Resolve-DesignerPath -Path $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
            if ($full -and [System.IO.File]::Exists($full)) { $state.StartupPath = Add-DesignerKnownPath -State $state -Path $full -Kind config }
            else { Write-Host "NOTE: '$ConfigPath' was not found; the Designer starts with a new configuration." -ForegroundColor Yellow }
        }
        $state.PanelProfileDir = $PanelProfileDir
        Assert-DesignerProfileSeparate -State $state -AuditProfile (Get-DesignerAuditProfile -EdgeProfileDir $AuditProfileDir -ConfigPath $state.StartupPath)
        $state.ConfigPath = $state.StartupPath
        $state.Browser.TypedPort = $DebugPort
        $state.Browser.TypedProfileDir = $AuditProfileDir
        $state.Browser.TypedKeepOpen = [bool]$KeepBrowserOpen
        $state.Browser.AllowLaunch = -not $NoBrowserLaunch
        $state.Browser.ConnectPending = -not $NoBrowser
        $state.TickHandlers.Add({ param($s) Invoke-DesignerBrowserTick -State $s })
        $state.TickHandlers.Add({ param($s) Invoke-DesignerRunTick -State $s })
        # Temporary folders of Designers that were killed (their owner is gone) go now.
        try { [void](Clear-DesignerStaleSession) } catch { Write-Verbose "Old Designer folders were not checked: $($_.Exception.Message)" }
        if ($RunScriptPath) { $state.RunScriptPath = [System.IO.Path]::GetFullPath($RunScriptPath) }
        $state.OpenLog = $OpenLog
        $url = "http://localhost:$($state.Port)/?t=$($state.Token)"
        Write-Host "Vouch Designer $Version is running at http://localhost:$($state.Port)/"
        if ($ReadyFile) {
            $ready = [ordered]@{ port = $state.Port; token = $state.Token; url = $url; pid = $PID } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($ReadyFile, $ready, [System.Text.UTF8Encoding]::new($false))
        }
        if (-not $NoPanel) {
            try {
                $panelLaunchedAt = Get-Date
                $state.PanelProcess = Start-DesignerPanel -Url $url -ProfileDir $PanelProfileDir -AuditProfileDir $state.AuditProfileDir
                $state.PanelStartedAt = Get-Date
                $state.PanelProcessStart = Get-DesignerProcessStartTime -Process $state.PanelProcess
            }
            catch {
                # Another Designer opened its window in the meantime: stop, as at the start.
                if ($_.Exception.Message -eq (Get-DesignerAlreadyOpenMessage)) { throw }
                Write-Host "The Designer window could not be opened: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Open this address in Edge or another browser on this computer instead:`n  $url"
            }
        }
        Write-Host 'Close the Designer window, or press Ctrl+C here, to stop the Designer.'
        Invoke-DesignerLoop -Listener $listener -State $state
        if ($state.StopReason) { Write-Host $state.StopReason }
    }
    finally {
        try { $listener.Stop(); $listener.Close() } catch { Write-Verbose 'The listener was already closed.' }
        if ($null -ne $state) {
            # A run still going is stopped cleanly first (then by force after its grace time).
            try { Stop-DesignerRunForExit -State $state }
            catch { Write-Host "The run could not be stopped: $($_.Exception.Message)" -ForegroundColor Yellow }
            try { Remove-DesignerSessionFolder -State $state } catch { Write-Verbose 'The temporary folder was not removed.' }
        }
        if ($null -ne $state) {
            try { Close-DesignerBrowser -State $state }
            catch { Write-Host "The audit Edge could not be closed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        if ($null -ne $state -and $null -ne $state.PanelProcess) { Stop-DesignerPanel -Process $state.PanelProcess -LaunchedAt $panelLaunchedAt }
        Exit-DesignerInstance -Instance $instance
        Write-Host 'Vouch Designer stopped.'
    }
}

#endregion
