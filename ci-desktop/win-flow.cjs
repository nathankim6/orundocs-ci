'use strict';
// Windows: run the real setup exe like a user, drive its native dialogs with UI Automation,
// verify the install, run the shared E2E on the installed app, uninstall, verify removal.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { runE2E } = require('./e2e.cjs');

const [setupExe, outDir] = process.argv.slice(2);
const EXPECT = 'cd49b295f6b1ba5d9de28e96f1cb45b58a29e37ddc95c5974ca7f72a420cadcb';
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
    D.readyFiles = fs.readdirSync(tmp).filter(f => /-uninstall-.*\.(ready|go)$/i.test(f));
    D.powershellProcs = ps(`@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object { @{pid=$_.ProcessId; parent=$_.ParentProcessId; cmd=$_.CommandLine} }) | ConvertTo-Json -Depth 3 -Compress`);
    D.orunProcs = ps(`@(Get-CimInstance Win32_Process -Filter "Name='OrunDocs.exe'" | ForEach-Object { @{pid=$_.ProcessId; cmd=$_.CommandLine} }) | ConvertTo-Json -Depth 3 -Compress`);
    D.remainingFiles = fs.existsSync(target) ? countFiles(target) : 0;
    D.remainingSample = fs.existsSync(target) ? fs.readdirSync(target).slice(0, 20) : [];
    D.events = ps(`@(Get-WinEvent -LogName 'Windows PowerShell' -MaxEvents 30 -ErrorAction SilentlyContinue | Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-15) } | ForEach-Object { @{t=$_.TimeCreated.ToString('o'); id=$_.Id; msg=($_.Message.Substring(0,[Math]::Min(300,$_.Message.Length)))} }) | ConvertTo-Json -Depth 3 -Compress`);
  } catch (e) { D.error = String(e.stack || e); }
  L('UNINSTALL DIAGNOSTICS', D);
  return D;
}


