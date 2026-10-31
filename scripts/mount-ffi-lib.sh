#!/usr/bin/env bash
# Builds the mount session library (crates/mount-ffi, ADR 0019) for Apple
# silicon and Intel, and joins them into rust/target/universal/release/
# libcwb_mount_ffi.a, which the Mac apps link.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root/rust"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release --package cwb-mount-ffi --target "$target"
done
out=target/universal/release
mkdir -p "$out"
lipo -create \
  target/aarch64-apple-darwin/release/libcwb_mount_ffi.a \
  target/x86_64-apple-darwin/release/libcwb_mount_ffi.a \
  -output "$out/libcwb_mount_ffi.a"
echo "Built rust/$out/libcwb_mount_ffi.a ($(lipo -archs "$out/libcwb_mount_ffi.a"))"
