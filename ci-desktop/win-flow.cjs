'use strict';
// Windows: run the real setup exe like a user, drive its native dialogs with UI Automation,
// verify the install, run the shared E2E on the installed app, uninstall, verify removal.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { runE2E } = require('./e2e.cjs');

const [setupExe, outDir] = process.argv.slice(2);
const EXPECT = '6da2752f95116cb690b8c0b881e88cbf45a88a0da1fa33f218e128ad305999f3';
const shots = path.join(outDir, 'shots');
fs.mkdirSync(shots, { recursive: true });
const S = { platform: 'windows', setupExe, steps: {}, startedAt: new Date().toISOString() };
const lines = [];
const L = (...a) => { const s = new Date().toISOString() + ' ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' '); lines.push(s); console.log(s); };
const step = (id, status, detail, evidence = []) => { S.steps[id] = { status, detail, evidence: evidence.filter(Boolean).map(rel) }; L('STEP', id, status, typeof detail === 'string' ? detail : JSON.stringify(detail)); };
const rel = p => path.isAbsolute(p) ? path.relative(outDir, p).split(path.sep).join('/') : p;
const wait = ms => new Promise(r => setTimeout(r, ms));
const save = () => { fs.writeFileSync(path.join(outDir, 'windows-summary.json'), JSON.stringify(S, null, 2)); fs.writeFileSync(path.join(outDir, 'windows-flow-log.txt'), lines.join('\n')); };

function ui(action, cfg) {
  return new Promise(resolve => {
    const p = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'win-ui.ps1'), '-Action', action, '-ArgsB64', Buffer.from(JSON.stringify(cfg), 'utf8').toString('base64')], { windowsHide: true });
    let out = '', err = '';
    p.stdout.on('data', d => out += d); p.stderr.on('data', d => { err += d; process.stdout.write('[ui] ' + d); });
    const t = setTimeout(() => { try { p.kill(); } catch {} }, ((cfg.timeoutSec || 60) + 60) * 1000);
    p.on('close', code => { clearTimeout(t); let j = null; const last = out.trim().split(/\r?\n/).pop(); try { j = JSON.parse(last); } catch { j = { ok: false, error: 'unparsable helper output', out: out.slice(-2000), err: err.slice(-2000) }; } j.exitCode = code; resolve(j); });
  });
}
function ps(script) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from('[Console]::OutputEncoding=[Text.Encoding]::UTF8\n' + script, 'utf16le').toString('base64')], { encoding: 'utf8', timeout: 120000, maxBuffer: 2e7 });
  const o = (r.stdout || '').trim(); try { return JSON.parse(o.split(/\r?\n/).pop()); } catch { return { raw: o, err: r.stderr }; }
}
const INTEGRATION = `
$k='HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\OrunDocs'
$reg=$null; if(Test-Path $k){ $reg=Get-ItemProperty $k | Select-Object DisplayName,DisplayVersion,Publisher,InstallLocation,UninstallString,DisplayIcon,EstimatedSize,NoModify,NoRepair,InstallDate }
$desk=[Environment]::GetFolderPath('Desktop'); $start=Join-Path $env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs\\OrunDocs'
$sa=New-Object -ComObject Shell.Application; $lnks=@()
foreach($f in @((Join-Path $desk 'OrunDocs.lnk'),(Join-Path $start 'OrunDocs.lnk'),(Join-Path $start 'OrunDocs 제거.lnk'))){ if(Test-Path -LiteralPath $f){ $t='';$a='';$wd=''; try{ $l=$sa.Namespace([IO.Path]::GetDirectoryName($f)).ParseName([IO.Path]::GetFileName($f)).GetLink; $t=$l.Path; $a=$l.Arguments; $wd=$l.WorkingDirectory }catch{ $t='read-error: '+$_.Exception.Message }; $lnks+=@{path=$f;exists=$true;target=$t;args=$a;workdir=$wd} } else { $lnks+=@{path=$f;exists=$false} } }
@{registry=$reg;shortcuts=$lnks;startMenuDirExists=(Test-Path -LiteralPath $start);desktopDir=$desk} | ConvertTo-Json -Depth 5 -Compress`;
function countFiles(dir) { let n = 0; const walk = d => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { if (e.isDirectory()) walk(path.join(d, e.name)); else n++; } }; walk(dir); return n; }
function waitExit(proc, ms) { return new Promise(r => { if (proc.exitCode !== null) return r(proc.exitCode); const t = setTimeout(() => r('timeout'), ms); proc.once('exit', c => { clearTimeout(t); r(c); }); }); }

