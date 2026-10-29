#!/bin/zsh
# Launches the real app and checks the workspace features in-app (no global input): hiding panels,
# the Claude panel, exporting and importing a project bundle, and auto save writing the file every
# 2 s. Screenshots and features.json go to build/ui-demo-features/. Exits non-zero if a check fails.
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/MotionForge.app ]] || scripts/bundle.sh
OUT="$PWD/build/ui-demo-features"
rm -rf "$OUT"; mkdir -p "$OUT/recovery"
MOTIONFORGE_UIDEMO_FEATURES="$OUT" MOTIONFORGE_RECOVERY_DIR="$OUT/recovery" MOTIONFORGE_NO_KEYCHAIN=1 \
    build/MotionForge.app/Contents/MacOS/MotionForge
