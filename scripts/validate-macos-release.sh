#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/J.A.R.V.I.S.app}"
REQUIRE_DISTRIBUTION="${JARVIS_REQUIRE_DISTRIBUTION_SIGNATURE:-0}"
REQUIRE_NOTARIZATION="${JARVIS_REQUIRE_NOTARIZATION:-0}"
REQUIRE_PERSONAL="${JARVIS_REQUIRE_PERSONAL_SIGNATURE:-0}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  printf 'Application bundle not found: %s\n' "$APP_BUNDLE" >&2
  exit 1
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/JarvisApp"
GLASS_ORB_RESOURCES="$APP_BUNDLE/Contents/Resources/GlassVoiceOrbStudy"
if [[ ! -d "$GLASS_ORB_RESOURCES" ]]; then
  if [[ -d "$APP_BUNDLE/Contents/Resources/JarvisMac_JarvisApp.bundle/Contents/Resources/GlassVoiceOrbStudy" ]]; then
    GLASS_ORB_RESOURCES="$APP_BUNDLE/Contents/Resources/JarvisMac_JarvisApp.bundle/Contents/Resources/GlassVoiceOrbStudy"
  else
    GLASS_ORB_RESOURCES="$APP_BUNDLE/Contents/Resources/JarvisMac_JarvisApp.bundle/GlassVoiceOrbStudy"
  fi
fi

plutil -lint "$INFO_PLIST"
if [[ "${JARVIS_REQUIRE_UPDATER_CONFIGURATION:-0}" == "1" ]]; then
  python3 - "$INFO_PLIST" <<'PY'
import base64, plistlib, sys
from urllib.parse import urlparse
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
feed = urlparse(info.get('SUFeedURL', ''))
if feed.scheme != 'https' or not feed.netloc:
    raise SystemExit('An HTTPS Sparkle feed is required.')
if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
    raise SystemExit('A valid Ed25519 update public key is required.')
if not info.get('SUVerifyUpdateBeforeExtraction') or not info.get('SURequireSignedFeed'):
    raise SystemExit('Update archives and feeds must require signature verification.')
PY
fi
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  printf 'Sparkle.framework must be embedded in the application.\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$SPARKLE_FRAMEWORK"
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
  if [[ "$(plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw - <<<"$ENTITLEMENTS_XML" 2>/dev/null || true)" != "true" ]]; then
    printf 'Ad hoc builds must allow the embedded Sparkle framework to load.\n' >&2
    exit 1
  fi
  printf '✓ valid ad hoc signature with hardened runtime (personal build, not Apple notarized)\n'
else
  if [[ "$REQUIRE_PERSONAL" == "1" ]]; then
    printf 'Personal release validation requires an ad hoc signature.\n' >&2
    exit 1
  fi
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
