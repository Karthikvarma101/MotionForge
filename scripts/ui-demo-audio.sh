#!/bin/zsh
# Audio layers + export window check on a real project: selects the audible audio layer (waveform,
# inspector), plays 2.5 s and compares the picture with the audio clock, shows the account card, then
# runs a 60 s export in the export window (CPU / GPU / fps / time left); a screenshot per step.
#   scripts/ui-demo-audio.sh project.mfproj [output-dir]      (default: build/ui-demo-audio)
set -euo pipefail
cd "${0:A:h}/.."
PROJECT="${1:?project.mfproj}"
OUT="${2:-build/ui-demo-audio}"
[[ -d build/MotionForge.app ]] || scripts/bundle.sh release
rm -rf "$OUT"; mkdir -p "$OUT"
MOTIONFORGE_RECOVERY_DIR="${OUT:A}/recovery" MOTIONFORGE_OPEN="${PROJECT:A}" MOTIONFORGE_UIDEMO_AUDIO="${OUT:A}" \
  build/MotionForge.app/Contents/MacOS/MotionForge
echo "Screenshots and ui-demo-audio.json in $OUT"
