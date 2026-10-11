# Jarvis settings and updates validation

Validated on October 10, 2026, using Apple Silicon and Swift 6.4 / Xcode 27.

- 121 JarvisCore tests pass, including automatic-save coalescing, edits during a save, invalid-value recovery, closing-window flush, legacy orb preferences, request model overrides, and Hermes model inventory decoding.
- SwiftPM packaging and the Xcode Release application target build successfully.
- The packaged app passes hardened-runtime signature, nested Sparkle signature, embedded resource, arm64, entitlement, public update key/feed, and development-path dependency checks.
- A local ZIP and appcast were generated using the Jarvis update key. Both Ed25519 signatures verify against the public key embedded in the archive. Deliberately invalid signatures are rejected.
- GitHub workflows pass actionlint. Modified packaging/validation scripts pass bash syntax and ShellCheck; the setup helper passes syntax and ShellCheck with the template's unused-color warning excluded.
- The live Hermes API supplies the model inventory, including authenticated providers and the current default.
- The actual SwiftUI SettingsView was compiled in an isolated preview app. Native controls show Models, Liquid Glass only, software updates, and automatic-save status. Toggling transcript retention invoked the application callback and persisted the preference without pressing any save button. Preview preferences were kept separate from the installed app's preferences.
- All 35 reachable Git commits, current source, GitHub metadata, and OCR from all 19 historical image blobs were checked before the repository became public. The final source scan also reports no secret candidates.

The local app is `dist/updates/J.A.R.V.I.S.app` (0.2.0, build 1000), with an ad hoc signature for local review. It has not replaced the installed app. The implementation was committed and pushed to the public repository after local validation. The release workflow now defaults to personal builds using the existing Sparkle update key; Apple Developer ID and notarization credentials are required only for the optional `developer-id` mode.

A full update installation, Apple notarization, and credential persistence across updates remain untested. Public feed and archive verification are covered below.

## Personal release validation

The release workflow now supports the owner's personal Apple account by requiring only the configured Sparkle key in its default `personal` mode.

- `dist/personal/J.A.R.V.I.S.app` builds as version 0.2.0, build 1001, without an Apple signing certificate. Bundle, hardened-runtime, personal entitlements, updater configuration, and nested framework signatures pass validation.
- A hardened-runtime ad hoc executable loads the embedded Sparkle framework successfully with the personal entitlements.
- ZIP and DMG creation succeeds, and the DMG checksum verifies. Archive and appcast signatures verify against the app's public Ed25519 key.
- Developer ID validation still rejects personal signatures. Personal validation rejects the older ad hoc bundle without the Sparkle loading entitlement. An invalid release mode is rejected.
- Actionlint, shell syntax, ShellCheck, diff checks, and a redacted secret scan of the changes pass.

This build has not replaced the installed app. Initial downloaded-app approval and microphone/Keychain persistence across personal updates remain physical validation steps.

## Published personal release

- [Version 0.2.0, build 1001](https://github.com/aoppenh1-afk/J.A.R.I.S/releases/tag/v0.2.0) was built and published by [GitHub Actions](https://github.com/aoppenh1-afk/J.A.R.I.S/actions/runs/38100866104). Tests, packaging, archive creation, signing, and publication passed without Apple credentials. Apple certificate import and notarization were skipped as intended.
- [Checks](https://github.com/aoppenh1-afk/J.A.R.I.S/actions/runs/38100702620) passed for the implementation, including tests, personal packaging, ZIP/DMG generation, and the Git history secret scan.
- The configured `releases/latest/download/appcast.xml` feed and its ZIP downloaded without a GitHub token. The downloaded app's public key matches the trusted source. The archive and feed signatures both verify.
- The release includes a ZIP, DMG, and signed appcast. The existing installed app still needs to be replaced once with the updater-enabled build.
