#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
project="$PWD"
output_dir="${WFOLDER_APP_OUTPUT_DIR:-$project/dist}"
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
flags=(-g -Onone -whole-module-optimization)
if [[ "$configuration" == release ]]; then flags=(-O -whole-module-optimization); fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset" "$output_dir"
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
read -r -a architectures <<< "${WFOLDER_ARCHS:-$(uname -m)}"
binaries=()
for arch in "${architectures[@]}"; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 2 ;; esac
    binary="$stage/PerchFiles-$arch"
    xcrun swiftc -sdk "$sdk" -target "$arch-apple-macosx14.0" \
        -swift-version 5 -parse-as-library -module-name PerchFiles "${flags[@]}" \
        -I Sources/CArchive Sources/PerchFiles/*.swift -o "$binary"
    binaries+=("$binary")
done
if [[ ${#binaries[@]} == 1 ]]; then
    mv "${binaries[0]}" "$app/Contents/MacOS/PerchFiles"
else
    xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/PerchFiles"
fi
plist="$app/Contents/Info.plist"
install -m 0644 Scripts/Info.plist "$plist"
if [[ -n "${WFOLDER_PRO_PUBLIC_KEY:-}" ]]; then
    key_bytes="$(printf '%s' "$WFOLDER_PRO_PUBLIC_KEY" | base64 -D | wc -c | tr -d '[:space:]')"
    [[ "$key_bytes" == 32 ]] || { echo "Invalid wfolder Pro public key" >&2; exit 2; }
    plutil -insert WFolderProPublicKey -string "$WFOLDER_PRO_PUBLIC_KEY" "$plist"
fi
if [[ -n "${WFOLDER_PRO_CHECKOUT_URL:-}" ]]; then
    case "$WFOLDER_PRO_CHECKOUT_URL" in
        https://*) plutil -insert WFolderProCheckoutURL -string "$WFOLDER_PRO_CHECKOUT_URL" "$plist" ;;
        *) echo "The checkout URL must use HTTPS" >&2; exit 2 ;;
    esac
fi
if [[ -n "${WFOLDER_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$WFOLDER_SIGNING_IDENTITY" "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

target="$output_dir/$bundle_name"
previous="$stage/previous.app"
if [[ -e "$target" ]]; then mv "$target" "$previous"; fi
if ! mv "$app" "$target"; then
    if [[ -e "$previous" ]]; then mv "$previous" "$target"; fi
    exit 1
fi
codesign --verify --strict "$target"
printf '%s\n' "$target"
