# App icon

`AppIcon.icns` is drawn by `make-icon.swift`: the owner's own photo of the Moon (`moon.png`, a DWARF 3 stack from 2026-11-20, cropped to the disk, greyscale and with no metadata; CC0) with the mosaic plan's tiles over its sunlit part. Without `moon.png` the script draws a Moon instead. `scripts/moon-mosaic-app.sh` copies it into the app.

To redraw it after changing the script:

```sh
cd macos/MoonMosaic/Icon
T=$(mktemp -d); I=$T/AppIcon.iconset; mkdir $I
swift make-icon.swift $T/big.png 1024 moon.png
for n in 16 32 128 256 512; do
  sips -z $n $n $T/big.png --out $I/icon_${n}x${n}.png
  sips -z $((n*2)) $((n*2)) $T/big.png --out $I/icon_${n}x${n}@2x.png
done
iconutil -c icns $I -o AppIcon.icns
```
