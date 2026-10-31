#!/usr/bin/env bash
# Installs ZWO's camera library for Apple silicon where the Moon Mosaic app
# looks first (ADR 0019): ~/Library/Application Support/MoonMosaic/lib/.
# ASIStudio's own copy is Intel-only. This one is ZWO's arm64 build as INDI
# ships it (indilib/indi-3rdparty, libasi/mac_arm64; ZWO's MIT-style licence),
# pinned by commit and SHA-256, pointed at Homebrew's libusb and signed ad
# hoc for this Mac. Never committed to this repo.
set -euo pipefail

commit=f5e7166564d1afea311faf622d368afbe14bd841
sha256=7b0c3ef65f90460f6b7fcd98dcf071f4d540bf843b6529d214d05520d82da06e
url="https://raw.githubusercontent.com/indilib/indi-3rdparty/$commit/libasi/mac_arm64/libASICamera2.bin"
dest="$HOME/Library/Application Support/MoonMosaic/lib"

if [ "$(uname -m)" != "arm64" ]; then
  echo "This Mac is Intel: the app can load ASIStudio's copy instead." >&2
  exit 0
fi
brew list libusb >/dev/null 2>&1 || brew install libusb
libusb="$(brew --prefix libusb)/lib/libusb-1.0.0.dylib"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -sSfL "$url" -o "$work/libASICamera2.dylib"
echo "$sha256  $work/libASICamera2.dylib" | shasum -a 256 -c - >/dev/null || {
  echo "checksum mismatch: not installing" >&2
  exit 1
}
install_name_tool -id "$dest/libASICamera2.dylib" "$work/libASICamera2.dylib"
install_name_tool -change @rpath/libusb-1.0.0.dylib "$libusb" "$work/libASICamera2.dylib"
codesign --force --sign - "$work/libASICamera2.dylib"
mkdir -p "$dest"
cp "$work/libASICamera2.dylib" "$dest/"
echo "Installed $dest/libASICamera2.dylib"
