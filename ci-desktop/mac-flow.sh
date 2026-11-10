#!/bin/bash
# macOS: verify the exact notarized ZIP, install to /Applications, E2E, build + verify an unsigned DMG.
# Usage: mac-flow.sh <zip> <evidence-dir> <dmg-out-dir>
set -u
ZIP="$1"; OUT="$2"; DMGDIR="$3"
EXPECT=94223a5f6a81ccf53559e6f4d3ffd9e7451a537b7b4b38a79f7a96d623053887
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT/shots" "$DMGDIR"
LOG="$OUT/mac-flow-log.txt"; : > "$LOG"
STEPS="$OUT/mac-steps.tsv"; : > "$STEPS"
step(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STEPS"; echo "STEP $1 $2 $3" | tee -a "$LOG"; }
run(){ echo "\$ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; local rc=$?; echo "[exit $rc]" >> "$LOG"; return $rc; }

sw_vers | tee -a "$LOG"; uname -m | tee -a "$LOG"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
if [ "$SHA" = "$EXPECT" ]; then step 0-sha256 passed "$SHA"; else step 0-sha256 failed "$SHA"; exit 1; fi

W="$RUNNER_TEMP/macwork"; rm -rf "$W"; mkdir -p "$W/unz"
run ditto -x -k "$ZIP" "$W/unz" || { step 1-ditto failed "ditto -x -k failed"; exit 1; }
APP="$W/unz/OrunDocs.app"
[ -d "$APP" ] && step 1-ditto passed "extracted $(du -sh "$APP" | cut -f1)" || { step 1-ditto failed "no app"; exit 1; }
ls -la "$APP/Contents/MacOS" >> "$LOG"
/usr/libexec/PlistBuddy -c 'Print' "$APP/Contents/Info.plist" > "$OUT/bundle-version.txt" 2>&1
file "$APP/Contents/MacOS/OrunDocs" >> "$LOG"

spctl -a -vvv -t exec "$APP" > "$OUT/spctl-extracted.txt" 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q "source=Notarized Developer ID" "$OUT/spctl-extracted.txt"; then step 2a-spctl passed "$(tr '\n' ' ' < "$OUT/spctl-extracted.txt")"; else step 2a-spctl failed "rc=$rc $(tr '\n' ' ' < "$OUT/spctl-extracted.txt")"; fi
xcrun stapler validate "$APP" > "$OUT/stapler-validate.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && step 2b-stapler passed "$(tr '\n' ' ' < "$OUT/stapler-validate.txt")" || step 2b-stapler failed "rc=$rc $(tr '\n' ' ' < "$OUT/stapler-validate.txt")"
codesign --verify --deep --strict --verbose=2 "$APP" > "$OUT/codesign-verify.txt" 2>&1; rc=$?
codesign -dvv "$APP" > "$OUT/codesign-display.txt" 2>&1
[ $rc -eq 0 ] && step 2c-codesign passed "$(grep -E 'Authority=Developer ID Application|TeamIdentifier' "$OUT/codesign-display.txt" | tr '\n' ' ')" || step 2c-codesign failed "rc=$rc $(tail -3 "$OUT/codesign-verify.txt" | tr '\n' ' ')"

# Install like a user: copy into /Applications
sudo rm -rf "/Applications/OrunDocs.app"
run ditto "$APP" "/Applications/OrunDocs.app" || run sudo ditto "$APP" "/Applications/OrunDocs.app"
spctl -a -vvv -t exec "/Applications/OrunDocs.app" > "$OUT/spctl-applications.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && step 3-install-applications passed "copied; /Applications copy assessed: $(tr '\n' ' ' < "$OUT/spctl-applications.txt")" || step 3-install-applications failed "rc=$rc $(tr '\n' ' ' < "$OUT/spctl-applications.txt")"
# Launch through LaunchServices (as Finder/Dock would), observe, then quit
open -a "/Applications/OrunDocs.app" >> "$LOG" 2>&1; olrc=$?
sleep 12
pgrep -fl "OrunDocs.app/Contents/MacOS/OrunDocs" > "$OUT/open-launch-ps.txt" 2>&1
screencapture -x "$OUT/shots/m00-open-launch.png" >/dev/null 2>&1 || true
if [ -s "$OUT/open-launch-ps.txt" ]; then step 3b-launchservices-open passed "open -a rc=$olrc; running: $(head -1 "$OUT/open-launch-ps.txt")"; else step 3b-launchservices-open failed "open -a rc=$olrc; app process not found after 12s"; fi
osascript -e 'tell application "OrunDocs" to quit' >> "$LOG" 2>&1 || true
sleep 5; pkill -f "OrunDocs.app/Contents/MacOS/OrunDocs" 2>/dev/null; sleep 2

# E2E against /Applications copy
( cd "$HERE" && node mac-e2e.cjs "/Applications/OrunDocs.app" "$OUT" ) 2>&1 | tee "$OUT/mac-e2e-console.txt"
# Never keep GitHub ::add-mask:: lines (they carry the secret itself) in uploaded evidence files.
sed -i '' '/::add-mask::/d' "$OUT/mac-e2e-console.txt"
grep -q "MAC E2E OVERALL passed" "$OUT/mac-e2e-console.txt" && step 4-e2e passed "see e2e-result.json" || step 4-e2e "$(grep -o 'MAC E2E OVERALL [a-z]*' "$OUT/mac-e2e-console.txt" | awk '{print $4}')" "see e2e-result.json"
pkill -f "OrunDocs.app/Contents/MacOS/OrunDocs" 2>/dev/null

# Unsigned DMG of the notarized app (app inside keeps its signature + stapled ticket)
D="$W/dmgsrc"; rm -rf "$D"; mkdir -p "$D"
ditto "$APP" "$D/OrunDocs.app"
ln -s /Applications "$D/Applications"
DMG="$DMGDIR/OrunDocs-4.0.0-mac-arm64.dmg"
run hdiutil create -volname "OrunDocs" -srcfolder "$D" -ov -format UDZO "$DMG"; rc=$?
[ $rc -eq 0 ] && step 5a-dmg-create passed "$(shasum -a 256 "$DMG" | awk '{print $1}') $(stat -f %z "$DMG") bytes" || step 5a-dmg-create failed "rc=$rc"
shasum -a 256 "$DMG" | tee "$DMGDIR/OrunDocs-4.0.0-mac-arm64.dmg.sha256" > "$OUT/dmg.sha256"
run hdiutil imageinfo "$DMG"
MNT="$W/mnt"; mkdir -p "$MNT"
run hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG"; rc=$?
if [ $rc -eq 0 ]; then
  ls -la "$MNT" > "$OUT/dmg-root-listing.txt" 2>&1
  readlink "$MNT/Applications" >> "$OUT/dmg-root-listing.txt"
  python3 - "$APP" "$MNT/OrunDocs.app" > "$OUT/dmg-tree-compare.txt" 2>&1 <<'PY'
import hashlib, os, stat, sys
def manifest(root):
    rows = {}
    for d, dirs, files in os.walk(root, followlinks=False):
        for n in dirs + files:
            p = os.path.join(d, n); r = os.path.relpath(p, root); s = os.lstat(p)
            if stat.S_ISLNK(s.st_mode): rows[r] = ('link', os.readlink(p))
            elif stat.S_ISDIR(s.st_mode): rows[r] = ('dir', oct(s.st_mode & 0o777))
            else:
                h = hashlib.sha256()
                with open(p, 'rb') as f:
                    for c in iter(lambda: f.read(1 << 20), b''): h.update(c)
                rows[r] = ('file', oct(s.st_mode & 0o777), s.st_size, h.hexdigest())
    return rows
a, b = manifest(sys.argv[1]), manifest(sys.argv[2])
diff = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
print('entries_source', len(a), 'entries_dmg', len(b), 'differences', len(diff))
for k in diff[:50]: print('DIFF', k, a.get(k), b.get(k))
print('IDENTICAL' if not diff else 'DIFFERENT')
PY
  grep -q '^IDENTICAL' "$OUT/dmg-tree-compare.txt" && step 5b-dmg-identical passed "$(head -1 "$OUT/dmg-tree-compare.txt")" || step 5b-dmg-identical failed "$(head -3 "$OUT/dmg-tree-compare.txt" | tr '\n' ' ')"
  codesign --verify --deep --strict --verbose=2 "$MNT/OrunDocs.app" > "$OUT/dmg-codesign.txt" 2>&1; c1=$?
  spctl -a -vvv -t exec "$MNT/OrunDocs.app" > "$OUT/dmg-spctl.txt" 2>&1; c2=$?
  xcrun stapler validate "$MNT/OrunDocs.app" > "$OUT/dmg-stapler.txt" 2>&1; c3=$?
  [ $c1 -eq 0 ] && [ $c2 -eq 0 ] && [ $c3 -eq 0 ] && step 5c-dmg-app-verify passed "codesign ok; $(tr '\n' ' ' < "$OUT/dmg-spctl.txt"); stapler ok" || step 5c-dmg-app-verify failed "codesign=$c1 spctl=$c2 stapler=$c3"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" > "$OUT/dmg-container-spctl.txt" 2>&1; echo "dmg container assessment rc=$? (expected rejected: DMG is unsigned)" >> "$OUT/dmg-container-spctl.txt"
  run hdiutil detach "$MNT"
else step 5b-dmg-identical failed "attach failed"; fi
echo done | tee -a "$LOG"
