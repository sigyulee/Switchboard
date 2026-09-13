#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/check-toolchain.sh
python3 scripts/check-source.py
if [[ -f scripts/compile-localizations.py ]]; then
    python3 scripts/compile-localizations.py --check
fi
for script in scripts/*.sh; do
    bash -n "$script"
done

xcrun swift-format lint --strict --configuration .swift-format --recursive \
    Package.swift Sources Tests Installer
bash scripts/swift.sh run --configuration debug BridgeChecks

# Compile the production queue directly. This executable uses no audio devices,
# application bundle, permissions, or framework callbacks.
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-queue-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun --sdk macosx clang -std=c11 -arch arm64 -mmacosx-version-min=27.0 \
    -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
    -fsanitize=address,undefined -fno-sanitize-recover=all -pthread \
    -I Sources/AudioRealtime/include \
    Sources/AudioRealtime/Queue.c Tests/AudioRealtimeChecks/QueueStress.c \
    -o "$check_directory/QueueStress"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    "$check_directory/QueueStress"
printf 'Local checks passed. Live audio hardware and call behavior were not tested.\n'
