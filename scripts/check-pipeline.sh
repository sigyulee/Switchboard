#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
bash scripts/check-toolchain.sh
bash scripts/swift.sh build --configuration "$configuration" --target AudioRealtime --jobs 2
bash scripts/swift.sh build --configuration "$configuration" --target TranscriptKit --jobs 2
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-pipeline-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun clang -std=c11 -arch arm64 -mmacosx-version-min=26.0 \
    -I Sources/AudioRealtime/include -c Tests/AudioPipelineChecks/EndpointStatus.c \
    -o "$check_directory/EndpointStatus.o"
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess, sys
binary = Path('.build/arm64-apple-macosx') / sys.argv[1]
temporary = Path(sys.argv[2])
objects = [str(p) for target in ['BridgeCore', 'RecorderKit', 'TranscriptKit']
           for p in sorted((binary / (target + '.build')).glob('*.swift.o'))]
sources = ['AudioPipeline', 'SessionController', 'DeviceCatalog', 'ApplicationCatalog', 'Localization', 'TextKey']
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/clang-cache',
    '-I', str(binary / 'Modules'), '-I', str(binary / 'AudioRealtime.build'),
    *[f'Sources/Switchboard/{name}.swift' for name in sources],
    'Tests/AudioPipelineChecks/DeviceDoubles.swift', 'Tests/AudioPipelineChecks/RouteChecks.swift',
    str(binary / 'AudioRealtime.build/Queue.c.o'), str(temporary / 'EndpointStatus.o'), *objects,
    '-o', str(temporary / 'RouteChecks')], check=True)
subprocess.run([str(temporary / 'RouteChecks')], check=True)
PY
