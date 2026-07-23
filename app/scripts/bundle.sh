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
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Continuations "$APP/Contents/MacOS/Continuations"

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

codesign --force --sign - "$APP"
echo "built $APP"
