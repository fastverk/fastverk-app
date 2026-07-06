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

# Resolve the release tag. While unsigned we publish prereleases, which the
# GitHub "latest release" API excludes (so a no-tag download 404s). Take the
# newest release including prereleases; override with an explicit tag arg:
#   bash install.sh v0.0.2
TAG="${1:-$(gh release list --repo "$REPO" --exclude-drafts --limit 1 \
    --json tagName --jq '.[0].tagName')}"
[ -n "$TAG" ] || { echo "fastverk: no releases found in $REPO" >&2; exit 1; }

TMP="$(mktemp -d)"
MNT=""
cleanup() {
    [ -n "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "→ downloading the $TAG fastverk .dmg…"
gh release download "$TAG" --repo "$REPO" --pattern '*.dmg' --dir "$TMP" --clobber
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

# Put the `fv` product CLI on PATH for the quickstart (fv service / status).
# current_exe() resolves the symlink back into the bundle, so fv still finds
# its sibling fvd / cred-helper there.
mkdir -p "$HOME/.local/bin"
ln -sfn "$APP/Contents/MacOS/fv" "$HOME/.local/bin/fv"

echo "✓ installed $APP"
echo "  launch:        open -a fastverk        # a menu-bar icon appears"
echo "  run at login:  fv service install      # ~/.local/bin/fv (ensure it's on PATH)"
echo "  daemon status: fv status"
echo "  bazel dev env: install tbzl (github.com/tomato-bazel/tbzl), then \`tbzl bootstrap\`"
