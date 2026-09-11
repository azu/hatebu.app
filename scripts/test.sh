#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift test --disable-sandbox --cache-path .build/cache
