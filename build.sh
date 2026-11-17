#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
BUILD_OPTIONS=(--disable-sandbox --build-system native --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release)
swift build "${BUILD_OPTIONS[@]}"
BUILD_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
APP="$PWD/dist/Claudy Archive.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/ClaudyArchive" "$APP/Contents/MacOS/ClaudyArchive.new"
mv -f "$APP/Contents/MacOS/ClaudyArchive.new" "$APP/Contents/MacOS/ClaudyArchive"
cp Info.plist "$APP/Contents/Info.plist"
if [ -d "$BUILD_DIR/ClaudyArchive_ClaudyArchive.bundle" ]; then
    ditto "$BUILD_DIR/ClaudyArchive_ClaudyArchive.bundle" "$APP/Contents/Resources/ClaudyArchive_ClaudyArchive.bundle"
else
    echo "The SwiftPM resources bundle was not found." >&2
    exit 1
fi
swift scripts/icon.swift "$PWD/dist/AppIcon.iconset"
cp "$PWD/dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/Claudy Archive-macOS.zip"
echo "Built: $APP"
