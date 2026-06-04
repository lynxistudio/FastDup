#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/FastDup.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/build/FastDupIcon.iconset"
ICON_PNG="$ROOT_DIR/Assets/FastDupIcon-1024.png"
MODULE_CACHE_DIR="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"

VERSION="${VERSION:-1.1.5}"
BUILD="${BUILD:-7}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR" "$MODULE_CACHE_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -framework QuickLookUI \
  -framework CoreServices \
  -framework Quartz \
  "$ROOT_DIR/FastDupApp.swift" "$ROOT_DIR"/Models/*.swift "$ROOT_DIR"/Services/*.swift \
  -lsqlite3 \
  -o "$MACOS_DIR/FastDup"

cp "$ICON_PNG" "$RESOURCES_DIR/FastDupIcon.png"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
while read -r size name; do
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/$name" >/dev/null
done <<'EOF'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
EOF

python3 - "$ICONSET_DIR" "$RESOURCES_DIR/FastDupIcon.icns" <<'PY'
from pathlib import Path
import sys

iconset = Path(sys.argv[1])
out = Path(sys.argv[2])
pairs = [
    ("icp4", "icon_16x16.png"),
    ("ic04", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("ic05", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]
chunks = []
for code, name in pairs:
    data = (iconset / name).read_bytes()
    chunks.append(code.encode("ascii") + (len(data) + 8).to_bytes(4, "big") + data)
body = b"".join(chunks)
out.write_bytes(b"icns" + (len(body) + 8).to_bytes(4, "big") + body)
PY

python3 - "$CONTENTS_DIR/Info.plist" "$VERSION" "$BUILD" <<'PY'
import plistlib
from pathlib import Path
import sys

plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "FastDup",
    "CFBundleIconFile": "FastDupIcon.icns",
    "CFBundleIconName": "FastDupIcon",
    "CFBundleIcons": {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": ["FastDupIcon"],
            "CFBundleIconName": "FastDupIcon",
        }
    },
    "CFBundleIdentifier": "com.fastdup.app",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "FastDup",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundleVersion": sys.argv[3],
    "LSApplicationCategoryType": "public.app-category.utilities",
    "LSMinimumSystemVersion": "14.0",
    "NSPrincipalClass": "NSApplication",
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False))
PY

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR"