function listAll(dir) { const out = []; const walk = (d, rel) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const r = rel ? rel + '/' + e.name : e.name; out.push(r + (e.isDirectory() ? '/' : '')); if (e.isDirectory()) walk(path.join(d, e.name), r); } }; try { walk(dir, ''); } catch (e) { out.push('error: ' + e.message); } return out; }
let TARGET, EXE;
async function doInstall(n, sp) {
  const t0 = Date.now();
  const setup = spawn(setupExe, [], { stdio: 'ignore', cwd: path.dirname(setupExe) });
  setup.on('exit', c => L('setup exe exited', c));
  const c1 = await ui('click', { processNames: ['OrunDocs'], textRegex: '이 계정에 설치할까요', buttonRegexes: ['^설치$'], keys: '{ENTER}', timeoutSec: 300, shotBefore: path.join(shots, sp + '1-install-confirm.png'), shotAfter: path.join(shots, sp + '2-installing.png'), shotOnTimeout: path.join(shots, sp + '1-timeout.png'), progressShot: path.join(shots, sp + '0-sfx-extracting.png'), progressShotAfterSec: 4 });
  step(n + 'a-installer-confirm-dialog', c1.ok ? 'passed' : 'failed', { seconds: Math.round((Date.now() - t0) / 1000), ...c1, log: undefined }, [c1.shotBefore, c1.shotAfter, c1.shot]);
  if (!c1.ok) return false;
  const c2 = await ui('click', { processNames: ['OrunDocs'], textRegex: '설치가 완료되었습니다|설치 실패', buttonRegexes: ['^닫기$', '^(OK|확인)$'], keys: '{ESC}', timeoutSec: 1200, shotBefore: path.join(shots, sp + '3-install-complete.png'), shotAfter: path.join(shots, sp + '4-after-close.png'), shotOnTimeout: path.join(shots, sp + '3-timeout.png'), progressShot: path.join(shots, sp + '2b-install-progress.png'), progressShotAfterSec: 3 });
  const installError = /설치 실패/.test(c2.text || '');
  step(n + 'b-installer-complete-dialog', c2.ok && !installError ? 'passed' : 'failed', { installError, seconds: Math.round((Date.now() - t0) / 1000), ...c2, log: undefined }, [c2.shotBefore, c2.shotAfter, c2.shot]);
  if (!c2.ok || installError) { await waitExit(setup, 60000); return installError ? 'install-error' : false; }
  const se = await waitExit(setup, 180000);
  let info = null; try { info = JSON.parse(fs.readFileSync(path.join(TARGET, 'install-info.json'), 'utf8')); } catch {}
  const integ = ps(INTEGRATION); const files = fs.existsSync(TARGET) ? countFilesSafe(TARGET) : 0;
  const ok = se === 0 && fs.existsSync(EXE) && info && info.version === '4.0.0' && info.files.length === files - 2 && integ.registry && integ.registry.DisplayVersion === '4.0.0' && Array.isArray(integ.shortcuts) && integ.shortcuts.every(x => x.exists);
  step(n + 'c-setup-exit-and-installed', ok ? 'passed' : 'failed', { setupExit: se, seconds: Math.round((Date.now() - t0) / 1000), exe: fs.existsSync(EXE), filesOnDisk: files, installInfoFiles: info && info.files.length, registryVersion: integ.registry && integ.registry.DisplayVersion, shortcuts: integ.shortcuts });
  return ok ? true : false;
}
async function doUninstall(n, sp, mode) {
  const target = TARGET, exe = EXE;
  const integ = ps(INTEGRATION);
  const t1 = Date.now(); let un = null, how;
  if (mode === 'start-menu-shortcut') {
    const lnk = integ.shortcuts.find(s => /제거\.lnk$/.test(s.path));
    how = { mode, shortcut: lnk };
    const r = ps(`Start-Process -FilePath '${String(lnk && lnk.path).replace(/'/g, "''")}'; 'started' | ConvertTo-Json`); how.start = r;
  } else {
    const un0 = (integ.registry && integ.registry.UninstallString) || '';
    const m = un0.match(/^"([^"]+)"\s*(.*)$/);
    const cwd = mode === 'uninstallstring-install-dir-cwd' ? target : path.join(process.env.SystemRoot, 'System32');
    how = { mode, uninstallString: un0, cwd };
    un = spawn(m ? m[1] : exe, m ? m[2].split(/\s+/).filter(Boolean) : ['--uninstall'], { stdio: 'ignore', cwd });
  }
  const u1 = await ui('click', { processNames: ['OrunDocs'], textRegex: '제거할까요', buttonRegexes: ['^제거$'], keys: '{TAB}{ENTER}', timeoutSec: 120, shotBefore: path.join(shots, sp + '0-uninstall-confirm.png'), shotOnTimeout: path.join(shots, sp + '0-timeout.png') });
  step(n + 'a-uninstall-confirm-dialog', u1.ok ? 'passed' : 'failed', { ...how, ...u1, log: undefined }, [u1.shotBefore, u1.shot]);
  const u2 = await ui('click', { processNames: ['OrunDocs'], textRegex: '앱 등록과 바로가기를 제거했습니다|제거 실패', buttonRegexes: ['^(OK|확인)$'], keys: '{ENTER}', timeoutSec: 120, shotBefore: path.join(shots, sp + '1-uninstall-done.png'), shotAfter: path.join(shots, sp + '2-after-uninstall.png'), shotOnTimeout: path.join(shots, sp + '1-timeout.png') });
  const u2err = /제거 실패/.test(u2.text || '');
  step(n + 'b-uninstall-done-dialog', u2.ok && !u2err ? 'passed' : 'failed', { appReportedError: u2err, ...u2, log: undefined }, [u2.shotBefore, u2.shotAfter, u2.shot]);
  const ue = un ? await waitExit(un, 60000) : 'n/a (ShellExecute)';
  let gone = false, zeroSince = null; const until = Date.now() + 300000; const timeline = []; let lastSample = 0;
  while (Date.now() < until) {
    if (!fs.existsSync(target)) { gone = true; break; }
    const files = countFilesSafe(target);
    if (files === 0) { zeroSince = zeroSince || Date.now(); if (Date.now() - zeroSince > 45000) break; } else zeroSince = null;
    if (Date.now() - lastSample > 15000) {
      lastSample = Date.now();
      let tf = []; try { tf = fs.readdirSync(process.env.TEMP).filter(f => /-uninstall-/i.test(f)); } catch {}
      const pr = ps(`@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'uninstall-' } | ForEach-Object { $p=Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; @{pid=$_.ProcessId; cpu=[Math]::Round($p.TotalProcessorTime.TotalSeconds,2)} }) | ConvertTo-Json -Depth 3 -Compress`);
      const smp = { s: Math.round((Date.now() - t1) / 1000), files, tempFiles: tf, cleanupProcs: pr.raw === '' ? [] : pr };
      timeline.push(smp); L('UNINSTALL SAMPLE', n, smp);
    }
    await wait(1000);
  }
  const integ2 = ps(INTEGRATION);
  const remaining = fs.existsSync(target) ? listAll(target) : [];
  const filesLeft = fs.existsSync(target) ? countFilesSafe(target) : 0;
  const integrationRemoved = !integ2.registry && integ2.shortcuts.every(s => !s.exists) && !integ2.startMenuDirExists;
  const status = gone && integrationRemoved ? 'passed' : (filesLeft === 0 && integrationRemoved ? 'partial' : 'failed');
  const D = status === 'passed' ? null : await diagnoseCleanup(target);
  step(n + 'c-removed', status, { mode, uninstallerExit: ue, seconds: Math.round((Date.now() - t1) / 1000), installDirRemoved: gone, filesLeft, remainingEntries: remaining.slice(0, 60), registryAfter: integ2.registry, shortcutsAfter: integ2.shortcuts, startMenuDirExists: integ2.startMenuDirExists, userDataPreservedByDesign: fs.existsSync(path.join(process.env.APPDATA, 'OrunDocs')), timeline, diagnostics: D });
  return status;
}
function countFilesSafe(d) { try { return countFiles(d); } catch { return -1; } }

