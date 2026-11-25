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
                # Same-origin login redirect: the common shape of an expired session. With
                # ?key=K and the cookie /signin?key=K sets, the real page (a signed-in session).
                $key = [string]$query['key']
                $session = if ($key) { $context.Request.Cookies["session_$key"] } else { $null }
                if ($null -ne $session -and $session.Value -eq '1') {
                    Send-Response $context 200 (Page 'Protected' "<h1 id='secret'>Protected content</h1>")
                }
                else {
                    Send-Response $context 302 '' @{ Location = "$base/login?returnUrl=%2Fprotected" }
                }
            }
            '^/signin$' {
                # What signing in does: a session cookie for /protected?key=K.
                $key = [string]$query['key']
                Send-Response $context 200 (Page 'Signed in' 'signed in') @{ 'Set-Cookie' = "session_$key=1; Path=/" }
            }
            '^/gate$' {
                # Content that needs the person: a placeholder until /gate/open?key=K sets
                # the cookie (the person confirming something), then #content shows.
                $key = [string]$query['key']
                $body = "<p id='placeholder'>Please confirm in the browser</p><div id='content' style='display:none'>Gate content</div>" +
                    "<script>setInterval(function () { if (document.cookie.indexOf('gate_$key=open') >= 0) {" +
                    " document.getElementById('content').style.display = 'block'; document.getElementById('placeholder').style.display = 'none'; } }, 200);</script>"
                Send-Response $context 200 (Page 'Gate' $body)
            }
            '^/gate/open$' {
                $key = [string]$query['key']
                Send-Response $context 200 (Page 'Gate open' 'open') @{ 'Set-Cookie' = "gate_$key=open; Path=/" }
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
            '^/bigpanel$' {
                # The window scrolls, and a panel inside it holds far more content.
                $rows = (1..40 | ForEach-Object { "<div class='row'>Panel row $_</div>" }) -join ''
                $body = "<style>body{margin:0} #panel{height:70vh;overflow-y:auto} .row{height:100px;border-bottom:1px solid #ccc}" +
                    " footer{height:2000px;background:linear-gradient(#fff,#0a0)}</style>" +
                    "<header>Report</header><div id='panel'>$rows</div><footer>Page footer</footer>"
                Send-Response $context 200 (Page 'Big panel' $body)
            }
            '^/delayed$' {
                # #late is in the page from the start but only shown after ms milliseconds,
                # the way applications reveal a grid once its data has arrived.
                $ms = if ($query['ms']) { [int]$query['ms'] } else { 1000 }
                $body = "<h1>Delayed</h1><div id='late' style='display:none'>Arrived</div>" +
                    "<script>setTimeout(function () { document.getElementById('late').style.display = 'block'; }, $ms);</script>"
                Send-Response $context 200 (Page 'Delayed' $body)
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
            '^/signout$' {
                # For "log", the sign-out link is the shortest partial match: only the
                # sign-out guard keeps clicktext away from it.
                $body = "<a href='#' id='signout' onclick=""document.title='SIGNED OUT';return false;"">Log out</a>" +
                    "<button id='logsettings' onclick=""document.title='LOG SETTINGS'"">Change log settings</button>"
                Send-Response $context 200 (Page 'Sign out' $body)
            }
            '^/pickme$' {
                # Everything the Designer's picker must get right. ?x=<port> is the port of the
                # other origin, for the frame from another site. Every element records a hit
                # when clicked; links would leave the page if a click got through the picker.
                $other = if ($query['x']) { [int]$query['x'] } else { 1 }
                $rows = (1..12 | ForEach-Object { "<div>Row $_</div>" }) -join ''
                $body = @"
<style>
body{margin:0;font:15px/1.3 sans-serif} .row{display:flex;gap:10px;align-items:center;padding:4px 8px;min-height:40px}
.panel{width:280px;height:150px;overflow-y:auto;border:1px solid #888;display:inline-block;vertical-align:top}
.panel div{height:50px;border-bottom:1px solid #ddd} #clipbox{width:200px;height:100px;overflow-y:clip;border:1px solid #c00;display:inline-block;vertical-align:top}
iframe{width:260px;height:110px;border:1px solid #888} #spacer{height:2500px;background:linear-gradient(#fff,#ccf)}
</style>
<div class="row" id="navrow">
<a href="/ok" id="reports-a" onclick="return hit('reports-1')">Reports</a>
<a href="/ok" onclick="return hit('reports-2')">Reports</a>
<button id="fav" onclick="hit('fav')"><span class="icon" id="favicon">&#9733;</span> Favourite</button>
<button data-testid="save-settings" onclick="hit('save')">Save settings</button>
<button id="ember4821" onclick="hit('generated')">Archive now</button>
<button aria-label="Close dialog" onclick="hit('close')"><svg width="18" height="18" id="xsvg"><path d="M2 2L16 16M16 2L2 16" stroke="black" stroke-width="2"/></svg></button>
</div>
<div class="row"><div><div><div><div><div><em onclick="hit('deep')">Deep target</em></div></div></div></div></div></div>
<div class="row"><iframe id="sameframe" name="sameframe" src="/pickframe"></iframe><iframe id="otherframe" src="http://localhost:$other/pickframe"></iframe><div id="shadowhost"></div></div>
<div><div class="panel" id="leftpanel">$rows</div> <div class="panel" id="rightpanel">$rows</div> <div id="clipbox"><div style="height:400px">Clipped content</div></div> <div id="hscroll" style="width:200px;overflow-x:auto;display:inline-block;vertical-align:top"><div style="width:1200px;height:60px">Wide content</div></div></div>
<dialog id="dlg"><p>A dialog</p><button id="dlgbtn" onclick="hit('dialog')">Dialog action</button></dialog>
<div popover="manual" id="pop"><button id="popbtn" onclick="hit('popover')">Popover action</button></div>
<div popover id="autopop"><button id="autobtn" onclick="hit('auto')">Menu item</button></div>
<dialog id="dlg2"><p>A second dialog</p><button id="dlg2btn" onclick="hit('dialog2')">Second dialog action</button></dialog>
<div id="trapbox" hidden style="position:fixed;left:400px;top:120px;width:260px;padding:12px;background:#eef;border:2px solid #446;z-index:10"><button id="trapfirst" onclick="hit('trap1')">Trap first</button> <button id="trapsecond" onclick="hit('trap2')">Trap second</button></div>
<form id="lonely" action="/ok" onsubmit="window.__submits++; document.title = 'SUBMITTED'; return false;"><input id="q" name="q" value="find"></form>
<div id="spacer">The rest of a tall page</div>
<script>
window.__hits = []; window.__downs = 0; window.__keys = 0; window.__submits = 0; window.__winHits = [];
// A site that acts in the capture phase on window, registered before any picker: it
// records whenever one of its own controls is the target of a click, mousedown or pointerdown.
['click', 'mousedown', 'pointerdown'].forEach(function (type) {
  window.addEventListener(type, function (e) {
    var t = e.target;
    if (t && t.nodeType === 1 && t.closest && t.closest('a,button,input,em,form,[role]')) { window.__winHits.push(type + ':' + (t.id || t.tagName)); }
  }, true);
});
function hit(n) { window.__hits.push(n); document.title = 'HIT ' + n; return false; }
document.addEventListener('mousedown', function () { window.__downs++; });
document.addEventListener('keydown', function () { window.__keys++; });
window.__keyTargets = []; window.__wheels = [];
window.addEventListener('keydown', function (e) { window.__keyTargets.push(e.target && e.target.tagName); }, true);
window.addEventListener('wheel', function (e) { window.__wheels.push({ ctrl: e.ctrlKey, prevented: e.defaultPrevented }); });
var q = new URLSearchParams(location.search);
if (q.get('dialog') === '1') { document.getElementById('dlg').showModal(); }
if (q.get('popover') === '1') { document.getElementById('pop').showPopover(); }
if (q.get('transform') === '1') { document.documentElement.style.transform = 'translateX(0px)'; }
// A page that opens a modal dialog at the press, or rebuilds what is under the pointer
// between press and release - both from capture listeners on window, before any picker.
if (q.get('openOnDown') === '1') { window.addEventListener('pointerdown', function () { var d = document.getElementById('dlg'); if (!d.open) { d.showModal(); } }, true); }
// A native menu (popover="auto": light-dismissed by a press outside it).
window.__toggles = [];
document.getElementById('autopop').addEventListener('toggle', function (e) { window.__toggles.push(e.newState); });
if (q.get('autopop') === '1') { document.getElementById('autopop').showPopover(); }
// A div-based modal with a synchronous focus trap (as focus-trap libraries do), focused at load.
window.__trapEvents = 0;
if (q.get('trap') === '1') {
  var trap = document.getElementById('trapbox'); trap.hidden = false;
  trap.addEventListener('focusin', function () { window.__trapEvents++; });
  trap.addEventListener('focusout', function (e) { window.__trapEvents++; if (!trap.contains(e.relatedTarget)) { document.getElementById('trapfirst').focus(); } });
  document.getElementById('trapfirst').focus();
}
// A field with blur and change handlers.
window.__blurs = 0; window.__changes = 0;
document.getElementById('q').addEventListener('blur', function () { window.__blurs++; });
document.getElementById('q').addEventListener('change', function () { window.__changes++; });
// Two modal dialogs where the one earlier in the page is opened last (so it is on top).
if (q.get('nested') === '1') { document.getElementById('dlg2').showModal(); document.getElementById('dlg').showModal(); }
// A page whose observer throws out anything added to <html> (it fights the picking layer).
if (q.get('fight') === '1') {
  new MutationObserver(function (list) { list.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType === 1 && n.tagName !== 'BODY' && n.tagName !== 'HEAD' && n.parentNode === document.documentElement) { n.remove(); } }); }); })
    .observe(document.documentElement, { childList: true });
}
if (q.get('swapOnUp') === '1') { window.addEventListener('pointerup', function () { var a = document.getElementById('reports-a'); if (a) { var s = document.createElement('span'); s.id = 'swapped'; s.textContent = 'Swapped'; a.replaceWith(s); } }, true); }
var shadowRoot = document.getElementById('shadowhost').attachShadow({ mode: 'open' });
var shadowButton = document.createElement('button'); shadowButton.id = 'shadowbtn'; shadowButton.textContent = 'Shadow button';
shadowButton.onclick = function () { hit('shadow'); }; shadowRoot.appendChild(shadowButton);
</script>
"@
                Send-Response $context 200 (Page 'Pick me' $body)
            }
            '^/pickframe$' {
                $rows = (1..8 | ForEach-Object { "<div style='height:50px'>Frame row $_</div>" }) -join ''
                $body = "<button id='framebtn' onclick=""document.body.setAttribute('data-clicks', String((+document.body.getAttribute('data-clicks') || 0) + 1)); try { top.__hits.push('frame'); top.document.title = 'HIT frame'; } catch (e) { document.title = 'HIT other frame'; }"">Frame action</button>$rows" +
                    "<script>['click', 'mousedown', 'pointerdown'].forEach(function (type) { window.addEventListener(type, function (e) { var t = e.target;" +
                    " if (t && t.closest && t.closest('button')) { try { top.__winHits.push('frame-' + type + ':' + t.id); } catch (x) { } } }, true); });</script>"
                Send-Response $context 200 (Page 'Pick frame' $body)
            }
            '^/framegeom$' {
                # One frame (?kind=): thick border and padding; or shown scaled, mirrored,
                # turned (180, or 90 on a square), inside a turned box, or only moved.
                $style = switch ([string]$query['kind']) {
                    'scaled' { 'width:300px;height:150px;transform:scale(0.8);transform-origin:0 0' }
                    'mirror' { 'width:300px;height:150px;transform:scaleX(-1)' }
                    'rot180' { 'width:300px;height:150px;transform:rotate(180deg)' }
                    'rot90' { 'width:200px;height:200px;transform:rotate(90deg)' }
                    'ancestor' { 'width:300px;height:150px' }
                    'translate' { 'width:300px;height:150px;transform:translate(40px,30px)' }
                    default { 'width:300px;height:150px;border:6px solid #888;padding:24px' }
                }
                $frame = "<iframe id='geomframe' src='/pickframe' style='$style'></iframe>"
                if ([string]$query['kind'] -eq 'ancestor') { $frame = "<div id='turned' style='display:inline-block;transform:rotate(180deg)'>$frame</div>" }
                Send-Response $context 200 (Page 'Frame geometry' "<div style='margin:20px'>$frame</div>")
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
