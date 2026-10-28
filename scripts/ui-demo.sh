#!/bin/zsh
# End-to-end UI check: launches the real app, which clicks/drags inside its own window, edits
# scale/opacity, undoes, plays back for 4 s, saves + reopens, screenshots each step, then quits.
#   scripts/ui-demo.sh [output-dir]      (default: build/ui-demo)
set -euo pipefail
cd "${0:A:h}/.."
OUT="${1:-build/ui-demo}"
[[ -d build/MotionForge.app ]] || scripts/bundle.sh release
rm -rf "$OUT"; mkdir -p "$OUT"
MOTIONFORGE_RECOVERY_DIR="${OUT:A}/recovery" MOTIONFORGE_UIDEMO="${OUT:A}" build/MotionForge.app/Contents/MacOS/MotionForge
echo "Screenshots and ui-demo.json in $OUT"
