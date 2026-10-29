#!/bin/zsh
# Live collaboration check against the real Supabase project, signed in as you: shares a small test
# project, has a second editor (in the same process, on its own live connection) join it, edits from
# both sides, checks presence, per-person undo, the shared image and the server copy, then stops
# sharing, which deletes the test project. Needs a Pro account; macOS may ask once about the Keychain.
# If MotionForge is already open, the check uses its current sign-in token without refreshing it, so
# the open copy stays signed in. Results: build/ui-demo-collab/collab.json. Exits non-zero on failure.
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/MotionForge.app ]] || scripts/bundle.sh
OUT="$PWD/build/ui-demo-collab"
rm -rf "$OUT"; mkdir -p "$OUT/recovery"
EXTRA=()
pgrep -qf "MotionForge.app/Contents/MacOS/MotionForge" && EXTRA=(MOTIONFORGE_NO_TOKEN_REFRESH=1)
env "${EXTRA[@]}" MOTIONFORGE_UIDEMO_COLLAB="$OUT" MOTIONFORGE_RECOVERY_DIR="$OUT/recovery" \
    build/MotionForge.app/Contents/MacOS/MotionForge
