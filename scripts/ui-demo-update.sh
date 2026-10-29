#!/bin/zsh
# End-to-end check of the in-app updater without publishing anything: builds a fake "9.9.9" release
# (the current app, re-signed with the same certificate) as a local disk image and release feed,
# lets the real app find it on Home, refuse look-alikes (unsigned, another app, not newer), then
# install it over a throwaway copy in build/ui-demo-update/Installed/ (never your own copy).
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/MotionForge.app ]] || scripts/bundle.sh
OUT="$PWD/build/ui-demo-update"
rm -rf "$OUT"; mkdir -p "$OUT/recovery" "$OUT/release" "$OUT/Installed" "$OUT/bad"
SIGN="${MOTIONFORGE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN" ]] || { echo "ui-demo-update: needs the Apple Development certificate bundle.sh signs with" >&2; exit 2; }

version() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$1/Contents/Info.plist"; }
resign() { codesign --force --sign "$2" --timestamp=none "$1/Contents/MacOS/mfmcp" >/dev/null; codesign --force --sign "$2" --timestamp=none "$1" >/dev/null; }

# The new release: the same app as 9.9.9, same certificate.
NEW="$OUT/release/MotionForge.app"
ditto build/MotionForge.app "$NEW"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString 9.9.9" "$NEW/Contents/Info.plist"
resign "$NEW" "$SIGN"
hdiutil create -quiet -srcfolder "$OUT/release" -volname "MotionForge 9.9.9" -format UDZO "$OUT/MotionForge.dmg"
SIZE=$(stat -f %z "$OUT/MotionForge.dmg")
cat > "$OUT/feed.json" <<JSON
{"tag_name": "v9.9.9", "name": "MotionForge 9.9.9", "html_url": "https://github.com/Karthikvarma101/MotionForge/releases",
 "body": "## New in 9.9.9\n\n- **Video footage** import (MOV, MP4, …)\n- Every image format\n- After Effects shortcuts",
 "assets": [{"name": "MotionForge.dmg", "size": $SIZE, "browser_download_url": "file://$OUT/MotionForge.dmg"}]}
JSON

# Look-alikes it must refuse.
ditto "$NEW" "$OUT/bad/Unsigned.app"; codesign --force --deep --sign - "$OUT/bad/Unsigned.app" >/dev/null
ditto "$NEW" "$OUT/bad/OtherApp.app"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier com.example.NotMotionForge" "$OUT/bad/OtherApp.app/Contents/Info.plist"
resign "$OUT/bad/OtherApp.app" "$SIGN"
ditto build/MotionForge.app "$OUT/bad/NotNewer.app"

# The copy that gets updated.
ditto build/MotionForge.app "$OUT/Installed/MotionForge.app"
BEFORE=$(version "$OUT/Installed/MotionForge.app")

MOTIONFORGE_UIDEMO_UPDATE="$OUT" MOTIONFORGE_RECOVERY_DIR="$OUT/recovery" MOTIONFORGE_NO_KEYCHAIN=1 \
MOTIONFORGE_UPDATE_FEED="file://$OUT/feed.json" MOTIONFORGE_UPDATE_TARGET="$OUT/Installed/MotionForge.app" \
MOTIONFORGE_UPDATE_NO_RELAUNCH=1 MOTIONFORGE_UPDATE_BAD_APPS="$OUT/bad/Unsigned.app:$OUT/bad/OtherApp.app:$OUT/bad/NotNewer.app" \
    build/MotionForge.app/Contents/MacOS/MotionForge || true

# The helper swaps the bundles once the app has quit.
for i in {1..100}; do [[ "$(version "$OUT/Installed/MotionForge.app" 2>/dev/null)" == 9.9.9 ]] && break; sleep 0.1; done
AFTER=$(version "$OUT/Installed/MotionForge.app" 2>/dev/null || echo missing)
LEFT=$(ls -A "$OUT/Installed")
codesign --verify --strict "$OUT/Installed/MotionForge.app" && SIGNED=1 || SIGNED=0
echo "ui-demo-update installed copy: $BEFORE -> $AFTER, signature ok: $SIGNED, folder: $LEFT"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[-1]["failures"] == [] else 1)' "$OUT/update.json" \
    || { echo "ui-demo-update: FAILED in-app checks"; exit 1; }
[[ "$AFTER" == 9.9.9 && "$SIGNED" == 1 && "$LEFT" == MotionForge.app ]] || { echo "ui-demo-update: FAILED install"; exit 1; }
echo "ui-demo-update: all checks passed"
