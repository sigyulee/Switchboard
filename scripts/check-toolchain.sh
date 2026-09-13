#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

fail() {
    printf 'Toolchain check failed: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == Darwin ]] || fail 'local builds and audio checks require macOS.'
[[ "$(uname -m)" == arm64 ]] || fail 'use an Apple Silicon arm64 shell (not Rosetta).'
command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required; no additional Python packages are needed.'
command -v xcrun >/dev/null 2>&1 || fail 'install and select Apple Command Line Tools or Xcode with xcode-select.'

sdk_version="$(xcrun --sdk macosx --show-sdk-version)" || fail 'the selected developer tools have no macOS SDK.'
swift_version="$(xcrun swift --version 2>&1)" || fail 'Swift is unavailable in the selected developer tools.'
xcrun --find clang >/dev/null 2>&1 || fail 'Clang is required for the C sanitizer checks.'
xcrun --find swift-format >/dev/null 2>&1 || fail 'swift-format is required in the selected developer tools.'

python3 - "$sdk_version" "$swift_version" <<'PY'
import re
import sys

if sys.version_info.major != 3:
    sys.exit("Toolchain check failed: Python 3 is required.")
sdk = re.match(r"^(\d+)\.(\d+)", sys.argv[1])
swift = re.search(r"Swift version (\d+)\.(\d+)", sys.argv[2])
if not sdk or tuple(map(int, sdk.groups())) < (27, 0):
    sys.exit("Toolchain check failed: select a macOS 27 or newer SDK with xcode-select.")
if not swift or tuple(map(int, swift.groups())) < (6, 4):
    sys.exit("Toolchain check failed: select Swift 6.4 or newer with xcode-select.")
print(f"Toolchain ready: Darwin arm64, macOS SDK {sys.argv[1]}, "
      f"Swift {'.'.join(swift.groups())}, Python {sys.version.split()[0]}.")
PY
