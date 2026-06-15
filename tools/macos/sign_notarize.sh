#!/usr/bin/env bash
# Sign (Developer ID + hardened runtime), notarize, and staple a fastverk
# .app, then package it into a signed .dmg. Used by release.yml and runnable
# locally (same path) — see the local verification in the project notes.
#
# Usage:
#   sign_notarize.sh <app_path> <dmg_out> <identity> <notarytool-auth...>
# where <notarytool-auth...> is passed verbatim to `notarytool submit`, e.g.
#   --keychain-profile fastverk-notary
#   --key /path/AuthKey.p8 --key-id <id> --issuer <id>
#
# The .app (extracted + run by install.sh) is notarized AND stapled, so it
# launches with zero Gatekeeper friction even offline / when copied out of
# the dmg. The dmg is Developer ID-signed (mounting isn't notarization-gated).
set -euo pipefail

APP="$1"; DMG_OUT="$2"; IDENTITY="$3"; shift 3
NOTARY=("$@")
ENT="$(cd "$(dirname "$0")" && pwd)/entitlements.plist"

echo "→ signing $APP (Developer ID + hardened runtime)"
# Inner Mach-O binaries first, then the bundle (inside-out).
while IFS= read -r bin; do
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY" "$bin"
done < <(find "$APP/Contents/MacOS" -type f)
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "→ notarizing the app"
ZIP="$(mktemp -d)/app.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"

echo "→ packaging + signing the dmg"
rm -f "$DMG_OUT"
hdiutil create -volname fastverk -srcfolder "$APP" -ov -quiet -format UDZO "$DMG_OUT"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_OUT"

echo "→ Gatekeeper assessment"
spctl -a -vvv "$APP"
echo "✓ signed + notarized + stapled: $DMG_OUT"
