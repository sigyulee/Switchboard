#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
bash scripts/check-toolchain.sh
bash scripts/swift.sh build --configuration "$configuration" --target RecorderKit --jobs 2
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-transcript-pcm-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess, sys
binary = Path('.build/arm64-apple-macosx') / sys.argv[1]
temporary = Path(sys.argv[2])
objects = [str(p) for target in ['BridgeCore', 'RecorderKit']
           for p in sorted((binary / (target + '.build')).glob('*.swift.o'))]
# Compile the actual internal converter and feed together with its checks. This
# works with either dependency configuration without exporting a testing API.
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    *(['-O'] if sys.argv[1] == 'release' else []),
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/clang-cache',
    '-I', str(binary / 'Modules'),
    'Sources/TranscriptKit/TranscriptAudioSequence.swift',
    'Sources/TranscriptKit/TranscriptFeed.swift',
    'Tests/TranscriptPCMChecks/PCMChecks.swift', *objects,
    '-o', str(temporary / 'PCMChecks')], check=True)
subprocess.run([str(temporary / 'PCMChecks')], check=True)
PY
