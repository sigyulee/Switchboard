#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-scroll-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$configuration" "$check_directory" <<'PY'
from pathlib import Path
import subprocess,sys
binary=Path('.build/arm64-apple-macosx') / sys.argv[1]
output=Path(sys.argv[2]) / 'Checks'
objects=sorted((binary/'BridgeCore.build').glob('*.swift.o'))
if not objects: sys.exit('Build BridgeChecks first.')
sources=['AppTypography','TextKey','ViewState','ControlStyles','AppFindController',
         'TranscriptScrollFollow','TranscriptTailFrame','TranscriptSearch','TranscriptSearchText','TranscriptMessages']
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-target','arm64-apple-macosx26.0',
 '-module-cache-path','.build/scroll-layout-cache','-I',str(binary/'Modules'),
 *[f'Sources/Switchboard/{name}.swift' for name in sources],
 'Tests/TranscriptScrollLayoutChecks/Checks.swift', *map(str,objects),'-o',str(output)],check=True)
subprocess.run([str(output)],check=True)
PY
