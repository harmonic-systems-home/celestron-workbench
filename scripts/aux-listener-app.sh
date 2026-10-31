#!/usr/bin/env bash
# Builds the AUX Listener (ADR 0018) and wraps it as macos/AuxListener/build/AUX Listener.app,
# signed ad hoc to run on this Mac. Optional: --install copies it to ~/Applications.
# Bundle ID prefix: CWB_BUNDLE_ID_PREFIX (default com.popperbiz), as for the iPhone app.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
pkg="$root/macos/AuxListener"
app="$pkg/build/AUX Listener.app"
prefix="${CWB_BUNDLE_ID_PREFIX:-com.popperbiz}"

swift build --package-path "$pkg" -c release --product AuxListener
bin="$(swift build --package-path "$pkg" -c release --show-bin-path)/AuxListener"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/AuxListener"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AuxListener</string>
  <key>CFBundleIdentifier</key><string>$prefix.AuxListener</string>
  <key>CFBundleName</key><string>AUX Listener</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/AUX Listener.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed in ~/Applications"
fi
