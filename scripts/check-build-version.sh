#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-build-version.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
    -module-cache-path .build/clang-cache Sources/Switchboard/AppBuildVersion.swift \
    Tests/BuildVersionChecks/Checks.swift -o "$check_directory/BuildVersionChecks"
"$check_directory/BuildVersionChecks"
