#!/bin/zsh
# Builds MotionForge and wraps the executable in a signed (ad-hoc) macOS .app bundle.
#   scripts/bundle.sh            # release build -> build/MotionForge.app
#   scripts/bundle.sh debug      # debug build
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product MotionForge
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/MotionForge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MotionForge" "$APP/Contents/MacOS/MotionForge"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MotionForge</string>
    <key>CFBundleDisplayName</key><string>MotionForge</string>
    <key>CFBundleIdentifier</key><string>com.motionforge.MotionForge</string>
    <key>CFBundleExecutable</key><string>MotionForge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>MotionForge Project</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.motionforge.project</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.motionforge.project</string>
            <key>UTTypeDescription</key><string>MotionForge Project</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>mfproj</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP ($CONFIG, $(lipo -archs "$APP/Contents/MacOS/MotionForge"))"
