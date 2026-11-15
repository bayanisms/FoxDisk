#!/bin/zsh
set -eu
cd "${0:A:h:h}"
./build.sh
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr build/FoxDisk.app "$stage/FoxDisk.app"
ln -s /Applications "$stage/Applications"
mkdir -p dist
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
image="dist/FoxDisk-${version}-macOS.dmg"
hdiutil create -ov -fs HFS+ -format UDZO -volname FoxDisk -srcfolder "$stage" "$image"
hdiutil verify "$image"
