#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-standard}" in
    standard)
        APP_PATH="$PROJECT_ROOT/.build/Disker.app"
        BUNDLE_ID="com.avaricejs.Disker"
        SANDBOXED=false
        ;;
    sandboxed)
        APP_PATH="$PROJECT_ROOT/.build/Disker-Sandboxed.app"
        BUNDLE_ID="com.avaricejs.Disker.Sandboxed"
        SANDBOXED=true
        ;;
    *)
        printf 'Usage: %s [standard|sandboxed]\n' "$0" >&2
        exit 2
        ;;
esac
CONTENTS="$APP_PATH/Contents"
mkdir -p "$PROJECT_ROOT/.build/clang-module-cache"

cd "$PROJECT_ROOT"
CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-module-cache" swift build \
    --disable-sandbox \
    --cache-path "$PROJECT_ROOT/.build/swiftpm-cache" \
    --manifest-cache local \
    -c release \
    --product Disker
mkdir -p "$CONTENTS/MacOS"
cp "$PROJECT_ROOT/.build/release/Disker" "$CONTENTS/MacOS/Disker"
ICONSET="$PROJECT_ROOT/.build/Disker.iconset"
swift "$PROJECT_ROOT/scripts/create-app-icon.swift" "$ICONSET"
mkdir -p "$CONTENTS/Resources"
/usr/bin/iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Disker</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Disker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
if [ "$SANDBOXED" = true ]; then
    codesign --force --sign - --timestamp=none \
        --entitlements "$PROJECT_ROOT/config/Disker-Sandboxed.entitlements" \
        "$APP_PATH"
    codesign --verify --strict --deep "$APP_PATH"
fi
printf 'Created %s\n' "$APP_PATH"
