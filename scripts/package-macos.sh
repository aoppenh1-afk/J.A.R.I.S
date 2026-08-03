#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="$PROJECT_ROOT/apps/macos"
PACKAGING_ROOT="$PACKAGE_ROOT/Packaging"
OUTPUT_ROOT="${JARVIS_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP_NAME="${JARVIS_APP_NAME:-J.A.R.V.I.S}"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"
BUNDLE_IDENTIFIER="${JARVIS_BUNDLE_IDENTIFIER:-com.jarvis.voice-assistant}"
MARKETING_VERSION="${JARVIS_MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${JARVIS_BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${JARVIS_SIGNING_IDENTITY:-Apple Development: senderopp@icloud.com (Y3GCC2VAB2)}"
ENTITLEMENTS="$PACKAGING_ROOT/Jarvis.entitlements"
INFO_PLIST="$PACKAGING_ROOT/Info.plist"

"$PROJECT_ROOT/scripts/validate-prerequisites.sh" --build

swift build \
  --configuration release \
  --arch arm64 \
  --product JarvisApp \
  --package-path "$PACKAGE_ROOT"

BIN_PATH="$(swift build --configuration release --arch arm64 --show-bin-path --package-path "$PACKAGE_ROOT")"
EXECUTABLE="$BIN_PATH/JarvisApp"
RESOURCE_BUNDLE="$BIN_PATH/JarvisMac_JarvisApp.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
  printf 'Release executable was not produced: %s\n' "$EXECUTABLE" >&2
  exit 1
fi
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  printf 'Release resource bundle was not produced: %s\n' "$RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
install -m 755 "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/JarvisApp"
ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
install -m 644 "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

ARCHITECTURES="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/JarvisApp")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  printf 'Expected an arm64-only executable, found: %s\n' "$ARCHITECTURES" >&2
  exit 1
fi

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

printf '\nPackaged %s\n' "$APP_BUNDLE"
printf 'Bundle identifier: %s\n' "$BUNDLE_IDENTIFIER"
printf 'Version: %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  printf 'Signature: ad hoc (local validation only)\n'
else
  printf 'Signature: %s\n' "$SIGNING_IDENTITY"
fi
