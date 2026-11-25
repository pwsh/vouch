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
    dialogs, popovers and full-screen elements that opened before it) and is placed
    inside the topmost open modal dialog when there is one (everything outside a modal
    dialog is inert). Every refresh checks that it is still there, last, on top and
    covering the whole window; what cannot be restored ends the pick.
  - The keyboard never reaches the page: focus is parked on the hit layer and every key
    event is swallowed. Esc cancels; scroll keys scroll what lies under the pointer,
    by the picker's own code, like the wheel. There is no keyboard picking.
  - It PROPOSES text and selectors. It never decides: the server keeps a proposal only
    when the engine's own find-only scripts, run against this page, resolve it to the
    marked element. There is no second matcher here.
  - Nothing from the page is trusted by the server: it reads plain values (strings and
    numbers) and short codes, caps their length and builds every sentence itself.
  - stop() removes everything: listeners, timers, the observer, the injected nodes, the
    mark and the single namespaced global window.__vouchPicker.
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
  var hadTarget = Object.prototype.hasOwnProperty.call(window, '__vouchTarget');
  var savedTarget = hadTarget ? window.__vouchTarget : undefined;
  var previousFocus = document.activeElement;
  var NONE = {};

  var state = { phase: 'picking', code: '', message: '', note: '', picked: null, hover: null, down: NONE, downMoves: 0, saved: null };
  var attached = [];   // { win, type, fn }
  var windows = [];    // windows that have our listeners
  var timer = 0;
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

  // ---------------------------------------------------------------- staying on top
  // The topmost open modal dialog: while one is open, everything outside it is inert.
  function topModal() {
    var list = document.querySelectorAll('dialog[open]'), found = null;
    for (var i = 0; i < list.length; i++) {
      try { if (list[i].matches(':modal')) { found = list[i]; } } catch (e) { /* :modal unknown */ }
    }
    return found;
  }
  function wantedParent() { return topModal() || document.documentElement; }
  function showOnTop(again) {
    if (!canPopover || !host.isConnected) { return; }
    try {
      if (host.matches(':popover-open')) { if (again) { host.hidePopover(); host.showPopover(); } }
      else { host.showPopover(); }
    }
    catch (e) { /* not possible now; coverage checks decide */ }
  }
  function placeHost() {
    var parent = wantedParent();
    if (!parent) { return; }
    if (host.parentNode !== parent || parent.lastElementChild !== host) {
      parent.appendChild(host);
      // The first placement is the picker's own; later ones are the page changing things.
      if (placed) { moves++; lastMove = Date.now(); }
      placed = true;
    }
    showOnTop(false);
  }
  // How often the layer had to be put back or moved: a move between press and release
  // means the page changed under the pointer.
  var moves = 0, lastMove = 0, placed = false;
  // Whether the layer is what lies on top at a few points of the window.
  function onTopEverywhere() {
    var w = window.innerWidth, h = window.innerHeight, points = [[0.5, 0.5], [0.05, 0.05], [0.95, 0.05], [0.05, 0.95], [0.95, 0.95]];
    for (var i = 0; i < points.length; i++) {
      var e = document.elementFromPoint(w * points[i][0], h * points[i][1]);
      if (e && e !== host) { return false; }
    }
    return true;
  }
  function coversWindow() {
    var r = hitLayer.getBoundingClientRect();
    return r.left <= 0.5 && r.top <= 0.5 && r.right >= window.innerWidth - 0.5 && r.bottom >= window.innerHeight - 0.5;
  }

  // ---------------------------------------------------------------- the keyboard focus
  function park() {
    if (document.activeElement === host) { return true; }
    try { hitLayer.focus({ preventScroll: true }); } catch (e) { /* not focusable now */ }
    return document.activeElement === host;
  }
  function focusInForeignFrame() {
    var a = document.activeElement;
    for (var depth = 0; depth < 12 && a && /^i?frame$/i.test(a.tagName); depth++) {
      var d = null;
      try { d = a.contentDocument; } catch (e) { d = null; }
      if (!d) { return true; }
      a = d.activeElement;
    }
    return false;
  }

  // ---------------------------------------------------------------- geometry
  /*
    Where a frame's content starts, in its parent's window: the frame's box plus its
    border and padding. A frame shown scaled or turned (its box on screen differs from
    its layout size) cannot be mapped exactly, so it gives null and is refused.
  */
  function frameOrigin(frame) {
    var r = frame.getBoundingClientRect();
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
      var list = doc.elementsFromPoint(x - ox, y - oy), el = null;
      for (var i = 0; i < list.length; i++) { if (list[i] !== host) { el = list[i]; break; } }
      if (!el) { return null; }
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
      var real = el;
      for (var k = 0; k < 12 && real.shadowRoot && real.shadowRoot.elementFromPoint; k++) {
        var deeper = real.shadowRoot.elementFromPoint(x - ox, y - oy);
        if (!deeper || deeper === real) { break; }
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
  function setNote(code) { state.note = code; draw(); }
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
    finish('picked', '', '');
  }
  function onMove(win) {
    return function (ev) {
      if (state.phase !== 'picking' || !ev.isTrusted) { return; }
      if (ev.target === host && win === window) {
        pointer.x = ev.clientX; pointer.y = ev.clientY;
        state.hover = resolveHit(hitTest(ev.clientX, ev.clientY));
        if (state.note && state.note.indexOf('uncovered') === 0) { state.note = ''; }
      }
      else { state.hover = null; state.note = aboveReason(ev.target); }
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
      var onLayer = ev.target === host && win === window;
      if (ev.type === 'pointerdown') {
        // A layer the page made us move just now (its own listener ran first, at this very
        // press) means the page is changing under the pointer: this press picks nothing.
        var fresh = Date.now() - lastMove < 100;
        state.down = onLayer && ev.button === 0 && !fresh ? keyOf(resolveHit(hitTest(ev.clientX, ev.clientY))) : NONE;
        state.spoiled = onLayer && ev.button === 0 && fresh;
        state.downMoves = moves;
        return;
      }
      if (ev.type === 'pointerup' && state.spoiled) { state.spoiled = false; setNote('changed'); return; }
      // The release already tells whether the page changed under the pointer: the browser
      // may not send the click at all after the page moved things around (for example a
      // dialog opened at the press).
      if (ev.type === 'pointerup' && state.down !== NONE && ev.button === 0) {
        if (!onLayer) { setNote(aboveReason(ev.target)); state.down = NONE; return; }
        if (moves !== state.downMoves || state.down !== keyOf(resolveHit(hitTest(ev.clientX, ev.clientY)))) { setNote('changed'); state.down = NONE; }
        return;
      }
      if (ev.type !== 'click') { return; }
      if (!onLayer) { setNote(aboveReason(ev.target)); return; }
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
    Keys never reach the page. Esc cancels; the scroll keys (arrows, Page Up/Down,
    Home/End, Space and Shift+Space) scroll what is under the pointer; every other key
    does nothing. There is no keyboard picking: words and selectors can be typed in the
    Designer instead.
  */
  function onKey(ev) {
    swallow(ev);
    if (!ev.isTrusted || ev.type !== 'keydown') { return; }
    if (ev.key === 'Escape') { if (state.phase === 'picking') { finish('cancelled', 'esc', ''); } return; }
    if (state.phase !== 'picking') { return; }
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
  }
  function onFocusIn(ev) {
    if (ev.target !== host && (state.phase === 'picking' || state.phase === 'picked')) { park(); }
  }
  function onTopLayerChange() { guard(); }
  function listen(win) {
    if (windows.indexOf(win) >= 0) { return; }
    windows.push(win);
    var add = function (type, fn) { win.addEventListener(type, fn, true); attached.push({ win: win, type: type, fn: fn }); };
    var pointerFn = onPointer(win);
    POINTER.forEach(function (type) { add(type, pointerFn); });
    KEYS.forEach(function (type) { add(type, onKey); });
    add('mousemove', onMove(win));
    add('focusin', onFocusIn);
    add('toggle', onTopLayerChange);
    add('fullscreenchange', onTopLayerChange);
  }
  function unlistenAll() {
    attached.forEach(function (a) { try { a.win.removeEventListener(a.type, a.fn, true); } catch (e) { /* frame gone */ } });
    attached = []; windows = [];
  }

  /*
    The guard, run on every refresh, on DOM changes at the top of the page and when
    top-layer content opens or closes: the host must be connected, last in its parent
    (the topmost modal dialog or the page), on top, covering the whole window, and
    holding the focus. A host the page removed is put back and the listeners are added
    again (document.open() drops every listener). What cannot be restored ends the pick
    rather than going on unprotected.
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
        unlistenAll();
        vouchDocs().list.forEach(function (entry) { listen(entry.win); });
        watch();
      }
      else if (host.parentNode !== parent || (parent && parent.lastElementChild !== host)) {
        // Moved only (a dialog opened or closed, something added after it): the listeners stay.
        placeHost();
      }
      // A full-screen element stays above the layer whatever is done; clicks there are refused.
      if (!document.fullscreenElement && !onTopEverywhere()) { showOnTop(true); }
      if (!coversWindow()) { placeHost(); }
      if (!host.isConnected || !coversWindow()) { finish('error', 'coverage', ''); return; }
      if (!park() && focusInForeignFrame()) { finish('error', 'focus', ''); }
    }
    finally { guarding = false; }
  }
  function watch() {
    if (observer) { observer.disconnect(); }
    if (typeof MutationObserver !== 'function') { return; }
    observer = new MutationObserver(function () { guard(); });
    observer.observe(document, { childList: true });
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['open'] });
    }
  }
  function refresh() {
    var docs = refreshOverlays();
    docs.list.forEach(function (entry) { listen(entry.win); });
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
    var hadFocus = document.activeElement === host;
    try { if (canPopover && host.matches(':popover-open')) { host.hidePopover(); } } catch (e) { /* not shown */ }
    if (host.parentNode) { host.parentNode.removeChild(host); }
    // Focus goes back where it was; focusing activates nothing. Not into a frame.
    if (hadFocus && previousFocus && previousFocus.isConnected && previousFocus !== document.body &&
      !/^i?frame$/i.test(previousFocus.tagName) && typeof previousFocus.focus === 'function') {
      try { previousFocus.focus({ preventScroll: true }); } catch (e) { /* not focusable any more */ }
    }
    if (window[NS] === api) { try { delete window[NS]; } catch (e) { window[NS] = undefined; } }
    return true;
  }
  var api = {
    status: function () {
      return { phase: state.phase, code: state.code, note: state.note, mode: mode, url: String(location.href).substring(0, 2000) };
    },
    info: info,
    proposals: proposals,
    restore: restore,
    element: function () { var p = state.picked; return p ? (mode === 'scroll' ? (p.scroll && p.scroll.node) || null : p.el) : null; },
    stop: stop,
  };
  Object.defineProperty(window, NS, { value: api, configurable: true, enumerable: false, writable: true });
  placeHost();
  watch();
  park();
  refresh();
  timer = setInterval(refresh, 250);
  return 'picking';
})
