#!/usr/bin/env bash
# Build iTex (macOS, Release) and install to /Applications with a STABLE code signature.
#
# Why stable signing: Xcode's default "Sign to Run Locally" is ad-hoc — its cdhash changes
# every build, so macOS invalidates the app's recent-documents SharedFileList on each
# replace and the Recent list vanishes. We build as usual, then re-sign the installed app
# with the Developer ID cert (no provisioning profile needed, works offline). That gives a
# stable designated requirement, so recents (and other LaunchServices state) survive rebuilds.
#
# Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="iTex-macOS"
IDENTITY="Developer ID Application: YongKyu Lee (488U7L9D53)"
DERIVED="/tmp/iTex-release-build"   # outside the source tree (16 GB Mac: no in-tree build churn)
APP="$DERIVED/Build/Products/Release/iTex.app"
DEST="/Applications/iTex.app"

echo "▸ Building $SCHEME (Release)…"
xcodebuild build \
  -project iTex.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  | tail -2

echo "▸ Installing to ${DEST}"
rm -rf "${DEST}"
cp -R "$APP" "${DEST}"

echo "▸ Re-signing with stable identity: $IDENTITY"
codesign --force --deep --preserve-metadata=entitlements \
  --sign "$IDENTITY" "${DEST}"

echo "▸ Signature:"
codesign -dvv "${DEST}" 2>&1 | grep -E "Authority=|TeamIdentifier|Signature" || true
echo "✓ Done: ${DEST}"
