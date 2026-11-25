/*
  Vouch Designer panel.

  No framework and no build step: plain DOM built with createElement/textContent only
  (configuration files can come from other people, so nothing from them is ever parsed
  as HTML). The configuration in memory (S.config) is the single source of truth; it is
  kept exactly as the file was written (no defaults filled in), and keys the panel does
  not know are carried along untouched.

  Links to the server (see the Task 7 and Task 8 reports):
  - GET /api/state -> capabilities {browser, pick, test, run}, browser {...}, run {...}.
    When a capability turns true, the matching buttons below start calling their API.
  - Browser: renderBrowser() (status strip), retryBrowser(), tidyWindows(), zoomOff(),
    goToUrl(), addPageFromCurrentTab() -> /api/browser/{connect,layout,zoom-off,navigate},
    /api/page/from-current
  - Picker:  startPick(mode, target) -> /api/pick/start, GET /api/pick, /api/pick/cancel;
    chooseCandidate() lets the person pick one of the verified candidates; applyPick().
  - Action test: testAction(pageIndex, actionIndex) -> /api/action/test (result inline)
  - Runs: startRun('all'|'page') -> POST /api/run (the configuration as shown, unsaved
    edits included); pollRun() -> GET /api/run?since=n every second while it goes;
    stopRun(force) -> /api/run/stop; openTarget(kind) -> /api/open; refreshRunPlan() ->
    /api/run/plan (what a run would do, shown before it starts); page-test previews are
    fetched with the token and shown as data: images (loadPreviews).
  Everything that came from the audit page (titles, addresses, element words, selectors)
  arrives as JSON strings and is only ever shown with textContent.
*/
(function () {
  'use strict';

  // ------------------------------------------------------------------ DOM helpers
  let idSeq = 0;
  function uid(prefix) { idSeq += 1; return (prefix || 'id') + '-' + idSeq; }

  function h(tag, props) {
    const el = document.createElement(tag);
    if (props) {
      for (const key of Object.keys(props)) {
        const v = props[key];
        if (v === undefined || v === null || (v === false && key !== 'value')) continue;
        if (key === 'class') el.className = v;
        else if (key === 'text') el.textContent = v;
        else if (key === 'value') el.value = v;
        else if (key === 'checked') el.checked = !!v;
        else if (key === 'dataset') { for (const d of Object.keys(v)) el.dataset[d] = v[d]; }
        else if (key.startsWith('on') && typeof v === 'function') el.addEventListener(key.slice(2), v);
        else el.setAttribute(key, v === true ? '' : String(v));
      }
    }
    for (let i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }
  function append(parent, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach(c => append(parent, c)); return; }
    parent.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  const clone = v => JSON.parse(JSON.stringify(v));

  // ------------------------------------------------------------------ paths
  // Paths use the engine's spelling: pages[2].actions[0].selector
  function parsePath(p) { return (String(p).match(/[^.[\]]+/g) || []).map(t => (/^\d+$/.test(t) ? Number(t) : t)); }
  function P() {
    let out = '';
    for (const part of arguments) {
      if (typeof part === 'number') out += '[' + part + ']';
      else out += (out ? '.' : '') + part;
    }
    return out;
  }
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  function getAt(obj, path) {
    let cur = obj;
    for (const k of parsePath(path)) {
      if (cur === null || typeof cur !== 'object') return undefined;
      cur = cur[k];
    }
    return cur;
  }
  function setAt(obj, path, value) {
    const keys = parsePath(path);
    let cur = obj;
    for (let i = 0; i < keys.length - 1; i++) {
      const k = keys[i];
      const wantArray = typeof keys[i + 1] === 'number';
      if (cur[k] === null || typeof cur[k] !== 'object' || Array.isArray(cur[k]) !== wantArray) cur[k] = wantArray ? [] : {};
      cur = cur[k];
    }
    cur[keys[keys.length - 1]] = value;
  }
  function deleteAt(obj, path) {
    const keys = parsePath(path);
    const parent = getAt(obj, P.apply(null, keys.slice(0, -1)));
    if (isObj(parent)) delete parent[keys[keys.length - 1]];
  }
  /*
    The value a path had in the file as last opened or saved (undefined when absent).
    A page is found again by its id, not its position: after pages were moved, the
    same position in the saved file is another page.
  */
  function savedValue(path) {
    let saved;
    try { saved = JSON.parse(S.savedJson || 'null'); } catch (e) { return undefined; }
    const keys = parsePath(path);
    if (keys[0] === 'pages' && typeof keys[1] === 'number') {
      const page = pageAt(keys[1]);
      if (!page) return undefined;
      const id = pageId(page, keys[1]).toLowerCase();
      const savedPages = pagesOf(saved);
      const at = savedPages.findIndex((p, j) => isObj(p) && pageId(p, j).toLowerCase() === id);
      if (at < 0) return undefined;
      return getAt(saved, P.apply(null, ['pages', at].concat(keys.slice(2))));
    }
    return getAt(saved, path);
  }
  /*
    Clearing a field removes its key, so blanks and empty {} do not pile up in the file.
    A key the file already had as "" (or {}) is put back as it was instead, so opening
    a file and saving it without real edits still changes nothing.
  */
  function clearValue(path) {
    const original = savedValue(path);
    if (original === '') setAt(S.config, path, ''); else deleteAt(S.config, path);
    const keys = parsePath(path);
    if (keys.length >= 2 && keys[keys.length - 2] === 'overrides') {
      const holder = P.apply(null, keys.slice(0, -1));
      const now = getAt(S.config, holder);
      const before = savedValue(holder);
      if (isObj(now) && !Object.keys(now).length && !(isObj(before) && !Object.keys(before).length)) deleteAt(S.config, holder);
    }
  }
  // Text whose blank means "not set" (as opposed to required text, kept so its error shows).
  const REQUIRED_TEXT = ['name', 'url', 'selector', 'text'];
  function isOptionalText(path) {
    const sp = S.schema && S.schema.settings[path];
    if (sp) return sp.type === 'string';
    const keys = parsePath(path);
    return keys[0] === 'pages' && !REQUIRED_TEXT.includes(keys[keys.length - 1]);
  }

  // ------------------------------------------------------------------ state
  const S = {
    token: '',
    server: null,
    schema: null,
    defaults: null,
    config: null,
    path: '',
    fileName: '',
    savedJson: '',
    hasComments: false,
    tab: 'pages',
    page: 0,
    openAction: -1,
    overridesOpen: false,
    advancedOpen: false,
    issuesOpen: false,
    check: { client: [], errors: [], warnings: [], preview: null, stale: true },
    undo: [],
    redo: [],
    coalesce: null,
    logo: null,
    command: null,
    commandError: '',
    run: { state: 'idle', number: -1, pages: [], notes: [], sessionFlags: [], open: {} },
    // Events of the run shown (appended from GET /api/run?since=), and where to go on from.
    runEvents: [],
    runSince: 0,
    runStarting: false,
    // What a full run / a page test would do now (POST /api/run/plan).
    runPlan: null,
    pagePlan: null,
    // Preview images of the last page test: address -> data: URL (or 'failed').
    previewImages: {},
    pageResults: {},
    capabilities: { browser: false, pick: false, test: false, run: false },
    browser: { connected: false },
    connecting: false,
    // A page is being opened with Go (the server waits for it to load).
    going: false,
    // Results of "Test" per action (key: testKey()), and the one being tested now.
    tests: {},
    testing: '',
    picking: null,
    closed: false,
    drag: -1,
    clickStash: null,
  };
  window.VouchDesigner = { S: S };

  // ------------------------------------------------------------------ texts
  const LATER_BROWSER = 'This needs the audit browser, which is not connected. See the browser line at the top (Retry), or type the address, words or selector yourself.';
  const LATER_RUN = 'Running and testing need the audit browser, which is not connected. See the browser line at the top (Retry), or copy the command from the Run tab into a PowerShell window.';
  const LATER_RUN_HERE = 'Running and testing need the audit browser, which is not connected. See the browser line at the top (Retry), or copy the command below into a PowerShell window.';
  const RUN_ACTIVE = ['starting', 'running', 'waitingForUser', 'stopping'];
  function runActive() { return RUN_ACTIVE.includes(S.run.state) || S.runStarting; }

  const SETTING_LABELS = {
    'name': 'Configuration name',
    'schemaVersion': 'File format version',
    'browser.profileDir': 'Edge profile folder',
    'browser.debugPort': 'Browser connection port',
    'browser.useVirtualDesktop': 'Use a separate virtual desktop',
    'browser.keepBrowserOpen': 'Keep the browser open afterwards',
    'defaults.account': 'Default account',
    'defaults.captureArea': 'Capture area',
    'defaults.zoomPercent': 'Zoom',
    'defaults.navigationTimeoutSec': 'Page load time limit',
    'defaults.settleSeconds': 'Wait after loading',
    'defaults.scrollSettleSeconds': 'Wait after each scroll',
    'defaults.maxScrollSegments': 'Most screenshots per scrolled page',
    'defaults.waitFor': 'Wait for this element on every page',
    'defaults.onNotReady': 'When a page is not ready',
    'defaults.promptTimeoutSec': 'Time to answer a question',
    'output.dir': 'Output folder',
    'output.reportName': 'Report name',
    'output.imageFormat': 'Image format',
    'output.jpegQuality': 'JPEG quality',
    'output.saveImages': 'Save image files',
    'output.embedImages': 'Images in the report',
    'output.jsonSummary': 'JSON summary',
    'output.logDir': 'Console transcript folder',
    'output.failOnWarning': 'Fail on warnings',
    'output.openReport': 'Open the report when done',
    'output.captureLog': 'Write a capture log',
    'output.zip.enabled': 'Make a zip',
    'output.zip.name': 'Zip name',
    'report.title': 'Report title',
    'report.logoPath': 'Logo',
    'report.showIndex': 'Contents list',
    'report.company.name': 'Company name',
    'report.company.details': 'Company details',
    'report.description': 'Description',
    'report.origin': 'Origin',
    'report.generatedBy': 'Generated by',
    'report.period.from': 'Period from',
    'report.period.to': 'Period to',
    'report.period.label': 'Period name',
    'report.classification': 'Classification',
  };
  const PAGE_LABELS = { id: 'Page id', name: 'Page name', url: 'Address (URL)', notes: 'Notes', enabled: 'Capture in full runs', overrides: 'Capture options', actions: 'Actions' };
  const ACTION_LABELS = { type: 'Kind', selector: 'Selector', text: 'Text to click', seconds: 'Seconds', timeoutSec: 'Time limit', message: 'Message', label: 'Label', scroll: 'Scrolling', 'scroll.mode': 'Scrolling', 'scroll.selector': 'Area to scroll', 'scroll.as': 'Image form' };
  const AREA_TEXT = { screen: 'Full screen with the taskbar clock', window: 'Edge window only', page: 'Page content only' };
  const NOT_READY_TEXT = { warn: 'Capture anyway, with a warning', prompt: 'Ask me (Continue / Wait / Skip)' };
  // Settings shown under "Advanced" on the Output tab.
  const ADVANCED = ['defaults.navigationTimeoutSec', 'defaults.settleSeconds', 'defaults.scrollSettleSeconds', 'defaults.maxScrollSegments',
    'defaults.waitFor', 'defaults.onNotReady', 'defaults.promptTimeoutSec', 'browser.debugPort', 'browser.profileDir'];

  function pagesOf(config) { return config && Array.isArray(config.pages) ? config.pages : []; }
  function pageAt(i) { const p = pagesOf(S.config)[i]; return isObj(p) ? p : null; }
  function actionsOf(page) { return page && Array.isArray(page.actions) ? page.actions : []; }
  function pageId(page, index) {
    if (page && typeof page.id === 'string' && page.id.trim()) return page.id.trim();
    return 'p' + String(index + 1).padStart(3, '0');
  }
  function pageName(page, index) {
    const name = page && typeof page.name === 'string' && page.name.trim() ? page.name.trim() : '';
    return name || ('Page ' + (index + 1));
  }
  function actionType(action) {
    if (!isObj(action) || typeof action.type !== 'string') return '';
    const wanted = action.type.trim().toLowerCase();
    return Object.keys(S.schema.actions).find(k => k.toLowerCase() === wanted) || '';
  }
  function canonEnum(allowed, value) {
    if (typeof value !== 'string') return value;
    return (allowed || []).find(a => a.toLowerCase() === value.toLowerCase()) ?? value;
  }
  function spec(path) { return S.schema.settings[path]; }
  // The value a run uses for a run-level setting: the file's, else the default.
  function eff(path) {
    const sp = spec(path);
    const v = getAt(S.config, path);
    if (v === undefined || v === null) return sp ? sp.default : undefined;
    if (typeof v === 'string' && !v.trim() && sp && typeof sp.default === 'string' && sp.default.trim()) return sp.default;
    if (sp && sp.allowed) return canonEnum(sp.allowed, v);
    return v;
  }
  function effOverride(pageIndex, key) {
    const page = pageAt(pageIndex);
    const ov = page && isObj(page.overrides) ? page.overrides[key] : undefined;
    const has = ov !== undefined && ov !== null && !(typeof ov === 'string' && !ov.trim());
    const base = eff('defaults.' + key);
    const sp = spec('defaults.' + key);
    return { has: has, value: has ? (sp && sp.allowed ? canonEnum(sp.allowed, ov) : ov) : base, base: base };
  }
  function fmtNum(n) { return typeof n === 'number' ? String(n) : String(n ?? ''); }
  function shortText(t, max) { t = String(t ?? ''); return t.length > max ? t.slice(0, max - 1) + '…' : t; }

  function labelFor(path) {
    const keys = parsePath(path);
    if (keys[0] === 'pages' && typeof keys[1] === 'number') {
      const i = keys[1];
      const where = 'Page ' + (i + 1) + ' “' + shortText(pageName(pageAt(i), i), 40) + '”';
      if (keys.length === 2) return where;
      if (keys[2] === 'overrides' && keys.length > 3) return where + ' › ' + (SETTING_LABELS['defaults.' + keys[3]] || keys[3]) + ' (this page)';
      if (keys[2] === 'actions' && typeof keys[3] === 'number') {
        const rest = keys.slice(4).join('.');
        return where + ' › Action ' + (keys[3] + 1) + (rest ? ' › ' + (ACTION_LABELS[rest] || rest) : '');
      }
      return where + ' › ' + (PAGE_LABELS[keys[2]] || keys.slice(2).join('.'));
    }
    return SETTING_LABELS[path] || path || 'The configuration';
  }
  function sentence(t) { t = String(t || '').trim(); return t ? t.charAt(0).toUpperCase() + t.slice(1) : t; }
  function plainMessage(m) {
    return sentence(String(m || '').replace(/, without quotes/g, '').replace(/ in double quotes/g, '').replace(/; use a dot for decimals/g, ''));
  }

  function describeAction(action) {
    const type = actionType(action);
    const q = s => '‘' + String(s ?? '') + '’';
    switch (type) {
      case 'click': return 'Click the element ' + (action.selector ? q(action.selector) : '(no selector yet)');
      case 'clickText': return 'Click the text ' + (action.text ? q(action.text) : '(no text yet)');
      case 'wait': return 'Wait ' + fmtNum(action.seconds) + (Number(action.seconds) === 1 ? ' second' : ' seconds');
      case 'waitFor': return 'Wait until ' + (action.selector ? q(action.selector) : '(no selector yet)') + ' appears' +
        (action.timeoutSec !== undefined && action.timeoutSec !== null && action.timeoutSec !== '' ? ' (at most ' + fmtNum(action.timeoutSec) + ' s)' : '');
      case 'pause': return 'Pause and ask me to continue' + (action.message ? ': ' + q(action.message) : '');
      case 'capture': {
        const scroll = isObj(action.scroll) ? action.scroll : {};
        const mode = canonEnum(['none', 'auto', 'page', 'area'], scroll.mode || 'none');
        let what = { none: 'what is visible', auto: 'auto-detect what scrolls', page: 'whole page by scrolling', area: 'the area ' + q(scroll.selector || '?') + ' by scrolling' }[mode] || String(mode);
        if (mode !== 'none' && String(scroll.as || '').toLowerCase() === 'single') what += ', as one tall image';
        return 'Capture: ' + what + (action.label ? ' — ' + q(action.label) : '');
      }
      default: return 'Unknown action ' + q(isObj(action) ? action.type : action) + ' (kept as written)';
    }
  }

  // ------------------------------------------------------------------ API
  class ApiError extends Error {
    constructor(status, message, detail, data) { super(message); this.status = status; this.detail = detail || ''; this.data = data || null; }
  }
  async function api(method, path, body) {
    const options = { method: method, headers: { 'X-Vouch-Token': S.token }, cache: 'no-store', credentials: 'omit' };
    if (body !== undefined) { options.headers['Content-Type'] = 'application/json'; options.body = JSON.stringify(body); }
    let response;
    try { response = await fetch(path, options); }
    catch (e) { throw new ApiError(0, 'The Designer is not answering.', 'It may have been closed. Start the Vouch Designer again; your last saved file is safe.'); }
    let data = null;
    try { data = await response.json(); } catch (e) { data = null; }
    if (!response.ok) {
      throw new ApiError(response.status, (data && data.error) || ('The Designer answered with an error (' + response.status + ').'), data && data.detail, data);
    }
    return data;
  }
  window.VouchDesigner.api = api;

  // ------------------------------------------------------------------ toast, announcer, modal
  let toastTimer = 0;
  function toast(text, action) {
    const el = $('#toast');
    el.replaceChildren(h('span', { text: text }));
    if (action) {
      el.appendChild(h('button', { type: 'button', class: 'btn btn-small', text: action.label, onclick: () => { el.hidden = true; action.run(); } }));
    }
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, action ? 9000 : 5000);
  }
  function announce(text) {
    const el = $('#announcer');
    el.textContent = '';
    setTimeout(() => { el.textContent = text; }, 30);
  }
  function ask(options) {
    const dialog = $('#modal');
    $('#modal-title').textContent = options.title;
    const body = $('#modal-body');
    body.replaceChildren();
    for (const part of [].concat(options.body || [])) append(body, typeof part === 'string' ? h('p', { text: part }) : part);
    const buttons = $('#modal-buttons');
    buttons.replaceChildren();
    return new Promise(resolve => {
      let done = false;
      const finish = value => { if (done) return; done = true; if (dialog.open) dialog.close(); resolve(value); };
      for (const b of options.buttons) {
        buttons.appendChild(h('button', {
          type: 'button', class: 'btn' + (b.primary ? ' btn-primary' : '') + (b.danger ? ' btn-danger' : ''),
          text: b.label, onclick: () => finish(b.value),
        }));
      }
      // A close event of the question before this one may still be on its way while this
      // one is already shown: only a close that leaves the dialog closed answers.
      dialog.onclose = () => { if (!dialog.open) finish(options.cancelValue); };
      dialog.oncancel = () => finish(options.cancelValue);
      dialog.showModal();
      const first = buttons.querySelector('.btn-primary') || buttons.querySelector('button');
      if (first) first.focus();
    });
  }
  function showError(error, title) {
    const parts = [];
    if (error && error.detail) parts.push(String(error.detail));
    if (error && error.data && Array.isArray(error.data.problems) && error.data.problems.length) {
      parts.push(h('ul', { class: 'plain-list' }, error.data.problems.map(p => h('li', { text: p }))));
    }
    return ask({ title: title || (error && error.message) || 'Something went wrong.', body: parts.length ? parts : [String(error && error.message || error)], buttons: [{ label: 'OK', value: true, primary: true }], cancelValue: true });
  }

  // ------------------------------------------------------------------ focus keeping
  // Structural changes re-render a whole tab; the focused control (data-fkey) and its
  // caret are put back so keyboard users do not lose their place.
  function keepFocus(fn) {
    const active = document.activeElement;
    const key = active && active.dataset ? active.dataset.fkey : '';
    let start = null, end = null;
    try { start = active.selectionStart; end = active.selectionEnd; } catch (e) { start = null; }
    fn();
    if (!key) return;
    const again = $$('[data-fkey]').find(el => el.dataset.fkey === key);
    if (again && again !== document.activeElement) {
      again.focus({ preventScroll: true });
      try { if (start !== null) again.setSelectionRange(start, end); } catch (e) { /* not a text field */ }
    }
  }
  function focusKey(key) {
    const el = $$('[data-fkey]').find(e => e.dataset.fkey === key);
    if (el) { el.focus(); return true; }
    return false;
  }

  // ------------------------------------------------------------------ changes, undo, dirty
  function snapshot() { return { json: JSON.stringify(S.config), page: S.page, tab: S.tab }; }
  /*
    Every edit goes through change(): one undo step per edit (typing in one field within
    1.5 s is one step), then the dirty marker, the checks and the command box follow.
    render: 'all' re-renders the current tab; 'light' only updates what shows the value
    elsewhere (for typing, so the caret and an input method are never disturbed).
  */
  function change(mutate, options) {
    options = options || {};
    const now = Date.now();
    const merge = options.coalesce && S.coalesce && S.coalesce.key === options.coalesce && now - S.coalesce.at < 1500;
    if (!merge) {
      S.undo.push(snapshot());
      if (S.undo.length > 200) S.undo.shift();
    }
    S.coalesce = options.coalesce ? { key: options.coalesce, at: now } : null;
    S.redo = [];
    mutate(S.config);
    afterChange(options.render || 'all');
  }
  function afterChange(render) {
    S.check.stale = true;
    runClientChecks();
    if (render === 'all') renderAll();
    else lightRender();
    scheduleValidate();
    scheduleCommand();
    scheduleRunPlan();
  }
  function restore(entry) {
    S.config = JSON.parse(entry.json);
    S.page = Math.min(entry.page, Math.max(0, pagesOf(S.config).length - 1));
    S.tab = entry.tab || S.tab;
    S.openAction = -1;
    S.coalesce = null;
    afterChange('all');
  }
  function undo() {
    if (!S.undo.length) { toast('There is nothing to undo.'); return; }
    S.redo.push(snapshot());
    restore(S.undo.pop());
    announce('Undone.');
  }
  function redo() {
    if (!S.redo.length) { toast('There is nothing to redo.'); return; }
    S.undo.push(snapshot());
    restore(S.redo.pop());
    announce('Redone.');
  }
  function isDirty() { return S.config !== null && JSON.stringify(S.config) !== S.savedJson; }

  // ------------------------------------------------------------------ checks
  function parseNumber(text, whole) {
    const t = String(text).trim().replace(',', '.');
    if (!/^-?\d+(\.\d+)?$/.test(t) && !/^-?\.\d+$/.test(t)) return null;
    const n = Number(t);
    if (!Number.isFinite(n)) return null;
    if (whole && !Number.isInteger(n)) return null;
    return n;
  }
  function rangeText(sp) {
    const kind = sp.type === 'int' ? 'a whole number' : 'a number';
    return 'Enter ' + kind + ' from ' + sp.min + ' to ' + sp.max + '.';
  }
  function checkNumber(list, path, value, sp) {
    if (value === undefined || value === null || !sp || (sp.type !== 'int' && sp.type !== 'number')) return;
    if (typeof value !== 'number' || (sp.type === 'int' && !Number.isInteger(value)) || value < sp.min || value > sp.max) {
      list.push({ path: path, message: rangeText(sp), client: true });
    }
  }
  /* Immediate checks in the panel; the engine's own check (/api/config/validate) follows. */
  function runClientChecks() {
    const list = [];
    if (!S.config || !S.schema) { S.check.client = list; return; }
    for (const path of Object.keys(S.schema.settings)) checkNumber(list, path, getAt(S.config, path), spec(path));
    const seen = {};
    pagesOf(S.config).forEach((page, i) => {
      if (!isObj(page)) return;
      if (typeof page.name !== 'string' || !page.name.trim()) list.push({ path: P('pages', i, 'name'), message: 'Every page needs a name.', client: true });
      if (typeof page.url !== 'string' || !page.url.trim()) list.push({ path: P('pages', i, 'url'), message: 'Every page needs an address.', client: true });
      else if (!/^https?:\/\/\S/i.test(page.url.trim())) list.push({ path: P('pages', i, 'url'), message: 'The address must start with http:// or https://.', client: true });
      const id = pageId(page, i).toLowerCase();
      if (seen[id] !== undefined) list.push({ path: P('pages', i, 'id'), message: 'Page ' + (seen[id] + 1) + ' already uses the id “' + pageId(page, i) + '”. Every page needs its own id.', client: true });
      else seen[id] = i;
      if (isObj(page.overrides)) {
        for (const key of Object.keys(page.overrides)) checkNumber(list, P('pages', i, 'overrides', key), page.overrides[key], spec('defaults.' + key));
      }
      actionsOf(page).forEach((action, j) => {
        const type = actionType(action);
        const base = P('pages', i, 'actions', j);
        const blank = v => typeof v !== 'string' || !v.trim();
        if (type === 'click' && blank(action.selector)) list.push({ path: base + '.selector', message: 'Enter the selector of what to click.', client: true });
        if (type === 'clickText' && blank(action.text)) list.push({ path: base + '.text', message: 'Enter the words shown on what to click.', client: true });
        if (type === 'waitFor' && blank(action.selector)) list.push({ path: base + '.selector', message: 'Enter the selector of the element to wait for.', client: true });
        if (type === 'wait') checkNumber(list, base + '.seconds', action.seconds ?? '', S.schema.actions.wait.seconds);
        if (type === 'waitFor') checkNumber(list, base + '.timeoutSec', action.timeoutSec, S.schema.actions.waitFor.timeoutSec);
        if (type === 'capture' && isObj(action.scroll) && String(action.scroll.mode || '').toLowerCase() === 'area' && blank(action.scroll.selector)) {
          list.push({ path: base + '.scroll.selector', message: 'Enter the selector of the area to scroll.', client: true });
        }
      });
    });
    S.check.client = list;
  }
  // One problem per path: the panel's own wording first, then the engine's.
  function problems() {
    const byPath = new Map();
    for (const p of S.check.client) if (!byPath.has(p.path)) byPath.set(p.path, { path: p.path, text: p.message, level: 'error' });
    if (!S.check.stale) {
      for (const p of S.check.errors) if (!byPath.has(p.path)) byPath.set(p.path, { path: p.path, text: plainMessage(p.text || p.message), level: 'error' });
    }
    const errors = Array.from(byPath.values());
    const warnings = (S.check.stale ? [] : S.check.warnings).filter(w => !byPath.has(w.path))
      .map(w => ({ path: w.path, text: plainMessage(w.text || w.message), level: 'warning' }));
    return { errors: errors, warnings: warnings };
  }
  let validateTimer = 0, validateSeq = 0;
  function scheduleValidate() { clearTimeout(validateTimer); validateTimer = setTimeout(validateNow, 350); }
  let validating = null;
  // Resolves once the newest check has been applied (a later one supersedes an earlier one).
  async function validateNow() {
    if (!S.config || S.closed) return;
    clearTimeout(validateTimer);
    const seq = ++validateSeq;
    const run = (async () => {
      try {
        const result = await api('POST', '/api/config/validate', { config: S.config });
        if (seq !== validateSeq) return;
        S.check.errors = result.errors || [];
        S.check.warnings = result.warnings || [];
        S.check.preview = result.preview || null;
        S.check.stale = false;
        lightRender();
      } catch (e) { if (e.status === 0) serverGone(); }
    })();
    validating = run;
    let last = run;
    await last;
    while (validating !== last) { last = validating; await last; }
  }
  window.VouchDesigner.validateNow = validateNow;

  // ------------------------------------------------------------------ field builders
  function errorSlot(path) { return h('p', { class: 'field-error', id: uid('err'), dataset: { errFor: path }, hidden: true }); }
  function wireDescribed(input, helpEl, errEl) {
    const ids = [helpEl && helpEl.id, errEl && errEl.id].filter(Boolean).join(' ');
    if (ids) input.setAttribute('aria-describedby', ids);
  }
  /*
    o: { path, label, help, kind: 'text'|'number'|'textarea', whole, placeholder, value,
         commit(rawText) (default: set the path), extra (nodes after the input), badge }
  */
  function textField(o) {
    const id = uid('f');
    const current = o.value !== undefined ? o.value : getAt(S.config, o.path);
    const shown = current === undefined || current === null ? '' : (typeof current === 'object' ? JSON.stringify(current) : String(current));
    const helpEl = o.help ? h('p', { class: 'help', id: uid('help'), text: o.help }) : null;
    const errEl = errorSlot(o.path);
    const input = h(o.kind === 'textarea' ? 'textarea' : 'input', {
      id: id, class: 'input' + (o.mono ? ' mono' : ''), value: shown, placeholder: o.placeholder || '',
      type: o.kind === 'textarea' ? null : 'text', inputmode: o.kind === 'number' ? (o.whole ? 'numeric' : 'decimal') : null,
      rows: o.kind === 'textarea' ? (o.rows || 3) : null, spellcheck: o.mono ? 'false' : null, autocomplete: 'off',
      dataset: { path: o.path, fkey: o.fkey || o.path },
    });
    input.addEventListener('input', () => {
      const raw = input.value;
      change(() => (o.commit ? o.commit(raw) : commitText(o, raw)), { coalesce: o.path, render: 'light' });
    });
    wireDescribed(input, helpEl, errEl);
    return h('div', { class: 'field' + (o.narrow ? ' field-narrow' : '') },
      h('div', { class: 'label-row' }, h('label', { for: id, text: o.label }), o.badge || null),
      o.extra ? h('div', { class: 'control-row' }, input, o.extra) : input,
      helpEl, errEl);
  }
  function commitText(o, raw) {
    if (o.kind === 'number') {
      if (!raw.trim()) { clearValue(o.path); return; }
      const n = parseNumber(raw, o.whole);
      setAt(S.config, o.path, n === null ? raw : n);
      return;
    }
    if (raw === '' && isOptionalText(o.path)) { clearValue(o.path); return; }
    setAt(S.config, o.path, raw);
  }
  function checkField(o) {
    const id = uid('f');
    const value = o.value !== undefined ? o.value : !!eff(o.path);
    const helpEl = o.help ? h('p', { class: 'help', id: uid('help'), text: o.help }) : null;
    const errEl = errorSlot(o.path);
    const input = h('input', { type: 'checkbox', id: id, class: 'check', checked: value, dataset: { path: o.path, fkey: o.fkey || o.path } });
    input.addEventListener('change', () => change(() => (o.commit ? o.commit(input.checked) : setAt(S.config, o.path, o.invert ? !input.checked : input.checked)), { render: 'all' }));
    wireDescribed(input, helpEl, errEl);
    return h('div', { class: 'field field-check' }, h('div', { class: 'check-row' }, input, h('label', { for: id, text: o.label }), o.badge || null), helpEl, errEl);
  }
  /* options: [{value, label, help}] shown as radio buttons with an explanation each. */
  function radioField(o) {
    const name = uid('r');
    const value = o.value !== undefined ? o.value : eff(o.path);
    const legendId = uid('lg');
    const errEl = errorSlot(o.path);
    const helpEl = o.help ? h('p', { class: 'help', id: uid('help'), text: o.help }) : null;
    const group = h('div', { class: 'radio-group', role: 'radiogroup', 'aria-labelledby': legendId });
    o.options.forEach(opt => {
      const id = uid('o');
      const descId = opt.help ? uid('d') : null;
      const input = h('input', { type: 'radio', name: name, id: id, value: opt.value, checked: opt.value === value, class: 'radio', 'aria-describedby': descId, dataset: { path: o.path, fkey: o.path + '=' + opt.value } });
      input.addEventListener('change', () => { if (input.checked) change(() => (o.commit ? o.commit(opt.value) : setAt(S.config, o.path, opt.value)), { render: 'all' }); });
      group.appendChild(h('div', { class: 'radio-row' }, input, h('div', {},
        h('label', { for: id, text: opt.label }), opt.help ? h('p', { class: 'help', id: descId, text: opt.help }) : null)));
    });
    return h('div', { class: 'field field-radio' }, h('div', { class: 'label-row' }, h('span', { class: 'legend', id: legendId, text: o.label }), o.badge || null), helpEl, group, errEl);
  }
  function selectField(o) {
    const id = uid('f');
    const value = o.value !== undefined ? o.value : eff(o.path);
    const helpEl = o.help ? h('p', { class: 'help', id: uid('help'), text: o.help }) : null;
    const errEl = errorSlot(o.path);
    const select = h('select', { id: id, class: 'input', dataset: { path: o.path, fkey: o.path } });
    const values = o.options.map(x => x.value);
    if (value !== undefined && !values.includes(value)) select.appendChild(h('option', { value: String(value), text: String(value) + ' (not a known choice)' }));
    o.options.forEach(opt => select.appendChild(h('option', { value: opt.value, text: opt.label })));
    select.value = value === undefined ? '' : String(value);
    select.addEventListener('change', () => change(() => (o.commit ? o.commit(select.value) : setAt(S.config, o.path, select.value)), { render: 'all' }));
    wireDescribed(select, helpEl, errEl);
    return h('div', { class: 'field' }, h('div', { class: 'label-row' }, h('label', { for: id, text: o.label }), o.badge || null), o.extra ? h('div', { class: 'control-row' }, select, o.extra) : select, helpEl, errEl);
  }
  function btn(label, onclick, o) {
    o = o || {};
    const b = h('button', {
      type: 'button', class: 'btn' + (o.primary ? ' btn-primary' : '') + (o.small ? ' btn-small' : '') + (o.danger ? ' btn-danger' : '') + (o.later ? ' btn-later' : ''),
      'aria-label': o.aria || null, title: o.title || null, 'aria-disabled': o.later || o.disabled ? 'true' : null,
      'aria-pressed': o.pressed === undefined ? null : String(o.pressed), 'aria-expanded': o.expanded === undefined ? null : String(o.expanded),
      'aria-controls': o.controls || null, dataset: { fkey: o.fkey || ('btn:' + label) },
    }, label);
    b.addEventListener('click', ev => {
      if (o.later) { ev.preventDefault(); toast(o.later); return; }
      if (o.disabled) { ev.preventDefault(); return; }
      onclick(ev);
    });
    return b;
  }
  function section(title, intro, children, o) {
    o = o || {};
    const headingId = uid('h');
    return h('section', { class: 'card' + (o.class ? ' ' + o.class : ''), 'aria-labelledby': headingId },
      h('h2', { class: 'card-title', id: headingId, text: title }),
      intro ? h('p', { class: 'card-intro', text: intro }) : null,
      children);
  }
  function disclosure(title, open, onToggle, children, fkey) {
    const panelId = uid('dp');
    const button = h('button', { type: 'button', class: 'disclosure', 'aria-expanded': String(!!open), 'aria-controls': panelId, dataset: { fkey: fkey } },
      h('span', { class: 'disclosure-mark', 'aria-hidden': 'true', text: open ? '▾' : '▸' }), title);
    button.addEventListener('click', () => { onToggle(!open); keepFocus(renderAll); });
    return h('div', { class: 'disclosure-wrap' }, button, h('div', { id: panelId, class: 'disclosure-body', hidden: !open }, children));
  }
  function laterNote(text) { return h('p', { class: 'later-note', text: text }); }

  // ------------------------------------------------------------------ header and tabs
  const TABS = [['pages', 'Pages'], ['output', 'Output'], ['report', 'Report'], ['run', 'Run']];
  function buildChrome() {
    const bar = $('#file-toolbar');
    bar.replaceChildren(
      btn('New', () => newConfig(), { title: 'Start a new configuration' }),
      btn('Open…', () => openConfig(), { title: 'Open a configuration file (.json)' }),
      btn('Save', () => save(false), { primary: true, title: 'Save (Ctrl+S)', fkey: 'tb:save' }),
      btn('Save as…', () => save(true), { title: 'Save under a new name' }),
      btn('Import CSV…', () => importCsv(), { title: 'Add the pages of a capture list (CSV)' }),
      h('span', { class: 'toolbar-gap' }),
      btn('Undo', () => undo(), { small: true, title: 'Undo (Ctrl+Z)', fkey: 'tb:undo' }),
      btn('Redo', () => redo(), { small: true, title: 'Redo (Ctrl+Y)', fkey: 'tb:redo' }),
      btn('Close', () => closeDesigner(), { small: true, title: 'Close the Vouch Designer' }));
    const tabs = $('#tabs');
    tabs.replaceChildren();
    TABS.forEach(([key, label]) => {
      const tab = h('button', { type: 'button', role: 'tab', id: 'tab-' + key, class: 'tab', 'aria-controls': 'panel-' + key, dataset: { tab: key, fkey: 'tab:' + key } }, label);
      tab.addEventListener('click', () => setTab(key));
      tab.addEventListener('keydown', ev => {
        const i = TABS.findIndex(t => t[0] === key);
        let next = -1;
        if (ev.key === 'ArrowRight') next = (i + 1) % TABS.length;
        else if (ev.key === 'ArrowLeft') next = (i + TABS.length - 1) % TABS.length;
        else if (ev.key === 'Home') next = 0;
        else if (ev.key === 'End') next = TABS.length - 1;
        if (next >= 0) { ev.preventDefault(); setTab(TABS[next][0]); $('#tab-' + TABS[next][0]).focus(); }
      });
      tabs.appendChild(tab);
    });
  }
  function setTab(key) {
    S.tab = key;
    renderAll();
    if (key === 'run') { refreshCommand(); refreshRunPlan(); }
  }
  function renderHeader() {
    const dirty = isDirty();
    $('#file-title').textContent = S.fileName || 'New configuration';
    $('#dirty-marker').hidden = !dirty;
    $('#file-path').textContent = S.path ? S.path : 'Not saved to a file yet';
    document.title = (dirty ? '* ' : '') + (S.fileName || 'New configuration') + ' – Vouch Designer';
    for (const [key] of TABS) {
      const tab = $('#tab-' + key);
      const selected = key === S.tab;
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
      $('#panel-' + key).hidden = !selected;
    }
  }

  // ------------------------------------------------------------------ issues
  function renderIssues() {
    const box = $('#issues');
    const pr = problems();
    const total = pr.errors.length + pr.warnings.length;
    if (!total) { box.hidden = true; box.replaceChildren(); return; }
    box.hidden = false;
    const parts = [];
    if (pr.errors.length) parts.push(pr.errors.length + (pr.errors.length === 1 ? ' problem to fix' : ' problems to fix'));
    if (pr.warnings.length) parts.push(pr.warnings.length + (pr.warnings.length === 1 ? ' note' : ' notes'));
    const listId = 'issues-list';
    const toggle = h('button', { type: 'button', class: 'issues-toggle' + (pr.errors.length ? ' has-errors' : ''), 'aria-expanded': String(S.issuesOpen), 'aria-controls': listId, dataset: { fkey: 'issues-toggle' } },
      h('span', { 'aria-hidden': 'true', class: 'disclosure-mark', text: S.issuesOpen ? '▾' : '▸' }), parts.join(' · '),
      pr.errors.length ? h('span', { class: 'issues-hint', text: ' — saving needs them fixed' }) : null);
    toggle.addEventListener('click', () => { S.issuesOpen = !S.issuesOpen; keepFocus(renderIssues); });
    const list = h('ul', { id: listId, class: 'issues-list', hidden: !S.issuesOpen });
    for (const p of pr.errors.concat(pr.warnings)) {
      list.appendChild(h('li', { class: 'issue issue-' + p.level },
        h('button', { type: 'button', class: 'issue-link', onclick: () => jumpTo(p.path), dataset: { fkey: 'issue:' + p.path } },
          h('span', { class: 'issue-level', text: p.level === 'error' ? 'Problem' : 'Note' }),
          h('span', { class: 'issue-where', text: labelFor(p.path) + ': ' }), p.text)));
    }
    keepFocus(() => box.replaceChildren(toggle, list));
  }
  function applyFieldErrors() {
    const pr = problems();
    const map = new Map();
    for (const p of pr.errors.concat(pr.warnings)) if (!map.has(p.path)) map.set(p.path, p);
    for (const slot of $$('[data-err-for]')) {
      const p = map.get(slot.dataset.errFor);
      slot.hidden = !p;
      slot.textContent = p ? p.text : '';
      slot.classList.toggle('is-warning', !!p && p.level === 'warning');
    }
    for (const input of $$('[data-path]')) {
      const p = map.get(input.dataset.path);
      if (p && p.level === 'error') input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
    }
  }
  /* Opens the tab, page, section and editor a problem belongs to, then focuses its field. */
  function jumpTo(path) {
    const keys = parsePath(path);
    if (keys[0] === 'pages') {
      S.tab = 'pages';
      if (typeof keys[1] === 'number') S.page = keys[1];
      if (keys[2] === 'overrides') S.overridesOpen = true;
      S.openAction = keys[2] === 'actions' && typeof keys[3] === 'number' ? keys[3] : -1;
    }
    else if (path.startsWith('report.') || path === 'defaults.account' || path === 'name') S.tab = 'report';
    else if (path.startsWith('output.') || path.startsWith('defaults.') || path.startsWith('browser.')) {
      S.tab = 'output';
      if (ADVANCED.includes(path)) S.advancedOpen = true;
    }
    renderAll();
    for (let n = keys.length; n > 0; n--) {
      const candidate = P.apply(null, keys.slice(0, n));
      const el = $$('[data-path]').find(e => e.dataset.path === candidate);
      if (el) { el.focus(); el.scrollIntoView({ block: 'center' }); return; }
    }
  }

  // ------------------------------------------------------------------ rendering
  function renderAll() {
    if (!S.config) return;
    keepFocus(() => {
      renderHeader();
      renderBrowser();
      const render = { pages: renderPages, output: renderOutput, report: renderReport, run: renderRun }[S.tab];
      for (const [key] of TABS) if (key !== S.tab) $('#panel-' + key).replaceChildren();
      render();
      renderIssues();
      applyFieldErrors();
      updatePreviews();
    });
  }
  // After typing: everything that shows the value elsewhere, but not the field being typed in.
  function lightRender() {
    if (!S.config) return;
    renderHeader();
    if (S.tab === 'pages') { const list = $('#page-list-wrap'); if (list) keepFocus(() => list.replaceWith(pageListBlock())); }
    for (const el of $$('[data-summary-for]')) {
      const action = getAt(S.config, el.dataset.summaryFor);
      el.textContent = describeAction(action);
    }
    for (const el of $$('[data-page-heading]')) el.textContent = pageName(pageAt(S.page), S.page);
    renderIssues();
    applyFieldErrors();
    updatePreviews();
    if (S.tab === 'run') renderCommandBox();
  }
  function updatePreviews() {
    const pv = S.check.preview;
    for (const el of $$('[data-preview]')) {
      const kind = el.dataset.preview;
      let text = '';
      if (kind === 'report') {
        text = pv ? 'A run now would save the report as: ' + pv.reportFile : (S.check.stale ? 'Working out the report name…' : 'The report name is shown here once the problems are fixed.');
        if (pv && pv.reportUnknown && pv.reportUnknown.length) text += ' (Vouch does not know ' + pv.reportUnknown.join(', ') + '; it is kept as written.)';
        if (pv && pv.reportChanged) text += ' Characters Windows does not allow in file names were replaced.';
      }
      else if (kind === 'zip') {
        text = pv ? 'A run now would make: ' + pv.zipFile : '';
        if (pv && pv.zipUnknown && pv.zipUnknown.length) text += ' (Vouch does not know ' + pv.zipUnknown.join(', ') + '; it is kept as written.)';
      }
      el.textContent = text;
    }
  }

  // ------------------------------------------------------------------ Pages tab
  /* The page's last test or run result in this session (from the server), with its time. */
  function pageStatus(page, i) {
    const result = S.pageResults[pageId(page, i)];
    if (!result) return { text: 'Not tested', cls: 'chip-muted', title: '' };
    const status = String(result.status || '').toUpperCase();
    const what = result.kind === 'page' ? 'Test' : 'Run';
    const word = status === 'OK' ? what + ' OK' : status === 'WARNING' ? what + ': warning' : status === 'FAILED' ? what + ' failed' : status === 'NOTFINISHED' ? what + ': not finished' : what + ': ' + String(result.status);
    return { text: word + (result.time ? ' ' + result.time : ''), cls: status === 'NOTFINISHED' ? 'chip-muted' : 'chip-' + status.toLowerCase(), title: result.text || '' };
  }
  function pageErrorCount(i) {
    const prefix = P('pages', i);
    return problems().errors.filter(p => p.path === prefix || p.path.startsWith(prefix + '.') || p.path.startsWith(prefix + '[')).length;
  }
  function pageListBlock() {
    const pages = pagesOf(S.config);
    const list = h('ol', { class: 'page-list', 'aria-label': 'Pages, in the order they are captured' });
    pages.forEach((page, i) => {
      const valid = isObj(page);
      const selected = i === S.page;
      const errors = pageErrorCount(i);
      const status = valid ? pageStatus(page, i) : { text: '', cls: '' };
      const enabled = !valid || page.enabled !== false;
      const select = h('button', {
        type: 'button', class: 'page-select', 'aria-current': selected ? 'true' : null, dataset: { fkey: 'page-select:' + i },
        title: 'Alt+Up / Alt+Down moves the page',
      },
        h('span', { class: 'page-num', text: (i + 1) + '.' }),
        h('span', { class: 'page-main' },
          h('span', { class: 'page-name', text: valid ? pageName(page, i) : '(not a page: kept as written)' }),
          h('span', { class: 'page-url', text: valid && typeof page.url === 'string' ? page.url : '' })),
        h('span', { class: 'page-chips' },
          errors ? h('span', { class: 'chip chip-failed', text: errors === 1 ? '1 problem' : errors + ' problems' }) : null,
          !enabled ? h('span', { class: 'chip chip-muted', text: 'Off' }) : null,
          status.text ? h('span', { class: 'chip ' + status.cls, text: status.text, title: status.title || null }) : null));
      select.addEventListener('click', () => selectPage(i));
      select.addEventListener('keydown', ev => {
        if (ev.altKey && (ev.key === 'ArrowUp' || ev.key === 'ArrowDown')) { ev.preventDefault(); movePage(i, ev.key === 'ArrowUp' ? i - 1 : i + 1, true); return; }
        let target = -1;
        if (ev.key === 'ArrowUp') target = i - 1;
        else if (ev.key === 'ArrowDown') target = i + 1;
        else if (ev.key === 'Home') target = 0;
        else if (ev.key === 'End') target = pages.length - 1;
        if (target >= 0 && target < pages.length) { ev.preventDefault(); selectPage(target); focusKey('page-select:' + target); }
      });
      const enable = h('input', {
        type: 'checkbox', class: 'check', checked: enabled, disabled: !valid,
        'aria-label': 'Capture “' + (valid ? pageName(page, i) : 'page ' + (i + 1)) + '” in full runs', dataset: { fkey: 'page-enable:' + i, path: P('pages', i, 'enabled') },
      });
      enable.addEventListener('change', () => change(c => { c.pages[i].enabled = enable.checked; }, { render: 'all' }));
      const row = h('li', { class: 'page-row' + (selected ? ' is-selected' : '') + (enabled ? '' : ' is-off'), draggable: 'true', dataset: { index: String(i) } },
        h('span', { class: 'grip', 'aria-hidden': 'true', title: 'Drag to move' }), enable, select);
      row.addEventListener('dragstart', ev => { S.drag = i; ev.dataTransfer.effectAllowed = 'move'; ev.dataTransfer.setData('text/plain', String(i)); row.classList.add('is-dragging'); });
      row.addEventListener('dragend', () => { S.drag = -1; $$('.page-row').forEach(r => r.classList.remove('is-dragging', 'drop-before', 'drop-after')); });
      row.addEventListener('dragover', ev => {
        if (S.drag < 0) return;
        ev.preventDefault();
        const box = row.getBoundingClientRect();
        const after = ev.clientY > box.top + box.height / 2;
        row.classList.toggle('drop-after', after);
        row.classList.toggle('drop-before', !after);
      });
      row.addEventListener('dragleave', () => row.classList.remove('drop-before', 'drop-after'));
      row.addEventListener('drop', ev => {
        ev.preventDefault();
        const from = S.drag;
        const box = row.getBoundingClientRect();
        let to = ev.clientY > box.top + box.height / 2 ? i + 1 : i;
        if (from < to) to -= 1;
        S.drag = -1;
        if (from >= 0 && from !== to) movePage(from, to, false);
        else renderAll();
      });
      list.appendChild(row);
    });
    return h('div', { id: 'page-list-wrap' }, pages.length ? list : h('p', { class: 'empty', text: 'No pages yet. Add one below, or import a capture list (CSV).' }));
  }
  function renderPages() {
    const panel = $('#panel-pages');
    // The kept-aside click value lives only as long as its editor is open.
    if (S.clickStash && S.clickStash.path !== P('pages', S.page, 'actions', S.openAction)) S.clickStash = null;
    const pages = pagesOf(S.config);
    if (S.page >= pages.length) S.page = Math.max(0, pages.length - 1);
    const listCol = h('div', { class: 'pages-list-col' },
      h('div', { class: 'col-head' },
        h('h2', { class: 'card-title', text: 'Pages (' + pages.length + ')' }),
        h('p', { class: 'card-intro', text: 'Captured from top to bottom. Drag a page, or use Alt+Up / Alt+Down, to change the order.' })),
      pageListBlock(),
      h('div', { class: 'button-row' },
        btn('Add blank page', () => addPage(), { primary: true, fkey: 'add-page' }),
        btn('Add page from current tab', () => addPageFromCurrentTab(), { later: S.capabilities.browser ? null : LATER_BROWSER, fkey: 'add-from-tab', title: 'Adds the page shown in the audit Edge window, with its title as the name' })),
      S.capabilities.browser ? null : laterNote('“Add page from current tab” works once the audit browser is connected (see the top of this window).'));
    const editor = pages.length ? pageEditor(S.page) : h('div', { class: 'card empty-editor' }, h('p', { text: 'Add a page to start. A page is one web address to capture, with the clicks and waits needed before the screenshot.' }));
    panel.replaceChildren(h('div', { class: 'pages-layout' }, listCol, h('div', { class: 'pages-editor-col' }, editor)));
  }
  function pageEditor(i) {
    const page = pageAt(i);
    const pages = pagesOf(S.config);
    if (!page) {
      return section('Page ' + (i + 1), 'This entry is not a page object, so it cannot be edited here. It is kept in the file as written.',
        h('div', { class: 'button-row' }, btn('Delete it', () => deletePage(i), { danger: true })));
    }
    const base = P('pages', i);
    const headerButtons = h('div', { class: 'button-row tight' },
      btn('Move up', () => movePage(i, i - 1, true), { small: true, disabled: i === 0, fkey: 'page-up' }),
      btn('Move down', () => movePage(i, i + 1, true), { small: true, disabled: i === pages.length - 1, fkey: 'page-down' }),
      btn('Duplicate', () => duplicatePage(i), { small: true, fkey: 'page-dup' }),
      btn('Delete', () => deletePage(i), { small: true, danger: true, fkey: 'page-del' }));
    const goButton = btn(S.going ? 'Opening…' : 'Go', () => goToUrl(i), { small: true, later: S.capabilities.browser ? null : LATER_BROWSER, disabled: S.going, title: 'Open this address in the audit browser, at the zoom the run will use', fkey: 'go' });
    const accountInfo = effOverride(i, 'account');
    const details = h('div', { class: 'card page-card' },
      h('div', { class: 'card-head' },
        h('div', {}, h('p', { class: 'eyebrow', text: 'Page ' + (i + 1) + ' of ' + pages.length }),
          h('h2', { class: 'card-title', dataset: { pageHeading: '1' }, text: pageName(page, i) })),
        headerButtons),
      textField({ path: base + '.name', label: 'Name', help: 'A short label for this evidence; it is the heading in the report.' }),
      textField({ path: base + '.url', label: 'Address (URL)', help: 'Copy it from the browser’s address bar. It must start with https:// or http://.', mono: true, extra: goButton, placeholder: 'https://' }),
      textField({ path: base + '.notes', label: 'Notes', kind: 'textarea', rows: 2, help: 'Shown with the screenshots in the report, for example the control number or what to look at.' }),
      h('div', { class: 'field-pair' },
        textField({
          path: base + '.overrides.account', label: 'Account for this page', value: accountInfo.has ? accountInfo.value : '',
          placeholder: accountInfo.base ? accountInfo.base + ' (default)' : 'The default account',
          help: 'Only when this page is captured with another sign-in than the default (Report tab).',
          commit: raw => { if (raw.trim()) setAt(S.config, base + '.overrides.account', raw); else clearValue(base + '.overrides.account'); },
        }),
        textField({ path: base + '.id', label: 'Page id', placeholder: pageId(page, i), narrow: true, mono: true, help: 'Used to run one page (-Only ' + pageId(page, i) + ').' })),
      checkField({ path: base + '.enabled', label: 'Capture this page in full runs', value: page.enabled !== false, help: 'Switch off to keep a page in the file without capturing it. “Test this page” still works.' }),
      overridesBlock(i),
      actionsBlock(i),
      h('div', { class: 'test-row' },
        btn('Test this page', () => startRun('page'), { later: S.capabilities.run ? null : LATER_RUN, disabled: runActive(), fkey: 'test-page', title: 'Runs this page alone, as a run would, and shows the screenshots in the Run tab' }),
        h('span', { class: 'chip ' + pageStatus(page, i).cls, text: pageStatus(page, i).text, title: pageStatus(page, i).title || null })));
    return details;
  }
  const OVERRIDE_FIELDS = [
    { key: 'captureArea', kind: 'select' },
    { key: 'zoomPercent', kind: 'number', unit: '%' },
    { key: 'waitFor', kind: 'text', pick: true },
    { key: 'onNotReady', kind: 'select' },
    { key: 'navigationTimeoutSec', kind: 'number', unit: 's' },
    { key: 'settleSeconds', kind: 'number', unit: 's' },
    { key: 'scrollSettleSeconds', kind: 'number', unit: 's' },
    { key: 'maxScrollSegments', kind: 'number' },
    { key: 'promptTimeoutSec', kind: 'number', unit: 's' },
  ];
  function displayValue(key, value) {
    if (key === 'captureArea') return AREA_TEXT[value] || String(value);
    if (key === 'onNotReady') return NOT_READY_TEXT[value] || String(value);
    if (value === '' || value === undefined || value === null) return 'none';
    const f = OVERRIDE_FIELDS.find(x => x.key === key);
    return String(value) + (f && f.unit ? (f.unit === '%' ? '%' : ' ' + f.unit) : '');
  }
  function overridesBlock(i) {
    const base = P('pages', i, 'overrides');
    const changed = OVERRIDE_FIELDS.filter(f => effOverride(i, f.key).has).length;
    const fields = OVERRIDE_FIELDS.map(f => {
      const info = effOverride(i, f.key);
      const path = base + '.' + f.key;
      const sp = spec('defaults.' + f.key);
      const badge = info.has
        ? h('span', { class: 'override-state' }, h('span', { class: 'chip chip-accent', text: 'Changed for this page' }),
          btn('Reset to default', () => change(() => clearValue(path), { render: 'all' }), { small: true, fkey: 'reset:' + path }))
        : h('span', { class: 'chip chip-muted', text: 'Run default' });
      const help = 'Run default: ' + displayValue(f.key, info.base) + '.';
      if (f.kind === 'select') {
        const options = (sp.allowed || []).map(v => ({ value: v, label: (f.key === 'captureArea' ? AREA_TEXT : NOT_READY_TEXT)[v] || v }));
        return selectField({ path: path, label: SETTING_LABELS['defaults.' + f.key], value: info.value, options: options, help: help, badge: badge });
      }
      const pick = f.pick ? btn('Pick', () => startPick('waitFor', { page: i, override: true }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-waitfor', aria: 'Pick the element to wait for in the browser' }) : null;
      return textField({
        path: path, label: SETTING_LABELS['defaults.' + f.key] + (f.unit === 's' ? ' (seconds)' : f.unit === '%' ? ' (%)' : ''),
        kind: f.kind, whole: sp.type === 'int', mono: f.key === 'waitFor', value: info.has ? info.value : '',
        placeholder: info.base === '' ? 'none' : String(info.base) + ' (run default)', help: help + (f.key === 'waitFor' ? ' A selector that must appear before anything is captured.' : ''),
        badge: badge, extra: pick,
        commit: raw => {
          if (!raw.trim()) { clearValue(path); return; }
          if (f.kind === 'number') { const n = parseNumber(raw, sp.type === 'int'); setAt(S.config, path, n === null ? raw : n); }
          else setAt(S.config, path, raw);
        },
      });
    });
    return h('div', { class: 'subsection' },
      disclosure('Capture options for this page' + (changed ? ' (' + changed + ' changed)' : ''), S.overridesOpen, v => { S.overridesOpen = v; },
        [h('p', { class: 'help', text: 'Each option starts with the run default from the Output tab. Change one only when this page needs something else.' })].concat(fields), 'overrides-toggle'));
  }

  // ------------------------------------------------------------------ actions
  function actionsBlock(i) {
    const page = pageAt(i);
    const actions = actionsOf(page);
    const list = h('ol', { class: 'action-list', 'aria-label': 'Actions on this page, in order' });
    actions.forEach((action, j) => {
      const path = P('pages', i, 'actions', j);
      const open = S.openAction === j;
      const editorId = 'action-editor-' + j;
      const clicks = ['click', 'clickText'].includes(actionType(action));
      const key = testKey(i, j);
      const result = S.tests[key];
      const testing = S.testing === key;
      const row = h('li', { class: 'action-row' + (open ? ' is-open' : '') },
        h('div', { class: 'action-line' },
          h('span', { class: 'action-num', text: (j + 1) + '.' }),
          h('span', { class: 'action-text', dataset: { summaryFor: path, path: path }, tabindex: '-1', text: describeAction(action) })),
        h('div', { class: 'action-buttons' },
          btn(open ? 'Close' : 'Edit', () => { S.openAction = open ? -1 : j; keepFocus(renderAll); }, { small: true, expanded: open, controls: editorId, fkey: 'action-edit:' + j, aria: (open ? 'Close action ' : 'Edit action ') + (j + 1) }),
          btn(testing ? 'Testing…' : (clicks ? 'Test (really clicks)' : 'Test'), () => testAction(i, j), {
            small: true, later: S.capabilities.test ? null : LATER_BROWSER, disabled: !!S.testing, fkey: 'action-test:' + j,
            aria: 'Test action ' + (j + 1) + ' in the audit browser' + (clicks ? ': this really clicks on the page' : ''),
            title: clicks ? 'Runs this click in the audit browser now. It is a real click: the site acts on it.' : 'Runs this one step in the audit browser now.',
          }),
          btn('↑', () => moveAction(i, j, j - 1), { small: true, disabled: j === 0, aria: 'Move action ' + (j + 1) + ' up', fkey: 'action-up:' + j }),
          btn('↓', () => moveAction(i, j, j + 1), { small: true, disabled: j === actions.length - 1, aria: 'Move action ' + (j + 1) + ' down', fkey: 'action-down:' + j }),
          btn('Delete', () => deleteAction(i, j), { small: true, danger: true, aria: 'Delete action ' + (j + 1), fkey: 'action-del:' + j })),
        result ? h('p', { class: 'action-result ' + (result.ok ? 'is-ok' : 'is-bad'), role: 'status' },
          h('strong', { text: result.ok ? 'Test worked. ' : 'Test: ' }), result.message) : null,
        open ? h('div', { class: 'action-editor', id: editorId }, actionEditor(i, j, action)) : null);
      list.appendChild(row);
    });
    const hasCapture = actions.some(a => actionType(a) === 'capture');
    return h('div', { class: 'subsection' },
      h('h3', { class: 'sub-title', text: 'What happens on this page' }),
      h('p', { class: 'help', text: 'Vouch opens the address, then does these steps in order. Each “Capture” takes the screenshots.' }),
      actions.length ? list : h('p', { class: 'empty', text: 'No actions yet.' }),
      hasCapture ? null : h('p', { class: 'help note', text: 'This page has no capture, so Vouch adds one at the end: a screenshot of what is visible.' }),
      h('div', { class: 'button-row wrap' },
        btn('Pick something to click', () => startPick('click', { page: i }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-click', title: 'Point at it in the audit browser; Vouch records how to click it again' }),
        btn('Pick a scroll area', () => startPick('scroll', { page: i }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-area', title: 'Point inside the area in the audit browser; Vouch adds a capture that scrolls it' }),
        btn('Add click', () => addAction(i, { type: 'clickText', text: '' }), { small: true, fkey: 'add-click' }),
        btn('Add capture', () => addAction(i, { type: 'capture', scroll: { mode: 'none' } }), { small: true, fkey: 'add-capture' }),
        btn('Add wait', () => addAction(i, { type: 'wait', seconds: 2 }), { small: true, fkey: 'add-wait' }),
        btn('Add wait-for', () => addAction(i, { type: 'waitFor', selector: '' }), { small: true, fkey: 'add-waitfor' }),
        btn('Add pause', () => addAction(i, { type: 'pause' }), { small: true, fkey: 'add-pause' })),
      S.capabilities.pick ? null : laterNote('Picking needs the audit browser (see the top of this window). Until it is connected, use “Add click” and type the words or the selector.'));
  }
  // A test result belongs to one action as it is now: moving or changing it drops the result.
  function testKey(i, j) {
    const page = pageAt(i);
    return pageId(page, i) + '#' + j + '#' + JSON.stringify(actionsOf(page)[j]);
  }
  function actionEditor(i, j, action) {
    const path = P('pages', i, 'actions', j);
    const type = actionType(action);
    const schemaFor = t => S.schema.actions[t];
    switch (type) {
      case 'click':
      case 'clickText': {
        const byText = type === 'clickText';
        return [
          radioField({
            path: path + '.type', label: 'Click by', value: type,
            options: [
              { value: 'clickText', label: 'The words on it', help: 'Clicks the link, button or tab showing these words. Keeps working when the page’s design changes. Capital letters do not matter.' },
              { value: 'click', label: 'An exact element (selector)', help: 'For when the same words appear more than once. A selector such as #tab-users, copied from Edge (F12, right-click, Copy selector).' },
            ],
            // The value of the other kind is kept aside while this editor is open, so
            // switching back and forth loses nothing; only the chosen kind's value is in
            // the configuration.
            commit: value => {
              const a = getAt(S.config, path);
              const from = value === 'click' ? 'text' : 'selector';
              const to = value === 'click' ? 'selector' : 'text';
              if (!S.clickStash || S.clickStash.path !== path) S.clickStash = { path: path, values: {} };
              if (typeof a[from] === 'string') S.clickStash.values[from] = a[from];
              delete a[from];
              a.type = value;
              a[to] = typeof S.clickStash.values[to] === 'string' ? S.clickStash.values[to] : (typeof a[to] === 'string' ? a[to] : '');
            },
          }),
          byText
            ? textField({ path: path + '.text', label: 'Words to click', help: 'Vouch never clicks Log out or Sign out unless you write those words here.' })
            : textField({ path: path + '.selector', label: 'Selector', mono: true, help: 'The first element on the page that matches is clicked.', extra: btn('Pick', () => startPick('click', { page: i, action: j }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-sel', aria: 'Pick what to click in the browser' }) }),
        ];
      }
      case 'wait':
        return [textField({ path: path + '.seconds', label: 'Seconds to wait', kind: 'number', narrow: true, help: 'For pages that fill in slowly, 0 to ' + schemaFor('wait').seconds.max + ' seconds. “Wait until” is usually better: it goes on as soon as the element is there.' })];
      case 'waitFor':
        return [
          textField({ path: path + '.selector', label: 'Wait until this element appears (selector)', mono: true, help: 'For example #lockout-table. Vouch waits until it is on the page and visible.', extra: btn('Pick', () => startPick('waitFor', { page: i, action: j }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-wf', aria: 'Pick the element to wait for in the browser' }) }),
          textField({ path: path + '.timeoutSec', label: 'At most (seconds)', kind: 'number', whole: true, narrow: true, placeholder: String(effOverride(i, 'navigationTimeoutSec').value) + ' (page load limit)', help: 'Empty: the page load time limit. If the element does not appear in time, the page gets a warning.' }),
        ];
      case 'pause':
        return [
          textField({ path: path + '.message', label: 'Message to show', kind: 'textarea', rows: 2, help: 'The run stops here and the Vouch dialog shows this message with Continue / Wait / Skip, for example to complete a sign-in. Scheduled runs never stop: they skip the pause and note it.' }),
        ];
      case 'capture': {
        const scroll = isObj(action.scroll) ? action.scroll : {};
        const mode = canonEnum(['none', 'auto', 'page', 'area'], scroll.mode || 'none');
        const as = String(scroll.as || 'segments').toLowerCase() === 'single' ? 'single' : 'segments';
        const parts = [
          textField({ path: path + '.label', label: 'Label (optional)', help: 'Shown under the screenshots in the report, useful when a page has several captures.' }),
          radioField({
            path: path + '.scroll.mode', label: 'What to capture', value: mode,
            options: [
              { value: 'none', label: 'What is visible', help: 'One screenshot of what fits in the window.' },
              { value: 'auto', label: 'Auto-detect what scrolls', help: 'Vouch finds what scrolls - the page, or the largest panel inside it - and captures all of it. Same as ScrollFullPage Y in a CSV.' },
              { value: 'page', label: 'The whole page', help: 'Scrolls the page itself from top to bottom.' },
              { value: 'area', label: 'A chosen area', help: 'Scrolls one part of the page that you name with a selector, for example a table with its own scroll bar.' },
            ],
            commit: value => { const a = getAt(S.config, path); if (!isObj(a.scroll)) a.scroll = {}; a.scroll.mode = value; },
          }),
        ];
        if (mode === 'area') {
          parts.push(textField({ path: path + '.scroll.selector', label: 'Area to scroll (selector)', mono: true, help: 'For example #main.', extra: btn('Pick', () => startPick('scroll', { page: i, action: j }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-ar', aria: 'Pick the area to scroll in the browser' }) }));
        }
        if (mode !== 'area') {
          parts.push(h('div', { class: 'button-row' },
            btn('Pick the area to scroll in the browser', () => startPick('scroll', { page: i, action: j }), { small: true, later: S.capabilities.pick ? null : LATER_BROWSER, fkey: 'pick-ar2', title: 'Point inside what should be scrolled; the page itself gives “The whole page”' })));
        }
        if (mode !== 'none') {
          parts.push(radioField({
            path: path + '.scroll.as', label: 'How to save it', value: as,
            options: [
              { value: 'segments', label: 'One screenshot per screenful', help: 'Works with every capture area; the report shows them in order.' },
              { value: 'single', label: 'One tall image', help: 'Only with the capture area “Page content only”, when the page itself scrolls and is not too long. Otherwise Vouch takes screenfuls and says so in the report.' },
            ],
            commit: value => { const a = getAt(S.config, path); if (!isObj(a.scroll)) a.scroll = {}; a.scroll.as = value; },
          }));
        }
        return parts;
      }
      default:
        return [h('p', { class: 'help', text: 'Vouch does not know this kind of action. It is kept in the file as written; the run will report it as a problem. Delete it if it is not needed.' })];
    }
  }

  // ------------------------------------------------------------------ page and action operations
  function nextPageId() {
    const used = new Set(pagesOf(S.config).map((p, i) => pageId(p, i).toLowerCase()));
    for (let n = 1; ; n++) { const id = 'p' + String(n).padStart(3, '0'); if (!used.has(id)) return id; }
  }
  function ensurePages(c) { if (!Array.isArray(c.pages)) c.pages = []; return c.pages; }
  function addPage(fields) {
    const page = Object.assign({ id: nextPageId(), name: 'New page', url: '', enabled: true, actions: [{ type: 'capture', scroll: { mode: 'none' } }] }, fields || {});
    change(c => { ensurePages(c).push(page); }, { render: 'none' });
    S.page = pagesOf(S.config).length - 1;
    S.openAction = -1;
    S.tab = 'pages';
    renderAll();
    focusKey('pages[' + S.page + '].name');
    announce('Page added: ' + page.name + '.');
  }
  function selectPage(i) { S.page = i; S.openAction = -1; keepFocus(renderAll); scheduleRunPlan(); }
  function movePage(from, to, keyboard) {
    const pages = pagesOf(S.config);
    if (to < 0 || to >= pages.length || from === to) return;
    const name = pageName(pages[from], from);
    change(c => { const [p] = c.pages.splice(from, 1); c.pages.splice(to, 0, p); }, { render: 'none' });
    S.page = to;
    renderAll();
    if (keyboard) focusKey('page-select:' + to);
    announce('Moved “' + name + '” to position ' + (to + 1) + ' of ' + pages.length + '.');
  }
  function duplicatePage(i) {
    const copy = clone(pageAt(i));
    copy.id = nextPageId();
    copy.name = pageName(copy, i) + ' (copy)';
    change(c => { c.pages.splice(i + 1, 0, copy); }, { render: 'none' });
    S.page = i + 1;
    renderAll();
    announce('Page duplicated.');
  }
  function deletePage(i) {
    const name = pageName(pageAt(i), i);
    change(c => { c.pages.splice(i, 1); }, { render: 'none' });
    S.page = Math.max(0, Math.min(i, pagesOf(S.config).length - 1));
    renderAll();
    toast('Deleted the page “' + name + '”.', { label: 'Undo', run: undo });
    announce('Page deleted. Press Ctrl+Z to undo.');
  }
  function addAction(i, action) {
    change(c => { const page = c.pages[i]; if (!Array.isArray(page.actions)) page.actions = []; page.actions.push(action); }, { render: 'none' });
    S.openAction = actionsOf(pageAt(i)).length - 1;
    renderAll();
    const first = $('.action-editor input[type=text], .action-editor textarea, .action-editor input');
    if (first) first.focus();
    announce('Action added.');
  }
  function moveAction(i, from, to) {
    const actions = actionsOf(pageAt(i));
    if (to < 0 || to >= actions.length) return;
    change(c => { const list = c.pages[i].actions; const [a] = list.splice(from, 1); list.splice(to, 0, a); }, { render: 'none' });
    if (S.openAction === from) S.openAction = to;
    renderAll();
    focusKey((to < from ? 'action-up:' : 'action-down:') + to) || focusKey('action-edit:' + to);
    announce('Action moved to position ' + (to + 1) + '.');
  }
  function deleteAction(i, j) {
    const text = describeAction(actionsOf(pageAt(i))[j]);
    change(c => { c.pages[i].actions.splice(j, 1); }, { render: 'none' });
    S.openAction = -1;
    renderAll();
    toast('Deleted: ' + shortText(text, 60), { label: 'Undo', run: undo });
  }
  Object.assign(window.VouchDesigner, { addPage, selectPage, movePage, duplicatePage, deletePage, addAction, moveAction, deleteAction, undo, redo, setTab, jumpTo, problems, isDirty });

  // ------------------------------------------------------------------ Output tab
  function browseButton(path, kind, title) {
    return btn('Browse…', async () => {
      try {
        const result = await whileServerDialog(() => api('POST', '/api/dialog', { kind: kind, title: title }));
        if (result.cancelled) return;
        // The preview remembers the value it was made for: after Undo the path changes
        // back and the preview is no longer shown with it (Redo shows it again).
        if (kind === 'image') S.logo = result.logo ? Object.assign({}, result.logo, { value: result.value || result.path }) : null;
        change(() => setAt(S.config, path, result.value || result.path), { render: 'all' });
      } catch (e) { showError(e); }
    }, { small: true, fkey: 'browse:' + path });
  }
  function settingNumber(path, label, help, unit) {
    const sp = spec(path);
    return textField({ path: path, label: label + (unit ? ' (' + unit + ')' : ''), kind: 'number', whole: sp.type === 'int', narrow: true, placeholder: String(sp.default) + ' (default)', help: help + ' ' + sp.min + ' to ' + sp.max + '; default ' + sp.default + '.' });
  }
  function renderOutput() {
    const panel = $('#panel-output');
    const jpeg = eff('output.imageFormat') === 'jpeg';
    const embed = eff('output.embedImages') !== false;
    const zipOn = eff('output.zip.enabled') === true;
    panel.replaceChildren(h('div', { class: 'stack' },
      section('Where the report goes', null, [
        textField({ path: 'output.dir', label: 'Output folder', mono: true, placeholder: 'reports', extra: browseButton('output.dir', 'folder', 'Choose the output folder'), help: 'Where reports are saved. A relative folder such as “reports” is inside the folder of this configuration file.' }),
        textField({ path: 'output.reportName', label: 'Report name', placeholder: 'VouchReport_{date}_{time} (default)', help: 'Leave empty for VouchReport_<date>_<time>. You can use {date}, {time}, {title}, {period}, {classification} and {report} (the default name). A report with the same name in the folder is replaced.' }),
        h('p', { class: 'preview', dataset: { preview: 'report' }, 'aria-live': 'polite' }),
        checkField({ path: 'output.openReport', label: 'Open the report when the run is finished', help: 'Only when a person started the run; never in a scheduled run.' }),
      ]),
      section('Images', null, [
        radioField({ path: 'output.imageFormat', label: 'Image format', options: [
          { value: 'jpeg', label: 'JPEG', help: 'Smaller files; the usual choice.' },
          { value: 'png', label: 'PNG', help: 'Lossless, larger files.' }] }),
        jpeg ? settingNumber('output.jpegQuality', 'JPEG quality', 'Higher is sharper and larger.') : null,
        radioField({ path: 'output.embedImages', label: 'Images in the report', value: embed, commit: v => setAt(S.config, 'output.embedImages', v === true || v === 'true'),
          options: [
            { value: true, label: 'Inside the report (one self-contained file)', help: 'The report is one file you can email or attach as it is. It can be large.' },
            { value: false, label: 'Linked picture files', help: 'The report stays small and shows the picture files saved next to it (images\\<report name>\\). That folder must always travel with the report - or turn on the zip below; without it the pictures are missing and the report cannot be verified. Picture files are always saved for this.' }] }),
        checkField({ path: 'output.saveImages', label: 'Also save every screenshot as a picture file', help: 'In images\\<report name>\\ next to the report, with a SHA256SUMS file of their fingerprints.' + (embed ? '' : ' (Always on with linked picture files.)') }),
      ]),
      section('What each screenshot shows', null, [
        radioField({ path: 'defaults.captureArea', label: 'Capture area (run default)', options: [
          { value: 'screen', label: AREA_TEXT.screen, help: 'The whole screen, as today: the Windows clock and date are in every picture. What auditors usually expect.' },
          { value: 'window', label: AREA_TEXT.window, help: 'The Edge window with its title bar, tabs and address bar; no taskbar.' },
          { value: 'page', label: AREA_TEXT.page, help: 'Taken by the browser itself; Edge need not be in front. No address bar or clock in the picture - the time and address are in the report and inside each image file.' }] }),
        settingNumber('defaults.zoomPercent', 'Zoom', 'Shows the pages zoomed, like Ctrl+plus or minus, without changing anything in Edge.', '%'),
        checkField({ path: 'browser.useVirtualDesktop', label: 'Capture on a separate, empty virtual desktop', help: 'Other programs then do not appear in the taskbar of the screenshots. Your windows are untouched and you return to them at the end. A page test from the Designer ignores this setting.' }),
      ]),
      section('Logs and results', null, [
        checkField({ path: 'output.captureLog', label: 'Write a capture log', help: 'A readable, time-stamped account written next to the report while the run happens: each page, action, question and answer, and every image with its fingerprint. It also goes into the zip. On by default.' }),
        checkField({ path: 'output.jsonSummary', label: 'Write a JSON summary', help: 'The results as a .json file next to the report, for monitoring tools.' }),
        checkField({ path: 'output.failOnWarning', label: 'Count warnings as failure', help: 'The run ends with exit code 3 when a page has a warning, so a scheduled task shows it as failed. Without it, warnings count as success.' }),
        textField({ path: 'output.logDir', label: 'Console transcript folder (optional)', mono: true, extra: browseButton('output.logDir', 'folder', 'Choose the transcript folder'), help: 'Keeps a raw copy of everything the Vouch window shows, for troubleshooting scheduled runs. This is not the capture log.' }),
      ]),
      section('Zip', null, [
        checkField({ path: 'output.zip.enabled', label: 'Put everything into one zip when done', help: 'The report, its JSON summary, the capture log and the picture files in one zip in the output folder, ready to attach. Extracting it gives a working report.' }),
        zipOn ? textField({ path: 'output.zip.name', label: 'Zip name', placeholder: '{report}.zip', help: 'Tokens: {report} (the report’s name), {title}, {date}, {time}, {period}, {classification}. An existing zip is never replaced; a number is added.' }) : null,
        zipOn ? h('p', { class: 'preview', dataset: { preview: 'zip' }, 'aria-live': 'polite' }) : null,
      ]),
      section('Browser', null, [
        checkField({ path: 'browser.keepBrowserOpen', label: 'Keep the browser open after the run', help: 'Leaves the Edge window Vouch opened. An Edge that was already running is always left open.' }),
      ]),
      h('div', { class: 'card' }, disclosure('Advanced: time limits, scrolling and the browser connection', S.advancedOpen, v => { S.advancedOpen = v; }, [
        settingNumber('defaults.navigationTimeoutSec', 'Page load time limit', 'How long to wait for each page to load.', 'seconds'),
        settingNumber('defaults.settleSeconds', 'Wait after loading', 'Extra time after a page has loaded and after each click, for content that appears late.', 'seconds'),
        settingNumber('defaults.scrollSettleSeconds', 'Wait after each scroll', 'Time after each scroll before the next screenshot.', 'seconds'),
        settingNumber('defaults.maxScrollSegments', 'Most screenshots per scrolled page', 'A longer page is reported with a warning.'),
        textField({ path: 'defaults.waitFor', label: 'Wait for this element on every page (selector, optional)', mono: true, help: 'Something every page shows once it is ready, for example #content.' }),
        radioField({ path: 'defaults.onNotReady', label: 'When a page is not ready or asks for a sign-in', options: [
          { value: 'warn', label: NOT_READY_TEXT.warn, help: 'The run goes on by itself; the report says what was wrong.' },
          { value: 'prompt', label: NOT_READY_TEXT.prompt, help: 'In a run a person started, the Vouch dialog asks. Scheduled runs never ask.' }] }),
        settingNumber('defaults.promptTimeoutSec', 'Time to answer a question', 'After this the run goes on as if Continue was chosen.', 'seconds'),
        settingNumber('browser.debugPort', 'Browser connection port', 'The local port Vouch uses to control Edge. An Edge already listening there is reused.'),
        textField({ path: 'browser.profileDir', label: 'Edge profile folder (optional)', mono: true, placeholder: 'The profile -LoginSetup prepares', help: 'Where the sign-ins Vouch uses are kept. Leave empty for the usual one.' }),
      ], 'advanced-toggle'))));
  }

  // ------------------------------------------------------------------ Report tab
  const CLASSIFICATIONS = [['', 'None'], ['Public', 'Public'], ['Internal', 'Internal'], ['Private', 'Private'], ['Confidential', 'Confidential']];
  function renderReport() {
    const panel = $('#panel-report');
    const level = eff('report.classification') || '';
    const chip = level ? h('span', { class: 'cls-chip cls-' + level.toLowerCase(), text: level.toUpperCase() }) : h('span', { class: 'chip chip-muted', text: 'No marking' });
    const logoPath = eff('report.logoPath') || '';
    const preview = S.logo && logoPath && S.logo.value === logoPath ? S.logo : null;
    const logo = preview && preview.dataUri ? h('img', { class: 'logo-thumb', src: preview.dataUri, alt: 'Logo preview' }) : null;
    const logoNote = preview && preview.warning ? h('p', { class: 'help warning-text', text: preview.warning }) : null;
    panel.replaceChildren(h('div', { class: 'stack' },
      section('Report heading', null, [
        textField({ path: 'report.title', label: 'Title', placeholder: 'Audit Evidence Report', help: 'The report’s main heading.' }),
        selectField({ path: 'report.classification', label: 'Classification', value: level, options: CLASSIFICATIONS.map(([v, l]) => ({ value: v, label: l })), extra: chip,
          help: 'A coloured banner at the top and bottom of the report, repeated on every printed page.' }),
        textField({ path: 'report.logoPath', label: 'Logo (optional)', mono: true, extra: browseButton('report.logoPath', 'image', 'Choose a logo'),
          commit: raw => { if (raw === '') clearValue('report.logoPath'); else setAt(S.config, 'report.logoPath', raw); },
          help: 'PNG, JPEG, GIF or SVG, at most 1 MB. It is copied into the report. A relative path is read from the folder of this configuration file.' }),
        logo ? h('div', { class: 'logo-row' }, logo) : (logoPath && !logoNote ? h('p', { class: 'help', text: 'Choose the file with Browse… to see a preview.' }) : null),
        logoNote,
        textField({ path: 'report.company.name', label: 'Company name' }),
        textField({ path: 'report.company.details', label: 'Company details', kind: 'textarea', rows: 3, help: 'Address, engagement and so on; line breaks are kept.' }),
      ]),
      section('What, where and who', null, [
        textField({ path: 'report.description', label: 'Description', kind: 'textarea', rows: 3, help: 'What this evidence is for.' }),
        textField({ path: 'report.origin', label: 'Origin', help: 'Where the capture was made, for example the office, the system or the request it answers.' }),
        textField({ path: 'defaults.account', label: 'Default account', help: 'The account used to sign in to the applications, shown in the report and inside each image. A page can name another one.' }),
        textField({ path: 'report.generatedBy', label: 'Generated by', placeholder: 'Your Windows user name', help: 'Who produced the report.' }),
      ]),
      section('Period covered', 'The period under audit, shown exactly as typed. The time of the captures is recorded separately.', [
        h('div', { class: 'field-pair' },
          textField({ path: 'report.period.from', label: 'From', placeholder: '2026-07-01', narrow: true }),
          textField({ path: 'report.period.to', label: 'To', placeholder: '2026-09-30', narrow: true })),
        textField({ path: 'report.period.label', label: 'Name of the period', placeholder: 'Q3 2026' }),
      ]),
      section('Layout', null, [
        checkField({ path: 'report.showIndex', label: 'Show a contents list near the top', help: 'A list of all pages with their result, linking to each one.' }),
        textField({ path: 'name', label: 'Name of this configuration', help: 'Only for you, to tell configurations apart. The report uses the title above.' }),
      ])));
  }

  // ------------------------------------------------------------------ Run tab
  function fmtElapsed(sec) {
    sec = Math.max(0, Math.round(Number(sec) || 0));
    const m = Math.floor(sec / 60), r = sec % 60;
    return m + ':' + String(r).padStart(2, '0');
  }
  function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }
  /* What a run would do, before it starts: unsaved edits, the output folder, notes, the added switches. */
  function runPlanBlock() {
    const plan = S.runPlan;
    if (!plan) return h('p', { class: 'help', text: 'Working out where the results go…' });
    const parts = [];
    if (plan.unsaved) {
      parts.push(h('div', { class: 'callout callout-accent', role: 'note' },
        h('strong', { text: 'Running your current edits (not yet saved). ' }),
        plan.saved ? 'The saved file is not changed by a run.' : 'This configuration has not been saved to a file yet.'));
    }
    if (plan.errors && plan.errors.length) {
      parts.push(h('p', { class: 'callout callout-error', text: plural(plan.errors.length, 'problem', 'problems') + ' must be fixed before anything can run (see the list at the top).' }));
    }
    else if (plan.outputFolder) {
      parts.push(h('p', { class: 'run-where' }, h('span', { class: 'run-where-label', text: 'Reports of a full run go to: ' }), h('code', { class: 'path-text', text: plan.outputFolder })));
    }
    const notes = [].concat(plan.notes || []);
    const pagePlan = S.pagePlan;
    if (pagePlan && pagePlan.notes) for (const n of pagePlan.notes) if (!notes.includes(n)) notes.push(n);
    if (notes.length) parts.push(h('ul', { class: 'notes' }, notes.map(n => h('li', { text: n }))));
    const flags = plan.sessionFlags || [];
    const pageFlags = pagePlan && pagePlan.sessionFlags ? pagePlan.sessionFlags.filter(f => !flags.includes(f)) : [];
    if (flags.length) {
      parts.push(h('details', { class: 'run-flags' },
        h('summary', { text: 'What the Designer adds to the command below for its runs' }),
        h('p', { class: 'help', text: 'A run here is the command below, on a copy of what you see, with these settings added for this run only:' }),
        h('ul', { class: 'notes' }, flags.map(f => h('li', { text: f }))),
        pageFlags.length ? h('p', { class: 'help', text: 'A page test also adds:' }) : null,
        pageFlags.length ? h('ul', { class: 'notes' }, pageFlags.map(f => h('li', { text: f }))) : null));
    }
    return h('div', { class: 'run-plan' }, parts);
  }
  function runStatusText() {
    const r = S.run;
    const base = runStateText();
    if (r.state === 'idle') return base;
    const bits = [base];
    if (r.kind) bits.push(r.kind === 'page' ? 'Page test: ' + (r.pageName || r.pageId) : 'Full run');
    bits.push('time ' + fmtElapsed(r.elapsedSec));
    const c = r.counts;
    if (c) bits.push(plural(c.run, 'page', 'pages') + ' run: ' + c.ok + ' OK, ' + c.warning + ' with warnings, ' + c.failed + ' failed' + (c.notRun ? ', ' + c.notRun + ' not run' : '') + ', ' + plural(c.captures, 'image', 'images'));
    else if (r.pages && r.pages.length) {
      const done = r.pages.filter(p => p.status !== 'RUNNING').length;
      const total = r.pages[0].total > 0 ? r.pages[0].total : r.pages.length;
      bits.push(done + ' of ' + plural(total, 'page', 'pages') + ' done');
    }
    return bits.join(' · ');
  }
  const STATUS_TEXT = { OK: 'OK', WARNING: 'Warning', FAILED: 'Failed', RUNNING: 'Running…', NOTFINISHED: 'Not finished' };
  function statusChipClass(status) { return status === 'RUNNING' ? 'chip-accent' : status === 'NOTFINISHED' ? 'chip-muted' : 'chip-' + status.toLowerCase(); }
  function runPageList() {
    const pages = S.run.pages || [];
    if (!pages.length) return h('p', { class: 'empty', text: runActive() ? 'Waiting for the first page…' : 'Progress appears here while a run is going.' });
    return h('ol', { class: 'run-pages', 'aria-label': 'Pages in this run' }, pages.map(p => {
      const status = String(p.status || 'RUNNING').toUpperCase();
      const details = p.details || [];
      return h('li', { class: 'run-page st-' + status.toLowerCase() },
        h('div', { class: 'run-page-head' },
          h('span', { class: 'run-page-name', text: p.name || p.pageId || 'Page' }),
          h('span', { class: 'chip ' + statusChipClass(status), text: STATUS_TEXT[status] || status }),
          h('span', { class: 'run-page-count', text: plural(p.captureCount || 0, 'image', 'images') })),
        details.length ? h('details', { class: 'run-details' },
          h('summary', { text: status === 'FAILED' ? plural(details.length, 'problem', 'problems') : status === 'WARNING' || status === 'NOTFINISHED' ? plural(details.length, 'warning', 'warnings') : plural(details.length, 'note', 'notes') }),
          h('ul', { class: 'notes' }, details.map(d => h('li', { text: d })))) : null);
    }));
  }
  function runResultButtons() {
    const r = S.run, o = r.open || {};
    if (r.kind !== 'full' || runActive()) return null;
    if (!o.report && !o.folder && !o.log && !o.zip) return null;
    return h('div', { class: 'button-row wrap' },
      btn('Open report', () => openTarget('report'), { small: true, primary: true, disabled: !o.report, fkey: 'open-report' }),
      btn('Open folder', () => openTarget('folder'), { small: true, disabled: !o.folder, fkey: 'open-folder' }),
      btn('Open capture log', () => openTarget('log'), { small: true, disabled: !o.log, fkey: 'open-log' }),
      o.zip ? btn('Open zip location', () => openTarget('zip'), { small: true, fkey: 'open-zip' }) : null);
  }
  function previewBlock() {
    const r = S.run;
    if (r.kind !== 'page' || runActive()) return null;
    const pv = r.preview;
    const page = (r.pages || [])[0];
    const parts = [h('h3', { class: 'sub-title', text: 'Preview of the page test' + (r.pageName ? ': ' + r.pageName : '') })];
    if (page) {
      const status = String(page.status || '').toUpperCase();
      parts.push(h('p', {}, h('span', { class: 'chip ' + statusChipClass(status), text: STATUS_TEXT[status] || status }), ' ', plural(page.captureCount || 0, 'image', 'images')));
    }
    parts.push(h('p', { class: 'preview-note', text: 'This is a test, not evidence. Use Run all pages to make the report.' }));
    const images = pv && Array.isArray(pv.images) ? pv.images : [];
    if (images.length) {
      parts.push(h('div', { class: 'thumbs' }, images.map((img, k) => {
        const src = S.previewImages[img.url];
        const caption = (img.label ? img.label + ' · ' : '') + (img.segmentCount > 1 ? 'part ' + img.segment + ' of ' + img.segmentCount : 'image ' + (k + 1));
        const inner = src && src !== 'failed' ? h('img', { class: 'thumb-img', src: src, alt: 'Screenshot: ' + caption })
          : h('span', { class: 'thumb-wait', text: src === 'failed' ? 'Could not be shown' : 'Loading…' });
        return h('button', { type: 'button', class: 'thumb', dataset: { fkey: 'thumb:' + k }, 'aria-label': 'Show larger: ' + caption, onclick: () => showPreviewImage(img, caption) },
          inner, h('span', { class: 'thumb-caption', text: caption }));
      })));
    }
    else if (r.state === 'done' || r.state === 'failed') parts.push(h('p', { class: 'help', text: 'This test made no screenshots.' }));
    if (pv && pv.report) parts.push(h('div', { class: 'button-row' }, btn('Open the preview report', () => openTarget('preview-report'), { small: true, fkey: 'open-preview' })));
    parts.push(h('p', { class: 'help', text: 'The preview is temporary: it is replaced by the next test of this page and removed when the Designer closes.' }));
    return h('div', { class: 'preview-block' }, parts);
  }
  function renderRun() {
    const panel = $('#panel-run');
    const canRun = S.capabilities.run;
    const page = pageAt(S.page);
    const run = S.run;
    const active = runActive();
    const stopping = run.state === 'stopping';
    const stopButton = run.forceAvailable
      ? btn('Force stop', () => stopRun(true), { danger: true, fkey: 'run-force', title: 'Ends the run at once; its report may be missing' })
      : btn(stopping ? 'Stopping…' : 'Stop', () => stopRun(false), { danger: true, disabled: !active || stopping, fkey: 'run-stop', title: 'Ends the run after the current step; the report is still written' });
    const outcome = (run.state === 'done' || run.state === 'failed') && run.message
      ? h('div', { class: 'callout ' + (run.state === 'failed' ? 'callout-error' : (run.exitCode === 0 && !(run.counts && run.counts.warning) ? 'callout-ok' : 'callout-warning')), role: 'note' },
        h('p', { class: 'run-message', text: run.message }),
        run.nextStep ? h('p', { class: 'run-next', text: 'What to do: ' + run.nextStep }) : null,
        run.errorText && run.errorText !== run.message && !run.message.includes(run.errorText) ? h('pre', { class: 'code run-error', text: run.errorText }) : null)
      : null;
    panel.replaceChildren(h('div', { class: 'stack' },
      section('Run', canRun ? 'Run all pages that are switched on, or test the selected page on its own. What runs is what you see here, saved or not.' : null, [
        canRun ? null : laterNote(LATER_RUN_HERE),
        active ? null : runPlanBlock(),
        h('div', { class: 'button-row wrap' },
          btn('Run all pages', () => startRun('all'), { primary: true, later: canRun ? null : LATER_RUN_HERE, disabled: active, fkey: 'run-all' }),
          btn('Test this page' + (page ? ': ' + shortText(pageName(page, S.page), 30) : ''), () => startRun('page'), { later: canRun ? null : LATER_RUN_HERE, disabled: active || !page, fkey: 'run-page' }),
          active ? stopButton : null),
        h('p', { class: 'run-state', role: 'status', text: runStatusText() }),
        active && run.unsaved ? h('p', { class: 'help', text: 'Running your current edits (not yet saved).' }) : null,
        stopping && !run.forceAvailable && run.forceInSec > 0 ? h('p', { class: 'help', text: 'The run ends after its current step. If it has not ended in ' + run.forceInSec + ' s, you can force it to stop.' }) : null,
        run.forceAvailable ? h('p', { class: 'help warning-text', text: 'The run has not stopped. Force stop ends it at once; its report may then be missing.' }) : null,
        run.state === 'waitingForUser' ? h('div', { class: 'callout callout-accent', role: 'alert' },
          h('strong', { text: 'Waiting for you in the Vouch window over the browser. ' }),
          (run.prompt && run.prompt.title ? '“' + run.prompt.title + '”' + (run.prompt.pageName ? ' (page ' + run.prompt.pageName + ')' : '') + '. ' : '') + 'Answer it there: Continue, Wait or Skip this page.') : null,
        active && (run.notes || []).length ? h('ul', { class: 'notes' }, run.notes.map(n => h('li', { text: n }))) : null,
        outcome,
        runPageList(),
        runResultButtons(),
        previewBlock(),
      ]),
      section('Command line', 'To run this configuration without the Designer - in a PowerShell window, a shortcut or a scheduled task.', [h('div', { id: 'command-box' })])));
    renderCommandBox();
  }
  function runStateText() {
    const s = S.run.state;
    return { idle: 'Nothing is running.', starting: 'Starting…', running: 'Running…', waitingForUser: 'Waiting for your answer in the Vouch window.', stopping: 'Stopping after the current step…', done: 'Finished.', failed: 'The run did not finish.' }[s] || String(s);
  }
  /*
    A command shown one switch per line (with a hanging indent, wrapping only inside a
    long value), so it reads well in the narrow panel. Display only: Copy always gives
    the exact one-line command.
  */
  function commandLines(text) {
    const tokens = [];
    let current = '', quote = '';
    for (const ch of String(text)) {
      if (quote) { current += ch; if (ch === quote) quote = ''; continue; }
      if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
      if (ch === ' ') { if (current) tokens.push(current); current = ''; continue; }
      current += ch;
    }
    if (current) tokens.push(current);
    const lines = [];
    let pastFile = false;
    for (const token of tokens) {
      const starts = lines.length === 0 || (pastFile && token.startsWith('-')) || token === '-File';
      if (token === '-File') pastFile = true;
      if (starts) lines.push(token); else lines[lines.length - 1] += ' ' + token;
    }
    return lines;
  }
  function commandCode(text, labelledBy) {
    return h('pre', { class: 'code command-text', tabindex: '0', 'aria-labelledby': labelledBy || null },
      h('code', {}, commandLines(text).map(line => h('span', { class: 'cmd-line', text: line }))));
  }
  function copyBlock(title, help, text, cmdText, key) {
    const codeId = uid('code');
    const block = h('div', { class: 'command' },
      h('div', { class: 'command-head' }, h('h3', { class: 'sub-title', id: codeId + '-t', text: title }),
        btn('Copy', () => copyText(text, title), { small: true, aria: 'Copy: ' + title, fkey: 'copy:' + key })),
      help ? h('p', { class: 'help', text: help }) : null,
      commandCode(text, codeId + '-t'));
    if (cmdText && cmdText !== text) {
      block.appendChild(h('details', { class: 'cmd-variant' },
        h('summary', { text: 'For cmd.exe or a shortcut' }),
        h('div', { class: 'command-head' }, h('span', { class: 'help', text: 'Quoted for cmd.exe.' }), btn('Copy', () => copyText(cmdText, title + ' (cmd.exe)'), { small: true, aria: 'Copy for cmd.exe: ' + title, fkey: 'copycmd:' + key })),
        commandCode(cmdText)));
    }
    return block;
  }
  function renderCommandBox() {
    const box = $('#command-box');
    if (!box) return;
    const c = S.command;
    const parts = [];
    if (S.commandError) parts.push(h('p', { class: 'callout callout-error', text: S.commandError }));
    if (!c) { parts.push(h('p', { class: 'empty', text: 'Working out the commands…' })); keepFocus(() => box.replaceChildren(...parts)); return; }
    if (c.unsaved || isDirty()) {
      parts.push(h('div', { class: 'callout callout-warning', role: 'note' },
        h('strong', { text: c.saved ? 'Not saved: ' : 'Not saved yet: ' }),
        c.saved ? 'these commands run the file as it was last saved, without your latest changes. Save first.' : 'save the configuration to a file to get the commands that run it.',
        btn(c.saved ? 'Save now' : 'Save…', () => save(!c.saved), { small: true, fkey: 'cmd-save' })));
    }
    if (c.run) {
      parts.push(copyBlock('Run it', 'Paste into a PowerShell window. Every setting and page comes from the file.', c.run, c.runCmd, 'run'));
      parts.push(copyBlock('Run it with every setting spelled out', 'The same run, with each setting that differs from Vouch’s default written as a switch. Change a switch to override the file for one run.', c.runExpanded, c.runExpandedCmd, 'expanded'));
      // The schedule command stays in the API (c.schedule) but is not shown until
      // Install-VouchSchedule.ps1 can take a configuration file.
      parts.push(h('div', { class: 'command' }, h('h3', { class: 'sub-title', text: 'Schedule it' }),
        h('p', { class: 'later-note', text: 'Running this file on a schedule comes in a later step of the Designer.' })));
    }
    if (c.notes && c.notes.length) parts.push(h('ul', { class: 'notes' }, c.notes.map(n => h('li', { text: n }))));
    keepFocus(() => box.replaceChildren(...parts));
  }
  let commandTimer = 0, commandSeq = 0;
  function scheduleCommand() { clearTimeout(commandTimer); commandTimer = setTimeout(refreshCommand, 600); }
  async function refreshCommand() {
    if (!S.config || S.closed) return;
    const seq = ++commandSeq;
    try {
      const result = await api('POST', '/api/command', { config: S.config, path: S.path });
      if (seq !== commandSeq) return;
      S.command = result;
      S.commandError = '';
    } catch (e) {
      if (seq !== commandSeq) return;
      S.commandError = e.message + (e.detail ? ' ' + e.detail : '');
    }
    if (S.tab === 'run') renderCommandBox();
  }
  async function copyText(text, what) {
    try { await navigator.clipboard.writeText(text); }
    catch (e) {
      const area = h('textarea', { class: 'visually-hidden', value: text });
      document.body.appendChild(area); area.select();
      try { document.execCommand('copy'); } finally { area.remove(); }
    }
    toast('Copied: ' + what + '.');
  }
  Object.assign(window.VouchDesigner, { refreshCommand });

  // ------------------------------------------------------------------ the audit browser
  /*
    The status strip under the header: connected (page title and address, Tidy windows,
    a zoom preview with "Show at 100%"), connecting, or not connected with the reason,
    what to do about it, and Retry. Page text is shown with textContent only.
  */
  function renderBrowser() {
    const box = $('#browser-strip');
    if (!box || S.closed) return;
    const b = S.browser || {};
    const parts = [];
    let cls = 'is-off';
    if (b.connected) {
      cls = 'is-on';
      parts.push(h('div', { class: 'bs-line' },
        h('span', { class: 'bs-dot', 'aria-hidden': 'true' }),
        h('span', { class: 'bs-state', text: 'Browser connected' }),
        h('span', { class: 'bs-actions' }, btn('Tidy windows', () => tidyWindows(), { small: true, fkey: 'bs-tidy', title: 'Put the browser on the left and this window on the right' }))),
        h('p', { class: 'bs-page' },
          h('span', { class: 'bs-title', text: b.title || '(no title)' }),
          h('span', { class: 'bs-url', text: b.url || '' })));
      if (b.zoom && b.zoom.percent && b.zoom.percent !== 100) {
        parts.push(h('p', { class: 'bs-zoom' },
          h('strong', { text: 'Zoom preview: ' }),
          (b.zoom.page ? '“' + b.zoom.page + '”' : 'This page') + ' is shown at ' + b.zoom.percent + '%, the run’s zoom. The layout may differ at the run’s full window width. ',
          btn('Show at 100%', () => zoomOff(), { small: true, fkey: 'bs-zoomoff' })));
      }
      if (b.settingsChanged) {
        parts.push(h('p', { class: 'bs-note' }, 'The saved configuration names another browser (port or profile) than the one connected. ',
          btn('Reconnect', () => retryBrowser(), { small: true, fkey: 'bs-reconnect' })));
      }
      if (b.notice) parts.push(h('p', { class: 'bs-note', text: b.notice }));
    }
    else if (b.inRun) {
      cls = 'is-busy';
      parts.push(h('div', { class: 'bs-line' }, h('span', { class: 'bs-dot', 'aria-hidden': 'true' }), h('span', { class: 'bs-state', text: 'A run is using the audit browser' })),
        h('p', { class: 'help', text: 'The Designer leaves the browser alone until the run ends, then connects to it again. You can go on editing.' }));
    }
    else if (b.connecting || S.connecting) {
      cls = 'is-busy';
      parts.push(h('div', { class: 'bs-line' }, h('span', { class: 'bs-dot', 'aria-hidden': 'true' }), h('span', { class: 'bs-state', text: 'Connecting to the audit Edge…' })));
    }
    else {
      const problem = b.problem || { message: b.message || 'The audit Edge is not connected.', causes: [] };
      parts.push(h('div', { class: 'bs-line' },
        h('span', { class: 'bs-dot', 'aria-hidden': 'true' }),
        h('strong', { class: 'bs-state', text: 'Browser not connected' }),
        h('span', { class: 'bs-actions' }, btn('Retry', () => retryBrowser(), { small: true, primary: true, fkey: 'bs-retry', title: 'Connect to the audit Edge again, opening it if needed' }))),
        h('p', { class: 'bs-problem', text: problem.message }),
        Array.isArray(problem.causes) && problem.causes.length ? h('ul', { class: 'bs-causes' }, problem.causes.map(c => h('li', { text: c }))) : null,
        h('p', { class: 'help', text: 'You can still edit and save. Type addresses, words and selectors yourself until the browser is connected.' }));
    }
    box.className = 'browser-strip ' + cls;
    keepFocus(() => box.replaceChildren(...parts));
  }
  function browserAnnouncement(before, after) {
    if (!before || before.connected === after.connected) return '';
    if (after.connected) return 'Browser connected' + (after.title ? ': ' + after.title : '') + '.';
    return 'Browser not connected: ' + ((after.problem && after.problem.message) || after.message || '');
  }
  async function retryBrowser() {
    S.connecting = true;
    renderBrowser();
    try { S.browser = await api('POST', '/api/browser/connect', {}); }
    catch (e) { showError(e); }
    finally { S.connecting = false; }
    await poll(true);
    renderBrowser();
    announce(S.browser.connected ? 'Browser connected.' : 'Still not connected: ' + ((S.browser.problem && S.browser.problem.message) || ''));
  }
  async function tidyWindows() {
    try { const r = await api('POST', '/api/browser/layout', {}); toast(r.message || 'Done.'); }
    catch (e) { showError(e); }
  }
  async function zoomOff() {
    try { S.browser = await api('POST', '/api/browser/zoom-off', {}); renderBrowser(); announce('The page is shown at 100% again.'); }
    catch (e) { showError(e); }
  }
  async function goToUrl(i) {
    if (S.going) return;
    const page = pageAt(i);
    S.going = true;
    keepFocus(renderAll);
    announce('Opening the page in the browser…');
    try {
      const r = await api('POST', '/api/browser/navigate', { url: page && typeof page.url === 'string' ? page.url : '', config: S.config, pageIndex: i });
      toast((r.status === 'loaded' ? 'Opened: ' : '') + (r.status === 'loaded' ? (r.title || r.url) : r.message));
      await poll(true);
    } catch (e) { showError(e, 'The page was not opened.'); }
    finally { S.going = false; keepFocus(renderAll); }
  }
  async function addPageFromCurrentTab() {
    try {
      const current = await api('POST', '/api/page/from-current', {});
      addPage({ name: current.name || 'New page', url: current.url || '' });
    } catch (e) { showError(e, 'No page was added.'); }
  }

  // ------------------------------------------------------------------ picking
  const PICK_TEXT = {
    click: 'Click what Vouch should click, in the Edge window. Press Esc there to cancel.',
    scroll: 'Click inside the area Vouch should scroll, in the Edge window. Press Esc there to cancel.',
    waitFor: 'Click the element Vouch should wait for, in the Edge window. Press Esc there to cancel.',
  };
  const ROBUST = { best: 'Most robust', good: 'Robust', fair: 'Less robust', fragile: 'Fragile' };
  /*
    A dialog that cannot be closed while its work is pending: Chromium lets a second Esc
    close a modal dialog even when its "cancel" is prevented, so the dialog opens itself
    again until release() is called.
  */
  function holdOpen(dialog) {
    let held = true;
    const reopen = () => { if (held && !dialog.open && dialog.isConnected) { try { dialog.showModal(); } catch (e) { /* not possible now */ } } };
    dialog.addEventListener('close', reopen);
    if (!dialog.open) dialog.showModal();
    return () => { held = false; dialog.removeEventListener('close', reopen); if (dialog.open) dialog.close(); };
  }
  /* mode: 'click' | 'scroll' | 'waitFor'; target: { page, action?, override? } */
  async function startPick(mode, target) {
    if (S.picking) return;
    let release = null;
    let started = false;
    S.picking = { mode: mode, target: target };
    try {
      await api('POST', '/api/pick/start', { mode: mode });
      started = true;
      $('#picking-text').textContent = PICK_TEXT[mode];
      $('#picking-notice').hidden = true;
      release = holdOpen($('#picking'));
      announce('Waiting for you to click in the browser. Press Esc there to cancel.');
      let state;
      for (;;) {
        await new Promise(r => setTimeout(r, 400));
        state = await api('GET', '/api/pick');
        if (state.state !== 'picking') break;
        $('#picking-notice').textContent = state.notice || '';
        $('#picking-notice').hidden = !state.notice;
      }
      release(); release = null;
      started = false;
      if (state.state === 'done' && state.result) {
        const choice = await chooseCandidate(mode, state.result);
        if (choice) applyPick(mode, target, choice);
        else announce('Nothing was recorded.');
      }
      else if (state.state === 'cancelled') { toast(state.message || 'Picking was cancelled.'); announce(state.message || 'Picking was cancelled.'); }
      else await ask({ title: 'Nothing was recorded', body: [state.message || 'Picking stopped.'], buttons: [{ label: 'OK', value: true, primary: true }], cancelValue: true });
    } catch (e) {
      // The page may still be waiting for a click: end the pick there too (best effort).
      if (started) {
        if (release) { release(); release = null; }
        try { await api('POST', '/api/pick/cancel', {}); } catch (e2) { /* the Designer is not answering */ }
        await showError(e, 'Picking stopped: the Designer did not answer, so the pick was cancelled in the browser too.');
      }
      else showError(e, 'Picking did not work.');
    }
    finally { if (release) release(); S.picking = null; }
  }
  async function cancelPick() {
    try { await api('POST', '/api/pick/cancel', {}); } catch (e) { /* the poll reports it */ }
  }
  function candidateValueLabel(mode, c) {
    if (mode === 'scroll') return 'Area to scroll (selector)';
    if (mode === 'waitFor') return 'Element to wait for (selector)';
    return c.kind === 'text' ? 'Words to click' : 'Selector of what to click';
  }
  /*
    Shows the verified candidates, best first and pre-selected: the plain description,
    how robust it is, and the exact words or selector, which can still be edited. An
    edited value has not been checked against the page, and the dialog says so.
  */
  async function chooseCandidate(mode, result) {
    const cands = Array.isArray(result.candidates) ? result.candidates : [];
    if (!cands.length) return null;
    const element = result.element || {};
    let selected = 0;
    const name = uid('cand');
    const legendId = uid('lg');
    const inputId = uid('f');
    const input = h('input', { type: 'text', id: inputId, class: 'input mono', value: cands[0].value, spellcheck: 'false', autocomplete: 'off', dataset: { fkey: 'cand-value' } });
    const inputLabel = h('label', { for: inputId, text: candidateValueLabel(mode, cands[0]) });
    const editNote = h('p', { class: 'help', text: 'You can change it. A changed value is not checked against the page; use Test afterwards.' });
    const valueBlock = h('div', { class: 'field cand-edit', hidden: cands[0].kind === 'page' }, inputLabel, input, editNote);
    const group = h('div', { class: 'radio-group cand-list', role: 'radiogroup', 'aria-labelledby': legendId });
    cands.forEach((c, k) => {
      const id = uid('o');
      const descId = uid('d');
      const radio = h('input', { type: 'radio', name: name, id: id, class: 'radio', value: String(k), checked: k === 0, 'aria-describedby': descId, dataset: { fkey: 'cand:' + k } });
      radio.addEventListener('change', () => {
        if (!radio.checked) return;
        selected = k;
        input.value = c.value;
        inputLabel.textContent = candidateValueLabel(mode, c);
        valueBlock.hidden = c.kind === 'page';
      });
      group.appendChild(h('div', { class: 'radio-row cand-row' }, radio, h('div', { class: 'cand-main' },
        h('label', { for: id, text: sentence(c.description) }),
        h('span', { class: 'chip cand-' + c.robustness, text: ROBUST[c.robustness] || c.robustness }),
        h('p', { class: 'help', id: descId, text: c.note }),
        c.kind === 'page' ? null : h('code', { class: 'cand-value', text: c.value }))));
    });
    const what = element.kind === 'window' ? 'the whole page' : ('the ' + (element.noun || 'element') + (element.text ? ' “' + shortText(element.text, 60) + '”' : '') + (element.frame ? ' in the frame ' + element.frame : ''));
    const body = [
      h('p', {}, 'You picked ', h('strong', { text: what }), '. Vouch checked each way below in the page: replaying it reaches exactly that.'),
      element.climbedNote ? h('p', { class: 'help', text: element.climbedNote }) : null,
      result.note ? h('p', { class: 'help warning-text', text: result.note }) : null,
      h('p', { class: 'legend', id: legendId, text: cands.length === 1 ? 'The way Vouch can record it:' : 'Choose how Vouch records it (the first is the most robust):' }),
      group,
      valueBlock,
    ].filter(Boolean);
    const ok = await ask({ title: 'Record this?', body: body, buttons: [{ label: 'Use this', value: true, primary: true }, { label: 'Cancel', value: false }], cancelValue: false });
    if (!ok) return null;
    const c = cands[selected];
    const value = input.value.trim();
    if (c.kind !== 'page' && !value) { toast('Nothing was recorded: the value was empty.'); return null; }
    return { candidate: c, value: c.kind === 'page' ? '' : value, edited: c.kind !== 'page' && value !== c.value };
  }
  function applyPick(mode, target, choice) {
    const i = target.page;
    const c = choice.candidate;
    const said = sentence(c.description) + (choice.edited ? ' (edited by hand)' : '');
    if (mode === 'click') {
      const action = c.kind === 'text' ? { type: 'clickText', text: choice.value } : { type: 'click', selector: choice.value };
      if (target.action === undefined) addAction(i, action);
      else { S.clickStash = null; change(() => setAt(S.config, P('pages', i, 'actions', target.action), action), {}); }
    }
    else if (mode === 'scroll') {
      if (target.action === undefined) {
        addAction(i, { type: 'capture', scroll: c.kind === 'page' ? { mode: 'page' } : { mode: 'area', selector: choice.value, as: 'segments' } });
      }
      else {
        change(() => {
          const a = getAt(S.config, P('pages', i, 'actions', target.action));
          if (!isObj(a.scroll)) a.scroll = {};
          a.scroll.mode = c.kind === 'page' ? 'page' : 'area';
          if (c.kind === 'page') delete a.scroll.selector; else a.scroll.selector = choice.value;
        }, {});
      }
    }
    else if (target.override) change(() => setAt(S.config, P('pages', i, 'overrides', 'waitFor'), choice.value), {});
    else change(() => setAt(S.config, P('pages', i, 'actions', target.action, 'selector'), choice.value), {});
    if (choice.edited) toast('Recorded as you edited it. It was not checked against the page; try it with Test.');
    announce('Recorded: ' + said + '.');
  }
  async function testAction(i, j) {
    const page = pageAt(i);
    const action = actionsOf(page)[j];
    const key = testKey(i, j);
    S.testing = key;
    keepFocus(renderAll);
    try {
      const result = await api('POST', '/api/action/test', { action: action, config: S.config, pageIndex: i });
      S.tests[key] = { ok: !!result.ok, message: result.message || '' };
      announce((result.ok ? 'Test worked. ' : 'Test: ') + (result.message || ''));
    } catch (e) {
      S.tests[key] = { ok: false, message: e.message + (e.detail ? ' ' + e.detail : '') };
      announce('Test: ' + S.tests[key].message);
    } finally {
      S.testing = '';
      keepFocus(renderAll);
      poll(true);
    }
  }
  /*
    Runs. What runs is the configuration as shown (unsaved edits too); the saved file is
    never changed by it. Problems block it with the same list Save shows. While it goes,
    GET /api/run?since=n brings the new events and the server's view of each page every
    second; the panel stays editable (edits do not change the run in progress).
  */
  let runTimer = 0, runPlanTimer = 0, runPlanSeq = 0;
  function applyRun(data) {
    if (!data) return;
    const before = S.run;
    if (data.number !== before.number) { S.runEvents = []; S.previewImages = {}; }
    if (Array.isArray(data.events) && data.since === S.runEvents.length) S.runEvents.push(...data.events);
    S.runSince = S.runEvents.length;
    S.run = data;
    if (data.pageResults) S.pageResults = data.pageResults;
    const wasActive = RUN_ACTIVE.includes(before.state);
    if (wasActive && !RUN_ACTIVE.includes(data.state) && data.number === before.number) {
      announce(data.message || runStateText());
      poll(true);
      refreshRunPlan();
    }
    else if (before.state !== 'waitingForUser' && data.state === 'waitingForUser') announce('The run is waiting for you in the Vouch window over the browser.');
    if (data.preview && data.preview.images && data.preview.images.length) loadPreviews();
  }
  async function showRunProblems(list, kind) {
    const body = [(list.length === 1 ? 'There is 1 problem' : 'There are ' + list.length + ' problems') + ' to fix before ' + (kind === 'page' ? 'the page can be tested:' : 'the configuration can run:'),
      h('ul', { class: 'plain-list' }, list.slice(0, 12).map(p => h('li', {}, h('strong', { text: labelFor(p.path) + ': ' }), p.text)))];
    const go = await ask({ title: kind === 'page' ? 'Not tested' : 'Not run', body: body, buttons: [{ label: 'Show the first one', value: true, primary: true }, { label: 'Close', value: false }], cancelValue: false });
    if (go && list.length) jumpTo(list[0].path);
  }
  async function startRun(kind) {
    if (runActive()) return false;
    const page = pageAt(S.page);
    if (kind === 'page' && !page) { toast('Select the page to test first.'); return false; }
    runClientChecks();
    const pr = problems();
    if (pr.errors.length) { await showRunProblems(pr.errors, kind); return false; }
    S.runStarting = true;
    S.tab = 'run';
    keepFocus(renderAll);
    let started = false;
    try {
      const data = await api('POST', '/api/run', { config: S.config, path: S.path, kind: kind === 'page' ? 'page' : 'full', pageId: kind === 'page' ? pageId(page, S.page) : '' });
      S.runStarting = false;
      applyRun(data);
      started = true;
      announce(kind === 'page' ? 'Testing the page. Progress is shown in the Run tab.' : 'The run has started. Progress is shown in the Run tab.');
    } catch (e) {
      S.runStarting = false;
      if (e.status === 422 && e.data && e.data.errors) {
        S.check.errors = e.data.errors; S.check.stale = false;
        keepFocus(renderAll);
        await showRunProblems(problems().errors, kind);
      }
      else await showError(e, kind === 'page' ? 'The page was not tested.' : 'The run did not start.');
    }
    keepFocus(renderAll);
    if (started) { poll(true); runTimer = setTimeout(pollRun, 500); }
    return started;
  }
  async function pollRun() {
    clearTimeout(runTimer);
    if (S.closed) return;
    try {
      const data = await api('GET', '/api/run?since=' + S.runSince);
      if (data.number !== S.run.number && data.since > 0) { S.runSince = 0; S.runEvents = []; runTimer = setTimeout(pollRun, 0); return; }
      applyRun(data);
      if (S.tab === 'run') keepFocus(renderRun); else lightRender();
      if (RUN_ACTIVE.includes(data.state)) runTimer = setTimeout(pollRun, 1000);
    } catch (e) {
      if (RUN_ACTIVE.includes(S.run.state)) runTimer = setTimeout(pollRun, 2000);
    }
  }
  async function stopRun(force) {
    try {
      const data = await api('POST', '/api/run/stop', { force: !!force });
      applyRun(data);
      if (S.tab === 'run') keepFocus(renderRun);
      announce(force ? 'The run was ended.' : 'Stopping the run after its current step.');
      pollRun();
    } catch (e) { showError(e); }
  }
  async function openTarget(what) {
    try { await api('POST', '/api/open', { what: what }); } catch (e) { showError(e); }
  }
  /* Preview images need the token, which an <img> cannot send: fetched here, shown as data: URLs. */
  async function loadPreviews() {
    const images = S.run.preview && Array.isArray(S.run.preview.images) ? S.run.preview.images : [];
    const wanted = images.filter(img => !(img.url in S.previewImages));
    if (!wanted.length) return;
    for (const img of wanted) S.previewImages[img.url] = '';
    await Promise.all(wanted.map(async img => {
      try {
        const response = await fetch(img.url, { headers: { 'X-Vouch-Token': S.token }, cache: 'no-store', credentials: 'omit' });
        if (!response.ok) throw new Error(String(response.status));
        const blob = await response.blob();
        S.previewImages[img.url] = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result));
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(blob);
        });
      } catch (e) { S.previewImages[img.url] = 'failed'; }
    }));
    if (S.tab === 'run') keepFocus(renderRun);
  }
  function showPreviewImage(img, caption) {
    const src = S.previewImages[img.url];
    if (!src || src === 'failed') { toast('This image is not available.'); return; }
    ask({ title: caption, body: [h('img', { class: 'preview-large', src: src, alt: 'Screenshot: ' + caption })], buttons: [{ label: 'Close', value: true, primary: true }], cancelValue: true });
  }
  function scheduleRunPlan() { clearTimeout(runPlanTimer); runPlanTimer = setTimeout(refreshRunPlan, 700); }
  async function refreshRunPlan() {
    if (!S.config || S.closed) return;
    const seq = ++runPlanSeq;
    const page = pageAt(S.page);
    try {
      const full = api('POST', '/api/run/plan', { config: S.config, path: S.path, kind: 'full' });
      const pagePlan = page ? api('POST', '/api/run/plan', { config: S.config, path: S.path, kind: 'page', pageId: pageId(page, S.page) }) : Promise.resolve(null);
      const results = await Promise.all([full, pagePlan]);
      if (seq !== runPlanSeq) return;
      S.runPlan = results[0];
      S.pagePlan = results[1];
    } catch (e) {
      if (seq !== runPlanSeq) return;
      S.runPlan = null;
    }
    if (S.tab === 'run' && !runActive()) keepFocus(renderRun);
  }
  Object.assign(window.VouchDesigner, { goToUrl, addPageFromCurrentTab, startPick, cancelPick, chooseCandidate, applyPick, testAction, testKey, renderBrowser, retryBrowser, tidyWindows, zoomOff, holdOpen, startRun, pollRun, stopRun, openTarget, refreshRunPlan, loadPreviews, runActive });

  // ------------------------------------------------------------------ files
  /*
    A request that may open a Windows file dialog on the server keeps the panel modal
    until it answers: the dialog can sit behind the panel for a while, and edits made
    meanwhile would race with the answer (a Save As would mark them saved).
  */
  async function whileServerDialog(fn) {
    const release = holdOpen($('#busy'));
    try { return await fn(); }
    finally { release(); }
  }
  async function confirmDiscard(what) {
    if (!isDirty()) return true;
    const choice = await ask({
      title: 'Save your changes first?', body: ['You have changes that are not saved. ' + what],
      buttons: [{ label: 'Save', value: 'save', primary: true }, { label: 'Don’t save', value: 'discard', danger: true }, { label: 'Cancel', value: 'cancel' }], cancelValue: 'cancel',
    });
    if (choice === 'save') return await save(false);
    return choice === 'discard';
  }
  function loadDocument(result, opts) {
    S.config = result.config;
    S.path = result.path || '';
    S.fileName = result.name || '';
    S.savedJson = opts && opts.unsaved ? '' : JSON.stringify(S.config);
    S.hasComments = !!result.hasComments;
    S.logo = result.logo || null;
    S.page = 0; S.openAction = -1; S.undo = []; S.redo = []; S.coalesce = null;
    S.check.errors = result.errors || []; S.check.warnings = result.warnings || []; S.check.stale = false; S.check.preview = null;
    S.command = null;
    runClientChecks();
    renderAll();
    scheduleValidate();
    refreshCommand();
  }
  async function newConfig(skipConfirm) {
    if (!skipConfirm && !(await confirmDiscard('A new configuration replaces the one shown.'))) return;
    try { loadDocument(await api('POST', '/api/config/new', {})); announce('New configuration.'); }
    catch (e) { showError(e); }
  }
  async function openConfig(path) {
    if (!path && !(await confirmDiscard('Opening another file replaces the one shown.'))) return false;
    try {
      const result = path ? await api('POST', '/api/config/open', { path: path }) : await whileServerDialog(() => api('POST', '/api/config/open', {}));
      if (result.cancelled) return false;
      loadDocument(result);
      const n = (result.errors || []).length;
      if (n) { S.issuesOpen = true; renderIssues(); toast('Opened, with ' + n + (n === 1 ? ' problem' : ' problems') + ' to fix before it can be saved.'); }
      else announce('Opened ' + result.name + '.');
      return true;
    } catch (e) { showError(e); return false; }
  }
  async function save(saveAs) {
    runClientChecks();
    const pr = problems();
    if (pr.errors.length) { await showProblems(pr.errors); return false; }
    if (S.hasComments) {
      const ok = await ask({ title: 'This file has comments', body: ['The file has comments (// or /* */). The Designer writes the file afresh, so saving removes them. Everything else is kept.'],
        buttons: [{ label: 'Save without the comments', value: true, primary: true }, { label: 'Cancel', value: false }], cancelValue: false });
      if (!ok) return false;
    }
    try {
      // What is sent is what gets saved. Edits made while the answer is on its way stay
      // in the panel and stay marked unsaved; they are never replaced by the answer.
      const sent = JSON.stringify(S.config);
      const send = () => api('POST', '/api/config/save', { config: JSON.parse(sent), path: saveAs ? '' : S.path, saveAs: !!saveAs });
      const result = saveAs || !S.path ? await whileServerDialog(send) : await send();
      if (result.cancelled) return false;
      const page = S.page, tab = S.tab, openAction = S.openAction;
      const changedMeanwhile = JSON.stringify(S.config) !== sent;
      S.path = result.path; S.fileName = result.name;
      if (changedMeanwhile) S.savedJson = sent;
      else { S.config = result.config; S.savedJson = JSON.stringify(S.config); }
      S.hasComments = false;
      S.page = page; S.tab = tab; S.openAction = openAction;
      S.check.warnings = result.warnings || [];
      runClientChecks();
      renderAll();
      refreshCommand();
      if (result.notices && result.notices.length) toast(result.notices.join(' '));
      else toast('Saved ' + result.name + '.' + (changedMeanwhile ? ' Changes made while saving are not saved yet.' : ''));
      return true;
    } catch (e) {
      if (e.status === 422 && e.data && e.data.errors) {
        S.check.errors = e.data.errors; S.check.stale = false;
        renderAll();
        await showProblems(problems().errors);
        return false;
      }
      showError(e, 'The configuration was not saved.');
      return false;
    }
  }
  async function showProblems(list) {
    const body = [list.length === 1 ? 'There is 1 problem to fix before saving:' : 'There are ' + list.length + ' problems to fix before saving:',
      h('ul', { class: 'plain-list' }, list.slice(0, 12).map(p => h('li', {}, h('strong', { text: labelFor(p.path) + ': ' }), p.text)))];
    const go = await ask({ title: 'Not saved yet', body: body, buttons: [{ label: 'Show the first one', value: true, primary: true }, { label: 'Close', value: false }], cancelValue: false });
    if (go && list.length) jumpTo(list[0].path);
  }
  async function importCsv() {
    let result;
    try { result = await whileServerDialog(() => api('POST', '/api/config/import-csv', {})); }
    catch (e) { showError(e); return; }
    if (result.cancelled) return;
    const incoming = Array.isArray(result.pages) ? result.pages : [];
    let mode = 'add';
    if (pagesOf(S.config).length) {
      mode = await ask({ title: 'Import ' + incoming.length + (incoming.length === 1 ? ' page' : ' pages'),
        body: ['From ' + result.name + '. Add them after the pages you have, or start a new configuration with only these pages?'],
        buttons: [{ label: 'Add to this configuration', value: 'add', primary: true }, { label: 'Start a new configuration', value: 'new' }, { label: 'Cancel', value: 'cancel' }], cancelValue: 'cancel' });
      if (mode === 'cancel') return;
      if (mode === 'new') {
        if (!(await confirmDiscard('A new configuration replaces the one shown.'))) return;
        const fresh = await api('POST', '/api/config/new', {});
        fresh.config.name = result.title || '';
        fresh.config.pages = incoming;
        loadDocument(fresh, { unsaved: true });
        toast('Imported ' + incoming.length + ' page(s) from ' + result.name + '. Save to keep them.');
        return;
      }
    }
    change(c => {
      const pages = ensurePages(c);
      for (const page of incoming) {
        const used = new Set(pages.map((p, i) => pageId(p, i).toLowerCase()));
        if (used.has(String(page.id || '').toLowerCase())) {
          for (let n = 1; ; n++) { const id = 'p' + String(n).padStart(3, '0'); if (!used.has(id)) { page.id = id; break; } }
        }
        pages.push(page);
      }
      if (typeof c.name !== 'string' || !c.name.trim()) c.name = result.title || '';
    }, { render: 'none' });
    S.tab = 'pages';
    S.page = Math.max(0, pagesOf(S.config).length - incoming.length);
    renderAll();
    toast('Imported ' + incoming.length + ' page(s) from ' + result.name + '.');
  }
  async function closeDesigner() {
    const running = runActive();
    if (running) {
      const ok = await ask({ title: 'A run is going', body: ['Closing the Designer stops the run first: it ends after its current step and still writes its report. Then the Designer closes.'],
        buttons: [{ label: 'Stop the run and close', value: true, danger: true }, { label: 'Cancel', value: false, primary: true }], cancelValue: false });
      if (!ok) return;
    }
    if (!(await confirmDiscard('Closing the Designer loses them.'))) return;
    S.savedJson = JSON.stringify(S.config);
    clearTimeout(runTimer);
    try { await api('POST', '/api/shutdown', running ? { stopRun: true } : {}); } catch (e) { /* already gone */ }
    showClosed(running ? 'The run is being stopped; the Vouch Designer closes as soon as it has. You can close this window.' : 'The Vouch Designer has stopped. You can close this window.');
  }
  function showClosed(text) {
    S.closed = true;
    clearInterval(pollTimer);
    $('#app').replaceChildren(h('div', { class: 'closed' }, h('h1', { text: 'Vouch Designer' }), h('p', { text: text })));
  }
  Object.assign(window.VouchDesigner, { newConfig, openConfig, save, importCsv, whileServerDialog });

  // ------------------------------------------------------------------ server state polling
  let pollTimer = 0, pollFailures = 0;
  function applyServerState(state) {
    S.server = state;
    const caps = state.capabilities || {};
    const changed = JSON.stringify(caps) !== JSON.stringify(S.capabilities);
    S.capabilities = { browser: !!caps.browser, pick: !!caps.pick, test: !!caps.test, run: !!caps.run };
    const before = S.browser;
    S.browser = state.browser || { connected: false };
    if (JSON.stringify(before) !== JSON.stringify(S.browser)) {
      renderBrowser();
      const said = browserAnnouncement(before, S.browser);
      if (said) announce(said);
    }
    if (state.run && state.run.state && (state.run.state !== S.run.state || state.run.number !== S.run.number)) pollRun();
    if (changed && S.config) renderAll();
  }
  async function poll(force) {
    if (S.closed || (document.hidden && force !== true)) return;
    try { applyServerState(await api('GET', '/api/state')); pollFailures = 0; $('#banner').hidden = true; }
    catch (e) { pollFailures += 1; if (pollFailures >= 2) serverGone(); }
  }
  function serverGone() {
    const banner = $('#banner');
    banner.textContent = 'The Vouch Designer is not answering. It may have been closed: start it again with Vouch-Designer.cmd. Changes you did not save are only in this window.';
    banner.hidden = false;
  }

  // ------------------------------------------------------------------ keyboard and window
  document.addEventListener('keydown', ev => {
    if ($('#modal').open || $('#busy').open || $('#picking').open || S.closed) return;
    const mod = ev.ctrlKey || ev.metaKey;
    if (!mod) return;
    const key = ev.key.toLowerCase();
    if (key === 's') { ev.preventDefault(); save(ev.shiftKey); }
    else if (key === 'z' && !ev.shiftKey) { ev.preventDefault(); undo(); }
    else if (key === 'y' || (key === 'z' && ev.shiftKey)) { ev.preventDefault(); redo(); }
  });
  window.addEventListener('beforeunload', ev => {
    if (!S.closed && (isDirty() || runActive())) { ev.preventDefault(); ev.returnValue = ''; }
  });

  // ------------------------------------------------------------------ start
  async function start() {
    const params = new URLSearchParams(location.search);
    let token = params.get('t') || '';
    // The token leaves the address bar at once (no history, no screenshots of it). It is
    // also kept in this window's sessionStorage so that a reload (F5) keeps working; the
    // storage belongs to this window only and ends with it.
    try {
      if (token) sessionStorage.setItem('vouch-token', token);
      else token = sessionStorage.getItem('vouch-token') || '';
    } catch (e) { /* storage blocked: memory only */ }
    if (params.has('t')) history.replaceState(null, '', location.pathname);
    S.token = token;
    buildChrome();
    $('#busy').addEventListener('cancel', ev => ev.preventDefault());
    $('#picking').addEventListener('cancel', ev => ev.preventDefault());
    $('#picking-cancel').addEventListener('click', () => cancelPick());
    renderBrowser();
    if (!token) { showClosed('Open the Vouch Designer with Vouch-Designer.cmd (or vouch.ps1 -Designer); this address alone cannot be used.'); return; }
    let state;
    try { state = await api('GET', '/api/state'); }
    catch (e) {
      showClosed(e.status === 403 ? 'This window belongs to an earlier Designer session. Close it and start the Vouch Designer again.' : e.message + ' ' + e.detail);
      return;
    }
    S.schema = state.schema;
    S.defaults = state.defaults;
    applyServerState(state);
    let opened = false;
    if (state.startupPath) opened = await openConfig(state.startupPath);
    if (!opened) await newConfig(true);
    pollTimer = setInterval(poll, 2500);
  }
  window.VouchDesigner.ready = new Promise(resolve => {
    const go = () => start().then(resolve, err => { resolve(); throw err; });
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go); else go();
  });
})();
