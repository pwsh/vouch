<#
    Minimal HTTP server for the Vouch integration tests. Serves canned pages on one or
    more localhost ports (different ports = different origins). Requests are handled
    one at a time, so run the slow route on its own instance.
#>
param(
    # Comma-separated; pwsh -File passes "1,2" as a single string, not an array.
    [Parameter(Mandatory)][string]$Port
)

$listener = [System.Net.HttpListener]::new()
foreach ($p in $Port.Split(',')) { $listener.Prefixes.Add("http://localhost:$([int]$p)/") }
$listener.Start()

function Send-Response {
    param($Context, [int]$Status = 200, [string]$Body = '', [hashtable]$Headers = @{})
    $response = $Context.Response
    $response.StatusCode = $Status
    foreach ($key in $Headers.Keys) { $response.Headers[$key] = $Headers[$key] }
    $response.ContentType = 'text/html; charset=utf-8'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response.ContentLength64 = $bytes.Length
    if ($bytes.Length -gt 0) { $response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $response.Close()
}

function Page([string]$Title, [string]$Body) {
    "<!DOCTYPE html><html><head><title>$Title</title></head><body>$Body</body></html>"
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.AbsolutePath
    $query = $context.Request.QueryString
    $base = "http://localhost:$($context.Request.Url.Port)"
    try {
        switch -Regex ($path) {
            '^/ok$' {
                Send-Response $context 200 (Page 'OK page' '<h1>Everything is fine</h1>')
            }
            '^/tall$' {
                $px = if ($query['px']) { [int]$query['px'] } else { 5000 }
                Send-Response $context 200 (Page 'Tall page' "<div style='height:${px}px;background:linear-gradient(#fff,#00f)'>tall</div>")
            }
            '^/status/(\d+)$' {
                $code = [int]$Matches[1]
                $body = if ($query['empty'] -eq '1') { '' } else { Page "Error $code" "<h1>HTTP $code</h1>" }
                Send-Response $context $code $body
            }
            '^/protected$' {
                # Same-origin login redirect: the common shape of an expired session.
                Send-Response $context 302 '' @{ Location = "$base/login?returnUrl=%2Fprotected" }
            }
            '^/xredirect$' {
                $to = $query['to']
                Send-Response $context 302 '' @{ Location = $to }
            }
            '^/innerscroll$' {
                # App-style layout: the page never scrolls, a panel inside it does.
                $rows = if ($query['rows']) { [int]$query['rows'] } else { 20 }
                $content = (1..$rows | ForEach-Object { "<div class='row'>Inner row $_</div>" }) -join ''
                $body = "<style>html,body{margin:0;height:100%;overflow:hidden} header{height:60px;background:#333;color:#fff}" +
                    " #main{height:calc(100% - 60px);overflow-y:auto} .row{height:100px;border-bottom:1px solid #ccc}</style>" +
                    "<header>Admin console</header><div id='main'>$content</div>"
                Send-Response $context 200 (Page 'Inner scroll' $body)
            }
            '^/tworegions$' {
                $column = (1..20 | ForEach-Object { "<div style='height:100px'>Line $_</div>" }) -join ''
                $body = "<style>html,body{margin:0;height:100%;overflow:hidden} .pane{float:left;width:50%;height:100%;overflow-y:auto}</style>" +
                    "<div class='pane' id='left'>$column</div><div class='pane' id='right'>$column</div>"
                Send-Response $context 200 (Page 'Two regions' $body)
            }
            '^/framepage$' {
                $rows = if ($query['rows']) { [int]$query['rows'] } else { 12 }
                $body = "<style>html,body{margin:0;height:100%;overflow:hidden}</style>" +
                    "<iframe id='content' name='content' src='/framecontent?rows=$rows' style='border:0;width:100%;height:100%'></iframe>"
                Send-Response $context 200 (Page 'Frame page' $body)
            }
            '^/framecontent$' {
                $rows = if ($query['rows']) { [int]$query['rows'] } else { 12 }
                $content = (1..$rows | ForEach-Object { "<div style='height:100px;border-bottom:1px solid #ccc'>Frame row $_</div>" }) -join ''
                $body = "<button id='frame-btn' onclick=""top.document.title='FRAME CLICKED'"">Frame button</button>" +
                    "<a id='frame-next' href='/slowsame?s=2'>Frame next</a>$content"
                Send-Response $context 200 (Page 'Frame content' $body)
            }
            '^/slowsame$' {
                $seconds = if ($query['s']) { [int]$query['s'] } else { 2 }
                Start-Sleep -Seconds $seconds
                Send-Response $context 200 (Page 'Slow same' '<h1>Loaded in the frame</h1>')
            }
            '^/xframe$' {
                $to = [System.Net.WebUtility]::HtmlEncode($query['to'])
                $body = "<style>html,body{margin:0;height:100%;overflow:hidden}</style>" +
                    "<iframe src='$to' style='border:0;width:100%;height:100%'></iframe>"
                Send-Response $context 200 (Page 'Other-site frame' $body)
            }
            '^/links$' {
                $to = [System.Net.WebUtility]::HtmlEncode($query['to'])
                Send-Response $context 200 (Page 'Links' "<a id='go' href='$to'>Go</a>")
            }
            '^/login' {
                Send-Response $context 200 (Page 'Sign in' '<form><input name=u><button>Sign in</button></form>')
            }
            '^/tabs$' {
                $body = @'
<nav>
  <a href="#" id="signout" onclick="document.title='SIGNED OUT';return false;">Log out</a>
  <a href="#" style="display:none" onclick="document.title='HIDDEN Audit Log';return false;">Audit Log</a>
  <a href="#" style="display:none" onclick="document.title='HIDDEN Archive';return false;">Archive</a>
</nav>
<div role="tablist">
  <button role="tab" id="t-general" onclick="document.title='General'">General</button>
  <button role="tab" id="t-audit" onclick="document.title='Audit Log'">Audit Log</button>
  <button role="tab" id="t-logs" onclick="document.title='Logs'">Logs</button>
</div>
<ul><li><a href="#" class="item" onclick="document.title='second';return false;">A</a></li></ul>
'@
                Send-Response $context 200 (Page 'Tabs' $body)
            }
            '^/slow$' {
                $seconds = if ($query['s']) { [int]$query['s'] } else { 10 }
                Start-Sleep -Seconds $seconds
                Send-Response $context 200 (Page 'Slow page' '<h1>finally</h1>')
            }
            default {
                Send-Response $context 404 (Page 'Not found' 'not found')
            }
        }
    }
    catch {
        # The browser may have given up on the request already; nothing left to answer.
        try { $context.Response.Abort() } catch { Write-Verbose 'Response already closed.' }
    }
}