// Re-run the app's OWN cleanup script generator (read-only, no gate file => it never deletes)
// to observe why the uninstaller's PowerShell helper did not report ready.
async function diagnoseCleanup(target) {
  // Read-only evidence about the 4.0.0 uninstall mechanism (temp .ps1 + Start-Process grandchild).
  const D = {};
  try {
    const tmp = process.env.TEMP;
    D.tempScripts = fs.readdirSync(tmp).filter(f => /^OrunDocs-uninstall-.*\.ps1$/i.test(f)).map(f => ({ f, bytes: fs.statSync(path.join(tmp, f)).size }));
    D.readyFiles = fs.readdirSync(tmp).filter(f => /^OrunDocs-uninstall-.*\.(ready|go)$/i.test(f));
    D.powershellProcs = ps(`@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object { @{pid=$_.ProcessId; parent=$_.ParentProcessId; cmd=$_.CommandLine} }) | ConvertTo-Json -Depth 3 -Compress`);
    D.orunProcs = ps(`@(Get-CimInstance Win32_Process -Filter "Name='OrunDocs.exe'" | ForEach-Object { @{pid=$_.ProcessId; cmd=$_.CommandLine} }) | ConvertTo-Json -Depth 3 -Compress`);
    D.remainingFiles = fs.existsSync(target) ? countFiles(target) : 0;
    D.remainingSample = fs.existsSync(target) ? fs.readdirSync(target).slice(0, 20) : [];
    D.events = ps(`@(Get-WinEvent -LogName 'Windows PowerShell' -MaxEvents 30 -ErrorAction SilentlyContinue | Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-15) } | ForEach-Object { @{t=$_.TimeCreated.ToString('o'); id=$_.Id; msg=($_.Message.Substring(0,[Math]::Min(300,$_.Message.Length)))} }) | ConvertTo-Json -Depth 3 -Compress`);
  } catch (e) { D.error = String(e.stack || e); }
  L('UNINSTALL DIAGNOSTICS', D);
  return D;
}

