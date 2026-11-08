'use strict';
// Shared OrunDocs desktop E2E (Windows + macOS). Drives the REAL packaged Electron app
// through Chromium remote debugging (playwright-core connectOverCDP). Does not modify the app.
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { spawn, spawnSync } = require('node:child_process');

const wait = ms => new Promise(r => setTimeout(r, ms));
const sha256 = buf => crypto.createHash('sha256').update(buf).digest('hex');
function getJson(url) {
  return new Promise((res, rej) => {
    const r = http.get(url, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => { try { res(JSON.parse(b)); } catch (e) { rej(e); } }); });
    r.on('error', rej); r.setTimeout(3000, () => r.destroy(Error('timeout')));
  });
}
function withTimeout(p, ms, label) {
  let t; return Promise.race([p, new Promise((_, rej) => { t = setTimeout(() => rej(Error(label + ' timed out after ' + ms + 'ms')), ms); })]).finally(() => clearTimeout(t));
}
// Minimal ZIP reader (central directory) to pull one entry out of a DOCX.
function zipEntries(buf) {
  let e = buf.length - 22; while (e >= 0 && buf.readUInt32LE(e) !== 0x06054b50) e--; if (e < 0) throw Error('not a zip');
  const n = buf.readUInt16LE(e + 10); let p = buf.readUInt32LE(e + 16); const out = {};
  for (let i = 0; i < n; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw Error('bad central dir');
    const method = buf.readUInt16LE(p + 10), csize = buf.readUInt32LE(p + 20), nl = buf.readUInt16LE(p + 28), el = buf.readUInt16LE(p + 30), cl = buf.readUInt16LE(p + 32), local = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nl);
    out[name] = () => { const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28); const raw = buf.subarray(start, start + csize); return method === 8 ? zlib.inflateRawSync(raw) : raw; };
    p += 46 + nl + el + cl;
  }
  return out;
}

const HOOK = () => {
  if (window.__e2eHooked) return 'already'; window.__e2eHooked = true; window.__dl = [];
  const blobs = new Map(); const oc = URL.createObjectURL;
  URL.createObjectURL = function (o) { const u = oc.call(URL, o); try { if (o instanceof Blob) blobs.set(u, o); } catch {} return u; };
  const click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    try {
      if (this.download && blobs.has(this.href)) {
        const b = blobs.get(this.href); const rec = { name: this.download, size: b.size, type: b.type, at: Date.now() }; window.__dl.push(rec);
        b.arrayBuffer().then(async ab => { const h = await crypto.subtle.digest('SHA-256', ab); rec.sha256 = [...new Uint8Array(h)].map(x => x.toString(16).padStart(2, '0')).join(''); rec.head = Array.from(new Uint8Array(ab.slice(0, 5))).map(c => String.fromCharCode(c)).join(''); }).catch(e => { rec.err = String(e); });
      }
    } catch (e) {}
    return click.call(this);
  };
  return 'hooked';
};

