#!/bin/zsh
# Launch animation + Home window: screenshots at 0.2 ... 3 s after launch (build/ui-demo-home/).
set -euo pipefail
cd "${0:A:h}/.."
OUT="${1:-build/ui-demo-home}"
[[ -d build/MotionForge.app ]] || scripts/bundle.sh release
rm -rf "$OUT"; mkdir -p "$OUT"
MOTIONFORGE_RECOVERY_DIR="${OUT:A}/recovery" MOTIONFORGE_UIDEMO_HOME="${OUT:A}" build/MotionForge.app/Contents/MacOS/MotionForge
echo "Frames in $OUT"