(async () => {
  const target = path.join(process.env.LOCALAPPDATA, 'Programs', 'OrunDocs');
  const exe = path.join(target, 'OrunDocs.exe');
  S.installTarget = target;
  try {
    // 0. sha256 of the exact binary
    const h = crypto.createHash('sha256').update(fs.readFileSync(setupExe)).digest('hex');
    step('0-sha256', h === EXPECT ? 'passed' : 'failed', `sha256=${h} size=${fs.statSync(setupExe).size} expected=${EXPECT}`);
    if (h !== EXPECT) throw Error('sha mismatch');
    step('0-preconditions', fs.existsSync(target) ? 'failed' : 'passed', `install target pre-exists=${fs.existsSync(target)}; integration=${JSON.stringify(ps(INTEGRATION))}`);

    // 1. Run the setup exe as a user would (double-click equivalent), drive its dialogs.
    const t0 = Date.now();
    const setup = spawn(setupExe, [], { stdio: 'ignore', cwd: path.dirname(setupExe) });
    setup.on('exit', c => L('setup exe exited', c));
    S.setupPid = setup.pid;
    const c1 = await ui('click', { processNames: ['OrunDocs'], textRegex: '이 계정에 설치할까요', buttonRegexes: ['^설치$'], keys: '{ENTER}', timeoutSec: 300, shotBefore: path.join(shots, 'w01-install-confirm.png'), shotAfter: path.join(shots, 'w02-installing.png'), shotOnTimeout: path.join(shots, 'w01-timeout.png'), progressShot: path.join(shots, 'w00-sfx-extracting.png'), progressShotAfterSec: 4 });
    step('1a-installer-confirm-dialog', c1.ok ? 'passed' : 'failed', { seconds: Math.round((Date.now() - t0) / 1000), ...c1, log: undefined }, [c1.shotBefore, c1.shotAfter, c1.shot]);
    S.uiLogs = { confirm: c1.log };
    if (!c1.ok) throw Error('installer confirm dialog not handled');
    const c2 = await ui('click', { processNames: ['OrunDocs'], textRegex: '설치가 완료되었습니다', buttonRegexes: ['^닫기$'], keys: '{ESC}', timeoutSec: 1200, shotBefore: path.join(shots, 'w03-install-complete.png'), shotAfter: path.join(shots, 'w04-after-close.png'), shotOnTimeout: path.join(shots, 'w03-timeout.png'), progressShot: path.join(shots, 'w02b-install-progress.png'), progressShotAfterSec: 3 });
    S.uiLogs.complete = c2.log;
    step('1b-installer-complete-dialog', c2.ok ? 'passed' : 'failed', { seconds: Math.round((Date.now() - t0) / 1000), ...c2, log: undefined }, [c2.shotBefore, c2.shotAfter, c2.shot]);
    if (!c2.ok) throw Error('install-complete dialog not handled');
    const se = await waitExit(setup, 180000);
    step('1c-setup-exit', se === 0 ? 'passed' : 'failed', `setup exe exit code=${se} after ${Math.round((Date.now() - t0) / 1000)}s`);

    // 2. Verify installed files, shortcuts, uninstall registration
    let info = null; try { info = JSON.parse(fs.readFileSync(path.join(target, 'install-info.json'), 'utf8')); } catch (e) { L('install-info read', e.message); }
    const integ = ps(INTEGRATION);
    S.installedIntegration = integ;
    const files = fs.existsSync(target) ? countFiles(target) : 0;
    const lnkOk = Array.isArray(integ.shortcuts) && integ.shortcuts.every(s => s.exists && s.target && s.target.toLowerCase() === exe.toLowerCase()) && /--uninstall/.test(integ.shortcuts[2].args || '');
    const regOk = integ.registry && integ.registry.DisplayVersion === '3.5.0' && /--uninstall/.test(integ.registry.UninstallString || '') && (integ.registry.InstallLocation || '').toLowerCase() === target.toLowerCase();
    const filesOk = fs.existsSync(exe) && fs.existsSync(path.join(target, 'resources', 'app', 'desktop', 'main.cjs')) && info && info.version === '3.5.0' && info.files.length === files - 2;
    step('2-installed-files-shortcuts-registry', filesOk && lnkOk && regOk ? 'passed' : 'failed', { filesOk, lnkOk, regOk, filesOnDisk: files, installInfo: info && { version: info.version, files: info.files.length, byteSize: info.byteSize, installId: info.installId, installedAt: info.installedAt }, registry: integ.registry, shortcuts: integ.shortcuts, pythonExe: fs.existsSync(path.join(target, 'resources', 'runtime', 'python-export', 'python.exe')) });
    save();

    // 3. Launch the installed app and run the E2E (native Save dialog driven via UIA)
    const e2e = await runE2E({ label: 'windows-installed', exe, expectVersion: '4.0.0', productName: 'OrunDocs', out: outDir, fixtures: path.join(__dirname, 'fixtures'), port: 9333, saveMode: 'native',
      saveHandler: async ({ name, dest, shotPath, kind }) => {
        // For the split result keep the dialog's default name/location (what a user who just presses Save gets).
        const acceptDefault = kind === 'split-pdf';
        const dl = path.join(process.env.USERPROFILE, 'Downloads', name);
        const r = await ui('save', { processNames: ['OrunDocs'], titleRegex: '처리 결과 저장', path: acceptDefault ? dl : dest, acceptDefault, timeoutSec: 60, shotBefore: shotPath, shotOnTimeout: shotPath.replace('.png', '-timeout.png') });
        return { ...r, log: undefined, shot: r.shot && rel(r.shot), uiLog: r.log, savedPath: acceptDefault ? dl : dest, altPaths: acceptDefault ? [dl.replace(/\.pdf$/i, '')] : [] };
      } });
    S.e2eOverall = e2e.overall;
    step('3-e2e-installed-app', e2e.overall === 'passed' ? 'passed' : 'failed', `overall=${e2e.overall}; gracefulExit=${e2e.gracefulExit}; exitCode=${e2e.exitCode}; see e2e-result.json`);
    await wait(3000);

    // 4. Uninstall the way Windows "Apps > Uninstall" does: run the registered UninstallString
    const un0 = (integ.registry && integ.registry.UninstallString) || '';
    const m = un0.match(/^"([^"]+)"\s*(.*)$/);
    const unExe = m ? m[1] : exe, unArgs = m ? m[2].split(/\s+/).filter(Boolean) : ['--uninstall'];
    const t1 = Date.now();
    const un = spawn(unExe, unArgs, { stdio: 'ignore', cwd: target });
    const u1 = await ui('click', { processNames: ['OrunDocs'], textRegex: '제거할까요', buttonRegexes: ['^제거$'], keys: '{TAB}{ENTER}', timeoutSec: 120, shotBefore: path.join(shots, 'w10-uninstall-confirm.png'), shotOnTimeout: path.join(shots, 'w10-timeout.png') });
    step('4a-uninstall-confirm-dialog', u1.ok ? 'passed' : 'failed', { uninstallString: un0, ...u1, log: undefined }, [u1.shotBefore, u1.shot]);
    S.uiLogs.uninstallConfirm = u1.log;
    const u2 = await ui('click', { processNames: ['OrunDocs'], textRegex: '앱 등록과 바로가기를 제거했습니다|제거 실패', buttonRegexes: ['^(OK|확인)$'], keys: '{ENTER}', timeoutSec: 120, shotBefore: path.join(shots, 'w11-uninstall-done.png'), shotAfter: path.join(shots, 'w12-after-uninstall.png'), shotOnTimeout: path.join(shots, 'w11-timeout.png') });
    S.uiLogs.uninstallDone = u2.log;
    const u2err = /제거 실패/.test(u2.text || '');
    step('4b-uninstall-done-dialog', u2.ok && !u2err ? 'passed' : 'failed', { appReportedError: u2err, ...u2, log: undefined }, [u2.shotBefore, u2.shotAfter, u2.shot]);
    const ue = await waitExit(un, 60000);
    let gone = false; const until = Date.now() + 180000;
    while (Date.now() < until) { if (!fs.existsSync(target)) { gone = true; break; } await wait(1000); }
    const integ2 = ps(INTEGRATION);
    const leftovers = fs.existsSync(target) ? countFiles(target) : 0;
    const userData = path.join(process.env.APPDATA, 'OrunDocs');
    const removedOk = gone && !integ2.registry && integ2.shortcuts.every(s => !s.exists) && !integ2.startMenuDirExists;
    if (!removedOk) S.uninstallDiagnostics = await diagnoseCleanup(target);
    step('4c-removed', removedOk ? 'passed' : 'failed', { uninstallerExit: ue, seconds: Math.round((Date.now() - t1) / 1000), installDirRemoved: gone, leftoverFiles: leftovers, registryAfter: integ2.registry, shortcutsAfter: integ2.shortcuts, startMenuDirExists: integ2.startMenuDirExists, userDataPreservedByDesign: fs.existsSync(userData) });
  } catch (e) { S.fatal = String(e.stack || e); L('FATAL', S.fatal); }
  finally {
    for (const im of ['OrunDocs.exe', path.basename(setupExe)]) { const k = spawnSync('taskkill', ['/IM', im, '/T', '/F'], { encoding: 'utf8' }); if (k.status === 0) L('cleanup: killed leftover', im); }
    const v = Object.values(S.steps).map(s => s.status);
    S.overall = S.fatal || v.includes('failed') ? 'failed' : 'passed';
    S.finishedAt = new Date().toISOString(); save();
    console.log('WINDOWS OVERALL', S.overall);
    process.exit(0);
  }
})();
