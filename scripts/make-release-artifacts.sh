#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="${JARVIS_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP_BUNDLE="${1:-$OUTPUT_ROOT/J.A.R.V.I.S.app}"
APP_NAME="$(basename "$APP_BUNDLE" .app)"
ZIP_PATH="$OUTPUT_ROOT/$APP_NAME-macos-arm64.zip"
DMG_PATH="$OUTPUT_ROOT/$APP_NAME-macos-arm64.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

JARVIS_REQUIRE_DISTRIBUTION_SIGNATURE=1 \
  "$PROJECT_ROOT/scripts/validate-macos-release.sh" "$APP_BUNDLE"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

printf 'Created %s\n' "$ZIP_PATH"
printf 'Created %s\n' "$DMG_PATH"
printf 'Artifacts are local only; notarization/upload is never performed by this script.\n'
