#!/bin/bash
# Build an unsigned TabloTV.ipa for the Apple TV. atvloadly on sanctarus
# re-signs it with the free Apple ID and keeps it refreshed on the TV; the
# GitHub workflow .github/workflows/tvos-ipa.yml runs this and publishes the
# result as a release that atvloadly tracks.
#   tvos/scripts/build-ipa.sh [output.ipa]   (default: tvos/build/TabloTV-tvos.ipa)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/TabloTV-tvos.ipa}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcodegen generate --quiet
xcodebuild -project TabloTV.xcodeproj -scheme TabloTV -configuration Release \
  -sdk appletvos -destination 'generic/platform=tvOS' -derivedDataPath "$WORK/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build -quiet
mkdir -p "$WORK/Payload"
cp -R "$WORK/dd/Build/Products/Release-appletvos/TabloTV.app" "$WORK/Payload/"
rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload)
echo "$OUT"
