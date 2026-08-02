#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/J.A.R.V.I.S.app}"
REQUIRE_DISTRIBUTION="${JARVIS_REQUIRE_DISTRIBUTION_SIGNATURE:-0}"
REQUIRE_NOTARIZATION="${JARVIS_REQUIRE_NOTARIZATION:-0}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  printf 'Application bundle not found: %s\n' "$APP_BUNDLE" >&2
  exit 1
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/JarvisApp"
GLASS_ORB_RESOURCES="$APP_BUNDLE/Contents/Resources/GlassVoiceOrbStudy"

plutil -lint "$INFO_PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO_PLIST")" = "true"
/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$INFO_PLIST" >/dev/null

if [[ ! -x "$EXECUTABLE" ]]; then
  printf 'Bundle executable is missing or not executable: %s\n' "$EXECUTABLE" >&2
  exit 1
fi

for resource in embed.html bridge.js src/renderer.js src/state.js shader-sources.js; do
  if [[ ! -f "$GLASS_ORB_RESOURCES/$resource" ]]; then
    printf 'Bundled Glass Voice Orb resource is missing: %s\n' "$GLASS_ORB_RESOURCES/$resource" >&2
    exit 1
  fi
done

ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  printf 'Expected arm64-only executable, found: %s\n' "$ARCHITECTURES" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
ENTITLEMENTS_XML="$(codesign --display --entitlements - --xml "$APP_BUNDLE" 2>/dev/null)"
for entitlement in \
  'com\.apple\.security\.device\.audio-input' \
  'com\.apple\.security\.network\.client'; do
  if [[ "$(plutil -extract "$entitlement" raw - <<<"$ENTITLEMENTS_XML")" != "true" ]]; then
    printf 'Required signed entitlement is missing: %s\n' "$entitlement" >&2
    exit 1
  fi
done

SIGNING_SUMMARY="$(codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)"
if ! grep -q 'flags=.*runtime' <<<"$SIGNING_SUMMARY"; then
  printf 'The hardened runtime is not enabled on the app signature.\n' >&2
  exit 1
fi

if grep -q '^Signature=adhoc$' <<<"$SIGNING_SUMMARY"; then
  if [[ "$REQUIRE_DISTRIBUTION" == "1" || "$REQUIRE_NOTARIZATION" == "1" ]]; then
    printf 'A Developer ID Application signature is required for distribution.\n' >&2
    exit 1
  fi
  printf '✓ valid ad hoc signature with hardened runtime (local validation only)\n'
else
  if [[ "$REQUIRE_DISTRIBUTION" == "1" ]] && ! grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_SUMMARY"; then
    printf 'A Developer ID Application signature is required for distribution.\n' >&2
    exit 1
  fi
  printf '✓ non-ad-hoc code signature with hardened runtime\n'
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  printf '✓ Gatekeeper assessment and stapled notarization ticket validated\n'
fi

printf '✓ Info.plist, arm64 executable, entitlements, and signature validated\n'
