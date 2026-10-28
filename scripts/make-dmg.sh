#!/bin/zsh
# Packs build/MotionForge.app into a drag-to-Applications disk image -> build/MotionForge.dmg.
#   scripts/bundle.sh && scripts/make-dmg.sh
# Needs uv (https://docs.astral.sh/uv/): dmgbuild writes the Finder window layout without scripting Finder.
set -euo pipefail
cd "${0:A:h}/.."

APP="build/MotionForge.app"
DMG="build/MotionForge.dmg"
[[ -d "$APP" ]] || { echo "No $APP: run scripts/bundle.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-dmg-background.swift "$WORK"

rm -f "$DMG"
uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py \
    -D app="$APP" -D background="$WORK/background.png" -D icon=Resources/AppIcon.icns \
    "MotionForge $VERSION" "$DMG"
codesign --force --sign - --timestamp=none "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $DMG (MotionForge $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
