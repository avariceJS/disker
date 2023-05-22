#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
BUNDLE_ID="com.avaricejs.Disker.SandboxFootprintQA.$RUN_ID"
QA_APP="$ROOT/.build/Disker-SandboxFootprint-QA-$RUN_ID.app"
RESULT_BASE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Caches/DiskerAppFootprintQA"
RESULT_DIR="$RESULT_BASE/$RUN_ID"
RESULT="$RESULT_DIR/result.txt"

cleanup() {
    rm -rf "$QA_APP" "$RESULT_DIR"
    rmdir "$RESULT_BASE" 2>/dev/null || true
}

if [ -e "$QA_APP" ] || [ -e "$RESULT_DIR" ]; then
    echo "Refusing to overwrite a QA artifact for run $RUN_ID." >&2
    exit 1
fi
trap cleanup EXIT INT TERM

cd "$ROOT"
swift build -c debug --product Disker
mkdir -p "$QA_APP/Contents/MacOS"
cp "$ROOT/.build/debug/Disker" "$QA_APP/Contents/MacOS/Disker"
cat > "$QA_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Disker</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Disker Sandbox Footprint QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/config/Disker-Sandboxed.entitlements" "$QA_APP"
codesign --verify --strict --deep "$QA_APP"
if open -W -n "$QA_APP" --args --sandboxed-app-footprint-check "$RUN_ID"; then
    APP_STATUS=0
else
    APP_STATUS=$?
fi
if [ -f "$RESULT" ]; then
    cat "$RESULT"
else
    echo "Sandboxed footprint QA app exited $APP_STATUS without writing its result." >&2
fi
[ "$APP_STATUS" -eq 0 ]
grep -q '^PASS sandboxed app bundle and app-owned support no-follow boundary$' "$RESULT"
