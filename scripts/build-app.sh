#!/bin/bash
# Builds "API Proxy Widget.app" into build/ from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
app="build/API Proxy Widget.app"

swift build -c release --product APIProxyWidget
bin="$(swift build -c release --show-bin-path)/APIProxyWidget"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/APIProxyWidget"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.github.stivenkn.api-proxy-widget</string>
	<key>CFBundleName</key>
	<string>API Proxy Widget</string>
	<key>CFBundleExecutable</key>
	<string>APIProxyWidget</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- Menu bar only: no Dock icon, no app menu. -->
	<key>LSUIElement</key>
	<true/>
	<!-- A hub on this Mac or the local network is plain HTTP. -->
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$app"
echo "$app"
