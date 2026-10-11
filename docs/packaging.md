# macOS Packaging

## Build architecture

J.A.R.V.I.S. has two real native packaging paths:

- `archive-macos.sh` builds the `JarvisNativeApp` Xcode application target, creates an `.xcarchive`, and exports `J.A.R.V.I.S.app` for Xcode development or Developer ID distribution.
- `package-macos.sh` assembles the tested SwiftPM `JarvisApp` executable into the same application-bundle layout. GitHub releases use this path. It defaults to ad hoc signing for personal builds without an Apple developer membership; set `JARVIS_SIGNING_IDENTITY` to use a certificate.

`JarvisCore` and the vendored `ParakeetTDT` target remain Swift package products, so the Xcode application target and XCTest suite use the same implementation.

The Xcode project is generated from `apps/macos/project.yml` and committed for use on machines without XcodeGen:

```bash
./scripts/generate-xcode-project.sh
```

Regeneration requires `brew install xcodegen`; normal archive builds only require the generated project and Xcode.

## Local Apple Silicon archive

```bash
./scripts/validate-prerequisites.sh --all
./scripts/archive-macos.sh
./scripts/validate-installed-app.sh
```

Outputs:

```text
dist/J.A.R.V.I.S.xcarchive
dist/J.A.R.V.I.S.app
```

By default, `archive-macos.sh` uses the installed `Apple Development: senderopp@icloud.com (Y3GCC2VAB2)` certificate with development team `ZRU5DU22H4`. Set `JARVIS_DEVELOPMENT_SIGNING_IDENTITY` or `JARVIS_DEVELOPMENT_TEAM` to override those local development-signing values.

Packaging and archive validation do not launch the app, request microphone access, start Hermes, run Parakeet inference, or call Deepgram.

## Bundle metadata and capabilities

`apps/macos/Packaging/Info.plist` declares:

- `APPL` bundle type and the `JarvisApp` executable.
- Menu-bar-only behavior through `LSUIElement`.
- Utilities application category.
- macOS 14 as the minimum system version.
- A push-to-talk-specific microphone usage description.
- Build-setting-driven version, build, and bundle identifier values.

`apps/macos/Packaging/Jarvis.entitlements` contains only audio-input and outbound-network capabilities. Hardened runtime is enabled in the Xcode target and every signing command. Release validation extracts the signed entitlements and verifies both required values.

Ad hoc packaging uses `JarvisPersonal.entitlements`, which also disables hardened-runtime library validation so the embedded Sparkle framework can load without an Apple Team ID. Certificate-signed builds keep the original entitlements. See [updates.md](updates.md) for personal releases and initial macOS approval.

## Pinned Parakeet source and external model

The small Swift runtime is vendored under `apps/macos/Vendor/ParakeetTDT` at source snapshot `f71daf2dbcccf88aed2d49fdb308e50fba643389`. Its Apache-2.0 license and provenance are retained with the source. Clean builds no longer require a package under the developer's Downloads directory.

Core ML model weights remain external and are never copied into the app or release artifacts. Both the app and prerequisite script verify all encoder, decoder, joint, tokenizer, and weight files under the configured/default cache:

```text
~/Library/Caches/com.parakeet-tdt/hf-models/mweinbach1_parakeet-tdt-0.6b-v3-coreml
```

Hermes also remains external. The packaged runtime searches:

```text
~/.local/bin/hermes
/opt/homebrew/bin/hermes
/usr/local/bin/hermes
```

`JARVIS_HERMES_EXECUTABLE` remains a development override. Use `./scripts/validate-prerequisites.sh --runtime` to check Hermes and the model cache without launching either one.

## Developer ID archive and export

Release values are supplied through the environment and are never stored in source control:

```bash
export JARVIS_BUNDLE_IDENTIFIER="com.example.jarvis"
export JARVIS_MARKETING_VERSION="1.0.0"
export JARVIS_BUILD_NUMBER="1"
export JARVIS_DEVELOPMENT_TEAM="TEAMID"
export JARVIS_SIGNING_IDENTITY="Developer ID Application: Example Corp (TEAMID)"

./scripts/archive-macos.sh
JARVIS_REQUIRE_DISTRIBUTION_SIGNATURE=1 \
  ./scripts/validate-macos-release.sh dist/J.A.R.V.I.S.app
./scripts/validate-installed-app.sh dist/J.A.R.V.I.S.app
```

When both signing values are present, the archive uses manual Developer ID signing and `xcodebuild -exportArchive` with a temporary `developer-id` export options plist. The temporary plist is deleted automatically.

## ZIP and DMG

After Developer ID validation:

```bash
./scripts/make-release-artifacts.sh dist/J.A.R.V.I.S.app
```

This creates:

```text
dist/J.A.R.V.I.S-macos-arm64.zip
dist/J.A.R.V.I.S-macos-arm64.dmg
```

The script requires Developer ID signatures by default and never uploads anything. For a personal build, opt into ad hoc validation explicitly:

```bash
JARVIS_RELEASE_MODE=personal ./scripts/make-release-artifacts.sh dist/J.A.R.V.I.S.app
```

The personal mode requires an ad hoc signature and the entitlement needed to load Sparkle. These builds are not Apple notarized.

## Explicit notarization and stapling

Store notarization credentials in a notarytool Keychain profile:

```bash
xcrun notarytool store-credentials JARVIS_NOTARY
```

The notarization pipeline has a hard `--submit` guard because it uploads to Apple. It submits a ZIP of the signed app, staples the app, rebuilds artifacts, submits and staples the DMG, and runs Gatekeeper/notary validation:

```bash
JARVIS_NOTARY_PROFILE="JARVIS_NOTARY" \
  ./scripts/notarize-macos.sh --submit dist/J.A.R.V.I.S.app
```

No notarization, upload, or publication occurs unless this explicit command is invoked. Never put App Store Connect credentials, API keys, certificates, or notary profiles in source control.

## Installed and clean-account validation

Static installed-bundle validation checks:

- Resolved bundle identity and arm64 executable.
- Signature integrity, hardened runtime, and signed entitlements.
- No dynamic load commands referencing Downloads, `.build`, DerivedData, or the project directory.
- No bundled model weights, Hermes copy, Python, Node, or unexpected helper executable.
- Links to Security, ServiceManagement, Carbon, AVFoundation, and CoreML.

For an app copied to `/Applications`, require the installed location with:

```bash
JARVIS_REQUIRE_APPLICATIONS_INSTALL=1 \
  ./scripts/validate-installed-app.sh /Applications/J.A.R.V.I.S.app
```

A clean macOS account must still physically verify behavior that scripts cannot safely simulate:

- Gatekeeper launch from the notarized DMG.
- Microphone permission attributed to J.A.R.V.I.S.
- Global push-to-talk from other apps and Spaces.
- Keychain credential persistence across an application update.
- Launch-at-login across logout/login.
- Sleep/wake and audio-device recovery without stale replay.
- Actionable missing-Hermes and missing-model behavior.
