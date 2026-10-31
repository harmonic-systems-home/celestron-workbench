#!/usr/bin/env bash
# Builds the AUX Listener (ADR 0018) and wraps it as macos/AuxListener/build/AUX Listener.app,
# signed ad hoc, for Apple silicon and Intel.
#   --install           copies it to ~/Applications on this Mac
#   --deploy [HOST]     copies it to ~/Applications on another Mac over SSH and opens it
#                       there; HOST defaults to AUX_LISTENER_HOST from your shell profile.
#                       Needs Remote Login on that Mac and an SSH key. Never commit HOST.
# Bundle ID prefix: CWB_BUNDLE_ID_PREFIX (default com.popperbiz), as for the iPhone app.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
pkg="$root/macos/AuxListener"
app="$pkg/build/AUX Listener.app"
prefix="${CWB_BUNDLE_ID_PREFIX:-com.popperbiz}"

build=(swift build --package-path "$pkg" -c release --arch arm64 --arch x86_64)
"${build[@]}" --product AuxListener
bin="$("${build[@]}" --show-bin-path)/AuxListener"

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

case "${1:-}" in
  --install)
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/AUX Listener.app"
    cp -R "$app" "$HOME/Applications/"
    echo "Installed in ~/Applications"
    ;;
  --deploy)
    host="${2:-${AUX_LISTENER_HOST:-}}"
    if [ -z "$host" ]; then
      echo "Give the other Mac as --deploy user@host, or set AUX_LISTENER_HOST in your shell profile." >&2
      exit 1
    fi
    ssh "$host" 'osascript -e "quit app \"AUX Listener\"" 2>/dev/null; mkdir -p ~/Applications'
    rsync -a --delete "$app/" "$host:Applications/AUX Listener.app/"
    ssh "$host" 'open ~/Applications/"AUX Listener.app"'
    echo "Installed and opened on $host"
    ;;
esac
