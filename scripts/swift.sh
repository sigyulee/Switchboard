#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
verb="${1:-build}"
shift || true
build_system="${SWITCHBOARD_SWIFT_BUILD_SYSTEM:-native}"
case "$build_system" in
    native|swiftbuild) ;;
    *) printf 'Unsupported Swift build system: %s\n' "$build_system" >&2; exit 2 ;;
esac
exec xcrun swift "$verb" --build-system "$build_system" --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
