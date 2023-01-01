#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$PROJECT_ROOT/.build/clang-module-cache"
cd "$PROJECT_ROOT"
CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-module-cache" swift run \
    --disable-sandbox \
    --cache-path "$PROJECT_ROOT/.build/swiftpm-cache" \
    --manifest-cache local \
    DiskerCoreChecks
