'use strict';
// macOS: run the shared E2E against the app copied to /Applications. The app's native NSSavePanel
// sheet is accepted through System Events (Accessibility) when the runner allows it; otherwise the
// harness falls back to CDP download behaviour and reports the native save step as not automated.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { runE2E } = require('./e2e.cjs');
const [appBundle, outDir] = process.argv.slice(2);
const exe = path.join(appBundle, 'Contents', 'MacOS', 'OrunDocs');
const wait = ms => new Promise(r => setTimeout(r, ms));

function osa(script, args = [], timeout = 90000) {
  const r = spawnSync('osascript', ['-', ...args], { input: script, encoding: 'utf8', timeout });
  return { code: r.status, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() + (r.error ? ' ' + r.error.message : '') };
}
function screencap(file) { const r = spawnSync('screencapture', ['-x', file], { timeout: 20000 }); return r.status === 0 && fs.existsSync(file) ? file : null; }

const SAVE_SCRIPT = `
on run argv
  tell application "System Events"
    tell process "OrunDocs"
      set frontmost to true
      set found to false
      repeat 80 times
        try
          repeat with w in windows
            if exists sheet 1 of w then
              set found to true
              exit repeat
            end if
          end repeat
        end try
        if found then exit repeat
        delay 0.5
      end repeat
      if not found then
        set names to ""
        try
          set names to name of every window as text
        end try
        return "no-sheet; windows=" & names
      end if
      delay 1
      set w to missing value
      repeat with x in windows
        if exists sheet 1 of x then set w to x
      end repeat
      set btns to ""
      try
        set btns to name of every button of sheet 1 of w as text
      end try
      try
        set fld to value of text field 1 of sheet 1 of w
      on error
        set fld to "?"
      end try
      try
        click button "Save" of sheet 1 of w
        return "clicked Save; defaultName=" & fld & "; buttons=" & btns
      on error e1
        keystroke return
        return "pressed Return (" & e1 & "); defaultName=" & fld & "; buttons=" & btns
      end try
    end tell
  end tell
end run`;

(async () => {
  fs.mkdirSync(path.join(outDir, 'shots'), { recursive: true });
  const probe = osa('tell application "System Events" to get name of every UI element of process "Dock"', [], 25000);
  const axOk = probe.code === 0;
  const meta = { accessibilityProbe: probe, saveMode: axOk ? 'native' : 'cdp-bypass' };
  console.log('accessibility probe', JSON.stringify(probe));
  const downloads = path.join(os.homedir(), 'Downloads');
  fs.mkdirSync(downloads, { recursive: true });
  const r = await runE2E({ label: 'macos-applications', exe, expectVersion: '4.0.0', productName: 'OrunDocs', out: outDir, fixtures: path.join(__dirname, 'fixtures'), port: 9333, saveMode: meta.saveMode,
    saveHandler: async ({ name, shotPath }) => {
      const savedPath = path.join(downloads, name);
      try { fs.rmSync(savedPath, { force: true }); } catch {}
      await wait(1500);
      const shot = screencap(shotPath);
      const res = osa(SAVE_SCRIPT, [], 90000);
      return { savedPath, osascript: res, shot: shot ? path.relative(outDir, shot) : null };
    } });
  r.macMeta = meta;
  fs.writeFileSync(path.join(outDir, 'e2e-result.json'), JSON.stringify(r, null, 2));
  console.log('MAC E2E OVERALL', r.overall, JSON.stringify(Object.fromEntries(Object.entries(r.checks).map(([k, v]) => [k, v.status]))));
})();
