#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in
    release|debug) ;;
    *) printf 'Usage: %s [release|debug]\n' "$0" >&2; exit 2 ;;
esac
version="${SWITCHBOARD_BUILD_VERSION:-$(cat VERSION)}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid VERSION\n' >&2; exit 2; }
python3 scripts/compile-localizations.py
bash scripts/swift.sh build -c "$configuration"
bash scripts/build-drivers.sh
xcrun swift -module-cache-path .build/clang-cache scripts/generate-app-icon.swift build/Switchboard.iconset
iconutil -c icns build/Switchboard.iconset -o build/Switchboard.icns
xcrun swiftc -swift-version 6 -parse-as-library -O -target arm64-apple-macosx26.0 \
  -module-cache-path .build/clang-cache Installer/Installer.swift -o build/InstallerTool
app="build/Switchboard.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Drivers"
mkdir -p "$app/Contents/Resources/Licenses/Vendor/BlackHole"
cp -R build/Localizations/en.lproj build/Localizations/ko.lproj "$app/Contents/Resources/"
cp LICENSE NOTICE.md "$app/Contents/Resources/Licenses/"
cp Vendor/BlackHole/LICENSE "$app/Contents/Resources/Licenses/Vendor/BlackHole/"
cp build/Switchboard.icns "$app/Contents/Resources/"
cp ".build/arm64-apple-macosx/$configuration/Switchboard" "$app/Contents/MacOS/Switchboard"
cp build/InstallerTool "$app/Contents/Resources/InstallerTool"
cp -R build/drivers/MIHCaller.driver build/drivers/MIHReply.driver \
  build/drivers/SwitchboardAgent.driver "$app/Contents/Resources/Drivers/"
python3 - "$app" "$configuration" "$version" <<'PY'
import hashlib,pathlib,plistlib,sys,json
app=pathlib.Path(sys.argv[1])
p={'CFBundleIdentifier':'com.switchboard.main','CFBundleExecutable':'Switchboard',
   'CFBundleName':'Switchboard','CFBundleDisplayName':'Switchboard','CFBundlePackageType':'APPL',
   'CFBundleShortVersionString':sys.argv[3],'CFBundleVersion':sys.argv[3],'LSMinimumSystemVersion':'26.0',
   'CFBundleIconFile':'Switchboard.icns',
   'NSHighResolutionCapable':True,'SwitchboardPreview':sys.argv[2]=='debug',
   'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ko'],
   'NSMicrophoneUsageDescription':'Switchboard receives audio from the selected caller through a virtual device for relay, monitoring, recording, and transcription.',
   'NSAudioCaptureUsageDescription':'Switchboard captures audio only from the selected Agent application for relay, monitoring, recording, and transcription.',
   'NSAppleEventsUsageDescription':'Switchboard requests administrator approval to install its audio drivers.',
   'UTExportedTypeDeclarations':[
       {'UTTypeIdentifier':'com.switchboard.main.session','UTTypeDescription':'Switchboard Session',
        'UTTypeConformsTo':['public.directory','com.apple.package'],
        'UTTypeTagSpecification':{'public.filename-extension':['switchboard']}},
       {'UTTypeIdentifier':'com.switchboard.main.recording','UTTypeDescription':'Switchboard Recording',
        'UTTypeConformsTo':['public.directory','com.apple.package'],
        'UTTypeTagSpecification':{'public.filename-extension':['mihrecording']}}],
   'CFBundleDocumentTypes':[
       {'CFBundleTypeName':'Switchboard Session','CFBundleTypeRole':'Editor','LSHandlerRank':'Owner',
        'LSTypeIsPackage':True,'LSItemContentTypes':['com.switchboard.main.session']},
       {'CFBundleTypeName':'Switchboard Recording','CFBundleTypeRole':'Viewer','LSHandlerRank':'Owner',
        'LSTypeIsPackage':True,'LSItemContentTypes':['com.switchboard.main.recording']}]}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(p))
drivers=app/'Contents/Resources/Drivers'
hashes={str(f.relative_to(drivers)):hashlib.sha256(f.read_bytes()).hexdigest()
        for b in ['MIHCaller.driver','MIHReply.driver','SwitchboardAgent.driver']
        for f in (drivers/b).rglob('*') if f.is_file()}
(drivers/'hashes.json').write_text(json.dumps(hashes,sort_keys=True,indent=2))
PY
codesign --force --sign - "$app/Contents/Resources/InstallerTool"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$PWD/$app"
