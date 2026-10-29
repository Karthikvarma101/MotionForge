#!/bin/zsh
# Launches the real app and checks footage and rotoscoping in-app (no global input): a generated clip,
# PNG and SVG imported the normal way, frames rendered, the Roto Brush following the ball, a mask
# rotoscoped by hand in the viewer, and a video export. Output in build/ui-demo-media/.
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/MotionForge.app ]] || scripts/bundle.sh
OUT="$PWD/build/ui-demo-media"
rm -rf "$OUT"; mkdir -p "$OUT/recovery"
MOTIONFORGE_UIDEMO_MEDIA="$OUT" MOTIONFORGE_RECOVERY_DIR="$OUT/recovery" MOTIONFORGE_NO_KEYCHAIN=1 \
    build/MotionForge.app/Contents/MacOS/MotionForge