// The job step runs under pwsh 7, which prepends PowerShell-7 module paths to PSModulePath. Every process the
// harness starts (setup -> app -> uninstaller -> Windows PowerShell 5.1 cleanup) would inherit that, which a user
// launching from Explorer/Settings never has (it breaks module autoload, e.g. Get-FileHash, in 5.1).
// Restore an Explorer-like PSModulePath (Machine + User values from the registry) before launching anything.
function sanitizePsModulePath() {
  const before = process.env.PSModulePath || '';
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', "[Environment]::GetEnvironmentVariable('PSModulePath','Machine'); '---'; [Environment]::GetEnvironmentVariable('PSModulePath','User')"], { encoding: 'utf8' });
  const [mach, user] = (r.stdout || '').split('---').map(x => x.trim());
  const after = [user, mach].filter(Boolean).join(';');
  if (after) process.env.PSModulePath = after;
  return { before, after: process.env.PSModulePath };
}
const HASHTEST = target => `$t=Get-Date; $ok=0;$err=0;$e1=$null; foreach($f in @(Get-ChildItem -LiteralPath '${target.replace(/'/g, "''")}' -File | Select-Object -First 5)){ try{ $null=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; $ok++ }catch{ $err++; if(-not $e1){$e1=$_.Exception.Message} } }; @{ok=$ok;err=$err;firstError=$e1;seconds=[Math]::Round(((Get-Date)-$t).TotalSeconds,1)} | ConvertTo-Json -Compress`;

