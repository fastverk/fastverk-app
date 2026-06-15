#!/usr/bin/env bash
# Install the latest fastverk release into /Applications — no Apple
# Developer ID required.
#
#   gh repo clone fastverk/fastverk … then: bash tools/macos/install.sh
#   or:  curl -fsSL <raw-url>/tools/macos/install.sh | bash
#
# fastverk/fastverk is a private repo, so this uses the GitHub CLI (you
# must be a signed-in org member: `brew install gh && gh auth login`).
# `gh`-downloaded files carry no com.apple.quarantine attribute, so
# Gatekeeper won't block the (ad-hoc-signed) app. Once a Developer ID +
# notarization are in place, this script is unchanged — the app just stops
# triggering any Gatekeeper prompt at all.
set -euo pipefail

REPO="fastverk/fastverk"
APP="/Applications/fastverk.app"

command -v gh >/dev/null 2>&1 || {
    echo "fastverk: needs the GitHub CLI — 'brew install gh && gh auth login'" >&2
    exit 1
}

TMP="$(mktemp -d)"
MNT=""
cleanup() {
    [ -n "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "→ downloading the latest fastverk .dmg…"
gh release download --repo "$REPO" --pattern '*.dmg' --dir "$TMP" --clobber
DMG="$(ls "$TMP"/*.dmg | head -1)"

MNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -mountpoint "$MNT" >/dev/null
echo "→ installing $APP"
rm -rf "$APP"
cp -R "$MNT/fastverk.app" /Applications/
hdiutil detach "$MNT" >/dev/null
MNT=""

# Belt-and-suspenders (gh downloads aren't quarantined, but just in case).
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✓ installed $APP"
echo "  launch:        open -a fastverk        # a menu-bar icon appears"
echo "  run at login:  $APP/Contents/MacOS/fv service install"
