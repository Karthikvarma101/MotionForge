#!/bin/zsh
# Composition navigation + timeline gesture check on a real nested project: opens it, goes
# master -> scene -> rig (tabs + breadcrumb), zooms with option-scroll, scrolls with a sideways
# swipe, jumps back through the breadcrumb, switches and closes tabs; a screenshot per step.
#   scripts/ui-demo-nav.sh project.mfproj [output-dir]      (default: build/ui-demo-nav)
set -euo pipefail
cd "${0:A:h}/.."
PROJECT="${1:?project.mfproj}"
OUT="${2:-build/ui-demo-nav}"
[[ -d build/MotionForge.app ]] || scripts/bundle.sh release
rm -rf "$OUT"; mkdir -p "$OUT"
MOTIONFORGE_RECOVERY_DIR="${OUT:A}/recovery" MOTIONFORGE_OPEN="${PROJECT:A}" MOTIONFORGE_UIDEMO_NAV="${OUT:A}" \
  build/MotionForge.app/Contents/MacOS/MotionForge
echo "Screenshots and ui-demo-nav.json in $OUT"
