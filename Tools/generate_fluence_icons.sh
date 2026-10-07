#!/bin/bash
# Rebuilds Resources/AppIcon.iconset and Resources/AppIcon.icns from one square artwork
# (1024 px or larger), for when the Fluence icon changes:
#
#   Tools/generate_fluence_icons.sh path/to/artwork.png
#
# Without an argument it only re-packs the existing iconset into AppIcon.icns.
set -e

SRC="$1"
ICONSET="Resources/AppIcon.iconset"

mkdir -p "$ICONSET"

if [ -n "$SRC" ]; then
    echo "Generating iconset from $SRC..."
    sips -s format png -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png" > /dev/null
    sips -s format png -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
    sips -s format png -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png" > /dev/null
    sips -s format png -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
    sips -s format png -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png" > /dev/null
    sips -s format png -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
    sips -s format png -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png" > /dev/null
    sips -s format png -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
    sips -s format png -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png" > /dev/null
    sips -s format png -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
    # The orb drawn inside the app is the same artwork, smaller.
    sips -s format png -z 256 256   "$SRC" --out "Resources/AquaOrb.png" > /dev/null
    cp Resources/AquaOrb.png Resources/AppIcon.png
fi

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
