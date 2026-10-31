#!/usr/bin/env bash
# Builds the Moon Mosaic app (ADR 0019) as macos/MoonMosaic/build/Moon Mosaic.app
# for Apple silicon and Intel, signed ad hoc: first the Rust mount library,
# then the Swift app linked against it.
#   --install           copies it to ~/Applications on this Mac
#   --deploy [HOST]     copies it to ~/Applications on another Mac over SSH,
#                       installs ZWO's camera library there if missing, and
#                       opens it; HOST defaults to AUX_LISTENER_HOST.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
pkg="$root/macos/MoonMosaic"
app="$pkg/build/Moon Mosaic.app"
prefix="${CWB_BUNDLE_ID_PREFIX:-com.popperbiz}"

"$root/scripts/mount-ffi-lib.sh"
build=(swift build --package-path "$pkg" -c release --arch arm64 --arch x86_64)
"${build[@]}" --product MoonMosaic
bin="$("${build[@]}" --show-bin-path)/MoonMosaic"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/MoonMosaic"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MoonMosaic</string>
  <key>CFBundleIdentifier</key><string>$prefix.MoonMosaic</string>
  <key>CFBundleName</key><string>Moon Mosaic</string>
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
    rm -rf "$HOME/Applications/Moon Mosaic.app"
    cp -R "$app" "$HOME/Applications/"
    echo "Installed in ~/Applications"
    ;;
  --deploy)
    host="${2:-${AUX_LISTENER_HOST:-}}"
    if [ -z "$host" ]; then
      echo "Give the other Mac as --deploy user@host, or set AUX_LISTENER_HOST." >&2
      exit 1
    fi
    if ! ssh "$host" 'test -f ~/Library/Application\ Support/MoonMosaic/lib/libASICamera2.dylib'; then
      echo "Installing ZWO's camera library on $host"
      ssh "$host" 'zsh -lc "bash -s"' < "$root/scripts/zwo-camera-lib.sh"
    fi
    ssh "$host" 'osascript -e "quit app \"Moon Mosaic\"" 2>/dev/null; mkdir -p ~/Applications'
    rsync -a --delete "$app/" "$host:Applications/Moon Mosaic.app/"
    ssh "$host" 'open ~/Applications/"Moon Mosaic.app"'
    echo "Installed and opened on $host"
    ;;
esac
