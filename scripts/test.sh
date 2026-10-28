#!/bin/bash
set -euo pipefail

MIC_LOCK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MIC_LOCK_ROOT"
export CLANG_MODULE_CACHE_PATH="$MIC_LOCK_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MIC_LOCK_ROOT/.build/module-cache"
exec swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
