#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_PATH="$PROJECT_ROOT/.build/Disker.app"
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
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Disker</string>
    <key>CFBundleIdentifier</key><string>com.avaricejs.Disker</string>
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
printf 'Created %s\n' "$APP_PATH"
