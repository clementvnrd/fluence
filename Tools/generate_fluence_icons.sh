#!/bin/bash
set -e

SRC="/Users/testuser/.gemini/antigravity/brain/d7a2730a-cd73-4ebf-bf2e-262426a91aa5/.user_uploaded/media_1789512356949.png"
ICONSET="Resources/AppIcon.iconset"

mkdir -p "$ICONSET"

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

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Successfully generated Resources/AppIcon.icns for Fluence!"
