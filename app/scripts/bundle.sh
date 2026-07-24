#!/bin/zsh
# Build the binary and wrap it into a .app bundle.
# Release (default): dist/Continuations.app
# Debug (--debug):   dist/Continuation-Debug.app — display name
#                    "Continuation Debug", bundle id
#                    com.wezzarddesign.continuation.debug — so debug and release
#                    install side by side with separate prefs and state.
# The bundle (not the bare binary) is what carries the local-network and
# Bonjour privacy declarations macOS requires for NWBrowser.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG=debug
fi

if [[ "$CONFIG" == "debug" ]]; then
    APP=dist/Continuation-Debug.app
    APP_NAME="Continuation Debug"
    BUNDLE_ID="com.wezzarddesign.continuation.debug"
    EXEC_NAME="Continuation-Debug"
else
    APP=dist/Continuations.app
    APP_NAME="Continuations"
    BUNDLE_ID="com.wezzarddesign.continuations"
    EXEC_NAME="Continuations"
fi

# swift-build needs a full Xcode; plain CommandLineTools fails to init the
# build system. Honor a caller's DEVELOPER_DIR, else pick the newest Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && ! -d "$(xcode-select -p)/Platforms" ]]; then
    export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
fi

swift build -c "$CONFIG" --product Continuations

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Continuations" "$APP/Contents/MacOS/$EXEC_NAME"

# Icon: a chosen 1024×1024 master at AppIcon-master.png wins; otherwise
# the vector generator draws the placeholder.
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"
if [[ -f AppIcon-master.png ]]; then
    mkdir -p "$ICONSET"
    while read -r px name; do
        sips -z "$px" "$px" AppIcon-master.png \
            --out "$ICONSET/$name.png" > /dev/null
    done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES
else
    swift scripts/make-icon.swift "$ICONSET" > /dev/null
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Payload: the `continuation` CLI + the agent plugin (plus the marketplace
# manifest that names the plugin), embedded for the Settings installer.
# The materialized copy in Application Support is what agents get wired to.
PAYLOAD="$APP/Contents/Resources/payload"
mkdir -p "$PAYLOAD/bin" "$PAYLOAD/.claude-plugin"
cp ../bin/continuation "$PAYLOAD/bin/continuation"
cp ../.claude-plugin/marketplace.json "$PAYLOAD/.claude-plugin/marketplace.json"
ditto ../plugins/continuation "$PAYLOAD/plugins/continuation"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>${APP_NAME} discovers agentic-continuation nodes on your local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_agentic-cont._tcp</string>
    </array>
</dict>
</plist>
PLIST

# Prefer the Developer ID identity (hardened runtime + timestamp) for a
# distributable archive; fall back to ad-hoc for local dev machines.
# Sign by certificate hash: duplicate certs make names ambiguous.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk '/Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "signed: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (no Developer ID identity found)"
fi

echo "built $APP"

# Only release builds are distribution artifacts worth archiving.
if [[ "$CONFIG" == "release" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
        "$APP/Contents/Info.plist")
    ditto -c -k --keepParent "$APP" "dist/Continuations-$VERSION.zip"
    echo "archived dist/Continuations-$VERSION.zip"
fi
