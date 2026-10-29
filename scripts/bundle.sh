#!/bin/zsh
# Builds MotionForge and wraps the executable in a signed macOS .app bundle.
#   scripts/bundle.sh            # release build -> build/MotionForge.app
#   scripts/bundle.sh debug      # debug build
# Signing: MOTIONFORGE_SIGN_IDENTITY if set, else this Mac's "Apple Development" certificate (free with a
# personal team in Xcode), else ad-hoc. A certificate keeps the app's identity the same from build to
# build, so macOS stops asking for Keychain access after every update; ad-hoc builds change identity
# each time.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product MotionForge
swift build -c "$CONFIG" --product mfmcp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/MotionForge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MotionForge" "$APP/Contents/MacOS/MotionForge"
cp "$BIN_DIR/mfmcp" "$APP/Contents/MacOS/mfmcp"  # MCP server for Claude (see ClaudeTools.swift)
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
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
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
        <dict>
            <key>CFBundleTypeName</key><string>MotionForge Project Bundle</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.motionforge.bundle</string></array>
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
        <dict>
            <key>UTTypeIdentifier</key><string>com.motionforge.bundle</string>
            <key>UTTypeDescription</key><string>MotionForge Project Bundle</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>mfbundle</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

SIGN="${MOTIONFORGE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
SIGN="${SIGN:--}"
codesign --force --sign "$SIGN" --timestamp=none "$APP/Contents/MacOS/mfmcp" >/dev/null
codesign --force --sign "$SIGN" --timestamp=none "$APP" >/dev/null
echo "Built $APP ($CONFIG, $(lipo -archs "$APP/Contents/MacOS/MotionForge"), signed ${SIGN/#-/ad-hoc})"
