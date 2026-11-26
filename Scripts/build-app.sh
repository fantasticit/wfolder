#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
project="$PWD"
configuration="${1:-release}"
case "$configuration" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

sdk="$(xcrun --sdk macosx --show-sdk-path)"
version="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${version%%.*} < 27 )); then
    echo "Building the native Liquid Glass interface requires the macOS 27 SDK or newer." >&2
    exit 2
fi
export SDKROOT="$sdk"

mkdir -p "$project/.build"
stage="$(mktemp -d "$project/.build/app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle_name="$(plutil -extract CFBundleName raw Scripts/Info.plist).app"
app="$stage/$bundle_name"
iconset="$stage/Perch.iconset"
flags=(-g -Onone)
if [[ "$configuration" == release ]]; then flags=(-O -whole-module-optimization); fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset" "$project/dist"
ditto Scripts/Templates "$app/Contents/Resources/Templates"
ditto Sources/PerchFiles/Resources/Markdown "$app/Contents/Resources/Markdown"
xcrun swift Scripts/MakeIcon.swift "$stage/Perch.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/Perch.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    high_density="$((size * 2))"
    sips -z "$high_density" "$high_density" "$stage/Perch.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
icon_name="$(plutil -extract CFBundleIconFile raw Scripts/Info.plist)"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/$icon_name"
xcrun swiftc -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" \
    -swift-version 5 -parse-as-library -module-name PerchFiles "${flags[@]}" \
    -I Sources/CArchive Sources/PerchFiles/*.swift -o "$app/Contents/MacOS/PerchFiles"
install -m 0644 Scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

target="$project/dist/$bundle_name"
previous="$stage/previous.app"
if [[ -e "$target" ]]; then mv "$target" "$previous"; fi
if ! mv "$app" "$target"; then
    if [[ -e "$previous" ]]; then mv "$previous" "$target"; fi
    exit 1
fi
codesign --verify --strict "$target"
printf '%s\n' "$target"
