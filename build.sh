#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle="./Room Audio.app"
signing_identity="${ROOM_AUDIO_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -p codesigning | awk '/"Room Audio Local Signing"/ {print $2; exit}')
    signing_identity="${signing_identity:--}"
fi
transport="${ROOM_AUDIO_TRANSPORT:-../../work/airplay-preflight/cliairplay}"
if [ ! -f "$transport" ]; then
    download=$(mktemp -d)
    trap 'rm -f "$download/cliairplay"; rmdir "$download"' EXIT
    transport="$download/cliairplay"
    curl -fsSL 'https://github.com/music-assistant/airplay-cli/releases/download/v0.5.17/cliairplay-macos-arm64' -o "$transport"
fi
actual=$(shasum -a 256 "$transport")
[ "${actual%% *}" = 'de19cc204837640301061a088459ed72e2aa10a352c9040f9e26f9dbb10f7c3a' ]
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library RoomAudio.swift Streaming.swift AppAudio.swift LocalOutput.swift Routing.swift SourcePicker.swift SavedGroups.swift -o "$bundle/Contents/MacOS/RoomAudio"
swiftc -swift-version 6 -warnings-as-errors PTPService.swift -o "$bundle/Contents/Resources/PTPService"
cp "$transport" "$bundle/Contents/Resources/cliairplay"
chmod 755 "$bundle/Contents/Resources/cliairplay"
cp stream.py "$bundle/Contents/Resources/stream.py"
cp Info.plist "$bundle/Contents/Info.plist"
codesign --force --timestamp=none --sign "$signing_identity" "$bundle"
codesign --verify --strict "$bundle"
