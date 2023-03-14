#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/disker-event-check.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

xcrun swiftc -parse-as-library -framework CoreServices \
    "$ROOT/Sources/DiskerApp/SelectedRootEventWatcher.swift" \
    "$ROOT/Tests/DiskerAppChecks/SelectedRootEventWatcherChecks.swift" \
    -o "$TEMP_DIR/SelectedRootEventWatcherChecks"
"$TEMP_DIR/SelectedRootEventWatcherChecks"
