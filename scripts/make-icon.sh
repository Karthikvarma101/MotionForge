#!/bin/zsh
# Regenerates Resources/AppIcon.icns (and the 1024 px master) from the brand artwork.
set -euo pipefail
cd "${0:A:h}/.."
TMP="$(mktemp -d)"
swift scripts/make-icon.swift Resources/Brand/MotionForge-AppIcon-source.png "$TMP/AppIcon.iconset" Resources/Brand/AppIcon-1024.png
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns"
