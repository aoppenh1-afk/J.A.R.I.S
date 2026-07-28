#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="${JARVIS_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP_BUNDLE="${2:-$OUTPUT_ROOT/J.A.R.V.I.S.app}"
NOTARY_PROFILE="${JARVIS_NOTARY_PROFILE:-}"
SUBMISSION_ZIP="$OUTPUT_ROOT/J.A.R.V.I.S-notary-submission.zip"
DMG_PATH="$OUTPUT_ROOT/J.A.R.V.I.S-macos-arm64.dmg"

if [[ "${1:-}" != "--submit" ]]; then
  printf 'This command uploads artifacts to Apple. Re-run explicitly with --submit.\n' >&2
  printf 'Usage: JARVIS_NOTARY_PROFILE=<keychain-profile> %s --submit [app-path]\n' "$0" >&2
  exit 2
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  printf 'JARVIS_NOTARY_PROFILE must name a notarytool Keychain profile.\n' >&2
  exit 1
fi

JARVIS_REQUIRE_DISTRIBUTION_SIGNATURE=1 \
  "$PROJECT_ROOT/scripts/validate-macos-release.sh" "$APP_BUNDLE"

rm -f "$SUBMISSION_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

"$PROJECT_ROOT/scripts/make-release-artifacts.sh" "$APP_BUNDLE"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

JARVIS_REQUIRE_NOTARIZATION=1 \
  "$PROJECT_ROOT/scripts/validate-macos-release.sh" "$APP_BUNDLE"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

printf 'Notarized application: %s\n' "$APP_BUNDLE"
printf 'Notarized disk image: %s\n' "$DMG_PATH"
