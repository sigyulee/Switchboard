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
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-session-presentation-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun clang -std=c11 -arch arm64 -mmacosx-version-min=26.0 \
    -I Sources/AudioRealtime/include -c Tests/AudioPipelineChecks/EndpointStatus.c \
    -o "$check_directory/EndpointStatus.o"
# The main check gate has built these dependencies already. Never open devices or invoke SwiftPM here.
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess, sys

binary = Path('.build/arm64-apple-macosx') / sys.argv[1]
temporary = Path(sys.argv[2])
objects = []
for target in ['BridgeCore', 'RecorderKit', 'TranscriptKit']:
    target_objects = sorted((binary / (target + '.build')).glob('*.swift.o'))
    if not target_objects or not (binary / 'Modules' / (target + '.swiftmodule')).is_file():
        sys.exit(f'Missing {target} build artifacts; build BridgeChecks in {sys.argv[1]} first.')
    objects.extend(map(str, target_objects))
sources = ['AudioPipeline', 'SessionController', 'DeviceCatalog', 'ApplicationCatalog', 'Localization', 'TextKey']
executable = temporary / 'PresentationChecks'
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/clang-cache',
    '-I', str(binary / 'Modules'), '-I', str(binary / 'AudioRealtime.build'),
    *[f'Sources/Switchboard/{name}.swift' for name in sources],
    'Tests/AudioPipelineChecks/DeviceDoubles.swift', 'Tests/SessionPresentationChecks/PresentationChecks.swift',
    str(binary / 'AudioRealtime.build/Queue.c.o'), str(temporary / 'EndpointStatus.o'), *objects,
    '-o', str(executable),
], check=True)
subprocess.run([str(executable)], check=True)
PY