async function runE2E(o) {
  // o: { exe, out, fixtures, port, saveMode: 'native'|'cdp-bypass', saveHandler: async({name,dest,shotPath}) => ({savedPath,...}), label }
  const out = o.out;
  const shotsDir = path.join(out, 'shots'), savedDir = path.join(out, 'saved');
  await fsp.mkdir(shotsDir, { recursive: true }); await fsp.mkdir(savedDir, { recursive: true });
  const logLines = [], appLog = [];
  const L = (...a) => { const s = new Date().toISOString() + ' ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' '); logLines.push(s); console.log(s); };
  const R = { label: o.label, exe: o.exe, platform: process.platform, saveMode: o.saveMode, checks: {}, saves: {}, events: { crash: 0, pageErrors: [], consoleErrors: [], playwrightDownloads: [] }, startedAt: new Date().toISOString() };
  const setCheck = (id, status, detail, evidence = []) => { R.checks[id] = { status, detail, evidence: evidence.filter(Boolean) }; L('CHECK', id, status, detail); };
  let child, browser, page, cdpHung = false;
  let TOKEN = '', tokenSource = 'none';
  const EXPECT_EMAIL = (process.env.OD_REVIEW_EMAIL || '').trim().toLowerCase();
  async function acquireToken() {
    if (process.env.OD_REVIEW_EMAIL && process.env.OD_REVIEW_PASSWORD) {
      try {
        const r = await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyCtvGwVSwR0YoxPwNiVBLAWTDkyr-hDh3c', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: process.env.OD_REVIEW_EMAIL, password: process.env.OD_REVIEW_PASSWORD, returnSecureToken: true }) });
        const j = await r.json();
        if (r.ok && j.refreshToken) { TOKEN = j.refreshToken; tokenSource = 'signInWithPassword(OD_REVIEW_EMAIL)'; process.stdout.write('::add-mask::' + TOKEN + '\n'); if (j.idToken) process.stdout.write('::add-mask::' + j.idToken + '\n'); }
        else tokenSource = 'signInWithPassword failed: HTTP ' + r.status + ' ' + (j.error && j.error.message || '');
      } catch (e) { tokenSource = 'signInWithPassword error: ' + e.message; }
    } else if (process.env.OD_TEST_REFRESH_TOKEN) { TOKEN = process.env.OD_TEST_REFRESH_TOKEN; tokenSource = 'OD_TEST_REFRESH_TOKEN'; }
    R.tokenSource = tokenSource; L('token source', tokenSource, 'present=' + !!TOKEN);
  }
  const shot = async name => { const f = path.join(shotsDir, name); try { await withTimeout(page.screenshot({ path: f }), 20000, 'screenshot'); return path.relative(out, f).split(path.sep).join('/'); } catch (e) { L('screenshot failed', name, e.message); return null; } };
  const ev = (fn, arg, ms = 30000) => withTimeout(page.evaluate(fn, arg), ms, 'page.evaluate');

  async function doSave(selector, name, kind) {
    const dest = path.join(savedDir, name);
    try { fs.rmSync(dest, { force: true }); } catch {}
    const rec = { name, selector, mode: o.saveMode, dest: path.relative(out, dest).split(path.sep).join('/') };
    if (cdpHung) { rec.status = 'blocked'; rec.detail = 'CDP unresponsive after an earlier native dialog'; return rec; }
    const before = await ev(() => window.__dl.length);
    await ev(sel => { setTimeout(() => document.querySelector(sel).click(), 50); return true; }, selector);
    let savedPath = dest;
    if (o.saveMode === 'native') {
      try { const h = await o.saveHandler({ name, dest, kind, shotPath: path.join(shotsDir, 'dialog-' + kind + '.png') }); rec.handler = h; if (h && h.savedPath) savedPath = h.savedPath; }
      catch (e) { rec.handler = { error: String(e.message || e) }; }
    }
    let st = null; const until = Date.now() + 60000;
    while (Date.now() < until) {
      try { const s = fs.statSync(savedPath); if (s.size > 0) { await wait(800); const s2 = fs.statSync(savedPath); if (s2.size === s.size) { st = s2; break; } } } catch {}
      await wait(500);
    }
    if (!st && rec.handler && Array.isArray(rec.handler.altPaths)) for (const alt of rec.handler.altPaths) { try { const s3 = fs.statSync(alt); if (s3.size > 0) { rec.writtenUnderDifferentName = alt; L('file appeared under a different name', alt); } } catch {} }
    if (st && savedPath !== dest) { fs.copyFileSync(savedPath, dest); rec.originalSavedPath = savedPath; }
    let inPage = null;
    try { await wait(500); inPage = await ev((args) => { const l = window.__dl.slice(args.before); return l.filter(d => d.name === args.name).pop() || l.pop() || null; }, { before, name }, 20000); }
    catch (e) { cdpHung = true; rec.cdpError = e.message; }
    rec.inPage = inPage;
    if (st) {
      const buf = fs.readFileSync(dest); rec.file = { bytes: buf.length, sha256: sha256(buf), head: buf.subarray(0, 5).toString('latin1') };
      rec.matchesInPageBytes = !!(inPage && inPage.sha256 === rec.file.sha256);
      rec.status = 'written';
    } else rec.status = 'not-written';
    R.saves[kind] = rec; L('SAVE', kind, JSON.stringify(rec));
    return rec;
  }
  const mask = e => { const m = String(e || '').match(/^(.{0,4})[^@]*(@.*)$/); return m ? m[1] + '***' + m[2] : (e ? '(no @)' : ''); };
  async function waitUnlocked(ms) {
    const t0 = Date.now(); let last = null;
    while (Date.now() - t0 < ms) {
      try { last = await ev(() => ({ locked: document.documentElement.classList.contains('od-locked'), account: document.getElementById('od-account')?.textContent || '', accountHidden: document.getElementById('od-account')?.hidden, msg: document.querySelector('#od-gate .od-msg')?.textContent || '', kind: document.querySelector('#od-gate .od-msg')?.dataset.kind || '' }), null, 10000); } catch (e) { last = { error: e.message }; }
      if (last && last.locked === false && /@/.test(last.account || '')) break;
      if (last && last.kind === 'err') break;
      await wait(500);
    }
    const acct = (last && last.account) || '';
    // Privacy (public repo): never store the full address; record a mask + sha256 for comparison.
    try { await ev(() => { const c = document.getElementById('od-account'); if (c) c.style.filter = 'blur(5px)'; return true; }); } catch {}
    const plain = acct.replace(/^오프라인 · /, '').trim().toLowerCase();
    return { matchesExpectedAccount: EXPECT_EMAIL ? plain === EXPECT_EMAIL : null, unlocked: !!last && last.locked === false, accountHasAt: /@/.test(acct), accountMasked: mask(acct.replace(/^오프라인 · /, '')), accountSha256: acct ? sha256(Buffer.from(acct.replace(/^오프라인 · /, '').trim())) : null, offlineMode: /^오프라인/.test(acct), gateMsgIfLocked: last && last.locked ? last.msg : null, ms: Date.now() - t0 };
  }
  async function startApp(label) {
    child = spawn(o.exe, ['--remote-debugging-port=' + o.port, '--remote-debugging-address=127.0.0.1'], { stdio: ['ignore', 'pipe', 'pipe'], cwd: path.dirname(o.exe) });
    const me = child;
    child.stdout.on('data', d => appLog.push(String(d))); child.stderr.on('data', d => appLog.push(String(d)));
    child.on('exit', (c, s) => L('app process exited', label, c, s)); child.on('error', e => L('spawn error', e.message));
    (R.launches = R.launches || []).push({ label, pid: child.pid }); L('launched', label, o.exe, 'pid', child.pid);
    let ver; const until = Date.now() + 120000;
    while (Date.now() < until) { try { ver = await getJson('http://127.0.0.1:' + o.port + '/json/version'); break; } catch {} if (me.exitCode !== null) throw Error('app exited before CDP endpoint, code ' + me.exitCode); await wait(500); }
    if (!ver) throw Error('CDP endpoint never appeared on port ' + o.port);
    R.cdp = { browser: ver.Browser, userAgent: ver['User-Agent'], protocol: ver['Protocol-Version'] }; L('CDP up', ver.Browser);
    const { chromium } = require('playwright-core');
    R.playwrightCore = require('playwright-core/package.json').version;
    browser = await chromium.connectOverCDP('http://127.0.0.1:' + o.port, { timeout: 60000 });
    try {
      const b = await browser.newBrowserCDPSession();
      if (o.saveMode === 'cdp-bypass') await b.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: savedDir, eventsEnabled: true });
      else await b.send('Browser.setDownloadBehavior', { behavior: 'default' });
      R.downloadBehavior = o.saveMode === 'cdp-bypass' ? 'allow (bypasses app save dialog)' : 'default (app will-download + native save dialog)';
    } catch (e) { R.downloadBehavior = 'setDownloadBehavior failed: ' + e.message; L(R.downloadBehavior); }
    const ctx = browser.contexts()[0]; const until2 = Date.now() + 60000; page = null;
    while (Date.now() < until2) { page = ctx.pages().find(p => p.url().startsWith('http://127.0.0.1:')); if (page) break; await wait(300); }
    if (!page) throw Error('No app window page found via CDP. Pages: ' + ctx.pages().map(p => p.url()).join(', '));
    L('page', page.url().replace(/#.*/, ''));
    page.on('crash', () => { R.events.crash++; L('RENDERER CRASH'); });
    page.on('pageerror', e => R.events.pageErrors.push(String(e.message || e).slice(0, 400)));
    page.on('console', m => { if (m.type() === 'error') R.events.consoleErrors.push(m.text().slice(0, 400)); });
    page.on('download', d => R.events.playwrightDownloads.push(d.suggestedFilename()));
  }
  async function stopApp() {
    try { if (page && !cdpHung) await withTimeout(page.close(), 15000, 'page.close'); } catch (e) { L('page.close', e.message); }
    try { if (browser) await withTimeout(browser.close(), 10000, 'browser.close'); } catch (e) { L('browser.close', e.message); }
    let graceful = null;
    if (child) {
      const c = child; const exited = () => c.exitCode !== null || c.signalCode !== null;
      const t = Date.now() + 30000; while (!exited() && Date.now() < t) await wait(300);
      graceful = exited();
      if (!exited()) {
        L('app still running; terminating');
        if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(c.pid), '/T'], { stdio: 'ignore' }); else c.kill('SIGTERM');
        const t2 = Date.now() + 15000; while (!exited() && Date.now() < t2) await wait(300);
        if (!exited()) { if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(c.pid), '/T', '/F'], { stdio: 'ignore' }); else c.kill('SIGKILL'); await wait(2000); }
      }
      R.exitCode = c.exitCode; R.exitSignal = c.signalCode;
    }
    page = null; browser = null; child = null;
    return graceful;
  }
  async function home() { await page.locator('#home-nav').click(); await page.waitForSelector('#tools-home:not([hidden])', { timeout: 20000 }); }
  async function openCard(title) { await home(); await page.getByRole('button', { name: title + ' 도구 열기', exact: true }).click(); }

  try {
    await acquireToken();
    await startApp('first launch');

    // ---- Check G1: sign-in gate shown, workspace hidden
    try {
      await page.waitForSelector('#od-gate', { state: 'attached', timeout: 30000 });
      await page.waitForFunction(() => /로그인해 주세요/.test(document.querySelector('#od-gate .od-msg')?.textContent || ''), null, { timeout: 45000 }).catch(() => {});
      const g = await ev(() => { const gate = document.getElementById('od-gate'), btn = document.querySelector('#od-gate .od-google'), sb = document.querySelector('.app-sidebar'), main = document.getElementById('app-main');
        return { locked: document.documentElement.classList.contains('od-locked'), gateHidden: gate ? gate.hidden : null, gateVisible: gate ? getComputedStyle(gate).display !== 'none' && gate.getBoundingClientRect().width > 0 : false,
          msg: document.querySelector('#od-gate .od-msg')?.textContent || '', button: btn ? btn.textContent : null, buttonVisible: btn ? !btn.hidden && btn.getBoundingClientRect().width > 0 : false,
          cardText: (document.querySelector('#od-gate .od-card')?.textContent || '').replace(/\s+/g, ' ').trim(), subtitleRemoved: !(document.querySelector('#od-gate .od-card')?.textContent || '').includes('문서 작업 공간'), sidebarVisibility: sb ? getComputedStyle(sb).visibility : null, mainVisibility: main ? getComputedStyle(main).visibility : null, accountHidden: document.getElementById('od-account')?.hidden }; });
      R.gate = g;
      const s = await shot('00a-signin-gate.png');
      const ok = g.locked && g.gateHidden === false && g.gateVisible && /로그인 \(Google · Apple\)/.test(g.button || '') && g.buttonVisible && /로그인해 주세요/.test(g.msg) && g.sidebarVisibility === 'hidden' && g.subtitleRemoved;
      setCheck('G1-signin-gate-shown-workspace-hidden', ok ? 'passed' : 'failed', JSON.stringify(g), [s]);
    } catch (e) { setCheck('G1-signin-gate-shown-workspace-hidden', 'failed', 'error: ' + e.message, [await shot('00a-gate-error.png')]); }

    // ---- Check G2: real allowed-account unlock via the app's IPC store + Google refresh + allowlist
    if (TOKEN) {
      try {
        const setRes = await ev(async t => { try { await window.pdfDesktop.auth.set({ v: 1, email: '', refreshToken: t, lastVerifiedAt: 0, maxSeenAt: 0 }); return 'stored'; } catch (e) { return 'auth.set error: ' + String(e && e.message || e); } }, TOKEN);
        if (setRes !== 'stored') throw Error(setRes);
        await page.reload({ waitUntil: 'domcontentloaded' });
        const r = await waitUnlocked(90000);
        R.login = { method: 'refresh-token secret via window.pdfDesktop.auth.set + reload', ...r };
        const s = await shot('00b-signed-in.png');
        setCheck('G2-real-account-unlock', r.unlocked && r.accountHasAt && r.matchesExpectedAccount !== false ? 'passed' : 'failed', JSON.stringify(r), [s]);
      } catch (e) { R.login = { error: e.message }; setCheck('G2-real-account-unlock', 'failed', 'error: ' + e.message, [await shot('00b-login-error.png')]); }
    } else {
      setCheck('G2-real-account-unlock', 'not-verified', 'no refresh token (' + tokenSource + '): gate hidden by harness, login path NOT verified');
    }
    if (await ev(() => document.documentElement.classList.contains('od-locked'))) {
      L('gate still locked; hiding it so tool checks can run (login NOT counted as verified)');
      R.gateBypassedForToolChecks = true;
      await ev(() => { document.documentElement.classList.remove('od-locked'); const g = document.getElementById('od-gate'); if (g) g.hidden = true; return true; });
    }
    await page.waitForSelector('#tools-home:not([hidden])', { timeout: 60000 });
    await page.waitForFunction(() => document.querySelectorAll('#tool-grid .tool-card').length > 0, null, { timeout: 30000 });
    L('hook', await ev(HOOK));

    // ---- Check 1: window loads, footer 3.5.0, 32 tools
    try {
      await wait(1500);
      const info = await ev(async () => ({
        ua: navigator.userAgent, title: document.title,
        footer: document.querySelector('.app-statusbar')?.textContent,
        total: document.getElementById('tool-total')?.textContent,
        cards: document.querySelectorAll('#tool-grid .tool-card').length,
        catalogCount: document.getElementById('catalog-count')?.textContent,
        desktop: await (window.pdfDesktop?.getInfo?.() || Promise.resolve(null)).catch(e => String(e)),
        health: await fetch('/api/health').then(r => r.json()).catch(e => String(e)),
        toolStatus: await fetch('/api/tool-status').then(r => r.json()).catch(e => String(e)),
        win: { w: innerWidth, h: innerHeight },
      }));
      R.appInfo = info;
      const s = await shot('01-home.png');
      const electron = (info.ua.match(/Electron\/([\d.]+)/) || [])[1];
      const ok = new RegExp((o.expectVersion || '3.5.0').replace(/\./g, '\\.')).test(info.footer || '') && info.cards === 32 && /32/.test(info.total || '');
      setCheck('1-window-footer-catalog', ok ? 'passed' : 'failed', `footer="${(info.footer || '').trim()}", tool-total="${info.total}", cards=${info.cards}, catalog-count="${info.catalogCount}", Electron=${electron}, desktopInfo=${JSON.stringify(info.desktop)}, health.version=${info.health && info.health.version}`, [s]);
    } catch (e) { setCheck('1-window-footer-catalog', 'failed', 'error: ' + e.message, [await shot('01-home-error.png')]); }

    // ---- Check 2: exam scan (handwriting removal) + save as PDF
    try {
      await openCard('시험지 필기 지우기');
      await page.waitForSelector('#exam-view:not([hidden])', { timeout: 20000 });
      await page.locator('#exam-pick').setInputFiles(path.join(o.fixtures, 'exam-photo.jpg'));
      await page.waitForFunction(() => (document.getElementById('exam-status')?.textContent || '').includes('확인한 뒤'), null, { timeout: 120000 });
      const st1 = await ev(() => document.getElementById('exam-status').textContent);
      const s1 = await shot('02a-exam-photo-detected.png');
      await page.locator('#exam-run').click();
      await page.waitForFunction(() => { const s = document.getElementById('exam-status'); return s && ((s.textContent || '').includes('처리 완료') || s.classList.contains('is-error')); }, null, { timeout: 300000 });
      const ex = await ev(() => { const s = document.getElementById('exam-status'), c = document.getElementById('exam-canvas'); let ink = null; try { const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let dark = 0; for (let i = 0; i < d.length; i += 16) if (d[i] + d[i + 1] + d[i + 2] < 300) dark++; ink = dark / (d.length / 16); } catch (e) { ink = String(e); } return { status: s.textContent, isError: s.classList.contains('is-error'), anyError: !!document.querySelector('#exam-view .is-error'), canvas: c ? { w: c.width, h: c.height } : null, darkFraction: ink }; });
      const s2 = await shot('02b-exam-processed.png');
      const ok = ex.status.includes('처리 완료') && !ex.isError && !ex.anyError && ex.canvas && ex.canvas.w > 300;
      R.exam = { detectStatus: st1, ...ex };
      setCheck('2a-exam-process', ok ? 'passed' : 'failed', `detect status="${st1}"; run status="${ex.status}"; canvas=${JSON.stringify(ex.canvas)}; darkPixelFraction=${ex.darkFraction}; is-error=${ex.isError || ex.anyError}`, [s1, s2]);
      await page.fill('#exam-name', 'exam-e2e');
      await page.selectOption('#exam-format', 'pdf');
      const sv = await doSave('#exam-save', 'exam-e2e.pdf', 'exam-pdf');
      let statusAfter = null; try { statusAfter = await ev(() => document.getElementById('exam-status').textContent, null, 15000); } catch {}
      const s3 = cdpHung ? null : await shot('02c-exam-after-save.png');
      const okSave = sv.status === 'written' && sv.file.head.startsWith('%PDF') && sv.file.bytes > 1000;
      setCheck('2b-exam-save-pdf', okSave ? 'passed' : (sv.status === 'blocked' ? 'blocked' : 'failed'), `mode=${o.saveMode}; ${sv.status}; file=${JSON.stringify(sv.file || null)}; inPage=${JSON.stringify(sv.inPage)}; bytesMatchInPage=${sv.matchesInPageBytes}; status after="${statusAfter}"; handler=${JSON.stringify(sv.handler || null)}`, [s3, sv.handler && sv.handler.shot, sv.status === 'written' ? sv.dest : null]);
    } catch (e) { setCheck(R.checks['2a-exam-process'] ? '2b-exam-save-pdf' : '2a-exam-process', 'failed', 'error: ' + e.message, [await shot('02-exam-error.png')]); }

    // ---- Check 3: PDF split with preview of the 6-page PDF + save one result
    try {
      if (cdpHung) throw Error('skipped: CDP unresponsive');
      await openCard('PDF 분할');
      await page.waitForSelector('#suite-view:not([hidden])', { timeout: 20000 });
      await page.locator('#suite-picker').setInputFiles(path.join(o.fixtures, 'preview-six-pages.pdf'));
      await page.waitForFunction(() => { const c = document.getElementById('suite-canvas'), p = document.getElementById('suite-preview'); return c && p && !p.hidden && c.width > 1 && c.height > 1; }, null, { timeout: 60000 });
      await wait(1500);
      const pv = await ev(() => ({ canvas: (c => ({ w: c.width, h: c.height }))(document.getElementById('suite-canvas')), thumbs: document.querySelectorAll('#suite-preview .pdf-preview-thumbs button').length, text: document.getElementById('suite-preview').innerText.replace(/\s+/g, ' ').slice(0, 300) }));
      const s1 = await shot('03a-split-preview.png');
      await page.locator('#suite-run').click();
      await page.waitForFunction(() => { const s = document.getElementById('suite-status'); return s && !s.hidden && (/처리가 완료/.test(s.textContent) || s.classList.contains('is-error')); }, null, { timeout: 180000 });
      const res = await ev(() => { const s = document.getElementById('suite-status'); const btns = [...document.querySelectorAll('#suite-output-files button')].filter(b => b.textContent === '다운로드'); if (btns[0]) btns[0].setAttribute('data-e2e-dl', 'split'); return { status: s.textContent, isError: s.classList.contains('is-error'), outputs: btns.map(b => (b.getAttribute('aria-label') || '').replace(/ 다운로드$/, '')), summary: document.getElementById('suite-summary')?.textContent }; });
      const s2 = await shot('03b-split-result.png');
      const okRun = !res.isError && res.outputs.length === 6 && pv.canvas.w > 1;
      setCheck('3a-split-preview-and-result', okRun ? 'passed' : 'failed', `preview canvas=${JSON.stringify(pv.canvas)} thumbs=${pv.thumbs} text="${pv.text}"; status="${res.status}"; outputs(${res.outputs.length})=${JSON.stringify(res.outputs)}`, [s1, s2]);
      if (res.outputs[0]) {
        const sv = await doSave('[data-e2e-dl="split"]', res.outputs[0], 'split-pdf');
        const okSave = sv.status === 'written' && sv.file.head.startsWith('%PDF');
        setCheck('3b-split-save-pdf', okSave ? 'passed' : (sv.status === 'blocked' ? 'blocked' : 'failed'), `mode=${o.saveMode}; ${sv.status}; file=${JSON.stringify(sv.file || null)}; bytesMatchInPage=${sv.matchesInPageBytes}; handler=${JSON.stringify(sv.handler || null)}`, [sv.handler && sv.handler.shot, sv.status === 'written' ? sv.dest : null]);
      }
    } catch (e) { setCheck(R.checks['3a-split-preview-and-result'] ? '3b-split-save-pdf' : '3a-split-preview-and-result', cdpHung ? 'blocked' : 'failed', 'error: ' + e.message, cdpHung ? [] : [await shot('03-split-error.png')]); }

    // ---- Check 4: Python-backed PDF -> Word
    try {
      if (cdpHung) throw Error('skipped: CDP unresponsive');
      await openCard('PDF → Word');
      await page.waitForSelector('#suite-view:not([hidden])', { timeout: 20000 });
      const req = await ev(() => ({ hidden: document.getElementById('suite-requirement').hidden, text: document.getElementById('suite-requirement').textContent }));
      await page.locator('#suite-picker').setInputFiles(path.join(o.fixtures, 'preview-six-pages.pdf'));
      await wait(1500);
      const exportResp = page.waitForResponse(r => r.url().includes('/api/document-export'), { timeout: 240000 }).then(r => ({ status: r.status(), type: r.headers()['content-type'] })).catch(e => ({ error: e.message }));
      await page.locator('#suite-run').click();
      await page.waitForFunction(() => { const s = document.getElementById('suite-status'); return s && !s.hidden && (/처리가 완료/.test(s.textContent) || s.classList.contains('is-error')); }, null, { timeout: 240000 });
      const api = await exportResp;
      const res = await ev(() => { const s = document.getElementById('suite-status'); const btns = [...document.querySelectorAll('#suite-output-files button')].filter(b => b.textContent === '다운로드'); if (btns[0]) btns[0].setAttribute('data-e2e-dl', 'word'); return { status: s.textContent, isError: s.classList.contains('is-error'), outputs: btns.map(b => (b.getAttribute('aria-label') || '').replace(/ 다운로드$/, '')) }; });
      const s1 = await shot('04a-pdf-to-word-result.png');
      const okRun = !res.isError && res.outputs.length >= 1 && /\.docx$/i.test(res.outputs[0]) && api.status === 200;
      setCheck('4a-pdf-to-word-python', okRun ? 'passed' : 'failed', `requirement=${JSON.stringify(req)}; /api/document-export=${JSON.stringify(api)}; status="${res.status}"; outputs=${JSON.stringify(res.outputs)}`, [s1]);
      if (res.outputs[0]) {
        const sv = await doSave('[data-e2e-dl="word"]', res.outputs[0], 'word-docx');
        let docText = null;
        if (sv.status === 'written') { try { const z = zipEntries(fs.readFileSync(path.join(savedDir, res.outputs[0]))); docText = z['word/document.xml'] ? z['word/document.xml']().toString('utf8').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 300) : 'word/document.xml missing; entries=' + Object.keys(z).join(','); } catch (e) { docText = 'zip parse error: ' + e.message; } }
        sv.documentXmlText = docText;
        const okSave = sv.status === 'written' && sv.file.head.startsWith('PK') && /PAGE/i.test(docText || '');
        setCheck('4b-word-save-docx', okSave ? 'passed' : (sv.status === 'blocked' ? 'blocked' : 'failed'), `mode=${o.saveMode}; ${sv.status}; file=${JSON.stringify(sv.file || null)}; bytesMatchInPage=${sv.matchesInPageBytes}; document.xml text="${docText}"; handler=${JSON.stringify(sv.handler || null)}`, [sv.handler && sv.handler.shot, sv.status === 'written' ? sv.dest : null]);
      }
    } catch (e) { setCheck(R.checks['4a-pdf-to-word-python'] ? '4b-word-save-docx' : '4a-pdf-to-word-python', cdpHung ? 'blocked' : 'failed', 'error: ' + e.message, cdpHung ? [] : [await shot('04-word-error.png')]); }

    // ---- Check 5: no renderer crash, page still responsive
    try {
      const alive = await ev(() => 1 + 1, null, 15000);
      const s = await shot('05-final.png');
      const ok = R.events.crash === 0 && alive === 2 && child.exitCode === null;
      setCheck('5-no-renderer-crash', ok ? 'passed' : 'failed', `crash events=${R.events.crash}; page responsive=${alive === 2}; app process alive=${child.exitCode === null}; pageErrors=${R.events.pageErrors.length}; consoleErrors=${R.events.consoleErrors.length}`, [s]);
    } catch (e) { setCheck('5-no-renderer-crash', 'failed', 'error: ' + e.message); }
  } catch (e) {
    R.fatal = String(e.stack || e); L('FATAL', R.fatal);
  }
  try {
    // ---- Check G3: restart persistence (stored session unlocks by itself)
    if (TOKEN && R.checks['G2-real-account-unlock']?.status === 'passed') {
      try {
        R.gracefulExit = await stopApp();
        await wait(3000);
        await startApp('relaunch');
        const r = await waitUnlocked(90000);
        R.relaunch = r;
        const s = await shot('06-relaunch-auto-unlocked.png');
        setCheck('G3-restart-persistence', r.unlocked && r.accountHasAt && r.matchesExpectedAccount !== false ? 'passed' : 'failed', JSON.stringify(r), [s]);
      } catch (e) { setCheck('G3-restart-persistence', 'failed', 'error: ' + e.message, [await shot('06-relaunch-error.png')]); }
    } else setCheck('G3-restart-persistence', 'not-verified', 'skipped because G2 did not pass / no token');
  } catch (e) {
    R.fatal2 = String(e.stack || e); L('FATAL(late)', R.fatal2);
  } finally {
    const g = await stopApp(); if (R.gracefulExit === undefined) R.gracefulExit = g; R.gracefulExitLast = g;
    R.finishedAt = new Date().toISOString();
    const vals = Object.values(R.checks).map(c => c.status);
    R.overall = (R.fatal || R.fatal2) ? 'failed' : vals.includes('failed') ? 'failed' : (vals.includes('blocked') || vals.includes('not-verified')) ? 'partial' : 'passed';
    await fsp.writeFile(path.join(out, 'e2e-result.json'), JSON.stringify(R, null, 2));
    await fsp.writeFile(path.join(out, 'e2e-log.txt'), logLines.join('\n'));
    await fsp.writeFile(path.join(out, 'app-stdio.txt'), appLog.join(''));
  }
  return R;
}
module.exports = { runE2E, zipEntries };
