#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_ROOT="$PROJECT_ROOT/apps/macos"
PROJECT_PATH="$MACOS_ROOT/JarvisMac.xcodeproj"
OUTPUT_ROOT="${JARVIS_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
ARCHIVE_PATH="${JARVIS_ARCHIVE_PATH:-$OUTPUT_ROOT/J.A.R.V.I.S.xcarchive}"
EXPORTED_APP="$OUTPUT_ROOT/J.A.R.V.I.S.app"
EXPORT_PATH="$OUTPUT_ROOT/export"
BUNDLE_IDENTIFIER="${JARVIS_BUNDLE_IDENTIFIER:-com.jarvis.voice-assistant}"
MARKETING_VERSION="${JARVIS_MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${JARVIS_BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${JARVIS_SIGNING_IDENTITY:-}"
DEVELOPMENT_SIGNING_IDENTITY="${JARVIS_DEVELOPMENT_SIGNING_IDENTITY:-Apple Development: senderopp@icloud.com (Y3GCC2VAB2)}"
DEVELOPMENT_TEAM="${JARVIS_DEVELOPMENT_TEAM:-ZRU5DU22H4}"
ENTITLEMENTS="$MACOS_ROOT/Packaging/Jarvis.entitlements"

"$PROJECT_ROOT/scripts/validate-prerequisites.sh" --build

if command -v xcodegen >/dev/null 2>&1; then
  "$PROJECT_ROOT/scripts/generate-xcode-project.sh"
elif [[ ! -d "$PROJECT_PATH" ]]; then
  printf 'The generated Xcode project is missing and XcodeGen is unavailable.\n' >&2
  exit 1
fi

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$EXPORTED_APP"
mkdir -p "$OUTPUT_ROOT"

COMMON_BUILD_SETTINGS=(
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_IDENTIFIER"
  "MARKETING_VERSION=$MARKETING_VERSION"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
)

if [[ -z "$SIGNING_IDENTITY" ]]; then
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme JarvisNativeApp \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    "CODE_SIGN_IDENTITY=$DEVELOPMENT_SIGNING_IDENTITY" \
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" \
    "${COMMON_BUILD_SETTINGS[@]}" \
    archive

  ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/J.A.R.V.I.S.app"
  ditto "$ARCHIVED_APP" "$EXPORTED_APP"
else
  if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    printf 'JARVIS_DEVELOPMENT_TEAM is required with JARVIS_SIGNING_IDENTITY.\n' >&2
    exit 1
  fi

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme JarvisNativeApp \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" \
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" \
    "${COMMON_BUILD_SETTINGS[@]}" \
    archive

  EXPORT_OPTIONS="$(mktemp "${TMPDIR:-/tmp}/jarvis-export.XXXXXX.plist")"
  trap 'rm -f "$EXPORT_OPTIONS"' EXIT
  cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
    <key>signingCertificate</key>
    <string>$SIGNING_IDENTITY</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
EOF

  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

  EXPORTED_CANDIDATE="$(find "$EXPORT_PATH" -maxdepth 1 -type d -name '*.app' -print -quit)"
  if [[ -z "$EXPORTED_CANDIDATE" ]]; then
    printf 'Xcode did not export an application bundle.\n' >&2
    exit 1
  fi
  ditto "$EXPORTED_CANDIDATE" "$EXPORTED_APP"
fi

"$PROJECT_ROOT/scripts/validate-macos-release.sh" "$EXPORTED_APP"
printf '\nArchive: %s\n' "$ARCHIVE_PATH"
printf 'Application: %s\n' "$EXPORTED_APP"
