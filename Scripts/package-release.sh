#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
: "${WFOLDER_SIGNING_IDENTITY:?Set the Developer ID Application signing identity}"
: "${WFOLDER_NOTARY_PROFILE:?Set the notarytool Keychain profile}"
: "${WFOLDER_PRO_PUBLIC_KEY:?Set the public key for this commercial release}"
export WFOLDER_ARCHS="${WFOLDER_ARCHS:-arm64 x86_64}"

app="$(./Scripts/build-app.sh release)"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
tagged="wfolder-$version-macOS.zip"
stage="$(mktemp -d "$PWD/.build/release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

ditto -c -k --keepParent "$app" "$stage/notarize.zip"
xcrun notarytool submit "$stage/notarize.zip" --wait --keychain-profile "$WFOLDER_NOTARY_PROFILE"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict "$app"
spctl --assess --type execute "$app"

ditto -c -k --keepParent "$app" "$stage/$tagged"
(cd "$stage" && shasum -a 256 "$tagged" > "$tagged.sha256")
mv "$stage/$tagged" "$stage/$tagged.sha256" dist/
printf '%s\n' "$PWD/dist/$tagged" "$PWD/dist/$tagged.sha256"
