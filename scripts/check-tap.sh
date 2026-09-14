#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/check-toolchain.sh
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-tap-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
    -module-cache-path "$check_directory/module-cache" \
    Sources/Switchboard/ProcessTapConfiguration.swift Tests/AudioTapChecks/ConfigurationChecks.swift \
    -framework CoreAudio -framework Foundation -o "$check_directory/ConfigurationChecks"
"$check_directory/ConfigurationChecks"
