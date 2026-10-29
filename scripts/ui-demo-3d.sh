#!/bin/zsh
# Launches the real app and checks the 3D workspace in-app (no global input): 3D cards, a moving camera,
# the Custom View and Orbit tool, and an export of the camera move. Output in build/ui-demo-3d/
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/MotionForge.app ]] || scripts/bundle.sh
OUT="$PWD/build/ui-demo-3d"
rm -rf "$OUT"; mkdir -p "$OUT/recovery"
MOTIONFORGE_UIDEMO_3D="$OUT" MOTIONFORGE_RECOVERY_DIR="$OUT/recovery" MOTIONFORGE_NO_KEYCHAIN=1 \
    build/MotionForge.app/Contents/MacOS/MotionForge
