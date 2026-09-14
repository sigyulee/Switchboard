#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
bash scripts/check-toolchain.sh
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-microphone-access-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

# Compile the actual observable controller with injected permission operations;
# these checks never read or request the host's microphone permission.
xcrun swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macosx26.0 -module-cache-path .build/clang-cache \
    Sources/Switchboard/MicrophoneAccess.swift \
    Tests/MicrophoneAccessChecks/MicrophoneAccessChecks.swift \
    -o "$check_directory/MicrophoneAccessChecks"
"$check_directory/MicrophoneAccessChecks"
