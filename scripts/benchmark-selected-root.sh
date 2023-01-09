#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "Usage: scripts/benchmark-selected-root.sh <existing-directory>" >&2
    exit 2
fi

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SELECTED_ROOT=$1
mkdir -p "$PROJECT_ROOT/.build/clang-module-cache"
cd "$PROJECT_ROOT"
CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-module-cache" swift run \
    --disable-sandbox \
    --cache-path "$PROJECT_ROOT/.build/swiftpm-cache" \
    --manifest-cache local \
    DiskerCoreChecks --benchmark-root "$SELECTED_ROOT"
