#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
QA_APP="$ROOT/.build/Disker-DashboardModel-QA-$RUN_ID.app"
RESULT="$ROOT/.build/disker-dashboard-model-qa/$RUN_ID/result.txt"
RESULT_DIR=$(dirname "$RESULT")

cleanup() {
    rm -rf "$QA_APP" "$RESULT_DIR"
    rmdir "$ROOT/.build/disker-dashboard-model-qa" 2>/dev/null || true
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
<key>CFBundleIdentifier</key><string>com.avaricejs.Disker.DashboardModelQA.$RUN_ID</string>
<key>CFBundleName</key><string>Disker Dashboard Model QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$QA_APP"
codesign --verify --strict --deep "$QA_APP"
if "$QA_APP/Contents/MacOS/Disker" --dashboard-model-monitoring-check "$RESULT"; then
    APP_STATUS=0
else
    APP_STATUS=$?
fi
if [ -f "$RESULT" ]; then
    cat "$RESULT"
else
    echo "DashboardModel QA app exited $APP_STATUS without writing its result." >&2
fi
[ "$APP_STATUS" -eq 0 ]
grep -q '^PASS DashboardModel monitor lifecycle, event-triggered growth scan, persisted same-path report, opt-out, re-opt-in baseline, and periodic scheduled scan$' "$RESULT"
