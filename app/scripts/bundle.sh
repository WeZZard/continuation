#!/bin/zsh
# Build the release binary and wrap it into Continuations.app.
# The bundle (not the bare binary) is what carries the local-network and
# Bonjour privacy declarations macOS requires for NWBrowser.
set -euo pipefail
cd "$(dirname "$0")/.."

# swift-build needs a full Xcode; plain CommandLineTools fails to init the
# build system. Honor a caller's DEVELOPER_DIR, else pick the newest Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && ! -d "$(xcode-select -p)/Platforms" ]]; then
    export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
fi

swift build -c release --product Continuations

APP=dist/Continuations.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Continuations "$APP/Contents/MacOS/Continuations"

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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.wezzard.continuations</string>
    <key>CFBundleName</key>
    <string>Continuations</string>
    <key>CFBundleDisplayName</key>
    <string>Continuations</string>
    <key>CFBundleExecutable</key>
    <string>Continuations</string>
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
    <string>Continuations discovers agentic-continuation nodes on your local network.</string>
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

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$APP/Contents/Info.plist")
ditto -c -k --keepParent "$APP" "dist/Continuations-$VERSION.zip"
echo "built $APP"
echo "archived dist/Continuations-$VERSION.zip"
