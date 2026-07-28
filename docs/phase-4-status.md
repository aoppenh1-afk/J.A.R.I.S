# Phase 4 Status

## Implementation complete

- Added the native `JarvisNativeApp` Xcode application target with a shared Release archive scheme.
- Added `apps/macos/project.yml` as the maintainable XcodeGen source and committed the generated `JarvisMac.xcodeproj` for machines without XcodeGen.
- The application target links the existing `JarvisCore` Swift package product rather than duplicating core implementation.
- Added a reproducible arm64 `.xcarchive` and app-export pipeline through `archive-macos.sh`.
- Preserved the faster SwiftPM application-bundle path for focused local packaging.
- Added bundle metadata for menu-bar behavior, utilities category, macOS 14, version/build identifiers, and microphone privacy disclosure.
- Added minimal signed audio-input and outbound-network entitlements and hardened runtime in Xcode and script signing paths.
- Vendored the small Parakeet Swift runtime at pinned source snapshot `f71daf2dbcccf88aed2d49fdb308e50fba643389`, including license and provenance.
- Removed the release build dependency on a developer-specific Downloads path.
- Kept all Core ML weights external to the application and release artifacts.
- Added complete model-cache validation in both `JarvisCore` and packaging prerequisite checks.
- Kept Hermes as an external prerequisite and validated the stable executable locations supported by the packaged runtime.
- Added Developer ID archive/export inputs without storing identity or team values in source control.
- Added guarded ZIP/DMG generation that rejects ad hoc signatures.
- Added an explicit `--submit` notarization pipeline for app submission, app stapling, artifact regeneration, DMG submission/stapling, Gatekeeper assessment, and ticket validation.
- Added installed-bundle validation for resolved identity, arm64 architecture, signed entitlements, hardened runtime, development-path dynamic dependencies, unexpected executables, model weights, language runtimes, and required system frameworks.
- Added `dist/` to ignored generated artifacts.

## Automated verification

- 49 XCTest tests pass with 0 failures, including complete/incomplete Parakeet model-cache validation.
- The Xcode project generates successfully.
- `xcodebuild` resolves the local package and recognizes the `JarvisNativeApp` archive scheme.
- A Release arm64 archive succeeds and produces `dist/J.A.R.V.I.S.xcarchive`.
- The archived app exports to `dist/J.A.R.V.I.S.app` and passes ad hoc hardened-runtime signing validation.
- `plutil`, `lipo`, signed-entitlement extraction, and `codesign --verify --deep --strict` pass.
- Installed-bundle checks find no development-path load commands, model weights, Hermes copy, Python/Node runtime, or unexpected helper executable.
- The notarization script refuses to upload unless `--submit` is explicitly supplied.
- The local machine has an Apple Development identity but no Developer ID Application identity, so distribution signing and Apple notarization were not executed.
- Automated verification does not launch the app, request microphone permission, run Parakeet inference, start Hermes, call Deepgram, modify `/Applications`, or publish an artifact.

## Release-owner validation

Phase 4 implementation is complete. Final distribution acceptance requires credentials and physical operating-system state that are not available to automated local validation:

1. Select the organization-owned production bundle identifier.
2. Install a Developer ID Application certificate and configure `JARVIS_DEVELOPMENT_TEAM`.
3. Configure a notarytool Keychain profile.
4. Run the documented Developer ID archive and explicit notarization command.
5. Install the stapled DMG on a clean macOS account.
6. Verify Gatekeeper, microphone attribution, global hotkey, Keychain upgrade persistence, launch at login, sleep/wake, and audio-device recovery.

These are release execution and hardware/account checks, not missing implementation. See [packaging.md](packaging.md) for exact commands and safeguards.
