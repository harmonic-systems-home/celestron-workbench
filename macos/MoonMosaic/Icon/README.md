# App icon

`AppIcon.icns` is drawn by `make-icon.swift`: a gibbous Moon with the mosaic plan's tiles over it, all procedural, with no photos. `scripts/moon-mosaic-app.sh` copies it into the app.

To redraw it after changing the script:

```sh
cd macos/MoonMosaic/Icon
T=$(mktemp -d); I=$T/AppIcon.iconset; mkdir $I
swift make-icon.swift $T/big.png 1024
for n in 16 32 128 256 512; do
  sips -z $n $n $T/big.png --out $I/icon_${n}x${n}.png
  sips -z $((n*2)) $((n*2)) $T/big.png --out $I/icon_${n}x${n}@2x.png
done
iconutil -c icns $I -o AppIcon.icns
```
