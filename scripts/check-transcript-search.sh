#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [debug|release]\n' "$0" >&2
    exit 2
fi
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
bash scripts/check-toolchain.sh
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-transcript-search-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

# Reuse the module already built by BridgeChecks in check.sh without another SwiftPM build.
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess, sys

binary = Path('.build/arm64-apple-macosx') / sys.argv[1]
temporary = Path(sys.argv[2])
objects = sorted((binary / 'BridgeCore.build').glob('*.swift.o'))
if not objects or not (binary / 'Modules/BridgeCore.swiftmodule').is_file():
    sys.exit(f'Missing BridgeCore build artifacts; build BridgeChecks in {sys.argv[1]} first.')
executable = temporary / 'SearchChecks'
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/transcript-search-clang-cache',
    '-I', str(binary / 'Modules'),
    'Sources/Switchboard/AppFindController.swift', 'Sources/Switchboard/TranscriptSearch.swift',
    'Tests/TranscriptSearchChecks/SearchChecks.swift', *map(str, objects), '-o', str(executable),
], check=True)
subprocess.run([str(executable)], check=True)
PY
