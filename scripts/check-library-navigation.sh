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
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-library-navigation-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

# Reuse the modules already built by BridgeChecks in check.sh; never race another SwiftPM build.
# Navigation uses preview fixtures; first-run checks use isolated preferences and temporary storage.
# Neither path starts a session or requests audio permissions.
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
audio_objects = sorted((binary / 'AudioRealtime.build').glob('*.c.o'))
if not audio_objects:
    sys.exit(f'Missing AudioRealtime build artifacts; build BridgeChecks in {sys.argv[1]} first.')
sources = [
    'AppModel', 'AppStorageDirectories', 'OperationIssue', 'AppTypography', 'AppAudioTap', 'ApplicationCatalog', 'AudioEndpoint', 'AudioPipeline',
    'CallerRouteObserver', 'CapturePermissionRequest', 'DefaultInputLease', 'DeviceCatalog',
    'LegacyInstallation', 'Localization', 'MicrophoneAccess', 'PlaybackController', 'PrivilegedInstaller',
    'ProcessTapConfiguration', 'SessionActions', 'SessionController', 'StoredProcessingController',
    'TextKey', 'TranscriptController',
]
executable = temporary / 'NavigationChecks'
subprocess.run([
    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
    '-target', 'arm64-apple-macosx26.0', '-module-cache-path', '.build/clang-cache',
    '-I', str(binary / 'Modules'), '-I', str(binary / 'AudioRealtime.build'),
    *[f'Sources/Switchboard/{name}.swift' for name in sources],
    'Tests/LibraryNavigationChecks/NavigationChecks.swift', *map(str, audio_objects), *objects,
    '-o', str(executable),
], check=True)
subprocess.run([str(executable)], check=True)
PY
