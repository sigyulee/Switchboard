#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
bash scripts/check-toolchain.sh

# Keep instrumented products separate from normal debug and release builds.
TSAN_OPTIONS=halt_on_error=1:exitcode=66 \
    bash scripts/swift.sh run --configuration debug \
    --scratch-path .build/thread-sanitizer --sanitize thread BridgeChecks
