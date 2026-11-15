#!/bin/zsh
set -eu
cd "${0:A:h}"
app=build/FoxDisk.app/Contents
icons=build/FoxDisk.iconset
mkdir -p "$app/MacOS" "$app/Resources" "$icons"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/FoxDisk.png --out "$icons/icon_${size}x${size}.png" >/dev/null
    sips -z "$((2 * size))" "$((2 * size))" Assets/FoxDisk.png --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$app/Resources/FoxDisk.icns"
for arch in arm64 x86_64; do
    swiftc -module-name FoxDisk -module-cache-path build/ModuleCache -O -target "${arch}-apple-macos13.0" -parse-as-library Sources/*.swift -o "build/FoxDisk-$arch"
done
lipo -create build/FoxDisk-arm64 build/FoxDisk-x86_64 -output "$app/MacOS/FoxDisk"
cp Info.plist "$app/Info.plist"
codesign --force --sign - build/FoxDisk.app
codesign --verify --strict build/FoxDisk.app
