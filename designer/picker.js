/*
  Vouch Designer picker: runs inside the AUDIT browser's page, never in the panel.

  The server (designer\Designer.ps1, Start-ElementPick) evaluates this file in the page
  through the DevTools connection, wrapped in a closure that also holds the engine's own
  frame helpers (vouchDocs, vouchVisible, vouchFrameName from Get-FrameDocsScript), and
  calls it with a config object { mode, token, texts }. Every value in that object went
  through ConvertTo-JsLiteral.

  The rules it keeps:
  - ONE gesture picks: a trusted primary-button click whose target is the picker's own
    hit layer, and only when the element under the pointer is the same at the press
    (pointerdown) and at the click. Everything else fails safe: it is swallowed and
    picks nothing. A trusted click that does not land on the layer (something the page
    shows above it) is refused with a plain note in the banner.
  - The hit layer is a transparent box over the whole window inside a closed shadow
    root, shown as a manual popover so it sits in the browser's top layer (above modal
    dialogs and popovers that opened before it), placed inside the modal dialog that is
    really on top (everything outside it is inert) and inside the open menu (auto or
    hint popover) that is on top of the browser's popover stack, so a press does not
    light-dismiss the page's menus. Dialogs and menus are looked for in the page and in
    every open shadow root; closed shadow roots cannot be searched. Every refresh checks
    that the layer is still there, on top and covering the whole window; repairs are
    bounded, and what cannot be restored ends the pick.
  - Keys: ONE rule, decided by where the key event goes, never by what kind of control
    has the focus. A key aimed at the picker's own layer never reaches the page, and
    only function keys and Ctrl/Alt/Meta combinations keep their default (the browser's
    own shortcuts). A key aimed anywhere else - the page took the focus - is stopped AND
    prevented, every one. On top of that every beforeinput is cancelled, cut/copy/paste
    never reach the page, and the first sign of typing arriving in the page anyway (a
    composition starting, a trusted input event) ENDS the pick ("typing"). The focus is
    taken once at the start; the page may move it within its own documents (never
    fought over), but a focus in a frame the picker cannot listen in is taken back,
    boundedly, or the pick ends. Esc cancels; scroll keys scroll what lies under the
    pointer, like the wheel. No keyboard picking.
  - It PROPOSES text and selectors. It never decides: the server keeps a proposal only
    when the engine's own find-only scripts, run against this page, resolve it to the
    marked element. There is no second matcher here.
  - Nothing from the page is trusted by the server: it reads plain values (strings and
    numbers) and short codes, caps their length and builds every sentence itself.
  - It has a lifetime of its own: the server asks for its status several times a second
    while the person picks. When nobody has asked for HEARTBEAT_MS (the Designer closed,
    crashed, or gave up on a tab that stopped answering without calling stop()), it
    removes itself, so a page is never left swallowing every click until it is reloaded.
    While the server checks a click it already has (phase "picked"), the limit is
    BUSY_MS: the engine's checks of the proposals take up to ten seconds.
  - stop() removes everything: listeners, timers, the observer, the injected nodes, the
    mark and the single namespaced global window.__vouchPicker.
  - A page that reloads or moves on by itself during a pick takes all this with it. For
    that moment the server has the browser run a small shield at the start of every new
    document (Get-DesignerPickShieldScript in Designer.ps1): it swallows clicks and keys
    until the server has put the picker back, which replaces it (see "previous" below).
*/
(function (cfg) {
  'use strict';
  var NS = '__vouchPicker';
  var MARK = '__vouchPickMark';
  var previous = window[NS];
  if (previous && typeof previous.stop === 'function') { try { previous.stop(); } catch (e) { /* a broken earlier copy */ } }

  var mode = cfg.mode === 'scroll' || cfg.mode === 'waitFor' ? cfg.mode : 'click';
  var texts = cfg.texts || {};
  var INTERACTIVE = 'a[href],button,[role=button],[role=tab],[role=menuitem],[role=link],[role=checkbox],[role=radio],[role=switch],[role=option],input,select,textarea,summary,label';
  // Everything a pointer, a touch or a form could make the site act on.
  var POINTER = ['pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu',
    'touchstart', 'touchend', 'touchcancel', 'dragstart', 'drop', 'submit'];
  var KEYS = ['keydown', 'keypress', 'keyup'];
  var CLIPBOARD = ['cut', 'copy', 'paste'];
  var hadTarget = Object.prototype.hasOwnProperty.call(window, '__vouchTarget');
  var savedTarget = hadTarget ? window.__vouchTarget : undefined;
  var NONE = {};

  var state = { phase: 'picking', code: '', message: '', note: '', picked: null, hover: null, down: NONE, downMoves: 0, saved: null };
  var attached = [];   // { target, type, fn }: every listener added, on windows and on open shadow roots
  var handlers = typeof WeakMap === 'function' ? new WeakMap() : null;   // window -> its listener functions (stable, so adding again is a no-op)
  var timer = 0;
  // The server polls status() every 200 ms while picking (its loop can be held up for a
  // few seconds by a slow request); 5 s without a poll means nobody is coming back.
  var HEARTBEAT_MS = 5000;
  var BUSY_MS = 20000;
  var lastBeat = Date.now();
  function beat() { lastBeat = Date.now(); }
  var observer = null;
  var pointer = { x: window.innerWidth / 2, y: window.innerHeight / 2 };

  // ---------------------------------------------------------------- UI (closed shadow root)
  function css(el, rules) { for (var k in rules) { if (Object.prototype.hasOwnProperty.call(rules, k)) { el.style.setProperty(k, rules[k], 'important'); } } return el; }
  var host = document.createElement('vouch-picker-ui');
  css(host, { all: 'initial', position: 'fixed', left: '0', top: '0', width: '0', height: '0', margin: '0', padding: '0', border: '0',
    'z-index': '2147483647', display: 'block', overflow: 'visible', 'pointer-events': 'none', background: 'transparent' });
  var canPopover = typeof host.showPopover === 'function';
  if (canPopover) { host.popover = 'manual'; }
  var root = host.attachShadow({ mode: 'closed' });
  var outline = css(document.createElement('div'), {
    position: 'fixed', display: 'none', 'box-sizing': 'border-box', border: '2px solid #1f56a6', background: 'rgba(31,86,166,0.12)',
    'border-radius': '3px', 'pointer-events': 'none', 'z-index': '2', margin: '0', padding: '0' });
  var label = css(document.createElement('div'), {
    position: 'fixed', display: 'none', background: '#1f56a6', color: '#ffffff', font: '600 12px/1.4 "Segoe UI", system-ui, sans-serif',
    padding: '1px 6px', 'border-radius': '3px', 'pointer-events': 'none', 'z-index': '3', 'max-width': '60vw', 'white-space': 'nowrap',
    overflow: 'hidden', 'text-overflow': 'ellipsis', margin: '0' });
  var banner = css(document.createElement('div'), {
    position: 'fixed', left: '50%', top: '8px', transform: 'translateX(-50%)', background: '#1c2330', color: '#ffffff',
    font: '14px/1.4 "Segoe UI", system-ui, sans-serif', padding: '8px 14px', 'border-radius': '6px', 'box-shadow': '0 4px 16px rgba(0,0,0,0.3)',
    'pointer-events': 'none', 'z-index': '4', 'max-width': 'min(640px, calc(100vw - 32px))', 'text-align': 'center', margin: '0' });
  var bannerTitle = css(document.createElement('div'), { 'font-weight': '600', margin: '0' });
  var bannerStatus = css(document.createElement('div'), { 'font-size': '13px', color: '#dfe6f2', margin: '2px 0 0' });
  bannerTitle.textContent = texts.banner || 'Click what Vouch should click. Esc to cancel.';
  banner.appendChild(bannerTitle);
  banner.appendChild(bannerStatus);
  var overlayLayer = css(document.createElement('div'), { position: 'fixed', left: '0', top: '0', width: '0', height: '0', 'z-index': '1', margin: '0' });
  /*
    The hit layer: transparent, over the whole window, frames included, so every pointer
    event's target is this picker's own host and no listener of the site - not even one
    registered on window in the capture phase before the picker came - sees a real
    element as the target. What lies beneath is found by hit-testing (hitTest). It also
    holds the keyboard focus (tabIndex -1), so key events target the host too.
  */
  var hitLayer = css(document.createElement('div'), {
    position: 'fixed', left: '0', top: '0', width: '100vw', height: '100vh', 'z-index': '0', margin: '0', padding: '0',
    background: 'transparent', cursor: 'crosshair', 'pointer-events': 'auto', outline: 'none' });
  hitLayer.tabIndex = -1;
  root.appendChild(hitLayer);
  root.appendChild(overlayLayer);
  root.appendChild(outline);
  root.appendChild(label);
  root.appendChild(banner);

  // ---------------------------------------------------------------- the page's trees
  /*
    Where an event really goes: the first node of its path. Read at window, event.target
    is the outermost shadow host when the layer sits inside a component's shadow root
    (the layer goes inside the page's open menu, wherever that is).
  */
  function targetOf(ev) {
    var path = null;
    try { path = typeof ev.composedPath === 'function' ? ev.composedPath() : null; } catch (e) { path = null; }
    return path && path.length ? path[0] : ev.target;
  }
  // The tree the host is in (the page, or a shadow root): hit-tests asked there name the host itself.
  function scopeOf() {
    var r = host.getRootNode ? host.getRootNode() : null;
    return r && r !== host && typeof r.elementsFromPoint === 'function' ? r : document;
  }
  // Up one step in the tree as drawn: out of a slot, a parent, or a shadow root's host.
  function upDrawn(n) { return n.assignedSlot || n.parentNode || n.host || null; }
  function deepContains(a, b) {
    for (var n = b, depth = 0; n && depth < 2000; n = upDrawn(n), depth++) { if (n === a) { return true; } }
    return false;
  }
  // The picker's host, or a component that holds it (what a hit-test in an outer tree names instead).
  function isOurs(e) { return e === host || (!!e && !!e.shadowRoot && deepContains(e, host)); }
  /*
    The page's documents and open shadow roots, found by walking every element (closed
    shadow roots cannot be seen from a page script). "scopes" are the trees of the top
    page (where its dialogs and menus are looked for), "roots" every open shadow root,
    "wins" every window the picker may listen in - frames inside shadow roots included,
    which the engine's own frame list does not look for.
    The walk costs time on a big page, so it is repeated at most every 200 ms and less
    often when it is slow (at most about a twentieth of the time).
  */
  var known = { scopes: [document], roots: [], wins: [window] }, scanDue = 0;
  function walkTree(scope, top, out) {
    var all = scope.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var e = all[i], r = e.shadowRoot;
      if (r && r.querySelectorAll) { out.roots.push(r); if (top) { out.scopes.push(r); } walkTree(r, top, out); }
      if (e.localName === 'iframe' || e.localName === 'frame') {
        var d = null;
        try { d = e.contentDocument; } catch (x) { d = null; }
        if (d && d.documentElement && out.wins.length < 500) { out.wins.push(e.contentWindow); walkTree(d, false, out); }
      }
    }
  }
  function scan(force) {
    var now = Date.now();
    if (!force && now < scanDue) { return; }
    var out = { scopes: [document], roots: [], wins: [window] };
    try { walkTree(document, true, out); } catch (e) { /* a tree changing under the walk: next time */ }
    known = out;
    scanDue = Date.now() + Math.max(200, (Date.now() - now) * 20);
  }

  // ---------------------------------------------------------------- staying on top
  // What lies on top at a point, as the host's own tree names it.
  function topAt(x, y) { return scopeOf().elementFromPoint(x, y); }
  // Whether an element is what lies on top at its own centre (the picker's layer skipped).
  function onTopAtCentre(el) {
    var r = el.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) { return false; }
    var scope = el.getRootNode ? el.getRootNode() : document;
    if (!scope || typeof scope.elementsFromPoint !== 'function') { scope = document; }
    var list = scope.elementsFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    for (var i = 0; i < list.length; i++) {
      if (list[i] === el || deepContains(el, list[i])) { return true; }
      if (isOurs(list[i])) { continue; }
      return false;
    }
    return false;
  }
  /*
    Menus and dialogs the layer could not be drawn in (a component that does not show
    content added to it): left alone from then on, the layer goes one level further out.
  */
  var unusable = typeof WeakSet === 'function' ? new WeakSet() : { has: function () { return false; }, add: function () { } };
  // The open modal dialogs and the open menus (auto and hint popovers) of the top page, shadow roots included.
  function topLayerOwners() {
    var dialogs = [], pops = [];
    known.scopes.forEach(function (scope) {
      if (scope !== document && scope.isConnected === false) { return; }
      var list = [];
      try { list = scope.querySelectorAll('dialog[open],[popover]'); } catch (e) { list = []; }
      for (var i = 0; i < list.length; i++) {
        var el = list[i];
        if (el === host || unusable.has(el)) { continue; }
        try {
          if (el.localName === 'dialog' && el.matches(':modal')) { dialogs.push(el); }
          else if ((el.popover === 'auto' || el.popover === 'hint') && el.matches(':popover-open')) { pops.push(el); }
        }
        catch (e) { /* dialogs or popovers unknown to this browser */ }
      }
    });
    return { dialogs: dialogs, pops: pops };
  }
  /*
    The open modal dialog that is really on top (everything outside it is inert): not the
    last one in the page, but the one whose own centre is not covered - a lower modal is
    covered by the upper one's backdrop. Document order only decides when none can tell.
  */
  function topModal(dialogs) {
    var top = null;
    for (var i = 0; i < dialogs.length; i++) { if (onTopAtCentre(dialogs[i])) { top = dialogs[i]; } }
    return top || (dialogs.length ? dialogs[dialogs.length - 1] : null);
  }
  /*
    The order in which menus opened during this pick (beforetoggle, seen at window
    capture and in every known shadow root): the one opened later is above.
  */
  var opened = typeof WeakMap === 'function' ? new WeakMap() : null, openCount = 0;
  // Whether menu a holds a button that opens menu b (popovertarget, commandfor, interestfor).
  function invokes(a, b) {
    var found = false;
    function look(node) {
      var i, list = node.querySelectorAll('button,input,[commandfor],[interestfor]');
      for (i = 0; i < list.length && !found; i++) {
        var e = list[i];
        try { found = e.popoverTargetElement === b || e.commandForElement === b || e.interestForElement === b; } catch (x) { found = false; }
      }
      var all = node.querySelectorAll('*');
      for (i = 0; i < all.length && !found; i++) { if (all[i].shadowRoot && all[i] !== host) { look(all[i].shadowRoot); } }
    }
    try { look(a); if (!found && a.shadowRoot) { look(a.shadowRoot); } } catch (e) { found = false; }
    return found;
  }
  /*
    Whether menu b is above menu a in the browser's popover stack. Open menus always form
    one chain (showing one closes every menu that is not its ancestor): one seen opening
    later is above; otherwise b is above a when it is inside a, or a holds the button
    that opens b.
  */
  function above(b, a) {
    var hb = b.popover === 'hint', ha = a.popover === 'hint';
    if (hb !== ha) {
      // A hint (tooltip) that belongs to a menu is above it. One that does not cannot be
      // kept together with the menu at all (a press in either closes the other,
      // established in Edge): the menu is kept.
      var hint = hb ? b : a, menu = hb ? a : b, belongs = deepContains(menu, hint) || invokes(menu, hint);
      return hb ? belongs : !belongs;
    }
    var sb = (opened && opened.get(b)) || 0, sa = (opened && opened.get(a)) || 0;
    if (sb !== sa) { return sb > sa; }
    return deepContains(a, b) || invokes(a, b);
  }
  /*
    The open menu on top of the popover stack: a press outside that stack closes every
    menu, and a press inside a lower menu closes the ones above it - and the press
    target is the picker's host. So the host goes inside the top one, which keeps every
    menu open while the person points (established in Edge: cancelling the press does
    not stop the closing, and the site sees its menu close).
    NOT document order: a sub-menu need not be inside its menu, nor come after it. When
    the chain cannot be told from the page (a sub-menu opened by script alone, before
    the pick), the one not covered at its centre wins, then the last found.
  */
  function topPopover(pops, modal) {
    var open = modal ? pops.filter(function (p) { return deepContains(modal, p); }) : pops;
    if (!open.length) { return null; }
    var top = open.filter(function (a) { return !open.some(function (b) { return b !== a && above(b, a); }); });
    if (top.length > 1) { var clear = top.filter(onTopAtCentre); if (clear.length) { top = clear; } }
    if (!top.length) { top = open; }
    return top[top.length - 1];
  }
  /*
    Where the host goes: inside the menu on top, else the modal dialog on top, else the
    page. A menu or dialog that draws its content from an open shadow root gets the host
    there (content added beside it would not be drawn).
  */
  function wantedParent() {
    var owners = topLayerOwners();
    var modal = topModal(owners.dialogs);
    var owner = topPopover(owners.pops, modal) || modal;
    if (!owner) { return document.documentElement; }
    return owner.shadowRoot && owner.shadowRoot.appendChild ? owner.shadowRoot : owner;
  }
  /*
    Only in the page itself must the host be the last child (so nothing added later is
    drawn above it where the top layer is not available). Inside a site's menu or dialog
    its place among the children does not matter: a menu that keeps adding rows must
    not cost a repair each time, nor see its :last-child styles move to the host.
  */
  function misplaced(parent) {
    return host.parentNode !== parent || (parent === document.documentElement && parent.lastElementChild !== host);
  }
  function showOnTop(again) {
    if (!canPopover || !host.isConnected) { return; }
    try {
      if (host.matches(':popover-open')) { if (again && repaired()) { host.hidePopover(); host.showPopover(); } }
      else { host.showPopover(); }
    }
    catch (e) { /* not possible now; coverage checks decide */ }
  }
  function placeHost() {
    var parent = wantedParent();
    if (!parent) { return; }
    if (misplaced(parent)) {
      // The first placement is the picker's own; later ones are the page changing things.
      if (placed && !repaired()) { return; }
      // Moving an element drops its focus: the picker's own focus goes along with its own move.
      var ours = focusOurs();
      try { parent.appendChild(host); }
      catch (e) { unusable.add(parent.host || parent); return; }
      if (placed) { moves++; lastMove = Date.now(); }
      placed = true;
      showOnTop(false);
      if (ours) { park(); }
      return;
    }
    showOnTop(false);
  }
  /*
    Every repair (putting the layer back, moving it, showing it on top again) is counted:
    a page that keeps undoing them (an observer that throws the layer out, a script that
    keeps raising its own pop-up) would otherwise ping-pong with the guard and hang the
    tab. More than 8 repairs in a second end the pick ("coverage"). Returns whether this
    repair may go ahead.
  */
  var repairs = [];
  function repaired() {
    var now = Date.now();
    repairs = repairs.filter(function (t) { return now - t < 1000; });
    repairs.push(now);
    if (repairs.length > 8) { finish('error', 'coverage', ''); return false; }
    return true;
  }
  // How often the layer had to be put back or moved: a move between press and release
  // means the page changed under the pointer.
  var moves = 0, lastMove = 0, placed = false;
  // Whether the layer is what lies on top at a few points of the window.
  function onTopEverywhere() {
    var w = window.innerWidth, h = window.innerHeight, points = [[0.5, 0.5], [0.05, 0.05], [0.95, 0.05], [0.05, 0.95], [0.95, 0.95]];
    for (var i = 0; i < points.length; i++) {
      var e = topAt(w * points[i][0], h * points[i][1]);
      if (e && e !== host) { return false; }
    }
    return true;
  }
  function coversWindow() {
    var r = hitLayer.getBoundingClientRect();
    return r.left <= 0.5 && r.top <= 0.5 && r.right >= window.innerWidth - 0.5 && r.bottom >= window.innerHeight - 0.5;
  }

  // ---------------------------------------------------------------- the keyboard focus
  /*
    The focus is taken ONCE, at the start, so the page's own controls are not focused
    when the person starts. After that the page may keep or move the focus wherever it
    likes in its own document or a same-site frame - every key there is stopped and
    prevented at window capture - and the picker never fights it (focus traps would
    fight back until the stack overflows). Only a focus inside a frame the picker cannot
    listen in matters (a frame from another site, or one hidden in a closed shadow
    root), because keys there never pass the picker: it is taken back out of the event,
    at most 3 times a second, and if it will not stay out the pick ends ("focus").
  */
  // Whether the focus is on the picker's own layer (asked in the host's own tree: a shadow root when it is in one).
  function focusOurs() {
    var r = host.getRootNode ? host.getRootNode() : null;
    return !!r && r !== host && r.activeElement === host;
  }
  function park() {
    if (focusOurs()) { return true; }
    try { hitLayer.focus({ preventScroll: true }); } catch (e) { /* not focusable now */ }
    return focusOurs();
  }
  var takeBacks = [], takeBackTimer = 0;
  function takeBackFocus() {
    if (takeBackTimer || !focusInForeignFrame()) { return; }
    var now = Date.now();
    takeBacks = takeBacks.filter(function (t) { return now - t < 1000; });
    if (takeBacks.length >= 3) { finish('error', 'focus', ''); return; }
    takeBackTimer = setTimeout(function () {
      takeBackTimer = 0;
      if (state.phase !== 'picking' && state.phase !== 'picked') { return; }
      if (!focusInForeignFrame()) { return; }
      takeBacks.push(Date.now());
      park();
    }, 0);
  }
  /*
    Whether the focus is in a frame whose keys never pass the picker. Followed from the
    page's focused element down through open shadow roots and same-site frames: a frame
    whose document cannot be reached is from another site. And when the top window has
    lost the focus to one of its frames (windowBlurred) but the trail ends at an
    ordinary element of the top page, the frame is hidden inside a closed shadow root.
  */
  var windowBlurred = false;
  function focusInForeignFrame() {
    var a = document.activeElement;
    for (var depth = 0; depth < 40 && a; depth++) {
      var inner = a.shadowRoot ? a.shadowRoot.activeElement : null;
      if (inner) { a = inner; continue; }
      if (!/^i?frame$/i.test(a.localName || '')) { return windowBlurred && a.ownerDocument === document && document.hasFocus(); }
      var d = null;
      try { d = a.contentDocument; } catch (e) { d = null; }
      if (!d) { return true; }
      a = d.activeElement;
    }
    return false;
  }
  // The top window lost or got the focus: told apart from the person leaving Edge by document.hasFocus(), a moment later.
  function onWindowFocus(ev) {
    if (ev.target !== window) { return; }
    if (ev.type === 'focus') { windowBlurred = false; return; }
    setTimeout(function () {
      windowBlurred = document.hasFocus() && !focusOurs() && document.activeElement !== document.body;
      if (windowBlurred && (state.phase === 'picking' || state.phase === 'picked')) { takeBackFocus(); }
    }, 0);
  }

  // ---------------------------------------------------------------- geometry
  /*
    Whether an element is drawn without scaling, mirroring or turning: no CSS rotate,
    scale or zoom other than the identity (rotate: 0deg, scale: 1 and zoom: 1 are what
    utility classes and resting transitions leave behind), no motion path (offset-path
    turns an element without any transform), and a transform that is at most a
    translation (which the bounding rect already includes). Anything else would make a
    frame's inside map to other points.
  */
  function allNumbers(text, wanted) {
    var parts = String(text).trim().split(/\s+/);
    for (var i = 0; i < parts.length; i++) { if (parseFloat(parts[i]) !== wanted) { return false; } }
    return parts.length > 0;
  }
  function onlyMoved(el) {
    var cs = el.ownerDocument.defaultView.getComputedStyle(el);
    // rotate computes to an angle, or an axis and an angle: the angle is the last part.
    if (cs.rotate && cs.rotate !== 'none' && parseFloat(String(cs.rotate).trim().split(/\s+/).pop()) !== 0) { return false; }
    if (cs.scale && cs.scale !== 'none' && !allNumbers(cs.scale, 1)) { return false; }
    if (cs.zoom && cs.zoom !== 'normal' && parseFloat(cs.zoom) !== 1) { return false; }
    if (cs.offsetPath && cs.offsetPath !== 'none') { return false; }
    var t = cs.transform;
    if (!t || t === 'none') { return true; }
    var m = /^matrix\(([^)]*)\)$/.exec(t);
    if (m) {
      var v = m[1].split(',').map(parseFloat);
      return v[0] === 1 && v[1] === 0 && v[2] === 0 && v[3] === 1;
    }
    var m3 = /^matrix3d\(([^)]*)\)$/.exec(t);
    if (m3) {
      var w = m3[1].split(',').map(parseFloat), id = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
      for (var i = 0; i < 12; i++) { if (w[i] !== id[i]) { return false; } }
      return w[15] === 1;
    }
    return false;
  }
  // The frame and every element around it, up through the frames to the top page, only moved.
  function mappable(frame) {
    for (var el = frame, depth = 0; el && depth < 200; depth++) {
      if (!onlyMoved(el)) { return false; }
      if (el.parentElement) { el = el.parentElement; continue; }
      var w = el.ownerDocument.defaultView;
      el = null;
      try { el = w.frameElement; } catch (e) { el = null; }
    }
    return true;
  }
  /*
    Where a frame's content starts, in its parent's window: the frame's box plus its
    border and padding. A frame drawn scaled, mirrored or turned - itself or anything
    around it - cannot be mapped exactly, so it gives null and is refused. (Points in
    the documents themselves need no such care: elementsFromPoint is transform-aware.)
  */
  function frameOrigin(frame) {
    var r = frame.getBoundingClientRect();
    if (!mappable(frame)) { return null; }
    if (Math.abs(r.width - frame.offsetWidth) > 1 || Math.abs(r.height - frame.offsetHeight) > 1) { return null; }
    var cs = frame.ownerDocument.defaultView.getComputedStyle(frame);
    return { x: r.left + (parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(cs.paddingLeft) || 0),
      y: r.top + (parseFloat(cs.borderTopWidth) || 0) + (parseFloat(cs.paddingTop) || 0) };
  }
  function frameOffset(entry) {
    var x = 0, y = 0;
    for (var e = entry; e && e.frame; e = e.parent) {
      var o = frameOrigin(e.frame) || { x: e.frame.getBoundingClientRect().left, y: e.frame.getBoundingClientRect().top };
      x += o.x; y += o.y;
    }
    return { x: x, y: y };
  }
  function topRect(el, entry) {
    var r = el.getBoundingClientRect(), off = frameOffset(entry);
    return { left: r.left + off.x, top: r.top + off.y, width: r.width, height: r.height };
  }
  function place(el, r) {
    css(el, { left: Math.round(r.left) + 'px', top: Math.round(r.top) + 'px', width: Math.max(0, Math.round(r.width)) + 'px', height: Math.max(0, Math.round(r.height)) + 'px' });
  }
  function entryForWindow(win) {
    var list = vouchDocs().list;
    for (var i = 0; i < list.length; i++) { if (list[i].win === win) { return list[i]; } }
    return null;
  }

  // ---------------------------------------------------------------- frames from another site
  function refreshOverlays() {
    var docs = vouchDocs();
    while (overlayLayer.firstChild) { overlayLayer.removeChild(overlayLayer.firstChild); }
    docs.blocked.forEach(function (b) {
      var r = b.frame.getBoundingClientRect(), off = frameOffset(b.parent);
      var box = css(document.createElement('div'), {
        position: 'fixed', 'box-sizing': 'border-box', border: '2px dashed #a8201a', 'pointer-events': 'none',
        background: 'repeating-linear-gradient(45deg, rgba(168,32,26,0.06) 0 10px, rgba(168,32,26,0.14) 10px 20px)', margin: '0' });
      place(box, { left: r.left + off.x, top: r.top + off.y, width: r.width, height: r.height });
      overlayLayer.appendChild(box);
    });
    return docs;
  }

  // ---------------------------------------------------------------- what the pointer is on
  function inShadow(node) {
    var rootNode = node && node.getRootNode ? node.getRootNode() : null;
    return !!rootNode && rootNode !== node.ownerDocument && typeof rootNode.host !== 'undefined';
  }
  function upAcrossShadow(node) {
    if (node.parentElement) { return node.parentElement; }
    var rootNode = node.getRootNode ? node.getRootNode() : null;
    return rootNode && rootNode.host ? rootNode.host : null;
  }
  function scrollableHere(n, win, strict) {
    if (n.clientHeight < 50 || n.scrollHeight <= n.clientHeight + 16) { return false; }
    var oy = win.getComputedStyle(n).overflowY;
    return strict ? (oy === 'auto' || oy === 'scroll' || oy === 'overlay') : (oy !== 'visible' && oy !== 'clip');
  }
  function frameScrolls(entry) {
    var fs = entry.doc.scrollingElement || entry.doc.documentElement;
    return !!fs && fs.scrollHeight > entry.win.innerHeight + 16;
  }
  // The area the engine's "area" capture would scroll for a point inside it.
  function findScroller(start, entry) {
    var node = start, e = entry;
    while (e) {
      var loose = null;
      for (var n = node; n && n.nodeType === 1; n = upAcrossShadow(n)) {
        if (n === e.doc.documentElement || n === e.doc.body) { break; }
        var strictHit = scrollableHere(n, e.win, true);
        if (strictHit || (!loose && scrollableHere(n, e.win, false))) {
          if (inShadow(n)) { return { kind: 'shadow' }; }
          if (strictHit) { return { kind: 'element', node: n, entry: e }; }
          loose = n;
        }
      }
      if (loose) { return { kind: 'element', node: loose, entry: e }; }
      if (e.frame) {
        if (frameScrolls(e)) { return { kind: 'frame', node: e.frame, entry: e.parent, inner: e }; }
        node = e.frame; e = e.parent; continue;
      }
      var top = document.scrollingElement || document.documentElement;
      return top.scrollHeight > window.innerHeight + 16 ? { kind: 'window' } : { kind: 'none' };
    }
    return { kind: 'none' };
  }
  /*
    What lies under a point of the top window, beneath the hit layer: elementsFromPoint
    lists the elements there from the top; the picker's host is skipped. A frame from
    the same site is entered at its content origin (frameOrigin); a frame from another
    site, or one shown scaled or turned, is refused. An open shadow root is looked into
    only to be able to say that it cannot be recorded.
    Identification only: what is recorded is still decided by the engine on the server.
  */
  function hitTest(x, y) {
    var doc = document, win = window, ox = 0, oy = 0;
    for (var depth = 0; depth < 12; depth++) {
      // In the top page the question is asked in the host's own tree (a shadow root when
      // the layer sits inside a component's menu), which names the host itself.
      var list = (depth === 0 ? scopeOf() : doc).elementsFromPoint(x - ox, y - oy), found = null;
      for (var i = 0; i < list.length; i++) { if (list[i] !== host) { found = list[i]; break; } }
      if (!found) { return null; }
      // As the page's document sees it: a node inside a component counts as that component.
      var el = found;
      while (inShadow(el)) { el = el.getRootNode().host; }
      if (el !== found) { return { el: el, real: found, win: win, refused: '' }; }
      var tag = el.tagName.toLowerCase();
      if (tag === 'iframe' || tag === 'frame') {
        var inner = null;
        try { inner = el.contentDocument; } catch (e) { inner = null; }
        if (!inner || !inner.documentElement) { return { el: el, win: win, refused: 'crossorigin' }; }
        var origin = frameOrigin(el);
        if (!origin) { return { el: el, win: win, refused: 'transformed' }; }
        ox += origin.x; oy += origin.y;
        doc = inner; win = el.contentWindow;
        continue;
      }
      // Into open shadow roots, to be able to say that what is there cannot be recorded
      // (a component that merely holds the picker's layer is hit as itself).
      var real = el;
      for (var k = 0; k < 12 && real.shadowRoot && real.shadowRoot.elementsFromPoint && !isOurs(real); k++) {
        var sub = real.shadowRoot.elementsFromPoint(x - ox, y - oy), deeper = null;
        for (var j = 0; j < sub.length; j++) {
          if (isOurs(sub[j])) { continue; }
          if (sub[j].getRootNode() === real.shadowRoot) { deeper = sub[j]; }
          break;
        }
        if (!deeper) { break; }
        real = deeper;
      }
      return { el: el, real: real, win: win, refused: '' };
    }
    return null;
  }
  function resolveHit(hit) {
    if (!hit) { return { blocked: 'ours' }; }
    if (hit.refused) { return { blocked: hit.refused, frameName: vouchFrameName(hit.el) }; }
    var entry = entryForWindow(hit.win);
    if (!entry) { return { blocked: 'ours' }; }
    var t = hit.el, real = hit.real;
    if (mode === 'scroll') {
      var s = findScroller(real, entry);
      if (s.kind === 'shadow') { return { blocked: 'shadow' }; }
      return { blocked: '', scroll: s, entry: s.entry || entry, el: s.node || null };
    }
    if (real !== t && inShadow(real)) { return { blocked: 'shadow' }; }
    var el = t, climbedFrom = '';
    if (mode === 'click') {
      var up = t.closest ? t.closest(INTERACTIVE) : null;
      if (up && up !== t) { climbedFrom = t.tagName.toLowerCase(); el = up; }
    }
    return { blocked: '', el: el, entry: entry, climbedFrom: climbedFrom };
  }
  // What a pick would be, for comparing the press with the click.
  function keyOf(info) {
    if (!info) { return NONE; }
    if (info.blocked) { return 'blocked:' + info.blocked; }
    if (mode === 'scroll') { return info.scroll.kind === 'window' ? 'window' : (info.scroll.node || 'none'); }
    return info.el || NONE;
  }
  // Why a click did not land on the layer: what the page shows above it, when it can tell.
  function aboveReason(t) {
    if (!t || t.nodeType !== 1) { return 'uncovered'; }
    var doc = t.ownerDocument;
    if (doc.fullscreenElement && (doc.fullscreenElement === t || doc.fullscreenElement.contains(t))) { return 'uncovered-fullscreen'; }
    var holder = t.closest ? t.closest('dialog[open],[popover]') : null;
    if (holder) { return holder.tagName === 'DIALOG' ? 'uncovered-dialog' : 'uncovered-popup'; }
    return 'uncovered';
  }

  // ---------------------------------------------------------------- words for the outline and the banner
  function labelOf(el) { return String(el.innerText || el.textContent || el.value || '').replace(/\s+/g, ' ').trim(); }
  function nounOf(el) {
    var tag = el.tagName.toLowerCase(), role = (el.getAttribute('role') || '').toLowerCase(), type = (el.getAttribute('type') || '').toLowerCase();
    if (role === 'tab') { return 'tab'; }
    if (role === 'menuitem') { return 'menu item'; }
    if (role === 'button' || tag === 'button' || (tag === 'input' && (type === 'submit' || type === 'button' || type === 'reset'))) { return 'button'; }
    if (role === 'link' || tag === 'a') { return 'link'; }
    if (role === 'checkbox' || type === 'checkbox') { return 'checkbox'; }
    if (role === 'radio' || type === 'radio') { return 'choice'; }
    if (tag === 'input' || tag === 'textarea') { return 'field'; }
    if (tag === 'select') { return 'list'; }
    if (tag === 'table') { return 'table'; }
    if (tag === 'img' || tag === 'svg') { return 'picture'; }
    if (tag === 'iframe' || tag === 'frame') { return 'frame'; }
    return 'element';
  }
  function short(t, n) { t = String(t || ''); return t.length > n ? t.substring(0, n - 1) + '…' : t; }
  function describeHover(info) {
    if (info.blocked === 'crossorigin') { return texts.crossorigin || 'This is a frame from another site.'; }
    if (info.blocked === 'transformed') { return texts.transformed || 'This frame is shown scaled or turned.'; }
    if (info.blocked === 'shadow') { return texts.shadow || 'This is inside a component Vouch cannot look into.'; }
    if (mode === 'scroll') {
      var s = info.scroll;
      if (s.kind === 'window') { return texts.page || 'The whole page'; }
      if (s.kind === 'none') { return texts.nothing || 'Nothing here scrolls.'; }
      return (s.kind === 'frame' ? 'Frame' : 'Scrolling area') + ': ' + short(s.node.id ? '#' + s.node.id : s.node.tagName.toLowerCase(), 40);
    }
    var text = labelOf(info.el);
    return nounOf(info.el) + (text ? ' “' + short(text, 50) + '”' : '') + (info.climbedFrom ? ' (' + (texts.climbed || 'the part you point at belongs to it') + ')' : '');
  }
  function draw() {
    var info = state.phase === 'picked' ? state.picked : state.hover;
    var note = state.phase === 'picking' && state.note ? (texts[state.note] || '') : '';
    if (!info || info.blocked) {
      css(outline, { display: 'none' }); css(label, { display: 'none' });
      var said = info && info.blocked && info.blocked !== 'ours' ? describeHover(info) : (state.phase === 'picked' ? (texts.checking || 'Checking…') : '');
      bannerStatus.textContent = note || said;
      css(banner, { background: (info && info.blocked && info.blocked !== 'ours') || note ? '#a8201a' : '#1c2330' });
      return;
    }
    var r = null;
    if (mode === 'scroll' && info.scroll.kind === 'window') { r = { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight }; }
    else if (mode === 'scroll' && info.scroll.kind === 'none') { r = null; }
    else if (info.el) { r = topRect(info.el, info.entry); }
    css(banner, { background: note ? '#a8201a' : '#1c2330' });
    bannerStatus.textContent = state.phase === 'picked' ? (texts.checking || 'Checking…') : (note || describeHover(info));
    if (!r) { css(outline, { display: 'none' }); css(label, { display: 'none' }); return; }
    place(outline, r);
    css(outline, { display: 'block', 'border-width': mode === 'scroll' ? '3px' : '2px' });
    label.textContent = describeHover(info);
    css(label, { display: 'block', left: Math.round(Math.max(0, r.left)) + 'px', top: Math.round(r.top > 24 ? r.top - 22 : r.top + 2) + 'px' });
    // Keep the banner out of the way of what is being pointed at.
    var bannerBox = banner.getBoundingClientRect();
    if (r.top < bannerBox.bottom + 8 && r.top + r.height > bannerBox.top) { css(banner, { top: 'auto', bottom: '8px' }); }
    else { css(banner, { top: '8px', bottom: 'auto' }); }
  }

  // ---------------------------------------------------------------- scrolling for the person
  /*
    Scrolls what lies under the point by (dx, dy), the way the browser would: the
    nearest panel that can still scroll that way, then the frame's page, then the
    window. Used for the wheel and the scroll keys, which the layer and the parked focus
    would otherwise keep from the page. Returns whether anything scrolled.
  */
  function scrollAt(x, y, dx, dy) {
    var hit = hitTest(x, y);
    var e = hit && !hit.refused ? entryForWindow(hit.win) : entryForWindow(window);
    var node = hit && !hit.refused ? hit.el : null;
    var room = /^(auto|scroll|overlay)$/;
    for (; e; e = e.parent) {
      for (var n = node; n && n.nodeType === 1; n = n.parentElement) {
        if (n === e.doc.documentElement || n === e.doc.body) { break; }
        var cs = e.win.getComputedStyle(n);
        var sx = dx !== 0 && room.test(cs.overflowX) && ((dx > 0 && n.scrollLeft + n.clientWidth < n.scrollWidth - 1) || (dx < 0 && n.scrollLeft > 0));
        var sy = dy !== 0 && room.test(cs.overflowY) && ((dy > 0 && n.scrollTop + n.clientHeight < n.scrollHeight - 1) || (dy < 0 && n.scrollTop > 0));
        if (sx || sy) { n.scrollBy(sx ? dx : 0, sy ? dy : 0); return true; }
      }
      var fs = e.doc.scrollingElement || e.doc.documentElement, w = e.win;
      var wy = dy !== 0 && ((dy > 0 && w.scrollY + w.innerHeight < fs.scrollHeight - 1) || (dy < 0 && w.scrollY > 0));
      var wx = dx !== 0 && ((dx > 0 && w.scrollX + w.innerWidth < fs.scrollWidth - 1) || (dx < 0 && w.scrollX > 0));
      if (wy || wx) { w.scrollBy(wx ? dx : 0, wy ? dy : 0); return true; }
      node = e.frame;
    }
    return false;
  }
  function onWheel(ev) {
    // Ctrl+wheel is the browser's own zoom: left alone.
    if (!ev.isTrusted || ev.ctrlKey) { return; }
    var scale = ev.deltaMode === 1 ? 16 : (ev.deltaMode === 2 ? window.innerHeight : 1);
    if (scrollAt(ev.clientX, ev.clientY, ev.deltaX * scale, ev.deltaY * scale)) {
      ev.preventDefault();
      ev.stopPropagation();
    }
  }
  hitLayer.addEventListener('wheel', onWheel, { passive: false });

  // ---------------------------------------------------------------- events
  function swallow(ev) {
    ev.preventDefault();
    ev.stopImmediatePropagation();
    ev.stopPropagation();
  }
  function finish(phase, code, message) {
    state.phase = phase; state.code = code || ''; state.message = message || '';
    draw();
  }
  /*
    A short note while picking goes on. "changed" more than twice in a row means the page
    changes under every click: say instead that pointing does not work here.
  */
  var changedRun = 0;
  function setNote(code) {
    if (code === 'changed') { changedRun++; if (changedRun >= 3) { code = 'changed-again'; } }
    state.note = code;
    draw();
  }
  // The person's choice: mark the element (the server's proof looks for this mark).
  function accept(info) {
    if (info.blocked === 'ours') { return; }
    if (info.blocked) { state.hover = info; finish('blocked', info.blocked, describeHover(info)); return; }
    if (mode === 'scroll' && info.scroll.kind === 'none') { state.hover = info; draw(); return; }
    var target = mode === 'scroll' ? (info.scroll.kind === 'window' ? null : info.scroll.node) : info.el;
    if (target) {
      try { Object.defineProperty(target, MARK, { value: String(cfg.token), configurable: true, enumerable: false, writable: true }); }
      catch (e) { finish('error', 'mark', 'The element could not be marked.'); return; }
    }
    state.picked = info;
    state.saved = saveScroll(info);
    changedRun = 0;
    finish('picked', '', '');
  }
  function onMove(win) {
    return function (ev) {
      if (state.phase !== 'picking' || !ev.isTrusted) { return; }
      if (targetOf(ev) === host && win === window) {
        pointer.x = ev.clientX; pointer.y = ev.clientY;
        state.hover = resolveHit(hitTest(ev.clientX, ev.clientY));
        if (state.note && state.note.indexOf('uncovered') === 0) { state.note = ''; }
      }
      else { state.hover = null; state.note = aboveReason(targetOf(ev)); }
      draw();
    };
  }
  /*
    The single gesture that picks: a trusted primary click on the layer whose element
    is the one under the pointer at the press. A press records that element; anything
    the page changes in between makes the click pick nothing (note "changed"). Events
    the page makes itself (isTrusted false) never pick. A trusted click that did not
    land on the layer is something the page shows above it: refused, with a note.
  */
  function onPointer(win) {
    return function (ev) {
      swallow(ev);
      if (!ev.isTrusted || state.phase !== 'picking') { return; }
      var target = targetOf(ev), onLayer = target === host && win === window;
      if (ev.type === 'pointerdown') {
        // A layer the page made us move just now (its own listener ran first, at this very
        // press) means the page is changing under the pointer: this press picks nothing.
        var fresh = Date.now() - lastMove < 100;
        state.down = onLayer && ev.button === 0 && !fresh ? keyOf(resolveHit(hitTest(ev.clientX, ev.clientY))) : NONE;
        state.spoiled = onLayer && ev.button === 0 && fresh;
        state.downMoves = moves;
        // A new press starts afresh: the last note no longer applies.
        if (onLayer && state.note) { state.note = ''; draw(); }
        return;
      }
      if (ev.type === 'pointerup' && state.spoiled) { state.spoiled = false; setNote('changed'); return; }
      // The release already tells whether the page changed under the pointer: the browser
      // may not send the click at all after the page moved things around (for example a
      // dialog opened at the press).
      if (ev.type === 'pointerup' && state.down !== NONE && ev.button === 0) {
        if (!onLayer) { setNote(aboveReason(target)); state.down = NONE; return; }
        if (moves !== state.downMoves || state.down !== keyOf(resolveHit(hitTest(ev.clientX, ev.clientY)))) { setNote('changed'); state.down = NONE; }
        return;
      }
      if (ev.type !== 'click') { return; }
      // A click the browser made itself, without the pointer (pointerId -1): the page's
      // access key (Alt + a letter), which cannot be switched off. It is cancelled like
      // every click, and said so.
      if (!onLayer) { setNote(ev.pointerId === -1 ? 'shortcut' : aboveReason(target)); return; }
      if (ev.button !== 0) { return; }
      var down = state.down;
      state.down = NONE;
      var info = resolveHit(hitTest(ev.clientX, ev.clientY));
      if (down === NONE || moves !== state.downMoves || down !== keyOf(info)) { setNote('changed'); return; }
      state.note = '';
      accept(info);
    };
  }
  /*
    ONE rule for keys, decided by where the key goes - never by what kind of control has
    the focus (an <input> inside a component, a <select> that F4 opens, a link that
    Ctrl+Enter opens in a new tab: the list of such cases has no end):
    - aimed at the picker's own layer: never reaches the page; function keys and
      Ctrl/Alt/Meta combinations keep their default, so the browser's own shortcuts
      work (the layer cannot be typed in and has no default of the site's);
    - aimed anywhere else (the page took the focus - in the page, a same-site frame or
      any shadow tree): never reaches the page AND its default is prevented, every key.
    Esc cancels; the scroll keys (arrows, Page Up/Down, Home/End, Space and Shift+Space)
    scroll what is under the pointer. There is no keyboard picking: words and selectors
    can be typed in the Designer instead.
  */
  function onKey(win) {
    return function (ev) {
      var ours = win === window && targetOf(ev) === host;
      // A key arriving here means this window has the focus, not a frame inside it.
      if (win === window && ev.isTrusted) { windowBlurred = false; }
      var browsers = /^F([1-9]|1[0-9]|2[0-4])$/.test(ev.key) || ev.ctrlKey || ev.altKey || ev.metaKey;
      ev.stopImmediatePropagation();
      ev.stopPropagation();
      if (!(ours && browsers) || ev.key === 'Escape') { ev.preventDefault(); }
      if (!ev.isTrusted || ev.type !== 'keydown') { return; }
      if (ev.key === 'Escape') { if (state.phase === 'picking') { finish('cancelled', 'esc', ''); } return; }
      if (state.phase !== 'picking' || ev.ctrlKey || ev.altKey || ev.metaKey) { return; }
      var step = 40, page = Math.max(40, window.innerHeight * 0.875), dx = 0, dy = 0;
      switch (ev.key) {
        case 'ArrowDown': dy = step; break;
        case 'ArrowUp': dy = -step; break;
        case 'ArrowRight': dx = step; break;
        case 'ArrowLeft': dx = -step; break;
        case 'PageDown': dy = page; break;
        case 'PageUp': dy = -page; break;
        case ' ': case 'Spacebar': dy = ev.shiftKey ? -page : page; break;
        case 'Home': dy = -1e7; break;
        case 'End': dy = 1e7; break;
        default: return;
      }
      scrollAt(pointer.x, pointer.y, dx, dy);
    };
  }
  /*
    The picker never edits anything, so every edit the browser is about to make is
    cancelled (beforeinput): typing a key's default could not stop - text an input
    method commits, the emoji panel, clipboard history, voice typing, spelling
    corrections - and undo/redo, which Ctrl+Z would apply to the page's last edited
    field even with the focus on the picker's layer.
  */
  function onBeforeInput(ev) { swallow(ev); }
  /*
    Typing reached the page all the same: a composition started (its text cannot be
    cancelled) or a field changed. The pick ends rather than go on while the page is
    being typed in. Events the page makes itself do not count.
  */
  function onTyping(ev) {
    if (!ev.isTrusted || (state.phase !== 'picking' && state.phase !== 'picked')) { return; }
    finish('error', 'typing', '');
  }
  // Cut, copy and paste never reach the page (a site may act on a paste anywhere); nothing is cut or pasted.
  function onClipboard(ev) {
    ev.stopImmediatePropagation();
    ev.stopPropagation();
    if (ev.type !== 'copy') { ev.preventDefault(); }
  }
  // Never a focus change inside a focus event: only a focus gone into another site's frame is taken back, later.
  function onFocusIn() {
    if (state.phase === 'picking' || state.phase === 'picked') { takeBackFocus(); }
  }
  /*
    A menu or dialog of the page opening or closing. beforetoggle comes before the
    change: it gives the order menus open in, and the guard runs as soon as the page's
    script is done (a microtask), before any further press. The picker's own popover
    toggling must not start the guard again (it would loop).
  */
  function onTopLayerChange(ev) {
    var t = targetOf(ev);
    if (t === host) { return; }
    if (ev.type === 'beforetoggle') {
      if (opened && t && t.nodeType === 1) { if (ev.newState === 'open') { opened.set(t, ++openCount); } else { opened.delete(t); } }
      // A menu the layer could not be drawn in gets another chance when it opens again
      // (not when it closes: the layer would hop in and out of it under the very press).
      if (t && ev.newState === 'open' && typeof unusable.delete === 'function') { unusable.delete(t); }
      Promise.resolve().then(guard);
      return;
    }
    guard();
  }
  // A frame finished loading: its new page gets the listeners now, not at the next refresh.
  function onLoad(ev) {
    var t = targetOf(ev);
    if (!t || t.nodeType !== 1 || !/^i?frame$/i.test(t.localName || '')) { return; }
    var d = null;
    try { d = t.contentDocument; } catch (e) { d = null; }
    if (!d || !d.documentElement) { return; }
    var out = { scopes: [], roots: [], wins: [t.contentWindow] };
    try { walkTree(d, false, out); } catch (e) { /* next refresh */ }
    out.wins.forEach(listen);
  }
  function add(target, type, fn) {
    target.addEventListener(type, fn, true);
    for (var i = 0; i < attached.length; i++) { if (attached[i].target === target && attached[i].type === type && attached[i].fn === fn) { return; } }
    attached.push({ target: target, type: type, fn: fn });
  }
  /*
    Adds the listeners to a window. Called again on every refresh: adding the same
    function twice does nothing, and a window whose page was replaced (a frame that
    navigated or reloaded, document.open()) has lost them all and gets them back.
  */
  function listen(win) {
    try {
      // A frame's new page came with the server's shield (it swallows everything until
      // the picker is there): the picker's own listeners take over.
      var there = win !== window ? win[NS] : null;
      if (there && there.shield && typeof there.stop === 'function') { there.stop(); }
      var h = handlers ? handlers.get(win) : null;
      if (!h) {
        h = { pointer: onPointer(win), key: onKey(win), move: onMove(win) };
        if (handlers) { handlers.set(win, h); }
      }
      POINTER.forEach(function (type) { add(win, type, h.pointer); });
      KEYS.forEach(function (type) { add(win, type, h.key); });
      CLIPBOARD.forEach(function (type) { add(win, type, onClipboard); });
      add(win, 'mousemove', h.move);
      add(win, 'focusin', onFocusIn);
      add(win, 'beforeinput', onBeforeInput);
      add(win, 'input', onTyping);
      add(win, 'compositionstart', onTyping);
      add(win, 'toggle', onTopLayerChange);
      add(win, 'beforetoggle', onTopLayerChange);
      add(win, 'fullscreenchange', onTopLayerChange);
      // A frame's load event stops at its document (it never reaches the window).
      add(win.document, 'load', onLoad);
      if (win === window) { add(win, 'blur', onWindowFocus); add(win, 'focus', onWindowFocus); }
    }
    catch (e) { /* a frame that went away or changed site meanwhile */ }
  }
  // Menus, dialogs and frames inside an open shadow root: their events do not leave it.
  function listenRoot(root) {
    try {
      add(root, 'toggle', onTopLayerChange);
      add(root, 'beforetoggle', onTopLayerChange);
      add(root, 'load', onLoad);
      if (observer && observed.indexOf(root) < 0 && root.isConnected !== false && deepContains(document, root)) {
        observed.push(root);
        observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['open'] });
      }
    }
    catch (e) { /* gone */ }
  }
  function listenAll() {
    known.wins.forEach(listen);
    known.roots.forEach(listenRoot);
  }
  function unlistenAll() {
    attached.forEach(function (a) { try { a.target.removeEventListener(a.type, a.fn, true); } catch (e) { /* frame gone */ } });
    attached = [];
  }

  /*
    The guard, run on every refresh, on DOM changes that matter and when top-layer
    content opens or closes: the host must be connected, where it belongs (inside the
    menu or modal dialog on top, else last in the page), on top, covering the whole
    window, and the focus must not be in a frame the picker cannot listen in. A host
    the page removed is put back and the listeners are added again (document.open()
    drops every listener). What cannot be restored ends the pick rather than going on
    unprotected.
  */
  var guarding = false;
  function guard() {
    if (guarding || (state.phase !== 'picking' && state.phase !== 'picked')) { return; }
    guarding = true;
    try {
      var parent = wantedParent();
      if (!host.isConnected) {
        // Taken out of the page (document.open() also drops every listener): put back and listen again.
        placeHost();
        scan(true);
        watch();
        listenAll();
      }
      else if (misplaced(parent)) {
        // Moved only (a menu or dialog opened or closed, something added after it): the listeners stay.
        placeHost();
      }
      // A full-screen element stays above the layer whatever is done; clicks there are refused.
      if (!document.fullscreenElement && !onTopEverywhere()) { showOnTop(true); }
      if (!coversWindow()) {
        // Not drawn where it is: a menu or dialog that does not show content added to it
        // (a component with a closed shadow root). Do without that one.
        var at = host.parentNode, owner = at && at.host ? at.host : at;
        if (owner && owner !== document.documentElement) { unusable.add(owner); }
        placeHost();
      }
      if (!host.isConnected || !coversWindow()) { finish('error', 'coverage', ''); return; }
      if (focusInForeignFrame()) { takeBackFocus(); }
    }
    finally { guarding = false; }
  }
  /*
    DOM changes: only those that can matter start the guard - the host gone or no longer
    where it belongs, or a dialog opening or closing (its "open" attribute). A menu that
    keeps rewriting its rows around the host costs nothing.
  */
  var observed = [];
  function onMutations(records) {
    var matters = !host.isConnected || (host.parentNode === document.documentElement && document.documentElement.lastElementChild !== host);
    for (var i = 0; i < records.length && !matters; i++) { matters = records[i].type === 'attributes'; }
    if (matters) { guard(); }
  }
  function watch() {
    if (observer) { observer.disconnect(); }
    observed = [];
    if (typeof MutationObserver !== 'function') { return; }
    observer = new MutationObserver(onMutations);
    observer.observe(document, { childList: true });
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['open'] });
    }
  }
  function refresh() {
    if (Date.now() - lastBeat > (state.phase === 'picking' ? HEARTBEAT_MS : BUSY_MS)) { stop(); return; }
    scan(false);
    listenAll();
    refreshOverlays();
    guard();
    if (state.phase === 'picking' && state.hover && !state.hover.blocked) { draw(); }
  }

  // ---------------------------------------------------------------- scroll positions (the engine's area check scrolls to the top)
  function saveScroll(info) {
    var saved = { x: window.scrollX, y: window.scrollY, node: null, top: 0, win: null, wy: 0 };
    if (mode !== 'scroll' || !info.scroll) { return saved; }
    if (info.scroll.kind === 'element') { saved.node = info.scroll.node; saved.top = info.scroll.node.scrollTop; }
    if (info.scroll.kind === 'frame') { saved.win = info.scroll.inner.win; saved.wy = saved.win.scrollY; }
    return saved;
  }
  function restore() {
    var s = state.saved;
    if (s) {
      try { window.scrollTo(s.x, s.y); } catch (e) { /* gone */ }
      try { if (s.node) { s.node.scrollTop = s.top; } } catch (e) { /* gone */ }
      try { if (s.win) { s.win.scrollTo(0, s.wy); } } catch (e) { /* gone */ }
    }
    if (hadTarget) { window.__vouchTarget = savedTarget; }
    else { try { delete window.__vouchTarget; } catch (e) { window.__vouchTarget = undefined; } }
    return true;
  }

  // ---------------------------------------------------------------- proposals (checked by the engine on the server)
  function cssString(v) { return '"' + String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\a ').replace(/\r/g, '\\d ') + '"'; }
  function ownText(el) {
    var parts = [];
    for (var c = el.firstChild; c; c = c.nextSibling) { if (c.nodeType === 3) { parts.push(c.nodeValue); } }
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }
  function segment(n) {
    var tag = n.tagName.toLowerCase(), index = 1, same = 0;
    for (var s = n.parentElement ? n.parentElement.firstElementChild : null; s; s = s.nextElementSibling) {
      if (s.tagName === n.tagName) { same++; if (s === n) { index = same; } }
    }
    return same > 1 ? tag + ':nth-of-type(' + index + ')' : tag;
  }
  function anchorOf(n) {
    var attrs = ['data-testid', 'data-test', 'data-qa'];
    for (var i = 0; i < attrs.length; i++) {
      var v = n.getAttribute(attrs[i]);
      if (v) { return { sel: '[' + attrs[i] + '=' + cssString(v) + ']', id: '' }; }
    }
    if (n.id) { return { sel: '#' + CSS.escape(n.id), id: n.id }; }
    return null;
  }
  function paths(el, doc) {
    var out = [], segs = [], n = el;
    for (var depth = 0; n && n.nodeType === 1 && n !== doc.documentElement && depth < 6; depth++) {
      if (n !== el) {
        var a = anchorOf(n);
        if (a && out.length < 3) { out.push({ kind: 'path', value: a.sel + ' > ' + segs.join(' > '), anchorId: a.id }); }
      }
      if (segs.length >= 5) { break; }
      segs.unshift(segment(n));
      n = n.parentElement;
    }
    out.push({ kind: 'path', value: segs.join(' > '), anchorId: '' });
    return out;
  }
  function proposals() {
    var p = state.picked;
    if (!p) { return []; }
    var list = [];
    if (mode === 'scroll' && p.scroll.kind === 'window') { return [{ kind: 'page', value: '' }]; }
    var el = mode === 'scroll' ? p.scroll.node : p.el;
    if (!el) { return []; }
    var doc = el.ownerDocument;
    if (mode === 'click') {
      var full = labelOf(el), own = ownText(el);
      if (full && full.length <= 80) { list.push({ kind: 'text', value: full }); }
      if (own && own !== full && own.length >= 2 && own.length <= 80) { list.push({ kind: 'text', value: own }); }
    }
    ['data-testid', 'data-test', 'data-qa'].forEach(function (attr) {
      var v = el.getAttribute(attr);
      if (v && v.length <= 120) { list.push({ kind: 'testid', value: '[' + attr + '=' + cssString(v) + ']', attr: attr, attrValue: v }); }
    });
    if (el.id && el.id.length <= 120) { list.push({ kind: 'id', value: '#' + CSS.escape(el.id), attrValue: el.id }); }
    var tag = el.tagName.toLowerCase();
    ['aria-label', 'name', 'placeholder'].forEach(function (attr) {
      var v = el.getAttribute(attr);
      if (v && v.trim() && v.length <= 120) { list.push({ kind: 'attribute', value: tag + '[' + attr + '=' + cssString(v) + ']', attr: attr, attrValue: v }); }
    });
    paths(el, doc).forEach(function (x) { list.push(x); });
    return list;
  }
  function info() {
    var p = state.picked;
    if (!p) { return null; }
    if (mode === 'scroll') {
      var s = p.scroll;
      if (s.kind === 'window') { return { kind: 'window', tag: '', id: '', noun: 'page', text: '', frame: '', climbedFrom: '' }; }
      return { kind: s.kind, tag: s.node.tagName.toLowerCase(), id: s.node.id || '', noun: s.kind === 'frame' ? 'frame' : 'area', text: '',
        frame: p.entry && p.entry.frame ? vouchFrameName(p.entry.frame) : '', climbedFrom: '' };
    }
    return { kind: 'element', tag: p.el.tagName.toLowerCase(), id: p.el.id || '', noun: nounOf(p.el), text: short(labelOf(p.el), 120),
      frame: p.entry && p.entry.frame ? vouchFrameName(p.entry.frame) : '', climbedFrom: p.climbedFrom || '' };
  }

  // ---------------------------------------------------------------- the one global, while picking
  function stop() {
    if (timer) { clearInterval(timer); timer = 0; }
    if (observer) { observer.disconnect(); observer = null; }
    unlistenAll();
    var p = state.picked;
    var target = p ? (mode === 'scroll' ? (p.scroll && p.scroll.node) : p.el) : null;
    if (target) { try { delete target[MARK]; } catch (e) { /* gone */ } }
    if (takeBackTimer) { clearTimeout(takeBackTimer); takeBackTimer = 0; }
    try { if (canPopover && host.matches(':popover-open')) { host.hidePopover(); } } catch (e) { /* not shown */ }
    // The focus is NOT given back to what the page had focused: focusing fires the page's
    // focus handlers, which can open focus-driven widgets (date pickers, menus). It falls
    // to the page body as the layer goes; the person clicks where they want to work.
    if (host.parentNode) { host.parentNode.removeChild(host); }
    if (window[NS] === api) { try { delete window[NS]; } catch (e) { window[NS] = undefined; } }
    return true;
  }
  var api = {
    status: function () {
      beat();
      return { phase: state.phase, code: state.code, note: state.note, mode: mode, url: String(location.href).substring(0, 2000) };
    },
    info: function () { beat(); return info(); },
    proposals: function () { beat(); return proposals(); },
    restore: function () { beat(); return restore(); },
    element: function () { beat(); var p = state.picked; return p ? (mode === 'scroll' ? (p.scroll && p.scroll.node) || null : p.el) : null; },
    stop: stop,
  };
  Object.defineProperty(window, NS, { value: api, configurable: true, enumerable: false, writable: true });
  scan(true);
  placeHost();
  watch();
  park();
  refresh();
  timer = setInterval(refresh, 250);
  return 'picking';
})
