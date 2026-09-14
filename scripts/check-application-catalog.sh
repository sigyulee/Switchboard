#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
bash scripts/check-toolchain.sh
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-catalog-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

# Compile the real identity and catalog with fixed discovery inputs. No workspace
# enumeration, application launch, permissions, or audio access is involved.
xcrun swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macosx26.0 -module-cache-path .build/clang-cache \
    -emit-library -emit-module -module-name BridgeCore \
    -emit-module-path "$check_directory/BridgeCore.swiftmodule" \
    Sources/BridgeCore/ApplicationIdentity.swift -o "$check_directory/libBridgeCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macosx26.0 -module-cache-path .build/clang-cache \
    -I "$check_directory" -L "$check_directory" -lBridgeCore \
    -Xlinker -rpath -Xlinker "$check_directory" \
    Sources/Switchboard/ApplicationCatalog.swift \
    Tests/ApplicationCatalogChecks/ApplicationCatalogChecks.swift \
    -o "$check_directory/ApplicationCatalogChecks"
"$check_directory/ApplicationCatalogChecks"
