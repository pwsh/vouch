/*
  Vouch Designer picker: runs inside the AUDIT browser's page, never in the panel.

  The server (designer\Designer.ps1, Start-ElementPick) evaluates this file in the page
  through the DevTools connection, wrapped in a closure that also holds the engine's own
  frame helpers (vouchDocs, vouchVisible, vouchFrameName from Get-FrameDocsScript), and
  calls it with a config object { mode, token, texts }. Every value in that object went
  through ConvertTo-JsLiteral.

  What it does, and what it does not:
  - It shows what the person points at (a banner and an outline in a closed shadow root,
    styled through the CSSOM so neither the site's CSS nor its Content-Security-Policy
    gets in the way). A transparent hit layer covers the window, so pointer events land
    on the picker, never on the site's elements; what lies beneath is found by
    hit-testing. Clicks, keys and the events around them are swallowed so the site never
    acts on them, and only the person's own (trusted) events pick or cancel. The picked
    element is marked with a temporary property.
  - It PROPOSES text and selectors. It never decides: the server keeps a proposal only
    when the engine's own find-only scripts, run against this page, resolve it to the
    marked element. There is no second matcher here.
  - Nothing from the page is trusted by the server: it reads plain values (strings and
    numbers), caps their length and builds every sentence itself.
  - stop() removes everything: listeners, timers, the injected nodes, the mark and the
    single namespaced global window.__vouchPicker.
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
  // Everything that could make the site act. Pointer events never reach the site's
  // elements anyway (they land on the hit layer below); these are swallowed as well for
  // keyboard activation, events inside frames, and implicit form submission.
  var SWALLOW = ['pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu',
    'touchstart', 'touchend', 'touchcancel', 'dragstart', 'drop', 'submit'];
  var hadTarget = Object.prototype.hasOwnProperty.call(window, '__vouchTarget');
  var savedTarget = hadTarget ? window.__vouchTarget : undefined;

  var state = { phase: 'picking', code: '', message: '', picked: null, hover: null, saved: null };
  var attached = [];   // { win, type, fn }
  var windows = [];    // windows that have our listeners
  var timer = 0;

  // ---------------------------------------------------------------- UI (closed shadow root)
  function css(el, rules) { for (var k in rules) { if (Object.prototype.hasOwnProperty.call(rules, k)) { el.style.setProperty(k, rules[k], 'important'); } } return el; }
  var host = document.createElement('vouch-picker-ui');
  css(host, { all: 'initial', position: 'fixed', left: '0', top: '0', width: '0', height: '0', 'z-index': '2147483647', display: 'block', overflow: 'visible', 'pointer-events': 'none' });
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
  bannerStatus.textContent = '';
  banner.appendChild(bannerTitle);
  banner.appendChild(bannerStatus);
  var overlayLayer = css(document.createElement('div'), { position: 'fixed', left: '0', top: '0', width: '0', height: '0', 'z-index': '1', margin: '0' });
  /*
    The hit layer: transparent, over the whole window, frames included. Every pointer
    event's target is therefore this picker's own host, so no listener of the site - not
    even one registered on window in the capture phase before the picker came - ever
    sees the real element as the target. What lies under the pointer is found by
    hit-testing beneath the layer (hitTest), through same-site frames. One layer in the
    top document is enough: it covers the frames too, so they get no pointer events at
    all. The wheel is passed on to what lies beneath (onWheel), so the person can still
    scroll the page, its panels and its frames to reach what they want to pick.
  */
  var hitLayer = css(document.createElement('div'), {
    position: 'fixed', left: '0', top: '0', width: '100vw', height: '100vh', 'z-index': '0', margin: '0', padding: '0',
    background: 'transparent', cursor: 'crosshair', 'pointer-events': 'auto' });
  root.appendChild(hitLayer);
  root.appendChild(overlayLayer);
  root.appendChild(outline);
  root.appendChild(label);
  root.appendChild(banner);
  document.documentElement.appendChild(host);

  // ---------------------------------------------------------------- geometry
  function frameOffset(entry) {
    var x = 0, y = 0;
    for (var e = entry; e && e.frame; e = e.parent) {
      var r = e.frame.getBoundingClientRect();
      x += r.left + e.frame.clientLeft; y += r.top + e.frame.clientTop;
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
      var rect = { left: r.left + off.x, top: r.top + off.y, width: r.width, height: r.height };
      var box = css(document.createElement('div'), {
        position: 'fixed', 'box-sizing': 'border-box', border: '2px dashed #a8201a', 'pointer-events': 'none',
        background: 'repeating-linear-gradient(45deg, rgba(168,32,26,0.06) 0 10px, rgba(168,32,26,0.14) 10px 20px)', margin: '0' });
      place(box, rect);
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
    lists the elements there from the top; the picker's own host is skipped. A frame from
    the same site is entered (its document, with the point in its own coordinates); a
    frame from another site cannot be, and says so. An open shadow root is looked into
    (ShadowRoot.elementFromPoint), only to be able to say that it cannot be recorded.
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
        if (!inner || !inner.documentElement) { return { el: el, real: el, win: win, crossorigin: true }; }
        var r = el.getBoundingClientRect();
        ox += r.left + el.clientLeft; oy += r.top + el.clientTop;
        doc = inner; win = el.contentWindow;
        continue;
      }
      var real = el;
      for (var k = 0; k < 12 && real.shadowRoot && real.shadowRoot.elementFromPoint; k++) {
        var deeper = real.shadowRoot.elementFromPoint(x - ox, y - oy);
        if (!deeper || deeper === real) { break; }
        real = deeper;
      }
      return { el: el, real: real, win: win, crossorigin: false };
    }
    return null;
  }
  // The element that has the keyboard focus, through same-site frames and open shadow roots.
  function focusedTarget() {
    var doc = document, win = window, el = doc.activeElement;
    for (var depth = 0; depth < 12 && el; depth++) {
      var tag = el.tagName.toLowerCase();
      if (tag !== 'iframe' && tag !== 'frame') { break; }
      var inner = null;
      try { inner = el.contentDocument; } catch (e) { inner = null; }
      if (!inner) { return { el: el, real: el, win: win, crossorigin: true }; }
      doc = inner; win = el.contentWindow; el = doc.activeElement;
    }
    if (!el || el === doc.body || el === doc.documentElement || el === host) { return null; }
    var real = el;
    for (var k = 0; k < 12 && real.shadowRoot && real.shadowRoot.activeElement; k++) { real = real.shadowRoot.activeElement; }
    return { el: el, real: real, win: win, crossorigin: false };
  }
  function resolveHit(hit) {
    if (!hit) { return { blocked: 'ours' }; }
    if (hit.crossorigin) { return { blocked: 'crossorigin', frameName: vouchFrameName(hit.el) }; }
    return resolveElement(hit.el, hit.real, hit.win);
  }
  function resolve(ev, win) {
    var t = ev.target;
    if (t === host) { return resolveHit(hitTest(ev.clientX, ev.clientY)); }
    if (!t || t.nodeType !== 1) { return { blocked: 'ours' }; }
    var path = typeof ev.composedPath === 'function' ? ev.composedPath() : [];
    var real = path.length && path[0] && path[0].nodeType === 1 ? path[0] : t;
    return resolveElement(t, real, win);
  }
  function resolveElement(t, real, win) {
    var entry = entryForWindow(win);
    if (!entry) { return { blocked: 'ours' }; }
    var tag = t.tagName.toLowerCase();
    if (tag === 'iframe' || tag === 'frame') {
      var reachable = vouchDocs().list.some(function (x) { return x.frame === t; });
      if (!reachable) { return { blocked: 'crossorigin', frameName: vouchFrameName(t) }; }
    }
    if (mode === 'scroll') {
      var s = findScroller(real, entry);
      if (s.kind === 'shadow') { return { blocked: 'shadow' }; }
      return { blocked: '', scroll: s, entry: s.entry || entry, el: s.node || null };
    }
    if (real !== t && inShadow(real)) { return { blocked: 'shadow' }; }
    var el = t, climbedFrom = '';
    if (mode === 'click') {
      var up = t.closest ? t.closest(INTERACTIVE) : null;
      if (up && up !== t) { climbedFrom = tag; el = up; }
    }
    return { blocked: '', el: el, entry: entry, climbedFrom: climbedFrom };
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
    if (!info || info.blocked) {
      css(outline, { display: 'none' }); css(label, { display: 'none' });
      bannerStatus.textContent = info && info.blocked && info.blocked !== 'ours' ? describeHover(info) : (state.phase === 'picked' ? (texts.checking || 'Checking…') : '');
      css(banner, { background: info && info.blocked && info.blocked !== 'ours' ? '#a8201a' : '#1c2330' });
      return;
    }
    var r = null;
    if (mode === 'scroll' && info.scroll.kind === 'window') { r = { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight }; }
    else if (mode === 'scroll' && info.scroll.kind === 'none') { r = null; }
    else if (info.el) { r = topRect(info.el, info.entry); }
    css(banner, { background: '#1c2330' });
    bannerStatus.textContent = state.phase === 'picked' ? (texts.checking || 'Checking…') : describeHover(info);
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
  function onMove(win) {
    return function (ev) {
      if (state.phase !== 'picking' || !ev.isTrusted) { return; }
      state.hover = resolve(ev, win);
      draw();
    };
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
    finish('picked', '', '');
  }
  /*
    Only what the person does counts. Events the page makes itself (el.click(),
    dispatchEvent - isTrusted false) are swallowed like the others but never pick or
    cancel: a page that clicks something by script (an auto-refresh, a carousel, or a
    hostile page) must not choose what Vouch records.
  */
  function onSwallowed(win) {
    return function (ev) {
      swallow(ev);
      if (!ev.isTrusted || ev.type !== 'click' || state.phase !== 'picking') { return; }
      accept(resolve(ev, win));
    };
  }
  /*
    Keys: Esc cancels. Enter or Space on a focused control picks that control (keyboard
    picking) and is swallowed, so it is neither activated nor submits a form. With
    nothing focused, Space and every other key keep their normal job - scrolling the
    page is never blocked.
  */
  function onKey(ev) {
    var key = ev.key;
    if (key === 'Escape') {
      swallow(ev);
      if (ev.isTrusted && ev.type === 'keydown' && state.phase === 'picking') { finish('cancelled', 'esc', ''); }
      return;
    }
    if (key !== 'Enter' && key !== ' ' && key !== 'Spacebar') { return; }
    var focused = focusedTarget();
    if (!focused) { return; }
    swallow(ev);
    if (ev.isTrusted && ev.type === 'keydown' && !ev.repeat && state.phase === 'picking') { accept(resolveHit(focused)); }
  }
  /*
    The wheel over the hit layer would only scroll the top page; it is passed on to what
    lies beneath the pointer instead: the nearest panel that can still scroll that way,
    then the frame's page, then the window - the order the browser itself uses.
  */
  function onWheel(ev) {
    if (!ev.isTrusted) { return; }
    var hit = hitTest(ev.clientX, ev.clientY);
    if (!hit || hit.crossorigin) { return; }
    var scale = ev.deltaMode === 1 ? 16 : (ev.deltaMode === 2 ? window.innerHeight : 1);
    var dy = ev.deltaY * scale, dx = ev.deltaX * scale;
    var entry = entryForWindow(hit.win);
    var node = hit.el;
    for (var e = entry; e; e = e.parent) {
      for (var n = node; n && n.nodeType === 1; n = n.parentElement) {
        if (n === e.doc.documentElement || n === e.doc.body) { break; }
        var oy = e.win.getComputedStyle(n).overflowY;
        var can = (oy === 'auto' || oy === 'scroll' || oy === 'overlay') &&
          ((dy > 0 && n.scrollTop + n.clientHeight < n.scrollHeight - 1) || (dy < 0 && n.scrollTop > 0));
        if (can) { n.scrollBy(dx, dy); ev.preventDefault(); return; }
      }
      var fs = e.doc.scrollingElement || e.doc.documentElement;
      if (fs && ((dy > 0 && e.win.scrollY + e.win.innerHeight < fs.scrollHeight - 1) || (dy < 0 && e.win.scrollY > 0) || !e.frame)) {
        e.win.scrollBy(dx, dy); ev.preventDefault(); return;
      }
      node = e.frame;
    }
  }
  hitLayer.addEventListener('wheel', onWheel, { passive: false });
  function listen(win) {
    if (windows.indexOf(win) >= 0) { return; }
    windows.push(win);
    var add = function (type, fn) { win.addEventListener(type, fn, true); attached.push({ win: win, type: type, fn: fn }); };
    var swallowFn = onSwallowed(win);
    SWALLOW.forEach(function (type) { add(type, swallowFn); });
    add('mousemove', onMove(win));
    add('keydown', onKey);
    add('keyup', onKey);
  }
  function refresh() {
    var docs = refreshOverlays();
    docs.list.forEach(function (entry) { listen(entry.win); });
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
    attached.forEach(function (a) { try { a.win.removeEventListener(a.type, a.fn, true); } catch (e) { /* frame gone */ } });
    attached = []; windows = [];
    var p = state.picked;
    var target = p ? (mode === 'scroll' ? (p.scroll && p.scroll.node) : p.el) : null;
    if (target) { try { delete target[MARK]; } catch (e) { /* gone */ } }
    if (host.parentNode) { host.parentNode.removeChild(host); }
    if (window[NS] === api) { try { delete window[NS]; } catch (e) { window[NS] = undefined; } }
    return true;
  }
  var api = {
    status: function () {
      return { phase: state.phase, code: state.code, message: short(state.message, 300), mode: mode, url: String(location.href).substring(0, 2000) };
    },
    info: info,
    proposals: proposals,
    restore: restore,
    element: function () { var p = state.picked; return p ? (mode === 'scroll' ? (p.scroll && p.scroll.node) || null : p.el) : null; },
    say: function (text) { bannerStatus.textContent = String(text || ''); return true; },
    stop: stop,
  };
  Object.defineProperty(window, NS, { value: api, configurable: true, enumerable: false, writable: true });
  refresh();
  timer = setInterval(refresh, 300);
  return 'picking';
})
