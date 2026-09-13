#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh release
stage="$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R build/Switchboard.app "$stage/"
ln -s /Applications "$stage/Applications"
cp docs/LOCAL-INSTALL.md "$stage/Read Me.txt"
cp -R build/Switchboard.app/Contents/Resources/Licenses "$stage/"
hdiutil create -volname "Switchboard" -srcfolder "$stage" -ov -format UDZO build/Switchboard.dmg
hdiutil verify build/Switchboard.dmg
