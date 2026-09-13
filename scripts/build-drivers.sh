#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/drivers
python3 scripts/prepare-driver.py build/drivers/BlackHole.c
build_driver() {
    local role="$1" display="$2" factory="$3"
    local name="MIH${role}"
    local bundle="build/drivers/${name}.driver"
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    # Upstream always supplies a channel-count format argument, even for fixed custom names.
    # Suppress that one intentional upstream warning, not warnings in our own C code.
    xcrun clang -arch arm64 -mmacosx-version-min=27.0 -std=c11 -O2 -bundle \
      -framework CoreAudio -framework Accelerate -framework CoreFoundation \
      -DkNumber_Of_Channels=2 -DkHas_Driver_Name_Format=false \
      -Wno-format-extra-args \
      '-DkManufacturer_Name="Switchboard"' '-DkPlugIn_Icon="DeviceIcon.pdf"' \
      "-DkDriver_Name=\"${name}\"" "-DkDevice_Name=\"${display}\"" \
      "-DkPlugIn_BundleID=\"local.mouthinhands.${role}\"" \
      build/drivers/BlackHole.c -o "$bundle/Contents/MacOS/$name"
    python3 - "$bundle" "$name" "$role" "$factory" "$(cat VERSION)" <<'PY'
import pathlib,plistlib,sys
bundle,name,role,factory,version=sys.argv[1:]
p=plistlib.load(open('Vendor/BlackHole/BlackHole.plist','rb'))
p.update(CFBundleExecutable=name,CFBundleIdentifier='local.mouthinhands.'+role,
         CFBundleName=name,CFBundleShortVersionString=version,CFBundleVersion=version)
p['CFPlugInFactories']={factory:'BlackHole_Create'}
p['CFPlugInTypes']={'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]}
pathlib.Path(bundle,'Contents','Info.plist').write_bytes(plistlib.dumps(p))
PY
    python3 scripts/make-driver-icon.py "$bundle/Contents/Resources/DeviceIcon.pdf"
    cp Vendor/BlackHole/LICENSE "$bundle/Contents/Resources/LICENSE.txt"
    codesign --force --sign - "$bundle"
    codesign --verify --strict "$bundle"
}
build_driver Caller 'Phone → Agent' '76c2d727-6df9-414c-93f7-ce029155fd13'
build_driver Reply 'Chrome → Phone' '9c12242e-b672-448b-9279-6a4fd815a17b'