(async () => {
  // This round deliberately KEEPS the pwsh-7-inherited PSModulePath (the environment that broke Get-FileHash in
  // the previous build) to prove the .NET SHA256 hashing fix. Nothing is sanitized.
  S.psModulePath = { before: process.env.PSModulePath || '', after: process.env.PSModulePath || '', sanitized: false };
  L('PSModulePath kept as inherited (not sanitized)', S.psModulePath.before);
  const target = path.join(process.env.LOCALAPPDATA, 'Programs', 'OrunDocs');
  const exe = path.join(target, 'OrunDocs.exe');
  TARGET = target; EXE = exe;
  S.installTarget = target;
  try {
    // 0. sha256 of the exact binary
    const h = crypto.createHash('sha256').update(fs.readFileSync(setupExe)).digest('hex');
    step('0-sha256', h === EXPECT ? 'passed' : 'failed', `sha256=${h} size=${fs.statSync(setupExe).size} expected=${EXPECT}`);
    if (h !== EXPECT) throw Error('sha mismatch');
    step('0-preconditions', fs.existsSync(target) ? 'failed' : 'passed', `install target pre-exists=${fs.existsSync(target)}; integration=${JSON.stringify(ps(INTEGRATION))}`);

    // 1. Run the setup exe as a user would (double-click equivalent), drive its dialogs.
    if (!(await doInstall('1', 'w0'))) throw Error('install failed');

    // 2. Verify installed files, shortcuts, uninstall registration
    let info = null; try { info = JSON.parse(fs.readFileSync(path.join(target, 'install-info.json'), 'utf8')); } catch (e) { L('install-info read', e.message); }
    const integ = ps(INTEGRATION);
    S.installedIntegration = integ;
    const files = fs.existsSync(target) ? countFiles(target) : 0;
    const lnkOk = Array.isArray(integ.shortcuts) && integ.shortcuts.every(s => s.exists && s.target && s.target.toLowerCase() === exe.toLowerCase()) && /--uninstall/.test(integ.shortcuts[2].args || '');
    const regOk = integ.registry && integ.registry.DisplayVersion === '4.0.0' && /--uninstall/.test(integ.registry.UninstallString || '') && (integ.registry.InstallLocation || '').toLowerCase() === target.toLowerCase();
    const filesOk = fs.existsSync(exe) && fs.existsSync(path.join(target, 'resources', 'app', 'desktop', 'main.cjs')) && info && info.version === '4.0.0' && info.files.length === files - 2;
    const unLnk = (integ.shortcuts || []).find(x => /제거\.lnk$/.test(x.path || '')) || {};
    const unLnkWorkdirIsPrograms = (unLnk.workdir || '').replace(/\\+$/, '').toLowerCase() === path.dirname(target).toLowerCase();
    step('2-installed-files-shortcuts-registry', filesOk && lnkOk && regOk && unLnkWorkdirIsPrograms ? 'passed' : 'failed', { filesOk, lnkOk, regOk, uninstallShortcutWorkdir: unLnk.workdir, unLnkWorkdirIsPrograms, filesOnDisk: files, installInfo: info && { version: info.version, files: info.files.length, byteSize: info.byteSize, installId: info.installId, installedAt: info.installedAt }, registry: integ.registry, shortcuts: integ.shortcuts, pythonExe: fs.existsSync(path.join(target, 'resources', 'runtime', 'python-export', 'python.exe')) });
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

    S.getFileHashInThisEnv = ps(HASHTEST(target)); L('Get-FileHash availability in the (unsanitized) environment', S.getFileHashInThisEnv);
    // 3b. Read-only: what the cleanup script's hash-then-delete loop will see (PowerShell 5.1 Get-FileHash vs install-info)
    S.preUninstallHashCheck = ps(`$t=Get-Date; $target='${target.replace(/'/g, "''")}'
$info=Get-Content -LiteralPath (Join-Path $target 'install-info.json') -Raw | ConvertFrom-Json
$mis=0;$err=0;$ok=0;$errs=@()
foreach($r in $info.files){ $p=[IO.Path]::GetFullPath((Join-Path $target ([string]$r))); try{ $h=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash; if($h -eq $info.hashes.PSObject.Properties[[string]$r].Value){$ok++}else{$mis++} }catch{ $err++; if($errs.Count -lt 5){$errs+=$_.Exception.Message} } }
$lock=@(); foreach($f in @('OrunDocs.exe','resources\\app\\desktop\\main.cjs')){ try{ $fsx=[IO.File]::Open((Join-Path $target $f),'Open','ReadWrite','None'); $fsx.Close(); $lock+=@{f=$f;exclusiveOpen='ok'} }catch{ $lock+=@{f=$f;exclusiveOpen=$_.Exception.Message} } }
@{ok=$ok;mismatch=$mis;errors=$err;errSamples=$errs;seconds=[Math]::Round(((Get-Date)-$t).TotalSeconds,1);lockTest=$lock} | ConvertTo-Json -Depth 4 -Compress`);
    L('PRE-UNINSTALL HASH CHECK', S.preUninstallHashCheck);
    save();

    // 4. Uninstall #1 from the Start-menu shortcut "OrunDocs 제거" (ShellExecute; shortcut's own working folder)
    await doUninstall('4', 'w1', 'start-menu-shortcut');
    // 5. Reinstall (must succeed with no harness cleanup in between)
    S.leftoverBeforeReinstall = fs.existsSync(TARGET) ? listAll(TARGET) : null;
    const re = await doInstall('5', 'w2');
    // 6. Uninstall #2 via the registered UninstallString (Settings > Apps), System32 working folder
    if (re === true) await doUninstall('6', 'w3', 'uninstallstring-system32-cwd');
    // 7. Reinstall onto a pre-created EMPTY install folder
    if (fs.existsSync(TARGET)) { S.step7PreExisting = listAll(TARGET); L('target unexpectedly exists before step 7', S.step7PreExisting); }
    fs.mkdirSync(TARGET, { recursive: true });
    S.step7PreCreatedEmptyFolder = { exists: fs.existsSync(TARGET), entries: listAll(TARGET) };
    const re7 = await doInstall('7', 'w4');
    // 8. Final cleanup uninstall via UninstallString launched from INSIDE the install folder (old failure mode)
    if (re7 === true) await doUninstall('8', 'w5', 'uninstallstring-install-dir-cwd');
  } catch (e) { S.fatal = String(e.stack || e); L('FATAL', S.fatal); }
  finally {
    for (const im of ['OrunDocs.exe', path.basename(setupExe)]) { const k = spawnSync('taskkill', ['/IM', im, '/T', '/F'], { encoding: 'utf8' }); if (k.status === 0) L('cleanup: killed leftover', im); }
    const v = Object.values(S.steps).map(s => s.status);
    S.overall = S.fatal || v.includes('failed') ? 'failed' : v.includes('partial') ? 'partial' : 'passed';
    S.finishedAt = new Date().toISOString(); save();
    console.log('WINDOWS OVERALL', S.overall);
    process.exit(0);
  }
})();
