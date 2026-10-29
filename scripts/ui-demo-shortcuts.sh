#!/bin/zsh
# Launches the real app and checks the After Effects shortcuts in-app (key presses and mouse drags are
# sent to its own window, never system-wide): the menus' key equivalents, the tools, property reveal,
# the work area, RAM Preview, Split Layer, Pre-compose, Trim Comp, the shortcut sheet and Preferences.
# Screenshots and shortcuts.json go to build/ui-demo-shortcuts/. Exits non-zero if a check fails.
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/MotionForge.app ]] || scripts/bundle.sh
OUT="$PWD/build/ui-demo-shortcuts"
rm -rf "$OUT"; mkdir -p "$OUT/recovery"
MOTIONFORGE_UIDEMO_SHORTCUTS="$OUT" MOTIONFORGE_RECOVERY_DIR="$OUT/recovery" MOTIONFORGE_NO_KEYCHAIN=1 \
    build/MotionForge.app/Contents/MacOS/MotionForge
