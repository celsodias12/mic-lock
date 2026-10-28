#!/bin/bash
set -euo pipefail

MIC_LOCK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MIC_LOCK_ROOT"
export CLANG_MODULE_CACHE_PATH="$MIC_LOCK_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MIC_LOCK_ROOT/.build/module-cache"

MIC_LOCK_SWIFT_ARGS=(--configuration release --disable-sandbox -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security)
swift build "${MIC_LOCK_SWIFT_ARGS[@]}"
MIC_LOCK_BIN_DIR="$(swift build "${MIC_LOCK_SWIFT_ARGS[@]}" --show-bin-path)"
MIC_LOCK_APP="$MIC_LOCK_ROOT/build/Mic Lock.app"

mkdir -p "$MIC_LOCK_APP/Contents/MacOS" "$MIC_LOCK_APP/Contents/Resources"
install -m 755 "$MIC_LOCK_BIN_DIR/MicLock" "$MIC_LOCK_APP/Contents/MacOS/MicLock"
install -m 644 Resources/Info.plist "$MIC_LOCK_APP/Contents/Info.plist"
plutil -lint "$MIC_LOCK_APP/Contents/Info.plist"
codesign --force --sign - "$MIC_LOCK_APP"
codesign --verify --strict "$MIC_LOCK_APP"
printf '\nApp criado: %s\n' "$MIC_LOCK_APP"
