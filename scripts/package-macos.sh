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
SIGNING_IDENTITY="${JARVIS_SIGNING_IDENTITY:--}"
ENTITLEMENTS="$PACKAGING_ROOT/Jarvis.entitlements"
INFO_PLIST="$PACKAGING_ROOT/Info.plist"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  # Ad hoc signatures have no Team ID for hardened-runtime library validation.
  # Allow the embedded Sparkle framework to load in personal builds.
  ENTITLEMENTS="$PACKAGING_ROOT/JarvisPersonal.entitlements"
fi

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
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
install -m 755 "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/JarvisApp"
# Older SwiftPM versions can add a build-directory framework search path.
# The packaged app resolves Sparkle exclusively from its embedded Frameworks folder.
python3 - "$APP_BUNDLE/Contents/MacOS/JarvisApp" "$PROJECT_ROOT" <<'PY'
import re, subprocess, sys
binary, project = sys.argv[1:]
commands = subprocess.check_output(['otool', '-l', binary], text=True)
for path in re.findall(r'\n\s*path (.*?) \(offset \d+\)', commands):
    if project in path or any(part in path for part in ('/.build/', '/DerivedData/', '/Downloads/')):
        subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
PY
ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
SPARKLE_FRAMEWORK="$BIN_PATH/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  SPARKLE_FRAMEWORK="$(find "$PACKAGE_ROOT/.build/artifacts" -type d -name Sparkle.framework -print -quit)"
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  printf 'Sparkle.framework was not produced.\n' >&2
  exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
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
# Sign Sparkle's nested code inside-out, using the same identity as the app.
FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
NESTED_SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --options runtime "--preserve-metadata=identifier,entitlements")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  NESTED_SIGN_ARGS+=(--timestamp=none)
else
  NESTED_SIGN_ARGS+=(--timestamp)
fi
while IFS= read -r nested; do
  if file "$nested" | grep -q 'Mach-O'; then
    codesign "${NESTED_SIGN_ARGS[@]}" "$nested"
  fi
done < <(find "$FRAMEWORK" -type f -perm -111)
while IFS= read -r nested; do
  codesign "${NESTED_SIGN_ARGS[@]}" "$nested"
done < <(find "$FRAMEWORK" -depth -type d \( -name '*.xpc' -o -name '*.app' \))
codesign "${NESTED_SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

printf '\nPackaged %s\n' "$APP_BUNDLE"
printf 'Bundle identifier: %s\n' "$BUNDLE_IDENTIFIER"
printf 'Version: %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  printf 'Signature: ad hoc (personal build, not Apple notarized)\n'
else
  printf 'Signature: %s\n' "$SIGNING_IDENTITY"
fi
