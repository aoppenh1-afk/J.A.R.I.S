#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/J.A.R.V.I.S.app}"
REQUIRE_APPLICATIONS="${JARVIS_REQUIRE_APPLICATIONS_INSTALL:-0}"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/JarvisApp"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

"$PROJECT_ROOT/scripts/validate-macos-release.sh" "$APP_BUNDLE"

if [[ "$REQUIRE_APPLICATIONS" == "1" && "$APP_BUNDLE" != /Applications/*.app ]]; then
  printf 'Installed validation requires an application under /Applications.\n' >&2
  exit 1
fi

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if [[ -z "$BUNDLE_IDENTIFIER" || "$BUNDLE_IDENTIFIER" == *'$('* ]]; then
  printf 'The application has an unresolved bundle identifier: %s\n' "$BUNDLE_IDENTIFIER" >&2
  exit 1
fi

DEPENDENCIES="$(otool -L "$EXECUTABLE" | grep '^[[:space:]]')"
RPATHS="$(otool -l "$EXECUTABLE" | grep -A2 LC_RPATH | grep ' path ' || true)"
if grep -E -q "${PROJECT_ROOT//\//\\/}|/Downloads/|/\.build/|/DerivedData/" <<<"$DEPENDENCIES$RPATHS"; then
  printf 'The executable contains a development-path load command.\n' >&2
  exit 1
fi

for framework in Security ServiceManagement Carbon AVFoundation CoreML; do
  if ! grep -q "$framework" <<<"$DEPENDENCIES"; then
    printf 'Expected system framework is not linked: %s\n' "$framework" >&2
    exit 1
  fi
done

if find "$APP_BUNDLE/Contents" -type d \( -name '*.mlpackage' -o -name '*.mlmodelc' \) -print -quit | grep -q .; then
  printf 'Core ML model weights must remain external to the application bundle.\n' >&2
  exit 1
fi

if find "$APP_BUNDLE/Contents" -type f \( -name hermes -o -name python -o -name python3 -o -name node \) -print -quit | grep -q .; then
  printf 'The application bundle contains a prohibited background runtime or Hermes copy.\n' >&2
  exit 1
fi

if find "$APP_BUNDLE/Contents" -type f -perm -111 ! -path "$EXECUTABLE" -print -quit | grep -q .; then
  printf 'Unexpected nested executable found in the application bundle.\n' >&2
  exit 1
fi

printf '✓ bundle identity is resolved: %s\n' "$BUNDLE_IDENTIFIER"
printf '✓ no development-path dynamic dependency was found\n'
printf '✓ no model weights, Hermes copy, language runtime, or helper executable is bundled\n'
printf '✓ required Keychain, launch-at-login, hotkey, audio, and Core ML frameworks are linked\n'
printf '\nPhysical checks still required on the installed signed build:\n'
printf '  - Microphone permission is attributed to J.A.R.V.I.S.\n'
printf '  - Global push-to-talk works from another app and Space.\n'
printf '  - Launch at login survives logout/login.\n'
printf '  - Keychain credentials survive an application update.\n'
printf '  - Sleep/wake and audio-device recovery complete without replay.\n'
